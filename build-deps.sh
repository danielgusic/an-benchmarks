#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${WASI_SDK_DIR:?Set WASI_SDK_DIR to your unpacked WASI SDK}"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
for dep in wasmtime-an wasm-float-transpiler wasm-point-oc; do
  [[ -f "$ROOT/deps/$dep/Cargo.toml" ]] || {
    echo "Missing $dep; run git submodule update --init --recursive first" >&2; exit 1;
  }
done
[[ -f "$ROOT/deps/an-able-sqlite/sqlite3.c" && -x "$WASI_SDK_DIR/bin/clang" ]] || {
  echo "Missing an-able-sqlite sources or WASI SDK clang" >&2; exit 1;
}
for target in wasm32-wasip1 wasm32-unknown-unknown; do
  rustup target list --installed | grep -qx "$target" || {
    echo "Run rustup target add --toolchain $RUSTUP_TOOLCHAIN $target first" >&2; exit 1;
  }
done

echo "==> Build Wasmtime"
CARGO_TARGET_DIR="$ROOT/deps/wasmtime-an/target" cargo build --locked --release \
  --manifest-path "$ROOT/deps/wasmtime-an/Cargo.toml" \
  --no-default-features --features run,compile,cranelift --bin wasmtime

echo "==> Build float transpiler and APFloat backend"
CARGO_TARGET_DIR="$ROOT/deps/wasm-float-transpiler/target" cargo build --locked --release \
  --manifest-path "$ROOT/deps/wasm-float-transpiler/Cargo.toml" -p wasm-float-transpiler
CARGO_TARGET_DIR="$ROOT/deps/wasm-float-transpiler/target" cargo build --locked --release \
  --manifest-path "$ROOT/deps/wasm-float-transpiler/Cargo.toml" \
  --target wasm32-wasip1 -p wasm-soft-float-apfloat

echo "==> Build integer-only SQLite"
mkdir -p "$ROOT/benchmarks/sqlite-integer/build"
"$WASI_SDK_DIR/bin/clang" --sysroot="$WASI_SDK_DIR/share/wasi-sysroot" \
  --target=wasm32-wasip1 -O3 \
  -D__minux -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID \
  -DSQLITE_OMIT_FLOATING_POINT -DSQLITE_OMIT_TRACE -DSQLITE_NOHAVE_SYSTEM -DSQLITE_OMIT_JSON \
  -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_TEMP_STORE=3 \
  "$ROOT/deps/an-able-sqlite/shell.c" "$ROOT/deps/an-able-sqlite/sqlite3.c" \
  -lc-printscan-no-floating-point -lwasi-emulated-signal -lwasi-emulated-getpid \
  -o "$ROOT/benchmarks/sqlite-integer/build/sqlite.wasm"
echo "==> Build point-OC guest"
CARGO_TARGET_DIR="$ROOT/deps/wasm-point-oc/target" cargo build --locked --release \
  --target wasm32-unknown-unknown --manifest-path "$ROOT/deps/wasm-point-oc/Cargo.toml"
echo "==> Dependencies built. Follow each benchmark README for setup and execution."
