(** EIP-712 digests of Hyperliquid's user-signed actions ([approveAgent],
    [approveBuilderFee], transfers), which the account owner signs with its wallet rather
    than through the L1 phantom-agent scheme of orders:

    {v
domain  = {name: "HyperliquidSignTransaction", version: "1",
           chainId: <signatureChainId>, verifyingContract: 0x0}
message = {hyperliquidChain: "Mainnet" | "Testnet", ...action fields..., nonce}
    v}

    The field list and order of each action type come from the official SDKs
    ([sign_agent], [sign_approve_builder_fee]). *)

open! Core
open! Hl_protocol

module Value : sig
  type t =
    | String of string (** hashed with Keccak-256 *)
    | Address of Address.t (** left-padded to 32 bytes *)
    | Uint64 of int (** big-endian, 32 bytes *)
end

(** [digest ~primary_type ~chain_id fields] is the 32-byte digest
    [keccak256(0x19 0x01 || domainSeparator || hashStruct(message))], with [primary_type]
    like ["HyperliquidTransaction:ApproveAgent"] and [fields] in the type's declared
    order. *)
val digest : primary_type:string -> chain_id:int -> (string * Value.t) list -> string

(** ["0x66eee"] is 421614. *)
val chain_id_of_hex : string -> int Or_error.t

(** The address whose key produced [signature] (an [{r, s, v}] JSON object) over [digest]. *)
val recover : digest:string -> Yojson.Safe.t -> Address.t Or_error.t

(** Lowercase hex without a prefix, for printing digests. *)
val to_hex : string -> string
