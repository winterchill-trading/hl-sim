(** Everything that happens on the exchange, in order. The websocket layer streams these
    ([trades], [orderUpdates], [userFills], [l2Book] after book-changing events). All
    [time] fields are nanoseconds from the exchange clock. *)

open! Core
open! Hl_protocol

module Cancel_reason : sig
  type t =
    | User (** cancel or cancelByCloid request *)
    | Modified (** replaced by a modify request *)
    | Ioc_unfilled (** IOC or market remainder *)
    | Self_trade (** taker remainder cancelled by self-trade prevention *)
    | Liquidated (** the account was liquidated *)
  [@@deriving sexp_of, compare, equal]
end

type t =
  | Order_accepted of
      { address : Address.t
      ; order : Open_order.t (** rests on the book with [sz] remaining *)
      ; time : int
      }
  | Order_rejected of
      { address : Address.t
      ; coin : Coin.t option
      ; cloid : Cloid.t option
      ; reason : string
      ; time : int
      }
  | Fill of
      { fill : Fill.t
      ; taker : User_fill.t
      ; maker : User_fill.t
      }
  | Order_filled of
      { address : Address.t
      ; order : Open_order.t (** [sz] is zero, [orig_sz] the original size *)
      ; time : int
      }
  | Order_cancelled of
      { address : Address.t
      ; order : Open_order.t (** [sz] is the size that was cancelled *)
      ; reason : Cancel_reason.t
      ; time : int
      }
  | Liquidation of
      { liquidation : Clearinghouse.Liquidation.t
      ; time : int
      }
  | Funding of
      { coin : Coin.t
      ; rate : float
      ; mark : Price.t
      ; payments : Clearinghouse.Funding_payment.t list
      ; time : int
      }
[@@deriving sexp_of]

val time : t -> int

(** The coin whose book changed, if any. *)
val book_coin : t -> Coin.t option

(** The [orderUpdates] message for the order's owner, if the event is an order update. *)
val to_order_update : t -> (Address.t * Order_update.t) option
