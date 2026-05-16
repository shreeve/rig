const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Shape = union(enum) {
    circle: i32,
    triangle: struct { a: i32, b: i32 },
    origin: void,
};

pub fn main() void {
    const s: Shape = .{ .triangle = .{ .a = 3, .b = 4 } };
    switch (s) {
        .circle => |r| { std.debug.print("{any}\n", .{ r }); },
        .triangle => |__payload| { const a = __payload.a; const b = __payload.b; std.debug.print("{any}\n", .{ (a + b) }); },
        .origin => { std.debug.print("{any}\n", .{ 0 }); },
    }
}
