#!/usr/bin/env bash
# Runs hl-sim with BTC anchored to a recorded minute of Hyperliquid BTC (the raw minute
# files under test/fixtures, about 18 seconds of trades, books and funding), connects the
# market-maker to it when that repository is checked out next to this one, and prints
# once a second the anchor's reference price, the simulated book's top and the maker's
# quotes, so the quotes can be seen following the reference.
#
#   scripts/anchor-demo.sh [SECONDS]
#
# Environment: WORKSPACE (the dune workspace holding hl-sim and its siblings, default the
# parent of this checkout), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-hl-sim), SPEED (1: real time; 0.5 stretches the minute to twice its
# length), PORT (a free port), MM (1 to require the market-maker, 0 to skip it; default:
# use it when present), DATA (the recorder data directory, default the fixture),
# FROM/TO (the recorded range, default the fixture's minute), ANCHOR
# (hyperliquid:BTC=BTC).
set -euo pipefail

run_for="${1:-25}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-hl-sim}"
speed="${SPEED:-1}"
data="${DATA:-$repo/test/fixtures}"
from="${FROM:-2026-10-12T13:35:00Z}"
to="${TO:-2026-10-12T13:36:00Z}"
anchor="${ANCHOR:-hyperliquid:BTC=BTC}"
coin="${anchor##*=}"
mm_address="0x0000000000000000000000000000000000006d6d"

use_mm="${MM:-}"
if [[ -z "$use_mm" ]]; then
  if [[ -d "$root/market-maker" ]]; then use_mm=1; else use_mm=0; fi
fi
targets=(hl-sim/bin/main.exe)
if [[ "$use_mm" == 1 ]]; then targets+=(market-maker/bin/main.exe); fi

echo "anchor-demo: building ${targets[*]} (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . "${targets[@]}")
build="$DUNE_BUILD_DIR/default"

port="${PORT:-$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/anchor-demo.XXXXXX")"

pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

"$build/hl-sim/bin/main.exe" -port "$port" -anchor "$anchor" -anchor-raw "$data" \
  -anchor-from "$from" -anchor-to "$to" -anchor-speed "$speed" \
  -anchor-status-interval-s 0 >"$log_dir/sim.log" 2>&1 &
pids+=($!)
for _ in $(seq 50); do
  curl -sf "$base_url/info" -d '{"type":"meta"}' >/dev/null && break
  sleep 0.1
done
echo "anchor-demo: hl-sim on $base_url anchored to $anchor ($data, speed $speed), logs in $log_dir" >&2

if [[ "$use_mm" == 1 ]]; then
  # The maker refuses an empty book: wait for the first reference snapshot.
  for _ in $(seq 100); do
    curl -sf "$base_url/status" | grep -q '"fresh":true' && break
    sleep 0.1
  done
  "$build/market-maker/bin/main.exe" -venue hyperliquid -network local -base-url "$base_url" \
    -symbol "$coin" -run-for "$run_for" >"$log_dir/mm-report.txt" 2>"$log_dir/mm.log" &
  pids+=($!)
fi

show() {
  python3 -I - "$1" "$2" "$3" "$coin" <<'PY'
import json, sys
status, book, orders, coin = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4]
a = (status.get("anchors") or [{}])[0]
bids, asks = (book or {}).get("levels", [[], []])
top = lambda side: side[0]["px"] if side else "-"
mine = [o for o in orders if o.get("coin") == coin]
mm_bid = max((float(o["limitPx"]) for o in mine if o["side"] == "B"), default=None)
mm_ask = min((float(o["limitPx"]) for o in mine if o["side"] == "A"), default=None)
fmt = lambda x: "-" if x is None else f"{x:g}"
print(f"ref {a.get('reference_price') or '-':>9} {'fresh' if a.get('fresh') else 'stale':5}"
      f"  book {top(bids):>9} / {top(asks):<9}  maker {fmt(mm_bid):>9} / {fmt(mm_ask):<9}"
      f"  shadows {a.get('shadow_levels', 0):2}  replay fills {a.get('replay_fills', 0)}")
PY
}

end=$((SECONDS + run_for))
while ((SECONDS < end)); do
  status="$(curl -sf "$base_url/status" || echo '{}')"
  book="$(curl -sf "$base_url/info" -d "{\"type\":\"l2Book\",\"coin\":\"$coin\"}" || echo null)"
  orders="$(curl -sf "$base_url/info" -d "{\"type\":\"openOrders\",\"user\":\"$mm_address\"}" || echo '[]')"
  show "$status" "$book" "$orders"
  sleep 1
done

if [[ "$use_mm" == 1 ]]; then
  wait "${pids[1]}" 2>/dev/null || true
  echo "anchor-demo: market-maker report:" >&2
  cat "$log_dir/mm-report.txt"
fi
echo "anchor-demo: final anchor status:" >&2
curl -sf "$base_url/status"
echo
