#!/usr/bin/env bash
set -euo pipefail
exec 2>&1

REPETITIONS="${1:-3}"
SIZE="${2:-25}"
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ && "$SIZE" =~ ^[1-9][0-9]*$ && $# -le 2 ]] || {
  echo "usage: $0 [positive repetitions] [positive size]" >&2; exit 2;
}
TESTS=(main orm fp star)

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
WASMTIME="${WASMTIME_BIN:-$ROOT/../../deps/wasmtime-an/target/release/wasmtime}"
REGULAR="$BUILD/speedtest1.regular.cwasm"
ENCODED="$BUILD/speedtest1.encoded.cwasm"
TIME=/usr/bin/time
GUEST=/benchmark

[[ -x "$WASMTIME" && -f "$REGULAR" && -f "$ENCODED" ]] || {
  echo "Build dependencies and run setup.sh first" >&2; exit 1;
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sqlite-benchmark.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MEASUREMENTS="$WORK/measurements"

run_one() {
  local test="$1" mode="$2" repetition="$3" module="$4" an="$5"
  local output="$WORK/$test-$mode-$repetition.txt"
  local database="$WORK/$test-$mode-$repetition.db"
  local timing="$WORK/$test-$mode-$repetition.time"

  echo
  echo "--- $test / $mode / repetition $repetition of $REPETITIONS ---"

  if [[ "$(uname -s)" == Darwin ]]; then
    "$TIME" -l -o "$timing" \
      "$WASMTIME" run --dir "$WORK::$GUEST" --allow-precompiled \
      -C cache=n -C "an-encoding=$an" \
      "$module" --size "$SIZE" --big-transactions --verify \
      --testset "$test" "$GUEST/${database##*/}" \
      | tee "$output"
    WALL="$(awk '$2 == "real" {print $1}' "$timing")"
    RSS="$(awk '/maximum resident set size/ {printf "%.0f", $1 / 1024}' "$timing")"
  else
    "$TIME" -o "$timing" -f '%e %M' \
      "$WASMTIME" run --dir "$WORK::$GUEST" --allow-precompiled \
      -C cache=n -C "an-encoding=$an" \
      "$module" --size "$SIZE" --big-transactions --verify \
      --testset "$test" "$GUEST/${database##*/}" \
      | tee "$output"
    read -r WALL RSS < "$timing"
  fi

  printf '%s %s %s %s\n' "$test" "$mode" "$WALL" "$RSS" >> "$MEASUREMENTS"
  printf 'wall=%ss peak-RSS=%.1f MiB\n' "$WALL" "$(awk -v n="$RSS" 'BEGIN {print n/1024}')"
}

description() {
  case "$1" in
    main) printf 'mixed SQL/OLTP' ;;
    orm)  printf 'short row lookups' ;;
    fp)   printf 'REAL-heavy SQL' ;;
    star) printf 'star-schema joins' ;;
  esac
}

average() {
  awk -v test="$1" -v mode="$2" -v column="$3" '
    $1 == test && $2 == mode { total += $column; count++ }
    END { printf "%.2f", total / count }
  ' "$MEASUREMENTS"
}

echo "SQLite speedtest1: $REPETITIONS repetitions, size $SIZE"

for ((repetition=1; repetition<=REPETITIONS; repetition++)); do
  for test in "${TESTS[@]}"; do
    run_one "$test" regular "$repetition" "$REGULAR" n
    run_one "$test" encoded "$repetition" "$ENCODED" y

    regular_output="$WORK/$test-regular-$repetition.txt"
    encoded_output="$WORK/$test-encoded-$repetition.txt"
    regular_hash="$(grep '^Verification Hash:' "$regular_output")"
    encoded_hash="$(grep '^Verification Hash:' "$encoded_output")"

    [[ "$regular_hash" == "$encoded_hash" ]] || {
      echo "Verification failed: $test hashes differ"
      exit 1
    }
    cmp "$WORK/$test-regular-$repetition.db" "$WORK/$test-encoded-$repetition.db"
  done
done

echo
echo "Benchmark results (arithmetic means)"
printf '%-9s %-19s %14s %15s %24s %24s\n' \
  benchmark description 'regular time' 'regular RSS' 'encoded time' 'encoded RSS'

for test in "${TESTS[@]}"; do
  regular_time="$(average "$test" regular 3)"
  encoded_time="$(average "$test" encoded 3)"
  regular_rss="$(average "$test" regular 4)"
  encoded_rss="$(average "$test" encoded 4)"
  slowdown="$(awk -v a="$encoded_time" -v b="$regular_time" 'BEGIN {if(b>0)printf "%.2f", a/b; else printf "n/a"}')"
  increase="$(awk -v a="$encoded_rss" -v b="$regular_rss" 'BEGIN {if(b>0)printf "%.2f", a/b; else printf "n/a"}')"
  regular_mib="$(awk -v n="$regular_rss" 'BEGIN {printf "%.1f", n/1024}')"
  encoded_mib="$(awk -v n="$encoded_rss" 'BEGIN {printf "%.1f", n/1024}')"

  printf '%-9s %-19s %12.2fs %12s MiB %12.2fs (%5sx) %11s MiB (%5sx)\n' \
    "$test" "$(description "$test")" \
    "$regular_time" "$regular_mib" \
    "$encoded_time" "$slowdown" \
    "$encoded_mib" "$increase"
done

echo "Verification passed; temporary databases were removed."
