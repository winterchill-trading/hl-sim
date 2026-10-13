open! Core
open! Hl_protocol
open! Hl_sim

let user = Helpers.addr 0xaa
let maker = Helpers.addr 0xbb

let order server address ~is_buy ~sz ~tif =
  Server.handle_exchange
    server
    address
    { action =
        Order
          { orders =
              [ { asset = Asset.of_int 0
                ; is_buy
                ; limit_px = Helpers.px "100000"
                ; sz = Helpers.sz sz
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
  |> Exchange_response.yojson_of_t
  |> Yojson.Safe.to_string
  |> print_endline
;;

let leverage server n =
  Server.handle_extra_action
    server
    user
    (Update_leverage { asset = Asset.of_int 0; is_cross = true; leverage = n })
  |> Exchange_response.yojson_of_t
  |> Yojson.Safe.to_string
  |> print_endline
;;

let%expect_test "BTC above 150M USDC: 20x and tiered maintenance" =
  let server =
    Server.create
      ~config:{ Server.Config.default with initial_balance = Usd.of_int 100_000_000 }
      ~now:(fun () -> 1_700_000_000_000_000_000)
      (Adapt.create_exchange ())
  in
  leverage server 20;
  order server maker ~is_buy:false ~sz:"1600" ~tif:Gtc;
  order server user ~is_buy:true ~sz:"1600" ~tif:Ioc;
  (* 160M USDC of BTC is in the second tier: 40x is refused, 20x is fine. *)
  leverage server 40;
  leverage server 20;
  let state =
    Server.handle_info_json
      server
      (`Assoc [ "type", `String "clearinghouseState"; "user", Address.yojson_of_t user ])
  in
  (* 160M / 40 - 150M * (1/40 - 1/80) *)
  print_endline
    (Yojson.Safe.to_string (Yojson.Safe.Util.member "crossMaintenanceMarginUsed" state));
  [%expect
    {|
    {"status":"ok","response":{"type":"default"}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"1600","avgPx":"100000","oid":2}}]}}}
    {"status":"err","response":"Invalid leverage value."}
    {"status":"ok","response":{"type":"default"}}
    "2125000"
    |}]
;;
