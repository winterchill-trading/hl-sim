(** Hyperliquid's user-signed exchange actions that the copy-trading flow needs, which
    {!Hl_protocol.Exchange_action} does not model yet:

    {v
{"type": "approveAgent", "signatureChainId": "0x66eee", "hyperliquidChain": "Testnet",
 "agentAddress": "0x...", "agentName": "copy", "nonce": 1700000000000}
{"type": "approveBuilderFee", "signatureChainId": "0x66eee",
 "hyperliquidChain": "Testnet", "maxFeeRate": "0.01%", "builder": "0x...",
 "nonce": 1700000000000}
    v}

    Both are signed by the account owner with EIP-712 ({!Eip712}), not by an agent. An
    absent [agentName] (the SDK deletes it after signing an unnamed agent) is signed as
    the empty string. Keys are encoded in the SDK's order. *)

open! Core
open! Hl_protocol

module Approve_agent : sig
  type t =
    { signature_chain_id : string
    ; hyperliquid_chain : string (** ["Mainnet"] or ["Testnet"] *)
    ; agent_address : Address.t
    ; agent_name : string option (** [None] (or [""]) for the unnamed agent *)
    ; nonce : int
    }
  [@@deriving sexp, compare, equal]
end

module Approve_builder_fee : sig
  type t =
    { signature_chain_id : string
    ; hyperliquid_chain : string
    ; max_fee_rate : string (** a percentage, e.g. ["0.01%"] *)
    ; builder : Address.t
    ; nonce : int
    }
  [@@deriving sexp, compare, equal]
end

type t =
  | Approve_agent of Approve_agent.t
  | Approve_builder_fee of Approve_builder_fee.t
[@@deriving sexp, compare, equal, yojson]

(** [None] when the action's ["type"] is not one of these; raises on a malformed one. *)
val of_action_json : Yojson.Safe.t -> t option

val nonce : t -> int
val type_tag : t -> string

(** The EIP-712 digest the owner signed. *)
val digest : t -> string Or_error.t

(** The address that signed [t] with [signature]. *)
val signer : t -> signature:Yojson.Safe.t -> Address.t Or_error.t
