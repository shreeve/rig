const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    var rc1: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc1: bool = true;
    defer if (__rig_alive_rc1) { __rig_alive_rc1 = false; rc1.dropStrong(); };
    const rc2: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc2: bool = true;
    defer if (__rig_alive_rc2) { __rig_alive_rc2 = false; rc2.dropStrong(); };
    rc1.value.set(10);
    rc2.value.set(20);
    if (__rig_alive_rc1) { rc1.dropStrong(); __rig_alive_rc1 = false; } rc1 = rig_mv_0: { __rig_alive_rc2 = false; break :rig_mv_0 rc2; }; __rig_alive_rc1 = true;
    std.debug.print("{any}\n", .{ rc1.value.get() });
}
