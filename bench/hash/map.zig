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
/// strings, small, intern) times: `table_std.zig`, Zig's own
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

// Each row's timed loop is a function of its own that is never inlined,
// so its registers are allotted for that loop alone, not shared with
// the other rows' loops in the caller. It reads the clock around the
// loop, so the call is not timed, and returns the time with the row's
// checksum.

/// A row's time in nanoseconds and its checksum.
const Timed = struct { ns: i96, check: i64 };

const StdIntMap = std.AutoHashMapUnmanaged(i64, i64);

noinline fn intsInsert(io: std.Io, m: *StdIntMap, n: i64) !i96 {
    const t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) try m.put(gpa, i *% mul, i);
    return since(io, t);
}

noinline fn intsHit(io: std.Io, m: *StdIntMap, n: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) if (m.get(i *% mul)) |v| {
        sum += v;
    };
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn intsMiss(io: std.Io, m: *StdIntMap, n: i64) Timed {
    var found: i64 = 0;
    const t = now(io);
    var i: i64 = n;
    while (i < 2 * n) : (i += 1) if (m.contains(i *% mul)) {
        found += 1;
    };
    return .{ .ns = since(io, t), .check = found };
}

noinline fn intsIterate(io: std.Io, m: *StdIntMap) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var it = m.iterator();
    while (it.next()) |e| sum += e.value_ptr.*;
    return .{ .ns = since(io, t), .check = sum };
}

fn ints(io: std.Io, n: i64) !void {
    var m: StdIntMap = .empty;
    defer m.deinit(gpa);
    const ns = try intsInsert(io, &m, n);
    out("int", "insert", ns, m.count());
    var d = intsHit(io, &m, n);
    out("int", "hit", d.ns, d.check);
    d = intsMiss(io, &m, n);
    out("int", "miss", d.ns, d.check);
    d = intsIterate(io, &m);
    out("int", "iterate", d.ns, d.check);
}

/// A key of two words, as map.rig's `Pair`.
const Pair = struct { lo: u64, hi: u64 };

fn pair(i: i64) Pair {
    const u: u64 = @intCast(i);
    return .{ .lo = ((u >> 10) << 32) | (u & 1023), .hi = 0xA5C4000000000000 };
}

/// The timed loops of `pairs` and `triples`, for keys `make(i)`.
noinline fn keyedInsert(comptime K: type, comptime make: fn (i64) K, io: std.Io, m: *table.Auto(K, i64), n: i64) !i96 {
    const t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) try m.put(gpa, make(i), i);
    return since(io, t);
}

noinline fn keyedHit(comptime K: type, comptime make: fn (i64) K, io: std.Io, m: *table.Auto(K, i64), n: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) if (m.get(make(i))) |v| {
        sum += v;
    };
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn keyedMiss(comptime K: type, comptime make: fn (i64) K, io: std.Io, m: *table.Auto(K, i64), n: i64) Timed {
    var found: i64 = 0;
    const t = now(io);
    var i: i64 = n;
    while (i < 2 * n) : (i += 1) if (m.contains(make(i))) {
        found += 1;
    };
    return .{ .ns = since(io, t), .check = found };
}

fn pairs(io: std.Io, n: i64) !void {
    var m: table.Auto(Pair, i64) = .empty;
    defer m.deinit(gpa);
    const ns = try keyedInsert(Pair, pair, io, &m, n);
    out("pair", "insert", ns, @intCast(m.count()));
    var d = keyedHit(Pair, pair, io, &m, n);
    out("pair", "hit", d.ns, d.check);
    d = keyedMiss(Pair, pair, io, &m, n);
    out("pair", "miss", d.ns, d.check);
}

/// A key of three words, as map.rig's `Triple`.
const Triple = struct { owner: u64, lo: u64, hi: u64 };

fn triple(i: i64) Triple {
    const u: u64 = @intCast(i);
    return .{ .owner = u >> 4, .lo = ((u >> 10) << 32) | (u & 1023), .hi = 0xA5C4000000000000 };
}

fn triples(io: std.Io, n: i64) !void {
    var m: table.Auto(Triple, i64) = .empty;
    defer m.deinit(gpa);
    const ns = try keyedInsert(Triple, triple, io, &m, n);
    out("triple", "insert", ns, @intCast(m.count()));
    var d = keyedHit(Triple, triple, io, &m, n);
    out("triple", "hit", d.ns, d.check);
    d = keyedMiss(Triple, triple, io, &m, n);
    out("triple", "miss", d.ns, d.check);
}

/// "key" and `i`, built as Rig's `String("key", i)` is (`rig.String.add`).
fn key(i: usize) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &list);
    try w.writer.print("key{d}", .{i});
    return w.toArrayList();
}

const StdStrMap = std.StringHashMapUnmanaged(i64);

noinline fn stringsInsert(io: std.Io, m: *StdStrMap, put: []std.ArrayList(u8)) !i96 {
    const t = now(io);
    for (put, 0..) |k, i| try m.put(gpa, k.items, @intCast(i));
    return since(io, t);
}

noinline fn stringsHit(io: std.Io, m: *StdStrMap, look: []std.ArrayList(u8)) Timed {
    var sum: i64 = 0;
    const t = now(io);
    for (look) |k| if (m.get(k.items)) |v| {
        sum += v;
    };
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn stringsMiss(io: std.Io, m: *StdStrMap, miss: []std.ArrayList(u8)) Timed {
    var found: i64 = 0;
    const t = now(io);
    for (miss) |k| if (m.contains(k.items)) {
        found += 1;
    };
    return .{ .ns = since(io, t), .check = found };
}

noinline fn stringsIterate(io: std.Io, m: *StdStrMap) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var it = m.iterator();
    while (it.next()) |e| sum += e.value_ptr.*;
    return .{ .ns = since(io, t), .check = sum };
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
    var m: StdStrMap = .empty;
    const ns = try stringsInsert(io, &m, put);
    out("string", "insert", ns, m.count());
    var d = stringsHit(io, &m, look);
    out("string", "hit", d.ns, d.check);
    d = stringsMiss(io, &m, miss);
    out("string", "miss", d.ns, d.check);
    d = stringsIterate(io, &m);
    out("string", "iterate", d.ns, d.check);
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

noinline fn smallHit(io: std.Io, m: *StdIntMap, n: i64, size: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var i: i64 = 0;
    while (i < n) : (i += 1) if (m.get(@mod(i, size) *% mul)) |v| {
        sum += v;
    };
    return .{ .ns = since(io, t), .check = sum };
}

/// `n` hit lookups in a map of `size` Int keys.
fn small(io: std.Io, n: i64, size: i64) !void {
    var m: StdIntMap = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < size) : (i += 1) try m.put(gpa, i *% mul, i);
    const d = smallHit(io, &m, n, size);
    const keys = if (size == 4) "small 4" else "small 8";
    std.debug.print("{s} {d} {d}\n", .{ keys, d.ns, d.check });
}

noinline fn internWords(
    io: std.Io,
    ids: *std.StringHashMapUnmanaged(u32),
    arena: *std.ArrayList(u8),
    ends: *std.ArrayList(u32),
    words: []std.ArrayList(u8),
) !Timed {
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
    return .{ .ns = since(io, t), .check = @bitCast(sum) };
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
    const d = try internWords(io, &ids, &arena, &ends, words);
    out("string", "intern", d.ns, d.check);
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

const IntMap = table.Auto(i64, i64);

noinline fn sizedInsert(io: std.Io, maps: []IntMap, s: i64) !i96 {
    const t = now(io);
    for (maps, 0..) |*m, j| {
        const base = @as(i64, @intCast(j)) * s;
        var i: i64 = 0;
        while (i < s) : (i += 1) try m.put(gpa, (base + i) *% mul, i);
    }
    return since(io, t);
}

noinline fn sizedRemove(io: std.Io, maps: []IntMap, s: i64) Timed {
    var check: i64 = 0;
    const t = now(io);
    for (maps, 0..) |*m, j| {
        const base = @as(i64, @intCast(j)) * s;
        var i: i64 = 0;
        while (i < s) : (i += 1) if (m.fetchRemove((base + i) *% mul)) |e| {
            check += e.value;
        };
    }
    return .{ .ns = since(io, t), .check = check };
}

noinline fn sizedHit(io: std.Io, m: *IntMap, s: i64, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        var i: i64 = 0;
        while (i < s) : (i += 1) if (m.get(hide(i) *% mul)) |v| {
            sum += v;
        };
    }
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn sizedMiss(io: std.Io, m: *IntMap, s: i64, rounds: i64) Timed {
    var found: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        var i: i64 = s;
        while (i < 2 * s) : (i += 1) if (m.contains(hide(i) *% mul)) {
            found += 1;
        };
    }
    return .{ .ns = since(io, t), .check = found };
}

noinline fn sizedIterate(io: std.Io, m: *IntMap, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(m).iterator();
        while (it.next()) |e| sum += e.value_ptr.*;
    }
    return .{ .ns = since(io, t), .check = sum };
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
    const maps = try gpa.alloc(IntMap, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        for (maps) |*m| m.* = .empty;
        ins += try sizedInsert(io, maps, s);
        const d = sizedRemove(io, maps, s);
        rem += d.ns;
        check += d.check;
        keep(maps.ptr);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: IntMap = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < s) : (i += 1) try m.put(gpa, i *% mul, i);
    const rounds = @divTrunc(total, s);
    var d = sizedHit(io, &m, s, rounds);
    out(name, "hit", @divTrunc(d.ns * n, total), d.check);
    d = sizedMiss(io, &m, s, rounds);
    out(name, "miss", @divTrunc(d.ns * n, total), d.check);
    d = sizedIterate(io, &m, rounds);
    out(name, "iterate", @divTrunc(d.ns * n, total), d.check);
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

noinline fn randomInsert(io: std.Io, maps: []IntMap, keys: []const i64, su: usize) !i96 {
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (keys[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    }
    return since(io, t);
}

noinline fn randomRemove(io: std.Io, maps: []IntMap, keys: []const i64, su: usize) Timed {
    var check: i64 = 0;
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (keys[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
            check += e.value;
        };
    }
    return .{ .ns = since(io, t), .check = check };
}

noinline fn randomHit(io: std.Io, m: *IntMap, hit: []const i64, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(hit.ptr)[0..hit.len]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn randomMiss(io: std.Io, m: *IntMap, miss: []const i64, rounds: i64) Timed {
    var found: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(miss.ptr)[0..miss.len]) |x| if (m.contains(x)) {
            found += 1;
        };
    }
    return .{ .ns = since(io, t), .check = found };
}

noinline fn randomIterate(io: std.Io, m: *IntMap, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(m).iterator();
        while (it.next()) |e| sum += e.value_ptr.*;
    }
    return .{ .ns = since(io, t), .check = sum };
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
    const keys = try gpa.alloc(i64, @intCast(k * s));
    defer gpa.free(keys);
    for (keys, 0..) |*x, i| x.* = scatter(@intCast(i));
    const maps = try gpa.alloc(IntMap, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        for (maps) |*m| m.* = .empty;
        ins += try randomInsert(io, maps, keys, su);
        const d = randomRemove(io, maps, keys, su);
        rem += d.ns;
        check += d.check;
        keep(maps.ptr);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: IntMap = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    const hit = try gpa.dupe(i64, keys[0..su]);
    defer gpa.free(hit);
    shuffle(hit);
    const miss = try gpa.alloc(i64, su);
    defer gpa.free(miss);
    for (miss, 0..) |*x, i| x.* = scatter(8 * n + @as(i64, @intCast(i)));
    const rounds = @divTrunc(total, s);
    var d = randomHit(io, &m, hit, rounds);
    out(name, "hit", @divTrunc(d.ns * n, total), d.check);
    d = randomMiss(io, &m, miss, rounds);
    out(name, "miss", @divTrunc(d.ns * n, total), d.check);
    d = randomIterate(io, &m, rounds);
    out(name, "iterate", @divTrunc(d.ns * n, total), d.check);
}

/// `text(n)` of bench/hash/WORKLOADS.md: 7 to 27 bytes, distinct by
/// the part after `#`, in an allocation of its own.
fn text(n: i64) ![]u8 {
    const shift: u6 = @intCast(@mod(n, 48));
    // Formatted on the stack, then allocated once at its length, as
    // map.rs's `format!` and map.cc's `std::string` make one block a text;
    // an `allocPrint` grows and shrinks its buffer, which scatters them.
    var buf: [48]u8 = undefined;
    const t = try std.fmt.bufPrint(&buf, "{d}#{d}", .{ @as(u64, @bitCast(scatter(n))) >> shift, n });
    return gpa.dupe(u8, t);
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

noinline fn latencyChain(io: std.Io, m: *IntMap, first: i64, total: i64) Timed {
    var x = first;
    const t = now(io);
    var r: i64 = 0;
    while (r < total) : (r += 1) x = m.get(x).?;
    return .{ .ns = since(io, t), .check = x };
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
    var m: IntMap = .empty;
    defer m.deinit(gpa);
    // Each key `scatter(i)` is put in order of `i`, with the key after it
    // in the cycle as its value, so a map that keeps its entries in order
    // meets them out of order.
    const next = try gpa.alloc(i64, su);
    defer gpa.free(next);
    for (0..su) |t| next[@intCast(p[t])] = p[(t + 1) % su];
    for (0..su) |i| try m.put(gpa, scatter(@intCast(i)), scatter(next[i]));
    const d = latencyChain(io, &m, scatter(p[0]), total);
    out(name, "chain", @divTrunc(d.ns * n, total), d.check);
}

noinline fn churnTurnover(io: std.Io, m: *IntMap, keys: []const i64, s: i64, turns: i64) !Timed {
    var check: i64 = 0;
    const t = now(io);
    var i: i64 = 0;
    while (i < turns) : (i += 1) {
        if (m.fetchRemove(keys[@intCast(i)])) |e| check +%= e.value;
        try m.put(gpa, keys[@intCast(s + i)], s + i);
    }
    return .{ .ns = since(io, t), .check = check };
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
    var m: IntMap = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    const d = try churnTurnover(io, &m, keys, s, turns);
    keep(&m);
    out(name, "turnover", @divTrunc(d.ns * n, total), d.check);
}

noinline fn mixedHalf(io: std.Io, m: *IntMap, look: []const i64, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(look.ptr)[0..look.len]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    return .{ .ns = since(io, t), .check = sum };
}

/// Lookups that hit half the time, in shuffled order.
fn mixed(io: std.Io, s: i64) !void {
    const n: i64 = 1_000_000;
    const total: i64 = 4 * n;
    const su: usize = @intCast(s);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "mix{d}", .{s});
    var m: IntMap = .empty;
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
    const d = mixedHalf(io, &m, look, @divTrunc(total, s));
    out(name, "half", @divTrunc(d.ns * n, total), d.check);
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

noinline fn textsInsert(io: std.Io, maps: []StrMap, put: [][]u8, su: usize) !i96 {
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (put[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, @intCast(i));
    }
    return since(io, t);
}

noinline fn textsRemove(io: std.Io, maps: []StrMap, take: [][]u8, su: usize) Timed {
    var check: i64 = 0;
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (take[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
            gpa.free(e.key);
            check += e.value;
        };
    }
    return .{ .ns = since(io, t), .check = check };
}

noinline fn textsHit(io: std.Io, m: *StrMap, hit: [][]u8, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(hit.ptr)[0..hit.len]) |x| if (m.get(x)) |v| {
            sum += v;
        };
    }
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn textsMiss(io: std.Io, m: *StrMap, miss: [][]u8, rounds: i64) Timed {
    var found: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(miss.ptr)[0..miss.len]) |x| if (m.contains(x)) {
            found += 1;
        };
    }
    return .{ .ns = since(io, t), .check = found };
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
        ins += try textsInsert(io, maps, put, su);
        const d = textsRemove(io, maps, take, su);
        rem += d.ns;
        check += d.check;
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
    var d = textsHit(io, &m, hit, @divTrunc(n, s));
    out(name, "hit", d.ns, d.check);
    d = textsMiss(io, &m, miss, @divTrunc(n, s));
    out(name, "miss", d.ns, d.check);
}

const BigMap = table.Auto(i64, [8]i64);

noinline fn bigsInsert(io: std.Io, maps: []BigMap, keys: []const i64, su: usize) !i96 {
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (keys[j * su ..][0..su], 0..) |x, i| try m.put(gpa, x, big(@intCast(i)));
    }
    return since(io, t);
}

noinline fn bigsRemove(io: std.Io, maps: []BigMap, keys: []const i64, su: usize) Timed {
    var check: i64 = 0;
    const t = now(io);
    for (maps, 0..) |*m, j| {
        for (keys[j * su ..][0..su]) |x| if (m.fetchRemove(x)) |e| {
            check += e.value[7];
        };
    }
    return .{ .ns = since(io, t), .check = check };
}

noinline fn bigsHit(io: std.Io, m: *BigMap, hit: []const i64, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        for (hide(hit.ptr)[0..hit.len]) |x| if (m.getPtr(x)) |v| {
            sum += v[7];
        };
    }
    return .{ .ns = since(io, t), .check = sum };
}

noinline fn bigsIterate(io: std.Io, m: *BigMap, rounds: i64) Timed {
    var sum: i64 = 0;
    const t = now(io);
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        var it = hide(m).valueIterator();
        while (it.next()) |v| sum += v[0];
    }
    return .{ .ns = since(io, t), .check = sum };
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
    const keys = try gpa.alloc(i64, @intCast(k * s));
    defer gpa.free(keys);
    for (keys, 0..) |*x, i| x.* = scatter(@intCast(i));
    const maps = try gpa.alloc(BigMap, @intCast(k));
    defer gpa.free(maps);
    var ins: i96 = 0;
    var rem: i96 = 0;
    var check: i64 = 0;
    var r: i64 = 0;
    while (r < reps) : (r += 1) {
        for (maps) |*m| m.* = .empty;
        ins += try bigsInsert(io, maps, keys, su);
        const d = bigsRemove(io, maps, keys, su);
        rem += d.ns;
        check += d.check;
        keep(maps.ptr);
        for (maps) |*m| m.deinit(gpa);
    }
    out(name, "insert", @divTrunc(ins * n, total), reps * k * s);
    out(name, "remove", @divTrunc(rem * n, total), check);
    var m: BigMap = .empty;
    defer m.deinit(gpa);
    for (keys[0..su], 0..) |x, i| try m.put(gpa, x, big(@intCast(i)));
    const hit = try gpa.dupe(i64, keys[0..su]);
    defer gpa.free(hit);
    shuffle(hit);
    const rounds = @divTrunc(total, s);
    var d = bigsHit(io, &m, hit, rounds);
    out(name, "hit", @divTrunc(d.ns * n, total), d.check);
    d = bigsIterate(io, &m, rounds);
    out(name, "iterate", @divTrunc(d.ns * n, total), d.check);
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
    try pairs(io, @intCast(n));
    try triples(io, @intCast(n));
    // The rows only Rig and Zig's own HashMap time.
    if (!table.is_std) return;
    try ints(io, @intCast(n));
    try strings(io, n);
    try small(io, @intCast(n), 4);
    try small(io, @intCast(n), 8);
    try intern(io, n);
}
