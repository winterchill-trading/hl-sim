open! Core
open! Async
open! Hl_protocol
open! Hl_sim

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
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let exchange = Exchange.create () in
       let server =
         Server.create
           ~config:
             { Server.Config.default with
               initial_balance = Usd.of_string initial_balance
             }
           exchange
       in
       let%bind http = Server.listen server ~port in
       Log.Global.info
         "hl-sim listening on port %d (POST /info, POST /exchange, GET /ws)"
         (Server.port http);
       Server.start_periodic server;
       if noise_traders > 0
       then (
         let sim =
           Market_sim.create
             { Market_sim.Config.default with
               seed
             ; vol_bps
             ; noise_traders
             ; coins = List.map (Option.value coins ~default:[]) ~f:Coin.of_string
             }
             exchange
         in
         Market_sim.start sim ~server);
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
