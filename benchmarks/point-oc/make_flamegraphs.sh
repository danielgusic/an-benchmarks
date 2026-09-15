#!/usr/bin/env bash
#
# Regenerate the four point-oc flamegraphs in example_flamegraphs/.
#
# Measures the point-oc guest under the point-oc-host embedder, AN-encoding off
# vs on, for both a debug and a release guest build. Uses perf via cargo
# flamegraph with frame-pointer unwinding (so the JIT'd wasm/AN frames symbolize
# across the wasm boundary) and the host's --perfmap flag.
#
# Requires: rustup, perf, cargo-flamegraph, wasm32-unknown-unknown target.
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
[[ "$(uname -s)" == Linux ]] || { echo "Flamegraphs require Linux perf" >&2; exit 1; }
command -v perf >/dev/null || { echo "Install Linux perf first (see README)" >&2; exit 1; }
command -v cargo-flamegraph >/dev/null || { echo "Run cargo install flamegraph --locked first" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_DIR="$HERE/../../deps/wasm-point-oc"
OUT="$HERE/example_flamegraphs"

# Telegram counts are picked so each run takes a few wall-clock seconds:
BENCH_OFF_DEBUG=4000000
BENCH_OFF_RELEASE=14000000
BENCH_ON=4000000

PERF_ARGS="record -F 997 --call-graph fp -g"

echo ">> building guest (debug + release)"
( cd "$GUEST_DIR"
  CARGO_TARGET_DIR="$GUEST_DIR/target" cargo build --locked --target wasm32-unknown-unknown
  CARGO_TARGET_DIR="$GUEST_DIR/target" cargo build --locked --release --target wasm32-unknown-unknown
)

echo ">> building host (profiling profile)"
( cd "$HERE" && CARGO_TARGET_DIR="$HERE/target" cargo build --locked --profile profiling )

REL_WASM="$GUEST_DIR/target/wasm32-unknown-unknown/release/point-oc.wasm"
mkdir -p "$OUT"
cd "$HERE"

# flame <output.svg> <host-args...>
flame() {
  local svg="$1"; shift
  echo ">> $svg"
  CARGO_TARGET_DIR="$HERE/target" cargo flamegraph --locked --profile profiling -c "$PERF_ARGS" -o "$OUT/$svg" -- "$@" --perfmap
}

flame an-off.svg "$GUEST_DIR/target/wasm32-unknown-unknown/debug/point-oc.wasm" --bench "$BENCH_OFF_DEBUG"
flame an-on.svg "$GUEST_DIR/target/wasm32-unknown-unknown/debug/point-oc.wasm" --an --bench "$BENCH_ON"
flame an-off-release.svg "$REL_WASM"      --bench "$BENCH_OFF_RELEASE"
flame an-on-release.svg  "$REL_WASM" --an --bench "$BENCH_ON"

echo ">> done — wrote 4 flamegraphs to $OUT"
