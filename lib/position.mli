(** One account's position in one coin (one-way mode). *)

open! Core
open! Hl_protocol

type t = private
  { coin : Coin.t
  ; mutable szi : Size.t (** signed: positive long, negative short *)
  ; mutable entry_px : Price.t (** volume-weighted average entry; meaningless when flat *)
  ; mutable realized_pnl : Usd.t (** cumulative closed PnL, before fees and funding *)
  ; mutable cum_funding : Usd.t (** cumulative funding paid (positive) or received *)
  }
[@@deriving sexp_of]

val create : Coin.t -> t
val is_flat : t -> bool

(** Result of applying a fill to a position. *)
module Change : sig
  type t =
    { start_position : Size.t
    ; closed_pnl : Usd.t
    ; dir : string
    (** Hyperliquid's direction label: ["Open Long"], ["Close Short"], ["Long > Short"],
        ... *)
    }
  [@@deriving sexp_of]
end

(** Applies a trade of [sz] (positive) on [side] at [px]: increases move the entry price
    to the weighted average, reductions realise PnL against the entry price, and a flip
    closes the old position and opens the remainder at [px]. *)
val apply_trade : t -> side:Side.t -> px:Price.t -> sz:Size.t -> Change.t

(** Signed notional [szi * mark]. *)
val notional : t -> mark:Price.t -> Usd.t

val unrealized_pnl : t -> mark:Price.t -> Usd.t

(** Closes the whole position at [px], returning the realised PnL. *)
val close_at : t -> px:Price.t -> Usd.t

(** Records a funding payment (positive = paid by this position). *)
val add_funding : t -> Usd.t -> unit
