const std = @import("std");

pub fn Box(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
    };
}

pub fn main() void {
    const b: Box([]const u8) = .{ .value = "hi" };
    std.debug.print("{s}\n", .{ b.value });
}
