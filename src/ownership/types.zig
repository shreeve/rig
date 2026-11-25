//! What the checker reads of sema's facts: each type's facts, and each
//! expression's classification (docs/CORE.md section 9).

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const Sexp = parser.Sexp;
const TypeId = sema.TypeId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const Owning = state.Owning;
const Ref = state.Ref;
const Value = state.Value;
const VarId = state.VarId;

pub fn sexpMentionsView(t: Sexp) bool {
    if (t != .list) return false;
    for (t.items()) |c| {
        if (c == .tag and (c.tag == .read_view or c.tag == .write_view)) return true;
        if (sexpMentionsView(c)) return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Core section 9: per type, one fact each, from sema's facts
// -----------------------------------------------------------------------------

pub fn text(self: *const Checker, node: Sexp) []const u8 {
    return switch (node) {
        .src => |s| rig.leafText(self.source, s),
        else => "",
    };
}

/// The structure of a type.
pub fn typeData(self: *const Checker, id: TypeId) sema.Type {
    return self.sema.types.get(id);
}

/// The type of the symbol declared at `decl_pos`.
pub fn symType(self: *const Checker, decl_pos: u32) ?TypeId {
    const ctx = self.sema;
    const sid = ctx.symbolAt(decl_pos) orelse return null;
    return self.known(ctx.symbols.items[sid].ty);
}

/// The type ctx recorded for an expression.
pub fn exprType(self: *const Checker, e: Sexp) ?TypeId {
    const ctx = self.sema;
    return self.known(ctx.typeOf(e) orelse return null);
}

pub fn known(self: *const Checker, ty: TypeId) ?TypeId {
    const ctx = self.sema;
    if (ty == ctx.types.unknown_id or ty == ctx.types.invalid_id) return null;
    return ty;
}

pub fn isVoid(self: *const Checker, ty: ?TypeId) bool {
    const t = ty orelse return false;
    return self.typeData(t) == .void;
}

/// The declared return type of the function or method named at `name`.
pub fn fnReturnType(self: *const Checker, name: Sexp) ?TypeId {
    const t = self.typeData(self.exprType(name) orelse return null);
    if (t != .function) return null;
    return self.known(t.function.returns);
}

pub fn returnMayView(self: *Checker, ret_ty: ?TypeId, returns: Sexp) bool {
    if (sexpMentionsView(returns)) return true;
    return ret_ty != null and self.mayCarryLoan(ret_ty);
}

pub fn refOfType(self: *const Checker, ty: ?TypeId) Ref {
    const t = ty orelse return .none;
    return switch (self.typeData(t)) {
        .read_view => .read,
        .write_view => .write,
        else => .none,
    };
}

/// Whether `ty` is a view (`sema.isViewType`).
pub fn isView(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return sema.isViewType(ctx, ty orelse return false);
}

/// The type a view type refers to.
pub fn pointee(self: *const Checker, ty: ?TypeId) ?TypeId {
    const t = ty orelse return null;
    return switch (self.typeData(t)) {
        .read_view, .write_view => |inner| inner,
        else => t,
    };
}

/// A value copied implicitly where it is used (`sema.copies`):
/// not one whose copying depends on a type parameter.
pub fn copies(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return sema.copies(ctx, ty orelse return false) == .yes;
}

/// A value of `ty` copies at `pos`, where `$plain` has held of each
/// type parameter it holds (`sema.copiesNarrowed`).
pub fn copiesNarrowed(self: *Checker, ty: ?TypeId, pos: u32) Error!bool {
    const ctx = self.sema;
    return sema.copiesNarrowed(ctx, ty orelse return false, pos, self.arena());
}

/// A view whose value is copied out where its context reads it
/// (`sema.copiedThrough`).
pub fn copiedThrough(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return sema.copiedThrough(ctx, ty orelse return false) != null;
}

/// A scalar (`sema.isScalar`: a number, `Bool`, `?String`, or a
/// vector), or an error. A method call takes any other self by
/// address, so a later argument must not change it before the call
/// reads it.
pub fn isScalar(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    const t = ty orelse return false;
    return sema.isScalar(ctx, t) or ctx.types.get(t) == .any_error;
}

/// A `String`, whose bytes a `?String` may view.
pub fn isString(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    const t = ty orelse return false;
    return t == ctx.types.string_id or sema.boxedType(ctx, t) == ctx.types.string_id;
}

/// A `List[T]`.
pub fn isList(self: *const Checker, ty: TypeId) bool {
    const ctx = self.sema;
    const t = ctx.types.get(ty);
    return t == .parameterized_nominal and t.parameterized_nominal.sym == ctx.list_sym_id;
}

/// A `List[T]` or a `Table[T, n]`: elements held behind it, in memory
/// it owns, not in the var.
pub fn holdsElems(self: *const Checker, ty: TypeId) bool {
    const ctx = self.sema;
    return self.isList(ty) or sema.tableElem(ctx, ty) != null;
}

/// A List (or a view of one) whose elements move (`sema.moves`):
/// walked by a view of each slot.
/// Values of this type move (`sema.moves`) and cannot be copied
/// implicitly: null for a value that copies. The kind only chooses
/// the diagnostic (`kindLabel`).
pub fn owningKind(self: *const Checker, ty: ?TypeId) ?Owning {
    const ctx = self.sema;
    const t = ty orelse return null;
    return switch (sema.moves(ctx, t)) {
        .no => null,
        .depends => .generic,
        .yes => self.kindLabel(t),
    };
}

/// How a diagnostic names the kind of a value that moves.
pub fn kindLabel(self: *const Checker, t: TypeId) Owning {
    const ctx = self.sema;
    var inner = t;
    while (ctx.types.get(inner) == .optional) inner = ctx.types.get(inner).optional;
    const name = switch (ctx.types.get(inner)) {
        .parameterized_nominal => |pn| ctx.symbols.items[pn.sym].name,
        else => if (sema.nominalDecl(ctx, inner)) |d| d.symbol().name else "value",
    };
    if (!sema.typeHasDropGlue(ctx, t) and sema.isUnique(ctx, t)) {
        // An array of unique values is named by its element.
        var elem = inner;
        while (ctx.types.get(elem) == .array or ctx.types.get(elem) == .optional) elem = switch (ctx.types.get(elem)) {
            .array => |a| a.elem,
            .optional => |o| o,
            else => unreachable,
        };
        return .{ .unique = switch (ctx.types.get(elem)) {
            .parameterized_nominal => |pn| ctx.symbols.items[pn.sym].name,
            else => if (sema.nominalDecl(ctx, elem)) |d| d.symbol().name else "value",
        } };
    }
    return switch (ctx.types.get(inner)) {
        .shared => .shared,
        .weak => .weak,
        .string => .text,
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id) .list else if (pn.sym == ctx.box_sym_id) .box else .{ .drop_glue = name },
        else => .{ .drop_glue = name },
    };
}

/// Whether a value of this type can hold a marked view, or a `?String` that
/// may view a String. Unknown types are assumed to.
pub fn mayCarryLoan(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    const t = ty orelse return true;
    return sema.mayHoldView(ctx, t) or self.holdsItem(t);
}

/// Whether `v` carries a loan on memory the body owns: a value of its
/// own, a parameter it was given by value, or self's storage.
pub fn viewsOwned(self: *Checker, v: Value) bool {
    for (v.loans) |l| if (self.ownsLoan(l, 0)) return true;
    return false;
}

/// Whether loan `l` is on memory the body owns (`viewsOwned`).
pub fn ownsLoan(self: *Checker, l: Loan, depth: u32) bool {
    if (l.ext or self.isGlobal(l.root)) return false;
    if (l.frame) return true;
    return self.ownsVar(l.root, depth);
}

/// Whether var `id` is memory the body owns: self's storage, a value
/// of its own, or a parameter given by value. A view parameter is the
/// caller's; a loop element that views its collection's slot, and a
/// local view, are what they view.
pub fn ownsVar(self: *Checker, id: VarId, depth: u32) bool {
    const r = self.vars.items[id];
    if (r.kind == .param and std.mem.eql(u8, r.name, "@")) return true;
    if (r.kind == .param and r.ref != .none) return false;
    if (self.isGlobal(id)) return false;
    if (depth > 8) return true;
    if (r.elem_of) |c| if (r.elem_view or r.loop_view) return self.ownsVar(c, depth + 1);
    const ctx = self.sema;
    const viewing = r.ref != .none or if (r.ty) |t| sema.viewParam(ctx, t) else false;
    if (!viewing) return true;
    for (self.varValue(id).loans) |m| if (self.ownsLoan(m, depth + 1)) return true;
    return false;
}

/// The type a value of type `ty` reaches through its views.
pub fn reachedType(self: *const Checker, ty: ?TypeId) ?TypeId {
    const ctx = self.sema;
    return sema.unwrapViews(ctx, ty orelse return null);
}

/// Whether a value of type `ty` may write what it reaches: it holds a
/// write view, or its type is not known.
pub fn mayWrite(self: *const Checker, ty: ?TypeId) bool {
    return ty == null or self.carriesWriteView(ty);
}

/// Whether a value of this type holds a write view, which must not
/// be duplicated.
pub fn carriesWriteView(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return sema.holdsWriteView(ctx, ty orelse return false);
}

/// How a method call takes its self, from the signature ctx
/// resolved for the callee: `!@` writes, a `Self` value is consumed,
/// anything else reads. A shared handle is only ever read through.
pub fn selfMode(self: *const Checker, obj: Sexp, callee: Sexp) sema.SelfMode {
    if (obj.isKind(.move)) return .value;
    if (self.exprType(obj)) |t| if (self.typeData(t) == .shared) return .read;
    const f = self.typeData(self.exprType(callee) orelse return .read);
    if (f != .function or f.function.params.len == 0) return .read;
    return switch (self.typeData(f.function.params[0])) {
        .write_view => .write,
        .nominal, .parameterized_nominal, .imported_nominal => .value,
        else => .read,
    };
}

/// Whether `ty` is a shared or weak handle.
pub fn isHandleType(self: *const Checker, ty: ?TypeId) bool {
    const t = ty orelse return false;
    return switch (self.typeData(t)) {
        .shared, .weak => true,
        else => false,
    };
}

/// Whether `ty` is the type of something the type checker rejected.
pub fn isPoisonType(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return ty == null or ty == ctx.types.invalid_id;
}

/// Whether the type checker rejected `e` (its type is invalid).
pub fn rejected(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    return ctx.typeOf(e) == ctx.types.invalid_id;
}

/// Whether `ty` is an object or enum with a `drop` body of its own.
pub fn dropBodyType(self: *const Checker, ty: TypeId) bool {
    const ctx = self.sema;
    const decl = sema.nominalDecl(ctx, ty) orelse return false;
    var dctx = decl.ctx;
    var sym = decl.symbol();
    if (sema.isProxy(sym)) {
        if (sym.from.module_id == 0) return false;
        const foreign = dctx.foreign_semas.get(sym.from.module_id) orelse return false;
        dctx = foreign;
        sym = foreign.symbols.items[sym.from.sym];
    }
    for (sym.fields orelse &.{}) |fld| if (fld.is_drop_method) return true;
    return false;
}

/// `Cell`, `Signal`, or `List` when a value of type `ty` is one,
/// through views and shared handles.
pub fn builtinName(self: *const Checker, ty: ?TypeId) ?[]const u8 {
    const ctx = self.sema;
    var t = ty orelse return null;
    while (true) switch (ctx.types.get(t)) {
        .read_view, .write_view, .shared => |i| t = i,
        .parameterized_nominal => |pn| {
            if (pn.sym == ctx.cell_sym_id) return "Cell";
            if (pn.sym == ctx.signal_sym_id) return "Signal";
            if (pn.sym == ctx.list_sym_id) return "List";
            if (pn.sym == ctx.chan_sym_id) return "Chan";
            return null;
        },
        else => return null,
    };
}

// -----------------------------------------------------------------------------
// Per expression, one classification
// -----------------------------------------------------------------------------

/// What `e` hands over to its context (`sema.handsOver`).
pub fn hands(self: *const Checker, e: Sexp) sema.Hands {
    return sema.handsOverIn(self.source, self.sema, e);
}

/// Whether `e` is erased to an API object that views a copy
/// (`sema.Erasure.copy`).
pub fn erasesCopy(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    if (ctx.facts.erasures.count() == 0) return false;
    const er = ctx.erasureOf(e) orelse return false;
    return er.copy;
}

/// Whether `e` is viewed by `step` of the view table.
pub fn viewsBy(self: *const Checker, e: Sexp, step: sema.ViewStep) bool {
    const view = self.viewOf(e) orelse return false;
    return view.has(step);
}

/// `print` or `warn`, the built-ins that only read their values.
pub fn isPrint(self: *Checker, callee: Sexp) bool {
    if (callee != .src) return false;
    const name = self.text(callee);
    if (!std.mem.eql(u8, name, "print") and !std.mem.eql(u8, name, "warn")) return false;
    return self.sema.symbolOf(callee) == null;
}
