open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Market_sim = Exchange_core_engine.Market_sim

(* [-anchor-from]/[-anchor-to]: times with a zone, or dates (UTC days). *)
module Recorded_range = struct
  type t =
    { from : Time_ns.t
    ; to_ : Time_ns.t
    }

  let parse ~end_of_day s =
    match Date.of_string s with
    | date ->
      let date = if end_of_day then Date.add_days date 1 else date in
      Time_ns.of_date_ofday ~zone:Time_float.Zone.utc date Time_ns.Ofday.start_of_day
    | exception _ -> Time_ns.of_string_with_utc_offset s
  ;;

  let of_strings ~from ~to_ =
    let from = parse ~end_of_day:false from in
    let to_ = parse ~end_of_day:true to_ in
    if Time_ns.( >= ) from to_ then failwith "-anchor-from must be before -anchor-to";
    { from; to_ }
  ;;

  let day time = Time_ns.to_date time ~zone:Time_float.Zone.utc
  let first_day t = day t.from
  let last_day t = day (Time_ns.sub t.to_ (Time_ns.Span.of_int_ns 1))
end

let command =
  Command.async
    ~summary:"Hyperliquid exchange simulator"
    ~readme:(fun () ->
      "Serves POST /info, POST /exchange and the websocket API (GET /ws) on one port. \
       Signatures are not checked: the acting address is the X-Address header, else the \
       request's vaultAddress, else 0x0000000000000000000000000000000000000001. Every \
       address is credited -initial-balance USD on first use.")
    (let%map_open.Command port =
       flag "-port" (optional_with_default 3000 int) ~doc:"PORT HTTP and websocket port"
     and seed =
       flag "-seed" (optional_with_default 0 int) ~doc:"N market simulation random seed"
     and vol_bps =
       flag
         "-vol-bps"
         (optional_with_default Market_sim.Config.default.vol_bps float)
         ~doc:"BPS reference price volatility per second, in basis points"
     and coins =
       flag
         "-coins"
         (optional (Arg_type.comma_separated string))
         ~doc:"COIN,... coins the noise traders trade (default: all)"
     and noise_traders =
       flag
         "-noise-traders"
         (optional_with_default Market_sim.Config.default.noise_traders int)
         ~doc:"N number of noise trader accounts (0 disables the market simulation)"
     and initial_balance =
       flag
         "-initial-balance"
         (optional_with_default
            (Usd.to_string Server.Config.default.initial_balance)
            string)
         ~doc:"USD balance credited to any address on first use"
     and response_delay_ms =
       flag
         "-response-delay-ms"
         (optional_with_default 0 int)
         ~doc:"MS delay every /exchange response (the order still takes effect at once)"
     and journal =
       flag
         "-journal"
         (optional string)
         ~doc:"FILE append every accepted /exchange request to FILE (JSON lines)"
     and anchors =
       flag
         "-anchor"
         (listed Anchoring.Spec.arg_type)
         ~doc:
           "VENUE:SYMBOL=COIN follow a reference instrument (repeatable), e.g. \
            binance:BTCUSDT=BTC; live through the venue's public feed"
     and anchor_base_url =
       flag
         "-anchor-base-url"
         (optional string)
         ~doc:"URL API root of the live reference venue (default: its mainnet)"
     and anchor_raw =
       flag
         "-anchor-raw"
         (optional string)
         ~doc:
           "DIR replay the reference from recorded raw minute files under DIR (the \
            recorder's data directory) instead of the live feed"
     and anchor_norm =
       flag
         "-anchor-norm"
         (optional string)
         ~doc:"DIR replay the reference from normalized event logs under DIR"
     and anchor_from =
       flag
         "-anchor-from"
         (optional string)
         ~doc:"TIME start of a recorded reference (ISO 8601 time with zone, or a date)"
     and anchor_to =
       flag
         "-anchor-to"
         (optional string)
         ~doc:"TIME end of a recorded reference, exclusive (a date means its whole day)"
     and anchor_speed =
       flag
         "-anchor-speed"
         (optional_with_default 1. float)
         ~doc:
           "X pace of a recorded reference: 1 real time (default), 0 as fast as possible"
     and anchor_levels =
       flag
         "-anchor-levels"
         (optional_with_default Anchoring.Config.default.levels int)
         ~doc:"N reference levels per side resting in the book (default 5)"
     and anchor_mark_interval_ms =
       flag
         "-anchor-mark-interval-ms"
         (optional_with_default 100 int)
         ~doc:"MS minimum time between two anchored mark updates (default 100)"
     and anchor_max_staleness_ms =
       flag
         "-anchor-max-staleness-ms"
         (optional_with_default 5000 int)
         ~doc:"MS a silent reference goes stale after this long (default 5000)"
     and anchor_noise =
       flag
         "-anchor-noise"
         (optional_with_default 0 int)
         ~doc:"N noise traders kept on anchored coins (default 0)"
     and anchor_price_factor =
       flag
         "-anchor-price-factor"
         (optional_with_default 1. float)
         ~doc:"F multiply reference prices by F (default 1)"
     and anchor_size_factor =
       flag
         "-anchor-size-factor"
         (optional_with_default 1. float)
         ~doc:"F multiply reference sizes by F (default 1)"
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let exchange = Adapt.create_exchange () in
       let%bind journal =
         match journal with
         | None -> return None
         | Some path -> Journal.open_file path >>| Option.some
       in
       let server =
         Server.create
           ?journal
           ~config:
             { Server.Config.default with
               initial_balance = Usd.of_string initial_balance
             ; response_delay = Time_ns.Span.of_int_ms response_delay_ms
             }
           exchange
       in
       let%bind http = Server.listen server ~port in
       Log.Global.info
         "hl-sim listening on port %d (POST /info, POST /exchange, GET /ws)"
         (Server.port http);
       Server.start_periodic server;
       let coins = Option.map coins ~f:(List.map ~f:Coin.of_string) in
       let market_sim =
         if noise_traders > 0
         then (
           let sim =
             Market_sim.create
               { Market_sim.Config.default with
                 seed
               ; vol_bps
               ; noise_traders
               ; symbols = Option.value coins ~default:[]
               }
               exchange
           in
           Server.run_market_sim server sim;
           Some sim)
         else None
       in
       let anchor_config =
         { Anchoring.Config.levels = anchor_levels
         ; mark_interval = Time_ns.Span.of_int_ms anchor_mark_interval_ms
         ; max_staleness = Time_ns.Span.of_int_ms anchor_max_staleness_ms
         ; noise_traders = anchor_noise
         ; price_factor = anchor_price_factor
         ; size_factor = anchor_size_factor
         }
       in
       let source_name, speed, anchor_source =
         let range () =
           match anchor_from, anchor_to with
           | Some from, Some to_ -> Recorded_range.of_strings ~from ~to_
           | _ -> failwith "-anchor-raw and -anchor-norm need -anchor-from and -anchor-to"
         in
         match anchor_raw, anchor_norm with
         | Some _, Some _ -> failwith "-anchor-raw and -anchor-norm exclude each other"
         | Some dir, None ->
           let { Recorded_range.from; to_ } = range () in
           ( "raw"
           , anchor_speed
           , fun spec -> return (Anchoring.raw_source ~dir ~from ~to_ spec) )
         | None, Some dir ->
           let range = range () in
           ( "norm"
           , anchor_speed
           , Anchoring.norm_source
               ~dir
               ~from:(Recorded_range.first_day range)
               ~to_:(Recorded_range.last_day range) )
         | None, None ->
           ( "live"
           , 0.
           , Anchoring.live_source ?base_url:(Option.map anchor_base_url ~f:Uri.of_string)
           )
       in
       let%bind () =
         Deferred.List.iter ~how:`Sequential anchors ~f:(fun spec ->
           (* Only coins the market simulation trades have noise traders to adjust. *)
           let market_sim =
             Option.filter market_sim ~f:(fun _ ->
               match coins with
               | None -> true
               | Some coins -> List.mem coins spec.sim_symbol ~equal:Coin.equal)
           in
           let anchoring =
             Anchoring.create ~config:anchor_config ?market_sim server spec
           in
           let%map source = anchor_source spec >>| ok_exn in
           Log.Global.info_s
             [%message
               "anchored"
                 ~anchor:(Anchoring.Spec.to_string spec)
                 ~source:(source_name : string)];
           don't_wait_for
             (let%map () = Anchoring.run ~speed anchoring source in
              Log.Global.error_s
                [%message "anchor source closed" ~anchor:(Anchoring.Spec.to_string spec)]))
       in
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
