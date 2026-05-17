const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub const User = struct {
    age: i32,

    pub fn read_age(self: User) i32 {
        return self.age;
    }
};

pub fn main() void {
    const rc = (rig.rcNew(User{ .age = 42 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
    std.debug.print("{any}\n", .{ rc.value.age });
    std.debug.print("{any}\n", .{ rc.value.read_age() });
    rc.dropStrong(); __rig_alive_rc = false;
}
