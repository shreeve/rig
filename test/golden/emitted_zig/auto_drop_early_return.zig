const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const C = struct {
    v: i32,
};

pub fn pick(cond: bool) i32 {
    const rc = (rig.rcNew(C{ .v = 99 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    if (cond) {
        return 1;
    }
    return 2;
}

pub fn main() void {
    std.debug.print("{any}\n", .{ pick(true) });
    std.debug.print("{any}\n", .{ pick(false) });
}
