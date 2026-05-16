const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Op = enum {
    go,
    abort,
};

pub fn handle(op: Op, x: i32) i32 {
    const result: i32 = switch (op) {
        .go => (x * 2),
        .abort => {
            return -1;
        },
    };
    return (result + 1);
}

pub fn main() void {
    std.debug.print("{any}\n", .{ handle(.go, 5) });
    std.debug.print("{any}\n", .{ handle(.abort, 5) });
}
