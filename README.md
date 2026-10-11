# hl-sim

Hyperliquid exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Requests and responses use the wire types from
[hl-protocol](https://github.com/winterchill-trading/hl-protocol). Matching is done by
[order-book](https://github.com/winterchill-trading/order-book), and fixed-point
arithmetic comes from [fixed-decimal](https://github.com/winterchill-trading/fixed-decimal).

This package holds the pure matching and accounting engine. It does no I/O; an
HTTP/websocket front end will drive it.

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

## Tests

`dune test` runs expect tests (fees, PnL, liquidation, funding, exchange flows) and
`Base_quickcheck` properties: balances plus unrealised PnL plus fees are conserved.
Order book tests live in `order-book`.
