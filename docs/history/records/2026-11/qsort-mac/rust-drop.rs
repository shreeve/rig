//! The Rayon twin of fork.rig: psum, the sum of 2^25 Ints split in halves
//! down to 8,192 by rayon::join; qsort, 2^22 Ints partitioned into two
//! owned Vecs, each half on rayon::join down to 8,192, then sort_unstable.
//! Prints `NAME NS CHECK` as fork.rig does.
use std::time::Instant;

const GRAIN: usize = 8192;

fn psum(xs: &[i64]) -> i64 {
    if xs.len() <= GRAIN {
        return xs.iter().fold(0i64, |s, &x| s.wrapping_add(x));
    }
    let (l, r) = xs.split_at(xs.len() / 2);
    let (a, b) = rayon::join(|| psum(l), || psum(r));
    a.wrapping_add(b)
}

fn qsort(mut xs: Vec<i64>) -> Vec<i64> {
    if xs.len() <= GRAIN {
        xs.sort_unstable();
        return xs;
    }
    let pivot = xs[xs.len() / 2];
    let mut lo = Vec::with_capacity(xs.len() / 2);
    let mut mid = Vec::new();
    let mut hi = Vec::with_capacity(xs.len() / 2);
    for &x in &xs {
        if x < pivot {
            lo.push(x)
        } else if x > pivot {
            hi.push(x)
        } else {
            mid.push(x)
        }
    }
    drop(xs);
    let (mut out, b) = rayon::join(|| qsort(lo), || qsort(hi));
    out.extend_from_slice(&mid);
    out.extend_from_slice(&b);
    out
}

fn main() {
    let n = 1usize << 25;
    let xs: Vec<i64> = (0..n as i64).map(|i| i.wrapping_mul(2654435761) % 1000).collect();
    let t = Instant::now();
    let s = psum(std::hint::black_box(&xs));
    println!("psum {} {}", t.elapsed().as_nanos(), s);
    let m = 1usize << 22;
    let ys: Vec<i64> = (0..m as i64)
        .map(|i| i.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) >> 20)
        .collect();
    let t2 = Instant::now();
    let zs = qsort(ys);
    let el = t2.elapsed().as_nanos();
    let ok = zs.windows(2).all(|w| w[0] <= w[1]) as usize;
    println!("qsort {} {}", el, ok * zs.len());
}
