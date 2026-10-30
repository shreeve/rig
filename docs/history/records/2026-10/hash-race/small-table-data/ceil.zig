//! The Zig ceiling for HashMap's count loop on small tables (knucleotide's
//! k = 1, 2, 4). The table is src/unordered.zig's arm64 layout (groups of
//! 7 slots and an 8-byte metadata word whose last byte is the overflow
//! byte; tag 0 free, 1 sentinel; rotl-8 hash, top byte the tag; quadratic
//! probe over groups; 4 groups at least; maximum load 0.8), with each of
//! Rig's extras behind a switch.
const std = @import("std");

pub const Cfg = struct {
    /// The table's header lives in a stack object whose address a
    /// noinline call (grow, drop) takes, as Rig emits today; false: every
    /// out-of-line call takes the header by value and hands it back, so
    /// the header stays in registers.
    escape: bool = true,
    /// The tag from a 256-byte table (`reduced_table`), as Rig does; false:
    /// `t | 0x80`, one instruction, the class still `t & 7`.
    tag_table: bool = true,
    /// HashMap.ensure's `@len = @t.count()`, every count.
    len_store: bool = true,
    /// ensure hands back a slot index and `value_mut` makes the address
    /// again; false: it hands back the value's address.
    index_trip: bool = true,
    /// ensure goes straight to `claim`'s probe, which keeps the first
    /// free lane as it goes; false: a peeled home-group hit first.
    claim_first: bool = true,
    /// The key mixed (`code ^ code << 32`), knucleotide's S1 workaround.
    mix: bool = true,
    /// A `rig.turn` tick each count, as in a program that makes tasks.
    tick: bool = false,
    /// The hash: Rig's one multiply, or foldhash's folded multiply
    /// (hashbrown's default), for comparison.
    fold_hash: bool = false,
};

const W = 8;
const NL = 7;
const Group = extern struct { m: [W]u8 align(W) };
const VW = @Vector(W, u8);
const sentinel = 1;
const slot_lanes: u64 = 0x0001010101010101;
const int_mul: u64 = 0x4b33a62ed433d4a3;
const min_groups = 4;

var dummy: [2]Group = blk: {
    var g: Group = .{ .m = @splat(0) };
    g.m[W - 2] = sentinel;
    break :blk .{ g, g };
};

const reduced_table: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = switch (i) {
        0 => 8,
        1 => 9,
        else => i,
    };
    break :blk t;
};
const shift_table = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

const Elem = struct { key: u64, value: u32 };

inline fn reduceEq(eq: @Vector(W, bool)) u64 {
    const bytes: @Vector(8, u8) = @select(u8, eq, @as(@Vector(8, u8), @splat(0xFF)), @as(@Vector(8, u8), @splat(0)));
    return @bitCast(bytes);
}
inline fn matchTag(v: VW, tag: VW) u64 {
    return reduceEq(v == tag) & slot_lanes;
}
inline fn matchFree(v: VW) u64 {
    return reduceEq(v == @as(VW, @splat(0))) & slot_lanes;
}
inline fn matchFull(pg: *const Group) u64 {
    return reduceEq(pg.m > @as(VW, @splat(sentinel))) & slot_lanes;
}
inline fn laneOf(m: u64) usize {
    return @as(usize, @ctz(m)) >> 3;
}
inline fn classClear(pg: *const Group, class: u3) bool {
    const o: *const volatile u8 = &pg.m[W - 1];
    return o.* & shift_table[class] == 0;
}
inline fn markOverflow(pg: *Group, tag: u8) void {
    pg.m[W - 1] |= @as(u8, 1) << @as(u3, @truncate(tag));
}
inline fn slotOf(es: [*]Elem, pos: usize, m: u64) *Elem {
    const base: [*]u8 = @ptrCast(es + pos * NL);
    return @ptrCast(@alignCast(base + (@as(usize, @ctz(m)) << 1)));
}

pub var tick_sink: u64 = 0;
noinline fn tickSlow() void {
    @as(*volatile u64, &tick_sink).* += 1;
}

pub fn Main(comptime cfg: Cfg) type {
    return struct {
        const Table = struct {
            groups: [*]Group = &dummy,
            elements: ?[*]Elem = null,
            mask: usize = 1,
            ml: usize = 0,
            size: usize = 0,
            shift: u8 = 63,
        };
        const HashMap = struct {
            len: i64 = 0,
            t: Table = .{},
        };

        const Home = struct { pos: usize, tag: u8, vtag: VW, class: u3 };

        inline fn hashKey(k: u64) u64 {
            if (cfg.fold_hash) {
                const p = @as(u128, k ^ 0x13198a2e03707344) * 0xa4093822299f31d0;
                return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
            }
            return k *% int_mul;
        }

        inline fn homeOf(hash: u64, shift: u8) Home {
            const t = std.math.rotl(u64, hash, 8);
            const b: u8 = @truncate(t);
            const tag: u8 = if (cfg.tag_table) reduced_table[b] else b | 0x80;
            return .{ .pos = @intCast(t >> @intCast(shift)), .tag = tag, .vtag = @splat(tag), .class = @truncate(t) };
        }

        const Prober = struct {
            pos: usize,
            step: usize = 0,
            inline fn next(pb: *Prober, mask: usize) bool {
                pb.step += 1;
                pb.pos = (pb.pos + pb.step) & mask;
                return pb.step <= mask;
            }
        };

        fn newTable(groups: usize) Table {
            const slots = groups * NL - 1;
            const bytes = @sizeOf(Elem) * slots + @sizeOf(Group) * (groups + 1);
            const block = std.heap.page_allocator.alignedAlloc(u8, .@"16", bytes) catch @panic("oom");
            const es: [*]Elem = @ptrCast(@alignCast(block.ptr));
            var p: usize = @intFromPtr(block.ptr) + @sizeOf(Elem) * slots;
            p += (@sizeOf(Group) -% p) % @sizeOf(Group);
            const gs: [*]Group = @ptrFromInt(p);
            @memset(@as([*]u8, @ptrCast(gs))[0 .. groups * W], 0);
            gs[groups - 1].m[NL - 1] = sentinel;
            const c = slots;
            return .{
                .groups = gs,
                .elements = es,
                .mask = groups - 1,
                .ml = if (c <= 2 * NL - 1) c else c * 4 / 5,
                .size = 0,
                .shift = @intCast(@as(u32, 64) - std.math.log2_int(usize, groups)),
            };
        }

        inline fn emplace(t: *Table, hash: u64) usize {
            const h = homeOf(hash, t.shift);
            var pb: Prober = .{ .pos = h.pos };
            while (true) : (_ = pb.next(t.mask)) {
                const pg = &t.groups[pb.pos];
                const free = matchFree(pg.m);
                if (free != 0) {
                    const lane = laneOf(free);
                    pg.m[lane] = h.tag;
                    return pb.pos * NL + lane;
                } else markOverflow(pg, h.tag);
            }
        }

        /// The old table's entries moved into one twice its groups.
        fn grown(old: Table) Table {
            var t = newTable(if (old.elements == null) min_groups else (old.mask + 1) * 2);
            if (old.elements) |es| {
                for (0..old.mask + 1) |g| {
                    var m = matchFull(&old.groups[g]);
                    while (m != 0) : (m &= m - 1) {
                        const e = &es[g * NL + laneOf(m)];
                        t.elements.?[emplace(&t, hashKey(e.key))] = e.*;
                        t.size += 1;
                    }
                }
            }
            return t;
        }

        /// Rig's: the header by pointer, which escapes.
        noinline fn claimGrownPtr(t: *Table, hash: u64) usize {
            t.* = grown(t.*);
            t.size += 1;
            return emplace(t, hash);
        }

        /// The header by value, handed back.
        const GrowR = struct { t: Table, i: usize };
        noinline fn claimGrownVal(t0: Table, hash: u64) GrowR {
            var t = grown(t0);
            t.size += 1;
            const i = emplace(&t, hash);
            return .{ .t = t, .i = i };
        }

        noinline fn dropPtr(t: *Table) void {
            if (t.elements) |es| {
                const groups = t.mask + 1;
                const slots = groups * NL - 1;
                const bytes = @sizeOf(Elem) * slots + @sizeOf(Group) * (groups + 1);
                std.heap.page_allocator.free(@as([*]align(16) u8, @ptrCast(@alignCast(es)))[0..bytes]);
            }
            t.* = .{};
        }
        noinline fn dropVal(t: Table) void {
            var tt = t;
            dropPtr(&tt);
        }

        const Claim = struct { i: usize, p: *Elem, new: bool };

        /// unordered.zig's `claim`, with the grow by pointer or by value.
        inline fn claim(t: *Table, k: u64, hash: u64) Claim {
            const h = homeOf(hash, t.shift);
            var pb: Prober = .{ .pos = h.pos };
            var free_pg: ?*Group = null;
            var free_pos: usize = 0;
            var free_lane: usize = 0;
            while (true) {
                const pos = pb.pos;
                const pg = &t.groups[pos];
                const vec = pg.m;
                var m = matchTag(vec, h.vtag);
                while (m != 0) : (m &= m - 1) {
                    const p = slotOf(t.elements.?, pos, m);
                    if (p.key == k) return .{ .i = (@intFromPtr(p) - @intFromPtr(t.elements.?)) / @sizeOf(Elem), .p = p, .new = false };
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
                if (!pb.next(t.mask)) break;
            }
            var i: usize = undefined;
            if (t.size >= t.ml) {
                @branchHint(.unlikely);
                if (cfg.escape) {
                    i = claimGrownPtr(t, hash);
                } else {
                    const r = claimGrownVal(t.*, hash);
                    t.* = r.t;
                    i = r.i;
                }
            } else {
                t.size += 1;
                if (free_pg) |pg| {
                    @branchHint(.likely);
                    pg.m[free_lane] = h.tag;
                    i = free_pos * NL + free_lane;
                } else {
                    markOverflow(&t.groups[pb.pos], h.tag);
                    _ = pb.next(t.mask);
                    i = emplace(t, hash); // a rare path; the ceiling does not time it
                }
            }
            t.elements.?[i] = .{ .key = k, .value = 0 };
            return .{ .i = i, .p = &t.elements.?[i], .new = true };
        }

        inline fn ensure(m: *HashMap, k: u64) *u32 {
            const hash = hashKey(k);
            const p: *Elem = blk: {
                if (!cfg.claim_first) {
                    const h = homeOf(hash, m.t.shift);
                    const pg = &m.t.groups[h.pos];
                    var mm = matchTag(pg.m, h.vtag);
                    if (mm != 0) {
                        const es = m.t.elements.?;
                        const p = slotOf(es, h.pos, mm);
                        if (p.key == k) {
                            @branchHint(.likely);
                            break :blk p;
                        }
                        mm &= mm - 1;
                        while (mm != 0) : (mm &= mm - 1) {
                            const q = slotOf(es, h.pos, mm);
                            if (q.key == k) break :blk q;
                        }
                    }
                }
                const c = claim(&m.t, k, hash);
                if (cfg.index_trip) {
                    const j: i64 = @intCast(c.i);
                    break :blk &m.t.elements.?[@intCast(j)];
                }
                break :blk c.p;
            };
            if (cfg.len_store) m.len = @intCast(m.t.size);
            return &p.value;
        }

        inline fn frequencies(seq: []const u8, comptime k: u6) HashMap {
            var counts: HashMap = .{};
            var alive = true;
            defer if (alive) {
                if (cfg.escape) dropPtr(&counts.t) else dropVal(counts.t);
            };
            const mask: u64 = (@as(u64, 1) << (2 * k)) - 1;
            var code: u64 = 0;
            var turns: u32 = 1024;
            for (seq, 0..) |b, i| body: {
                code = ((code << 2) | b) & mask;
                if (i + 1 < k) break :body;
                const key = if (cfg.mix) code ^ (code << 32) else code;
                ensure(&counts, key).* += 1;
                if (cfg.tick) {
                    turns -%= 1;
                    if (turns == 0) {
                        @branchHint(.unlikely);
                        turns = 1024;
                        tickSlow();
                    }
                }
            }
            alive = false;
            return counts;
        }

        fn sum(m: *const HashMap) u64 {
            var s: u64 = 0;
            const es = m.t.elements orelse return 0;
            for (0..m.t.mask + 1) |g| {
                var mm = matchFull(&m.t.groups[g]);
                while (mm != 0) : (mm &= mm - 1) {
                    const e = es[g * NL + laneOf(mm)];
                    s +%= e.value *% (e.key | 1);
                }
            }
            return s;
        }

        /// Keys not in their home group.
        fn displaced(m: *const HashMap) usize {
            var n: usize = 0;
            const es = m.t.elements orelse return 0;
            for (0..m.t.mask + 1) |g| {
                var mm = matchFull(&m.t.groups[g]);
                while (mm != 0) : (mm &= mm - 1) {
                    const e = es[g * NL + laneOf(mm)];
                    const h = homeOf(hashKey(e.key), m.t.shift);
                    if (h.pos != g) n += 1;
                }
            }
            return n;
        }

        pub fn main(init: std.process.Init) !void {
            const io = init.io;
            const gpa = init.gpa;
            const input = try std.Io.Dir.cwd().readFileAlloc(io, "/dev/stdin", gpa, .limited(1 << 31));
            const start = std.mem.indexOf(u8, input, ">THREE") orelse input.len;
            var at = (std.mem.indexOfScalarPos(u8, input, start, '\n') orelse input.len - 1) + 1;
            const seq = try gpa.alloc(u8, input.len - at);
            var n: usize = 0;
            while (at < input.len) : (at += 1) {
                const b = input[at];
                if (b == '\n') continue;
                seq[n] = (b & 0b110) >> 1;
                n += 1;
            }
            const s = seq[0..n];
            const t2 = std.Io.Clock.awake.now(io);
            var f1 = frequencies(s, 1);
            const t3 = std.Io.Clock.awake.now(io);
            var f2 = frequencies(s, 2);
            const t4 = std.Io.Clock.awake.now(io);
            var f4 = frequencies(s, 4);
            const t5 = std.Io.Clock.awake.now(io);
            const us = struct {
                fn f(a: std.Io.Timestamp, b: std.Io.Timestamp) i64 {
                    return @intCast(@divTrunc(b.nanoseconds - a.nanoseconds, 1000));
                }
            }.f;
            std.debug.print("zig k1 {d} k2 {d} k4 {d}\n", .{ us(t2, t3), us(t3, t4), us(t4, t5) });
            if (std.process.Environ.getPosix(init.minimal.environ, "CEIL_DIAG") != null) {
                std.debug.print("groups {d} {d} {d} displaced {d} {d} {d} sums {x} {x} {x}\n", .{
                    f1.t.mask + 1, f2.t.mask + 1, f4.t.mask + 1,
                    displaced(&f1), displaced(&f2), displaced(&f4),
                    sum(&f1),       sum(&f2),       sum(&f4),
                });
            }
            var buf: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{d} {d} {d}\n", .{ f1.t.size, f2.t.size, f4.t.size });
            try std.Io.File.stdout().writeStreamingAll(io, line);
            if (cfg.escape) {
                dropPtr(&f1.t);
                dropPtr(&f2.t);
                dropPtr(&f4.t);
            } else {
                dropVal(f1.t);
                dropVal(f2.t);
                dropVal(f4.t);
            }
        }
    };
}
