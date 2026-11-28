//! The text search sweep: the time of one search by the haystack's
//! length, 1 to 256 bytes, for each way std.text could search it, so
//! the lengths where one way starts to beat another can be read off and
//! set as std/text.zig's tiers; then 320 bytes to 4 KiB, the lengths
//! `far` searches. The ways:
//!
//!   scalar  a byte loop: each place whose first byte matches is confirmed
//!   swar    8 places a step in a `u64`, the first and last bytes' matches
//!           found by the zero-byte test of the word xor the byte
//!   v8      8 places a step, `@Vector(8, u8)` compares
//!   v16     16 places a step, `@Vector(16, u8)`
//!   v32     32 places a step, `@Vector(32, u8)` (x86-64 with AVX2 only)
//!   v64     64 places a step, `@Vector(64, u8)` (x86-64 with AVX-512BW only)
//!   zig     `std.mem.findScalar`, for a needle of one byte only
//!
//! A vector way needs a whole vector of text, so it is shown only from
//! its width; each ends as std/text.zig's searches do, with the last
//! vector of places again, without the places already tested, and a
//! text of fewer places than lanes tests the first byte of its first
//! vector. The masks are the runtime's (`rig.maskTrueLanes`), as
//! std/text.zig's are. Each needle, of 1 or of 4 bytes, is searched for
//! where it is the text's last bytes (`end`) and where it is not there
//! (`miss`, its first and last bytes ones the text has). Each row
//! searches 256 windows of a text made in the manner of lib.dom.d.ts,
//! at varied offsets; its time is the fastest of the interleaved
//! rounds, in nanoseconds per search.
//!
//!     zig run -O ReleaseFast -mcpu=native --dep runtime -Mroot=bench/text/sweep.zig -Mruntime=src/runtime.zig
//!
//! `-- check` after it instead tests every way against the byte loop
//! on every length, needle, and window.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime");

const Lanes = struct { bits: u64, shift: u6 };
const missing = std.math.maxInt(usize);

const Way = enum { scalar, swar, v8, v16, v32, v64, zig };
const x86 = builtin.cpu.arch == .x86_64;
const avx2 = x86 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
const avx512 = x86 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw);
const ways = if (avx512)
    [_]Way{ .scalar, .swar, .v8, .v16, .v32, .v64, .zig }
else if (avx2)
    [_]Way{ .scalar, .swar, .v8, .v16, .v32, .zig }
else
    [_]Way{ .scalar, .swar, .v8, .v16, .zig };

const windows = 256;
const stride = 4352;
const reps = 40;
const rounds = 21;

var text: [1 << 17]u8 = undefined;
var hay: [windows * stride]u8 = undefined;
var needles: [windows][4]u8 = undefined;

const words = [_][]const u8{
    "interface ",  "readonly ", "string",  "number",           "boolean", "void",     "(",           ")",     ": ",   ";\n",
    "    ",        "HTMLElement", "Event", "extends ",         "addEventListener", "options", "type ", "<K>", "this", "listener",
    " | ",         "undefined", "[]",      "name",             "value",   "declare ", "var ",        "new ",  "prototype", "{\n",
    "}\n",         "Element",   "Node",    "Document",         "Window",  "readonly length: number;\n",
};

fn makeText() void {
    var x: u64 = 5;
    var n: usize = 0;
    while (n < text.len) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const w = words[@intCast(((x >> 33) & 0x7FFFFFFF) % words.len)];
        for (w) |c| {
            if (n == text.len) break;
            text[n] = c;
            n += 1;
        }
    }
}

const Case = enum { end, miss };

/// Fills each window with `len` bytes of the text and its needle of `k`
/// bytes: the window's last bytes, a middle one made 0x02 in both, for
/// `end`; bytes from its middle with one made 0x01, which the text never
/// has, for `miss`. Byte 0x02 is in no window but there.
fn prepare(len: usize, k: usize, case: Case) void {
    for (0..windows) |w| {
        const off = (w * 7919) % (text.len - stride);
        const h = hay[w * stride ..][0..len];
        @memcpy(h, text[off..][0..len]);
        const n = needles[w][0..k];
        switch (case) {
            .end => {
                @memcpy(n, h[len - k ..]);
                n[k / 2] = 0x02;
                h[len - k + k / 2] = 0x02;
            },
            .miss => {
                const at = (len - k) / 2;
                @memcpy(n, h[at..][0..k]);
                n[k / 2] = 0x01;
            },
        }
    }
}

inline fn same(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

inline fn confirm(h: []const u8, n: []const u8, i: usize, c: Lanes) usize {
    var bits = c.bits;
    while (bits != 0) : (bits &= bits - 1) {
        const at = i + (@as(usize, @ctz(bits)) >> c.shift);
        if (same(h[at..][0..n.len], n)) return at;
    }
    return missing;
}

fn scalar(h: []const u8, n: []const u8) usize {
    @setRuntimeSafety(false);
    if (n.len > h.len) return missing;
    const places = h.len - n.len + 1;
    var i: usize = 0;
    while (i < places) : (i += 1) {
        if (h[i] == n[0] and same(h[i..][0..n.len], n)) return i;
    }
    return missing;
}

const ones: u64 = 0x0101_0101_0101_0101;
const highs: u64 = 0x8080_8080_8080_8080;

/// 0x80 in each byte of `x` that is 0, and 0 elsewhere, exactly.
inline fn zeroBytes(x: u64) u64 {
    const lows = ~highs;
    return ~(((x & lows) +% lows) | x | lows);
}

inline fn word(h: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, h[i..][0..8], .little);
}

/// The places `i` to `i + 7` whose first and last bytes match: one bit
/// per place, at bit `8j + 7`.
inline fn swarCandidates(h: []const u8, i: usize, n: []const u8) u64 {
    var m = zeroBytes(word(h, i) ^ (ones *% n[0]));
    if (n.len > 1) m &= zeroBytes(word(h, i + n.len - 1) ^ (ones *% n[n.len - 1]));
    return m;
}

fn swar(h: []const u8, n: []const u8) usize {
    @setRuntimeSafety(false);
    if (n.len > h.len) return missing;
    const places = h.len - n.len + 1;
    if (places < 8) return scalar(h, n);
    var i: usize = 0;
    while (i + 8 <= places) : (i += 8) {
        const at = confirm(h, n, i, .{ .bits = swarCandidates(h, i, n) >> 7, .shift = 3 });
        if (at != missing) return at;
    }
    if (i == places) return missing;
    const base = places - 8;
    const m = (swarCandidates(h, base, n) >> 7) >> @intCast((i - base) * 8);
    return confirm(h, n, i, .{ .bits = m, .shift = 3 });
}

fn lanes(comptime w: usize, h: []const u8, n: []const u8) usize {
    @setRuntimeSafety(false);
    const V = @Vector(w, u8);
    if (n.len > h.len) return missing;
    const places = h.len - n.len + 1;
    const x: V = @splat(n[0]);
    const y: V = @splat(n[n.len - 1]);
    var i: usize = 0;
    while (i + w <= places) : (i += w) {
        const c = (@as(V, h[i..][0..w].*) == x) & (@as(V, h[i + n.len - 1 ..][0..w].*) == y);
        const at = confirm(h, n, i, rt.maskTrueLanes(Lanes, c));
        if (at != missing) return at;
    }
    if (i == places) return missing;
    if (places >= w) {
        const base = places - w;
        const c = (@as(V, h[base..][0..w].*) == x) & (@as(V, h[base + n.len - 1 ..][0..w].*) == y);
        var l = rt.maskTrueLanes(Lanes, c);
        l.bits >>= @intCast((i - base) << l.shift);
        return confirm(h, n, i, l);
    }
    // Fewer places than lanes in a text of a vector or more: the first
    // byte's matches among the first vector, those that are places.
    var l = rt.maskTrueLanes(Lanes, @as(V, h[0..w].*) == x);
    l.bits &= (@as(u64, 1) << @intCast(places << l.shift)) - 1;
    return confirm(h, n, 0, l);
}

inline fn search(comptime way: Way, h: []const u8, n: []const u8) usize {
    return switch (way) {
        .scalar => scalar(h, n),
        .swar => swar(h, n),
        .v8 => lanes(8, h, n),
        .v16 => lanes(16, h, n),
        .v32 => lanes(32, h, n),
        .v64 => lanes(64, h, n),
        .zig => std.mem.findScalar(u8, h, n[0]) orelse missing,
    };
}

fn applies(way: Way, len: usize, k: usize) bool {
    return switch (way) {
        .scalar, .swar => true,
        .v8 => len >= 8,
        .v16 => len >= 16,
        .v32 => len >= 32,
        .v64 => len >= 64,
        .zig => k == 1,
    };
}

/// A value the optimizer cannot see through.
inline fn opaqueValue(x: usize) usize {
    var y = x;
    std.mem.doNotOptimizeAway(&y);
    return @as(*volatile usize, &y).*;
}

fn timeOne(io: std.Io, comptime way: Way, len_in: usize, k_in: usize) u64 {
    const len = opaqueValue(len_in);
    const k = opaqueValue(k_in);
    var sum: usize = 0;
    const t0 = std.Io.Clock.awake.now(io);
    for (0..reps) |_| {
        for (0..windows) |w| {
            sum +%= search(way, hay[w * stride ..][0..len], needles[w][0..k]);
        }
    }
    const ns = t0.untilNow(io, .awake).toNanoseconds();
    std.mem.doNotOptimizeAway(sum);
    return @intCast(ns);
}

const lengths = blk: {
    const long = [_]usize{ 320, 384, 512, 768, 1024, 2048, 4096 };
    var out: [64 + 24 + long.len]usize = undefined;
    for (0..64) |j| out[j] = j + 1;
    for (0..24) |j| out[64 + j] = 72 + 8 * j;
    for (long, 0..) |n, j| out[88 + j] = n;
    break :blk out;
};

const check_lengths = blk: {
    var out: [256 + 7]usize = undefined;
    for (0..256) |j| out[j] = j + 1;
    for (lengths[88..], 0..) |n, j| out[256 + j] = n;
    break :blk out;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    makeText();
    const check = args.len > 1 and std.mem.eql(u8, args[1], "check");
    var out_buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const out = &fw.interface;
    if (check) {
        var tested: usize = 0;
        for (check_lengths) |len| for ([_]usize{ 1, 2, 3, 4 }) |k| for ([_]Case{ .end, .miss }) |case| {
            if (k > len) continue;
            if (case == .miss and k == 1 and len < 1) continue;
            prepare(len, k, case);
            inline for (ways) |way| {
                if (applies(way, len, k)) for (0..windows) |w| {
                    const h = hay[w * stride ..][0..len];
                    const n = needles[w][0..k];
                    const want = scalar(h, n);
                    const got = search(way, h, n);
                    if (got != want) {
                        try out.print("{s} len {d} k {d} {s} window {d}: {d}, want {d}\n", .{ @tagName(way), len, k, @tagName(case), w, got, want });
                        try out.flush();
                        std.process.exit(1);
                    }
                    tested += 1;
                };
            }
        };
        try out.print("check: {d} searches agree with the byte loop\n", .{tested});
        return out.flush();
    }
    try out.print("{s} {s}, ns per search, fastest of {d} rounds\n", .{ @tagName(builtin.cpu.arch), builtin.cpu.model.name, rounds });
    try out.print("{s:>4} {s:>2} {s:>4}", .{ "len", "k", "case" });
    inline for (ways) |way| try out.print(" {s:>7}", .{@tagName(way)});
    try out.print("  fastest\n", .{});
    for ([_]usize{ 1, 4 }) |k| for ([_]Case{ .end, .miss }) |case| for (lengths) |len| {
        if (k > len) continue;
        prepare(len, k, case);
        var best: [ways.len]u64 = @splat(std.math.maxInt(u64));
        for (0..rounds) |_| {
            inline for (ways, 0..) |way, j| {
                if (applies(way, len, k)) best[j] = @min(best[j], timeOne(io, way, len, k));
            }
        }
        try out.print("{d:>4} {d:>2} {s:>4}", .{ len, k, @tagName(case) });
        var fastest: usize = 0;
        inline for (ways, 0..) |way, j| {
            if (applies(way, len, k)) {
                const ns = @as(f64, @floatFromInt(best[j])) / (reps * windows);
                try out.print(" {d:>7.2}", .{ns});
                if (best[j] < best[fastest] or !applies(ways[fastest], len, k)) fastest = j;
            } else try out.print(" {s:>7}", .{"-"});
        }
        try out.print("  {s}\n", .{@tagName(ways[fastest])});
        try out.flush();
    };
}
