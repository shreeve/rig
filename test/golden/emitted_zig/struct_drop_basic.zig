const std = @import("std");
const rig = @import("_runtime.zig");

pub const Owner = struct {
    cell: *rig.RcBox(rig.Cell(i32)),

    pub fn __rig_user_drop(self: *Owner) void {
        _ = self;
        std.debug.print("{any}\n", .{ 99 });
    }

    pub fn __rig_drop(self: *Owner) void {
        self.__rig_user_drop();
        self.cell.dropStrong();
    }
};

pub fn main() void {
    const c: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 42 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_c: bool = true;
    defer if (__rig_alive_c) { __rig_alive_c = false; c.dropStrong(); };
    var o: Owner = Owner{ .cell = rig_mv_0: { __rig_alive_c = false; break :rig_mv_0 c; } };
    var __rig_alive_o: bool = true;
    defer if (__rig_alive_o) { __rig_alive_o = false; o.__rig_drop(); }; _ = &o;
    std.debug.print("{any}\n", .{ 0 });
}
