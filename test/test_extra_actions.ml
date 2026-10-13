open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let start = 1_700_000_000_000_000_000
let mm = Helpers.addr 0xaa
let taker = Helpers.addr 0xab

let order ?(cloid = "") ~is_buy ~px () =
  sprintf
    {|{"a":0,"b":%b,"p":"%s","s":"0.01","r":false,"t":{"limit":{"tif":"Gtc"}}%s}|}
    is_buy
    px
    (if String.is_empty cloid then "" else sprintf {|,"c":"%s"|} cloid)
;;

let cloid = "0x00000000000000000000000000000001"

let%expect_test "updateLeverage, batchModify, scheduleCancel and orderStatus" =
  Log.Global.set_output [];
  let path = Filename_unix.temp_file "hl-sim-extra" ".jsonl" in
  let%bind journal = Journal.open_file path in
  let clock = ref start in
  let server =
    Server.create ~now:(fun () -> !clock) ~journal (Adapt.create_exchange ())
  in
  let exchange ?(who = mm) action =
    print_endline
      (Yojson.Safe.to_string
         (Exchange_response.yojson_of_t
            (Server.handle_exchange_json
               server
               ~x_address:(Some who)
               (Yojson.Safe.from_string (sprintf {|{"action":%s,"nonce":1}|} action)))))
  in
  let info body =
    print_endline
      (Yojson.Safe.to_string
         (Server.handle_info_json server (Yojson.Safe.from_string body)))
  in
  exchange {|{"type":"updateLeverage","asset":0,"isCross":true,"leverage":10}|};
  exchange {|{"type":"updateLeverage","asset":0,"isCross":true,"leverage":41}|};
  exchange {|{"type":"updateLeverage","asset":0,"isCross":false,"leverage":5}|};
  exchange {|{"type":"updateLeverage","asset":9,"isCross":true,"leverage":5}|};
  [%expect
    {|
    {"status":"ok","response":{"type":"default"}}
    {"status":"err","response":"Invalid leverage value."}
    {"status":"err","response":"Isolated margin is not supported."}
    {"status":"err","response":"Asset 9 does not exist."}
    |}];
  exchange
    (sprintf
       {|{"type":"order","orders":[%s,%s],"grouping":"na"}|}
       (order ~is_buy:false ~px:"101000" ())
       (order ~cloid ~is_buy:false ~px:"102000" ()));
  exchange
    (sprintf
       {|{"type":"batchModify","modifies":[{"oid":1,"order":%s},{"oid":"%s","order":%s},{"oid":99,"order":%s}]}|}
       (order ~is_buy:false ~px:"100500" ())
       cloid
       (order ~cloid ~is_buy:false ~px:"100600" ())
       (order ~is_buy:false ~px:"100700" ()));
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}},{"resting":{"oid":2,"cloid":"0x00000000000000000000000000000001"}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":3}},{"resting":{"oid":4,"cloid":"0x00000000000000000000000000000001"}},{"error":"Cannot modify canceled or filled order"}]}}}
    |}];
  (* The taker lifts one order; the maker's position is at 10x. *)
  exchange
    ~who:taker
    (sprintf
       {|{"type":"order","orders":[%s],"grouping":"na"}|}
       (order ~is_buy:true ~px:"100500" ()));
  info (sprintf {|{"type":"clearinghouseState","user":"%s"}|} (Address.to_string mm));
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100500","oid":5}}]}}}
    {"assetPositions":[{"type":"oneWay","position":{"coin":"BTC","szi":"-0.01","entryPx":"100500","positionValue":"1005","unrealizedPnl":"0","liquidationPx":"98864676.4691358","leverage":{"type":"cross","value":10},"marginUsed":"100.5","maxLeverage":40}}],"marginSummary":{"accountValue":"999999.84925","totalNtlPos":"1005","totalRawUsd":"999999.84925","totalMarginUsed":"100.5"},"crossMarginSummary":{"accountValue":"999999.84925","totalNtlPos":"1005","totalRawUsd":"999999.84925","totalMarginUsed":"100.5"},"crossMaintenanceMarginUsed":"12.5625","withdrawable":"999899.34925","time":1700000000000}
    |}];
  exchange {|{"type":"scheduleCancel","time":1700000003000}|};
  exchange {|{"type":"scheduleCancel","time":1700000010000}|};
  [%expect
    {|
    {"status":"err","response":"Scheduled cancel time too early, must be at least 5 seconds from now."}
    {"status":"ok","response":{"type":"default"}}
    |}];
  clock := start + 11_000_000_000;
  Server.mutate server ~f:ignore;
  List.iter
    [ "3"; "4"; sprintf {|"%s"|} cloid; "77" ]
    ~f:(fun oid ->
      info
        (sprintf
           {|{"type":"orderStatus","user":"%s","oid":%s}|}
           (Address.to_string mm)
           oid));
  [%expect
    {|
    {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"100500","sz":"0","oid":3,"timestamp":1700000000000,"orderType":"Limit","isTrigger":false,"triggerPx":"0.0","triggerCondition":"N/A","children":[],"isPositionTpsl":false,"reduceOnly":false,"tif":null},"status":"filled","statusTimestamp":1700000000000}}
    {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"100600","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01","cloid":"0x00000000000000000000000000000001","orderType":"Limit","isTrigger":false,"triggerPx":"0.0","triggerCondition":"N/A","children":[],"isPositionTpsl":false,"reduceOnly":false,"tif":null},"status":"scheduledCancel","statusTimestamp":1700000011000}}
    {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"100600","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01","cloid":"0x00000000000000000000000000000001","orderType":"Limit","isTrigger":false,"triggerPx":"0.0","triggerCondition":"N/A","children":[],"isPositionTpsl":false,"reduceOnly":false,"tif":null},"status":"scheduledCancel","statusTimestamp":1700000011000}}
    {"status":"unknownOid"}
    |}];
  let%bind () = Journal.close journal in
  let%bind records = Journal.load path in
  let replayed, _ = Server.replay (Adapt.create_exchange ()) records in
  (* Positions and margin; [time] differs, as the replay's clock stops at the last record. *)
  let state server =
    let json =
      Server.handle_info_json
        server
        (`Assoc [ "type", `String "clearinghouseState"; "user", Address.yojson_of_t mm ])
    in
    Yojson.Safe.Util.(member "assetPositions" json, member "marginSummary" json)
  in
  print_s
    [%message
      ""
        ~records:(List.length records : int)
        ~same_state:([%equal: Json.t * Json.t] (state server) (state replayed) : bool)];
  [%expect {| ((records 9) (same_state true)) |}];
  Unix.unlink path
;;
