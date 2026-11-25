mod bench;
mod common;
mod inject;
mod regions;

use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser)]
#[command(
    version,
    about = "Benchmark-agnostic wasmtime-an host for microbenchmarks"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Bench(bench::BenchArgs),
    Inject(inject::InjectArgs),
    CsvHeader {
        #[arg(value_enum)]
        of: HeaderOf,
    },
    #[command(hide = true)]
    InjectChild(inject::ChildArgs),
}

#[derive(Clone, Copy, ValueEnum)]
enum HeaderOf {
    Bench,
    Inject,
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Bench(args) => bench::run(args),
        Command::Inject(args) => inject::run(args),
        Command::CsvHeader { of } => {
            println!(
                "{}",
                match of {
                    HeaderOf::Bench => bench::CSV_HEADER,
                    HeaderOf::Inject => inject::CSV_HEADER,
                }
            );
            Ok(())
        }
        Command::InjectChild(args) => inject::child(args),
    }
}
