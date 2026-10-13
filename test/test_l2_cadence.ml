open! Core
open! Async
open! Hl_protocol
open! Hl_sim

let mm = Helpers.addr 0xaa

let bid px : Exchange_request.t =
  { action =
      Order
        { orders =
            [ { asset = Asset.of_int 0
              ; is_buy = true
              ; limit_px = Helpers.px px
              ; sz = Helpers.sz "0.01"
              ; reduce_only = false
              ; order_type = Limit { tif = Gtc }
              ; cloid = None
              }
            ]
        ; grouping = Na
        }
  ; nonce = 1
  ; signature = None
  ; vault_address = None
  }
;;

let%expect_test "l2Book: first change after one block, later ones coalesced an interval \
                 apart"
  =
  Log.Global.set_output [];
  let interval = Time_ns.Span.of_int_ms 300 in
  let server =
    Server.create
      ~config:{ Server.Config.default with l2_book_interval = interval }
      ~now:(fun () -> 1_700_000_000_000_000_000)
      (Adapt.create_exchange ())
  in
  let%bind http = Server.listen server ~port:0 in
  let%bind incoming, outgoing = Ws_helpers.connect (Server.port http) in
  Pipe.write_without_pushback
    outgoing
    {|{"method":"subscribe","subscription":{"type":"l2Book","coin":"BTC"}}|};
  (* The echo and the snapshot. *)
  let%bind _ = Pipe.read incoming in
  let%bind _ = Pipe.read incoming in
  let started = Time_ns.now () in
  let place px =
    ignore (Server.handle_exchange server mm (bid px) : Exchange_response.t)
  in
  let next () =
    let%map msg = Pipe.read incoming in
    let levels =
      match msg with
      | `Ok text ->
        Yojson.Safe.Util.(
          Yojson.Safe.from_string text
          |> member "data"
          |> member "levels"
          |> index 0
          |> to_list
          |> List.length)
      | `Eof -> -1
    in
    levels, Time_ns.diff (Time_ns.now ()) started
  in
  place "99000";
  let%bind first_levels, first_at = next () in
  place "98000";
  place "97000";
  let%bind second_levels, second_at = next () in
  print_s
    [%message
      ""
        (first_levels : int)
        ~first_before_interval:(Time_ns.Span.(first_at < interval) : bool)
        (second_levels : int)
        ~second_an_interval_later:(Time_ns.Span.(second_at >= interval) : bool)];
  [%expect
    {|
    ((first_levels 1) (first_before_interval true) (second_levels 3)
     (second_an_interval_later true))
    |}];
  Pipe.close outgoing;
  Cohttp_async.Server.close http
;;
