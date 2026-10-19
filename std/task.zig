//! `std.task`: the waiting point that waits for nothing.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn check() rig.Stop!void {
    try rig.waitPoint(std.Io.checkCancel, .{rig.io()});
    std.Thread.yield() catch {};
}
