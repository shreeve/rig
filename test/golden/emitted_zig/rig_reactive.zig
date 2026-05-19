const std = @import("std");
const rig = @import("_runtime.zig");

pub const IntSource = struct {
    value: *rig.RcBox(rig.Cell(i32)),
    subs: *rig.RcBox(rig.Cell(rig.Vec(*rig.RcBox(rig.Closure0)))),

    pub fn new(initial: i32) *rig.RcBox(IntSource) {
        const val: *rig.RcBox(rig.Cell(i32)) = (rig.rcNew(rig.Cell(i32){ .value = initial }) catch @panic("Rig Rc allocation failed"));
        var __rig_alive_val: bool = true;
        defer if (__rig_alive_val) { __rig_alive_val = false; val.dropStrong(); };
        var empty: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
        var __rig_alive_empty: bool = true;
        defer if (__rig_alive_empty) { __rig_alive_empty = false; empty.__rig_drop(); }; _ = &empty;
        const subs_cell: *rig.RcBox(rig.Cell(rig.Vec(*rig.RcBox(rig.Closure0)))) = (rig.rcNew(rig.Cell(rig.Vec(*rig.RcBox(rig.Closure0))){ .value = rig_mv_0: { __rig_alive_empty = false; break :rig_mv_0 empty; } }) catch @panic("Rig Rc allocation failed"));
        var __rig_alive_subs_cell: bool = true;
        defer if (__rig_alive_subs_cell) { __rig_alive_subs_cell = false; subs_cell.dropStrong(); };
        return (rig.rcNew(IntSource{ .value = rig_mv_1: { __rig_alive_val = false; break :rig_mv_1 val; }, .subs = rig_mv_2: { __rig_alive_subs_cell = false; break :rig_mv_2 subs_cell; } }) catch @panic("Rig Rc allocation failed"));
    }
    pub fn get(self: IntSource) i32 {
        return self.value.value.get();
    }
    pub fn subscribe(self: IntSource, cb: *rig.RcBox(rig.Closure0)) void {
        
        var __rig_alive_cb: bool = true;
        defer if (__rig_alive_cb) { __rig_alive_cb = false; cb.dropStrong(); };
        var empty: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
        var __rig_alive_empty: bool = true;
        defer if (__rig_alive_empty) { __rig_alive_empty = false; empty.__rig_drop(); }; _ = &empty;
        var current: rig.Vec(*rig.RcBox(rig.Closure0)) = self.subs.value.replace(rig_mv_3: { __rig_alive_empty = false; break :rig_mv_3 empty; });
        var __rig_alive_current: bool = true;
        defer if (__rig_alive_current) { __rig_alive_current = false; current.__rig_drop(); }; _ = &current;
        current.push(cb.cloneStrong());
        var discarded: rig.Vec(*rig.RcBox(rig.Closure0)) = self.subs.value.replace(rig_mv_4: { __rig_alive_current = false; break :rig_mv_4 current; });
        var __rig_alive_discarded: bool = true;
        defer if (__rig_alive_discarded) { __rig_alive_discarded = false; discarded.__rig_drop(); }; _ = &discarded;
    }
    pub fn set(self: IntSource, v: i32) void {
        self.value.value.set(v);
        var empty: rig.Vec(*rig.RcBox(rig.Closure0)) = rig.Vec(*rig.RcBox(rig.Closure0)).init(rig.defaultAllocator());
        var __rig_alive_empty: bool = true;
        defer if (__rig_alive_empty) { __rig_alive_empty = false; empty.__rig_drop(); }; _ = &empty;
        var current: rig.Vec(*rig.RcBox(rig.Closure0)) = self.subs.value.replace(rig_mv_5: { __rig_alive_empty = false; break :rig_mv_5 empty; });
        var __rig_alive_current: bool = true;
        defer if (__rig_alive_current) { __rig_alive_current = false; current.__rig_drop(); }; _ = &current;
        if (current.buf) |__rig_p_3338| {
            var __rig_i_3338: usize = 0;
            while (__rig_i_3338 < current.len) : (__rig_i_3338 += 1) {
                const __rig_elem_3338 = &__rig_p_3338[__rig_i_3338];
                {
                    __rig_elem_3338.*.value.invoke();
                }
            }
        }
        var discarded: rig.Vec(*rig.RcBox(rig.Closure0)) = self.subs.value.replace(rig_mv_6: { __rig_alive_current = false; break :rig_mv_6 current; });
        var __rig_alive_discarded: bool = true;
        defer if (__rig_alive_discarded) { __rig_alive_discarded = false; discarded.__rig_drop(); }; _ = &discarded;
    }

    pub fn __rig_drop(self: *IntSource) void {
        self.subs.dropStrong();
        self.value.dropStrong();
    }
};

pub fn main() void {
    const count = IntSource.new(0);
    var __rig_alive_count: bool = true;
    defer if (__rig_alive_count) { __rig_alive_count = false; count.dropStrong(); };
    const body: *rig.RcBox(rig.Closure0) = rig_closure_0: {
        const Env = struct {
            cap_count: *rig.RcBox(IntSource),
            fn rigInvoke(ctx: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                std.debug.print("{any}\n", .{ self.cap_count.value.get() });
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
    var __rig_alive_body: bool = true;
    defer if (__rig_alive_body) { __rig_alive_body = false; body.dropStrong(); };
    count.value.subscribe(body.cloneStrong());
    count.value.set(1);
    count.value.set(7);
}
