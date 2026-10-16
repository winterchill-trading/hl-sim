#!/usr/bin/env bash
# End-to-end run with the price collar and halt rule on: starts hl-sim (seeded noise
# traders, -collar-bps and -halt-levels) on a free port, runs the market-maker binary
# against it for SECONDS (default 30), then sends an IOC buy 5% through the mid and
# checks that it gets Hyperliquid's oracle error. Prints the maker's report and the
# guard section of GET /status, then calls POST /sim/reopen.
#
#   scripts/collar-e2e.sh [SECONDS]
#
# Needs the sibling checkouts in one dune workspace (as market-maker/scripts/e2e.sh).
# Environment overrides: WORKSPACE (the parent of this checkout), OPAM_SWITCH (5.2.0+ox),
# DUNE_BUILD_DIR (<root>/_build-hl-sim), SEED (42), PORT (a free port), LOG_DIR (a
# temporary directory), COLLAR_BPS (50), HALT_LEVELS (7:15m,13:15m,20:reopen).
set -euo pipefail

run_for="${1:-30}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-hl-sim}"
seed="${SEED:-42}"
collar_bps="${COLLAR_BPS:-50}"
halt_levels="${HALT_LEVELS:-7:15m,13:15m,20:reopen}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hl-sim-collar-e2e.XXXXXX")}"
mkdir -p "$log_dir"

echo "collar-e2e: building hl-sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  hl-sim/bin/main.exe market-maker/bin/main.exe)
sim_exe="$DUNE_BUILD_DIR/default/hl-sim/bin/main.exe"
mm_exe="$DUNE_BUILD_DIR/default/market-maker/bin/main.exe"

port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"

sim_pid=""
mm_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  for pid in "$mm_pid" "$sim_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "collar-e2e: hl-sim on port $port, seed $seed, collar ${collar_bps} bps, halts $halt_levels" >&2
"$sim_exe" -port "$port" -seed "$seed" -collar-bps "$collar_bps" -halt-levels "$halt_levels" \
  >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 100); do
  curl -sf "$base_url/info" -d '{"type":"meta"}' >/dev/null 2>&1 && break
  kill -0 "$sim_pid" 2>/dev/null || { cat "$log_dir/sim.log" >&2; exit 1; }
  sleep 0.2
done
# Let the noise traders build a two-sided book and trade (the collar's reference).
sleep 2

echo "collar-e2e: market-maker for ${run_for}s, log $log_dir/mm.log" >&2
unset HL_PRIVATE_KEY HL_ADDRESS
status=0
"$mm_exe" -venue hyperliquid -network local -base-url "$base_url" -run-for "$run_for" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!
wait "$mm_pid" || status=$?
mm_pid=""
cat "$log_dir/report.txt"
[[ $status -eq 0 ]] || { echo "collar-e2e: market-maker exited with $status" >&2; tail -20 "$log_dir/mm.log" >&2; }

# An IOC buy 5% through the mid, on Hyperliquid's price grid (5 significant figures).
mid="$(curl -sf "$base_url/info" -d '{"type":"allMids"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["BTC"])')"
px="$(python3 -c "import sys; p = float('%.5g' % (float(sys.argv[1]) * 1.05)); print(int(p) if p == int(p) else p)" "$mid")"
order="{\"action\":{\"type\":\"order\",\"orders\":[{\"a\":0,\"b\":true,\"p\":\"$px\",\"s\":\"0.001\",\"r\":false,\"t\":{\"limit\":{\"tif\":\"Ioc\"}}}],\"grouping\":\"na\"},\"nonce\":1}"
response="$(curl -sf "$base_url/exchange" -H 'X-Address: 0x00000000000000000000000000000000000000e2' -d "$order")"
echo "collar-e2e: buy at $px (mid $mid): $response"
if ! grep -q 'away from the reference price' <<<"$response"; then
  echo "collar-e2e: FAILED: expected the oracle error" >&2
  status=1
fi

echo "--- guard status ---"
curl -sf "$base_url/status" | python3 -c 'import json,sys; g = json.load(sys.stdin)["guard"]; g["recent"] = g["recent"][-3:]; print(json.dumps(g, indent=2))'
echo "--- POST /sim/reopen ---"
curl -sf -X POST "$base_url/sim/reopen" | python3 -c 'import json,sys; g = json.load(sys.stdin); print(json.dumps({"halted": g["halted"], "stats": g["stats"]}))'
echo "collar-e2e: guard log lines (settings and events): $(grep -c '(guard' "$log_dir/sim.log" || true), logs in $log_dir"
exit "$status"
