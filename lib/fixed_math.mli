(** Arithmetic across the hl-protocol fixed-point types ([Price], [Size], [Usd]), which
    all count units of [10^-8] but only expose addition. Products and quotients are
    computed on the raw units without overflowing for any value representable in the
    result type. All results truncate toward zero. *)

open! Hl_protocol

(** [10^8], the number of units in one. *)
val scale : int

(** [mul_units a b] is [a * b / scale], truncated toward zero. *)
val mul_units : int -> int -> int

(** [div_units a b] is [a * scale / b], truncated toward zero. Raises if [b = 0]. *)
val div_units : int -> int -> int

(** [notional px sz] is [px * sz] in USD, signed like [sz]. *)
val notional : Price.t -> Size.t -> Usd.t

(** [avg_price ~notional ~size] is [notional / size]. Raises if [size] is zero. *)
val avg_price : notional:Usd.t -> size:Size.t -> Price.t

(** [usd_times_rate usd ~rate] is [usd * rate] where [rate] is a dimensionless fraction in
    units of [10^-8] (so [rate = 3_500] is 0.035%). *)
val usd_times_rate : Usd.t -> rate:int -> Usd.t

(** [div_int usd n] is [usd / n] truncated toward zero. *)
val div_int : Usd.t -> int -> Usd.t

(** [rate_of_bps bps] converts basis points to a rate in units of [10^-8]. *)
val rate_of_bps : float -> int

(** [rate_of_float r] converts a fraction such as [0.0000125] to units of [10^-8]. *)
val rate_of_float : float -> int

val price_to_usd : Price.t -> Usd.t
