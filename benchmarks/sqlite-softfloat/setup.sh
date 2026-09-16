#!/usr/bin/env bash
set -euo pipefail
exec 2>&1

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
SQLITE_SOURCE="$ROOT/../../deps/sqlite"
SQLITE="$BUILD/sqlite"
SPEEDTEST="$SQLITE_SOURCE/test/speedtest1.c"
WASMTIME_SOURCE="$ROOT/../../deps/wasmtime-an"
TRANSPILER_SOURCE="$ROOT/../../deps/wasm-float-transpiler"

: "${WASI_SDK_DIR:?Set WASI_SDK_DIR to your unpacked WASI SDK}"

CLANG="$WASI_SDK_DIR/bin/clang"
LLVM_NM="$WASI_SDK_DIR/bin/llvm-nm"
WASMTIME="${WASMTIME_BIN:-$WASMTIME_SOURCE/target/release/wasmtime}"
TRANSPILER="$TRANSPILER_SOURCE/target/release/wasm-float-transpiler"
SOFT_FLOAT="$TRANSPILER_SOURCE/target/wasm32-wasip1/release/libwasm_soft_float_apfloat.a"

REGULAR_WASM="$BUILD/speedtest1.regular.wasm"
ENCODED_WASM="$BUILD/speedtest1.encoded.wasm"
REGULAR_CWASM="$BUILD/speedtest1.regular.cwasm"
ENCODED_CWASM="$BUILD/speedtest1.encoded.cwasm"

mkdir -p "$BUILD"

for source in "$WASMTIME_SOURCE/Cargo.toml" "$TRANSPILER_SOURCE/Cargo.toml" "$SQLITE_SOURCE/configure" "$SPEEDTEST"; do
  [[ -f "$source" ]] || { echo "Missing $source; run git submodule update --init --recursive" >&2; exit 1; }
done

for binary in "$CLANG" "$LLVM_NM" "$WASMTIME" "$TRANSPILER"; do
  [[ -x "$binary" ]] || { echo "Missing $binary; run ../../build-deps.sh first" >&2; exit 1; }
done
[[ -f "$SOFT_FLOAT" ]] || { echo "Missing $SOFT_FLOAT; run ../../build-deps.sh first" >&2; exit 1; }

# Generate the amalgamation with native tools, then cross-compile it below.
# Recreate it on each setup so changing the submodule cannot reuse stale sources.
echo "==> Generate SQLite amalgamation"
mkdir -p "$SQLITE"
(
  cd "$SQLITE"
  "$SQLITE_SOURCE/configure" --disable-tcl --disable-readline
  make -B sqlite3.c sqlite3.h
)

# The transpiler turns leaf functions into functions which call soft-float
# helpers. Disabling the red zone prevents those new calls from overwriting
# stack data which Clang originally considered safe below the stack pointer.
CFLAGS=(
  --target=wasm32-wasip1
  "--sysroot=$WASI_SDK_DIR/share/wasi-sysroot"
  -O3
  -Xclang -disable-red-zone
  -DSQLITE_THREADSAFE=0
  -DSQLITE_TEMP_STORE=3
  -DSQLITE_SPEEDTEST1_WASM
  "-I$SQLITE"
  "$SPEEDTEST"
  "$SQLITE/sqlite3.c"
)

echo "==> Compile regular SQLite"
"$CLANG" "${CFLAGS[@]}" -o "$REGULAR_WASM"

echo "==> Compile and transpile encoded SQLite"
EXPORTS=()
SYMBOLS="$("$LLVM_NM" --defined-only "$SOFT_FLOAT" \
  | awk '$2 == "T" && $3 ~ /^__wasm_soft_float_/ {print $3}' | sort -u)"
[[ -n "$SYMBOLS" ]] || { echo "No soft-float helper exports found in $SOFT_FLOAT" >&2; exit 1; }
while read -r symbol; do
  EXPORTS+=("-Wl,--export=$symbol")
done <<< "$SYMBOLS"

WITH_HELPERS="$BUILD/speedtest1.with-helpers.wasm"
"$CLANG" "${CFLAGS[@]}" "$SOFT_FLOAT" "${EXPORTS[@]}" -o "$WITH_HELPERS"
"$TRANSPILER" "$WITH_HELPERS" "$ENCODED_WASM"
rm "$WITH_HELPERS"

echo "==> Precompile both modules"
"$WASMTIME" compile -C cache=n -C an-encoding=n "$REGULAR_WASM" -o "$REGULAR_CWASM"
"$WASMTIME" compile -C cache=n -C an-encoding=y "$ENCODED_WASM" -o "$ENCODED_CWASM"

echo "==> Done. Run ./run.sh"
