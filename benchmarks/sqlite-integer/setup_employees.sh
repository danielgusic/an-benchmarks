#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
OFF="$HERE/build/sqlite.off.cwasm"
DB="$HERE/build/bench_employees.db"
DATASET="$ROOT/deps/test_db"
GUEST=/w

file_size_bytes() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }

[[ -x "$WT" ]] || { echo "missing Wasmtime binary: $WT"; exit 1; }
[[ -f "$OFF" ]] || { echo "missing $OFF -- run ./setup.sh first"; exit 1; }

DUMPS=(
  load_departments.dump load_employees.dump load_dept_emp.dump
  load_dept_manager.dump load_titles.dump load_salaries1.dump
  load_salaries2.dump load_salaries3.dump
)
for dump in "${DUMPS[@]}"; do
  [[ -f "$DATASET/$dump" ]] || {
    echo "Missing $DATASET/$dump; run git submodule update --init --recursive from the repository root" >&2
    exit 1
  }
done

echo "==> loading real employees dataset into bench_employees.db (AN-off)"
rm -f "$DB"
SETUP_OUT="$HERE/.setup_employees_stdout"
SETUP_ERR="$HERE/.setup_employees_stderr"
set +e
{ printf ".bail on\n"; cat "$HERE/schema_employees.sql" \
    "$DATASET/load_departments.dump" \
    "$DATASET/load_employees.dump" \
    "$DATASET/load_dept_emp.dump" \
    "$DATASET/load_dept_manager.dump" \
    "$DATASET/load_titles.dump" \
    "$DATASET/load_salaries1.dump" \
    "$DATASET/load_salaries2.dump" \
    "$DATASET/load_salaries3.dump"; } \
  | "$WT" run --dir "$HERE::$GUEST" --allow-precompiled -C cache=n "$OFF" "$GUEST/build/bench_employees.db" \
    > "$SETUP_OUT" 2> "$SETUP_ERR"
pipeline_status=("${PIPESTATUS[@]}")
set -e
grep -v sqliterc "$SETUP_OUT" || true
grep -v sqliterc "$SETUP_ERR" >&2 || true
rm -f "$SETUP_OUT" "$SETUP_ERR"
[[ "${pipeline_status[0]}" -eq 0 ]] || exit "${pipeline_status[0]}"
[[ "${pipeline_status[1]}" -eq 0 ]] || exit "${pipeline_status[1]}"
[[ -f "$DB" ]] || { echo "Wasmtime exited successfully but did not create $DB"; exit 1; }

printf "    bench_employees.db: %s MB\n" "$(( $(file_size_bytes "$DB") / 1048576 ))"
echo "==> setup done. Now run ./run_employees.sh to benchmark."
