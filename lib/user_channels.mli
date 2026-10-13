(** Account websocket channels that {!Hl_protocol.Subscription} does not model, open to
    any address as on Hyperliquid (this is how a follower watches a leader):

    - [{"type": "webData2", "user": "0x..."}], channel ["webData2"]: a lite version of the
      web frontend's account snapshot,
      [{"clearinghouseState": {...}, "openOrders": [...], "serverTime": ms, "user": "0x..."}]
      (the real message also carries spot balances, vault equities, asset contexts and
      more); sent on subscribe and then every second.
    - [{"type": "userEvents", "user": "0x..."}], channel ["user"]: [{"fills": [...]}] with
      the account's fills as they happen ({!Hl_protocol.User_event}); funding, liquidation
      and non-user-cancel events are not sent. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

module Kind : sig
  type t =
    | Web_data2
    | User_events
  [@@deriving sexp_of, compare, equal]
end

module Request : sig
  type t =
    { subscribe : bool
    ; kind : Kind.t
    ; user : Address.t
    }
  [@@deriving sexp_of, equal]

  (** [None] for anything other than a [webData2] or [userEvents] (un)subscription. *)
  val of_json : Yojson.Safe.t -> t option

  val to_json : t -> Yojson.Safe.t

  (** The [subscriptionResponse] echo. *)
  val response : t -> Yojson.Safe.t
end

(** The [webData2] message for [user]. *)
val web_data2 : Exchange.t -> Address.t -> Yojson.Safe.t

(** The [user] channel message carrying [fills]. *)
val user_fills_event : User_fill.t list -> Yojson.Safe.t
