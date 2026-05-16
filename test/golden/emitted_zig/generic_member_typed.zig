const std = @import("std");

pub fn Box(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
    };
}

pub fn main() void {
    const b: Box(i32) = .{ .value = 5 };
    std.debug.print("{any}\n", .{ b.value });
}
