open! Core
open! Async
open! Hl_protocol

module Config = struct
  type t =
    { seed : int
    ; coins : Coin.t list
    ; initial_prices : (Coin.t * Price.t) list
    ; vol_bps : float
    ; noise_traders : int
    ; trader_balance : Usd.t
    ; tick_interval : Time_ns.Span.t
    ; max_orders_per_coin : int
    ; post_probability : float
    ; cancel_probability : float
    ; market_probability : float
    ; max_offset_bps : float
    ; min_notional : float
    ; max_notional : float
    }
  [@@deriving sexp_of]

  let default =
    { seed = 0
    ; coins = []
    ; initial_prices =
        List.map
          [ "BTC", "100000"; "ETH", "3500"; "SOL", "150" ]
          ~f:(fun (c, p) -> Coin.of_string c, Price.of_string p)
    ; vol_bps = 5.
    ; noise_traders = 10
    ; trader_balance = Usd.of_int 10_000_000
    ; tick_interval = Time_ns.Span.of_int_ms 100
    ; max_orders_per_coin = 5
    ; post_probability = 0.3
    ; cancel_probability = 0.1
    ; market_probability = 0.02
    ; max_offset_bps = 25.
    ; min_notional = 20.
    ; max_notional = 2000.
    }
  ;;
end

module Market = struct
  type t =
    { coin : Coin.t
    ; asset : Asset.t
    ; sz_decimals : int
    ; mutable reference : float
    }
end

type t =
  { config : Config.t
  ; exchange : Exchange.t
  ; random : Random.State.t
  ; markets : Market.t list
  ; traders : Address.t list
  ; sigma : float (** per-tick standard deviation of log returns *)
  }

let config t = t.config
let traders t = t.traders
let trader_address i = Address.of_string (sprintf "0x%s%08x" (String.make 32 'f') i)

let create (config : Config.t) exchange =
  let meta = Exchange.meta exchange in
  let coins =
    match config.coins with
    | [] -> List.map meta.universe ~f:(fun m -> m.name)
    | coins -> coins
  in
  let markets =
    List.map coins ~f:(fun coin ->
      match Meta.find meta coin, Meta.asset_of_coin meta coin with
      | Some m, Some asset ->
        let reference =
          List.Assoc.find config.initial_prices coin ~equal:Coin.equal
          |> Option.value_map ~f:Price.to_float ~default:100.
        in
        { Market.coin; asset; sz_decimals = m.sz_decimals; reference }
      | _ -> raise_s [%message "Market_sim: unknown coin" (coin : Coin.t)])
  in
  let traders = List.init config.noise_traders ~f:trader_address in
  List.iter traders ~f:(fun a -> Exchange.deposit exchange a config.trader_balance);
  let sigma =
    config.vol_bps /. 10_000. *. Float.sqrt (Time_ns.Span.to_sec config.tick_interval)
  in
  { config
  ; exchange
  ; random = Random.State.make [| config.seed |]
  ; markets
  ; traders
  ; sigma
  }
;;

(* Hyperliquid prices: at most 5 significant figures and [6 - szDecimals] decimals;
   integers are always valid. *)
let round_price ~sz_decimals x =
  let int_digits = Float.iround_down_exn (Float.log10 x) + 1 in
  let decimals = Int.max 0 (Int.min (6 - sz_decimals) (5 - int_digits)) in
  Price.round_nearest (Price.of_float x) ~decimals
;;

let reference_price t coin =
  List.find t.markets ~f:(fun m -> Coin.equal m.coin coin)
  |> Option.map ~f:(fun m -> round_price ~sz_decimals:m.sz_decimals m.reference)
;;

let uniform t lo hi = lo +. Random.State.float t.random (hi -. lo)
let chance t p = Float.(Random.State.float t.random 1. < p)
let random_side t = if Random.State.bool t.random then Side.Buy else Side.Sell

(* Box-Muller. *)
let gaussian t =
  let u1 = Float.max Float.min_positive_normal_value (Random.State.float t.random 1.) in
  let u2 = Random.State.float t.random 1. in
  Float.sqrt (-2. *. Float.log u1) *. Float.cos (2. *. Float.pi *. u2)
;;

(* A size worth a random notional at [px], rounded down to the coin's lot size. *)
let random_size t (m : Market.t) ~px =
  let notional = uniform t t.config.min_notional t.config.max_notional in
  Size.round_down (Size.of_float (notional /. px)) ~decimals:m.sz_decimals
;;

let cancel_oldest t trader (m : Market.t) =
  let orders =
    Exchange.open_orders t.exchange trader
    |> List.filter ~f:(fun (o : Open_order.t) -> Coin.equal o.coin m.coin)
  in
  let n = List.length orders in
  if n > t.config.max_orders_per_coin || (n > 0 && chance t t.config.cancel_probability)
  then (
    (* [open_orders] is newest first. *)
    let oldest = List.last_exn orders in
    ignore
      (Exchange.cancel t.exchange trader { asset = m.asset; oid = oldest.oid }
       : Cancel_status.t))
;;

let post t trader (m : Market.t) =
  if chance t t.config.post_probability
  then (
    let side = random_side t in
    let offset = uniform t 0.5 t.config.max_offset_bps /. 10_000. in
    let px =
      match side with
      | Buy -> m.reference *. (1. -. offset)
      | Sell -> m.reference *. (1. +. offset)
    in
    let limit_px = round_price ~sz_decimals:m.sz_decimals px in
    let sz = random_size t m ~px in
    if Size.is_positive sz
    then
      ignore
        (Exchange.place_order
           t.exchange
           trader
           { asset = m.asset
           ; is_buy = Side.is_buy side
           ; limit_px
           ; sz
           ; reduce_only = false
           ; order_type = Order_type.gtc
           ; cloid = None
           }
         : Order_status.t))
;;

let market t trader (m : Market.t) =
  if chance t t.config.market_probability
  then (
    let side = random_side t in
    let sz = random_size t m ~px:m.reference in
    if Size.is_positive sz
    then
      ignore
        (Exchange.market_order t.exchange trader ~coin:m.coin ~side ~sz : Order_status.t))
;;

let tick t =
  List.iter t.markets ~f:(fun m ->
    m.reference <- m.reference *. Float.exp (t.sigma *. gaussian t);
    Exchange.set_mark
      t.exchange
      m.coin
      (round_price ~sz_decimals:m.sz_decimals m.reference));
  List.iter t.traders ~f:(fun trader ->
    List.iter t.markets ~f:(fun m ->
      cancel_oldest t trader m;
      post t trader m;
      market t trader m))
;;

let start t ~server =
  Clock_ns.every t.config.tick_interval (fun () ->
    Server.mutate server ~f:(fun _ -> tick t))
;;
