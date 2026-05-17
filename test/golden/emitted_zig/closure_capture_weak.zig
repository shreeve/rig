const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const rc: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 1 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    var watch = struct {
        cap_rc: rig.WeakHandle(rig.Cell(i32)),
        pub fn invoke(self: *@This()) void {
            _ = self;
            std.debug.print("{s}\n", .{ "observing weak" });
        }
    }{ .cap_rc = rc.weakRef() }; _ = &watch;
    var __rig_alive_watch_cap_rc: bool = true;
    defer if (__rig_alive_watch_cap_rc) { __rig_alive_watch_cap_rc = false; watch.cap_rc.dropWeak(); };
    watch.invoke();
    watch.invoke();
    std.debug.print("{any}\n", .{ rc.value.get() });
}
