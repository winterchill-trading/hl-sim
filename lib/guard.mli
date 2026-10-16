(** The engine's price collar ({!Exchange_core_engine.Price_collar}) and halt rule
    ({!Exchange_core_engine.Halt_rule}) as simulator settings: the command-line flags,
    applying them to an exchange, the status shown on [GET /status], and the Hyperliquid
    text of their rejections.

    Both are off unless a flag turns them on, and then go through the engine's recorded
    calls ([set_collar], [set_halt_rule]), so an input journal carries them and its replay
    reproduces the guard events. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange
module Price_collar := Exchange_core_engine.Price_collar
module Halt_rule := Exchange_core_engine.Halt_rule
module Guard_event := Exchange_core_engine.Guard_event

module Config : sig
  type t =
    { collar : Price_collar.Config.t option (** set on every coin *)
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of]

  (** Neither collar nor halt rule: the simulator behaves as without this module. *)
  val off : t
end

(** Parses halt levels, [PERCENT:DURATION] separated by commas, ascending:
    ["7:15m,13:15m,20:reopen"]. The percentage may have decimals; the duration is a
    {!Time_ns.Span} ([15m], [90s], [1h]) or [reopen] (halted until [POST /sim/reopen]). *)
val parse_levels : string -> Halt_rule.Level.t list Or_error.t

(** [-collar-bps N | -collar-ticks N], [-collar-reference last|mid|mark],
    [-collar-action reject|reprice], [-halt-levels SPEC] and [-halt-scope market|symbol].
    The result takes whether the run is anchored: the collar reference then defaults to
    the mark (the anchored reference), else to the last trade. Errors for a reference or
    action without a band, a scope without levels, or invalid settings. *)
val param : (anchored:bool -> Config.t Or_error.t) Command.Param.t

(** Sets the collar on every instrument of the exchange and the halt rule (only those
    configured). *)
val apply : Config.t -> Exchange.t -> unit Or_error.t

(** Whether a collar or halt rule is set on the exchange. *)
val is_on : Exchange.t -> bool

(** [{"collar": ..., "halt_rule": ..., "halted": [...], "stats": {...}, "recent": [...]}]:
    the settings, the halted coins with the time they reopen ([until_ms], or [until]
    ["reopen"] or ["reopen_pending"]), the {!Guard_event.Stats} counters and [recent]
    guard events, oldest first. *)
val status : Exchange.t -> recent:Guard_event.t list -> Yojson.Safe.t

(** One guard event as JSON, as listed in {!status}. *)
val event_json : Guard_event.t -> Yojson.Safe.t

(** {2 Rejections} *)

(** Runs [f] (an order call on the exchange) and says whether the collar rejected it: the
    engine reports a collar rejection as [Invalid_price], like a price off the tick grid,
    and only the guard counter going up during the call tells them apart. *)
val collar_rejected_during : Exchange.t -> f:(unit -> 'a) -> 'a * bool

(** The width of the coin's collar in percent of the reference, as Hyperliquid writes it
    in its oracle error ([0.5], [5], [80]): from a band in bps, or measured from the
    current reference and bound for a band in ticks. *)
val collar_percent : Exchange.t -> Coin.t -> side:Exchange_core.Side.t -> string

(** Whether a rejection reason is the engine's halt rejection. *)
val is_halt_rejection : Exchange_core.Reject_reason.t -> bool
