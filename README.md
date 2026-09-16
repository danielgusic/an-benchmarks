# AN-encoded wasmtime benchmarks

A collection of some benchmarks for [wasmtime-an](https://github.com/danielgusic/wasmtime-an).

| Benchmark | Source | Instructions |
|---|---|---|
| Integer-only SQLite: some i32/i64 and employees (string heavy) | Modified `an-able-sqlite` | [README](benchmarks/sqlite-integer/README.md) |
| SQLite speedtest1 with soft floats | Official SQLite | [README](benchmarks/sqlite-softfloat/README.md) |
| Point object controller | `wasm-point-oc` guest, local Rust host | [README](benchmarks/point-oc/README.md) |
| Iterative Fibonacci | Local Rust program | [README](benchmarks/fibonacci/README.md) |

## Dependencies

Run
```bash
git submodule update --init --recursive
```

Install stable Rust/Cargo and the clang [WASI SDK](https://github.com/WebAssembly/wasi-sdk), then run:

```bash
rustup target add --toolchain stable wasm32-wasip1 wasm32-unknown-unknown
export WASI_SDK_DIR=/absolute/path/to/wasi-sdk
./build-deps.sh
```

This builds the shared release Wasmtime CLI, float transpiler and APFloat backend,
integer-only SQLite module, and point-OC guest. 

Then follow the instructions in an individual benchmark's `README.md`.
These may also contain instructions for further dependencies.
