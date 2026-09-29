//! The standard library, embedded in the compiler: `use std.NAME` reads
//! `NAME.rig` from this table, and a module's `extern zig "NAME.zig"`
//! block its Zig shim. `RIG_STD=dir` reads them from `dir` instead.

pub const files = [_]struct { []const u8, []const u8 }{
    .{ "math.rig", @embedFile("math.rig") },
    .{ "math.zig", @embedFile("math.zig") },
    .{ "os.rig", @embedFile("os.rig") },
    .{ "os.zig", @embedFile("os.zig") },
    .{ "random.rig", @embedFile("random.rig") },
    .{ "random.zig", @embedFile("random.zig") },
    .{ "time.rig", @embedFile("time.rig") },
    .{ "time.zig", @embedFile("time.zig") },
};

pub fn get(name: []const u8) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f[0], name)) return f[1];
    return null;
}

const std = @import("std");
