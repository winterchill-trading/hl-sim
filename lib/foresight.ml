open! Core
open! Hl_protocol
module Market_sim = Exchange_core_engine.Market_sim

type walk =
  { coin : Coin.t
  ; path : float Queue.t (** current point first, [lookahead_ticks] more after it *)
  }

type t =
  { market_sim : Market_sim.t
  ; random : Random.State.t
  ; sigma : float (** per-tick standard deviation of log returns, as [Market_sim]'s *)
  ; lookahead : Time_ns.Span.t
  ; walks : walk list
  }

let lookahead t = t.lookahead

(* Box-Muller, as in [Market_sim]. *)
let gaussian random =
  let u1 = Float.max Float.min_positive_normal_value (Random.State.float random 1.) in
  let u2 = Random.State.float random 1. in
  Float.sqrt (-2. *. Float.log u1) *. Float.cos (2. *. Float.pi *. u2)
;;

let extend t (w : walk) =
  let last = Queue.last_exn w.path in
  Queue.enqueue w.path (last *. Float.exp (t.sigma *. gaussian t.random))
;;

let create ~seed ~lookahead market_sim ~coins =
  if Time_ns.Span.(lookahead < zero)
  then
    raise_s [%message "Foresight.create: negative lookahead" (lookahead : Time_ns.Span.t)];
  let config = Market_sim.config market_sim in
  let ticks = Float.iround_nearest_exn Time_ns.Span.(lookahead // config.tick_interval) in
  let sigma =
    config.vol_bps /. 10_000. *. Float.sqrt (Time_ns.Span.to_sec config.tick_interval)
  in
  let walks =
    List.map coins ~f:(fun coin ->
      match Market_sim.reference_price market_sim coin with
      | Some px -> { coin; path = Queue.singleton (Price.to_float px) }
      | None -> raise_s [%message "Foresight.create: coin not simulated" (coin : Coin.t)])
  in
  let t =
    { market_sim
    ; random = Random.State.make [| seed; 0xf0e5 |]
    ; sigma
    ; lookahead = Time_ns.Span.scale_int config.tick_interval ticks
    ; walks
    }
  in
  List.iter walks ~f:(fun w ->
    for _ = 1 to ticks do
      extend t w
    done);
  t
;;

let tick t =
  List.iter t.walks ~f:(fun w ->
    extend t w;
    ignore (Queue.dequeue_exn w.path : float);
    Market_sim.set_reference
      t.market_sim
      w.coin
      ((Price.of_float [@alert "-lossy"]) (Queue.peek_exn w.path)))
;;

let ahead t coin =
  List.find t.walks ~f:(fun w -> Coin.equal w.coin coin)
  |> Option.map ~f:(fun w -> Queue.last_exn w.path)
;;
