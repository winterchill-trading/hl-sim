# hl-sim

Hyperliquid exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Requests and responses use the wire types from
[hl-protocol](https://github.com/winterchill-trading/hl-protocol). Matching is done by
[order-book](https://github.com/winterchill-trading/order-book), and fixed-point
arithmetic comes from [fixed-decimal](https://github.com/winterchill-trading/fixed-decimal).

The package has a pure matching and accounting engine (`Exchange`), an HTTP and
websocket server speaking Hyperliquid's public API (`Server`), a synthetic order flow
generator (`Market_sim`) and the `hl-sim` executable that runs them together.

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

### Websocket

The websocket is served on the same port at `/ws`:

```sh
websocat ws://localhost:3000/ws
{"method": "subscribe", "subscription": {"type": "l2Book", "coin": "BTC"}}
{"method": "subscribe", "subscription": {"type": "trades", "coin": "BTC"}}
{"method": "subscribe", "subscription": {"type": "orderUpdates", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "subscribe", "subscription": {"type": "userFills", "user": "0x00000000000000000000000000000000000000aa"}}
{"method": "subscribe", "subscription": {"type": "allMids"}}
{"method": "ping"}
```

Every (un)subscribe is answered with a `subscriptionResponse` echo and `ping` with
`{"channel": "pong"}`. `l2Book` subscriptions get a snapshot immediately, then a new
snapshot after changes to that book, at most every 50ms. `userFills` starts with an
`isSnapshot: true` message; `allMids` starts with a snapshot and repeats every second.
`trades`, `orderUpdates` and `userFills` are pushed as events happen.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add hl-protocol https://github.com/winterchill-trading/hl-protocol.git --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `hl-protocol`, `fixed-decimal` and
`order-book`, dune uses
the sibling sources and the pins are not needed.

## Modules

All modules live under `Hl_sim`. The order book (`Order_book`, with fills as
`Order_book.Fill`) lives in the `order-book` library.

| Module | Description |
| --- | --- |
| `Position` | Signed size, weighted entry price, realised PnL and funding for one coin |
| `Account` | USD balance, positions and per-coin leverage of one address |
| `Fee_schedule` | Maker/taker fees in basis points (default 1 / 3.5 bps) |
| `Clearinghouse` | All accounts: fill settlement, fees, initial and maintenance margin, liquidation, funding, `clearinghouseState` |
| `Event` | Log entries: order accepted/rejected/filled/cancelled, fill, liquidation, funding |
| `Exchange` | Top level: books per coin, clearinghouse, marks, id counters, clock, event log; exchange and info endpoints |
| `Server` | cohttp-async server for `/info`, `/exchange` and the `/ws` websocket (async_websocket); owns the `Exchange` |
| `Market_sim` | Seeded random-walk reference prices, marks, and noise traders posting, cancelling and taking |

## Design notes

- **Determinism.** Time is an `int` count of nanoseconds advanced by the caller with
  `Exchange.step`; the engine never reads the wall clock. Oids and trade ids are
  sequential. Hyperliquid-facing timestamps are reported in milliseconds.
- **Matching** is price-time priority with maker-price fills and self-trade prevention;
  see the [order-book](https://github.com/winterchill-trading/order-book) design notes.
  Market orders are IOC orders priced `slippage_bps` (default 5%) through the best
  opposite price, as Hyperliquid's SDKs send them.
- **Order statuses** follow Hyperliquid: an order that rests (even after partial fills)
  is `resting`; an IOC or market order with any fill is `filled` with the filled size and
  average price; an IOC order with no fill, an ALO order that would cross and failed
  checks are `error` with Hyperliquid's message where one exists.
- **Validation.** Size must be a multiple of `10^-szDecimals`; price must have at most 5
  significant figures (integers always allowed) and `6 - szDecimals` decimals; orders
  must be worth at least $10 unless reduce-only; reduce-only orders are clipped to the
  position; trigger orders are rejected.
- **Margin.** Cross margin only. Account value is balance plus unrealised PnL at mark.
  A new order needs `notional / leverage` for the part that increases the position,
  out of account value minus position margin minus margin held by resting orders
  (resting orders reserve their full notional / leverage). Maintenance margin is
  `notional / (2 * maxLeverage)`. Default leverage is `min 20 maxLeverage`.
- **Mark price** is the last `set_mark`, else the last trade price, else the book mid.
- **Liquidation.** `set_mark` and `step` close every position of an account whose value
  is below maintenance margin at mark and cancel its resting orders. There is no
  liquidator or backstop: the closed size leaves open interest, and losses beyond the
  balance leave a negative balance.
- **Funding** is charged at each multiple of the funding interval (1 hour) crossed by
  `step`: every position pays `szi * mark * rate`, so longs pay shorts when the rate is
  positive. The rate is per coin (`set_funding_rate`), default 0.00125%; it is not
  derived from a premium index.
- **Modify** cancels the target and places the replacement with a new oid (losing
  priority). If the replacement is rejected the original stays cancelled.
- **Fixed point.** `Price`, `Size` and `Usd` count units of `10^-8` in an `int`.
  Notional values use `Fixed_decimal.Product (Price) (Size) (Usd)` and fee and funding
  rates a private `Rate` type; products and quotients never overflow an intermediate
  and truncate toward zero.

- **Server.** All exchange access happens on the Async scheduler thread, so there is no
  locking. Before each request the exchange clock is stepped to the wall clock (funding
  and liquidation run then and on a 1s timer); events produced by a request are
  published to websocket subscribers right after it. The websocket upgrade uses
  cohttp-async's `` `Expert `` response, which hands the raw reader and writer to
  async_websocket after writing the `101` response.
- **Market simulation.** Each coin's reference price is a geometric random walk with
  `-vol-bps` volatility per second, stepped every 100ms; the mark follows it. Noise
  traders (addresses `0xffff...ff0000000N`, $10M each) post GTC orders up to 25 bps from
  the reference, cancel old ones and occasionally send market orders. Runs are
  reproducible for a seed, given the same sequence of external requests.

## Tests

`dune test` runs expect tests (fees, PnL, liquidation, funding, exchange flows, a
seeded market simulation, and the HTTP and websocket server on a free port with a fixed
clock) and `Base_quickcheck` properties: balances plus unrealised PnL plus fees are
conserved.
Order book tests live in `order-book`.
