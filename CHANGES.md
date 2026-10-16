# Changes

Notable changes to `hl-sim` are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (before 1.0.0, a minor version may break the
API).

## Unreleased

### Added

- Price collar and halt rule flags: `-collar-bps N` or `-collar-ticks N`,
  `-collar-reference last|mid|mark` (the mark by default when anchored, else the last
  trade), `-collar-action reject|reprice`, `-halt-levels "7:15m,13:15m,20:reopen"` and
  `-halt-scope market|symbol`. They set the engine's `Price_collar` and `Halt_rule`
  through recorded calls, so input journals replay the guard events.
- Collar rejections answer Hyperliquid's oracle error,
  `Order price cannot be more than P% away from the reference price asset=N`, with the
  `orderUpdates` status `oracleRejected`; halt rejections answer
  `Trading is halted. asset=N`.
- `GET /status` has a `guard` entry (settings, halted coins, counters, recent guard
  events) when a collar or halt rule is set; `POST /sim/reopen` (optional `coin`) lifts
  halts. Every guard event is logged at `info`.
- `Guard` module; `Server.guard_events` and `Server.reopen`.
- `scripts/collar-e2e.sh`: the market-maker binary against a collared simulator, then
  an order that must get the oracle error.

### Compatibility

- Without the new flags nothing changes: no `guard` entry in `GET /status`, the same
  responses and the same journals.
