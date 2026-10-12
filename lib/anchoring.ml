open! Core
open! Async
open! Hl_protocol
module Anchor = Price_anchor.Anchor
module Source = Price_anchor.Source

module Spec = struct
  type t =
    { reference : Market_data.Instrument.t
    ; sim_symbol : Coin.t
    }
  [@@deriving sexp_of, equal]

  let of_string s =
    let reference, sim_symbol =
      match String.lsplit2 s ~on:'=' with
      | Some (reference, coin) -> reference, Some coin
      | None -> s, None
    in
    let reference = Market_data.Instrument.of_string (String.strip reference) in
    let sim_symbol =
      match sim_symbol with
      | Some coin -> Coin.of_string (String.strip coin)
      | None -> Coin.of_string (Market_data.Symbol.to_string reference.symbol)
    in
    { reference; sim_symbol }
  ;;

  let to_string { reference; sim_symbol } =
    sprintf
      "%s=%s"
      (Market_data.Instrument.to_string reference)
      (Coin.to_string sim_symbol)
  ;;

  let arg_type = Command.Arg_type.create of_string
end

module Config = struct
  type t =
    { levels : int
    ; mark_interval : Time_ns.Span.t
    ; max_staleness : Time_ns.Span.t
    ; noise_traders : int
    ; price_factor : float
    ; size_factor : float
    }
  [@@deriving sexp_of]

  let default =
    { levels = 5
    ; mark_interval = Time_ns.Span.of_int_ms 100
    ; max_staleness = Time_ns.Span.of_sec 5.
    ; noise_traders = 0
    ; price_factor = 1.
    ; size_factor = 1.
    }
  ;;
end

let supported_venues : Market_data.Venue.t list = [ Hyperliquid; Binance ]

let unsupported venue =
  Or_error.error_s
    [%message
      "no client for this reference venue"
        (venue : Market_data.Venue.t)
        (supported_venues : Market_data.Venue.t list)]
;;

let normalizer (venue : Market_data.Venue.t) : Market_data.Normalizer.t Or_error.t =
  match venue with
  | Hyperliquid -> Ok (module Hl_client.Raw_normalizer)
  | Binance -> Ok (module Binance_client.Raw_normalizer)
  | venue -> unsupported venue
;;

let streams : Market_data.Stream.t list = [ Trades; L2; Funding ]
let symbol (spec : Spec.t) = Market_data.Symbol.to_string spec.reference.symbol

(* Closing the source (from the reader's side) closes the feed and its connections. *)
let source_of_feed ((module F : Market_data.Feed.S) as feed) =
  let source = Source.of_feed feed in
  upon (Pipe.closed source) (fun () -> don't_wait_for (F.close ()));
  source
;;

let live_source ?base_url (spec : Spec.t) =
  match spec.reference.venue with
  | Hyperliquid ->
    let config =
      match base_url with
      | Some base_url -> Hl_client.Config.create ~base_url ()
      | None -> Hl_client.Config.mainnet ()
    in
    Monitor.try_with_or_error (fun () ->
      Hl_client.Live_feed.create config ~symbols:[ symbol spec ] ~streams)
    >>|? source_of_feed
  | Binance ->
    let config =
      match base_url with
      | Some base_url -> Binance_client.Config.Read_only.create ~base_url ()
      | None -> Binance_client.Config.Read_only.mainnet ()
    in
    Monitor.try_with_or_error (fun () ->
      Binance_client.Live_feed.create config ~symbols:[ symbol spec ] ~streams)
    >>|? source_of_feed
  | venue -> return (unsupported venue)
;;

let raw_source ?on_error ~dir ~from ~to_ (spec : Spec.t) =
  let%map.Or_error normalizer = normalizer spec.reference.venue in
  Source.of_raw ?on_error ~dir ~symbol:(symbol spec) ~from ~to_ ~normalizer ()
;;

let norm_source ~dir ~from ~to_ (spec : Spec.t) =
  Source.of_norm ~dir spec.reference ~from ~to_
;;

type t =
  { spec : Spec.t
  ; anchor : Anchor.t
  ; server : Server.t
  }

let spec t = t.spec
let anchor t = t.anchor

let create ?(config = Config.default) ?market_sim ?log server (spec : Spec.t) =
  let log =
    match log with
    | Some log -> log
    | None ->
      let tag = Spec.to_string spec in
      fun sexp -> Log.Global.info_s [%message "anchor" tag ~_:(sexp : Sexp.t)]
  in
  let anchor =
    Server.mutate server ~f:(fun exchange ->
      Anchor.create
        ~price_factor:config.price_factor
        ~size_factor:config.size_factor
        ~levels:config.levels
        ~mark_interval:config.mark_interval
        ~max_staleness:config.max_staleness
        ~noise_traders:config.noise_traders
        ~log
        ?market_sim
        ~exchange
        ~reference:spec.reference
        ~sim_symbol:spec.sim_symbol
        ())
  in
  Server.on_clock_step server (fun ~now -> Anchor.step anchor ~now);
  { spec; anchor; server }
;;

let run ?speed ?time_source t source =
  Source.run ?speed ?time_source source ~anchor:t.anchor ~on_item:(fun _ ->
    Server.publish_events t.server)
;;
