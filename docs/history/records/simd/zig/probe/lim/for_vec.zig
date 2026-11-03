const std = @import("std");
export fn f(a: *const @Vector(4, u8)) u8 { var s: u8 = 0; for (a.*) |x| s +%= x; return s; }
