p='src/typecheck.zig'
s=open(p).read()
def rep(old,new,cnt=1):
    global s
    assert old in s, old[:80]
    s=s.replace(old,new,cnt)
rep('''    lent_write: Sexp = .nil,
''','''    lent_write: Sexp = .nil,
    /// The argument being checked, when the call keeps no borrow of its
    /// arguments: a temporary array there may be lent as a `[]T`.
    lent_temp: Sexp = .nil,
    /// Set by a caller of `checkArgs` whose call may take a temporary
    /// array as a `[]T` argument (a function or method, not a closure),
    /// with a method's receiver parameter.
    lend_call: bool = false,
    lend_recv: ?TypeId = null,
''')
# checkArgs: compute lends
rep('''    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo, callee: []const u8, pos: u32) Error!void {
        const call = self.current_call;''','''    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo, callee: []const u8, pos: u32) Error!void {
        const call = self.current_call;
        const lends = self.lend_call and !self.callRetains(f, self.lend_recv);
        self.lend_call = false;
        self.lend_recv = null;''')
rep('''            slots[i] = .{ .arg = @intCast(i) };
            try self.checkArg(a, f, i);''','''            slots[i] = .{ .arg = @intCast(i) };
            try self.checkArg(a, f, i, lends);''')
rep('''            slots[idx] = .{ .arg = @intCast(ai) };
            try self.checkArg(ir.Kwarg.value(kw), f, idx);''','''            slots[idx] = .{ .arg = @intCast(ai) };
            try self.checkArg(ir.Kwarg.value(kw), f, idx, lends);''')
rep('''    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize) Error!void {
        try self.checkExpr(arg, f.params[i]);
    }''','''    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, lends: bool) Error!void {
        const saved = self.lent_temp;
        defer self.lent_temp = saved;
        self.lent_temp = if (lends) arg else .nil;
        try self.checkExpr(arg, f.params[i]);
    }

    /// Whether a call of `f` (with receiver parameter `recv`) may keep a
    /// borrow of an argument past the call: in its result, or through a
    /// write borrow into something that can hold one.
    fn callRetains(self: *Checker, f: FunctionType, recv: ?TypeId) bool {
        if (sema.mayHoldBorrow(self.ctx, f.returns)) return true;
        for (f.params) |p| if (self.storesBorrow(p)) return true;
        return if (recv) |r| self.storesBorrow(r) else false;
    }

    /// A write borrow into something that can hold a borrow.
    fn storesBorrow(self: *Checker, param: TypeId) bool {
        const inner = switch (self.ctx.types.get(param)) {
            .borrow_write => |inner| inner,
            else => return false,
        };
        const held = if (sema.writeSliceElem(self.ctx, param)) |elem| elem else inner;
        return sema.mayHoldBorrow(self.ctx, held);
    }''')
# callers: functionCall
rep('''        if (fty.function.ct_params.len > 0) try self.ctx.recordType(callee, try self.ctx.internCopy(.{ .function = f }));
        try self.checkArgs(args, f, info, name, callee.src.pos);''','''        if (fty.function.ct_params.len > 0) try self.ctx.recordType(callee, try self.ctx.internCopy(.{ .function = f }));
        self.lend_call = true;
        try self.checkArgs(args, f, info, name, callee.src.pos);''')
rep('''        try self.checkArgs(args, rest, info, method, pos);''','''        self.lend_call = true;
        self.lend_recv = f.params[0];
        try self.checkArgs(args, rest, info, method, pos);''')
rep('''                f = (try self.instantiateCall(f, ct, args, info, 0, name, pos, m.receiver != .none, recv)) orelse return self.skipCall(args);
                try self.noteCallee(f);
                try self.checkArgs(args, f, info, name, pos);''','''                f = (try self.instantiateCall(f, ct, args, info, 0, name, pos, m.receiver != .none, recv)) orelse return self.skipCall(args);
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, name, pos);''')
rep('''                // A generic function's callee has the instance's signature.
                try self.noteCallee(f);
                try self.checkArgs(args, f, info, qualified, pos);''','''                // A generic function's callee has the instance's signature.
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, qualified, pos);''')
# copy arg in elemsCall
rep('''        switch (op) {
            .copy, .fill => try self.checkExpr(args[0], params[1]),''','''        switch (op) {
            // `copy` keeps nothing of its source: a temporary array may
            // be lent as it.
            .copy => {
                const saved = self.lent_temp;
                defer self.lent_temp = saved;
                self.lent_temp = args[0];
                try self.checkExpr(args[0], params[1]);
            },
            .fill => try self.checkExpr(args[0], params[1]),''')
# checkExpr: array literal pre-check and mismatch path
rep('''        if (try self.checkContextual(e, expected)) |ty| return self.ctx.recordType(e, ty);

        const actual = try self.synthExpr(e);
        if (compatible(self.ctx, actual, expected)) {''','''        if (try self.lentTempLiteral(e, expected)) return;
        if (try self.checkContextual(e, expected)) |ty| return self.ctx.recordType(e, ty);

        const actual = try self.synthExpr(e);
        if (try self.arrayAsSlice(e, actual, expected)) return;
        if (compatible(self.ctx, actual, expected)) {''')
rep('''    fn mismatch(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error!void {''','''    /// An array literal or fill lent as a `[]T` argument: its elements
    /// take the slice's element type. True when handled.
    fn lentTempLiteral(self: *Checker, e: Sexp, expected: TypeId) Error!bool {
        if (!e.isKind(.array) and !e.isKind(.array_fill)) return false;
        if (!sameNode(e, self.lent_temp)) return false;
        const elem = switch (self.ctx.types.get(expected)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        const t = try self.synthQuiet(e);
        const len = switch (self.ctx.types.get(t)) {
            .array => |a| a.len,
            else => return false,
        };
        try self.checkExpr(e, try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } }));
        try self.ctx.recordArrayView(e, .temporary);
        return true;
    }

    /// An array where a slice is expected: `?a` as `?a[..]` where a `[]T`
    /// is, `!a` as `!a[..]` where a `![]T` is, and a temporary array as
    /// a `[]T` argument of a call that keeps no borrow of it. A bare
    /// named array is rejected with the borrow to write. True when
    /// handled.
    fn arrayAsSlice(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const want_write = sema.writeSliceElem(self.ctx, expected) != null;
        const elem = sema.writeSliceElem(self.ctx, expected) orelse switch (self.ctx.types.get(expected)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        const arr_of = struct {
            fn f(ctx: *const SemContext, ty: TypeId, want: TypeId) bool {
                return switch (ctx.types.get(ty)) {
                    .array => |a| a.elem == want,
                    else => false,
                };
            }
        }.f;
        switch (self.ctx.types.get(actual)) {
            .borrow_read => |inner| if (!want_write and e.isKind(.read) and arr_of(self.ctx, inner, elem)) {
                try self.ctx.recordType(e, expected);
                try self.ctx.recordArrayView(e, .borrowed);
                return true;
            },
            .borrow_write => |inner| if (want_write and e.isKind(.write) and arr_of(self.ctx, inner, elem)) {
                try self.ctx.recordType(e, expected);
                try self.ctx.recordArrayView(e, .borrowed);
                return true;
            },
            .array => |a| if (a.elem == elem) {
                if (isPlaceExpr(e)) {
                    const sp = self.ctx.span(e);
                    const text = self.ctx.source[sp.start..sp.end];
                    const sigil: u8 = if (want_write) '!' else '?';
                    try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; write `{c}{s}` or `{c}{s}[..]`", .{ try self.tyName(expected), try self.tyName(actual), sigil, text, sigil, text });
                    return true;
                }
                if (!want_write and sameNode(e, self.lent_temp)) {
                    try self.ctx.recordArrayView(e, .temporary);
                    return true;
                }
                if (!want_write) {
                    try self.errAt(e, "a temporary array is lent as a `{s}` only to a call that keeps no borrow of it; bind it to a name and pass `?name`", .{try self.tyName(expected)});
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn mismatch(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error!void {''')
# bindArg for generic inference
rep('''            else if (sema.writeSliceElem(self.ctx, actual)) |elem|
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else
                self.noteMismatch(inf, pattern, actual, arg),''','''            else if (sema.writeSliceElem(self.ctx, actual)) |elem|
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else if (arrayElem(self.ctx, actual)) |elem|
                // An array lent as a slice (`?a`, a temporary).
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else
                self.noteMismatch(inf, pattern, actual, arg),''')
rep('''fn sameNode(a: Sexp, b: Sexp) bool {''','''/// The element type of an array, or of a borrow of one.
fn arrayElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(sema.unwrapBorrows(ctx, ty))) {
        .array => |a| a.elem,
        else => null,
    };
}

fn sameNode(a: Sexp, b: Sexp) bool {''')
open(p,'w').write(s)
