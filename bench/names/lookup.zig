//! `rig.NameTable.find`, the lookup behind `E.from_text(word)`, timed
//! against comparing the names one by one, the way it would be built
//! without a table. For each count of names it prints `NAMES WAY OP NS`:
//! the nanoseconds of one lookup that hits (a name of the set) or misses
//! (a word of a name's length that is not one), the fastest of several
//! runs. See bench/names/README.md.
const std = @import("std");
const nametable = @import("nametable");

const NameTable = nametable.NameTable;
const queries = 4096;
const rounds = 400;
const runs = 7;

/// A word like a variant's name: 3 to 12 lowercase letters and `_`.
fn word(a: std.mem.Allocator, rng: std.Random) ![]u8 {
    const len = rng.intRangeAtMost(usize, 3, 12);
    const w = try a.alloc(u8, len);
    for (w, 0..) |*c, i| c.* = if (i > 0 and i + 1 < len and rng.uintLessThan(u8, 6) == 0) '_' else 'a' + rng.uintLessThan(u8, 26);
    return w;
}

fn has(names: []const []const u8, w: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, w)) return true;
    return false;
}

const Way = enum { linear, hashed };

fn find(way: Way, t: NameTable, w: []const u8) ?u32 {
    return switch (way) {
        .hashed => t.find(w),
        .linear => for (t.names, 0..) |name, i| {
            if (std.mem.eql(u8, name, w)) break @intCast(i);
        } else null,
    };
}

/// The nanoseconds of one lookup of each word of `words`, the fastest of
/// `runs`.
fn time(io: std.Io, comptime way: Way, t: NameTable, words: []const []const u8) f64 {
    var best: f64 = std.math.inf(f64);
    for (0..runs) |_| {
        var found: u64 = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..rounds) |_| for (words) |w| {
            if (find(way, t, w)) |id| found +%= id + 1;
            std.mem.doNotOptimizeAway(found);
        };
        const ns: f64 = @floatFromInt(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds());
        best = @min(best, ns / @as(f64, @floatFromInt(rounds * words.len)));
    }
    return best;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();
    for ([_]usize{ 2, 3, 4, 6, 8, 12, 16, 32, 64, 256 }) |n| {
        var names: std.ArrayList([]const u8) = .empty;
        while (names.items.len < n) {
            const w = try word(a, rng);
            if (!has(names.items, w)) try names.append(a, w);
        }
        // Each query in a buffer of its own, as a word read from input is.
        const hits = try a.alloc([]const u8, queries);
        for (hits) |*q| q.* = try a.dupe(u8, names.items[rng.uintLessThan(usize, n)]);
        const misses = try a.alloc([]const u8, queries);
        for (misses) |*q| {
            const len = names.items[rng.uintLessThan(usize, n)].len;
            while (true) {
                const w = try a.alloc(u8, len);
                for (w) |*c| c.* = 'a' + rng.uintLessThan(u8, 26);
                if (has(names.items, w)) continue;
                q.* = w;
                break;
            }
        }
        const built = try nametable.build(a, names.items);
        const t: NameTable = .{ .names = names.items, .tags = built.tags, .slots = built.slots };
        inline for (.{ Way.linear, Way.hashed }) |way| {
            std.debug.print("{d} {s} hit {d:.2}\n", .{ n, @tagName(way), time(io, way, t, hits) });
            std.debug.print("{d} {s} miss {d:.2}\n", .{ n, @tagName(way), time(io, way, t, misses) });
        }
    }
}
