//! `std.bigint`: the panics of its misused arguments, which Rig code has
//! no way to raise itself.

const std = @import("std");

pub fn bad_base() void {
    @panic("bigint.parse: the base is not 0 or between 2 and 36");
}

pub fn negative_shift(who: []const u8) void {
    var buf: [64]u8 = undefined;
    @panic(std.fmt.bufPrint(&buf, "{s}: the shift is negative", .{who}) catch "bigint: the shift is negative");
}

pub fn negative_power() void {
    @panic("bigint.pow: the power is negative");
}
