const std = @import("std");

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn main() void {
    const c: Color = .red;
    const x = switch (c) {
        .red => 1,
        .green => 2,
        .blue => 3,
    };
    std.debug.print("{any}\n", .{ x });
}
