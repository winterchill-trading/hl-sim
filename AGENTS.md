# AGENTS.md (hl-sim)

## Purpose

A Hyperliquid exchange simulator: an HTTP and websocket server that speaks the public
Hyperliquid API on top of the shared matching engine, with a seeded market simulation
behind it. Clients and copy-trading code run against it in place of mainnet or testnet.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_sim` library: the Hyperliquid view of the engine (`Adapt`), `Active_asset_ctx`, the HTTP and websocket server, copy-trading support, anchoring ([lib/AGENTS.md](lib/AGENTS.md)) |
| `bin/` | The `hl-sim` executable: flags for seed, market, noise traders, journals, price anchor, copy trading ([bin/AGENTS.md](bin/AGENTS.md)) |
| `test/` | Expect tests, the signed-request fixtures and recorded raw frames ([test/AGENTS.md](test/AGENTS.md)) |
| `scripts/` | `anchor-demo.sh`, a live anchor run against a recorded minute |
| `.github/` | CI workflow ([.github/AGENTS.md](.github/AGENTS.md)) |
| `README.md` | Running, addresses, the info and exchange endpoints, journal, price anchor, copy trading |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-sim/all @hl-sim/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-sim` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

Run the simulator: `dune exec hl-sim -- -port 3000` (see the README for the flags).

Format only this repository, after the tests pass:
`dune build --root .. @hl-sim/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, ppx_jane
  derivations, expect tests and Base_quickcheck properties.
- The simulator's behaviour is part of its contract for the clients. A change to a
  response shape, error wording or rounding rule needs a test pinned on the exact text.
- Seeded runs are reproducible. Keep new randomness on the seeded generator; a new
  consumer of noise traders shifts every seeded test that uses them.
- Engine event kinds that only this server matches go in separate drains, so simulators
  matching every event type still compile.
- Odoc on every public value; a comment at each non-obvious choice saying what and why.
- No `Obj.magic`. The obj-magic job in CI enforces it.

## Dependencies and dependents

- Depends on `exchange-core`, `exchange-core-engine`, `order-book`, `hl-protocol`,
  `price-anchor`, `market-data`, `mm-core`, `hl-client`, `parquet`, `venue-net` and
  `fixed-decimal`. The CI pin list in `.github/workflows/ci.yml` gives the exact set and order.
- Used by `../hl-mm` (tests), `../hl-copy-engine` (tests), `../hl-copy-api` (end-to-end
  script), `../hl-copy-web` (live smoke test) and `../hl-leaderboard` (its end-to-end script).
- Spec: `../specs/repos/hl-sim.md`; the simulators design is in `../specs/design/simulators.md`.

## CI

`.github/workflows/ci.yml` has two jobs. `build` runs the `ox-setup` action (the switch
and every sibling pinned from GitHub), then `dune build` and `dune test`. `obj-magic` calls
the shared reusable workflow from `infra`. The switch cache is keyed on the pins; a run
with unchanged siblings restores it and finishes in a few minutes.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- Signed approvals carry nonces near 1.7e12 milliseconds. Tests need the server clock set to
  about 1.7e18 nanoseconds for the nonce window to accept them.
- Simulated accounts (leaders, noise traders) must be marked as already seen. Otherwise the
  first info request credits them the initial balance again.
- `Float.to_string` prints `1000000.`. Leaderboard strings need their own decimal formatting.
- Pushing l2Book updates at once after a quiet spell broke a signed test in `hl-mm`
  (book update before the order ack). Keep the 50 ms delay in the server's push path.
- Synthetic leaders lose on thin noise books: fees and slippage beat their strategy. Cap
  their slippage or give them an edge, or the copy-trading runs show nothing.
- Pushing commits in quick succession cancels earlier CI runs through the concurrency
  group. Pause until one run finishes before the next push when you need its result.
- Expect tests of the signed fixtures are generated with the Python `eth-account` package
  in a scratch virtualenv; do not install it into the shared switch.

## Where to read more

- `README.md`, `../specs/repos/hl-sim.md`, `../specs/design/simulators.md`,
  `../specs/design/copytrading.md`
- `../oxcaml-claude-skills/AGENTS.md` (workspace guide) and `../oxcaml-claude-skills/GOTCHAS.md`
- Skills: `../oxcaml-claude-skills/skills/oxcaml-performance` before optimising the engine
  path, `../oxcaml-claude-skills/skills/janestreet-ocaml-style`

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Point the simulator or its tests at a mainnet URL. Keep the testnet and local targets only.
- Publish, tag or release.
- Commit credentials. `.env` is gitignored; values come from the environment only.
- Print secrets, private keys or signatures.
