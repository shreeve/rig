const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const U = struct {
    v: i32,
};

pub fn take_int(x: i32) void {
    std.debug.print("{any}\n", .{ x });
}

pub fn make_rc() *rig.RcBox(U) {
    const x = (rig.rcNew(U{ .v = 99 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_x: bool = true;
    defer if (__rig_alive_x) { __rig_alive_x = false; x.dropStrong(); };
    __rig_alive_x = false; return x;
}

pub fn main() void {
    take_int(5);
    const rc = make_rc();
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    std.debug.print("{any}\n", .{ rc.value.v });
    rc.dropStrong(); __rig_alive_rc = false;
}
