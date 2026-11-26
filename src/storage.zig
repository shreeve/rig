//! Storage deciders: which hidden storage emit makes, and how.
//!
//! Each is a pure function of the typing facts. Lowering asks them as
//! it makes each body's vars (`src/lower.zig`): for each expression or
//! construct emit holds in hidden storage, a var of the kinds listed
//! here, what it holds (`StorageKind`), how (`StorageBy`), for how long
//! (`StorageLife`), and how it drops what it holds; and for each
//! binding, how it drops its value (`bindingDrop`)
//! (docs/internals/INTERNALS.md, "Storage facts"). Emit asks the same
//! ones; it names each storage location through its var
//! (`Emitter.hiddenStorage`), which must exist and agree. So the
//! ownership checker walks the storage the emitted program has, from
//! the same LIR. Emit never makes storage that no var names.

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

// =============================================================================
// The var table
// =============================================================================

/// What a hidden storage location holds, and the Zig name emit gives it.
pub const StorageKind = enum {
    /// An owning temporary its statement or header drops at its end
    /// (`__rig_tmp`): `dropsTemp`.
    temp,
    /// The value of a header that makes statement temporaries, yielded
    /// by the block that ends them (`__rig_hdr`).
    header_value,
    /// The construct (`match`, `for`, `as`) binds the parts of that
    /// yielded value, a copy of its subject: `copiesHeader`. No name of
    /// its own: the storage is the header's value.
    header_copy,
    /// The made value a header's subject is a part of, held for the
    /// construct (`__rig_held`): `Header.held`.
    held,
    /// The array a `for` takes, held for the loop (`__rig_src`):
    /// `Header.taken`.
    taken,
    /// The iterator a consuming `for` hands its elements over from
    /// (`__rig_it`).
    iterator,
    /// The element a consuming `for` hands over, before its binding
    /// takes it (`__rig_elem`).
    element,
    /// A range `for`'s counter, from the range's start (`__rig_i`).
    range_start,
    /// A range `for`'s end (`__rig_end`).
    range_end,
    /// Whether an inclusive range `for` runs again (`__rig_more`): its
    /// counter never steps past the end, which may be its type's largest
    /// value.
    range_more,
    /// A `match` subject evaluated once, before its arms (`__rig_subject`).
    subject,
    /// The whole value a `match <x` arm takes (`__rig_whole`).
    whole,
    /// A variant's payload an arm captures (`__rig_payload`).
    payload,
    /// What `if … as` or `while … as` captures (`__rig_opt`).
    as_value,
    /// A mutable copy of what an `as` captures, which its binding views
    /// (`__rig_opt_N_v`).
    as_copy,
    /// The value inside an optional a view reaches (`__rig_viewed`).
    viewed,
    /// The copy an API object of a read view of plain data, or of a type
    /// parameter's value, views (`Erasure.copy`), a local of the erasing
    /// block (`__rig_erased`).
    erased_copy,
    /// The payload a branch of a value read where its leaves are takes,
    /// captured by address (`__rig_leaf`).
    leaf,
    /// The error a `catch |e|` handler names (`__rig_err`).
    error_value,
    /// An argument of a call whose arguments are evaluated first
    /// (`__rig_arg`).
    argument,
    /// The self of such a call, or an actor's handle, or a select
    /// arm's channel (`__rig_recv`): `storage.heldFirst`.
    self,
    /// The environment of a closure literal passed to a call (`__rig_env`).
    environment,
    /// A closure literal called where it is written, or the callee of a
    /// call whose arguments are evaluated first, which a value the call
    /// reaches is (`__rig_fn`): `storage.heldFirst`.
    invoked,
    /// The environment an owned closure allocates (`__rig_env`), which
    /// the closure value then owns.
    closure_env,
    /// An assignment's value, made before the store (`__rig_new`).
    new_value,
    /// The value an assignment's target path starts from, evaluated after
    /// the value and before the indexes (`__rig_base`).
    base,
    /// An index of an assignment's target, evaluated before the store
    /// (`__rig_ix`).
    index,
    /// The place an assignment stores to, found once (`__rig_slot`).
    slot,
    /// The API object a call through its table reads twice, for the
    /// table and the value, evaluated once (`__rig_obj`): a copy of the
    /// view or box, which nothing views.
    api_object,
    /// The place a call through an API object's table writes its result
    /// to (`TableEntry.result_out`), copied out as the call returns
    /// (`__rig_res`).
    result_place,
    /// The several results a call gives, held for its statement while
    /// each target takes its own, left to right (`__rig_res`): a
    /// destructure's, `q, r = f()`. A result no target takes (`_`) it
    /// drops at the statement's end.
    results,
    /// The header (pointer, length, and capacity) of a String or List a
    /// write view parameter views, held in a local for the function's
    /// body and written back as it returns (`__rig_header`;
    /// `storage.planHeldHeaders`): the parameter's name views the local,
    /// so a loop keeps the header in registers.
    held_header,
    /// The record of a task made by `t = f(x)&` that stays in its
    /// maker's frame and is waited for there (`storage.taskRecordIn`): a
    /// fork. Emit makes it in this slot, `var __rig_task_N =
    /// rig.Task(T).frame.spawn(f, .{ x })`, and starts it there,
    /// `t = __rig_task_N.start()`; it counts in the frame
    /// (`accounts.count`).
    task_record,
    /// A value made here whose address emit takes where Zig holds it, in
    /// no slot: a leaf no statement slot keeps (`storage.leafStep` is
    /// `made`, and not `dropsTemp`), or a literal, reached by address.
    /// No name of its own: the storage is Zig's, which keeps it until its
    /// statement ends.
    zig_temp,
    /// Not storage: the value of `_ = e`, or of a statement `<e` of
    /// anything but a name, which Zig drops at once. It is in the table
    /// for its `drop`, and has no name.
    discard,
};

/// How a hidden storage location holds what it holds.
pub const StorageBy = enum {
    /// The value is its own: made there, or taken, and dropped there if
    /// nothing takes it on.
    owned,
    /// A copy of a value that is still held where it was: a view of the
    /// storage views the copy, not that value.
    copy,
    /// The address of a place, or of storage another fact records.
    pointer,
    /// Text a template makes where a `?String` reads it, held in the
    /// storage itself while it fits 256 bytes, and in a heap block the
    /// storage frees past them (`rig.TextBuf`): no String is made.
    buffer,
};

/// How long a hidden storage location lives.
pub const StorageLife = enum {
    /// Until its statement ends; a header is its own statement.
    statement,
    /// Until its header ends.
    header,
    /// Until the construct (`match`, `for`, `if … as`) ends.
    construct,
    /// For one iteration of a loop.
    iteration,
    /// Until its `match` arm ends.
    arm,
    /// Until the body of its `if … as` or `while … as` ends.
    body,
    /// Until its `catch` handler ends.
    handler,
    /// Until the expression it is made in ends.
    expression,
    /// Until its call returns.
    call,
    /// Until the `task.select` whose arm it is a part of returns: the
    /// select makes every arm, then runs the one it commits.
    select,
    /// Until its assignment's store.
    assignment,
    /// Until the block it is made in ends: each pass of a loop's body
    /// makes it anew.
    block,
};

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
    if (std.ascii.isDigit(t[0]) or sema.isStringLiteralText(t) or t[0] == '.') return true;
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false");
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
    const f = ctx.foreignMember(ctx.symbolOf(ir.Member.object(obj)) orelse return null, srcText(ctx, ir.Member.name(obj))) orelse return null;
    return f.ctx.symbols.items[f.id];
}

/// An object, enum, or generic type: calling it constructs a value.
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
    switch (e) {
        .src => {
            if (isLiteralText(srcText(ctx, e)) or sema.isNoneLeaf(ctx, e)) return true;
            const sym = ctx.symbolOf(e) orelse return false;
            const s = ctx.symbols.items[sym];
            return switch (s.kind) {
                .local, .param, .capture => s.flags.fixed or s.flags.comptime_known,
                else => true,
            };
        },
        .list => return switch (e.kind().?) {
            .enum_lit, .symbol => true,
            // A view held as a pointer is the name's address; a view
            // held by value (a `?String`'s bytes, a slice, a copy of a
            // number) reads the name where the call runs, after the
            // arguments written before it.
            .read, .write => ir.get(e, .operand) == .src and ((isPtrViewExpr(ctx, e) and ctx.viewOf(e) == null) or isPureArg(ctx, ir.get(e, .operand))),
            .move => ir.get(e, .operand) == .src,
            .neg => ir.Neg.operand(e) == .src and isLiteralText(srcText(ctx, ir.Neg.operand(e))),
            else => false,
        },
        else => return false,
    }
}

/// The self of `value.method(...)`.
pub fn selfOf(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasSelf(ctx, call)) return null;
    return ir.Member.object(ctx.calleeOf(call));
}

/// What a call whose arguments are evaluated first holds as its self
/// (`selfHold`): the self of `value.method(...)`, the handle of an
/// actor's method, `h.m(...)`, which stands for its self, or the
/// channel of an arm of `task.select`, `ch` of `!ch.on_recv()`, which
/// the select evaluates in the arm's turn. A deadline arm,
/// `time.after(ms: 50)`, has none.
pub fn heldSelf(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (ctx.selectArmOf(call)) |arm| return if (arm == .after) null else ir.get(ir.Member.object(ctx.calleeOf(call)), .operand);
    if (ctx.isActorCall(call)) return ir.Member.object(ctx.calleeOf(call));
    return selfOf(ctx, call);
}

/// The part of a call it evaluates before its arguments, which a call
/// whose arguments are evaluated first holds in its turn, as written
/// (`selfHold`): its self (`heldSelf`), held as `self`, or else a
/// callee that is a value, `pick(k)(...)`, `fs[i](...)`, `mk().f(...)`,
/// `b.f(...)`, or a local `f` an argument may reassign, held as
/// `invoked`. A function, a constant, a fixed binding, a stack
/// closure, a type, a module's function, an instance, and a closure
/// literal (built first, `invoked`) are no such value.
pub fn heldFirst(ctx: *const SemContext, call: Sexp) ?HeldFirst {
    if (heldSelf(ctx, call)) |recv| return .{ .node = viewedPlace(recv), .kind = .self };
    const callee = ctx.calleeOf(call);
    if (callee == .src) {
        const sym = ctx.symbols.items[ctx.symbolOf(callee) orelse return null];
        switch (sym.kind) {
            .local, .param, .capture => if (sym.flags.closure or isPureArg(ctx, callee)) return null,
            else => return null,
        }
    }
    if (callee.isKind(.lambda) or ctx.instanceOf(callee) != null) return null;
    if (callee.isKind(.member) and isTypeCallee(ctx, ir.Member.object(callee))) return null;
    if (fnType(ctx, typeOf(ctx, callee)) == null) return null;
    return .{ .node = callee, .kind = .invoked };
}

/// The part `heldFirst` gives, without its view sigils, and the kind of
/// storage that holds it.
pub const HeldFirst = struct {
    node: Sexp,
    kind: StorageKind,
};

/// Whether `call` passes a self, its callee's object, as its first
/// parameter (`value.method(...)`), as its recorded parameters say
/// (`SemContext.callParamsOf`): not `Type.f(...)`, `module.f(...)`, or a
/// callable a field holds (`s.cb(...)`). A call checked against no
/// signature has a self when its callee is a member of a value.
pub fn hasSelf(ctx: *const SemContext, call: Sexp) bool {
    const callee = ctx.calleeOf(call);
    if (!callee.isKind(.member)) return false;
    if (ctx.callParamsOf(call)) |filled| return filled.fills.len > 0 and filled.fills[0] == .self;
    return !isTypeCallee(ctx, ir.Member.object(callee));
}

/// Whether the method of `value.method(...)` takes `!@`.
pub fn selfWrites(ctx: *const SemContext, call: Sexp) bool {
    if (!hasSelf(ctx, call)) return false;
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return false;
    return f.params.len > 0 and ctx.types.get(f.params[0]) == .write_view;
}

/// The self of `value.method(...)` when it is an owned temporary
/// the method consumes (`mk().consume(...)`).
pub fn consumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    return if (decideConsumedTemporary(ctx, call) != null) selfOf(ctx, call) else null;
}

fn decideConsumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasSelf(ctx, call)) return null;
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

/// A closure literal passed as a callable view.
pub fn viewedLiteral(ctx: *const SemContext, e: Sexp) bool {
    return e.isKind(.lambda) and ctx.callableOf(e) != null;
}

/// Whether a call's arguments, or an array literal's elements, must be
/// evaluated into temporaries first: when binding keyword arguments
/// reorders two that have side effects, or when a part may leave after
/// an owned value was produced (`leavesAfterOwned`), which would be lost.
pub fn hoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    if (call.isKind(.array)) return leavesAfterOwned(ctx, false, ir.Array.elems(call));
    if (!call.isKind(.call)) return false;
    // `task.select` evaluates its arms' parts first, in their order, in
    // storage that lives until the arm it commits has run; an arm holds
    // none of its own.
    if (ctx.selectArmOf(call) != null) return false;
    if (ctx.isSelect(call)) {
        var owned = false;
        for (ir.Call.args(call)) |named| {
            const arm = argValue(named);
            if (callHoistsArgs(ctx, arm)) return true;
            if (leavesAfterOwned(ctx, owned, ir.Call.args(arm))) return true;
            for (ir.Call.args(arm)) |a| owned = owned or ownsValue(ctx, argValue(a));
        }
        return false;
    }
    return callHoistsArgs(ctx, call);
}

fn callHoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    if (ctx.isPrintCall(call) or stringCall(ctx, call) != null) return false;
    const args = ir.Call.args(call);
    // A closure literal passed to the call gets an environment first.
    for (args) |a| if (viewedLiteral(ctx, argValue(a))) return true;
    if (ctx.callSlotsOf(call)) |slots| {
        var last: ?usize = null;
        for (slots) |slot| {
            const given: []const u32 = switch (slot) {
                .arg => |*a| a[0..1],
                .default => continue,
                .parts => |p| p.args,
            };
            for (given) |ai| {
                if (isPureArg(ctx, argValue(args[ai]))) continue;
                if (last) |l| if (ai < l) return true;
                last = ai;
            }
        }
    }
    const callee = ctx.calleeOf(call);
    // Zig passes a temporary self to a `!@` method as a constant.
    if (selfOf(ctx, call)) |recv| if (!hasStorage(ctx, recv) and recv.kind() != .move and selfWrites(ctx, call)) return true;
    const owned = (callee.isKind(.member) and ir.Member.object(callee).isKind(.move)) or consumedTemporary(ctx, call) != null;
    return leavesAfterOwned(ctx, owned, args);
}

/// Whether a value built of several parts evaluated in order (a call's
/// arguments, an array literal's elements, the results of `return a,
/// b`) has a part that can leave after an earlier part that owns was
/// made, or after `owned` was: a `!` or `?`, or a `return`, `break`,
/// or `continue` in a `catch` handler or a branch, leaves the
/// enclosing block, and Zig, building the value as it goes, would lose
/// what was made. Such parts are evaluated into storage first, which
/// drops an owned one on the way out.
fn leavesAfterOwned(ctx: *const SemContext, owned_before: bool, parts: []const Sexp) bool {
    var owned = owned_before;
    for (parts) |a| {
        const v = argValue(a);
        if (owned and setLeaves(v)) return true;
        if (ownsValue(ctx, v)) owned = true;
    }
    return false;
}

/// How a call whose arguments are evaluated first (`hoistsArgs`) holds
/// its self, or the callee it evaluates in its place (`heldFirst`),
/// while they run.
pub const SelfHold = enum {
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

    /// How the storage holds self, given whether `recv` itself
    /// has storage (`hasStorage`): a part of a temporary is a copy.
    pub fn by(hold: SelfHold, part: bool) StorageBy {
        return switch (hold) {
            .consumed => .owned,
            .leaf, .slot, .place => .pointer,
            .value => if (part) .copy else .owned,
        };
    }
};

/// How a call whose arguments are evaluated first holds its self, or
/// the callee it evaluates in its place (`heldFirst`), or null when it
/// is evaluated where the call is: a self, or a callee that owns, that
/// is a name or a field path off one, which the ownership checker
/// holds for the call, so no argument changes what it reads. A callee
/// that copies is copied in its turn, as plain data is read (Core
/// §6), which keeps no view.
pub fn selfHold(ctx: *const SemContext, call: Sexp) ?SelfHold {
    if (consumedTemporary(ctx, call) != null) return .consumed;
    // View sigils on a self are implicit in Zig's method calls.
    const first = heldFirst(ctx, call) orelse return null;
    const recv = first.node;
    if (first.kind == .invoked and !ownsValue(ctx, recv)) return .value;
    const writes = selfWrites(ctx, call);
    const temporary = !hasStorage(ctx, recv) and !recv.isKind(.move);
    // A part that acts or leaves (`o?`, `o ?? return`, `mk()`) runs
    // before the arguments, and one that indexes picks its element
    // first.
    if (!contains(recv, &.{.index}) and !setActs(recv) and !(writes and temporary)) return null;
    if (reachesLeaf(ctx, recv)) return .leaf;
    if (temporary and keptInSlot(ctx, recv)) return .slot;
    if (!temporary) return .place;
    return .value;
}

/// How a call whose arguments are evaluated first holds an argument
/// that is not pure (`isPureArg`), and an array literal whose elements
/// are evaluated first holds such an element.
pub const ArgumentHold = enum {
    /// A closure literal passed as a callable: its environment, and the
    /// `rig.FnRef` over it.
    closure,
    /// Any other callable passed: the `rig.FnRef`.
    callable,
    /// A value passed as the view its parameter expects (`viewOf`): the
    /// view, which points where the value is, a place or its
    /// statement's slot.
    viewed,
    /// The argument's value.
    value,
};

pub fn argumentHold(ctx: *const SemContext, v: Sexp) ArgumentHold {
    if (ctx.callableOf(v) != null) return if (v.isKind(.lambda)) .closure else .callable;
    if (ctx.viewOf(v) != null and !ctx.viewsTempArray(v)) return .viewed;
    return .value;
}

/// The types of the run-time parameters a call's arguments fill, in
/// slot order: every parameter but the one its self fills, as the
/// call's recorded parameters say (`SemContext.callParamsOf`). A callable
/// a field holds (`s.cb(...)`) has no self; `value.method(...)` does.
pub fn argParams(ctx: *const SemContext, call: Sexp) []const TypeId {
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return &.{};
    return if (hasSelf(ctx, call) and f.params.len > 0) f.params[1..] else f.params;
}

/// The type of the parameter argument `a` of `call` fills; null when
/// unknown.
pub fn argumentParam(ctx: *const SemContext, call: Sexp, ai: usize) ?TypeId {
    const params = argParams(ctx, call);
    const slot = if (ctx.callSlotsOf(call)) |slots| sema.slotOf(slots, ai) orelse ai else ai;
    return if (slot < params.len) params[slot] else null;
}

/// Whether `e` is a value its statement's slot keeps (`dropsTemp`), or
/// a field or element of one: Zig storage that lives until the
/// statement ends.
pub fn keptInSlot(ctx: *const SemContext, e: Sexp) bool {
    var p = viewedPlace(e);
    while (true) {
        if (ctx.dropsTemp(p)) return true;
        if (!p.isKind(.member) and !p.isKind(.index)) return false;
        p = viewedPlace(ir.get(p, .object));
    }
}

/// Whether `e`, a value that branches with a leaf that is not made
/// there (`sema.handsOver` is `branches`), is reached where the leaf
/// it takes is: it is read, not taken, and its type is read by
/// address (`sema.readByAddress`), as the ownership checker reads
/// each leaf in place (`holdBranchReads`). Zig would copy it into a
/// temporary, and a `?@` method would view the copy; an object, an
/// array, or a String is instead reached through the address of its
/// leaf, which Zig follows for a field, an element, or a method.
pub fn reachesLeaf(ctx: *const SemContext, e: Sexp) bool {
    if (handsKind(ctx, e) != .branches) return false;
    if (ctx.useOf(e)) |use| if (use == .take) return false;
    const ty = typeOf(ctx, e) orelse return false;
    if (!sema.readByAddress(ctx, ty)) return false;
    return switch (ctx.types.get(ty)) {
        .string, .array, .nominal, .parameterized_nominal => true,
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
    /// `?x` or `!x`: the view it makes.
    view,
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
        .view => .view,
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
/// (`startsOutsideHeader`), a view of one held as a pointer (`!v[i]`),
/// or a value that branches (`a if c else b`) each leaf of which reaches
/// one or jumps. A value made in the header, a part of one, or a place
/// inside a view of one (`id(?mk()).e`) has no place that outlives the
/// header, and the header yields its value.
pub fn headerPoints(ctx: *const SemContext, e: Sexp) bool {
    if (e == .nil or sema.firstStmtTemp(ctx, e) == null) return false;
    return reachesPlace(ctx, e);
}

/// The value a header (`match`, `for`, `as`) evaluates: a `match`'s
/// subject without its view sigils, a `for`'s source, an `as` value.
pub fn headerSubject(header: Sexp) Sexp {
    return switch (header.kind() orelse return .nil) {
        .match => viewedPlace(ir.Match.subject(header)),
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
        // A read view of a scalar or a view is a copy.
        .view => return (e.isKind(.read) or e.isKind(.write)) and isPtrViewExpr(ctx, e) and reachesPlace(ctx, ir.get(e, .operand)),
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
pub const MatchMode = enum(u2) { read, write, consume };

/// The type an arm's member pattern is of: an error member's own set,
/// which the subject may be one of; else the subject's, `subject`.
pub fn armType(ctx: *const SemContext, pattern: Sexp, subject: ?TypeId) ?TypeId {
    if (pattern.isKind(.variant_pattern) or pattern.isKind(.member)) if (ctx.typeOf(pattern)) |t| if (sema.isErrorSet(ctx, t)) return t;
    return subject;
}

/// The enum a `match` switches on: the one a box or handle holds, or
/// the subject's type.
pub fn matchedType(ctx: *const SemContext, match: Sexp) ?TypeId {
    const scrutinee = ir.Match.subject(match);
    const ty = typeOf(ctx, scrutinee) orelse return null;
    const reached = sema.unwrapAccess(ctx, ty);
    return if (reached != sema.unwrapViews(ctx, ty)) reached else ty;
}

pub fn matchMode(ctx: *const SemContext, match: Sexp) MatchMode {
    const scrutinee = ir.Match.subject(match);
    if (scrutinee.isKind(.write)) return .write;
    const ty = matchedType(ctx, match) orelse return .read;
    if ((scrutinee.isKind(.move) or ctx.takesSubject(match)) and owns(ctx, ty)) return .consume;
    return .read;
}

/// Whether `pattern` is a catch-all arm's: a name that binds, or `_`;
/// not a literal, nor a module constant's name (`sema.patternConst`).
pub fn isCatchAll(ctx: *const SemContext, pattern: Sexp) bool {
    return pattern == .src and !isLiteralText(rig.leafText(ctx.source, pattern.src)) and sema.patternConst(ctx, pattern) == null;
}

/// Whether the pattern of `match` arm `arm` takes every value
/// (`isCatchAll`), decided once. Asked of the arm, not of its pattern: a
/// `matches` test's hidden `_` arm has its pattern at the position of the
/// pattern written, which may be a leaf as well.
pub fn catchesAll(ctx: *const SemContext, arm: Sexp) bool {
    return isCatchAll(ctx, ir.Arm.pattern(arm));
}

/// Whether some arm of `match` has a guard.
pub fn matchGuarded(match: Sexp) bool {
    for (ir.Match.arms(match)) |arm| if (ir.Arm.guard(arm) != .nil or rig.patternTests(ir.Arm.pattern(arm))) return true;
    return false;
}

/// Whether `match` picks its arm before it runs one: an arm has a guard,
/// or the match is on text, which a Zig `switch` cannot test. Decided
/// once.
pub fn matchSelects(ctx: *const SemContext, match: Sexp) bool {
    if (matchGuarded(match)) return true;
    const ty = matchedType(ctx, match) orelse return false;
    return sema.isText(ctx, sema.unwrapViews(ctx, ty));
}

/// The patterns an arm's pattern is emitted as, a prong each:
/// alternatives that bind names are a prong apiece (`emit.prongsOf`).
pub fn prongsOf(ctx: *const SemContext, pattern: *const Sexp) []const Sexp {
    if (ctx.altsBind(pattern.*)) return ir.AltPattern.alts(pattern.*);
    return pattern[0..1];
}

/// Whether `match` reads its subject again after picking an arm: a
/// `match !x` binding of the whole value points at the place, and a
/// `match <x` arm with alternatives drops the value from it.
pub fn matchRereads(ctx: *const SemContext, match: Sexp) bool {
    // An error that may carry fields is switched on by its code, and read
    // again for its fields.
    if (matchedType(ctx, match)) |ty| {
        const value = sema.unwrapViews(ctx, ty);
        if (ctx.types.get(value) == .any_error or sema.setHasFields(ctx, value)) return true;
    }
    const mode = matchMode(ctx, match);
    for (ir.Match.arms(match)) |arm| {
        const pattern = ir.Arm.pattern(arm);
        if (mode == .write and isCatchAll(ctx, pattern)) return true;
        if (mode == .consume and pattern.isKind(.alt_pattern) and !ctx.altsBind(pattern)) return true;
    }
    return false;
}

/// Whether `match` evaluates its subject first, or holds the value it is
/// a part of (`Header.held`), in a block around the match.
pub fn matchBlock(ctx: *const SemContext, match: Sexp) bool {
    return ctx.headerOf(match) == .held or matchSelects(ctx, match) or matchesGenericView(ctx, match) or
        (matchRereads(ctx, match) and !subjectRereadable(viewedPlace(ir.Match.subject(match))));
}

/// The `T` of a read view `?T` whose form depends on a generic type's
/// arguments: `T` holds a type parameter and neither owns resources nor
/// holds a Cell on its own. Emit writes it `rig.ReadView(T)`, a copy or
/// a pointer per instance; null for any other type. An object or an
/// enum with payloads, and an optional of one, is viewed by address in
/// every instance (`sema.copiedByReadView`), so its view is a pointer
/// whatever its arguments: `rig.ReadView` would ask Zig about the type,
/// which a view inside the type itself (`prev: (?Frame[T])?`) cannot.
pub fn genericReadView(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const inner = switch (ctx.types.get(ty)) {
        .read_view => |inner| inner,
        else => return null,
    };
    if (!sema.maybeDropGlue(ctx, inner) or sema.holdsCellByValue(ctx, inner)) return null;
    if (viewedByAddressAlways(ctx, inner)) return null;
    return inner;
}

/// Whether every instance of `ty` is viewed by address: an object or an
/// enum with a payload (`sema.isCompound`), or an optional of one.
fn viewedByAddressAlways(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .optional => |inner| viewedByAddressAlways(ctx, inner),
        else => sema.isCompound(ctx, ty),
    };
}

/// Whether `match`'s subject is a view a call returns whose form depends
/// on a generic type's arguments (`genericReadView`): the match holds it
/// in `__rig_subject` and switches where it points (`rig.viewedPtr`),
/// never on a copy of what it views.
fn matchesGenericView(ctx: *const SemContext, match: Sexp) bool {
    const subject = viewedPlace(ir.Match.subject(match));
    if (subject.isKind(.move) or hasStorage(ctx, subject) or !isPtrViewExpr(ctx, subject)) return false;
    return genericReadView(ctx, typeOf(ctx, subject) orelse return false) != null;
}

/// How a `match` that evaluates its subject first (`matchBlock`) holds
/// it in `__rig_subject`: the address of a place, which a header that
/// makes temporaries yields (`headerPoints`), a view a call returns as
/// the pointer it is, or the value; null when it reads the subject again
/// as it is written.
pub fn subjectHold(ctx: *const SemContext, match: Sexp) ?StorageBy {
    const subject = viewedPlace(ir.Match.subject(match));
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

/// What the loans of the memory `e` reads in place name (`sema.livesIn`,
/// CORE §9), decided once and recorded: the type checker asks it of a
/// loop's source, and `verifyDecisions` fails a pass that sees another.
pub fn livesIn(ctx: *const SemContext, e: Sexp) sema.LoanRoots {
    return sema.livesIn(ctx, e);
}

/// What expression `e` hands over (`sema.handsOver`'s kind), decided by
/// the plan for every expression, for emit to read.
pub fn handsKind(ctx: *const SemContext, e: Sexp) sema.Hands.Kind {
    return sema.handsOver(ctx, e).kind;
}

/// Whether `e`, an operand of `==` or `!=` beside `none` or a bare
/// `.variant`, is a value made here that moves and that no statement slot
/// keeps, which the test drops where it reads it (`rig.isNone`,
/// `rig.isVariantDiscard`). Decided once, for emit and the plan.
pub fn dropsWhenTested(ctx: *const SemContext, e: Sexp) bool {
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
    const mode = ir.For.mode(loop).tag;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..")) return false;
    const t = typeOf(ctx, source) orelse return false;
    if (isListTy(ctx, t)) return mode == .move or (!hasStorage(ctx, source) and owns(ctx, t));
    return ctx.types.get(t) == .array and owns(ctx, ctx.types.get(t).array.elem) and (mode == .move or !hasStorage(ctx, source));
}

/// How a `for` loop combines integers into a local, when it is a fold:
/// `for x in xs` over a List or a slice of integers of at most 64 bits,
/// whose body is only `s OP= x`, `s` a local of the element's type. Emit
/// lowers it to `rig.fold`, which combines the elements by vectors, as
/// LLVM's loop vectorizer would and Zig 0.17, with it off, does not
/// (INTERNALS, "Known Zig 0.17 issues"). The result is the plain loop's,
/// and a checked `+` panics on the element where the plain loop would.
pub const Fold = enum(u8) { add_wrap, add, bit_xor, bit_or, bit_and };

/// The `Fold` of `for` loop `loop`, or null when it is not one, decided
/// once.
pub fn fold(ctx: *const SemContext, loop: Sexp) ?Fold {
    const mode = ir.For.mode(loop).tag;
    if (mode != .iter and mode != .read) return null;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..") or forConsumes(ctx, loop)) return null;
    if (ctx.headerOf(loop)) |how| if (how != .viewed) return null;
    if (ctx.symbolOf(ir.For.index(loop))) |i| if (ctx.isUsed(i)) return null;
    // A source a shared handle holds is walked where the handle reaches it.
    const t = typeOf(ctx, source) orelse return null;
    const walked = sema.loopWalks(ctx, t);
    if (walked != sema.unwrapViews(ctx, t)) return null;
    const elem = switch (ctx.types.get(walked)) {
        .slice => |sl| sl.elem,
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.list) pn.args[0] else return null,
        else => return null,
    };
    switch (ctx.types.get(elem)) {
        .int => |i| if (i.width() > 64) return null,
        else => return null,
    }
    const x = ctx.symbolOf(ir.For.@"var"(loop)) orelse return null;
    if (ctx.symbols.items[x].ty != elem) return null;
    const body = ir.For.body(loop);
    if (!body.isKind(.block) or ir.Block.stmts(body).len != 1) return null;
    const set = ir.Block.stmts(body)[0];
    if (!set.isKind(.set)) return null;
    const how: Fold = switch (rig.bindingKindOf(ir.Set.op(set)).operator() orelse return null) {
        .@"+%" => .add_wrap,
        .@"+" => .add,
        .@"^" => .bit_xor,
        .@"|" => .bit_or,
        .@"&" => .bit_and,
        else => return null,
    };
    const target = ir.Set.target(set);
    const value = ir.Set.value(set);
    if (target != .src or value != .src or ctx.symbolOf(value) != x) return null;
    const s = ctx.symbolOf(target) orelse return null;
    const sum = ctx.symbols.items[s];
    if (s == x or sum.kind != .local or sum.access != null or sum.ty != elem) return null;
    return how;
}

/// Whether the binding of a read `for` or of an `if … as` is the bytes
/// of a String it reaches (`loopBindsStringBytes`,
/// `optionalBindsStringBytes`), decided once.
pub fn bindsStringBytes(ctx: *const SemContext, node: Sexp) bool {
    if (node.isKind(.@"for")) return loopBindsStringBytes(ctx, node);
    if (node.isKind(.as)) return optionalBindsStringBytes(ctx, node);
    return false;
}

/// Whether a read `for` over an array, a slice, or a List binds the bytes
/// of each String element: its binding is a `?String`, the read view of a
/// `String`, so the loop walks the elements by address and the binding is
/// each one's `.bytes()`.
fn loopBindsStringBytes(ctx: *const SemContext, loop: Sexp) bool {
    if (ir.For.mode(loop).tag == .write) return false;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..") or forConsumes(ctx, loop)) return false;
    const sym = ctx.symbolOf(ir.For.@"var"(loop)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = sema.loopWalks(ctx, typeOf(ctx, source) orelse return false);
    const elem = switch (ctx.types.get(t)) {
        .array => |a| a.elem,
        .slice => |sl| sl.elem,
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.list or pn.sym == ctx.builtins.table) pn.args[0] else return false,
        else => return false,
    };
    return sema.viewsStringBytes(ctx, elem, bound);
}

/// Whether `if value as name` binds the bytes of a String that a write
/// view in the optional points at (`(!String)?`): the binding is a
/// `?String`, the read view of that String.
fn optionalBindsStringBytes(ctx: *const SemContext, cond: Sexp) bool {
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = typeOf(ctx, ir.As.value(cond)) orelse return false;
    return switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .optional => |inner| ctx.types.get(inner) == .write_view and sema.viewsStringBytes(ctx, inner, bound),
        else => false,
    };
}

/// How a read binding of a write view is bound (`throughWrite`).
pub const ThroughWrite = enum { pointer, value };

/// How the binding of `if value as name` reads through a write view, decided
/// once: when the optional holds one and the binding only reads
/// (`bindingAccess`), it is bound as the read view of what that write view
/// views. `.pointer`: the write view itself (a `?P`, or a `[]T` of a
/// `![]T`); `.value`: the value it points at, copied out, as a `?T` of a
/// scalar or a view is a copy (`sema.viewByValue`). Null for any other
/// binding.
pub fn throughWrite(ctx: *const SemContext, cond: Sexp) ?ThroughWrite {
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return null;
    if (ctx.bindingAccess(sym) != .read) return null;
    const t = typeOf(ctx, ir.As.value(cond)) orelse return null;
    const reached = switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .optional => |inner| inner,
        else => return null,
    };
    return switch (ctx.types.get(reached)) {
        .write_view => |inner| if (ctx.types.get(inner) != .slice and sema.viewByValue(ctx, inner)) .value else .pointer,
        else => null,
    };
}

/// Whether payload binding `b` of `match` points at the field it binds
/// (`payloadByAddress`), decided once.

pub fn bindsByAddress(ctx: *const SemContext, b: Sexp, match: Sexp) bool {
    return payloadByAddress(ctx, b, matchesInPlace(ctx, match));
}

/// Whether the catch-all binding `pattern` of a read `match` is captured by
/// address where the match switches (`catchAllByAddress`), decided once.

pub fn catchAllCaptured(ctx: *const SemContext, pattern: Sexp, match: Sexp) bool {
    const sym = ctx.symbolOf(pattern) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    return catchAllByAddress(ctx, ty, matchesInPlace(ctx, match));
}

/// Whether `match`'s subject is a view a call returns, held as a pointer:
/// the match switches on it where it points, temporaries or not, and binds
/// no copy of it.
pub fn holdsView(ctx: *const SemContext, match: Sexp) bool {
    const subject = ir.Match.subject(match);
    return !hasStorage(ctx, subject) and isPtrViewExpr(ctx, subject);
}

/// Whether a read `match` switches on its subject where it is, never on
/// a copy: the subject reaches a place (`reachesPlace`), through its
/// header's temporaries or not, is a part of the made value the match
/// holds (`Header.held`), or is a view a call returns, switched on where
/// it points. A payload captured by pointer is then the subject's own.
pub fn matchesInPlace(ctx: *const SemContext, match: Sexp) bool {
    if (matchMode(ctx, match) != .read) return false;
    const subject = viewedPlace(ir.Match.subject(match));
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
/// Emit, lowering, and the ownership checker all take an
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
    /// The assignment replaces a value that moves (`sema.resourceKind`):
    /// the place, a field or element of a type that moves (or of a type
    /// sema does not know), a local that owns, or what a `!T` local
    /// writes through when it owns. The new value is made first, then
    /// the old one is dropped and the new one stored.
    drops_old: bool = false,
    _: u4 = 0,
};

/// How assignment `set` runs, decided once.
pub fn setOrder(ctx: *const SemContext, set: Sexp) SetOrder {
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
        .drops_old = dropsOld(ctx, set),
    };
}

/// Whether assignment `set` replaces a value that moves (`SetOrder.drops_old`).
fn dropsOld(ctx: *const SemContext, set: Sexp) bool {
    const kind = rig.bindingKindOf(ir.Set.op(set));
    if (kind.operator() != null) return false;
    const target = ir.Set.target(set);
    if (target != .src) {
        if (kind != .default) return false;
        // A target assigned through, a call's write view, writes the
        // value the view reaches.
        const place_ty = if (assignedThrough(target)) (if (typeOf(ctx, target)) |t| sema.writtenThrough(ctx, t) else null) else typeOf(ctx, target);
        return if (place_ty) |t| owns(ctx, t) else true;
    }
    if (std.mem.eql(u8, srcText(ctx, target), "_")) return false;
    const sym = ctx.symbolOf(target) orelse return false;
    const s = ctx.symbols.items[sym];
    if (s.decl_pos == target.src.pos) return false;
    const ty = known(ctx, s.ty) orelse return false;
    if (!isPtrViewTy(ctx, ty)) return owns(ctx, ty);
    const pointee = sema.writtenThrough(ctx, ty);
    return ctx.writesThrough(set) and !isPtrViewTy(ctx, pointee) and owns(ctx, pointee);
}

/// How the value of `e`, which emit holds in a var or discards, drops
/// when nothing takes it (`sema.resourceKind` of its type), or null when
/// it owns nothing (`Var.drop`).
pub fn dropOf(ctx: *const SemContext, e: Sexp) ?sema.ResourceKind {
    return sema.resourceKind(ctx, typeOf(ctx, e) orelse return null);
}

/// Whether step `e` of an assignment can act when it runs: call, assign,
/// drop, leave, or end the program. Then the order of the steps and the
/// store is observable.
pub fn setActs(e: Sexp) bool {
    return contains(e, &([_]Tag{ .call, .builtin, .set, .drop, .panic } ++ leave_kinds));
}

/// Whether `return a, b` (`results`) evaluates its parts into storage
/// first, in their order (`argument` storage, one per part): a part that
/// can leave (`!`, `?`, a jump) comes after one that owns, which a
/// tuple Zig builds as it goes would lose on the way out. The storage
/// drops an owned part on that way, and the return takes each. Decided
/// once.
pub fn hoistsResults(ctx: *const SemContext, results: Sexp) bool {
    return leavesAfterOwned(ctx, false, ir.Results.values(results));
}

/// Whether step `e` of an assignment can leave before the store: `!`,
/// `?`, `return`, `break`, or `continue`.
fn setLeaves(e: Sexp) bool {
    return contains(e, &leave_kinds);
}

/// The nodes that leave the code around them: a body's exits and the
/// jumps (`rig.leavesBody`, `rig.isJump`).
pub const leave_kinds = rig.body_exit_kinds ++ rig.jump_kinds;

/// Whether the base of an assignment's path gives the same place however
/// late it is evaluated: a name, or a view of a name or of a field path
/// off one (`(!p)`, `(!p.q)`). A step that could change which place it
/// gives changes the name, which a live loan of the target forbids.
fn baseStays(e: Sexp) bool {
    var p = viewedPlace(e);
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
    if (sema.isReadOrWriteView(ctx, ty)) return ctx.writesThrough(set);
    return true;
}

/// Whether the fill `[n of x]` that `e` takes is built where its value
/// goes, never in a temporary on the stack first: a box's (`^[n of x]`),
/// in the box's allocation, or a binding's that declares or reassigns a
/// local array (`a = [n of x]`), in the local, by `@memset`. A
/// reassignment whose value is made first (`storesAfterValue`) is not.
pub fn fillsInPlace(ctx: *const SemContext, e: Sexp) bool {
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

/// Where the step of a `while` runs (docs/internals/INTERNALS.md, "Loops"), which
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

/// A step that reads a name an `as` part of the condition binds runs in
/// the bindings' scope, after the body; any other is the continue
/// expression, which runs after that scope ends. A name reads a binding
/// when it is the binding or a closure's capture of it (`sema.findUse`).
pub fn stepPoint(ctx: *const SemContext, loop: Sexp) StepPoint {
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

/// `e` without the view sigils around it.
pub fn viewedPlace(e: Sexp) Sexp {
    var x = e;
    while (x.isKind(.read) or x.isKind(.write)) x = ir.get(x, .operand);
    return x;
}

/// The value of a call argument: a `(kwarg name value)` stands for its value.
pub fn argValue(a: Sexp) Sexp {
    return if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
}

/// Whether a view reaches the value inside an optional on the way to its
/// view (the view table's `optional` row), which it captures by address.
pub fn viewsInsideOptional(view: sema.View) bool {
    if (view.callable() != null or view.has(.read_only)) return false;
    for (view.steps()) |step| switch (step) {
        .optional => return true,
        .elems, .text, .read_only => return false,
        else => {},
    };
    return false;
}

/// The value a block yields: its last statement, or a value that is
/// no block.
pub fn lastValue(e: Sexp) Sexp {
    if (!e.isKind(.block)) return e;
    const stmts = ir.Block.stmts(e);
    return if (stmts.len > 0) stmts[stmts.len - 1] else .nil;
}

// =============================================================================
// Held headers and units
// =============================================================================

/// Whether a parameter of type `ty` may hold its header: a write view of
/// a `String`, or of a `List[T]` with no inline room, viewed by pointer.
pub fn holdsHeaderType(ctx: *const SemContext, ty: TypeId) bool {
    const inner = switch (ctx.types.get(ty)) {
        .write_view => |inner| inner,
        else => return false,
    };
    if (!sema.viewHeldAsPointer(ctx, ty) or sema.containsTypeVar(ctx, inner)) return false;
    if (inner == ctx.types.string_id) return true;
    if (sema.listElem(ctx, inner) == null) return false;
    return switch (ctx.types.get(inner)) {
        .parameterized_nominal => |pn| pn.inline_len == 0,
        else => false,
    };
}

pub const Within = enum {
    /// Inside a `while` or `for`.
    loop,
    /// Inside a task's call, a closure, or a `raw` block.
    escape,
};

/// Whether `e` names `sym` within a node of the kind `within` asks for.
pub fn usedIn(ctx: *const SemContext, e: Sexp, sym: SymbolId, within: Within) bool {
    if (e == .src) return false;
    if (e != .list) return false;
    const inside = switch (within) {
        .loop => e.isKind(.@"while") or e.isKind(.@"for"),
        .escape => e.isKind(.lambda) or e.isKind(.raw_block) or (e.isKind(.call) and ir.get(e, .task) != .nil),
    };
    if (inside) return namesSym(ctx, e, sym);
    // A closure's body is its own: a loop in it is not the function's.
    if (within == .loop and e.isKind(.lambda)) return false;
    for (e.items()) |c| if (usedIn(ctx, c, sym, within)) return true;
    return false;
}

/// Whether `e` names `sym` anywhere, a closure's capture of it included.
fn namesSym(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    if (e == .src) {
        const s = ctx.symbolOf(e) orelse return false;
        return s == sym or (ctx.symbols.items[s].kind == .capture and ctx.symbols.items[s].origin == sym);
    }
    if (e != .list) return false;
    for (e.items()) |c| if (namesSym(ctx, c, sym)) return true;
    return false;
}

/// Whether `e` holds a node of `kind`.
pub fn containsKind(e: Sexp, kind: Tag) bool {
    if (e != .list) return false;
    if (e.isKind(kind)) return true;
    for (e.items()) |c| if (containsKind(c, kind)) return true;
    return false;
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

/// How binding `sym` drops its value: `sema.resourceKind` of its type
/// for a parameter, local, or capture, or null for one that owns
/// nothing to drop. Emit gives such a binding `var` storage and a drop
/// guard of this kind.
pub fn bindingDrop(ctx: *const SemContext, sym: SymbolId) ?sema.ResourceKind {
    const s = ctx.symbols.items[sym];
    return switch (s.kind) {
        .param, .local, .capture => if (known(ctx, s.ty)) |t| sema.resourceKind(ctx, t) else null,
        else => null,
    };
}

/// How a new binding holds its value (`bindHold`).
pub const BindHold = enum {
    /// The value, made or copied; a read view that copies
    /// (`sema.viewByValue`) is held as the value it views.
    value,
    /// A view held as a pointer (`viewHeldAsPointer`), however it was
    /// obtained.
    pointer,
    /// The address of the place `?x` or `!x` views.
    view,
};

/// How the binding assignment `set` declares holds its value, decided
/// once: a view of a place made by address holds the place's address, any
/// other view held as a pointer holds the pointer, and everything else
/// the value. A write view of slice elements, a callable view, and a view
/// of an API object are values however they are made.
pub fn bindHold(ctx: *const SemContext, set: Sexp) BindHold {
    const sym = ctx.symbolOf(ir.Set.target(set)) orelse return .value;
    const value = ir.Set.value(set);
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse
        return if (value.isKind(.read) or value.isKind(.write)) .view else .value;
    // A read view that copies (`sema.viewByValue`) is no address.
    const by_address = switch (ctx.types.get(ty)) {
        .read_view => sema.viewHeldAsPointer(ctx, ty) or genericReadView(ctx, ty) != null,
        .write_view => true,
        else => false,
    };
    if (by_address and (value.isKind(.read) or value.isKind(.write)) and
        sema.writeSliceElem(ctx, ty) == null and sema.callableFn(ctx, ty) == null and sema.objectView(ctx, ty) == null) return .view;
    return if (sema.viewHeldAsPointer(ctx, ty)) .pointer else .value;
}

/// The most bytes a task's record may take and stay in its maker's frame
/// (`task_record`): a larger one, such as one holding an array argument
/// by value, would grow every frame of a recursion that makes it.
pub const max_frame_task_bytes = 1024;

/// What a task's record holds besides its arguments and result, at most
/// (`sched.Record`: its `Job`'s header, its `tasks.Control`, and its
/// deadline), counted against `max_frame_task_bytes` and in its maker's
/// frame (`taskRecordBytes`). A unit test checks it against the runtime's.
pub const task_header_bytes = 512;

/// The task call of `stmt`, a statement of `block`, when its record stays
/// in a slot of `block`'s frame (`task_record`): a `frameTaskSite` whose
/// task never leaves its binding (`task_stays`), with a record of at most
/// `max_frame_task_bytes`. Asked by the plan (`Planner.frameTasks`) and by
/// the frame count, where the record counts (`accounts.count`).
pub fn taskRecordIn(ctx: *SemContext, stmt: Sexp, block: Sexp) !?Sexp {
    const task = frameTaskSite(ctx, stmt) orelse return null;
    if (!taskStays(ctx, stmt, block)) return null;
    const bytes = (try taskRecordBytes(ctx, task)) orelse return null;
    return if (bytes <= max_frame_task_bytes) task else null;
}

/// The bytes of the record of the task `call` makes: its header
/// (`task_header_bytes`), its self, its arguments, and its result; null
/// where a size is not known.
pub fn taskRecordBytes(ctx: *SemContext, task: Sexp) !?u128 {
    var bytes: u128 = task_header_bytes;
    const ty = typeOf(ctx, task) orelse return null;
    const result = sema.taskResult(ctx, ty) orelse return null;
    bytes += (try sema.minBytes(ctx, result)) orelse return null;
    if (selfOf(ctx, task)) |recv| {
        const rt_ = typeOf(ctx, recv) orelse return null;
        bytes += (try sema.minBytes(ctx, rt_)) orelse return null;
    }
    for (ir.Call.args(task)) |a| {
        const at = typeOf(ctx, argValue(a)) orelse return null;
        bytes += (try sema.minBytes(ctx, at)) orelse return null;
    }
    return bytes;
}

/// The task call of `stmt` if it is a site a task's record may stay in
/// its maker's frame at: an assignment, written `=`, that declares a fresh
/// name and whose whole value is a task call, `t = f(x)&`, not one through
/// an actor's handle, which the actor runs.
pub fn frameTaskSite(ctx: *const SemContext, stmt: Sexp) ?Sexp {
    if (!stmt.isKind(.set)) return null;
    // The value first: a task call is rare, and the name's lookup is not
    // free (the frame count asks of every statement).
    const value = ir.Set.value(stmt);
    if (!value.isKind(.call) or ir.Call.task(value) == .nil) return null;
    if (rig.bindingKindOf(ir.Set.op(stmt)) != .default) return null;
    const target = ir.Set.target(stmt);
    if (target != .src) return null;
    const sym = ctx.symbolOf(target) orelse return null;
    if (ctx.symbols.items[sym].decl_pos != target.src.pos) return null;
    if (ctx.isActorCall(value)) return null;
    return value;
}

/// Whether the task bound by `stmt`, a `frameTaskSite` in `block`, never
/// leaves its binding (`task_stays`), by a positive list of uses: every
/// later naming of the binding in the block is the task of `>t`, the self
/// of `<t.cancel()`, or a read view, `?t`, outside every closure. Its drop, which waits, then
/// runs before the block ends on every path. Any other naming, a move, a
/// `return`, a `Tasks` add, a stored field, a moving capture, or an
/// assignment, keeps the record on the heap.
fn taskStays(ctx: *const SemContext, stmt: Sexp, block: Sexp) bool {
    _ = frameTaskSite(ctx, stmt) orelse return false;
    const sym = ctx.symbolOf(ir.Set.target(stmt)) orelse return false;
    var after = false;
    for (rig.children(block)) |s| {
        if (s == .list and s.items().ptr == stmt.items().ptr) {
            after = true;
            continue;
        }
        if (after and !onlyStays(ctx, s, sym)) return false;
    }
    return after;
}

/// Whether every naming of `sym` within `e` is one that leaves the task
/// in its binding (`decideTaskStays`).
fn onlyStays(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    switch (e) {
        // A closure's capture of the binding is a symbol of its own.
        .src => return !namesSym(ctx, e, sym),
        .list => {},
        else => return true,
    }
    if (e.kind()) |kind| switch (kind) {
        // `?t`, a read view, and `?t.on_end()` through it.
        .read => if (isSym(ctx, ir.get(e, .operand), sym)) return true,
        // `>t` and `<t.cancel()`: the wait, and the cancel, which waits
        // for the end before it returns.
        .member => {
            const obj = ir.Member.object(e);
            if (obj.isKind(.move) and isSym(ctx, ir.Move.operand(obj), sym)) {
                const name = ir.Member.name(e);
                return rig.isWaitMember(e) or (name == .src and std.mem.eql(u8, srcText(ctx, name), "cancel"));
            }
        },
        else => {},
    };
    for (if (e.kind() == null) e.items() else rig.children(e)) |c| if (!onlyStays(ctx, c, sym)) return false;
    return true;
}

fn isSym(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    return e == .src and ctx.symbolOf(e) == sym;
}

/// The call a compound assignment `x op= v` lowers to, which assigns the
/// call's result (`compoundCall`): its place is found once.
pub const CompoundCall = enum {
    /// A mask's `&`, `|`, and `^` (`rig.maskAnd`, `rig.Mask`).
    mask,
    /// A vector's lane shifts (`rig.vecShl`, `rig.vecShlWrap`,
    /// `rig.vecShr`), which take the amount as it is.
    lane_shift,
    /// A vector's saturating `+|` and `-|` (`rig.vecAddSat`,
    /// `rig.vecSubSat`).
    lane_saturate,
    /// `rig.rem`, for `%`.
    rem,
    /// `@divTrunc`, an integer `/`.
    div,
    /// `rig.div`, a `/` of a type parameter's values.
    div_generic,
    /// `@shlExact`, a scalar `<<`.
    shl,
    /// A checked `+`, `-`, or `*` on integer lanes (`laneChecked`).
    lane_checked,
};

/// The call compound assignment `set` lowers to, which assigns its
/// result, or null for Zig's own compound assignment; decided once.
pub fn compoundCall(ctx: *const SemContext, set: Sexp) ?CompoundCall {
    const op = rig.bindingKindOf(ir.Set.op(set)).operator() orelse return null;
    const target = ir.Set.target(set);
    const lanes: ?sema.SimdType = if (typeOf(ctx, target)) |t| switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .simd => |v| v,
        else => null,
    } else null;
    if (lanes) |v| switch (op) {
        .@"&", .@"|", .@"^" => if (v.elem == ctx.types.bool_id) return .mask,
        .@"<<", .@"<<%", .@">>" => return .lane_shift,
        .@"+|", .@"-|" => return .lane_saturate,
        else => {},
    };
    return switch (op) {
        .@"%" => .rem,
        .@"/" => {
            var call: CompoundCall = .div;
            for ([2]Sexp{ target, ir.Set.value(set) }) |e| {
                const ty = typeOf(ctx, e) orelse continue;
                switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
                    .float, .float_literal => return null,
                    .type_var => call = .div_generic,
                    else => {},
                }
            }
            return call;
        },
        .@"<<" => .shl,
        .@"+", .@"-", .@"*" => if (laneChecked(ctx, set)) .lane_checked else null,
        else => null,
    };
}

fn isListTy(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == ctx.builtins.list,
        else => false,
    };
}

/// A Cell holding a List, reached by value, view, or shared handle.
pub fn isCellListTy(ctx: *const SemContext, ty: TypeId) bool {
    const cell = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.cell and pn.args.len == 1) pn.args[0] else return false,
        else => return false,
    };
    return isListTy(ctx, cell);
}

test "a task's record holds at most `task_header_bytes` besides its arguments and result" {
    const tasks = @import("tasks.zig");
    const F = struct {
        fn f() void {}
    };
    const Frame = tasks.Task(void).Frame(false, F.f, @TypeOf(.{}));
    try std.testing.expect(@sizeOf(Frame) <= task_header_bytes);
}
