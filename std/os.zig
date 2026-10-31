//! `std.os`: the process's arguments and environment, which the runtime
//! stores when the program starts (`rig.start`). Both live as long as
//! the process, so they cross into Rig as `Static`s. What the program's
//! allocations come to (`rig.memoryTotals`), its end (`rig.exitNow`), and
//! what a closed stdout pipe does (`rig.setBrokenPipeDies`).

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn args() []const []const u8 {
    return rig.processArgs();
}

pub fn env(name: []const u8) ?[]const u8 {
    const init = rig.process orelse return null;
    return init.environ.getPosix(name);
}

pub fn memory_live() i64 {
    return rig.memoryTotals().live;
}

pub fn memory_peak() i64 {
    return rig.memoryTotals().peak;
}

pub fn memory_allocs() i64 {
    return rig.memoryTotals().allocs;
}

pub fn exit(code: i64) void {
    rig.exitNow(code);
}

pub fn set_broken_pipe_dies(dies: bool) void {
    rig.setBrokenPipeDies(dies);
}
