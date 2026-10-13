(** Hyperliquid front end of the venue-neutral engine ({!Exchange_core_engine.Exchange}):
    Hyperliquid's universe and price rules, asset indices, request and response types,
    error wording and websocket payloads.

    The engine counts time in nanoseconds; every Hyperliquid-facing timestamp is reported
    in milliseconds. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

(** {2 Universe} *)

(** BTC (szDecimals 5, 40x), ETH (4, 25x), SOL (2, 20x); asset indices 0, 1, 2. *)
val default_meta : Meta.t

(** Hyperliquid's base perps fee tier (below $5M of 14-day volume): taker 4.5 bps, maker
    1.5 bps. *)
val base_fees : Exchange_core.Fee_schedule.t

(** Hyperliquid perp rules: size step [10^-szDecimals], price tick [10^-(6 - szDecimals)]
    and at most 5 significant figures (integers always allowed), [fees] (default
    {!base_fees}). *)
val instrument
  :  ?fees:Exchange_core.Fee_schedule.t
  -> Meta.Asset_meta.t
  -> Exchange_core.Instrument.t

(** {!Exchange_core_engine.Exchange.Config.default} with the instruments of [meta]
    (default {!default_meta}). *)
val config
  :  ?meta:Meta.t
  -> ?fees:Exchange_core.Fee_schedule.t
  -> unit
  -> Exchange.Config.t

(** Hyperliquid's self-trade prevention: [Expire_maker]. A taker that reaches its own
    resting order cancels that order (reported as [selfTradeCanceled]) and keeps matching
    behind it. *)
val self_trade : Order_book.Stp.t

(** An exchange with {!config} and {!self_trade}. *)
val create_exchange
  :  ?meta:Meta.t
  -> ?fees:Exchange_core.Fee_schedule.t
  -> unit
  -> Exchange.t

(** The universe in asset index order. *)
val meta : Exchange.t -> Meta.t

(** {2 Exchange endpoint} *)

(** Unknown assets are rejected here; everything else is placed on the engine. A trigger
    order ([{"trigger": {"isMarket", "triggerPx", "tpsl"}}]) becomes an engine trigger
    order ({!Exchange_core_engine.Exchange.place_trigger}) that fires on the mark price: a
    limit order at [limitPx] (GTC), or with [isMarket] a market order with Hyperliquid's
    10% slippage tolerance, measured from the best opposite price when it fires. It
    answers [resting] with its order id. *)
val place_order : Exchange.t -> Address.t -> Order_request.t -> Order_status.t

(** [place_order], with the [orderUpdates] message Hyperliquid sends for an order the
    matching engine rejects: status ["badAloPxRejected"], ["iocCancelRejected"],
    ["minTradeNtlRejected"], ["perpMarginRejected"], ["reduceOnlyRejected"],
    ["tickRejected"], ... ({!reject_status}). Front-end rejections (unknown asset) have no
    order id and get none. *)
val place_order_with_update
  :  Exchange.t
  -> Address.t
  -> Order_request.t
  -> Order_status.t * Order_update.t option

(** The [orderUpdates] status of an order rejected for [reason]. *)
val reject_status : Exchange_core.Reject_reason.t -> Order_update.Status.t

(** An IOC order priced [slippage_bps] (default from config) through the best opposite
    price, as Hyperliquid's SDKs submit market orders. *)
val market_order
  :  ?slippage_bps:int
  -> ?reduce_only:bool
  -> ?cloid:Cloid.t
  -> Exchange.t
  -> Address.t
  -> coin:Coin.t
  -> side:Side.t
  -> sz:Size.t
  -> Order_status.t

val cancel : Exchange.t -> Address.t -> Cancel_request.t -> Cancel_status.t
val cancel_by_cloid : Exchange.t -> Address.t -> Cancel_by_cloid.t -> Cancel_status.t

(** Cancels the target (a resting or trigger order) and places the replacement, which may
    be a trigger order, with a new oid. A replacement for an unknown asset is rejected
    without cancelling the target. *)
val modify : Exchange.t -> Address.t -> Modify_request.t -> Order_status.t

(** {2 Info endpoint} *)

val l2_book : ?n_levels:int -> Exchange.t -> Coin.t -> L2_book.t option
val all_mids : Exchange.t -> All_mids.t

(** Resting and trigger orders, newest first. *)
val open_orders : Exchange.t -> Address.t -> Open_order.t list

(** Fills, newest first. *)
val user_fills : Exchange.t -> Address.t -> User_fill.t list

val clearinghouse_state : Exchange.t -> Address.t -> Clearinghouse_state.t

(** {2 Conversions} *)

(** Hyperliquid's wording for a rejection, with the [" asset=N"] suffix where Hyperliquid
    adds one ([coin]'s index in [meta]). *)
val reject_message : Meta.t -> ?coin:Coin.t -> Exchange_core.Reject_reason.t -> string

val order_status
  :  Meta.t
  -> coin:Coin.t option
  -> Exchange_core.Order_status.t
  -> Order_status.t

(** ["Open Long"], ["Close Short"], ["Long > Short"], ... *)
val dir : Exchange_core_engine.Position.Direction.t -> string

val open_order : Exchange_core.Open_order.t -> Open_order.t
val user_fill : Exchange_core_engine.Execution.t -> User_fill.t

(** A deterministic placeholder transaction hash derived from the trade id. *)
val hash : Order_book.Fill.t -> string

(** The public trade as streamed on the [trades] channel. *)
val trade : Order_book.Fill.t -> Trade.t

val l2 : Exchange_core.L2.t -> L2_book.t
val clearinghouse_state_of_view : Exchange_core.Account_view.t -> Clearinghouse_state.t

(** The [orderUpdates] message for the order's owner, if the event is an order update.
    Liquidation cancels are ["liquidatedCanceled"], self-trade cancels
    ["selfTradeCanceled"]. Rejections are not events with an order; see
    {!place_order_with_update}. *)
val order_update : Exchange_core_engine.Event.t -> (Address.t * Order_update.t) option

(** The [orderUpdates] message for a trigger order's owner: ["open"] when placed,
    ["triggered"] when the mark reaches it (the placed order's own updates follow), and
    the cancel statuses of {!order_update}. *)
val trigger_order_update
  :  Exchange_core_engine.Trigger_event.t
  -> Address.t * Order_update.t
