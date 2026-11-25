//! Expression checking: the bodies of functions, methods, lambdas, and
//! tests.
//!
//! Two entry points drive everything:
//!
//!   synthExpr(e)            infer e's type from e alone
//!   checkExpr(e, expected)  check e against a type its context requires;
//!                           literals, `none`, `.variant`, generic
//!                           constructors, and branches take their type
//!                           from `expected`
//!
//! Both record the result in the facts table (`SemContext.recordType`),
//! and every identifier they resolve is recorded with its symbol.
//!
//! Compatibility (`compatible`): identical types; a literal where a
//! numeric type is expected; `none` where an optional is expected; any
//! `T` where `T?` or `T!` is expected (the value is lifted), and an
//! error value where `T!` is expected (the function fails); `!T` where
//! `?T` is expected; a view of a Copy value where the value is
//! expected (`readValue`), which reads through it (`Facts.reads`); and
//! anything where poison (`unknown` / `invalid`) is involved, so one
//! error does not cascade.
//!
//! Effects are checked in the same walk. Fallibility: a call of type
//! `T!` must be the operand of `!` or `catch`, and `!` needs a fallible
//! operand and a place to send the failure (`fail_to`). The raw
//! boundary: builtins outside the safe list and calls to `extern`
//! functions must be inside `raw`.
//!
//! Anything accepted here must be lowerable by emit. Constructs the
//! backend cannot express yet are rejected with a diagnostic that says
//! so rather than being passed through.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const diag = @import("diag.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");
const Wide = sema.Wide;
const resolve = @import("resolve.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const FunctionType = sema.FunctionType;
const SelfMode = sema.SelfMode;
const NominalContext = sema.NominalContext;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;

const identAt = sema.identAt;
const srcPos = sema.srcPos;
const BuiltinCheck = @import("check/builtins.zig");
const CallCheck = @import("check/calls.zig");
const ClosureCheck = @import("check/closures.zig");
const ExprCheck = @import("check/expr.zig");
const FlowCheck = @import("check/flow.zig");
const PatternCheck = @import("check/patterns.zig");
const StdFormCheck = @import("check/stdforms.zig");
const StmtCheck = @import("check/stmt.zig");
const ViewCheck = @import("check/views.zig");
const ApiCheck = @import("check/apis.zig");
const CompatCheck = @import("check/compat.zig");
const GenericCheck = @import("check/generics.zig");

/// What other passes use of the check files.
pub const FrameWalker = GenericCheck.FrameWalker;
pub const checkApiDecl = ApiCheck.checkApiDecl;
pub const checkApis = ApiCheck.checkApis;
pub const checkConformance = ApiCheck.checkConformance;
pub const checkDeclaredApis = GenericCheck.checkDeclaredApis;
pub const checkFrames = GenericCheck.checkFrames;
pub const checkGenericInstantiations = GenericCheck.checkGenericInstantiations;
pub const checkMethodCalls = GenericCheck.checkMethodCalls;
pub const checkStatedForwards = GenericCheck.checkStatedForwards;
pub const inlineFrame = GenericCheck.inlineFrame;
pub const max_inline_depth = GenericCheck.max_inline_depth;
pub const meets = CompatCheck.meets;
pub const recordFrameOwners = GenericCheck.recordFrameOwners;

pub fn checkModule(ctx: *SemContext, tree: Sexp, module_scope: ScopeId) Error!void {
    if (!tree.isKind(.module)) return;
    var c: Checker = .{
        .ctx = ctx,
        .scope = module_scope,
        .module_scope = module_scope,
        .body = .{ .ret = ctx.types.void_id },
        .tree = tree,
    };
    defer c.deinit();
    try StdFormCheck.placePanics(&c, tree, .value);
    for (ctx.const_order.items) |*decl| try c.checkRewritten(decl, Checker.checkDecl, .{});
    // A compile-time function was checked before the constants that call
    // it (`resolve.ensureCtFun`, `checkCtFun`).
    for (ir.Module.decls(tree)) |*decl| if (!rig.isModuleConst(decl.*) and !rig.isCtFun(decl.*)) try c.checkRewritten(decl, Checker.checkDecl, .{});
    for (ir.Module.decls(tree)) |decl| if (!rig.isCtFun(decl)) try ViewCheck.checkViewBases(&c, decl, decl, false, true);
}

/// Check the body of compile-time function `decl` as any function body
/// is typed, ahead of the module's other bodies: its parameters are
/// values the evaluator knows, so a compile-time call in it may take any
/// argument (`Checker.in_ct_fun`).
pub fn checkCtFun(ctx: *SemContext, decl: Sexp) Error!void {
    var c: Checker = .{
        .ctx = ctx,
        .scope = sema.module_scope,
        .module_scope = sema.module_scope,
        .body = .{ .ret = ctx.types.void_id },
        .in_ct_fun = true,
    };
    defer c.deinit();
    try StdFormCheck.placePanics(&c, decl, .value);
    try c.checkRewritten(&decl, Checker.checkDecl, .{});
    try ViewCheck.checkViewBases(&c, decl, decl, false, true);
}

/// Each group of a function or a method the module declares, `..net:
/// Net` (docs/design/options.md), checked (`Checker.checkGroups`) and,
/// when it holds, made the parameters it means, before any body is
/// checked (`rig.Parser.flattenGroups`): its fields' parameters are
/// declared, and the function's signature resolved again
/// (`resolve.resolveFlattened`). Its uses in the body are rewritten
/// where typecheck finds them (`Checker.checkRewritten`).
pub fn flattenGroups(ctx: *SemContext, tree: Sexp) Error!void {
    if (!tree.isKind(.module)) return;
    const p = ctx.parser orelse return;
    var c: Checker = .{
        .ctx = ctx,
        .scope = sema.module_scope,
        .module_scope = sema.module_scope,
        .body = .{ .ret = ctx.types.void_id },
        .tree = tree,
    };
    defer c.deinit();
    var sites: std.ArrayList(rig.GroupSite) = .empty;
    defer sites.deinit(ctx.allocator);
    var flat: std.ArrayList(rig.Parser.Flattened) = .empty;
    defer flat.deinit(ctx.allocator);
    for (ir.Module.decls(tree)) |decl| {
        const d = rig.unpub(decl);
        switch (d.kind() orelse continue) {
            .fun, .sub => if (hasGroup(d)) try c.flattenIn(p, d, sema.symbol_invalid, &sites, &flat),
            .@"struct", .@"enum", .generic_struct, .generic_enum => {
                const any = for (ir.rest(d, .members)) |m| {
                    if ((m.isKind(.fun) or m.isKind(.sub)) and hasGroup(m)) break true;
                } else false;
                if (!any) continue;
                const sym = ctx.symbolOf(ir.get(d, .name)) orelse continue;
                const prev = c.nominal;
                c.nominal = try sema.makeNominalContext(ctx, sym);
                defer c.nominal = prev;
                for (ir.rest(d, .members)) |m| if (m.isKind(.fun) or m.isKind(.sub)) try c.flattenIn(p, m, sym, &sites, &flat);
            },
            else => {},
        }
    }
    if (flat.items.len > 0) try resolve.fillGroupDefaults(ctx);
}

/// Whether function `def` declares a group among its parameters.
pub fn hasGroup(def: Sexp) bool {
    const params = ir.get(def, .params);
    if (params != .list) return false;
    for (params.items()) |p| if (p.isKind(.group_param)) return true;
    return false;
}

/// Where a binding that cannot be written got its value: a loop element
/// or `as` binding copied from a place, or a match binding of a field of
/// the place a bare match copies (`match_copy`) or a `?` match reads
/// (`match_read`).
pub const CopySource = struct {
    place: Sexp,
    kind: enum { loop, as, match_copy, match_read },
    whole: bool = false,
    /// For a binding of `s matches .circle(r)`, its pattern, which the advice
    /// to write through it names.
    pattern: Sexp = .nil,
};

/// How a match reaches its subject: `match e` and `match ?e` read it,
/// `match !e` writes its fields in place, and `match <e` consumes it.
pub const MatchMode = enum { read, write, consume };

pub const Checker = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,
    expect: Expect = .{},
    /// The module's tree, where a group's type declared here is found
    /// (`groupSite`).
    tree: Sexp = .nil,
    /// The function being checked has a group as written, whose field
    /// reads its body records (`synthMember`).
    in_group_body: bool = false,
    /// The function, method, closure, test, or drop body being checked.
    body: Body,
    nominal: NominalContext = NominalContext.none,
    /// The APIs the module declares and imports, found once
    /// (`visibleApis`).
    visible_apis: ?[]const sema.ApiRef = null,
    /// The compile-time parameters of its own and their arguments, of the
    /// instance the last `instantiateCall` made; empty for a function that
    /// has none (`noteTarget`).
    inst_own: TypeSubst = .empty,
    /// The compile-time slot each of `inst_own`'s parameters fills
    /// (`sema.ownParamOf`), which a call through an API records
    /// (`sema.ApiCall.slots`).
    inst_slots: []const u32 = &.{},
    /// The string literals found to be a byte or bytes (`byteString`) in
    /// the statements being checked under a mark (`checkRewritten`), each
    /// checked again with them rewritten; `rewrites_open` of them.
    bytes: std.ArrayList(rig.ByteLiteral) = .empty,
    /// The chains found so (`chainCall`).
    chains: std.ArrayList(rig.Chain) = .empty,
    /// The uses of groups made parameters (`noteGroupUse`), and the
    /// spreads (`recordSpread`), found in the module's declaration being
    /// checked, which is checked again with them rewritten
    /// (`checkRewritten`); and the groups whose uses stay as written,
    /// since the body writes one, which is refused.
    group_uses: std.ArrayList(rig.GroupUse) = .empty,
    spreads: std.ArrayList(rig.SpreadSite) = .empty,
    refused: std.AutoHashMapUnmanaged(u32, void) = .empty,
    rewrites_open: u32 = 0,
    /// Enclosing `raw` blocks.
    raw_depth: u32 = 0,
    /// The locals that hold a task given a write view, each moved only
    /// into its own wait, `>t`, or `<t.cancel()`.
    write_tasks: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// A binding that never changes whose value is a plain enum's
    /// variant the checker knows, by name (`constVariant`).
    fixed_variants: std.AutoHashMapUnmanaged(SymbolId, []const u8) = .empty,
    /// The chains whose result holds views of the items of their source,
    /// each a consumer's call to the source it walks and the source's
    /// type, learned by a quiet check (`chainSource`, `chainTypes`).
    chain_views: std.AutoHashMapUnmanaged(parser.NodeId, struct { root: Sexp, ty: TypeId }) = .empty,
    /// The binding conditions whose `else` is being checked, innermost
    /// last: a name one binds is unbound there (`unboundHint`).
    else_conds: std.ArrayList(Sexp) = .empty,
    /// A read match's binding whose subject has no storage, `copied_from`
    /// records none for: the subject, for the hint that names the match
    /// that writes (`readMatchHint`).
    read_subjects: std.AutoHashMapUnmanaged(SymbolId, CopySource) = .empty,
    /// Each `break` and `continue` that names a construct being checked,
    /// and that construct (`sema.eachJumpTo`), recorded as the construct
    /// is entered (`enterFrame`).
    jump_targets: std.AutoHashMapUnmanaged(parser.NodeId, Sexp) = .empty,
    /// Where each `panic` of a body stands (`placePanics`); one absent
    /// stands where a value is needed.
    panic_places: std.AutoHashMapUnmanaged(parser.NodeId, PanicPlace) = .empty,
    /// The types inference found for arguments (`argType`).
    arg_types: std.AutoHashMapUnmanaged(parser.NodeId, TypeId) = .empty,
    /// What typing found that the walk over paths reads
    /// (`checkViewBases`): the members a call resolved as a method, with
    /// how it takes its self and what it returns; the type each
    /// expression was checked against; the values that are a function's,
    /// a closure's, or a block's last value, which are used; and the
    /// view each path's object is (`viewOf`).
    methods: std.AutoHashMapUnmanaged(parser.NodeId, MethodFact) = .empty,
    expected: std.AutoHashMapUnmanaged(parser.NodeId, TypeId) = .empty,
    value_tails: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    view_of: std.AutoHashMapUnmanaged(parser.NodeId, ?Sexp) = .empty,
    /// Whether a view of each branch (`?(a if c else b)`, or a path from
    /// one) may stand (`viewsBranch`), decided once.
    branch_views: std.AutoHashMapUnmanaged(parser.NodeId, bool) = .empty,
    /// A loop element or `as` binding that copies from a place: the
    /// place, named when the binding is written (`checkBindingWritable`).
    copied_from: std.AutoHashMapUnmanaged(SymbolId, CopySource) = .empty,
    /// The element and index bindings of `for x, i in xs`, each mapped
    /// to both, for the hint on a loop written index first.
    loop_pairs: std.AutoHashMapUnmanaged(SymbolId, LoopPair) = .empty,
    /// The bindings of a `match <x` arm: each owns what it binds.
    owned_bindings: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Inside `argType`, whose argument the call checks again with the
    /// type it is expected to have: the generic instances found there
    /// are not recorded.
    tentative: u32 = 0,
    /// The declaration's position of the method being checked, of a
    /// generic type, an addition, or an API's default, which Zig compiles
    /// only where the program reaches it (`sema.BodyReach`); `no_body`
    /// elsewhere, and in a method called without a call written: a
    /// `drop`, or one that gives a built-in API its meaning.
    body_pos: u32 = sema.no_body,
    /// The body being checked is a compile-time function's
    /// (`checkCtFun`): a compile-time call there is run by the evaluator,
    /// which knows every value, so its arguments may be any expression.
    in_ct_fun: bool = false,
    /// Generic calls whose result gives a type parameter that only
    /// literal arguments gave a type (`max(1, 2)`, `parse(true, 1)!`), with
    /// that literal type, or an optional nothing gave a type
    /// (`nothing()`, `id(none)`), as `none`: as an argument, such a call
    /// binds like the literal or `none` (`literalResult`).
    literal_results: std.AutoHashMapUnmanaged(parser.NodeId, LiteralResult) = .empty,
    /// Generic calls whose arguments give a type parameter another type
    /// than the one the result is expected to have: what to write instead.
    result_hints: std.AutoHashMapUnmanaged(parser.NodeId, []const u8) = .empty,

    /// How a call's value reaches the type parameter its result gives:
    /// the result is `T`, a `T!` propagated with `!`, or a `T?` with `?`.
    pub const ResultPath = enum { direct, propagate, propagate_none };
    pub const LiteralResult = struct { ty: TypeId, path: ResultPath };

    pub const Body = struct {
        /// Type `return` values must have; `unknown` while a closure's
        /// return type is inferred.
        ret: TypeId,
        is_sub: bool = true,
        /// Where a `!` in the code being checked sends its failure.
        fail_to: FailTarget = .module,
        /// The `return`s of the closure whose return type is inferred.
        returns: ?*std.ArrayList(ReturnSite) = null,
        /// The name of the `fun` or `sub` being checked, for messages.
        name: Sexp = .nil,
        /// The loops and labeled blocks around the code being checked,
        /// innermost first: what a `break` or `continue` names
        /// (`resolveJump`).
        loops: ?*LoopFrame = null,
        /// A closure's body, or code inside one: a jump there cannot leave
        /// a loop around the closure.
        in_closure: bool = false,
        /// A test's body, where `return` gives the `Bool` that decides it.
        in_test: bool = false,
    };

    pub const LoopFrame = struct {
        label: []const u8,
        /// The construct a jump to this frame names: a `while` or `for`,
        /// or a labeled block's `match` or `raw` block.
        node: Sexp,
        /// False for a labeled block, which only `break $label` leaves.
        is_loop: bool = true,
        /// The part of the loop being checked, which decides where a
        /// `continue` from it goes.
        part: LoopPart = .body,
        /// A `while` with a step.
        has_step: bool = false,
        /// The `continue`s in a `while`'s condition, whose destination the
        /// step's point decides (`settleConditionJumps`).
        cond_continues: std.ArrayList(Sexp) = .empty,
        /// The value of a loop used as one.
        value: ?*LoopValue = null,
        parent: ?*LoopFrame,
    };

    /// The part of a loop being checked. A `for` source runs before the
    /// loop is entered, so a jump there names the loop around it.
    pub const LoopPart = enum { source, cond, step, body };

    /// A member a call resolved as a method: how it takes its self,
    /// and what it returns.
    pub const MethodFact = struct { self_mode: sema.SelfMode, returns: TypeId };

    /// A loop used as a value: its `break` values and its `else` value.
    pub const LoopValue = struct {
        expected: ?TypeId,
        /// The type the values settle on, without `expected`.
        ty: ?TypeId = null,
        values: std.ArrayList(Typed) = .empty,
    };

    /// A branch, arm, or `break` value and the type it synthesized.
    pub const Typed = struct { node: Sexp, ty: TypeId };

    pub const ReturnSite = struct { node: Sexp, ty: ?TypeId };

    /// What the node being checked stands in, which its context sets for
    /// the check below it and puts back after: one value, saved and put
    /// back whole or by field (docs/internals/INTERNALS.md, "Typecheck's
    /// context").
    pub const Expect = struct {
        /// The position of a name that is the object of a field read or a
        /// spread's operand being checked: a group's name there reads its
        /// fields, not the group whole (`noteGroupUse`).
        group_member: u32 = std.math.maxInt(u32),
        /// Callee node of the method call being checked; its resolved
        /// signature is recorded as the node's type. Each call starts with
        /// none (`synthCall`), so a call in an argument never records its
        /// signature on the callee of the call around it.
        callee_node: ?Sexp = null,
        /// The call being checked, for its argument-slot fact.
        current_call: ?Sexp = null,
        /// A std maker's call left fallible by an argument that is not a
        /// constant (`constMakerCall`), and that argument: the error that
        /// asks for its `!` names it.
        /// `literal` when the maker takes a plain string literal
        /// (`TimeZone.named`), so the error says that is what it lacks.
        maker_runtime: struct { call: Sexp = .nil, arg: Sexp = .nil, literal: bool = false } = .{},
        /// The `for` whose source is being checked, which a chain of stages
        /// may be (`chainCall`).
        chain_for: Sexp = .nil,
        /// The `new x` binding whose value is being checked: not visible yet.
        pending: SymbolId = sema.symbol_invalid,
        /// The names `new q, r = f()` declares, while its call is checked.
        pending_names: []const SymbolId = &.{},
        /// The operand of the `!` or `catch` being checked: a fallible call
        /// there is handled.
        handled: Sexp = .nil,
        /// The operand of the `*x` being checked.
        shared_operand: Sexp = .nil,
        /// The value and target of the binding of a name being checked
        /// (`t = f(!x)&`), where a task given a write view may stand.
        local_value: Sexp = .nil,
        local_target: Sexp = .nil,
        /// The task a wait, `>t`, or a `<t.cancel()` being checked takes.
        task_wait: Sexp = .nil,
        /// The value of the object or enum field, or the field default, being
        /// checked: a value holding a Cell may be made there (`cellMadeAway`).
        cell_home: Sexp = .nil,
        /// The object of the member, method call, or view being checked: a
        /// branch there is read in place, by address, never copied
        /// (`cellMadeAway`).
        in_place: Sexp = .nil,
        /// How the element `index_use.at` is used (`indexUse`), so the error
        /// for a type with no index names the form that fits that use.
        index_use: IndexUse = .{},
        /// The member pattern being checked, `E.name =>`, which tests the
        /// member whether or not it has fields.
        member_pattern: Sexp = .nil,
        /// The operand of the `return` being checked: an error value meets a
        /// `T!` only in its branch leaves (`isReturnLeaf`).
        return_operand: Sexp = .nil,
        /// The expression statement being checked, whose value is
        /// discarded (`isDiscardedCall`).
        discarded: Sexp = .nil,
        /// `discarded` is the value of `_ =`, which drops it by name.
        discard_named: bool = false,
        /// The last line of the test being checked: a `Bool` there is the
        /// test's value, which decides it (`checkExprStmt`).
        test_tail: Sexp = .nil,
        /// The call that gives several results where they may stand: the
        /// value of a destructure, of `return` in a function that gives
        /// them, or of `if ... as a, b` (docs/internals/INTERNALS.md, "Several
        /// results"). Any other such call is reported (`misplacedResults`).
        results_ok: Sexp = .nil,
        /// The type of the result the `result_part` being checked takes:
        /// a destructure's target binds it as `x = e` binds `e`.
        part_ty: TypeId = sema.type_invalid,
        /// The value of the single binding being checked, and the call it
        /// is, for the hint that binds each of several results.
        bound_value: Sexp = .nil,
        bound_call: Sexp = .nil,
        /// The last line of a function that gives several results, which
        /// gives them with `return`.
        results_tail: Sexp = .nil,
        /// The call `if c as x` binds one name of, for the hint that binds
        /// each of several results.
        as_call: Sexp = .nil,
        /// The name an assignment re-binds while its value is checked, when
        /// that name holds a `Static` (`staticHint`).
        static_target: []const u8 = "",
        static_target_value: Sexp = .nil,
        /// The `!x` being checked where a write view is expected, the one
        /// place a write view of a `Bool` is not read as its value.
        viewed_write: Sexp = .nil,
        /// Whether a view of a handle that changes by a marked call skips the
        /// writability checks (`handleWritable` turns it off).
        handle_exempt: bool = true,
        /// The self of the method call being checked, while it is typed.
        self_obj: Sexp = .nil,
        /// The operand of the `not` being checked, which must be a `Bool`.
        not_operand: Sexp = .nil,
        /// The `and` or `or` being checked, and its operands, which must be
        /// `Bool`s.
        logic_op: []const u8 = "",
        logic_operands: [2]Sexp = .{ .nil, .nil },
        /// The condition of the `if` value being checked.
        ternary_cond: Sexp = .nil,
        /// The condition being checked whose `and` chain narrows, at a
        /// `$plain(T)` operand, what runs once the test has held
        /// (`sema.PlainRegion`).
        plain_cond: ?PlainCond = null,
        /// A call whose value a `!` written before it makes a write view of,
        /// with the sigil outside the call (`!(v.pop())`, `!o?.pop()`): a write
        /// method on a temporary self there has a `!` that does not reach it.
        outer_write: Sexp = .nil,
        /// The member a method call is checked through, while its self
        /// mode is checked.
        self_of: Sexp = .nil,
        /// The argument being checked, when the call keeps no view of its
        /// arguments: a temporary array there may be viewed as a `[]T`.
        viewed_temp: Sexp = .nil,
        /// The argument being checked, or a generic call's type parameters
        /// inferred from: a bare value there is passed as a read view where a
        /// view is expected (`viewByRows`), and a slice there as `?xs[a..b]`
        /// would be (`synthSlice`).
        view_arg: Sexp = .nil,
        /// The template whose context takes its value (`synthTemplate`): an
        /// unannotated binding's, or one where a `String` or `?String` goes.
        template_ok: Sexp = .nil,
        /// The template whose context takes it as fixed text when its slots
        /// are constant (`templateFolds`): where a `?String` or a `Static`
        /// goes, or a module's constant.
        template_fixed: Sexp = .nil,
        /// The parameter or field the argument being checked fills, which a
        /// diagnostic names (`ignoredWriteView`).
        slot: Slot = .{},
        /// A construction a field of which `writeViewRead` rejected: its own
        /// type, built without the view, is not reported again.
        ignored_in: Sexp = .nil,
        /// The value a header makes and holds for its construct, of which
        /// its subject is a part (`Header.held`): it is no temporary of the
        /// header.
        held_base: Sexp = .nil,
        /// The arms of a read `match` whose subject emit matches as a copy
        /// (not `storage.matchesInPlace`) are being bound: a binding that is
        /// no plain data views that copy, so it is usable within its arm only
        /// (`SymbolFlags.arm_view`).
        arm_local: bool = false,
        /// The `match` whose arms are being checked.
        matching: Sexp = .nil,
        /// The access `loopElement` decided for the element binding of the
        /// `for` being checked, which `checkFor` records.
        loop_access: ?sema.Access = null,
        /// A condition is being checked where nothing it makes can be held
        /// for the construct: a `while`'s, which runs again each iteration,
        /// a joined one, whose later parts may use earlier bindings, and a
        /// value `if`'s.
        no_hold: bool = false,
        /// The argument being checked, where a closure literal may be passed
        /// as a callable view, and the call when its result could hold
        /// the literal instead.
        viewed_callable: Sexp = .nil,
        callable_kept: Sexp = .nil,
        /// Set by a caller of `checkArgs` whose call may take a temporary
        /// array as a `[]T` argument (a function or method, not a closure),
        /// with a method's self parameter.
        view_call: bool = false,
        view_recv: ?TypeId = null,
        /// Checking an expression where a rejected type is expected, or an
        /// argument of a call that cannot be checked: a size it would have is
        /// not reported.
        under_poison: bool = false,
        /// The label, and the value when it is used as one, of the loop
        /// about to be checked.
        loop_label: []const u8 = "",
        loop_value: ?*LoopValue = null,
        /// The call whose value goes where a `ty` is expected (`checkExpr`),
        /// directly or through `!`, `?`, `catch`, or `??` (`resultCall`):
        /// inference binds the type parameters its arguments leave open from
        /// `ty`. `value` is the expression checked, the call or what wraps
        /// it.
        result_expected: struct { call: Sexp = .nil, ty: TypeId = sema.type_invalid, value: Sexp = .nil } = .{},
        /// The operand of an arithmetic or comparison operator being
        /// synthesized, beside `other`, whose type is `ty` once known: where
        /// a call on a type parameter takes its type (`typeParamResult`).
        beside: struct { node: Sexp = .nil, other: Sexp = .nil, ty: ?TypeId = null } = .{},
        /// Inside `noteTakeable`'s trial of a take, which only asks whether
        /// `<e` would be accepted: `requireAccess` records nothing.
        trial_take: bool = false,
    };

    pub const FailTarget = union(enum) {
        /// The caller: in a `fun ...() -> T!`, a `sub ...()!`, `sub main()`, or a test.
        caller,
        /// A `fun` or `sub` that cannot fail; its name.
        infallible: Sexp,
        closure,
        deferred,
        drop,
        /// Module-level code, which is rejected on its own.
        module,
    };

    pub fn deinit(self: *Checker) void {
        const a = self.ctx.allocator;
        self.bytes.deinit(a);
        self.chains.deinit(a);
        self.group_uses.deinit(a);
        self.spreads.deinit(a);
        self.refused.deinit(a);
        self.arg_types.deinit(a);
        self.methods.deinit(a);
        self.expected.deinit(a);
        self.value_tails.deinit(a);
        self.chain_views.deinit(a);
        self.view_of.deinit(a);
        self.branch_views.deinit(a);
        self.copied_from.deinit(a);
        self.read_subjects.deinit(a);
        self.loop_pairs.deinit(a);
        self.owned_bindings.deinit(a);
        self.literal_results.deinit(a);
        self.result_hints.deinit(a);
        self.jump_targets.deinit(a);
        self.panic_places.deinit(a);
        self.else_conds.deinit(a);
    }

    pub fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.err(pos, fmt, args);
    }

    pub fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.note(pos, fmt, args);
    }

    pub fn errAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.errAt(node, fmt, args);
    }

    pub fn noteAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.noteAt(node, fmt, args);
    }

    /// Where a node starts in the source.
    pub fn startOf(self: *Checker, node: Sexp) u32 {
        return self.ctx.startOf(node);
    }

    pub fn tyName(self: *Checker, ty: TypeId) Error![]const u8 {
        return sema.formatType(self.ctx, ty);
    }

    pub fn text(self: *Checker, node: Sexp) []const u8 {
        return identAt(self.ctx.source, node) orelse "";
    }

    /// Make the scope `node` opened current; returns the previous scope.
    pub fn enter(self: *Checker, node: Sexp) ScopeId {
        const prev = self.scope;
        if (self.ctx.scopeOf(node)) |s| self.scope = s;
        return prev;
    }

    pub fn resolver(self: *Checker) resolve.TypeResolver {
        return .{ .ctx = self.ctx, .scope = self.scope, .nominal = self.nominal, .body = StdFormCheck.bodyRef(self) };
    }

    pub fn t(self: *Checker) *sema.TypeStore {
        return self.ctx.types;
    }

    pub fn isPoison(self: *Checker, ty: TypeId) bool {
        return ty == self.ctx.types.unknown_id or ty == self.ctx.types.invalid_id;
    }

    // =========================================================================
    // Declarations
    // =========================================================================

    pub fn checkDecl(self: *Checker, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return self.errAt(sexp, not_at_module_level, .{})) {
            .@"pub" => try self.checkDecl(ir.Pub.decl(sexp)),
            .fun, .sub => {
                const fn_ty = if (self.ctx.symbolOf(ir.get(sexp, .name))) |id| self.ctx.symbols.items[id].ty else self.t().invalid_id;
                try self.checkFunction(sexp, fn_ty);
            },
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => try self.checkNominal(sexp),
            .error_join => try self.checkErrorJoin(sexp),
            .@"test" => {
                try ExprCheck.checkEscapes(self, ir.Test.name(sexp));
                const prev_scope = self.enter(sexp);
                defer self.scope = prev_scope;
                // A test fails by returning an error, which `rig test`
                // reports, or by giving `false`: from its last line, or
                // from a `return`.
                const body = ir.Test.body(sexp);
                const saved_tail = self.expect.test_tail;
                defer self.expect.test_tail = saved_tail;
                self.expect.test_tail = CompatCheck.lastStmt(body);
                try self.checkBody(body, .{ .ret = self.t().void_id, .fail_to = .caller, .in_test = true });
            },
            .set => try self.checkModuleConst(sexp),
            .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_const => {},
            .api => try self.checkApiDefaults(sexp),
            .api_add => try self.checkAddMethods(sexp),
            .zig_extern => for (ir.ZigExtern.decls(sexp)) |d| {
                try self.checkMarkedView(d);
                try self.checkDecl(d);
            },
            else => try self.errAt(sexp, not_at_module_level, .{}),
        }
    }

    /// The standard library's `extern zig` functions that take a value
    /// that changes by a marked call, each read to keep the premise of
    /// Core §4 in Zig the checkers do not see: the value is never replaced
    /// whole, and every view it gave out lasts while a handle to it lives,
    /// so the function moves and frees nothing a view may see, and any
    /// view it gives is of such memory. `shared.Map`'s entries never move,
    /// and are freed only when the map drops (std/shared.zig).
    pub const marked_externs = [_][]const u8{ "std.shared.find", "std.shared.holds", "std.shared.insert", "std.shared.settle", "std.shared.count" };

    /// An `extern zig` function `d` that takes a value that changes by a
    /// marked call (`sema.changesByMark`), through a view, a handle, or a
    /// box (`sema.unwrapAccess`), or whose result may view a parameter of
    /// a type parameter's or an API object's type, which may be one, must
    /// be one of `marked_externs`.
    pub fn checkMarkedView(self: *Checker, d: Sexp) Error!void {
        const f = if (d.isKind(.@"pub")) ir.Pub.decl(d) else d;
        if (!f.isKind(.fun) and !f.isKind(.sub)) return;
        const name_node = ir.get(f, .name);
        const id = self.ctx.symbolOf(name_node) orelse return;
        const sym = self.ctx.symbols.items[id];
        const fn_ty = switch (self.ctx.types.get(sym.ty)) {
            .function => |ft| ft,
            else => return,
        };
        const result = switch (self.ctx.types.get(fn_ty.returns)) {
            .fallible => |fl| fl.ok,
            else => fn_ty.returns,
        };
        const gives_view = sema.mayHoldView(self.ctx, result);
        const marked = for (fn_ty.params, 0..) |param, i| {
            const value = sema.unwrapAccess(self.ctx, param);
            if (sema.changesByMark(self.ctx, value)) break value;
            const viewed = i < 64 and (sym.origins.result >> @intCast(i)) & 1 != 0;
            switch (self.ctx.types.get(value)) {
                .type_var, .api_object => if (gives_view and viewed) break value,
                else => {},
            }
        } else return;
        const name = identAt(self.ctx.source, name_node) orelse return;
        const full = try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ self.ctx.name, name });
        for (marked_externs) |listed| if (std.mem.eql(u8, listed, full)) return;
        try self.errAt(name_node, "`{s}` takes a `{s}`, which may change by marked calls, in Zig the checkers do not see: it must move and free nothing a view of it may see, and give only views of such memory (Core §4); read its Zig, then list `{s}` in `Checker.marked_externs`", .{ name, try self.tyName(marked), full });
    }

    /// A module-level binding is a constant, `name = value`: its value
    /// is known at compile time and owns nothing, so no function can
    /// change it and nothing has to release it.
    pub fn checkModuleConst(self: *Checker, node: Sexp) Error!void {
        const target = ir.Set.target(node);
        if (target != .src) return self.errAt(node, not_at_module_level, .{});
        if (rig.bindingKindOf(ir.Set.op(node)) != .fixed) {
            if (self.ctx.symbolOf(target)) |id| if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                (try self.ctx.symbolMut(id)).ty = self.t().invalid_id;
            };
            return self.errAt(node, "a module-level binding is a constant; write `{s} = value`", .{self.text(target)});
        }
        try StmtCheck.checkSet(self, node);
        const value = ir.Set.value(node);
        if (self.isPoison(self.ctx.typeOf(target) orelse self.t().invalid_id)) return;
        // A vector made of constants, `Simd[U8, 16](array)` or
        // `Simd[U8, 16].splat(x)` (or through an alias of the type), is a
        // module constant's whole value: it is a Zig `var` (`emitConst`),
        // and an array or a branch holding one would be known to Zig.
        const vector = value.isKind(.call) and self.isVectorMade(value) and self.isConstExpr(ir.Call.args(value)[0]);
        if (!vector and !self.isConstExpr(value)) {
            try self.errAt(value, "a module-level constant needs a value known at compile time: a literal, `.variant`, a constant, or operators, ternaries, and arrays over them, or a vector of them (`Simd[T, n](array)`, `Simd[T, n].splat(x)`)", .{});
            return;
        }
        try self.checkConstArithmetic(value);
    }

    /// A module constant's integer arithmetic is checked here, when Rig
    /// computes it (`sema.cteval.foldInt`): Zig would compute it again when it
    /// compiles, and stop at an overflow or a division by zero. So each
    /// operand is a value Rig knows; one the target sets, or a constant
    /// branching on something Rig does not compute, is rejected.
    pub fn checkConstArithmetic(self: *Checker, e: Sexp) Error!void {
        if (e != .list) return;
        if (!CompatCheck.isArithmetic(e)) {
            for (e.items()) |c| try self.checkConstArithmetic(c);
            return;
        }
        const ty = self.ctx.typeOf(e) orelse return;
        if (!sema.isInteger(self.ctx, ty) and ty != self.t().int_literal_id) return;
        if (sema.cteval.constInt(self.ctx, e) != .not_constant) return;
        const operand = self.unknownOperand(e) orelse return;
        if (try self.perTarget(operand, "the operands of a module constant's arithmetic")) return;
        try self.errAt(operand, "the operands of a module constant's arithmetic must be values Rig computes when it checks the program, and it does not compute `{s}`; branch on integers, or write each branch's value", .{CallCheck.sourceText(self, operand)});
    }

    /// The first operand of the arithmetic `e`, outside further
    /// arithmetic, whose value Rig does not compute; null when each has
    /// one (and `e` has none for another reason, reported elsewhere).
    pub fn unknownOperand(self: *Checker, e: Sexp) ?Sexp {
        const pair = if (e.isKind(.neg)) [2]Sexp{ ir.Neg.operand(e), .nil } else [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
        for (pair) |o| {
            if (o == .nil) continue;
            if (CompatCheck.isArithmetic(o)) {
                if (self.unknownOperand(o)) |x| return x;
            } else if (sema.cteval.constInt(self.ctx, o) == .not_constant) return o;
        }
        return null;
    }

    /// Report that `node`, needed as `what`, names a value the target
    /// sets (`sema.perTargetLeaf`); false when it names none.
    pub fn perTarget(self: *Checker, node: Sexp, what: []const u8) Error!bool {
        const leaf = sema.perTargetLeaf(self.ctx, node) orelse return false;
        try self.errAt(node, "{s} must be known when Rig checks the program; " ++ sema.per_target_why, .{ what, CallCheck.sourceText(self, leaf) });
        return true;
    }

    pub fn isConstExpr(self: *Checker, e: Sexp) bool {
        if (e.isKind(.array)) {
            for (ir.Array.elems(e)) |x| if (!self.isConstExpr(x)) return false;
            return true;
        }
        if (e.isKind(.array_fill)) return self.isConstExpr(ir.ArrayFill.value(e));
        // A ternary `a if c else b` over constants.
        if (e.isKind(.@"if")) return self.isConstExpr(ir.If.cond(e)) and self.isConstExpr(ir.If.then(e)) and self.isConstExpr(ir.If.@"else"(e));
        return CallCheck.isComptimeKnown(self, e);
    }

    /// A call that makes a vector of its one argument: `Simd[T, n](a)`,
    /// `Block(a)` for an alias `Block` of a vector type, or `.splat(x)` of
    /// either.
    pub fn isVectorMade(self: *Checker, call: Sexp) bool {
        const ty = self.ctx.typeOf(call) orelse return false;
        if (self.ctx.types.get(ty) != .simd or ir.Call.args(call).len != 1) return false;
        const callee = ir.Call.callee(call);
        if (self.ctx.elemCallOf(callee)) |ec| return ec.op == .splat;
        const named = if (rig.isBracketList(callee)) ir.get(callee, .object) else callee;
        if (named != .src) return false;
        const id = self.ctx.symbolOf(named) orelse CallCheck.lookupQuiet(self, named) orelse return false;
        return if (rig.isBracketList(callee)) self.ctx.ref(id) == self.ctx.builtins.simd else self.ctx.symbols.items[id].kind == .type_alias;
    }

    pub const not_at_module_level = "only declarations and bindings are allowed at module level; move this statement into a function";

    /// The fields of error set `sym`'s members: each field's type holds no
    /// loan, holds no `*` or `~` handle, and clones, so an error never
    /// limits an owner, goes to any task, and drops without running a
    /// `drop` body (CORE, "A failure moves its error").
    pub fn checkErrorFields(self: *Checker, sym: SymbolId, fields: []const sema.Field) Error!void {
        const self_ty = try self.ctx.intern(.{ .nominal = self.ctx.ref(sym) });
        for (fields) |f| {
            if (!f.is_variant) continue;
            // Whether the member's fields compare and hash, which the
            // glue reads.
            var compares: sema.MemberCompares = .{ .eq = true, .hash = true };
            for (f.payload orelse &.{}) |p| {
                if (self.isPoison(p.ty)) continue;
                if (try sema.notEquatable(self.ctx, p.ty, null) != null) compares.eq = false;
                if (try sema.notHashable(self.ctx, p.ty, null) != null) compares.hash = false;
            }
            if (f.payload != null and f.payload.?.len > 0) try self.ctx.recordMemberCompares(f, compares);
            for (f.payload orelse &.{}) |p| {
                if (self.isPoison(p.ty)) continue;
                const shown = try self.tyName(p.ty);
                if (p.ty == self.t().any_error_id or p.ty == self_ty) {
                    try self.err(p.decl_pos, "a member holding `{s}` contains itself: write `^{s}`", .{ shown, shown });
                } else if (sema.isErrorSet(self.ctx, p.ty) and sema.setHasFields(self.ctx, p.ty)) {
                    // Every error with fields is held in room for the
                    // program's largest member, so one held inline would
                    // hold itself.
                    try self.err(p.decl_pos, "a member holding `{s}`, whose members have fields, holds it boxed: write `^{s}`", .{ shown, shown });
                } else if (sema.mayHoldView(self.ctx, p.ty)) {
                    try self.err(p.decl_pos, "an error's field never holds a view: hold a `String` or a `Static`", .{});
                } else if (sema.holdsHandle(self.ctx, p.ty)) {
                    // An API object's hidden value may hold a handle.
                    const why = if (sema.mentionsObject(self.ctx, p.ty)) "may hide a handle, its type erased" else "shares what it holds";
                    try self.err(p.decl_pos, "an error's field holds no handle: `{s}` {s}, and an error owns what it carries", .{ shown, why });
                } else if (sema.cloneable(self.ctx, p.ty) == .no) {
                    const why = if (sema.isUnique(self.ctx, p.ty)) "is unique" else "has no clone";
                    try self.err(p.decl_pos, "an error's fields must clone, and `{s}` {s}", .{ shown, why });
                }
            }
        }
    }

    /// `error L = A | B`: no part joins `L` again, directly or through
    /// another union, so `L` stands for a finite list of sets.
    pub fn checkErrorJoin(self: *Checker, node: Sexp) Error!void {
        const name = ir.ErrorJoin.name(node);
        const sym = self.ctx.symbolOf(name) orelse return;
        const self_ty = try self.ctx.intern(.{ .nominal = self.ctx.ref(sym) });
        for (ir.ErrorJoin.members(node)) |m| {
            const shown = if (m == .src) self.text(m) else try ViewCheck.plainText(self, m);
            try self.errAt(m, "a union of error sets lists no members of its own; declare a set for `{s}` and join it", .{shown});
        }
        const parts = self.ctx.symbols.items[sym].error_parts orelse return;
        for (ir.ErrorJoin.parts(node).items(), 0..) |part_node, i| {
            if (i >= parts.len) break;
            const part = parts[i];
            if (part == self_ty) {
                try self.errAt(part_node, "`{s}` joins itself: a union joins other sets", .{self.text(name)});
                continue;
            }
            if (sema.isErrorUnion(self.ctx, part) and try self.unionReaches(part, sym, 0)) {
                try self.errAt(part_node, "`{s}` joins itself through `{s}`: a union joins other sets", .{ self.text(name), try self.tyName(part) });
            }
        }
    }

    /// Whether union `ty` joins union `target` of this module, at any
    /// depth.
    pub fn unionReaches(self: *Checker, ty: TypeId, target: SymbolId, depth: u32) Error!bool {
        if (depth > 32) return true;
        const d = sema.nominalDecl(self.ctx, ty) orelse return false;
        const parts = d.symbol().error_parts orelse return false;
        for (parts) |part| {
            const pd = sema.nominalDecl(d.ctx, part) orelse continue;
            if (pd.ctx == self.ctx and pd.sym == target) return true;
            if (pd.symbol().error_parts != null and pd.ctx == self.ctx and try self.unionReaches(part, target, depth + 1)) return true;
        }
        return false;
    }
    pub const discard_read = "`_` discards a value; it cannot be read";
    /// A stack closure made and never called, alone on a line or
    /// discarded (`_ = |x| ...`): its body never runs.
    pub const never_called = "this closure is never called: bind it and call it (`f = |...| ...`, then `f()`), or remove it";
    pub const stack_signal = "stack-local `Signal[T]` is not supported: a Signal lives behind a shared handle; construct it with `*Signal(...)`";

    /// A `struct`, `enum`, `errors`, `generic_struct`, or `generic_enum`.
    pub fn checkNominal(self: *Checker, node: Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(ir.get(node, .name)) orelse return;
        const prev = self.nominal;
        self.nominal = try sema.makeNominalContext(self.ctx, sym_id);
        defer self.nominal = prev;
        const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
        if (node.isKind(.errors)) try self.checkErrorFields(sym_id, fields);
        if (self.ctx.symbols.items[sym_id].flags.exact) try self.checkExact(node, sym_id);
        for (ir.rest(node, .members)) |m| {
            const h = m.kind() orelse continue;
            switch (h) {
                .fun, .sub => {
                    const pos = ir.get(m, .name).src.pos;
                    var fn_ty = self.t().invalid_id;
                    var bounds: []const sema.OwnerBound = &.{};
                    for (fields) |f| {
                        if (f.is_method and f.decl_pos == pos) {
                            fn_ty = f.ty;
                            bounds = f.owner_bounds;
                        }
                    }
                    if (bounds.len == 0) {
                        try self.checkFunction(m, fn_ty);
                        continue;
                    }
                    // A method under bounds: its type's parameters have
                    // them while its body is checked.
                    const tparams = self.ctx.symbols.items[sym_id].type_params orelse &.{};
                    try ExprCheck.checkOwnerBounds(self, sym_id, node, pos, bounds);
                    const widened = try sema.widenOwnerBounds(self.ctx, tparams, bounds);
                    defer sema.restoreOwnerBounds(self.ctx, widened);
                    try self.checkFunction(m, fn_ty);
                    try sema.recordTypeWitnesses(self.ctx);
                },
                .default => for (fields) |f| {
                    if (f.default != null and f.decl_pos == ir.Default.name(m).src.pos) try self.checkDefaultValue(f.default.?, f.ty, "field", self.text(ir.Default.name(m)));
                },
                .drop_decl => {
                    const prev_scope = self.enter(m);
                    defer self.scope = prev_scope;
                    try self.checkBody(ir.DropDecl.body(m), .{ .ret = self.t().void_id, .fail_to = .drop });
                },
                else => {},
            }
        }
    }

    /// An `exact` object lays out as declared (`sema.exactLayout`): its
    /// fields in declaration order with no padding, each a number, a
    /// `Bool`, a plain enum, an `exact` object, or a fixed array of them.
    /// Padding is written as a field (`_pad: [3]U8`).
    pub fn checkExact(self: *Checker, node: Sexp, sym_id: SymbolId) Error!void {
        const not = (try sema.exactLayout(self.ctx, sym_id)) orelse return;
        const name = self.ctx.symbols.items[sym_id].name;
        // A field's own `exact` object that does not lay out as declared
        // is reported where that object is declared.
        if (not.field.len > 0 and !std.mem.eql(u8, not.owner, name)) return;
        var pos = ir.get(node, .name).src.pos;
        for (self.ctx.symbols.items[sym_id].fields orelse &.{}) |f| {
            if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, not.field)) pos = f.decl_pos;
        }
        const head = "`exact` object `{s}` ";
        switch (not.why) {
            .padding_before => |p| {
                const bytes = p.alignment - p.at % p.alignment;
                try self.err(pos, head ++ "has {d} {s} of padding before field `{s}`: it starts at byte {d}, and {s} `{s}` starts at a multiple of {d}; write the padding as a field before it, `_pad: [{d}]U8`, or order the fields so that none needs it", .{ name, bytes, if (bytes == 1) "byte" else "bytes", not.field, p.at, CompatCheck.article(not.shown), not.shown, p.alignment, bytes });
            },
            .padding_after => |p| try self.err(pos, head ++ "has {d} {s} of padding after field `{s}`, to a multiple of {d}; write the padding as a field after it, `_pad: [{d}]U8`", .{ name, p.bytes, if (p.bytes == 1) "byte" else "bytes", not.field, p.alignment, p.bytes }),
            .empty => if (not.field.len == 0)
                try self.err(pos, head ++ "holds no bytes: give it a field", .{name})
            else
                try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`, which holds no bytes", .{ name, not.field, CompatCheck.article(not.shown), not.shown }),
            .not_exact => |inner| try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`, which is not `exact`: add `exact` to `obj {s}`", .{ name, not.field, CompatCheck.article(not.shown), not.shown, inner }),
            else => try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`; an `exact` object holds integers, floats, `Bool`s, plain enums, `exact` objects, and fixed arrays of them", .{ name, not.field, CompatCheck.article(not.shown), not.shown }),
        }
    }

    /// An API's defaults, each checked once, as a method generic over the
    /// type that provides the API: `@` is a view of `Self`, a type
    /// parameter bounded by the API, so the body does what the API and
    /// those it builds on declare (docs/design/apis.md, Stage 3,
    /// "Lowering": `describe[Self: Shape](?@)`).
    pub fn checkApiDefaults(self: *Checker, node: Sexp) Error!void {
        const id = self.ctx.symbolOf(ir.Api.name(node)) orelse return;
        const sym = self.ctx.symbols.items[id];
        const params = sym.type_params orelse return;
        const prev = self.nominal;
        // `Item` names the API's associated type, as in its signatures.
        self.nominal = .{ .sym = id, .self_type = try self.ctx.intern(.{ .type_var = self.ctx.ref(params[0]) }), .type_params = params[1..] };
        defer self.nominal = prev;
        const prev_scope = self.enter(node);
        defer self.scope = prev_scope;
        for (ir.rest(node, .members)) |m| {
            if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
            if (ir.get(m, .body) == .nil) continue;
            const pos = ir.get(m, .name).src.pos;
            for (sym.fields orelse &.{}) |f| if (f.decl_pos == pos) try self.checkFunction(m, f.ty);
        }
    }

    /// An addition's methods, checked as methods of the type it adds its
    /// APIs to: `@` is a view of `Self`, that type (`add Int: Shape`), or
    /// the generic type at the addition's own parameters (`add Wrap[T:
    /// Shape]`).
    pub fn checkAddMethods(self: *Checker, node: Sexp) Error!void {
        const at = self.ctx.startOf(node);
        const conf = for (self.ctx.conformances.items) |c| {
            if (c.kind == .add and c.pos == at) break c;
        } else return;
        if (sema.containsPoison(self.ctx, conf.ty)) return;
        const prev = self.nominal;
        self.nominal = .{ .sym = conf.self_sym, .self_type = conf.ty, .type_params = conf.params };
        defer self.nominal = prev;
        const prev_scope = self.enter(node);
        defer self.scope = prev_scope;
        for (ir.rest(node, .members)) |m| {
            if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
            const pos = ir.get(m, .name).src.pos;
            for (conf.methods) |f| if (f.decl_pos == pos) try self.checkFunction(m, f.ty);
        }
    }

    /// A `fun` or `sub`.
    pub fn checkFunction(self: *Checker, node: Sexp, fn_ty_id: TypeId) Error!void {
        const is_sub = node.isKind(.sub);
        const fn_ty = self.ctx.types.get(fn_ty_id);
        const ret = if (fn_ty == .function) fn_ty.function.returns else self.t().unknown_id;

        const prev_scope = self.enter(node);
        defer self.scope = prev_scope;
        const name = ir.get(node, .name);
        const prev_body = self.body_pos;
        defer self.body_pos = prev_body;
        self.body_pos = if (self.nominal.isEmpty() or ExprCheck.calledUnwritten(self, name.src.pos)) sema.no_body else name.src.pos;
        // The root module's `main` is the program's entry point; in any
        // other module `main` is an ordinary function.
        const is_main = self.ctx.is_root and self.nominal.isEmpty() and std.mem.eql(u8, self.text(name), "main");
        // It returns nothing, or the process's exit status (`-> Int`, or
        // `-> Int!`).
        const status = ret == self.t().int_id or (self.ctx.types.get(ret) == .fallible and self.ctx.types.get(ret).fallible.ok == self.t().int_id);
        if (is_main and ((!is_sub and !status) or ir.get(node, .params).items().len > 0 or sema.tparamsOf(node).items().len > 0)) {
            try self.errAt(name, "`main` must be `sub main()`, or `fun main() -> Int` returning the exit status (`-> Int!` if it may fail): the program's entry point takes no parameters", .{});
        }
        for (ir.get(node, .params).items()) |p| if (p.isKind(.default)) {
            const ty = self.ctx.bindingTypeOf(ir.Default.name(p)) orelse self.t().unknown_id;
            try self.checkDefaultValue(ir.Default.value(p), ty, "parameter", self.text(ir.Default.name(p)));
        };
        // Its groups were checked, and made parameters, before any body
        // (`flattenGroups`); a field read of one is found here.
        const saved_groups = self.in_group_body;
        defer self.in_group_body = saved_groups;
        self.in_group_body = for (ir.get(node, .params).items()) |p| {
            if (p.isKind(.group_param) or sema.groupFieldOf(p) != null) break true;
        } else false;
        // `main` lowers to a fallible Zig `main`.
        const fallible = is_main or rig.subFails(node) or rig.returnType(node).isKind(.error_union);
        if (node.isKind(.fun) and !is_main) try self.checkFunReturns(node, ret);
        // A Zig-backed declaration's body is its Zig function.
        if (ir.get(node, .body) == .nil) return;
        try self.checkBody(ir.get(node, .body), .{ .ret = ret, .is_sub = is_sub, .fail_to = if (fallible) .caller else .{ .infallible = name }, .name = name });
    }

    // -------------------------------------------------------------------------
    // Groups and spreads (docs/design/options.md, sections 2 to 4)
    //
    // A group is checked and made parameters before any body
    // (`flattenGroups`). The check of a body sees the group's own name,
    // `net` of type `Net`, and each spread as written: it finds their uses
    // (`rig.GroupUse`, `rig.SpreadSite`) and checks a call with a spread no
    // further. The declaration is rewritten, its uses as parameters and
    // keyword arguments, and checked again (`checkRewritten`).
    // -------------------------------------------------------------------------

    /// A group's type: an object, declared here or in module `module`
    /// (symbol `sym` there), its data fields in the order declared, and
    /// each one's type here.
    pub const GroupType = struct {
        name: []const u8,
        fields: []const Field,
        tys: []const TypeId,
        module: ?u32,
        sym: SymbolId,
    };

    /// The object `ty` names as a group's type, or null for any other
    /// type: an enum, a generic type's instance, an optional, a view.
    pub fn groupType(self: *Checker, ty: TypeId) Error!?GroupType {
        const a = self.ctx.arena.allocator();
        const sym: sema.Symbol, const module: ?u32, const id: SymbolId, const foreign: ?*SemContext = switch (self.ctx.types.get(ty)) {
            .nominal => |r| if (self.ctx.owns(r)) .{ self.ctx.symbols.items[r.sym], null, r.sym, null } else blk: {
                const fc = self.ctx.foreign_semas.get(r.module_id) orelse return null;
                break :blk .{ fc.symbols.items[r.sym], r.module_id, r.sym, fc };
            },
            else => return null,
        };
        if (sym.kind != .nominal_type or sym.flags.error_set) return null;
        const all = sym.fields orelse return null;
        var fields: std.ArrayList(Field) = .empty;
        var tys: std.ArrayList(TypeId) = .empty;
        for (all) |f| {
            if (f.is_variant) return null;
            if (f.is_method) continue;
            try fields.append(a, f);
            try tys.append(a, if (foreign) |fc| try sema.importType(self.ctx, fc, f.ty, module.?) else f.ty);
        }
        return .{ .name = sym.name, .fields = fields.items, .tys = tys.items, .module = module, .sym = id };
    }

    /// Which of the types `tys` of a group's or an update's fields move
    /// (Core §1: an owner or a handle), and so take a spread's sigil.
    pub fn fieldMoves(self: *Checker, tys: []const TypeId) Error![]const bool {
        const out = try self.ctx.arena.allocator().alloc(bool, tys.len);
        for (tys, out) |ty, *o| o.* = sema.copies(self.ctx, ty) != .yes;
        return out;
    }

    /// The symbol of group type `g`, here or in its module.
    pub fn groupSymbol(self: *Checker, g: GroupType) sema.Symbol {
        return if (g.module) |m| self.ctx.foreign_semas.get(m).?.symbols.items[g.sym] else self.ctx.symbols.items[g.sym];
    }

    /// Whether group type `g` has a `drop` body.
    pub fn hasDropBody(self: *Checker, g: GroupType) bool {
        for (self.groupSymbol(g).fields orelse &.{}) |f| if (f.is_drop_method) return true;
        return false;
    }

    /// Why object `g` is no group's type, as a phrase, or null when it may
    /// be one: a group passes its fields one by one, as parameters, so its
    /// type is only its fields, with no `drop` body and not `unique`. (No
    /// field holds a callable view, which a closure written last fills,
    /// so that rule needs nothing of a group.) A field whose type is
    /// invalid was reported, and gives "".
    pub fn notGroupType(self: *Checker, g: GroupType) ?[]const u8 {
        for (g.tys) |ft| if (sema.containsPoison(self.ctx, ft)) return "";
        if (self.groupSymbol(g).flags.unique) return "is `unique`, whose fields a group would copy";
        if (self.hasDropBody(g)) return "has a `drop` body, which expects every field: a group passes its fields one by one";
        return null;
    }

    /// The object an update makes, `result`, as a group's type: an
    /// instance of a generic object (`Box(n: 2, ..b)`) has its fields'
    /// types at the instance's arguments.
    pub fn updateType(self: *Checker, result: TypeId, fields: []const Field) Error!?GroupType {
        const pn = switch (self.ctx.types.get(result)) {
            .parameterized_nominal => |pn| pn,
            else => return self.groupType(result),
        };
        const a = self.ctx.arena.allocator();
        const subst: TypeSubst = .{ .params = self.ctx.symbols.items[self.ctx.localSym(pn.sym)].type_params orelse &.{}, .args = pn.args };
        var data: std.ArrayList(Field) = .empty;
        var tys: std.ArrayList(TypeId) = .empty;
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            try data.append(a, f);
            try tys.append(a, try sema.substituteType(self.ctx, f.ty, subst));
        }
        return .{ .name = self.ctx.symbols.items[self.ctx.localSym(pn.sym)].name, .fields = data.items, .tys = tys.items, .module = null, .sym = self.ctx.localSym(pn.sym) };
    }

    /// Where field `f` of `gt` is declared, as a note.
    pub fn noteGroupField(self: *Checker, gt: GroupType, f: Field) Error!void {
        if (f.decl_pos >= sema.imported_decl_pos) return;
        if (gt.module) |m| return self.ctx.noteIn(m, f.decl_pos, "`{s}` declared here, a field of `{s}`", .{ f.name, gt.name });
        try self.note(f.decl_pos, "`{s}` declared here, a field of `{s}`", .{ f.name, gt.name });
    }

    /// Whether function `node` is `pub`: a module's function, or a
    /// method of a type, declared so.
    pub fn isPubFunction(self: *Checker, node: Sexp) bool {
        const name = ir.get(node, .name);
        if (self.nominal.isEmpty()) {
            const id = self.ctx.symbolOf(name) orelse return false;
            return self.ctx.symbols.items[id].flags.is_public;
        }
        for (self.ctx.symbols.items[self.nominal.sym].fields orelse &.{}) |f| if (f.is_method and f.decl_pos == name.src.pos) return f.is_pub;
        return false;
    }

    /// The type each field of object `sym`, declared in this module, has
    /// as its declaration writes it, in the order of `fields`.
    pub fn writtenFieldTypes(self: *Checker, sym: sema.Symbol, fields: []const Field) Error![]const Sexp {
        const decl = for (ir.Module.decls(self.tree)) |d| {
            const u = rig.unpub(d);
            if (u.isKind(.@"struct") and ir.Struct.name(u).src.pos == sym.decl_pos) break u;
        } else return &.{};
        const out = try self.ctx.arena.allocator().alloc(Sexp, fields.len);
        for (fields, out) |f, *o| {
            o.* = .nil;
            for (ir.rest(decl, .members)) |m| {
                const n = sema.paramNameNode(m) orelse continue;
                if (n != .src or n.src.pos != f.decl_pos) continue;
                o.* = ir.get(m, .type);
            }
            if (o.* == .nil) return &.{};
        }
        return out;
    }

    /// Function `def`'s groups (`checkGroups`), those that hold made its
    /// parameters (`flattenGroups`).
    pub fn flattenIn(self: *Checker, p: *rig.Parser, def: Sexp, nominal_sym: SymbolId, sites: *std.ArrayList(rig.GroupSite), flat: *std.ArrayList(rig.Parser.Flattened)) Error!void {
        sites.clearRetainingCapacity();
        try self.checkGroups(def, sites);
        if (sites.items.len == 0) return;
        const first = flat.items.len;
        try p.flattenGroups(def, sites.items, self.ctx.allocator, flat);
        for (flat.items[first..]) |f| try self.ctx.flat_groups.put(self.ctx.allocator, f.site.name, f);
        try resolve.resolveFlattened(self.ctx, def, nominal_sym, flat.items[first..]);
    }

    /// The groups of function `node`, `..net: Net` (docs/design/options.md,
    /// section 2): each an object of plain data, its fields public where the
    /// function is, no name among the function's parameters and its groups'
    /// fields twice, and 64 parameters at most in all. Each such group of
    /// a function whose declaration holds is recorded for the Parser
    /// wrapper to make parameters (`rig.GroupSite`).
    pub fn checkGroups(self: *Checker, node: Sexp, out: *std.ArrayList(rig.GroupSite)) Error!void {
        const params = ir.get(node, .params);
        if (params != .list) return;
        var groups: usize = 0;
        for (params.items()) |p| groups += @intFromBool(p.isKind(.group_param));
        if (groups == 0) return;
        const a = self.ctx.arena.allocator();
        const fname = self.text(ir.get(node, .name));
        const is_pub = self.isPubFunction(node);
        const Named = struct { name: []const u8, group: ?usize = null };
        var names: std.ArrayList(Named) = .empty;
        for (params.items()) |p| {
            if (p.isKind(.group_param)) continue;
            const n = sema.paramName(self.ctx.source, p) orelse continue;
            try names.append(a, .{ .name = n });
        }
        var types: std.ArrayList(?GroupType) = .empty;
        var gnames: std.ArrayList([]const u8) = .empty;
        var ok = true;
        var count: usize = params.items().len - groups;
        for (params.items()) |p| {
            if (!p.isKind(.group_param)) continue;
            const name = ir.GroupParam.name(p);
            const gname = self.text(name);
            const gi = types.items.len;
            try gnames.append(a, gname);
            const ty = self.ctx.bindingTypeOf(name) orelse self.t().invalid_id;
            const gt = if (self.isPoison(ty)) null else try self.groupType(ty);
            try types.append(a, gt);
            if (self.isPoison(ty)) {
                ok = false;
                continue;
            }
            const g = gt orelse {
                if (self.ctx.types.get(ty) == .parameterized_nominal) {
                    try self.errAt(ir.GroupParam.type(p), "group `{s}` of `{s}` is a `{s}`, an instance of a generic object; a group's type has no type parameters", .{ gname, fname, try self.tyName(ty) });
                } else try self.errAt(ir.GroupParam.type(p), "group `{s}` of `{s}` is a `{s}`, which is not an object: a group's type is an object, whose fields become the function's options", .{ gname, fname, try self.tyName(ty) });
                ok = false;
                continue;
            };
            if (self.notGroupType(g)) |why| {
                if (why.len > 0) try self.errAt(p, "group `{s}` of `{s}` is a `{s}`, which {s}", .{ gname, fname, g.name, why });
                ok = false;
                continue;
            }
            // Every caller gives the fields, so another module's type
            // has none private to it.
            if (g.module) |m| if (self.ctx.foreign_semas.get(m)) |fc| if (!(fc.is_std and self.ctx.is_std)) for (g.fields) |f| if (!f.is_pub or f.read_only) {
                try self.errAt(p, "group `{s}` of `{s}` is a `{s}.{s}`, whose field `{s}` is private to module `{s}`: every caller gives a group's fields", .{ gname, fname, fc.name, g.name, f.name, fc.name });
                try self.noteGroupField(g, f);
                ok = false;
                break;
            };
            if (is_pub) for (g.fields) |f| if (!f.is_pub or f.read_only) {
                try self.errAt(p, "`{s}` is `pub`, so the fields of its group `{s}`, a `{s}`, are public too: declare `{s}` `pub`", .{ fname, gname, g.name, f.name });
                try self.noteGroupField(g, f);
                ok = false;
                break;
            };
            count += g.fields.len;
            for (g.fields) |f| {
                for (names.items) |n| {
                    if (!std.mem.eql(u8, n.name, f.name)) continue;
                    if (n.group) |other| {
                        try self.errAt(p, "`{s}` is a field of both group `{s}`, a `{s}`, and group `{s}`, a `{s}`, of `{s}`", .{ f.name, gnames.items[other], types.items[other].?.name, gname, g.name, fname });
                    } else try self.errAt(p, "`{s}` is both a parameter of `{s}` and a field of its group `{s}`, a `{s}`", .{ f.name, fname, gname, g.name });
                    try self.noteGroupField(g, f);
                    ok = false;
                }
                for (gnames.items) |other| {
                    if (!std.mem.eql(u8, other, f.name)) continue;
                    try self.errAt(p, "`{s}` is both group `{s}` of `{s}` and a field of its group `{s}`, a `{s}`: name the group otherwise", .{ f.name, other, fname, gname, g.name });
                    ok = false;
                }
            }
            for (names.items) |n| {
                if (n.group == null or !std.mem.eql(u8, n.name, gname)) continue;
                try self.errAt(name, "`{s}` is both group `{s}` of `{s}` and a field of its group `{s}`, a `{s}`: name the group otherwise", .{ gname, gname, fname, gnames.items[n.group.?], types.items[n.group.?].?.name });
                ok = false;
            }
            for (g.fields) |f| try names.append(a, .{ .name = f.name, .group = gi });
        }
        if (count > @bitSizeOf(sema.ParamMask)) {
            try self.errAt(ir.get(node, .name), "`{s}` takes {d} parameters with its groups' fields, and a function takes at most {d}", .{ fname, count, @bitSizeOf(sema.ParamMask) });
            ok = false;
        }
        if (!ok) return;
        // A required parameter after a group was reported where the
        // parameters were resolved (`paramDefaults`).
        var after_group = false;
        for (params.items()) |p| {
            if (p.isKind(.group_param)) {
                after_group = true;
                continue;
            }
            if (!after_group or p.isKind(.default)) continue;
            const ty = self.ctx.bindingTypeOf(sema.paramNameNode(p) orelse continue) orelse continue;
            if (sema.callableFnTy(self.ctx, ty) == null and self.ctx.types.get(ty) != .function) return;
        }
        var gi: usize = 0;
        for (params.items()) |p| {
            if (!p.isKind(.group_param)) continue;
            const g = types.items[gi].?;
            gi += 1;
            const id = CompatCheck.nodeId(p);
            const fields = try a.alloc([]const u8, g.fields.len);
            for (g.fields, fields) |f, *o| o.* = f.name;
            const written = if (g.module == null) try self.writtenFieldTypes(self.ctx.symbols.items[g.sym], g.fields) else &.{};
            try out.append(self.ctx.allocator, .{ .node = id, .name = ir.GroupParam.name(p).src.pos, .fields = fields, .field_types = written, .moves = try self.fieldMoves(g.tys) });
        }
    }

    /// A name that names a group as written (`sema.SymbolFlags.group`):
    /// used whole, unless it is the object of a field read or a spread's
    /// operand being checked (`group_member`), which records its own use.
    pub fn noteGroupUse(self: *Checker, leaf: Sexp, sym: sema.Symbol) Error!void {
        if (leaf.src.pos == self.expect.group_member) return;
        try self.group_uses.append(self.ctx.allocator, .{ .group = sym.decl_pos, .pos = leaf.src.pos });
    }

    /// Whether `e` is a spread's operand as one may be written: a name, or
    /// a field path from one (`cfg.net`), each read once per field.
    pub fn isSpreadPlace(self: *Checker, e: Sexp) bool {
        if (e == .src) {
            const word = self.text(e);
            // Self, `@`, is a place, and `@at` a field of it.
            if (std.mem.eql(u8, word, "@")) return true;
            return word.len > 0 and rig.isIdentStart(word[0]) and !std.mem.eql(u8, word, "true") and !std.mem.eql(u8, word, "false") and !std.mem.eql(u8, word, "none");
        }
        if (e.isKind(.member)) return self.isSpreadPlace(ir.Member.object(e));
        return false;
    }

    /// A spread's operand, checked: a place, whose type is an object's;
    /// its type, or null after a diagnostic. A name that names a group as
    /// written is read field by field, so it is no use of the group whole.
    pub fn spreadOperand(self: *Checker, spread: Sexp) Error!?TypeId {
        const written = ir.Spread.value(spread);
        if (written.isKind(.read) or written.isKind(.write)) {
            const place = try ViewCheck.plainText(self, ir.get(written, .operand));
            try self.errAt(spread, "a spread gives a value's fields: write `..{s}`, `..<{s}` to move its owners, or `..+{s}` to clone them", .{ place, place, place });
            _ = try FlowCheck.synthQuiet(self, ir.get(written, .operand));
            return null;
        }
        const operand = rig.Parser.spreadPlace(written);
        if (!self.isSpreadPlace(operand)) {
            try self.errAt(spread, "a spread passes a name or a field: bind `{s}` to a name first", .{try ViewCheck.plainText(self, operand)});
            _ = try FlowCheck.synthQuiet(self, operand);
            return null;
        }
        const saved = self.expect.group_member;
        defer self.expect.group_member = saved;
        if (operand == .src) self.expect.group_member = operand.src.pos;
        const ty = try PatternCheck.synthExpr(self, operand);
        if (self.isPoison(ty)) return null;
        const value = sema.unwrapAccess(self.ctx, ty);
        switch (self.ctx.types.get(value)) {
            .optional => {
                try self.errAt(spread, "`..{s}` is a `{s}`, an optional: a spread passes a value; take it out first", .{ try ViewCheck.plainText(self, written), try self.tyName(value) });
                return null;
            },
            .type_var => {
                try self.errAt(spread, "`..{s}` is a value of type parameter `{s}`: a spread passes a value of a group's own type", .{ try ViewCheck.plainText(self, written), try self.tyName(value) });
                return null;
            },
            else => {},
        }
        return value;
    }

    /// The group a spread's operand names, as written, when it is a name
    /// of one (its name's position), else null: its fields are its
    /// parameters.
    pub fn spreadGroup(self: *Checker, spread: Sexp) ?u32 {
        const operand = rig.Parser.spreadPlace(ir.Spread.value(spread));
        if (operand != .src) return null;
        const id = self.ctx.symbolOf(operand) orelse return null;
        const sym = self.ctx.symbols.items[id];
        return if (sym.flags.group) sym.decl_pos else null;
    }

    /// A spread that will not be rewritten: a name of a group in it is a
    /// use of the group whole, so the check again, which sees it again,
    /// finds the group's value bound.
    pub fn spreadRefused(self: *Checker, spread: Sexp) Error!void {
        var place = rig.Parser.spreadPlace(ir.Spread.value(spread));
        while (place.isKind(.member)) : (place = ir.Member.object(place)) {
            // A field read in it stays as written, so the message about it
            // reads the same.
            var i: usize = 0;
            while (i < self.group_uses.items.len) {
                const u = self.group_uses.items[i];
                if (u.member != 0 and u.member == place.list.id) {
                    try self.group_uses.append(self.ctx.allocator, .{ .group = u.group, .pos = u.pos });
                    _ = self.group_uses.swapRemove(i);
                } else i += 1;
            }
        }
        if (self.spreadGroup(spread)) |g| try self.group_uses.append(self.ctx.allocator, .{ .group = g, .pos = rig.Parser.spreadPlace(ir.Spread.value(spread)).src.pos });
    }

    /// Record spread `spread`, which gives `fields`.
    pub fn recordSpread(self: *Checker, spread: Sexp, given: Given) Error!void {
        const id = CompatCheck.nodeId(spread);
        for (self.spreads.items) |sp| if (sp.node == id) return;
        try self.spreads.append(self.ctx.allocator, .{ .node = id, .fields = given.fields, .group = self.spreadGroup(spread), .sigil = spreadSigil(spread), .moves = given.moves });
    }

    /// The fields a spread gives, those no keyword of its call names, in
    /// the order declared, and which of them move.
    pub const Given = struct { fields: []const []const u8, moves: []const bool };

    /// The sigil spread `spread` is written with.
    pub fn spreadSigil(spread: Sexp) rig.SpreadSigil {
        const v = ir.Spread.value(spread);
        return if (v.isKind(.move)) .move else if (v.isKind(.clone)) .clone else .none;
    }

    /// The fields of object `gt` that spread `spread` gives, those no
    /// keyword among `args` names, checked against its sigil: a spread
    /// gives each field as the keyword argument written out would
    /// (docs/design/options.md, section 11, step 3), so a field that
    /// moves needs `..<v` or `..+v`, and `..<v` needs a field to move. An
    /// object update (`update`, of the type made) of a type with a `drop`
    /// body, which expects every field and has no clone, or of a `unique`
    /// type, is refused. Null after a diagnostic.
    pub fn spreadGiven(self: *Checker, spread: Sexp, gt: GroupType, args: []const Sexp, update: bool) Error!?Given {
        const a = self.ctx.arena.allocator();
        // A field whose type was refused is said where it is declared.
        for (gt.tys) |ft| if (sema.containsPoison(self.ctx, ft)) return null;
        const sigil = spreadSigil(spread);
        const place = try ViewCheck.plainText(self, rig.Parser.spreadPlace(ir.Spread.value(spread)));
        if (update and self.groupSymbol(gt).flags.unique) {
            try self.errAt(spread, "object update copies the fields of `{s}`, which is `unique`: write its fields", .{gt.name});
            return null;
        }
        if (update and self.hasDropBody(gt)) {
            try self.errAt(spread, "`{s}` has a `drop` body, so no update makes one: an update would take its fields apart or duplicate it, and a `drop` type has no clone (Core sentence 2); move `{s}` whole and set the field", .{ gt.name, place });
            return null;
        }
        var fields: std.ArrayList([]const u8) = .empty;
        var moves: std.ArrayList(bool) = .empty;
        var moving: ?usize = null;
        for (gt.fields, gt.tys, 0..) |f, ty, i| {
            if (self.namesKeyword(args, f.name)) continue;
            const m = sema.copies(self.ctx, ty) != .yes;
            if (m and moving == null) moving = i;
            try fields.append(a, f.name);
            try moves.append(a, m);
        }
        switch (sigil) {
            .none => if (moving) |i| {
                const ty = gt.tys[i];
                const handle = sema.cloneable(self.ctx, ty) == .bump;
                try self.errAt(spread, "`..{s}` gives `{s}`, a `{s}`, {s}: write `..<{s}` to move it, or `..+{s}` to {s} it", .{ place, gt.fields[i].name, try self.tyName(ty), if (handle) "a handle" else "which owns", place, place, if (handle) "share" else "clone" });
                return null;
            },
            .move => if (moving == null) {
                try self.errAt(spread, "`..<{s}` moves nothing, since every field it gives copies: write `..{s}`", .{ place, place });
                return null;
            },
            .clone => {},
        }
        return .{ .fields = fields.items, .moves = moves.items };
    }

    /// Whether keyword argument `name` is among `args`.
    pub fn namesKeyword(self: *Checker, args: []const Sexp, name: []const u8) bool {
        for (args) |a| if (a.isKind(.kwarg) and std.mem.eql(u8, self.text(ir.Kwarg.name(a)), name)) return true;
        return false;
    }

    /// A call with a spread, or of a function whose group is as written:
    /// each spread checked against the group it fills and found, and each
    /// other argument typed, no further. True when the call is such a
    /// call; its declaration is checked again with it the keyword call it
    /// then is (`checkRewritten`).
    pub fn optionsCall(self: *Checker, args: []const Sexp, info: ParamInfo, callee: []const u8) Error!bool {
        var spreads = false;
        for (args) |x| spreads = spreads or x.isKind(.spread);
        var whole = false;
        if (info.groups) |gs| for (gs) |g| if (g) |x| {
            whole = whole or x.whole;
        };
        if (!spreads and !whole) return false;
        const a = self.ctx.arena.allocator();
        var filled: std.ArrayList([]const u8) = .empty;
        var given: std.ArrayList(Given) = .empty;
        var rest: std.ArrayList(Sexp) = .empty;
        var ok = true;
        for (args) |x| {
            if (!x.isKind(.spread)) {
                try rest.append(a, x);
                continue;
            }
            const value = (try self.spreadOperand(x)) orelse {
                ok = false;
                continue;
            };
            const shown = try ViewCheck.plainText(self, ir.Spread.value(x));
            const target = (try self.spreadTarget(x, value, info, callee, shown)) orelse {
                ok = false;
                continue;
            };
            const twice = for (filled.items) |g| {
                if (std.mem.eql(u8, g, target)) break true;
            } else false;
            if (twice) {
                try self.errAt(x, "group `{s}` of `{s}` is filled by two spreads", .{ target, callee });
                ok = false;
                continue;
            }
            try filled.append(a, target);
            const gt = (try self.groupType(value)) orelse {
                ok = false;
                continue;
            };
            const g = (try self.spreadGiven(x, gt, args, false)) orelse {
                ok = false;
                continue;
            };
            try given.append(a, g);
        }
        // A call's spreads are rewritten together or not at all, so a
        // check of the call after the rewrite sees what this one saw.
        var k: usize = 0;
        for (args) |x| {
            if (!x.isKind(.spread)) continue;
            if (!ok) {
                try self.spreadRefused(x);
                continue;
            }
            try self.recordSpread(x, given.items[k]);
            k += 1;
        }
        try CallCheck.synthArgs(self, rest.items);
        return true;
    }

    /// The group of the callee a spread of a value of type `value` fills:
    /// the one of exactly its type, by name, or null after a diagnostic.
    pub fn spreadTarget(self: *Checker, spread: Sexp, value: TypeId, info: ParamInfo, callee: []const u8, shown: []const u8) Error!?[]const u8 {
        const a = self.ctx.arena.allocator();
        const ref = sema.nominalRef(self.ctx, value);
        var names: std.ArrayList([]const u8) = .empty;
        var types: std.ArrayList([]const u8) = .empty;
        if (info.groups) |gs| for (gs) |g| if (g) |x| {
            const seen = for (names.items) |n| {
                if (std.mem.eql(u8, n, x.group)) break true;
            } else false;
            if (seen) continue;
            if (ref != null and x.ref != null and ref.?.ref.module_id == x.ref.?.module_id and ref.?.ref.sym == x.ref.?.sym) return x.group;
            try names.append(a, x.group);
            try types.append(a, x.type_name);
        };
        // A group refused at its declaration has no type to name.
        for (types.items) |tn| if (tn.len == 0) return null;
        const vname = try self.tyName(value);
        switch (names.items.len) {
            0 => try self.errAt(spread, "`{s}` has no group for `..{s}` to fill: a spread gives a value's fields to a group, `..name: T` among a function's parameters", .{ callee, shown }),
            1 => try self.errAt(spread, "`..{s}` is a `{s}`, but group `{s}` of `{s}` is a `{s}`: a spread passes a value of the group's own type", .{ shown, vname, names.items[0], callee, types.items[0] }),
            else => {
                var list: std.ArrayList(u8) = .empty;
                for (names.items, types.items, 0..) |n, tn, i| {
                    if (i > 0) try list.appendSlice(a, if (i + 1 == names.items.len) ", and " else ", ");
                    try list.print(a, "`{s}`, a `{s}`", .{ n, tn });
                }
                try self.errAt(spread, "`..{s}` is a `{s}`, and no group of `{s}` is one: its groups are {s}; a spread passes a value of the group's own type", .{ shown, vname, callee, list.items });
            },
        }
        return null;
    }

    /// `Point(x: 3, ..p)`: a copy of `p` with the fields named set
    /// (docs/design/options.md, "Object update"): one spread, of a place of
    /// exactly the type made, of plain data, and no argument by position.
    /// The spread is found and the rest typed; the declaration is checked
    /// again with the constructor it then is.
    pub fn objectUpdate(self: *Checker, args: []const Sexp, fields: []const Field, result: TypeId, owner: []const u8) Error!void {
        const a = self.ctx.arena.allocator();
        var rest: std.ArrayList(Sexp) = .empty;
        var spread: ?Sexp = null;
        var ok = true;
        for (args) |x| {
            if (!x.isKind(.spread)) {
                if (!x.isKind(.kwarg)) {
                    try self.errAt(x, "an object update names each field it sets: `{s}(name: value, ..v)`", .{owner});
                    ok = false;
                }
                try rest.append(a, x);
                continue;
            }
            if (spread != null) {
                try self.errAt(x, "a `{s}` is updated from one spread", .{owner});
                ok = false;
                continue;
            }
            spread = x;
        }
        defer CallCheck.synthArgs(self, rest.items) catch {};
        const sp = spread.?;
        const value = (try self.spreadOperand(sp)) orelse return self.spreadRefused(sp);
        const shown = try ViewCheck.plainText(self, ir.Spread.value(sp));
        if (value != result) {
            try self.errAt(sp, "`..{s}` is a `{s}`, but this makes a `{s}`: a spread passes a value of the type it updates", .{ shown, try self.tyName(value), try self.tyName(result) });
            return self.spreadRefused(sp);
        }
        const gt = (try self.updateType(result, fields)) orelse return self.spreadRefused(sp);
        for (gt.tys) |ft| if (sema.containsPoison(self.ctx, ft)) return self.spreadRefused(sp);
        const given = (try self.spreadGiven(sp, gt, args, true)) orelse return self.spreadRefused(sp);
        if (!ok) return self.spreadRefused(sp);
        try self.recordSpread(sp, given);
    }

    /// `name:` alone, `name: name` (docs/design/options.md, "The
    /// shorthand"), names a local or a parameter: never a module's
    /// constant or a function, so renaming a local cannot make it name
    /// something else.
    pub fn checkShorthands(self: *Checker, args: []const Sexp) Error!void {
        for (args) |x| {
            if (!x.isKind(.kwarg)) continue;
            const name = ir.Kwarg.name(x);
            const value = ir.Kwarg.value(x);
            if (name != .src or value != .src or name.src.pos != value.src.pos) continue;
            const word = self.text(name);
            const local = if (CallCheck.lookupQuiet(self, name)) |id| switch (self.ctx.symbols.items[id].kind) {
                .local, .param, .capture => self.ctx.symbols.items[id].scope != self.module_scope,
                else => false,
            } else false;
            if (!local) try self.errAt(x, "`{s}:` alone needs a local or a parameter named `{s}`", .{ word, word });
        }
    }

    /// A `fun` returns a value: one without `-> T`, or returning `Void`,
    /// is a `sub` (`sub f(...)!` when it may fail).
    pub fn checkFunReturns(self: *Checker, node: Sexp, ret: TypeId) Error!void {
        const returns = rig.returnType(node);
        const name = self.text(ir.get(node, .name));
        if (returns == .nil) {
            return self.errAt(ir.get(node, .name), "a `fun` returns a value; declare `-> T`, or make `{s}` a `sub`", .{name});
        }
        const r = self.ctx.types.get(ret);
        if (ret == self.t().void_id) {
            try self.errAt(returns, "a `fun` returning nothing is a `sub`: `sub {s}(...)`", .{name});
        } else if (r == .fallible and r.fallible.ok == self.t().void_id) {
            try self.errAt(returns, "a `fun` that returns nothing but may fail is a fallible `sub`: `sub {s}(...)!`", .{name});
        }
    }

    /// A parameter or field default, of type `ty`, means the same value
    /// wherever it is filled in: a literal, or a module constant (this
    /// module's or an imported one, or a number type's limit). A field's
    /// may also be an empty or literal constructor, `List()`, `String()`,
    /// `Cell(0)`, or `[n of 0]`, which each value gets a fresh one of.
    pub fn checkDefaultValue(self: *Checker, value: Sexp, ty: TypeId, what: []const u8, name: []const u8) Error!void {
        const field = std.mem.eql(u8, what, "field");
        // A `Duration` is made as the program runs, so no default but
        // `none` holds one.
        if (sema.durationParam(self.ctx, ty) != null and !std.mem.eql(u8, identAt(self.ctx.source, value) orelse "", "none")) {
            const shown = try ViewCheck.plainText(self, value);
            const made = if (sema.isNumeric(self.ctx, self.ctx.typeOf(value) orelse sema.type_invalid) or CompatCheck.isDefaultLiteral(self.ctx.source, value)) try std.fmt.allocPrint(self.ctx.arena.allocator(), "time.duration({s})", .{shown}) else shown;
            return self.errAt(value, "a `time.Duration` is made as the program runs, so the only default it has is `none`: declare `{s}: time.Duration? = none`, and read it as `{s} ?? {s}`", .{ name, name, made });
        }
        // A table reserves or makes its slots as the program runs, which
        // a default, a constant the object's type holds, cannot.
        if (sema.tableElem(self.ctx, ty) != null) {
            return self.errAt(value, "a table is made as the program runs, so it is no {s}'s default: make it where the value is made, `{s}()` in a constructor or a function", .{ what, "Table" });
        }
        const ok = CompatCheck.isDefaultLiteral(self.ctx.source, value) or self.isConstantDefault(value) or (field and try self.isConstructorDefault(value));
        if (!ok) {
            if (field and try self.emptyConstructorGap(value)) return;
            if (field) {
                try self.errAt(value, "a default field value must be a literal, a module constant, a number type's limit, or an empty or literal constructor: `List()`, `String()`, `Cell(0)`, `[n of 0]`, or `T()` of an object whose every field has a default", .{});
            } else try self.errAt(value, "a default parameter value must be a literal, a module constant, or a number type's limit", .{});
            return;
        }
        const saved_home = self.expect.cell_home;
        defer self.expect.cell_home = saved_home;
        if (field) self.expect.cell_home = value;
        try ViewCheck.checkExpr(self, value, ty);
    }

    /// A module constant, of this module or an imported one (`LIMIT`,
    /// `lib.LIMIT`), or a number type's limit (`U8.max`, `Byte.max`,
    /// `lib.Byte.max`).
    pub fn isConstantDefault(self: *Checker, e: Sexp) bool {
        if (e == .src) {
            const id = CallCheck.lookupQuiet(self, e) orelse return false;
            const sym = self.ctx.symbols.items[id];
            return sym.kind == .local and sym.scope == self.module_scope and sym.flags.fixed;
        }
        if (!e.isKind(.member)) return false;
        const obj = ir.Member.object(e);
        if (CallCheck.namesNumberType(self, obj)) return true;
        if (obj != .src) return false;
        const id = CallCheck.lookupQuiet(self, obj) orelse return false;
        if (self.ctx.symbols.items[id].kind != .module) return false;
        const foreign = CallCheck.foreignMember(self, e) orelse return false;
        return foreign.kind == .local and foreign.flags.fixed;
    }

    /// `List()`, `List[T]()`, `Cell(literal)`, `[n of literal]` (or of a
    /// constant), or `T()` of an object type whose every field has a
    /// default (`T`, `lib.T`, `T[A]`, `lib.T[A]`), which is made from
    /// those defaults.
    pub fn isConstructorDefault(self: *Checker, e: Sexp) Error!bool {
        if (e.isKind(.array_fill)) {
            const v = ir.ArrayFill.value(e);
            return CompatCheck.isDefaultLiteral(self.ctx.source, v) or self.isConstantDefault(v);
        }
        if (!e.isKind(.call)) return false;
        var callee = ir.Call.callee(e);
        // `String()`: the empty text, which owns nothing yet.
        if (callee == .src and std.mem.eql(u8, self.text(callee), "String") and CallCheck.lookupQuiet(self, callee) == null) return ir.Call.args(e).len == 0;
        if (rig.isBracketList(callee)) callee = ir.get(callee, .object);
        const args = ir.Call.args(e);
        if (callee == .src) if (CallCheck.lookupQuiet(self, callee)) |id| {
            if (self.ctx.ref(id) == self.ctx.builtins.list) return args.len == 0;
            if (self.ctx.ref(id) == self.ctx.builtins.cell) return args.len == 1 and CompatCheck.isDefaultLiteral(self.ctx.source, args[0]);
        };
        return args.len == 0 and try self.emptyConstructor(ir.Call.callee(e));
    }

    /// `T()` as a field default, of an object type with a field that has
    /// no default: reported naming those fields. True when reported.
    pub fn emptyConstructorGap(self: *Checker, e: Sexp) Error!bool {
        if (!e.isKind(.call) or ir.Call.args(e).len != 0) return false;
        const callee = ir.Call.callee(e);
        const nt = (try CallCheck.namedType(self, callee)) orelse return false;
        const fields = nt.sym.fields orelse return false;
        var bare: std.ArrayList(u8) = .empty;
        defer bare.deinit(self.ctx.allocator);
        var n: usize = 0;
        for (fields) |f| {
            if (f.is_variant) return false;
            if (f.is_method or f.default != null) continue;
            try bare.appendSlice(self.ctx.allocator, if (n == 0) "`" else ", `");
            try bare.appendSlice(self.ctx.allocator, f.name);
            try bare.append(self.ctx.allocator, '`');
            n += 1;
        }
        if (n == 0) return false;
        const shown = CallCheck.sourceText(self, callee);
        try self.errAt(e, "`{s}()` is a default only when every field of `{s}` has one, and {s} {s} none", .{ shown, shown, bare.items, if (n == 1) "has" else "have" });
        return true;
    }

    /// Whether `callee`, called with no arguments, names an object type
    /// whose every field has a default.
    pub fn emptyConstructor(self: *Checker, callee: Sexp) Error!bool {
        const nt = (try CallCheck.namedType(self, callee)) orelse return false;
        const fields = nt.sym.fields orelse return false;
        for (fields) |f| if (f.is_variant) return false;
        return CallCheck.everyFieldDefaulted(fields);
    }

    /// A body's statements, checked as `context`; in a `fun`, the last one
    /// is its value.
    pub fn checkBody(self: *Checker, body: Sexp, context: Body) Error!void {
        const saved = self.body;
        defer self.body = saved;
        self.body = context;
        const ret = context.ret;
        const wants_value = !context.is_sub and ret != self.t().void_id;
        if (!body.isKind(.block)) {
            if (wants_value) try self.checkTail(body, ret) else try StmtCheck.checkStmt(self, body);
            return;
        }
        const prev = self.enter(body);
        defer self.scope = prev;
        const stmts = ir.Block.stmts(body);
        if (stmts.len == 0) {
            if (wants_value) try self.errAt(body, "function body is empty but must produce a `{s}`", .{try self.tyName(ret)});
            return;
        }
        // A `Void!` function has no value to end with: its last statement
        // may be any statement.
        const ends_void = switch (self.ctx.types.get(ret)) {
            .fallible => |inner| inner.ok == self.t().void_id,
            else => false,
        };
        for (stmts) |*s| try self.checkRewritten(s, checkBodyStmt, .{ wants_value and s == &stmts[stmts.len - 1], ret, ends_void });
    }

    /// Statement `s` of a function's body, `last` its last whose value
    /// the function returns, `ret` its result type.
    pub fn checkBodyStmt(self: *Checker, s: Sexp, last: bool, ret: TypeId, ends_void: bool) Error!void {
        if (!last) return StmtCheck.checkStmt(self, s);
        if (CompatCheck.loopsForever(self.ctx.source, s) or (ends_void and (FlowCheck.yieldsNoValue(self, s) or CompatCheck.isIfWithoutElse(s)))) {
            try StmtCheck.checkStmt(self, s);
            return;
        }
        if (FlowCheck.yieldsNoValue(self, s) and !s.isKind(.@"return") and !s.isKind(.panic)) {
            try StmtCheck.checkStmt(self, s);
            const what = switch (s.kind().?) {
                .set => "assignment",
                .@"while", .@"for" => "loop",
                .labeled => switch (ir.Labeled.stmt(s).kind() orelse .labeled) {
                    .@"while", .@"for" => "loop",
                    .match => "labeled `match` (a label makes it a statement)",
                    .raw_block => "labeled `raw` block (a label makes it a statement)",
                    .block => "labeled block",
                    else => "labeled statement",
                },
                .drop => "drop",
                .pass => "`pass`",
                .rarely => "`rarely`",
                .@"defer", .@"errdefer" => "deferred statement",
                else => "jump",
            };
            try self.errAt(s, "a function returning `{s}` must end with a value; this {s} produces none", .{ try self.tyName(ret), what });
            return;
        }
        const saved_tail = self.expect.results_tail;
        defer self.expect.results_tail = saved_tail;
        if (sema.resultsOf(self.ctx, ret) != null) self.expect.results_tail = CompatCheck.resultCall(s) orelse .nil;
        try self.checkTail(s, ret);
    }

    /// `check` of the block statement or module declaration `slot` holds,
    /// with `args`, which typecheck may find holds a form that is
    /// rewritten once types are known: a string literal that is a byte or
    /// bytes where it stands (`byteString`), written as the integer or
    /// array literal it is, and a chain (`chainCall`), written as the loop
    /// it means. No pass sees either: what checking the statement recorded
    /// is taken back, the tree is rewritten where they stand
    /// (`rig.Parser.byteLiterals`, `rig.Parser.elaborateChains`, with the
    /// loops' names and scopes from `resolve.resolveChains`), and the
    /// statement is checked again in that form
    /// (docs/internals/INTERNALS.md, "Strings as bytes", "Chains"). Only a
    /// statement the parser found may hold one (`rig.Parser.Mark.rewrite`)
    /// is checked under a mark.
    pub inline fn checkRewritten(self: *Checker, slot: *const Sexp, comptime check: anytype, args: anytype) @typeInfo(@TypeOf(check)).@"fn".return_type.? {
        if (!self.mayRewrite(slot.*)) return @call(.auto, check, .{ self, slot.* } ++ args);
        return self.checkUnderMark(slot, check, args);
    }

    /// `checkRewritten` of a statement that may be rewritten: under a
    /// mark, checked again as long as the check finds a rewrite.
    pub fn checkUnderMark(self: *Checker, slot: *const Sexp, comptime check: anytype, args: anytype) @typeInfo(@TypeOf(check)).@"fn".return_type.? {
        self.rewrites_open += 1;
        defer self.rewrites_open -= 1;
        // A group's uses and a spread are rewritten with the module's
        // declaration that holds them: a group used whole is bound at its
        // function's start, which changes how each of its field reads is
        // written, wherever it stands.
        const decl = comptime isDeclCheck(check);
        const uses = self.group_uses.items.len;
        const spreads = self.spreads.items.len;
        defer if (decl) {
            self.group_uses.shrinkRetainingCapacity(uses);
            self.spreads.shrinkRetainingCapacity(spreads);
        };
        while (true) {
            const m = self.ctx.mark();
            const bytes = self.bytes.items.len;
            const chains = self.chains.items.len;
            const returns = if (self.body.returns) |r| r.items.len else 0;
            const result = try @call(.auto, check, .{ self, slot.* } ++ args);
            const options = decl and (self.spreads.items.len > spreads or self.groupRewrites(uses));
            if (self.bytes.items.len == bytes and self.chains.items.len == chains and !options) {
                self.ctx.commit(m);
                return result;
            }
            try self.ctx.rollback(m);
            if (self.body.returns) |r| r.shrinkRetainingCapacity(returns);
            const p = self.ctx.parser.?;
            try p.byteLiterals(slot, self.bytes.items[bytes..]);
            self.bytes.shrinkRetainingCapacity(bytes);
            if (self.chains.items.len > chains) {
                // The rewritten tree stays, inside a check an open mark
                // may take back, and so do the names and scopes of its
                // new nodes.
                const open = self.ctx.pauseTrail();
                defer self.ctx.resumeTrail(open);
                var loops: std.ArrayList(rig.Parser.ChainLoop) = .empty;
                defer loops.deinit(self.ctx.allocator);
                const fresh = p.base.nodeCount() + 1;
                const found = self.chains.items[chains..];
                try p.elaborateChains(slot, found, self.ctx.allocator, &loops);
                try resolve.resolveChains(self.ctx, found, loops.items, fresh);
                self.chains.shrinkRetainingCapacity(chains);
            }
            if (options) {
                const open = self.ctx.pauseTrail();
                defer self.ctx.resumeTrail(open);
                var kept: std.ArrayList(rig.GroupUse) = .empty;
                defer kept.deinit(self.ctx.allocator);
                for (self.group_uses.items[uses..]) |u| if (self.rewritesGroup(u.group)) try kept.append(self.ctx.allocator, u);
                var binds: std.ArrayList(rig.Parser.Flattened) = .empty;
                defer binds.deinit(self.ctx.allocator);
                try p.elaborateOptions(slot, &self.ctx.flat_groups, kept.items, self.spreads.items[spreads..], self.ctx.allocator, &binds);
                for (binds.items) |f| try resolve.bindGroup(self.ctx, f);
                self.group_uses.shrinkRetainingCapacity(uses);
                self.spreads.shrinkRetainingCapacity(spreads);
            }
            // A module constant's value is folded before any body is
            // checked (`resolve.foldModuleConsts`), so one written anew
            // is folded again, with the constants that name it. A body's
            // assignment is no constant: folding then would run a
            // compile-time function while it is checked.
            if (decl and rig.isModuleConst(slot.*)) try resolve.refoldModuleConsts(self.ctx);
        }
    }

    /// Whether `check` checks a module's declaration (`checkDecl`).
    pub fn isDeclCheck(comptime check: anytype) bool {
        if (@TypeOf(check) != @TypeOf(Checker.checkDecl)) return false;
        return check == Checker.checkDecl;
    }

    /// Whether a use of the group at `pos` is rewritten: a group made
    /// parameters (`flattenGroups`) whose body writes it not.
    pub fn rewritesGroup(self: *Checker, pos: u32) bool {
        return self.ctx.flat_groups.contains(pos) and !self.refused.contains(pos);
    }

    /// Whether a use found since `from` is one to rewrite.
    pub fn groupRewrites(self: *Checker, from: usize) bool {
        for (self.group_uses.items[from..]) |u| if (self.rewritesGroup(u.group)) return true;
        return false;
    }

    /// Whether `s`, a block's statement or a module's declaration, is a
    /// string literal or may hold a form rewritten once types are known
    /// (`checkRewritten`).
    pub fn mayRewrite(self: *Checker, s: Sexp) bool {
        return switch (s) {
            .src => sema.isStringLiteralText(self.text(s)),
            .list => if (self.ctx.parser) |p| p.marked(.rewrite, s) else false,
            else => false,
        };
    }

    /// A function's last value, which is used (`value_tails`). It is the
    /// function's result, which hands its views to the caller, so a
    /// branch there is not viewed where it stands (`checkExpr`).
    pub fn checkTail(self: *Checker, e: Sexp, ret: TypeId) Error!void {
        try self.noteValueTail(e);
        const mark = self.ctx.diagnostics.items.len;
        try ViewCheck.checkExprAgainst(self, e, ret);
        if (self.ctx.diagnostics.items.len == mark) try ViewCheck.keptViews(self, e, .returned);
    }

    /// A closure's or a block's last value, which is used.
    pub fn synthTail(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
        try self.noteValueTail(e);
        if (expected) |ty| {
            try ViewCheck.checkExpr(self, e, ty);
            return ty;
        }
        return PatternCheck.synthExpr(self, e);
    }

    // =========================================================================
    // Statements
    // =========================================================================

    pub fn noteValueTail(self: *Checker, e: Sexp) Error!void {
        if (e == .list) try self.value_tails.put(self.ctx.allocator, CompatCheck.nodeId(e), {});
    }

    // ---- bindings and assignment --------------------------------------------

    // ---- several results ------------------------------------------------------

    // ---- places -------------------------------------------------------------

    /// What is done with a place: written by assignment, `!p`, or
    /// `for x in !p`; emptied by `<p.f`; where it holds a `!T`, passed on
    /// (by `!p.f`, or passed where a value holding a `!T` goes) or
    /// written through; or, where it is a Cell, changed in place.
    pub const Access = enum {
        assign,
        write_viewed,
        write_iterate,
        take,

        /// How a diagnostic names the access: "cannot {head} <object>{tail}".
        pub fn verb(a: Access) Verb {
            return switch (a) {
                .assign => .{ .head = "assign to" },
                .write_viewed => Verb.write_viewed,
                .write_iterate => .{ .head = "write-iterate" },
                .take => .{ .head = "take" },
            };
        }
    };

    /// The verb of a diagnostic about an access, around its object:
    /// "cannot change `x`".
    pub const Verb = struct {
        head: []const u8,
        tail: []const u8 = "",

        const write_viewed: Verb = .{ .head = "change" };
    };

    /// Where a place starts.
    pub const Root = enum {
        /// A binding of the body being checked.
        local,
        param,
        capture,
        /// A loop or pattern binding that holds a value: a copy of what
        /// it binds, unless a resource was moved into it.
        pattern,
        /// A module-level binding: fixed (a constant), or not.
        constant,
        global,
        /// An imported module, whose binding is `module.name`.
        module,
        /// A value no binding holds: a call's result, a literal, a
        /// moved or cloned handle.
        temporary,
        /// A view a call or sigil yields, or a handle one yields that
        /// the path reaches through: the place is its owner's.
        view,
        /// A name that is no binding, or a value of no known type.
        other,
    };

    /// Why a place is read-only: a `*T` on the way, which other handles
    /// may share; an element of a `[]T` or a `?String`, a `.len`, an
    /// enum's or a symbol's `.text`, or a field another module declared read-only; or
    /// a `?T` on the way.
    /// Where several apply, the first in that order.
    pub const Block = enum {
        shared,
        slice,
        string,
        len,
        /// `e.text`, the name of a plain enum value's variant.
        text,
        /// `s.text`, the name of a symbol.
        symbol_text,
        /// A field another module declared `pub ?name: T`.
        read_only,
        /// The field by which an object names its none (`none id == 0`),
        /// which only its constructor sets.
        none_field,
        read_view,

        pub fn rank(b: Block) u2 {
            return switch (b) {
                .shared => 0,
                .slice, .string, .len, .text, .symbol_text, .read_only, .none_field => 1,
                .read_view => 2,
            };
        }
    };

    /// A place expression (a name, or a field or element of one),
    /// classified once from the recorded types of the objects along its
    /// path (`a` and `a.b` in `a.b.c`).
    pub const Place = struct {
        node: Sexp = .nil,
        /// The expression the path starts from, and where it starts.
        base: Sexp = .nil,
        pos: u32 = 0,
        root: Root = .other,
        /// The binding the base names.
        sym: ?SymbolId = null,
        /// `module.name`, when the base names an imported module.
        module_member: ?Sexp = null,
        /// The fields and elements on the path; whether all are fields.
        steps: u32 = 0,
        fields_only: bool = true,
        /// A range index `xs[a..b]` is on the path.
        sliced: bool = false,
        /// A view or handle is on the way.
        indirect: bool = false,
        /// What makes the place read-only, and where: the outermost
        /// step of the first kind that applies.
        blocked: ?struct { why: Block, pos: u32 } = null,
        /// For a `.read_only` block: the field, as the access reaches it.
        read_only: ?sema.ReadOnlyField = null,
        /// The `c[i]` the path goes through where `c` is a
        /// `Cell[List[E]]`: such an element is a copy, read or written
        /// whole.
        cell_list_elem: ?Sexp = null,
        /// The path starts at a write view, `(!c)[i]`.
        marked: bool = false,
        /// A read view, a slice, a `?String`, or a `.len` stands between the
        /// path's end and the shared handle it crosses (or its base, if
        /// it crosses none).
        leaf_blocked: bool = false,
        /// A read view stands on the path: nothing changes through it, a
        /// Cell behind a handle it views or reaches included.
        view_blocked: bool = false,
        /// The outermost read view on the path, and where it starts.
        view: ?struct { ty: TypeId, pos: u32 } = null,
        /// The path crosses a shared handle (`sema.accessThroughShared`).
        crossed: bool = false,
        /// Where the place itself holds a read view (`out` of `out = ?a`),
        /// or a write view of one (`x` of `for x in !vs` over a `List[?T]`):
        /// assigned whole, it points elsewhere; written through, it
        /// writes what it views, which nothing does through a read view.
        holds_view: ?u32 = null,

        /// A name, or a field or element of one: storage with an owner.
        pub fn named(p: Place) bool {
            return p.base == .src and !p.sliced;
        }

        /// A name, or a chain of fields off one: `v`, `t.kids`, `a.b.c`.
        pub fn fieldPath(p: Place) bool {
            return p.base == .src and p.fields_only;
        }

        pub fn block(p: *Place, why: Block, pos: u32) void {
            if (p.blocked) |b| if (b.why.rank() <= why.rank()) return;
            p.blocked = .{ .why = why, .pos = pos };
        }
    };

    // ---- conditionals and loops ---------------------------------------------

    pub const Position = enum { statement, value };

    /// A condition whose `and` chain may narrow (`plain_cond`): its
    /// operands, where it ends, and the code it guards.
    pub const PlainCond = struct { operands: []const Sexp, end: u32, guarded: []const diag.Span };

    /// Whether a `for` source of type `ty` is an iterator, as the one
    /// classifier, `sema.iterItem`, decides for the loop and the `Iter`
    /// bound alike. A type with a `next` of another shape is `.malformed`,
    /// so the mistake is reported where the loop is.
    pub const IterShape = union(enum) { not_iterator, malformed: []const u8, iterator };

    /// What a `for` over `source` is, as `iterLoop` finds it.
    pub const IterFor = union(enum) {
        /// Not a loop over an iterator: the `for` walks its source.
        not_iterator,
        /// A loop over an iterator, rejected where it stands.
        rejected,
        /// A loop over an iterator, which is the `while` it means
        /// (`elaborateFor`), walking its source so.
        rewrite: rig.IterSource,
    };

    pub const LoopPair = struct { elem: SymbolId, index: SymbolId, source: Sexp };

    // ---- match ----------------------------------------------------------------

    /// What `checkMatchSubject` found of a `match`'s subject.
    pub const MatchSubject = struct {
        mode: MatchMode,
        scrutinee: TypeId,
        hands: sema.Hands,
        pos: u32,
        matchable: bool,
    };

    /// The values of a variant a pattern matches: what it tests of each
    /// payload field (`sema.PayloadTest`), so a cube of the variant's
    /// values, in which each optional field holds a value or none. A
    /// pattern that tests no field matches the whole variant.
    pub const Cube = []const sema.PayloadTest;

    /// One alternative of the arm being checked: its variant (or error)
    /// key, and the values it matches (null: every value of it).
    pub const ArmAlt = struct { name: []const u8, cube: ?Cube, pos: u32 };

    /// What the arms of a match have covered so far.
    pub const MatchCoverage = struct {
        /// Variants (and errors, and other keys) every value of which an
        /// unguarded arm covers, and where the first such arm is.
        variants: std.StringHashMapUnmanaged(u32) = .empty,
        /// Variants unguarded arms cover only some values of, by testing
        /// optional fields: the cube each such alternative matches. They
        /// join `variants` once they cover the whole variant.
        parts: std.StringHashMapUnmanaged(std.ArrayList(Cube)) = .empty,
        /// The alternatives of the arm being checked so far: no two of one
        /// variant may match a value in common.
        arm_alts: std.ArrayList(ArmAlt) = .empty,
        bools: [2]bool = .{ false, false },
        /// Inclusive integer intervals, disjoint, apart, and in order.
        ints: std.ArrayList([2]Wide) = .empty,
        has_default: bool = false,
        /// An arm's pattern was rejected without saying what it meant to
        /// cover: whether the arms cover every value is not known.
        rejected: bool = false,
        /// Variants only a guarded arm matches, which covers none.
        guarded: std.StringHashMapUnmanaged(void) = .empty,
        /// How many variants the scrutinee's type has, when it is an
        /// enum (`sema.enumVariantCount`), counted once for the match.
        variant_total: ?usize = null,
        /// For a guarded arm, which covers nothing after it, what the
        /// arms before it cover: its patterns may not repeat that either,
        /// and what they cover is its own.
        before: ?*const MatchCoverage = null,
        /// The type matched, whose variants' fields name a cube's tests.
        subject: TypeId = sema.type_invalid,

        pub fn deinit(c: *MatchCoverage, a: std.mem.Allocator) void {
            c.variants.deinit(a);
            var it = c.parts.valueIterator();
            while (it.next()) |l| l.deinit(a);
            c.parts.deinit(a);
            c.arm_alts.deinit(a);
            c.ints.deinit(a);
            c.guarded.deinit(a);
        }

        /// The cubes of variant `name` the arms so far cover, here and
        /// before, appended to `out`.
        pub fn partsOf(c: *const MatchCoverage, name: []const u8, a: std.mem.Allocator, out: *std.ArrayList(Cube)) std.mem.Allocator.Error!void {
            if (c.parts.get(name)) |l| try out.appendSlice(a, l.items);
            if (c.before) |b| try b.partsOf(name, a, out);
        }

        /// Where the pattern that first covered variant (or error) key
        /// `name` is.
        pub fn variantAt(c: *const MatchCoverage, name: []const u8) ?u32 {
            if (c.variants.get(name)) |pos| return pos;
            return if (c.before) |b| b.variantAt(name) else null;
        }

        /// Whether a pattern covered Bool value `i` (0 for `false`).
        pub fn hasBool(c: *const MatchCoverage, i: usize) bool {
            return c.bools[i] or if (c.before) |b| b.hasBool(i) else false;
        }

        /// Whether a pattern covered a value from `lo` to `hi`.
        pub fn overlapsInts(c: *const MatchCoverage, lo: Wide, hi: Wide) bool {
            const ints = c.ints.items;
            const at = intsAfter(ints, lo);
            if ((at > 0 and ints[at - 1][1] >= lo) or (at < ints.len and ints[at][0] <= hi)) return true;
            return if (c.before) |b| b.overlapsInts(lo, hi) else false;
        }

        /// The first of `ints` that starts after `lo`: of an interval
        /// from `lo`, only it and the one before it can overlap.
        pub fn intsAfter(ints: []const [2]Wide, lo: Wide) usize {
            return std.sort.upperBound([2]Wide, ints, lo, struct {
                pub fn order(key: Wide, iv: [2]Wide) std.math.Order {
                    return std.math.order(key, iv[0]);
                }
            }.order);
        }
    };

    /// A header's subject without its sigil, and the sigil (`?S`, `!S`):
    /// the same for `match`, `if … as`, `while … as`, and `for` (whose `?`
    /// and `!` are its mode).
    pub const HeaderSubject = struct { node: Sexp, sigil: ?ViewKind };

    // =========================================================================
    // Expressions: synthesis
    // =========================================================================

    pub const entry_point_use = "`main` is the program's entry point; it cannot be called or used as a value";

    pub const MemberKind = enum { field, method, associated };

    // ---- operators ------------------------------------------------------------

    // ---- ownership sigils -----------------------------------------------------

    pub const ViewKind = enum { read, write };

    /// What a function value is where a call runs it: the one classifier
    /// for every call that runs a function on another task or on several
    /// at once (a task's or an actor's argument, `par.map` and
    /// `par.each`, `http.serve`, `task.isolate` and `task.supervise`) and
    /// for `task.select`'s arms.
    pub const FnArg = enum {
        /// A closure written in the call: its captures are checked
        /// where it goes.
        literal,
        /// A function's name, which captures nothing.
        named,
        /// A closure binding, `g`: it holds its captures and goes
        /// nowhere; its view `?g` is what reaches a call.
        binding,
        /// A closure's or a function's callable view (`?g`), or an owned
        /// closure (`*|...| body`), whose type does not show what it
        /// captures.
        view,
        /// No function value.
        other,
    };

    // ---- member access and indexing -------------------------------------------

    /// A method of a self's nominal type, local or imported, with
    /// its signature in this module's types.
    pub const Method = struct {
        field: Field,
        fn_ty: FunctionType,
        owner: []const u8,
        /// The type's symbol; `symbol_invalid` for an imported type.
        nominal_sym: SymbolId,
        /// Source of the module that declares the parameter defaults.
        source: []const u8,
        /// The type's symbol, and the module it is in: null for this one.
        owner_sym: sema.Symbol,
        module: ?u32 = null,
        /// The type's generic arguments, for a local type.
        args: []const TypeId = &.{},
    };

    /// A nominal type named where a value could be (`Type`, or
    /// `module.Type` for an imported one), whose members `Type.name`
    /// and `Type.name(...)` reach.
    pub const NamedType = struct {
        id: SymbolId,
        sym: sema.Symbol,
        /// Where an imported type is declared.
        foreign: ?ForeignFields = null,
        /// A generic type's arguments, when given (`Pair[Int, ?String]`).
        args: ?[]const TypeId = null,
    };

    // ---- compile-time arguments ---------------------------------------------
    //
    // `x[...]` is an `index` (one argument) or an `inst` (more) in the IR.
    // It gives compile-time arguments when `x` names a generic type or a
    // function; otherwise it indexes. Each bracket list read as
    // compile-time arguments is recorded as an instance
    // (`SemContext.instanceOf`).

    /// What the object of a bracket list names, when that makes the list
    /// compile-time arguments; null when it is an index.
    pub const InstTarget = union(enum) {
        /// A generic type, local or built in: `List[Int]`.
        generic: NamedType,
        /// A function, named directly, through its module, or through
        /// its type: `check[.strict]`, `m.f[2]`, `Pair.make[1]`.
        function: FnTarget,
        /// `value.name[...]`: a method's compile-time arguments, or an
        /// element of a field; self's type tells which.
        value_member,
        /// A type that takes no type arguments; its name.
        not_generic: []const u8,
        /// A generic type of another module that is not public, reported.
        reported,
    };

    /// Whether a function has compile-time and run-time parameters.
    pub const FnTarget = struct { ct_params: bool, takes_args: bool };

    pub const Foreign = struct {
        ctx: *SemContext,
        module_id: u32,
        id: SymbolId,
        sym: sema.Symbol,
    };

    // ---- array literals ------------------------------------------------------

    // =========================================================================
    // Calls
    // =========================================================================

    /// A part that goes to a task (`crossCheck`): the type it goes as,
    /// how, where, and how it is passed, for `requireTask`.
    pub const Gone = struct { ty: TypeId, how: sema.Crossing, pos: u32, passed: []const u8 };

    /// How a value is hidden from the rules that wait for a task
    /// (`hidesNoTask`).
    pub const Hidden = enum { erased, isolated, captured };

    /// Where a `panic` stands (`placePanics`).
    pub const PanicPlace = enum {
        /// A statement, or a branch's value: allowed.
        statement,
        /// Where a value is needed.
        value,
        /// In a `defer` or `errdefer`.
        deferred,
    };

    // ---- templates -------------------------------------------------------------

    // ---- vectors --------------------------------------------------------------

    /// How an element is used, for the error of an element a type has no
    /// index for: assigned, changed by an operator, viewed for writing, or
    /// read.
    pub const IndexUse = struct {
        at: Sexp = .nil,
        form: enum { read, assign, compound, write_view } = .read,
        /// The assigned value's text, and the operator written (`+=`).
        rhs_text: []const u8 = "",
        op: []const u8 = "",
    };

    /// What is done to a lane where a place would be.
    pub const LaneUse = enum { assign, read_viewed, write_viewed, take };

    /// What a call needs to know about a callee's parameters beyond its
    /// type: names for keyword arguments and default values.
    pub const ParamInfo = struct {
        names: ?[]const []const u8 = null,
        defaults: ?[]const ?Sexp = null,
        /// Source of the module that declares the defaults.
        source: []const u8 = "",
        /// The parameters that take a duration form (`sema.duration`).
        durations: sema.ParamMask = 0,
        /// The parameters that belong to a group (`sema.GroupParam`), once
        /// read (`withGroups`) from the declaring module's
        /// `group_params` at `group_pos`, after `group_skip` of them.
        groups: ?[]const ?sema.GroupParam = null,
        group_pos: ?u32 = null,
        group_skip: u32 = 0,
        /// The callee waits the duration it is given, so a negative
        /// constant is refused: `time.sleep`, `time.within`, `time.after`,
        /// and `per:` (`sema.duration.waits`).
        waits: bool = false,
        /// The callee adds a duration to a value with no calendar,
        /// `datetime.Instant`'s `add`, so the fix for `days:` names a
        /// zone (`sema.duration.zoneless`).
        zoneless: bool = false,
        /// The callee is std.datetime's, whose failures are its
        /// `DateTimeError` (`durationFold`).
        datetime: bool = false,
        /// The error set a duration form that can fail joins, the
        /// callee's own, when the callee returns `!` (`durationFold`).
        fold: ?sema.FoldInto = null,

        pub fn default(self: ParamInfo, i: usize) ?Sexp {
            const d = self.defaults orelse return null;
            return if (i < d.len) d[i] else null;
        }

        /// The group parameter `i` belongs to, or null.
        pub fn group(self: ParamInfo, i: usize) ?sema.GroupParam {
            const g = self.groups orelse return null;
            return if (i < g.len) g[i] else null;
        }

        pub fn isDuration(self: ParamInfo, i: usize) bool {
            return self.durations != 0 and i < @bitSizeOf(sema.ParamMask) and self.durations & sema.paramBit(i) != 0;
        }

        /// The duration parameter a unit's keyword fills, `ms:` of
        /// `time.sleep(ms: 40)`: the callee's one duration parameter; none
        /// when it has two or more, each given by its own name.
        pub fn unitParam(self: ParamInfo) ?usize {
            if (@popCount(self.durations) != 1) return null;
            return @ctz(self.durations);
        }
    };

    /// What fills a call's parameters besides its arguments, and which
    /// of them it passes loans on from (`sema.CallParams`).
    pub const CallSite = struct {
        /// A method called on a value: its self fills parameter 0,
        /// before those `checkArgs` checks.
        has_self: bool = false,
        origins: sema.Origins = .{},
        /// The parameters as declared, before a generic call's
        /// instance is substituted, when known: what a diagnostic says
        /// a parameter would have to be (`Slot`).
        declared: []const TypeId = &.{},
    };

    /// The parameter or field of a call or constructor that an argument
    /// fills, as a diagnostic names it (`ignoredWriteView`).
    pub const Slot = struct {
        /// The argument or field value.
        value: Sexp = .nil,
        /// The call or construction it is written in.
        call: Sexp = .nil,
        /// A field's: what the construction makes, as written
        /// (`Opt.some`, `G[Int]`).
        field: bool = false,
        owner: []const u8 = "",
        /// A call's parameters as declared (`CallSite.declared`).
        params: []const TypeId = &.{},
        /// The slot's type as declared, when known: `T` in a generic.
        declared: TypeId = sema.type_invalid,
        /// A field of a generic type's instance: the instance's
        /// arguments, which a type parameter `declared` is one of.
        subst: TypeSubst = .empty,
        /// The arguments whose `!` their slots ignore (`plainSlotViews`).
        views: []const Sexp = &.{},
    };

    /// Compile-time argument `i` of `callee`, a value of type `ty`.
    pub fn checkCtValue(self: *Checker, a: Sexp, ty: TypeId, i: usize, callee: []const u8) Error!void {
        if (StdFormCheck.isTypeName(self, a)) return self.errAt(a, "compile-time argument {d} of `{s}` is a value of type `{s}`, not a type", .{ i + 1, callee, try self.tyName(ty) });
        const mark = self.ctx.diagnostics.items.len;
        try ViewCheck.checkExpr(self, a, ty);
        if (self.ctx.diagnostics.items.len != mark or CallCheck.isComptimeKnown(self, a)) return;
        const fixed = a == .src and if (self.ctx.symbolOf(a)) |id| self.ctx.symbols.items[id].flags.fixed else false;
        if (CallCheck.isCtArithmetic(self, a)) {
            try self.errAt(a, "compile-time argument {d} of `{s}` does arithmetic on a compile-time parameter, which Rig cannot check for overflow or division by zero; use a parameter or a constant", .{ i + 1, callee });
        } else if (fixed) {
            try self.errAt(a, "compile-time argument {d} of `{s}` must be known at compile time; `{s}` is bound with `=!` to a value computed when the program runs", .{ i + 1, callee, self.text(a) });
        } else try self.errAt(a, "compile-time argument {d} of `{s}` must be known at compile time; pass a literal, an enum value, a module constant, a compile-time parameter, a `=!` binding of one, or arithmetic on them", .{ i + 1, callee });
    }

    /// Where inside an argument's type `bindArg` found a type
    /// parameter: the steps down from the argument's whole type, each a
    /// function type's parameter or result or a generic type's
    /// argument. A conflict inside one argument names each side by them
    /// (`whereText`).
    pub const Where = struct {
        const cap = 4;
        const Step = struct { kind: enum(u8) { param, result, type_arg }, index: u8 = 0, count: u8 = 0 };
        len: u8 = 0,
        /// Deeper than `cap` steps: not named.
        deep: bool = false,
        steps: [cap]Step = undefined,

        pub fn with(w: Where, step: Step) Where {
            var next = w;
            if (w.len == cap) {
                next.deep = true;
            } else {
                next.steps[w.len] = step;
                next.len += 1;
            }
            return next;
        }

        pub fn eql(a: Where, b: Where) bool {
            if (a.len != b.len or a.deep != b.deep) return false;
            for (a.steps[0..a.len], b.steps[0..b.len]) |x, y| {
                if (x.kind != y.kind or x.index != y.index) return false;
            }
            return true;
        }
    };

    /// What the arguments of a call say about one type parameter: the
    /// type the first non-literal argument gives it, and the first
    /// argument that gives it another, each with where inside its
    /// argument it was found.
    pub const Bound = struct {
        ty: TypeId = sema.type_invalid,
        arg: u32 = 0,
        at: Where = .{},
        conflict: TypeId = sema.type_invalid,
        conflict_arg: u32 = 0,
        conflict_at: Where = .{},
        /// `ty` is the one the call's expected type gives.
        expected: bool = false,
        /// The type the expected type gives, where an argument gave
        /// another.
        wanted: TypeId = sema.type_invalid,
        /// A `none` argument fills the parameter itself, which must then
        /// be an optional.
        none: bool = false,
        /// The type an argument binds it to where that type is held
        /// exactly: written through, or the argument of a generic type,
        /// an array, a handle, or a function type.
        held_ty: TypeId = sema.type_invalid,
        /// `ty` is `?String` only because a `?T` met a `?String`, the read
        /// view of a `String`: the parameter is that `?String` or the `String`
        /// it views, and a `String` another argument gives it settles it.
        text_view: bool = false,
    };

    /// A literal argument where a type parameter goes: it gives the
    /// parameter its default type (`Int`, `Float`) only when no other
    /// argument gives it a type.
    pub const LiteralBound = struct { param: usize, ty: TypeId, arg: u32 };

    pub const Inference = struct {
        own: []const SymbolId,
        bound: []Bound,
        literals: std.ArrayList(LiteralBound) = .empty,
        /// The first argument whose type does not have the shape of the
        /// type it fills (`?[3]Int` where `[]T` goes), with the whole
        /// parameter type and argument type.
        mismatch: ?struct { arg: u32, pattern: TypeId, actual: TypeId } = null,
        /// The type expected of the result does not have the declared
        /// result's shape.
        result_mismatch: bool = false,
        /// An argument's type or the expected type holds poison: a
        /// diagnostic about it explains a parameter left unbound.
        poisoned: bool = false,
        /// How many held places `bindArg` is inside (`Bound.held`).
        exact: u8 = 0,
        /// Where inside the argument `bindArg` is matching.
        at: Where = .{},
        /// `bindArg` is matching the `T` of a `?T` against a `?String`.
        viewing: bool = false,
        /// `bindArg` is matching a closure literal, whose failure binds
        /// no set parameter (`bindSet`).
        lambda: bool = false,
        /// Bit `i`: a closure literal fails where set parameter `own[i]`
        /// goes; with nothing else to bind it, it is `error`.
        lambda_sets: u64 = 0,
        lambda_arg: u32 = 0,
        /// The closure literals whose parameters were all known and whose
        /// quiet check found errors (`viewedLambdaType`).
        failed: std.ArrayList(FailedLambda) = .empty,
    };

    /// A closure literal argument of a generic call that does not check
    /// clean though its parameters' types are known: `given` them, as
    /// one that can fail when `fails`, where function type `pattern` goes.
    pub const FailedLambda = struct { lambda: Sexp, given: []const TypeId, fails: bool, pattern: TypeId };

    /// A closure literal argument of a generic call, and the function
    /// type its parameter gives it.
    pub const LambdaArg = struct { pattern: TypeId, lambda: Sexp, arg: u32 };

    /// A generic call's declared result, and the type expected of it.
    pub const ResultType = struct { pattern: TypeId, expected: TypeId };

    pub const ForeignFields = struct { ctx: *SemContext, module_id: u32 };

    pub const FieldArgs = struct {
        owner: []const u8,
        decl_pos: u32,
        /// The module whose source `decl_pos` and the fields' positions
        /// are in, for a proxy's fields; 0 for this one.
        module_id: u32 = 0,
        pos: u32,
        subst: TypeSubst = TypeSubst.empty,
        foreign: ?ForeignFields = null,
        kind: enum { constructor, variant },
        /// The call that constructs it, when not the call being checked.
        call: Sexp = .nil,
        /// The instance a generic type's constructor or variant makes.
        instance: TypeId = sema.type_invalid,
    };

    // ---- method calls -----------------------------------------------------------

    /// How a call through an API reaches its method: through a witness,
    /// or an API object's table, the object's API's, at an entry
    /// (`sema.Dispatch`).
    pub const ApiVia = union(enum) { witness: sema.Witness, table: struct { api: sema.ApiRef, slot: u32 } };

    /// A call's own compile-time arguments and the slots they fill, as
    /// `instantiateCall` binds them.
    pub const OwnArgs = struct { args: []const TypeId, slots: []const u32 };

    /// Where an inferred generic's arguments are matched: the fields a
    /// constructor or a variant's payload fills, or an associated
    /// function's parameters (with their names, for keyword arguments).
    pub const InferFrom = union(enum) {
        fields: []const Field,
        payload: []const Field,
        params: struct { params: []const TypeId, names: ?[]const []const u8, defaults: ?[]const ?Sexp = null },
    };

    // =========================================================================
    // Expressions: checking against an expected type
    // =========================================================================

    /// Where a box or a counted handle (`form`), or an optional one,
    /// moves into one of an API object (`eraseBox`, `eraseShared`):
    /// the object type it becomes (`want`), the object, whether both are
    /// optional, and the box or handle itself. Null for any other pair.
    pub const HeldInto = struct { want: TypeId, object: sema.ApiObject, optional: bool, value: TypeId };

    // ---- lasting views --------------------------------------------------------

    /// Where a value that holds a view is kept past its statement: a
    /// binding or an assignment, named by its target, or a returned value.
    pub const Kept = union(enum) {
        binding: []const u8,
        returned,
        /// Stored by the call to this callee.
        stored: []const u8,
    };

    /// The source of a statement with every view written as a path's
    /// base (`viewBase`) taken off it, the whole path given the sigil its
    /// context takes (`useOf`).
    pub const ViewBaseFix = struct {
        c: *Checker,
        root: Sexp,
        edits: std.ArrayList(Edit) = .empty,
        /// A temporary the hint binds to a name first, written as it.
        named: ?struct { view: Sexp, name: []const u8 } = null,
        /// Every path written bare, its sigil dropped (`plainText`).
        bare: bool = false,

        const Edit = struct {
            view: Sexp,
            /// The viewed place, under its sigils and `<`.
            place: Sexp,
            top: Sexp,
            /// Whether the whole path is assigned to, a header's subject,
            /// taken (`<`), written as it stands (assigned, given a write
            /// view, taken, a `for` source written, or a write method's
            /// self), reached through a shared handle, or part of a
            /// temporary.
            assigned: bool = false,
            header: bool = false,
            taken: bool = false,
            writes: bool = false,
            shared: bool = false,
            temp: bool = false,
            /// Whether its value is an optional, and whether no plain form
            /// fits its context (`valueSigil`).
            optional: bool = false,
            none: bool = false,
            /// What goes before and after the whole path: the sigil its
            /// context takes, or nothing.
            open: []const u8 = "",
            close: []const u8 = "",
            /// Where a slice on the way ends, which is viewed as a whole
            /// (`(?p.arr[0..2])[1]`), its parenthesis opened with `open`.
            slice_to: u32 = 0,
            /// Where the whole path starts and ends, and the view's span
            /// with its parentheses.
            at: u32 = 0,
            to: u32 = 0,
            reach: u32 = 0,
            start: u32 = 0,
            end: u32 = 0,
        };

        pub fn collect(f: *ViewBaseFix, n: Sexp) Error!void {
            if (n != .list or n.isKind(.lambda)) return;
            if (n.isKind(.member) or n.isKind(.index)) {
                const obj = ir.get(n, .object);
                if (ViewCheck.viewOf(f.c, obj)) |view| if (!CompatCheck.viewsSlice(view) and !f.c.methods.contains(CompatCheck.nodeId(n)) and !(CompatCheck.isCallee(f.root, n) and (ViewCheck.isSelfSigil(f.c, obj) or !ViewCheck.namesField(f.c, obj, n)))) {
                    _ = try f.add(n, obj);
                };
            }
            for (n.items()) |x| try f.collect(x);
        }

        /// What the whole path that `path` with base `obj` starts is to
        /// its context, and the sigil that context takes: the facts typing
        /// recorded (the type expected there, a method's self mode, a
        /// value tail) and the tree around it.
        pub fn useOf(f: *ViewBaseFix, path: Sexp, obj: Sexp) Error!Edit {
            const c = f.c;
            var top = path;
            while (CompatCheck.parentIn(f.root, top)) |p| {
                if (!(p.isKind(.member) or p.isKind(.index)) or !CompatCheck.sameExpr(ir.get(p, .object), top) or c.methods.contains(CompatCheck.nodeId(p))) break;
                top = p;
            }
            const view = ViewCheck.viewOf(c, obj) orelse obj;
            const place = ViewCheck.viewedThrough(c, view);
            var x: Edit = .{ .view = obj, .place = place, .top = top };
            const sigil: []const u8 = if (view.isKind(.write)) "!" else "?";
            x.reach = c.ctx.span(top).end;
            if (f.bare) return f.spans(x, obj);
            // Reached through a shared handle on the way.
            var n = top;
            while (n.isKind(.member) or n.isKind(.index)) : (n = ir.get(n, .object)) {
                const o = ir.get(n, .object);
                const o_ty = if (CompatCheck.sameExpr(o, obj)) c.ctx.typeOf(place) else c.ctx.typeOf(o);
                if (o_ty) |ty| {
                    const v = sema.unwrapViews(c.ctx, ty);
                    if (c.ctx.types.get(v) == .shared) x.shared = true;
                }
                if (CompatCheck.sameExpr(o, obj)) break;
            }
            // A part of a value made here, which no name holds: a view a
            // call returns is not one.
            if (ViewCheck.hands(c, place).kind != .place) {
                const pt = c.ctx.typeOf(place);
                x.temp = pt == null or !sema.isReadOrWriteView(c.ctx, pt.?);
            }
            if (c.ctx.typeOf(top)) |tt| x.optional = c.ctx.types.get(tt) == .optional;
            const p = CompatCheck.parentIn(f.root, top) orelse {
                f.setValueSigil(&x, top, sigil);
                return f.spans(x, obj);
            };
            switch (p.kind() orelse .module) {
                .set => if (CompatCheck.sameExpr(ir.Set.target(p), top)) {
                    x.assigned = true;
                    x.writes = true;
                } else {
                    f.setValueSigil(&x, top, sigil);
                },
                // A statement that drops: only a binding is dropped.
                .drop => x.none = true,
                .write => x.writes = true,
                .move => {
                    x.writes = true;
                    x.taken = true;
                },
                .read => {},
                // A header's subject: its binding takes the view's sigil.
                .match => if (CompatCheck.sameExpr(ir.Match.subject(p), top)) {
                    x.header = true;
                    x.open = sigil;
                },
                .as => if (CompatCheck.sameExpr(ir.As.value(p), top)) {
                    x.header = true;
                    x.open = sigil;
                },
                // A `for` walks a binding's place, or a field or element of
                // one, in place: none of a value that branches.
                .@"for" => if (CompatCheck.sameExpr(ir.For.source(p), top)) {
                    x.header = true;
                    if (ir.For.mode(p).tag == .iter) x.open = sigil;
                    x.writes = ir.For.mode(p).tag == .write;
                    if (ViewCheck.hands(c, place).kind != .place) x.none = true;
                },
                // A method's self: a write view where the method
                // writes it (in parentheses where the call's `Bool` value
                // is used), and bare otherwise.
                .member => if (c.methods.get(CompatCheck.nodeId(p))) |m| {
                    x.reach = c.ctx.span(p).end;
                    if (m.self_mode == .write) {
                        x.writes = true;
                        const call = CompatCheck.parentIn(f.root, p) orelse p;
                        const ret = c.ctx.types.get(m.returns);
                        const value = if (ret == .fallible) ret.fallible.ok else m.returns;
                        const used = !CompatCheck.sameExpr(call, f.root) or c.value_tails.contains(CompatCheck.nodeId(call));
                        const bool_used = value == c.t().bool_id and used;
                        x.open = if (bool_used) "(!" else "!";
                        x.close = if (bool_used) ")" else "";
                    }
                } else {
                    f.setValueSigil(&x, top, sigil);
                },
                else => f.setValueSigil(&x, top, sigil),
            }
            return f.spans(x, obj);
        }

        pub fn setValueSigil(f: *ViewBaseFix, x: *Edit, top: Sexp, sigil: []const u8) void {
            if (f.valueSigil(top, sigil)) |open| {
                x.open = open;
            } else x.none = true;
        }

        /// The sigil a path read as a value takes from its context, or
        /// null where no plain form fits it:
        /// - a slice of an array, a List, or a String is a view: `?` (`!`
        ///   where a write view goes);
        /// - where a write view is expected, `!`;
        /// - where a read view is, `?`, but none for an argument a `?T`
        ///   parameter takes (viewed implicitly), or for a value that is a
        ///   view already;
        /// - where a value is, none if it copies, a clone `+` if it does
        ///   not, and null if it is not the value expected;
        /// - where nothing is expected, the view's own sigil if the value
        ///   is taken and does not copy, and none otherwise.
        /// A leaf of a value that branches takes the branch's context.
        pub fn valueSigil(f: *ViewBaseFix, top: Sexp, sigil: []const u8) ?[]const u8 {
            const c = f.c;
            var at = top;
            while (CompatCheck.parentIn(f.root, at)) |p| {
                const leaf = switch (p.kind() orelse break) {
                    .@"if" => !CompatCheck.sameExpr(ir.If.cond(p), at),
                    .@"??", .@"catch" => true,
                    else => false,
                };
                if (!leaf) break;
                at = p;
            }
            // A path its own check rejected has no plain form to give.
            const top_ty = c.ctx.typeOf(top) orelse return null;
            if (c.isPoison(top_ty)) return null;
            const copies = sema.copies(c.ctx, top_ty) == .yes;
            const want_ty = c.expected.get(CompatCheck.nodeId(at));
            if (top.isKind(.index) and ir.Index.index(top).isKind(.@"..")) {
                if (want_ty) |w| if (c.ctx.types.get(w) == .write_view or sema.writeSliceElem(c.ctx, w) != null) return "!";
                return "?";
            }
            if (want_ty) |want| {
                var inner = want;
                var opt = false;
                while (c.ctx.types.get(inner) == .optional) {
                    inner = c.ctx.types.get(inner).optional;
                    opt = true;
                }
                switch (c.ctx.types.get(inner)) {
                    .write_view => return "!",
                    .read_view => return if (!opt and f.implicitArg(at)) "" else "?",
                    .slice, .string_view => if (!sema.holdsWriteView(c.ctx, inner)) {
                        if (sema.writeSliceElem(c.ctx, inner) != null) return "!";
                        return if (CompatCheck.compatible(c.ctx, top_ty, inner)) "" else "?";
                    },
                    else => {},
                }
                if (sema.holdsWriteView(c.ctx, want)) return "!";
                if (!CompatCheck.compatible(c.ctx, top_ty, want)) return null;
                if (copies) return "";
                return if (sema.cloneable(c.ctx, top_ty) != .no) "+" else null;
            }
            // A branch whose other leaves are views takes their sigil.
            if (!CompatCheck.sameExpr(at, top)) {
                var leaves: std.ArrayList(Sexp) = .empty;
                defer leaves.deinit(c.ctx.allocator);
                sema.yieldedLeaves(c.ctx.allocator, c.ctx.source, at, &leaves) catch return "";
                for (leaves.items) |l| {
                    if (l.isKind(.write)) return "!";
                    if (l.isKind(.read)) return "?";
                }
            }
            // A value taken that does not copy keeps the view's sigil: a
            // binding's, an element's.
            if (!copies) {
                const taken = c.ctx.useOf(at) == .take or if (CompatCheck.parentIn(f.root, at)) |p| p.isKind(.set) or p.isKind(.array) else false;
                if (taken) return sigil;
            }
            return "";
        }

        /// Whether `e` is an argument of a call of a function or a method,
        /// where a read view is made without a written `?`; a type's
        /// constructor stores it.
        pub fn implicitArg(f: *ViewBaseFix, e: Sexp) bool {
            var p = CompatCheck.parentIn(f.root, e) orelse return false;
            if (p.isKind(.kwarg)) p = CompatCheck.parentIn(f.root, p) orelse return false;
            if (!p.isKind(.call)) return false;
            const callee = ir.Call.callee(p);
            if (CompatCheck.sameExpr(callee, e)) return false;
            if (f.c.methods.contains(CompatCheck.nodeId(callee))) return true;
            const ty = f.c.ctx.typeOf(callee) orelse return false;
            return switch (f.c.ctx.types.get(sema.unwrapViews(f.c.ctx, ty))) {
                .function => true,
                else => sema.ownedClosureFn(f.c.ctx, ty) != null,
            };
        }

        pub fn spans(f: *const ViewBaseFix, edit_: Edit, obj: Sexp) Edit {
            var x = edit_;
            const top = x.top;
            const src = f.c.ctx.source;
            var ls = f.c.ctx.span(obj);
            // Every pair of parentheses around the view alone, `((!p))`,
            // but not a call's.
            while (true) {
                var i = ls.start;
                while (i > 0 and CompatCheck.isBlank(src[i - 1])) i -= 1;
                var j = ls.end;
                while (j < src.len and CompatCheck.isBlank(src[j])) j += 1;
                if (i == 0 or j >= src.len or src[i - 1] != '(' or src[j] != ')') break;
                const k = i - 1;
                if (k > 0 and (std.ascii.isAlphanumeric(src[k - 1]) or src[k - 1] == '_' or src[k - 1] == ')' or src[k - 1] == ']')) break;
                ls = .{ .start = i - 1, .end = j + 1 };
            }
            const ts = f.c.ctx.span(top);
            // A slice on the way below the top is viewed as a whole: a view
            // of a slice is a view, kept as a path's base.
            if (!f.bare) {
                var n = x.top;
                var slice: ?Sexp = null;
                while (n.isKind(.member) or n.isKind(.index)) : (n = ir.get(n, .object)) {
                    if (n.isKind(.index) and ir.Index.index(n).isKind(.@"..")) slice = n;
                    if (CompatCheck.sameExpr(ir.get(n, .object), obj)) break;
                }
                // Only a place is sliced: a value that branches is not.
                if (slice != null and ViewCheck.hands(f.c, x.place).kind != .place) x.none = true;
                if (slice) |sl| if (!CompatCheck.sameExpr(sl, x.top)) {
                    const view = ViewCheck.viewOf(f.c, obj) orelse obj;
                    const sig: []const u8 = if (x.writes and view.isKind(.write)) "(!" else "(?";
                    x.open = std.mem.concat(f.c.ctx.arena.allocator(), u8, &.{ x.open, sig }) catch x.open;
                    x.slice_to = f.c.ctx.span(sl).end;
                };
            }
            x.at = @min(ts.start, ls.start);
            x.to = @max(ts.end, ls.end);
            x.reach = @max(x.reach, ls.end);
            x.start = ls.start;
            x.end = ls.end;
            return x;
        }

        pub fn add(f: *ViewBaseFix, path: Sexp, obj: Sexp) Error!Edit {
            const x = try f.useOf(path, obj);
            try f.edits.append(f.c.ctx.arena.allocator(), x);
            return x;
        }

        pub fn edit(f: *const ViewBaseFix, view: Sexp) ?Edit {
            for (f.edits.items) |x| if (CompatCheck.sameExpr(x.view, view)) return x;
            return null;
        }

        /// Where `n` starts: the first of its parts, which a sigil the
        /// tree moved inward (`!v[0].bump()`) may start before it.
        pub fn start(f: *const ViewBaseFix, n: Sexp, from: u32) u32 {
            var s = from;
            if (n == .list and !n.isKind(.lambda)) {
                if (n.list.len > 1) s = @min(s, f.c.ctx.span(n).start);
                for (n.items()) |x| s = f.start(x, s);
            } else if (n == .src) s = @min(s, n.src.pos);
            return s;
        }

        /// The source from `from` to `to`, each edit within it applied.
        pub fn write(f: *const ViewBaseFix, out: *std.ArrayList(u8), from: u32, to: u32) Error!void {
            return f.writeWithin(out, from, to, null);
        }

        /// `write`, inside the edit at `inside`, whose view is not met
        /// again.
        pub fn writeWithin(f: *const ViewBaseFix, out: *std.ArrayList(u8), from: u32, to: u32, inside: ?usize) Error!void {
            const a = f.c.ctx.arena.allocator();
            const src = f.c.ctx.source;
            const opened = try a.alloc(bool, f.edits.items.len);
            const closed = try a.alloc(bool, f.edits.items.len);
            const sliced = try a.alloc(bool, f.edits.items.len);
            @memset(opened, false);
            @memset(closed, false);
            @memset(sliced, false);
            var at = from;
            while (true) {
                // The next point an edit changes, in source order: a
                // sigil moved onto a path, a view taken off it, or the
                // parenthesis that closes a path.
                const Step = enum { open, view, close, slice_close };
                var next: ?struct { i: usize, step: Step } = null;
                var pos: u32 = to + 1;
                for (f.edits.items, 0..) |x, i| {
                    if (x.close.len > 0 and !closed[i] and x.to >= at and x.to <= to and x.to < pos) {
                        next = .{ .i = i, .step = .close };
                        pos = x.to;
                    }
                    if (x.slice_to != 0 and !sliced[i] and x.slice_to >= at and x.slice_to <= to and x.slice_to < pos) {
                        next = .{ .i = i, .step = .slice_close };
                        pos = x.slice_to;
                    }
                }
                for (f.edits.items, 0..) |x, i| {
                    if (x.open.len > 0 and !opened[i] and x.at >= at and x.at < to and x.at <= pos) {
                        next = .{ .i = i, .step = .open };
                        pos = x.at;
                    }
                }
                for (f.edits.items, 0..) |x, i| if (i != inside and x.start >= at and x.end <= to and x.start < pos) {
                    next = .{ .i = i, .step = .view };
                    pos = x.start;
                };
                const n = next orelse break;
                const x = f.edits.items[n.i];
                try out.appendSlice(a, src[at..pos]);
                at = pos;
                switch (n.step) {
                    .open => {
                        try out.appendSlice(a, x.open);
                        opened[n.i] = true;
                    },
                    .close => {
                        try out.appendSlice(a, x.close);
                        closed[n.i] = true;
                    },
                    .slice_close => {
                        try out.append(a, ')');
                        sliced[n.i] = true;
                    },
                    .view => {
                        if (f.named) |named| if (CompatCheck.sameExpr(named.view, x.view)) {
                            try out.appendSlice(a, named.name);
                            at = x.end;
                            continue;
                        };
                        // What a postfix would not bind is kept in
                        // parentheses: `(a if c else b).len`.
                        const base = x.place;
                        const bs = f.c.ctx.span(base);
                        const parens = !CompatCheck.postfixBinds(base) and src[bs.start] != '(';
                        if (parens) try out.append(a, '(');
                        try f.writeWithin(out, bs.start, bs.end, n.i);
                        if (parens) try out.append(a, ')');
                        at = x.end;
                    },
                }
            }
            try out.appendSlice(a, src[at..to]);
        }
    };

    /// How a view is read as the value it reaches (`readOf`).
    pub const ViewRead = union(enum) {
        /// Copied out into a slot that stores or takes this plain type
        /// (`recordAdapted`).
        slot: TypeId,
        /// Read as this value: an operand, an index, a bound, a printed
        /// value.
        value: TypeId,
        /// Passed on as a read view: `?!x`.
        read_view_of_write,
        /// Where this read view goes (a `?T`, a `[]T`, a `?String`), which
        /// only reads what it views.
        read_view: TypeId,
        /// A method's self it takes as a read view (`?@`).
        read_self: []const u8,
        /// The base of this path, which only reads what it reaches: a
        /// view of a slice (`(!arr[..])[0]`, `viewBase`).
        path: Sexp,
        /// A held write view passed where a read view of a value that
        /// copies goes, which narrows it: no `!` is written there.
        narrow,
        /// Through it a place is reached, not read as a value.
        reach,
    };

    pub const SpanOrder = struct {
        ctx: *SemContext,
        parts: []const Sexp,
        pub fn less(o: SpanOrder, x: usize, y: usize) bool {
            return o.ctx.span(o.parts[x]).start < o.ctx.span(o.parts[y]).start;
        }
    };

    /// Error set `set` as this module writes it: `E`, or `m.E` for one
    /// of a module it imports as `m`, or of a module it only reaches,
    /// which it names by that module's name, and `import` is then set.
    pub const SetSpelling = struct { text: []const u8, import: ?[]const u8 = null };

    // =========================================================================
    // Builtins
    // =========================================================================

    /// Every builtin Rig has. Rig's own, the compile-time type queries
    /// `$size(T)`, `$align(T)`, `$name(T)`, and `$type(x)` as their
    /// argument, work anywhere. Zig's keep their Zig names and work only
    /// inside `raw`: the casts, and the queries under Zig's names
    /// (`$sizeOf`), which mean what Rig's do.
    pub const Builtin = enum {
        size,
        @"align",
        name,
        type,
        sizeOf,
        alignOf,
        typeName,
        TypeOf,
        bitCast,
        intCast,
        floatCast,
        truncate,
        trunc,
        floatFromInt,
        fromBackingInt,
        variants,
        plain,
        embed,

        pub fn isSafe(b: Builtin) bool {
            return switch (b) {
                .size, .@"align", .name, .type, .variants, .plain, .embed => true,
                else => false,
            };
        }

        /// The type query `b` spells, by its Rig name, or null for a cast.
        pub fn query(b: Builtin) ?Builtin {
            return switch (b) {
                .size, .sizeOf => .size,
                .@"align", .alignOf => .@"align",
                .name, .typeName => .name,
                .type, .TypeOf => .type,
                else => null,
            };
        }
    };

    // =========================================================================
    // Closures
    // =========================================================================

};

// =============================================================================
// Compatibility and classification
// =============================================================================

// =============================================================================
// Generic requirements
// =============================================================================

// ---- stack frames -----------------------------------------------------------

// =============================================================================
// APIs of a program's own (docs/design/apis.md, Stage 3)
// =============================================================================

// =============================================================================
// Tests
// =============================================================================

pub fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { ctx: SemContext, p: parser.Parser, tree: Sexp } {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const tree = try p.parseProgram();
    const ctx = try sema.check(allocator, source, tree, .{ .is_root = true });
    return .{ .ctx = ctx, .p = p, .tree = tree };
}

pub fn expectDiagnostic(ctx: *const SemContext, needle: []const u8) !void {
    for (ctx.diagnostics.items) |d| {
        if (std.mem.find(u8, d.message, needle) != null) return;
    }
    std.debug.print("missing diagnostic containing: {s}\n", .{needle});
    for (ctx.diagnostics.items) |d| std.debug.print("  got: {s}\n", .{d.message});
    return error.TestExpectedDiagnostic;
}

pub fn expectClean(ctx: *const SemContext) !void {
    for (ctx.diagnostics.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try std.testing.expect(!ctx.hasErrors());
}

/// Typecheck's source, its files joined, which the tests read.
const typecheck_source = @embedFile("typecheck.zig") ++ @embedFile("check/builtins.zig") ++ @embedFile("check/calls.zig") ++ @embedFile("check/closures.zig") ++ @embedFile("check/expr.zig") ++ @embedFile("check/flow.zig") ++ @embedFile("check/patterns.zig") ++ @embedFile("check/stdforms.zig") ++ @embedFile("check/stmt.zig") ++ @embedFile("check/views.zig") ++ @embedFile("check/compat.zig") ++ @embedFile("check/generics.zig") ++ @embedFile("check/apis.zig");

/// That `needle` stands in `src` once in each function `want` names, as
/// many times as it names it, in any order: typecheck's files are joined
/// in no order a reader keeps.
fn expectCallers(src: []const u8, needle: []const u8, want: []const []const u8) !void {
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(std.testing.allocator);
    var from: usize = 0;
    while (std.mem.findPos(u8, src, from, needle)) |at| : (from = at + needle.len) {
        const fn_at = std.mem.findLast(u8, src[0..at], "pub fn ").?;
        try got.append(std.testing.allocator, src[fn_at + "pub fn ".len .. fn_at + std.mem.findScalar(u8, src[fn_at..], '(').?]);
    }
    const expected = try std.testing.allocator.dupe([]const u8, want);
    defer std.testing.allocator.free(expected);
    const lt = struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt;
    std.mem.sort([]const u8, expected, {}, lt);
    std.mem.sort([]const u8, got.items, {}, lt);
    try std.testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "check: implicit lift of T into T! and T?" {
    var r = try checkSource(std.testing.allocator,
        \\fun double(n: Int) -> Int!
        \\  n * 2
        \\
        \\fun maybe(n: Int) -> Int?
        \\  if n > 0
        \\    n
        \\  else
        \\    none
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
}

test "check: operators diagnose non-numeric operands" {
    var r = try checkSource(std.testing.allocator,
        \\sub main()
        \\  s = "a"
        \\  t = s + 1
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectDiagnostic(&r.ctx, "requires numeric operands; got `Static`");
}

test "check: integer literal range" {
    var r = try checkSource(std.testing.allocator,
        \\sub main()
        \\  a: U8 = 255
        \\  b: U8 = 256
        \\  c: I8 = -128
        \\  d: U8 = -1
        \\  print(a, b, c, d)
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectDiagnostic(&r.ctx, "`256` does not fit in `U8`");
    try expectDiagnostic(&r.ctx, "`-1` does not fit in `U8`");
    var count: usize = 0;
    for (r.ctx.diagnostics.items) |d| {
        if (d.severity == .@"error") count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "check: a view of a view parameter" {
    var r = try checkSource(std.testing.allocator,
        \\obj B
        \\  n: Int
        \\
        \\fun g(b: ?B) -> Int
        \\  b.n
        \\
        \\fun f(b: ?B) -> Int
        \\  g(?b)
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
}

test "check: a fallible call must be wrapped with `!` or `catch`" {
    var r = try checkSource(std.testing.allocator,
        \\fun load(id: Int) -> Int!
        \\  id
        \\
        \\obj U
        \\  n: Int
        \\
        \\  fun check(?@) -> Int!
        \\    @n
        \\
        \\sub main()
        \\  x = load(1)
        \\  u = U(n: 1)
        \\  print(x, u.check())
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectDiagnostic(&r.ctx, "fallible call to `load` must be wrapped");
    try expectDiagnostic(&r.ctx, "fallible call to `u.check` must be wrapped");
}

test "check: `!` in a fallible function, `sub main`, and a test" {
    var r = try checkSource(std.testing.allocator,
        \\fun load(id: Int) -> Int!
        \\  id
        \\
        \\fun twice(id: Int) -> Int!
        \\  load(id)! + load(id)!
        \\
        \\sub main()
        \\  print(twice(2)!)
        \\
        \\test "twice"
        \\  print(twice(1)!)
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
}

test "check: `!` needs a fallible operand and a function that can fail" {
    var r = try checkSource(std.testing.allocator,
        \\fun one() -> Int
        \\  1
        \\
        \\fun g() -> Int!
        \\  3
        \\
        \\fun two() -> Int
        \\  g()! + 1
        \\
        \\sub main()
        \\  print(one()!)
        \\  defer print(g()!)
        \\  n = 1
        \\  c = |+n|
        \\    print(g()! + n)
        \\  c()
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectDiagnostic(&r.ctx, "needs a fallible operand");
    try expectDiagnostic(&r.ctx, "requires the enclosing function `two`");
    try expectDiagnostic(&r.ctx, "inside `defer`");
    try expectDiagnostic(&r.ctx, "a closure body propagates failure only when its type can fail");
}

test "check: each distinct instance of a generic function is recorded once" {
    var r = try checkSource(std.testing.allocator,
        \\obj P
        \\  a: Int
        \\
        \\fun size[T](x: T) -> Int
        \\  y: T = x
        \\  3
        \\
        \\sub main()
        \\  print(size[Int](5))
        \\  print(size[P](P(a: 1)))
        \\  print(size(7))
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
    // `size[Int]`, spelled and inferred, and `size[P]`.
    try std.testing.expectEqual(2, r.ctx.fn_instances.items.len);
}

test "check: a quiet check takes back the facts it recorded" {
    const source =
        \\sub main()
        \\  i = 1
        \\  print(nosuch[i])
        \\
    ;
    var r = try checkSource(std.testing.allocator, source);
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectDiagnostic(&r.ctx, "nosuch");
    // The index of a value in error is checked quietly, only to
    // learn its type (`synthQuiet`): it leaves no type behind.
    const at: u32 = @intCast(std.mem.find(u8, source, "[i]").? + 1);
    try std.testing.expectEqual(null, r.ctx.typeOf(.{ .src = .{ .pos = at, .len = 1, .id = 0 } }));
}


/// Every file of the ownership checker, for the tests that read its
/// source.
const ownership_src = @embedFile("ownership.zig") ++ @embedFile("ownership/state.zig") ++ @embedFile("ownership/live.zig") ++
    @embedFile("ownership/transfer.zig") ++ @embedFile("ownership/rules.zig") ++ @embedFile("ownership/origins.zig") ++
    @embedFile("ownership/exits.zig") ++ @embedFile("ownership/generic.zig") ++ @embedFile("ownership/types.zig") ++
    @embedFile("ownership/notes.zig");
test "check: every read of a view as a value is decided by writeViewRead" {
    // `readOf` is the one place type checking records that a view is read
    // as the value it reaches, and it asks `writeViewRead` first. Another
    // record of `reads` would read a written `!x` as a value with its
    // `!` ignored, past the decider.
    const needle = "ctx." ++ "record(.reads,";
    const src = typecheck_source;
    try std.testing.expectEqual(1, std.mem.count(u8, src, needle));
    const at = std.mem.find(u8, src, needle).?;
    const fn_at = std.mem.findLast(u8, src[0..at], "pub fn ").?;
    try std.testing.expect(std.mem.startsWith(u8, src[fn_at..], "pub fn readOf("));
    try std.testing.expect(std.mem.find(u8, src[fn_at..at], "writeViewRead(self") != null);
    // Every pass after type checking reads the fact; none records it.
    for ([_][]const u8{ @embedFile("emit.zig"), ownership_src, @embedFile("storage.zig"), @embedFile("resolve.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, needle));
    }
}

test "check: where a Cell and a write view stand, and a branch viewed in place, are each decided once" {
    // Where a Cell and a write view may stand is one decider in sema,
    // `misplaced` (its write-view half, `writeViewMisplaced`, needs no
    // contents, so a type is rejected where it is written). Type
    // resolution asks it of every spelled type through `misplacedAt`,
    // typecheck of each generic instance's arguments, and of an array
    // literal's element; no other pass asks it.
    const sema_src = @embedFile("sema.zig");
    const tc = typecheck_source;
    const res = @embedFile("resolve.zig");
    try std.testing.expectEqual(1, std.mem.count(u8, sema_src, "pub fn " ++ "misplaced("));
    try std.testing.expectEqual(1, std.mem.count(u8, tc, "sema." ++ "misplaced("));
    try std.testing.expectEqual(1, std.mem.count(u8, res, "sema." ++ "misplaced("));
    try std.testing.expectEqual(1, std.mem.count(u8, tc, "sema." ++ "writeViewMisplaced("));
    try std.testing.expectEqual(1, std.mem.count(u8, res, "sema." ++ "writeViewMisplaced("));
    for ([_][]const u8{ ownership_src, @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, "sema." ++ "misplaced("));
        try std.testing.expectEqual(0, std.mem.count(u8, other, "sema." ++ "writeViewMisplaced("));
    }
    // A value holding a Cell is made only at a home (`cellMadeAway`),
    // asked of every expression typed (`synthExpr`, `checkExpr`).
    try std.testing.expectEqual(2, std.mem.count(u8, tc, "cellMadeAway" ++ "(self,"));
    // Every view of a branch, written or in place, asks `viewsBranch`:
    // a sigil, a slice, a write view of a temporary, a weak handle `*`
    // upgrades, a temporary viewed to read, a header's subject, and a view
    // a context takes in place.
    const call = "viewsBranch" ++ "(self,";
    try expectCallers(tc, call, &.{ "headerViewsBranch", "makeViewOf", "checkWriteView", "viewSlice", "weakUpgrade", "viewTempIn", "checkExpr" });
    // What a Cell kept by value needed is gone: no per-instance
    // interior mutability, Cell temporaries, or write through a field.
    for ([_][]const u8{ "interior" ++ "Mutable", "ReadPtr" ++ "(", "Cell" ++ "Temp", "refuseHeld" ++ "Cell", "payloadReads" ++ "ThroughWrite", "headerCopies" ++ "WriteView" }) |gone| {
        for ([_][]const u8{ sema_src, tc, res, ownership_src, @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig"), @embedFile("runtime.zig") }) |src| {
            try std.testing.expectEqual(0, std.mem.count(u8, src, gone));
        }
    }
    // A read view changes nothing, a Cell included (Core sentence 4): neither
    // the emitter nor the ownership checker treats a read view of a value
    // that holds a Cell differently from any other.
    for ([_][]const u8{ ownership_src, @embedFile("emit.zig"), @embedFile("facts.zig") }) |src| {
        try std.testing.expectEqual(0, std.mem.count(u8, src, "holdsCell" ++ "ByValue"));
    }
}

test "check: what `!x` puts on `x` is decided once, by loanOfView" {
    // A read or a write loan (Core §4) is one fact: `sema.loanOfView`
    // decides it, typecheck records it where `!x`'s view is chosen
    // (`recordLoan`) and where a handle becomes a view of its value
    // (`viewByRows`), and the ownership checker reads it (`loanOf`). Emit
    // never asks.
    const tc = typecheck_source;
    try std.testing.expectEqual(1, std.mem.count(u8, @embedFile("sema.zig"), "pub fn " ++ "loanOfView("));
    try std.testing.expectEqual(2, std.mem.count(u8, tc, "sema." ++ "loanOfView("));
    try std.testing.expectEqual(2, std.mem.count(u8, ownership_src, "loan" ++ "Of(self, "));
    for ([_][]const u8{ ownership_src, @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, "loanOf" ++ "View("));
        try std.testing.expectEqual(0, std.mem.count(u8, other, "record" ++ "Loan("));
    }
    for ([_][]const u8{ @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, "loan" ++ "Of("));
    }
}

test "check: a binding's mode is decided once, by decideBindingAccess" {
    // A view binding's access (can a write go through it) is one fact,
    // decided by `sema.decideBindingAccess` and recorded on its symbol.
    // Typecheck derives the binding's type from it at each kind of binding
    // (a match, `as`, a loop), ownership the loan a view of it makes, and
    // emit how it binds: no pass derives a binding's mode another way.
    const decide = "sema." ++ "decideBindingAccess(";
    const record = ").access" ++ " = ";
    const tc = typecheck_source;
    try std.testing.expectEqual(3, std.mem.count(u8, tc, decide));
    try expectCallers(tc, decide, &.{ "loopElement", "bindMatchView", "asAccess" });
    // The access is recorded where each binding's type is: in
    // `checkOptionalBinding`, `checkFor`, and `bindMatchView`, each also
    // marking it decided for the check that the two agree
    // (`sema.checkBindingAccess`).
    try std.testing.expectEqual(3, std.mem.count(u8, tc, record));
    try std.testing.expectEqual(3, std.mem.count(u8, tc, "flags.access_decided" ++ " = true"));
    // One helper builds a binding's type from its access, for every kind
    // of binding: `viewOfAccess`, called from the three binding sites.
    const derive = "viewOfAccess" ++ "(self,";
    try std.testing.expectEqual(3, std.mem.count(u8, tc, derive));
    try expectCallers(tc, derive, &.{ "checkOptionalBinding", "loopElement", "bindMatchView" });
    try std.testing.expectEqual(0, std.mem.count(u8, tc, "asBinding" ++ "Type("));
    // Whether a header passes on a write view its subject makes, and
    // whether it would copy one out of a place, are each one decider in
    // sema, by a positive list, which `match` and `as` share.
    const Shared = struct { call: []const u8, callers: []const []const u8 };
    for ([_]Shared{
        .{ .call = "sema." ++ "makesWriteView(", .callers = &.{ "checkOptionalBinding", "checkOptionalBinding", "matchReach" } },
        // Every header kind, `match` (and `as` with a pattern, which is
        // one), `if … as` / `while … as`, and `for`, views a branching
        // subject where it stands: none can skip it.
        .{ .call = "headerViewsBranch" ++ "(self,", .callers = &.{ "checkOptionalBinding", "checkFor", "checkMatchSubject" } },
    }) |shared| {
        try expectCallers(tc, shared.call, shared.callers);
    }
    // The decider is sema's alone.
    try std.testing.expectEqual(1, std.mem.count(u8, @embedFile("sema.zig"), "pub fn " ++ "decideBindingAccess("));
    for ([_][]const u8{ ownership_src, @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig"), @embedFile("resolve.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, decide));
        try std.testing.expectEqual(0, std.mem.count(u8, other, record));
    }
    // Ownership views a binding by its access, in `viewTarget` alone,
    // which reads neither the binding's type (`ref`) nor how the match
    // reached it (`payload_view`, `matchMode`).
    const own = ownership_src;
    const read_fact = "ctx." ++ "bindingAccess(";
    try std.testing.expectEqual(1, std.mem.count(u8, own, read_fact));
    const target_at = std.mem.find(u8, own, "pub fn " ++ "viewTarget(").?;
    const body = own[target_at .. std.mem.findPos(u8, own, target_at, "\n}\n").?];
    try std.testing.expect(std.mem.find(u8, body, read_fact) != null);
    for ([_][]const u8{ ".ref", "payload_view", "matchMode", "types.get" }) |other| {
        try std.testing.expect(std.mem.find(u8, body, other) == null);
    }
    for ([_][]const u8{ "payload_" ++ "writes", "writes" ++ "Subject" }) |gone| {
        try std.testing.expectEqual(0, std.mem.count(u8, own, gone));
    }
    // Storage binds a payload by address from the same fact, not from the
    // match's mode.
    const st = @embedFile("storage.zig");
    const by_addr = std.mem.find(u8, st, "fn " ++ "payloadByAddress(").?;
    const by_body = st[by_addr..std.mem.findPos(u8, st, by_addr, "\n}\n").?];
    try std.testing.expect(std.mem.find(u8, by_body, "bindingAccess(") != null);
    try std.testing.expect(std.mem.find(u8, by_body, "matchMode") == null);
}

test "check: a written write view read as a value is rejected" {
    var r = try checkSource(std.testing.allocator,
        \\fun f(x: Int) -> Int
        \\  x
        \\
        \\sub main()
        \\  n = 1
        \\  a = f(!n)
        \\  b = !n + 1
        \\  print(!n, a, b)
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    var count: usize = 0;
    for (r.ctx.diagnostics.items) |d| {
        if (d.severity == .@"error" and std.mem.find(u8, d.message, "here is read, not held") != null) count += 1;
    }
    try std.testing.expectEqual(3, count);
}

test "frame owners: one list of each kind, and the owner of a call in each kind of body" {
    var r = try checkSource(std.testing.allocator,
        \\fun h(i: Int) -> Int
        \\  i + 1
        \\
        \\fun g[T](x: T, i: Int) -> Int
        \\  h(i)
        \\
        \\obj Res
        \\  n: Int
        \\
        \\  fun get(?@) -> Int
        \\    h(@n)
        \\
        \\  drop(!@)
        \\    print(h(@n))
        \\
        \\fun f(i: Int) -> Int
        \\  defer print(h(i))
        \\  return 5 if i == 9
        \\  c = |+i|
        \\    k = |+i| h(i)
        \\    k()
        \\  match i
        \\    0 => h(i)
        \\    _ => c()
        \\
        \\test "t"
        \\  print(h(1))
        \\
        \\sub main()
        \\  r = Res(n: 1)
        \\  print(f(0), g(1, 2), r.get())
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
    const Want = struct { kind: sema.FrameOwner.Kind, label: []const u8, parent: ?u32 };
    const want = [_]Want{
        .{ .kind = .function, .label = "`h`", .parent = null },
        .{ .kind = .function, .label = "`g`", .parent = null },
        .{ .kind = .function, .label = "`get`", .parent = null },
        .{ .kind = .drop, .label = "`drop`", .parent = null },
        .{ .kind = .function, .label = "`f`", .parent = null },
        .{ .kind = .closure, .label = "a closure", .parent = 4 },
        .{ .kind = .closure, .label = "a closure", .parent = 5 },
        .{ .kind = .test_block, .label = "test \"t\"", .parent = null },
        .{ .kind = .function, .label = "`main`", .parent = null },
    };
    const owners = r.ctx.frame_owners.items;
    try std.testing.expectEqual(want.len, owners.len);
    for (want, owners) |w, o| {
        try std.testing.expectEqual(w.kind, o.kind);
        try std.testing.expectEqualStrings(w.label, o.label);
        try std.testing.expectEqual(w.parent, o.parent);
    }
    try std.testing.expect(owners[2].member and !owners[2].of_generic_type);
    try std.testing.expect(owners[1].per_instance and owners[1].own == null);
    // Each call of `h`: its owner, and how many times Zig writes it (the
    // `defer` body at the `return` and at the end).
    const Call = struct { owner: u32, copies: u32 };
    const calls = [_]Call{
        .{ .owner = 1, .copies = 1 }, // g
        .{ .owner = 2, .copies = 1 }, // get
        .{ .owner = 3, .copies = 1 }, // drop
        .{ .owner = 4, .copies = 2 }, // f's defer
        .{ .owner = 6, .copies = 1 }, // the inner closure
        .{ .owner = 4, .copies = 1 }, // f's match arm
        .{ .owner = 7, .copies = 1 }, // the test
    };
    var seen: usize = 0;
    for (r.ctx.frame_calls.items) |c| {
        const callee = r.ctx.calleeOf(c.node);
        if (callee != .src or !std.mem.eql(u8, sema.identAt(r.ctx.source, callee) orelse "", "h")) continue;
        try std.testing.expect(seen < calls.len);
        try std.testing.expectEqual(calls[seen].owner, r.ctx.ownerOf(c.node).?);
        try std.testing.expectEqual(calls[seen].copies, c.copies);
        try std.testing.expectEqual(sema.CallTarget{ .function = .{ .module = r.ctx.module_id, .pos = owners[0].pos } }, r.ctx.callTargetOf(c.node).?);
        seen += 1;
    }
    try std.testing.expectEqual(calls.len, seen);
    // Each owner lists its calls.
    for (owners, 0..) |o, i| for (o.calls) |ci| try std.testing.expectEqual(@as(?u32, @intCast(i)), r.ctx.frame_calls.items[ci].owner);
}

test "check: a frame an inline call cannot count is an error at the call, never no values" {
    var r = try checkSource(std.testing.allocator,
        \\inline fun big[T](x: T, i: Int) -> T
        \\  t = [1000 of x]
        \\  t[i % 1000]
        \\
        \\sub near(i: Int)
        \\  print(big(1, i))
        \\
    );
    defer r.p.deinit();
    defer r.ctx.deinit();
    try expectClean(&r.ctx);
    try std.testing.expectEqual(1, r.ctx.inline_calls.count());
    // `near`'s account holds `big`'s values at the instance its call makes.
    var found = false;
    for (r.ctx.frame_owners.items) |o| if (std.mem.eql(u8, o.label, "`near`")) {
        try std.testing.expect(o.marked.bytes >= 8000);
        found = true;
    };
    try std.testing.expect(found);
    // The recorded call, without the instance it makes: `big`'s values
    // hold `T`, which nothing binds.
    var it = r.ctx.inline_calls.valueIterator();
    const ic = it.next().?;
    const saved = ic.*;
    ic.subst = .empty;
    try GenericCheck.checkFrames(&r.ctx);
    try expectDiagnostic(&r.ctx, "cannot count the values this `inline` call adds to the frame it is in (the call does not bind every parameter its values hold)");
    // A function no module declares.
    ic.* = saved;
    ic.fun.module +%= 1000;
    try GenericCheck.checkFrames(&r.ctx);
    try expectDiagnostic(&r.ctx, "cannot count the values this `inline` call adds to the frame it is in (its module is not loaded)");
}
