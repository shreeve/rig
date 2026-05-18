const std = @import("std");
const rig = @import("_rig_runtime.zig");

pub fn main() void {
    const notes: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_notes: bool = true;
    defer if (__rig_alive_notes) { __rig_alive_notes = false; notes.dropStrong(); };
    const one: *rig.RcBox(rig.Closure0) = rig_closure_0: {
        const Env = struct {
            cap_notes: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.value.set((self.cap_notes.value.get() + 1));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_notes = notes.cloneStrong() };
        break :rig_closure_0 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_one: bool = true;
    defer if (__rig_alive_one) { __rig_alive_one = false; one.dropStrong(); };
    const ten: *rig.RcBox(rig.Closure0) = rig_closure_1: {
        const Env = struct {
            cap_notes: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.value.set((self.cap_notes.value.get() + 10));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_notes = notes.cloneStrong() };
        break :rig_closure_1 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_ten: bool = true;
    defer if (__rig_alive_ten) { __rig_alive_ten = false; ten.dropStrong(); };
    const cent: *rig.RcBox(rig.Closure0) = rig_closure_2: {
        const Env = struct {
            cap_notes: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.value.set((self.cap_notes.value.get() + 100));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_notes.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_notes = notes.cloneStrong() };
        break :rig_closure_2 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_cent: bool = true;
    defer if (__rig_alive_cent) { __rig_alive_cent = false; cent.dropStrong(); };
    const sig: *rig.RcBox(rig.Signal(i32)) = (rig.rcNew(rig.Signal(i32).init(0)) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_sig: bool = true;
    defer if (__rig_alive_sig) { __rig_alive_sig = false; sig.dropStrong(); };
    sig.value.subscribe(one.cloneStrong());
    sig.value.subscribe(ten.cloneStrong());
    sig.value.subscribe(cent.cloneStrong());
    std.debug.print("{any}\n", .{ notes.value.get() });
    sig.value.set(1);
    std.debug.print("{any}\n", .{ notes.value.get() });
    sig.value.set(2);
    std.debug.print("{any}\n", .{ notes.value.get() });
}
