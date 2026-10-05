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
pub fn isPtrBorrowTy(ctx: *const SemContext, ty: TypeId) bool {
    return sema.viewHeldAsPointer(ctx, ty);
}

pub fn isPtrBorrowExpr(ctx: *const SemContext, e: Sexp) bool {
    return isPtrBorrowTy(ctx, typeOf(ctx, e) orelse return false);
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

/// The function type of a function, closure, or borrowed callable.
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
/// or a borrow or move of a name.
pub fn isPureArg(ctx: *const SemContext, e: Sexp) bool {
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
    return f.params.len > 0 and ctx.types.get(f.params[0]) == .borrow_write;
}

/// The receiver of `value.method(...)` when it is an owned temporary
/// the method consumes (`mk().consume(...)`).
pub fn consumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasReceiver(ctx, call)) return null;
    const callee = ctx.calleeOf(call);
    const obj = ir.Member.object(callee);
    if (hasStorage(ctx, obj) or obj.isKind(.move) or !ownsValue(ctx, obj)) return null;
    const f = fnType(ctx, typeOf(ctx, callee)) orelse return null;
    if (f.params.len == 0) return null;
    return switch (ctx.types.get(f.params[0])) {
        .borrow_read, .borrow_write => null,
        else => obj,
    };
}

/// A closure literal lent as a borrowed callable.
pub fn lentLiteral(ctx: *const SemContext, e: Sexp) bool {
    return e.isKind(.lambda) and ctx.callableOf(e) != null;
}

/// Whether a call's arguments must be evaluated into temporaries
/// first: when binding keyword arguments reorders two that have side
/// effects, or when an argument may leave (`!`, a `catch` that
/// returns) after an owned value was produced, which would be lost.
pub fn hoistsArgs(ctx: *const SemContext, call: Sexp) bool {
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
    // and a Cell a read borrow may change must not be in one.
    if (receiverOf(ctx, call)) |recv| if ((!hasStorage(ctx, recv) and recv.kind() != .move and receiverWrites(ctx, call)) or ctx.lendsCellTemp(unborrowed(recv))) return true;
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
    if (consumedTemporary(ctx, call) != null) return .consumed;
    // Borrow sigils on a receiver are implicit in Zig's method calls.
    const recv = unborrowed(receiverOf(ctx, call) orelse return null);
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
    var p = unborrowed(e);
    while (true) {
        if (ctx.dropsTemp(p)) return true;
        if (!p.isKind(.member) and !p.isKind(.index)) return false;
        p = unborrowed(ir.get(p, .object));
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
    if (sema.handsOver(ctx, e).kind != .branches) return false;
    if (ctx.useOf(e)) |use| if (use == .take) return false;
    const ty = typeOf(ctx, e) orelse return false;
    if (!sema.readByAddress(ctx, ty)) return false;
    return switch (ctx.types.get(ty)) {
        .text, .array, .nominal, .parameterized_nominal, .imported_nominal => true,
        else => false,
    };
}

/// Whether `if o as x` over `value` borrows the value inside the
/// optional rather than copying it (`checkOptionalBinding`).
pub fn borrowsOptionalValue(ctx: *const SemContext, value: Sexp) bool {
    const ty = typeOf(ctx, value) orelse return false;
    return isPtrBorrowTy(ctx, ty) and !ctx.readsThrough(value);
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
/// subject is read, `!` binds write borrows of the fields, and `<` of
/// a value that owns a resource hands the arm its fields.
pub const MatchMode = enum { read, write, consume };

/// The enum a `match` switches on: the one a box or handle holds, or
/// the subject's type.
pub fn matchedType(ctx: *const SemContext, match: Sexp) ?TypeId {
    const scrutinee = ir.Match.subject(match);
    const ty = typeOf(ctx, scrutinee) orelse return null;
    const reached = sema.unwrapAccess(ctx, ty);
    return if (reached != sema.unwrapBorrows(ctx, ty)) reached else ty;
}

pub fn matchMode(ctx: *const SemContext, match: Sexp) MatchMode {
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
    return ctx.headerOf(match) == .held or matchGuarded(match) or
        (matchRereads(ctx, match) and !subjectRereadable(unborrowed(ir.Match.subject(match))));
}

/// How a `match` that evaluates its subject first (`matchBlock`) holds
/// it in `__rig_subject`: the address of a place, a view a call returns
/// as the pointer it is, or the value; null when it reads the subject
/// again as it is written.
pub fn subjectHold(ctx: *const SemContext, match: Sexp) ?StorageBy {
    const subject = unborrowed(ir.Match.subject(match));
    if (subjectRereadable(subject)) return null;
    const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
    if (hasStorage(ctx, value) and !subject.isKind(.move) and sema.firstStmtTemp(ctx, value) == null) return .pointer;
    if (!subject.isKind(.move) and isPtrBorrowExpr(ctx, value)) return .pointer;
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
/// field: every field but a borrow or slice, which is bound as it is.
pub fn fieldIsPointee(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .borrow_write, .slice => false,
        else => true,
    };
}

/// Whether a payload binding of type `binding` (null when unknown) for
/// field `f` points at the field: a write binds a pointer to each field,
/// and a read binds one to a field it views (`?F` of a field that is no
/// view).
pub fn payloadByAddress(ctx: *const SemContext, binding: ?TypeId, f: sema.Field, writes: bool) bool {
    const viewed = !writes and if (binding) |t| ctx.types.get(t) == .borrow_read and ctx.types.get(f.ty) != .borrow_read else false;
    return (writes or viewed) and fieldIsPointee(ctx, f.ty);
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

/// `e` without the borrow sigils around it.
pub fn unborrowed(e: Sexp) Sexp {
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
        if (ctx.lendOf(e)) |lend| {
            if (lendsInsideOptional(lend)) try p.record(e, .lent, .pointer, .expression);
            try p.leaves(if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e);
        }
        if (e != .list) return;
        switch (e.kind() orelse return) {
            // A value read where its leaves are is reached through the
            // address of the leaf it takes, for a field, an element, or a
            // method.
            .member => try p.leaves(unborrowed(ir.Member.object(e))),
            .index => try p.leaves(ir.Index.object(e)),
            .call => try p.call(e),
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
            if (used) try p.record(cond, .as_value, .pointer, .body);
            return;
        }
        if (borrowsOptionalValue(ctx, value)) {
            // A borrow of a temporary the header drops: the binding views
            // a copy of the value inside.
            const copy = ctx.copiesHeader(cond) or (value.isKind(.read) and ctx.lendsCellTemp(ir.Read.operand(value)));
            if (ctx.copiesHeader(cond)) try p.header(value);
            if (used) {
                try p.record(cond, .as_value, if (copy) .copy else .pointer, .body);
                if (copy) try p.record(cond, .as_copy, .copy, .body);
            }
            return;
        }
        try p.header(value);
        const sym = ctx.symbolOf(name);
        const ty: ?TypeId = if (sym) |s| known(ctx, ctx.symbols.items[s].ty) else if (typeOf(ctx, value)) |t| switch (ctx.types.get(sema.unwrapBorrows(ctx, t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        // A resource is captured, then owned by the binding.
        if (ty != null and owns(ctx, ty.?)) try p.record(cond, .as_value, .owned, .body);
    }

    fn forLoop(p: *Planner, loop: Sexp) !void {
        const ctx = p.ctx;
        const mode = ir.For.mode(loop).tag;
        const source = ir.For.source(loop);
        if (source.isKind(.@"..")) {
            try p.record(loop, .range_start, .owned, .construct);
            try p.record(loop, .range_end, .owned, .construct);
            try p.header(ir.@"..".left(source));
            return p.header(ir.@"..".right(source));
        }
        const src_ty = typeOf(ctx, source);
        const is_vec = src_ty != null and isVecTy(ctx, src_ty.?);
        const consuming = if (src_ty) |t|
            (is_vec and (mode == .move or (!hasStorage(ctx, source) and owns(ctx, t)))) or
                (ctx.types.get(t) == .array and owns(ctx, ctx.types.get(t).array.elem) and (mode == .move or !hasStorage(ctx, source)))
        else
            false;
        if (consuming) {
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
        // Writing an array's elements in place iterates through a pointer.
        const elem_ty: ?TypeId = if (ctx.symbolOf(ir.For.@"var"(loop))) |s| known(ctx, ctx.symbols.items[s].ty) else null;
        const by_ptr = mode == .write or (elem_ty != null and ctx.types.get(elem_ty.?) == .borrow_read);
        const array_ptr = by_ptr and !is_vec and src_ty != null and ctx.types.get(sema.unwrapBorrows(ctx, src_ty.?)) == .array;
        if (!array_ptr) try p.header(source);
    }

    fn match(p: *Planner, m: Sexp) !void {
        const ctx = p.ctx;
        const mode = matchMode(ctx, m);
        const subject = unborrowed(ir.Match.subject(m));
        if (ctx.headerOf(m) == .held) try p.record(m, .held, .owned, .construct);
        var reread = false;
        var temp = false;
        if (matchBlock(ctx, m)) {
            if (subjectHold(ctx, m)) |by| {
                try p.record(m, .subject, by, .construct);
                const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                if (!(hasStorage(ctx, value) and !subject.isKind(.move) and sema.firstStmtTemp(ctx, value) == null)) try p.header(value);
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
        if (!(temp or (reread and mode != .consume))) try p.header(subject);
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
            const fields = variantPayload(ctx, ty orelse continue, srcText(ctx, ir.VariantPattern.name(pattern))) orelse continue;
            var any = false;
            var by_addr = mode == .write;
            for (ir.VariantPattern.bindings(pattern), fields) |b, f| {
                if (!p.isUsed(b)) continue;
                any = true;
                const binding: ?TypeId = if (ctx.symbolOf(b)) |s| known(ctx, ctx.symbols.items[s].ty) else null;
                if (payloadByAddress(ctx, binding, f, mode == .write)) by_addr = true;
            }
            if (any) try p.record(arm, .payload, if (by_addr) .pointer else .copy, .arm);
        }
    }

    fn call(p: *Planner, c: Sexp) !void {
        const ctx = p.ctx;
        const callee = ctx.calleeOf(c);
        if (ctx.elemCallOf(callee) != null) return;
        // A closure literal called where it is written is built first.
        if (callee.isKind(.lambda)) try p.record(callee, .invoked, .owned, .call);
        if (!hoistsArgs(ctx, c)) return;
        if (receiverHold(ctx, c)) |hold| {
            const recv = if (hold == .consumed) consumedTemporary(ctx, c).? else unborrowed(receiverOf(ctx, c).?);
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
                .value => if (argumentParam(ctx, c, ai)) |t| (if (isPtrBorrowTy(ctx, t)) .pointer else .owned) else .owned,
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
        // is dropped.
        const ty = known(ctx, s.ty) orelse return;
        const ptr = isPtrBorrowTy(ctx, ty);
        const writes_through = !ctx.repoints(set) and sema.assignWritesThrough(ctx, s.ty);
        if ((ptr and writes_through and owns(ctx, sema.unwrapBorrows(ctx, ty))) or (!ptr and owns(ctx, ty)))
            try p.record(value, .new_value, .owned, .assignment);
    }

    /// An assignment to a field or element (`emitPlaceAssign`).
    fn placeAssign(p: *Planner, target: Sexp, value: Sexp) !void {
        const ctx = p.ctx;
        const through = ctx.writesThrough(target);
        const target_ty = typeOf(ctx, target);
        const place_ty = if (through) sema.unwrapBorrows(ctx, target_ty.?) else target_ty;
        if (target.isKind(.index)) if (typeOf(ctx, ir.Index.object(target))) |t| if (isCellVecTy(ctx, t)) return p.openAssign(target, value);
        if (target != .src and isPtrBorrowExpr(ctx, target) and !through) return p.openAssign(target, value);
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
    /// (`reachesLeaf`), that capture a payload by address.
    fn leaves(p: *Planner, e: Sexp) !void {
        if (reachesLeaf(p.ctx, e)) try p.leaf(e);
    }

    fn leaf(p: *Planner, e: Sexp) !void {
        if (sema.handsOver(p.ctx, e).kind != .branches) return;
        switch (e.kind() orelse return) {
            .@"if" => {
                try p.leaf(lastValue(ir.If.then(e)));
                try p.leaf(lastValue(ir.If.@"else"(e)));
            },
            .@"??" => {
                try p.record(e, .leaf, .pointer, .expression);
                try p.leaf(ir.@"??".right(e));
            },
            .propagate, .propagate_none => try p.record(e, .leaf, .pointer, .expression),
            .@"catch" => {
                try p.record(e, .leaf, .pointer, .expression);
                const handler = ir.Catch.handler(e);
                try p.leaf(if (p.isUsed(ir.Catch.name(e))) lastValue(handler) else handler);
            },
            else => {},
        }
    }
};

/// Whether `x op= v` lowers to a builtin that assigns its result
/// (`@rem`, `@shlExact`, an integer `/`): its place is found once.
fn divides(ctx: *const SemContext, op: Tag, target: Sexp, value: Sexp) bool {
    switch (op) {
        .@"%", .@"<<" => return true,
        .@"/" => {
            for ([2]Sexp{ target, value }) |e| {
                const ty = typeOf(ctx, e) orelse continue;
                switch (ctx.types.get(sema.unwrapBorrows(ctx, ty))) {
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
    return switch (ctx.types.get(sema.unwrapBorrows(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == ctx.vec_sym_id,
        else => false,
    };
}

/// A Cell holding a Vec, reached by value, borrow, or shared handle.
fn isCellVecTy(ctx: *const SemContext, ty: TypeId) bool {
    const cell = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id and pn.args.len == 1) pn.args[0] else return false,
        else => return false,
    };
    return isVecTy(ctx, cell);
}
