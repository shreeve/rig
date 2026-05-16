const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Counter = struct {
    value: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(Counter{ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    const rc2 = rc.cloneStrong();
    rc2.dropStrong();
    rc.dropStrong();
    std.debug.print("{s}\n", .{ "ok" });
}
