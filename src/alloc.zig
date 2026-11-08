//! Rig's allocator for release builds: a heap per thread, with no lock,
//! as mimalloc keeps one. A heap hands out small blocks (up to
//! `max_small` bytes) from free lists, one per size class, which it fills
//! from pages of its own segments; a block freed on the thread whose heap
//! made it goes back on that heap's list with no atomic operation, and
//! one freed on another thread (a task's value that moved to another
//! core) goes on the owning heap's remote list, with one
//! compare-and-swap, for the owner to take back when its own list runs
//! out. Large blocks come from the system, and a heap keeps those freed
//! for the next request any of them fits, the smallest that does, and
//! keeps the rest of it apart (`takeKept`), so a list that grows, a
//! buffer used again, and tables built and dropped again and again do
//! not map and unmap memory each time; a large block that grows moves
//! into a kept block that fits, whose pages are resident, before it
//! takes new ones (`remap`). It keeps them while what it holds
//! in large blocks, handed out and kept, is no more than its settled
//! peak, the most it has had handed out just after a free, and
//! `keep_large` more (`keepBound`). So a growth's moment, the old block
//! and the new one handed out together, does not raise what it may keep,
//! and a table that grows does not leave the block it grew from
//! resident. A heap that does not fault in ahead (`faultsAhead`), as a
//! server's worker's, keeps only `keep_resident` bytes of them resident
//! and gives the pages of the rest back to the system, keeping their
//! addresses for its next (`cold`). Segments are never returned to the
//! system: memory freed stays for reuse. On Linux,
//! a heap that does much of the program's work, one that has taken from
//! the system most of what every heap has or more than one segment's
//! worth, faults in at once the memory it is about to fill (`prefault`)
//! and asks for huge pages for each new segment, and a new large block
//! of 16 MiB or more asks for huge pages (`huge_large`), each while the
//! system has free 2 MiB blocks for it and a few more (`hugeFreeFor`),
//! counted on the node of the thread that asks (`freeHugeBlocks`). What
//! a request does follows the system's mode for transparent huge pages,
//! read once from /sys (`adviceFor`): under `madvise` it is as above,
//! with no test where `defrag` is `defer` or `never`, as no fault
//! compacts there; under `always`, where every range gets huge pages
//! unasked and asking would make its faults compact, nothing asks for
//! huge pages, and what should keep small pages (a segment of a heap
//! that does not fault in ahead, a large block under 16 MiB, a Table's
//! first 2 MiB) asks for them; under `never` nothing asks, and
//! /proc/buddyinfo is never read.
//! Reserved Tables (`table.zig`) take ranges of an address space of
//! their own, which none of this touches (`reserveTable`). On the Mac,
//! `os.exit` may unmap the segments' region and the Tables' regions on
//! several workers before the process ends (`exitRanges`,
//! `sched.tearDown`).
//!
//! A thread that ends gives its heap back (`threadExit`), and the next
//! thread to start takes it, with what it holds.
//!
//! In a program that reads `os.memory` (`counts`), each heap counts the
//! bytes and blocks its thread takes and gives back, and adds them to the
//! program's totals in batches. Debug builds keep the leak checker's path
//! (`runtime.zig`, `defaultAllocator`).

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const split = @import("split.zig");
const sched = @import("sched.zig");

// Unit 0 of a split build defines every cell of this file
// (`split.cell`).
comptime {
    if (split.on and split.main) _ = .{
        taken_all,
        kept_reading,
        buddyinfo_for_test,
        buddyinfo_reads,
        clock_for_test,
        region_next,
        region_end,
        region_lock,
        tables_lock,
        table_regions,
        table_region_count,
        table_next,
        table_end,
        tables_unmapped,
        table_free,
        table_free_count,
        tables_asked_huge,
        thp_mode,
        node_for_test,
        table_holes,
        table_hole_count,
        table_remap_fails_for_test,
        table_live,
        total_live,
        total_peak,
        total_allocs,
        owner_lost,
        spare_heaps,
        spare_lock,
        mapped_lock,
        mapped_spans,
        mapped_count,
        exe_file,
    };
}

/// Whether the heaps count what they hand out: only in a program that
/// names `os.memory`, whose root declares `__rig_memory` (and in this
/// file's tests). Any other program's allocator is the same code without
/// the counting, so the counts cost it nothing.
pub const counts = builtin.is_test or (@hasDecl(root, "__rig_memory") and root.__rig_memory);

/// A segment: `segment_size` bytes, aligned to their size, so a block's
/// segment is its address rounded down. Its first page holds its header.
const segment_size: usize = 4 << 20;
/// Small blocks are carved from pages of this size, one class per page.
const page_size: usize = 64 << 10;
const pages_per_segment = segment_size / page_size;

/// How much of a segment a heap faults in at once, as it reaches it.
const prefault_size: usize = 1 << 20;
const pages_per_prefault = prefault_size / page_size;

/// Linux's `MADV_POPULATE_WRITE` (5.14 and later), which Zig's
/// `std.os.linux.MADV` does not name.
const madv_populate_write: u32 = 23;

/// What every heap has taken from the system together (`Heap.taken`).
var taken_all_var: std.atomic.Value(usize) = .init(0);
const taken_all = split.cell(&taken_all_var, "alloc.taken_all");

/// A heap faults in ahead while it has taken from the system at least
/// this many times what every other heap has together (`leads`).
const prefault_lead: usize = 4;

/// A heap that has taken this much from the system, two segments' worth,
/// faults in ahead whatever the others have taken (`faultsAhead`).
const prefault_big: usize = 2 * segment_size;

/// Of a large block's pages, how many bytes to fault in at once: a List
/// that doubles into a block fills, on average, its old elements and
/// half the room after them, so a new block faults in its first three
/// quarters, and a block that grows by `mremap` half the bytes it gains;
/// at most `prefault_large` bytes, so a huge block's untouched room still
/// faults as it is reached. Rounded down to whole pages.
fn likelyFilled(len: usize) usize {
    return @min(len, prefault_large) & ~(std.heap.pageSize() - 1);
}

/// The most of a large block faulted in at once.
const prefault_large: usize = 8 << 20;

/// Faults in the `len` bytes at `p` in one call, on Linux, while `h`
/// does much of the program's work (`faultsAhead`), as writing them
/// would, page by page, with one trap each: a stretch of a segment the heap is about to carve
/// blocks from, or the part of a large block a List growing into it is
/// likely to fill (`likelyFilled`). It saves a trap per page, and the
/// cycles a program stalls after each, and commits little a program
/// never writes. Elsewhere, or where the system cannot (an older kernel),
/// the pages fault as they are touched.
fn prefault(h: *const Heap, p: usize, len: usize) void {
    if (len == 0) return;
    if (!faultsAhead(h)) return;
    if (builtin.os.tag == .linux) {
        const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p);
        std.posix.madvise(at, len, madv_populate_write) catch {};
    }
}

/// Whether `h` faults in ahead: it leads the heaps (`leads`), or it has
/// taken from the system `prefault_big` bytes or more, more than its
/// first segment, as the heap of each of several parallel checkers does
/// as it fills its segments densely. The workers of a server, or of a
/// program of many small tasks, each keep to one segment, so they fault
/// lazily: each would fault in its first stretch as it starts, and a
/// server's buffers are written sparsely, so faulting in ahead slowed
/// both.
fn faultsAhead(h: *const Heap) bool {
    return h.taken >= prefault_big or leads(h);
}

/// Whether `h` does the program's work: it has taken from the system at
/// least `prefault_lead` times what every other heap has together. A
/// program on one thread always leads, and so does one whose other
/// threads take little, as a blocking-pool thread that reads a file
/// does. In a program of several busy threads, as a server's workers or
/// parallel checkers, none leads. A new heap's first segment counts
/// before it asks, so it leads only a program whose other heaps have
/// taken a quarter of it or less.
fn leads(h: *const Heap) bool {
    const others = taken_all.load(.monotonic) -| h.taken;
    return others * prefault_lead <= h.taken;
}

/// The largest small block.
pub const max_small: usize = 32 << 10;

/// Size classes: 8 to 64 bytes in steps of 8, then four per doubling up to
/// `max_small`, so a block wastes at most a fifth of itself.
const class_count = 8 + 4 * 9;

fn classSize(c: usize) usize {
    if (c < 8) return (c + 1) * 8;
    const k = c - 8;
    const base: usize = @as(usize, 64) << @intCast(k / 4);
    return base + (base / 4) * (k % 4 + 1);
}

/// The class of a block of `len` bytes aligned to `alignment`, or null
/// for a large one.
inline fn classOf(len: usize, alignment: std.mem.Alignment) ?usize {
    const a = alignment.toByteUnits();
    if (a <= 8) {
        if (len <= small_table_max) return small_table[(len + 7) >> 3];
        if (len > max_small) return null;
        return classAbove(len);
    }
    return classAligned(len, a);
}

/// The class of `n` bytes, 64 < n <= `max_small`: four per doubling.
inline fn classAbove(n: usize) usize {
    const log: usize = std.math.log2_int(usize, n - 1); // base < n <= 2 * base
    const shift: u6 = @intCast(log - 2); // a quarter of base
    const step = (n - 1 - (@as(usize, 1) << @intCast(log))) >> shift; // 0..3
    return 8 + (log - 6) * 4 + step;
}

fn classAligned(len: usize, a: usize) ?usize {
    @branchHint(.unlikely);
    if (a > page_size) return null;
    const n = std.mem.alignForward(usize, @max(len, 8), a);
    if (n > max_small) return null;
    var k = if (n <= 64) (n - 1) / 8 else classAbove(n);
    // A class whose size is not a multiple of the alignment is passed by.
    while (k < class_count and classSize(k) % a != 0) k += 1;
    return if (k < class_count) k else null;
}

/// The classes of sizes up to `small_table_max`, by size in eighths. A
/// `Class`, so an entry indexes `Heap.free` with no bounds check.
const small_table_max = 1024;
const small_table: [small_table_max / 8 + 1]Class = blk: {
    var t: [small_table_max / 8 + 1]Class = undefined;
    for (&t, 0..) |*e, i| {
        const n = @max(i * 8, 8);
        e.* = if (n <= 64) (n - 1) / 8 else classAbove(n);
    }
    break :blk t;
};

/// A class, as the fast paths carry it: its type bounds it below
/// `free_slots`.
const Class = u6;
const free_slots = 1 << @bitSizeOf(Class);

comptime {
    std.debug.assert(classSize(class_count - 1) == max_small);
    std.debug.assert(class_count <= free_slots);
}

const Block = struct { next: ?*Block };

/// A segment's header, at its start.
const Segment = struct {
    /// The heap that made the segment, which owns its blocks.
    heap: *Heap,
    /// Pages handed out so far; the first is the header's.
    used: usize,
};

/// What a thread allocates from.
pub const Heap = struct {
    /// A free list per class: `free_slots` of them, so a `Class` indexes
    /// it with no bounds check; those past `class_count` stay empty.
    free: [free_slots]?*Block = @splat(null),
    /// Blocks other threads freed, which this heap takes back when its
    /// own list of their class runs out.
    remote: [class_count]std.atomic.Value(?*Block) = @splat(.init(null)),
    /// The page each class carves its next blocks from, and where.
    carve: [class_count]usize = @splat(0),
    carve_end: [class_count]usize = @splat(0),
    /// The segment pages come from.
    segment: ?*Segment = null,
    /// Large blocks freed and kept for the next, their pages resident.
    kept: Kept = .{},
    /// Large blocks freed and kept whose pages past the first were given
    /// back to the system (`decommit`): a heap that does not fault in
    /// ahead keeps only `keep_resident` bytes resident.
    cold: Kept = .{},
    /// The bytes of the large blocks this heap has handed out and not
    /// had back, and the most they have been just after a free, its
    /// settled peak (`keepBound`).
    large_live: usize = 0,
    large_peak: usize = 0,
    /// What this thread counted and has not yet added to the program's
    /// totals (`count`); nothing in a program that does not count.
    pending: Pending = .{},
    /// The next heap given back by a thread that ended (`threadExit`).
    next_free: ?*Heap = null,
    /// In a safe build, the thread that owns it (`threadToken`).
    owner: usize = 0,
    /// The bytes this heap has taken from the system: its segments, and
    /// the large blocks it mapped and the growth it moved them by, never
    /// less for those given back (`leads`).
    taken: usize = 0,

    /// `n` more bytes taken from the system.
    fn took(h: *Heap, n: usize) void {
        h.taken += n;
        _ = taken_all.fetchAdd(n, .monotonic);
    }

    fn alloc(h: *Heap, c: usize) ?[*]u8 {
        mustOwn(h);
        if (h.free[c]) |b| {
            h.free[c] = b.next;
            return @ptrCast(b);
        }
        if (h.remote[c].load(.monotonic) != null) {
            if (h.remote[c].swap(null, .acquire)) |list| {
                h.free[c] = list.next;
                return @ptrCast(list);
            }
        }
        const size = classSize(c);
        if (h.carve[c] + size > h.carve_end[c]) {
            const page = h.newPage() orelse return null;
            h.carve[c] = page;
            h.carve_end[c] = page + page_size - page_size % size;
        }
        const p = h.carve[c];
        h.carve[c] += size;
        return @ptrFromInt(p);
    }

    fn newPage(h: *Heap) ?usize {
        if (h.segment) |s| if (s.used < pages_per_segment) {
            const p = @intFromPtr(s) + s.used * page_size;
            if (s.used % pages_per_prefault == 0) prefault(h, p, prefault_size);
            s.used += 1;
            return p;
        };
        const s = mapSegment() orelse return null;
        h.took(segment_size);
        // A heap that does much of the work fills its segments densely,
        // so it asks for huge pages for them; a heap that keeps to one
        // segment, as a server's worker's or a blocking-pool thread's,
        // keeps small pages, as a huge page would commit 2 MiB of it.
        if (builtin.os.tag == .linux) ask(@intFromPtr(s), segment_size, if (faultsAhead(h)) .huge else .small);
        // The header's page, and the first stretch the heap carves from.
        prefault(h, @intFromPtr(s), prefault_size);
        s.* = .{ .heap = h, .used = 2 };
        h.segment = s;
        return @intFromPtr(s) + page_size;
    }

    /// A block of `bytes` taken (`allocs` 1) or given back (negative
    /// `bytes`, `allocs` 0): counted on this heap, and added to the
    /// program's totals once the heap is `flush_bytes` or `flush_allocs`
    /// from them.
    inline fn count(h: *Heap, bytes: isize, allocs: u32) void {
        h.pending.bytes += bytes;
        h.pending.allocs += allocs;
        if (h.pending.bytes >= flush_bytes or h.pending.bytes <= -flush_bytes or h.pending.allocs >= flush_allocs) h.flush();
    }

    /// Add what this heap counted to the program's totals, and raise the
    /// peak to what the program now holds.
    fn flush(h: *Heap) void {
        @branchHint(.cold);
        const now = total_live.fetchAdd(h.pending.bytes, .monotonic) + h.pending.bytes;
        _ = total_allocs.fetchAdd(h.pending.allocs, .monotonic);
        h.pending = .{};
        _ = total_peak.fetchMax(now, .monotonic);
    }

    fn freeSmall(h: *Heap, p: [*]u8, c: usize) void {
        const seg = segmentOf(p);
        const b = blockOf(p);
        if (seg.heap == h) {
            mustOwn(h);
            b.next = h.free[c];
            h.free[c] = b;
            return;
        }
        // Another thread's block: onto its heap's remote list.
        const owner = seg.heap;
        var top = owner.remote[c].load(.monotonic);
        while (true) {
            b.next = top;
            top = owner.remote[c].cmpxchgWeak(top, b, .release, .monotonic) orelse return;
        }
    }
};

// -----------------------------------------------------------------------------
// Large blocks
// -----------------------------------------------------------------------------

/// A freed large block, kept: its header at its start.
const LargeFree = struct { next: ?*LargeFree, len: usize };

const large_buckets = 4 * 40;
const large_words = (large_buckets + 63) / 64;

/// Freed large blocks kept, by bucket (four per doubling of pages, each
/// block at least its bucket's size); which buckets hold any, a bit
/// each; and how many bytes they hold.
const Kept = struct {
    large: [large_buckets]?*LargeFree = @splat(null),
    held: [large_words]u64 = @splat(0),
    bytes: usize = 0,
};

/// The most bytes of freed large blocks a heap that does not fault in
/// ahead (`faultsAhead`) keeps resident; the pages of those it frees past
/// them go back to the system (`decommit`), and the blocks stay kept, by
/// address, for its next (`Heap.cold`). The workers of a server each
/// take blocks that other workers freed and free blocks others made, so
/// what each keeps follows a random walk that grows with time. Kept
/// resident up to `keepBound`, a 22-worker server with 64 KiB values held
/// 60 MB, where with this bound it holds 39 MB at the same speed, and
/// xmalloc-test's freeing threads, which never allocate, kept 16 MiB each
/// (docs/history/records/2026-10/mem-both/).
/// A heap that does the program's work, as each of Trig's checkers', keeps
/// every block resident, within `keepBound`.
const keep_resident: usize = 1 << 20;

/// Give the pages of the kept block of `len` bytes at `p` back to the
/// system, all but its first, which holds its header: on Linux with
/// `MADV_DONTNEED`, which lowers what the program holds at once, as
/// `MADV_FREE` does only when the system runs short (xmalloc-test held
/// 289 MB with `MADV_FREE` and 93 MB with this, on pup), and on macOS with
/// `MADV_FREE_REUSABLE`. Its addresses stay the heap's, and its pages
/// fault in again, zeroed, as the block is used.
fn decommit(p: usize, len: usize) void {
    const pg = std.heap.pageSize();
    if (len <= pg) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p + pg);
    const advice: u32 = if (builtin.os.tag == .linux) std.os.linux.MADV.DONTNEED else if (builtin.os.tag.isDarwin()) madv_free_reusable else return;
    std.posix.madvise(at, len - pg, advice) catch {};
}

/// The `len` bytes at `p`, taken from the heap's cold blocks, used
/// again: on macOS the pages `decommit` gave back are claimed
/// (`MADV_FREE_REUSE`), as the system's own allocator does, so they count
/// as the program's again; elsewhere nothing is needed.
fn recommit(p: usize, len: usize) void {
    if (!builtin.os.tag.isDarwin()) return;
    const pg = std.heap.pageSize();
    if (len <= pg) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p + pg);
    std.posix.madvise(at, len - pg, madv_free_reuse) catch {};
}

/// macOS's `MADV_FREE_REUSABLE` and `MADV_FREE_REUSE`.
const madv_free_reusable: u32 = 7;
const madv_free_reuse: u32 = 8;

/// The bytes a large block takes: its length rounded up to its bucket's
/// size, so a kept block of that bucket, at least its size, fits it.
fn largeSize(len: usize) usize {
    const pages = std.mem.alignForward(usize, len, std.heap.pageSize());
    if (pages <= 4 * std.heap.pageSize()) return pages;
    const log: usize = std.math.log2_int(usize, pages - 1);
    const base: usize = @as(usize, 1) << @intCast(log);
    const quarter = base / 4;
    return base + quarter * ((pages - base + quarter - 1) / quarter);
}

/// The bucket of `size` bytes: the largest whose size is `size` or less.
fn largeBucket(size: usize) usize {
    const log: usize = std.math.log2_int(usize, size);
    const base: usize = @as(usize, 1) << @intCast(log);
    const quarter = @max(base / 4, 1);
    const k = log * 4 + (size - base) / quarter;
    return @min(k, large_buckets - 1);
}

/// The fewest bytes of freed large blocks a heap keeps, whatever it has
/// held before (`keepBound`).
const keep_large: usize = 16 << 20;

/// The smallest block a large request takes: a freed piece smaller than
/// this is given back to the system.
fn minLarge() usize {
    return largeSize(max_small + 1);
}

/// A large block at least this long that no kept block fits grows by
/// moving its pages (`mremap`, Linux), not by copying them into new
/// ones, which the system would fault in afresh (`remap`).
const move_large: usize = 64 << 10;

/// The most bytes of freed large blocks a heap keeps: as many as leave
/// what it holds in large blocks, handed out and kept, within its
/// settled peak and `keep_large` more. A growth maps the new block, mostly
/// untouched, before it frees the old one, whose pages are resident;
/// the peak, counted only after a free, leaves that moment out, so the
/// old block is kept only within `keep_large`. A table built and dropped
/// counts its whole size, since its last growth's free leaves it handed
/// out: a program that builds and drops its tables again and again takes
/// their pages from its own. A free or a reuse leaves what the heap holds
/// as it was, so only new pages can pass the bound (`trimKept`); while
/// they take it past its settled peak, it keeps no more than
/// `keep_large`.
fn keepBound(h: *const Heap) usize {
    return (h.large_peak -| h.large_live) + keep_large;
}

fn allocLarge(h: *Heap, len: usize) ?[*]u8 {
    mustOwn(h);
    const size = largeSize(len);
    if (takeKept(&h.kept, size)) |p| {
        lent(h, size);
        return p;
    }
    if (takeKept(&h.cold, size)) |p| {
        recommit(@intFromPtr(p), size);
        lent(h, size);
        return p;
    }
    const got = mapLarge(size) orelse return null;
    if (size >= huge_large) ask(got, size, .huge) else if (size >= huge_page) ask(got, size, .small);
    h.took(size);
    lent(h, size);
    trimKept(h);
    prefault(h, got, likelyFilled(size - size / 4));
    return @ptrFromInt(got);
}

/// A new large block of at least this many bytes is mapped, on Linux,
/// aligned to `huge_page` and advised for transparent huge pages
/// (`ask`), and so is a block grown to it by `mremap`: its pages
/// fault in 2 MiB at a time, a trap and a TLB entry each. Smaller blocks,
/// and blocks taken from those kept, stay as they are: huge pages for
/// every new block of 2 MiB or more raise Trig's peak memory, and from
/// 16 MiB they do not (docs/history/records/2026-10/alloc-thp16/). Where
/// every range gets huge pages unasked (`enabled=always`), a new block
/// of `huge_page` or more and less than this asks for small pages.
const huge_large: usize = 16 << 20;

/// A transparent huge page on Linux.
const huge_page: usize = 2 << 20;

/// `size` new bytes from the system: on Linux, from `huge_large`,
/// aligned to `huge_page` (as the system often maps them already).
fn mapLarge(size: usize) ?usize {
    const got = mapPages(size) orelse return null;
    if (builtin.os.tag != .linux or size < huge_large or got % huge_page == 0) return got;
    unmapLarge(got, size);
    const raw = mapPages(size + huge_page) orelse return null;
    const p = std.mem.alignForward(usize, raw, huge_page);
    if (p > raw) unmapLarge(raw, p - raw);
    unmapLarge(p + size, raw + huge_page - p);
    return p;
}

fn mapPages(size: usize) ?usize {
    const got = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    return @intFromPtr(got.ptr);
}

/// Tell Linux what the `len` bytes at `p` want, huge pages or small ones,
/// as the system's mode asks (`adviceFor`). Under `madvise`, a range that
/// wants huge pages asks for them (`MADV_HUGEPAGE`) while the system has
/// free 2 MiB blocks for them and `huge_floor` more (`hugeFreeFor`); a
/// new segment and a new large block ask just before their pages fault,
/// as they are faulted in ahead (`prefault`), so the count is current
/// when they need the blocks. Under `always`, a range that wants small
/// pages says so (`MADV_NOHUGEPAGE`). A system that cannot leaves them
/// as they are.
fn ask(p: usize, len: usize, want: Want) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const advice: u32 = switch (adviceFor(thpMode(), want)) {
        .nothing => return,
        .huge => linux.MADV.HUGEPAGE,
        .huge_if_free => if (hugeFreeFor((len + huge_page - 1) / huge_page)) linux.MADV.HUGEPAGE else return,
        .small => linux.MADV.NOHUGEPAGE,
    };
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p);
    std.posix.madvise(at, len, advice) catch {};
}

/// What Rig wants of a range: huge pages for one that has asked for
/// nothing (`huge`); huge pages for one that may have asked for small
/// ones, which only asking for huge pages undoes (`huge_again`, a large
/// block grown by `mremap`, which keeps its range's advice); or small
/// pages (`small`).
const Want = enum { huge, huge_again, small };

/// What a range asks of Linux: nothing, huge pages, huge pages only
/// while free 2 MiB blocks are there for them (`hugeFreeFor`,
/// `hugeFree`), or small pages.
const Advice = enum { nothing, huge, huge_if_free, small };

/// How Linux gives transparent huge pages of 2 MiB, by
/// /sys/kernel/mm/transparent_hugepage/`enabled`,
/// `hugepages-2048kB/enabled`, and `defrag` (`thpModeOf`), read once
/// (`thpMode`).
const Thp = packed struct(u8) {
    /// `enabled` is `never`: no range gets huge pages.
    off: bool = false,
    /// `enabled` is `always`: a range that asks for nothing gets huge
    /// pages, a fault taking a free 2 MiB block if there is one and
    /// compacting for one only under `defrag` `always`.
    by_default: bool = false,
    /// `defrag` is `madvise`, `defer+madvise`, or `always`: a fault in a
    /// range that asked for huge pages and finds no free 2 MiB block
    /// compacts memory to make one, in the fault. Under `defer` and
    /// `never` no fault compacts, whatever its range asked.
    advice_stalls: bool = true,
    /// Set in every mode read, so a mode is never 0, `thp_mode`'s unread.
    read: bool = true,
    _: u4 = 0,
};

/// What a range that wants `want` asks under `mode`:
///
/// - `enabled=never`: nothing, and /proc/buddyinfo is never read.
/// - `enabled=madvise` (pup's): a range that
///   wants huge pages asks for them, while free blocks are there where a
///   fault that finds none would compact (`advice_stalls`), and with no
///   test where none does; one that wants small pages asks for nothing,
///   as it already has them.
/// - `enabled=always` (the kernel's own default):
///   a range that wants huge pages asks for nothing, as it gets them
///   unasked, and asking would only make its faults compact (`defrag`
///   `madvise` or `defer+madvise`) or compact harder (`always`); one that
///   wants small pages says so. A range that may have said so asks for
///   huge pages as under `madvise`, as asking is the only way to undo it.
/// - A mode that cannot be read is taken for `madvise`, with `defrag`
///   `madvise`, as the test is then what keeps a fault from compacting.
fn adviceFor(mode: Thp, want: Want) Advice {
    if (mode.off) return .nothing;
    return switch (want) {
        .huge => if (mode.by_default) .nothing else if (mode.advice_stalls) .huge_if_free else .huge,
        .huge_again => if (mode.advice_stalls) .huge_if_free else .huge,
        .small => if (mode.by_default) .small else .nothing,
    };
}

/// The mode of the files `enabled`, `hugepages-2048kB/enabled`, and
/// `defrag` say, each the word in brackets among those it lists
/// (`always [madvise] never`). The second, where Linux has it (6.8 and
/// later), is the mode of 2 MiB pages, unless it is `inherit`, the first's.
/// A file that names none is taken as `madvise`.
fn thpModeOf(enabled: []const u8, enabled_2m: []const u8, defrag: []const u8) Thp {
    const own = chosenWord(enabled_2m);
    const e = if (own.len == 0 or std.mem.eql(u8, own, "inherit")) chosenWord(enabled) else own;
    const d = chosenWord(defrag);
    return .{
        .off = std.mem.eql(u8, e, "never"),
        .by_default = std.mem.eql(u8, e, "always"),
        .advice_stalls = !(std.mem.eql(u8, d, "defer") or std.mem.eql(u8, d, "never")),
    };
}

/// The word in brackets in `text`, or "" if it has none.
fn chosenWord(text: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, text, '[') orelse return "";
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return "";
    return text[open + 1 .. close];
}

/// The system's mode for transparent huge pages, read on the first
/// request for huge or small pages (`readThpMode`), as it is a setting of
/// the host, changed by its administrator, not by the load. 0 unread.
var thp_mode_var: std.atomic.Value(u8) = .init(0);
const thp_mode = split.cell(&thp_mode_var, "alloc.thp_mode");

fn thpMode() Thp {
    const m = thp_mode.load(.monotonic);
    if (m != 0) return @bitCast(m);
    return readThpMode();
}

/// Read the mode from /sys. Threads that read it at once read the same.
noinline fn readThpMode() Thp {
    @branchHint(.cold);
    var enabled: [128]u8 = undefined;
    var enabled_2m: [128]u8 = undefined;
    var defrag: [128]u8 = undefined;
    const mode = thpModeOf(
        readSmallFile("/sys/kernel/mm/transparent_hugepage/enabled", &enabled),
        readSmallFile("/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled", &enabled_2m),
        readSmallFile("/sys/kernel/mm/transparent_hugepage/defrag", &defrag),
    );
    thp_mode.store(@bitCast(mode), .monotonic);
    return mode;
}

/// Under the mode of `enabled` and `defrag` from now (a test's).
fn useThpForTest(enabled: []const u8, defrag: []const u8) void {
    thp_mode.store(@bitCast(thpModeOf(enabled, "", defrag)), .monotonic);
}

/// What a file of /proc or /sys reads, as much as fits `buf`; "" if it
/// cannot be read. Such a file reads as empty to a reader that trusts
/// its size, so it is read to its end.
fn readSmallFile(path: [*:0]const u8, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return "";
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const r: isize = @bitCast(linux.read(fd, buf[len..].ptr, buf.len - len));
        if (r < 0) return "";
        if (r == 0) break;
        len += @intCast(r);
    }
    return buf[0..len];
}

/// The free blocks of 2 MiB or more that Linux must have, more than
/// this many, before a reserved Table asks it for huge pages for all of
/// its reservation (`hugeFree`), which it then grows into over the whole
/// run: about what one program takes for itself (Trig 76 on ts-pattern, 15 on zod3), so a
/// program that asks finds free blocks for its faults rather than
/// compacting in them. A quiet host idles above it (pup at about 90 to
/// 140), where asking does not stall; a spare of 128, within that idle
/// level, shut the test for most of Trig's runs there, as a run's own
/// huge pages drain the count, and this spare runs ts-pattern 5.8%
/// faster than it.
/// Below it, with memory fragmented and 35 to 65 free, Trig on
/// ts-pattern asking at a spare of 32 compacted in 17 of 20 runs and ran
/// more than 5% slower than with no huge pages in 8 (up to 70%), and at
/// 16 ran 34% slower by the median, where at 64 it asked for none
/// (docs/history/records/2026-10/perf-stage/thp-spare.md).
const huge_spare: usize = 64;

/// The free blocks of 2 MiB or more that a new segment or large block
/// leaves when it asks for huge pages (`hugeFreeFor`). It asks moments
/// before its pages fault, so it needs only its own blocks free, and
/// this many more for other programs that take them meanwhile. Where
/// the Tables' spare of 64 shut the gate (12 to 17 free blocks on pup),
/// segments asking at this floor ran Trig's zod3 2.6% faster and the
/// small projects 3.2 to 5.4%, level when memory was quiet, with no
/// compaction stall (docs/history/records/2026-10/perf-stage/
/// table-huge.md).
const huge_floor: usize = 8;

/// Whether Linux has more than `huge_spare` free blocks of 2 MiB or more
/// (`/proc/buddyinfo`), the test a Table's `reserve` in `table.zig` makes
/// before it asks for huge pages. Under the
/// default `defrag` setting, `madvise`, a fault in a range that asked for
/// huge pages finds a free 2 MiB block or compacts memory to make one, in
/// the fault; with none free the compaction mostly fails, a fault costs
/// 2 to 60 times a small page's, and Trig ran 34 to 41% slower than with
/// no huge pages (docs/history/records/2026-10/perf-stage/
/// thp-fragmented.md).
///
/// A reading taken in the last `reading_life` answers it (`keptReading`),
/// so the burst of Tables a program makes at once, 43 for each of Trig's
/// checkers, reads the file once. A kept reading may open the gate: a
/// Table takes no block as it is reserved, only as it is later written,
/// over the whole run, and `huge_spare` is there for what memory gives
/// up meanwhile; a reading a few milliseconds older adds nothing to that.
///
/// Where no fault compacts (`defrag` `defer` or `never`) it holds with no
/// reading, and where asking is not how a range gets huge pages
/// (`enabled` `always` or `never`) it does not hold (`adviceFor`).
pub fn hugeFree() bool {
    if (builtin.os.tag != .linux) return false;
    return switch (adviceFor(thpMode(), .huge)) {
        .huge => true,
        .huge_if_free => (keptReading() orelse readNow()) > huge_spare,
        .nothing, .small => false,
    };
}

/// Whether Linux has free blocks of 2 MiB or more for `need` huge pages
/// and `huge_floor` more: the test a new segment or large block makes
/// before it asks (`ask`). Its blocks are taken moments later, as
/// its pages fault, so only a reading taken now may say yes; a kept one
/// may say no, which costs at most huge pages missed, never a stall. A
/// yes takes its `need` from the reading kept.
fn hugeFreeFor(need: usize) bool {
    if (builtin.os.tag != .linux) return false;
    if (keptReading()) |blocks| if (blocks < need + huge_floor) return false;
    if (readNow() < need + huge_floor) return false;
    spendReading(need);
    return true;
}

/// How long a reading of /proc/buddyinfo answers the gates: a few
/// milliseconds, the span of a burst of Tables (Trig's checkers make 43
/// each in about one), short beside the seconds a Table is written over.
const reading_life_ns: u64 = 4 * std.time.ns_per_ms;

/// The reading kept: the low 40 bits of the monotonic clock in units of
/// 2^16 ns (about 65 microseconds) in the top 40 bits, which wrap every
/// 2^56 ns, two years, so an age is taken in 40 bits (`time_mask`); the
/// node whose blocks it counted, or `every_node`, in the next 8; its free
/// blocks, at most `count_max` (65,535, 128 GiB of them, far past every
/// test, which a reading taken now answers uncapped), in the low 16; or
/// 0, none. One word, so a thread never pairs one reading's time with
/// another's count.
var kept_reading_var: std.atomic.Value(u64) = .init(0);
const kept_reading = split.cell(&kept_reading_var, "alloc.kept_reading");
const count_bits = 16;
const node_bits = 8;
const time_shift = count_bits + node_bits;
const count_max: u64 = (1 << count_bits) - 1;
const node_mask: u64 = (1 << node_bits) - 1;
const time_mask: u64 = (1 << (64 - time_shift)) - 1;
/// The node of a reading that counted every node's blocks, as one of a
/// host with one node does: it answers a thread on any.
const every_node: u64 = node_mask;

/// The monotonic clock in units of 2^16 ns, through the vDSO: tens of
/// nanoseconds, where a reading costs microseconds. 0 if it fails.
fn clockUnits() u64 {
    if (comptime builtin.is_test) if (clock_for_test.*) |ns| return ns >> 16;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const ns = @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
    return ns >> 16;
}

/// The free blocks of the reading kept, if it was taken in the last
/// `reading_life_ns`, of every node or of the asking thread's.
fn keptReading() ?usize {
    const k = kept_reading.load(.monotonic);
    if (k == 0) return null;
    const now = clockUnits();
    if (now == 0 or (now -% (k >> time_shift)) & time_mask >= reading_life_ns >> 16) return null;
    const node = (k >> count_bits) & node_mask;
    if (node != every_node and node != (thisNode() orelse every_node)) return null;
    return @intCast(k & count_max);
}

/// Read /proc/buddyinfo, keep the reading, and give its free blocks.
fn readNow() usize {
    const r = freeHugeNow();
    const now = clockUnits();
    if (now != 0 and r.node <= every_node) kept_reading.store(now << time_shift | r.node << count_bits | @min(r.blocks, count_max), .monotonic);
    return r.blocks;
}

/// Take `need` blocks from the reading kept, as a range that asked for
/// them is about to fault them in.
fn spendReading(need: usize) void {
    var k = kept_reading.load(.monotonic);
    while (k != 0) {
        const left = (k & count_max) -| need;
        k = kept_reading.cmpxchgWeak(k, (k & ~count_max) | left, .monotonic, .monotonic) orelse return;
    }
}

/// A reading's free blocks, and the node they are of: `every_node` for
/// all, and past it for a node too high to keep a reading for.
const Reading = struct { blocks: usize, node: u64 };

/// The free blocks of 2 MiB or more Linux has now (`/proc/buddyinfo`)
/// on the asking thread's node, read once for each new segment, new
/// large block of `huge_large`, and burst of reserved Tables
/// (`keptReading`). A host of one node is not asked which node the
/// thread is on. A file that cannot be read counts none, so nothing
/// asks.
noinline fn freeHugeNow() Reading {
    @branchHint(.cold);
    if (builtin.os.tag != .linux) return .{ .blocks = 0, .node = every_node };
    // A line per zone of each node, about 100 bytes: a host of 10 nodes
    // fits. A reading cut short counts fewer blocks, never more: one that
    // fills the buffer may have lost the asking node's lines, which then
    // count none (`freeHugeBlocks`).
    var buf: [4096]u8 = undefined;
    const text = text: {
        if (comptime builtin.is_test) {
            buddyinfo_reads.* += 1;
            if (buddyinfo_for_test.*) |text| break :text text;
        }
        break :text readSmallFile("/proc/buddyinfo", &buf);
    };
    const node: ?usize = if (oneNode(text)) null else thisNode();
    const tag: u64 = if (node) |n| (if (n < every_node) n else every_node + 1) else every_node;
    return .{ .blocks = freeHugeBlocks(text, node, text.len < buf.len), .node = tag };
}

/// The NUMA node of the CPU the thread runs on (`getcpu`), or null if
/// Linux does not say.
fn thisNode() ?usize {
    if (comptime builtin.is_test) if (node_for_test.*) |n| return n;
    if (builtin.os.tag != .linux) return null;
    // Linux writes an `unsigned int` for each, where Zig's `getcpu`
    // names a `usize`.
    var cpu: u32 = 0;
    var node: u32 = 0;
    const rc: isize = @bitCast(std.os.linux.syscall2(.getcpu, @intFromPtr(&cpu), @intFromPtr(&node)));
    if (rc < 0) return null;
    return node;
}

/// What a test reads in place of /proc/buddyinfo, the readings it has
/// made, the clock it sees, in nanoseconds, and the node it runs on.
var buddyinfo_for_test_var: ?[]const u8 = null;
const buddyinfo_for_test = split.cell(&buddyinfo_for_test_var, "alloc.buddyinfo_for_test");
var buddyinfo_reads_var: usize = 0;
const buddyinfo_reads = split.cell(&buddyinfo_reads_var, "alloc.buddyinfo_reads");
var clock_for_test_var: ?u64 = null;
const clock_for_test = split.cell(&clock_for_test_var, "alloc.clock_for_test");
var node_for_test_var: ?usize = null;
const node_for_test = split.cell(&node_for_test_var, "alloc.node_for_test");

/// Read `text` in place of /proc/buddyinfo from now, with no reading
/// kept, under `madvise` for huge pages with `defrag` `madvise`, pup's
/// mode, where the reading is what each request asks; and with null,
/// read the files again, the system's own.
fn useBuddyinfoForTest(text: ?[]const u8) void {
    buddyinfo_for_test.* = text;
    kept_reading.store(0, .monotonic);
    node_for_test.* = null;
    if (text != null) useThpForTest("always [madvise] never", "always defer defer+madvise [madvise] never") else thp_mode.store(0, .monotonic);
}

/// The free blocks of 2 MiB in a reading of /proc/buddyinfo: each line
/// is `Node N, zone NAME` and a count of free blocks for each order from
/// 0 (4 KiB); a block of order 9 is 2 MiB and one of order 9 + k holds
/// 2^k of them. The `DMA` zone's are left out, as no user page is taken
/// from it. Only the lines of `node` count, as a fault takes its huge
/// page from the node of the thread that faults, and compacts there
/// before it looks at another; every node's count where `node` is null,
/// or has no lines in a `whole` reading, a node with no memory of its
/// own, whose faults take another's. A reading that may have been cut
/// short with no line of `node` counts none.
fn freeHugeBlocks(text: []const u8, node: ?usize, whole: bool) usize {
    var all: usize = 0;
    var mine: usize = 0;
    var seen = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const ours = node != null and nodeOf(line) == node;
        seen = seen or ours;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        // The four words before the counts.
        var order: isize = -4;
        while (words.next()) |w| : (order += 1) {
            if (order == -1 and std.mem.eql(u8, w, "DMA")) break;
            if (order < 9) continue;
            const c = std.fmt.parseUnsigned(usize, w, 10) catch break;
            const blocks = std.math.shlExact(usize, c, @intCast(order - 9)) catch std.math.maxInt(usize);
            all +|= blocks;
            if (ours) mine +|= blocks;
        }
    }
    return if (seen) mine else if (node == null or whole) all else 0;
}

/// The node a line of /proc/buddyinfo is of (`Node N, zone ...`).
fn nodeOf(line: []const u8) ?usize {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, words.next() orelse return null, "Node")) return null;
    return std.fmt.parseUnsigned(usize, std.mem.trimEnd(u8, words.next() orelse return null, ","), 10) catch null;
}

/// Whether every line of a reading of /proc/buddyinfo is of one node.
fn oneNode(text: []const u8) bool {
    var first: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const n = nodeOf(line) orelse continue;
        if (first == null) first = n else if (first != n) return false;
    }
    return true;
}

/// `size` more bytes of large blocks handed out. The settled peak is
/// raised by a free (`freeLarge`), not here, so a block handed out
/// before the one it replaces is freed does not count twice.
fn lent(h: *Heap, size: usize) void {
    h.large_live += size;
}

/// A kept block of `k` for `size` bytes, best fit by bucket: the first
/// of the lowest bucket from `size`'s that holds one at least `size`
/// long. What it holds past `size` is kept on its own, in `k`.
fn takeKept(k: *Kept, size: usize) ?[*]u8 {
    var j = nextHeld(k, largeBucket(size));
    while (j) |b| : (j = nextHeld(k, b + 1)) {
        const f = unkeep(k, b, size) orelse continue;
        const p = @intFromPtr(f);
        const len = f.len;
        if (len > size) keepPiece(k, p + size, len - size);
        return @ptrFromInt(p);
    }
    return null;
}

/// Take from bucket `j` of `k` its first kept block at least `len` long.
fn unkeep(k: *Kept, j: usize, len: usize) ?*LargeFree {
    var at = &k.large[j];
    while (at.*) |f| : (at = &f.next) {
        if (f.len < len) continue;
        at.* = f.next;
        if (k.large[j] == null) k.held[j / 64] &= ~(@as(u64, 1) << @intCast(j % 64));
        k.bytes -= f.len;
        return f;
    }
    return null;
}

/// The lowest bucket of `k` from `from` that holds a kept block, or null.
fn nextHeld(k: *const Kept, from: usize) ?usize {
    var w = from / 64;
    if (w >= large_words) return null;
    var bits = k.held[w] & (~@as(u64, 0) << @intCast(from % 64));
    while (true) {
        if (bits != 0) return w * 64 + @ctz(bits);
        w += 1;
        if (w >= large_words) return null;
        bits = k.held[w];
    }
}

/// The highest bucket of `k` that holds a kept block, or null.
fn lastHeld(k: *const Kept) ?usize {
    var w: usize = large_words;
    while (w > 0) {
        w -= 1;
        const bits = k.held[w];
        if (bits != 0) return w * 64 + 63 - @clz(bits);
    }
    return null;
}

/// Keep the `len` bytes at `p` in `k`, or give them back to the system
/// if no large request could take them.
fn keepPiece(k: *Kept, p: usize, len: usize) void {
    if (len < minLarge()) return unmapLarge(p, len);
    const f: *LargeFree = @ptrFromInt(p);
    const b = largeBucket(len);
    f.* = .{ .next = k.large[b], .len = len };
    k.large[b] = f;
    k.held[b / 64] |= @as(u64, 1) << @intCast(b % 64);
    k.bytes += len;
}

/// The bytes of freed large blocks `h` keeps, resident and cold.
fn heldLarge(h: *const Heap) usize {
    return h.kept.bytes + h.cold.bytes;
}

/// Give kept blocks back to the system until the heap keeps no more
/// than `keepBound`, after it has taken new pages for a block no kept
/// one fitted: its cold blocks first, whose pages are already given
/// back, then its resident ones; of each, the smallest block that alone
/// brings it within the bound, or else the largest, and again. So the
/// heap keeps its largest blocks, a program's tables built again, which
/// cost the most pages to fault in afresh.
fn trimKept(h: *Heap) void {
    trimFrom(h, &h.cold);
    trimFrom(h, &h.kept);
}

fn trimFrom(h: *Heap, k: *Kept) void {
    while (heldLarge(h) > keepBound(h)) {
        const over = heldLarge(h) - keepBound(h);
        var j = nextHeld(k, largeBucket(over));
        const f = while (j) |b| : (j = nextHeld(k, b + 1)) {
            if (unkeep(k, b, over)) |f| break f;
        } else unkeep(k, lastHeld(k) orelse return, 0).?;
        unmapLarge(@intFromPtr(f), f.len);
    }
}

fn unmapLarge(p: usize, len: usize) void {
    std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(p))[0..len]);
}

fn freeLarge(h: *Heap, p: [*]u8, len: usize) void {
    mustOwn(h);
    const size = largeSize(len);
    // A block another heap handed out, freed here, counts against this
    // heap's bound as a new one would. What stays handed out after the
    // free is the settled peak's measure.
    h.large_live -|= size;
    h.large_peak = @max(h.large_peak, h.large_live);
    if (heldLarge(h) + size > keepBound(h)) return unmapLarge(@intFromPtr(p), size);
    // A heap that does not do much of the work keeps `keep_resident`
    // bytes resident, and the rest by address only.
    if (faultsAhead(h) or h.kept.bytes + size <= keep_resident) return keepPiece(&h.kept, @intFromPtr(p), size);
    decommit(@intFromPtr(p), size);
    keepPiece(&h.cold, @intFromPtr(p), size);
}

// -----------------------------------------------------------------------------
// Segments and heaps
// -----------------------------------------------------------------------------

/// The address space segments are carved from: one reservation, made
/// as the first segment is wanted, which the system backs only as pages
/// are touched, so a heap's growth makes no system call.
const region_size: usize = 64 << 30;
var region_next_var: std.atomic.Value(usize) = .init(0);
const region_next = split.cell(&region_next_var, "alloc.region_next");
var region_end_var: usize = 0;
const region_end = split.cell(&region_end_var, "alloc.region_end");
var region_lock_var: SpinLock = .{};
const region_lock = split.cell(&region_lock_var, "alloc.region_lock");

/// A lock that spins, for the few loads and stores, or the rare system
/// call, it is held across: a region's or a Table's address space, and
/// the spare heaps.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    /// Counted as the scheduler's are, in a program built to be
    /// preempted (`sched.holdOff`): `reserveTable` and the rest may be
    /// inlined into the program's own code.
    fn lock(self: *SpinLock) void {
        if (sched.preempting) sched.holdOff();
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
        if (sched.preempting) sched.holdOn();
    }
};

fn mapSegment() ?*Segment {
    if (region_next.load(.acquire) == 0) reserveRegion();
    var at = region_next.load(.monotonic);
    while (at != 0 and at + segment_size <= region_end.*) {
        at = region_next.cmpxchgWeak(at, at + segment_size, .monotonic, .monotonic) orelse return @ptrFromInt(at);
    }
    return mapOwnSegment();
}

fn reserveRegion() void {
    @branchHint(.cold);
    region_lock.lock();
    defer region_lock.unlock();
    if (region_next.load(.monotonic) != 0) return;
    const raw = std.posix.mmap(null, region_size + segment_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
        // No room for it: each segment is mapped on its own.
        region_end.* = 0;
        region_next.store(1, .release);
        return;
    };
    const start = std.mem.alignForward(usize, @intFromPtr(raw.ptr), segment_size);
    region_end.* = start + region_size;
    region_next.store(start, .release);
}

fn mapOwnSegment() ?*Segment {
    // Map twice the size, then give back what lies outside one aligned
    // segment.
    const raw = std.posix.mmap(null, 2 * segment_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch return null;
    const start = @intFromPtr(raw.ptr);
    const aligned = std.mem.alignForward(usize, start, segment_size);
    if (aligned > start) std.posix.munmap(@alignCast(raw.ptr[0 .. aligned - start]));
    const tail = start + 2 * segment_size - (aligned + segment_size);
    if (tail > 0) std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(aligned + segment_size))[0..tail]);
    return @ptrFromInt(aligned);
}

// -----------------------------------------------------------------------------
// Tables' address space
// -----------------------------------------------------------------------------

/// The address space reserved Tables (`table.zig`) are handed on Linux
/// and the Mac: regions of `table_region_size`, each mapped once, with no
/// memory committed (`MAP_NORESERVE`), and on Linux advised for small
/// pages once, under `madvise` for huge pages (`adviceFor`). A Table
/// takes a range of whole 2 MiB blocks from one (`reserveTable`), which
/// makes no system call while memory has no free 2 MiB blocks to spare,
/// and on Linux one `madvise` while it does; a Table dropped gives its
/// pages back to the system, with `MADV_DONTNEED` on Linux and by
/// mapping its range again in place on the Mac (`MAP_FIXED`), which
/// leaves the range reading as zeros, and its range to the next Table
/// (`unreserveTable`). Under Linux's `always`, a region asks for nothing,
/// and each Table's first 2 MiB ask for small pages; a Table dropped is
/// mapped afresh, as on the Mac, which gives its pages back and leaves
/// the range asking for nothing again, as no advice does. A region is
/// never unmapped while the program runs, so its addresses are never
/// another mapping's but in a hole a dropped Table may leave
/// (`loseTableRange`), and `os.exit` may unmap the rest of it whole
/// (`exitRanges`). Trig's
/// checkers reserve 43 Tables each, 24 MiB to 4 GiB, 53 GiB in all, and
/// a mapping, its advice, and its unmapping for each cost about 8
/// microseconds of system calls. Only release builds take Tables from
/// here: a debug build maps each on its own, so a Table used after it is
/// dropped faults and the leak checker sees each. On the Mac the kernel
/// walks a mapping's whole range as the process ends, touched or not,
/// about 2.4 µs a GiB (0.6 ms for 256 GiB), so its regions are 32 GiB,
/// little more than a Table's largest.
const table_region_size: usize = if (builtin.os.tag.isDarwin()) 32 << 30 else 256 << 30;
/// The regions there may be, 8 TiB in all on Linux and 2 TiB on the Mac;
/// a Table that finds none with room, or is larger than a region, is
/// mapped on its own.
const table_regions_max = if (builtin.os.tag.isDarwin()) 64 else 32;
/// The free ranges kept between Tables. A range that would be one more
/// is given up: its pages are back with the system, and only its
/// addresses go unused.
const table_free_max = 128;

const Range = struct { start: usize, len: usize };

var tables_lock_var: SpinLock = .{};
const tables_lock = split.cell(&tables_lock_var, "alloc.tables_lock");
/// The regions, in the order they were mapped; the newest is handed out
/// from `table_next` to `table_end`.
var table_regions_var: [table_regions_max]Range = undefined;
const table_regions = split.cell(&table_regions_var, "alloc.table_regions");
var table_region_count_var: usize = 0;
const table_region_count = split.cell(&table_region_count_var, "alloc.table_region_count");
var table_next_var: usize = 0;
const table_next = split.cell(&table_next_var, "alloc.table_next");
var table_end_var: usize = 0;
const table_end = split.cell(&table_end_var, "alloc.table_end");
/// No region could be mapped (`ulimit -v`, strict overcommit): each
/// Table is mapped on its own from then on.
var tables_unmapped_var: bool = false;
const tables_unmapped = split.cell(&tables_unmapped_var, "alloc.tables_unmapped");
/// The ranges given back, by address, none touching another.
var table_free_var: [table_free_max]Range = undefined;
const table_free = split.cell(&table_free_var, "alloc.table_free");
var table_free_count_var: usize = 0;
const table_free_count = split.cell(&table_free_count_var, "alloc.table_free_count");
/// The ranges of dropped Tables that could be neither mapped afresh nor
/// filled (`loseTableRange`): addresses inside a region that are not the
/// Tables'.
const table_holes_max = 16;
var table_holes_var: [table_holes_max]Range = undefined;
const table_holes = split.cell(&table_holes_var, "alloc.table_holes");
var table_hole_count_var: usize = 0;
const table_hole_count = split.cell(&table_hole_count_var, "alloc.table_hole_count");
/// How a test makes mapping a range afresh fail: not, leaving a hole
/// that can be filled, or leaving one that cannot.
var table_remap_fails_for_test_var: enum { no, remap, and_plug } = .no;
const table_remap_fails_for_test = split.cell(&table_remap_fails_for_test_var, "alloc.table_remap_fails_for_test");
/// Whether any range has asked for huge pages, so a range given back is
/// advised for small pages again before the next Table takes it.
var tables_asked_huge_var: std.atomic.Value(bool) = .init(false);
const tables_asked_huge = split.cell(&tables_asked_huge_var, "alloc.tables_asked_huge");
/// The Tables handed out and not given back: each holds at least one
/// page-table page once written, which the exit's teardown counts
/// (`exitWork`).
var table_live_var: std.atomic.Value(usize) = .init(0);
const table_live = split.cell(&table_live_var, "alloc.table_live");

/// Whether Tables take their ranges from the regions here: on Linux and
/// the Mac.
const tables_here = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// A range of at least `bytes`, from a 2 MiB boundary, for a reserved
/// Table: zeros, none committed. Its first 2 MiB keep small pages, and
/// the rest asks for huge pages while the system has free 2 MiB blocks
/// to spare (`hugeFree`), as `table.zig`'s `reserve` describes (on
/// Linux; the Mac has no huge pages to ask for). Under `always`, the
/// rest has huge pages unasked and asks for nothing, and the first 2 MiB
/// ask for small pages (`adviceFor`). Null where Tables are not taken
/// from here: off Linux and the Mac, a Table larger than a region, or no
/// region to be had.
pub fn reserveTable(bytes: usize) ?[*]align(huge_page) u8 {
    if (!tables_here) return null;
    const len = std.mem.alignForward(usize, bytes, huge_page);
    if (len > table_region_size) return null;
    // Read before `tables_lock`, which a new region's advice is under.
    if (builtin.os.tag == .linux) _ = thpMode();
    const huge = builtin.os.tag == .linux and len > huge_page and hugeFree();
    tables_lock.lock();
    const p = takeTableRange(len);
    tables_lock.unlock();
    const at = p orelse return null;
    _ = table_live.fetchAdd(1, .monotonic);
    if (huge) {
        tables_asked_huge.store(true, .monotonic);
        std.posix.madvise(@ptrFromInt(at + huge_page), bytes - huge_page, std.os.linux.MADV.HUGEPAGE) catch {};
    }
    ask(at, huge_page, .small);
    return @ptrFromInt(at);
}

/// Give back the range of a Table of `bytes` at `p`, if it is one
/// `reserveTable` handed out: its pages to the system, and the range,
/// advised for small pages again on Linux, to the next Table. Under
/// Linux's `always`, where its first 2 MiB asked for small pages, and on
/// the Mac, it is mapped afresh, which asks for nothing. A range that
/// cannot be is not used again: on Linux it is set aside
/// (`loseTableRange`); on the Mac, where its old mapping stays, it keeps
/// its pages and stays the region's.
pub fn unreserveTable(p: [*]u8, bytes: usize) bool {
    if (!tables_here) return false;
    const at = @intFromPtr(p);
    const len = std.mem.alignForward(usize, bytes, huge_page);
    tables_lock.lock();
    var mine = false;
    for (table_regions[0..table_region_count.*]) |r| mine = mine or (r.start <= at and at < r.start + r.len);
    for (table_holes[0..table_hole_count.*]) |r| mine = mine and !(r.start <= at and at < r.start + r.len);
    tables_lock.unlock();
    if (!mine) return false;
    _ = table_live.fetchSub(1, .monotonic);
    const range: [*]align(huge_page) u8 = @alignCast(p);
    if (builtin.os.tag == .linux and adviceFor(thpMode(), .small) != .small) {
        std.posix.madvise(range, len, std.os.linux.MADV.DONTNEED) catch {};
        if (len > huge_page and tables_asked_huge.load(.monotonic)) std.posix.madvise(range, len, std.os.linux.MADV.NOHUGEPAGE) catch {};
    } else if (!mapTableRangeAfresh(range, len)) {
        if (builtin.os.tag == .linux) loseTableRange(range, len);
        return true;
    }
    tables_lock.lock();
    giveTableRange(at, len);
    tables_lock.unlock();
    return true;
}

/// Map the `len` bytes at `range` afresh (`MAP_FIXED`), which gives its
/// pages back and leaves it asking for nothing. False if the system
/// could not: a Linux before 6.12 may then have unmapped the range and
/// mapped nothing in its place, and the Mac keeps the old mapping.
fn mapTableRangeAfresh(range: [*]align(huge_page) u8, len: usize) bool {
    if (comptime builtin.is_test) if (table_remap_fails_for_test.* != .no) {
        // As such a Linux may fail: the old mapping gone, no new one.
        std.posix.munmap(range[0..len]);
        return false;
    };
    _ = std.posix.mmap(range, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = true }, -1, 0) catch return false;
    return true;
}

/// Set aside the range of a Table that could not be mapped afresh: its
/// pages go back to the system, and it is never handed out again. So
/// that nothing the system maps later lands inside a region, where a
/// Table given back would be taken for one of the region's, a hole it
/// may have left is filled by a mapping no access may touch
/// (`PROT_NONE`, `MAP_FIXED_NOREPLACE`, which fails where anything is
/// mapped). A range that cannot be filled so is kept as a hole
/// (`table_holes`), which `unreserveTable` takes for no Table's; past
/// `table_holes_max` of them the program panics rather than risk it.
fn loseTableRange(range: [*]align(huge_page) u8, len: usize) void {
    @branchHint(.cold);
    std.posix.madvise(range, len, std.os.linux.MADV.DONTNEED) catch {};
    if (plugTableRange(range, len)) return;
    tables_lock.lock();
    defer tables_lock.unlock();
    if (table_hole_count.* == table_holes_max) @panic("rig: the system could not take back the ranges of dropped tables");
    table_holes[table_hole_count.*] = .{ .start = @intFromPtr(range), .len = len };
    table_hole_count.* += 1;
}

/// Fill the `len` bytes at `range` with a mapping no access may touch.
/// False if any of it is mapped already, or Linux could not.
fn plugTableRange(range: [*]align(huge_page) u8, len: usize) bool {
    if (comptime builtin.is_test) if (table_remap_fails_for_test.* == .and_plug) return false;
    const got = std.posix.mmap(range, len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED_NOREPLACE = true }, -1, 0) catch return false;
    if (@intFromPtr(got.ptr) == @intFromPtr(range)) return true;
    // A Linux before 4.17 takes the address as a hint and maps elsewhere.
    std.posix.munmap(got);
    return false;
}

/// `len` bytes of the Tables' address space: the smallest free range
/// that holds them, else the newest region's rest, else a new region.
/// Under `tables_lock`.
fn takeTableRange(len: usize) ?usize {
    var best: ?usize = null;
    for (table_free[0..table_free_count.*], 0..) |r, i| {
        if (r.len >= len and (best == null or r.len < table_free[best.?].len)) best = i;
    }
    if (best) |i| {
        const r = &table_free[i];
        const p = r.start;
        r.start += len;
        r.len -= len;
        if (r.len == 0) {
            std.mem.copyForwards(Range, table_free[i .. table_free_count.* - 1], table_free[i + 1 .. table_free_count.*]);
            table_free_count.* -= 1;
        }
        return p;
    }
    if (table_end.* - table_next.* < len and !newTableRegion()) return null;
    const p = table_next.*;
    table_next.* += len;
    return p;
}

/// Map a new region, on Linux advised for small pages under `madvise`
/// (`Thp`),
/// and give the newest one's rest to the free ranges. Under
/// `tables_lock`.
fn newTableRegion() bool {
    @branchHint(.cold);
    if (tables_unmapped.* or table_region_count.* == table_regions_max) return false;
    const raw = std.posix.mmap(null, table_region_size + huge_page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
        tables_unmapped.* = true;
        return false;
    };
    if (builtin.os.tag == .linux) {
        const mode = thpMode();
        if (!mode.off and !mode.by_default) std.posix.madvise(raw.ptr, raw.len, std.os.linux.MADV.NOHUGEPAGE) catch {};
    }
    const start = std.mem.alignForward(usize, @intFromPtr(raw.ptr), huge_page);
    if (table_end.* > table_next.*) giveTableRange(table_next.*, table_end.* - table_next.*);
    table_regions[table_region_count.*] = .{ .start = start, .len = table_region_size };
    table_region_count.* += 1;
    table_next.* = start;
    table_end.* = start + table_region_size;
    return true;
}

/// Put `len` bytes at `p` back: onto the newest region's rest when they
/// end there, else among the free ranges, joined to those they touch.
/// Under `tables_lock`.
fn giveTableRange(p: usize, len: usize) void {
    if (p + len == table_next.*) {
        table_next.* = p;
        // A free range that now ends at the rest joins it.
        for (table_free[0..table_free_count.*], 0..) |r, i| if (r.start + r.len == p) {
            table_next.* = r.start;
            std.mem.copyForwards(Range, table_free[i .. table_free_count.* - 1], table_free[i + 1 .. table_free_count.*]);
            table_free_count.* -= 1;
            break;
        };
        return;
    }
    // The first free range after `p`.
    var i: usize = 0;
    while (i < table_free_count.* and table_free[i].start < p) i += 1;
    const joins_before = i > 0 and table_free[i - 1].start + table_free[i - 1].len == p;
    const joins_after = i < table_free_count.* and p + len == table_free[i].start;
    if (joins_before and joins_after) {
        table_free[i - 1].len += len + table_free[i].len;
        std.mem.copyForwards(Range, table_free[i .. table_free_count.* - 1], table_free[i + 1 .. table_free_count.*]);
        table_free_count.* -= 1;
    } else if (joins_before) {
        table_free[i - 1].len += len;
    } else if (joins_after) {
        table_free[i].start = p;
        table_free[i].len += len;
    } else if (table_free_count.* < table_free_max) {
        std.mem.copyBackwards(Range, table_free[i + 1 .. table_free_count.* + 1], table_free[i..table_free_count.*]);
        table_free[i] = .{ .start = p, .len = len };
        table_free_count.* += 1;
    }
}

// -----------------------------------------------------------------------------
// What `os.exit` may unmap
// -----------------------------------------------------------------------------

/// A range of address space the exit's teardown unmaps (`sched.tearDown`).
pub const ExitRange = Range;

/// The most ranges `exitRanges` gives: the segments' region in two, and
/// every Tables region, cut in one more piece by each hole.
pub const exit_ranges_max = 2 + table_regions_max + table_holes_max;

/// The address space of this file that holds the program's memory, for
/// `os.exit` to unmap before the process ends: the segments' region up
/// to its next segment, densely written, as `dense` of the ranges (0 or
/// 1), then its rest and each Tables region, whole but for its holes
/// (`table_holes`), which are sparse: the kernel walks even a range
/// never touched as the process ends. Each was mapped once and is never
/// unmapped while the program runs, so no other mapping holds any of its
/// addresses. Read once every thread
/// that could take a segment or a Table has stopped.
pub fn exitRanges(out: *[exit_ranges_max]Range) struct { ranges: []Range, dense: usize } {
    var n: usize = 0;
    var dense: usize = 0;
    const next = region_next.load(.acquire);
    if (region_end.* != 0 and next > 1) {
        const start = region_end.* - region_size;
        if (next > start) {
            out[n] = .{ .start = start, .len = next - start };
            n += 1;
            dense = 1;
        }
        if (region_end.* > next) {
            out[n] = .{ .start = next, .len = region_end.* - next };
            n += 1;
        }
    }
    for (table_regions[0..table_region_count.*]) |r| {
        var from = r.start;
        const end = r.start + r.len;
        while (true) {
            // The region's first hole from `from`, which the ranges skip.
            var hole: ?Range = null;
            for (table_holes[0..table_hole_count.*]) |h| {
                if (h.start >= from and h.start < end and (hole == null or h.start < hole.?.start)) hole = h;
            }
            const to = if (hole) |h| h.start else end;
            if (to > from) {
                out[n] = .{ .start = from, .len = to - from };
                n += 1;
            }
            from = (hole orelse break).start + hole.?.len;
        }
    }
    return .{ .ranges = out[0..n], .dense = dense };
}

/// About how many page-table pages the program's segments and Tables
/// hold, and how many MiB of segments: what `os.exit`'s teardown would
/// save, read without a lock (an estimate, to decide whether to try).
pub fn exitWork(span: usize) struct { page_tables: usize, segment_mib: usize } {
    const next = region_next.load(.monotonic);
    const end = @atomicLoad(usize, region_end, .monotonic);
    const used = if (end != 0 and next > end - region_size) next - (end - region_size) else 0;
    return .{ .page_tables = table_live.load(.monotonic) + used / span, .segment_mib = used >> 20 };
}

// -----------------------------------------------------------------------------
// What the program's allocations come to
// -----------------------------------------------------------------------------

/// The bytes of the program's live blocks (each counted at its class's
/// size, or a large block's), the most they have come to, and how many
/// blocks the program has taken. Each heap adds to them what it counted
/// once it is `flush_bytes` bytes or `flush_allocs` blocks away, so they
/// trail each thread by at most that much (`Heap.count`).
///
/// Each sits on a cache line of its own: placed among the runtime's other
/// globals, they shifted those, and a task's spawn ran about 60% slower
/// on Apple cores (bench/tasks), as a line shared by cores that write it
/// would make it.
var total_live_var: std.atomic.Value(isize) align(128) = .init(0);
const total_live = split.cell(&total_live_var, "alloc.total_live");
var total_peak_var: std.atomic.Value(isize) align(128) = .init(0);
const total_peak = split.cell(&total_peak_var, "alloc.total_peak");
var total_allocs_var: std.atomic.Value(u64) align(128) = .init(0);
const total_allocs = split.cell(&total_allocs_var, "alloc.total_allocs");
const flush_bytes: isize = 64 << 10;
const flush_allocs: u32 = 1024;

/// The bytes of blocks a thread took less those it gave back, and the
/// blocks it took.
const Pending = if (counts) struct { bytes: isize = 0, allocs: u32 = 0 } else struct {};

pub const Totals = struct { live: i64, peak: i64, allocs: i64 };

/// The program's totals (`os.memory`), after adding the running thread's
/// own count, so a program on one thread reads them exactly.
pub fn totals() Totals {
    if (!counts) @compileError("os.memory in a program whose root does not declare __rig_memory");
    if (heap()) |h| h.flush();
    return .{
        .live = @intCast(total_live.load(.monotonic)),
        .peak = @intCast(total_peak.load(.monotonic)),
        .allocs = @intCast(total_allocs.load(.monotonic)),
    };
}

threadlocal var my_heap_var: ?*Heap = null;
inline fn my_heap() *?*Heap {
    return split.local(&my_heap_var, "alloc.my_heap");
}

/// Whether each heap checks that the thread using it owns it: in safe
/// builds.
const check_owner = std.debug.runtime_safety;

/// One byte per thread, whose address names the thread (`threadToken`).
threadlocal var my_token_var: u8 = 0;
inline fn my_token() *u8 {
    return split.local(&my_token_var, "alloc.my_token");
}

/// The running thread, as the address of its own `my_token`. A fiber
/// may resume on another thread after any switch, and a compiler may
/// reuse a thread-local's address within a function, so every read goes
/// through a call that is never inlined, as `sched.me` does.
noinline fn threadToken() usize {
    return @intFromPtr(my_token());
}

/// In a safe build, panic unless the running thread owns `h`: a heap
/// has no lock, so only its own thread may take from it or give to it.
inline fn mustOwn(h: *const Heap) void {
    if (check_owner and h.owner != threadToken()) owner_lost.*();
}

/// What `mustOwn` does with a heap another thread owns; a test sets it
/// to count instead.
var owner_lost_var: *const fn () void = ownerLost;
pub const owner_lost = split.cell(&owner_lost_var, "alloc.owner_lost");

fn ownerLost() void {
    @branchHint(.cold);
    @panic("rig: a thread used another thread's heap");
}

/// Test only: the running thread's heap, to use as a caller that kept it
/// across a switch would.
pub fn heapForTest() *Heap {
    return heap().?;
}

/// Test only: the check a heap's paths make first (`mustOwn`).
pub fn checkOwnForTest(h: *const Heap) void {
    mustOwn(h);
}

/// What `owner_lost` is but in a test.
pub const owner_lost_default: *const fn () void = ownerLost;

/// Heaps given back by threads that ended, for the next to start.
var spare_heaps_var: std.atomic.Value(?*Heap) = .init(null);
const spare_heaps = split.cell(&spare_heaps_var, "alloc.spare_heaps");
var spare_lock_var: SpinLock = .{};
const spare_lock = split.cell(&spare_lock_var, "alloc.spare_lock");

/// The running thread's heap, made as it first allocates. Never
/// inlined: a fiber may resume on another thread after any switch, and
/// a compiler may reuse a thread-local's address within a function, so
/// a caller that allocated before a switch would go on with the heap of
/// the thread it left (`sched.me`). The fast paths, `alloc` and `free`,
/// read `my_heap` themselves for the same reason never inlined.
noinline fn heap() ?*Heap {
    if (my_heap().*) |h| return h;
    return newHeap();
}

fn newHeap() ?*Heap {
    @branchHint(.cold);
    // A heap a thread that ended gave back, with what it holds.
    spare_lock.lock();
    const spare = spare_heaps.load(.monotonic);
    if (spare) |s| spare_heaps.store(s.next_free, .monotonic);
    spare_lock.unlock();
    if (spare) |s| {
        s.next_free = null;
        if (check_owner) s.owner = threadToken();
        my_heap().* = s;
        return s;
    }
    const bytes = std.posix.mmap(null, std.mem.alignForward(usize, @sizeOf(Heap), std.heap.pageSize()), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    const h: *Heap = @ptrCast(@alignCast(bytes.ptr));
    h.* = .{};
    if (check_owner) h.owner = threadToken();
    my_heap().* = h;
    return h;
}

/// The running thread ends: give its heap back for the next thread, so
/// what it holds, and the blocks other threads free into it, are used
/// again.
pub noinline fn threadExit() void {
    const h = my_heap().* orelse return;
    if (counts) h.flush();
    my_heap().* = null;
    spare_lock.lock();
    h.next_free = spare_heaps.load(.monotonic);
    spare_heaps.store(h, .monotonic);
    spare_lock.unlock();
}

// -----------------------------------------------------------------------------
// The Allocator interface
// -----------------------------------------------------------------------------

pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

// The fast paths. `alloc` and `free` serve a small block of the common
// sizes, up to `small_table_max` bytes aligned to 8 or less, from and to
// the running thread's own free list, with no call, and leave the rest to
// `allocSlow` and `freeSlow`. They read the thread's heap (`my_heap`)
// themselves, which is safe because neither is ever inlined: the read is
// made in their own frame, never one a caller shares across a fiber
// switch (`heap`), and between it and their last use of the heap they
// call nothing that could switch.
//
// They skip two checks the slow paths make, each always true here:
//
// - The owner check (`mustOwn`): `my_heap` is written only by `newHeap`,
//   which sets the heap's `owner` to the running thread in the same call,
//   and by `threadExit`, to null, and `owner` is written nowhere else; so
//   a heap read from `my_heap`, on the thread that runs on until the read
//   is used, is that thread's. The runtime's own tests keep the check, so
//   the scheduler's test of fibers that move between threads would catch
//   a fast path that used a stale heap.
// - The bounds check on `free[c]`: `c` is a `Class`, whose type bounds it
//   below `free_slots`, the length of `free`.

/// A block of `len` bytes aligned to `alignment`.
noinline fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (fastClass(len, alignment)) |c| if (my_heap().*) |h| if (h.free[c]) |b| {
        if (builtin.is_test) mustOwn(h);
        h.free[c] = b.next;
        if (counts) h.count(@intCast(classSize(c)), 1);
        return @ptrCast(b);
    };
    const p = allocSlow(len, alignment);
    // Its heap's state is whole again: a caller in the program's code
    // may yield here (`sched.settleAt`).
    if (sched.preempting) sched.settleAt(@returnAddress());
    return p;
}

/// Give back `memory`, a block `alloc` made with `alignment`.
noinline fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    if (fastClass(memory.len, alignment)) |c| if (my_heap().*) |h| {
        const seg = segmentOf(memory.ptr);
        if (seg.heap == h) {
            if (builtin.is_test) mustOwn(h);
            const b = blockOf(memory.ptr);
            b.next = h.free[c];
            h.free[c] = b;
            if (counts) h.count(-@as(isize, @intCast(classSize(c))), 0);
            return;
        }
    };
    freeSlow(memory, alignment);
}

// `segmentOf` and `blockOf` read a small block `alloc` made, which `free`
// and `freeSmall` are given: Zig's checks on their casts are kept in a
// debug build and left out of an optimized one, where the allocator's own
// layout proves them. Both are spelled as the runtime's are.
const proven_checks = builtin.mode == .debug;

/// A fact the allocator relies on in place of a check, asserted in a
/// debug build, as the runtime's `invariant` is.
inline fn invariant(ok: bool) void {
    if (builtin.mode == .debug) std.debug.assert(ok);
}

/// The segment that holds `p`, a small block: segments are aligned to
/// `segment_size`, and a block is never in a segment's first page (its
/// header's), so the address is the segment's and is not zero.
inline fn segmentOf(p: [*]u8) *Segment {
    invariant(@intFromPtr(p) & (segment_size - 1) >= page_size);
    // A block lies past its segment's header, so the segment is not null.
    @setRuntimeSafety(proven_checks);
    return @ptrFromInt(@intFromPtr(p) & ~(segment_size - 1));
}

/// `p`, a small block, as a free-list entry: carved at a multiple of its
/// class's size, every one a multiple of 8, from a page, so aligned for
/// a `Block`.
inline fn blockOf(p: [*]u8) *Block {
    invariant(@intFromPtr(p) % @alignOf(Block) == 0);
    // Every class's size is a multiple of 8 (`classSize`), as is a page.
    @setRuntimeSafety(proven_checks);
    return @ptrCast(@alignCast(p));
}

/// The class of a block the fast paths serve, or null.
inline fn fastClass(len: usize, alignment: std.mem.Alignment) ?Class {
    if (alignment.toByteUnits() > 8 or len > small_table_max) return null;
    return small_table[(len + 7) >> 3];
}

/// What `alloc`'s fast path leaves: a class whose free list is empty, a
/// larger or more aligned block, or a thread with no heap yet.
noinline fn allocSlow(len: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const h = heap() orelse return null;
    if (classOf(len, alignment)) |c| {
        const p = h.alloc(c);
        if (counts) if (p != null) h.count(@intCast(classSize(c)), 1);
        return p;
    }
    if (alignment.toByteUnits() > std.heap.pageSize()) return null;
    const p = allocLarge(h, len);
    if (counts) if (p != null) h.count(@intCast(largeSize(len)), 1);
    return p;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old) |c| return new != null and new.? == c;
    if (new != null) return false;
    return largeSize(memory.len) == largeSize(new_len);
}

// -----------------------------------------------------------------------------
// Runs of the executable mapped into a List
// -----------------------------------------------------------------------------

/// The fewest bytes of an embedded run `List.extend_from_bytes` maps
/// rather than copies (`mapRun`): below it the copy costs less than the
/// system call, and the free and grow tests below look only at blocks this
/// large, so a smaller one never pays for them.
pub const map_min: usize = 64 << 10;

/// The mapped runs a program may hold at once; a run past them is copied.
const map_spans_max = 256;

var mapped_lock_var: SpinLock = .{};
const mapped_lock = split.cell(&mapped_lock_var, "alloc.mapped_lock");
/// The mappings `mapRun` made, each from its page to the run's end.
var mapped_spans_var: [map_spans_max]Range = undefined;
const mapped_spans = split.cell(&mapped_spans_var, "alloc.mapped_spans");
var mapped_count_var: std.atomic.Value(usize) = .init(0);
const mapped_count = split.cell(&mapped_count_var, "alloc.mapped_count");

/// The executable's own file, opened once, read-only, and where the
/// read-only parts of its running image lie in it: `fd` is -2 before the
/// first run and -1 where it cannot be read.
const ExeFile = struct {
    fd: i32 = -2,
    loads: [max_loads]Load = undefined,
    load_count: usize = 0,
};
/// A read-only part of the running image the file holds whole: `len`
/// bytes from `addr`, which are the file's from `offset` (a `PT_LOAD`
/// without `PF_W` on Linux, an `LC_SEGMENT_64` without write in its
/// initial protection on macOS).
const Load = struct { addr: usize, len: usize, offset: u64 };
const max_loads = 8;
const Phdr = extern struct { type: u32, flags: u32, offset: u64, vaddr: u64, paddr: u64, filesz: u64, memsz: u64, @"align": u64 };
var exe_file_var: ExeFile = .{};
const exe_file = split.cell(&exe_file_var, "alloc.exe_file");

/// Whether `mapRun` maps runs on this target: Linux and macOS.
pub const maps_files = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// The pages of the executable's file that hold `bytes`, a run of a
/// read-only part of the running image (an `$embed`, a literal), mapped
/// privately (`MAP_PRIVATE`), so the kernel reads each page from the file
/// as it is first touched, shares it with the page cache, and copies it
/// for this mapping alone when it is first written: a List over them
/// owns its elements as any List does, and no other value sees its
/// writes. Its address within a page is the run's, so it keeps the run's
/// alignment. Null, and the caller copies, off Linux and macOS, where the
/// file cannot be opened (`/proc/self/exe`, `_NSGetExecutablePath`) or is
/// not the image (a universal binary's file begins with its own header),
/// for a run not in a read-only loaded part, when `map_spans_max` runs are
/// mapped, or when the system refuses. The mapping is given back by
/// `free` or by growing the List past it, which copies (`releaseMapped`,
/// `remap`).
pub fn mapRun(bytes: []const u8) ?[*]u8 {
    if (!maps_files or bytes.len < map_min) return null;
    mapped_lock.lock();
    defer mapped_lock.unlock();
    const exe = exe_file;
    if (exe.fd == -2) openExe(exe);
    if (exe.fd < 0 or mapped_count.load(.monotonic) == map_spans_max) return null;
    const at = @intFromPtr(bytes.ptr);
    for (exe.loads[0..exe.load_count]) |l| {
        if (at < l.addr or at + bytes.len > l.addr + l.len) continue;
        const off = at - l.addr + l.offset;
        const page = std.heap.pageSize();
        const start = off - off % page;
        const len = off - start + bytes.len;
        const m = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, exe.fd, @intCast(start)) catch return null;
        const n = mapped_count.load(.monotonic);
        mapped_spans[n] = .{ .start = @intFromPtr(m.ptr), .len = len };
        mapped_count.store(n + 1, .release);
        return m.ptr + (off - start);
    }
    return null;
}

/// Open the executable's file and find the read-only parts of the
/// running image it holds, once (`mapRun`, under its lock).
fn openExe(exe: *ExeFile) void {
    exe.fd = -1;
    exe.load_count = 0;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const ph: usize = linux.getauxval(std.elf.AT.PHDR);
        const num: usize = linux.getauxval(std.elf.AT.PHNUM);
        if (ph == 0 or num == 0) return;
        const phdrs = @as([*]const Phdr, @ptrFromInt(ph))[0..num];
        // How far the image is loaded from the addresses the headers
        // give (`PT_PHDR`).
        var bias: usize = 0;
        for (phdrs) |p| if (p.type == 6) {
            bias = ph -% p.vaddr;
        };
        for (phdrs) |p| {
            // PT_LOAD, without PF_W: what the file holds is what the image does.
            if (p.type != 1 or p.flags & 2 != 0) continue;
            if (exe.load_count == max_loads) break;
            exe.loads[exe.load_count] = .{ .addr = @intCast(p.vaddr +% bias), .len = @intCast(p.filesz), .offset = p.offset };
            exe.load_count += 1;
        }
        const rc = linux.open("/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        exe.fd = @intCast(rc);
    } else if (builtin.os.tag == .macos) {
        const macho = std.macho;
        const hdr: *const macho.mach_header_64 = @ptrCast(@alignCast(std.c._dyld_get_image_header(0) orelse return));
        if (hdr.magic != macho.MH_MAGIC_64) return;
        const slide = std.c._dyld_get_image_vmaddr_slide(0);
        var cmd: [*]const u8 = @ptrCast(hdr);
        cmd += @sizeOf(macho.mach_header_64);
        for (0..hdr.ncmds) |_| {
            const lc: *align(1) const macho.load_command = @ptrCast(cmd);
            if (lc.cmd == .SEGMENT_64) {
                const seg: *align(1) const macho.segment_command_64 = @ptrCast(cmd);
                // Not written as the image loads: what the file holds is
                // what the image does.
                if (!seg.initprot.WRITE and seg.filesize > 0 and exe.load_count < max_loads) {
                    exe.loads[exe.load_count] = .{ .addr = @intCast(seg.vmaddr +% slide), .len = @intCast(seg.filesize), .offset = seg.fileoff };
                    exe.load_count += 1;
                }
            }
            cmd += lc.cmdsize;
        }
        var path: [4096]u8 = undefined;
        var size: u32 = path.len - 1;
        if (std.c._NSGetExecutablePath(&path, &size) != 0) return;
        const fd = std.c.open(@ptrCast(&path), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return;
        // The file is the image only if it begins with the image's own
        // header: a universal binary begins with its list of slices.
        var head: [@sizeOf(macho.mach_header_64)]u8 = undefined;
        const got = std.c.pread(fd, &head, head.len, 0);
        if (got != head.len or !std.mem.eql(u8, &head, std.mem.asBytes(hdr))) {
            _ = std.c.close(fd);
            return;
        }
        exe.fd = fd;
    }
}

/// Whether `p` lies in a run `mapRun` mapped. Out of line, as `freeSlow`
/// is, so no caller of the allocator that inlines it changes.
noinline fn isMapped(p: [*]const u8) bool {
    if (mapped_count.load(.acquire) == 0) return false;
    mapped_lock.lock();
    defer mapped_lock.unlock();
    const x = @intFromPtr(p);
    for (mapped_spans[0..mapped_count.load(.monotonic)]) |r| if (x >= r.start and x < r.start + r.len) return true;
    return false;
}

/// Give back the mapping of the run `memory` begins in, when it is one
/// (`mapRun`): true when it was.
fn releaseMapped(memory: []u8) bool {
    if (mapped_count.load(.acquire) == 0) return false;
    mapped_lock.lock();
    defer mapped_lock.unlock();
    const x = @intFromPtr(memory.ptr);
    const n = mapped_count.load(.monotonic);
    for (mapped_spans[0..n], 0..) |r, i| {
        if (x < r.start or x >= r.start + r.len) continue;
        unmapLarge(r.start, r.len);
        mapped_spans[i] = mapped_spans[n - 1];
        mapped_count.store(n - 1, .release);
        return true;
    }
    return false;
}

/// A large block grown to `new_len`: copied into a kept block that fits,
/// which then keeps the old one in turn, since a kept block's pages are
/// resident and copying into them costs less than faulting in fresh
/// ones; else, on Linux and from `move_large`, grown by moving its pages
/// (`mremap`). Anything else, or a block that shrinks, is left to the
/// caller, which copies it into a new block.
fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    // A mapped run is not this heap's: the caller copies it into a new
    // block and frees it (`mapRun`).
    if (memory.len >= map_min and isMapped(memory.ptr)) return null;
    if (resize(ctx, memory, alignment, new_len, ret)) return memory.ptr;
    if (classOf(memory.len, alignment) != null or classOf(new_len, alignment) != null) return null;
    if (new_len < memory.len) return null;
    const h = heap() orelse return null;
    const old_size = largeSize(memory.len);
    const new_size = largeSize(new_len);
    if (takeKept(&h.kept, new_size)) |p| {
        lent(h, new_size);
        @memcpy(p[0..memory.len], memory);
        freeLarge(h, memory.ptr, memory.len);
        if (counts) h.count(@intCast(new_size - old_size), 0);
        return p;
    }
    if (builtin.os.tag != .linux or memory.len < move_large) return null;
    const linux = std.os.linux;
    // A block grown to `huge_large` moves to pages aligned for huge ones.
    const to = if (new_size >= huge_large) mapLarge(new_size) orelse return null else 0;
    const rc = linux.mremap(@alignCast(memory.ptr), old_size, new_size, .{ .MAYMOVE = true, .FIXED = to != 0 }, if (to != 0) @ptrFromInt(to) else null);
    if (@as(isize, @bitCast(rc)) < 0 and @as(isize, @bitCast(rc)) > -4096) {
        if (to != 0) unmapLarge(to, new_size);
        return null;
    }
    // A block that grows to `huge_large` asks for huge pages, as one
    // taken afresh does, and one that grows to `huge_page` for small ones.
    // The range keeps the advice of the block it grew from, so one that
    // grows from a block that asked for small pages asks again
    // (`huge_again`).
    if (to != 0) {
        ask(rc, new_size, if (old_size >= huge_page and old_size < huge_large) .huge_again else .huge);
    } else if (new_size >= huge_page and old_size < huge_page) {
        ask(rc, new_size, .small);
    }
    // The pages moved stay; of the new ones, those a List is likely to
    // fill are faulted in at once.
    h.took(new_size - old_size);
    lent(h, new_size - old_size);
    trimKept(h);
    prefault(h, rc + old_size, likelyFilled((new_size - old_size) / 2));
    if (counts) h.count(@intCast(new_size - old_size), 0);
    return @ptrFromInt(rc);
}

/// What `free`'s fast path leaves: a block of another thread's heap, a
/// larger or more aligned one, or a thread with no heap yet.
noinline fn freeSlow(memory: []u8, alignment: std.mem.Alignment) void {
    if (memory.len >= map_min and releaseMapped(memory)) return;
    const h = heap() orelse return;
    if (classOf(memory.len, alignment)) |c| {
        if (counts) h.count(-@as(isize, @intCast(classSize(c))), 0);
        return h.freeSmall(memory.ptr, c);
    }
    if (counts) h.count(-@as(isize, @intCast(largeSize(memory.len))), 0);
    freeLarge(h, memory.ptr, memory.len);
}

test "size classes cover every small size, each a fit for what it holds" {
    var len: usize = 1;
    while (len <= max_small) : (len += 1) {
        const c = classOf(len, .@"8").?;
        try std.testing.expect(classSize(c) >= len);
        if (c > 0) try std.testing.expect(classSize(c - 1) < @max(len, 8));
        // At most a fifth wasted past 64 bytes.
        if (len > 64) try std.testing.expect(classSize(c) * 4 <= len * 5 + 4 * 8);
    }
    try std.testing.expect(classOf(max_small + 1, .@"8") == null);
    // An alignment the class does not keep moves to one that does.
    const c16 = classOf(24, .@"16").?;
    try std.testing.expect(classSize(c16) % 16 == 0 and classSize(c16) >= 24);
}

test "blocks are reused, large ones kept, and a block freed on another thread goes back to its heap" {
    const a = allocator;
    var ptrs: [1000][]u8 = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = try a.alloc(u8, 1 + i * 37 % 5000);
        @memset(p.*, @truncate(i));
    }
    for (ptrs, 0..) |p, i| for (p) |b| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
    for (ptrs) |p| a.free(p);
    const again = try a.alloc(u8, 100);
    a.free(again);
    const big = try a.alloc(u8, 1 << 20);
    const big_ptr = big.ptr;
    a.free(big);
    const big2 = try a.alloc(u8, 1 << 20);
    try std.testing.expectEqual(big_ptr, big2.ptr);
    a.free(big2);
    // Freed on another thread, taken back by this one.
    const x = try a.alloc(u8, 48);
    const T = struct {
        fn run(p: []u8) void {
            allocator.free(p);
            threadExit();
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{x});
    th.join();
    // The free list of the class runs out first only after its own
    // blocks; drain it until the remote one comes back.
    var got = false;
    var held: [4096][]u8 = undefined;
    var n: usize = 0;
    while (n < held.len) : (n += 1) {
        held[n] = try a.alloc(u8, 48);
        if (held[n].ptr == x.ptr) {
            got = true;
            n += 1;
            break;
        }
    }
    for (held[0..n]) |p| a.free(p);
    try std.testing.expect(got);
}

test "the heap that does the work faults in ahead, beside a thread that takes little, and two busy heaps fault lazily" {
    const a = allocator;
    // This thread's heap does the program's work: four times what every
    // heap has taken so far, and more.
    const work = try a.alloc(u8, 4 * taken_all.load(.monotonic) + (16 << 20));
    defer a.free(work);
    const me = heapForTest();
    try std.testing.expect(leads(me));
    // A thread that reads a file, as the blocking pool does: its buffer
    // makes a heap, which does not lead, and the first still does.
    const Reader = struct {
        fn run(buf: *[]u8, led: *bool) void {
            buf.* = allocator.alloc(u8, 1 << 20) catch unreachable;
            led.* = leads(heapForTest());
            threadExit();
        }
    };
    var buf: []u8 = undefined;
    var led = true;
    (try std.Thread.spawn(.{}, Reader.run, .{ &buf, &led })).join();
    a.free(buf);
    try std.testing.expect(!led);
    try std.testing.expect(leads(me));
    // A second thread that takes as much as the first: neither leads.
    const Worker = struct {
        fn run(n: usize, led_w: *bool, led_first: *bool, first: *const Heap) void {
            const got = allocator.alloc(u8, n) catch unreachable;
            led_w.* = leads(heapForTest());
            led_first.* = leads(first);
            allocator.free(got);
            threadExit();
        }
    };
    var led_first = true;
    (try std.Thread.spawn(.{}, Worker.run, .{ me.taken, &led, &led_first, me })).join();
    try std.testing.expect(!led);
    try std.testing.expect(!led_first);
    try std.testing.expect(!leads(me));
}

test "heaps that have each taken more than a segment fault in ahead, though neither leads, and one of a segment that does not lead faults lazily" {
    const a = allocator;
    const me = heapForTest();
    const mine = try a.alloc(u8, prefault_big);
    defer a.free(mine);
    try std.testing.expect(me.taken >= prefault_big);
    // A second thread that takes as much: neither leads, both fault in ahead.
    const Checker = struct {
        fn run(n: usize, first: *const Heap, out: *[4]bool) void {
            const got = allocator.alloc(u8, n) catch unreachable;
            const h = heapForTest();
            out.* = .{ leads(h), faultsAhead(h), leads(first), faultsAhead(first) };
            allocator.free(got);
            threadExit();
        }
    };
    var out: [4]bool = undefined;
    (try std.Thread.spawn(.{}, Checker.run, .{ me.taken, me, &out })).join();
    try std.testing.expectEqual([4]bool{ false, true, false, true }, out);
    // A heap of one segment, beside them, neither leads nor faults in ahead.
    var small: Heap = .{ .taken = segment_size };
    try std.testing.expect(!leads(&small));
    try std.testing.expect(!faultsAhead(&small));
}

/// A heap of its own for a test, owned by the running thread.
fn testHeap() Heap {
    var h: Heap = .{};
    if (check_owner) h.owner = threadToken();
    return h;
}

test "a freed large block serves a smaller request and keeps the rest, and a table dropped and built again takes no new pages" {
    var h = testHeap();
    const mib: usize = 1 << 20;
    // A 4 MiB block freed serves two of 2 MiB, head then rest.
    const big = allocLarge(&h, 4 * mib).?;
    freeLarge(&h, big, 4 * mib);
    const a = allocLarge(&h, 2 * mib).?;
    const b = allocLarge(&h, 2 * mib).?;
    try std.testing.expectEqual(big, a);
    try std.testing.expectEqual(@intFromPtr(big) + 2 * mib, @intFromPtr(b));
    freeLarge(&h, a, 2 * mib);
    freeLarge(&h, b, 2 * mib);
    // 64 blocks of 512 KiB, 32 MiB, more than `keep_large`: built a
    // second time, they take no new pages.
    var blocks: [64][*]u8 = undefined;
    for (&blocks) |*p| p.* = allocLarge(&h, 512 << 10).?;
    for (blocks) |p| freeLarge(&h, p, 512 << 10);
    const taken = h.taken;
    for (&blocks) |*p| p.* = allocLarge(&h, 512 << 10).?;
    try std.testing.expectEqual(taken, h.taken);
    for (blocks) |p| freeLarge(&h, p, 512 << 10);
    // What it holds stays within the most it handed out, and
    // `keep_large`.
    try std.testing.expect(heldLarge(&h) + h.large_live <= h.large_peak + keep_large);
    // A block larger than any kept takes new pages, past the settled
    // peak, and gives back kept ones past the bound: no more than
    // `keep_large` stay.
    const huge = allocLarge(&h, 64 * mib).?;
    try std.testing.expect(heldLarge(&h) <= keepBound(&h));
    try std.testing.expect(heldLarge(&h) <= keep_large);
    freeLarge(&h, huge, 64 * mib);
    trimAllForTest(&h);
}

test "a block grown as a List grows it, to past `keep_large`, keeps no more than `keep_large` of the blocks it grew from" {
    var h = testHeap();
    const mib: usize = 1 << 20;
    // Each growth takes a block twice the size and frees the old one,
    // whose pages stay resident while the new one, mostly untouched, is
    // filled: the heap keeps no more of them than `keep_large`.
    var len: usize = mib;
    var p = allocLarge(&h, len).?;
    while (len < 64 * mib) : (len *= 2) {
        const q = allocLarge(&h, 2 * len).?;
        freeLarge(&h, p, len);
        p = q;
        try std.testing.expect(heldLarge(&h) <= keep_large);
    }
    // Dropped, the last block is kept: it is what the heap held at its
    // settled peak.
    freeLarge(&h, p, len);
    try std.testing.expect(heldLarge(&h) + h.large_live <= h.large_peak + keep_large);
    try std.testing.expect(heldLarge(&h) > keep_large);
    trimAllForTest(&h);
}

test "tables grown past `keep_large` in all, dropped, and built again take no new pages" {
    var h = testHeap();
    // 48 tables, each grown from 128 KiB to 512 KiB, all held at once
    // (24 MiB), then dropped: built again the same way, they take their
    // pages from what the heap kept.
    var tables: [48][*]u8 = undefined;
    for (0..2) |round| {
        const taken = h.taken;
        for (&tables) |*t| {
            var len: usize = 128 << 10;
            t.* = allocLarge(&h, len).?;
            while (len < 512 << 10) : (len *= 2) {
                const q = allocLarge(&h, 2 * len).?;
                freeLarge(&h, t.*, len);
                t.* = q;
            }
        }
        if (round == 1) try std.testing.expectEqual(taken, h.taken);
        for (tables) |t| freeLarge(&h, t, 512 << 10);
    }
    trimAllForTest(&h);
}

test "a heap that does not fault in ahead keeps `keep_resident` bytes of the large blocks it frees resident and the rest by address, and a busy heap keeps them all resident" {
    // The thread's heap holds a segment, so a new heap beside it does not lead.
    const one = try allocator.alloc(u8, 64);
    defer allocator.free(one);
    var h = testHeap();
    try std.testing.expect(!faultsAhead(&h));
    // 32 blocks of 64 KiB, 2 MiB in all, written and freed.
    var blocks: [32][*]u8 = undefined;
    for (&blocks) |*p| {
        p.* = allocLarge(&h, 64 << 10).?;
        @memset(p.*[0 .. 64 << 10], 1);
    }
    const taken = h.taken;
    for (blocks) |p| freeLarge(&h, p, 64 << 10);
    try std.testing.expect(h.kept.bytes <= keep_resident);
    try std.testing.expectEqual(@as(usize, 2 << 20), h.kept.bytes + h.cold.bytes);
    // Taken again, the cold blocks serve them: no new pages, and each
    // block can be written whole.
    for (&blocks) |*p| {
        p.* = allocLarge(&h, 64 << 10).?;
        @memset(p.*[0 .. 64 << 10], 2);
    }
    try std.testing.expectEqual(taken, h.taken);
    try std.testing.expectEqual(@as(usize, 0), heldLarge(&h));
    for (blocks) |p| freeLarge(&h, p, 64 << 10);
    trimAllForTest(&h);
    // A heap that faults in ahead keeps every block resident.
    var busy = testHeap();
    busy.taken = prefault_big;
    for (&blocks) |*p| p.* = allocLarge(&busy, 64 << 10).?;
    for (blocks) |p| freeLarge(&busy, p, 64 << 10);
    try std.testing.expectEqual(@as(usize, 2 << 20), busy.kept.bytes);
    try std.testing.expectEqual(@as(usize, 0), busy.cold.bytes);
    trimAllForTest(&busy);
}

test "on Linux a new block of 16 MiB or more, and one grown to it, is aligned for huge pages and asks for them while 2 MiB blocks are free, and a smaller one does not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(big) % huge_page);
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(big)));
    const small = allocLarge(&h, 8 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(small)));
    freeLarge(&h, big, 16 * mib);
    freeLarge(&h, small, 8 * mib);
    trimAllForTest(&h);
    // A block of 8 MiB, new, grown by `mremap` to 32 MiB.
    trimAllForTest(heap().?);
    const a = allocator;
    const m = try a.alloc(u8, 8 * mib);
    @memset(m, 7);
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(m.ptr)));
    const g = a.remap(m, 32 * mib).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(g.ptr) % huge_page);
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(g.ptr)));
    try std.testing.expectEqual(@as(u8, 7), g[8 * mib - 1]);
    a.free(g);
}

test "a large block grows into a kept block that fits, which keeps the old one, and takes no new pages" {
    const a = allocator;
    const h = heap().?;
    trimAllForTest(h);
    const mib: usize = 1 << 20;
    const k = try a.alloc(u8, 4 * mib);
    const m = try a.alloc(u8, 2 * mib);
    @memset(m, 7);
    a.free(k);
    const taken = h.taken;
    const g = a.remap(m, 4 * mib).?;
    try std.testing.expectEqual(k.ptr, g.ptr);
    try std.testing.expectEqual(@as(u8, 7), g[0]);
    try std.testing.expectEqual(@as(u8, 7), g[2 * mib - 1]);
    try std.testing.expectEqual(taken, h.taken);
    // The block it grew from is kept for the next.
    const again = try a.alloc(u8, 2 * mib);
    try std.testing.expectEqual(m.ptr, again.ptr);
    a.free(again);
    a.free(g);
    trimAllForTest(h);
}

test "on Linux a large block from 64 KiB that no kept block fits grows by moving its pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = allocator;
    const h = heap().?;
    trimAllForTest(h);
    const m = try a.alloc(u8, 64 << 10);
    @memset(m, 9);
    const taken = h.taken;
    const g = a.remap(m, 128 << 10).?;
    try std.testing.expectEqual(@as(u8, 9), g[(64 << 10) - 1]);
    // Only the growth is new; the block it grew from is not kept.
    try std.testing.expectEqual(taken + largeSize(128 << 10) - largeSize(64 << 10), h.taken);
    try std.testing.expectEqual(@as(usize, 0), heldLarge(h));
    a.free(g);
    trimAllForTest(h);
}

test "on Linux a new segment of a heap that faults in ahead is aligned for huge pages and asks for them while 2 MiB blocks are free, and one of a heap that does not keeps small pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    // The thread's heap takes two segments' worth, so a new heap of one
    // segment beside it does not lead.
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    const s = p & ~(segment_size - 1);
    try std.testing.expectEqual(@as(usize, 0), s % huge_page);
    try std.testing.expect(try advisedHugeForTest(s));
    try std.testing.expect(try advisedHugeForTest(s + segment_size - 1));
    var small = testHeap();
    const q = small.newPage().?;
    try std.testing.expect(!faultsAhead(&small));
    try std.testing.expect(!try advisedHugeForTest(q));
}

/// Readings of /proc/buddyinfo for the tests: memory with free 2 MiB
/// blocks to spare, and memory fragmented as a busy build host's is.
const buddyinfo_plenty =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    211    395    378    717    515    367    336    236    159      3      0
    \\Node 0, zone   Normal 364636 108634  62179  57000  38809  19951   4972   7065   2464    300      8
    \\
;
const buddyinfo_fragmented =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    211    395    378    717    515    367    336    236    159      1      0
    \\Node 0, zone   Normal 1359150  17930   6222   5728   3186   1669   1392   3119   2467     1      0
    \\
;

test "free 2 MiB blocks are counted from orders 9 and up, an order-10 block as two, outside the DMA zone" {
    try std.testing.expectEqual(@as(usize, 3 + 300 + 16), freeHugeBlocks(buddyinfo_plenty, null, true));
    try std.testing.expectEqual(@as(usize, 2), freeHugeBlocks(buddyinfo_fragmented, null, true));
    try std.testing.expectEqual(@as(usize, 0), freeHugeBlocks("", null, true));
}

/// Readings of /proc/buddyinfo for the tests: a quiet host's idle level
/// of free 2 MiB blocks, and memory partly fragmented.
const buddyinfo_idle =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    225    437    407    793    594    402    356    236    163      4      0
    \\Node 0, zone   Normal 220790 283987 134655  91745  51471  16101   6882   8684   1943     92      2
    \\
;
const buddyinfo_partly =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    225    437    407    793    594    402    356    236    163      4      0
    \\Node 0, zone   Normal 350327 293013 229278 138927  72867  28994   8972   3759   1173     51      0
    \\
;

test "on Linux a Table asks for huge pages with 100 free 2 MiB blocks, a quiet host's idle level, and not with 55, memory partly fragmented" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 100), freeHugeBlocks(buddyinfo_idle, null, true));
    try std.testing.expectEqual(@as(usize, 55), freeHugeBlocks(buddyinfo_partly, null, true));
    defer useBuddyinfoForTest(null);
    useBuddyinfoForTest(buddyinfo_idle);
    try std.testing.expect(hugeFree());
    useBuddyinfoForTest(buddyinfo_partly);
    try std.testing.expect(!hugeFree());
}

/// A reading of /proc/buddyinfo for the tests: 17 free 2 MiB blocks, a
/// build host's level, where a Table's spare of 64 is not there.
const buddyinfo_low =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    644    647    573    798    522    427    347    248    119      1      0
    \\Node 0, zone   Normal 166456 136034  11485  85382  67040  16083   9468   1953    108     14      1
    \\
;

test "on Linux a new segment or large block asks for huge pages while free 2 MiB blocks number its own and 8 more, where a Table asks for none" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 17), freeHugeBlocks(buddyinfo_low, null, true));
    useBuddyinfoForTest(buddyinfo_low);
    defer useBuddyinfoForTest(null);
    try std.testing.expect(!hugeFree());
    try std.testing.expect(hugeFreeFor(9));
    // Each test from here reads afresh, as nothing took the blocks it
    // asked for.
    useBuddyinfoForTest(buddyinfo_low);
    try std.testing.expect(!hugeFreeFor(10));
    // A segment needs 2 blocks, a block of 16 MiB 8: both leave 8 free.
    useBuddyinfoForTest(buddyinfo_low);
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    try std.testing.expect(try advisedHugeForTest(p & ~(segment_size - 1)));
    useBuddyinfoForTest(buddyinfo_low);
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(big)));
    freeLarge(&h, big, 16 * mib);
    trimAllForTest(&h);
}

test "on Linux a burst of Tables reads /proc/buddyinfo once, and a reading older than a few milliseconds is read again" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    defer useBuddyinfoForTest(null);
    defer clock_for_test.* = null;
    // The clock's time kept in a reading wraps past 2^56 ns of uptime.
    for ([_]u64{ 1 << 40, (1 << 57) + (1 << 40) }) |start| {
        useBuddyinfoForTest(buddyinfo_idle);
        clock_for_test.* = start;
        const before = buddyinfo_reads.*;
        for (0..43) |_| try std.testing.expect(hugeFree());
        try std.testing.expectEqual(before + 1, buddyinfo_reads.*);
        // Memory fragments: the reading kept answers until its life is over.
        buddyinfo_for_test.* = buddyinfo_partly;
        clock_for_test.*.? += reading_life_ns - (1 << 17);
        try std.testing.expect(hugeFree());
        try std.testing.expectEqual(before + 1, buddyinfo_reads.*);
        clock_for_test.*.? += 1 << 17;
        try std.testing.expect(!hugeFree());
        try std.testing.expectEqual(before + 2, buddyinfo_reads.*);
    }
}

test "on Linux a kept reading may tell a new segment no, but a yes is read again and takes the segment's blocks from the reading kept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_low);
    defer useBuddyinfoForTest(null);
    clock_for_test.* = 1 << 40;
    defer clock_for_test.* = null;
    const before = buddyinfo_reads.*;
    // 17 free: a Table's reading is kept, then too few for 10 blocks and
    // 8 more answers with no new reading.
    try std.testing.expect(!hugeFree());
    try std.testing.expect(!hugeFreeFor(10));
    try std.testing.expectEqual(before + 1, buddyinfo_reads.*);
    // Enough for 2 and 8 more: read again, and the 2 are taken from it.
    try std.testing.expect(hugeFreeFor(2));
    try std.testing.expectEqual(before + 2, buddyinfo_reads.*);
    try std.testing.expectEqual(@as(?usize, 15), keptReading());
    try std.testing.expect(hugeFreeFor(7));
    try std.testing.expectEqual(@as(?usize, 10), keptReading());
    // The reading kept now says 10: too few for 3 and 8 more.
    try std.testing.expect(!hugeFreeFor(3));
    try std.testing.expectEqual(before + 3, buddyinfo_reads.*);
}

test "on Linux, with memory fragmented, no block, segment, or growth asks for huge pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_fragmented);
    defer useBuddyinfoForTest(null);
    try std.testing.expect(!hugeFree());
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(big)));
    freeLarge(&h, big, 16 * mib);
    trimAllForTest(&h);
    trimAllForTest(heap().?);
    const m = try allocator.alloc(u8, 8 * mib);
    const g = allocator.remap(m, 32 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(g.ptr)));
    allocator.free(g);
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    try std.testing.expect(faultsAhead(&busy));
    try std.testing.expect(!try advisedHugeForTest(p));
}

test "on Linux a burst of Tables takes ranges of one region, 2 MiB aligned, with one reading of /proc/buddyinfo, and gives them back to the region's rest" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_fragmented);
    defer useBuddyinfoForTest(null);
    clock_for_test.* = 1 << 40;
    defer clock_for_test.* = null;
    const reads = buddyinfo_reads.*;
    const next = table_next.*;
    var got: [43][*]u8 = undefined;
    for (&got, 0..) |*g, i| {
        g.* = reserveTable((i + 1) * (3 << 20) + 4096).?;
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(g.*) % huge_page);
    }
    try std.testing.expectEqual(reads + 1, buddyinfo_reads.*);
    try std.testing.expect(table_region_count.* >= 1);
    // Given back in another order than taken, they join one another and
    // then the region's rest.
    for (got, 0..) |g, i| if (i % 2 == 1) try std.testing.expect(unreserveTable(g, (i + 1) * (3 << 20) + 4096));
    try std.testing.expect(table_free_count.* > 0);
    for (got, 0..) |g, i| if (i % 2 == 0) try std.testing.expect(unreserveTable(g, (i + 1) * (3 << 20) + 4096));
    try std.testing.expectEqual(@as(usize, 0), table_free_count.*);
    if (next != 0) try std.testing.expectEqual(next, table_next.*);
}

test "on Linux a Table's range given back has its pages back with the system, and the next Table that takes it reads zeros" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_fragmented);
    defer useBuddyinfoForTest(null);
    const mib: usize = 1 << 20;
    const a = reserveTable(6 * mib).?;
    const b = reserveTable(4 * mib).?;
    @memset(a[0 .. 6 * mib], 7);
    try std.testing.expectEqual(@as(usize, 6 * mib), try residentForTest(a, 6 * mib));
    // `a` is not at the region's rest, so its range is kept apart.
    try std.testing.expect(unreserveTable(a, 6 * mib));
    try std.testing.expectEqual(@as(usize, 0), try residentForTest(a, 6 * mib));
    const c = reserveTable(5 * mib + 4096).?;
    try std.testing.expectEqual(a, c);
    for (c[0 .. 6 * mib]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(unreserveTable(c, 5 * mib + 4096));
    try std.testing.expect(unreserveTable(b, 4 * mib));
    try std.testing.expectEqual(@as(usize, 0), table_free_count.*);
    // A mapping of its own is not the Tables'.
    var own: [4096]u8 align(4096) = undefined;
    try std.testing.expect(!unreserveTable(&own, own.len));
}

test "on Linux a Table's range past its first 2 MiB asks for huge pages while 2 MiB blocks are free to spare, and keeps small pages once given back" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    const mib: usize = 1 << 20;
    const t = reserveTable(24 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t)));
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(t) + 2 * mib));
    const small = reserveTable(2 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(small)));
    try std.testing.expect(unreserveTable(t, 24 * mib));
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t) + 2 * mib));
    useBuddyinfoForTest(buddyinfo_partly);
    const u = reserveTable(24 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(u) + 2 * mib));
    try std.testing.expect(unreserveTable(u, 24 * mib));
    try std.testing.expect(unreserveTable(small, 2 * mib));
    try std.testing.expectEqual(@as(usize, 0), table_free_count.*);
}

/// /sys/kernel/mm/transparent_hugepage/`enabled` and `defrag` for the
/// tests, as Linux writes them, each mode in brackets.
const thp_enabled_madvise = "always [madvise] never\n";
const thp_enabled_always = "[always] madvise never\n";
const thp_enabled_never = "always madvise [never]\n";
fn thpDefragForTest(comptime mode: []const u8) []const u8 {
    return comptime text: {
        var text: []const u8 = "";
        for ([_][]const u8{ "always", "defer", "defer+madvise", "madvise", "never" }, 0..) |m, i| {
            text = text ++ (if (i > 0) " " else "") ++ (if (std.mem.eql(u8, m, mode)) "[" ++ m ++ "]" else m);
        }
        break :text text ++ "\n";
    };
}

test "the mode for huge pages is the word in brackets of `enabled` and `defrag`, and files that name none read as `madvise`" {
    const pup = thpModeOf(thp_enabled_madvise, "", thpDefragForTest("madvise"));
    try std.testing.expect(!pup.off and !pup.by_default and pup.advice_stalls);
    const always = thpModeOf(thp_enabled_always, "", thpDefragForTest("madvise"));
    try std.testing.expect(!always.off and always.by_default and always.advice_stalls);
    try std.testing.expect(thpModeOf(thp_enabled_never, "", thpDefragForTest("madvise")).off);
    inline for ([_][]const u8{ "always", "madvise", "defer+madvise" }) |d| try std.testing.expect(thpModeOf(thp_enabled_madvise, "", thpDefragForTest(d)).advice_stalls);
    try std.testing.expect(!thpModeOf(thp_enabled_madvise, "", thpDefragForTest("defer")).advice_stalls);
    try std.testing.expect(!thpModeOf(thp_enabled_madvise, "", thpDefragForTest("never")).advice_stalls);
    // A host with no transparent huge pages, or that hides /sys, has no
    // files to read.
    try std.testing.expectEqual(pup, thpModeOf("", "", ""));
    try std.testing.expectEqual(pup, thpModeOf("[madvise", "", "madvise]"));
    // The mode of 2 MiB pages, where Linux has its file, is its own
    // unless it is `inherit`.
    const inherit = "always [inherit] madvise never\n";
    try std.testing.expectEqual(pup, thpModeOf(thp_enabled_madvise, inherit, thpDefragForTest("madvise")));
    try std.testing.expect(thpModeOf(thp_enabled_madvise, "always inherit madvise [never]\n", thpDefragForTest("madvise")).off);
    try std.testing.expect(thpModeOf(thp_enabled_never, "[always] inherit madvise never\n", thpDefragForTest("madvise")).by_default);
    try std.testing.expectEqual(always, thpModeOf(thp_enabled_always, inherit, thpDefragForTest("madvise")));
    // A mode is never 0, which `thp_mode` keeps for unread.
    try std.testing.expect(@as(u8, @bitCast(thpModeOf(thp_enabled_never, "", thpDefragForTest("never")))) != 0);
}

test "a range asks for huge pages under `madvise`, with the test only where a fault would compact; asks for small ones only under `always`; and asks for nothing under `never`" {
    const huge, const again, const small = .{ Want.huge, Want.huge_again, Want.small };
    // pup's mode: as before the mode was read.
    inline for ([_][]const u8{ "madvise", "defer+madvise", "always" }) |d| {
        const m = thpModeOf(thp_enabled_madvise, "", thpDefragForTest(d));
        try std.testing.expectEqual(Advice.huge_if_free, adviceFor(m, huge));
        try std.testing.expectEqual(Advice.huge_if_free, adviceFor(m, again));
        try std.testing.expectEqual(Advice.nothing, adviceFor(m, small));
    }
    inline for ([_][]const u8{ "defer", "never" }) |d| {
        const m = thpModeOf(thp_enabled_madvise, "", thpDefragForTest(d));
        try std.testing.expectEqual(Advice.huge, adviceFor(m, huge));
        try std.testing.expectEqual(Advice.huge, adviceFor(m, again));
        try std.testing.expectEqual(Advice.nothing, adviceFor(m, small));
    }
    inline for ([_][]const u8{ "madvise", "defer+madvise", "always" }) |d| {
        const m = thpModeOf(thp_enabled_always, "", thpDefragForTest(d));
        try std.testing.expectEqual(Advice.nothing, adviceFor(m, huge));
        try std.testing.expectEqual(Advice.huge_if_free, adviceFor(m, again));
        try std.testing.expectEqual(Advice.small, adviceFor(m, small));
    }
    inline for ([_][]const u8{ "defer", "never" }) |d| {
        const m = thpModeOf(thp_enabled_always, "", thpDefragForTest(d));
        try std.testing.expectEqual(Advice.nothing, adviceFor(m, huge));
        try std.testing.expectEqual(Advice.huge, adviceFor(m, again));
        try std.testing.expectEqual(Advice.small, adviceFor(m, small));
    }
    inline for ([_][]const u8{ "always", "defer", "defer+madvise", "madvise", "never" }) |d| {
        const m = thpModeOf(thp_enabled_never, "", thpDefragForTest(d));
        for ([_]Want{ huge, again, small }) |w| try std.testing.expectEqual(Advice.nothing, adviceFor(m, w));
    }
}

/// A reading of /proc/buddyinfo for the tests from a host of two nodes:
/// node 0 has 10 free 2 MiB blocks outside its `DMA` zone, and node 1
/// 300.
const buddyinfo_two_nodes =
    \\Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2
    \\Node 0, zone    DMA32    211    395    378    717    515    367    336    236    159      3      0
    \\Node 0, zone   Normal 1359150  17930   6222   5728   3186   1669   1392   3119   2467      5      1
    \\Node 1, zone   Normal 364636 108634  62179  57000  38809  19951   4972   7065   2464    200     50
    \\
;

test "free 2 MiB blocks are counted on the asking thread's node only, and on every node where the node is not known or has no memory" {
    try std.testing.expectEqual(@as(usize, 10), freeHugeBlocks(buddyinfo_two_nodes, 0, true));
    try std.testing.expectEqual(@as(usize, 300), freeHugeBlocks(buddyinfo_two_nodes, 1, true));
    try std.testing.expectEqual(@as(usize, 310), freeHugeBlocks(buddyinfo_two_nodes, null, true));
    try std.testing.expectEqual(@as(usize, 310), freeHugeBlocks(buddyinfo_two_nodes, 2, true));
    // A host of one node counts the same, whichever node is asked.
    try std.testing.expectEqual(@as(usize, 319), freeHugeBlocks(buddyinfo_plenty, 0, true));
    try std.testing.expectEqual(@as(usize, 319), freeHugeBlocks(buddyinfo_plenty, 1, true));
    // A reading that may be cut short, with no line of the node asked,
    // counts none, not the other nodes'.
    const cut = buddyinfo_two_nodes[0..std.mem.indexOf(u8, buddyinfo_two_nodes, "Node 1").?];
    try std.testing.expectEqual(@as(usize, 0), freeHugeBlocks(cut, 1, false));
    try std.testing.expectEqual(@as(usize, 10), freeHugeBlocks(cut, 0, false));
    try std.testing.expectEqual(@as(usize, 0), freeHugeBlocks(buddyinfo_two_nodes, 2, false));
    try std.testing.expect(!oneNode(buddyinfo_two_nodes));
    try std.testing.expect(oneNode(buddyinfo_plenty));
    try std.testing.expect(oneNode(""));
    try std.testing.expectEqual(@as(?usize, 1), nodeOf("Node 1, zone   Normal 1 2 3"));
    try std.testing.expectEqual(@as(?usize, null), nodeOf("zone Normal"));
}

test "on Linux a kept reading of a host of two nodes answers only a thread on the node it counted, and one of a host of one node answers any" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_two_nodes);
    defer useBuddyinfoForTest(null);
    clock_for_test.* = 1 << 40;
    defer clock_for_test.* = null;
    const before = buddyinfo_reads.*;
    // Node 0 has 10 free, too few for a Table; node 1 has 300.
    node_for_test.* = 0;
    try std.testing.expect(!hugeFree());
    try std.testing.expect(!hugeFree());
    try std.testing.expectEqual(before + 1, buddyinfo_reads.*);
    node_for_test.* = 1;
    try std.testing.expect(hugeFree());
    try std.testing.expect(hugeFree());
    try std.testing.expectEqual(before + 2, buddyinfo_reads.*);
    // A segment on node 0 needs 2 and 8 more: node 1's reading does not
    // answer it.
    node_for_test.* = 0;
    try std.testing.expect(hugeFreeFor(2));
    try std.testing.expectEqual(@as(?usize, 8), keptReading());
    try std.testing.expectEqual(before + 3, buddyinfo_reads.*);
    useBuddyinfoForTest(buddyinfo_idle);
    node_for_test.* = 0;
    const one = buddyinfo_reads.*;
    try std.testing.expect(hugeFree());
    node_for_test.* = 1;
    try std.testing.expect(hugeFree());
    try std.testing.expectEqual(one + 1, buddyinfo_reads.*);
}

test "on Linux under `never` nothing asks for huge pages and /proc/buddyinfo is not read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    useThpForTest(thp_enabled_never, thpDefragForTest("madvise"));
    const before = buddyinfo_reads.*;
    try std.testing.expect(!hugeFree());
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    try std.testing.expect(!try advisedHugeForTest(p));
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(big)));
    try std.testing.expect(!try advisedSmallForTest(@intFromPtr(big)));
    freeLarge(&h, big, 16 * mib);
    trimAllForTest(&h);
    const t = reserveTable(24 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t) + 2 * mib));
    try std.testing.expect(unreserveTable(t, 24 * mib));
    try std.testing.expectEqual(before, buddyinfo_reads.*);
}

test "on Linux under `madvise` with `defrag` `defer`, where no fault compacts, segments, large blocks, and Tables ask for huge pages with memory fragmented and no reading" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_fragmented);
    defer useBuddyinfoForTest(null);
    useThpForTest(thp_enabled_madvise, thpDefragForTest("defer"));
    const before = buddyinfo_reads.*;
    try std.testing.expect(hugeFree());
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    try std.testing.expect(try advisedHugeForTest(p));
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(big)));
    freeLarge(&h, big, 16 * mib);
    trimAllForTest(&h);
    const t = reserveTable(24 * mib).?;
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(t) + 2 * mib));
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t)));
    try std.testing.expect(unreserveTable(t, 24 * mib));
    try std.testing.expectEqual(before, buddyinfo_reads.*);
}

test "on Linux under `always` nothing asks for huge pages, what should keep small pages asks for them, and a Table given back asks for nothing again" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    useThpForTest(thp_enabled_always, thpDefragForTest("madvise"));
    const before = buddyinfo_reads.*;
    try std.testing.expect(!hugeFree());
    // A segment of a heap that faults in ahead asks for nothing; one of a
    // heap that does not asks for small pages.
    const mine = try allocator.alloc(u8, prefault_big);
    defer allocator.free(mine);
    var busy = testHeap();
    busy.taken = prefault_big;
    const p = busy.newPage().?;
    try std.testing.expect(!try advisedHugeForTest(p));
    try std.testing.expect(!try advisedSmallForTest(p));
    var lone = testHeap();
    const q = lone.newPage().?;
    try std.testing.expect(!faultsAhead(&lone));
    try std.testing.expect(try advisedSmallForTest(q));
    // A block of 16 MiB asks for nothing, one of 8 MiB for small pages.
    var h = testHeap();
    const mib: usize = 1 << 20;
    const big = allocLarge(&h, 16 * mib).?;
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(big)));
    try std.testing.expect(!try advisedSmallForTest(@intFromPtr(big)));
    const small = allocLarge(&h, 8 * mib).?;
    try std.testing.expect(try advisedSmallForTest(@intFromPtr(small)));
    freeLarge(&h, big, 16 * mib);
    freeLarge(&h, small, 8 * mib);
    trimAllForTest(&h);
    try std.testing.expectEqual(before, buddyinfo_reads.*);
    // A Table's first 2 MiB ask for small pages. Given back, its range is
    // mapped afresh: it asks for nothing, and its pages are back with
    // the system, so it reads zeros.
    const t = reserveTable(24 * mib).?;
    try std.testing.expect(try advisedSmallForTest(@intFromPtr(t)));
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t) + 2 * mib));
    @memset(t[0 .. 24 * mib], 7);
    try std.testing.expect(unreserveTable(t, 24 * mib));
    try std.testing.expectEqual(@as(usize, 0), try residentForTest(t, 8 * mib));
    for ([_]usize{ 0, 2 * mib, 23 * mib }) |off| {
        try std.testing.expect(!try advisedSmallForTest(@intFromPtr(t) + off));
        try std.testing.expect(!try advisedHugeForTest(@intFromPtr(t) + off));
    }
    for (t[0 .. 24 * mib]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // The next Table, wherever it is placed, asks the same.
    const v = reserveTable(24 * mib).?;
    try std.testing.expect(try advisedSmallForTest(@intFromPtr(v)));
    try std.testing.expect(!try advisedHugeForTest(@intFromPtr(v) + 2 * mib));
    try std.testing.expect(unreserveTable(v, 24 * mib));
    try std.testing.expectEqual(before, buddyinfo_reads.*);
    // A block of 8 MiB grown to 32 MiB asks again for huge pages, while
    // free blocks are there for them, as only asking undoes its advice.
    trimAllForTest(heap().?);
    const m = try allocator.alloc(u8, 8 * mib);
    try std.testing.expect(try advisedSmallForTest(@intFromPtr(m.ptr)));
    const g = allocator.remap(m, 32 * mib).?;
    try std.testing.expect(try advisedHugeForTest(@intFromPtr(g.ptr)));
    try std.testing.expectEqual(before + 1, buddyinfo_reads.*);
    allocator.free(g);
}

test "on Linux under `always` a Table's range that cannot be mapped afresh is filled with a mapping no access touches, or kept as a hole no Table is taken from, and is never handed out again" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_plenty);
    defer useBuddyinfoForTest(null);
    useThpForTest(thp_enabled_always, thpDefragForTest("madvise"));
    defer table_remap_fails_for_test.* = .no;
    const mib: usize = 1 << 20;
    const live = table_live.load(.monotonic);
    // The mapping afresh fails and leaves a hole, which is filled.
    table_remap_fails_for_test.* = .remap;
    const t = reserveTable(4 * mib).?;
    @memset(t[0 .. 4 * mib], 7);
    const holes = table_hole_count.*;
    try std.testing.expect(unreserveTable(t, 4 * mib));
    try std.testing.expect(!try vmFlagForTest(@intFromPtr(t), "rd"));
    try std.testing.expect(!try vmFlagForTest(@intFromPtr(t) + 4 * mib - 1, "wr"));
    try std.testing.expectEqual(holes, table_hole_count.*);
    // Neither filling it can: the hole is kept, and a mapping the system
    // later puts there is not taken for a Table's.
    table_remap_fails_for_test.* = .and_plug;
    const u = reserveTable(4 * mib).?;
    try std.testing.expect(u != t);
    try std.testing.expect(unreserveTable(u, 4 * mib));
    try std.testing.expectEqual(holes + 1, table_hole_count.*);
    // The hole is empty: a mapping that may not replace another fits.
    const other = try std.posix.mmap(u, 4096, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true }, -1, 0);
    defer std.posix.munmap(other);
    try std.testing.expect(!unreserveTable(other.ptr, other.len));
    // Neither range is handed out again.
    table_remap_fails_for_test.* = .no;
    var got: [4][*]u8 = undefined;
    for (&got) |*g| {
        g.* = reserveTable(4 * mib).?;
        try std.testing.expect(g.* != t and g.* != u);
    }
    try std.testing.expectEqual(live + got.len, table_live.load(.monotonic));
    // What `os.exit` would unmap holds each Table's range, and not the
    // hole, where the system may have mapped anything.
    var buf: [exit_ranges_max]Range = undefined;
    const ex = exitRanges(&buf);
    for (ex.ranges) |r| try std.testing.expect(r.start + r.len <= @intFromPtr(u) or @intFromPtr(u) + 4 * mib <= r.start);
    for (got) |g| {
        var covered = false;
        for (ex.ranges[ex.dense..]) |r| covered = covered or (r.start <= @intFromPtr(g) and @intFromPtr(g) + 4 * mib <= r.start + r.len);
        try std.testing.expect(covered);
    }
    for (got) |g| try std.testing.expect(unreserveTable(g, 4 * mib));
    try std.testing.expectEqual(live, table_live.load(.monotonic));
}

test "on the Mac Tables take ranges of one region, and a range given back reads zeros for the next Table" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const mib: usize = 1 << 20;
    const live = table_live.load(.monotonic);
    const a = reserveTable(6 * mib).?;
    const b = reserveTable(24 * mib).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(a) % huge_page);
    try std.testing.expect(table_region_count.* >= 1);
    try std.testing.expectEqual(live + 2, table_live.load(.monotonic));
    @memset(a[0 .. 6 * mib], 7);
    b[24 * mib - 1] = 9;
    // `a` is not at the region's rest, so its range is kept apart, and
    // the next Table that fits takes it, as zeros.
    try std.testing.expect(unreserveTable(a, 6 * mib));
    const c = reserveTable(5 * mib + 4096).?;
    try std.testing.expectEqual(a, c);
    for (c[0 .. 6 * mib]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Both lie within what `os.exit` would unmap.
    var buf: [exit_ranges_max]Range = undefined;
    const got = exitRanges(&buf);
    var covered: usize = 0;
    for (got.ranges[got.dense..]) |r| {
        if (r.start <= @intFromPtr(c) and @intFromPtr(c) + 6 * mib <= r.start + r.len) covered += 1;
        if (r.start <= @intFromPtr(b) and @intFromPtr(b) + 24 * mib <= r.start + r.len) covered += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), covered);
    try std.testing.expect(unreserveTable(c, 5 * mib + 4096));
    try std.testing.expect(unreserveTable(b, 24 * mib));
    try std.testing.expectEqual(live, table_live.load(.monotonic));
    var own: [4096]u8 align(4096) = undefined;
    try std.testing.expect(!unreserveTable(&own, own.len));
}

/// The bytes of the `len` at `p` resident in memory (`mincore`).
fn residentForTest(p: [*]u8, len: usize) !usize {
    const pages = len / std.heap.pageSize();
    var vec: [4096]u8 = undefined;
    if (pages > vec.len) return error.TooLong;
    const rc: isize = @bitCast(std.os.linux.syscall3(.mincore, @intFromPtr(p), len, @intFromPtr(&vec)));
    if (rc < 0) return error.NoMincore;
    var n: usize = 0;
    for (vec[0..pages]) |v| n += v & 1;
    return n * std.heap.pageSize();
}

/// Whether the mapping that holds `p` asks for huge pages: its `VmFlags`
/// in /proc/self/smaps name `hg`.
fn advisedHugeForTest(p: usize) !bool {
    return vmFlagForTest(p, "hg");
}

/// Whether the mapping that holds `p` asks for small pages: its
/// `VmFlags` name `nh`.
fn advisedSmallForTest(p: usize) !bool {
    return vmFlagForTest(p, "nh");
}

/// Whether the `VmFlags` of the mapping that holds `p`, in
/// /proc/self/smaps, name `flag`.
fn vmFlagForTest(p: usize, flag: []const u8) !bool {
    // A file of /proc reads as empty to a reader that trusts its size,
    // so it is read to its end here.
    const linux = std.os.linux;
    const fd: i32 = @intCast(@as(isize, @bitCast(linux.open("/proc/self/smaps", .{}, 0))));
    if (fd < 0) return error.NoSmaps;
    defer _ = linux.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    while (true) {
        try buf.ensureUnusedCapacity(std.testing.allocator, 64 << 10);
        const n: isize = @bitCast(linux.read(fd, buf.unusedCapacitySlice().ptr, buf.unusedCapacitySlice().len));
        if (n < 0) return error.NoSmaps;
        if (n == 0) break;
        buf.items.len += @intCast(n);
    }
    const smaps = buf.items;
    var lines = std.mem.splitScalar(u8, smaps, '\n');
    var inside = false;
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '-')) |dash| if (std.mem.indexOfScalar(u8, line, ' ')) |sp| if (dash < sp) {
            const lo = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
            const hi = std.fmt.parseInt(usize, line[dash + 1 .. sp], 16) catch continue;
            inside = lo <= p and p < hi;
            continue;
        };
        if (inside and std.mem.startsWith(u8, line, "VmFlags:")) {
            var flags = std.mem.tokenizeScalar(u8, line["VmFlags:".len..], ' ');
            while (flags.next()) |f| if (std.mem.eql(u8, f, flag)) return true;
            return false;
        }
    }
    return error.NoMapping;
}

/// Give back every block `h` keeps.
fn trimAllForTest(h: *Heap) void {
    for ([_]*Kept{ &h.kept, &h.cold }) |k| while (lastHeld(k)) |j| {
        const f = unkeep(k, j, 0).?;
        unmapLarge(@intFromPtr(f), f.len);
    };
}

/// A run of 80,000 bytes in the test binary's read-only image, each its
/// index times 7.
const mapped_blob: [80_000]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var b: [80_000]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = @truncate(i *% 7);
    break :blk b;
};

test "on Linux and macOS a run of the executable maps privately: it reads the run's bytes, its writes are its own, and freeing it unmaps it" {
    if (!maps_files) return error.SkipZigTest;
    // Zig's own backend (a debug build) places the constant in writable
    // data, which `mapRun` copies, as it should; a debug build never maps.
    if (builtin.zig_backend != .stage2_llvm) return error.SkipZigTest;
    const run: []const u8 = mapped_blob[13..];
    const p = mapRun(run) orelse return error.TestUnexpectedResult;
    // The run's address within its page, so its alignment, is kept.
    try std.testing.expectEqual(@intFromPtr(run.ptr) % std.heap.pageSize(), @intFromPtr(p) % std.heap.pageSize());
    try std.testing.expectEqualSlices(u8, run, p[0..run.len]);
    try std.testing.expect(isMapped(p) and isMapped(p + run.len - 1));
    // A second mapping of the same run is apart from the first.
    const q = mapRun(run) orelse return error.TestUnexpectedResult;
    p[100] = 0xee;
    try std.testing.expectEqual(@as(u8, @truncate(113 *% 7)), q[100]);
    try std.testing.expectEqual(@as(u8, @truncate(113 *% 7)), mapped_blob[113]);
    // Growing it is the caller's copy; freeing it gives the pages back.
    try std.testing.expect(remap(undefined, p[0..run.len], .@"1", run.len * 2, 0) == null);
    free(undefined, p[0..run.len], .@"1", 0);
    try std.testing.expect(!isMapped(p));
    free(undefined, q[0..run.len], .@"1", 0);
    try std.testing.expectEqual(@as(usize, 0), mapped_count.load(.monotonic));
    // A run outside the image, or too short, is copied.
    var heap_run: [map_min]u8 = undefined;
    try std.testing.expect(mapRun(&heap_run) == null);
    try std.testing.expect(mapRun(mapped_blob[0 .. map_min - 1]) == null);
}

test "every large size is its bucket's size" {
    var pages: usize = 1;
    while (pages < 1 << 16) : (pages += 1) {
        const len = pages * std.heap.pageSize();
        if (len <= max_small) continue;
        const size = largeSize(len);
        try std.testing.expect(size >= len);
        // The bucket a block of `size` falls in holds only blocks of
        // `size` or more, so a request takes any block of it.
        const k = largeBucket(size);
        try std.testing.expect(k == 0 or largeBucket(size - 1) < k);
    }
}
