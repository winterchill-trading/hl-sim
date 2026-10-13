open! Core
open! Hl_protocol
open! Hl_sim

let%expect_test "fee rates" =
  List.iter
    [ "0.1%"; "0.01%"; "0.001%"; "0%"; "1%"; "0.0001%"; "-0.01%"; "0.01"; "x%" ]
    ~f:(fun rate ->
      print_s [%sexp (rate : string), (Builder.tenths_bps_of_rate rate : int Or_error.t)]);
  [%expect
    {|
    (0.1% (Ok 100))
    (0.01% (Ok 10))
    (0.001% (Ok 1))
    (0% (Ok 0))
    (1% (Ok 1000))
    (0.0001% (Error ("invalid maxFeeRate" 0.0001%)))
    (-0.01% (Error ("invalid maxFeeRate" -0.01%)))
    (0.01 (Error ("invalid maxFeeRate" 0.01)))
    (x% (Error ("invalid maxFeeRate" x%)))
    |}]
;;

let%expect_test "fees" =
  let builder f = { Builder.b = Helpers.addr 0xbb; f } in
  List.iter [ 1; 10; 100 ] ~f:(fun f ->
    print_s
      [%sexp
        (f : int)
        , (Builder.fee (builder f) ~px:(Helpers.px "100000") ~sz:(Helpers.sz "0.0123")
           : Usd.t)]);
  [%expect {|
    (1 0.0123)
    (10 0.123)
    (100 1.23)
    |}]
;;

let%expect_test "decoding the builder field" =
  let decode s = Builder.of_action_json (Yojson.Safe.from_string s) in
  print_s [%sexp (decode {|{"type":"order","orders":[]}|} : Builder.t option)];
  print_s
    [%sexp
      (decode
         {|{"type":"order","orders":[],"builder":{"b":"0x00000000000000000000000000000000000000BB","f":10}}|}
       : Builder.t option)];
  [%expect {|
    ()
    (((b 0x00000000000000000000000000000000000000bb) (f 10)))
    |}]
;;
