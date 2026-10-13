(* A copy-trading session on the simulator: noise traders, leaders, and a follower that
   approved an agent and a builder and mirrors a leader with builder-coded orders. The
   engine inputs of the run, journaled, replay into a fresh exchange bit for bit: leaders,
   approvals and builder fees all act through recorded engine calls. *)

open! Core
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange
module Engine_journal = Exchange_core_engine.Journal
module Market_sim = Exchange_core_engine.Market_sim

let start = 1_700_000_000_000_000_000
let vectors = lazy (Yojson.Safe.from_file "fixtures/user_signed.json")
let follower = Address.of_string "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
let builder_address = Address.of_string "0x00000000000000000000000000000000000000bb"
let btc = Coin.of_string "BTC"

let fixture_request name =
  let v = Yojson.Safe.Util.member name (force vectors) in
  `Assoc
    [ "action", Yojson.Safe.Util.member "action" v
    ; "nonce", Yojson.Safe.Util.member "nonce" v
    ; "signature", Yojson.Safe.Util.member "signature" v
    ]
;;

let position ex address =
  Exchange_core.Account_view.find_position (Exchange.account_view ex address) btc
  |> Option.value_map ~default:0. ~f:(fun (p : Exchange_core.Position_view.t) ->
    Size.to_float p.size)
;;

(* An IOC order 1% through the mark, for the follower's share (a tenth) of the leader's
   position change. *)
let mirror server ex ~leader ~last =
  let now = position ex leader in
  let delta = (now -. !last) /. 10. in
  last := now;
  match Exchange.mark ex btc with
  | Some mid when Float.(abs delta >= 0.0002) ->
    let is_buy = Float.(delta > 0.) in
    let px = Price.to_float mid *. if is_buy then 1.01 else 0.99 in
    let req : Exchange_request.t =
      { action =
          Order
            { orders =
                [ { asset = Asset.of_int 0
                  ; is_buy
                  ; limit_px =
                      Price.of_string (Int.to_string (Float.iround_nearest_exn px))
                  ; sz = Size.of_string (sprintf "%.5f" (Float.abs delta))
                  ; reduce_only = false
                  ; order_type = Limit { tif = Ioc }
                  ; cloid = None
                  }
                ]
            ; grouping = Na
            }
      ; nonce = 1
      ; signature = None
      ; vault_address = None
      }
    in
    ignore
      (Server.handle_exchange
         ~builder:{ builder = builder_address; fee_tenths_bp = 10 }
         server
         follower
         req
       : Exchange_response.t)
  | _ -> ()
;;

let accounts sim leaders =
  (follower :: builder_address :: Market_sim.traders sim)
  @ List.map (Leaders.leaders leaders) ~f:(fun l -> l.address)
;;

let state ex accounts =
  [%sexp
    { now : int = Exchange.now ex
    ; views : Exchange_core.Account_view.t list =
        List.map accounts ~f:(Exchange.account_view ex)
    ; fills : Exchange_core_engine.Execution.t list list =
        List.map accounts ~f:(Exchange.fills ex)
    ; book : Exchange_core.L2.t option = Exchange.l2 ex btc
    }]
;;

let%expect_test "a copy-trading run replays from its engine journal" =
  Async.Log.Global.set_output [];
  let ex = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs ex ~f:(Queue.enqueue inputs);
  let clock = ref start in
  let server = Server.create ~now:(fun () -> !clock) ex in
  let sim = Market_sim.create { Market_sim.Config.default with seed = 5 } ex in
  let leaders = Leaders.create { Leaders.Config.default with seed = 5; count = 3 } ex in
  List.iter [ "agent_named"; "builder_fee" ] ~f:(fun name ->
    print_endline
      (Yojson.Safe.to_string
         (Exchange_response.yojson_of_t
            (Server.handle_exchange_json server ~x_address:None (fixture_request name)))));
  [%expect
    {|
    {"status":"ok","response":{"type":"default"}}
    {"status":"ok","response":{"type":"default"}}
    |}];
  let leader = Leaders.address 0 in
  let last = ref 0. in
  for i = 1 to 6_000 do
    clock := start + (i * 100_000_000);
    Server.mutate server ~f:(fun _ -> Market_sim.tick sim);
    if i % 50 = 0
    then (
      Server.mutate server ~f:(fun _ -> Leaders.tick leaders);
      Server.mutate server ~f:(fun ex -> mirror server ex ~leader ~last))
  done;
  let accounts = accounts sim leaders in
  let original = state ex accounts in
  let journal = Engine_journal.to_string (Queue.to_list inputs) in
  let replayed =
    Engine_journal.replay
      ~config:(Adapt.config ())
      (ok_exn (Engine_journal.of_string journal))
  in
  print_s
    [%message
      ""
        ~inputs:(Queue.length inputs : int)
        ~follower_fills:(List.length (Exchange.fills ex follower) : int)
        ~leader_position:(position ex leader : float)
        ~follower_position:(position ex follower : float)
        ~builder_equity:((Exchange.account_view ex builder_address).equity : Usd.t)
        ~identical:(Sexp.equal original (state replayed accounts) : bool)];
  [%expect
    {|
    ((inputs 127065) (follower_fills 32) (leader_position 1.026)
     (follower_position 0.09084) (builder_equity 1000002.66124902)
     (identical true))
    |}]
;;
