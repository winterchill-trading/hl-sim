open! Core
open! Hl_protocol
open! Hl_sim
open! Exchange_core_engine

let run ~seed ~ticks =
  let exchange = Adapt.create_exchange () in
  let meta = Adapt.meta exchange in
  let sim =
    Market_sim.create { Market_sim.Config.default with seed; noise_traders = 4 } exchange
  in
  let counts = String.Table.create () in
  for i = 1 to ticks do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    List.iter (Exchange.drain_events exchange) ~f:(fun e ->
      let name =
        match e with
        | Order_rejected { symbol; reason; _ } ->
          "rejected: " ^ Adapt.reject_message meta ?coin:symbol reason
        | _ ->
          (match [%sexp_of: Event.t] e with
           | List (Atom name :: _) | Atom name -> name
           | List _ -> "?")
      in
      Hashtbl.incr counts name)
  done;
  exchange, sim, counts
;;

let%expect_test "noise traders keep a two-sided book around the reference price" =
  let exchange, sim, counts = run ~seed:7 ~ticks:200 in
  let btc = Coin.of_string "BTC" in
  let book = Option.value_exn (Adapt.l2_book exchange btc ~n_levels:3) in
  print_s
    [%message
      ""
        ~reference:(Market_sim.reference_price sim btc : Price.t option)
        ~best_bid:(L2_book.best_bid book : L2_book.Level.t option)
        ~best_ask:(L2_book.best_ask book : L2_book.Level.t option)
        ~events:
          (Hashtbl.to_alist counts |> List.sort ~compare:[%compare: string * int]
           : (string * int) list)];
  [%expect
    {|
    ((reference (100222)) (best_bid (((px 100172) (sz 0.01674) (n 1))))
     (best_ask (((px 100253) (sz 0.01122) (n 1))))
     (events
      ((Fill 112) (Order_accepted 756) (Order_cancelled 642) (Order_filled 112)
       ("rejected: Order could not immediately match against any resting orders. asset=0"
        1)
       ("rejected: Order could not immediately match against any resting orders. asset=2"
        1))))
    |}]
;;

let%expect_test "same seed, same run" =
  let digest seed =
    let exchange, _, _ = run ~seed ~ticks:50 in
    Adapt.all_mids exchange
  in
  print_s [%sexp ([%equal: All_mids.t] (digest 3) (digest 3) : bool)];
  [%expect {| true |}];
  print_s [%sexp ([%equal: All_mids.t] (digest 3) (digest 4) : bool)];
  [%expect {| false |}]
;;
