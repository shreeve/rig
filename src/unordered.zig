//! The unordered hash table behind `HashMap` and `HashSet`
//! (std/prelude.rig): the compiler built-ins `UnorderedMap[K, V]` and
//! `UnorderedSet[K]`, held here as `UnorderedMap(K, V)` and
//! `UnorderedSet(K)`, written beside the runtime. It is bench/hash's
//! `zig-hash` (bench/hash/hash.zig, with its defaults;
//! docs/history/records/2026-10/hash-race/zig-hash.md for each choice and
//! its measurement), with Rig's `==` and its drops.
//!
//! boost's FOA layout: slots in groups, a power-of-two count of them, and
//! beside them a metadata word a group, a tag a slot (0 free, 1 the
//! sentinel in the last slot of the last group, 2 to 255 full) and an
//! overflow byte. An insert that passes a full group sets bit `tag % 8`
//! of its overflow byte; a lookup stops at the first group whose bit for
//! its tag is clear. A take writes 0 to its tag, and where its group's
//! bit for the tag is set lowers the maximum load by one, so no
//! tombstone piles up: a rehash forced by that drift sizes the table to
//! at most 0.6 full (0.5 for groups of 7). Groups are 15 slots and 16
//! bytes on x86-64 (`pcmpeqb`, `pmovmskb`), 7 and 8 on arm64 (`cmeq.8b`,
//! `fmov`, a byte a lane), whose maximum load is 0.8 and whose tables
//! have 4 groups at least.
//!
//! The hash is rotated left a byte: its top byte is the tag and the bits
//! below it the home group. An integer key of up to 64 bits hashes by one
//! multiply, a text key by folded multiplies up to 32 bytes (Wyhash
//! above) and compares by words; every other key by `rig.hash` and
//! `rig.eql`, as `.hash()` and `==` do. A key over 8 bytes keeps its
//! hash in its slot, so growth never hashes a key again.
//!
//! The order of the slots is the order a walk gives, which depends on
//! the hashes, the target's group width, and the table's history: Rig
//! leaves it unspecified.
//!
//! Every method here is called only from std/prelude.rig's `HashMap` and
//! `HashSet`, whose declarations the checkers read; a slot index it is
//! given is one this table gave and is full.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime.zig");

const Arch = enum { sse2, neon, generic };
const arch: Arch = switch (builtin.cpu.arch) {
    .x86_64 => .sse2,
    .aarch64 => .neon,
    else => .generic,
};

/// Groups of 7 slots and an 8-byte metadata word on arm64.
const group8 = arch == .neon;
/// Lanes a group, the last the overflow byte.
const W: usize = if (group8) 8 else 16;
/// Slots a group.
const NL: usize = W - 1;
/// The maximum load, `load_num / load_den` of the slots: 0.8 for groups
/// of 7, whose small groups overflow more often near full; boost's 0.875
/// for groups of 15.
const load_num: usize = if (group8) 4 else 7;
const load_den: usize = if (group8) 5 else 8;
/// The fill a rehash forced by drift sizes the table to,
/// `drift_num / drift_den`: 0.5 for groups of 7 (at 0.6, a turnover of
/// 1,000 keys rehashed at its own size), 0.6 for groups of 15.
const drift_num: usize = if (group8) 1 else 3;
const drift_den: usize = if (group8) 2 else 5;
/// The fewest groups a table allocates: 4 for groups of 7, so a table of
/// 16 keys grows once.
const min_groups: usize = if (group8) 4 else 2;
/// The most entries a table holds, as a Map's.
const max_entries: usize = std.math.maxInt(u32);

const Group = extern struct {
    m: [W]u8 align(W),
};
const VW = @Vector(W, u8);

const sentinel = 1;

/// Two groups as an empty table's: the sentinel set, nothing else. An
/// empty table points here, so a lookup needs no test of its own; its
/// maximum load is 0, so no insert writes it.
const Dummy = struct {
    var groups: [2]Group = blk: {
        var g: Group = .{ .m = @splat(0) };
        g.m[W - 2] = sentinel;
        break :blk .{ g, g };
    };
};

/// The overflow class bits, by a table (`classClear`).
const shift_table = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

/// The tag of a byte of the hash, broadcast to four bytes: 0 and 1
/// (free, sentinel) become 8 and 9, which keeps the byte's class mod 8.
/// A table, so the tag reaches a vector register by a broadcasting load
/// (`vpbroadcastd`, `ld1r`), not by a move and a shuffle, which on x86
/// costs a hit in cache about a third.
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

/// The tag of hash byte `b` in every lane of a group.
inline fn tagVector(b: u8) VW {
    return switch (arch) {
        .sse2 => @bitCast(@as(@Vector(W / 4, u32), @splat(match_word[b]))),
        else => @splat(reduced_table[b]),
    };
}

/// A group's lanes as a mask: on arm64 a byte a lane, bit 0 of each
/// (`cmeq.8b`, `fmov`), so a lane is `ctz >> 3`; elsewhere a bit a lane
/// (`pmovmskb`).
const step: u5 = if (group8) 8 else 1;
const Mask = if (group8) u64 else u32;
/// The slot lanes, all but the overflow byte.
const slot_lanes: Mask = blk: {
    var x: Mask = 0;
    for (0..NL) |i| x |= @as(Mask, 1) << @intCast(i * step);
    break :blk x;
};

inline fn laneBit(i: usize) Mask {
    return @as(Mask, 1) << @intCast(i * step);
}

inline fn laneOf(m: Mask) usize {
    return @as(usize, @ctz(m)) >> @intCast(@ctz(@as(u32, step)));
}

/// The lanes where `eq` holds, before `& slot_lanes`.
inline fn reduceEq(eq: @Vector(W, bool)) Mask {
    if (group8) {
        const bytes: @Vector(8, u8) = @select(u8, eq, @as(@Vector(8, u8), @splat(0xFF)), @as(@Vector(8, u8), @splat(0)));
        return @bitCast(bytes);
    }
    return @as(u16, @bitCast(eq));
}

inline fn load(pg: *const Group) VW {
    return pg.m;
}

inline fn matchTag(v: VW, tag: VW) Mask {
    return reduceEq(v == tag) & slot_lanes;
}

inline fn matchFree(v: VW) Mask {
    return reduceEq(v == @as(VW, @splat(0))) & slot_lanes;
}

/// The full lanes: a tag above the sentinel's.
inline fn matchFull(pg: *const Group) Mask {
    return reduceEq(load(pg) > @as(VW, @splat(sentinel))) & slot_lanes;
}

/// Whether group `pg`'s overflow bit for `class` is clear. The read is
/// volatile, so the compiler cannot take the byte from the loaded group
/// ahead of the tag match, where a hit would pay for it.
inline fn classClear(pg: *const Group, class: u3) bool {
    const o: *const volatile u8 = &pg.m[W - 1];
    return o.* & shift_table[class] == 0;
}

inline fn isNotOverflowed(pg: *const Group, tag: u8) bool {
    return pg.m[W - 1] & (@as(u8, 1) << @as(u3, @truncate(tag))) == 0;
}

inline fn markOverflow(pg: *Group, tag: u8) void {
    pg.m[W - 1] |= @as(u8, 1) << @as(u3, @truncate(tag));
}

// hashing ////////////////////////////////////////////////////////////////////

/// One multiply, the 128-bit product's halves folded.
inline fn fold(a: u64, b: u64) u64 {
    const p = @as(u128, a) * b;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}

inline fn read64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}

inline fn read32(p: [*]const u8) u64 {
    return std.mem.readInt(u32, p[0..4], .little);
}

/// The table's text hash: up to 16 bytes one folded multiply of two
/// overlapping reads, up to 32 two in parallel, Wyhash above.
inline fn textHash(s: []const u8) u64 {
    const k0: u64 = 0x243f6a8885a308d3;
    const k1: u64 = 0x13198a2e03707344;
    const k2: u64 = 0xa4093822299f31d0;
    const k3: u64 = 0x082efa98ec4e6c89;
    const n = s.len;
    const p = s.ptr;
    if (n <= 16) {
        var a: u64 = 0;
        var b: u64 = 0;
        if (n >= 8) {
            a = read64(p);
            b = read64(p + n - 8);
        } else if (n >= 4) {
            a = read32(p);
            b = read32(p + n - 4);
        } else if (n > 0) {
            a = p[0];
            b = (@as(u64, p[n - 1]) << 8) | p[n / 2];
        }
        return fold(a ^ k0, b ^ k1 ^ n);
    }
    if (n <= 32) {
        const a = read64(p);
        const b = read64(p + 8);
        const c = read64(p + n - 16);
        const d = read64(p + n - 8);
        return fold(a ^ k0, c ^ k1) ^ fold(b ^ k2, d ^ k3 ^ n);
    }
    return std.hash.Wyhash.hash(0, s);
}

/// Text equality by words up to 32 bytes.
inline fn textEql(a: []const u8, b: []const u8) bool {
    const n = a.len;
    if (n != b.len) return false;
    const p = a.ptr;
    const q = b.ptr;
    if (n >= 8 and n <= 16)
        return (read64(p) ^ read64(q)) | (read64(p + n - 8) ^ read64(q + n - 8)) == 0;
    if (n > 16 and n <= 32)
        return (read64(p) ^ read64(q)) | (read64(p + 8) ^ read64(q + 8)) |
            (read64(p + n - 16) ^ read64(q + n - 16)) | (read64(p + n - 8) ^ read64(q + n - 8)) == 0;
    return std.mem.eql(u8, a, b);
}

/// The multiplier of the table's integer hash: odd, and not the golden
/// ratio's 0x9e3779b97f4a7c15, a common stride, whose square spreads
/// keys of that stride into a few groups.
const int_mul: u64 = 0x4b33a62ed433d4a3;

/// `HashMap[K, V]`'s table.
pub fn UnorderedMap(comptime K: type, comptime V: type) type {
    return Unordered(K, V);
}

/// `HashSet[K]`'s table: a HashMap's with no value.
pub fn UnorderedSet(comptime K: type) type {
    return Unordered(K, void);
}

fn Unordered(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const is_set = V == void;
        /// A view of a key, as a lookup takes it (`?K`).
        const KeyView = rt.ReadView(K);
        const int_key = @typeInfo(K) == .int and @bitSizeOf(K) <= 64;
        const text_key = K == rt.String or K == []const u8;
        /// A key over 8 bytes keeps its hash in its slot.
        const store_hash = @sizeOf(K) > 8;

        const Element = if (store_hash)
            struct { key: K, value: V, hash: u64 }
        else
            struct { key: K, value: V };

        /// No prefetch for slots over 40 bytes, a `String` key's with its
        /// value and hash; for smaller ones, the home group's first slot
        /// line, inside the branch a tag match takes.
        const prefetch_slots = @sizeOf(Element) <= 40;

        /// The groups; an empty table's are `Dummy`'s, so never null, and
        /// `HashMap?` holds its `none` here (`rt.nicheOf`).
        groups: [*]Group = &Dummy.groups,
        /// The slots, then the groups, in one block; null while empty.
        elements: ?[*]Element = null,
        /// The groups less one: their count is a power of two.
        mask: usize = 1,
        /// The live entries the table takes before it grows: its maximum
        /// load, less one for each take from a group a probe may walk
        /// past.
        ml: usize = 0,
        /// The live entries.
        size: usize = 0,
        /// 64 less the log of the groups: the rotated hash's shift right
        /// that leaves its home group.
        shift: u8 = 63,

        pub const empty: Self = .{};
        /// Its arguments, for `rt.typeName`.
        pub const __rig_args = if (is_set) .{K} else .{ K, V };
        /// `rt.cloneValue` clones it by `clone`.
        pub const __rig_unordered = {};

        // hashing, homes ////////////////////////////////////////////////////

        inline fn hashKey(k: KeyView) u64 {
            if (int_key) return @as(u64, @as(@Int(.unsigned, @bitSizeOf(K)), @bitCast(k))) *% int_mul;
            if (text_key) return textHash(rt.stringBytes(k));
            return rt.hash(k);
        }

        inline fn hashOf(e: *const Element) u64 {
            return if (store_hash) e.hash else hashKey(rt.lend(&e.key));
        }

        inline fn keyMatches(e: *const Element, k: KeyView) bool {
            if (int_key and @sizeOf(Element) <= 16) {
                // The whole slot in one load (`ldp`), so a hit reads its
                // value from the same load.
                const s = e.*;
                return s.key == k;
            }
            if (text_key) return textEql(rt.stringBytes(e.key), rt.stringBytes(k));
            return switch (@typeInfo(K)) {
                .int, .bool, .@"enum" => e.key == k,
                else => rt.eql(e.key, k),
            };
        }

        inline fn makeElement(k: K, v: V, h: u64) Element {
            return if (store_hash) .{ .key = k, .value = v, .hash = h } else .{ .key = k, .value = v };
        }

        /// The home group, the tag and its broadcast, and the tag's class.
        const Home = struct { pos: usize, tag: u8, vtag: VW, class: u3 };

        inline fn homeOf(hash: u64, shift: u8) Home {
            const t = std.math.rotl(u64, hash, 8);
            return .{
                .pos = @intCast(t >> @intCast(shift)),
                .tag = reduced_table[@as(u8, @truncate(t))],
                .vtag = tagVector(@truncate(t)),
                // From the hash byte, which has the tag's class mod 8, so
                // not waiting on the table.
                .class = @truncate(t),
            };
        }

        /// The quadratic probe over groups.
        const Prober = struct {
            pos: usize,
            step: usize = 0,

            inline fn next(pb: *Prober, mask: usize) bool {
                pb.step += 1;
                pb.pos = (pb.pos + pb.step) & mask;
                return pb.step <= mask;
            }
        };

        // sizes /////////////////////////////////////////////////////////////

        inline fn slotsFor(groups: usize) usize {
            return groups * NL - 1;
        }

        /// The slots, 0 while empty.
        inline fn slotCount(self: *const Self) usize {
            return if (self.elements != null) slotsFor(self.mask + 1) else 0;
        }

        fn groupsFor(n: usize) usize {
            return std.math.ceilPowerOfTwoAssert(usize, @max(n / NL + 1, min_groups));
        }

        fn initialMaxLoad(self: *const Self) usize {
            const c = self.slotCount();
            if (c <= 2 * NL - 1) return c;
            return c * load_num / load_den;
        }

        /// The block's elements: the slots, and room after them for the
        /// groups at the next boundary of a group, a whole number of
        /// elements.
        fn blockLen(groups: usize) usize {
            const bytes = @sizeOf(Element) * slotsFor(groups) + @sizeOf(Group) * (groups + 1) - 1;
            return (bytes + @sizeOf(Element) - 1) / @sizeOf(Element);
        }

        const Arrays = struct {
            groups: [*]Group,
            elements: [*]Element,
            mask: usize,
            shift: u8,
        };

        /// New arrays for `n` slots or more, every group free and the
        /// sentinel set.
        fn newArrays(n: usize) Arrays {
            const groups = groupsFor(n);
            const block = rt.allocSlice(Element, blockLen(groups));
            var p: usize = @intFromPtr(block.ptr + slotsFor(groups));
            p += (@sizeOf(Group) -% p) % @sizeOf(Group);
            const gs: [*]Group = @ptrFromInt(p);
            @memset(@as([*]u8, @ptrCast(gs))[0 .. groups * @sizeOf(Group)], 0);
            gs[groups - 1].m[NL - 1] = sentinel;
            return .{
                .groups = gs,
                .elements = block.ptr,
                .mask = groups - 1,
                .shift = @intCast(@as(u32, 64) - std.math.log2_int(usize, groups)),
            };
        }

        fn freeArrays(elements: ?[*]Element, mask: usize) void {
            const e = elements orelse return;
            rt.freeSlice(Element, e[0..blockLen(mask + 1)]);
        }

        noinline fn tooMany() noreturn {
            @branchHint(.cold);
            @panic(if (is_set) "a HashSet holds at most 4294967295 keys" else "a HashMap holds at most 4294967295 entries");
        }

        // slots /////////////////////////////////////////////////////////////

        /// Slot `i`, which the table or a caller names. The table names
        /// only slots below its count, and the prelude only those the
        /// table gave it, so release builds test nothing; a debug build,
        /// which `rig run` and the suite make, tests that `i` is a slot
        /// and, where `full`, that it holds an entry, so a bug in the
        /// table panics there rather than reading past the slots (the
        /// panel's decision 10).
        inline fn slotAt(self: *const Self, i: usize, comptime full: bool) *Element {
            if (builtin.mode == .debug) {
                if (i >= self.slotCount()) @panic("unordered: a slot index past the slots");
                if (full and self.groups[i / NL].m[i % NL] <= sentinel) @panic("unordered: a slot index names a free slot");
            }
            return &self.elements.?[i];
        }

        /// The slot of group `pos` at `m`'s first lane. On arm64 a 16-byte
        /// slot's offset is `ctz << 1`, one shift folded into the address.
        inline fn slotOf(elements: [*]Element, pos: usize, m: Mask) *Element {
            if (group8 and @sizeOf(Element) == 16) {
                const base: [*]u8 = @ptrCast(elements + pos * NL);
                return @ptrCast(@alignCast(base + (@as(usize, @ctz(m)) << 1)));
            }
            return &elements[pos * NL + laneOf(m)];
        }

        /// The index of slot `p`: an exact division, so a caller that
        /// makes the slot's address again from the index gets `p` back
        /// with no arithmetic.
        inline fn indexOf(es: [*]Element, p: *const Element) usize {
            return @divExact(@intFromPtr(p) - @intFromPtr(es), @sizeOf(Element));
        }

        // finding ///////////////////////////////////////////////////////////

        const Found = struct { pg: *Group, lane: usize, i: usize, p: *Element };

        /// The slot of `k`, whose hash is `hash`. The home group is peeled
        /// from the probe: a hit in its first matching lane takes no loop,
        /// and the overflow byte is read only on the way to a miss.
        inline fn locate(self: *const Self, k: KeyView, hash: u64) ?Found {
            const h = homeOf(hash, self.shift);
            const pg = &self.groups[h.pos];
            var m = matchTag(load(pg), h.vtag);
            if (m != 0) {
                const es = self.elements.?;
                if (prefetch_slots) @prefetch(@as([*]const u8, @ptrCast(es + h.pos * NL)), .{ .rw = .read, .locality = 3, .cache = .data });
                const p = slotOf(es, h.pos, m);
                if (keyMatches(p, k)) {
                    @branchHint(.likely);
                    return .{ .pg = pg, .lane = laneOf(m), .i = indexOf(es, p), .p = p };
                }
                m &= m - 1;
                while (m != 0) : (m &= m - 1) {
                    const q = slotOf(es, h.pos, m);
                    if (keyMatches(q, k)) return .{ .pg = pg, .lane = laneOf(m), .i = indexOf(es, q), .p = q };
                }
            }
            if (classClear(pg, h.class)) {
                @branchHint(.likely);
                return null;
            }
            return self.findRest(k, hash);
        }

        /// The groups after the home group. It makes the home again from
        /// the hash, so the hot path keeps nothing for it.
        inline fn findRest(self: *const Self, k: KeyView, hash: u64) ?Found {
            const h = homeOf(hash, self.shift);
            var pb: Prober = .{ .pos = h.pos };
            while (pb.next(self.mask)) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                var m = matchTag(load(pg), h.vtag);
                while (m != 0) : (m &= m - 1) {
                    const p = slotOf(self.elements.?, pos, m);
                    if (keyMatches(p, k)) return .{ .pg = pg, .lane = laneOf(m), .i = indexOf(self.elements.?, p), .p = p };
                }
                if (classClear(pg, h.class)) return null;
            }
            return null;
        }

        // adding ////////////////////////////////////////////////////////////

        /// From the probe `pb`, the first group with a free lane takes the
        /// tag; each full one passed marks the tag's class. The slot's
        /// index, for its element to be written there.
        inline fn emplaceFrom(a: Arrays, pb_: Prober, tag: u8) usize {
            var pb = pb_;
            while (true) : (_ = pb.next(a.mask)) {
                const pg = &a.groups[pb.pos];
                const free = matchFree(load(pg));
                if (free != 0) {
                    @branchHint(.likely);
                    const lane = laneOf(free);
                    pg.m[lane] = tag;
                    return pb.pos * NL + lane;
                } else markOverflow(pg, tag);
            }
        }

        inline fn emplace(a: Arrays, hash: u64) usize {
            const h = homeOf(hash, a.shift);
            return emplaceFrom(a, .{ .pos = h.pos }, h.tag);
        }

        /// A slot for a key whose hash is `hash`: the slot that holds it,
        /// or one claimed for it, its tag set and the size counted, for
        /// the caller to write its element. One pass: the find remembers
        /// the first group with a free lane.
        const Claim = struct { i: usize, new: bool };

        inline fn claim(self: *Self, k: KeyView, hash: u64) Claim {
            const h = homeOf(hash, self.shift);
            var pb: Prober = .{ .pos = h.pos };
            var free_pg: ?*Group = null;
            var free_pos: usize = 0;
            var free_lane: usize = 0;
            while (true) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                const vec = load(pg);
                var m = matchTag(vec, h.vtag);
                while (m != 0) : (m &= m - 1) {
                    const p = slotOf(self.elements.?, pos, m);
                    if (keyMatches(p, k)) return .{ .i = indexOf(self.elements.?, p), .new = false };
                }
                if (free_pg == null) {
                    const f = matchFree(vec);
                    if (f != 0) {
                        free_pg = pg;
                        free_pos = pos;
                        free_lane = laneOf(f);
                    }
                }
                if (classClear(pg, h.class)) break;
                if (!pb.next(self.mask)) break;
            }
            if (self.size >= self.ml) {
                @branchHint(.unlikely);
                return .{ .i = self.claimGrown(hash), .new = true };
            }
            self.size += 1;
            if (free_pg) |pg| {
                @branchHint(.likely);
                pg.m[free_lane] = h.tag;
                return .{ .i = free_pos * NL + free_lane, .new = true };
            }
            // Every group the find passed is full: the one it stopped at
            // overflows now, and the probe goes on to a free lane.
            const a = self.arrays();
            markOverflow(&a.groups[pb.pos], h.tag);
            _ = pb.next(a.mask);
            return .{ .i = emplaceFrom(a, pb, h.tag), .new = true };
        }

        /// A slot claimed for a key known to be absent.
        inline fn claimNew(self: *Self, hash: u64) usize {
            if (self.size >= self.ml) {
                @branchHint(.unlikely);
                return self.claimGrown(hash);
            }
            self.size += 1;
            return emplace(self.arrays(), hash);
        }

        /// The table grown, then a slot claimed in it.
        noinline fn claimGrown(self: *Self, hash: u64) usize {
            if (self.size >= max_entries) tooMany();
            self.rehash(self.growthSlots());
            self.size += 1;
            return emplace(self.arrays(), hash);
        }

        inline fn arrays(self: *const Self) Arrays {
            return .{ .groups = self.groups, .elements = self.elements.?, .mask = self.mask, .shift = self.shift };
        }

        /// The slots growth makes room for: `(size + size/61 + 1) / max
        /// load`, or, when drift lowered the maximum load, enough for the
        /// size to fill at most the drift fill of them.
        fn growthSlots(self: *const Self) usize {
            const s = self.size;
            var n = std.math.divCeil(usize, (s + s / 61 + 1) * load_den, load_num) catch unreachable;
            if (self.elements != null and self.ml < self.initialMaxLoad()) {
                n = @max(n, std.math.divCeil(usize, (s + 1) * drift_den, drift_num) catch unreachable);
            }
            return n;
        }

        /// Every entry moved into new arrays of `n` slots or more, each
        /// placed by its hash with no compare.
        fn rehash(self: *Self, n: usize) void {
            const new = newArrays(n);
            if (self.elements) |es| {
                if (!group8 and new.mask == 2 * self.mask + 1) {
                    self.moveDoubled(es, new);
                } else {
                    for (0..self.mask + 1) |g| {
                        var m = matchFull(&self.groups[g]);
                        while (m != 0) : (m &= m - 1) {
                            const e = &es[g * NL + laneOf(m)];
                            new.elements[emplace(new, hashOf(e))] = e.*;
                        }
                    }
                }
            }
            freeArrays(self.elements, self.mask);
            self.groups = new.groups;
            self.elements = new.elements;
            self.mask = new.mask;
            self.shift = new.shift;
            self.ml = self.initialMaxLoad();
        }

        /// Every entry moved into `new`, of twice the groups. An entry at
        /// home in old group `g` is at home in new group `2g` or `2g + 1`,
        /// and a group's lanes fill in order, so the pair's next free lanes
        /// are kept as counts, read once for `g`: no entry loads a group the
        /// entry before it wrote a tag into, a load the store would hold up
        /// (a 16-byte load over a pending 1-byte store waits for it to
        /// commit: bench/hash's 100,000-key inserts 12% slower on pup when
        /// half the entries met it). An entry that overflowed, or whose new
        /// group is full, is placed by `emplace`, and the counts follow it.
        /// Groups of 7 on arm64 keep the placement of `emplace`: random
        /// keys alternate between the pair, so the waits there are short
        /// and the M5 hides them, and the counts cost its random-key
        /// inserts 4-6% (docs/history/records/2026-10/hash-race/
        /// rehash-counts.md).
        fn moveDoubled(self: *const Self, es: [*]Element, new: Arrays) void {
            for (0..self.mask + 1) |g| {
                var m = matchFull(&self.groups[g]);
                if (m == 0) continue;
                const pair = 2 * g;
                var even: usize = @popCount(matchFull(&new.groups[pair]));
                var odd: usize = @popCount(matchFull(&new.groups[pair + 1]));
                // The last group's last lane holds the sentinel.
                const odd_lanes: usize = if (pair + 1 == new.mask) NL - 1 else NL;
                while (m != 0) : (m &= m - 1) {
                    const e = &es[g * NL + laneOf(m)];
                    const hash = hashOf(e);
                    const h = homeOf(hash, new.shift);
                    const is_odd = h.pos & 1 != 0;
                    const lane = if (is_odd) odd else even;
                    const lanes = if (is_odd) odd_lanes else NL;
                    var slot: usize = undefined;
                    if (h.pos >> 1 == g and lane < lanes) {
                        @branchHint(.likely);
                        new.groups[h.pos].m[lane] = h.tag;
                        slot = h.pos * NL + lane;
                        even += @intFromBool(!is_odd);
                        odd += @intFromBool(is_odd);
                    } else {
                        slot = emplace(new, hash);
                        const pos = slot / NL;
                        if (pos == pair) even += 1;
                        if (pos == pair + 1) odd += 1;
                    }
                    new.elements[slot] = e.*;
                }
            }
        }

        /// The slot `p`, whose entry is moved out or dropped, freed; the
        /// maximum load lowered by one where a probe may walk past it.
        inline fn recover(self: *Self, pg: *Group, lane: usize) void {
            self.ml -= @intFromBool(!isNotOverflowed(pg, pg.m[lane]));
            pg.m[lane] = 0;
            self.size -= 1;
        }

        // the built-in's members ////////////////////////////////////////////
        //
        // Each is what resolve.registerTables declares for
        // `UnorderedMap[K, V]` or `UnorderedSet[K]`, lowered as emit lowers
        // a call: `?K` a `ReadView(K)`, `!V` a `*V`, `Int` an `i64`, `T?`
        // an `Opt(T)`, a closure view an `rt.FnRef`.

        /// `find(?@, k: ?K) -> Int?`: the slot of `k`.
        pub inline fn find(self: *const Self, k: KeyView) ?i64 {
            const f = self.locate(k, hashKey(k)) orelse return null;
            return @intCast(f.i);
        }

        /// `get(?@, k: ?K) -> (?V)? from @`: the value of `k`, viewed
        /// where the slot that holds it was found.        ///
        /// Its origin is narrowed to self (`resolve.fromSelf`), which holds
        /// only because `k` is hashed and compared, never returned or
        /// stored: returning anything reached through `k` would make that
        /// narrowing unsound.
        pub inline fn get(self: *const Self, k: KeyView) ?rt.ReadView(V) {
            const f = self.locate(k, hashKey(k)) orelse return null;
            return rt.lend(&f.p.value);
        }

        /// `edit(!@, k: ?K) -> (!V)? from @`: the value of `k`, lent to
        /// write.        ///
        /// Its origin is narrowed to self (`resolve.fromSelf`), which holds
        /// only because `k` is hashed and compared, never returned or
        /// stored: returning anything reached through `k` would make that
        /// narrowing unsound.
        pub inline fn edit(self: *Self, k: KeyView) ?*V {
            const f = self.locate(k, hashKey(k)) orelse return null;
            return &f.p.value;
        }

        /// `key(?@, j: Int) -> ?K`.
        pub inline fn key(self: *const Self, j: i64) KeyView {
            return rt.lend(&self.slotAt(@intCast(j), true).key);
        }

        /// `value(?@, j: Int) -> ?V`.
        pub inline fn value(self: *const Self, j: i64) rt.ReadView(V) {
            return rt.lend(&self.slotAt(@intCast(j), true).value);
        }

        /// `value_mut(!@, j: Int) -> !V`.
        pub inline fn value_mut(self: *Self, j: i64) *V {
            return &self.slotAt(@intCast(j), true).value;
        }

        /// `put(!@, k: K, v: V) -> Bool`: `v` under `k`; a key already
        /// there keeps its slot, and its old value and `k` are dropped.
        /// True when `k` was new.
        pub inline fn put(self: *Self, k: K, v: V) bool {
            var kk = k;
            const h = hashKey(rt.lend(&kk));
            const c = self.claim(rt.lend(&kk), h);
            const e = &self.elements.?[c.i];
            if (!c.new) {
                rt.dropElement(K, &kk);
                rt.dropElement(V, &e.value);
                e.value = v;
                return false;
            }
            e.* = makeElement(kk, v, h);
            return true;
        }

        /// `replace(!@, k: K, v: V) -> V?`: as `put`, handing the old
        /// value back.
        pub inline fn replace(self: *Self, k: K, v: V) rt.Opt(V) {
            var kk = k;
            const h = hashKey(rt.lend(&kk));
            const c = self.claim(rt.lend(&kk), h);
            const e = &self.elements.?[c.i];
            if (!c.new) {
                rt.dropElement(K, &kk);
                const old = e.value;
                e.value = v;
                return rt.pack(rt.Opt(V), old);
            }
            e.* = makeElement(kk, v, h);
            return rt.pack(rt.Opt(V), null);
        }

        /// `put_new(!@, k: K, v: V) -> Bool`: `v` under `k` only when `k`
        /// is new; otherwise both are dropped.
        pub inline fn put_new(self: *Self, k: K, v: V) bool {
            return self.ensureAt(k, v).new;
        }

        /// `add(!@, k: K) -> Bool`: a HashSet's `put_new`.
        pub inline fn add(self: *Self, k: K) bool {
            return self.put_new(k, {});
        }

        /// `ensure(!@, k: K, v: V) -> Int`: the slot of `k`, made of `k`
        /// and `v` when `k` is new; otherwise both are dropped.
        pub inline fn ensure(self: *Self, k: K, v: V) i64 {
            return @intCast(self.ensureAt(k, v).i);
        }

        inline fn ensureAt(self: *Self, k: K, v: V) Claim {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
            const c = self.claim(rt.lend(&kk), h);
            if (!c.new) {
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return c;
            }
            self.elements.?[c.i] = makeElement(kk, vv, h);
            return c;
        }

        /// `insert_new(!@, k: K, v: V) -> Int`: the slot of `k`, which is
        /// not there, made of `k` and `v`.
        pub fn insert_new(self: *Self, k: K, v: V) i64 {
            @branchHint(.unlikely);
            var kk = k;
            const h = hashKey(rt.lend(&kk));
            const i = self.claimNew(h);
            self.elements.?[i] = makeElement(kk, v, h);
            return @intCast(i);
        }

        /// `take(!@, k: ?K) -> V?` (a HashSet's: `-> K?`): the entry of `k`
        /// taken out; a HashMap drops its key and hands its value back.
        pub inline fn take(self: *Self, k: KeyView) rt.Opt(if (is_set) K else V) {
            const R = rt.Opt(if (is_set) K else V);
            const f = self.locate(k, hashKey(k)) orelse return rt.pack(R, null);
            const e = f.p;
            self.recover(f.pg, f.lane);
            if (is_set) return rt.pack(R, e.key);
            rt.dropElement(K, &e.key);
            return rt.pack(R, e.value);
        }

        /// `count(?@) -> Int`: the live entries.
        pub inline fn count(self: *const Self) i64 {
            return @intCast(self.size);
        }

        /// `next_slot(?@, g: !Int, lanes: !Int) -> Int`: the next full
        /// slot of a walk, or -1 past the last. `g` is the group the walk
        /// is in (-1 before the first) and `lanes` that group's full lanes
        /// not yet given, so a step within a group clears one bit and the
        /// walk's state stays in two words the caller holds.
        pub inline fn next_slot(self: *const Self, g: *i64, lanes: *i64) i64 {
            const groups: i64 = if (self.elements != null) @intCast(self.mask + 1) else 0;
            var at = g.*;
            var m: Mask = @truncate(@as(u64, @bitCast(lanes.*)));
            while (m == 0) {
                at +%= 1;
                if (at >= groups) {
                    g.* = at;
                    lanes.* = 0;
                    return -1;
                }
                m = matchFull(&self.groups[@as(usize, @bitCast(at))]);
            }
            const slot = @as(usize, @bitCast(at)) * NL + laneOf(m);
            g.* = at;
            lanes.* = @bitCast(@as(u64, m & (m -% 1)));
            return @intCast(slot);
        }

        /// `update(!@, f: ?sub(?K, !V))`: `f` called with each entry's key
        /// to read and value to write.
        pub fn update(self: *Self, f: anytype) void {
            const es = self.elements orelse return;
            for (0..self.mask + 1) |g| {
                var m = matchFull(&self.groups[g]);
                while (m != 0) : (m &= m - 1) {
                    const entry = &es[g * NL + laneOf(m)];
                    f.call(.{ rt.lend(&entry.key), &entry.value });
                }
            }
        }

        /// `retain(!@, f)`: keep the entries for which `f` is true; one it
        /// rejects is dropped then. A HashMap's `f` gets each key to read
        /// and value to write, a HashSet's each key.
        pub fn retain(self: *Self, f: anytype) void {
            const es = self.elements orelse return;
            for (0..self.mask + 1) |g| {
                const pg = &self.groups[g];
                var m = matchFull(pg);
                while (m != 0) : (m &= m - 1) {
                    const lane = laneOf(m);
                    const e = &es[g * NL + lane];
                    const keep = if (is_set)
                        f.call(.{rt.lend(&e.key)})
                    else
                        f.call(.{ rt.lend(&e.key), &e.value });
                    if (keep) continue;
                    rt.dropElement(V, &e.value);
                    rt.dropElement(K, &e.key);
                    self.recover(pg, lane);
                }
            }
        }

        /// `clear(!@)`: drop every entry, keeping the memory.
        pub fn clear(self: *Self) void {
            self.dropLive();
            if (self.elements == null) return;
            const groups = self.mask + 1;
            @memset(@as([*]u8, @ptrCast(self.groups))[0 .. groups * @sizeOf(Group)], 0);
            self.groups[groups - 1].m[NL - 1] = sentinel;
            self.size = 0;
            self.ml = self.initialMaxLoad();
        }

        /// `reserve(!@, n: Int)`: room for `n` more entries at once, so the
        /// next `n` puts of new keys do not grow the table.
        pub fn reserve(self: *Self, n: i64) void {
            if (n <= 0) return;
            const more: usize = @intCast(n);
            // The limit first: past it, the arrays would be made before
            // the growth traps.
            if (more > max_entries - self.size) tooMany();
            const want = self.size + more;
            if (want <= self.ml) return;
            self.rehash(std.math.divCeil(usize, want * load_den, load_num) catch unreachable);
        }

        // drop, clone, walk /////////////////////////////////////////////////

        /// Drop every entry, its value before its key, as an object drops
        /// its fields.
        fn dropLive(self: *Self) void {
            if (comptime !rt.needsDrop(Element)) return;
            const es = self.elements orelse return;
            var g = self.mask + 1;
            while (g > 0) {
                g -= 1;
                var m = matchFull(&self.groups[g]);
                while (m != 0) : (m &= m - 1) {
                    const e = &es[g * NL + laneOf(m)];
                    rt.dropElement(V, &e.value);
                    rt.dropElement(K, &e.key);
                }
            }
        }

        /// What `rt.dropElement` runs: every entry dropped, then the block
        /// freed.
        pub fn __rig_drop(self: *Self) void {
            self.dropLive();
            freeArrays(self.elements, self.mask);
            self.* = .{};
        }

        /// `+m`: a new table of the entries, each cloned.
        pub fn clone(self: *const Self) Self {
            var out: Self = .{};
            if (self.size == 0) return out;
            out.reserve(@intCast(self.size));
            const es = self.elements.?;
            const a = out.arrays();
            for (0..self.mask + 1) |g| {
                var m = matchFull(&self.groups[g]);
                while (m != 0) : (m &= m - 1) {
                    const e = &es[g * NL + laneOf(m)];
                    const h = hashOf(e);
                    a.elements[emplace(a, h)] = makeElement(rt.cloneValue(&e.key), rt.cloneValue(&e.value), h);
                }
            }
            out.size = self.size;
            return out;
        }

        /// The slots a walk for printing passes (`isLive`, `entryAt`).
        pub fn walkEnd(self: *const Self) usize {
            return self.slotCount();
        }

        /// Whether slot `j`, below `walkEnd`, holds an entry.
        pub fn isLive(self: *const Self, j: usize) bool {
            return self.groups[j / NL].m[j % NL] > sentinel;
        }

        /// Slot `j`'s key and value, for printing.
        pub fn entryAt(self: *const Self, j: usize) *const Element {
            return &self.elements.?[j];
        }

        /// The invariants, for tests: the size is the full lanes; every
        /// entry is on its probe sequence with its tag, once; every group
        /// it walked past marks its class; the sentinel is set.
        fn verify(self: *const Self) !void {
            if (self.elements == null) {
                if (self.size != 0) return error.Corrupt;
                return;
            }
            if (self.size > self.ml or self.ml > self.initialMaxLoad()) return error.Corrupt;
            if (self.groups[self.mask].m[NL - 1] != sentinel) return error.Corrupt;
            var full: usize = 0;
            for (0..self.mask + 1) |g| {
                var m = matchFull(&self.groups[g]);
                while (m != 0) : (m &= m - 1) {
                    full += 1;
                    const lane = laneOf(m);
                    const e = &self.elements.?[g * NL + lane];
                    const h = homeOf(hashOf(e), self.shift);
                    if (h.tag != self.groups[g].m[lane]) return error.Corrupt;
                    var pb: Prober = .{ .pos = h.pos };
                    while (pb.pos != g) {
                        if (isNotOverflowed(&self.groups[pb.pos], h.tag)) return error.Corrupt;
                        if (!pb.next(self.mask)) return error.Corrupt;
                    }
                }
            }
            if (full != self.size) return error.Corrupt;
        }
    };
}

// tests //////////////////////////////////////////////////////////////////////

const testing = std.testing;

/// The slots of `m`'s entries, as the prelude's walk gives them.
fn walkSlots(m: anytype, out: *std.ArrayList(i64)) !void {
    out.clearRetainingCapacity();
    var g: i64 = -1;
    var lanes: i64 = 0;
    while (true) {
        const j = m.next_slot(&g, &lanes);
        if (j < 0) break;
        try out.append(testing.allocator, j);
    }
}

test "unordered: the table is 48 bytes, as sema.minBytesOf says" {
    try testing.expectEqual(@as(usize, 48), @sizeOf(UnorderedMap(i64, i64)));
    try testing.expectEqual(@as(usize, 48), @sizeOf(UnorderedSet(u8)));
}

test "unordered: puts, takes, and walks" {
    var m: UnorderedMap(i64, i64) = .{};
    defer m.__rig_drop();
    var slots: std.ArrayList(i64) = .empty;
    defer slots.deinit(testing.allocator);
    try walkSlots(&m, &slots);
    try testing.expect(m.find(3) == null and slots.items.len == 0);
    var i: i64 = 0;
    while (i < 1000) : (i += 1) try testing.expect(m.put(i, i * 2));
    try testing.expect(!m.put(5, 7));
    try testing.expectEqual(@as(i64, 7), m.value(m.find(5).?));
    i = 0;
    while (i < 1000) : (i += 3) try testing.expectEqual(if (i == 5) 7 else i * 2, rt.some(m.take(i)).?);
    try testing.expectEqual(@as(i64, 1000 - 334), m.count());
    var n: i64 = 0;
    var sum: i64 = 0;
    try walkSlots(&m, &slots);
    for (slots.items) |at| {
        const k = m.key(at);
        try testing.expect(@mod(k, 3) != 0);
        sum += k;
        n += 1;
    }
    try testing.expectEqual(m.count(), n);
    try testing.expectEqual(@as(i64, 499500 - 166833), sum);
    try m.verify();
}

test "unordered: a set of strided keys" {
    var s: UnorderedSet(i64) = .{};
    defer s.__rig_drop();
    var i: i64 = 1;
    // Multiples of 2^20 and of the golden ratio: strides a one-multiply
    // hash must still spread.
    while (i < 20_000) : (i += 1) {
        try testing.expect(s.add(i << 20));
        try testing.expect(s.add(i *% -7046029254386353131));
    }
    try s.verify();
    try testing.expectEqual(@as(i64, 39_998), s.count());
    i = 1;
    while (i < 20_000) : (i += 1) try testing.expect(s.find(i << 20) != null and s.find((i << 20) + 1) == null);
}

test "unordered: growth moves every entry, crowded and overflowed ones too" {
    // Dense keys and multiples of 2^32 crowd some groups under a
    // one-multiply hash, so entries overflow past home before growth
    // moves them; the table is checked after each growth.
    for ([_]u6{ 0, 32 }) |shift| {
        var m: UnorderedMap(i64, i64) = .{};
        defer m.__rig_drop();
        var mask = m.mask;
        var grown: usize = 0;
        var i: i64 = 0;
        while (i < 20_000) : (i += 1) {
            try testing.expect(m.put(i << shift, i));
            if (m.mask != mask) {
                mask = m.mask;
                grown += 1;
                try m.verify();
            }
        }
        try testing.expect(grown >= 8);
        i = 0;
        while (i < 20_000) : (i += 1) try testing.expectEqual(i, m.value(m.find(i << shift).?));
        try testing.expect(m.find(@as(i64, 20_000) << shift) == null);
    }
}

test "unordered: random writes, takes, retains, and clears against a model" {
    const gpa = testing.allocator;
    for ([_]u64{ 40, 3000, 100_000 }, 0..) |range, seed| {
        var m: UnorderedMap(i64, i64) = .{};
        defer m.__rig_drop();
        var values: std.AutoHashMapUnmanaged(i64, i64) = .empty;
        defer values.deinit(gpa);
        var prng = std.Random.DefaultPrng.init(seed + 7);
        var slots: std.ArrayList(i64) = .empty;
        defer slots.deinit(gpa);
        const rnd = prng.random();
        for (0..60_000) |i| {
            const k: i64 = @intCast(rnd.uintLessThan(u64, range));
            switch (rnd.uintLessThan(u16, 1000)) {
                0...399 => {
                    const v: i64 = @intCast(i);
                    const gop = try values.getOrPut(gpa, k);
                    gop.value_ptr.* = v;
                    try testing.expectEqual(!gop.found_existing, m.put(k, v));
                },
                400...649 => {
                    const want = values.fetchRemove(k);
                    const got = rt.some(m.take(k));
                    try testing.expectEqual(want == null, got == null);
                    if (want) |kv| try testing.expectEqual(kv.value, got.?);
                },
                650...989 => {
                    const got = m.find(k);
                    try testing.expectEqual(values.get(k), if (got) |j| m.value(j) else null);
                },
                990...996 => {
                    // Keep the odd keys.
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
                    var it = values.iterator();
                    var evens: std.ArrayList(i64) = .empty;
                    defer evens.deinit(gpa);
                    while (it.next()) |e| if (@mod(e.key_ptr.*, 2) == 0) try evens.append(gpa, e.key_ptr.*);
                    for (evens.items) |x| _ = values.remove(x);
                },
                997 => {
                    m.clear();
                    values.clearRetainingCapacity();
                },
                else => m.reserve(@intCast(rnd.uintLessThan(u64, 64))),
            }
            try testing.expectEqual(@as(i64, @intCast(values.count())), m.count());
            if (i % 997 == 0) {
                try m.verify();
                try walkSlots(&m, &slots);
                for (slots.items) |at| try testing.expectEqual(values.get(m.key(at)).?, m.value(at));
                try testing.expectEqual(values.count(), slots.items.len);
                var c = m.clone();
                defer c.__rig_drop();
                try c.verify();
                var vit = values.iterator();
                while (vit.next()) |e| try testing.expectEqual(e.value_ptr.*, c.value(c.find(e.key_ptr.*).?));
            }
        }
    }
}

test "unordered: a turnover at a fixed size rehashes on drift and stays bounded" {
    var m: UnorderedMap(i64, i64) = .{};
    defer m.__rig_drop();
    const size = 13_000;
    var i: i64 = 0;
    while (i < size) : (i += 1) _ = m.put(i, i);
    const slots = m.slotCount();
    var lo: i64 = 0;
    var hi: i64 = size;
    for (0..1_000_000) |_| {
        try testing.expectEqual(lo, rt.some(m.take(lo)).?);
        lo += 1;
        _ = m.put(hi, hi);
        hi += 1;
    }
    try testing.expect(m.slotCount() <= 2 * slots + 1);
    try m.verify();
    try testing.expectEqual(@as(i64, size), m.count());
}
