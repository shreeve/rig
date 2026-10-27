//! sim.zig: bench/hash's big rows' allocations (insert, then deinit, four
//! reps), printing what the heap took from the system per rep.
const std = @import("std");
const table = @import("table");
const alloc = @import("alloc");
const gpa = alloc.allocator;

fn big(i: i64) [8]i64 {
    return .{ i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7 };
}

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn ms(a: std.Io.Clock.Timestamp, b: std.Io.Clock.Timestamp) i96 {
    return @divTrunc(a.durationTo(b).raw.toNanoseconds(), 1000000);
}

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_]i64{ 1000, 100_000, 1_000_000 }) |s| {
        const n: i64 = 1_000_000;
        const k: i64 = if (s < n) @divTrunc(n, s) else 1;
        const su: usize = @intCast(s);
        const Map = table.Auto(i64, [8]i64);
        const maps = try gpa.alloc(Map, @intCast(k));
        defer gpa.free(maps);
        var r: usize = 0;
        while (r < 4) : (r += 1) {
            const t0 = if (@hasDecl(alloc, "heapForTest")) alloc.heapForTest().taken else 0;
            const c0 = now(io);
            for (maps) |*m| m.* = .empty;
            for (maps, 0..) |*m, j| {
                for (0..su) |i| try m.put(gpa, @intCast(j * su + i), big(@intCast(i)));
            }
            const c1 = now(io);
            for (maps) |*m| m.deinit(gpa);
            const c2 = now(io);
            const took = if (@hasDecl(alloc, "heapForTest")) alloc.heapForTest().taken - t0 else 0;
            std.debug.print("big{d} rep {d}: insert {d} ms, deinit {d} ms, took {d} MiB\n", .{ s, r, ms(c0, c1), ms(c1, c2), took >> 20 });
        }
    }
}
