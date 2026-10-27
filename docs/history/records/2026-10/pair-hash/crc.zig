// crc.zig: a two-word key hashed by one folded multiply (std.hash's
// runtime) or by abseil's two parallel CRC32s, inside a dependent
// table-index chain (latency) and over independent keys (throughput),
// plus the slot spread of Trig-shaped packed keys.
const std = @import("std");

inline fn foldMul(a: u64, b: u64) u64 {
    const p = @as(u128, a) * b;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}
const seed: u64 = 0x2d358dccaa6c78a5;
const pair: u64 = 0x9e3779b97f4a7c15;
inline fn hfold(lo: u64, hi: u64) u64 {
    return foldMul(lo ^ seed, hi ^ pair);
}
inline fn crc32q(c: u32, v: u64) u32 {
    var x: u64 = c;
    asm ("crc32q %[v], %[x]"
        : [x] "+r" (x),
        : [v] "rm" (v),
    );
    return @truncate(x);
}
inline fn combine(state: u64, v: u64) u64 {
    const lo: u32 = @truncate(state);
    const hi: u32 = @truncate(state >> 32);
    return (@as(u64, crc32q(hi, v)) << 32) | crc32q(lo, v *% 3);
}
inline fn hcrc(lo: u64, hi: u64) u64 {
    return combine(combine(seed, lo), hi);
}

fn now() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn main() !void {
    const N = 1 << 16;
    var table: [N]u32 = undefined;
    var r: u64 = 1;
    for (&table) |*t| {
        r = r *% 6364136223846793005 +% 1442695040888963407;
        t.* = @truncate(r >> 33);
    }
    const iters = 50_000_000;
    inline for (.{ "fold", "crc" }) |name| {
        const H = if (comptime std.mem.eql(u8, name, "fold")) hfold else hcrc;
        // latency: each key depends on the last load
        var t0 = now();
        var k: u64 = 7;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const h = H((k << 32) | (i & 0xffff), 3);
            k = table[h & (N - 1)];
        }
        const lat = @as(f64, @floatFromInt(now() - t0)) / iters;
        // throughput
        t0 = now();
        var acc: u64 = 0;
        i = 0;
        while (i < iters) : (i += 1) acc +%= table[H((i >> 10) << 32 | (i & 1023), 0xA5C4000000000000) & (N - 1)];
        const thr = @as(f64, @floatFromInt(now() - t0)) / iters;
        // spread: packed keys into 2^17 slots, count distinct slots and tags
        var hits = std.mem.zeroes([1 << 17]u8);
        var used: usize = 0;
        var s: u64 = 0;
        while (s < 100000) : (s += 1) {
            const h = H(((s % 317) << 32) | (s / 317), 0);
            const slot = h & ((1 << 17) - 1);
            if (hits[slot] == 0) used += 1;
            hits[slot] +|= 1;
        }
        std.debug.print("{s}: latency {d:.2} ns, throughput {d:.2} ns, 100000 packed keys in {d} of 131072 slots, check {d} {d}\n", .{ name, lat, thr, used, k, acc });
    }
}
