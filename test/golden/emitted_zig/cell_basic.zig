const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const c: rig.Cell(i32) = .{ .value = 7 };
    std.debug.print("{any}\n", .{ c.value });
}
