const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    name: []const u8,
    age: i32,
};

pub fn main() void {
    const u = User{ .name = "Steve", .age = 30 };
    std.debug.print("{s}\n", .{ u.name });
}
