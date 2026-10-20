// 7. Wider-than-native vectors: 64 x u8 (4 q-regs on NEON, 2 ymm on AVX2).
const V64 = @Vector(64, u8);
const V16x32 = @Vector(16, u32);
export fn w_add(a: *const V64, b: *const V64, o: *V64) void { o.* = a.* +% b.*; }
export fn w_min(a: *const V64, b: *const V64, o: *V64) void { o.* = @min(a.*, b.*); }
export fn w_sel(a: *const V64, b: *const V64, o: *V64) void { o.* = @select(u8, a.* < b.*, a.*, b.*); }
export fn w_any(a: *const V64, b: *const V64) bool { return @reduce(.Or, a.* == b.*); }
export fn w_sum(a: *const V64) u8 { return @reduce(.Add, a.*); }
export fn w_u32add(a: *const V16x32, b: *const V16x32, o: *V16x32) void { o.* = a.* +% b.*; }
// Widen 16 bytes to 16 x u32 (zero-extend) and back.
export fn w_widen(a: *const @Vector(16, u8), o: *V16x32) void { o.* = a.*; }
export fn w_narrow(a: *const V16x32, o: *@Vector(16, u8)) void { o.* = @truncate(a.*); }
// Storing a bool vector to memory and bitcasting it.
export fn w_boolstore(a: *const V64, b: *const V64, o: *@Vector(64, bool)) void { o.* = a.* == b.*; }
export fn w_boolarr(a: *const @Vector(16, u8), b: *const @Vector(16, u8), o: *[16]bool) void { o.* = a.* == b.*; }
