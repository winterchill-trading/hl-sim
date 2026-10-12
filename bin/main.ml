open! Core
open! Async
open! Hl_protocol
open! Hl_sim
module Market_sim = Exchange_core_engine.Market_sim

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
           let%map source =
             Anchoring.live_source
               ?base_url:(Option.map anchor_base_url ~f:Uri.of_string)
               spec
             >>| ok_exn
           in
           Log.Global.info_s
             [%message "anchored" ~anchor:(Anchoring.Spec.to_string spec) ~source:"live"];
           don't_wait_for
             (let%map () = Anchoring.run anchoring source in
              Log.Global.error_s
                [%message "anchor source closed" ~anchor:(Anchoring.Spec.to_string spec)]))
       in
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
