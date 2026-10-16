(* The price collar and halt rule flags: parsing, Hyperliquid's errors for the orders they
   stop, the guard status on [GET /status], reopening, and replays of the inputs. *)

open! Core
open! Hl_protocol
open! Hl_sim
open! Helpers
module Exchange = Exchange_core_engine.Exchange
module Engine_journal = Exchange_core_engine.Journal
module Guard_event = Exchange_core_engine.Guard_event

let%expect_test "flags" =
  let show ?bps ?ticks ?reference ?action ?levels ?scope ?(anchored = false) () =
    print_s
      [%sexp
        (Guard.of_flags ?bps ?ticks ?reference ?action ?levels ?scope ~anchored ()
         : Guard.Config.t Or_error.t)]
  in
  show ();
  [%expect {| (Ok ((collar ()) (halt_rule ()))) |}];
  show ~bps:50 ();
  [%expect
    {|
    (Ok
     ((collar (((reference Last_trade) (band (Bps 50)) (action Reject))))
      (halt_rule ())))
    |}];
  show ~ticks:20 ~action:Reprice ~anchored:true ();
  [%expect
    {|
    (Ok
     ((collar (((reference Mark) (band (Ticks 20)) (action Reprice))))
      (halt_rule ())))
    |}];
  show ~levels:"7:15m,13:15m,20:reopen" ~scope:Per_symbol ();
  [%expect
    {|
    (Ok
     ((collar ())
      (halt_rule
       (((levels
          (((move_bps 700) (duration_ns (900000000000)))
           ((move_bps 1300) (duration_ns (900000000000)))
           ((move_bps 2000) (duration_ns ()))))
         (scope Per_symbol) (watch ()) (observe Mark) (reopen Automatic))))))
    |}];
  show ~levels:"2.5:90s" ();
  [%expect
    {|
    (Ok
     ((collar ())
      (halt_rule
       (((levels (((move_bps 250) (duration_ns (90000000000)))))
         (scope Market_wide) (watch ()) (observe Mark) (reopen Automatic))))))
    |}];
  show ~bps:50 ~ticks:5 ();
  [%expect {| (Error "-collar-bps and -collar-ticks exclude each other") |}];
  show ~reference:Mid ();
  [%expect
    {|
    (Error
     "-collar-reference and -collar-action need -collar-bps or -collar-ticks")
    |}];
  show ~scope:Market_wide ();
  [%expect {| (Error "-halt-scope needs -halt-levels") |}];
  show ~bps:0 ();
  [%expect
    {|
    (Error
     ("Price_collar: band must be positive"
      (t ((reference Last_trade) (band (Bps 0)) (action Reject)))))
    |}];
  show ~levels:"13:15m,7:15m" ();
  [%expect
    {|
    (Error
     ("Halt_rule: invalid levels"
      (t
       ((levels
         (((move_bps 1300) (duration_ns (900000000000)))
          ((move_bps 700) (duration_ns (900000000000)))))
        (scope Market_wide) (watch ()) (observe Mark) (reopen Automatic)))))
    |}];
  show ~levels:"7" ();
  [%expect {| (Error ("halt level is not PERCENT:DURATION" 7)) |}];
  show ~levels:"7:soon" ();
  [%expect
    {|
    (Error
     (("invalid halt level" 7:soon)
      ("Time_ns.Span.of_string: invalid string" (string soon)
       (reason "no digits before unit suffix"))))
    |}]
;;

(* A server at a settable clock over a fresh exchange with the given guard; [inputs] gets
   every engine input from before the guard is applied, as an input journal would. *)
let setup ?bps ?action ?levels ?scope () =
  let now = ref 1_700_000_000_000_000_000 in
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let server = Server.create ~now:(fun () -> !now) exchange in
  Guard.of_flags ?bps ?action ?levels ?scope ~anchored:false ()
  |> ok_exn
  |> fun config ->
  Guard.apply config exchange |> ok_exn;
  server, exchange, inputs, now
;;

let order ?(tif = "Gtc") ~is_buy ~px ~sz () =
  sprintf
    {|{"action":{"type":"order","orders":[{"a":0,"b":%b,"p":"%s","s":"%s","r":false,"t":{"limit":{"tif":"%s"}}}],"grouping":"na"},"nonce":1}|}
    is_buy
    px
    sz
    tif
  |> Yojson.Safe.from_string
  |> Exchange_request.t_of_yojson
;;

let send server address req =
  Server.handle_exchange server address req
  |> Exchange_response.yojson_of_t
  |> Yojson.Safe.to_string
  |> print_endline
;;

let maker = addr 1
let taker = addr 2

(* A trade at [px] between the maker and the taker. *)
let trade server px =
  send server maker (order ~is_buy:false ~px ~sz:"0.01" ());
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px ~sz:"0.01" ())
;;

let print_status server =
  match Server.status server with
  | `Assoc fields ->
    List.Assoc.find fields "guard" ~equal:String.equal
    |> Option.value ~default:`Null
    |> Yojson.Safe.pretty_to_string
    |> print_endline
  | _ -> assert false
;;

let%expect_test "no guard: no guard entry in the status" =
  let server, _, _, _ = setup () in
  print_endline (Yojson.Safe.to_string (Server.status server));
  [%expect {| {"ws_connections":0,"ws_dropped":0,"ws_idle_closed":0} |}]
;;

let%expect_test "collar: Hyperliquid's oracle error, then re-pricing" =
  let server, exchange, _, _ = setup ~bps:50 () in
  trade server "100000";
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":2}}]}}}
    |}];
  send server maker (order ~is_buy:false ~px:"100400" ~sz:"0.01" ());
  send server maker (order ~is_buy:false ~px:"100600" ~sz:"0.01" ());
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":3}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":4}}]}}}
    |}];
  send server maker (order ~is_buy:true ~px:"99600" ~sz:"0.01" ());
  (* Beyond 100500 and 99500, the bounds 50 bps from the last trade. *)
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"101000" ~sz:"0.02" ());
  send server taker (order ~tif:"Ioc" ~is_buy:false ~px:"99000" ~sz:"0.02" ());
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":5}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Order price cannot be more than 0.5% away from the reference price asset=0"}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Order price cannot be more than 0.5% away from the reference price asset=0"}]}}}
    |}];
  (* The orderUpdates status of a collar rejection. *)
  (match (order ~tif:"Ioc" ~is_buy:true ~px:"101000" ~sz:"0.01" ()).action with
   | Order { orders = [ o ]; _ } ->
     let status, update = Adapt.place_order_with_update exchange taker o in
     print_s
       [%message
         ""
           (status : Order_status.t)
           ~update_status:
             (Option.map update ~f:(fun u -> u.status) : Order_update.Status.t option)]
   | _ -> assert false);
  [%expect
    {|
    ((status
      (Error
       "Order price cannot be more than 0.5% away from the reference price asset=0"))
     (update_status ((Other oracleRejected))))
    |}];
  (* A tick error is still a tick error. *)
  send server taker (order ~is_buy:true ~px:"100000.5" ~sz:"0.01" ());
  [%expect
    {| {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Price must be divisible by tick size. asset=0"}]}}} |}];
  Guard.apply
    { Guard.Config.off with
      collar = Some { reference = Last_trade; band = Bps 50; action = Reprice }
    }
    exchange
  |> ok_exn;
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"101000" ~sz:"0.02" ());
  [%expect
    {| {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100400","oid":10}}]}}} |}];
  print_status server;
  [%expect
    {|
    {
      "collar": { "band_bps": 50, "reference": "last", "action": "reprice" },
      "halt_rule": null,
      "halted": [],
      "stats": {
        "collar_rejected": 3,
        "collar_repriced": 1,
        "collar_unreferenced": 2,
        "halt_rejected": 0,
        "halts": 0,
        "reopens": 0
      },
      "recent": [
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "collar_rejected",
          "side": "buy",
          "limit_px": "101000",
          "reference": "100000",
          "bound": "100500",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 6
        },
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "collar_rejected",
          "side": "sell",
          "limit_px": "99000",
          "reference": "100000",
          "bound": "99500",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 7
        },
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "collar_rejected",
          "side": "buy",
          "limit_px": "101000",
          "reference": "100000",
          "bound": "100500",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 8
        },
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "collar_repriced",
          "side": "buy",
          "limit_px": "101000",
          "repriced_px": "100500",
          "reference": "100000",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 10
        }
      ]
    }
    |}]
;;

let%expect_test "halt: rejections, status, automatic and requested reopening" =
  let server, _, _, now = setup ~levels:"7:15m,13:reopen" ~scope:Per_symbol () in
  trade server "100000";
  (* A 7.5% move halts BTC for 15 minutes. *)
  trade server "107500";
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":2}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":3}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"107500","oid":4}}]}}}
    |}];
  send server maker (order ~is_buy:false ~px:"107600" ~sz:"0.01" ());
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"107600" ~sz:"0.01" ());
  (* Passive orders rest during the halt. *)
  send server taker (order ~is_buy:true ~px:"100000" ~sz:"0.01" ());
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":5}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Trading is halted. asset=0"}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":7}}]}}}
    |}];
  print_status server;
  [%expect
    {|
    {
      "collar": null,
      "halt_rule": {
        "levels": [
          { "move_bps": 700, "duration_s": 900 },
          { "move_bps": 1300, "duration_s": "reopen" }
        ],
        "scope": "symbol"
      },
      "halted": [ { "coin": "BTC", "until_ms": 1700000900000 } ],
      "stats": {
        "collar_rejected": 0,
        "collar_repriced": 0,
        "collar_unreferenced": 0,
        "halt_rejected": 1,
        "halts": 1,
        "reopens": 0
      },
      "recent": [
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "halted",
          "trigger": "BTC",
          "level": 0,
          "reference": "100000",
          "px": "107500",
          "move_bps": 750,
          "until_ms": 1700000900000
        },
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "halt_rejected",
          "side": "buy",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 6
        }
      ]
    }
    |}];
  now := !now + Time_ns.Span.to_int_ns (Time_ns.Span.of_min 16.);
  (* Reopened automatically: the taker buys the 107600 ask left from the halt. *)
  trade server "113500";
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":8}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"107600","oid":9}}]}}}
    |}];
  send server maker (order ~is_buy:false ~px:"113600" ~sz:"0.01" ());
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"113600" ~sz:"0.01" ());
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":10}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"113500","oid":11}}]}}}
    |}];
  print_endline (Yojson.Safe.pretty_to_string (Server.reopen server));
  [%expect
    {|
    {
      "collar": null,
      "halt_rule": {
        "levels": [
          { "move_bps": 700, "duration_s": 900 },
          { "move_bps": 1300, "duration_s": "reopen" }
        ],
        "scope": "symbol"
      },
      "halted": [],
      "stats": {
        "collar_rejected": 0,
        "collar_repriced": 0,
        "collar_unreferenced": 0,
        "halt_rejected": 1,
        "halts": 2,
        "reopens": 2
      },
      "recent": [
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "halted",
          "trigger": "BTC",
          "level": 0,
          "reference": "100000",
          "px": "107500",
          "move_bps": 750,
          "until_ms": 1700000900000
        },
        {
          "time_ms": 1700000000000,
          "coin": "BTC",
          "kind": "halt_rejected",
          "side": "buy",
          "user": "0x0000000000000000000000000000000000000002",
          "oid": 6
        },
        { "time_ms": 1700000960000, "coin": "BTC", "kind": "reopened" },
        {
          "time_ms": 1700000960000,
          "coin": "BTC",
          "kind": "halted",
          "trigger": "BTC",
          "level": 1,
          "reference": "100000",
          "px": "113500",
          "move_bps": 1350,
          "until_ms": null
        },
        { "time_ms": 1700000960000, "coin": "BTC", "kind": "reopened" }
      ]
    }
    |}];
  trade server "113500";
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":12}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"113500","oid":13}}]}}}
    |}]
;;

let%expect_test "the input journal replays the guard events" =
  let server, exchange, inputs, now = setup ~bps:200 ~levels:"1:1m,3:reopen" () in
  trade server "100000";
  (* A collar rejection, a halt, a halt rejection, an automatic and a requested reopening. *)
  send server maker (order ~is_buy:false ~px:"102500" ~sz:"0.01" ());
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"103000" ~sz:"0.01" ());
  trade server "101500";
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"102500" ~sz:"0.01" ());
  now := !now + Time_ns.Span.to_int_ns (Time_ns.Span.of_min 2.);
  send server taker (order ~tif:"Ioc" ~is_buy:true ~px:"102500" ~sz:"0.01" ());
  trade server "103000";
  ignore (Server.reopen server : Yojson.Safe.t);
  let live = Server.guard_events server in
  let replayed =
    Engine_journal.replay
      ~config:(Exchange.config exchange)
      (Engine_journal.of_string (Engine_journal.to_string (Queue.to_list inputs))
       |> ok_exn)
  in
  let replayed_events = Exchange.drain_guard_events replayed in
  print_s
    [%message
      ""
        ~events:(List.length live : int)
        ~same_events:([%equal: Guard_event.t list] live replayed_events : bool)
        ~same_stats:
          (Guard_event.Stats.equal
             (Exchange.guard_stats exchange)
             (Exchange.guard_stats replayed)
           : bool)];
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"100000","oid":2}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":3}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Order price cannot be more than 2% away from the reference price asset=0"}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":5}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"101500","oid":6}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Trading is halted. asset=0"}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"102500","oid":8}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":9}}]}}}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.01","avgPx":"103000","oid":10}}]}}}
    ((events 14) (same_events true) (same_stats true))
    |}];
  List.iter live ~f:(fun e -> print_endline (Yojson.Safe.to_string (Guard.event_json e)));
  [%expect
    {|
    {"time_ms":1700000000000,"coin":"BTC","kind":"collar_rejected","side":"buy","limit_px":"103000","reference":"100000","bound":"102000","user":"0x0000000000000000000000000000000000000002","oid":4}
    {"time_ms":1700000000000,"coin":"BTC","kind":"halted","trigger":"BTC","level":0,"reference":"100000","px":"101500","move_bps":150,"until_ms":1700000060000}
    {"time_ms":1700000000000,"coin":"ETH","kind":"halted","trigger":"BTC","level":0,"reference":"100000","px":"101500","move_bps":150,"until_ms":1700000060000}
    {"time_ms":1700000000000,"coin":"SOL","kind":"halted","trigger":"BTC","level":0,"reference":"100000","px":"101500","move_bps":150,"until_ms":1700000060000}
    {"time_ms":1700000000000,"coin":"BTC","kind":"halt_rejected","side":"buy","user":"0x0000000000000000000000000000000000000002","oid":7}
    {"time_ms":1700000120000,"coin":"BTC","kind":"reopened"}
    {"time_ms":1700000120000,"coin":"ETH","kind":"reopened"}
    {"time_ms":1700000120000,"coin":"SOL","kind":"reopened"}
    {"time_ms":1700000120000,"coin":"BTC","kind":"halted","trigger":"BTC","level":1,"reference":"100000","px":"103000","move_bps":300,"until_ms":null}
    {"time_ms":1700000120000,"coin":"ETH","kind":"halted","trigger":"BTC","level":1,"reference":"100000","px":"103000","move_bps":300,"until_ms":null}
    {"time_ms":1700000120000,"coin":"SOL","kind":"halted","trigger":"BTC","level":1,"reference":"100000","px":"103000","move_bps":300,"until_ms":null}
    {"time_ms":1700000120000,"coin":"BTC","kind":"reopened"}
    {"time_ms":1700000120000,"coin":"ETH","kind":"reopened"}
    {"time_ms":1700000120000,"coin":"SOL","kind":"reopened"}
    |}]
;;
