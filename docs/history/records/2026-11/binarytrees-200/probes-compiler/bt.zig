const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_m2_std_math = @import("__rig_std_math.zig");

const __rig_m3_std_os = @import("__rig_std_os.zig");

const __rig_m6_std_text = @import("__rig_std_text.zig");

pub const MIN_DEPTH: i64 = 4;

pub const Tree = struct {
    left: rig.Opt(rig.Box(Tree)) = rig.pack(rig.Opt(rig.Box(Tree)), null),
    right: rig.Opt(rig.Box(Tree)) = rig.pack(rig.Opt(rig.Box(Tree)), null),
    pub const __rig_name = .{ .module = "", .name = .{ "Tree" } };
};

pub fn bottom_up_tree(depth: i64) linksection(rig.preempt_section) Tree {
    @setEvalBranchQuota(rig.eval_quota);
    rig.tickCall();
    if (depth == 0) {
        return Tree{};
    }
    return Tree{ .left = rig.pack(rig.Opt(rig.Box(Tree)), rig.Box(Tree).init(bottom_up_tree(depth - 1))), .right = rig.pack(rig.Opt(rig.Box(Tree)), rig.Box(Tree).init(bottom_up_tree(depth - 1))) };
}

pub fn item_check(t: *const Tree) linksection(rig.preempt_section) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    rig.tickCall();
    if (rig.somePtr(&(t.left))) |__rig_opt_1| {
        const l = __rig_opt_1;
        if (rig.somePtr(&(t.right))) |__rig_opt_2| {
            const r = __rig_opt_2;
            return (1 + item_check(rig.readView((l).value))) + item_check(rig.readView((r).value));
        }
    }
    return 1;
}

pub inline fn inner(__rig_in_depth: i64, __rig_in_iterations: i64) rig.String {
    const depth = rig.rt(__rig_in_depth);
    const iterations = rig.rt(__rig_in_iterations);
    var chk: i64 = 0;
    {
        var __rig_turns_6: u32 = rig.tick_turns;
        var __rig_i_7: i64 = 0;
        const __rig_end_7: i64 = iterations;
        while (__rig_i_7 < __rig_end_7) : ({ rig.turn(&__rig_turns_6); __rig_i_7 += 1; }) {
            var __rig_tmp_8: Tree = undefined; var __rig_tmp_8_live = false; defer if (__rig_tmp_8_live) rig.drop(&__rig_tmp_8); { const __rig_new_9: i64 = item_check(&rig.keep(&__rig_tmp_8, &__rig_tmp_8_live, bottom_up_tree(depth)).*); chk += __rig_new_9; } if (__rig_tmp_8_live) { __rig_tmp_8_live = false; rig.drop(&__rig_tmp_8); }
        }
    }
    return rig.String.of(.{ iterations, "\t trees of depth ", depth, "\t check: ", chk });
}

pub const panic = rig.panic;
pub const std_options = rig.std_options;

pub const __rig_interrupt = true;

pub fn main(__rig_init: std.process.Init.Minimal) void {
    return rig.onOwnStack(__rig_fail_main, .{__rig_init});
}

fn __rig_fail_main(__rig_init: std.process.Init.Minimal) void {
    var __rig_main_slot: rig.ErrData = undefined;
    const result = __rig_run_main(__rig_init, rig.failSlot(&__rig_main_slot)) catch |__rig_failed| {
        rig.reportFailure(__rig_failed, &__rig_main_slot);
        rig.finish();
        rig.failMainReported(__rig_failed);
    };
    rig.finish();
    return result;
}

fn __rig_run_main(__rig_init: std.process.Init.Minimal, __out: rig.ErrSlot) linksection(rig.preempt_section) anyerror!void {
    @setEvalBranchQuota(rig.eval_quota);
    rig.start(__rig_init);
    _ = &__out;
    const args = __rig_m3_std_os.args();
    const n: i64 = @as(i64, if (rig.lenOf(args) > 1) try (__rig_rt_10: { var __rig_v_10 = __rig_m6_std_text.parse_int(rig.at(args, 1), 10, __out); _ = &__rig_v_10; break :__rig_rt_10 __rig_v_10; }) else 10);
    const max_depth: i64 = rig.rt(__rig_m2_std_math.max(i64, n, @as(i64, 6)));
    const stretch: i64 = max_depth + 1;
    var __rig_tmp_11: Tree = undefined; var __rig_tmp_11_live = false; defer if (__rig_tmp_11_live) rig.drop(&__rig_tmp_11); const check: i64 = item_check(&rig.keep(&__rig_tmp_11, &__rig_tmp_11_live, bottom_up_tree(stretch)).*); if (__rig_tmp_11_live) { __rig_tmp_11_live = false; rig.drop(&__rig_tmp_11); }
    var __rig_tmp_12: rig.String = undefined; var __rig_tmp_12_live = false; defer if (__rig_tmp_12_live) rig.drop(&__rig_tmp_12); rig.print(.{ rig.keep(&__rig_tmp_12, &__rig_tmp_12_live, rig.String.of(.{ "stretch tree of depth ", stretch, "\t check: ", check })).*, "\n" }); if (__rig_tmp_12_live) { __rig_tmp_12_live = false; rig.drop(&__rig_tmp_12); }
    var long_lived = bottom_up_tree(max_depth);
    defer rig.drop(&long_lived);
    var messages = rig.Tasks(rig.String){};
    var __rig_alive_messages = true;
    defer if (__rig_alive_messages) { __rig_alive_messages = false; rig.drop(&messages); };
    var depth: i64 = MIN_DEPTH;
    {
        var __rig_turns_16: u32 = rig.tick_turns;
        while (true) : ({ rig.turn(&__rig_turns_16); { depth += 2; } }) {
            if (!(depth <= max_depth)) break;
            {
                messages.add(rig.Task(rig.String).spawn(inner, .{ depth, @shlExact(@as(i64, 1), rig.shiftAmount(i64, (max_depth - depth) + rig.rt(MIN_DEPTH))) }));
            }
        }
    }
    var done = rig.take(&__rig_alive_messages, messages).wait_allInto(rig.no_slot);
    defer rig.drop(&done);
    {
        var __rig_turns_21: u32 = rig.tick_turns;
        for (done.items()) |*__rig_elem_23| {
            rig.turn(&__rig_turns_21);
            const message = __rig_elem_23.bytes();
            rig.print(.{ message, "\n" });
        }
    }
    var __rig_tmp_24: rig.String = undefined; var __rig_tmp_24_live = false; defer if (__rig_tmp_24_live) rig.drop(&__rig_tmp_24); rig.print(.{ rig.keep(&__rig_tmp_24, &__rig_tmp_24_live, rig.String.of(.{ "long lived tree of depth ", max_depth, "\t check: ", item_check(&long_lived) })).*, "\n" }); if (__rig_tmp_24_live) { __rig_tmp_24_live = false; rig.drop(&__rig_tmp_24); }
}

pub const __rig_tasks = true;
pub const __rig_task_guard: usize = 16777216;
pub const __rig_dense_stride: usize = 1048576;
pub const __rig_start_early = true;
pub const __rig_preempt = true;
