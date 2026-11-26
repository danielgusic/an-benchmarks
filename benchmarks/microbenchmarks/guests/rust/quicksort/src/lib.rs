use micro_abi::{Bench, XorShift64, black_box, check, fold};

const SEED: u64 = 67;

struct Quicksort {
    data: Vec<u32>,
}

impl Bench for Quicksort {
    fn setup(param: u64) -> Self {
        check(param > 0);
        Quicksort {
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

fn sort<T: PartialOrd>(data: &mut [T]) {
    if data.len() < 2 {
        return;
    }
    let n = data.len();
    let p = median_of_3(data, 0, n / 2, n - 1);
    let (a, b) = partition3(data, p);
    sort(&mut data[..a]);
    sort(&mut data[b..]);
}

fn median_of_3<T: PartialOrd>(data: &[T], a: usize, b: usize, c: usize) -> usize {
    if data[a] < data[b] {
        if data[b] < data[c] {
            b
        } else if data[a] < data[c] {
            c
        } else {
            a
        }
    } else {
        if data[a] < data[c] {
            a
        } else if data[b] < data[c] {
            c
        } else {
            b
        }
    }
}

fn partition3<T: PartialOrd>(data: &mut [T], p: usize) -> (usize, usize) {
    data.swap(0, p);
    let (mut lt, mut i, mut gt) = (1, 1, data.len());
    while i < gt {
        if data[i] < data[0] {
            data.swap(i, lt);
            lt += 1;
            i += 1;
        } else if data[i] > data[0] {
            gt -= 1;
            data.swap(i, gt);
        } else {
            i += 1;
        }
    }
    data.swap(0, lt - 1);
    (lt - 1, gt)
}

micro_abi::bench!(Quicksort);
