const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Counter = struct {
    value: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(Counter{ .value = 7 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    std.debug.print("{any}\n", .{ rc.value.value });
}
