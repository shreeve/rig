const std = @import("std");
pub fn main() void {
    inline for (.{ @Vector(16, u8), @Vector(64, u8), @Vector(16, bool), @Vector(64, bool), @Vector(4, u32), @Vector(8, f32), @Vector(4, u128), @Vector(2, u8) }) |T| {
        std.debug.print("{s}: size {d} align {d}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
    }
}
