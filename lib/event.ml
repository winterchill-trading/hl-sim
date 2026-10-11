open! Core
open! Hl_protocol

module Cancel_reason = struct
  type t =
    | User
    | Modified
    | Ioc_unfilled
    | Self_trade
    | Liquidated
  [@@deriving sexp_of, compare, equal]
end

type t =
  | Order_accepted of
      { address : Address.t
      ; order : Open_order.t
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
      ; order : Open_order.t
      ; time : int
      }
  | Order_cancelled of
      { address : Address.t
      ; order : Open_order.t
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

let time = function
  | Order_accepted { time; _ }
  | Order_rejected { time; _ }
  | Order_filled { time; _ }
  | Order_cancelled { time; _ }
  | Liquidation { time; _ }
  | Funding { time; _ } -> time
  | Fill { fill; _ } -> fill.time
;;

let book_coin = function
  | Order_accepted { order; _ } | Order_cancelled { order; _ } -> Some order.coin
  | Fill { fill; _ } -> Some fill.coin
  | Order_rejected _ | Order_filled _ | Liquidation _ | Funding _ -> None
;;

let ms ns = ns / 1_000_000

let to_order_update t =
  let update address order status time =
    Some (address, { Order_update.order; status; status_timestamp = ms time })
  in
  match t with
  | Order_accepted { address; order; time } -> update address order Open time
  | Order_filled { address; order; time } -> update address order Filled time
  | Order_cancelled { address; order; reason; time } ->
    let status : Order_update.Status.t =
      match reason with
      | User | Modified | Ioc_unfilled -> Canceled
      | Self_trade -> Other "selfTradeCanceled"
      | Liquidated -> Margin_canceled
    in
    update address order status time
  | Order_rejected _ | Fill _ | Liquidation _ | Funding _ -> None
;;
