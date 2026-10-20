const V = @Vector(16, u8);
extern fn @"llvm.aarch64.neon.tbl1"(V, V) V;
export fn f(t: *const [16]u8, i: *const [16]u8, o: *[16]u8) void {
    o.* = @"llvm.aarch64.neon.tbl1"(t.*, i.*);
}
