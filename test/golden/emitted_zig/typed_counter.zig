const std = @import("std");

pub fn main() void {
    var i: i32 = 0;
    i += 1;
    i += 1;
    i += 1;
    std.debug.print("{any}\n", .{ i });
}
