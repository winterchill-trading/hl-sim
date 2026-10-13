open! Core
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
open Helpers

let btc_asset = Asset.of_int 0
let cloid n = Cloid.of_int n

let order ?(tif = Tif.Gtc) ?(reduce_only = false) ?cloid side p s : Order_request.t =
  { asset = btc_asset
  ; is_buy = Side.is_buy side
  ; limit_px = px p
  ; sz = sz s
  ; reduce_only
  ; order_type = Limit { tif }
  ; cloid
  }
;;

let place ex n ?tif ?reduce_only ?cloid side p s =
  print_s
    [%sexp
      (Adapt.place_order ex (addr n) (order ?tif ?reduce_only ?cloid side p s)
       : Order_status.t)]
;;

let short_addr a = Address.to_string a |> Fn.flip String.drop_prefix 38

let fresh () =
  let ex = Adapt.create_exchange () in
  List.iter [ 1; 2; 3 ] ~f:(fun n -> Exchange.deposit ex (addr n) (usd "10000"));
  ex
;;

let meta = Adapt.default_meta

let summarize (e : Event.t) =
  let o order =
    let order = Adapt.open_order order in
    sprintf
      "oid=%s %s %s@%s"
      (Order_id.to_string order.oid)
      (Side.to_wire order.side)
      (Size.to_string order.sz)
      (Price.to_string order.limit_px)
  in
  match e with
  | Order_accepted { account; order; _ } ->
    sprintf "accepted %s %s" (short_addr account) (o order)
  | Order_rejected { account; symbol; reason; _ } ->
    sprintf
      "rejected %s %s"
      (short_addr account)
      (Adapt.reject_message meta ?coin:symbol reason)
  | Order_filled { account; order; _ } ->
    sprintf "filled %s %s" (short_addr account) (o order)
  | Order_cancelled { account; order; reason; _ } ->
    sprintf
      "cancelled %s %s %s"
      (short_addr account)
      (o order)
      (Sexp.to_string [%sexp (reason : Event.Cancel_reason.t)])
  | Fill { fill; taker; maker } ->
    let taker = Adapt.user_fill { fill; settlement = taker }
    and maker = Adapt.user_fill { fill; settlement = maker } in
    sprintf
      "fill tid=%d %s@%s taker=%s(%s fee %s) maker=%s(%s fee %s)"
      taker.tid
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (short_addr fill.taker)
      taker.dir
      (Usd.to_string taker.fee)
      (short_addr fill.maker)
      maker.dir
      (Usd.to_string maker.fee)
  | Liquidation { liquidation = l; _ } ->
    sprintf
      "liquidation %s %s %s@%s pnl %s"
      (short_addr l.account)
      (Coin.to_string l.symbol)
      (Size.to_string l.size)
      (Price.to_string l.px)
      (Usd.to_string l.pnl)
  | Funding { symbol; rate; mark; payments; _ } ->
    sprintf
      "funding %s rate=%g mark=%s %s"
      (Coin.to_string symbol)
      rate
      (Price.to_string mark)
      (List.map payments ~f:(fun p ->
         sprintf "%s:%s" (short_addr p.account) (Usd.to_string p.payment))
       |> String.concat ~sep:" ")
;;

let print_events ex =
  List.iter (Exchange.drain_events ex) ~f:(fun e -> print_endline (summarize e))
;;

let%expect_test "resting, crossing, and the info views" =
  let ex = fresh () in
  Exchange.step ex ~now:1_000_000_000;
  place ex 1 Sell "100000" "0.01" ~cloid:(cloid 1);
  place ex 1 Sell "100100" "0.02";
  place ex 2 Buy "100100" "0.015";
  [%expect
    {|
    (Resting (oid 1) (cloid (0x00000000000000000000000000000001)))
    (Resting (oid 2) (cloid ()))
    (Filled (oid 3) (total_sz 0.015) (avg_px 100033.33333333) (cloid ()))
    |}];
  print_events ex;
  [%expect
    {|
    accepted 0001 oid=1 A 0.01@100000
    accepted 0001 oid=2 A 0.02@100100
    fill tid=1 0.01@100000 taker=0002(Open Long fee 0.45) maker=0001(Open Short fee 0.15)
    filled 0001 oid=1 A 0@100000
    fill tid=2 0.005@100100 taker=0002(Open Long fee 0.225225) maker=0001(Open Short fee 0.075075)
    filled 0002 oid=3 B 0@100100
    |}];
  print_s [%sexp (Adapt.open_orders ex (addr 1) : Open_order.t list)];
  print_s [%sexp (Adapt.user_fills ex (addr 2) : User_fill.t list)];
  print_s [%sexp (Adapt.l2_book ex btc : L2_book.t option)];
  print_s [%sexp (Adapt.all_mids ex : All_mids.t)];
  [%expect
    {|
    (((coin BTC) (side Sell) (limit_px 100100) (sz 0.015) (oid 2)
      (timestamp 1000) (orig_sz (0.02)) (cloid ())))
    (((coin BTC) (px 100100) (sz 0.005) (side Buy) (time 1000)
      (start_position 0.01) (dir "Open Long") (closed_pnl 0)
      (hash 0x0000000000000000000000000000000000000000000000000000000000000002)
      (oid 3) (crossed true) (fee 0.225225) (tid 2) (fee_token (USDC))
      (cloid ()))
     ((coin BTC) (px 100000) (sz 0.01) (side Buy) (time 1000) (start_position 0)
      (dir "Open Long") (closed_pnl 0)
      (hash 0x0000000000000000000000000000000000000000000000000000000000000001)
      (oid 3) (crossed true) (fee 0.45) (tid 1) (fee_token (USDC)) (cloid ())))
    (((coin BTC) (time 1000) (bids ()) (asks (((px 100100) (sz 0.015) (n 1))))))
    ()
    |}];
  print_s [%sexp (Adapt.clearinghouse_state ex (addr 2) : Clearinghouse_state.t)];
  [%expect
    {|
    ((positions
      (((coin BTC) (szi 0.015) (entry_px (100033.33333333))
        (position_value 1501.5) (unrealized_pnl 1.00000001) (liquidation_px ())
        (leverage (Cross (value 20))) (margin_used 75.075) (max_leverage 40))))
     (margin_summary
      ((account_value 10000.32477501) (total_ntl_pos 1501.5)
       (total_raw_usd 9999.324775) (total_margin_used 75.075)))
     (cross_margin_summary
      ((account_value 10000.32477501) (total_ntl_pos 1501.5)
       (total_raw_usd 9999.324775) (total_margin_used 75.075)))
     (cross_maintenance_margin_used 18.76875) (withdrawable 9925.24977501)
     (time 1000))
    |}]
;;

let%expect_test "rejections" =
  let ex = fresh () in
  place ex 1 Buy "100000" "0.000001";
  place ex 1 Buy "100000.5" "0.01";
  place ex 1 Buy "1000.0001" "0.01";
  place ex 1 Buy "100000" "0.0001";
  place ex 1 Buy "100000" "3";
  place ex 1 ~tif:Ioc Buy "100000" "0.01";
  place ex 1 ~reduce_only:true Sell "100000" "0.01";
  place ex 1 Sell "100000" "0.01";
  place ex 2 ~tif:Alo Buy "100000" "0.01";
  place ex 1 ~cloid:(cloid 7) Sell "100001" "0.01";
  place ex 1 ~cloid:(cloid 7) Sell "100002" "0.01";
  print_s
    [%sexp
      (Adapt.place_order ex (addr 1) { (order Buy "1" "10") with asset = Asset.of_int 9 }
       : Order_status.t)];
  print_s
    [%sexp
      (Adapt.place_order
         ex
         (addr 1)
         { (order Buy "1" "10") with
           order_type = Trigger { is_market = true; trigger_px = px "1"; tpsl = Sl }
         }
       : Order_status.t)];
  [%expect
    {|
    (Error "Order has invalid size. asset=0")
    (Error "Price must be divisible by tick size. asset=0")
    (Error "Price must be divisible by tick size. asset=0")
    (Resting (oid 4) (cloid ()))
    (Error "Insufficient margin to place order. asset=0")
    (Error
     "Order could not immediately match against any resting orders. asset=0")
    (Error "Reduce only order would increase position. asset=0")
    (Error "Order would have matched against own resting order. asset=0")
    (Resting (oid 9) (cloid ()))
    (Resting (oid 10) (cloid (0x00000000000000000000000000000007)))
    (Error "Duplicate cloid. asset=0")
    (Error "Asset 9 does not exist.")
    (Error "Trigger orders are not supported.")
    |}]
;;

let%expect_test "self-trade, IOC partial fill and market orders" =
  let ex = fresh () in
  place ex 1 Sell "100000" "0.01";
  place ex 2 Sell "100100" "0.01";
  place ex 1 Buy "100200" "0.02";
  [%expect
    {|
    (Resting (oid 1) (cloid ()))
    (Resting (oid 2) (cloid ()))
    (Error "Order would have matched against own resting order. asset=0")
    |}];
  place ex 3 ~tif:Ioc Buy "100100" "0.05";
  [%expect {| (Filled (oid 4) (total_sz 0.02) (avg_px 100050) (cloid ())) |}];
  place ex 1 Buy "99000" "0.01";
  place ex 1 Buy "98000" "0.01";
  print_s
    [%sexp
      (Adapt.market_order ex (addr 3) ~coin:btc ~side:Sell ~sz:(sz "0.03")
       : Order_status.t)];
  [%expect
    {|
    (Resting (oid 5) (cloid ()))
    (Resting (oid 6) (cloid ()))
    (Filled (oid 7) (total_sz 0.02) (avg_px 98500) (cloid ()))
    |}];
  print_events ex;
  [%expect
    {|
    accepted 0001 oid=1 A 0.01@100000
    accepted 0002 oid=2 A 0.01@100100
    rejected 0001 Order would have matched against own resting order. asset=0
    fill tid=1 0.01@100000 taker=0003(Open Long fee 0.45) maker=0001(Open Short fee 0.15)
    filled 0001 oid=1 A 0@100000
    fill tid=2 0.01@100100 taker=0003(Open Long fee 0.45045) maker=0002(Open Short fee 0.15015)
    filled 0002 oid=2 A 0@100100
    cancelled 0003 oid=4 B 0.03@100100 Ioc_unfilled
    accepted 0001 oid=5 B 0.01@99000
    accepted 0001 oid=6 B 0.01@98000
    fill tid=3 0.01@99000 taker=0003(Close Long fee 0.4455) maker=0001(Close Short fee 0.1485)
    filled 0001 oid=5 B 0@99000
    fill tid=4 0.01@98000 taker=0003(Close Long fee 0.441) maker=0001(Open Long fee 0.147)
    filled 0001 oid=6 B 0@98000
    cancelled 0003 oid=7 A 0.01@94050 Ioc_unfilled
    |}]
;;

let%expect_test "cancel, cancel by cloid and modify" =
  let ex = fresh () in
  place ex 1 Buy "99000" "0.01" ~cloid:(cloid 1);
  place ex 1 Buy "98000" "0.01" ~cloid:(cloid 2);
  place ex 1 Buy "97000" "0.01";
  let cancel n oid =
    print_s
      [%sexp
        (Adapt.cancel ex (addr n) { asset = btc_asset; oid = Order_id.of_int oid }
         : Cancel_status.t)]
  in
  cancel 2 1;
  cancel 1 1;
  cancel 1 1;
  print_s
    [%sexp
      (Adapt.cancel_by_cloid ex (addr 1) { asset = btc_asset; cloid = cloid 2 }
       : Cancel_status.t)];
  print_s
    [%sexp
      (Adapt.modify
         ex
         (addr 1)
         { oid = Oid (Order_id.of_int 3)
         ; order = order ~cloid:(cloid 3) Buy "97500" "0.02"
         }
       : Order_status.t)];
  print_s
    [%sexp
      (Adapt.modify
         ex
         (addr 1)
         { oid = Cloid (cloid 3); order = order Buy "97600" "0.02" }
       : Order_status.t)];
  print_s
    [%sexp
      (Adapt.modify
         ex
         (addr 1)
         { oid = Cloid (cloid 3); order = order Buy "97600" "0.02" }
       : Order_status.t)];
  [%expect
    {|
    (Resting (oid 1) (cloid (0x00000000000000000000000000000001)))
    (Resting (oid 2) (cloid (0x00000000000000000000000000000002)))
    (Resting (oid 3) (cloid ()))
    (Error "Order was never placed, already canceled, or filled. asset=0")
    Success
    (Error "Order was never placed, already canceled, or filled. asset=0")
    Success
    (Resting (oid 4) (cloid (0x00000000000000000000000000000003)))
    (Resting (oid 5) (cloid ()))
    (Error "Cannot modify canceled or filled order")
    |}];
  print_events ex;
  print_s [%sexp (Adapt.open_orders ex (addr 1) : Open_order.t list)];
  [%expect
    {|
    accepted 0001 oid=1 B 0.01@99000
    accepted 0001 oid=2 B 0.01@98000
    accepted 0001 oid=3 B 0.01@97000
    cancelled 0001 oid=1 B 0.01@99000 User
    cancelled 0001 oid=2 B 0.01@98000 User
    cancelled 0001 oid=3 B 0.01@97000 Modified
    accepted 0001 oid=4 B 0.02@97500
    cancelled 0001 oid=4 B 0.02@97500 Modified
    accepted 0001 oid=5 B 0.02@97600
    rejected 0001 Cannot modify canceled or filled order
    (((coin BTC) (side Buy) (limit_px 97600) (sz 0.02) (oid 5) (timestamp 0)
      (orig_sz (0.02)) (cloid ())))
    |}]
;;

let%expect_test "reduce-only orders are clipped to the position" =
  let ex = fresh () in
  place ex 2 Sell "100000" "0.02";
  place ex 1 Buy "100000" "0.02";
  place ex 3 Buy "99000" "1";
  place ex 1 ~reduce_only:true Sell "99000" "0.05";
  place ex 1 ~reduce_only:true Sell "99000" "0.05";
  [%expect
    {|
    (Resting (oid 1) (cloid ()))
    (Filled (oid 2) (total_sz 0.02) (avg_px 100000) (cloid ()))
    (Resting (oid 3) (cloid ()))
    (Filled (oid 4) (total_sz 0.02) (avg_px 99000) (cloid ()))
    (Error "Reduce only order would increase position. asset=0")
    |}]
;;

let%expect_test "set_mark liquidates and cancels the account's orders" =
  let ex = fresh () in
  Exchange.deposit ex (addr 4) (usd "60");
  place ex 2 Sell "100000" "0.02";
  place ex 4 Buy "100000" "0.01";
  place ex 4 Buy "90000" "0.0002";
  ignore (Exchange.drain_events ex);
  (* BTC max leverage is 40x, so maintenance is 1/80 of notional. Account value is $60 -
     $0.35 fee + 0.01 * (mark - 100000). *)
  Exchange.set_mark ex btc (px "95500");
  print_events ex;
  [%expect
    {|
    (Resting (oid 1) (cloid ()))
    (Filled (oid 2) (total_sz 0.01) (avg_px 100000) (cloid ()))
    (Resting (oid 3) (cloid ()))
    |}];
  Exchange.set_mark ex btc (px "94500");
  print_events ex;
  print_s [%sexp (Adapt.open_orders ex (addr 4) : Open_order.t list)];
  [%expect
    {|
    liquidation 0004 BTC 0.01@94500 pnl -55
    cancelled 0004 oid=3 B 0.0002@90000 Liquidated
    ()
    |}]
;;

let%expect_test "step charges hourly funding" =
  let ex = fresh () in
  place ex 2 Sell "100000" "0.1";
  place ex 1 Buy "100000" "0.1";
  ignore (Exchange.drain_events ex);
  let hour = 3_600_000_000_000 in
  Exchange.step ex ~now:(hour - 1);
  print_events ex;
  [%expect
    {|
    (Resting (oid 1) (cloid ()))
    (Filled (oid 2) (total_sz 0.1) (avg_px 100000) (cloid ()))
    |}];
  Exchange.step ex ~now:(hour + 1);
  print_events ex;
  [%expect {| funding BTC rate=1.25e-05 mark=100000 0001:0.125 0002:-0.125 |}];
  Exchange.set_funding_rate ex btc (-0.0001);
  Exchange.step ex ~now:((3 * hour) + 5);
  print_events ex;
  [%expect
    {|
    funding BTC rate=-0.0001 mark=100000 0001:-1 0002:1
    funding BTC rate=-0.0001 mark=100000 0001:-1 0002:1
    |}]
;;

let%test_unit "random order flow keeps books uncrossed and conserves value" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    List.gen_with_length
      80
      (let%map owner = Int.gen_incl 1 3
       and side = Quickcheck.Generator.of_list Side.all
       and px = Int.gen_incl 990 1010
       and sz = Int.gen_incl 1 20
       and tif = Quickcheck.Generator.of_list Tif.all
       and cancel =
         Quickcheck.Generator.weighted_union
           [ 4., return None; 1., Int.gen_incl 1 80 >>| Option.some ]
       in
       owner, side, px * 100, sz, tif, cancel)
  in
  Quickcheck.test
    ~trials:100
    ~sexp_of:[%sexp_of: (int * Side.t * int * int * Tif.t * int option) list]
    gen
    ~f:(fun ops ->
      let ex = fresh () in
      List.iter ops ~f:(fun (owner, side, p, s, tif, cancel) ->
        (match cancel with
         | Some oid ->
           ignore
             (Adapt.cancel
                ex
                (addr owner)
                { asset = btc_asset; oid = Order_id.of_int oid }
              : Cancel_status.t)
         | None ->
           ignore
             (Adapt.place_order
                ex
                (addr owner)
                (order ~tif side (Int.to_string p) (sprintf "0.%03d" s))
              : Order_status.t));
        Order_book.invariant (Option.value_exn (Exchange.book ex btc)));
      let ch = Exchange.clearinghouse ex in
      let total =
        Usd.sum
          (Exchange_core_engine.Clearinghouse.fees_collected ch
           :: List.map [ 1; 2; 3 ] ~f:(fun n ->
             Exchange_core_engine.Clearinghouse.equity
               ch
               (addr n)
               ~mark:(Exchange.mark ex)))
      in
      assert (Usd.( <= ) (Usd.abs (Usd.( - ) total (usd "30000"))) (usd "0.0001"));
      (* Every resting order is listed exactly once in its owner's open orders. *)
      let listed =
        List.concat_map [ 1; 2; 3 ] ~f:(fun n -> Adapt.open_orders ex (addr n))
      in
      [%test_result: int]
        (List.length listed)
        ~expect:(Order_book.length (Option.value_exn (Exchange.book ex btc))))
;;
