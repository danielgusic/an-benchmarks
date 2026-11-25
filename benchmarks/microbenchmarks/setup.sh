#!/usr/bin/env bash
# Builds micro-host and every guest into build/<name>.wasm:
#   guests/rust/<crate>  -> build/<lib name>.wasm   (wasm32-unknown-unknown)
#   guests/c/<dir>/*.c   -> build/<dir>.wasm         (WASI SDK clang, reactor)
# A guests/c/<dir>/cflags file, if present, adds extra compiler flags
# (whitespace-separated) for that guest.
set -euo pipefail
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WASI_SDK_DIR="${WASI_SDK_DIR:-/opt/wasi-sdk}"
BUILD="$HERE/build"

[[ -f "$ROOT/deps/wasmtime-an/Cargo.toml" ]] || {
  echo "Missing wasmtime-an; run git submodule update --init --recursive first" >&2; exit 1;
}
rustup target list --installed 2>/dev/null | grep -qx wasm32-unknown-unknown || {
  echo "Run rustup target add --toolchain $RUSTUP_TOOLCHAIN wasm32-unknown-unknown first" >&2; exit 1;
}

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Build micro-host"
cargo build --locked --release --manifest-path "$HERE/host/Cargo.toml"

echo "==> Build Rust guests"
# Not --locked: adding a guest crate changes the lock file (guests have no
# external dependencies, so nothing is resolved from the network).
cargo build --release --target wasm32-unknown-unknown \
  --manifest-path "$HERE/guests/rust/Cargo.toml"
for wasm in "$HERE"/guests/rust/target/wasm32-unknown-unknown/release/*.wasm; do
  [[ -e "$wasm" ]] || continue
  cp "$wasm" "$BUILD/"
  echo "    $(basename "$wasm")"
done

echo "==> Build C guests"
for dir in "$HERE"/guests/c/*/; do
  name="$(basename "$dir")"
  [[ "$name" == include ]] && continue
  sources=("$dir"*.c)
  [[ -e "${sources[0]}" ]] || continue
  [[ -x "$WASI_SDK_DIR/bin/clang" ]] || {
    echo "C guest $name needs the WASI SDK; set WASI_SDK_DIR (tried $WASI_SDK_DIR)" >&2; exit 1;
  }
  extra=()
  [[ -f "$dir/cflags" ]] && read -r -a extra < "$dir/cflags"
  "$WASI_SDK_DIR/bin/clang" --sysroot="$WASI_SDK_DIR/share/wasi-sysroot" \
    --target=wasm32-wasip1 -O3 -mno-simd128 -mexec-model=reactor \
    -Wall -Wextra -I "$HERE/guests/c/include" ${extra[@]+"${extra[@]}"} \
    "${sources[@]}" -o "$BUILD/$name.wasm"
  echo "    $name.wasm"
done

echo "==> Done. Guests are in build/; register them in benches.conf."
