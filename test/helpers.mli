open! Core
open! Hl_protocol
open! Hl_sim

(** [addr n] is the address [0x00...0n]. *)
val addr : int -> Address.t

val px : string -> Price.t
val sz : string -> Size.t
val usd : string -> Usd.t
val btc : Coin.t

(** An order book with oid, trade id and clock counters. *)
module Book : sig
  type t

  val create : unit -> t
  val book : t -> Order_book.t

  (** Places a limit order for account [owner] and returns its oid; prints the result. *)
  val limit
    :  ?quiet:bool
    -> ?tif:Tif.t
    -> t
    -> owner:int
    -> Side.t
    -> string
    -> string
    -> Order_id.t * Order_book.Result.t

  val market
    :  ?quiet:bool
    -> t
    -> owner:int
    -> Side.t
    -> string
    -> slippage_bps:int
    -> Order_book.Result.t

  val print_l2 : ?n_levels:int -> t -> unit
end

val print_result : Order_book.Result.t -> unit
