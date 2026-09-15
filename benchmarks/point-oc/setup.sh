#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
[[ -f "$ROOT/deps/wasm-point-oc/target/wasm32-unknown-unknown/release/point-oc.wasm" ]] || {
  echo "Missing point-OC guest; run the root build-deps.sh first" >&2; exit 1;
}
CARGO_TARGET_DIR="$HERE/target" cargo build --locked --release --manifest-path "$HERE/Cargo.toml"
