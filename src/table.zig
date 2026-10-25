//! `Table[T, n]`, `Slot[n]`, and `Span[n]` (SPEC §10, "Table";
//! docs/CORE.md §10, "Tables"): a table holds `n` slots from the moment it
//! is made, each `T()` until written, and a `Slot[n]` is a number below
//! `n`, so any slot names a slot of any table of `n` and is read with no
//! test. A `Span[n]` is a run of them, `start + count <= n`, so any span
//! is a slice of any table of `n`, taken with no test.
//!
//! How the slots are held is the element's (`sema.tableFill`, mirrored
//! here by `fillsWithZeros`, as `needsDrop` mirrors `typeHasDropGlue`):
//!
//! - **Reserved.** `T` is plain data whose default is all zero bytes: one
//!   private anonymous mapping of `n * @sizeOf(T)` bytes, made with
//!   `MAP_NORESERVE` and, on Linux, `MADV_NOHUGEPAGE`. The system gives
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
    const v = std.math.cast(u64, i) orelse return rt.pack(rt.Opt(Slot(n)), null);
    return rt.pack(rt.Opt(Slot(n)), if (v < n) @as(Slot(n), @intCast(v)) else null);
}

/// The Zig type of `Span[n]`: a run of slots, `start + count <= n`, which
/// only `Table.append`, `sub`, and `Span[n]()` (the empty run at 0)
/// make. Its start and count are each the fewest of 8, 16, 32, and 64
/// bits that hold `n` (`sema.spanWordBytes`), each read with a plain
/// load.
pub fn Span(comptime n: u64) type {
    const W = if (n <= std.math.maxInt(u8)) u8 else if (n <= std.math.maxInt(u16)) u16 else if (n <= std.math.maxInt(u32)) u32 else u64;
    return extern struct {
        start: W = 0,
        count: W = 0,

        const Self = @This();
        pub const __rig_span = {};
        /// `Span[n]()` is all zero bytes, so a table of records that hold
        /// spans is reserved (`fillsWithZeros`).
        pub const __rig_zeros = true;

        /// `sp.len`: the number of slots in the run.
        pub inline fn len(self: Self) i64 {
            return @intCast(self.count);
        }

        /// `sp.sub(a, b)`: the slots `a` up to, not including, `b` of the
        /// run; panics unless `0 <= a <= b <= sp.len`. Its end is at most
        /// the run's, so `start + count <= n` holds.
        pub fn sub(self: Self, a: i64, b: i64) Self {
            if (a < 0 or a > b or b > self.count) subPanic(a, b, self.count);
            return .{ .start = self.start + @as(W, @intCast(a)), .count = @intCast(b - a) };
        }

        /// Prints as the range of slots it runs over, `start..end`.
        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d}..{d}", .{ self.start, @as(u64, self.start) + self.count });
        }
    };
}

fn subPanic(a: i64, b: i64, count: u64) noreturn {
    @branchHint(.cold);
    var buf: [128]u8 = undefined;
    @panic(std.fmt.bufPrint(&buf, "span bounds {d}..{d} out of range for a span of {d} slot{s}", .{ a, b, count, if (count == 1) "" else "s" }) catch "span bounds out of range");
}

fn spanPastPanic() noreturn {
    @branchHint(.cold);
    @panic("a span past the slots this table has written: on a target that holds a table's slots as they are written, a span of another table is read only where this one wrote");
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

/// `bytes` of address space, zero pages, none committed.
fn reserve(bytes: usize) [*]align(page) u8 {
    const m = std.posix.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch reservePanic(bytes);
    // A huge page would commit 2 MiB at a table's first touch.
    if (builtin.os.tag == .linux) std.posix.madvise(m.ptr, m.len, std.posix.MADV.NOHUGEPAGE) catch {};
    return m.ptr;
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
        /// `Span[n]`.
        pub const Run = Span(n);

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

        /// `!t.append(xs)`: writes `xs` into the slots from `len` and gives
        /// them as a span; panics, writing nothing, when they do not fit
        /// below `n`. Each slot is dropped first, as `push` drops it.
        pub fn append(self: *Self, xs: []const T) Run {
            const start = self.len;
            if (xs.len > n - start) fullPanic(n);
            const end = start + xs.len;
            if (xs.len > 0) {
                if (comptime how == .committed) if (end > self.cap) self.grow(@intCast(end - 1));
                const to = self.slots[@intCast(start)..@intCast(end)];
                if (comptime rt.needsDrop(T)) {
                    for (to, xs) |*p, x| {
                        rt.dropElement(T, p);
                        p.* = x;
                    }
                } else @memcpy(to, xs);
            }
            self.len = end;
            return .{ .start = @intCast(start), .count = @intCast(xs.len) };
        }

        /// A span's first slot and its count: in range by its type, which a
        /// debug build asserts, as a proven test is (`verify_proofs`).
        inline fn runOf(sp: Run) struct { usize, usize } {
            if (rt.verify_proofs and @as(u128, sp.start) + sp.count > n) rt.proofPanic();
            return .{ @intCast(sp.start), @intCast(sp.count) };
        }

        /// `?t[sp]`: the span's slots, read-only, with no test. A committed
        /// table holds the slots it has written, which every span it made
        /// is within; a span of another table past them panics, since a
        /// read never grows the table.
        pub inline fn view(self: *const Self, sp: Run) []const T {
            const s, const c = runOf(sp);
            if (comptime how == .committed) if (s + c > self.cap) {
                if (c == 0) return &.{};
                spanPastPanic();
            };
            return self.slots[s..][0..c];
        }

        /// `!t[sp]`: the span's slots, to write, with no test. A committed
        /// table is grown to hold them.
        pub inline fn viewMut(self: *Self, sp: Run) []T {
            const s, const c = runOf(sp);
            if (comptime how == .committed) if (s + c > self.cap) {
                if (c == 0) return &.{};
                self.grow(s + c - 1);
            };
            return self.slots[s..][0..c];
        }

        /// `t[sp]` under `RIG_NO_PROOFS`: the span tested against `n`, as
        /// every test is written there.
        pub inline fn viewTested(self: *const Self, sp: Run) []const T {
            if (@as(u128, sp.start) + sp.count > n) rt.proofPanic();
            return self.view(sp);
        }
        pub inline fn viewMutTested(self: *Self, sp: Run) []T {
            if (@as(u128, sp.start) + sp.count > n) rt.proofPanic();
            return self.viewMut(sp);
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
            return @intCast(rt.index(i, if (comptime n > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(n)));
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
