//! The experiment arm (not landed): src/qos.zig as measured, called as
//! the first line of sched.zig's `workerMain`, `@import("qos.zig").worker();`,
//! and written beside the runtime by emit.zig and main.zig like alloc.zig.
//! RIG_QOS picks the class each worker thread asks for.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn pthread_set_qos_class_self_np(class: c_uint, relative: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn worker() void {
    if (builtin.os.tag != .macos) return;
    const v = getenv("RIG_QOS") orelse return;
    const s = std.mem.span(v);
    const class: c_uint = if (std.mem.eql(u8, s, "ux")) 0x21 else if (std.mem.eql(u8, s, "ui")) 0x19 else if (std.mem.eql(u8, s, "ut")) 0x11 else return;
    _ = pthread_set_qos_class_self_np(class, 0);
}
