# Microbenchmark harness

A harness for microbenchmarking WASM modules.

I includes 2 modes:
- Regular microbenchmarks to benchmark performance
- Fault injection to benchmark safety 

Follow the [root dependency setup](../../README.md) first, then (from this directory) run:
directory:

```bash
./setup.sh                                  # build micro-host and all guests into build/
```

## Performance
To benchamrk performance, use `run.sh`. `run.sh 100` performs 100 experiments.
You can set the following options via environment variables:
- `REPS` repetitions per benchmark and mode, default is 5
- `BENCHES` pick the benches you have registered in `benches.conf` (default all)
- `MODES` either `off` or `an` (default `off an` (both))
- `AN_CONSTANT` set the AN constant (default 65521)
- `BENCH_CONF` path to a config file (default `benches.conf`)

## Fault injection
To benchmark with fault injection, use `inject.sh`. `inject.sh 100` performs 100 experiments.
You can set the following options via environment variables:
- `REGIONS` the meory regions that are targeted, `,` separated (options are `memory`, `shadow`, `stack`, `code`, `runtime`, default: `memory`)
- `WIGHTING` `size` if a bit should be selected uniformly from all bits or `equal` if first a region should be selected equally and then uniform one bit within the region
- `SEED` the seed (default `0`)
- `JOBS` number of experiments run in parallel (default `1`)
- `TIMEOUT_FACTOR` result times out after this many golden run times (default `10`)
- `BENCHES`, `MODE`, `AN_CONSTANT`, `BENCH_CONF` same as for performance

More docs coming soon™
