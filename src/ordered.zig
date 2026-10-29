//! The ordered hash table behind `Map` and `Set` (std/prelude.rig):
//! the compiler built-ins `OrderedMap[K, V]` and `OrderedSet[K]`, held
//! here as `OrderedMap(K, V)` and `OrderedSet(K)`, written beside the
//! runtime. It is bench/hash's `zig-ordered` (bench/hash/ordered.zig;
//! docs/history/records/2026-10/hash-race/zig-ordered.md for each choice
//! and its measurement), with Rig's hash and `==` and its drops.
//!
//! The entries sit in one array in the order their keys were first put,
//! `{key, value}`, and a key over 8 bytes, but a plain one of at most
//! four words, keeps its hash beside them. A
//! take drops its key, hands its value back, and marks its entry gone in
//! a bitset at the end of the same allocation, so the order survives
//! every take, and a walk passes the gone entries by runs. The entries
//! are compacted only when the array is full and a quarter of it is
//! gone, when the index grows, or when a take empties the table.
//!
//! The index: groups of 16 tag bytes (15 tags and an overflow byte), and
//! beside them a 64-byte line of sixteen `u32` entry indexes a group. A
//! key's group is its hash's high bits and its tag the low byte, 0 made
//! 1; 0 is a free lane. An insert that passes a full group sets the bit
//! `tag & 7` of its overflow byte, and a probe stops at the first group
//! whose bit for the class is clear. A take writes 0 to its tag and,
//! where the group's bit for its class is set, lowers the maximum load by
//! one, so no tombstone piles up: a rebuild forced by drift sizes the
//! index so the live entries fill at most 0.6 of it.
//!
//! Up to `small` (16) live entries there is no index: the small tags,
//! lane `i` entry `i`'s tag (0 when gone or not written), find a key by
//! one match. A small table writes up to `small_lanes` entries, so a
//! turnover compacts once every `small` takes, and its first put makes
//! room for 4. The small tags sit in the table where an indexed table
//! keeps its index's pointers and gone bits (`Held`), so the table is 56
//! bytes and a `Map` 64, a line. An indexed table's room doubles but
//! from 32 to 48 and 48 to 64 (`nextRoom`)
//! (docs/history/records/2026-10/hash-race/small-maps.md).
//!
//! Every method here is called only from std/prelude.rig's `Map` and
//! `Set`, whose declarations the checkers read; an entry index it is
//! given is one this table gave and is live.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime.zig");

/// NEON's 16-lane compare is narrowed to a nibble a lane (`shrn #4`);
/// SSE2's is `pmovmskb`, a bit a lane.
const neon = builtin.cpu.arch == .aarch64;
const LaneMask = if (neon) u64 else u32;
const lane_shift: u6 = if (neon) 2 else 0;
/// The 15 tag lanes of a group; lane 15 is the overflow byte.
const tag_lanes: LaneMask = if (neon) 0x0111_1111_1111_1111 else 0x7FFF;

const Group = [16]u8;
const Slots = [16]u32;

/// Live entries a table holds before it builds its index.
const small = 16;
/// Entries a small table may have written, gone or not.
const small_lanes = 32;
/// The room a table makes at its first put.
const first_cap = 4;
/// The index's maximum load, in thousandths of its tag lanes.
const max_load_milli = 875;
/// An index larger than this is far: a rebuild prefetches the groups it
/// fills ahead.
const far_bytes = 1 << 20;
/// The most entries a table holds: an entry index is 32 bits.
const max_entries: usize = std.math.maxInt(u32);


/// `Map[K, V]`'s table.
pub fn OrderedMap(comptime K: type, comptime V: type) type {
    return Ordered(K, V);
}

/// `Set[K]`'s table: a Map's with no value.
pub fn OrderedSet(comptime K: type) type {
    return Ordered(K, void);
}

fn Ordered(comptime K: type, comptime V: type) type {
    return extern struct {
        const Self = @This();

        /// A key over 8 bytes keeps its hash in its entry, but for a plain
        /// key of at most 4 words (`rt.wordCount`), which hashes in a
        /// multiply or two and compares in as many loads: its entry is a
        /// word smaller, and a lookup reads the key where it would have
        /// read the hash, on the same line.
        const stores_hash = @sizeOf(K) > 8 and (rt.wordCount(K) orelse 5) > 4;
        const is_set = V == void;

        const E = if (stores_hash)
            struct { key: K, value: V, hash: u64 }
        else
            struct { key: K, value: V };


        /// A view of a key, as a lookup takes it (`?K`).
        const KeyView = rt.ReadView(K);

        /// An indexed table's index and gone bits; a small table's tags in
        /// their place, as no table holds both. A Map is then 64 bytes, a
        /// line.
        const Index = extern struct {
            /// A bit an entry, set when it is gone: `goneWords(cap)` words
            /// while `has_gone`, made at the first take that leaves a hole.
            gone: [*]u64,
            /// The live entries the index takes before it grows: 7/8 of
            /// its tag lanes, less one for each take from a lane a probe
            /// may walk past.
            max_load: u32,
            /// The index's groups, a power of two.
            groups: u32,
            /// The index: `groupCount()` groups of tags, and their slots.
            /// `slots` starts the index's block.
            tags: [*]Group,
            slots: [*]Slots,
        };
        const Held = extern union {
            /// A small table's tags: lane `i` is entry `i`'s, 0 when it is
            /// gone or not written.
            small: [small_lanes]u8,
            ix: Index,
        };
        comptime {
            std.debug.assert(@sizeOf(Index) <= small_lanes);
        }

        // The fields are laid out in order (an `extern struct`), each
        // 8-byte word holding fields written together: `len` and `live`,
        // written by every put and take, share no word with a field a
        // lookup reads, as `shift` is; a store into a word and a narrower
        // load of another part of it, soon after, wait on each other on
        // Apple cores. The prelude's Map and Set put their table first,
        // so a Map's address is its table's: with the table 8 bytes in, a
        // loop over a List of Maps kept two pointers for each and spilled
        // one (bench/hash's int16 inserts 8-10% slower on pup).

        /// The entries, `cap` of them; undefined while `cap` is 0.
        entries: [*]E = undefined,
        /// Entries written, gone or not.
        len: u32 = 0,
        /// Entries not gone; `len - live` are gone.
        live: u32 = 0,
        /// At 16 bytes into the table, and so into a Map, which starts
        /// with it: in a Map 16-aligned, as a List's or the stack's are,
        /// no group of the small tags straddles two cache lines. At 24, a
        /// group did, wherever the Map sat 16 bytes into a line
        /// (bench/hash's churn16 3-5% slower on pup).
        u: Held = .{ .small = @splat(0) },
        cap: u32 = 0,
        /// The hash's shift right that leaves its group, 64 less the log
        /// of the index's groups; 0 in a small table, which has no index.
        shift: u8 = 0,
        /// Whether the index is far (`far_bytes`). A `Bool`, so a `Map?`
        /// holds its `none` here (`rt.nicheOf`), never in a pointer.
        far: bool = false,
        /// Whether an indexed table has made its gone bits.
        has_gone: bool = false,
        /// Under `RIG_MAP_TRACE`, how many times the index was built
        /// anew (`traceRebuilds`); nothing otherwise.
        trace_rebuilds: if (rt.map_trace) u32 else void = if (rt.map_trace) 0 else {},

        pub const empty: Self = .{};
        /// Its arguments, for `rt.typeName`.
        pub const __rig_args = if (is_set) .{K} else .{ K, V };
        /// `rt.cloneValue` clones it by `clone`.
        pub const __rig_ordered = {};

        /// Whether the table has no index.
        inline fn isSmall(self: *const Self) bool {
            return self.shift == 0;
        }

        /// The index's groups; 0 in a small table.
        inline fn groupCount(self: *const Self) usize {
            return if (self.shift == 0) 0 else self.u.ix.groups;
        }

        /// The index's groups less one: its group mask.
        inline fn groupMask(self: *const Self) usize {
            return @as(usize, self.u.ix.groups) -% 1;
        }

        inline fn hashShift(self: *const Self) u6 {
            return @truncate(self.shift);
        }

        /// The words of gone bits held.
        inline fn goneWordsHeld(self: *const Self) usize {
            return if (self.has_gone) goneWords(self.cap) else 0;
        }

        // hashing, tags, groups /////////////////////////////////////////////

        inline fn hashKey(k: anytype) u64 {
            return rt.hash(k);
        }

        inline fn hashOf(e: *const E) u64 {
            return if (stores_hash) e.hash else rt.hash(e.key);
        }

        inline fn eqlKey(stored: *const K, k: KeyView) bool {
            return switch (@typeInfo(K)) {
                .int, .bool, .@"enum" => stored.* == k,
                else => rt.eql(stored.*, k),
            };
        }

        inline fn keyMatch(e: *const E, k: KeyView, h: u64) bool {
            if (stores_hash) return e.hash == h and eqlKey(&e.key, k);
            return eqlKey(&e.key, k);
        }

        inline fn tagOf(h: u64) u8 {
            return @max(@as(u8, @truncate(h)), 1);
        }

        inline fn classBit(tag: u8) u8 {
            return @as(u8, 1) << @intCast(tag & 7);
        }

        inline fn home(self: *const Self, h: u64) usize {
            return @intCast(h >> self.hashShift());
        }

        inline fn makeEntry(k: K, v: V, h: u64) E {
            return if (stores_hash) .{ .key = k, .value = v, .hash = h } else .{ .key = k, .value = v };
        }

        inline fn firstLane(m: LaneMask) usize {
            return @as(usize, @ctz(m)) >> lane_shift;
        }

        /// The tag lanes of `grp` that hold `tag` (0: the free lanes).
        inline fn match(grp: *const Group, tag: u8) LaneMask {
            return matchAll(grp, tag) & tag_lanes;
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

        /// Write lane `lane` of the 16 tags `grp` as `x`: the 16 written
        /// whole from a register, so the next lookup's load of them takes
        /// them from the store, where a byte's store would stall it.
        inline fn writeLane(grp: *Group, lane: usize, x: u8) void {
            const ids: @Vector(16, u8) = std.simd.iota(u8, 16);
            const v: @Vector(16, u8) = grp.*;
            grp.* = @select(u8, ids == @as(@Vector(16, u8), @splat(@intCast(lane))), @as(@Vector(16, u8), @splat(x)), v);
        }

        inline fn lowBits(n: usize) u64 {
            return if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
        }

        // the entries' block ////////////////////////////////////////////////

        fn goneWords(n: usize) usize {
            return (n + 63) / 64;
        }

        /// Room for `new_cap` entries: the entries alone in their block,
        /// whose size is a whole number of entries, and the gone bits, if
        /// any, sized to match.
        fn resizeEntries(self: *Self, new_cap: usize) void {
            if (new_cap > max_entries) tooMany();
            const old_cap: usize = self.cap;
            self.entries = (if (old_cap == 0) rt.allocSlice(E, new_cap) else rt.reallocSlice(E, self.entries[0..old_cap], new_cap)).ptr;
            self.cap = @intCast(new_cap);
            if (self.has_gone) self.sizeGone(goneWords(old_cap));
        }

        /// An indexed table's next room: twice its room, but from 32 to
        /// 48 and from 48 to 64, so a table of 33 to 48 entries holds 48
        /// rather than 64 (Trig's symbol tables of 41) and every larger
        /// room is a power of two again.
        fn nextRoom(cap: usize) usize {
            if (cap >= 32 and cap < 48) return 48;
            if (cap == 48) return 64;
            return 2 * cap;
        }

        noinline fn tooMany() noreturn {
            @branchHint(.cold);
            @panic(if (is_set) "a Set holds at most 4294967295 keys" else "a Map holds at most 4294967295 entries");
        }

        /// Entry `j`, which an index, a small table's tags, or a caller
        /// names. The index and the tags name only entries written, and
        /// the prelude only those the table gave it, so release builds
        /// test nothing; a debug build, which `rig run` and the suite
        /// make, tests that `j` is written and, where `live`, not gone,
        /// so a bug in the table panics there rather than reading past
        /// the entries (the panel's decision 10).
        inline fn entryOf(self: *const Self, j: usize, comptime live: bool) *E {
            if (builtin.mode == .debug) {
                if (j >= self.len) @panic("ordered: an entry index past the entries written");
                if (live and self.isGone(j)) @panic("ordered: an entry index names a gone entry");
            }
            return &self.entries[j];
        }

        /// The gone bits, `old` words of them, sized for `cap` entries,
        /// the new words clear.
        fn sizeGone(self: *Self, old: usize) void {
            const new = goneWords(self.cap);
            if (new <= old) return;
            self.u.ix.gone = (if (old == 0) rt.allocSlice(u64, new) else rt.reallocSlice(u64, self.u.ix.gone[0..old], new)).ptr;
            @memset(self.u.ix.gone[old..new], 0);
            self.has_gone = true;
        }

        /// Mark entry `j` of an indexed table gone, making its gone bits
        /// at the first.
        inline fn markGone(self: *Self, j: usize) void {
            if (!self.has_gone) self.sizeGone(0);
            self.u.ix.gone[j >> 6] |= @as(u64, 1) << @intCast(j & 63);
        }

        /// Clear the gone bits of the first `n` entries.
        fn clearGone(self: *Self, n: usize) void {
            if (self.has_gone) @memset(self.u.ix.gone[0..@min(goneWords(n), goneWords(self.cap))], 0);
        }

        /// Whether entry `j` is gone: its bit in `gone`; in a small table,
        /// whose gone bits stay clear, its tag is 0.
        inline fn isGone(self: *const Self, j: usize) bool {
            if (self.isSmall()) return self.u.small[j] == 0;
            return self.has_gone and (self.u.ix.gone[j >> 6] >> @intCast(j & 63)) & 1 != 0;
        }

        /// Word `w` of the gone bits of the entries written: in a small
        /// table, the lanes of its tags that are 0, below `len`.
        inline fn goneWord(self: *const Self, w: usize) u64 {
            if (self.isSmall()) {
                if (w > 0) return 0;
                const v: @Vector(small_lanes, u8) = self.u.small;
                const zero: u32 = @bitCast(v == @as(@Vector(small_lanes, u8), @splat(0)));
                return zero & lowBits(self.len);
            }
            return if (w < self.goneWordsHeld()) self.u.ix.gone[w] else 0;
        }

        // the index's block /////////////////////////////////////////////////

        /// The index's block, in words: the slots, a 64-byte line a group,
        /// then the tags, 16 bytes a group, 80 bytes a group in all, a size
        /// Rig's allocator holds exactly. Its alignment is a word's, which
        /// the allocator serves from its size classes (a wider one goes the
        /// slow way); a block of four groups or more starts a line there,
        /// as a large one starts a page, so each group's slots are one
        /// line, which a lookup prefetches with its tags.
        fn indexWords(groups: usize) usize {
            return 10 * groups;
        }

        fn indexBlock(self: *const Self) []u64 {
            const p: [*]u64 = @ptrCast(@alignCast(self.u.ix.slots));
            return p[0..indexWords(self.groupCount())];
        }

        fn freeIndex(self: *Self) void {
            if (!self.isSmall()) rt.freeSlice(u64, self.indexBlock());
            self.shift = 0;
        }

        fn maxLoad(groups: usize) u32 {
            return @intCast(15 * groups * max_load_milli / 1000);
        }

        /// The groups that hold `n` live entries at most 0.6 full: a power
        /// of two, at least 2.
        fn groupsFor(n: usize) usize {
            var g: usize = 2;
            while (9 * g < n) g *= 2;
            return g;
        }

        /// A new index of `groups` free groups, in place of the old.
        fn newIndex(self: *Self, groups: usize) void {
            // The old index is freed first: the new one is filled from
            // the entries, so the two never need to live at once.
            self.freeIndex();
            const b = rt.allocSlice(u64, indexWords(groups));
            // Only the tags need zeros: a slot is read only at a lane
            // whose tag is set, which `place` writes with it.
            @memset(b[8 * groups ..], 0);
            self.u.ix.slots = @ptrCast(b.ptr);
            self.u.ix.tags = @ptrCast(b.ptr + 8 * groups);
            self.shift = @intCast(@as(u32, 64) - std.math.log2_int(usize, groups));
            self.u.ix.max_load = maxLoad(groups);
            self.u.ix.groups = @intCast(groups);
            self.far = indexWords(groups) * 8 > far_bytes;
        }

        /// The first free lane from `g`'s group on takes entry `j`; each
        /// full group on the way marks the tag's class as overflowed.
        inline fn place(self: *Self, start: usize, tag: u8, j: usize) void {
            const mask = self.groupMask();
            var g = start;
            var step: usize = 0;
            while (true) {
                const grp = &self.u.ix.tags[g];
                const free = match(grp, 0);
                if (free != 0) {
                    const lane = firstLane(free);
                    writeLane(grp, lane, tag);
                    self.u.ix.slots[g][lane] = @intCast(j);
                    return;
                }
                writeLane(grp, 15, grp[15] | classBit(tag));
                step += 1;
                g = (g + step) & mask;
            }
        }

        /// A new index of `groups` groups, filled from the entries in
        /// order; the gone entries are dropped from the array first.
        noinline fn rebuild(self: *Self, groups: usize) void {
            if (rt.map_trace) self.trace_rebuilds +%= 1;
            if (self.len != self.live) self.moveLive(null);
            self.newIndex(groups);
            self.fill();
        }

        /// Place every entry, in order. A far index is filled hashing
        /// sixteen entries ahead and prefetching the group each lands in.
        fn fill(self: *Self) void {
            const shift = self.hashShift();
            const es = self.entries;
            const n: usize = self.len;
            if (!self.far) {
                for (0..n) |j| {
                    const h = hashOf(&es[j]);
                    self.place(@intCast(h >> shift), tagOf(h), j);
                }
                return;
            }
            const ahead = 16;
            var ring: [ahead]u64 = undefined;
            var it: usize = 0;
            while (it < ahead and it < n) : (it += 1) {
                const h = hashOf(&es[it]);
                ring[it] = h;
                @prefetch(&self.u.ix.tags[@intCast(h >> shift)], .{ .rw = .write });
                @prefetch(&self.u.ix.slots[@intCast(h >> shift)], .{ .rw = .write });
            }
            for (0..n) |j| {
                const h = ring[j % ahead];
                if (it != n) {
                    const nh = hashOf(&es[it]);
                    ring[j % ahead] = nh;
                    @prefetch(&self.u.ix.tags[@intCast(nh >> shift)], .{ .rw = .write });
                    @prefetch(&self.u.ix.slots[@intCast(nh >> shift)], .{ .rw = .write });
                    it += 1;
                }
                self.place(@intCast(h >> shift), tagOf(h), j);
            }
        }

        /// Move the live entries down, in order. With `before`, record
        /// the gone entries before each word of gone bits, and leave the
        /// gone bits for the index's renumbering; without, clear them.
        fn moveLive(self: *Self, before: ?[]u32) void {
            const n: usize = self.len;
            const es = self.entries;
            const words = goneWords(n);
            var dst: usize = 0;
            var dropped: u32 = 0;
            for (0..words) |w| {
                if (before) |b| b[w] = dropped;
                const base = w * 64;
                const lim = @min(64, n - base);
                const g = self.goneWord(w);
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
            if (before == null) self.clearGone(n);
            self.len = @intCast(dst);
        }

        /// Compact the entries under the same index: move the live ones
        /// down, then renumber every slot by the gone entries below it. No
        /// hash, no probe; tags and positions stay.
        fn compact(self: *Self) void {
            const words = goneWords(self.len);
            var stack: [64]u32 = undefined;
            const before = if (words <= stack.len) stack[0..words] else rt.allocSlice(u32, words);
            defer if (words > stack.len) rt.freeSlice(u32, before);
            const gone = self.u.ix.gone;
            self.moveLive(before);
            for (0..self.groupCount()) |g| {
                var full = ~match(&self.u.ix.tags[g], 0) & tag_lanes;
                const sl = &self.u.ix.slots[g];
                while (full != 0) : (full &= full - 1) {
                    const lane = firstLane(full);
                    const j: usize = sl[lane];
                    const w = j >> 6;
                    const below = gone[w] & lowBits(j & 63);
                    sl[lane] = @intCast(j - before[w] - @popCount(below));
                }
            }
            self.clearGone(words * 64);
        }

        /// A small table's live entries moved down, and their tags with
        /// them.
        fn compactSmall(self: *Self) void {
            const n: usize = self.len;
            self.moveLive(null);
            var d: usize = 0;
            for (0..n) |i| {
                if (self.u.small[i] == 0) continue;
                self.u.small[d] = self.u.small[i];
                d += 1;
            }
            @memset(self.u.small[d..], 0);
        }

        /// Room for one more entry, and room in the index for it.
        noinline fn reserveOne(self: *Self) void {
            if (self.live >= self.u.ix.max_load) {
                self.rebuild(@max(groupsFor(@as(usize, self.live) + 1), self.groupCount()));
            }
            if (self.len == self.cap) {
                const dead = self.len - self.live;
                if (dead != 0 and dead >= self.cap / 4) {
                    self.compact();
                } else {
                    self.resizeEntries(nextRoom(self.cap));
                }
            }
        }

        /// Empty the table, keeping its memory and its index: taking the
        /// last live entry.
        fn reset(self: *Self) void {
            const n: usize = self.len;
            self.len = 0;
            self.live = 0;
            // A small table's tags are 0 already, each take having cleared
            // its own, and its gone bits stay clear.
            if (self.isSmall()) return;
            self.clearGone(n);
            const t: [*]u8 = @ptrCast(self.u.ix.tags);
            @memset(t[0 .. 16 * self.groupCount()], 0);
            self.u.ix.max_load = maxLoad(self.groupCount());
        }

        /// Write lane `i` of a small table's tags (`writeLane`).
        inline fn setSmallTag(self: *Self, i: usize, tag: u8) void {
            writeLane(self.u.small[i & 16 ..][0..16], i & 15, tag);
        }

        // finding ///////////////////////////////////////////////////////////

        const Found = struct { g: usize, lane: usize, j: usize };

        /// The entry of `k` in a small table (no index): the lanes of its
        /// tag among the small tags, each an entry.
        inline fn findSmall(self: *const Self, k: KeyView, h: u64) ?usize {
            const tag = tagOf(h);
            var m = matchAll(self.u.small[0..16], tag);
            while (m != 0) : (m &= m - 1) {
                const i = firstLane(m);
                if (keyMatch(self.entryOf(i, false), k, h)) return i;
            }
            if (self.len > 16) {
                @branchHint(.unlikely);
                m = matchAll(self.u.small[16..32], tag);
                while (m != 0) : (m &= m - 1) {
                    const i = 16 + firstLane(m);
                    if (keyMatch(self.entryOf(i, false), k, h)) return i;
                }
            }
            return null;
        }

        /// The probe from group `start`, `step` groups walked.
        inline fn probeFrom(self: *const Self, k: KeyView, h: u64, tag: u8, start: usize, start_step: usize) ?Found {
            const mask = self.groupMask();
            const bit = classBit(tag);
            var g = start;
            var step = start_step;
            while (true) {
                const grp = &self.u.ix.tags[g];
                var m = match(grp, tag);
                while (m != 0) : (m &= m - 1) {
                    const lane = firstLane(m);
                    const j: usize = self.u.ix.slots[g][lane];
                    if (keyMatch(self.entryOf(j, false), k, h)) return .{ .g = g, .lane = lane, .j = j };
                }
                if (grp[15] & bit == 0) return null;
                step += 1;
                if (step > mask) return null;
                g = (g + step) & mask;
            }
        }

        /// The walk past the home group `home_g`, out of line.
        noinline fn probePastHome(self: *const Self, k: KeyView, h: u64, tag: u8, home_g: usize) ?Found {
            @branchHint(.cold);
            return self.probeFrom(k, h, tag, (home_g + 1) & self.groupMask(), 1);
        }

        /// The entry of `k`, whose hash is `h`, in the index: the home
        /// group inline, and the walk past it out of line unless
        /// `walk_inline` (a take, a call of its own, keeps it inline: a
        /// call in it costs its prologue more saved registers than the
        /// walk costs).
        inline fn findIndexed(self: *const Self, k: KeyView, h: u64, comptime walk_inline: bool) ?Found {
            const tag = tagOf(h);
            const g = self.home(h);
            @prefetch(&self.u.ix.slots[g], .{});
            const grp = &self.u.ix.tags[g];
            var m = match(grp, tag);
            while (m != 0) : (m &= m - 1) {
                const lane = firstLane(m);
                const j: usize = self.u.ix.slots[g][lane];
                if (keyMatch(self.entryOf(j, false), k, h)) return .{ .g = g, .lane = lane, .j = j };
            }
            if (grp[15] & classBit(tag) != 0) {
                @branchHint(.unlikely);
                if (walk_inline) return self.probeFrom(k, h, tag, (g + 1) & (self.groupMask()), 1);
                return self.probePastHome(k, h, tag, g);
            }
            return null;
        }

        inline fn findHashed(self: *const Self, k: KeyView, h: u64) ?usize {
            if (self.isSmall()) {
                if (self.cap == 0) return null;
                return self.findSmall(k, h);
            }
            const f = self.findIndexed(k, h, false) orelse return null;
            return f.j;
        }

        // adding ////////////////////////////////////////////////////////////

        /// Add the entry `k`, `v`, whose key is new and hashes to `h`, and
        /// give its index. An insert into room the table has is inline;
        /// making room is out of line.
        inline fn insertHashed(self: *Self, k: K, v: V, h: u64) usize {
            if (self.isSmall()) {
                const j: usize = self.len;
                if (j < self.cap and j < small_lanes and self.live < small) {
                    self.entries[j] = makeEntry(k, v, h);
                    self.setSmallTag(j, tagOf(h));
                    self.len = @intCast(j + 1);
                    self.live += 1;
                    return j;
                }
                return self.insertSmallSlow(k, v, h);
            }
            if (self.len == self.cap or self.live >= self.u.ix.max_load) self.reserveOne();
            const j: usize = self.len;
            self.entries[j] = makeEntry(k, v, h);
            self.len = @intCast(j + 1);
            self.live += 1;
            // The home group's first free lane, inline; a full home group
            // walks on out of line.
            const g = self.home(h);
            const grp = &self.u.ix.tags[g];
            const free = match(grp, 0);
            if (free != 0) {
                const lane = firstLane(free);
                writeLane(grp, lane, tagOf(h));
                self.u.ix.slots[g][lane] = @intCast(j);
            } else self.placePast(g, tagOf(h), j);
            return j;
        }

        noinline fn placePast(self: *Self, g: usize, tag: u8, j: usize) void {
            @branchHint(.unlikely);
            self.place(g, tag, j);
        }

        /// A small table's first entry; one whose array is full, given
        /// room up to `small_lanes` or compacted; or one with `small` live
        /// entries, given its index, sized for the entries' next room.
        noinline fn insertSmallSlow(self: *Self, k: K, v: V, h: u64) usize {
            if (self.cap == 0) {
                self.resizeEntries(first_cap);
            } else if (self.live < small and self.len == self.cap and self.cap < small_lanes) {
                self.resizeEntries(@min(2 * @as(usize, self.cap), small_lanes));
            } else if (self.live < small) {
                self.compactSmall();
            } else {
                self.rebuild(groupsFor(2 * @as(usize, self.cap)));
                if (self.len == self.cap) self.resizeEntries(nextRoom(self.cap));
                const j: usize = self.len;
                self.entries[j] = makeEntry(k, v, h);
                self.len = @intCast(j + 1);
                self.live += 1;
                self.place(self.home(h), tagOf(h), j);
                return j;
            }
            const j: usize = self.len;
            self.entries[j] = makeEntry(k, v, h);
            self.u.small[j] = tagOf(h);
            self.len = @intCast(j + 1);
            self.live += 1;
            return j;
        }

        // take //////////////////////////////////////////////////////////////

        /// The entry of `k` taken out of the index (its lane freed) and
        /// left to the caller, who drops it from the live entries
        /// (`dropEntry`); or null.
        inline fn unlink(self: *Self, k: KeyView) ?usize {
            const h = hashKey(k);
            if (self.isSmall()) {
                if (self.cap == 0) return null;
                const i = self.findSmall(k, h) orelse return null;
                self.setSmallTag(i, 0);
                return i;
            }
            const f = self.findIndexed(k, h, true) orelse return null;
            const grp = &self.u.ix.tags[f.g];
            writeLane(grp, f.lane, 0);
            if (grp[15] & classBit(tagOf(h)) != 0) self.u.ix.max_load -= 1;
            return f.j;
        }

        /// The last entry written, `j`, cut off, with the gone entries
        /// before it; out of line, as a take of the last entry is rare
        /// beside the others.
        /// Entry `j`, whose lane is freed and whose key and value are
        /// handed on or dropped, leaves the live entries: marked gone; or
        /// cut off, with the gone entries before it, when it is the last
        /// written; or, when it was the last live entry, the table emptied.
        inline fn dropEntry(self: *Self, j: usize) void {
            self.live -= 1;
            if (self.live == 0) {
                self.reset();
            } else if (j + 1 == self.len) {
                var n = j;
                while (self.isGone(n - 1)) {
                    n -= 1;
                    if (!self.isSmall()) self.u.ix.gone[n >> 6] &= ~(@as(u64, 1) << @intCast(n & 63));
                }
                self.len = @intCast(n);
            } else if (!self.isSmall()) {
                self.markGone(j);
            }
        }

        // the built-in's members ////////////////////////////////////////////
        //
        // Each is what resolve.registerBuiltins declares for
        // `OrderedMap[K, V]` or `OrderedSet[K]`, lowered as emit lowers a
        // call: `?K` a `ReadView(K)`, `!V` a `*V`, `Int` an `i64`, `T?` an
        // `Opt(T)`, a closure view an `rt.FnRef`.

        /// `find(?@, k: ?K) -> Int?`: the entry of `k`.
        pub inline fn find(self: *const Self, k: KeyView) ?i64 {
            const j = self.findHashed(k, hashKey(k)) orelse return null;
            return @intCast(j);
        }

        /// `get(?@, k: ?K) -> (?V)? from @`: the value of `k`, viewed
        /// where the lookup found its entry.        ///
        /// Its origin is narrowed to self (`resolve.fromSelf`), which holds
        /// only because `k` is hashed and compared, never returned or
        /// stored: returning anything reached through `k` would make that
        /// narrowing unsound.
        pub inline fn get(self: *const Self, k: KeyView) ?rt.ReadView(V) {
            const j = self.findHashed(k, hashKey(k)) orelse return null;
            return rt.lend(&self.entryOf(j, true).value);
        }

        /// `edit(!@, k: ?K) -> (!V)? from @`: the value of `k`, lent to
        /// write.        ///
        /// Its origin is narrowed to self (`resolve.fromSelf`), which holds
        /// only because `k` is hashed and compared, never returned or
        /// stored: returning anything reached through `k` would make that
        /// narrowing unsound.
        pub inline fn edit(self: *Self, k: KeyView) ?*V {
            const j = self.findHashed(k, hashKey(k)) orelse return null;
            return &self.entryOf(j, true).value;
        }

        /// `key(?@, j: Int) -> ?K`.
        pub inline fn key(self: *const Self, j: i64) KeyView {
            return rt.lend(&self.entryOf(@intCast(j), true).key);
        }

        /// `value(?@, j: Int) -> ?V`.
        pub inline fn value(self: *const Self, j: i64) rt.ReadView(V) {
            return rt.lend(&self.entryOf(@intCast(j), true).value);
        }

        /// `value_mut(!@, j: Int) -> !V`.
        pub inline fn value_mut(self: *Self, j: i64) *V {
            return &self.entryOf(@intCast(j), true).value;
        }

        /// `put(!@, k: K, v: V) -> Bool`: `v` under `k`; a key already
        /// there keeps its place and its old value and `k` are dropped.
        /// True when `k` was new.
        pub inline fn put(self: *Self, k: K, v: V) bool {
            var kk = k;
            const h = hashKey(rt.lend(&kk));
            if (self.findHashed(rt.lend(&kk), h)) |j| {
                rt.dropElement(K, &kk);
                const e = &self.entries[j];
                rt.dropElement(V, &e.value);
                e.value = v;
                return false;
            }
            _ = self.insertHashed(kk, v, h);
            return true;
        }

        /// `replace(!@, k: K, v: V) -> V?`: as `put`, handing the old
        /// value back.
        pub inline fn replace(self: *Self, k: K, v: V) rt.Opt(V) {
            var kk = k;
            const h = hashKey(rt.lend(&kk));
            if (self.findHashed(rt.lend(&kk), h)) |j| {
                rt.dropElement(K, &kk);
                const e = &self.entries[j];
                const old = e.value;
                e.value = v;
                return rt.pack(rt.Opt(V), old);
            }
            _ = self.insertHashed(kk, v, h);
            return rt.pack(rt.Opt(V), null);
        }

        /// `put_new(!@, k: K, v: V) -> Bool`: `v` under `k` only when `k`
        /// is new; otherwise both are dropped.
        pub inline fn put_new(self: *Self, k: K, v: V) bool {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
            if (self.findHashed(rt.lend(&kk), h) != null) {
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return false;
            }
            _ = self.insertHashed(kk, vv, h);
            return true;
        }

        /// `add(!@, k: K) -> Bool`: a Set's `put_new`.
        pub inline fn add(self: *Self, k: K) bool {
            return self.put_new(k, {});
        }

        /// `ensure(!@, k: K, v: V) -> Int`: the entry of `k`, made of `k`
        /// and `v` when `k` is new; otherwise both are dropped.
        pub inline fn ensure(self: *Self, k: K, v: V) i64 {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
            if (self.findHashed(rt.lend(&kk), h)) |j| {
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return @intCast(j);
            }
            return @intCast(self.addNew(kk, vv, h));
        }

        /// `insert_new(!@, k: K, v: V) -> Int`: the entry of `k`, which
        /// is not there, made of `k` and `v`.
        pub fn insert_new(self: *Self, k: K, v: V) i64 {
            @branchHint(.unlikely);
            var kk = k;
            return @intCast(self.insertHashed(kk, v, hashKey(rt.lend(&kk))));
        }

        /// An insert out of line, so a lookup that finds its key stays
        /// short.
        noinline fn addNew(self: *Self, k: K, v: V, h: u64) usize {
            return self.insertHashed(k, v, h);
        }

        /// `take(!@, k: ?K) -> V?` (a Set's: `-> K?`): the entry of `k`
        /// taken out; a Map drops its key and hands its value back.
        pub inline fn take(self: *Self, k: KeyView) rt.Opt(if (is_set) K else V) {
            const R = rt.Opt(if (is_set) K else V);
            const j = self.unlink(k) orelse return rt.pack(R, null);
            const e = &self.entries[j];
            if (is_set) {
                const out = e.key;
                self.dropEntry(j);
                return rt.pack(R, out);
            }
            rt.dropElement(K, &e.key);
            const out = e.value;
            self.dropEntry(j);
            return rt.pack(R, out);
        }

        /// `count(?@) -> Int`: the live entries.
        pub inline fn count(self: *const Self) i64 {
            return self.live;
        }

        /// `written(?@) -> Int`: the entries written, gone or not.
        pub inline fn written(self: *const Self) i64 {
            return self.len;
        }

        /// `holes(?@) -> Bool`: whether an entry written is gone.
        pub inline fn holes(self: *const Self) bool {
            return self.len != self.live;
        }

        /// `live_from(?@, j: Int) -> Int`: the first live entry from `j`
        /// on; `written` when none is. Called once a run of a walk.
        pub noinline fn live_from(self: *const Self, from: i64) i64 {
            const n: usize = self.len;
            var j: usize = @intCast(from);
            while (j < n) {
                const w = j >> 6;
                const live_bits = ~self.goneWord(w) >> @intCast(j & 63);
                if (live_bits != 0) {
                    j += @ctz(live_bits);
                    return @intCast(@min(j, n));
                }
                j = (w + 1) * 64;
            }
            return @intCast(n);
        }

        /// `gone_from(?@, j: Int) -> Int`: the first gone entry from `j`
        /// on; `written` when none is.
        pub noinline fn gone_from(self: *const Self, from: i64) i64 {
            const n: usize = self.len;
            var j: usize = @intCast(from);
            while (j < n) {
                const w = j >> 6;
                const gone_bits = self.goneWord(w) >> @intCast(j & 63);
                if (gone_bits != 0) {
                    j += @ctz(gone_bits);
                    return @intCast(@min(j, n));
                }
                j = (w + 1) * 64;
            }
            return @intCast(n);
        }

        /// `nth(?@, i: Int) -> Int`: the entry of the `i`th live one,
        /// `0 <= i < count`: `i` while none is gone; else counted 64 at a
        /// time.
        pub fn nth(self: *const Self, i: i64) i64 {
            if (self.len == self.live) return i;
            const n: usize = self.len;
            var left: usize = @intCast(i);
            var w: usize = 0;
            while (w * 64 < n) : (w += 1) {
                var live_bits = ~self.goneWord(w) & lowBits(n - w * 64);
                const c: usize = @popCount(live_bits);
                if (left < c) {
                    while (left > 0) : (left -= 1) live_bits &= live_bits - 1;
                    return @intCast(w * 64 + @ctz(live_bits));
                }
                left -= c;
            }
            return @intCast(n);
        }

        /// `update(!@, f: ?sub(?K, !V))`: `f` called with each live
        /// entry's key to read and value to write, in order.
        pub fn update(self: *Self, f: anytype) void {
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const entry = &self.entries[j];
                f.call(.{ rt.lend(&entry.key), &entry.value });
            }
        }

        /// `retain(!@, f)`: keep the entries for which `f` is true, in
        /// order; one it rejects is dropped then. A Map's `f` gets each
        /// key to read and value to write, a Set's each key.
        pub fn retain(self: *Self, f: anytype) void {
            var removed = false;
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const e = &self.entries[j];
                const keep = if (is_set)
                    f.call(.{rt.lend(&e.key)})
                else
                    f.call(.{ rt.lend(&e.key), &e.value });
                if (keep) continue;
                rt.dropElement(V, &e.value);
                rt.dropElement(K, &e.key);
                if (self.isSmall()) {
                    self.u.small[j] = 0;
                } else self.markGone(j);
                self.live -= 1;
                removed = true;
            }
            if (removed) {
                if (rt.map_trace) self.trace_rebuilds +%= 1;
                self.reindex();
            }
        }

        /// The entries compacted and found again after `retain`: the
        /// index refilled under the same groups, or a small table's tags
        /// made again.
        fn reindex(self: *Self) void {
            if (self.live == 0) {
                self.reset();
                return;
            }
            self.moveLive(null);
            if (self.isSmall()) {
                @memset(&self.u.small, 0);
                for (0..self.len) |j| self.u.small[j] = tagOf(hashOf(&self.entries[j]));
                return;
            }
            const t: [*]u8 = @ptrCast(self.u.ix.tags);
            @memset(t[0 .. 16 * self.groupCount()], 0);
            self.u.ix.max_load = maxLoad(self.groupCount());
            self.fill();
        }

        /// `clear(!@)`: drop every entry and the index, keeping the
        /// entries' memory.
        pub fn clear(self: *Self) void {
            self.dropLive();
            // The small tags take the index's place: the gone bits go
            // with it.
            if (self.has_gone) rt.freeSlice(u64, self.u.ix.gone[0..goneWords(self.cap)]);
            self.has_gone = false;
            self.freeIndex();
            self.len = 0;
            self.live = 0;
            @memset(&self.u.small, 0);
        }

        /// `reserve(!@, n: Int)`: room for `n` more entries at once, the
        /// entries and the index sized for them, so the next `n` puts of
        /// new keys grow neither.
        pub fn reserve(self: *Self, n: i64) void {
            if (n <= 0) return;
            const more: usize = @intCast(n);
            // The limit first: past it, the index would be built and
            // zeroed before the entries' growth traps.
            if (@as(usize, self.len) + more > max_entries) tooMany();
            const want = @as(usize, self.live) + more;
            if (want > small) {
                const g = groupsFor(want);
                if (g > self.groupCount()) self.rebuild(g);
            } else if (self.isSmall() and @as(usize, self.len) + more > small_lanes) {
                self.compactSmall();
            }
            const total = @as(usize, self.len) + more;
            if (total > self.cap) self.resizeEntries(total);
        }

        // drop, clone, walk /////////////////////////////////////////////////

        /// Drop every live entry, the last first, its value before its
        /// key, as a List drops its elements and an object its fields.
        fn dropLive(self: *Self) void {
            if (comptime !rt.needsDrop(E)) return;
            var j: usize = self.len;
            while (j > 0) {
                j -= 1;
                if (self.isGone(j)) continue;
                const e = &self.entries[j];
                rt.dropElement(V, &e.value);
                rt.dropElement(K, &e.key);
            }
        }

        /// What `rt.dropElement` runs: every live entry dropped, then the
        /// entries' block and the index freed.
        pub fn __rig_drop(self: *Self) void {
            self.dropLive();
            if (self.cap != 0) rt.freeSlice(E, self.entries[0..self.cap]);
            if (self.has_gone) rt.freeSlice(u64, self.u.ix.gone[0..goneWords(self.cap)]);
            self.has_gone = false;
            self.freeIndex();
            self.* = .{};
        }

        /// `+m`: a new table of the live entries, each cloned, in order.
        pub fn clone(self: *const Self) Self {
            var out: Self = .{};
            if (self.live == 0) return out;
            out.reserve(self.live);
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const e = &self.entries[j];
                const h = hashOf(e);
                _ = out.insertHashed(rt.cloneValue(&e.key), rt.cloneValue(&e.value), h);
            }
            return out;
        }

        /// Under `RIG_MAP_TRACE`, the index's builds so far and its lanes,
        /// which the traced `Map` and `Set` record as a `grow` when the
        /// count moves (src/map_trace.zig).
        pub fn traceRebuilds(self: *const Self) u32 {
            return self.trace_rebuilds;
        }

        pub fn traceSlots(self: *const Self) u64 {
            return @as(u64, self.groupCount()) * 16;
        }

        /// The invariants, for tests: the counts agree; every live entry
        /// has exactly one full lane, on its probe sequence, with its
        /// tag; every group it walked past marks its class; no lane names
        /// a gone entry; the gone bits lie below `len`.
        fn verify(self: *const Self) !void {
            if (self.live > self.len or self.len > self.cap) return error.Corrupt;
            if (self.cap == 0) return;
            var gone_count: usize = 0;
            for (0..self.goneWordsHeld()) |w| {
                const g = self.u.ix.gone[w];
                gone_count += @popCount(g);
                if (g != 0 and w * 64 + 64 - @clz(g) > self.len) return error.Corrupt;
            }
            if (gone_count != (if (self.isSmall()) 0 else self.len - self.live)) return error.Corrupt;
            if (self.len != 0 and self.isGone(self.len - 1)) return error.Corrupt;
            if (self.isSmall()) {
                if (self.len > small_lanes or self.live > small) return error.Corrupt;
                for (0..small_lanes) |i| {
                    const t = self.u.small[i];
                    if (i >= self.len or self.isGone(i)) {
                        if (t != 0) return error.Corrupt;
                    } else if (t != tagOf(hashOf(&self.entries[i]))) return error.Corrupt;
                }
                return;
            }
            if (self.live > self.u.ix.max_load) return error.Corrupt;
            var full: usize = 0;
            for (0..self.groupCount()) |g| for (0..15) |lane| {
                if (self.u.ix.tags[g][lane] == 0) continue;
                full += 1;
                const j = self.u.ix.slots[g][lane];
                if (j >= self.len or self.isGone(j)) return error.Corrupt;
                if (tagOf(hashOf(&self.entries[j])) != self.u.ix.tags[g][lane]) return error.Corrupt;
            };
            if (full != self.live) return error.Corrupt;
            const mask = self.groupMask();
            for (0..self.len) |j| {
                if (self.isGone(j)) continue;
                const h = hashOf(&self.entries[j]);
                const tag = tagOf(h);
                var g = self.home(h);
                var step: usize = 0;
                while (true) {
                    var hits: usize = 0;
                    for (0..15) |lane| {
                        if (self.u.ix.tags[g][lane] == tag and self.u.ix.slots[g][lane] == j) hits += 1;
                    }
                    if (hits > 1) return error.Corrupt;
                    if (hits == 1) break;
                    if (self.u.ix.tags[g][15] & classBit(tag) == 0) return error.Corrupt;
                    step += 1;
                    if (step > mask) return error.Corrupt;
                    g = (g + step) & mask;
                }
            }
        }

        /// The entries a walk for printing passes (`isLive`, `entryAt`).
        pub fn walkEnd(self: *const Self) usize {
            return self.len;
        }

        /// Whether entry `j`, below `written`, is live: what printing
        /// walks.
        pub fn isLive(self: *const Self, j: usize) bool {
            return !self.isGone(j);
        }

        /// Entry `j`'s key and value, for printing.
        pub fn entryAt(self: *const Self, j: usize) *const E {
            return &self.entries[j];
        }
    };
}

// tests //////////////////////////////////////////////////////////////////////

const testing = std.testing;

test "ordered: puts, takes, and walks keep first-put order" {
    var m: OrderedMap(i64, i64) = .{};
    defer m.__rig_drop();
    var i: i64 = 0;
    while (i < 1000) : (i += 1) try testing.expect(m.put(i, i * 2));
    try testing.expect(!m.put(5, 7));
    try testing.expectEqual(@as(i64, 7), m.value(m.find(5).?));
    i = 0;
    while (i < 1000) : (i += 3) try testing.expectEqual(i * 2, rt.some(m.take(i)).?);
    try testing.expectEqual(@as(i64, 1000 - 334), m.count());
    var last: i64 = -1;
    var j: i64 = m.live_from(0);
    while (j < m.written()) {
        const end = m.gone_from(j);
        while (j < end) : (j += 1) {
            const k = m.key(j);
            try testing.expect(k > last and @mod(k, 3) != 0);
            last = k;
        }
        j = m.live_from(j);
    }
    try testing.expectEqual(@as(i64, 998), last);
}

test "ordered: the table is 56 bytes, as sema.minBytesOf says" {
    if (rt.map_trace) return;
    try testing.expectEqual(@as(usize, 56), @sizeOf(OrderedMap(u32, u32)));
    try testing.expectEqual(@as(usize, 56), @sizeOf(OrderedSet(u8)));
}

test "ordered: a small table turns over" {
    var s: OrderedSet(i64) = .{};
    defer s.__rig_drop();
    var i: i64 = 0;
    while (i < 200) : (i += 1) {
        try testing.expect(s.add(i));
        if (i >= 10) try testing.expectEqual(@as(i64, i - 10), rt.some(s.take(i - 10)).?);
    }
    try testing.expectEqual(@as(i64, 10), s.count());
    try testing.expect(s.isSmall());
    try testing.expect(s.find(195) != null and s.find(189) == null);
}

test "ordered: wide keys, with their hash kept and without" {
    const Plain = struct { owner: u64, lo: u64, hi: u64 };
    const Wide = struct { a: u64, b: u64, c: u64, d: u64, e: u64 };
    comptime std.debug.assert(!Ordered(Plain, u32).stores_hash and Ordered(Wide, u32).stores_hash);
    inline for (.{ Plain, Wide }) |K| {
        var m: OrderedMap(K, u32) = .{};
        defer m.__rig_drop();
        const keyOf = struct {
            fn f(i: u64) K {
                var k: K = undefined;
                inline for (@typeInfo(K).@"struct".field_names, 0..) |name, n| @field(k, name) = (i *% (n + 1)) ^ 0xA5C4;
                return k;
            }
        }.f;
        for (0..5000) |i| try testing.expect(m.put(keyOf(i), @intCast(i)));
        for (0..5000) |i| if (i % 3 == 0) try testing.expectEqual(@as(u32, @intCast(i)), rt.some(m.take(&keyOf(i))).?);
        try m.verify();
        for (0..10000) |i| {
            const got = m.find(&keyOf(i));
            try testing.expectEqual(i < 5000 and i % 3 != 0, got != null);
            if (got) |j| try testing.expectEqual(@as(u32, @intCast(i)), m.value(j));
        }
    }
}

/// The keys in first-put order, as a walk by runs gives them.
fn walkKeys(m: anytype, out: *std.ArrayList(i64)) !void {
    out.clearRetainingCapacity();
    var j: i64 = if (m.holes()) m.live_from(0) else 0;
    var end: i64 = if (m.holes()) m.gone_from(j) else m.written();
    while (j < m.written()) {
        while (j < end) : (j += 1) try out.append(testing.allocator, m.key(j));
        j = m.live_from(j);
        end = m.gone_from(j);
    }
}

test "ordered: random writes, takes, retains, and clears against a model" {
    const gpa = testing.allocator;
    for ([_]u64{ 40, 3000, 100_000 }, 0..) |range, seed| {
        var m: OrderedMap(i64, i64) = .{};
        defer m.__rig_drop();
        var order: std.ArrayList(i64) = .empty;
        defer order.deinit(gpa);
        var values: std.AutoHashMapUnmanaged(i64, i64) = .empty;
        defer values.deinit(gpa);
        var walked: std.ArrayList(i64) = .empty;
        defer walked.deinit(gpa);
        var prng = std.Random.DefaultPrng.init(seed + 7);
        const rnd = prng.random();
        for (0..60_000) |i| {
            const k: i64 = @intCast(rnd.uintLessThan(u64, range));
            switch (rnd.uintLessThan(u16, 1000)) {
                0...399 => {
                    const v: i64 = @intCast(i);
                    const gop = try values.getOrPut(gpa, k);
                    if (!gop.found_existing) try order.append(gpa, k);
                    gop.value_ptr.* = v;
                    try testing.expectEqual(!gop.found_existing, m.put(k, v));
                },
                400...649 => {
                    const want = values.fetchRemove(k);
                    if (want != null) _ = order.orderedRemove(std.mem.indexOfScalar(i64, order.items, k).?);
                    const got = rt.some(m.take(k));
                    try testing.expectEqual(want == null, got == null);
                    if (want) |kv| try testing.expectEqual(kv.value, got.?);
                },
                650...989 => {
                    const got = m.find(k);
                    try testing.expectEqual(values.get(k), if (got) |j| m.value(j) else null);
                },
                990...996 => {
                    // Keep the odd keys: a model's retain, in order.
                    const keep = struct {
                        fn odd(_: *anyopaque, args: struct { i64, *i64 }) bool {
                            return @mod(args[0], 2) == 1;
                        }
                    };
                    const F = struct { ctx: *anyopaque, call_fn: *const fn (*anyopaque, struct { i64, *i64 }) bool, fn call(f: @This(), args: struct { i64, *i64 }) bool {
                        return f.call_fn(f.ctx, args);
                    } };
                    var dummy: u8 = 0;
                    m.retain(F{ .ctx = &dummy, .call_fn = keep.odd });
                    var w: usize = 0;
                    for (order.items) |x| {
                        if (@mod(x, 2) == 1) {
                            order.items[w] = x;
                            w += 1;
                        } else _ = values.remove(x);
                    }
                    order.shrinkRetainingCapacity(w);
                },
                997 => {
                    m.clear();
                    order.clearRetainingCapacity();
                    values.clearRetainingCapacity();
                },
                else => m.reserve(@intCast(rnd.uintLessThan(u64, 64))),
            }
            try testing.expectEqual(@as(i64, @intCast(values.count())), m.count());
            if (i % 997 == 0) {
                try m.verify();
                try walkKeys(&m, &walked);
                try testing.expectEqualSlices(i64, order.items, walked.items);
                for (order.items, 0..) |x, n| try testing.expectEqual(x, m.key(m.nth(@intCast(n))));
                var c = m.clone();
                defer c.__rig_drop();
                try c.verify();
                try walkKeys(&c, &walked);
                try testing.expectEqualSlices(i64, order.items, walked.items);
            }
        }
    }
}
