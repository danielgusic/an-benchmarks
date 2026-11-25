#!/usr/bin/env bash
# Runs the microbenchmarks registered in benches.conf, AN off and on.
#
#   ./run.sh [REPS]                     (default: 5 process repetitions)
#   BENCHES="example" ./run.sh 3        only these registry names
#   MODES="an" ./run.sh                 only these modes (off, an)
#   AN_CONSTANT=1 ./run.sh              override the AN constant A
#   PIN_CPU=3 ./run.sh                  Linux: pin every process to CPU 3
#   BENCH_CONF=other.conf ./run.sh      use another registry
#
# One micro-host process per (rep, bench, mode). Repetitions are interleaved
# (rep -> bench -> mode) and the mode order flips on every repetition, so
# drift and ordering effects spread evenly over both modes.
#
# Correctness: the first run of a benchmark fixes its checksum (unless
# benches.conf gives one); every later run, in both modes, must reproduce it.
#
# Raw rows go to results/<timestamp>.csv, the run's environment to
# results/<timestamp>.meta. Summarise and plot with plot.py.
set -euo pipefail

REPS="${1:-5}"
[[ "$REPS" =~ ^[1-9][0-9]*$ && $# -le 1 ]] || { echo "usage: $0 [positive repetitions]" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/registry.sh"

PIN=()
if [[ -n "${PIN_CPU:-}" ]]; then
  if [[ "$(uname -s)" == Linux ]] && command -v taskset > /dev/null; then
    PIN=(taskset -c "$PIN_CPU")
  else
    echo "warning: PIN_CPU needs Linux taskset; running unpinned" >&2
  fi
fi

# --- Output files ------------------------------------------------------------
mkdir -p "$RESULTS"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$RESULTS/$STAMP.csv"
META="$RESULTS/$STAMP.meta"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/micro.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"$HOST" csv-header bench > "$CSV"
write_meta "$META" "reps: $REPS  pin: ${PIN_CPU:-none}"

echo "micro: ${NAMES[*]}  reps: $REPS  modes: ${MODES[*]}"
echo "results: $CSV"

# Median of the sample rows (ns) in a host CSV file.
median_ms() {
  awk -F, '$7 == "sample" { print $9 }' "$1" | sort -n |
    awk '{ v[NR] = $1 } END { m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2; printf "%.3f", m / 1e6 }'
}

# --- Run ---------------------------------------------------------------------
for ((rep = 1; rep <= REPS; rep++)); do
  order=("${MODES[@]}")
  if ((rep % 2 == 0 && ${#MODES[@]} == 2)); then order=("${MODES[1]}" "${MODES[0]}"); fi
  for i in "${!NAMES[@]}"; do
    for mode in "${order[@]}"; do
      set_an_args "$mode"
      args=(bench "$HERE/build/${WASMS[$i]}" --csv --name "${NAMES[$i]}" --rep "$rep"
            --param "${PARAMS[$i]}" --iters "${ITERS[$i]}"
            --warmup "${WARMUPS[$i]}" --samples "${SAMPLES[$i]}" ${AN_ARGS[@]+"${AN_ARGS[@]}"})
      [[ -n "${CHECKSUMS[$i]}" ]] && args+=(--expect "${CHECKSUMS[$i]}")
      label=off; [[ "$mode" == an ]] && label=on
      printf '==> rep %d/%d  %-20s AN %-3s ' "$rep" "$REPS" "${NAMES[$i]}" "$label"
      if ! ${PIN[@]+"${PIN[@]}"} "$HOST" "${args[@]}" > "$WORK/out.csv"; then
        echo "FAILED" >&2
        echo "command: $HOST ${args[*]}" >&2
        exit 1
      fi
      cat "$WORK/out.csv" >> "$CSV"
      [[ -n "${CHECKSUMS[$i]}" ]] || CHECKSUMS[$i]="$(awk -F, '$7 == "sample" { print $10; exit }' "$WORK/out.csv")"
      echo "median $(median_ms "$WORK/out.csv") ms"
    done
  done
done
echo "done: $CSV"
