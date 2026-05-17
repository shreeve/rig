const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Counter = struct {
    value: i32,
};

pub fn main() void {
    var rc = (rig.rcNew(Counter{ .value = 11 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    if (__rig_alive_rc) { rc.dropStrong(); __rig_alive_rc = false; } rc = (rig.rcNew(Counter{ .value = 22 }) catch @panic("Rig Rc allocation failed")); __rig_alive_rc = true;
    std.debug.print("{any}\n", .{ rc.value.value });
}
