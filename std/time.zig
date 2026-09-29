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

pub fn sleep(ns: i64) void {
    if (ns <= 0) return;
    rig.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}
