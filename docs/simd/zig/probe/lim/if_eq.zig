const std = @import("std");
export fn f(a: *const @Vector(4, u8), b: *const @Vector(4, u8)) bool { if (a.* == b.*) return true; return false; }
