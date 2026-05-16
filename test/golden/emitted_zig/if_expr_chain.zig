const std = @import("std");

pub fn classify(x: i32) i32 {
    return if ((x > 0)) 1 else if ((x < 0)) -1 else 0;
}

pub fn main() void {
    std.debug.print("{any}\n", .{ classify(5) });
    std.debug.print("{any}\n", .{ classify(-5) });
    std.debug.print("{any}\n", .{ classify(0) });
}
