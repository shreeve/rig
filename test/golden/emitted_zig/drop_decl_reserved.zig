const std = @import("std");
const rig = @import("_runtime.zig");

pub const File = struct {
    fd: i32,

    pub fn __rig_user_drop(self: *File) void {
        {
            std.debug.print("{any}\n", .{ self.fd });
        }
    }

    pub fn __rig_drop(self: *File) void {
        self.__rig_user_drop();
    }
};

pub fn main() void {
    var f: File = File{ .fd = 7 };
    var __rig_alive_f: bool = true;
    defer if (__rig_alive_f) { __rig_alive_f = false; f.__rig_drop(); }; _ = &f;
    std.debug.print("{any}\n", .{ 0 });
}
