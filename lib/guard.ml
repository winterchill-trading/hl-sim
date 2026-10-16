open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange
module Price_collar = Exchange_core_engine.Price_collar
module Halt_rule = Exchange_core_engine.Halt_rule
module Guard_event = Exchange_core_engine.Guard_event

module Config = struct
  type t =
    { collar : Price_collar.Config.t option
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of]

  let off = { collar = None; halt_rule = None }
end

let parse_level s : Halt_rule.Level.t Or_error.t =
  match String.lsplit2 (String.strip s) ~on:':' with
  | None -> Or_error.error_s [%message "halt level is not PERCENT:DURATION" s]
  | Some (pct, duration) ->
    Or_error.try_with_join (fun () ->
      let pct = Float.of_string (String.strip pct) in
      let move_bps = Float.iround_nearest_exn (pct *. 100.) in
      let duration_ns =
        match String.strip duration with
        | "reopen" -> None
        | d -> Some (Time_ns.Span.to_int_ns (Time_ns.Span.of_string d))
      in
      Ok { Halt_rule.Level.move_bps; duration_ns })
    |> Or_error.tag_s ~tag:[%message "invalid halt level" s]
;;

let parse_levels s =
  String.split s ~on:',' |> List.map ~f:parse_level |> Or_error.combine_errors
;;

let reference_arg =
  Command.Arg_type.of_alist_exn ~list_values_in_help:false
    [ "last", Price_collar.Reference.Last_trade; "mid", Mid; "mark", Mark ]
;;

let action_arg =
  Command.Arg_type.of_alist_exn ~list_values_in_help:false [ "reject", Price_collar.Action.Reject; "reprice", Reprice ]
;;

let scope_arg =
  Command.Arg_type.of_alist_exn ~list_values_in_help:false
    [ "market", Halt_rule.Scope.Market_wide; "symbol", Per_symbol ]
;;

let collar_config ~bps ~ticks ~reference ~action ~anchored =
  let band : Price_collar.Band.t option Or_error.t =
    match bps, ticks with
    | Some _, Some _ -> Or_error.error_string "-collar-bps and -collar-ticks exclude each other"
    | Some n, None -> Ok (Some (Bps n))
    | None, Some n -> Ok (Some (Ticks n))
    | None, None -> Ok None
  in
  match%bind.Or_error band with
  | None ->
    if Option.is_some reference || Option.is_some action
    then Or_error.error_string "-collar-reference and -collar-action need -collar-bps or -collar-ticks"
    else Ok None
  | Some band ->
    let config =
      { Price_collar.Config.band
      ; reference =
          Option.value reference ~default:(if anchored then Price_collar.Reference.Mark else Last_trade)
      ; action = Option.value action ~default:Price_collar.Action.Reject
      }
    in
    let%map.Or_error () = Price_collar.Config.validate config in
    Some config
;;

let halt_config ~levels ~scope =
  match levels with
  | None ->
    if Option.is_some scope
    then Or_error.error_string "-halt-scope needs -halt-levels"
    else Ok None
  | Some levels ->
    let%bind.Or_error levels = parse_levels levels in
    let config =
      { Halt_rule.Config.levels
      ; scope = Option.value scope ~default:Halt_rule.Scope.Market_wide
      ; watch = []
      ; observe = Mark
      ; reopen = Automatic
      }
    in
    let%map.Or_error () = Halt_rule.Config.validate config in
    Some config
;;

let param =
  let open Command.Let_syntax in
  let%map_open bps =
    flag
      "-collar-bps"
      (optional int)
      ~doc:"N price collar: reject orders priced more than N bps from the reference"
  and ticks =
    flag "-collar-ticks" (optional int) ~doc:"N price collar of N ticks around the reference"
  and reference =
    flag
      "-collar-reference"
      (optional reference_arg)
      ~doc:"REF collar reference: last, mid or mark (default mark when anchored, else last)"
  and action =
    flag
      "-collar-action"
      (optional action_arg)
      ~doc:"ACTION reject (default) or reprice an order beyond the collar"
  and levels =
    flag
      "-halt-levels"
      (optional string)
      ~doc:
        "LEVELS halt trading on a move from the session reference, e.g. \
         7:15m,13:15m,20:reopen (percent:duration; reopen waits for POST /sim/reopen)"
  and scope =
    flag
      "-halt-scope"
      (optional scope_arg)
      ~doc:"SCOPE market (default: a halt stops every coin) or symbol"
  in
  fun ~anchored ->
    let%bind.Or_error collar = collar_config ~bps ~ticks ~reference ~action ~anchored in
    let%map.Or_error halt_rule = halt_config ~levels ~scope in
    { Config.collar; halt_rule }
;;

let apply (config : Config.t) ex =
  let%bind.Or_error () =
    match config.collar with
    | None -> Ok ()
    | Some collar ->
      Exchange.instruments ex
      |> List.map ~f:(fun (i : Exchange_core.Instrument.t) ->
        Exchange.set_collar ex i.symbol (Some collar))
      |> Or_error.combine_errors_unit
  in
  match config.halt_rule with
  | None -> Ok ()
  | Some rule -> Exchange.set_halt_rule ex (Some rule)
;;

let collar_of_exchange ex =
  List.find_map (Exchange.instruments ex) ~f:(fun (i : Exchange_core.Instrument.t) ->
    Exchange.collar ex i.symbol)
;;

let is_on ex = Option.is_some (Exchange.halt_rule ex) || Option.is_some (collar_of_exchange ex)
let px p = `String (Price.to_string p)

let side_json : Exchange_core.Side.t -> Yojson.Safe.t = function
  | Buy -> `String "buy"
  | Sell -> `String "sell"
;;

let reference_name : Price_collar.Reference.t -> string = function
  | Last_trade -> "last"
  | Mid -> "mid"
  | Mark -> "mark"
;;

let collar_json (c : Price_collar.Config.t) : Yojson.Safe.t =
  `Assoc
    [ (match c.band with
       | Bps n -> "band_bps", `Int n
       | Ticks n -> "band_ticks", `Int n)
    ; "reference", `String (reference_name c.reference)
    ; ( "action"
      , `String
          (match c.action with
           | Reject -> "reject"
           | Reprice -> "reprice") )
    ]
;;

let ns_to_ms ns = ns / 1_000_000

let halt_rule_json (r : Halt_rule.Config.t) : Yojson.Safe.t =
  `Assoc
    [ ( "levels"
      , `List
          (List.map r.levels ~f:(fun (l : Halt_rule.Level.t) ->
             `Assoc
               [ "move_bps", `Int l.move_bps
               ; ( "duration_s"
                 , match l.duration_ns with
                   | None -> `String "reopen"
                   | Some ns -> `Int (ns / 1_000_000_000) )
               ])) )
    ; ( "scope"
      , `String
          (match r.scope with
           | Market_wide -> "market"
           | Per_symbol -> "symbol") )
    ]
;;

let kind_fields : Guard_event.Kind.t -> (string * Yojson.Safe.t) list = function
  | Collar_rejected { side; limit_px; reference; bound } ->
    [ "kind", `String "collar_rejected"
    ; "side", side_json side
    ; "limit_px", px limit_px
    ; "reference", px reference
    ; "bound", px bound
    ]
  | Collar_repriced { side; limit_px; repriced_px; reference } ->
    [ "kind", `String "collar_repriced"
    ; "side", side_json side
    ; "limit_px", px limit_px
    ; "repriced_px", px repriced_px
    ; "reference", px reference
    ]
  | Halt_rejected { side } -> [ "kind", `String "halt_rejected"; "side", side_json side ]
  | Halted { trigger_symbol; level; reference; px = moved; move_bps; until } ->
    [ "kind", `String "halted"
    ; "trigger", `String (Exchange_core.Symbol.to_string trigger_symbol)
    ; "level", `Int level
    ; "reference", px reference
    ; "px", px moved
    ; "move_bps", `Int move_bps
    ; ( "until_ms"
      , match until with
        | None -> `Null
        | Some ns -> `Int (ns_to_ms ns) )
    ]
  | Reopen_pending -> [ "kind", `String "reopen_pending" ]
  | Reopened -> [ "kind", `String "reopened" ]
;;

let event_json (e : Guard_event.t) : Yojson.Safe.t =
  `Assoc
    ([ "time_ms", `Int (ns_to_ms e.time)
     ; "coin", `String (Exchange_core.Symbol.to_string e.symbol)
     ]
     @ kind_fields e.kind
     @ List.filter_opt
         [ Option.map e.account ~f:(fun a ->
             "user", `String (Exchange_core.Account.to_string a))
         ; Option.map e.order_id ~f:(fun o ->
             "oid", `Int (Int64.to_int_exn (Exchange_core.Order_id.to_int64 o)))
         ])
;;

let stats_json (s : Guard_event.Stats.t) : Yojson.Safe.t =
  `Assoc
    [ "collar_rejected", `Int s.collar_rejected
    ; "collar_repriced", `Int s.collar_repriced
    ; "collar_unreferenced", `Int s.collar_unreferenced
    ; "halt_rejected", `Int s.halt_rejected
    ; "halts", `Int s.halts
    ; "reopens", `Int s.reopens
    ]
;;

let status ex ~recent : Yojson.Safe.t =
  let halted =
    List.filter_map (Exchange.instruments ex) ~f:(fun (i : Exchange_core.Instrument.t) ->
      Exchange.halt_status ex i.symbol
      |> Option.map ~f:(fun status ->
        `Assoc
          [ "coin", `String (Exchange_core.Symbol.to_string i.symbol)
          ; (match status with
             | `Until ns -> "until_ms", `Int (ns_to_ms ns)
             | `Until_reopen -> "until", `String "reopen"
             | `Reopen_pending -> "until", `String "reopen_pending")
          ]))
  in
  `Assoc
    [ "collar", Option.value_map (collar_of_exchange ex) ~default:`Null ~f:collar_json
    ; "halt_rule", Option.value_map (Exchange.halt_rule ex) ~default:`Null ~f:halt_rule_json
    ; "halted", `List halted
    ; "stats", stats_json (Exchange.guard_stats ex)
    ; "recent", `List (List.map recent ~f:event_json)
    ]
;;

let collar_rejected_during ex ~f =
  let before = (Exchange.guard_stats ex).collar_rejected in
  let result = f () in
  result, (Exchange.guard_stats ex).collar_rejected > before
;;

let percent_string pct = Float.to_string_hum ~decimals:2 ~strip_zero:true pct

let collar_percent ex coin ~side =
  match Exchange.collar ex coin with
  | None -> "?"
  | Some { band = Bps n; _ } -> percent_string (Float.of_int n /. 100.)
  | Some ({ band = Ticks _; _ } as config) ->
    (match Exchange.instrument ex coin, Exchange.collar_reference ex coin with
     | Some instrument, Some reference ->
       let bound = Price_collar.bound config instrument ~reference ~side in
       let reference = Price.to_float reference in
       percent_string
         (Float.abs (Price.to_float bound -. reference) /. reference *. 100.)
     | _ -> "?")
;;

let is_halt_rejection : Exchange_core.Reject_reason.t -> bool = function
  | Unsupported "trading halted" -> true
  | _ -> false
;;
