open! Core
open! Async
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Market_sim = Exchange_core_engine.Market_sim

module Config = struct
  type t =
    { initial_balance : Usd.t
    ; default_address : Address.t
    ; l2_book_interval : Time_ns.Span.t
    ; all_mids_interval : Time_ns.Span.t
    ; step_interval : Time_ns.Span.t
    ; response_delay : Time_ns.Span.t
    ; max_ws_queue : int
    }
  [@@deriving sexp_of]

  let default =
    { initial_balance = Usd.of_int 1_000_000
    ; default_address = Address.of_string "0x0000000000000000000000000000000000000001"
    ; l2_book_interval = Time_ns.Span.of_int_ms 50
    ; all_mids_interval = Time_ns.Span.second
    ; step_interval = Time_ns.Span.second
    ; response_delay = Time_ns.Span.zero
    ; max_ws_queue = 10_000
    }
  ;;
end

module Conn = struct
  type t =
    { id : int
    ; send : string Pipe.Writer.t
    ; max_queue : int
    ; disconnect : unit -> unit
    ; mutable subs : Subscription.Set.t
    }
end

type t =
  { exchange : Exchange.t
  ; config : Config.t
  ; now : unit -> int
  ; seen : Address.Hash_set.t
  ; conns : Conn.t Int.Table.t
  ; mutable next_conn_id : int
  ; dirty_books : Coin.Hash_set.t
  ; mutable l2_flush_scheduled : bool
  ; journal : Journal.t option
  }

let wall_clock () = Time_ns.now () |> Time_ns.to_int_ns_since_epoch
let config t = t.config
let num_ws_connections t = Hashtbl.length t.conns

let step_clock t =
  let now = t.now () in
  if now > Exchange.now t.exchange then Exchange.step t.exchange ~now
;;

let create ?(config = Config.default) ?(now = wall_clock) ?journal exchange =
  let t =
    { exchange
    ; config
    ; now
    ; seen = Address.Hash_set.create ()
    ; conns = Int.Table.create ()
    ; next_conn_id = 0
    ; dirty_books = Coin.Hash_set.create ()
    ; l2_flush_scheduled = false
    ; journal
    }
  in
  step_clock t;
  ignore (Exchange.drain_events exchange : Event.t list);
  t
;;

let ensure_account t address =
  if not (Hash_set.mem t.seen address)
  then (
    Hash_set.add t.seen address;
    Exchange.deposit t.exchange address t.config.initial_balance;
    Log.Global.debug_s
      [%message
        "credited initial balance"
          (address : Address.t)
          ~usd:(t.config.initial_balance : Usd.t)])
;;

(* Websocket fan-out *)

let encode_ws msg = Yojson.Safe.to_string (Ws_message.yojson_of_t msg)

(* A subscriber that does not read lets its queue grow (async_websocket writes the next
   batch only once the socket has taken the previous one); past [max_queue] messages it is
   disconnected rather than buffered without bound. *)
let send_text (conn : Conn.t) text =
  if Pipe.length conn.send >= conn.max_queue
  then conn.disconnect ()
  else Pipe.write_without_pushback_if_open conn.send text
;;

let send conn msg = send_text conn (encode_ws msg)

let broadcast t sub msg =
  let subscribers =
    Hashtbl.data t.conns |> List.filter ~f:(fun (c : Conn.t) -> Set.mem c.subs sub)
  in
  if not (List.is_empty subscribers)
  then (
    let text = encode_ws msg in
    List.iter subscribers ~f:(fun c -> send_text c text))
;;

let flush_l2 t =
  t.l2_flush_scheduled <- false;
  let coins = Hash_set.to_list t.dirty_books |> List.sort ~compare:Coin.compare in
  Hash_set.clear t.dirty_books;
  List.iter coins ~f:(fun coin ->
    Option.iter (Adapt.l2_book t.exchange coin) ~f:(fun book ->
      broadcast t (L2_book { coin }) (L2_book book)))
;;

let schedule_l2_flush t =
  if (not t.l2_flush_scheduled) && not (Hash_set.is_empty t.dirty_books)
  then (
    t.l2_flush_scheduled <- true;
    Clock_ns.run_after t.config.l2_book_interval (fun () -> flush_l2 t) ())
;;

let log_event (event : Event.t) =
  match event with
  | Fill { fill; _ } ->
    Log.Global.info
      "fill %s %s %s@%s taker=%s maker=%s tid=%s"
      (Coin.to_string fill.symbol)
      (Side.to_wire fill.taker_side)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (Address.to_string fill.taker)
      (Address.to_string fill.maker)
      (Exchange_core.Trade_id.to_string fill.tid)
  | Liquidation { liquidation = l; _ } ->
    Log.Global.info
      "liquidation %s %s %s@%s pnl=%s"
      (Address.to_string l.account)
      (Coin.to_string l.symbol)
      (Size.to_string l.size)
      (Price.to_string l.px)
      (Usd.to_string l.pnl)
  | Order_accepted _ | Order_rejected _ | Order_filled _ | Order_cancelled _ | Funding _
    -> Log.Global.debug_s [%sexp (event : Event.t)]
;;

let publish t =
  let events = Exchange.drain_events t.exchange in
  List.iter events ~f:log_event;
  let trades, fills, updates =
    List.fold
      events
      ~init:(Coin.Map.empty, Address.Map.empty, Address.Map.empty)
      ~f:(fun (trades, fills, updates) event ->
        Option.iter (Event.book_symbol event) ~f:(Hash_set.add t.dirty_books);
        let updates =
          match Adapt.order_update event with
          | Some (address, update) -> Map.add_multi updates ~key:address ~data:update
          | None -> updates
        in
        match event with
        | Fill { fill; taker; maker } ->
          let user_fill settlement = Adapt.user_fill { fill; settlement } in
          ( Map.add_multi trades ~key:fill.symbol ~data:(Adapt.trade fill)
          , Map.add_multi
              (Map.add_multi fills ~key:fill.taker ~data:(user_fill taker))
              ~key:fill.maker
              ~data:(user_fill maker)
          , updates )
        | _ -> trades, fills, updates)
  in
  Map.iteri trades ~f:(fun ~key:coin ~data ->
    broadcast t (Trades { coin }) (Trades (List.rev data)));
  Map.iteri fills ~f:(fun ~key:user ~data ->
    broadcast
      t
      (User_fills { user })
      (User_fills { is_snapshot = false; user; fills = List.rev data }));
  Map.iteri updates ~f:(fun ~key:user ~data ->
    broadcast t (Order_updates { user }) (Order_updates (List.rev data)));
  schedule_l2_flush t
;;

let mutate t ~f =
  step_clock t;
  let result = f t.exchange in
  publish t;
  result
;;

(* Request handlers *)

let handle_info t (req : Info_request.t) =
  (match req with
   | Open_orders { user } | User_fills { user } | Clearinghouse_state { user } ->
     ensure_account t user
   | L2_book _ | All_mids | Meta -> ());
  mutate t ~f:(fun ex ->
    let response : Info_response.t option =
      match req with
      | L2_book { coin; n_sig_figs = _; mantissa = _ } ->
        Adapt.l2_book ex coin |> Option.map ~f:(fun b -> Info_response.L2_book b)
      | All_mids -> Some (All_mids (Adapt.all_mids ex))
      | Open_orders { user } -> Some (Open_orders (Adapt.open_orders ex user))
      | User_fills { user } -> Some (User_fills (Adapt.user_fills ex user))
      | Clearinghouse_state { user } ->
        Some (Clearinghouse_state (Adapt.clearinghouse_state ex user))
      | Meta -> Some (Meta (Adapt.meta ex))
    in
    match response with
    | Some r -> Info_response.yojson_of_t r
    | None -> `Null)
;;

let handle_exchange t address (req : Exchange_request.t) : Exchange_response.t =
  ensure_account t address;
  mutate t ~f:(fun ex ->
    Option.iter t.journal ~f:(fun journal ->
      Journal.write journal { time = Exchange.now ex; address; request = req });
    match req.action with
    | Order { orders; grouping = _ } ->
      Exchange_response.Ok (Order (List.map orders ~f:(Adapt.place_order ex address)))
    | Cancel { cancels } ->
      Exchange_response.Ok (Cancel (List.map cancels ~f:(Adapt.cancel ex address)))
    | Cancel_by_cloid { cancels } ->
      Exchange_response.Ok
        (Cancel (List.map cancels ~f:(Adapt.cancel_by_cloid ex address)))
    | Modify modify ->
      (match Adapt.modify ex address modify with
       | Error msg -> Exchange_response.Err msg
       | Resting _ | Filled _ | Waiting_for_fill | Waiting_for_trigger ->
         Exchange_response.Ok Default))
;;

let replay ?config exchange entries =
  let clock =
    ref
      (match entries with
       | (first : Journal.Entry.t) :: _ -> first.time
       | [] -> Exchange.now exchange)
  in
  let t = create ?config ~now:(fun () -> !clock) exchange in
  let responses =
    List.map entries ~f:(fun { time; address; request } ->
      clock := time;
      handle_exchange t address request)
  in
  t, responses
;;

(* Websocket connections *)

let ws_snapshot t conn (sub : Subscription.t) =
  match sub with
  | L2_book { coin } ->
    Option.iter (Adapt.l2_book t.exchange coin) ~f:(fun book -> send conn (L2_book book))
  | All_mids -> send conn (All_mids (Adapt.all_mids t.exchange))
  | User_fills { user } ->
    ensure_account t user;
    send
      conn
      (User_fills { is_snapshot = true; user; fills = Adapt.user_fills t.exchange user })
  | Order_updates { user } -> ensure_account t user
  | Trades _ -> ()
;;

let handle_ws_message t (conn : Conn.t) text =
  match Ws_request.t_of_yojson (Yojson.Safe.from_string text) with
  | exception _ ->
    Log.Global.debug "ws %d: invalid message %s" conn.id text;
    send conn (Error (sprintf "Invalid message: %s" text))
  | Ping -> send conn Pong
  | Subscribe sub as req ->
    Log.Global.debug_s
      [%message "ws subscribe" ~conn:(conn.id : int) (sub : Subscription.t)];
    conn.subs <- Set.add conn.subs sub;
    send conn (Subscription_response req);
    ws_snapshot t conn sub
  | Unsubscribe sub as req ->
    conn.subs <- Set.remove conn.subs sub;
    send conn (Subscription_response req)
;;

let handle_ws t reader writer =
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  let incoming, outgoing = Websocket.pipes ws in
  let id = t.next_conn_id in
  t.next_conn_id <- id + 1;
  let disconnect () =
    if Hashtbl.mem t.conns id
    then (
      Hashtbl.remove t.conns id;
      Log.Global.info
        "ws %d: disconnected slow consumer (%d messages queued)"
        id
        (Pipe.length outgoing);
      Pipe.close outgoing;
      (* The close frame would wait behind the unread data; drop the socket now. *)
      don't_wait_for (Writer.close ~force_close:Deferred.unit writer))
  in
  let conn =
    { Conn.id
    ; send = outgoing
    ; max_queue = t.config.max_ws_queue
    ; disconnect
    ; subs = Subscription.Set.empty
    }
  in
  Hashtbl.set t.conns ~key:id ~data:conn;
  Log.Global.debug "ws %d: connected" id;
  let%map () = Pipe.iter_without_pushback incoming ~f:(handle_ws_message t conn) in
  Hashtbl.remove t.conns id;
  Pipe.close outgoing;
  Log.Global.debug "ws %d: disconnected" id
;;

(* HTTP *)

let json_headers = Cohttp.Header.of_list [ "content-type", "application/json" ]

let respond_json ?(status = `OK) json =
  let%map response =
    Cohttp_async.Server.respond_string
      ~headers:json_headers
      ~status
      (Yojson.Safe.to_string json)
  in
  `Response response
;;

let respond_error status msg = respond_json ~status (`Assoc [ "error", `String msg ])

let error_message = function
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure msg, _) | Failure msg -> msg
  | Yojson.Json_error msg -> msg
  | exn -> Exn.to_string exn
;;

(* Parses and decodes the body, then runs [f]; decoding failures and exceptions raised by
   [f] become a 400 response. *)
let with_body body ~decode ~f =
  let%bind body = Cohttp_async.Body.to_string body in
  match decode (Yojson.Safe.from_string body) with
  | exception exn -> respond_error `Bad_request (error_message exn)
  | req ->
    (match f req with
     | exception exn -> respond_error `Bad_request (error_message exn)
     | json -> respond_json json)
;;

let acting_address t req (exchange_req : Exchange_request.t) =
  match Cohttp.Header.get (Cohttp.Request.headers req) "x-address" with
  | Some a -> Address.of_string a
  | None -> Option.value exchange_req.vault_address ~default:t.config.default_address
;;

let header_is req name value =
  match Cohttp.Header.get (Cohttp.Request.headers req) name with
  | Some v ->
    String.split v ~on:','
    |> List.exists ~f:(fun v -> String.Caseless.equal (String.strip v) value)
  | None -> false
;;

let ws_upgrade t req =
  match Cohttp.Header.get (Cohttp.Request.headers req) "sec-websocket-key" with
  | None -> respond_error `Bad_request "missing Sec-WebSocket-Key"
  | Some key ->
    let headers =
      Cohttp.Header.of_list
        [ "upgrade", "websocket"
        ; "connection", "Upgrade"
        ; ( "sec-websocket-accept"
          , Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key )
        ]
    in
    (* [Http.Response.make], unlike [Cohttp.Response.make], does not add
       [transfer-encoding: chunked], which is invalid on a 101. *)
    let response = Http.Response.make ~status:`Switching_protocols ~headers () in
    return (`Expert (response, fun reader writer -> handle_ws t reader writer))
;;

let handler t ~body _addr req =
  match Cohttp.Request.meth req, Uri.path (Cohttp.Request.uri req) with
  | `POST, "/info" -> with_body body ~decode:Info_request.t_of_yojson ~f:(handle_info t)
  | `POST, "/exchange" ->
    let%bind response =
      with_body body ~decode:Exchange_request.t_of_yojson ~f:(fun exchange_req ->
        let address = acting_address t req exchange_req in
        handle_exchange t address exchange_req |> Exchange_response.yojson_of_t)
    in
    let%map () =
      if Time_ns.Span.(t.config.response_delay > zero)
      then Clock_ns.after t.config.response_delay
      else return ()
    in
    response
  | `GET, ("/ws" | "/") when header_is req "upgrade" "websocket" -> ws_upgrade t req
  | _, path -> respond_error `Not_found (sprintf "no route for %s" path)
;;

let listen t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (handler t)
;;

let port server = Cohttp_async.Server.listening_on server

let start_periodic t =
  Clock_ns.every t.config.all_mids_interval (fun () ->
    broadcast t All_mids (All_mids (Adapt.all_mids t.exchange)));
  Clock_ns.every t.config.step_interval (fun () -> mutate t ~f:ignore)
;;

let run_market_sim t sim =
  Clock_ns.every (Market_sim.config sim).tick_interval (fun () ->
    mutate t ~f:(fun _ -> Market_sim.tick sim))
;;
