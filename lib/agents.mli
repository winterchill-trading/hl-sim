(** Per-account approvals: API wallets (agents) and builder fee caps, plus the nonce sets
    of the signers the simulator verifies.

    Rules, as on Hyperliquid:
    - an account has at most one unnamed agent and three named ones; approving a new
      unnamed agent deregisters the previous unnamed one, and approving a name already in
      use replaces that agent;
    - an agent signs for one account only;
    - nonces are tracked per signer (the agent for agent-signed actions, the owner for
      user-signed ones): the 100 highest are kept, and a new nonce must be unused, larger
      than the smallest kept one, and within (now - 2 days, now + 1 day);
    - an account approves at most 10 builders at once (a rate of 0 revokes), each for up
      to 1% (the spot cap; perps orders are further capped at 0.1% per order).

    Rejections carry the message returned to the client. Hyperliquid documents the rules
    but not every error string; the ones marked "sim wording" in the implementation are
    ours. *)

open! Core
open! Hl_protocol

type t

val create : unit -> t

(** [approve_agent t ~user ~agent ~name] registers [agent] for [user] ([name] [None] for
    the unnamed agent). A name ending in [" valid_until <ms>"] names the agent by the part
    before it and makes it expire at that time, as on Hyperliquid. *)
val approve_agent
  :  t
  -> user:Address.t
  -> agent:Address.t
  -> name:string option
  -> (unit, string) Result.t

(** The account an agent signs for; [None] once the agent has expired at [now_ms]. *)
val owner : ?now_ms:int -> t -> Address.t -> Address.t option

module Agent : sig
  type t =
    { name : string option
    ; address : Address.t
    ; valid_until : int option (** milliseconds *)
    }
  [@@deriving sexp_of]

  (** An [extraAgents] row: [{"name": "...", "address": "0x...", "validUntil": ...}]
      ([validUntil] is far in the future for an agent without expiry). *)
  val to_json : t -> Yojson.Safe.t
end

(** The account's agents, unnamed first, then by name. *)
val agents : t -> Address.t -> Agent.t list

(** Checks [nonce] against [signer]'s nonce set and records it. [now_ms] is the exchange
    clock in milliseconds. *)
val use_nonce
  :  t
  -> signer:Address.t
  -> nonce:int
  -> now_ms:int
  -> (unit, string) Result.t

(** [approve_builder_fee t ~user ~builder ~tenths_bps] sets the cap; 0 revokes. *)
val approve_builder_fee
  :  t
  -> user:Address.t
  -> builder:Address.t
  -> tenths_bps:int
  -> (unit, string) Result.t

(** The approved cap in tenths of a basis point, 0 when none (the [maxBuilderFee] info
    response). *)
val max_builder_fee : t -> user:Address.t -> builder:Address.t -> int
