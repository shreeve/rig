// One cell of the checked lane arithmetic grid, chosen by arguments:
//
//   lane_grid <impl> <op> <type> <lanes> <clean|ovf> <seed> [lane]
//
// `impl` is how the operation is made:
//   plain      Zig's own `a + b` (and `-`, `*`, `-a`) on the vector
//   intrinsic  `@addWithOverflow` (and `@subWithOverflow`, `@mulWithOverflow`)
//              with a branch to a panic on any flag: what `plain` lowers to
//   rig        the runtime's `vecAdd`, `vecSub`, `vecMul`, `vecNeg`
//
// `clean` feeds vectors no lane of which overflows, and must return the
// wrapped result. `ovf` makes lane `lane` overflow, and must panic. Exit
// status: 0 correct; 3 a wrong value; 4 no panic on an overflow (missed).
// A panic on a clean vector is a false overflow: the process aborts.
// Vectors are loaded from bytes by a noinline function, so nothing folds
// at compile time. `lane_grid.py` runs the grid, and builds only the ways
// it was asked for (the module `impls`, a `list` of them).
const std = @import("std");
const rig = @import("rig");

pub const Impl = enum { plain, intrinsic, rig };
const Op = enum { add, sub, mul, neg };

noinline fn load(comptime T: type, comptime n: usize, b: []const u8) @Vector(n, T) {
    const size = @sizeOf(T);
    var out: [n]T = undefined;
    for (&out, 0..) |*o, i| o.* = std.mem.readInt(T, b[i * size ..][0..size], .little);
    return out;
}

noinline fn apply(comptime impl: Impl, comptime op: Op, comptime T: type, comptime n: usize, a: @Vector(n, T), b: @Vector(n, T)) @Vector(n, T) {
    const V = @Vector(n, T);
    const zero: V = @splat(0);
    switch (impl) {
        .plain => return switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .neg => -a,
        },
        .intrinsic => {
            const r = switch (op) {
                .add => @addWithOverflow(a, b),
                .sub => @subWithOverflow(a, b),
                .mul => @mulWithOverflow(a, b),
                .neg => @subWithOverflow(zero, a),
            };
            if (@reduce(.Or, r[1] != @as(@Vector(n, u1), @splat(0)))) @panic("integer overflow");
            return r[0];
        },
        .rig => return switch (op) {
            .add => rig.vecAdd(a, b),
            .sub => rig.vecSub(a, b),
            .mul => rig.vecMul(a, b),
            .neg => rig.vecNeg(a),
        },
    }
}

fn scalar(comptime op: Op, comptime T: type, a: T, b: T) struct { T, bool } {
    const r = switch (op) {
        .add => @addWithOverflow(a, b),
        .sub => @subWithOverflow(a, b),
        .mul => @mulWithOverflow(a, b),
        .neg => @subWithOverflow(@as(T, 0), a),
    };
    return .{ r[0], r[1] != 0 };
}

fn overflowPair(comptime op: Op, comptime T: type) [2]T {
    const signed = @typeInfo(T).int.signedness == .signed;
    return switch (op) {
        .add => .{ std.math.maxInt(T), 1 },
        .sub => .{ if (signed) std.math.minInt(T) else 0, 1 },
        .mul => .{ std.math.maxInt(T), 2 },
        .neg => .{ std.math.minInt(T), 0 },
    };
}

fn cell(comptime impl: Impl, comptime op: Op, comptime T: type, comptime n: usize, ovf: bool, seed: u64, at: usize) u8 {
    const size = @sizeOf(T);
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    var xs: [n]T = undefined;
    var ys: [n]T = undefined;
    const same = seed % 2 == 0;
    const picks = [_]T{ 0, 1, std.math.maxInt(T), std.math.minInt(T), std.math.maxInt(T) / 2, std.math.minInt(T) / 2 };
    for (0..n) |i| {
        // Each lane is small, an extreme, or uniform; one that would
        // overflow becomes zero.
        for ([2]*T{ &xs[i], &ys[i] }) |p| p.* = switch (r.uintLessThan(u8, 3)) {
            0 => @intCast(r.uintLessThan(u8, 50)),
            1 => picks[r.uintLessThan(usize, picks.len)],
            else => r.int(T),
        };
        if (same) ys[i] = xs[i];
        if (scalar(op, T, xs[i], ys[i])[1]) {
            xs[i] = 0;
            ys[i] = 0;
        }
    }
    if (ovf) {
        const pair = overflowPair(op, T);
        xs[at] = pair[0];
        ys[at] = if (same and op != .neg) pair[0] else pair[1];
        if (same and !scalar(op, T, xs[at], ys[at])[1]) {
            // The same operand twice overflows these (`x + x`, `x * x`);
            // `x - x` and the like cannot, so such a cell has no overflow.
            return 0;
        }
    }
    var buf_a: [n * size]u8 = undefined;
    var buf_b: [n * size]u8 = undefined;
    for (0..n) |i| {
        std.mem.writeInt(T, buf_a[i * size ..][0..size], xs[i], .little);
        std.mem.writeInt(T, buf_b[i * size ..][0..size], ys[i], .little);
    }
    const a = load(T, n, &buf_a);
    const b = if (same) a else load(T, n, &buf_b);
    const got: [n]T = apply(impl, op, T, n, a, b);
    if (ovf) return 4;
    for (0..n) |i| if (got[i] != scalar(op, T, xs[i], ys[i])[0]) return 3;
    return 0;
}

/// Ends the process as a panic's abort does, with status 134, but by
/// exiting: a crash reporter that the kernel starts for each abort (apport
/// on Ubuntu) would cost each `ovf` cell a second or more.
fn exitOnAbort(_: std.posix.SIG) callconv(.c) void {
    std.process.exit(134);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = exitOnAbort }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.ABRT, &act, null);
    var it = init.args.iterate();
    _ = it.next();
    const impl_name = it.next().?;
    const op_name = it.next().?;
    const type_name = it.next().?;
    const lanes = std.fmt.parseInt(usize, it.next().?, 10) catch unreachable;
    const ovf = std.mem.eql(u8, it.next().?, "ovf");
    const seed = std.fmt.parseInt(u64, it.next().?, 10) catch unreachable;
    const at = if (it.next()) |s| std.fmt.parseInt(usize, s, 10) catch unreachable else 0;
    inline for (@import("impls").list) |impl| {
        inline for (comptime std.enums.values(Op)) |op| {
            inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
                inline for (.{ 2, 4, 8, 16, 32, 64 }) |n| {
                    if (comptime !(op == .neg and @typeInfo(T).int.signedness == .unsigned)) {
                        if (lanes == n and std.mem.eql(u8, impl_name, @tagName(impl)) and
                            std.mem.eql(u8, op_name, @tagName(op)) and std.mem.eql(u8, type_name, @typeName(T)))
                            return cell(impl, op, T, n, ovf, seed, at % n);
                    }
                }
            }
        }
    }
    return 2;
}
