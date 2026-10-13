open! Core
open! Async
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Market_sim = Exchange_core_engine.Market_sim
module Trigger_event = Exchange_core_engine.Trigger_event
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

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
    ; ws_idle_timeout : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let default =
    { initial_balance = Usd.of_int 1_000_000
    ; default_address = Address.of_string "0x0000000000000000000000000000000000000001"
    ; l2_book_interval = Time_ns.Span.of_int_ms 500
    ; all_mids_interval = Time_ns.Span.second
    ; step_interval = Time_ns.Span.second
    ; response_delay = Time_ns.Span.zero
    ; max_ws_queue = 10_000
    ; strict_signatures = false
    ; is_mainnet = false
    ; max_ws_users = 10
    ; ws_idle_timeout = Time_ns.Span.minute
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
    ; disconnect : [ `Slow | `Idle ] -> unit
    ; mutable last_sent : Time_ns.t (** wall clock *)
    ; mutable subs : Subscription.Set.t
    ; mutable ctx_coins : Coin.Set.t (** [activeAssetCtx] subscriptions *)
    ; mutable web_data_users : Address.Set.t (** [webData2] subscriptions *)
    ; mutable event_users : Address.Set.t (** [userEvents] subscriptions *)
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
  ; mutable num_ws_idle_closed : int
  ; dirty_books : Coin.Hash_set.t
  ; mutable l2_flush_scheduled : bool
  ; mutable last_l2_flush : Time_ns.t
  ; journal : Journal.t option
  ; day_stats : Active_asset_ctx.Day_stats.t
  ; mutable on_clock_step : (now:int -> unit) list
  ; mutable status : (string * (unit -> Yojson.Safe.t)) list
  ; agents : Agents.t
  ; builder_orders : Builder.t Order_key.Table.t
  (** resting or just-filled orders placed with a builder code *)
  ; rankings : Rankings.t
  ; mutable rejection_updates : (Address.t * Order_update.t) list
  (** newest first; published with the request's events *)
  ; scheduled_cancels : int Address.Table.t (** [scheduleCancel] time, ms *)
  ; scheduled_cancel_fires : (int * int) Address.Table.t
  (** UTC day and number of scheduled cancels fired that day *)
  ; scheduled_cancelled : Order_key.Hash_set.t
  (** orders cancelled by a scheduled cancel, until their update is published *)
  ; order_history : Order_update.t Order_key.Table.t (** latest update per order *)
  ; liquidation_orders : User_fill.Liquidation.t Order_key.Table.t
  (** liquidation market orders, by the liquidated account and order id *)
  ; liquidation_trades : User_fill.Liquidation.t Int.Table.t
  (** trades of liquidation orders, by trade id: both sides' fills carry it *)
  ; mutable next_lid : int
  ; trigger_history : Exchange_core_engine.Trigger_order.t Order_key.Table.t
  (** every trigger order placed, for [orderStatus] *)
  ; cloid_history : Order_id.t Cloid.Table.t Address.Table.t
  ; mutable charging_builder_fees : bool
  (** builder fees move money through deposits, which are not deposits to the leaderboard *)
  }

let wall_clock () = Time_ns.now () |> Time_ns.to_int_ns_since_epoch
let config t = t.config
let agents t = t.agents
let num_ws_connections t = Hashtbl.length t.conns
let num_ws_dropped t = t.num_ws_dropped
let ms_per_day = 86_400_000

(* Fires every [scheduleCancel] that is due: cancels all the account's resting orders,
   whose updates then carry the status "scheduledCancel". *)
let fire_scheduled_cancels t =
  if not (Hashtbl.is_empty t.scheduled_cancels)
  then (
    let now_ms = Exchange.now t.exchange / 1_000_000 in
    Hashtbl.to_alist t.scheduled_cancels
    |> List.filter ~f:(fun (_, time) -> time <= now_ms)
    |> List.sort ~compare:[%compare: Address.t * int]
    |> List.iter ~f:(fun (account, _) ->
      Hashtbl.remove t.scheduled_cancels account;
      let day = now_ms / ms_per_day in
      Hashtbl.update t.scheduled_cancel_fires account ~f:(function
        | Some (d, n) when d = day -> d, n + 1
        | _ -> day, 1);
      List.iter (Adapt.open_orders t.exchange account) ~f:(fun o ->
        Hash_set.add t.scheduled_cancelled (account, o.oid);
        ignore
          (Exchange.cancel t.exchange account ~symbol:o.coin o.oid
           : Exchange_core.Cancel_status.t))))
;;

let step_clock t =
  let now = t.now () in
  if now > Exchange.now t.exchange then Exchange.step t.exchange ~now;
  fire_scheduled_cancels t;
  let now = Exchange.now t.exchange in
  Rankings.sample t.rankings t.exchange;
  List.iter t.on_clock_step ~f:(fun f -> f ~now)
;;

let on_clock_step t f = t.on_clock_step <- t.on_clock_step @ [ f ]
let add_status t ~name f = t.status <- t.status @ [ name, f ]

let status t : Yojson.Safe.t =
  `Assoc
    ([ "ws_connections", `Int (Hashtbl.length t.conns)
     ; "ws_dropped", `Int t.num_ws_dropped
     ; "ws_idle_closed", `Int t.num_ws_idle_closed
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
    ; num_ws_idle_closed = 0
    ; dirty_books = Coin.Hash_set.create ()
    ; l2_flush_scheduled = false
    ; last_l2_flush = Time_ns.epoch
    ; journal
    ; day_stats = Active_asset_ctx.Day_stats.create ()
    ; on_clock_step = []
    ; status = []
    ; agents = Agents.create ()
    ; builder_orders = Order_key.Table.create ()
    ; rankings = Rankings.create ()
    ; rejection_updates = []
    ; scheduled_cancels = Address.Table.create ()
    ; scheduled_cancel_fires = Address.Table.create ()
    ; scheduled_cancelled = Order_key.Hash_set.create ()
    ; order_history = Order_key.Table.create ()
    ; liquidation_orders = Order_key.Table.create ()
    ; liquidation_trades = Int.Table.create ()
    ; next_lid = 1
    ; trigger_history = Order_key.Table.create ()
    ; cloid_history = Address.Table.create ()
    ; charging_builder_fees = false
    }
  in
  Exchange.record_inputs exchange ~f:(function
    | Deposit { account; usd } when not t.charging_builder_fees ->
      Rankings.record_deposit t.rankings account usd
    | _ -> ());
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
  then conn.disconnect `Slow
  else (
    conn.last_sent <- Time_ns.now ();
    Pipe.write_without_pushback_if_open conn.send text)
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

let broadcast_json t sub json =
  let subscribers =
    Hashtbl.data t.conns |> List.filter ~f:(fun (c : Conn.t) -> Set.mem c.subs sub)
  in
  if not (List.is_empty subscribers)
  then (
    let text = Yojson.Safe.to_string json in
    List.iter subscribers ~f:(fun c -> send_text c text))
;;

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

(* Adds [liquidation] to the fills (JSON objects with a [tid]) of liquidation trades, as
   Hyperliquid's fills carry it. *)
let annotate_fill t (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields "tid" ~equal:String.equal with
     | Some (`Int tid) ->
       (match Hashtbl.find t.liquidation_trades tid with
        | Some l ->
          `Assoc (fields @ [ "liquidation", User_fill.Liquidation.yojson_of_t l ])
        | None -> json)
     | _ -> json)
  | json -> json
;;

(* [annotate_fill] on every element of a ["fills"] list, at any depth of a message. *)
let rec annotate_fills t (json : Yojson.Safe.t) =
  if Hashtbl.is_empty t.liquidation_trades
  then json
  else (
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map fields ~f:(fun (key, value) ->
           match key, value with
           | "fills", `List fills -> key, `List (List.map fills ~f:(annotate_fill t))
           | _, (`Assoc _ as value) -> key, annotate_fills t value
           | _ -> key, value))
    | json -> json)
;;

let fills_json t fills =
  `List (List.map fills ~f:(fun f -> annotate_fill t (User_fill.yojson_of_t f)))
;;

let send_to_event_users t user json =
  let subscribers =
    Hashtbl.data t.conns
    |> List.filter ~f:(fun (c : Conn.t) -> Set.mem c.event_users user)
  in
  if not (List.is_empty subscribers)
  then (
    let text = Yojson.Safe.to_string json in
    List.iter subscribers ~f:(fun c -> send_text c text))
;;

let broadcast_user_event t user fills =
  send_to_event_users t user (annotate_fills t (User_channels.user_fills_event fills))
;;

(* Records the liquidation orders the engine sent, and sends one [liquidation] user event
   per liquidated account. *)
let publish_liquidations t =
  let liquidations = Exchange.drain_liquidation_events t.exchange in
  List.iter liquidations ~f:(fun (l : Exchange_core_engine.Book_liquidation.Event.t) ->
    Log.Global.info
      !"liquidation %s %s %s %s mark=%s"
      (match l.method_ with
       | Market -> "market"
       | Backstop -> "backstop")
      (Address.to_string l.account)
      (Coin.to_string l.symbol)
      (Size.to_string l.order_size)
      (Price.to_string l.mark);
    Option.iter l.order_id ~f:(fun oid ->
      Hashtbl.set
        t.liquidation_orders
        ~key:(l.account, oid)
        ~data:
          { User_fill.Liquidation.liquidated_user = Some l.account
          ; mark_px = l.mark
          ; method_ = "market"
          }));
  List.dedup_and_sort
    liquidations
    ~compare:(fun (a : Exchange_core_engine.Book_liquidation.Event.t) b ->
      Address.compare a.account b.account)
  |> List.iter ~f:(fun (l : Exchange_core_engine.Book_liquidation.Event.t) ->
    let lid = t.next_lid in
    t.next_lid <- lid + 1;
    send_to_event_users
      t
      l.account
      (`Assoc
        [ "channel", `String User_event.channel
        ; ( "data"
          , User_event.yojson_of_t
              (Liquidation
                 { lid
                 ; liquidator = Adapt.liquidator
                 ; liquidated_user = l.account
                 ; liquidated_ntl_pos = Usd.to_string l.notional
                 ; liquidated_account_value = Usd.to_string l.equity
                 }) )
        ]))
;;

(* One [webData2] message per followed user, encoded once. *)
let broadcast_web_data t =
  let conns = Hashtbl.data t.conns in
  let users =
    List.fold conns ~init:Address.Set.empty ~f:(fun acc (c : Conn.t) ->
      Set.union acc c.web_data_users)
  in
  Set.iter users ~f:(fun user ->
    let text = Yojson.Safe.to_string (User_channels.web_data2 t.exchange user) in
    List.iter conns ~f:(fun (c : Conn.t) ->
      if Set.mem c.web_data_users user then send_text c text))
;;

let flush_l2 t =
  t.l2_flush_scheduled <- false;
  t.last_l2_flush <- Time_ns.now ();
  let coins = Hash_set.to_list t.dirty_books |> List.sort ~compare:Coin.compare in
  Hash_set.clear t.dirty_books;
  List.iter coins ~f:(fun coin ->
    Option.iter (Adapt.l2_book t.exchange coin) ~f:(fun book ->
      broadcast t (L2_book { coin }) (L2_book book)))
;;

let block_time = Time_ns.Span.of_int_ms 50

let schedule_l2_flush t =
  if (not t.l2_flush_scheduled) && not (Hash_set.is_empty t.dirty_books)
  then (
    t.l2_flush_scheduled <- true;
    (* Like Hyperliquid's blocks: the first change after a quiet spell goes out with the
       next block (modelled as 50ms, which also lets the request's ack go out first),
       later ones no sooner than [l2_book_interval] after the previous push. *)
    let next = Time_ns.add t.last_l2_flush t.config.l2_book_interval in
    let delay = Time_ns.Span.max block_time (Time_ns.diff next (Time_ns.now ())) in
    Clock_ns.run_after delay (fun () -> flush_l2 t) ())
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
  t.charging_builder_fees <- true;
  Exn.protect
    ~finally:(fun () -> t.charging_builder_fees <- false)
    ~f:(fun () ->
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
                  Exchange.deposit t.exchange builder.builder fee))));
      List.iter events ~f:(fun (event : Event.t) ->
        match event with
        | Order_filled { account; order; _ } | Order_cancelled { account; order; _ } ->
          Hashtbl.remove t.builder_orders (account, order.order_id)
        | _ -> ()))
;;

let remember_order t user (update : Order_update.t) =
  Hashtbl.set t.order_history ~key:(user, update.order.oid) ~data:update;
  Option.iter update.order.cloid ~f:(fun cloid ->
    Hashtbl.set
      (Hashtbl.find_or_add t.cloid_history user ~default:Cloid.Table.create)
      ~key:cloid
      ~data:update.order.oid)
;;

let publish t =
  publish_liquidations t;
  let numbered = Exchange.drain_numbered_events t.exchange in
  let events = List.map numbered ~f:(fun (e : Event.Numbered.t) -> e.event) in
  if not (Hashtbl.is_empty t.builder_orders) then charge_builder_fees t events;
  List.iter events ~f:log_event;
  let add_update updates (address, (update : Order_update.t)) =
    let key = address, update.order.oid in
    let update =
      if Hash_set.mem t.scheduled_cancelled key
      then (
        Hash_set.remove t.scheduled_cancelled key;
        { update with status = Other "scheduledCancel" })
      else update
    in
    Map.add_multi updates ~key:address ~data:update
  in
  (* Trigger order updates go before the engine events numbered from their [before_seq]. *)
  let pending_triggers = ref (Exchange.drain_trigger_events t.exchange) in
  let add_trigger_updates updates ~before =
    let due, rest =
      List.split_while !pending_triggers ~f:(fun (e : Trigger_event.t) ->
        e.before_seq <= before)
    in
    pending_triggers := rest;
    List.fold due ~init:updates ~f:(fun updates (e : Trigger_event.t) ->
      (match e.kind with
       | Placed ->
         Hashtbl.set
           t.trigger_history
           ~key:(e.order.account, e.order.order_id)
           ~data:e.order
       | Triggered | Cancelled _ -> ());
      add_update updates (Adapt.trigger_order_update e))
  in
  let trades, fills, updates =
    List.fold
      numbered
      ~init:(Coin.Map.empty, Address.Map.empty, Address.Map.empty)
      ~f:(fun (trades, fills, updates) { seq; event } ->
        Option.iter (Event.book_symbol event) ~f:(Hash_set.add t.dirty_books);
        let updates = add_trigger_updates updates ~before:seq in
        let updates =
          match Adapt.order_update event with
          | Some update -> add_update updates update
          | None -> updates
        in
        match event with
        | Fill { fill; taker; maker } ->
          Option.iter
            (Hashtbl.find t.liquidation_orders (fill.taker, fill.taker_oid))
            ~f:(fun l ->
              Hashtbl.set
                t.liquidation_trades
                ~key:(Exchange_core.Trade_id.to_int fill.tid)
                ~data:l);
          let notional = Notional.mul fill.px fill.sz in
          Rankings.record_volume t.rankings fill.taker notional;
          Rankings.record_volume t.rankings fill.maker notional;
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
  let updates = add_trigger_updates updates ~before:Int.max_value in
  Map.iteri trades ~f:(fun ~key:coin ~data ->
    broadcast t (Trades { coin }) (Trades (List.rev data)));
  Map.iteri fills ~f:(fun ~key:user ~data ->
    broadcast_json
      t
      (User_fills { user })
      (annotate_fills
         t
         (Ws_message.yojson_of_t
            (User_fills { is_snapshot = false; user; fills = List.rev data })));
    broadcast_user_event t user (List.rev data));
  let updates =
    List.fold_right t.rejection_updates ~init:updates ~f:(fun (address, update) acc ->
      Map.add_multi acc ~key:address ~data:update)
  in
  t.rejection_updates <- [];
  (* [data] is newest first; remember the latest update last. *)
  Map.iteri updates ~f:(fun ~key:user ~data ->
    List.iter (List.rev data) ~f:(remember_order t user));
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
      (* annotated below *)
      | Clearinghouse_state { user } ->
        Some (Clearinghouse_state (Adapt.clearinghouse_state ex user))
      | Meta -> Some (Meta (Adapt.meta ex))
    in
    match response with
    | Some (User_fills fills) -> fills_json t fills
    | Some r -> Info_response.yojson_of_t r
    | None -> `Null)
;;

(* The frontend view's order type and trigger fields of a trigger order. The order type
   names are the frontend's; the [triggerCondition] wording is not documented. *)
let trigger_fields (o : Exchange_core_engine.Trigger_order.t) =
  let market =
    match o.request.order_type with
    | Market _ -> true
    | Limit _ -> false
  in
  let order_type =
    match o.trigger.kind, market with
    | Stop_loss, true -> "Stop Market"
    | Stop_loss, false -> "Stop Limit"
    | Take_profit, true -> "Take Profit Market"
    | Take_profit, false -> "Take Profit Limit"
  in
  let px = Price.to_string o.trigger.trigger_px in
  [ "orderType", `String order_type
  ; "isTrigger", `Bool true
  ; "triggerPx", `String px
  ; ( "triggerCondition"
    , `String
        (if Exchange_core.Trigger.fires_above o.trigger ~side:o.request.side
         then "Price above " ^ px
         else "Price below " ^ px) )
  ; "children", `List []
  ; "isPositionTpsl", `Bool false
  ; "reduceOnly", `Bool o.request.reduce_only
  ; "tif", `Null
  ]
;;

(* [{"status": "order", "order": {"order": {...}, "status": "open", "statusTimestamp": ms}}]
   or [{"status": "unknownOid"}]; the order is the frontend view, with a limit order's
   fixed trigger fields or a trigger order's own. *)
let order_status t json =
  let user = Address.t_of_yojson (Json.member_exn json ~key:"user") in
  let oid =
    match Json.member_exn json ~key:"oid" with
    | `String cloid ->
      Hashtbl.find t.cloid_history user
      |> Option.bind ~f:(fun table -> Hashtbl.find table (Cloid.of_string cloid))
    | oid -> Some (Order_id.t_of_yojson oid)
  in
  match Option.bind oid ~f:(fun oid -> Hashtbl.find t.order_history (user, oid)) with
  | None -> `Assoc [ "status", `String "unknownOid" ]
  | Some update ->
    let extra =
      match Hashtbl.find t.trigger_history (user, update.order.oid) with
      | Some trigger_order -> trigger_fields trigger_order
      | None ->
        [ "orderType", `String "Limit"
        ; "isTrigger", `Bool false
        ; "triggerPx", `String "0.0"
        ; "triggerCondition", `String "N/A"
        ; "children", `List []
        ; "isPositionTpsl", `Bool false
        ; "reduceOnly", `Bool false
        ; "tif", `Null
        ]
    in
    let order =
      match Open_order.yojson_of_t update.order with
      | `Assoc fields -> `Assoc (fields @ extra)
      | json -> json
    in
    `Assoc
      [ "status", `String "order"
      ; ( "order"
        , `Assoc
            [ "order", order
            ; "status", `String (Order_update.Status.to_wire update.status)
            ; "statusTimestamp", `Int update.status_timestamp
            ] )
      ]
;;

let leaderboard t = Rankings.to_json (Rankings.rows t.rankings t.exchange)

(* [[meta, [ctx, ...]]] with one context per coin in universe order ([null] for a coin
   with no price yet). *)
let meta_and_asset_ctxs t =
  let meta = Adapt.meta t.exchange in
  `List
    [ Meta.yojson_of_t meta
    ; `List
        (List.map meta.universe ~f:(fun (m : Meta.Asset_meta.t) ->
           Active_asset_ctx.of_exchange t.exchange t.day_stats m.name
           |> Option.value_map ~default:`Null ~f:Active_asset_ctx.ctx_json))
    ]
;;

(* An approved agent is an [agent] of its account, any address the server has credited is
   a [user], anything else is [missing]. Vaults and sub-accounts are not modelled. *)
let user_role t address =
  let role : User_role.Role.t =
    match Agents.owner ~now_ms:(Exchange.now t.exchange / 1_000_000) t.agents address with
    | Some user -> Agent { user }
    | None -> if Hash_set.mem t.seen address then User else Missing
  in
  User_role.yojson_of_response role
;;

(* Info requests hl-protocol's [Info_request] does not model; [None] for the others. *)
let handle_extra_info t json =
  let user () = Address.t_of_yojson (Json.member_exn json ~key:"user") in
  match Json.member json ~key:"type" with
  | Some (`String "maxBuilderFee") ->
    let builder = Address.t_of_yojson (Json.member_exn json ~key:"builder") in
    Some (`Int (Agents.max_builder_fee t.agents ~user:(user ()) ~builder))
  | Some (`String "extraAgents") ->
    Some (`List (List.map (Agents.agents t.agents (user ())) ~f:Agents.Agent.to_json))
  | Some (`String "leaderboard") -> Some (leaderboard t)
  | Some (`String "metaAndAssetCtxs") -> Some (meta_and_asset_ctxs t)
  | Some (`String "userRole") -> Some (user_role t (User_role.t_of_yojson json).user)
  | Some (`String "orderStatus") -> Some (order_status t json)
  | Some (`String "userFillsByTime") ->
    let req = User_fills_by_time.t_of_yojson json in
    ensure_account t req.user;
    let end_time = Option.value req.end_time ~default:Int.max_value in
    (* Oldest first, so that the last fill's time is the next page's [startTime]. *)
    let fills =
      Adapt.user_fills t.exchange req.user
      |> List.rev
      |> List.filter ~f:(fun (f : User_fill.t) ->
        f.time >= req.start_time && f.time <= end_time)
      |> Fn.flip List.take User_fills_by_time.max_fills_per_response
    in
    Some (fills_json t fills)
  | _ -> None
;;

let handle_info_json t json =
  match handle_extra_info t json with
  | Some response -> response
  | None -> handle_info t (Info_request.t_of_yojson json)
;;

(* Hyperliquid checks the builder code before placing any order of the action. *)
let check_builder t ex address (builder : Builder.t) =
  if builder.fee_tenths_bp < 0 || builder.fee_tenths_bp > Builder.max_perp_fee
  then (* sim wording *) Error "Builder fee is above the 0.1% perps limit."
  else if Agents.max_builder_fee t.agents ~user:address ~builder:builder.builder
          < builder.fee_tenths_bp
  then Error "Builder fee has not been approved."
  else if Usd.( < )
            (Exchange.account_view ex builder.builder).equity
            Builder.min_builder_account_value
  then (* sim wording *) Error "Builder has insufficient balance to be builder."
  else Ok ()
;;

let place t ex address order =
  let status, update = Adapt.place_order_with_update ex address order in
  Option.iter update ~f:(fun u ->
    t.rejection_updates <- (address, u) :: t.rejection_updates);
  status
;;

let place_with_builder t ex address builder orders =
  match check_builder t ex address builder with
  | Error msg -> Exchange_response.Err msg
  | Ok () ->
    Exchange_response.Ok
      (Order
         (List.map orders ~f:(fun order ->
            let status = place t ex address order in
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
         ensure_account t builder.builder;
         place_with_builder t ex address builder orders
       | None -> Exchange_response.Ok (Order (List.map orders ~f:(place t ex address))))
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
      | Approve_agent { agent_address; agent_name; _ } ->
        Agents.approve_agent t.agents ~user:address ~agent:agent_address ~name:agent_name
      | Approve_builder_fee { builder; max_fee_rate; _ } ->
        (* Funding the builder here, inside the journaled request, keeps replays exact. *)
        ensure_account t builder;
        (match Builder.tenths_bps_of_rate max_fee_rate with
         | Error _ -> Error (sprintf "Invalid max fee rate %s." max_fee_rate)
         | Ok tenths_bps ->
           Agents.approve_builder_fee t.agents ~user:address ~builder ~tenths_bps)
    in
    match result with
    | Ok () -> Exchange_response.Ok Default
    | Error msg -> Exchange_response.Err msg)
;;

let schedule_cancel t address time =
  let now_ms = Exchange.now t.exchange / 1_000_000 in
  let fired_today =
    match Hashtbl.find t.scheduled_cancel_fires address with
    | Some (day, n) when day = now_ms / ms_per_day -> n
    | _ -> 0
  in
  match time with
  | None ->
    Hashtbl.remove t.scheduled_cancels address;
    (Ok Default : Exchange_response.t)
  | Some time when time < now_ms + 5_000 ->
    (* sim wording *)
    Err "Scheduled cancel time too early, must be at least 5 seconds from now."
  | Some _ when fired_today >= 10 ->
    (* sim wording; the limit of 10 triggers per UTC day is documented *)
    Err "Too many scheduled cancels triggered today."
  | Some time ->
    Hashtbl.set t.scheduled_cancels ~key:address ~data:time;
    Ok Default
;;

let handle_extra_action t address (action : Extra_action.t) : Exchange_response.t =
  ensure_account t address;
  mutate t ~f:(fun ex ->
    Option.iter t.journal ~f:(fun journal ->
      Journal.write_record
        journal
        (Extra { time = Exchange.now ex; address; extra_action = action }));
    match (action : Extra_action.t) with
    | Update_leverage { asset; is_cross; leverage } ->
      (match Meta.coin_of_asset (Adapt.meta ex) asset with
       | None ->
         Exchange_response.Err (sprintf "Asset %d does not exist." (Asset.to_int asset))
       | Some _ when not is_cross ->
         (* sim wording: the engine is cross margin only *)
         Err "Isolated margin is not supported."
       | Some coin ->
         (match Exchange.set_leverage ex address coin leverage with
          | Ok () -> Ok Default
          | Error _ -> (* sim wording *) Err "Invalid leverage value."))
    | Schedule_cancel { time } -> schedule_cancel t address time
    | Batch_modify { modifies } ->
      Ok (Order (List.map modifies ~f:(Adapt.modify ex address))))
;;

let replay ?config exchange records =
  let time_of : Journal.Record.t -> int = function
    | Request e -> e.time
    | User_action e -> e.time
    | Extra e -> e.time
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
        handle_user_action ?signature t address user_action
      | Extra { address; extra_action; time = _ } ->
        handle_extra_action t address extra_action)
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
    send_json
      conn
      (annotate_fills
         t
         (Ws_message.yojson_of_t
            (User_fills
               { is_snapshot = true; user; fills = Adapt.user_fills t.exchange user })))
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
  | None ->
    (match User_channels.Request.of_json json with
     | Some req -> `User_channel req
     | None -> `Request (Ws_request.t_of_yojson json))
;;

(* Every user a connection follows, through any user-specific subscription. *)
let followed_users (conn : Conn.t) =
  Set.fold
    conn.subs
    ~init:(Set.union conn.web_data_users conn.event_users)
    ~f:(fun acc -> function
    | User_fills { user } | Order_updates { user } -> Set.add acc user
    | L2_book _ | Trades _ | All_mids -> acc)
;;

(* Hyperliquid allows 10 distinct users across a client's user subscriptions. The limit is
   documented; the message text is the simulator's. *)
let check_user_limit t (conn : Conn.t) user =
  let users = followed_users conn in
  if Set.mem users user || Set.length users < t.config.max_ws_users
  then Ok ()
  else Error (sprintf "Cannot track more than %d total users." t.config.max_ws_users)
;;

let subscription_user : Subscription.t -> Address.t option = function
  | User_fills { user } | Order_updates { user } -> Some user
  | L2_book _ | Trades _ | All_mids -> None
;;

let handle_user_channel_request t (conn : Conn.t) (req : User_channels.Request.t) =
  Log.Global.debug_s
    [%message "ws user channel" ~conn:(conn.id : int) (req : User_channels.Request.t)];
  let update f =
    match req.kind with
    | Web_data2 -> conn.web_data_users <- f conn.web_data_users
    | User_events -> conn.event_users <- f conn.event_users
  in
  if not req.subscribe
  then (
    update (fun s -> Set.remove s req.user);
    send_json conn (User_channels.Request.response req))
  else (
    match check_user_limit t conn req.user with
    | Error msg -> send conn (Error msg)
    | Ok () ->
      ensure_account t req.user;
      update (fun s -> Set.add s req.user);
      send_json conn (User_channels.Request.response req);
      (match req.kind with
       | Web_data2 -> send_json conn (User_channels.web_data2 t.exchange req.user)
       | User_events -> ()))
;;

let handle_ws_message t (conn : Conn.t) text =
  match decode_ws_request text with
  | `Ctx req -> handle_ctx_request t conn req
  | `User_channel req -> handle_user_channel_request t conn req
  | exception _ ->
    Log.Global.debug "ws %d: invalid message %s" conn.id text;
    send conn (Error (sprintf "Invalid message: %s" text))
  | `Request Ping -> send conn Pong
  | `Request (Subscribe sub as req) ->
    Log.Global.debug_s
      [%message "ws subscribe" ~conn:(conn.id : int) (sub : Subscription.t)];
    (match
       Option.value_map (subscription_user sub) ~default:(Ok ()) ~f:(fun user ->
         check_user_limit t conn user)
     with
     | Error msg -> send conn (Error msg)
     | Ok () ->
       conn.subs <- Set.add conn.subs sub;
       send conn (Subscription_response req);
       ws_snapshot t conn sub)
  | `Request (Unsubscribe sub as req) ->
    conn.subs <- Set.remove conn.subs sub;
    send conn (Subscription_response req)
;;

let handle_ws t reader writer =
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  let incoming, outgoing = Websocket.pipes ws in
  let id = t.next_conn_id in
  t.next_conn_id <- id + 1;
  let disconnect reason =
    if Hashtbl.mem t.conns id
    then (
      Hashtbl.remove t.conns id;
      (match reason with
       | `Slow ->
         t.num_ws_dropped <- t.num_ws_dropped + 1;
         Log.Global.info
           "ws %d: disconnected slow consumer (%d messages queued)"
           id
           (Pipe.length outgoing)
       | `Idle ->
         t.num_ws_idle_closed <- t.num_ws_idle_closed + 1;
         Log.Global.info
           "ws %d: closed after %s with nothing sent"
           id
           (Time_ns.Span.to_string_hum t.config.ws_idle_timeout));
      Pipe.close outgoing;
      (* The close frame would wait behind the unread data; drop the socket now. *)
      don't_wait_for (Writer.close ~force_close:Deferred.unit writer))
  in
  let conn =
    { Conn.id
    ; send = outgoing
    ; max_queue = t.config.max_ws_queue
    ; disconnect
    ; last_sent = Time_ns.now ()
    ; subs = Subscription.Set.empty
    ; ctx_coins = Coin.Set.empty
    ; web_data_users = Address.Set.empty
    ; event_users = Address.Set.empty
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
let l1_signers t (env : Exchange_envelope.t) signature =
  match Hl_client.Signing.Signature.t_of_yojson signature with
  | exception _ -> []
  | signature ->
    let connection_id =
      Hl_client.Signing.action_hash
        ?expires_after:env.expires_after
        ~vault_address:env.vault_address
        ~nonce:env.nonce
        env.action
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

let resolve_l1 t ~x_address (env : Exchange_envelope.t) =
  let open Result.Let_syntax in
  let fallback () = Ok (unsigned_address t ~x_address ~vault_address:env.vault_address) in
  match env.signature with
  | None | Some `Null ->
    if t.config.strict_signatures then Error "Missing signature." else fallback ()
  | Some signature ->
    let signers = l1_signers t env signature in
    (match
       List.find_map signers ~f:(fun signer ->
         Option.map
           (Agents.owner ~now_ms:(now_ms t) t.agents signer)
           ~f:(fun owner -> signer, owner))
     with
     | Some (agent, owner) ->
       let%map () = use_nonce t ~signer:agent ~nonce:env.nonce in
       owner
     | None when not t.config.strict_signatures -> fallback ()
     | None ->
       (match signers with
        | [] -> Error "Invalid signature."
        | signer :: _ ->
          let%map () = use_nonce t ~signer ~nonce:env.nonce in
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

(* With ["a": false], a modify must not take liquidity: a GTC replacement becomes ALO
   (rejected if it would cross) and an IOC one is refused. *)
let modify_without_always_place action (req : Exchange_request.t) =
  match req.action, Json.member action ~key:"a" with
  | Modify ({ order; _ } as modify), Some (`Bool false) ->
    (match order.order_type with
     | Limit { tif = Gtc } ->
       Ok
         { req with
           action =
             Modify
               { modify with order = { order with order_type = Limit { tif = Alo } } }
         }
     | Limit { tif = Alo } -> Ok req
     | Limit { tif = Ioc } | Trigger _ ->
       (* sim wording *)
       Error "Modify without always-place needs an ALO or GTC replacement.")
  | _ -> Ok req
;;

let handle_l1_json t ~x_address json (env : Exchange_envelope.t) action
  : Exchange_response.t
  =
  match Extra_action.of_action_json action with
  | Some extra ->
    (match resolve_l1 t ~x_address env with
     | Error msg -> Err msg
     | Ok address -> handle_extra_action t address extra)
  | None ->
    let req = Exchange_request.t_of_yojson json in
    (match modify_without_always_place action req with
     | Error msg -> Err msg
     | Ok req ->
       let builder =
         match req.action with
         | Order _ -> Builder.of_action_json action
         | Cancel _ | Cancel_by_cloid _ | Modify _ -> None
       in
       (match resolve_l1 t ~x_address env with
        | Error msg -> Err msg
        | Ok address -> handle_exchange ?builder t address req))
;;

let handle_envelope t ~x_address json action : Exchange_response.t =
  let env = Exchange_envelope.t_of_yojson json in
  match env.expires_after with
  | Some expires_after when expires_after < now_ms t ->
    (* sim wording; Hyperliquid also charges a rate-limit penalty *)
    Err (sprintf "Action expired: expiresAfter %d is in the past." expires_after)
  | Some _ | None -> handle_l1_json t ~x_address json env action
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
  | None -> handle_envelope t ~x_address json action
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
  | `POST, "/info" -> with_body body ~decode:Fn.id ~f:(handle_info_json t)
  (* The stats host's path, for clients pointed at the simulator as their stats URL. *)
  | `GET, ("/leaderboard" | "/Mainnet/leaderboard" | "/Testnet/leaderboard") ->
    respond_json (leaderboard t)
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

(* Hyperliquid closes a connection it has sent nothing to for 60 seconds; clients keep
   quiet connections open with pings, which the pong answers count as sends. *)
let close_idle_connections t =
  let now = Time_ns.now () in
  Hashtbl.data t.conns
  |> List.iter ~f:(fun (c : Conn.t) ->
    if Time_ns.Span.(Time_ns.diff now c.last_sent >= t.config.ws_idle_timeout)
    then c.disconnect `Idle)
;;

let start_periodic t =
  Clock_ns.every
    (Time_ns.Span.min
       Time_ns.Span.second
       (Time_ns.Span.scale t.config.ws_idle_timeout 0.25))
    (fun () -> close_idle_connections t);
  Clock_ns.every t.config.all_mids_interval (fun () ->
    broadcast t All_mids (All_mids (Adapt.all_mids t.exchange));
    broadcast_ctx t;
    broadcast_web_data t);
  Clock_ns.every t.config.step_interval (fun () -> mutate t ~f:ignore)
;;

(* Simulated accounts are funded by their creator; the first request naming them must not
   credit them the initial balance again. *)
let adopt t address ~display_name =
  Hash_set.add t.seen address;
  Rankings.set_display_name t.rankings address display_name
;;

let run_leaders t leaders =
  List.iter (Leaders.leaders leaders) ~f:(fun (l : Leaders.Leader.t) ->
    adopt t l.address ~display_name:(Leaders.Leader.display_name l));
  Clock_ns.every (Leaders.config leaders).decision_interval (fun () ->
    mutate t ~f:(fun _ -> Leaders.tick leaders))
;;

let run_market_sim ?foresight t sim =
  List.iteri (Market_sim.traders sim) ~f:(fun i address ->
    adopt t address ~display_name:(sprintf "noise-%d" i));
  Clock_ns.every (Market_sim.config sim).tick_interval (fun () ->
    mutate t ~f:(fun _ ->
      Option.iter foresight ~f:Foresight.tick;
      Market_sim.tick sim))
;;
