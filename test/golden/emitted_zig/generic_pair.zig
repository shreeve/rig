const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn Pair(comptime T: type, comptime U: type) type {
    return struct {
        const Self = @This();

        first: T,
        second: U,
    };
}

pub fn main() void {
    const p: Pair(i32, []const u8) = .{ .first = 42, .second = "answer" };
    std.debug.print("{any}\n", .{ p.first });
}
