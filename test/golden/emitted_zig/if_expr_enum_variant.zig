const std = @import("std");

pub const Sign = enum {
    pos,
    neg,
    zero,
};

pub fn classify(x: i32) Sign {
    return if ((x > 0)) .pos else if ((x < 0)) .neg else .zero;
}

pub fn to_int(s: Sign) i32 {
    return switch (s) {
        .pos => 1,
        .neg => -1,
        .zero => 0,
    };
}

pub fn main() void {
    std.debug.print("{any}\n", .{ to_int(classify(5)) });
    std.debug.print("{any}\n", .{ to_int(classify(-3)) });
    std.debug.print("{any}\n", .{ to_int(classify(0)) });
}
