(** Simulated "leader" accounts for copy trading: [N] accounts that each trade one coin
    with a fixed strategy, so that followers have positions to mirror and the leaderboard
    has distinct track records.

    Leader [i] has the address [0x1eade5] followed by [i] in 34 hex digits, trades coin
    [i / 3] (modulo the coins) and follows strategy [i mod 3]:
    - [Trend]: long when a fast moving average of the mid is above a slow one, short when
      below;
    - [Mean_reversion]: short when the mid is more than a threshold above the slow
      average, long when as far below, flat in between;
    - [Random]: switches between long, flat and short at random moments.

    Its averages' lengths, leverage (0.5x to 3x of account value) and thresholds are drawn
    from a generator seeded with [Config.seed] and [i], so a leader keeps the same
    address, coin, strategy and parameters across runs: restarting the simulator with the
    same flags gives the same leaders. Leaders trade with market orders through the
    engine's ordinary calls, so an input journal replays them. Without a book (no market
    simulation or anchor) they stay flat. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

module Strategy : sig
  type t =
    | Trend
    | Mean_reversion
    | Random
  [@@deriving sexp_of, compare, equal]

  val to_string : t -> string
end

module Config : sig
  type t =
    { seed : int
    ; count : int
    ; coins : Coin.t list (** empty means every coin of the exchange *)
    ; decision_interval : Time_ns.Span.t (** how often each leader re-evaluates *)
    ; balance : Usd.t (** deposited into each leader at creation *)
    }
  [@@deriving sexp_of]

  (** Seed 0, no leaders, all coins, 5s, $100,000. *)
  val default : t
end

module Leader : sig
  type t =
    { index : int
    ; address : Address.t
    ; coin : Coin.t
    ; strategy : Strategy.t
    ; leverage : float
    }
  [@@deriving sexp_of]

  (** ["trend-0"], ["mean-reversion-1"], ...: the leaderboard [displayName]. *)
  val display_name : t -> string
end

type t

(** Deposits [balance] into every leader. *)
val create : Config.t -> Exchange.t -> t

val config : t -> Config.t
val leaders : t -> Leader.t list

(** The address of leader [i]. *)
val address : int -> Address.t

(** One decision round: every leader reads its coin's mid and trades towards its target
    position. *)
val tick : t -> unit
