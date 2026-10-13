open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange

let now () = 1_700_000_000_000_000_000
let user = Helpers.addr 0xaa
let maker = Helpers.addr 0xbb

let exchange server ~address body =
  Server.handle_exchange_json
    server
    ~x_address:(Some address)
    (Yojson.Safe.from_string (sprintf {|{"action": %s, "nonce": 1}|} body))
  |> Exchange_response.yojson_of_t
  |> Yojson.Safe.to_string
  |> print_endline
;;

let info server body =
  Server.handle_info_json server (Yojson.Safe.from_string body)
  |> Yojson.Safe.to_string
  |> print_endline
;;

let order ~b ~p ~s ?(r = false) t =
  sprintf
    {|{"type": "order", "grouping": "na", "orders": [{"a": 0, "b": %b, "p": "%s", "s": "%s", "r": %b, "t": %s}]}|}
    b
    p
    s
    r
    t
;;

let set_mark server p =
  Server.mutate server ~f:(fun ex -> Exchange.set_mark ex Helpers.btc (Helpers.px p))
;;

let%expect_test "a stop-loss rests, fires on the mark and reports triggered" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"orderUpdates","user":"%s"}}|}
       (Address.to_string user));
  let%bind () = Ws_helpers.receive incoming in
  (* The user goes long 0.01 BTC at 100000; the maker also bids at 99000. *)
  exchange
    server
    ~address:maker
    (order ~b:false ~p:"100000" ~s:"0.01" {|{"limit": {"tif": "Gtc"}}|});
  exchange
    server
    ~address:maker
    (order ~b:true ~p:"99000" ~s:"0.02" {|{"limit": {"tif": "Gtc"}}|});
  exchange
    server
    ~address:user
    (order ~b:true ~p:"100000" ~s:"0.01" {|{"limit": {"tif": "Ioc"}}|});
  set_mark server "100000";
  let%bind () = Ws_helpers.receive incoming in
  [%expect
    {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"orderUpdates","user":"0x00000000000000000000000000000000000000aa"}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":2}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":3}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"B","limitPx":"100000","sz":"0","oid":3,"timestamp":1700000000000,"origSz":"0.01"},"status":"filled","statusTimestamp":1700000000000}]}
    |}];
  exchange
    server
    ~address:user
    (order
       ~b:false
       ~p:"95000"
       ~s:"0.01"
       ~r:true
       {|{"trigger": {"isMarket": true, "triggerPx": "99500", "tpsl": "sl"}}|});
  let%bind () = Ws_helpers.receive incoming in
  info server (sprintf {|{"type": "openOrders", "user": "%s"}|} (Address.to_string user));
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":4}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"95000","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    [{"coin":"BTC","side":"A","limitPx":"95000","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01"}]
    |}];
  set_mark server "99600";
  info
    server
    (sprintf {|{"type": "orderStatus", "user": "%s", "oid": 4}|} (Address.to_string user));
  [%expect
    {| {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"95000","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01","orderType":"Stop Market","isTrigger":true,"triggerPx":"99500","triggerCondition":"Price below 99500","children":[],"isPositionTpsl":false,"reduceOnly":true,"tif":null},"status":"open","statusTimestamp":1700000000000}} |}];
  set_mark server "99500";
  let%bind () = Ws_helpers.receive incoming in
  info
    server
    (sprintf {|{"type": "orderStatus", "user": "%s", "oid": 4}|} (Address.to_string user));
  info
    server
    (sprintf {|{"type": "clearinghouseState", "user": "%s"}|} (Address.to_string user));
  [%expect
    {|
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"95000","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01"},"status":"triggered","statusTimestamp":1700000000000},{"order":{"coin":"BTC","side":"A","limitPx":"89100","sz":"0","oid":4,"timestamp":1700000000000,"origSz":"0.01"},"status":"filled","statusTimestamp":1700000000000}]}
    {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"89100","sz":"0","oid":4,"timestamp":1700000000000,"origSz":"0.01","orderType":"Stop Market","isTrigger":true,"triggerPx":"99500","triggerCondition":"Price below 99500","children":[],"isPositionTpsl":false,"reduceOnly":true,"tif":null},"status":"filled","statusTimestamp":1700000000000}}
    {"assetPositions":[],"marginSummary":{"accountValue":"999989.1045","totalNtlPos":"0","totalRawUsd":"999989.1045","totalMarginUsed":"0"},"crossMarginSummary":{"accountValue":"999989.1045","totalNtlPos":"0","totalRawUsd":"999989.1045","totalMarginUsed":"0"},"crossMaintenanceMarginUsed":"0","withdrawable":"999989.1045","time":1700000000000}
    |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;

let%expect_test "take-profit limit orders: cancel and modify" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"orderUpdates","user":"%s"}}|}
       (Address.to_string user));
  let%bind () = Ws_helpers.receive incoming in
  [%expect
    {| {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"orderUpdates","user":"0x00000000000000000000000000000000000000aa"}}} |}];
  set_mark server "100000";
  let tp px =
    order
      ~b:false
      ~p:"101000"
      ~s:"0.01"
      (sprintf {|{"trigger": {"isMarket": false, "triggerPx": "%s", "tpsl": "tp"}}|} px)
  in
  exchange server ~address:user (tp "100800");
  let%bind () = Ws_helpers.receive incoming in
  exchange server ~address:user {|{"type": "cancel", "cancels": [{"a": 0, "o": 1}]}|};
  let%bind () = Ws_helpers.receive incoming in
  exchange server ~address:user (tp "100800");
  let%bind () = Ws_helpers.receive incoming in
  exchange
    server
    ~address:user
    (sprintf
       {|{"type": "modify", "oid": 2, "order": %s}|}
       (Yojson.Safe.to_string
          (Yojson.Safe.Util.member "orders" (Yojson.Safe.from_string (tp "100900"))
           |> Yojson.Safe.Util.index 0)));
  let%bind () = Ws_helpers.receive incoming in
  info
    server
    (sprintf {|{"type": "orderStatus", "user": "%s", "oid": 3}|} (Address.to_string user));
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":1,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    {"status":"ok","response":{"type":"cancel","data":{"statuses":["success"]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":1,"timestamp":1700000000000,"origSz":"0.01"},"status":"canceled","statusTimestamp":1700000000000}]}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":2}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":2,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    {"status":"ok","response":{"type":"default"}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":2,"timestamp":1700000000000,"origSz":"0.01"},"status":"canceled","statusTimestamp":1700000000000},{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    {"status":"order","order":{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01","orderType":"Take Profit Limit","isTrigger":true,"triggerPx":"100900","triggerCondition":"Price above 100900","children":[],"isPositionTpsl":false,"reduceOnly":false,"tif":null},"status":"open","statusTimestamp":1700000000000}}
    |}];
  set_mark server "100900";
  let%bind () = Ws_helpers.receive incoming in
  info server (sprintf {|{"type": "openOrders", "user": "%s"}|} (Address.to_string user));
  [%expect
    {|
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01"},"status":"triggered","statusTimestamp":1700000000000},{"order":{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    [{"coin":"BTC","side":"A","limitPx":"101000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01"}]
    |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;
