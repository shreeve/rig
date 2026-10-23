const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_m2_std_json = @import("__rig_std_json.zig");

pub const panic = rig.panic;

pub fn main(__rig_init: std.process.Init.Minimal) void {
    rig.onOwnStack(__rig_run_main, .{__rig_init});
}

fn __rig_run_main(__rig_init: std.process.Init.Minimal) void {
    @setEvalBranchQuota(rig.eval_quota);
    rig.start(__rig_init);
    defer rig.finish();
    var src: []const u8 = "{\"name\": \"Ada\", \"born\": 1815, \"langs\": [\"en\", \"fr\"], \"ratio\": 0.5, \"notes\": {\"x\": [1, 2]}}"; _ = &src;
    var doc = rig.rt(__rig_m2_std_json.new_doc());
    defer rig.drop(&doc);
    if (!rig.rt(doc.parse(src))) {
        rig.print(.{ "error", " ", rig.rt(__rig_m2_std_json.error_name(doc.@"error")), " ", "at byte", " ", doc.error_pos, "\n" });
        return;
    }
    rig.print(.{ rig.rt(doc.size()), " ", rig.rt(doc.kind(0)), "\n" });
    var i: i64 = 1;
    while (true) {
        if (!(rig.rt(doc.kind(i)) != .object_end)) break;
        {
            const key: []const u8 = rig.rt(doc.get_str(i));
            i += 1;
            const k: __rig_m2_std_json.Kind = rig.rt(doc.kind(i));
            if (k == .string) {
                rig.print(.{ key, " ", "is the text", " ", rig.rt(doc.get_str(i)), "\n" });
            } else if (k == .int) {
                rig.print(.{ key, " ", "is the integer", " ", rig.rt(doc.get_int(i)), "\n" });
            } else if (k == .float) {
                rig.print(.{ key, " ", "is the float", " ", rig.rt(doc.get_float(i)), "\n" });
            } else if (k == .array) {
                rig.print(.{ key, " ", "holds", "\n" });
                {
                    var __rig_i_7: i64 = i + 1;
                    const __rig_end_7: i64 = rig.rt(doc.next(i)) - 1;
                    while (__rig_i_7 < __rig_end_7) : (__rig_i_7 += 1) {
                        const j = __rig_i_7;
                        rig.print(.{ "-", " ", rig.rt(doc.get_str(j)), "\n" });
                    }
                }
            } else {
                rig.print(.{ key, " ", "is skipped", "\n" });
            }
            { const __rig_new_8: i64 = rig.rt(doc.next(i)); i = __rig_new_8; }
        }
    }
    var bad: []const u8 = "[1, 2"; _ = &bad;
    var again = rig.rt(__rig_m2_std_json.new_doc());
    defer rig.drop(&again);
    if (!rig.rt(again.parse(bad))) {
        rig.print(.{ rig.rt(__rig_m2_std_json.error_name(again.@"error")), " ", "at byte", " ", again.error_pos, "\n" });
    }
}

pub const __rig_sanitize = true;
pub const __rig_run_started = "RIG_PROGRAM_STARTED";

pub const __rig_error_glue = @import("__rig_errors.zig").Glue;
