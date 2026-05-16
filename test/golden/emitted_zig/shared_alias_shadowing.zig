const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Box = struct {
    value: i32,
};

pub fn holder(rc: *rig.RcBox(Box)) void {
    rc.dropStrong();
}

pub fn consumer(rc: i32) void {
    std.debug.print("{any}\n", .{ rc });
}

pub fn main() void {
    const b = (rig.rcNew(Box{ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    holder(b);
    consumer(42);
}
