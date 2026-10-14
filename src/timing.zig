//! The time `rig check --time` reports for each pass of the compiler,
//! summed over every module of the program. A pass that runs again
//! (sema, after the iterator rewrite) adds its second run to its first.

const std = @import("std");

pub const Pass = enum {
    /// Lexing, parsing, and the rewrite into the semantic IR.
    lex_parse,
    /// Names, declarations, and what each declared type holds.
    resolve,
    /// Every expression, frames, generic instances.
    typecheck,
    /// The hidden storage emit makes (`storage.plan`).
    storage,
    ownership,
    proofs,
    inlining,

    fn label(p: Pass) []const u8 {
        return switch (p) {
            .lex_parse => "lex and parse",
            else => @tagName(p),
        };
    }
};

const n_passes = @typeInfo(Pass).@"enum".field_names.len;

pub const Timing = struct {
    io: std.Io,
    ns: [n_passes]u64 = @splat(0),

    pub const Start = std.Io.Timestamp;

    pub fn now(t: *const Timing) Start {
        return std.Io.Clock.awake.now(t.io);
    }

    /// Add the time since `from` to `pass`.
    pub fn add(t: *Timing, pass: Pass, from: Start) void {
        const d = from.durationTo(t.now()).nanoseconds;
        t.ns[@intFromEnum(pass)] += @intCast(@max(d, 0));
    }

    /// Each pass's milliseconds, then the rest of `total` (reading files,
    /// resolving `use`, writing diagnostics) and `total` itself.
    pub fn write(t: *const Timing, w: *std.Io.Writer, total_ns: u64) std.Io.Writer.Error!void {
        var sum: u64 = 0;
        inline for (0..n_passes) |i| {
            const p: Pass = @enumFromInt(i);
            try w.print("{s:<14}{d:>10.3} ms\n", .{ p.label(), ms(t.ns[i]) });
            sum += t.ns[i];
        }
        try w.print("{s:<14}{d:>10.3} ms\n", .{ "other", ms(total_ns -| sum) });
        try w.print("{s:<14}{d:>10.3} ms\n", .{ "total", ms(total_ns) });
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// The start of a pass when `t` times passes; null otherwise.
pub fn start(t: ?*Timing) ?Timing.Start {
    return if (t) |x| x.now() else null;
}

/// Add the time since `s` to `pass` when `t` times passes.
pub fn stop(t: ?*Timing, pass: Pass, s: ?Timing.Start) void {
    if (t) |x| x.add(pass, s.?);
}
