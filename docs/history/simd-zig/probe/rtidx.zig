export fn f(p: *const [16]u8, i: usize) u8 {
    const v: @Vector(16, u8) = p.*;
    return v[i];
}
