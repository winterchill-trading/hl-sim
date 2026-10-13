(* Ten simulated minutes of the default market simulation with nine leaders (trend,
   mean-reversion and random on three coins): with the edge, the trend and mean-reversion
   leaders end up ahead after fees, the random ones behind, and the same seed gives the
   same leaderboard. *)

open! Core
open! Hl_protocol
open! Hl_sim
open! Exchange_core_engine

let balance = 100_000.

(* Market ticks every 100 ms, leader rounds every 5 s, the exchange clock driven by the
   loop: ten minutes run in well under a second. *)
let run ~seed ~edge =
  let exchange = Adapt.create_exchange () in
  let sim = Market_sim.create { Market_sim.Config.default with seed } exchange in
  let foresight =
    Option.map edge ~f:(fun lookahead ->
      Foresight.create
        ~seed
        ~lookahead
        sim
        ~coins:(List.map (Exchange.instruments exchange) ~f:(fun i -> i.symbol)))
  in
  let leaders =
    Leaders.create ?foresight { Leaders.Config.default with seed; count = 9 } exchange
  in
  for i = 1 to 6_000 do
    Option.iter foresight ~f:Foresight.tick;
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    if i % 50 = 0 then Leaders.tick leaders;
    ignore (Exchange.drain_events exchange : Event.t list)
  done;
  (* Equity is net of fees paid. *)
  List.map (Leaders.leaders leaders) ~f:(fun l ->
    let view = Exchange.account_view exchange l.address in
    ( Leaders.Leader.display_name l
    , Float.iround_nearest_exn (Usd.to_float view.equity -. balance) ))
  |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
;;

let print ranking =
  List.iter ranking ~f:(fun (name, pnl) -> printf "%-18s %+6d\n" name pnl)
;;

let%expect_test "with the edge, trend and mean reversion win and random loses" =
  let ranking = run ~seed:1 ~edge:(Some (Time_ns.Span.of_int_sec 60)) in
  print ranking;
  [%expect
    {|
    mean-reversion-7    +4795
    trend-0             +4321
    trend-6             +4057
    mean-reversion-1    +3286
    trend-3             +2008
    mean-reversion-4    +1721
    random-5              -77
    random-8            -2775
    random-2            -2937
    |}];
  let is prefix (name, _) = String.is_prefix name ~prefix in
  let winners = List.filter ranking ~f:(fun (_, pnl) -> pnl > 0) in
  printf
    "%d winners, all trend or mean reversion: %b; a random leader loses: %b\n"
    (List.length winners)
    (List.for_all winners ~f:(fun l -> is "trend" l || is "mean-reversion" l))
    (List.exists ranking ~f:(fun ((_, pnl) as l) -> is "random" l && pnl < 0));
  [%expect
    {| 6 winners, all trend or mean reversion: true; a random leader loses: true |}];
  printf
    "same ranking on a second run: %b\n"
    ([%equal: (string * int) list]
       ranking
       (run ~seed:1 ~edge:(Some (Time_ns.Span.of_int_sec 60))));
  [%expect {| same ranking on a second run: true |}]
;;

let%expect_test "without the edge, fees and slippage beat every strategy" =
  print (run ~seed:1 ~edge:None);
  [%expect
    {|
    trend-0             +1490
    trend-3               -87
    random-5             -466
    trend-6              -615
    mean-reversion-4     -792
    mean-reversion-1    -1055
    random-8            -1171
    random-2            -1510
    mean-reversion-7    -1792
    |}]
;;
