const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const C = struct {
    v: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(C{ .v = 7 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    const cond = true;
    if (cond) {
        rc.dropStrong(); __rig_alive_rc = false;
    } else {
        std.debug.print("{any}\n", .{ rc.value.v });
    }
    std.debug.print("{s}\n", .{ "done" });
}
