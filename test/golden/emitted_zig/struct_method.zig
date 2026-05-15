const std = @import("std");

pub const User = struct {
    name: []const u8,

    pub fn greet() []const u8 {
        return "hi";
    }
};

pub fn main() void {
    std.debug.print("{s}\n", .{ User.greet() });
}
