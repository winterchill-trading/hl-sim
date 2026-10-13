open! Core
open! Hl_protocol

module Approve_agent = struct
  type t =
    { signature_chain_id : string
    ; hyperliquid_chain : string
    ; agent_address : Address.t
    ; agent_name : string option
    ; nonce : int
    }
  [@@deriving sexp, compare, equal]
end

module Approve_builder_fee = struct
  type t =
    { signature_chain_id : string
    ; hyperliquid_chain : string
    ; max_fee_rate : string
    ; builder : Address.t
    ; nonce : int
    }
  [@@deriving sexp, compare, equal]
end

type t =
  | Approve_agent of Approve_agent.t
  | Approve_builder_fee of Approve_builder_fee.t
[@@deriving sexp, compare, equal]

let type_tag = function
  | Approve_agent _ -> "approveAgent"
  | Approve_builder_fee _ -> "approveBuilderFee"
;;

let nonce = function
  | Approve_agent { nonce; _ } | Approve_builder_fee { nonce; _ } -> nonce
;;

let yojson_of_t t =
  let common ~signature_chain_id ~hyperliquid_chain =
    [ "type", `String (type_tag t)
    ; "signatureChainId", `String signature_chain_id
    ; "hyperliquidChain", `String hyperliquid_chain
    ]
  in
  match t with
  | Approve_agent a ->
    `Assoc
      (common
         ~signature_chain_id:a.signature_chain_id
         ~hyperliquid_chain:a.hyperliquid_chain
       @ [ "agentAddress", Address.yojson_of_t a.agent_address ]
       @ Option.value_map a.agent_name ~default:[] ~f:(fun n ->
         [ "agentName", `String n ])
       @ [ "nonce", `Int a.nonce ])
  | Approve_builder_fee b ->
    `Assoc
      (common
         ~signature_chain_id:b.signature_chain_id
         ~hyperliquid_chain:b.hyperliquid_chain
       @ [ "maxFeeRate", `String b.max_fee_rate
         ; "builder", Address.yojson_of_t b.builder
         ; "nonce", `Int b.nonce
         ])
;;

let field json key =
  match Json.member json ~key with
  | Some v -> v
  | None -> Json.error (sprintf "User_action: missing field %s" key) json
;;

let string_field json key =
  match field json key with
  | `String s -> s
  | v -> Json.error (sprintf "User_action: %s must be a string" key) v
;;

let int_field json key =
  match field json key with
  | `Int n -> n
  | `Intlit s -> Int.of_string s
  | v -> Json.error (sprintf "User_action: %s must be an integer" key) v
;;

let of_action_json json =
  let chain () =
    string_field json "signatureChainId", string_field json "hyperliquidChain"
  in
  match Json.member json ~key:"type" with
  | Some (`String "approveAgent") ->
    let signature_chain_id, hyperliquid_chain = chain () in
    let agent_name =
      match Json.member json ~key:"agentName" with
      | None | Some `Null | Some (`String "") -> None
      | Some (`String n) -> Some n
      | Some v -> Json.error "User_action: agentName must be a string" v
    in
    Some
      (Approve_agent
         { signature_chain_id
         ; hyperliquid_chain
         ; agent_address = Address.t_of_yojson (field json "agentAddress")
         ; agent_name
         ; nonce = int_field json "nonce"
         })
  | Some (`String "approveBuilderFee") ->
    let signature_chain_id, hyperliquid_chain = chain () in
    Some
      (Approve_builder_fee
         { signature_chain_id
         ; hyperliquid_chain
         ; max_fee_rate = string_field json "maxFeeRate"
         ; builder = Address.t_of_yojson (field json "builder")
         ; nonce = int_field json "nonce"
         })
  | _ -> None
;;

let t_of_yojson json =
  match of_action_json json with
  | Some t -> t
  | None -> Json.error "User_action: unsupported action type" json
;;

let digest t =
  let open Or_error.Let_syntax in
  match t with
  | Approve_agent a ->
    let%map chain_id = Eip712.chain_id_of_hex a.signature_chain_id in
    Eip712.digest
      ~primary_type:"HyperliquidTransaction:ApproveAgent"
      ~chain_id
      [ "hyperliquidChain", String a.hyperliquid_chain
      ; "agentAddress", Address a.agent_address
      ; "agentName", String (Option.value a.agent_name ~default:"")
      ; "nonce", Uint64 a.nonce
      ]
  | Approve_builder_fee b ->
    let%map chain_id = Eip712.chain_id_of_hex b.signature_chain_id in
    Eip712.digest
      ~primary_type:"HyperliquidTransaction:ApproveBuilderFee"
      ~chain_id
      [ "hyperliquidChain", String b.hyperliquid_chain
      ; "maxFeeRate", String b.max_fee_rate
      ; "builder", Address b.builder
      ; "nonce", Uint64 b.nonce
      ]
;;

let signer t ~signature =
  let open Or_error.Let_syntax in
  let%bind digest = digest t in
  Eip712.recover ~digest signature
;;
