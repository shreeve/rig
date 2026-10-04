//! The dataflow over the core: liveness, initialization, loans.

const std = @import("std");
const core = @import("core.zig");

pub fn check(a: std.mem.Allocator, func: *core.Func) !?core.Finding {
    _ = a;
    _ = func;
    return null;
}
