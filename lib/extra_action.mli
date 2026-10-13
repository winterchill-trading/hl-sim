(** L1 exchange actions (signed like orders) that {!Hl_protocol.Exchange_action} does not
    model:

    {v
{"type": "updateLeverage", "asset": 0, "isCross": true, "leverage": 10}
{"type": "scheduleCancel", "time": 1700000010000}     (no "time": unschedule)
{"type": "batchModify", "modifies": [{"oid": 1, "order": {...}}, ...]}
    v}

    Shapes from the Hyperliquid exchange endpoint docs. *)

open! Core
open! Hl_protocol

type t =
  | Update_leverage of
      { asset : Asset.t
      ; is_cross : bool
      ; leverage : int
      }
  | Schedule_cancel of { time : int option (** milliseconds *) }
  | Batch_modify of { modifies : Modify_request.t list }
[@@deriving sexp, compare, equal, yojson]

val type_tag : t -> string

(** [None] for any other action type; raises on a malformed one. *)
val of_action_json : Yojson.Safe.t -> t option
