#!/usr/bin/env bash
# One-time setup for the SQLite speedtest1 comparison benchmark. Times nothing.
#
#   ./setup.sh
#
# Builds speedtest1 + official SQLite ($SQLITE_TAG, default version-3.53.2)
# twice, with identical compiler flags:
#   native    : regular f32/f64 instructions
#   softfloat : f32/f64 rewritten into APFloat soft-float helper calls by
#               wasm-float-transpiler
# and precompiles the three modules that run.sh compares:
#   build/speedtest1.native.off.cwasm     native floats, AN encoding off
#   build/speedtest1.softfloat.off.cwasm  soft floats,   AN encoding off
#   build/speedtest1.softfloat.an.cwasm   soft floats,   AN encoding on
set -euo pipefail
[[ $# -eq 0 ]] || { echo "usage: $0" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"
: "${WASI_SDK_DIR:?Set WASI_SDK_DIR to your unpacked WASI SDK}"
SQLITE_TAG="${SQLITE_TAG:-version-3.53.2}"

CLANG="$WASI_SDK_DIR/bin/clang"
LLVM_NM="$WASI_SDK_DIR/bin/llvm-nm"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
TRANSPILER_SOURCE="$ROOT/deps/wasm-float-transpiler"
TRANSPILER="$TRANSPILER_SOURCE/target/release/wasm-float-transpiler"
SOFT_FLOAT="$TRANSPILER_SOURCE/target/wasm32-wasip1/release/libwasm_soft_float_apfloat.a"
SQLITE_SOURCE="$ROOT/deps/sqlite"

file_size_mb() { echo $(( $( stat -c %s "$1" 2>/dev/null || stat -f %z "$1" ) / 1048576 )); }

for binary in "$CLANG" "$LLVM_NM" "$WT" "$TRANSPILER"; do
  [[ -x "$binary" ]] || { echo "Missing $binary; run ../../build-deps.sh first" >&2; exit 1; }
done
[[ -f "$SOFT_FLOAT" ]] || { echo "Missing $SOFT_FLOAT; run ../../build-deps.sh first" >&2; exit 1; }
[[ -f "$SQLITE_SOURCE/configure" ]] || {
  echo "Missing $SQLITE_SOURCE; run git submodule update --init --recursive" >&2; exit 1;
}

mkdir -p "$BUILD"

# The submodule's pinned commit (used by ../sqlite-softfloat) is left alone;
# the requested tag is exported into build/ instead.
echo "==> Export official SQLite $SQLITE_TAG and generate the amalgamation"
if ! git -C "$SQLITE_SOURCE" rev-parse -q --verify "refs/tags/$SQLITE_TAG" >/dev/null; then
  git -C "$SQLITE_SOURCE" fetch --depth 1 origin tag "$SQLITE_TAG"
fi
rm -rf "$BUILD/sqlite-src" "$BUILD/sqlite-amalg"
mkdir -p "$BUILD/sqlite-src" "$BUILD/sqlite-amalg"
git -C "$SQLITE_SOURCE" archive "$SQLITE_TAG" | tar -x -C "$BUILD/sqlite-src"
(
  cd "$BUILD/sqlite-amalg"
  "$BUILD/sqlite-src/configure" --disable-tcl --disable-readline > configure.log 2>&1
  make sqlite3.c sqlite3.h > make.log 2>&1
)
echo "    SQLite $(awk '/^#define SQLITE_VERSION /{gsub(/"/,"",$3); print $3; exit}' "$BUILD/sqlite-amalg/sqlite3.c")"

# Same flags as ../sqlite-softfloat. The transpiler adds calls to leaf
# functions, so the red zone must be disabled; the native build gets the same
# flag so both builds share identical codegen apart from float handling.
CFLAGS=(
  --target=wasm32-wasip1 "--sysroot=$WASI_SDK_DIR/share/wasi-sysroot" -O3
  -Xclang -disable-red-zone
  -DSQLITE_THREADSAFE=0 -DSQLITE_TEMP_STORE=3 -DSQLITE_SPEEDTEST1_WASM
  "-I$BUILD/sqlite-amalg"
  "$BUILD/sqlite-src/test/speedtest1.c" "$BUILD/sqlite-amalg/sqlite3.c"
)

echo "==> Compile native-float speedtest1"
"$CLANG" "${CFLAGS[@]}" -o "$BUILD/speedtest1.native.wasm"

echo "==> Compile soft-float speedtest1 and transpile floats"
EXPORTS=()
SYMBOLS="$("$LLVM_NM" --defined-only "$SOFT_FLOAT" \
  | awk '$2 == "T" && $3 ~ /^__wasm_soft_float_/ {print $3}' | sort -u)"
[[ -n "$SYMBOLS" ]] || { echo "No soft-float helper exports found in $SOFT_FLOAT" >&2; exit 1; }
while read -r symbol; do EXPORTS+=("-Wl,--export=$symbol"); done <<< "$SYMBOLS"
"$CLANG" "${CFLAGS[@]}" "$SOFT_FLOAT" "${EXPORTS[@]}" -o "$BUILD/speedtest1.softfloat.with-helpers.wasm"
"$TRANSPILER" "$BUILD/speedtest1.softfloat.with-helpers.wasm" "$BUILD/speedtest1.softfloat.wasm"
rm -f "$BUILD/speedtest1.softfloat.with-helpers.wasm"

echo "==> Precompile 3 modules"
"$WT" compile -C cache=n -C an-encoding=n "$BUILD/speedtest1.native.wasm"    -o "$BUILD/speedtest1.native.off.cwasm"
"$WT" compile -C cache=n -C an-encoding=n "$BUILD/speedtest1.softfloat.wasm" -o "$BUILD/speedtest1.softfloat.off.cwasm"
"$WT" compile -C cache=n -C an-encoding=y "$BUILD/speedtest1.softfloat.wasm" -o "$BUILD/speedtest1.softfloat.an.cwasm"
for m in native.off softfloat.off softfloat.an; do
  printf "    %-14s %s MB\n" "$m" "$(file_size_mb "$BUILD/speedtest1.$m.cwasm")"
done

echo "==> Setup done. Now run ./run.sh"
