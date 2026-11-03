const V = @Vector(16, u8);
export fn add_checked(a: *const V, b: *const V, o: *V) void { o.* = a.* + b.*; }
export fn add_wrap(a: *const V, b: *const V, o: *V) void { o.* = a.* +% b.*; }
export fn sum_checked(a: *const @Vector(64, u8)) u8 {
    const wide: @Vector(64, u16) = a.*;
    return @intCast(@reduce(.Add, wide));
}
export fn sum_wide(a: *const @Vector(64, u8)) u64 {
    const wide: @Vector(64, u16) = a.*;
    return @reduce(.Add, wide);
}
