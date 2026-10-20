// 2. Lane-wise ops on 16 x u8 (plus a few i8 / u16 / u32 where the ISA differs).
const V = @Vector(16, u8);
const VI = @Vector(16, i8);
const VB = @Vector(16, bool);
const V8x16 = @Vector(8, u16);
const V4x32 = @Vector(4, u32);

// Comparisons produce @Vector(16,bool); store it as a 0x00/0xFF byte mask
// (what the hardware produces) via @select, which should be free.
inline fn mask(b: VB) V {
    return @select(u8, b, @as(V, @splat(0xFF)), @as(V, @splat(0)));
}

export fn eq_u8(a: *const V, b: *const V, o: *V) void { o.* = mask(a.* == b.*); }
export fn ne_u8(a: *const V, b: *const V, o: *V) void { o.* = mask(a.* != b.*); }
export fn lt_u8(a: *const V, b: *const V, o: *V) void { o.* = mask(a.* < b.*); }
export fn le_u8(a: *const V, b: *const V, o: *V) void { o.* = mask(a.* <= b.*); }
export fn lt_i8(a: *const VI, b: *const VI, o: *V) void { o.* = mask(a.* < b.*); }
// Range test, the classic classifier step: 'a' <= x <= 'z'
export fn inrange_u8(a: *const V, o: *V) void {
    const x = a.*;
    o.* = mask((x >= @as(V, @splat('a'))) & (x <= @as(V, @splat('z'))));
}
// Same written with the subtract trick: (x - 'a') <= 25 (unsigned)
export fn inrange_sub_u8(a: *const V, o: *V) void {
    const x = a.*;
    o.* = mask((x -% @as(V, @splat('a'))) <= @as(V, @splat(25)));
}

export fn and_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* & b.*; }
export fn or_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* | b.*; }
export fn xor_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* ^ b.*; }
export fn not_u8(a: *const V, o: *V) void { o.* = ~a.*; }
export fn andnot_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* & ~b.*; }
// Bool-vector logic (no `and`/`or` on vectors: & | ^ ! only)
export fn bool_logic(a: *const V, b: *const V, o: *V) void {
    const p = a.* == b.*;
    const q = a.* < b.*;
    o.* = mask((p | q) & !(p ^ q));
}

// Arithmetic. Plain + traps on overflow in ReleaseSafe (per lane).
export fn add_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* + b.*; }
export fn addw_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* +% b.*; }
export fn sub_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* - b.*; }
export fn subw_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* -% b.*; }
export fn adds_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* +| b.*; }
export fn subs_u8(a: *const V, b: *const V, o: *V) void { o.* = a.* -| b.*; }
export fn adds_i8(a: *const VI, b: *const VI, o: *VI) void { o.* = a.* +| b.*; }
export fn mul_u16(a: *const V8x16, b: *const V8x16, o: *V8x16) void { o.* = a.* *% b.*; }
export fn mul_u32(a: *const V4x32, b: *const V4x32, o: *V4x32) void { o.* = a.* *% b.*; }

export fn min_u8(a: *const V, b: *const V, o: *V) void { o.* = @min(a.*, b.*); }
export fn max_u8(a: *const V, b: *const V, o: *V) void { o.* = @max(a.*, b.*); }
export fn min_i8(a: *const VI, b: *const VI, o: *VI) void { o.* = @min(a.*, b.*); }
export fn max_u32(a: *const V4x32, b: *const V4x32, o: *V4x32) void { o.* = @max(a.*, b.*); }
export fn abs_i8(a: *const VI, o: *V) void { o.* = @abs(a.*); }

// Shifts. RHS must be @Vector(16, u3) for u8 lanes.
export fn shr4_u8(a: *const V, o: *V) void { o.* = a.* >> @splat(4); }
export fn shl1_u8(a: *const V, o: *V) void { o.* = a.* << @splat(1); }
export fn shr_var_u8(a: *const V, s: u8, o: *V) void { o.* = a.* >> @splat(@as(u3, @truncate(s))); }
export fn shr_lanes_u8(a: *const V, s: *const @Vector(16, u3), o: *V) void { o.* = a.* >> s.*; }
export fn sar3_i8(a: *const VI, o: *VI) void { o.* = a.* >> @splat(3); }
export fn shr4_u16(a: *const V8x16, o: *V8x16) void { o.* = a.* >> @splat(4); }
// Shift that may overflow: << in ReleaseSafe is NOT checked; @shlExact is.
export fn shlexact_u8(a: *const V, o: *V) void { o.* = @shlExact(a.*, @as(@Vector(16, u3), @splat(1))); }
export fn shlsat_u8(a: *const V, o: *V) void { o.* = a.* <<| @as(@Vector(16, u3), @splat(1)); }
// Per-lane shift with the amounts held as bytes (avoids the bit-packed
// in-memory layout of @Vector(16, u3)).
export fn shr_lanes_bytes(a: *const V, s: *const V, o: *V) void {
    const amt: @Vector(16, u3) = @truncate(s.*);
    o.* = a.* >> amt;
}
