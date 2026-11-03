const std = @import("std");
export fn f(a: *const @Vector(16, u8), o: *@Vector(16, u1)) void { o.* = @intFromBool(a.* == @as(@Vector(16, u8), @splat(0))); }
