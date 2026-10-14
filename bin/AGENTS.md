# bin/ (AGENTS.md)

The `hl-sim` executable. Its flags (seed, market, noise traders, journals, price anchor,
copy trading, signature checks) are documented in the root `README.md`; keep the two in step.

Build and run from the repository root:
`opam exec --switch 5.2.0+ox -- dune exec hl-sim -- -port 3000`.

Rules that matter here:

- A new flag keeps the default behaviour of existing runs, and gets a line in the README.
- Changing a default changes every seeded run that relies on it; say so in the commit message.
