const std = @import("std");
export fn f(a: *const @Vector(4, u8)) bool { const p = a.* == @as(@Vector(4, u8), @splat(1)); const q = p and p; return @reduce(.Or, q); }
