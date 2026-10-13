open! Core
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange

let start = 1_700_000_000_000_000_000
let hour = 3_600 * 1_000_000_000
let minute = 60 * 1_000_000_000
let day = 24 * hour

module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

let maker = Helpers.addr 0xa0
let taker = Helpers.addr 0xa1

let order ex user ~is_buy ~px ~tif =
  ignore
    (Adapt.place_order
       ex
       user
       { asset = Asset.of_int 0
       ; is_buy
       ; limit_px = Helpers.px px
       ; sz = Helpers.sz "0.1"
       ; reduce_only = false
       ; order_type = Limit { tif }
       ; cloid = None
       }
     : Order_status.t)
;;

let%expect_test "windows over a simulated week" =
  let ex = Adapt.create_exchange () in
  Exchange.step ex ~now:start;
  let r = Rankings.create () in
  let deposit a usd =
    Exchange.deposit ex a usd;
    Rankings.record_deposit r a usd
  in
  let trade ~px =
    order ex maker ~is_buy:false ~px ~tif:Gtc;
    order ex taker ~is_buy:true ~px ~tif:Ioc;
    List.iter (Exchange.drain_events ex) ~f:(fun e ->
      Option.iter
        (Exchange_core_engine.Event.executions e)
        ~f:(fun ((t : Exchange_core_engine.Execution.t), m) ->
          let n = Notional.mul t.fill.px t.fill.sz in
          Rankings.record_volume r t.settlement.account n;
          Rankings.record_volume r m.settlement.account n))
  in
  deposit maker (Usd.of_int 100_000);
  deposit taker (Usd.of_int 100_000);
  Rankings.sample r ex;
  (* The taker buys at 100000 on day 0 and again on day 6 after a deposit; the mark is
     100500 on day 3 and 101000 at the end, so the taker is up and the maker (short) down.
     The day window starts from the day 3 sample, the others from the start. *)
  trade ~px:"100000";
  Exchange.step ex ~now:(start + (3 * day));
  Exchange.set_mark ex (Coin.of_string "BTC") (Helpers.px "100500");
  Rankings.sample r ex;
  Exchange.step ex ~now:(start + (6 * day));
  Rankings.sample r ex;
  deposit taker (Usd.of_int 50_000);
  trade ~px:"100000";
  Exchange.step ex ~now:(start + (6 * day) + (2 * hour));
  Exchange.set_mark ex (Coin.of_string "BTC") (Helpers.px "101000");
  Rankings.sample r ex;
  let rows = Rankings.rows r ex in
  print_s [%sexp (rows : Rankings.Row.t list)];
  [%expect
    {|
    (((address 0x00000000000000000000000000000000000000a1)
      (account_value 150172.4525)
      (windows
       ((Day ((pnl 135.9525) (roi 0.00090612950848626827) (vlm 10000)))
        (Week ((pnl 172.4525) (roi 0.0011496833333333332) (vlm 20000)))
        (Month ((pnl 172.4525) (roi 0.0011496833333333332) (vlm 20000)))
        (All_time ((pnl 172.4525) (roi 0.0011496833333333332) (vlm 20000)))))
      (display_name ()))
     ((address 0x00000000000000000000000000000000000000a0)
      (account_value 99815.5475)
      (windows
       ((Day ((pnl -141.9525) (roi -0.00142012855463572) (vlm 10000)))
        (Week ((pnl -184.4525) (roi -0.0018445249999999999) (vlm 20000)))
        (Month ((pnl -184.4525) (roi -0.0018445249999999999) (vlm 20000)))
        (All_time ((pnl -184.4525) (roi -0.0018445249999999999) (vlm 20000)))))
      (display_name ())))
    |}];
  let json = Rankings.to_json rows in
  print_endline (Yojson.Safe.pretty_to_string json);
  [%expect
    {|
    {
      "leaderboardRows": [
        {
          "ethAddress": "0x00000000000000000000000000000000000000a1",
          "accountValue": "150172.4525",
          "windowPerformances": [
            [
              "day", { "pnl": "135.9525", "roi": "0.0009061295", "vlm": "10000" }
            ],
            [
              "week",
              { "pnl": "172.4525", "roi": "0.0011496833", "vlm": "20000" }
            ],
            [
              "month",
              { "pnl": "172.4525", "roi": "0.0011496833", "vlm": "20000" }
            ],
            [
              "allTime",
              { "pnl": "172.4525", "roi": "0.0011496833", "vlm": "20000" }
            ]
          ],
          "prize": 0,
          "displayName": null
        },
        {
          "ethAddress": "0x00000000000000000000000000000000000000a0",
          "accountValue": "99815.5475",
          "windowPerformances": [
            [
              "day",
              { "pnl": "-141.9525", "roi": "-0.0014201286", "vlm": "10000" }
            ],
            [
              "week",
              { "pnl": "-184.4525", "roi": "-0.001844525", "vlm": "20000" }
            ],
            [
              "month",
              { "pnl": "-184.4525", "roi": "-0.001844525", "vlm": "20000" }
            ],
            [
              "allTime",
              { "pnl": "-184.4525", "roi": "-0.001844525", "vlm": "20000" }
            ]
          ],
          "prize": 0,
          "displayName": null
        }
      ]
    }
    |}];
  (* The output decodes with hl-protocol's reader of the real endpoint. *)
  print_s [%sexp (List.length (Leaderboard.t_of_yojson json).leaderboard_rows : int)];
  [%expect {| 2 |}]
;;

(* Seen early in runs with noise traders: a $10M account with a short of a few lots has a
   liquidation price estimate beyond what a price can hold, which made the leaderboard
   answer 400. *)
let%expect_test "the leaderboard of a tiny short against a large balance" =
  let ex = Adapt.create_exchange () in
  let server = Server.create ~now:(fun () -> start) ex in
  List.iter [ maker; taker ] ~f:(fun a ->
    Server.ensure_account server a;
    Exchange.deposit ex a (Usd.of_int 10_000_000));
  let tiny ~is_buy ~tif user =
    ignore
      (Adapt.place_order
         ex
         user
         { asset = Asset.of_int 0
         ; is_buy
         ; limit_px = Helpers.px "100000"
         ; sz = Helpers.sz "0.0001"
         ; reduce_only = false
         ; order_type = Limit { tif }
         ; cloid = None
         }
       : Order_status.t)
  in
  Server.mutate server ~f:(fun _ ->
    tiny maker ~is_buy:true ~tif:Gtc;
    tiny taker ~is_buy:false ~tif:Ioc);
  let rows =
    match Server.handle_info_json server (`Assoc [ "type", `String "leaderboard" ]) with
    | `Assoc [ ("leaderboardRows", `List rows) ] -> rows
    | json -> failwith (Yojson.Safe.to_string json)
  in
  print_s [%message "" ~rows:(List.length rows : int)];
  [%expect {| (rows 2) |}]
;;

let%expect_test "portfolio history: samples, then the current state" =
  let ex = Adapt.create_exchange () in
  Exchange.step ex ~now:start;
  let r = Rankings.create () in
  let deposit a usd =
    Exchange.deposit ex a usd;
    Rankings.record_deposit r a usd
  in
  deposit maker (Usd.of_int 100_000);
  deposit taker (Usd.of_int 100_000);
  Rankings.sample r ex;
  Exchange.step ex ~now:(start + minute);
  Rankings.sample r ex;
  order ex maker ~is_buy:false ~px:"100000" ~tif:Gtc;
  order ex taker ~is_buy:true ~px:"100000" ~tif:Ioc;
  Rankings.record_volume r taker (Usd.of_int 10_000);
  Exchange.step ex ~now:(start + (2 * minute));
  Exchange.set_mark ex (Coin.of_string "BTC") (Helpers.px "100500");
  Rankings.sample r ex;
  let json = Rankings.portfolio r ex taker in
  let windows =
    match json with
    | `List windows ->
      List.map windows ~f:(function
        | `List [ `String n; _ ] -> n
        | _ -> "?")
    | _ -> []
  in
  print_s [%sexp (windows : string list)];
  [%expect {| (day week month allTime perpDay perpWeek perpMonth perpAllTime) |}];
  let day =
    match json with
    | `List windows ->
      List.find_map windows ~f:(function
        | `List [ `String "day"; body ] -> Some body
        | _ -> None)
      |> Option.value_exn
    | _ -> assert false
  in
  print_endline (Yojson.Safe.to_string day);
  [%expect
    {| {"accountValueHistory":[[1700000000000,"100000"],[1700000060000,"100000"],[1700000120000,"100045.5"]],"pnlHistory":[[1700000000000,"0"],[1700000060000,"0"],[1700000120000,"45.5"]],"vlm":"10000"} |}];
  let unknown = Rankings.portfolio r ex (Helpers.addr 0xff) in
  print_endline
    (Yojson.Safe.to_string
       (List.hd_exn
          (match unknown with
           | `List l -> l
           | _ -> [])));
  [%expect {| ["day",{"accountValueHistory":[],"pnlHistory":[],"vlm":"0"}] |}]
;;
