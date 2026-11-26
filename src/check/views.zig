//! Typecheck's views: read and write views and the loans they make,
//! temporaries, erasure, kept views, view bases, and checking a value
//! against an expected type.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Wide = sema.Wide;
const resolve = @import("../resolve.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const SymbolRef = sema.SymbolRef;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const SelfMode = sema.SelfMode;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const ApiCheck = @import("apis.zig");
const CompatCheck = @import("compat.zig");
const GenericCheck = @import("generics.zig");
const BuiltinCheck = @import("builtins.zig");
const CallCheck = @import("calls.zig");
const ClosureCheck = @import("closures.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const StmtCheck = @import("stmt.zig");

/// What `!x`, `e`, puts on `x`, given the view it makes (Core §4): a
/// read loan when that is a write view of a value that changes by a
/// marked call (`sema.loanOfView`), a write loan otherwise. A
/// method's self reached through a handle is the value the handle
/// holds, which the method is called on; a handle viewed where a view
/// of its value goes is decided again there (`viewByRows`).
pub fn recordLoan(self: *Checker, e: Sexp, view: TypeId) Error!void {
    var viewed = switch (self.ctx.types.get(view)) {
        .write_view => |base| base,
        else => return self.ctx.record(.loans, e, .write),
    };
    if (CompatCheck.sameNode(e, self.expect.self_obj)) switch (self.ctx.types.get(viewed)) {
        .shared => |inner| viewed = inner,
        else => {},
    };
    try self.ctx.record(.loans, e, sema.loanOfView(self.ctx, viewed));
}

pub fn makeViewOf(self: *Checker, e: Sexp, kind: Checker.ViewKind) Error!TypeId {
    const operand = ir.get(e, .operand);
    try recordUse(self, operand, .view);
    const saved_in_place = self.expect.in_place;
    defer self.expect.in_place = saved_in_place;
    self.expect.in_place = operand;
    if (rig.isRangeIndex(operand)) {
        return viewSlice(self, operand, kind);
    }
    const saved_use = self.expect.index_use;
    defer self.expect.index_use = saved_use;
    if (operand.isKind(.index)) self.expect.index_use = .{ .at = operand, .form = if (kind == .write) .write_view else .read };
    const saved_outer = self.expect.outer_write;
    defer self.expect.outer_write = saved_outer;
    if (kind == .write and operand.isKind(.call)) self.expect.outer_write = operand;
    // A viewed temporary lives until its statement ends, which drops
    // it; the ownership checker keeps a view of it from outliving
    // the statement.
    const inner = if (!hands(self, operand).hasStorage())
        try PatternCheck.synthExpr(self, operand)
    else
        try synthOperand(self, operand);
    if (self.isPoison(inner)) return inner;
    if (try StdFormCheck.rejectLane(self, operand, if (kind == .write) .write_viewed else .read_viewed)) return self.t().invalid_id;
    // A branch is a value, never a place: viewed only where it is made.
    if (!try viewsBranch(self, operand, .nil, kind)) return self.t().invalid_id;
    // `?!x` only reads what `!x` views.
    if (kind == .read and try writeViewRead(self, operand, inner, .read_view_of_write)) return self.t().invalid_id;
    // `e.text` is a name the enum's type holds, no part of `e`: there
    // is nothing of `e` to view.
    if (kind == .read and self.ctx.isEnumText(operand)) {
        try self.errAt(e, "`{s}` is a variant's name, a `Static`, not a part of the value to view; pass it as it is: `{s}`", .{ CallCheck.sourceText(self, operand), CallCheck.sourceText(self, operand) });
        return self.t().invalid_id;
    }
    const place = StmtCheck.placeOf(self, operand);
    if (place.cell_list_elem != null) {
        try self.errAt(operand, "cannot make a view of an element of a Cell's List: the cell may change while the view lives; copy the element out with `c[i]`", .{});
        return self.t().invalid_id;
    }
    // `?f` of a stack closure passes it as a callable view.
    if (closureBinding(self, operand)) {
        if (kind == .read) return sema.callableOfFn(self.ctx, inner);
        try self.errAt(e, "a call never changes what a closure captures, so a closure is passed as a read view: write `?{s}`", .{CallCheck.sourceText(self, operand)});
        return self.t().invalid_id;
    }
    // Anywhere but where a `!Bool` is expected, `!flag` is read as
    // a `Bool`: the habit of `!` as negation.
    if (kind == .write and CompatCheck.readValue(self.ctx, inner) == self.t().bool_id and !CompatCheck.sameNode(e, self.expect.viewed_write)) {
        try self.errAt(e, "`!` makes a write view; use `not` for negation (a `Bool` gets a write view only where a `!Bool` is expected: `f(!flag)`)", .{});
        return self.t().invalid_id;
    }
    // A constant lives for the whole program and never changes.
    if (kind == .write and try isConstant(self, operand)) {
        try self.errAt(operand, "cannot change constant `{s}`: it lives for the whole program and never changes; bind its value to a name first", .{CallCheck.sourceText(self, operand)});
        return self.t().invalid_id;
    }
    // `![]T` is a writable slice, which a read-only `[]T` cannot give.
    if (kind == .write and self.ctx.types.get(inner) == .slice) {
        try self.errAt(operand, "cannot make a write view of a `{s}`: its elements are read-only; take a writable slice of the array or List it views with `!xs[a..b]`", .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    if (kind == .write and inner == self.t().string_view_id) {
        try self.errAt(operand, "cannot make a write view of `{s}`: it holds a read view of text, `?String`, which is pointed at other text by assigning to it; to change text in place, hold a `String`", .{CallCheck.sourceText(self, operand)});
        return self.t().invalid_id;
    }
    if (kind == .write and self.ctx.types.get(inner) == .read_view) {
        const handle_hint: []const u8 = if (StmtCheck.viewsHandle(self, place)) "; take a write view, or share a handle of your own with `+h`" else "";
        try self.errAt(operand, "cannot make a write view through a read view `{s}`{s}{s}", .{ try self.tyName(inner), try PatternCheck.readMatchHint(self, place.sym), handle_hint });
        return self.t().invalid_id;
    }
    // Where only the binding may not be written, the view keeps its
    // type, so what it is passed to is checked too.
    if (kind == .write and !try StmtCheck.requireAccess(self, place, .write_viewed, operand) and (place.blocked != null or place.root == .temporary)) return self.t().invalid_id;
    if (kind == .read) try checkReadView(self, operand);
    if (kind == .write and !try checkWriteView(self, operand)) return self.t().invalid_id;
    // `!c` views the handle itself, which a callee may point elsewhere,
    // only where `c` may be written (`handleWritable`, the one fact
    // `requireAccess` decides). Anywhere else, and as a self never
    // matters, it views what the handle holds: that value's write view.
    if (kind == .write and StmtCheck.viewsHandle(self, place) and !CompatCheck.sameNode(e, self.expect.self_obj) and !try StmtCheck.handleWritable(self, place, operand)) {
        const handle = sema.unwrapViews(self.ctx, inner);
        const view = try self.ctx.intern(.{ .write_view = self.ctx.types.get(handle).shared });
        if (sema.viewAs(self.ctx, handle, .write, view)) |made| try self.ctx.recordView(e, made);
        return view;
    }
    switch (self.ctx.types.get(inner)) {
        // (A write view of a `?T` was rejected above.)
        .read_view => return inner,
        .write_view => |base| {
            if (kind == .write) return inner;
            const view = try readViewOf(self, e, base);
            // A `!{Shape}` gives its `?{Shape}`, a value of another Zig
            // type (`rig.ApiView`), by the view table's `read_only` row.
            if (sema.apiObject(self.ctx, base) != null) if (sema.viewAs(self.ctx, base, .write, view)) |made| try self.ctx.recordView(e, made);
            return view;
        },
        else => {},
    }
    return if (kind == .read) readViewOf(self, e, inner) else self.ctx.intern(.{ .write_view = inner });
}

/// The read view `?x` of a value of type `base`, made by the view
/// table's rows. The view of a `String` is its bytes, `?String`, so
/// the view records its `text` row.
pub fn readViewOf(self: *Checker, e: Sexp, base: TypeId) Error!TypeId {
    const view = try self.ctx.intern(.{ .read_view = base });
    if (base == self.t().string_id) {
        if (sema.viewAs(self.ctx, base, .read, view)) |made| try self.ctx.recordView(e, made);
    }
    return view;
}

/// The first of a branching value's `leaves` that a binding holds,
/// by a positive list of what may stand there instead: a value made
/// there, a view, a jump, or a constant (`Color.red`), which no
/// binding holds. `.nil` when there is none.
pub fn heldLeaf(self: *Checker, leaves: []const Sexp) Error!Sexp {
    for (leaves) |leaf| switch (hands(self, leaf).kind) {
        .made, .view, .jump => {},
        .place, .part_of_made, .branches, .none => if (!try isConstant(self, leaf)) return leaf,
    };
    return .nil;
}

/// Each of `leaves` as a fix writes it: viewed with `sigil` where a
/// binding may hold it (`namedLeaf`), as written elsewhere.
pub fn viewedLeaves(self: *Checker, leaves: []const Sexp, sigil: u8) Error![]const []const u8 {
    const a = self.ctx.arena.allocator();
    const withs = try a.alloc([]const u8, leaves.len);
    for (leaves, withs) |leaf, *w| w.* = switch (hands(self, leaf).kind) {
        .made, .view, .jump => CallCheck.sourceText(self, leaf),
        else => try a.print("{c}{s}", .{ sigil, CallCheck.sourceText(self, leaf) }),
    };
    return withs;
}

/// Whether a view (`?` or `!`, `kind`) of `operand` may stand, by a
/// positive list: an operand that is a branch (`a if c else b`,
/// `a ?? b`, `e catch h`, `e?`, `e!`), or a path of fields, elements,
/// and method calls from one (`?(a if c else b).e`), is viewed only
/// where every leaf (`sema.valueLeaves`) is a value made there (a
/// call's result, a literal, a constructor), a constant, a view
/// itself, or a jump.
/// A branch is a value, never a place: a view of one with a leaf a
/// place holds would view a copy of that leaf's value, a write view
/// included (Core §3, planned). Each branch is viewed instead, which
/// the error writes out in `whole` (the operand, or the slice it is
/// the object of). Decided once per branch (`branch_views`), so a view
/// that asks again, as a slice's object does, reports nothing new;
/// a verdict reached quietly is not kept. False after reporting.
pub fn viewsBranch(self: *Checker, operand: Sexp, whole: Sexp, kind: Checker.ViewKind) Error!bool {
    const viewed = viewedBranch(operand);
    if (viewed == .nil) return true;
    // A handle that changes by a marked call is viewed, not what holds
    // it: the branch is only read.
    if (kind == .write and StmtCheck.viewsPath(self, StmtCheck.placeOf(self, operand))) return true;
    if (self.branch_views.get(CompatCheck.nodeId(viewed))) |ok| return ok;
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    try sema.valueLeaves(self.ctx.allocator, viewed, &leaves);
    const place = try heldLeaf(self, leaves.items);
    // A verdict reached while diagnostics are dropped is not kept: the
    // check that keeps them decides again, and reports.
    if (self.ctx.quiet == 0) try self.branch_views.put(self.ctx.allocator, CompatCheck.nodeId(viewed), place == .nil);
    if (place == .nil) return true;
    const a = self.ctx.arena.allocator();
    const sigil: u8 = if (kind == .write) '!' else '?';
    const withs = try viewedLeaves(self, leaves.items, sigil);
    const to = if (kind == .write) "a write view" else "a view";
    // What `o?` unwraps is viewed and unwrapped in a header instead.
    const fix = if (unwrapped(self, place))
        try a.print("make a view of what it unwraps, and unwrap it in a header: `if {c}{s} as x`", .{ sigil, CallCheck.sourceText(self, place) })
    else if (whole != .nil or CompatCheck.sameNode(operand, viewed))
        try a.print("put the sigil on each branch: `{s}`", .{try spliced(self, if (whole != .nil) whole else operand, leaves.items, withs)})
    else
        // A path keeps its view, now through each branch's view.
        try a.print("put the sigil on each branch: `{c}{s}`", .{ sigil, try spliced(self, operand, leaves.items, withs) });
    if (hands(self, place).kind == .part_of_made) {
        try self.errAt(viewed, "cannot make {s} of `{s}`: it may be `{s}`, a part of the temporary `{s}`, which a view of the branching value would copy; {s}", .{ to, CallCheck.sourceText(self, viewed), CallCheck.sourceText(self, place), CallCheck.sourceText(self, StmtCheck.placeOf(self, place).base), fix });
    } else try self.errAt(viewed, "cannot make {s} of `{s}`: it may be `{s}`, a value a name holds, which a view of the branching value would copy; {s}", .{ to, CallCheck.sourceText(self, viewed), CallCheck.sourceText(self, place), fix });
    return false;
}

/// Whether `leaf` is the operand of a postfix `?` or `!` as written.
pub fn unwrapped(self: *Checker, leaf: Sexp) bool {
    const end = self.ctx.span(leaf).end;
    return end < self.ctx.source.len and (self.ctx.source[end] == '?' or self.ctx.source[end] == '!');
}

/// The branch view operand `operand` is, or a path of fields,
/// elements, and method calls starts from; `.nil` for none.
pub fn viewedBranch(operand: Sexp) Sexp {
    var e = operand;
    while (true) {
        if (e.isKind(.member) or e.isKind(.index)) {
            e = ir.get(e, .object);
        } else if (e.isKind(.call) and ir.Call.callee(e).isKind(.member)) {
            e = ir.Member.object(ir.Call.callee(e));
        } else break;
    }
    return if (sema.isBranchingForm(e)) e else .nil;
}

/// A read view of `operand`, written `?e` or not: a temporary is held
/// to its statement's end.
pub fn checkReadView(self: *Checker, operand: Sexp) Error!void {
    if (isTemporary(self, operand)) try viewTemp(self, operand);
}

/// Whether `e` is a constant, a value that lives for the whole
/// program and never changes (Core sentence 7), by what it means: a
/// literal or `none`; a function, or a module's constant, named here
/// (`f`, `K`) or in another module (`lib.twice`, `lib.K`); a member
/// of a type, here or in another module (an enum variant that holds
/// no payload, `Color.red`; an error value, `E.bad`; a number type's
/// limit, `Int.max`; a type's function, `P.origin`); an enum or error
/// literal with no payload (`.red`); an operator applied to constants
/// (`2 + 3`, `-5`, `Int.max - 1`); or a value that branches, every
/// value of which is a constant. A local binding is no constant,
/// whatever it holds: `g = f` may be given a write view.
pub fn isConstant(self: *Checker, e: Sexp) Error!bool {
    switch (e) {
        .src => {
            const id = self.ctx.symbolOf(e) orelse return hands(self, e).kind == .made;
            const sym = self.ctx.symbols.items[id];
            return sym.kind == .function or StmtCheck.rootOf(self, sym) == .constant;
        },
        .list => {},
        else => return false,
    }
    {
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        try sema.valueLeaves(self.ctx.allocator, e, &leaves);
        // A value that branches.
        if (leaves.items.len != 1 or !CompatCheck.sameNode(leaves.items[0], e)) {
            for (leaves.items) |leaf| if (!try isConstant(self, leaf)) return false;
            return leaves.items.len > 0;
        }
    }
    return switch (e.kind() orelse return false) {
        .enum_lit, .symbol => true,
        .member => self.ctx.isErrorMember(e) or try namesTypeConstant(self, e) or namesModuleConstant(self, e),
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>" => for (rig.children(e)) |c| {
            if (!try isConstant(self, c)) break false;
        } else true,
        else => false,
    };
}

/// `T.name` of a type `T` (a number type, an object, enum, or error
/// set, an alias, here or in another module): a constant the type
/// holds, a variant, an error value, a limit, or a function.
pub fn namesTypeConstant(self: *Checker, e: Sexp) Error!bool {
    const obj = ir.Member.object(e);
    return (try numberType(self, obj)) != null or (try CallCheck.namedType(self, obj)) != null;
}

/// `m.name` of another module's function or constant.
pub fn namesModuleConstant(self: *Checker, e: Sexp) bool {
    const sym = CallCheck.foreignMember(self, e) orelse return false;
    return sym.kind == .function or (sym.kind == .local and sym.flags.fixed);
}

/// A write view of `operand` (Core sentence 4: `!` makes a write view
/// of any value, named or temporary): a temporary, or the value a part
/// of one starts from, is held in its statement's slot until the
/// statement ends (`viewTemp`), where the change is seen and dropped
/// with it. A branching value that may be a name's would be viewed as
/// a copy, which the change would miss: each branch is viewed instead.
/// (A constant is never given a write view: `isConstant`.) False when
/// the view is rejected (reported).
pub fn checkWriteView(self: *Checker, operand: Sexp) Error!bool {
    if (!isTemporary(self, operand)) return true;
    // A handle that changes by a marked call is viewed, not what holds
    // it: what holds it is only read, in place, as a read self's
    // value is.
    if (StmtCheck.viewsPath(self, StmtCheck.placeOf(self, operand))) {
        if (!hands(self, operand).hasStorage()) try readLeafAs(self, operand, false);
        return true;
    }
    const base = if (hands(self, operand).hasStorage()) StmtCheck.placeOf(self, operand).base else operand;
    if (!try viewsBranch(self, operand, .nil, .write)) return false;
    try viewTemp(self, operand);
    if (base == .list) try self.ctx.record(.written_temps, base, {});
    return true;
}

/// `U8`, a `?String`'s byte.
pub fn byteType(self: *Checker) Error!TypeId {
    return self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
}

/// Whether `e` names a stack closure binding: one bound to a closure
/// literal, whose type is that function type (a binding declared as
/// another type keeps that type, and the literal was rejected).
pub fn closureBinding(self: *Checker, e: Sexp) bool {
    if (e != .src) return false;
    const id = self.ctx.symbolOf(e) orelse return false;
    const sym = self.ctx.symbols.items[id];
    return sym.flags.closure and self.ctx.types.get(sym.ty) == .function;
}

/// What `f`, of type `ty`, is as a function value (`FnArg`).
pub fn fnArg(self: *Checker, f: Sexp, ty: TypeId) Checker.FnArg {
    if (f.isKind(.lambda)) return .literal;
    if (closureBinding(self, f)) return .binding;
    if (sema.callableFnTy(self.ctx, ty) != null or sema.ownedClosureFn(self.ctx, ty) != null) return .view;
    return if (self.ctx.types.get(ty) == .function) .named else .other;
}

/// A value no binding holds, or a part of one: a view of it lives
/// only until the end of its statement. A view made here views
/// what it views, which outlives the statement.
pub fn isTemporary(self: *Checker, e: Sexp) bool {
    return switch (hands(self, e).kind) {
        .part_of_made => true,
        .made, .branches => if (self.ctx.typeOf(e)) |ty| !sema.isReadOrWriteView(self.ctx, ty) else false,
        .place, .view, .jump, .none => false,
    };
}

/// What the context of `e` does with it (`sema.Use`), recorded for a
/// name and for a value that yields one of its parts: emit moves a
/// name at a tail of the value out of its binding only where the
/// value is taken.
pub fn recordUse(self: *Checker, e: Sexp, use: sema.Use) Error!void {
    const yields = switch (e) {
        .src => hands(self, e).kind == .place,
        .list => sema.yieldsPart(e),
        else => false,
    };
    if (yields) try self.ctx.recordUse(e, use);
}

/// Whether `e`'s value needs cleanup.
pub fn ownsResource(self: *Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return !self.isPoison(ty) and sema.typeHasDropGlue(self.ctx, ty);
}

/// Whether `e` is a view whose value is copied out where a value is
/// expected (`sema.copiedThrough`).
pub fn copiesThrough(self: *const Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return sema.copiedThrough(self.ctx, ty) != null;
}

/// Whether `e`'s value copies (`sema.copies`).
pub fn copiesValue(self: *const Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return sema.copies(self.ctx, ty) == .yes;
}

/// How self `recv` is written (`SelfShape`).
pub fn selfShape(self: *const Checker, recv: Sexp) CompatCheck.SelfShape {
    if (recv.isKind(.read)) return .read_explicit;
    if (recv.isKind(.write)) return .write_explicit;
    if (recv.isKind(.move)) return .move_explicit;
    return switch (hands(self, recv).kind) {
        .made => .made,
        .branches => .branches,
        .place, .part_of_made, .view, .jump, .none => .place,
    };
}

/// What `e` hands over to its context (`sema.handsOver`).
pub fn hands(self: *const Checker, e: Sexp) sema.Hands {
    return sema.handsOver(self.ctx, e);
}

/// `?xs[a..b]`: a read-only slice `[]T`; `!xs[a..b]`: a writable one,
/// `![]T`.
pub fn viewSlice(self: *Checker, slice: Sexp, kind: Checker.ViewKind) Error!TypeId {
    const ty = if (kind == .read) try CallCheck.synthSlice(self, slice, true) else try writeSlice(self, slice);
    try self.ctx.recordType(slice, ty);
    // A slice of a branch views each branch's elements.
    if (!self.isPoison(ty) and !try viewsBranch(self, ir.Index.object(slice), slice, kind)) return self.t().invalid_id;
    return ty;
}

/// `!xs[a..b]`: a write view of the elements from `a` up to `b`, of
/// an array or a List of plain data the code may write, or of a
/// `![]T`. A `?String` and a `[]T` are read-only.
pub fn writeSlice(self: *Checker, slice: Sexp) Error!TypeId {
    const object = ir.Index.object(slice);
    const range = ir.Index.index(slice);
    // A temporary sliced is held in its statement's slot (below).
    const obj_ty = if (!hands(self, object).hasStorage()) try PatternCheck.synthExpr(self, object) else try synthOperand(self, object);
    try CallCheck.checkSliceRange(self, range);
    if (self.isPoison(obj_ty)) return obj_ty;
    if (sema.sliceView(self.ctx, obj_ty)) |view| try self.ctx.record(.slice_views, slice, view);
    const peeled = sema.unwrapViews(self.ctx, obj_ty);
    var len: ?u64 = null;
    const elem: TypeId = switch (self.ctx.types.get(peeled)) {
        .string_view, .static => {
            try self.errAt(object, "cannot make a write view of a slice of a `?String`; a `?String` is read-only", .{});
            return self.t().invalid_id;
        },
        .string => {
            try self.errAt(object, "cannot make a write view of a slice of a String; a String changes only through its methods (`!t.add(...)`, `!t.push(b)`, `!t.clear()`)", .{});
            return self.t().invalid_id;
        },
        .slice => |s| blk: {
            if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
                try self.errAt(object, "cannot make a write view of a slice of a `{s}`; a `[]T` is read-only (a writable slice is a `![]T`)", .{try self.tyName(obj_ty)});
                return self.t().invalid_id;
            }
            break :blk s.elem;
        },
        .array => |a| blk: {
            len = sema.arrayLen(self.ctx, a);
            break :blk a.elem;
        },
        else => (try CallCheck.listSliceElem(self, object, obj_ty, peeled)) orelse return self.t().invalid_id,
    };
    try CallCheck.checkSliceBounds(self, range, len);
    // The binding it reaches may be one no view can write (a
    // parameter, a fixed or loop binding): reported, nothing viewed.
    const place = StmtCheck.placeOf(self, slice);
    if (!try StmtCheck.requireAccess(self, place, .write_viewed, object)) return self.t().invalid_id;
    // A `![]T` may be resliced wherever it comes from; an array or a
    // List is sliced where it is stored, a temporary's in its
    // statement's slot.
    if (place.root == .temporary) {
        if (!try checkWriteView(self, object)) return self.t().invalid_id;
    } else if (sema.writeSliceElem(self.ctx, obj_ty) == null and place.base != .src) {
        try self.errAt(object, CompatCheck.slice_of_temporary, .{});
        return self.t().invalid_id;
    }
    return self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .slice = .{ .elem = elem } }) });
}

/// `<x`. What it does to its source is `sema.moveSource`: of a field
/// or element holding an optional, `<p.f` takes the value out and
/// leaves `none` behind, so the place is written, and must be
/// reachable for writing. A part of a value made here is reported
/// (`rejectMadeParts`); the ownership checker decides the rest.
pub fn synthMove(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Move.operand(e);
    const ty = try PatternCheck.synthExpr(self, operand);
    if (operand == .src) if (self.ctx.symbolOf(operand)) |id| try self.ctx.recordWrite(e, id, .move);
    if (try PatternCheck.payloadViewTaken(self, operand, "move")) return self.t().invalid_id;
    if (self.isPoison(ty)) return ty;
    if (try StdFormCheck.rejectLane(self, operand, .take)) return self.t().invalid_id;
    if (try rejectMadeParts(self, e, operand)) return self.t().invalid_id;
    if (sema.moveSource(self.ctx, operand) != .optional_part) return ty;
    try self.ctx.record(.takes, e, {});
    const place = StmtCheck.placeOf(self, operand);
    if (place.cell_list_elem != null) {
        try self.errAt(e, "an element of a Cell's List is read and written whole: copy it out with `c[i]`, then write `c[i] = none`", .{});
        return ty;
    }
    if (!try StmtCheck.requireAccess(self, place, .take, e)) return ty;
    // The owner changes: it lives in mutable storage. (Through a
    // view or handle, the place is the owner's.)
    if (!place.indirect) if (place.sym) |id| {
        try self.ctx.recordWrite(e, id, .take);
    };
    return ty;
}

/// `<operand` (at `at`) of a part of a value made here, as the whole
/// operand or as a leaf of a branching one (`sema.moveSource`): the
/// statement drops the value, so nothing would see the part ended or
/// emptied. Reported; whether it was.
pub fn rejectMadeParts(self: *Checker, at: Sexp, operand: Sexp) Error!bool {
    switch (sema.moveSource(self.ctx, operand)) {
        .made_part => {
            try rejectMadePart(self, at, operand);
            return true;
        },
        .branches => {
            var leaves: std.ArrayList(sema.MoveLeaf) = .empty;
            try sema.moveLeaves(self.ctx.arena.allocator(), self.ctx, operand, &leaves);
            for (leaves.items) |leaf| if (leaf.source == .made_part) {
                try rejectMadePart(self, leaf.node, leaf.node);
                return true;
            };
            return false;
        },
        else => return false,
    }
}

pub fn rejectMadePart(self: *Checker, at: Sexp, part: Sexp) Error!void {
    const ty = self.ctx.typeOf(part) orelse return;
    if (self.isPoison(ty)) return;
    const optional = self.ctx.types.get(ty) == .optional;
    // A handle made here reaches a box other handles may see.
    if (!optional and sema.copies(self.ctx, ty) == .yes) {
        try self.errAt(at, "cannot move out of `{s}`: it copies, so `<` would leave it as it was; remove the `<` to copy it", .{CallCheck.sourceText(self, part)});
    } else if (handleOnPath(self, part)) |handle| {
        try self.errAt(at, "cannot {s} `{s}`: it is reached through the shared handle `{s}`, and other handles may still use it", .{ if (optional) "take out of" else "move out of", CallCheck.sourceText(self, part), CallCheck.sourceText(self, handle) });
    } else if (optional) {
        try self.errAt(at, "cannot take out of a temporary: nothing would see it emptied; bind it to a name first", .{});
    } else {
        // A view of a temporary names the temporary.
        const root = sema.pathRoot(part);
        const temp = if (root.isKind(.read) or root.isKind(.write)) ir.get(root, .operand) else root;
        try self.errAt(at, "cannot move a part out of the temporary `{s}`, which its statement drops; bind it to a name first", .{CallCheck.sourceText(self, temp)});
    }
}

/// The shared handle a field or element path passes through, by the
/// type of each value on it.
pub fn handleOnPath(self: *Checker, e: Sexp) ?Sexp {
    var p = e;
    while (p.isKind(.member) or p.isKind(.index)) {
        p = ir.get(p, .object);
        const ty = self.ctx.typeOf(p) orelse continue;
        if (self.ctx.types.get(ty) == .shared) return p;
    }
    return null;
}

pub fn synthShare(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Share.operand(e);
    if (try shareOfNone(self, e, null)) return self.t().invalid_id;
    if (operand.isKind(.lambda)) return ClosureCheck.ownedClosure(self, operand, null);
    const ty = try shareOperand(self, operand, null);
    if (try weakUpgrade(self, e, ty)) |upgraded| return upgraded;
    // A literal takes its default type.
    if (ty == self.t().int_literal_id) try defaultIntLiteral(self, operand);
    const inner = ExprCheck.canonical(self, ty);
    if (self.isPoison(inner)) return inner;
    if (self.ctx.types.get(inner) == .function) {
        try self.errAt(operand, "`*` makes an owned closure only from a closure literal: `*|...| body`", .{});
        return self.t().invalid_id;
    }
    if (self.ctx.types.get(inner) == .shared) {
        try self.errAt(operand, "this value is already a shared handle `{s}`; `*` would nest handles. Clone it with `+x` for another handle", .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    // A box of an API object holds a value whose size is erased, which
    // no new allocation could take.
    if (sema.objectHeld(self.ctx, inner)) |h| if (h.form == .box) {
        var shared = h.object;
        shared.builtins.remove(.Sends);
        shared.builtins.remove(.Clone);
        try self.errAt(e, "`{s}` would move a value whose type is erased: share the value before erasing it, `*<x` where a `*{s}` goes", .{ CallCheck.sourceText(self, e), try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), shared) });
        return self.t().invalid_id;
    };
    if (sema.heapStacked(self.ctx, inner)) {
        // `*o` of an optional weak handle: `*` upgrades the handle
        // inside, once it is taken out.
        if (self.ctx.types.get(sema.unwrapOptionals(self.ctx, inner)) == .weak) {
            const shown = try plainText(self, CompatCheck.stripSigil(operand));
            try self.errAt(operand, "`{s}` is an optional weak handle `{s}`, and `*` upgrades a weak handle, not an optional: take the handle out first, `if {s} as w`, then `*w`", .{ shown, try self.tyName(inner), shown });
            return self.t().invalid_id;
        }
        try self.errAt(operand, "this value is already `{s}`; `*` would hold it twice; " ++ sema.heap_stacked_rule, .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    switch (self.ctx.types.get(inner)) {
        .read_view, .write_view => {
            try self.errAt(operand, "a handle holds a value, not a view; `{s}` is a view: share an owned value instead", .{try self.tyName(inner)});
            return self.t().invalid_id;
        },
        else => {},
    }
    try sema.requireHandleOf(self.ctx, inner, self.startOf(e), "`*`");
    return self.ctx.intern(.{ .shared = inner });
}

/// `*w` of `w`, of type `ty`, where it upgrades a weak handle: the
/// `*T?` it makes, else null. `*` of a `~T`, or of a view of one,
/// upgrades it; a `T` a generic body sees is no weak handle, so `*x`
/// there makes a counted handle in every instance. Whether `*` reads
/// `w` or takes it is decided by a positive list (`sema.Upgrade`):
/// it reads a view, a place, a part of a value, `?x` or `!x`, or a
/// branching value, and takes a weak handle made there (`*<w`, `*~h`,
/// `*f()`), which is dropped once upgraded. Recorded
/// (`Facts.upgrades`), which the ownership checker and emit
/// read: a read is `w`'s, as a `?@` method's self is read; a
/// take moves `w` as `*<x` moves `x`.
pub fn weakUpgrade(self: *Checker, e: Sexp, ty: TypeId) Error!?TypeId {
    const operand = ir.Share.operand(e);
    if (self.isPoison(ty)) return null;
    const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
        .weak => |inner| inner,
        else => return null,
    };
    const how: sema.Upgrade = if (sema.isReadOrWriteView(self.ctx, ty)) .reads else switch (hands(self, operand).kind) {
        .place, .part_of_made, .view, .branches => .reads,
        .made => .takes,
        .jump, .none => return null,
    };
    if (operand.isKind(.write)) {
        const shown = try plainText(self, CompatCheck.stripSigil(operand));
        try self.errAt(operand, "`*` only reads the weak handle it upgrades: write `*{s}`", .{shown});
        return self.t().invalid_id;
    }
    if (how == .reads) {
        // A branching value that may be a name's is viewed branch by
        // branch, `*(?a if c else ?b)`, as a self is.
        if (hands(self, operand).kind == .branches and !try viewsBranch(self, operand, e, .read)) return self.t().invalid_id;
        try rejectResourceTemporary(self, operand, ty);
    }
    try self.ctx.record(.upgrades, e, how);
    return try self.ctx.intern(.{ .optional = try self.ctx.intern(.{ .shared = inner }) });
}

/// Whether `e`'s type is its own wherever it stands, whatever is
/// expected of it, by a positive list: a name, a field or element
/// path, a view, or a move (`checkContextual` types none of them).
pub fn typedWhereItStands(self: *Checker, e: Sexp) bool {
    return switch (e) {
        .src => blk: {
            const s = self.text(e);
            break :blk s.len > 0 and (std.ascii.isAlphabetic(s[0]) or s[0] == '_') and
                !std.mem.eql(u8, s, "none") and !std.mem.eql(u8, s, "true") and !std.mem.eql(u8, s, "false");
        },
        .list => if (e.kind()) |k| switch (k) {
            .member, .index => true,
            .read, .write, .move => typedWhereItStands(self, ir.get(e, .operand)),
            else => false,
        } else false,
        else => false,
    };
}

/// `*none` where no handle of an optional is expected (`target`, a
/// `*(T?)`, holds `none`), which would make a handle of nothing, is
/// rejected (reported): an optional handle with no value is `none`
/// itself.
pub fn shareOfNone(self: *Checker, e: Sexp, target: ?TypeId) Error!bool {
    const operand = ir.Share.operand(e);
    if (operand != .src or !std.mem.eql(u8, self.text(operand), "none")) return false;
    // Where the expected type was reported, nothing more is.
    if (self.expect.under_poison) return false;
    if (target) |want| switch (self.ctx.types.get(want)) {
        .shared => |inner| if (self.ctx.types.get(inner) == .optional) return false,
        else => {},
    };
    try self.errAt(e, "`*none` makes a handle of nothing; write `none` where a `(*T)?` is expected", .{});
    return true;
}

/// The operand of `*x`, checked against `expected` when given: the
/// one place a `Signal(...)` constructor may stand.
pub fn shareOperand(self: *Checker, operand: Sexp, expected: ?TypeId) Error!TypeId {
    const prev = self.expect.shared_operand;
    defer self.expect.shared_operand = prev;
    self.expect.shared_operand = operand;
    const e = expected orelse return PatternCheck.synthExpr(self, operand);
    try checkExpr(self, operand, e);
    return e;
}

/// The type `sigil` over `inner` would be, as a diagnostic spells it.
pub fn stackedSpelling(self: *Checker, sigil: u8, inner: TypeId) Error![]const u8 {
    // A suffix binds tighter than a holding sigil: `*(~T?)`.
    const shown = try self.tyName(inner);
    if (self.ctx.types.get(inner) == .optional) return self.ctx.arena.allocator().print("{c}({s})", .{ sigil, shown });
    return self.ctx.arena.allocator().print("{c}{s}", .{ sigil, shown });
}

/// `^x`: `x` moved into a new box, checked against the box's value
/// type when `target` is a box.
pub fn synthBox(self: *Checker, e: Sexp, target: ?TypeId) Error!TypeId {
    const operand = ir.Box.operand(e);
    if (try boxOfNone(self, e, target)) return self.t().invalid_id;
    if (operand.isKind(.lambda)) {
        try self.errAt(e, "`^` boxes a value, not a closure: an owned closure is `*|...| body`", .{});
        return self.t().invalid_id;
    }
    const want = if (target) |tt| sema.boxedType(self.ctx, tt) else null;
    const ty = if (want) |w| blk: {
        try checkExpr(self, operand, w);
        break :blk w;
    } else try PatternCheck.synthExpr(self, operand);
    if (ty == self.t().int_literal_id) try defaultIntLiteral(self, operand);
    const inner = ExprCheck.canonical(self, ty);
    if (self.isPoison(inner)) return inner;
    if (self.ctx.types.get(inner) == .function) {
        try self.errAt(operand, sema.boxed_function, .{});
        return self.t().invalid_id;
    }
    if (sema.heapStacked(self.ctx, inner)) {
        try self.errAt(operand, "this value is already `{s}`; `^` would hold it twice; " ++ sema.heap_stacked_rule, .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    // A task, or a set of them, is a handle to work the runtime holds,
    // waited or canceled where it is held, never through a box.
    const held = sema.unwrapOptionals(self.ctx, inner);
    if (sema.isTask(self.ctx, held) or sema.isTaskSet(self.ctx, held)) {
        try self.errAt(operand, "`^` boxes a value, and a `{s}` is a handle to work the runtime holds already: hold it as it is", .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    var r = self.resolver();
    return r.boxOf(inner, self.startOf(e));
}

/// `^none` where no box of an optional is expected (`target`, a
/// `^(T?)`, holds `none`) makes a box of nothing, which is
/// rejected (reported): an optional box with no value is `none`
/// itself.
pub fn boxOfNone(self: *Checker, e: Sexp, target: ?TypeId) Error!bool {
    const operand = ir.Box.operand(e);
    if (operand != .src or !std.mem.eql(u8, self.text(operand), "none")) return false;
    if (self.expect.under_poison) return false;
    if (target) |want| if (sema.boxedType(self.ctx, want)) |inner| if (self.ctx.types.get(inner) == .optional) return false;
    try self.errAt(e, "`^none` makes a box of nothing; write `none` where a `^T?` is expected", .{});
    return true;
}

pub fn synthWeak(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Weak.operand(e);
    const inner = try synthOperand(self, operand);
    if (self.isPoison(inner)) return inner;
    switch (self.ctx.types.get(inner)) {
        .shared => |target| {
            // A frozen value is kept by any handle, from any task.
            if (sema.frozenValue(self.ctx, target) != null) {
                try self.errAt(operand, "a frozen value has no weak handle: `+{s}` shares it", .{CallCheck.sourceText(self, operand)});
                return self.t().invalid_id;
            }
            // A `*{A + Syncs}` holds one.
            if (sema.frozenObject(self.ctx, target)) {
                try self.errAt(e, "`{s}` of a `{s}`: a frozen value has no weak handle", .{ CallCheck.sourceText(self, e), try self.tyName(inner) });
                return self.t().invalid_id;
            }
            return self.ctx.intern(.{ .weak = target });
        },
        else => {
            try self.errAt(operand, "`~` weak reference requires a shared handle `*T`; got `{s}`", .{try self.tyName(inner)});
            return self.t().invalid_id;
        },
    }
}

/// `+e` reads `e` (Core §3): a value made there is a temporary its
/// statement drops, and a branching value's names are read in place.
pub fn synthClone(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Clone.operand(e);
    if (try rejectSharedTemporary(self, operand)) return self.t().invalid_id;
    const inner = try synthReadTemp(self, operand);
    if (self.isPoison(inner)) return inner;
    // A `![]T` reaches elements it does not own; a copy of the view
    // would be a second path to them.
    if (sema.writeSliceElem(self.ctx, inner) != null) {
        try self.errAt(operand, "`+x` cannot clone a `{s}`: it is a write view of elements it does not own; move it with `<x`, or take a read slice with `?x[..]`", .{try self.tyName(inner)});
        return self.t().invalid_id;
    }
    // An API object's value has no type a clone could make; only a
    // box of one clones, through its table (docs/design/apis.md,
    // Stage 4).
    if (sema.objectView(self.ctx, inner)) |ov| {
        const shown = CallCheck.sourceText(self, operand);
        const fix = if (ov.form == .write) try std.fmt.allocPrint(self.ctx.arena.allocator(), "pass it on as a read view with `?{s}`", .{shown}) else try std.fmt.allocPrint(self.ctx.arena.allocator(), "a view copies, so `{s}` itself views the value again", .{shown});
        try self.errAt(operand, "`+{s}` would make a value of no size of its own: only a `^{s}` has `+`; {s}", .{ shown, try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), ov.object), fix });
        return self.t().invalid_id;
    }
    // A box of an API object clones through its table's `Clone`,
    // which only its braces or API name.
    if (sema.objectHeld(self.ctx, sema.unwrapViews(self.ctx, inner))) |h| if (!sema.objectMeets(self.ctx, h.object, h.form, .Clone)) {
        const shown = CallCheck.sourceText(self, operand);
        const api = try sema.apiName(self.ctx, h.object.api);
        var with = h.object;
        with.builtins.insert(.Clone);
        try self.errAt(operand, "`+{s}` makes a new owner, and a `{s}` is not cloned: its type is erased; write `^{s}`, or build `{s}` on `Clone`", .{ shown, try self.tyName(sema.unwrapViews(self.ctx, inner)), try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), with), api });
        return self.t().invalid_id;
    };
    // A clone reads the value a view reaches.
    const value = try readThrough(self, operand, inner, sema.unwrapViews(self.ctx, inner));
    switch (sema.cloneable(self.ctx, inner)) {
        .copy, .bump, .text, .deep => {},
        .depends => try requireOf(self, value, .clones, self.startOf(operand), "clones a value"),
        .no => {
            const shown = try self.tyName(value);
            if (sema.tableElem(self.ctx, sema.unwrapViews(self.ctx, value)) != null) {
                try self.errAt(operand, "`+x` cannot clone a `{s}`: a table has no clone, since a copy would make every slot; move it with `<x`, or pass a view of it", .{shown});
            } else if (!sema.typeHasDropGlue(self.ctx, value) and sema.holdsWriteView(self.ctx, value)) {
                try self.errAt(operand, "`+x` cannot clone a `{s}`: it holds a write view, which has one holder; move it with `<x`", .{shown});
            } else if (!sema.typeHasDropGlue(self.ctx, value)) {
                try self.errAt(operand, "`+x` cannot clone a `{s}`: it is unique, and a copy would duplicate it; move it with `<x`", .{shown});
            } else if (sema.isUnique(self.ctx, value)) {
                try self.errAt(operand, "`+x` cannot clone a `{s}`: it holds a unique value, which a copy would duplicate; move it with `<x`, or pass a view of it", .{shown});
            } else if (sema.containsTypeVar(self.ctx, value)) {
                try self.errAt(operand, "`+x` cannot clone a `{s}`: a type parameter has no deep clone in a generic body; move it with `<x`, or pass a view of it", .{shown});
            } else try self.errAt(operand, "`+x` cannot clone a `{s}`: a value with a `drop` body, or holding a Signal or a write view, has no clone; move it with `<x`, or pass a view of it", .{shown});
            return self.t().invalid_id;
        },
    }
    // A `?String` view clones into the `String` that owns a copy of its bytes.
    return if (value == self.t().string_view_id) self.t().string_id else value;
}

/// The value an operator reads from `e` (`operandValue`).
pub fn synthOperandValue(self: *Checker, e: Sexp) Error!TypeId {
    const ty = try PatternCheck.synthExpr(self, e);
    return readThrough(self, e, ty, CompatCheck.operandValue(self.ctx, ty));
}

/// The value a view `e` reaches, or `e`'s own value.
pub fn synthReached(self: *Checker, e: Sexp) Error!TypeId {
    const ty = try PatternCheck.synthExpr(self, e);
    return readThrough(self, e, ty, sema.unwrapViews(self.ctx, ty));
}

/// The value `e` gives where a value is read: a viewed Copy value
/// reads as the value (`readValue`).
pub fn synthValue(self: *Checker, e: Sexp) Error!TypeId {
    const ty = try PatternCheck.synthExpr(self, e);
    return readThrough(self, e, ty, CompatCheck.readValue(self.ctx, ty));
}

/// `value`, the value `e` of type `ty` gives where it is read; when
/// that is what a view reaches, `e` reads through it (`readOf`).
pub fn readThrough(self: *Checker, e: Sexp, ty: TypeId, value: TypeId) Error!TypeId {
    if (value != ty) try readOf(self, e, ty, .{ .value = value });
    return value;
}

/// `e`, of type `ty`, a view through which a place is reached (an
/// element of a viewed slice or `?String`, a header's optional): read
/// through, as no value but the place it reaches.
pub fn reachThrough(self: *Checker, e: Sexp, ty: TypeId, value: TypeId) Error!TypeId {
    if (value != ty) try readOf(self, e, ty, .reach);
    return value;
}

/// Synthesize the operand of a view, clone, member access, index,
/// or method call. The operand is not bound to a name, so a fresh
/// value that owns a resource there would never be dropped.
pub fn synthOperand(self: *Checker, operand: Sexp) Error!TypeId {
    if (try rejectSharedTemporary(self, operand)) return self.t().invalid_id;
    const ty = try PatternCheck.synthExpr(self, operand);
    try rejectResourceTemporary(self, operand, ty);
    return ty;
}

/// `*Name(...)` where nothing binds it: a new allocation whatever its
/// type turns out to be. True when reported.
pub fn rejectSharedTemporary(self: *Checker, operand: Sexp) Error!bool {
    if (!operand.isKind(.share) or !ir.Share.operand(operand).isKind(.call) or ir.Call.callee(ir.Share.operand(operand)) != .src) return false;
    try self.errAt(operand, "this `*{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{self.text(ir.Call.callee(ir.Share.operand(operand)))});
    return true;
}

/// Whether a value of `ty` does not copy (`sema.copies`), for a
/// check that rejects `op`, which copies one. Inside a generic body a
/// type holding type parameters may or may not: `op` is then allowed,
/// and every instantiation must supply values that copy
/// (`Requirement.copies`).
pub fn cannotCopy(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
    return switch (sema.copies(self.ctx, ty)) {
        .no => true,
        .yes => false,
        .depends => {
            try requireOf(self, ty, .copies, pos, op);
            return false;
        },
    };
}

/// Whether a value of `ty` moves (`sema.moves`), for a construct
/// that takes such a value rather than reading a copy of it. Inside
/// a generic body a type holding type parameters may or may not: the
/// construct reads it, and every instantiation must supply values
/// that copy (`Requirement.copies`).
pub fn mustTake(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
    return switch (sema.moves(self.ctx, ty)) {
        .yes => true,
        .no => false,
        .depends => {
            try requireOf(self, ty, .copies, pos, op);
            return false;
        },
    };
}

/// Whether a value of `ty` needs cleanup (`sema.typeHasDropGlue`),
/// for a check that rejects `op`, which discards one or keeps it
/// where nothing drops it. Inside a generic body a type holding type
/// parameters may or may not: `op` is then allowed, and every
/// instantiation must supply values that need no cleanup
/// (`Requirement.no_cleanup`).
pub fn needsCleanup(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
    if (sema.typeHasDropGlue(self.ctx, ty)) return true;
    if (sema.maybeDropGlue(self.ctx, ty)) try requireOf(self, ty, .no_cleanup, pos, op);
    return false;
}

/// What the built-in method `m` of the type `owner_sym` declares it
/// needs of the type's parameter `T` (`sema.Needs`, from
/// `resolve.registerBuiltins`), checked at a call on either route it
/// takes, `xs.m(...)` and `List.m(xs, ...)` through the type, where
/// `args` are the type's arguments at the call. A `T` that may or may
/// not meet it, inside a generic body, makes it a requirement on
/// each instance (`Requirement.copies`). An instance the type itself
/// rejects (`resolve.builtinElementError`) was reported where it is
/// spelled or made. False after a diagnostic.
pub fn meetsNeeds(self: *Checker, m: Field, owner_sym: SymbolId, args: []const TypeId, pos: u32, values: []const Sexp) Error!bool {
    const needs = m.needs orelse return true;
    // Only a built-in generic's method declares needs, and every call
    // of one has the type's arguments: a call without them is
    // rejected, never passed unchecked.
    if (args.len == 0) {
        try self.err(pos, "internal error: `{s}.{s}` declares what it needs of `T`, and the call has no type arguments to check", .{ self.ctx.symbols.items[owner_sym].name, m.name });
        return false;
    }
    if (self.isPoison(args[0])) return true;
    const param = args[0];
    switch (needs.t) {
        .copies => if (!try cannotCopy(self, param, pos, needs.op)) return true,
        // A copy kept where no loan is tracked holds no view; one in a
        // generic body asks each instance for none (`Checker.requireNoView`
        // in the ownership checker).
        .plain => if (sema.mayHoldView(self.ctx, param)) {
            const shown = try self.tyName(param);
            try self.err(pos, "{s}, and {s} `{s}` holds a view, which the List would not track: push each element, `!xs.push(y)`", .{ needs.says.into_elements.what, CompatCheck.article(shown), shown });
            return false;
        } else if (!try cannotCopy(self, param, pos, needs.op)) return true,
        .records => return readsRecords(self, m.name, param, pos, if (values.len > 0 and !values[0].isKind(.kwarg)) values[0] else null),
        .equatable => {
            var params: std.ArrayList(SymbolId) = .empty;
            defer params.deinit(self.ctx.allocator);
            const n = (try sema.notEquatable(self.ctx, param, &params)) orelse {
                for (params.items) |tv| try ExprCheck.require(self, tv, .equatable, pos, needs.op);
                return true;
            };
            try self.err(pos, "`{s}.{s}` compares elements with `==`, which is not defined for `{s}`: {s}", .{ self.ctx.symbols.items[owner_sym].name, m.name, try self.tyName(param), try ApiCheck.notEquatableReason(self.ctx, n) });
            return false;
        },
    }
    if ((try resolve.builtinElementError(self.ctx, owner_sym, args)) != null) return true;
    const owner = self.ctx.symbols.items[owner_sym].name;
    const shown = try self.tyName(param);
    switch (needs.says) {
        .element_out => |advice| try self.err(pos, "`{s}.{s}` would copy an element out of a `{s}` of `{s}`, which a copy cannot share; {s}", .{ owner, m.name, owner, shown, advice }),
        .value_out => |advice| try self.err(pos, "`{s}.{s}` returns a copy of the value, and {s} `{s}` {s}, so it can't be copied; {s}", .{ owner, m.name, CompatCheck.article(shown), shown, if (sema.typeHasDropGlue(self.ctx, param)) "owns what it must release" else movesBecause(self, param), advice }),
        .into_elements => |d| try notDuplicated(self, pos, d.what, param, d.loop, d.tail),
        .from_bytes, .compares => unreachable,
    }
    return false;
}

/// Whether `elem`, the element of a List that method `method` makes
/// from the bytes `bytes`, is a record (`sema.bytesRecord`); in a
/// generic body, a type parameter's instances must be
/// (`Requirement.records`). Bytes known where the call is written, a
/// string literal or an embedded file, must be a whole number of
/// records: the file's size is known once the module graph finds it
/// (`SemContext.recordEmbedRecord`). False after a diagnostic.
pub fn readsRecords(self: *Checker, method: []const u8, elem: TypeId, pos: u32, bytes: ?Sexp) Error!bool {
    if (self.ctx.types.get(elem) == .type_var) {
        try ExprCheck.require(self, self.ctx.localSym(self.ctx.types.get(elem).type_var), .records, pos, method);
        return true;
    }
    const shown = try self.tyName(elem);
    var held: std.ArrayList(SymbolId) = .empty;
    try sema.heldTypeVars(self.ctx, elem, &held, self.ctx.arena.allocator());
    if (held.items.len > 0) {
        try self.err(pos, "`{s}` makes each `{s}` from bytes, which takes a type known here or a type parameter, `List[T]`: whether every bit pattern of a `{s}` is one depends on its instance", .{ method, shown, shown });
        return false;
    }
    const head = "`{s}` makes each `{s}` from bytes, so every bit pattern must be {s} `{s}`";
    const a = self.ctx.arena.allocator();
    // A record of `Bool`s or enums is made only from an embedded
    // file's bytes, whose values the module graph checks.
    var checked = false;
    const not = switch (try sema.bytesRecord(self.ctx, elem)) {
        .record => |r| not: {
            const embedded = if (bytes) |b| isEmbedCall(self, b) else false;
            if (r.checks.len > 0 and !embedded) {
                checked = true;
                break :not r.checks[0].not;
            }
            if (bytes) |b| try recordsIn(self, method, shown, r, b);
            return true;
        },
        .not => |n| n,
    };
    const subject = if (not.field.len == 0) try a.print(", and {s} `{s}`", .{ CompatCheck.article(not.shown), not.shown }) else try a.print("; field `{s}` of `{s}` is {s} `{s}`,", .{ not.field, not.owner, CompatCheck.article(not.shown), not.shown });
    const which = if (not.field.len == 0) "" else " which";
    const embed_hint: []const u8 = if (checked) "; an `$embed(path)`'s bytes may make one, since the compiler checks their values" else "";
    switch (not.why) {
        .boolean => try self.err(pos, head ++ "{s}{s} is only 0 or 1{s}", .{ method, shown, CompatCheck.article(shown), shown, subject, which, embed_hint }),
        .enumeration => if (not.field.len == 0)
            try self.err(pos, head ++ ", and `{s}` is an enum, whose values are only its variants'{s}", .{ method, shown, CompatCheck.article(shown), shown, not.shown, embed_hint })
        else
            try self.err(pos, head ++ "; field `{s}` of `{s}` is an enum, whose values are only its variants'{s}", .{ method, shown, CompatCheck.article(shown), shown, not.field, not.owner, embed_hint }),
        .other => try self.err(pos, head ++ "{s}{s} is not an integer, a float, or an object or array of them", .{ method, shown, CompatCheck.article(shown), shown, subject, which }),
        .not_plain => try self.err(pos, head ++ ", and `{s}` is not plain data: it does not copy, or has a `drop`", .{ method, shown, CompatCheck.article(shown), shown, not.shown }),
        .generic => try self.err(pos, head ++ ", and `{s}` is an instance of a generic object; declare an object of its field types", .{ method, shown, CompatCheck.article(shown), shown, not.shown }),
        .not_exact => |obj| if (not.field.len == 0)
            try self.err(pos, head ++ ", and `{s}` is not `exact`, so Zig may lay out its fields in an order of its own: add `exact` to `obj {s}`", .{ method, shown, CompatCheck.article(shown), shown, not.shown, obj })
        else
            try self.err(pos, head ++ "; field `{s}` of `{s}` is {s} `{s}`, which is not `exact`: add `exact` to `obj {s}`", .{ method, shown, CompatCheck.article(shown), shown, not.field, not.owner, CompatCheck.article(not.shown), not.shown, obj }),
        .empty => try self.err(pos, head ++ ", and `{s}` holds no bytes", .{ method, shown, CompatCheck.article(shown), shown, not.shown }),
        .private => |module| try self.err(pos, head ++ "; field `{s}` of `{s}` is private to module `{s}`, which sets it", .{ method, shown, CompatCheck.article(shown), shown, not.field, not.owner, module }),
        .padding_before => |p| try self.err(pos, head ++ ", and `{s}` has padding before field `{s}`: it starts at byte {d}, and {s} `{s}` starts at a multiple of {d}; order the fields so that none needs padding", .{ method, shown, CompatCheck.article(shown), shown, not.owner, not.field, p.at, CompatCheck.article(not.shown), not.shown, p.alignment }),
        .named_none => |none| {
            const value = if (none.variant) |v| try a.print(".{s}", .{v}) else try a.print("{d}", .{none.value});
            try self.err(pos, head ++ "{s}{s} names its none (`none {s} == {s}`), a value no `{s}` holds", .{ method, shown, CompatCheck.article(shown), shown, subject, which, none.field, value, not.shown });
        },
        .padding_after => |p| try self.err(pos, head ++ ", and `{s}` has {d} {s} of padding after field `{s}`, to a multiple of {d}; add a field that fills them", .{ method, shown, CompatCheck.article(shown), shown, not.owner, p.bytes, if (p.bytes == 1) "byte" else "bytes", not.field, p.alignment }),
    }
    return false;
}

/// The bytes `bytes` a call makes records of `size` bytes from, when
/// they are known where it is written: a string literal's, checked
/// here, and an embedded file's, checked once the file is found.
pub fn recordsIn(self: *Checker, method: []const u8, shown: []const u8, record: sema.Record, bytes: Sexp) Error!void {
    const size = record.size;
    if (bytes == .src) {
        const lit = self.text(bytes);
        if (lit.len < 2 or (lit[0] != '"' and lit[0] != '\'')) return;
        const held = CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), lit) orelse return;
        if (held.len % size != 0) try self.errAt(bytes, "`{s}` reads whole `{s}`s, {d} bytes each, and the literal holds {d} bytes", .{ method, shown, size, held.len });
        return;
    }
    if (isEmbedCall(self, bytes)) {
        try self.ctx.recordEmbedRecord(bytes, .{ .size = size, .method = method, .shown = shown, .checks = record.checks });
    }
}

/// Whether `bytes` is written `$embed(path)`: an embedded file's
/// bytes, whole, known where the call is written.
pub fn isEmbedCall(self: *Checker, bytes: Sexp) bool {
    return bytes.isKind(.builtin) and std.mem.eql(u8, self.text(ir.Builtin.name(bytes)), "embed");
}

/// A call of method `m` of a generic type (`owner`, declared in
/// module `module`, null for this one) at the type's arguments `args`
/// meets the bounds the method adds to them (`fun Wrap[T: Print].show(?@)`)
/// and records the witnesses it passes for those that name APIs of a
/// program's own. An argument that holds a type parameter with no
/// bound meets none: each instance would decide, and a call on one
/// reaches no method under a bound. False after a diagnostic.
pub fn meetsOwnerBounds(self: *Checker, m: Field, owner: sema.Symbol, module: ?u32, args: []const TypeId, pos: u32, self_arg: bool) Error!bool {
    if (m.owner_bounds.len == 0) return true;
    const a = self.ctx.arena.allocator();
    const home: *const SemContext = if (module) |id| self.ctx.foreign_semas.get(id) orelse self.ctx else self.ctx;
    const home_sym = owner;
    const tparams = home_sym.type_params orelse &.{};
    if (args.len < tparams.len) {
        try self.err(pos, "internal error: `{s}.{s}` is declared under bounds on its type's parameters, and the call has no type arguments to check", .{ owner.name, m.name });
        return false;
    }
    for (args) |arg| if (self.isPoison(arg)) return true;
    var inst_text: std.ArrayList(u8) = .empty;
    try inst_text.print(a, "{s}[", .{owner.name});
    for (args, 0..) |arg, i| try inst_text.print(a, "{s}{s}", .{ if (i > 0) ", " else "", try self.tyName(arg) });
    try inst_text.print(a, "].{s}", .{m.name});
    const inst = inst_text.items;
    for (m.owner_bounds) |b| {
        if (b.param >= tparams.len) continue;
        const arg = args[b.param];
        const pname = home.symbols.items[tparams[b.param]].name;
        const shown = try self.tyName(arg);
        // A type parameter with no bound, which each instance decides;
        // a `pub` declaration's is checked by its bounds, below.
        var held: std.ArrayList(SymbolId) = .empty;
        try sema.reachedTypeVars(self.ctx, arg, &held, a);
        for (held.items) |p| {
            const psym = self.ctx.symbols.items[p];
            if (sema.checkedByBounds(psym) or psym.flags.set_param) continue;
            const needed = try sema.ownerBoundsText(self.ctx, home, a, tparams, &.{b});
            try self.err(pos, "`{s}` needs `{s}`, and `{s}` has no bound: a call reaches a method under a bound only where the bounds of its type's arguments give it; write `[{s}: {s}]`", .{ inst, needed, psym.name, psym.name, needed[std.mem.find(u8, needed, ": ").? + 2 ..] });
            return false;
        }
        for (b.user_apis) |u| {
            if (try sema.provides(self.ctx, arg, u) != null) continue;
            const uname = try sema.apiName(self.ctx, u);
            if (try sema.reportStatedUser(self.ctx, pos, arg, u, try a.print("calls `{s}`, which needs `{s}: {s}`", .{ inst, pname, uname }))) return false;
            try self.err(pos, "`{s}` needs `{s}: {s}`, and `{s}` does not provide `{s}`{s}", .{ inst, pname, uname, shown, uname, try sema.unprovidedFix(self.ctx, arg, u) });
            return false;
        }
        var it = sema.implied(b.apis).iterator();
        while (it.next()) |api| {
            const lack = (try sema.lacks(self.ctx, arg, api)) orelse continue;
            if (try sema.reportStatedLack(self.ctx, pos, api, lack, try a.print("calls `{s}`, which needs `{s}: {s}`", .{ inst, pname, @tagName(api) }))) {
                // Reported at the parameter.
            } else if (lack.own_eq) {
                try self.err(pos, "`{s}` needs `{s}: {s}`: {s}", .{ inst, pname, @tagName(api), try sema.ownEqUnhashed(self.ctx, lack.ty) });
            } else try self.err(pos, "`{s}` needs `{s}: {s}`, and `{s}` {s}{s}", .{ inst, pname, @tagName(api), shown, sema.cannotDo(api), try sema.lackDetail(self.ctx, a, arg, api, lack) });
            return false;
        }
    }
    const ws = (try sema.ownerWitnesses(self.ctx, m.owner_bounds, args)) orelse return false;
    if (ws.len > 0) if (self.expect.current_call) |call| try self.ctx.record(.owner_witnesses, call, .{ .witnesses = ws, .self_arg = self_arg });
    return true;
}

/// The one diagnostic of a form that writes copies of a value it
/// leaves in place (`copy`, `fill`, `[n of x]`, `List.filled`, and
/// `resize`) when the element `elem` does not copy (docs/CORE.md §5,
/// "Only a value that copies is duplicated without `+`"), at `at`, a
/// node or a position. `what` says what the form copies, and `loop`
/// is the loop that makes each element with `+x` instead, which the
/// diagnostic offers, followed by `tail`, when `+x` clones `elem`.
pub fn notDuplicated(self: *Checker, at: anytype, what: []const u8, elem: TypeId, loop: []const u8, tail: []const u8) Error!void {
    const shown = try self.tyName(elem);
    const why = movesBecause(self, elem);
    const args = .{ what, CompatCheck.article(shown), shown, why };
    const plain = "{s}, and {s} `{s}` {s}, so it cannot be copied";
    if (sema.holdsWriteView(self.ctx, elem)) {
        if (@TypeOf(at) == Sexp) return self.errAt(at, plain, args);
        return self.err(at, plain, args);
    }
    if (sema.cloneable(self.ctx, elem) == .no) {
        const fmt = plain ++ ", and it has no clone: write a loop that makes each element anew";
        if (@TypeOf(at) == Sexp) return self.errAt(at, fmt, args);
        return self.err(at, fmt, args);
    }
    const fmt = plain ++ ": write a loop that makes each element with `+x` ({s}){s}";
    const with_loop = .{ what, CompatCheck.article(shown), shown, why, loop, tail };
    if (@TypeOf(at) == Sexp) return self.errAt(at, fmt, with_loop);
    return self.err(at, fmt, with_loop);
}

/// Why a value of `ty`, which does not copy (`sema.copies`), cannot
/// be copied, as a diagnostic says it.
pub fn movesBecause(self: *const Checker, ty: TypeId) []const u8 {
    if (sema.typeHasDropGlue(self.ctx, ty)) return "owns a resource";
    if (sema.holdsWriteView(self.ctx, ty)) return "holds a write view, which has one holder";
    if (self.ctx.types.get(ty) == .any_error) return "is owning";
    if (sema.holdsAnyError(self.ctx, ty)) return "holds an `error`, which is owning";
    return "is unique";
}

/// Every type parameter `ty` holds must meet `req` in each instance.
pub fn requireOf(self: *Checker, ty: TypeId, req: Requirement, pos: u32, op: []const u8) Error!void {
    var held: std.ArrayList(SymbolId) = .empty;
    defer held.deinit(self.ctx.allocator);
    try sema.heldTypeVars(self.ctx, ty, &held, self.ctx.allocator);
    for (held.items) |param| try ExprCheck.require(self, param, req, pos, op);
}

/// The temporary a read view of `operand` (or a slice of it) views,
/// the value itself or the value a field path starts from: it lives
/// in a slot until its statement ends. A view of a branching value
/// that may be a name's value, or a part of a temporary, would copy
/// that value into the slot, which a value that moves (an owner, or
/// a unique value such as one holding a Cell) or a write view must
/// not be: each branch is viewed instead.
pub fn viewTemp(self: *Checker, operand: Sexp) Error!void {
    return viewTempIn(self, operand, .nil);
}

/// `viewTemp` of `operand`, the object of the slice `whole` (or
/// `.nil`), which the hint writes with each branch viewed.
pub fn viewTempIn(self: *Checker, operand: Sexp, whole: Sexp) Error!void {
    const base = if (hands(self, operand).hasStorage()) StmtCheck.placeOf(self, operand).base else operand;
    if (base != .list) return;
    const ty = self.ctx.typeOf(base) orelse return;
    if (sema.moves(self.ctx, ty) == .yes or self.ctx.types.get(ty) == .write_view) if (!try viewsBranch(self, operand, whole, .read)) return;
    try self.ctx.record(.temp_drops, base, {});
}

/// A leaf of `e` that is a value a name holds, where `e` hands over
/// branches (`sema.handsOver`): a place, a part of one, or a view.
pub fn namedLeaf(self: *Checker, e: Sexp) ?Sexp {
    if (hands(self, e).kind != .branches) return null;
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    sema.valueLeaves(self.ctx.allocator, e, &leaves) catch return e;
    for (leaves.items) |leaf| if (hands(self, leaf).hasStorage()) return leaf;
    return null;
}

/// Synthesize `operand` where its value is only read (`readLeaf`).
pub fn synthReadTemp(self: *Checker, operand: Sexp) Error!TypeId {
    const ty = try PatternCheck.synthExpr(self, operand);
    if (!self.isPoison(ty)) try readLeaf(self, operand);
    return ty;
}

/// `e`, synthesized, is only read. Reading never moves a name: a
/// read passes through a branching value (`a if c else b`, `??`,
/// `catch`, `e!`, `e?`) to its leaves (`sema.valueLeaves`). A value
/// made where it is only read (a call's result, a constructor, `+x`,
/// `<x`, a block or `match` value) is a temporary: one that owns a
/// resource is dropped when its statement ends.
pub fn readLeaf(self: *Checker, e: Sexp) Error!void {
    return readLeafAs(self, e, true);
}

/// `readLeaf`, recording the use of `e` as a read only if `record_use`
/// (a handle given a write view has its use recorded as a view).
pub fn readLeafAs(self: *Checker, e: Sexp, record_use: bool) Error!void {
    // A value a header holds is taken there, not read as a temporary.
    if (e == .list and CompatCheck.sameNode(e, self.expect.held_base)) return recordUse(self, e, .take);
    if (record_use) try recordUse(self, e, .read);
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    // A branching value whose every leaf is made here is itself a
    // value made here: one temporary.
    if (hands(self, e).kind == .branches) try sema.valueLeaves(self.ctx.allocator, e, &leaves) else try leaves.append(self.ctx.allocator, e);
    for (leaves.items) |leaf| {
        const leaf_hands = hands(self, leaf);
        // A name's value, or a part of one, is read where it is.
        if (leaf_hands.hasStorage()) {
            if (leaves.items.len > 1) try self.ctx.record(.in_place_reads, leaf, {});
            continue;
        }
        if (leaf_hands.kind != .made) continue;
        // A literal, `none`, or a function lives for the whole program.
        if (leaf == .src) continue;
        const ty = self.ctx.typeOf(leaf) orelse continue;
        if (self.isPoison(ty) or sema.isReadOrWriteView(self.ctx, ty)) continue;
        // A fallible value's temporary holds what it gives on success.
        const held = switch (self.ctx.types.get(ty)) {
            .fallible => |inner| inner.ok,
            else => ty,
        };
        if (try needsCleanup(self, held, self.startOf(leaf), "leaves a temporary")) try self.ctx.record(.temp_drops, leaf, {});
    }
}

/// A fresh value (a call result, `*x`, `+x`, `<x`, ...) that owns a
/// resource, where nothing takes ownership of it.
pub fn rejectResourceTemporary(self: *Checker, operand: Sexp, ty: TypeId) Error!void {
    if (hands(self, operand).hasStorage() or !(try needsCleanup(self, ty, self.startOf(operand), "leaves a temporary"))) return;
    try self.errAt(operand, "this `{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{try self.tyName(ty)});
}

pub fn synthMember(self: *Checker, e: Sexp) Error!TypeId {
    const obj = ir.Member.object(e);
    const field_node = ir.Member.name(e);
    const field = self.text(field_node);
    const pos = srcPos(field_node, self.startOf(obj));
    const saved_in_place = self.expect.in_place;
    defer self.expect.in_place = saved_in_place;
    self.expect.in_place = obj;

    if (try CallCheck.moduleMember(self, obj, field, pos)) |ty| return ty;
    if (try numberType(self, obj)) |ty| return numberLimit(self, obj, ty, field, pos);
    if (try CallCheck.namedType(self, obj)) |nt| {
        const ty = try CallCheck.typeMember(self, nt, field, pos);
        if (nt.sym.flags.error_set and !self.isPoison(ty)) try self.ctx.record(.error_members, e, {});
        return ty;
    }
    // A field of a temporary is read where it stands, and the
    // statement drops the temporary. Taking an owning field out of it
    // is taking a part of its parent, which the ownership checker
    // rejects.
    if (!hands(self, obj).hasStorage()) return CallCheck.memberOf(self, e, obj, try synthReadTemp(self, obj));
    // A field read of a group as written reads the field's parameter
    // once the group is rewritten (`rig.GroupUse`).
    if (self.in_group_body and obj == .src) if (CallCheck.lookupQuiet(self, obj)) |id| if (self.ctx.symbols.items[id].flags.group) {
        const saved = self.expect.group_member;
        defer self.expect.group_member = saved;
        self.expect.group_member = obj.src.pos;
        const mark = self.ctx.diagnostics.items.len;
        const ty = try CallCheck.memberOf(self, e, obj, try synthOperand(self, obj));
        const read = self.ctx.diagnostics.items.len == mark and e.list.id != 0;
        try self.group_uses.append(self.ctx.allocator, .{ .group = self.ctx.symbols.items[id].decl_pos, .pos = obj.src.pos, .member = if (read) e.list.id else 0 });
        return ty;
    };
    return CallCheck.memberOf(self, e, obj, try synthOperand(self, obj));
}

/// `U8.max`, `Int.min`, `F64.max`: the greatest or least value of a
/// number type, a constant of it. A float's least is the most
/// negative finite value.
pub fn numberLimit(self: *Checker, obj: Sexp, ty: TypeId, field: []const u8, pos: u32) Error!TypeId {
    if (self.isPoison(ty)) return ty;
    if (std.mem.eql(u8, field, "min") or std.mem.eql(u8, field, "max")) return ty;
    try self.err(pos, "a number type has no member `{s}`; its limits are `{s}.min` and `{s}.max`", .{ field, CallCheck.sourceText(self, obj), CallCheck.sourceText(self, obj) });
    return self.t().invalid_id;
}

/// The number type `obj` names: a built-in one (`U8`), or an alias
/// of one (`type Byte = U8`); null for anything else.
pub fn numberType(self: *Checker, obj: Sexp) Error!?TypeId {
    if (obj.isKind(.member)) return CallCheck.importedNumberAlias(self, obj);
    if (obj != .src) return null;
    const id = CallCheck.lookupQuiet(self, obj) orelse {
        if (!resolve.isNumericTypeName(self.text(obj))) return null;
        var r = self.resolver();
        return try r.resolveType(obj);
    };
    const sym = self.ctx.symbols.items[id];
    if (sym.kind != .type_alias or !sema.isNumeric(self.ctx, sym.ty)) return null;
    try self.ctx.recordName(obj, id);
    return sym.ty;
}

/// The instance of generic `sym_id` at `args`, checked like a spelled
/// one: the built-in generics' element rules, and every generic's
/// requirements (through its instantiation site).
pub fn instantiate(self: *Checker, gref: SymbolRef, args: []const TypeId, pos: u32) Error!TypeId {
    if (gref == self.ctx.builtins.simd) return resolve.simdInstance(self.ctx, args, pos);
    if (gref == self.ctx.builtins.slot) return resolve.slotInstance(self.ctx, args, pos);
    if (self.ctx.owns(gref)) if (try resolve.builtinElementError(self.ctx, gref.sym, args)) |msg| try self.err(pos, "{s}", .{msg});
    const ty = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = gref, .args = try self.ctx.dupeIds(args) } });
    if (!sema.containsTypeVar(self.ctx, ty)) {
        const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
        if (!gop.found_existing) {
            gop.value_ptr.* = pos;
            // An instance first made here, in an expression, is checked
            // as a written one is (`resolve`'s `instance_stacking`).
            try sema.checkInstanceStacked(self.ctx, ty, pos);
        }
    } else try self.ctx.addUse(ty, StdFormCheck.bodyRef(self), pos);
    return ty;
}

/// `module.function(args)` or `module.Type(fields)`.
pub fn crossModuleCall(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const module_name = self.ctx.symbols.items[module_sym].name;
    const found = (try CallCheck.foreignSymbol(self, module_sym, name, pos)) orelse return CallCheck.skipCall(self, args);
    const qualified = try self.ctx.arena.allocator().print("{s}.{s}", .{ module_name, name });
    switch (found.sym.kind) {
        .type_alias => return StdFormCheck.aliasCall(self, self.expect.current_call orelse Sexp.nil, self.expect.callee_node orelse Sexp.nil, qualified, try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id), args, pos),
        .function, .@"extern" => {
            const local = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
            const fty = self.ctx.types.get(local);
            if (fty != .function) return CallCheck.badCall(self, args, pos, "`{s}` cannot be called", .{qualified});
            var info = CallCheck.paramsOf(found.sym, found.ctx.source);
            info.waits = sema.duration.waits(found.ctx, name);
            const f = (try CallCheck.instantiateCall(self, fty.function, ct, args, info, 0, qualified, pos, false, .empty)) orelse return CallCheck.skipCall(self, args);
            if (found.sym.kind == .function) try StdFormCheck.noteTarget(self, found.module_id, found.sym.decl_pos, found.sym.flags.inline_marked, .empty);
            // A generic function's callee has the instance's signature.
            try StdFormCheck.noteCallee(self, f);
            self.expect.view_call = true;
            const mark = self.ctx.diagnostics.items.len;
            try CallCheck.checkArgs(self, args, f, info, qualified, pos, .{ .origins = found.sym.origins, .declared = fty.function.params });
            // `time.duration` of a form that cannot fail gives the
            // plain `Duration` (docs/design/datetime.md §5.2), unwrapped
            // as a maker's call of constants is (`sema.ConstMaker`); one
            // whose form has an error of its own asks for no `!` besides.
            if (sema.duration.isMaker(found.ctx, name) and self.ctx.diagnostics.items.len > mark) return self.t().invalid_id;
            if (sema.duration.isMaker(found.ctx, name)) if (self.expect.current_call) |call| if (!StdFormCheck.formFolds(self, call, args) and ir.Call.task(call) == .nil) {
                try self.ctx.record(.const_makers, call, {});
                return switch (self.ctx.types.get(f.returns)) {
                    .fallible => |fl| fl.ok,
                    else => f.returns,
                };
            };
            return f.returns;
        },
        .nominal_type => if (ct == null) return CallCheck.construct(self, found.id, args, pos, TypeSubst.empty, .{ .ctx = found.ctx, .module_id = found.module_id }) else return CallCheck.badCall(self, args, ct.?, "`{s}` is not a generic type; it takes no type arguments", .{qualified}),
        .generic_type => {
            const nt = try CallCheck.foreignGeneric(self, found);
            return StdFormCheck.constructGeneric(self, self.expect.callee_node orelse Sexp.nil, nt.ref(self.ctx), args, qualified, pos);
        },
        else => return CallCheck.badCall(self, args, pos, "`{s}` cannot be called", .{qualified}),
    }
}

/// Whether `node` is the `?p`, `!p`, or `<p` of `?p.m(...)`,
/// `!p.m(...)`, or `<p.m(...)`, written before the call rather than
/// in parentheses.
pub fn isSelfSigil(self: *Checker, node: Sexp) bool {
    const p = self.ctx.parser orelse return false;
    return p.marked(.self_sigil, node);
}

/// `?p.m(...)`, `!p.m(...)`, or `<p.m(...)` where `m` takes no
/// self the sigil could apply to.
pub fn misplacedSigil(self: *Checker, recv: Sexp, method: []const u8, why: []const u8) Error!void {
    try self.errAt(recv, "`{s}` {s}; remove the `{s}`", .{ method, why, CompatCheck.sigilText(recv) });
}

/// `!p.f(...)` or `<p.f[i](...)`, where `f` is a field holding
/// functions: there is no self for the sigil. A `!` before a call
/// whose value is a `Bool` was meant as negation.
pub fn fieldCallSigil(self: *Checker, recv: Sexp, field: []const u8, what: []const u8, fn_ty: TypeId) Error!void {
    const returns: ?TypeId = if (sema.ownedClosureFn(self.ctx, fn_ty)) |f| f.returns else switch (self.ctx.types.get(sema.unwrapViews(self.ctx, fn_ty))) {
        .function => |f| f.returns,
        else => null,
    };
    if (recv.isKind(.write) and returns == self.t().bool_id) {
        return self.errAt(recv, "`{s}` is {s}, not a method that takes `self`; for negation use `not`", .{ field, what });
    }
    if (recv.isKind(.read)) return self.errAt(recv, "`{s}` is {s}, not a method that takes `self`; remove the `?`, or make a view of the call's result with `?({s})`", .{ field, what, try FlowCheck.callWith(self, recv, CallCheck.sourceText(self, ir.Read.operand(recv)), field) });
    try self.errAt(recv, "`{s}` is {s}, not a method that takes `self`; remove the `{s}`", .{ field, what, CompatCheck.sigilText(recv) });
}

/// `?p.m(...)`, `!p.m(...)`, and `<p.m(...)` (see
/// `Parser.selfSigil`): the sigil is the self mode of `m`, so
/// a `!` before a method that only reads is the habit of `!` as
/// negation, and a `!` call whose `Bool` value is used is written
/// `(!p).m(...)` so it never reads as one: a `!` is rejected wherever
/// reading it as `not` would also type-check. `returns` is the result
/// with self's type arguments applied, so `!flags.remove(0)` on a
/// `List[Bool]` is a `Bool`, while inside a generic body, where they
/// are parameters, a `T` stays a `T`. A `?` spells out the read self
/// a call takes anyway. Returns whether it reported an error.
pub fn checkSelfSigil(self: *Checker, recv: Sexp, mode: SelfMode, returns: TypeId, method: []const u8) Error!bool {
    if (!isSelfSigil(self, recv)) return false;
    const place = ir.get(recv, .operand);
    const at = self.ctx.span(place);
    const name = diag.textOf(self.ctx.source, at);
    if (recv.isKind(.read)) {
        if (mode == .read) return false;
        const hint = if (returns == self.t().void_id) "" else try self.ctx.arena.allocator().print("; to make a view of the call's result, write `?({s})`", .{try FlowCheck.callWith(self, recv, name, method)});
        if (mode == .write) {
            try self.errAt(recv, "`{s}` writes `self`: write `{s}`{s}", .{ method, try FlowCheck.writeCallText(self, recv, method, returns), hint });
        } else try self.errAt(recv, "`{s}` consumes `self`: write `{s}`{s}", .{ method, try FlowCheck.callWith(self, recv, try self.ctx.arena.allocator().print("<{s}", .{name}), method), hint });
    } else if (recv.isKind(.write)) switch (mode) {
        .write => {
            if (!FlowCheck.usesValue(self, recv, returns)) return false;
            // `!(!b).m(...)` whose value is used: self is a write
            // view already, so the outer `!` is the one to remove,
            // not to parenthesize.
            if (place.isKind(.write)) {
                const viewed = CallCheck.sourceText(self, ir.get(place, .operand));
                const call = if (self.expect.current_call) |c| try spliced(self, c, &.{recv}, &.{CallCheck.sourceText(self, recv)[1..]}) else try self.ctx.arena.allocator().print("(!{s}).{s}(...)", .{ viewed, method });
                try self.errAt(recv, "`(!{s})` already makes a write view of `{s}`: remove the outer `!` and write `{s}`", .{ viewed, viewed, call });
                return true;
            }
            if (!FlowCheck.isBoolResult(self, returns)) return false;
            const long = try self.ctx.arena.allocator().print("({s})", .{CallCheck.sourceText(self, recv)});
            const call = if (self.expect.current_call) |c| try spliced(self, c, &.{recv}, &.{long}) else try self.ctx.arena.allocator().print("{s}.{s}(...)", .{ long, method });
            // Under `not` the negation is meant: only its long form.
            if (self.expect.current_call) |c| if (CompatCheck.sameSite(c, self.expect.not_operand)) {
                try self.errAt(recv, "`!` makes a write view of `{s}` and never negates: write `not {s}`", .{ name, call });
                return true;
            };
            try self.errAt(recv, "`!` makes a write view of `{s}` and never negates: write `{s}` for what `{s}` returns, or `not {s}` for its opposite", .{ name, call, method, call });
        },
        else => if (returns == self.t().bool_id) {
            try self.errAt(recv, "`{s}` does not write `self`; for negation use `not`", .{method});
        } else try self.errAt(recv, "`{s}` does not write `self`; remove the `!`", .{method}),
    } else switch (mode) {
        .value => return false,
        .write => try self.errAt(recv, "`{s}` does not consume `self`; it writes it: `{s}`, and its result needs no `<`", .{ method, try FlowCheck.writeCallText(self, recv, method, returns) }),
        else => try self.errAt(recv, "`{s}` does not consume `self`; remove the `<`: a call's result moves without it", .{method}),
    }
    return true;
}

/// Whether a write self `recv` of kind `kind` is a write view,
/// which a write method writes through.
pub fn writesThrough(self: *Checker, recv: Sexp, kind: CompatCheck.SelfTypeKind) bool {
    if (kind == .write_view) return true;
    const ty = self.ctx.typeOf(recv) orelse return false;
    return self.ctx.types.get(ty) == .write_view;
}

/// A write method called on a temporary (a value made here, a part
/// of one, or a branching value made in every branch) with no `!`:
/// every change is marked by `!` (Core sentences 4 and 9), which
/// makes a write view of the temporary.
pub fn writeOfTemporary(self: *Checker, recv: Sexp, method: []const u8, returns: TypeId) Error!void {
    const shown = try plainText(self, recv);
    const a = self.ctx.arena.allocator();
    const viewed = if (sigilReaches(recv)) try a.print("!{s}", .{shown}) else try a.print("!({s})", .{shown});
    const call = try FlowCheck.callWith(self, recv, if (FlowCheck.parenthesized(self, recv, returns)) try a.print("({s})", .{viewed}) else viewed, method);
    // A `!` that is there but does not reach self.
    const outer = self.expect.outer_write;
    if (outer.isKind(.call) and CompatCheck.sameNode(ir.Call.callee(outer), self.expect.self_of)) {
        return self.errAt(recv, "`{s}` changes `self`, a temporary no name holds; the `!` here makes a write view of what `{s}` returns, not of `self`: write `{s}`", .{ method, method, call });
    }
    try self.errAt(recv, "`{s}` changes `self`, a temporary no name holds; add `!`: `{s}`", .{ method, call });
}

/// Whether `!` written before `recv` followed by a method call views
/// `recv` as self (self-sigil rule, `rig.Parser`): a
/// postfix chain with no method call in it, or else `recv` must be
/// parenthesized (`!(+s).bump()`, `!(a.make()).bump()`).
pub fn sigilReaches(recv: Sexp) bool {
    switch (recv.kind() orelse return true) {
        .call, .member, .index, .inst, .array => {},
        else => return false,
    }
    var p = recv;
    while (true) switch (p.kind() orelse return true) {
        .member, .index, .inst => p = ir.get(p, .object),
        .call => return !rig.isMethodCallee(ir.Call.callee(p)),
        else => return true,
    };
}

/// Whether `e`, a value that branches, is a write view: each of its
/// branches is a write view (`!a if c else !b`), a handle included.
pub fn isWriteViewValue(self: *Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return self.ctx.types.get(ty) == .write_view;
}

/// Why a self that changes through a shared handle is marked, for
/// a diagnostic that asks for the mark; empty for any other self.
pub fn markNote(self: *Checker, recv: Sexp) []const u8 {
    const ty = self.ctx.typeOf(recv) orelse return "";
    if (!sema.changesByMark(self.ctx, ty)) return "";
    const held = sema.unwrapAccess(self.ctx, ty);
    if (sema.chanValue(self.ctx, held) != null) return ": a channel changes as it sends and receives, and a change through a shared handle is marked with `!`";
    return switch (self.ctx.types.get(held)) {
        .parameterized_nominal => |pn| if (pn.sym == self.ctx.builtins.cell)
            ": changing a shared Cell is marked with `!`"
        else if (pn.sym == self.ctx.builtins.signal)
            ": changing a shared Signal is marked with `!`"
        else
            ": changing a Cell it holds is marked with `!`",
        else => ": changing a Cell it holds is marked with `!`",
    };
}

/// Self rules: `?@` is viewed implicitly; `!@` needs an explicit
/// `!x.m()`; a consuming `<@` needs an explicit `<x.m()`. Write and
/// consuming selves are refused through `?T` and `*T`.
pub fn checkSelfMode(self: *Checker, recv: Sexp, mode: SelfMode, kind: CompatCheck.SelfTypeKind, method: []const u8, pos: u32, returns: TypeId) Error!void {
    const shape = selfShape(self, recv);
    switch (mode) {
        .read => if (shape == .move_explicit) {
            try self.err(pos, "method `{s}` takes `self` as a read view; cannot move", .{method});
        } else if (self.ctx.typeOf(recv)) |ty| {
            _ = try writeViewRead(self, recv, ty, .{ .read_self = method });
        },
        .write => {
            if (kind == .read_view) return self.err(pos, "method `{s}` needs a write view of `self`; a read view cannot become a write view", .{method});
            if (kind == .shared and !sema.changesByMark(self.ctx, self.ctx.typeOf(recv) orelse sema.type_invalid)) return self.err(pos, "cannot call method `{s}`, which writes `self`, through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.", .{method});
            switch (shape) {
                .write_explicit => {},
                // A value made here, or a part of one, is a temporary
                // no name holds, which a write method changes only
                // where `!` views it (`!mk().bump()`). A write view
                // made here writes through.
                .made => if (!writesThrough(self, recv, kind)) try writeOfTemporary(self, recv, method, returns),
                // A branch that is a write view writes through it; one
                // that is a name's value would be written as a copy.
                // (One that owns a resource is reported as a temporary
                // nothing drops.)
                .branches => if (kind != .write_view and !isWriteViewValue(self, recv) and !ownsResource(self, recv)) {
                    const leaf = namedLeaf(self, recv) orelse recv;
                    try self.errAt(recv, "method `{s}` writes `self`, and `{s}` may be `{s}`, a value a name holds, which the call would write as a copy; call `{s}` on the name in each branch", .{ method, CallCheck.sourceText(self, recv), CallCheck.sourceText(self, leaf), method });
                },
                .read_explicit => try self.err(pos, "method `{s}` needs a write view of `self`, not a read view; write `{s}`{s}", .{ method, try FlowCheck.writeCallText(self, recv, method, returns), markNote(self, recv) }),
                .move_explicit => try self.err(pos, "method `{s}` needs a write view of `self`, not a move; write `{s}`", .{ method, try FlowCheck.writeCallText(self, recv, method, returns) }),
                // A binding that already holds a write view (`x: !T`,
                // `!@`) passes it on visibly too.
                .place => if (kind != .write_view and hands(self, recv).kind == .part_of_made) {
                    try writeOfTemporary(self, recv, method, returns);
                } else if (kind != .write_view) {
                    try self.err(pos, "method `{s}` needs a write view of `self`; write `{s}`{s}", .{ method, try FlowCheck.writeCallText(self, recv, method, returns), markNote(self, recv) });
                } else {
                    const name = CallCheck.sourceText(self, recv);
                    try self.errAt(recv, "write `{s}`: the call writes `{s}`", .{ try FlowCheck.writeCallText(self, recv, method, returns), name });
                },
            }
        },
        .value => {
            switch (kind) {
                // A view of a value that copies is copied out, as
                // where a value is expected (Core §4).
                .read_view, .write_view => if (!copiesThrough(self, recv)) {
                    // An API object's view: only its box gives the
                    // value up.
                    if (self.ctx.typeOf(recv)) |rt| if (sema.objectHeld(self.ctx, sema.unwrapViews(self.ctx, rt)) orelse sema.objectHeld(self.ctx, rt)) |ov| {
                        const call = CallCheck.sourceText(self, self.expect.current_call orelse recv);
                        const box = try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), ov.object);
                        return self.err(pos, "`{s}{s}` consumes self, and `{s}` is a `{s}`, a view: only a box, `^{s}`, gives its value up", .{ if (std.mem.startsWith(u8, call, "<")) "" else "<", call, CallCheck.sourceText(self, CompatCheck.stripSigil(recv)), try self.tyName(rt), box });
                    };
                    return self.err(pos, "method `{s}` consumes `self`; cannot consume through a view", .{method});
                },
                .shared => return self.err(pos, "method `{s}` consumes `self`; cannot consume the inner value through a shared handle (`*T`) — other handles may still reference it", .{method}),
                else => {},
            }
            switch (shape) {
                // A branching value is taken leaf by leaf: a name
                // there is moved with `<` (the ownership checker).
                .move_explicit, .made, .branches => {},
                .read_explicit, .write_explicit => try self.err(pos, "method `{s}` consumes `self`; a view cannot give it up; write `{s}`", .{ method, try FlowCheck.callWith(self, recv, try self.ctx.arena.allocator().print("<{s}", .{try plainText(self, selfPlace(recv))}), method) }),
                // A place whose value copies is read, as an argument
                // is: the call takes a copy (Core sentence 1).
                .place => if (!copiesValue(self, recv) and !copiesThrough(self, recv)) switch (sema.moveSource(self.ctx, recv)) {
                    .binding, .capture => try self.err(pos, "method `{s}` consumes `self`; write `{s}`", .{ method, try FlowCheck.callWith(self, recv, try self.ctx.arena.allocator().print("<{s}", .{CallCheck.sourceText(self, recv)}), method) }),
                    .made_part => try self.errAt(recv, "method `{s}` consumes `self`, and `{s}` is a part of a temporary its statement drops; bind the value to a name first", .{ method, CallCheck.sourceText(self, recv) }),
                    else => try self.errAt(recv, "method `{s}` takes its self with `<@`, and `<` cannot move `{s}` out of the value that holds it; exchange it out first: `swap(!{s}, v).{s}(...)`", .{ method, CallCheck.sourceText(self, recv), CallCheck.sourceText(self, recv), method }),
                },
            }
        },
        .none => {},
    }
}

pub fn checkExpr(self: *Checker, e: Sexp, expected: TypeId) Error!void {
    try checkExprAgainst(self, e, expected);
    // A branching value, or a path from one, that goes where it
    // stands as a view is viewed there (`viewedInPlace`); a function's
    // result hands its views to the caller.
    if (viewedBranch(e) == .nil or StmtCheck.isReturnLeaf(self, e)) return;
    if (viewedInPlace(self, e, expected)) |kind| _ = try viewsBranch(self, e, .nil, kind);
}

/// How `e`, checked against `expected`, goes where it stands as a
/// view, by a positive list: passed on to write where a write view goes
/// (bound, passed, or stored as one), and viewed to read where a read
/// view goes (`?T`, `[]T`, `?String`) and it is read in place
/// (`readsInPlace`). Null where it is copied or read as a value.
pub fn viewedInPlace(self: *Checker, e: Sexp, expected: TypeId) ?Checker.ViewKind {
    if (self.isPoison(expected)) return null;
    return switch (self.ctx.types.get(liftTarget(self, expected))) {
        .write_view => .write,
        .read_view, .slice, .string_view => if (readsInPlace(self, e)) .read else null,
        else => null,
    };
}

/// Whether a branching value `e`, or a path from one (`viewedBranch`),
/// is read where it stands when a view of it is used: a leaf of the
/// branch (`sema.valueLeaves`) is a write view, which narrows, or a
/// value that is no view. A branch whose every leaf is a read view (a
/// `?T`, a `[]T`, a `?String`, or an optional of one) copies the view it
/// takes, so it is read as a value.
pub fn readsInPlace(self: *Checker, e: Sexp) bool {
    const root = viewedBranch(e);
    if (root == .nil) return false;
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    sema.valueLeaves(self.ctx.allocator, root, &leaves) catch return true;
    for (leaves.items) |leaf| {
        const ty = self.ctx.typeOf(leaf) orelse continue;
        switch (self.ctx.types.get(liftTarget(self, ty))) {
            .read_view, .slice, .string_view, .static, .none_literal, .noreturn, .invalid, .unknown => {},
            else => return true,
        }
    }
    return false;
}

pub fn checkExprAgainst(self: *Checker, e: Sexp, expected: TypeId) Error!void {
    try checkExprAgainstType(self, e, expected);
    if (self.ctx.typeOf(e)) |actual| try recordLift(self, e, actual, expected);
}

pub fn checkExprAgainstType(self: *Checker, e: Sexp, expected: TypeId) Error!void {
    // A value checked against the type its context gives it is taken
    // there: a typed binding, an argument, a field, an element, a
    // result.
    try recordUse(self, e, .take);
    if (e == .list and self.ctx.quiet == 0) try self.expected.put(self.ctx.allocator, CompatCheck.nodeId(e), expected);
    const prev_viewed = self.expect.viewed_write;
    defer self.expect.viewed_write = prev_viewed;
    if (e.isKind(.write) and self.ctx.types.get(expected) == .write_view) self.expect.viewed_write = e;
    const saved_result = self.expect.result_expected;
    defer self.expect.result_expected = saved_result;
    if (CompatCheck.resultCall(e)) |call| self.expect.result_expected = .{ .call = call, .ty = expected, .value = e };
    // A poisoned expected type still reaches a generic call's
    // inference, which then reports nothing more.
    if (self.isPoison(expected)) {
        // `[]` has no type of its own to report on.
        if (e.isKind(.array) and ir.Array.elems(e).len == 0) return;
        const saved = self.expect.under_poison;
        defer self.expect.under_poison = saved;
        self.expect.under_poison = true;
        _ = try PatternCheck.synthExpr(self, e);
        return;
    }
    if (e.isKind(.template)) return StdFormCheck.checkTemplateAgainst(self, e, expected);
    if (try viewedTempLiteral(self, e, expected)) return;
    // A variant literal where a view held by address goes is the value
    // `E.v(...)` is, which goes there as that value goes.
    const viewed = try variantUnderView(self, e, expected);
    if (try checkContextual(self, e, viewed orelse expected)) |ty| {
        if (try PatternCheck.cellMadeAway(self, e, ty)) return self.ctx.recordType(e, self.t().invalid_id);
        try self.ctx.recordType(e, ty);
        if (self.isPoison(ty)) return;
        // A member of a set without fields (`.name`, `checkShortForm`)
        // where one that may carry them goes becomes an error value,
        // as `E.name` does there.
        if (viewed == null) return recordCodeWidening(self, e, ty, expected);
        return checkActual(self, e, ty, expected);
    }

    return checkActual(self, e, try PatternCheck.synthExpr(self, e), expected);
}

/// `e`, of type `actual` (`synthExpr`), where `expected` goes: adapted
/// or viewed as it, or reported.
pub fn checkActual(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    // A written `!x` where a read view goes only reads.
    if (readViewSlot(self, expected) and try writeViewRead(self, e, actual, .{ .read_view = expected })) return;
    const into = erasureTarget(self, actual, expected);
    if (try viewByRows(self, e, actual, into)) return;
    if (try arrayAsSlice(self, e, actual, expected)) return;
    if (try stringAsStringView(self, e, actual, expected)) return;
    if (self.ctx.types.get(expected) == .function and sema.callableFnTy(self.ctx, actual) == expected) {
        return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; a view of a closure goes to a parameter declared `{s}`", .{ try self.tyName(expected), try self.tyName(actual), try self.tyName(actual) });
    }
    if (CompatCheck.compatible(self.ctx, actual, expected)) {
        try recordAdapted(self, e, actual, expected);
        return;
    }
    if (try eraseBox(self, e, actual, into)) return;
    if (try eraseShared(self, e, actual, into)) return;
    if (try handleThroughView(self, e, actual, into)) return;
    // Failing is written: an error value meets a `T!` only as the
    // operand of `return`.
    if (self.ctx.types.get(expected) == .fallible and sema.isErrorValue(self.ctx, actual)) {
        if (StmtCheck.isReturnLeaf(self, e)) return ExprCheck.checkReturnedError(self, e, actual, expected);
        return self.errAt(e, "an error value meets `{s}` only as the operand of `return`: write `return {s}`", .{ try self.tyName(expected), CallCheck.sourceText(self, e) });
    }
    // A fallible call where its value is expected: `synthCall`
    // reported the missing `!` / `catch`.
    const at = self.ctx.types.get(actual);
    if (at == .fallible and CompatCheck.compatible(self.ctx, at.fallible.ok, expected)) return;
    if (CompatCheck.sameExpr(e, self.expect.ignored_in)) return;
    if (CompatCheck.resultCall(e)) |call| if (call.list.id != 0) if (self.result_hints.get(call.list.id)) |hint| {
        return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; {s}", .{ try self.tyName(expected), try self.tyName(actual), hint });
    };
    // Only a value that copies is copied out of a view (`copiedOut`).
    switch (at) {
        .read_view, .write_view => |inner| if (CompatCheck.compatible(self.ctx, inner, expected)) {
            if (try PatternCheck.payloadViewTaken(self, e, "move")) return;
            // A bounded `T` copies only where its bounds name `Copy`.
            switch (self.ctx.types.get(inner)) {
                .type_var => |param| if (sema.checkedByBounds(sema.symbolAt(self.ctx, param).*))
                    return GenericCheck.reportUnbounded(self.ctx, self.startOf(e), self.ctx.localSym(param), .Copy, "a copy"),
                else => {},
            }
            const name = try self.tyName(inner);
            const why = if (sema.copies(self.ctx, inner) == .depends) "may not copy in every instance" else movesBecause(self, inner);
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; only a value that copies is copied out of a view, and `{s}` {s}: pass it on as a view where it goes (`?{s}` or `!{s}`)", .{ try self.tyName(expected), try self.tyName(actual), name, why, name, name });
        },
        else => {},
    }
    // An array or a slice viewed where a view of a List goes: a slice
    // views either.
    if (self.ctx.types.get(expected) == .read_view) if (sema.listElem(self.ctx, self.ctx.types.get(expected).read_view)) |elem| {
        const given: ?TypeId = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, actual))) {
            .array => |a| a.elem,
            .slice => |sl| sl.elem,
            else => null,
        };
        if (given == elem) {
            const shown = try self.tyName(elem);
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; a `{s}` views a List alone: declare `[]{s}`, which views an array or a List", .{ try self.tyName(expected), try self.tyName(actual), try self.tyName(expected), shown });
        }
    };
    // A number is a duration form only as an argument of a call that
    // names its function (`sema.duration`).
    if (sema.durationParam(self.ctx, expected) != null and sema.isNumeric(self.ctx, actual)) {
        const shown = try plainText(self, e);
        return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; a number is a duration only as an argument of a call that names its function: write `time.duration({s})`", .{ try self.tyName(expected), try self.tyName(actual), shown });
    }
    try mismatch(self, e, expected, actual);
}

/// The set an error of set `from` widens to where a read view of it
/// goes, `?S` of a set or union `S` that holds `from`, when neither
/// has fields: a code, which copies and is viewed by value, with no
/// temporary to outlive. Null for any other (`mismatch` says how to
/// view it).
pub fn widenedError(self: *Checker, from: TypeId, expected: TypeId) ?TypeId {
    const want = unionViewed(self, from, expected) orelse return null;
    return if (!sema.setHasFields(self.ctx, from) and !sema.setHasFields(self.ctx, want)) want else null;
}

/// The set or union `S` of a `?S` that `expected` is, which holds
/// the other set `from`; null for any other.
pub fn unionViewed(self: *Checker, from: TypeId, expected: TypeId) ?TypeId {
    if (!sema.isErrorSet(self.ctx, from)) return null;
    const want = switch (self.ctx.types.get(expected)) {
        .read_view => |inner| inner,
        else => return null,
    };
    if (want == from or !sema.isErrorSet(self.ctx, want)) return null;
    return if (sema.errorSubset(self.ctx, from, want)) want else null;
}

/// An array literal or fill viewed as a `[]T` argument: its elements
/// take the slice's element type. True when handled.
pub fn viewedTempLiteral(self: *Checker, e: Sexp, expected: TypeId) Error!bool {
    if (!e.isKind(.array) and !e.isKind(.array_fill)) return false;
    if (!CompatCheck.sameNode(e, self.expect.viewed_temp)) return false;
    const elem = switch (self.ctx.types.get(expected)) {
        .slice => |sl| sl.elem,
        else => return false,
    };
    const synth = try FlowCheck.synthQuiet(self, e);
    const len = switch (self.ctx.types.get(synth)) {
        .array => |a| a.len,
        else => return false,
    };
    const array = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
    try checkExpr(self, e, array);
    try viewTempArray(self, e, array, expected);
    return true;
}

/// `e`, of type `actual`, where a view of type `expected` goes, viewed
/// by the rows of the view table that make it (`sema.viewAs`): from
/// a view written here (`?a`, `!b`), a view `e` already is (a `?String`
/// a call returns, a held `![]T`), or a function. True when handled.
pub fn viewByRows(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const kind: sema.ViewKind, var from: TypeId = switch (self.ctx.types.get(actual)) {
        .read_view => |inner| .{ .read, inner },
        .write_view => |inner| .{ .write, inner },
        else => .{ .read, actual },
    };
    // An error where a view of a set or union that holds it goes is a
    // value of that set, viewed as one is: `m.get(B.y)` for a
    // `Map[L, Int]` of `error L = A | B`.
    if (kind == .read and actual == from) if (widenedError(self, from, expected)) |set| {
        try recordCodeWidening(self, e, from, set);
        from = set;
    };
    // A slice argument is viewed the way its name is: `total(w[1..3])`
    // is `total(?w[1..3])`, whose slice `synthSlice` made, so the
    // view goes where its own type does.
    const sliced = CallCheck.slicedArg(self, e);
    var made = (if (sliced) CompatCheck.sliceArgView(self.ctx, actual, expected) else sema.viewAs(self.ctx, from, kind, expected)) orelse
        return sliced and try sliceArgRejected(self, e, actual, expected);
    // `!h` of a handle views the handle itself where a `!*T` goes, and
    // makes a write view of the value it holds where the view goes
    // through the handle (`recordLoan`).
    if (e.isKind(.write) and !sliced) switch (self.ctx.types.get(from)) {
        .shared => |inner| try self.ctx.record(.loans, e, if (made.has(.handle)) sema.loanOfView(self.ctx, inner) else .write),
        else => {},
    };
    const view = sema.isReadOrWriteView(self.ctx, actual);
    // A bare value where a view argument goes is viewed to read where
    // it is, as `?e` would view it (Core sentence 1): a place, or a
    // value made here, which its statement holds. A function views
    // itself.
    const function = made.callable() != null and self.ctx.types.get(from) == .function and !closureBinding(self, e);
    // (A temporary array viewed as a `[]T` by a call that keeps no view
    // of it lives in a slot of the call: `arrayAsSlice`.)
    const temp_array = CompatCheck.sameNode(e, self.expect.viewed_temp) and self.ctx.types.get(from) == .array;
    if (!view and CompatCheck.sameExpr(e, self.expect.view_arg) and !function and !temp_array) {
        switch (hands(self, e).kind) {
            .place, .part_of_made, .made => {},
            .view, .branches, .jump, .none => return false,
        }
        // A slice held its own temporary, as `?xs[a..b]` does; a code
        // views a constant, which no temporary holds, unless a handle
        // or a box made here holds the code (`*X.one`): its statement
        // holds that, and drops it.
        if (!sliced and !made.codeAlone()) try checkReadView(self, e);
        if (made.has(.erase) and !try erase(self, e, actual, from, made)) return true;
        made.implicit = true;
        try self.ctx.record(.uses, e, .view);
        try self.ctx.recordView(e, made);
        return true;
    }
    // `?x` where a `(?T)?` is expected is a view the context admits as
    // it is.
    if (made.onlyLifts()) return false;
    if (made.callable() != null) {
        if (sema.ownedClosureFn(self.ctx, from) != null and !view) {
            // The handle is viewed from its binding; reported once.
            const place = switch (e.kind() orelse .lambda) {
                .move, .clone => ir.get(e, .operand),
                else => e,
            };
            if (hands(self, place).hasStorage()) {
                try self.errAt(e, "an owned closure is passed to a `{s}` parameter as a view: write `?{s}`", .{ try self.tyName(expected), CallCheck.sourceText(self, place) });
            } else try self.errAt(e, "an owned closure is passed to a `{s}` parameter as a view of a binding: bind it first (`cb = ...`), then pass it with `?cb`", .{try self.tyName(expected)});
            try self.ctx.recordType(e, self.t().invalid_id);
            return true;
        }
    } else if (made.has(.read_only)) {
        try recordAdapted(self, e, actual, expected);
    } else {
        // Every other row views a value written `?x` or `!x` here, or
        // what a view `e` already is views.
        if (!view) return false;
        // A String made here is a temporary its statement drops.
        if (made.has(.text) and e.isKind(.read) and !StmtCheck.placeOf(self, ir.Read.operand(e)).named()) try viewTemp(self, ir.Read.operand(e));
        // A view written here of an array's or a String's own elements
        // is the view it makes.
        if (e.isKind(.read) or e.isKind(.write)) for (made.steps()) |step| switch (step) {
            .lift => {},
            .elems => try self.ctx.recordType(e, expected),
            .text => try self.ctx.recordType(e, self.t().string_view_id),
            else => break,
        };
        if (made.has(.erase) and !try erase(self, e, actual, from, made)) return true;
    }
    try self.ctx.recordView(e, made);
    return true;
}

/// The type a value of `actual` is erased into where `expected` goes:
/// `expected`, or, for a value that is no `T!` (a result's last
/// expression, `return`'s operand, `f()!`), the value a `(^{A})!`,
/// `(*{A})!`, or `(?{A})!` holds, which the value meets as it is.
/// The one place every erasure (`viewByRows`, `eraseBox`,
/// `eraseShared`, `handleThroughView`) reads through a `!`; an
/// optional is each one's own row.
pub fn erasureTarget(self: *Checker, actual: TypeId, expected: TypeId) TypeId {
    const types = self.ctx.types;
    const ok = switch (types.get(expected)) {
        .fallible => |f| f.ok,
        else => return expected,
    };
    if (types.get(actual) == .fallible or sema.isErrorValue(self.ctx, actual)) return expected;
    return if (self.ctx.typeInfo(ok).object) ok else expected;
}

pub fn heldInto(self: *Checker, actual: TypeId, expected: TypeId, form: sema.ObjectForm) ?Checker.HeldInto {
    const types = self.ctx.types;
    if (self.isPoison(actual)) return null;
    const want = switch (types.get(expected)) {
        .optional => |inner| inner,
        else => expected,
    };
    const h = sema.objectHeld(self.ctx, want) orelse return null;
    if (h.form != form) return null;
    const optional = types.get(actual) == .optional;
    if (optional and want == expected) return null;
    return .{ .want = want, .object = h.object, .optional = optional, .value = if (optional) types.get(actual).optional else actual };
}

/// `e`, of type `actual`, erased to an API object by the rows of
/// `made` from `from` (docs/design/apis.md, Stage 4): the value they
/// reach provides the object's API, by a witness, and meets the
/// built-in APIs its braces name, where the type is still known.
/// Recorded once (`sema.Erasure`), with whether the object views a
/// copy, a local of the erasing block: of a read view `e` holds of
/// plain data or of a type parameter's value, which may have no
/// address of its own. False after reporting.
pub fn erase(self: *Checker, e: Sexp, actual: TypeId, from: TypeId, made: sema.View) Error!bool {
    const types = self.ctx.types;
    var reached = from;
    var view = made.ty;
    var only_erase = true;
    for (made.steps()) |step| switch (step) {
        .lift => view = types.get(view).optional,
        .optional => {
            reached = types.get(reached).optional;
            view = types.get(view).optional;
            only_erase = false;
        },
        .unbox => {
            reached = sema.boxedType(self.ctx, reached) orelse return true;
            only_erase = false;
        },
        .handle => {
            const inner = types.get(reached).shared;
            reached = sema.frozenValue(self.ctx, inner) orelse inner;
            only_erase = false;
        },
        .erase => break,
        else => only_erase = false,
    };
    if (reached == types.int_literal_id) reached = types.int_id;
    if (reached == types.float_literal_id) reached = types.float_id;
    if (self.isPoison(reached)) return false;
    const ov = sema.objectView(self.ctx, view) orelse return true;
    const viewed = if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e;
    const witness = (try erasable(self, e, viewed, actual, reached, view, ov.object)) orelse return false;
    // A read view `e` holds, of plain data or of a type parameter's
    // value, may be a copy with no address of its own: the object
    // views a copy, a local of the erasing block.
    const held = self.ctx.typeOf(viewed) orelse actual;
    const copy = only_erase and ov.form == .read and switch (self.ctx.types.get(held)) {
        .read_view => |inner| self.ctx.types.get(inner) == .type_var or sema.holdsNoLoanButText(self.ctx, inner),
        else => false,
    };
    try self.ctx.record(.erasures, e, .{ .api = ov.object.api, .from = reached, .view = view, .witness = witness, .form = ov.form, .copy = copy });
    return true;
}

/// `e`, a box `^T` (or a `^T?`) moved where a box of an API object
/// goes, `^{A}` (or `^{A}?`): the box keeps its allocation, and its
/// value's type is erased (Core §4, "A `^T` moves into a `^{A}` and
/// keeps its box"). Only the value a box holds is erased, never a
/// List's or another container's element. True when handled.
pub fn eraseBox(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const into = heldInto(self, actual, expected, .box) orelse return false;
    const reached = sema.boxedType(self.ctx, into.value) orelse return false;
    const witness = (try erasable(self, e, e, actual, reached, into.want, into.object)) orelse return true;
    try self.ctx.record(.erasures, e, .{ .api = into.object.api, .from = reached, .view = into.want, .witness = witness, .form = .box, .optional = into.optional });
    try recordLift(self, e, if (into.optional) expected else into.want, expected);
    return true;
}

/// `e`, a counted handle (or an optional one) moved where a shared API
/// object goes, `*{A}` (or `*{A}?`): the handle keeps its allocation
/// and its count, and its value's type is erased (Core §4, "A `*T`
/// moves into a `*{A}`, keeping its allocation, and a frozen value's
/// handle only into a `*{A + Syncs}`"). The holding follows from the
/// braces (`sema.frozenObject`): a `*T`'s allocation counts plainly,
/// a frozen value's atomically, and neither becomes the other. An
/// actor's, a channel's, and a Cell's handles are none: their methods
/// are messages, or change what they hold. True when handled.
pub fn eraseShared(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const types = self.ctx.types;
    const into = heldInto(self, actual, expected, .shared) orelse return false;
    const want = into.want;
    const handle = into.value;
    const inner = switch (types.get(handle)) {
        .shared => |inner| inner,
        else => return false,
    };
    // Another object, or an owned closure, mismatches.
    if (sema.apiObject(self.ctx, inner) != null or types.get(inner) == .function) return false;
    const shown = try self.tyName(handle);
    const shown_view = try self.tyName(want);
    const what: ?[]const u8 = if (sema.actorValue(self.ctx, inner) != null)
        "an actor's handle, whose methods are messages"
    else if (sema.chanValue(self.ctx, inner) != null)
        "a channel's handle, whose methods are messages"
    else if (sema.isCell(self.ctx, inner))
        "a Cell's handle, which changes what it holds"
    else
        null;
    if (what) |w| {
        try self.errAt(e, "`{s}` is {s}, so it is no `{s}`", .{ shown, w, shown_view });
        return true;
    }
    const syncs = sema.frozenObject(self.ctx, types.get(want).shared);
    const frozen = sema.frozenValue(self.ctx, inner);
    if (frozen != null and !syncs) {
        // A frozen value holds no view, so `Owned` is no longer written.
        var with = into.object;
        with.builtins.insert(.Syncs);
        with.builtins.remove(.Owned);
        const fixed = try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), with);
        try self.errAt(e, "a frozen value's handle is erased only to `*{s}`, which counts atomically: write `*{s}`", .{ fixed, fixed });
        return true;
    }
    if (frozen == null and syncs) {
        const by_api = !into.object.builtins.contains(.Syncs);
        const why = if (by_api) try std.fmt.allocPrint(self.ctx.arena.allocator(), " (`{s}` builds on `Syncs`)", .{try sema.apiName(self.ctx, into.object.api)}) else "";
        // A word-Cell object's count is atomic: what keeps it out is
        // that its Cells change, where `Syncs` erases only what never
        // does.
        if (sema.cellObject(self.ctx, inner)) {
            try self.errAt(e, "`{s}` is erased to `{s}`, which holds only a frozen value{s}, and `{s}` changes through its Cells", .{ shown, shown_view, why, try self.tyName(inner) });
            return true;
        }
        try self.errAt(e, "`{s}` is erased to `{s}`, which several tasks read{s}, but its count is not atomic: freeze the value, `*Frozen(...)`", .{ shown, shown_view, why });
        return true;
    }
    const reached = frozen orelse inner;
    const witness = (try erasable(self, e, e, actual, reached, want, into.object)) orelse return true;
    try self.ctx.record(.erasures, e, .{ .api = into.object.api, .from = reached, .view = want, .witness = witness, .form = .shared, .holding = if (frozen != null) .frozen else .counted, .optional = into.optional });
    try recordLift(self, e, if (into.optional) expected else want, expected);
    return true;
}

/// `e`, a view of a handle (`?h`, `!h`) where a view of a handle of
/// an API object goes, `?*{A}`: rejected (reported), as a handle is
/// erased only as it moves or counts (the adversary's A5). A `!h`
/// viewed as a `!*{Shape}` would let a `Circle` be written into a
/// `*Square`, and a `?*Square` read as a `?*{Shape}` read 8 bytes as
/// 16. True when reported.
pub fn handleThroughView(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const types = self.ctx.types;
    if (self.isPoison(actual)) return false;
    const want = switch (types.get(expected)) {
        .optional => |inner| inner,
        else => expected,
    };
    const viewed = switch (types.get(want)) {
        .read_view, .write_view => |inner| inner,
        else => return false,
    };
    const h = sema.objectHeld(self.ctx, viewed) orelse return false;
    if (h.form != .shared and h.form != .weak) return false;
    const got = sema.unwrapViews(self.ctx, sema.unwrapOptionals(self.ctx, actual));
    switch (types.get(got)) {
        .shared, .weak => |inner| if (sema.apiObject(self.ctx, inner) != null) return false,
        else => return false,
    }
    const operand = if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e;
    try self.errAt(e, "`{s}` would view a `{s}` as a `{s}`: a handle is erased only as it moves or counts, never through a view; pass `+{s}`", .{ CallCheck.sourceText(self, e), try self.tyName(got), try self.tyName(viewed), try plainText(self, operand) });
    return true;
}

/// Whether the value `reached`, `viewed` (of type `actual`) being where
/// it is written, may be erased to `object` held as `view`: it is no
/// object itself, provides the object's API, by the witness given, and
/// meets the built-in APIs the braces name, checked on its type (Core
/// §4). Null after reporting.
pub fn erasable(self: *Checker, e: Sexp, viewed: Sexp, actual: TypeId, reached: TypeId, view: TypeId, object: sema.ApiObject) Error!?sema.Witness {
    const shown_view = try self.tyName(view);
    const api_name = try sema.apiName(self.ctx, object.api);
    // An object's type is fixed where its value is erased: no other
    // object gives a view of one (open question 10).
    if (sema.apiObject(self.ctx, reached) != null) {
        try self.errAt(e, "`{s}` is a `{s}`, which gives no view of another API object: an object's API and braces are fixed where its value is erased", .{ CallCheck.sourceText(self, viewed), try self.tyName(self.ctx.typeOf(viewed) orelse actual) });
        return null;
    }
    // An actor is reached only through its handle (`sema.actorMisplaced`):
    // its value is never viewed, as an object or otherwise.
    if (sema.actorValue(self.ctx, reached) != null) {
        try self.errAt(e, "an actor is reached only through its handle, whose methods are messages, so `{s}` is no `{s}`", .{ CallCheck.sourceText(self, viewed), shown_view });
        return null;
    }
    const witness = (try sema.witnessFor(self.ctx, reached, object.api)) orelse {
        if (self.ctx.types.get(reached) == .type_var) {
            const param = self.ctx.types.get(reached).type_var;
            const pname = sema.symbolAt(self.ctx, param).name;
            if (sema.symbolAt(self.ctx, param).user_apis.len == 0) {
                try self.errAt(e, "`{s}` is a `{s}` with no bound, so it is no `{s}`: write `[{s}: {s}]`", .{ CallCheck.sourceText(self, viewed), pname, shown_view, pname, api_name });
            } else try self.errAt(e, "`{s}` is a `{s}`, whose bounds do not name `{s}`, so it is no `{s}`: write `[{s}: {s}]`", .{ CallCheck.sourceText(self, viewed), pname, api_name, shown_view, pname, api_name });
            return null;
        }
        const tname = try self.tyName(reached);
        const fix = try sema.unprovidedFix(self.ctx, reached, object.api);
        if (self.expect.current_call) |call| {
            try self.errAt(e, "`{s}` cannot make a view of `{s}` as a `{s}`: `{s}` does not provide `{s}`{s}", .{ CallCheck.sourceText(self, call), CallCheck.sourceText(self, viewed), shown_view, tname, api_name, fix });
        } else try self.errAt(e, "`{s}` cannot be viewed as a `{s}`: `{s}` does not provide `{s}`{s}", .{ CallCheck.sourceText(self, viewed), shown_view, tname, api_name, fix });
        return null;
    };
    // A task, or a set of tasks, is waited for where its type shows
    // it (`task.isolate`, an error's field, a crossing): erased, no
    // rule would see it.
    if (!try StdFormCheck.hidesNoTask(self, e, reached, .erased, shown_view)) return null;
    // Its table holds every method the API names, which Zig compiles.
    if (self.tentative == 0) _ = try self.ctx.recordBodyReach(.{ .fun = .{ .module = 0, .pos = 0 }, .in = StdFormCheck.bodyRef(self), .params = &.{}, .args = &.{}, .recv = reached, .method = "", .site = self.startOf(e), .erase = object.api });
    // The built-in APIs the braces name, checked on the value's type.
    // The built-in APIs its braces and API name (`sema.objectBounds`):
    // Stage 3 checks an API's of each type that provides it, but a
    // generic type may provide it only where its arguments do.
    const bounds = sema.objectBounds(self.ctx, object);
    var it = bounds.iterator();
    while (it.next()) |b| if (b != .Sends and b != .Syncs) if (try sema.lacks(self.ctx, reached, b)) |_| {
        // `Owned`: the value holds no loan, which a part of it may.
        if (b == .Owned) {
            const why = if (try ApiCheck.fieldLacking(self.ctx, sema.nominalDecl(self.ctx, reached), .Owned)) |f| f[2..] else try std.fmt.allocPrint(self.ctx.arena.allocator(), "a `{s}` may hold a view", .{try self.tyName(reached)});
            try self.errAt(e, "`{s}` is erased to `{s}`, which holds no view, but {s}", .{ try self.tyName(reached), shown_view, why });
            return null;
        }
        if (!object.builtins.contains(b)) {
            try self.errAt(e, "`{s}` is erased to `{s}`, whose API builds on `{s}`, and `{s}` is not `{s}`", .{ CallCheck.sourceText(self, viewed), shown_view, @tagName(b), try self.tyName(reached), @tagName(b) });
            return null;
        }
        try self.errAt(e, "`{s}` is erased to `{s}`, which names `{s}`, and `{s}` is not `{s}`", .{ CallCheck.sourceText(self, viewed), shown_view, @tagName(b), try self.tyName(reached), @tagName(b) });
        return null;
    };
    // The crossing bounds its braces and API name, facts of the hidden
    // value (docs/design/apis.md, Stage 5): after this, the object
    // crosses by its braces alone.
    for ([_]sema.Crossing{ .moves, .shares }) |how| {
        const b = sema.crossingBound(how);
        if (!bounds.contains(b)) continue;
        if (try sema.lacks(self.ctx, reached, b) == null) continue;
        try self.errAt(e, "{s}", .{try crossingLack(self, reached, shown_view, how)});
        return null;
    }
    // A type parameter the value holds whose bounds do not decide a
    // bound is decided by each instance, as a known type is above:
    // `^Wrap[U](...)` in a generic body hides each `U` it is made of.
    if (self.ctx.typeInfo(reached).has_type_var) {
        const a = self.ctx.arena.allocator();
        const pos = self.startOf(e);
        var bit = bounds.iterator();
        while (bit.next()) |b| switch (b) {
            .Sends, .Syncs => try StdFormCheck.requireTask(self, reached, if (b == .Sends) .moves else .shares, pos, try a.print("is erased to `{s}`", .{shown_view}), false),
            else => {
                var held: std.ArrayList(SymbolId) = .empty;
                defer held.deinit(self.ctx.allocator);
                try sema.reachedTypeVars(self.ctx, reached, &held, self.ctx.allocator);
                for (held.items) |param| {
                    if (sema.checkedByBounds(self.ctx.symbols.items[param])) continue;
                    try ExprCheck.require(self, param, .{ .meets = b }, pos, try a.print("erases a value that holds a `{s}` to `{s}`, whose braces or API name `{s}`", .{ self.ctx.symbols.items[param].name, shown_view, @tagName(b) }));
                }
            },
        };
    }
    return witness;
}

/// Why `reached`, erased to `shown_view`, whose braces or API name the
/// crossing bound `how` needs, does not meet it: a type parameter's
/// bounds, or the part of the value that keeps it from crossing.
pub fn crossingLack(self: *Checker, reached: TypeId, shown_view: []const u8, how: sema.Crossing) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const b = sema.crossingBound(how);
    const blocker = (try sema.crossingBlocker(self.ctx, reached, how)) orelse reached;
    if (self.ctx.types.get(blocker) == .type_var) {
        const sym = sema.symbolAt(self.ctx, self.ctx.types.get(blocker).type_var).*;
        return a.print("`{s}` is erased to `{s}`, but `{s}` is not bounded by `{s}`: write `[{s}: {s}]`", .{ try self.tyName(reached), shown_view, sym.name, @tagName(b), sym.name, try sema.formatBounds(self.ctx, a, sym, b) });
    }
    const goes = if (how == .moves) "goes to other tasks" else "several tasks read";
    const shared = how == .shares;
    if (sema.nominalDecl(self.ctx, reached)) |d| if (d.ctx == @as(*const SemContext, self.ctx)) {
        for (d.symbol().fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant) continue;
            const fb = (try sema.crossingBlocker(self.ctx, f.ty, how)) orelse continue;
            const why = if (fb == f.ty) (try GenericCheck.crossingReason(self.ctx, fb, shared, "is"))[3..] else try a.print("which {s}", .{try GenericCheck.crossingReason(self.ctx, fb, shared, null)});
            return a.print("`{s}` is erased to `{s}`, which {s}, but its field `{s}` is a `{s}`, {s}", .{ try self.tyName(reached), shown_view, goes, f.name, try self.tyName(f.ty), why });
        }
    };
    return a.print("`{s}` is erased to `{s}`, which {s}, but `{s}` {s}", .{ try self.tyName(reached), shown_view, goes, try self.tyName(reached), try GenericCheck.crossingReason(self.ctx, blocker, shared, if (blocker == reached) "is" else null) });
}

/// `stmt`, a binding or an assignment, keeps the value it is given.
pub fn checkKeptSet(self: *Checker, stmt: Sexp) Error!void {
    const target = ir.Set.target(stmt);
    if (target == .src and std.mem.eql(u8, self.text(target), "_")) return;
    if (rig.bindingKindOf(ir.Set.op(stmt)).operator() != null) return;
    try keptViews(self, ir.Set.value(stmt), .{ .binding = if (target == .src) self.text(target) else CallCheck.sourceText(self, target) });
}

/// The one decider of a lasting view (Core sentence 4: a view kept
/// in a binding is written). `value`, which holds a view and is kept
/// (`Kept`), is a call whose result carries what an argument or the
/// self views (`CallParams.resultCarries`); if that is viewed
/// implicitly, the loan outlives the statement, so the view is
/// written: `r = head(?v)`, `xs = ?b.all()`. A call whose result is
/// used only within its statement views implicitly, since its loan
/// ends with the statement.
pub fn keptViews(self: *Checker, value: Sexp, kept: Checker.Kept) Error!void {
    if (value != .list or self.expect.under_poison) return;
    // A value that holds no view keeps no loan, whatever views were
    // read to make it: `m.get(k) ?? 0`, or a view read through where
    // its value is expected.
    if (self.ctx.typeOf(value)) |ty| {
        const kept_ty = if (self.ctx.readsThrough(value)) sema.unwrapViews(self.ctx, ty) else ty;
        if (!self.isPoison(kept_ty) and !sema.mayHoldView(self.ctx, kept_ty)) return;
    }
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, value, &leaves);
    // The payload of `a ?? b` or `a catch b` that copies what it views
    // out keeps only what that value holds (`copiedPayloadLeaves`).
    var copied: std.ArrayList(Sexp) = .empty;
    defer copied.deinit(self.ctx.allocator);
    try copiedPayloadLeaves(self, value, &copied);
    leaf: for (leaves.items) |leaf| {
        for (copied.items) |c| if (CompatCheck.sameNode(c, leaf)) continue :leaf;
        try keptLeaf(self, leaf, kept);
    }
}

/// The leaves of every operand in `e` whose payload a `??` or `catch`
/// copies out (`SemContext.copiesPayload`): its view is read there,
/// not kept, so what the copy keeps is what the value it views holds,
/// as a binding `v` of `if a as v` keeps what `v` holds.
pub fn copiedPayloadLeaves(self: *Checker, e: Sexp, out: *std.ArrayList(Sexp)) Error!void {
    if (e != .list) return;
    if (self.ctx.copiesPayload(e)) {
        const holder = if (e.isKind(.@"??")) ir.@"??".left(e) else ir.Catch.value(e);
        try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, holder, out);
    }
    for (e.items()) |c| try copiedPayloadLeaves(self, c, out);
}

pub fn keptLeaf(self: *Checker, e: Sexp, kept: Checker.Kept) Error!void {
    if (e != .list) return;
    // A chain whose result holds views of its source's items keeps
    // the source viewed, as a call keeps an argument it carries:
    // `vs = ?names.filter(f).collect()`.
    if (self.chain_views.count() > 0 and e.isKind(.call)) if (self.chain_views.get(CompatCheck.nodeId(e))) |source| {
        const root = source.root;
        if (self.ctx.kept_reported.contains(CompatCheck.nodeId(e))) return;
        if (!implicitSelfOf(self, root, source.ty)) return keptLeaf(self, root, kept);
        if (self.ctx.quiet != 0) return;
        try self.ctx.putIn(.check, .kept_reported, CompatCheck.nodeId(e), {});
        // A chain reported is not rewritten into its loop, so the
        // report is the last word on it.
        for (self.chains.items, 0..) |c, i| if (c.node == e.list.id) {
            _ = self.chains.orderedRemove(i);
            break;
        };
        return reportKept(self, e, root, kept);
    };
    const ty = self.ctx.typeOf(e) orelse return;
    if (self.isPoison(ty) or !sema.mayHoldView(self.ctx, ty)) return;
    switch (e.kind() orelse return) {
        // A part of a value a call made keeps what the call's
        // result carries.
        .member, .index => try keptLeaf(self, ir.get(e, .object), kept),
        .array => for (ir.Array.elems(e)) |el| try keptLeaf(self, el, kept),
        .call => {
            // Marked reported only where the report is kept: a quiet
            // check's is dropped, and the check that keeps it reports.
            if (self.ctx.kept_reported.contains(CompatCheck.nodeId(e))) return;
            if (self.ctx.quiet == 0) try self.ctx.putIn(.check, .kept_reported, CompatCheck.nodeId(e), {});
            const callee = ir.Call.callee(e);
            const params = self.ctx.callParamsOf(e);
            const has_recv = if (params) |p| p.fills.len > 0 and p.fills[0] == .self else false;
            if (callee.isKind(.member) and has_recv and params.?.resultCarriesSelf()) {
                const recv = ir.Member.object(callee);
                if (implicitSelf(self, recv)) return reportKept(self, e, recv, kept);
                try keptLeaf(self, recv, kept);
            }
            for (ir.Call.args(e), 0..) |a, i| {
                if (params) |p| if (!p.resultCarries(i)) continue;
                const arg = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
                if (implicitArgument(self, arg)) return reportKept(self, e, arg, kept);
                try keptLeaf(self, arg, kept);
            }
        },
        else => {},
    }
}

/// Whether `arg` is a place viewed to read where a view goes, with no
/// `?` written (`View.implicit`).
pub fn implicitArgument(self: *Checker, arg: Sexp) bool {
    const view = self.ctx.viewOf(arg) orelse return false;
    return view.implicit and hands(self, arg).kind == .place;
}

/// Whether `recv`, the self of a method that reads it, is a place
/// the call views to read with no `?` written: an owner, not a view
/// that is copied.
pub fn implicitSelf(self: *Checker, recv: Sexp) bool {
    return implicitSelfOf(self, recv, self.ctx.typeOf(recv) orelse return false);
}

/// `implicitSelf` of a `recv` of type `ty`.
pub fn implicitSelfOf(self: *Checker, recv: Sexp, ty: TypeId) bool {
    if (recv.isKind(.read) or recv.isKind(.write) or recv.isKind(.move)) return false;
    if (self.isPoison(ty) or sema.isReadOrWriteView(self.ctx, ty)) return false;
    return hands(self, recv).kind == .place and StmtCheck.placeOf(self, recv).named();
}

pub fn reportKept(self: *Checker, call: Sexp, viewed: Sexp, kept: Checker.Kept) Error!void {
    const a = self.ctx.arena.allocator();
    const shown = try plainText(self, viewed);
    const fixed = try spliced(self, call, &.{viewed}, &.{try a.print("?{s}", .{shown})});
    const call_text = CallCheck.sourceText(self, call);
    switch (kept) {
        .binding => |name| if (std.mem.eql(u8, name, rig.hiddenIteratorName())) {
            try self.errAt(viewed, "`{s}` keeps a view of `{s}` while the loop walks it; write `for ... in {s}`", .{ call_text, shown, fixed });
        } else try self.errAt(viewed, "`{s}` keeps a view of `{s}` while `{s}` lives; write `{s}`", .{ call_text, shown, name, fixed }),
        .returned => try self.errAt(viewed, "`{s}` keeps a view of `{s}` in the value it returns; write `{s}`", .{ call_text, shown, fixed }),
        .stored => |callee| try self.errAt(viewed, "`{s}` keeps a view of `{s}` in what `{s}` stores; write `{s}`", .{ call_text, shown, callee, fixed }),
    }
}

/// A slice argument (`slicedArg`) where its context takes no read
/// view of that type: a write view, `!xs[a..b]`, where a `![]T`
/// goes, and a copy where a value of its own does. True when
/// reported; any other type is a mismatch, as for `?xs[a..b]`.
pub fn sliceArgRejected(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const a = self.ctx.arena.allocator();
    const slot = self.expect.slot;
    const in_call = CompatCheck.sameExpr(e, slot.value) and slot.call != .nil and !slot.field and argOf(slot.call, e);
    const shown = try plainText(self, e);
    const callee = if (in_call) try a.print("`{s}`", .{try StdFormCheck.calleeName(self, ir.Call.callee(slot.call))}) else "the call";
    const object = try plainText(self, ir.Index.object(e));
    if (sema.writeSliceElem(self.ctx, expected)) |elem| {
        if (self.ctx.types.get(actual) != .slice or self.ctx.types.get(actual).slice.elem != elem) return false;
        const viewed = try a.print("!{s}", .{shown});
        const fix = if (in_call) try spliced(self, slot.call, &.{e}, &.{viewed}) else viewed;
        try self.errAt(e, "{s} writes the elements of `{s}`, and a slice is a read view unless it is written `!`; write `{s}`", .{ callee, shown, fix });
        return true;
    }
    if ((actual == self.t().string_view_id or actual == self.t().static_id) and liftTarget(self, expected) == self.t().string_id) {
        const copy = try a.print("String(?{s})", .{shown});
        const fix = if (in_call) try spliced(self, slot.call, &.{e}, &.{copy}) else copy;
        try self.errAt(e, "{s} takes a `String`, which owns its bytes, and `{s}` only views `{s}`'s; write `{s}` to pass a copy", .{ callee, shown, object, fix });
        return true;
    }
    const elem = switch (self.ctx.types.get(actual)) {
        .slice => |sl| sl.elem,
        else => return false,
    };
    const target = liftTarget(self, expected);
    const owns = switch (self.ctx.types.get(target)) {
        .array => |arr| arr.elem == elem,
        else => sema.listElem(self.ctx, target) == elem,
    };
    if (!owns) return false;
    try self.errAt(e, "{s} takes a `{s}`, which owns its elements, and `{s}` only views `{s}`'s", .{ callee, try self.tyName(expected), shown, object });
    return true;
}

/// A temporary array `e` of `elem`s viewed as a `[]T` argument, with no
/// `?` written (`total([1, 2])`). One whose elements need no cleanup
/// lives where Zig holds it for the call; any other is held and
/// dropped in its statement's slot, as `?[...]` holds it
/// (`checkReadView`).
pub fn viewTempArray(self: *Checker, e: Sexp, array: TypeId, expected: TypeId) Error!void {
    const elem = self.ctx.types.get(array).array.elem;
    if (!sema.typeHasDropGlue(self.ctx, elem) and !sema.maybeDropGlue(self.ctx, elem)) return self.ctx.record(.temp_arrays, e, {});
    var view = sema.viewAs(self.ctx, array, .read, expected) orelse return self.ctx.record(.temp_arrays, e, {});
    try checkReadView(self, e);
    view.implicit = true;
    try self.ctx.record(.uses, e, .view);
    try self.ctx.recordView(e, view);
}

/// An array where a slice is expected: a temporary array as a `[]T`
/// argument of a call that keeps no view of it. A bare named array
/// is rejected with the write view. True when handled.
pub fn arrayAsSlice(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    const want_write = sema.writeSliceElem(self.ctx, expected) != null;
    const elem = sema.writeSliceElem(self.ctx, expected) orelse switch (self.ctx.types.get(expected)) {
        .slice => |sl| sl.elem,
        else => return false,
    };
    switch (self.ctx.types.get(actual)) {
        .array => |a| if (a.elem == elem or (!want_write and sema.readsAsStringView(self.ctx, a.elem, elem))) {
            if (hands(self, e).hasStorage()) {
                const shown = try plainText(self, e);
                const sigil: u8 = if (want_write) '!' else '?';
                try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; write `{c}{s}` or `{c}{s}[..]`", .{ try self.tyName(expected), try self.tyName(actual), sigil, shown, sigil, shown });
                return true;
            }
            if (!want_write and CompatCheck.sameNode(e, self.expect.viewed_temp)) {
                try viewTempArray(self, e, actual, expected);
                return true;
            }
            if (!want_write) {
                try self.errAt(e, "a temporary array is passed as a `{s}` only to a call that keeps no view of it; bind it to a name and pass `?name`", .{try self.tyName(expected)});
                return true;
            }
        },
        else => {},
    }
    return false;
}

/// A String, or a write view of one, where a `?String` is expected: it
/// is viewed as a `?String` to read, `?t`. True when handled.
pub fn stringAsStringView(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
    // Where a `(?String)?` is expected, too: the view is lifted.
    const want = switch (self.ctx.types.get(expected)) {
        .optional => |inner| inner,
        else => expected,
    };
    if (want != self.t().string_view_id) return false;
    const string_ty = self.t().string_id;
    const is_text = switch (self.ctx.types.get(actual)) {
        .string => true,
        .write_view => |inner| inner == string_ty,
        else => false,
    };
    if (!is_text) return false;
    if (e.isKind(.template)) {
        try self.errAt(e, "a template is a `?String` only as an argument a parameter reads, a temporary of its statement; elsewhere bind its String to a name first", .{});
        return true;
    }
    const shown = try plainText(self, CompatCheck.stripSigil(e));
    try self.errAt(e, "type mismatch: expected `?String`, got `{s}`; pass it as a `?String` with `?{s}` or `?{s}[..]`", .{ try self.tyName(actual), shown, shown });
    return true;
}

pub fn mismatch(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error!void {
    // `o or 0` for an optional `o`: a fallback, which `??` writes.
    if (std.mem.eql(u8, self.expect.logic_op, "or") and CompatCheck.sameSite(e, self.expect.logic_operands[0]) and expected == self.t().bool_id and self.ctx.types.get(actual) == .optional) {
        return self.errAt(e, "`or` joins Bools; an optional's fallback is `{s} ?? {s}`", .{ CallCheck.sourceText(self, e), CallCheck.sourceText(self, self.expect.logic_operands[1]) });
    }
    // `!c` of a handle that may not be written here views what it holds
    // (`synthView`), which a `!*T` parameter cannot take.
    if (e.isKind(.write)) if (self.ctx.types.get(expected) == .write_view and self.ctx.types.get(actual) == .write_view) {
        const want = self.ctx.types.get(expected).write_view;
        if (self.ctx.types.get(want) == .shared and self.ctx.types.get(want).shared == self.ctx.types.get(actual).write_view) {
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`: this handle is read-only here; pass `+{s}` to share a new handle, or pass a view of the contents", .{ try self.tyName(expected), try self.tyName(actual), CallCheck.sourceText(self, ir.Write.operand(e)) });
        }
    };
    // `?p.m()` reads `p`; where a view of the call's result is
    // expected, the view goes around the call.
    if (e.isKind(.call) and self.ctx.types.get(expected) == .read_view and CompatCheck.compatible(self.ctx, actual, sema.unwrapViews(self.ctx, expected))) {
        const callee = ir.Call.callee(e);
        if (callee.isKind(.member) and ir.Member.object(callee).isKind(.read) and isSelfSigil(self, ir.Member.object(callee))) {
            const recv = ir.Member.object(callee);
            const start = self.ctx.span(ir.Read.operand(recv)).start;
            const end = self.ctx.span(e).end;
            const call = diag.textBetween(self.ctx.source, start, end);
            return self.errAt(recv, "type mismatch: expected `{s}`, got `{s}`: `?{s}` reads `{s}` for the call; write `?({s})` to make a view of the call's result", .{ try self.tyName(expected), try self.tyName(actual), call, CallCheck.sourceText(self, ir.Read.operand(recv)), call });
        }
    }
    // An error with fields where a view of `error` or of a union goes:
    // a value of either is bound first, and viewed. (A code views its
    // error value, `sema.codeViewed`.)
    const any_error = sema.isErrorSet(self.ctx, actual) and self.ctx.types.get(expected) == .read_view and self.ctx.types.get(expected).read_view == self.t().any_error_id;
    if (unionViewed(self, actual, expected) orelse if (any_error) self.t().any_error_id else null) |set| {
        // A place whose value moves is moved into the binding.
        const moved = hands(self, e).kind == .place and sema.moves(self.ctx, actual) == .yes;
        const src = if (moved) try std.fmt.allocPrint(self.ctx.arena.allocator(), "<{s}", .{CallCheck.sourceText(self, e)}) else CallCheck.sourceText(self, e);
        return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; bind it first, `k: {s} = {s}`, then pass `?k`", .{ try self.tyName(expected), try self.tyName(actual), try self.tyName(set), src });
    }
    // A place where a view of it is expected: the sigil is missing.
    // (A literal is no place to view.)
    const place = StmtCheck.placeOf(self, e);
    switch (self.ctx.types.get(expected)) {
        .read_view, .write_view => |inner| if (place.named() and place.sym != null and CompatCheck.compatible(self.ctx, actual, inner)) {
            const write = self.ctx.types.get(expected) == .write_view;
            // A read match's binding is written through `match !e`.
            if (write) {
                const hint = try PatternCheck.readMatchHint(self, place.sym);
                if (hint.len > 0) return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}", .{ try self.tyName(expected), try self.tyName(actual), hint });
            }
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; make a {s} view of it: `{c}{s}`", .{ try self.tyName(expected), try self.tyName(actual), if (write) "write" else "read", @as(u8, if (write) '!' else '?'), try plainText(self, e) });
        },
        else => {},
    }
    // A mask is no `Bool`: it is reduced or combined.
    if (expected == self.t().bool_id and sema.isMask(self.ctx, actual)) return StdFormCheck.maskAsBool(self, e, sema.unwrapViews(self.ctx, actual));
    // `not n` of an integer: the complement is a method.
    if (CompatCheck.sameSite(e, self.expect.not_operand) and expected == self.t().bool_id and sema.isInteger(self.ctx, sema.unwrapViews(self.ctx, actual))) {
        return self.errAt(e, "`not` takes a Bool; for the bitwise complement write `x.not()`", .{});
    }
    const match_hint = if (self.ctx.types.get(expected) == .write_view) try PatternCheck.readMatchHint(self, place.sym) else "";
    if (match_hint.len > 0) return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}", .{ try self.tyName(expected), try self.tyName(actual), match_hint });
    try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}{s}{s}", .{ try self.tyName(expected), try self.tyName(actual), try FlowCheck.loopOrderHint(self, e, expected), staticHint(self, e, expected, actual), try ownerHint(self, e, expected, actual) });
}

/// Where a `String` is expected and a `?String` (or a `Static`) is
/// given: a `String` owns its text, so the way out is a copy, or a
/// place that only reads, `?String`.
pub fn ownerHint(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error![]const u8 {
    if (expected != self.t().string_id) return "";
    if (actual != self.t().string_view_id and actual != self.t().static_id) return "";
    return self.ctx.arena.allocator().print("; a `String` owns its text: write `String({s})` to copy it, or declare the place `?String` to only read it", .{try plainText(self, e)});
}

/// Why a `?String` is not a `Static`, and the way out, when `actual`
/// is the text of a `?String` (or a `String`) and `expected` a `Static`
/// (also in an optional): the text may view a `String`, which a
/// `Static` never does.
pub fn staticHint(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) []const u8 {
    const want = switch (self.ctx.types.get(expected)) {
        .optional => |inner| inner,
        else => expected,
    };
    if (want != self.t().static_id) return "";
    const got = sema.unwrapViews(self.ctx, switch (self.ctx.types.get(actual)) {
        .optional => |inner| inner,
        else => actual,
    });
    if (got != self.t().string_view_id and got != self.t().string_id) return "";
    if (self.expect.static_target.len > 0 and CompatCheck.sameSite(e, self.expect.static_target_value)) return self.ctx.arena.allocator().print("; `{s}` is a `Static`, bound to a literal's text, and a `?String` may view a `String`: declare it `{s}: ?String = ...` to hold other text", .{ self.expect.static_target, self.expect.static_target }) catch "";
    return "; a `Static` is a literal, or text derived only from literals, and a `?String` may view a `String`. A parameter or field that only reads its text is declared `?String`, which takes a `Static` too";
}

/// The type a variant literal (`.V`, `.V(...)`) takes where a view
/// held by address goes (`?Val`, `!Color`, `(?Val)?`): the viewed
/// type, as `Val.V(...)` has, so the literal is a value made where it
/// stands, viewed as one is or rejected. A view that holds a copy of
/// the value (`?Color`, `sema.viewByValue`) takes the literal itself.
/// Any view of `error` or of a union takes the error union or `error`,
/// whose member the literal names (`checkShortForm`).
/// Null for any other form or expected type, and for a name that is
/// no variant of the viewed enum, which `checkContextual` reports
/// (an error's name where a `T!` goes, too).
pub fn variantUnderView(self: *Checker, e: Sexp, expected: TypeId) Error!?TypeId {
    const name = if (e.isKind(.enum_lit))
        ir.EnumLit.name(e)
    else if (e.isKind(.call) and ir.Call.callee(e).isKind(.enum_lit))
        ir.EnumLit.name(ir.Call.callee(e))
    else
        return null;
    const view = liftTarget(self, expected);
    switch (self.ctx.types.get(view)) {
        .read_view, .write_view => {},
        else => return null,
    }
    const viewed = sema.unwrapViews(self.ctx, view);
    // A member where a view of `error` or of a union goes is of its
    // own set, as `E.name` is, and is viewed as that value is.
    if (viewed == self.t().any_error_id or sema.isErrorUnion(self.ctx, viewed)) return viewed;
    if (!sema.viewHeldAsPointer(self.ctx, view)) return null;
    if (try sema.lookupVariant(self.ctx, viewed, self.text(name)) == null) return null;
    return viewed;
}

/// A string literal where a `U8` goes is its one byte, and where a
/// `[N]U8` goes, its bytes, as an integer literal takes the type its
/// context gives it: found (`bytes`) for its statement to be checked
/// again with the literal written as the integer or array literal it
/// is (`checkRewritten`). Null where `target` is neither, so the literal
/// stays text.
pub fn byteString(self: *Checker, e: Sexp, target: TypeId) Error!?TypeId {
    const len: ?u64 = switch (self.ctx.types.get(target)) {
        .array => |a| if (CompatCheck.isU8(self.ctx, a.elem)) (sema.arrayLen(self.ctx, a) orelse return null) else return null,
        else => if (CompatCheck.isU8(self.ctx, target)) null else return null,
    };
    const lit = self.text(e);
    const mark = self.ctx.diagnostics.items.len;
    try ExprCheck.checkEscapes(self, e);
    if (self.ctx.diagnostics.items.len > mark) return self.t().invalid_id;
    const bytes = CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), lit) orelse return self.t().invalid_id;
    if (len) |n| {
        if (bytes.len != n) {
            try self.errAt(e, "string literal `{s}` is {d} byte{s}; `{s}` needs {d}", .{ lit, bytes.len, CompatCheck.plural(bytes.len), try self.tyName(target), n });
            return self.t().invalid_id;
        }
    } else if (bytes.len != 1) {
        try self.errAt(e, "{s}", .{try notOneByte(self, lit, bytes.len)});
        return self.t().invalid_id;
    }
    // Every statement and declaration that holds a string literal is
    // checked under a mark (`checkRewritten`).
    if (self.rewrites_open == 0) {
        try self.errAt(e, "internal error: string literal `{s}` is a byte here, outside any statement checked again", .{lit});
        return self.t().invalid_id;
    }
    for (self.bytes.items) |l| if (l.pos == e.src.pos) return target;
    try self.bytes.append(self.ctx.allocator, .{ .pos = e.src.pos, .bytes = bytes, .array = len != null });
    return target;
}

/// Why string literal `lit`, of `n` bytes, is no `U8`: its size, a
/// raw escape's bytes and the double-quoted literal that is the byte,
/// or the bytes of a character outside ASCII.
pub fn notOneByte(self: *Checker, lit: []const u8, n: usize) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const body = lit[1 .. lit.len - 1];
    if (lit[0] == '\'' and std.mem.findScalar(u8, body, '\\') != null) {
        const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{body});
        const escaped = std.zig.string_literal.parseAlloc(a, quoted) catch null;
        if (escaped != null and escaped.?.len == 1) {
            const b = escaped.?[0];
            const what = switch (b) {
                '\n' => "a newline",
                '\t' => "a tab",
                '\r' => "a carriage return",
                '\\' => "a backslash",
                else => try std.fmt.allocPrint(a, "the byte 0x{x:0>2}", .{b}),
            };
            const raw = if (body.len == 2) try std.fmt.allocPrint(a, "the two bytes `\\` and `{c}`", .{body[1]}) else try std.fmt.allocPrint(a, "the {d} bytes `{s}`", .{ n, body });
            return std.fmt.allocPrint(a, "`{s}` is raw, {s}; for {s} write `{s}`", .{ lit, raw, what, quoted });
        }
        return std.fmt.allocPrint(a, "`{s}` is {d} bytes, and raw: a `U8` is one byte, and a `\\` is a byte of its own in single quotes; write the literal in double quotes for its escapes", .{ lit, n });
    }
    if (n > 1 and body.len == n and body[0] >= 0x80 and (std.unicode.utf8ByteSequenceLength(body[0]) catch 0) == n)
        return std.fmt.allocPrint(a, "`{s}` is one character of {d} bytes; a `U8` is one byte", .{ lit, n });
    if (n == 0) return std.fmt.allocPrint(a, "`{s}` holds no bytes; a `U8` is one byte", .{lit});
    return std.fmt.allocPrint(a, "`{s}` is {d} bytes; a `U8` is one byte", .{ lit, n });
}

/// `c == 'A'`, `c - '0'`: a string literal beside a `U8` goes where a
/// `U8` does (`byteString`). The `U8`, or null.
pub fn byteBeside(self: *Checker, operands: [2]Sexp, a: TypeId, b: TypeId) Error!?TypeId {
    for (operands, [2]TypeId{ b, a }) |o, other| {
        if (o != .src or !sema.isStringLiteralText(self.text(o))) continue;
        const ty = sema.unwrapViews(self.ctx, other);
        if (!CompatCheck.isU8(self.ctx, ty)) continue;
        try checkExpr(self, o, ty);
        return ty;
    }
    return null;
}

/// A short form, `.name` or `.name(fields)`, which names a variant
/// or a member of the type its context gives, `target`: the type
/// recorded for it, which emit reads. Where any error or a union goes,
/// it is the member of the one set that has it (the set's type, as
/// `E.name` has); where a `T!` goes, a variant of `T`, since a function
/// fails only by naming the error set. The member's fields are then
/// checked against its set's, as `E.name(fields)`'s are.
pub fn checkShortForm(self: *Checker, e: Sexp, expected: TypeId, target: TypeId) Error!TypeId {
    const call: ?Sexp = if (e.isKind(.call)) e else null;
    const name = ir.EnumLit.name(if (call) |c| ir.Call.callee(c) else e);
    const ty = if (target == self.t().any_error_id)
        try BuiltinCheck.resolveErrorName(self, name)
    else if (sema.isErrorUnion(self.ctx, target))
        try BuiltinCheck.unionMemberSet(self, target, name)
    else blk: {
        if (self.ctx.types.get(expected) == .fallible and !self.isPoison(target) and
            (try sema.lookupVariant(self.ctx, target, self.text(name))) == null)
        {
            const sets = try sema.errorSetsWith(self.ctx, self.text(name));
            if (sets.len > 0) {
                try BuiltinCheck.bareErrorName(self, name, target, sets);
                break :blk self.t().invalid_id;
            }
        }
        break :blk target;
    };
    const c = call orelse {
        try BuiltinCheck.checkEnumLit(self, name, ty);
        return ty;
    };
    if (self.isPoison(ty)) {
        try CallCheck.synthArgs(self, ir.Call.args(c));
        return ty;
    }
    try BuiltinCheck.checkPayloadVariant(self, c, ty);
    try self.ctx.recordType(ir.Call.callee(c), ty);
    return ty;
}

/// A constructor call `C(...)` or `.v(...)` typed by the type its
/// context gives it (`checkContextual`); null for any other call.
pub fn contextualCall(self: *Checker, e: Sexp, expected: TypeId, target: TypeId) Error!?TypeId {
    const callee = ir.Call.callee(e);
    if (callee.isKind(.enum_lit)) return try checkShortForm(self, e, expected, target);
    // `Wrap(...)` where a `Wrap[Int]` is expected.
    const tt = self.ctx.types.get(target);
    if (callee != .src or tt != .parameterized_nominal) return null;
    const id = CallCheck.lookupQuiet(self, callee) orelse return null;
    if (self.ctx.ref(id) != tt.parameterized_nominal.sym) return null;
    // `Frozen(x)` and `Actor(x)` take their types from `x`
    // (`frozenMake`, `actorMake`).
    if (self.ctx.ref(id) == self.ctx.builtins.frozen or self.ctx.ref(id) == self.ctx.builtins.actor) return null;
    _ = try ExprCheck.useName(self, callee);
    if (self.ctx.ref(id) == self.ctx.builtins.signal and !CompatCheck.sameNode(e, self.expect.shared_operand)) {
        try self.errAt(callee, Checker.stack_signal, .{});
        try CallCheck.synthArgs(self, ir.Call.args(e));
    } else if (self.ctx.ref(id) == self.ctx.builtins.list) {
        try BuiltinCheck.checkListConstruction(self, e, target);
    } else if (self.ctx.ref(id) == self.ctx.builtins.table) {
        try StdFormCheck.checkTableConstruction(self, e);
    } else {
        const r = self.ctx.ref(id);
        const foreign: ?Checker.ForeignFields = if (self.ctx.owns(r)) null else .{ .ctx = self.ctx.foreign_semas.get(r.module_id).?, .module_id = r.module_id };
        _ = try CallCheck.construct(self, r.sym, ir.Call.args(e), callee.src.pos, .{ .params = sema.paramRefs(self.ctx, r), .args = tt.parameterized_nominal.args }, foreign);
    }
    return target;
}

/// A form whose type comes from context: its type, or null when `e`
/// is not one.
pub fn checkContextual(self: *Checker, e: Sexp, expected: TypeId) Error!?TypeId {
    const target = liftTarget(self, expected);
    switch (e) {
        .src => {
            const s = self.text(e);
            if (std.mem.eql(u8, s, "none")) return try checkNone(self, e, expected);
            // A number literal where a view argument `?N` goes is viewed
            // as `?5` is: a copy of the number.
            if (CompatCheck.sameExpr(e, self.expect.view_arg) and (sema.isIntLiteralText(s) or sema.isFloatLiteralText(s))) switch (self.ctx.types.get(expected)) {
                .read_view => |inner| if (sema.isNumeric(self.ctx, inner)) {
                    try checkExpr(self, e, inner);
                    return inner;
                },
                else => {},
            };
            if (sema.isStringLiteralText(s)) return byteString(self, e, target);
            if (!sema.isIntLiteralText(s) or !(sema.isInteger(self.ctx, target) or self.ctx.types.get(target) == .slot)) return null;
            try BuiltinCheck.checkLiteralFits(self, e, target);
            return target;
        },
        .list => {},
        else => return null,
    }
    const head = e.kind() orelse return null;
    switch (head) {
        // `?5` where a `?Int` is expected: the literal takes the
        // viewed type, as it would bare.
        .read => {
            const operand = ir.Read.operand(e);
            const lit = if (operand.isKind(.neg)) ir.Neg.operand(operand) else operand;
            if (lit != .src or !(sema.isIntLiteralText(self.text(lit)) or sema.isFloatLiteralText(self.text(lit)))) return null;
            const inner = switch (self.ctx.types.get(expected)) {
                .read_view => |i| i,
                else => return null,
            };
            if (!sema.isNumeric(self.ctx, inner)) return null;
            try checkExpr(self, operand, inner);
            return expected;
        },
        .neg => {
            const operand = ir.Neg.operand(e);
            if (operand != .src or !sema.isIntLiteralText(self.text(operand)) or !sema.isInteger(self.ctx, target)) return null;
            try BuiltinCheck.checkLiteralFits(self, e, target);
            try self.ctx.recordType(operand, target);
            return target;
        },
        .enum_lit => return try checkShortForm(self, e, expected, target),
        .call => {
            // A call marked `&` gives a task of what the call gives,
            // which `taskOf` types and checks, whatever the context.
            const made = try contextualCall(self, e, expected, target) orelse return null;
            return if (ir.Call.task(e) != .nil) try CallCheck.taskOf(self, e, made) else made;
        },
        .builtin => {
            const ty = try BuiltinCheck.synthBuiltin(self, e, target);
            return if (ty == self.t().int_literal_id) target else ty;
        },
        .lambda => {
            if (self.ctx.types.get(target) == .function) {
                const ty = try ClosureCheck.checkLambda(self, e, target);
                if (!CompatCheck.sameNode(e, self.expect.viewed_callable) and !CompatCheck.sameNode(e, self.expect.callable_kept)) return ty;
                // Reported here; the closure is not checked as escaping.
                try self.errAt(e, "a closure literal is not a function value `{s}`; declare the parameter `?{s}` to pass the closure to the call as a view", .{ try self.tyName(target), try self.tyName(target) });
                return self.t().invalid_id;
            }
            if (sema.callableFn(self.ctx, target) != null) return try ClosureCheck.viewedLambda(self, e, target);
            const fn_ty = ClosureCheck.ownedClosureType(self, target) orelse return null;
            try self.errAt(e, "`{s}` is an owned closure; write `*|...| body` to make one", .{try self.tyName(target)});
            _ = try ClosureCheck.checkLambda(self, e, fn_ty);
            return self.t().invalid_id;
        },
        .share => {
            const operand = ir.Share.operand(e);
            if (try shareOfNone(self, e, target)) return target;
            if (operand.isKind(.lambda) and sema.callableFn(self.ctx, target) != null) {
                try self.errAt(e, "`{s}` views a closure for the call; write the closure without `*` (remove the `*`)", .{try self.tyName(target)});
                _ = try ClosureCheck.checkLambda(self, operand, sema.callableFnTy(self.ctx, target).?);
                return target;
            }
            if (operand.isKind(.lambda)) {
                const ty = try ClosureCheck.ownedClosure(self, operand, ClosureCheck.ownedClosureType(self, target));
                if (!CompatCheck.compatible(self.ctx, ty, expected)) try mismatch(self, e, expected, ty);
                return ty;
            }
            const tt = self.ctx.types.get(target);
            if (tt != .shared) return null;
            // A handle made where a shared API object goes is made of
            // its own type, then erased (`eraseShared`).
            if (sema.apiObject(self.ctx, tt.shared) != null) return null;
            // An owned closure is made only from a closure literal,
            // where a handle's value is a function as where `*f`
            // stands alone (`synthShare`).
            if (self.ctx.types.get(tt.shared) == .function) {
                try self.errAt(operand, "`*` makes an owned closure only from a closure literal: `*|...| body`", .{});
                return self.t().invalid_id;
            }
            // `*` of a weak handle upgrades it whatever is expected
            // (`weakUpgrade`), so it makes no `*~T`: synthesized, it
            // mismatches. An operand typed where it stands is typed
            // first, and checked against the handle's value only where
            // it is no weak handle.
            if (self.ctx.types.get(sema.unwrapViews(self.ctx, tt.shared)) == .weak) return null;
            if (typedWhereItStands(self, operand)) {
                const ty = try shareOperand(self, operand, null);
                if (try weakUpgrade(self, e, ty)) |upgraded| {
                    if (!CompatCheck.compatible(self.ctx, upgraded, expected)) try mismatch(self, e, expected, upgraded);
                    return upgraded;
                }
                if (self.isPoison(ty)) return target;
                try recordUse(self, operand, .take);
                if (operand == .list and self.ctx.quiet == 0) try self.expected.put(self.ctx.allocator, CompatCheck.nodeId(operand), tt.shared);
                try checkActual(self, operand, ty, tt.shared);
                return target;
            }
            _ = try shareOperand(self, operand, tt.shared);
            return target;
        },
        .box => {
            if (sema.boxedType(self.ctx, target) == null) return null;
            // A box made where a box of an API object goes is made of
            // its own type, then erased (`eraseBox`).
            if (sema.objectHeld(self.ctx, target) != null) return null;
            const ty = try synthBox(self, e, target);
            return if (self.isPoison(ty)) ty else target;
        },
        .array => return CallCheck.checkArray(self, e, target),
        .array_fill => return if (self.ctx.types.get(target) == .array) try CallCheck.checkArrayFill(self, e, target) else null,
        .@"if" => _ = try FlowCheck.checkIfValue(self, e, expected, .value),
        .match => _ = try PatternCheck.checkMatch(self, e, .value, expected),
        .@"while", .@"for", .labeled => {
            if (!FlowCheck.isValueLoop(self, e)) return try FlowCheck.noLoopValue(self, e, expected);
            _ = try FlowCheck.checkLoopValue(self, e, expected, true);
        },
        .block => _ = try ExprCheck.synthBlock(self, e, expected),
        .raw_block => {
            self.raw_depth += 1;
            defer self.raw_depth -= 1;
            try checkExpr(self, ir.RawBlock.body(e), expected);
        },
        .@"??", .@"catch" => {
            const ty = if (head == .@"??") try ExprCheck.synthCoalesce(self, e, expected) else try ExprCheck.synthCatch(self, e, expected);
            // A view either branch gives is copied out where its
            // value is expected (`copiedOut`).
            if (CompatCheck.compatible(self.ctx, ty, expected)) try recordAdapted(self, e, ty, expected) else try mismatch(self, e, expected, ty);
            return ty;
        },
        else => return null,
    }
    return expected;
}

/// `none` where `expected` is required: an optional (possibly
/// fallible). Returns the optional type.
pub fn checkNone(self: *Checker, e: Sexp, expected: TypeId) Error!TypeId {
    var ty = expected;
    while (true) {
        switch (self.ctx.types.get(ty)) {
            .optional => return ty,
            .fallible => |i| ty = i.ok,
            else => break,
        }
    }
    // `?T?` is a view of a `T?`, which `none` is no value of; a view
    // that may be missing is `(?T)?`.
    switch (self.ctx.types.get(expected)) {
        .read_view, .write_view => |viewed| if (self.ctx.types.get(viewed) == .optional) {
            const payload = self.ctx.types.get(viewed).optional;
            const view = try self.ctx.intern(if (self.ctx.types.get(expected) == .read_view) .{ .read_view = payload } else .{ .write_view = payload });
            const fixed = try self.ctx.intern(.{ .optional = view });
            try self.errAt(e, "`none` needs an optional type; `{s}` is a view of an optional, not an optional view (write `{s}`)", .{ try self.tyName(expected), try self.tyName(fixed) });
            return self.t().invalid_id;
        },
        else => {},
    }
    // Spelled as a type is: `*B?`, `([2]Int)?`.
    const optional = try self.ctx.intern(.{ .optional = expected });
    try self.errAt(e, "`none` needs an optional type; `{s}` is not optional (write `{s}`)", .{ try self.tyName(expected), try self.tyName(optional) });
    return self.t().invalid_id;
}

/// What a contextual form (literal, `.variant`, constructor) should
/// produce when `expected` may lift it: `T` for `T?` and `T!`.
pub fn liftTarget(self: *Checker, expected: TypeId) TypeId {
    var ty = expected;
    while (true) {
        switch (self.ctx.types.get(ty)) {
            .optional => |i| ty = i,
            .fallible => |i| ty = i.ok,
            else => return ty,
        }
    }
}

/// Record how `e`, of type `actual`, adapts to the `expected` its
/// context gives: a view copied out (`copiedOut`) is read through
/// (`readOf`), and so is a write view passed where a read view that
/// copies its value is expected; a literal takes a concrete type.
pub fn recordAdapted(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    try recordAdaptedType(self, e, actual, expected);
    try recordLift(self, e, self.ctx.typeOf(e) orelse actual, expected);
    // A view copied out adapts as the value it copies: `?B.y` where
    // an error with fields goes widens as `B.y` does.
    const value = if (CompatCheck.copiedOut(self.ctx, actual, expected)) sema.copiedThrough(self.ctx, actual) orelse actual else actual;
    try recordCodeWidening(self, e, value, expected);
}

/// An error whose set has no fields, where an error that may carry
/// them goes (`error`, or a set or union with fields), through any
/// optionals: a code that becomes a `rig.ErrorValue` with no fields.
pub fn recordCodeWidening(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    if (!sema.isErrorSet(self.ctx, actual) or sema.setHasFields(self.ctx, actual)) return;
    const into = sema.unwrapOptionals(self.ctx, expected);
    if (into == self.t().any_error_id or (sema.isErrorSet(self.ctx, into) and sema.setHasFields(self.ctx, into))) try self.ctx.record(.code_widenings, e, {});
}

/// Record the optional `e`'s value becomes where `expected` goes
/// (`SemContext.recordLift`): `none`, which needs the optional's type,
/// and a value of type `actual` (or the value a view of that type
/// copies out, `copiedOut`) with fewer levels of optional than the
/// optional `expected` is or holds, which Zig lifts into it on its own.
/// Emit writes either explicitly where an optional is not Zig's `?T`
/// (`sema.optionalRouted`). Any other value is no lift.
pub fn recordLift(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    const ts = self.ctx.types;
    var into = expected;
    while (ts.get(into) == .fallible) into = ts.get(into).fallible.ok;
    if (ts.get(into) != .optional) return self.ctx.recordLift(e, null);
    if (sema.isNoneLeaf(self.ctx, e)) {
        return self.ctx.recordLift(e, .{ .into = into, .from = self.t().none_id });
    }
    var from = actual;
    while (!CompatCheck.meets(self.ctx, from, into)) from = sema.copiedThrough(self.ctx, from) orelse return self.ctx.recordLift(e, null);
    switch (ts.get(from)) {
        // `?none` copies out the `none` it views, and `<none` and
        // `+none` are the `none` they move or clone: each becomes the
        // optional as `none` does.
        .none_literal => return self.ctx.recordLift(e, if (from != actual or e.isKind(.move) or e.isKind(.clone)) .{ .into = into, .from = self.t().none_id } else null),
        .noreturn, .invalid, .unknown => return self.ctx.recordLift(e, null),
        else => {},
    }
    if (CompatCheck.optionalDepth(self.ctx, from) >= CompatCheck.optionalDepth(self.ctx, into)) return self.ctx.recordLift(e, null);
    try self.ctx.recordLift(e, .{ .into = into, .from = from });
}

pub fn recordAdaptedType(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    const lifted = liftTarget(self, expected);
    if (CompatCheck.copiedOut(self.ctx, actual, expected)) return readOf(self, e, actual, .{ .slot = expected });
    if (self.ctx.types.get(actual) == .write_view) switch (self.ctx.types.get(lifted)) {
        .read_view => |inner| if (sema.viewByValue(self.ctx, inner)) return readOf(self, e, actual, .narrow),
        else => {},
    };
    if (actual != self.t().int_literal_id and actual != self.t().float_literal_id) return;
    const target = lifted;
    // A literal below `n` is a `Slot[n]`, checked as it is given one.
    if (self.ctx.types.get(target) == .slot and actual == self.t().int_literal_id) {
        try self.ctx.recordType(e, target);
        try recordLiteralType(self, e, target);
        return BuiltinCheck.checkLiteralFits(self, e, target);
    }
    if (!sema.isNumeric(self.ctx, target)) return;
    if (self.ctx.types.get(target) == .float) if (integerOnlyOp(e)) |op| {
        return self.errAt(op, "operator `{s}` is for integers, and its literal operands here take the type `{s}`", .{ @tagName(op.kind().?), try self.tyName(target) });
    };
    try self.ctx.recordType(e, target);
    try recordLiteralType(self, e, target);
    if (actual == self.t().int_literal_id) try BuiltinCheck.checkLiteralFits(self, e, target);
    if (self.ctx.types.get(target) == .float) try checkWholeDivision(self, e);
    try checkFloatConstant(self, e, target);
}

/// Whether `e` hands over a write view to a binding: each leaf of the
/// value it gives (`sema.yieldedLeaves`: through an `if`, `match`,
/// block, `??`, `catch`, `e!`, `e?`, and a loop used as a value) is a
/// call's result, `!x`, `<w`, or a jump.
pub fn yieldsWriteView(self: *Checker, e: Sexp) Error!bool {
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
    if (leaves.items.len == 0) return false;
    for (leaves.items) |leaf| switch (leaf.kind() orelse return false) {
        .call, .result_part, .write, .move, .@"return", .@"break", .@"continue", .panic => {},
        else => return false,
    };
    return true;
}

/// Every path in `decl` with a view of a place as its base (`(!p).x`,
/// `(?arr)[0]`, `(<(!p)).x`, `(?t).f(1)`): reported, in one walk over
/// the typed tree that visits each field, element, and slice once, so
/// no typing routine can route a path around the rule. The view goes
/// on the whole path (`!p.x`), and an assignment shows the write
/// itself (`p.x = 5`). What a base is comes from `viewOf`. Not this
/// rule's: a method's self (the positive fact `methods`), a value
/// that branches (`(!a if c else !b).x`), which `viewOf` calls no
/// view, and a view of a slice (`(?t[..])[0]`), whose written `!`
/// only read is decided as any such read (`writeViewRead`).
pub fn checkViewBases(self: *Checker, n: Sexp, root: Sexp, in_block: bool, module_level: bool) Error!void {
    if (n != .list) return;
    if (n.isKind(.member) or n.isKind(.index)) try viewBase(self, n, root, in_block, module_level);
    // A statement's parts are hinted at as that statement: each of a
    // block's statements, and an expression a function, a closure, or
    // a `match` arm has for its body. Only a block's statement can
    // have a binding put before it.
    const kind = n.kind() orelse .module;
    for (n.items()) |x| {
        const body = (kind == .lambda or kind == .fun or kind == .sub or kind == .arm) and x == .list and !x.isKind(.block) and isBodyOf(n, x);
        if (kind == .block or body) {
            try checkViewBases(self, x, x, kind == .block, false);
        } else try checkViewBases(self, x, root, in_block, module_level);
    }
}

/// Whether `x` is the body of `n`: a function's, a closure's, or an
/// arm's.
pub fn isBodyOf(n: Sexp, x: Sexp) bool {
    const body = switch (n.kind() orelse return false) {
        .lambda => ir.Lambda.body(n),
        .fun => ir.get(n, .body),
        .sub => ir.get(n, .body),
        .arm => ir.get(n, .body),
        else => return false,
    };
    return CompatCheck.sameExpr(body, x);
}

/// `e`, a field, element, or slice, in statement `root` (a block's
/// statement where `in_block`, or a module-level declaration):
/// reported where its object is a view of a place (`checkViewBases`).
pub fn viewBase(self: *Checker, e: Sexp, root: Sexp, in_block: bool, module_level: bool) Error!void {
    const obj = ir.get(e, .object);
    const view = viewOf(self, obj) orelse return;
    if (self.methods.contains(CompatCheck.nodeId(e))) return;
    // The element of a Cell's List, assigned: the view marks the Cell,
    // whose elements are copies and cannot be viewed.
    if (e.isKind(.index) and view.isKind(.write) and CompatCheck.cellListElement(self.ctx, self.ctx.typeOf(obj) orelse sema.type_invalid) != null) return;
    if (CompatCheck.isCallee(root, e)) {
        // Self sigil the parser moved onto a call of a field
        // holding functions (`!p.f[0]()`) is the call's to report, and
        // so is a method the call did not find (`(!s).nope()`).
        if (isSelfSigil(self, obj)) return;
        if (!namesField(self, obj, e)) return;
    }
    var fix: Checker.ViewBaseFix = .{ .c = self, .root = root };
    if (CompatCheck.viewsSlice(view)) {
        const ty = self.ctx.typeOf(obj) orelse return;
        if (writtenWriteView(self, obj, ty) == null) return;
        if ((try fix.useOf(e, obj)).writes) return;
        _ = try writeViewRead(self, obj, ty, .{ .path = e });
        return;
    }
    try fix.collect(fix.root);
    const own = fix.edit(obj) orelse try fix.add(e, obj);
    const shown = try CompatCheck.oneLine(self.ctx.arena.allocator(), CallCheck.sourceText(self, e));
    const head = "`{s}`: put the sigil on the whole path, not its base";
    // No rewrite compiles where the path writes through a read view
    // or a shared handle, takes a part that is no optional, or binds
    // a temporary where no statement can go first; each says why.
    if (own.writes and view.isKind(.read)) return self.errAt(obj, head ++ "; and nothing is written through a read view", .{shown});
    if (own.shared and (own.writes or std.mem.findScalar(u8, own.open, '!') != null)) return self.errAt(obj, head ++ "; and nothing is written through a shared handle (`*T`), which other handles may see", .{shown});
    if (own.taken and !own.temp and !own.optional) return self.errAt(obj, head ++ "; and `<` takes out only an optional field or element, leaving `none`", .{shown});
    // The hint is the line the statement is on: a statement spread
    // over lines, or a module-level value, which no plain path makes
    // constant, gets none. A view its own check rejected gets none,
    // and so does a context no plain form fits.
    const src = self.ctx.source;
    const sp = self.ctx.span(obj);
    var ws: parser.Span = .{ .start = own.at, .end = own.at };
    while (ws.start > 0 and src[ws.start - 1] != '\n') ws.start -= 1;
    while (ws.start < own.at and (src[ws.start] == ' ' or src[ws.start] == '\t')) ws.start += 1;
    while (ws.end < src.len and src[ws.end] != '\n') ws.end += 1;
    var stmt = ownSpan(self, root);
    stmt.start = fix.start(root, stmt.start);
    const spread = stmt.start < ws.start or std.mem.trimEnd(u8, src[stmt.start..@max(stmt.start, stmt.end)], " \t\n").len > ws.end - stmt.start;
    if (own.none or own.to > ws.end or spread or module_level) return self.errAt(obj, head, .{shown});
    // An error inside the view, or in the path after it (a field it
    // does not have, an index out of bounds, a method it lacks), is
    // what the path still needs: it gets no rewrite.
    for (self.ctx.diagnostics.items) |d| {
        if (d.severity != .@"error" or d.lint or d.module != 0) continue;
        if ((d.pos > sp.start and d.pos < sp.end) or (d.pos >= own.end and d.pos < own.reach)) return self.errAt(obj, head, .{shown});
    }
    // A part of a temporary assigned, taken, or bound by a header: the
    // temporary is bound to a name first, in a statement put before
    // this one, where one can go.
    if (own.temp and (own.assigned or own.header or own.taken)) {
        if (!in_block or stmt.start != ws.start) return self.errAt(obj, head ++ "; and a part of a temporary is changed or bound only through a name: bind the temporary first, in a statement of its own", .{shown});
        const name = for ([_][]const u8{ "t", "tmp", "tmp1", "tmp2", "tmp3", "tmp4" }) |n| {
            if (!CompatCheck.hasCodeWord(src, n)) break n;
        } else "tmp5";
        fix.named = .{ .view = obj, .name = name };
        var out: std.ArrayList(u8) = .empty;
        try fix.write(&out, ws.start, ws.end);
        var made: std.ArrayList(u8) = .empty;
        const bs = self.ctx.span(own.place);
        try fix.write(&made, bs.start, bs.end);
        return self.errAt(obj, head ++ "; to change or bind a part of a temporary, bind it to a name first: `{s} = {s}`, then `{s}`", .{ shown, name, made.items, out.items });
    }
    var out: std.ArrayList(u8) = .empty;
    try fix.write(&out, ws.start, ws.end);
    try self.errAt(obj, head ++ ": `{s}`", .{ shown, out.items });
}

/// Whether member `e` of `obj` names a data field of `obj`'s type: a
/// call of it calls the function the field holds, and its object is a
/// path's base, not a self.
pub fn namesField(self: *Checker, obj: Sexp, e: Sexp) bool {
    if (!e.isKind(.member)) return true;
    const ty = self.ctx.typeOf(obj) orelse return false;
    if (self.isPoison(ty)) return false;
    return sema.lookupDataFieldConst(self.ctx, sema.unwrapAccess(self.ctx, ty), self.text(ir.Member.name(e))) != null;
}

/// The view the object of a path, `e`, is: `?x` or `!x`, also moved,
/// `<(!p)` (Core §4: a moved view is still that view), by what `e`
/// hands over (`sema.handsOver`), recorded the first time it is asked
/// (`view_of`). Null for anything else, a value that branches among
/// them.
pub fn viewOf(self: *Checker, e: Sexp) ?Sexp {
    if (e != .list) return null;
    const id = CompatCheck.nodeId(e);
    if (self.view_of.get(id)) |known| return known;
    const view = viewUnder(self, e);
    self.view_of.put(self.ctx.allocator, id, view) catch {};
    return view;
}

/// The place `view` views, under every sigil and every `<` of a view
/// on the way: `p` in `!(<(!p))`.
pub fn viewedThrough(self: *Checker, view: Sexp) Sexp {
    var e = CompatCheck.viewedPlace(view);
    while (e.isKind(.move)) {
        const inner = viewOf(self, e) orelse break;
        e = CompatCheck.viewedPlace(inner);
    }
    return e;
}

pub fn viewUnder(self: *const Checker, e: Sexp) ?Sexp {
    return switch (hands(self, e).kind) {
        .view => e,
        .made => if (e.isKind(.move)) viewUnder(self, ir.Move.operand(e)) else null,
        else => null,
    };
}

/// `e`'s source with each view that is a path's base taken off,
/// for a diagnostic that names the place (`!p.o as v`).
pub fn plainText(self: *Checker, e: Sexp) Error![]const u8 {
    var fix: Checker.ViewBaseFix = .{ .c = self, .root = e, .bare = true };
    try fix.collect(e);
    if (fix.edits.items.len == 0) return CallCheck.sourceText(self, e);
    var out: std.ArrayList(u8) = .empty;
    const sp = self.ctx.span(e);
    try fix.write(&out, fix.start(e, sp.start), sp.end);
    return out.items;
}

/// The part of statement `s` that is not another statement's: all of
/// a simple statement, and the header of a loop, an `if`, or a
/// `match`, up to its body.
pub fn ownSpan(self: *Checker, s: Sexp) parser.Span {
    var sp = self.ctx.span(s);
    const stmt = if (s.isKind(.labeled)) ir.Labeled.stmt(s) else s;
    const body: Sexp = switch (stmt.kind() orelse return sp) {
        .@"while" => ir.While.body(stmt),
        .@"for" => ir.For.body(stmt),
        .@"if" => ir.If.then(stmt),
        .match => if (ir.Match.arms(stmt).len > 0) ir.Match.arms(stmt)[0] else .nil,
        else => .nil,
    };
    if (body != .nil) sp.end = @min(sp.end, self.startOf(body));
    return sp;
}

/// Record that `e`, a view of type `ty`, is read through (`Facts.reads`),
/// the one place type checking records it: a read as a value is first
/// decided by `writeViewRead`.
pub fn readOf(self: *Checker, e: Sexp, ty: TypeId, how: Checker.ViewRead) Error!void {
    switch (how) {
        .slot, .value, .read_view_of_write, .read_view, .read_self, .path => if (try writeViewRead(self, e, ty, how)) return,
        .narrow, .reach => {},
    }
    try self.ctx.record(.reads, e, {});
}

/// The write view written at `e`, of type `ty`: `!x`, or `<!x`, which
/// moves the view `!x` makes. Its `!` says the view is held to write.
/// Null for anything else, a held write view included (`w`, `h.w`, a
/// `!T` parameter), which is read as a bare name is (Core sentence 1).
pub fn writtenWriteView(self: *Checker, e: Sexp, ty: TypeId) ?Sexp {
    if (self.ctx.types.get(ty) != .write_view) return null;
    return viewUnder(self, e);
}

/// Whether `e`, of type `ty`, read as a value `how` says, is a write
/// view written there (`writtenWriteView`): its `!` would be ignored,
/// so it is rejected (Core §4), and reported here. The one decider
/// for every read of a view as a value (`readOf`), `print`'s values,
/// and `?!x`; inference binds such a view as the slot then reads it
/// (`argType`).
pub fn writeViewRead(self: *Checker, e: Sexp, ty: TypeId, how: Checker.ViewRead) Error!bool {
    const view = writtenWriteView(self, e, ty) orelse {
        // A value that branches or loops is read at each leaf it may
        // be (`sema.yieldedLeaves`), a written view among them too.
        if (!sema.yieldsPart(e) and !FlowCheck.isValueLoop(self, e)) return false;
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
        var any = false;
        for (leaves.items) |leaf| {
            if (CompatCheck.sameExpr(leaf, e)) continue;
            const leaf_ty = self.ctx.typeOf(leaf) orelse continue;
            if (try writeViewRead(self, leaf, leaf_ty, how)) any = true;
        }
        return any;
    };
    try self.ctx.recordType(e, self.t().invalid_id);
    // A `!` its operand's own check reported (one before a write
    // method's temporary self) is reported once.
    const sp = self.ctx.span(e);
    for (self.ctx.diagnostics.items) |d| if (d.severity == .@"error" and d.module == 0 and d.pos >= sp.start and d.pos < sp.end) return true;
    try ignoredWriteView(self, e, view, how);
    return true;
}

/// Whether a value of type `ty` goes where only a read view does: a
/// `?T`, a `[]T`, or a `?String` (also as an optional), which holds no
/// write view.
pub fn readViewSlot(self: *Checker, ty: TypeId) bool {
    const lifted = liftTarget(self, ty);
    if (sema.holdsWriteView(self.ctx, lifted)) return false;
    return switch (self.ctx.types.get(lifted)) {
        .read_view, .slice, .string_view => true,
        else => false,
    };
}

/// The diagnostic for `e`, a write view written where it is read as a
/// value (`writeViewRead`), with the forms that say what is meant: a
/// slot whose type holds the write view, or a copy written as one.
pub fn ignoredWriteView(self: *Checker, e: Sexp, made: Sexp, how: Checker.ViewRead) Error!void {
    const a = self.ctx.arena.allocator();
    const place_node = unviewed(made);
    const place = CallCheck.sourceText(self, place_node);
    const head = "`{s}` here is read, not held: {s}. ";
    const shown = try plainText(self, e);
    const value_ty = switch (how) {
        .slot, .value => |slot_ty| slot_ty,
        else => sema.unwrapViews(self.ctx, self.ctx.typeOf(place_node) orelse self.t().invalid_id),
    };
    const ty = try self.tyName(value_ty);
    switch (how) {
        .slot => {},
        .read_view_of_write => return self.errAt(e, head ++ "Write `?{s}`", .{ shown, "`?` passes it on as a read view", place }),
        .read_view => |view| {
            const slot = self.expect.slot;
            const in_slot = CompatCheck.sameExpr(e, slot.value) and slot.call != .nil and argOf(slot.call, e);
            const owner = if (!in_slot)
                try a.print("a `{s}`", .{try self.tyName(view)})
            else if (slot.field)
                try a.print("`{s}`", .{slot.owner})
            else
                try a.print("`{s}`", .{try StdFormCheck.calleeName(self, ir.Call.callee(slot.call))});
            const viewed = try a.print("?{s}", .{place});
            const fix = if (in_slot) try spliced(self, slot.call, &.{e}, &.{viewed}) else viewed;
            return self.errAt(e, "`{s}` here is read, not held: {s} only reads `{s}`; write `{s}`", .{ shown, owner, place, fix });
        },
        .path => |path| {
            // The slice viewed to read: `(?arr[..])[0]`.
            const ps = self.ctx.span(path);
            const ls = self.ctx.span(made);
            const fix = if (ls.start >= ps.start and ls.end <= ps.end) try std.mem.concat(a, u8, &.{ diag.textBetween(self.ctx.source, ps.start, ls.start), "?", place, diag.textBetween(self.ctx.source, ls.end, ps.end) }) else try a.print("?{s}", .{place});
            return self.errAt(e, head ++ "Write `{s}`", .{ shown, try a.print("`{s}` only reads the place it reaches", .{CallCheck.sourceText(self, path)}), fix });
        },
        .read_self => |method| {
            const call = self.expect.current_call orelse Sexp.nil;
            const fix = if (call != .nil) try unparenthesized(self, call, e, place) else try a.print("{s}(...)", .{try sema.memberText(a, place, method)});
            return self.errAt(e, "`{s}` here is read, not held: `{s}` only reads `{s}`; write `{s}`", .{ shown, method, place, fix });
        },
        else => return self.errAt(e, head ++ "Write `{s}`", .{ shown, try a.print("only its `{s}` is read here", .{ty}), place }),
    }
    const slot = self.expect.slot;
    const in_slot = CompatCheck.sameExpr(e, slot.value) and slot.call != .nil and argOf(slot.call, e);
    if (in_slot and slot.field) self.expect.ignored_in = slot.call;
    // What takes the value, and the value written without the `!`s
    // the slots of the call ignore.
    const what = if (!in_slot)
        try a.print("{s} `{s}` goes here", .{ CompatCheck.article(ty), ty })
    else
        try a.print("`{s}` {s} {s} `{s}`", .{
            if (slot.field) slot.owner else try StdFormCheck.calleeName(self, ir.Call.callee(slot.call)),
            if (slot.field) "stores" else "takes",
            CompatCheck.article(ty),
            ty,
        });
    const copy = if (in_slot) try withoutViews(self, slot.call, slot.views, e) else place;
    const copied = if (!in_slot) "to copy the value" else if (slot.field) "to store a copy" else "to pass a copy";
    // A write view of a value made here would not outlive its
    // statement, and a field never holds one (`sema.misplaced`): the
    // copy is what can be meant.
    if (hands(self, place_node).kind != .place or (in_slot and slot.field)) return self.errAt(e, head ++ "Write `{s}` {s}", .{ shown, what, copy, copied });
    const must = if (in_slot)
        try a.print("to make a write view of `{s}`, the parameter must be a `{s}`", .{ place, try self.tyName(try writeViewOf(self, if (slot.declared != sema.type_invalid) slot.declared else value_ty)) })
    else
        try a.print("to keep a write view of `{s}`, the type here must be `{s}`", .{ place, try self.tyName(try writeViewOf(self, value_ty)) });
    return self.errAt(e, head ++ "Write `{s}` {s}; {s}", .{ shown, what, copy, copied, must });
}

/// The source of `whole` with `part`, and the parentheses written
/// around it (`(!p)` in `(!p).x`), written as `with`.
pub fn unparenthesized(self: *Checker, whole: Sexp, part: Sexp, with: []const u8) Error![]const u8 {
    var ws = self.ctx.span(whole);
    if (whole.isKind(.call) and ir.Call.callee(whole).isKind(.member)) ws.start = @min(ws.start, self.ctx.span(ir.Member.object(ir.Call.callee(whole))).start);
    var ps = self.ctx.span(part);
    if (ps.start < ws.start or ps.end > ws.end) return with;
    // The parentheses stay where what is left needs them.
    const left = unviewed(part);
    const bare = left == .src or left.isKind(.member) or left.isKind(.index) or left.isKind(.call);
    if (bare and ps.start > ws.start and ps.end < ws.end and diag.textBetween(self.ctx.source, ps.start - 1, ps.start).len == 1 and self.ctx.source[ps.start - 1] == '(' and diag.textBetween(self.ctx.source, ps.end, ps.end + 1).len == 1 and self.ctx.source[ps.end] == ')') {
        ps.start -= 1;
        ps.end += 1;
    }
    return std.mem.concat(self.ctx.arena.allocator(), u8, &.{ diag.textBetween(self.ctx.source, ws.start, ps.start), with, diag.textBetween(self.ctx.source, ps.end, ws.end) });
}

/// A method's self with the sigils written before it taken off
/// (`?c`, `!c`, `<c`: `c`).
pub fn selfPlace(e: Sexp) Sexp {
    var node = e;
    while (node.isKind(.read) or node.isKind(.write) or node.isKind(.move)) node = ir.get(node, .operand);
    return node;
}

/// The place a write view views, every `!` and `<` written before it
/// taken off (`!!n`, `<!n`: `n`).
pub fn unviewed(e: Sexp) Sexp {
    var node = e;
    while (node.isKind(.write) or node.isKind(.move)) node = ir.get(node, .operand);
    return node;
}

/// Whether `value` is one of `call`'s arguments, by position or by name.
pub fn argOf(call: Sexp, value: Sexp) bool {
    if (!call.isKind(.call)) return false;
    for (ir.Call.args(call)) |arg| {
        const v = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
        if (CompatCheck.sameExpr(v, value)) return true;
    }
    return false;
}

/// `call` as written with each of `views`, arguments whose slots
/// ignore their `!`, written as the place it views; `e` is one.
pub fn withoutViews(self: *Checker, call: Sexp, views: []const Sexp, e: Sexp) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var parts: std.ArrayList(Sexp) = .empty;
    var withs: std.ArrayList([]const u8) = .empty;
    var has_e = false;
    for (views) |l| {
        if (CompatCheck.sameExpr(l, e)) has_e = true;
        try parts.append(a, l);
        try withs.append(a, CallCheck.sourceText(self, unviewed(l)));
    }
    if (!has_e) {
        try parts.append(a, e);
        try withs.append(a, CallCheck.sourceText(self, unviewed(e)));
    }
    return spliced(self, call, parts.items, withs.items);
}

/// The arguments of a call or construction written `!x` (or `<!x`)
/// whose slot type holds no write view: each would be read, its `!`
/// ignored, which a diagnostic's suggested copy writes without.
/// `types[i]` is the slot of `values[i]`.
pub fn plainSlotViews(self: *Checker, values: []const Sexp, types: []const TypeId) Error![]const Sexp {
    var out: std.ArrayList(Sexp) = .empty;
    for (values, types) |v, ty| {
        const written = v.isKind(.write) or (v.isKind(.move) and ir.Move.operand(v).isKind(.write));
        if (!written) continue;
        if (sema.holdsWriteView(self.ctx, ty)) continue;
        try out.append(self.ctx.arena.allocator(), v);
    }
    return out.items;
}

/// The type that holds a write view where `ty` holds a value: `!T`,
/// and `(!T)?` for a `T?`.
pub fn writeViewOf(self: *Checker, ty: TypeId) Error!TypeId {
    return switch (self.ctx.types.get(ty)) {
        .optional => |inner| self.ctx.intern(.{ .optional = try writeViewOf(self, inner) }),
        .fallible => |inner| self.ctx.intern(.{ .fallible = .{ .ok = try writeViewOf(self, inner.ok) } }),
        else => self.ctx.intern(.{ .write_view = ty }),
    };
}

/// The source of `whole` with each of `parts`, which it contains and
/// which do not overlap, written as the matching `withs`.
pub fn spliced(self: *Checker, whole: Sexp, parts: []const Sexp, withs: []const []const u8) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var w = self.ctx.span(whole);
    // A self's sigil is written before the call's own span.
    if (whole.isKind(.call) and ir.Call.callee(whole).isKind(.member)) w.start = @min(w.start, self.ctx.span(ir.Member.object(ir.Call.callee(whole))).start);
    const order = try a.alloc(usize, parts.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, Checker.SpanOrder{ .ctx = self.ctx, .parts = parts }, Checker.SpanOrder.less);
    var out: std.ArrayList(u8) = .empty;
    var at = w.start;
    for (order) |i| {
        const p = self.ctx.span(parts[i]);
        if (p.start < at or p.end > w.end) continue;
        try out.appendSlice(a, diag.textBetween(self.ctx.source, at, p.start));
        try out.appendSlice(a, withs[i]);
        at = p.end;
        // `@name` written as `(!@)`: the member takes its `.` back.
        const with = withs[i];
        if (with.len > 0 and with[with.len - 1] == ')' and at < self.ctx.source.len and rig.isIdentStart(self.ctx.source[at])) try out.append(a, '.');
    }
    try out.appendSlice(a, diag.textBetween(self.ctx.source, at, w.end));
    return out.items;
}

/// An operator in literal arithmetic `e` that only integers have
/// (bitwise, shift, wrapping), whose literals cannot take a float
/// type.
pub fn integerOnlyOp(e: Sexp) ?Sexp {
    const h = e.kind() orelse return null;
    return switch (h) {
        .neg => integerOnlyOp(ir.Neg.operand(e)),
        .@"if" => integerOnlyOp(ir.If.then(e)) orelse integerOnlyOp(ir.If.@"else"(e)),
        .@"+", .@"-", .@"*", .@"/", .@"%" => integerOnlyOp(ir.get(e, .left)) orelse integerOnlyOp(ir.get(e, .right)),
        .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>" => e,
        else => null,
    };
}

/// Integer-literal arithmetic that takes no type from its context is
/// an `Int`.
pub fn defaultIntLiteral(self: *Checker, e: Sexp) Error!void {
    try recordLiteralType(self, e, self.t().int_id);
    try BuiltinCheck.checkLiteralFits(self, e, self.t().int_id);
}

/// Integer-literal arithmetic given integer type `target` is
/// computed in it: each operation in `e` records the type, so that a
/// wrapping one wraps there and a shift is folded in its width
/// (`sema.cteval.foldInt`), and the emitter types it so. A constant shift
/// amount must be below that width.
pub fn recordLiteralType(self: *Checker, e: Sexp, target: TypeId) Error!void {
    const h = e.kind() orelse return;
    switch (h) {
        .neg => try recordLiteralType(self, ir.Neg.operand(e), target),
        .@"if" => {
            try recordLiteralType(self, ir.If.then(e), target);
            try recordLiteralType(self, ir.If.@"else"(e), target);
        },
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^" => {
            try recordLiteralType(self, ir.get(e, .left), target);
            try recordLiteralType(self, ir.get(e, .right), target);
        },
        .@"<<", .@"<<%", .@">>" => {
            try recordLiteralType(self, ir.get(e, .left), target);
            if (self.ctx.types.get(target) != .int) return;
            const amount = ir.get(e, .right);
            const bits = self.ctx.types.get(target).int.width();
            if (ExprCheck.constInt(self, amount)) |v| if (v >= bits) {
                try self.errAt(amount, "shift amount `{d}` is out of range for `{s}` (0..{d})", .{ v, try self.tyName(target), bits - 1 });
            };
        },
        else => return,
    }
    try self.ctx.recordType(e, target);
}

/// A division of whole-number literals, `7 / 2`, divides integers:
/// a literal's context reaches through `+`, `-`, and `*`, but not
/// through `/` or `%`. Where the literals' value is a float, reached
/// that way, it is rejected, since it would silently be `3.0`.
pub fn checkWholeDivision(self: *Checker, e: Sexp) Error!void {
    const div = CompatCheck.wholeDivision(self.ctx.source, e) orelse return;
    const left = ir.get(div, .left);
    const right = ir.get(div, .right);
    const op = @tagName(div.kind().?);
    const a = self.ctx.arena.allocator();
    const fix = if (left == .src)
        try a.print("{s}.0 {s} {s}", .{ self.text(left), op, CallCheck.sourceText(self, right) })
    else
        try a.print("Float({s}) {s} {s}", .{ CallCheck.sourceText(self, left), op, CallCheck.sourceText(self, right) });
    // A remainder of whole numbers is the same whole number as a
    // float's: only its type differs.
    if (div.isKind(.@"%")) return self.errAt(div, "`{s}` is a whole-number remainder; write `{s}` for a Float", .{ CallCheck.sourceText(self, div), fix });
    const whole: []const u8 = if (ExprCheck.constInt(self, div)) |v| try a.print(" ({d})", .{v}) else "";
    const folded = sema.cteval.foldFloat(f64, self.ctx, div, false);
    if (folded == .value) {
        const f = folded.value;
        const shown = if (f == @trunc(f) and @abs(f) < 1e15) try a.print("{d}.0", .{f}) else try a.print("{d}", .{f});
        return self.errAt(div, "`{s}` divides whole numbers{s}; for {s} write `{s}`", .{ CallCheck.sourceText(self, div), whole, shown, fix });
    }
    try self.errAt(div, "`{s}` divides whole numbers{s}; for a float write `{s}`", .{ CallCheck.sourceText(self, div), whole, fix });
}

/// The number literals of an expression given float type `target`
/// are values of it, and so is each operation on them, which the
/// program computes in that type: a float literal must be in range,
/// an integer literal exact, and a constant operation must not
/// overflow. What was already found in `Float` arithmetic, where
/// literals default to it, is not reported again for `F32`.
pub fn checkFloatConstant(self: *Checker, e: Sexp, target: TypeId) Error!void {
    const bits = switch (self.ctx.types.get(target)) {
        .float => |f| f.bits,
        else => return,
    };
    switch (e) {
        .src => {
            const s = self.text(e);
            if (sema.isFloatLiteralText(s)) {
                const v = sema.cteval.floatLiteralAs(f64, s);
                if (bits == 32 and std.math.isFinite(v) and @abs(v) > std.math.floatMax(f32)) {
                    try self.errAt(e, "float literal `{s}` does not fit in `{s}`", .{ s, try self.tyName(target) });
                }
            } else if (sema.isIntLiteralText(s)) {
                const v = std.fmt.parseInt(Wide, s, 0) catch return;
                if (!CompatCheck.holdsInt(self.ctx, target, v) and (bits != 32 or CompatCheck.holdsInt(self.ctx, self.t().float_id, v))) {
                    try self.errAt(e, "integer value `{d}` does not fit exactly in `{s}`", .{ v, try self.tyName(target) });
                }
            }
        },
        .list => switch (e.kind() orelse return) {
            .neg => try checkFloatConstant(self, ir.Neg.operand(e), target),
            .@"if" => {
                try checkFloatConstant(self, ir.If.then(e), target);
                try checkFloatConstant(self, ir.If.@"else"(e), target);
            },
            .@"+", .@"-", .@"*", .@"/", .@"%" => {
                try checkFloatConstant(self, ir.get(e, .left), target);
                try checkFloatConstant(self, ir.get(e, .right), target);
                const overflows = if (bits == 32)
                    sema.cteval.floatOverflows(f32, self.ctx, e) and !sema.cteval.floatOverflows(f64, self.ctx, e)
                else
                    sema.cteval.floatOverflows(f64, self.ctx, e);
                if (overflows) try self.errAt(e, "this constant expression overflows `{s}`", .{try self.tyName(target)});
            },
            else => {},
        },
        else => {},
    }
}
