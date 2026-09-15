#!/usr/bin/env bash
# Secondary "realistic usage" benchmark: AN-off vs AN-on on the real MySQL
# `employees` sample db (narrow OLTP HR schema, point-lookup + join heavy).
# This is a sanity check that the encoding
# holds up under a workload shape that looks like real SQLite usage instead
# of an adversarial bulk-aggregate synthetic one.
#
# Assumes ./setup.sh and ./setup_employees.sh have already run.
#
#   ./run_employees.sh [REPS]          (default 5)
set -euo pipefail

REPS="${1:-5}"
[[ "$REPS" =~ ^[1-9][0-9]*$ && $# -le 1 ]] || {
  echo "usage: $0 [positive repetitions]" >&2; exit 2;
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
OFF="$HERE/build/sqlite.off.cwasm"
AN="$HERE/build/sqlite.an.cwasm"
DB="$HERE/build/bench_employees.db"
WL="$HERE/workload_employees.sql"
GUEST=/w
OUTPUTS="$HERE/outputs"
mkdir -p "$OUTPUTS"

file_size_bytes() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }

[[ -x "$WT" ]] || { echo "missing Wasmtime binary: $WT"; exit 1; }
for f in "$OFF" "$AN" "$DB" "$WL"; do
  [[ -f "$f" ]] || { echo "missing $f -- run ./setup.sh and ./setup_employees.sh first"; exit 1; }
done
echo "dataset: bench_employees.db = $(( $(file_size_bytes "$DB") / 1048576 )) MB, reps=$REPS"

# run_once <label> <rep> <cwasm> <extra wasmtime flags...>
# prints "<wall_s> <peakRSS_kb>"
run_once() {
  local label="$1" rep="$2" cw="$3"; shift 3
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
    if { printf '.bail on\n'; cat "$WL"; } | /usr/bin/time -l -o "$tf" \
      "$WT" run --dir "$HERE::$GUEST" --allow-precompiled -C cache=n "$@" "$cw" \
      "$GUEST/$work_name" > "$OUTPUTS/out_$label.txt" 2> "$stderr_file"; then status=0; else status=$?; fi
    wall="$(awk '$2 == "real" {print $1; exit}' "$tf")"
    rss="$(awk '/maximum resident set size/ {printf "%.0f\n", $1 / 1024; found=1} END {if (!found) print "n/a"}' "$tf")"
  else
    if { printf '.bail on\n'; cat "$WL"; } | /usr/bin/time -o "$tf" -f "%e %M" \
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

declare -a off_t off_m an_t an_m

echo "==> employees workload / AN-OFF: $REPS reps"
for ((i=1;i<=REPS;i++)); do
  read -r w m < <(run_once off_employees "$i" "$OFF")
  off_t[i]=$w; off_m[i]=$m
  printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
done

echo "==> employees workload / AN-ON: $REPS reps"
for ((i=1;i<=REPS;i++)); do
  read -r w m < <(run_once an_employees "$i" "$AN" -C an-encoding=y)
  an_t[i]=$w; an_m[i]=$m
  printf "    rep %d/%d: wall=%ss  peakRSS=%sKB\n" "$i" "$REPS" "$w" "$m"
done

read -r off_avg off_min off_max <<<"$(stats "${off_t[@]}")"
read -r an_avg  an_min  an_max  <<<"$(stats "${an_t[@]}")"
read -r off_mavg _ _ <<<"$(stats "${off_m[@]}")"; off_mavg="$(integer_stat "$off_mavg")"
read -r an_mavg  _ _ <<<"$(stats "${an_m[@]}")";  an_mavg="$(integer_stat "$an_mavg")"
ratio="$(awk -v a="$an_avg" -v o="$off_avg" 'BEGIN{if(o>0)printf "%.2f", a/o; else printf "n/a"}')"

echo
echo "================= RESULTS (avg of $REPS reps) ================="
printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
  "AN-off" "$off_avg" "$off_min" "$off_max" "$off_mavg"
printf "  %-7s  avg=%6ss   min=%6ss   max=%6ss   peakRSS(avg)=%sKB\n" \
  "AN-on"  "$an_avg"  "$an_min"  "$an_max"  "$an_mavg"
printf "  AN-on / AN-off slowdown = %sx\n" "$ratio"
echo "=============================================================="

echo "--- output identical between modes? (correctness check) ---"
if diff -q "$OUTPUTS/out_off_employees.txt" "$OUTPUTS/out_an_employees.txt" >/dev/null 2>&1; then
  echo "    YES - byte-identical"
else
  echo "    NO - differences:"; diff "$OUTPUTS/out_off_employees.txt" "$OUTPUTS/out_an_employees.txt" | head || true
    exit 1
fi
