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
//! system has free 2 MiB blocks for it and a few more (`hugeFreeFor`).
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
var taken_all: std.atomic.Value(usize) = .init(0);

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
        if (builtin.os.tag == .linux and faultsAhead(h)) adviseHuge(@intFromPtr(s), segment_size);
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
    if (size >= huge_large) adviseHuge(got, size);
    h.took(size);
    lent(h, size);
    trimKept(h);
    prefault(h, got, likelyFilled(size - size / 4));
    return @ptrFromInt(got);
}

/// A new large block of at least this many bytes is mapped, on Linux,
/// aligned to `huge_page` and advised for transparent huge pages
/// (`adviseHuge`), and so is a block grown to it by `mremap`: its pages
/// fault in 2 MiB at a time, a trap and a TLB entry each. Smaller blocks,
/// and blocks taken from those kept, stay as they are: huge pages for
/// every new block of 2 MiB or more raise Trig's peak memory, and from
/// 16 MiB they do not (docs/history/records/2026-10/alloc-thp16/).
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

/// Ask Linux to back the `len` bytes at `p` with transparent huge pages,
/// where it is set to do so for a range that asks (`madvise` mode), while
/// it has free 2 MiB blocks for them and `huge_floor` more
/// (`hugeFreeFor`). A new segment and a new large block ask just before
/// their pages fault, as they are faulted in ahead (`prefault`), so the
/// count is current when they need the blocks. A system that cannot
/// leaves them as they are.
fn adviseHuge(p: usize, len: usize) void {
    if (builtin.os.tag != .linux) return;
    if (!hugeFreeFor((len + huge_page - 1) / huge_page)) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p);
    std.posix.madvise(at, len, std.os.linux.MADV.HUGEPAGE) catch {};
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
pub fn hugeFree() bool {
    if (builtin.os.tag != .linux) return false;
    return (keptReading() orelse readNow()) > huge_spare;
}

/// Whether Linux has free blocks of 2 MiB or more for `need` huge pages
/// and `huge_floor` more: the test a new segment or large block makes
/// before it asks (`adviseHuge`). Its blocks are taken moments later, as
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

/// The reading kept: the monotonic clock in units of 2^16 ns (about 65
/// microseconds) in the top 40 bits, which last 2^56 ns, two years; its
/// free blocks, at most `count_max`, in the low 24; or 0, none. One
/// word, so a thread never pairs one reading's time with another's count.
var kept_reading: std.atomic.Value(u64) = .init(0);
const count_bits = 24;
const count_max: u64 = (1 << count_bits) - 1;

/// The monotonic clock in units of 2^16 ns, through the vDSO: tens of
/// nanoseconds, where a reading costs microseconds. 0 if it fails.
fn clockUnits() u64 {
    if (comptime builtin.is_test) if (clock_for_test) |ns| return ns >> 16;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const ns = @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
    return ns >> 16;
}

/// The free blocks of the reading kept, if it was taken in the last
/// `reading_life_ns`.
fn keptReading() ?usize {
    const k = kept_reading.load(.monotonic);
    if (k == 0) return null;
    const now = clockUnits();
    if (now == 0 or now -% (k >> count_bits) >= reading_life_ns >> 16) return null;
    return @intCast(k & count_max);
}

/// Read /proc/buddyinfo, keep the reading, and give its free blocks.
fn readNow() usize {
    const blocks = freeHugeNow();
    const now = clockUnits();
    if (now != 0) kept_reading.store(now << count_bits | @min(blocks, count_max), .monotonic);
    return blocks;
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

/// The free blocks of 2 MiB or more Linux has now (`/proc/buddyinfo`),
/// read once for each new segment, new large block of `huge_large`, and
/// burst of reserved Tables (`keptReading`). A file that cannot be read
/// counts none, so nothing asks.
noinline fn freeHugeNow() usize {
    @branchHint(.cold);
    if (builtin.os.tag != .linux) return 0;
    if (comptime builtin.is_test) {
        buddyinfo_reads += 1;
        if (buddyinfo_for_test) |text| return freeHugeBlocks(text);
    }
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, "/proc/buddyinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return 0;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    // A line per zone of each node, about 100 bytes: a host of 10 nodes
    // fits. A reading cut short counts fewer blocks, never more.
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const r: isize = @bitCast(linux.read(fd, buf[len..].ptr, buf.len - len));
        if (r < 0) return 0;
        if (r == 0) break;
        len += @intCast(r);
    }
    return freeHugeBlocks(buf[0..len]);
}

/// What a test reads in place of /proc/buddyinfo, the readings it has
/// made, and the clock it sees, in nanoseconds.
var buddyinfo_for_test: ?[]const u8 = null;
var buddyinfo_reads: usize = 0;
var clock_for_test: ?u64 = null;

/// Read `text` in place of /proc/buddyinfo from now, with no reading kept.
fn useBuddyinfoForTest(text: ?[]const u8) void {
    buddyinfo_for_test = text;
    kept_reading.store(0, .monotonic);
}

/// The free blocks of 2 MiB in a reading of /proc/buddyinfo: each line
/// is `Node N, zone NAME` and a count of free blocks for each order from
/// 0 (4 KiB); a block of order 9 is 2 MiB and one of order 9 + k holds
/// 2^k of them. The `DMA` zone's are left out, as no user page is taken
/// from it.
fn freeHugeBlocks(text: []const u8) usize {
    var blocks: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        // The four words before the counts.
        var order: isize = -4;
        while (words.next()) |w| : (order += 1) {
            if (order == -1 and std.mem.eql(u8, w, "DMA")) break;
            if (order < 9) continue;
            const c = std.fmt.parseUnsigned(usize, w, 10) catch break;
            blocks +|= std.math.shlExact(usize, c, @intCast(order - 9)) catch std.math.maxInt(usize);
        }
    }
    return blocks;
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
var region_next: std.atomic.Value(usize) = .init(0);
var region_end: usize = 0;
var region_lock: std.atomic.Value(bool) = .init(false);

fn mapSegment() ?*Segment {
    if (region_next.load(.acquire) == 0) reserveRegion();
    var at = region_next.load(.monotonic);
    while (at != 0 and at + segment_size <= region_end) {
        at = region_next.cmpxchgWeak(at, at + segment_size, .monotonic, .monotonic) orelse return @ptrFromInt(at);
    }
    return mapOwnSegment();
}

fn reserveRegion() void {
    @branchHint(.cold);
    while (region_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer region_lock.store(false, .release);
    if (region_next.load(.monotonic) != 0) return;
    const raw = std.posix.mmap(null, region_size + segment_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
        // No room for it: each segment is mapped on its own.
        region_end = 0;
        region_next.store(1, .release);
        return;
    };
    const start = std.mem.alignForward(usize, @intFromPtr(raw.ptr), segment_size);
    region_end = start + region_size;
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

/// The address space reserved Tables (`table.zig`) are handed on Linux:
/// regions of `table_region_size`, each mapped once, with no memory
/// committed (`MAP_NORESERVE`), and advised for small pages once. A Table
/// takes a range of whole huge pages from one (`reserveTable`), which
/// makes no system call while memory has no free 2 MiB blocks to spare,
/// and one `madvise` while it does; a Table dropped gives its pages back
/// to the system with `MADV_DONTNEED`, which leaves the range reading as
/// zeros, and its range to the next Table (`unreserveTable`). Trig's
/// checkers reserve 43 Tables each, 24 MiB to 4 GiB, 53 GiB in all, and
/// a mapping, its advice, and its unmapping for each cost about 8
/// microseconds of system calls. Only release builds take Tables from
/// here: a debug build maps each on its own, so a Table used after it is
/// dropped faults and the leak checker sees each.
const table_region_size: usize = 256 << 30;
/// The regions there may be, 8 TiB in all; a Table that finds none with
/// room, or is larger than a region, is mapped on its own.
const table_regions_max = 32;
/// The free ranges kept between Tables. A range that would be one more
/// is given up: its pages are back with the system, and only its
/// addresses go unused.
const table_free_max = 128;

const Range = struct { start: usize, len: usize };

var tables_lock: std.atomic.Value(bool) = .init(false);
/// The regions, in the order they were mapped; the newest is handed out
/// from `table_next` to `table_end`.
var table_regions: [table_regions_max]Range = undefined;
var table_region_count: usize = 0;
var table_next: usize = 0;
var table_end: usize = 0;
/// No region could be mapped (`ulimit -v`, strict overcommit): each
/// Table is mapped on its own from then on.
var tables_unmapped: bool = false;
/// The ranges given back, by address, none touching another.
var table_free: [table_free_max]Range = undefined;
var table_free_count: usize = 0;
/// Whether any range has asked for huge pages, so a range given back is
/// advised for small pages again before the next Table takes it.
var tables_asked_huge: std.atomic.Value(bool) = .init(false);

fn lockTables() void {
    while (tables_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockTables() void {
    tables_lock.store(false, .release);
}

/// A range of at least `bytes`, from a 2 MiB boundary, for a reserved
/// Table: zeros, none committed. Its first 2 MiB keep small pages, and
/// the rest asks for huge pages while the system has free 2 MiB blocks
/// to spare (`hugeFree`), as `table.zig`'s `reserve` describes. Null
/// where Tables are not taken from here: off Linux, a Table larger than
/// a region, or no region to be had.
pub fn reserveTable(bytes: usize) ?[*]align(huge_page) u8 {
    if (builtin.os.tag != .linux) return null;
    const len = std.mem.alignForward(usize, bytes, huge_page);
    if (len > table_region_size) return null;
    const huge = len > huge_page and hugeFree();
    lockTables();
    const p = takeTableRange(len);
    unlockTables();
    if (huge) if (p) |at| {
        tables_asked_huge.store(true, .monotonic);
        std.posix.madvise(@ptrFromInt(at + huge_page), bytes - huge_page, std.os.linux.MADV.HUGEPAGE) catch {};
    };
    return @ptrFromInt(p orelse return null);
}

/// Give back the range of a Table of `bytes` at `p`, if it is one
/// `reserveTable` handed out: its pages to the system, and the range,
/// advised for small pages again, to the next Table.
pub fn unreserveTable(p: [*]u8, bytes: usize) bool {
    if (builtin.os.tag != .linux) return false;
    const at = @intFromPtr(p);
    const len = std.mem.alignForward(usize, bytes, huge_page);
    lockTables();
    var mine = false;
    for (table_regions[0..table_region_count]) |r| mine = mine or (r.start <= at and at < r.start + r.len);
    unlockTables();
    if (!mine) return false;
    const range: [*]align(huge_page) u8 = @alignCast(p);
    std.posix.madvise(range, len, std.os.linux.MADV.DONTNEED) catch {};
    if (len > huge_page and tables_asked_huge.load(.monotonic)) std.posix.madvise(range, len, std.os.linux.MADV.NOHUGEPAGE) catch {};
    lockTables();
    giveTableRange(at, len);
    unlockTables();
    return true;
}

/// `len` bytes of the Tables' address space: the smallest free range
/// that holds them, else the newest region's rest, else a new region.
/// Under `tables_lock`.
fn takeTableRange(len: usize) ?usize {
    var best: ?usize = null;
    for (table_free[0..table_free_count], 0..) |r, i| {
        if (r.len >= len and (best == null or r.len < table_free[best.?].len)) best = i;
    }
    if (best) |i| {
        const r = &table_free[i];
        const p = r.start;
        r.start += len;
        r.len -= len;
        if (r.len == 0) {
            std.mem.copyForwards(Range, table_free[i .. table_free_count - 1], table_free[i + 1 .. table_free_count]);
            table_free_count -= 1;
        }
        return p;
    }
    if (table_end - table_next < len and !newTableRegion()) return null;
    const p = table_next;
    table_next += len;
    return p;
}

/// Map a new region, advised for small pages, and give the newest one's
/// rest to the free ranges. Under `tables_lock`.
fn newTableRegion() bool {
    @branchHint(.cold);
    if (tables_unmapped or table_region_count == table_regions_max) return false;
    const raw = std.posix.mmap(null, table_region_size + huge_page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
        tables_unmapped = true;
        return false;
    };
    std.posix.madvise(raw.ptr, raw.len, std.os.linux.MADV.NOHUGEPAGE) catch {};
    const start = std.mem.alignForward(usize, @intFromPtr(raw.ptr), huge_page);
    if (table_end > table_next) giveTableRange(table_next, table_end - table_next);
    table_regions[table_region_count] = .{ .start = start, .len = table_region_size };
    table_region_count += 1;
    table_next = start;
    table_end = start + table_region_size;
    return true;
}

/// Put `len` bytes at `p` back: onto the newest region's rest when they
/// end there, else among the free ranges, joined to those they touch.
/// Under `tables_lock`.
fn giveTableRange(p: usize, len: usize) void {
    if (p + len == table_next) {
        table_next = p;
        // A free range that now ends at the rest joins it.
        for (table_free[0..table_free_count], 0..) |r, i| if (r.start + r.len == p) {
            table_next = r.start;
            std.mem.copyForwards(Range, table_free[i .. table_free_count - 1], table_free[i + 1 .. table_free_count]);
            table_free_count -= 1;
            break;
        };
        return;
    }
    // The first free range after `p`.
    var i: usize = 0;
    while (i < table_free_count and table_free[i].start < p) i += 1;
    const joins_before = i > 0 and table_free[i - 1].start + table_free[i - 1].len == p;
    const joins_after = i < table_free_count and p + len == table_free[i].start;
    if (joins_before and joins_after) {
        table_free[i - 1].len += len + table_free[i].len;
        std.mem.copyForwards(Range, table_free[i .. table_free_count - 1], table_free[i + 1 .. table_free_count]);
        table_free_count -= 1;
    } else if (joins_before) {
        table_free[i - 1].len += len;
    } else if (joins_after) {
        table_free[i].start = p;
        table_free[i].len += len;
    } else if (table_free_count < table_free_max) {
        std.mem.copyBackwards(Range, table_free[i + 1 .. table_free_count + 1], table_free[i..table_free_count]);
        table_free[i] = .{ .start = p, .len = len };
        table_free_count += 1;
    }
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
var total_live: std.atomic.Value(isize) align(128) = .init(0);
var total_peak: std.atomic.Value(isize) align(128) = .init(0);
var total_allocs: std.atomic.Value(u64) align(128) = .init(0);
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

threadlocal var my_heap: ?*Heap = null;

/// Whether each heap checks that the thread using it owns it: in safe
/// builds.
const check_owner = std.debug.runtime_safety;

/// One byte per thread, whose address names the thread (`threadToken`).
threadlocal var my_token: u8 = 0;

/// The running thread, as the address of its own `my_token`. A fiber
/// may resume on another thread after any switch, and a compiler may
/// reuse a thread-local's address within a function, so every read goes
/// through a call that is never inlined, as `sched.me` does.
noinline fn threadToken() usize {
    return @intFromPtr(&my_token);
}

/// In a safe build, panic unless the running thread owns `h`: a heap
/// has no lock, so only its own thread may take from it or give to it.
inline fn mustOwn(h: *const Heap) void {
    if (check_owner and h.owner != threadToken()) owner_lost();
}

/// What `mustOwn` does with a heap another thread owns; a test sets it
/// to count instead.
pub var owner_lost: *const fn () void = ownerLost;

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
var spare_heaps: std.atomic.Value(?*Heap) = .init(null);
var spare_lock: std.atomic.Value(bool) = .init(false);

/// The running thread's heap, made as it first allocates. Never
/// inlined: a fiber may resume on another thread after any switch, and
/// a compiler may reuse a thread-local's address within a function, so
/// a caller that allocated before a switch would go on with the heap of
/// the thread it left (`sched.me`). The fast paths, `alloc` and `free`,
/// read `my_heap` themselves for the same reason never inlined.
noinline fn heap() ?*Heap {
    if (my_heap) |h| return h;
    return newHeap();
}

fn newHeap() ?*Heap {
    @branchHint(.cold);
    // A heap a thread that ended gave back, with what it holds.
    while (spare_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    const spare = spare_heaps.load(.monotonic);
    if (spare) |s| spare_heaps.store(s.next_free, .monotonic);
    spare_lock.store(false, .release);
    if (spare) |s| {
        s.next_free = null;
        if (check_owner) s.owner = threadToken();
        my_heap = s;
        return s;
    }
    const bytes = std.posix.mmap(null, std.mem.alignForward(usize, @sizeOf(Heap), std.heap.pageSize()), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    const h: *Heap = @ptrCast(@alignCast(bytes.ptr));
    h.* = .{};
    if (check_owner) h.owner = threadToken();
    my_heap = h;
    return h;
}

/// The running thread ends: give its heap back for the next thread, so
/// what it holds, and the blocks other threads free into it, are used
/// again.
pub noinline fn threadExit() void {
    const h = my_heap orelse return;
    if (counts) h.flush();
    my_heap = null;
    while (spare_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    h.next_free = spare_heaps.load(.monotonic);
    spare_heaps.store(h, .monotonic);
    spare_lock.store(false, .release);
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
    if (fastClass(len, alignment)) |c| if (my_heap) |h| if (h.free[c]) |b| {
        if (builtin.is_test) mustOwn(h);
        h.free[c] = b.next;
        if (counts) h.count(@intCast(classSize(c)), 1);
        return @ptrCast(b);
    };
    return allocSlow(len, alignment);
}

/// Give back `memory`, a block `alloc` made with `alignment`.
noinline fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    if (fastClass(memory.len, alignment)) |c| if (my_heap) |h| {
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
// layout proves them.
const proven_checks = builtin.mode == .debug;

/// The segment that holds `p`, a small block: segments are aligned to
/// `segment_size`, and a block is never in a segment's first page (its
/// header's), so the address is the segment's and is not zero.
inline fn segmentOf(p: [*]u8) *Segment {
    if (builtin.mode == .debug) std.debug.assert(@intFromPtr(p) & (segment_size - 1) >= page_size);
    // A block lies past its segment's header, so the segment is not null.
    @setRuntimeSafety(proven_checks);
    return @ptrFromInt(@intFromPtr(p) & ~(segment_size - 1));
}

/// `p`, a small block, as a free-list entry: carved at a multiple of its
/// class's size, every one a multiple of 8, from a page, so aligned for
/// a `Block`.
inline fn blockOf(p: [*]u8) *Block {
    if (builtin.mode == .debug) std.debug.assert(@intFromPtr(p) % @alignOf(Block) == 0);
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

/// A large block grown to `new_len`: copied into a kept block that fits,
/// which then keeps the old one in turn, since a kept block's pages are
/// resident and copying into them costs less than faulting in fresh
/// ones; else, on Linux and from `move_large`, grown by moving its pages
/// (`mremap`). Anything else, or a block that shrinks, is left to the
/// caller, which copies it into a new block.
fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
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
    if (to != 0) adviseHuge(rc, new_size);
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
    try std.testing.expectEqual(@as(usize, 3 + 300 + 16), freeHugeBlocks(buddyinfo_plenty));
    try std.testing.expectEqual(@as(usize, 2), freeHugeBlocks(buddyinfo_fragmented));
    try std.testing.expectEqual(@as(usize, 0), freeHugeBlocks(""));
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
    try std.testing.expectEqual(@as(usize, 100), freeHugeBlocks(buddyinfo_idle));
    try std.testing.expectEqual(@as(usize, 55), freeHugeBlocks(buddyinfo_partly));
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
    try std.testing.expectEqual(@as(usize, 17), freeHugeBlocks(buddyinfo_low));
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
    useBuddyinfoForTest(buddyinfo_idle);
    defer useBuddyinfoForTest(null);
    clock_for_test = 1 << 40;
    defer clock_for_test = null;
    const before = buddyinfo_reads;
    for (0..43) |_| try std.testing.expect(hugeFree());
    try std.testing.expectEqual(before + 1, buddyinfo_reads);
    // Memory fragments: the reading kept answers until its life is over.
    buddyinfo_for_test = buddyinfo_partly;
    clock_for_test.? += reading_life_ns - (1 << 17);
    try std.testing.expect(hugeFree());
    try std.testing.expectEqual(before + 1, buddyinfo_reads);
    clock_for_test.? += 1 << 17;
    try std.testing.expect(!hugeFree());
    try std.testing.expectEqual(before + 2, buddyinfo_reads);
}

test "on Linux a kept reading may tell a new segment no, but a yes is read again and takes the segment's blocks from the reading kept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    useBuddyinfoForTest(buddyinfo_low);
    defer useBuddyinfoForTest(null);
    clock_for_test = 1 << 40;
    defer clock_for_test = null;
    const before = buddyinfo_reads;
    // 17 free: a Table's reading is kept, then too few for 10 blocks and
    // 8 more answers with no new reading.
    try std.testing.expect(!hugeFree());
    try std.testing.expect(!hugeFreeFor(10));
    try std.testing.expectEqual(before + 1, buddyinfo_reads);
    // Enough for 2 and 8 more: read again, and the 2 are taken from it.
    try std.testing.expect(hugeFreeFor(2));
    try std.testing.expectEqual(before + 2, buddyinfo_reads);
    try std.testing.expectEqual(@as(?usize, 15), keptReading());
    try std.testing.expect(hugeFreeFor(7));
    try std.testing.expectEqual(@as(?usize, 10), keptReading());
    // The reading kept now says 10: too few for 3 and 8 more.
    try std.testing.expect(!hugeFreeFor(3));
    try std.testing.expectEqual(before + 3, buddyinfo_reads);
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
    clock_for_test = 1 << 40;
    defer clock_for_test = null;
    const reads = buddyinfo_reads;
    const next = table_next;
    var got: [43][*]u8 = undefined;
    for (&got, 0..) |*g, i| {
        g.* = reserveTable((i + 1) * (3 << 20) + 4096).?;
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(g.*) % huge_page);
    }
    try std.testing.expectEqual(reads + 1, buddyinfo_reads);
    try std.testing.expect(table_region_count >= 1);
    // Given back in another order than taken, they join one another and
    // then the region's rest.
    for (got, 0..) |g, i| if (i % 2 == 1) try std.testing.expect(unreserveTable(g, (i + 1) * (3 << 20) + 4096));
    try std.testing.expect(table_free_count > 0);
    for (got, 0..) |g, i| if (i % 2 == 0) try std.testing.expect(unreserveTable(g, (i + 1) * (3 << 20) + 4096));
    try std.testing.expectEqual(@as(usize, 0), table_free_count);
    if (next != 0) try std.testing.expectEqual(next, table_next);
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
    try std.testing.expectEqual(@as(usize, 0), table_free_count);
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
    try std.testing.expectEqual(@as(usize, 0), table_free_count);
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
            while (flags.next()) |f| if (std.mem.eql(u8, f, "hg")) return true;
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
