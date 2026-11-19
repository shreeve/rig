use std::hint::black_box;
use std::time::Instant;
fn input(m: usize) -> Vec<i64> { (0..m as i64).map(|i| i.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) >> 20).collect() }
#[inline(never)]
fn part(xs: &[i64]) -> usize {
    let pivot = xs[xs.len() / 2];
    let mut lo = Vec::with_capacity(xs.len() / 2); let mut mid = Vec::new(); let mut hi = Vec::with_capacity(xs.len() / 2);
    for &x in xs { if x < pivot { lo.push(x) } else if x > pivot { hi.push(x) } else { mid.push(x) } }
    lo.len() * 3 + hi.len() + mid.len()
}
#[inline(never)]
fn part_warm(xs: &[i64], lo: &mut Vec<i64>, mid: &mut Vec<i64>, hi: &mut Vec<i64>) -> usize {
    let pivot = xs[xs.len() / 2];
    for &x in xs { if x < pivot { lo.push(x) } else if x > pivot { hi.push(x) } else { mid.push(x) } }
    lo.len() * 3 + hi.len() + mid.len()
}
fn main() {
    let m = 1usize << 22; let src = input(m); let reps = 7; let h = m / 2;
    for _ in 0..reps { let t = Instant::now(); let c = part(black_box(&src)); println!("part {} {}", t.elapsed().as_nanos(), c); }
    let (mut lo, mut mid, mut hi) = (Vec::with_capacity(m), Vec::with_capacity(m), Vec::with_capacity(m));
    for _ in 0..reps { lo.clear(); mid.clear(); hi.clear(); let t = Instant::now(); let c = part_warm(black_box(&src), &mut lo, &mut mid, &mut hi); println!("partwarm {} {}", t.elapsed().as_nanos(), c); }
    for _ in 0..reps { let mut a: Vec<i64> = Vec::with_capacity(h); a.extend_from_slice(&src[..h]); let t = Instant::now(); a.extend_from_slice(&src[h..]); println!("extend {} {}", t.elapsed().as_nanos(), black_box(&a).len()); }
    for _ in 0..reps { let mut a: Vec<i64> = Vec::with_capacity(m); a.extend_from_slice(&src[..h]); let t = Instant::now(); a.extend_from_slice(&src[h..]); println!("extendroom {} {}", t.elapsed().as_nanos(), black_box(&a).len()); }
    for _ in 0..reps { let t = Instant::now(); let mut a: Vec<i64> = Vec::with_capacity(h); for &x in &src[..h] { a.push(x) } println!("fresh {} {}", t.elapsed().as_nanos(), black_box(&a).len()); }
    for _ in 0..reps { let mut s = 0i64; let t = Instant::now(); for k in 0..512 { let mut leaf = src[k*8192..(k+1)*8192].to_vec(); leaf.sort_unstable(); s = s.wrapping_add(leaf[100]); } println!("leaves {} {}", t.elapsed().as_nanos(), s); }
    for _ in 0..reps { let mut s = 0i64; let t = Instant::now(); for k in 0..512 { let leaf = black_box(src[k*8192..(k+1)*8192].to_vec()); s = s.wrapping_add(leaf[100]); } println!("leafcopy {} {}", t.elapsed().as_nanos(), s); }
}
