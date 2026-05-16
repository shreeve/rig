const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    name: []const u8,

    pub fn greet(self: User) []const u8 {
        return self.name;
    }
};

pub const Color = enum {
    red,
    green,
    blue,

    pub fn code(self: Color) i32 {
        return switch (self) {
            .red => 1,
            .green => 2,
            .blue => 3,
        };
    }
};

pub fn main() void {
    const u = User{ .name = "Steve" };
    const c = Color.red;
    std.debug.print("{s}\n", .{ u.greet() });
    std.debug.print("{any}\n", .{ c.code() });
}
