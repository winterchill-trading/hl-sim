open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange

module Strategy = struct
  type t =
    | Trend
    | Mean_reversion
    | Random
  [@@deriving sexp_of, compare, equal]

  let of_index i =
    match i % 3 with
    | 0 -> Trend
    | 1 -> Mean_reversion
    | _ -> Random
  ;;

  let to_string = function
    | Trend -> "trend"
    | Mean_reversion -> "mean-reversion"
    | Random -> "random"
  ;;
end

module Config = struct
  type t =
    { seed : int
    ; count : int
    ; coins : Coin.t list
    ; decision_interval : Time_ns.Span.t
    ; balance : Usd.t
    }
  [@@deriving sexp_of]

  let default =
    { seed = 0
    ; count = 0
    ; coins = []
    ; decision_interval = Time_ns.Span.of_int_sec 5
    ; balance = Usd.of_int 100_000
    }
  ;;
end

module Leader = struct
  type t =
    { index : int
    ; address : Address.t
    ; coin : Coin.t
    ; strategy : Strategy.t
    ; leverage : float
    }
  [@@deriving sexp_of]

  let display_name t = sprintf "%s-%d" (Strategy.to_string t.strategy) t.index
end

(* Per-leader state: the strategy's parameters and moving averages. *)
type state =
  { leader : Leader.t
  ; rand : Random.State.t
  ; fast_alpha : float
  ; slow_alpha : float
  ; threshold : float (** mean reversion: relative distance from the slow average *)
  ; switch_probability : float (** random: chance per round of picking a new side *)
  ; mutable fast : float option
  ; mutable slow : float option
  ; mutable random_side : int
  }

type t =
  { config : Config.t
  ; exchange : Exchange.t
  ; states : state list
  }

let address i = Address.of_string (sprintf "0x1eade5%034x" i)
let config t = t.config
let leaders t = List.map t.states ~f:(fun s -> s.leader)

let create (config : Config.t) exchange =
  let coins =
    match config.coins with
    | [] ->
      List.map (Exchange.instruments exchange) ~f:(fun (i : Exchange_core.Instrument.t) ->
        i.symbol)
    | coins -> coins
  in
  let states =
    List.init config.count ~f:(fun index ->
      let rand = Random.State.make [| config.seed; index; 0x1ead |] in
      let leader : Leader.t =
        { index
        ; address = address index
        ; coin = List.nth_exn coins (index / 3 % List.length coins)
        ; strategy = Strategy.of_index index
        ; leverage = Random.State.float_range rand 0.5 3.
        }
      in
      (* Averages over 3 to 10 rounds (fast) and 15 to 60 rounds (slow). *)
      let alpha rounds = 2. /. (Float.of_int rounds +. 1.) in
      { leader
      ; rand
      ; fast_alpha = alpha (Random.State.int_incl rand 3 10)
      ; slow_alpha = alpha (Random.State.int_incl rand 15 60)
      ; threshold = Random.State.float_range rand 0.0005 0.003
      ; switch_probability = Random.State.float_range rand 0.02 0.1
      ; fast = None
      ; slow = None
      ; random_side = 0
      })
  in
  List.iter states ~f:(fun s -> Exchange.deposit exchange s.leader.address config.balance);
  { config; exchange; states }
;;

let ema alpha prev x =
  match prev with
  | None -> x
  | Some prev -> prev +. (alpha *. (x -. prev))
;;

(* -1 short, 0 flat, 1 long. *)
let side s ~mid =
  match s.leader.strategy, s.fast, s.slow with
  | Trend, Some fast, Some slow ->
    if Float.(fast > slow) then 1 else if Float.(fast < slow) then -1 else 0
  | Mean_reversion, _, Some slow ->
    let dev = (mid -. slow) /. slow in
    if Float.(dev > s.threshold) then -1 else if Float.(dev < -.s.threshold) then 1 else 0
  | Random, _, _ ->
    if Float.(Random.State.float s.rand 1. < s.switch_probability)
    then s.random_side <- Random.State.int_incl s.rand (-1) 1;
    s.random_side
  | (Trend | Mean_reversion), _, _ -> 0
;;

let position ex (s : state) =
  let view = Exchange.account_view ex s.leader.address in
  ( view
  , Exchange_core.Account_view.find_position view s.leader.coin
    |> Option.value_map ~default:0. ~f:(fun (p : Exchange_core.Position_view.t) ->
      Size.to_float p.size) )
;;

let decide t (s : state) ~mid =
  s.fast <- Some (ema s.fast_alpha s.fast mid);
  s.slow <- Some (ema s.slow_alpha s.slow mid);
  let side = side s ~mid in
  let view, current = position t.exchange s in
  let equity = Usd.to_float view.equity in
  let target = Float.of_int side *. s.leader.leverage *. equity /. mid in
  let diff = target -. current in
  (* Trade only for a change worth a quarter of the target exposure (and at least $50), so
     leaders hold positions between signals instead of churning. *)
  let min_notional = Float.max 50. (0.25 *. s.leader.leverage *. equity) in
  if Float.(abs diff *. mid >= min_notional)
  then (
    let decimals =
      Option.value_map
        (Exchange.instrument t.exchange s.leader.coin)
        ~default:0
        ~f:(fun i -> i.size_decimals)
    in
    let sz = Size.of_string (sprintf "%.*f" decimals (Float.abs diff)) in
    if Size.is_positive sz
    then
      (* At most 20 bps through the book: a leader takes what is there and works towards
         its target over the next rounds instead of sweeping the noise traders' book. *)
      ignore
        (Adapt.market_order
           ~slippage_bps:20
           t.exchange
           s.leader.address
           ~coin:s.leader.coin
           ~side:(if Float.(diff > 0.) then Buy else Sell)
           ~sz
         : Order_status.t))
;;

let tick t =
  let mids = Exchange.mids t.exchange in
  List.iter t.states ~f:(fun s ->
    match List.Assoc.find mids s.leader.coin ~equal:Coin.equal with
    | None -> ()
    | Some mid -> decide t s ~mid:(Price.to_float mid))
;;
