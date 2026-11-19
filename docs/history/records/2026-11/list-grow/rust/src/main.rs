//! The twin of grow.rig: one Vec growth, timed, in a fresh process.
use std::time::Instant;
fn main() {
    let case = std::env::args().nth(1).unwrap();
    let m = 1usize << 22;
    let src: Vec<i64> = (0..m as i64).map(|i| i.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) >> 20).collect();
    if case == "push" {
        let t = Instant::now();
        let mut xs: Vec<i64> = Vec::new();
        for i in 0..m as i64 { xs.push(i) }
        let xs = std::hint::black_box(xs);
        println!("push {} {}", t.elapsed().as_nanos(), xs.len());
    } else {
        let h = if case == "span" { 1886750 } else { 2097152 };
        let mut a: Vec<i64> = Vec::with_capacity(h);
        a.extend_from_slice(&src[..h]);
        let t = Instant::now();
        a.extend_from_slice(&src[h..2 * h]);
        let a = std::hint::black_box(a);
        println!("{} {} {}", case, t.elapsed().as_nanos(), a.len());
    }
}
