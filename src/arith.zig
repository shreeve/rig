//! The rules of arithmetic the compiler and the runtime both apply, so
//! that a constant the checker computes and the same value the program
//! computes agree by construction. `bin/rig` writes this file verbatim
//! beside the runtime as `rig/arith.zig`, which the runtime imports; the
//! compiler imports it as source (cteval, proofs, the checker). It holds
//! pure functions and constants only, and imports nothing but Zig's
//! standard library.

const std = @import("std");

/// The longest length a Rig `Int` holds, and the longest a length read
/// gives (`rig.lenOf`): no List grows past it, no target holds more, and
/// the margin above it lets the compiler prove `i + c` fits where `i` is
/// below a length (docs/internals/INTERNALS.md, "Proven checks").
pub const max_len: u64 = (1 << 62) - 1;

/// Whether `n` is a shift amount for an integer of `bits` bits: 0 to
/// `bits - 1`. A constant amount outside is rejected as Rig compiles, and
/// one known only as the program runs panics (`rig.shiftAmount`), both
/// with `shift_range_text`.
pub inline fn shiftInRange(n: anytype, bits: anytype) bool {
    return n >= 0 and n < bits;
}

/// What a shift amount out of range reports, given the amount, the
/// shifted type's Rig name, and its greatest amount.
pub const shift_range_text = "shift amount `{d}` is out of range for `{s}` (0..{d})";

/// `a % b`: the remainder with the dividend's sign, of integers or
/// floats. A signed integer's remainder by -1 is 0, `Int.min % -1`
/// included, where the machine's division would trap.
pub inline fn rem(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    switch (@typeInfo(@TypeOf(a))) {
        .int => |int| if (int.signedness == .signed and b == -1) return 0,
        else => {},
    }
    return @rem(a, b);
}

// Durations (docs/design/datetime.md §5.1): std.time's `Duration` holds
// whole seconds and the nanoseconds after them, of one sign, and its range
// is symmetric so that `neg()` cannot fail.

/// The nanoseconds in a second.
pub const ns_per_s: i128 = 1_000_000_000;
/// The greatest whole seconds of a `Duration`; the least is its negation.
pub const duration_max_s: i128 = std.math.maxInt(i64);
/// The greatest nanoseconds a `Duration` holds; the least is its negation.
pub const duration_max_ns: i128 = duration_max_s * ns_per_s + (ns_per_s - 1);

/// Whether `ns` nanoseconds is within a `Duration`'s range.
pub inline fn durationHolds(ns: anytype) bool {
    return ns >= -duration_max_ns and ns <= duration_max_ns;
}

/// `x * unit`, `x` a finite double and `unit` a positive integer, rounded
/// from its exact value to the nearest integer, a half away from zero,
/// and held within ±2^100; null when `x` is not finite. A double is an
/// integer times a power of two, so the product is exact before the one
/// rounding. The checker converts a constant with it, and the runtime a
/// number known only as the program runs.
pub fn floatToNs(x: f64, unit: i64) ?i128 {
    if (!std.math.isFinite(x)) return null;
    const cap: i128 = 1 << 100;
    const bits: u64 = @bitCast(x);
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7ff);
    const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
    const m: u64 = if (exp_bits == 0) frac else frac | (@as(u64, 1) << 52);
    const e: i32 = (if (exp_bits == 0) @as(i32, 1) else exp_bits) - 1075;
    const neg = bits >> 63 == 1;
    // |x * unit| = m * unit * 2^e, m below 2^53 and unit below 2^42.
    const num: u128 = @as(u128, m) * @as(u128, @intCast(unit));
    var q: u128 = 0;
    if (e >= 0) {
        if (num != 0 and (e >= 100 or (@as(u128, cap) >> @intCast(e)) < num)) {
            q = cap;
        } else q = num << @intCast(e);
    } else {
        const shift: u32 = @intCast(-e);
        if (shift < 128) {
            q = num >> @intCast(shift);
            const rest = num - (q << @intCast(shift));
            if (rest >= (@as(u128, 1) << @intCast(shift - 1))) q += 1;
        }
    }
    const n: i128 = @intCast(@min(q, cap));
    return if (neg) -n else n;
}
