const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Counter = struct {
    value: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(Counter{ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    const rc2 = rc.cloneStrong();
    var __rig_alive_rc2: bool = true;
    defer if (__rig_alive_rc2) { __rig_alive_rc2 = false; rc2.dropStrong(); };
    rc2.dropStrong(); __rig_alive_rc2 = false;
    rc.dropStrong(); __rig_alive_rc = false;
    std.debug.print("{s}\n", .{ "ok" });
}
