use std::hint::black_box;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = "usage: fibonacci N (0..50) [iterations (1..4294967295)]";
    if !(2..=3).contains(&args.len()) {
        eprintln!("{usage}");
        std::process::exit(2);
    }
    let n = args[1].parse::<u32>().ok().filter(|&n| n <= 50);
    let iterations = args
        .get(2)
        .map_or(Ok(1_000_000_000), |s| s.parse::<u32>())
        .ok()
        .filter(|&count| count > 0);
    let (Some(n), Some(iterations)) = (n, iterations) else {
        eprintln!("{usage}");
        std::process::exit(2);
    };

    let mut checksum = 0_u64;
    for _ in 0..iterations {
        checksum = checksum.wrapping_add(black_box(fib(black_box(n))));
    }
    println!(
        "fib({n}) = {}; iterations={iterations}; checksum={checksum}",
        fib(n)
    );
}

#[unsafe(no_mangle)]
pub fn fib(num: u32) -> u64 {
    let (mut a, mut b) = (0_u64, 1_u64);
    for _ in 0..num {
        (a, b) = (b, a + b);
    }
    a
}
