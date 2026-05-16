const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Shape = union(enum) {
    circle: i32,
    square: i32,
    triangle: struct { a: i32, b: i32 },
    origin: void,
};

pub fn main() void {
    const s1: Shape = .{ .circle = 5 };
    const s2: Shape = .{ .triangle = .{ .a = 3, .b = 4 } };
    const s3: Shape = .origin;
    std.debug.print("{any}\n", .{ s1 });
    std.debug.print("{any}\n", .{ s2 });
    std.debug.print("{any}\n", .{ s3 });
}
