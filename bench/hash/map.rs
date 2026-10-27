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

type Map = HashMap<i64, i64, BuildHasherDefault<Fx>>;

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

fn main() {
    for s in [16, 1000, 100_000, 4_000_000] {
        sized(s);
    }
    for s in [16, 1000, 100_000, 4_000_000] {
        random(s);
    }
}
