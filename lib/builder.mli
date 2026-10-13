(** Builder codes: an order action may carry [{"builder": {"b": "0x...", "f": 10}}], which
    charges the user an extra fee of [f] tenths of a basis point of each fill's notional
    and credits it to the builder [b]. The user must first approve at least that rate for
    the builder ({!User_action.Approve_builder_fee}). *)

open! Core
open! Hl_protocol

type t =
  { b : Address.t (** the builder *)
  ; f : int (** fee in tenths of a basis point: 10 is 1 bp *)
  }
[@@deriving sexp, compare, equal, yojson]

(** The perps cap, 0.1%: [f <= 100]. *)
val max_perp_fee : int

(** The builder's minimum perps account value, $100. *)
val min_builder_account_value : Usd.t

(** The [builder] field of an order action, if any; raises on a malformed one. *)
val of_action_json : Yojson.Safe.t -> t option

(** [fee t ~px ~sz] is [px * sz * f / 100_000], truncated to the [Usd.t] resolution. *)
val fee : t -> px:Price.t -> sz:Size.t -> Usd.t

(** A [maxFeeRate] percentage in tenths of a basis point: ["0.1%"] is 100, ["0.001%"]
    is 1. Errors on anything finer than 0.001%, negative, or not a percentage. *)
val tenths_bps_of_rate : string -> int Or_error.t
