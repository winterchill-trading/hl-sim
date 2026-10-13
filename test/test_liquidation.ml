open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange

let now () = 1_700_000_000_000_000_000
let user = Helpers.addr 0xaa
let maker = Helpers.addr 0xbb

let order ex address ~is_buy ~px ~sz ~tif =
  ignore
    (Adapt.place_order
       ex
       address
       { asset = Asset.of_int 0
       ; is_buy
       ; limit_px = Helpers.px px
       ; sz = Helpers.sz sz
       ; reduce_only = false
       ; order_type = Limit { tif }
       ; cloid = None
       }
     : Order_status.t)
;;

(* Prints every message that arrives within 200 ms. Waits with [values_available], not
   [read]: a timed-out read would still take the next message. *)
let rec drain incoming =
  match%bind
    Clock_ns.with_timeout (Time_ns.Span.of_int_ms 200) (Pipe.values_available incoming)
  with
  | `Result `Ok ->
    (match Pipe.read_now incoming with
     | `Ok msg ->
       print_endline msg;
       drain incoming
     | `Eof | `Nothing_available -> return ())
  | `Result `Eof | `Timeout -> return ()
;;

let subscribe outgoing kind =
  Pipe.write_without_pushback
    outgoing
    (sprintf
       {|{"method":"subscribe","subscription":{"type":"%s","user":"%s"}}|}
       kind
       (Address.to_string user))
;;

let%expect_test "a liquidation through the book: fills and user events" =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  Server.ensure_account server user;
  Server.ensure_account server maker;
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  subscribe outgoing "userEvents";
  subscribe outgoing "userFills";
  let%bind () = drain incoming in
  [%expect
    {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"userEvents","user":"0x00000000000000000000000000000000000000aa"}}}
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"userFills","user":"0x00000000000000000000000000000000000000aa"}}}
    {"channel":"userFills","data":{"isSnapshot":true,"user":"0x00000000000000000000000000000000000000aa","fills":[]}}
    |}];
  (* The user (credited $1M) goes long 300 BTC at 40x; the maker bids below. *)
  Server.mutate server ~f:(fun ex ->
    ignore (Exchange.set_leverage ex user Helpers.btc 40 : unit Or_error.t);
    Exchange.deposit ex maker (Helpers.usd "100000000");
    order ex maker ~is_buy:false ~px:"100000" ~sz:"300" ~tif:Gtc;
    order ex user ~is_buy:true ~px:"100000" ~sz:"300" ~tif:Ioc;
    order ex maker ~is_buy:true ~px:"97700" ~sz:"500" ~tif:Gtc;
    Exchange.set_mark ex Helpers.btc (Helpers.px "100000"));
  let%bind () = drain incoming in
  [%expect
    {|
    {"channel":"userFills","data":{"user":"0x00000000000000000000000000000000000000aa","fills":[{"coin":"BTC","px":"100000","sz":"300","side":"B","time":1700000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","oid":2,"crossed":true,"fee":"13500","tid":1,"feeToken":"USDC"}]}}
    {"channel":"user","data":{"fills":[{"coin":"BTC","px":"100000","sz":"300","side":"B","time":1700000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","oid":2,"crossed":true,"fee":"13500","tid":1,"feeToken":"USDC"}]}}
    |}];
  (* Below maintenance (1/80 of the notional), above two thirds of it: a 20% slice of the
     position goes to the book. *)
  Server.mutate server ~f:(fun ex ->
    Exchange.set_mark ex Helpers.btc (Helpers.px "97800"));
  let%bind () = drain incoming in
  [%expect
    {|
    {"channel":"user","data":{"liquidation":{"lid":1,"liquidator":"0x000000000000000000000000000000000000ffff","liquidated_user":"0x00000000000000000000000000000000000000aa","liquidated_ntl_pos":"29340000","liquidated_account_value":"326500"}}}
    {"channel":"userFills","data":{"user":"0x00000000000000000000000000000000000000aa","fills":[{"coin":"BTC","px":"97700","sz":"60","side":"A","time":1700000000000,"startPosition":"300","dir":"Close Long","closedPnl":"-138000","hash":"0x0000000000000000000000000000000000000000000000000000000000000002","oid":4,"crossed":true,"fee":"2637.9","tid":2,"feeToken":"USDC","liquidation":{"liquidatedUser":"0x00000000000000000000000000000000000000aa","markPx":"97800","method":"market"}}]}}
    {"channel":"user","data":{"fills":[{"coin":"BTC","px":"97700","sz":"60","side":"A","time":1700000000000,"startPosition":"300","dir":"Close Long","closedPnl":"-138000","hash":"0x0000000000000000000000000000000000000000000000000000000000000002","oid":4,"crossed":true,"fee":"2637.9","tid":2,"feeToken":"USDC","liquidation":{"liquidatedUser":"0x00000000000000000000000000000000000000aa","markPx":"97800","method":"market"}}]}}
    |}];
  Server.handle_info_json
    server
    (`Assoc [ "type", `String "userFills"; "user", Address.yojson_of_t user ])
  |> Yojson.Safe.to_string
  |> print_endline;
  [%expect
    {| [{"coin":"BTC","px":"97700","sz":"60","side":"A","time":1700000000000,"startPosition":"300","dir":"Close Long","closedPnl":"-138000","hash":"0x0000000000000000000000000000000000000000000000000000000000000002","oid":4,"crossed":true,"fee":"2637.9","tid":2,"feeToken":"USDC","liquidation":{"liquidatedUser":"0x00000000000000000000000000000000000000aa","markPx":"97800","method":"market"}},{"coin":"BTC","px":"100000","sz":"300","side":"B","time":1700000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","oid":2,"crossed":true,"fee":"13500","tid":1,"feeToken":"USDC"}] |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;
