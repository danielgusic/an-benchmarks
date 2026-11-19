
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
mkdir -p "$HERE/build"
CARGO_TARGET_DIR="$HERE/target" cargo build --locked --release --manifest-path "$HERE/Cargo.toml"
"$WT" compile -C cache=n -C an-encoding=n "$HERE/target/wasm32-wasip1/release/bubblesort.wasm" -o "$HERE/build/bubblesort.off.cwasm"
"$WT" compile -C cache=n -C an-encoding=y "$HERE/target/wasm32-wasip1/release/bubblesort.wasm" -o "$HERE/build/bubblesort.an.cwasm"
