#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUEST="$ROOT/deps/mibench/telecomm/CRC32/crc_32.wasm"
WT="${WASMTIME_BIN:-$ROOT/deps/wasmtime-an/target/release/wasmtime}"
[[ -x "$WT" ]] || { echo "Build the runtime first (see root README)" >&2; exit 1; }
[[ -x "$GUEST" ]] || { echo "Build the guest module first (see root README)" >&2; exit 1; }
mkdir -p "$HERE/build"
"$WT" compile -C cache=n -C an-encoding=n "$GUEST" -o "$HERE/build/crc_32.off.cwasm"
"$WT" compile -C cache=n -C an-encoding=y "$GUEST" -o "$HERE/build/crc_32.an.cwasm"
