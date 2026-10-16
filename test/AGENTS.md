# test/ (AGENTS.md)

Expect tests of the endpoints, the seeded market and the server on a free port with a fixed
clock, copy-trading scenarios, anchored runs, and fixtures.

- `test/fixtures/user_signed.json` is produced by `user_signed.py` (Python `eth-account`,
  in a scratch virtualenv). Regenerate it there, never in the shared switch.
- `test/fixtures/raw/` holds recorded minute frames in the recorder format.
- Promote expect output with `dune promote` only after reading each diff.
- `test_guard.ml` pins the collar and halt error texts, the `guard` status JSON and the
  replay of guard events. An IOC meant to hit a collar or halt needs resting liquidity to
  cross; otherwise it is not marketable and gets the no-liquidity error instead.
- Tests that read pushed books skip updates until the expected order appears; pushes are
  at most every 20 ms. Do not assert on the first push.

Run from the repository root with
`opam exec --switch 5.2.0+ox -- dune build --root .. @hl-sim/runtest`.
