const std = @import("std");

pub fn Option(comptime T: type) type {
    return union(enum) {
        const Self = @This();

        some: T,
        none: void,

        pub fn is_some(self: Self) bool {
            return switch (self) {
                .some => true,
                .none => false,
            };
        }
    };
}

pub fn main() void {
    const o1: Option(i32) = .{ .some = 1 };
    const o2: Option(i32) = .none;
    std.debug.print("{any}\n", .{ o1.is_some() });
    std.debug.print("{any}\n", .{ o2.is_some() });
}
