open! Core
open! Hl_protocol
open! Hl_sim
open Helpers

let%expect_test "price-time priority: better price first, then oldest first" =
  let b = Book.create () in
  let quiet ?tif owner side p s =
    ignore (Book.limit ~quiet:true ?tif b ~owner side p s)
  in
  quiet 1 Sell "101" "1";
  quiet 2 Sell "100" "1";
  quiet 3 Sell "100" "2";
  quiet 4 Sell "102" "1";
  Book.print_l2 b;
  [%expect {| ((bids ()) (asks ("100 x 3 (2)" "101 x 1 (1)" "102 x 1 (1)"))) |}];
  ignore (Book.limit b ~owner:9 Buy "101" "3.5");
  [%expect
    {|
    ((status Filled) (filled 3.5) (remaining 0)
     (fills
      (((tid 1) (px 100) (sz 1) (taker (5 9)) (maker (2 2)))
       ((tid 2) (px 100) (sz 2) (taker (5 9)) (maker (3 3)))
       ((tid 3) (px 101) (sz 0.5) (taker (5 9)) (maker (1 1))))))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ()) (asks ("101 x 0.5 (1)" "102 x 1 (1)"))) |}]
;;

let%expect_test "partial fill of a resting maker keeps its priority" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Buy "100" "5");
  ignore (Book.limit ~quiet:true b ~owner:2 Buy "100" "1");
  ignore (Book.limit b ~owner:3 Sell "100" "2");
  ignore (Book.limit b ~owner:3 Sell "100" "4");
  [%expect
    {|
    ((status Filled) (filled 2) (remaining 0)
     (fills (((tid 1) (px 100) (sz 2) (taker (3 3)) (maker (1 1))))))
    ((status Filled) (filled 4) (remaining 0)
     (fills
      (((tid 2) (px 100) (sz 3) (taker (4 3)) (maker (1 1)))
       ((tid 3) (px 100) (sz 1) (taker (4 3)) (maker (2 2))))))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ()) (asks ())) |}]
;;

let%expect_test "GTC rests the remainder" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100" "1");
  ignore (Book.limit b ~owner:2 Buy "100.5" "3");
  [%expect
    {|
    ((status Resting) (filled 1) (remaining 2)
     (fills (((tid 1) (px 100) (sz 1) (taker (2 2)) (maker (1 1))))))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ("100.5 x 2 (1)")) (asks ())) |}]
;;

let%expect_test "IOC cancels the remainder" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100" "1");
  ignore (Book.limit ~tif:Ioc b ~owner:2 Buy "100" "3");
  ignore (Book.limit ~tif:Ioc b ~owner:2 Buy "100" "3");
  [%expect
    {|
    ((status (Cancelled Ioc_unfilled)) (filled 1) (remaining 2)
     (fills (((tid 1) (px 100) (sz 1) (taker (2 2)) (maker (1 1))))))
    ((status (Cancelled Ioc_unfilled)) (filled 0) (remaining 3) (fills ()))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ()) (asks ())) |}]
;;

let%expect_test "ALO rejects when it would cross, otherwise rests" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100" "1");
  ignore (Book.limit ~tif:Alo b ~owner:2 Buy "100" "1");
  ignore (Book.limit ~tif:Alo b ~owner:2 Buy "99.5" "1");
  [%expect
    {|
    ((status Would_cross) (filled 0) (remaining 1) (fills ()))
    ((status Resting) (filled 0) (remaining 1) (fills ()))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ("99.5 x 1 (1)")) (asks ("100 x 1 (1)"))) |}]
;;

let%expect_test "self-trade cancels the taker's remainder, keeps earlier fills" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100" "1");
  ignore (Book.limit ~quiet:true b ~owner:2 Sell "100" "1");
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "101" "1");
  ignore (Book.limit b ~owner:2 Buy "101" "3");
  [%expect
    {|
    ((status (Cancelled Self_trade)) (filled 1) (remaining 2)
     (fills (((tid 1) (px 100) (sz 1) (taker (4 2)) (maker (1 1))))))
    |}];
  Book.print_l2 b;
  [%expect {| ((bids ()) (asks ("100 x 1 (1)" "101 x 1 (1)"))) |}]
;;

let%expect_test "market order sweeps within slippage" =
  let b = Book.create () in
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100" "1");
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "100.5" "1");
  ignore (Book.limit ~quiet:true b ~owner:1 Sell "102" "1");
  (* 100 bps above the best ask of 100 is 101, so the 102 level is out of reach. *)
  ignore (Book.market b ~owner:2 Buy "5" ~slippage_bps:100 : Order_book.Result.t);
  [%expect
    {|
    ((status (Cancelled Ioc_unfilled)) (filled 2) (remaining 3)
     (fills
      (((tid 1) (px 100) (sz 1) (taker (4 2)) (maker (1 1)))
       ((tid 2) (px 100.5) (sz 1) (taker (4 2)) (maker (2 1))))))
    |}];
  ignore (Book.market b ~owner:2 Sell "1" ~slippage_bps:100 : Order_book.Result.t);
  [%expect {| ((status (Cancelled Ioc_unfilled)) (filled 0) (remaining 1) (fills ())) |}]
;;

let%expect_test "cancel" =
  let b = Book.create () in
  let oid1, _ = Book.limit ~quiet:true b ~owner:1 Buy "99" "1" in
  let _oid2, _ = Book.limit ~quiet:true b ~owner:2 Buy "99" "2" in
  let show o = print_s [%sexp (o : Order_book.Resting_order.t option)] in
  show (Order_book.cancel (Book.book b) oid1);
  show (Order_book.cancel (Book.book b) oid1);
  [%expect
    {|
    (((oid 1) (owner 0x0000000000000000000000000000000000000001) (side Buy)
      (px 99) (remaining 1) (orig_sz 1) (timestamp 1) (reduce_only false)
      (cloid ())))
    ()
    |}];
  Book.print_l2 b;
  Order_book.invariant (Book.book b);
  [%expect {| ((bids ("99 x 2 (1)")) (asks ())) |}]
;;

let%expect_test "L2 snapshot: best first, aggregated, truncated to n levels" =
  let b = Book.create () in
  List.iter
    [ "99", "1"; "98", "2"; "99", "0.5"; "97", "1"; "96", "1" ]
    ~f:(fun (p, s) -> ignore (Book.limit ~quiet:true b ~owner:1 Buy p s));
  List.iter
    [ "101", "1"; "102", "3"; "101", "0.25" ]
    ~f:(fun (p, s) -> ignore (Book.limit ~quiet:true b ~owner:2 Sell p s));
  Book.print_l2 b ~n_levels:3;
  print_s
    [%message
      ""
        ~best_bid:(Order_book.best_bid (Book.book b) : Price.t option)
        ~best_ask:(Order_book.best_ask (Book.book b) : Price.t option)
        ~mid:(Order_book.mid (Book.book b) : Price.t option)];
  [%expect
    {|
    ((bids ("99 x 1.5 (2)" "98 x 2 (1)" "97 x 1 (1)"))
     (asks ("101 x 1.25 (2)" "102 x 3 (1)")))
    ((best_bid (99)) (best_ask (101)) (mid (100)))
    |}]
;;

(* Property tests over random operation sequences. *)

module Op = struct
  type t =
    | Limit of
        { owner : int
        ; side : Side.t
        ; px : int
        ; sz : int
        ; tif : Tif.t
        }
    | Market of
        { owner : int
        ; side : Side.t
        ; sz : int
        }
    | Cancel of int
  [@@deriving sexp_of]

  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let owner = Int.gen_incl 1 4 in
    let side = Quickcheck.Generator.of_list Side.all in
    Quickcheck.Generator.weighted_union
      [ ( 6.
        , let%map owner
          and side
          and px = Int.gen_incl 95 105
          and sz = Int.gen_incl 1 5
          and tif = Quickcheck.Generator.of_list Tif.all in
          Limit { owner; side; px; sz; tif } )
      ; ( 1.
        , let%map owner
          and side
          and sz = Int.gen_incl 1 8 in
          Market { owner; side; sz } )
      ; (2., Int.gen_incl 0 1000 >>| fun i -> Cancel i)
      ]
  ;;
end

let total_size (fills : Fill.t list) = Size.sum (List.map fills ~f:(fun f -> f.sz))

let run_op b (op : Op.t) =
  let book = Book.book b in
  let before =
    Order_book.orders book
    |> List.map ~f:(fun (o : Order_book.Resting_order.t) -> o.oid, o.remaining)
  in
  let check_result ~sz (r : Order_book.Result.t) =
    (* Taker side: what was filled is the sum of fill sizes, and filled plus remaining is
       the order size. *)
    [%test_result: Size.t] (total_size r.fills) ~expect:r.filled;
    [%test_result: Size.t] (Size.( + ) r.filled r.remaining) ~expect:(Size.of_int sz);
    assert (not (Size.is_negative r.remaining));
    (* Maker side: each maker's remaining size dropped by exactly its fills. *)
    let by_maker =
      List.fold r.fills ~init:Order_id.Map.empty ~f:(fun acc (f : Fill.t) ->
        assert (Size.is_positive f.sz);
        Map.update acc f.maker_oid ~f:(fun prev ->
          Size.( + ) (Option.value prev ~default:Size.zero) f.sz))
    in
    List.iter before ~f:(fun (oid, was) ->
      let now =
        Order_book.find book oid
        |> Option.value_map ~default:Size.zero ~f:(fun (o : Order_book.Resting_order.t) ->
          o.remaining)
      in
      let taken = Map.find by_maker oid |> Option.value ~default:Size.zero in
      [%test_result: Size.t] (Size.( - ) was now) ~expect:taken)
  in
  (match op with
   | Limit { owner; side; px; sz; tif } ->
     let _, r =
       Book.limit ~quiet:true ~tif b ~owner side (Int.to_string px) (Int.to_string sz)
     in
     check_result ~sz r
   | Market { owner; side; sz } ->
     check_result
       ~sz
       (Book.market ~quiet:true b ~owner side (Int.to_string sz) ~slippage_bps:300)
   | Cancel i ->
     (match List.nth before (i % Int.max 1 (List.length before)) with
      | None -> ()
      | Some (oid, _) -> assert (Option.is_some (Order_book.cancel book oid))));
  Order_book.invariant book;
  (match Order_book.best_bid book, Order_book.best_ask book with
   | Some bid, Some ask -> assert (Price.( < ) bid ask)
   | _ -> ());
  Order_book.iter book ~f:(fun o -> assert (Size.is_positive o.remaining))
;;

let%test_unit "random operation sequences preserve book invariants and conserve size" =
  Quickcheck.test
    ~trials:500
    ~sexp_of:[%sexp_of: Op.t list]
    (Quickcheck.Generator.list_with_length 60 Op.gen)
    ~f:(fun ops ->
      let b = Book.create () in
      List.iter ops ~f:(run_op b);
      (* Cancelling every resting order empties the book. *)
      let book = Book.book b in
      List.iter (Order_book.orders book) ~f:(fun o ->
        assert (Option.is_some (Order_book.cancel book o.oid)));
      Order_book.invariant book;
      assert (Order_book.is_empty book);
      assert (Option.is_none (Order_book.best_bid book));
      assert (Option.is_none (Order_book.best_ask book)))
;;

let%test_unit "a single taker sweeps 200k makers" =
  let book = Order_book.create btc in
  let n = 200_000 in
  let add ~oid ~owner side p s =
    Order_book.add_limit
      book
      ~oid:(Order_id.of_int oid)
      ~owner:(addr owner)
      ~side
      ~px:(Price.of_int p)
      ~sz:(Size.of_int s)
      ~tif:Gtc
      ~time:oid
      ~next_tid:(fun () -> oid)
      ()
  in
  for i = 1 to n do
    ignore (add ~oid:i ~owner:(1 + (i % 2)) Sell (100 + (i % 50)) 1 : Order_book.Result.t)
  done;
  let r = add ~oid:(n + 1) ~owner:3 Buy 1000 n in
  [%test_result: int] (List.length r.fills) ~expect:n;
  assert (Order_book.is_empty book)
;;
