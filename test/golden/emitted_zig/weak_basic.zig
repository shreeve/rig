const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Node = struct {
    value: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(Node{ .value = 7 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    const w = rc.weakRef();
    var __rig_alive_w: bool = true;
    defer if (__rig_alive_w) { __rig_alive_w = false; w.dropWeak(); };
    rc.dropStrong(); __rig_alive_rc = false;
    w.dropWeak(); __rig_alive_w = false;
    std.debug.print("{s}\n", .{ "weak cycle ok" });
}
