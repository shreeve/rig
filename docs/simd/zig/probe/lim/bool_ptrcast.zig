const std = @import("std");
export fn f(p: *const [16]bool) u16 { const v: @Vector(16, bool) = p.*; return @bitCast(v); }
