# hl-sim

Hyperliquid exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Requests and responses use the wire types from
[hl-protocol](https://github.com/winterchill-trading/hl-protocol).

This package holds the pure matching and accounting engine. It does no I/O; an
HTTP/websocket front end will drive it.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add hl-protocol https://github.com/winterchill-trading/hl-protocol.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `hl-protocol` and `fixed-decimal`, dune uses
the sibling sources and the pins are not needed.

## Modules

All modules live under `Hl_sim`.

| Module | Description |
| --- | --- |
| `Order_book` | One coin's book: price-time priority, GTC/IOC/ALO limit orders, slippage-bounded market orders, cancel, L2 snapshot |
| `Fill` | A taker/maker match: trade id, price, size, both oids, accounts and cloids |
| `Position` | Signed size, weighted entry price, realised PnL and funding for one coin |
| `Account` | USD balance, positions and per-coin leverage of one address |
| `Fee_schedule` | Maker/taker fees in basis points (default 1 / 3.5 bps) |
| `Clearinghouse` | All accounts: fill settlement, fees, initial and maintenance margin, liquidation, funding, `clearinghouseState` |
| `Event` | Log entries: order accepted/rejected/filled/cancelled, fill, liquidation, funding |
| `Exchange` | Top level: books per coin, clearinghouse, marks, id counters, clock, event log; exchange and info endpoints |
| `Fixed_math` | Overflow-safe products and quotients of `Price`, `Size` and `Usd` |

## Design notes

- **Determinism.** Time is an `int` count of nanoseconds advanced by the caller with
  `Exchange.step`; the engine never reads the wall clock. Oids and trade ids are
  sequential. Hyperliquid-facing timestamps are reported in milliseconds.
- **Matching.** Each side is a `Map` from price to a FIFO `Queue`. Fills execute at the
  maker's price. Market orders are IOC orders priced `slippage_bps` (default 5%) through
  the best opposite price, as Hyperliquid's SDKs send them.
- **Self-trade prevention.** When the next maker in priority belongs to the taker,
  matching stops and the taker's remainder is cancelled; earlier fills stand and the
  resting order is untouched.
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
  `Fixed_math` multiplies by splitting operands into integer and fractional parts and
  divides by long division, so no intermediate overflows; results truncate toward zero.

### OxCaml

The matching loop (`Order_book.sweep`) uses OxCaml modes to avoid heap allocation of
per-order temporaries:

- the taker's context record is stack-allocated with `let local_` and passed as a
  `local_` argument; its non-immediate fields are `global_` so they can be copied into
  heap-allocated fills;
- the loop's result is returned in the caller's region with `exclave_`, as a record with
  `global_` fields (a local tuple would make its components local, and they could not
  escape into the result);
- `Order_book.iter` takes its callback `@ local`, and Base's `Map` and `Queue` iterators
  accept local closures, so the wrappers stay on the stack.

## Tests

`dune test` runs expect tests (priority, partial fills, TIF semantics, self-trade,
cancel, L2 shape, fees, PnL, liquidation, funding, exchange flows) and
`Base_quickcheck` properties: books never cross, taker and maker filled sizes agree,
remaining sizes stay positive, cancelling everything empties the book, and balances
plus unrealised PnL plus fees are conserved.
