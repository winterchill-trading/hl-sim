open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange
module Account_state = Exchange_core_engine.Account_state
module Clearinghouse = Exchange_core_engine.Clearinghouse
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

type t =
  { coin : Coin.t
  ; funding : float
  ; open_interest : Size.t
  ; prev_day_px : Price.t
  ; day_ntl_vlm : Usd.t
  ; premium : float
  ; oracle_px : Price.t
  ; mark_px : Price.t
  ; mid_px : Price.t option
  ; impact_pxs : (Price.t * Price.t) option
  ; day_base_vlm : Size.t
  }
[@@deriving sexp_of]

(* Plain decimal notation, as Hyperliquid sends rates: "0.0000125", never "1.25e-05". *)
let rate_string x =
  let s = sprintf "%.10f" x in
  let s = String.rstrip s ~drop:(Char.equal '0') in
  if String.is_suffix s ~suffix:"." then s ^ "0" else s
;;

let to_ws_message t =
  let px p = `String (Price.to_string p) in
  let ctx =
    List.filter_opt
      [ Some ("funding", `String (rate_string t.funding))
      ; Some ("openInterest", `String (Size.to_string t.open_interest))
      ; Some ("prevDayPx", px t.prev_day_px)
      ; Some ("dayNtlVlm", `String (Usd.to_string t.day_ntl_vlm))
      ; Some ("premium", `String (rate_string t.premium))
      ; Some ("oraclePx", px t.oracle_px)
      ; Some ("markPx", px t.mark_px)
      ; Some ("midPx", Option.value_map t.mid_px ~default:`Null ~f:px)
      ; Option.map t.impact_pxs ~f:(fun (bid, ask) ->
          "impactPxs", `List [ px bid; px ask ])
      ; Some ("dayBaseVlm", `String (Size.to_string t.day_base_vlm))
      ]
  in
  `Assoc
    [ "channel", `String "activeAssetCtx"
    ; "data", `Assoc [ "coin", `String (Coin.to_string t.coin); "ctx", `Assoc ctx ]
    ]
;;

let ns_per_day = 86_400 * 1_000_000_000
let day_of time = time / ns_per_day

module Day_stats = struct
  type coin_stats =
    { mutable day : int
    ; mutable ntl : Usd.t
    ; mutable base : Size.t
    ; mutable last_px : Price.t option
    ; mutable prev_day_px : Price.t option
    }

  type t = coin_stats Coin.Table.t

  let create () = Coin.Table.create ()

  (* Moves the stats to [day], closing the days in between. *)
  let roll s ~day =
    if day > s.day
    then (
      s.day <- day;
      s.ntl <- Usd.zero;
      s.base <- Size.zero;
      if Option.is_some s.last_px then s.prev_day_px <- s.last_px)
  ;;

  let record_trade t ~coin ~px ~sz ~time =
    let day = day_of time in
    let s =
      Hashtbl.find_or_add t coin ~default:(fun () ->
        { day; ntl = Usd.zero; base = Size.zero; last_px = None; prev_day_px = None })
    in
    roll s ~day;
    s.ntl <- Usd.(s.ntl + Notional.mul px sz);
    s.base <- Size.(s.base + sz);
    s.last_px <- Some px
  ;;

  let find t coin ~time =
    Option.map (Hashtbl.find t coin) ~f:(fun s ->
      roll s ~day:(day_of time);
      s)
  ;;
end

let open_interest exchange coin =
  Clearinghouse.accounts (Exchange.clearinghouse exchange)
  |> List.fold ~init:Size.zero ~f:(fun total account ->
    match Account_state.position account coin with
    | Some p when Size.is_positive p.size -> Size.(total + p.size)
    | _ -> total)
;;

let of_exchange exchange stats coin =
  match Exchange.instrument exchange coin, Exchange.mark exchange coin with
  | None, _ | _, None -> None
  | Some instrument, Some mark ->
    let stats = Day_stats.find stats coin ~time:(Exchange.now exchange) in
    let book = Exchange.l2 ~n_levels:1 exchange coin in
    let mid_px =
      Option.bind book ~f:(fun (book : Exchange_core.L2.t) ->
        match book.bids, book.asks with
        | bid :: _, ask :: _ -> Some (Price.div_int Price.(bid.px + ask.px) 2)
        | _ -> None)
    in
    let impact_pxs =
      match Exchange.impact_pxs exchange coin with
      | Some bid, Some ask ->
        let round = Exchange_core.Instrument.round_price instrument in
        Some (round bid, round ask)
      | _ -> None
    in
    let oracle_px = Option.value (Exchange.oracle exchange coin) ~default:mark in
    let premium =
      match Exchange.premium exchange coin with
      | Some premium -> premium
      | None ->
        Option.value_map mid_px ~default:0. ~f:(fun mid ->
          (Price.to_float mid -. Price.to_float oracle_px) /. Price.to_float oracle_px)
    in
    { coin
    ; funding = Exchange.funding_rate exchange coin
    ; open_interest = open_interest exchange coin
    ; prev_day_px =
        Option.bind stats ~f:(fun s -> s.prev_day_px) |> Option.value ~default:mark
    ; day_ntl_vlm = Option.value_map stats ~default:Usd.zero ~f:(fun s -> s.ntl)
    ; premium
    ; oracle_px
    ; mark_px = mark
    ; mid_px
    ; impact_pxs
    ; day_base_vlm = Option.value_map stats ~default:Size.zero ~f:(fun s -> s.base)
    }
    |> Option.some
;;

module Request = struct
  type t =
    { subscribe : bool
    ; coin : Coin.t
    }
  [@@deriving sexp_of, equal]

  let of_json json =
    let open Yojson.Safe.Util in
    match json with
    | `Assoc _ ->
      let subscription = member "subscription" json in
      (match member "method" json, subscription with
       | `String (("subscribe" | "unsubscribe") as meth), `Assoc _ ->
         (match member "type" subscription, member "coin" subscription with
          | `String "activeAssetCtx", `String coin ->
            Some { subscribe = String.equal meth "subscribe"; coin = Coin.of_string coin }
          | _ -> None)
       | _ -> None)
    | _ -> None
  ;;

  let to_json t =
    `Assoc
      [ "method", `String (if t.subscribe then "subscribe" else "unsubscribe")
      ; ( "subscription"
        , `Assoc
            [ "type", `String "activeAssetCtx"; "coin", `String (Coin.to_string t.coin) ]
        )
      ]
  ;;

  let response t = `Assoc [ "channel", `String "subscriptionResponse"; "data", to_json t ]
end
