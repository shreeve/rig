//! `std.time`: the monotonic and wall clocks, read through Zig's
//! `std.Io`, and sleeping and deadlines, which the runtime's tasks keep.

const std = @import("std");
const rig = @import("../runtime.zig");

pub const monotonic = rig.monotonicNs;
pub const since_start = rig.sinceStartNs;
pub const sleep = rig.taskSleep;
pub const enter_deadline = rig.enterDeadline;
pub const restore_deadline = rig.restoreDeadline;

pub fn unix_ns() i64 {
    return @intCast(std.Io.Timestamp.now(rig.io(), .real).nanoseconds);
}
