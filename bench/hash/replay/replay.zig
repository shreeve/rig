//! Replays a trace of map operations (bench/hash/replay/README.md, "The
//! trace") on the Zig table the module `table` names, as replay.rig and
//! the Rust arms do: one map per instance, values of 1, 2, 4 or 8 words.
//! Keys of a fixed width only (u32, int, pair, triple); a text trace is
//! refused. Prints `KIND NS OPS CHECK` per kind of segment and `total NS
//! OPS CHECK`; the checks must agree with every other arm's.
//!
//! `table.Map(K, V)` is a table with `empty`, `deinit(gpa)`, `count()`,
//! `getPtr(k)`, `put(gpa, k, v)`, `fetchRemove(k)` (a `.value`),
//! `valueIterator()`, and `clear(gpa)`, which drops every entry and may
//! keep the memory.
const std = @import("std");
const table = @import("table");
const gpa = table.allocator;

const PUT = 0;
const GET = 1;
const TAKE = 2;
const WALK = 3;
const CLEAR = 6;
const MIXED = 15;

const names = [16][]const u8{ "insert", "overwrite", "hit", "miss", "remove", "iterate", "new", "drop", "clear", "mixed", "mixed", "mixed", "mixed", "mixed", "mixed", "mixed" };

pub const Pair = struct { a: u64, b: u64 };
pub const Triple = struct { a: u64, b: u64, c: u64 };

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn since(io: std.Io, t: std.Io.Clock.Timestamp) i64 {
    return @intCast(t.durationTo(now(io)).raw.toNanoseconds());
}

fn u32At(d: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, d[at..][0..4], .little);
}

fn u64At(d: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, d[at..][0..8], .little);
}

const Ops = struct { op: []const u8, inst: []const u32, key: []const u32 };
const Row = struct { ns: i64, check: i64 };

fn Replay(comptime K: type, comptime N: usize) type {
    return struct {
        const V = [N]i64;
        const M = table.Map(K, V);

        inline fn value(j: usize) V {
            var v: V = undefined;
            inline for (0..N) |w| v[w] = @as(i64, @intCast(j)) + w;
            return v;
        }

        noinline fn putRun(io: std.Io, maps: []M, keys: []const K, o: Ops, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| {
                const m = &maps[o.inst[j]];
                m.put(gpa, keys[o.key[j]], value(j)) catch @panic("out of memory");
                check +%= @intCast(m.count());
            }
            return .{ .ns = since(io, t), .check = check };
        }

        noinline fn getRun(io: std.Io, maps: []M, keys: []const K, o: Ops, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| {
                if (maps[o.inst[j]].getPtr(keys[o.key[j]])) |v| check +%= v[0] + 1;
            }
            return .{ .ns = since(io, t), .check = check };
        }

        noinline fn takeRun(io: std.Io, maps: []M, keys: []const K, o: Ops, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| {
                if (maps[o.inst[j]].fetchRemove(keys[o.key[j]])) |kv| check +%= kv.value[N - 1] + 1;
            }
            return .{ .ns = since(io, t), .check = check };
        }

        fn walk(m: *const M) i64 {
            var check: i64 = 0;
            var it = m.valueIterator();
            while (it.next()) |v| check +%= v[0];
            return check +% @as(i64, @intCast(m.count()));
        }

        noinline fn walkRun(io: std.Io, maps: []M, o: Ops, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| check +%= walk(&maps[o.inst[j]]);
            return .{ .ns = since(io, t), .check = check };
        }

        fn life(m: *M, clear: bool) i64 {
            const c: i64 = @as(i64, @intCast(m.count())) + 1;
            if (clear) {
                m.clear(gpa);
            } else {
                m.deinit(gpa);
                m.* = .empty;
            }
            return c;
        }

        noinline fn lifeRun(io: std.Io, maps: []M, o: Ops, clear: bool, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| check +%= life(&maps[o.inst[j]], clear);
            return .{ .ns = since(io, t), .check = check };
        }

        noinline fn mixedRun(io: std.Io, maps: []M, keys: []const K, o: Ops, at: usize, n: usize) Row {
            var check: i64 = 0;
            const t = now(io);
            for (at..at + n) |j| {
                const m = &maps[o.inst[j]];
                switch (o.op[j]) {
                    GET => if (m.getPtr(keys[o.key[j]])) |v| {
                        check +%= v[0] + 1;
                    },
                    PUT => {
                        m.put(gpa, keys[o.key[j]], value(j)) catch @panic("out of memory");
                        check +%= @intCast(m.count());
                    },
                    TAKE => if (m.fetchRemove(keys[o.key[j]])) |kv| {
                        check +%= kv.value[N - 1] + 1;
                    },
                    WALK => check +%= walk(m),
                    CLEAR => check +%= life(m, true),
                    else => check +%= life(m, false),
                }
            }
            return .{ .ns = since(io, t), .check = check };
        }

        fn run(io: std.Io, keys: []const K, d: []const u8, out: *std.Io.Writer) !void {
            const instances = u32At(d, 12);
            const nops = u32At(d, 20);
            const nsegs = u32At(d, 24);
            var at: usize = u32At(d, 32);
            const op = d[at..][0..nops];
            at += (nops + 3) / 4 * 4;
            const inst = try gpa.alloc(u32, nops);
            for (inst, 0..) |*x, j| x.* = u32At(d, at + 4 * j);
            at += 4 * nops;
            const key = try gpa.alloc(u32, nops);
            for (key, 0..) |*x, j| x.* = u32At(d, at + 4 * j);
            at += 4 * nops;
            const o: Ops = .{ .op = op, .inst = inst, .key = key };
            const maps = try gpa.alloc(M, instances);
            for (maps) |*m| m.* = .empty;
            var ns: [16]i64 = @splat(0);
            var cnt: [16]usize = @splat(0);
            var chk: [16]i64 = @splat(0);
            for (0..nsegs) |s| {
                const kind = u32At(d, at + 12 * s);
                const from = u32At(d, at + 12 * s + 4);
                const count = u32At(d, at + 12 * s + 8);
                const r = switch (kind) {
                    0, 1 => putRun(io, maps, keys, o, from, count),
                    2, 3 => getRun(io, maps, keys, o, from, count),
                    4 => takeRun(io, maps, keys, o, from, count),
                    5 => walkRun(io, maps, o, from, count),
                    6, 7 => lifeRun(io, maps, o, false, from, count),
                    8 => lifeRun(io, maps, o, true, from, count),
                    else => mixedRun(io, maps, keys, o, from, count),
                };
                ns[kind] += r.ns;
                cnt[kind] += count;
                chk[kind] +%= r.check;
            }
            var tns: i64 = 0;
            var tchk: i64 = 0;
            for (0..16) |k| if (cnt[k] > 0) {
                try out.print("{s} {d} {d} {d}\n", .{ names[k], ns[k], cnt[k], chk[k] });
                tns += ns[k];
                tchk +%= chk[k];
            };
            try out.print("total {d} {d} {d}\n", .{ tns, nops, tchk });
        }
    };
}

fn byValue(comptime K: type, io: std.Io, keys: []const K, d: []const u8, out: *std.Io.Writer) !void {
    switch (u32At(d, 8)) {
        1 => try Replay(K, 1).run(io, keys, d, out),
        2 => try Replay(K, 2).run(io, keys, d, out),
        4 => try Replay(K, 4).run(io, keys, d, out),
        8 => try Replay(K, 8).run(io, keys, d, out),
        else => @panic("replay: values of 1, 2, 4 or 8 Ints"),
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.skip();
    const path = args.next() orelse @panic("usage: replay TRACE");
    const io = std.Io.Threaded.global_single_threaded.io();
    const d = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    if (d.len < 36 or u32At(d, 0) != 0x314c5052) @panic("replay: not a trace");
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    const n = u32At(d, 16);
    const at = 36;
    switch (u32At(d, 4)) {
        0 => {
            const ks = try gpa.alloc(u32, n);
            for (ks, 0..) |*k, i| k.* = u32At(d, at + 8 * i);
            try byValue(u32, io, ks, d, out);
        },
        1 => {
            const ks = try gpa.alloc(i64, n);
            for (ks, 0..) |*k, i| k.* = @bitCast(u64At(d, at + 8 * i));
            try byValue(i64, io, ks, d, out);
        },
        2 => {
            const ks = try gpa.alloc(Pair, n);
            for (ks, 0..) |*k, i| k.* = .{ .a = u64At(d, at + 16 * i), .b = u64At(d, at + 16 * i + 8) };
            try byValue(Pair, io, ks, d, out);
        },
        3 => {
            const ks = try gpa.alloc(Triple, n);
            for (ks, 0..) |*k, i| k.* = .{ .a = u64At(d, at + 24 * i), .b = u64At(d, at + 24 * i + 8), .c = u64At(d, at + 24 * i + 16) };
            try byValue(Triple, io, ks, d, out);
        },
        else => @panic("replay: the Zig arms take keys of a fixed width, not text"),
    }
    try out.flush();
}
