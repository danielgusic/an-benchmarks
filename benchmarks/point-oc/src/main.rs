//! Minimal wasmtime embedder ("host") for the `point-oc` guest module.
//!
//! `point-oc` is a railway point (switch) object controller compiled to wasm.
//! It imports three host functions from module `env`:
//!
//!   recv_msg(buf: *mut u8) -> usize    host writes the next SCI telegram into
//!                                       guest memory at `buf`, returns its length
//!   send_msg(msg: *const u8, len)      guest hands the host a response telegram
//!   move_point(cmd: i32) -> i32        physically move the switch
//!                                       cmd: 0 = Left, 1 = Right
//!                                       ret: 0 = EndPositionArrived, 1 = Trailed
//!
//! Its `main` is an infinite recv/handle/respond loop. We drive it by feeding a
//! scripted sequence of telegrams; when the inbox drains we make `recv_msg` trap
//! to unwind the loop, and treat that one trap as a clean shutdown.
//!
//! Usage:
//!   point-oc-host [WASM_PATH] [--an] [--an-constant N] [--bench N]
//!
//!   WASM_PATH       defaults to the release build of deps/wasm-point-oc
//!   --an            enable AN-encoding (Config::an_encoding)
//!   --an-constant N override the AN constant A
//!   --bench N       benchmark mode: cycle the scripted conversation until N
//!                   telegrams have been served, suppress per-telegram output,
//!                   and report wall time + telegrams/sec for the guest run
//!   --fault TARGETS periodically flip random bits in linear memory, the
//!                   encoded shadow, and/or the guest stack window
//!   --fault-seed N  deterministic seed for fault injection
//!   --fault-period-us N
//!                   delay between injected bit flips, in microseconds
//!   --fault-count N stop the injector after N successful flips
//!   --fault-final-memory-check
//!                   also report latent raw/shadow mismatches after the scripted
//!                   workload

use std::{collections::VecDeque, sync::Arc, time::Duration};

use anyhow::Result;
use fault::{
    FaultConfig, FaultRuntime, FaultTarget, parse_fault_targets, parse_u64_arg,
    refresh_initial_fault_regions, refresh_linear_fault_region, refresh_stack_fault_region,
    start_fault_injector,
};
use sci_rs::{
    SCIMessageType, SCITelegram,
    scip::{SCIPointLocation, SCIPointTargetLocation},
};
// Note: this fork's `wasmtime` has its own error type. Host closures must
// return `wasmtime::Result<T>`, so use wasmtime's `bail!`/`format_err!` there
// (there is a `From<wasmtime::Error> for anyhow::Error`, but not the reverse).
use wasmtime::{
    AsContext, CallHook, Caller, Config, Engine, Linker, Module, ProfilingStrategy, Store, bail,
    format_err,
};

mod fault;

const DEFAULT_WASM: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../deps/wasm-point-oc/target/wasm32-unknown-unknown/release/point-oc.wasm"
);
const CONTROLLER: &str = "IXL"; // the interlocking talking to the point
const POINT: &str = "P01"; // must match the guest's SELF_ID

/// Everything the host functions need to share.
struct HostState {
    /// Telegrams still to be delivered to the guest, in order.
    inbox: VecDeque<Vec<u8>>,
    /// Bench mode: the script to cycle through once `inbox` is drained.
    script: Vec<Vec<u8>>,
    /// Bench mode: how many telegrams are still to be served from `script`.
    remaining: usize,
    /// Bench mode: index of the next `script` entry to serve.
    cursor: usize,
    /// Suppress per-telegram output (bench mode).
    quiet: bool,
    /// Set once the inbox is empty so the final trap is recognised as clean.
    drained: bool,
    /// How many physical moves the guest requested.
    moves: usize,
    /// Expected response telegrams, used as the observable correctness oracle.
    expected_responses: VecDeque<Vec<u8>>,
    /// Expected `move_point` commands for the scripted conversation.
    expected_moves: VecDeque<i32>,
    /// How many response telegrams matched the oracle.
    responses: usize,
}

impl HostState {
    fn oracle_error(&self) -> Option<String> {
        if self.expected_responses.is_empty() && self.expected_moves.is_empty() {
            None
        } else {
            Some(format!(
                "output oracle incomplete: {} expected response(s) and {} expected move(s) were not observed",
                self.expected_responses.len(),
                self.expected_moves.len()
            ))
        }
    }
}

fn main() -> Result<()> {
    let mut wasm_path = DEFAULT_WASM.to_string();
    let mut an = false;
    let mut an_constant: Option<u64> = None;
    let mut bench: Option<usize> = None;
    let mut perfmap = false;
    let mut fault_targets: Option<Vec<FaultTarget>> = None;
    let mut fault_seed = 0u64;
    let mut fault_period = Duration::from_millis(10);
    let mut fault_count: Option<u64> = None;
    let mut fault_final_memory_check = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--an" => an = true,
            "--an-constant" => {
                an_constant = Some(
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--an-constant needs a value"))?
                        .parse()?,
                );
            }
            "--bench" => {
                bench = Some(
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--bench needs a telegram count"))?
                        .parse()?,
                );
            }
            "--perfmap" => perfmap = true,
            "--fault" => {
                let targets = args
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--fault needs a target list"))?;
                fault_targets = Some(parse_fault_targets(&targets)?);
            }
            "--fault-seed" => {
                fault_seed = parse_u64_arg(
                    "--fault-seed",
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--fault-seed needs a value"))?,
                )?;
            }
            "--fault-period-us" => {
                let micros = parse_u64_arg(
                    "--fault-period-us",
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--fault-period-us needs a value"))?,
                )?;
                if micros == 0 {
                    return Err(anyhow::anyhow!("--fault-period-us must be greater than 0"));
                }
                fault_period = Duration::from_micros(micros);
            }
            "--fault-count" => {
                fault_count = Some(parse_u64_arg(
                    "--fault-count",
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--fault-count needs a value"))?,
                )?);
            }
            "--fault-final-memory-check" => fault_final_memory_check = true,
            "-h" | "--help" => {
                println!(
                    "usage: point-oc-host [WASM_PATH] [--an] [--an-constant N] [--bench N] [--perfmap]\n\
                     \n\
                     fault injection:\n\
                       --fault TARGETS        comma-separated: memory,shadow,stack,all\n\
                       --fault-seed N         deterministic RNG seed (default 0)\n\
                       --fault-period-us N    delay between flips (default 10000)\n\
                       --fault-count N        stop after N successful flips\n\
                       --fault-final-memory-check\n\
                                             report latent raw/shadow mismatches after the run"
                );
                return Ok(());
            }
            other => wasm_path = other.to_string(),
        }
    }

    let fault_config = fault_targets
        .map(|targets| FaultConfig::new(targets, fault_seed, fault_period, fault_count));

    let mut config = Config::new();
    if an {
        config.an_encoding(true);
        if let Some(a) = an_constant {
            config.an_constant(a);
        }
    }
    if perfmap {
        // Emit /tmp/perf-<pid>.map so an external sampler (samply) can
        // symbolize the JIT-compiled wasm frames in the flamegraph.
        config.profiler(ProfilingStrategy::PerfMap);
    }

    println!(
        "host: loading {wasm_path}\nhost: AN-encoding {}{}\n",
        if an { "ON" } else { "off" },
        an_constant.map(|a| format!(" (A={a})")).unwrap_or_default(),
    );
    if let Some(config) = &fault_config {
        println!(
            "host: fault injection configured (targets={}, seed={}, period={:?}, count={})\n",
            config.target_list(),
            config.seed,
            config.period,
            config
                .max_flips
                .map(|n| n.to_string())
                .unwrap_or_else(|| "unlimited".to_string())
        );
        if config.uses_encoded_shadow() && !an {
            println!("host: note: shadow target requested while AN-encoding is off");
        }
    }
    let final_fault_memory_check = an
        && fault_final_memory_check
        && fault_config
            .as_ref()
            .is_some_and(FaultConfig::can_leave_memory_mismatch);
    if fault_final_memory_check && !final_fault_memory_check {
        println!(
            "host: note: final memory check is active only for AN memory/shadow fault campaigns"
        );
    }

    let compile_start = std::time::Instant::now();
    println!("host: compiling guest module");
    let engine = Engine::new(&config)?;
    let module = Module::from_file(&engine, &wasm_path)?;
    println!(
        "host: compiled guest module in {:.3?}",
        compile_start.elapsed()
    );

    let mut linker = Linker::new(&engine);

    // recv_msg(buf) -> len : pop the next scripted telegram into guest memory.
    linker.func_wrap(
        "env",
        "recv_msg",
        |mut caller: Caller<'_, HostState>, buf: i32| -> wasmtime::Result<i32> {
            let state = caller.data_mut();
            let bytes = if let Some(bytes) = state.inbox.pop_front() {
                bytes
            } else if state.remaining > 0 {
                // Bench mode: cycle through the script without materializing
                // millions of telegrams up front.
                let bytes = state.script[state.cursor].clone();
                state.cursor = (state.cursor + 1) % state.script.len();
                state.remaining -= 1;
                bytes
            } else {
                state.drained = true;
                bail!("inbox drained — unwinding the guest loop");
            };
            let mem = caller
                .get_export("memory")
                .and_then(|e| e.into_memory())
                .ok_or_else(|| format_err!("guest has no exported memory"))?;
            mem.write(&mut caller, buf as usize, &bytes)?;
            if !caller.data().quiet {
                println!("  → recv  {}", describe(&bytes));
            }
            Ok(bytes.len() as i32)
        },
    )?;

    // send_msg(ptr, len) : read a response telegram out of guest memory.
    linker.func_wrap(
        "env",
        "send_msg",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| -> wasmtime::Result<()> {
            let mem = caller
                .get_export("memory")
                .and_then(|e| e.into_memory())
                .ok_or_else(|| format_err!("guest has no exported memory"))?;
            let mut bytes = vec![0u8; len as usize];
            mem.read(&caller, ptr as usize, &mut bytes)?;
            {
                let state = caller.data_mut();
                let expected = state.expected_responses.pop_front().ok_or_else(|| {
                    format_err!("guest sent unexpected response {}", describe(&bytes))
                })?;
                if bytes != expected {
                    let expected_desc = describe(&expected);
                    let actual_desc = describe(&bytes);
                    return Err(format_err!(
                        "guest response mismatch: expected {expected_desc}, got {actual_desc}"
                    ));
                }
                state.responses += 1;
            }
            if !caller.data().quiet {
                println!("  ← send  {}", describe(&bytes));
            }
            Ok(())
        },
    )?;

    // move_point(cmd) -> result : pretend the switch always reaches its end position.
    // Return 1 instead of 0 here to exercise the guest's Trailed -> PointBumped path.
    linker.func_wrap(
        "env",
        "move_point",
        |mut caller: Caller<'_, HostState>, cmd: i32| -> wasmtime::Result<i32> {
            let state = caller.data_mut();
            let expected = state
                .expected_moves
                .pop_front()
                .ok_or_else(|| format_err!("guest requested unexpected move_point({cmd})"))?;
            if cmd != expected {
                return Err(format_err!(
                    "guest move mismatch: expected move_point({}), got move_point({})",
                    move_name(expected),
                    move_name(cmd)
                ));
            }
            state.moves += 1;
            if !caller.data().quiet {
                let dir = if cmd == 0 { "Left" } else { "Right" };
                println!("  ⚙ move_point({dir}) => EndPositionArrived");
            }
            Ok(0) // 0 = EndPositionArrived, 1 = Trailed
        },
    )?;

    let fault_runtime = fault_config.as_ref().map(|_| Arc::new(FaultRuntime::new()));
    let state = match bench {
        Some(n) => HostState {
            inbox: VecDeque::new(),
            script: build_script().into(),
            remaining: n,
            cursor: 0,
            quiet: true,
            drained: false,
            moves: 0,
            expected_responses: build_expected_responses(n),
            expected_moves: build_expected_moves(n),
            responses: 0,
        },
        None => {
            let inbox = build_script();
            let messages = inbox.len();
            HostState {
                inbox,
                script: Vec::new(),
                remaining: 0,
                cursor: 0,
                quiet: false,
                drained: false,
                moves: 0,
                expected_responses: build_expected_responses(messages),
                expected_moves: build_expected_moves(messages),
                responses: 0,
            }
        }
    };
    let mut store = Store::new(&engine, state);

    let instantiate_start = std::time::Instant::now();
    let instance = linker.instantiate(&mut store, &module)?;
    println!(
        "host: instantiated guest in {:.3?}",
        instantiate_start.elapsed()
    );
    let memory = instance
        .get_memory(&mut store, "memory")
        .ok_or_else(|| anyhow::anyhow!("guest has no exported memory"))?;
    let fault_thread = if let (Some(config), Some(runtime)) = (fault_config, fault_runtime.clone())
    {
        refresh_initial_fault_regions(&mut store, memory, &runtime);
        let runtime_for_hook = Arc::clone(&runtime);
        let memory_for_hook = memory;
        store.call_hook(move |cx, hook| {
            match hook {
                CallHook::CallingHost | CallHook::ReturningFromHost => {
                    refresh_linear_fault_region(
                        cx.as_context(),
                        memory_for_hook,
                        &runtime_for_hook,
                    );
                    refresh_stack_fault_region(cx.as_context(), &runtime_for_hook);
                }
                CallHook::ReturningFromWasm => runtime_for_hook.clear_stack(),
                CallHook::CallingWasm => {}
            }
            Ok(())
        });
        Some(start_fault_injector(config, runtime))
    } else {
        None
    };
    let entry = instance.get_typed_func::<(i32, i32), i32>(&mut store, "main")?;

    println!("host: starting guest\n");
    let start = std::time::Instant::now();
    let result = entry.call(&mut store, (0, 0));
    let elapsed = start.elapsed();
    if let Some(runtime) = &fault_runtime {
        runtime.clear_all();
        runtime.request_stop();
    }
    let fault_stats = match fault_thread {
        Some(handle) => Some(
            handle
                .join()
                .map_err(|_| anyhow::anyhow!("fault injector thread panicked"))?,
        ),
        None => None,
    };
    let mut final_memory_fault = if final_fault_memory_check {
        match memory.try_data(&store) {
            Ok(_) => None,
            Err(err) => Some(err),
        }
    } else {
        None
    };
    let mut exit_error = None;
    let oracle_error = store.data().oracle_error();
    match result {
        Ok(code) => {
            if let Some(err) = oracle_error {
                eprintln!("\nhost: ✗ output oracle failed: {err}");
                exit_error = Some(anyhow::anyhow!(err));
            } else {
                println!("\nhost: guest main returned {code} (loop exited on its own?)");
            }
        }
        Err(err) => {
            if store.data().drained {
                if let Some(err) = oracle_error {
                    eprintln!("\nhost: ✗ output oracle failed: {err}");
                    exit_error = Some(anyhow::anyhow!(err));
                } else {
                    println!(
                        "\nhost: run complete — {} response(s), {} physical move(s), output oracle passed",
                        store.data().responses,
                        store.data().moves
                    );
                    if let Some(n) = bench {
                        println!(
                            "host: bench — {n} telegrams in {elapsed:.3?} ({:.0} telegrams/sec)",
                            n as f64 / elapsed.as_secs_f64()
                        );
                    }
                }
            } else {
                // A real trap (e.g. AN-encoding mismatch). Surface it.
                eprintln!("\nhost: ✗ guest trapped: {err:?}");
                exit_error = Some(err.into());
            }
        }
    }
    if exit_error.is_none() {
        if let Some(err) = final_memory_fault.take() {
            println!("host: final AN memory check found a latent raw/shadow mismatch: {err:?}");
            println!(
                "host: note: the whole memory was intentionally checked after the workload; \
                 the output oracle passed, so this corruption probably did not affect this run"
            );
        }
    }
    if let Some(stats) = fault_stats {
        println!(
            "host: fault injection — {} bit flip(s), {} skipped tick(s)",
            stats.flips, stats.skipped
        );
    }
    if let Some(err) = exit_error {
        return Err(err);
    }

    Ok(())
}

/// The scripted conversation the controller plays toward the point.
fn build_script() -> VecDeque<Vec<u8>> {
    let telegrams = vec![
        // Ask for the current location (guest ignores the payload here).
        SCITelegram::location_status(CONTROLLER, POINT, SCIPointLocation::PointNoTargetLocation),
        // Throw the point to the right, then re-query.
        SCITelegram::change_location(
            CONTROLLER,
            POINT,
            SCIPointTargetLocation::PointLocationChangeToRight,
        ),
        SCITelegram::location_status(CONTROLLER, POINT, SCIPointLocation::PointNoTargetLocation),
        // Throw it back to the left, then re-query.
        SCITelegram::change_location(
            CONTROLLER,
            POINT,
            SCIPointTargetLocation::PointLocationChangeToLeft,
        ),
        SCITelegram::location_status(CONTROLLER, POINT, SCIPointLocation::PointNoTargetLocation),
    ];
    telegrams.into_iter().map(<Vec<u8>>::from).collect()
}

fn build_expected_responses(messages: usize) -> VecDeque<Vec<u8>> {
    let mut responses = VecDeque::new();
    let mut location = SCIPointLocation::PointLocationLeft;
    for step in 0..messages {
        match step % 5 {
            1 => location = SCIPointLocation::PointLocationRight,
            3 => location = SCIPointLocation::PointLocationLeft,
            _ => {}
        }
        responses.push_back(Vec::from(SCITelegram::location_status(
            POINT, CONTROLLER, location,
        )));
    }
    responses
}

fn build_expected_moves(messages: usize) -> VecDeque<i32> {
    let mut moves = VecDeque::new();
    for step in 0..messages {
        match step % 5 {
            1 => moves.push_back(1), // Right
            3 => moves.push_back(0), // Left
            _ => {}
        }
    }
    moves
}

/// Decode an SCI-P telegram into a one-line human description.
fn describe(bytes: &[u8]) -> String {
    let t = match SCITelegram::try_from(bytes) {
        Ok(t) => t,
        Err(e) => return format!("<unparseable {} bytes: {e}>", bytes.len()),
    };
    let body = if t.message_type == SCIMessageType::scip_change_location() {
        format!("ChangeLocation -> {}", target_name(t.payload.data[0]))
    } else if t.message_type == SCIMessageType::scip_location_status() {
        format!("LocationStatus = {}", location_name(t.payload.data[0]))
    } else {
        format!("msgtype {:#06x}", u16::from(t.message_type))
    };
    let s = t.sender.trim_end_matches('_');
    let r = t.receiver.trim_end_matches('_');
    format!("[{s} -> {r}] {body}")
}

fn target_name(v: u8) -> &'static str {
    match v {
        0x01 => "Right",
        0x02 => "Left",
        _ => "?",
    }
}

fn location_name(v: u8) -> &'static str {
    match v {
        0x01 => "Right",
        0x02 => "Left",
        0x03 => "NoTarget",
        0x04 => "Bumped",
        _ => "?",
    }
}

fn move_name(cmd: i32) -> &'static str {
    match cmd {
        0 => "Left",
        1 => "Right",
        _ => "?",
    }
}
