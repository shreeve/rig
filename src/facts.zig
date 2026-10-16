//! What emit may know about a checked module: its recorded facts, read-only.
//!
//! Emit lowers a module the checkers have accepted, so every decision that
//! affects ownership or memory (copy or address, slot or temporary, the
//! order things run in, where a drop goes, `*T` or `*const T`, view or
//! value) was made before it runs, by sema, typecheck, or the storage plan,
//! and the ownership checker walked what they decided. Emit reads those
//! decisions here and decides none of them again (AGENTS.md, "One
//! classifier per fact" and "The checker checks exactly what is emitted").
//!
//! `src/emit.zig` imports this file and not `sema.zig`, `storage.zig`, or
//! `resolve.zig`, so the classifiers there are out of its reach: a call of
//! `sema.copies` or `storage.matchesInPlace` from emit does not compile. A
//! unit test below fails if emit imports anything else. What `Facts` offers
//! is of three kinds:
//!
//! - **Node facts**: what the checkers recorded about a node, read from the
//!   facts table (docs/INTERNALS.md, "The facts table") and the storage
//!   facts (`storageOf`, "Storage facts"). Each answers for the node it is
//!   asked about and is decided once, where it is recorded.
//! - **Types**: the type table, the symbols, and the questions about a type
//!   whose answer is how values of that type are spelled in Zig (whether a
//!   view is a pointer, whether a pointer to it is mutable, what `+x`
//!   lowers to): one answer per type, read the same way by every pass.
//! - **Pending** (`Facts.pending`): the node decisions emit still makes
//!   itself, with the classifiers the checkers also call. It is the
//!   allowlist this file's test counts: each entry is a decision that
//!   should become a recorded node fact, and the list only shrinks.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");
const resolve = @import("resolve.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;

pub const TypeId = sema.TypeId;
pub const SymbolId = sema.SymbolId;

/// How a read binding of a write view is bound (`Facts.readsThroughWrite`).
pub const ThroughWrite = enum { pointer, value };
pub const Wide = sema.Wide;
pub const Type = sema.Type;
pub const TypeStore = sema.TypeStore;
pub const Symbol = sema.Symbol;
pub const Field = sema.Field;
pub const FunctionType = sema.FunctionType;
pub const ParamNominal = sema.ParamNominal;
pub const Lend = sema.Lend;
pub const LendStep = sema.LendStep;
pub const StringCall = sema.StringCall;
pub const ElemCall = sema.ElemCall;
pub const Proven = sema.Proven;
pub const UnitKind = rig.UnitKind;
pub const NodeKey = sema.NodeKey;

/// Whether this build of the compiler runs its own consistency checks
/// (`zig build -Dself-check`; on in every debug build).
pub const self_check = @import("build_options").self_check;

/// Emit asserts that it writes each node inside the unit that holds it
/// (`Emitter.inUnit`) in every self-checking build.
pub const check_units = self_check;

pub const UnitEvent = sema.UnitEvent;
pub const GenericCall = sema.GenericCall;
pub const Use = sema.Use;
pub const Header = sema.Header;
pub const Storage = sema.Storage;
pub const StorageKind = sema.StorageKind;
pub const StorageBy = sema.StorageBy;
pub const Answer = sema.Answer;
pub const Clone = sema.Clone;
pub const MethodReceiver = sema.MethodReceiver;
pub const Upgrade = sema.Upgrade;
pub const Lift = sema.Lift;
pub const TypedInt = sema.TypedInt;
pub const ValueParts = sema.ValueParts;
pub const ArgSlot = sema.ArgSlot;
pub const Instance = sema.Instance;
pub const HandsKind = sema.Hands.Kind;
pub const LeafStep = storage.LeafStep;
pub const MatchMode = storage.MatchMode;
pub const ReceiverHold = storage.ReceiverHold;
pub const ArgumentHold = storage.ArgumentHold;
pub const SetOrder = storage.SetOrder;
pub const SetStep = storage.SetStep;
pub const StepPoint = storage.StepPoint;
pub const JumpDest = sema.JumpDest;
pub const CallTarget = sema.CallTarget;

pub const type_invalid = sema.type_invalid;
pub const type_param_mark = sema.type_param_mark;

/// The recorded facts of one checked module.
pub const Facts = struct {
    /// The module's `SemContext`, which only this file reads.
    sema_context: *const anyopaque,
    types: *const TypeStore,
    symbols: *const std.ArrayList(Symbol),
    source: []const u8,
    /// The module's name, as other modules `use` it.
    name: []const u8,
    /// The module's emitted file, which other modules `@import`.
    zig_file: []const u8,
    /// The program's root module.
    is_root: bool,
    cell_sym_id: SymbolId,
    list_sym_id: SymbolId,
    signal_sym_id: SymbolId,
    box_sym_id: SymbolId,
    endian_sym_id: SymbolId,
    arch_sym_id: SymbolId,
    /// The decisions emit still makes itself (the allowlist).
    pending: Pending,

    pub fn of(ctx: *const SemContext) Facts {
        return .{
            .sema_context = ctx,
            .types = &ctx.types,
            .symbols = &ctx.symbols,
            .source = ctx.source,
            .name = ctx.name,
            .zig_file = ctx.zig_file,
            .is_root = ctx.is_root,
            .cell_sym_id = ctx.cell_sym_id,
            .list_sym_id = ctx.list_sym_id,
            .signal_sym_id = ctx.signal_sym_id,
            .box_sym_id = ctx.box_sym_id,
            .endian_sym_id = ctx.endian_sym_id,
            .arch_sym_id = ctx.arch_sym_id,
            .pending = .{ .sema_context = ctx },
        };
    }

    fn c(f: Facts) *const SemContext {
        return @ptrCast(@alignCast(f.sema_context));
    }

    /// Whether `f` and `g` are the facts of the same module.
    pub fn same(f: Facts, g: Facts) bool {
        return f.sema_context == g.sema_context;
    }

    // -------------------------------------------------------------------
    // Modules
    // -------------------------------------------------------------------

    /// Another module of the program, by id.
    pub fn foreign(f: Facts, module_id: u32) ?Facts {
        return of(f.c().foreign_semas.get(module_id) orelse return null);
    }

    /// The module whose source is `source`: this one, or one it reaches.
    pub fn moduleWithSource(f: Facts, source: []const u8) ?Facts {
        if (source.ptr == f.source.ptr) return f;
        var it = f.c().foreign_semas.valueIterator();
        while (it.next()) |ctx| if (ctx.*.source.ptr == source.ptr) return of(ctx.*);
        return null;
    }

    /// The module a `use`'s symbol names.
    pub fn moduleOf(f: Facts, sym: SymbolId) ?u32 {
        return f.c().module_refs.get(sym);
    }

    pub const Import = struct { local_name: []const u8, module_id: u32, facts: Facts };

    pub fn importCount(f: Facts) usize {
        return f.c().imports.len;
    }

    /// The module's `i`th `use`.
    pub fn importAt(f: Facts, i: usize) Import {
        const imp = f.c().imports[i];
        return .{ .local_name = imp.local_name, .module_id = imp.module_id, .facts = of(imp.sema) };
    }

    // -------------------------------------------------------------------
    // Node facts
    // -------------------------------------------------------------------

    pub fn symbolOf(f: Facts, node: Sexp) ?SymbolId {
        return f.c().symbolOf(node);
    }
    pub fn typeOf(f: Facts, node: Sexp) ?TypeId {
        return f.c().typeOf(node);
    }
    pub fn startOf(f: Facts, node: Sexp) u32 {
        return f.c().startOf(node);
    }
    /// Whether the function or method whose name leaf is `name` is
    /// emitted `inline` (`inlining.decide`).
    pub fn isInlined(f: Facts, name: Sexp) bool {
        return f.c().inlined.contains(f.c().startOf(name));
    }
    /// Whether the function or method whose name leaf is `name` has a
    /// large frame, emitted `noinline` (`sema.SemContext.large_frames`).
    pub fn isLargeFrame(f: Facts, name: Sexp) bool {
        return f.c().large_frames.contains(f.c().startOf(name));
    }
    /// Whether the closure or `drop` body `node`, a frame owner of its
    /// own (`sema.FrameOwner`), has a large frame, emitted `noinline`.
    pub fn isLargeOwner(f: Facts, node: Sexp) bool {
        return f.c().large_frames.contains(f.c().startOf(node));
    }
    /// The marker of the `fun` or `sub` `node`: `rarely` starts its body
    /// with the cold hint, and `called` emits it `noinline fn`.
    pub fn markerOf(f: Facts, node: Sexp) rig.Marker {
        _ = f;
        return rig.markerOf(node);
    }
    /// Whether the call may reach a function emitted `inline`, whose
    /// result Zig could know at compile time.
    pub fn callsInlined(f: Facts, call: Sexp) bool {
        return call == .list and f.c().inlined_calls.contains(call.list.id);
    }
    pub fn calleeOf(f: Facts, call: Sexp) Sexp {
        return f.c().calleeOf(call);
    }
    /// What a call reaches, as typecheck resolved it (`SemContext.callTargetOf`).
    pub fn callTargetOf(f: Facts, call: Sexp) ?CallTarget {
        return f.c().callTargetOf(call);
    }
    /// Whether `call` calls a Rig function or method: a function of this
    /// module or another, or a method a module declares on its type, not
    /// a built-in's. For emit's check that typecheck resolved each such
    /// call it writes (`Emitter.checkCallTarget`).
    pub fn callsRigFunction(f: Facts, call: Sexp) bool {
        const ctx = f.c();
        const callee = ctx.calleeOf(call);
        if (callee == .src) {
            const id = ctx.symbolOf(callee) orelse return false;
            return ctx.symbols.items[id].kind == .function;
        }
        if (!callee.isKind(.member)) return false;
        if (storage.moduleMemberSym(ctx, callee)) |sym| return sym.kind == .function;
        const obj = ir.Member.object(callee);
        const name_leaf = ir.Member.name(callee);
        if (name_leaf != .src) return false;
        const name = rig.leafText(ctx.source, name_leaf.src);
        // A value's type, or the type a type's name stands for.
        const decl = if (ctx.typeOf(obj)) |t| sema.nominalDecl(ctx, t) else null;
        const sym: sema.Symbol = if (decl) |d| d.symbol() else blk: {
            const id = ctx.symbolOf(obj) orelse return false;
            if (!storage.isTypeSym(ctx, id)) return false;
            break :blk ctx.symbols.items[id];
        };
        if (sym.decl_pos == sema.builtin_decl_pos) return false;
        for (sym.fields orelse return false) |field| {
            if (field.is_method and !field.is_drop_method and std.mem.eql(u8, field.name, name)) return true;
        }
        return false;
    }
    pub fn ctArgsOf(f: Facts, call: Sexp) []const Sexp {
        return f.c().ctArgsOf(call);
    }
    pub fn callSlotsOf(f: Facts, call: Sexp) ?[]const ArgSlot {
        return f.c().callSlotsOf(call);
    }
    pub fn instanceOf(f: Facts, node: Sexp) ?Instance {
        return f.c().instanceOf(node);
    }
    pub fn genericCallOf(f: Facts, node: Sexp) ?GenericCall {
        return f.c().genericCallOf(node);
    }
    pub fn elemCallOf(f: Facts, callee: Sexp) ?ElemCall {
        return f.c().elemCallOf(callee);
    }
    pub fn splatOf(f: Facts, node: Sexp) ?TypeId {
        return f.c().splatOf(node);
    }
    /// The root of the innermost unit holding `node` (`rig.eachUnit`),
    /// which emit asserts it writes the node inside.
    pub fn unitOf(f: Facts, node: Sexp) ?sema.NodeKey {
        return f.c().unitOf(node);
    }
    /// The kind of the unit `node` is the root of, or null.
    pub fn unitRootKind(f: Facts, node: Sexp) ?UnitKind {
        return f.c().unitRootKind(node);
    }
    /// Which of the node's tests are known to pass (`src/proofs.zig`):
    /// emit omits those, and a debug build makes them as assertions.
    pub fn provenOf(f: Facts, node: Sexp) Proven {
        return f.c().provenOf(node);
    }
    pub fn callableOf(f: Facts, node: Sexp) ?TypeId {
        return f.c().callableOf(node);
    }
    pub fn lendOf(f: Facts, node: Sexp) ?Lend {
        return f.c().lendOf(node);
    }
    pub fn lendsTempArray(f: Facts, node: Sexp) bool {
        return f.c().lendsTempArray(node);
    }
    pub fn readsThrough(f: Facts, node: Sexp) bool {
        return f.c().readsThrough(node);
    }
    pub fn copiesPayload(f: Facts, node: Sexp) bool {
        return f.c().copiesPayload(node);
    }
    pub fn readsInPlace(f: Facts, node: Sexp) bool {
        return f.c().readsInPlace(node);
    }
    pub fn writesTemp(f: Facts, node: Sexp) bool {
        return f.c().writesTemp(node);
    }
    pub fn dropsTemp(f: Facts, node: Sexp) bool {
        return f.c().dropsTemp(node);
    }
    pub fn useOf(f: Facts, node: Sexp) ?Use {
        return f.c().useOf(node);
    }
    /// The optional `node`'s value becomes where it goes: `none`, or a
    /// `T` where a `T?` goes (`SemContext.recordLift`).
    pub fn liftOf(f: Facts, node: Sexp) ?Lift {
        return f.c().liftOf(node);
    }
    pub fn takes(f: Facts, node: Sexp) bool {
        return f.c().takes(node);
    }
    pub fn upgradeOf(f: Facts, node: Sexp) ?Upgrade {
        return f.c().upgradeOf(node);
    }
    pub fn repoints(f: Facts, node: Sexp) bool {
        return f.c().repoints(node);
    }
    pub fn isErrorMember(f: Facts, node: Sexp) bool {
        return f.c().isErrorMember(node);
    }
    pub fn isEnumText(f: Facts, node: Sexp) bool {
        return f.c().isEnumText(node);
    }
    /// Whether the program calls `from_text` on plain enum `sym` of this
    /// module, which then emits its table of names.
    pub fn hasTextTable(f: Facts, sym: SymbolId) bool {
        return f.c().hasTextTable(sym);
    }
    pub fn headerOf(f: Facts, node: Sexp) ?Header {
        return f.c().headerOf(node);
    }
    pub fn heldBaseOf(f: Facts, node: Sexp) ?Sexp {
        return f.c().heldBaseOf(node);
    }
    /// The bindings of a variant pattern, by field (a by-name pattern's
    /// in the order of the payload's fields).
    /// The type of the field payload binding `b` binds, at the matched
    /// instance.
    pub fn payloadFieldOf(f: Facts, b: Sexp) ?TypeId {
        return f.c().payloadFieldOf(b);
    }
    pub fn payloadBindings(f: Facts, pattern: Sexp) ?[]const Sexp {
        return f.c().payloadBindings(pattern);
    }
    pub fn copiesHeader(f: Facts, node: Sexp) bool {
        return f.c().copiesHeader(node);
    }
    pub fn consumes(f: Facts, sym: SymbolId) bool {
        return f.c().consumes(sym);
    }
    pub fn storageOf(f: Facts, node: Sexp, kind: StorageKind) ?Storage {
        return f.c().storageOf(node, kind);
    }
    /// How the walk that reaches a value by address reaches `e`
    /// (`storage.leafStep`, a recorded decision); null when no checker
    /// walked it.
    pub fn leafStep(f: Facts, e: Sexp) ?LeafStep {
        return storage.decided(f.c(), e, .leaf_step);
    }
    /// Whether `e` is reached where its leaves are (`storage.reachesLeaf`,
    /// a recorded decision); null when it was never decided.
    pub fn reachesLeaf(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .reaches_leaf);
    }
    /// The decisions about a `match` the checkers made (`storage`): null
    /// when none did.
    pub fn matchMode(f: Facts, match: Sexp) ?MatchMode {
        return storage.decided(f.c(), match, .match_mode);
    }
    pub fn matchesInPlace(f: Facts, match: Sexp) ?bool {
        return storage.decided(f.c(), match, .matches_in_place);
    }
    pub fn matchRereads(f: Facts, match: Sexp) ?bool {
        return storage.decided(f.c(), match, .match_rereads);
    }
    pub fn matchBlock(f: Facts, match: Sexp) ?bool {
        return storage.decided(f.c(), match, .match_block);
    }
    /// How `__rig_subject` holds the subject (null inside: not at all).
    pub fn subjectHold(f: Facts, match: Sexp) ??StorageBy {
        return storage.decided(f.c(), match, .subject_hold);
    }
    pub fn holdsView(f: Facts, match: Sexp) ?bool {
        return storage.decided(f.c(), match, .holds_view);
    }
    /// Whether a read match's catch-all binding is captured by address.
    pub fn catchAllCaptured(f: Facts, pattern: Sexp) ?bool {
        return storage.decided(f.c(), pattern, .catch_all_by_address);
    }
    /// Whether `if … as` binds the bytes of the String a write view in the
    /// optional points at.
    pub fn optionalBindsStringBytes(f: Facts, cond: Sexp) bool {
        return storage.optionalBindsStringBytes(f.c(), cond);
    }
    /// Whether a read `for` binds the bytes of each String element.
    pub fn loopBindsStringBytes(f: Facts, loop: Sexp) bool {
        return storage.loopBindsStringBytes(f.c(), loop);
    }
    /// Whether a payload binding points at the field it binds.
    pub fn bindsByAddress(f: Facts, b: Sexp) ?bool {
        return storage.decided(f.c(), b, .payload_by_address);
    }
    /// Whether a write may go through binding `sym` (`.write`), only
    /// a read (`.read`), or it is no view (`SemContext.bindingAccess`).
    pub fn bindingAccess(f: Facts, sym: SymbolId) ?sema.Access {
        return f.c().bindingAccess(sym);
    }
    /// How binding `sym`, which binds a value of type `reached`, reads
    /// through a write view: `reached` is one, and the binding only reads
    /// (`bindingAccess`), so it is bound as the read view of what that
    /// write view views. `.pointer`: the write view itself (a `?P`, or a
    /// `[]T` of a `![]T`); `.value`: the value it points at, copied out, as
    /// a `?T` of a scalar or a view is a copy (`sema.lendByValue`). Null
    /// for any other binding.
    pub fn readsThroughWrite(f: Facts, sym: SymbolId, reached: TypeId) ?ThroughWrite {
        const ctx = f.c();
        if (ctx.bindingAccess(sym) != .read) return null;
        return switch (ctx.types.get(reached)) {
            .write_view => |inner| if (ctx.types.get(inner) != .slice and sema.lendByValue(ctx, inner)) .value else .pointer,
            else => null,
        };
    }
    /// Whether a `print`, `String(...)`, or `add` argument is read by address
    /// (`storage.printsByAddress`).
    pub fn printsByAddress(f: Facts, a: Sexp) ?bool {
        return storage.decided(f.c(), a, .print_by_address);
    }
    /// Whether a test against `none` or a `.variant` drops its operand
    /// (`storage.dropsWhenTested`).
    pub fn dropsWhenTested(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .drops_when_tested);
    }
    /// What an expression hands over (`sema.handsOver`), as the plan
    /// decided it for every expression.
    pub fn handsOver(f: Facts, e: Sexp) ?HandsKind {
        return storage.decided(f.c(), e, .hands);
    }
    /// Whether `e` is read from storage, not made for its context: a
    /// place, a part of a value made here, or a lend (`Hands.hasStorage`).
    pub fn hasStorage(f: Facts, e: Sexp) ?bool {
        const kind = f.handsOver(e) orelse return null;
        return (sema.Hands{ .kind = kind }).hasStorage();
    }
    /// Whether a header's block yields the address of the place its
    /// subject reaches (`storage.headerPoints`).
    pub fn headerPoints(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .header_points);
    }
    /// Whether an `as` binding views the value inside the optional
    /// (`storage.viewsOptionalValue`).
    pub fn viewsOptionalValue(f: Facts, value: Sexp) ?bool {
        return storage.decided(f.c(), value, .views_optional_value);
    }
    /// The decisions about a call the plan made (`storage`): whether it
    /// evaluates its arguments first, how it holds its receiver and each
    /// argument, whether it consumes a temporary receiver, and whether an
    /// argument, an assigned value, or an index is pure.
    pub fn hoistsArgs(f: Facts, call: Sexp) ?bool {
        return storage.decided(f.c(), call, .hoists_args);
    }
    /// Whether the fill a box or a binding takes is built where its value
    /// goes (`storage.fillsInPlace`).
    pub fn fillsInPlace(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .fills_in_place);
    }
    /// How an assignment runs: which of its steps it evaluates into
    /// storage in their turn (`storage.setOrder`).
    pub fn setOrder(f: Facts, set: Sexp) ?SetOrder {
        return storage.decided(f.c(), set, .set_order);
    }
    /// Where the step of a `while` runs (`storage.stepPoint`).
    pub fn stepPoint(f: Facts, loop: Sexp) ?StepPoint {
        return storage.decided(f.c(), loop, .step_point);
    }
    /// Where a `break` or `continue` goes, as the type checker resolved it
    /// (`sema.JumpDest`).
    pub fn jumpDest(f: Facts, jump: Sexp) ?JumpDest {
        return f.c().jumpDestOf(jump);
    }
    pub fn receiverHold(f: Facts, call: Sexp) ??ReceiverHold {
        return storage.decided(f.c(), call, .receiver_hold);
    }
    pub fn consumesReceiver(f: Facts, call: Sexp) ?bool {
        return storage.decided(f.c(), call, .consumes_receiver);
    }
    pub fn argumentHold(f: Facts, v: Sexp) ?ArgumentHold {
        return storage.decided(f.c(), v, .argument_hold);
    }
    /// Whether arithmetic on vector lanes is made by a checking runtime
    /// helper (`storage.laneChecked`).
    pub fn laneChecked(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .lane_checked);
    }
    pub fn isPureArg(f: Facts, e: Sexp) ?bool {
        return storage.decided(f.c(), e, .pure_arg);
    }
    /// Whether a `for` consumes its source (`storage.forConsumes`).
    pub fn forConsumes(f: Facts, loop: Sexp) ?bool {
        return storage.decided(f.c(), loop, .for_consumes);
    }
    /// Whether a binding is an integer constant the module folds.
    pub fn isConstInt(f: Facts, sym: SymbolId) bool {
        return f.c().const_ints.contains(sym);
    }
    /// Whether a symbol is declared at module level.
    pub fn isModuleLevel(f: Facts, sym: SymbolId) bool {
        return f.c().symbols.items[sym].scope == sema.module_scope;
    }
    /// Whether a local `k =! n` stands for a compile-time parameter.
    pub fn isCtLocal(f: Facts, sym: SymbolId) bool {
        return f.c().ct_locals.contains(sym);
    }
    /// The statement temporaries `stmt` makes, in the order they are made
    /// (the recorded `dropsTemp` facts).
    pub fn stmtTemps(f: Facts, a: std.mem.Allocator, stmt: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
        return sema.stmtTemps(f.c(), a, stmt, out);
    }
    pub fn firstStmtTemp(f: Facts, stmt: Sexp) ?Sexp {
        return sema.firstStmtTemp(f.c(), stmt);
    }
    /// The value of an integer constant expression.
    pub fn constIntOf(f: Facts, e: Sexp) ?Wide {
        return sema.constIntOf(f.c(), e);
    }
    /// `Int.max` and the like.
    pub fn intLimit(f: Facts, e: Sexp) ?TypedInt {
        return sema.intLimit(f.c(), e);
    }
    /// The built-in String operation `call` is.
    pub fn stringCall(f: Facts, call: Sexp) ?StringCall {
        return storage.stringCall(f.c(), call);
    }
    /// The integer type of a `t.push[T, e](v)` call.
    pub fn stringNumOf(f: Facts, callee: Sexp) ?TypeId {
        return f.c().stringNumOf(callee);
    }
    pub fn isPrintCall(f: Facts, call: Sexp) bool {
        return storage.isPrintCall(f.c(), call);
    }
    pub fn isNoneLeaf(f: Facts, e: Sexp) bool {
        return storage.isNoneLeaf(f.c(), e);
    }
    /// Whether the object of a call's callee names a type or a module.
    pub fn isTypeCallee(f: Facts, obj: Sexp) bool {
        return storage.isTypeCallee(f.c(), obj);
    }
    pub fn moduleMemberSym(f: Facts, obj: Sexp) ?Symbol {
        return storage.moduleMemberSym(f.c(), obj);
    }
    pub fn isTypeSym(f: Facts, id: SymbolId) bool {
        return storage.isTypeSym(f.c(), id);
    }
    /// The receiver of `value.method(...)`, as the call's recorded
    /// parameters say.
    pub fn receiverOf(f: Facts, call: Sexp) ?Sexp {
        return storage.receiverOf(f.c(), call);
    }
    /// Whether the method of `value.method(...)` takes `!self`.
    pub fn receiverWrites(f: Facts, call: Sexp) bool {
        return storage.receiverWrites(f.c(), call);
    }
    /// The run-time parameters a call's arguments fill.
    pub fn argParams(f: Facts, call: Sexp) []const TypeId {
        return storage.argParams(f.c(), call);
    }
    /// A closure literal lent as a callable view.
    pub fn lentLiteral(f: Facts, e: Sexp) bool {
        return storage.lentLiteral(f.c(), e);
    }
    pub fn lambdaYields(f: Facts, lambda: Sexp) bool {
        return storage.lambdaYields(f.c(), lambda);
    }
    /// The enum a `match` switches on.
    pub fn matchedType(f: Facts, match: Sexp) ?TypeId {
        return storage.matchedType(f.c(), match);
    }
    /// The built-in types the program's names table spells.
    pub fn builtinTypes(f: Facts, a: std.mem.Allocator) ![]const Type {
        return resolve.builtinTypes(f.c(), a);
    }

    // -------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------

    pub fn payloadViewed(f: Facts, ty: TypeId) ?TypeId {
        return sema.payloadViewed(f.c(), ty);
    }
    pub fn unwrapViews(f: Facts, ty: TypeId) TypeId {
        return sema.unwrapViews(f.c(), ty);
    }
    pub fn writtenThrough(f: Facts, ty: TypeId) TypeId {
        return sema.writtenThrough(f.c(), ty);
    }
    pub fn unwrapReadAccess(f: Facts, ty: TypeId) TypeId {
        return sema.unwrapReadAccess(f.c(), ty);
    }
    pub fn unwrapAccess(f: Facts, ty: TypeId) TypeId {
        return sema.unwrapAccess(f.c(), ty);
    }
    pub fn boxedType(f: Facts, ty: TypeId) ?TypeId {
        return sema.boxedType(f.c(), ty);
    }
    pub fn boxedNominal(f: Facts, ty: TypeId) ?TypeId {
        return sema.boxedNominal(f.c(), ty);
    }
    pub fn callableFn(f: Facts, ty: TypeId) ?FunctionType {
        return sema.callableFn(f.c(), ty);
    }
    pub fn callableFnTy(f: Facts, ty: TypeId) ?TypeId {
        return sema.callableFnTy(f.c(), ty);
    }
    pub fn ownedClosureFn(f: Facts, ty: TypeId) ?FunctionType {
        return sema.ownedClosureFn(f.c(), ty);
    }
    /// The function type of a function, closure, or callable view.
    pub fn fnType(f: Facts, ty: ?TypeId) ?FunctionType {
        return storage.fnType(f.c(), ty);
    }
    pub fn writeSliceElem(f: Facts, ty: TypeId) ?TypeId {
        return sema.writeSliceElem(f.c(), ty);
    }
    pub fn isReadOrWriteView(f: Facts, ty: TypeId) bool {
        return sema.isReadOrWriteView(f.c(), ty);
    }
    pub fn isErrorSet(f: Facts, ty: TypeId) bool {
        return sema.isErrorSet(f.c(), ty);
    }
    pub fn isErrorValue(f: Facts, ty: TypeId) bool {
        return sema.isErrorValue(f.c(), ty);
    }
    pub fn hoistsResults(f: Facts, results: Sexp) bool {
        return storage.hoistsResults(f.c(), results);
    }
    pub fn resultsOf(f: Facts, ty: TypeId) ?[]const TypeId {
        return sema.resultsOf(f.c(), ty);
    }
    pub fn isNumeric(f: Facts, ty: TypeId) bool {
        return sema.isNumeric(f.c(), ty);
    }
    pub fn isPlainEnum(f: Facts, ty: TypeId) bool {
        return sema.isPlainEnum(f.c(), ty);
    }
    pub fn containsTypeVar(f: Facts, ty: TypeId) bool {
        return sema.containsTypeVar(f.c(), ty);
    }
    pub fn isBuiltinEnum(f: Facts, sym: SymbolId) bool {
        return sema.isBuiltinEnum(f.c(), sym);
    }
    pub fn isBuiltinGeneric(f: Facts, sym: SymbolId) bool {
        return sema.isBuiltinGeneric(f.c(), sym);
    }
    pub fn lookupDataFieldConst(f: Facts, receiver_ty: TypeId, name: []const u8) ?Field {
        return sema.lookupDataFieldConst(f.c(), receiver_ty, name);
    }
    pub fn methodReceiver(f: Facts, receiver_ty: TypeId, name: []const u8) ?MethodReceiver {
        return sema.methodReceiver(f.c(), receiver_ty, name);
    }
    /// The payload fields of variant `vname` of an enum type.
    pub fn variantPayload(f: Facts, enum_ty: TypeId, vname: []const u8) ?[]const Field {
        return storage.variantPayload(f.c(), enum_ty, vname);
    }

    /// The declaration behind a (possibly viewed) nominal type, with the
    /// facts of the module that declares it.
    pub const Nominal = struct {
        facts: Facts,
        sym: SymbolId,
        module_id: ?u32,

        pub fn symbol(n: Nominal) Symbol {
            return n.facts.symbols.items[n.sym];
        }
    };

    pub fn nominalDecl(f: Facts, ty: TypeId) ?Nominal {
        const d = sema.nominalDecl(f.c(), ty) orelse return null;
        return .{ .facts = of(d.ctx), .sym = d.sym, .module_id = d.module_id };
    }

    pub fn formatTypeValue(f: Facts, a: std.mem.Allocator, ty: Type) std.mem.Allocator.Error![]const u8 {
        return sema.formatTypeValue(f.c(), a, ty);
    }
    pub fn formatTypeMarked(f: Facts, a: std.mem.Allocator, ty: TypeId) std.mem.Allocator.Error![]const u8 {
        return sema.formatTypeMarked(f.c(), a, ty);
    }
    pub fn formatGenericSelfMarked(f: Facts, a: std.mem.Allocator, sym: SymbolId) std.mem.Allocator.Error![]const u8 {
        return sema.formatGenericSelfMarked(f.c(), a, sym);
    }

    // How a type is held in Zig: one answer per type, which every pass
    // reads the same way (docs/INTERNALS.md, Emit, "Views").

    /// Whether a view of this type is a Zig pointer (`sema.viewHeldAsPointer`).
    pub fn viewHeldAsPointer(f: Facts, ty: TypeId) bool {
        return sema.viewHeldAsPointer(f.c(), ty);
    }
    /// Whether a read view of `inner` is a copy, not an address
    /// (`sema.lendByValue`).
    pub fn lendByValue(f: Facts, inner: TypeId) bool {
        return sema.lendByValue(f.c(), inner);
    }
    /// Whether a view of type `view` of a slot of type `slot` is the bytes
    /// of a String (`sema.viewsStringBytes`).
    pub fn viewsStringBytes(f: Facts, slot: TypeId, view: TypeId) bool {
        return sema.viewsStringBytes(f.c(), slot, view);
    }
    /// The `T` of a `?T` written `rig.ReadView(T)` (`storage.genericReadView`).
    pub fn genericReadView(f: Facts, ty: TypeId) ?TypeId {
        return storage.genericReadView(f.c(), ty);
    }
    /// Whether a `T?` of payload `inner` is written `rig.Opt(T)`, with
    /// every operation through the optional helpers
    /// (`sema.optionalRouted`); `strict` under `RIG_STRICT_OPTIONALS`.
    pub fn optionalRouted(f: Facts, inner: TypeId, strict: bool) bool {
        return sema.optionalRouted(f.c(), inner, strict);
    }
    /// Whether the type `sym` declares is an object (`sema.isObjectSym`).
    pub fn isObjectSym(f: Facts, sym: SymbolId) bool {
        return sema.isObjectSym(f.c(), sym);
    }
    /// What `+x` does to a value of this type (`sema.cloneable`).
    pub fn cloneable(f: Facts, ty: TypeId) Clone {
        return sema.cloneable(f.c(), ty);
    }
};

/// The node decisions emit still makes itself, by calling a classifier the
/// checkers also call, or by a rule of its own over a type's facts. Each is
/// a decision that belongs in a recorded node fact; when one moves there,
/// its entry here is deleted, and the test below counts what is left.
pub const Pending = struct {
    sema_context: *const anyopaque,

    fn c(p: Pending) *const SemContext {
        return @ptrCast(@alignCast(p.sema_context));
    }

    pub fn assignWritesThrough(p: Pending, ty: TypeId) bool {
        return sema.assignWritesThrough(p.c(), ty);
    }
    pub fn moves(p: Pending, ty: TypeId) Answer {
        return sema.moves(p.c(), ty);
    }
    pub fn copies(p: Pending, ty: TypeId) Answer {
        return sema.copies(p.c(), ty);
    }
};

/// The syntax helpers emit shares with the checkers: functions of the IR
/// alone, which read no fact and decide nothing a fact owns.
pub const syntax = struct {
    pub const lentPlace = storage.lentPlace;
    pub const argValue = storage.argValue;
    pub const eachTargetStep = storage.eachTargetStep;
    pub const assignedThrough = storage.assignedThrough;
    pub const eachGuardPart = rig.eachGuardPart;
    pub const eachGuardOperand = rig.eachGuardOperand;
    pub const leavesBody = rig.leavesBody;
    pub const contains = storage.contains;
    pub const isCatchAll = storage.isCatchAll;
    pub const matchGuarded = storage.matchGuarded;
    pub const subjectRereadable = storage.subjectRereadable;
    pub const isLiteralText = storage.isLiteralText;
    pub const valueParts = sema.valueParts;
    pub const tailOf = sema.tailOf;
    pub const yieldsValue = sema.yieldsValue;
    pub const hasValueBreaks = sema.hasValueBreaks;
    pub const isHeaderOf = sema.isHeaderOf;
    pub const captureList = sema.captureList;
    pub const captureNameNode = sema.captureNameNode;
    pub const paramName = sema.paramName;
    pub const paramNameNode = sema.paramNameNode;
    pub const tparamsOf = sema.tparamsOf;
    pub const dataFields = sema.dataFields;
    pub const isProxy = sema.isProxy;
    pub const isIntLiteralText = sema.isIntLiteralText;
    pub const isFloatLiteralText = sema.isFloatLiteralText;
    pub const isNumericTypeName = resolve.isNumericTypeName;
};

/// The node decisions `Pending` may still offer emit: this number only
/// goes down, as each moves into a recorded fact.
const pending_budget = 3;

test "emit reads the checkers' decisions only through Facts" {
    const emit_source = @embedFile("emit.zig");
    // Emit imports no file that holds a classifier: sema.zig, storage.zig,
    // and resolve.zig are reached only through this one. nametable.zig
    // builds the data of a table of names, and decides nothing.
    const allowed = [_][]const u8{ "std", "parser.zig", "rig.zig", "facts.zig", "diag.zig", "nametable.zig" };
    // Read as Zig reads it, so no spelling of an import slips past.
    var tokens = std.zig.Tokenizer.init(emit_source);
    var imports: usize = 0;
    while (true) {
        const t = tokens.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        const name = emit_source[t.loc.start..t.loc.end];
        // Nothing reaches a struct's parent through a field of `Facts`.
        if (std.mem.eql(u8, name, "@fieldParentPtr")) return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, name, "@import")) continue;
        if (tokens.next().tag != .l_paren) return error.TestUnexpectedResult;
        const arg = tokens.next();
        if (arg.tag != .string_literal) return error.TestUnexpectedResult;
        const file = emit_source[arg.loc.start + 1 .. arg.loc.end - 1];
        imports += 1;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, file)) break;
        } else {
            std.debug.print("emit.zig imports {s}, which only facts.zig may\n", .{file});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(allowed.len, imports);
    // Nor does it reach the context behind `Facts`.
    for ([_][]const u8{ "sema_context", "@ptr" ++ "Cast(", "any" ++ "opaque" }) |word| {
        if (std.mem.indexOf(u8, emit_source, word)) |i| {
            std.debug.print("emit.zig reaches past Facts at byte {d}: {s}\n", .{ i, word });
            return error.TestUnexpectedResult;
        }
    }
    // Every pending decision is one emit still makes, and there are no more
    // of them than the budget: a decision moved into a recorded fact leaves
    // the list.
    const decls = @typeInfo(Pending).@"struct".decl_names;
    try std.testing.expect(decls.len <= pending_budget);
    inline for (decls) |name| {
        if (std.mem.indexOf(u8, emit_source, ".pending." ++ name ++ "(") == null) {
            std.debug.print("Pending.{s} is no longer used by emit: delete it\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "Facts answers as the context it was made from" {
    const source =
        \\obj S
        \\  n: Int
        \\  t: String
        \\
        \\fun mk(n: Int) -> S
        \\  S(n: n, t: String("s"))
        \\
        \\sub main()
        \\  s = mk(1)
        \\  print(mk(2).n, s.t)
        \\
    ;
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var ctx = try sema.check(a, source, tree, .{});
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
    const f = Facts.of(&ctx);
    try std.testing.expect(f.same(Facts.of(&ctx)));
    try std.testing.expect(f.moduleWithSource(source).?.same(f));
    try std.testing.expectEqualStrings(source, f.source);
    // Every node: the same answers, read through the accessor.
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    var temps: usize = 0;
    for (nodes.items) |n| {
        try std.testing.expectEqual(ctx.symbolOf(n), f.symbolOf(n));
        try std.testing.expectEqual(ctx.typeOf(n), f.typeOf(n));
        try std.testing.expectEqual(ctx.dropsTemp(n), f.dropsTemp(n));
        try std.testing.expectEqual(ctx.useOf(n), f.useOf(n));
        for (std.enums.values(StorageKind)) |k| try std.testing.expectEqual(ctx.storageOf(n, k), f.storageOf(n, k));
        if (f.dropsTemp(n)) temps += 1;
    }
    // `mk(2)` is a temporary its statement drops.
    try std.testing.expectEqual(1, temps);
}

test "Facts reads the leaf walk the storage plan decided" {
    const source =
        \\obj R unique
        \\  n: Int
        \\
        \\  fun get(?self) -> Int
        \\    self.n
        \\
        \\fun mkr(n: Int) -> R
        \\  R(n: n)
        \\
        \\sub go(k: Bool)
        \\  r = mkr(1)
        \\  print((r if k else mkr(5)).get())
        \\
    ;
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var ctx = try sema.check(a, source, tree, .{});
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
    const f = Facts.of(&ctx);
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    var reached: usize = 0;
    var made: usize = 0;
    for (nodes.items) |n| {
        // Decided for every expression.
        if (n == .src or (n == .list and n.list.id != 0)) {
            const r = f.reachesLeaf(n) orelse return error.TestUnexpectedResult;
            if (r) reached += 1;
        }
        if (f.leafStep(n)) |step| if (step == .made) {
            made += 1;
            // Reached where Zig holds it: a fact names it.
            try std.testing.expectEqual(StorageBy.owned, (f.storageOf(n, .zig_temp) orelse return error.TestUnexpectedResult).by);
        };
    }
    // `r if k else mkr(5)`, with `mkr(5)` made there.
    try std.testing.expectEqual(1, reached);
    try std.testing.expectEqual(1, made);
}

test "Facts reads every match decision the plan made" {
    const source =
        \\enum E
        \\  a(n: Int, t: String)
        \\  b
        \\
        \\sub main()
        \\  e = E.a(n: 1, t: String("x"))
        \\  match e
        \\    .a(n, t) if n > 0 => print(n, t)
        \\    other => print(other)
        \\
    ;
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var ctx = try sema.check(a, source, tree, .{});
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
    const f = Facts.of(&ctx);
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    var matches: usize = 0;
    for (nodes.items) |n| if (n.isKind(.match)) {
        matches += 1;
        try std.testing.expectEqual(MatchMode.read, f.matchMode(n).?);
        // A name's value is matched where it is.
        try std.testing.expect(f.matchesInPlace(n).?);
        try std.testing.expect(f.matchBlock(n).?);
        try std.testing.expect(!f.holdsView(n).?);
        try std.testing.expect(f.matchRereads(n) != null and f.subjectHold(n) != null);
        for (ir.Match.arms(n)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            if (pattern == .src) try std.testing.expect(f.catchAllCaptured(pattern) != null);
            if (pattern.isKind(.variant_pattern)) for (f.payloadBindings(pattern).?) |b| {
                // `t` is a view of the String where it is; `n` a copy.
                const by_addr = f.bindsByAddress(b).?;
                try std.testing.expectEqual(std.mem.eql(u8, source[b.src.pos..][0..b.src.len], "t"), by_addr);
            };
        }
    };
    try std.testing.expectEqual(1, matches);
}

test "Facts reads where each step runs and where each jump goes" {
    const source =
        \\fun some(i: Int) -> Int?
        \\  i if i < 6 else none
        \\
        \\sub main()
        \\  i = 0
        \\  while some(i) as h and h >= 0: i += h
        \\    continue if h == 2
        \\    break if h == 4
        \\  j = 0
        \\  while j < 3: j += 1
        \\    continue
        \\  k = 0
        \\  while (some(k) ?? continue) > 0
        \\    k += 1
        \\  @outer for a in 0..3
        \\    for b in 0..3
        \\      continue @outer if b == a
        \\      break @outer
        \\  m = 0
        \\  while true: m += some(m) ?? continue
        \\    break
        \\  @blk match i
        \\    0 => break @blk
        \\    _ => pass
        \\
    ;
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var ctx = try sema.check(a, source, tree, .{});
    defer ctx.deinit();
    for (ctx.diagnostics.items) |d| std.debug.print("{s}\n", .{d.message});
    try std.testing.expect(!ctx.hasErrors());
    const f = Facts.of(&ctx);
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    const Want = struct { to: JumpDest.To, target: parser.Tag };
    const jumps = [_]Want{
        .{ .to = .step, .target = .@"while" }, // a `continue` from the body, to a step after it
        .{ .to = .exit, .target = .@"while" },
        .{ .to = .step, .target = .@"while" }, // to the continue expression
        .{ .to = .head, .target = .@"while" }, // from the condition of a loop with no step
        .{ .to = .head, .target = .@"for" }, // `continue @outer` from the inner loop's body
        .{ .to = .exit, .target = .@"for" },
        .{ .to = .head, .target = .@"while" }, // from the step
        .{ .to = .exit, .target = .@"while" },
        .{ .to = .exit, .target = .match },
    };
    const steps = [_]StepPoint{ .after_body, .continue_expr, .continue_expr, .continue_expr };
    var nj: usize = 0;
    var ns: usize = 0;
    for (nodes.items) |n| {
        if (n.isKind(.@"while")) {
            try std.testing.expectEqual(steps[ns], f.stepPoint(n).?);
            ns += 1;
        }
        if (n.isKind(.@"break") or n.isKind(.@"continue")) {
            const d = f.jumpDest(n) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(jumps[nj].to, d.to);
            try std.testing.expectEqual(jumps[nj].target, d.target.kind().?);
            nj += 1;
        }
    }
    try std.testing.expectEqual(jumps.len, nj);
    try std.testing.expectEqual(steps.len, ns);
}

fn collect(a: std.mem.Allocator, e: Sexp, out: *std.ArrayList(Sexp)) !void {
    try out.append(a, e);
    if (e == .list) for (e.items()) |child| try collect(a, child, out);
}
