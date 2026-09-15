# Point object controller

The guest is in `../../deps/wasm-point-oc`. Complete the [root dependency
setup](../../README.md) first, then run these commands from this directory.

```bash
./setup.sh
./run.sh 100000 5      # telegrams per run, repetitions; AN off and on
```

The root dependency build creates the release guest; local setup builds the release host.
The default guest path is resolved from the host's manifest directory, so
execution does not depend on the current working directory.

The host reports compilation, instantiation and guest execution separately,
including telegram throughput. Its scripted output oracle remains enabled.
The benchmark count is the number of telegrams, not full conversations.

For direct use, including existing fault injection options:

```bash
cargo run                          # AN-encoding off
cargo run -- --an                  # AN-encoding on (default A=65521)
cargo run -- --an --an-constant 1  # AN on, identity constant
cargo run -- --bench 100           # Run the scripted conversation 100 times
cargo run -- /path/to/other.wasm   # run a different guest
```

### Fault injection

The host can start a second thread that periodically flips one random bit in a
currently available guest-owned region. The RNG is deterministic for a given
seed, period, target list, and run shape. It uses a seeded ChaCha RNG from the
`rand` ecosystem.

```sh
cargo run -- --an --fault memory --fault-seed 1 --fault-count 10
cargo run -- --an --fault shadow --fault-seed 2 --fault-period-us 1000
cargo run -- --an --fault stack --fault-seed 3 --bench 1000
cargo run -- --an --fault all --fault-seed 4 --fault-count 100 --bench 10000
cargo run -- --an --fault memory --fault-seed 1 --fault-final-memory-check
```

`memory` targets the working memory, `shadow` targets the shadow memory and `stack` targets the stack.
`all` can be used to target the three of them at once.
The behavior is compared with an oracle for validation. 
This should catch any errors that were not caught by the encoding.
`--fault-final-memory-check` performs a comparison between the shadow and the working memory at the end, catching bit flips which did not have an effect on the execution.

## Flamegraphs (Linux only)

Install Linux `perf` for your running kernel using your distribution's package
manager, and install [cargo-flamegraph](https://github.com/flamegraph-rs/flamegraph):

```bash
cargo install flamegraph --locked
./make_flamegraphs.sh
```

The script requires perf recording permission under your system's
`perf_event_paranoid` policy, Rust/Cargo, the `wasm32-unknown-unknown` target,
and initialized submodules. 
It builds debug/release guests and a profiling host, then writes four SVGs to
`example_flamegraphs/`. This optional profiling workflow rebuilds its own
variants and is separate from the normal `setup.sh` / `run.sh` workflow.
