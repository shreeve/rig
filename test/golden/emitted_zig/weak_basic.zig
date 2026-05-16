const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Node = struct {
    value: i32,
};

pub fn main() void {
    const rc = (rig.rcNew(Node{ .value = 7 }) catch @panic("Rig Rc allocation failed"));
    const w = rc.weakRef();
    rc.dropStrong();
    w.dropWeak();
    std.debug.print("{s}\n", .{ "weak cycle ok" });
}
