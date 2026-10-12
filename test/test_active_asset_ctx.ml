open! Core
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange

let day = 86_400 * 1_000_000_000
let start = 1_700_000_000_000_000_000

let limit ex user ~is_buy ~px ~sz =
  let req : Order_request.t =
    { asset = Asset.of_int 0
    ; is_buy
    ; limit_px = Helpers.px px
    ; sz = Helpers.sz sz
    ; reduce_only = false
    ; order_type = Limit { tif = Gtc }
    ; cloid = None
    }
  in
  ignore (Adapt.place_order ex user req : Order_status.t)
;;

let print t = print_endline (Yojson.Safe.to_string (Active_asset_ctx.to_ws_message t))

let%expect_test "context of a traded coin" =
  let ex = Adapt.create_exchange () in
  let stats = Active_asset_ctx.Day_stats.create () in
  let record () =
    List.iter (Exchange.drain_events ex) ~f:(function
      | Fill { fill; _ } ->
        Active_asset_ctx.Day_stats.record_trade
          stats
          ~coin:fill.symbol
          ~px:fill.px
          ~sz:fill.sz
          ~time:fill.time
      | _ -> ())
  in
  let a = Helpers.addr 1
  and b = Helpers.addr 2 in
  List.iter [ a; b ] ~f:(fun u -> Exchange.deposit ex u (Helpers.usd "100000"));
  Exchange.step ex ~now:start;
  (* No trade, no mark, no book: nothing to report. *)
  print_s [%sexp (Active_asset_ctx.of_exchange ex stats Helpers.btc : _ option)];
  [%expect {| () |}];
  limit ex a ~is_buy:false ~px:"100000" ~sz:"0.1";
  limit ex b ~is_buy:true ~px:"100000" ~sz:"0.04";
  record ();
  Exchange.step ex ~now:(start + day);
  limit ex b ~is_buy:true ~px:"100000" ~sz:"0.01";
  limit ex b ~is_buy:true ~px:"99000" ~sz:"0.01";
  record ();
  Option.iter (Active_asset_ctx.of_exchange ex stats Helpers.btc) ~f:print;
  [%expect
    {| {"channel":"activeAssetCtx","data":{"coin":"BTC","ctx":{"funding":"0.0000125","openInterest":"0.05","prevDayPx":"100000","dayNtlVlm":"1000","premium":"-0.005","oraclePx":"100000","markPx":"100000","midPx":"99500","impactPxs":["99000","100000"],"dayBaseVlm":"0.01"}}} |}];
  print_s
    [%sexp (Active_asset_ctx.of_exchange ex stats (Coin.of_string "DOGE") : _ option)];
  [%expect {| () |}]
;;

let%expect_test "requests" =
  List.iter
    [ {|{"method":"subscribe","subscription":{"type":"activeAssetCtx","coin":"BTC"}}|}
    ; {|{"method":"unsubscribe","subscription":{"type":"activeAssetCtx","coin":"ETH"}}|}
    ; {|{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}|}
    ; {|{"method":"ping"}|}
    ; {|[1]|}
    ]
    ~f:(fun text ->
      match Active_asset_ctx.Request.of_json (Yojson.Safe.from_string text) with
      | None -> print_endline "-"
      | Some req ->
        print_endline (Yojson.Safe.to_string (Active_asset_ctx.Request.response req)));
  [%expect
    {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"activeAssetCtx","coin":"BTC"}}}
    {"channel":"subscriptionResponse","data":{"method":"unsubscribe","subscription":{"type":"activeAssetCtx","coin":"ETH"}}}
    -
    -
    -
    |}]
;;
