# Integer-only SQLite

Uses only `../../deps/an-able-sqlite`, the modified float-free amalgamation.
It does **not** use the regular SQLite supplied to the soft-float benchmark.

Complete the [root dependency setup](../../README.md), then from this directory:

```bash
./setup.sh 1000000
./run.sh all 5
# Or select one workload:
./run.sh i32 5
./run.sh i64 5
```

The root `build-deps.sh` builds the integer module with `-O3`. `setup.sh`
precompiles AN-off/on modules and creates the synthetic database. Each timed
repetition uses a fresh copy. Compilation and copying are outside the timer;
process startup remains included. Scripts report wall time and peak RSS.

For the employees workload:

```bash
./setup_employees.sh
./run_employees.sh 5
```
