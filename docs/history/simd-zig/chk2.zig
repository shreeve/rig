const std = @import("std");
pub fn main() void {
    var buf: [64]u8 = @splat('a');
    buf[3] = '"'; buf[17] = '\\'; buf[40] = 0x01; buf[63] = '"';
    std.debug.print("{x} {x}\n", .{ @import("neon2.zig").special64p(&buf), @import("mask.zig").special64(&buf) });
}
