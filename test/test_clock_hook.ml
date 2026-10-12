open! Core
open! Hl_protocol
open! Hl_sim
module Exchange = Exchange_core_engine.Exchange

let%expect_test "clock-step hooks see the exchange clock, even when it is ahead" =
  let clock = ref 1_000 in
  let exchange = Adapt.create_exchange () in
  let server = Server.create ~now:(fun () -> !clock) exchange in
  Server.on_clock_step server (fun ~now -> printf "first %d\n" now);
  Server.on_clock_step server (fun ~now -> printf "second %d\n" now);
  clock := 2_000;
  Server.mutate server ~f:ignore;
  [%expect {|
    first 2000
    second 2000
    |}];
  (* Something else moved the exchange past the server's clock. *)
  Exchange.step exchange ~now:5_000;
  clock := 3_000;
  Server.mutate server ~f:ignore;
  [%expect {|
    first 5000
    second 5000
    |}]
;;
