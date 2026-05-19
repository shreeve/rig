const std = @import("std");
const rig = @import("_runtime.zig");

pub const User = struct {
    name: []const u8,

    pub fn greet(self: User) []const u8 {
        return self.name;
    }
};

pub fn main() void {
    const u = User{ .name = "Steve" };
    std.debug.print("{s}\n", .{ u.greet() });
}
