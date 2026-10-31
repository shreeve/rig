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
