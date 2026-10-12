export fn bc(p: *const [16]u8) u128 { return @bitCast(p.*); }
export fn ptr(p: *const [16]u8) u128 { return @as(*align(1) const u128, @ptrCast(p)).*; }
export fn bc_aligned(p: *align(16) const [16]u8) u128 { return @bitCast(p.*); }
export fn bc_vec(p: *const [16]u8) u128 { const v: @Vector(16, u8) = p.*; return @bitCast(v); }
export fn bc8(p: *const [8]u8) u64 { return @bitCast(p.*); }
