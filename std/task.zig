//! `std.task`: the waiting point that waits for nothing.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn check() rig.Stop!void {
    return rig.taskCheck();
}
