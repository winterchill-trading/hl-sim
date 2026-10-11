(** A cross-margin trading account: a USD balance plus one position per coin. The balance
    already includes realised PnL, fees and funding; account value adds unrealised PnL at
    mark (see [Clearinghouse]). *)

open! Core
open! Hl_protocol

type t = private
  { address : Address.t
  ; mutable balance : Usd.t
  ; positions : Position.t Coin.Table.t
  ; leverage : int Coin.Table.t (** per-coin leverage overrides *)
  }
[@@deriving sexp_of]

val create : Address.t -> t
val add_balance : t -> Usd.t -> unit

(** The position in [coin], if not flat. *)
val position : t -> Coin.t -> Position.t option

(** The position record in [coin], created flat if absent. *)
val position_or_create : t -> Coin.t -> Position.t

(** Non-flat positions, sorted by coin. *)
val open_positions : t -> Position.t list

val set_leverage : t -> Coin.t -> int -> unit
val leverage : t -> Coin.t -> int option
