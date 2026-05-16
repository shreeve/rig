const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    name: []const u8,
};

pub fn main() void {
    const rc = (rig.rcNew(User{ .name = "x" }) catch @panic("Rig Rc allocation failed"));
    const w = rc.weakRef();
    const m = w.upgrade();
    std.debug.print("{any}\n", .{ m });
    rc.dropStrong();
    w.dropWeak();
}
