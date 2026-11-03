//! Heap census (measurement copy only): a global allocator over mimalloc that, with `TSRS_HEAP_CENSUS=PATH`, keeps
//! every live heap block with its size and its allocating stack (frame-pointer walk; build with
//! `-C force-frame-pointers=yes`), and at `check end` writes live bytes per stack to PATH (resolved offline).

use std::alloc::{GlobalAlloc, Layout};
use std::cell::Cell;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::io::Write;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

const D: usize = 28;

#[derive(Default)]
pub struct H(u64);
impl Hasher for H {
    fn write(&mut self, b: &[u8]) {
        for &x in b {
            self.write_u64(u64::from(x));
        }
    }
    fn write_u64(&mut self, i: u64) {
        self.0 = (self.0.rotate_left(5) ^ i).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
    fn write_usize(&mut self, i: usize) {
        self.write_u64(i as u64);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}
type B = BuildHasherDefault<H>;

struct State {
    live: HashMap<usize, (u32, u32), B>,
    stacks: HashMap<[usize; D], u32, B>,
    list: Vec<[usize; D]>,
    allocs: u64,
    alloc_bytes: u64,
}

static ON: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<Option<State>> = Mutex::new(None);

thread_local! {
    static GUARD: Cell<bool> = const { Cell::new(false) };
    static STACK_HI: Cell<usize> = const { Cell::new(0) };
}

pub struct Counting;

pub fn init() {
    if std::env::var_os("TSRS_HEAP_CENSUS").is_none() {
        return;
    }
    GUARD.with(|g| g.set(true));
    *STATE.lock().unwrap() = Some(State {
        live: HashMap::with_capacity_and_hasher(1 << 22, B::default()),
        stacks: HashMap::with_capacity_and_hasher(1 << 18, B::default()),
        list: Vec::with_capacity(1 << 18),
        allocs: 0,
        alloc_bytes: 0,
    });
    let _ = tsrs_core::census::HEAP_SUSPEND.set(suspend);
    let _ = tsrs_core::census::HEAP_DUMP.set(dump);
    GUARD.with(|g| g.set(false));
    ON.store(true, Ordering::Release);
}

fn suspend(on: bool) -> bool {
    GUARD.with(|g| g.replace(on))
}

fn stack_hi() -> usize {
    let h = STACK_HI.with(Cell::get);
    if h != 0 {
        return h;
    }
    // SAFETY: pthread_getattr_np fills the attribute object for the calling thread; destroyed after use.
    let hi = unsafe {
        let mut attr: libc::pthread_attr_t = std::mem::zeroed();
        if libc::pthread_getattr_np(libc::pthread_self(), &raw mut attr) != 0 {
            return 0;
        }
        let mut addr: *mut libc::c_void = std::ptr::null_mut();
        let mut size: libc::size_t = 0;
        libc::pthread_attr_getstack(&raw const attr, &raw mut addr, &raw mut size);
        libc::pthread_attr_destroy(&raw mut attr);
        addr as usize + size
    };
    STACK_HI.with(|c| c.set(hi));
    hi
}

#[inline(always)]
fn capture(out: &mut [usize; D]) {
    let mut fp: usize;
    // SAFETY: reads the frame pointer register.
    unsafe { std::arch::asm!("mov {}, rbp", out(reg) fp, options(nomem, nostack, preserves_flags)) };
    let hi = stack_hi();
    let lo = fp;
    let mut n = 0;
    while n < D {
        if fp < lo || fp + 16 > hi || fp % 8 != 0 {
            break;
        }
        // SAFETY: `fp` lies in this thread's stack, between the current frame and the top.
        let (next, ret) = unsafe { (*(fp as *const usize), *((fp + 8) as *const usize)) };
        if ret < 4096 {
            break;
        }
        out[n] = ret;
        n += 1;
        if next <= fp {
            break;
        }
        fp = next;
    }
}

#[inline(never)]
fn note_alloc(p: *mut u8, size: usize) {
    if p.is_null() || GUARD.with(|g| g.replace(true)) {
        return;
    }
    let mut st = [0usize; D];
    capture(&mut st);
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        let n = s.list.len() as u32;
        let id = *s.stacks.entry(st).or_insert(n);
        if id == n {
            s.list.push(st);
        }
        s.live.insert(p as usize, (u32::try_from(size).unwrap_or(u32::MAX), id));
        s.allocs += 1;
        s.alloc_bytes += size as u64;
    }
    GUARD.with(|g| g.set(false));
}

#[inline(never)]
fn note_free(p: *mut u8) {
    if GUARD.with(|g| g.replace(true)) {
        return;
    }
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        s.live.remove(&(p as usize));
    }
    GUARD.with(|g| g.set(false));
}

unsafe extern "C" {
    fn mi_usable_size(p: *const std::ffi::c_void) -> usize;
}

// SAFETY: forwards to mimalloc; the census only observes.
unsafe impl GlobalAlloc for Counting {
    #[inline]
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        // SAFETY: forwarded.
        let p = unsafe { mimalloc_safe::MiMalloc.alloc(l) };
        if ON.load(Ordering::Relaxed) {
            note_alloc(p, l.size());
        }
        p
    }
    #[inline]
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        // SAFETY: forwarded.
        let p = unsafe { mimalloc_safe::MiMalloc.alloc_zeroed(l) };
        if ON.load(Ordering::Relaxed) {
            note_alloc(p, l.size());
        }
        p
    }
    #[inline]
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        if ON.load(Ordering::Relaxed) {
            note_free(p);
        }
        // SAFETY: forwarded.
        unsafe { mimalloc_safe::MiMalloc.dealloc(p, l) }
    }
    #[inline]
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        if ON.load(Ordering::Relaxed) {
            note_free(p);
        }
        // SAFETY: forwarded.
        let q = unsafe { mimalloc_safe::MiMalloc.realloc(p, l, new) };
        if ON.load(Ordering::Relaxed) {
            note_alloc(q, new);
        }
        q
    }
}

fn dump() {
    if !ON.load(Ordering::Relaxed) {
        return;
    }
    let prev = suspend(true);
    let path = std::env::var("TSRS_HEAP_CENSUS").unwrap();
    let g = STATE.lock().unwrap();
    let s = g.as_ref().unwrap();
    // Per stack: live blocks, requested bytes, usable bytes.
    let mut per: Vec<(u64, u64, u64)> = vec![(0, 0, 0); s.list.len()];
    for (&p, &(size, id)) in &s.live {
        let e = &mut per[id as usize];
        e.0 += 1;
        e.1 += u64::from(size);
        // SAFETY: a live mimalloc block.
        e.2 += unsafe { mi_usable_size(p as *const std::ffi::c_void) } as u64;
    }
    let mut out = std::io::BufWriter::new(std::fs::File::create(&path).unwrap());
    let (n, b, u) = per.iter().fold((0, 0, 0), |a, e| (a.0 + e.0, a.1 + e.1, a.2 + e.2));
    let _ = writeln!(
        out,
        "# live blocks {n} requested {b} usable {u} | allocations {} bytes {} | stacks {}",
        s.allocs,
        s.alloc_bytes,
        s.list.len()
    );
    if let Ok(maps) = std::fs::read_to_string("/proc/self/maps") {
        for l in maps.lines().filter(|l| l.contains("tsrs") || l.contains(".so")) {
            let _ = writeln!(out, "map {l}");
        }
    }
    for (id, e) in per.iter().enumerate() {
        if e.0 == 0 {
            continue;
        }
        let _ = write!(out, "{}\t{}\t{}\t", e.0, e.1, e.2);
        for &f in s.list[id].iter().take_while(|&&f| f != 0) {
            let _ = write!(out, "{f:x} ");
        }
        let _ = writeln!(out);
    }
    drop(out);
    drop(g);
    suspend(prev);
}
