(** An informational edge for the synthetic leaders: the market simulation's reference
    price, seen [lookahead] ahead of the market.

    For each coin it covers, [Foresight] takes over the reference price's random walk from
    {!Exchange_core_engine.Market_sim}: it draws the walk itself, with the same volatility
    and tick interval, [lookahead] in advance, and on every market tick pins the
    simulation's reference to the walk's current point ({!Market_sim.set_reference}
    without a half-life). The noise traders quote around that point as they would around
    their own walk, while a leader holding the [Foresight] reads the point [lookahead]
    later ({!ahead}). The walk's random numbers come from a generator seeded with the
    given seed, so runs repeat. The market acts only through [set_reference] (a mark
    update) and its ordinary orders, so an input journal still replays the run. *)

open! Core
open! Hl_protocol
module Market_sim := Exchange_core_engine.Market_sim

type t

(** Covers [coins] (they must be simulated by [market_sim]; anchored coins must be left
    out, the anchor owns their reference). The walk starts at each coin's current
    reference and [lookahead] (rounded to whole market ticks) of it is drawn at once.
    Raises if [lookahead] is negative. *)
val create
  :  seed:int
  -> lookahead:Time_ns.Span.t
  -> Market_sim.t
  -> coins:Coin.t list
  -> t

val lookahead : t -> Time_ns.Span.t

(** Advances every walk one market tick and pins the market's reference to it. Call it
    right before each [Market_sim.tick]. *)
val tick : t -> unit

(** The reference price of [coin] [lookahead] from now, or [None] for a coin not covered. *)
val ahead : t -> Coin.t -> float option
