const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    var v: rig.Vec(i32) = rig.Vec(i32).initCapacity(rig.defaultAllocator(), 32) catch @panic("Rig Vec allocation failed");
    var __rig_alive_v: bool = true;
    defer if (__rig_alive_v) { __rig_alive_v = false; v.__rig_drop(); }; _ = &v;
    v.push(1);
    v.push(2);
    v.push(3);
    std.debug.print("{any}\n", .{ v.length() });
}
