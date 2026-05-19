const std = @import("std");
const rig = @import("_runtime.zig");

pub const Reactor = struct {
    count: *rig.RcBox(rig.Cell(i32)),

    pub fn __rig_drop(self: *Reactor) void {
        self.count.dropStrong();
    }
};

pub fn main() void {
    const c: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.dropStrong(); };
    var r: Reactor = Reactor{ .count = rig_mv_0: { __rig_alive_c = false; break :rig_mv_0 c; } };
    var __rig_alive_r: bool = true;
    defer if (__rig_alive_r) { __rig_alive_r = false; r.__rig_drop(); }; _ = &r;
    std.debug.print("{any}\n", .{ 0 });
}
