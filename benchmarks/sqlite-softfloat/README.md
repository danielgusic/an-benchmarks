# SQLite benchmark

This benchmark compares regular Wasmtime with the AN-encoded runtime using
SQLite's official `speedtest1` benchmark. It is intended for comparing the performance of [wasmtime](https://github.com/bytecodealliance/wasmtime) with [wasmtime-an](https://github.com/danielgusic/wasmtime-an).

## Repository layout

```text
an-benchmark/
├── build-deps.sh                builds the shared dependencies
├── deps/
│   ├── wasm-float-transpiler/    Git submodule
│   └── wasmtime-an/              Git submodule
└── benchmarks/sqlite-softfloat/
    ├── sqlite/                 regular SQLite amalgamation (manual download)
    │   ├── sqlite3.c
    │   └── sqlite3.h
    ├── speedtest1.c            SQLite test driver (manual download)
    ├── setup.sh                builds and precompiles the SQLite modules
    ├── run.sh                  runs and measures the benchmark
    └── build/                  generated files
```

The `sqlite/`, `speedtest1.c`, and `build/` paths are ignored by Git. The first
two need to be downloaded manually, the last one is created by `setup.sh`.

## Setup

From the `an-benchmark` repository root, initialize the pinned submodules:

```bash
git submodule update --init --recursive
```

Install (if not already present):

- stable Rust and Cargo
- the Rust `wasm32-wasip1` and `wasm32-unknown-unknown` targets
- clang [WASI SDK](https://github.com/WebAssembly/wasi-sdk)
- `/usr/bin/time`

For a rustup installation, add the targets used by the dependency build with:

```bash
rustup toolchain install stable
rustup target add --toolchain stable wasm32-wasip1 wasm32-unknown-unknown
```

Download the [SQLite amalgamation](https://sqlite.org/download.html) and put
`sqlite3.c` and `sqlite3.h` in `benchmarks/sqlite-softfloat/sqlite/`. Then download SQLite's official [`speedtest1.c`](https://sqlite.org/src/file/test/speedtest1.c) and put it in
`benchmarks/sqlite-softfloat/`. Use regular, unmodified SQLite here, **not**
`deps/an-able-sqlite`, which belongs to the integer-only benchmark. Ideally, use `speedtest1.c` from the same SQLite release
as the amalgamation.

From the repository root, point the build at your WASI SDK and run:

```bash
export WASI_SDK_DIR=/absolute/path/to/wasi-sdk
./build-deps.sh
cd benchmarks/sqlite-softfloat
./setup.sh
```

`build-deps.sh` builds the pinned shared dependencies. `setup.sh` compiles
regular SQLite, applies the soft float transpiler, and precompiles both
configurations with Wasmtime. Dependencies are not updated to remote branch tips.
All commands below run from `benchmarks/sqlite-softfloat/`.

The comparison measures the combined cost of soft floats and AN encoding:
original Wasm with AN off versus transpiled Wasm with AN on, both using the fork.

## Running the benchmark

For each repetition, the script runs four SQLite workload families: mixed SQL
and OLTP (`main`), short ORM-style lookups (`orm`), floating-point-heavy SQL
(`fp`), and analytical star-schema joins (`star`). Each is run once with
regular Wasmtime and once with AN encoding, using a fresh
database. The final table reports mean wall-clock time, mean peak memory usage,
and the encoded-to-regular ratios.

`repetitions` is the number of complete regular/encoded measurements collected
for every workload. `size` is SQLite speedtest1's scale, so increasing
it increases the amount of data and number of operations performed.

The default is 3 repetitions with a speedtest size of 25:

```bash
./run.sh
```

The two optional arguments are the repetition count and size. For example:

```bash
./run.sh 5 50
```

All benchmark output and the final comparison table go to stdout. Redirect or
pipe it only if you want to keep a copy:

```bash
./run.sh 3 25 | tee results.txt
```

After each pair, the script checks that the verification hashes and database
files match to ensure both version produced the same result.
Temporary output and database files are removed again after finishing.

## Running a test manually

The precompiled modules can also be run directly without `run.sh`. Choose a
test set and size, create a directory for the generated databases, and run both
configurations.

Create a fresh directory where the DBs are saved (use a new directory for each run):
```bash
mkdir -p manual-run
```

Unencoded:
```bash
../../deps/wasmtime-an/target/release/wasmtime run --dir "./manual-run::/benchmark" --allow-precompiled -C cache=n -C an-encoding=n ./build/speedtest1.regular.cwasm --size 25 --big-transactions --verify --testset main /benchmark/regular.db
```

Encoded:
```bash
../../deps/wasmtime-an/target/release/wasmtime run --dir "./manual-run::/benchmark" --allow-precompiled -C cache=n -C an-encoding=y ./build/speedtest1.encoded.cwasm --size 25 --big-transactions --verify --testset main /benchmark/encoded.db
```

You have to use `-C an-encoding=y` with the encoded version and `-C an-encoding=n` with the regular version.

`--size` is the size, `--big-transactions` adds `BEGIN` and `END` around large tests, `--testset` is the benchmark that is to be run (e.g. `main`, `orm`, `fp`, `star`, `cte`, `json`, `trigger`, `parsenumber`, `app` (seems to break for WASM), `rtree`, `debug1`), `--verify` computes hashes that are used to verify that both version produce the same results.

For further flags look into `speedtest1.c`.

See the [root requirements](../../README.md#workflow-and-system-requirements)
for native build tools and shell utilities. Setup additionally uses the WASI SDK
`llvm-nm` binary. `WASMTIME_BIN` overrides the CLI for both setup and run;
re-run setup when changing it. Use matching SQLite and speedtest1 releases
for reproducible measurements, and record the release with your results.
