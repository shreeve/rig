//! Memory census (measurement copy only, not for landing): every arena allocation by Rust type.
//!
//! `TSRS_CENSUS=PATH`: each typed arena allocation (`Arena::alloc_with`, `alloc_slice_copy`, `alloc_vec`,
//! `alloc_str`, the free-list paths `P::new_recycled` / `alloc_slice_recycled`, and the untyped
//! `alloc_layout` callers in `ptr.rs`) appends (address, bytes, alignment padding, type, store, sequence).
//! Every event that makes arena memory dead appends a kill range: a block pushed on a free list, a rewind, a
//! freed region's chunks. At `check end` (memsplit's report) an allocation is live when no later kill covers
//! its address; the table per type is written to PATH. Bookkeeping lives on the heap (suspended for the heap
//! census through `HEAP_SUSPEND`).

use std::collections::HashMap;
use std::io::Write;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU8, Ordering};

static MODE: AtomicU8 = AtomicU8::new(0); // 0 unknown, 1 on, 2 off

#[inline]
pub fn enabled() -> bool {
    match MODE.load(Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => init_mode(),
    }
}

#[cold]
fn init_mode() -> bool {
    let on = std::env::var_os("TSRS_CENSUS").is_some();
    MODE.store(if on { 1 } else { 2 }, Ordering::Relaxed);
    on
}

/// Store of an allocation: 0 thread arena, 1 registered region, 2 scratch (unregistered) region.
pub const STORE_THREAD: u8 = 0;

#[derive(Clone, Copy)]
struct Rec {
    addr: u64,
    size: u32,
    seq: u32,
    ty: u16,
    store: u8,
    pad: u8,
}

struct TypeInfo {
    name: &'static str,
    size_of: usize,
    align_of: usize,
    slice: bool,
}

#[derive(Default)]
struct State {
    recs: Vec<Rec>,
    /// (start, end, seq, kind): kind 1 free list, 2 rewind, 3 region freed.
    kills: Vec<(usize, usize, u32, u8)>,
    types: Vec<TypeInfo>,
    by_ptr: HashMap<(usize, usize, bool), u16>,
    seq: u32,
    parse_end_seq: u32,
    big: u64,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Set by the heap census around census bookkeeping (installed from the binary).
pub static HEAP_SUSPEND: std::sync::OnceLock<fn(bool) -> bool> = std::sync::OnceLock::new();
/// The heap census's dump, called at `check end` (installed from the binary).
pub static HEAP_DUMP: std::sync::OnceLock<fn()> = std::sync::OnceLock::new();

fn suspend(on: bool) -> bool {
    HEAP_SUSPEND.get().map_or(false, |f| f(on))
}

pub fn record_raw(
    name: &'static str,
    size_of: usize,
    align_of: usize,
    slice: bool,
    addr: usize,
    bytes: usize,
    taken: usize,
    store: u8,
) {
    let prev = suspend(true);
    {
        let mut g = STATE.lock().unwrap();
        let s = g.get_or_insert_with(State::default);
        let key = (name.as_ptr() as usize, name.len(), slice);
        let ty = match s.by_ptr.get(&key) {
            Some(&t) => t,
            None => {
                let t = u16::try_from(s.types.len()).expect("census: too many types");
                s.types.push(TypeInfo { name, size_of, align_of, slice });
                s.by_ptr.insert(key, t);
                t
            }
        };
        s.seq += 1;
        let size = u32::try_from(bytes).unwrap_or_else(|_| {
            s.big += bytes as u64;
            u32::MAX
        });
        let pad = taken.saturating_sub(bytes).min(255) as u8;
        s.recs.push(Rec { addr: addr as u64, size, seq: s.seq, ty, store, pad });
    }
    suspend(prev);
}

#[inline]
pub fn record<T>(slice: bool, addr: usize, bytes: usize, taken: usize, store: u8) {
    record_raw(
        std::any::type_name::<T>(),
        std::mem::size_of::<T>(),
        std::mem::align_of::<T>(),
        slice,
        addr,
        bytes,
        taken,
        store,
    );
}

pub fn kill(start: usize, len: usize, kind: u8) {
    if len == 0 {
        return;
    }
    let prev = suspend(true);
    {
        let mut g = STATE.lock().unwrap();
        let s = g.get_or_insert_with(State::default);
        s.seq += 1;
        let seq = s.seq;
        s.kills.push((start, start + len, seq, kind));
    }
    suspend(prev);
}

pub fn mark_parse_end() {
    let mut g = STATE.lock().unwrap();
    let s = g.get_or_insert_with(State::default);
    s.parse_end_seq = s.seq;
}

#[derive(Default, Clone)]
struct Agg {
    alloc_n: u64,
    alloc_b: u64,
    live_n: u64,
    live_b: u64,
    live_taken: u64,
    live_parse_b: u64,
    live_region_b: u64,
    dead_free_b: u64,
    dead_rewind_b: u64,
    dead_region_b: u64,
}

/// Writes the census (memsplit's `check end`). `free_lists` = (blocks, bytes) on the thread arenas' free lists.
pub fn dump_at_check_end(free_lists: (usize, usize), arena_used: usize) {
    if let Some(f) = HEAP_DUMP.get() {
        f();
    }
    if !enabled() {
        return;
    }
    let prev = suspend(true);
    let path = std::env::var("TSRS_CENSUS").unwrap();
    let mut g = STATE.lock().unwrap();
    let Some(s) = g.as_mut() else {
        return;
    };
    let parse_end = s.parse_end_seq;
    let mut kills = std::mem::take(&mut s.kills);
    kills.sort_unstable_by_key(|k| k.0);
    s.recs.sort_unstable_by_key(|r| r.addr);
    let mut aggs: Vec<Agg> = vec![Agg::default(); s.types.len()];
    // Max-seq heap of the kill ranges that start at or before the address; expired ones are dropped lazily.
    let mut heap: std::collections::BinaryHeap<(u32, usize, u8)> = std::collections::BinaryHeap::new();
    let mut ki = 0;
    for r in &s.recs {
        let addr = r.addr as usize;
        while ki < kills.len() && kills[ki].0 <= addr {
            heap.push((kills[ki].2, kills[ki].1, kills[ki].3));
            ki += 1;
        }
        while let Some(&(_, end, _)) = heap.peek() {
            if end <= addr {
                heap.pop();
            } else {
                break;
            }
        }
        let a = &mut aggs[r.ty as usize];
        let b = u64::from(r.size);
        a.alloc_n += 1;
        a.alloc_b += b;
        match heap.peek() {
            Some(&(seq, _, kind)) if seq > r.seq => match kind {
                1 => a.dead_free_b += b,
                2 => a.dead_rewind_b += b,
                _ => a.dead_region_b += b,
            },
            _ => {
                a.live_n += 1;
                a.live_b += b;
                a.live_taken += b + u64::from(r.pad);
                if r.seq <= parse_end {
                    a.live_parse_b += b;
                }
                if r.store != STORE_THREAD {
                    a.live_region_b += b;
                }
            }
        }
    }
    // Merge types whose names are equal (type_name may give one string per crate).
    let mut merged: HashMap<(String, bool), (usize, usize, Agg)> = HashMap::new();
    for (t, a) in s.types.iter().zip(&aggs) {
        let e = merged.entry((t.name.to_string(), t.slice)).or_insert((t.size_of, t.align_of, Agg::default()));
        let m = &mut e.2;
        m.alloc_n += a.alloc_n;
        m.alloc_b += a.alloc_b;
        m.live_n += a.live_n;
        m.live_b += a.live_b;
        m.live_taken += a.live_taken;
        m.live_parse_b += a.live_parse_b;
        m.live_region_b += a.live_region_b;
        m.dead_free_b += a.dead_free_b;
        m.dead_rewind_b += a.dead_rewind_b;
        m.dead_region_b += a.dead_region_b;
    }
    let mut rows: Vec<_> = merged.into_iter().collect();
    rows.sort_by(|a, b| b.1.2.live_taken.cmp(&a.1.2.live_taken));
    let mut out = std::io::BufWriter::new(std::fs::File::create(&path).unwrap());
    let tot_live: u64 = rows.iter().map(|r| r.1.2.live_taken).sum();
    let tot_live_thread: u64 = rows.iter().map(|r| r.1.2.live_taken - r.1.2.live_region_b).sum();
    let _ = writeln!(
        out,
        "# records {} kills {} big {} | live taken {} (thread arenas approx {}) | memsplit arena used {} | free lists {} blocks {} bytes",
        s.recs.len(),
        kills.len(),
        s.big,
        tot_live,
        tot_live_thread,
        arena_used,
        free_lists.0,
        free_lists.1
    );
    let _ = writeln!(
        out,
        "type\tslice\tsize_of\talign_of\talloc_n\talloc_b\tlive_n\tlive_b\tlive_taken\tlive_parse_b\tlive_region_b\tdead_free_b\tdead_rewind_b\tdead_region_b"
    );
    for ((name, slice), (sz, al, a)) in rows {
        let _ = writeln!(
            out,
            "{name}\t{}\t{sz}\t{al}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            u8::from(slice),
            a.alloc_n,
            a.alloc_b,
            a.live_n,
            a.live_b,
            a.live_taken,
            a.live_parse_b,
            a.live_region_b,
            a.dead_free_b,
            a.dead_rewind_b,
            a.dead_region_b
        );
    }
    drop(out);
    suspend(prev);
}
