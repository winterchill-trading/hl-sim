open! Core
open! Hl_protocol
open! Hl_sim

(* Vectors produced by eth_account's [encode_typed_data] and [sign_message] with the
   Hyperliquid SDK's type lists, for the throwaway keys 0x11..11 (user) and 0x22..22
   (agent). They have never held funds anywhere. *)
let vectors = lazy (Yojson.Safe.from_file "fixtures/user_signed.json")
let member key json = Yojson.Safe.Util.member key json
let str json = Yojson.Safe.Util.to_string json

let check name ~primary_type ~fields =
  let v = member name (force vectors) in
  let action = member "action" v in
  let chain_id =
    ok_exn (Eip712.chain_id_of_hex (str (member "signatureChainId" action)))
  in
  let digest = Eip712.digest ~primary_type ~chain_id (fields action) in
  let signer = Eip712.recover ~digest (member "signature" v) in
  print_s
    [%message
      name
        ~digest_matches:
          (String.equal (Eip712.to_hex digest) (str (member "digest" v)) : bool)
        (signer : Address.t Or_error.t)]
;;

let agent_fields action =
  [ "hyperliquidChain", Eip712.Value.String (str (member "hyperliquidChain" action))
  ; "agentAddress", Address (Address.of_string (str (member "agentAddress" action)))
  ; ( "agentName"
    , String
        (match member "agentName" action with
         | `Null -> ""
         | name -> str name) )
  ; "nonce", Uint64 (Yojson.Safe.Util.to_int (member "nonce" action))
  ]
;;

let%expect_test "digests and signers match eth_account" =
  print_s [%sexp (str (member "user" (force vectors)) : string)];
  [%expect {| 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a |}];
  check
    "agent_named"
    ~primary_type:"HyperliquidTransaction:ApproveAgent"
    ~fields:agent_fields;
  check
    "agent_unnamed"
    ~primary_type:"HyperliquidTransaction:ApproveAgent"
    ~fields:agent_fields;
  check
    "builder_fee"
    ~primary_type:"HyperliquidTransaction:ApproveBuilderFee"
    ~fields:(fun action ->
      [ "hyperliquidChain", Eip712.Value.String (str (member "hyperliquidChain" action))
      ; "maxFeeRate", String (str (member "maxFeeRate" action))
      ; "builder", Address (Address.of_string (str (member "builder" action)))
      ; "nonce", Uint64 (Yojson.Safe.Util.to_int (member "nonce" action))
      ]);
  [%expect
    {|
    (agent_named (digest_matches true)
     (signer (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    (agent_unnamed (digest_matches true)
     (signer (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    (builder_fee (digest_matches true)
     (signer (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    |}]
;;

let%expect_test "chain ids" =
  List.iter [ "0x66eee"; "0xa4b1"; "66eee"; "0x"; "0xzz" ] ~f:(fun hex ->
    print_s [%sexp (hex : string), (Eip712.chain_id_of_hex hex : int Or_error.t)]);
  [%expect
    {|
    (0x66eee (Ok 421614))
    (0xa4b1 (Ok 42161))
    (66eee (Error ("invalid signatureChainId" 66eee)))
    (0x (Error ("invalid signatureChainId" 0x)))
    (0xzz (Error (Failure "Int.of_string: \"0xzz\"")))
    |}]
;;
