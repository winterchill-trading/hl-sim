(** Leaderboard rows computed from the simulated accounts, in the shape of Hyperliquid's
    stats endpoint ({!Hl_protocol.Leaderboard}):

    {v
{"leaderboardRows": [
  {"ethAddress": "0x...", "accountValue": "1000123.5",
   "windowPerformances": [["day", {"pnl": "123.5", "roi": "0.0001235", "vlm": "250000.0"}],
                          ["week", {...}], ["month", {...}], ["allTime", {...}]],
   "prize": 0, "displayName": null}, ...]}
    v}

    For a window of length [w] ending now (day, week = 7 days, month = 30 days, rolling
    like Hyperliquid's; all time):
    - [pnl] is the change in account value minus net deposits over the window;
    - [roi] is [pnl] divided by the account value at the window start plus the deposits
      made during it;
    - [vlm] is the traded notional, both sides counted for the account's own fills.

    Account values are sampled from the exchange clock every [sample_interval] (default
    one minute), so a window's start is resolved to that grain; samples older than 31 days
    are dropped. Rows are every account that received a deposit (simulated users, noise
    traders, leaders), sorted by account value, largest first. *)

open! Core
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

type t

val create : ?sample_interval:Time_ns.Span.t -> unit -> t

(** A deposit (or withdrawal, negative) into [account]: not PnL. *)
val record_deposit : t -> Address.t -> Usd.t -> unit

(** Notional traded by [account] in one fill. *)
val record_volume : t -> Address.t -> Usd.t -> unit

(** Samples every account's value if [sample_interval] has passed on the exchange clock
    since the last sample. *)
val sample : t -> Exchange.t -> unit

module Window : sig
  type t =
    | Day
    | Week
    | Month
    | All_time
  [@@deriving sexp_of, enumerate]

  val to_wire : t -> string
end

module Performance : sig
  type t =
    { pnl : Usd.t
    ; roi : float
    ; vlm : Usd.t
    }
  [@@deriving sexp_of]
end

module Row : sig
  type t =
    { address : Address.t
    ; account_value : Usd.t
    ; windows : (Window.t * Performance.t) list
    }
  [@@deriving sexp_of]
end

val rows : t -> Exchange.t -> Row.t list

(** [{"leaderboardRows": [...]}]. *)
val to_json : Row.t list -> Yojson.Safe.t
