//! What emit may know about a checked module: its recorded facts, read-only.
//!
//! Emit lowers a module the checkers have accepted, so every decision that
//! affects ownership or memory (copy or address, slot or temporary, the
//! order things run in, where a drop goes, `*T` or `*const T`, view or
//! value) was made before it runs, by sema, typecheck, or lowering,
//! and the ownership checker walked what they decided. Emit reads those
//! decisions here and decides none of them again (AGENTS.md, "One
//! classifier per fact" and "The checker checks exactly what is emitted").
//!
//! `src/emit.zig` imports this file and not `sema.zig`, `lower.zig`, or
//! `resolve.zig`, so the classifiers there are out of its reach: a call of
//! `sema.copies` or `lower.matchesInPlace` from emit does not compile. A
//! unit test below fails if emit imports anything else. What `Facts` offers
//! is of two kinds:
//!
//! - **Node facts**: what the checkers recorded about a node, read from the
//!   facts table (docs/internals/INTERNALS.md, "The facts table") and the
//!   module's LIR (`lower`, "Storage facts"). Each answers for the node it is
//!   asked about and is decided once, where it is recorded.
//! - **Types**: the type table, the symbols, and the questions about a type
//!   whose answer is how values of that type are spelled in Zig (whether a
//!   view is a pointer, whether a pointer to it is mutable, what `+x`
//!   lowers to): one answer per type, read the same way by every pass.
//!
//! Emit makes no decision of its own with a classifier the checkers also
//! call: whether a binding or a hidden storage holds a value that moves,
//! and how it drops it, is its var in the module's LIR (`lower`) and
//! `SetOrder.drops_old`.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const lowering = @import("lower.zig");
pub const lir = @import("lir.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;

pub const TypeId = sema.TypeId;
pub const SymbolId = sema.SymbolId;
pub const SymbolRef = sema.SymbolRef;
pub const MemberCompares = sema.MemberCompares;

pub const ThroughWrite = lir.ThroughWrite;
pub const CompoundCall = lir.CompoundCall;
pub const BindHold = lir.BindHold;
pub const SwapCall = sema.SwapCall;
pub const Builtin = sema.Builtin;
pub const Wide = sema.Wide;
pub const Type = sema.Type;
pub const TypeStore = sema.TypeStore;
pub const Symbol = sema.Symbol;
pub const Field = sema.Field;
pub const FunctionType = sema.FunctionType;
pub const ParamNominal = sema.ParamNominal;
pub const View = sema.View;
pub const ViewStep = sema.ViewStep;
pub const StringCall = sema.StringCall;
pub const ElemCall = sema.ElemCall;
pub const BuiltinCall = sema.BuiltinCall;
pub const Proven = sema.Proven;
pub const ProvenIf = sema.ProvenIf;
pub const FlagTest = sema.FlagTest;
pub const NodeKey = sema.NodeKey;

/// Whether this build of the compiler runs its own consistency checks
/// (`zig build -Dself-check`; on in every debug build).
pub const self_check = @import("build_options").self_check;

pub const CtVal = sema.cteval.CtVal;
pub const CtResult = sema.cteval.Result;
pub const CtHidden = sema.cteval.Hidden;
pub const GenericCall = sema.GenericCall;
pub const PlainBit = sema.PlainBit;
pub const PlainArg = sema.PlainArg;
pub const Use = sema.Use;
pub const Header = sema.Header;
/// A module's bodies lowered (`src/lower.zig`), whose vars are the
/// storage emit prints.
pub const Lowered = lowering.Module;
pub const Coercion = @import("lir.zig").Coercion;
pub const liftLevels = @import("lir.zig").liftLevels;
pub const Hands = sema.Hands;
pub const StorageKind = lir.StorageKind;
pub const StorageBy = lir.StorageBy;
pub const Clone = sema.Clone;
pub const SelfMode = sema.SelfMode;
pub const Upgrade = sema.Upgrade;
pub const Lift = sema.Lift;
pub const TypedInt = sema.cteval.TypedInt;
pub const DurationParts = sema.DurationParts;
pub const DurationHow = sema.DurationHow;
pub const Instance = sema.Instance;
pub const HandsKind = sema.Hands.Kind;
pub const LeafStep = lir.LeafStep;
pub const MatchMode = lir.MatchMode;
pub const SelfHold = lir.SelfHold;
pub const ArgumentHold = lir.ArgumentHold;
pub const SetOrder = lir.SetOrder;
pub const ResourceKind = sema.ResourceKind;
pub const SetStep = lowering.SetStep;
pub const StepPoint = lir.StepPoint;
pub const Fold = lir.Fold;
pub const JumpDest = sema.JumpDest;
pub const CallTarget = sema.CallTarget;
pub const Dispatch = sema.Dispatch;
pub const Witness = sema.Witness;
pub const Erasure = sema.Erasure;
pub const ArgWitness = sema.ArgWitness;
pub const Conformance = sema.Conformance;
pub const ApiRef = sema.ApiRef;
pub const ApiObject = sema.ApiObject;
pub const TableEntry = sema.TableEntry;

pub const type_invalid = sema.type_invalid;
pub const symbol_invalid = sema.symbol_invalid;
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
    /// The built-in types and enums, by their refs in module 0.
    builtins: *const sema.Builtins,

    pub fn of(ctx: *const SemContext) Facts {
        return .{
            .sema_context = ctx,
            .types = ctx.types,
            .symbols = &ctx.symbols,
            .source = ctx.source,
            .name = ctx.name,
            .zig_file = ctx.zig_file,
            .is_root = ctx.is_root,
            .builtins = ctx.builtins,
        };
    }

    fn c(f: Facts) *const SemContext {
        return @ptrCast(@alignCast(f.sema_context));
    }

    /// What a checker recorded about a node, read from the module's
    /// record: a method of `SemContext`, or a helper of sema or lowering
    /// over recorded symbols, types, and constants (the test below lists
    /// those), asked with the node and what else it takes:
    /// `f.node(.viewOf, e)`, `f.node(.calleeOf, .{ call })`. Emit
    /// may ask only what `node_facts` lists.
    pub fn node(f: Facts, comptime fact: @EnumLiteral(), args: anytype) Result(@tagName(fact)) {
        comptime listed(&node_facts, @tagName(fact));
        return f.ask(@tagName(fact), args);
    }

    pub const node_facts = [_][]const u8{
        "symbolOf",        "typeOf",            "startOf",        "calleeOf",
        "callTargetOf",    "ctArgsOf",          "instanceOf",     "genericCallOf",
        "elemCallOf",      "builtinOf",         "builtinCallOf",  "durationOf",
        "provenOf",        "provenIfOf",        "flagOf",         "callableOf",
        "viewOf",          "viewsTempArray",    "readsThrough",   "copiesPayload",
        "readsInPlace",    "taskJoinOf",        "isActorMake",    "isFrozenMake",
        "isTypeParamCall", "dispatchOf",        "erasureOf",      "isChanMake",
        "isSelect",        "isActorSupervised", "isOnceClosure",  "isLocalTask",
        "testCheckOf",     "writesTemp",        "useOf",          "liftOf",
        "takes",           "oldIsNone",         "upgradeOf",      "writesThrough",
        "copiesElem",      "isTypedLiteral",    "isFailingLeaf",  "isMemberTest",
        "isErrorMember",   "namesErrorMember",  "isTableWrite",   "isEnumText",
        "headerOf",        "heldBaseOf",        "payloadFieldOf", "payloadBindings",
        "altsBind",        "payloadTests",      "copiesHeader",   "stringCall",
        "stringNumOf",     "isPrintCall",       "isNoneLeaf",     "isTypeCallee",
        "moduleMemberSym", "selfOf",            "heldFirst",      "selfWrites",
        "lambdaYields",    "matchedType",
    };

    /// How a type or a symbol is spelled and held in Zig: one answer per
    /// type, read the same way by every pass, asked as `node` asks, of
    /// what `layouts` lists.
    pub fn layout(f: Facts, comptime q: @EnumLiteral(), args: anytype) Result(@tagName(q)) {
        comptime listed(&layouts, @tagName(q));
        return f.ask(@tagName(q), args);
    }

    pub const layouts = [_][]const u8{
        "owns",              "isUsed",           "needsPlainBit",           "witnessName",
        "witnessParamName",  "conformanceArgs",  "apiSymbol",               "isOnceCapture",
        "memberCompares",    "fieldMoves",       "isTypeSym",               "payloadViewed",
        "unwrapViews",       "writtenThrough",   "unwrapReadAccess",        "unwrapAccess",
        "loopWalks",         "boxedType",        "boxedNominal",            "callableFn",
        "callableFnTy",      "ownedClosureFn",   "fnType",                  "writeSliceElem",
        "isReadOrWriteView", "isErrorSet",       "isErrorValue",            "isSetParam",
        "resultsOf",         "isNumeric",        "declFill",                "tableElem",
        "frozenValue",       "isPlainEnum",      "containsTypeVar",         "lookupDataFieldConst",
        "methodSelfMode",    "variantPayload",   "ownApiOf",                "isErrorValueForm",
        "formatTypeValue",   "formatTypeMarked", "formatGenericSelfMarked", "formatInlineListMarked",
        "viewHeldAsPointer", "viewByValue",      "viewsStringBytes",        "genericReadView",
        "namedNoneOf",       "wordBitsOfSym",    "optionalRouted",          "isCompoundSym",
        "cloneable",         "enumVariantCount", "typeHasDropGlue",         "cellObjectSym",
    };

    fn listed(comptime list: []const []const u8, comptime name: []const u8) void {
        for (list) |n| if (std.mem.eql(u8, n, name)) return;
        @compileError("emit asks a question of facts that no list names: " ++ name);
    }

    /// The function that answers `name`: a method of `SemContext`, else
    /// a function of sema or of lowering's storage deciders that takes
    /// the context first.
    fn answerer(comptime name: []const u8) @TypeOf(@field(Answerer(name), name)) {
        return @field(Answerer(name), name);
    }

    fn Answerer(comptime name: []const u8) type {
        if (@hasDecl(SemContext, name)) return SemContext;
        if (@hasDecl(sema, name)) return sema;
        return lowering;
    }

    fn Result(comptime name: []const u8) type {
        return @typeInfo(@TypeOf(answerer(name))).@"fn".return_type.?;
    }

    fn ask(f: Facts, comptime name: []const u8, args: anytype) Result(name) {
        const A = @TypeOf(args);
        const tuple = if (@typeInfo(A) == .@"struct" and @typeInfo(A).@"struct".is_tuple) args else .{args};
        return @call(.auto, answerer(name), .{f.c()} ++ tuple);
    }

    /// The program-wide name of this module's symbol `sym` (`SemContext.ref`).
    pub fn refOf(f: Facts, sym: SymbolId) sema.SymbolRef {
        return f.c().ref(sym);
    }

    /// Whether `ty` is a bare API object, `{Shape}`, which only a type
    /// alias names (`sema.apiObject`).
    pub fn objectBare(f: Facts, ty: TypeId) bool {
        return sema.apiObject(f.c(), ty) != null;
    }
    /// The API object a box `ty` holds, `^{Shape}`; null for any other
    /// type.
    pub fn objectBox(f: Facts, ty: TypeId) ?sema.ApiObject {
        const h = sema.objectHeld(f.c(), ty) orelse return null;
        return if (h.form == .box) h.object else null;
    }

    /// The API object a counted or a weak handle `ty` holds, `*{Shape}`
    /// or `~{Shape}`; null for any other type.
    pub fn objectHandle(f: Facts, ty: TypeId) ?sema.ApiObject {
        const h = sema.objectHeld(f.c(), ty) orelse return null;
        return if (h.form == .shared or h.form == .weak) h.object else null;
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

    /// The element type of the range `a..b` a `for` walks: the bounds'
    /// type, which the checker records on the range (`checkFor`).
    pub fn rangeElem(f: Facts, range: Sexp) ?TypeId {
        const ty = f.c().typeOf(range) orelse return null;
        return switch (f.types.get(ty)) {
            .range => |e| e,
            else => null,
        };
    }
    /// Where the package holds the file `$embed` call `call` reads
    /// (`sema.EmbedSite`), once the module graph found it.
    pub fn embedPlace(f: Facts, call: Sexp) ?[]const u8 {
        return if (call == .list) f.c().facts.embeds.get(call.list.id) else null;
    }
    /// Whether the function or method whose name leaf is `name` is
    /// emitted `inline` (`inlining.decide`).
    pub fn isInlined(f: Facts, name: Sexp) bool {
        return f.c().decides(.inlined, f.c().startOf(name));
    }
    /// Whether the function or method whose name leaf is `name` never
    /// returns, which Zig's result `noreturn` says (`returns.decide`).
    pub fn neverReturns(f: Facts, name: Sexp) bool {
        return f.c().decides(.never_returns, f.c().startOf(name));
    }
    /// In a split build, the unit that owns the function or method whose
    /// name leaf is `name`, when it is cut (`units.decide`).
    pub fn splitUnitOf(f: Facts, name: Sexp) ?u16 {
        return f.c().decisionOf(.split_units, f.c().startOf(name));
    }
    /// Whether the function or method whose name leaf is `name` checks
    /// for work left waiting at its entry: one of a set every cycle of
    /// calls passes through (`inlining.decide`).
    pub fn hasEntryCheck(f: Facts, name: Sexp) bool {
        return f.c().decides(.entry_checks, f.c().startOf(name));
    }
    /// Whether the function or method whose name leaf is `name` has a
    /// large frame, emitted `noinline` (`sema.SemContext.large_frames`).
    pub fn isLargeFrame(f: Facts, name: Sexp) bool {
        return f.c().large_frames.contains(f.c().startOf(name));
    }
    /// Whether the closure or `drop` body `node`, a frame owner of its
    /// own (`sema.FrameOwner`), has a large frame, emitted `noinline`.
    pub fn isLargeOwner(f: Facts, n: Sexp) bool {
        return f.c().large_frames.contains(f.c().startOf(n));
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
        if (lowering.moduleMemberSym(ctx, callee)) |sym| return sym.kind == .function;
        const obj = ir.Member.object(callee);
        const name_leaf = ir.Member.name(callee);
        if (name_leaf != .src) return false;
        const name = rig.leafText(ctx.source, name_leaf.src);
        // A value's type, or the type a type's name stands for.
        const decl = if (ctx.typeOf(obj)) |t| sema.nominalDecl(ctx, t) else null;
        const sym: sema.Symbol = if (decl) |d| d.symbol() else blk: {
            const id = ctx.symbolOf(obj) orelse return false;
            if (!lowering.isTypeSym(ctx, id)) return false;
            break :blk ctx.symbols.items[id];
        };
        if (sym.decl_pos == sema.builtin_decl_pos) return false;
        for (sym.fields orelse return false) |field| {
            if (field.is_method and !field.is_drop_method and std.mem.eql(u8, field.name, name)) return true;
        }
        return false;
    }
    /// The value of a compile-time call (`cap[8]`), which the checker
    /// computed, and the hidden constant that holds an array one.
    pub fn ctValueOf(f: Facts, n: Sexp) ?CtResult {
        return sema.cteval.recorded(f.c(), n);
    }
    /// The hidden constants of the module's compile-time values, in order:
    /// the one at `i` is `__rig_ct_<i>`.
    pub fn ctHidden(f: Facts) []const CtHidden {
        return f.c().ct.hidden.items;
    }
    /// The name of variant `i` of plain enum `ty`.
    pub fn variantName(f: Facts, ty: TypeId, i: u32) []const u8 {
        return sema.cteval.variantName(f.c(), ty, i);
    }

    // -------------------------------------------------------------------
    // APIs of a program's own (docs/design/apis.md, Stage 3)
    // -------------------------------------------------------------------

    /// The witnesses an instance of a generic type takes among its
    /// arguments (`sema.recordTypeWitnesses`); null for a type that takes
    /// none, or one no check recorded.
    pub fn typeWitnesses(f: Facts, ty: TypeId) ?[]const ArgWitness {
        return f.c().type_witnesses.get(ty);
    }
    /// The bits an instance of a generic type passes after its arguments
    /// (`sema.recordPlainFacts`); empty for one that passes none.
    pub fn typePlainBits(f: Facts, ty: TypeId) []const PlainArg {
        return f.c().type_plain_bits.get(ty) orelse &.{};
    }
    /// What `$plain` of `ty` gives where the module tests it
    /// (`sema.recordPlainFacts`).
    pub fn plainTestBit(f: Facts, ty: TypeId) ?PlainBit {
        return f.c().plain_test_bits.get(ty);
    }
    /// Whether generic type `sym`'s parameters take witnesses: some bound
    /// names an API of a program's own.
    pub fn takesWitnesses(f: Facts, sym: SymbolId) bool {
        for (f.symbols.items[sym].type_params orelse return false) |p| {
            if (p != sema.symbol_invalid and f.symbols.items[p].user_apis.len > 0) return true;
        }
        return false;
    }
    /// The conformances this module writes, each with its witness.
    pub fn conformances(f: Facts) []const Conformance {
        return f.c().conformances.items;
    }
    /// The conformance `index` of module `module_id`, with that module's
    /// facts.
    pub fn conformanceAt(f: Facts, module_id: u32, index: u32) ?struct { facts: Facts, conf: Conformance } {
        const home = if (module_id == f.c().module_id) f else f.foreign(module_id) orelse return null;
        return .{ .facts = home, .conf = home.c().conformances.items[index] };
    }
    /// The API object view `ty` is, `?{Shape}` or `!{Shape}`
    /// (`sema.objectView`).
    pub fn objectView(f: Facts, ty: TypeId) ?sema.ApiObject {
        return if (sema.objectView(f.c(), ty)) |v| v.object else null;
    }
    /// The entries of the table of API `sym`, declared in this module
    /// (`sema.TableEntry`).
    pub fn objectTable(f: Facts, sym: SymbolId) []const sema.TableEntry {
        return f.c().object_tables.get(sym) orelse &.{};
    }
    /// Whether the result of a call through an API object goes out
    /// through the caller's place: its table entry's (`sema.TableEntry`
    /// `result_out`).
    pub fn resultOut(f: Facts, d: Dispatch.Dynamic) bool {
        const e = sema.tableEntry(f.c(), d) orelse return false;
        return e.result_out;
    }
    /// This module's id among the program's.
    pub fn moduleId(f: Facts) u32 {
        return f.c().module_id;
    }
    /// Whether a task that makes this call first may take a dense stack
    /// (`program.Table.dense_calls`).
    pub fn isDenseCall(f: Facts, call: Sexp) bool {
        return call == .list and f.c().decides(.dense_calls, call.list.id);
    }

    /// The most stack this call may take, in bytes, when every function
    /// it can reach is known and fits a dense stack; null when no bound
    /// is known (`program.Table.dense_calls`).
    pub fn callDepth(f: Facts, call: Sexp) ?u64 {
        if (call != .list) return null;
        return f.c().decisionOf(.dense_calls, call.list.id);
    }

    /// Whether the program calls `from_text` on plain enum `sym` of this
    /// module, which then emits its table of names.
    pub fn hasTextTable(f: Facts, sym: SymbolId) bool {
        return f.c().decides(.text_tables, sym);
    }
    /// The module's bodies lowered, with what lowering decides for emit:
    /// tree `module` is the module's. Sema lowered them for its checks
    /// and freed them once they finished; emit lowers each module again
    /// as it writes it.
    pub fn lower(f: Facts, gpa: std.mem.Allocator, module: Sexp, strict_optionals: bool) !Lowered {
        return lowering.lowerModule(gpa, @constCast(f.c()), module, .{ .strict_optionals = strict_optionals });
    }
    /// The value a constant pattern compares with (`sema.patternConst`).
    pub fn patternConst(f: Facts, pattern: Sexp) ?sema.ConstScalar {
        return sema.constScalar(sema.patternConst(f.c(), pattern) orelse return null);
    }
    /// Where a `break` or `continue` goes, as the type checker resolved it
    /// (`sema.JumpDest`).
    pub fn jumpDest(f: Facts, jump: Sexp) ?JumpDest {
        return f.c().jumpDestOf(jump);
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
    /// The value of an integer constant expression.
    pub fn constIntOf(f: Facts, e: Sexp) ?Wide {
        return sema.cteval.constIntOf(f.c(), e);
    }
    /// `Int.max` and the like.
    pub fn intLimit(f: Facts, e: Sexp) ?TypedInt {
        return sema.cteval.intLimit(f.c(), e);
    }
    /// The built-in types the program's names table spells.
    pub fn builtinTypes(f: Facts, a: std.mem.Allocator) ![]const Type {
        return resolve.builtinTypes(f.c(), a);
    }

    // -------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------

    pub fn isBuiltinEnum(f: Facts, sym: SymbolId) bool {
        return sema.isBuiltinEnum(f.c(), f.c().ref(sym));
    }
    pub fn isBuiltinGeneric(f: Facts, sym: SymbolId) bool {
        return sema.isBuiltinGeneric(f.c(), f.c().ref(sym));
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

    /// A member of a declared error set, with the facts of the module
    /// that declares the set.
    pub const ErrorMember = struct { facts: Facts, set: []const u8, name: []const u8 };

    /// Every member of every set `set`, a set or a union, stands for
    /// (`sema.errorSetLeaves`): what a `g: E =>` arm matches.
    pub fn errorSetMembers(f: Facts, set: TypeId, a: std.mem.Allocator) std.mem.Allocator.Error![]const ErrorMember {
        var leaves: std.ArrayList(sema.SetKey) = .empty;
        try sema.errorSetLeaves(f.c(), set, &leaves, a);
        var out: std.ArrayList(ErrorMember) = .empty;
        for (leaves.items) |leaf| {
            const leaf_facts = of(leaf.ctx);
            const set_name = leaf.ctx.symbols.items[leaf.sym].name;
            for (sema.setMembers(leaf)) |m| if (m.is_variant) try out.append(a, .{ .facts = leaf_facts, .set = set_name, .name = m.name });
        }
        return out.items;
    }

    /// The members a `g: E =>` pattern covers that no arm before it did
    /// (`SemContext.recordSetPatternMembers`): what its prong lists.
    pub fn setPatternMembers(f: Facts, n: Sexp, a: std.mem.Allocator) std.mem.Allocator.Error!?[]const ErrorMember {
        const members = f.c().setPatternMembers(n) orelse return null;
        const out = try a.alloc(ErrorMember, members.len);
        for (members, out) |m, *o| {
            const d = f.nominalDecl(m.set) orelse return null;
            o.* = .{ .facts = d.facts, .set = d.symbol().name, .name = m.name };
        }
        return out;
    }

    pub fn nominalDecl(f: Facts, ty: TypeId) ?Nominal {
        const d = sema.nominalDecl(f.c(), ty) orelse return null;
        return .{ .facts = of(d.ctx), .sym = d.sym, .module_id = d.module_id };
    }

    // How a type is held in Zig: one answer per type, which every pass
    // reads the same way (docs/internals/INTERNALS.md, Emit, "Views").

    /// The none the object `sym` of this module names.
    pub fn namedNoneOfSym(f: Facts, sym: SymbolId) ?sema.NamedNone {
        return f.c().named_nones.get(sym);
    }
    /// Whether `ty` is word-sized (`sema.wordBits`): its read views copy
    /// it.
    pub fn wordSized(f: Facts, ty: TypeId) bool {
        return sema.wordBits(f.c(), ty) != null;
    }
    /// The bits of the object `sym` declares here when it is held as one
    /// word, a Zig `packed struct` (`program.decideWords`).
    pub fn wordHeldBitsOfSym(f: Facts, sym: SymbolId) ?u8 {
        if (!f.c().decides(.word_held, sym)) return null;
        return sema.wordBitsOfSym(f.c(), sym);
    }
    /// Whether the object `sym` declares here is `exact`, laid out in
    /// declaration order: a Zig `extern struct`.
    pub fn isExact(f: Facts, sym: SymbolId) bool {
        return f.c().symbols.items[sym].flags.exact;
    }
    /// The bytes of the tag type of the plain enum `sym` declares here,
    /// when an `exact` object holds it (`program.decideExactEnums`).
    pub fn exactEnumBytes(f: Facts, sym: SymbolId) ?u8 {
        return f.c().decisionOf(.exact_enums, sym);
    }
    /// Whether a field of type `ty` inside a plain object is held at
    /// four-byte alignment (`align(4)`): a 64-bit word-held object, which
    /// takes the place its two 32-bit fields would, so the object keeps
    /// its size.
    pub fn wordAlignedField(f: Facts, ty: TypeId) bool {
        const d = sema.nominalDecl(f.c(), ty) orelse return false;
        return switch (f.c().types.get(ty)) {
            .nominal => d.ctx.decides(.word_held, d.sym) and sema.wordBitsOfSym(d.ctx, d.sym) == 64,
            else => false,
        };
    }
};

/// The syntax helpers emit shares with the checkers: functions of the IR
/// alone, which read no fact and decide nothing a fact owns.
pub const syntax = struct {
    /// The marker of the `fun` or `sub` `node`: `rarely`, its body's
    /// first line, starts it with the cold hint, and `called` emits it
    /// `noinline fn`.
    pub const markerOf = rig.markerOf;
    pub const viewedPlace = lowering.viewedPlace;
    pub const argValue = lowering.argValue;
    pub const eachTargetStep = lowering.eachTargetStep;
    pub const assignedThrough = lowering.assignedThrough;
    pub const eachGuardPart = rig.eachGuardPart;
    pub const funRarely = rig.funRarely;
    pub const contains = lowering.contains;
    pub const isStringLiteralText = sema.isStringLiteralText;
    pub const SingleQuoted = sema.SingleQuoted;
    /// A template's slots and pieces, its pieces' text, and a show slot's
    /// label (SPEC "Templates").
    pub const Template = rig.Template;
    pub const templateText = rig.templateText;
    pub const showLabel = rig.showLabel;
    pub const templateBlock = rig.templateBlock;
    pub const writeTemplatePiece = rig.writeTemplatePiece;
    pub const isBlockText = rig.isBlockText;
    pub const zigLiteral = rig.zigLiteral;
    pub const isLiteralText = lowering.isLiteralText;
    pub const valueParts = sema.valueParts;
    pub const tailOf = sema.tailOf;
    pub const yieldsValue = sema.yieldsValue;
    pub const hasValueBreaks = sema.hasValueBreaks;
    pub const isHeaderOf = sema.isHeaderOf;
    pub const captureList = sema.captureList;
    pub const captureNameNode = sema.captureNameNode;
    pub const captureValue = sema.captureValue;
    pub const paramName = sema.paramName;
    pub const paramNameNode = sema.paramNameNode;
    pub const tparamsOf = sema.tparamsOf;
    pub const ownApiMethod = sema.ownApiMethod;
    pub const isIntLiteralText = sema.isIntLiteralText;
    pub const isFloatLiteralText = sema.isFloatLiteralText;
    pub const isNumericTypeName = resolve.isNumericTypeName;
};

test "emit reads the checkers' decisions only through Facts" {
    const emit_source = @embedFile("emit.zig");
    // Emit imports no file that holds a classifier: sema.zig, lower.zig,
    // and resolve.zig are reached only through this one. nametable.zig
    // builds the data of a table of names, and names.zig lists the
    // runtime's names; neither decides anything.
    const allowed = [_][]const u8{ "std", "parser.zig", "rig.zig", "facts.zig", "diag.zig", "nametable.zig", "names.zig" };
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
    // Nor does it call a classifier the checkers also call: what it would
    // decide with one is recorded.
    for ([_][]const u8{ ".pending.", "moves(" }) |word| {
        if (std.mem.indexOf(u8, emit_source, word)) |i| {
            std.debug.print("emit.zig decides at byte {d}: {s}\n", .{ i, word });
            return error.TestUnexpectedResult;
        }
    }
}

test "emit names hidden storage only through hiddenStorage" {
    const emit_source = @embedFile("emit.zig");
    // The base names `hiddenStorage` gives the storage the facts record,
    // read from its body.
    const begin = std.mem.indexOf(u8, emit_source, "    fn hiddenStorage(").?;
    const end = begin + std.mem.indexOf(u8, emit_source[begin..], "\n    }\n").?;
    var bases: std.ArrayList([]const u8) = .empty;
    defer bases.deinit(std.testing.allocator);
    // Spellings of a base that name no storage: a table entry's result
    // parameter, a parameter a function owns or holds the header of, and
    // a loop's index counter.
    const others = [_][]const u8{ "({s}{s}), __rig_res);\\n", ", __rig_res: *", "__rig_arg_{d}", "__rig_viewed_{s}", "__rig_viewed_{d}", "__rig_i_{d}" };
    var pass: enum { bases, uses } = .bases;
    while (true) : (pass = .uses) {
        var tokens = std.zig.Tokenizer.init(emit_source);
        while (true) {
            const t = tokens.next();
            if (t.tag == .eof) break;
            if (t.tag != .string_literal) continue;
            const text = emit_source[t.loc.start + 1 .. t.loc.end - 1];
            const inside = t.loc.start > begin and t.loc.end < end;
            if (pass == .bases) {
                if (inside and std.mem.startsWith(u8, text, "__rig_")) try bases.append(std.testing.allocator, text);
                continue;
            }
            if (inside) continue;
            for (others) |o| {
                if (std.mem.eql(u8, o, text)) break;
            } else for (bases.items) |b| {
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, text, at, b)) |i| : (at = i + 1) {
                    // `__rig_i` is not `__rig_it` or `__rig_in_self`.
                    const rest = text[i + b.len ..];
                    const name = rest.len > 0 and std.ascii.isAlphanumeric(rest[0]) or
                        rest.len > 1 and rest[0] == '_' and std.ascii.isAlphabetic(rest[1]);
                    if (i > 0 and text[i - 1] == '_' or name) continue;
                    std.debug.print("emit.zig spells the storage name {s} outside hiddenStorage: \"{s}\"\n", .{ b, text });
                    return error.TestUnexpectedResult;
                }
            }
        }
        if (pass == .uses) break;
    }
    try std.testing.expect(bases.items.len > 20);
}

test "a Facts method about a node reads what a checker recorded" {
    const source = @embedFile("facts.zig");
    // A method of `Facts` that takes a node, and a node fact (`node`),
    // answers from a record, the facts table or the storage facts, read
    // through the context. These still find their answer with a helper of
    // lowering, sema, or cteval, each by the node's shape over recorded
    // symbols, types, and constants; the list only shrinks.
    const readers = [_][]const u8{
        "callsRigFunction", "patternConst",
        "constIntOf",       "intLimit",
        "stringCall",       "isNoneLeaf",
        "isTypeCallee",     "moduleMemberSym",
        "selfOf",           "heldFirst",
        "selfWrites",       "lambdaYields",
        "matchedType",
    };
    var seen: [readers.len]bool = @splat(false);
    const begin = std.mem.indexOf(u8, source, "pub const Facts = struct {").?;
    const end = begin + std.mem.indexOf(u8, source[begin..], "\n};\n").?;
    var tokens = std.zig.Tokenizer.init(source);
    tokens.index = begin;
    var methods: usize = 0;
    while (true) {
        var t = tokens.next();
        if (t.tag == .eof or t.loc.start >= end) break;
        if (t.tag != .keyword_fn) continue;
        const name_tok = tokens.next();
        const name = source[name_tok.loc.start..name_tok.loc.end];
        // The parameters, then the body, each to its closing bracket.
        var takes_node = false;
        var depth: usize = 0;
        while (true) {
            t = tokens.next();
            if (t.tag == .l_paren) depth += 1;
            if (t.tag == .r_paren) depth -= 1;
            if (t.tag == .identifier and std.mem.eql(u8, source[t.loc.start..t.loc.end], "Sexp")) takes_node = true;
            if (depth == 0 and t.tag == .r_paren) break;
        }
        while (t.tag != .l_brace) t = tokens.next();
        depth = 1;
        // The last three tokens: `lowering` `.` `name` before a `(` is a
        // call of lowering's `name`.
        var last: [3]std.zig.Token = undefined;
        var count: usize = 0;
        var classifier: ?[]const u8 = null;
        while (depth > 0) {
            t = tokens.next();
            if (t.tag == .l_brace) depth += 1;
            if (t.tag == .r_brace) depth -= 1;
            if (t.tag == .l_paren and count >= 3 and last[1].tag == .period and last[2].tag == .identifier and last[0].tag == .identifier) {
                const base = source[last[0].loc.start..last[0].loc.end];
                const called = source[last[2].loc.start..last[2].loc.end];
                // `cteval.recorded` reads the checker's record of a
                // compile-time call; cteval's other helpers fold.
                const folds = std.mem.eql(u8, base, "cteval") and !std.mem.eql(u8, called, "recorded");
                // `lowering.lowerModule` lowers the module; lowering's
                // other helpers are its storage deciders.
                const decides = std.mem.eql(u8, base, "lowering") and !std.mem.eql(u8, called, "lowerModule");
                if (decides or std.mem.eql(u8, base, "sema") or folds) classifier = called;
            }
            last = .{ last[1], last[2], t };
            count += 1;
        }
        if (!takes_node) continue;
        methods += 1;
        const listed = for (readers, 0..) |r, i| {
            if (std.mem.eql(u8, r, name)) break i;
        } else null;
        if (listed) |i| seen[i] = classifier != null;
        if (classifier != null and listed == null) {
            std.debug.print("Facts.{s} answers about a node by calling {s}, not by reading a record\n", .{ name, classifier.? });
            return error.TestUnexpectedResult;
        }
    }
    // A node fact no method of the context answers is a helper's.
    inline for (Facts.node_facts) |n| if (!@hasDecl(SemContext, n)) {
        const i = for (readers, 0..) |r, i| {
            if (std.mem.eql(u8, r, n)) break i;
        } else {
            std.debug.print("the node fact {s} is answered by a helper, not by reading a record\n", .{n});
            return error.TestUnexpectedResult;
        };
        seen[i] = true;
    };
    for (readers, seen) |r, s| if (!s) {
        std.debug.print("Facts.{s} no longer calls a helper of lowering, sema, or cteval: take it off the list\n", .{r});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(methods + Facts.node_facts.len > 50);
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
    var lowered = try f.lower(a, tree, false);
    defer lowered.deinit();
    var temps: usize = 0;
    for (nodes.items) |n| {
        try std.testing.expectEqual(ctx.symbolOf(n), f.node(.symbolOf, n));
        try std.testing.expectEqual(ctx.typeOf(n), f.node(.typeOf, n));
        try std.testing.expectEqual(ctx.useOf(n), f.node(.useOf, n));
        if (lowered.varOf(n, .temp) != null) temps += 1;
    }
    // `mk(2)` is a temporary its statement drops.
    try std.testing.expectEqual(1, temps);
}

test "Facts reads the leaf walk lowering decided" {
    const source =
        \\obj R unique
        \\  n: Int
        \\
        \\  fun get(?@) -> Int
        \\    @n
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
    var lowered = try f.lower(a, tree, false);
    defer lowered.deinit();
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    var reached: usize = 0;
    var made: usize = 0;
    for (nodes.items) |n| {
        const d = lowered.answersOf(n) orelse continue;
        if (d.reaches_leaf) reached += 1;
        if (d.leaf_step == .made) {
            made += 1;
            // Reached where Zig holds it: its LIR has a var for it.
            try std.testing.expectEqual(StorageBy.owned, (lowered.varOf(n, .zig_temp) orelse return error.TestUnexpectedResult).by);
        }
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
        \\    .a(:n, :t) if n > 0 => print(n, t)
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
    var lowered = try f.lower(a, tree, false);
    defer lowered.deinit();
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    var matches: usize = 0;
    for (nodes.items) |n| if (n.isKind(.match)) {
        matches += 1;
        const answers = lowered.choiceOf(n).?.answers;
        try std.testing.expectEqual(MatchMode.read, answers.mode);
        // A name's value is matched where it is.
        try std.testing.expect(answers.in_place);
        try std.testing.expect(answers.block);
        for (ir.Match.arms(n)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            if (pattern == .src) try std.testing.expect(lowered.bindingOf(f.node(.symbolOf, pattern).?) != null);
            if (pattern.isKind(.variant_pattern)) for (f.node(.payloadBindings, pattern).?) |b| {
                // `t` is a view of the String where it is; `n` a copy.
                const by_addr = lowered.bindingOf(f.node(.symbolOf, b).?).?.by_address;
                try std.testing.expectEqual(std.mem.eql(u8, source[b.src.pos..][0..b.src.len], "t"), by_addr);
            };
        }
    };
    try std.testing.expectEqual(1, matches);
}

test "every call emit writes has the record lowering made" {
    const source =
        \\V = Simd[Int, 4]([1, 2, 3, 4])
        \\
        \\obj P
        \\  x: Int
        \\
        \\  fun twice(?@) -> Int
        \\    @x * 2
        \\
        \\sub main()
        \\  p = P(x: 3)
        \\  print(p.twice(), (V + V)[1])
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
    var lowered = try f.lower(a, tree, false);
    defer lowered.deinit();
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    // Each call, a body's or the module constant's, by its form.
    const kinds = [_]lir.CallKind{ .simd_conversion, .constructor, .print, .plain };
    var i: usize = 0;
    for (nodes.items) |n| if (n.isKind(.call)) {
        try std.testing.expectEqual(kinds[i], (lowered.callOf(n) orelse return error.TestUnexpectedResult).kind);
        i += 1;
    };
    try std.testing.expectEqual(kinds.len, i);
    // Emit reads a call's record in one place, where a call lowering did
    // not record is an internal error, never Zig written from a guess.
    const emit_source = @embedFile("emit.zig");
    try std.testing.expectEqual(1, std.mem.count(u8, emit_source, ".callOf("));
    try std.testing.expect(std.mem.indexOf(u8, emit_source, ".callOf(call) orelse self.unsupported(call, \"a call lowering did not record\")") != null);
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
        \\  $outer: for a in 0..3
        \\    for b in 0..3
        \\      continue $outer if b == a
        \\      break $outer
        \\  m = 0
        \\  while m >= 0 : m += some(m) ?? continue
        \\    break
        \\  $blk: match i
        \\    0 => break $blk
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
    var lowered = try f.lower(a, tree, false);
    defer lowered.deinit();
    var nodes: std.ArrayList(Sexp) = .empty;
    defer nodes.deinit(a);
    try collect(a, tree, &nodes);
    const Want = struct { to: JumpDest.To, target: parser.Tag };
    const jumps = [_]Want{
        .{ .to = .step, .target = .@"while" }, // a `continue` from the body, to a step after it
        .{ .to = .exit, .target = .@"while" },
        .{ .to = .step, .target = .@"while" }, // to the continue expression
        .{ .to = .head, .target = .@"while" }, // from the condition of a loop with no step
        .{ .to = .head, .target = .@"for" }, // `continue $outer` from the inner loop's body
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
            try std.testing.expectEqual(steps[ns], lowered.stepOf(n).?.loop.step_point);
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
