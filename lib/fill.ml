open! Core
open! Hl_protocol

type t =
  { tid : int
  ; coin : Coin.t
  ; px : Price.t
  ; sz : Size.t
  ; taker_side : Side.t
  ; taker_oid : Order_id.t
  ; maker_oid : Order_id.t
  ; taker : Address.t
  ; maker : Address.t
  ; taker_cloid : Cloid.t option
  ; maker_cloid : Cloid.t option
  ; time : int
  }
[@@deriving sexp_of, compare, equal]

let maker_side t = Side.flip t.taker_side
let hash t = sprintf "0x%064x" t.tid

let to_trade t : Trade.t =
  let users =
    match t.taker_side with
    | Buy -> t.taker, t.maker
    | Sell -> t.maker, t.taker
  in
  { coin = t.coin
  ; side = t.taker_side
  ; px = t.px
  ; sz = t.sz
  ; hash = hash t
  ; time = t.time / 1_000_000
  ; tid = t.tid
  ; users
  }
;;
