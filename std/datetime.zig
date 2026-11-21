//! `std.datetime`: the wall clock, read through Zig's `std.Io`. It is
//! the real clock under the deterministic scheduler too, which makes
//! only the monotonic clock virtual.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn wall_ns() i64 {
    return @intCast(std.Io.Timestamp.now(rig.io(), .real).nanoseconds);
}
