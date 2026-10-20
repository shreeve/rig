const std = @import("std");
export fn f() u8 { const v: @Vector(0, u8) = .{}; _ = v; return 0; }
