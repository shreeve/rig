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

/// `n` hit lookups in a map of `size` Int keys.
fn small(io: std.Io, n: i64, size: i64) !void {
    var m: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, i *% mul, i);
    var sum: i64 = 0;
    const t = now(io);
    i = 0;
    while (i < n) : (i += 1) if (m.get(@mod(i, size) *% mul)) |v| {
        sum += v;
    };
    const keys = if (size == 4) "small 4" else "small 8";
    std.debug.print("{s} {d} {d}\n", .{ keys, since(io, t), sum });
}

/// `n` words, from 50,000 distinct ones, each given a dense id, as
/// `hash.Symbols` does: a map from the text to its id, the text of a
/// new word copied once into one arena.
fn intern(io: std.Io, n: usize) !void {
    const words = try gpa.alloc(std.ArrayList(u8), n);
    for (words, 0..) |*w, i| w.* = try word(i);
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    var arena: std.ArrayList(u8) = .empty;
    var ends: std.ArrayList(u32) = .empty;
    var sum: u64 = 0;
    const t = now(io);
    for (words) |w| {
        const got = try ids.getOrPut(gpa, w.items);
        if (!got.found_existing) {
            try arena.appendSlice(gpa, w.items);
            try ends.append(gpa, @intCast(arena.items.len));
            // The key views the word, whose buffer outlives the map.
            got.key_ptr.* = w.items;
            got.value_ptr.* = @intCast(ends.items.len - 1);
        }
        sum +%= got.value_ptr.*;
    }
    out("string", "intern", since(io, t), @bitCast(sum));
    ids.deinit(gpa);
    arena.deinit(gpa);
    ends.deinit(gpa);
    for (words) |*w| w.deinit(gpa);
    gpa.free(words);
}

/// "w" and `(i * 7919) % 50000`, built as Rig builds `String("w", x)`.
fn word(i: usize) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &list);
    try w.writer.print("w{d}", .{(i * 7919) % 50000});
    return w.toArrayList();
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const n: usize = 1_000_000;
    const io = std.Io.Threaded.global_single_threaded.io();
    try ints(io, @intCast(n));
    try strings(io, n);
    try small(io, @intCast(n), 4);
    try small(io, @intCast(n), 8);
    try intern(io, n);
}
