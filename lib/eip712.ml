open! Core
open! Hl_protocol
module Keccak = Hl_client.Keccak
module Signing = Hl_client.Signing

module Value = struct
  type t =
    | String of string
    | Address of Address.t
    | Uint64 of int
end

let to_hex s = String.concat_map s ~f:(fun c -> sprintf "%02x" (Char.to_int c))

let word_of_int n =
  String.init 32 ~f:(fun i ->
    if i < 24 then '\x00' else Char.of_int_exn ((n asr (8 * (31 - i))) land 0xff))
;;

let address_word address =
  let hex = String.chop_prefix_exn (Address.to_string address) ~prefix:"0x" in
  String.make 12 '\x00'
  ^ String.init 20 ~f:(fun i ->
    Char.of_int_exn (Int.of_string ("0x" ^ String.sub hex ~pos:(2 * i) ~len:2)))
;;

let type_name : Value.t -> string = function
  | String _ -> "string"
  | Address _ -> "address"
  | Uint64 _ -> "uint64"
;;

let encode : Value.t -> string = function
  | String s -> Keccak.digest s
  | Address a -> address_word a
  | Uint64 n -> word_of_int n
;;

let domain_separator ~chain_id =
  Keccak.digest
    (String.concat
       [ Keccak.digest
           "EIP712Domain(string name,string version,uint256 chainId,address \
            verifyingContract)"
       ; Keccak.digest "HyperliquidSignTransaction"
       ; Keccak.digest "1"
       ; word_of_int chain_id
       ; String.make 32 '\x00'
       ])
;;

let digest ~primary_type ~chain_id fields =
  let type_string =
    sprintf
      "%s(%s)"
      primary_type
      (String.concat
         ~sep:","
         (List.map fields ~f:(fun (name, v) -> type_name v ^ " " ^ name)))
  in
  let struct_hash =
    Keccak.digest
      (String.concat
         (Keccak.digest type_string :: List.map fields ~f:(fun (_, v) -> encode v)))
  in
  Keccak.digest (String.concat [ "\x19\x01"; domain_separator ~chain_id; struct_hash ])
;;

let chain_id_of_hex hex =
  match String.chop_prefix hex ~prefix:"0x" with
  | Some digits when (not (String.is_empty digits)) && String.length digits <= 15 ->
    Or_error.try_with (fun () -> Int.of_string ("0x" ^ digits))
  | _ -> Or_error.error_s [%message "invalid signatureChainId" hex]
;;

let recover ~digest json =
  let open Or_error.Let_syntax in
  let%bind signature =
    Or_error.try_with (fun () -> Signing.Signature.t_of_yojson json)
    |> Or_error.tag ~tag:"malformed signature"
  in
  Signing.recover ~digest signature
;;
