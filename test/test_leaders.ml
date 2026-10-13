open! Core
open! Hl_protocol
open! Hl_sim
open! Exchange_core_engine

(* One simulated hour: market ticks every 100ms, leader rounds every 5s. *)
let run ~seed =
  let exchange = Adapt.create_exchange () in
  let sim =
    Market_sim.create { Market_sim.Config.default with seed; noise_traders = 4 } exchange
  in
  let leaders = Leaders.create { Leaders.Config.default with seed; count = 6 } exchange in
  for i = 1 to 36_000 do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    if i % 50 = 0 then Leaders.tick leaders;
    ignore (Exchange.drain_events exchange : Event.t list)
  done;
  exchange, leaders
;;

let summary (exchange, leaders) =
  List.map (Leaders.leaders leaders) ~f:(fun (l : Leaders.Leader.t) ->
    let view = Exchange.account_view exchange l.address in
    ( Leaders.Leader.display_name l
    , l.coin
    , List.length (Exchange.fills exchange l.address)
    , List.map view.positions ~f:(fun p -> p.size)
    , view.equity ))
;;

let%expect_test "leaders trade distinct strategies, reproducibly" =
  let run1 = run ~seed:3 in
  List.iter
    (Leaders.leaders (snd run1))
    ~f:(fun l -> print_s [%sexp (l : Leaders.Leader.t)]);
  [%expect
    {|
    ((index 0) (address 0x1eade50000000000000000000000000000000000) (coin BTC)
     (strategy Trend) (leverage 2.2341153803319282))
    ((index 1) (address 0x1eade50000000000000000000000000000000001) (coin BTC)
     (strategy Mean_reversion) (leverage 1.62067250415018))
    ((index 2) (address 0x1eade50000000000000000000000000000000002) (coin BTC)
     (strategy Random) (leverage 0.59925963074310107))
    ((index 3) (address 0x1eade50000000000000000000000000000000003) (coin ETH)
     (strategy Trend) (leverage 1.4702794106306607))
    ((index 4) (address 0x1eade50000000000000000000000000000000004) (coin ETH)
     (strategy Mean_reversion) (leverage 0.98402240478336589))
    ((index 5) (address 0x1eade50000000000000000000000000000000005) (coin ETH)
     (strategy Random) (leverage 1.2485499444065453))
    |}];
  print_s [%sexp (summary run1 : (string * Coin.t * int * Size.t list * Usd.t) list)];
  [%expect
    {|
    ((trend-0 BTC 3851 (1.58267) 90791.29173904)
     (mean-reversion-1 BTC 3571 (-1.18916) 95420.75888775)
     (random-2 BTC 1163 (0.44045) 99771.9229843)
     (trend-3 ETH 2150 (3.7679) 100661.68646437)
     (mean-reversion-4 ETH 2740 (19.1286) 95066.91688464)
     (random-5 ETH 2025 (22.4089) 95212.58758974))
    |}];
  print_s
    [%sexp
      ([%equal: (string * Coin.t * int * Size.t list * Usd.t) list]
         (summary run1)
         (summary (run ~seed:3))
       : bool)];
  [%expect {| true |}]
;;
