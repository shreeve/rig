//! Zig's std.HashMap timed as bench/hash/map.rig times std.hash's Map:
//! `std.AutoHashMapUnmanaged(i64, i64)` and `std.StringHashMapUnmanaged(i64)`,
//! with Rig's allocator. Each String key is built as Rig builds
//! `String("key", i)`, by an `std.Io.Writer.Allocating` over an
//! `ArrayList(u8)`, so its bytes sit in an allocation of the same size
//! and both maps read keys from memory laid out alike. Prints
//! `KEYS OP NS CHECK` per line.
const std = @import("std");

const gpa = std.heap.smp_allocator; // what a Rig program allocates from
const mul: i64 = -7046029254386353131;

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn since(io: std.Io, t: std.Io.Clock.Timestamp) i96 {
    return t.durationTo(now(io)).raw.toNanoseconds();
}

fn out(keys: []const u8, op: []const u8, ns: i96, check: i64) void {
    std.debug.print("{s} {s} {d} {d}\n", .{ keys, op, ns, check });
}

fn ints(io: std.Io, n: i64) !void {
    var m: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    defer m.deinit(gpa);
    var t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) try m.put(gpa, i *% mul, i);
    out("int", "insert", since(io, t), m.count());
    var sum: i64 = 0;
    t = now(io);
    i = 0;
    while (i < n) : (i += 1) if (m.get(i *% mul)) |v| {
        sum += v;
    };
    out("int", "hit", since(io, t), sum);
    var found: i64 = 0;
    t = now(io);
    i = n;
    while (i < 2 * n) : (i += 1) if (m.contains(i *% mul)) {
        found += 1;
    };
    out("int", "miss", since(io, t), found);
    sum = 0;
    t = now(io);
    var it = m.iterator();
    while (it.next()) |e| sum += e.value_ptr.*;
    out("int", "iterate", since(io, t), sum);
}

/// "key" and `i`, built as Rig's `String("key", i)` is (`rig.String.add`).
fn key(i: usize) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &list);
    try w.writer.print("key{d}", .{i});
    return w.toArrayList();
}

fn strings(io: std.Io, n: usize) !void {
    const put = try gpa.alloc(std.ArrayList(u8), n);
    const look = try gpa.alloc(std.ArrayList(u8), n);
    const miss = try gpa.alloc(std.ArrayList(u8), n);
    for (0..n) |i| {
        put[i] = try key(i);
        look[i] = try key(i);
        miss[i] = try key(n + i);
    }
    var m: std.StringHashMapUnmanaged(i64) = .empty;
    var t = now(io);
    for (put, 0..) |k, i| try m.put(gpa, k.items, @intCast(i));
    out("string", "insert", since(io, t), m.count());
    var sum: i64 = 0;
    t = now(io);
    for (look) |k| if (m.get(k.items)) |v| {
        sum += v;
    };
    out("string", "hit", since(io, t), sum);
    var found: i64 = 0;
    t = now(io);
    for (miss) |k| if (m.contains(k.items)) {
        found += 1;
    };
    out("string", "miss", since(io, t), found);
    sum = 0;
    t = now(io);
    var it = m.iterator();
    while (it.next()) |e| sum += e.value_ptr.*;
    out("string", "iterate", since(io, t), sum);
    m.deinit(gpa);
    for (put, look, miss) |*a, *b, *c| {
        a.deinit(gpa);
        b.deinit(gpa);
        c.deinit(gpa);
    }
    gpa.free(put);
    gpa.free(look);
    gpa.free(miss);
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const n: usize = 1_000_000;
    const io = std.Io.Threaded.global_single_threaded.io();
    try ints(io, @intCast(n));
    try strings(io, n);
}
