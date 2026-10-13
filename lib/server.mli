(** HTTP and websocket front end for the venue-neutral engine
    ({!Exchange_core_engine.Exchange}, translated by {!Adapt}), speaking Hyperliquid's
    public API on a single port:

    - [POST /info]: an {!Hl_protocol.Info_request.t}, answered with the
      {!Hl_protocol.Info_response.t} JSON ([null] for an unknown coin). [nSigFigs] and
      [mantissa] are ignored. Also [maxBuilderFee] (the approved cap in tenths of a bp),
      [extraAgents] (the account's agents), [userFillsByTime] (oldest first, at most 2000)
      and [leaderboard] ({!Rankings}).
    - [GET /leaderboard] (also [/Mainnet/leaderboard] and [/Testnet/leaderboard], the
      stats host's paths): the same leaderboard.
    - [POST /exchange]: an {!Hl_protocol.Exchange_request.t} or a {!User_action.t},
      answered with an {!Hl_protocol.Exchange_response.t}; see "Who acts" below.
    - [GET /ws] with [Upgrade: websocket]: Hyperliquid's websocket protocol
      ({!Hl_protocol.Ws_request.t} in, {!Hl_protocol.Ws_message.t} out), plus the
      [activeAssetCtx] channel ({!Active_asset_ctx}), sent on subscribe and with every
      [allMids] broadcast. The [webData2] and [userEvents] channels ({!User_channels}) and
      the [userFills] and [orderUpdates] subscriptions work for any address; one
      connection may follow at most [Config.max_ws_users] distinct users across them (the
      next subscription gets an [error] message).
    - [GET /status]: {!status}.

    Malformed requests get status 400 and [{"error": "..."}].

    {2 Who acts}

    - [approveAgent] and [approveBuilderFee] act for the address that signed them
      (EIP-712, {!User_action.signer}); an agent's signature is refused, and the signer's
      nonce is checked ({!Agents.use_nonce}). Unsigned, they act for the [X-Address]
      header (or [Config.default_address]).
    - An order, cancel or modify whose L1 signature recovers (testnet or mainnet domain)
      to an approved agent acts for the agent's account; the agent's nonce is checked.
    - Anything else acts for the [X-Address] header if present, else the request's
      [vaultAddress], else [Config.default_address]; its signature is not checked.

    With [Config.strict_signatures], every request must be signed: an L1 action acts for
    its signer (or the signer's account if it is an agent), recovered in the
    [Config.is_mainnet] domain, and [X-Address] is ignored.

    An order action's [builder] code ({!Builder}) must be approved by the account, at most
    0.1%, for a builder with at least $100 of account value (a builder is credited the
    initial balance when first named, like any address, so only a builder that lost it is
    refused); its fee is charged on every fill of those orders.

    {2 Accounts and threading}

    Every address the server sees (as an acting address, a builder, an info [user] or a
    websocket [user] subscription) is credited [Config.initial_balance] the first time, so
    clients can trade without a deposit flow.

    The exchange is owned by the server and mutated only from the Async scheduler thread;
    every mutation goes through {!mutate}, which advances the exchange clock and then
    publishes the resulting events to websocket subscribers. *)

open! Core
open! Async
open! Hl_protocol
module Exchange := Exchange_core_engine.Exchange

module Config : sig
  type t =
    { initial_balance : Usd.t (** credited to each address on first use *)
    ; default_address : Address.t (** acting address when none is given *)
    ; l2_book_interval : Time_ns.Span.t
    (** minimum spacing of [l2Book] updates per coin (coalescing) *)
    ; all_mids_interval : Time_ns.Span.t (** period of [allMids] broadcasts *)
    ; step_interval : Time_ns.Span.t
    (** period of the clock step that charges funding and liquidates *)
    ; response_delay : Time_ns.Span.t
    (** delay of every [POST /exchange] response; the request takes effect (and its
        websocket events go out) at once, only the ack is late *)
    ; max_ws_queue : int
    (** messages a websocket subscriber may have waiting to be sent; a subscriber that
        falls further behind (stops reading) is disconnected *)
    ; strict_signatures : bool
    (** require and verify a signature on every [POST /exchange] *)
    ; is_mainnet : bool (** the L1 signing domain checked in strict mode *)
    ; max_ws_users : int
    (** distinct users one websocket connection may follow through user subscriptions *)
    }
  [@@deriving sexp_of]

  (** $1,000,000, address [0x0000000000000000000000000000000000000001], 50ms, 1s, 1s, no
      response delay, 10,000 queued websocket messages, signatures not required, testnet
      domain, 10 users per websocket connection. *)
  val default : t
end

type t

(** [now] returns the current time in nanoseconds since the epoch (default: the wall
    clock). The exchange is stepped to [now ()] before each request. Tests pass a constant
    to make timestamps deterministic. Every request accepted by {!handle_exchange} is
    appended to [journal], if given. *)
val create
  :  ?config:Config.t
  -> ?now:(unit -> int)
  -> ?journal:Journal.t
  -> Exchange.t
  -> t

val config : t -> Config.t

(** Agent and builder approvals. *)
val agents : t -> Agents.t

(** Credits [initial_balance] to [address] unless it has been seen before. *)
val ensure_account : t -> Address.t -> unit

(** Steps the exchange clock, runs [f] on the exchange, then logs and publishes the events
    it produced. *)
val mutate : t -> f:(Exchange.t -> 'a) -> 'a

(** [on_clock_step t f] calls [f ~now] every time {!mutate} (and the periodic clock step)
    has brought the exchange clock up to date, before the mutation itself; [now] is the
    exchange clock, which may be ahead of [now ()] when something else (a price anchor
    replaying recorded data) stepped it. Hooks run in the order they were added. *)
val on_clock_step : t -> (now:int -> unit) -> unit

(** [add_status t ~name f] adds [name: f ()] to {!status}. *)
val add_status : t -> name:string -> (unit -> Yojson.Safe.t) -> unit

(** [{"ws_connections": n, "ws_dropped": n, ...}] and the entries of {!add_status}, in the
    order they were added; served on [GET /status]. *)
val status : t -> Yojson.Safe.t

(** Logs and publishes the events the exchange produced outside {!mutate} (for example by
    a price anchor acting on it directly). *)
val publish_events : t -> unit

(** {2 Request handlers}
    (exposed for tests; the HTTP server calls these) *)

val handle_info : t -> Info_request.t -> Yojson.Safe.t

(** A [POST /info] body, including the requests {!Hl_protocol.Info_request} does not
    model. Raises on a body that does not decode. *)
val handle_info_json : t -> Yojson.Safe.t -> Yojson.Safe.t

(** [{"leaderboardRows": [...]}] for every funded account ({!Rankings}). *)
val leaderboard : t -> Yojson.Safe.t

(** Applies an exchange request for [address], already authenticated. [builder] is the
    order action's builder code. *)
val handle_exchange
  :  ?builder:Builder.t
  -> t
  -> Address.t
  -> Exchange_request.t
  -> Exchange_response.t

(** Applies a user-signed action for [address], already authenticated; [signature] is only
    journaled. *)
val handle_user_action
  :  ?signature:Yojson.Safe.t
  -> t
  -> Address.t
  -> User_action.t
  -> Exchange_response.t

(** A [POST /exchange] body: authenticates it (see above; [x_address] is the header) and
    applies it. Raises on a body that does not decode. *)
val handle_exchange_json
  :  t
  -> x_address:Address.t option
  -> Yojson.Safe.t
  -> Exchange_response.t

(** Applies journaled records, in order, to a server over [exchange] (normally fresh from
    {!Adapt.create_exchange}), stepping the clock to each record's [time] first. Returns
    the server, whose clock stays at the last record's time, and the responses. *)
val replay
  :  ?config:Config.t
  -> Exchange.t
  -> Journal.Record.t list
  -> t * Exchange_response.t list

(** {2 Network} *)

(** Starts the HTTP/websocket server; [port] 0 picks a free port (see {!port}). Does not
    start the periodic tasks. *)
val listen
  :  t
  -> port:int
  -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t

(** The port the server is bound to. *)
val port : (Socket.Address.Inet.t, int) Cohttp_async.Server.t -> int

(** Starts the periodic tasks: [allMids], [activeAssetCtx] and [webData2] broadcasts and
    clock steps. *)
val start_periodic : t -> unit

(** Calls {!Exchange_core_engine.Market_sim.tick} every [tick_interval] through {!mutate},
    so the resulting events reach websocket subscribers. The noise traders are named
    ["noise-<i>"] on the leaderboard and are not credited the initial balance. *)
val run_market_sim : t -> Exchange_core_engine.Market_sim.t -> unit

(** Calls {!Leaders.tick} every [decision_interval] through {!mutate}, and names the
    leaders on the leaderboard (they are not credited the initial balance). Create the
    leaders after the server, so that their deposits are not counted as PnL. *)
val run_leaders : t -> Leaders.t -> unit

(** Number of open websocket connections. *)
val num_ws_connections : t -> int

(** Number of websocket connections dropped for falling behind ({!Config.t.max_ws_queue}). *)
val num_ws_dropped : t -> int
