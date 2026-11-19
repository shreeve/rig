use std::time::Instant;
use std::sync::OnceLock;
const GRAIN: usize = 8192;
static T0: OnceLock<Instant> = OnceLock::new();
fn now() -> u128 { T0.get().unwrap().elapsed().as_nanos() }

fn qsort(xs: Vec<i64>, d: usize, path: usize) -> Vec<i64> {
    let mut xs = xs;
    if xs.len() <= GRAIN { xs.sort_unstable(); return xs; }
    let t0 = now();
    let pivot = xs[xs.len() / 2];
    let mut lo = Vec::with_capacity(xs.len() / 2);
    let mut mid = Vec::new();
    let mut hi = Vec::with_capacity(xs.len() / 2);
    for &x in &xs { if x < pivot { lo.push(x) } else if x > pivot { hi.push(x) } else { mid.push(x) } }
    let n = xs.len();
    drop(xs);
    let t1 = now();
    let (r, b) = rayon::join(|| { let o = qsort(lo, d + 1, path * 2); (o, now()) }, || qsort(hi, d + 1, path * 2 + 1));
    let t4 = now();
    let (mut out, t2) = r;
    let t3 = t2;
    out.extend_from_slice(&mid);
    out.extend_from_slice(&b);
    let t5 = now();
    if d < 3 { println!("ph {} {} {} {} {} {} {} {} {}", d, path, n, t0, t1, t2, t3, t4, t5); }
    out
}

fn main() {
    let m = 1usize << 22;
    let ys: Vec<i64> = (0..m as i64).map(|i| i.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) >> 20).collect();
    T0.set(Instant::now()).unwrap();
    let t2 = Instant::now();
    let zs = qsort(ys, 0, 0);
    let el = t2.elapsed().as_nanos();
    let ok = zs.windows(2).all(|w| w[0] <= w[1]) as usize;
    println!("qsort {} {}", el, ok * zs.len());
}
