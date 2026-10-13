open! Core
open! Async
open! Hl_sim

let%expect_test "a websocket the server has sent nothing to is closed; pings keep it open"
  =
  Log.Global.set_output [];
  let config =
    { Server.Config.default with ws_idle_timeout = Time_ns.Span.of_int_ms 200 }
  in
  let server = Server.create ~config (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind quiet_in, _quiet_out = Ws_helpers.connect (Server.port http) in
  let%bind pinging_in, pinging_out = Ws_helpers.connect (Server.port http) in
  let rec ping n =
    if n = 0
    then return ()
    else (
      Pipe.write_without_pushback pinging_out {|{"method":"ping"}|};
      let%bind () = Ws_helpers.receive pinging_in in
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
      Server.close_idle_connections server;
      ping (n - 1))
  in
  let%bind () = ping 4 in
  [%expect
    {|
    {"channel":"pong"}
    {"channel":"pong"}
    {"channel":"pong"}
    {"channel":"pong"}
    |}];
  let%bind () = Ws_helpers.receive quiet_in in
  print_endline (Yojson.Safe.to_string (Server.status server));
  [%expect {|
    <eof>
    {"ws_connections":1,"ws_dropped":0,"ws_idle_closed":1}
    |}];
  Pipe.close pinging_out;
  Cohttp_async.Server.close http
;;
