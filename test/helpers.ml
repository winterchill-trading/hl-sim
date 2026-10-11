open! Core
open! Hl_protocol
open! Hl_sim

let addr n = Address.of_string (sprintf "0x%040x" n)
let px = Price.of_string
let sz = Size.of_string
let usd = Usd.of_string
let btc = Coin.of_string "BTC"
