const std = @import("std");

pub fn Option(comptime T: type) type {
    return union(enum) {
        const Self = @This();

        some: T,
        none: void,
    };
}

pub fn main() void {
    const o: Option(i32) = .{ .some = 5 };
    switch (o) {
        .some => { std.debug.print("{s}\n", .{ "got it" }); },
        .none => { std.debug.print("{s}\n", .{ "nothing" }); },
    }
}
