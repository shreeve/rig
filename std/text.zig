//! `std.text`: searching and comparing Strings on Zig's `std.mem`,
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

/// `s` without its sign, when every byte after it is a digit and there
/// is one; `std.fmt` would also take `_` between digits.
fn digits(s: []const u8) ?[]const u8 {
    const rest = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
    if (rest.len == 0) return null;
    for (rest) |c| if (!std.ascii.isDigit(c)) return null;
    return rest;
}

pub fn parse_int(s: []const u8) ParseError!i64 {
    _ = digits(s) orelse return error.@"std.text.ParseError.invalid";
    return std.fmt.parseInt(i64, s, 10) catch |err| switch (err) {
        error.Overflow => error.@"std.text.ParseError.overflow",
        error.InvalidCharacter => error.@"std.text.ParseError.invalid",
    };
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
