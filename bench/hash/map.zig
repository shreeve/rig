//! Zig's std.HashMap timed as bench/hash/map.rig times the built-in Map:
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

/// A key of two words, as map.rig's `Pair`.
const Pair = struct { lo: u64, hi: u64 };

fn pair(i: i64) Pair {
    const u: u64 = @intCast(i);
    return .{ .lo = ((u >> 10) << 32) | (u & 1023), .hi = 0xA5C4000000000000 };
}

fn pairs(io: std.Io, n: i64) !void {
    var m: std.AutoHashMapUnmanaged(Pair, i64) = .empty;
    defer m.deinit(gpa);
    var t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) try m.put(gpa, pair(i), i);
    out("pair", "insert", since(io, t), m.count());
    var sum: i64 = 0;
    t = now(io);
    i = 0;
    while (i < n) : (i += 1) if (m.get(pair(i))) |v| {
        sum += v;
    };
    out("pair", "hit", since(io, t), sum);
    var found: i64 = 0;
    t = now(io);
    i = n;
    while (i < 2 * n) : (i += 1) if (m.contains(pair(i))) {
        found += 1;
    };
    out("pair", "miss", since(io, t), found);
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
/// `text.Interner` does: a map from the text to its id, the text of a
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

/// The ops at one size `s`, as map.rig's `sized`: insert and remove over
/// batches of maps of `s` keys, hit and miss in one map of `s`, iterate
/// over it, each 4,000,000 operations, NS scaled to a million.
fn sized(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const k: i64 = if (s < n) @divTrunc(n, s) else 1;
    const reps: i64 = @divTrunc(total, k * s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "int{d}", .{s});
    const Map = std.AutoHashMapUnmanaged(i64, i64);
    const maps = try gpa.alloc(Map, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        for (maps) |*m| m.* = .empty;
        var t = now(io);
        for (maps, 0..) |*m, j| {
            const base = @as(i64, @intCast(j)) * s;
            var i: i64 = 0;
            while (i < s) : (i += 1) try m.put(gpa, (base + i) *% mul, i);
        }
        ins += since(io, t);
        t = now(io);
        for (maps, 0..) |*m, j| {
            const base = @as(i64, @intCast(j)) * s;
            var i: i64 = 0;
            while (i < s) : (i += 1) if (m.fetchRemove((base + i) *% mul)) |e| {
                check += e.value;
            };
        }
        rem += since(io, t);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: Map = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < s) : (i += 1) try m.put(gpa, i *% mul, i);
    const rounds = @divTrunc(total, s);
    var sum: i64 = 0;
    var t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        i = 0;
        while (i < s) : (i += 1) if (m.get(i *% mul)) |v| {
            sum += v;
        };
    }
    out(name, "hit", @divTrunc(since(io, t) * n, total), sum);
    var found: i64 = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        i = s;
        while (i < 2 * s) : (i += 1) if (m.contains(i *% mul)) {
            found += 1;
        };
    }
    out(name, "miss", @divTrunc(since(io, t) * n, total), found);
    sum = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        var it = m.iterator();
        while (it.next()) |e| sum += e.value_ptr.*;
    }
    out(name, "iterate", @divTrunc(since(io, t) * n, total), sum);
}

/// splitmix64's output for `n + 1`: a bijection, so distinct `n` give
/// distinct keys, scattered over all 64 bits.
fn scatter(n: i64) i64 {
    var z: u64 = (@as(u64, @bitCast(n)) +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return @bitCast(z ^ (z >> 31));
}

const seed: i64 = 0x5eed;

/// `v` shuffled by Fisher-Yates, swap `i` choosing `scatter(seed + i) % (i + 1)`.
fn shuffle(v: []i64) void {
    var i: usize = v.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = @intCast(@as(u64, @bitCast(scatter(seed + @as(i64, @intCast(i))))) % (i + 1));
        std.mem.swap(i64, &v[i], &v[j]);
    }
}

/// The ops of `sized` on random keys (`scatter` of 0, 1, ...), read from
/// slices made before the timing; hits look the keys up in shuffled order.
fn random(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const k: i64 = if (s < n) @divTrunc(n, s) else 1;
    const reps: i64 = @divTrunc(total, k * s);
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "rnd{d}", .{s});
    const Map = std.AutoHashMapUnmanaged(i64, i64);
    const keys = try gpa.alloc(i64, @intCast(k * s));
    defer gpa.free(keys);
    for (keys, 0..) |*x, i| x.* = scatter(@intCast(i));
    const maps = try gpa.alloc(Map, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        for (maps) |*m| m.* = .empty;
        var t = now(io);
        for (maps, 0..) |*m, j| {
            for (keys[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
        }
        ins += since(io, t);
        t = now(io);
        for (maps, 0..) |*m, j| {
            for (keys[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
                check += e.value;
            };
        }
        rem += since(io, t);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: Map = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    const hit = try gpa.dupe(i64, keys[0..su]);
    defer gpa.free(hit);
    shuffle(hit);
    const miss = try gpa.alloc(i64, su);
    defer gpa.free(miss);
    for (miss, 0..) |*x, i| x.* = scatter(8 * n + @as(i64, @intCast(i)));
    const rounds = @divTrunc(total, s);
    var sum: i64 = 0;
    var t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        for (hit) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    out(name, "hit", @divTrunc(since(io, t) * n, total), sum);
    var found: i64 = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        for (miss) |x| if (m.contains(x)) {
            found += 1;
        };
    }
    out(name, "miss", @divTrunc(since(io, t) * n, total), found);
    sum = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        var it = m.iterator();
        while (it.next()) |e| sum += e.value_ptr.*;
    }
    out(name, "iterate", @divTrunc(since(io, t) * n, total), sum);
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const n: usize = 1_000_000;
    const io = std.Io.Threaded.global_single_threaded.io();
    try sized(io, 16);
    try sized(io, 1000);
    try sized(io, 100_000);
    try sized(io, 4_000_000);
    try random(io, 16);
    try random(io, 1000);
    try random(io, 100_000);
    try random(io, 4_000_000);
    try ints(io, @intCast(n));
    try strings(io, n);
    try pairs(io, @intCast(n));
    try small(io, @intCast(n), 4);
    try small(io, @intCast(n), 8);
    try intern(io, n);
}
