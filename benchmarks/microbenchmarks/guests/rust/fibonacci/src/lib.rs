use micro_abi::{Bench, black_box, fold};

struct Fib {
    n: u64,
}

impl Bench for Fib {
    fn setup(param: u64) -> Self {
        Fib { n: param }
    }
    fn run(&mut self, iters: u64) -> u64 {
        let mut checksum = 0;
        for _ in 0..iters {
            checksum = fold(checksum, fib(black_box(self.n)));
        }
        checksum
    }
}

#[inline]
fn fib(n: u64) -> u64 {
    if n < 2 {
        return n;
    } else {
        return fib(n - 1) + fib(n - 2);
    }
}

micro_abi::bench!(Fib);
