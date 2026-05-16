const std = @import("std");

pub const User = struct {
    name: []const u8,

    pub fn modify(self: User, new_name: []const u8) void {
        std.debug.print("{s}\n", .{ self.name });
        std.debug.print("{s}\n", .{ new_name });
    }
};

pub fn main() void {
    const u = User{ .name = "Steve" };
    u.modify("Bob");
}
