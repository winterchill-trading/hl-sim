open! Core
open! Hl_protocol
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

(* Dimensionless fractions such as fee and funding rates. *)
module Rate = Fixed_decimal.Make ()
module Fee = Fixed_decimal.Product (Usd) (Rate) (Usd)

let rate_of_bps bps = Rate.of_float (bps /. 10_000.)

type t =
  { meta : Meta.t
  ; fees : Fee_schedule.t
  ; taker_rate : Rate.t
  ; maker_rate : Rate.t
  ; default_leverage : int
  ; accounts : Account.t Address.Table.t
  ; mutable fees_collected : Usd.t
  }
[@@deriving sexp_of]

let create ?(fees = Fee_schedule.default) ?(default_leverage = 20) meta =
  { meta
  ; fees
  ; taker_rate = rate_of_bps fees.taker_bps
  ; maker_rate = rate_of_bps fees.maker_bps
  ; default_leverage
  ; accounts = Address.Table.create ()
  ; fees_collected = Usd.zero
  }
;;

let meta t = t.meta
let fees t = t.fees
let fees_collected t = t.fees_collected

let account t address =
  Hashtbl.find_or_add t.accounts address ~default:(fun () -> Account.create address)
;;

let find_account t address = Hashtbl.find t.accounts address

let accounts t =
  Hashtbl.data t.accounts
  |> List.sort ~compare:(fun (a : Account.t) b -> Address.compare a.address b.address)
;;

let deposit t address usd = Account.add_balance (account t address) usd

let max_leverage t coin =
  match Meta.find t.meta coin with
  | Some m -> m.max_leverage
  | None -> raise_s [%message "Clearinghouse: unknown coin" (coin : Coin.t)]
;;

let leverage t address coin =
  let default = Int.min t.default_leverage (max_leverage t coin) in
  match find_account t address with
  | None -> default
  | Some a -> Option.value (Account.leverage a coin) ~default
;;

let set_leverage t address coin lev =
  let max = max_leverage t coin in
  if lev < 1 || lev > max
  then
    Or_error.error_s
      [%message "Invalid leverage" (coin : Coin.t) (lev : int) ~max_leverage:(max : int)]
  else Ok (Account.set_leverage (account t address) coin lev)
;;

type mark = Coin.t -> Price.t option

let mark_of ~mark (p : Position.t) = Option.value (mark p.coin) ~default:p.entry_px

let positions t address =
  match find_account t address with
  | None -> []
  | Some a -> Account.open_positions a
;;

let sum_positions t address ~f = Usd.sum (List.map (positions t address) ~f)

let balance t address =
  Option.value_map (find_account t address) ~default:Usd.zero ~f:(fun a -> a.balance)
;;

let account_value t address ~mark =
  Usd.( + )
    (balance t address)
    (sum_positions t address ~f:(fun p ->
       Position.unrealized_pnl p ~mark:(mark_of ~mark p)))
;;

let abs_notional ~mark p = Usd.abs (Position.notional p ~mark:(mark_of ~mark p))

let position_margin t address ~mark (p : Position.t) =
  Usd.div_int (abs_notional ~mark p) (leverage t address p.coin)
;;

let position_maintenance t ~mark (p : Position.t) =
  Usd.div_int (abs_notional ~mark p) (2 * max_leverage t p.coin)
;;

let margin_used t address ~mark =
  sum_positions t address ~f:(position_margin t address ~mark)
;;

let maintenance_margin t address ~mark =
  sum_positions t address ~f:(position_maintenance t ~mark)
;;

let current_szi t address coin =
  match find_account t address with
  | None -> Size.zero
  | Some a ->
    Option.value_map (Account.position a coin) ~default:Size.zero ~f:(fun p -> p.szi)
;;

let reduce_only_size t address ~coin ~side =
  let szi = current_szi t address coin in
  match (side : Side.t) with
  | Sell when Size.is_positive szi -> szi
  | Buy when Size.is_negative szi -> Size.neg szi
  | Buy | Sell -> Size.zero
;;

let order_margin t address ~coin ~side ~px ~sz =
  let reducible = reduce_only_size t address ~coin ~side in
  let increase = Size.max Size.zero (Size.( - ) sz reducible) in
  Usd.div_int (Notional.mul px increase) (leverage t address coin)
;;

let check_order_margin t address ~coin ~side ~px ~sz ~reserved ~mark =
  let required = order_margin t address ~coin ~side ~px ~sz in
  let available =
    Usd.( - )
      (Usd.( - ) (account_value t address ~mark) (margin_used t address ~mark))
      reserved
  in
  if Usd.( <= ) required available
  then Ok ()
  else
    Or_error.error_s
      [%message
        "Insufficient margin to place order" (required : Usd.t) (available : Usd.t)]
;;

module Settlement = struct
  type t =
    { address : Address.t
    ; side : Side.t
    ; crossed : bool
    ; fee : Usd.t
    ; change : Position.Change.t
    }
  [@@deriving sexp_of]
end

let settle_side t (fill : Order_book.Fill.t) ~address ~side ~crossed : Settlement.t =
  let account = account t address in
  let position = Account.position_or_create account fill.coin in
  let change = Position.apply_trade position ~side ~px:fill.px ~sz:fill.sz in
  let rate = if crossed then t.taker_rate else t.maker_rate in
  let fee = Fee.mul (Notional.mul fill.px fill.sz) rate in
  Account.add_balance account (Usd.( - ) change.closed_pnl fee);
  t.fees_collected <- Usd.( + ) t.fees_collected fee;
  { address; side; crossed; fee; change }
;;

let settle_fill t (fill : Order_book.Fill.t) =
  let taker =
    settle_side t fill ~address:fill.taker ~side:fill.taker_side ~crossed:true
  in
  let maker =
    settle_side
      t
      fill
      ~address:fill.maker
      ~side:(Order_book.Fill.maker_side fill)
      ~crossed:false
  in
  taker, maker
;;

module Liquidation = struct
  type t =
    { address : Address.t
    ; coin : Coin.t
    ; szi : Size.t
    ; px : Price.t
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

let mark_to_market t ~mark =
  List.concat_map (accounts t) ~f:(fun account ->
    let address = account.address in
    let positions = Account.open_positions account in
    if List.is_empty positions
       || Usd.( >= ) (account_value t address ~mark) (maintenance_margin t address ~mark)
    then []
    else
      List.map positions ~f:(fun p ->
        let px = mark_of ~mark p in
        let szi = p.szi in
        let pnl = Position.close_at p ~px in
        Account.add_balance account pnl;
        { Liquidation.address; coin = p.coin; szi; px; pnl }))
;;

module Funding_payment = struct
  type t =
    { address : Address.t
    ; coin : Coin.t
    ; szi : Size.t
    ; payment : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

let apply_funding t ~coin ~rate ~mark =
  let rate = Rate.of_float rate in
  List.filter_map (accounts t) ~f:(fun account ->
    Account.position account coin
    |> Option.map ~f:(fun p ->
      let payment = Fee.mul (Position.notional p ~mark) rate in
      Account.add_balance account (Usd.neg payment);
      Position.add_funding p payment;
      { Funding_payment.address = account.address; coin; szi = p.szi; payment }))
;;

(* Estimated liquidation price of [p] holding everything else fixed: the mark at which
   account value meets maintenance margin. Uses floats; it is informational only. *)
let liquidation_px t ~mark ~account_value ~maintenance (p : Position.t) =
  let side = if Size.is_positive p.szi then 1. else -1. in
  let mark_px = Price.to_float (mark_of ~mark p) in
  let size = Float.abs (Size.to_float p.szi) in
  let l = 1. /. Float.of_int (2 * max_leverage t p.coin) in
  let margin_available = Usd.to_float account_value -. Usd.to_float maintenance in
  let liq = mark_px -. (side *. margin_available /. size /. (1. -. (l *. side))) in
  if Float.( > ) liq 0. then Some (Price.of_float liq) else None
;;

let state t address ~mark ~time : Clearinghouse_state.t =
  let account_value = account_value t address ~mark in
  let maintenance = maintenance_margin t address ~mark in
  let positions =
    List.map (positions t address) ~f:(fun p : Clearinghouse_state.Position.t ->
      let lev = leverage t address p.coin in
      { coin = p.coin
      ; szi = p.szi
      ; entry_px = Some p.entry_px
      ; position_value = abs_notional ~mark p
      ; unrealized_pnl = Position.unrealized_pnl p ~mark:(mark_of ~mark p)
      ; liquidation_px = liquidation_px t ~mark ~account_value ~maintenance p
      ; leverage = Cross { value = lev }
      ; margin_used = position_margin t address ~mark p
      ; max_leverage = max_leverage t p.coin
      })
  in
  let total_ntl_pos = sum_positions t address ~f:(abs_notional ~mark) in
  let total_margin_used = margin_used t address ~mark in
  let summary : Clearinghouse_state.Margin_summary.t =
    { account_value; total_ntl_pos; total_raw_usd = balance t address; total_margin_used }
  in
  { positions
  ; margin_summary = summary
  ; cross_margin_summary = summary
  ; cross_maintenance_margin_used = maintenance
  ; withdrawable = Usd.max Usd.zero (Usd.( - ) account_value total_margin_used)
  ; time
  }
;;
