const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const x = 5;
    switch (x) {
        1...3 => { std.debug.print("{s}\n", .{ "low" }); },
        4...6 => { std.debug.print("{s}\n", .{ "mid" }); },
        else => { std.debug.print("{s}\n", .{ "high" }); },
    }
}
