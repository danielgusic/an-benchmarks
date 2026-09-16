#!/usr/bin/env bash
# ONE-TIME setup for the AN-encoding SQLite benchmark. Run this once (or again
# only when you change N, the .wasm, or gen.sql). It does NOT time anything.
#
#   ./setup.sh [N_ROWS]      (default 1,000,000)
#
# Produces, in this benchmark directory (modules/databases in build/):
#   sqlite.off.cwasm  - native precompile, AN-encoding OFF
#   sqlite.an.cwasm   - native precompile, AN-encoding ON
#   bench.db          - integer dataset with N rows (built once, AN-off)
set -euo pipefail

N="${1:-1000000}"
[[ "$N" =~ ^[1-9][0-9]*$ && $# -le 1 ]] || {
  echo "usage: $0 [positive row count]" >&2; exit 2;
}
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
DEFAULT_WASM="$HERE/build/sqlite.wasm"
WASM="${SQLITE_WASM:-$DEFAULT_WASM}"
OFF="$HERE/build/sqlite.off.cwasm"
AN="$HERE/build/sqlite.an.cwasm"
DB="$HERE/build/bench.db"
GUEST=/w

file_size_bytes() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

[[ -x "$WT" ]] || { echo "missing Wasmtime binary: $WT"; exit 1; }
[[ -f "$WASM" ]] || { echo "missing float-free SQLite module: $WASM"; exit 1; }

mkdir -p "$HERE/build"

echo "==> precompile native .cwasm (AN off + AN on)"
"$WT" compile -C an-encoding=n -C cache=n "$WASM" -o "$OFF"
"$WT" compile -C an-encoding=y -C cache=n "$WASM" -o "$AN"
printf "    off: %s MB   an: %s MB\n" \
  "$(( $(file_size_bytes "$OFF") / 1048576 ))" "$(( $(file_size_bytes "$AN") / 1048576 ))"

echo "==> build bench.db with N=$N integer rows (AN-off)"
rm -f "$DB"
SETUP_SQL="$HERE/.setup_gen.sql"
SETUP_OUT="$HERE/.setup_stdout"
SETUP_ERR="$HERE/.setup_stderr"
{ printf ".bail on\n"; sed "s/__N__/$N/g" "$HERE/gen.sql"; } > "$SETUP_SQL"
if "$WT" run --dir "$HERE::$GUEST" --allow-precompiled -C cache=n "$OFF" "$GUEST/build/bench.db" \
  < "$SETUP_SQL" > "$SETUP_OUT" 2> "$SETUP_ERR"; then
  status=0
else
  status=$?
fi
grep -v sqliterc "$SETUP_OUT" || true
grep -v sqliterc "$SETUP_ERR" >&2 || true
rm -f "$SETUP_SQL" "$SETUP_OUT" "$SETUP_ERR"
[[ "$status" -eq 0 ]] || exit "$status"
[[ -f "$DB" ]] || { echo "Wasmtime exited successfully but did not create $DB"; exit 1; }
echo "$N" > "$HERE/.builtN"
printf "    bench.db: %s MB  (N=%s)\n" "$(( $(file_size_bytes "$DB") / 1048576 ))" "$N"
echo "==> setup done. Now run ./run.sh to benchmark."
