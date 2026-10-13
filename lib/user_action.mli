(** Hyperliquid's user-signed exchange actions that the copy-trading flow needs
    ([approveAgent], [approveBuilderFee]), as {!Hl_protocol.User_signed_action.t}, with
    what the simulator adds: recognising them in a [POST /exchange] body and recovering
    the signer.

    Both are signed by the account owner with EIP-712 ({!Eip712}), not by an agent. An
    absent [agentName] (the SDK deletes it after signing an unnamed agent) is signed as
    the empty string. *)

open! Core
open! Hl_protocol

type t = User_signed_action.t [@@deriving sexp, compare, equal, yojson]

(** [None] when the action's ["type"] is not one of these; raises on a malformed one. *)
val of_action_json : Yojson.Safe.t -> t option

val nonce : t -> int
val type_tag : t -> string

(** The EIP-712 digest the owner signed. *)
val digest : t -> string Or_error.t

(** The address that signed [t] with [signature]. *)
val signer : t -> signature:Yojson.Safe.t -> Address.t Or_error.t
