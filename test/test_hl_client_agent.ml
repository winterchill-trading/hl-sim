(* hl-client's copy-trading calls against the simulator over HTTP: the owner approves an
   agent and a builder, then the agent's handle trades for the owner with a builder fee.
   Throwaway keys 0x11..11 (owner), 0x22..22 (agent) and 0x33..33 (a maker), never funded
   anywhere. *)

open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Client = Hl_client.Client
module Signing = Hl_client.Signing

let key c = ok_exn (Signing.Private_key.of_hex (String.make 64 c))
let builder = Helpers.addr 0xbb

let order ~is_buy ~px : Order_request.t =
  { asset = Asset.of_int 0
  ; is_buy
  ; limit_px = Helpers.px px
  ; sz = Helpers.sz "0.01"
  ; reduce_only = false
  ; order_type = Limit { tif = Gtc }
  ; cloid = None
  }
;;

let show response =
  print_endline
    (match response with
     | Ok r -> Yojson.Safe.to_string (Exchange_response.yojson_of_t r)
     | Error e -> Error.to_string_hum e)
;;

let%expect_test "approve an agent and a builder with hl-client, then trade as the agent" =
  Log.Global.set_output [];
  (* The wall clock, since hl-client's nonces are wall-clock milliseconds. Strict
     signatures: [X-Address] is ignored, so the agent's order can only reach the owner's
     account through the agent approval. *)
  let server =
    Server.create
      ~config:{ Server.Config.default with strict_signatures = true }
      (Adapt.create_exchange ())
  in
  let%bind http = Server.listen server ~port:0 in
  let config () =
    Hl_client.Config.create
      ~base_url:(Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Server.port http) ())
      ()
  in
  let owner = Client.trading ~key:(key '1') (config ()) in
  let account = Signing.Private_key.address (key '1') in
  let agent_key = key '2' in
  let%bind r =
    Client.approve_agent
      owner
      ~agent_address:(Signing.Private_key.address agent_key)
      ~agent_name:"copy"
  in
  show r;
  let%bind r = Client.approve_builder_fee owner ~builder ~max_fee_tenths_bp:10 in
  show r;
  [%expect
    {|
    {"status":"ok","response":{"type":"default"}}
    {"status":"ok","response":{"type":"default"}}
    |}];
  let%bind r =
    Client.place_orders
      (Client.trading ~key:(key '3') (config ()))
      [ order ~is_buy:false ~px:"100000" ]
  in
  show r;
  let agent = Client.trading_with_agent ~agent_key ~account_address:account (config ()) in
  let%bind r =
    Client.place_orders
      ~builder:{ builder; fee_tenths_bp = 10 }
      agent
      [ order ~is_buy:true ~px:"100000" ]
  in
  show r;
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":2}}]}}}
    |}];
  let%bind fills = Client.user_fills (Client.to_read_only agent) in
  print_s
    [%message
      ""
        ~account_fills:(List.length (ok_exn fills) : int)
        ~builder_credited:
          ((Server.leaderboard server |> Leaderboard.t_of_yojson).leaderboard_rows
           |> List.find ~f:(fun r -> Address.equal r.eth_address builder)
           |> Option.map ~f:(fun r -> r.account_value)
           : float option)];
  [%expect {| ((account_fills 1) (builder_credited (1000000.1))) |}];
  Cohttp_async.Server.close http
;;
