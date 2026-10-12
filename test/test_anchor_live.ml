(* One simulator anchored, live, to another one serving as the reference venue. *)

open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let maker = Address.of_string "0x00000000000000000000000000000000000000aa"

let order ~is_buy ~px ~sz =
  sprintf
    {|{"action":{"type":"order","orders":[{"a":0,"b":%b,"p":"%s","s":"%s","r":false,"t":{"limit":{"tif":"Gtc"}}}],"grouping":"na"},"nonce":1}|}
    is_buy
    px
    sz
  |> Yojson.Safe.from_string
  |> Exchange_request.t_of_yojson
;;

let levels server =
  Server.handle_info
    server
    (L2_book { coin = Coin.of_string "BTC"; n_sig_figs = None; mantissa = None })
  |> Yojson.Safe.Util.member "levels"
;;

let rec until ~tries f =
  if f () || tries = 0
  then return ()
  else Clock_ns.after (Time_ns.Span.of_int_ms 20) >>= fun () -> until ~tries:(tries - 1) f
;;

let%expect_test "an anchored coin rests the reference's levels" =
  Log.Global.set_output [];
  let reference = Server.create (Adapt.create_exchange ()) in
  List.iter
    [ order ~is_buy:true ~px:"50000" ~sz:"1"
    ; order ~is_buy:true ~px:"49990" ~sz:"2"
    ; order ~is_buy:false ~px:"50010" ~sz:"3"
    ]
    ~f:(fun req ->
      ignore (Server.handle_exchange reference maker req : Exchange_response.t));
  let%bind http = Server.listen reference ~port:0 in
  let base_url = Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Server.port http) () in
  let sim = Server.create (Adapt.create_exchange ()) in
  let anchoring =
    Anchoring.create ~log:ignore sim (Anchoring.Spec.of_string "hyperliquid:BTC=BTC")
  in
  let%bind source =
    Anchoring.live_source ~base_url (Anchoring.spec anchoring) >>| ok_exn
  in
  let finished = Anchoring.run anchoring source in
  let%bind () =
    until ~tries:250 (fun () ->
      not (Price_anchor.Anchor.is_stale (Anchoring.anchor anchoring)))
  in
  print_s [%sexp (Price_anchor.Anchor.is_stale (Anchoring.anchor anchoring) : bool)];
  print_endline (Yojson.Safe.to_string (levels sim));
  [%expect
    {|
    false
    [[{"px":"50000","sz":"1","n":1},{"px":"49990","sz":"2","n":1}],[{"px":"50010","sz":"3","n":1}]]
    |}];
  Pipe.close_read source;
  let%bind () = finished in
  Cohttp_async.Server.close http
;;
