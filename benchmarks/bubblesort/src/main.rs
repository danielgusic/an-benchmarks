use std::hint::black_box;

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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = "usage: sort N (0..4294967295) [iterations (1..4294967295)]";
    if !(2..=3).contains(&args.len()) {
        eprintln!("{usage}");
        std::process::exit(2);
    }
    let n = args[1].parse::<usize>().ok();
    let iterations = args
        .get(2)
        .map_or(Ok(1_000_000_000), |s| s.parse::<u32>())
        .ok()
        .filter(|&count| count > 0);
    let (Some(n), Some(iterations)) = (n, iterations) else {
        eprintln!("{usage}");
        std::process::exit(2);
    };

    let mut data: Vec<u32> = vec![rand::random(); n];

    let mut sorted_count = 0;
    for _ in 0..iterations {
        black_box(sort(black_box(data.as_mut_slice())));
        if data.is_sorted() {
            sorted_count += 1;
        }
        data = vec![rand::random(); n];
    }
    println!("Sorted {n} integers ({sorted_count}/{iterations} correct iterations)",);
}
