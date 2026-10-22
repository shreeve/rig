p='src/typecheck.zig'
s=open(p).read()
old='''    /// `copy`, `fill`, and `swap`: built-in methods on the elements of a
    /// slice, an array, or a Vec, which write them in place. Null when
    /// `method` is none of them or the receiver has no elements.
    fn elemsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .slice => |sl| sl.elem,
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            .string => try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            else => vecElementType(self.ctx, peeled) orelse return null,
        };
        if (ct) |b| return try self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});'''
new='''    /// `copy`, `fill`, and `swap`: built-in methods on the elements of a
    /// slice, an array, or a Vec, which write them in place; and `read`
    /// and `write` on bytes (`bytesCall`). Null when `method` is none of
    /// them or the receiver has no elements.
    fn elemsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .slice => |sl| sl.elem,
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            .string => try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            else => vecElementType(self.ctx, peeled) orelse return null,
        };
        if (op == .read or op == .write) return try self.bytesCall(callee, obj, obj_ty, elem, len, op, pos, args, ct);
        if (ct) |b| return try self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});'''
assert old in s; s=s.replace(old,new,1)
old='''            .swap => "two arguments, the indexes of the elements to swap",
        }, args.len, if (args.len == 1) "" else "s" });'''
new='''            .swap => "two arguments, the indexes of the elements to swap",
            .read, .write => unreachable,
        }, args.len, if (args.len == 1) "" else "s" });'''
assert old in s; s=s.replace(old,new,1)
old='''            .swap => &.{ recv, self.t().int_id, self.t().int_id },
        };'''
new='''            .swap => &.{ recv, self.t().int_id, self.t().int_id },
            .read, .write => unreachable,
        };'''
assert old in s; s=s.replace(old,new,1)
old='''        switch (op) {
            .copy, .fill => try self.checkExpr(args[0], params[1]),
            .swap => for (args) |a| try self.checkIndexArg(a, len),
        }
        return self.t().void_id;
    }
'''
new='''        switch (op) {
            .copy, .fill => try self.checkExpr(args[0], params[1]),
            .swap => for (args) |a| try self.checkIndexArg(a, len),
            .read, .write => unreachable,
        }
        return self.t().void_id;
    }

    /// `bytes.read[T, e](at)` and `!bytes.write[T, e](at, v)`: the integer
    /// or float `T` held in the `@sizeOf(T)` bytes from `at`, in byte
    /// order `e`, a compile-time `Endian`. The bytes are a `[]U8`, an
    /// `![]U8`, a `[N]U8`, a `Vec[U8]`, or (for `read`) a String; `at` is
    /// checked now against an array's length when it is constant, and
    /// when the program runs otherwise.
    fn bytesCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, len: ?u64, op: sema.ElemOp, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const method = @tagName(op);
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        const byte = try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
        if (elem != byte) return self.badCall(args, obj, "`{s}` works on bytes: a `[]U8`, an `![]U8`, a `[N]U8`, a `Vec[U8]`, or a String; got `{s}`", .{ method, try self.tyName(obj_ty) });
        if (op == .write) {
            if (!try self.writesElements(obj, obj_ty, peeled, method)) return self.skipCall(args);
        } else if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "only reads its receiver");
        const example = if (op == .read) "read[U32, .little](at)" else "write[U32, .little](at, value)";
        const b = ct orelse return self.badCall(args, pos, "`{s}` takes the type and the byte order in brackets: `{s}`", .{ method, example });
        try self.ctx.recordInstance(b, .function);
        const given = sema.bracketArgs(b);
        if (given.len != 2) return self.badCall(args, b, "`{s}` takes two compile-time arguments, the type and the byte order: `{s}`", .{ method, example });
        const num = try self.typeArg(given[0]);
        if (self.isPoison(num)) return self.skipCall(args);
        const num_ok = switch (self.ctx.types.get(num)) {
            .int, .float => true,
            else => false,
        };
        if (!num_ok) return self.badCall(args, given[0], "`{s}` {s} an integer or float type; got `{s}`", .{ method, if (op == .read) "reads" else "writes", try self.tyName(num) });
        const endian = try self.ctx.intern(.{ .nominal = self.ctx.endian_sym_id });
        try self.checkCtValue(given[1], endian, 1, method);
        for (args) |a| if (a.isKind(.kwarg)) return self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        const want: usize = if (op == .read) 1 else 2;
        if (args.len != want) return self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, if (op == .read) "one argument, the offset of the first byte" else "two arguments, the offset of the first byte and the value", args.len, if (args.len == 1) "" else "s" });
        const recv = try self.ctx.intern(if (op == .read) Type{ .borrow_read = peeled } else Type{ .borrow_write = peeled });
        const params: []const TypeId = if (op == .read) &.{ recv, self.t().int_id } else &.{ recv, self.t().int_id, num };
        const returns = if (op == .read) num else self.t().void_id;
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(params), .returns = returns, .is_sub = op == .write });
        try self.ctx.recordElemCall(callee, .{ .op = op, .num = num });
        try self.checkOffsetArg(args[0], num, len, method);
        if (op == .write) try self.checkExpr(args[1], num);
        return returns;
    }

    /// The offset of a `read` or `write` of a `num`: an integer, checked
    /// now against a known length when it is constant.
    fn checkOffsetArg(self: *Checker, a: Sexp, num: TypeId, len: ?u64, method: []const u8) Error!void {
        const ty = try self.synthValue(a);
        if (self.isPoison(ty)) return;
        if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an offset must be an integer; got `{s}`", .{try self.tyName(ty)});
        if (ty == self.t().int_literal_id) try self.checkLiteralFits(a, self.t().int_id);
        const at = self.constInt(a) orelse return;
        const size: i128 = switch (self.ctx.types.get(num)) {
            .int => |i| if (i.bits == 0) 8 else i.bits / 8,
            .float => |f| if (f.bits == 0) 8 else f.bits / 8,
            else => return,
        };
        if (at < 0) return self.errAt(a, "an offset cannot be negative; got `{d}`", .{at});
        if (len) |n| if (at + size > n) {
            try self.errAt(a, "`{s}` of a `{s}` at `{d}` runs past the end of an array of length {d}: it needs {d} bytes", .{ method, try self.tyName(num), at, n, size });
        };
    }
'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='src/emit.zig'
s=open(p).read()
old='''    fn emitElemCall(self: *Emitter, call: Sexp, ec: sema.ElemCall) Error!void {
        const callee = self.sema.calleeOf(call);
        try self.w.print("rig.{s}(", .{@tagName(ec.op)});
        try self.emitElems(ir.Member.object(callee));
        for (ir.Call.args(call)) |a| {
            try self.w.writeAll(", ");
            try self.emitBare(a);
        }
        try self.w.writeAll(")");
    }'''
new='''    fn emitElemCall(self: *Emitter, call: Sexp, ec: sema.ElemCall) Error!void {
        const callee = self.sema.calleeOf(call);
        const args = ir.Call.args(call);
        switch (ec.op) {
            // `rig.readInt(T, bytes, at, endian)`,
            // `rig.writeInt(T, bytes, at, value, endian)`.
            .read, .write => {
                try self.w.writeAll(if (ec.op == .read) "rig.readInt(" else "rig.writeInt(");
                try self.emitTypeTy(ec.num);
                try self.w.writeAll(", ");
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
                try self.w.writeAll(", ");
                try self.emitBare(self.sema.ctArgsOf(call)[1]);
            },
            .copy, .fill, .swap => {
                try self.w.print("rig.{s}(", .{@tagName(ec.op)});
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
            },
        }
        try self.w.writeAll(")");
    }'''
assert old in s; s=s.replace(old,new,1)
s=s.replace('''    /// A built-in element method: `!dst.copy(src)` is `rig.copy(dst,
    /// src)`, and `fill` and `swap` likewise, on the receiver's elements
    /// (`emitElems`). Its arguments are plain data, so none is hoisted.''','''    /// A built-in element method: `!dst.copy(src)` is `rig.copy(dst,
    /// src)`, `fill` and `swap` likewise, and `read` and `write` are
    /// `rig.readInt` and `rig.writeInt`, on the receiver's elements
    /// (`emitElems`). The arguments are plain data, so none is hoisted.''')
open(p,'w').write(s)
