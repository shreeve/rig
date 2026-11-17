//! The Zig ceiling for std.sort's stable path: driftsort's design (Orson
//! Peters and Lukas Bergdoll, Rust's `slice::sort`), written again in Zig
//! with no Rig limits, to measure against Rust's `sort_by`.
//!
//! - Runs: a natural run of at least sqrt(n) elements (64 up to 4,096) is
//!   kept, a strictly falling one reversed; shorter stretches become
//!   *unsorted* runs. Runs merge in powersort's order (Munro and Wild), and
//!   two unsorted runs that fit in the scratch together merge *lazily*:
//!   they become one longer unsorted run. An unsorted run is sorted by the
//!   stable quicksort only when it must merge with a sorted one, or no
//!   longer fits; so input without runs is quicksorted in pieces as large
//!   as the scratch, and merged.
//! - The stable quicksort picks a pivot by the median of three (a
//!   recursive pseudomedian from 64 elements), and partitions through the
//!   scratch: an element below the pivot is written to the scratch's front,
//!   any other to its back (backwards), with no branch, then both parts
//!   are copied home, the back one reversed, so each keeps its order. A
//!   pivot not above the previous one (the left ancestor's, which every
//!   element here is at least) is partitioned by `<=` instead, and those
//!   elements are done: input of few values sorts in a few passes. The
//!   right side is taken next, the left pushed on an explicit stack. After
//!   2 log2(n) partitions on one path, a merge sort finishes the slice.
//! - At most 32 elements: two halves each sorted into the scratch (by
//!   sort-4/sort-8 networks, then insertion), merged back from both ends
//!   at once (bidirectional merge). At most 20 elements on their own:
//!   insertion.
//! - Merges move the shorter run to the scratch and merge it back, with no
//!   branch on the comparison.
//! - Scratch: max(n/2, min(n, 8 MB)), at least 48 elements, on the stack
//!   up to 4 KB, else from malloc (Zig's smp_allocator without libc).
//!
//! Every function runs without Zig's safety checks, as Rust's sort runs
//! without its bounds checks: each index is bounded by the loop that makes
//! it, whatever the comparison answers (a partition writes slot `left` or
//! `len - 1 - i + left` of the scratch; a merge stops at either run's end;
//! the bidirectional merge reads within its source for any answers and
//! panics after if the answers were no order). A safe build checks only
//! what each function is given.

const std = @import("std");

/// malloc, as Rust's `sort` allocates, where the program links libc.
const scratch_gpa = if (@import("builtin").link_libc) std.heap.c_allocator else std.heap.smp_allocator;

pub fn sort(comptime T: type, v: []T, ctx: anytype, comptime lessFn: fn (@TypeOf(ctx), T, T) bool) void {
    Sorter(T, @TypeOf(ctx), lessFn).sort(v, ctx);
}

pub fn Sorter(comptime T: type, comptime C: type, comptime lessFn: fn (C, T, T) bool) type {
    return struct {
        const small_max = 32;
        const insertion_max = 20;
        const full_alloc_bytes = 8_000_000;
        const min_scratch = small_max + 16;
        const stack_bytes = 4096;

        inline fn lt(c: C, a: *const T, b: *const T) bool {
            return lessFn(c, a.*, b.*);
        }

        pub fn sort(v: []T, c: C) void {
            @setRuntimeSafety(false);
            const len = v.len;
            if (len < 2) return;
            if (len <= insertion_max) {
                insertionSort(v.ptr, len, 1, c);
                return;
            }
            const full = @min(len, full_alloc_bytes / @sizeOf(T));
            const alloc_len = @max(@max(len - len / 2, full), min_scratch);
            const eager = len <= 2 * small_max;
            const stack_len = stack_bytes / @sizeOf(T);
            if (alloc_len <= stack_len) {
                var buf: [stack_len]T = undefined;
                drift(v.ptr, len, &buf, stack_len, eager, c);
            } else {
                const buf = scratch_gpa.alloc(T, alloc_len) catch @panic("out of memory");
                defer scratch_gpa.free(buf);
                drift(v.ptr, len, buf.ptr, alloc_len, eager, c);
            }
        }

        // A run is `len << 1 | sorted`.
        fn drift(v: [*]T, len: usize, s: [*]T, s_len: usize, eager: bool, c: C) void {
            @setRuntimeSafety(false);
            const scale = ((@as(u64, 1) << 62) + len - 1) / len;
            const min_good: usize = if (len <= 64 * 64) @min(len - len / 2, 64) else sqrtApprox(len);
            var runs: [66]usize = undefined;
            var depths: [66]u8 = undefined;
            var top: usize = 0;
            var scan: usize = 0;
            var prev: usize = 1;
            while (true) {
                var next: usize = 1;
                var depth: u8 = 0;
                if (scan < len) {
                    next = createRun(v + scan, len - scan, s, s_len, min_good, eager, c);
                    depth = treeDepth(scan - (prev >> 1), scan, scan + (next >> 1), scale);
                }
                while (top > 1 and depths[top - 1] >= depth) {
                    const left = runs[top - 1];
                    const merged = (left >> 1) + (prev >> 1);
                    prev = logicalMerge(v + (scan - merged), merged, s, s_len, left, prev, c);
                    top -= 1;
                }
                runs[top] = prev;
                depths[top] = depth;
                top += 1;
                if (scan >= len) break;
                scan += next >> 1;
                prev = next;
            }
            if (prev & 1 == 0) quicksort(v, len, s, s_len, c);
        }

        fn sqrtApprox(n: usize) usize {
            const shift: u6 = @intCast((1 + std.math.log2_int(usize, n | 1)) / 2);
            return ((@as(usize, 1) << shift) + (n >> shift)) / 2;
        }

        inline fn treeDepth(a: usize, m: usize, b: usize, scale: u64) u8 {
            const x = @as(u64, a) + m;
            const y = @as(u64, m) + b;
            return @clz((scale *% x) ^ (scale *% y));
        }

        fn createRun(v: [*]T, len: usize, s: [*]T, s_len: usize, min_good: usize, eager: bool, c: C) usize {
            @setRuntimeSafety(false);
            if (len >= min_good) {
                var n: usize = 2;
                const falling = lt(c, &v[1], &v[0]);
                if (falling) {
                    while (n < len and lt(c, &v[n], &v[n - 1])) n += 1;
                } else {
                    while (n < len and !lt(c, &v[n], &v[n - 1])) n += 1;
                }
                if (n >= min_good) {
                    if (falling) reverse(v, n);
                    return n << 1 | 1;
                }
            }
            if (eager) {
                const n: usize = @min(small_max, len);
                smallSort(v, n, s, c);
                return n << 1 | 1;
            }
            _ = s_len;
            return @min(min_good, len) << 1;
        }

        /// An element as one integer where it is the size of one, which
        /// LLVM keeps in registers (an object of two fields it moves
        /// through the stack when several are live).
        const Bits = switch (@sizeOf(T)) {
            1, 2, 4, 8, 16 => @Int(.unsigned, @sizeOf(T) * 8),
            else => T,
        };
        const BitsPtr = *align(@alignOf(T)) Bits;

        inline fn bits(p: [*]const T) BitsPtr {
            @setRuntimeSafety(false);
            return @ptrCast(@constCast(p));
        }

        /// Reverse v[0..n]: whole elements swapped from both ends, four
        /// at a time.
        fn reverse(v: [*]T, n: usize) void {
            @setRuntimeSafety(false);
            const half = n / 2;
            var i: usize = 0;
            var b = v + n;
            while (i + 4 <= half) : (i += 4) {
                b -= 4;
                const x0 = bits(v + i).*;
                const x1 = bits(v + i + 1).*;
                const x2 = bits(v + i + 2).*;
                const x3 = bits(v + i + 3).*;
                const y0 = bits(b).*;
                const y1 = bits(b + 1).*;
                const y2 = bits(b + 2).*;
                const y3 = bits(b + 3).*;
                bits(v + i).* = y3;
                bits(v + i + 1).* = y2;
                bits(v + i + 2).* = y1;
                bits(v + i + 3).* = y0;
                bits(b).* = x3;
                bits(b + 1).* = x2;
                bits(b + 2).* = x1;
                bits(b + 3).* = x0;
            }
            while (i < half) : (i += 1) {
                b -= 1;
                const t = bits(v + i).*;
                bits(v + i).* = bits(b).*;
                bits(b).* = t;
            }
        }

        fn logicalMerge(v: [*]T, len: usize, s: [*]T, s_len: usize, left: usize, right: usize, c: C) usize {
            @setRuntimeSafety(false);
            if (len <= s_len and left & 1 == 0 and right & 1 == 0) return len << 1;
            const ll = left >> 1;
            if (left & 1 == 0) quicksort(v, ll, s, s_len, c);
            if (right & 1 == 0) quicksort(v + ll, len - ll, s, s_len, c);
            merge(v, len, s, ll, c);
            return len << 1 | 1;
        }

        const Frame = struct { lo: usize, hi: usize, limit: u32, anc: u32, free: u32 };
        const none: u32 = std.math.maxInt(u32);

        fn quicksort(v0: [*]T, len0: usize, s: [*]T, s_len: usize, c: C) void {
            @setRuntimeSafety(false);
            var pivots: [128]T = undefined;
            var stack: [128]Frame = undefined;
            var top: usize = 0;
            var lo: usize = 0;
            var hi: usize = len0;
            var limit: u32 = 2 * @as(u32, std.math.log2_int(usize, len0 | 1));
            var anc: u32 = none;
            var free: u32 = 0;
            while (true) {
                const len = hi - lo;
                const v = v0 + lo;
                if (len <= small_max) {
                    smallSort(v, len, s, c);
                } else if (limit == 0) {
                    mergeSort(v, len, s, c);
                } else {
                    limit -= 1;
                    const p = choosePivot(v, len, c);
                    var eq = anc != none and !lt(c, &pivots[anc], &v[p]);
                    var nl: usize = 0;
                    if (!eq) {
                        pivots[free] = v[p];
                        nl = partition(v, len, s, s_len, p, false, c);
                        eq = nl == 0;
                    }
                    if (eq) {
                        lo += partition(v, len, s, s_len, p, true, c);
                        anc = none;
                        continue;
                    }
                    stack[top] = .{ .lo = lo, .hi = lo + nl, .limit = limit, .anc = anc, .free = free };
                    top += 1;
                    lo += nl;
                    anc = free;
                    free += 1;
                    continue;
                }
                if (top == 0) return;
                top -= 1;
                const f = stack[top];
                lo = f.lo;
                hi = f.hi;
                limit = f.limit;
                anc = f.anc;
                free = f.free;
            }
        }

        fn choosePivot(v: [*]T, len: usize, c: C) usize {
            @setRuntimeSafety(false);
            const n8 = len / 8;
            if (len < 64) return median3(v, 0, n8 * 4, n8 * 7, c);
            return median3Rec(v, 0, n8 * 4, n8 * 7, n8, c);
        }

        fn median3Rec(v: [*]T, a0: usize, b0: usize, c0: usize, n: usize, c: C) usize {
            @setRuntimeSafety(false);
            var a = a0;
            var b = b0;
            var d = c0;
            if (n * 8 >= 64) {
                const n8 = n / 8;
                a = median3Rec(v, a, a + n8 * 4, a + n8 * 7, n8, c);
                b = median3Rec(v, b, b + n8 * 4, b + n8 * 7, n8, c);
                d = median3Rec(v, d, d + n8 * 4, d + n8 * 7, n8, c);
            }
            return median3(v, a, b, d, c);
        }

        inline fn median3(v: [*]T, a: usize, b: usize, d: usize, c: C) usize {
            @setRuntimeSafety(false);
            const x = lt(c, &v[a], &v[b]);
            const y = lt(c, &v[a], &v[d]);
            if (x == y) {
                const z = lt(c, &v[b], &v[d]);
                return if (z != x) d else b;
            }
            return a;
        }

        /// Partition v[0..len] around v[p] through the scratch: the
        /// elements below it (or not above it, `le`) first, the rest
        /// after, each part in the order it had. The pivot goes with the
        /// second part under `<` and the first under `<=`, by no
        /// comparison. The length of the first part.
        fn partition(v: [*]T, len: usize, s: [*]T, s_len: usize, p: usize, comptime le: bool, c: C) usize {
            @setRuntimeSafety(false);
            if (len > s_len or p >= len) @panic("partition out of range");
            // A copy of the pivot, which no write here can reach, so it
            // stays in registers; v is not written until the scan ends.
            const pivot_copy = v[p];
            const pivot = &pivot_copy;
            var left: usize = 0;
            var back: [*]T = s + len;
            var scan: [*]const T = v;
            var stop = p;
            while (true) {
                if (@sizeOf(T) <= 16) {
                    const unrolled_end = v + (stop -| 3);
                    while (@intFromPtr(scan) < @intFromPtr(unrolled_end)) {
                        inline for (0..4) |_| {
                            const to_left = if (le) !lt(c, pivot, &scan[0]) else lt(c, &scan[0], pivot);
                            back -= 1;
                            (if (to_left) s else back)[left] = scan[0];
                            left +%= @intFromBool(to_left);
                            scan += 1;
                        }
                    }
                }
                const end = v + stop;
                while (@intFromPtr(scan) < @intFromPtr(end)) {
                    const to_left = if (le) !lt(c, pivot, &scan[0]) else lt(c, &scan[0], pivot);
                    back -= 1;
                    (if (to_left) s else back)[left] = scan[0];
                    left +%= @intFromBool(to_left);
                    scan += 1;
                }
                if (stop == len) break;
                back -= 1;
                (if (le) s else back)[left] = scan[0];
                left +%= @intFromBool(le);
                scan += 1;
                stop = len;
            }
            @memcpy(v[0..left], s[0..left]);
            copyReversed(v + left, s + left, len - left);
            return left;
        }

        /// dst[i] = src[n - 1 - i] for i below n; the two do not overlap.
        inline fn copyReversed(noalias dst: [*]T, noalias src: [*]const T, n: usize) void {
            @setRuntimeSafety(false);
            var i: usize = 0;
            var from = src + n;
            if (Bits == u64) {
                // Four at a time as a vector, its lanes reversed.
                while (i + 4 <= n) : (i += 4) {
                    from -= 4;
                    const x: @Vector(4, u64) = @as(*align(@alignOf(T)) const [4]u64, @ptrCast(from)).*;
                    @as(*align(@alignOf(T)) [4]u64, @ptrCast(dst + i)).* = @shuffle(u64, x, undefined, [4]i32{ 3, 2, 1, 0 });
                }
            }
            while (i + 4 <= n) : (i += 4) {
                from -= 4;
                const q0 = bits(from).*;
                const q1 = bits(from + 1).*;
                const q2 = bits(from + 2).*;
                const q3 = bits(from + 3).*;
                bits(dst + i).* = q3;
                bits(dst + i + 1).* = q2;
                bits(dst + i + 2).* = q1;
                bits(dst + i + 3).* = q0;
            }
            while (i < n) : (i += 1) {
                from -= 1;
                dst[i] = from[0];
            }
        }

        /// A merge sort of v[0..len] for a quicksort path that ran out
        /// of partitions: pieces of 32 sorted, merged by doubling widths.
        fn mergeSort(v: [*]T, len: usize, s: [*]T, c: C) void {
            @setRuntimeSafety(false);
            var a: usize = 0;
            while (a < len) : (a += small_max) smallSort(v + a, @min(small_max, len - a), s, c);
            var w: usize = small_max;
            while (w < len) : (w *= 2) {
                a = 0;
                while (a + w < len) : (a += 2 * w) merge(v + a, @min(2 * w, len - a), s, w, c);
            }
        }

        fn insertionSort(v: [*]T, len: usize, from: usize, c: C) void {
            @setRuntimeSafety(false);
            var i = from;
            while (i < len) : (i += 1) insertTail(v, i, c);
        }

        /// Insert v[i] into the sorted v[0..i], shifting the larger up.
        inline fn insertTail(v: [*]T, i: usize, c: C) void {
            @setRuntimeSafety(false);
            var sift = v + i - 1;
            if (!lt(c, &v[i], &sift[0])) return;
            const tmp = v[i];
            var hole = v + i;
            while (true) {
                hole[0] = sift[0];
                hole = sift;
                if (sift == v) break;
                sift -= 1;
                if (!lt(c, &tmp, &sift[0])) break;
            }
            hole[0] = tmp;
        }

        fn smallSort(v: [*]T, len: usize, s: [*]T, c: C) void {
            @setRuntimeSafety(false);
            if (len < 2) return;
            const half = len / 2;
            var pre: usize = 1;
            if (@sizeOf(T) <= 16 and len >= 16) {
                sort8(v, s, s + len, c);
                sort8(v + half, s + half, s + len + 8, c);
                pre = 8;
            } else if (len >= 8) {
                sort4(v, s, c);
                sort4(v + half, s + half, c);
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
                    insertTail(dst, i, c);
                }
            }
            bidirectionalMerge(s, len, v, c);
        }

        inline fn sel(b: bool, x: [*]const T, y: [*]const T) [*]const T {
            @setRuntimeSafety(false);
            return if (b) x else y;
        }

        fn sort4(v: [*]const T, dst: [*]T, c: C) void {
            @setRuntimeSafety(false);
            const c1 = lt(c, &v[1], &v[0]);
            const c2 = lt(c, &v[3], &v[2]);
            const a = v + @intFromBool(c1);
            const b = v + @intFromBool(!c1);
            const cc = v + 2 + @intFromBool(c2);
            const d = v + 2 + @intFromBool(!c2);
            const c3 = lt(c, &cc[0], &a[0]);
            const c4 = lt(c, &d[0], &b[0]);
            const min = sel(c3, cc, a);
            const max = sel(c4, b, d);
            const ul = sel(c3, a, sel(c4, cc, b));
            const ur = sel(c4, d, sel(c3, b, cc));
            const c5 = lt(c, &ur[0], &ul[0]);
            dst[0] = min[0];
            dst[1] = sel(c5, ur, ul)[0];
            dst[2] = sel(c5, ul, ur)[0];
            dst[3] = max[0];
        }

        fn sort8(v: [*]const T, dst: [*]T, tmp: [*]T, c: C) void {
            @setRuntimeSafety(false);
            sort4(v, tmp, c);
            sort4(v + 4, tmp + 4, c);
            bidirectionalMerge(tmp, 8, dst, c);
        }

        /// One element before `p`, which may be before the memory.
        inline fn before(p: [*]const T, k: bool) [*]const T {
            @setRuntimeSafety(false);
            return @ptrFromInt(@intFromPtr(p) -% @as(usize, @intFromBool(k)) * @sizeOf(T));
        }

        /// Merge the sorted halves of src[0..len] into dst, from the front
        /// and the back at once.
        inline fn bidirectionalMerge(src: [*]const T, len: usize, dst0: [*]T, c: C) void {
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
                const take_l = !lt(c, &r[0], &l[0]);
                d[0] = sel(take_l, l, r)[0];
                r += @intFromBool(!take_l);
                l += @intFromBool(take_l);
                d += 1;
                const take_r = !lt(c, &rr[0], &lr[0]);
                dr[0] = sel(take_r, rr, lr)[0];
                rr = before(rr, take_r);
                lr = before(lr, !take_r);
                dr = @ptrCast(@constCast(before(dr, true)));
            }
            const l_end = lr + 1;
            const r_end = rr + 1;
            if (len % 2 != 0) {
                const from_l = @intFromPtr(l) < @intFromPtr(l_end);
                d[0] = sel(from_l, l, r)[0];
                l += @intFromBool(from_l);
                r += @intFromBool(!from_l);
            }
            if (l != l_end or r != r_end) @panic("the comparison is not a total order");
        }

        /// Merge the sorted runs v[0..mid] and v[mid..len], the shorter
        /// moved to the scratch, with no branch on the comparison.
        fn merge(v: [*]T, len: usize, s: [*]T, mid: usize, c: C) void {
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
                    const take_l = !lt(c, &r[0], &l[0]);
                    out[0] = sel(take_l, l, r)[0];
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
                    const take_l = lt(c, &rp[0], &lp[0]);
                    out[0] = sel(take_l, lp, rp)[0];
                    l = lp + @intFromBool(!take_l);
                    r = rp + @intFromBool(take_l);
                    if (l == v or r == s) break;
                }
                const rest = (@intFromPtr(r) - @intFromPtr(s)) / @sizeOf(T);
                @memcpy(@constCast(l)[0..rest], s[0..rest]);
            }
        }
    };
}

const Pair = struct { key: u32, id: u32 };

fn pairLess(_: void, a: Pair, b: Pair) bool {
    return a.key < b.key;
}

test "drift sorts stably" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const sizes = [_]usize{ 0, 1, 2, 3, 7, 8, 15, 16, 17, 20, 21, 31, 32, 33, 47, 48, 63, 64, 65, 100, 1000, 4095, 4096, 4097, 5000, 70000, 300000 };
    for (sizes) |n| {
        for ([_]u32{ 0, 1, 2, 16, 1000, std.math.maxInt(u32) }) |range| {
            for (0..4) |shape| {
                const xs = try gpa.alloc(Pair, n);
                defer gpa.free(xs);
                for (xs, 0..) |*x, i| {
                    const k: u32 = switch (shape) {
                        0 => if (range == 0) 0 else if (range == std.math.maxInt(u32)) r.int(u32) else r.uintLessThan(u32, range),
                        1 => @intCast(i / 3),
                        2 => @intCast(n - i / 3),
                        else => @intCast((i % 97) * 31 % 53 + (if (i % 500 == 0) r.uintLessThan(u32, 1000) else 0)),
                    };
                    x.* = .{ .key = k, .id = @intCast(i) };
                }
                sort(Pair, xs, {}, pairLess);
                for (1..@max(n, 1)) |i| {
                    try std.testing.expect(xs[i - 1].key <= xs[i].key);
                    if (xs[i - 1].key == xs[i].key) try std.testing.expect(xs[i - 1].id < xs[i].id);
                }
            }
        }
    }
}
