# lib/ (AGENTS.md)

The `hl_sim` library: `Adapt` (the Hyperliquid view of the engine: universe, price and size
rules, both endpoints in `hl-protocol` types, trigger orders, margin tiers, liquidation),
`Active_asset_ctx`, the HTTP and websocket server, and the copy-trading and anchoring support.

Build from the repository root with
`opam exec --switch 5.2.0+ox -- dune build --root .. @hl-sim/all`.

Rules that matter here:

- Responses must match what `hl-protocol` decodes. Change the wire types there first, then
  the server here.
- Error wording is part of the contract: clients and tests match on it. The collar and
  halt texts and their `orderUpdates` statuses are listed in the README's error table.
- `Guard` sets the collar and halt rule only through the engine's recorded calls, so input
  journals replay them.
- Use the engine through `exchange-core-engine`; do not reimplement matching or margin here.
- Pins and tolerances in this code come from measurements on one machine; comment them.
