open! Core
open! Hl_protocol
open! Hl_sim

let%expect_test "userRole: user, agent and missing" =
  let server =
    Server.create ~now:(fun () -> 1_700_000_000_000_000_000) (Adapt.create_exchange ())
  in
  let user = Helpers.addr 1
  and agent = Helpers.addr 2
  and stranger = Helpers.addr 3 in
  Server.ensure_account server user;
  ok_exn
    (Agents.approve_agent (Server.agents server) ~user ~agent ~name:None
     |> Result.map_error ~f:Error.of_string);
  List.iter [ user; agent; stranger ] ~f:(fun a ->
    Server.handle_info_json
      server
      (`Assoc [ "type", `String "userRole"; "user", Address.yojson_of_t a ])
    |> Yojson.Safe.to_string
    |> print_endline);
  [%expect
    {|
    {"role":"user"}
    {"role":"agent","data":{"user":"0x0000000000000000000000000000000000000001"}}
    {"role":"missing"}
    |}]
;;
