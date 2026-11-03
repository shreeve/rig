const std = @import("std");
export fn f(a: *const @Vector(16, u8), o: *@Vector(16, u8)) void { o.* = @ctz(a.*); }
