open! Core
open! Hl_protocol
open! Hl_sim

(** [addr n] is the address [0x00...0n]. *)
val addr : int -> Address.t

val px : string -> Price.t
val sz : string -> Size.t
val usd : string -> Usd.t
val btc : Coin.t
