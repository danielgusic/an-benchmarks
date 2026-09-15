# Fibonacci

An iterative Fibonacci benchmark. Each Wasm invocation
repeats the calculation and prints one checksum to reduce overhead.

Complete the [root dependency setup](../../README.md) first, then from this directory:

```bash
./setup.sh
./run.sh 35 5 1000000000   # Fibonacci input, process repetitions, iterations per process
```

`WASMTIME_BIN` can select another runtime for both setup and execution.
Setup compiles `fib.rs` with `rustc -C opt-level=3 --target wasm32-wasip1` and
precompiles AN-off/on modules.
Run prints raw process timings and peak RSS using `/usr/bin/time` (macOS's native RSS output
is bytes; Linux's is KiB).
Process startup and printing are included, compilation is excluded.

Requires rustup, stable rustc with the `wasm32-wasip1` target, the shared
Wasmtime CLI, Bash, and `/usr/bin/time` plus the root-listed utilities.

Defaults are N=35, 5 process repetitions per mode, and 1 billion calculations
per process.
