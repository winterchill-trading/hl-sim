(** Accounts, positions and cross margin for all users.

    Margin model (cross margin only, one-way positions):
    - account value = balance + unrealised PnL at mark over all positions;
    - initial margin of a position = [|szi| * mark / leverage], where leverage is the
      account's per-coin setting (default [min 20 maxLeverage]);
    - maintenance margin = [|szi| * mark / (2 * maxLeverage)];
    - an account whose account value falls below its maintenance margin is liquidated by
      closing all of its positions at mark (no liquidator, no backstop vault).

    Marks are supplied by the caller as a lookup; when a coin has no mark the position's
    entry price is used. *)

open! Core
open! Hl_protocol

type t [@@deriving sexp_of]

(** [default_leverage] is capped by each coin's [max_leverage]. *)
val create : ?fees:Fee_schedule.t -> ?default_leverage:int -> Meta.t -> t

val meta : t -> Meta.t
val fees : t -> Fee_schedule.t

(** Total fees charged so far. *)
val fees_collected : t -> Usd.t

(** The account, created with a zero balance if new. *)
val account : t -> Address.t -> Account.t

val find_account : t -> Address.t -> Account.t option

(** All accounts, sorted by address. *)
val accounts : t -> Account.t list

(** Credits (or debits, if negative) the account's balance. *)
val deposit : t -> Address.t -> Usd.t -> unit

(** Raises for coins not in the universe. *)
val max_leverage : t -> Coin.t -> int

val leverage : t -> Address.t -> Coin.t -> int

(** Sets cross leverage for a coin; fails unless [1 <= leverage <= max_leverage]. *)
val set_leverage : t -> Address.t -> Coin.t -> int -> unit Or_error.t

type mark = Coin.t -> Price.t option

val account_value : t -> Address.t -> mark:mark -> Usd.t

(** Initial margin used by positions. *)
val margin_used : t -> Address.t -> mark:mark -> Usd.t

val maintenance_margin : t -> Address.t -> mark:mark -> Usd.t

(** Initial margin an order of [sz] at [px] would need: only the part that increases the
    position's absolute size is charged. *)
val order_margin
  :  t
  -> Address.t
  -> coin:Coin.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> Usd.t

(** Checks that [account value - margin used - reserved] covers [order_margin]. [reserved]
    is the margin held by the account's other resting orders. *)
val check_order_margin
  :  t
  -> Address.t
  -> coin:Coin.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> reserved:Usd.t
  -> mark:mark
  -> unit Or_error.t

(** The largest size on [side] that only reduces the current position (zero if flat or if
    [side] would increase it). *)
val reduce_only_size : t -> Address.t -> coin:Coin.t -> side:Side.t -> Size.t

module Settlement : sig
  (** One side of a settled fill. *)
  type t =
    { address : Address.t
    ; side : Side.t
    ; crossed : bool (** taker *)
    ; fee : Usd.t
    ; change : Position.Change.t
    }
  [@@deriving sexp_of]
end

(** Applies a fill to both accounts: updates positions, realises PnL into balances and
    charges fees. Returns [(taker, maker)]. *)
val settle_fill : t -> Fill.t -> Settlement.t * Settlement.t

module Liquidation : sig
  type t =
    { address : Address.t
    ; coin : Coin.t
    ; szi : Size.t (** position closed *)
    ; px : Price.t
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

(** Liquidates every account whose account value is below its maintenance margin by
    closing all its positions at mark. Returns one entry per closed position. *)
val mark_to_market : t -> mark:mark -> Liquidation.t list

module Funding_payment : sig
  type t =
    { address : Address.t
    ; coin : Coin.t
    ; szi : Size.t
    ; payment : Usd.t (** paid by the account if positive, received if negative *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** Charges every position in [coin] [szi * mark * rate]: with a positive rate longs pay
    and shorts receive. Zero-sum whenever open interest is balanced. *)
val apply_funding
  :  t
  -> coin:Coin.t
  -> rate:float
  -> mark:Price.t
  -> Funding_payment.t list

(** The [clearinghouseState] view of an account. [time] is in milliseconds. *)
val state : t -> Address.t -> mark:mark -> time:int -> Clearinghouse_state.t
