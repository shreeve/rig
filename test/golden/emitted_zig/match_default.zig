const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn main() void {
    const c: Color = .red;
    switch (c) {
        .red => { std.debug.print("{s}\n", .{ "red" }); },
        else => { std.debug.print("{s}\n", .{ "not red" }); },
    }
}
