const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const n = 7;
    var add = struct {
        cap_n: i32,
        pub fn invoke(self: *@This()) i32 {
            return (self.cap_n * 2);
        }
    }{ .cap_n = n }; _ = &add;
    std.debug.print("{any}\n", .{ add.invoke() });
    std.debug.print("{any}\n", .{ n });
}
