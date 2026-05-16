const std = @import("std");

pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        const Self = @This();

        ok: T,
        err: E,
    };
}

pub fn main() void {
    const good: Result(i32, []const u8) = .{ .ok = 42 };
    const bad: Result(i32, []const u8) = .{ .err = "oops" };
    switch (good) {
        .ok => { std.debug.print("{s}\n", .{ "42" }); },
        .err => { std.debug.print("{s}\n", .{ "nope" }); },
    }
    switch (bad) {
        .ok => { std.debug.print("{s}\n", .{ "nope" }); },
        .err => { std.debug.print("{s}\n", .{ "oops" }); },
    }
}
