//! `std.sort`: what its sorts need that Rig cannot say in Rig. The one
//! fact about a type, decided where `rig.order` decides how the type
//! orders; the stable sort's room, memory for elements none of which it
//! owns; and the stable sort's kernels, the loops that move elements
//! between the slice and the room while they compare them.
//!
//! A move here copies an element's bits and drops nothing: the slot it
//! is written to held no element (a slot of the room, or one a move
//! emptied), and the slot it is read from holds none after, until a move
//! fills it again. Each kernel leaves every element of its range in the
//! range exactly once whatever `less` answers, an order or not: a
//! partition writes element `i` to room slot `left` or `len - 1 - i +
//! left`, which no other element takes; a merge stops at either run's
//! end; a bidirectional merge that finds `less` no order copies back the
//! halves it merged from. A panic in `less` midway leaves some elements
//! in the slice and the room at once, but a panic runs no drop (SPEC
//! §17), so neither copy is dropped.
//!
//! The kernels follow driftsort's (Orson Peters and Lukas Bergdoll,
//! Rust's `slice::sort`); sort.rig has the algorithm. Each checks the
//! range it is given and then runs without Zig's safety checks, as
//! Rust's runs without its bounds checks: every index inside is bounded
//! by the loop that makes it, whatever `less` answers. Each is `inline`,
//! so the closure's call, a constant where `sort_by` is inlined into its
//! caller, is inlined in turn.

const std = @import("std");
const rig = @import("../runtime.zig");

/// Whether two `T`s that `<` finds equal are the same value
/// (`rig.orderIsIdentity`), known when the program compiles.
pub inline fn equal_is_same(comptime T: type) bool {
    return comptime rig.orderIsIdentity(T);
}

/// A room's memory is aligned for any element.
const room_align: std.mem.Alignment = .@"64";

/// The address of memory for `n` `T`s, none of them written; 64 when
/// they take no bytes.
pub fn room_alloc(comptime T: type, n: i64) i64 {
    comptime std.debug.assert(@alignOf(T) <= room_align.toByteUnits());
    const bytes = room_bytes(T, n);
    if (bytes == 0) return @intCast(room_align.toByteUnits());
    const p = rig.defaultAllocator().rawAlloc(@intCast(bytes), room_align, @returnAddress()) orelse rig.oom();
    return @intCast(@intFromPtr(p));
}

/// The bytes `n` `T`s take.
pub fn room_bytes(comptime T: type, n: i64) i64 {
    return @intCast(std.math.mul(usize, @sizeOf(T), @intCast(n)) catch rig.oom());
}

/// Free the `bytes` bytes at `addr` that `room_alloc` gave, dropping no
/// element.
pub fn room_free(addr: i64, bytes: i64) void {
    if (bytes == 0) return;
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    rig.defaultAllocator().rawFree(p[0..@intCast(bytes)], room_align, @returnAddress());
}

/// The room `r` holds (`sort.Room`), as a slice of its `cap` slots.
pub inline fn room_slots(comptime T: type, r: anytype) []T {
    const p: [*]T = @ptrFromInt(@as(usize, @intCast(r.addr)));
    return p[0..@intCast(r.cap)];
}

/// The scratch a stable sort of `n` `T`s partitions and merges through,
/// as driftsort sizes it: half of them, or all of them while they take at
/// most 8 MB, and at least 48 (a small sort's 32 and 16 more).
pub inline fn scratch_len(comptime T: type, n: i64) i64 {
    const full: i64 = if (@sizeOf(T) == 0) n else @min(n, @as(i64, 8_000_000 / @sizeOf(T)));
    return @max(@max(n - @divTrunc(n, 2), full), small_max + 16);
}

/// Move `from[i]` to `to[at]`.
pub inline fn move_one(comptime T: type, to: []T, at: i64, from: []const T, i: i64) void {
    to[@intCast(at)] = from[@intCast(i)];
}

const small_max = 32;

/// An element as one integer where it is the size of one, which LLVM keeps
/// in registers; an object of two fields it may move through the stack
/// when several are live, and read back before the store has landed.
fn Bits(comptime T: type) type {
    return switch (@sizeOf(T)) {
        1, 2, 4, 8, 16 => @Int(.unsigned, @sizeOf(T) * 8),
        else => T,
    };
}

inline fn bits(comptime T: type, p: [*]const T) *align(@alignOf(T)) Bits(T) {
    @setRuntimeSafety(false);
    return @ptrCast(@constCast(p));
}

/// `a` belongs before `b` by `less`.
inline fn lt(less: anytype, a: anytype, b: anytype) bool {
    return less.call(.{ rig.lend(a), rig.lend(b) });
}

/// `xs[lo..hi]`, its range checked.
inline fn range(comptime T: type, xs: []T, lo: i64, hi: i64) [*]T {
    if (lo < 0 or lo > hi or hi > xs.len) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    return xs.ptr + @as(usize, @intCast(lo));
}

/// Sort `xs[lo..hi]` by insertion.
pub inline fn insertion_by(comptime T: type, xs: []T, lo: i64, hi: i64, less: anytype) void {
    const v = range(T, xs, lo, hi);
    @setRuntimeSafety(false);
    const n: usize = @intCast(hi - lo);
    var i: usize = 1;
    while (i < n) : (i += 1) insertTail(T, v, i, less);
}

/// Insert v[i] into the sorted v[0..i], shifting the greater up.
inline fn insertTail(comptime T: type, v: [*]T, i: usize, less: anytype) void {
    @setRuntimeSafety(false);
    var sift = v + i - 1;
    if (!lt(less, &v[i], &sift[0])) return;
    const tmp = v[i];
    var hole = v + i;
    while (true) {
        hole[0] = sift[0];
        hole = sift;
        if (sift == v) break;
        sift -= 1;
        if (!lt(less, &tmp, &sift[0])) break;
    }
    hole[0] = tmp;
}

/// The run of `xs` from `a`, if it has at least `good` elements: the
/// longest rising one, or a strictly falling one, reversed; 0 if it is
/// shorter.
pub inline fn natural_run(comptime T: type, xs: []T, a: i64, good: i64, less: anytype) i64 {
    const v = range(T, xs, a, @intCast(xs.len));
    @setRuntimeSafety(false);
    const len: usize = xs.len - @as(usize, @intCast(a));
    if (len < 2 or len < good) return 0;
    var n: usize = 2;
    const falling = lt(less, &v[1], &v[0]);
    if (falling) {
        while (n < len and lt(less, &v[n], &v[n - 1])) n += 1;
    } else {
        while (n < len and !lt(less, &v[n], &v[n - 1])) n += 1;
    }
    if (n < good) return 0;
    if (falling) reverse(T, v, n);
    return @intCast(n);
}

/// Reverse v[0..n], whole elements swapped from both ends, four at a time.
inline fn reverse(comptime T: type, v: [*]T, n: usize) void {
    @setRuntimeSafety(false);
    const half = n / 2;
    var i: usize = 0;
    var b = v + n;
    while (i + 4 <= half) : (i += 4) {
        b -= 4;
        const x0 = bits(T, v + i).*;
        const x1 = bits(T, v + i + 1).*;
        const x2 = bits(T, v + i + 2).*;
        const x3 = bits(T, v + i + 3).*;
        const y0 = bits(T, b).*;
        const y1 = bits(T, b + 1).*;
        const y2 = bits(T, b + 2).*;
        const y3 = bits(T, b + 3).*;
        bits(T, v + i).* = y3;
        bits(T, v + i + 1).* = y2;
        bits(T, v + i + 2).* = y1;
        bits(T, v + i + 3).* = y0;
        bits(T, b).* = x3;
        bits(T, b + 1).* = x2;
        bits(T, b + 2).* = x1;
        bits(T, b + 3).* = x0;
    }
    while (i < half) : (i += 1) {
        b -= 1;
        const t = bits(T, v + i).*;
        bits(T, v + i).* = bits(T, b).*;
        bits(T, b).* = t;
    }
}

/// Sort `xs[lo..hi]`, at most 32 elements, through `room`, which holds
/// 16 more than they: each half sorted into the room (by sorting networks
/// of 4 or 8, then insertion), and the halves merged back from both ends
/// at once.
pub inline fn small_sort_by(comptime T: type, xs: []T, lo: i64, hi: i64, room: []T, less: anytype) void {
    const v = range(T, xs, lo, hi);
    const len: usize = @intCast(hi - lo);
    if (len > small_max or room.len < len + 16) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    smallSort(T, v, len, room.ptr, less);
}

inline fn smallSort(comptime T: type, v: [*]T, len: usize, s: [*]T, less: anytype) void {
    @setRuntimeSafety(false);
    if (len < 2) return;
    const half = len / 2;
    var pre: usize = 1;
    if (@sizeOf(T) <= 16 and len >= 16) {
        sort8(T, v, s, s + len, less);
        sort8(T, v + half, s + half, s + len + 8, less);
        pre = 8;
    } else if (len >= 8) {
        sort4(T, v, s, less);
        sort4(T, v + half, s + half, less);
        pre = 4;
    } else {
        s[0] = v[0];
        s[half] = v[half];
    }
    inline for (0..2) |h| {
        const src = if (h == 0) v else v + half;
        const dst = if (h == 0) s else s + half;
        const want = if (h == 0) half else len - half;
        var i = pre;
        while (i < want) : (i += 1) {
            dst[i] = src[i];
            insertTail(T, dst, i, less);
        }
    }
    bidirectionalMerge(T, s, len, v, less);
}

inline fn sel(comptime T: type, b: bool, x: [*]const T, y: [*]const T) [*]const T {
    @setRuntimeSafety(false);
    return if (b) x else y;
}

/// Sort v[0..4] into dst with no branch: a stable network of five
/// comparisons, which writes each element once whatever `less` answers.
inline fn sort4(comptime T: type, v: [*]const T, dst: [*]T, less: anytype) void {
    @setRuntimeSafety(false);
    const c1 = lt(less, &v[1], &v[0]);
    const c2 = lt(less, &v[3], &v[2]);
    const a = v + @intFromBool(c1);
    const b = v + @intFromBool(!c1);
    const c = v + 2 + @intFromBool(c2);
    const d = v + 2 + @intFromBool(!c2);
    const c3 = lt(less, &c[0], &a[0]);
    const c4 = lt(less, &d[0], &b[0]);
    const min = sel(T, c3, c, a);
    const max = sel(T, c4, b, d);
    const ul = sel(T, c3, a, sel(T, c4, c, b));
    const ur = sel(T, c4, d, sel(T, c3, b, c));
    const c5 = lt(less, &ur[0], &ul[0]);
    dst[0] = min[0];
    dst[1] = sel(T, c5, ur, ul)[0];
    dst[2] = sel(T, c5, ul, ur)[0];
    dst[3] = max[0];
}

inline fn sort8(comptime T: type, v: [*]const T, dst: [*]T, tmp: [*]T, less: anytype) void {
    @setRuntimeSafety(false);
    sort4(T, v, tmp, less);
    sort4(T, v + 4, tmp + 4, less);
    bidirectionalMerge(T, tmp, 8, dst, less);
}

/// One element before `p`, which may be before the memory.
inline fn before(comptime T: type, p: [*]const T, k: bool) [*]const T {
    @setRuntimeSafety(false);
    return @ptrFromInt(@intFromPtr(p) -% @as(usize, @intFromBool(k)) * @sizeOf(T));
}

/// Merge the sorted halves of src[0..len] into dst, from the front and
/// the back at once. Whatever `less` answers, every read stays within
/// `src`; if the answers were no order, some element was written twice
/// and another not at all, and src is copied to dst whole instead.
inline fn bidirectionalMerge(comptime T: type, src: [*]const T, len: usize, dst0: [*]T, less: anytype) void {
    @setRuntimeSafety(false);
    const half = len / 2;
    var l = src;
    var r = src + half;
    var d = dst0;
    var lr = src + half - 1;
    var rr = src + len - 1;
    var dr = dst0 + len - 1;
    var k: usize = 0;
    while (k < half) : (k += 1) {
        const take_l = !lt(less, &r[0], &l[0]);
        d[0] = sel(T, take_l, l, r)[0];
        r += @intFromBool(!take_l);
        l += @intFromBool(take_l);
        d += 1;
        const take_r = !lt(less, &rr[0], &lr[0]);
        dr[0] = sel(T, take_r, rr, lr)[0];
        rr = before(T, rr, take_r);
        lr = before(T, lr, !take_r);
        dr = @ptrCast(@constCast(before(T, dr, true)));
    }
    const l_end = lr + 1;
    const r_end = rr + 1;
    if (len % 2 != 0) {
        const from_l = @intFromPtr(l) < @intFromPtr(l_end);
        d[0] = sel(T, from_l, l, r)[0];
        l += @intFromBool(from_l);
        r += @intFromBool(!from_l);
    }
    if (l != l_end or r != r_end) {
        @branchHint(.cold);
        @memcpy(dst0[0..len], src[0..len]);
    }
}

/// The pivot of `xs[lo..hi]`, at least 8 elements, by index: the median of
/// three elements, at the start, a half, and seven eighths; from 64
/// elements each of the three is itself such a median of a range an
/// eighth as long, recursively (a pseudomedian of 3^k elements), as
/// Rust's `choose_pivot`.
pub inline fn pivot_by(comptime T: type, xs: []const T, lo: i64, hi: i64, less: anytype) i64 {
    if (lo < 0 or hi - lo < 8 or hi > xs.len) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    @setRuntimeSafety(false);
    const v = xs.ptr + @as(usize, @intCast(lo));
    const len: usize = @intCast(hi - lo);
    const n8 = len / 8;
    if (len < 64) return lo + @as(i64, @intCast(median3(T, v, 0, n8 * 4, n8 * 7, less)));
    // The recursion's leaves in its order, with no stack of frames: a
    // node at depth k (its eighth `n8 >> 3k`) has children at offsets 0,
    // 4, and 7 eighths; `digits` names the leaf, and `waiting[k]` holds
    // the medians of the first children of the node at depth k - 1 found
    // so far. The comparisons are the recursion's, in its order.
    var depth: usize = 1;
    while ((n8 >> @intCast(3 * depth)) >= 8) depth += 1;
    const leaf_n = n8 >> @intCast(3 * depth);
    var digits: [22]u8 = @splat(0);
    var waiting: [22][2]usize = undefined;
    var found: [22]u8 = @splat(0);
    while (true) {
        var base: usize = 0;
        for (1..depth + 1) |k| base += (n8 >> @intCast(3 * (k - 1))) * ([3]usize{ 0, 4, 7 })[digits[k]];
        var m = median3(T, v, base, base + leaf_n * 4, base + leaf_n * 7, less);
        var k = depth;
        while (k > 0) : (k -= 1) {
            if (found[k] < 2) {
                waiting[k][found[k]] = m;
                found[k] += 1;
                break;
            }
            m = median3(T, v, waiting[k][0], waiting[k][1], m, less);
            found[k] = 0;
        }
        if (k == 0) return lo + @as(i64, @intCast(m));
        var j = depth;
        while (true) {
            digits[j] += 1;
            if (digits[j] < 3) break;
            digits[j] = 0;
            j -= 1;
        }
    }
}

/// The median of v[a], v[b], v[c] by `less`: two comparisons, or three.
inline fn median3(comptime T: type, v: [*]const T, a: usize, b: usize, c: usize, less: anytype) usize {
    @setRuntimeSafety(false);
    const x = lt(less, &v[a], &v[b]);
    const y = lt(less, &v[a], &v[c]);
    if (x == y) {
        // a is above both or below both: the median is the lesser of b
        // and c, or the greater.
        const z = lt(less, &v[b], &v[c]);
        return if (z != x) c else b;
    }
    return a;
}

/// Partition `xs[lo..hi]` around `xs[p]` through `room`: the elements
/// below it first, then the rest, each part in the order it had; the
/// number in the first part. The pivot goes to the second part with no
/// comparison, so the first part is never all of them.
pub inline fn partition_lt(comptime T: type, xs: []T, lo: i64, hi: i64, p: i64, room: []T, less: anytype) i64 {
    return partition(T, xs, lo, hi, p, room, false, less);
}

/// Partition `xs[lo..hi]` around `xs[p]` as `partition_lt` does, the
/// elements not above it first: the pivot goes to the first part, which
/// is never empty.
pub inline fn partition_le(comptime T: type, xs: []T, lo: i64, hi: i64, p: i64, room: []T, less: anytype) i64 {
    return partition(T, xs, lo, hi, p, room, true, less);
}

inline fn partition(comptime T: type, xs: []T, lo: i64, hi: i64, p: i64, room: []T, comptime le: bool, less: anytype) i64 {
    const v = range(T, xs, lo, hi);
    const len: usize = @intCast(hi - lo);
    if (p < lo or p >= hi or room.len < len) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    @setRuntimeSafety(false);
    const s = room.ptr;
    const at: usize = @intCast(p - lo);
    // A copy of the pivot, which no write here reaches, so it stays in
    // registers; the slice is not written until the scan ends.
    const pivot_copy = v[at];
    const pivot = &pivot_copy;
    var left: usize = 0;
    var back: [*]T = s + len;
    var scan: [*]const T = v;
    var stop = at;
    while (true) {
        if (@sizeOf(T) <= 16) {
            const unrolled_end = v + (stop -| 3);
            while (@intFromPtr(scan) < @intFromPtr(unrolled_end)) {
                inline for (0..4) |_| {
                    const to_left = if (le) !lt(less, pivot, &scan[0]) else lt(less, &scan[0], pivot);
                    back -= 1;
                    (if (to_left) s else back)[left] = scan[0];
                    left += @intFromBool(to_left);
                    scan += 1;
                }
            }
        }
        const end = v + stop;
        while (@intFromPtr(scan) < @intFromPtr(end)) {
            const to_left = if (le) !lt(less, pivot, &scan[0]) else lt(less, &scan[0], pivot);
            back -= 1;
            (if (to_left) s else back)[left] = scan[0];
            left += @intFromBool(to_left);
            scan += 1;
        }
        if (stop == len) break;
        back -= 1;
        (if (le) s else back)[left] = scan[0];
        left += @intFromBool(le);
        scan += 1;
        stop = len;
    }
    @memcpy(v[0..left], s[0..left]);
    copyReversed(T, v + left, s + left, len - left);
    return @intCast(left);
}

/// dst[i] = src[n - 1 - i] for i below n; the two do not overlap.
inline fn copyReversed(comptime T: type, dst: [*]T, src: [*]const T, n: usize) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    var from = src + n;
    if (Bits(T) == u64) {
        // Four at a time as a vector, its lanes reversed.
        while (i + 4 <= n) : (i += 4) {
            from -= 4;
            const x: @Vector(4, u64) = @as(*align(@alignOf(T)) const [4]u64, @ptrCast(from)).*;
            @as(*align(@alignOf(T)) [4]u64, @ptrCast(dst + i)).* = @shuffle(u64, x, undefined, [4]i32{ 3, 2, 1, 0 });
        }
    }
    while (i + 4 <= n) : (i += 4) {
        from -= 4;
        const q0 = bits(T, from).*;
        const q1 = bits(T, from + 1).*;
        const q2 = bits(T, from + 2).*;
        const q3 = bits(T, from + 3).*;
        bits(T, dst + i).* = q3;
        bits(T, dst + i + 1).* = q2;
        bits(T, dst + i + 2).* = q1;
        bits(T, dst + i + 3).* = q0;
    }
    while (i < n) : (i += 1) {
        from -= 1;
        dst[i] = from[0];
    }
}

/// Merge the sorted runs `xs[lo..mid]` and `xs[mid..hi]`: the shorter moved
/// out to `room` and merged back, front first when it is the left one and
/// back first when the right, with no branch on `less`.
pub inline fn merge_by(comptime T: type, xs: []T, lo: i64, mid: i64, hi: i64, room: []T, less: anytype) void {
    const v = range(T, xs, lo, hi);
    if (mid < lo or mid > hi or room.len < @min(mid - lo, hi - mid)) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    merge(T, v, @intCast(hi - lo), room.ptr, @intCast(mid - lo), less);
}

inline fn merge(comptime T: type, v: [*]T, len: usize, s: [*]T, mid: usize, less: anytype) void {
    @setRuntimeSafety(false);
    if (mid == 0 or mid >= len) return;
    const v_end = v + len;
    if (mid <= len - mid) {
        @memcpy(s[0..mid], v[0..mid]);
        var l: [*]const T = s;
        const l_end = s + mid;
        var r: [*]const T = v + mid;
        var out = v;
        while (l != l_end and r != v_end) {
            const take_l = !lt(less, &r[0], &l[0]);
            out[0] = sel(T, take_l, l, r)[0];
            l += @intFromBool(take_l);
            r += @intFromBool(!take_l);
            out += 1;
        }
        const rest = (@intFromPtr(l_end) - @intFromPtr(l)) / @sizeOf(T);
        @memcpy(out[0..rest], l[0..rest]);
    } else {
        const rl = len - mid;
        @memcpy(s[0..rl], v[mid..len]);
        var l: [*]const T = v + mid;
        var r: [*]const T = s + rl;
        var out = v_end;
        while (true) {
            const lp = l - 1;
            const rp = r - 1;
            out -= 1;
            const take_l = lt(less, &rp[0], &lp[0]);
            out[0] = sel(T, take_l, lp, rp)[0];
            l = lp + @intFromBool(!take_l);
            r = rp + @intFromBool(take_l);
            if (l == v or r == s) break;
        }
        const rest = (@intFromPtr(r) - @intFromPtr(s)) / @sizeOf(T);
        @memcpy(@constCast(l)[0..rest], s[0..rest]);
    }
}

/// Sort `xs[lo..hi]` by merges alone, for a quicksort that partitioned
/// too often: pieces of 32 sorted small, then merged by doubling widths.
/// O(n log n) whatever the input.
pub inline fn merge_sort_by(comptime T: type, xs: []T, lo: i64, hi: i64, room: []T, less: anytype) void {
    const v = range(T, xs, lo, hi);
    const len: usize = @intCast(hi - lo);
    if (room.len < @max(len / 2, small_max + 16)) {
        @branchHint(.cold);
        @panic("index out of bounds");
    }
    @setRuntimeSafety(false);
    const s = room.ptr;
    var a: usize = 0;
    while (a < len) : (a += small_max) smallSort(T, v + a, @min(small_max, len - a), s, less);
    var w: usize = small_max;
    while (w < len) : (w *= 2) {
        a = 0;
        while (a + w < len) : (a += 2 * w) merge(T, v + a, @min(2 * w, len - a), s, w, less);
    }
}
