#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
# N="${1:-35}"
REPS="${1:-1000}"
DATAFILE="${2:-$ROOT/deps/mibench/telecomm/adpcm/data/large.pcm}"
ITERATIONS="${3:-1000000000}"
[[ "$REPS" =~ ^[1-9][0-9]*$ && "$ITERATIONS" =~ ^[1-9][0-9]{0,9}$ && "$ITERATIONS" -le 4294967295 && $# -le 3 ]] || {
  echo "usage: $0 [datafile path] [positive repetitions] [iterations: 1..4294967295]" >&2; exit 2;
}
[[ -x "$WT" && -f "$HERE/build/crc_32.off.cwasm" && -f "$HERE/build/crc_32.an.cwasm" ]] || {
  echo "Build the runtime and run setup.sh first" >&2; exit 1;
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/crc_32.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for ((i=1; i<=REPS; i++)); do
  for mode in off an; do
    flag=n; label=off
    if [[ "$mode" == an ]]; then flag=y; label=on; fi
    echo "==> repetition $i/$REPS / AN $label /"
    args=("$WT" run --dir=/ --allow-precompiled -C cache=n -C "an-encoding=$flag" "$HERE/build/crc_32.$mode.cwasm" "$DATAFILE")
    if [[ "$(uname -s)" == Darwin ]]; then
      /usr/bin/time -l "${args[@]}" > "$WORK/$mode.txt"
    else
      /usr/bin/time -f 'wall=%es peak-RSS=%M KiB' "${args[@]}" > "$WORK/$mode.txt"
    fi
    cat "$WORK/$mode.txt"
  done
  cmp "$WORK/off.txt" "$WORK/an.txt"
done
