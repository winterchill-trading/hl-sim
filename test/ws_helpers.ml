open! Core
open! Async

let connect port =
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
