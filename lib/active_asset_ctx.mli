(** Hyperliquid's [activeAssetCtx] websocket channel for perps, which carries the funding
    rate, mark and oracle prices of one coin:

    {v
{"channel": "activeAssetCtx",
 "data": {"coin": "BTC",
          "ctx": {"funding": "0.0000125", "openInterest": "25000.1",
                  "prevDayPx": "112000.0", "dayNtlVlm": "1234567890.0",
                  "premium": "0.0001", "oraclePx": "113010.0", "markPx": "113020.0",
                  "midPx": "113015.5", "impactPxs": ["113015.0", "113016.0"],
                  "dayBaseVlm": "11000.0"}}}
    v}

    hl-protocol has no type for this channel yet, so it is defined here.

    How the simulator fills it in:
    - [funding]: the engine's rate for the next funding boundary;
    - [markPx]: the engine's mark; [oraclePx]: the same price, as the engine has no
      separate oracle (the market simulation sets the mark to its reference price);
    - [midPx] and [impactPxs]: book mid and best bid and ask ([null] and absent when the
      book is one-sided; impact notional is ignored);
    - [premium]: [(mid - oracle) / oracle], 0 without a mid;
    - [openInterest]: the sum of long positions;
    - [dayNtlVlm], [dayBaseVlm], [prevDayPx]: volume of the current UTC day of the
      exchange clock and the last trade price of the previous day (the mark if there was
      none); Hyperliquid uses a rolling 24 hours. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

type t =
  { coin : Coin.t
  ; funding : float
  ; open_interest : Size.t
  ; prev_day_px : Price.t
  ; day_ntl_vlm : Usd.t
  ; premium : float
  ; oracle_px : Price.t
  ; mark_px : Price.t
  ; mid_px : Price.t option
  ; impact_pxs : (Price.t * Price.t) option
  ; day_base_vlm : Size.t
  }
[@@deriving sexp_of]

(** The whole websocket message, [{"channel": "activeAssetCtx", "data": ...}]. *)
val to_ws_message : t -> Yojson.Safe.t

(** Per-coin traded volume of the current day, fed with every trade. *)
module Day_stats : sig
  type t

  val create : unit -> t
  val record_trade : t -> coin:Coin.t -> px:Price.t -> sz:Size.t -> time:int -> unit
end

(** The context of [coin] at the exchange's current time; [None] for an unknown coin or
    one without any price yet. *)
val of_exchange : Exchange.t -> Day_stats.t -> Coin.t -> t option

(** [{"method": "subscribe" | "unsubscribe", "subscription": {"type": "activeAssetCtx", "coin": C}}],
    which {!Hl_protocol.Ws_request} does not decode. *)
module Request : sig
  type t =
    { subscribe : bool (** [false] for [unsubscribe] *)
    ; coin : Coin.t
    }
  [@@deriving sexp_of, equal]

  (** [None] for anything other than an [activeAssetCtx] (un)subscription. *)
  val of_json : Yojson.Safe.t -> t option

  val to_json : t -> Yojson.Safe.t

  (** The [subscriptionResponse] echo of the request. *)
  val response : t -> Yojson.Safe.t
end
