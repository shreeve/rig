const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const x = if (true) 1 else 2;
    const y = if ((x > 0)) 100 else -100;
    std.debug.print("{any}\n", .{ x });
    std.debug.print("{any}\n", .{ y });
}
