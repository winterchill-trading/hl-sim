(** A journal of accepted [POST /exchange] requests, one JSON object per line:

    [{"time": 1700000000000000000, "address": "0x...", "request": {...}}]

    [time] is the exchange clock (nanoseconds since the epoch) the request was applied at,
    [address] the acting address and [request] the decoded
    {!Hl_protocol.Exchange_request.t}. Requests that fail to decode are not journaled.

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
    }
  [@@deriving sexp, equal, yojson]

  (** One line of JSON, without the newline. *)
  val to_line : t -> string

  (** Parses one line; raises on malformed input. *)
  val of_line : string -> t
end

type t

(** Appends entries to [writer]. *)
val of_writer : Writer.t -> t

(** Opens (appending to) [path]. *)
val open_file : string -> t Deferred.t

(** Writes one entry and its newline; does not wait for the flush. *)
val write : t -> Entry.t -> unit

val flushed : t -> unit Deferred.t
val close : t -> unit Deferred.t

(** Reads every entry of a journal file; blank lines are skipped. *)
val load : string -> Entry.t list Deferred.t
