(** The whole simulated exchange: one order book per coin, the clearinghouse, mark prices,
    id counters, a caller-driven clock and an event log.

    Time is an [int] count of nanoseconds supplied by the caller ([step]); the exchange
    never reads the wall clock, so runs are deterministic. Hyperliquid-facing timestamps
    are reported in milliseconds.

    Requests and responses use the hl-protocol wire types. Error strings follow
    Hyperliquid's wording where the simulator implements the same check. *)

open! Core
open! Hl_protocol

module Config : sig
  type t =
    { meta : Meta.t
    ; fees : Fee_schedule.t
    ; default_leverage : int (** capped by each coin's [max_leverage] *)
    ; funding_interval_ns : int (** funding is charged at each multiple of this *)
    ; default_funding_rate : float (** per interval, until [set_funding_rate] *)
    ; min_order_value : Usd.t (** reduce-only orders are exempt *)
    ; market_slippage_bps : int (** default for [market_order] *)
    ; l2_levels : int (** default depth of [l2_book] *)
    }
  [@@deriving sexp_of]

  (** BTC (szDecimals 5, 40x), ETH (4, 25x), SOL (2, 20x). *)
  val default_meta : Meta.t

  (** [default_meta], {!Fee_schedule.default}, 20x, hourly funding at 0.00125% (the 0.01%
      per 8h interest component), $10 minimum, 5% market slippage, 20 levels. *)
  val default : t
end

type t

val create : ?config:Config.t -> unit -> t
val config : t -> Config.t
val meta : t -> Meta.t
val clearinghouse : t -> Clearinghouse.t

(** Current time in nanoseconds. *)
val now : t -> int

(** {2 Accounts} *)

val deposit : t -> Address.t -> Usd.t -> unit
val set_leverage : t -> Address.t -> Coin.t -> int -> unit Or_error.t

(** {2 Exchange endpoint} *)

(** Validates, margin-checks and matches an order. Trigger orders are rejected. A
    reduce-only order is clipped to the size that reduces the current position. *)
val place_order : t -> Address.t -> Order_request.t -> Order_status.t

(** An IOC order priced [slippage_bps] (default from config) through the best opposite
    price, as Hyperliquid's SDKs submit market orders. *)
val market_order
  :  ?slippage_bps:int
  -> ?reduce_only:bool
  -> ?cloid:Cloid.t
  -> t
  -> Address.t
  -> coin:Coin.t
  -> side:Side.t
  -> sz:Size.t
  -> Order_status.t

val cancel : t -> Address.t -> Cancel_request.t -> Cancel_status.t
val cancel_by_cloid : t -> Address.t -> Cancel_by_cloid.t -> Cancel_status.t

(** Cancels the target order and places [order] in its place (with a new oid, losing time
    priority). If the replacement is rejected the original stays cancelled. *)
val modify : t -> Address.t -> Modify_request.t -> Order_status.t

(** {2 Info endpoint} *)

val l2_book : ?n_levels:int -> t -> Coin.t -> L2_book.t option
val all_mids : t -> All_mids.t

(** Resting orders, newest first. *)
val open_orders : t -> Address.t -> Open_order.t list

(** Fills, newest first. *)
val user_fills : t -> Address.t -> User_fill.t list

val clearinghouse_state : t -> Address.t -> Clearinghouse_state.t

(** {2 Prices, funding and time} *)

(** Mark price: the last [set_mark], else the last trade price, else the book mid. *)
val mark : t -> Coin.t -> Price.t option

(** Sets the mark price and liquidates accounts that fall below maintenance margin. *)
val set_mark : t -> Coin.t -> Price.t -> unit

val set_funding_rate : t -> Coin.t -> float -> unit

(** Advances the clock to [now] (raises if it would go backwards), charges funding for
    every funding boundary crossed, then liquidates under-margined accounts. *)
val step : t -> now:int -> unit

(** {2 Events} *)

(** Returns the events since the previous call, oldest first, and forgets them. *)
val drain_events : t -> Event.t list

(** The order book of a coin, for inspection. *)
val book : t -> Coin.t -> Order_book.t option
