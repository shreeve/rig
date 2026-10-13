//! `std.text`: searching and comparing text (`?String`s) on Zig's `std.mem`,
//! and parsing numbers with `std.fmt`. A parse fails with the errors of
//! `std.text.ParseError`, which the emitter names
//! `error.@"std.text.ParseError.name"`.

const std = @import("std");

const ParseError = error{
    @"std.text.ParseError.invalid",
    @"std.text.ParseError.overflow",
};

pub fn empty_separator() void {
    @panic("text.split: the separator is empty");
}

pub fn find(s: []const u8, pat: []const u8) ?i64 {
    return @intCast(std.mem.find(u8, s, pat) orelse return null);
}

pub fn find_last(s: []const u8, pat: []const u8) ?i64 {
    return @intCast(std.mem.findLast(u8, s, pat) orelse return null);
}

pub fn count(s: []const u8, pat: []const u8) i64 {
    if (pat.len == 0) return @intCast(s.len + 1);
    return @intCast(std.mem.count(u8, s, pat));
}

pub fn bad_base(who: []const u8) void {
    var buf: [64]u8 = undefined;
    @panic(std.fmt.bufPrint(&buf, "{s}: the base is not between 2 and 36", .{who}) catch "text: the base is not between 2 and 36");
}

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

pub fn compare(a: []const u8, b: []const u8) i64 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}
