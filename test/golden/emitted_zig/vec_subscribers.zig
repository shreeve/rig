const std = @import("std");
const rig = @import("_runtime.zig");

pub fn main() void {
    const count: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_count: bool = true;
    defer if (__rig_alive_count) { __rig_alive_count = false; count.dropStrong(); };
    const cb1: *rig.RcBox(rig.Closure0) = rig_closure_0: {
        const Env = struct {
            cap_count: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_count.value.set((self.cap_count.value.get() + 1));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_count.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_count = count.cloneStrong() };
        break :rig_closure_0 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_cb1: bool = true;
    defer if (__rig_alive_cb1) { __rig_alive_cb1 = false; cb1.dropStrong(); };
    const cb2: *rig.RcBox(rig.Closure0) = rig_closure_1: {
        const Env = struct {
            cap_count: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_count.value.set((self.cap_count.value.get() + 10));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_count.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_count = count.cloneStrong() };
        break :rig_closure_1 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_cb2: bool = true;
    defer if (__rig_alive_cb2) { __rig_alive_cb2 = false; cb2.dropStrong(); };
    var subs: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
    var __rig_alive_subs: bool = true;
    defer if (__rig_alive_subs) { __rig_alive_subs = false; subs.__rig_drop(); }; _ = &subs;
    subs.push(cb1.cloneStrong());
    subs.push(cb2.cloneStrong());
    cb1.value.invoke();
    cb2.value.invoke();
    std.debug.print("{any}\n", .{ count.value.get() });
}
