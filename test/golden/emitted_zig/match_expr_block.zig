const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Op = enum {
    add,
    minus,
};

pub fn apply(op: Op, a: i32, b: i32) i32 {
    return switch (op) {
        .add => rig_blk_0: {
            const tmp = (a + b);
            break :rig_blk_0 tmp;
        },
        .minus => rig_blk_1: {
            const tmp = (a - b);
            break :rig_blk_1 tmp;
        },
    };
}

pub fn main() void {
    std.debug.print("{any}\n", .{ apply(.add, 3, 4) });
    std.debug.print("{any}\n", .{ apply(.minus, 10, 3) });
}
