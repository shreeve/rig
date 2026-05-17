const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    var c: rig.Cell(i32) = .{ .value = 7 }; _ = &c;
    std.debug.print("{any}\n", .{ c.value });
}
