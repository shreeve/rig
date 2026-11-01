//! Split builds. A large program can be compiled as several units, each a
//! `zig build-obj`, and linked into one executable. Every unit compiles
//! the runtime, but the runtime's state is one per process: each of its
//! module-level variables is a cell, which unit 0 defines and exports and
//! every other unit reaches by its symbol.
//!
//! A unit's root declares `__rig_unit`, a namespace with its `id`, from
//! 0, and the `count` of units. A program compiled whole declares none:
//! it is unit 0 of one, and each of its cells is a plain variable.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

/// Whether this compilation is one unit of a split build.
pub const on = @hasDecl(root, "__rig_unit");
/// This unit's number: 0 in a build that is not split.
pub const unit: u32 = if (on) root.__rig_unit.id else 0;
/// Whether this unit defines the process's cells: unit 0, or the whole
/// program.
pub const main = unit == 0;

/// The cell of `v`, a module-level variable of the runtime: a pointer to
/// it, used in its place. Unit 0 holds the variable and, in a split
/// build, exports it as `name`; another unit's cell points to unit 0's by
/// that name instead, its own copy unused. Unit 0 refers to every cell of
/// a file it compiles (a `comptime` block beside them), since a unit
/// defines only the variables it refers to and another unit may need one
/// this one never uses.
pub fn cell(comptime v: anytype, comptime name: []const u8) @TypeOf(v) {
    const P = @typeInfo(@TypeOf(v)).pointer;
    const T = P.child;
    const symbol = "rig.cell." ++ name;
    if (!main) return @ptrCast(@extern(*align(P.attrs.@"align" orelse @alignOf(T)) [@sizeOf(T)]u8, .{ .name = symbol }));
    // Zig exports only a variable whose type has a defined layout, so the
    // variable is exported as its bytes.
    if (on) @export(@as(*const [@sizeOf(T)]u8, @ptrCast(v)), .{ .name = symbol });
    return v;
}

/// The running thread's `v`, a thread-local variable of the runtime. In a
/// split build every unit's is a slot of the block of thread-locals unit
/// 0 defines, `name` says which, and the slot starts as `v` starts: the
/// thread's first use copies this unit's own `v`, which nothing else
/// writes.
pub inline fn local(v: anytype, comptime name: []const u8) @TypeOf(v) {
    if (!on) return v;
    const T = @typeInfo(@TypeOf(v)).pointer.child;
    if (@sizeOf(T) >= slot_size or @alignOf(T) > slot_align) @compileError("split: the thread-local `" ++ name ++ "` does not fit a slot");
    const slot = block()[comptime slotOf(name) * slot_size..][0..slot_size];
    const at: @TypeOf(v) = @ptrCast(@alignCast(slot));
    if (slot[slot_size - 1] == 0) {
        slot[slot_size - 1] = 1;
        at.* = v.*;
    }
    return at;
}

/// The runtime's thread-locals in a split build, each a slot of the block.
const locals_named = [_][]const u8{
    "alloc.my_heap",
    "alloc.my_token",
    "sched.me_slot",
    "sched.waker",
    "runtime.thread_task",
    "runtime.panicking_here",
    "runtime.profile_next",
    "runtime.profile_scope",
    "runtime.trace_thread",
};
/// A slot's bytes: its variable's, then, last, whether its thread set it.
const slot_size = 256;
const slot_align = 64;

/// Unit 0's block of thread-locals, exported.
const Locals = if (on and main) struct {
    export threadlocal var @"rig.locals": [locals_named.len * slot_size]u8 align(slot_align) = @splat(0);
} else struct {};

comptime {
    _ = Locals;
}

inline fn block() *align(slot_align) [locals_named.len * slot_size]u8 {
    if (main) return &Locals.@"rig.locals";
    return @extern(*align(slot_align) [locals_named.len * slot_size]u8, .{ .name = "rig.locals", .is_thread_local = true });
}

fn slotOf(comptime name: []const u8) usize {
    for (locals_named, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    @compileError("split: no slot for the thread-local `" ++ name ++ "`");
}

// ---- Calls between units ------------------------------------------------
//
// A function a split build cuts (`units.decide`) starts, in every unit
// but its owner, with a call of the owner's (`away`, `call`); the owner
// exports it (`exportFn`). A function whose parameters and result the C
// calling convention takes (integers to 64 bits, floats, bools, pointers
// that are not slices, optional pointers, small packed objects) is
// exported as itself and called directly; any other through a thunk
// taking its arguments, as a tuple, and the place for its result, by
// pointer. Every unit is compiled by the same Zig from the same package,
// so the tuple and the result have one layout in all of them.

/// Whether a call of `f` in this unit goes to unit `owner`, which owns
/// it: in a split build, from every other unit, when every unit can call
/// it (`crosses`). Every unit decides alike.
pub fn away(comptime f: anytype, comptime owner: u32) bool {
    return on and unit != owner and crosses(f);
}

/// Whether every unit can call `f` through one signature: it takes no
/// compile-time parameter and returns.
fn crosses(comptime f: anytype) bool {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.is_generic or info.attrs.varargs) return false;
    const R = info.return_type orelse return false;
    return switch (@typeInfo(R)) {
        .noreturn, .type, .comptime_int, .comptime_float, .enum_literal => false,
        else => true,
    };
}

const Thunk = *const fn (*const anyopaque, *anyopaque) callconv(.c) void;

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

/// Call `f`, which unit `owner` exports as `sym` (`exportFn`).
pub inline fn call(comptime f: anytype, comptime sym: []const u8, args: std.meta.ArgsTuple(@TypeOf(f))) Ret(f) {
    if (comptime direct(f)) return @call(.auto, @extern(*const CFn(f), .{ .name = sym }), args);
    const thunk = @extern(Thunk, .{ .name = sym });
    var ret: Ret(f) = undefined;
    thunk(@ptrCast(&args), @ptrCast(&ret));
    return ret;
}

/// Export `f` as `sym` from unit `owner`, which owns it (`call`).
pub fn exportFn(comptime f: anytype, comptime sym: []const u8, comptime owner: u32) void {
    if (unit != owner or !crosses(f)) return;
    if (comptime direct(f)) {
        const P = Params(f);
        const R = Ret(f);
        const S = struct {
            fn c0() callconv(.c) R {
                return @call(.auto, f, .{});
            }
            fn c1(a: P[0]) callconv(.c) R {
                return @call(.auto, f, .{a});
            }
            fn c2(a: P[0], b: P[1]) callconv(.c) R {
                return @call(.auto, f, .{ a, b });
            }
            fn c3(a: P[0], b: P[1], c: P[2]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c });
            }
            fn c4(a: P[0], b: P[1], c: P[2], d: P[3]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c, d });
            }
            fn c5(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c, d, e });
            }
            fn c6(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c, d, e, g });
            }
            fn c7(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c, d, e, g, h });
            }
            fn c8(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7]) callconv(.c) R {
                return @call(.auto, f, .{ a, b, c, d, e, g, h, i });
            }
        };
        const t = switch (P.len) {
            0 => &S.c0,
            1 => &S.c1,
            2 => &S.c2,
            3 => &S.c3,
            4 => &S.c4,
            5 => &S.c5,
            6 => &S.c6,
            7 => &S.c7,
            8 => &S.c8,
            else => unreachable,
        };
        @export(t, .{ .name = sym });
        return;
    }
    const S = struct {
        fn thunk(a: *const anyopaque, r: *anyopaque) callconv(.c) void {
            const args: *const std.meta.ArgsTuple(@TypeOf(f)) = @ptrCast(@alignCast(a));
            const rp: *Ret(f) = @ptrCast(@alignCast(r));
            rp.* = @call(.auto, f, args.*);
        }
    };
    @export(&S.thunk, .{ .name = sym });
}

// ---- Starting a split program ---------------------------------------------

/// The units of the build: `count`, each a root `__rig_unit_K.zig`, and
/// the executable's root, `__rig_entry.zig`, numbered `count`.
pub const count: u32 = if (on) root.__rig_unit.count else 1;

/// Each compilation numbers errors in the order it first meets their
/// names, and a unit's error reaches another as its number. So each
/// unit's root names every error the program can make first (`All`,
/// `__rig_errseed.zig`), and the program checks at start that every
/// unit numbered them alike (`signature`).
fn signature(comptime All: type) u64 {
    @setEvalBranchQuota(100_000_000);
    var h: u64 = 1469598103934665603;
    inline for (@typeInfo(All).error_set.error_names.?) |name| h = (h ^ @intFromError(@field(anyerror, name))) *% 1099511628211;
    return h;
}

/// What each unit's root exports: its numbering of the errors, a way to
/// take the process's state from the entry's std, and in unit 0, the
/// program's start (`start`).
pub fn exportUnit(comptime All: type) void {
    const S = struct {
        fn errors() callconv(.c) u64 {
            return signature(All);
        }
        // Zig's start code sets std's process state only in the copy of
        // std the executable's root compiles: on Linux, the layout of
        // thread-local storage, which each thread a unit starts needs,
        // and the auxiliary vector, through which std finds the vDSO.
        fn share(aux: ?*anyopaque, area: *const anyopaque) callconv(.c) void {
            if (builtin.os.tag != .linux or builtin.link_libc) return;
            std.os.linux.elf_aux_maybe = @ptrCast(@alignCast(aux));
            std.os.linux.tls.area_desc = @as(*const @TypeOf(std.os.linux.tls.area_desc), @ptrCast(@alignCast(area))).*;
        }
        fn entry(init: *const anyopaque) callconv(.c) u8 {
            const mine = signature(All);
            inline for (0..count) |k| {
                const theirs = @extern(*const fn () callconv(.c) u64, .{ .name = std.fmt.comptimePrint("rigx_errors_{d}", .{k}) });
                if (theirs() != mine) @panic(std.fmt.comptimePrint("rig: unit {d} of a split build numbers errors differently", .{k}));
            }
            const result = root.__rig_program.main(@as(*const std.process.Init.Minimal, @ptrCast(@alignCast(init))).*);
            return if (@TypeOf(result) == void) 0 else result;
        }
    };
    @export(&S.errors, .{ .name = std.fmt.comptimePrint("rigx_errors_{d}", .{unit}) });
    @export(&S.share, .{ .name = std.fmt.comptimePrint("rigx_share_{d}", .{unit}) });
    if (unit == 0) @export(&S.entry, .{ .name = "rigx_entry" });
}

/// The executable's `main`: hand each unit the process's state, then
/// start the program in unit 0 (`exportUnit`).
pub fn start(init: std.process.Init.Minimal) u8 {
    if (builtin.os.tag == .linux and !builtin.link_libc) inline for (0..count) |k| {
        const share = @extern(*const fn (?*anyopaque, *const anyopaque) callconv(.c) void, .{ .name = std.fmt.comptimePrint("rigx_share_{d}", .{k}) });
        share(@ptrCast(std.os.linux.elf_aux_maybe), @ptrCast(&std.os.linux.tls.area_desc));
    };
    const entry = @extern(*const fn (*const anyopaque) callconv(.c) u8, .{ .name = "rigx_entry" });
    return entry(@ptrCast(&init));
}

var test_a = false;
var test_b = false;
threadlocal var test_c: u8 = 7;

test "a cell is its variable; a thread-local starts as its variable" {
    const a = cell(&test_a, "test.a");
    const b = cell(&test_b, "test.b");
    a.* = true;
    try std.testing.expect(test_a and !b.*);
    try std.testing.expectEqual(@as(u8, 7), local(&test_c, "test.c").*);
}

test "a slot for each thread-local, each named once" {
    for (locals_named, 0..) |a, i| for (locals_named[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "unit 0 refers to every cell" {
    const files = [_][]const u8{ @embedFile("runtime.zig"), @embedFile("alloc.zig"), @embedFile("sched.zig"), @embedFile("tasks.zig"), @embedFile("net.zig") };
    for (files) |text| {
        const from = std.mem.indexOf(u8, text, "if (split.on and split.main) _ = .{") orelse return error.NoCellList;
        const end = std.mem.indexOfPos(u8, text, from, "};").?;
        const listed = text[from..end];
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const at = std.mem.indexOf(u8, line, " = split.cell(") orelse continue;
            const decl = std.mem.trimStart(u8, line[0..at], " ");
            const name = decl[std.mem.lastIndexOfScalar(u8, decl, ' ').? + 1 ..];
            // A nested cell is listed by its container: `lent.next`.
            var a: [64]u8 = undefined;
            var b: [64]u8 = undefined;
            const plain = try std.fmt.bufPrint(&a, " {s},", .{name});
            const nested = try std.fmt.bufPrint(&b, ".{s},", .{name});
            if (std.mem.indexOf(u8, listed, plain) == null and std.mem.indexOf(u8, listed, nested) == null) {
                std.debug.print("cell `{s}` is missing from its file's list\n", .{name});
                return error.Unlisted;
            }
        }
    }
}
