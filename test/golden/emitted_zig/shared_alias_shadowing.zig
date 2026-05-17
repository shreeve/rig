const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Box = struct {
    value: i32,
};

pub fn holder(rc: *rig.RcBox(Box)) void {
    
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    rc.dropStrong(); __rig_alive_rc = false;
}

pub fn consumer(rc: i32) void {
    std.debug.print("{any}\n", .{ rc });
}

pub fn main() void {
    const b = (rig.rcNew(Box{ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_b: bool = true;
    defer if (__rig_alive_b) { __rig_alive_b = false; b.dropStrong(); };
    holder(rig_mv_0: { __rig_alive_b = false; break :rig_mv_0 b; });
    consumer(42);
}
