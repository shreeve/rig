p='src/sema.zig'
s=open(p).read()
old='''    signal_sym_id: SymbolId = symbol_invalid,
'''
new='''    signal_sym_id: SymbolId = symbol_invalid,
    endian_sym_id: SymbolId = symbol_invalid,
'''
assert old in s; s=s.replace(old,new,1)
old='''pub const ElemCall = struct {
    op: ElemOp,
};

pub const ElemOp = enum { copy, fill, swap };'''
new='''pub const ElemCall = struct {
    op: ElemOp,
    /// `read` / `write`: the integer or float type of the value.
    num: TypeId = type_invalid,
};

pub const ElemOp = enum { copy, fill, swap, read, write };'''
assert old in s; s=s.replace(old,new,1)
old='''/// A built-in method on the elements of a slice, an array, a Vec, or a
/// String: `!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`.'''
new='''/// A built-in method on the elements of a slice, an array, a Vec, or a
/// String: `!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`, and on
/// bytes `buf.read[U16, .big](at)` and `!buf.write[U32, .little](at, v)`.'''
assert old in s; s=s.replace(old,new,1)
old='''        .nominal => |sym_id| return local_ctx.intern(.{ .imported_nominal = .{ .module_id = origin_module_id, .sym_id = sym_id } }),'''
new='''        // Every module has its own `Endian`, and they are one type.
        .nominal => |sym_id| return if (sym_id == foreign_ctx.endian_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.endian_sym_id })
        else
            local_ctx.intern(.{ .imported_nominal = .{ .module_id = origin_module_id, .sym_id = sym_id } }),'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='src/resolve.zig'
s=open(p).read()
old='''    // Signal[T]: a Copy value plus subscriber closures notified on `set`.'''
new='''    // Endian: the byte order `read` and `write` take, `.little` or `.big`.
    {
        const sym = try ctx.addSymbol(.{
            .name = "Endian",
            .kind = .nominal_type,
            .ty = ctx.types.unknown_id,
            .decl_pos = builtin_pos,
            .scope = module_scope,
        });
        try ctx.addToScope(module_scope, sym);
        ctx.endian_sym_id = sym;
        try setFields(ctx, sym, &.{
            .{ .name = "little", .ty = ctx.types.void_id, .decl_pos = builtin_pos, .is_variant = true },
            .{ .name = "big", .ty = ctx.types.void_id, .decl_pos = builtin_pos, .is_variant = true },
        });
    }

    // Signal[T]: a Copy value plus subscriber closures notified on `set`.'''
assert old in s; s=s.replace(old,new,1)
s=s.replace('''// `Cell[T]`, `Vec[T]`, and `Signal[T]`, registered in every module scope
// before user declarations.''','''// `Cell[T]`, `Vec[T]`, and `Signal[T]`, and the enum `Endian`, registered
// in every module scope before user declarations.''')
open(p,'w').write(s)

p='src/emit.zig'
s=open(p).read()
old='''        if (sym == self.sema.vec_sym_id or sym == self.sema.cell_sym_id or sym == self.sema.signal_sym_id) {'''
new='''        if (sym == self.sema.vec_sym_id or sym == self.sema.cell_sym_id or sym == self.sema.signal_sym_id or sym == self.sema.endian_sym_id) {'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='src/runtime.zig'
s=open(p).read()
old='''fn bounds(count: usize, lo: anytype, hi: anytype) [2]usize {'''
new='''/// Rig's `Endian`: the byte order of `read` and `write`.
pub const Endian = enum { little, big };

/// `bytes.read[T, e](at)`: the integer or float `T` stored in the
/// `@sizeOf(T)` bytes from `at`, in byte order `e`; panics unless they
/// are all in range.
pub fn readInt(comptime T: type, bytes: anytype, at: anytype, comptime endian: Endian) T {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, at, n) orelse @panic("byte read out of range");
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    return @bitCast(std.mem.readInt(Bits, bytes[i..][0..n], zigEndian(endian)));
}

/// `!bytes.write[T, e](at, value)`: store `value` in the `@sizeOf(T)`
/// bytes from `at`, in byte order `e`; panics unless they are all in
/// range.
pub fn writeInt(comptime T: type, bytes: anytype, at: anytype, value: T, comptime endian: Endian) void {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, at, n) orelse @panic("byte write out of range");
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    std.mem.writeInt(Bits, bytes[i..][0..n], @bitCast(value), zigEndian(endian));
}

/// `at` as an offset with `at + n <= count`, or null.
fn byteOffset(count: usize, at: anytype, n: usize) ?usize {
    const i = std.math.cast(usize, at) orelse return null;
    if (i > count or count - i < n) return null;
    return i;
}

fn zigEndian(comptime e: Endian) std.builtin.Endian {
    return switch (e) {
        .little => .little,
        .big => .big,
    };
}

fn bounds(count: usize, lo: anytype, hi: anytype) [2]usize {'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)
