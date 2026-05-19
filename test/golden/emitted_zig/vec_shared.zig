const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    const rv: *rig.RcBox(rig.Vec(i32)) = (rig.rcNew(rig.Vec(i32).init(rig.defaultAllocator())) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rv: bool = true;
    defer if (__rig_alive_rv) { __rig_alive_rv = false; rv.dropStrong(); };
    rv.value.push(100);
    rv.value.push(200);
    std.debug.print("{any}\n", .{ rv.value.length() });
}
