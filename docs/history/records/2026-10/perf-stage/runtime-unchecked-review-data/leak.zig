const std = @import("std");
inline fn unchecked(p: *anyopaque) *u64 {
    @setRuntimeSafety(false);
    return @ptrCast(@alignCast(p));
}
noinline fn idx() usize {
    return 7;
}
pub fn main() void {
    var x: u64 = 1;
    const p = unchecked(&x);
    var a = [_]u8{ 1, 2, 3 };
    const s: []u8 = &a;
    // If the callee's setting leaked into this scope, this would not panic.
    std.debug.print("{d} {d}\n", .{ p.*, s[idx()] });
}
