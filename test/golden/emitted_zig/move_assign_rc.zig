const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const U = struct {
    v: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(U{ .v = 1 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    var rc2 = (rig.rcNew(U{ .v = 2 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc2: bool = true;
    defer if (__rig_alive_rc2) { __rig_alive_rc2 = false; rc2.dropStrong(); };
    if (__rig_alive_rc2) { rc2.dropStrong(); __rig_alive_rc2 = false; } rc2 = rig_mv_0: { __rig_alive_rc = false; break :rig_mv_0 rc; }; __rig_alive_rc2 = true;
    std.debug.print("{any}\n", .{ rc2.value.v });
}
