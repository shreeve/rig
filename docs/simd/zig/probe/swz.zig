const V = @Vector(16, u8);
extern fn @"llvm.wasm.swizzle"(V, V) V;
var t: [16]u8 = @splat(0);
var i: [16]u8 = @splat(0);
export fn go() void {
    const r = @"llvm.wasm.swizzle"(t, i);
    t = r;
}
