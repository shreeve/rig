//! Typecheck's built-ins and named members: error names and sets,
//! constant and qualified patterns, enum literals and variants with
//! fields, list construction, and `$`-calls.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema.zig");
const Wide = sema.Wide;
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CompatCheck = @import("compat.zig");
const CallCheck = @import("calls.zig");
const ExprCheck = @import("expr.zig");
const PatternCheck = @import("patterns.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// A constant integer expression must fit the numeric type it gets:
/// in range for an integer type, exactly for a float type.
pub fn checkLiteralFits(self: *Checker, e: Sexp, target: TypeId) Error!void {
    const tt = self.ctx.types.get(target);
    if (tt != .int and tt != .float and tt != .slot) return;
    // A literal is a slot only where its count is known: in a generic
    // body, `Slot[n].of(i)` makes one, tested.
    if (tt == .slot and sema.slotCount(self.ctx, tt.slot) == null) {
        return self.errAt(e, "a literal is a `{s}` only where `n` is known; make one with `{s}.of(i)`", .{ try self.tyName(target), try self.tyName(target) });
    }
    switch (sema.constInt(self.ctx, e)) {
        .value => |v| if (!CompatCheck.holdsInt(self.ctx, target, v)) switch (tt) {
            .slot => |n| try self.errAt(e, "integer value `{d}` does not fit in `{s}` (0..{d}): a slot names one of {d} slots", .{ v, try self.tyName(target), sema.slotCount(self.ctx, n).? - 1, sema.slotCount(self.ctx, n).? }),
            .int => |info| try self.errAt(e, "integer value `{d}` does not fit in `{s}` ({d}..{d})", .{ v, try self.tyName(target), CompatCheck.intBounds(info).min, CompatCheck.intBounds(info).max }),
            else => try self.errAt(e, "integer value `{d}` does not fit exactly in `{s}`", .{ v, try self.tyName(target) }),
        },
        .overflow => if (e == .src) {
            try self.errAt(e, "integer literal `{s}` is too large", .{self.text(e)});
        } else try self.errAt(e, "this constant expression overflows; its value does not fit in `{s}`", .{try self.tyName(target)}),
        // Not constant as a whole (a branch is chosen when the program
        // runs): its constant parts are values of the type too.
        .not_constant => if (e.kind()) |h| switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^" => {
                try checkLiteralFits(self, ir.get(e, .left), target);
                try checkLiteralFits(self, ir.get(e, .right), target);
            },
            .@"<<", .@"<<%", .@">>" => try checkLiteralFits(self, ir.get(e, .left), target),
            .neg => try checkLiteralFits(self, ir.Neg.operand(e), target),
            .@"if" => {
                try checkLiteralFits(self, ir.If.then(e), target);
                try checkLiteralFits(self, ir.If.@"else"(e), target);
            },
            else => {},
        },
    }
}

/// `.name` where a `T!` is expected names no variant of `T` but a
/// member of an error set: say how to fail with it.
pub fn bareErrorName(self: *Checker, name_node: Sexp, target: TypeId, sets: []const TypeId) Error!void {
    const name = self.text(name_node);
    const a = self.ctx.arena.allocator();
    const what = if (target == self.t().void_id)
        "a `sub` returns no value"
    else if (sema.enumVariantCount(self.ctx, target) != null)
        try a.print("`.{s}` is not a variant of `{s}`", .{ name, try self.tyName(target) })
    else
        try a.print("`.{s}` is not a value of `{s}`", .{ name, try self.tyName(target) });
    try self.errAt(name_node, "{s}; to fail, name the error set: {s}", .{ what, try errorChoices(self, sets, name, true) });
}

pub fn setSpelling(self: *Checker, set: TypeId) Error!Checker.SetSpelling {
    const a = self.ctx.arena.allocator();
    const decl = sema.nominalDecl(self.ctx, set) orelse return .{ .text = try self.tyName(set) };
    const sname = decl.symbol().name;
    const module = decl.module_id orelse return .{ .text = sname };
    for (self.ctx.imports) |imp| if (imp.module_id == module) return .{ .text = try a.print("{s}.{s}", .{ imp.local_name, sname }) };
    return .{ .text = try a.print("{s}.{s}", .{ decl.ctx.name, sname }), .import = decl.ctx.name };
}

/// `A.x`, `B.x`, or `C.x`: each of `sets` (with its member `name`,
/// when `members`), saying which modules must be imported to write it.
pub fn errorChoices(self: *Checker, sets: []const TypeId, name: []const u8, members: bool) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    const conj = if (members) "or" else "and";
    for (sets, 0..) |set, i| {
        if (i + 1 < sets.len) {
            if (i > 0) try out.appendSlice(a, ", ");
        } else if (i > 0) try out.print(a, "{s} {s} ", .{ if (sets.len > 2) "," else "", conj });
        const sp = try setSpelling(self, set);
        if (members) try out.print(a, "`{s}.{s}`", .{ sp.text, name }) else try out.print(a, "`{s}`", .{sp.text});
        if (members) if (sp.import) |m| try out.print(a, " (import `{s}` to name it)", .{m});
    }
    return out.items;
}

/// `.name` where any error is expected: the member of the one error
/// set it may mean (`sema.errorSetsWith`). Its type is that set's, or
/// poison when no set or several have it.
pub fn resolveErrorName(self: *Checker, name_node: Sexp) Error!TypeId {
    const name = self.text(name_node);
    const sets = try sema.errorSetsWith(self.ctx, name);
    if (sets.len == 1) return sets[0];
    if (sets.len == 0) {
        try self.errAt(name_node, "no error set has a member `{s}`", .{name});
    } else {
        try self.errAt(name_node, "error sets {s} {s} have a member `{s}`; name the set: {s}", .{ try errorChoices(self, sets, name, false), if (sets.len == 2) "both" else "all", name, try errorChoices(self, sets, name, true) });
    }
    return self.t().invalid_id;
}

/// How many values a `match` on `ty` must cover, when they are named:
/// an enum's variants, a set's members, or every member of every set
/// a union joins.
pub fn variantTotal(self: *Checker, ty: TypeId) Error!?usize {
    if (!sema.isErrorUnion(self.ctx, ty)) return sema.enumVariantCount(self.ctx, ty);
    var leaves: std.ArrayList(sema.SetKey) = .empty;
    try sema.errorSetLeaves(self.ctx, ty, &leaves, self.ctx.arena.allocator());
    var n: usize = 0;
    for (leaves.items) |leaf| for (sema.setMembers(leaf)) |f| {
        if (f.is_variant) n += 1;
    };
    return n;
}

/// The set of union `union_ty` whose member `.name` is: the one set it
/// joins that has the member, or `invalid` once none or several do.
pub fn unionMemberSet(self: *Checker, union_ty: TypeId, name: Sexp) Error!TypeId {
    var leaves: std.ArrayList(sema.SetKey) = .empty;
    try sema.errorSetLeaves(self.ctx, union_ty, &leaves, self.ctx.arena.allocator());
    const wanted = self.text(name);
    var found: ?sema.SetKey = null;
    for (leaves.items) |leaf| for (sema.setMembers(leaf)) |f| {
        if (!f.is_variant or !std.mem.eql(u8, f.name, wanted)) continue;
        if (found) |first| {
            const a_ty = try first.typeIn(self.ctx);
            const b_ty = try leaf.typeIn(self.ctx);
            try self.errAt(name, "`.{s}` is a member of both `{s}` and `{s}`, which `{s}` joins: name its set, `{s}.{s}`", .{ wanted, try self.tyName(a_ty), try self.tyName(b_ty), try self.tyName(union_ty), try self.tyName(a_ty), wanted });
            return self.t().invalid_id;
        }
        found = leaf;
    };
    const leaf = found orelse {
        try self.errAt(name, "no set `{s}` joins has a member `.{s}`", .{ try self.tyName(union_ty), wanted });
        return self.t().invalid_id;
    };
    return leaf.typeIn(self.ctx);
}

/// `g: E =>`: an error of set `E`, a set or a union, bound as `g`,
/// where the subject may be of several sets: `error`, or a union that
/// holds `E`. It covers every member of `E`.
pub fn checkSetPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage) Error!void {
    const name = ir.SetPattern.name(pattern);
    const sym = self.ctx.symbolOf(name);
    var r = self.resolver();
    const set = try r.resolveType(ir.SetPattern.set(pattern));
    const subject = sema.unwrapViews(self.ctx, scrutinee);
    const bound = blk: {
        if (self.isPoison(set) or self.isPoison(subject)) break :blk self.t().invalid_id;
        if (!sema.isErrorSet(self.ctx, set)) {
            try self.errAt(ir.SetPattern.set(pattern), "`{s}` is not an error set: `{s}: E =>` names a set declared with `error`", .{ try self.tyName(set), self.text(name) });
            break :blk self.t().invalid_id;
        }
        if (subject != self.t().any_error_id and !sema.isErrorUnion(self.ctx, subject)) {
            try self.errAt(pattern, "`{s}: {s} =>` narrows an error that may be of several sets, and the subject is `{s}`", .{ self.text(name), try self.tyName(set), try self.tyName(scrutinee) });
            break :blk self.t().invalid_id;
        }
        if (!sema.errorSubset(self.ctx, set, subject)) {
            try self.errAt(ir.SetPattern.set(pattern), "`{s}` is not in `{s}`, the union the subject may be", .{ try self.tyName(set), try self.tyName(subject) });
            break :blk self.t().invalid_id;
        }
        break :blk set;
    };
    if (sym) |id| (try self.ctx.symbolMut(id)).ty = bound;
    try self.ctx.recordType(name, bound);
    try self.ctx.recordType(pattern, bound);
    if (self.isPoison(bound)) {
        cov.rejected = true;
        return;
    }
    var leaves: std.ArrayList(sema.SetKey) = .empty;
    try sema.errorSetLeaves(self.ctx, set, &leaves, self.ctx.arena.allocator());
    // The members no arm before covers: the arm's own, which its prong
    // lists, so no member is listed twice.
    var fresh: std.ArrayList(sema.SetMember) = .empty;
    for (leaves.items) |leaf| {
        const leaf_ty = try leaf.typeIn(self.ctx);
        for (sema.setMembers(leaf)) |f| {
            if (!f.is_variant) continue;
            const key = try errorArmKey(self, subject, leaf_ty, f.name);
            if (cov.variantAt(key) != null) continue;
            try cov.variants.put(self.ctx.allocator, key, self.startOf(pattern));
            try fresh.append(self.ctx.arena.allocator(), .{ .set = leaf_ty, .name = f.name });
        }
    }
    if (fresh.items.len == 0) try self.errAt(pattern, "this arm never runs: the arms before it cover every member of `{s}`", .{try self.tyName(set)});
    try self.ctx.record(.set_pattern_members, pattern, fresh.items);
}

/// What a pattern for member `name` of error set `set` covers: the
/// member alone where the subject is of that set, the set and the
/// member where it may be any error.
pub fn errorArmKey(self: *Checker, subject: TypeId, set: TypeId, name: []const u8) Error![]const u8 {
    if (subject != self.t().any_error_id and !sema.isErrorUnion(self.ctx, subject)) return name;
    return self.ctx.arena.allocator().print("{s}.{s}", .{ try self.tyName(set), name });
}

/// `E.name` or `m.E.name` as a pattern: a member of error set `E`,
/// where the subject is of that set or is any error.
pub fn checkQualifiedPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage) Error!void {
    const saved = self.expect.member_pattern;
    self.expect.member_pattern = pattern;
    const ty = try PatternCheck.synthExpr(self, pattern);
    self.expect.member_pattern = saved;
    const subject = sema.unwrapViews(self.ctx, scrutinee);
    const obj = ir.Member.object(pattern);
    const shown = try ViewCheck.plainText(self, pattern);
    const name = self.text(ir.Member.name(pattern));
    if (self.isPoison(ty) or self.isPoison(subject)) {
        cov.rejected = true;
        return;
    }
    if (!self.ctx.isErrorMember(pattern)) if (sema.patternConst(self.ctx, pattern)) |c| return checkConstPattern(self, pattern, ty, scrutinee, cov, c);
    if (!self.ctx.isErrorMember(pattern)) {
        const module = if (obj == .src) if (self.ctx.symbolOf(obj)) |id| self.ctx.symbols.items[id].kind == .module else false else false;
        const value = module or self.ctx.typeOf(obj) != null;
        // `Color.red` meant `.red`, which the arm covers; what any
        // other rejected pattern meant is unknown.
        if (!value and ty == subject and (try sema.lookupVariant(self.ctx, ty, name)) != null) {
            try PatternCheck.recordCovered(self, name, null, self.startOf(pattern), cov);
            return self.errAt(pattern, "a pattern names a variant without its enum: `.{s}`; only an error's pattern names its set", .{name});
        }
        cov.rejected = true;
        if (module) return self.errAt(pattern, "`{s}` is a constant, which a pattern cannot name; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
        if (value) return self.errAt(pattern, "`{s}` is a value, which a pattern cannot name; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
        return self.errAt(pattern, "`{s}` is not a pattern; a qualified pattern names a member of an error set: `E.name`", .{shown});
    }
    if (sema.isErrorUnion(self.ctx, subject)) {
        if (!sema.errorSubset(self.ctx, ty, subject)) {
            cov.rejected = true;
            return self.errAt(pattern, "`{s}` is not in `{s}`, the union the subject may be", .{ shown, try self.tyName(subject) });
        }
    } else if (subject != self.t().any_error_id and subject != ty) {
        cov.rejected = true;
        return self.errAt(pattern, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(subject), try self.tyName(ty) });
    }
    try PatternCheck.recordCovered(self, try errorArmKey(self, subject, ty, name), null, self.startOf(pattern), cov);
}

/// A module constant's name as a pattern (`ESC`, `lib.ESC`), of type
/// `ty`: an integer, a Bool, or a variant named alone, whose value Rig
/// knows, of the subject's type. It compares with that value and
/// covers it as the literal would. A constant of an error set is
/// compared in a guard.
pub fn checkConstPattern(self: *Checker, pattern: Sexp, ty: TypeId, scrutinee: TypeId, cov: *Checker.MatchCoverage, c: sema.PatternConst) Error!void {
    const subject = sema.unwrapViews(self.ctx, scrutinee);
    if (self.isPoison(ty) or self.isPoison(subject)) {
        cov.rejected = true;
        return;
    }
    const shown = try ViewCheck.plainText(self, pattern);
    const pos = self.startOf(pattern);
    const value = try constPatternValue(self, pattern, ty, subject, shown, c) orelse {
        cov.rejected = true;
        return;
    };
    switch (value) {
        .int => |v| try PatternCheck.coverInts(self, cov, v, v, pos),
        .boolean => |b| {
            const i: usize = @intFromBool(b);
            if (cov.hasBool(i)) try self.errAt(pattern, "this pattern overlaps an earlier arm", .{});
            cov.bools[i] = true;
        },
        .variant => |name| try PatternCheck.recordCovered(self, name, null, pos, cov),
    }
}

/// The value of constant pattern `pattern`, or null once its
/// rejection is reported.
pub fn constPatternValue(self: *Checker, pattern: Sexp, ty: TypeId, subject: TypeId, shown: []const u8, c: sema.PatternConst) Error!?sema.ConstScalar {
    if (sema.isErrorSet(self.ctx, ty)) {
        try self.errAt(pattern, "`{s}` is a constant, which a pattern cannot name; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
        return null;
    }
    const scalar = ty == self.t().bool_id or self.ctx.types.get(ty) == .int or sema.enumVariantCount(self.ctx, ty) != null;
    if (!scalar) {
        try self.errAt(pattern, "`{s}` is a constant of type `{s}`; a pattern may name a constant that is an integer, a `Bool`, or an enum value", .{ shown, try self.tyName(ty) });
        return null;
    }
    // An integer literal subject is an `Int` (`defaultIntLiteral`).
    const want = if (subject == self.t().int_literal_id) self.t().int_id else subject;
    if (ty != want) {
        try self.errAt(pattern, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(want), try self.tyName(ty) });
        return null;
    }
    if (try self.perTarget(pattern, "a constant a pattern names")) return null;
    if (sema.constScalar(c)) |v| return v;
    try self.errAt(pattern, "the value of `{s}` is not known when Rig checks the program, so a pattern cannot name it; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
    return null;
}

pub fn checkEnumLit(self: *Checker, name_node: Sexp, expected: TypeId) Error!void {
    const name = self.text(name_node);
    const pos = srcPos(name_node, 0);
    if (self.isPoison(expected)) return;
    if (try sema.lookupVariant(self.ctx, expected, name)) |v| {
        if (v.payload.len > 0) {
            try self.err(pos, "variant `{s}` carries a payload; construct it with `.{s}(...)`", .{ name, name });
        }
        return;
    }
    try PatternCheck.reportMissingVariant(self, expected, name, pos);
}

/// `.variant(payload...)` against an expected enum.
/// `(call (enum_lit name) args...)`.
pub fn checkPayloadVariant(self: *Checker, call: Sexp, expected: TypeId) Error!void {
    const name_node = ir.EnumLit.name(ir.Call.callee(call));
    const name = self.text(name_node);
    const pos = name_node.src.pos;
    const args = ir.Call.args(call);
    const resolved = (try sema.lookupVariant(self.ctx, expected, name)) orelse {
        try PatternCheck.reportMissingVariant(self, expected, name, pos);
        try CallCheck.synthArgs(self, args);
        return;
    };
    const owner = resolved.owner_name;
    if (resolved.payload.len == 0) {
        if (args.len > 0) try self.err(pos, "variant `{s}` of enum `{s}` takes no payload", .{ name, owner });
        try CallCheck.synthArgs(self, args);
        return;
    }
    const decl_pos = if (resolved.nominal_sym == sema.symbol_invalid and resolved.module == null) sema.builtin_decl_pos else resolved.field.decl_pos;
    const module_id = resolved.module orelse 0;
    try CallCheck.checkFieldArgs(self, args, resolved.payload, .{ .owner = name, .decl_pos = decl_pos, .module_id = module_id, .pos = pos, .kind = .variant, .call = call });
}

/// `List()` / `List(capacity: n)` / `List(a)`, making `list_ty`.
pub fn checkListConstruction(self: *Checker, call: Sexp, list_ty: TypeId) Error!void {
    var seen: ?u32 = null;
    const args = ir.Call.args(call);
    if (args.len == 1 and !args[0].isKind(.kwarg)) {
        _ = try listFromElems(self, args[0], CompatCheck.listElementType(self.ctx, list_ty));
        return;
    }
    for (args) |a| {
        if (!a.isKind(.kwarg)) {
            try self.errAt(a, "`List` constructor takes one positional argument, an array or slice to copy, `List([1, 2, 3])`; or none, `List()`, or `List(capacity: N)`", .{});
            _ = try PatternCheck.synthExpr(self, a);
            continue;
        }
        const name = self.text(ir.Kwarg.name(a));
        const pos = ir.Kwarg.name(a).src.pos;
        if (!std.mem.eql(u8, name, "capacity")) {
            try self.err(pos, "`List` constructor accepts only `capacity` as a kwarg; got `{s}`", .{name});
            _ = try PatternCheck.synthExpr(self, ir.Kwarg.value(a));
            continue;
        }
        if (seen) |first| {
            try self.err(pos, "duplicate `capacity` kwarg in `List` constructor", .{});
            try self.note(first, "first `capacity` here", .{});
        }
        seen = pos;
        try ViewCheck.checkExpr(self, ir.Kwarg.value(a), self.t().int_id);
    }
}

/// `List(a)`: a new List holding a copy of each element of `a`, an
/// array or a slice, as `String(s)` copies text; the call shows the
/// allocation. Its element type is `a`'s, or `want` where the List's
/// type is given. The elements copy and carry no loan, so the List
/// owns all it holds.
pub fn listFromElems(self: *Checker, arg: Sexp, want: ?TypeId) Error!TypeId {
    // An array literal takes the element type the List is given; a
    // temporary array is viewed as the slice it is copied from.
    const ty = if (want != null and arg.isKind(.array)) blk: {
        const saved = self.expect.viewed_temp;
        defer self.expect.viewed_temp = saved;
        self.expect.viewed_temp = arg;
        try ViewCheck.checkExpr(self, arg, try self.ctx.intern(.{ .slice = .{ .elem = want.? } }));
        break :blk self.ctx.typeOf(arg) orelse return self.t().invalid_id;
    } else try PatternCheck.synthExpr(self, arg);
    if (self.isPoison(ty)) return self.t().invalid_id;
    const elem: TypeId = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
        .array => |a| a.elem,
        .slice => |sl| sl.elem,
        else => {
            try self.errAt(arg, "`List(...)` copies the elements of an array or a slice, `List([1, 2, 3])`; got `{s}`", .{try self.tyName(ty)});
            return self.t().invalid_id;
        },
    };
    if (want) |w| if (elem != w and !self.isPoison(elem)) {
        try self.errAt(arg, "type mismatch: expected `[]{s}`, got `{s}`", .{ try self.tyName(w), try self.tyName(ty) });
        return self.t().invalid_id;
    };
    // A view of an array is read as the array it views (`List(?a)`):
    // a write view written here is reported, as it only reads.
    switch (self.ctx.types.get(ty)) {
        .read_view, .write_view => if (self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .array) try ViewCheck.readOf(self, arg, ty, .{ .value = sema.unwrapViews(self.ctx, ty) }),
        else => {},
    }
    if (!sema.holdsNoLoanButText(self.ctx, elem) or sema.mayHoldView(self.ctx, elem)) {
        // The form that works: an empty List, then a push of each
        // element, made in the call where the literal makes them.
        const name = try self.tyName(elem);
        const why = if (sema.mayHoldView(self.ctx, elem)) "holds a view" else ViewCheck.movesBecause(self, elem);
        if (arg.isKind(.array) and sema.isObject(self.ctx, elem)) {
            try self.errAt(arg, "`List(...)` copies plain data, and `{s}` {s}: make the List with `List[{s}]()`, then push each element, `!xs.push({s}(...))`", .{ name, why, name, name });
        } else if (sema.readViewField(self.ctx, elem) or self.ctx.types.get(elem) == .write_view) {
            // A List of views takes each as it is; `+x` would own.
            try self.errAt(arg, "`List(...)` copies plain data, and `{s}` {s}: make the List with `List[{s}]()`, then push each element, `!xs.push(x)`", .{ name, why, name });
        } else {
            try self.errAt(arg, "`List(...)` copies plain data, and `{s}` {s}: make the List with `List[{s}]()`, then push a copy of each element, `!xs.push(+x)`", .{ name, why, name });
        }
        return self.t().invalid_id;
    }
    return want orelse try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.list, .args = try self.ctx.dupeIds(&.{elem}) } });
}

/// Best-effort common type of two branches; reports on mismatch.
pub fn unify(self: *Checker, a: TypeId, b: TypeId, pos: u32) Error!?TypeId {
    if (a == b) return a;
    if (self.isPoison(a) or a == self.t().noreturn_id) return b;
    if (self.isPoison(b) or b == self.t().noreturn_id) return a;
    if (a == self.t().none_id and self.ctx.types.get(b) == .optional) return b;
    if (b == self.t().none_id and self.ctx.types.get(a) == .optional) return a;
    // Integer and float literals meet as a float literal.
    if ((a == self.t().int_literal_id and b == self.t().float_literal_id) or (b == self.t().int_literal_id and a == self.t().float_literal_id)) return self.t().float_literal_id;
    if (CompatCheck.compatible(self.ctx, a, b)) return b;
    if (CompatCheck.compatible(self.ctx, b, a)) return a;
    // A viewed Copy value meets a value as the value.
    const va = CompatCheck.readValue(self.ctx, a);
    const vb = CompatCheck.readValue(self.ctx, b);
    if (va != a or vb != b) return unify(self, va, vb, pos);
    try self.err(pos, "incompatible types `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
    return null;
}

/// `$sizeOf(I64)` as Rig writes it, `$size(I64)`: each of Zig's
/// names for a type query in `call` becomes Rig's.
pub fn rigSpelling(self: *Checker, call: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    var i: usize = 0;
    outer: while (i < call.len) {
        if (call[i] == '$') {
            for ([_][2][]const u8{ .{ "sizeOf", "size" }, .{ "alignOf", "align" }, .{ "typeName", "name" }, .{ "TypeOf", "type" } }) |pair| {
                const after = i + 1 + pair[0].len;
                if (std.mem.startsWith(u8, call[i + 1 ..], pair[0]) and (after == call.len or !(std.ascii.isAlphanumeric(call[after]) or call[after] == '_'))) {
                    try out.print(a, "${s}", .{pair[1]});
                    i = after;
                    continue :outer;
                }
            }
        }
        try out.append(a, call[i]);
        i += 1;
    }
    return out.items;
}

/// Zig's name for a type query outside `raw`: the fix-it writes the
/// call `node` with Rig's names.
pub fn zigQueryName(self: *Checker, node: Sexp, written: []const u8, rig_name: []const u8) Error!void {
    // From the name on: `$ sizeOf(I64)` is fixed as `$size(I64)`.
    const args = diag.textBetween(self.ctx.source, self.ctx.span(ir.Builtin.name(node)).end, self.ctx.span(node).end);
    const short = args.len <= 60 and std.mem.findScalar(u8, args, '\n') == null;
    const fix = if (short) try self.ctx.arena.allocator().print("${s}{s}", .{ rig_name, try rigSpelling(self, args) }) else try self.ctx.arena.allocator().print("${s}(...)", .{rig_name});
    try self.errAt(node, "write `{s}`: Rig's builtin is `${s}`; `${s}`, Zig's name for it, works only inside `raw`", .{ fix, rig_name, written });
}

pub fn synthBuiltin(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
    const name_node = ir.Builtin.name(node);
    const name = self.text(name_node);
    const pos = name_node.src.pos;
    const args = ir.Builtin.args(node);
    const ty: TypeId = blk: {
        const builtin = std.meta.stringToEnum(Checker.Builtin, name) orelse {
            if (std.mem.eql(u8, name, "enumFromInt")) {
                try self.err(pos, "builtin `$enumFromInt` is not supported; an integer becomes a plain enum with `$fromBackingInt`", .{});
            } else if (std.mem.eql(u8, name, "intFromFloat")) {
                try self.err(pos, "builtin `$intFromFloat` is not supported; a float becomes an integer with `$trunc`", .{});
            } else {
                try self.err(pos, "builtin `${s}` is not supported; the builtins are `$size`, `$align`, `$type`, `$name`, `$plain`, `$variants`, `$embed`, and, inside `raw`, `$bitCast`, `$intCast`, `$floatCast`, `$truncate`, `$trunc`, `$floatFromInt`, `$fromBackingInt`", .{name});
            }
            try CallCheck.synthArgs(self, args);
            break :blk self.t().invalid_id;
        };
        if (builtin == .variants) break :blk try variantsOf(self, args, pos);
        if (builtin == .plain) break :blk try plainTest(self, node, args, pos);
        if (builtin == .embed) break :blk try embedOf(self, node, args, pos);
        const query = builtin.query();
        if (self.raw_depth == 0 and !builtin.isSafe()) {
            if (query) |q| {
                try zigQueryName(self, node, name, @tagName(q));
            } else {
                try self.err(pos, "builtin `${s}` is not in the safe whitelist; wrap it in a `raw` block. Safe builtins: `$size`, `$align`, `$type`, `$name`, `$plain`, `$variants`, `$embed`", .{name});
            }
        }
        if (query) |q| switch (q) {
            .type => {
                try self.err(pos, "`${s}` is only allowed as the argument of `$size`, `$align`, `$name`, or `$plain`", .{name});
                try CallCheck.synthArgs(self, args);
                break :blk self.t().invalid_id;
            },
            else => {
                if (!(try builtinTypeArg(self, name, args, pos))) break :blk self.t().invalid_id;
                break :blk if (q == .name) self.t().string_view_id else self.t().int_literal_id;
            },
        };
        if (args.len != 1) {
            try self.err(pos, "`${s}` takes one argument", .{name});
            try CallCheck.synthArgs(self, args);
            break :blk self.t().invalid_id;
        }
        const operand = try ViewCheck.synthValue(self, args[0]);
        const target = expected orelse {
            try self.err(pos, "`${s}` needs a known result type; bind it to an annotated name (`y: T = ${s}(x)`)", .{ name, name });
            break :blk self.t().invalid_id;
        };
        if (!self.isPoison(operand) and !self.isPoison(target)) {
            const to = ViewCheck.liftTarget(self, target);
            if (castProblem(self, builtin, operand, to)) |why| {
                try self.err(pos, "`${s}` cannot turn `{s}` into `{s}`: {s}", .{ name, try self.tyName(operand), try self.tyName(target), why });
                break :blk self.t().invalid_id;
            }
            // Zig converts a constant operand when it compiles, so the
            // value must convert.
            switch (builtin) {
                .intCast, .floatFromInt => try checkLiteralFits(self, args[0], to),
                .trunc => try CallCheck.checkFloatFits(self, args[0], to),
                .fromBackingInt => if (ExprCheck.constInt(self, args[0]) != null) {
                    try self.errAt(args[0], "`$fromBackingInt` of a constant: name the variant instead (`.name`)", .{});
                },
                else => {},
            }
        }
        break :blk target;
    };
    if (expected) |e| if (!self.isPoison(ty) and !CompatCheck.compatible(self.ctx, ty, e)) try ViewCheck.mismatch(self, node, e, ty);
    return ty;
}

/// `$plain(T)`: whether `T` is plain data (`sema.isPlain`), a `Bool`
/// each instance answers when it compiles (`sema.plain_tests`); one
/// of a type that holds type parameters, from the bits its generic
/// takes. One of a type parameter or an associated type
/// that is an operand of the `and` chain of the condition being
/// checked narrows what runs once it has held (`plain_cond`).
pub fn plainTest(self: *Checker, node: Sexp, args: []const Sexp, pos: u32) Error!TypeId {
    if (!(try builtinTypeArg(self, "plain", args, pos))) return self.t().invalid_id;
    const a = args[0];
    const of = if (a.isKind(.builtin) and ir.Builtin.args(a).len >= 1) ir.Builtin.args(a)[0] else a;
    const ty = self.ctx.typeOf(of) orelse return self.t().bool_id;
    if (self.isPoison(ty)) return self.t().bool_id;
    try self.ctx.plain_tests.append(self.ctx.allocator, ty);
    const param = switch (self.ctx.types.get(ty)) {
        .type_var => |sym| sym,
        else => return self.t().bool_id,
    };
    const cond = self.expect.plain_cond orelse return self.t().bool_id;
    const operand = for (cond.operands) |o| {
        if (CompatCheck.sameNode(o, node)) break true;
    } else false;
    if (!operand) return self.t().bool_id;
    const regions = &self.ctx.plain_regions;
    const after = self.ctx.span(node).end;
    if (after < cond.end) try regions.append(self.ctx.allocator, .{ .start = after, .end = cond.end, .param = self.ctx.localSym(param) });
    for (cond.guarded) |g| if (g.start < g.end) try regions.append(self.ctx.allocator, .{ .start = g.start, .end = g.end, .param = self.ctx.localSym(param) });
    return self.t().bool_id;
}

/// The condition `cond` whose `$plain(T)` operands narrow the code
/// `guarded` holds, as `plain_cond` (`plainTest`).
pub fn plainCondOf(self: *Checker, cond: Sexp, guarded: []const Sexp) Error!Checker.PlainCond {
    const a = self.ctx.arena.allocator();
    const Ops = struct {
        list: std.ArrayList(Sexp) = .empty,
        a: std.mem.Allocator,
        pub fn part(v: *@This(), p: Sexp) Error!void {
            try rig.eachGuardOperand(p, v, @This().operand);
        }
        fn operand(v: *@This(), o: Sexp) Error!void {
            try v.list.append(v.a, o);
        }
    };
    var ops: Ops = .{ .a = a };
    try rig.eachGuardPart(cond, &ops);
    const spans = try a.alloc(diag.Span, guarded.len);
    for (guarded, spans) |g, *sp| sp.* = if (g == .nil) .{ .start = 0, .end = 0 } else self.ctx.span(g);
    return .{ .operands = ops.list.items, .end = self.ctx.span(cond).end, .guarded = spans };
}

/// `$embed("path")`: the bytes of the file `path` names, from the
/// directory of the file that names it, as a `Static`. The path is a
/// string literal, so the file is known where the call is written;
/// the module graph finds it once the module is checked
/// (`ModuleGraph.checkEmbeds`).
pub fn embedOf(self: *Checker, node: Sexp, args: []const Sexp, pos: u32) Error!TypeId {
    if (args.len != 1) {
        try self.err(pos, "`$embed` takes one argument, the file's path as a string literal: `$embed(\"data.bin\")`", .{});
        try CallCheck.synthArgs(self, args);
        return self.t().invalid_id;
    }
    const arg = args[0];
    const lit = if (arg == .src) self.text(arg) else "";
    if (lit.len < 2 or (lit[0] != '"' and lit[0] != '\'')) {
        _ = try PatternCheck.synthExpr(self, arg);
        try self.errAt(arg, "`$embed` takes the file's path as a string literal, so the file is known when the program is compiled: `$embed(\"data.bin\")`", .{});
        return self.t().invalid_id;
    }
    _ = try PatternCheck.synthExpr(self, arg);
    const path = CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), lit) orelse return self.t().invalid_id;
    try self.ctx.recordEmbed(node, arg, path);
    return self.t().static_id;
}

/// `$variants(T)`: every variant of plain enum `T`, in declaration
/// order, a `[N]T`.
pub fn variantsOf(self: *Checker, args: []const Sexp, pos: u32) Error!TypeId {
    if (!(try builtinTypeArg(self, "variants", args, pos))) return self.t().invalid_id;
    const ty = self.ctx.typeOf(args[0]) orelse return self.t().invalid_id;
    if (self.isPoison(ty)) return ty;
    const direct = switch (self.ctx.types.get(ty)) {
        .nominal => true,
        else => false,
    };
    if (!direct) {
        switch (self.ctx.types.get(ty)) {
            .optional, .read_view, .write_view => |inner| if (CallCheck.enumValues(self, inner) != null) {
                const what: []const u8 = switch (self.ctx.types.get(ty)) {
                    .optional => "an optional",
                    .read_view => "a read view",
                    else => "a write view",
                };
                try self.errAt(args[0], "`$variants` takes an enum type; `{s}` is {s} of one: write `$variants({s})`", .{ try self.tyName(ty), what, try self.tyName(inner) });
                return self.t().invalid_id;
            },
            else => {},
        }
        try self.errAt(args[0], "`$variants` takes an enum type; `{s}` is not one", .{try self.tyName(ty)});
        return self.t().invalid_id;
    }
    const plain = CallCheck.enumValues(self, ty) orelse {
        try self.errAt(args[0], "`$variants` takes an enum type; `{s}` is not an enum", .{try self.tyName(ty)});
        return self.t().invalid_id;
    };
    if (CallCheck.isBuiltinEnumTy(self, ty)) {
        try self.errAt(args[0], "`$variants(T)` takes a declared enum; `{s}` is a built-in enum", .{try self.tyName(ty)});
        return self.t().invalid_id;
    }
    if (!plain) {
        try self.errAt(args[0], "`$variants(T)` takes a plain enum; `{s}` has variants with payloads", .{try self.tyName(ty)});
        return self.t().invalid_id;
    }
    const decl = sema.nominalDecl(self.ctx, ty).?;
    var n: Wide = 0;
    for (decl.symbol().fields orelse &.{}) |f| {
        if (f.is_variant) n += 1;
    }
    return self.ctx.intern(.{ .array = .{ .elem = ty, .len = try sema.ctInt(self.ctx, n) } });
}

/// Why Zig would reject the cast builtin `cast` from `from` to `to`,
/// or null when it accepts it.
pub fn castProblem(self: *Checker, cast: Checker.Builtin, from: TypeId, to: TypeId) ?[]const u8 {
    const f = self.ctx.types.get(from);
    const t_ = self.ctx.types.get(to);
    const f_int = f == .int or f == .int_literal;
    const f_float = f == .float or f == .float_literal;
    switch (cast) {
        .intCast => if (!f_int or t_ != .int) return "it converts one integer type to another",
        .truncate => {
            if (!f_int or t_ != .int) return "it converts one integer type to another";
            if (f == .int) {
                if (f.int.signed != t_.int.signed) return "both must be signed, or both unsigned";
                if (CompatCheck.numericBits(t_).? > CompatCheck.numericBits(f).?) return "the result may not be wider";
            }
        },
        .floatCast => if (!f_float or t_ != .float) return "it converts one float type to another",
        .trunc => if (!f_float or t_ != .int) return "it converts a float to an integer",
        .floatFromInt => if (!f_int or t_ != .float) return "it converts an integer to a float",
        .fromBackingInt => if (!f_int or !sema.isPlainEnum(self.ctx, to)) return "it converts an integer to a plain enum",
        .bitCast => {
            const fb = CompatCheck.numericBits(f) orelse return "it reinterprets a number of the same size";
            const tb = CompatCheck.numericBits(t_) orelse return "it reinterprets a number of the same size";
            if (fb != tb) return "both must have the same size";
        },
        .size, .@"align", .name, .type, .sizeOf, .alignOf, .typeName, .TypeOf, .variants, .plain, .embed => {},
    }
    return null;
}

/// `$size(T)` / `$size($type(x))`. A type argument, written as one is
/// in an expression (`typeArg`), is recorded with the type it names.
pub fn builtinTypeArg(self: *Checker, name: []const u8, args: []const Sexp, pos: u32) Error!bool {
    if (args.len != 1) {
        try self.err(pos, "`${s}` takes one type argument", .{name});
        return false;
    }
    const a = args[0];
    if (a.isKind(.builtin) and ir.Builtin.args(a).len >= 1) {
        const inner = self.text(ir.Builtin.name(a));
        if (std.meta.stringToEnum(Checker.Builtin, inner)) |b| if (b.query() == .type) {
            // Under a query spelled Zig's way, its fix-it covers this one.
            const outer_rig = std.meta.stringToEnum(Checker.Builtin, name).?.isSafe();
            if (b != .type and self.raw_depth == 0 and outer_rig) try zigQueryName(self, a, inner, "type");
            const operand = ir.Builtin.args(a)[0];
            const of = try PatternCheck.synthExpr(self, operand);
            if (std.mem.eql(u8, name, "variants")) {
                try self.err(ir.Builtin.name(a).src.pos, "`${s}` is only allowed as the argument of `$size`, `$align`, `$name`, or `$plain`", .{inner});
                return false;
            }
            // Zig's `@TypeOf` never evaluates its operand, so the
            // operand may hold nothing that would run.
            if (StmtCheck.effectIn(operand, true)) |found| {
                try self.errAt(found, "`${s}` does not run its operand, so {s} `{s}` never happens; write the operand without `<`, `!`, or a call", .{ inner, StmtCheck.effectName(found), CallCheck.sourceText(self, found) });
                return false;
            }
            try requireNamed(self, name, of, a);
            return true;
        };
    }
    // Written as in an expression: `List[Int]`, `?Point`, `Int?`.
    const ty = try CallCheck.typeArg(self, a);
    if (self.isPoison(ty)) return false;
    try self.ctx.recordType(a, ty);
    try requireNamed(self, name, ty, a);
    // A vector's size and alignment are the target's, so Rig gives
    // neither, nor those of a type that holds one inline.
    if (!std.mem.eql(u8, name, "name") and !std.mem.eql(u8, name, "plain")) {
        if (sema.holdsVector(self.ctx, ty)) {
            try self.err(pos, "`${s}` takes no type that holds a vector: `{s}` holds a `Simd`, whose size and alignment differ from target to target", .{ name, try self.tyName(ty) });
            return false;
        }
        var params: std.ArrayList(SymbolId) = .empty;
        try sema.heldTypeVars(self.ctx, ty, &params, self.ctx.arena.allocator());
        for (params.items) |param| try ExprCheck.require(self, param, .sized, self.startOf(a), name);
    }
    return true;
}

/// `$name` of a type that holds type parameters names each one's
/// instance as the program runs (`rig.typeName`), from its Zig type:
/// each instance must hold no view it could not tell apart
/// (`Requirement.named`).
pub fn requireNamed(self: *Checker, builtin: []const u8, ty: TypeId, at: Sexp) Error!void {
    // Zig's `$typeName`, inside `raw`, names the Zig type.
    if (!std.mem.eql(u8, builtin, "name")) return;
    var params: std.ArrayList(SymbolId) = .empty;
    try sema.reachedTypeVars(self.ctx, ty, &params, self.ctx.arena.allocator());
    for (params.items) |param| try ExprCheck.require(self, param, .named, self.startOf(at), "$name");
}
