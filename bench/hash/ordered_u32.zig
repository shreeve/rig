//! A ceiling for the ordered `Map` on 32-bit integer keys: bench/hash's
//! `zig-ordered` (ordered.zig) with the key itself in the index in place
//! of a tag, so a probe compares keys in one SIMD step and takes the
//! entry index from the same group, never loading an entry to compare.
//!
//! The entries are as ordered.zig's: one dense array in first-put order,
//! `{key, value}` (an `extern struct`, the key first), a take marking its
//! entry gone in a bitset at the end of the same allocation.
//!
//! The index is groups of `width` u32 lanes: `width - 1` key lanes and an
//! overflow word, each key lane with its entry index in the lane of the
//! same number in the group's slots. With `width` 8 a group is one
//! 64-byte line, its 8 key lanes then its 8 slots; with `width` 16 the
//! keys are one line (15 keys and the overflow word) and the slots the
//! line of the same number in a second array, prefetched with the keys.
//! A free key lane holds `vacant` (all ones); a real key equal to it is
//! held out of the index, its entry index in `esc`. A key's group is its
//! hash's high bits and its overflow class the hash's low 5 bits: an
//! insert that passes a full group sets its class's bit in the group's
//! overflow word, and a probe stops at the first group whose bit for
//! its class is clear. A take writes `vacant` to its lane and, where its
//! group's bit for its class is set, lowers the maximum load by one
//! (boost's anti-drift), as ordered.zig does. Keys are unique, so a
//! group holds a key at most once: a probe takes the first lane that
//! matches, with no loop over candidates.
//!
//! Up to `small` (16) live entries there is no index: a probe compares
//! the entries' keys themselves, eight entries a step, masked by a bit
//! an entry written and not gone (`small_live`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const neon = builtin.cpu.arch == .aarch64;

pub const Options = struct {
    /// Lanes of a group: 8 (keys and slots on one line) or 16 (keys on
    /// one line, slots on another).
    width: u8 = 8,
    /// The index's maximum load, in thousandths of its key lanes.
    max_load: usize = 875,
    /// Entries a map holds before it builds an index.
    small: usize = 16,
    /// How a small map finds a key: SIMD over the entries' keys, or one
    /// key at a time.
    small_scan: enum { simd, scalar } = .simd,
    /// Entries a small probe compares a step: 8 or 16.
    small_chunk: usize = 8,
    first_cap: usize = 16,
    /// The entries: an array of `{key, value}` (aos), or an array of keys
    /// and one of values (soa), whose keys a small map compares 16 at a
    /// time.
    layout: enum { aos, soa } = .aos,
    /// With `width` 16, prefetch the slot line with the key line.
    prefetch: bool = true,
    far_bytes: usize = 1 << 20,
};

pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return Ordered(K, V, Context, .{});
}

pub fn Ordered(comptime K: type, comptime V: type, comptime Context: type, comptime opts: Options) type {
    comptime std.debug.assert(@typeInfo(K) == .int and @bitSizeOf(K) == 32);
    comptime std.debug.assert(opts.width == 8 or opts.width == 16);
    comptime std.debug.assert(opts.small <= 16 and opts.first_cap >= opts.small and opts.first_cap % 16 == 0);
    return struct {
        const Self = @This();

        pub const KV = struct { key: K, value: V };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };
        const ctx: Context = undefined;

        const E = extern struct { key: K, value: V };
        comptime {
            std.debug.assert(@sizeOf(E) % 4 == 0 and @offsetOf(E, "key") == 0);
        }

        const W: usize = opts.width;
        /// The overflow word's lane.
        const ov = W - 1;
        const vacant: u32 = 0xFFFF_FFFF;
        const small_lanes = 32;

        /// NEON narrows a lane's compare to a byte (8 lanes) or a nibble
        /// (16); SSE2 to a bit.
        const LaneMask = if (neon) u64 else @Int(.unsigned, W);
        const lane_shift: u6 = if (!neon) 0 else if (W == 8) 3 else 2;
        const key_lanes: LaneMask = if (!neon)
            (@as(LaneMask, 1) << (W - 1)) - 1
        else if (W == 8)
            0x0001_0101_0101_0101
        else
            0x0111_1111_1111_1111;

        const Keys = [W]u32;
        const Slots = [W]u32;
        /// A group of width 8: its keys, then its slots, one line.
        const Line = extern struct { keys: Keys align(64), slots: Slots };

        /// The entries' block: AoS, `cap` entries `E`; SoA, `cap` keys,
        /// then `cap` values at `vals`. Then the gone bits.
        base: [*]align(ealign) u8 = undefined,
        vals: [*]V = undefined,
        gone: [*]u64 = undefined,
        cap: usize = 0,
        len: usize = 0,
        live: usize = 0,
        dead: usize = 0,
        /// Width 8: the lines; width 16: the key lines, `slots` the slot
        /// lines. None while `groups` is 0.
        keys: [*]align(64) u8 = undefined,
        slots: [*]align(64) Slots = undefined,
        block: []align(64) u8 = &.{},
        groups: usize = 0,
        shift: u6 = 63,
        max_load: usize = 0,
        far: bool = false,
        /// 1 + the entry index of the key `vacant`, held out of the index;
        /// 0 when there is none.
        esc: usize = 0,
        /// A small map's entries written and not gone, a bit each.
        small_live: u32 = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.cap != 0) gpa.free(self.entryBytes());
            if (self.groups != 0) gpa.free(self.block);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.live;
        }

        inline fn bits(k: K) u32 {
            return @bitCast(k);
        }

        inline fn hashKey(k: K) u64 {
            return ctx.hash(k);
        }

        inline fn classBit(h: u64) u32 {
            return @as(u32, 1) << @as(u5, @truncate(h));
        }

        inline fn home(self: *const Self, h: u64) usize {
            return @intCast(h >> self.shift);
        }

        inline fn firstLane(m: LaneMask) usize {
            return @as(usize, @ctz(m)) >> lane_shift;
        }

        inline fn keysOf(self: *const Self, g: usize) *Keys {
            if (W == 8) {
                const lines: [*]Line = @ptrCast(self.keys);
                return &lines[g].keys;
            }
            const ks: [*]Keys = @ptrCast(self.keys);
            return &ks[g];
        }

        inline fn slotsOf(self: *const Self, g: usize) *Slots {
            if (W == 8) {
                const lines: [*]Line = @ptrCast(self.keys);
                return &lines[g].slots;
            }
            return &self.slots[g];
        }

        /// Every lane of `ks` (the overflow word's too) that holds `x`.
        inline fn match(ks: *const Keys, x: u32) LaneMask {
            const v: @Vector(W, u32) = ks.*;
            return @intCast(laneMask(W, v == @as(@Vector(W, u32), @splat(x))));
        }

        /// A compare's lanes as a mask, `laneShift(n)` bits a lane: NEON
        /// narrows 8 lanes to a byte each, 16 to a nibble; SSE2 a bit.
        inline fn laneMask(comptime n: usize, eq: @Vector(n, bool)) u64 {
            if (!neon) return @as(@Int(.unsigned, n), @bitCast(eq));
            const wide = @select(u32, eq, @as(@Vector(n, u32), @splat(0xFFFF_FFFF)), @as(@Vector(n, u32), @splat(0)));
            if (n == 8) {
                const b: @Vector(8, u8) = @truncate(wide);
                return @as(u64, @bitCast(b)) & 0x0101_0101_0101_0101;
            }
            const b: @Vector(16, u8) = @truncate(wide);
            const halves: @Vector(8, u16) = @bitCast(b);
            const nib: @Vector(8, u8) = @truncate(halves >> @splat(4));
            return @as(u64, @bitCast(nib)) & 0x1111_1111_1111_1111;
        }

        fn laneShift(comptime n: usize) u6 {
            return if (!neon) 0 else if (n == 8) 3 else 2;
        }

        // the entries' block ////////////////////////////////////////////////

        const soa = opts.layout == .soa;
        const ealign = @max(@alignOf(E), 8);

        fn goneWords(n: usize) usize {
            return (n + 63) / 64;
        }

        /// Where the values start, in SoA.
        fn valsOffset(cap: usize) usize {
            return std.mem.alignForward(usize, cap * 4, @alignOf(V));
        }

        fn goneOffset(cap: usize) usize {
            const end = if (soa) valsOffset(cap) + cap * @sizeOf(V) else cap * @sizeOf(E);
            return std.mem.alignForward(usize, end, 8);
        }

        fn blockBytes(cap: usize) usize {
            return goneOffset(cap) + goneWords(cap) * 8;
        }

        fn entryBytes(self: *const Self) []align(ealign) u8 {
            return self.base[0..blockBytes(self.cap)];
        }

        fn goneAt(p: [*]align(ealign) u8, cap: usize) [*]u64 {
            return @ptrCast(@alignCast(p + goneOffset(cap)));
        }

        inline fn keyArr(self: *const Self) [*]K {
            return @ptrCast(self.base);
        }

        inline fn aos(self: *const Self) [*]E {
            return @ptrCast(self.base);
        }

        inline fn keyAt(self: *const Self, j: usize) K {
            return if (soa) self.keyArr()[j] else self.aos()[j].key;
        }

        inline fn keyPtrIn(base: [*]align(ealign) u8, j: usize) *K {
            if (soa) {
                const ks: [*]K = @ptrCast(base);
                return &ks[j];
            }
            const es: [*]E = @ptrCast(base);
            return &es[j].key;
        }

        inline fn valPtrIn(base: [*]align(ealign) u8, vals: [*]V, j: usize) *V {
            if (soa) return &vals[j];
            const es: [*]E = @ptrCast(base);
            return &es[j].value;
        }

        inline fn keyPtr(self: *const Self, j: usize) *K {
            return if (soa) &self.keyArr()[j] else &self.aos()[j].key;
        }

        inline fn valPtr(self: *const Self, j: usize) *V {
            return if (soa) &self.vals[j] else &self.aos()[j].value;
        }

        inline fn setEntry(self: *Self, j: usize, k: K, v: V) void {
            if (soa) {
                self.keyArr()[j] = k;
                self.vals[j] = v;
            } else self.aos()[j] = .{ .key = k, .value = v };
        }

        fn setBase(self: *Self, p: [*]align(ealign) u8, cap: usize) void {
            self.base = p;
            if (soa) self.vals = @ptrCast(@alignCast(p + valsOffset(cap)));
            self.gone = goneAt(p, cap);
        }

        fn resizeEntries(self: *Self, gpa: Allocator, new_cap: usize) Allocator.Error!void {
            if (new_cap > std.math.maxInt(u32)) @panic("ordered_u32: too many entries");
            const old_cap = self.cap;
            const old_words = goneWords(old_cap);
            const new_words = goneWords(new_cap);
            if (old_cap == 0) {
                const b = try gpa.alignedAlloc(u8, .fromByteUnits(ealign), blockBytes(new_cap));
                self.setBase(b.ptr, new_cap);
                @memset(self.gone[0..new_words], 0);
            } else {
                const b = try gpa.realloc(self.entryBytes(), blockBytes(new_cap));
                // The gone bits, highest, move first; then the values.
                const old_gone = goneAt(b.ptr, old_cap);
                const new_gone = goneAt(b.ptr, new_cap);
                std.mem.copyBackwards(u64, new_gone[0..old_words], old_gone[0..old_words]);
                @memset(new_gone[old_words..new_words], 0);
                if (soa) {
                    const vb = old_cap * @sizeOf(V);
                    std.mem.copyBackwards(u8, (b.ptr + valsOffset(new_cap))[0..vb], (b.ptr + valsOffset(old_cap))[0..vb]);
                }
                self.setBase(b.ptr, new_cap);
            }
            self.cap = new_cap;
        }

        inline fn isGone(self: *const Self, j: usize) bool {
            return (self.gone[j >> 6] >> @intCast(j & 63)) & 1 != 0;
        }

        // the index's block /////////////////////////////////////////////////

        fn indexBytes(groups: usize) usize {
            return if (W == 8) 64 * groups else 128 * groups;
        }

        /// The bytes the index takes, for the report.
        pub fn memoryBytes(self: *const Self) usize {
            return (if (self.cap != 0) blockBytes(self.cap) else 0) + (if (self.groups != 0) indexBytes(self.groups) else 0);
        }

        fn maxLoad(groups: usize) usize {
            return (W - 1) * groups * opts.max_load / 1000;
        }

        /// The groups that hold `n` live entries at most 0.6 full.
        fn groupsFor(n: usize) usize {
            var g: usize = 2;
            while (g * (W - 1) * 6 < n * 10) g *= 2;
            return g;
        }

        /// Every key lane free, every overflow word clear.
        fn clearKeys(self: *Self) void {
            var fresh: Keys = @splat(vacant);
            fresh[ov] = 0;
            for (0..self.groups) |g| self.keysOf(g).* = fresh;
        }

        fn setIndex(self: *Self, b: []align(64) u8, groups: usize) void {
            self.block = b;
            self.keys = b.ptr;
            if (W == 16) self.slots = @ptrCast(@alignCast(b.ptr + 64 * groups));
            self.groups = groups;
            self.shift = @intCast(@as(u32, 64) - std.math.log2_int(usize, groups));
            self.max_load = maxLoad(groups);
            self.far = indexBytes(groups) > opts.far_bytes;
            self.clearKeys();
        }

        /// The first free lane from group `start` on takes key `x` and
        /// entry `j`; each full group on the way marks `h`'s class.
        inline fn place(self: *const Self, start: usize, x: u32, h: u64, j: usize) void {
            const mask = self.groups - 1;
            var g = start;
            var step: usize = 0;
            while (true) {
                const ks = self.keysOf(g);
                const free = match(ks, vacant) & key_lanes;
                if (free != 0) {
                    const lane = firstLane(free);
                    ks[lane] = x;
                    self.slotsOf(g)[lane] = @intCast(j);
                    return;
                }
                ks[ov] |= classBit(h);
                step += 1;
                g = (g + step) & mask;
            }
        }

        noinline fn rebuild(self: *Self, gpa: Allocator, groups: usize) Allocator.Error!void {
            const b = try gpa.alignedAlloc(u8, .@"64", indexBytes(groups));
            if (self.groups != 0) gpa.free(self.block);
            if (self.dead != 0) self.moveLive(null);
            self.setIndex(b, groups);
            self.fill();
        }

        /// Place every entry, in order; a far index hashes sixteen
        /// entries ahead and prefetches the group each lands in.
        fn fill(self: *Self) void {
            const shift = self.shift;
            const n = self.len;
            self.esc = 0;
            if (!self.far) {
                for (0..n) |j| {
                    const x = bits(self.keyAt(j));
                    if (x == vacant) {
                        self.esc = j + 1;
                        continue;
                    }
                    const h = hashKey(self.keyAt(j));
                    self.place(@intCast(h >> shift), x, h, j);
                }
                return;
            }
            const ahead = 16;
            var ring: [ahead]u64 = undefined;
            var it: usize = 0;
            while (it < ahead and it < n) : (it += 1) {
                const h = hashKey(self.keyAt(it));
                ring[it] = h;
                @prefetch(self.keysOf(@intCast(h >> shift)), .{ .rw = .write });
                if (W == 16) @prefetch(self.slotsOf(@intCast(h >> shift)), .{ .rw = .write });
            }
            for (0..n) |j| {
                const h = ring[j % ahead];
                if (it != n) {
                    const nh = hashKey(self.keyAt(it));
                    ring[j % ahead] = nh;
                    @prefetch(self.keysOf(@intCast(nh >> shift)), .{ .rw = .write });
                    if (W == 16) @prefetch(self.slotsOf(@intCast(nh >> shift)), .{ .rw = .write });
                    it += 1;
                }
                const x = bits(self.keyAt(j));
                if (x == vacant) {
                    self.esc = j + 1;
                    continue;
                }
                self.place(@intCast(h >> shift), x, h, j);
            }
        }

        inline fn moveRange(self: *Self, dst: usize, src: usize, n: usize) void {
            if (soa) {
                std.mem.copyForwards(K, self.keyArr()[dst .. dst + n], self.keyArr()[src .. src + n]);
                std.mem.copyForwards(V, self.vals[dst .. dst + n], self.vals[src .. src + n]);
            } else std.mem.copyForwards(E, self.aos()[dst .. dst + n], self.aos()[src .. src + n]);
        }

        fn moveLive(self: *Self, before: ?[]u32) void {
            const n = self.len;
            const gone = self.gone;
            const words = goneWords(n);
            var dst: usize = 0;
            var dropped: u32 = 0;
            for (0..words) |w| {
                if (before) |b| b[w] = dropped;
                const base = w * 64;
                const lim = @min(64, n - base);
                const g = gone[w];
                if (g == 0) {
                    if (dst != base) self.moveRange(dst, base, lim);
                    dst += lim;
                } else {
                    dropped += @popCount(g);
                    var keep = ~g & lowBits(lim);
                    while (keep != 0) : (keep &= keep - 1) {
                        self.moveRange(dst, base + @ctz(keep), 1);
                        dst += 1;
                    }
                }
            }
            if (before == null) @memset(gone[0..words], 0);
            self.len = dst;
            self.dead = 0;
        }

        inline fn lowBits(n: usize) u64 {
            return if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
        }

        inline fn renumber(j: usize, gone: [*]const u64, before: []const u32) usize {
            const w = j >> 6;
            return j - before[w] - @popCount(gone[w] & lowBits(j & 63));
        }

        /// Compact the entries under the same index and renumber every
        /// slot by the gone entries below it.
        fn compact(self: *Self, gpa: Allocator) Allocator.Error!void {
            const words = goneWords(self.len);
            var stack: [64]u32 = undefined;
            const before = if (words <= stack.len) stack[0..words] else try gpa.alloc(u32, words);
            defer if (words > stack.len) gpa.free(before);
            const gone = self.gone;
            self.moveLive(before);
            for (0..self.groups) |g| {
                var full = ~match(self.keysOf(g), vacant) & key_lanes;
                const sl = self.slotsOf(g);
                while (full != 0) : (full &= full - 1) {
                    const lane = firstLane(full);
                    sl[lane] = @intCast(renumber(sl[lane], gone, before));
                }
            }
            if (self.esc != 0) self.esc = renumber(self.esc - 1, gone, before) + 1;
            @memset(gone[0..words], 0);
        }

        noinline fn reserveOne(self: *Self, gpa: Allocator) Allocator.Error!void {
            if (self.live >= self.max_load) {
                try self.rebuild(gpa, @max(groupsFor(self.live + 1), self.groups));
            }
            if (self.len == self.cap) {
                if (self.dead != 0 and self.dead >= self.cap / 4) {
                    try self.compact(gpa);
                } else {
                    try self.resizeEntries(gpa, 2 * self.cap);
                }
            }
        }

        fn reset(self: *Self) void {
            @memset(self.gone[0..goneWords(self.len)], 0);
            self.len = 0;
            self.live = 0;
            self.dead = 0;
            self.esc = 0;
            self.small_live = 0;
            if (self.groups == 0) return;
            self.clearKeys();
            self.max_load = maxLoad(self.groups);
        }

        // finding ///////////////////////////////////////////////////////////

        const Found = struct { g: usize, lane: usize, j: usize };

        const stride = @sizeOf(E) / 4;
        const chunk = if (soa) 16 else opts.small_chunk;

        /// `chunk` keys from entry `base` on, as one vector.
        inline fn smallKeys(self: *const Self, base: usize) @Vector(chunk, u32) {
            if (soa or stride == 1) {
                const p: *const [chunk]u32 = @ptrCast(self.keyArr() + base);
                return p.*;
            }
            if (stride == 2) {
                // {u32 key, u32 value}: the low halves of 64-bit words.
                const p: *const [chunk]u64 = @ptrCast(@alignCast(self.aos() + base));
                const w: @Vector(chunk, u64) = p.*;
                return @truncate(w);
            }
            comptime std.debug.assert(stride == 4);
            const p: *const [2 * chunk]u64 = @ptrCast(@alignCast(self.aos() + base));
            const w: @Vector(2 * chunk, u64) = p.*;
            const even = comptime blk: {
                var e: [chunk]i32 = undefined;
                for (0..chunk) |i| e[i] = 2 * i;
                break :blk e;
            };
            const lo: @Vector(chunk, u64) = @shuffle(u64, w, undefined, even);
            return @truncate(lo);
        }

        /// The entry of `k` in a small map: its entries' keys, `chunk`
        /// a step; a lane that matches counts if its entry is live.
        inline fn findSmall(self: *const Self, k: K) ?usize {
            const x = bits(k);
            if (opts.small_scan == .scalar) {
                for (0..self.len) |i| {
                    if ((self.small_live >> @intCast(i)) & 1 != 0 and bits(self.keyAt(i)) == x) return i;
                }
                return null;
            }
            var base: usize = 0;
            while (base < self.len) : (base += chunk) {
                var m = laneMask(chunk, self.smallKeys(base) == @as(@Vector(chunk, u32), @splat(x)));
                while (m != 0) : (m &= m - 1) {
                    const i = base + (@as(usize, @ctz(m)) >> laneShift(chunk));
                    if ((self.small_live >> @intCast(i)) & 1 != 0) return i;
                }
            }
            return null;
        }

        inline fn probeFrom(self: *const Self, x: u32, h: u64, start: usize) ?Found {
            const mask = self.groups - 1;
            const bit = classBit(h);
            var g = start;
            var step: usize = 1;
            while (true) {
                const ks = self.keysOf(g);
                const m = match(ks, x) & key_lanes;
                if (m != 0) {
                    const lane = firstLane(m);
                    return .{ .g = g, .lane = lane, .j = self.slotsOf(g)[lane] };
                }
                if (ks[ov] & bit == 0) return null;
                step += 1;
                if (step > mask + 1) return null;
                g = (g + step) & mask;
            }
        }

        noinline fn probePastHome(self: *const Self, x: u32, h: u64, start: usize) ?Found {
            return self.probeFrom(x, h, start);
        }

        /// The entry of key bits `x` (not `vacant`), whose hash is `h`.
        inline fn findIndexed(self: *const Self, x: u32, h: u64, comptime walk_inline: bool) ?Found {
            const g = self.home(h);
            if (W == 16 and opts.prefetch) @prefetch(self.slotsOf(g), .{});
            const ks = self.keysOf(g);
            const m = match(ks, x) & key_lanes;
            if (m != 0) {
                const lane = firstLane(m);
                return .{ .g = g, .lane = lane, .j = self.slotsOf(g)[lane] };
            }
            if (ks[ov] & classBit(h) != 0) {
                @branchHint(.unlikely);
                const next = (g + 1) & (self.groups - 1);
                if (walk_inline) return self.probeFrom(x, h, next);
                return self.probePastHome(x, h, next);
            }
            return null;
        }

        inline fn findEntry(self: *const Self, k: K) ?usize {
            if (self.groups == 0) return self.findSmall(k);
            const x = bits(k);
            if (x == vacant) {
                @branchHint(.unlikely);
                return if (self.esc != 0) self.esc - 1 else null;
            }
            const f = self.findIndexed(x, hashKey(k), false) orelse return null;
            return f.j;
        }

        pub inline fn get(self: *const Self, k: K) ?V {
            const j = self.findEntry(k) orelse return null;
            return self.valPtr(j).*;
        }

        pub inline fn getPtr(self: *const Self, k: K) ?*V {
            const j = self.findEntry(k) orelse return null;
            return self.valPtr(j);
        }

        pub inline fn contains(self: *const Self, k: K) bool {
            return self.findEntry(k) != null;
        }

        // insert ////////////////////////////////////////////////////////////

        pub inline fn put(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.groups == 0) return self.putSmall(gpa, k, v);
            const x = bits(k);
            if (x == vacant) return self.putEsc(gpa, k, v);
            const h = hashKey(k);
            const g = self.home(h);
            if (W == 16 and opts.prefetch) @prefetch(self.slotsOf(g), .{});
            const ks = self.keysOf(g);
            const m = match(ks, x) & key_lanes;
            if (m != 0) {
                self.valPtr(self.slotsOf(g)[firstLane(m)]).* = v;
                return;
            }
            if (ks[ov] & classBit(h) == 0) {
                const free = match(ks, vacant) & key_lanes;
                const j = self.len;
                if (free != 0 and j < self.cap and self.live < self.max_load) {
                    const lane = firstLane(free);
                    self.setEntry(j, k, v);
                    self.len = j + 1;
                    self.live += 1;
                    ks[lane] = x;
                    self.slotsOf(g)[lane] = @intCast(j);
                    return;
                }
            }
            return self.putSlow(gpa, k, v, h);
        }

        noinline fn putSlow(self: *Self, gpa: Allocator, k: K, v: V, h: u64) Allocator.Error!void {
            const x = bits(k);
            if (self.findIndexed(x, h, true)) |f| {
                self.valPtr(f.j).* = v;
                return;
            }
            try self.reserveOne(gpa);
            const j = self.len;
            self.setEntry(j, k, v);
            self.len = j + 1;
            self.live += 1;
            self.place(self.home(h), x, h, j);
        }

        /// The key `vacant`, held out of the index.
        noinline fn putEsc(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.esc != 0) {
                self.valPtr(self.esc - 1).* = v;
                return;
            }
            try self.reserveOne(gpa);
            const j = self.len;
            self.setEntry(j, k, v);
            self.len = j + 1;
            self.live += 1;
            self.esc = j + 1;
        }

        inline fn putSmall(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.findSmall(k)) |i| {
                self.valPtr(i).* = v;
                return;
            }
            const j = self.len;
            if (j < self.cap and j < small_lanes and self.live < opts.small) {
                self.setEntry(j, k, v);
                self.small_live |= @as(u32, 1) << @intCast(j);
                self.len = j + 1;
                self.live += 1;
                return;
            }
            return self.putSmallSlow(gpa, k, v);
        }

        noinline fn putSmallSlow(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.cap == 0) {
                try self.resizeEntries(gpa, opts.first_cap);
            } else if (self.live < opts.small and self.len == self.cap and self.cap < small_lanes) {
                try self.resizeEntries(gpa, @min(2 * self.cap, small_lanes));
            } else if (self.live < opts.small) {
                self.moveLive(null);
                self.small_live = @truncate(lowBits(self.len));
            } else {
                try self.rebuild(gpa, groupsFor(2 * self.cap));
                self.small_live = 0;
                if (self.len == self.cap) try self.resizeEntries(gpa, 2 * self.cap);
                const j = self.len;
                self.setEntry(j, k, v);
                self.len = j + 1;
                self.live += 1;
                const x = bits(k);
                if (x == vacant) {
                    self.esc = j + 1;
                } else {
                    const h = hashKey(k);
                    self.place(self.home(h), x, h, j);
                }
                return;
            }
            const j = self.len;
            self.setEntry(j, k, v);
            self.small_live |= @as(u32, 1) << @intCast(j);
            self.len = j + 1;
            self.live += 1;
        }

        // take //////////////////////////////////////////////////////////////

        pub fn fetchRemove(self: *Self, k: K) ?KV {
            var j: usize = undefined;
            if (self.groups == 0) {
                j = self.findSmall(k) orelse return null;
                self.small_live &= ~(@as(u32, 1) << @intCast(j));
            } else if (bits(k) == vacant) {
                if (self.esc == 0) return null;
                j = self.esc - 1;
                self.esc = 0;
            } else {
                const h = hashKey(k);
                const f = self.findIndexed(bits(k), h, true) orelse return null;
                const ks = self.keysOf(f.g);
                ks[f.lane] = vacant;
                if (ks[ov] & classBit(h) != 0) self.max_load -= 1;
                j = f.j;
            }
            const kv: KV = .{ .key = self.keyAt(j), .value = self.valPtr(j).* };
            self.dropEntry(j);
            return kv;
        }

        inline fn dropEntry(self: *Self, j: usize) void {
            self.live -= 1;
            if (self.live == 0) {
                self.reset();
            } else if (j + 1 == self.len) {
                var n = j;
                while (self.isGone(n - 1)) {
                    n -= 1;
                    self.gone[n >> 6] &= ~(@as(u64, 1) << @intCast(n & 63));
                    self.dead -= 1;
                }
                self.len = n;
            } else {
                self.gone[j >> 6] |= @as(u64, 1) << @intCast(j & 63);
                self.dead += 1;
            }
        }

        // iteration (as ordered.zig) ////////////////////////////////////////

        const Cursor = struct {
            base: [*]align(ealign) u8,
            vals: [*]V,
            gone: [*]const u64,
            len: usize,
            i: usize,
            end: usize,
            holes: bool,

            fn init(m: *const Self) Cursor {
                const holes = m.dead != 0;
                return .{ .base = m.base, .vals = m.vals, .gone = m.gone, .len = m.len, .i = 0, .end = if (holes) 0 else m.len, .holes = holes };
            }

            inline fn step(c: *Cursor) usize {
                if (c.i == c.end) {
                    if (!c.holes) return c.len;
                    const r = nextRun(c.gone, c.len, c.i);
                    if (r.start == c.len) return c.len;
                    c.i = r.start;
                    c.end = r.end;
                }
                const j = c.i;
                c.i = j + 1;
                return j;
            }
        };

        const Run = struct { start: usize, end: usize };

        noinline fn nextRun(gone: [*]const u64, len: usize, from: usize) Run {
            var j = from;
            while (j < len) {
                const w = j >> 6;
                const live_bits = ~gone[w] >> @intCast(j & 63);
                if (live_bits != 0) {
                    j += @ctz(live_bits);
                    break;
                }
                j = (w + 1) * 64;
            }
            if (j >= len) return .{ .start = len, .end = len };
            var e = j;
            while (e < len) {
                const w = e >> 6;
                const gone_bits = gone[w] >> @intCast(e & 63);
                if (gone_bits != 0) {
                    e += @ctz(gone_bits);
                    break;
                }
                e = (w + 1) * 64;
            }
            return .{ .start = j, .end = @min(e, len) };
        }

        pub const Iterator = struct {
            c: Cursor,
            pub inline fn next(it: *Iterator) ?Entry {
                const j = it.c.step();
                if (j == it.c.len) return null;
                return .{ .key_ptr = keyPtrIn(it.c.base, j), .value_ptr = valPtrIn(it.c.base, it.c.vals, j) };
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .c = .init(self) };
        }

        pub const KeyIterator = struct {
            c: Cursor,
            pub inline fn next(it: *KeyIterator) ?*K {
                const j = it.c.step();
                if (j == it.c.len) return null;
                return keyPtrIn(it.c.base, j);
            }
        };

        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{ .c = .init(self) };
        }

        pub const ValueIterator = struct {
            c: Cursor,
            pub inline fn next(it: *ValueIterator) ?*V {
                const j = it.c.step();
                if (j == it.c.len) return null;
                return valPtrIn(it.c.base, it.c.vals, j);
            }
        };

        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .c = .init(self) };
        }

        // checking //////////////////////////////////////////////////////////

        /// The invariants, for tests: the counts agree; every live entry
        /// has exactly one key lane (or `esc`), on its probe sequence;
        /// every group it walked past marks its class.
        pub fn verify(self: *const Self, gpa: Allocator) !void {
            if (self.live + self.dead != self.len) return error.Corrupt;
            if (self.len > self.cap) return error.Corrupt;
            if (self.len != 0 and self.isGone(self.len - 1)) return error.Corrupt;
            if (self.groups == 0) {
                if (self.len > small_lanes or self.live > opts.small) return error.Corrupt;
                for (0..small_lanes) |i| {
                    const on = (self.small_live >> @intCast(i)) & 1 != 0;
                    const want = i < self.len and !self.isGone(i);
                    if (on != want) return error.Corrupt;
                }
                return;
            }
            if (self.live > self.max_load + 1) return error.Corrupt;
            const named = try gpa.alloc(u8, self.len);
            defer gpa.free(named);
            @memset(named, 0);
            var full: usize = 0;
            for (0..self.groups) |g| for (0..W - 1) |lane| {
                const x = self.keysOf(g)[lane];
                if (x == vacant) continue;
                full += 1;
                const j = self.slotsOf(g)[lane];
                if (j >= self.len or self.isGone(j)) return error.Corrupt;
                if (named[j] != 0) return error.Corrupt;
                named[j] = 1;
                if (bits(self.keyAt(j)) != x) return error.Corrupt;
            };
            if (self.esc != 0) {
                const j = self.esc - 1;
                if (j >= self.len or self.isGone(j) or bits(self.keyAt(j)) != vacant) return error.Corrupt;
                full += 1;
            }
            if (full != self.live) return error.Corrupt;
            const mask = self.groups - 1;
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const x = bits(self.keyAt(j));
                if (x == vacant) continue;
                const h = hashKey(self.keyAt(j));
                var g: usize = @intCast(h >> self.shift);
                var step: usize = 0;
                while (true) {
                    var hit = false;
                    for (0..W - 1) |lane| {
                        if (self.keysOf(g)[lane] == x and self.slotsOf(g)[lane] == j) hit = true;
                    }
                    if (hit) break;
                    if (self.keysOf(g)[ov] & classBit(h) == 0) return error.Corrupt;
                    step += 1;
                    if (step > mask) return error.Corrupt;
                    g = (g + step) & mask;
                }
            }
        }
    };
}

// tests //////////////////////////////////////////////////////////////////////

const testing = std.testing;

/// Rig's hash of an Int (`hashWord`), on a u32 widened.
pub const U32Ctx = struct {
    pub fn hash(_: U32Ctx, x: u32) u64 {
        const p = @as(u128, @as(u64, x) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
        return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
    }
    pub fn eql(_: U32Ctx, a: u32, b: u32) bool {
        return a == b;
    }
};

/// Crowds keys into a few groups and classes, so overflow bits, walks
/// past home and anti-drift all run.
const CrowdCtx = struct {
    pub fn hash(_: CrowdCtx, x: u32) u64 {
        const u: u64 = x;
        return ((u % 7) << 61) | ((u % 3) << 3) | (u & 0x7);
    }
    pub fn eql(_: CrowdCtx, a: u32, b: u32) bool {
        return a == b;
    }
};

fn Model(comptime K: type) type {
    return struct {
        order: std.ArrayList(K) = .empty,
        values: std.AutoHashMapUnmanaged(K, i64) = .empty,

        fn deinit(m: *@This(), gpa: Allocator) void {
            m.order.deinit(gpa);
            m.values.deinit(gpa);
        }

        fn put(m: *@This(), gpa: Allocator, k: K, v: i64) !void {
            const gop = try m.values.getOrPut(gpa, k);
            if (!gop.found_existing) try m.order.append(gpa, k);
            gop.value_ptr.* = v;
        }

        fn take(m: *@This(), k: K) ?i64 {
            const kv = m.values.fetchRemove(k) orelse return null;
            const i = std.mem.indexOfScalar(K, m.order.items, k).?;
            _ = m.order.orderedRemove(i);
            return kv.value;
        }
    };
}

fn expectOrder(map: anytype, model: anytype) !void {
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        try testing.expect(i < model.order.items.len);
        try testing.expectEqual(model.order.items[i], e.key_ptr.*);
        try testing.expectEqual(model.values.get(e.key_ptr.*).?, e.value_ptr.*);
    }
    try testing.expectEqual(model.order.items.len, i);
}

fn randomAgainstModel(comptime M: type, ops: usize, key_range: u64, check_every: usize, seed: u64) !void {
    const gpa = testing.allocator;
    var m: M = .{};
    defer m.deinit(gpa);
    var model: Model(u32) = .{};
    defer model.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (0..ops) |i| {
        // Keys near both ends, so the key `vacant` (all ones) comes up.
        const r = rnd.uintLessThan(u64, key_range);
        const k: u32 = if (r & 1 == 0) @intCast(r >> 1) else 0xFFFF_FFFF - @as(u32, @intCast(r >> 1));
        switch (rnd.uintLessThan(u8, 10)) {
            0...3 => {
                const v: i64 = @intCast(i);
                try m.put(gpa, k, v);
                try model.put(gpa, k, v);
            },
            4...5 => {
                const a = m.fetchRemove(k);
                const b = model.take(k);
                try testing.expectEqual(b == null, a == null);
                if (a) |kv| {
                    try testing.expectEqual(k, kv.key);
                    try testing.expectEqual(b.?, kv.value);
                }
            },
            6...7 => try testing.expectEqual(model.values.get(k), m.get(k)),
            else => try testing.expectEqual(model.values.contains(k), m.contains(k)),
        }
        try testing.expectEqual(model.values.count(), m.count());
        if (check_every != 0 and i % check_every == 0) {
            try m.verify(gpa);
            try expectOrder(&m, &model);
        }
    }
    try m.verify(gpa);
    try expectOrder(&m, &model);
}

test "random operations against a model of the order" {
    inline for (.{ 8, 16 }) |w| {
        inline for (.{ .aos, .soa }) |lay| {
            inline for (.{ .simd, .scalar }) |scan| {
                const M = Ordered(u32, i64, U32Ctx, .{ .width = w, .small_scan = scan, .layout = lay });
                try randomAgainstModel(M, 300_000, 6_000, 5_000, 0x5eed);
                try randomAgainstModel(M, 200_000, 80, 101, 1);
                try randomAgainstModel(M, 100_000, 40, 7, 2);
            }
            try randomAgainstModel(Ordered(u32, i64, CrowdCtx, .{ .width = w, .layout = lay }), 200_000, 6_000, 997, 3);
            try randomAgainstModel(Ordered(u32, i64, CrowdCtx, .{ .width = w, .layout = lay }), 100_000, 1_000, 97, 4);
        }
        try randomAgainstModel(Ordered(u32, i64, U32Ctx, .{ .width = w, .small_chunk = 16 }), 200_000, 80, 101, 5);
    }
}

test "growth to many keys, takes, and a refill" {
    const gpa = testing.allocator;
    inline for (.{ .{ 8, .aos, 8 }, .{ 16, .aos, 16 }, .{ 8, .soa, 8 }, .{ 16, .soa, 8 } }) |c| {
        var m: Ordered(u32, u32, U32Ctx, .{ .width = c[0], .layout = c[1], .small_chunk = c[2] }) = .{};
        defer m.deinit(gpa);
        for (0..100_000) |i| try m.put(gpa, @intCast(i * 7), @intCast(i));
        try m.verify(gpa);
        for (0..100_000) |i| try testing.expectEqual(@as(?u32, @intCast(i)), m.get(@intCast(i * 7)));
        for (0..100_000) |i| if (i % 3 != 0) {
            try testing.expect(m.fetchRemove(@intCast(i * 7)) != null);
        };
        try m.verify(gpa);
        for (100_000..150_000) |i| try m.put(gpa, @intCast(i * 7), @intCast(i));
        try m.verify(gpa);
        var it = m.iterator();
        var prev: u32 = 0;
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) {
            if (n != 0) try testing.expect(e.value_ptr.* > prev);
            prev = e.value_ptr.*;
        }
        try testing.expectEqual(m.count(), n);
        // a small map of u32 values, turned over
        var sm: Ordered(u32, u32, U32Ctx, .{ .width = c[0], .layout = c[1], .small_chunk = c[2] }) = .{};
        defer sm.deinit(gpa);
        for (0..2000) |i| {
            try sm.put(gpa, @intCast(i), @intCast(i));
            if (i >= 10) try testing.expectEqual(@as(u32, @intCast(i - 10)), sm.fetchRemove(@intCast(i - 10)).?.value);
            try testing.expect(sm.get(@intCast(i - @min(i, 9))) != null);
            try testing.expect(sm.get(@intCast(i + 1)) == null);
            try sm.verify(gpa);
        }
    }
}
