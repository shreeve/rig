const std = @import("std");
export fn f(a: *const @Vector(4, u8), o: *@Vector(4, u8)) void { o.* = a.* + 1; }
