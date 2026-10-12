# hl-sim

Hyperliquid exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
hl-sim is a Hyperliquid adapter over the venue-neutral engine in
[exchange-core](https://github.com/winterchill-trading/exchange-core)
(`exchange-core-engine`: matching, clearinghouse, margin, funding, liquidation and
synthetic order flow). Requests and responses use the wire types from
[hl-protocol](https://github.com/winterchill-trading/hl-protocol).

The package has `Adapt`, which maps Hyperliquid's universe, asset indices, requests,
responses, error messages and websocket payloads onto the engine, an HTTP and websocket
server speaking Hyperliquid's public API (`Server`), and the `hl-sim` executable that
runs them together with the engine's market simulation.

## Running

```sh
dune exec hl-sim -- -port 3000
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-port` | 3000 | HTTP and websocket port |
| `-seed` | 0 | market simulation random seed |
| `-vol-bps` | 5 | reference price volatility per second, in basis points |
| `-coins` | all | comma-separated coins the noise traders trade |
| `-noise-traders` | 10 | noise trader accounts; 0 disables the market simulation |
| `-initial-balance` | 1000000 | USD credited to any address on first use |
| `-response-delay-ms` | 0 | delay every `/exchange` response; the order takes effect, and its websocket events go out, at once |
| `-journal` | none | append every accepted `/exchange` request to this file (JSON lines) |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |

Logs go to stderr: fills and liquidations at `info`, every event, request detail and
websocket (un)subscription at `debug`.

The universe is BTC, ETH and SOL (asset indices 0, 1, 2; see `{"type": "meta"}`).

### Addresses and balances

Signatures are not verified. The acting address of a `POST /exchange` request is, in
order:

1. the `X-Address` header,
2. the request's `vaultAddress`,
3. `0x0000000000000000000000000000000000000001`.

Every address the server sees (acting address, info `user`, websocket `user`) is
credited `-initial-balance` USD the first time, so a client can trade without a deposit
flow.

### Info

```sh
curl -s localhost:3000/info -d '{"type": "l2Book", "coin": "BTC"}'
curl -s localhost:3000/info -d '{"type": "allMids"}'
curl -s localhost:3000/info -d '{"type": "meta"}'
curl -s localhost:3000/info -d '{"type": "clearinghouseState", "user": "0x00000000000000000000000000000000000000aa"}'
curl -s localhost:3000/info -d '{"type": "openOrders", "user": "0x00000000000000000000000000000000000000aa"}'
curl -s localhost:3000/info -d '{"type": "userFills", "user": "0x00000000000000000000000000000000000000aa"}'
```

`nSigFigs` and `mantissa` are accepted but ignored. An unknown coin returns `null`.

### Exchange

```sh
# Rest a bid for 0.001 BTC at 99000
curl -s localhost:3000/exchange -H 'X-Address: 0x00000000000000000000000000000000000000aa' -d '{
  "action": {"type": "order", "grouping": "na",
             "orders": [{"a": 0, "b": true, "p": "99000", "s": "0.001", "r": false,
                         "t": {"limit": {"tif": "Gtc"}}}]},
  "nonce": 1}'

# Cancel it, with the oid from the "resting" status of the response above
curl -s localhost:3000/exchange -H 'X-Address: 0x00000000000000000000000000000000000000aa' -d '{
  "action": {"type": "cancel", "cancels": [{"a": 0, "o": 1}]}, "nonce": 2}'
```

Supported actions: `order`, `cancel`, `cancelByCloid`, `modify`. Malformed bodies get
status 400 and `{"error": "..."}`.

### Journal and replay

With `-journal FILE` every `/exchange` request that decodes is appended to `FILE`, one
JSON object per line, before it is applied:

```json
{"time":1700000000000000000,"address":"0x...","request":{"action":{...},"nonce":1}}
```

`time` is the exchange clock in nanoseconds. `Journal.load` reads the file back and
`Server.replay` applies the entries to a fresh exchange, stepping the clock to each
entry's time, which reproduces the original responses, fills and account state as long
as nothing else traded (run with `-noise-traders 0`).

### Websocket

The websocket is served on the same port at `/ws`:

```sh
websocat ws://localhost:3000/ws
{"method": "subscribe", "subscription": {"type": "l2Book", "coin": "BTC"}}
{"method": "subscribe", "subscription": {"type": "trades", "coin": "BTC"}}
{"method": "subscribe", "subscription": {"type": "orderUpdates", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "subscribe", "subscription": {"type": "userFills", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "subscribe", "subscription": {"type": "allMids"}}
{"method": "subscribe", "subscription": {"type": "activeAssetCtx", "coin": "BTC"}}
{"method": "ping"}
```

Every (un)subscribe is answered with a `subscriptionResponse` echo and `ping` with
`{"channel": "pong"}`. `l2Book` subscriptions get a snapshot immediately, then a new
snapshot after changes to that book, at most every 50ms. `userFills` starts with an
`isSnapshot: true` message; `allMids` starts with a snapshot and repeats every second.
`trades`, `orderUpdates` and `userFills` are pushed as events happen.

`activeAssetCtx` (perp context: `funding`, `markPx`, `oraclePx`, `midPx`, `impactPxs`,
`premium`, `openInterest`, day volumes, `prevDayPx`) is sent on subscribe and then with
every `allMids` broadcast, which is enough for `hl-client feed -streams funding`. The
engine has no separate oracle, so `oraclePx` equals `markPx` (the market simulation sets
the mark to its reference price); day volumes cover the current UTC day of the exchange
clock rather than a rolling 24 hours; `impactPxs` is the best bid and ask. A coin with no
price yet gets only the `subscriptionResponse`.

Each connection may have at most 10,000 messages waiting to be written
(`Config.max_ws_queue`). A subscriber that stops reading falls behind once its socket
buffers fill, and is then disconnected instead of being buffered without bound; other
clients are not slowed down.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action
opam pin add hl-protocol https://github.com/winterchill-trading/hl-protocol.git --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git --no-action
opam pin add exchange-core-engine https://github.com/winterchill-trading/exchange-core.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `hl-protocol`, `fixed-decimal`,
`order-book` and `exchange-core`, dune uses the sibling sources and the pins are not
needed.

### CI and the dune cache

CI time is dominated by building the opam dependencies (Core, Async, cohttp and the
rest from source, about 15 minutes); `dune build` and `dune test` of this repo take
about 15 seconds. Enabling setup-ocaml's dune cache was measured on 2026-10-12 and
dropped again:

| Run | Compiler setup | `opam install --deps-only` | Total |
| --- | --- | --- | --- |
| before (no dune cache, two runs) | 36-43s | 948-954s | 17 min |
| `dune-cache: true`, cold | 144s | 881s | 19 min |
| `dune-cache: true`, cache restored | 146s | 855s | 17 min |
| also `opam-disable-sandboxing: true`, cold | 1165s (new switch cache key) | 884s | 34 min |
| same, cache restored | 145s | 859s (failed on a download) | - |

The saved dune cache was 479 bytes: dependency builds run by opam do not store
anything in it, so the restored cache saves nothing, and setup itself gets about 100s
slower (it installs dune into the switch). The input is also deprecated in
setup-ocaml v3. The time worth saving is in the dependencies, which would need the
opam switch itself cached after `opam install` (keyed on the sibling pins' commits).

CI now does exactly that through the shared `ox-setup` action from the infra repo
(its `docs/ci.md` has the cache key rule): the first run took 34 minutes (compiler and
dependencies), a rerun with unchanged siblings 2 minutes.

## Modules

All modules live under `Hl_sim`. The engine (`Exchange`, `Clearinghouse`, `Position`,
`Event`, `Market_sim`, ...) is `Exchange_core_engine` from exchange-core; its design notes
(determinism, matching, margin, liquidation, funding, fixed point, market simulation)
are in the [exchange-core README](https://github.com/winterchill-trading/exchange-core).

| Module | Description |
| --- | --- |
| `Adapt` | Hyperliquid view of the engine: default universe, instruments with Hyperliquid's price and size rules, asset index mapping, the exchange and info endpoints in hl-protocol types, error wording, `User_fill` with `dir` labels, `Trade`, `Order_update`, `Clearinghouse_state` |
| `Active_asset_ctx` | the `activeAssetCtx` channel: payload from the engine, day volume stats, subscription requests (not in hl-protocol yet) |
| `Journal` | JSON-lines journal of accepted `/exchange` requests, for replay |
| `Server` | cohttp-async server for `/info`, `/exchange` and the `/ws` websocket (async_websocket); owns the engine and drives its market simulation |

## Hyperliquid specifics

These live in `Adapt`; everything else is the engine's behaviour.

- **Universe.** BTC (szDecimals 5, 40x), ETH (4, 25x), SOL (2, 20x), asset indices in
  that order. Each becomes an `Exchange_core.Instrument` with size step
  `10^-szDecimals`, price tick `10^-(6 - szDecimals)`, at most 5 significant figures
  (integers always allowed) and the base fee tier (taker 3.5 bps, maker 1 bp).
- **Timestamps** are reported in milliseconds (the engine counts nanoseconds).
- **Order statuses** follow Hyperliquid: `resting`, `filled` with total size and average
  price, or `error` with Hyperliquid's message and its ` asset=N` suffix where one exists.
  Trigger orders are rejected (`Trigger orders are not supported.`), as are unknown asset
  indices (`Asset N does not exist.`). A `modify` whose replacement is rejected by these
  two checks leaves the target untouched.
- **Fills** carry Hyperliquid's `dir` labels (`Open Long`, `Close Short`,
  `Long > Short`, ...), `feeToken` `USDC` and a placeholder hash derived from the trade
  id. A self-trade cancel is reported as `selfTradeCanceled` and a liquidation cancel as
  `marginCanceled` in `orderUpdates`.
- **Market orders** use 5% slippage, as Hyperliquid's SDKs send them.

### Server

All exchange access happens on the Async scheduler thread, so there is no locking.
Before each request the exchange clock is stepped to the wall clock (funding and
liquidation run then and on a 1s timer); events produced by a request are published to
websocket subscribers right after it. The websocket upgrade uses cohttp-async's
`` `Expert `` response, which hands the raw reader and writer to async_websocket after
writing the `101` response. The market simulation ticks every 100ms through the same
path.

## Tests

`dune test` runs expect tests of the Hyperliquid endpoints through `Adapt` (statuses,
error messages, fills, `clearinghouseState`, events), a seeded market simulation on the
Hyperliquid universe, and the HTTP and websocket server on a free port with a fixed
clock. Engine tests (clearinghouse, properties) live in exchange-core, order book tests
in order-book.
