//! `Table[T, n]` and `Slot[n]` (SPEC §10, "Table"; docs/CORE.md §10,
//! "Tables"): a table holds `n` slots from the moment it is made, each
//! `T()` until written, and a `Slot[n]` is a number below `n`, so any
//! slot names a slot of any table of `n` and is read with no test.
//!
//! How the slots are held is the element's (`sema.tableFill`, mirrored
//! here by `fillsWithZeros`, as `needsDrop` mirrors `typeHasDropGlue`):
//!
//! - **Reserved.** `T` is plain data whose default is all zero bytes:
//!   `n * @sizeOf(T)` bytes of private anonymous address space, mapped
//!   with `MAP_NORESERVE`: in a release build on Linux and the Mac a
//!   range of the allocator's address space for tables (`alloc.zig`,
//!   `reserveTable`), elsewhere a mapping of its own. On Linux its first 2 MiB keep small
//!   pages and the rest asks for huge ones while the system has free
//!   2 MiB blocks to spare (`reserve`). The system gives each page as
//!   zeros when it is first touched, so a slot never written costs no
//!   memory, but for a table's first 64 KiB, which on Linux are faulted
//!   in for writing as it is made (`readyHead`). It is never one of `alloc.zig`'s blocks, which are reused
//!   unzeroed and faulted in ahead.
//! - **Made.** Any other `T`: `n` slots on the heap, each `T()`, dropped
//!   all `n` when the table is, since `t[s] = x` may write past `len`.
//! - **Committed.** A reserved table on a target with no lazily zeroed
//!   pages (`lazy_pages`), or with `RIG_TABLE_FALLBACK` set when the
//!   program is built: the slots below `cap` are held, zeroed, and a slot
//!   at or past it reads as `T()` and is grown into only by a write. The
//!   choice is made when the program is built, never as it runs.
//!
//! A reservation the system refuses (`ulimit -v`, strict overcommit)
//! panics as the table is made; a table is never smaller than `n`. In a
//! leak-checked build each mapping holds a one-byte token from the
//! runtime's allocator, freed with it, so a table never dropped is
//! reported as a leak.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime.zig");

/// The Zig type of `Slot[n]`: the fewest of 8, 16, 32, and 64 bits that
/// hold `n - 1` (`sema.slotBytes`).
pub fn Slot(comptime n: u64) type {
    const top = n -| 1;
    if (top <= std.math.maxInt(u8)) return u8;
    if (top <= std.math.maxInt(u16)) return u16;
    if (top <= std.math.maxInt(u32)) return u32;
    return u64;
}

/// `Slot[n].of(i)`: the slot `i` names, or none unless `0 <= i < n`.
pub fn slotOf(comptime n: u64, i: anytype) rt.Opt(Slot(n)) {
    return rt.pack(rt.Opt(Slot(n)), if (rt.offsetBelow(i, n)) |v| @as(Slot(n), @intCast(v)) else null);
}

/// Whether the target gives a private anonymous mapping's pages as zeros
/// when they are first touched, committing none before: every 64-bit
/// POSIX system Rig builds for. Elsewhere (wasm32, Windows) a reserved
/// table is committed as it is written.
const lazy_pages = @sizeOf(usize) == 8 and switch (builtin.os.tag) {
    .linux, .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
} and !rt.config.table_fallback;

/// Whether `T()` is all zero bytes and `T` owns nothing: the mirror of
/// `sema.tableFill`'s `.zeros` for a Zig type. An object says so itself
/// (`Repr.zeros`, which emit writes from `sema.tableFill`); of the rest,
/// only integers (numbers, slots) and `Bool`. A float may be `-0.0`, and
/// an optional's none is not zero bytes.
pub fn fillsWithZeros(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .bool => true,
        else => if (rt.reprOf(T)) |r| r.zeros else false,
    };
}

/// `T()`, the value every slot of a made table starts as: what Rig's
/// `T()` is for each element type a table takes (`sema.tableFill`).
fn defaultOf(comptime T: type) T {
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "__rig_optional")) return rt.pack(T, null);
    return switch (@typeInfo(T)) {
        .int, .float => 0,
        .bool => false,
        .optional => null,
        .@"struct" => if (comptime @hasDecl(T, "__rig_default")) T.__rig_default else T{},
        else => @compileError("rig.Table: no default for " ++ @typeName(T)),
    };
}

fn fullPanic(comptime n: u64) noreturn {
    @branchHint(.cold);
    @panic(std.fmt.comptimePrint("a table of {d} slot{s} is full", .{ n, if (n == 1) "" else "s" }));
}

fn reservePanic(bytes: usize) noreturn {
    @branchHint(.cold);
    var buf: [160]u8 = undefined;
    @panic(std.fmt.bufPrint(&buf, "rig: the system refused to reserve {d} bytes of address space for a table (ulimit -v, or strict overcommit)", .{bytes}) catch "rig: the system refused to reserve a table");
}

const page = std.heap.page_size_min;

/// A huge page's bytes on Linux.
const huge: usize = 2 << 20;

/// `bytes` of address space, zero pages, none committed. On Linux the
/// first 2 MiB keep small pages, since a huge page would commit 2 MiB at
/// a small table's first touch, and the rest, from a 2 MiB boundary, asks
/// for huge pages: a table that grows past 2 MiB is faulted in 2 MiB at a
/// time, one fault and one TLB entry where 512 small pages each take
/// their own, at the cost of the part of its last huge page not yet
/// written (docs/history/records/2026-10/perf-stage/fault-ahead/). It
/// asks only while the system has free 2 MiB blocks to spare
/// (`alloc.zig`'s `hugeFree`), tested once, here: a table grown after
/// memory fragments faults in through the compactor, as every range that
/// asks does (docs/history/records/2026-10/perf-stage/thp-fragmented.md).
/// A release build on Linux and the Mac takes the range from
/// `reserveTable`, which on Linux asks as this does, and waits to until
/// the heap that reserved it does much of the program's work
/// (`tableWaits`); a debug build, and any table it cannot place, maps its
/// own.
fn reserve(bytes: usize) [*]align(page) u8 {
    if (comptime !leak_checked) if (rt.fast_alloc.reserveTable(bytes)) |p| return p;
    const prot: std.posix.PROT = .{ .READ = true, .WRITE = true };
    const flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true };
    if (builtin.os.tag != .linux or bytes <= huge or !rt.fast_alloc.hugeFree()) {
        const m = std.posix.mmap(null, bytes, prot, flags, -1, 0) catch reservePanic(bytes);
        if (builtin.os.tag == .linux) std.posix.madvise(m.ptr, m.len, std.posix.MADV.NOHUGEPAGE) catch {};
        return m.ptr;
    }
    // Mapped `huge` long, then trimmed to start on a 2 MiB boundary.
    const m = std.posix.mmap(null, bytes + huge, prot, flags, -1, 0) catch reservePanic(bytes);
    const lo = @intFromPtr(m.ptr);
    const start = std.mem.alignForward(usize, lo, huge);
    if (start > lo) std.posix.munmap(m[0 .. start - lo]);
    const stop = start + bytes;
    const end = lo + m.len;
    if (end > stop) std.posix.munmap(@as([*]align(page) u8, @ptrFromInt(stop))[0 .. end - stop]);
    const p: [*]align(page) u8 = @ptrFromInt(start);
    std.posix.madvise(p, huge, std.posix.MADV.NOHUGEPAGE) catch {};
    std.posix.madvise(@ptrFromInt(start + huge), bytes - huge, std.posix.MADV.HUGEPAGE) catch {};
    return p;
}

/// The bytes at a reserved table's start faulted in for writing as it is
/// made, on Linux (`readyHead`).
const head_ready: usize = 64 << 10;

/// Fault in, for writing, the first `head_ready` of the `bytes` at `p`,
/// a table just reserved, with one call on Linux. A read of a slot never
/// written maps the system's shared zero page, and the first write to
/// that page then copies it and flushes the TLB of every other CPU the
/// program runs on: in Trig's check at four and eight checkers about
/// 2,200 pages a run, each stopping every running checker. A third of
/// them lie in a table's first 64 KiB (slot 0, a nil id, read first; ids
/// read just ahead of their writes), most of the rest in a few tables
/// read by id across their first 600 KiB (Trig's link indexes), which a
/// table cannot know to fault in, and which their owner fills with
/// `!t.grow(n)`. The pages faulted in here are mostly those a table
/// writes first, faulted in with no trap each; those it never touches
/// cost their memory (about 1.5 MiB a checker on Trig).
/// Elsewhere, or where the system cannot (before 5.14), the pages fault
/// as they are touched.
fn readyHead(p: [*]align(page) u8, bytes: usize) void {
    if (builtin.os.tag != .linux) return;
    std.posix.madvise(p, @min(bytes, head_ready), madv_populate_write) catch {};
}

/// `MADV_POPULATE_WRITE` (Linux 5.14): fault in a range's pages for
/// writing, as a write to each would, in one system call.
const madv_populate_write = 23;

/// Faults in the pages of `base[lo..hi]`, a range of a reservation, for
/// writing (`Table.grow`); the range widens to whole pages, which the
/// reservation holds. A refusal leaves the pages to fault in as they are
/// touched, so it is ignored.
fn populate(base: [*]u8, lo: usize, hi: usize) void {
    const start = std.mem.alignBackward(usize, @intFromPtr(base) + lo, page);
    const stop = std.mem.alignForward(usize, @intFromPtr(base) + hi, page);
    _ = std.os.linux.madvise(@ptrFromInt(start), stop - start, madv_populate_write);
}

fn unreserve(p: [*]align(page) u8, bytes: usize) void {
    if (comptime !leak_checked) if (rt.fast_alloc.unreserveTable(p, bytes)) return;
    std.posix.munmap(p[0..bytes]);
}

/// Whether the program is built with the leak checker, which maps each
/// reserved table on its own: a table used after it is dropped faults,
/// and one never dropped is reported. A release build takes them from
/// the allocator's address space for tables (`alloc.zig`,
/// `reserveTable`), with no system call for most.
const leak_checked = builtin.optimize == .debug;

/// `Table(T, n)`: `n` slots of `T`.
pub fn Table(comptime T: type, comptime n: u64) type {
    if (n == 0) @compileError("rig.Table: a table has at least one slot");
    const zeros = fillsWithZeros(T);
    const How = enum { reserved, made, committed };
    const how: How = if (!zeros) .made else if (lazy_pages) .reserved else .committed;
    const bytes_wide: u128 = @as(u128, n) * @sizeOf(T);
    if (how != .committed and bytes_wide > std.math.maxInt(usize)) @compileError("rig.Table: the table does not fit the address space");
    // The bytes the slots take, rounded up to whole pages for a mapping.
    const bytes: usize = if (how == .committed) 0 else std.mem.alignForward(usize, @intCast(bytes_wide), page);
    return struct {
        /// Slot `s` is `slots[s]`. Never null: an optional of a table, or
        /// of an object that holds one, may keep `none` as a null here.
        slots: [*]T,
        /// The slots pushed: `0..len`.
        len: u64 = 0,
        /// The slots held, below which a committed table reads its own.
        cap: if (how == .committed) usize else void = if (how == .committed) 0 else {},
        /// The leak checker's record of the mapping (`token`).
        token: if (how == .reserved and leak_checked) [*]u8 else void = undefined,

        const Self = @This();
        pub const __rig_args = .{ T, n };
        pub const __rig_table = {};
        /// `Slot[n]`.
        pub const Index = Slot(n);

        /// `Table()`: `n` slots, each `T()`. A table made once its value
        /// is wanted, at run time: never a constant.
        pub fn init() Self {
            if (comptime @sizeOf(T) == 0) return .{ .slots = @ptrFromInt(@alignOf(T)) };
            switch (how) {
                .reserved => {
                    const p = reserve(bytes);
                    readyHead(p, bytes);
                    var t: Self = .{ .slots = @ptrCast(@alignCast(p)) };
                    if (comptime leak_checked) t.token = (rt.allocSlice(u8, 1)).ptr;
                    return t;
                },
                .made => {
                    const buf = rt.allocSlice(T, @intCast(n));
                    const d = defaultOf(T);
                    for (buf) |*slot_| slot_.* = if (comptime rt.needsDrop(T)) defaultOf(T) else d;
                    return .{ .slots = buf.ptr };
                },
                .committed => return .{ .slots = @ptrFromInt(@alignOf(T)) },
            }
        }

        /// `!t.push(x)`: writes slot `len` and gives it; panics when all
        /// `n` are pushed. The slot is dropped first, as any store into a
        /// place drops what was there.
        pub fn push(self: *Self, value: T) Index {
            if (self.len == n) fullPanic(n);
            // `len < n` here, as only `push` raises `len`, and `n - 1`
            // fits `Index`: the cast is exact.
            rt.invariant(self.len < n);
            const s: Index = @truncate(self.len);
            const p = self.slot(s);
            if (comptime rt.needsDrop(T)) rt.dropElement(T, p);
            p.* = value;
            self.len += 1;
            return s;
        }

        /// `par.push`'s push of `total` slots at once (`tasks.parPushInto`):
        /// panics as `push` does unless they fit, and gives the first. Each
        /// slot keeps what it holds, `T()` unless written by slot, for the
        /// tasks to write in place; a committed table holds them all
        /// first, since the tasks write past `cap` at once.
        pub fn pushRuns(self: *Self, total: u64) u64 {
            if (total > n - self.len) fullPanic(n);
            const first = self.len;
            if (comptime how == .committed) if (total > 0 and first + total > self.cap) self.hold(@intCast(first + total - 1));
            self.len += total;
            return first;
        }

        /// `!t.grow(k)`: pushes `k` slots at once, as `k` pushes would,
        /// and panics as `push` does unless they fit; `k = 0` does
        /// nothing. Each slot keeps what it holds, `T()` unless written
        /// by slot. On Linux a reserved table then faults in those
        /// slots' pages for writing with one `MADV_POPULATE_WRITE`, so a
        /// later read of one finds a page of its own rather than the
        /// shared zero page, whose first write would copy it and flush
        /// every other core's TLB of it. A kernel without the advice
        /// (before 5.14) refuses it, and the pages then fault in as they
        /// are touched, as any reserved table's do.
        pub fn grow(self: *Self, k: rt.Int) void {
            const total = std.math.cast(u64, k) orelse @panic("negative size");
            if (total == 0) return;
            const first = self.pushRuns(total);
            if (comptime how == .reserved and builtin.os.tag == .linux and @sizeOf(T) > 0) populate(@ptrCast(self.slots), first * @sizeOf(T), (first + total) * @sizeOf(T));
        }

        /// A slot's offset: below `n` by its type, which a debug build
        /// asserts, as a proven test is (`verify_proofs`).
        inline fn offset(s: Index) usize {
            if (comptime n <= std.math.maxInt(Index)) if (rt.verify_proofs and s >= n) rt.proofPanic();
            return @intCast(s);
        }

        /// `t[s]`: the slot's value, with no test.
        pub inline fn at(self: *const Self, s: Index) T {
            return self.constSlot(s).*;
        }

        /// `t[s]` as a place to read in place.
        pub inline fn constSlot(self: *const Self, s: Index) *const T {
            const i = offset(s);
            if (comptime how == .committed) if (i >= self.cap) return &zero;
            return &self.slots[i];
        }

        /// `t[s]` as a place to write.
        pub inline fn slot(self: *Self, s: Index) *T {
            const i = offset(s);
            if (comptime how == .committed) if (i >= self.cap) self.hold(i);
            return &self.slots[i];
        }

        /// `i`, an integer, as a slot: tested `0 <= i < n`.
        pub inline fn index(i: anytype) Index {
            return @intCast(rt.indexBelow(i, comptime @min(n, std.math.maxInt(usize))));
        }

        /// `t[i]` with an integer `i`, or a slot under `RIG_NO_PROOFS`.
        pub inline fn atInt(self: *const Self, i: anytype) T {
            return self.at(index(i));
        }
        pub inline fn constSlotInt(self: *const Self, i: anytype) *const T {
            return self.constSlot(index(i));
        }
        pub inline fn slotInt(self: *Self, i: anytype) *T {
            return self.slot(index(i));
        }

        /// What a committed table's slot past `cap` reads as.
        const zero: T = if (how == .committed) std.mem.zeroes(T) else undefined;

        /// A committed table, written at `i`: the slots up to `i` held,
        /// at least doubling, zeroed. A read never holds more.
        noinline fn hold(self: *Self, i: usize) void {
            @branchHint(.cold);
            const limit: usize = if (comptime n > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(n);
            const want = @min(limit, @max(i +| 1, self.cap *| 2, 64));
            const old = self.slots[0..self.cap];
            const buf = rt.allocSlice(T, want);
            @memcpy(buf[0..self.cap], old);
            @memset(std.mem.sliceAsBytes(buf[self.cap..]), 0);
            if (self.cap > 0) rt.freeSlice(T, old);
            self.slots = buf.ptr;
            self.cap = want;
        }

        /// The pushed slots, `0..len`, which `for x in t` walks.
        pub fn items(self: anytype) if (@typeInfo(@TypeOf(self)).pointer.attrs.@"const") []const T else []T {
            return self.slots[0..@intCast(self.len)];
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try rt.writeList(w, self.slots[0..@intCast(self.len)]);
        }

        /// Drop every slot a made table holds, all `n`, last first; then
        /// give back the slots' memory.
        pub fn __rig_drop(self: *Self) void {
            if (comptime @sizeOf(T) == 0) return;
            switch (how) {
                .reserved => {
                    unreserve(@ptrCast(@alignCast(self.slots)), bytes);
                    if (comptime leak_checked) rt.freeSlice(u8, self.token[0..1]);
                },
                .made => {
                    const all = self.slots[0..@intCast(n)];
                    if (comptime rt.needsDrop(T)) {
                        var i: usize = all.len;
                        while (i > 0) {
                            i -= 1;
                            rt.dropElement(T, &all[i]);
                        }
                    }
                    rt.freeSlice(T, all);
                },
                .committed => if (self.cap > 0) rt.freeSlice(T, self.slots[0..self.cap]),
            }
        }
    };
}

/// Test only: the bytes of the `len` at `p` resident (`mincore`), on Linux.
fn residentForTest(p: [*]const u8, len: usize) !usize {
    var vec: [1024]u8 = undefined;
    const pages = len / page;
    if (pages > vec.len) return error.TooLong;
    const rc: isize = @bitCast(std.os.linux.syscall3(.mincore, @intFromPtr(p), len, @intFromPtr(&vec)));
    if (rc < 0) return error.NoMincore;
    var in: usize = 0;
    for (vec[0..pages]) |v| in += v & 1;
    return in * page;
}

test "on Linux a reserved table's first 64 KiB are faulted in as it is made" {
    if (builtin.os.tag != .linux or page != 4096) return error.SkipZigTest;
    var t = Table(u32, 1 << 22).init();
    defer t.__rig_drop();
    const base: [*]const u8 = @ptrCast(t.slots);
    try std.testing.expectEqual(head_ready, try residentForTest(base, 4 * head_ready));
    try std.testing.expectEqual(@as(u32, 0), t.at(5));
    t.slot(5).* = 7;
    try std.testing.expectEqual(@as(u32, 7), t.at(5));
    // A table smaller than 64 KiB is faulted in whole.
    var small = Table(u64, 100).init();
    defer small.__rig_drop();
    try std.testing.expectEqual(@as(usize, page), try residentForTest(@ptrCast(small.slots), page));
}

test "grow pushes slots that read as T(), and push follows them" {
    var t = Table(u32, 1 << 16).init();
    defer t.__rig_drop();
    t.grow(0);
    try std.testing.expectEqual(@as(u64, 0), t.len);
    t.grow(5000);
    try std.testing.expectEqual(@as(u64, 5000), t.len);
    try std.testing.expectEqual(@as(u32, 0), t.at(4999));
    t.slot(4000).* = 7;
    try std.testing.expectEqual(@as(u32, 7), t.at(4000));
    try std.testing.expectEqual(@as(Slot(1 << 16), 5000), t.push(9));
    t.grow((1 << 16) - 5001);
    try std.testing.expectEqual(@as(u64, 1 << 16), t.len);
    try std.testing.expectEqual(@as(u32, 9), t.at(5000));

    var m = Table(f64, 8).init();
    defer m.__rig_drop();
    m.grow(3);
    try std.testing.expectEqual(@as(u64, 3), m.len);
    try std.testing.expectEqual(@as(f64, 0), m.at(2));
    try std.testing.expectEqual(@as(Slot(8), 3), m.push(1.5));
}
