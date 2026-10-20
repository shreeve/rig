const std = @import("std");
const P = packed struct { v: @Vector(4, u8), x: u8 }; export fn f(p: *const P) u8 { return p.v[0] +% p.x; }
