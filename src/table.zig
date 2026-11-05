//! `Table[T, n]` and `Slot[n]` (SPEC §10, "Table"; docs/CORE.md §10,
//! "Tables"): a table holds `n` slots from the moment it is made, each
//! `T()` until written, and a `Slot[n]` is a number below `n`, so any
//! slot names a slot of any table of `n` and is read with no test.
//!
//! How the slots are held is the element's (`sema.tableFill`, mirrored
//! here by `fillsWithZeros`, as `needsDrop` mirrors `typeHasDropGlue`):
//!
//! - **Packed.** `T` is plain data whose default is all zero bytes, on a
//!   target that gives lazily zeroed pages (`lazy_pages`): the slots
//!   below `cap` are held, zeroed, in one of the heap's blocks, and a
//!   slot at or past it reads as `T()` and is grown into only by a write,
//!   at least doubling. Small tables of one thread so share the heap's
//!   pages, huge ones where the heap asks for them, rather than each
//!   taking pages and a mapping of its own. A table whose slots take more
//!   than `pack_bytes` is packed only while it is written from its first
//!   slot onward; the write that takes it past `pack_bytes`, or one that
//!   jumps past what doubling would hold, moves it once into its reserved
//!   range (`spill`), where it stays.
//! - **Reserved.** `n * @sizeOf(T)` bytes of private anonymous address
//!   space, mapped with `MAP_NORESERVE`: in a release build on Linux a
//!   range of the allocator's address space for tables (`alloc.zig`,
//!   `reserveTable`), elsewhere a mapping of its own. On Linux its first
//!   2 MiB keep small pages and the rest asks for huge ones while the
//!   system has free 2 MiB blocks to spare (`reserve`), and a table moved
//!   there full, as dense as it was packed, asks for all of it. The
//!   system gives each page as zeros when it is first touched, so a slot
//!   never written costs no memory. It is never one of `alloc.zig`'s
//!   blocks, which are reused unzeroed and faulted in ahead. It holds a
//!   packed table that spilled, and a table of zero-sized slots.
//! - **Made.** Any other `T`: `n` slots on the heap, each `T()`, dropped
//!   all `n` when the table is, since `t[s] = x` may write past `len`.
//! - **Committed.** A packed table on a target with no lazily zeroed
//!   pages, or with `RIG_TABLE_FALLBACK` set when the program is built:
//!   packed at every size, never moved into a reserved range. The choice
//!   is made when the program is built, never as it runs.
//!
//! A packed or committed table moves when a write grows it, as a List
//! does when it is pushed: no view of a slot outlives a write to the
//! table, since a slot is a place of the table (docs/CORE.md, "Tables").
//!
//! A reservation the system refuses (`ulimit -v`, strict overcommit)
//! panics as the table is made; a table is never smaller than `n`. In a
//! leak-checked build each mapping holds a one-byte token from the
//! runtime's allocator, freed with it, so a table never dropped is
//! reported as a leak.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
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
} and !(@hasDecl(root, "__rig_table_fallback") and root.__rig_table_fallback);

/// Whether `T()` is all zero bytes and `T` owns nothing: the mirror of
/// `sema.tableFill`'s `.zeros` for a Zig type. An object says so itself
/// (`__rig_zeros`, which emit writes from `sema.tableFill`); of the rest,
/// only integers (numbers, slots) and `Bool`. A float may be `-0.0`, and
/// an optional's none is not zero bytes.
pub fn fillsWithZeros(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .bool => true,
        .@"struct", .@"enum", .@"union" => @hasDecl(T, "__rig_zeros") and T.__rig_zeros,
        else => false,
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
/// A `dense` range, about to be filled from its start, asks for huge
/// pages from its first byte.
/// A release build on Linux takes the range from `reserveTable`, which
/// asks the same way; a debug build, and any table it cannot place, maps
/// its own.
fn reserve(bytes: usize, dense: bool) [*]align(page) u8 {
    if (comptime !leak_checked) if (rt.fast_alloc.reserveTable(bytes, dense)) |p| return p;
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
    if (dense) {
        std.posix.madvise(p, bytes, std.posix.MADV.HUGEPAGE) catch {};
        return p;
    }
    std.posix.madvise(p, huge, std.posix.MADV.NOHUGEPAGE) catch {};
    std.posix.madvise(@ptrFromInt(start + huge), bytes - huge, std.posix.MADV.HUGEPAGE) catch {};
    return p;
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

/// The most bytes a packed table holds in a heap block; one that needs
/// more moves into its reserved range. One huge page: a table moved
/// there has filled it, so its range asks for huge pages from its first
/// byte and wastes none of the first.
const pack_bytes: usize = huge;

/// `Table(T, n)`: `n` slots of `T`.
pub fn Table(comptime T: type, comptime n: u64) type {
    if (n == 0) @compileError("rig.Table: a table has at least one slot");
    const zeros = fillsWithZeros(T);
    const How = enum { reserved, made, committed, @"packed" };
    const how: How = if (!zeros) .made else if (@sizeOf(T) == 0) .reserved else if (lazy_pages) .@"packed" else .committed;
    const held = how == .committed or how == .@"packed";
    const bytes_wide: u128 = @as(u128, n) * @sizeOf(T);
    // A packed table that may need more than `pack_bytes`, which it then
    // holds in its reserved range.
    const spills = how == .@"packed" and bytes_wide > pack_bytes;
    if ((how == .reserved or spills) and bytes_wide > std.math.maxInt(usize)) @compileError("rig.Table: the table does not fit the address space");
    // The bytes the slots take, rounded up to whole pages for a mapping.
    const bytes: usize = if (how == .reserved or spills) std.mem.alignForward(usize, @intCast(bytes_wide), page) else 0;
    // The most slots a packed table holds in a heap block.
    const pack_slots: usize = if (how == .@"packed") pack_bytes / @max(@sizeOf(T), 1) else 0;
    // The slots of one page, which a write may reach past what doubling
    // would hold and stay packed.
    const page_slots: usize = @max(64, page / @max(@sizeOf(T), 1));
    return struct {
        /// Slot `s` is `slots[s]`. Never null: an optional of a table, or
        /// of an object that holds one, may keep `none` as a null here.
        slots: [*]T,
        /// The slots pushed: `0..len`.
        len: u64 = 0,
        /// The slots held, below which a packed or committed table reads
        /// its own; `n` once a packed table is in its reserved range.
        cap: if (held) usize else void = if (held) 0 else {},
        /// The leak checker's record of the mapping (`token`).
        token: if ((how == .reserved or spills) and leak_checked) [*]u8 else void = undefined,

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
                    const p = reserve(bytes, false);
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
                .committed, .@"packed" => return .{ .slots = @ptrFromInt(@alignOf(T)) },
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
            if (comptime held) if (i >= self.cap) return &zero;
            return &self.slots[i];
        }

        /// `t[s]` as a place to write.
        pub inline fn slot(self: *Self, s: Index) *T {
            const i = offset(s);
            if (comptime held) if (i >= self.cap) self.grow(i);
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

        /// What a packed or committed table's slot past `cap` reads as.
        const zero: T = if (held) std.mem.zeroes(T) else undefined;

        /// `n`, or the most a `usize` counts.
        const limit: usize = if (n > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(n);

        /// A packed or committed table, written at `i`: the slots up to
        /// `i` held, at least doubling, zeroed; a packed table past
        /// `pack_bytes`, or written past what doubling holds, moved into
        /// its reserved range (`spill`). A read never grows it.
        noinline fn grow(self: *Self, i: usize) void {
            @branchHint(.cold);
            const want = @min(limit, @max(i +| 1, self.cap *| 2, 64));
            if (comptime spills) if (want > pack_slots or i >= @max(self.cap *| 2, page_slots)) return self.spill();
            const old = self.slots[0..self.cap];
            const buf = rt.allocSlice(T, want);
            @memcpy(buf[0..self.cap], old);
            @memset(std.mem.sliceAsBytes(buf[self.cap..]), 0);
            if (self.cap > 0) rt.freeSlice(T, old);
            self.slots = buf.ptr;
            self.cap = want;
        }

        /// A packed table moved into its reserved range, all `n` slots,
        /// with the slots it held: for good, so `cap` is `n`. One that
        /// filled its heap block asks for huge pages from its first byte.
        noinline fn spill(self: *Self) void {
            @branchHint(.cold);
            const dense = self.cap *| 2 > pack_slots;
            const p: [*]T = @ptrCast(@alignCast(reserve(bytes, dense)));
            if (comptime leak_checked) self.token = (rt.allocSlice(u8, 1)).ptr;
            if (self.cap > 0) {
                const old = self.slots[0..self.cap];
                @memcpy(p[0..self.cap], old);
                rt.freeSlice(T, old);
            }
            self.slots = p;
            self.cap = limit;
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
                .@"packed" => if (spills and self.cap == limit) {
                    unreserve(@ptrCast(@alignCast(self.slots)), bytes);
                    if (comptime leak_checked) rt.freeSlice(u8, self.token[0..1]);
                } else if (self.cap > 0) rt.freeSlice(T, self.slots[0..self.cap]),
            }
        }
    };
}
