(** Builder codes: an order action may carry [{"builder": {"b": "0x...", "f": 10}}]
    ({!Hl_protocol.Builder_fee.t}), which charges the user an extra fee of [f] tenths of a
    basis point of each fill's notional and credits it to the builder [b]. The user must
    first approve at least that rate for the builder ([approveBuilderFee],
    {!User_action}). *)

open! Core
open! Hl_protocol

type t = Builder_fee.t =
  { builder : Address.t
  ; fee_tenths_bp : int
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

(** A [maxFeeRate] percentage in tenths of a basis point: ["0.1%"] is 100, ["0.001%"] is 1
    ({!Hl_protocol.Builder_fee.tenths_bp_of_percent}). *)
val tenths_bps_of_rate : string -> int Or_error.t
