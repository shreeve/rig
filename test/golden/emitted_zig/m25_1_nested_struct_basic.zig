const std = @import("std");
const rig = @import("_runtime.zig");

pub const Inner = struct {
    r: *rig.RcBox(rig.Cell(i32)),

    pub fn __rig_drop(self: *Inner) void {
        self.r.dropStrong();
    }
};

pub const Outer = struct {
    inner: Inner,

    pub fn __rig_drop(self: *Outer) void {
        self.inner.__rig_drop();
    }
};

pub fn main() void {
    const c: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 5 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.dropStrong(); };
    var i: Inner = Inner{ .r = rig_mv_0: { __rig_alive_c = false; break :rig_mv_0 c; } };
    var __rig_alive_i: bool = true;
    defer if (__rig_alive_i) { __rig_alive_i = false; i.__rig_drop(); }; _ = &i;
    var o: Outer = Outer{ .inner = rig_mv_1: { __rig_alive_i = false; break :rig_mv_1 i; } };
    var __rig_alive_o: bool = true;
    defer if (__rig_alive_o) { __rig_alive_o = false; o.__rig_drop(); }; _ = &o;
    std.debug.print("{any}\n", .{ 0 });
}
