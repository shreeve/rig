const std = @import("std");
export fn f(a: *const [24]u8) u24 { _ = a; return 0; } export fn g(a: *const [24]u8) u32 { const v: @Vector(24, u8) = a.*; const m: u24 = @bitCast(v == @as(@Vector(24, u8), @splat(34))); return m; }
