//! `std.time`: the monotonic and wall clocks, and sleeping, through
//! Zig's `std.Io`.

const std = @import("std");
const rig = @import("../runtime.zig");

fn nanoseconds(clock: std.Io.Clock) i64 {
    return @intCast(std.Io.Timestamp.now(rig.io(), clock).nanoseconds);
}

pub fn monotonic() i64 {
    return nanoseconds(.awake);
}

pub fn unix_ns() i64 {
    return nanoseconds(.real);
}

pub fn sleep(ns: i64) rig.Stop!void {
    return rig.taskSleep(ns);
}

pub fn enter_deadline(ns: i64) i64 {
    return rig.enterDeadline(ns);
}

pub fn restore_deadline(outer: i64) void {
    rig.restoreDeadline(outer);
}
