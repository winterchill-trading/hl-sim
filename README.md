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
| `-oracle-interval-ms` | 3000 | the market simulation publishes its reference as the oracle price this often and the mark follows Hyperliquid's median of oracle and book (see [Hyperliquid specifics](#hyperliquid-specifics)); 0 makes the reference the mark itself |
| `-initial-balance` | 1000000 | USD credited to any address on first use |
| `-response-delay-ms` | 0 | delay every `/exchange` response; the order takes effect, and its websocket events go out, at once |
| `-journal` | none | append every accepted `/exchange` request to this file (JSON lines) |
| `-input-journal` | none | write every engine input (requests, noise traders, anchors) to this binary journal |
| `-anchor` | none | `VENUE:SYMBOL=COIN`, repeatable: the coin follows that reference (see [Price anchor](#price-anchor)) |
| `-anchor-raw`, `-anchor-norm` | live | replay the reference from recorded raw minute files or event logs under a directory |
| `-anchor-from`, `-anchor-to` | | the recorded range: ISO 8601 times with a zone, or dates (`-anchor-to` exclusive; a date means its whole day) |
| `-anchor-speed` | 1 | pace of a recorded reference: 1 real time, 0 as fast as possible |
| `-anchor-base-url` | mainnet | API root of a live reference venue |
| `-anchor-levels` | 5 | reference levels per side resting in the book |
| `-anchor-mark-interval-ms` | 100 | minimum time between two anchored mark updates |
| `-anchor-max-staleness-ms` | 5000 | a silent reference goes stale after this long |
| `-anchor-noise` | 0 | noise traders kept on anchored coins |
| `-anchor-price-factor`, `-anchor-size-factor` | 1 | scale reference prices and sizes |
| `-anchor-status-interval-s` | 10 | log each anchor's status this often (0: never) |
| `-l2-interval-ms` | 500 | minimum time between two `l2Book` pushes |
| `-taker-fee-bps`, `-maker-fee-bps` | 4.5, 1.5 | trading fees (Hyperliquid's base perps tier) |
| `-leaders` | 0 | leader accounts for copy trading (see [Copy trading](#copy-trading)) |
| `-leaders-seed` | `-seed` | seed of the leaders' parameters |
| `-leader-balance` | 100000 | USD deposited into each leader |
| `-leader-edge-s` | 60 | trend and mean-reversion leaders see the reference this far ahead (see [Copy trading](#copy-trading)) |
| `-strict-signatures` | off | every `/exchange` request must be signed; `X-Address` is ignored |
| `-mainnet-signatures` | off | with `-strict-signatures`, check the mainnet L1 signing domain |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |

Logs go to stderr: fills and liquidations at `info`, every event, request detail and
websocket (un)subscription at `debug`.

The universe is BTC, ETH and SOL (asset indices 0, 1, 2; see `{"type": "meta"}`).

### Addresses and balances

The acting address of a `POST /exchange` request is, in order:

1. for `approveAgent` and `approveBuilderFee`, the address that signed them (EIP-712);
2. for an order, cancel or modify signed by an approved agent, the agent's account;
3. the `X-Address` header,
4. the request's `vaultAddress`,
5. `0x0000000000000000000000000000000000000001`.

Other signatures are not verified unless `-strict-signatures` is set (see
[Copy trading](#copy-trading)).

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

Also served: `metaAndAssetCtxs` (each coin's context as on `activeAssetCtx`), `orderStatus`,
`userRole` (`agent` for an approved agent, `user` for an address the simulator has
credited, else `missing`), and `maxBuilderFee`, `extraAgents`, `userFillsByTime` and
`leaderboard` (see [Copy trading](#copy-trading)).

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

Supported actions: `order` (with an optional `builder` code), `cancel`,
`cancelByCloid`, `modify`, `approveAgent`, `approveBuilderFee`. Malformed bodies get
status 400 and `{"error": "..."}`.

### Journal and replay

With `-journal FILE` every `/exchange` request that decodes is appended to `FILE`, one
JSON object per line, before it is applied:

```json
{"time":1700000000000000000,"address":"0x...","request":{"action":{...},"nonce":1}}
{"time":1700000000000000000,"address":"0x...","request":{...},"builder":{"b":"0x...","f":10}}
{"time":1700000000000000000,"address":"0x...","userAction":{"type":"approveAgent",...},"signature":{...}}
```

`time` is the exchange clock in nanoseconds and `address` the account that acted (for an
agent-signed order, the agent's account), so replay needs no signatures. `Journal.load` reads the file back and
`Server.replay` applies the entries to a fresh exchange, stepping the clock to each
entry's time, which reproduces the original responses, fills and account state as long
as nothing else traded (run with `-noise-traders 0`).

`-input-journal FILE` records one level lower: every input the engine performs (client
requests, noise traders, price anchors), in `exchange-core`'s binary `Journal` format.
`Exchange_core_engine.Journal.replay` with the exchange's configuration
(`Adapt.config ()`) rebuilds the whole run, anchored or not, without the reference data.
The file is flushed every second and on shutdown.

### Price anchor

`-anchor VENUE:SYMBOL=COIN` ties a simulated coin to a reference market through the
[price-anchor](https://github.com/winterchill-trading/price-anchor) library: the mark
and funding follow the reference, its top `-anchor-levels` levels per side rest in the
book (account `anchor:<venue>:<symbol>`), and resting client orders fill when the
reference trades at or through them (IOCs from `anchor-taker:<venue>:<symbol>`). Anchored
coins have no noise traders unless `-anchor-noise N`. The reference can be any venue
whose client is linked in, Hyperliquid or Binance for now, so BTC here can follow
Binance's BTCUSDT.

```sh
# Live, read-only (no keys): BTC follows Hyperliquid mainnet, ETH follows Binance
dune exec hl-sim -- -anchor hyperliquid:BTC -anchor binance:ETHUSDT=ETH

# A recorded minute (market-recorder raw files), in real time
dune exec hl-sim -- -anchor hyperliquid:BTC -anchor-raw test/fixtures \
  -anchor-from 2026-10-12T13:35:00Z -anchor-to 2026-10-12T13:36:00Z

# Normalized event logs for a day, as fast as possible, journaled for replay
dune exec hl-sim -- -anchor binance:BTCUSDT=BTC -anchor-norm /data/norm \
  -anchor-from 2026-10-01 -anchor-to 2026-10-01 -anchor-speed 0 -input-journal run.bin
```

The anchor runs on the scheduler thread that owns the engine: it applies each reference
item as it arrives (paced by `-anchor-speed` for recorded data), its clock hook runs
after the server steps the exchange clock, and the resulting events go to websocket
subscribers at once. A recorded reference fixes `sim time = recv_ts + offset` from its
first event, so with `-anchor-speed 0` the exchange clock runs ahead of the wall clock.

The reference is stale until its first book, after a gap and after
`-anchor-max-staleness-ms` without events (also once a recorded range has ended); while
stale the shadow levels are withdrawn and trade replay stops. Transitions are logged:

```
Info (anchor hyperliquid:BTC=BTC("anchor: reference fresh"(reference hyperliquid:BTC)(was Waiting_for_book)(stale_for_ns 950598000)(now ...)))
```

`GET /status` lists every anchor (also logged every `-anchor-status-interval-s`):

```json
{"ws_connections":0,"ws_dropped":0,"anchors":[{"anchor":"hyperliquid:BTC=BTC","fresh":true,
 "stale_reason":null,"went_stale":1,"stale_seconds":3.2,"gaps":0,"events":60,"marks_set":4,
 "funding_rates_set":4,"reference_price":"82493","shadow_levels":10,"shadow_placed":40,
 "shadow_skipped":0,"shadow_consumed":0,"replay_fills":0,"replays_rejected":0}]}
```

`scripts/anchor-demo.sh [SECONDS]` runs the simulator anchored to the recorded minute in
`test/fixtures`, connects the market-maker (when checked out next to this repository)
once the book is up, and prints the reference price, the book's top and the maker's
quotes every second:

```
ref     82493 fresh  book     82492 / 82493      maker     82468 / 82518      shadows 10  replay fills 0
ref     82493 fresh  book     82478 / 82479      maker     82451 / 82503      shadows 10  replay fills 0
```

Notes:

- The reference price prefers the venue's mark (Hyperliquid `activeAssetCtx`, Binance
  `markPrice`) over the book mid, so between funding updates the mark can lag the book.
- Reference levels are rounded to the coin's tick (bids down, asks up), so several
  Binance ETHUSDT levels (0.01 tick) can share one simulated ETH level (0.1 tick).

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
{"method": "subscribe", "subscription": {"type": "webData2", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "subscribe", "subscription": {"type": "userEvents", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "ping"}
```

Every (un)subscribe is answered with a `subscriptionResponse` echo and `ping` with
`{"channel": "pong"}`. `l2Book` subscriptions get a snapshot immediately, then a new
snapshot after changes to that book: 50ms (one block) after a quiet spell, then at most
every 500ms (`-l2-interval-ms`), like Hyperliquid's per-block pushes at least 0.5 s apart. `userFills` starts with an
`isSnapshot: true` message; `allMids` starts with a snapshot and repeats every second.
`trades`, `orderUpdates` and `userFills` are pushed as events happen.

`activeAssetCtx` (perp context: `funding`, `markPx`, `oraclePx`, `midPx`, `impactPxs`,
`premium`, `openInterest`, day volumes, `prevDayPx`) is sent on subscribe and then with
every `allMids` broadcast, which is enough for `hl-client feed -streams funding`. The
engine has no separate oracle, so `oraclePx` equals `markPx` (the market simulation sets
the mark to its reference price); day volumes cover the current UTC day of the exchange
clock rather than a rolling 24 hours; `impactPxs` is the best bid and ask. A coin with no
price yet gets only the `subscriptionResponse`.

`webData2` (lite: `clearinghouseState`, `openOrders`, `serverTime`, `user`) is sent on
subscribe and then every second; `userEvents` pushes `{"fills": [...]}` on channel
`user` as the account trades (funding, liquidation and non-user-cancel events are not
sent). User subscriptions work for any address, as on Hyperliquid. One connection
follows at most 10 distinct users across `userFills`, `orderUpdates`, `webData2` and
`userEvents`; the next one is answered with
`{"channel": "error", "data": "Cannot track more than 10 total users."}` (Hyperliquid
documents the limit; the wording is the simulator's).

Each connection may have at most 10,000 messages waiting to be written
(`Config.max_ws_queue`). A subscriber that stops reading falls behind once its socket
buffers fill, and is then disconnected instead of being buffered without bound; other
clients are not slowed down.

### Copy trading

The simulator supports the whole flow a copy-trading platform needs, without touching
Hyperliquid.

**Agents.** A user approves an API wallet with `approveAgent`, signed by the user's own
key as EIP-712 typed data (`HyperliquidTransaction:ApproveAgent` in the
`HyperliquidSignTransaction` domain; the chain id is taken from `signatureChainId`).
Orders, cancels and modifies whose L1 signature recovers to that agent (testnet or
mainnet phantom-agent domain) then act for the user. As on Hyperliquid: one unnamed and
three named agents per account, a new unnamed agent (or a reused name) replaces the old
one, an agent signs for one account, an agent cannot sign approvals, and nonces are
tracked per signer (the 100 highest kept; a new nonce must be unused, above the smallest
kept, and within two days before and one day after the server clock). `extraAgents`
lists an account's agents.

**Builder fees.** `approveBuilderFee` (signed by the user) sets the most a builder may
charge, up to 1%; a rate of 0 revokes it, and an account approves at most 10 builders.
An `order` action with `"builder": {"b": "0x...", "f": 10}` (tenths of a basis point)
is refused unless the approval covers `f`, `f` is at most 100 (0.1%, the perps cap) and
the builder has $100 of account value. The fee (`notional * f / 100000`) is moved from
the user to the builder on every fill of those orders. `maxBuilderFee` returns the
approved cap.

**Following.** `userFills`, `orderUpdates`, `webData2` and `userEvents` work for any
address. `userFillsByTime` returns an account's fills oldest first, at most 2000, for
paging by time.

**Leaderboard.** `POST /info {"type": "leaderboard"}`, and `GET /leaderboard` (also
`/Mainnet/leaderboard` and `/Testnet/leaderboard`, the stats host's paths), return
`{"leaderboardRows": [...]}` with `ethAddress`, `accountValue`, `displayName`, `prize`
and `windowPerformances` (`pnl`, `roi`, `vlm` as strings for `day`, `week`, `month`,
`allTime`) for every funded account. PnL is the change in account value net of
deposits; windows roll and are resolved to one-minute samples of the exchange clock.

**Leaders.** `-leaders N` runs N accounts that trade with fixed strategies: leader `i`
is `0x1eade5` followed by `i` in hex, trades coin `i / 3` and follows trend
(moving-average crossover), mean reversion or random entries for `i mod 3`, with
leverage and averaging lengths drawn from `-leaders-seed`. Same flags, same leaders. They
need prices, so run them with the market simulation or an anchor. On the leaderboard
they are named `trend-0`, `mean-reversion-1`, ... and the noise traders `noise-<i>`.

**Leader edge.** On thin noise books, fees (4.5 bp taker) and slippage beat every plain
strategy, so the leaderboard would only have losers. `-leader-edge-s S` (default 60, 0
turns it off) lets the trend and mean-reversion leaders see the reference price S
seconds ahead of the market: hl-sim draws the reference walk itself that far in advance
(`Foresight`, same volatility as the market simulation, seeded by `-leaders-seed`) and
pins the market to its current point, so the noise traders quote around a price the
leaders already know. With the edge:

| Strategy | Signal | Expected result |
| --- | --- | --- |
| `trend` | long when the reference ahead is above the mid by its threshold (5 to 30 bp), short when below, holds its side in between | net positive |
| `mean-reversion` | short when the mid is above fair value (the reference ahead) by its threshold, long when below, flat in between | net positive, smaller |
| `random` | random long / flat / short switches, no signal | net negative: fees and slippage |

Without the edge, trend uses a moving-average crossover of the mid and mean reversion
its slow average. Anchored coins follow a real market and get no edge. Ten simulated
minutes with nine leaders and seed 1 (`test/test_leader_edge.ml`) rank them, in USD
after fees:

| Leader | With the edge | Without |
| --- | ---: | ---: |
| mean-reversion-7 | +4795 | -1792 |
| trend-0 | +4321 | +1490 |
| trend-6 | +4057 | -615 |
| mean-reversion-1 | +3286 | -1055 |
| trend-3 | +2008 | -87 |
| mean-reversion-4 | +1721 | -792 |
| random-5 | -77 | -466 |
| random-8 | -2775 | -1171 |
| random-2 | -2937 | -1510 |

The same seed gives the same ranking on every run. Across seeds 1 to 5 at least three of
the six trend and mean-reversion leaders end positive; a random leader occasionally
ends a short run slightly up.

```sh
dune exec hl-sim -- -port 3000 -leaders 9
curl -s localhost:3000/leaderboard
```

**Strict signatures.** With `-strict-signatures` every `/exchange` request must carry a
valid signature: L1 actions act for their signer (or the account of an approved agent)
recovered in the testnet domain (`-mainnet-signatures` for mainnet), and `X-Address` is
ignored. Without it, unsigned requests keep acting for `X-Address`, so existing clients
work unchanged.

The signature fixtures in `test/fixtures/user_signed.json` come from eth_account with
throwaway keys (`user_signed.py` regenerates them).

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
| `Journal` | JSON-lines journal of accepted `/exchange` requests and approvals, for replay |
| `Eip712` | EIP-712 digests of user-signed actions and signer recovery |
| `User_action` | `approveAgent` and `approveBuilderFee` (hl-protocol's `User_signed_action`) and their signers |
| `Builder` | builder codes: the order field, fee amount, `maxFeeRate` parsing |
| `Agents` | agents, per-signer nonces and builder approvals, with Hyperliquid's limits |
| `User_channels` | the `webData2` and `userEvents` websocket channels |
| `Rankings` | leaderboard rows from sampled account values, deposits and volume |
| `Leaders` | leader accounts with trend, mean-reversion and random strategies |
| `Foresight` | the leaders' edge: the market's reference walk drawn ahead of the market |
| `Anchoring` | price anchors: `-anchor` specs, the reference sources (live feed of the linked clients, raw files, event logs), the anchor wired to the server's clock and websocket, its status |
| `Server` | cohttp-async server for `/info`, `/exchange` and the `/ws` websocket (async_websocket); owns the engine and drives its market simulation |

## Hyperliquid specifics

These live in `Adapt`; everything else is the engine's behaviour.

- **Universe.** BTC (szDecimals 5, 40x), ETH (4, 25x), SOL (2, 20x), asset indices in
  that order. Each becomes an `Exchange_core.Instrument` with size step
  `10^-szDecimals`, price tick `10^-(6 - szDecimals)`, at most 5 significant figures
  (integers always allowed) and Hyperliquid's base perps fee tier (taker 4.5 bps, maker
  1.5 bps; `-taker-fee-bps` and `-maker-fee-bps` change it, and an input journal then
  replays with `Adapt.config ~fees ()`). The input journal records the self-trade policy
  in its header; replay it with `Journal.load_with_header` and `Journal.replay ~header`.
- **Timestamps** are reported in milliseconds (the engine counts nanoseconds).
- **Order statuses** follow Hyperliquid: `resting`, `filled` with total size and average
  price, or `error` with Hyperliquid's message and its ` asset=N` suffix where one exists.
  Unknown asset indices are rejected (`Asset N does not exist.`); a `modify` whose
  replacement names one leaves the target untouched.
- **Trigger orders** (`{"trigger": {"isMarket", "triggerPx", "tpsl"}}`) answer `resting`
  with their oid and wait off the book, holding no margin, until the mark price reaches
  `triggerPx`: a sell stop-loss or a buy take-profit at or below it, a buy stop-loss or a
  sell take-profit at or above it. They then become a GTC limit order at `limitPx`, or
  with `isMarket` a market order with Hyperliquid's 10% slippage tolerance (measured from
  the best opposite price), under the same oid and with every check done then.
  `orderUpdates` reports `open`, then `triggered` followed by the placed order's own
  updates; `openOrders` lists waiting trigger orders, `orderStatus` gives their
  `orderType` (`Stop Market`, `Take Profit Limit`, ...), `triggerPx` and
  `triggerCondition`; cancel, cancel by cloid, modify, scheduled cancels and liquidation
  reach them. `normalTpsl` and `positionTpsl` grouping is not modelled.
- **Fills** carry Hyperliquid's `dir` labels (`Open Long`, `Close Short`,
  `Long > Short`, ...), `feeToken` `USDC` and a placeholder hash derived from the trade
  id. A self-trade cancel is reported as `selfTradeCanceled` and a liquidation cancel as
  `liquidatedCanceled` in `orderUpdates`.
- **Self-trade prevention** is Hyperliquid's: an order that reaches the same account's
  resting order cancels the resting one (`selfTradeCanceled` in `orderUpdates`, no fill,
  no fee, nothing in `trades`) and keeps matching behind it, so it may still fill, rest
  or be IOC-cancelled. It is never rejected for self-trade
  (`Adapt.self_trade = Expire_maker`).
- **Market orders** use 5% slippage, as Hyperliquid's SDKs send them.
- **Oracle, mark and funding.** With the market simulation, the reference walk is the
  oracle price, published every 3 s (`-oracle-interval-ms`); the engine derives the mark
  as Hyperliquid's median of the oracle plus the 150 s average premium of the mid, the
  median of best bid, best ask and last trade, and its 30 s average. Funding then follows
  the premium of the impact prices (20,000 USDC for BTC and ETH, 6,000 for SOL) over the
  oracle, sampled every 5 s: `P + clamp (0.01% - P, ±0.05%)` per 8 hours, paid hourly
  on `size * oracle`. `activeAssetCtx` and `metaAndAssetCtxs` report `oraclePx`,
  `markPx`, `premium` (latest sample), `funding` (the rate the next hour would pay) and
  the impact prices. Anchored coins without the simulation keep their anchor's mark and
  funding rate.

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
Copy-trading tests: EIP-712 digests and signers against eth_account vectors, agent and
builder limits, an agent-signed session with a builder fee replayed from the JSON
journal, following a leader over the websocket, leaderboard windows, reproducible
leaders, the leader edge's ranking over ten simulated minutes, and a run with leaders, approvals and builder fees replayed bit for bit from
the engine journal.
Anchor tests: a simulator anchored live to another one serving as the reference, and an
anchored run over the recorded minute in `test/fixtures` (copied from hl-client) whose
engine journal replays to the same book, marks and client fills.
