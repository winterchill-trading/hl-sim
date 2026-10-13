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
    ; strict_signatures : bool
    ; is_mainnet : bool
    ; max_ws_users : int
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
    ; strict_signatures = false
    ; is_mainnet = false
    ; max_ws_users = 10
    }
  ;;
end

module Order_key = struct
  module T = struct
    type t = Address.t * Exchange_core.Order_id.t [@@deriving sexp, compare, hash]
  end

  include T
  include Hashable.Make (T)
end

module Conn = struct
  type t =
    { id : int
    ; send : string Pipe.Writer.t
    ; max_queue : int
    ; disconnect : unit -> unit
    ; mutable subs : Subscription.Set.t
    ; mutable ctx_coins : Coin.Set.t (** [activeAssetCtx] subscriptions *)
    }
end

type t =
  { exchange : Exchange.t
  ; config : Config.t
  ; now : unit -> int
  ; seen : Address.Hash_set.t
  ; conns : Conn.t Int.Table.t
  ; mutable next_conn_id : int
  ; mutable num_ws_dropped : int
  ; dirty_books : Coin.Hash_set.t
  ; mutable l2_flush_scheduled : bool
  ; journal : Journal.t option
  ; day_stats : Active_asset_ctx.Day_stats.t
  ; mutable on_clock_step : (now:int -> unit) list
  ; mutable status : (string * (unit -> Yojson.Safe.t)) list
  ; agents : Agents.t
  ; builder_orders : Builder.t Order_key.Table.t
  (** resting or just-filled orders placed with a builder code *)
  }

let wall_clock () = Time_ns.now () |> Time_ns.to_int_ns_since_epoch
let config t = t.config
let agents t = t.agents
let num_ws_connections t = Hashtbl.length t.conns
let num_ws_dropped t = t.num_ws_dropped

let step_clock t =
  let now = t.now () in
  if now > Exchange.now t.exchange then Exchange.step t.exchange ~now;
  let now = Exchange.now t.exchange in
  List.iter t.on_clock_step ~f:(fun f -> f ~now)
;;

let on_clock_step t f = t.on_clock_step <- t.on_clock_step @ [ f ]
let add_status t ~name f = t.status <- t.status @ [ name, f ]

let status t : Yojson.Safe.t =
  `Assoc
    ([ "ws_connections", `Int (Hashtbl.length t.conns)
     ; "ws_dropped", `Int t.num_ws_dropped
     ]
     @ List.map t.status ~f:(fun (name, f) -> name, f ()))
;;

let create ?(config = Config.default) ?(now = wall_clock) ?journal exchange =
  let t =
    { exchange
    ; config
    ; now
    ; seen = Address.Hash_set.create ()
    ; conns = Int.Table.create ()
    ; next_conn_id = 0
    ; num_ws_dropped = 0
    ; dirty_books = Coin.Hash_set.create ()
    ; l2_flush_scheduled = false
    ; journal
    ; day_stats = Active_asset_ctx.Day_stats.create ()
    ; on_clock_step = []
    ; status = []
    ; agents = Agents.create ()
    ; builder_orders = Order_key.Table.create ()
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

let send_json conn json = send_text conn (Yojson.Safe.to_string json)

let send_ctx t conn coin =
  Option.iter (Active_asset_ctx.of_exchange t.exchange t.day_stats coin) ~f:(fun ctx ->
    send_json conn (Active_asset_ctx.to_ws_message ctx))
;;

(* One [activeAssetCtx] message per subscribed coin, encoded once. *)
let broadcast_ctx t =
  let conns = Hashtbl.data t.conns in
  let coins =
    List.fold conns ~init:Coin.Set.empty ~f:(fun acc (c : Conn.t) ->
      Set.union acc c.ctx_coins)
  in
  Set.iter coins ~f:(fun coin ->
    Option.iter (Active_asset_ctx.of_exchange t.exchange t.day_stats coin) ~f:(fun ctx ->
      let text = Yojson.Safe.to_string (Active_asset_ctx.to_ws_message ctx) in
      List.iter conns ~f:(fun (c : Conn.t) ->
        if Set.mem c.ctx_coins coin then send_text c text)))
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

(* The builder fee of each side of a fill whose order carries a builder code: taken from
   the user's balance and credited to the builder. Both are plain deposits, so the
   engine's input journal replays them. Orders leave the table once filled or cancelled. *)
let charge_builder_fees t events =
  List.iter events ~f:(fun (event : Event.t) ->
    match Event.executions event with
    | None -> ()
    | Some (taker, maker) ->
      List.iter [ taker; maker ] ~f:(fun (e : Exchange_core_engine.Execution.t) ->
        let account = e.settlement.account in
        Option.iter
          (Hashtbl.find
             t.builder_orders
             (account, Exchange_core_engine.Execution.order_id e))
          ~f:(fun builder ->
            let fee = Builder.fee builder ~px:e.fill.px ~sz:e.fill.sz in
            if Usd.is_positive fee
            then (
              Exchange.deposit t.exchange account (Usd.neg fee);
              Exchange.deposit t.exchange builder.b fee))));
  List.iter events ~f:(fun (event : Event.t) ->
    match event with
    | Order_filled { account; order; _ } | Order_cancelled { account; order; _ } ->
      Hashtbl.remove t.builder_orders (account, order.order_id)
    | _ -> ())
;;

let publish t =
  let events = Exchange.drain_events t.exchange in
  if not (Hashtbl.is_empty t.builder_orders) then charge_builder_fees t events;
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
          Active_asset_ctx.Day_stats.record_trade
            t.day_stats
            ~coin:fill.symbol
            ~px:fill.px
            ~sz:fill.sz
            ~time:fill.time;
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

let publish_events t = publish t

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

(* Hyperliquid checks the builder code before placing any order of the action. *)
let check_builder t ex address (builder : Builder.t) =
  if builder.f < 0 || builder.f > Builder.max_perp_fee
  then (* sim wording *) Error "Builder fee is above the 0.1% perps limit."
  else if Agents.max_builder_fee t.agents ~user:address ~builder:builder.b < builder.f
  then Error "Builder fee has not been approved."
  else if Usd.( < )
            (Exchange.account_view ex builder.b).equity
            Builder.min_builder_account_value
  then (* sim wording *) Error "Builder has insufficient balance to be builder."
  else Ok ()
;;

let place_with_builder t ex address builder orders =
  match check_builder t ex address builder with
  | Error msg -> Exchange_response.Err msg
  | Ok () ->
    Exchange_response.Ok
      (Order
         (List.map orders ~f:(fun order ->
            let status = Adapt.place_order ex address order in
            (match status with
             | Resting { oid; _ } | Filled { oid; _ } ->
               Hashtbl.set t.builder_orders ~key:(address, oid) ~data:builder
             | Error _ | Waiting_for_fill | Waiting_for_trigger -> ());
            status)))
;;

let handle_exchange ?builder t address (req : Exchange_request.t) : Exchange_response.t =
  ensure_account t address;
  mutate t ~f:(fun ex ->
    Option.iter t.journal ~f:(fun journal ->
      Journal.write journal { time = Exchange.now ex; address; request = req; builder });
    match req.action with
    | Order { orders; grouping = _ } ->
      (match builder with
       | Some builder ->
         ensure_account t builder.b;
         place_with_builder t ex address builder orders
       | None ->
         Exchange_response.Ok (Order (List.map orders ~f:(Adapt.place_order ex address))))
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

let handle_user_action ?signature t address (action : User_action.t) : Exchange_response.t
  =
  ensure_account t address;
  mutate t ~f:(fun ex ->
    Option.iter t.journal ~f:(fun journal ->
      Journal.write_record
        journal
        (User_action { time = Exchange.now ex; address; user_action = action; signature }));
    let result =
      match action with
      | Approve_agent approve -> Agents.approve_agent t.agents ~user:address approve
      | Approve_builder_fee approve ->
        (* Funding the builder here, inside the journaled request, keeps replays exact. *)
        ensure_account t approve.builder;
        (match Builder.tenths_bps_of_rate approve.max_fee_rate with
         | Error _ -> Error (sprintf "Invalid max fee rate %s." approve.max_fee_rate)
         | Ok tenths_bps ->
           Agents.approve_builder_fee
             t.agents
             ~user:address
             ~builder:approve.builder
             ~tenths_bps)
    in
    match result with
    | Ok () -> Exchange_response.Ok Default
    | Error msg -> Exchange_response.Err msg)
;;

let replay ?config exchange records =
  let time_of : Journal.Record.t -> int = function
    | Request e -> e.time
    | User_action e -> e.time
  in
  let clock =
    ref
      (match records with
       | first :: _ -> time_of first
       | [] -> Exchange.now exchange)
  in
  let t = create ?config ~now:(fun () -> !clock) exchange in
  let responses =
    List.map records ~f:(fun record ->
      clock := time_of record;
      match record with
      | Request { address; request; builder; time = _ } ->
        handle_exchange ?builder t address request
      | User_action { address; user_action; signature; time = _ } ->
        handle_user_action ?signature t address user_action)
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

let handle_ctx_request t (conn : Conn.t) (req : Active_asset_ctx.Request.t) =
  Log.Global.debug_s
    [%message
      "ws activeAssetCtx" ~conn:(conn.id : int) (req : Active_asset_ctx.Request.t)];
  conn.ctx_coins
  <- (if req.subscribe
      then Set.add conn.ctx_coins req.coin
      else Set.remove conn.ctx_coins req.coin);
  send_json conn (Active_asset_ctx.Request.response req);
  if req.subscribe then send_ctx t conn req.coin
;;

let decode_ws_request text =
  let json = Yojson.Safe.from_string text in
  match Active_asset_ctx.Request.of_json json with
  | Some req -> `Ctx req
  | None -> `Request (Ws_request.t_of_yojson json)
;;

let handle_ws_message t (conn : Conn.t) text =
  match decode_ws_request text with
  | `Ctx req -> handle_ctx_request t conn req
  | exception _ ->
    Log.Global.debug "ws %d: invalid message %s" conn.id text;
    send conn (Error (sprintf "Invalid message: %s" text))
  | `Request Ping -> send conn Pong
  | `Request (Subscribe sub as req) ->
    Log.Global.debug_s
      [%message "ws subscribe" ~conn:(conn.id : int) (sub : Subscription.t)];
    conn.subs <- Set.add conn.subs sub;
    send conn (Subscription_response req);
    ws_snapshot t conn sub
  | `Request (Unsubscribe sub as req) ->
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
      t.num_ws_dropped <- t.num_ws_dropped + 1;
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
    ; ctx_coins = Coin.Set.empty
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

(* Who acts for a request: signatures are checked where the copy-trading flow needs them,
   and the simulator's permissive defaults apply everywhere else (see the .mli). *)

let unsigned_address t ~x_address ~vault_address =
  match x_address with
  | Some a -> a
  | None -> Option.value vault_address ~default:t.config.default_address
;;

let now_ms t = Int.max (t.now ()) (Exchange.now t.exchange) / 1_000_000

let use_nonce t ~signer ~nonce =
  Agents.use_nonce t.agents ~signer ~nonce ~now_ms:(now_ms t)
;;

(* The addresses that may have signed an L1 action: one per signing domain (testnet "b"
   and mainnet "a"), or only the configured one in strict mode. *)
let l1_signers t json (req : Exchange_request.t) signature =
  match Hl_client.Signing.Signature.t_of_yojson signature with
  | exception _ -> []
  | signature ->
    let expires_after =
      match Json.member json ~key:"expiresAfter" with
      | Some (`Int n) -> Some n
      | _ -> None
    in
    let connection_id =
      Hl_client.Signing.action_hash
        ?expires_after
        ~vault_address:req.vault_address
        ~nonce:req.nonce
        (Json.member_exn json ~key:"action")
    in
    let networks =
      if t.config.strict_signatures then [ t.config.is_mainnet ] else [ false; true ]
    in
    List.filter_map networks ~f:(fun is_mainnet ->
      Hl_client.Signing.recover
        ~digest:(Hl_client.Signing.l1_digest ~is_mainnet ~connection_id)
        signature
      |> Result.ok)
;;

let resolve_l1 t ~x_address json (req : Exchange_request.t) =
  let open Result.Let_syntax in
  let fallback () = Ok (unsigned_address t ~x_address ~vault_address:req.vault_address) in
  match req.signature with
  | None | Some `Null ->
    if t.config.strict_signatures then Error "Missing signature." else fallback ()
  | Some signature ->
    let signers = l1_signers t json req signature in
    (match
       List.find_map signers ~f:(fun signer ->
         Option.map (Agents.owner t.agents signer) ~f:(fun owner -> signer, owner))
     with
     | Some (agent, owner) ->
       let%map () = use_nonce t ~signer:agent ~nonce:req.nonce in
       owner
     | None when not t.config.strict_signatures -> fallback ()
     | None ->
       (match signers with
        | [] -> Error "Invalid signature."
        | signer :: _ ->
          let%map () = use_nonce t ~signer ~nonce:req.nonce in
          signer))
;;

let resolve_user_action t ~x_address action ~signature =
  let open Result.Let_syntax in
  match signature with
  | None ->
    if t.config.strict_signatures
    then Error "Missing signature."
    else Ok (unsigned_address t ~x_address ~vault_address:None)
  | Some signature ->
    (match User_action.signer action ~signature with
     | Error _ -> Error "Invalid signature."
     | Ok signer when Option.is_some (Agents.owner t.agents signer) ->
       (* sim wording *)
       Error
         (sprintf
            "%s must be signed by the account owner, not an agent."
            (User_action.type_tag action))
     | Ok signer ->
       let%map () = use_nonce t ~signer ~nonce:(User_action.nonce action) in
       signer)
;;

let handle_exchange_json t ~x_address json : Exchange_response.t =
  let action = Json.member_exn json ~key:"action" in
  match User_action.of_action_json action with
  | Some user_action ->
    let signature =
      match Json.member json ~key:"signature" with
      | None | Some `Null -> None
      | Some s -> Some s
    in
    (match resolve_user_action t ~x_address user_action ~signature with
     | Error msg -> Err msg
     | Ok address -> handle_user_action ?signature t address user_action)
  | None ->
    let req = Exchange_request.t_of_yojson json in
    let builder =
      match req.action with
      | Order _ -> Builder.of_action_json action
      | Cancel _ | Cancel_by_cloid _ | Modify _ -> None
    in
    (match resolve_l1 t ~x_address json req with
     | Error msg -> Err msg
     | Ok address -> handle_exchange ?builder t address req)
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
      with_body body ~decode:Fn.id ~f:(fun json ->
        let x_address =
          Cohttp.Header.get (Cohttp.Request.headers req) "x-address"
          |> Option.map ~f:Address.of_string
        in
        handle_exchange_json t ~x_address json |> Exchange_response.yojson_of_t)
    in
    let%map () =
      if Time_ns.Span.(t.config.response_delay > zero)
      then Clock_ns.after t.config.response_delay
      else return ()
    in
    response
  | `GET, "/status" -> respond_json (status t)
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
    broadcast t All_mids (All_mids (Adapt.all_mids t.exchange));
    broadcast_ctx t);
  Clock_ns.every t.config.step_interval (fun () -> mutate t ~f:ignore)
;;

let run_market_sim t sim =
  Clock_ns.every (Market_sim.config sim).tick_interval (fun () ->
    mutate t ~f:(fun _ -> Market_sim.tick sim))
;;
