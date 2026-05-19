const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    var v: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
    var __rig_alive_v: bool = true;
    defer if (__rig_alive_v) { __rig_alive_v = false; v.__rig_drop(); }; _ = &v;
    const c: *rig.RcBox(rig.Cell(rig.Vec(*rig.RcBox(rig.Closure0)))) = (rig.rcNew(rig.Cell(rig.Vec(*rig.RcBox(rig.Closure0))){ .value = rig_mv_0: { __rig_alive_v = false; break :rig_mv_0 v; } }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.dropStrong(); };
    std.debug.print("{any}\n", .{ 0 });
}
