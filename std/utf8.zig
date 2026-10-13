//! `std.utf8`: the panic of `push_rune`.

const std = @import("std");

pub fn not_code_point(c: i64) void {
    std.debug.panic("utf8.push_rune: {d} is a surrogate or outside 0 to 0x10FFFF", .{c});
}
