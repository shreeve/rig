const std = @import("std");
const rig = @import("rig/runtime.zig");
const m1 = @import("__rig_std_json.zig");

pub const Glue = struct {
    const Ops = rig.ErrorGlueOps;
    pub const size: usize = @max(1, @sizeOf(m1.JsonError__bad));
    pub const alignment: usize = @max(1, @alignOf(m1.JsonError__bad));
    pub fn drop(code: anyerror, data: *rig.ErrData) void {
        switch (code) {
            error.@"std.json.JsonError.bad" => return Ops(m1.JsonError__bad).drop(data),
            else => return {},
        }
    }
    pub fn clone(code: anyerror, src: *const rig.ErrData, dst: *rig.ErrData) void {
        switch (code) {
            error.@"std.json.JsonError.bad" => return Ops(m1.JsonError__bad).clone(src, dst),
            else => return {},
        }
    }
    pub fn eql(code: anyerror, a: *const rig.ErrData, b: *const rig.ErrData) bool {
        _ = &a;
        _ = &b;
        switch (code) {
            error.@"std.json.JsonError.bad" => return Ops(m1.JsonError__bad).eqlFields(a, b),
            else => return true,
        }
    }
    pub fn hash(code: anyerror, data: *const rig.ErrData) u64 {
        _ = &data;
        switch (code) {
            error.@"std.json.JsonError.bad" => return Ops(m1.JsonError__bad).hash(data),
            else => return 0,
        }
    }
    pub fn print(code: anyerror, data: *const rig.ErrData, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (code) {
            error.@"std.json.JsonError.bad" => return Ops(m1.JsonError__bad).print(rig.errorShown(code), data, w),
            else => return w.writeAll(rig.errorShown(code)),
        }
    }
};
