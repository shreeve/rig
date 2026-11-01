// mapmem: the heap bytes hashbrown's HashMap and indexmap's IndexMap
// request for n entries of each shape (a counting global allocator, so
// the bytes asked for, not the allocator's size classes).
use std::alloc::{GlobalAlloc, Layout, System};

use std::sync::atomic::{AtomicIsize, Ordering::Relaxed};

struct Counting;
static LIVE: AtomicIsize = AtomicIsize::new(0);
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 { LIVE.fetch_add(l.size() as isize, Relaxed); unsafe { System.alloc(l) } }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) { LIVE.fetch_sub(l.size() as isize, Relaxed); unsafe { System.dealloc(p, l) } }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        LIVE.fetch_add(n as isize - l.size() as isize, Relaxed); unsafe { System.realloc(p, l, n) }
    }
}
#[global_allocator]
static A: Counting = Counting;

type H = foldhash::fast::RandomState;
#[derive(Clone, Copy)]
#[allow(dead_code)]
struct Big([u64; 8]);

macro_rules! measure {
    ($label:expr, $ty:ty, $n:expr, $k:expr, $v:expr) => {{
        let a = LIVE.load(Relaxed);
        let mut m: $ty = Default::default();
        for i in 0..$n { let i = i as u64; m.insert($k(i), $v(i)); }
        let b = LIVE.load(Relaxed);
        println!("{} {} {} {} {}", $label, $n, b - a, m.len(), std::mem::size_of::<$ty>());
        drop(std::hint::black_box(m));
    }};
}

fn main() {
    let mut sizes: Vec<usize> = (0..65).collect();
    sizes.extend([96, 100, 128, 129, 200, 256, 257, 448, 512, 513, 1000, 1500, 1792, 2048, 2049, 4096, 7168, 8192, 8193, 10000, 14336, 16384, 16385, 100000, 114688, 131072, 131073, 150000, 1000000, 1048576, 1048577]);
    for &n in &sizes {
        measure!("hashbrown u32u32", hashbrown::HashMap<u32, u32, H>, n, |i| i as u32, |i| i as u32);
        measure!("indexmap u32u32", indexmap::IndexMap<u32, u32, H>, n, |i| i as u32, |i| i as u32);
        measure!("hashbrown intint", hashbrown::HashMap<u64, u64, H>, n, |i| i, |i| i);
        measure!("indexmap intint", indexmap::IndexMap<u64, u64, H>, n, |i| i, |i| i);
        measure!("hashbrown intbig", hashbrown::HashMap<u64, Big, H>, n, |i| i, |i| Big([i; 8]));
        measure!("indexmap intbig", indexmap::IndexMap<u64, Big, H>, n, |i| i, |i| Big([i; 8]));
        measure!("hashbrown strint", hashbrown::HashMap<String, u64, H>, n, |i| format!("key{i}"), |i| i);
        measure!("indexmap strint", indexmap::IndexMap<String, u64, H>, n, |i| format!("key{i}"), |i| i);
    }
}
