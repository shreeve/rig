const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    var c: rig.Cell(i32) = .{ .value = 0 }; _ = &c;
    c.set(5);
    std.debug.print("{any}\n", .{ c.get() });
    c.set((c.get() + 10));
    std.debug.print("{any}\n", .{ c.get() });
}
