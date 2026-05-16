const std = @import("std");

pub fn summarize(n: i32) i32 {
    return if ((n > 0)) rig_blk_0: {
        const doubled: i32 = (n * 2);
        break :rig_blk_0 (doubled + 1);
    } else 0;
}

pub fn main() void {
    std.debug.print("{any}\n", .{ summarize(10) });
    std.debug.print("{any}\n", .{ summarize(0) });
}
