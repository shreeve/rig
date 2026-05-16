const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn main() void {
    const c: Color = .red;
    const x = switch (c) {
        .red => 1,
        .green => 2,
        .blue => 3,
    };
    std.debug.print("{any}\n", .{ x });
}
