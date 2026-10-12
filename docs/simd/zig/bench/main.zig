// Timing harness for kernels.zig. Buffer stays in L1/L2; min of trials.
const std = @import("std");
const builtin = @import("builtin");
const k = @import("kernels.zig");

const LEN = 32 * 1024;
const REPS = 4000; // 128 MiB per trial
const TRIALS = 9;

var buf: [LEN]u8 align(64) = undefined;
var masks: [4 * LEN / 64]u64 = undefined;

const Acc = k.Acc;
const MaskFn = *const fn ([*]const u8, usize, [*]u64) callconv(.c) void;
const ScanFn = *const fn ([*]const u8, usize, *Acc) callconv(.c) void;

fn fill(seed: u64, one_in: u32) void {
    var r = std.Random.DefaultPrng.init(seed);
    const rnd = r.random();
    for (&buf) |*b| b.* = if (rnd.uintLessThan(u32, one_in) == 0) '"' else rnd.intRangeAtMost(u8, 'a', 'z');
}

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn timeMask(io: std.Io, name: []const u8, f: MaskFn) void {
    var best: u64 = std.math.maxInt(u64);
    for (0..TRIALS) |_| {
        const t0 = now(io);
        for (0..REPS) |_| {
            f(&buf, LEN / 64, &masks);
            std.mem.doNotOptimizeAway(&masks);
        }
        const ns: u64 = @intCast(t0.durationTo(now(io)).raw.toNanoseconds());
        best = @min(best, ns);
    }
    var h: u64 = 0;
    for (masks[0 .. LEN / 64]) |m| h = (h ^ m) *% 0x9E3779B97F4A7C15;
    const bytes: f64 = @floatFromInt(@as(u64, LEN) * REPS);
    const nsf: f64 = @floatFromInt(best);
    std.debug.print("  {s:<22} {d:>7.2} GB/s  {d:>6.3} ns/64B  check {x:0>16}\n", .{ name, bytes / nsf, nsf / (bytes / 64), h });
}

fn timeScan(io: std.Io, name: []const u8, f: ScanFn) void {
    var best: u64 = std.math.maxInt(u64);
    var acc: Acc = undefined;
    for (0..TRIALS) |_| {
        const t0 = now(io);
        for (0..REPS / 4) |_| {
            acc = .{ .count = 0, .sum = 0 };
            f(&buf, LEN, &acc);
            std.mem.doNotOptimizeAway(&acc);
        }
        const ns: u64 = @intCast(t0.durationTo(now(io)).raw.toNanoseconds());
        best = @min(best, ns);
    }
    const bytes: f64 = @floatFromInt(@as(u64, LEN) * (REPS / 4));
    const nsf: f64 = @floatFromInt(best);
    std.debug.print("  {s:<22} {d:>7.2} GB/s  {d:>6.3} ns/64B  count {d} sum {d}\n", .{ name, bytes / nsf, nsf / (bytes / 64), acc.count, acc.sum });
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const a64 = builtin.cpu.arch == .aarch64;
    fill(1, 8);
    std.debug.print("Job A: linear u64 mask per 64-byte block (dense: 1 in 8 bytes match)\n", .{});
    timeMask(io, "simd16 (4x bitcast)", &k.mask_simd16);
    timeMask(io, "simd32 (2x bitcast)", &k.mask_simd32);
    timeMask(io, "simd64 (1x bitcast)", &k.mask_simd64);
    if (a64) timeMask(io, "neon addp (intrinsic)", &k.mask_neon_addp);
    timeMask(io, "portable addp", &k.mask_portable_addp);
    timeMask(io, "swar64", &k.mask_swar64);
    timeMask(io, "swar128", &k.mask_swar128);
    timeMask(io, "scalar", &k.mask_scalar);
    timeMask(io, "nibble (4 u64, not lin)", &k.mask_nibble);
    inline for (.{ .{ "sparse 1/256", 256 }, .{ "medium 1/32", 32 }, .{ "dense 1/8", 8 } }) |d| {
        fill(2, d[1]);
        std.debug.print("Job B: visit every match, {s}\n", .{d[0]});
        timeScan(io, "simd16 bitcast", &k.scan_simd16);
        timeScan(io, "simd16 any+bitcast", &k.scan_simd16_any);
        timeScan(io, "simd16 nibble", &k.scan_nibble16);
        timeScan(io, "simd32 bitcast", &k.scan_simd32);
        timeScan(io, "simd64 bitcast", &k.scan_simd64);
        if (a64) timeScan(io, "neon addp 64", &k.scan_neon_addp);
        timeScan(io, "swar64", &k.scan_swar64);
        timeScan(io, "swar128", &k.scan_swar128);
        timeScan(io, "std.mem.findScalarPos", &k.scan_std);
        timeScan(io, "scalar", &k.scan_scalar);
    }
}
