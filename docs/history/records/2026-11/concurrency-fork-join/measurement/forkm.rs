//! fork.rig's qsort with std.sort's leaf algorithm ported (insertion runs
//! of 20, then SymMerge by rotations), so only the fork-join differs.
use std::time::Instant;
const GRAIN: usize = 8192;

fn insertion<L: Fn(&i64, &i64) -> bool>(xs: &mut [i64], less: &L) {
    for i in 1..xs.len() { let mut j = i; while j > 0 && less(&xs[j], &xs[j - 1]) { xs.swap(j, j - 1); j -= 1; } }
}
fn swap_range(xs: &mut [i64], a: usize, b: usize, n: usize) { for i in 0..n { xs.swap(a + i, b + i); } }
fn rotate(xs: &mut [i64], a: usize, m: usize, b: usize) {
    let (mut i, mut j) = (m - a, b - m);
    while i != j { if i > j { swap_range(xs, m - i, m, j); i -= j; } else { swap_range(xs, m - i, m + j - i, i); j -= i; } }
    swap_range(xs, m - i, m, i);
}
fn sym_merge<L: Fn(&i64, &i64) -> bool>(xs: &mut [i64], less: &L, a: usize, m: usize, b: usize) {
    if m - a == 1 {
        let (mut i, mut j) = (m, b);
        while i < j { let h = (i + j) / 2; if less(&xs[h], &xs[a]) { i = h + 1 } else { j = h } }
        let mut k = a; while k < i - 1 { xs.swap(k, k + 1); k += 1; }
        return;
    }
    if b - m == 1 {
        let (mut i, mut j) = (a, m);
        while i < j { let h = (i + j) / 2; if !less(&xs[m], &xs[h]) { i = h + 1 } else { j = h } }
        let mut k = m; while k > i { xs.swap(k, k - 1); k -= 1; }
        return;
    }
    let mid = (a + b) / 2;
    let n = mid + m;
    let mut start = if m > mid { n - b } else { a };
    let mut r = if m > mid { mid } else { m };
    let p = n - 1;
    while start < r { let c = (start + r) / 2; if !less(&xs[p - c], &xs[c]) { start = c + 1 } else { r = c } }
    let end = n - start;
    if start < m && m < end { rotate(xs, start, m, end); }
    if a < start && start < mid { sym_merge(xs, less, a, start, mid); }
    if mid < end && end < b { sym_merge(xs, less, mid, end, b); }
}
fn sort_by<L: Fn(&i64, &i64) -> bool>(xs: &mut [i64], less: &L) {
    let n = xs.len();
    let mut width = 20;
    let mut a = 0;
    while a < n { let e = (a + width).min(n); insertion(&mut xs[a..e], less); a += width; }
    while width < n {
        a = 0;
        while a + width < n { sym_merge(xs, less, a, a + width, (a + 2 * width).min(n)); a += 2 * width; }
        width *= 2;
    }
}
fn qsort(xs: Vec<i64>) -> Vec<i64> {
    if xs.len() <= GRAIN { let mut xs = xs; sort_by(&mut xs, &|a: &i64, b: &i64| a < b); return xs; }
    let pivot = xs[xs.len() / 2];
    let mut lo = Vec::with_capacity(xs.len() / 2);
    let mut mid = Vec::new();
    let mut hi = Vec::with_capacity(xs.len() / 2);
    for &x in &xs { if x < pivot { lo.push(x) } else if x > pivot { hi.push(x) } else { mid.push(x) } }
    let (mut out, b) = rayon::join(|| qsort(lo), || qsort(hi));
    out.extend_from_slice(&mid);
    out.extend_from_slice(&b);
    out
}
fn qsortd(xs: Vec<i64>) -> Vec<i64> {
    if xs.len() <= GRAIN { let mut xs = xs; let l: &dyn Fn(&i64, &i64) -> bool = std::hint::black_box(&|a: &i64, b: &i64| a < b); sort_by(&mut xs, &l); return xs; }
    let pivot = xs[xs.len() / 2];
    let mut lo = Vec::with_capacity(xs.len() / 2);
    let mut mid = Vec::new();
    let mut hi = Vec::with_capacity(xs.len() / 2);
    for &x in &xs { if x < pivot { lo.push(x) } else if x > pivot { hi.push(x) } else { mid.push(x) } }
    let (mut out, b) = rayon::join(|| qsortd(lo), || qsortd(hi));
    out.extend_from_slice(&mid);
    out.extend_from_slice(&b);
    out
}
fn main() {
    let m = 1usize << 22;
    let gen = || -> Vec<i64> { (0..m as i64).map(|i| i.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) >> 20).collect() };
    let ys = gen();
    let t2 = Instant::now();
    let zs = qsort(ys);
    let el = t2.elapsed().as_nanos();
    let ok = zs.windows(2).all(|w| w[0] <= w[1]) as usize;
    println!("qsort {} {}", el, ok * zs.len());
    let ys = gen();
    let t3 = Instant::now();
    let zs = qsortd(ys);
    let el = t3.elapsed().as_nanos();
    let ok = zs.windows(2).all(|w| w[0] <= w[1]) as usize;
    println!("qsort_dyn {} {}", el, ok * zs.len());
    let mut zs = gen();
    let t6 = Instant::now();
    for c in zs.chunks_mut(GRAIN) { sort_by(c, &|a: &i64, b: &i64| a < b); }
    println!("leaves {} {}", t6.elapsed().as_nanos(), zs[0]);
    let mut ws = gen();
    let dynless: &dyn Fn(&i64, &i64) -> bool = std::hint::black_box(&|a: &i64, b: &i64| a < b);
    let t7 = Instant::now();
    for c in ws.chunks_mut(GRAIN) { sort_by(c, &dynless); }
    println!("leaves_dyn {} {}", t7.elapsed().as_nanos(), ws[0]);
}
