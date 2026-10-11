open! Core
open! Hl_protocol

type t =
  { coin : Coin.t
  ; mutable szi : Size.t
  ; mutable entry_px : Price.t
  ; mutable realized_pnl : Usd.t
  ; mutable cum_funding : Usd.t
  }
[@@deriving sexp_of]

let create coin =
  { coin
  ; szi = Size.zero
  ; entry_px = Price.zero
  ; realized_pnl = Usd.zero
  ; cum_funding = Usd.zero
  }
;;

let is_flat t = Size.is_zero t.szi

module Change = struct
  type t =
    { start_position : Size.t
    ; closed_pnl : Usd.t
    ; dir : string
    }
  [@@deriving sexp_of]
end

(* PnL of closing [closed] (signed like the position) opened at [entry] at [px]. *)
let pnl ~entry ~px ~closed =
  Usd.( - ) (Fixed_math.notional px closed) (Fixed_math.notional entry closed)
;;

let signed (side : Side.t) sz =
  match side with
  | Buy -> sz
  | Sell -> Size.neg sz
;;

let apply_trade t ~side ~px ~sz : Change.t =
  let start = t.szi in
  let delta = signed side sz in
  let next = Size.( + ) start delta in
  let same_direction =
    Size.is_zero start || Bool.equal (Size.is_positive start) (Size.is_positive delta)
  in
  let closed_pnl, dir =
    if same_direction
    then (
      (* Increase: weighted average entry. *)
      let notional =
        Usd.( + )
          (Fixed_math.notional t.entry_px (Size.abs start))
          (Fixed_math.notional px sz)
      in
      t.entry_px <- Fixed_math.avg_price ~notional ~size:(Size.abs next);
      Usd.zero, if Size.is_positive delta then "Open Long" else "Open Short")
    else (
      let closed =
        if Size.( <= ) (Size.abs delta) (Size.abs start) then Size.neg delta else start
      in
      let realized = pnl ~entry:t.entry_px ~px ~closed in
      let flipped =
        (not (Size.is_zero next))
        && not (Bool.equal (Size.is_positive next) (Size.is_positive start))
      in
      if flipped then t.entry_px <- px;
      let dir =
        match Size.is_positive start, flipped with
        | true, false -> "Close Long"
        | false, false -> "Close Short"
        | true, true -> "Long > Short"
        | false, true -> "Short > Long"
      in
      realized, dir)
  in
  t.szi <- next;
  if Size.is_zero next then t.entry_px <- Price.zero;
  t.realized_pnl <- Usd.( + ) t.realized_pnl closed_pnl;
  { start_position = start; closed_pnl; dir }
;;

let notional t ~mark = Fixed_math.notional mark t.szi
let unrealized_pnl t ~mark = pnl ~entry:t.entry_px ~px:mark ~closed:t.szi

let close_at t ~px =
  let realized = unrealized_pnl t ~mark:px in
  t.realized_pnl <- Usd.( + ) t.realized_pnl realized;
  t.szi <- Size.zero;
  t.entry_px <- Price.zero;
  realized
;;

let add_funding t payment = t.cum_funding <- Usd.( + ) t.cum_funding payment
