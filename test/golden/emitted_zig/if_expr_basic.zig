const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn pick(c: bool) i32 {
    return if (c) 10 else 20;
}

pub fn main() void {
    std.debug.print("{any}\n", .{ pick(true) });
    std.debug.print("{any}\n", .{ pick(false) });
}
