open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Execution = Exchange_core_engine.Execution
module Trigger_event = Exchange_core_engine.Trigger_event
module Trigger_order = Exchange_core_engine.Trigger_order
module Direction = Exchange_core_engine.Position.Direction
module Neutral = Exchange_core

let ms ns = ns / 1_000_000

(* Universe *)

let default_meta : Meta.t =
  let asset name sz_decimals max_leverage : Meta.Asset_meta.t =
    { name = Coin.of_string name; sz_decimals; max_leverage; only_isolated = false }
  in
  { universe = [ asset "BTC" 5 40; asset "ETH" 4 25; asset "SOL" 2 20 ] }
;;

let base_fees = { Neutral.Fee_schedule.taker_bps = 4.5; maker_bps = 1.5 }

let mainnet_margin_tiers =
  let tier lower_bound max_leverage =
    { Neutral.Margin_tier.lower_bound = Usd.of_int lower_bound; max_leverage }
  in
  [ Coin.of_string "BTC", [ tier 0 40; tier 150_000_000 20 ]
  ; Coin.of_string "ETH", [ tier 0 25; tier 100_000_000 15 ]
  ; Coin.of_string "SOL", [ tier 0 20; tier 70_000_000 10 ]
  ]
;;

let margin_tiers (m : Meta.Asset_meta.t) =
  match List.Assoc.find mainnet_margin_tiers m.name ~equal:Coin.equal with
  | Some (first :: _ as tiers) when first.max_leverage = m.max_leverage -> tiers
  | Some _ | None -> []
;;

let instrument ?(fees = base_fees) (m : Meta.Asset_meta.t) =
  let tick_decimals = Int.clamp_exn (6 - m.sz_decimals) ~min:0 ~max:Price.decimals in
  Neutral.Instrument.create
    ~margin_tiers:(margin_tiers m)
    m.name
    ~size_decimals:m.sz_decimals
    ~price_tick:(Price.of_units (Price.units_per_one / Int.pow 10 tick_decimals))
    ~max_significant_figures:5
    ~max_leverage:m.max_leverage
    ~fees
;;

let config ?(meta = default_meta) ?fees () =
  { Exchange.Config.default with
    instruments = List.map meta.universe ~f:(instrument ?fees)
  }
;;

let self_trade : Order_book.Stp.t = Expire_maker
let liquidator = Address.of_string "0x000000000000000000000000000000000000ffff"
let book_liquidation = Exchange_core_engine.Book_liquidation.Config.create ~liquidator

let create_exchange ?meta ?fees () =
  Exchange.create ~config:(config ?meta ?fees ()) ~self_trade ~book_liquidation ()
;;

let meta ex : Meta.t =
  { universe =
      List.map (Exchange.instruments ex) ~f:(fun (i : Neutral.Instrument.t) ->
        { Meta.Asset_meta.name = i.symbol
        ; sz_decimals = i.size_decimals
        ; max_leverage = i.max_leverage
        ; only_isolated = false
        })
  }
;;

(* The margin table ids are the simulator's: a single tier is the table numbered by its
   leverage, as on Hyperliquid (ids below 50), tiered tables count from 51 in universe
   order (Hyperliquid's own ids for them are not documented). *)
let meta_json ex =
  let instruments = Exchange.instruments ex in
  let table_ids =
    List.mapi instruments ~f:(fun i (instrument : Neutral.Instrument.t) ->
      match instrument.margin_tiers with
      | [] -> instrument.max_leverage
      | _ -> 51 + i)
  in
  let universe =
    List.map2_exn (meta ex).universe table_ids ~f:(fun asset id ->
      match Meta.Asset_meta.yojson_of_t asset with
      | `Assoc fields -> `Assoc (fields @ [ "marginTableId", `Int id ])
      | json -> json)
  in
  let tables =
    List.map2_exn instruments table_ids ~f:(fun instrument id ->
      ( id
      , `List
          [ `Int id
          ; `Assoc
              [ "description", `String ""
              ; ( "marginTiers"
                , `List
                    (List.map
                       (Neutral.Instrument.margin_tiers instrument)
                       ~f:(fun (tier : Neutral.Margin_tier.t) ->
                         `Assoc
                           [ "lowerBound", `String (Usd.to_string tier.lower_bound)
                           ; "maxLeverage", `Int tier.max_leverage
                           ])) )
              ]
          ] ))
    |> List.dedup_and_sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
    |> List.map ~f:snd
  in
  `Assoc [ "universe", `List universe; "marginTables", `List tables ]
;;

(* Conversions *)

let reject_message meta ?coin (reason : Neutral.Reject_reason.t) =
  let suffix =
    Option.bind coin ~f:(Meta.asset_of_coin meta)
    |> Option.value_map ~default:"" ~f:(fun a -> sprintf " asset=%d" (Asset.to_int a))
  in
  match reason with
  | Unknown_symbol ->
    sprintf "Unknown coin %s." (Option.value_map coin ~default:"?" ~f:Coin.to_string)
  | Unsupported msg -> msg
  | Invalid_size -> "Order has invalid size." ^ suffix
  (* Hyperliquid's documented text for its [Tick] error; the engine's [Invalid_price] also
     covers the significant-figure limit, for which no separate text is documented. *)
  | Invalid_price -> "Price must be divisible by tick size." ^ suffix
  | Duplicate_client_order_id -> "Duplicate cloid." ^ suffix
  | Reduce_only_would_increase -> "Reduce only order would increase position." ^ suffix
  | Below_min_value { min } ->
    sprintf "Order must have minimum value of $%s.%s" (Usd.to_string min) suffix
  | Insufficient_margin -> "Insufficient margin to place order." ^ suffix
  | No_liquidity ->
    "Order could not immediately match against any resting orders." ^ suffix
  (* Not produced under [Expire_maker], where a taker is never rejected for self-trade;
     kept for front ends that record it with [Exchange.reject]. *)
  | Self_trade -> "Order was canceled by self-trade prevention." ^ suffix
  | Post_only_would_cross { best_bid; best_ask } ->
    let show = Option.value_map ~default:"none" ~f:Price.to_string in
    sprintf
      "Post only order would have immediately matched, bbo was %s@%s.%s"
      (show best_bid)
      (show best_ask)
      suffix
  | Order_not_found -> "Cannot modify canceled or filled order"
;;

let order_status meta ~coin (status : Neutral.Order_status.t) : Order_status.t =
  match status with
  | Resting { order_id; client_order_id } ->
    Resting { oid = order_id; cloid = client_order_id }
  | Filled { order_id; total; avg_px; client_order_id } ->
    Filled { oid = order_id; total_sz = total; avg_px; cloid = client_order_id }
  | Rejected reason -> Error (reject_message meta ?coin reason)
;;

let dir : Direction.t -> string = function
  | Open_long -> "Open Long"
  | Open_short -> "Open Short"
  | Close_long -> "Close Long"
  | Close_short -> "Close Short"
  | Long_to_short -> "Long > Short"
  | Short_to_long -> "Short > Long"
;;

let open_order (o : Neutral.Open_order.t) : Open_order.t =
  { coin = o.symbol
  ; side = o.side
  ; limit_px = o.px
  ; sz = o.size
  ; oid = o.order_id
  ; timestamp = ms o.timestamp
  ; orig_sz = o.orig_size
  ; cloid = o.client_order_id
  }
;;

let hash (fill : Order_book.Fill.t) = sprintf "0x%064x" (Neutral.Trade_id.to_int fill.tid)

let user_fill (e : Execution.t) : User_fill.t =
  let s = e.settlement in
  { coin = e.fill.symbol
  ; px = e.fill.px
  ; sz = e.fill.sz
  ; side = s.side
  ; time = ms e.fill.time
  ; start_position = s.change.start_position
  ; dir = dir s.change.direction
  ; closed_pnl = s.change.closed_pnl
  ; hash = hash e.fill
  ; oid = Execution.order_id e
  ; crossed = s.crossed
  ; fee = s.fee
  ; tid = Neutral.Trade_id.to_int e.fill.tid
  ; fee_token = Some "USDC"
  ; cloid = Execution.client_order_id e
  }
;;

let trade (fill : Order_book.Fill.t) : Trade.t =
  let users =
    match fill.taker_side with
    | Buy -> fill.taker, fill.maker
    | Sell -> fill.maker, fill.taker
  in
  { coin = fill.symbol
  ; side = fill.taker_side
  ; px = fill.px
  ; sz = fill.sz
  ; hash = hash fill
  ; time = ms fill.time
  ; tid = Neutral.Trade_id.to_int fill.tid
  ; users
  }
;;

let l2 (book : Neutral.L2.t) : L2_book.t =
  let level (l : Neutral.L2.Level.t) : L2_book.Level.t =
    { px = l.px; sz = l.sz; n = l.n }
  in
  { coin = book.symbol
  ; time = ms book.time
  ; bids = List.map book.bids ~f:level
  ; asks = List.map book.asks ~f:level
  }
;;

let clearinghouse_state_of_view (v : Neutral.Account_view.t) : Clearinghouse_state.t =
  let positions =
    List.map
      v.positions
      ~f:(fun (p : Neutral.Position_view.t) : Clearinghouse_state.Position.t ->
        { coin = p.symbol
        ; szi = p.size
        ; entry_px = Some p.entry_px
        ; position_value = p.notional
        ; unrealized_pnl = p.unrealized_pnl
        ; liquidation_px = p.liquidation_px
        ; leverage = Cross { value = p.leverage }
        ; margin_used = p.margin_used
        ; max_leverage = p.max_leverage
        })
  in
  let summary : Clearinghouse_state.Margin_summary.t =
    { account_value = v.equity
    ; total_ntl_pos = v.total_notional
    ; total_raw_usd = v.balance
    ; total_margin_used = v.margin_used
    }
  in
  { positions
  ; margin_summary = summary
  ; cross_margin_summary = summary
  ; cross_maintenance_margin_used = v.maintenance_margin
  ; withdrawable = v.available
  ; time = ms v.time
  }
;;

let cancelled_status : Event.Cancel_reason.t -> Order_update.Status.t = function
  | User | Modified | Ioc_unfilled -> Canceled
  | Self_trade -> Other "selfTradeCanceled"
  | Liquidated -> Other "liquidatedCanceled"
;;

let order_update (event : Event.t) =
  let update account order status time =
    Some
      ( account
      , { Order_update.order = open_order order; status; status_timestamp = ms time } )
  in
  match event with
  | Order_accepted { account; order; time } -> update account order Open time
  | Order_filled { account; order; time } -> update account order Filled time
  | Order_cancelled { account; order; reason; time } ->
    update account order (cancelled_status reason) time
  | Order_rejected _ | Fill _ | Liquidation _ | Funding _ -> None
;;

let trigger_order_update (event : Trigger_event.t) =
  let status : Order_update.Status.t =
    match event.kind with
    | Placed -> Open
    | Triggered -> Triggered
    | Cancelled reason -> cancelled_status reason
  in
  ( event.order.account
  , { Order_update.order = open_order (Trigger_order.open_order event.order)
    ; status
    ; status_timestamp = ms event.time
    } )
;;

(* Exchange endpoint *)

let never_placed asset : Cancel_status.t =
  Error
    (sprintf
       "Order was never placed, already canceled, or filled. asset=%d"
       (Asset.to_int asset))
;;

(* Hyperliquid's market TP/SL orders have a 10% slippage tolerance (TP/SL docs). The
   engine measures it from the best opposite price when the order fires. *)
let trigger_market_slippage_bps = 1000

(* The engine request for a Hyperliquid order (with its trigger, for a trigger order), or
   the rejection to record. *)
let neutral_request ex (req : Order_request.t)
  : ( Neutral.Order_request.t * Neutral.Trigger.t option
      , Coin.t option * Neutral.Reject_reason.t * string )
      Result.t
  =
  match Meta.coin_of_asset (meta ex) req.asset with
  | None ->
    Error
      (None, Unknown_symbol, sprintf "Asset %d does not exist." (Asset.to_int req.asset))
  | Some coin ->
    let request (order_type : Neutral.Order_type.t) : Neutral.Order_request.t =
      { symbol = coin
      ; side = Order_request.side req
      ; size = req.sz
      ; px = Some req.limit_px
      ; order_type
      ; reduce_only = req.reduce_only
      ; client_order_id = req.cloid
      }
    in
    (match req.order_type with
     | Limit { tif } -> Ok (request (Limit tif), None)
     | Trigger { is_market; trigger_px; tpsl } ->
       let order_type : Neutral.Order_type.t =
         if is_market
         then Market { slippage_bps = Some trigger_market_slippage_bps }
         else Limit Gtc
       in
       let kind : Neutral.Trigger.Kind.t =
         match tpsl with
         | Tp -> Take_profit
         | Sl -> Stop_loss
       in
       Ok (request order_type, Some { Neutral.Trigger.trigger_px; kind }))
;;

let reject_request ex address (req : Order_request.t) (coin, reason, msg) : Order_status.t
  =
  ignore
    (Exchange.reject ?symbol:coin ?client_order_id:req.cloid ex address reason
     : Neutral.Order_status.t);
  Error msg
;;

let reject_status : Neutral.Reject_reason.t -> Order_update.Status.t = function
  | Invalid_price -> Other "tickRejected"
  | Below_min_value _ -> Other "minTradeNtlRejected"
  | Insufficient_margin -> Other "perpMarginRejected"
  | Reduce_only_would_increase -> Other "reduceOnlyRejected"
  | Post_only_would_cross _ -> Other "badAloPxRejected"
  | No_liquidity -> Other "iocCancelRejected"
  | Self_trade -> Other "selfTradeCanceled"
  | Unknown_symbol
  | Unsupported _
  | Invalid_size
  | Duplicate_client_order_id
  | Order_not_found -> Rejected
;;

let place_order_with_update ex address (req : Order_request.t) =
  match neutral_request ex req with
  | Error rejection -> reject_request ex address req rejection, None
  | Ok (neutral, trigger) ->
    let oid, status =
      match trigger with
      | None -> Exchange.place_with_order_id ex address neutral
      | Some trigger -> Exchange.place_trigger ex address neutral trigger
    in
    let update =
      match status with
      | Rejected reason ->
        let time = ms (Exchange.now ex) in
        Some
          { Order_update.order =
              { coin = neutral.symbol
              ; side = neutral.side
              ; limit_px = req.limit_px
              ; sz = req.sz
              ; oid
              ; timestamp = time
              ; orig_sz = Some req.sz
              ; cloid = req.cloid
              }
          ; status = reject_status reason
          ; status_timestamp = time
          }
      | Resting _ | Filled _ -> None
    in
    order_status (meta ex) ~coin:(Some neutral.symbol) status, update
;;

let place_order ex address req = fst (place_order_with_update ex address req)

let market_order ?slippage_bps ?reduce_only ?cloid ex address ~coin ~side ~sz =
  Exchange.place
    ex
    address
    (Neutral.Order_request.market
       ?slippage_bps
       ?reduce_only
       ?client_order_id:cloid
       coin
       side
       ~size:sz)
  |> order_status (meta ex) ~coin:(Some coin)
;;

let cancel_status asset : Neutral.Cancel_status.t -> Cancel_status.t = function
  | Cancelled -> Success
  | Not_found -> never_placed asset
;;

let cancel ex address (req : Cancel_request.t) =
  match Meta.coin_of_asset (meta ex) req.asset with
  | None -> never_placed req.asset
  | Some symbol -> Exchange.cancel ex address ~symbol req.oid |> cancel_status req.asset
;;

let cancel_by_cloid ex address (req : Cancel_by_cloid.t) =
  match Meta.coin_of_asset (meta ex) req.asset with
  | None -> never_placed req.asset
  | Some symbol ->
    Exchange.cancel_by_client_order_id ex address ~symbol req.cloid
    |> cancel_status req.asset
;;

let modify ex address (req : Modify_request.t) =
  match neutral_request ex req.order with
  | Error rejection -> reject_request ex address req.order rejection
  | Ok (neutral, trigger) ->
    let target : Exchange.Target.t =
      match req.oid with
      | Oid oid -> Order_id oid
      | Cloid cloid -> Client_order_id cloid
    in
    Exchange.modify ?trigger ex address target neutral
    |> order_status (meta ex) ~coin:(Some neutral.symbol)
;;

(* Info endpoint *)

let l2_book ?n_levels ex coin = Exchange.l2 ?n_levels ex coin |> Option.map ~f:l2
let all_mids ex = Exchange.mids ex

let open_orders ex address =
  Exchange.open_orders ex address
  @ List.map (Exchange.trigger_orders ex address) ~f:Trigger_order.open_order
  |> List.sort ~compare:(fun (a : Neutral.Open_order.t) b ->
    Neutral.Order_id.compare b.order_id a.order_id)
  |> List.map ~f:open_order
;;

let user_fills ex address = List.map (Exchange.fills ex address) ~f:user_fill

let clearinghouse_state ex address =
  clearinghouse_state_of_view (Exchange.account_view ex address)
;;
