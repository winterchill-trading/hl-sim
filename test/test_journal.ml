open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let start = 1_700_000_000_000_000_000
let users = List.init 4 ~f:(fun i -> Helpers.addr (0xa0 + i))

let request json =
  Exchange_request.t_of_yojson
    (Yojson.Safe.from_string (sprintf {|{"action":%s,"nonce":1}|} json))
;;

let order ~asset ~is_buy ~px ~sz ~tif =
  request
    (sprintf
       {|{"type":"order","orders":[{"a":%d,"b":%b,"p":"%s","s":"%s","r":false,"t":{"limit":{"tif":"%s"}}}],"grouping":"na"}|}
       asset
       is_buy
       px
       sz
       tif)
;;

let cancel ~asset ~oid =
  request (sprintf {|{"type":"cancel","cancels":[{"a":%d,"o":%d}]}|} asset oid)
;;

(* A seeded random session: limit orders around a drifting price in BTC and ETH, IOC
   takers and cancels of earlier order ids, with the clock advancing by up to 20 minutes
   per request (so funding boundaries are crossed). *)
let session ~seed ~n =
  let rand = Random.State.make [| seed |] in
  let mid = ref 100_000 in
  List.init n ~f:(fun i ->
    let user = List.nth_exn users (Random.State.int rand (List.length users)) in
    let dt = Random.State.int rand 1_200_000_000_000 in
    mid := !mid + Random.State.int_incl rand (-50) 50;
    let asset = Random.State.int rand 2 in
    let scale px = if asset = 0 then px else px / 30 in
    let is_buy = Random.State.bool rand in
    let req =
      match Random.State.int rand 10 with
      | 0 | 1 -> cancel ~asset ~oid:(1 + Random.State.int rand (i + 1))
      | 2 | 3 ->
        let px = scale (if is_buy then !mid + 200 else !mid - 200) in
        order ~asset ~is_buy ~px:(Int.to_string px) ~sz:"0.01" ~tif:"Ioc"
      | _ ->
        let offset = Random.State.int_incl rand (-30) 100 in
        let px = scale (if is_buy then !mid - offset else !mid + offset) in
        order
          ~asset
          ~is_buy
          ~px:(Int.to_string px)
          ~sz:(sprintf "0.0%d" (1 + Random.State.int rand 9))
          ~tif:"Gtc"
    in
    dt, user, req)
;;

let fills server_exchange =
  List.map users ~f:(fun user -> user, Adapt.user_fills server_exchange user)
;;

let with_tmp_file f =
  let path = Filename_unix.temp_file "hl-sim-journal" ".jsonl" in
  Monitor.protect (fun () -> f path) ~finally:(fun () -> Unix.unlink path)
;;

let%expect_test "an entry is one line of JSON" =
  let entry : Journal.Entry.t =
    { time = start
    ; address = Helpers.addr 0xa0
    ; request = order ~asset:0 ~is_buy:true ~px:"100000" ~sz:"0.01" ~tif:"Gtc"
    }
  in
  let line = Journal.Entry.to_line entry in
  print_endline line;
  [%expect
    {| {"time":1700000000000000000,"address":"0x00000000000000000000000000000000000000a0","request":{"action":{"type":"order","orders":[{"a":0,"b":true,"p":"100000","s":"0.01","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}} |}];
  print_s [%sexp (Journal.Entry.equal entry (Journal.Entry.of_line line) : bool)];
  [%expect {| true |}];
  return ()
;;

let%expect_test "replaying a journal into a fresh sim gives identical fills" =
  Log.Global.set_output [];
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ 1; 2; 3 ] ~f:(fun seed ->
      with_tmp_file (fun path ->
        let%bind journal = Journal.open_file path in
        let clock = ref start in
        let exchange = Adapt.create_exchange () in
        let server = Server.create ~now:(fun () -> !clock) ~journal exchange in
        let responses =
          List.map (session ~seed ~n:300) ~f:(fun (dt, user, req) ->
            clock := !clock + dt;
            Server.handle_exchange server user req)
        in
        let%bind () = Journal.close journal in
        let%map entries = Journal.load path in
        let replayed_exchange = Adapt.create_exchange () in
        let _replayed, replayed_responses = Server.replay replayed_exchange entries in
        let original = fills exchange in
        let num_fills = List.sum (module Int) original ~f:(fun (_, f) -> List.length f) in
        print_s
          [%message
            ""
              (seed : int)
              ~entries:(List.length entries : int)
              (num_fills : int)
              ~same_responses:
                ([%equal: Exchange_response.t list] responses replayed_responses : bool)
              ~same_fills:
                ([%equal: (Address.t * User_fill.t list) list]
                   original
                   (fills replayed_exchange)
                 : bool)
              ~same_state:
                (List.for_all users ~f:(fun user ->
                   [%equal: Clearinghouse_state.t]
                     (Adapt.clearinghouse_state exchange user)
                     (Adapt.clearinghouse_state replayed_exchange user))
                 : bool)]))
  in
  [%expect
    {|
    ((seed 1) (entries 300) (num_fills 248) (same_responses true)
     (same_fills true) (same_state true))
    ((seed 2) (entries 300) (num_fills 212) (same_responses true)
     (same_fills true) (same_state true))
    ((seed 3) (entries 300) (num_fills 232) (same_responses true)
     (same_fills true) (same_state true))
    |}];
  return ()
;;
