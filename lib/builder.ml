open! Core
open! Hl_protocol
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

type t = Builder_fee.t =
  { builder : Address.t
  ; fee_tenths_bp : int
  }
[@@deriving sexp, compare, equal]

let yojson_of_t = Builder_fee.yojson_of_t
let t_of_yojson = Builder_fee.t_of_yojson
let max_perp_fee = 100
let min_builder_account_value = Usd.of_int 100

let of_action_json json =
  match Json.member json ~key:"builder" with
  | None | Some `Null -> None
  | Some b -> Some (t_of_yojson b)
;;

let fee t ~px ~sz =
  Usd.of_units (Usd.to_units (Notional.mul px sz) * t.fee_tenths_bp / 100_000)
;;

let tenths_bps_of_rate = Builder_fee.tenths_bp_of_percent
