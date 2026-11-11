//! u32 keys in the ordered map: today's design (ordered.zig, as
//! `zig-ordered`) against the key-in-index ceiling (ordered_u32.zig),
//! on rows shaped as WORKLOADS.md's `rnd` and `lat` rows, with u32 keys
//! random (`fmix32(n + 1)`, a bijection) or sequential ids (`n + 1`),
//! and values u32 or i64. Each row's loop is a function of its own, never
//! inlined; it reads the clock and the process's instructions retired
//! (`proc_pid_rusage`, macOS) around the loop. Runs are interleaved, the
//! variants' order rotated each round, the fastest time and the fewest
//! instructions of each row kept.
//!
//! usage: u32 [ROUNDS] [VARIANTS,...] [SIZES,...]
//! prints `variant kind size value op ns_per_op instr_per_op check` lines,
//! then `mem variant value bytes_per_entry` for a map of 4,000,000.
const std = @import("std");
const today = @import("ordered.zig");
const nu = @import("ordered_u32.zig");
const gpa = std.heap.c_allocator;
const Ctx = nu.U32Ctx;

const N: usize = 1_000_000;
const TOTAL: usize = 4 * N;

const Variant = enum { today, new8, new16, new8soa, new16soa };

fn Table(comptime v: Variant, comptime V: type) type {
    return switch (v) {
        .today => today.HashMap(u32, V, Ctx),
        .new8 => nu.Ordered(u32, V, Ctx, .{ .width = 8 }),
        .new16 => nu.Ordered(u32, V, Ctx, .{ .width = 16 }),
        .new8soa => nu.Ordered(u32, V, Ctx, .{ .width = 8, .layout = .soa }),
        .new16soa => nu.Ordered(u32, V, Ctx, .{ .width = 16, .layout = .soa }),
    };
}

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;
extern "c" fn getpid() c_int;
extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;

fn instr() u64 {
    var b: [48]u64 = undefined;
    _ = proc_pid_rusage(getpid(), 4, &b);
    return b[31];
}

fn clock() u64 {
    return clock_gettime_nsec_np(4); // CLOCK_MONOTONIC_RAW
}

inline fn hide(x: anytype) @TypeOf(x) {
    return asm volatile (""
        : [ret] "=r" (-> @TypeOf(x)),
        : [x] "0" (x),
    );
}

const Kind = enum { rnd, seq };

fn fmix32(n: u32) u32 {
    var h = n;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

fn keyOf(kind: Kind, n: usize) u32 {
    const u: u32 = @intCast(n + 1);
    return if (kind == .rnd) fmix32(u) else u;
}

fn scatter(n: u64) u64 {
    var z = (n +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn shuffle(comptime T: type, v: []T) void {
    var i = v.len;
    while (i > 1) {
        i -= 1;
        const j: usize = @intCast(scatter(0x5eed + i) % (i + 1));
        std.mem.swap(T, &v[i], &v[j]);
    }
}

inline fn val(comptime V: type, i: usize) V {
    return if (V == u32) @truncate(i) else @intCast(i);
}

inline fn wide(v: anytype) u64 {
    return @bitCast(@as(i64, v));
}

const Meas = struct { ns: u64, ins: u64, check: u64 };

fn measure(t0: u64, c0: u64, check: u64) Meas {
    const t1 = clock();
    const in1 = instr();
    return .{ .ns = t1 - t0, .ins = in1 - c0, .check = check };
}

noinline fn rowInsert(comptime T: type, comptime V: type, maps: []T, keys: []const u32, s: usize) Meas {
    const c0 = instr();
    const t0 = clock();
    for (maps, 0..) |*m, j| {
        const ks = hide(keys[j * s ..].ptr);
        for (0..s) |i| m.put(gpa, ks[i], val(V, i)) catch unreachable;
    }
    return measure(t0, c0, maps.len * s);
}

noinline fn rowRemove(comptime T: type, maps: []T, keys: []const u32, s: usize) Meas {
    var sum: u64 = 0;
    const c0 = instr();
    const t0 = clock();
    for (maps, 0..) |*m, j| {
        const ks = hide(keys[j * s ..].ptr);
        for (0..s) |i| sum +%= wide(m.fetchRemove(ks[i]).?.value);
    }
    return measure(t0, c0, sum);
}

noinline fn rowHit(comptime T: type, m: *const T, look: []const u32, rounds: usize) Meas {
    var sum: u64 = 0;
    const c0 = instr();
    const t0 = clock();
    for (0..rounds) |_| {
        const mm = hide(m);
        const ks = hide(look.ptr);
        for (0..look.len) |i| sum +%= wide(mm.get(ks[i]).?);
    }
    return measure(t0, c0, sum);
}

noinline fn rowMiss(comptime T: type, m: *const T, look: []const u32, rounds: usize) Meas {
    var found: u64 = 0;
    const c0 = instr();
    const t0 = clock();
    for (0..rounds) |_| {
        const mm = hide(m);
        const ks = hide(look.ptr);
        for (0..look.len) |i| {
            if (mm.contains(ks[i])) found += 1;
        }
    }
    return measure(t0, c0, found);
}

noinline fn rowIterate(comptime T: type, m: *const T, rounds: usize) Meas {
    var sum: u64 = 0;
    const c0 = instr();
    const t0 = clock();
    for (0..rounds) |_| {
        const mm = hide(m);
        var it = mm.iterator();
        while (it.next()) |e| sum +%= wide(e.value_ptr.*);
    }
    return measure(t0, c0, sum);
}

noinline fn rowLat(comptime T: type, m: *const T, start: u32, steps: usize) Meas {
    var key = start;
    const c0 = instr();
    const t0 = clock();
    for (0..steps) |_| key = @intCast(m.get(key).?);
    return measure(t0, c0, key);
}

const ops = [_][]const u8{ "insert", "remove", "hit", "miss", "iterate", "lat" };
const sizes_all = [_]usize{ 16, 24, 1000, 100_000, 4_000_000 };
const variants_all = std.enums.values(Variant);
const values = [_]type{ u32, i64 };

/// One row block's inputs: keys for maps, lookups, misses, the chain.
const Inputs = struct {
    kind: Kind,
    s: usize,
    k: usize,
    reps: usize,
    map_keys: []u32, // k*s keys, map j's from j*s
    hit_keys: []u32, // key(i), i < s, in order
    look: []u32, // hit_keys shuffled
    miss: []u32,
    next: []u32, // the chain: key(i) -> key(next[i])
    start: u32,

    fn make(kind: Kind, s: usize) !Inputs {
        const k = if (s >= N) 1 else N / s;
        const reps = TOTAL / (k * s);
        const map_keys = try gpa.alloc(u32, k * s);
        for (map_keys, 0..) |*x, n| x.* = keyOf(kind, n);
        const hit_keys = try gpa.alloc(u32, s);
        for (hit_keys, 0..) |*x, i| x.* = keyOf(kind, i);
        const look = try gpa.dupe(u32, hit_keys);
        shuffle(u32, look);
        const miss = try gpa.alloc(u32, s);
        for (miss, 0..) |*x, i| x.* = keyOf(kind, 8 * N + i);
        const p = try gpa.alloc(u32, s);
        defer gpa.free(p);
        for (p, 0..) |*x, i| x.* = @intCast(i);
        shuffle(u32, p);
        const next = try gpa.alloc(u32, s);
        for (0..s) |t| next[p[t]] = p[(t + 1) % s];
        return .{ .kind = kind, .s = s, .k = k, .reps = reps, .map_keys = map_keys, .hit_keys = hit_keys, .look = look, .miss = miss, .next = next, .start = keyOf(kind, p[0]) };
    }

    fn deinit(in: *Inputs) void {
        gpa.free(in.map_keys);
        gpa.free(in.hit_keys);
        gpa.free(in.look);
        gpa.free(in.miss);
        gpa.free(in.next);
    }
};

const Best = struct { ns: u64 = std.math.maxInt(u64), ins: u64 = std.math.maxInt(u64), check: u64 = 0, ops: u64 = 0, seen: bool = false };

/// best[variant][kind][size][value][op]
var best: [variants_all.len][2][sizes_all.len][2][ops.len]Best = @splat(@splat(@splat(@splat(@splat(.{})))));

fn record(v: usize, kind: Kind, si: usize, vi: usize, op: usize, m: Meas, n_ops: u64) void {
    const b = &best[v][@intFromEnum(kind)][si][vi][op];
    if (b.seen and b.check != m.check) {
        std.debug.print("checksum differs: {s} {s} {d} {d} {s}: {d} vs {d}\n", .{ @tagName(variants_all[v]), @tagName(kind), sizes_all[si], vi, ops[op], m.check, b.check });
        std.process.exit(1);
    }
    // Every variant's checksum must agree with the first variant's.
    for (0..variants_all.len) |o| {
        const ob = &best[o][@intFromEnum(kind)][si][vi][op];
        if (ob.seen and ob.check != m.check) {
            std.debug.print("checksum differs across variants: {s} vs {s} {s} {d} {s}\n", .{ @tagName(variants_all[v]), @tagName(variants_all[o]), @tagName(kind), sizes_all[si], ops[op] });
            std.process.exit(1);
        }
    }
    b.seen = true;
    b.check = m.check;
    b.ops = n_ops;
    b.ns = @min(b.ns, m.ns);
    b.ins = @min(b.ins, m.ins);
}

fn runBlock(comptime vt: Variant, comptime V: type, vi: usize, in: *const Inputs, si: usize) !void {
    const T = Table(vt, V);
    const v = @intFromEnum(vt);
    const s = in.s;
    // insert and remove: k maps of s, reps rounds
    var ins_t: Meas = .{ .ns = 0, .ins = 0, .check = 0 };
    var rem_t: Meas = .{ .ns = 0, .ins = 0, .check = 0 };
    const maps = try gpa.alloc(T, in.k);
    defer gpa.free(maps);
    for (0..in.reps) |_| {
        for (maps) |*m| m.* = .empty;
        const a = rowInsert(T, V, maps, in.map_keys, s);
        const b = rowRemove(T, maps, in.map_keys, s);
        ins_t.ns += a.ns;
        ins_t.ins += a.ins;
        ins_t.check +%= a.check;
        rem_t.ns += b.ns;
        rem_t.ins += b.ins;
        rem_t.check +%= b.check;
        for (maps) |*m| m.deinit(gpa);
    }
    const n_ins: u64 = in.reps * in.k * s;
    record(v, in.kind, si, vi, 0, ins_t, n_ins);
    record(v, in.kind, si, vi, 1, rem_t, n_ins);
    // hit, miss, iterate: one map of key(i) -> i
    {
        var m: T = .empty;
        defer m.deinit(gpa);
        for (in.hit_keys, 0..) |x, i| try m.put(gpa, x, val(V, i));
        const rounds = TOTAL / s;
        record(v, in.kind, si, vi, 2, rowHit(T, &m, in.look, rounds), rounds * s);
        record(v, in.kind, si, vi, 3, rowMiss(T, &m, in.miss, rounds), rounds * s);
        record(v, in.kind, si, vi, 4, rowIterate(T, &m, rounds), rounds * s);
        if (s == 4_000_000 and !mem_done[v][vi]) {
            mem_done[v][vi] = true;
            mem[v][vi] = memOf(T, &m);
        }
    }
    // lat: key(i) -> key(next[i])
    {
        var m: T = .empty;
        defer m.deinit(gpa);
        for (in.hit_keys, 0..) |x, i| try m.put(gpa, x, @intCast(keyOf(in.kind, in.next[i])));
        record(v, in.kind, si, vi, 5, rowLat(T, &m, in.start, TOTAL), TOTAL);
    }
}

var mem: [variants_all.len][2]f64 = @splat(@splat(0));
var mem_done: [variants_all.len][2]bool = @splat(@splat(false));

fn memOf(comptime T: type, m: *const T) f64 {
    const bytes: usize = if (@hasDecl(T, "memoryBytes")) m.memoryBytes() else blk: {
        const words = (m.cap + 63) / 64;
        const ents = std.mem.alignForward(usize, m.cap * @sizeOf(T.KV), 8) + words * 8;
        break :blk ents + 16 * m.groups + 64 + 64 * m.groups;
    };
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(m.count()));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rounds: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 5;
    var want_v: [variants_all.len]bool = @splat(true);
    if (args.len > 2) {
        want_v = @splat(false);
        var it = std.mem.splitScalar(u8, args[2], ',');
        while (it.next()) |name| want_v[@intFromEnum(std.meta.stringToEnum(Variant, name) orelse return error.BadVariant)] = true;
    }
    var want_s: [sizes_all.len]bool = @splat(true);
    if (args.len > 3) {
        want_s = @splat(false);
        var it = std.mem.splitScalar(u8, args[3], ',');
        while (it.next()) |t| {
            const n = try std.fmt.parseInt(usize, t, 10);
            for (sizes_all, 0..) |s, i| if (s == n) {
                want_s[i] = true;
            };
        }
    }
    var inputs: [2][sizes_all.len]?Inputs = @splat(@splat(null));
    for (0..2) |ki| for (sizes_all, 0..) |s, si| {
        if (want_s[si]) inputs[ki][si] = try Inputs.make(@enumFromInt(ki), s);
    };
    for (0..rounds) |r| {
        for (0..2) |ki| for (0..sizes_all.len) |si| {
            const in = &(inputs[ki][si] orelse continue);
            inline for (values, 0..) |V, vi| {
                for (0..variants_all.len) |o| {
                    const v = (o + r) % variants_all.len;
                    if (!want_v[v]) continue;
                    switch (v) {
                        inline 0...variants_all.len - 1 => |cv| try runBlock(variants_all[cv], V, vi, in, si),
                        else => unreachable,
                    }
                }
            }
        };
        std.debug.print("round {d} done\n", .{r + 1});
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &w.interface;
    for (0..variants_all.len) |v| {
        if (!want_v[v]) continue;
        for (0..2) |ki| for (0..sizes_all.len) |si| for (0..2) |vi| for (0..ops.len) |op| {
            const b = best[v][ki][si][vi][op];
            if (!b.seen) continue;
            const fo: f64 = @floatFromInt(b.ops);
            try out.print("{s} {s} {d} {s} {s} {d:.3} {d:.2} {d}\n", .{ @tagName(variants_all[v]), @tagName(@as(Kind, @enumFromInt(ki))), sizes_all[si], if (vi == 0) "u32" else "i64", ops[op], @as(f64, @floatFromInt(b.ns)) / fo, @as(f64, @floatFromInt(b.ins)) / fo, b.check });
        };
        for (0..2) |vi| if (mem_done[v][vi]) try out.print("mem {s} {s} {d:.2}\n", .{ @tagName(variants_all[v]), if (vi == 0) "u32" else "i64", mem[v][vi] });
    }
    try out.flush();
}
