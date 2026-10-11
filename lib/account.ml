open! Core
open! Hl_protocol

type t =
  { address : Address.t
  ; mutable balance : Usd.t
  ; positions : Position.t Coin.Table.t
  ; leverage : int Coin.Table.t
  }
[@@deriving sexp_of]

let create address =
  { address
  ; balance = Usd.zero
  ; positions = Coin.Table.create ()
  ; leverage = Coin.Table.create ()
  }
;;

let add_balance t usd = t.balance <- Usd.( + ) t.balance usd

let position t coin =
  match Hashtbl.find t.positions coin with
  | Some p when not (Position.is_flat p) -> Some p
  | _ -> None
;;

let position_or_create t coin =
  Hashtbl.find_or_add t.positions coin ~default:(fun () -> Position.create coin)
;;

let open_positions t =
  Hashtbl.data t.positions
  |> List.filter ~f:(fun p -> not (Position.is_flat p))
  |> List.sort ~compare:(fun (a : Position.t) b -> Coin.compare a.coin b.coin)
;;

let set_leverage t coin lev = Hashtbl.set t.leverage ~key:coin ~data:lev
let leverage t coin = Hashtbl.find t.leverage coin
