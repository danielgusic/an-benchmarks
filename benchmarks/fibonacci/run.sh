#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
N="${1:-35}"
REPS="${2:-5}"
ITERATIONS="${3:-1000000000}"
[[ "$N" =~ ^(0|[1-9][0-9]?)$ && "$N" -le 50 && "$REPS" =~ ^[1-9][0-9]*$ && "$ITERATIONS" =~ ^[1-9][0-9]{0,9}$ && "$ITERATIONS" -le 4294967295 && $# -le 3 ]] || {
  echo "usage: $0 [N: 0..50] [positive repetitions] [iterations: 1..4294967295]" >&2; exit 2;
}
[[ -x "$WT" && -f "$HERE/build/fibonacci.off.cwasm" && -f "$HERE/build/fibonacci.an.cwasm" ]] || {
  echo "Build the runtime and run setup.sh first" >&2; exit 1;
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fibonacci.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for ((i=1; i<=REPS; i++)); do
  for mode in off an; do
    flag=n; label=off
    if [[ "$mode" == an ]]; then flag=y; label=on; fi
    echo "==> repetition $i/$REPS / AN $label / fib($N), $ITERATIONS iterations"
    args=("$WT" run --allow-precompiled -C cache=n -C "an-encoding=$flag" "$HERE/build/fibonacci.$mode.cwasm" "$N" "$ITERATIONS")
    if [[ "$(uname -s)" == Darwin ]]; then
      /usr/bin/time -l "${args[@]}" > "$WORK/$mode.txt"
    else
      /usr/bin/time -f 'wall=%es peak-RSS=%M KiB' "${args[@]}" > "$WORK/$mode.txt"
    fi
    cat "$WORK/$mode.txt"
  done
  cmp "$WORK/off.txt" "$WORK/an.txt"
done
