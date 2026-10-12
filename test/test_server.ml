open! Core
open! Async
open! Hl_protocol
open! Hl_sim

(* A fixed clock keeps every timestamp in the output deterministic. *)
let now () = 1_700_000_000_000_000_000
let mm = "0x00000000000000000000000000000000000000aa"

let with_server f =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind () = f (Server.port http) in
  Cohttp_async.Server.close http
;;

let post ?(headers = []) port path body =
  let uri = Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port ~path () in
  let%bind response, body =
    Cohttp_async.Client.post
      ~headers:(Cohttp.Header.of_list headers)
      ~body:(Cohttp_async.Body.of_string body)
      uri
  in
  let%map body = Cohttp_async.Body.to_string body in
  printf "%d %s\n" (Cohttp.Code.code_of_status (Cohttp.Response.status response)) body
;;

let order ~is_buy ~px ~sz =
  sprintf
    {|{"action":{"type":"order","orders":[{"a":0,"b":%b,"p":"%s","s":"%s","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}|}
    is_buy
    px
    sz
;;

let%expect_test "info and exchange over HTTP" =
  with_server (fun port ->
    let%bind () = post port "/info" {|{"type":"l2Book","coin":"BTC"}|} in
    [%expect {| 200 {"coin":"BTC","time":1700000000000,"levels":[[],[]]} |}];
    let%bind () =
      post
        port
        "/exchange"
        ~headers:[ "X-Address", mm ]
        (order ~is_buy:false ~px:"100000" ~sz:"0.001")
    in
    [%expect
      {| 200 {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}} |}];
    (* No X-Address: the default sim address trades. *)
    let%bind () = post port "/exchange" (order ~is_buy:true ~px:"100000" ~sz:"0.0004") in
    [%expect
      {| 200 {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.0004","avgPx":"100000","oid":2}}]}}} |}];
    let%bind () = post port "/info" {|{"type":"l2Book","coin":"BTC"}|} in
    [%expect
      {| 200 {"coin":"BTC","time":1700000000000,"levels":[[],[{"px":"100000","sz":"0.0006","n":1}]]} |}];
    let%bind () = post port "/info" (sprintf {|{"type":"openOrders","user":"%s"}|} mm) in
    [%expect
      {| 200 [{"coin":"BTC","side":"A","limitPx":"100000","sz":"0.0006","oid":1,"timestamp":1700000000000,"origSz":"0.001"}] |}];
    let%bind () = post port "/info" {|{"type":"nope"}|} in
    [%expect {| 400 {"error":"Info_request: unsupported request type"} |}];
    let%bind () = post port "/exchange" "not json" in
    [%expect {| 400 {"error":"Line 1, bytes 0-8:\nInvalid token 'not json'"} |}];
    return ())
;;

(* Websocket client handshake (async_websocket only implements framing). *)
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
    | `Ok line ->
      print_endline line;
      read_headers ()
  in
  let%map () = read_headers () in
  Websocket.pipes (Websocket.create ~opcode:`Text ~role:Client reader writer)
;;

let receive incoming =
  match%map Pipe.read incoming with
  | `Ok msg -> print_endline msg
  | `Eof -> print_endline "<eof>"
;;

let%expect_test "websocket l2Book subscription" =
  with_server (fun port ->
    let%bind incoming, outgoing = ws_connect port in
    [%expect
      {|
      HTTP/1.1 101 Switching Protocols
      upgrade: websocket
      connection: Upgrade
      sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
      |}];
    Pipe.write_without_pushback
      outgoing
      {|{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}|};
    let%bind () = receive incoming in
    [%expect
      {| {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}} |}];
    let%bind () = receive incoming in
    [%expect
      {| {"channel":"l2Book","data":{"coin":"BTC","time":1700000000000,"levels":[[],[]]}} |}];
    Pipe.write_without_pushback outgoing {|{"method":"ping"}|};
    let%bind () = receive incoming in
    [%expect {| {"channel":"pong"} |}];
    (* A book change is pushed after the coalescing delay. *)
    let%bind () =
      post
        port
        "/exchange"
        ~headers:[ "X-Address", mm ]
        (order ~is_buy:true ~px:"99000" ~sz:"0.001")
    in
    [%expect
      {| 200 {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}} |}];
    let%bind () = receive incoming in
    [%expect
      {| {"channel":"l2Book","data":{"coin":"BTC","time":1700000000000,"levels":[[{"px":"99000","sz":"0.001","n":1}],[]]}} |}];
    Pipe.close outgoing;
    return ())
;;
