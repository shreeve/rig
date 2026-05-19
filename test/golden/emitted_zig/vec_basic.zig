const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    var v: rig.Vec(i32) = rig.Vec(i32).init(rig.defaultAllocator());
    var __rig_alive_v: bool = true;
    defer if (__rig_alive_v) { __rig_alive_v = false; v.__rig_drop(); }; _ = &v;
    v.push(10);
    v.push(20);
    v.push(30);
    std.debug.print("{any}\n", .{ v.length() });
}
