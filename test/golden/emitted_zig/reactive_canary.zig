const std = @import("std");
const rig = @import("_runtime.zig");

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
    const sig: *rig.RcBox(rig.Signal(i32)) = (rig.rcNew(rig.Signal(i32).init(0)) catch @panic("Rig Rc allocation failed"));
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
    const notes: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_notes: bool = true;
    defer if (__rig_alive_notes) { __rig_alive_notes = false; notes.dropStrong(); };
    const one: *rig.RcBox(rig.Closure0) = rig_closure_2: {
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
        break :rig_closure_2 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_one: bool = true;
    defer if (__rig_alive_one) { __rig_alive_one = false; one.dropStrong(); };
    const ten: *rig.RcBox(rig.Closure0) = rig_closure_3: {
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
        break :rig_closure_3 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_ten: bool = true;
    defer if (__rig_alive_ten) { __rig_alive_ten = false; ten.dropStrong(); };
    const cent: *rig.RcBox(rig.Closure0) = rig_closure_4: {
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
        break :rig_closure_4 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_cent: bool = true;
    defer if (__rig_alive_cent) { __rig_alive_cent = false; cent.dropStrong(); };
    var subs: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
    var __rig_alive_subs: bool = true;
    defer if (__rig_alive_subs) { __rig_alive_subs = false; subs.__rig_drop(); }; _ = &subs;
    subs.push(one.cloneStrong());
    subs.push(ten.cloneStrong());
    subs.push(cent.cloneStrong());
    if (subs.buf) |__rig_p_5448| {
        var __rig_i_5448: usize = 0;
        while (__rig_i_5448 < subs.len) : (__rig_i_5448 += 1) {
            const __rig_elem_5448 = &__rig_p_5448[__rig_i_5448];
            {
                __rig_elem_5448.*.value.invoke();
            }
        }
    }
    std.debug.print("{any}\n", .{ notes.value.get() });
    const tally: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = 0 }) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_tally: bool = true;
    defer if (__rig_alive_tally) { __rig_alive_tally = false; tally.dropStrong(); };
    const add_a: *rig.RcBox(rig.Closure0) = rig_closure_5: {
        const Env = struct {
            cap_tally: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.value.set((self.cap_tally.value.get() + 1));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_tally = tally.cloneStrong() };
        break :rig_closure_5 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_add_a: bool = true;
    defer if (__rig_alive_add_a) { __rig_alive_add_a = false; add_a.dropStrong(); };
    const add_b: *rig.RcBox(rig.Closure0) = rig_closure_6: {
        const Env = struct {
            cap_tally: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.value.set((self.cap_tally.value.get() + 10));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_tally = tally.cloneStrong() };
        break :rig_closure_6 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_add_b: bool = true;
    defer if (__rig_alive_add_b) { __rig_alive_add_b = false; add_b.dropStrong(); };
    const add_c: *rig.RcBox(rig.Closure0) = rig_closure_7: {
        const Env = struct {
            cap_tally: *rig.RcBox(rig.Cell(i32)),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.value.set((self.cap_tally.value.get() + 100));
            }
            fn rigDrop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.cap_tally.dropStrong();
                allocator.destroy(self);
            }
        };
        const __rig_env = rig.defaultAllocator().create(Env) catch @panic("Rig closure env allocation failed");
        __rig_env.* = .{ .cap_tally = tally.cloneStrong() };
        break :rig_closure_7 (rig.rcNew(rig.Closure0{ .ctx = __rig_env, .invoke_fn = Env.rigInvoke, .drop_fn = Env.rigDrop, .allocator = rig.defaultAllocator() }) catch @panic("Rig Rc allocation failed"));
    };
    var __rig_alive_add_c: bool = true;
    defer if (__rig_alive_add_c) { __rig_alive_add_c = false; add_c.dropStrong(); };
    const multi: *rig.RcBox(rig.Signal(i32)) = (rig.rcNew(rig.Signal(i32).init(0)) catch @panic("Rig Rc allocation failed"));
    var __rig_alive_multi: bool = true;
    defer if (__rig_alive_multi) { __rig_alive_multi = false; multi.dropStrong(); };
    multi.value.subscribe(add_a.cloneStrong());
    multi.value.subscribe(add_b.cloneStrong());
    multi.value.subscribe(add_c.cloneStrong());
    multi.value.set(42);
    std.debug.print("{any}\n", .{ tally.value.get() });
}
