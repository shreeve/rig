const std = @import("std");

pub const Op = enum {
    zero,
    square,
    cube,
};

pub fn apply(op: Op, x: i32) i32 {
    return switch (op) {
        .zero => 0,
        .square => (x * x),
        .cube => rig_blk_0: {
            const sq: i32 = (x * x);
            break :rig_blk_0 (sq * x);
        },
    };
}

pub fn main() void {
    std.debug.print("{any}\n", .{ apply(.zero, 5) });
    std.debug.print("{any}\n", .{ apply(.square, 5) });
    std.debug.print("{any}\n", .{ apply(.cube, 3) });
}
