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
