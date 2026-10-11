extern fn @"llvm.clmul.i64"(u64, u64) u64;
export fn f(x: u64, y: u64) u64 { return @"llvm.clmul.i64"(x, y); }
