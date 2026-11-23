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
//!   memory. It is never one of `alloc.zig`'s blocks, which are reused
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
const root = @import("root");
const rt = @import("runtime.zig");
const split = @import("split.zig");

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
/// for huge pages (2 MiB unless `RIG_HUGE_MIN_MB` says more: `alloc.zig`,
/// `huge_min`): a table that grows past 2 MiB is faulted in 2 MiB at a
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
    const min = if (builtin.os.tag == .linux) rt.fast_alloc.hugeMin() else huge;
    if (builtin.os.tag != .linux or bytes <= min or !rt.fast_alloc.hugeFree()) {
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
    std.posix.madvise(p, min, std.posix.MADV.NOHUGEPAGE) catch {};
    std.posix.madvise(@ptrFromInt(start + min), bytes - min, std.posix.MADV.HUGEPAGE) catch {};
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
                    if (census.on()) census.add(@intFromPtr(p), bytes, @typeName(T), n);
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
            if (comptime how == .committed) if (total > 0 and first + total > self.cap) self.grow(@intCast(first + total - 1));
            self.len += total;
            return first;
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
                    if (census.on()) census.drop(@intFromPtr(self.slots));
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

// -----------------------------------------------------------------------------
// The census of reserved Tables (`RIG_TABLE_RSS=1`)
// -----------------------------------------------------------------------------

/// With `RIG_TABLE_RSS=1` set, each reserved table is recorded as it is
/// made, by its element type, `n`, and the thread that made it, and as
/// the process ends (`os.exit`, or `main` returning) each one's resident
/// bytes are written to stderr, one line a table: its bytes present and
/// its own (`/proc/self/pagemap`, so the zero page a read of an unwritten
/// slot maps is not counted), and of them those in huge pages
/// (`/proc/self/smaps`, `AnonHugePages`, of the mappings inside its
/// range, which its advice splits from its neighbours'), then the totals
/// of the segments' region, the Tables' regions, and the rest. A table
/// dropped first is measured as it is dropped. Linux only; unset, a
/// table's making and dropping test one byte and the exit one more.
pub const census = struct {
    const Entry = struct {
        start: usize,
        bytes: usize,
        name: []const u8,
        n: u64,
        tid: i32,
        dropped: bool = false,
        rss: usize = 0,
        huge: usize = 0,
        asked: bool = false,
    };
    const max = 4096;
    /// 0 unread, 1 off, 2 on.
    var state_var: std.atomic.Value(u8) = .init(0);
    const state = split.cell(&state_var, "table.census_state");
    var entries_var: [max]Entry = undefined;
    const entries = split.cell(&entries_var, "table.census_entries");
    var count_var: std.atomic.Value(usize) = .init(0);
    const count = split.cell(&count_var, "table.census_count");
    var lock_var: std.atomic.Value(bool) = .init(false);
    const lock = split.cell(&lock_var, "table.census_lock");

    comptime {
        if (split.on and split.main) _ = .{ state, entries, count, lock };
    }

    /// Whether the census is on, read from the environment once.
    pub inline fn on() bool {
        const s = state.load(.monotonic);
        if (s != 0) return s == 2;
        return readOn();
    }

    noinline fn readOn() bool {
        @branchHint(.cold);
        if (builtin.os.tag != .linux) {
            state.store(1, .monotonic);
            return false;
        }
        const p = rt.process.* orelse return false;
        const v = p.environ.getPosix("RIG_TABLE_RSS");
        const yes = v != null and std.mem.eql(u8, v.?, "1");
        state.store(if (yes) 2 else 1, .monotonic);
        return yes;
    }

    fn take() void {
        if (rt.sched.preempting) rt.sched.holdOff();
        while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn give() void {
        lock.store(false, .release);
        if (rt.sched.preempting) rt.sched.holdOn();
    }

    pub noinline fn add(start: usize, bytes: usize, name: []const u8, n: u64) void {
        @branchHint(.cold);
        if (comptime builtin.os.tag != .linux) return;
        const i = count.fetchAdd(1, .monotonic);
        if (i >= max) return;
        entries.*[i] = .{ .start = start, .bytes = bytes, .name = name, .n = n, .tid = std.os.linux.gettid() };
    }

    /// The table at `start` is about to be dropped: measured now.
    pub noinline fn drop(start: usize) void {
        @branchHint(.cold);
        if (comptime builtin.os.tag != .linux) return;
        take();
        defer give();
        const n = @min(count.load(.monotonic), max);
        for (entries.*[0..n]) |*e| if (e.start == start and !e.dropped) {
            var maps = Maps.read() orelse return;
            defer maps.deinit();
            measure(e, &maps);
            e.dropped = true;
            return;
        };
    }

    /// The mappings of `/proc/self/smaps`, in address order.
    const Map = struct { start: usize, end: usize, rss: usize, huge: usize, hg: bool };
    const Maps = struct {
        list: []Map,
        fn read() ?Maps {
            const linux = std.os.linux;
            const pa = std.heap.page_allocator;
            const rc = linux.openat(linux.AT.FDCWD, "/proc/self/smaps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (@as(isize, @bitCast(rc)) < 0) return null;
            const fd: linux.fd_t = @intCast(rc);
            defer _ = linux.close(fd);
            var text = pa.alloc(u8, 1 << 20) catch return null;
            defer pa.free(text);
            var len: usize = 0;
            while (true) {
                if (len == text.len) text = pa.realloc(text, text.len * 2) catch return null;
                const r: isize = @bitCast(linux.read(fd, text[len..].ptr, text.len - len));
                if (r <= 0) break;
                len += @intCast(r);
            }
            var list: std.ArrayList(Map) = .empty;
            var lines = std.mem.splitScalar(u8, text[0..len], '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                // A mapping's first line: `start-end perms ...`.
                if (std.mem.indexOfScalar(u8, line, '-')) |dash| if (dash > 0 and std.ascii.isHex(line[0]) and std.mem.indexOfScalar(u8, line[0..dash], ' ') == null) {
                    const sp = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse continue;
                    const a = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
                    const b = std.fmt.parseInt(usize, line[dash + 1 .. sp], 16) catch continue;
                    list.append(pa, .{ .start = a, .end = b, .rss = 0, .huge = 0, .hg = false }) catch return null;
                    continue;
                };
                if (list.items.len == 0) continue;
                const m = &list.items[list.items.len - 1];
                if (std.mem.startsWith(u8, line, "Rss:")) m.rss = kib(line[4..]) else if (std.mem.startsWith(u8, line, "AnonHugePages:")) m.huge = kib(line[14..]) else if (std.mem.startsWith(u8, line, "VmFlags:")) {
                    var words = std.mem.tokenizeScalar(u8, line[8..], ' ');
                    while (words.next()) |w| if (std.mem.eql(u8, w, "hg")) {
                        m.hg = true;
                    };
                }
            }
            return .{ .list = list.toOwnedSlice(pa) catch return null };
        }
        fn deinit(self: *Maps) void {
            std.heap.page_allocator.free(self.list);
        }
        fn kib(text: []const u8) usize {
            var words = std.mem.tokenizeScalar(u8, text, ' ');
            const w = words.next() orelse return 0;
            return (std.fmt.parseInt(usize, w, 10) catch 0) * 1024;
        }
    };

    /// `e`'s bytes present and its own, and those of the mappings inside
    /// its range in huge pages.
    fn measure(e: *Entry, maps: *const Maps) void {
        const span = std.mem.alignForward(usize, e.bytes, huge);
        e.rss = ownBytes(e.start, std.mem.alignForward(usize, e.bytes, page));
        e.huge = 0;
        e.asked = false;
        for (maps.list) |m| if (m.start >= e.start and m.end <= e.start + span) {
            e.huge += m.huge;
            e.asked = e.asked or m.hg;
        };
    }

    /// The bytes of `len` at `start` present and mapped by this process
    /// alone (`/proc/self/pagemap`): a page written, not the zero page.
    fn ownBytes(start: usize, len: usize) usize {
        const linux = std.os.linux;
        const rc = linux.openat(linux.AT.FDCWD, "/proc/self/pagemap", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (@as(isize, @bitCast(rc)) < 0) return 0;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        const small = std.heap.pageSize();
        const per = 8192;
        const buf = std.heap.page_allocator.alloc(u64, per) catch return 0;
        defer std.heap.page_allocator.free(buf);
        var total: usize = 0;
        var at = start / small;
        const stop = (start + len) / small;
        while (at < stop) {
            const want: usize = @min(per, stop - at);
            const r: isize = @bitCast(linux.pread(fd, @ptrCast(buf.ptr), want * 8, @intCast(at * 8)));
            if (r <= 0) break;
            const got: usize = @as(usize, @intCast(r)) / 8;
            for (buf[0..got]) |v| {
                // Present (bit 63) and mapped exclusively (bit 56).
                if (v >> 63 == 1 and (v >> 56) & 1 == 1) total += small;
            }
            at += got;
        }
        return total;
    }

    fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = std.posix.system.write(2, line.ptr, line.len);
    }

    fn inside(a: usize, b: usize, lo: usize, hi: usize) bool {
        return a >= lo and b <= hi;
    }

    /// The report, as the process ends; nothing unless the census is on.
    pub fn report() void {
        if (state.load(.monotonic) != 2) return;
        reportAll();
    }

    noinline fn reportAll() void {
        @branchHint(.cold);
        if (comptime builtin.os.tag != .linux) return;
        take();
        defer give();
        var maps = Maps.read() orelse return;
        defer maps.deinit();
        const n = @min(count.load(.monotonic), max);
        const mib = 1 << 20;
        print("rig-table-rss: table\tseq\ttid\tbytes_reserved\trss\tanon_huge\tasked\tdropped\tn\ttype\n", .{});
        var t_rss: usize = 0;
        var t_huge: usize = 0;
        for (entries.*[0..n], 0..) |*e, i| {
            if (!e.dropped) measure(e, &maps);
            t_rss += e.rss;
            t_huge += e.huge;
            print("rig-table-rss: table\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ i, e.tid, e.bytes, e.rss, e.huge, @intFromBool(e.asked), @intFromBool(e.dropped), e.n, e.name });
        }
        const regions = rt.fast_alloc.censusRegions();
        var seg: [3]usize = .{ 0, 0, 0 };
        var tab: [3]usize = .{ 0, 0, 0 };
        var other: [3]usize = .{ 0, 0, 0 };
        var all: [2]usize = .{ 0, 0 };
        for (maps.list) |m| {
            all[0] += m.rss;
            all[1] += m.huge;
            var into: *[3]usize = &other;
            if (regions.seg_end != 0 and inside(m.start, m.end, regions.seg_start, regions.seg_end)) into = &seg;
            for (regions.tables) |r| if (inside(m.start, m.end, r.start, r.start + r.len + huge)) {
                into = &tab;
            };
            into[0] += m.rss;
            into[1] += m.huge;
            if (m.hg) into[2] += 1;
        }
        print("rig-table-rss: tables\tcount={d}\trss={d}\tanon_huge={d}\t(sum of the lines above, MiB {d} / {d})\n", .{ n, t_rss, t_huge, t_rss / mib, t_huge / mib });
        print("rig-table-rss: region\ttables\trss={d}\tanon_huge={d}\thg_maps={d}\n", .{ tab[0], tab[1], tab[2] });
        print("rig-table-rss: region\tsegments\trss={d}\tanon_huge={d}\thg_maps={d}\n", .{ seg[0], seg[1], seg[2] });
        print("rig-table-rss: region\tother\trss={d}\tanon_huge={d}\thg_maps={d}\n", .{ other[0], other[1], other[2] });
        print("rig-table-rss: region\tall\trss={d}\tanon_huge={d}\n", .{ all[0], all[1] });
        var status: [4096]u8 = undefined;
        const text = readFile("/proc/self/status", &status);
        if (std.mem.indexOf(u8, text, "VmHWM:")) |at| {
            const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            print("rig-table-rss: peak\t{s}\n", .{text[at..end]});
        }
    }

    fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
        const linux = std.os.linux;
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (@as(isize, @bitCast(rc)) < 0) return "";
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        var len: usize = 0;
        while (len < buf.len) {
            const r: isize = @bitCast(linux.read(fd, buf[len..].ptr, buf.len - len));
            if (r <= 0) break;
            len += @intCast(r);
        }
        return buf[0..len];
    }
};
