const std = @import("std");
const rig = @import("_runtime.zig");

pub const Pair = struct {
    a: *rig.RcBox(rig.Cell(i32)),
    b: *rig.RcBox(rig.Cell(i32)),

    pub fn __rig_drop(self: *Pair) void {
        self.b.dropStrong();
        self.a.dropStrong();
    }
};

pub fn main() void {
    const ca: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_ca: bool = true;
    defer if (__rig_alive_ca) { __rig_alive_ca = false; ca.dropStrong(); };
    const cb: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 2 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_cb: bool = true;
    defer if (__rig_alive_cb) { __rig_alive_cb = false; cb.dropStrong(); };
    var p: Pair = Pair{ .a = rig_mv_0: { __rig_alive_ca = false; break :rig_mv_0 ca; }, .b = rig_mv_1: { __rig_alive_cb = false; break :rig_mv_1 cb; } };
    var __rig_alive_p: bool = true;
    defer if (__rig_alive_p) { __rig_alive_p = false; p.__rig_drop(); }; _ = &p;
    std.debug.print("{any}\n", .{ 0 });
}
