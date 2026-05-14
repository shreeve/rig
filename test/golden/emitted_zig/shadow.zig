const std = @import("std");

pub fn main() void {
    const x = 1;
    _ = x; const x_1 = 2;
    std.debug.print("{any}\n", .{ x_1 });
}
