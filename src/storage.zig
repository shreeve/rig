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
    return ctx.source[leaf.src.pos..][0..leaf.src.len];
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

/// The built-in Text operation `call` is: `Text(...)`, `!t.add(...)`,
/// or `!t.clear()`.
pub fn textCall(ctx: *const SemContext, call: Sexp) ?sema.TextCall {
    if (!call.isKind(.call)) return null;
    return ctx.textCallOf(call) orelse ctx.textCallOf(ctx.calleeOf(call));
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
    return switch (ctx.types.get(t)) {
        .function => |f| f,
        else => sema.callableFn(ctx, t),
    };
}

/// Whether `e` is read from storage, not made for its context
/// (`sema.Hands.hasStorage`).
pub fn hasStorage(ctx: *const SemContext, e: Sexp) bool {
    return sema.handsOver(ctx, e).hasStorage();
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
            .read, .write, .move => ir.get(e, .operand) == .src,
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
    if (!call.isKind(.call) or isPrintCall(ctx, call) or textCall(ctx, call) != null) return false;
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
    // Zig passes a temporary receiver to a `!self` method as a constant,
    // and a Cell a read view may change must not be in one.
    if (receiverOf(ctx, call)) |recv| if ((!hasStorage(ctx, recv) and recv.kind() != .move and receiverWrites(ctx, call)) or ctx.lendsCellTemp(lentPlace(recv))) return true;
    for (args) |a| if (argValue(a).isKind(.read) and ctx.lendsCellTemp(ir.Read.operand(argValue(a)))) return true;
    for (args) |a| if (ctx.lendsTempArray(argValue(a)) and ctx.lendsCellTemp(argValue(a))) return true;
    var owned = (callee.isKind(.member) and ir.Member.object(callee).isKind(.move)) or consumedTemporary(ctx, call) != null;
    for (args) |a| {
        const v = argValue(a);
        // A `!` or `?`, or a `return`, `break`, or `continue` in a
        // `catch` handler or a branch, leaves the enclosing block.
        if (owned and contains(v, &.{ .propagate, .propagate_none, .@"return", .@"break", .@"continue" })) return true;
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
    // A Cell-holding part of a temporary is held where it can change.
    const cell = ctx.lendsCellTemp(recv);
    const temporary = (!hasStorage(ctx, recv) and !recv.isKind(.move)) or cell;
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
    /// A Cell-holding part of a temporary lent to read, kept in its
    /// statement's slot: its address there.
    cell_slot,
    /// Such a part of a temporary no slot keeps: a mutable copy.
    cell_copy,
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
    if (v.isKind(.read) and ctx.lendsCellTemp(ir.Read.operand(v))) return if (keptInSlot(ctx, ir.Read.operand(v))) .cell_slot else .cell_copy;
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
/// array, or a Text is instead reached through the address of its
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
        .text, .array, .nominal, .parameterized_nominal, .imported_nominal => true,
        else => false,
    };
}

/// How emit finds the address of `e`, a value reached where its leaves
/// are (`reachesLeaf`), or of one of its leaves: one step of the walk
/// `Emitter.emitLeafPtr` writes, which the storage planner and
/// `madeLeaves` follow, so the checker keeps exactly the values emit
/// reaches. Inside such a value every branching form is walked to its
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
    /// value, which is reached as a value is (`madeLeaves`).
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
        .@"??", .@"catch" => .fallback,
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

/// The values made here that reaching `e` by address reaches, appended
/// to `out`: a value that branches with a leaf not made here
/// (`sema.handsOver` is `branches`) at each of its leaves, walked by
/// `leafStep`; any other value whole, as one temporary. A part of a
/// value made here (`mk().t`) reaches that value, the same way. Emit
/// takes the address of each such value where its statement's slot
/// keeps it (`dropsTemp`), and otherwise of a Zig temporary, which may
/// be constant, so nothing may change it: typecheck keeps each in its
/// slot wherever a value whose type holds a Cell is reached so
/// (`Checker.keepReached`), and emit stops with an internal error at one
/// no slot keeps (`Emitter.refuseHeldCell`).
pub fn madeLeaves(ctx: *const SemContext, a: std.mem.Allocator, e: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    const step = if (sema.handsOver(ctx, e).kind == .branches) leafStep(ctx, e) else wholeStep(ctx, e);
    switch (step) {
        .@"if", .fallback, .unwrap => {
            var parts = sema.valueParts(e);
            while (parts.next()) |part| try madeLeavesIn(ctx, a, part.node, out);
        },
        .made => try out.append(a, e),
        .part => try madeLeaves(ctx, a, pathBase(e), out),
        .place, .lend, .literal, .jump => {},
    }
}

/// `madeLeaves` of `e`, a part of a value that branches beside a name's:
/// every branching form is walked through (`leafStep`).
fn madeLeavesIn(ctx: *const SemContext, a: std.mem.Allocator, e: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    switch (leafStep(ctx, e)) {
        .@"if", .fallback, .unwrap => {
            var parts = sema.valueParts(e);
            while (parts.next()) |part| try madeLeavesIn(ctx, a, part.node, out);
        },
        .made => try out.append(a, e),
        .part => try madeLeaves(ctx, a, pathBase(e), out),
        .place, .lend, .literal, .jump => {},
    }
}

/// The value the field or element path `e` starts from.
fn pathBase(e: Sexp) Sexp {
    var base = e;
    while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
    return base;
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
/// evaluation makes none (`get(!v)[idx(?Text("a"))]`), which therefore
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
    return pattern == .src and !isLiteralText(source[pattern.src.pos..][0..pattern.src.len]);
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
    for (decl.symbol().fields orelse return null) |f| {
        if (f.is_variant and std.mem.eql(u8, f.name, vname)) return f.payload orelse &.{};
    }
    return null;
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
    if (ctx.types.get(binding) == .read_view) return true;
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

/// Whether a `print`, `Text(...)`, or `add` argument `a` is read where it
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
/// over one at a time: a Vec it takes (`for x in <v`) or that its source
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
    if (isVecTy(ctx, t)) return mode == .move or (!hasStorage(ctx, source) and owns(ctx, t));
    return ctx.types.get(t) == .array and owns(ctx, ctx.types.get(t).array.elem) and (mode == .move or !hasStorage(ctx, source));
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

/// Whether the value of an assignment, or an index of its target, can
/// act when it runs: call, assign, drop, or leave. Then the order of the
/// value, the indexes, and the store is observable (`openAssign`).
pub fn actsBeforeStore(target: Sexp, value: Sexp) bool {
    const acts = &[_]Tag{ .call, .builtin, .set, .drop, .@"return", .@"break", .@"continue", .propagate, .propagate_none };
    if (contains(value, acts)) return true;
    var e = target;
    while (true) switch (e.kind() orelse return false) {
        .member => e = ir.Member.object(e),
        .index => {
            if (contains(ir.Index.index(e), acts)) return true;
            e = ir.Index.object(e);
        },
        else => return false,
    };
}

/// Whether assignment `set` to a name, which stores a value (a plain
/// local, or what a `!T` local views) rather than pointing a view
/// elsewhere, makes its value into `__rig_new` before the store: when
/// the value can act (`actsBeforeStore`). An assignment is
/// `{ __v = value; place op= __v }`, so the store goes through the
/// place as the value left it; Zig would take a `!T` local's pointer
/// before the value runs (`w.* = switch ...`).
pub fn storesAfterValue(ctx: *const SemContext, set: Sexp) bool {
    const target = ir.Set.target(set);
    const value = ir.Set.value(set);
    if (target != .src or !actsBeforeStore(target, value) or isPureArg(ctx, value)) return false;
    const sym = ctx.symbolOf(target) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    if (sema.isReadOrWriteView(ctx, ty)) return !ctx.repoints(set) and sema.assignWritesThrough(ctx, ty);
    return true;
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
        .reaches_leaf, .matches_in_place, .match_rereads, .match_block, .holds_view, .catch_all_by_address, .payload_by_address, .for_consumes, .print_by_address, .drops_when_tested, .header_points, .views_optional_value, .hoists_args, .consumes_receiver, .pure_arg => bool,
        .receiver_hold => ?ReceiverHold,
        .argument_hold => ArgumentHold,
        .match_mode => MatchMode,
        .hands => sema.Hands.Kind,
        .subject_hold => ?StorageBy,
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
    };
}

const no_answer = 255;

fn encode(comptime q: sema.Question, a: Answer(q)) u8 {
    return switch (@typeInfo(Answer(q))) {
        .bool => @intFromBool(a),
        .@"enum" => @intFromEnum(a),
        .optional => if (a) |v| @intFromEnum(v) else no_answer,
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
    verifyDecisions(ctx);
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
        .@"return" => try consumeTail(ctx, ir.Return.value(e)),
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
                // How `print` and the Text operations read each argument.
                if (isPrintCall(ctx, e) or textCall(ctx, e) != null) for (ir.Call.args(e)) |a| {
                    _ = printsByAddress(ctx, a);
                };
                try p.call(e);
            },
            .set => try p.assignment(e),
            .@"for" => try p.forLoop(e),
            .match => try p.match(e),
            .@"if" => try p.condition(ir.If.cond(e)),
            .@"while" => try p.condition(ir.While.cond(e)),
            .@"catch" => if (p.isUsed(ir.Catch.name(e))) try p.record(e, .error_value, .copy, .handler),
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

    /// An `if` or `while` condition: each part of a joined one.
    fn condition(p: *Planner, cond: Sexp) !void {
        if (rig.isConditionJoin(cond)) {
            try p.condition(ir.get(cond, .left));
            return p.condition(ir.get(cond, .right));
        }
        if (cond.isKind(.as)) return p.optional(cond);
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
            const copy = ctx.copiesHeader(cond) or (value.isKind(.read) and ctx.lendsCellTemp(ir.Read.operand(value)));
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
    }

    fn forLoop(p: *Planner, loop: Sexp) !void {
        const ctx = p.ctx;
        const source = ir.For.source(loop);
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
                .cell_slot, .lent => .pointer,
                .cell_copy => .copy,
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
        if (kind.operator()) |op| {
            try p.openAssign(target, value);
            if (target != .src and divides(ctx, op, target, value)) try p.record(target, .slot, .pointer, .assignment);
            return;
        }
        if (target != .src) {
            if (kind == .default) try p.placeAssign(target, value);
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
        if ((ptr and writes_through and owns(ctx, sema.unwrapViews(ctx, ty))) or (!ptr and owns(ctx, ty)) or storesAfterValue(ctx, set))
            try p.record(value, .new_value, .owned, .assignment);
    }

    /// An assignment to a field or element (`emitPlaceAssign`).
    fn placeAssign(p: *Planner, target: Sexp, value: Sexp) !void {
        const ctx = p.ctx;
        const through = ctx.writesThrough(target);
        const target_ty = typeOf(ctx, target);
        const place_ty = if (through) sema.unwrapViews(ctx, target_ty.?) else target_ty;
        if (target.isKind(.index)) if (typeOf(ctx, ir.Index.object(target))) |t| if (isCellVecTy(ctx, t)) return p.openAssign(target, value);
        if (target != .src and isPtrViewExpr(ctx, target) and !through) return p.openAssign(target, value);
        if (place_ty != null and !owns(ctx, place_ty.?)) return p.openAssign(target, value);
        try p.record(value, .new_value, .owned, .assignment);
        if (actsBeforeStore(target, value)) try p.indexes(target);
        try p.record(target, .slot, .pointer, .assignment);
    }

    /// The value and the indexes of an assignment that can act before
    /// its store, each evaluated first unless it is pure (`openAssign`).
    fn openAssign(p: *Planner, target: Sexp, value: Sexp) !void {
        if (!actsBeforeStore(target, value)) return;
        if (!isPureArg(p.ctx, value)) try p.record(value, .new_value, .owned, .assignment);
        try p.indexes(target);
    }

    fn indexes(p: *Planner, e: Sexp) !void {
        switch (e.kind() orelse return) {
            .member => try p.indexes(ir.Member.object(e)),
            .index => {
                try p.indexes(ir.Index.object(e));
                const index = ir.Index.index(e);
                if (!index.isKind(.@"..")) return p.indexOf(index);
                for ([2]Sexp{ ir.@"..".left(index), ir.@"..".right(index) }) |bound| if (bound != .nil) try p.indexOf(bound);
            },
            else => {},
        }
    }

    fn indexOf(p: *Planner, e: Sexp) !void {
        if (!isPureArg(p.ctx, e)) try p.record(e, .index, .owned, .assignment);
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

/// Whether `x op= v` lowers to a builtin that assigns its result
/// (`rig.rem`, `@shlExact`, an integer `/`): its place is found once.
fn divides(ctx: *const SemContext, op: Tag, target: Sexp, value: Sexp) bool {
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
        else => return false,
    }
}

fn isVecTy(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == ctx.vec_sym_id,
        else => false,
    };
}

/// A Cell holding a Vec, reached by value, view, or shared handle.
fn isCellVecTy(ctx: *const SemContext, ty: TypeId) bool {
    const cell = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id and pn.args.len == 1) pn.args[0] else return false,
        else => return false,
    };
    return isVecTy(ctx, cell);
}
