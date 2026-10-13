open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let now () = 1_700_000_000_000_000_000
let leader = Helpers.addr 0x1ead
let maker = Helpers.addr 0xaa

let ws_connect port =
  let%bind _socket, reader, writer =
    Tcp.connect (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
  in
  Writer.write
    writer
    "GET /ws HTTP/1.1\r\n\
     Host: localhost\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
     Sec-WebSocket-Version: 13\r\n\
     \r\n";
  let rec read_headers () =
    match%bind Reader.read_line reader with
    | `Eof -> failwith "eof during handshake"
    | `Ok "" -> return ()
    | `Ok _ -> read_headers ()
  in
  let%map () = read_headers () in
  Websocket.pipes (Websocket.create ~opcode:`Text ~role:Client reader writer)
;;

let receive incoming =
  match%map Pipe.read incoming with
  | `Ok msg -> print_endline msg
  | `Eof -> print_endline "<eof>"
;;

let subscribe outgoing kind user =
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"%s","user":"%s"}}|}
       kind
       (Address.to_string user))
;;

let order ~is_buy ~px : Exchange_request.t =
  { action =
      Order
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
        }
  ; nonce = 1
  ; signature = None
  ; vault_address = None
  }
;;

let%expect_test "following another account: webData2, userEvents and the user limit" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = ws_connect (Server.port http) in
  subscribe outgoing "webData2" leader;
  let%bind () = receive incoming in
  let%bind () = receive incoming in
  [%expect
    {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"webData2","user":"0x0000000000000000000000000000000000001ead"}}}
    {"channel":"webData2","data":{"clearinghouseState":{"assetPositions":[],"marginSummary":{"accountValue":"1000000","totalNtlPos":"0","totalRawUsd":"1000000","totalMarginUsed":"0"},"crossMarginSummary":{"accountValue":"1000000","totalNtlPos":"0","totalRawUsd":"1000000","totalMarginUsed":"0"},"crossMaintenanceMarginUsed":"0","withdrawable":"1000000","time":1700000000000},"openOrders":[],"serverTime":1700000000000,"user":"0x0000000000000000000000000000000000001ead"}}
    |}];
  subscribe outgoing "userEvents" leader;
  let%bind () = receive incoming in
  [%expect
    {| {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"userEvents","user":"0x0000000000000000000000000000000000001ead"}}} |}];
  ignore
    (Server.handle_exchange server maker (order ~is_buy:false ~px:"100000")
     : Exchange_response.t);
  ignore
    (Server.handle_exchange server leader (order ~is_buy:true ~px:"100000")
     : Exchange_response.t);
  let%bind () = receive incoming in
  [%expect
    {| {"channel":"user","data":{"fills":[{"coin":"BTC","px":"100000","sz":"0.01","side":"B","time":1700000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","oid":2,"crossed":true,"fee":"0.35","tid":1,"feeToken":"USDC"}]}} |}];
  (* Nine more users fit (the leader is the first), the eleventh does not. *)
  List.iter (List.range 1 11) ~f:(fun i ->
    subscribe outgoing "userFills" (Helpers.addr (0xf00 + i)));
  let%bind () =
    Deferred.List.iter ~how:`Sequential (List.range 0 19) ~f:(fun _ ->
      match%map Pipe.read incoming with
      | `Ok msg -> if String.is_substring msg ~substring:"error" then print_endline msg
      | `Eof -> print_endline "<eof>")
  in
  [%expect {| {"channel":"error","data":"Cannot track more than 10 total users."} |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;
