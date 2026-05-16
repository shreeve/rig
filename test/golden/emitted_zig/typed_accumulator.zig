const std = @import("std");

pub fn sum_to(n: i32) i32 {
    var sum: i32 = 0;
    var i: i32 = 1;
    while ((i <= n)) {
        sum += i;
        i += 1;
    }
    return sum;
}

pub fn main() void {
    std.debug.print("{any}\n", .{ sum_to(10) });
}
