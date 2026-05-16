const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Color = enum {
    red,
    green,
    blue,

    pub fn is_red(self: Color) bool {
        return switch (self) {
            .red => true,
            .green => false,
            .blue => false,
        };
    }
};

pub fn main() void {
    const c1 = Color.red;
    const c2 = Color.blue;
    std.debug.print("{any}\n", .{ c1.is_red() });
    std.debug.print("{any}\n", .{ c2.is_red() });
}
