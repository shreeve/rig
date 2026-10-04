//! Lowering a function body to the core.

const std = @import("std");
const lib = @import("rig_lib");
const core = @import("core.zig");
const Unit = @import("main.zig").Unit;

/// Why the last lowering abstained.
pub var abstain_reason: []const u8 = "";

pub fn lowerUnit(a: std.mem.Allocator, m: *const lib.modules.Module, unit: Unit) !core.Func {
    _ = a;
    _ = m;
    _ = unit;
    abstain_reason = "not built";
    return error.Abstain;
}
