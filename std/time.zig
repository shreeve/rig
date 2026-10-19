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
    if (ns <= 0) return;
    try rig.waitPoint(std.Io.sleep, .{ rig.io(), std.Io.Duration.fromNanoseconds(ns), std.Io.Clock.awake });
}
