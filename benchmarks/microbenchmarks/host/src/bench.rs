use std::{fmt::Write as _, time::Instant};

use anyhow::{Result, bail};
use clap::Args;
use wasmtime::Store;

use crate::common::{Guest, GuestOpts, Phase, compile};

pub const CSV_HEADER: &str = "bench,mode,an_constant,rep,param,iters,kind,index,ns,checksum";

#[derive(Args)]
pub struct BenchArgs {
    #[command(flatten)]
    guest: GuestOpts,

    #[arg(long, value_name = "N", default_value_t = 2)]
    warmup: u32,

    #[arg(long, value_name = "N", default_value_t = 10,
          value_parser = clap::value_parser!(u32).range(1..))]
    samples: u32,

    #[arg(long, value_name = "CHECKSUM")]
    expect: Option<u64>,

    #[arg(long, value_name = "N", default_value_t = 1)]
    rep: u32,

    #[arg(long)]
    csv: bool,
}

struct Row {
    kind: &'static str,
    index: u32,
    ns: u128,
    checksum: Option<u64>,
}

pub fn run(args: BenchArgs) -> Result<()> {
    let opts = &args.guest;
    let mut rows = Vec::new();

    let start = Instant::now();
    let engine = opts.engine()?;
    let module = compile(&engine, &opts.wasm)?;
    rows.push(Row {
        kind: "compile",
        index: 0,
        ns: start.elapsed().as_nanos(),
        checksum: None,
    });

    let mut store = Store::new(&engine, ());
    let start = Instant::now();
    let guest = Guest::instantiate(&mut store, &module)?;
    rows.push(Row {
        kind: "instantiate",
        index: 0,
        ns: start.elapsed().as_nanos(),
        checksum: None,
    });

    let start = Instant::now();
    guest.setup(&mut store, opts.param)?;
    rows.push(Row {
        kind: "setup",
        index: 0,
        ns: start.elapsed().as_nanos(),
        checksum: None,
    });

    let mut reference = args.expect;
    for (kind, count) in [("warmup", args.warmup), ("sample", args.samples)] {
        for index in 0..count {
            guest.reset(&mut store)?;
            let start = Instant::now();
            let result = guest.run.call(&mut store, opts.iters);
            let ns = start.elapsed().as_nanos();
            let checksum = guest.checksum(&mut store, result).map_err(|(phase, e)| {
                let export = match phase {
                    Phase::Run => "bench_run",
                    Phase::Verify => "bench_verify",
                };
                anyhow::Error::from(e)
                    .context(format!("guest trapped in {export} ({kind} {index})"))
            })?;
            match reference {
                None => reference = Some(checksum),
                Some(expected) if expected != checksum => bail!(
                    "checksum mismatch in {kind} {index}: expected {expected}, got {checksum}{}",
                    if args.expect.is_some() {
                        " (expected value from --expect)"
                    } else {
                        " (bench_run must be deterministic after bench_reset)"
                    }
                ),
                Some(_) => {}
            }
            rows.push(Row {
                kind,
                index,
                ns,
                checksum: Some(checksum),
            });
        }
    }

    if args.csv {
        print_csv(&args, &rows);
    } else {
        print_summary(&args, &rows, reference.unwrap());
    }
    Ok(())
}

fn print_csv(args: &BenchArgs, rows: &[Row]) {
    let opts = &args.guest;
    let (name, mode, an_constant) = (opts.name(), opts.mode(), opts.an_constant_column());
    let mut out = String::new();
    for row in rows {
        let checksum = row.checksum.map(|c| c.to_string()).unwrap_or_default();
        writeln!(
            out,
            "{name},{mode},{an_constant},{},{},{},{},{},{},{checksum}",
            args.rep, opts.param, opts.iters, row.kind, row.index, row.ns,
        )
        .unwrap();
    }
    print!("{out}");
}

fn print_summary(args: &BenchArgs, rows: &[Row], checksum: u64) {
    let opts = &args.guest;
    let phase = |kind: &str| rows.iter().find(|r| r.kind == kind).map_or(0, |r| r.ns);
    let mut samples: Vec<f64> = rows
        .iter()
        .filter(|r| r.kind == "sample")
        .map(|r| r.ns as f64)
        .collect();
    samples.sort_by(f64::total_cmp);
    let n = samples.len() as f64;
    let mean = samples.iter().sum::<f64>() / n;
    let stddev = if samples.len() > 1 {
        (samples.iter().map(|s| (s - mean).powi(2)).sum::<f64>() / (n - 1.0)).sqrt()
    } else {
        0.0
    };
    let median = if samples.len() % 2 == 1 {
        samples[samples.len() / 2]
    } else {
        (samples[samples.len() / 2 - 1] + samples[samples.len() / 2]) / 2.0
    };
    let ms = |ns: f64| ns / 1e6;

    println!(
        "{} / AN {}{} / param={} iters={}",
        opts.name(),
        if opts.an { "on" } else { "off" },
        opts.an_constant
            .filter(|_| opts.an)
            .map(|a| format!(" (A={a})"))
            .unwrap_or_default(),
        opts.param,
        opts.iters
    );
    println!(
        "  compile {:.3} ms, instantiate {:.3} ms, setup {:.3} ms",
        ms(phase("compile") as f64),
        ms(phase("instantiate") as f64),
        ms(phase("setup") as f64)
    );
    println!(
        "  {} samples: median {:.3} ms, mean {:.3} ms ± {:.3} (sd), min {:.3} ms, max {:.3} ms",
        samples.len(),
        ms(median),
        ms(mean),
        ms(stddev),
        ms(samples[0]),
        ms(samples[samples.len() - 1])
    );
    if opts.iters > 0 {
        println!("  {:.2} ns/iter (median)", median / opts.iters as f64);
    }
    println!("  checksum {checksum}");
    if median < 1e6 {
        eprintln!(
            "  note: median sample is under 1 ms; raise --iters so timer and call overhead stay negligible"
        );
    }
}
