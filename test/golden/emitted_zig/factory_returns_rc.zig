const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Counter = struct {
    value: i32,
};

pub fn make_counter(n: i32) *rig.RcBox(Counter) {
    const rc = (rig.rcNew(Counter{ .value = n }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    __rig_alive_rc = false; return rc;
}

pub fn main() void {
    const c = make_counter(42);
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.dropStrong(); };
    std.debug.print("{any}\n", .{ c.value.value });
}
