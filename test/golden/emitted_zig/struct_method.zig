const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    name: []const u8,

    pub fn greet() []const u8 {
        return "hi";
    }
};

pub fn main() void {
    std.debug.print("{s}\n", .{ User.greet() });
}
