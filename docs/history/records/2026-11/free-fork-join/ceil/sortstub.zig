//! What rigsort.zig reads of Rig's runtime, for a program that makes no
//! yield checks (as fork.rig, built to be preempted by signal).
const std = @import("std");
const builtin = @import("builtin");
pub const program_section = if (builtin.object_format == .macho) "__TEXT,__text" else ".text";
pub const scheduled = false;
pub const preempt = false;
pub const tick_turns: u32 = 1024;
pub inline fn turn(_: *u32) void {}
pub fn orderIsIdentity(comptime T: type) bool {
    return @typeInfo(T) == .int;
}
pub fn defaultAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}
pub fn oom() noreturn {
    @panic("out of memory");
}
pub inline fn lend(x: anytype) @TypeOf(x) {
    return x;
}
