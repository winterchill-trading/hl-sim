open! Core
open! Hl_protocol

module Config = struct
  type t =
    { meta : Meta.t
    ; fees : Fee_schedule.t
    ; default_leverage : int
    ; funding_interval_ns : int
    ; default_funding_rate : float
    ; min_order_value : Usd.t
    ; market_slippage_bps : int
    ; l2_levels : int
    }
  [@@deriving sexp_of]

  let default_meta : Meta.t =
    let asset name sz_decimals max_leverage : Meta.Asset_meta.t =
      { name = Coin.of_string name; sz_decimals; max_leverage; only_isolated = false }
    in
    { universe = [ asset "BTC" 5 40; asset "ETH" 4 25; asset "SOL" 2 20 ] }
  ;;

  let default =
    { meta = default_meta
    ; fees = Fee_schedule.default
    ; default_leverage = 20
    ; funding_interval_ns = Time_ns.Span.to_int_ns Time_ns.Span.hour
    ; default_funding_rate = 0.0000125
    ; min_order_value = Usd.of_int 10
    ; market_slippage_bps = 500
    ; l2_levels = 20
    }
  ;;
end

type t =
  { config : Config.t
  ; clearinghouse : Clearinghouse.t
  ; books : Order_book.t Coin.Table.t
  ; marks : Price.t Coin.Table.t (** explicit marks from [set_mark] *)
  ; last_trade : Price.t Coin.Table.t
  ; funding_rates : float Coin.Table.t
  ; owner_orders : Coin.t Order_id.Table.t Address.Table.t (** owner -> oid -> coin *)
  ; cloids : Order_id.t Cloid.Table.t Address.Table.t
  ; fills : User_fill.t list Address.Table.t (** newest first *)
  ; events : Event.t Queue.t
  ; mutable time : int
  ; mutable next_oid : int
  ; mutable next_tid : int
  ; mutable next_funding : int
  }

let create ?(config = Config.default) () =
  let books = Coin.Table.create () in
  List.iter config.meta.universe ~f:(fun m ->
    Hashtbl.set books ~key:m.name ~data:(Order_book.create m.name));
  { config
  ; clearinghouse =
      Clearinghouse.create
        ~fees:config.fees
        ~default_leverage:config.default_leverage
        config.meta
  ; books
  ; marks = Coin.Table.create ()
  ; last_trade = Coin.Table.create ()
  ; funding_rates = Coin.Table.create ()
  ; owner_orders = Address.Table.create ()
  ; cloids = Address.Table.create ()
  ; fills = Address.Table.create ()
  ; events = Queue.create ()
  ; time = 0
  ; next_oid = 1
  ; next_tid = 1
  ; next_funding = config.funding_interval_ns
  }
;;

let config t = t.config
let meta t = t.config.meta
let clearinghouse t = t.clearinghouse
let now t = t.time
let ms ns = ns / 1_000_000
let emit t event = Queue.enqueue t.events event

let drain_events t =
  let events = Queue.to_list t.events in
  Queue.clear t.events;
  events
;;

let book t coin = Hashtbl.find t.books coin
let deposit t address usd = Clearinghouse.deposit t.clearinghouse address usd

let set_leverage t address coin lev =
  Clearinghouse.set_leverage t.clearinghouse address coin lev
;;

let mark t coin =
  match Hashtbl.find t.marks coin with
  | Some _ as mark -> mark
  | None ->
    (match Hashtbl.find t.last_trade coin with
     | Some _ as px -> px
     | None -> Option.bind (book t coin) ~f:Order_book.mid)
;;

let mark_fn t : Clearinghouse.mark = mark t

(* Order indexes *)

let owner_index t address =
  Hashtbl.find_or_add t.owner_orders address ~default:Order_id.Table.create
;;

let cloid_index t address =
  Hashtbl.find_or_add t.cloids address ~default:Cloid.Table.create
;;

let index_resting t (o : Order_book.Resting_order.t) ~coin =
  Hashtbl.set (owner_index t o.owner) ~key:o.oid ~data:coin;
  Option.iter o.cloid ~f:(fun cloid ->
    Hashtbl.set (cloid_index t o.owner) ~key:cloid ~data:o.oid)
;;

let unindex t ~owner ~oid ~cloid =
  Option.iter (Hashtbl.find t.owner_orders owner) ~f:(fun tbl -> Hashtbl.remove tbl oid);
  Option.iter cloid ~f:(fun cloid ->
    Option.iter (Hashtbl.find t.cloids owner) ~f:(fun tbl -> Hashtbl.remove tbl cloid))
;;

let open_order_of_resting ~coin ?sz (o : Order_book.Resting_order.t) : Open_order.t =
  { coin
  ; side = o.side
  ; limit_px = o.px
  ; sz = Option.value sz ~default:o.remaining
  ; oid = o.oid
  ; timestamp = ms o.timestamp
  ; orig_sz = Some o.orig_sz
  ; cloid = o.cloid
  }
;;

let resting_orders_of t address =
  match Hashtbl.find t.owner_orders address with
  | None -> []
  | Some tbl ->
    Hashtbl.to_alist tbl
    |> List.filter_map ~f:(fun (oid, coin) ->
      Option.bind (book t coin) ~f:(fun b -> Order_book.find b oid)
      |> Option.map ~f:(fun o -> coin, o))
;;

let remove_resting t ~coin oid ~reason =
  match Option.bind (book t coin) ~f:(fun b -> Order_book.cancel b oid) with
  | None -> false
  | Some o ->
    unindex t ~owner:o.owner ~oid ~cloid:o.cloid;
    emit
      t
      (Order_cancelled
         { address = o.owner
         ; order = open_order_of_resting ~coin o
         ; reason
         ; time = t.time
         });
    true
;;

(* Validation *)

let sz_decimals t coin =
  Meta.find (meta t) coin |> Option.value_map ~default:0 ~f:(fun m -> m.sz_decimals)
;;

let valid_size t coin sz =
  Size.is_positive sz && Size.equal sz (Size.round_down sz ~decimals:(sz_decimals t coin))
;;

(* Hyperliquid perps: at most 5 significant figures (integers always allowed) and at most
   [6 - szDecimals] decimals. *)
let valid_price t coin px =
  Price.is_positive px
  &&
  let is_integer = Price.to_units px % Fixed_math.scale = 0 in
  let max_decimals = Int.max 0 (6 - sz_decimals t coin) in
  let significant =
    Price.to_string px
    |> String.filter ~f:Char.is_digit
    |> String.lstrip ~drop:(Char.equal '0')
    |> String.length
  in
  is_integer
  || (Price.equal px (Price.round_down px ~decimals:max_decimals) && significant <= 5)
;;

let reserved_margin t address =
  resting_orders_of t address
  |> List.filter ~f:(fun (_, (o : Order_book.Resting_order.t)) -> not o.reduce_only)
  |> List.map ~f:(fun (coin, (o : Order_book.Resting_order.t)) ->
    Fixed_math.div_int
      (Fixed_math.notional o.px o.remaining)
      (Clearinghouse.leverage t.clearinghouse address coin))
  |> Usd.sum
;;

(* Matching results *)

let user_fill (fill : Fill.t) (s : Clearinghouse.Settlement.t) : User_fill.t =
  { coin = fill.coin
  ; px = fill.px
  ; sz = fill.sz
  ; side = s.side
  ; time = ms fill.time
  ; start_position = s.change.start_position
  ; dir = s.change.dir
  ; closed_pnl = s.change.closed_pnl
  ; hash = Fill.hash fill
  ; oid = (if s.crossed then fill.taker_oid else fill.maker_oid)
  ; crossed = s.crossed
  ; fee = s.fee
  ; tid = fill.tid
  ; fee_token = Some "USDC"
  ; cloid = (if s.crossed then fill.taker_cloid else fill.maker_cloid)
  }
;;

let record_fill t book (fill : Fill.t) =
  let taker_s, maker_s = Clearinghouse.settle_fill t.clearinghouse fill in
  let taker = user_fill fill taker_s
  and maker = user_fill fill maker_s in
  Hashtbl.add_multi t.fills ~key:fill.taker ~data:taker;
  Hashtbl.add_multi t.fills ~key:fill.maker ~data:maker;
  Hashtbl.set t.last_trade ~key:fill.coin ~data:fill.px;
  emit t (Fill { fill; taker; maker });
  (* A maker that is no longer on the book was filled completely. *)
  if Option.is_none (Order_book.find book fill.maker_oid)
  then (
    let tbl = Hashtbl.find t.owner_orders fill.maker in
    if Option.value_map tbl ~default:false ~f:(fun tbl -> Hashtbl.mem tbl fill.maker_oid)
    then (
      unindex t ~owner:fill.maker ~oid:fill.maker_oid ~cloid:fill.maker_cloid;
      emit
        t
        (Order_filled
           { address = fill.maker
           ; order =
               { coin = fill.coin
               ; side = Fill.maker_side fill
               ; limit_px = fill.px
               ; sz = Size.zero
               ; oid = fill.maker_oid
               ; timestamp = ms fill.time
               ; orig_sz = None
               ; cloid = fill.maker_cloid
               }
           ; time = t.time
           })))
;;

let avg_px (fills : Fill.t list) ~filled =
  let notional = Usd.sum (List.map fills ~f:(fun f -> Fixed_math.notional f.px f.sz)) in
  Fixed_math.avg_price ~notional ~size:filled
;;

let reject t address ?coin ?cloid reason : Order_status.t =
  emit t (Order_rejected { address; coin; cloid; reason; time = t.time });
  Error reason
;;

let asset_suffix asset = sprintf " asset=%d" (Asset.to_int asset)

(* Runs [submit] with a fresh oid and turns the book's result into an order status,
   emitting events and settling fills. *)
let submit
  t
  address
  ~asset
  ~coin
  ~side
  ~limit_px
  ~cloid
  ~(submit : oid:Order_id.t -> next_tid:(unit -> int) -> Order_book.Result.t)
  : Order_status.t
  =
  let book = Option.value_exn (book t coin) in
  let oid = Order_id.of_int t.next_oid in
  t.next_oid <- t.next_oid + 1;
  let next_tid () =
    let tid = t.next_tid in
    t.next_tid <- t.next_tid + 1;
    tid
  in
  let r = submit ~oid ~next_tid in
  List.iter r.fills ~f:(record_fill t book);
  let order ~sz : Open_order.t =
    { coin
    ; side
    ; limit_px
    ; sz
    ; oid
    ; timestamp = ms t.time
    ; orig_sz = Some (Size.( + ) r.filled r.remaining)
    ; cloid
    }
  in
  let filled () : Order_status.t =
    Filled { oid; total_sz = r.filled; avg_px = avg_px r.fills ~filled:r.filled; cloid }
  in
  let cancelled reason ~no_fill_error : Order_status.t =
    if Size.is_zero r.filled
    then reject t address ~coin ?cloid (no_fill_error ^ asset_suffix asset)
    else (
      emit
        t
        (Order_cancelled { address; order = order ~sz:r.remaining; reason; time = t.time });
      filled ())
  in
  match r.status with
  | Resting ->
    Option.iter (Order_book.find book oid) ~f:(index_resting t ~coin);
    emit t (Order_accepted { address; order = order ~sz:r.remaining; time = t.time });
    Resting { oid; cloid }
  | Filled ->
    emit t (Order_filled { address; order = order ~sz:Size.zero; time = t.time });
    filled ()
  | Cancelled Ioc_unfilled ->
    cancelled
      Ioc_unfilled
      ~no_fill_error:"Order could not immediately match against any resting orders."
  | Cancelled Self_trade ->
    cancelled
      Self_trade
      ~no_fill_error:"Order would have matched against own resting order."
  | Would_cross ->
    let show = Option.value_map ~default:"none" ~f:Price.to_string in
    reject
      t
      address
      ~coin
      ?cloid
      (sprintf
         "Post only order would have immediately matched, bbo was %s@%s.%s"
         (show (Order_book.best_bid book))
         (show (Order_book.best_ask book))
         (asset_suffix asset))
;;

(* Shared checks for limit and market orders. Returns the size to submit. *)
let pre_trade_checks t address ~asset ~coin ~side ~px ~sz ~reduce_only ~cloid =
  let open Result.Let_syntax in
  let suffix = asset_suffix asset in
  let%bind () =
    if valid_size t coin sz then Ok () else Error ("Order has invalid size." ^ suffix)
  in
  let%bind () =
    match cloid with
    | Some cloid when Hashtbl.mem (cloid_index t address) cloid ->
      Error ("Duplicate cloid." ^ suffix)
    | _ -> Ok ()
  in
  let%bind sz =
    if not reduce_only
    then Ok sz
    else (
      let reducible =
        Clearinghouse.reduce_only_size t.clearinghouse address ~coin ~side
      in
      if Size.is_zero reducible
      then Error ("Reduce only order would increase position." ^ suffix)
      else Ok (Size.min sz reducible))
  in
  let%bind () =
    if reduce_only || Usd.( >= ) (Fixed_math.notional px sz) t.config.min_order_value
    then Ok ()
    else
      Error
        (sprintf
           "Order must have minimum value of $%s.%s"
           (Usd.to_string t.config.min_order_value)
           suffix)
  in
  let%map () =
    Clearinghouse.check_order_margin
      t.clearinghouse
      address
      ~coin
      ~side
      ~px
      ~sz
      ~reserved:(reserved_margin t address)
      ~mark:(mark_fn t)
    |> Result.map_error ~f:(fun _ -> "Insufficient margin to place order." ^ suffix)
  in
  sz
;;

let place_order t address (req : Order_request.t) : Order_status.t =
  let side = Order_request.side req in
  match Meta.coin_of_asset (meta t) req.asset with
  | None ->
    reject
      t
      address
      ?cloid:req.cloid
      (sprintf "Asset %d does not exist." (Asset.to_int req.asset))
  | Some coin ->
    (match req.order_type with
     | Trigger _ ->
       reject t address ~coin ?cloid:req.cloid "Trigger orders are not supported."
     | Limit { tif } ->
       if not (valid_price t coin req.limit_px)
       then
         reject
           t
           address
           ~coin
           ?cloid:req.cloid
           ("Order has invalid price." ^ asset_suffix req.asset)
       else (
         match
           pre_trade_checks
             t
             address
             ~asset:req.asset
             ~coin
             ~side
             ~px:req.limit_px
             ~sz:req.sz
             ~reduce_only:req.reduce_only
             ~cloid:req.cloid
         with
         | Error reason -> reject t address ~coin ?cloid:req.cloid reason
         | Ok sz ->
           submit
             t
             address
             ~asset:req.asset
             ~coin
             ~side
             ~limit_px:req.limit_px
             ~cloid:req.cloid
             ~submit:(fun ~oid ~next_tid ->
               Order_book.add_limit
                 (Option.value_exn (book t coin))
                 ~oid
                 ~owner:address
                 ~side
                 ~px:req.limit_px
                 ~sz
                 ~tif
                 ~reduce_only:req.reduce_only
                 ?cloid:req.cloid
                 ~time:t.time
                 ~next_tid
                 ())))
;;

let market_order ?slippage_bps ?(reduce_only = false) ?cloid t address ~coin ~side ~sz =
  let slippage_bps = Option.value slippage_bps ~default:t.config.market_slippage_bps in
  match Meta.asset_of_coin (meta t) coin, book t coin with
  | None, _ | _, None ->
    reject t address ?cloid (sprintf "Unknown coin %s." (Coin.to_string coin))
  | Some asset, Some b ->
    (match Order_book.market_limit_px b ~side ~slippage_bps with
     | None ->
       reject
         t
         address
         ~coin
         ?cloid
         ("Order could not immediately match against any resting orders."
          ^ asset_suffix asset)
     | Some limit_px ->
       (match
          pre_trade_checks
            t
            address
            ~asset
            ~coin
            ~side
            ~px:limit_px
            ~sz
            ~reduce_only
            ~cloid
        with
        | Error reason -> reject t address ~coin ?cloid reason
        | Ok sz ->
          submit
            t
            address
            ~asset
            ~coin
            ~side
            ~limit_px
            ~cloid
            ~submit:(fun ~oid ~next_tid ->
              Order_book.market
                b
                ~oid
                ~owner:address
                ~side
                ~sz
                ~slippage_bps
                ~reduce_only
                ?cloid
                ~time:t.time
                ~next_tid
                ())))
;;

let never_placed asset : Cancel_status.t =
  Error ("Order was never placed, already canceled, or filled." ^ asset_suffix asset)
;;

let owned_coin t address oid =
  Option.bind (Hashtbl.find t.owner_orders address) ~f:(fun tbl -> Hashtbl.find tbl oid)
;;

let cancel_oid t address ~asset ~oid ~reason : Cancel_status.t =
  match owned_coin t address oid, Meta.coin_of_asset (meta t) asset with
  | Some coin, Some asset_coin when Coin.equal coin asset_coin ->
    if remove_resting t ~coin oid ~reason then Success else never_placed asset
  | _ -> never_placed asset
;;

let cancel t address (req : Cancel_request.t) =
  cancel_oid t address ~asset:req.asset ~oid:req.oid ~reason:User
;;

let oid_of_cloid t address cloid =
  Option.bind (Hashtbl.find t.cloids address) ~f:(fun tbl -> Hashtbl.find tbl cloid)
;;

let cancel_by_cloid t address (req : Cancel_by_cloid.t) =
  match oid_of_cloid t address req.cloid with
  | None -> never_placed req.asset
  | Some oid -> cancel_oid t address ~asset:req.asset ~oid ~reason:User
;;

let modify t address (req : Modify_request.t) : Order_status.t =
  let oid =
    match req.oid with
    | Oid oid -> Some oid
    | Cloid cloid -> oid_of_cloid t address cloid
  in
  let cancelled =
    match oid with
    | None -> false
    | Some oid ->
      (match owned_coin t address oid with
       | None -> false
       | Some coin -> remove_resting t ~coin oid ~reason:Modified)
  in
  if cancelled
  then place_order t address req.order
  else reject t address ?cloid:req.order.cloid "Cannot modify canceled or filled order"
;;

(* Info *)

let l2_book ?n_levels t coin =
  let n_levels = Option.value n_levels ~default:t.config.l2_levels in
  book t coin
  |> Option.map ~f:(fun b ->
    let bids, asks = Order_book.l2 b ~n_levels in
    { L2_book.coin; time = ms t.time; bids; asks })
;;

let all_mids t =
  List.filter_map (meta t).universe ~f:(fun m ->
    Option.bind (book t m.name) ~f:Order_book.mid |> Option.map ~f:(fun px -> m.name, px))
;;

let open_orders t address =
  resting_orders_of t address
  |> List.map ~f:(fun (coin, o) -> open_order_of_resting ~coin o)
  |> List.sort ~compare:(fun (a : Open_order.t) b -> Order_id.compare b.oid a.oid)
;;

let user_fills t address = Hashtbl.find_multi t.fills address

let clearinghouse_state t address =
  Clearinghouse.state t.clearinghouse address ~mark:(mark_fn t) ~time:(ms t.time)
;;

(* Marks, liquidation and funding *)

let liquidate t =
  let liquidations = Clearinghouse.mark_to_market t.clearinghouse ~mark:(mark_fn t) in
  List.iter liquidations ~f:(fun liquidation ->
    emit t (Liquidation { liquidation; time = t.time }));
  List.map liquidations ~f:(fun l -> l.address)
  |> List.dedup_and_sort ~compare:Address.compare
  |> List.iter ~f:(fun address ->
    List.iter (resting_orders_of t address) ~f:(fun (coin, o) ->
      ignore (remove_resting t ~coin o.oid ~reason:Liquidated : bool)))
;;

let set_mark t coin px =
  Hashtbl.set t.marks ~key:coin ~data:px;
  liquidate t
;;

let set_funding_rate t coin rate = Hashtbl.set t.funding_rates ~key:coin ~data:rate

let apply_funding t =
  List.iter (meta t).universe ~f:(fun m ->
    let coin = m.name in
    Option.iter (mark t coin) ~f:(fun mark ->
      let rate =
        Hashtbl.find t.funding_rates coin
        |> Option.value ~default:t.config.default_funding_rate
      in
      let payments = Clearinghouse.apply_funding t.clearinghouse ~coin ~rate ~mark in
      if not (List.is_empty payments)
      then emit t (Funding { coin; rate; mark; payments; time = t.time })))
;;

let step t ~now =
  if now < t.time
  then
    raise_s
      [%message "Exchange.step: time went backwards" (now : int) ~time:(t.time : int)];
  while t.next_funding <= now do
    t.time <- t.next_funding;
    apply_funding t;
    t.next_funding <- t.next_funding + t.config.funding_interval_ns
  done;
  t.time <- now;
  liquidate t
;;
