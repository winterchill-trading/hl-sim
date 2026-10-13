open! Core
open! Async
open! Hl_sim

let%expect_test "GET /status" =
  Log.Global.set_output [];
  let server = Server.create ~now:(fun () -> 0) (Adapt.create_exchange ()) in
  Server.add_status server ~name:"anchors" (fun () -> `List [ `String "hyperliquid:BTC" ]);
  let%bind http = Server.listen server ~port:0 in
  let uri =
    Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Server.port http) ~path:"/status" ()
  in
  let%bind response, body = Cohttp_async.Client.get uri in
  let%bind body = Cohttp_async.Body.to_string body in
  printf "%d %s\n" (Cohttp.Code.code_of_status (Cohttp.Response.status response)) body;
  [%expect
    {| 200 {"ws_connections":0,"ws_dropped":0,"ws_idle_closed":0,"anchors":["hyperliquid:BTC"]} |}];
  Cohttp_async.Server.close http
;;
