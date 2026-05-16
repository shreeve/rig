const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn safe_div(a: i32, b: i32) i32 {
    const result = if ((b == 0)) {
        return 0;
    } else (a * b);
    return (result + 1);
}

pub fn main() void {
    std.debug.print("{any}\n", .{ safe_div(10, 2) });
    std.debug.print("{any}\n", .{ safe_div(10, 0) });
}
