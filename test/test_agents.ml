open! Core
open! Hl_protocol
open! Hl_sim

let user = Helpers.addr 0x01
let approve ?name t agent = Agents.approve_agent t ~user ~agent:(Helpers.addr agent) ~name

let show t =
  print_s
    [%message
      ""
        ~agents:(Agents.agents t user : Agents.Agent.t list)
        ~owner_a1:(Agents.owner t (Helpers.addr 0xa1) : Address.t option)
        ~owner_a2:(Agents.owner t (Helpers.addr 0xa2) : Address.t option)]
;;

let%expect_test "one unnamed and three named agents" =
  let t = Agents.create () in
  let r = [%sexp_of: (unit, string) Result.t] in
  print_s (r (approve t 0xa1));
  print_s (r (approve t 0xa2));
  show t;
  List.iteri [ 0xb1; 0xb2; 0xb3; 0xb4 ] ~f:(fun i a ->
    print_s (r (approve t a ~name:(sprintf "n%d" i))));
  print_s (r (approve t 0xb5 ~name:"n0"));
  print_s (r (approve t 0x01));
  print_s
    (r
       (Agents.approve_agent
          t
          ~user:(Helpers.addr 0x02)
          ~agent:(Helpers.addr 0xa2)
          ~name:None));
  show t;
  [%expect
    {|
    (Ok ())
    (Ok ())
    ((agents (((name ()) (address 0x00000000000000000000000000000000000000a2))))
     (owner_a1 ()) (owner_a2 (0x0000000000000000000000000000000000000001)))
    (Ok ())
    (Ok ())
    (Ok ())
    (Error "Too many named agents: at most 3 per account.")
    (Ok ())
    (Error "Cannot approve the account itself as its agent.")
    (Error "Agent address is already in use.")
    ((agents
      (((name ()) (address 0x00000000000000000000000000000000000000a2))
       ((name (n0)) (address 0x00000000000000000000000000000000000000b5))
       ((name (n1)) (address 0x00000000000000000000000000000000000000b2))
       ((name (n2)) (address 0x00000000000000000000000000000000000000b3))))
     (owner_a1 ()) (owner_a2 (0x0000000000000000000000000000000000000001)))
    |}]
;;

let%expect_test "nonces" =
  let t = Agents.create () in
  let now_ms = 1_700_000_000_000 in
  let day = 86_400_000 in
  let signer = Helpers.addr 0xa1 in
  let use nonce =
    print_s
      [%sexp
        (nonce - now_ms : int)
        , (Agents.use_nonce t ~signer ~nonce ~now_ms : (unit, string) Result.t)]
  in
  List.iter
    [ 0; 0; -2 * day; day; (-2 * day) + 1; day - 1 ]
    ~f:(fun d -> use (now_ms + d));
  (* Fill the set with the 100 highest, then something below its smallest. *)
  List.iter (List.range 1 200) ~f:(fun i ->
    ignore (Agents.use_nonce t ~signer ~nonce:(now_ms + (i * 1000)) ~now_ms : _ Result.t));
  use (now_ms + 50_000);
  use (now_ms + 150_500);
  [%expect
    {|
    (0 (Ok ()))
    (0 (Error "Invalid nonce: 1700000000000 was already used."))
    (-172800000
     (Error "Invalid nonce: 1699827200000 is outside the time window."))
    (86400000 (Error "Invalid nonce: 1700086400000 is outside the time window."))
    (-172799999 (Ok ()))
    (86399999 (Ok ()))
    (50000 (Error "Invalid nonce: 1700000050000 is too low."))
    (150500 (Ok ()))
    |}]
;;

let%expect_test "builder approvals" =
  let t = Agents.create () in
  let r = [%sexp_of: (unit, string) Result.t] in
  let approve b tenths_bps =
    print_s (r (Agents.approve_builder_fee t ~user ~builder:(Helpers.addr b) ~tenths_bps))
  in
  approve 0xb0 10;
  approve 0xb0 1001;
  List.iter (List.range 0xc0 0xc9) ~f:(fun b -> approve b 1);
  approve 0xd0 1;
  approve 0xb0 0;
  approve 0xd0 5;
  print_s
    [%sexp
      (List.map [ 0xb0; 0xc0; 0xd0; 0xee ] ~f:(fun b ->
         Agents.max_builder_fee t ~user ~builder:(Helpers.addr b))
       : int list)];
  [%expect
    {|
    (Ok ())
    (Error "Max fee rate is above the 1% limit.")
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Ok ())
    (Error "Too many builder fee approvals: at most 10 per account.")
    (Ok ())
    (Ok ())
    (0 1 5 0)
    |}]
;;
