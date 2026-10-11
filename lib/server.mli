(** HTTP and websocket front end for {!Exchange}, speaking Hyperliquid's public API on a
    single port:

    - [POST /info]: an {!Hl_protocol.Info_request.t}, answered with the
      {!Hl_protocol.Info_response.t} JSON ([null] for an unknown coin). [nSigFigs] and
      [mantissa] are ignored.
    - [POST /exchange]: an {!Hl_protocol.Exchange_request.t}, answered with an
      {!Hl_protocol.Exchange_response.t}. Signatures are not verified. The acting address
      is the [X-Address] header if present, else the request's [vaultAddress], else
      [Config.default_address].
    - [GET /ws] with [Upgrade: websocket]: Hyperliquid's websocket protocol
      ({!Hl_protocol.Ws_request.t} in, {!Hl_protocol.Ws_message.t} out).

    Malformed requests get status 400 and [{"error": "..."}].

    Every address the server sees (as an acting address, an info [user] or a websocket
    [user] subscription) is credited [Config.initial_balance] the first time, so clients
    can trade without a deposit flow.

    The exchange is owned by the server and mutated only from the Async scheduler thread;
    every mutation goes through {!mutate}, which advances the exchange clock and then
    publishes the resulting events to websocket subscribers. *)

open! Core
open! Async
open! Hl_protocol

module Config : sig
  type t =
    { initial_balance : Usd.t (** credited to each address on first use *)
    ; default_address : Address.t (** acting address when none is given *)
    ; l2_book_interval : Time_ns.Span.t
    (** minimum spacing of [l2Book] updates per coin (coalescing) *)
    ; all_mids_interval : Time_ns.Span.t (** period of [allMids] broadcasts *)
    ; step_interval : Time_ns.Span.t
    (** period of the clock step that charges funding and liquidates *)
    }
  [@@deriving sexp_of]

  (** $1,000,000, address [0x0000000000000000000000000000000000000001], 50ms, 1s, 1s. *)
  val default : t
end

type t

(** [now] returns the current time in nanoseconds since the epoch (default: the wall
    clock). The exchange is stepped to [now ()] before each request. Tests pass a constant
    to make timestamps deterministic. *)
val create : ?config:Config.t -> ?now:(unit -> int) -> Exchange.t -> t

val config : t -> Config.t

(** Credits [initial_balance] to [address] unless it has been seen before. *)
val ensure_account : t -> Address.t -> unit

(** Steps the exchange clock, runs [f] on the exchange, then logs and publishes the events
    it produced. *)
val mutate : t -> f:(Exchange.t -> 'a) -> 'a

(** {2 Request handlers}
    (exposed for tests; the HTTP server calls these) *)

val handle_info : t -> Info_request.t -> Yojson.Safe.t
val handle_exchange : t -> Address.t -> Exchange_request.t -> Exchange_response.t

(** {2 Network} *)

(** Starts the HTTP/websocket server; [port] 0 picks a free port (see {!port}). Does not
    start the periodic tasks. *)
val listen
  :  t
  -> port:int
  -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t

(** The port the server is bound to. *)
val port : (Socket.Address.Inet.t, int) Cohttp_async.Server.t -> int

(** Starts the periodic tasks: [allMids] broadcasts and clock steps. *)
val start_periodic : t -> unit

(** Number of open websocket connections. *)
val num_ws_connections : t -> int
