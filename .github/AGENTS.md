# .github/ (AGENTS.md)

`workflows/ci.yml` builds and tests this repository with the shared `ox-setup` action and
calls the `obj-magic` reusable workflow from `infra`.

- The sibling pins must match `dune-project` and the org dependencies. A new org dependency
  gets its pin in the same commit.
- Keep the `concurrency` block.
- Check a run with one `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
