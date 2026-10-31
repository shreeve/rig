//! The standard library, embedded in the compiler: `use std.NAME` reads
//! `NAME.rig` from this table, and a module's `extern zig "NAME.zig"`
//! block its Zig shim. `RIG_STD=dir` reads them from `dir` instead.

pub const files = [_]struct { []const u8, []const u8 }{
    .{ "prelude.rig", @embedFile("prelude.rig") },
    .{ "bigint.rig", @embedFile("bigint.rig") },
    .{ "bigint.zig", @embedFile("bigint.zig") },
    .{ "file.rig", @embedFile("file.rig") },
    .{ "file.zig", @embedFile("file.zig") },
    .{ "char.zig", @embedFile("char.zig") },
    .{ "char_tables.zig", @embedFile("char_tables.zig") },
    .{ "hint.rig", @embedFile("hint.rig") },
    .{ "hint.zig", @embedFile("hint.zig") },
    .{ "crypto.zig", @embedFile("crypto.zig") },
    .{ "crypto/aead.rig", @embedFile("crypto/aead.rig") },
    .{ "crypto/aead_test.rig", @embedFile("crypto/aead_test.rig") },
    .{ "crypto/ct.rig", @embedFile("crypto/ct.rig") },
    .{ "crypto/blake2s/blake2s.rig", @embedFile("crypto/blake2s/blake2s.rig") },
    .{ "crypto/x25519/field.rig", @embedFile("crypto/x25519/field.rig") },
    .{ "crypto/x25519/table.rig", @embedFile("crypto/x25519/table.rig") },
    .{ "crypto/x25519/x25519.rig", @embedFile("crypto/x25519/x25519.rig") },
    .{ "http.rig", @embedFile("http.rig") },
    .{ "http.zig", @embedFile("http.zig") },
    .{ "io.rig", @embedFile("io.rig") },
    .{ "iter.rig", @embedFile("iter.rig") },
    .{ "json.rig", @embedFile("json.rig") },
    .{ "math.rig", @embedFile("math.rig") },
    .{ "math.zig", @embedFile("math.zig") },
    .{ "net.rig", @embedFile("net.rig") },
    .{ "net.zig", @embedFile("net.zig") },
    .{ "os.rig", @embedFile("os.rig") },
    .{ "os.zig", @embedFile("os.zig") },
    .{ "par.rig", @embedFile("par.rig") },
    .{ "random.rig", @embedFile("random.rig") },
    .{ "random.zig", @embedFile("random.zig") },
    .{ "slices.rig", @embedFile("slices.rig") },
    .{ "sort.rig", @embedFile("sort.rig") },
    .{ "target.rig", @embedFile("target.rig") },
    .{ "target.zig", @embedFile("target.zig") },
    .{ "task.rig", @embedFile("task.rig") },
    .{ "task.zig", @embedFile("task.zig") },
    .{ "terminal.rig", @embedFile("terminal.rig") },
    .{ "terminal.zig", @embedFile("terminal.zig") },
    .{ "text.rig", @embedFile("text.rig") },
    .{ "text.zig", @embedFile("text.zig") },
    .{ "time.rig", @embedFile("time.rig") },
    .{ "time.zig", @embedFile("time.zig") },
    .{ "unicode.rig", @embedFile("unicode.rig") },
    .{ "unicode_tables.zig", @embedFile("unicode_tables.zig") },
    .{ "utf16.rig", @embedFile("utf16.rig") },
    .{ "utf8.rig", @embedFile("utf8.rig") },
    .{ "width_tables.zig", @embedFile("width_tables.zig") },
};

pub fn get(name: []const u8) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f[0], name)) return f[1];
    return null;
}

const std = @import("std");
