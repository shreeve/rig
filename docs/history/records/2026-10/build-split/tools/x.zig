//! Calls between units. A function whose parameters and result the C
//! calling convention takes (integers, floats, bools, pointers that are
//! not slices, optional pointers, packed and extern objects) is exported
//! as itself, in the C convention, and called directly. Any other is
//! exported as a thunk taking its arguments, as a tuple, and the place
//! for its result, by pointer. Every unit is compiled by the same Zig
//! from the same declarations, so the tuple and the result have one
//! layout in all of them.
const std = @import("std");

pub const Thunk = *const fn (*const anyopaque, *anyopaque) callconv(.c) void;
const direct_calls = !@hasDecl(@import("root"), "__rig_tuple_calls_only");

fn Ret(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn cType(comptime T: type, comptime result: bool) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.bits <= 64,
        .bool, .float => true,
        .void => result,
        .pointer => |p| p.size != .slice and @typeInfo(p.child) != .@"fn",
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| p.size != .slice and @typeInfo(p.child) != .@"fn",
            else => false,
        },
        .@"struct" => |s| s.layout == .@"packed" and @sizeOf(T) <= 8,
        else => false,
    };
}

fn direct(comptime f: anytype) bool {
    if (!direct_calls) return false;
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.param_types.len > 8 or !cType(Ret(f), true)) return false;
    inline for (info.param_types) |p| if (!cType(p.?, false)) return false;
    return true;
}

fn Params(comptime f: anytype) []const type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    var ps: [info.param_types.len]type = undefined;
    for (info.param_types, 0..) |p, i| ps[i] = p.?;
    const out = ps;
    return &out;
}

fn CFn(comptime f: anytype) type {
    const ps = Params(f);
    const attrs: [ps.len]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    return @Fn(ps, &attrs, Ret(f), .{ .@"callconv" = .c });
}

pub inline fn call(comptime f: anytype, comptime sym: []const u8, args: std.meta.ArgsTuple(@TypeOf(f))) Ret(f) {
    if (comptime direct(f)) {
        const g = @extern(*const CFn(f), .{ .name = sym });
        return @call(.auto, g, args);
    }
    const t = @extern(Thunk, .{ .name = sym });
    var ret: Ret(f) = undefined;
    t(@ptrCast(&args), @ptrCast(&ret));
    return ret;
}

pub fn exportThunk(comptime f: anytype, comptime sym: []const u8) void {
    if (comptime direct(f)) {
        const P = Params(f);
        const R = Ret(f);
        const S = struct {
            fn c0() callconv(.c) R { return @call(.auto, f, .{}); }
            fn c1(a: P[0]) callconv(.c) R { return @call(.auto, f, .{a}); }
            fn c2(a: P[0], b: P[1]) callconv(.c) R { return @call(.auto, f, .{ a, b }); }
            fn c3(a: P[0], b: P[1], c: P[2]) callconv(.c) R { return @call(.auto, f, .{ a, b, c }); }
            fn c4(a: P[0], b: P[1], c: P[2], d: P[3]) callconv(.c) R { return @call(.auto, f, .{ a, b, c, d }); }
            fn c5(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4]) callconv(.c) R { return @call(.auto, f, .{ a, b, c, d, e }); }
            fn c6(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5]) callconv(.c) R { return @call(.auto, f, .{ a, b, c, d, e, g }); }
            fn c7(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6]) callconv(.c) R { return @call(.auto, f, .{ a, b, c, d, e, g, h }); }
            fn c8(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7]) callconv(.c) R { return @call(.auto, f, .{ a, b, c, d, e, g, h, i }); }
        };
        const t = switch (P.len) {
            0 => &S.c0, 1 => &S.c1, 2 => &S.c2, 3 => &S.c3, 4 => &S.c4,
            5 => &S.c5, 6 => &S.c6, 7 => &S.c7, 8 => &S.c8,
            else => unreachable,
        };
        @export(t, .{ .name = sym });
        return;
    }
    const S = struct {
        fn t(a: *const anyopaque, r: *anyopaque) callconv(.c) void {
            const args: *const std.meta.ArgsTuple(@TypeOf(f)) = @ptrCast(@alignCast(a));
            const rp: *Ret(f) = @ptrCast(@alignCast(r));
            rp.* = @call(.auto, f, args.*);
        }
    };
    @export(&S.t, .{ .name = sym });
}
