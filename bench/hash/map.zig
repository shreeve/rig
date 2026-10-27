//! Zig's std.HashMap timed as bench/hash/map.rig times the built-in Map:
//! `std.AutoHashMapUnmanaged(i64, i64)` and `std.StringHashMapUnmanaged(i64)`,
//! or a port named by the module `table`, allocating from libc's `malloc`.
//! Each String key is built as Rig builds
//! `String("key", i)`, by an `std.Io.Writer.Allocating` over an
//! `ArrayList(u8)`, so its bytes sit in an allocation of the same size
//! and both maps read keys from memory laid out alike. Prints
//! `KEYS OP NS CHECK` per line.
const std = @import("std");
/// The table every row but the first round's Rig-and-Zig rows (ints,
/// strings, pairs, small, intern) times: `table_std.zig`, Zig's own
/// HashMap, or a port (`table_foa.zig`, `table_dense.zig`), named by
/// bench-hash as the module `table`.
const table = @import("table");

/// The allocator, the module `alloc` bench-hash names: libc's `malloc`
/// by default, as the C++ and Rust contestants allocate from, so a row
/// times the table, not the allocator; another for `VARIANT:ALLOC`.
const alloc = @import("alloc");
const gpa = alloc.allocator;
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

/// `x`, hidden from the optimizer, as map.cc's `opaque` and Rust's
/// `black_box` hide it: a round's keys, or the map it walks, cannot be
/// proved the last round's, so no round's work is hoisted or merged.
inline fn hide(x: anytype) @TypeOf(x) {
    return asm volatile (""
        : [ret] "=r" (-> @TypeOf(x)),
        : [x] "0" (x),
    );
}

/// Keeps what `p` points at, as map.cc's `keep`: the stores made into it
/// must be made.
inline fn keep(p: anytype) void {
    asm volatile (""
        :
        : [p] "r" (p),
        : .{ .memory = true });
}

/// Gives back what a row's arena holds, for an allocator that has one.
fn rowDone() void {
    if (@hasDecl(alloc, "reset")) alloc.reset();
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
    const Map = table.Auto(i64, i64);
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
        keep(maps.ptr);
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
        while (i < s) : (i += 1) if (m.get(hide(i) *% mul)) |v| {
            sum += v;
        };
    }
    out(name, "hit", @divTrunc(since(io, t) * n, total), sum);
    var found: i64 = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        i = s;
        while (i < 2 * s) : (i += 1) if (m.contains(hide(i) *% mul)) {
            found += 1;
        };
    }
    out(name, "miss", @divTrunc(since(io, t) * n, total), found);
    sum = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(&m).iterator();
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
    const Map = table.Auto(i64, i64);
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
        keep(maps.ptr);
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
        for (hide(hit.ptr)[0..su]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    out(name, "hit", @divTrunc(since(io, t) * n, total), sum);
    var found: i64 = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        for (hide(miss.ptr)[0..su]) |x| if (m.contains(x)) {
            found += 1;
        };
    }
    out(name, "miss", @divTrunc(since(io, t) * n, total), found);
    sum = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(&m).iterator();
        while (it.next()) |e| sum += e.value_ptr.*;
    }
    out(name, "iterate", @divTrunc(since(io, t) * n, total), sum);
}

/// `text(n)` of bench/hash/WORKLOADS.md: 7 to 27 bytes, distinct by
/// the part after `#`, in an allocation of its own.
fn text(n: i64) ![]u8 {
    const shift: u6 = @intCast(@mod(n, 48));
    return std.fmt.allocPrint(gpa, "{d}#{d}", .{ @as(u64, @bitCast(scatter(n))) >> shift, n });
}

/// `big(i)`: eight integers from `i`.
fn big(i: i64) [8]i64 {
    return .{ i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7 };
}

/// `0, 1, ..., s - 1`, shuffled.
fn shuffled(s: usize) ![]i64 {
    const v = try gpa.alloc(i64, s);
    for (v, 0..) |*x, i| x.* = @intCast(i);
    shuffle(v);
    return v;
}

/// One lookup at a time, each waiting for the last: the map is one
/// cycle through its keys, in shuffled order.
fn latency(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "lat{d}", .{s});
    const p = try shuffled(su);
    defer gpa.free(p);
    var m: table.Auto(i64, i64) = .empty;
    defer m.deinit(gpa);
    // Each key `scatter(i)` is put in order of `i`, with the key after it
    // in the cycle as its value, so a map that keeps its entries in order
    // meets them out of order.
    const next = try gpa.alloc(i64, su);
    defer gpa.free(next);
    for (0..su) |t| next[@intCast(p[t])] = p[(t + 1) % su];
    for (0..su) |i| try m.put(gpa, scatter(@intCast(i)), scatter(next[i]));
    var x = scatter(p[0]);
    const t = now(io);
    var r: i64 = 0;
    while (r < total) : (r += 1) x = m.get(x).?;
    out(name, "chain", @divTrunc(since(io, t) * n, total), x);
}

/// A map of `s` keys turned over: each step removes the oldest key and
/// inserts a new one.
fn churn(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const turns: i64 = @divTrunc(total, 2);
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "churn{d}", .{s});
    const keys = try gpa.alloc(i64, @intCast(s + turns));
    defer gpa.free(keys);
    for (keys, 0..) |*x, i| x.* = scatter(@intCast(i));
    var m: table.Auto(i64, i64) = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    var check: i64 = 0;
    const t = now(io);
    var i: i64 = 0;
    while (i < turns) : (i += 1) {
        if (m.fetchRemove(keys[@intCast(i)])) |e| check +%= e.value;
        try m.put(gpa, keys[@intCast(s + i)], s + i);
    }
    const ns = since(io, t);
    keep(&m);
    out(name, "turnover", @divTrunc(ns * n, total), check);
}

/// Lookups that hit half the time, in shuffled order.
fn mixed(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "mix{d}", .{s});
    var m: table.Auto(i64, i64) = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < s) : (i += 1) try m.put(gpa, scatter(i), i);
    const look = try gpa.alloc(i64, su);
    defer gpa.free(look);
    for (look, 0..) |*x, j| {
        const ji: i64 = @intCast(j);
        x.* = if (@mod(ji, 2) == 0) scatter(ji) else scatter(8 * n + ji);
    }
    shuffle(look);
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < @divTrunc(total, s)) : (r += 1) {
        for (hide(look.ptr)[0..su]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    out(name, "half", @divTrunc(since(io, t) * n, total), sum);
}

const StrMap = table.String(i64);

/// Frees a map of texts and the keys it owns.
fn freeStrMap(m: *StrMap) void {
    var it = m.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    m.deinit(gpa);
}

/// Frees an array of texts.
fn freeTexts(v: [][]u8) void {
    for (v) |x| gpa.free(x);
    gpa.free(v);
}

/// Text keys, each moved into the map, which frees it, and found by an
/// equal text made apart; a million operations a row.
fn texts(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const k: i64 = if (s < n) @divTrunc(n, s) else 1;
    const reps: i64 = @divTrunc(n, k * s);
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "str{d}", .{s});
    const maps = try gpa.alloc(StrMap, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        // The map takes each key of `put`; only the array is freed after.
        const put = try gpa.alloc([]u8, @intCast(k * s));
        defer gpa.free(put);
        const take = try gpa.alloc([]u8, @intCast(k * s));
        defer freeTexts(take);
        // Each array in its own pass, as map.rs makes them, so one
        // array's texts sit together in memory.
        for (put, 0..) |*a, i| a.* = try text(@intCast(i));
        for (take, 0..) |*b, i| b.* = try text(@intCast(i));
        for (maps) |*m| m.* = .empty;
        var t = now(io);
        for (maps, 0..) |*m, j| {
            for (put[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
        }
        ins += since(io, t);
        t = now(io);
        for (maps, 0..) |*m, j| {
            for (take[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
                gpa.free(e.key);
                check += e.value;
            };
        }
        rem += since(io, t);
        keep(maps.ptr);
        for (maps) |*m| freeStrMap(m);
    }
    out(name, "insert", ins, reps * k * s);
    out(name, "remove", rem, check);
    var m: StrMap = .empty;
    defer freeStrMap(&m);
    var i: i64 = 0;
    while (i < s) : (i += 1) try m.put(gpa, try text(i), i);
    const order = try shuffled(su);
    defer gpa.free(order);
    const hit = try gpa.alloc([]u8, su);
    defer freeTexts(hit);
    const miss = try gpa.alloc([]u8, su);
    defer freeTexts(miss);
    for (hit, order) |*h, o| h.* = try text(o);
    for (miss, 0..) |*x, j| x.* = try text(8 * n + @as(i64, @intCast(j)));
    var sum: i64 = 0;
    var t = now(io);
    r = 0;
    while (r < @divTrunc(n, s)) : (r += 1) {
        for (hide(hit.ptr)[0..su]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    out(name, "hit", since(io, t), sum);
    var found: i64 = 0;
    t = now(io);
    r = 0;
    while (r < @divTrunc(n, s)) : (r += 1) {
        for (hide(miss.ptr)[0..su]) |x| if (m.contains(x)) {
            found += 1;
        };
    }
    out(name, "miss", since(io, t), found);
}

/// `random`'s insert, remove, hit and iterate with a value of eight
/// integers.
fn bigs(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const k: i64 = if (s < n) @divTrunc(n, s) else 1;
    const reps: i64 = @divTrunc(total, k * s);
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "big{d}", .{s});
    const Map = table.Auto(i64, [8]i64);
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
            for (keys[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, big(@intCast(i)));
        }
        ins += since(io, t);
        t = now(io);
        for (maps, 0..) |*m, j| {
            for (keys[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
                check += e.value[7];
            };
        }
        rem += since(io, t);
        keep(maps.ptr);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: Map = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, big(@intCast(i)));
    const hit = try gpa.dupe(i64, keys[0..su]);
    defer gpa.free(hit);
    shuffle(hit);
    const rounds = @divTrunc(total, s);
    var sum: i64 = 0;
    var t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        for (hide(hit.ptr)[0..su]) |x| if (m.getPtr(x)) |v| {
            sum += v[7];
        };
    }
    out(name, "hit", @divTrunc(since(io, t) * n, total), sum);
    sum = 0;
    t = now(io);
    r = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(&m).valueIterator();
        while (it.next()) |v| sum += v[0];
    }
    out(name, "iterate", @divTrunc(since(io, t) * n, total), sum);
}

/// `mem`: one map of 4,000,000 keys, for its peak memory; `mem0`: the
/// keys alone, the baseline.
fn memory(with_map: bool) !void {
    const n: usize = 4_000_000;
    const keys = try gpa.alloc(i64, n);
    defer gpa.free(keys);
    for (keys, 0..) |*x, i| x.* = scatter(@intCast(i));
    if (!with_map) {
        std.mem.doNotOptimizeAway(keys.ptr);
        std.debug.print("mem0 {d} len {d}\n", .{ n, keys.len });
        return;
    }
    var m: table.Auto(i64, i64) = .empty;
    defer m.deinit(gpa);
    for (keys, 0..) |x, i| try m.put(gpa, x, @intCast(i));
    keep(&m);
    std.debug.print("mem {d} len {d}\n", .{ n, m.count() });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.skip();
    if (args.next()) |a| {
        if (std.mem.eql(u8, a, "mem")) return memory(true);
        if (std.mem.eql(u8, a, "mem0")) return memory(false);
    }
    const n: usize = 1_000_000;
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_]i64{ 16, 1000, 100_000, 4_000_000 }) |s| {
        try sized(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 24, 1000, 1500, 100_000, 150_000, 3_000_000, 4_000_000 }) |s| {
        try random(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 1000, 100_000, 4_000_000 }) |s| {
        try latency(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 1000, 100_000, 4_000_000 }) |s| {
        try churn(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 1000, 100_000, 4_000_000 }) |s| {
        try mixed(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 1000, 100_000, 1_000_000 }) |s| {
        try texts(io, s);
        rowDone();
    }
    for ([_]i64{ 16, 1000, 100_000, 1_000_000 }) |s| {
        try bigs(io, s);
        rowDone();
    }
    // The rows only Rig and Zig's own HashMap time.
    if (!table.is_std) return;
    try ints(io, @intCast(n));
    try strings(io, n);
    try pairs(io, @intCast(n));
    try small(io, @intCast(n), 4);
    try small(io, @intCast(n), 8);
    try intern(io, n);
}
