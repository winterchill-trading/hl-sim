open! Core
open! Hl_protocol
open Ppx_yojson_conv_lib.Yojson_conv.Primitives
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

type t =
  { b : Address.t
  ; f : int
  }
[@@deriving sexp, compare, equal, yojson] [@@yojson.allow_extra_fields]

let max_perp_fee = 100
let min_builder_account_value = Usd.of_int 100

let of_action_json json =
  match Json.member json ~key:"builder" with
  | None | Some `Null -> None
  | Some b -> Some (t_of_yojson b)
;;

let fee t ~px ~sz = Usd.of_units (Usd.to_units (Notional.mul px sz) * t.f / 100_000)

let tenths_bps_of_rate rate =
  let error () = Or_error.error_s [%message "invalid maxFeeRate" rate] in
  match String.chop_suffix (String.strip rate) ~suffix:"%" with
  | None -> error ()
  | Some pct ->
    (* 1% is 1000 tenths of a bp, so three decimals of the percentage are whole units. *)
    (match Usd.of_string_opt pct with
     | None -> error ()
     | Some pct ->
       let units = Usd.to_units pct * 1000 in
       if Usd.is_negative pct || units % Usd.units_per_one <> 0
       then error ()
       else Ok (units / Usd.units_per_one))
;;
