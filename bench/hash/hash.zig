//! The design Rig's unordered `HashMap` takes: boost's FOA table
//! (bench/hash/foa.zig, a faithful port of boost 1.92's
//! unordered_flat_map) changed where bench/hash measured it losing. The
//! record of each change, kept or dropped, with its numbers, is
//! docs/history/records/2026-10/hash-race/zig-hash.md. Every change is an
//! `Options` field, so each experiment can be built again; the defaults
//! are the measured winners.
//!
//! What it keeps from boost:
//! - Element slots in groups, a power-of-two group count, and a sentinel
//!   in the last slot of the last group.
//! - A metadata word a group, apart from the slots: a tag a slot (0 free,
//!   1 the sentinel, 2 to 255 full) and an overflow byte. An insert that
//!   passes a full group sets bit `tag % 8` of its overflow byte; a
//!   lookup stops at the first group whose bit for its tag is clear.
//! - Quadratic probing over groups, a one-byte erase with no tombstones,
//!   and the anti-drift decrement of the maximum load.
//!
//! What it changes (the defaults):
//! - Group width per target: x86-64 keeps boost's 15 slots and 16 bytes
//!   (`pcmpeqb`, `pmovmskb`); arm64 takes 7 slots and 8 bytes (`cmeq.8b`,
//!   `fmov`, a byte a lane), with a maximum load of 0.8 and 4 groups at
//!   least.
//! - An integer key is hashed by the table with one multiply, a text key
//!   by folded multiplies up to 32 bytes (Wyhash above) and compared by
//!   words; the Context's hash serves every other key.
//! - The hash is rotated a byte: the tag is its top byte and the home
//!   group the bits below, so a one-multiply hash gives good tags.
//! - The tag reaches a vector register by a broadcasting load from a
//!   table; its overflow class bit comes from a table too.
//! - On arm64 a 16-byte slot's address is the group's plus `ctz << 1`.
//! - A text key keeps its full hash in its slot, so growth never reads a
//!   key again; lookups do not compare it.
//! - No element prefetch for slots over 32 bytes; for smaller ones, the
//!   home group's first slot line, inside the branch a tag match takes.
//! - A lookup's home group is peeled from the probe loop: a hit in its
//!   first matching lane takes no loop, and the overflow byte is read
//!   only on the way to a miss.
//! - One pass an insert: the find remembers the first free slot.
//! - A rehash forced by drift sizes the table to at most 0.6 full (0.5
//!   for groups of 7).
//!
//! `Options.checked` is the "Rig-shaped" variant: it puts back the
//! bounds tests safe Rig keeps, on every index that is not a masked
//! power-of-two index (the slot index `pos * S + lane`, and a tag read
//! by lane).
const std = @import("std");
const builtin = @import("builtin");

pub const Prefetch = enum {
    /// No element prefetch.
    none,
    /// boost's: after the match, the first line (x86) or half the group (ARM).
    boost,
    /// The home group's first slot line, issued from the hash before the
    /// metadata arrives (abseil's order), when the table is large.
    first,
    /// As `first`, and the next line too.
    two,
    /// The line of the key's home lane (`home_lane`).
    home,
    /// Inside the branch taken when the tag matches some lane, the home
    /// group's first slot line. The address follows from the hash, so on
    /// a predicted branch the line is requested before the metadata
    /// arrives; in a loop of misses the branch is predicted not taken and
    /// nothing is fetched. This is where boost's prefetch sits.
    matched,
    /// As `matched`, the home lane's line (`home_lane`).
    matched_home,
    /// As `matched`, and the next 64 bytes too, as boost on ARM.
    matched2,
    /// As `matched`, the lines of the group's first and last slots.
    matched_span,
};

pub const Options = struct {
    /// arm64 only: reduce a group compare to a mask with `shrn #4` (four bits
    /// a lane, lane = ctz >> 2) instead of boost's NEON movemask emulation.
    nibble_mask: bool = true,
    /// Hash an integer key with one multiply, inside the table, instead of
    /// the Context's hash.
    int_mul: bool = true,
    /// Hash a `[]const u8` key with the table's own folded-multiply hash up
    /// to 32 bytes (Wyhash above), and compare by words, instead of the
    /// Context's hash and eql.
    text_fold: bool = true,
    /// Keep the full hash in each slot; null: for every key but integers.
    store_hash: ?bool = null,
    /// With a stored hash, a lookup compares it before the key.
    hash_compare: bool = false,
    /// What a lookup prefetches; null: `matched` for slots of 32 bytes or
    /// fewer, else `none`.
    prefetch: ?Prefetch = null,
    /// The smallest slot array, in bytes, for which the `matched`
    /// prefetches run. 0: always. At 8 MiB the size test cost small maps'
    /// hits 10% and did not help rnd150000 (Mac).
    prefetch_min_bytes: usize = 0,
    /// The fewest groups for which `first` and `two` prefetch.
    prefetch_min_groups: usize = 1 << 13,
    /// The fill a rehash forced by drift sizes the table to; null: 0.6, or
    /// 0.5 for groups of 7 (at 0.6, churn1000 rehashed at the same size).
    drift_fill: ?f32 = null,
    /// Insert in one pass, the find remembering the first free slot.
    one_pass: bool = true,
    /// Slots a group in the slot array: 15, or 16 with the last unused, so
    /// that a slot's address is a shift and an add, not a multiply.
    stride16: bool = false,
    /// A home lane from the hash: an insert into the home group takes it
    /// when free.
    home_lane: bool = false,
    /// With `home_lane`, a lookup tests the home lane's tag byte and key, by
    /// a predicted branch, before the group match.
    first_probe: bool = false,
    /// Where the tag and the home group come from: `below`, the group the
    /// top bits and the tag the byte below them; `low`, boost's, the tag
    /// the low byte (weak for a one-multiply hash); `top`, the tag the top
    /// byte and the group the bits below it.
    /// `rot`, the hash rotated left a byte, then as `low`: the tag the top
    /// byte and the group the bits below it, with boost's instructions.
    tag_bits: enum { below, low, top, rot } = .rot,
    /// Growth without a stored hash: hashing a group's keys again, prefetch
    /// the texts of the next group's.
    rehash_prefetch: bool = true,
    /// Groups of 7 slots and an 8-byte metadata word (`cmeq.8b` and `fmov`
    /// on arm64, hashbrown's width), not 15 and 16 bytes; null: on arm64.
    group8: ?bool = null,
    /// The maximum load; null: boost's 0.875, or 0.8 for groups of 7, whose
    /// small groups overflow more often near full.
    max_load: ?f32 = null,
    /// The fewest groups a table allocates; null: 2, or 4 for groups of 7,
    /// so a map of 16 needs no growth past its first table.
    min_groups: ?usize = null,
    /// Peel the lookup's home group out of the probe loop.
    peel: bool = true,
    /// With `peel`, the other lanes and groups inline, not called.
    peel_inline: bool = true,
    /// x86: the peeled lookup's group and slot addresses as byte offsets
    /// from one shift and mask (measured: one instruction more, as LLVM
    /// makes the slots' multiply by 15 two `lea`s).
    byte_home: bool = false,
    /// Rig-shaped: a bounds test on each slot index and each tag read by
    /// lane, as safe Rig keeps them.
    checked: bool = false,
    /// With `checked`, the slot's address made as unchecked code makes it
    /// (`ctz << 2`), the test apart: what a Rig that kept the test but
    /// folded the address would emit.
    checked_fold: bool = false,
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

/// group15's 16-byte metadata word, or with `group8` an 8-byte word of 7
/// tags and the overflow byte.
fn GroupOf(comptime W: usize) type {
    return extern struct {
        m: [W]u8 align(W),
    };
}

const sentinel_ = 1;

/// `is_not_overflowed`'s table of bits.
const shift_table = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

/// The tag of a byte of the hash, broadcast to four bytes: 0 and 1 (free,
/// sentinel) become 8 and 9, which keeps the byte's class mod 8. Tables,
/// as boost's `match_word`, so that the tag reaches a vector register by
/// a broadcasting load (`vpbroadcastd`, `ld1r`), not by a move from a
/// general register and a shuffle, which on x86 costs a hit in cache
/// about a third.
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

inline fn reduce(t: u8) u8 {
    return reduced_table[t];
}

/// The tag of hash byte `b` in every lane of a group of `W`.
inline fn tagVector(comptime W: usize, b: u8) @Vector(W, u8) {
    return switch (arch) {
        .sse2 => @bitCast(@as(@Vector(W / 4, u32), @splat(match_word[b]))),
        else => @splat(reduced_table[b]),
    };
}

/// Two groups as an empty container's: the sentinel set, nothing else.
/// `empty` points here, so lookup needs no null check; capacity is 0, so no
/// insert ever writes it.
fn Dummy(comptime W: usize) type {
    return struct {
        var groups: [2]GroupOf(W) = blk: {
            var g: GroupOf(W) = .{ .m = @splat(0) };
            g.m[W - 2] = 1;
            break :blk .{ g, g };
        };
    };
}

/// The masks of a group's lanes: one bit a lane, or with `nibble_mask` on
/// arm64, bit 0 of each lane's nibble, so that `ctz` is four times the lane
/// and, for 16-byte slots, `ctz << 2` the slot's byte offset.
fn Masks(comptime nibble: bool, comptime W: usize) type {
    return struct {
        /// arm64 groups of 8: a byte a lane, bit 0 of each (`cmeq.8b`, `fmov`).
        const bytes8 = W == 8 and arch == .neon;
        /// Bits a lane in the mask.
        pub const step: u5 = if (bytes8) 8 else if (nibble) 4 else 1;
        pub const T = if (bytes8 or nibble) u64 else u32;
        /// The element lanes, all but the last.
        pub const lanes: T = blk: {
            var x: T = 0;
            for (0..W - 1) |i| x |= @as(T, 1) << @intCast(i * step);
            break :blk x;
        };

        pub inline fn laneBit(i: u32) T {
            return @as(T, 1) << @intCast(i * step);
        }

        pub inline fn lane(m: T) u32 {
            return @as(u32, @ctz(m)) >> @intCast(@ctz(@as(u32, step)));
        }

        /// The lanes where `eq` holds, before `& lanes`.
        pub inline fn reduceEq(eq: @Vector(W, bool)) T {
            if (W == 8) {
                if (bytes8) {
                    const bytes: @Vector(8, u8) = @select(u8, eq, @as(@Vector(8, u8), @splat(0xFF)), @as(@Vector(8, u8), @splat(0)));
                    return @bitCast(bytes);
                }
                return @as(u8, @bitCast(eq));
            }
            if (nibble) {
                // cmeq, shrn #4, fmov
                const bytes: @Vector(16, u8) = @select(u8, eq, @as(@Vector(16, u8), @splat(0xFF)), @as(@Vector(16, u8), @splat(0)));
                const halves: @Vector(8, u16) = @bitCast(bytes);
                const narrowed: @Vector(8, u8) = @truncate(halves >> @splat(4));
                return @bitCast(narrowed);
            }
            switch (arch) {
                .neon => {
                    // simde_mm_movemask_epi8, as boost copies it.
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
/// ratio's 0x9e3779b97f4a7c15, a common stride (bench/hash's int keys are its
/// multiples), whose square spreads such keys into a few groups.
const fib: u64 = 0x4b33a62ed433d4a3;

noinline fn outOfBounds() noreturn {
    @branchHint(.cold);
    @panic("index out of bounds");
}

pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return HashMapWith(K, V, Context, .{});
}

pub fn HashMapWith(comptime K: type, comptime V: type, comptime Context: type, comptime options: Options) type {
    comptime std.debug.assert(@sizeOf(Context) == 0);
    return struct {
        const Self = @This();
        const group8 = options.group8 orelse (arch == .neon);
        const max_load: f32 = options.max_load orelse (if (group8) 0.8 else mlf);
        const min_groups: usize = options.min_groups orelse (if (group8) 4 else 2);
        const drift_fill: f32 = options.drift_fill orelse (if (group8) 0.5 else 0.6);
        /// Lanes a group, the last the overflow byte.
        const W: usize = if (group8) 8 else 16;
        /// Element slots a group.
        const NL: usize = W - 1;
        const Group = GroupOf(W);
        const VW = @Vector(W, u8);
        const M = Masks(options.nibble_mask and arch == .neon, W);
        /// x86: the peeled lookup works in byte offsets (see `find`).
        const byte_home = options.byte_home and arch == .sse2 and options.tag_bits == .rot and !options.checked and
            (prefetch == .matched or prefetch == .none) and
            (S * @sizeOf(Element)) % @sizeOf(Group) == 0;
        const Mask = M.T;

        const int_key = @typeInfo(K) == .int;
        const text_key = K == []const u8;
        const own_int = options.int_mul and int_key and @sizeOf(K) <= 8;
        const own_text = options.text_fold and text_key;
        const store_hash = options.store_hash orelse !int_key;
        const prefetch: Prefetch = options.prefetch orelse
            (if (@sizeOf(Element) <= 32) .matched else .none);

        pub const KV = struct { key: K, value: V };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        /// A slot: the key and value, and with `store_hash` the key's hash.
        const Element = if (store_hash)
            struct { key: K, value: V, hash: u64 }
        else
            struct { key: K, value: V };
        const ctx: Context = undefined;
        const elem_align = @alignOf(Element);
        /// Slots a group in the slot array.
        const S: usize = if (options.stride16) W else NL;
        /// Slots in the slot array of `groups` groups.
        inline fn slotsFor(groups: usize) usize {
            return if (options.stride16) groups * S else groups * NL - 1;
        }

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
            .groups = &Dummy(W).groups,
            .elements = null,
            .ml = 0,
            .size = 0,
        };

        // ---- group15 -------------------------------------------------------

        inline fn load(pg: *const Group) VW {
            return pg.m;
        }

        inline fn matchTag(v: VW, tag: VW) Mask {
            return M.reduceEq(v == tag) & M.lanes;
        }

        inline fn matchFree(v: VW) Mask {
            return M.reduceEq(v == @as(VW, @splat(0))) & M.lanes;
        }

        inline fn matchAvailable(pg: *const Group) Mask {
            return matchFree(load(pg));
        }

        inline fn matchOccupied(pg: *const Group) Mask {
            return switch (arch) {
                .neon => M.reduceEq(load(pg) > @as(VW, @splat(0))) & M.lanes,
                else => ~matchAvailable(pg) & M.lanes,
            };
        }

        inline fn isNotOverflowed(pg: *const Group, tag: u8) bool {
            return pg.m[W - 1] & (@as(u8, 1) << @as(u3, @truncate(tag))) == 0;
        }

        /// As `isNotOverflowed`, by the class. The bit comes from a table, as
        /// boost's `is_not_overflowed`, so a hit pays one instruction for it
        /// (the index), not a shift.
        inline fn classClear(pg: *const Group, class: u3) bool {
            // A volatile read, so the compiler cannot extract the byte from
            // the loaded group ahead of the tag-match branch, where a hit
            // would pay for it.
            const o: *const volatile u8 = &pg.m[W - 1];
            return o.* & shift_table[class] == 0;
        }

        inline fn markOverflow(pg: *Group, tag: u8) void {
            pg.m[W - 1] |= @as(u8, 1) << @as(u3, @truncate(tag));
        }

        inline fn tagAt(pg: *const Group, n: u32) u8 {
            if (options.checked and n >= W) outOfBounds();
            return pg.m[n];
        }

        /// The slot's stored tag keeps its hash's class mod 8.
        inline fn maybeCausedOverflow(pg: *const Group, n: u32) bool {
            return !isNotOverflowed(pg, tagAt(pg, n));
        }

        inline fn setTag(pg: *Group, n: u32, tag: u8) void {
            if (options.checked and n >= W) outOfBounds();
            pg.m[n] = tag;
        }

        // ---- hashing -------------------------------------------------------

        inline fn hashFor(k: K) u64 {
            if (own_int) return @as(u64, @as(@Int(.unsigned, @bitSizeOf(K)), @bitCast(k))) *% fib;
            if (own_text) return textHash(k);
            return ctx.hash(k);
        }

        inline fn eql(a: K, b: K) bool {
            if (own_text) return textEql(a, b);
            return ctx.eql(a, b);
        }

        /// The home group (the hash's top bits) and the tag (the byte below
        /// them).
        /// The home group, the tag, its broadcast, and the home lane.
        const Home = struct { pos: usize, tag: u8, vtag: VW, class: u3, lane: u32 };

        inline fn home(hash: u64, size_index: u6, mask: usize) Home {
            const t = switch (options.tag_bits) {
                .below => hash >> (size_index - 8),
                .low => hash,
                .top => hash >> 56,
                .rot => std.math.rotl(u64, hash, 8),
            };
            const pos: usize = @intCast(switch (options.tag_bits) {
                .below => t >> 8,
                .low => hash >> size_index,
                .top => (hash >> (size_index - 8)) & mask,
                .rot => t >> size_index,
            });
            // The home lane, 0 to NL - 1, from the four bits below the tag.
            const b: u32 = @truncate((hash >> (size_index - 12)) & 15);
            return .{
                .pos = if (options.checked) pos & mask else pos,
                .tag = reduce(@truncate(t)),
                .vtag = tagVector(W, @truncate(t)),
                // The tag's class, from the hash byte, which has the tag's
                // class mod 8, so not waiting on the table.
                .class = @as(u3, @truncate(t)),
                .lane = if (options.home_lane) (b * @as(u32, NL)) >> 4 else 0,
            };
        }

        // ---- pow2_size_policy ----------------------------------------------

        inline fn sizeIndex(n: usize) u6 {
            const bits: u7 = if (n <= 2) 1 else @intCast(64 - @clz(n - 1));
            return @intCast(64 - @as(u7, bits));
        }

        inline fn sizeOf(size_index: u6) usize {
            return @as(usize, 1) << @intCast(64 - @as(u7, size_index));
        }

        /// `size_index_for`: n/NL+1 == ceil((n+1)/NL), +1 for the sentinel.
        inline fn sizeIndexFor(n: usize) u6 {
            return sizeIndex(@max(n / NL + 1, min_groups));
        }

        fn capacityFor(n: usize) usize {
            return sizeOf(sizeIndexFor(n)) * NL - 1;
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

            /// The slot `i`, bounds-tested when `checked`.
            inline fn slot(a: Arrays, i: usize) *Element {
                if (options.checked and i >= slotsFor(a.groups_size_mask + 1)) outOfBounds();
                return &a.elements[i];
            }
        };

        /// Combined space for elements and groups, in bytes, a whole
        /// number of elements (`buffer_size` * sizeof(value_type)).
        fn bufferBytes(groups_size: usize) usize {
            const bytes = @sizeOf(Element) * slotsFor(groups_size) + @sizeOf(Group) * (groups_size + 1) - 1;
            return (bytes + @sizeOf(Element) - 1) / @sizeOf(Element) * @sizeOf(Element);
        }

        /// `table_arrays::new_` for n > 0: elements, then the groups at the
        /// next 16-byte boundary after the element slots.
        fn newArrays(gpa: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Arrays {
            const size_index = sizeIndexFor(n);
            const groups_size = sizeOf(size_index);
            const buf = try gpa.alignedAlloc(u8, .of(Element), bufferBytes(groups_size));
            const elements: [*]Element = @ptrCast(buf.ptr);
            var p: usize = @intFromPtr(elements + slotsFor(groups_size));
            p += (@sizeOf(Group) -% p) % @sizeOf(Group);
            const groups: [*]Group = @ptrFromInt(p);
            @memset(@as([*]u8, @ptrCast(groups))[0 .. groups_size * @sizeOf(Group)], 0);
            groups[groups_size - 1].m[NL - 1] = sentinel_;
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
            return if (self.elements != null) (self.groups_size_mask + 1) * NL - 1 else 0;
        }

        fn initialMaxLoad(self: *const Self) usize {
            const small_capacity = 2 * NL - 1;
            const c = self.capacity();
            if (c <= small_capacity) return c; // 100% usage
            return @intFromFloat(max_load * @as(f32, @floatFromInt(c)));
        }

        /// BOOST_UNORDERED_PREFETCH_ELEMENTS: the first line on x86, the
        /// first half of the group's slots on ARM.
        inline fn prefetchBoost(p: [*]const Element) void {
            if (builtin.cpu.arch.isArm() or builtin.cpu.arch.isAARCH64()) {
                const cache_line = 64;
                var p0: [*]const u8 = @ptrCast(p);
                const p1 = p0 + @sizeOf(Element) * NL / 2;
                while (@intFromPtr(p0) < @intFromPtr(p1)) : (p0 += cache_line)
                    @prefetch(p0, .{ .rw = .read, .locality = 3, .cache = .data });
            } else {
                @prefetch(p, .{ .rw = .read, .locality = 3, .cache = .data });
            }
        }

        /// The home group's first slots, or the home lane's, from the hash
        /// alone.
        inline fn prefetchHome(self: *const Self, pos: usize, lane: u32) void {
            if (prefetch != .first and prefetch != .two and prefetch != .home) return;
            if (self.groups_size_mask + 1 < options.prefetch_min_groups) return;
            const p: [*]const u8 = @ptrCast(self.elements.? + pos * S + if (prefetch == .home) lane else 0);
            @prefetch(p, .{ .rw = .read, .locality = 3, .cache = .data });
            if (prefetch == .two) @prefetch(p + 64, .{ .rw = .read, .locality = 3, .cache = .data });
        }

        inline fn arrays(self: *const Self) Arrays {
            return .{
                .groups_size_index = self.groups_size_index,
                .groups_size_mask = self.groups_size_mask,
                .groups = self.groups,
                .elements = self.elements.?,
            };
        }

        /// table_locator
        const Locator = struct {
            pg: *Group,
            n: u32,
            p: *Element,
        };

        inline fn keyMatches(e: *const Element, k: K, hash: u64) bool {
            if (int_key and @sizeOf(Element) <= 16) {
                // The whole slot in one load (`ldp`), so a hit reads its
                // value from the same load.
                const s = e.*;
                return s.key == k;
            }
            if (store_hash and options.hash_compare and e.hash != hash) return false;
            return eql(k, e.key);
        }

        /// The fewest groups for which the `matched` prefetches run: slot
        /// arrays of `prefetch_min_bytes`.
        const matched_min_groups: usize = @max(1, options.prefetch_min_bytes / (S * @sizeOf(Element)));

        inline fn prefetchMatched(a: Arrays, pos: usize, step: usize, lane: u32) void {
            if (prefetch == .boost) prefetchBoost(a.elements + pos * S);
            // A test of the table's size, the same for every lookup in a
            // loop, so the compiler can take it out of the loop.
            if (a.groups_size_mask + 1 < matched_min_groups) return;
            if (prefetch == .matched or prefetch == .matched_home or prefetch == .matched2 or prefetch == .matched_span) {
                const off = if (prefetch == .matched_home and step == 0) lane else 0;
                const q: [*]const u8 = @ptrCast(a.elements + pos * S + off);
                @prefetch(q, .{ .rw = .read, .locality = 3, .cache = .data });
                if (prefetch == .matched2) @prefetch(q + 64, .{ .rw = .read, .locality = 3, .cache = .data });
                if (prefetch == .matched_span) @prefetch(q + (NL * @sizeOf(Element) - 1), .{ .rw = .read, .locality = 3, .cache = .data });
            }
        }

        /// The lookup with its home group peeled: a hit in its home group's
        /// first matching lane takes no loop, and a miss there takes one
        /// test more. The other lanes and groups are out of line.
        inline fn find(self: *const Self, k: K, hash: u64) ?Locator {
            if (!options.peel) return self.findLoop(k, hash);
            const h = home(hash, self.groups_size_index, self.groups_size_mask);
            if (self.elements != null) self.prefetchHome(h.pos, h.lane);
            // On x86 the home group's byte offset comes from the hash in one
            // shift and a mask, and the slots' from it by one multiply.
            const goff: usize = if (byte_home)
                @intCast((std.math.rotl(u64, hash, 8) >> (self.groups_size_index - @ctz(@as(u32, @sizeOf(Group))))) & ~@as(u64, @sizeOf(Group) - 1))
            else
                h.pos * @sizeOf(Group);
            const pg: *Group = @ptrFromInt(@intFromPtr(self.groups) + goff);
            var mask = matchTag(load(pg), h.vtag);
            if (mask != 0) {
                const a = self.arrays();
                if (byte_home) {
                    const base: [*]u8 = @as([*]u8, @ptrCast(a.elements)) + goff * (S * @sizeOf(Element) / @sizeOf(Group));
                    if (prefetch == .matched) @prefetch(base, .{ .rw = .read, .locality = 3, .cache = .data });
                    const p: *Element = @ptrCast(@alignCast(base + @as(usize, @ctz(mask)) * @sizeOf(Element)));
                    if (keyMatches(p, k, hash)) {
                        @branchHint(.likely);
                        return .{ .pg = pg, .n = M.lane(mask), .p = p };
                    }
                    mask &= mask - 1;
                    if (mask != 0) {
                        if (@call(slow_call, findLanes, .{ a, pg, goff / @sizeOf(Group), mask, k, hash })) |loc| return loc;
                    }
                    if (classClear(pg, h.class)) {
                        @branchHint(.likely);
                        return null;
                    }
                    return @call(slow_call, findRest, .{ self, k, hash });
                }
                prefetchMatched(a, h.pos, 0, h.lane);
                const p = slotOf(a, h.pos, mask);
                if (keyMatches(p, k, hash)) {
                    @branchHint(.likely);
                    return .{ .pg = pg, .n = M.lane(mask), .p = p };
                }
                mask &= mask - 1;
                if (mask != 0) {
                    if (@call(slow_call, findLanes, .{ a, pg, h.pos, mask, k, hash })) |loc| return loc;
                }
            }
            if (classClear(pg, h.class)) {
                @branchHint(.likely);
                return null;
            }
            return @call(slow_call, findRest, .{ self, k, hash });
        }

        const slow_call: std.builtin.CallModifier = if (options.peel_inline) .always_inline else .never_inline;

        /// The home group's other matching lanes.
        fn findLanes(a: Arrays, pg: *Group, pos: usize, mask_: Mask, k: K, hash: u64) ?Locator {
            var mask = mask_;
            while (mask != 0) : (mask &= mask - 1) {
                const p = slotOf(a, pos, mask);
                if (keyMatches(p, k, hash)) return .{ .pg = pg, .n = M.lane(mask), .p = p };
            }
            return null;
        }

        /// The groups after the home group. It makes the home again from the
        /// hash, so the hot path keeps nothing for it.
        fn findRest(self: *const Self, k: K, hash: u64) ?Locator {
            const h = home(hash, self.groups_size_index, self.groups_size_mask);
            var pb: Prober = .{ .pos = h.pos };
            while (pb.next(self.groups_size_mask)) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                var mask = matchTag(load(pg), h.vtag);
                if (mask != 0) {
                    const a = self.arrays();
                    while (mask != 0) : (mask &= mask - 1) {
                        const p = slotOf(a, pos, mask);
                        if (keyMatches(p, k, hash)) return .{ .pg = pg, .n = M.lane(mask), .p = p };
                    }
                }
                if (classClear(pg, h.class)) return null;
            }
            return null;
        }

        inline fn findLoop(self: *const Self, k: K, hash: u64) ?Locator {
            const h = home(hash, self.groups_size_index, self.groups_size_mask);
            if (self.elements != null) self.prefetchHome(h.pos, h.lane);
            if (options.home_lane and options.first_probe) {
                // The home lane first: a predicted branch, so the slot loads
                // while the tag is still on its way.
                const pg = &self.groups[h.pos];
                if (pg.m[h.lane] == h.tag) {
                    const p = self.arrays().slot(h.pos * S + h.lane);
                    if (keyMatches(p, k, hash)) return .{ .pg = pg, .n = h.lane, .p = p };
                }
            }
            var pb: Prober = .{ .pos = h.pos };
            while (true) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                var mask = matchTag(load(pg), h.vtag);
                if (mask != 0) {
                    const a = self.arrays();
                    if (prefetch == .boost) prefetchBoost(a.elements + pos * S);
                    if (prefetch == .matched or prefetch == .matched_home or prefetch == .matched2) {
                        const off = if (prefetch == .matched_home and pb.step == 0) h.lane else 0;
                        const q: [*]const u8 = @ptrCast(a.elements + pos * S + off);
                        @prefetch(q, .{ .rw = .read, .locality = 3, .cache = .data });
                        if (prefetch == .matched2) @prefetch(q + 64, .{ .rw = .read, .locality = 3, .cache = .data });
                    }
                    while (true) {
                        const n = M.lane(mask);
                        const p = slotOf(a, pos, mask);
                        if (keyMatches(p, k, hash)) {
                            @branchHint(.likely);
                            return .{ .pg = pg, .n = n, .p = p };
                        }
                        mask &= mask - 1;
                        if (mask == 0) break;
                    }
                }
                if (classClear(pg, h.class)) {
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
            return self.find(k, hashFor(k));
        }

        /// The slot of group `pos` at `mask`'s first lane. With nibble or byte
        /// masks and 16-byte slots its byte offset is `ctz << 2` (or `<< 1`),
        /// one shift folded into the address.
        inline fn slotOf(a: Arrays, pos: usize, mask: Mask) *Element {
            if (M.step > 1 and @sizeOf(Element) == 16 and (!options.checked or options.checked_fold)) {
                if (options.checked and pos * S + M.lane(mask) >= slotsFor(a.groups_size_mask + 1)) outOfBounds();
                // ctz is `step` times the lane: the offset is ctz * 16 / step.
                const base: [*]u8 = @ptrCast(a.elements + pos * S);
                return @ptrCast(@alignCast(base + (@as(usize, @ctz(mask)) << (4 - @ctz(@as(u32, M.step))))));
            }
            return a.slot(pos * S + M.lane(mask));
        }

        inline fn place(a: Arrays, pg: *Group, pos: usize, n: u32, tag: u8, hash: u64, k: K, v: V) void {
            const p = a.slot(pos * S + n);
            p.* = if (store_hash) .{ .key = k, .value = v, .hash = hash } else .{ .key = k, .value = v };
            setTag(pg, n, tag);
        }

        /// `nosize_unchecked_emplace_at`: from the probe `pb`, the first
        /// group with a free lane, marking each full one passed.
        inline fn emplaceFrom(a: Arrays, pb_: Prober, tag: u8, lane: u32, hash: u64, k: K, v: V) void {
            var pb = pb_;
            while (true) : (_ = pb.next(a.groups_size_mask)) {
                const pg = &a.groups[pb.pos];
                const mask = matchAvailable(pg);
                if (mask != 0) {
                    @branchHint(.likely);
                    place(a, pg, pb.pos, pickLane(mask, pb.step == 0, lane), tag, hash, k, v);
                    return;
                } else markOverflow(pg, tag);
            }
        }

        /// The free lane an insert takes: the home lane in the home group
        /// when it is free, else the first.
        inline fn pickLane(free: Mask, home_group: bool, lane: u32) u32 {
            if (options.home_lane and home_group and free & M.laneBit(lane) != 0) return lane;
            return M.lane(free);
        }

        inline fn emplace(a: Arrays, hash: u64, k: K, v: V) void {
            const h = home(hash, a.groups_size_index, a.groups_size_mask);
            emplaceFrom(a, .{ .pos = h.pos }, h.tag, h.lane, hash, k, v);
        }

        /// `new_arrays_for_growth`: ceil((size + size/61 + 1) / mlf) slots,
        /// or, when drift lowered the maximum load, enough slots for the
        /// size to fill at most `drift_fill` of them.
        fn newArraysForGrowth(self: *const Self, gpa: std.mem.Allocator) !Arrays {
            const s = self.size;
            var n: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(s + s / 61 + 1)) / max_load));
            if (self.elements != null and self.ml < self.initialMaxLoad()) {
                const d: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(s + 1)) / drift_fill));
                n = @max(n, d);
            }
            return newArrays(gpa, n);
        }

        /// `unchecked_rehash(new_arrays_)`: every element placed with no
        /// compare, by its stored hash or hashed again.
        fn uncheckedRehash(self: *Self, gpa: std.mem.Allocator, new: Arrays) void {
            if (self.elements) |elements| {
                const ngroups = self.groups_size_mask + 1;
                const last = ngroups - 1;
                var g: usize = 0;
                while (g < ngroups) : (g += 1) {
                    if (!store_hash and text_key and options.rehash_prefetch and g + 1 < ngroups) {
                        var ahead = self.matchReallyOccupied(g + 1, last);
                        const q = elements + (g + 1) * S;
                        while (ahead != 0) : (ahead &= ahead - 1)
                            @prefetch(q[M.lane(ahead)].key.ptr, .{ .rw = .read, .locality = 3, .cache = .data });
                    }
                    var mask = self.matchReallyOccupied(g, last);
                    const p = elements + g * S;
                    while (mask != 0) : (mask &= mask - 1) {
                        const e = &p[M.lane(mask)];
                        const hash = if (store_hash) e.hash else hashFor(e.key);
                        emplace(new, hash, e.key, e.value);
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
            emplace(new, hash, k, v);
            self.uncheckedRehash(gpa, new);
            self.size += 1;
        }

        /// `match_really_occupied`: excluding the sentinel.
        inline fn matchReallyOccupied(self: *const Self, g: usize, last: usize) Mask {
            const s: Mask = if (g == last) M.laneBit(NL - 1) else 0;
            return matchOccupied(&self.groups[g]) & ~s;
        }

        /// `recover_slot`, with the anti-drift decrement of the max load.
        inline fn recoverSlot(self: *Self, pg: *Group, n: u32) void {
            self.ml -= @intFromBool(maybeCausedOverflow(pg, n));
            setTag(pg, n, 0);
            self.size -= 1;
        }

        // ---- the API -------------------------------------------------------

        /// Inserts `k` or overwrites its value: `insert_or_assign`.
        pub fn put(self: *Self, gpa: std.mem.Allocator, k: K, v: V) !void {
            const hash = hashFor(k);
            if (!options.one_pass) {
                if (self.find(k, hash)) |loc| {
                    loc.p.value = v;
                    return;
                }
                if (self.size < self.ml) {
                    @branchHint(.likely);
                    emplace(self.arrays(), hash, k, v);
                    self.size += 1;
                } else {
                    try self.emplaceWithRehash(gpa, hash, k, v);
                }
                return;
            }
            // One pass: the find remembers the first group with a free lane.
            const h = home(hash, self.groups_size_index, self.groups_size_mask);
            var pb: Prober = .{ .pos = h.pos };
            var free_pg: ?*Group = null;
            var free_pos: usize = 0;
            var free_lane: u32 = 0;
            while (true) {
                const pos = pb.pos;
                const pg = &self.groups[pos];
                const vec = load(pg);
                var mask = matchTag(vec, h.vtag);
                while (mask != 0) : (mask &= mask - 1) {
                    const p = slotOf(self.arrays(), pos, mask);
                    if (keyMatches(p, k, hash)) {
                        p.value = v;
                        return;
                    }
                }
                if (free_pg == null) {
                    const f = matchFree(vec);
                    if (f != 0) {
                        free_pg = pg;
                        free_pos = pos;
                        free_lane = pickLane(f, pb.step == 0, h.lane);
                    }
                }
                if (classClear(pg, h.class)) break;
                if (!pb.next(self.groups_size_mask)) break;
            }
            if (self.size >= self.ml) {
                @branchHint(.unlikely);
                return self.emplaceWithRehash(gpa, hash, k, v);
            }
            const a = self.arrays();
            if (free_pg) |pg| {
                @branchHint(.likely);
                place(a, pg, free_pos, free_lane, h.tag, hash, k, v);
            } else {
                // Every group the find passed is full: the one it stopped at
                // overflows now, and the probe goes on to a free lane.
                markOverflow(&a.groups[pb.pos], h.tag);
                _ = pb.next(a.groups_size_mask);
                emplaceFrom(a, pb, h.tag, h.lane, hash, k, v);
            }
            self.size += 1;
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
            const kv: KV = .{ .key = loc.p.key, .value = loc.p.value };
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
                    const s: Mask = if (it.g == it.ngroups - 1) M.laneBit(NL - 1) else 0;
                    it.mask = matchOccupied(&it.groups[it.g]) & ~s;
                }
                const n = M.lane(it.mask);
                it.mask &= it.mask - 1;
                const i = it.g * S + n;
                if (options.checked and i >= slotsFor(it.ngroups)) outOfBounds();
                const e = &it.elements[i];
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

/// The key of step `i`: `i` itself, or scattered by splitmix64, since a
/// table that hashes integers by one multiply spreads consecutive keys so
/// evenly that nothing overflows and nothing drifts.
fn churnKey(comptime scatter: bool, i: i64) i64 {
    if (!scatter) return i;
    var z: u64 = (@as(u64, @bitCast(i)) +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return @bitCast(z ^ (z >> 31));
}

fn churn(comptime Map: type) !void {
    return churnWith(Map, false);
}

fn churnWith(comptime Map: type, comptime scatter: bool) !void {
    const gpa = testing.allocator;
    var m: Map = .empty;
    defer m.deinit(gpa);
    const size = 13_400; // near the max load of 13,439 in 15,359 slots
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, churnKey(scatter, i), i);
    const cap = m.capacity();
    var lo: i64 = 0;
    var hi: i64 = size;
    var rehashes: usize = 0;
    var last_ml = m.ml;
    for (0..2_000_000) |_| {
        try testing.expectEqual(lo, m.fetchRemove(churnKey(scatter, lo)).?.value);
        lo += 1;
        try m.put(gpa, churnKey(scatter, hi), hi);
        hi += 1;
        if (m.ml > last_ml) rehashes += 1;
        last_ml = m.ml;
        try testing.expectEqual(@as(usize, size), m.count());
    }
    // The table never grows past one doubling at a fixed size.
    try testing.expect(m.capacity() <= 2 * cap + 1);
    var k = lo;
    while (k < hi) : (k += 1) try testing.expectEqual(k, m.get(churnKey(scatter, k)).?);
    try testing.expect(!m.contains(churnKey(scatter, lo - 1)));
    try testing.expect(rehashes > 0); // drift forced rehashes
}

test "churn at a fixed size" {
    try churn(HashMapWith(i64, i64, IntCtx, .{ .int_mul = false }));
    try churn(HashMapWith(i64, i64, CrowdedCtx, .{ .int_mul = false }));
    try churnWith(HashMap(i64, i64, IntCtx), true);
}

test "growth through several doublings" {
    const gpa = testing.allocator;
    var m: HashMapWith(i64, [8]i64, IntCtx, .{ .group8 = false }) = .empty;
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
    var m: HashMapWith(i64, i64, IntCtx, .{ .group8 = false }) = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 29) : (i += 1) try m.put(gpa, i, i);
    try testing.expectEqual(@as(usize, 29), m.capacity());
    try m.put(gpa, 29, 29);
    try testing.expectEqual(@as(usize, 59), m.capacity());
}

test "the Context's hashes, crowded home groups, one pass and two" {
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .int_mul = false }), 300_000, 20_000, 6);
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .int_mul = false, .one_pass = false }), 300_000, 20_000, 7);
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .int_mul = false, .nibble_mask = false }), 300_000, 20_000, 8);
    try churn(HashMapWith(i64, i64, CrowdedCtx, .{ .int_mul = false }));
}

test "Rig-shaped: bounds tests on slot indexes" {
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .checked = true }), 300_000, 20_000, 9);
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .checked = true, .int_mul = false }), 300_000, 20_000, 10);
    try churnWith(HashMapWith(i64, i64, IntCtx, .{ .checked = true }), true);
}

test "every prefetch policy" {
    inline for (.{ Prefetch.none, Prefetch.boost, Prefetch.first, Prefetch.two, Prefetch.matched, Prefetch.matched2 }) |p|
        try randomOps(HashMapWith(i64, i64, IntCtx, .{ .prefetch = p, .prefetch_min_groups = 2 }), 100_000, 20_000, 11);
}

test "a drift-forced rehash near full load doubles the table" {
    const gpa = testing.allocator;
    var m: HashMapWith(i64, i64, IntCtx, .{ .group8 = false }) = .empty;
    defer m.deinit(gpa);
    // 100,000 keys fill 8,192 groups to 0.81.
    var i: i64 = 0;
    while (i < 100_000) : (i += 1) try m.put(gpa, churnKey(true, i), i);
    const cap = m.capacity();
    var lo: i64 = 0;
    var hi: i64 = 100_000;
    var same_size: usize = 0;
    var last_ml = m.ml;
    for (0..1_000_000) |_| {
        _ = m.fetchRemove(churnKey(true, lo)).?;
        lo += 1;
        try m.put(gpa, churnKey(true, hi), hi);
        hi += 1;
        if (m.ml > last_ml and m.capacity() == cap) same_size += 1;
        last_ml = m.ml;
    }
    try testing.expect(m.capacity() > cap);
    try testing.expectEqual(@as(usize, 0), same_size);
}

test "text keys of every length up to 80 bytes" {
    const gpa = testing.allocator;
    var m: HashMap([]const u8, i64, TextCtx) = .empty;
    defer m.deinit(gpa);
    const text = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz";
    var n: usize = 0;
    while (n <= 80) : (n += 1) try m.put(gpa, text[0..n], @intCast(n));
    try testing.expectEqual(@as(usize, 81), m.count());
    var buf: [96]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    n = 0;
    while (n <= 80) : (n += 1) {
        try testing.expectEqual(@as(i64, @intCast(n)), m.get(buf[0..n]).?);
        // One byte changed anywhere misses.
        var j: usize = 0;
        while (j < n) : (j += 1) {
            buf[j] ^= 0x20;
            try testing.expect(m.get(buf[0..n]) == null);
            buf[j] ^= 0x20;
        }
    }
}

test "stride 16, home lanes" {
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .stride16 = true }), 300_000, 20_000, 12);
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .home_lane = true, .first_probe = true, .prefetch = .home, .prefetch_min_groups = 2 }), 300_000, 20_000, 13);
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .home_lane = true, .prefetch = .matched_home }), 300_000, 20_000, 15);
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .home_lane = true, .stride16 = true, .int_mul = false, .checked = true }), 300_000, 20_000, 14);
    try churnWith(HashMapWith(i64, i64, IntCtx, .{ .home_lane = true, .stride16 = true }), true);
}

test "every tag layout, and text keys without a stored hash" {
    inline for (.{ .below, .low, .top, .rot }) |b| {
        try randomOps(HashMapWith(i64, i64, IntCtx, .{ .tag_bits = b }), 200_000, 20_000, 16);
        try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .tag_bits = b, .int_mul = false }), 200_000, 20_000, 17);
    }
    const gpa = testing.allocator;
    var m: HashMapWith([]const u8, i64, TextCtx, .{ .store_hash = false }) = .empty;
    defer m.deinit(gpa);
    var bufs: [3000][8]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        _ = std.fmt.bufPrint(b, "{d:0>8}", .{i}) catch unreachable;
        try m.put(gpa, b, @intCast(i));
    }
    for (&bufs, 0..) |*b, i| try testing.expectEqual(@as(i64, @intCast(i)), m.get(b).?);
}

test "groups of 7" {
    const G8 = HashMapWith(i64, i64, IntCtx, .{ .group8 = true, .min_groups = 2, .max_load = 0.875 });
    try randomOps(G8, 300_000, 20_000, 18);
    try randomOps(HashMapWith(i64, i64, CrowdedCtx, .{ .group8 = true, .int_mul = false, .checked = true }), 300_000, 20_000, 19);
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .group8 = true, .nibble_mask = false }), 100_000, 20_000, 20);
    try churnWith(G8, true);
    const gpa = testing.allocator;
    var m: G8 = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 13) : (i += 1) try m.put(gpa, i, i);
    try testing.expectEqual(@as(usize, 13), m.capacity());
    try m.put(gpa, 13, 13);
    try testing.expect(m.capacity() > 13);
    var sm: HashMapWith([]const u8, i64, TextCtx, .{ .group8 = true }) = .empty;
    defer sm.deinit(gpa);
    try sm.put(gpa, "a", 1);
    try sm.put(gpa, "bb", 2);
    try testing.expectEqual(@as(i64, 2), sm.get("bb").?);
    try testing.expect(sm.get("c") == null);
}

test "both layouts, by default and pinned" {
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .group8 = false }), 200_000, 20_000, 21);
    try randomOps(HashMapWith(i64, i64, IntCtx, .{ .group8 = true }), 200_000, 20_000, 22);
    try churnWith(HashMapWith(i64, i64, IntCtx, .{ .group8 = true }), true);
    const gpa = testing.allocator;
    var m: HashMapWith(i64, i64, IntCtx, .{ .group8 = true }) = .empty;
    defer m.deinit(gpa);
    try m.put(gpa, 1, 1);
    try testing.expectEqual(@as(usize, 27), m.capacity());
}
