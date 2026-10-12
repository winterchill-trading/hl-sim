open! Core
open! Hl_sim

let%expect_test "anchor specs" =
  List.iter
    [ "binance:BTCUSDT=BTC"; "hyperliquid:ETH"; " bybit:SOLUSDT = SOL " ]
    ~f:(fun s ->
      let spec = Anchoring.Spec.of_string s in
      print_s
        [%message (spec : Anchoring.Spec.t) ~round_trip:(Anchoring.Spec.to_string spec)]);
  [%expect
    {|
    ((spec ((reference ((venue Binance) (symbol BTCUSDT))) (sim_symbol BTC)))
     (round_trip binance:BTCUSDT=BTC))
    ((spec ((reference ((venue Hyperliquid) (symbol ETH))) (sim_symbol ETH)))
     (round_trip hyperliquid:ETH=ETH))
    ((spec ((reference ((venue Bybit) (symbol SOLUSDT))) (sim_symbol SOL)))
     (round_trip bybit:SOLUSDT=SOL))
    |}];
  Expect_test_helpers_core.require_does_raise (fun () ->
    Anchoring.Spec.of_string "BTCUSDT=BTC");
  [%expect {| ("Instrument.of_string: expected <venue>:<symbol>" BTCUSDT) |}]
;;

let%expect_test "normalizers of the linked clients" =
  List.iter [ Market_data.Venue.Hyperliquid; Binance; Bybit ] ~f:(fun venue ->
    print_s
      [%sexp
        (Anchoring.normalizer venue |> Or_error.map ~f:Market_data.Normalizer.venue
         : Market_data.Venue.t Or_error.t)]);
  [%expect
    {|
    (Ok Hyperliquid)
    (Ok Binance)
    (Error
     ("no client for this reference venue" (venue Bybit)
      (supported_venues (Hyperliquid Binance))))
    |}]
;;
