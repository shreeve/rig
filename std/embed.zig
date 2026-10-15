//! The standard library, embedded in the compiler: `use std.NAME` reads
//! `NAME.rig` from this table, and a module's `extern zig "NAME.zig"`
//! block its Zig shim. `RIG_STD=dir` reads them from `dir` instead.

pub const files = [_]struct { []const u8, []const u8 }{
    .{ "file.rig", @embedFile("file.rig") },
    .{ "file.zig", @embedFile("file.zig") },
    .{ "grapheme.zig", @embedFile("grapheme.zig") },
    .{ "grapheme_tables.zig", @embedFile("grapheme_tables.zig") },
    .{ "hash.rig", @embedFile("hash.rig") },
    .{ "json.rig", @embedFile("json.rig") },
    .{ "math.rig", @embedFile("math.rig") },
    .{ "math.zig", @embedFile("math.zig") },
    .{ "os.rig", @embedFile("os.rig") },
    .{ "os.zig", @embedFile("os.zig") },
    .{ "random.rig", @embedFile("random.rig") },
    .{ "random.zig", @embedFile("random.zig") },
    .{ "slices.rig", @embedFile("slices.rig") },
    .{ "sort.rig", @embedFile("sort.rig") },
    .{ "target.rig", @embedFile("target.rig") },
    .{ "target.zig", @embedFile("target.zig") },
    .{ "text.rig", @embedFile("text.rig") },
    .{ "text.zig", @embedFile("text.zig") },
    .{ "time.rig", @embedFile("time.rig") },
    .{ "time.zig", @embedFile("time.zig") },
    .{ "unicode.rig", @embedFile("unicode.rig") },
    .{ "unicode_tables.zig", @embedFile("unicode_tables.zig") },
    .{ "utf16.rig", @embedFile("utf16.rig") },
    .{ "utf8.rig", @embedFile("utf8.rig") },
};

pub fn get(name: []const u8) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f[0], name)) return f[1];
    return null;
}

const std = @import("std");
