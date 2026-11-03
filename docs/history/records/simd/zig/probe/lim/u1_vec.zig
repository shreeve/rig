const std = @import("std");
export fn f(a: *const @Vector(16, u8)) u16 { const b: @Vector(16, u1) = @truncate(a.*); return @bitCast(b); }
