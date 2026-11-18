//! Zig's sorts on the data std.sort's bench sorts: `pdq` (unstable) and
//! `block` (stable, WikiSort) and `drift` (stable, drift.zig) over i64, text, a two-field object, and a
//! record ordered by one key. Prints the fastest round, ns per element.
//! zsort KIND PATTERN N ROUNDS ALGO
//! The data is aligned to 64 bytes, as a large malloc's is.
const std = @import("std");
const drift = @import("drift.zig");

const P = struct { a: i64, b: i64 };
const Rec = struct { key: i64, id: i64 };

var state: u64 = 42;
fn next() u64 {
    state +%= 0x9e3779b97f4a7c15;
    var z = state;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn key(pattern: []const u8, i: usize, n: usize) i64 {
    if (std.mem.eql(u8, pattern, "rand")) return @intCast(next() >> 1);
    if (std.mem.eql(u8, pattern, "sorted")) return @intCast(i);
    if (std.mem.eql(u8, pattern, "rev")) return @intCast(n - i);
    return @intCast(next() % 16);
}

fn lessInt(_: void, a: i64, b: i64) bool {
    return a < b;
}
fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return textLess(a, b);
}

/// Whether text `a` orders before `b`: eight bytes at a time as
/// big-endian words from 8 bytes in common, the last overlapping the
/// bytes found equal (Rig's `rig.textLess`). std.mem.order goes byte
/// by byte, at about three times the cost; an `Order` returned instead
/// of a `bool` makes LLVM branch on it in a safe build.
fn textLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    const p = a.ptr;
    const q = b.ptr;
    if (n >= 8) {
        var i: usize = 0;
        while (i < n - 8) : (i += 8) {
            const x = std.mem.bigToNative(u64, @as(*align(1) const u64, @ptrCast(p + i)).*);
            const y = std.mem.bigToNative(u64, @as(*align(1) const u64, @ptrCast(q + i)).*);
            if (x != y) return x < y;
        }
        const x = std.mem.bigToNative(u64, @as(*align(1) const u64, @ptrCast(p + n - 8)).*);
        const y = std.mem.bigToNative(u64, @as(*align(1) const u64, @ptrCast(q + n - 8)).*);
        if (x != y) return x < y;
    } else {
        for (p[0..n], q[0..n]) |x, y| if (x != y) return x < y;
    }
    return a.len < b.len;
}
fn lessP(_: void, a: P, b: P) bool {
    if (a.a != b.a) return a.a < b.a;
    return a.b < b.b;
}
fn lessP3(_: void, a: P, b: P) bool {
    return ord3(a, b).compare(.lt);
}
fn ord3(a: P, b: P) std.math.Order {
    const st = @typeInfo(P).@"struct";
    inline for (st.field_names) |name| {
        const o = std.math.order(@field(a, name), @field(b, name));
        if (o != .eq) return o;
    }
    return .eq;
}
fn lessRec(_: void, a: Rec, b: Rec) bool {
    return a.key < b.key;
}

const Algo = enum { pdq, pdqv, drift, block };

fn run(comptime T: type, io: std.Io, master: []const T, work: []T, n: usize, rounds: usize, algo_name: []const u8, comptime less: anytype) u64 {
    const algo = std.meta.stringToEnum(Algo, algo_name) orelse .block;
    return switch (algo) {
        inline else => |a| runAlgo(T, a, io, master, work, n, rounds, less),
    };
}

fn runAlgo(comptime T: type, comptime algo: Algo, io: std.Io, master: []const T, work: []T, n: usize, rounds: usize, comptime less: anytype) u64 {
    const reps = master.len / n;
    var best: u64 = std.math.maxInt(u64);
    for (0..rounds) |_| {
        @memcpy(work, master);
        const t0 = std.Io.Clock.awake.now(io);
        var r: usize = 0;
        while (r < reps) : (r += 1) {
            const s = work[r * n .. (r + 1) * n];
            switch (algo) {
                .pdq => std.sort.pdq(T, s, {}, less),
                .pdqv => {
                    // pdq with whole-value swaps (std.mem.swap moves bytes).
                    const Ctx = struct {
                        items: []T,
                        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                            return less({}, c.items[x], c.items[y]);
                        }
                        pub fn swap(c: @This(), x: usize, y: usize) void {
                            const t = c.items[x];
                            c.items[x] = c.items[y];
                            c.items[y] = t;
                        }
                    };
                    std.sort.pdqContext(0, s.len, Ctx{ .items = s });
                },
                .drift => drift.sort(T, s, {}, less),
                .block => std.sort.block(T, s, {}, less),
            }
        }
        const dt: u64 = @intCast(t0.untilNow(io, .awake).toNanoseconds());
        std.mem.doNotOptimizeAway(work.ptr);
        best = @min(best, dt);
    }
    // Check the result of the last round.
    for (0..reps) |q| {
        const s = work[q * n .. (q + 1) * n];
        for (1..s.len) |k| if (less({}, s[k], s[k - 1])) @panic("unsorted");
    }
    return best;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const kind = args[1];
    const pattern = args[2];
    const n = try std.fmt.parseInt(usize, args[3], 10);
    const rounds = try std.fmt.parseInt(usize, args[4], 10);
    const algo = args[5];
    const reps = @max(1, (1 << 20) / n);
    const total = reps * n;
    var best: u64 = 0;
    if (std.mem.eql(u8, kind, "int")) {
        const m = try arena.alignedAlloc(i64, .@"64", total);
        for (0..reps) |r| for (0..n) |i| {
            m[r * n + i] = key(pattern, i, n);
        };
        best = run(i64, io, m, try arena.alignedAlloc(i64, .@"64", total), n, rounds, algo, lessInt);
    } else if (std.mem.eql(u8, kind, "str")) {
        const m = try arena.alignedAlloc([]const u8, .@"64", total);
        const sorted = std.mem.eql(u8, pattern, "sorted") or std.mem.eql(u8, pattern, "rev");
        for (0..reps) |r| for (0..n) |i| {
            const k = key(pattern, i, n);
            m[r * n + i] = try arena.print("{d}", .{if (sorted) k + 1000000000000 else k});
        };
        best = run([]const u8, io, m, try arena.alignedAlloc([]const u8, .@"64", total), n, rounds, algo, lessStr);
    } else if (std.mem.eql(u8, kind, "obj") or std.mem.eql(u8, kind, "obj3")) {
        const m = try arena.alignedAlloc(P, .@"64", total);
        for (0..reps) |r| for (0..n) |i| {
            const k = key(pattern, i, n);
            m[r * n + i] = .{ .a = @divFloor(k, 1024), .b = @mod(k, 1024) };
        };
        best = if (std.mem.eql(u8, kind, "obj")) run(P, io, m, try arena.alignedAlloc(P, .@"64", total), n, rounds, algo, lessP) else run(P, io, m, try arena.alignedAlloc(P, .@"64", total), n, rounds, algo, lessP3);
    } else {
        const m = try arena.alignedAlloc(Rec, .@"64", total);
        for (0..reps) |r| for (0..n) |i| {
            m[r * n + i] = .{ .key = key(pattern, i, n), .id = @intCast(i) };
        };
        best = run(Rec, io, m, try arena.alignedAlloc(Rec, .@"64", total), n, rounds, algo, lessRec);
    }
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("{d:.3}\n", .{@as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(total))});
    try out.interface.flush();
}
