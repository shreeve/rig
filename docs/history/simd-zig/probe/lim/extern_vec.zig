const std = @import("std");
const E = extern struct { v: @Vector(4, u32) }; export fn f(p: *const E) u32 { return p.v[0]; }
