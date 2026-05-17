const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    name: []const u8,
};

pub fn main() void {
    const rc = (rig.rcNew(User{ .name = "x" }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    const w = rc.weakRef();
    var __rig_alive_w: bool = true;
    defer if (__rig_alive_w) { __rig_alive_w = false; w.dropWeak(); };
    const m = w.upgrade();
    std.debug.print("{any}\n", .{ m });
    rc.dropStrong(); __rig_alive_rc = false;
    w.dropWeak(); __rig_alive_w = false;
}
