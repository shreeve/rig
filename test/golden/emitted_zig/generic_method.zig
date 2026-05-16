const std = @import("std");
const rig = @import("_rig_runtime.zig");

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
