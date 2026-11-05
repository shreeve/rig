const std = @import("std");
extern "c" fn qos_class_self() c_uint;
extern "c" fn pthread_set_qos_class_self_np(c: c_uint, rel: c_int) c_int;
fn th() void {
    std.debug.print("thread qos 0x{x}\n", .{qos_class_self()});
    _ = pthread_set_qos_class_self_np(0x19, 0);
    std.debug.print("thread qos after 0x{x}\n", .{qos_class_self()});
}
pub fn main() !void {
    std.debug.print("main qos 0x{x}\n", .{qos_class_self()});
    const t = try std.Thread.spawn(.{}, th, .{});
    t.join();
}
