//! `std.math`: the Float functions, on Zig's builtins and `std.math`.

const std = @import("std");

pub fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

pub fn floor(x: f64) f64 {
    return @floor(x);
}

pub fn ceil(x: f64) f64 {
    return @ceil(x);
}

pub fn trunc(x: f64) f64 {
    return @trunc(x);
}

pub fn copysign(x: f64, sign: f64) f64 {
    return std.math.copysign(x, sign);
}

pub fn log2(x: f64) f64 {
    return @log2(x);
}

pub fn exp(x: f64) f64 {
    return @exp(x);
}

pub fn ln(x: f64) f64 {
    return @log(x);
}

pub fn sin(x: f64) f64 {
    return @sin(x);
}

pub fn cos(x: f64) f64 {
    return @cos(x);
}

pub fn powf(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}

pub fn clamp_bounds() void {
    @panic("math.clamp: the low bound is above the high bound");
}

/// The shortest decimal of a finite `x`, with trailing zeros moved into the
/// exponent.
fn decimalOf(x: f64) struct { digits: u64, exp: i64 } {
    const d = std.fmt.float.binaryToDecimal(u64, @as(u64, @bitCast(x)), 52, 11, false, &std.fmt.float.Backend64_TablesFull);
    if (d.mantissa == 0) return .{ .digits = 0, .exp = 0 };
    var m = d.mantissa;
    var e: i64 = d.exponent;
    while (m % 10 == 0) {
        m /= 10;
        e += 1;
    }
    return .{ .digits = m, .exp = e };
}

pub fn shortest_digits(x: f64) u64 {
    return decimalOf(x).digits;
}

pub fn shortest_exp(x: f64) i64 {
    return decimalOf(x).exp;
}
