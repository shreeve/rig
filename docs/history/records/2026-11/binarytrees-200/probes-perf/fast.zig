const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_m2_std_math = @import("__rig_std_math.zig");

const __rig_m3_std_os = @import("__rig_std_os.zig");

const __rig_m6_std_par = @import("__rig_std_par.zig");

const __rig_m7_std_text = @import("__rig_std_text.zig");

pub const MIN_DEPTH: i64 = 4;

pub const RUNS: i64 = 64;

pub const Node = packed struct(u64) {
    pub const __rig_word_sized = {};
    left: i32 = -1,
    right: i32 = -1,
    pub const __rig_name = .{ .module = "", .name = .{ "Node" } };
};

pub fn bottom_up_tree(pool: *rig.List(Node), depth: i64) linksection(rig.preempt_section) i32 {
    @setEvalBranchQuota(rig.eval_quota);
    rig.tickCall();
    const at: i64 = rig.lenOf(pool);
    pool.push(Node{});
    if (depth > 0) {
        const right: i32 = bottom_up_tree(pool, depth - 1);
        const left: i32 = bottom_up_tree(pool, depth - 1);
        { const __rig_new_1: Node = Node{ .left = left, .right = right }; const __rig_ix_1_1: i64 = at; pool.*.slotProven(__rig_ix_1_1, .lower).* = __rig_new_1; }
    }
    return @as(i32, @intCast(@as(i64, at)));
}

pub fn item_check(pool: *const rig.List(Node), at: i32) linksection(rig.preempt_section) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    rig.tickCall();
    const n = pool.*.at(@as(i64, @intCast(@as(i32, at))));
    if (n.left < 0) {
        return 1;
    }
    return (1 + item_check(pool, n.right)) + item_check(pool, n.left);
}

pub inline fn run(__rig_in_depth: i64, __rig_in_count: i64) i64 {
    const depth = rig.rt(__rig_in_depth);
    const count = rig.rt(__rig_in_count);
    var pool = rig.List(Node).empty;
    defer rig.drop(&pool);
    var chk: i64 = 0;
    {
        var __rig_turns_5: u32 = rig.tick_turns;
        var __rig_i_6: i64 = 0;
        const __rig_end_6: i64 = count;
        while (__rig_i_6 < __rig_end_6) : ({ rig.turn(&__rig_turns_5); __rig_i_6 += 1; }) {
            pool.keep(0);
            const root: i32 = bottom_up_tree(&pool, depth);
            { const __rig_new_7: i64 = item_check(&pool, root); chk += __rig_new_7; }
        }
    }
    return chk;
}

pub fn inner(depth: i64, iterations: i64) linksection(rig.preempt_section) rig.String {
    @setEvalBranchQuota(rig.eval_quota);
    var runs = rig.List(i64).empty;
    defer rig.drop(&runs);
    const per: i64 = @divTrunc((iterations + rig.rt(RUNS)) - 1, rig.rt(RUNS));
    var left: i64 = iterations;
    {
        var __rig_turns_11: u32 = rig.tick_turns;
        while (true) : ({ rig.turn(&__rig_turns_11); { left -= per; } }) {
            if (!(left > 0)) break;
            {
                runs.push(rig.rt(__rig_m2_std_math.min(i64, per, left)));
            }
        }
    }
    var __rig_tmp_13: rig.List(i64) = undefined; var __rig_tmp_13_live = false; defer if (__rig_tmp_13_live) rig.drop(&__rig_tmp_13); const chk: i64 = rig.sum(rig.keep(&__rig_tmp_13, &__rig_tmp_13_live, __rig_call_14: {
        const __rig_arg_14_0: []const i64 = runs.items();
        var __rig_env_15 = struct {
            cap_depth: i64,

            pub fn __rig_invoke(__rig_self: *@This(), count: i64) linksection(rig.preempt_section) i64 {
                @setEvalBranchQuota(rig.eval_quota);
                return rig.rt(run(__rig_self.cap_depth, count));
            }
        }{ .cap_depth = depth };
        const __rig_arg_14_1 = rig.FnRef(&.{ i64 }, i64).of(@TypeOf(__rig_env_15), &__rig_env_15);
        break :__rig_call_14 rig.parMapInto(__rig_arg_14_0, __rig_arg_14_1, 0, rig.no_slot);
    }).*.items(), 0); if (__rig_tmp_13_live) { __rig_tmp_13_live = false; rig.drop(&__rig_tmp_13); }
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
    const n: i64 = @as(i64, if (rig.lenOf(args) > 1) try (__rig_rt_16: { var __rig_v_16 = __rig_m7_std_text.parse_int(rig.at(args, 1), 10, __out); _ = &__rig_v_16; break :__rig_rt_16 __rig_v_16; }) else 10);
    const max_depth: i64 = rig.rt(__rig_m2_std_math.max(i64, n, @as(i64, 6)));
    const stretch: i64 = max_depth + 1;
    var __rig_tmp_17: rig.String = undefined; var __rig_tmp_17_live = false; defer if (__rig_tmp_17_live) rig.drop(&__rig_tmp_17); rig.print(.{ rig.keep(&__rig_tmp_17, &__rig_tmp_17_live, rig.String.of(.{ "stretch tree of depth ", stretch, "\t check: ", rig.rt(run(stretch, 1)) })).*, "\n" }); if (__rig_tmp_17_live) { __rig_tmp_17_live = false; rig.drop(&__rig_tmp_17); }
    var long_lived = rig.List(Node).empty;
    defer rig.drop(&long_lived);
    const long_root: i32 = bottom_up_tree(&long_lived, max_depth);
    var depths = rig.List(i64).empty;
    defer rig.drop(&depths);
    var depth: i64 = MIN_DEPTH;
    {
        var __rig_turns_21: u32 = rig.tick_turns;
        while (true) : ({ rig.turn(&__rig_turns_21); { depth += 2; } }) {
            if (!(depth <= max_depth)) break;
            {
                depths.push(depth);
            }
        }
    }
    var messages = __rig_call_23: {
        const __rig_arg_23_0: []const i64 = depths.items();
        var __rig_env_24 = struct {
            cap_max_depth: i64,

            pub fn __rig_invoke(__rig_self: *@This(), d: i64) linksection(rig.preempt_section) rig.String {
                @setEvalBranchQuota(rig.eval_quota);
                return inner(d, @shlExact(@as(i64, 1), rig.shiftAmount(i64, (__rig_self.cap_max_depth - d) + rig.rt(MIN_DEPTH))));
            }
        }{ .cap_max_depth = max_depth };
        const __rig_arg_23_1 = rig.FnRef(&.{ i64 }, rig.String).of(@TypeOf(__rig_env_24), &__rig_env_24);
        break :__rig_call_23 rig.parMapInto(__rig_arg_23_0, __rig_arg_23_1, 0, rig.no_slot);
    };
    defer rig.drop(&messages);
    {
        var __rig_turns_28: u32 = rig.tick_turns;
        for (messages.items()) |*__rig_elem_30| {
            rig.turn(&__rig_turns_28);
            const message = __rig_elem_30.bytes();
            rig.print(.{ message, "\n" });
        }
    }
    const check: i64 = item_check(&long_lived, long_root);
    var __rig_tmp_31: rig.String = undefined; var __rig_tmp_31_live = false; defer if (__rig_tmp_31_live) rig.drop(&__rig_tmp_31); rig.print(.{ rig.keep(&__rig_tmp_31, &__rig_tmp_31_live, rig.String.of(.{ "long lived tree of depth ", max_depth, "\t check: ", check })).*, "\n" }); if (__rig_tmp_31_live) { __rig_tmp_31_live = false; rig.drop(&__rig_tmp_31); }
}

pub const __rig_tasks = true;
pub const __rig_task_guard: usize = 16777216;
pub const __rig_dense_stride: usize = 1048576;
pub const __rig_start_early = true;
pub const __rig_preempt = true;
note: the package (every module and the runtime, rig/runtime.zig) is in /Users/shreeve/.cache/rig/binarytrees-fast-e410e8d47641606e
