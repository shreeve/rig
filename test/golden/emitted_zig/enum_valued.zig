const std = @import("std");

pub const Status = enum(u32) {
    ok = 0,
    warn = 1,
    err = 2,
};

pub fn main() void {
    const s: Status = .ok;
    std.debug.print("{any}\n", .{ s });
}
