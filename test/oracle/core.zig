//! The core the oracle checks: a function body lowered to vars and
//! straight-line ops in basic blocks.

const std = @import("std");

pub const Rule = enum { C1, C2, C3, C4, C5, C6, C7 };

pub const Finding = struct {
    rule: Rule,
    pos: u32,
    reason: []const u8,
};

pub const Func = struct {};

pub fn dump(func: *const Func, w: *std.Io.Writer) !void {
    _ = func;
    _ = w;
}
