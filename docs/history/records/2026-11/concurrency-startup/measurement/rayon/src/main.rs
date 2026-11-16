//! The Rayon twin of startup.rig: psum's first call by STARTUP_MODE (cold, pre, gap).
use std::time::{Duration, Instant};
const GRAIN: usize = 8192;
fn psum(xs: &[i64]) -> i64 {
    if xs.len() <= GRAIN {
        return xs.iter().fold(0i64, |s, &x| s.wrapping_add(x));
    }
    let (l, r) = xs.split_at(xs.len() / 2);
    let (a, b) = rayon::join(|| psum(l), || psum(r));
    a.wrapping_add(b)
}
fn seq(xs: &[i64]) -> i64 { xs.iter().fold(0i64, |s, &x| s.wrapping_add(x)) }
fn main() {
    let mode = std::env::var("STARTUP_MODE").unwrap_or("cold".into());
    if mode == "pre" {
        let (a, b) = rayon::join(|| 1, || 2);
        println!("pre 0 {}", a + b);
    }
    let n = 1usize << 25;
    let xs: Vec<i64> = (0..n as i64).map(|i| i.wrapping_mul(2654435761) % 1000).collect();
    let t0 = Instant::now();
    let s0 = seq(std::hint::black_box(&xs));
    println!("seqsum {} {}", t0.elapsed().as_nanos(), s0);
    for k in 1..4 {
        if k == 3 && mode == "gap" { std::thread::sleep(Duration::from_millis(100)); }
        let t = Instant::now();
        let s = psum(std::hint::black_box(&xs));
        println!("psum{} {} {}", k, t.elapsed().as_nanos(), s);
    }
}
