//! `std.text`: searching text (`?String`s) 16 bytes at a time, comparing
//! it on Zig's `std.mem`, and parsing numbers with `std.fmt`. A parse fails with the errors of
//! `std.text.ParseError`, which the emitter names
//! `error.@"std.text.ParseError.name"`.

const std = @import("std");
const rig = @import("../runtime.zig");

const ParseError = error{
    @"std.text.ParseError.invalid",
    @"std.text.ParseError.overflow",
};

pub fn find(s: []const u8, pat: []const u8) ?i64 {
    return @intCast(search(s, pat) orelse return null);
}

pub fn find_last(s: []const u8, pat: []const u8) ?i64 {
    if (pat.len == 0) return @intCast(s.len);
    const at = if (pat.len == 1) searchLast(s, pat, true) else searchLast(s, pat, false);
    return @intCast(found(at) orelse return null);
}

pub fn count(s: []const u8, pat: []const u8) i64 {
    if (pat.len == 0) return @intCast(s.len + 1);
    var n: i64 = 0;
    var i: usize = 0;
    while (search(s[i..], pat)) |at| : (n += 1) i += at + pat.len;
    return n;
}

// ---- Searching -----------------------------------------------------------
//
// `search(h, n)` is the first index of `n` in `h`.
//
// A needle of one byte, the most common, is searched for in the first
// 4 KiB of `h` by Zig's `std.mem.findScalar`, inline where `find` is
// called, so a search for a constant byte that is near costs no call and
// is what Zig makes of it; past 4 KiB, on aarch64, `byteRest` tests 64
// bytes a step, asking only whether any of them is the byte
// (`rig.maskAny`), and elsewhere `findScalar` goes on.
//
// A longer needle is searched out of line. A place a match may start at
// is a candidate when two bytes of the needle match there, the bytes at
// its indexes `a` and `b`: two compares of 16 bytes, read at `i + a` and
// `i + b`, give the candidates among the places `i` to `i + 15`, and each
// candidate is confirmed by comparing the whole needle. `many` tests the
// first 256 places 32 at a time; `far` tests the rest 64 at a time, out
// of line, so a match near the start pays for none of its frame. Each
// asks first whether any place of the step is a candidate, and ends by
// testing the last 16 places again without those already tested, as
// `find_any` does. Near the start, and in a text of fewer than 64 KiB, `a`
// and `b` are the needle's first and last bytes; farther on, they are its
// two rarest bytes by `byte_rank`, which fewer places match, found by a
// walk over the needle that a long text pays for. A text of fewer than 16
// bytes is searched by `short`.

/// The masks of `rig.maskTrueLanes`: one bit per lane, lane `k` at bit
/// `k << shift`.
const Lanes = struct { bits: u64, shift: u6 };

const Block = @Vector(16, u8);

inline fn load(h: []const u8, i: usize) Block {
    return h[i..][0..16].*;
}

/// The index of a lane of `c`, which has one, counted from `i`.
inline fn lowest(i: usize, c: Lanes) usize {
    return i + (@as(usize, @ctz(c.bits)) >> c.shift);
}

/// Inline where `find` and `count` call it.
inline fn search(h: []const u8, n: []const u8) ?usize {
    if (n.len == 1) {
        if (!steps_of_64) return std.mem.findScalar(u8, h, n[0]);
        const first = @min(h.len, near_bytes);
        if (std.mem.findScalar(u8, h[0..first], n[0])) |at| return at;
        if (first == h.len) return null;
        return found(byteRest(h, n[0], first));
    }
    return found(searchMany(h, n));
}

/// Whether a needle of one byte is searched 64 bytes a step past
/// `near_bytes`: on aarch64, where it is faster than `std.mem.findScalar`;
/// on x86-64 `findScalar` is as fast, and searches the whole text.
const steps_of_64 = @import("builtin").cpu.arch == .aarch64;

/// The bytes `std.mem.findScalar` searches for a needle of one byte
/// before `byteRest` does.
const near_bytes = 4096;

/// What a search out of line returns for no match. Those functions
/// return a plain index, in a register: an optional comes back through
/// memory, written a field at a time and read whole, which on x86-64
/// waits for the stores (a failed store forward) on every match.
const missing = std.math.maxInt(usize);

inline fn found(at: usize) ?usize {
    return if (at == missing) null else at;
}

noinline fn byteRest(h: []const u8, b: u8, start: usize) usize {
    return byteFrom(h, b, start) orelse missing;
}

/// The first `b` in `h` from `start`, at least 16 bytes before its end.
inline fn byteFrom(h: []const u8, b: u8, start: usize) ?usize {
    const x: Block = @splat(b);
    var i = start;
    while (i + 64 <= h.len) : (i += 64) {
        const c0 = load(h, i) == x;
        const c1 = load(h, i + 16) == x;
        const c2 = load(h, i + 32) == x;
        const c3 = load(h, i + 48) == x;
        if (rig.maskAny((c0 | c1) | (c2 | c3))) {
            inline for (.{ c0, c1, c2, c3 }, 0..) |c, j| {
                const l = rig.maskTrueLanes(Lanes, c);
                if (l.bits != 0) return lowest(i + 16 * j, l);
            }
        }
    }
    while (i + 16 <= h.len) : (i += 16) {
        const c = rig.maskTrueLanes(Lanes, load(h, i) == x);
        if (c.bits != 0) return lowest(i, c);
    }
    if (i == h.len) return null;
    var c = rig.maskTrueLanes(Lanes, load(h, h.len - 16) == x);
    c.bits >>= @intCast((i + 16 - h.len) << c.shift);
    if (c.bits == 0) return null;
    return lowest(i, c);
}

noinline fn searchMany(h: []const u8, n: []const u8) usize {
    return many(h, n) orelse missing;
}

/// A needle of two bytes or more.
inline fn many(h: []const u8, n: []const u8) ?usize {
    if (n.len > h.len) return null;
    if (n.len == 0) return 0;
    if (h.len < 16) return short(h, n);
    const places = h.len - n.len + 1;
    if (places < 16) return head(h, n, places);
    const p = pairAt(n, 0, n.len - 1);
    var i: usize = 0;
    while (i < near_places and i + 32 <= places) : (i += 32) {
        const c0 = candidates(h, i, p);
        const c1 = candidates(h, i + 16, p);
        if (rig.maskAny(c0 | c1)) {
            if (confirm(h, n, i, rig.maskTrueLanes(Lanes, c0))) |at| return at;
            if (confirm(h, n, i + 16, rig.maskTrueLanes(Lanes, c1))) |at| return at;
        }
    }
    if (i + 32 <= places) return found(far(h, n, i));
    if (i + 16 <= places) {
        if (confirm(h, n, i, rig.maskTrueLanes(Lanes, candidates(h, i, p)))) |at| return at;
        i += 16;
    }
    return tail(h, n, i, places, p);
}

/// The places `searchMany` tests 32 at a time before it calls `far`.
const near_places = 256;

/// How many places from `far`'s start make the walk for the rarest
/// bytes worth its cost.
const rare_from = 1 << 16;

noinline fn far(h: []const u8, n: []const u8, start: usize) usize {
    return farFrom(h, n, start) orelse missing;
}

/// The places from `start` on, 64 at a time.
inline fn farFrom(h: []const u8, n: []const u8, start: usize) ?usize {
    const places = h.len - n.len + 1;
    const p = if (places - start >= rare_from) rarest(n) else pairAt(n, 0, n.len - 1);
    var i = start;
    while (i + 64 <= places) : (i += 64) {
        const c0 = candidates(h, i, p);
        const c1 = candidates(h, i + 16, p);
        const c2 = candidates(h, i + 32, p);
        const c3 = candidates(h, i + 48, p);
        if (rig.maskAny((c0 | c1) | (c2 | c3))) {
            inline for (.{ c0, c1, c2, c3 }, 0..) |c, j| {
                if (confirm(h, n, i + 16 * j, rig.maskTrueLanes(Lanes, c))) |at| return at;
            }
        }
    }
    while (i + 16 <= places) : (i += 16) {
        if (confirm(h, n, i, rig.maskTrueLanes(Lanes, candidates(h, i, p)))) |at| return at;
    }
    return tail(h, n, i, places, p);
}

/// The two bytes of the needle a candidate matches: `x`, the byte at
/// index `a`, and `y`, the byte at index `b`.
const Pair = struct { a: usize, b: usize, x: Block, y: Block };

fn pairAt(n: []const u8, a: usize, b: usize) Pair {
    return .{ .a = a, .b = b, .x = @splat(n[a]), .y = @splat(n[b]) };
}

/// The places `i` to `i + 15` where the pair matches.
inline fn candidates(h: []const u8, i: usize, p: Pair) @Vector(16, bool) {
    return (load(h, i + p.a) == p.x) & (load(h, i + p.b) == p.y);
}

/// The first of the candidates `c`, places from `i`, where the whole
/// needle matches.
inline fn confirm(h: []const u8, n: []const u8, i: usize, c: Lanes) ?usize {
    var bits = c.bits;
    while (bits != 0) : (bits &= bits - 1) {
        const at = i + (@as(usize, @ctz(bits)) >> c.shift);
        if (same(h[at..][0..n.len], n)) return at;
    }
    return null;
}

/// Fewer than 16 places from `i` to `places`: the last 16 places again,
/// without the lanes before `i`.
inline fn tail(h: []const u8, n: []const u8, i: usize, places: usize, p: Pair) ?usize {
    if (i == places) return null;
    const base = places - 16;
    var c = rig.maskTrueLanes(Lanes, candidates(h, base, p));
    c.bits >>= @intCast((i - base) << c.shift);
    return confirm(h, n, i, c);
}

/// Fewer than 16 places in a text of 16 bytes or more: the places where
/// the first byte matches, among the text's first 16 bytes.
inline fn head(h: []const u8, n: []const u8, places: usize) ?usize {
    var c = rig.maskTrueLanes(Lanes, load(h, 0) == @as(Block, @splat(n[0])));
    c.bits &= (@as(u64, 1) << @intCast(places << c.shift)) - 1;
    return confirm(h, n, 0, c);
}

/// A text of fewer than 16 bytes. A match at 0 is tested first, by
/// itself, as a vector compare would take longer to find it; then, in a
/// text of 8 bytes or more, the places where the first byte matches come
/// from two compares of 8 bytes, the first 8 bytes and the last, and in a
/// shorter one from a walk.
inline fn short(h: []const u8, n: []const u8) ?usize {
    if (same(h[0..n.len], n)) return 0;
    const places = h.len - n.len + 1;
    if (places == 1) return null;
    if (h.len < 8) {
        var i: usize = 1;
        while (i < places) : (i += 1) {
            if (h[i] == n[0] and same(h[i..][0..n.len], n)) return i;
        }
        return null;
    }
    const x: @Vector(8, u8) = @splat(n[0]);
    const lo: @Vector(8, u8) = h[0..8].*;
    var c = rig.maskTrueLanes(Lanes, lo == x);
    c.bits &= ~@as(u64, 1); // place 0, tested already
    if (places < 8) c.bits &= (@as(u64, 1) << @intCast(places << c.shift)) - 1;
    if (confirm(h, n, 0, c)) |at| return at;
    if (places <= 8) return null;
    // The places from 8 on, among the last 8 bytes, which begin at
    // `h.len - 8`: lane `j` is place `h.len - 8 + j`.
    const hi: @Vector(8, u8) = h[h.len - 8 ..][0..8].*;
    c = rig.maskTrueLanes(Lanes, hi == x);
    c.bits >>= @intCast((16 - h.len) << c.shift);
    c.bits &= (@as(u64, 1) << @intCast((places - 8) << c.shift)) - 1;
    return confirm(h, n, 8, c);
}

// ---- Searching from the end ---------------------------------------------
//
// `searchLast(h, n)` is the last index of `n` in `h`, the search above
// run backward: the places a match may start at are tested from the
// last one, 64 at a step and then 16, a place a candidate where the
// needle's first and last bytes match (where its one byte does), and a
// block's candidates confirmed from the highest. Fewer than 16 places
// left at the start are the first 16 places again, without those
// tested. Fewer than 16 places in all are walked one at a time.

noinline fn searchLast(h: []const u8, n: []const u8, comptime one: bool) usize {
    if (n.len > h.len) return missing;
    const places = h.len - n.len + 1;
    if (places < 16) {
        var i = places;
        while (i > 0) {
            i -= 1;
            if (h[i] == n[0] and same(h[i..][0..n.len], n)) return i;
        }
        return missing;
    }
    const p = pairAt(n, 0, n.len - 1);
    var i = places;
    while (i >= 64) {
        i -= 64;
        const c0 = hits(h, i, p, one);
        const c1 = hits(h, i + 16, p, one);
        const c2 = hits(h, i + 32, p, one);
        const c3 = hits(h, i + 48, p, one);
        if (rig.maskAny((c0 | c1) | (c2 | c3))) {
            inline for (.{ c3, c2, c1, c0 }, .{ 48, 32, 16, 0 }) |c, j| {
                if (confirmLast(h, n, i + j, rig.maskTrueLanes(Lanes, c))) |at| return at;
            }
        }
    }
    while (i >= 16) {
        i -= 16;
        if (confirmLast(h, n, i, rig.maskTrueLanes(Lanes, hits(h, i, p, one)))) |at| return at;
    }
    if (i == 0) return missing;
    var c = rig.maskTrueLanes(Lanes, hits(h, 0, p, one));
    c.bits &= (@as(u64, 1) << @intCast(i << c.shift)) - 1;
    return confirmLast(h, n, 0, c) orelse missing;
}

/// The places `i` to `i + 15` where the pair matches; for a needle of
/// one byte, where it does.
inline fn hits(h: []const u8, i: usize, p: Pair, comptime one: bool) @Vector(16, bool) {
    return if (one) load(h, i) == p.x else candidates(h, i, p);
}

/// The last of the candidates `c`, places from `i`, where the whole
/// needle matches.
inline fn confirmLast(h: []const u8, n: []const u8, i: usize, c: Lanes) ?usize {
    var bits = c.bits;
    while (bits != 0) {
        const lane = @as(usize, 63 - @clz(bits)) >> c.shift;
        if (same(h[i + lane ..][0..n.len], n)) return i + lane;
        bits &= (@as(u64, 1) << @intCast(lane << c.shift)) - 1;
    }
    return null;
}

/// Whether `a` and `b`, of one length, hold the same bytes: words of 8
/// bytes, the last one overlapping, or of 4, or 3 single bytes; inline,
/// so a search that calls no function keeps its vectors in registers.
inline fn same(a: []const u8, b: []const u8) bool {
    const len = b.len;
    if (len >= 8) {
        var i: usize = 0;
        while (i + 8 < len) : (i += 8) {
            if (word(u64, a, i) != word(u64, b, i)) return false;
        }
        return word(u64, a, len - 8) == word(u64, b, len - 8);
    }
    if (len >= 4) return word(u32, a, 0) == word(u32, b, 0) and word(u32, a, len - 4) == word(u32, b, len - 4);
    return a[0] == b[0] and a[len / 2] == b[len / 2] and a[len - 1] == b[len - 1];
}

inline fn word(comptime T: type, s: []const u8, i: usize) T {
    return @bitCast(s[i..][0..@sizeOf(T)].*);
}

/// The needle's two rarest bytes by `byte_rank`, at different indexes.
fn rarest(n: []const u8) Pair {
    var a: usize = 0;
    var b: usize = 1;
    if (byte_rank[n[1]] < byte_rank[n[0]]) {
        a = 1;
        b = 0;
    }
    for (n[2..], 2..) |c, j| {
        const r = byte_rank[c];
        if (r < byte_rank[n[a]]) {
            b = a;
            a = j;
        } else if (r < byte_rank[n[b]]) b = j;
    }
    return pairAt(n, a, b);
}

/// Each byte's place among the 256 by how often it occurs in Rig's own
/// sources (`src/*.zig`, `docs/*.md`, `std/*.rig`): 0 for the rarest,
/// 255 for the most common (the space).
const byte_rank: [256]u8 = .{
    0,   1,   2,   3,   4,   5,   6,   7,   8,   9,   244, 10,  11,  12,  13,  14,
    15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,
    255, 211, 218, 176, 165, 167, 184, 201, 237, 236, 204, 182, 239, 217, 245, 233,
    213, 203, 197, 188, 187, 175, 190, 170, 200, 171, 223, 229, 177, 232, 207, 196,
    206, 212, 183, 205, 174, 202, 193, 169, 172, 210, 164, 178, 192, 179, 186, 199,
    198, 161, 191, 214, 216, 173, 180, 181, 163, 158, 168, 209, 195, 208, 166, 220,
    230, 250, 228, 243, 242, 254, 241, 226, 235, 247, 194, 219, 246, 234, 249, 248,
    238, 185, 251, 252, 253, 240, 225, 227, 224, 231, 189, 222, 215, 221, 162, 31,
    156, 132, 32,  33,  34,  35,  154, 146, 36,  37,  38,  139, 39,  144, 40,  140,
    41,  148, 155, 42,  147, 43,  44,  133, 141, 45,  46,  47,  48,  49,  50,  151,
    51,  52,  53,  54,  55,  56,  153, 159, 134, 149, 57,  142, 58,  59,  60,  61,
    62,  63,  130, 64,  65,  135, 131, 143, 66,  67,  68,  69,  70,  145, 71,  136,
    72,  73,  160, 150, 74,  75,  76,  77,  78,  79,  80,  81,  137, 82,  83,  84,
    85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  96,  97,  98,  99,  100,
    101, 102, 157, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 138,
    152, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129,
};

/// The value of each byte as a digit: `0` to `9`, then the letters `a`
/// to `z` in either case for 10 to 35, and 36 for any other byte.
const digit_values: [256]u8 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u8 = @splat(36);
    for (0..10) |d| t['0' + d] = d;
    for (0..26) |d| {
        t['a' + d] = 10 + d;
        t['A' + d] = 10 + d;
    }
    break :blk t;
};

/// For each base, how many digits never overflow an `i64`: the most `n`
/// with `base^n - 1 <= maxInt(i64)`.
const safe_digits: [37]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [37]u8 = @splat(0);
    for (2..37) |base| {
        var n: u8 = 0;
        var max: u128 = base - 1; // the largest number of n + 1 digits
        while (max <= std.math.maxInt(i64)) : (max = max * base + base - 1) n += 1;
        t[base] = n;
    }
    break :blk t;
};

/// One pass over the digits. Up to `safe_digits[base]` of them cannot
/// overflow, so they are read with no overflow check; longer runs go to
/// `parseLong`. The function stays small, so LLVM inlines it into a hot
/// loop, where the error folds into the caller's `catch`.
pub fn parse_radix(s: []const u8, base: i64) ParseError!i64 {
    const b: u64 = @bitCast(base);
    var digits = s;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        digits = s[1..];
    }
    if (digits.len == 0) return error.@"std.text.ParseError.invalid";
    if (digits.len > safe_digits[@intCast(b)]) return parseLong(digits, b, negative);
    var acc: u64 = 0;
    for (digits) |c| {
        const d = digit_values[c];
        if (d >= b) return error.@"std.text.ParseError.invalid";
        acc = acc *% b +% d;
    }
    const value: i64 = @bitCast(acc);
    return if (negative) 0 -% value else value;
}

/// `digits`, more than `safe_digits[base]` of them, in base `base`, with
/// overflow checked; negative for `negative`, which reaches `minInt(i64)`.
/// A bad digit anywhere makes them invalid, even after an overflow.
fn parseLong(digits: []const u8, base: u64, negative: bool) ParseError!i64 {
    @branchHint(.unlikely);
    var acc: u64 = 0;
    var over = false;
    for (digits) |c| {
        const d = digit_values[c];
        if (d >= base) return error.@"std.text.ParseError.invalid";
        const scaled = @mulWithOverflow(acc, base);
        const next = @addWithOverflow(scaled[0], d);
        over = over or scaled[1] != 0 or next[1] != 0;
        acc = next[0];
    }
    const limit: u64 = if (negative) 1 << 63 else std.math.maxInt(i64);
    if (over or acc > limit) return error.@"std.text.ParseError.overflow";
    return if (negative) @bitCast(0 -% acc) else @bitCast(acc);
}

pub fn parse_float(s: []const u8) ParseError!f64 {
    // `std.fmt` also reads hexadecimal floats and `_` between digits.
    const rest = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
    if (std.mem.findScalar(u8, rest, '_') != null) return error.@"std.text.ParseError.invalid";
    if (rest.len >= 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) return error.@"std.text.ParseError.invalid";
    const x = std.fmt.parseFloat(f64, s) catch return error.@"std.text.ParseError.invalid";
    if (std.math.isInf(x) and std.ascii.toLower(rest[0]) != 'i') return error.@"std.text.ParseError.overflow";
    return x;
}
