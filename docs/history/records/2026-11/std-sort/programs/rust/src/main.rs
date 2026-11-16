// Rust's sorts on the data std.sort's bench sorts. Prints the fastest
// round, ns per element. rsortbench KIND PATTERN N ROUNDS ALGO(stable|unstable)
use std::hint::black_box;
use std::time::Instant;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct P { a: i64, b: i64 }
#[derive(Clone, Copy)]
struct Rec { key: i64, id: i64 }

struct Gen(u64);
impl Gen {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
    fn key(&mut self, p: &str, i: usize, n: usize) -> i64 {
        match p {
            "rand" => (self.next() >> 1) as i64,
            "sorted" => i as i64,
            "rev" => (n - i) as i64,
            _ => (self.next() % 16) as i64,
        }
    }
}

fn run<T: Clone>(master: &[T], n: usize, rounds: usize, mut f: impl FnMut(&mut [T])) -> u128 {
    let reps = master.len() / n;
    let mut work = master.to_vec();
    let mut best = u128::MAX;
    for _ in 0..rounds {
        work.clone_from_slice(master);
        let t0 = Instant::now();
        for r in 0..reps { f(&mut work[r * n..(r + 1) * n]); }
        let dt = t0.elapsed().as_nanos();
        black_box(&work);
        best = best.min(dt);
    }
    best
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (kind, pattern) = (a[1].as_str(), a[2].as_str());
    let n: usize = a[3].parse().unwrap();
    let rounds: usize = a[4].parse().unwrap();
    let stable = a[5] == "stable";
    let reps = std::cmp::max(1, (1 << 20) / n);
    let total = reps * n;
    let mut g = Gen(42);
    let mut keys = Vec::with_capacity(total);
    for _ in 0..reps { for i in 0..n { keys.push(g.key(pattern, i, n)); } }
    let best = match kind {
        "int" => run(&keys, n, rounds, |s| if stable { s.sort() } else { s.sort_unstable() }),
        "str" => {
            let sorted = pattern == "sorted" || pattern == "rev";
            let texts: Vec<String> = keys.iter().map(|&k| format!("{}", if sorted { k + 1000000000000 } else { k })).collect();
            let views: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();
            run(&views, n, rounds, |s| if stable { s.sort() } else { s.sort_unstable() })
        }
        "obj" => {
            let m: Vec<P> = keys.iter().map(|&k| P { a: k.div_euclid(1024), b: k.rem_euclid(1024) }).collect();
            run(&m, n, rounds, |s| if stable { s.sort() } else { s.sort_unstable() })
        }
        _ => {
            let m: Vec<Rec> = keys.iter().enumerate().map(|(i, &k)| Rec { key: k, id: (i % n) as i64 }).collect();
            run(&m, n, rounds, |s| if stable { s.sort_by(|x, y| x.key.cmp(&y.key)) } else { s.sort_unstable_by(|x, y| x.key.cmp(&y.key)) })
        }
    };
    println!("{:.3}", best as f64 / total as f64);
}
