const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const rc: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    rc.value.set(5);
    std.debug.print("{any}\n", .{ rc.value.get() });
}
