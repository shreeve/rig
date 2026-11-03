const std = @import("std");
export fn f(a: *@Vector(4, u8), i: usize) void { const p = &a[i]; p.* = 1; }
