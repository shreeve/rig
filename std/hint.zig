//! `std.hint`: what the optimizer must not see through, as empty
//! assembly it cannot look inside.

const rig = @import("../runtime.zig");

/// An empty `asm volatile` that takes the address of `x` and clobbers
/// memory: the optimizer must compute `x`, place it in memory, and
/// assume the assembly read it and read and wrote anything else.
pub inline fn keep(comptime T: type, x: rig.ReadView(T)) void {
    asm volatile (""
        :
        : [x] "r" (&x),
        : .{ .memory = true });
}

/// `x`, through an empty `asm volatile` that takes its address and
/// clobbers memory: the optimizer must hold `x` in memory and assume the
/// assembly changed it, so it knows nothing of the value it reads back.
pub inline fn @"opaque"(comptime T: type, x: T) T {
    var v = x;
    asm volatile (""
        :
        : [v] "r" (&v),
        : .{ .memory = true });
    return v;
}
