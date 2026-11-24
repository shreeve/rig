// The replay every Rust arm runs (bench/hash/replay/README.md, "The
// trace"), included by each program in src/bin after it names its table
// (`Map`) and hash (`S`). Prints `KIND NS OPS CHECK` per kind of segment
// and `total NS OPS CHECK`, as replay.rig does; the checks must agree.
use std::hash::Hash;
use std::time::Instant;

#[derive(Clone, PartialEq, Eq, Hash)]
struct Pair {
    a: i64,
    b: i64,
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct Triple {
    a: i64,
    b: i64,
    c: i64,
}

const PUT: u8 = 0;
const GET: u8 = 1;
const TAKE: u8 = 2;
const WALK: u8 = 3;
const CLEAR: u8 = 6;

const NAMES: [&str; 16] = [
    "insert", "overwrite", "hit", "miss", "remove", "iterate", "new", "drop", "clear", "mixed", "mixed", "mixed",
    "mixed", "mixed", "mixed", "mixed",
];

fn u32_at(d: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(d[at..at + 4].try_into().unwrap())
}

fn i64_at(d: &[u8], at: usize) -> i64 {
    i64::from_le_bytes(d[at..at + 8].try_into().unwrap())
}

#[inline(always)]
fn value<const N: usize>(j: usize) -> [i64; N] {
    let mut v = [j as i64; N];
    for (w, x) in v.iter_mut().enumerate() {
        *x = j as i64 + w as i64;
    }
    v
}

fn new_map<K, const N: usize>() -> Map<K, N> {
    Map::with_hasher(S::default())
}

struct Ops {
    op: Vec<u8>,
    inst: Vec<u32>,
    key: Vec<u32>,
}

#[inline(never)]
fn put_run<K: Hash + Eq, const N: usize>(maps: &mut [Map<K, N>], owned: &mut Vec<K>, o: &Ops, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let m = &mut maps[o.inst[j] as usize];
        let k = owned.pop().unwrap();
        m.insert(k, value::<N>(j));
        check = check.wrapping_add(m.len() as i64);
    }
    (t.elapsed().as_nanos(), check)
}

#[inline(never)]
fn get_run<K: Hash + Eq, const N: usize>(maps: &[Map<K, N>], keys: &[K], o: &Ops, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let m = &maps[o.inst[j] as usize];
        if let Some(v) = m.get(&keys[o.key[j] as usize]) {
            check = check.wrapping_add(v[0] + 1);
        }
    }
    (t.elapsed().as_nanos(), check)
}

#[inline(never)]
fn take_run<K: Hash + Eq, const N: usize>(maps: &mut [Map<K, N>], keys: &[K], o: &Ops, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let m = &mut maps[o.inst[j] as usize];
        if let Some(v) = m.remove(&keys[o.key[j] as usize]) {
            check = check.wrapping_add(v[N - 1] + 1);
        }
    }
    (t.elapsed().as_nanos(), check)
}

#[inline(never)]
fn walk_run<K: Hash + Eq, const N: usize>(maps: &[Map<K, N>], o: &Ops, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let m = &maps[o.inst[j] as usize];
        for v in m.values() {
            check = check.wrapping_add(v[0]);
        }
        check = check.wrapping_add(m.len() as i64);
    }
    (t.elapsed().as_nanos(), check)
}

#[inline(never)]
fn life_run<K: Hash + Eq, const N: usize>(maps: &mut [Map<K, N>], o: &Ops, clear: bool, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let i = o.inst[j] as usize;
        check = check.wrapping_add(maps[i].len() as i64 + 1);
        if clear {
            maps[i].clear();
        } else {
            maps[i] = new_map();
        }
    }
    (t.elapsed().as_nanos(), check)
}

#[inline(never)]
fn mixed_run<K: Hash + Eq, const N: usize>(maps: &mut [Map<K, N>], owned: &mut Vec<K>, keys: &[K], o: &Ops, at: usize, n: usize) -> (u128, i64) {
    let mut check = 0i64;
    let t = Instant::now();
    for j in at..at + n {
        let i = o.inst[j] as usize;
        match o.op[j] {
            GET => {
                if let Some(v) = maps[i].get(&keys[o.key[j] as usize]) {
                    check = check.wrapping_add(v[0] + 1);
                }
            }
            PUT => {
                let k = owned.pop().unwrap();
                maps[i].insert(k, value::<N>(j));
                check = check.wrapping_add(maps[i].len() as i64);
            }
            TAKE => {
                if let Some(v) = maps[i].remove(&keys[o.key[j] as usize]) {
                    check = check.wrapping_add(v[N - 1] + 1);
                }
            }
            WALK => {
                for v in maps[i].values() {
                    check = check.wrapping_add(v[0]);
                }
                check = check.wrapping_add(maps[i].len() as i64);
            }
            CLEAR => {
                check = check.wrapping_add(maps[i].len() as i64 + 1);
                maps[i].clear();
            }
            _ => {
                check = check.wrapping_add(maps[i].len() as i64 + 1);
                maps[i] = new_map();
            }
        }
    }
    (t.elapsed().as_nanos(), check)
}

fn replay<K: Hash + Eq + Clone, const N: usize>(keys: Vec<K>, d: &[u8]) {
    let instances = u32_at(d, 12) as usize;
    let nops = u32_at(d, 20) as usize;
    let nsegs = u32_at(d, 24) as usize;
    let mut at = u32_at(d, 32) as usize;
    let op = d[at..at + nops].to_vec();
    at += nops.div_ceil(4) * 4;
    let inst: Vec<u32> = (0..nops).map(|j| u32_at(d, at + 4 * j)).collect();
    at += 4 * nops;
    let key: Vec<u32> = (0..nops).map(|j| u32_at(d, at + 4 * j)).collect();
    at += 4 * nops;
    let o = Ops { op, inst, key };
    // The keys each put moves in, made apart from the ones lookups use,
    // last first, so each put pops its own.
    let mut owned: Vec<K> = Vec::new();
    for j in (0..nops).rev() {
        if o.op[j] == PUT {
            owned.push(keys[o.key[j] as usize].clone());
        }
    }
    let mut maps: Vec<Map<K, N>> = (0..instances).map(|_| new_map()).collect();
    let mut ns = [0u128; 16];
    let mut cnt = [0usize; 16];
    let mut chk = [0i64; 16];
    for s in 0..nsegs {
        let kind = u32_at(d, at + 12 * s) as usize;
        let from = u32_at(d, at + 12 * s + 4) as usize;
        let count = u32_at(d, at + 12 * s + 8) as usize;
        let r = match kind {
            0 | 1 => put_run(&mut maps, &mut owned, &o, from, count),
            2 | 3 => get_run(&maps, &keys, &o, from, count),
            4 => take_run(&mut maps, &keys, &o, from, count),
            5 => walk_run(&maps, &o, from, count),
            6 | 7 => life_run(&mut maps, &o, false, from, count),
            8 => life_run(&mut maps, &o, true, from, count),
            _ => mixed_run(&mut maps, &mut owned, &keys, &o, from, count),
        };
        ns[kind] += r.0;
        cnt[kind] += count;
        chk[kind] = chk[kind].wrapping_add(r.1);
    }
    let (mut tns, mut tchk) = (0u128, 0i64);
    for k in 0..16 {
        if cnt[k] > 0 {
            println!("{} {} {} {}", NAMES[k], ns[k], cnt[k], chk[k]);
            tns += ns[k];
            tchk = tchk.wrapping_add(chk[k]);
        }
    }
    println!("total {} {} {}", tns, nops, tchk);
}

fn by_value<K: Hash + Eq + Clone>(keys: Vec<K>, d: &[u8]) {
    match u32_at(d, 8) {
        1 => replay::<K, 1>(keys, d),
        2 => replay::<K, 2>(keys, d),
        4 => replay::<K, 4>(keys, d),
        8 => replay::<K, 8>(keys, d),
        _ => panic!("replay: values of 1, 2, 4 or 8 Ints"),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: replay TRACE");
    let d = std::fs::read(path).expect("replay: cannot read the trace");
    assert!(d.len() >= 36 && u32_at(&d, 0) == 0x314c5052, "replay: not a trace");
    let kind = u32_at(&d, 4);
    let n = u32_at(&d, 16) as usize;
    let at = 36;
    match kind {
        0 => by_value((0..n).map(|i| u32_at(&d, at + 8 * i)).collect::<Vec<u32>>(), &d),
        1 => by_value((0..n).map(|i| i64_at(&d, at + 8 * i)).collect::<Vec<i64>>(), &d),
        2 => by_value((0..n).map(|i| Pair { a: i64_at(&d, at + 16 * i), b: i64_at(&d, at + 16 * i + 8) }).collect(), &d),
        3 => by_value(
            (0..n)
                .map(|i| Triple { a: i64_at(&d, at + 24 * i), b: i64_at(&d, at + 24 * i + 8), c: i64_at(&d, at + 24 * i + 16) })
                .collect(),
            &d,
        ),
        _ => {
            let base = at + 4 * (n + 1);
            let ks: Vec<String> = (0..n)
                .map(|i| {
                    let (a, b) = (u32_at(&d, at + 4 * i) as usize, u32_at(&d, at + 4 * i + 4) as usize);
                    String::from_utf8(d[base + a..base + b].to_vec()).expect("replay: a text key that is not UTF-8")
                })
                .collect();
            by_value(ks, &d)
        }
    }
}
