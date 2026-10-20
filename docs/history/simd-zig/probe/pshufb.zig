const V = @Vector(16, u8);
extern fn @"llvm.x86.ssse3.pshuf.b.128"(V, V) V;
var t: [16]u8 = @splat(0);
var i: [16]u8 = @splat(0);
pub fn main() void {
    const r = @"llvm.x86.ssse3.pshuf.b.128"(t, i);
    t = r;
}
