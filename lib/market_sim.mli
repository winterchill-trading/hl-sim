(** Synthetic background order flow, so the simulated book is alive without external
    traders.

    Each coin has a reference price following a geometric random walk. On every tick the
    walk advances, the exchange's mark is set to the reference price, and each of [N]
    noise trader accounts may, per coin:
    - cancel its oldest resting order (always when it has more than
      [max_orders_per_coin]);
    - post a GTC limit order a random distance from the reference price, bids below and
      asks above it (resting orders left behind by the walk cross and trade);
    - send a small market order.

    All randomness comes from a [Random.State.t] seeded with [Config.seed], and the
    simulator never reads the clock, so [tick] sequences are reproducible. *)

open! Core
open! Async
open! Hl_protocol

module Config : sig
  type t =
    { seed : int
    ; coins : Coin.t list (** coins to trade; empty means every coin in the meta *)
    ; initial_prices : (Coin.t * Price.t) list
    (** starting reference prices; BTC 100000, ETH 3500, SOL 150, else 100 *)
    ; vol_bps : float (** standard deviation of the reference price over 1s, in bps *)
    ; noise_traders : int
    ; trader_balance : Usd.t (** deposited into each noise trader at creation *)
    ; tick_interval : Time_ns.Span.t
    ; max_orders_per_coin : int (** per trader *)
    ; post_probability : float (** per trader, coin and tick *)
    ; cancel_probability : float
    ; market_probability : float
    ; max_offset_bps : float (** limit orders rest up to this far from the reference *)
    ; min_notional : float (** USD size range of an order *)
    ; max_notional : float
    }
  [@@deriving sexp_of]

  (** Seed 0, all coins, 5 bps/s, 10 traders with $10M each, 100ms ticks, up to 5 orders
      per coin per trader, probabilities 0.3 / 0.1 / 0.02, offsets up to 25 bps, $20 to
      $2000 per order. *)
  val default : t
end

type t

(** Deposits [trader_balance] into every noise trader. *)
val create : Config.t -> Exchange.t -> t

val config : t -> Config.t

(** The noise trader addresses: [0xffff...ff] followed by the trader index in 8 hex
    digits. *)
val traders : t -> Address.t list

val reference_price : t -> Coin.t -> Price.t option

(** Advances the walk one tick and generates that tick's orders. Does not move the
    exchange clock. *)
val tick : t -> unit

(** Calls [tick] every [tick_interval] through {!Server.mutate}, so the resulting events
    reach websocket subscribers. *)
val start : t -> server:Server.t -> unit
