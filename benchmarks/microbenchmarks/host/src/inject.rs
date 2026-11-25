use std::{
    collections::HashMap,
    fmt::Write as _,
    io::{Read, Write},
    path::PathBuf,
    process::{Command, ExitStatus, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

use anyhow::{Result, bail};
use clap::{Args, ValueEnum};
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;
use wasmtime::{Module, Store};

use crate::{
    common::{Context, Guest, GuestOpts, Phase, WASM_STACK, compile},
    regions::{Region, Span, flip_code, flip_data, subtract, writable_mappings},
};

pub const CSV_HEADER: &str = "bench,mode,an_constant,param,iters,regions,seed,experiment,\
region,offset,region_size,bit,delay_ns,flip_ns,run_ns,outcome,detail,checksum";

const OUTCOMES: [&str; 7] = [
    "correct",
    "sdc",
    "an-detected",
    "trap",
    "crash",
    "timeout",
    "late",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Weighting {
    Size,
    Equal,
}

#[derive(Args)]
pub struct InjectArgs {
    #[command(flatten)]
    guest: GuestOpts,

    #[arg(long, value_enum, value_delimiter = ',', default_value = "memory")]
    regions: Vec<Region>,

    #[arg(long, value_enum, default_value_t = Weighting::Size)]
    weighting: Weighting,

    #[arg(long, value_name = "N", default_value_t = 1000)]
    experiments: u64,

    #[arg(long, value_name = "I", default_value_t = 0)]
    first: u64,

    #[arg(long, default_value_t = 0)]
    seed: u64,

    #[arg(long, value_name = "CHECKSUM")]
    expect: Option<u64>,

    #[arg(long, value_name = "N", default_value_t = 3,
          value_parser = clap::value_parser!(u32).range(1..))]
    golden_runs: u32,

    #[arg(long, value_name = "F", default_value_t = 10.0)]
    timeout_factor: f64,

    #[arg(long, value_name = "MS", default_value_t = 1000)]
    min_timeout_ms: u64,

    #[arg(long, value_name = "N", default_value_t = 1,
          value_parser = clap::value_parser!(u32).range(1..))]
    jobs: u32,

    #[arg(long)]
    csv: bool,
}

#[derive(Args)]
pub struct ChildArgs {
    #[command(flatten)]
    guest: GuestOpts,

    #[arg(long, value_enum, value_delimiter = ',')]
    regions: Vec<Region>,

    #[arg(long, value_enum, default_value_t = Weighting::Size)]
    weighting: Weighting,

    #[arg(long, default_value_t = 0)]
    seed: u64,

    #[arg(long)]
    experiment: Option<u64>,

    #[arg(long, default_value_t = 0)]
    delay_max_ns: u64,
}

struct TempModule(PathBuf);

impl Drop for TempModule {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

struct Finished {
    stdout: String,
    stderr: String,
    status: Option<ExitStatus>,
    wall: Duration,
}

#[derive(Default)]
struct Report {
    plan: Option<HashMap<String, String>>,
    result: Option<HashMap<String, String>>,
}

impl Report {
    fn parse(stdout: &str) -> Self {
        let mut report = Report::default();
        for line in stdout.lines() {
            let mut words = line.split_whitespace();
            let slot = match words.next() {
                Some("plan") => &mut report.plan,
                Some("result") => &mut report.result,
                _ => continue,
            };
            *slot = Some(
                words
                    .filter_map(|kv| kv.split_once('='))
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            );
        }
        report
    }
}

fn field<'a>(map: &'a Option<HashMap<String, String>>, key: &str) -> &'a str {
    map.as_ref()
        .and_then(|m| m.get(key))
        .map_or("", String::as_str)
}

fn csv_safe(text: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    let mut out: String = line
        .chars()
        .map(|c| if c == ',' || c == '"' { ';' } else { c })
        .take(100)
        .collect();
    if line.chars().count() > 100 {
        out.push('…');
    }
    out
}

pub fn run(args: InjectArgs) -> Result<()> {
    let opts = &args.guest;
    if !opts.an && args.regions.contains(&Region::Shadow) {
        if args.regions.iter().all(|r| *r == Region::Shadow) {
            bail!("the shadow region only exists with --an");
        }
        eprintln!("note: AN is off, so the shadow region is skipped");
    }
    let engine = opts.engine()?;
    let module = compile(&engine, &opts.wasm)?;
    let cwasm = TempModule(std::env::temp_dir().join(format!(
        "micro-host-{}-{}.cwasm",
        std::process::id(),
        opts.mode()
    )));
    std::fs::write(&cwasm.0, module.serialize()?)?;
    let exe = std::env::current_exe()?;
    let regions_arg = args.regions.iter().map(|r| r.name()).collect::<Vec<_>>();
    let weighting = args.weighting.to_possible_value().unwrap();

    let child_cmd = |experiment: Option<u64>, delay_max_ns: u64| {
        let mut cmd = Command::new(&exe);
        cmd.arg("inject-child")
            .arg(&cwasm.0)
            .args(["--param", &opts.param.to_string()])
            .args(["--iters", &opts.iters.to_string()])
            .args(["--regions", &regions_arg.join(",")])
            .args(["--weighting", weighting.get_name()])
            .args(["--seed", &args.seed.to_string()])
            .args(["--delay-max-ns", &delay_max_ns.to_string()]);
        if opts.an {
            cmd.arg("--an");
            if let Some(a) = opts.an_constant {
                cmd.args(["--an-constant", &a.to_string()]);
            }
        }
        if let Some(i) = experiment {
            cmd.args(["--experiment", &i.to_string()]);
        }
        cmd
    };

    let prefix = format!(
        "{},{},{},{},{},{},{}",
        opts.name(),
        opts.mode(),
        opts.an_constant_column(),
        opts.param,
        opts.iters,
        regions_arg.join("+"),
        args.seed
    );
    let mut stdout = std::io::stdout().lock();

    let mut golden_run = Vec::new();
    let mut golden_wall = Vec::new();
    let mut golden = None;
    for _ in 0..args.golden_runs {
        let done = spawn_and_wait(child_cmd(None, 0), None)?;
        let report = Report::parse(&done.stdout);
        if field(&report.result, "status") != "ok" || !done.status.is_some_and(|s| s.success()) {
            bail!(
                "golden run failed ({}):\n{}{}",
                done.status.map_or("killed".into(), describe_status),
                done.stdout,
                done.stderr
            );
        }
        let checksum: u64 = field(&report.result, "checksum").parse()?;
        let run_ns: u64 = field(&report.result, "run_ns").parse()?;
        match (golden, args.expect) {
            (Some(g), _) if g != checksum => {
                bail!("golden runs disagree: checksum {g} vs {checksum}")
            }
            (None, Some(e)) if e != checksum => {
                bail!("golden checksum {checksum} differs from --expect {e}")
            }
            _ => golden = Some(checksum),
        }
        if args.csv {
            writeln!(stdout, "{prefix},,,,,,,,{run_ns},golden,,{checksum}")?;
        }
        golden_run.push(run_ns);
        golden_wall.push(done.wall);
    }
    let golden = golden.unwrap();
    golden_run.sort_unstable();
    golden_wall.sort_unstable();
    let delay_max_ns = golden_run[golden_run.len() / 2].max(1);
    let timeout = golden_wall[golden_wall.len() / 2]
        .mul_f64(args.timeout_factor)
        .max(Duration::from_millis(args.min_timeout_ms));
    eprintln!(
        "{} / AN {}: golden checksum {golden}, bench_run {:.3} ms, process {:.1} ms -> timeout {:.0} ms",
        opts.name(),
        if opts.an { "on" } else { "off" },
        delay_max_ns as f64 / 1e6,
        golden_wall[golden_wall.len() / 2].as_secs_f64() * 1e3,
        timeout.as_secs_f64() * 1e3,
    );

    let end = args.first + args.experiments;
    let next = AtomicU64::new(args.first);
    let abort = AtomicBool::new(false);
    let (tx, rx) = mpsc::channel::<Result<(u64, String, &'static str)>>();
    let mut counts: HashMap<&str, u64> = HashMap::new();
    let mut failure = None;
    thread::scope(|scope| {
        for _ in 0..args.jobs {
            let tx = tx.clone();
            let (next, abort, child_cmd) = (&next, &abort, &child_cmd);
            scope.spawn(move || {
                while !abort.load(Ordering::SeqCst) {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    if i >= end {
                        break;
                    }
                    let row = spawn_and_wait(child_cmd(Some(i), delay_max_ns), Some(timeout))
                        .and_then(|done| classify(i, &done, golden));
                    if row.is_err() {
                        abort.store(true, Ordering::SeqCst);
                    }
                    let _ = tx.send(row);
                }
            });
        }
        drop(tx);

        let step = (args.experiments / 20).max(1);
        let mut finished = 0;
        for row in rx {
            match row {
                Ok((_, line, outcome)) => {
                    if args.csv {
                        let _ = writeln!(stdout, "{prefix},{line}");
                        let _ = stdout.flush();
                    }
                    *counts.entry(outcome).or_default() += 1;
                    finished += 1;
                    if finished % step == 0 || finished == args.experiments {
                        eprintln!("  [{finished}/{}] {}", args.experiments, summary(&counts));
                    }
                }
                Err(e) => {
                    failure.get_or_insert(e);
                }
            }
        }
    });
    if let Some(e) = failure {
        return Err(e.context("campaign aborted"));
    }
    if !args.csv {
        println!(
            "{} / AN {}: {}",
            opts.name(),
            if opts.an { "on" } else { "off" },
            summary(&counts)
        );
    }
    Ok(())
}

fn summary(counts: &HashMap<&str, u64>) -> String {
    let counted: u64 = OUTCOMES[..6]
        .iter()
        .map(|o| counts.get(o).unwrap_or(&0))
        .sum();
    let mut out = String::new();
    for outcome in OUTCOMES {
        let n = counts.get(outcome).copied().unwrap_or(0);
        if outcome == "late" {
            if n > 0 {
                let _ = write!(out, "  (late {n})");
            }
        } else {
            let pct = if counted > 0 {
                100.0 * n as f64 / counted as f64
            } else {
                0.0
            };
            let _ = write!(out, "{outcome} {pct:.1}%  ");
        }
    }
    out.trim_end().to_string()
}

fn describe_status(status: ExitStatus) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            return format!("signal {sig}");
        }
    }
    match status.code() {
        Some(code) => format!("exit {code}"),
        None => "unknown exit".to_string(),
    }
}

fn spawn_and_wait(mut cmd: Command, timeout: Option<Duration>) -> Result<Finished> {
    let start = Instant::now();
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut out_pipe = child.stdout.take().unwrap();
    let mut err_pipe = child.stderr.take().unwrap();
    thread::scope(|scope| {
        let out = scope.spawn(move || {
            let mut s = String::new();
            let _ = out_pipe.read_to_string(&mut s);
            s
        });
        let err = scope.spawn(move || {
            let mut s = String::new();
            let _ = err_pipe.read_to_string(&mut s);
            s
        });
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break Some(status);
            }
            if timeout.is_some_and(|t| start.elapsed() >= t) {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            thread::sleep(Duration::from_micros(500));
        };
        let wall = start.elapsed();
        Ok(Finished {
            stdout: out.join().unwrap(),
            stderr: err.join().unwrap(),
            status,
            wall,
        })
    })
}

fn classify(i: u64, done: &Finished, golden: u64) -> Result<(u64, String, &'static str)> {
    let report = Report::parse(&done.stdout);
    if report.plan.is_none() && done.status.is_some() {
        bail!(
            "experiment {i} failed before injecting ({}):\n{}{}",
            done.status.map_or("killed".into(), describe_status),
            done.stdout,
            done.stderr
        );
    }
    let result = &report.result;
    let flip_ns = field(result, "flip_ns");
    let run_ns = field(result, "run_ns");
    let mut checksum = "";
    let (outcome, detail) = match (done.status, result) {
        (None, _) => (
            "timeout",
            format!("killed after {} ms", done.wall.as_millis()),
        ),
        (Some(_), Some(_))
            if flip_ns == "-" || flip_ns.parse::<u64>()? > run_ns.parse::<u64>()? =>
        {
            ("late", String::new())
        }
        (Some(_), Some(r)) => match r.get("status").map(String::as_str) {
            Some("ok") => {
                checksum = field(result, "checksum");
                if checksum.parse::<u64>()? == golden {
                    ("correct", String::new())
                } else {
                    ("sdc", String::new())
                }
            }
            Some("trap") => {
                let trap = field(result, "trap");
                let outcome = match trap {
                    "AnMemoryMismatch" | "AnCodewordInvalid" => "an-detected",
                    _ => "trap",
                };
                let detail = match field(result, "phase") {
                    "verify" => format!("{trap} in bench_verify"),
                    _ => trap.to_string(),
                };
                (outcome, detail)
            }
            other => bail!("experiment {i}: unexpected result status {other:?}"),
        },
        (Some(status), None) => {
            let first_line = csv_safe(&done.stderr);
            let mut detail = describe_status(status);
            if !first_line.is_empty() {
                detail = format!("{detail}: {first_line}");
            }
            ("crash", detail)
        }
    };
    let plan = &report.plan;
    let line = format!(
        "{i},{},{},{},{},{},{},{},{outcome},{detail},{checksum}",
        field(plan, "region"),
        field(plan, "offset"),
        field(plan, "region_size"),
        field(plan, "bit"),
        field(plan, "delay_ns"),
        flip_ns.replace('-', ""),
        run_ns,
    );
    Ok((i, line, outcome))
}

const WAITING: u8 = 0;
const ARMED: u8 = 1;
const CANCELLED: u8 = 2;

#[derive(Default)]
struct Injector {
    sp: AtomicUsize,
    state: AtomicU8,
    go: AtomicBool,
    done: AtomicBool,
    addr: AtomicUsize,
    bit: AtomicU8,
    delay_ns: AtomicU64,
    flip_ns: AtomicU64,
}

impl Injector {
    fn run(&self) {
        let marker = 0u8;
        self.sp.store(
            std::hint::black_box(&marker) as *const u8 as usize,
            Ordering::SeqCst,
        );
        loop {
            match self.state.load(Ordering::SeqCst) {
                ARMED => break,
                CANCELLED => return,
                WAITING => thread::yield_now(),
                _ => unreachable!(),
            }
        }
        while !self.go.load(Ordering::SeqCst) {
            std::hint::spin_loop();
        }
        let start = Instant::now();
        let delay = Duration::from_nanos(self.delay_ns.load(Ordering::SeqCst));
        loop {
            if self.done.load(Ordering::SeqCst) {
                return; // bench_run finished first: no flip
            }
            let elapsed = start.elapsed();
            if elapsed >= delay {
                break;
            }
            let remaining = delay - elapsed;
            if remaining > Duration::from_millis(10) {
                thread::sleep(remaining - Duration::from_millis(5));
            } else {
                std::hint::spin_loop();
            }
        }
        unsafe {
            flip_data(
                self.addr.load(Ordering::SeqCst),
                self.bit.load(Ordering::SeqCst),
            )
        };
        self.flip_ns
            .store(start.elapsed().as_nanos() as u64, Ordering::SeqCst);
    }
}

pub fn child(args: ChildArgs) -> Result<()> {
    let opts = &args.guest;
    let engine = opts.engine()?;
    let module = unsafe { Module::deserialize_file(&engine, &opts.wasm) }
        .context("failed to load the precompiled guest")?;
    let mut store = Store::new(&engine, ());
    let guest = Guest::instantiate(&mut store, &module)?;
    guest.setup(&mut store, opts.param)?;
    guest.reset(&mut store)?;

    let Some(experiment) = args.experiment else {
        let start = Instant::now();
        let result = guest.run.call(&mut store, opts.iters);
        let run_ns = start.elapsed().as_nanos() as u64;
        let result = guest.checksum(&mut store, result);
        report_and_exit(result, run_ns, None);
    };

    let injector = Arc::new(Injector {
        flip_ns: AtomicU64::new(u64::MAX),
        ..Default::default()
    });
    let handle = {
        let injector = Arc::clone(&injector);
        thread::spawn(move || injector.run())
    };
    while injector.sp.load(Ordering::SeqCst) == 0 {
        thread::yield_now();
    }

    let marker = 0u8;
    let sp = std::hint::black_box(&marker) as *const u8 as usize;
    let stack = Span::new(sp - WASM_STACK, WASM_STACK);

    let memory = guest.instance.get_memory(&mut store, "memory");
    let memory_span = memory.map(|m| Span::new(m.data_ptr(&store) as usize, m.data_size(&store)));
    let shadow_span = memory
        .and_then(|m| m.an_shadow_data_mut_for_test(&mut store))
        .map(|s| Span::new(s.as_mut_ptr() as usize, s.len()));
    let text = module.text();
    let code_span = Span::new(text.as_ptr() as usize, text.len());

    let mut candidates: Vec<(Region, Vec<Span>)> = Vec::new();
    for &region in &args.regions {
        let spans = match region {
            Region::Memory => memory_span.into_iter().collect(),
            Region::Shadow => shadow_span.into_iter().collect(),
            Region::Stack => vec![stack],
            Region::Code => vec![code_span],
            Region::Runtime => {
                let mappings = writable_mappings()?;
                let injector_sp = injector.sp.load(Ordering::SeqCst);
                let mut holes: Vec<Span> = mappings
                    .iter()
                    .copied()
                    .filter(|m| m.contains(injector_sp))
                    .collect();
                holes.extend([stack, code_span]);
                holes.extend(memory_span);
                holes.extend(shadow_span);
                subtract(&mappings, &holes)
            }
        };
        if spans.iter().any(|s| s.len > 0) && !candidates.iter().any(|(r, _)| *r == region) {
            candidates.push((region, spans));
        }
    }
    if candidates.is_empty() {
        injector.state.store(CANCELLED, Ordering::SeqCst);
        bail!("none of the selected regions exists in this configuration");
    }

    let mut rng = ChaCha8Rng::seed_from_u64(args.seed);
    rng.set_stream(experiment);
    let total = |spans: &[Span]| spans.iter().map(|s| s.len as u64).sum::<u64>();
    let (region, spans, offset) = match args.weighting {
        Weighting::Size => {
            let mut pick = rng.gen_range(0..candidates.iter().map(|(_, s)| total(s)).sum());
            let mut chosen = None;
            for (region, spans) in &candidates {
                if pick < total(spans) {
                    chosen = Some((*region, spans, pick));
                    break;
                }
                pick -= total(spans);
            }
            chosen.unwrap()
        }
        Weighting::Equal => {
            let (region, spans) = &candidates[rng.gen_range(0..candidates.len())];
            (*region, spans, rng.gen_range(0..total(spans)))
        }
    };
    let mut rest = offset;
    let mut addr = 0;
    for span in spans {
        if rest < span.len as u64 {
            addr = span.start + rest as usize;
            break;
        }
        rest -= span.len as u64;
    }
    let bit: u8 = rng.gen_range(0..8);
    let fraction: u64 = rng.r#gen();
    let delay_ns = if region == Region::Code {
        0
    } else {
        ((u128::from(fraction) * u128::from(args.delay_max_ns)) >> 64) as u64
    };
    println!(
        "plan region={} offset={offset} region_size={} bit={bit} delay_ns={delay_ns}",
        region.name(),
        total(spans)
    );
    std::io::stdout().flush()?;

    if region == Region::Code {
        injector.state.store(CANCELLED, Ordering::SeqCst);
        unsafe { flip_code(addr, bit)? };
        injector.flip_ns.store(0, Ordering::SeqCst);
    } else {
        injector.addr.store(addr, Ordering::SeqCst);
        injector.bit.store(bit, Ordering::SeqCst);
        injector.delay_ns.store(delay_ns, Ordering::SeqCst);
        injector.state.store(ARMED, Ordering::SeqCst);
    }

    injector.go.store(true, Ordering::SeqCst);
    let start = Instant::now();
    let result = guest.run.call(&mut store, opts.iters);
    let run_ns = start.elapsed().as_nanos() as u64;
    injector.done.store(true, Ordering::SeqCst);
    let _ = handle.join();
    let flip_ns = injector.flip_ns.load(Ordering::SeqCst);
    let result = guest.checksum(&mut store, result);
    report_and_exit(result, run_ns, (flip_ns != u64::MAX).then_some(flip_ns));
}

fn report_and_exit(
    result: Result<u64, (Phase, wasmtime::Error)>,
    run_ns: u64,
    flip_ns: Option<u64>,
) -> ! {
    let flip = flip_ns.map_or("-".to_string(), |f| f.to_string());
    let line = match result {
        Ok(checksum) => {
            format!("result status=ok checksum={checksum} run_ns={run_ns} flip_ns={flip}")
        }
        Err((phase, err)) => {
            let trap = err
                .downcast_ref::<wasmtime::Trap>()
                .map_or("error".to_string(), |t| format!("{t:?}"));
            let phase = match phase {
                Phase::Run => "run",
                Phase::Verify => "verify",
            };
            format!("result status=trap trap={trap} phase={phase} run_ns={run_ns} flip_ns={flip}")
        }
    };
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
    std::process::exit(0);
}
