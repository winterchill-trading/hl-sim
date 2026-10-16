(* The simulator anchored to a recorded minute of Hyperliquid BTC (raw minute files as the
   recorder writes them), with a client resting orders in it. The engine inputs of the
   run, journaled, replay into a fresh exchange to the same book, marks and fills without
   the reference data. *)

open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange
module Engine_journal = Exchange_core_engine.Journal

let start = Time_ns.of_string_with_utc_offset "2026-10-12T13:35:00Z"
let client = Address.of_string "0x00000000000000000000000000000000000000cc"
let btc = Coin.of_string "BTC"

let order ~is_buy ~px ~sz =
  sprintf
    {|{"action":{"type":"order","orders":[{"a":0,"b":%b,"p":"%s","s":"%s","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}|}
    is_buy
    px
    sz
  |> Yojson.Safe.from_string
  |> Exchange_request.t_of_yojson
;;

(* Everything a replay must reproduce. *)
let state exchange =
  [%sexp
    { now : int = Exchange.now exchange
    ; mark : Price.t option = Exchange.mark exchange btc
    ; book : Exchange_core.L2.t option = Exchange.l2 ~n_levels:20 exchange btc
    ; client_fills : Exchange_core_engine.Execution.t list =
        Exchange.fills exchange client
    ; client_orders : Exchange_core.Open_order.t list =
        Exchange.open_orders exchange client
    }]
;;

let range_end = Time_ns.add start (Time_ns.Span.of_min 1.)

(* A fresh simulator with the client's three orders, BTC anchored to [source], run to the
   end of the source. Returns the exchange, its inputs and the anchoring. *)
let run_anchored ?(guard = Guard.Config.off) ?(on_server = ignore) source =
  Log.Global.set_output [];
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let server =
    Server.create ~now:(fun () -> Time_ns.to_int_ns_since_epoch start) exchange
  in
  Guard.apply guard exchange |> ok_exn;
  on_server server;
  List.iter
    [ order ~is_buy:true ~px:"82514" ~sz:"0.01"
    ; order ~is_buy:true ~px:"82490" ~sz:"0.02"
    ; order ~is_buy:false ~px:"82560" ~sz:"0.01"
    ]
    ~f:(fun req ->
      ignore (Server.handle_exchange server client req : Exchange_response.t));
  let anchoring =
    Anchoring.create ~log:ignore server (Anchoring.Spec.of_string "hyperliquid:BTC")
  in
  let%bind source = source (Anchoring.spec anchoring) in
  let%map () = Anchoring.run anchoring source in
  exchange, inputs, anchoring
;;

let raw_source spec =
  Anchoring.raw_source
    ~on_error:(fun e -> print_s [%message "raw error" (e : Error.t)])
    ~dir:"fixtures"
    ~from:start
    ~to_:range_end
    spec
  |> ok_exn
  |> return
;;

let%expect_test "an anchored run replays from its journal" =
  let%bind exchange, inputs, anchoring = run_anchored raw_source in
  let stats = Price_anchor.Anchor.stats (Anchoring.anchor anchoring) in
  print_s
    [%message
      ""
        ~events:(stats.events : int)
        ~marks_set:(stats.marks_set : int)
        ~funding_rates_set:(stats.funding_rates_set : int)
        ~replays:(stats.replays : int)
        ~went_stale:(stats.went_stale : int)
        ~stale:(stats.stale : Price_anchor.Anchor.Stale_reason.t option)
        ~client_fills:(List.length (Exchange.fills exchange client) : int)
        ~inputs:(Queue.length inputs : int)];
  [%expect
    {|
    ((events 64) (marks_set 6) (funding_rates_set 4) (replays 2) (went_stale 3)
     (stale ()) (client_fills 2) (inputs 188))
    |}];
  print_endline
    (Yojson.Safe.pretty_to_string
       (Anchoring.Status.yojson_of_t (Anchoring.status anchoring)));
  [%expect
    {|
    {
      "anchor": "hyperliquid:BTC=BTC",
      "fresh": true,
      "stale_reason": null,
      "went_stale": 3,
      "stale_seconds": 3.190931,
      "gaps": 0,
      "events": 64,
      "marks_set": 6,
      "funding_rates_set": 4,
      "reference_price": "82493",
      "shadow_levels": 10,
      "shadow_placed": 66,
      "shadow_skipped": 5,
      "shadow_consumed": 0,
      "replay_fills": 2,
      "replays_rejected": 0
    }
    |}];
  let journal = Engine_journal.to_string (Queue.to_list inputs) in
  let replayed =
    Engine_journal.replay
      ~config:(Exchange.config exchange)
      (Engine_journal.of_string journal |> ok_exn)
  in
  print_s
    [%message "" ~replay_matches:(Sexp.equal (state exchange) (state replayed) : bool)];
  [%expect {| (replay_matches true) |}];
  return ()
;;

let%expect_test "an anchored run with a collar on the mark replays its guard events" =
  (* A 5 bps collar on the anchored mark (the default reference of an anchored run) and a
     5 bps halt level: tight enough for the recorded minute to hit both. *)
  let guard = Guard.of_flags ~bps:5 ~levels:"0.05:10s" ~anchored:true () |> ok_exn in
  let server = Set_once.create () in
  let%map exchange, inputs, _ =
    run_anchored ~guard ~on_server:(fun s -> Set_once.set_exn server s) raw_source
  in
  (* After the run, a client buy 1% through the anchored mark. *)
  (match (order ~is_buy:true ~px:"83300" ~sz:"0.01").action with
   | Order { orders = [ o ]; _ } ->
     print_s
       [%sexp
         (Adapt.place_order exchange client { o with order_type = Limit { tif = Ioc } }
          : Order_status.t)]
   | _ -> assert false);
  (* The server drains the guard log after each mutation; the last order's event comes
     with the next one. *)
  Server.publish_events (Set_once.get_exn server);
  let server_events = Server.guard_events (Set_once.get_exn server) in
  let replayed =
    Engine_journal.replay
      ~config:(Exchange.config exchange)
      (Engine_journal.of_string (Engine_journal.to_string (Queue.to_list inputs))
       |> ok_exn)
  in
  print_s
    [%message
      ""
        ~stats:(Exchange.guard_stats exchange : Exchange_core_engine.Guard_event.Stats.t)
        ~same_events:
          ([%equal: Exchange_core_engine.Guard_event.t list]
             server_events
             (Exchange.drain_guard_events replayed)
           : bool)
        ~replay_matches:(Sexp.equal (state exchange) (state replayed) : bool)];
  [%expect
    {|
    (Error
     "Order price cannot be more than 0.05% away from the reference price asset=0")
    ((stats
      ((collar_rejected 1) (collar_repriced 0) (collar_unreferenced 3)
       (halt_rejected 3) (halts 3) (reopens 3)))
     (same_events true) (replay_matches true))
    |}]
;;

let with_temp_dir f =
  let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "hl-sim-test") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () -> Unix.system_exn (sprintf "rm -rf %s" (Filename.quote dir)))
;;

let%expect_test "event logs rebuilt from the raw files anchor the same run" =
  with_temp_dir (fun dir ->
    let date = Date.of_string "2026-10-12" in
    let%bind (_ : Market_data.Rebuild_norm.Stats.t) =
      Market_data.Rebuild_norm.run
        ~normalizers:[ (module Hl_client.Raw_normalizer) ]
        ~data_dir:"fixtures"
        ~out_dir:dir
        date
      >>| ok_exn
    in
    let%bind from_raw, _, _ = run_anchored raw_source in
    let%map from_norm, _, anchoring =
      run_anchored (fun spec ->
        Anchoring.norm_source ~dir ~from:date ~to_:date spec >>| ok_exn)
    in
    print_s
      [%message
        ""
          ~events:((Price_anchor.Anchor.stats (Anchoring.anchor anchoring)).events : int)
          ~same_state:(Sexp.equal (state from_raw) (state from_norm) : bool)];
    [%expect {| ((events 64) (same_state true)) |}])
;;
