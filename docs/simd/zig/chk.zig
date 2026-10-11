const std = @import("std");
const n = @import("neon.zig");
pub fn main() void {
    var buf: [64]u8 = @splat('a');
    buf[3] = '"'; buf[17] = '\\'; buf[40] = 0x01; buf[63] = '"';
    const m4 = @import("mask.zig");
    std.debug.print("{x} {x}\n", .{ n.special64p(&buf), m4.special64(&buf) });
}
