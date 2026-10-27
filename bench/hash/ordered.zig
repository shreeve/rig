//! The design Rig's built-in ordered `Map` will take (the hash-race
//! panel's design (a), docs/history/records/2026-10/hash-race/panel/
//! design.md §1), for bench/hash's `zig-ordered`.
//!
//! The entries sit in one dense array in the order their keys were first
//! put, `{key, value}` with no optional; a key over 8 bytes also keeps its
//! hash in its entry. A take marks its entry gone in a bitset kept at the
//! end of the same allocation, so the order survives every take, and a
//! walk skips the gone entries by runs. The entries are compacted only
//! when the array is full and a quarter of it is gone, when the index
//! grows, or when a take empties the map.
//!
//! The index is split: groups of 16 tag bytes (15 tags and an overflow
//! byte, boost's group) in one array, and beside them a line of sixteen
//! `u32` entry indexes a group (15 used). A key's group is its hash's high
//! bits and its tag the low byte, 0 made 1; 0 is a free lane. An insert
//! that passes a full group sets the bit `tag & 7` of its overflow byte,
//! and a probe stops at the first group whose bit for the class is clear.
//! A take writes 0 to its tag and, when the group's bit for its class is
//! set, lowers the maximum load by one (boost's anti-drift), so no
//! tombstone ever piles up: a rebuild forced by drift sizes the index so
//! the live entries fill at most 0.6 of it.
//!
//! A lookup prefetches its group's slot line with its tags; the home
//! group is probed inline and the walk past it out of line.
//!
//! Up to `small` (16) live entries there is no index: a tag vector in the
//! map itself, whose lane `i` is entry `i`'s tag (0 when gone or not
//! written), finds a key by one match. A small map may write up to twice
//! that many entries, so a turnover compacts once every `small` takes.
//! At the next live key it builds its index, sized for the entries'
//! next capacity.
//!
//! `Ordered(K, V, Context, .{ .checked = true })` is the Rig-shaped
//! variant: it keeps the tests safe Rig would keep (compiler.md §2 and
//! §3 step 0): every entry index read from the index or a small map's
//! tags is tested against the entries written, every prefetch is
//! range-tested, a home group is masked, and a walk tests its index.
//! Its walk past the home group stays inline (zig-ordered.md,
//! experiment 12).
//!
//! The record of every choice and its measurement is
//! docs/history/records/2026-10/hash-race/zig-ordered.md.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// NEON's 16-lane compare is narrowed to a nibble a lane (`shrn #4`);
/// SSE2's is `pmovmskb`, a bit a lane.
const neon = builtin.cpu.arch == .aarch64;
const LaneMask = if (neon) u64 else u32;
const lane_shift: u6 = if (neon) 2 else 0;
/// The 15 tag lanes of a group; lane 15 is the overflow byte.
const tag_lanes: LaneMask = if (neon) 0x0111_1111_1111_1111 else 0x7FFF;

const Group = [16]u8;
const Slots = [16]u32;

pub const Prefetch = enum { never, far, always };

pub const Options = struct {
    /// Keep the tests safe Rig would keep.
    checked: bool = false,
    /// Entries a map holds before it builds an index.
    small: usize = 16,
    /// How a small map finds a key: by its tags, a lane an entry, or by
    /// comparing keys one at a time to the first match.
    small_scan: enum { tags, scalar } = .tags,
    /// The entries' first capacity; at least `small`.
    first_cap: usize = 16,
    /// When a lookup prefetches its group's slot line with its tags.
    prefetch: Prefetch = .always,
    /// An index larger than this is far: its lookups prefetch, and a
    /// rebuild prefetches the groups it fills ahead.
    far_bytes: usize = 1 << 20,
    /// The index's maximum load, in thousandths of its lanes.
    max_load: usize = 875,
    /// Superblocks: four groups' tags on one line, then their four slot
    /// lines, 320 bytes, so a hit's two lines share a page; else the
    /// tags and the slots are two arrays.
    superblocks: bool = false,
};

pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return Ordered(K, V, Context, .{});
}

pub fn Ordered(comptime K: type, comptime V: type, comptime Context: type, comptime opts: Options) type {
    comptime std.debug.assert(opts.first_cap >= opts.small and opts.small <= 16 and opts.small >= 1);
    return struct {
        const Self = @This();

        pub const KV = struct { key: K, value: V };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        const ctx: Context = undefined;

        /// A key over 8 bytes keeps its hash in its entry.
        pub const stores_hash = @sizeOf(K) > 8;
        /// A slice key compares through a call: the walk past the home
        /// group goes out of line.
        const compare_is_call = @typeInfo(K) == .pointer;

        const E = if (stores_hash)
            struct { key: K, value: V, hash: u64 }
        else
            struct { key: K, value: V };

        const ealign = @max(@alignOf(E), 8);
        /// The entries a small map may have written: twice the live ones
        /// it may hold, so a turnover compacts once every `small` takes.
        const small_lanes = if (opts.small <= 8) 16 else 32;
        const max_entries: usize = std.math.maxInt(u32);

        /// The entries, `cap` of them and then the gone bits.
        entries: [*]E = undefined,
        gone: [*]u64 = undefined,
        cap: usize = 0,
        /// Entries written, gone or not.
        len: usize = 0,
        /// Entries not gone.
        live: usize = 0,
        dead: usize = 0,
        /// The index: `groups` groups of tags, and their slots; none
        /// while `groups` is 0.
        tags: [*]Group = undefined,
        slots: [*]Slots = undefined,
        block: [*]u8 = undefined,
        groups: usize = 0,
        shift: u6 = 63,
        max_load: usize = 0,
        far: bool = false,
        /// A small map's tags: lane `i` is entry `i`'s, 0 when it is gone
        /// or not written.
        small_tags: [small_lanes]u8 align(16) = @splat(0),

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.cap != 0) gpa.free(self.entryBytes());
            if (self.groups != 0) freeBlock(gpa, self.block, self.groups);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.live;
        }

        // checks ////////////////////////////////////////////////////////////

        /// A test safe Rig keeps; nothing in the plain variant.
        inline fn check(ok: bool) void {
            if (opts.checked and !ok) @panic("ordered: index out of range");
        }

        // hashing, tags, groups /////////////////////////////////////////////

        inline fn hashKey(k: K) u64 {
            return ctx.hash(k);
        }

        inline fn hashOf(e: *const E) u64 {
            return if (stores_hash) e.hash else ctx.hash(e.key);
        }

        inline fn tagOf(h: u64) u8 {
            return @max(@as(u8, @truncate(h)), 1);
        }

        inline fn classBit(tag: u8) u8 {
            return @as(u8, 1) << @intCast(tag & 7);
        }

        inline fn home(self: *const Self, h: u64) usize {
            const g: usize = @intCast(h >> self.shift);
            return if (opts.checked) g & (self.groups - 1) else g;
        }

        inline fn keyMatch(e: *const E, k: K, h: u64) bool {
            if (stores_hash) return e.hash == h and ctx.eql(e.key, k);
            return ctx.eql(e.key, k);
        }

        inline fn makeEntry(k: K, v: V, h: u64) E {
            return if (stores_hash) .{ .key = k, .value = v, .hash = h } else .{ .key = k, .value = v };
        }

        inline fn firstLane(m: LaneMask) usize {
            return @as(usize, @ctz(m)) >> lane_shift;
        }

        /// The tag lanes of `grp` that hold `tag` (0: the free lanes).
        inline fn match(grp: *const Group, tag: u8) LaneMask {
            const v: @Vector(16, u8) = grp.*;
            const eq = v == @as(@Vector(16, u8), @splat(tag));
            if (neon) {
                const bytes = @select(u8, eq, @as(@Vector(16, u8), @splat(0xFF)), @as(@Vector(16, u8), @splat(0)));
                const halves: @Vector(8, u16) = @bitCast(bytes);
                const nibbles: @Vector(8, u8) = @truncate(halves >> @splat(4));
                return @as(u64, @bitCast(nibbles)) & tag_lanes;
            } else {
                return @as(u16, @bitCast(eq)) & tag_lanes;
            }
        }

        /// The lanes of `tags`, all sixteen, that hold `tag`.
        inline fn matchAll(tags: *const Group, tag: u8) LaneMask {
            const v: @Vector(16, u8) = tags.*;
            const eq = v == @as(@Vector(16, u8), @splat(tag));
            if (neon) {
                const bytes = @select(u8, eq, @as(@Vector(16, u8), @splat(0xFF)), @as(@Vector(16, u8), @splat(0)));
                const halves: @Vector(8, u16) = @bitCast(bytes);
                const nibbles: @Vector(8, u8) = @truncate(halves >> @splat(4));
                return @as(u64, @bitCast(nibbles)) & 0x1111_1111_1111_1111;
            } else {
                return @as(u16, @bitCast(eq));
            }
        }

        inline fn prefetchSlots(self: *const Self, g: usize) void {
            switch (opts.prefetch) {
                .never => {},
                .far => if (self.far) {
                    check(g < self.groups);
                    @prefetch(self.ix().sl(g), .{});
                },
                .always => {
                    check(g < self.groups);
                    @prefetch(self.ix().sl(g), .{});
                },
            }
        }

        // the entries' block ////////////////////////////////////////////////

        fn goneWords(n: usize) usize {
            return (n + 63) / 64;
        }

        fn goneOffset(cap: usize) usize {
            return std.mem.alignForward(usize, cap * @sizeOf(E), 8);
        }

        fn blockBytes(cap: usize) usize {
            return goneOffset(cap) + goneWords(cap) * 8;
        }

        fn entryBytes(self: *const Self) []align(ealign) u8 {
            const p: [*]align(ealign) u8 = @ptrCast(@alignCast(self.entries));
            return p[0..blockBytes(self.cap)];
        }

        fn goneAt(p: [*]align(ealign) u8, cap: usize) [*]u64 {
            return @ptrCast(@alignCast(p + goneOffset(cap)));
        }

        /// Room for `new_cap` entries; the gone bits move to the block's
        /// new end.
        fn resizeEntries(self: *Self, gpa: Allocator, new_cap: usize) Allocator.Error!void {
            if (new_cap > max_entries) @panic("ordered: a map holds at most 2^32 - 1 entries");
            const old_words = goneWords(self.cap);
            const new_words = goneWords(new_cap);
            if (self.cap == 0) {
                const b = try gpa.alignedAlloc(u8, .fromByteUnits(ealign), blockBytes(new_cap));
                self.entries = @ptrCast(b.ptr);
                self.gone = goneAt(b.ptr, new_cap);
                @memset(self.gone[0..new_words], 0);
            } else {
                const b = try gpa.realloc(self.entryBytes(), blockBytes(new_cap));
                const old_gone = goneAt(b.ptr, self.cap);
                const new_gone = goneAt(b.ptr, new_cap);
                std.mem.copyBackwards(u64, new_gone[0..old_words], old_gone[0..old_words]);
                @memset(new_gone[old_words..new_words], 0);
                self.entries = @ptrCast(b.ptr);
                self.gone = new_gone;
            }
            self.cap = new_cap;
        }

        inline fn isGone(self: *const Self, j: usize) bool {
            return (self.gone[j >> 6] >> @intCast(j & 63)) & 1 != 0;
        }

        // the index's block /////////////////////////////////////////////////

        /// Where group `g`'s tags and slots lie.
        const Ix = struct {
            tags: [*]Group,
            slots: [*]Slots,

            inline fn grp(x: Ix, g: usize) *Group {
                if (!opts.superblocks) return &x.tags[g];
                const p: [*]u8 = @ptrCast(x.tags);
                return @ptrCast(@alignCast(p + (g >> 2) * 320 + (g & 3) * 16));
            }

            inline fn sl(x: Ix, g: usize) *Slots {
                if (!opts.superblocks) return &x.slots[g];
                const p: [*]u8 = @ptrCast(x.tags);
                return @ptrCast(@alignCast(p + (g >> 2) * 320 + 64 + (g & 3) * 64));
            }
        };

        inline fn ix(self: *const Self) Ix {
            return .{ .tags = self.tags, .slots = self.slots };
        }

        /// Tags, then the slots on a 64-byte line: one allocation.
        fn indexBytes(groups: usize) usize {
            if (opts.superblocks) return (groups + 3) / 4 * 320 + 64;
            return 16 * groups + 64 + 64 * groups;
        }

        /// The bytes that hold tags (and, in superblocks, slots too).
        fn tagBytes(groups: usize) usize {
            if (opts.superblocks) return (groups + 3) / 4 * 320;
            return 16 * groups;
        }

        /// Whether `gpa` is libc's `malloc`, whose `calloc` the index uses.
        inline fn isLibc(gpa: Allocator) bool {
            if (!builtin.link_libc) return false;
            return gpa.vtable == std.heap.c_allocator.vtable;
        }

        fn allocBlock(gpa: Allocator, groups: usize) Allocator.Error![*]u8 {
            const n = indexBytes(groups);
            // Fresh pages from calloc are zero already: no stores.
            if (isLibc(gpa)) {
                const p = std.c.calloc(1, n) orelse return error.OutOfMemory;
                return @ptrCast(p);
            }
            const b = try gpa.alignedAlloc(u8, .@"16", n);
            @memset(b, 0);
            return b.ptr;
        }

        fn freeBlock(gpa: Allocator, p: [*]u8, groups: usize) void {
            if (isLibc(gpa)) return std.c.free(p);
            const a: [*]align(16) u8 = @alignCast(p);
            gpa.free(a[0..indexBytes(groups)]);
        }

        fn maxLoad(groups: usize) usize {
            return 15 * groups * opts.max_load / 1000;
        }

        /// The groups that hold `n` live entries at most 0.6 full.
        fn groupsFor(n: usize) usize {
            var g: usize = 2;
            while (9 * g < n) g *= 2;
            return g;
        }

        fn setIndex(self: *Self, p: [*]u8, groups: usize) void {
            self.block = p;
            if (opts.superblocks) {
                const a = std.mem.alignForward(usize, @intFromPtr(p), 64);
                self.tags = @ptrFromInt(a);
                self.slots = @ptrFromInt(a);
            } else {
                self.tags = @ptrCast(@alignCast(p));
                const s = std.mem.alignForward(usize, @intFromPtr(p) + 16 * groups, 64);
                self.slots = @ptrFromInt(s);
            }
            self.groups = groups;
            self.shift = @intCast(@as(u32, 64) - std.math.log2_int(usize, groups));
            self.max_load = maxLoad(groups);
            self.far = indexBytes(groups) > opts.far_bytes;
        }

        /// The first free lane from `g`'s group on takes entry `j`; each
        /// full group on the way marks the tag's class as overflowed.
        inline fn place(x: Ix, mask: usize, start: usize, tag: u8, j: usize) void {
            var g = start;
            var step: usize = 0;
            while (true) {
                const grp = x.grp(g);
                const free = match(grp, 0);
                if (free != 0) {
                    const lane = firstLane(free);
                    grp[lane] = tag;
                    x.sl(g)[lane] = @intCast(j);
                    return;
                }
                grp[15] |= classBit(tag);
                step += 1;
                g = (g + step) & mask;
            }
        }

        /// A new index of `groups` groups, filled from the entries in
        /// order; the gone entries are dropped from the array first.
        noinline fn rebuild(self: *Self, gpa: Allocator, groups: usize) Allocator.Error!void {
            const p = try allocBlock(gpa, groups);
            if (self.groups != 0) freeBlock(gpa, self.block, self.groups);
            if (self.dead != 0) self.moveLive(null);
            self.setIndex(p, groups);
            self.fill();
        }

        /// Place every entry, in order. A far index is filled hashing
        /// sixteen entries ahead and prefetching the group each lands in.
        fn fill(self: *Self) void {
            const x = self.ix();
            const mask = self.groups - 1;
            const shift = self.shift;
            const es = self.entries;
            const n = self.len;
            if (!self.far) {
                for (0..n) |j| {
                    const h = hashOf(&es[j]);
                    place(x, mask, @intCast(h >> shift), tagOf(h), j);
                }
                return;
            }
            const ahead = 16;
            var ring: [ahead]u64 = undefined;
            var it: usize = 0;
            while (it < ahead and it < n) : (it += 1) {
                const h = hashOf(&es[it]);
                ring[it] = h;
                @prefetch(x.grp(@intCast(h >> shift)), .{ .rw = .write });
                @prefetch(x.sl(@intCast(h >> shift)), .{ .rw = .write });
            }
            for (0..n) |j| {
                const h = ring[j % ahead];
                if (it != n) {
                    const nh = hashOf(&es[it]);
                    ring[j % ahead] = nh;
                    @prefetch(x.grp(@intCast(nh >> shift)), .{ .rw = .write });
                    @prefetch(x.sl(@intCast(nh >> shift)), .{ .rw = .write });
                    it += 1;
                }
                place(x, mask, @intCast(h >> shift), tagOf(h), j);
            }
        }

        /// Move the live entries down, in order. With `before`, record
        /// the gone entries before each word of gone bits, and leave the
        /// gone bits for the index's renumbering; without, clear them.
        fn moveLive(self: *Self, before: ?[]u32) void {
            const n = self.len;
            const es = self.entries;
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
                    if (dst != base) std.mem.copyForwards(E, es[dst .. dst + lim], es[base .. base + lim]);
                    dst += lim;
                } else {
                    dropped += @popCount(g);
                    var keep = ~g & lowBits(lim);
                    while (keep != 0) : (keep &= keep - 1) {
                        es[dst] = es[base + @ctz(keep)];
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

        /// Compact the entries under the same index: move the live ones
        /// down, then renumber every slot by the gone entries below it.
        /// No hash, no probe; tags and positions stay.
        fn compact(self: *Self, gpa: Allocator) Allocator.Error!void {
            const words = goneWords(self.len);
            var stack: [64]u32 = undefined;
            const before = if (words <= stack.len) stack[0..words] else try gpa.alloc(u32, words);
            defer if (words > stack.len) gpa.free(before);
            const gone = self.gone;
            self.moveLive(before);
            const x = self.ix();
            for (0..self.groups) |g| {
                var full = ~match(x.grp(g), 0) & tag_lanes;
                const sl = x.sl(g);
                while (full != 0) : (full &= full - 1) {
                    const lane = firstLane(full);
                    const j: usize = sl[lane];
                    const w = j >> 6;
                    const below = gone[w] & lowBits(j & 63);
                    sl[lane] = @intCast(j - before[w] - @popCount(below));
                }
            }
            @memset(gone[0..words], 0);
        }

        /// Room for one more entry, and room in the index for it.
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

        /// Empty the map, keeping its memory: taking the last entry.
        fn reset(self: *Self) void {
            @memset(self.gone[0..goneWords(self.len)], 0);
            self.len = 0;
            self.live = 0;
            self.dead = 0;
            if (self.groups == 0) return;
            const t: [*]u8 = @ptrCast(self.tags);
            @memset(t[0..tagBytes(self.groups)], 0);
            self.max_load = maxLoad(self.groups);
        }

        // finding ///////////////////////////////////////////////////////////

        const Found = struct { g: usize, lane: usize, j: usize };

        /// The entry of `k` in a small map (no index): the lanes of its
        /// tag among the small tags, each an entry.
        inline fn findSmall(self: *const Self, k: K, h: u64) ?usize {
            if (opts.small_scan == .scalar and !stores_hash and !opts.checked) {
                for (0..self.len) |i| {
                    if (self.small_tags[i] != 0 and ctx.eql(self.entries[i].key, k)) return i;
                }
                return null;
            }
            const tag = tagOf(h);
            var m = matchAll(self.small_tags[0..16], tag);
            while (m != 0) : (m &= m - 1) {
                const i = firstLane(m);
                check(i < self.len);
                if (keyMatch(&self.entries[i], k, h)) return i;
            }
            if (small_lanes == 32 and self.len > 16) {
                @branchHint(.unlikely);
                m = matchAll(self.small_tags[16..32], tag);
                while (m != 0) : (m &= m - 1) {
                    const i = 16 + firstLane(m);
                    check(i < self.len);
                    if (keyMatch(&self.entries[i], k, h)) return i;
                }
            }
            return null;
        }

        /// The probe from group `start`, `step` groups walked.
        inline fn probeFrom(self: *const Self, k: K, h: u64, tag: u8, start: usize, start_step: usize) ?Found {
            const x = self.ix();
            const es = self.entries;
            const mask = self.groups - 1;
            const bit = classBit(tag);
            var g = start;
            var step = start_step;
            while (true) {
                const grp = x.grp(g);
                var m = match(grp, tag);
                while (m != 0) : (m &= m - 1) {
                    const lane = firstLane(m);
                    const j: usize = x.sl(g)[lane];
                    check(j < self.len);
                    if (keyMatch(&es[j], k, h)) return .{ .g = g, .lane = lane, .j = j };
                }
                if (grp[15] & bit == 0) return null;
                step += 1;
                if (step > mask) return null;
                g = (g + step) & mask;
            }
        }

        noinline fn probePastHome(self: *const Self, k: K, h: u64, tag: u8, start: usize) ?Found {
            return self.probeFrom(k, h, tag, start, 1);
        }

        /// The entry of `k`, whose hash is `h`, in the index: the home
        /// group inline, the walk past it out of line.
        inline fn findIndexed(self: *const Self, k: K, h: u64) ?Found {
            return self.findIndexedWalk(k, h, opts.checked);
        }

        /// As `findIndexed`, the walk past home inline when `walk_inline`.
        inline fn findIndexedWalk(self: *const Self, k: K, h: u64, comptime walk_inline: bool) ?Found {
            const tag = tagOf(h);
            const g = self.home(h);
            self.prefetchSlots(g);
            const grp = self.ix().grp(g);
            var m = match(grp, tag);
            while (m != 0) : (m &= m - 1) {
                const lane = firstLane(m);
                const j: usize = self.ix().sl(g)[lane];
                check(j < self.len);
                if (keyMatch(&self.entries[j], k, h)) return .{ .g = g, .lane = lane, .j = j };
            }
            if (grp[15] & classBit(tag) != 0) {
                @branchHint(.unlikely);
                // Checked, the walk stays inline: a call that may panic
                // is not read-only, and LLVM would reload the map's
                // fields after it on every lookup. A take, a call of its
                // own, keeps it inline too: a call in it costs its
                // prologue more saved registers than the walk costs.
                if (walk_inline) return self.probeFrom(k, h, tag, (g + 1) & (self.groups - 1), 1);
                return self.probePastHome(k, h, tag, (g + 1) & (self.groups - 1));
            }
            return null;
        }

        inline fn findEntry(self: *const Self, k: K) ?usize {
            const h = hashKey(k);
            if (self.groups == 0) return self.findSmall(k, h);
            const f = self.findIndexed(k, h) orelse return null;
            return f.j;
        }

        // lookup ////////////////////////////////////////////////////////////

        pub inline fn get(self: *const Self, k: K) ?V {
            const j = self.findEntry(k) orelse return null;
            return self.entries[j].value;
        }

        pub inline fn getPtr(self: *const Self, k: K) ?*V {
            const j = self.findEntry(k) orelse return null;
            return &self.entries[j].value;
        }

        pub inline fn contains(self: *const Self, k: K) bool {
            return self.findEntry(k) != null;
        }

        // insert ////////////////////////////////////////////////////////////

        /// Put `v` under `k`: a key already there keeps its place and gets
        /// the new value; a new key goes after every entry. The home group
        /// is inline, and so is an insert into room there.
        pub inline fn put(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.groups == 0) return self.putSmall(gpa, k, v);
            const h = hashKey(k);
            const tag = tagOf(h);
            const g = self.home(h);
            self.prefetchSlots(g);
            const grp = self.ix().grp(g);
            var m = match(grp, tag);
            while (m != 0) : (m &= m - 1) {
                const lane = firstLane(m);
                const j: usize = self.ix().sl(g)[lane];
                check(j < self.len);
                const e = &self.entries[j];
                if (keyMatch(e, k, h)) {
                    e.value = v;
                    return;
                }
            }
            if (grp[15] & classBit(tag) == 0) {
                const free = match(grp, 0);
                const j = self.len;
                if (free != 0 and j < self.cap and self.live < self.max_load) {
                    const lane = firstLane(free);
                    self.entries[j] = makeEntry(k, v, h);
                    self.len = j + 1;
                    self.live += 1;
                    grp[lane] = tag;
                    self.ix().sl(g)[lane] = @intCast(j);
                    return;
                }
            }
            return self.putSlow(gpa, k, v, h);
        }

        /// Past the home group, or no room: find `k` on past home; else
        /// make room and place it.
        noinline fn putSlow(self: *Self, gpa: Allocator, k: K, v: V, h: u64) Allocator.Error!void {
            if (self.findIndexed(k, h)) |f| {
                self.entries[f.j].value = v;
                return;
            }
            try self.reserveOne(gpa);
            const j = self.len;
            self.entries[j] = makeEntry(k, v, h);
            self.len = j + 1;
            self.live += 1;
            place(self.ix(), self.groups - 1, self.home(h), tagOf(h), j);
        }

        inline fn putSmall(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            const h = hashKey(k);
            if (self.findSmall(k, h)) |i| {
                self.entries[i].value = v;
                return;
            }
            const j = self.len;
            if (j < self.cap and j < small_lanes and self.live < opts.small) {
                self.entries[j] = makeEntry(k, v, h);
                self.small_tags[j] = tagOf(h);
                self.len = j + 1;
                self.live += 1;
                return;
            }
            return self.putSmallSlow(gpa, k, v, h);
        }

        /// A small map's first entry; one whose array is full, given room
        /// up to `small_lanes` or compacted; or one with `small` live
        /// entries, given its index.
        noinline fn putSmallSlow(self: *Self, gpa: Allocator, k: K, v: V, h: u64) Allocator.Error!void {
            if (self.cap == 0) {
                try self.resizeEntries(gpa, opts.first_cap);
            } else if (self.live < opts.small and self.len == self.cap and self.cap < small_lanes) {
                try self.resizeEntries(gpa, @min(2 * self.cap, small_lanes));
            } else if (self.live < opts.small) {
                var d: usize = 0;
                for (0..self.len) |i| {
                    if (self.small_tags[i] == 0) continue;
                    self.small_tags[d] = self.small_tags[i];
                    d += 1;
                }
                @memset(self.small_tags[d..], 0);
                self.moveLive(null);
            } else {
                // Sized for the entries' next capacity, so the index is
                // at most 0.6 full until the map passes it.
                try self.rebuild(gpa, groupsFor(2 * self.cap));
                if (self.len == self.cap) try self.resizeEntries(gpa, 2 * self.cap);
                const j = self.len;
                self.entries[j] = makeEntry(k, v, h);
                self.len = j + 1;
                self.live += 1;
                place(self.ix(), self.groups - 1, self.home(h), tagOf(h), j);
                return;
            }
            const j = self.len;
            self.entries[j] = makeEntry(k, v, h);
            self.small_tags[j] = tagOf(h);
            self.len = j + 1;
            self.live += 1;
        }

        // take //////////////////////////////////////////////////////////////

        /// Take the entry of `k` out, handing back its key and value. One
        /// probe; its tag is cleared and its entry marked gone, and the
        /// order of the rest is kept. The last entry written is cut off
        /// instead, with any gone entries before it; the last live entry
        /// empties the map.
        pub fn fetchRemove(self: *Self, k: K) ?KV {
            const h = hashKey(k);
            if (self.groups == 0) {
                const i = self.findSmall(k, h) orelse return null;
                const e = &self.entries[i];
                const kv: KV = .{ .key = e.key, .value = e.value };
                self.small_tags[i] = 0;
                self.dropEntry(i);
                return kv;
            }
            const f = self.findIndexedWalk(k, h, true) orelse return null;
            const grp = self.ix().grp(f.g);
            grp[f.lane] = 0;
            if (grp[15] & classBit(tagOf(h)) != 0) self.max_load -= 1;
            const e = &self.entries[f.j];
            const kv: KV = .{ .key = e.key, .value = e.value };
            self.dropEntry(f.j);
            return kv;
        }

        /// Entry `j`, whose lane is cleared, leaves the live entries.
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

        // iteration /////////////////////////////////////////////////////////

        /// A walk of the entries in order, by runs of live entries: with
        /// none gone, one counted loop over the array.
        const Cursor = struct {
            entries: [*]E,
            gone: [*]const u64,
            len: usize,
            i: usize,
            end: usize,
            holes: bool,

            fn init(m: *const Self) Cursor {
                const holes = m.dead != 0;
                return .{ .entries = m.entries, .gone = m.gone, .len = m.len, .i = 0, .end = if (holes) 0 else m.len, .holes = holes };
            }

            /// The next live entry's index; `len` past the last.
            inline fn step(c: *Cursor) usize {
                if (c.i == c.end) {
                    if (!c.holes) return c.len;
                    const r = nextRun(c.gone, c.len, c.i);
                    if (r.start == c.len) return c.len;
                    c.i = r.start;
                    c.end = r.end;
                }
                check(c.i < c.len);
                const j = c.i;
                c.i = j + 1;
                return j;
            }
        };

        const Run = struct { start: usize, end: usize };

        /// The run of live entries at or after `from`.
        noinline fn nextRun(gone: [*]const u64, len: usize, from: usize) Run {
            var j = from;
            // the first live entry: a clear bit
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
            // the next gone entry: a set bit
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
                const e = &it.c.entries[j];
                return .{ .key_ptr = &e.key, .value_ptr = &e.value };
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
                const e = &it.c.entries[j];
                return &e.key;
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
                const e = &it.c.entries[j];
                return &e.value;
            }
        };

        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .c = .init(self) };
        }

        // checking //////////////////////////////////////////////////////////

        /// The invariants, for tests: the counts agree; every live entry
        /// has exactly one full lane, on its probe sequence, with its tag;
        /// every group it walked past marks its class; no lane names a
        /// gone entry; the gone bits lie below `len`.
        pub fn verify(self: *const Self, gpa: Allocator) !void {
            if (self.live + self.dead != self.len) return error.Corrupt;
            if (self.len > self.cap) return error.Corrupt;
            var gone_count: usize = 0;
            for (0..goneWords(self.cap)) |w| {
                const g = self.gone[w];
                gone_count += @popCount(g);
                if (g != 0 and w * 64 + 64 - @clz(g) > self.len) return error.Corrupt;
            }
            if (self.cap != 0 and gone_count != self.dead) return error.Corrupt;
            if (self.len != 0 and self.isGone(self.len - 1)) return error.Corrupt;
            if (self.groups == 0) {
                if (self.len > small_lanes or self.live > opts.small) return error.Corrupt;
                for (0..small_lanes) |i| {
                    const t = self.small_tags[i];
                    if (i >= self.len or self.isGone(i)) {
                        if (t != 0) return error.Corrupt;
                    } else if (t != tagOf(hashOf(&self.entries[i]))) return error.Corrupt;
                }
                return;
            }
            if (self.live > self.max_load) return error.Corrupt;
            const named = try gpa.alloc(u8, self.len);
            defer gpa.free(named);
            @memset(named, 0);
            var full: usize = 0;
            for (0..self.groups) |g| for (0..15) |lane| {
                if (self.ix().grp(g)[lane] == 0) continue;
                full += 1;
                const j = self.ix().sl(g)[lane];
                if (j >= self.len or self.isGone(j)) return error.Corrupt;
                if (named[j] != 0) return error.Corrupt;
                named[j] = 1;
                if (tagOf(hashOf(&self.entries[j])) != self.ix().grp(g)[lane]) return error.Corrupt;
            };
            if (full != self.live) return error.Corrupt;
            const mask = self.groups - 1;
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const h = hashOf(&self.entries[j]);
                const tag = tagOf(h);
                var g: usize = @intCast(h >> self.shift);
                var step: usize = 0;
                while (true) {
                    var hit = false;
                    for (0..15) |lane| {
                        if (self.ix().grp(g)[lane] == tag and self.ix().sl(g)[lane] == j) hit = true;
                    }
                    if (hit) break;
                    if (self.ix().grp(g)[15] & classBit(tag) == 0) return error.Corrupt;
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

/// Rig's hash of an Int, as bench/hash's `zig-ordered` uses.
const IntCtx = struct {
    pub fn hash(_: IntCtx, x: i64) u64 {
        const p = @as(u128, @as(u64, @bitCast(x)) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
        return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
    }
    pub fn eql(_: IntCtx, a: i64, b: i64) bool {
        return a == b;
    }
};

/// A hash that crowds keys into a few groups and tag classes, so overflow
/// bits, walks past home and anti-drift all run.
const CrowdCtx = struct {
    pub fn hash(_: CrowdCtx, x: i64) u64 {
        const u: u64 = @bitCast(x);
        return ((u % 7) << 61) | ((u % 3) << 3) | (u & 0x7) | (((u >> 3) << 8) & 0x00FF_FF00);
    }
    pub fn eql(_: CrowdCtx, a: i64, b: i64) bool {
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

/// The model: the live keys in first-put order, and their values.
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

/// Every entry, in order, against the model's order.
fn expectOrder(map: anytype, model: anytype) !void {
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        try testing.expect(i < model.order.items.len);
        try testing.expectEqual(model.order.items[i], e.key_ptr.*);
        try testing.expectEqual(model.values.get(e.key_ptr.*).?, e.value_ptr.*);
    }
    try testing.expectEqual(model.order.items.len, i);
    var ki = map.keyIterator();
    var vi = map.valueIterator();
    i = 0;
    while (ki.next()) |k| : (i += 1) {
        try testing.expectEqual(model.order.items[i], k.*);
        try testing.expectEqual(model.values.get(k.*).?, vi.next().?.*);
    }
    try testing.expect(vi.next() == null);
}

fn randomAgainstModel(comptime M: type, ops: usize, key_range: u64, check_every: usize, seed: u64) !void {
    const gpa = testing.allocator;
    var m: M = .empty;
    defer m.deinit(gpa);
    var model: Model(i64) = .{};
    defer model.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (0..ops) |i| {
        const k: i64 = @intCast(rnd.uintLessThan(u64, key_range));
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

const Plain = HashMap(i64, i64, IntCtx);
const Checked = Ordered(i64, i64, IntCtx, .{ .checked = true });

test "random operations against a model of the order" {
    try randomAgainstModel(Plain, 300_000, 3_000, 5_000, 0x5eed);
    try randomAgainstModel(Plain, 200_000, 40, 101, 1);
    try randomAgainstModel(Checked, 200_000, 3_000, 5_000, 2);
    try randomAgainstModel(Ordered(i64, i64, IntCtx, .{ .superblocks = true }), 200_000, 3_000, 5_000, 8);
}

test "random operations with a crowding hash" {
    try randomAgainstModel(Ordered(i64, i64, CrowdCtx, .{}), 200_000, 3_000, 997, 3);
    try randomAgainstModel(Ordered(i64, i64, CrowdCtx, .{ .checked = true }), 100_000, 500, 97, 4);
    try randomAgainstModel(Ordered(i64, i64, CrowdCtx, .{ .superblocks = true }), 100_000, 2_000, 97, 9);
}

test "the small path, to 16 entries, and back from empty" {
    inline for (.{ 8, 16 }) |small| {
        inline for (.{ .tags, .scalar }) |scan| {
            const M = Ordered(i64, i64, IntCtx, .{ .small = small, .first_cap = 16, .small_scan = scan });
            try randomAgainstModel(M, 50_000, 20, 1, 5);
            try randomAgainstModel(M, 50_000, 14, 1, 6);
        }
    }
}

test "a re-put keeps its place; a take and put goes last" {
    const gpa = testing.allocator;
    var m: Plain = .empty;
    defer m.deinit(gpa);
    var model: Model(i64) = .{};
    defer model.deinit(gpa);
    for (0..100) |i| {
        try m.put(gpa, @intCast(i), @intCast(i));
        try model.put(gpa, @intCast(i), @intCast(i));
    }
    try m.put(gpa, 3, -3);
    try model.put(gpa, 3, -3);
    try testing.expectEqual(@as(i64, 5), m.fetchRemove(5).?.value);
    _ = model.take(5);
    try m.put(gpa, 5, 55);
    try model.put(gpa, 5, 55);
    try expectOrder(&m, &model);
    try m.verify(gpa);
    // the last entry written is cut off, with the gone ones before it
    try testing.expectEqual(@as(i64, 98), m.fetchRemove(98).?.value);
    _ = model.take(98);
    try testing.expectEqual(@as(i64, 55), m.fetchRemove(5).?.value);
    _ = model.take(5);
    try testing.expectEqual(@as(i64, 99), m.fetchRemove(99).?.value);
    _ = model.take(99);
    // 98 cut off with 99; the first 5 stays gone
    try testing.expectEqual(@as(usize, 98), m.len);
    try testing.expectEqual(@as(usize, 1), m.dead);
    try expectOrder(&m, &model);
    try m.verify(gpa);
}

test "churn: no tombstones pile up, the order holds" {
    const gpa = testing.allocator;
    inline for (.{ Plain, Checked }) |M| {
        for ([_]usize{ 16, 1000, 50_000 }) |size| {
            var m: M = .empty;
            defer m.deinit(gpa);
            var i: i64 = 0;
            while (i < size) : (i += 1) try m.put(gpa, i, i);
            var oldest: i64 = 0;
            var next: i64 = @intCast(size);
            var most_groups: usize = 0;
            var most_cap: usize = 0;
            for (0..30 * size) |step| {
                const kv = m.fetchRemove(oldest).?;
                try testing.expectEqual(oldest, kv.value);
                oldest += 1;
                try m.put(gpa, next, next);
                next += 1;
                try testing.expectEqual(size, m.count());
                if (step > 4 * size) {
                    most_groups = @max(most_groups, m.groups);
                    most_cap = @max(most_cap, m.cap);
                }
                if (step % (size * 3 + 1) == 0) try m.verify(gpa);
            }
            try m.verify(gpa);
            // a steady index and an array at most four times the live entries
            try testing.expect(most_groups <= 2 * Plain.groupsFor(size));
            try testing.expect(most_cap <= 4 * size + 16);
            var it = m.iterator();
            var want = oldest;
            while (it.next()) |e| : (want += 1) try testing.expectEqual(want, e.key_ptr.*);
            try testing.expectEqual(next, want);
        }
    }
}

test "churn under a crowding hash, random victims" {
    const gpa = testing.allocator;
    var m: Ordered(i64, i64, CrowdCtx, .{}) = .empty;
    defer m.deinit(gpa);
    var model: Model(i64) = .{};
    defer model.deinit(gpa);
    const size = 2_000;
    var i: i64 = 0;
    while (i < size) : (i += 1) {
        try m.put(gpa, i, i);
        try model.put(gpa, i, i);
    }
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var next: i64 = size;
    for (0..40_000) |step| {
        const victim = model.order.items[rnd.uintLessThan(usize, model.order.items.len)];
        try testing.expectEqual(model.take(victim).?, m.fetchRemove(victim).?.value);
        try m.put(gpa, next, next);
        try model.put(gpa, next, next);
        next += 1;
        if (step % 2000 == 0) {
            try m.verify(gpa);
            try expectOrder(&m, &model);
        }
    }
    try m.verify(gpa);
    try expectOrder(&m, &model);
}

test "growth and compaction keep every entry in order" {
    const gpa = testing.allocator;
    inline for (.{ Ordered(i64, [8]i64, IntCtx, .{}), Ordered(i64, [8]i64, IntCtx, .{ .checked = true }), Ordered(i64, [8]i64, IntCtx, .{ .superblocks = true }) }) |M| {
        var m: M = .empty;
        defer m.deinit(gpa);
        try testing.expect(m.get(5) == null);
        try testing.expect(m.fetchRemove(5) == null);
        var last_groups: usize = 0;
        var i: i64 = 0;
        const mul: i64 = -7046029254386353131;
        while (i < 200_000) : (i += 1) {
            try m.put(gpa, i *% mul, @splat(i));
            if (m.groups != last_groups) {
                last_groups = m.groups;
                try m.verify(gpa);
            }
        }
        try testing.expectEqual(@as(usize, 200_000), m.count());
        // take every third, then fill the array: it compacts in place
        i = 0;
        while (i < 200_000) : (i += 3) try testing.expectEqual(i, m.fetchRemove(i *% mul).?.value[2]);
        try m.verify(gpa);
        const groups = m.groups;
        const cap = m.cap;
        var extra: i64 = 0;
        while (m.len < m.cap) : (extra += 1) try m.put(gpa, (1_000_000 + extra) *% mul, @splat(-extra));
        try m.put(gpa, (1_000_000 + extra) *% mul, @splat(-extra));
        extra += 1;
        try testing.expectEqual(groups, m.groups);
        try testing.expectEqual(cap, m.cap);
        try testing.expectEqual(@as(usize, 0), m.dead);
        try m.verify(gpa);
        var it = m.iterator();
        var want: i64 = 0;
        while (want < 200_000) : (want += 1) {
            if (@mod(want, 3) == 0) continue;
            const e = it.next().?;
            try testing.expectEqual(want *% mul, e.key_ptr.*);
            try testing.expectEqual(want, e.value_ptr.*[7]);
        }
        var x: i64 = 0;
        while (x < extra) : (x += 1) try testing.expectEqual(-x, it.next().?.value_ptr.*[0]);
        try testing.expect(it.next() == null);
        try m.put(gpa, 1 *% mul, @splat(-1)); // overwrite keeps the place
        try testing.expectEqual(@as(i64, -1), m.get(1 *% mul).?[0]);
        // taking every entry empties it, and it is used again
        it = m.iterator();
        var keys: std.ArrayList(i64) = .empty;
        defer keys.deinit(gpa);
        while (it.next()) |e| try keys.append(gpa, e.key_ptr.*);
        for (keys.items) |k| _ = m.fetchRemove(k).?;
        try testing.expectEqual(@as(usize, 0), m.len);
        try m.verify(gpa);
        try m.put(gpa, 42, @splat(42));
        try testing.expectEqual(@as(i64, 42), m.getPtr(42).?[5]);
        try m.verify(gpa);
    }
}

test "text keys, owned by the map and found by equal texts made apart" {
    const gpa = testing.allocator;
    inline for (.{ HashMap([]const u8, i64, TextCtx), Ordered([]const u8, i64, TextCtx, .{ .checked = true }) }) |M| {
        try testing.expect(M.stores_hash);
        var m: M = .empty;
        var model: Model(u32) = .{};
        defer model.deinit(gpa);
        var prng = std.Random.DefaultPrng.init(42);
        const rnd = prng.random();
        var buf: [32]u8 = undefined;
        for (0..100_000) |i| {
            const n = rnd.uintLessThan(u32, 5_000);
            const probe = try std.fmt.bufPrint(&buf, "{d}#key{d}", .{ n *% 2654435761, n });
            switch (rnd.uintLessThan(u8, 4)) {
                0, 1 => {
                    if (m.getPtr(probe)) |v| {
                        v.* = @intCast(i);
                    } else {
                        try m.put(gpa, try gpa.dupe(u8, probe), @intCast(i));
                    }
                    try model.put(gpa, n, @intCast(i));
                },
                2 => {
                    const a = m.fetchRemove(probe);
                    const b = model.take(n);
                    try testing.expectEqual(b == null, a == null);
                    if (a) |kv| {
                        try testing.expectEqualStrings(probe, kv.key);
                        try testing.expectEqual(b.?, kv.value);
                        gpa.free(kv.key);
                    }
                },
                else => try testing.expectEqual(model.values.get(n), m.get(probe)),
            }
            if (i % 10_000 == 0) try m.verify(gpa);
        }
        try m.verify(gpa);
        var it = m.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            const n = model.order.items[i];
            const want = try std.fmt.bufPrint(&buf, "{d}#key{d}", .{ n *% 2654435761, n });
            try testing.expectEqualStrings(want, e.key_ptr.*);
            try testing.expectEqual(model.values.get(n).?, e.value_ptr.*);
        }
        try testing.expectEqual(model.order.items.len, i);
        // free every key the map holds, as the bench does: none twice
        var ki = m.keyIterator();
        while (ki.next()) |k| gpa.free(k.*);
        m.deinit(gpa);
    }
}

test "iteration over holes" {
    const gpa = testing.allocator;
    var m: Plain = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 10_000) : (i += 1) try m.put(gpa, i, i * 2);
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    var live = try std.DynamicBitSet.initFull(gpa, 10_000);
    defer live.deinit();
    // runs of holes of every length, word-aligned and not
    var k: usize = 0;
    while (k < 10_000) {
        const run = rnd.uintLessThan(usize, 150);
        const holes = rnd.uintLessThan(usize, 150);
        k += run;
        var h: usize = 0;
        while (h < holes and k < 9_999) : ({
            h += 1;
            k += 1;
        }) {
            _ = m.fetchRemove(@intCast(k)).?;
            live.unset(k);
        }
    }
    try m.verify(gpa);
    var it = m.iterator();
    var want = live.iterator(.{});
    while (want.next()) |w| {
        const e = it.next().?;
        try testing.expectEqual(@as(i64, @intCast(w)), e.key_ptr.*);
        try testing.expectEqual(@as(i64, @intCast(w)) * 2, e.value_ptr.*);
    }
    try testing.expect(it.next() == null);
}
