(** Price anchors for the simulator: each anchored coin follows a reference instrument on
    another venue (or on Hyperliquid itself), live or recorded, through
    {!Price_anchor.Anchor}.

    The anchor acts on the exchange directly (journaled engine calls), on the Async
    scheduler thread that owns the server: it is created inside {!Server.mutate}, its
    {!Price_anchor.Anchor.step} runs from {!Server.on_clock_step} after the server has
    stepped the clock, and the events of every reference item are published to websocket
    subscribers right after it is applied. *)

open! Core
open! Async
open! Hl_protocol

module Spec : sig
  type t =
    { reference : Market_data.Instrument.t
    ; sim_symbol : Coin.t
    }
  [@@deriving sexp_of, equal]

  (** ["<venue>:<symbol>=<coin>"], e.g. ["binance:BTCUSDT=BTC"]; without [=<coin>] the
      reference symbol is the simulated coin (["hyperliquid:BTC"]). Raises on an unknown
      venue or a missing [':']. *)
  val of_string : string -> t

  val to_string : t -> string
  val arg_type : t Command.Arg_type.t
end

module Config : sig
  type t =
    { levels : int (** shadow levels per side *)
    ; mark_interval : Time_ns.Span.t
    ; max_staleness : Time_ns.Span.t
    ; noise_traders : int (** noise traders kept on an anchored coin *)
    ; price_factor : float
    ; size_factor : float
    }
  [@@deriving sexp_of]

  (** 5 levels, 100ms, 5s, no noise traders, factors of 1. *)
  val default : t
end

(** Venues the simulator can follow: their client's live feed and raw-file normalizer are
    linked in. *)
val supported_venues : Market_data.Venue.t list

(** The {!Market_data.Normalizer.S} of a venue's raw recorder files. *)
val normalizer : Market_data.Venue.t -> Market_data.Normalizer.t Or_error.t

(** A live source: the reference venue's read-only [Live_feed] (trades, L2, funding),
    against the venue's mainnet unless [base_url] is given. Closing the source closes the
    feed. *)
val live_source : ?base_url:Uri.t -> Spec.t -> Price_anchor.Source.t Or_error.t Deferred.t

(** The reference's raw minute files under [dir] with [recv_ts] in [[from, to_)]. *)
val raw_source
  :  ?on_error:(Error.t -> unit)
  -> dir:string
  -> from:Time_ns.t
  -> to_:Time_ns.t
  -> Spec.t
  -> Price_anchor.Source.t Or_error.t

(** The reference's normalized event logs under [dir] for the UTC days [[from, to_]]. *)
val norm_source
  :  dir:string
  -> from:Date.t
  -> to_:Date.t
  -> Spec.t
  -> Price_anchor.Source.t Or_error.t Deferred.t

type t

(** Creates the anchor on the server's exchange (with [market_sim], the coin's noise
    traders are set to [config.noise_traders]) and hooks its [step] to the server's clock.
    [log] receives the anchor's transitions (default: [Log.Global.info_s], tagged with the
    spec). Raises if the coin is not simulated. *)
val create
  :  ?config:Config.t
  -> ?market_sim:Exchange_core_engine.Market_sim.t
  -> ?log:(Sexp.t -> unit)
  -> Server.t
  -> Spec.t
  -> t

val spec : t -> Spec.t
val anchor : t -> Price_anchor.Anchor.t

(** Applies every item of [source] to the anchor ({!Price_anchor.Source.run}), publishing
    the resulting events after each one. [speed] paces recorded time ([1.] real time,
    [0.], the default, as fast as items come). Determined when the source closes. *)
val run
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> t
  -> Price_anchor.Source.t
  -> unit Deferred.t
