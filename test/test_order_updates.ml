open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let now () = 1_700_000_000_000_000_000
let mm = Helpers.addr 0xaa

let order ~is_buy ~px ~tif : Exchange_request.t =
  { action =
      Order
        { orders =
            [ { asset = Asset.of_int 0
              ; is_buy
              ; limit_px = Helpers.px px
              ; sz = Helpers.sz "0.01"
              ; reduce_only = false
              ; order_type = Limit { tif }
              ; cloid = None
              }
            ]
        ; grouping = Na
        }
  ; nonce = 1
  ; signature = None
  ; vault_address = None
  }
;;

let%expect_test "rejected orders reach orderUpdates with Hyperliquid's statuses" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"orderUpdates","user":"%s"}}|}
       (Address.to_string mm));
  let%bind () = Ws_helpers.receive incoming in
  [%expect
    {| {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"orderUpdates","user":"0x00000000000000000000000000000000000000aa"}}} |}];
  let place ~is_buy ~px ~tif =
    print_endline
      (Yojson.Safe.to_string
         (Exchange_response.yojson_of_t
            (Server.handle_exchange server mm (order ~is_buy ~px ~tif))))
  in
  place ~is_buy:false ~px:"100000" ~tif:Gtc;
  let%bind () = Ws_helpers.receive incoming in
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"100000","sz":"0.01","oid":1,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    |}];
  (* A post-only bid at the ask, an IOC bid below it, and a price off the tick. *)
  place ~is_buy:true ~px:"100000" ~tif:Alo;
  let%bind () = Ws_helpers.receive incoming in
  place ~is_buy:true ~px:"99000" ~tif:Ioc;
  let%bind () = Ws_helpers.receive incoming in
  place ~is_buy:true ~px:"99000.05" ~tif:Gtc;
  let%bind () = Ws_helpers.receive incoming in
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Post only order would have immediately matched, bbo was none@100000. asset=0"}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"B","limitPx":"100000","sz":"0.01","oid":2,"timestamp":1700000000000,"origSz":"0.01"},"status":"badAloPxRejected","statusTimestamp":1700000000000}]}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Order could not immediately match against any resting orders. asset=0"}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"B","limitPx":"99000","sz":"0.01","oid":3,"timestamp":1700000000000,"origSz":"0.01"},"status":"iocCancelRejected","statusTimestamp":1700000000000}]}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Price must be divisible by tick size. asset=0"}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"B","limitPx":"99000.05","sz":"0.01","oid":4,"timestamp":1700000000000,"origSz":"0.01"},"status":"tickRejected","statusTimestamp":1700000000000}]}
    |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;

let%expect_test "liquidation cancels are liquidatedCanceled" =
  let order : Exchange_core.Open_order.t =
    { symbol = Coin.of_string "BTC"
    ; side = Buy
    ; px = Helpers.px "100"
    ; size = Helpers.sz "1"
    ; orig_size = Some (Helpers.sz "1")
    ; order_id = Order_id.of_int 7
    ; client_order_id = None
    ; timestamp = 0
    }
  in
  List.iter
    [ Exchange_core_engine.Event.Cancel_reason.Liquidated; Self_trade; User ]
    ~f:(fun reason ->
      Adapt.order_update (Order_cancelled { account = mm; order; reason; time = 0 })
      |> Option.iter ~f:(fun (_, (u : Order_update.t)) ->
        print_endline (Order_update.Status.to_wire u.status)));
  [%expect {|
    liquidatedCanceled
    selfTradeCanceled
    canceled
    |}];
  return ()
;;

let%expect_test "a bid through the user's own ask expires the ask" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"orderUpdates","user":"%s"}}|}
       (Address.to_string mm));
  let%bind () = Ws_helpers.receive incoming in
  let place ~is_buy ~px ~tif =
    print_endline
      (Yojson.Safe.to_string
         (Exchange_response.yojson_of_t
            (Server.handle_exchange server mm (order ~is_buy ~px ~tif))))
  in
  place ~is_buy:false ~px:"100000" ~tif:Gtc;
  let%bind () = Ws_helpers.receive incoming in
  [%expect {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"orderUpdates","user":"0x00000000000000000000000000000000000000aa"}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"100000","sz":"0.01","oid":1,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    |}];
  (* Hyperliquid cancels the resting order and lets the new one rest; no error. *)
  place ~is_buy:true ~px:"100000" ~tif:Gtc;
  let%bind () = Ws_helpers.receive incoming in
  [%expect {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":2}}]}}}
    {"channel":"orderUpdates","data":[{"order":{"coin":"BTC","side":"A","limitPx":"100000","sz":"0.01","oid":1,"timestamp":1700000000000,"origSz":"0.01"},"status":"selfTradeCanceled","statusTimestamp":1700000000000},{"order":{"coin":"BTC","side":"B","limitPx":"100000","sz":"0.01","oid":2,"timestamp":1700000000000,"origSz":"0.01"},"status":"open","statusTimestamp":1700000000000}]}
    |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;
