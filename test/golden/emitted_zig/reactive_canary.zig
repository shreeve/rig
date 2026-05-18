const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const count: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_count: bool = true;
    defer if (__rig_alive_count) { __rig_alive_count = false; count.dropStrong(); };
    count.value.set(1);
    std.debug.print("{any}\n", .{ count.value.get() });
    var bump = struct {
        cap_count: *rig.RcBox(rig.Cell(i32)),
        pub fn invoke(self: *@This()) void {
            self.cap_count.value.set((self.cap_count.value.get() + 1));
        }
    }{ .cap_count = count.cloneStrong() }; _ = &bump;
    var __rig_alive_bump_cap_count: bool = true;
    defer if (__rig_alive_bump_cap_count) { __rig_alive_bump_cap_count = false; bump.cap_count.dropStrong(); };
    bump.invoke();
    bump.invoke();
    std.debug.print("{any}\n", .{ count.value.get() });
    const eff: *rig.RcBox(rig.Closure0) = rig_closure_0: {
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
        break :rig_closure_0 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_eff: bool = true;
    defer if (__rig_alive_eff) { __rig_alive_eff = false; eff.dropStrong(); };
    eff.value.invoke();
    std.debug.print("{any}\n", .{ count.value.get() });
    const sig: *rig.RcBox(rig.Signal(i32)) = (rig.rcNew(rig.Signal(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_sig: bool = true;
    defer if (__rig_alive_sig) { __rig_alive_sig = false; sig.dropStrong(); };
    const log: *rig.RcBox(rig.Closure0) = rig_closure_1: {
        const Env = struct {
            cap_sig: *rig.RcBox(rig.Signal(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                std.debug.print("{any}\n", .{ self.cap_sig.value.get() });
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_sig.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_sig = sig.cloneStrong() };
        break :rig_closure_1 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_log: bool = true;
    defer if (__rig_alive_log) { __rig_alive_log = false; log.dropStrong(); };
    sig.value.subscribe(log.cloneStrong());
    sig.value.set(7);
    sig.value.set(99);
}
