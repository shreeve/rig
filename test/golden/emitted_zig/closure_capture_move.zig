const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const rc: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 42 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    var owned = struct {
        cap_rc: *rig.RcBox(rig.Cell(i32)),
        pub fn invoke(self: *@This()) i32 {
            return self.cap_rc.value.get();
        }
    }{ .cap_rc = rig_mv_0: { __rig_alive_rc = false; break :rig_mv_0 rc; } }; _ = &owned;
    var __rig_alive_owned_cap_rc: bool = true;
    defer if (__rig_alive_owned_cap_rc) { __rig_alive_owned_cap_rc = false; owned.cap_rc.dropStrong(); };
    std.debug.print("{any}\n", .{ owned.invoke() });
}
