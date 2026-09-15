#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TELEGRAMS="${1:-1000000}"
REPS="${2:-5}"
[[ "$TELEGRAMS" =~ ^[1-9][0-9]*$ && "$REPS" =~ ^[1-9][0-9]*$ && $# -le 2 ]] || {
  echo "usage: $0 [positive telegram count] [positive repetitions]" >&2; exit 2;
}
HOST="$HERE/target/release/point-oc-host"
[[ -x "$HOST" ]] || { echo "Run setup.sh first" >&2; exit 1; }
for ((i=1; i<=REPS; i++)); do
  echo "==> repetition $i/$REPS / AN off"
  "$HOST" --bench "$TELEGRAMS"
  echo "==> repetition $i/$REPS / AN on"
  "$HOST" --an --bench "$TELEGRAMS"
done
