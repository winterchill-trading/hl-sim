(** Trading fees in basis points of notional. Fees are always charged (no rebates). *)

open! Core

type t =
  { taker_bps : float
  ; maker_bps : float
  }
[@@deriving sexp, compare, equal]

(** Hyperliquid's base tier: taker 0.035% (3.5 bps), maker 0.01% (1 bp). *)
val default : t

(** No fees, convenient in tests. *)
val zero : t
