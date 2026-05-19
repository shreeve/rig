const std = @import("std");
const rig = @import("_runtime.zig");

pub const User = struct {
    age: i32,
};

pub fn main() void {
    const u: *rig.RcBox(User) = (rig.rcNew(User{ .age = 30 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_u: bool = true;
    defer if (__rig_alive_u) { __rig_alive_u = false; u.dropStrong(); };
    var c: rig.Cell(*rig.RcBox(User)) = .{ .value = rig_mv_0: { __rig_alive_u = false; break :rig_mv_0 u; } };
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.__rig_drop(); }; _ = &c;
    std.debug.print("{any}\n", .{ 0 });
}
