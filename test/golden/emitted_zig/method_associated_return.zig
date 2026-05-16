const std = @import("std");

pub const User = struct {
    name: []const u8,

    pub fn make(default: []const u8) User {
        return User{ .name = default };
    }
};

pub fn main() void {
    const u: User = User.make("guest");
    std.debug.print("{s}\n", .{ u.name });
}
