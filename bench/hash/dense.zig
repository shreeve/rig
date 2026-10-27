//! A port of ankerl's `unordered_dense` 5.3.3 (`ankerl::unordered_dense::map`,
//! default `bucket_type::group`, `std::vector` values) to Zig, as close to
//! the header as the language allows, for bench/hash's `zig-dense`.
//!
//! The layout is 5.3.3's: every entry `{key, value}` in one dense array in
//! insertion order (until an erase), and an index of 88-byte blocks, one per
//! group of sixteen slots: sixteen one-byte fingerprints, eight one-byte
//! overflow counters, and sixteen `u32` value indexes. The group is
//! `hash >> shifts`; the fingerprint is the hash's low byte with 0 mapped
//! to 8, and its low three bits pick the counter. Groups are probed
//! triangularly. An insert increments its class's counter in every full
//! group it passes, an erase decrements them again (saturating at 255), and
//! a probe stops at the first group whose counter is zero. An erase moves
//! the last entry into the hole and repoints that entry's slot. A writing
//! hit found past its home group moves home when there is room (`move_home`).
//! Growth doubles the index at 0.8 full and refills it from the entries in
//! order, hashing sixteen ahead and prefetching each target block.
//!
//! The sixteen-lane compare is `@Vector(16, u8)`. On x86-64 it lowers to
//! `pcmpeqb` + `pmovmskb`, as the header's SSE2 path. On aarch64 it is
//! written as the header's NEON path: compare, view as eight `u16` lanes,
//! shift right by four and narrow (`shrn`), one `fmov` to a general
//! register, a 64-bit mask with lane i at bit 4i.
//!
//! The hash is the context's, taken as avalanching (ankerl's
//! `is_avalanching`): no extra mixing.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The header's NEON path: AArch64, little endian.
const neon = builtin.cpu.arch == .aarch64;

/// What a compare of sixteen fingerprints answers with: one bit per matching
/// lane, adjacent (SSE2) or four apart (NEON).
const LaneMask = if (neon) u64 else u32;
const lane_stride = if (neon) 4 else 1;

/// `bucket_type::group` followed by its sixteen value indexes:
/// `detail::group_block<group>`, 88 bytes, no padding.
const Block = extern struct {
    fingerprints: [16]u8,
    overflows: [8]u8,
    index: [16]u32,
};

comptime {
    std.debug.assert(@sizeOf(Block) == 88);
}

/// `detail::sentinel_groups`: an empty table's index, every slot empty and
/// every counter zero, shared and never written.
const sentinel_groups = 4;
const sentinel_blocks: [sentinel_groups]Block = @splat(std.mem.zeroes(Block));

/// `detail::fingerprint_words`, one byte wide: the fingerprint of every low
/// byte of a hash, 0 mapped to 8.
const fingerprint_table: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| e.* = if (i == 0) 8 else @intCast(i);
    break :blk t;
};

/// operator new's alignment, which the header's blocks get.
const block_align: std.mem.Alignment = .@"16";

pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const KV = struct { key: K, value: V };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        const ctx: Context = undefined;

        /// `detail::key_compare_is_call`: a slice key compares through a
        /// call, so the walk past the home group goes out of line.
        const compare_is_call = @typeInfo(K) == .pointer;

        const slots_per_group = 16;
        /// `pipeline_depth`.
        const pipeline_depth = 16;
        /// 2^(64 - shifts) groups.
        const initial_shifts: u8 = 64 - 2;
        const max_load_factor: f32 = 0.8;
        /// `max_size()` for a `u32` value index: 2^32.
        const max_bucket_count: usize = @as(usize, 1) << 32;

        // m_values: a std::vector.
        entries: [*]KV,
        len: usize,
        cap: usize,
        // m_buckets.
        blocks: [*]Block,
        num_groups: usize, // 0 while the sentinel is in use
        max_bucket_capacity: usize,
        group_mask: u32,
        shifts: u8,

        pub const empty: Self = .{
            .entries = undefined,
            .len = 0,
            .cap = 0,
            .blocks = @constCast(&sentinel_blocks),
            .num_groups = 0,
            .max_bucket_capacity = 0,
            .group_mask = 0,
            .shifts = initial_shifts,
        };

        const ProbeResult = struct {
            group_idx: u32,
            value_idx: u32,
            lane: u8,
            found: bool,
        };
        const not_found: ProbeResult = .{ .group_idx = 0, .value_idx = 0, .lane = 0, .found = false };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.cap != 0) gpa.free(self.entries[0..self.cap]);
            self.deallocateBuckets(gpa);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        // hashing ///////////////////////////////////////////////////////////

        inline fn mixedHash(k: K) u64 {
            return ctx.hash(k);
        }

        inline fn eql(a: K, b: K) bool {
            return ctx.eql(a, b);
        }

        inline fn groupIdxFromHash(self: *const Self, hash: u64) u32 {
            return @truncate(hash >> @intCast(self.shifts));
        }

        inline fn fingerprint(hash: u64) u8 {
            return fingerprint_table[@as(u8, @truncate(hash))];
        }

        /// Triangular: reaches every group of a power-of-two array.
        inline fn nextGroup(group_idx: u32, delta: *u32, mask: u32) u32 {
            delta.* += 1;
            return (group_idx +% delta.*) & mask;
        }

        // the index /////////////////////////////////////////////////////////

        inline fn firstLane(lanes: LaneMask) u32 {
            return @ctz(lanes) / lane_stride;
        }

        /// Lanes whose fingerprint is `fp`.
        inline fn matchFingerprint(block: *const Block, fp: u8) LaneMask {
            const v: @Vector(16, u8) = block.fingerprints;
            const eq = v == @as(@Vector(16, u8), @splat(fp));
            if (neon) {
                // vceqq_u8, vshrn_n_u16(.., 4), vget_lane_u64, & 0x1111...
                const bytes = @select(u8, eq, @as(@Vector(16, u8), @splat(0xFF)), @as(@Vector(16, u8), @splat(0)));
                const halves: @Vector(8, u16) = @bitCast(bytes);
                const nibbles: @Vector(8, u8) = @truncate(halves >> @splat(4));
                return @as(u64, @bitCast(nibbles)) & 0x1111111111111111;
            } else {
                // _mm_cmpeq_epi8, _mm_movemask_epi8
                return @as(u16, @bitCast(eq));
            }
        }

        inline fn matchEmpty(block: *const Block) LaneMask {
            return matchFingerprint(block, 0);
        }

        /// `prefetch_index`: the rest of the block, for a probe reading its
        /// fingerprints out of the first line: `p + 64` and `p + 87`.
        inline fn prefetchIndex(blocks: [*]const Block, group_idx: u32) void {
            const p: [*]const u8 = @ptrCast(&blocks[group_idx]);
            @prefetch(p + 64, .{});
            @prefetch(p + 87, .{});
        }

        /// `prefetch_block`: the block's first two lines, `p` and `p + 64`.
        inline fn prefetchBlock(block: *const Block) void {
            const p: [*]const u8 = @ptrCast(block);
            @prefetch(p, .{});
            @prefetch(p + 64, .{});
        }

        /// `probe_from`: the probe's loop, from a group and the distance
        /// already walked.
        inline fn probeFrom(self: *const Self, key: K, fp: u8, counter: u32, start: u32, start_delta: u32) ProbeResult {
            const groups = self.blocks;
            var group_idx = start;
            var delta = start_delta;
            while (true) {
                prefetchIndex(groups, group_idx);
                const group = &groups[group_idx];
                var lanes = matchFingerprint(group, fp);
                while (lanes != 0) : (lanes &= lanes - 1) {
                    const lane = firstLane(lanes);
                    const value_idx = group.index[lane];
                    if (eql(key, self.entries[value_idx].key)) {
                        return .{ .group_idx = group_idx, .value_idx = value_idx, .lane = @intCast(lane), .found = true };
                    }
                }
                if (group.overflows[counter] == 0 or delta == self.group_mask) return not_found;
                group_idx = nextGroup(group_idx, &delta, self.group_mask);
            }
        }

        /// `probe_past_home`: the walk out of line, for a key whose compare
        /// is a call.
        noinline fn probePastHome(self: *const Self, key: K, fp: u8, counter: u32, group_idx: u32, delta: u32) ProbeResult {
            return self.probeFrom(key, fp, counter, group_idx, delta);
        }

        /// `probe_after_home`.
        inline fn probeAfterHome(self: *const Self, key: K, fp: u8, counter: u32, home: *const Block, home_idx: u32) ProbeResult {
            if (home.overflows[counter] == 0 or self.group_mask == 0) return not_found;
            var delta: u32 = 0;
            const next = nextGroup(home_idx, &delta, self.group_mask);
            if (compare_is_call) {
                return self.probePastHome(key, fp, counter, next, delta);
            } else {
                return self.probeFrom(key, fp, counter, next, delta);
            }
        }

        /// `probe`.
        inline fn probe(self: *const Self, key: K, mh: u64) ProbeResult {
            const fp = fingerprint(mh);
            const counter: u32 = fp & 7;
            const home_idx = self.groupIdxFromHash(mh);
            if (!compare_is_call) {
                return self.probeFrom(key, fp, counter, home_idx, 0);
            } else {
                const groups = self.blocks;
                prefetchIndex(groups, home_idx);
                const home = &groups[home_idx];
                var lanes = matchFingerprint(home, fp);
                while (lanes != 0) : (lanes &= lanes - 1) {
                    const lane = firstLane(lanes);
                    const value_idx = home.index[lane];
                    if (eql(key, self.entries[value_idx].key)) {
                        return .{ .group_idx = home_idx, .value_idx = value_idx, .lane = @intCast(lane), .found = true };
                    }
                }
                return self.probeAfterHome(key, fp, counter, home, home_idx);
            }
        }

        /// `place_group`: the first free slot on the key's probe sequence
        /// takes it; every full group on the way counts it.
        inline fn placeGroup(self: *Self, fp: u8, counter: u32, start: u32, value_idx: u32) void {
            const groups = self.blocks;
            const mask = self.group_mask;
            var group_idx = start;
            var delta: u32 = 0;
            while (true) {
                const group = &groups[group_idx];
                const empties = matchEmpty(group);
                if (empties != 0) {
                    const lane = firstLane(empties);
                    group.fingerprints[lane] = fp;
                    group.index[lane] = value_idx;
                    return;
                }
                if (group.overflows[counter] != 255) group.overflows[counter] += 1;
                group_idx = nextGroup(group_idx, &delta, mask);
            }
        }

        /// `uncount`: the same walk from home that placed the entry, up to
        /// the group it landed in.
        inline fn uncount(groups: [*]Block, mask: u32, home_idx: u32, counter: u32, found_in: u32) void {
            var group_idx = home_idx;
            var delta: u32 = 0;
            while (group_idx != found_in) {
                if (groups[group_idx].overflows[counter] != 255) groups[group_idx].overflows[counter] -= 1;
                group_idx = nextGroup(group_idx, &delta, mask);
            }
        }

        /// `erase_group_slot`.
        inline fn eraseGroupSlot(self: *Self, found_in: u32, lane: u8, mh: u64) void {
            const groups = self.blocks;
            const mask = self.group_mask;
            const home_idx = self.groupIdxFromHash(mh);
            const counter: u32 = fingerprint(mh) & 7;
            groups[found_in].fingerprints[lane] = 0;
            uncount(groups, mask, home_idx, counter, found_in);
        }

        /// `move_home`: a writing hit found past its home group moves home if
        /// there is room there now.
        fn moveHome(self: *Self, found_in: u32, from_lane: u8, mh: u64) void {
            const home_idx = self.groupIdxFromHash(mh);
            if (found_in == home_idx) return;
            const groups = self.blocks;
            const home = &groups[home_idx];
            const empties = matchEmpty(home);
            if (empties == 0) return;
            const lane = firstLane(empties);
            const mask = self.group_mask;
            const counter: u32 = fingerprint(mh) & 7;
            const from = &groups[found_in];
            home.fingerprints[lane] = from.fingerprints[from_lane];
            home.index[lane] = from.index[from_lane];
            from.fingerprints[from_lane] = 0;
            uncount(groups, mask, home_idx, counter, found_in);
        }

        /// `repoint_value`: overwrite the slot that points at `value_idx`.
        fn repointValue(self: *Self, mh: u64, value_idx: u32, new_value_idx: u32) void {
            const fp = fingerprint(mh);
            var group_idx = self.groupIdxFromHash(mh);
            const groups = self.blocks;
            var delta: u32 = 0;
            while (true) {
                const group = &groups[group_idx];
                var lanes = matchFingerprint(group, fp);
                while (lanes != 0) : (lanes &= lanes - 1) {
                    const lane = firstLane(lanes);
                    if (group.index[lane] == value_idx) {
                        group.index[lane] = new_value_idx;
                        return;
                    }
                }
                if (delta == self.group_mask) @panic("dense: a key changed while in the map");
                group_idx = nextGroup(group_idx, &delta, self.group_mask);
            }
        }

        // the index's array /////////////////////////////////////////////////

        fn calcNumGroups(shifts: u8) usize {
            return @min(max_bucket_count / slots_per_group, @as(usize, 1) << @intCast(64 - @as(u32, shifts)));
        }

        fn deallocateBuckets(self: *Self, gpa: Allocator) void {
            if (self.num_groups != 0) {
                const aligned: [*]align(16) Block = @alignCast(self.blocks);
                gpa.free(aligned[0..self.num_groups]);
            }
            self.blocks = @constCast(&sentinel_blocks);
            self.num_groups = 0;
            self.max_bucket_capacity = 0;
            self.group_mask = 0;
        }

        /// `allocate_buckets_from_shift`: a zeroed array beside the old one,
        /// which is given back once the new one exists.
        fn allocateBucketsFromShift(self: *Self, gpa: Allocator, shifts: u8) Allocator.Error!void {
            const num_groups = calcNumGroups(shifts);
            const fresh = try gpa.alignedAlloc(Block, block_align, num_groups);
            @memset(std.mem.sliceAsBytes(fresh), 0);
            if (self.num_groups != 0) {
                const aligned: [*]align(16) Block = @alignCast(self.blocks);
                gpa.free(aligned[0..self.num_groups]);
            }
            self.blocks = fresh.ptr;
            self.num_groups = num_groups;
            self.shifts = shifts;
            // describe_buckets
            self.group_mask = @intCast(num_groups - 1);
            const num_buckets = num_groups * slots_per_group;
            self.max_bucket_capacity = if (num_buckets == max_bucket_count)
                max_bucket_count
            else
                @intFromFloat(@as(f32, @floatFromInt(num_buckets)) * max_load_factor);
        }

        inline fn allocateBucketsIfNone(self: *Self, gpa: Allocator) Allocator.Error!void {
            if (self.num_groups == 0) try self.allocateBucketsFromShift(gpa, self.shifts);
        }

        /// `fill_buckets_from_values`: into an index just allocated, so
        /// already empty; hashes sixteen entries ahead of the one it places
        /// and prefetches the block each will land in.
        noinline fn fillBucketsFromValues(self: *Self) void {
            const ahead = pipeline_depth;
            const groups = self.blocks;
            const mask = self.group_mask;
            const shifts: u6 = @intCast(self.shifts);
            const entries = self.entries;
            const n = self.len;
            var ring: [ahead]u64 = undefined;
            var it: usize = 0;
            while (it < ahead and it < n) : (it += 1) {
                const mh = mixedHash(entries[it].key);
                ring[it] = mh;
                prefetchBlock(&groups[@intCast(mh >> shifts)]);
            }
            var value_idx: usize = 0;
            while (value_idx < n) : (value_idx += 1) {
                const mh = ring[value_idx % ahead];
                if (it != n) {
                    const nh = mixedHash(entries[it].key);
                    it += 1;
                    ring[value_idx % ahead] = nh;
                    prefetchBlock(&groups[@intCast(nh >> shifts)]);
                }
                const fp = fingerprint(mh);
                const counter: u32 = fp & 7;
                var group_idx: u32 = @intCast(mh >> shifts);
                var delta: u32 = 0;
                while (true) {
                    const group = &groups[group_idx];
                    const empties = matchEmpty(group);
                    if (empties != 0) {
                        const lane = firstLane(empties);
                        group.fingerprints[lane] = fp;
                        group.index[lane] = @intCast(value_idx);
                        break;
                    }
                    if (group.overflows[counter] != 255) group.overflows[counter] += 1;
                    group_idx = nextGroup(group_idx, &delta, mask);
                }
            }
        }

        /// `increase_size`: the new entry is already appended; on failure
        /// it is taken back out.
        noinline fn increaseSize(self: *Self, gpa: Allocator) Allocator.Error!void {
            if (self.max_bucket_capacity == max_bucket_count) {
                self.len -= 1;
                return error.OutOfMemory;
            }
            self.allocateBucketsFromShift(gpa, self.shifts - 1) catch |e| {
                self.len -= 1;
                return e;
            };
            self.fillBucketsFromValues();
        }

        // the values ////////////////////////////////////////////////////////

        /// `std::vector::emplace_back`: a new array of twice the capacity
        /// (at least one), the old entries moved over, the old one freed.
        inline fn appendValue(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            if (self.len == self.cap) try self.increaseCapacity(gpa);
            self.entries[self.len] = .{ .key = k, .value = v };
            self.len += 1;
        }

        noinline fn increaseCapacity(self: *Self, gpa: Allocator) Allocator.Error!void {
            const new_cap = @max(2 * self.cap, self.len + 1);
            const fresh = try gpa.alloc(KV, new_cap);
            @memcpy(fresh[0..self.len], self.entries[0..self.len]);
            if (self.cap != 0) gpa.free(self.entries[0..self.cap]);
            self.entries = fresh.ptr;
            self.cap = new_cap;
        }

        // insert ////////////////////////////////////////////////////////////

        /// `insert_or_assign`, through `do_find_or_place`: the home group
        /// inline, everything after a miss there behind a call.
        pub inline fn put(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            const mh = mixedHash(k);
            const fp = fingerprint(mh);
            const home_idx = self.groupIdxFromHash(mh);
            const groups = self.blocks;
            prefetchIndex(groups, home_idx);
            const home = &groups[home_idx];
            var lanes = matchFingerprint(home, fp);
            while (lanes != 0) : (lanes &= lanes - 1) {
                const value_idx = home.index[firstLane(lanes)];
                if (eql(k, self.entries[value_idx].key)) {
                    self.entries[value_idx].value = v;
                    return;
                }
            }
            return self.findOrPlaceMiss(gpa, mh, fp, home_idx, k, v);
        }

        /// `find_or_place_miss`.
        noinline fn findOrPlaceMiss(self: *Self, gpa: Allocator, mh: u64, fp: u8, home_idx: u32, k: K, v: V) Allocator.Error!void {
            try self.allocateBucketsIfNone(gpa);
            const counter: u32 = fp & 7;
            if (self.blocks[home_idx].overflows[counter] == 0) {
                return self.placeNew(gpa, fp, counter, home_idx, k, v);
            }
            return self.findOrPlaceFar(gpa, mh, fp, home_idx, k, v);
        }

        /// `find_or_place_far`: walk on past home, and place the key if it
        /// is not there.
        noinline fn findOrPlaceFar(self: *Self, gpa: Allocator, mh: u64, fp: u8, home_idx: u32, k: K, v: V) Allocator.Error!void {
            const counter: u32 = fp & 7;
            const r = self.probeAfterHome(k, fp, counter, &self.blocks[home_idx], home_idx);
            if (r.found) {
                self.moveHome(r.group_idx, r.lane, mh);
                self.entries[r.value_idx].value = v;
                return;
            }
            return self.placeNew(gpa, fp, counter, home_idx, k, v);
        }

        /// `place_element_at`.
        inline fn placeNew(self: *Self, gpa: Allocator, fp: u8, counter: u32, home_idx: u32, k: K, v: V) Allocator.Error!void {
            try self.appendValue(gpa, k, v);
            const value_idx: u32 = @intCast(self.len - 1);
            if (self.len > self.max_bucket_capacity) {
                try self.increaseSize(gpa); // places every value, the new one included
            } else {
                self.placeGroup(fp, counter, home_idx, value_idx);
            }
        }

        // lookup ////////////////////////////////////////////////////////////

        pub fn get(self: *const Self, k: K) ?V {
            const r = self.probe(k, mixedHash(k));
            return if (r.found) self.entries[r.value_idx].value else null;
        }

        pub fn getPtr(self: *const Self, k: K) ?*V {
            const r = self.probe(k, mixedHash(k));
            return if (r.found) &self.entries[r.value_idx].value else null;
        }

        pub fn contains(self: *const Self, k: K) bool {
            return self.probe(k, mixedHash(k)).found;
        }

        // erase /////////////////////////////////////////////////////////////

        /// `extract(key)`: `do_erase_key`, `do_erase`, `finish_erase`. The
        /// last entry moves into the hole and its slot is repointed.
        pub fn fetchRemove(self: *Self, k: K) ?KV {
            const mh = mixedHash(k);
            const r = self.probe(k, mh);
            if (!r.found) return null;
            const value_idx = r.value_idx;
            const last = self.len - 1;
            @prefetch(&self.entries[value_idx], .{});
            @prefetch(&self.entries[last], .{});
            self.eraseGroupSlot(r.group_idx, r.lane, mh);
            const erased = self.entries[value_idx];
            if (value_idx != last) {
                self.entries[value_idx] = self.entries[last];
                const moved = mixedHash(self.entries[value_idx].key);
                self.repointValue(moved, @intCast(last), value_idx);
            }
            self.len = last;
            return erased;
        }

        // iteration /////////////////////////////////////////////////////////

        /// Walks the dense array in order.
        pub const Iterator = struct {
            entries: [*]KV,
            len: usize,
            i: usize = 0,

            pub fn next(it: *Iterator) ?Entry {
                if (it.i == it.len) return null;
                const e = &it.entries[it.i];
                it.i += 1;
                return .{ .key_ptr = &e.key, .value_ptr = &e.value };
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .entries = self.entries, .len = self.len };
        }

        pub const KeyIterator = struct {
            entries: [*]KV,
            len: usize,
            i: usize = 0,

            pub fn next(it: *KeyIterator) ?*K {
                if (it.i == it.len) return null;
                it.i += 1;
                return &it.entries[it.i - 1].key;
            }
        };

        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{ .entries = self.entries, .len = self.len };
        }

        pub const ValueIterator = struct {
            entries: [*]KV,
            len: usize,
            i: usize = 0,

            pub fn next(it: *ValueIterator) ?*V {
                if (it.i == it.len) return null;
                it.i += 1;
                return &it.entries[it.i - 1].value;
            }
        };

        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .entries = self.entries, .len = self.len };
        }

        // checking //////////////////////////////////////////////////////////

        /// The index's invariants, for tests: every entry is pointed at by
        /// exactly one full slot, on its probe sequence, and every counter is
        /// the number of entries of its class that walked past the group.
        pub fn verify(self: *const Self, gpa: Allocator) !void {
            if (self.num_groups == 0) {
                if (self.len != 0) return error.Corrupt;
                return;
            }
            const groups = self.blocks[0..self.num_groups];
            var full: usize = 0;
            for (groups) |*g| for (g.fingerprints) |f| {
                if (f != 0) full += 1;
            };
            if (full != self.len) return error.Corrupt;
            const counts = try gpa.alloc([8]u32, self.num_groups);
            defer gpa.free(counts);
            @memset(counts, @splat(0));
            for (self.entries[0..self.len], 0..) |e, vi| {
                const mh = mixedHash(e.key);
                const fp = fingerprint(mh);
                var group_idx = self.groupIdxFromHash(mh);
                var delta: u32 = 0;
                while (true) {
                    const g = &groups[group_idx];
                    var hit = false;
                    for (0..16) |lane| {
                        if (g.fingerprints[lane] == fp and g.index[lane] == vi) hit = true;
                    }
                    if (hit) break;
                    counts[group_idx][fp & 7] += 1;
                    if (delta == self.group_mask) return error.Corrupt;
                    group_idx = nextGroup(group_idx, &delta, self.group_mask);
                }
            }
            for (groups, counts) |*g, c| for (0..8) |i| {
                const want: u32 = @min(c[i], 255);
                if (g.overflows[i] != want and g.overflows[i] != 255) return error.Corrupt;
            };
        }
    };
}

// tests //////////////////////////////////////////////////////////////////////

const testing = std.testing;

/// Rig's hash of an Int, as bench/hash's `dense-mix` and `zig-dense` use.
const IntCtx = struct {
    pub fn hash(_: IntCtx, x: i64) u64 {
        const p = @as(u128, @as(u64, @bitCast(x)) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
        return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
    }
    pub fn eql(_: IntCtx, a: i64, b: i64) bool {
        return a == b;
    }
};

/// A hash that crowds keys into a few groups and fingerprint classes, so
/// overflow counters, walks past home and move_home all run.
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

fn randomAgainstStd(comptime Ctx: type, ops: usize, key_range: u64, verify_every: usize) !void {
    const gpa = testing.allocator;
    var m: HashMap(i64, i64, Ctx) = .empty;
    defer m.deinit(gpa);
    var ref: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    defer ref.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    for (0..ops) |i| {
        const k: i64 = @intCast(rnd.uintLessThan(u64, key_range));
        switch (rnd.uintLessThan(u8, 10)) {
            0...3 => {
                const v: i64 = @intCast(i);
                try m.put(gpa, k, v);
                try ref.put(gpa, k, v);
            },
            4...5 => {
                const a = m.fetchRemove(k);
                const b = ref.fetchRemove(k);
                try testing.expectEqual(b == null, a == null);
                if (a) |kv| {
                    try testing.expectEqual(b.?.key, kv.key);
                    try testing.expectEqual(b.?.value, kv.value);
                }
            },
            6...7 => try testing.expectEqual(ref.get(k), m.get(k)),
            else => try testing.expectEqual(ref.contains(k), m.contains(k)),
        }
        try testing.expectEqual(ref.count(), m.count());
        if (verify_every != 0 and i % verify_every == 0) try m.verify(gpa);
    }
    try m.verify(gpa);
    var it = ref.iterator();
    while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, m.get(e.key_ptr.*).?);
}

test "random insert, remove and lookup against std, 1M operations" {
    try randomAgainstStd(IntCtx, 1_000_000, 50_000, 100_000);
}

test "random operations with a crowding hash" {
    try randomAgainstStd(CrowdCtx, 200_000, 3_000, 997);
}

test "churn at a fixed size" {
    const gpa = testing.allocator;
    var m: HashMap(i64, i64, IntCtx) = .empty;
    defer m.deinit(gpa);
    const size = 100_000;
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, i, i);
    const groups = m.num_groups;
    var next: i64 = size;
    var oldest: i64 = 0;
    for (0..20 * size) |_| {
        const kv = m.fetchRemove(oldest).?;
        try testing.expectEqual(oldest, kv.value);
        oldest += 1;
        try m.put(gpa, next, next);
        next += 1;
        try testing.expectEqual(@as(usize, size), m.count());
    }
    try testing.expectEqual(groups, m.num_groups); // no growth from churn
    try m.verify(gpa);
    var k = oldest;
    while (k < next) : (k += 1) try testing.expectEqual(k, m.get(k).?);
    try testing.expect(!m.contains(oldest - 1));
}

test "churn with move_home under a crowding hash" {
    const gpa = testing.allocator;
    var m: HashMap(i64, i64, CrowdCtx) = .empty;
    defer m.deinit(gpa);
    const size = 2_000;
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, i, i);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var next: i64 = size;
    for (0..50_000) |step| {
        // a writing hit on a random live key, then one out, one in
        const e = m.entries[rnd.uintLessThan(usize, m.len)];
        try m.put(gpa, e.key, e.value);
        const victim = m.entries[rnd.uintLessThan(usize, m.len)].key;
        _ = m.fetchRemove(victim).?;
        try m.put(gpa, next, next);
        next += 1;
        if (step % 1000 == 0) try m.verify(gpa);
    }
    try m.verify(gpa);
    for (m.entries[0..m.len]) |e| try testing.expectEqual(e.key, m.get(e.key).?);
}

test "growth" {
    const gpa = testing.allocator;
    var m: HashMap(i64, [8]i64, IntCtx) = .empty;
    defer m.deinit(gpa);
    try testing.expect(m.get(5) == null); // the sentinel
    try testing.expect(m.fetchRemove(5) == null);
    var last_groups: usize = 0;
    var i: i64 = 0;
    while (i < 300_000) : (i += 1) {
        try m.put(gpa, i *% -7046029254386353131, @splat(i));
        if (m.num_groups != last_groups) {
            last_groups = m.num_groups;
            try testing.expect(m.count() <= m.max_bucket_capacity);
            try m.verify(gpa);
            var j: i64 = 0;
            while (j <= i) : (j += 1) try testing.expectEqual(j, m.getPtr(j *% -7046029254386353131).?[3]);
        }
    }
    try testing.expectEqual(@as(usize, 300_000), m.count());
    // 4 groups of 16 at first, doubling at 0.8 full
    try testing.expectEqual(@as(usize, 32768), m.num_groups);
    try m.put(gpa, 0, @splat(-1)); // overwrite
    try testing.expectEqual(@as(usize, 300_000), m.count());
    try testing.expectEqual(@as(i64, -1), m.get(0).?[0]);
}

test "string keys" {
    const gpa = testing.allocator;
    var m: HashMap([]const u8, i64, TextCtx) = .empty;
    defer m.deinit(gpa);
    var ref: std.StringHashMapUnmanaged(i64) = .empty;
    defer ref.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    for (0..200_000) |i| {
        const n = rnd.uintLessThan(u32, 20_000);
        const key = try std.fmt.allocPrint(arena, "key{d}", .{n});
        switch (rnd.uintLessThan(u8, 4)) {
            0, 1 => {
                try m.put(gpa, key, @intCast(i));
                const gop = try ref.getOrPut(gpa, key);
                gop.value_ptr.* = @intCast(i);
            },
            2 => try testing.expectEqual(ref.fetchRemove(key) == null, m.fetchRemove(key) == null),
            else => try testing.expectEqual(ref.get(key), m.get(key)),
        }
    }
    try testing.expectEqual(ref.count(), m.count());
    try m.verify(gpa);
    var it = ref.iterator();
    while (it.next()) |e| {
        const copy = try arena.dupe(u8, e.key_ptr.*); // found by an equal text made apart
        try testing.expectEqual(e.value_ptr.*, m.get(copy).?);
    }
}

test "iteration covers exactly the live entries" {
    const gpa = testing.allocator;
    var m: HashMap(i64, i64, IntCtx) = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 10_000) : (i += 1) try m.put(gpa, i, i * 2);
    // in insertion order before any erase
    var it = m.iterator();
    var want: i64 = 0;
    while (it.next()) |e| : (want += 1) {
        try testing.expectEqual(want, e.key_ptr.*);
        try testing.expectEqual(want * 2, e.value_ptr.*);
    }
    try testing.expectEqual(@as(i64, 10_000), want);
    i = 0;
    while (i < 10_000) : (i += 3) _ = m.fetchRemove(i).?;
    var seen = try std.DynamicBitSet.initEmpty(gpa, 10_000);
    defer seen.deinit();
    var n: usize = 0;
    it = m.iterator();
    while (it.next()) |e| {
        const k: usize = @intCast(e.key_ptr.*);
        try testing.expect(k % 3 != 0);
        try testing.expect(!seen.isSet(k));
        try testing.expectEqual(e.key_ptr.* * 2, e.value_ptr.*);
        seen.set(k);
        n += 1;
    }
    try testing.expectEqual(m.count(), n);
    try testing.expectEqual(@as(usize, 10_000 - 3334), n);
    var ki = m.keyIterator();
    var vi = m.valueIterator();
    var sum_k: i64 = 0;
    var sum_v: i64 = 0;
    while (ki.next()) |k| sum_k += k.*;
    while (vi.next()) |v| sum_v += v.*;
    try testing.expectEqual(sum_k * 2, sum_v);
}
