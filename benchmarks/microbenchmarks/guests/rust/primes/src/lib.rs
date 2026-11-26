use std::hint::black_box;

use micro_abi::{Bench, fold};

struct Primes {
    limit: u64,
}

impl Bench for Primes {
    fn setup(param: u64) -> Self {
        Self { limit: param }
    }

    fn run(&mut self, iters: u64) -> u64 {
        let mut checksum = 0;
        for _ in 0..iters {
            let prime_list = primes(black_box(self.limit as usize));
            checksum = fold(
                checksum,
                *prime_list.last().expect("Limit must be greater than 2"),
            );
        }
        checksum
    }
}

#[inline]
fn primes(limit: usize) -> Vec<u64> {
    let mut sieve = vec![true; limit as usize];
    for i in 2..(limit / 2) {
        for j in 1..i {
            if i * j < limit {
                sieve[i * j] = false;
            }
        }
    }
    sieve
        .iter()
        .enumerate()
        .filter_map(|(idx, is_prime)| is_prime.then(|| idx as u64))
        .collect()
}

micro_abi::bench!(Primes);
