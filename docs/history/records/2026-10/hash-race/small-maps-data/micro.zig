//! Built from src/: copy it there beside main's src/ordered.zig as zz_ordered_main.zig
//! (and, for micro.zig, another table as zz_gm.zig), then zig build-exe -OReleaseFast.
//! old (main), new (ordered.zig), prev (zz_gm.zig): hit and miss across many maps, churn, in-order remove, insert.
const std = @import("std");
const rt = @import("runtime.zig");
const new = @import("ordered.zig");
const prev = @import("zz_gm.zig");
const old = @import("zz_ordered_main.zig");
fn scatter(n: u64) i64 {
    var z = (n +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return @bitCast(z ^ (z >> 31));
}
var io_g: std.Io = undefined;
fn now() std.Io.Timestamp {
    return std.Io.Timestamp.now(io_g, .awake);
}
fn since(t0: std.Io.Timestamp) u64 {
    return @intCast(t0.durationTo(now()).toNanoseconds());
}
const F = 6;
const names = [F][]const u8{ "hit", "miss", "insert", "remove", "churn", "hit1" };
noinline fn row(comptime Mod: type, ks: []const i64, s: usize, nmaps: usize) [F]u64 {
    const T = struct { len: i64 = 0, t: Mod.OrderedMap(i64, i64) = .{} };
    var r: [F]u64 = undefined;
    var c: i64 = 0;
    const k = nmaps;
    const maps = rt.allocSlice(T, k);
    defer rt.freeSlice(T, maps);
    @memset(maps, .{});
    var t0 = now();
    for (maps, 0..) |*m, j| for (0..s) |i| {
        _ = m.t.put(ks[j * s + i], @intCast(i));
    };
    r[2] = since(t0) * 4;
    const reps = 4_000_000 / (k * s);
    t0 = now();
    for (0..reps) |_| for (maps, 0..) |*m, j| for (0..s) |i| {
        if (m.t.find(ks[j * s + i])) |x| c +%= m.t.value(x);
    };
    r[0] = since(t0);
    t0 = now();
    for (0..reps) |_| for (maps, 0..) |*m, j| for (0..s) |i| {
        if (m.t.find(ks[3_000_000 + j * s + i]) != null) c += 1;
    };
    r[1] = since(t0);
    // hits in shuffled order on one map, behind a pointer
    t0 = now();
    for (0..4_000_000 / s) |rr| for (0..s) |i| {
        const ii = (i * 7 + rr) % s;
        if (maps[0].t.find(ks[ii])) |x| c +%= maps[0].t.value(x);
    };
    r[5] = since(t0);
    t0 = now();
    for (maps, 0..) |*m, j| for (0..s) |i| {
        c +%= rt.some(m.t.take(ks[j * s + i])) orelse 0;
    };
    r[3] = since(t0) * 4;
    for (maps) |*m| m.t.__rig_drop();
    {
        maps[0] = .{};
        for (0..s) |i| _ = maps[0].t.put(ks[i], @intCast(i));
        t0 = now();
        for (0..2_000_000) |i| {
            c +%= rt.some(maps[0].t.take(ks[i])) orelse 0;
            _ = maps[0].t.put(ks[s + i], @intCast(s + i));
        }
        r[4] = since(t0);
        maps[0].t.__rig_drop();
    }
    std.mem.doNotOptimizeAway(c);
    return r;
}
pub fn main(init: std.process.Init) !void {
    io_g = init.io;
    const ks = rt.allocSlice(i64, 5_000_000);
    for (ks, 0..) |*k, n| k.* = scatter(n);
    std.debug.print("ns per op; old / new / prev\n", .{});
    for ([_]usize{ 2, 4, 8, 16, 24, 32, 40, 48 }) |s| for ([_]usize{ 1_000_000 / s }) |nm| {
        var best: [3][F]u64 = undefined;
        for (&best) |*b| b.* = @splat(~@as(u64, 0));
        for (0..5) |_| {
            inline for (.{ old, new, prev }, 0..) |M, v| {
                const r = row(M, ks, s, nm);
                for (0..F) |f| best[v][f] = @min(best[v][f], r[f]);
            }
        }
        std.debug.print("s={d:2}", .{s});
        for (0..F) |f| std.debug.print(" | {s} {d:.2} {d:.2} {d:.2}", .{ names[f], @as(f64, @floatFromInt(best[0][f])) / 4e6, @as(f64, @floatFromInt(best[1][f])) / 4e6, @as(f64, @floatFromInt(best[2][f])) / 4e6 });
        std.debug.print("\n", .{});
    };
}
