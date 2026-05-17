const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const count: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_count: bool = true;
    defer if (__rig_alive_count) { __rig_alive_count = false; count.dropStrong(); };
    count.value.set(1);
    std.debug.print("{any}\n", .{ count.value.get() });
    var bump = struct {
        cap_count: *rig.RcBox(rig.Cell(i32)),
        pub fn invoke(self: *@This()) void {
            self.cap_count.value.set((self.cap_count.value.get() + 1));
        }
    }{ .cap_count = count.cloneStrong() }; _ = &bump;
    var __rig_alive_bump_cap_count: bool = true;
    defer if (__rig_alive_bump_cap_count) { __rig_alive_bump_cap_count = false; bump.cap_count.dropStrong(); };
    bump.invoke();
    bump.invoke();
    std.debug.print("{any}\n", .{ count.value.get() });
}
