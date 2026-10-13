(** A journal of accepted [POST /exchange] requests, one JSON object per line:

    [{"time": 1700000000000000000, "address": "0x...", "request": {...}}]
    [{"time": 1700000000000000000, "address": "0x...", "userAction": {...}, "signature": {...}}]

    [time] is the exchange clock (nanoseconds since the epoch) the request was applied at,
    [address] the acting account (for an agent-signed request, the account the agent signs
    for) and [request] the decoded {!Hl_protocol.Exchange_request.t}, with the order
    action's builder code in [builder] when it has one. User-signed actions
    ({!User_action}) are journaled with the owner's address, so replay does not need to
    verify signatures. Requests that fail to decode are not journaled.

    Replaying a journal into a fresh exchange ({!Server.replay}) reproduces the same
    fills, provided nothing else mutated the original exchange (no market simulation). *)

open! Core
open! Async
open! Hl_protocol

module Entry : sig
  type t =
    { time : int
    ; address : Address.t
    ; request : Exchange_request.t
    ; builder : Builder.t option (** absent from the JSON when [None] *)
    }
  [@@deriving sexp, equal, yojson]

  (** One line of JSON, without the newline. *)
  val to_line : t -> string

  (** Parses one line; raises on malformed input. *)
  val of_line : string -> t
end

module User_entry : sig
  type t =
    { time : int
    ; address : Address.t
    ; user_action : User_action.t
    ; signature : Json.t option
    }
  [@@deriving sexp, equal, yojson]
end

(** [updateLeverage], [scheduleCancel] and [batchModify], under ["l1Action"]. *)
module Extra_entry : sig
  type t =
    { time : int
    ; address : Address.t
    ; extra_action : Extra_action.t
    }
  [@@deriving sexp, equal, yojson]
end

(** One line of a journal. *)
module Record : sig
  type t =
    | Request of Entry.t
    | User_action of User_entry.t
    | Extra of Extra_entry.t
  [@@deriving sexp_of, equal]

  val to_line : t -> string

  (** Parses one line of either kind; raises on malformed input. *)
  val of_line : string -> t
end

type t

(** Appends entries to [writer]. *)
val of_writer : Writer.t -> t

(** Opens (appending to) [path]. *)
val open_file : string -> t Deferred.t

(** Writes one entry and its newline; does not wait for the flush. *)
val write : t -> Entry.t -> unit

val write_record : t -> Record.t -> unit
val flushed : t -> unit Deferred.t
val close : t -> unit Deferred.t

(** Reads every entry of a journal file; blank lines are skipped. *)
val load : string -> Record.t list Deferred.t
