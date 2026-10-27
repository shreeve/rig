//! Rust's HashMap, which is hashbrown (SwissTable, groups of 16 control
//! bytes on x86 and 8 on Arm, at most 7/8 full), timed as
//! bench/hash/map.rig's `sized` times std.hash, with FxHasher, the
//! one-multiply hash rustc and tsrs use, written out below so the
//! program needs no crate: `rustc -C opt-level=3 map.rs`. Prints
//! `KEYS OP NS CHECK` per line.
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::hint::black_box;
use std::time::Instant;

/// rustc-hash's FxHasher on whole words.
#[derive(Default, Clone, Copy)]
struct Fx(u64);

impl Hasher for Fx {
    fn write(&mut self, bytes: &[u8]) {
        for c in bytes.chunks(8) {
            let mut w = [0u8; 8];
            w[..c.len()].copy_from_slice(c);
            self.write_u64(u64::from_le_bytes(w));
        }
    }
    #[cfg(not(mix))]
    fn write_u64(&mut self, x: u64) {
        self.0 = (self.0.rotate_left(5) ^ x).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
    }
    /// With `--cfg mix`: Rig's hash of an Int (`hashWord` in
    /// src/runtime.zig), a full 64x64 multiply folded to 64 bits, so the
    /// keys scatter as std.hash scatters them rather than in FxHash's
    /// strides, which a prefetcher follows.
    #[cfg(mix)]
    fn write_u64(&mut self, x: u64) {
        let p = ((x ^ 0x2d35_8dcc_aa6c_78a5) as u128) * 0x4b33_a62e_d433_d4a3u128;
        self.0 = (p as u64) ^ ((p >> 64) as u64);
    }
    fn write_i64(&mut self, x: i64) {
        self.write_u64(x as u64);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}

/// FxHasher for text keys, the same in every variant: `--cfg mix`
/// changes only the hash of integers.
#[derive(Default, Clone, Copy)]
struct FxStr(u64);

impl Hasher for FxStr {
    fn write(&mut self, bytes: &[u8]) {
        for c in bytes.chunks(8) {
            let mut w = [0u8; 8];
            w[..c.len()].copy_from_slice(c);
            self.write_u64(u64::from_le_bytes(w));
        }
    }
    fn write_u64(&mut self, x: u64) {
        self.0 = (self.0.rotate_left(5) ^ x).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}

type Map = HashMap<i64, i64, BuildHasherDefault<Fx>>;
/// A value of eight integers (`big`).
type BigMap = HashMap<i64, [i64; 8], BuildHasherDefault<Fx>>;
type StrMap = HashMap<String, i64, BuildHasherDefault<FxStr>>;

const MUL: i64 = -7046029254386353131;
const N: i64 = 1_000_000;

fn out(keys: &str, op: &str, ns: u128, check: i64) {
    println!("{keys} {op} {ns} {check}");
}

fn sized(s: i64) {
    let total = 4 * N;
    let k = if s < N { N / s } else { 1 };
    let reps = total / (k * s);
    let name = format!("int{s}");
    let (mut ins, mut rem, mut check) = (0u128, 0u128, 0i64);
    for _ in 0..reps {
        let mut maps: Vec<Map> = (0..k).map(|_| Map::default()).collect();
        let t = Instant::now();
        for (j, m) in maps.iter_mut().enumerate() {
            let base = j as i64 * s;
            for i in 0..s {
                m.insert((base + i).wrapping_mul(MUL), i);
            }
        }
        ins += t.elapsed().as_nanos();
        let t = Instant::now();
        for (j, m) in maps.iter_mut().enumerate() {
            let base = j as i64 * s;
            for i in 0..s {
                check += m.remove(&(base + i).wrapping_mul(MUL)).unwrap_or(0);
            }
        }
        rem += t.elapsed().as_nanos();
        black_box(&maps);
    }
    let scale = |ns: u128| ns * N as u128 / total as u128;
    out(&name, "insert", scale(ins), reps * k * s);
    out(&name, "remove", scale(rem), check);
    let mut m = Map::default();
    for i in 0..s {
        m.insert(i.wrapping_mul(MUL), i);
    }
    let rounds = total / s;
    let mut sum = 0i64;
    let t = Instant::now();
    for _ in 0..rounds {
        for i in 0..s {
            if let Some(v) = m.get(&black_box(i).wrapping_mul(MUL)) {
                sum += v;
            }
        }
    }
    out(&name, "hit", scale(t.elapsed().as_nanos()), sum);
    let mut found = 0i64;
    let t = Instant::now();
    for _ in 0..rounds {
        for i in s..2 * s {
            if m.contains_key(&black_box(i).wrapping_mul(MUL)) {
                found += 1;
            }
        }
    }
    out(&name, "miss", scale(t.elapsed().as_nanos()), found);
    sum = 0;
    let t = Instant::now();
    for _ in 0..rounds {
        for v in black_box(&m).values() {
            sum += v;
        }
    }
    out(&name, "iterate", scale(t.elapsed().as_nanos()), sum);
}

/// splitmix64's output for `n + 1`: a bijection, so distinct `n` give
/// distinct keys, scattered over all 64 bits.
fn scatter(n: i64) -> i64 {
    let mut z = (n as u64).wrapping_add(1).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    (z ^ (z >> 31)) as i64
}

/// `v` shuffled by Fisher-Yates, swap `i` choosing `scatter(SEED + i) % (i + 1)`.
fn shuffled(mut v: Vec<i64>) -> Vec<i64> {
    for i in (1..v.len()).rev() {
        let j = (scatter(SEED + i as i64) as u64 % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
    v
}

const SEED: i64 = 0x5eed;

/// The ops of `sized` on random keys (`scatter` of 0, 1, ...), read from
/// arrays made before the timing; hits look the keys up in shuffled order.
fn random(s: i64) {
    let total = 4 * N;
    let k = if s < N { N / s } else { 1 };
    let reps = total / (k * s);
    let name = format!("rnd{s}");
    let keys: Vec<i64> = (0..k * s).map(scatter).collect();
    let (mut ins, mut rem, mut check) = (0u128, 0u128, 0i64);
    for _ in 0..reps {
        let mut maps: Vec<Map> = (0..k).map(|_| Map::default()).collect();
        let t = Instant::now();
        for (m, ks) in maps.iter_mut().zip(keys.chunks(s as usize)) {
            for (i, &key) in ks.iter().enumerate() {
                m.insert(key, i as i64);
            }
        }
        ins += t.elapsed().as_nanos();
        let t = Instant::now();
        for (m, ks) in maps.iter_mut().zip(keys.chunks(s as usize)) {
            for &key in ks {
                check += (|m: &mut Map, k: &i64| m.remove(k))(m, &key).unwrap_or(0);
            }
        }
        rem += t.elapsed().as_nanos();
        black_box(&maps);
    }
    let scale = |ns: u128| ns * N as u128 / total as u128;
    out(&name, "insert", scale(ins), reps * k * s);
    out(&name, "remove", scale(rem), check);
    let mut m = Map::default();
    for (i, &key) in keys[..s as usize].iter().enumerate() {
        m.insert(key, i as i64);
    }
    let hit = shuffled(keys[..s as usize].to_vec());
    let miss: Vec<i64> = (0..s).map(|i| scatter(8 * N + i)).collect();
    let rounds = total / s;
    let mut sum = 0i64;
    let t = Instant::now();
    for _ in 0..rounds {
        for &key in black_box(&hit) {
            if let Some(v) = m.get(&key) {
                sum += v;
            }
        }
    }
    out(&name, "hit", scale(t.elapsed().as_nanos()), sum);
    let mut found = 0i64;
    let t = Instant::now();
    for _ in 0..rounds {
        for key in black_box(&miss) {
            if m.contains_key(key) {
                found += 1;
            }
        }
    }
    out(&name, "miss", scale(t.elapsed().as_nanos()), found);
    sum = 0;
    let t = Instant::now();
    for _ in 0..rounds {
        for v in black_box(&m).values() {
            sum += v;
        }
    }
    out(&name, "iterate", scale(t.elapsed().as_nanos()), sum);
}

/// `text(n)` of bench/hash/WORKLOADS.md: 7 to 27 bytes, distinct by
/// the part after `#`.
fn text(n: i64) -> String {
    format!("{}#{}", (scatter(n) as u64) >> (n % 48), n)
}

/// `big(i)`: eight integers from `i`.
fn big(i: i64) -> [i64; 8] {
    [i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7]
}

/// One lookup at a time, each waiting for the last: the map is one
/// cycle through its keys, in shuffled order. Each key `scatter(i)` is
/// put in order of `i`, with the key after it in the cycle as its value,
/// so a map that keeps its entries in order meets them out of order.
fn latency(s: i64) {
    let total = 4 * N;
    let p = shuffled((0..s).collect());
    let mut m = Map::default();
    let mut next = vec![0i64; s as usize];
    for t in 0..s as usize {
        next[p[t] as usize] = p[(t + 1) % s as usize];
    }
    for i in 0..s {
        m.insert(scatter(i), scatter(next[i as usize]));
    }
    let mut key = scatter(p[0]);
    let t = Instant::now();
    for _ in 0..total {
        key = m[&key];
    }
    out(&format!("lat{s}"), "chain", t.elapsed().as_nanos() * N as u128 / total as u128, key);
}

/// A map of `s` keys turned over: each step removes the oldest key and
/// inserts a new one.
fn churn(s: i64) {
    let total = 4 * N;
    let turns = total / 2;
    let keys: Vec<i64> = (0..s + turns).map(scatter).collect();
    let mut m = Map::default();
    for i in 0..s {
        m.insert(keys[i as usize], i);
    }
    let mut check = 0i64;
    let t = Instant::now();
    for i in 0..turns {
        check = check.wrapping_add(m.remove(&keys[i as usize]).unwrap_or(0));
        m.insert(keys[(s + i) as usize], s + i);
    }
    out(&format!("churn{s}"), "turnover", t.elapsed().as_nanos() * N as u128 / total as u128, check);
    black_box(&m);
}

/// Lookups that hit half the time, in shuffled order.
fn mixed(s: i64) {
    let total = 4 * N;
    let mut m = Map::default();
    for i in 0..s {
        m.insert(scatter(i), i);
    }
    let look = shuffled((0..s).map(|i| if i % 2 == 0 { scatter(i) } else { scatter(8 * N + i) }).collect());
    let mut sum = 0i64;
    let t = Instant::now();
    for _ in 0..total / s {
        for key in black_box(&look) {
            if let Some(v) = m.get(key) {
                sum += v;
            }
        }
    }
    out(&format!("mix{s}"), "half", t.elapsed().as_nanos() * N as u128 / total as u128, sum);
}

/// Text keys, each moved into the map and found by an equal text made
/// apart; a million operations a row.
fn strings(s: i64) {
    let k = if s < N { N / s } else { 1 };
    let reps = N / (k * s);
    let name = format!("str{s}");
    let (mut ins, mut rem, mut check) = (0u128, 0u128, 0i64);
    for _ in 0..reps {
        let mut put: Vec<String> = (0..k * s).map(text).collect();
        let take: Vec<String> = (0..k * s).map(text).collect();
        let mut maps: Vec<StrMap> = (0..k).map(|_| StrMap::default()).collect();
        let t = Instant::now();
        let mut put_at = put.drain(..);
        for m in maps.iter_mut() {
            for i in 0..s {
                m.insert(put_at.next().unwrap(), i);
            }
        }
        ins += t.elapsed().as_nanos();
        drop(put_at);
        let t = Instant::now();
        for (m, ks) in maps.iter_mut().zip(take.chunks(s as usize)) {
            for key in ks {
                check += m.remove(key.as_str()).unwrap_or(0);
            }
        }
        rem += t.elapsed().as_nanos();
        black_box(&maps);
    }
    out(&name, "insert", ins, reps * k * s);
    out(&name, "remove", rem, check);
    let mut m = StrMap::default();
    for i in 0..s {
        m.insert(text(i), i);
    }
    let hit: Vec<String> = shuffled((0..s).collect()).into_iter().map(text).collect();
    let miss: Vec<String> = (0..s).map(|i| text(8 * N + i)).collect();
    let mut sum = 0i64;
    let t = Instant::now();
    for _ in 0..N / s {
        for key in black_box(&hit) {
            if let Some(v) = m.get(key.as_str()) {
                sum += v;
            }
        }
    }
    out(&name, "hit", t.elapsed().as_nanos(), sum);
    let mut found = 0i64;
    let t = Instant::now();
    for _ in 0..N / s {
        for key in black_box(&miss) {
            if m.contains_key(key.as_str()) {
                found += 1;
            }
        }
    }
    out(&name, "miss", t.elapsed().as_nanos(), found);
}

/// `random`'s insert, remove, hit and iterate with a value of eight
/// integers.
fn bigs(s: i64) {
    let total = 4 * N;
    let k = if s < N { N / s } else { 1 };
    let reps = total / (k * s);
    let name = format!("big{s}");
    let keys: Vec<i64> = (0..k * s).map(scatter).collect();
    let (mut ins, mut rem, mut check) = (0u128, 0u128, 0i64);
    for _ in 0..reps {
        let mut maps: Vec<BigMap> = (0..k).map(|_| BigMap::default()).collect();
        let t = Instant::now();
        for (m, ks) in maps.iter_mut().zip(keys.chunks(s as usize)) {
            for (i, &key) in ks.iter().enumerate() {
                m.insert(key, big(i as i64));
            }
        }
        ins += t.elapsed().as_nanos();
        let t = Instant::now();
        for (m, ks) in maps.iter_mut().zip(keys.chunks(s as usize)) {
            for key in ks {
                if let Some(v) = m.remove(key) {
                    check += v[7];
                }
            }
        }
        rem += t.elapsed().as_nanos();
        black_box(&maps);
    }
    let scale = |ns: u128| ns * N as u128 / total as u128;
    out(&name, "insert", scale(ins), reps * k * s);
    out(&name, "remove", scale(rem), check);
    let mut m = BigMap::default();
    for (i, &key) in keys[..s as usize].iter().enumerate() {
        m.insert(key, big(i as i64));
    }
    let hit = shuffled(keys[..s as usize].to_vec());
    let mut sum = 0i64;
    let t = Instant::now();
    for _ in 0..total / s {
        for key in black_box(&hit) {
            if let Some(v) = m.get(key) {
                sum += v[7];
            }
        }
    }
    out(&name, "hit", scale(t.elapsed().as_nanos()), sum);
    sum = 0;
    let t = Instant::now();
    for _ in 0..total / s {
        for v in black_box(&m).values() {
            sum += v[0];
        }
    }
    out(&name, "iterate", scale(t.elapsed().as_nanos()), sum);
}

/// `mem`: one map of 4,000,000 keys, for its peak memory; `mem0`: the
/// keys alone, the baseline.
fn memory(with_map: bool) {
    let n = 4_000_000i64;
    let keys: Vec<i64> = (0..n).map(scatter).collect();
    if !with_map {
        println!("mem0 {n} len {}", black_box(&keys).len());
        return;
    }
    let mut m = Map::default();
    for (i, &key) in keys.iter().enumerate() {
        m.insert(key, i as i64);
    }
    println!("mem {n} len {}", black_box(&m).len());
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("mem") => return memory(true),
        Some("mem0") => return memory(false),
        _ => {}
    }
    for s in [16, 1000, 100_000, 4_000_000] {
        sized(s);
    }
    for s in [16, 24, 1000, 1500, 100_000, 150_000, 3_000_000, 4_000_000] {
        random(s);
    }
    for s in [16, 1000, 100_000, 4_000_000] {
        latency(s);
    }
    for s in [16, 1000, 100_000, 4_000_000] {
        churn(s);
    }
    for s in [16, 1000, 100_000, 4_000_000] {
        mixed(s);
    }
    for s in [16, 1000, 100_000, 1_000_000] {
        strings(s);
    }
    for s in [16, 1000, 100_000, 1_000_000] {
        bigs(s);
    }
}
