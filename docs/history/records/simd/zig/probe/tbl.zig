const V = @Vector(16, u8);
extern fn @"llvm.aarch64.neon.tbl1"(V, V) V;
var t: [16]u8 = @splat(0);
var i: [16]u8 = @splat(0);
pub fn main() void {
    const r = @"llvm.aarch64.neon.tbl1"(t, i);
    t = r;
}
