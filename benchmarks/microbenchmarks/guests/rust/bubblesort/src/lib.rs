use micro_abi::{Bench, XorShift64, black_box, check, fold};

const SEED: u64 = 67;

struct Bubblesort {
    data: Vec<u32>,
}

impl Bench for Bubblesort {
    fn setup(param: u64) -> Self {
        check(param > 0);
        Bubblesort {
            data: vec![0; param as usize],
        }
    }

    fn run(&mut self, iters: u64) -> u64 {
        let mut acc = 0;
        for _ in 0..iters {
            let mut rng = XorShift64::new(SEED);
            for x in self.data.iter_mut() {
                *x = rng.next_u32();
            }
            sort(black_box(&mut self.data));
            acc = fold(acc, self.data[self.data.len() / 2] as u64);
        }
        acc
    }

    fn verify(&mut self) -> u64 {
        self.data.iter().fold(0, |acc, &x| fold(acc, x as u64))
    }
}

pub fn sort<T: PartialOrd>(data: &mut [T]) {
    for i in 0..data.len() {
        let max = (data.len() - i) - 1;
        for j in 0..max {
            if data[j] > data[j + 1] {
                data.swap(j, j + 1);
            }
        }
    }
}

micro_abi::bench!(Bubblesort);
