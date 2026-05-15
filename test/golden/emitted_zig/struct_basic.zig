const std = @import("std");

pub const User = struct {
    name: []const u8,
    age: i32,
};

pub fn main() void {
    const u = User{ .name = "Steve", .age = 30 };
    std.debug.print("{s}\n", .{ u.name });
}
