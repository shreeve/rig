const std = @import("std");
export fn f(p: *const [16]bool) u16 { return @bitCast(p.*); }
