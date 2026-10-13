open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Signing = Hl_client.Signing

(* The fixture approvals (test/fixtures/user_signed.json) carry nonces at this time, in
   milliseconds; the nonce window is checked against it. *)
let start = 1_700_000_000_000_000_000
let vectors = lazy (Yojson.Safe.from_file "fixtures/user_signed.json")
let member key json = Yojson.Safe.Util.member key json

(* Throwaway keys, never funded anywhere: user 0x11..11, agent 0x22..22. *)
let user = Address.of_string "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
let agent_key = ok_exn (Signing.Private_key.of_hex (String.init 64 ~f:(fun _ -> '2')))
let maker = Helpers.addr 0xaa
let builder = Address.of_string "0x00000000000000000000000000000000000000bb"

let fixture_request name =
  let v = member name (force vectors) in
  `Assoc
    [ "action", member "action" v
    ; "nonce", member "nonce" v
    ; "signature", member "signature" v
    ]
;;

let order_action ?builder_fee ~is_buy ~px () =
  let action =
    Exchange_action.yojson_of_t
      (Order
         { orders =
             [ { asset = Asset.of_int 0
               ; is_buy
               ; limit_px = Helpers.px px
               ; sz = Helpers.sz "0.01"
               ; reduce_only = false
               ; order_type = Limit { tif = Gtc }
               ; cloid = None
               }
             ]
         ; grouping = Na
         })
  in
  match builder_fee, action with
  | None, _ -> action
  | Some f, `Assoc fields ->
    `Assoc
      (fields @ [ "builder", `Assoc [ "b", Address.yojson_of_t builder; "f", `Int f ] ])
  | Some _, _ -> assert false
;;

(* An order signed by the agent key, as [Client.trading_with_agent] sends it. *)
let agent_signed ~nonce action =
  let signature =
    Signing.sign_l1_action agent_key ~is_mainnet:false ~vault_address:None ~nonce action
  in
  `Assoc
    [ "action", action
    ; "nonce", `Int nonce
    ; "signature", Signing.Signature.yojson_of_t signature
    ]
;;

let show response =
  print_endline (Yojson.Safe.to_string (Exchange_response.yojson_of_t response))
;;

let balances server =
  let ex = Server.handle_info server in
  List.map
    [ "user", user; "maker", maker; "builder", builder ]
    ~f:(fun (name, a) ->
      let json = ex (Clearinghouse_state { user = a }) in
      ( name
      , Yojson.Safe.Util.(member "marginSummary" json |> member "totalRawUsd")
        |> Yojson.Safe.Util.to_string ))
;;

let%expect_test "an agent trades for the account that approved it, with a builder fee" =
  Log.Global.set_output [];
  let path = Filename_unix.temp_file "hl-sim-copy" ".jsonl" in
  let%bind journal = Journal.open_file path in
  let server = Server.create ~now:(fun () -> start) ~journal (Adapt.create_exchange ()) in
  let exchange ?x_address body =
    show (Server.handle_exchange_json server ~x_address body)
  in
  (* Before approval the agent's signature means nothing: the order acts for the default
     address. *)
  exchange
    (agent_signed ~nonce:1_700_000_000_005 (order_action ~is_buy:true ~px:"90000" ()));
  [%expect
    {| {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}} |}];
  exchange (fixture_request "agent_named");
  [%expect {| {"status":"ok","response":{"type":"default"}} |}];
  print_s
    [%sexp
      (Agents.owner (Server.agents server) (Signing.Private_key.address agent_key)
       : Address.t option)];
  [%expect {| (0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a) |}];
  (* The same signed approval again: its nonce is spent. *)
  exchange (fixture_request "agent_named");
  [%expect
    {| {"status":"err","response":"Invalid nonce: 1700000000000 was already used."} |}];
  exchange
    ~x_address:maker
    (Exchange_request.yojson_of_t
       { action = Exchange_action.t_of_yojson (order_action ~is_buy:false ~px:"100000" ())
       ; nonce = 1
       ; signature = None
       ; vault_address = None
       });
  [%expect
    {| {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":2}}]}}} |}];
  let buy = order_action ~builder_fee:10 ~is_buy:true ~px:"100000" () in
  exchange (agent_signed ~nonce:1_700_000_000_010 buy);
  [%expect {| {"status":"err","response":"Builder fee has not been approved."} |}];
  exchange (fixture_request "builder_fee");
  [%expect {| {"status":"ok","response":{"type":"default"}} |}];
  exchange (agent_signed ~nonce:1_700_000_000_011 buy);
  [%expect
    {| {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":3}}]}}} |}];
  exchange
    (agent_signed
       ~nonce:1_700_000_000_012
       (order_action ~builder_fee:101 ~is_buy:true ~px:"100000" ()));
  exchange (agent_signed ~nonce:1_700_000_000_013 buy);
  (* A replayed signed order: the agent's nonce is spent. *)
  exchange (agent_signed ~nonce:1_700_000_000_013 buy);
  [%expect
    {|
    {"status":"err","response":"Builder fee is above the 0.1% perps limit."}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":4}}]}}}
    {"status":"err","response":"Invalid nonce: 1700000000013 was already used."}
    |}];
  print_s [%sexp (balances server : (string * string) list)];
  [%expect {| ((user 999999.45) (maker 999999.85) (builder 1000000.1)) |}];
  let info body =
    print_endline
      (Yojson.Safe.to_string
         (Server.handle_info_json server (Yojson.Safe.from_string body)))
  in
  info
    (sprintf
       {|{"type":"maxBuilderFee","user":"%s","builder":"%s"}|}
       (Address.to_string user)
       (Address.to_string builder));
  info (sprintf {|{"type":"extraAgents","user":"%s"}|} (Address.to_string user));
  info
    (sprintf
       {|{"type":"userFillsByTime","user":"%s","startTime":0}|}
       (Address.to_string user));
  [%expect
    {|
    10
    [{"name":"copy","address":"0x1563915e194d8cfba1943570603f7606a3115508","validUntil":4102444800000}]
    [{"coin":"BTC","px":"100000","sz":"0.01","side":"B","time":1700000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","oid":3,"crossed":true,"fee":"0.45","tid":1,"feeToken":"USDC"}]
    |}];
  let rows = Leaderboard.t_of_yojson (Server.leaderboard server) in
  List.iter rows.leaderboard_rows ~f:(fun row ->
    print_s
      [%sexp
        (row.eth_address : Address.t)
        , (row.account_value : float)
        , (Leaderboard.Row.performance row All_time : Leaderboard.Performance.t option)]);
  [%expect
    {|
    (0x00000000000000000000000000000000000000bb 1000000.1
     (((pnl 0.1) (roi 1E-07) (vlm 0))))
    (0x0000000000000000000000000000000000000001 1000000
     (((pnl 0) (roi 0) (vlm 0))))
    (0x00000000000000000000000000000000000000aa 999999.85
     (((pnl -0.15) (roi -1.5E-07) (vlm 1000))))
    (0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a 999999.45
     (((pnl -0.55) (roi -5.5E-07) (vlm 1000))))
    |}];
  let%bind () = Journal.close journal in
  let%bind records = Journal.load path in
  let replayed, _ = Server.replay (Adapt.create_exchange ()) records in
  print_s
    [%message
      ""
        ~records:(List.length records : int)
        ~same_balances:
          ([%equal: (string * string) list] (balances server) (balances replayed) : bool)];
  [%expect {| ((records 8) (same_balances true)) |}];
  Unix.unlink path
;;
