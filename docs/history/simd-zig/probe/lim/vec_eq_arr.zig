const std = @import("std");
export fn f(a: *const [16]u8) bool { const v: @Vector(16, u8) = a.*; return std.meta.eql(v, v); }
