#!/usr/bin/env bash
set -euo pipefail
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
[[ -x "$WT" ]] || { echo "Build the runtime first (see root README)" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -qx wasm32-wasip1 || {
  echo "Install the WASI target first: rustup target add wasm32-wasip1" >&2; exit 1;
}
mkdir -p "$HERE/build"
rustc --edition 2024 -C opt-level=3 --target wasm32-wasip1 "$HERE/fib.rs" -o "$HERE/build/fibonacci.wasm"
"$WT" compile -C cache=n -C an-encoding=n "$HERE/build/fibonacci.wasm" -o "$HERE/build/fibonacci.off.cwasm"
"$WT" compile -C cache=n -C an-encoding=y "$HERE/build/fibonacci.wasm" -o "$HERE/build/fibonacci.an.cwasm"
