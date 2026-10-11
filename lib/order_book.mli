(** A single coin's limit order book with price-time priority.

    Each side maps prices to levels; a level is a FIFO queue of resting orders. Incoming
    orders match against the opposite side best price first and, within a price, oldest
    first. Fills always execute at the maker's price.

    Self-trade prevention: when the next maker in priority belongs to the taker's own
    account, matching stops and the taker's remainder is cancelled (the resting order is
    left untouched). Fills made before reaching the own order stand.

    The book is mutable and performs no margin or account checks; see [Exchange]. *)

open! Core
open! Hl_protocol

module Resting_order : sig
  type t = private
    { oid : Order_id.t
    ; owner : Address.t
    ; side : Side.t
    ; px : Price.t
    ; mutable remaining : Size.t
    ; orig_sz : Size.t
    ; timestamp : int (** nanoseconds at which the order was accepted *)
    ; reduce_only : bool
    ; cloid : Cloid.t option
    }
  [@@deriving sexp_of]
end

module Cancel_reason : sig
  type t =
    | Ioc_unfilled (** IOC or market remainder after sweeping the book *)
    | Self_trade (** the next maker belonged to the taker's account *)
  [@@deriving sexp_of, compare, equal]
end

module Status : sig
  type t =
    | Resting (** the remainder rests on the book *)
    | Filled (** the whole size was matched *)
    | Cancelled of Cancel_reason.t (** the remainder was cancelled *)
    | Would_cross (** ALO order rejected because it would have taken liquidity *)
  [@@deriving sexp_of, compare, equal]
end

module Result : sig
  type t =
    { fills : Fill.t list (** in execution order *)
    ; status : Status.t
    ; filled : Size.t
    ; remaining : Size.t (** unfilled size: resting, cancelled or rejected *)
    }
  [@@deriving sexp_of]
end

type t [@@deriving sexp_of]

val create : Coin.t -> t
val coin : t -> Coin.t

(** Submits a limit order. [Gtc] rests any remainder, [Ioc] cancels it, [Alo] is rejected
    with [Would_cross] if it would match immediately and otherwise rests in full.
    [next_tid] is called once per fill. Raises if [sz] or [px] is not positive or the oid
    is already on the book. *)
val add_limit
  :  t
  -> oid:Order_id.t
  -> owner:Address.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> tif:Tif.t
  -> ?reduce_only:bool
  -> ?cloid:Cloid.t
  -> time:int
  -> next_tid:(unit -> int)
  -> unit
  -> Result.t

(** The worst acceptable price for a market order: the best opposite price moved against
    the taker by [slippage_bps]. [None] if the opposite side is empty. *)
val market_limit_px : t -> side:Side.t -> slippage_bps:int -> Price.t option

(** Sweeps the opposite side up to [market_limit_px], like an IOC order at that price.
    With an empty opposite side nothing fills and the status is [Cancelled Ioc_unfilled]. *)
val market
  :  t
  -> oid:Order_id.t
  -> owner:Address.t
  -> side:Side.t
  -> sz:Size.t
  -> slippage_bps:int
  -> ?reduce_only:bool
  -> ?cloid:Cloid.t
  -> time:int
  -> next_tid:(unit -> int)
  -> unit
  -> Result.t

(** Removes a resting order, returning it, or [None] if it is not on the book. *)
val cancel : t -> Order_id.t -> Resting_order.t option

val find : t -> Order_id.t -> Resting_order.t option
val best_bid : t -> Price.t option
val best_ask : t -> Price.t option

(** Midpoint of the best bid and ask, when both exist (rounded toward zero). *)
val mid : t -> Price.t option

(** Aggregated levels, best first, at most [n_levels] per side: [(bids, asks)]. *)
val l2 : t -> n_levels:int -> L2_book.Level.t list * L2_book.Level.t list

(** Visits every resting order: bids from best to worst, then asks from best to worst, in
    time priority within a level. [f] must not modify the book. *)
val iter : t -> f:(Resting_order.t -> unit) @ local -> unit

val orders : t -> Resting_order.t list
val length : t -> int
val is_empty : t -> bool

(** Raises if internal invariants are violated (crossed book, empty or mis-totalled
    levels, stale index). Used by tests. *)
val invariant : t -> unit
