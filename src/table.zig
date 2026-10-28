//! `Table[T, n]` and `Slot[n]` (SPEC §10, "Table"; docs/CORE.md §10,
//! "Tables"): a table holds `n` slots from the moment it is made, each
//! `T()` until written, and a `Slot[n]` is a number below `n`, so any
//! slot names a slot of any table of `n` and is read with no test.
//!
//! How the slots are held is the element's (`sema.tableFill`, mirrored
//! here by `fillsWithZeros`, as `needsDrop` mirrors `typeHasDropGlue`):
//!
//! - **Reserved.** `T` is plain data whose default is all zero bytes: one
//!   private anonymous mapping of `n * @sizeOf(T)` bytes, made with
//!   `MAP_NORESERVE`; on Linux its first 2 MiB keep small pages and the
//!   rest asks for huge ones (`reserve`). The system gives
//!   each page as zeros when it is first touched, so a slot never written
//!   costs no memory. It is its own mapping, never one of `alloc.zig`'s
//!   blocks, which are reused unzeroed and faulted in ahead.
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
/// written (docs/history/records/2026-10/perf-stage/fault-ahead/).
fn reserve(bytes: usize) [*]align(page) u8 {
    const prot: std.posix.PROT = .{ .READ = true, .WRITE = true };
    const flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true };
    if (builtin.os.tag != .linux or bytes <= huge) {
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

fn unreserve(p: [*]align(page) u8, bytes: usize) void {
    std.posix.munmap(p[0..bytes]);
}

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

        const leak_checked = builtin.optimize == .debug;

        /// `Table()`: `n` slots, each `T()`. A table made once its value
        /// is wanted, at run time: never a constant.
        pub fn init() Self {
            if (comptime @sizeOf(T) == 0) return .{ .slots = @ptrFromInt(@alignOf(T)) };
            switch (how) {
                .reserved => {
                    const p = reserve(bytes);
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
            const s: Index = @intCast(self.len);
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
            if (comptime how == .committed) if (i >= self.cap) return &zero;
            return &self.slots[i];
        }

        /// `t[s]` as a place to write.
        pub inline fn slot(self: *Self, s: Index) *T {
            const i = offset(s);
            if (comptime how == .committed) if (i >= self.cap) self.grow(i);
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
        /// at least doubling, zeroed. A read never grows it.
        noinline fn grow(self: *Self, i: usize) void {
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
