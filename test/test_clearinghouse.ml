open! Core
open! Hl_protocol
open! Hl_sim
open Helpers

let meta : Meta.t =
  { universe =
      [ { name = btc; sz_decimals = 5; max_leverage = 50; only_isolated = false } ]
  }
;;

let tid = ref 0

let fill ~taker ~maker ~side p s : Fill.t =
  incr tid;
  { tid = !tid
  ; coin = btc
  ; px = px p
  ; sz = sz s
  ; taker_side = side
  ; taker_oid = Order_id.of_int (2 * !tid)
  ; maker_oid = Order_id.of_int ((2 * !tid) + 1)
  ; taker = addr taker
  ; maker = addr maker
  ; taker_cloid = None
  ; maker_cloid = None
  ; time = 0
  }
;;

let settle ch f =
  let taker, maker = Clearinghouse.settle_fill ch f in
  let show (s : Clearinghouse.Settlement.t) =
    [%sexp
      { side = (s.side : Side.t)
      ; fee = (s.fee : Usd.t)
      ; dir = (s.change.dir : string)
      ; start = (s.change.start_position : Size.t)
      ; closed_pnl = (s.change.closed_pnl : Usd.t)
      }]
  in
  print_s [%message "" ~taker:(show taker : Sexp.t) ~maker:(show maker : Sexp.t)]
;;

let mark_at p : Clearinghouse.mark = fun _ -> Some (px p)

let print_account ch n ~mark =
  let a = Clearinghouse.account ch (addr n) in
  let pos =
    Account.position a btc
    |> Option.map ~f:(fun (p : Position.t) ->
      [%sexp
        { szi = (p.szi : Size.t)
        ; entry = (p.entry_px : Price.t)
        ; realized = (p.realized_pnl : Usd.t)
        ; upnl = (Position.unrealized_pnl p ~mark:(Option.value_exn (mark btc)) : Usd.t)
        }])
  in
  print_s
    [%message
      ""
        ~account:(n : int)
        ~balance:(a.balance : Usd.t)
        ~value:(Clearinghouse.account_value ch (addr n) ~mark : Usd.t)
        (pos : Sexp.t option)]
;;

let%expect_test "round trip: entry, realised PnL and fees" =
  let ch = Clearinghouse.create meta in
  Clearinghouse.deposit ch (addr 1) (usd "1000");
  Clearinghouse.deposit ch (addr 2) (usd "1000");
  settle ch (fill ~taker:1 ~maker:2 ~side:Buy "100" "1");
  settle ch (fill ~taker:1 ~maker:2 ~side:Buy "110" "1");
  [%expect
    {|
    ((taker ((side Buy) (fee 0.035) (dir "Open Long") (start 0) (closed_pnl 0)))
     (maker ((side Sell) (fee 0.01) (dir "Open Short") (start 0) (closed_pnl 0))))
    ((taker ((side Buy) (fee 0.0385) (dir "Open Long") (start 1) (closed_pnl 0)))
     (maker
      ((side Sell) (fee 0.011) (dir "Open Short") (start -1) (closed_pnl 0))))
    |}];
  print_account ch 1 ~mark:(mark_at "120");
  print_account ch 2 ~mark:(mark_at "120");
  [%expect
    {|
    ((account 1) (balance 999.9265) (value 1029.9265)
     (pos (((szi 2) (entry 105) (realized 0) (upnl 30)))))
    ((account 2) (balance 999.979) (value 969.979)
     (pos (((szi -2) (entry 105) (realized 0) (upnl -30)))))
    |}];
  (* Close at 120: A sells 2 as maker this time. *)
  settle ch (fill ~taker:2 ~maker:1 ~side:Buy "120" "2");
  [%expect
    {|
    ((taker
      ((side Buy) (fee 0.084) (dir "Close Short") (start -2) (closed_pnl -30)))
     (maker
      ((side Sell) (fee 0.024) (dir "Close Long") (start 2) (closed_pnl 30))))
    |}];
  print_account ch 1 ~mark:(mark_at "120");
  print_account ch 2 ~mark:(mark_at "120");
  print_s [%message "" ~fees_collected:(Clearinghouse.fees_collected ch : Usd.t)];
  [%expect
    {|
    ((account 1) (balance 1029.9025) (value 1029.9025) (pos ()))
    ((account 2) (balance 969.895) (value 969.895) (pos ()))
    (fees_collected 0.2025)
    |}]
;;

let%expect_test "flip from long to short reopens at the fill price" =
  let ch = Clearinghouse.create ~fees:Fee_schedule.zero meta in
  settle ch (fill ~taker:1 ~maker:2 ~side:Buy "100" "1");
  settle ch (fill ~taker:1 ~maker:2 ~side:Sell "90" "3");
  [%expect
    {|
    ((taker ((side Buy) (fee 0) (dir "Open Long") (start 0) (closed_pnl 0)))
     (maker ((side Sell) (fee 0) (dir "Open Short") (start 0) (closed_pnl 0))))
    ((taker
      ((side Sell) (fee 0) (dir "Long > Short") (start 1) (closed_pnl -10)))
     (maker ((side Buy) (fee 0) (dir "Short > Long") (start -1) (closed_pnl 10))))
    |}];
  print_account ch 1 ~mark:(mark_at "80");
  [%expect
    {|
    ((account 1) (balance -10) (value 10)
     (pos (((szi -2) (entry 90) (realized -10) (upnl 20)))))
    |}]
;;

let%expect_test "initial margin check and reduce-only size" =
  let ch = Clearinghouse.create meta in
  Clearinghouse.deposit ch (addr 1) (usd "100");
  let check side p s ~reserved =
    print_s
      [%sexp
        (Clearinghouse.check_order_margin
           ch
           (addr 1)
           ~coin:btc
           ~side
           ~px:(px p)
           ~sz:(sz s)
           ~reserved:(usd reserved)
           ~mark:(mark_at "100")
         : unit Or_error.t)]
  in
  (* Default leverage is 20x, so $100 supports $2000 of notional. *)
  check Buy "100" "20" ~reserved:"0";
  check Buy "100" "20.01" ~reserved:"0";
  check Buy "100" "10" ~reserved:"60";
  [%expect
    {|
    (Ok ())
    (Error
     ("Insufficient margin to place order" (required 100.05) (available 100)))
    (Error ("Insufficient margin to place order" (required 50) (available 40)))
    |}];
  print_s [%sexp (Clearinghouse.set_leverage ch (addr 1) btc 51 : unit Or_error.t)];
  print_s [%sexp (Clearinghouse.set_leverage ch (addr 1) btc 50 : unit Or_error.t)];
  check Buy "100" "50" ~reserved:"0";
  [%expect
    {|
    (Error ("Invalid leverage" (coin BTC) (lev 51) (max_leverage 50)))
    (Ok ())
    (Ok ())
    |}];
  ignore (Clearinghouse.set_leverage ch (addr 1) btc 20 : unit Or_error.t);
  Clearinghouse.deposit ch (addr 2) (usd "1000");
  ignore (Clearinghouse.settle_fill ch (fill ~taker:1 ~maker:2 ~side:Buy "100" "15"));
  (* Long 15: selling up to 15 needs no margin, beyond that it is charged. *)
  print_s
    [%message
      ""
        ~reducible_sell:
          (Clearinghouse.reduce_only_size ch (addr 1) ~coin:btc ~side:Sell : Size.t)
        ~reducible_buy:
          (Clearinghouse.reduce_only_size ch (addr 1) ~coin:btc ~side:Buy : Size.t)
        ~margin_sell_15:
          (Clearinghouse.order_margin
             ch
             (addr 1)
             ~coin:btc
             ~side:Sell
             ~px:(px "100")
             ~sz:(sz "15")
           : Usd.t)
        ~margin_sell_20:
          (Clearinghouse.order_margin
             ch
             (addr 1)
             ~coin:btc
             ~side:Sell
             ~px:(px "100")
             ~sz:(sz "20")
           : Usd.t)];
  [%expect
    {|
    ((reducible_sell 15) (reducible_buy 0) (margin_sell_15 0)
     (margin_sell_20 25))
    |}]
;;

let%expect_test "liquidation when account value drops below maintenance margin" =
  let ch = Clearinghouse.create ~fees:Fee_schedule.zero meta in
  Clearinghouse.deposit ch (addr 1) (usd "10");
  Clearinghouse.deposit ch (addr 2) (usd "1000");
  ignore (Clearinghouse.settle_fill ch (fill ~taker:1 ~maker:2 ~side:Buy "100" "1"));
  (* Max leverage 50: maintenance is 1% of notional. *)
  let at p =
    let mark = mark_at p in
    let value = Clearinghouse.account_value ch (addr 1) ~mark in
    let maintenance = Clearinghouse.maintenance_margin ch (addr 1) ~mark in
    let liquidations = Clearinghouse.mark_to_market ch ~mark in
    print_s
      [%message
        ""
          ~mark:p
          (value : Usd.t)
          (maintenance : Usd.t)
          (liquidations : Clearinghouse.Liquidation.t list)]
  in
  let state = Clearinghouse.state ch (addr 1) ~mark:(mark_at "100") ~time:0 in
  print_s
    [%sexp
      (List.map state.positions ~f:(fun p -> p.liquidation_px) : Price.t option list)];
  at "91";
  at "90.9";
  [%expect
    {|
    ((90.90909091))
    ((mark 91) (value 1) (maintenance 0.91) (liquidations ()))
    ((mark 90.9) (value 0.9) (maintenance 0.909)
     (liquidations
      (((address 0x0000000000000000000000000000000000000001) (coin BTC) (szi 1)
        (px 90.9) (pnl -9.1)))))
    |}];
  print_account ch 1 ~mark:(mark_at "90.9");
  [%expect {| ((account 1) (balance 0.9) (value 0.9) (pos ())) |}]
;;

let%expect_test "funding: longs pay shorts when the rate is positive" =
  let ch = Clearinghouse.create ~fees:Fee_schedule.zero meta in
  ignore (Clearinghouse.settle_fill ch (fill ~taker:1 ~maker:2 ~side:Buy "100" "2"));
  ignore (Clearinghouse.settle_fill ch (fill ~taker:3 ~maker:2 ~side:Buy "100" "1"));
  print_s
    [%sexp
      (Clearinghouse.apply_funding ch ~coin:btc ~rate:0.0001 ~mark:(px "100")
       : Clearinghouse.Funding_payment.t list)];
  List.iter [ 1; 2; 3 ] ~f:(fun n ->
    print_s
      [%message
        ""
          ~account:(n : int)
          ~balance:((Clearinghouse.account ch (addr n)).balance : Usd.t)]);
  [%expect
    {|
    (((address 0x0000000000000000000000000000000000000001) (coin BTC) (szi 2)
      (payment 0.02))
     ((address 0x0000000000000000000000000000000000000002) (coin BTC) (szi -3)
      (payment -0.03))
     ((address 0x0000000000000000000000000000000000000003) (coin BTC) (szi 1)
      (payment 0.01)))
    ((account 1) (balance -0.02))
    ((account 2) (balance 0.03))
    ((account 3) (balance -0.01))
    |}]
;;

let%expect_test "clearinghouse state" =
  let ch = Clearinghouse.create meta in
  Clearinghouse.deposit ch (addr 1) (usd "1000");
  Clearinghouse.deposit ch (addr 2) (usd "1000");
  ignore (Clearinghouse.settle_fill ch (fill ~taker:1 ~maker:2 ~side:Sell "100" "2"));
  print_s
    [%sexp
      (Clearinghouse.state ch (addr 1) ~mark:(mark_at "95") ~time:1234
       : Clearinghouse_state.t)];
  [%expect
    {|
    ((positions
      (((coin BTC) (szi -2) (entry_px (100)) (position_value 190)
        (unrealized_pnl 10) (liquidation_px (594.02475248))
        (leverage (Cross (value 20))) (margin_used 9.5) (max_leverage 50))))
     (margin_summary
      ((account_value 1009.93) (total_ntl_pos 190) (total_raw_usd 999.93)
       (total_margin_used 9.5)))
     (cross_margin_summary
      ((account_value 1009.93) (total_ntl_pos 190) (total_raw_usd 999.93)
       (total_margin_used 9.5)))
     (cross_maintenance_margin_used 1.9) (withdrawable 1000.43) (time 1234))
    |}]
;;

let%test_unit "random fills conserve value (balances + unrealised PnL + fees)" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    List.gen_with_length
      40
      (let%map taker = Int.gen_incl 1 4
       and maker_offset = Int.gen_incl 1 3
       and side = Quickcheck.Generator.of_list Side.all
       and px_cents = Int.gen_incl 9_000 11_000
       and sz_milli = Int.gen_incl 1 5_000 in
       taker, ((taker + maker_offset - 1) % 4) + 1, side, px_cents, sz_milli)
  in
  Quickcheck.test
    ~trials:200
    ~sexp_of:[%sexp_of: (int * int * Side.t * int * int) list]
    gen
    ~f:(fun trades ->
      let ch = Clearinghouse.create meta in
      List.iter trades ~f:(fun (taker, maker, side, px_cents, sz_milli) ->
        let p = Price.of_units (px_cents * 1_000_000) in
        let s = Size.of_units (sz_milli * 100_000) in
        ignore
          (Clearinghouse.settle_fill
             ch
             { (fill ~taker ~maker ~side "1" "1") with px = p; sz = s }));
      let mark = mark_at "100" in
      let total =
        Usd.sum
          (Clearinghouse.fees_collected ch
           :: List.map [ 1; 2; 3; 4 ] ~f:(fun n ->
             Clearinghouse.account_value ch (addr n) ~mark))
      in
      (* Average entry prices are truncated to 1e-8, so allow a tiny drift. *)
      assert (Usd.( <= ) (Usd.abs total) (Usd.of_string "0.0001"));
      (* Positions net to zero. *)
      let net =
        Size.sum
          (List.map [ 1; 2; 3; 4 ] ~f:(fun n ->
             match Account.position (Clearinghouse.account ch (addr n)) btc with
             | None -> Size.zero
             | Some p -> p.szi))
      in
      [%test_result: Size.t] net ~expect:Size.zero)
;;
