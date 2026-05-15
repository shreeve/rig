const std = @import("std");

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn main() void {
    const c: Color = .red;
    switch (c) {
        .red => { std.debug.print("{s}\n", .{ "R" }); },
        .green => { std.debug.print("{s}\n", .{ "G" }); },
        .blue => { std.debug.print("{s}\n", .{ "B" }); },
    }
}
