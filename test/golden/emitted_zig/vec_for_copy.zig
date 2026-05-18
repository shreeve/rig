const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    var nums: rig.Vec(i32) = rig.Vec(i32).init(rig.defaultAllocator());
    var __rig_alive_nums: bool = true;
    defer if (__rig_alive_nums) { __rig_alive_nums = false; nums.__rig_drop(); }; _ = &nums;
    nums.push(10);
    nums.push(20);
    nums.push(30);
    if (nums.buf) |__rig_p_973| {
        var __rig_i_973: usize = 0;
        while (__rig_i_973 < nums.len) : (__rig_i_973 += 1) {
            const n = __rig_p_973[__rig_i_973];
            {
                std.debug.print("{any}\n", .{ n });
            }
        }
    }
}
