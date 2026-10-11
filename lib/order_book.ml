open! Core
open! Hl_protocol

module Resting_order = struct
  type t =
    { oid : Order_id.t
    ; owner : Address.t
    ; side : Side.t
    ; px : Price.t
    ; mutable remaining : Size.t
    ; orig_sz : Size.t
    ; timestamp : int
    ; reduce_only : bool
    ; cloid : Cloid.t option
    }
  [@@deriving sexp_of]
end

module Cancel_reason = struct
  type t =
    | Ioc_unfilled
    | Self_trade
  [@@deriving sexp_of, compare, equal]
end

module Status = struct
  type t =
    | Resting
    | Filled
    | Cancelled of Cancel_reason.t
    | Would_cross
  [@@deriving sexp_of, compare, equal]
end

module Result = struct
  type t =
    { fills : Fill.t list
    ; status : Status.t
    ; filled : Size.t
    ; remaining : Size.t
    }
  [@@deriving sexp_of]
end

module Level = struct
  type t =
    { mutable total : Size.t
    ; orders : Resting_order.t Queue.t
    }
  [@@deriving sexp_of]
end

type t =
  { coin : Coin.t
  ; mutable bids : Level.t Price.Map.t
  ; mutable asks : Level.t Price.Map.t
  ; index : Resting_order.t Order_id.Table.t
  }
[@@deriving sexp_of]

let create coin =
  { coin
  ; bids = Price.Map.empty
  ; asks = Price.Map.empty
  ; index = Order_id.Table.create ()
  }
;;

let coin t = t.coin

let side_levels t (side : Side.t) =
  match side with
  | Buy -> t.bids
  | Sell -> t.asks
;;

let set_side_levels t (side : Side.t) levels =
  match side with
  | Buy -> t.bids <- levels
  | Sell -> t.asks <- levels
;;

(* Best level of a side: highest bid, lowest ask. *)
let best_level t (side : Side.t) =
  match side with
  | Buy -> Map.max_elt t.bids
  | Sell -> Map.min_elt t.asks
;;

let best_bid t = Map.max_elt t.bids |> Option.map ~f:fst
let best_ask t = Map.min_elt t.asks |> Option.map ~f:fst

let mid t =
  match best_bid t, best_ask t with
  | Some b, Some a -> Some (Price.of_units ((Price.to_units b + Price.to_units a) / 2))
  | _ -> None
;;

(* Whether a taker on [side] with [limit] would trade against a maker at [px]. *)
let crosses (side : Side.t) ~limit px =
  match side with
  | Buy -> Price.( <= ) px limit
  | Sell -> Price.( >= ) px limit
;;

let rest t (order : Resting_order.t) =
  let levels = side_levels t order.side in
  let level =
    match Map.find levels order.px with
    | Some level -> level
    | None ->
      let level = { Level.total = Size.zero; orders = Queue.create () } in
      set_side_levels t order.side (Map.set levels ~key:order.px ~data:level);
      level
  in
  Queue.enqueue level.orders order;
  level.total <- Size.( + ) level.total order.remaining;
  Hashtbl.set t.index ~key:order.oid ~data:order
;;

let remove_level_if_empty t (side : Side.t) px (level : Level.t) =
  if Queue.is_empty level.orders
  then set_side_levels t side (Map.remove (side_levels t side) px)
;;

(* Per-call context of the incoming order, threaded through the matching loop.

   OxCaml: the record is allocated on the stack ([local_]) by [sweep]'s caller and passed
   down as a [local_] argument, so matching an order does not heap-allocate its context.
   Fields whose types are not immediate are marked [global_] so that reading them yields
   heap values which may be stored into the (heap-allocated) fills. *)
type taker =
  { global_ oid : Order_id.t
  ; global_ owner : Address.t
  ; side : Side.t
  ; global_ limit : Price.t
  ; global_ cloid : Cloid.t option
  ; time : int
  ; global_ next_tid : unit -> int
  }

type stop =
  | Done
  | Exhausted
  | Self_trade

(* Result of [sweep], returned on the caller's stack ([exclave_]). A local tuple would
   make its components local too, so the components could not escape into the heap
   [Result.t]; [global_] record fields avoid that. *)
type swept =
  { global_ unfilled : Size.t
  ; global_ rev_fills : Fill.t list
  ; stop : stop
  }

(* Matches [remaining] against the opposite side until filled, out of crossing liquidity,
   or blocked by an own order. Returns the unfilled size, the fills in reverse execution
   order and why matching stopped.

   OxCaml: the recursive call is [exclave_ sweep ...], which ends this frame's region
   before the call so it stays a tail call while still returning into the caller's region
   (a plain call is rejected: the result is local, not a global return value). *)
let rec sweep t (local_ (taker : taker)) remaining fills =
  if Size.is_zero remaining
  then exclave_ { unfilled = remaining; rev_fills = fills; stop = Done }
  else (
    let opposite = Side.flip taker.side in
    match best_level t opposite with
    | None -> exclave_ { unfilled = remaining; rev_fills = fills; stop = Exhausted }
    | Some (px, _) when not (crosses taker.side ~limit:taker.limit px) ->
      exclave_ { unfilled = remaining; rev_fills = fills; stop = Exhausted }
    | Some (px, level) ->
      let maker = Queue.peek_exn level.orders in
      if Address.equal maker.owner taker.owner
      then exclave_ { unfilled = remaining; rev_fills = fills; stop = Self_trade }
      else (
        let sz = Size.min remaining maker.remaining in
        maker.remaining <- Size.( - ) maker.remaining sz;
        level.total <- Size.( - ) level.total sz;
        if Size.is_zero maker.remaining
        then (
          ignore (Queue.dequeue_exn level.orders : Resting_order.t);
          Hashtbl.remove t.index maker.oid;
          remove_level_if_empty t opposite px level);
        let fill : Fill.t =
          { tid = taker.next_tid ()
          ; coin = t.coin
          ; px
          ; sz
          ; taker_side = taker.side
          ; taker_oid = taker.oid
          ; maker_oid = maker.oid
          ; taker = taker.owner
          ; maker = maker.owner
          ; taker_cloid = taker.cloid
          ; maker_cloid = maker.cloid
          ; time = taker.time
          }
        in
        exclave_ sweep t taker (Size.( - ) remaining sz) (fill :: fills)))
;;

let check_new_order t ~oid ~sz =
  if not (Size.is_positive sz)
  then raise_s [%message "Order_book: size must be positive" (sz : Size.t)];
  if Hashtbl.mem t.index oid
  then raise_s [%message "Order_book: duplicate oid" (oid : Order_id.t)]
;;

let execute t ~oid ~owner ~side ~limit ~sz ~tif ~reduce_only ~cloid ~time ~next_tid
  : Result.t
  =
  let local_ taker = { oid; owner; side; limit; cloid; time; next_tid } in
  let { unfilled = remaining; rev_fills; stop } = sweep t taker sz [] in
  let fills = List.rev rev_fills in
  let filled = Size.( - ) sz remaining in
  let status : Status.t =
    match stop, (tif : Tif.t) with
    | Done, _ -> Filled
    | Self_trade, _ -> Cancelled Self_trade
    | Exhausted, (Ioc | Alo) -> Cancelled Ioc_unfilled
    | Exhausted, Gtc ->
      rest
        t
        { oid
        ; owner
        ; side
        ; px = limit
        ; remaining
        ; orig_sz = sz
        ; timestamp = time
        ; reduce_only
        ; cloid
        };
      Resting
  in
  { fills; status; filled; remaining }
;;

let add_limit
  t
  ~oid
  ~owner
  ~side
  ~px
  ~sz
  ~tif
  ?(reduce_only = false)
  ?cloid
  ~time
  ~next_tid
  ()
  : Result.t
  =
  check_new_order t ~oid ~sz;
  if not (Price.is_positive px)
  then raise_s [%message "Order_book: price must be positive" (px : Price.t)];
  match (tif : Tif.t) with
  | Alo ->
    let would_cross =
      match best_level t (Side.flip side) with
      | None -> false
      | Some (best, _) -> crosses side ~limit:px best
    in
    if would_cross
    then { fills = []; status = Would_cross; filled = Size.zero; remaining = sz }
    else (
      rest
        t
        { oid
        ; owner
        ; side
        ; px
        ; remaining = sz
        ; orig_sz = sz
        ; timestamp = time
        ; reduce_only
        ; cloid
        };
      { fills = []; status = Resting; filled = Size.zero; remaining = sz })
  | Gtc | Ioc ->
    execute t ~oid ~owner ~side ~limit:px ~sz ~tif ~reduce_only ~cloid ~time ~next_tid
;;

let market_limit_px t ~side ~slippage_bps =
  best_level t (Side.flip side)
  |> Option.map ~f:(fun (best, _) ->
    let units = Price.to_units best in
    let delta =
      Fixed_math.mul_units units (Fixed_math.rate_of_bps (Float.of_int slippage_bps))
    in
    match (side : Side.t) with
    | Buy -> Price.of_units (units + delta)
    | Sell -> Price.of_units (Int.max 0 (units - delta)))
;;

let market
  t
  ~oid
  ~owner
  ~side
  ~sz
  ~slippage_bps
  ?(reduce_only = false)
  ?cloid
  ~time
  ~next_tid
  ()
  : Result.t
  =
  check_new_order t ~oid ~sz;
  match market_limit_px t ~side ~slippage_bps with
  | None ->
    { fills = []; status = Cancelled Ioc_unfilled; filled = Size.zero; remaining = sz }
  | Some limit ->
    execute t ~oid ~owner ~side ~limit ~sz ~tif:Ioc ~reduce_only ~cloid ~time ~next_tid
;;

let find t oid = Hashtbl.find t.index oid

let cancel t oid =
  match Hashtbl.find_and_remove t.index oid with
  | None -> None
  | Some (order : Resting_order.t) ->
    (match Map.find (side_levels t order.side) order.px with
     | None -> ()
     | Some level ->
       Queue.filter_inplace level.orders ~f:(fun (o : Resting_order.t) ->
         not (Order_id.equal o.oid oid));
       level.total <- Size.( - ) level.total order.remaining;
       remove_level_if_empty t order.side order.px level);
    Some order
;;

let levels_best_first t (side : Side.t) =
  match side with
  | Buy -> Map.to_sequence t.bids ~order:`Decreasing_key
  | Sell -> Map.to_sequence t.asks ~order:`Increasing_key
;;

let l2 t ~n_levels =
  let side_l2 side =
    levels_best_first t side
    |> Fn.flip Sequence.take n_levels
    |> Sequence.map ~f:(fun (px, (level : Level.t)) ->
      { L2_book.Level.px; sz = level.total; n = Queue.length level.orders })
    |> Sequence.to_list
  in
  side_l2 Buy, side_l2 Sell
;;

let iter t ~(f @ local) =
  (* OxCaml: [f] is a [local_] closure, and Base's [Map.iter] / [Queue.iter] accept local
     closures too, so the wrapper closures below stay on the stack. *)
  let visit_level (level : Level.t) = Queue.iter level.orders ~f in
  Map.fold_right t.bids ~init:() ~f:(fun ~key:_ ~data () -> visit_level data);
  Map.iter t.asks ~f:visit_level [@nontail]
;;

let orders t =
  let acc = ref [] in
  iter t ~f:(fun o -> acc := o :: !acc);
  List.rev !acc
;;

let length t = Hashtbl.length t.index
let is_empty t = Hashtbl.is_empty t.index

let invariant t =
  let count = ref 0 in
  let check_side (side : Side.t) levels =
    Map.iteri levels ~f:(fun ~key:px ~data:(level : Level.t) ->
      if Queue.is_empty level.orders
      then raise_s [%message "empty level" (side : Side.t) (px : Price.t)];
      let total =
        Queue.fold level.orders ~init:Size.zero ~f:(fun acc (o : Resting_order.t) ->
          if not (Size.is_positive o.remaining)
          then raise_s [%message "non-positive remaining" (o : Resting_order.t)];
          if not (Price.equal o.px px && Side.equal o.side side)
          then raise_s [%message "order on wrong level" (o : Resting_order.t)];
          (match Hashtbl.find t.index o.oid with
           | Some o' when phys_equal o o' -> ()
           | _ -> raise_s [%message "order missing from index" (o : Resting_order.t)]);
          incr count;
          Size.( + ) acc o.remaining)
      in
      if not (Size.equal total level.total)
      then raise_s [%message "level total mismatch" (px : Price.t)])
  in
  check_side Buy t.bids;
  check_side Sell t.asks;
  if !count <> Hashtbl.length t.index
  then raise_s [%message "index has stale entries" (!count : int)];
  match best_bid t, best_ask t with
  | Some b, Some a when Price.( >= ) b a ->
    raise_s [%message "crossed book" (b : Price.t) (a : Price.t)]
  | _ -> ()
;;
