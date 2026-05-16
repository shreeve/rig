const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const Box = struct {
    payload: i32,
};

pub fn use_rc(rc: *rig.RcBox(Box)) void {
    rc.dropStrong();
}

pub fn main() void {
    const rc = (rig.rcNew(Box{ .payload = 42 }) catch @panic("Rig Rc allocation failed"));
    use_rc(rc);
    std.debug.print("{s}\n", .{ "moved" });
}
