open! Core
open! Hl_protocol

let scale = 100_000_000

let mul_units a b =
  let sign = if Bool.equal (a < 0) (b < 0) then 1 else -1 in
  let a = abs a
  and b = abs b in
  (* Split both operands into integer and fractional parts so that every partial
     product stays well inside 63 bits. *)
  let a1 = a / scale
  and a0 = a % scale
  and b1 = b / scale
  and b0 = b % scale in
  sign * ((a1 * b1 * scale) + (a1 * b0) + (a0 * b1) + (a0 * b0 / scale))
;;

let div_units a b =
  if b = 0 then raise_s [%message "Fixed_math.div_units: division by zero"];
  let sign = if Bool.equal (a < 0) (b < 0) then 1 else -1 in
  let a = abs a
  and b = abs b in
  (* Long division, one decimal digit at a time, so [r * 10] never overflows. *)
  let rec loop q r digits =
    if digits = 0
    then q
    else (
      let r = r * 10 in
      loop ((q * 10) + (r / b)) (r % b) (digits - 1))
  in
  sign * loop (a / b) (a % b) 8
;;

let notional px sz = Usd.of_units (mul_units (Price.to_units px) (Size.to_units sz))

let avg_price ~notional ~size =
  Price.of_units (div_units (Usd.to_units notional) (Size.to_units size))
;;

let usd_times_rate usd ~rate = Usd.of_units (mul_units (Usd.to_units usd) rate)
let div_int usd n = Usd.of_units (Usd.to_units usd / n)
let rate_of_float r = Float.iround_nearest_exn (r *. Float.of_int scale)
let rate_of_bps bps = rate_of_float (bps /. 10_000.)
let price_to_usd px = Usd.of_units (Price.to_units px)
