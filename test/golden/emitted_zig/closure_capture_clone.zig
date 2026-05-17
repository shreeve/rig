const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const rc: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    var read = struct {
        cap_rc: *rig.RcBox(rig.Cell(i32)),
        pub fn invoke(self: *@This()) i32 {
            return self.cap_rc.value.get();
        }
    }{ .cap_rc = rc.cloneStrong() }; _ = &read;
    var __rig_alive_read_cap_rc: bool = true;
    defer if (__rig_alive_read_cap_rc) { __rig_alive_read_cap_rc = false; read.cap_rc.dropStrong(); };
    std.debug.print("{any}\n", .{ read.invoke() });
    std.debug.print("{any}\n", .{ read.invoke() });
    std.debug.print("{any}\n", .{ rc.value.get() });
}
