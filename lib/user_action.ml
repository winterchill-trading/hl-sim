open! Core
open! Hl_protocol

type t = User_signed_action.t [@@deriving sexp, compare, equal, yojson]

let of_action_json json =
  match Json.member json ~key:"type" with
  | Some (`String tag) when User_signed_action.is_user_signed_type tag ->
    Some (t_of_yojson json)
  | _ -> None
;;

let nonce = User_signed_action.nonce
let type_tag = User_signed_action.type_tag

let digest t =
  let open Or_error.Let_syntax in
  let module E = User_signed_action.Eip712 in
  let%map chain_id = Eip712.chain_id_of_hex (User_signed_action.signature_chain_id t) in
  Eip712.digest
    ~primary_type:(E.primary_type t)
    ~chain_id
    (List.map (E.fields t) ~f:(fun (name, (v : E.Value.t)) ->
       ( name
       , match v with
         | String s -> Eip712.Value.String s
         | Address a -> Address a
         | Uint64 n -> Uint64 n )))
;;

let signer t ~signature =
  let open Or_error.Let_syntax in
  let%bind digest = digest t in
  Eip712.recover ~digest signature
;;
