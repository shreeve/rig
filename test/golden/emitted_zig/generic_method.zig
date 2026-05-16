const std = @import("std");

pub fn Box(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub fn get(self: Self) T {
            return self.value;
        }
    };
}

pub fn main() void {
    const b: Box(i32) = .{ .value = 42 };
    std.debug.print("{any}\n", .{ b.get() });
}
