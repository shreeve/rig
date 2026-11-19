//! bw: the memory ceiling for psum. Writes 2^25 i64 (psum's input, i*2654435761 % 1000) into a
//! fresh mapping, then times ONE summing pass, as fork.rig does.
//! usage: bw PAGES ORDER THREADS LOOP
//!   PAGES: small (MADV_NOHUGEPAGE) | huge (2 MiB aligned, MADV_HUGEPAGE) | plain (mmap, no advice)
//!   ORDER: asc (one pass) | leafasc (8,192-element leaves ascending) | leafdesc (leaves descending,
//!          each read forwards: Rig's order at one worker if the continuation runs first)
//!   THREADS: N threads, each a contiguous 1/N (spawned and spinning before the write)
//!   LOOP: scalar (no vectors, 1 accumulator) | vec (4 x @Vector(4,i64))
//! prints: ns sum
const std = @import("std");
const linux = std.os.linux;

const n: usize = 1 << 25;
const grain: usize = 8192;

var data: []i64 = undefined;
var order: u8 = 'a';
var vec_loop = false;
var go = std.atomic.Value(u32).init(0);
var done = std.atomic.Value(u32).init(0);
var sums: [64]i64 = @splat(0);

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

noinline fn sumScalar(xs: []const i64) i64 {
    var s: i64 = 0;
    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        s +%= xs[i];
    }
    return s;
}

noinline fn sumVec(xs: []const i64) i64 {
    const V = @Vector(4, i64);
    var a: [4]V = @splat(@splat(0));
    var i: usize = 0;
    while (i + 16 <= xs.len) : (i += 16) {
        inline for (0..4) |k| a[k] +%= xs[i + 4 * k ..][0..4].*;
    }
    var s: i64 = @reduce(.Add, a[0] +% a[1] +% a[2] +% a[3]);
    while (i < xs.len) : (i += 1) s +%= xs[i];
    return s;
}

fn sumRange(xs: []const i64) i64 {
    const f = if (vec_loop) &sumVec else &sumScalar;
    if (order == 'a') return f(xs);
    var s: i64 = 0;
    const leaves = (xs.len + grain - 1) / grain;
    var k: usize = 0;
    while (k < leaves) : (k += 1) {
        const j = if (order == 'd') leaves - 1 - k else k;
        const end = @min(xs.len, (j + 1) * grain);
        s +%= f(xs[j * grain .. end]);
    }
    return s;
}

fn worker(id: usize, nt: usize) void {
    while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
    const per = n / nt;
    sums[id] = sumRange(data[id * per .. (id + 1) * per]);
    _ = done.fetchAdd(1, .release);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next();
    const pages = it.next().?;
    const ord = it.next().?;
    const nt = try std.fmt.parseInt(usize, it.next().?, 10);
    vec_loop = std.mem.eql(u8, it.next().?, "vec");
    order = if (std.mem.eql(u8, ord, "asc")) 'a' else if (std.mem.eql(u8, ord, "leafasc")) 'l' else 'd';

    const bytes = n * 8;
    const huge: usize = 2 << 20;
    const raw = try std.posix.mmap(null, bytes + huge, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    var p = @intFromPtr(raw.ptr);
    if (std.mem.eql(u8, pages, "huge")) {
        p = std.mem.alignForward(usize, p, huge);
        _ = linux.madvise(@ptrFromInt(p), bytes, linux.MADV.HUGEPAGE);
    } else if (std.mem.eql(u8, pages, "small")) {
        _ = linux.madvise(@ptrFromInt(p), bytes, linux.MADV.NOHUGEPAGE);
    }
    data = @as([*]i64, @ptrFromInt(p))[0..n];

    var threads: [64]std.Thread = undefined;
    var t: usize = 1;
    while (t < nt) : (t += 1) threads[t] = try std.Thread.spawn(.{}, worker, .{ t, nt });

    var i: usize = 0;
    while (i < n) : (i += 1) data[i] = @rem(@as(i64, @intCast(i)) *% 2654435761, 1000);

    const t0 = now();
    go.store(1, .release);
    const per = n / nt;
    sums[0] = sumRange(data[0..per]);
    while (done.load(.acquire) != nt - 1) std.atomic.spinLoopHint();
    var s: i64 = 0;
    for (sums[0..nt]) |x| s +%= x;
    const el = now() - t0;
    t = 1;
    while (t < nt) : (t += 1) threads[t].join();
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{d} {d}\n", .{ el, s });
    _ = linux.write(1, line.ptr, line.len);
}
