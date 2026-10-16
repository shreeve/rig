//! Storage facts: the hidden storage emit makes, decided once.
//!
//! After a module's expressions are checked, `plan` walks it and records,
//! for each expression or construct emit holds in hidden storage, a
//! `sema.Storage`: what the storage holds (`kind`), how (`by`), and for
//! how long (`life`) (docs/INTERNALS.md, "Storage facts"). The
//! predicates that decide where emit makes storage are here, and emit
//! asks the same ones; it names each storage location through the fact
//! (`Emitter.hiddenStorage`), which must exist and agree. So the ownership
//! checker can walk the storage the emitted program has, from the same
//! facts. Emit never makes storage that no fact names.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const diag = @import("diag.zig");
const sema = @import("sema.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const Storage = sema.Storage;
const StorageBy = sema.StorageBy;

// =============================================================================
// The predicates emit and the plan share
// =============================================================================

/// The type sema recorded for an expression; null for none or poison.
pub fn typeOf(ctx: *const SemContext, e: Sexp) ?TypeId {
    return known(ctx, ctx.typeOf(e) orelse return null);
}

pub fn known(ctx: *const SemContext, ty: TypeId) ?TypeId {
    if (ty == ctx.types.unknown_id or ty == ctx.types.invalid_id) return null;
    return ty;
}

/// Whether a value of `ty` moves (`sema.moves`): emit holds it as a
/// resource, which its storage drops unless something takes it.
pub fn owns(ctx: *const SemContext, ty: TypeId) bool {
    return sema.moves(ctx, ty) != .no;
}

/// Whether a value of `ty` is an owning value its storage drops.
fn ownsValue(ctx: *const SemContext, e: Sexp) bool {
    return owns(ctx, typeOf(ctx, e) orelse return false);
}

/// A view held as a pointer (`sema.viewHeldAsPointer`).
pub fn isPtrViewTy(ctx: *const SemContext, ty: TypeId) bool {
    return sema.viewHeldAsPointer(ctx, ty);
}

pub fn isPtrViewExpr(ctx: *const SemContext, e: Sexp) bool {
    return isPtrViewTy(ctx, typeOf(ctx, e) orelse return false);
}

fn srcText(ctx: *const SemContext, leaf: Sexp) []const u8 {
    return rig.leafText(ctx.source, leaf.src);
}

/// Literal source text: numbers, quoted strings, and the value keywords.
pub fn isLiteralText(t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.ascii.isDigit(t[0]) or t[0] == '"' or t[0] == '\'' or t[0] == '.') return true;
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false");
}

pub fn isNoneLeaf(ctx: *const SemContext, e: Sexp) bool {
    return e == .src and ctx.symbolOf(e) == null and std.mem.eql(u8, srcText(ctx, e), "none");
}

/// `print(...)`.
pub fn isPrintCall(ctx: *const SemContext, call: Sexp) bool {
    const callee = ctx.calleeOf(call);
    return callee == .src and ctx.symbolOf(callee) == null and std.mem.eql(u8, srcText(ctx, callee), "print");
}

/// The built-in String operation `call` is: `String(...)`, `!t.add(...)`,
/// or `!t.clear()`.
pub fn stringCall(ctx: *const SemContext, call: Sexp) ?sema.StringCall {
    if (!call.isKind(.call)) return null;
    return ctx.stringCallOf(call) orelse ctx.stringCallOf(ctx.calleeOf(call));
}

/// The object of `Type.f(...)`, `module.f(...)`, or
/// `module.Type.f(...)`: a call passing every parameter.
pub fn isTypeCallee(ctx: *const SemContext, obj: Sexp) bool {
    if (ctx.instanceOf(obj)) |inst| return inst == .type;
    if (obj.isKind(.member)) {
        const sym = moduleMemberSym(ctx, obj) orelse return false;
        return switch (sym.kind) {
            .nominal_type, .generic_type, .type_alias => true,
            else => false,
        };
    }
    const id = ctx.symbolOf(obj) orelse return false;
    return isTypeSym(ctx, id) or ctx.symbols.items[id].kind == .module;
}

/// The symbol `module.name` names in that module; null when `obj` is
/// not a module's member.
pub fn moduleMemberSym(ctx: *const SemContext, obj: Sexp) ?sema.Symbol {
    const id = ctx.symbolOf(ir.Member.object(obj)) orelse return null;
    if (ctx.symbols.items[id].kind != .module) return null;
    const foreign = ctx.foreign_semas.get(ctx.module_refs.get(id) orelse return null) orelse return null;
    const fid = foreign.lookupInScopeOnly(sema.module_scope, srcText(ctx, ir.Member.name(obj))) orelse return null;
    return foreign.symbols.items[fid];
}

/// A struct, enum, or generic type: calling it constructs a value.
pub fn isTypeSym(ctx: *const SemContext, id: SymbolId) bool {
    return switch (ctx.symbols.items[id].kind) {
        .nominal_type, .generic_type => true,
        else => false,
    };
}

/// The function type of a function, closure, or callable view.
pub fn fnType(ctx: *const SemContext, ty: ?TypeId) ?sema.FunctionType {
    const t = ty orelse return null;
    return sema.calledFn(ctx, t);
}

/// Whether `e` is read from storage, not made for its context
/// (`sema.Hands.hasStorage`).
pub fn hasStorage(ctx: *const SemContext, e: Sexp) bool {
    return sema.handsOver(ctx, e).hasStorage();
}

/// Whether the arithmetic `e` (`+`, `-`, `*`, `-v`, or a compound
/// assignment of one) is made lane by lane on the integers of a vector,
/// by a runtime helper that checks each lane (`rig.vecAdd`). Float lanes
/// are not.
pub fn laneChecked(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .lane_checked);
}

fn decideLaneChecked(ctx: *const SemContext, e: Sexp) bool {
    const kind = e.kind() orelse return false;
    const op: Tag, const ty = switch (kind) {
        .set => .{ rig.bindingKindOf(ir.Set.op(e)).operator() orelse return false, typeOf(ctx, ir.Set.target(e)) orelse return false },
        .@"+", .@"-", .@"*", .neg => .{ kind, typeOf(ctx, e) orelse return false },
        else => return false,
    };
    switch (op) {
        .@"+", .@"-", .@"*", .neg => {},
        else => return false,
    }
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .simd => |v| ctx.types.get(v.elem) == .int,
        else => false,
    };
}

/// A value whose evaluation has no side effect and reads nothing a
/// later argument could change: a literal, a constant, a function,
/// or a view or move of a name.
pub fn isPureArg(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .pure_arg);
}

fn decideIsPureArg(ctx: *const SemContext, e: Sexp) bool {
    switch (e) {
        .src => {
            if (isLiteralText(srcText(ctx, e)) or isNoneLeaf(ctx, e)) return true;
            const sym = ctx.symbolOf(e) orelse return false;
            const s = ctx.symbols.items[sym];
            return switch (s.kind) {
                .local, .param, .capture => s.flags.fixed or s.flags.comptime_known,
                else => true,
            };
        },
        .list => return switch (e.kind().?) {
            .enum_lit => true,
            // A view held as a pointer is the name's address; a view
            // held by value (a `?String`'s bytes, a slice, a copy of a
            // number) reads the name where the call runs, after the
            // arguments written before it.
            .read, .write => ir.get(e, .operand) == .src and ((isPtrViewExpr(ctx, e) and ctx.lendOf(e) == null) or isPureArg(ctx, ir.get(e, .operand))),
            .move => ir.get(e, .operand) == .src,
            .neg => ir.Neg.operand(e) == .src and isLiteralText(srcText(ctx, ir.Neg.operand(e))),
            else => false,
        },
        else => return false,
    }
}

/// The receiver of `value.method(...)`.
pub fn receiverOf(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasReceiver(ctx, call)) return null;
    return ir.Member.object(ctx.calleeOf(call));
}

/// Whether `call` passes a receiver, its callee's object, as its first
/// parameter (`value.method(...)`), as its recorded parameters say
/// (`SemContext.callParamsOf`): not `Type.f(...)`, `module.f(...)`, or a
/// callable a field holds (`s.cb(...)`). A call checked against no
/// signature has a receiver when its callee is a member of a value.
pub fn hasReceiver(ctx: *const SemContext, call: Sexp) bool {
    const callee = ctx.calleeOf(call);
    if (!callee.isKind(.member)) return false;
    if (ctx.callParamsOf(call)) |filled| return filled.fills.len > 0 and filled.fills[0] == .receiver;
    return !isTypeCallee(ctx, ir.Member.object(callee));
}

/// Whether the method of `value.method(...)` takes `!self`.
pub fn receiverWrites(ctx: *const SemContext, call: Sexp) bool {
    if (!hasReceiver(ctx, call)) return false;
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return false;
    return f.params.len > 0 and ctx.types.get(f.params[0]) == .write_view;
}

/// The receiver of `value.method(...)` when it is an owned temporary
/// the method consumes (`mk().consume(...)`).
pub fn consumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    return if (decide(ctx, call, .consumes_receiver)) receiverOf(ctx, call) else null;
}

fn decideConsumesReceiver(ctx: *const SemContext, call: Sexp) bool {
    return decideConsumedTemporary(ctx, call) != null;
}

fn decideConsumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasReceiver(ctx, call)) return null;
    const callee = ctx.calleeOf(call);
    const obj = ir.Member.object(callee);
    if (hasStorage(ctx, obj) or obj.isKind(.move) or !ownsValue(ctx, obj)) return null;
    const f = fnType(ctx, typeOf(ctx, callee)) orelse return null;
    if (f.params.len == 0) return null;
    return switch (ctx.types.get(f.params[0])) {
        .read_view, .write_view => null,
        else => obj,
    };
}

/// A closure literal lent as a callable view.
pub fn lentLiteral(ctx: *const SemContext, e: Sexp) bool {
    return e.isKind(.lambda) and ctx.callableOf(e) != null;
}

/// Whether a call's arguments must be evaluated into temporaries
/// first: when binding keyword arguments reorders two that have side
/// effects, or when an argument may leave (`!`, a `catch` that
/// returns) after an owned value was produced, which would be lost.
pub fn hoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    return decide(ctx, call, .hoists_args);
}

fn decideHoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    if (!call.isKind(.call) or isPrintCall(ctx, call) or stringCall(ctx, call) != null) return false;
    const args = ir.Call.args(call);
    // A closure literal lent to the call gets an environment first.
    for (args) |a| if (lentLiteral(ctx, argValue(a))) return true;
    if (ctx.callSlotsOf(call)) |slots| {
        var last: ?usize = null;
        for (slots) |slot| {
            const ai = switch (slot) {
                .arg => |a| a,
                .default => continue,
            };
            if (isPureArg(ctx, argValue(args[ai]))) continue;
            if (last) |l| if (ai < l) return true;
            last = ai;
        }
    }
    const callee = ctx.calleeOf(call);
    // Zig passes a temporary receiver to a `!self` method as a constant.
    if (receiverOf(ctx, call)) |recv| if (!hasStorage(ctx, recv) and recv.kind() != .move and receiverWrites(ctx, call)) return true;
    var owned = (callee.isKind(.member) and ir.Member.object(callee).isKind(.move)) or consumedTemporary(ctx, call) != null;
    for (args) |a| {
        const v = argValue(a);
        // A `!` or `?`, or a `return`, `break`, or `continue` in a
        // `catch` handler or a branch, leaves the enclosing block.
        if (owned and contains(v, &leave_kinds)) return true;
        if (ownsValue(ctx, v)) owned = true;
    }
    return false;
}

/// How a call whose arguments are evaluated first (`hoistsArgs`) holds
/// its receiver while they run.
pub const ReceiverHold = enum {
    /// An owned temporary the method consumes, handed over when the
    /// call runs (`consumedTemporary`).
    consumed,
    /// A value that branches: the address of the leaf it takes
    /// (`reachesLeaf`).
    leaf,
    /// A value its statement's slot keeps, or a part of one: its address
    /// there (`keptInSlot`).
    slot,
    /// A place: its address.
    place,
    /// A temporary: its value, which the call's block holds.
    value,

    /// How the storage holds the receiver, given whether `recv` itself
    /// has storage (`hasStorage`): a part of a temporary is a copy.
    pub fn by(hold: ReceiverHold, part: bool) StorageBy {
        return switch (hold) {
            .consumed => .owned,
            .leaf, .slot, .place => .pointer,
            .value => if (part) .copy else .owned,
        };
    }
};

/// How a call whose arguments are evaluated first holds its receiver,
/// or null when it is evaluated where the call is.
pub fn receiverHold(ctx: *const SemContext, call: Sexp) ?ReceiverHold {
    return decide(ctx, call, .receiver_hold);
}

fn decideReceiverHold(ctx: *const SemContext, call: Sexp) ?ReceiverHold {
    if (consumedTemporary(ctx, call) != null) return .consumed;
    // Lend sigils on a receiver are implicit in Zig's method calls.
    const recv = lentPlace(receiverOf(ctx, call) orelse return null);
    const writes = receiverWrites(ctx, call);
    const temporary = !hasStorage(ctx, recv) and !recv.isKind(.move);
    if (!contains(recv, &.{ .call, .index }) and !(writes and temporary)) return null;
    if (reachesLeaf(ctx, recv)) return .leaf;
    if (temporary and keptInSlot(ctx, recv)) return .slot;
    if (!temporary) return .place;
    return .value;
}

/// How a call whose arguments are evaluated first holds an argument
/// that is not pure (`isPureArg`).
pub const ArgumentHold = enum {
    /// A closure literal lent as a callable: its environment, and the
    /// `rig.FnRef` over it.
    closure,
    /// Any other callable lent: the `rig.FnRef`.
    callable,
    /// A value lent as the view its parameter expects (`lendOf`): the
    /// view, which points where the value is, a place or its
    /// statement's slot.
    lent,
    /// The argument's value.
    value,
};

pub fn argumentHold(ctx: *const SemContext, v: Sexp) ArgumentHold {
    return decide(ctx, v, .argument_hold);
}

fn decideArgumentHold(ctx: *const SemContext, v: Sexp) ArgumentHold {
    if (ctx.callableOf(v) != null) return if (v.isKind(.lambda)) .closure else .callable;
    if (ctx.lendOf(v) != null and !ctx.lendsTempArray(v)) return .lent;
    return .value;
}

/// The types of the run-time parameters a call's arguments fill, in
/// slot order: every parameter but the one its receiver fills, as the
/// call's recorded parameters say (`SemContext.callParamsOf`). A callable
/// a field holds (`s.cb(...)`) has no receiver; `value.method(...)` does.
pub fn argParams(ctx: *const SemContext, call: Sexp) []const TypeId {
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return &.{};
    return if (hasReceiver(ctx, call) and f.params.len > 0) f.params[1..] else f.params;
}

/// The type of the parameter argument `a` of `call` fills; null when
/// unknown.
fn argumentParam(ctx: *const SemContext, call: Sexp, ai: usize) ?TypeId {
    const params = argParams(ctx, call);
    const slot = if (ctx.callSlotsOf(call)) |slots| for (slots, 0..) |s, i| {
        if (s == .arg and s.arg == ai) break i;
    } else ai else ai;
    return if (slot < params.len) params[slot] else null;
}

/// Whether `e` is a value its statement's slot keeps (`dropsTemp`), or
/// a field or element of one: Zig storage that lives until the
/// statement ends.
pub fn keptInSlot(ctx: *const SemContext, e: Sexp) bool {
    var p = lentPlace(e);
    while (true) {
        if (ctx.dropsTemp(p)) return true;
        if (!p.isKind(.member) and !p.isKind(.index)) return false;
        p = lentPlace(ir.get(p, .object));
    }
}

/// Whether `e`, a value that branches with a leaf that is not made
/// there (`sema.handsOver` is `branches`), is reached where the leaf
/// it takes is: it is read, not taken, and its type is read by
/// address (`sema.readByAddress`), as the ownership checker reads
/// each leaf in place (`holdBranchReads`). Zig would copy it into a
/// temporary, and a `?self` method would view the copy; a struct, an
/// array, or a String is instead reached through the address of its
/// leaf, which Zig follows for a field, an element, or a method.
pub fn reachesLeaf(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .reaches_leaf);
}

fn decideReachesLeaf(ctx: *const SemContext, e: Sexp) bool {
    if (sema.handsOver(ctx, e).kind != .branches) return false;
    if (ctx.useOf(e)) |use| if (use == .take) return false;
    const ty = typeOf(ctx, e) orelse return false;
    if (!sema.readByAddress(ctx, ty)) return false;
    return switch (ctx.types.get(ty)) {
        .string, .array, .nominal, .parameterized_nominal, .imported_nominal => true,
        else => false,
    };
}

/// How emit finds the address of `e`, a value reached where its leaves
/// are (`reachesLeaf`), or of one of its leaves: one step of the walk
/// `Emitter.emitLeafPtr` writes, which the storage planner follows.
/// Inside such a value every branching form is walked to its
/// parts (`sema.valueParts`), as `sema.valueLeaves` walks a read, also
/// one whose every leaf is made here.
pub const LeafStep = enum {
    /// `a if c else b`: the address of the branch it takes.
    @"if",
    /// `o ?? d` and `e catch h`: the address of the payload where the
    /// optional or fallible operand is (reached as a leaf), or else of
    /// the fallback's value.
    fallback,
    /// `o?` and `e!`: the address of the payload where the operand is.
    unwrap,
    /// A place: its address.
    place,
    /// A field or element of a value made here: its address within that
    /// value, which is reached as a value is.
    part,
    /// A lend: the view it makes.
    lend,
    /// A value made here: its address in its statement's slot when one
    /// keeps it (`dropsTemp`), else of a Zig temporary.
    made,
    /// A literal (`none`, a number, a string): a constant of the program,
    /// which no slot keeps and which holds no Cell. `none` is reached only
    /// as the operand whose payload a branch captures, which it has
    /// none of, so its address is never written through.
    literal,
    /// `return`, `break`, `continue`: no value, no address.
    jump,
};

pub fn leafStep(ctx: *const SemContext, e: Sexp) LeafStep {
    return decide(ctx, e, .leaf_step);
}

fn decideLeafStep(ctx: *const SemContext, e: Sexp) LeafStep {
    if (sema.isBranchingForm(e)) return switch (e.kind().?) {
        .@"if" => .@"if",
        // One that copies the value its payload views out gives a value
        // made here, not the payload where it is.
        .@"??", .@"catch" => if (ctx.copiesPayload(e)) .made else .fallback,
        else => .unwrap,
    };
    return wholeStep(ctx, e);
}

/// The step that reaches `e` as one value, not through its parts: what
/// `leafStep` gives a value that is no branching form, and how a value
/// whose every leaf is made here (`sema.handsOver` is `made`) is reached
/// where no value that branches beside a name's encloses it.
fn wholeStep(ctx: *const SemContext, e: Sexp) LeafStep {
    return switch (sema.handsOver(ctx, e).kind) {
        .place => .place,
        .part_of_made => .part,
        .lend => .lend,
        .jump => .jump,
        .made, .branches, .none => if (e == .src) .literal else .made,
    };
}

/// Whether a header over `e` (a `match` subject, a `for` source, an
/// `as` value) that makes statement temporaries yields the address of
/// what `e` reaches, not its value: the block that ends the temporaries
/// breaks with `&place`, and the construct binds through that pointer,
/// so what it binds is the place's own, never a copy. `e` reaches a
/// place when it is one (`sema.Hands.place`, its indexes evaluated in
/// the block) whose path starts outside the header's temporaries
/// (`startsOutsideHeader`), a lend of one held as a pointer (`!v[i]`),
/// or a value that branches (`a if c else b`) each leaf of which reaches
/// one or jumps. A value made in the header, a part of one, or a place
/// inside a view of one (`id(?mk()).e`) has no place that outlives the
/// header, and the header yields its value.
pub fn headerPoints(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .header_points);
}

fn decideHeaderPoints(ctx: *const SemContext, e: Sexp) bool {
    if (e == .nil or sema.firstStmtTemp(ctx, e) == null) return false;
    return reachesPlace(ctx, e);
}

/// The value a header (`match`, `for`, `as`) evaluates: a `match`'s
/// subject without its lend sigils, a `for`'s source, an `as` value.
pub fn headerSubject(header: Sexp) Sexp {
    return switch (header.kind() orelse return .nil) {
        .match => lentPlace(ir.Match.subject(header)),
        .@"for" => ir.For.source(header),
        .as => ir.As.value(header),
        else => .nil,
    };
}

fn reachesPlace(ctx: *const SemContext, e: Sexp) bool {
    // A slice is a view already, yielded as it is.
    if (rig.isRangeIndex(e)) return false;
    switch (sema.handsOver(ctx, e).kind) {
        .place => return startsOutsideHeader(ctx, e),
        // A read lend of a scalar or a view is a copy.
        .lend => return (e.isKind(.read) or e.isKind(.write)) and isPtrViewExpr(ctx, e) and reachesPlace(ctx, ir.get(e, .operand)),
        .branches => {
            if (!e.isKind(.@"if")) return false;
            var parts = sema.valueParts(e);
            var any = false;
            while (parts.next()) |part| switch (sema.handsOver(ctx, part.node).kind) {
                .jump => {},
                else => {
                    if (!reachesPlace(ctx, part.node)) return false;
                    any = true;
                },
            };
            return any;
        },
        .part_of_made, .made, .jump, .none => return false,
    }
}

/// Whether the field or element path `e` starts outside the statement
/// temporaries its header makes: at a name, or at a view whose
/// evaluation makes none (`get(!v)[idx(?String("a"))]`), which therefore
/// cannot point into one. A path from a view of a value the header makes
/// (`id(?mk()).e`, `(?mk()).e`, `id(?mkh()).xs`) lives inside a
/// temporary the header's block drops.
fn startsOutsideHeader(ctx: *const SemContext, e: Sexp) bool {
    var base = e;
    while (true) {
        if (base.isKind(.member) or base.isKind(.index)) {
            base = ir.get(base, .object);
        } else if (base.isKind(.read) or base.isKind(.write)) {
            base = ir.get(base, .operand);
        } else break;
    }
    return base == .src or sema.firstStmtTemp(ctx, base) == null;
}

/// Whether `if o as x` over `value` views the value inside the
/// optional rather than copying it (`checkOptionalBinding`).
pub fn viewsOptionalValue(ctx: *const SemContext, value: Sexp) bool {
    return decide(ctx, value, .views_optional_value);
}

fn decideViewsOptionalValue(ctx: *const SemContext, value: Sexp) bool {
    const ty = typeOf(ctx, value) orelse return false;
    return isPtrViewTy(ctx, ty) and !ctx.readsThrough(value);
}

/// Whether a `match` subject can be read again as it is written: a
/// name, or a field of one. An element's index may have effects, and a
/// call makes a new value.
pub fn subjectRereadable(subject: Sexp) bool {
    var e = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
    while (e.isKind(.member)) e = ir.Member.object(e);
    return e == .src;
}

/// How a `match` reaches its subject (`checkMatch`): a bare or `?`
/// subject is read, `!` binds write views of the fields, and `<` of
/// a value that owns a resource hands the arm its fields.
pub const MatchMode = enum { read, write, consume };

/// The enum a `match` switches on: the one a box or handle holds, or
/// the subject's type.
pub fn matchedType(ctx: *const SemContext, match: Sexp) ?TypeId {
    const scrutinee = ir.Match.subject(match);
    const ty = typeOf(ctx, scrutinee) orelse return null;
    const reached = sema.unwrapAccess(ctx, ty);
    return if (reached != sema.unwrapViews(ctx, ty)) reached else ty;
}

pub fn matchMode(ctx: *const SemContext, match: Sexp) MatchMode {
    return decide(ctx, match, .match_mode);
}

fn decideMatchMode(ctx: *const SemContext, match: Sexp) MatchMode {
    const scrutinee = ir.Match.subject(match);
    if (scrutinee.isKind(.write)) return .write;
    const ty = matchedType(ctx, match) orelse return .read;
    if ((scrutinee.isKind(.move) or ctx.takesSubject(match)) and owns(ctx, ty)) return .consume;
    return .read;
}

/// Whether `pattern` is a catch-all arm's: a name, or `_`.
pub fn isCatchAll(source: []const u8, pattern: Sexp) bool {
    return pattern == .src and !isLiteralText(rig.leafText(source, pattern.src));
}

/// Whether some arm of `match` has a guard.
pub fn matchGuarded(match: Sexp) bool {
    for (ir.Match.arms(match)) |arm| if (ir.Arm.guard(arm) != .nil) return true;
    return false;
}

/// Whether `match` reads its subject again after picking an arm: a
/// `match !x` binding of the whole value points at the place, and a
/// `match <x` arm with alternatives drops the value from it.
pub fn matchRereads(ctx: *const SemContext, match: Sexp) bool {
    return decide(ctx, match, .match_rereads);
}

fn decideMatchRereads(ctx: *const SemContext, match: Sexp) bool {
    const mode = matchMode(ctx, match);
    for (ir.Match.arms(match)) |arm| {
        const pattern = ir.Arm.pattern(arm);
        if (mode == .write and isCatchAll(ctx.source, pattern)) return true;
        if (mode == .consume and pattern.isKind(.alt_pattern)) return true;
    }
    return false;
}

/// Whether `match` evaluates its subject first, or holds the value it is
/// a part of (`Header.held`), in a block around the match.
pub fn matchBlock(ctx: *const SemContext, match: Sexp) bool {
    return decide(ctx, match, .match_block);
}

fn decideMatchBlock(ctx: *const SemContext, match: Sexp) bool {
    return ctx.headerOf(match) == .held or matchGuarded(match) or matchesGenericView(ctx, match) or
        (matchRereads(ctx, match) and !subjectRereadable(lentPlace(ir.Match.subject(match))));
}

/// The `T` of a read view `?T` whose form depends on a generic type's
/// arguments: `T` holds a type parameter and neither owns resources nor
/// holds a Cell on its own. Emit writes it `rig.ReadView(T)`, a copy or
/// a pointer per instance; null for any other type.
pub fn genericReadView(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const inner = switch (ctx.types.get(ty)) {
        .read_view => |inner| inner,
        else => return null,
    };
    if (!sema.maybeDropGlue(ctx, inner) or sema.holdsCellByValue(ctx, inner)) return null;
    return inner;
}

/// Whether `match`'s subject is a view a call returns whose form depends
/// on a generic type's arguments (`genericReadView`): the match holds it
/// in `__rig_subject` and switches where it points (`rig.viewedPtr`),
/// never on a copy of what it views.
fn matchesGenericView(ctx: *const SemContext, match: Sexp) bool {
    const subject = lentPlace(ir.Match.subject(match));
    if (subject.isKind(.move) or hasStorage(ctx, subject) or !isPtrViewExpr(ctx, subject)) return false;
    return genericReadView(ctx, typeOf(ctx, subject) orelse return false) != null;
}

/// How a `match` that evaluates its subject first (`matchBlock`) holds
/// it in `__rig_subject`: the address of a place, which a header that
/// makes temporaries yields (`headerPoints`), a view a call returns as
/// the pointer it is, or the value; null when it reads the subject again
/// as it is written.
pub fn subjectHold(ctx: *const SemContext, match: Sexp) ?StorageBy {
    return decide(ctx, match, .subject_hold);
}

fn decideSubjectHold(ctx: *const SemContext, match: Sexp) ?StorageBy {
    const subject = lentPlace(ir.Match.subject(match));
    if (subjectRereadable(subject)) return null;
    const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
    if (hasStorage(ctx, value) and !subject.isKind(.move) and sema.firstStmtTemp(ctx, value) == null) return .pointer;
    if (!subject.isKind(.move) and (headerPoints(ctx, value) or isPtrViewExpr(ctx, value))) return .pointer;
    return if (matchMode(ctx, match) == .consume) .owned else .copy;
}

/// The payload fields of variant `vname` of an enum type.
pub fn variantPayload(ctx: *const SemContext, enum_ty: TypeId, vname: []const u8) ?[]const sema.Field {
    const decl = sema.nominalDecl(ctx, enum_ty) orelse return null;
    const fields = decl.symbol().fields orelse return null;
    const i = sema.variantIn(ctx, fields, vname) orelse return null;
    return fields[i].payload orelse &.{};
}

/// Whether a `match !x` binding of a field of type `ty` points at the
/// field: every field but a view or slice, which is bound as it is.
pub fn fieldIsPointee(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .slice => false,
        else => true,
    };
}

/// Whether payload binding `b` points at the field it binds: a binding
/// a write goes through (`SemContext.bindingAccess`, `match !e`) binds a
/// pointer to each field, and a read binds one to a field it
/// views (`?F` of a field that is no view), and to a field of a type
/// parameter's value (`sema.copies` is `depends`) that the match reads
/// where its subject is (`in_place`, `matchesInPlace`): what each
/// instance reads is the subject's own, never a copy in the arm. A field
/// that is itself a view or a slice is bound as it is. The binding's
/// type and its field's (`SemContext.payloadFieldOf`) are typecheck's:
/// the field's type at the matched instance, so `v` of `Opt[?T]`'s
/// `v: T` is the view the field holds.
fn payloadByAddress(ctx: *const SemContext, b: Sexp, in_place: bool) bool {
    const sym = ctx.symbolOf(b) orelse return false;
    const writes = ctx.bindingAccess(sym) == .write;
    const field = ctx.payloadFieldOf(b) orelse return writes;
    if (!fieldIsPointee(ctx, field)) return false;
    if (writes) return true;
    const binding = known(ctx, ctx.bindingTypeOf(b) orelse return false) orelse return false;
    if (ctx.types.get(binding) == .read_view or sema.viewsStringBytes(ctx, field, binding)) return true;
    return in_place and !sema.isReadOrWriteView(ctx, binding) and sema.copies(ctx, binding) == .depends;
}

/// Whether a read match's catch-all binding of type `ty` is captured by
/// address where the match switches: a view held as a pointer, and a
/// value of a type parameter (`sema.copies` is `depends`) that the match
/// reads where its subject is (`in_place`, `matchesInPlace`), as
/// `payloadByAddress` binds a payload. Any other is a copy in the arm.
fn catchAllByAddress(ctx: *const SemContext, ty: TypeId, in_place: bool) bool {
    if (isPtrViewTy(ctx, ty)) return true;
    return in_place and !sema.isReadOrWriteView(ctx, ty) and sema.copies(ctx, ty) == .depends;
}

/// Whether a `print`, `String(...)`, or `add` argument `a` is read where it
/// is, by address: a place that owns storage, or a view of one (a
/// function's binding, or a field or element of a value, not a slice,
/// which is a new value). Plain data is copied whole where it is read.
/// Decided once: emit passes its address, and the ownership checker holds
/// the place it reads while the later arguments run (`holdRead`).
pub fn printsByAddress(ctx: *const SemContext, a: Sexp) bool {
    return decide(ctx, a, .print_by_address);
}

fn decidePrintsByAddress(ctx: *const SemContext, a: Sexp) bool {
    const place = switch (a) {
        .src => if (ctx.symbolOf(a)) |id| switch (ctx.symbols.items[id].kind) {
            .param, .local, .capture => ctx.symbols.items[id].scope != sema.module_scope and ctx.callableOf(a) == null,
            else => false,
        } else false,
        .list => switch (a.kind() orelse return false) {
            .member => true,
            .index => !ir.Index.index(a).isKind(.@".."),
            else => false,
        },
        else => false,
    };
    const ty = typeOf(ctx, a) orelse return false;
    return place and sema.readByAddress(ctx, sema.unwrapViews(ctx, ty));
}

/// What expression `e` hands over (`sema.handsOver`'s kind), decided by
/// the plan for every expression, for emit to read.
pub fn handsKind(ctx: *const SemContext, e: Sexp) sema.Hands.Kind {
    return decide(ctx, e, .hands);
}

fn decideHands(ctx: *const SemContext, e: Sexp) sema.Hands.Kind {
    return sema.handsOver(ctx, e).kind;
}

/// Whether `e`, an operand of `==` or `!=` beside `none` or a bare
/// `.variant`, is a value made here that moves and that no statement slot
/// keeps, which the test drops where it reads it (`rig.isNone`,
/// `rig.isVariantDiscard`). Decided once, for emit and the plan.
pub fn dropsWhenTested(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .drops_when_tested);
}

fn decideDropsWhenTested(ctx: *const SemContext, e: Sexp) bool {
    if (sema.handsOver(ctx, e).kind != .made or ctx.dropsTemp(e)) return false;
    const ty = typeOf(ctx, e) orelse return false;
    return owns(ctx, ty);
}

/// Whether `for` loop `loop` consumes its source, handing its elements
/// over one at a time: a List it takes (`for x in <v`) or that its source
/// makes and that owns resources, or an array of values that move, which
/// it takes or its source makes. Decided once: emit lowers the loop so,
/// the plan makes its iterator and elements, and the ownership checker
/// walks the source as taken.
pub fn forConsumes(ctx: *const SemContext, loop: Sexp) bool {
    return decide(ctx, loop, .for_consumes);
}

fn decideForConsumes(ctx: *const SemContext, loop: Sexp) bool {
    const mode = ir.For.mode(loop).tag;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..")) return false;
    const t = typeOf(ctx, source) orelse return false;
    if (isListTy(ctx, t)) return mode == .move or (!hasStorage(ctx, source) and owns(ctx, t));
    return ctx.types.get(t) == .array and owns(ctx, ctx.types.get(t).array.elem) and (mode == .move or !hasStorage(ctx, source));
}

/// Whether a read `for` over an array, a slice, or a List binds the bytes
/// of each String element: its binding is a `?String`, the read view of a
/// `String`, so the loop walks the elements by address and the binding is
/// each one's `.bytes()`.
pub fn loopBindsStringBytes(ctx: *const SemContext, loop: Sexp) bool {
    if (ir.For.mode(loop).tag == .write) return false;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..") or forConsumes(ctx, loop)) return false;
    const sym = ctx.symbolOf(ir.For.@"var"(loop)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = sema.unwrapViews(ctx, typeOf(ctx, source) orelse return false);
    const elem = switch (ctx.types.get(t)) {
        .array => |a| a.elem,
        .slice => |sl| sl.elem,
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id) pn.args[0] else return false,
        else => return false,
    };
    return sema.viewsStringBytes(ctx, elem, bound);
}

/// Whether `if value as name` binds the bytes of a String that a write
/// view in the optional points at (`(!String)?`): the binding is a
/// `?String`, the read view of that String.
pub fn optionalBindsStringBytes(ctx: *const SemContext, cond: Sexp) bool {
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = typeOf(ctx, ir.As.value(cond)) orelse return false;
    return switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .optional => |inner| ctx.types.get(inner) == .write_view and sema.viewsStringBytes(ctx, inner, bound),
        else => false,
    };
}

/// Whether payload binding `b` of `match` points at the field it binds
/// (`payloadByAddress`), decided once.
pub fn bindsByAddress(ctx: *const SemContext, b: Sexp, match: Sexp) bool {
    return decideAt(ctx, b, match, .payload_by_address);
}

fn decidePayloadByAddress(ctx: *const SemContext, b: Sexp, match: Sexp) bool {
    return payloadByAddress(ctx, b, matchesInPlace(ctx, match));
}

/// Whether the catch-all binding `pattern` of a read `match` is captured by
/// address where the match switches (`catchAllByAddress`), decided once.
pub fn catchAllCaptured(ctx: *const SemContext, pattern: Sexp, match: Sexp) bool {
    return decideAt(ctx, pattern, match, .catch_all_by_address);
}

fn decideCatchAllByAddress(ctx: *const SemContext, pattern: Sexp, match: Sexp) bool {
    const sym = ctx.symbolOf(pattern) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    return catchAllByAddress(ctx, ty, matchesInPlace(ctx, match));
}

/// Whether `match`'s subject is a view a call returns, held as a pointer:
/// the match switches on it where it points, temporaries or not, and binds
/// no copy of it.
pub fn holdsView(ctx: *const SemContext, match: Sexp) bool {
    return decide(ctx, match, .holds_view);
}

fn decideHoldsView(ctx: *const SemContext, match: Sexp) bool {
    const subject = ir.Match.subject(match);
    return !hasStorage(ctx, subject) and isPtrViewExpr(ctx, subject);
}

/// Whether a read `match` switches on its subject where it is, never on
/// a copy: the subject reaches a place (`reachesPlace`), through its
/// header's temporaries or not, is a part of the made value the match
/// holds (`Header.held`), or is a view a call returns, switched on where
/// it points. A payload captured by pointer is then the subject's own.
pub fn matchesInPlace(ctx: *const SemContext, match: Sexp) bool {
    return decide(ctx, match, .matches_in_place);
}

fn decideMatchesInPlace(ctx: *const SemContext, match: Sexp) bool {
    if (matchMode(ctx, match) != .read) return false;
    const subject = lentPlace(ir.Match.subject(match));
    if (ctx.headerOf(match) == .held) return true;
    // A value that branches is matched where it points when it is a view
    // held as a pointer, or through the address its header yields; one
    // over bare places is a copy (`subjectHold`), so typecheck rejects
    // one that moves or may (`sema.moves` is not `no`).
    if (sema.handsOver(ctx, subject).kind == .branches) return headerPoints(ctx, subject) or isPtrViewExpr(ctx, subject);
    return reachesPlace(ctx, subject) or (!hasStorage(ctx, subject) and isPtrViewExpr(ctx, subject));
}

// =============================================================================
// The order of an assignment
// =============================================================================

/// One step of an assignment `place op= value`, in the order it runs
/// (`eachSetStep`): the value, then the value the target's path starts
/// from (its base), then each index on the path from the base outward,
/// a range's bounds left to right. The store follows the last step.
pub const SetStep = struct {
    node: Sexp,
    role: Role,

    pub const Role = enum { value, base, index };
};

/// Call `visitor.step(SetStep)` for each step of assignment `set`, in the
/// order it runs. The positive list of a target's steps: a field
/// (`.member`) and an element (`.index`) continue the path to their
/// object, and anything else is its base. A target that is a name has no
/// steps; a name as a base is one, which evaluates nothing (`baseStays`).
/// Emit, the storage plan, and the ownership checker all take an
/// assignment's steps from here.
pub fn eachSetStep(set: Sexp, visitor: anytype) !void {
    try visitor.step(.{ .node = ir.Set.value(set), .role = .value });
    try eachTargetStep(ir.Set.target(set), visitor);
}

/// Whether assignment target `e` is assigned through: a call, `f(x) =
/// v`, or a call's `!` or `?`, `f(x)? = v`, which writes the value the
/// write view `!T` it gives reaches (typecheck admits it only where the
/// call gives one, `assignThroughCall`). No field or element is on its
/// path, so the target is its own base (`eachSetStep`), and runs after
/// the value.
pub fn assignedThrough(e: Sexp) bool {
    if (e.isKind(.call)) return true;
    if (e.isKind(.propagate)) return ir.Propagate.value(e).isKind(.call);
    if (e.isKind(.propagate_none)) return ir.PropagateNone.value(e).isKind(.call);
    return false;
}

/// The steps of target `e` (`eachSetStep`).
pub fn eachTargetStep(e: Sexp, visitor: anytype) !void {
    if (e == .src) return;
    try eachPathStep(e, visitor);
}

fn eachPathStep(e: Sexp, visitor: anytype) !void {
    switch (e.kind() orelse return visitor.step(.{ .node = e, .role = .base })) {
        .member => try eachPathStep(ir.Member.object(e), visitor),
        .index => {
            try eachPathStep(ir.Index.object(e), visitor);
            const index = ir.Index.index(e);
            if (!index.isKind(.@"..")) return visitor.step(.{ .node = index, .role = .index });
            for ([2]Sexp{ ir.@"..".left(index), ir.@"..".right(index) }) |bound| if (bound != .nil) try visitor.step(.{ .node = bound, .role = .index });
        },
        else => try visitor.step(.{ .node = e, .role = .base }),
    }
}

/// How assignment `set` runs (`setOrder`): its desugaring is
///
///     { __v = value; __b = base; __i1 = index1; ...; place op= __v }
///
/// with the steps `eachSetStep` lists. Zig would find the place before it
/// evaluates the value, and evaluate the base where it finds the place,
/// so emit evaluates a step into hidden storage when its turn comes
/// wherever Zig's own order could be told apart.
pub const SetOrder = packed struct(u8) {
    /// The value or an index can act (`setActs`), or the base can and the
    /// value is not pure (`isPureArg`): the value, unless it is pure, is
    /// made into `__rig_new` first, and then each index that is not pure
    /// into `__rig_ix`, before the place is found. Otherwise Zig's own
    /// order (the base, the indexes, the value) is one no program can
    /// tell from this one, and stands.
    held: bool = false,
    /// The base is evaluated into `__rig_base` in its turn, after the
    /// value and before the indexes: the steps are held, an index after
    /// it is, and the base does not stay (`baseStays`). An unheld base is
    /// evaluated where the place is found, after every held step, which
    /// is its turn when no index is held.
    base: bool = false,
    /// The value owns a resource, and a step of the target can leave
    /// (`setLeaves`): where the value is made into storage before that
    /// step (`held`, or a place that owns, whose old value is dropped
    /// after the new one is made), the storage is dropped on the way out
    /// unless the store takes it.
    guard: bool = false,
    _: u5 = 0,
};

/// How assignment `set` runs, decided once.
pub fn setOrder(ctx: *const SemContext, set: Sexp) SetOrder {
    return decide(ctx, set, .set_order);
}

fn decideSetOrder(ctx: *const SemContext, set: Sexp) SetOrder {
    const Scan = struct {
        ctx: *const SemContext,
        /// Whether the value or an index can act; whether the base can.
        acts: bool = false,
        base_acts: bool = false,
        leaves: bool = false,
        base: Sexp = .nil,
        held_index: bool = false,

        pub fn step(sc: *@This(), s: SetStep) error{}!void {
            switch (s.role) {
                .value => {},
                .base => sc.base = s.node,
                .index => if (!isPureArg(sc.ctx, s.node)) {
                    sc.held_index = true;
                },
            }
            if (setActs(s.node)) {
                if (s.role == .base) sc.base_acts = true else sc.acts = true;
            }
            if (s.role != .value and setLeaves(s.node)) sc.leaves = true;
        }
    };
    var sc: Scan = .{ .ctx = ctx };
    eachSetStep(set, &sc) catch unreachable;
    // Zig evaluates the base, then the indexes, then the value: a base
    // that acts is in its turn unless a value that is not pure must run
    // before it.
    const held = sc.acts or (sc.base_acts and !isPureArg(ctx, ir.Set.value(set)));
    return .{
        .held = held,
        .base = held and sc.base != .nil and sc.held_index and !baseStays(sc.base),
        .guard = sc.leaves and ownsValue(ctx, ir.Set.value(set)),
    };
}

/// Whether step `e` of an assignment can act when it runs: call, assign,
/// drop, or leave. Then the order of the steps and the store is
/// observable.
pub fn setActs(e: Sexp) bool {
    return contains(e, &([_]Tag{ .call, .builtin, .set, .drop } ++ leave_kinds));
}

/// Whether step `e` of an assignment can leave before the store: `!`,
/// `?`, `return`, `break`, or `continue`.
/// Whether `return a, b` (`results`) evaluates its parts into storage
/// first, in their order (`argument` storage, one per part): a part that
/// can leave (`!`, `?`, a jump) comes after one that owns, which a
/// tuple Zig builds as it goes would lose on the way out. The storage
/// drops an owned part on that way, and the return takes each.
pub fn hoistsResults(ctx: *const SemContext, results: Sexp) bool {
    var owned = false;
    for (ir.Results.values(results)) |part| {
        if (owned and setLeaves(part)) return true;
        if (typeOf(ctx, part)) |ty| if (owns(ctx, ty)) {
            owned = true;
        };
    }
    return false;
}

fn setLeaves(e: Sexp) bool {
    return contains(e, &leave_kinds);
}

/// The nodes that leave the code around them: a body's exits and the
/// jumps (`rig.leavesBody`, `rig.isJump`).
pub const leave_kinds = rig.body_exit_kinds ++ rig.jump_kinds;

/// Whether the base of an assignment's path gives the same place however
/// late it is evaluated: a name, or a lend of a name or of a field path
/// off one (`(!p)`, `(!p.q)`). A step that could change which place it
/// gives changes the name, which a live loan of the target forbids.
fn baseStays(e: Sexp) bool {
    var p = lentPlace(e);
    while (p.isKind(.member)) p = ir.Member.object(p);
    return p == .src;
}

/// Whether assignment `set` to a name, which stores a value (a plain
/// local, or what a `!T` local views) rather than pointing a view
/// elsewhere, makes its value into `__rig_new` before the store: when
/// the value can act (`setOrder`). An assignment is
/// `{ __v = value; place op= __v }`, so the store goes through the
/// place as the value left it; Zig would take a `!T` local's pointer
/// before the value runs (`w.* = switch ...`).
pub fn storesAfterValue(ctx: *const SemContext, set: Sexp) bool {
    const target = ir.Set.target(set);
    const value = ir.Set.value(set);
    if (target != .src or !setOrder(ctx, set).held or isPureArg(ctx, value)) return false;
    const sym = ctx.symbolOf(target) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    if (sema.isReadOrWriteView(ctx, ty)) return !ctx.repoints(set) and sema.assignWritesThrough(ctx, ty);
    return true;
}

/// Whether the fill `[n of x]` that `e` takes is built where its value
/// goes, never in a temporary on the stack first: a box's (`^[n of x]`),
/// in the box's allocation, or a binding's that declares or reassigns a
/// local array (`a = [n of x]`), in the local, by `@memset`. A
/// reassignment whose value is made first (`storesAfterValue`) is not.
pub fn fillsInPlace(ctx: *const SemContext, e: Sexp) bool {
    return decide(ctx, e, .fills_in_place);
}

fn decideFillsInPlace(ctx: *const SemContext, e: Sexp) bool {
    switch (e.kind() orelse return false) {
        .box => return ir.Box.operand(e).isKind(.array_fill),
        .set => {
            if (!ir.Set.value(e).isKind(.array_fill) or rig.bindingKindOf(ir.Set.op(e)).operator() != null) return false;
            const target = ir.Set.target(e);
            if (target != .src) return false;
            const sym = ctx.symbolOf(target) orelse return false;
            const s = ctx.symbols.items[sym];
            if (s.kind != .local or s.scope == sema.module_scope or s.flags.comptime_known) return false;
            const ty = known(ctx, s.ty) orelse return false;
            if (ctx.types.get(ty) != .array) return false;
            return s.decl_pos == target.src.pos or !storesAfterValue(ctx, e);
        },
        else => return false,
    }
}

/// Where the step of a `while` runs (docs/INTERNALS.md, "Loops"), which
/// emit lowers to, the ownership checker walks, and the type checker's
/// jump resolver reads.
pub const StepPoint = enum(u8) {
    /// The loop's continue expression, after the condition's bindings end:
    /// a `continue` from the condition or the body goes on to it. A
    /// `while` with no step has nothing to place, and is this too.
    continue_expr,
    /// After the body, in the scope of the condition's bindings, which the
    /// step reads: a `continue` from the body goes on to it, and one from
    /// the condition would skip binding what it reads.
    after_body,
};

/// Where the step of `while` loop `loop` runs, decided once.
pub fn stepPoint(ctx: *const SemContext, loop: Sexp) StepPoint {
    return decide(ctx, loop, .step_point);
}

/// A step that reads a name an `as` part of the condition binds runs in
/// the bindings' scope, after the body; any other is the continue
/// expression, which runs after that scope ends. A name reads a binding
/// when it is the binding or a closure's capture of it (`sema.findUse`).
fn decideStepPoint(ctx: *const SemContext, loop: Sexp) StepPoint {
    const step = ir.While.step(loop);
    if (step == .nil) return .continue_expr;
    const Reads = struct {
        ctx: *const SemContext,
        step: Sexp,
        found: bool = false,
        pub fn part(r: *@This(), p: Sexp) error{}!void {
            if (!p.isKind(.as)) return;
            const sym = r.ctx.symbolOf(ir.As.name(p)) orelse return;
            if (sema.findUse(r.ctx, r.step, sym) != null) r.found = true;
        }
    };
    var reads: Reads = .{ .ctx = ctx, .step = step };
    rig.eachGuardPart(ir.While.cond(loop), &reads) catch unreachable;
    return if (reads.found) .after_body else .continue_expr;
}

/// Whether `e` holds a node of one of `kinds`, outside the closures in it.
pub fn contains(e: Sexp, kinds: []const Tag) bool {
    if (e != .list) return false;
    if (e.kind()) |h| {
        if (h == .lambda) return false;
        if (std.mem.findScalar(Tag, kinds, h) != null) return true;
    }
    for (e.items()) |c| if (contains(c, kinds)) return true;
    return false;
}

/// `e` without the lend sigils around it.
pub fn lentPlace(e: Sexp) Sexp {
    var x = e;
    while (x.isKind(.read) or x.isKind(.write)) x = ir.get(x, .operand);
    return x;
}

/// The value of a call argument: a `(kwarg name value)` stands for its value.
pub fn argValue(a: Sexp) Sexp {
    return if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
}

/// Whether a lend reaches the value inside an optional on the way to its
/// view (the lend table's `optional` row), which it captures by address.
pub fn lendsInsideOptional(lend: sema.Lend) bool {
    if (lend.callable() != null or lend.has(.read_only)) return false;
    for (lend.steps()) |step| switch (step) {
        .optional => return true,
        .elems, .text, .read_only => return false,
        else => {},
    };
    return false;
}

/// The value a block yields: its last statement, or a value that is
/// no block.
fn lastValue(e: Sexp) Sexp {
    if (!e.isKind(.block)) return e;
    const stmts = ir.Block.stmts(e);
    return if (stmts.len > 0) stmts[stmts.len - 1] else .nil;
}

// =============================================================================
// Decisions: answered once, recorded
// =============================================================================

/// The type of the answer to `q`.
pub fn Answer(comptime q: sema.Question) type {
    return switch (q) {
        .leaf_step => LeafStep,
        .reaches_leaf, .matches_in_place, .match_rereads, .match_block, .holds_view, .catch_all_by_address, .payload_by_address, .for_consumes, .print_by_address, .drops_when_tested, .header_points, .views_optional_value, .hoists_args, .consumes_receiver, .pure_arg, .lane_checked, .fills_in_place => bool,
        .receiver_hold => ?ReceiverHold,
        .argument_hold => ArgumentHold,
        .match_mode => MatchMode,
        .hands => sema.Hands.Kind,
        .subject_hold => ?StorageBy,
        .set_order => SetOrder,
        .step_point => StepPoint,
    };
}

/// How `q` is answered about a node, in the construct `at` it belongs to
/// (`.nil` for a question about the node alone), from the facts as they
/// stand.
fn decider(comptime q: sema.Question) fn (*const SemContext, Sexp, Sexp) Answer(q) {
    const Node = struct {
        fn of(comptime f: fn (*const SemContext, Sexp) Answer(q)) fn (*const SemContext, Sexp, Sexp) Answer(q) {
            return struct {
                fn decide(ctx: *const SemContext, e: Sexp, _: Sexp) Answer(q) {
                    return f(ctx, e);
                }
            }.decide;
        }
    };
    return switch (q) {
        .leaf_step => Node.of(decideLeafStep),
        .reaches_leaf => Node.of(decideReachesLeaf),
        .matches_in_place => Node.of(decideMatchesInPlace),
        .match_mode => Node.of(decideMatchMode),
        .match_rereads => Node.of(decideMatchRereads),
        .match_block => Node.of(decideMatchBlock),
        .subject_hold => Node.of(decideSubjectHold),
        .holds_view => Node.of(decideHoldsView),
        .catch_all_by_address => decideCatchAllByAddress,
        .payload_by_address => decidePayloadByAddress,
        .for_consumes => Node.of(decideForConsumes),
        .print_by_address => Node.of(decidePrintsByAddress),
        .drops_when_tested => Node.of(decideDropsWhenTested),
        .hands => Node.of(decideHands),
        .header_points => Node.of(decideHeaderPoints),
        .views_optional_value => Node.of(decideViewsOptionalValue),
        .hoists_args => Node.of(decideHoistsArgs),
        .receiver_hold => Node.of(decideReceiverHold),
        .consumes_receiver => Node.of(decideConsumesReceiver),
        .argument_hold => Node.of(decideArgumentHold),
        .pure_arg => Node.of(decideIsPureArg),
        .lane_checked => Node.of(decideLaneChecked),
        .set_order => Node.of(decideSetOrder),
        .step_point => Node.of(decideStepPoint),
        .fills_in_place => Node.of(decideFillsInPlace),
    };
}

const no_answer = 255;

fn encode(comptime q: sema.Question, a: Answer(q)) u8 {
    return switch (@typeInfo(Answer(q))) {
        .bool => @intFromBool(a),
        .@"enum" => @intFromEnum(a),
        .optional => if (a) |v| @intFromEnum(v) else no_answer,
        .@"struct" => @bitCast(a),
        else => comptime unreachable,
    };
}

/// The recorded answer to `q` about `e`, decoded; null when none is.
pub fn decided(ctx: *const SemContext, e: Sexp, comptime q: sema.Question) ?Answer(q) {
    const a = ctx.decision(e, q) orelse return null;
    return switch (@typeInfo(Answer(q))) {
        .bool => a != 0,
        .@"enum" => @enumFromInt(a),
        .optional => |o| if (a == no_answer) @as(Answer(q), null) else @as(o.child, @enumFromInt(a)),
        .@"struct" => @bitCast(a),
        else => comptime unreachable,
    };
}

/// The answer to `q` about `e`: the one recorded, or, the first time it
/// is asked, the one the facts give now, which is recorded.
fn decide(ctx: *const SemContext, e: Sexp, comptime q: sema.Question) Answer(q) {
    return decideAt(ctx, e, .nil, q);
}

/// `decide`, for a question about `e` within the construct `at`.
fn decideAt(ctx: *const SemContext, e: Sexp, at: Sexp, comptime q: sema.Question) Answer(q) {
    if (decided(ctx, e, q)) |a| return a;
    const a = decider(q)(ctx, e, at);
    ctx.recordDecision(e, at, q, encode(q, a));
    return a;
}

/// Ask every recorded question again, from the facts as they stand once the
/// module is checked: an answer that changed after it was recorded is one
/// two passes acted on differently, an internal error.
pub fn verifyDecisions(ctx: *const SemContext) void {
    ctx.decided.sealed = true;
    // A module with errors is not emitted; its diagnostics come first.
    if (ctx.hasErrors()) return;
    var it = ctx.decided.map.iterator();
    while (it.next()) |entry| switch (entry.key_ptr.q) {
        inline else => |q| {
            const now = encode(q, decider(q)(ctx, entry.value_ptr.node, entry.value_ptr.at));
            if (now != entry.value_ptr.answer) {
                const lc = @import("diag.zig").lineCol(ctx.source, ctx.startOf(entry.value_ptr.node));
                std.debug.panic("{d}:{d}: internal error: {s} was decided as {d}, but the facts now give {d}", .{ lc.line, lc.col, @tagName(q), entry.value_ptr.answer, now });
            }
        },
    };
}

// =============================================================================
// The plan
// =============================================================================

/// Record the hidden storage emit makes for module `tree`.
pub fn plan(ctx: *SemContext, tree: Sexp) !void {
    var p: Planner = .{ .ctx = ctx };
    defer p.used.deinit(ctx.allocator);
    // A binding is read where a name other than its declaration names
    // it, or a closure captures it.
    p.used = try .initEmpty(ctx.allocator, ctx.symbols.items.len);
    var names = ctx.facts.names.iterator();
    while (names.next()) |e| if (ctx.symbols.items[e.value_ptr.*].decl_pos != e.key_ptr.*) p.used.set(e.value_ptr.*);
    for (ctx.symbols.items) |s| if (s.kind == .capture and s.origin < p.used.bit_length) p.used.set(s.origin);
    try p.walk(tree);
    try planConsumed(ctx, tree);
    try rig.eachBody(tree, ctx, planUnits);
    verifyDecisions(ctx);
}

/// Record the units of a body (`rig.eachUnit`): the innermost one
/// holding each node (`SemContext.unitOf`), which emit asserts each
/// check, write, and hidden storage it writes sits in.
fn planUnits(ctx: *SemContext, owner: Sexp, body: Sexp) !void {
    _ = owner;
    const Units = struct {
        ctx: *SemContext,
        pub fn enter(u: @This(), root: Sexp, kind: rig.UnitKind) std.mem.Allocator.Error!void {
            var arena = std.heap.ArenaAllocator.init(u.ctx.allocator);
            defer arena.deinit();
            const parts: []const Sexp = if (kind == .selection) try rig.selectionParts(arena.allocator(), root) else &.{root};
            try u.ctx.recordUnit(root, kind, parts);
        }
        pub fn exit(_: @This(), _: Sexp) std.mem.Allocator.Error!void {}
    };
    try rig.eachUnit(body, Units{ .ctx = ctx });
}

/// Record the bindings a use may move out (`SemContext.consumed`): the
/// name `<x` takes, as a move or a drop, a `for x in <v` source, a
/// `|<x|` capture, and a bare name at a tail of a value that leaves its scope
/// (`sema.eachTailPart`): `return x`, `break x`, a function's or a
/// closure's last value, and a value `if`, `match`, `??`, `catch`, loop,
/// or block. Whether such a use moves is the ownership checker's
/// decision; it moves no binding this fact leaves out.
fn planConsumed(ctx: *SemContext, e: Sexp) !void {
    if (e != .list) return;
    const head = e.kind() orelse {
        for (e.items()) |c| try planConsumed(ctx, c);
        return;
    };
    switch (head) {
        .move => try consumeName(ctx, ir.Move.operand(e)),
        .drop => try consumeName(ctx, ir.Drop.target(e)),
        // `return a, b` takes each part as `return x` takes `x`.
        .@"return" => if (ir.Return.value(e).isKind(.results)) {
            for (ir.Results.values(ir.Return.value(e))) |part| try consumeTail(ctx, part);
        } else try consumeTail(ctx, ir.Return.value(e)),
        .@"break" => try consumeTail(ctx, ir.Break.value(e)),
        .@"for" => {
            if (ir.For.mode(e).tag == .move) try consumeName(ctx, ir.For.source(e));
            try consumeTail(ctx, e);
        },
        .@"if" => if (ir.If.@"else"(e) != .nil) try consumeTail(ctx, e),
        .@"??", .@"catch", .match, .@"while", .raw_block => try consumeTail(ctx, e),
        .cap_move => if (ctx.symbolOf(ir.get(e, .name))) |cap| try ctx.consumed.put(ctx.allocator, ctx.symbols.items[cap].origin, {}),
        .fun => if (ir.Fun.returns(e) != .nil) try consumeTail(ctx, ir.Fun.body(e)),
        .lambda => if (lambdaYields(ctx, e)) try consumeTail(ctx, ir.Lambda.body(e)),
        else => {},
    }
    for (rig.children(e)) |c| try planConsumed(ctx, c);
}

fn consumeName(ctx: *SemContext, node: Sexp) !void {
    if (node != .src) return;
    const sym = ctx.symbolOf(node) orelse return;
    try ctx.consumed.put(ctx.allocator, sym, {});
}

fn consumeTail(ctx: *SemContext, value: Sexp) std.mem.Allocator.Error!void {
    if (value == .src) return consumeName(ctx, value);
    try sema.eachTailPart(value, ctx, consumeTail);
}

/// Whether closure literal `lambda` yields a value: a `fun` whose body
/// has a result.
pub fn lambdaYields(ctx: *const SemContext, lambda: Sexp) bool {
    const f = fnType(ctx, typeOf(ctx, lambda)) orelse return false;
    if (f.is_sub) return false;
    return switch (ctx.types.get(f.returns)) {
        .void, .unknown, .invalid, .noreturn => false,
        else => true,
    };
}

const Planner = struct {
    ctx: *SemContext,
    used: std.bit_set.Dynamic = .{},

    fn record(p: *Planner, node: Sexp, kind: sema.StorageKind, by: StorageBy, life: sema.StorageLife) !void {
        try p.ctx.recordStorage(node, .{ .kind = kind, .by = by, .life = life });
    }

    fn isUsed(p: *Planner, name: Sexp) bool {
        if (name != .src) return false;
        const sym = p.ctx.symbolOf(name) orelse return false;
        return p.used.isSet(sym);
    }

    fn walk(p: *Planner, e: Sexp) std.mem.Allocator.Error!void {
        switch (e) {
            .list => for (if (e.kind() == null) e.items() else rig.children(e)) |c| try p.walk(c),
            .src => {},
            else => return,
        }
        const ctx = p.ctx;
        // Whether a value is reached where its leaves are is decided for
        // every expression, which emit reads wherever it takes an address.
        _ = reachesLeaf(ctx, e);
        _ = handsKind(ctx, e);
        if (ctx.lendOf(e)) |lend| {
            if (lendsInsideOptional(lend)) try p.record(e, .lent, .pointer, .expression);
            try p.leaves(if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e);
        }
        if (e != .list) return;
        // Whether each header's block yields an address is decided for
        // its subject, which emit reads.
        const subject = headerSubject(e);
        if (subject != .nil) {
            _ = headerPoints(ctx, subject);
            if (subject.isKind(.move)) _ = headerPoints(ctx, ir.Move.operand(subject));
            if (e.isKind(.as)) _ = viewsOptionalValue(ctx, subject);
        }
        switch (e.kind() orelse return) {
            // A value read where its leaves are is reached through the
            // address of the leaf it takes, for a field, an element, or a
            // method.
            .member => try p.leaves(lentPlace(ir.Member.object(e))),
            .index => try p.leaves(ir.Index.object(e)),
            .@"==", .@"!=" => for ([2]Sexp{ ir.get(e, .left), ir.get(e, .right) }) |operand| {
                _ = dropsWhenTested(ctx, operand);
            },
            .call => {
                // How a call holds what it is passed, for emit to read.
                _ = hoistsArgs(ctx, e);
                _ = receiverHold(ctx, e);
                _ = consumedTemporary(ctx, e);
                for (ir.Call.args(e)) |a| {
                    _ = isPureArg(ctx, argValue(a));
                    _ = argumentHold(ctx, argValue(a));
                }
                // How `print` and the String operations read each argument.
                if (isPrintCall(ctx, e) or stringCall(ctx, e) != null) for (ir.Call.args(e)) |a| {
                    _ = printsByAddress(ctx, a);
                };
                try p.call(e);
            },
            .set => {
                _ = laneChecked(ctx, e);
                _ = fillsInPlace(ctx, e);
                try p.assignment(e);
            },
            // The call's results, which each target takes in its turn.
            .destructure => try p.record(e, .results, .owned, .statement),
            // The parts of `return a, b`, made first when a later one can
            // leave.
            .results => if (hoistsResults(ctx, e)) try p.record(e, .argument, .owned, .call),
            .box => _ = fillsInPlace(ctx, e),
            .@"+", .@"-", .@"*", .neg => _ = laneChecked(ctx, e),
            .@"for" => try p.forLoop(e),
            .match => try p.match(e),
            .@"if" => try p.condition(ir.If.cond(e)),
            .@"while" => {
                _ = stepPoint(ctx, e);
                try p.condition(ir.While.cond(e));
            },
            .@"catch" => if (p.isUsed(ir.Catch.name(e))) try p.record(e, .error_value, .owned, .handler),
            .share => if (ir.Share.operand(e).isKind(.lambda)) try p.record(ir.Share.operand(e), .closure_env, .owned, .expression),
            else => {},
        }
    }

    /// A header `e` that makes statement temporaries is evaluated in a
    /// block that ends them and yields its value.
    fn header(p: *Planner, e: Sexp) !void {
        if (e == .nil or sema.firstStmtTemp(p.ctx, e) == null) return;
        try p.record(e, .header_value, .copy, .header);
    }

    /// A construct's subject `e` (`headerSubject`) that makes statement
    /// temporaries: the block that ends them yields the address of the
    /// place `e` reaches (`headerPoints`), or else its value.
    fn subjectHeader(p: *Planner, e: Sexp) !void {
        if (e == .nil or sema.firstStmtTemp(p.ctx, e) == null) return;
        const points = headerPoints(p.ctx, e);
        try p.record(e, .header_value, if (points) .pointer else .copy, .header);
        // A value that branches over places yields the address of the leaf
        // it takes.
        if (points and sema.handsOver(p.ctx, e).kind == .branches and !isPtrViewExpr(p.ctx, e)) try p.leaf(e);
    }

    /// An `if` or `while` condition: each of its guard parts
    /// (`rig.eachGuardPart`).
    fn condition(p: *Planner, cond: Sexp) !void {
        try rig.eachGuardPart(cond, p);
    }

    pub fn part(p: *Planner, cond: Sexp) !void {
        if (cond.isKind(.as)) return p.optional(cond);
        // `if f() as a, b`: the call's results, captured for the body,
        // each taken by its binding, the rest dropped there.
        if (cond.isKind(.as_results)) {
            try p.subjectHeader(ir.AsResults.value(cond));
            return p.record(cond, .results, .owned, .body);
        }
        try p.header(cond);
    }

    /// `if … as` or `while … as`.
    fn optional(p: *Planner, cond: Sexp) !void {
        const ctx = p.ctx;
        const value = ir.As.value(cond);
        const name = ir.As.name(cond);
        const used = p.isUsed(name);
        // A place, or a part of a value the `if` holds, is bound where it
        // stands.
        if (ctx.headerOf(cond)) |how| {
            if (how == .held) try p.record(cond, .held, .owned, .construct);
            try p.subjectHeader(value);
            if (used) try p.record(cond, .as_value, .pointer, .body);
            return;
        }
        if (viewsOptionalValue(ctx, value)) {
            // A view of a temporary the header drops: the binding views
            // a copy of the value inside.
            const copy = ctx.copiesHeader(cond);
            try p.subjectHeader(value);
            if (used) {
                try p.record(cond, .as_value, if (copy) .copy else .pointer, .body);
                if (copy) try p.record(cond, .as_copy, .copy, .body);
            }
            return;
        }
        if (value.isKind(.move)) try p.header(value) else try p.subjectHeader(value);
        const sym = ctx.symbolOf(name);
        const ty: ?TypeId = if (sym) |s| known(ctx, ctx.symbols.items[s].ty) else if (typeOf(ctx, value)) |t| switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        // A resource is captured, then owned by the binding.
        if (ty != null and owns(ctx, ty.?)) try p.record(cond, .as_value, .owned, .body);
        // The bytes of the String a captured write view points at: the
        // pointer is captured, and the binding takes its bytes.
        if (used and optionalBindsStringBytes(ctx, cond)) try p.record(cond, .as_value, .pointer, .body);
    }

    fn forLoop(p: *Planner, loop: Sexp) !void {
        const ctx = p.ctx;
        const source = ir.For.source(loop);
        if (loopBindsStringBytes(ctx, loop) and p.isUsed(ir.For.@"var"(loop))) try p.record(loop, .element, .pointer, .iteration);
        if (source.isKind(.@"..")) {
            try p.record(loop, .range_start, .owned, .construct);
            try p.record(loop, .range_end, .owned, .construct);
            try p.header(ir.@"..".left(source));
            return p.header(ir.@"..".right(source));
        }
        if (forConsumes(ctx, loop)) {
            try p.record(loop, .iterator, .owned, .construct);
            try p.record(loop, .element, .owned, .iteration);
            return p.header(source);
        }
        const how = ctx.headerOf(loop);
        if (how == .held) try p.record(loop, .held, .owned, .construct);
        if (how == .taken) {
            try p.record(loop, .taken, .owned, .construct);
            return p.header(source);
        }
        try p.subjectHeader(source);
    }

    fn match(p: *Planner, m: Sexp) !void {
        const ctx = p.ctx;
        const mode = matchMode(ctx, m);
        const subject = lentPlace(ir.Match.subject(m));
        // How it binds is decided for every binding, which emit reads.
        _ = holdsView(ctx, m);
        _ = matchesInPlace(ctx, m);
        _ = matchRereads(ctx, m);
        _ = subjectHold(ctx, m);
        for (ir.Match.arms(m)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            if (pattern == .src) {
                if (isCatchAll(ctx.source, pattern) and ctx.symbolOf(pattern) != null) _ = catchAllCaptured(ctx, pattern, m);
            } else if (pattern.isKind(.variant_pattern)) {
                for (ctx.payloadBindings(pattern) orelse continue) |b| if (b != .nil) {
                    _ = bindsByAddress(ctx, b, m);
                };
            }
        }
        if (ctx.headerOf(m) == .held) try p.record(m, .held, .owned, .construct);
        var reread = false;
        var temp = false;
        if (matchBlock(ctx, m)) {
            if (subjectHold(ctx, m)) |by| {
                try p.record(m, .subject, by, .construct);
                const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                if (subject.isKind(.move)) try p.header(value) else try p.subjectHeader(value);
                temp = mode == .consume and by == .owned;
            }
            reread = true;
            if (matchGuarded(m)) {
                for (ir.Match.arms(m)) |arm| {
                    try p.header(ir.Arm.guard(arm));
                    // The arm takes the value.
                    if (mode == .consume) try p.record(arm, .whole, .owned, .arm);
                }
                return;
            }
        } else if (matchRereads(ctx, m)) reread = true;
        if (!(temp or (reread and mode != .consume))) try p.subjectHeader(subject);
        const ty = matchedType(ctx, m);
        for (ir.Match.arms(m)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            if (isCatchAll(ctx.source, pattern)) {
                if (mode == .consume) try p.record(arm, .whole, .owned, .arm);
                continue;
            }
            const variant = pattern.isKind(.variant_pattern) or pattern.isKind(.enum_lit);
            if (mode == .consume) {
                if (!variant) {
                    try p.record(arm, .whole, .owned, .arm);
                } else if (variantPayload(ctx, ty orelse continue, srcText(ctx, ir.get(pattern, .name)))) |fields| {
                    if (fields.len > 0) try p.record(arm, .payload, .owned, .arm);
                }
                continue;
            }
            if (!pattern.isKind(.variant_pattern)) continue;
            var any = false;
            var by_addr = mode == .write;
            for (ctx.payloadBindings(pattern) orelse continue) |b| {
                if (!p.isUsed(b)) continue;
                any = true;
                if (bindsByAddress(ctx, b, m)) by_addr = true;
            }
            if (any) try p.record(arm, .payload, if (by_addr) .pointer else .copy, .arm);
        }
    }

    fn call(p: *Planner, c: Sexp) !void {
        const ctx = p.ctx;
        const callee = ctx.calleeOf(c);
        const hoists = ctx.elemCallOf(callee) == null and hoistsArgs(ctx, c);
        // A temporary array lent as a slice to a call that evaluates its
        // arguments where they stand is lent where Zig holds it, which
        // lives through the call.
        if (!hoists) for (ir.Call.args(c)) |a| if (ctx.lendsTempArray(argValue(a))) try p.record(argValue(a), .zig_temp, .owned, .statement);
        if (ctx.elemCallOf(callee) != null) return;
        // A closure literal called where it is written is built first.
        if (callee.isKind(.lambda)) try p.record(callee, .invoked, .owned, .call);
        if (!hoists) return;
        if (receiverHold(ctx, c)) |hold| {
            const recv = if (hold == .consumed) consumedTemporary(ctx, c).? else lentPlace(receiverOf(ctx, c).?);
            try p.record(recv, .receiver, hold.by(hasStorage(ctx, recv)), .call);
        }
        for (ir.Call.args(c), 0..) |a, ai| {
            const v = argValue(a);
            if (isPureArg(ctx, v)) continue;
            // What the storage holds: a value of its own, a copy, or a
            // view, as the lend and the parameter say.
            const by: StorageBy = switch (argumentHold(ctx, v)) {
                .closure => by: {
                    try p.record(v, .environment, .owned, .call);
                    break :by .owned;
                },
                .callable => .owned,
                .lent => .pointer,
                .value => if (argumentParam(ctx, c, ai)) |t| (if (isPtrViewTy(ctx, t)) .pointer else .owned) else .owned,
            };
            try p.record(v, .argument, by, .call);
        }
    }

    fn assignment(p: *Planner, set: Sexp) !void {
        const ctx = p.ctx;
        const kind = rig.bindingKindOf(ir.Set.op(set));
        const target = ir.Set.target(set);
        const value = ir.Set.value(set);
        const order = setOrder(ctx, set);
        if (kind.operator()) |op| {
            try p.openAssign(set, order);
            if (target != .src and (assignsThroughCall(ctx, op, target, value) or laneChecked(ctx, set))) try p.record(target, .slot, .pointer, .assignment);
            return;
        }
        if (target != .src) {
            if (kind == .default) try p.placeAssign(set, order);
            return;
        }
        if (std.mem.eql(u8, srcText(ctx, target), "_")) return;
        const sym = ctx.symbolOf(target) orelse return;
        const s = ctx.symbols.items[sym];
        if (s.decl_pos == target.src.pos) return;
        // A reassigned resource's new value is made before the old one
        // is dropped. Any other store whose value can act makes its value
        // first, as every assignment does (`storesAfterValue`).
        const ty = known(ctx, s.ty) orelse return;
        const ptr = isPtrViewTy(ctx, ty);
        const writes_through = !ctx.repoints(set) and sema.assignWritesThrough(ctx, s.ty);
        const pointee = sema.writtenThrough(ctx, ty);
        if ((ptr and writes_through and !isPtrViewTy(ctx, pointee) and owns(ctx, pointee)) or (!ptr and owns(ctx, ty)) or storesAfterValue(ctx, set))
            try p.record(value, .new_value, .owned, .assignment);
    }

    /// An assignment to a field or element (`emitPlaceAssign`).
    fn placeAssign(p: *Planner, set: Sexp, order: SetOrder) !void {
        const ctx = p.ctx;
        const target = ir.Set.target(set);
        // A target assigned through, a call's write view, writes the
        // value the view reaches.
        const through = assignedThrough(target);
        const place_ty = if (through) (if (typeOf(ctx, target)) |t| sema.writtenThrough(ctx, t) else null) else typeOf(ctx, target);
        if (target.isKind(.index)) if (typeOf(ctx, ir.Index.object(target))) |t| if (isCellListTy(ctx, t)) return p.openAssign(set, order);
        const holds_view = if (through) (if (place_ty) |t| isPtrViewTy(ctx, t) else false) else (target != .src and isPtrViewExpr(ctx, target));
        if (holds_view) return p.openAssign(set, order);
        if (place_ty != null and !owns(ctx, place_ty.?)) return p.openAssign(set, order);
        try p.record(ir.Set.value(set), .new_value, .owned, .assignment);
        if (order.held) try p.targetSteps(set, order);
        try p.record(target, .slot, .pointer, .assignment);
    }

    /// The steps of an assignment whose order is held (`SetOrder`), each
    /// evaluated into its storage in its turn unless it is pure
    /// (`openAssign`).
    fn openAssign(p: *Planner, set: Sexp, order: SetOrder) !void {
        if (!order.held) return;
        if (!isPureArg(p.ctx, ir.Set.value(set))) try p.record(ir.Set.value(set), .new_value, .owned, .assignment);
        try p.targetSteps(set, order);
    }

    /// The storage of the target's steps an assignment holds: its base,
    /// when `order.base`, and each index that is not pure.
    fn targetSteps(p: *Planner, set: Sexp, order: SetOrder) !void {
        const Steps = struct {
            p: *Planner,
            order: SetOrder,

            pub fn step(st: @This(), s: SetStep) !void {
                switch (s.role) {
                    .value => {},
                    .base => if (st.order.base) try st.p.record(s.node, .base, .pointer, .assignment),
                    .index => if (!isPureArg(st.p.ctx, s.node)) try st.p.record(s.node, .index, .owned, .assignment),
                }
            }
        };
        try eachTargetStep(ir.Set.target(set), Steps{ .p = p, .order = order });
    }

    /// The branches of `e`, when it is a value read where its leaves are
    /// (`reachesLeaf`), that capture a payload by address, walked as emit
    /// walks them (`leafStep`).
    fn leaves(p: *Planner, e: Sexp) !void {
        if (reachesLeaf(p.ctx, e)) try p.leaf(e);
    }

    fn leaf(p: *Planner, e: Sexp) !void {
        switch (leafStep(p.ctx, e)) {
            .place, .part, .lend, .jump => {},
            // A value made here that no slot keeps, or a literal, is
            // reached where Zig holds it.
            .made => if (!p.ctx.dropsTemp(e)) try p.record(e, .zig_temp, .owned, .statement),
            .literal => if (!isNoneLeaf(p.ctx, e)) try p.record(e, .zig_temp, .owned, .statement),
            .@"if" => {
                try p.leaf(lastValue(ir.If.then(e)));
                try p.leaf(lastValue(ir.If.@"else"(e)));
            },
            .fallback => {
                try p.record(e, .leaf, .pointer, .expression);
                if (e.isKind(.@"??")) {
                    try p.leaf(ir.@"??".left(e));
                    try p.leaf(ir.@"??".right(e));
                } else {
                    try p.leaf(ir.Catch.value(e));
                    try p.leaf(lastValue(ir.Catch.handler(e)));
                }
            },
            .unwrap => {
                try p.record(e, .leaf, .pointer, .expression);
                try p.leaf(if (e.isKind(.propagate)) ir.Propagate.value(e) else ir.PropagateNone.value(e));
            },
        }
    }
};

/// Whether `x op= v` lowers to a call that assigns its result, as
/// `Emitter.emitCompound` lowers it: `rig.rem`, `@shlExact`, an integer
/// `/`, and on a vector the runtime's lane shifts and saturating `+|` and
/// `-|`, and a mask's `&`, `|`, and `^` (`rig.Mask`): its place is found
/// once. A checked `+=`, `-=`, or `*=` on integer lanes does too
/// (`laneChecked`), which the caller asks separately.
fn assignsThroughCall(ctx: *const SemContext, op: Tag, target: Sexp, value: Sexp) bool {
    switch (op) {
        .@"%", .@"<<" => return true,
        .@"/" => {
            for ([2]Sexp{ target, value }) |e| {
                const ty = typeOf(ctx, e) orelse continue;
                switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
                    .float, .float_literal => return false,
                    else => {},
                }
            }
            return true;
        },
        .@"<<%", .@">>", .@"+|", .@"-|", .@"&", .@"|", .@"^" => {
            const ty = typeOf(ctx, target) orelse return false;
            const v = switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
                .simd => |v| v,
                else => return false,
            };
            return switch (op) {
                .@"&", .@"|", .@"^" => v.elem == ctx.types.bool_id,
                else => true,
            };
        },
        else => return false,
    }
}

fn isListTy(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == ctx.list_sym_id,
        else => false,
    };
}

/// A Cell holding a List, reached by value, view, or shared handle.
fn isCellListTy(ctx: *const SemContext, ty: TypeId) bool {
    const cell = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id and pn.args.len == 1) pn.args[0] else return false,
        else => return false,
    };
    return isListTy(ctx, cell);
}
