# AN runtime benchmarks

A collection of some benchmarks for [wasmtime-an](https://github.com/danielgusic/wasmtime-an).

| Benchmark | Source | Instructions |
|---|---|---|
| Integer-only SQLite: some i32/i64 and employees (string heavy) | Modified `an-able-sqlite` | [README](benchmarks/sqlite-integer/README.md) |
| SQLite speedtest1 with soft floats | Manual download of regular SQLite | [README](benchmarks/sqlite-softfloat/README.md) |
| Point object controller | `wasm-point-oc` guest, local Rust host | [README](benchmarks/point-oc/README.md) |
| Iterative Fibonacci | Local Rust program | [README](benchmarks/fibonacci/README.md) |

## Dependencies

Run
```bash
git submodule update --init --recursive
```

This also fetches the pinned employees sample data into `deps/test_db`.
The employees setup script loads that local data into SQLite without downloading it.

Install stable Rust/Cargo and the [WASI SDK](https://github.com/WebAssembly/wasi-sdk), then run:

```bash
rustup target add --toolchain stable wasm32-wasip1 wasm32-unknown-unknown
export WASI_SDK_DIR=/absolute/path/to/wasi-sdk
./build-deps.sh
```

This builds the shared release Wasmtime CLI, float transpiler and APFloat backend,
integer-only SQLite module, and point-OC guest. It uses stable Rust by
default; `RUSTUP_TOOLCHAIN` can override it. It does not generate benchmark datasets
or download regular SQLite and `speedtest1.c`.

Then follow the instructions in an individual benchmark's `README.md`.

## Workflow and system requirements

Use Bash on Linux or macOS. Install Git, rustup with stable Rust (edition 2024),
a native C/C++ compiler and linker (Xcode Command Line Tools on macOS; a build
toolchain such as `build-essential` on Debian/Ubuntu), and a recent WASI SDK
whose Clang supports `--target=wasm32-wasip1`. The SDK must include `llvm-nm`
and the WASI sysroot. Cargo needs network access on the first build to fetch
locked crates and Git dependencies.

The measurement scripts require `/usr/bin/time` (GNU time on Linux, BSD time
on macOS), plus standard utilities: awk, sed, grep, sort, stat, mktemp, cmp,
diff, tee, and core file utilities. Flamegraphs have additional Linux-only
requirements in the [point-OC README](benchmarks/point-oc/README.md).

1. Run `./build-deps.sh` once from the repository root, and again after changing
   dependency sources or the Rust/WASI toolchain. This owns all dependency builds.
2. Run `./setup.sh` inside each desired benchmark directory. Setup prepares local
   modules, host binaries, and/or datasets; it does not rebuild dependency projects.
3. Run `./run.sh` in that directory. Timed runs never build dependencies.

Scripts resolve files relative to their own location and can also be invoked
by absolute path. Rust build scripts default to `RUSTUP_TOOLCHAIN=stable`;
set that variable consistently to override it, installing both targets for the
selected toolchain. `WASMTIME_BIN` selects a different CLI for Fibonacci and
both SQLite benchmarks; point-OC embeds the pinned runtime as a Rust library.
Re-run benchmark setup after rebuilding or selecting a runtime: `.cwasm` files
are native artifacts tied to the runtime and machine that compiled them.
