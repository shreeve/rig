const std = @import("std");
export fn f(a: @Vector(16, u8)) u8 { return @reduce(.Add, a); }
