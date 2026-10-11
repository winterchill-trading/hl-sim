# hl-sim

Hyperliquid exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core, Async).

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam install . --deps-only --with-test
dune build && dune test
```
