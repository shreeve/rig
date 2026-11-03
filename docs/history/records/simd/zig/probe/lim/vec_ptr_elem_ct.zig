const std = @import("std");
export fn f(a: *@Vector(4, u8)) void { const p = &a[1]; p.* = 1; }
