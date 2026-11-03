const std = @import("std");
pub fn main() void {
    var a: @Vector(4, u8) = .{ 250, 1, 2, 3 };
    var b: @Vector(4, u8) = .{ 10, 1, 1, 1 };
    _ = &a; _ = &b;
    const c = a + b;
    const arr: [4]u8 = c;
    std.debug.print("{any}\n", .{arr});
}
