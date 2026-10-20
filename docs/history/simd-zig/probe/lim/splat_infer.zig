const std = @import("std");
export fn f(a: *const @Vector(4, u8)) bool { return @reduce(.Or, a.* == @splat(34)); }
