const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Box = struct {
    payload: i32,
};

pub fn use_rc(rc: *rig.RcBox(Box)) void {
    
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    rc.dropStrong(); __rig_alive_rc = false;
}

pub fn main() void {
    const rc = (rig.rcNew(Box{ .payload = 42 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    use_rc(rig_mv_0: { __rig_alive_rc = false; break :rig_mv_0 rc; });
    std.debug.print("{s}\n", .{ "moved" });
}
