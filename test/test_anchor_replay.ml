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

let%expect_test "an anchored run replays from its journal" =
  Log.Global.set_output [];
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let server =
    Server.create ~now:(fun () -> Time_ns.to_int_ns_since_epoch start) exchange
  in
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
  let source =
    Anchoring.raw_source
      ~on_error:(fun e -> print_s [%message "raw error" (e : Error.t)])
      ~dir:"fixtures"
      ~from:start
      ~to_:(Time_ns.add start (Time_ns.Span.of_min 1.))
      (Anchoring.spec anchoring)
    |> ok_exn
  in
  let%bind () = Anchoring.run anchoring source in
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
