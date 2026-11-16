//! Scratch arms for std.sort's stable path, never committed as options:
//! (a) a buffered stable merge (natural runs, minrun 32 by binary
//! insertion, powersort merge order, merges through a buffer of n/2
//! elements that copy the shorter run), and (b) Zig's in-place block
//! merge sort (WikiSort, `std.sort.block`). Each with the closure's
//! compare (`FnRef`, indirect) and with `<` (`rig.compare`, direct).

const std = @import("std");
const rig = @import("../runtime.zig");

fn Less(comptime T: type) type {
    return rig.FnRef(&.{ rig.ReadView(T), rig.ReadView(T) }, bool);
}

fn closureLt(comptime T: type) fn (Less(T), T, T) bool {
    return struct {
        fn lt(less: Less(T), a: T, b: T) bool {
            return less.call(.{ rig.lend(&a), rig.lend(&b) });
        }
    }.lt;
}

fn ordLt(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn lt(_: void, a: T, b: T) bool {
            return rig.compare(a, .lt, b);
        }
    }.lt;
}

pub fn block_by(comptime T: type, xs: []T, less: Less(T)) void {
    std.sort.block(T, xs, less, closureLt(T));
}

pub fn block_ord(comptime T: type, xs: []T) void {
    std.sort.block(T, xs, {}, ordLt(T));
}

pub fn buffered_by(comptime T: type, xs: []T, less: Less(T)) void {
    buffered(T, xs, less, closureLt(T));
}

pub fn buffered_ord(comptime T: type, xs: []T) void {
    buffered(T, xs, {}, ordLt(T));
}

fn buffered(comptime T: type, xs: []T, ctx: anytype, comptime lt: fn (@TypeOf(ctx), T, T) bool) void {
    const n = xs.len;
    if (n < 2) return;
    if (n <= 20) {
        binaryInsertion(T, xs, 1, ctx, lt);
        return;
    }
    const buf = rig.defaultAllocator().alloc(T, n / 2 + 1) catch @panic("out of memory");
    defer rig.defaultAllocator().free(buf);
    const min_run: usize = 32;
    // Powersort: runs on a stack, each with its power; merge while the
    // top's power is not below the new boundary's.
    var starts: [128]usize = undefined;
    var powers: [128]u8 = undefined;
    var top: usize = 0;
    var start: usize = 0;
    var run_end = nextRun(T, xs, 0, min_run, ctx, lt);
    while (start < n) {
        const next_start = run_end;
        var next_end: usize = n;
        var power: u8 = 0;
        if (next_start < n) {
            next_end = nextRun(T, xs, next_start, min_run, ctx, lt);
            power = nodePower(n, start, next_start, next_end);
        }
        while (top > 0 and powers[top - 1] > power) {
            top -= 1;
            merge(T, xs, starts[top], start, next_start, buf, ctx, lt);
            start = starts[top];
        }
        if (next_start >= n) break;
        starts[top] = start;
        powers[top] = power;
        top += 1;
        start = next_start;
        run_end = next_end;
    }
}

fn nodePower(n: usize, a: usize, m: usize, b: usize) u8 {
    const n2: u128 = @as(u128, n) * 2;
    const l: u128 = @as(u128, a) + m; // 2 * midpoint of left run
    const r: u128 = @as(u128, m) + b;
    var p: u8 = 0;
    var x = (l << 64) / n2;
    var y = (r << 64) / n2;
    while (true) {
        p += 1;
        if ((x >> 63) != (y >> 63)) return p;
        x = (x << 1) & ((@as(u128, 1) << 64) - 1);
        y = (y << 1) & ((@as(u128, 1) << 64) - 1);
        if (p > 100) return p;
    }
}

/// The end of the run starting at `a`: a natural run (a strictly falling
/// one reversed), extended to `min_run` by binary insertion.
fn nextRun(comptime T: type, xs: []T, a: usize, min_run: usize, ctx: anytype, comptime lt: fn (@TypeOf(ctx), T, T) bool) usize {
    const n = xs.len;
    var e = a + 1;
    if (e >= n) return n;
    if (lt(ctx, xs[e], xs[a])) {
        while (e + 1 < n and lt(ctx, xs[e + 1], xs[e])) e += 1;
        std.mem.reverse(T, xs[a .. e + 1]);
    } else {
        while (e + 1 < n and !lt(ctx, xs[e + 1], xs[e])) e += 1;
    }
    e += 1;
    if (e - a < min_run) {
        const end = @min(n, a + min_run);
        binaryInsertion(T, xs[a..end], e - a, ctx, lt);
        return end;
    }
    return e;
}

fn binaryInsertion(comptime T: type, xs: []T, sorted: usize, ctx: anytype, comptime lt: fn (@TypeOf(ctx), T, T) bool) void {
    var i = sorted;
    while (i < xs.len) : (i += 1) {
        const x = xs[i];
        var lo: usize = 0;
        var hi: usize = i;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lt(ctx, x, xs[mid])) hi = mid else lo = mid + 1;
        }
        var j = i;
        while (j > lo) : (j -= 1) xs[j] = xs[j - 1];
        xs[lo] = x;
    }
}

/// Merge the sorted runs xs[a..m] and xs[m..b] through `buf`, copying
/// the shorter one out.
fn merge(comptime T: type, xs: []T, a: usize, m: usize, b: usize, buf: []T, ctx: anytype, comptime lt: fn (@TypeOf(ctx), T, T) bool) void {
    if (a >= m or m >= b) return;
    if (!lt(ctx, xs[m], xs[m - 1])) return; // already in order
    if (m - a <= b - m) {
        const left = buf[0 .. m - a];
        @memcpy(left, xs[a..m]);
        var i: usize = 0;
        var j = m;
        var k = a;
        while (i < left.len and j < b) : (k += 1) {
            if (lt(ctx, xs[j], left[i])) {
                xs[k] = xs[j];
                j += 1;
            } else {
                xs[k] = left[i];
                i += 1;
            }
        }
        @memcpy(xs[k .. k + left.len - i], left[i..]);
    } else {
        const right = buf[0 .. b - m];
        @memcpy(right, xs[m..b]);
        var i = m; // left elements xs[a..i]
        var j = right.len;
        var k = b;
        while (i > a and j > 0) {
            k -= 1;
            if (lt(ctx, right[j - 1], xs[i - 1])) {
                xs[k] = xs[i - 1];
                i -= 1;
            } else {
                xs[k] = right[j - 1];
                j -= 1;
            }
        }
        @memcpy(xs[k - j .. k], right[0..j]);
    }
}
