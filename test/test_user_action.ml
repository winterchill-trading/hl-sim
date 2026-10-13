open! Core
open! Hl_protocol
open! Hl_sim

let vectors = lazy (Yojson.Safe.from_file "fixtures/user_signed.json")
let member key json = Yojson.Safe.Util.member key json

let%expect_test "fixture actions decode, re-encode and recover the owner" =
  List.iter [ "agent_named"; "agent_unnamed"; "builder_fee" ] ~f:(fun name ->
    let v = member name (force vectors) in
    let action = Option.value_exn (User_action.of_action_json (member "action" v)) in
    print_s [%sexp (action : User_action.t)];
    print_endline (Yojson.Safe.to_string (User_action.yojson_of_t action));
    print_s
      [%sexp
        (User_action.signer action ~signature:(member "signature" v)
         : Address.t Or_error.t)]);
  [%expect
    {|
    (Approve_agent
     ((signature_chain_id 0x66eee) (hyperliquid_chain Testnet)
      (agent_address 0x1563915e194d8cfba1943570603f7606a3115508)
      (agent_name (copy)) (nonce 1700000000000)))
    {"type":"approveAgent","signatureChainId":"0x66eee","hyperliquidChain":"Testnet","agentAddress":"0x1563915e194d8cfba1943570603f7606a3115508","agentName":"copy","nonce":1700000000000}
    (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
    (Approve_agent
     ((signature_chain_id 0x66eee) (hyperliquid_chain Mainnet)
      (agent_address 0x1563915e194d8cfba1943570603f7606a3115508) (agent_name ())
      (nonce 1700000000000)))
    {"type":"approveAgent","signatureChainId":"0x66eee","hyperliquidChain":"Mainnet","agentAddress":"0x1563915e194d8cfba1943570603f7606a3115508","nonce":1700000000000}
    (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
    (Approve_builder_fee
     ((signature_chain_id 0x66eee) (hyperliquid_chain Testnet)
      (max_fee_rate 0.01%) (builder 0x00000000000000000000000000000000000000bb)
      (nonce 1700000000001)))
    {"type":"approveBuilderFee","signatureChainId":"0x66eee","hyperliquidChain":"Testnet","maxFeeRate":"0.01%","builder":"0x00000000000000000000000000000000000000bb","nonce":1700000000001}
    (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
    |}]
;;

let%expect_test "other actions and malformed ones" =
  let decode s = User_action.of_action_json (Yojson.Safe.from_string s) in
  print_s [%sexp (decode {|{"type":"order","orders":[]}|} : User_action.t option)];
  print_s
    [%sexp
      (Or_error.try_with (fun () -> decode {|{"type":"approveAgent","nonce":1}|})
       : User_action.t option Or_error.t)];
  [%expect
    {|
    ()
    (Error
     ("Of_yojson_error (Failure(\"User_action: missing field hyperliquidChain\"), {\"type\":\"approveAgent\",\"nonce\":1})"))
    |}]
;;
