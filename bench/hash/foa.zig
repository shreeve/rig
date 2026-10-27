//! boost::unordered_flat_map's table (FOA, "fast open addressing"), boost
//! 1.92.0, ported to Zig as closely as the languages allow. The sources are
//! bench/hash/upstream/boost/unordered/include/boost/unordered/detail/foa/
//! core.hpp (group15, pow2_size_policy, pow2_quadratic_prober, table_arrays,
//! table_core) and table.hpp (emplace_impl, erase).
//!
//! - Element slots are split into groups of N = 15. The group count is a
//!   power of two, and the last slot of the last group is a sentinel, so a
//!   table holds 15 * 2^n - 1 elements.
//! - Each group has a 16-byte metadata word apart from the elements: 15
//!   reduced hashes (0 free, 1 the sentinel, 2 to 255 a full slot) and an
//!   overflow byte. An insert that passes a full group sets bit hash % 8 of
//!   its overflow byte; a lookup stops at the first group whose bit for its
//!   hash is clear.
//! - The home group is the hash's high bits, the reduced hash its low byte.
//! - Probing is quadratic over groups (triangular numbers).
//! - The maximum load is 0.875, or every slot of a table of two groups. An
//!   erase that empties a slot of a group overflowed for the slot's class
//!   lowers the maximum load by one (anti-drift); growth asks for 1/61 more
//!   than the size so that drift does not rehash at the same size.
//!
//! The hash is used as it is, as boost does for a hash marked avalanching.
const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    /// arm64 only: reduce a group compare to a mask with `shrn #4` (four bits
    /// a lane, lane = ctz >> 2) instead of boost's NEON movemask emulation.
    nibble_mask: bool = false,
};

/// The number of element slots in a group.
pub const N = 15;
/// boost's hard-coded maximum load factor (`foa::mlf`).
pub const mlf: f32 = 0.875;

const Arch = enum { sse2, neon, generic };
const arch: Arch = switch (builtin.cpu.arch) {
    .x86_64 => .sse2,
    .aarch64 => .neon,
    else => .generic,
};

/// group15's 16-byte metadata word.
const Group = extern struct {
    m: [16]u8 align(16),
};

const sentinel_ = 1;

/// `match_word` (SSE2): the reduced hash of a low byte, broadcast to four
/// bytes; the NEON and generic tables are its low byte.
const match_word: [256]u32 = blk: {
    var w: [256]u32 = undefined;
    for (&w, 0..) |*x, i| {
        const r: u32 = switch (i) {
            0 => 8,
            1 => 9,
            else => i,
        };
        x.* = r * 0x01010101;
    }
    break :blk w;
};

const reduced_table: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = @truncate(match_word[i]);
    break :blk t;
};

inline fn reducedHash(hash: u64) u8 {
    return reduced_table[@as(u8, @truncate(hash))];
}

/// `is_not_overflowed`'s table of bits.
const shift_table = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

/// Two groups as an empty container's: the sentinel set, nothing else.
/// `empty` points here, so lookup needs no null check; capacity is 0, so no
/// insert ever writes it.
var dummy_groups: [2]Group = .{
    .{ .m = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } },
    .{ .m = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } },
};

/// The masks of a group's lanes, as `int` in boost: one bit a lane, or with
/// `nibble_mask` on arm64, bit 3 of each lane's nibble.
fn Masks(comptime nibble: bool) type {
    return struct {
        pub const T = if (nibble) u64 else u32;
        /// The 15 element lanes.
        pub const lanes: T = if (nibble) 0x0888_8888_8888_8888 else 0x7FFF;

        pub inline fn laneBit(i: u32) T {
            return if (nibble) @as(T, 8) << @intCast(i * 4) else @as(T, 1) << @intCast(i);
        }

        /// `unchecked_countr_zero`, as a lane.
        pub inline fn lane(m: T) u32 {
            return if (nibble) @as(u32, @ctz(m)) >> 2 else @ctz(m);
        }

        /// The lanes where `eq` holds, before `& lanes`.
        pub inline fn reduce(eq: @Vector(16, bool)) T {
            if (nibble) {
                // cmeq, shrn #4, fmov
                const bytes: @Vector(16, u8) = @select(u8, eq, @as(@Vector(16, u8), @splat(0xFF)), @as(@Vector(16, u8), @splat(0)));
                const halves: @Vector(8, u16) = @bitCast(bytes);
                const narrowed: @Vector(8, u8) = @truncate(halves >> @splat(4));
                return @bitCast(narrowed);
            }
            switch (arch) {
                .neon => {
                    // simde_mm_movemask_epi8, as boost copies it: AND with
                    // the lane weights, zip the halves, add across.
                    const md: @Vector(16, u8) = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
                    const masked = @select(u8, eq, md, @as(@Vector(16, u8), @splat(0)));
                    const zipped = @shuffle(u8, masked, undefined, [16]i32{ 0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15 });
                    const x: @Vector(8, u16) = @bitCast(zipped);
                    return @reduce(.Add, x);
                },
                // pmovmskb
                .sse2, .generic => return @as(u16, @bitCast(eq)),
            }
        }
    };
}

pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return HashMapWith(K, V, Context, .{});
}

pub fn HashMapWith(comptime K: type, comptime V: type, comptime Context: type, comptime options: Options) type {
    comptime std.debug.assert(@sizeOf(Context) == 0);
    return struct {
        const Self = @This();
        const M = Masks(options.nibble_mask and arch == .neon);
        const Mask = M.T;

        pub const KV = struct { key: K, value: V };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        /// boost's value_type, the element array's type.
        const Element = KV;
        const ctx: Context = undefined;
        const elem_align = @alignOf(Element);

        // table_arrays
        groups_size_index: u6,
        groups_size_mask: usize,
        groups: [*]Group,
        elements: ?[*]Element,
        // plain_size_control
        ml: usize,
        size: usize,

        /// `table_arrays::new_(al, 0)`: two dummy groups, no allocation.
        pub const empty: Self = .{
            .groups_size_index = 63,
            .groups_size_mask = 1,
            .groups = &dummy_groups,
            .elements = null,
            .ml = 0,
            .size = 0,
        };

        // ---- group15 -------------------------------------------------------

        inline fn load(pg: *const Group) @Vector(16, u8) {
            return pg.m;
        }

        inline fn match(pg: *const Group, hash: u64) Mask {
            const word: @Vector(16, u8) = switch (arch) {
                .sse2 => @bitCast(@as(@Vector(4, u32), @splat(match_word[@as(u8, @truncate(hash))]))),
                else => @splat(reducedHash(hash)),
            };
            return M.reduce(load(pg) == word) & M.lanes;
        }

        inline fn matchAvailable(pg: *const Group) Mask {
            return M.reduce(load(pg) == @as(@Vector(16, u8), @splat(0))) & M.lanes;
        }

        inline fn matchOccupied(pg: *const Group) Mask {
            return switch (arch) {
                .neon => M.reduce(load(pg) > @as(@Vector(16, u8), @splat(0))) & M.lanes,
                else => ~matchAvailable(pg) & M.lanes,
            };
        }

        inline fn isNotOverflowed(pg: *const Group, hash: u64) bool {
            return pg.m[15] & shift_table[@as(u3, @truncate(hash))] == 0;
        }

        inline fn markOverflow(pg: *Group, hash: u64) void {
            pg.m[15] |= @as(u8, 1) << @as(u3, @truncate(hash));
        }

        /// The slot's stored reduced hash keeps its hash's class mod 8.
        inline fn maybeCausedOverflow(pg: *const Group, n: u32) bool {
            return !isNotOverflowed(pg, pg.m[n]);
        }

        inline fn setSlot(pg: *Group, n: u32, hash: u64) void {
            pg.m[n] = reducedHash(hash);
        }

        // ---- pow2_size_policy ----------------------------------------------

        inline fn sizeIndex(n: usize) u6 {
            const bits: u7 = if (n <= 2) 1 else @intCast(64 - @clz(n - 1));
            return @intCast(64 - @as(u7, bits));
        }

        inline fn sizeOf(size_index: u6) usize {
            return @as(usize, 1) << @intCast(64 - @as(u7, size_index));
        }

        /// `size_index_for`: n/N+1 == ceil((n+1)/N), +1 for the sentinel.
        inline fn sizeIndexFor(n: usize) u6 {
            return sizeIndex(n / N + 1);
        }

        inline fn positionFor(hash: u64, size_index: u6) usize {
            return @intCast(hash >> size_index);
        }

        fn capacityFor(n: usize) usize {
            return sizeOf(sizeIndexFor(n)) * N - 1;
        }

        // ---- pow2_quadratic_prober -----------------------------------------

        const Prober = struct {
            pos: usize,
            step: usize = 0,

            inline fn next(pb: *Prober, mask: usize) bool {
                pb.step += 1;
                pb.pos = (pb.pos + pb.step) & mask;
                return pb.step <= mask;
            }
        };

        // ---- table_arrays --------------------------------------------------

        const Arrays = struct {
            groups_size_index: u6,
            groups_size_mask: usize,
            groups: [*]Group,
            elements: [*]Element,
        };

        /// Combined space for elements and groups, in bytes, a whole
        /// number of elements (`buffer_size` * sizeof(value_type)).
        fn bufferBytes(groups_size: usize) usize {
            const bytes = @sizeOf(Element) * (groups_size * N - 1) + @sizeOf(Group) * (groups_size + 1) - 1;
            return (bytes + @sizeOf(Element) - 1) / @sizeOf(Element) * @sizeOf(Element);
        }

        /// `table_arrays::new_` for n > 0: elements, then the groups at the
        /// next 16-byte boundary after the element slots.
        fn newArrays(gpa: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Arrays {
            const size_index = sizeIndexFor(n);
            const groups_size = sizeOf(size_index);
            const buf = try gpa.alignedAlloc(u8, .of(Element), bufferBytes(groups_size));
            const elements: [*]Element = @ptrCast(buf.ptr);
            var p: usize = @intFromPtr(elements + groups_size * N - 1);
            p += (@sizeOf(Group) -% p) % @sizeOf(Group);
            const groups: [*]Group = @ptrFromInt(p);
            @memset(@as([*]u8, @ptrCast(groups))[0 .. groups_size * @sizeOf(Group)], 0);
            groups[groups_size - 1].m[N - 1] = sentinel_;
            return .{
                .groups_size_index = size_index,
                .groups_size_mask = groups_size - 1,
                .groups = groups,
                .elements = elements,
            };
        }

        fn deleteArrays(gpa: std.mem.Allocator, elements: ?[*]Element, groups_size_mask: usize) void {
            const e = elements orelse return;
            const buf: [*]align(elem_align) u8 = @ptrCast(e);
            gpa.free(buf[0..bufferBytes(groups_size_mask + 1)]);
        }

        // ---- table_core ----------------------------------------------------

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            deleteArrays(gpa, self.elements, self.groups_size_mask);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn capacity(self: *const Self) usize {
            return if (self.elements != null) (self.groups_size_mask + 1) * N - 1 else 0;
        }

        fn initialMaxLoad(self: *const Self) usize {
            const small_capacity = 2 * N - 1;
            const c = self.capacity();
            if (c <= small_capacity) return c; // 100% usage
            return @intFromFloat(mlf * @as(f32, @floatFromInt(c)));
        }

        inline fn hashFor(k: K) u64 {
            return ctx.hash(k);
        }

        /// BOOST_UNORDERED_PREFETCH_ELEMENTS: the first line on x86, the
        /// first half of the group's slots on ARM.
        inline fn prefetchElements(p: [*]const Element) void {
            if (builtin.cpu.arch.isArm() or builtin.cpu.arch.isAARCH64()) {
                const cache_line = 64;
                var p0: [*]const u8 = @ptrCast(p);
                const p1 = p0 + @sizeOf(Element) * N / 2;
                while (@intFromPtr(p0) < @intFromPtr(p1)) : (p0 += cache_line)
                    @prefetch(p0, .{ .rw = .read, .locality = 3, .cache = .data });
            } else {
                @prefetch(p, .{ .rw = .read, .locality = 3, .cache = .data });
            }
        }

        /// table_locator
        const Locator = struct {
            pg: *Group,
            n: u32,
            p: *Element,
        };

        inline fn find(self: *const Self, k: K, pos0: usize, hash: u64) ?Locator {
            var pb: Prober = .{ .pos = pos0 };
            while (true) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                var mask = match(pg, hash);
                if (mask != 0) {
                    const p = self.elements.? + pos * N;
                    prefetchElements(p);
                    while (true) {
                        const n = M.lane(mask);
                        if (ctx.eql(k, p[n].key)) {
                            @branchHint(.likely);
                            return .{ .pg = pg, .n = n, .p = &p[n] };
                        }
                        mask &= mask - 1;
                        if (mask == 0) break;
                    }
                }
                if (isNotOverflowed(pg, hash)) {
                    @branchHint(.likely);
                    return null;
                }
                if (!pb.next(self.groups_size_mask)) {
                    @branchHint(.unlikely);
                    return null;
                }
            }
        }

        inline fn findKey(self: *const Self, k: K) ?Locator {
            const hash = hashFor(k);
            return self.find(k, positionFor(hash, self.groups_size_index), hash);
        }

        /// `nosize_unchecked_emplace_at`
        inline fn emplaceAt(arrays_: Arrays, pos0: usize, hash: u64, k: K, v: V) *Element {
            var pb: Prober = .{ .pos = pos0 };
            while (true) : (_ = pb.next(arrays_.groups_size_mask)) {
                const pos = pb.pos;
                const pg = &arrays_.groups[pos];
                const mask = matchAvailable(pg);
                if (mask != 0) {
                    @branchHint(.likely);
                    const n = M.lane(mask);
                    const p = &arrays_.elements[pos * N + n];
                    p.* = .{ .key = k, .value = v };
                    setSlot(pg, n, hash);
                    return p;
                } else markOverflow(pg, hash);
            }
        }

        /// `new_arrays_for_growth`: ceil((size + size/61 + 1) / mlf) slots,
        /// so that drift does not bring the table back to its own size.
        fn newArraysForGrowth(self: *const Self, gpa: std.mem.Allocator) !Arrays {
            const s = self.size;
            const n: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(s + s / 61 + 1)) / mlf));
            return newArrays(gpa, n);
        }

        /// `unchecked_rehash(new_arrays_)`: every element hashed again and
        /// placed with no compare.
        fn uncheckedRehash(self: *Self, gpa: std.mem.Allocator, new: Arrays) void {
            if (self.elements) |elements| {
                const ngroups = self.groups_size_mask + 1;
                const last = ngroups - 1;
                var g: usize = 0;
                while (g < ngroups) : (g += 1) {
                    var mask = self.matchReallyOccupied(g, last);
                    const p = elements + g * N;
                    while (mask != 0) : (mask &= mask - 1) {
                        const e = &p[M.lane(mask)];
                        const hash = hashFor(e.key);
                        _ = emplaceAt(new, positionFor(hash, new.groups_size_index), hash, e.key, e.value);
                    }
                }
            }
            deleteArrays(gpa, self.elements, self.groups_size_mask);
            self.groups_size_index = new.groups_size_index;
            self.groups_size_mask = new.groups_size_mask;
            self.groups = new.groups;
            self.elements = new.elements;
            self.ml = self.initialMaxLoad();
        }

        /// `unchecked_emplace_with_rehash`: the new element goes into the new
        /// arrays first, then the old ones are moved over.
        noinline fn emplaceWithRehash(self: *Self, gpa: std.mem.Allocator, hash: u64, k: K, v: V) !void {
            const new = try self.newArraysForGrowth(gpa);
            _ = emplaceAt(new, positionFor(hash, new.groups_size_index), hash, k, v);
            self.uncheckedRehash(gpa, new);
            self.size += 1;
        }

        inline fn arrays(self: *const Self) Arrays {
            return .{
                .groups_size_index = self.groups_size_index,
                .groups_size_mask = self.groups_size_mask,
                .groups = self.groups,
                .elements = self.elements.?,
            };
        }

        /// `match_really_occupied`: excluding the sentinel.
        inline fn matchReallyOccupied(self: *const Self, g: usize, last: usize) Mask {
            const s: Mask = if (g == last) M.laneBit(N - 1) else 0;
            return matchOccupied(&self.groups[g]) & ~s;
        }

        /// `recover_slot`, with the anti-drift decrement of the max load.
        inline fn recoverSlot(self: *Self, pg: *Group, n: u32) void {
            self.ml -= @intFromBool(maybeCausedOverflow(pg, n));
            pg.m[n] = 0;
            self.size -= 1;
        }

        // ---- the API -------------------------------------------------------

        /// Inserts `k` or overwrites its value: `insert_or_assign`.
        pub fn put(self: *Self, gpa: std.mem.Allocator, k: K, v: V) !void {
            // table::emplace_impl
            const hash = hashFor(k);
            const pos0 = positionFor(hash, self.groups_size_index);
            if (self.find(k, pos0, hash)) |loc| {
                loc.p.value = v;
                return;
            }
            if (self.size < self.ml) {
                @branchHint(.likely);
                _ = emplaceAt(self.arrays(), pos0, hash, k, v);
                self.size += 1;
            } else {
                try self.emplaceWithRehash(gpa, hash, k, v);
            }
        }

        pub fn get(self: *const Self, k: K) ?V {
            const loc = self.findKey(k) orelse return null;
            return loc.p.value;
        }

        pub fn getPtr(self: *const Self, k: K) ?*V {
            const loc = self.findKey(k) orelse return null;
            return &loc.p.value;
        }

        pub fn contains(self: *const Self, k: K) bool {
            return self.findKey(k) != null;
        }

        pub fn fetchRemove(self: *Self, k: K) ?KV {
            const loc = self.findKey(k) orelse return null;
            const kv = loc.p.*;
            self.recoverSlot(loc.pg, loc.n);
            return kv;
        }

        /// Group by group over the full lanes, as `for_all_elements`.
        pub const Iterator = struct {
            groups: [*]Group,
            elements: [*]Element,
            ngroups: usize,
            g: usize,
            mask: Mask,

            pub fn next(it: *Iterator) ?Entry {
                while (it.mask == 0) {
                    it.g += 1;
                    if (it.g >= it.ngroups) return null;
                    const s: Mask = if (it.g == it.ngroups - 1) M.laneBit(N - 1) else 0;
                    it.mask = matchOccupied(&it.groups[it.g]) & ~s;
                }
                const n = M.lane(it.mask);
                it.mask &= it.mask - 1;
                const e = &it.elements[it.g * N + n];
                return .{ .key_ptr = &e.key, .value_ptr = &e.value };
            }
        };

        /// std's `keyIterator` and `valueIterator`: one field of each entry.
        pub fn FieldIterator(comptime T: type, comptime field: enum { key, value }) type {
            return struct {
                inner: Iterator,
                pub fn next(it: *@This()) ?*T {
                    const e = it.inner.next() orelse return null;
                    return switch (field) {
                        .key => e.key_ptr,
                        .value => e.value_ptr,
                    };
                }
            };
        }

        pub fn keyIterator(self: *const Self) FieldIterator(K, .key) {
            return .{ .inner = self.iterator() };
        }

        pub fn valueIterator(self: *const Self) FieldIterator(V, .value) {
            return .{ .inner = self.iterator() };
        }

        pub fn iterator(self: *const Self) Iterator {
            const elements = self.elements orelse return .{
                .groups = self.groups,
                .elements = undefined,
                .ngroups = 0,
                .g = 0,
                .mask = 0,
            };
            const ngroups = self.groups_size_mask + 1;
            return .{
                .groups = self.groups,
                .elements = elements,
                .ngroups = ngroups,
                .g = 0,
                .mask = self.matchReallyOccupied(0, ngroups - 1),
            };
        }
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

const IntCtx = struct {
    pub fn hash(_: IntCtx, x: i64) u64 {
        const p = @as(u128, @as(u64, @bitCast(x)) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
        return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
    }
    pub fn eql(_: IntCtx, a: i64, b: i64) bool {
        return a == b;
    }
};

/// Home groups only in the first eighth of the table: long probes, many
/// overflow bits, and the anti-drift decrement at work.
const CrowdedCtx = struct {
    pub fn hash(_: CrowdedCtx, x: i64) u64 {
        return IntCtx.hash(.{}, x) >> 3;
    }
    pub fn eql(_: CrowdedCtx, a: i64, b: i64) bool {
        return a == b;
    }
};

const TextCtx = struct {
    pub fn hash(_: TextCtx, s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: TextCtx, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

fn checkSame(comptime Map: type, m: *const Map, ref: *const std.AutoHashMapUnmanaged(i64, i64)) !void {
    try testing.expectEqual(ref.count(), m.count());
    var it = ref.iterator();
    while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, m.get(e.key_ptr.*).?);
    var n: usize = 0;
    var mi = m.iterator();
    while (mi.next()) |e| {
        n += 1;
        try testing.expectEqual(ref.get(e.key_ptr.*).?, e.value_ptr.*);
    }
    try testing.expectEqual(ref.count(), n);
    try testing.expect(m.size <= m.ml);
}

fn randomOps(comptime Map: type, ops: usize, range: i64, seed: u64) !void {
    const gpa = testing.allocator;
    var m: Map = .empty;
    defer m.deinit(gpa);
    var ref: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    defer ref.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..ops) |i| {
        const k = r.intRangeLessThan(i64, 0, range);
        switch (r.uintLessThan(u8, 10)) {
            0...3 => {
                const v: i64 = @intCast(i);
                try m.put(gpa, k, v);
                try ref.put(gpa, k, v);
            },
            4...6 => {
                const a = m.fetchRemove(k);
                const b = ref.fetchRemove(k);
                try testing.expectEqual(b == null, a == null);
                if (a) |x| {
                    try testing.expectEqual(b.?.key, x.key);
                    try testing.expectEqual(b.?.value, x.value);
                }
            },
            else => {
                try testing.expectEqual(ref.get(k), m.get(k));
                try testing.expectEqual(ref.contains(k), m.contains(k));
            },
        }
        if (i % 100_000 == 0) try checkSame(Map, &m, &ref);
    }
    try checkSame(Map, &m, &ref);
}

test "random insert, remove, lookup against std, 1M operations" {
    try randomOps(HashMap(i64, i64, IntCtx), 1_000_000, 50_000, 1);
    try randomOps(HashMap(i64, i64, IntCtx), 1_000_000, 1_000_000, 2);
}

test "random operations with crowded home groups" {
    try randomOps(HashMap(i64, i64, CrowdedCtx), 300_000, 20_000, 3);
}

test "random operations, nibble masks" {
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .nibble_mask = true }), 300_000, 20_000, 4);
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .nibble_mask = true }), 300_000, 20_000, 5);
}

fn churn(comptime Map: type) !void {
    const gpa = testing.allocator;
    var m: Map = .empty;
    defer m.deinit(gpa);
    const size = 13_400; // near the max load of 13,439 in 15,359 slots
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, i, i);
    const cap = m.capacity();
    var lo: i64 = 0;
    var hi: i64 = size;
    var rehashes: usize = 0;
    var last_ml = m.ml;
    for (0..2_000_000) |_| {
        try testing.expectEqual(lo, m.fetchRemove(lo).?.value);
        lo += 1;
        try m.put(gpa, hi, hi);
        hi += 1;
        if (m.ml > last_ml) rehashes += 1;
        last_ml = m.ml;
        try testing.expectEqual(@as(usize, size), m.count());
    }
    // The table never grows past one doubling at a fixed size.
    try testing.expect(m.capacity() <= 2 * cap + 1);
    var k = lo;
    while (k < hi) : (k += 1) try testing.expectEqual(k, m.get(k).?);
    try testing.expect(!m.contains(lo - 1));
    try testing.expect(rehashes > 0); // drift forced rehashes
}

test "churn at a fixed size" {
    try churn(HashMap(i64, i64, IntCtx));
    try churn(HashMap(i64, i64, CrowdedCtx));
}

test "growth through several doublings" {
    const gpa = testing.allocator;
    var m: HashMap(i64, [8]i64, IntCtx) = .empty;
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), m.capacity());
    try testing.expect(m.get(1) == null);
    var caps: std.ArrayList(usize) = .empty;
    defer caps.deinit(gpa);
    const n = 300_000;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        var v: [8]i64 = undefined;
        for (&v, 0..) |*x, j| x.* = i * 8 + @as(i64, @intCast(j));
        try m.put(gpa, i *% -7046029254386353131, v);
        if (caps.items.len == 0 or caps.items[caps.items.len - 1] != m.capacity())
            try caps.append(gpa, m.capacity());
    }
    // 29 slots first (two groups, all usable), then each doubling.
    try testing.expectEqual(@as(usize, 29), caps.items[0]);
    for (caps.items[1..], caps.items[0 .. caps.items.len - 1]) |c, prev| try testing.expectEqual(prev * 2 + 1, c);
    try testing.expect(caps.items.len >= 10);
    try testing.expectEqual(@as(usize, n), m.count());
    i = 0;
    while (i < n) : (i += 1) {
        const v = m.getPtr(i *% -7046029254386353131).?;
        try testing.expectEqual(i * 8 + 7, v[7]);
    }
    var sum: i64 = 0;
    var it = m.iterator();
    while (it.next()) |e| sum += e.value_ptr[0];
    try testing.expectEqual(@as(i64, 8 * (n * (n - 1) / 2)), sum);
}

test "string keys" {
    const gpa = testing.allocator;
    var m: HashMap([]const u8, i64, TextCtx) = .empty;
    defer m.deinit(gpa);
    const n = 100_000;
    var keys = try gpa.alloc([]u8, 2 * n);
    defer {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }
    for (keys, 0..) |*k, i| k.* = try std.fmt.allocPrint(gpa, "key{d}", .{i});
    for (keys[0..n], 0..) |k, i| try m.put(gpa, k, @intCast(i));
    try testing.expectEqual(@as(usize, n), m.count());
    // A different buffer with the same text finds the same entry.
    var buf: [32]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        try testing.expectEqual(@as(i64, @intCast(i)), m.get(k).?);
    }
    for (keys[n..]) |k| try testing.expect(!m.contains(k));
    try m.put(gpa, "key7", -7);
    try testing.expectEqual(@as(i64, -7), m.get("key7").?);
    try testing.expectEqual(@as(usize, n), m.count());
    for (keys[0 .. n / 2]) |k| try testing.expect(m.fetchRemove(k) != null);
    try testing.expectEqual(@as(usize, n - n / 2), m.count());
    try testing.expect(m.fetchRemove("key0") == null);
    var c: usize = 0;
    var it = m.iterator();
    while (it.next()) |_| c += 1;
    try testing.expectEqual(m.count(), c);
}

test "empty map" {
    var m: HashMap(i64, i64, IntCtx) = .empty;
    try testing.expect(m.get(0) == null);
    try testing.expect(m.fetchRemove(0) == null);
    var it = m.iterator();
    try testing.expect(it.next() == null);
    m.deinit(testing.allocator);
}

test "small table holds 29 before it grows" {
    const gpa = testing.allocator;
    var m: HashMap(i64, i64, IntCtx) = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 29) : (i += 1) try m.put(gpa, i, i);
    try testing.expectEqual(@as(usize, 29), m.capacity());
    try m.put(gpa, 29, 29);
    try testing.expectEqual(@as(usize, 59), m.capacity());
}
