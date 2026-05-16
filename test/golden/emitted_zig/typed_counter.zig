const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    var i: i32 = 0;
    i += 1;
    i += 1;
    i += 1;
    std.debug.print("{any}\n", .{ i });
}
