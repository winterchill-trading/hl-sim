open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let mm = Helpers.addr 0xaa

let order ~is_buy ~px =
  Exchange_request.t_of_yojson
    (Yojson.Safe.from_string
       (sprintf
          {|{"action":{"type":"order","orders":[{"a":0,"b":%b,"p":"%d","s":"0.001","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}|}
          is_buy
          px))
;;

(* Twenty levels a side make every l2Book snapshot about 2KB. *)
let fill_book server =
  for i = 1 to 20 do
    List.iter
      [ order ~is_buy:true ~px:(99_000 - (i * 10))
      ; order ~is_buy:false ~px:(101_000 + (i * 10))
      ]
      ~f:(fun req -> ignore (Server.handle_exchange server mm req : Exchange_response.t))
  done
;;

(* A websocket client that sends but never reads its socket: frames go out through a
   client-side [Websocket] whose reader is an empty pipe, so nothing drains the socket's
   receive buffer. *)
let connect_without_reading port =
  let%bind _socket, reader, writer =
    Tcp.connect (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
  in
  (* The server hangs up while frames are still going out. *)
  Writer.set_raise_when_consumer_leaves writer false;
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
  let%bind () = read_headers () in
  let never_r, _never_w = Pipe.create () in
  let%map silent = Reader.of_pipe (Info.of_string "silent") never_r in
  let _incoming, outgoing =
    Websocket.pipes (Websocket.create ~opcode:`Text ~role:Client silent writer)
  in
  outgoing
;;

let post port body =
  let uri = Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port ~path:"/exchange" () in
  let%bind response, body =
    Cohttp_async.Client.post
      ~headers:
        (Cohttp.Header.of_list
           [ "X-Address", "0x00000000000000000000000000000000000000bb" ])
      ~body:(Cohttp_async.Body.of_string body)
      uri
  in
  let%map body = Cohttp_async.Body.to_string body in
  Cohttp.Code.code_of_status (Cohttp.Response.status response), body
;;

let rec wait_until ~deadline f =
  if f ()
  then return true
  else if Time_ns.(now () > deadline)
  then return false
  else (
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 10) in
    wait_until ~deadline f)
;;

let order_body =
  {|{"action":{"type":"order","orders":[{"a":0,"b":true,"p":"98000","s":"0.001","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}|}
;;

let after span = Time_ns.add (Time_ns.now ()) span

(* Floods a non-reading subscriber with snapshots while another client places an order.
   Prints whether the slow subscriber got dropped and returns the other client's ack
   latency. *)
let flood ~max_ws_queue ~wait =
  Log.Global.set_output [];
  let server =
    Server.create
      ~config:{ Server.Config.default with max_ws_queue }
      (Adapt.create_exchange ())
  in
  fill_book server;
  let%bind http = Server.listen server ~port:0 in
  let port = Server.port http in
  let%bind slow = connect_without_reading port in
  (* Each subscribe is answered with an echo and a ~2KB snapshot: 40MB in all, far more
     than the socket buffers hold. *)
  for _ = 1 to 20_000 do
    Pipe.write_without_pushback
      slow
      {|{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}|}
  done;
  let started = Time_ns.now () in
  let%bind status, _ = post port order_body in
  let ack = Time_ns.diff (Time_ns.now ()) started in
  let%bind (_ : bool) =
    wait_until ~deadline:(after wait) (fun () -> Server.num_ws_dropped server > 0)
  in
  print_s
    [%message
      (status : int)
        ~dropped:(Server.num_ws_dropped server : int)
        ~open_connections:(Server.num_ws_connections server : int)];
  Pipe.close slow;
  let%map () = Cohttp_async.Server.close http in
  ack
;;

let%expect_test "a subscriber that never reads is disconnected" =
  let%bind ack = flood ~max_ws_queue:200 ~wait:(Time_ns.Span.of_sec 3.) in
  [%expect {| ((status 200) (dropped 1) (open_connections 0)) |}];
  (* About 15-30ms on a laptop; the bound leaves room for slow CI machines. *)
  print_s [%message "" ~ack_under_500ms:(Time_ns.Span.(ack < of_int_ms 500) : bool)];
  [%expect {| (ack_under_500ms true) |}];
  return ()
;;

let%expect_test "without a bound the slow subscriber stays connected" =
  let%bind ack = flood ~max_ws_queue:Int.max_value ~wait:Time_ns.Span.second in
  [%expect {| ((status 200) (dropped 0) (open_connections 1)) |}];
  ignore (ack : Time_ns.Span.t);
  return ()
;;
