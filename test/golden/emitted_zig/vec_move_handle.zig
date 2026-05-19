const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    const c1: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 7 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c1: bool = true;
    defer if (__rig_alive_c1) { __rig_alive_c1 = false; c1.dropStrong(); };
    const c2: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 13 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c2: bool = true;
    defer if (__rig_alive_c2) { __rig_alive_c2 = false; c2.dropStrong(); };
    var v: rig.Vec(*rig.RcBox(rig.Cell(i32))) = rig.Vec(*rig.RcBox(rig.Cell(i32))).init(rig.defaultAllocator());
    var __rig_alive_v: bool = true;
    defer if (__rig_alive_v) { __rig_alive_v = false; v.__rig_drop(); }; _ = &v;
    v.push(rig_mv_0: { __rig_alive_c1 = false; break :rig_mv_0 c1; });
    v.push(rig_mv_1: { __rig_alive_c2 = false; break :rig_mv_1 c2; });
    std.debug.print("{any}\n", .{ v.length() });
}
