# SQLite comparison

Runs SQLite's `speedtest1` with six configurations:

| | native floats, AN off | soft floats, AN off | soft floats, AN on |
|---|---|---|---|
| **mem** (`--memdb`, database is `:memory:`) | ✓ | ✓ | ✓ |
| **disk** (database file on the WASI `--dir` mount) | ✓ | ✓ | ✓ |


## Setup

Follow [root dependency setup](../../README.md), then run this from this directory:

```bash
export WASI_SDK_DIR=/absolute/path/to/wasi-sdk
./setup.sh
```

## Running

```bash
./run.sh                       # 3 reps, size 25, testsets main orm fp star
./run.sh 5 50                  # 5 reps, size 50
TESTSETS="main fp" ./run.sh    # choose testsets
```

The benchmarks performed are the same as in the [SQLite softfloat benchmark](../sqlite-softfloat/). There you can find more information.

- **mem** runs `speedtest1 --memdb`.
- **disk** runs `speedtest1 /w/<config>.db` on a fresh file.

Process startup, module loading and opening the database is not measured.

Raw measurements go to `results/<timestamp>.csv`. The full speedtest1 output,
including per-test times, goes to `outputs/<testset>_<storage>_<config>_rep<N>.txt`.
