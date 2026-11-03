#!/usr/bin/env python3
# apply-patch.py SRC: adds the census hooks to a copy of tsrs (crates/tsrs_core, crates/tsrs_cli).
import sys, shutil, os

src = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))


def edit(path, pairs):
    p = os.path.join(src, path)
    t = open(p).read()
    for old, new in pairs:
        if t.count(old) != 1:
            sys.exit(f"{path}: {t.count(old)} matches for {old[:60]!r}")
        t = t.replace(old, new)
    open(p, 'w').write(t)


shutil.copy(os.path.join(here, 'census.rs'), os.path.join(src, 'crates/tsrs_core/src/census.rs'))
edit('crates/tsrs_core/src/lib.rs', [('pub mod memsplit;\n', 'pub mod memsplit;\npub mod census;\n')])

A = 'crates/tsrs_core/src/arena.rs'
edit(A, [
    # census helpers on Arena
    ('''    pub(crate) fn is_region(&self) -> bool {
        self.region.is_some()
    }
''', '''    pub(crate) fn is_region(&self) -> bool {
        self.region.is_some()
    }

    /// Census: the finger and chunk start before an allocation.
    #[inline]
    pub(crate) fn census_mark(&self) -> (*mut u8, *mut u8) {
        (self.ptr.get(), self.start.get())
    }

    /// Census: bytes the allocation since `mark` took (alignment padding included), or `size` across a new chunk.
    #[inline]
    pub(crate) fn census_taken(&self, mark: (*mut u8, *mut u8), size: usize) -> usize {
        if self.start.get() != mark.1 {
            return size;
        }
        let (a, b) = (mark.0.addr(), self.ptr.get().addr());
        if self.up { b - a } else { a - b }
    }

    /// Census: 0 thread arena, 1 registered region, 2 scratch region.
    #[inline]
    pub(crate) fn census_store(&self) -> u8 {
        if self.region.is_none() {
            0
        } else if self.registered {
            1
        } else {
            2
        }
    }

    /// Census: blocks and bytes on this arena's free lists.
    pub(crate) fn free_list_totals(&self) -> (usize, usize) {
        let (mut n, mut b) = (0, 0);
        for class in 1..CLASSES {
            let mut p = self.free[class].get();
            while !p.is_null() {
                n += 1;
                b += class * 8;
                // SAFETY: free blocks hold the next pointer in their first word.
                p = unsafe { *p.cast_const().cast::<*mut u8>() };
            }
        }
        (n, b)
    }
'''),
    # alloc_with
    ('''        let p = self.alloc_layout(layout).cast::<T>();
        // SAFETY: fresh, aligned, exclusively owned memory for one `T`.''',
     '''        let mark = self.census_mark();
        let p = self.alloc_layout(layout).cast::<T>();
        if crate::census::enabled() {
            crate::census::record::<T>(
                false,
                p.as_ptr().addr(),
                layout.size(),
                self.census_taken(mark, layout.size()),
                self.census_store(),
            );
        }
        // SAFETY: fresh, aligned, exclusively owned memory for one `T`.'''),
    # alloc_slice_copy
    ('''        let p = self.alloc_layout(Layout::for_value(src)).cast::<T>();
        // SAFETY: fresh memory for `src.len()` items; `T: Copy`.''',
     '''        let mark = self.census_mark();
        let p = self.alloc_layout(Layout::for_value(src)).cast::<T>();
        if crate::census::enabled() {
            let size = std::mem::size_of_val(src);
            crate::census::record::<T>(
                true,
                p.as_ptr().addr(),
                size,
                self.census_taken(mark, size),
                self.census_store(),
            );
        }
        // SAFETY: fresh memory for `src.len()` items; `T: Copy`.'''),
    # alloc_vec
    ('''        let p = self.alloc_layout(Layout::array::<T>(len).expect("arena slice layout")).cast::<T>();''',
     '''        let mark = self.census_mark();
        let p = self.alloc_layout(Layout::array::<T>(len).expect("arena slice layout")).cast::<T>();
        if crate::census::enabled() {
            let size = len * std::mem::size_of::<T>();
            crate::census::record::<T>(
                true,
                p.as_ptr().addr(),
                size,
                self.census_taken(mark, size),
                self.census_store(),
            );
        }'''),
    # alloc_str: recorded as `str`
    ('''        let bytes = self.alloc_slice_copy(s.as_bytes());
        // SAFETY: copied from a `str`.''',
     '''        let mark = self.census_mark();
        let p = self.alloc_layout(Layout::for_value(s.as_bytes()));
        if crate::census::enabled() {
            crate::census::record_raw(
                "str",
                1,
                1,
                true,
                p.as_ptr().addr(),
                s.len(),
                self.census_taken(mark, s.len()),
                self.census_store(),
            );
        }
        // SAFETY: fresh memory for `s.len()` bytes.
        let bytes = unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), p.as_ptr(), s.len());
            std::slice::from_raw_parts_mut(p.as_ptr(), s.len())
        };
        // SAFETY: copied from a `str`.'''),
    # free_block: kill
    ('''    let p = std::ptr::with_exposed_provenance_mut::<u8>(addr);
    arena.bump_epoch();''',
     '''    let p = std::ptr::with_exposed_provenance_mut::<u8>(addr);
    if crate::census::enabled() {
        crate::census::kill(addr, size, 1);
    }
    arena.bump_epoch();'''),
    # rewind: kill
    ('''    if len == 0 {
        return;
    }
    // Values discarded by the rewind are not dropped''',
     '''    if len == 0 {
        return;
    }
    if crate::census::enabled() {
        crate::census::kill(now.addr(), len, 2);
    }
    // Values discarded by the rewind are not dropped'''),
    # region freed: kill its chunks
    ('''        let arena = &*self.arena;
        let chunks = arena.chunks();
''', '''        let arena = &*self.arena;
        let chunks = arena.chunks();
        if crate::census::enabled() {
            for &(start, size) in &chunks {
                crate::census::kill(start, size, 3);
            }
        }
'''),
])

P = 'crates/tsrs_core/src/ptr.rs'
edit(P, [
    ('''                let p = block.cast::<T>();
                // SAFETY: a dead block of exactly `p_layout::<T>().size()` bytes, 8-aligned (`free_class`).
                unsafe { p.as_ptr().write(value) };''',
     '''                let p = block.cast::<T>();
                if crate::census::enabled() {
                    let size = p_layout::<T>().size();
                    crate::census::record::<T>(false, p.as_ptr().addr(), size, size, a.census_store());
                }
                // SAFETY: a dead block of exactly `p_layout::<T>().size()` bytes, 8-aligned (`free_class`).
                unsafe { p.as_ptr().write(value) };'''),
    ('''        if let Some(block) = with_arena(|a| a.pop_free(class)) {
            let p = block.cast::<T>();''',
     '''        if let Some((block, a)) = with_arena(|a| a.pop_free(class).map(|b| (b, a))) {
            let p = block.cast::<T>();
            if crate::census::enabled() {
                let size = std::mem::size_of_val(items);
                crate::census::record::<T>(true, p.as_ptr().addr(), size, size, a.census_store());
            }'''),
    ('''        let layout = std::alloc::Layout::from_size_align(4 + s.len(), 4).unwrap();
        let p = with_arena(|a| a.alloc_layout(layout));''',
     '''        let layout = std::alloc::Layout::from_size_align(4 + s.len(), 4).unwrap();
        let p = with_arena(|a| {
            let mark = a.census_mark();
            let p = a.alloc_layout(layout);
            if crate::census::enabled() {
                crate::census::record_raw("PackedStr long text (u32 len + bytes)", 1, 4, true, p.as_ptr().addr(), layout.size(), a.census_taken(mark, layout.size()), a.census_store());
            }
            p
        });'''),
    ('''        std::alloc::Layout::from_size_align(items.len().max(1), 4).expect("arena slice layout");
    let p = with_arena(|a| a.alloc_layout(layout));''',
     '''        std::alloc::Layout::from_size_align(items.len().max(1), 4).expect("arena slice layout");
    let p = with_arena(|a| {
        let mark = a.census_mark();
        let p = a.alloc_layout(layout);
        if crate::census::enabled() {
            crate::census::record_raw("[u8] (alloc_slice_aligned4)", 1, 4, true, p.as_ptr().addr(), layout.size(), a.census_taken(mark, layout.size()), a.census_store());
        }
        p
    });'''),
    ('''        std::alloc::Layout::from_size_align(capacity, 1).expect("arena string capacity overflow");
    with_arena(|a| a.alloc_layout(layout))''',
     '''        std::alloc::Layout::from_size_align(capacity, 1).expect("arena string capacity overflow");
    with_arena(|a| {
        let mark = a.census_mark();
        let p = a.alloc_layout(layout);
        if crate::census::enabled() {
            crate::census::record_raw("ArenaStringBuilder buffer (str)", 1, 1, true, p.as_ptr().addr(), layout.size(), a.census_taken(mark, layout.size()), a.census_store());
        }
        p
    })'''),
])

M = 'crates/tsrs_core/src/memsplit.rs'
edit(M, [
    ('''    let mut out = format!("tsrs mem split: {what}\\n");''',
     '''    if what == "parse end" {
        crate::census::mark_parse_end();
    }
    let mut out = format!("tsrs mem split: {what}\\n");'''),
    ('''    let _ = writeln!(
        out,
        "  thread arenas: {} arenas,''',
     '''    if what == "check end" {
        let mut fl = (0, 0);
        for a in ARENAS.lock().unwrap().iter() {
            let (n, b) = a.0.free_list_totals();
            fl.0 += n;
            fl.1 += b;
        }
        crate::census::dump_at_check_end(fl, arenas.used);
    }
    let _ = writeln!(
        out,
        "  thread arenas: {} arenas,'''),
])

C = 'crates/tsrs_cli/src/main.rs'
edit(C, [
    ('''#[global_allocator]
static GLOBAL: mimalloc_safe::MiMalloc = mimalloc_safe::MiMalloc;
''', '''#[global_allocator]
static GLOBAL: heapcensus::Counting = heapcensus::Counting;

mod heapcensus;
'''),
    ('''    let args: Vec<String> = std::env::args().skip(1).collect();
''', '''    let args: Vec<String> = std::env::args().skip(1).collect();
    heapcensus::init();
'''),
])
shutil.copy(os.path.join(here, 'heapcensus.rs'), os.path.join(src, 'crates/tsrs_cli/src/heapcensus.rs'))
print("patched")
