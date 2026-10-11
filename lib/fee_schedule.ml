open! Core

type t =
  { taker_bps : float
  ; maker_bps : float
  }
[@@deriving sexp, compare, equal]

let default = { taker_bps = 3.5; maker_bps = 1. }
let zero = { taker_bps = 0.; maker_bps = 0. }
