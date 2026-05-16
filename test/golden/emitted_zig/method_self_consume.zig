const std = @import("std");

pub const User = struct {
    name: []const u8,

    pub fn consume(self: User) void {
        std.debug.print("{s}\n", .{ self.name });
    }
};

pub fn main() void {
    const u = User{ .name = "Steve" };
    u.consume();
}
