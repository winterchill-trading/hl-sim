open! Core
open! Hl_protocol
open! Hl_sim

(* 1700000000000 ms. *)
let start = 1_700_000_000_000_000_000
let mm = Helpers.addr 0xaa
let taker = Helpers.addr 0xab

let order ~is_buy ~px ~tif =
  sprintf
    {|{"a":0,"b":%b,"p":"%s","s":"0.01","r":false,"t":{"limit":{"tif":"%s"}}}|}
    is_buy
    px
    tif
;;

let%expect_test "expiresAfter and modify without always-place" =
  Async.Log.Global.set_output [];
  let server = Server.create ~now:(fun () -> start) (Adapt.create_exchange ()) in
  let exchange ?(who = mm) ?(extra = "") action =
    print_endline
      (Yojson.Safe.to_string
         (Exchange_response.yojson_of_t
            (Server.handle_exchange_json
               server
               ~x_address:(Some who)
               (Yojson.Safe.from_string
                  (sprintf {|{"action":%s,"nonce":1%s}|} action extra)))))
  in
  let place ?who ?extra o =
    exchange ?who ?extra (sprintf {|{"type":"order","orders":[%s],"grouping":"na"}|} o)
  in
  place
    ~extra:{|,"expiresAfter":1699999999999|}
    (order ~is_buy:false ~px:"101000" ~tif:"Gtc");
  place
    ~extra:{|,"expiresAfter":1700000000000|}
    (order ~is_buy:false ~px:"101000" ~tif:"Gtc");
  [%expect
    {|
    {"status":"err","response":"Action expired: expiresAfter 1699999999999 is in the past."}
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1}}]}}}
    |}];
  (* A bid resting at 100000; the ask at 101000 (oid 1) is modified down through it. *)
  place ~who:taker (order ~is_buy:true ~px:"100000" ~tif:"Gtc");
  let modify ?(oid = 1) ?a ~tif () =
    exchange
      (sprintf
         {|{"type":"modify","oid":%d,"order":%s%s}|}
         oid
         (order ~is_buy:false ~px:"99000" ~tif)
         (Option.value_map a ~default:"" ~f:(sprintf {|,"a":%b|})))
  in
  modify ~a:false ~tif:"Ioc" ();
  modify ~a:false ~tif:"Gtc" ();
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":2}}]}}}
    {"status":"err","response":"Modify without always-place needs an ALO or GTC replacement."}
    {"status":"err","response":"Post only order would have immediately matched, bbo was 100000@none. asset=0"}
    |}];
  (* The rejected ALO replacement left oid 1 cancelled, as any failed modify does. A new
     ask, modified without [a], crosses and fills. *)
  place (order ~is_buy:false ~px:"101000" ~tif:"Gtc");
  modify ~oid:4 ~tif:"Gtc" ();
  [%expect
    {|
    {"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":4}}]}}}
    {"status":"ok","response":{"type":"default"}}
    |}]
;;
