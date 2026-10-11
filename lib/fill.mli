(** A single match between an incoming (taker) order and a resting (maker) order. *)

open! Core
open! Hl_protocol

type t =
  { tid : int (** trade id, unique across the exchange *)
  ; coin : Coin.t
  ; px : Price.t (** always the maker's price *)
  ; sz : Size.t (** strictly positive *)
  ; taker_side : Side.t
  ; taker_oid : Order_id.t
  ; maker_oid : Order_id.t
  ; taker : Address.t
  ; maker : Address.t
  ; taker_cloid : Cloid.t option
  ; maker_cloid : Cloid.t option
  ; time : int (** nanoseconds, from the caller-supplied clock *)
  }
[@@deriving sexp_of, compare, equal]

val maker_side : t -> Side.t

(** The public trade as streamed on the [trades] channel. *)
val to_trade : t -> Trade.t

(** A deterministic placeholder transaction hash derived from the trade id. *)
val hash : t -> string
