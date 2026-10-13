//! `std.text`: searching and comparing text (`?String`s) on Zig's `std.mem`,
//! parsing numbers with `std.fmt`, and checking UTF-8 with
//! `std.unicode`. A parse fails with the errors of `std.text.ParseError`,
//! which the emitter names `error.@"std.text.ParseError.name"`.

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

pub fn parse_radix(s: []const u8, base: i64) ParseError!i64 {
    const radix: u8 = @intCast(base);
    const digits = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
    if (digits.len == 0) return error.@"std.text.ParseError.invalid";
    for (digits) |c| _ = std.fmt.charToDigit(c, radix) catch return error.@"std.text.ParseError.invalid";
    // Accumulate below zero, which holds `Int.min`.
    var acc: i64 = 0;
    for (digits) |c| {
        const d: i64 = std.fmt.charToDigit(c, radix) catch unreachable;
        const scaled = @mulWithOverflow(acc, base);
        const next = @subWithOverflow(scaled[0], d);
        if (scaled[1] != 0 or next[1] != 0) return error.@"std.text.ParseError.overflow";
        acc = next[0];
    }
    if (s[0] == '-') return acc;
    if (acc == std.math.minInt(i64)) return error.@"std.text.ParseError.overflow";
    return -acc;
}

pub fn decode_rune(s: []const u8, i: i64) i64 {
    const at: usize = @intCast(i);
    const bad = 0xFFFD * 8 + 1;
    const n = std.unicode.utf8ByteSequenceLength(s[at]) catch return bad;
    if (at + n > s.len) return bad;
    const c = std.unicode.utf8Decode(s[at .. at + n]) catch return bad;
    return @as(i64, c) * 8 + n;
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

pub fn valid_utf8(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

pub fn compare(a: []const u8, b: []const u8) i64 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}
