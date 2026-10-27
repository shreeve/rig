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
//! not map and unmap memory each time. It keeps them while what it holds
//! in large blocks, handed out and kept, is no more than its settled
//! peak, the most it has had handed out just after a free, and
//! `keep_large` more (`keepBound`). So a growth's moment, the old block
//! and the new one handed out together, does not raise what it may keep,
//! and a table that grows does not leave the block it grew from
//! resident. Segments are never returned to the system: memory freed
//! stays for reuse. On Linux,
//! a heap that does much of the program's work, one that has taken from
//! the system most of what every heap has or more than one segment's
//! worth, faults in at once the memory it is about to fill (`prefault`),
//! and a new large block of 16 MiB or more asks for huge pages
//! (`huge_large`).
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
    /// Large blocks freed and kept for the next (`keepLarge`), by bucket
    /// (four per doubling of pages, each block at least its bucket's
    /// size); which buckets hold any, a bit each; and how many bytes
    /// they hold.
    large: [large_buckets]?*LargeFree = @splat(null),
    large_held: [large_words]u64 = @splat(0),
    large_bytes: usize = 0,
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
        const seg: *Segment = @ptrFromInt(@intFromPtr(p) & ~(segment_size - 1));
        const b: *Block = @ptrCast(@alignCast(p));
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

/// A large block at least this long grows by moving its pages
/// (`mremap`, Linux), not by copying them into new ones, which the
/// system would fault in afresh.
const move_large: usize = 1 << 20;

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
    if (takeKept(h, size)) |p| {
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
/// where it is set to do so for a range that asks (`madvise` mode). A
/// system that cannot leaves them as they are.
fn adviseHuge(p: usize, len: usize) void {
    if (builtin.os.tag != .linux) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p);
    std.posix.madvise(at, len, std.os.linux.MADV.HUGEPAGE) catch {};
}

/// `size` more bytes of large blocks handed out. The settled peak is
/// raised by a free (`freeLarge`), not here, so a block handed out
/// before the one it replaces is freed does not count twice.
fn lent(h: *Heap, size: usize) void {
    h.large_live += size;
}

/// A kept block for `size` bytes, best fit by bucket: the first of the
/// lowest bucket from `size`'s that holds one at least `size` long. What
/// it holds past `size` is kept on its own.
fn takeKept(h: *Heap, size: usize) ?[*]u8 {
    var j = nextHeld(h, largeBucket(size));
    while (j) |b| : (j = nextHeld(h, b + 1)) {
        const f = unkeep(h, b, size) orelse continue;
        const p = @intFromPtr(f);
        const len = f.len;
        if (len > size) keepPiece(h, p + size, len - size);
        return @ptrFromInt(p);
    }
    return null;
}

/// Take from bucket `j` its first kept block at least `len` long.
fn unkeep(h: *Heap, j: usize, len: usize) ?*LargeFree {
    var at = &h.large[j];
    while (at.*) |f| : (at = &f.next) {
        if (f.len < len) continue;
        at.* = f.next;
        if (h.large[j] == null) h.large_held[j / 64] &= ~(@as(u64, 1) << @intCast(j % 64));
        h.large_bytes -= f.len;
        return f;
    }
    return null;
}

/// The lowest bucket from `k` that holds a kept block, or null.
fn nextHeld(h: *const Heap, k: usize) ?usize {
    var w = k / 64;
    if (w >= large_words) return null;
    var bits = h.large_held[w] & (~@as(u64, 0) << @intCast(k % 64));
    while (true) {
        if (bits != 0) return w * 64 + @ctz(bits);
        w += 1;
        if (w >= large_words) return null;
        bits = h.large_held[w];
    }
}

/// The highest bucket that holds a kept block, or null.
fn lastHeld(h: *const Heap) ?usize {
    var w: usize = large_words;
    while (w > 0) {
        w -= 1;
        const bits = h.large_held[w];
        if (bits != 0) return w * 64 + 63 - @clz(bits);
    }
    return null;
}

/// Keep the `len` bytes at `p`, or give them back to the system if no
/// large request could take them.
fn keepPiece(h: *Heap, p: usize, len: usize) void {
    if (len < minLarge()) return unmapLarge(p, len);
    const f: *LargeFree = @ptrFromInt(p);
    const k = largeBucket(len);
    f.* = .{ .next = h.large[k], .len = len };
    h.large[k] = f;
    h.large_held[k / 64] |= @as(u64, 1) << @intCast(k % 64);
    h.large_bytes += len;
}

/// Give kept blocks back to the system until the heap keeps no more
/// than `keepBound`, after it has taken new pages for a block no kept
/// one fitted: the smallest block that alone brings it within the
/// bound, or else the largest, and again. So the heap keeps its largest
/// blocks, a program's tables built again, which cost the most pages
/// to fault in afresh.
fn trimKept(h: *Heap) void {
    while (h.large_bytes > keepBound(h)) {
        const over = h.large_bytes - keepBound(h);
        var j = nextHeld(h, largeBucket(over));
        const f = while (j) |b| : (j = nextHeld(h, b + 1)) {
            if (unkeep(h, b, over)) |f| break f;
        } else unkeep(h, lastHeld(h) orelse return, 0).?;
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
    if (h.large_bytes + size > keepBound(h)) return unmapLarge(@intFromPtr(p), size);
    keepPiece(h, @intFromPtr(p), size);
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
        const seg: *const Segment = @ptrFromInt(@intFromPtr(memory.ptr) & ~(segment_size - 1));
        if (seg.heap == h) {
            if (builtin.is_test) mustOwn(h);
            const b: *Block = @ptrCast(@alignCast(memory.ptr));
            b.next = h.free[c];
            h.free[c] = b;
            if (counts) h.count(-@as(isize, @intCast(classSize(c))), 0);
            return;
        }
    };
    freeSlow(memory, alignment);
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

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ret)) return memory.ptr;
    if (builtin.os.tag != .linux) return null;
    if (classOf(memory.len, alignment) != null or classOf(new_len, alignment) != null) return null;
    if (memory.len < move_large or new_len < memory.len) return null;
    const h = heap() orelse return null;
    const old_size = largeSize(memory.len);
    const new_size = largeSize(new_len);
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
    try std.testing.expect(h.large_bytes + h.large_live <= h.large_peak + keep_large);
    // A block larger than any kept takes new pages, past the settled
    // peak, and gives back kept ones past the bound: no more than
    // `keep_large` stay.
    const huge = allocLarge(&h, 64 * mib).?;
    try std.testing.expect(h.large_bytes <= keepBound(&h));
    try std.testing.expect(h.large_bytes <= keep_large);
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
        try std.testing.expect(h.large_bytes <= keep_large);
    }
    // Dropped, the last block is kept: it is what the heap held at its
    // settled peak.
    freeLarge(&h, p, len);
    try std.testing.expect(h.large_bytes + h.large_live <= h.large_peak + keep_large);
    try std.testing.expect(h.large_bytes > keep_large);
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

test "on Linux a new block of 16 MiB or more, and one grown to it, is aligned for huge pages and asks for them, and a smaller one does not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
    while (lastHeld(h)) |j| {
        const f = unkeep(h, j, 0).?;
        unmapLarge(@intFromPtr(f), f.len);
    }
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
