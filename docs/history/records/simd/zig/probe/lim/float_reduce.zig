const std = @import("std");
export fn f(a: *const @Vector(4, f32)) f32 { return @reduce(.Add, a.*); }
