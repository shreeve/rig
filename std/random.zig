//! `std.random`: the operating system's entropy, for `Random.new`.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn entropy() u64 {
    var bytes: [8]u8 = undefined;
    rig.io().random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

pub fn check_range(lo: i64, hi: i64) void {
    if (lo >= hi) std.debug.panic("random: empty range {d}..{d}", .{ lo, hi });
}
