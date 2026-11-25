use micro_abi::{Bench, XorShift64, black_box, check, fold};

struct Example {
    input: Vec<u32>,
    work: Vec<u32>,
}

impl Bench for Example {
    fn setup(param: u64) -> Self {
        let mut rng = XorShift64::new(42);
        let input: Vec<u32> = (0..param).map(|_| rng.next_u32()).collect();
        check(!input.is_empty());
        let work = input.clone();
        Self { input, work }
    }

    fn reset(&mut self) {
        self.work.copy_from_slice(&self.input);
    }

    fn run(&mut self, iters: u64) -> u64 {
        let work = black_box(&mut self.work);
        let mut checksum = 0;
        for _ in 0..iters {
            let mut carry = 0u32;
            for (i, x) in work.iter_mut().enumerate() {
                carry = x.rotate_left(5) ^ carry.wrapping_add(i as u32);
                *x = carry;
            }
            checksum = fold(checksum, u64::from(carry));
        }
        checksum
    }

    fn verify(&mut self) -> u64 {
        self.work.iter().fold(0, |acc, &x| fold(acc, u64::from(x)))
    }
}

micro_abi::bench!(Example);
