const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    std.debug.print("{s}\n", .{ "hello, rig" });
}
