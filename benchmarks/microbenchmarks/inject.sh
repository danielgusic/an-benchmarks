#!/usr/bin/env bash
# Fault-injection campaigns for the benchmarks in benches.conf, AN off and on.
#
#   ./inject.sh [EXPERIMENTS]                 (default: 1000 per benchmark and mode)
#   REGIONS=memory,stack ./inject.sh          fault regions: memory, shadow, stack, code,
#                                             runtime (default: memory)
#   WEIGHTING=equal ./inject.sh               with several regions: each region equally
#                                             likely (default size: each byte equally likely)
#   SEED=7 ./inject.sh                        campaign seed (default 0)
#   JOBS=4 ./inject.sh                        parallel experiments (default 1; keep it at or
#                                             below the number of performance cores)
#   TIMEOUT_FACTOR=10 ./inject.sh             hang threshold in golden process times
#   BENCHES=... MODES=... AN_CONSTANT=... BENCH_CONF=...   as in run.sh
#
# One campaign per (benchmark, mode). Each experiment flips one bit in a fresh
# process and is classified as correct, sdc, an-detected, trap, crash, timeout
# or late (see host/target/release/micro-host inject --help). The golden
# (fault-free) checksum must be the same in both modes.
#
# Rows go to results/faults-<timestamp>.csv (written as experiments finish),
# the environment to results/faults-<timestamp>.meta. Plot with plot_faults.py.
set -euo pipefail

EXPERIMENTS="${1:-1000}"
[[ "$EXPERIMENTS" =~ ^[1-9][0-9]*$ && $# -le 1 ]] || { echo "usage: $0 [positive experiment count]" >&2; exit 2; }
REGIONS="${REGIONS:-memory}"
WEIGHTING="${WEIGHTING:-size}"
SEED="${SEED:-0}"
JOBS="${JOBS:-1}"
TIMEOUT_FACTOR="${TIMEOUT_FACTOR:-10}"
[[ "$REGIONS" =~ ^(memory|shadow|stack|code|runtime)(,(memory|shadow|stack|code|runtime))*$ ]] || {
  echo "REGIONS must be a comma-separated list of memory, shadow, stack, code, runtime" >&2; exit 2;
}
[[ "$WEIGHTING" == size || "$WEIGHTING" == equal ]] || { echo "WEIGHTING must be size or equal" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ && "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "SEED and JOBS must be numbers" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/registry.sh"

mkdir -p "$RESULTS"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$RESULTS/faults-$STAMP.csv"
META="$RESULTS/faults-$STAMP.meta"
"$HOST" csv-header inject > "$CSV"
write_meta "$META" "experiments: $EXPERIMENTS  regions: $REGIONS  weighting: $WEIGHTING  seed: $SEED  jobs: $JOBS  timeout_factor: $TIMEOUT_FACTOR"

echo "faults: ${NAMES[*]}  experiments: $EXPERIMENTS  regions: $REGIONS  modes: ${MODES[*]}"
echo "results: $CSV"

for i in "${!NAMES[@]}"; do
  for mode in "${MODES[@]}"; do
    if [[ "$mode" == off && "$REGIONS" =~ ^(shadow,?)+$ ]]; then
      echo "==> ${NAMES[$i]} AN off: skipped (the shadow region only exists with AN on)"
      continue
    fi
    set_an_args "$mode"
    args=(inject "$HERE/build/${WASMS[$i]}" --csv --name "${NAMES[$i]}"
          --param "${PARAMS[$i]}" --iters "${ITERS[$i]}"
          --regions "$REGIONS" --weighting "$WEIGHTING" --seed "$SEED"
          --experiments "$EXPERIMENTS" --jobs "$JOBS" --timeout-factor "$TIMEOUT_FACTOR"
          ${AN_ARGS[@]+"${AN_ARGS[@]}"})
    [[ -n "${CHECKSUMS[$i]}" ]] && args+=(--expect "${CHECKSUMS[$i]}")
    label=off; [[ "$mode" == an ]] && label=on
    echo "==> ${NAMES[$i]} AN $label"
    if ! "$HOST" "${args[@]}" >> "$CSV"; then
      echo "FAILED: $HOST ${args[*]}" >&2
      exit 1
    fi
    if [[ -z "${CHECKSUMS[$i]}" ]]; then
      CHECKSUMS[$i]="$(awk -F, -v b="${NAMES[$i]}" '$1 == b && $16 == "golden" { print $18; exit }' "$CSV")"
    fi
  done
done
echo "done: $CSV"
