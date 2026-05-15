const std = @import("std");

pub fn Pair(comptime T: type, comptime U: type) type {
    return struct {
        first: T,
        second: U,
    };
}

pub fn main() void {
    const p: Pair(i32, []const u8) = .{ .first = 42, .second = "answer" };
    std.debug.print("{any}\n", .{ p.first });
}
