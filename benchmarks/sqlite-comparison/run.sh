#!/usr/bin/env bash
# SQLite speedtest1 comparison: {mem, disk} x {native floats AN off,
# soft floats AN off, soft floats AN on}.
#
#   ./run.sh [REPS] [SIZE]                  (default: 3 25)
#   TESTSETS="main fp" ./run.sh 5 50        (default testsets: main orm fp star)
#
# Storage:
#   mem  - speedtest1 --memdb (database is :memory:)
#   disk - a fresh database file on the WASI --dir mount (speedtest1 defaults:
#          journal_mode=DELETE, synchronous=FULL)
#
# Timing: the primary metric is speedtest1's own TOTAL, the sum of its
# per-test timers (ms resolution). It excludes process startup, module
# loading and opening the database. Whole-process wall time and peak RSS are
# recorded too.
#
# Repetitions are interleaved (rep -> testset -> 6 configs) to spread drift
# evenly. For every testset the speedtest1 verification hash must be identical
# across all six configurations, and the three disk databases must be
# byte-identical. Raw measurements go to results/<timestamp>.csv, full
# speedtest1 output (per-test times) to outputs/.
set -euo pipefail

REPS="${1:-3}"
SIZE="${2:-25}"
[[ "$REPS" =~ ^[1-9][0-9]*$ && "$SIZE" =~ ^[1-9][0-9]*$ && $# -le 2 ]] || {
  echo "usage: $0 [positive repetitions] [positive size]" >&2; exit 2;
}
read -r -a TESTSETS <<< "${TESTSETS:-main orm fp star}"
STORAGES=(mem disk)
CONFIGS=(native.off softfloat.off softfloat.an)

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
BUILD="$HERE/build"
OUTPUTS="$HERE/outputs"
RESULTS="$HERE/results"
WORK="$HERE/.work"
GUEST=/w

[[ -x "$WT" ]] || { echo "missing Wasmtime binary: $WT" >&2; exit 1; }
if [[ "$(uname -s)" != Darwin ]] && ! /usr/bin/time -f '%e %M' -o /dev/null true 2>/dev/null; then
  echo "run.sh needs GNU time at /usr/bin/time (Debian/Ubuntu: apt install time; Fedora: dnf install time)" >&2
  exit 1
fi
for c in "${CONFIGS[@]}"; do
  [[ -f "$BUILD/speedtest1.$c.cwasm" ]] || { echo "missing build/speedtest1.$c.cwasm -- run ./setup.sh first" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK" "$OUTPUTS" "$RESULTS"
trap 'rm -rf "$WORK"' EXIT
CSV="$RESULTS/$(date +%Y%m%d-%H%M%S).csv"
echo "testset,rep,storage,config,total_s,wall_s,peak_rss_kb" > "$CSV"

echo "speedtest1: testsets: ${TESTSETS[*]}  reps: $REPS  size: $SIZE"
echo "results:    $CSV"

# run_one <testset> <rep> <storage> <config>; appends one CSV row.
run_one() {
  local test="$1" rep="$2" storage="$3" config="$4"
  local label="${storage}_${config/./_}" flag=n status=0 wall rss total
  local out="$OUTPUTS/${test}_${label}_rep${rep}.txt"
  [[ "$config" == *.an ]] && flag=y

  local target=(--memdb)
  [[ "$storage" == disk ]] && target=("$GUEST/$label.db")

  local cmd=("$WT" run --dir "$WORK::$GUEST" --allow-precompiled -C cache=n -C "an-encoding=$flag"
             "$BUILD/speedtest1.$config.cwasm"
             --size "$SIZE" --big-transactions --verify --testset "$test" "${target[@]}")
  if [[ "$(uname -s)" == Darwin ]]; then
    /usr/bin/time -l -o "$WORK/.time" "${cmd[@]}" > "$out" 2> "$WORK/.stderr" || status=$?
    wall="$(awk '$2 == "real" {print $1; exit}' "$WORK/.time")"
    rss="$(awk '/maximum resident set size/ {printf "%.0f", $1 / 1024}' "$WORK/.time")"
  else
    /usr/bin/time -o "$WORK/.time" -f '%e %M' "${cmd[@]}" > "$out" 2> "$WORK/.stderr" || status=$?
    read -r wall rss < "$WORK/.time"
  fi
  cat "$WORK/.stderr" >&2
  [[ "$status" -eq 0 ]] || { echo "FAILED: $test / $label (exit $status); output in $out" >&2; exit "$status"; }

  total="$(awk '$1 ~ /^TOTAL/ {v = $NF; sub(/s$/, "", v); print v; exit}' "$out")"
  [[ -n "$total" ]] || { echo "FAILED: $test / $label printed no TOTAL line" >&2; exit 1; }

  echo "$test,$rep,$storage,$config,$total,$wall,$rss" >> "$CSV"
  printf '    %-20s total=%8ss  wall=%7ss  peakRSS=%8.1f MiB\n' \
    "$label" "$total" "$wall" "$(awk -v k="$rss" 'BEGIN {print k / 1024}')"
}

for ((rep=1; rep<=REPS; rep++)); do
  for test in "${TESTSETS[@]}"; do
    echo "==> $test / rep $rep of $REPS"
    for storage in "${STORAGES[@]}"; do for config in "${CONFIGS[@]}"; do
      run_one "$test" "$rep" "$storage" "$config"
    done; done

    # Correctness: same verification hash everywhere, identical disk databases.
    ref_hash="$(grep '^Verification Hash:' "$OUTPUTS/${test}_mem_native_off_rep${rep}.txt")"
    for storage in "${STORAGES[@]}"; do for config in "${CONFIGS[@]}"; do
      h="$(grep '^Verification Hash:' "$OUTPUTS/${test}_${storage}_${config/./_}_rep${rep}.txt")"
      [[ "$h" == "$ref_hash" ]] || {
        echo "VERIFICATION FAILED: $test / ${storage}_${config}: '$h' != '$ref_hash' (mem_native_off)" >&2; exit 1;
      }
    done; done
    for config in softfloat.off softfloat.an; do
      cmp "$WORK/disk_native_off.db" "$WORK/disk_${config/./_}.db" || {
        echo "VERIFICATION FAILED: $test / disk database of $config differs from native_off" >&2; exit 1;
      }
    done
    rm -f "$WORK"/*.db "$WORK"/*.db-journal
  done
done

echo
echo "========== RESULTS (mean of $REPS reps, size $SIZE; time = speedtest1 TOTAL) =========="
echo "  x native = time / native AN-off (same storage);  x sf-off = time / soft-float AN-off"
awk -F, '
  NR == 1 { next }
  {
    k = $1 SUBSEP $3 SUBSEP $4
    n[k]++; t[k] += $5; w[k] += $6; r[k] += $7
    if (!(k in mn) || $5 < mn[k]) mn[k] = $5
    if (!(k in mx) || $5 > mx[k]) mx[k] = $5
    if (!($1 in seen)) { seen[$1] = 1; order[++nt] = $1 }
  }
  function avg(k) { return t[k] / n[k] }
  END {
    split("mem disk", S, " "); split("native.off softfloat.off softfloat.an", C, " ")
    for (i = 1; i <= nt; i++) {
      ts = order[i]
      printf "\n-- %s --\n", ts
      printf "  %-5s %-14s %10s %9s %9s %9s %10s %9s %9s\n", "store", "config", "time avg", "min", "max", "wall avg", "RSS MiB", "x native", "x sf-off"
      for (si = 1; si <= 2; si++) for (ci = 1; ci <= 3; ci++) {
        k = ts SUBSEP S[si] SUBSEP C[ci]
        if (!(k in n)) continue
        kn = ts SUBSEP S[si] SUBSEP "native.off"; ks = ts SUBSEP S[si] SUBSEP "softfloat.off"
        xn = (ci > 1 && avg(kn) > 0) ? sprintf("%.2fx", avg(k) / avg(kn)) : ""
        xs = (ci == 3 && avg(ks) > 0) ? sprintf("%.2fx", avg(k) / avg(ks)) : ""
        printf "  %-5s %-14s %9.3fs %8.3fs %8.3fs %8.2fs %10.1f %9s %9s\n", S[si], C[ci], avg(k), mn[k], mx[k], w[k] / n[k], r[k] / n[k] / 1024, xn, xs
      }
    }
  }' "$CSV"
echo "========================================================================================"
echo "Verification passed: hashes identical across all 6 configs, disk databases identical."
echo "Raw data: $CSV"
