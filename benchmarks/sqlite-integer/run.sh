#!/usr/bin/env bash
# AN-encoding SQLite benchmark: read+write workload, AN-off vs AN-on.
# Assumes ./setup.sh has already produced sqlite.off.cwasm, sqlite.an.cwasm and
# bench.db. This script ONLY runs the timed workload (no compiling, no DB build).
#
#   ./run.sh [i32|i64|all] [REPS]   (default: all 5)
#   ./run.sh [REPS]                 (legacy shorthand for: all REPS)
#
# Runs two independent workloads (i32 and i64) against both modes. Each rep
# copies bench.db to a fresh writable file. Reports avg/min/max wall time and
# peak RSS per workload per mode, plus the AN-on/AN-off slowdown ratio for each.
set -euo pipefail

case "${1:-all}" in
  i32|i64|all)
    WORKLOAD="${1:-all}"
    REPS="${2:-5}"
    ;;
  *[!0-9]*|'')
    echo "usage: $0 [i32|i64|all] [REPS]"; exit 2
    ;;
  *)
    WORKLOAD=all
    REPS="$1"
    [[ $# -eq 1 ]] || { echo "usage: $0 [i32|i64|all] [REPS]"; exit 2; }
    ;;
esac
[[ "$REPS" =~ ^[1-9][0-9]*$ && $# -le 2 ]] || { echo "REPS must be a positive integer"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
OFF="$HERE/build/sqlite.off.cwasm"
AN="$HERE/build/sqlite.an.cwasm"
DB="$HERE/build/bench.db"
WL_I32="$HERE/workload_i32.sql"
WL_I64="$HERE/workload_i64.sql"
GUEST=/w
OUTPUTS="$HERE/outputs"
mkdir -p "$OUTPUTS"

file_size_bytes() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

[[ -x "$WT" ]] || { echo "missing Wasmtime binary: $WT"; exit 1; }
required=("$OFF" "$AN" "$DB")
[[ "$WORKLOAD" == i64 ]] || required+=("$WL_I32")
[[ "$WORKLOAD" == i32 ]] || required+=("$WL_I64")
for f in "${required[@]}"; do
  [[ -f "$f" ]] || { echo "missing $f -- run ./setup.sh first"; exit 1; }
done
echo "dataset: bench.db = $(( $(file_size_bytes "$DB") / 1048576 )) MB (N=$(cat "$HERE/.builtN" 2>/dev/null)), workload=$WORKLOAD, reps=$REPS"

# run_once <label> <rep> <cwasm> <workload_sql> <extra wasmtime flags...>
# prints "<wall_s> <peakRSS_kb>"
run_once() {
  local label="$1" rep="$2" cw="$3" wl="$4"; shift 4
  local work_db work_name
  work_db="$(mktemp "$HERE/.work_${label}.XXXXXX")"
  work_name="${work_db##*/}"

  cleanup_work_db() {
    rm -f "$work_db" "$work_db-journal" "$work_db-wal" "$work_db-shm"
    if [[ -d "$work_db.lock" ]]; then
      rmdir "$work_db.lock" 2>/dev/null || true
    fi
  }
  trap cleanup_work_db EXIT
  cp "$DB" "$work_db"

  local tf="$HERE/.time_$label"
  local stderr_file="$HERE/.stderr_$label"
  local tracker_file="$HERE/tracker_${label}_rep${rep}.txt"
  local status wall rss

  if [[ "$(uname -s)" == Darwin ]]; then
    if { printf '.bail on\n'; cat "$wl"; } | /usr/bin/time -l -o "$tf" \
      "$WT" run --dir "$HERE::$GUEST" --allow-precompiled -C cache=n "$@" "$cw" \
      "$GUEST/$work_name" > "$OUTPUTS/out_$label.txt" 2> "$stderr_file"; then status=0; else status=$?; fi
    wall="$(awk '$2 == "real" {print $1; exit}' "$tf")"
    rss="$(awk '/maximum resident set size/ {printf "%.0f\n", $1 / 1024; found=1} END {if (!found) print "n/a"}' "$tf")"
  else
    if { printf '.bail on\n'; cat "$wl"; } | /usr/bin/time -o "$tf" -f "%e %M" \
      "$WT" run --dir "$HERE::$GUEST" --allow-precompiled -C cache=n "$@" "$cw" \
      "$GUEST/$work_name" > "$OUTPUTS/out_$label.txt" 2> "$stderr_file"; then status=0; else status=$?; fi
    read -r wall rss < "$tf"
  fi

  grep -v sqliterc "$stderr_file" >&2 || true
  if [[ "$status" -eq 0 ]] && grep '^\[an-integer-loads:' "$stderr_file" > "$tracker_file"; then
    rm -f "${tracker_file%.txt}.partial.txt"
    echo "    tracker: $tracker_file" >&2
  elif [[ "$status" -ne 0 ]] && grep '^\[an-integer-loads:' "$stderr_file" > "${tracker_file%.txt}.partial.txt"; then
    rm -f "$tracker_file"
    echo "    partial tracker (failed run): ${tracker_file%.txt}.partial.txt" >&2
  else
    rm -f "$tracker_file" "${tracker_file%.txt}.partial.txt"
  fi
  cleanup_work_db
  trap - EXIT
  rm -f "$tf" "$stderr_file"
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s %s\n' "$wall" "$rss"
}

# stats over a list of numbers: prints "avg min max"
stats() { printf '%s\n' "$@" | awk '
  $1 != "n/a" {if(!n)min=max=$1; s+=$1; n++; if($1<min)min=$1; if($1>max)max=$1}
  END{if(n)printf "%.2f %.2f %.2f", s/n, min, max; else printf "n/a n/a n/a"}'; }

integer_stat() {
  [[ "$1" == n/a ]] && printf 'n/a' || printf '%.0f' "$1"
}

declare -a off_i32_t off_i32_m an_i32_t an_i32_m
declare -a off_i64_t off_i64_m an_i64_t an_i64_m

# ---- i32 workload -----------------------------------------------------------

if [[ "$WORKLOAD" == all || "$WORKLOAD" == i32 ]]; then
  echo "==> i32 workload / AN-OFF: $REPS reps"
  for ((i=1;i<=REPS;i++)); do
    read -r w m < <(run_once off_i32 "$i" "$OFF" "$WL_I32")
    off_i32_t[i]=$w; off_i32_m[i]=$m
    printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
  done

  echo "==> i32 workload / AN-ON: $REPS reps"
  for ((i=1;i<=REPS;i++)); do
    read -r w m < <(run_once an_i32 "$i" "$AN" "$WL_I32" -C an-encoding=y)
    an_i32_t[i]=$w; an_i32_m[i]=$m
    printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
  done
fi

# ---- i64 workload -----------------------------------------------------------

if [[ "$WORKLOAD" == all || "$WORKLOAD" == i64 ]]; then
  echo "==> i64 workload / AN-OFF: $REPS reps"
  for ((i=1;i<=REPS;i++)); do
    read -r w m < <(run_once off_i64 "$i" "$OFF" "$WL_I64")
    off_i64_t[i]=$w; off_i64_m[i]=$m
    printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
  done

  echo "==> i64 workload / AN-ON: $REPS reps"
  for ((i=1;i<=REPS;i++)); do
    read -r w m < <(run_once an_i64 "$i" "$AN" "$WL_I64" -C an-encoding=y)
    an_i64_t[i]=$w; an_i64_m[i]=$m
    printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
  done
fi

# ---- results ----------------------------------------------------------------

echo
echo "================= RESULTS (avg of $REPS reps) ================="
if [[ "$WORKLOAD" == all || "$WORKLOAD" == i32 ]]; then
  read -r off_i32_avg off_i32_min off_i32_max <<<"$(stats "${off_i32_t[@]}")"
  read -r an_i32_avg  an_i32_min  an_i32_max  <<<"$(stats "${an_i32_t[@]}")"
  read -r off_i32_mavg _ _ <<<"$(stats "${off_i32_m[@]}")"; off_i32_mavg="$(integer_stat "$off_i32_mavg")"
  read -r an_i32_mavg  _ _ <<<"$(stats "${an_i32_m[@]}")";  an_i32_mavg="$(integer_stat "$an_i32_mavg")"
  ratio_i32="$(awk -v a="$an_i32_avg" -v o="$off_i32_avg" 'BEGIN{if(o>0)printf "%.2f", a/o; else printf "n/a"}')"
  echo "  -- i32 workload (R1-R7, W1-W6) --"
  printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
    "AN-off" "$off_i32_avg" "$off_i32_min" "$off_i32_max" "$off_i32_mavg"
  printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
    "AN-on"  "$an_i32_avg"  "$an_i32_min"  "$an_i32_max"  "$an_i32_mavg"
  printf "  AN-on / AN-off slowdown = %sx\n" "$ratio_i32"
fi
if [[ "$WORKLOAD" == all || "$WORKLOAD" == i64 ]]; then
  [[ "$WORKLOAD" == i64 ]] || echo
  read -r off_i64_avg off_i64_min off_i64_max <<<"$(stats "${off_i64_t[@]}")"
  read -r an_i64_avg  an_i64_min  an_i64_max  <<<"$(stats "${an_i64_t[@]}")"
  read -r off_i64_mavg _ _ <<<"$(stats "${off_i64_m[@]}")"; off_i64_mavg="$(integer_stat "$off_i64_mavg")"
  read -r an_i64_mavg  _ _ <<<"$(stats "${an_i64_m[@]}")";  an_i64_mavg="$(integer_stat "$an_i64_mavg")"
  ratio_i64="$(awk -v a="$an_i64_avg" -v o="$off_i64_avg" 'BEGIN{if(o>0)printf "%.2f", a/o; else printf "n/a"}')"
  echo "  -- i64 workload (R8-R12, W1v-W6) --"
  printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
    "AN-off" "$off_i64_avg" "$off_i64_min" "$off_i64_max" "$off_i64_mavg"
  printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
    "AN-on"  "$an_i64_avg"  "$an_i64_min"  "$an_i64_max"  "$an_i64_mavg"
  printf "  AN-on / AN-off slowdown = %sx\n" "$ratio_i64"
fi
echo "=============================================================="

echo "--- output identical between modes? (correctness check) ---"
if [[ "$WORKLOAD" == all ]]; then workloads=(i32 i64); else workloads=("$WORKLOAD"); fi
for wl in "${workloads[@]}"; do
  if diff -q "$OUTPUTS/out_off_$wl.txt" "$OUTPUTS/out_an_$wl.txt" >/dev/null 2>&1; then
    echo "    $wl: YES - byte-identical"
  else
    echo "    $wl: NO - differences:"; diff "$OUTPUTS/out_off_$wl.txt" "$OUTPUTS/out_an_$wl.txt" | head || true
    exit 1
  fi
done
