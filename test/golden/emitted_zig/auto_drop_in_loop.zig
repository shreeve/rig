const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const C = struct {
    v: i32,
};

pub fn main() void {
    var i: i32 = 0;
    while ((i < 3)) {
        const rc = (rig.rcNew(C{ .v = i }) catch @panic("Rig Rc allocation failed"));
        var __rig_alive_rc: bool = true;
        defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
        std.debug.print("{any}\n", .{ rc.value.v });
        i += 1;
    }
    std.debug.print("{s}\n", .{ "done" });
}
