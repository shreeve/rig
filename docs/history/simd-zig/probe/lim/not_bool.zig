const std = @import("std");
export fn f(a: *const @Vector(4, u8)) bool { const p = a.* == @as(@Vector(4, u8), @splat(1)); return @reduce(.Or, !p); }
