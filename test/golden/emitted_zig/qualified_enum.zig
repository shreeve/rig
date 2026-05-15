const std = @import("std");

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn main() void {
    const c: Color = Color.red;
    std.debug.print("{any}\n", .{ c });
}
