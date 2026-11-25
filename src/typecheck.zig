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
//! expected (`readValue`), which reads through it (`recordRead`); and
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
    /// The module's tree, where a group's type declared here is found
    /// (`groupSite`).
    tree: Sexp = .nil,
    /// The position of a name that is the object of a field read or a
    /// spread's operand being checked: a group's name there reads its
    /// fields, not the group whole (`noteGroupUse`).
    group_member: u32 = std.math.maxInt(u32),
    /// The function being checked has a group as written, whose field
    /// reads its body records (`synthMember`).
    in_group_body: bool = false,
    /// The function, method, closure, test, or drop body being checked.
    body: Body,
    nominal: NominalContext = NominalContext.none,
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
    /// The `new x` binding whose value is being checked: not visible yet.
    pending: SymbolId = sema.symbol_invalid,
    /// The names `new q, r = f()` declares, while its call is checked.
    pending_names: []const SymbolId = &.{},
    /// Enclosing `raw` blocks.
    raw_depth: u32 = 0,
    /// The operand of the `!` or `catch` being checked: a fallible call
    /// there is handled.
    handled: Sexp = .nil,
    /// The operand of the `*x` being checked.
    shared_operand: Sexp = .nil,
    /// The value and target of the binding of a name being checked
    /// (`t = f(!x)&`), where a task given a write view may stand.
    local_value: Sexp = .nil,
    local_target: Sexp = .nil,
    /// The locals that hold a task given a write view, each moved only
    /// into its own wait, `>t`, or `<t.cancel()`.
    write_tasks: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// A binding that never changes whose value is a plain enum's
    /// variant the checker knows, by name (`constVariant`).
    fixed_variants: std.AutoHashMapUnmanaged(SymbolId, []const u8) = .empty,
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
    /// The calls whose lasting views were reported (`keptViews`), so that
    /// one reached from two kept values is reported once.
    kept_reported: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The closure literals whose errors were reported by a check aloud
    /// given the parameter types their call gives them (`closureErrors`,
    /// `lambdaLeftUnbound`), where the call then stops: `synthArgs`
    /// leaves them out, since its check, with no parameter types and as
    /// one that cannot fail, would report errors the closure has not.
    closures_reported: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The closure literals a std form calls that check clean neither as
    /// one that cannot fail nor as one that can (`closureType`,
    /// `reduceFunction`): the call reports their errors and gives poison,
    /// so whether it fails, which the closure's errors leave open, adds
    /// no error of its own (`closureResult`).
    closures_in_error: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The chains whose result holds views of the items of their source,
    /// each a consumer's call to the source it walks (`chainTypes`).
    chain_views: std.AutoHashMapUnmanaged(parser.NodeId, Sexp) = .empty,
    /// The closures and outer locals whose missing capture was reported
    /// (`useName`), each a closure's scope above a local's symbol.
    uncaptured_reported: std.AutoHashMapUnmanaged(u64, void) = .empty,
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
    /// The binding conditions whose `else` is being checked, innermost
    /// last: a name one binds is unbound there (`unboundHint`).
    else_conds: std.ArrayList(Sexp) = .empty,
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
    /// A read match's binding whose subject has no storage, `copied_from`
    /// records none for: the subject, for the hint that names the match
    /// that writes (`readMatchHint`).
    read_subjects: std.AutoHashMapUnmanaged(SymbolId, CopySource) = .empty,
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
    /// Inside `noteTakeable`'s trial of a take, which only asks whether
    /// `<e` would be accepted: `requireAccess` records nothing.
    trial_take: bool = false,
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
        self.kept_reported.deinit(a);
        self.closures_reported.deinit(a);
        self.closures_in_error.deinit(a);
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
        return &self.ctx.types;
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
                const saved_tail = self.test_tail;
                defer self.test_tail = saved_tail;
                self.test_tail = lastStmt(body);
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
    /// computes it (`sema.ctFoldBy`): Zig would compute it again when it
    /// compiles, and stop at an overflow or a division by zero. So each
    /// operand is a value Rig knows; one the target sets, or a constant
    /// branching on something Rig does not compute, is rejected.
    pub fn checkConstArithmetic(self: *Checker, e: Sexp) Error!void {
        if (e != .list) return;
        if (!isArithmetic(e)) {
            for (e.items()) |c| try self.checkConstArithmetic(c);
            return;
        }
        const ty = self.ctx.typeOf(e) orelse return;
        if (!sema.isInteger(self.ctx, ty) and ty != self.t().int_literal_id) return;
        if (sema.constInt(self.ctx, e) != .not_constant) return;
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
            if (isArithmetic(o)) {
                if (self.unknownOperand(o)) |x| return x;
            } else if (sema.constInt(self.ctx, o) == .not_constant) return o;
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
        return if (rig.isBracketList(callee)) id == self.ctx.simd_sym_id else self.ctx.symbols.items[id].kind == .type_alias;
    }

    pub const not_at_module_level = "only declarations and bindings are allowed at module level; move this statement into a function";

    /// The fields of error set `sym`'s members: each field's type holds no
    /// loan, holds no `*` or `~` handle, and clones, so an error never
    /// limits an owner, goes to any task, and drops without running a
    /// `drop` body (CORE, "A failure moves its error").
    pub fn checkErrorFields(self: *Checker, sym: SymbolId, fields: []const sema.Field) Error!void {
        const self_ty = try self.ctx.intern(.{ .nominal = sym });
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
        const self_ty = try self.ctx.intern(.{ .nominal = sym });
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
                try self.err(pos, head ++ "has {d} {s} of padding before field `{s}`: it starts at byte {d}, and {s} `{s}` starts at a multiple of {d}; write the padding as a field before it, `_pad: [{d}]U8`, or order the fields so that none needs it", .{ name, bytes, if (bytes == 1) "byte" else "bytes", not.field, p.at, article(not.shown), not.shown, p.alignment, bytes });
            },
            .padding_after => |p| try self.err(pos, head ++ "has {d} {s} of padding after field `{s}`, to a multiple of {d}; write the padding as a field after it, `_pad: [{d}]U8`", .{ name, p.bytes, if (p.bytes == 1) "byte" else "bytes", not.field, p.alignment, p.bytes }),
            .empty => if (not.field.len == 0)
                try self.err(pos, head ++ "holds no bytes: give it a field", .{name})
            else
                try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`, which holds no bytes", .{ name, not.field, article(not.shown), not.shown }),
            .not_exact => |inner| try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`, which is not `exact`: add `exact` to `obj {s}`", .{ name, not.field, article(not.shown), not.shown, inner }),
            else => try self.err(pos, head ++ "holds field `{s}`, {s} `{s}`; an `exact` object holds integers, floats, `Bool`s, plain enums, `exact` objects, and fixed arrays of them", .{ name, not.field, article(not.shown), not.shown }),
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
        self.nominal = .{ .sym = id, .self_type = try self.ctx.intern(.{ .type_var = params[0] }), .type_params = params[1..] };
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
            .nominal => |id| .{ self.ctx.symbols.items[id], null, id, null },
            .imported_nominal => |n| blk: {
                const fc = self.ctx.foreign_semas.get(n.module_id) orelse return null;
                break :blk .{ fc.symbols.items[n.sym_id], n.module_id, n.sym_id, fc };
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
        const subst: TypeSubst = .{ .params = self.ctx.symbols.items[pn.sym].type_params orelse &.{}, .args = pn.args };
        var data: std.ArrayList(Field) = .empty;
        var tys: std.ArrayList(TypeId) = .empty;
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            try data.append(a, f);
            try tys.append(a, try sema.substituteType(self.ctx, f.ty, subst));
        }
        return .{ .name = self.ctx.symbols.items[pn.sym].name, .fields = data.items, .tys = tys.items, .module = null, .sym = pn.sym };
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
            const id = nodeId(p);
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
        if (leaf.src.pos == self.group_member) return;
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
        const saved = self.group_member;
        defer self.group_member = saved;
        if (operand == .src) self.group_member = operand.src.pos;
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
        const id = nodeId(spread);
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
            const made = if (sema.isNumeric(self.ctx, self.ctx.typeOf(value) orelse sema.type_invalid) or isDefaultLiteral(self.ctx.source, value)) try std.fmt.allocPrint(self.ctx.arena.allocator(), "time.duration({s})", .{shown}) else shown;
            return self.errAt(value, "a `time.Duration` is made as the program runs, so the only default it has is `none`: declare `{s}: time.Duration? = none`, and read it as `{s} ?? {s}`", .{ name, name, made });
        }
        // A table reserves or makes its slots as the program runs, which
        // a default, a constant the object's type holds, cannot.
        if (sema.tableElem(self.ctx, ty) != null) {
            return self.errAt(value, "a table is made as the program runs, so it is no {s}'s default: make it where the value is made, `{s}()` in a constructor or a function", .{ what, "Table" });
        }
        const ok = isDefaultLiteral(self.ctx.source, value) or self.isConstantDefault(value) or (field and try self.isConstructorDefault(value));
        if (!ok) {
            if (field and try self.emptyConstructorGap(value)) return;
            if (field) {
                try self.errAt(value, "a default field value must be a literal, a module constant, a number type's limit, or an empty or literal constructor: `List()`, `String()`, `Cell(0)`, `[n of 0]`, or `T()` of an object whose every field has a default", .{});
            } else try self.errAt(value, "a default parameter value must be a literal, a module constant, or a number type's limit", .{});
            return;
        }
        const saved_home = self.cell_home;
        defer self.cell_home = saved_home;
        if (field) self.cell_home = value;
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
            return isDefaultLiteral(self.ctx.source, v) or self.isConstantDefault(v);
        }
        if (!e.isKind(.call)) return false;
        var callee = ir.Call.callee(e);
        // `String()`: the empty text, which owns nothing yet.
        if (callee == .src and std.mem.eql(u8, self.text(callee), "String") and CallCheck.lookupQuiet(self, callee) == null) return ir.Call.args(e).len == 0;
        if (rig.isBracketList(callee)) callee = ir.get(callee, .object);
        const args = ir.Call.args(e);
        if (callee == .src) if (CallCheck.lookupQuiet(self, callee)) |id| {
            if (id == self.ctx.list_sym_id) return args.len == 0;
            if (id == self.ctx.cell_sym_id) return args.len == 1 and isDefaultLiteral(self.ctx.source, args[0]);
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
        if (loopsForever(self.ctx.source, s) or (ends_void and (FlowCheck.yieldsNoValue(self, s) or isIfWithoutElse(s)))) {
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
        const saved_tail = self.results_tail;
        defer self.results_tail = saved_tail;
        if (sema.resultsOf(self.ctx, ret) != null) self.results_tail = resultCall(s) orelse .nil;
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
    /// statement the parser found may hold one (`rig.Parser.rewrite_stmts`)
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
            .list => |l| if (self.ctx.parser) |p| p.mayRewrite(l.id) else false,
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
        if (e == .list) try self.value_tails.put(self.ctx.allocator, nodeId(e), {});
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
                if (ViewCheck.viewOf(f.c, obj)) |view| if (!viewsSlice(view) and !f.c.methods.contains(nodeId(n)) and !(isCallee(f.root, n) and (ViewCheck.isSelfSigil(f.c, obj) or !ViewCheck.namesField(f.c, obj, n)))) {
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
            while (parentIn(f.root, top)) |p| {
                if (!(p.isKind(.member) or p.isKind(.index)) or !sameExpr(ir.get(p, .object), top) or c.methods.contains(nodeId(p))) break;
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
                const o_ty = if (sameExpr(o, obj)) c.ctx.typeOf(place) else c.ctx.typeOf(o);
                if (o_ty) |ty| {
                    const v = sema.unwrapViews(c.ctx, ty);
                    if (c.ctx.types.get(v) == .shared) x.shared = true;
                }
                if (sameExpr(o, obj)) break;
            }
            // A part of a value made here, which no name holds: a view a
            // call returns is not one.
            if (ViewCheck.hands(c, place).kind != .place) {
                const pt = c.ctx.typeOf(place);
                x.temp = pt == null or !sema.isReadOrWriteView(c.ctx, pt.?);
            }
            if (c.ctx.typeOf(top)) |tt| x.optional = c.ctx.types.get(tt) == .optional;
            const p = parentIn(f.root, top) orelse {
                f.setValueSigil(&x, top, sigil);
                return f.spans(x, obj);
            };
            switch (p.kind() orelse .module) {
                .set => if (sameExpr(ir.Set.target(p), top)) {
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
                .match => if (sameExpr(ir.Match.subject(p), top)) {
                    x.header = true;
                    x.open = sigil;
                },
                .as => if (sameExpr(ir.As.value(p), top)) {
                    x.header = true;
                    x.open = sigil;
                },
                // A `for` walks a binding's place, or a field or element of
                // one, in place: none of a value that branches.
                .@"for" => if (sameExpr(ir.For.source(p), top)) {
                    x.header = true;
                    if (ir.For.mode(p).tag == .iter) x.open = sigil;
                    x.writes = ir.For.mode(p).tag == .write;
                    if (ViewCheck.hands(c, place).kind != .place) x.none = true;
                },
                // A method's self: a write view where the method
                // writes it (in parentheses where the call's `Bool` value
                // is used), and bare otherwise.
                .member => if (c.methods.get(nodeId(p))) |m| {
                    x.reach = c.ctx.span(p).end;
                    if (m.self_mode == .write) {
                        x.writes = true;
                        const call = parentIn(f.root, p) orelse p;
                        const ret = c.ctx.types.get(m.returns);
                        const value = if (ret == .fallible) ret.fallible.ok else m.returns;
                        const used = !sameExpr(call, f.root) or c.value_tails.contains(nodeId(call));
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
            while (parentIn(f.root, at)) |p| {
                const leaf = switch (p.kind() orelse break) {
                    .@"if" => !sameExpr(ir.If.cond(p), at),
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
            const want_ty = c.expected.get(nodeId(at));
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
                        return if (compatible(c.ctx, top_ty, inner)) "" else "?";
                    },
                    else => {},
                }
                if (sema.holdsWriteView(c.ctx, want)) return "!";
                if (!compatible(c.ctx, top_ty, want)) return null;
                if (copies) return "";
                return if (sema.cloneable(c.ctx, top_ty) != .no) "+" else null;
            }
            // A branch whose other leaves are views takes their sigil.
            if (!sameExpr(at, top)) {
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
                const taken = c.ctx.useOf(at) == .take or if (parentIn(f.root, at)) |p| p.isKind(.set) or p.isKind(.array) else false;
                if (taken) return sigil;
            }
            return "";
        }

        /// Whether `e` is an argument of a call of a function or a method,
        /// where a read view is made without a written `?`; a type's
        /// constructor stores it.
        pub fn implicitArg(f: *ViewBaseFix, e: Sexp) bool {
            var p = parentIn(f.root, e) orelse return false;
            if (p.isKind(.kwarg)) p = parentIn(f.root, p) orelse return false;
            if (!p.isKind(.call)) return false;
            const callee = ir.Call.callee(p);
            if (sameExpr(callee, e)) return false;
            if (f.c.methods.contains(nodeId(callee))) return true;
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
                while (i > 0 and isBlank(src[i - 1])) i -= 1;
                var j = ls.end;
                while (j < src.len and isBlank(src[j])) j += 1;
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
                    if (sameExpr(ir.get(n, .object), obj)) break;
                }
                // Only a place is sliced: a value that branches is not.
                if (slice != null and ViewCheck.hands(f.c, x.place).kind != .place) x.none = true;
                if (slice) |sl| if (!sameExpr(sl, x.top)) {
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
            for (f.edits.items) |x| if (sameExpr(x.view, view)) return x;
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
                        if (f.named) |named| if (sameExpr(named.view, x.view)) {
                            try out.appendSlice(a, named.name);
                            at = x.end;
                            continue;
                        };
                        // What a postfix would not bind is kept in
                        // parentheses: `(a if c else b).len`.
                        const base = x.place;
                        const bs = f.c.ctx.span(base);
                        const parens = !postfixBinds(base) and src[bs.start] != '(';
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

/// The type an operator reads from an operand: a viewed Copy value
/// (`readValue`), or the `T` a viewed type parameter reaches. Every
/// `T` an operator's requirement admits is plain data, so reading one
/// through its view copies no resource.
pub fn operandValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| if (ctx.types.get(inner) == .type_var) inner else readValue(ctx, ty),
        else => ty,
    };
}

/// A view of a scalar (`sema.readsAsValue`) reads as the scalar to an
/// operator: `n + 1` with `n: ?Int` or `n: !Int` is an `Int`.
pub fn readValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| if (sema.readsAsValue(ctx, inner)) inner else ty,
        else => ty,
    };
}

/// The type a binding with no type takes from a bare name or place of
/// type `ty` (Core sentence 1): a write view, which is never copied,
/// reads the value it reaches where that copies (`sema.copiedThrough`);
/// a read view is copied, but one of a scalar binds the scalar
/// (`readValue`).
pub fn bindingValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .write_view => sema.copiedThrough(ctx, ty) orelse ty,
        else => readValue(ctx, ty),
    };
}

/// Whether `ty` can be written in an expression's bracket list
/// (`id[Wrap[Int]](...)`): array, slice, and function types cannot.
pub fn spelledInBrackets(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .slice, .array, .function => false,
        .optional, .read_view, .write_view, .shared, .weak => |inner| spelledInBrackets(ctx, inner),
        .fallible => |inner| spelledInBrackets(ctx, inner.ok),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (!spelledInBrackets(ctx, arg)) break false;
        } else true,
        else => true,
    };
}

/// `x` of `?x`, `!x`, or `<x`; any other node as it is.
pub fn stripSigil(e: Sexp) Sexp {
    return if (e.isKind(.read) or e.isKind(.write) or e.isKind(.move)) ir.get(e, .operand) else e;
}

/// The place `?x` or `!x` views (through any number of them); any other
/// node, `<x` among them, as it is.
pub fn viewedPlace(e: Sexp) Sexp {
    var p = e;
    while (p.isKind(.read) or p.isKind(.write)) p = ir.get(p, .operand);
    return p;
}

/// The leaf a place starts from: `a` in `!a.b[i]`.
pub fn placeRoot(e: Sexp) ?Sexp {
    var x = e;
    while (true) {
        if (x == .src) return x;
        const h = x.kind() orelse return null;
        x = switch (h) {
            .member, .index => ir.get(x, .object),
            .read, .write, .move => ir.get(x, .operand),
            else => return null,
        };
    }
}

/// The first `<x` in `e`, if any.
pub fn findMove(e: Sexp) ?Sexp {
    if (e != .list) return null;
    if (e.isKind(.move)) return e;
    for (e.items()) |c| if (findMove(c)) |m| return m;
    return null;
}

/// Can a value of type `actual` be used where `expected` is required?
/// As itself (`meets`), or as a copy of the value a view of it reaches
/// (`copiedOut`).
pub fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    return meets(ctx, actual, expected) or copiedOut(ctx, actual, expected);
}

/// Whether a view `actual` meets `expected` only as a copy of the value
/// it reaches (`sema.copiedThrough`): that value meets `expected`,
/// and the view itself does not. A view of a value that copies is copied
/// out where the value is expected (Core §4), and the view is read
/// through there (`Checker.recordAdapted`).
pub fn copiedOut(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    const inner = sema.copiedThrough(ctx, actual) orelse return false;
    return !meets(ctx, actual, expected) and compatible(ctx, inner, expected);
}

/// How many levels of optional `ty` has.
pub fn optionalDepth(ctx: *const SemContext, ty: TypeId) u32 {
    var n: u32 = 0;
    var t = ty;
    while (ctx.types.get(t) == .optional) : (n += 1) t = ctx.types.get(t).optional;
    return n;
}

/// Can a value of type `actual` be used as itself where `expected` is
/// required?
pub fn meets(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    if (actual == expected) return true;
    const ts = &ctx.types;
    if (actual == ts.invalid_id or actual == ts.unknown_id or expected == ts.invalid_id or expected == ts.unknown_id) return true;
    if (actual == ts.noreturn_id) return true;
    const a = ts.get(actual);
    const e = ts.get(expected);
    switch (e) {
        .optional => |inner| {
            if (a == .none_literal) return true;
            // A `Static?` is read as a `(?String)?`.
            if (a == .optional) if (sema.readsAsStringView(ctx, a.optional, inner)) return true;
            return meets(ctx, actual, inner);
        },
        // A `Static` is read as the `?String` it is, a view that carries
        // no loan. Only where the text is read: a place that can be
        // written (`!x`) holds exactly its type.
        .string_view => if (a == .static) return true,
        .read_view => |inner| if (sema.readsAsStringView(ctx, actual, expected)) return true else if (a == .write_view) return a.write_view == inner else if (inner == ts.any_error_id and a == .read_view and sema.isSetParam(ctx, a.read_view)) return true,
        // A `T!` holds a `T`; an error value meets it only as `return`'s
        // operand (`Checker.isReturnLeaf`).
        .fallible => |inner| {
            // A `T!A` meets a `T!L` whose set holds `A`'s.
            if (a == .fallible) return a.fallible.ok == inner.ok and sema.errorSubset(ctx, a.fallible.set, inner.set);
            return meets(ctx, actual, inner.ok);
        },
        // `error` holds an error of any set, a set parameter's included.
        .any_error => if (sema.isErrorSet(ctx, actual) or sema.isSetParam(ctx, actual)) return true,
        // A `![]T` (or a `?[]T`) reads as the `[]T` it views.
        .slice => |want| switch (a) {
            .read_view, .write_view => |inner| if (inner == expected) return true,
            // The elements of a `[]Static` are read as `?String`s.
            .slice => |have| if (sema.readsAsStringView(ctx, have.elem, want.elem)) return true,
            else => {},
        },
        // A union holds an error of each set it joins.
        .nominal, .imported_nominal => if (sema.isErrorUnion(ctx, expected) and sema.isErrorSet(ctx, actual) and sema.errorSubset(ctx, actual, expected)) return true,
        else => {},
    }
    return switch (a) {
        // A literal is a `Slot[n]` below `n` (`Checker.checkLiteralFits`).
        .int_literal => e == .int or e == .float or e == .slot,
        .float_literal => e == .float,
        else => false,
    };
}

pub const SelfTypeKind = enum { owned_nominal, read_view, write_view, shared, other };

/// What kind of value a method's self is, for the type whose symbol
/// is `nominal_sym` (`symbol_invalid` for an imported type).
pub fn classifySelfType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) SelfTypeKind {
    const matches = struct {
        fn f(c: *const SemContext, id: TypeId, sym: SymbolId) bool {
            // A box's value is reached as the box is: owned, or viewed,
            // or through the read view it holds.
            if (sym != c.box_sym_id) if (sema.boxedType(c, id)) |inner| return f(c, sema.unwrapViews(c, inner), sym);
            return switch (c.types.get(id)) {
                .nominal => |s| s == sym,
                .parameterized_nominal => |pn| pn.sym == sym,
                .imported_nominal => sym == sema.symbol_invalid,
                else => false,
            };
        }
    }.f;
    // A view of a shared handle (`!h.m()` with `h: *T`) still reaches
    // the value through the handle, and so does a box of one, for a
    // method of the value (not the box's own).
    if (ctx.types.get(sema.unwrapViews(ctx, ty_id)) == .shared) return .shared;
    if (nominal_sym != ctx.box_sym_id and sema.accessThroughShared(ctx, ty_id)) return .shared;
    // A box of a read view (`^?T`) reaches its value through the view.
    if (nominal_sym != ctx.box_sym_id and sema.boxedReadView(ctx, ty_id) != null) return if (matches(ctx, sema.unwrapViews(ctx, ty_id), nominal_sym)) .read_view else .other;
    return switch (ctx.types.get(ty_id)) {
        .read_view => |i| if (matches(ctx, i, nominal_sym)) .read_view else .other,
        .write_view => |i| if (matches(ctx, i, nominal_sym)) .write_view else .other,
        else => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
    };
}

/// How a self is written: with a self sigil (`?v.m()`, `!v.m()`,
/// `<v.m()`, Core §8), or bare, by what it hands over
/// (`Checker.selfShape`).
pub const SelfShape = enum { read_explicit, write_explicit, move_explicit, made, branches, place };

/// The sigil of a self sigil node, as written.
pub fn sigilText(recv: Sexp) []const u8 {
    return if (recv.isKind(.read)) "?" else if (recv.isKind(.write)) "!" else "<";
}

/// The element type of a Cell self (`Cell[T]`, `?Cell[T]`, `*Cell[T]`, ...).
pub fn cellElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.cell_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// Whether `node` lies in the index of an element read in `tree`.
pub fn inIndex(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.index) and contains(ir.Index.index(tree), node)) return true;
    for (tree.items()) |item| if (inIndex(item, node)) return true;
    return false;
}

/// Whether `node` lies in an argument of a call in `tree`.
pub fn inArgument(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.call)) for (ir.Call.args(tree)) |a| if (contains(a, node)) return true;
    for (tree.items()) |item| if (inArgument(item, node)) return true;
    return false;
}

/// Whether `node` is `tree` or inside it.
pub fn contains(tree: Sexp, node: Sexp) bool {
    if (sameNode(tree, node)) return true;
    if (tree != .list) return false;
    for (tree.items()) |item| if (contains(item, node)) return true;
    return false;
}

/// The element type of a Cell holding a List (`Cell[List[E]]`, `?Cell[List[E]]`, `*Cell[List[E]]`, ...).
pub fn cellListElement(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return listElementType(ctx, cellElementType(ctx, ty) orelse return null);
}

pub const slice_of_temporary = "only a named array, List, or String, or a field or element of one, can be sliced; bind this value to a name first";

pub const cell_list_handle = "cannot read or overwrite an element of a `{s}` in place: its elements are handles, which would be copied out or released while the cell holds them; `pop` the element, or `swap` the List out to work on it";

/// The data field (not a method or variant) named `name`.
pub fn findDataField(ctx: *SemContext, fields: []const Field, name: []const u8) Error!?Field {
    return fields[(try sema.findMember(ctx, fields, name, .data)) orelse return null];
}

/// The element type of a `List[T]`.
pub fn listElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.list_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// An arithmetic operation: unary minus or a binary arithmetic,
/// bitwise, or shift operator.
pub fn isArithmetic(e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => true,
        else => false,
    };
}

/// What a slice argument (`Checker.slicedArg`) of type `actual` views
/// where a `view` is expected: the view it is, which goes where its own
/// type does (a `[]T` or a `?String`, or an optional of one). Null
/// elsewhere.
pub fn sliceArgView(ctx: *const SemContext, actual: TypeId, view: TypeId) ?sema.View {
    return if (compatible(ctx, actual, view)) .{ .ty = view } else null;
}

/// `String` for a type that reaches a String through boxes and handles
/// (`sema.unwrapAccess`), which is viewed through them; any other type as
/// it is.
pub fn stringOrBoxed(ctx: *const SemContext, ty: TypeId) TypeId {
    return if (sema.unwrapAccess(ctx, ty) == ctx.types.string_id) ctx.types.string_id else ty;
}

/// Why enum `ty`, which has variants, is not plain: its payloads, or its
/// type parameters.
pub fn notPlainWhy(ctx: *const SemContext, ty: TypeId) []const u8 {
    const generic = if (sema.nominalDecl(ctx, ty)) |d| d.symbol().type_params != null else false;
    return if (generic) "is generic" else "has variants with payloads";
}

pub const isText = sema.isText;

/// The bytes a string literal holds: a double-quoted one with its escapes
/// read as Zig reads them, a single-quoted one as `sema.SingleQuoted`
/// reads it. Null for an escape the checker rejects.
pub fn textLiteralBytes(a: std.mem.Allocator, lit: []const u8) ?[]const u8 {
    if (rig.isBlockText(lit)) return rig.literalBytes(a, lit);
    if (lit[0] == '"') return std.zig.string_literal.parseAlloc(a, lit) catch null;
    var bytes: std.ArrayList(u8) = .empty;
    var it = sema.SingleQuoted.init(lit);
    while (it.next()) |c| bytes.append(a, c) catch return null;
    return bytes.items;
}

pub fn numericBits(t: sema.Type) ?u16 {
    return switch (t) {
        .int => |i| intBounds(i).bits,
        .float => |f| if (f.bits == 0) 64 else f.bits,
        else => null,
    };
}

pub const IntBounds = struct { min: Wide, max: Wide, bits: u8 };

/// The width and value range of an integer type.
pub fn intBounds(info: sema.IntInfo) IntBounds {
    const bits: u8 = if (info.bits == 0) 64 else info.bits;
    const half = @as(Wide, 1) << @intCast(bits - 1);
    return if (info.signed) .{ .min = -half, .max = half - 1, .bits = bits } else .{ .min = 0, .max = 2 * half - 1, .bits = bits };
}

/// The value of a float literal (`inf` when it is out of `F64`'s range).
pub fn floatLiteralValue(lit: []const u8) f64 {
    return floatLiteralAs(f64, lit);
}

pub fn floatLiteralAs(comptime F: type, lit: []const u8) F {
    return std.fmt.parseFloat(F, lit) catch 0;
}

/// The value of a constant expression of number literals computed in
/// float type `F` as the program computes it: each literal and each
/// operation rounded to `F`. Null when `e` is not one, or when an
/// operation in it overflows.
pub fn floatConstIn(comptime F: type, source: []const u8, e: Sexp) ?F {
    switch (e) {
        .src => {
            const t = identAt(source, e) orelse return null;
            if (sema.isFloatLiteralText(t)) {
                const v = floatLiteralAs(F, t);
                return if (std.math.isFinite(v)) v else null;
            }
            if (!sema.isIntLiteralText(t)) return null;
            return wideToFloat(F, std.fmt.parseInt(Wide, t, 0) catch return null);
        },
        .list => {
            const h = e.kind() orelse return null;
            if (h == .member) return floatLimit(F, source, e);
            if (h == .neg) return -(floatConstIn(F, source, ir.Neg.operand(e)) orelse return null);
            switch (h) {
                .@"+", .@"-", .@"*", .@"/", .@"%" => {},
                else => return null,
            }
            const a = floatConstIn(F, source, ir.get(e, .left)) orelse return null;
            const b = floatConstIn(F, source, ir.get(e, .right)) orelse return null;
            return if (floatOverflows(F, h, a, b)) null else floatOp(F, h, a, b);
        },
        else => return null,
    }
}

/// `F32.max`, `Float.min`: a float type's limit, in `F`; null for any
/// other member.
pub fn floatLimit(comptime F: type, source: []const u8, e: Sexp) ?F {
    const obj = ir.Member.object(e);
    const name = identAt(source, obj) orelse return null;
    const max: f64 = if (std.mem.eql(u8, name, "F32"))
        std.math.floatMax(f32)
    else if (std.mem.eql(u8, name, "F64") or std.mem.eql(u8, name, "Float"))
        std.math.floatMax(f64)
    else
        return null;
    const field = identAt(source, ir.Member.name(e)) orelse return null;
    const v: F = @floatCast(if (std.mem.eql(u8, field, "max")) max else if (std.mem.eql(u8, field, "min")) -max else return null);
    return if (std.math.isFinite(v)) v else null;
}

/// Whether the arithmetic node `e`, whose operands are constants in `F`,
/// overflows `F`.
pub fn floatOpOverflows(comptime F: type, source: []const u8, e: Sexp) bool {
    const a = floatConstIn(F, source, ir.get(e, .left)) orelse return false;
    const b = floatConstIn(F, source, ir.get(e, .right)) orelse return false;
    return floatOverflows(F, e.kind().?, a, b);
}

/// An operation on finite values whose result is infinite. Division by
/// zero gives an infinity or NaN instead.
pub fn floatOverflows(comptime F: type, h: Tag, a: F, b: F) bool {
    if (b == 0 and (h == .@"/" or h == .@"%")) return false;
    return std.math.isFinite(a) and std.math.isFinite(b) and !std.math.isFinite(floatOp(F, h, a, b));
}

pub fn floatOp(comptime F: type, h: Tag, a: F, b: F) F {
    return switch (h) {
        .@"+" => a + b,
        .@"-" => a - b,
        .@"*" => a * b,
        .@"/" => a / b,
        else => if (b == 0) std.math.nan(F) else @rem(a, b),
    };
}

/// `v` as a float, rounded. (LLVM has no conversion from an integer as
/// wide as `Wide`, so it goes through two 128-bit halves.)
pub fn wideToFloat(comptime F: type, v: Wide) F {
    if (std.math.cast(i128, v)) |n| return @floatFromInt(n);
    const lo: u128 = @truncate(@as(u256, @bitCast(v)));
    const hi: i128 = @truncate(v >> 128);
    return @floatCast(@as(f64, @floatFromInt(hi)) * 0x1p128 + @as(f64, @floatFromInt(lo)));
}

/// The first division of whole-number literals (`7 / 2`, `9 % 4`) that
/// a literal context reaches in `e`: through negation, a ternary's
/// branches, `+`, `-`, `*`, a comparison of literals, and a division
/// that is not one.
pub fn wholeDivision(source: []const u8, e: Sexp) ?Sexp {
    const h = e.kind() orelse return null;
    return switch (h) {
        .neg => wholeDivision(source, ir.Neg.operand(e)),
        .@"if" => wholeDivision(source, ir.If.then(e)) orelse wholeDivision(source, ir.If.@"else"(e)),
        .@"+", .@"-", .@"*", .@"<", .@">", .@"<=", .@">=", .@"==", .@"!=" => wholeDivision(source, ir.get(e, .left)) orelse wholeDivision(source, ir.get(e, .right)),
        .@"/", .@"%" => if (wholeLiterals(source, ir.get(e, .left)) and wholeLiterals(source, ir.get(e, .right)))
            e
        else
            wholeDivision(source, ir.get(e, .left)) orelse wholeDivision(source, ir.get(e, .right)),
        else => null,
    };
}

/// An expression of whole-number literals: integer literals, and
/// arithmetic and builtins (`$size(T)`) over them.
pub fn wholeLiterals(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => sema.isIntLiteralText(identAt(source, e) orelse ""),
        .list => switch (e.kind() orelse return false) {
            .neg => wholeLiterals(source, ir.Neg.operand(e)),
            .@"+", .@"-", .@"*", .@"/", .@"%" => wholeLiterals(source, ir.get(e, .left)) and wholeLiterals(source, ir.get(e, .right)),
            .builtin => true,
            else => false,
        },
        else => false,
    };
}

/// Whether numeric type `ty` holds the integer `v`: in range for an
/// integer type, exactly representable for a float type (Zig rejects a
/// constant that would round).
pub fn holdsInt(ctx: *const SemContext, ty: TypeId, v: Wide) bool {
    return switch (ctx.types.get(ty)) {
        .slot => |n| if (sema.slotCount(ctx, n)) |c| v >= 0 and v < c else false,
        .int => |info| v >= intBounds(info).min and v <= intBounds(info).max,
        .float => |f| blk: {
            const mantissa: u8 = if (f.bits == 32) 24 else 53;
            const a = @abs(v);
            break :blk a == 0 or @bitSizeOf(Wide) - @clz(a) - @ctz(a) <= mantissa;
        },
        else => true,
    };
}

/// `loop` with no `break` out of it: the loop only ends by
/// `return`, so a function may end with it.
pub fn loopsForever(source: []const u8, s: Sexp) bool {
    return sema.isLoop(source, s) and !sema.breaksOut(source, s, false);
}

/// `return`, `break`, `continue`, or `panic`: a fallback that leaves.
pub fn isJumpNode(e: Sexp) bool {
    return rig.leaves(e);
}

/// Whether `e` names `name` anywhere in `source`.
pub fn readsNameIn(source: []const u8, e: Sexp, name: []const u8) bool {
    return switch (e) {
        .src => |leaf| std.mem.eql(u8, rig.leafText(source, leaf), name),
        .list => for (e.items()) |c| {
            if (readsNameIn(source, c, name)) break true;
        } else false,
        else => false,
    };
}

/// The call whose value `e` is: `e` itself, or the call under a `!`,
/// `?`, `catch`, or on the left of `??`.
pub fn resultCall(e: Sexp) ?Sexp {
    const head = e.kind() orelse return null;
    return switch (head) {
        .call => e,
        .propagate => resultCall(ir.Propagate.value(e)),
        .propagate_none => resultCall(ir.PropagateNone.value(e)),
        .@"catch" => resultCall(ir.Catch.value(e)),
        .@"??" => resultCall(ir.@"??".left(e)),
        else => null,
    };
}

/// `a` and `b` are the same parsed node.
pub fn sameNode(a: Sexp, b: Sexp) bool {
    return a == .list and b == .list and a.list.ptr == b.list.ptr;
}

/// Whether `a` and `b` are the same node, a leaf by its place in the
/// source.
pub fn sameSite(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos and a.src.len == b.src.len;
    return sameNode(a, b);
}

/// `text` with each comment (`#` to the end of its line, outside a
/// string) taken out, for a hint that writes source spanning lines.
pub fn withoutComments(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, text, '#') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote) |q| {
            if (c == '\\' and q == '"' and i + 1 < text.len) {
                try out.appendSlice(a, text[i .. i + 2]);
                i += 1;
                continue;
            }
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            while (out.items.len > 0 and isBlank(out.items[out.items.len - 1])) out.items.len -= 1;
            if (i < text.len) try out.append(a, '\n');
            continue;
        }
        try out.append(a, c);
    }
    return out.items;
}

/// `text` on one line: each run of blanks with a line break in it is one
/// space.
pub fn oneLine(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, text, '\n') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!isBlank(text[i])) {
            try out.append(a, text[i]);
            continue;
        }
        var j = i;
        var broke = false;
        while (j < text.len and isBlank(text[j])) : (j += 1) broke = broke or text[j] == '\n';
        if (broke) {
            const prev = if (out.items.len > 0) out.items[out.items.len - 1] else ' ';
            const next = if (j < text.len) text[j] else ' ';
            if (prev != '(' and prev != '[' and next != ')' and next != ']' and next != '.') try out.append(a, ' ');
        } else try out.appendSlice(a, text[i..j]);
        i = j - 1;
    }
    return out.items;
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The id a node is recorded by.
pub fn nodeId(e: Sexp) parser.NodeId {
    return if (e == .list) e.list.id else 0;
}

/// Whether `view` views a slice, the view it makes (`?t[..]`).
pub fn viewsSlice(view: Sexp) bool {
    const viewed = viewedPlace(view);
    return viewed.isKind(.index) and ir.Index.index(viewed).isKind(.@"..");
}

/// Whether a postfix written after `e` binds to all of it: a name, a
/// field, an element, or a call.
pub fn postfixBinds(e: Sexp) bool {
    return e == .src or e.isKind(.member) or e.isKind(.index) or e.isKind(.call);
}

/// The node within `root` that holds `target` as a child, outside the
/// closures in it.
pub fn parentIn(root: Sexp, target: Sexp) ?Sexp {
    if (root != .list or root.isKind(.lambda)) return null;
    for (root.items()) |c| {
        if (sameExpr(c, target)) return root;
        if (parentIn(c, target)) |p| return p;
    }
    return null;
}

/// Whether member `m` within `root` names the method a call calls, with
/// or without compile-time arguments (`(!w).put[2](3)`).
pub fn isCallee(root: Sexp, m: Sexp) bool {
    if (!m.isKind(.member)) return false;
    var callee = m;
    var p = parentIn(root, m) orelse return false;
    if ((p.isKind(.index) or p.isKind(.inst)) and sameExpr(ir.get(p, .object), m)) {
        callee = p;
        p = parentIn(root, p) orelse return false;
    }
    return p.isKind(.call) and sameExpr(ir.Call.callee(p), callee);
}

/// Whether the code of `src`, its comments aside, holds `word` as a
/// whole name: a name a hint may bind is declared nowhere in the module.
pub fn hasCodeWord(src: []const u8, word: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.findScalar(u8, line, '#')) |h| line[0..h] else line;
        if (hasWord(code, word)) return true;
    }
    return false;
}

/// Whether `text` holds `word` as a whole name.
pub fn hasWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, text, i, word)) |at| : (i = at + 1) {
        const before = at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
        const end = at + word.len;
        const after = end == text.len or !(std.ascii.isAlphanumeric(text[end]) or text[end] == '_');
        if (before and after) return true;
    }
    return false;
}

/// `a` and `b` are the same parsed expression: a list node, or a leaf at
/// one position.
pub fn sameExpr(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos;
    return sameNode(a, b);
}

/// Forms whose type comes from the other operand: `.variant`,
/// `.variant(field: value)`, `none`.
pub fn isContextual(source: []const u8, e: Sexp) bool {
    if (e.isKind(.call) and ir.Call.callee(e).isKind(.enum_lit)) return true;
    return e.isKind(.enum_lit) or std.mem.eql(u8, identAt(source, e) orelse "", "none");
}

/// Literal forms allowed as default parameter values: the same text
/// means the same value at every call site, in any module.
pub fn isDefaultLiteral(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => isLiteralText(identAt(source, e).?) or std.mem.eql(u8, identAt(source, e).?, "none"),
        .list => e.isKind(.enum_lit) or e.isKind(.symbol) or
            (e.isKind(.neg) and ir.Neg.operand(e) == .src and isLiteralText(identAt(source, ir.Neg.operand(e)).?)),
        else => false,
    };
}

/// The last statement of a block (the block itself when it is empty),
/// or a lone statement.
pub fn lastStmt(body: Sexp) Sexp {
    if (!body.isKind(.block)) return body;
    const stmts = ir.Block.stmts(body);
    return if (stmts.len > 0) stmts[stmts.len - 1] else body;
}

/// An `if` (or `else if` chain) that lacks a final `else`.
pub fn ifWithoutValue(e: Sexp) bool {
    if (!e.isKind(.@"if")) return false;
    const other = ir.If.@"else"(e);
    return other == .nil or ifWithoutValue(other);
}

/// A keyword a duration in seconds might be meant by, for `seconds:`.
pub fn isSecondsName(name: []const u8) bool {
    for ([_][]const u8{ "second", "secs", "sec", "s" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// An `Int` literal as written, possibly negated, if `e` is one.
pub fn constIntText(source: []const u8, e: Sexp) ?i64 {
    if (e.isKind(.neg)) return -(constIntText(source, ir.Neg.operand(e)) orelse return null);
    const t = identAt(source, e) orelse return null;
    if (t.len == 0 or !std.ascii.isDigit(t[0])) return null;
    return std.fmt.parseInt(i64, t, 0) catch null;
}

/// `Float.inf()` or `Float.nan()`, possibly negated, of any float type.
pub fn isNotFinite(source: []const u8, e: Sexp) bool {
    if (e.isKind(.neg)) return isNotFinite(source, ir.Neg.operand(e));
    if (!e.isKind(.call) or ir.Call.args(e).len != 0 or !ir.Call.callee(e).isKind(.member)) return false;
    const name = identAt(source, ir.Member.name(ir.Call.callee(e))) orelse return false;
    const owner = identAt(source, ir.Member.object(ir.Call.callee(e))) orelse return false;
    const float = std.mem.eql(u8, owner, "Float") or std.mem.eql(u8, owner, "F64") or std.mem.eql(u8, owner, "F32");
    return float and (std.mem.eql(u8, name, "inf") or std.mem.eql(u8, name, "nan"));
}

/// The value of a float literal, possibly negated: `2.5`, `-1e3`.
/// What `Checker.floatConst` knows of a `Float`: its value as Rig
/// computes it, that it is a constant with no finite value, or nothing.
pub const FloatConst = union(enum) { value: f64, not_finite, unknown };

pub fn constFloatOf(source: []const u8, e: Sexp) ?f64 {
    if (e.isKind(.neg)) return -(constFloatOf(source, ir.Neg.operand(e)) orelse return null);
    const t = identAt(source, e) orelse return null;
    if (!sema.isFloatLiteralText(t)) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// `if c` with no `else`: a statement, never a value.
pub fn isIfWithoutElse(s: Sexp) bool {
    return s.isKind(.@"if") and ir.If.@"else"(s) == .nil;
}

/// Whether `ty` is `U8`, the byte.
pub fn isU8(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int => |info| info.bits == 8 and !info.signed,
        else => false,
    };
}

/// An integer literal, possibly negated: `42`, `-1`.
pub fn isIntLiteralNode(source: []const u8, e: Sexp) bool {
    if (e.isKind(.neg)) return isIntLiteralNode(source, ir.Neg.operand(e));
    return e == .src and sema.isIntLiteralText(identAt(source, e) orelse "");
}

pub fn isLiteralText(s: []const u8) bool {
    if (s.len == 0) return false;
    if (sema.isStringLiteralText(s)) return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return true;
    return sema.isIntLiteralText(s) or sema.isFloatLiteralText(s);
}

/// The article before a type's name in a diagnostic: "an `Int`",
/// "a `String`".
pub fn article(name: []const u8) []const u8 {
    if (name.len == 0) return "a";
    return switch (name[0]) {
        'A', 'E', 'I', 'O', 'a', 'e', 'i', 'o' => "an",
        else => "a",
    };
}

/// The first `n` parameters.
pub fn paramsMask(n: usize) sema.ParamMask {
    return if (n >= 64) sema.all_params else (@as(sema.ParamMask, 1) << @intCast(n)) - 1;
}

pub fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// =============================================================================
// Generic requirements
// =============================================================================

/// Every instantiation of a generic type, and every instance of a
/// generic function, must support the operations its bodies apply to
/// the type parameters (`@value + 1` requires a numeric `T`). Checked
/// after all bodies, against every instance the module's code makes.
/// An instance's type arguments, each standing as one (`sema.misplaced`):
/// a value holding a Cell by value, a write view, a bare API object, a
/// frozen value, or an actor's value is no type argument.
/// True when one stands misplaced, reported at the instance's site when
/// `report` gives one.
pub fn misplacedArgs(ctx: *SemContext, args: []const TypeId, report: ?u32) Error!bool {
    for (args) |arg| {
        if (sema.containsPoison(ctx, arg)) continue;
        const why = sema.misplaced(ctx, arg, .type_arg) orelse continue;
        const site = report orelse return true;
        const shown = try sema.formatType(ctx, arg);
        switch (why) {
            .cell => try ctx.err(site, sema.cell_misplaced, .{ shown, shown }),
            .write_view => try ctx.err(site, sema.write_view_misplaced, .{shown}),
            .unsized => try ctx.err(site, sema.object_unsized_arg, .{shown}),
            .frozen => try ctx.err(site, sema.frozen_misplaced_arg, .{ shown, shown }),
            .actor => try ctx.err(site, sema.actor_misplaced, .{shown}),
        }
        return true;
    }
    return false;
}

/// What the module's generic bodies, headers, APIs, and conformances
/// declare, checked before the instances are expanded, which read what
/// each conformance's witness names (`sema.Conformance.members`).
pub fn checkDeclaredApis(ctx: *SemContext) Error!void {
    try checkStatedForwards(ctx);
    try checkBoundedBodies(ctx);
    try checkHeaders(ctx);
    try checkApis(ctx);
}

pub fn checkGenericInstantiations(ctx: *SemContext) Error!void {
    var reqs: Requirements = .empty;
    defer {
        var lists = reqs.valueIterator();
        while (lists.next()) |l| l.deinit(ctx.allocator);
        reqs.deinit(ctx.allocator);
    }
    for (ctx.generic_requirements.items, 0..) |req, i| {
        // A method's own, where the method is reached (`checkReaches`).
        if (req.body != sema.no_body) continue;
        const gop = try reqs.getOrPut(ctx.allocator, req.param);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(ctx.allocator, @intCast(i));
    }
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |entry| {
        const pn = switch (ctx.types.get(entry.key_ptr.*)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        const params = ctx.symbols.items[pn.sym].type_params orelse continue;
        // A box holds an API object through its allocation, `^{Shape}`.
        if (pn.sym == ctx.box_sym_id and pn.args.len == 1 and sema.apiObject(ctx, pn.args[0]) != null) continue;
        if (try misplacedArgs(ctx, pn.args, entry.value_ptr.*)) continue;
        const of: sema.InstanceRoot = .{ .type = entry.key_ptr.* };
        if (!try sema.checkBounds(ctx, params, pn.args, entry.value_ptr.*, of)) continue;
        if (!try checkRequirements(ctx, &reqs, params, pn.args, entry.value_ptr.*, of)) continue;
        if (!try checkMethodCalls(ctx, .{ .params = params, .args = pn.args }, params, entry.value_ptr.*, of)) continue;
        try checkInstanceSizes(ctx, params, pn.args, entry.value_ptr.*, of);
    }
    // A method's instance checks only its own parameters; its type's
    // are checked with self's instance.
    // An instance made by one whose bounds failed is not checked: the
    // failure written at the call is the error, and the generics that
    // instance calls would only repeat it (`sort.sort[F32]` and each of
    // the bounded helpers it reaches).
    var failed: std.HashMapUnmanaged(sema.FnInstance, void, sema.FnInstance.Context, 80) = .empty;
    defer failed.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < ctx.fn_instances.items.len) : (i += 1) {
        const f = ctx.fn_instances.items[i];
        if (f.via) |via| if (via == .func and failed.contains(via.func)) continue;
        // An implementation's method reached through an API has the
        // arguments the call's instance of the API's method checks and
        // reports.
        if (try misplacedArgs(ctx, f.inst.ownArgs(), if (f.through_api) null else f.site)) continue;
        const of: sema.InstanceRoot = .{ .func = f.inst };
        // So are its bounds, which are the API's method's.
        const bounded = if (f.through_api) try sema.boundsMet(ctx, f.inst.ownParams(), f.inst.ownArgs()) else try sema.checkBounds(ctx, f.inst.ownParams(), f.inst.ownArgs(), f.site, of);
        if (!bounded) {
            try failed.put(ctx.allocator, f.inst, {});
            if (!f.through_api) if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
        } else if (try checkRequirements(ctx, &reqs, f.inst.ownParams(), f.inst.ownArgs(), f.site, of) and
            try checkMethodCalls(ctx, f.inst.subst(), f.inst.ownParams(), f.site, of))
        {
            try checkInstanceSizes(ctx, f.inst.params, f.inst.args, f.site, of);
        } else if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
    }
    try checkReaches(ctx);
}

// ---- stack frames -----------------------------------------------------------

/// Every frame owner (`sema.FrameOwner`: a function, method, closure,
/// test, or drop body) keeps at most `sema.max_frame_bytes` of values on
/// its stack: each binding it declares and each by-value parameter, once,
/// and each array literal, fill, and call whose value no binding takes
/// directly (a temporary). A closure's captures count in the frame that
/// makes it. A call's result counts twice when a binding takes it, since a
/// debug build holds it in a temporary first. This count is a limit on
/// what a program keeps on the stack; what keeps the stack safe is its
/// reach, below.
///
/// A frame's reach is its values and a copy of every value its code
/// makes or copies (`FrameWalker.copy`): Zig's code may hold each in a
/// temporary of its own, so the stack the frame really takes is at most
/// `sema.reach_factor` times its reach, which must fit
/// `sema.max_frame_reach`, far below the guard under the stack. Code Zig
/// writes more than once counts once for each copy: a `defer` or
/// `errdefer` body at every exit it covers (`FrameWalker.deferBody`), and
/// an inlined function at every call (`inlining.decide`, which fills each
/// owner's `sema.Account`). A frame whose reach passes
/// `sema.noinline_reach` is never inlined, so two such frames never merge
/// (`sema.SemContext.large_frames`).
///
/// A frame whose size depends on generic parameters is checked at each
/// instance (`checkInstanceSizes`). `recordFrameOwners` runs first.
pub fn checkFrames(ctx: *SemContext) Error!void {
    var w: FrameWalker = .{ .ctx = ctx };
    var i: u32 = 0;
    while (i < ctx.frame_owners.items.len) i = try checkOwnerTree(&w, i);
    // What each `inline` function lands in a caller's frame, worked out
    // here, where it is declared, for the modules that import this one.
    var it = ctx.inline_decls.keyIterator();
    while (it.next()) |pos| _ = try inlineFrame(ctx, pos.*, 1);
}

/// What the `inline` function declared at `pos` in this module lands in
/// the frame of a call of it: the values it keeps and its copies, and
/// those of the `inline` functions it calls in turn, each at the instance
/// its call makes, over its own and its type's parameters. Its closures
/// are frames of their own. Null while it is being worked out: a call on
/// a cycle of `inline` functions, which `inlining.decide` reports, so the
/// program is never emitted.
pub fn inlineFrame(ctx: *SemContext, pos: u32, depth: u32) Error!?[]const sema.FrameSlot {
    if (ctx.inline_frames.get(pos)) |known| return known;
    const node = ctx.inline_decls.get(pos).?;
    try ctx.inline_frames.put(ctx.allocator, pos, null);
    var w: FrameWalker = .{ .ctx = ctx, .depth = depth };
    var slots: FrameWalker.Slots = .empty;
    defer slots.deinit(ctx.allocator);
    for ([_]Sexp{ ir.get(node, .params), ir.get(node, .body) }) |part| try w.walk(part, &slots, false, false);
    try w.paramCopies(ir.get(node, .params), &slots);
    const kept = try ctx.arena.allocator().dupe(sema.FrameSlot, slots.items);
    try ctx.inline_frames.put(ctx.allocator, pos, kept);
    try ctx.inline_heights.put(ctx.allocator, pos, w.height);
    return kept;
}

/// The most calls of marked `inline` functions that may nest, each
/// inlined into the one around it: Zig's own analysis recurses once for
/// each, and runs out of its stack some thousands deep.
pub const max_inline_depth = 256;

/// Check owner `i` after the closures in it, in source order, as a
/// closure's frame is met inside its maker's: so a message about a
/// closure comes before one about the frame around it. The owners are
/// listed with each one's closures right after it. Returns the owner
/// after them.
pub fn checkOwnerTree(w: *FrameWalker, i: u32) Error!u32 {
    const owners = w.ctx.frame_owners.items;
    var j = i + 1;
    while (j < owners.len and owners[j].parent == i) j = try checkOwnerTree(w, j);
    try w.ownerFrame(i);
    return j;
}

/// Record the frame owners of `tree` (`sema.FrameOwner`), each with the
/// owner around it, and every call with the innermost owner around it
/// and the copies of it Zig writes (`sema.FrameCall`): one walk, which
/// knows the owners by a positive list of their kinds. Nothing else
/// finds an owner or attributes a call; `checkFrames`, `inlining.decide`,
/// and `rig check --facts=frames` read these.
pub fn recordFrameOwners(ctx: *SemContext, tree: Sexp) Error!void {
    var w: OwnerWalker = .{ .ctx = ctx };
    try w.walk(tree, null, 1, .{});
    const a = ctx.arena.allocator();
    const owners = ctx.frame_owners.items;
    const counts = try a.alloc(u32, owners.len);
    @memset(counts, 0);
    for (ctx.frame_calls.items) |c| if (c.owner) |o| {
        counts[o] += 1;
    };
    const lists = try a.alloc([]u32, owners.len);
    for (lists, counts) |*l, n| l.* = try a.alloc(u32, n);
    @memset(counts, 0);
    for (ctx.frame_calls.items, 0..) |c, i| if (c.owner) |o| {
        lists[o][counts[o]] = @intCast(i);
        counts[o] += 1;
    };
    for (owners, lists) |*o, l| o.calls = l;
}

pub const OwnerWalker = struct {
    ctx: *SemContext,

    /// What the declarations around a function make it: a member of a
    /// type, and of a generic one, and the type's name.
    const Decl = struct { member: bool = false, generic_type: bool = false, type_name: []const u8 = "" };

    /// `copies`: how many times Zig writes the code `node` is in, which a
    /// `defer` or `errdefer` body multiplies by its exits
    /// (`FrameWalker.deferBody` counts its values the same way).
    fn walk(self: *OwnerWalker, node: Sexp, owner: ?u32, copies: u32, decl: Decl) Error!void {
        const ctx = self.ctx;
        if (node != .list) return;
        const kind = node.kind() orelse {
            for (node.items()) |c| try self.walk(c, owner, copies, decl);
            return;
        };
        const a = ctx.arena.allocator();
        switch (kind) {
            .use => {},
            .fun, .sub => {
                // A compile-time function has no frame: it never runs when
                // the program does.
                if (rig.isCtFun(node)) return;
                const name = ir.get(node, .name);
                const label = try a.print("`{s}`", .{sema.identAt(ctx.source, name) orelse "?"});
                const o = try self.add(.{ .kind = .function, .root = node, .parent = owner, .pos = ctx.startOf(name), .label = label, .member = decl.member, .of_generic_type = decl.generic_type, .type_name = decl.type_name });
                for ([_]Sexp{ ir.get(node, .params), ir.get(node, .body) }) |part| try self.walk(part, o, 1, .{});
            },
            .@"test" => {
                const label = try a.print("test {s}", .{sema.identAt(ctx.source, ir.get(node, .name)) orelse "?"});
                const o = try self.add(.{ .kind = .test_block, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = label });
                try self.walk(ir.get(node, .body), o, 1, .{});
            },
            .drop_decl => {
                const o = try self.add(.{ .kind = .drop, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = "`drop`" });
                for ([_]Sexp{ ir.get(node, .params), ir.get(node, .body) }) |part| try self.walk(part, o, 1, .{});
            },
            .lambda => {
                // The captures are made where the closure is.
                try self.walk(ir.Lambda.captures(node), owner, copies, decl);
                const o = try self.add(.{ .kind = .closure, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = "a closure" });
                for ([_]Sexp{ ir.Lambda.params(node), ir.Lambda.body(node) }) |part| try self.walk(part, o, 1, .{});
            },
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => {
                const of: Decl = .{ .member = true, .generic_type = decl.generic_type or kind == .generic_struct or kind == .generic_enum, .type_name = sema.identAt(ctx.source, ir.get(node, .name)) orelse "" };
                for (rig.children(node)) |c| try self.walk(c, owner, copies, of);
            },
            .call => {
                // The callee first, as its object's calls run first.
                try self.walk(ir.Call.callee(node), owner, copies, decl);
                const i: u32 = @intCast(ctx.frame_calls.items.len);
                try ctx.frame_calls.append(ctx.allocator, .{ .node = node, .owner = owner, .copies = copies });
                if (sema.decisionKeyOf(node)) |k| try ctx.call_index.put(ctx.allocator, k, i);
                for (ir.Call.args(node)) |arg| try self.walk(arg, owner, copies, decl);
            },
            else => {
                const kids = rig.children(node);
                for (kids, 0..) |c, i| {
                    if (owner != null and (c.isKind(.@"defer") or c.isKind(.@"errdefer"))) {
                        var exits: u32 = 1;
                        for (kids[i + 1 ..]) |r| exits += @intCast(FrameWalker.countExits(r));
                        // Saturating: a count that large fails every limit.
                        try self.walk(ir.get(c, .body), owner, copies *| exits, decl);
                        continue;
                    }
                    try self.walk(c, owner, copies, decl);
                }
            },
        }
    }

    fn add(self: *OwnerWalker, o: sema.FrameOwner) Error!u32 {
        const i: u32 = @intCast(self.ctx.frame_owners.items.len);
        try self.ctx.frame_owners.append(self.ctx.allocator, o);
        return i;
    }
};

pub const FrameWalker = struct {
    ctx: *SemContext,
    /// How deep in calls of marked `inline` functions the body walked is
    /// (`inlineFrame`): 0 for an owner's own.
    depth: u32 = 0,
    /// The deepest nesting of marked calls below the body walked, which
    /// `inlineFrame` records (`SemContext.inline_heights`).
    height: u32 = 0,

    /// A value the frame keeps, or (`copy`) a copy its code may make,
    /// which counts in its reach alone; `marked` when a call of a marked
    /// `inline` function lands it there (`addInlined`).
    const Slot = sema.FrameSlot;
    const Slots = std.ArrayList(Slot);

    /// `copied`: the value of `node` is made or copied where it is used,
    /// so Zig's code may hold it in a temporary (`copiedIn`).
    fn walk(self: *FrameWalker, node: Sexp, frame: ?*Slots, bound: bool, copied: bool) Error!void {
        const ctx = self.ctx;
        if (node == .src) {
            const f = frame orelse return;
            const id = ctx.symbolOf(node) orelse return;
            const sym = ctx.symbols.items[id];
            if (sym.decl_pos != node.src.pos) {
                if (copied) try self.copy(node, f);
                return;
            }
            switch (sym.kind) {
                .local, .param, .capture => {},
                else => return,
            }
            if (sym.flags.comptime_known or sym.scope == sema.module_scope) return;
            try f.append(ctx.allocator, .{ .ty = sym.ty, .name = sym.name });
            return;
        }
        // A group (a parameter list) has no kind.
        const kind = node.kind() orelse {
            for (node.items()) |c| try self.walk(c, frame, false, false);
            return;
        };
        switch (kind) {
            // Frame owners of their own (`recordFrameOwners`).
            .fun, .sub, .@"test", .drop_decl => {},
            // The captures are stored where the closure is made; its body
            // is a frame of its own.
            .lambda => try self.walk(ir.Lambda.captures(node), frame, false, false),
            .set => {
                try self.walk(ir.Set.target(node), frame, false, false);
                // A fill built in the local makes no copy (`storage.fillsInPlace`).
                try self.walk(ir.Set.value(node), frame, true, !storage.fillsInPlace(ctx, node));
            },
            .box => {
                // A fill built in the box's allocation is no temporary.
                const in_place = storage.fillsInPlace(ctx, node);
                try self.walk(ir.Box.operand(node), frame, in_place, !in_place);
            },
            else => {
                if (frame) |f| {
                    switch (kind) {
                        .array, .array_fill => if (!bound) if (ctx.typeOf(node)) |ty| try f.append(ctx.allocator, .{ .ty = ty, .name = "" }),
                        .call => if (ctx.typeOf(node)) |ty| {
                            // A constructor builds its value where a binding takes it.
                            if (!bound or self.callsFunction(node)) try f.append(ctx.allocator, .{ .ty = ty, .name = "" });
                        },
                        else => {},
                    }
                    if (copied) try self.copy(node, f);
                    if (kind == .call) {
                        // A self a method takes by value is copied.
                        if (storage.selfOf(ctx, node)) |recv| if (self.takesSelf(node)) try self.copy(recv, f);
                        try self.addInlined(node, f);
                    }
                }
                const kids = rig.children(node);
                for (kids, 0..) |c, i| {
                    if (frame) |f| if (c.isKind(.@"defer") or c.isKind(.@"errdefer")) {
                        try self.deferBody(c, f, kids[i + 1 ..]);
                        continue;
                    };
                    // A fork's record, in a slot of this frame
                    // (`storage.taskRecordIn`, `task_record`).
                    if (frame) |f| if (kind == .block) if (try storage.taskRecordIn(ctx, c, node)) |task| {
                        const bytes = (try storage.taskRecordBytes(ctx, task)).?;
                        const byte = try ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
                        const record = try ctx.intern(.{ .array = .{ .elem = byte, .len = try sema.ctInt(ctx, @intCast(bytes)) } });
                        try f.append(ctx.allocator, .{ .ty = record, .name = "a task's record" });
                    };
                    try self.walk(c, frame, false, self.copiedIn(node, c));
                }
            },
        }
    }

    /// Whether the value of `child` is made or copied where `parent` uses
    /// it, by a positive list of the uses that read it in place: a callee,
    /// and the base of a field or element path or the operand of a view
    /// that is storage (`storage.hasStorage`) or reached where its leaf is
    /// (`storage.reachesLeaf`); any other base or operand is made into a
    /// temporary first.
    fn copiedIn(self: *FrameWalker, parent: Sexp, child: Sexp) bool {
        const ctx = self.ctx;
        return switch (parent.kind().?) {
            .member, .index => !sameSite(child, ir.get(parent, .object)) or !readsInPlace(ctx, child),
            .read, .write => !readsInPlace(ctx, child),
            .call => !sameSite(child, ctx.calleeOf(parent)),
            else => true,
        };
    }

    fn readsInPlace(ctx: *SemContext, e: Sexp) bool {
        return storage.hasStorage(ctx, e) or storage.reachesLeaf(ctx, e);
    }

    /// Whether the method `call` calls takes its self by value, not
    /// through a view.
    fn takesSelf(self: *FrameWalker, call: Sexp) bool {
        const ctx = self.ctx;
        const f = storage.fnType(ctx, storage.typeOf(ctx, ctx.calleeOf(call))) orelse return false;
        if (f.params.len == 0) return false;
        return switch (ctx.types.get(f.params[0])) {
            .read_view, .write_view => false,
            else => true,
        };
    }

    /// A `defer` or `errdefer`, whose body Zig writes again at each exit
    /// of its block it covers: every exit among the statements after it
    /// (`storage.leave_kinds`), and the block's end. The body's values
    /// and copies count once more for each exit past the first, as
    /// copies.
    fn deferBody(self: *FrameWalker, d: Sexp, f: *Slots, rest: []const Sexp) Error!void {
        const ctx = self.ctx;
        const start = f.items.len;
        try self.walk(ir.get(d, .body), f, false, false);
        var exits: usize = 1;
        for (rest) |r| exits += countExits(r);
        const once = try ctx.arena.allocator().dupe(Slot, f.items[start..]);
        for (1..exits) |_| for (once) |slot| try f.append(ctx.allocator, .{ .ty = slot.ty, .name = "", .copy = true, .marked = slot.marked });
    }

    /// The values a call of a marked `inline` function lands in the frame
    /// it is in (`sema.InlineCall`): the function's own values and copies
    /// and those of the marked functions it calls in turn
    /// (`inlineFrame`), at the instance the call makes, in this module's
    /// types, each marked. The count fails closed: a frame no count knows,
    /// or one the instance does not make concrete, is an error at the
    /// call, never no values.
    fn addInlined(self: *FrameWalker, call: Sexp, f: *Slots) Error!void {
        const ctx = self.ctx;
        const ic = ctx.inlineCallOf(call) orelse return;
        const decl = ctx.declaringContext(ic.fun) orelse return self.unknownFrame(call, "its module is not loaded");
        const local = decl == @as(*const SemContext, ctx);
        if (!decl.inline_decls.contains(ic.fun.pos)) return self.unknownFrame(call, "its declaration is not recorded");
        // Zig inlines each call into the body it is in, nested as deep as
        // the calls are: past `max_inline_depth` Zig itself runs out of
        // stack, so a deeper nesting is an error, found before this walk
        // goes deeper.
        if (self.depth + 1 > max_inline_depth) return self.tooDeep(call);
        const slots = if (local)
            // Null on a cycle of `inline` functions, which
            // `inlining.decide` reports, so the program is never emitted.
            (try inlineFrame(ctx, ic.fun.pos, self.depth + 1)) orelse return
        else
            // The module that declares it worked out its frame
            // (`checkFrames`), unless that module failed its check.
            (decl.inline_frames.get(ic.fun.pos) orelse return self.unknownFrame(call, "its module did not count it")) orelse return self.unknownFrame(call, "its module did not count it");
        const below = decl.inline_heights.get(ic.fun.pos) orelse 0;
        if (self.depth + 1 + below > max_inline_depth) return self.tooDeep(call);
        self.height = @max(self.height, below + 1);
        // The instance binds every parameter the frame mentions: with each
        // argument poisoned, none is left.
        const a = ctx.arena.allocator();
        const blank = try a.alloc(TypeId, ic.subst.args.len);
        @memset(blank, ctx.types.invalid_id);
        for (slots) |slot| {
            const ty = if (local) slot.ty else try sema.importType(ctx, decl, slot.ty, ic.fun.module);
            if (sema.containsTypeVar(ctx, try sema.substituteType(ctx, ty, .{ .params = ic.subst.params, .args = blank })))
                return self.unknownFrame(call, "the call does not bind every parameter its values hold");
            try f.append(ctx.allocator, .{ .ty = try sema.substituteType(ctx, ty, ic.subst), .name = slot.name, .copy = slot.copy, .marked = true });
        }
    }

    /// A copy of each parameter of the function whose parameters are
    /// `params`: where it is inlined, Zig's code copies each into a local
    /// of its own (`rig.rt`), beside the argument a call makes and the
    /// parameter itself.
    fn paramCopies(self: *FrameWalker, params: Sexp, f: *Slots) Error!void {
        if (params != .list) return;
        for (params.items()) |p| {
            const name = sema.paramNameNode(p) orelse continue;
            const id = self.ctx.symbolOf(name) orelse continue;
            const sym = self.ctx.symbols.items[id];
            if (sym.kind != .param or sym.flags.comptime_known) continue;
            try f.append(self.ctx.allocator, .{ .ty = sym.ty, .name = "", .copy = true });
        }
    }

    fn unknownFrame(self: *FrameWalker, call: Sexp, why: []const u8) Error!void {
        try self.ctx.errAt(ir.Call.callee(call), "cannot count the values this `inline` call adds to the frame it is in ({s}); a frame must be known to be checked", .{why});
    }

    fn tooDeep(self: *FrameWalker, call: Sexp) Error!void {
        try self.ctx.errAt(ir.Call.callee(call), "calls of `inline` functions nest more than {d} deep through this one, which no build can inline; drop `inline` from one of them", .{max_inline_depth});
    }

    /// The exits in `e` (`storage.leave_kinds`), not counting those in its
    /// closures.
    pub fn countExits(e: Sexp) usize {
        if (e != .list) return 0;
        const kind = e.kind() orelse {
            var n: usize = 0;
            for (e.items()) |c| n += countExits(c);
            return n;
        };
        if (kind == .lambda) return 0;
        var n: usize = @intFromBool(std.mem.findScalar(Tag, &storage.leave_kinds, kind) != null);
        for (rig.children(e)) |c| n += countExits(c);
        return n;
    }

    /// A copy of the value of `node` in the frame's reach, unless it is
    /// viewed where it is used (a pointer) or fits in registers. A view its
    /// context reads through (`readsThrough`: a use that expects the
    /// value copies it out) counts at the size of what it views.
    fn copy(self: *FrameWalker, node: Sexp, f: *Slots) Error!void {
        const ctx = self.ctx;
        if (ctx.viewOf(node) != null) return;
        const seen = ctx.typeOf(node) orelse return;
        const ty = if (ctx.readsThrough(node)) sema.unwrapViews(ctx, seen) else seen;
        if (!sema.containsTypeVar(ctx, ty)) {
            if (sema.containsPoison(ctx, ty)) return;
            const b = (try sema.minBytes(ctx, ty)) orelse return;
            if (b <= sema.register_bytes) return;
        }
        try f.append(ctx.allocator, .{ .ty = ty, .name = "", .copy = true });
    }

    /// Whether `call` calls a function or method, not a type's constructor.
    fn callsFunction(self: *FrameWalker, call: Sexp) bool {
        const callee = self.ctx.calleeOf(call);
        if (callee.isKind(.member)) return true;
        const id = self.ctx.symbolOf(callee) orelse return false;
        return self.ctx.symbols.items[id].kind == .function;
    }

    /// The frame of owner `index`, checked now or, when its size depends
    /// on generic parameters, at each instance; its own count goes into
    /// the owner (`sema.FrameOwner.own`).
    fn ownerFrame(self: *FrameWalker, index: u32) Error!void {
        const ctx = self.ctx;
        const owner = ctx.frame_owners.items[index];
        const root = owner.root;
        const label = owner.label;
        const pos = owner.pos;
        var slots: Slots = .empty;
        defer slots.deinit(ctx.allocator);
        const nodes: []const Sexp = switch (owner.kind) {
            .function, .drop => &.{ ir.get(root, .params), ir.get(root, .body) },
            .test_block => &.{ir.get(root, .body)},
            .closure => &.{ ir.Lambda.params(root), ir.Lambda.body(root) },
        };
        for (nodes) |p| try self.walk(p, &slots, false, false);
        // A function's parameters, copied where the rule inlines it.
        var params: Slots = .empty;
        defer params.deinit(ctx.allocator);
        if (owner.kind == .function) try self.paramCopies(ir.get(root, .params), &params);
        const items = slots.items;
        if (items.len + params.items.len == 0) {
            ctx.frame_owners.items[index].own = .none;
            return;
        }
        // The values first, then the copies; in each, its own, then what
        // marked calls land in it; then the parameters' copies.
        const arena = ctx.arena.allocator();
        const tys = try arena.alloc(TypeId, items.len + params.items.len);
        const names = try arena.alloc([]const u8, tys.len);
        var n: usize = 0;
        var parts: FrameParts = .{};
        for ([_]bool{ false, true }) |copies| for ([_]bool{ false, true }) |mark| for (items) |s| if (s.copy == copies and s.marked == mark) {
            tys[n] = s.ty;
            names[n] = s.name;
            n += 1;
            if (copies) parts.copies += 1;
            if (mark and copies) parts.marked_copies += 1;
            if (mark and !copies) parts.marked += 1;
        };
        for (params.items) |s| {
            tys[n] = s.ty;
            names[n] = s.name;
            n += 1;
        }
        parts.params = @intCast(params.items.len);
        for (tys) |ty| if (sema.containsTypeVar(ctx, ty)) {
            try ctx.addGeneric(.frames, .{ .label = label, .pos = pos, .tys = tys, .names = names, .copies = parts.copies, .marked = parts.marked, .marked_copies = parts.marked_copies, .params = parts.params });
            ctx.frame_owners.items[index].per_instance = true;
            return;
        };
        const counted = (try checkFrame(ctx, pos, label, null, tys, names, parts, pos)) orelse return;
        ctx.frame_owners.items[index].own = counted.own;
        ctx.frame_owners.items[index].marked = counted.marked;
        ctx.frame_owners.items[index].params = counted.params;
    }
};

/// How a frame's types (`sema.Frame.tys`) are laid out: the values, then
/// `copies`, which are copies its code may make, then `params`, a
/// function's parameters as the code copies them where it is inlined;
/// of the values the last `marked`, and of the copies the last
/// `marked_copies`, are what calls of marked `inline` functions land in
/// it.
pub const FrameParts = struct { copies: u32 = 0, marked: u32 = 0, marked_copies: u32 = 0, params: u32 = 0 };

/// A frame's count: its own values, what marked calls land in it
/// (`sema.Account`), and the reach of its parameters' copies where it is
/// inlined (`sema.FrameOwner.params`).
pub const FrameCounted = struct { own: sema.FrameCount, marked: sema.FrameCount, params: u128 = 0 };

/// Check the frame of `label` whose types are `tys`, laid out as `parts`
/// says: its count, its own values and what marked calls land in it
/// together, against `sema.max_frame_bytes` and its reach against
/// `sema.max_frame_reach`. A large one marks its declaration, at `decl`
/// in `module` (0 for this one), `noinline` (`sema.SemContext.large_frames`).
/// A marked `inline` function's frame is counted, for what the rule
/// inlines through it (`inlining.decide`), and not checked: Zig never
/// writes it, and its values land in each caller's, which is.
pub fn checkFrame(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, decl: u32) Error!?FrameCounted {
    return checkFrameIn(ctx, pos, label, of, tys, names, parts, 0, decl);
}

/// The count of the frame, null when a value in it follows an error. It
/// is recorded (`SemContext.frame_sizes`) as the frame of the owner
/// declared at `decl` in module `module` (0 for this one).
pub fn checkFrameIn(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, module: u32, decl: u32) Error!?FrameCounted {
    const body = tys[0 .. tys.len - parts.params];
    const values = body[0 .. body.len - parts.copies];
    const copied = body[values.len..];
    const bytes = (try frameBytes(ctx, values)) orelse return null;
    const reach = bytes + ((try reachBytes(ctx, copied)) orelse return null);
    const marked_bytes = (try frameBytes(ctx, values[values.len - parts.marked ..])) orelse return null;
    const marked: sema.FrameCount = .{ .bytes = marked_bytes, .reach = marked_bytes + ((try reachBytes(ctx, copied[copied.len - parts.marked_copies ..])) orelse return null) };
    const params = (try reachBytes(ctx, tys[body.len..])) orelse return null;
    const counted: FrameCounted = .{ .own = .{ .bytes = bytes - marked.bytes, .reach = reach - marked.reach }, .marked = marked, .params = params };
    const shown = if (of) |root| try ctx.arena.allocator().print("{s} in `{s}`", .{ label, try sema.rootName(ctx, root) }) else label;
    const declared = if (module == 0) ctx.module_id else module;
    try ctx.frame_sizes.append(ctx.allocator, .{ .label = shown, .pos = pos, .bytes = counted.own.bytes, .reach = counted.own.reach, .marked = marked, .params = params, .module = declared, .decl = decl });
    // A marked `inline` function's frame is never written: its values
    // land in each caller's, which is checked in turn.
    const decl_ctx = ctx.declaringContext(.{ .module = declared, .pos = decl }) orelse return counted;
    if (decl_ctx.inline_decls.contains(decl)) return counted;
    if (bytes > sema.max_frame_bytes) {
        try reportFrame(ctx, pos, label, bytes, of, values, names[0..values.len]);
        return counted;
    }
    if (reach * sema.reach_factor > sema.max_frame_reach) {
        const in = if (of) |root| try ctx.arena.allocator().print(" in `{s}`", .{try sema.rootName(ctx, root)}) else "";
        try ctx.err(pos, "{s} makes or copies {d} bytes of values{s}, and a build may hold each in a temporary of its own on the stack, {d} times over at most; a function's code may take at most {d} bytes (512 MiB) of stack. Keep large data on the heap, in a box (`^T`) or a `List`, or split the function", .{ label, reach, in, sema.reach_factor, sema.max_frame_reach });
        return counted;
    }
    if (reach * sema.reach_factor < sema.noinline_reach) return counted;
    // Within `max_frame_reach`, checked above.
    const takes: u64 = @intCast(reach * sema.reach_factor);
    if (declared == ctx.module_id) try sema.markLarge(&ctx.large_frames, ctx.allocator, decl, takes) else try ctx.large_foreign_frames.append(ctx.allocator, .{ .module = module, .pos = decl, .bytes = takes });
    return counted;
}

/// The bytes of the copies `tys`, each that does not fit in registers;
/// null when one follows an error.
pub fn reachBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
    var total: u128 = 0;
    for (tys) |ty| {
        if (sema.containsPoison(ctx, ty)) return null;
        const b = (try sema.minBytes(ctx, ty)) orelse return null;
        if (b > sema.register_bytes) total += b;
    }
    return total;
}

/// The bytes the values `tys` take together; null when one follows an
/// error or is too large by itself, which is reported on its own.
pub fn frameBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
    var total: u128 = 0;
    for (tys) |ty| {
        if (sema.containsPoison(ctx, ty)) return null;
        const b = (try sema.minBytes(ctx, ty)) orelse return null;
        if (b > sema.max_value_bytes) return null;
        total += b;
    }
    return total;
}

pub fn reportFrame(ctx: *SemContext, pos: u32, label: []const u8, bytes: u128, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8) Error!void {
    const in = if (of) |root| try ctx.arena.allocator().print(" in `{s}`", .{try sema.rootName(ctx, root)}) else "";
    // The three largest, by name where a local has one.
    var top: [3]usize = undefined;
    var n: usize = 0;
    for (tys, 0..) |ty, i| {
        const b = (try sema.minBytes(ctx, ty)) orelse 0;
        var at = n;
        while (at > 0 and (try sema.minBytes(ctx, tys[top[at - 1]])).? < b) : (at -= 1) {}
        if (at >= top.len) continue;
        if (n < top.len) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) top[j] = top[j - 1];
        top[at] = i;
    }
    var largest: std.ArrayList(u8) = .empty;
    for (top[0..n], 0..) |i, k| {
        const b = (try sema.minBytes(ctx, tys[i])) orelse 0;
        const what = if (names[i].len > 0) try ctx.arena.allocator().print("`{s}`", .{names[i]}) else "a temporary";
        try largest.appendSlice(ctx.arena.allocator(), try ctx.arena.allocator().print("{s}{s} ({d} bytes)", .{ if (k == 0) "" else ", ", what, b }));
    }
    try ctx.err(pos, "{s} keeps {d} bytes of values on its stack{s}; a function keeps at most {d} (13 MiB). Its largest: {s}. Keep large data on the heap, in a box (`^T`) or a `List`", .{ label, bytes, in, sema.max_frame_bytes, largest.items });
}

/// The arrays a generic declaration makes, in one instance, and a generic
/// type's instance itself, must fit `sema.max_value_bytes`; the instance
/// must also nest at most `sema.max_value_depth` deep.
pub fn checkInstanceSizes(ctx: *SemContext, params: []const SymbolId, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!void {
    for (args) |a| if (sema.containsPoison(ctx, a)) return;
    const subst: sema.TypeSubst = .{ .params = params, .args = args };
    var entries: std.ArrayList(u32) = .empty;
    defer entries.deinit(ctx.allocator);
    try ctx.genericEntries(.arrays, params, &entries);
    for (entries.items) |i| {
        const g = ctx.generic_arrays.items[i];
        const ty = try sema.substituteType(ctx, g.ty, subst);
        if (sema.containsTypeVar(ctx, ty) or sema.containsPoison(ctx, ty)) continue;
        const bytes = (try sema.arrayOversized(ctx, ty)) orelse continue;
        try ctx.oversized.put(ctx.allocator, ty, {});
        if (of == .type) try ctx.oversized.put(ctx.allocator, of.type, {});
        try ctx.err(at, "`{s}` makes `{s}`, which takes {d} bytes; a value takes at most {d} (8 MiB), since it may live on the stack. Keep larger data in a `List`", .{ try sema.rootName(ctx, of), try sema.formatType(ctx, ty), bytes, sema.max_value_bytes });
        try ctx.noteIn(g.module_id, g.pos, "the array is made here", .{});
        return;
    }
    if (of == .type) {
        const sym = ctx.types.get(of.type).parameterized_nominal.sym;
        if (try sema.oversizedByItself(ctx, of.type, sym, subst)) |bytes| {
            try sema.reportOversized(ctx, at, of.type, bytes);
            return;
        }
        if (try sema.tooDeepByItself(ctx, of.type, sym, subst)) |depth| {
            try sema.reportTooDeep(ctx, at, of.type, depth);
            return;
        }
    }
    // A function instance checks the frames that use its own parameters;
    // those that use only its type's are checked with the type's instance.
    const own = switch (of) {
        .func => |f| f.ownParams(),
        .type => params,
    };
    var buf: std.ArrayList(TypeId) = .empty;
    defer buf.deinit(ctx.allocator);
    try ctx.genericEntries(.frames, own, &entries);
    frames: for (entries.items) |i| {
        const fr = ctx.generic_frames.items[i];
        buf.clearRetainingCapacity();
        for (fr.tys) |ty| {
            const t = try sema.substituteType(ctx, ty, subst);
            if (sema.containsTypeVar(ctx, t)) continue :frames;
            try buf.append(ctx.allocator, t);
        }
        const before = ctx.diagnostics.items.len;
        _ = try checkFrameIn(ctx, at, fr.label, of, buf.items, fr.names, .{ .copies = fr.copies, .marked = fr.marked, .marked_copies = fr.marked_copies, .params = fr.params }, fr.module_id, fr.pos);
        if (ctx.diagnostics.items.len == before) continue;
        try ctx.noteIn(fr.module_id, fr.pos, "{s} is declared here", .{fr.label});
        return;
    }
}

/// Why a value holding `blocker` cannot go to another task
/// (`Checker.crossCheck`), and to be read there when `shared`; `verb`
/// says how it relates to `blocker` when it is that type or views it.
pub fn crossingReason(ctx: *SemContext, blocker: TypeId, shared: bool, verb: ?[]const u8) Error![]const u8 {
    const a = ctx.arena.allocator();
    const what = verb orelse try std.fmt.allocPrint(a, "holds `{s}`,", .{try sema.formatType(ctx, blocker)});
    const blocker_is_weak = ctx.types.get(blocker) == .weak;
    const why: []const u8 = switch (ctx.types.get(blocker)) {
        .shared, .weak => |inner| if (ctx.types.get(inner) == .function)
            "an owned closure, whose captures its type does not show"
        else if (blocker_is_weak and (sema.isWordCell(ctx, inner) or sema.cellObject(ctx, inner)))
            "a `~` handle, which stays with one task; a `*` handle to the same value goes to other tasks"
        else if (blocker_is_weak)
            "a `~` handle whose count is not atomic, so two cores could change it at once"
        else if (sema.isCell(ctx, inner))
            "a `*` handle to a Cell of more than one word, which stays with one task; a Cell of an `Int`, `Bool`, `Float`, or plain enum goes to other tasks"
        else if (try sema.cellRefusalReason(ctx, inner)) |reason|
            reason
        else
            "a `*` handle whose count is not atomic, so two cores could change it at once",
        .callable => "a closure or function passed to a call as a view, whose captures its type does not show",
        .write_view => "a write view, which no two tasks may hold at once",
        // The bound it lacks for the form that reached it: one named
        // alone says which the other is.
        .api_object => |o| blk: {
            const named = sema.objectBounds(ctx, o);
            if (named.contains(.Sends)) break :blk "an API object whose braces and API name no `Syncs`, so no two tasks may read what it hides";
            if (named.contains(.Syncs)) break :blk "an API object whose braces and API name no `Sends`, so what it hides may not go to another task";
            break :blk "an API object whose braces and API name no `Sends` or `Syncs` for this, so what it hides may go to no task";
        },
        .parameterized_nominal => |pn| if (pn.sym == ctx.task_sym_id and shared)
            "a task, which only the one that holds it may wait for"
        else if (pn.sym == ctx.tasks_sym_id)
            "a set of tasks, which stays with the task that made it"
        else
            "a value that changes through handles that stay on this core",
        else => "a value that cannot go to another core",
    };
    return std.fmt.allocPrint(a, "{s} {s}", .{ what, why });
}

/// `inst`, made at `at`, gives its parameter `pname` the type `arg`, which
/// fails `req`, a `Requirement.task` or `.no_task`: the error, and a note
/// at the body's line.
pub fn reportTaskReq(ctx: *SemContext, req: sema.GenericRequirement, at: u32, inst: []const u8, pname: []const u8, arg: TypeId) Error!void {
    const aname = try sema.formatType(ctx, arg);
    switch (req.req) {
        .no_task => {
            try ctx.err(at, "`{s}` cannot use `{s} = {s}`: {s}, and {s}", .{ inst, pname, aname, req.op, try taskWhy(ctx, arg) });
            try ctx.noteIn(req.module_id, req.pos, "`{s}` hidden here", .{pname});
        },
        .task => |reach| {
            const blocker = (try sema.taskBlocker(ctx, arg, reach)).?;
            // A value a local task takes: the task the body makes crosses.
            // (An erasure hides the value in an object, which crosses by
            // its bound wherever it goes.)
            const crosses = !reach.local and (try sema.localBlocker(ctx, arg, reach.how)) == null and !std.mem.startsWith(u8, req.op, "is erased");
            const whose = if (std.mem.find(u8, req.op, "actor") != null) "the actor's task" else "the body's task";
            try ctx.err(at, "`{s}` cannot use `{s} = {s}`: a value that holds a `{s}` {s} in the generic body, and `{s}` {s}{s}{s}{s}", .{ inst, pname, aname, pname, req.op, aname, try crossingReason(ctx, blocker, reach.how == .shares, if (blocker == arg) "is" else null), if (crosses) "; " else "", if (crosses) whose else "", if (crosses) " may run on another core in every instance, so it takes nothing that stays on one thread" else "" });
            try ctx.noteIn(req.module_id, req.pos, "a `{s}` {s} here", .{ pname, req.op });
        },
        else => unreachable,
    }
}

/// The methods the program reaches (`sema.BodyReach`), each checked
/// against what its body requires of its type's parameters
/// (`GenericRequirement.body`): at the call that reaches it, or that
/// makes the instance of the body whose call does.
pub fn checkReaches(ctx: *SemContext) Error!void {
    var i: usize = 0;
    while (i < ctx.body_reaches.items.len) : (i += 1) {
        const r = ctx.body_reaches.items[i];
        for (ctx.generic_requirements.items) |req| {
            if (req.body == sema.no_body or req.body != r.fun.pos) continue;
            if ((if (req.module_id == 0) ctx.module_id else req.module_id) != r.fun.module) continue;
            if (req.index >= r.args.len) continue;
            const arg = r.args[req.index];
            if (sema.containsPoison(ctx, arg) or sema.containsTypeVar(ctx, arg)) continue;
            if (!try sema.liveAt(ctx, req.module_id, req.pos, r.params, r.args)) continue;
            if (try satisfies(ctx, arg, req.req)) continue;
            const inst = try sema.rootName(ctx, .{ .func = try sema.reachInstance(ctx, r) });
            try reportTaskReq(ctx, req, r.site, inst, ctx.symbols.items[req.param].name, arg);
            if (r.via) |via| try ctx.note(r.site, "`{s}` is reached from `{s}`", .{ inst, try sema.rootName(ctx, via) });
            break;
        }
    }
}

/// The positions of `generic_requirements` on each parameter, in order.
pub const Requirements = std.AutoHashMapUnmanaged(SymbolId, std.ArrayList(u32));

/// False after a diagnostic.
pub fn checkRequirements(ctx: *SemContext, reqs: *const Requirements, given_params: []const SymbolId, given_args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    var ok = true;
    // The associated types of the parameters too (`I.Item`), at what each
    // argument gives them.
    const all = try sema.withAssoc(ctx, given_params, given_args);
    const params = all.params;
    const args = all.args;
    for (params, 0..) |param, i| {
        if (i >= args.len) break;
        const arg = args[i];
        // A diagnostic was reported about the argument.
        if (sema.containsPoison(ctx, arg)) continue;
        const on = reqs.getPtr(param) orelse continue;
        for (on.items) |r| {
            const req = ctx.generic_requirements.items[r];
            // What code this instance does not compile needs (`sema.liveAt`).
            if (!try sema.liveAt(ctx, req.module_id, req.pos, params, args)) continue;
            if (try satisfies(ctx, arg, req.req)) continue;
            const inst = try sema.rootName(ctx, of);
            const pname = ctx.symbols.items[param].name;
            const aname = try sema.formatType(ctx, arg);
            const cannot = "`{s}` cannot use `{s} = {s}`: the generic body ";
            switch (req.req) {
                .copies, .no_cleanup => if (sema.typeHasDropGlue(ctx, arg))
                    try ctx.err(at, cannot ++ "{s} that holds a `{s}`, which would leak or duplicate the resource `{s}` owns", .{ inst, pname, aname, req.op, pname, aname })
                else
                    try ctx.err(at, cannot ++ "{s} that holds a `{s}`, and `{s}` is unique", .{ inst, pname, aname, req.op, pname, aname }),
                .clones => try ctx.err(at, cannot ++ "{s} that holds a `{s}`, and `{s}` is not `Clone`", .{ inst, pname, aname, req.op, pname, aname }),
                .array_len => try ctx.err(at, cannot ++ "uses `{s}` as an array length, which runs from 0 to {d}", .{ inst, pname, aname, pname, sema.max_array_len }),
                .lane_count => try ctx.err(at, cannot ++ "uses `{s}` as a lane count, a power of two from 2 to 64", .{ inst, pname, aname, pname }),
                .slot_count => try ctx.err(at, cannot ++ "names `Slot[{s}]`, and a slot names one of `n` slots, `n` at least 1", .{ inst, pname, aname, pname }),
                .sized => try ctx.err(at, cannot ++ "takes `${s}` of a type that holds a `{s}`, and `{s}` holds a vector, whose size and alignment differ from target to target", .{ inst, pname, aname, req.op, pname, aname }),
                .bytes => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` in bytes, which takes an integer or float type", .{ inst, pname, aname, req.op, pname }),
                .records => try ctx.err(at, cannot ++ "makes a `{s}` from bytes with `extend_from_bytes`, and not every bit pattern is {s} `{s}`: give `{s}` an integer, a float, or an object or array of them with no padding", .{ inst, pname, aname, pname, article(aname), aname, pname }),
                .fits => |v| try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and the literal `{d}`, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, v, aname }),
                .float => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and a float literal, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, aname }),
                .shift => |v| try ctx.err(at, cannot ++ "shifts a `{s}` by {d} bits, which `{s}` is too narrow for", .{ inst, pname, aname, pname, v, aname }),
                .printable => if (try sema.objectUnprinted(ctx, arg)) |held|
                    try ctx.err(at, cannot ++ "{s}s a value that holds a `{s}`, and `{s}` cannot be {s}: its type is erased, and its braces and API name no `Print`", .{ inst, pname, aname, req.op, pname, try sema.formatType(ctx, held), if (std.mem.eql(u8, req.op, "write")) "written" else "printed" })
                else
                    try ctx.err(at, cannot ++ "{s}s a value that holds a `{s}`, and {s} would {s} as text, like a `?String`", .{ inst, pname, aname, req.op, pname, if (std.mem.eql(u8, aname, "[]U8")) "a `[]U8`" else try ctx.arena.allocator().print("the `[]U8` a `{s}` holds", .{aname}), req.op }),
                .whole_division => try ctx.err(at, cannot ++ "gives a `{s}` the division of whole numbers `{s}`, which divides integers, not a `{s}`", .{ inst, pname, aname, pname, req.op, aname }),
                .not_error => try ctx.err(at, "`{s}` cannot use `{s} = {s}`: a return type `{s}!` would make a failure and a success both `{s}` values", .{ inst, pname, aname, pname, aname }),
                .error_set => try ctx.err(at, "`{s}` cannot use `{s} = {s}`: `{s}` names an error set, and `{s}` is not one", .{ inst, pname, aname, pname, aname }),
                .not_function => try ctx.err(at, cannot ++ "makes a handle `{s}{s}` of a `{s}`, and `{s}` is a function type: `*{s}` is an owned closure, not a handle of a function. Hold the owned closure itself in a `{s}`: `{s} = *{s}`", .{ inst, pname, aname, req.op[1..2], pname, pname, aname, aname, pname, pname, aname }),
                .named => {
                    const held = sema.unnameable(ctx, arg).?;
                    const what = if (held == arg) "is one" else try ctx.arena.allocator().print("holds `{s}`", .{try sema.formatType(ctx, held)});
                    try ctx.err(at, cannot ++ "names a type that holds a `{s}` with `$name`, which spells no view or slice in a type parameter's instance but a `?String`, and `{s}` {s}", .{ inst, pname, aname, pname, aname, what });
                },
                .frozen => try ctx.err(at, cannot ++ "freezes a value that holds a `{s}`, and {s}", .{ inst, pname, aname, pname, try sema.frozenReason(ctx, arg, (try sema.frozenBlocker(ctx, arg)).?) }),
                .no_task, .task => try reportTaskReq(ctx, req, at, inst, pname, arg),
                .meets => |api| try ctx.err(at, cannot ++ "{s}, and `{s}` is not `{s}`", .{ inst, pname, aname, req.op, aname, @tagName(api) }),
                .order => {
                    const lack: sema.Lack = (try sema.lacks(ctx, arg, .Ord)) orelse .{ .ty = arg };
                    try ctx.err(at, cannot ++ "orders a `{s}` with `order`, and `{s}` cannot be ordered{s}", .{ inst, pname, aname, pname, aname, try sema.lackDetail(ctx, ctx.arena.allocator(), arg, .Ord, lack) });
                },
                .equatable => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support: {s}", .{ inst, pname, aname, req.op, pname, aname, try notEquatableReason(ctx, (try sema.notEquatable(ctx, arg, null)).?) }),
                .hashable => try ctx.err(at, cannot ++ "hashes a `{s}` with `.hash()`, which `{s}` does not support: {s}", .{ inst, pname, aname, pname, aname, try notEquatableReason(ctx, (try sema.notHashable(ctx, arg, null)).?) }),
                else => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support", .{ inst, pname, aname, req.op, pname, aname }),
            }
            switch (req.req) {
                .copies, .no_cleanup, .clones => try ctx.noteIn(req.module_id, req.pos, "here", .{}),
                .array_len => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as an array length here", .{pname}),
                .lane_count => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as a lane count here", .{pname}),
                .slot_count => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as a slot count here", .{pname}),
                .bytes, .fits, .float, .shift, .whole_division => try ctx.noteIn(req.module_id, req.pos, "`{s}` used here", .{req.op}),
                .not_error => try ctx.noteIn(req.module_id, req.pos, "`{s}!` returned here", .{pname}),
                .error_set => try ctx.noteIn(req.module_id, req.pos, "`!{s}` here", .{pname}),
                .not_function => try ctx.noteIn(req.module_id, req.pos, "`{s}{s}` here", .{ req.op[1..2], pname }),
                .named => try ctx.noteIn(req.module_id, req.pos, "`$name` here", .{}),
                .printable => try ctx.noteIn(req.module_id, req.pos, "written here", .{}),
                .frozen => try ctx.noteIn(req.module_id, req.pos, "frozen here", .{}),
                .no_task, .task => {},
                .meets => try ctx.noteIn(req.module_id, req.pos, "erased here", .{}),
                else => try ctx.noteIn(req.module_id, req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() }),
            }
            ok = false;
            break;
        }
    }
    return ok;
}

/// Whether `ty` is an `obj` or an `enum` a module declares, whose
/// methods a call on a type parameter reaches as Zig resolves it in each
/// instance; a built-in type's methods are lowered by emit at a call of
/// a known type, so none is reached through a type parameter.
pub fn declaredType(ctx: *const SemContext, ty: TypeId) bool {
    switch (ctx.types.get(ty)) {
        .nominal, .imported_nominal, .parameterized_nominal => {},
        else => return false,
    }
    const decl = sema.nominalDecl(ctx, ty) orelse return false;
    return decl.symbol().decl_pos != sema.builtin_decl_pos and !(decl.module_id == null and sema.isBuiltinGeneric(ctx, decl.sym));
}

/// The method calls generic bodies make on the parameters `own`
/// (`sema.GenericMethodCall`), checked at the instance `subst` made at
/// `at`: a call whose types this instance leaves open is checked where
/// they are bound. A type's instance leaves open what its methods' own
/// parameters bind; a method's instance checks only the calls on its own
/// parameters or whose types name one. False after a diagnostic.
pub fn checkMethodCalls(ctx: *SemContext, subst: TypeSubst, own: []const SymbolId, at: u32, of: sema.InstanceRoot) Error!bool {
    const outer: TypeSubst = .{ .params = subst.params[0 .. subst.params.len - own.len], .args = subst.args[0 .. subst.args.len - own.len] };
    var i: usize = 0;
    while (i < ctx.generic_methods.items.len) : (i += 1) {
        const c = ctx.generic_methods.items[i];
        if (subst.lookup(c.param) == null) continue;
        if (std.mem.findScalar(SymbolId, own, c.param) == null) {
            // On a type's parameter: checked with a method's instance only
            // where it names one of the method's own.
            if (of == .func and !try namesOwn(ctx, c, outer)) continue;
        }
        const arg = subst.lookup(c.param).?;
        if (sema.containsPoison(ctx, arg)) continue;
        // A call in code this instance does not compile (`sema.liveAt`).
        if (!try sema.liveAt(ctx, c.module_id, c.pos, subst.params, subst.args)) continue;
        if (!try checkMethodCall(ctx, c, subst, arg, at, of)) return false;
    }
    return true;
}

/// Whether the types of call `c` name a parameter `outer` leaves open.
pub fn namesOwn(ctx: *SemContext, c: sema.GenericMethodCall, outer: TypeSubst) Error!bool {
    for (c.args) |t| if (sema.containsTypeVar(ctx, try sema.substituteType(ctx, t, outer))) return true;
    return switch (c.result) {
        .ty => |t| sema.containsTypeVar(ctx, try sema.substituteType(ctx, t, outer)),
        .nothing, .dropped => false,
    };
}

/// Call `c` at an instance whose type for its parameter is `arg`. True
/// when the instance meets it, or when the instance leaves a type of it
/// open.
pub fn checkMethodCall(ctx: *SemContext, c: sema.GenericMethodCall, subst: TypeSubst, arg: TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    const a = ctx.arena.allocator();
    const args = try a.alloc(TypeId, c.args.len);
    for (c.args, args) |t, *out| out.* = try sema.substituteType(ctx, t, subst);
    const result: ?TypeId = switch (c.result) {
        .ty => |t| try sema.substituteType(ctx, t, subst),
        .nothing, .dropped => null,
    };
    if (sema.containsTypeVar(ctx, arg)) return true;
    for (args) |t| if (sema.containsTypeVar(ctx, t)) return true;
    if (result) |t| if (sema.containsTypeVar(ctx, t)) return true;
    for (args) |t| if (sema.containsPoison(ctx, t)) return true;
    if (result) |t| if (sema.containsPoison(ctx, t)) return true;

    const inst = try sema.rootName(ctx, of);
    const pname = ctx.symbols.items[c.param].name;
    const aname = try sema.formatType(ctx, arg);
    const cannot = "`{s}` cannot use `{s} = {s}`: the generic body ";
    const viewed = ctx.types.get(arg) == .read_view;
    const base = if (viewed) ctx.types.get(arg).read_view else arg;
    const bname = try sema.formatType(ctx, base);
    const verb: []const u8 = switch (c.self_mode) {
        .write => "writes",
        .value => "consumes",
        .read, .none => "reads",
    };
    if (try reportApiUnbound(ctx, c, base, at, of)) return false;
    // An API object's methods are reached through its table, which only
    // a call on a value whose type is written as the object makes.
    if (sema.mentionsObject(ctx, base)) {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and an API object's methods are called only where its type is written", .{ inst, pname, aname, c.method, pname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    if (!declaredType(ctx, base)) {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and a call on a `{s}` reaches only the methods of an `obj` or an `enum` a module declares, not those of `{s}`", .{ inst, pname, aname, c.method, pname, pname, bname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    if (viewed and c.self_mode != .read) {
        try ctx.err(at, cannot ++ "calls `{s}`, which {s} `{s}`, and `{s}` is a read view, through which nothing is written or consumed", .{ inst, pname, aname, c.call, verb, c.recv, aname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    const m = (try sema.typeMethod(ctx, base, c.method)) orelse {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and `{s}` has no method `{s}`", .{ inst, pname, aname, c.method, pname, bname, c.method });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    };
    const owner = try a.print("{s}.{s}", .{ bname, c.method });
    const why: ?[]const u8 = blk: {
        const declared = m.module orelse if (sema.isProxy(m.owner)) m.owner.from.module_id else ctx.module_id;
        const body = if (c.module_id == 0) ctx.module_id else c.module_id;
        if (!m.field.is_pub and declared != body) {
            const mname = if (declared == ctx.module_id) ctx.name else if (ctx.foreign_semas.get(declared)) |f| f.name else "?";
            break :blk try a.print("and `{s}` is private to module `{s}`; declare it `pub` there", .{ owner, mname });
        }
        if (m.field.self_mode == .none) break :blk try a.print("and `{s}` takes no `self`", .{owner});
        // A method with options takes them by name, which a generic
        // body's call, by position only, never gives: refused as a
        // function value is (`optionsValue`).
        if (m.field.has_groups) break :blk try a.print("and `{s}` has options, given by name, which a call in a generic body cannot give; call it where its type is written, or pass a closure that does", .{owner});
        if (m.field.param_defaults) |d| for (d) |x| {
            if (x != null) break :blk try a.print("and `{s}` has options, given by name, which a call in a generic body cannot give; call it where its type is written, or pass a closure that does", .{owner});
        };
        if (m.field.self_mode != c.self_mode) break :blk try a.print("which {s} `{s}`, but `{s}` takes `self` as `{s}`", .{ verb, c.recv, owner, switch (m.field.self_mode) {
            .read => "?@",
            .write => "!@",
            .value => "<@",
            .none => "",
        } });
        if (m.field.inline_marked) break :blk try a.print("and `{s}` is marked `inline`, and a call on a `{s}` is not inlined", .{ owner, pname });
        // A view kept in a `T` the body holds by value is a loan the body
        // does not track, which a move of the value could carry out of
        // the function; through a write view, the function's own `keeps`
        // says what may be stored.
        if (c.owned_recv and m.field.origins.stores & m.field.origins.viewed != 0) break :blk try a.print("and `{s}` keeps a view of an argument in `{s}`, a `{s}` the body holds, whose views it does not track", .{ owner, c.recv, pname });
        // Its result may view `x` itself, a `T` the body holds, or an
        // argument: held as a value of a type parameter's type, which can
        // hold a view at this instance, the view is one no loan tracks.
        if (c.owned_recv and c.result == .ty and sema.containsTypeVar(ctx, c.result.ty) and m.field.origins.result & m.field.origins.viewed != 0 and sema.mayHoldView(ctx, result.?))
            break :blk try a.print("and `{s}` gives a view of `{s}` or an argument, which the body holds as a `{s}`, whose views it does not track", .{ owner, c.recv, try sema.formatType(ctx, c.result.ty) });
        if (m.field.owner_bounds.len > 0) break :blk try a.print("and `{s}` is declared under a bound on its type's parameters, which a call on a `{s}` with no bound does not state", .{ owner, pname });
        if (sema.isGenericFn(ctx, m.fn_ty)) break :blk try a.print("and `{s}` takes compile-time parameters of its own, which a call on a `{s}` does not give", .{ owner, pname });
        const params = m.fn_ty.params[1..];
        if (params.len != args.len) break :blk try a.print("with {d} argument{s}, and `{s}` takes {d}", .{ args.len, if (args.len == 1) "" else "s", owner, params.len });
        for (args, params, 1..) |got, want, n| if (got != want)
            break :blk try a.print("passing argument {d} as `{s}`, and `{s}` takes `{s}` there", .{ n, try sema.formatType(ctx, got), owner, try sema.formatType(ctx, want) });
        const gives = m.fn_ty.returns;
        switch (c.result) {
            .ty => if (result.? != gives) break :blk try a.print("taking its result as `{s}`, and `{s}` gives `{s}`", .{ try sema.formatType(ctx, result.?), owner, try sema.formatType(ctx, gives) }),
            .nothing => if (ctx.types.get(gives) != .void) break :blk try a.print("as a statement, and `{s}` gives `{s}`; discard it with `_ = {s}`", .{ owner, try sema.formatType(ctx, gives), c.call }),
            .dropped => if (ctx.types.get(gives) == .fallible) break :blk try a.print("under `_ =`, and `{s}` gives `{s}`, whose failure `_ =` would not handle", .{ owner, try sema.formatType(ctx, gives) }),
        }
        break :blk null;
    };
    const reason = why orelse return true;
    try ctx.err(at, cannot ++ "calls `{s}`, {s}", .{ inst, pname, aname, c.call, reason });
    try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
    return false;
}

/// A call `x.area()` on a `T` with no bound, where the instance's type
/// has no method `area` of its own but provides an API the module sees
/// that declares it (a default, or an addition's method): only a bound
/// reaches it, so the error says to write one. False when that is not so.
pub fn reportApiUnbound(ctx: *SemContext, c: sema.GenericMethodCall, base: TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    if (try sema.typeMethod(ctx, base, c.method) != null) return false;
    const a = ctx.arena.allocator();
    var refs: std.ArrayList(sema.ApiRef) = .empty;
    for (ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and !sema.isProxy(sym)) try refs.append(a, .{ .module_id = ctx.module_id, .sym = @intCast(i) });
    }
    for (ctx.imports) |imp| for (imp.sema.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and sym.flags.is_public and !sema.isProxy(sym)) try refs.append(a, .{ .module_id = imp.module_id, .sym = @intCast(i) });
    };
    const api: sema.ApiRef = for (refs.items) |r| {
        const sym = sema.apiSymbol(ctx, r) orelse continue;
        const declares = for (sym.fields orelse &.{}) |f| {
            if (f.is_method and std.mem.eql(u8, f.name, c.method)) break true;
        } else false;
        if (declares and try sema.provides(ctx, base, r) != null) break r;
    } else return false;
    const pname = ctx.symbols.items[c.param].name;
    const generic: []const u8 = switch (of) {
        .func => |f| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.print(a, "{s}[", .{f.name});
            for (f.ownParams(), 0..) |p, i| try out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", ctx.symbols.items[p].name });
            try out.append(a, ']');
            break :blk out.items;
        },
        .type => |t| try sema.formatType(ctx, if (ctx.types.get(t) == .parameterized_nominal) (try sema.makeNominalContext(ctx, ctx.types.get(t).parameterized_nominal.sym)).self_type else t),
    };
    try ctx.err(at, "`{s}` has no method `{s}`: `{s}` gives `{s}` no bound; write `[{s}: {s}]`, which declares `{s}`", .{ pname, c.method, generic, pname, pname, try sema.apiName(ctx, api), c.method });
    try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
    return true;
}

/// The value a box, a counted handle, or a frozen value's handle of type
/// `ty` reaches, through each in turn; `ty` itself for any other type.
pub fn reachedValue(ctx: *const SemContext, ty: TypeId) TypeId {
    var a = ty;
    while (true) {
        if (sema.boxedType(ctx, a)) |inner| {
            a = inner;
        } else switch (ctx.types.get(a)) {
            .shared => |inner| a = sema.frozenValue(ctx, inner) orelse inner,
            else => return a,
        }
    }
}

/// Whether the bounds of `sym` give what `req` needs, `api`: the API
/// itself, or for the comparison operators `Num`, since every number
/// orders by `<`, a float as IEEE 754 says (a NaN beside anything false).
pub fn boundsGive(ctx: *SemContext, sym: sema.Symbol, req: Requirement, api: sema.Api) bool {
    const apis = sema.boundApis(ctx, sym);
    return apis.contains(api) or (req == .ordered and apis.contains(.Num));
}

/// Whether `api` says how a value is copied, kept, or crosses to
/// another task: a fact of a type's parts that every method of a generic
/// type shares, never one a method's own bounds add.
pub fn ownershipApi(api: sema.Api) bool {
    return switch (api) {
        .Copy, .Clone, .Owned, .Sends, .Syncs => true,
        else => false,
    };
}

/// The API that gives a body requirement `req` on a type parameter
/// (docs/design/apis.md, "What a bound changes in a body"), or null for
/// one each instance still decides with any bounds: a literal's fit, a
/// shift's width, a size, a name.
pub fn apiOf(req: Requirement) ?sema.Api {
    return switch (req) {
        .numeric, .bytes => .Num,
        .integer, .whole_division => .Integer,
        .records => null,
        .signed => .Signed,
        .ordered, .order => .Ord,
        .equatable => .Eq,
        .hashable => .Hash,
        .copies, .no_cleanup => .Copy,
        .clones => .Clone,
        .printable => .Print,
        .meets => |api| api,
        .float, .fits, .shift, .array_len, .lane_count, .slot_count, .sized, .not_error, .error_set, .not_function, .named, .frozen, .no_task, .task => null,
    };
}

/// A type parameter checked by its bounds (`sema.checkedByBounds`) that a
/// generic function's body gives, through the generic functions it calls
/// at it (`SemContext.param_calls`), to a task that may run on another
/// core must state `Sends`, or `Syncs` given as a read view, and one it
/// gives to a body that prints it must state `Print`, as a body doing so
/// itself must: each instance is not checked for it, and an error at a
/// callee's instance would name what the public generic does not show. What
/// a callee's parameter needs, the caller's parameters its argument holds
/// need, where the callee's own walk looks: `sema.taskParams` for a task,
/// `sema.printedTypeVars` for printing. A generic type's printing passes
/// the same way to the parameters of each instance a body names
/// (`SemContext.generic_uses`), as every instance is checked for it.
pub fn checkStatedForwards(ctx: *SemContext) Error!void {
    const a = ctx.arena.allocator();
    const Need = union(enum) { task: sema.TaskReach, print };
    const Gone = struct { param: SymbolId, need: Need, pos: u32 };
    var gone: std.ArrayList(Gone) = .empty;
    for (ctx.generic_requirements.items) |r| {
        if (r.body != sema.no_body) continue;
        switch (r.req) {
            .task => |reach| try gone.append(a, .{ .param = r.param, .need = .{ .task = reach }, .pos = r.pos }),
            // A parameter checked by its bounds answers for its own
            // printing (`checkBoundedBodies`), and its callers through
            // them at each call.
            .printable => if (!sema.checkedByBounds(ctx.symbols.items[r.param])) try gone.append(a, .{ .param = r.param, .need = .print, .pos = r.pos }),
            else => {},
        }
    }
    if (gone.items.len == 0) return;
    // What each callee's parameter needs, its caller's parameters need
    // through the arguments, until nothing new.
    var tasks: std.ArrayList(sema.TaskParam) = .empty;
    defer tasks.deinit(ctx.allocator);
    var printed: std.ArrayList(SymbolId) = .empty;
    defer printed.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < gone.items.len) : (i += 1) {
        const g = gone.items[i];
        for (ctx.param_calls.items) |c| for (c.params, c.args) |p, arg| {
            if (p != g.param) continue;
            switch (g.need) {
                // A task in a method of a generic type is checked where
                // the program reaches the method (`sema.BodyReach`).
                .task => |reach| if (c.body == sema.no_body) {
                    tasks.clearRetainingCapacity();
                    try sema.taskParams(ctx, arg, reach, &tasks);
                    for (tasks.items) |f| try addNeed(Gone, a, &gone, .{ .param = f.param, .need = .{ .task = f.reach }, .pos = c.pos });
                },
                .print => try printedNeeds(Gone, ctx, a, &gone, arg, c.pos, &printed),
            }
        };
        // A type's printing is its every instance's (`checkGenericInstantiations`):
        // the parameters of what a body names it at, `Box(v: x)` in `f[T]`.
        if (g.need == .print) for (ctx.generic_uses.items, ctx.generic_uses_at.items) |use, at| {
            const pn = switch (ctx.types.get(use)) {
                .parameterized_nominal => |pn| pn,
                else => continue,
            };
            const params = ctx.symbols.items[pn.sym].type_params orelse continue;
            for (params, pn.args) |p, arg| if (p == g.param) try printedNeeds(Gone, ctx, a, &gone, arg, at, &printed);
        };
    }
    var reported: std.AutoHashMapUnmanaged(struct { SymbolId, sema.Api }, void) = .empty;
    defer reported.deinit(ctx.allocator);
    for (gone.items) |g| {
        const sym = ctx.symbols.items[g.param];
        if (sema.isProxy(sym) or !sema.checkedByBounds(sym)) continue;
        const api: sema.Api, const what: []const u8 = switch (g.need) {
            .task => |reach| if (reach.local) continue else if (reach.how == .moves)
                .{ .Sends, "a value given to a task that may run on another core" }
            else
                .{ .Syncs, "a value passed as a view to a task that may run on another core" },
            .print => .{ .Print, "printing" },
        };
        if (sema.boundApis(ctx, sym).contains(api)) continue;
        if ((try reported.getOrPut(ctx.allocator, .{ g.param, api })).found_existing) continue;
        try reportUnbounded(ctx, g.pos, g.param, api, what);
    }
}

/// Adds to `gone` (`checkStatedForwards`) the need to print each type
/// parameter a printed `arg` holds, given at `pos`.
pub fn printedNeeds(comptime Gone: type, ctx: *SemContext, a: std.mem.Allocator, gone: *std.ArrayList(Gone), arg: TypeId, pos: u32, printed: *std.ArrayList(SymbolId)) Error!void {
    printed.clearRetainingCapacity();
    try sema.printedTypeVars(ctx, arg, printed, ctx.allocator);
    for (printed.items) |param| try addNeed(Gone, a, gone, .{ .param = param, .need = .print, .pos = pos });
}

/// Adds `need` to `gone` (`checkStatedForwards`) unless it is there.
pub fn addNeed(comptime Gone: type, a: std.mem.Allocator, gone: *std.ArrayList(Gone), need: Gone) Error!void {
    for (gone.items) |o| if (o.param == need.param and std.meta.eql(o.need, need.need)) return;
    try gone.append(a, need);
}

/// A type parameter with bounds is checked against its bounds alone: what
/// this module's bodies do with one must be what its bounds name. A
/// parameter with no bound keeps per-instance checking.
pub fn checkBoundedBodies(ctx: *SemContext) Error!void {
    const a = ctx.arena.allocator();
    for (ctx.generic_requirements.items) |r| {
        if (r.module_id != 0) continue;
        const sym = ctx.symbols.items[r.param];
        if (!sema.checkedByBounds(sym)) continue;
        const api = apiOf(r.req) orelse continue;
        if (boundsGive(ctx, sym, r.req, api)) continue;
        // Where `$plain(T)` has held, a `T` copies and holds no loan.
        if (sema.plainApis().contains(api) and sema.narrowedAt(ctx, 0, r.pos, r.param)) continue;
        if (try sema.reportStated(ctx, r.pos, r.param, api, r.op)) continue;
        try reportUnbounded(ctx, r.pos, r.param, api, try a.print("{s}", .{r.req.describe()}));
    }
}

/// A body at `pos` does with a `T` (`param`, which has bounds or is one
/// of a `pub` declaration's) what `api` gives (`what`), and its bounds do
/// not name it.
pub fn reportUnbounded(ctx: *SemContext, pos: u32, param: SymbolId, api: sema.Api, what: []const u8) Error!void {
    if (try sema.reportStated(ctx, pos, param, api, "")) return;
    const a = ctx.arena.allocator();
    const sym = ctx.symbols.items[param];
    try ctx.err(pos, "{s}", .{try sema.unboundedMessage(ctx, a, sym, api, what)});
}

/// The APIs this module's types name on their headers. A type that
/// declares the method of an API it names (`sema.apiMethodName`) gives
/// that API its own meaning, by that method, whose signature the API
/// fixes (`checkApiMethod`). A type that names `Ord` with no `order` of its
/// own is ordered by its fields in declared order, and an enum by its
/// variant, then its payload's fields: each must provide `Ord`. A field of
/// a type parameter's type is decided by each instance (`sema.lacks`).
pub fn checkHeaders(ctx: *SemContext) Error!void {
    for (ctx.symbols.items) |sym| {
        if (sym.kind != .nominal_type and sym.kind != .generic_type) continue;
        if (sema.isProxy(sym) or sym.decl_pos == sema.builtin_decl_pos) continue;
        try checkLookAlikes(ctx, sym);
        if (sym.apis.count() == 0) continue;
        var it = sym.apis.iterator();
        while (it.next()) |api| if (sema.ownApiMethod(sym, api)) |m| try checkApiMethod(ctx, sym, api, m);
        if (!sym.apis.contains(.Ord) or sema.ownApiMethod(sym, .Ord) != null) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method) continue;
            const parts: []const Field = if (f.is_variant) f.payload orelse &.{} else &.{f};
            for (parts) |part| {
                const lack = (try sema.lacks(ctx, part.ty, .Ord)) orelse continue;
                const shown = if (f.is_variant) try ctx.arena.allocator().print("{s}.{s}", .{ f.name, part.name }) else part.name;
                try ctx.err(sym.decl_pos, "`{s}` names `Ord`, so it is ordered by its fields, but its field `{s}` is a `{s}`, which {s}{s}", .{ sym.name, shown, try sema.formatType(ctx, part.ty), sema.cannotDo(.Ord), try sema.lackDetail(ctx, ctx.arena.allocator(), part.ty, .Ord, lack) });
                break;
            }
        }
    }
}

/// Where field `f`, declared `pub ?name`, may be written, as an error
/// says it: in its module, or, for a built-in type written in Rig, in the
/// type's own methods. `declares` adds what declares it so.
pub fn readOnlyWhere(ctx: *SemContext, f: sema.ReadOnlyField, declares: bool) Error![]const u8 {
    const a = ctx.arena.allocator();
    if (std.mem.eql(u8, f.module, "std." ++ rig.builtin_module_name)) return a.print("outside the methods of `{s}`", .{f.owner});
    if (declares) return a.print("outside module `{s}`, which declares it `pub ?{s}`", .{ f.module, f.field });
    return a.print("outside module `{s}`", .{f.module});
}

/// The signature `api` fixes for the method by which a type gives it its
/// own meaning, as an error shows it.
pub fn fixedSignature(api: sema.Api) []const u8 {
    return switch (api) {
        .Eq => "fun eq(?@, other: ?Self) -> Bool",
        .Hash => "sub hash_into(?@, h: !Hasher)",
        .Ord => "fun order(?@, other: ?Self) -> Order",
        .Print => "sub print(?@, out: !Printer)",
        else => "",
    };
}

/// Whether `ty` is a write view of the built-in `Hasher`.
pub fn isHasherView(ctx: *SemContext, ty: TypeId) Error!bool {
    return ty == try ctx.intern(.{ .write_view = try ctx.intern(.{ .nominal = ctx.hasher_sym_id }) });
}

/// The method `m` of `sym`, by which it gives `api` its own meaning, has
/// the signature `api` fixes: another signature is an error, not a quiet
/// opt-out (docs/design/apis.md, Stage 2).
pub fn checkApiMethod(ctx: *SemContext, sym: sema.Symbol, api: sema.Api, m: Field) Error!void {
    const why = (try apiMethodMismatch(ctx, api, m)) orelse return;
    if (why.len == 0) return;
    const owner = try ctx.arena.allocator().print("{s}.{s}", .{ sym.name, m.name });
    try ctx.err(m.decl_pos, "`{s}` {s}, but `{s}` fixes `{s}`", .{ owner, why, @tagName(api), fixedSignature(api) });
}

/// A method of `sym` with the very signature a built-in API fixes,
/// `fun eq(?@, other: ?Self) -> Bool` and the others, on a type whose
/// header does not name that API: `==`, hashing, ordering, or printing
/// would quietly pass it by. A method under the name with another
/// signature is an ordinary method.
pub fn checkLookAlikes(ctx: *SemContext, sym: sema.Symbol) Error!void {
    if (sym.flags.error_set) return;
    for ([_]sema.Api{ .Eq, .Hash, .Ord, .Print }) |api| {
        if (sym.apis.contains(api)) continue;
        const name = sema.apiMethodName(api).?;
        for (sym.fields orelse &.{}) |m| {
            if (!m.is_method or m.is_drop_method or !std.mem.eql(u8, m.name, name)) continue;
            if ((try apiMethodMismatch(ctx, api, m)) != null) continue;
            const a = ctx.arena.allocator();
            const is_enum = for (sym.fields orelse &.{}) |f| {
                if (f.is_variant) break true;
            } else false;
            const params: []const u8 = if (sym.kind == .generic_type) try a.print("[{s}]", .{tparamNames(ctx, sym)}) else "";
            const uses: []const u8 = switch (api) {
                .Eq => "`==`",
                .Hash => "hashing",
                .Ord => "`<`",
                .Print => "`print`",
                else => unreachable,
            };
            try ctx.err(m.decl_pos, "`{s}.{s}` has the signature `{s}` fixes, but `{s}` does not name `{s}`, so {s} does not use it: name it on the header, `{s} {s}{s}: {s}`, or rename the method", .{ sym.name, m.name, @tagName(api), sym.name, @tagName(api), uses, if (is_enum) "enum" else "obj", sym.name, params, try sema.formatBounds(ctx, a, sym, api) });
        }
    }
}

/// How method `m` differs from the signature `api` fixes for it, as an
/// error says it; empty for no function, null for the very signature.
pub fn apiMethodMismatch(ctx: *SemContext, api: sema.Api, m: Field) Error!?[]const u8 {
    const a = ctx.arena.allocator();
    const f = switch (ctx.types.get(m.ty)) {
        .function => |f| f,
        else => return "",
    };
    if (f.params.len == 0) return "";
    const self_view = f.params[0];
    const names = m.param_names orelse &.{};
    const what: ?[]const u8 = blk: {
        if (m.self_mode != .read) break :blk try a.print("takes `self` as `{s}`", .{switch (m.self_mode) {
            .write => "!@",
            .value => "<@",
            .none => "nothing",
            .read => "?@",
        }});
        if (f.ct_params.len > 0) break :blk "takes compile-time parameters";
        if (m.owner_bounds.len > 0) break :blk "is declared under a bound on its type's parameters, which the header does not state";
        if (f.params.len != 2) break :blk try a.print("takes {d} parameter{s}", .{ f.params.len - 1, if (f.params.len == 2) "" else "s" });
        const p = f.params[1];
        const ok = switch (api) {
            .Eq, .Ord => p == self_view,
            .Hash => try isHasherView(ctx, p),
            .Print => p == try ctx.intern(.{ .write_view = try ctx.intern(.{ .nominal = ctx.printer_sym_id }) }),
            else => true,
        };
        if (!ok) break :blk try a.print("takes `{s}` as `{s}`", .{ if (names.len > 1) names[1] else "?", try sema.formatType(ctx, p) });
        const want: TypeId = switch (api) {
            .Eq => ctx.types.bool_id,
            .Ord => try ctx.intern(.{ .nominal = ctx.order_sym_id }),
            else => ctx.types.void_id,
        };
        if (f.returns != want) break :blk if (f.returns == ctx.types.void_id) "gives nothing" else try a.print("gives `{s}`", .{try sema.formatType(ctx, f.returns)});
        break :blk null;
    };
    return what;
}

// =============================================================================
// APIs of a program's own (docs/design/apis.md, Stage 3)
// =============================================================================

/// This module's APIs, and each conformance it writes: a header that
/// names an API, or an addition. An API builds on others without a
/// cycle and takes their methods as they are; each of its methods says
/// what its result views. A conformance provides every method its API
/// and those it builds on declare, each matching its declaration
/// exactly but for `from` and `keeps`, which may be narrower; meets the
/// built-in APIs they build on; and is the only one of its type and API
/// in the program, written in the type's module or the API's.
pub fn checkApis(ctx: *SemContext) Error!void {
    for (ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and !sema.isProxy(sym)) try checkApiDecl(ctx, @intCast(i));
    }
    for (ctx.conformances.items, 0..) |_, i| try checkConformance(ctx, i);
}

pub fn checkApiDecl(ctx: *SemContext, id: SymbolId) Error!void {
    const a = ctx.arena.allocator();
    const sym = ctx.symbols.items[id];
    const self_ref: sema.ApiRef = .{ .module_id = ctx.module_id, .sym = id };
    for (sym.user_apis) |s| {
        const closure = try sema.apiClosure(ctx, a, s);
        for (closure) |c| if (c.eql(self_ref)) {
            try ctx.err(sym.decl_pos, "`{s}` builds on itself, through `{s}`: an API builds on others without a cycle", .{ sym.name, try sema.apiName(ctx, s) });
            return;
        };
    }
    try recordObjectTable(ctx, id);
    const own = sym.fields orelse &.{};
    // Each associated type is what a provider's methods give where the
    // API's required methods name it (`sema.inferAssoc`), so one names it.
    const params = sym.type_params orelse &.{};
    if (params.len > 1) for (params[1..]) |p| {
        const named = for (own) |m| {
            if (m.is_method and !m.is_default and sema.usesParams(ctx, m.ty, &.{p})) break true;
        } else false;
        if (!named) try ctx.err(ctx.symbols.items[p].decl_pos, "`{s}` declares `type {s}`, which none of its required methods names: a provider's `{s}` is what its methods give in their place", .{ sym.name, ctx.symbols.items[p].name, ctx.symbols.items[p].name });
    };
    for (own) |m| {
        // An API takes the methods of those it builds on as they are.
        supers: for (sym.user_apis) |s| for (try sema.apiClosure(ctx, a, s)) |c| {
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            for (csym.fields orelse &.{}) |f| if (std.mem.eql(u8, f.name, m.name)) {
                try ctx.err(m.decl_pos, "`{s}` builds on `{s}`, which declares `{s}`: an API takes the methods of those it builds on as they are, and declares none of them again", .{ sym.name, try sema.apiName(ctx, c), m.name });
                break :supers;
            };
        };
        // A call through the API passes every argument: an implementation
        // has no default to fill, and one of the API's would be a second.
        if (m.has_groups) for (ctx.group_params.get(m.decl_pos) orelse &.{}) |g| if (g) |x| {
            try ctx.err(m.decl_pos, "`{s}.{s}` takes the group `{s}`, and an API's method takes none: a call through the API passes each argument", .{ sym.name, m.name, x.group });
            break;
        };
        for (m.param_defaults orelse &.{}, 0..) |d, i| if (d != null) {
            const pname = if (m.param_names) |ns| (if (i < ns.len) ns[i] else "?") else "?";
            try ctx.err(m.decl_pos, "`{s}.{s}` gives `{s}` a default, and an API's method takes none: a call through the API passes each argument", .{ sym.name, m.name, pname });
            break;
        };
        const f = switch (ctx.types.get(m.ty)) {
            .function => |f| f,
            else => continue,
        };
        if (m.origins.declared or sema.containsPoison(ctx, f.returns)) continue;
        var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
        defer scratch.deinit();
        if ((try sema.viewTargets(ctx, scratch.allocator(), f.returns)).isEmpty()) continue;
        const ret = try sema.formatType(ctx, f.returns);
        try ctx.err(m.decl_pos, "`{s}.{s}` gives `{s}`, which may view what it is passed, and an API's method says what with `from`: `-> {s} from @`", .{ sym.name, m.name, ret, ret });
    }
}

/// The entries of the table of API `id` (`sema.TableEntry`): each method
/// a call through an object of it reaches, its type brought into this
/// module, where emit writes the table (docs/design/apis.md, Stage 4).
pub fn recordObjectTable(ctx: *SemContext, id: SymbolId) Error!void {
    const a = ctx.arena.allocator();
    const ref: sema.ApiRef = .{ .module_id = ctx.module_id, .sym = id };
    var entries: std.ArrayList(sema.TableEntry) = .empty;
    for (try sema.objectMethods(ctx, a, ref)) |m| {
        const slot = m.slot orelse continue;
        const home = sema.apiContext(ctx, m.api) orelse continue;
        const fn_ty = if (home == @as(*const SemContext, ctx)) m.field.ty else try sema.importType(ctx, home, m.field.ty, m.api.module_id);
        if (ctx.types.get(fn_ty) != .function or sema.containsPoison(ctx, fn_ty)) continue;
        // An associated type an entry names is the object's, built with
        // the braces that name it (open question 7).
        const f = ctx.types.get(fn_ty).function;
        const named_param = for (f.params[@min(1, f.params.len)..]) |p| {
            if (sema.containsTypeVar(ctx, p)) break true;
        } else false;
        if (named_param or sema.containsTypeVar(ctx, f.returns)) continue;
        try entries.append(a, .{ .name = m.field.name, .slot = slot, .self_mode = m.field.self_mode, .fn_ty = fn_ty, .result_out = try sema.resultOut(ctx, f.returns) });
    }
    try ctx.object_tables.put(ctx.allocator, id, entries.items);
}

/// An API method a conformance must provide: its field, and the API of
/// the closure that declares it.
pub const ApiMethod = struct { api: sema.ApiRef, home: *const SemContext, field: Field };

pub fn checkConformance(ctx: *SemContext, index: usize) Error!void {
    const a = ctx.arena.allocator();
    const conf = ctx.conformances.items[index];
    const api_sym = sema.apiSymbol(ctx, conf.api) orelse return;
    const api_name = try sema.apiName(ctx, conf.api);
    if (sema.containsPoison(ctx, conf.ty)) return;
    // The type's own symbol, for a type a module declares.
    const decl = sema.nominalDecl(ctx, conf.ty);
    const tname: []const u8 = if (conf.kind == .header) ctx.symbols.items[decl.?.sym].name else try sema.formatType(ctx, conf.ty);
    if (conf.kind == .add and !try checkAddHome(ctx, conf, tname, api_name)) return;
    // Once in the program: a type and an API take one conformance.
    for (ctx.conformances.items[0..index]) |other| {
        if (!try sameProvider(ctx, conf.ty, other.ty)) continue;
        const overlap = if (conf.kind == .header and other.kind == .header) other.api.eql(conf.api) else try buildsOn(ctx, conf.api, other.api) or try buildsOn(ctx, other.api, conf.api);
        if (!overlap) continue;
        try ctx.err(conf.pos, "`{s}` provides `{s}` twice: a type provides an API once in the whole program", .{ tname, api_name });
        try ctx.note(other.pos, "`{s}` provides `{s}` here", .{ tname, try sema.apiName(ctx, other.api) });
        return;
    }
    // The built-in APIs it builds on, which the type's parts give.
    const closure = try sema.apiClosure(ctx, a, conf.api);
    for (closure) |c| {
        const csym = sema.apiSymbol(ctx, c) orelse continue;
        var it = csym.apis.iterator();
        while (it.next()) |b| {
            const lack = (try sema.lacks(ctx, conf.ty, b)) orelse continue;
            // An iterator is one by its `next`, not by its fields.
            const by_field = if (b == .Iter) null else try fieldLacking(ctx, decl, b);
            const detail = by_field orelse try sema.lackDetail(ctx, a, conf.ty, b, lack);
            const shown = if (std.mem.startsWith(u8, detail, "; ")) try a.print(": {s}", .{detail[2..]}) else detail;
            try ctx.err(conf.pos, "`{s}` provides `{s}`, which builds on `{s}`, but `{s}` {s}{s}", .{ tname, api_name, @tagName(b), tname, sema.cannotDo(b), shown });
            return;
        }
    }
    // Every method of the API and those it builds on.
    var wanted: std.ArrayList(ApiMethod) = .empty;
    for (closure) |c| {
        const home = sema.apiContext(ctx, c) orelse continue;
        const csym = sema.apiSymbol(ctx, c) orelse continue;
        for (csym.fields orelse &.{}) |f| try wanted.append(a, .{ .api = c, .home = home, .field = f });
    }
    const provider = providerMethods(conf, decl);
    // An addition's methods are its APIs', and none its type has already.
    if (conf.kind == .add) for (conf.methods) |m| {
        const declared = for (wanted.items) |w| {
            if (std.mem.eql(u8, w.field.name, m.name)) break true;
        } else false;
        if (!declared and !try anotherApiDeclares(ctx, conf, m.name)) try ctx.err(m.decl_pos, "`add {s}: {s}` declares `{s}`, which `{s}` does not: an addition's methods are its API's", .{ tname, api_name, m.name, api_name });
        const has = if (decl) |d| typeHasMethod(d.symbol(), m.name) else false;
        if (declared and (has or builtinMember(ctx, conf.ty, m.name))) {
            try ctx.err(m.decl_pos, "`add {s}: {s}` declares `{s}`, which `{s}` has already: an addition neither adopts nor replaces a method of its type", .{ tname, api_name, m.name, tname });
        }
    };
    var members: std.ArrayList(sema.WitnessMember) = .empty;
    defer ctx.conformances.items[index].members = members.items;
    for (wanted.items, 0..) |w, wi| {
        // Each name once, by the first API that declares it.
        const first = for (wanted.items[0..wi]) |e| {
            if (std.mem.eql(u8, e.field.name, w.field.name)) break false;
        } else true;
        if (!first) continue;
        const have = findMethod(provider, w.field.name) orelse {
            if (w.field.is_default) {
                try members.append(a, .{ .name = w.field.name, .from = .{ .default = w.api } });
                // Two defaults for one name, until the type writes it: from
                // the APIs this one builds on, or another API the type
                // provides.
                const other: ?sema.ApiRef = for (wanted.items[wi + 1 ..]) |e| {
                    if (std.mem.eql(u8, e.field.name, w.field.name) and e.field.is_default and !e.api.eql(w.api)) break e.api;
                } else try laterDefault(ctx, index, w.field.name, w.api);
                if (other) |o| try ctx.err(conf.pos, "`{s}` provides `{s}` and `{s}`, which both give `{s}` a default: declare `{s}` in `{s}` to choose", .{ tname, try sema.apiName(ctx, w.api), try sema.apiName(ctx, o), w.field.name, w.field.name, tname });
                continue;
            }
            try ctx.err(conf.pos, "`{s}` provides `{s}` but has no method `{s}`; declare `{s}` in `{s}`", .{ tname, api_name, w.field.name, headerText(w.home.source, w.field.decl_pos), if (conf.kind == .add) try a.print("add {s}: {s}", .{ tname, api_name }) else tname });
            continue;
        };
        try members.append(a, .{ .name = w.field.name, .from = if (conf.kind == .add) .added else .own });
        // A method under bounds the header does not state meets no API on
        // it: only an addition under those bounds gives the API.
        if (conf.kind == .header and have.owner_bounds.len > 0) {
            const tsym = ctx.symbols.items[decl.?.sym];
            const tparams = tsym.type_params orelse &.{};
            var names: std.ArrayList(u8) = .empty;
            for (tparams, 0..) |p, i| try names.print(a, "{s}{s}", .{ if (i > 0) ", " else "", ctx.symbols.items[p].name });
            const under = try sema.ownerBoundsText(ctx, ctx, a, tparams, have.owner_bounds);
            try ctx.err(have.decl_pos, "`{s}.{s}` is declared under `{s}`, which `{s}[{s}]: {s}` does not state: a conformance is met only by methods its own bounds imply; take `{s}` off the header and write `add {s}[{s}]: {s}`, which declares `{s}`", .{ tname, have.name, under, tname, names.items, api_name, api_name, tname, try boundParamsText(ctx, a, tparams, have.owner_bounds), api_name, have.name });
            continue;
        }
        try checkMethodMeets(ctx, conf, tname, w, have);
        // A call through the API gives each argument by position, so a
        // method that meets it has no option (SPEC "Functions"); the API's
        // own method has none either (`checkApiDecl`).
        if (have.has_groups) for (ctx.group_params.get(have.decl_pos) orelse &.{}) |g| if (g) |x| {
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}` of `{s}`, so it takes no group, and it takes `{s}`: a call through the API gives each argument by position", .{ tname, have.name, w.field.name, try sema.apiName(ctx, w.api), x.group });
            break;
        };
        for (have.param_defaults orelse &.{}, 0..) |d, i| if (d != null) {
            const pname = if (have.param_names) |ns| (if (i < ns.len) ns[i] else "?") else "?";
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}` of `{s}`, so `{s}` has no default: a call through the API gives each argument by position", .{ tname, have.name, w.field.name, try sema.apiName(ctx, w.api), pname });
            break;
        };
        // A method that meets a `pub` API on a `pub` type is `pub`.
        if (conf.kind == .header and api_sym.flags.is_public and ctx.symbols.items[decl.?.sym].flags.is_public and !have.is_pub) {
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}`, a `pub` API, on `{s}`, a `pub` type, so it is `pub`: write `pub {s}`", .{ tname, have.name, api_name, tname, headerText(ctx.source, have.decl_pos) });
        }
    }
}

/// A generic type's parameters with the bounds a method adds written in:
/// `T: Print, U`.
pub fn boundParamsText(ctx: *SemContext, a: std.mem.Allocator, tparams: []const SymbolId, bounds: []const sema.OwnerBound) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (tparams, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        const b = for (bounds) |b| {
            if (b.param == i) break b;
        } else null;
        if (b) |one| {
            try out.appendSlice(a, try sema.ownerBoundsText(ctx, ctx, a, tparams, &.{one}));
        } else try out.appendSlice(a, ctx.symbols.items[p].name);
    }
    return out.items;
}

/// An API other than `api` that a later conformance of the same type
/// gives a default method `name`, which the type does not write.
pub fn laterDefault(ctx: *SemContext, index: usize, name: []const u8, api: sema.ApiRef) Error!?sema.ApiRef {
    const conf = ctx.conformances.items[index];
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (ctx.conformances.items[index + 1 ..]) |o| {
        if (!try sameProvider(ctx, conf.ty, o.ty)) continue;
        for (try sema.apiClosure(ctx, scratch.allocator(), o.api)) |c| {
            if (c.eql(api)) continue;
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            const f = findMethod(csym.fields orelse &.{}, name) orelse continue;
            if (f.is_default) return c;
        }
    }
    return null;
}

/// Why a value of `ty`, which holds a task (`sema.holdsTask`), holds
/// one: its first field that does (`taskField`), or "a `T` holds one".
pub fn taskWhy(ctx: *SemContext, ty: TypeId) Error![]const u8 {
    if (taskField(ctx, sema.nominalDecl(ctx, ty))) |f| return f;
    return ctx.arena.allocator().print("a `{s}` holds one", .{try sema.formatType(ctx, ty)});
}

/// The first field or payload of `decl` that holds a task (`sema.holdsTask`),
/// as `its field `t` is a `Task[Int]``; null when none of its own does.
pub fn taskField(ctx: *SemContext, decl: ?sema.NominalDecl) ?[]const u8 {
    const d = decl orelse return null;
    if (d.ctx != @as(*const SemContext, ctx)) return null;
    for (d.symbol().fields orelse &.{}) |*f| {
        for (sema.dataFields(f)) |df| {
            if (!sema.holdsTask(ctx, df.ty)) continue;
            return ctx.arena.allocator().print("its {s} `{s}` is a `{s}`", .{ if (f.is_variant) "payload" else "field", df.name, sema.formatType(ctx, df.ty) catch return null }) catch null;
        }
    }
    return null;
}

/// The first field of the object `decl` whose type lacks `api`, as the
/// end of an error says it: `; its field `cache` is a `*Cell[Int]``.
pub fn fieldLacking(ctx: *SemContext, decl: ?sema.NominalDecl, api: sema.Api) Error!?[]const u8 {
    const d = decl orelse return null;
    if (d.ctx != @as(*const SemContext, ctx)) return null;
    for (d.symbol().fields orelse &.{}) |f| {
        if (f.is_method or f.is_variant) continue;
        if (try sema.lacks(ctx, f.ty, api) == null) continue;
        return try ctx.arena.allocator().print("; its field `{s}` is a `{s}`", .{ f.name, try sema.formatType(ctx, f.ty) });
    }
    return null;
}

/// Whether another API of the addition that writes `conf` (`add Int:
/// Shape + Named`), or one it builds on, declares a method `name`.
pub fn anotherApiDeclares(ctx: *SemContext, conf: sema.Conformance, name: []const u8) Error!bool {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (ctx.conformances.items) |o| {
        if (o.kind != .add or o.pos != conf.pos or o.api.eql(conf.api)) continue;
        for (try sema.apiClosure(ctx, scratch.allocator(), o.api)) |c| {
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            if (findMethod(csym.fields orelse &.{}, name) != null) return true;
        }
    }
    return false;
}

/// The methods a conformance provides its API by: an addition's own, or
/// the type's.
pub fn providerMethods(conf: sema.Conformance, decl: ?sema.NominalDecl) []const Field {
    if (conf.kind == .add) return conf.methods;
    return (decl orelse return &.{}).symbol().fields orelse &.{};
}

pub fn findMethod(fields: []const Field, name: []const u8) ?Field {
    for (fields) |f| if (f.is_method and !f.is_drop_method and std.mem.eql(u8, f.name, name)) return f;
    return null;
}

pub fn typeHasMethod(sym: sema.Symbol, name: []const u8) bool {
    return findMethod(sym.fields orelse &.{}, name) != null;
}

/// Whether built-in type `ty` has a member `name` no declaration holds:
/// the `len` and `is_empty` of text, an array, a slice, or a List, a
/// String's `add`, `push`, `reserve`, and `clear`, a `Symbol`'s `text`.
pub fn builtinMember(ctx: *SemContext, ty: TypeId, name: []const u8) bool {
    const t = ctx.types.get(ty);
    const has_len = switch (t) {
        .array, .slice, .string_view, .static, .string => true,
        .parameterized_nominal => listElementType(ctx, ty) != null or cellListElement(ctx, ty) != null,
        else => false,
    };
    if (has_len and (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "is_empty"))) return true;
    if (t == .string) if (std.meta.stringToEnum(sema.StringCall, name)) |op| switch (op) {
        .add, .push, .reserve, .clear => return true,
        else => {},
    };
    return t == .symbol and std.mem.eql(u8, name, "text");
}

/// Whether API `a` is `b` or builds on it.
pub fn buildsOn(ctx: *SemContext, x: sema.ApiRef, y: sema.ApiRef) Error!bool {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (try sema.apiClosure(ctx, scratch.allocator(), x)) |c| if (c.eql(y)) return true;
    return false;
}

/// Whether `x` and `y`, types of this module's conformances, are one
/// type constructor: one conformance covers both.
pub fn sameProvider(ctx: *SemContext, x: TypeId, y: TypeId) Error!bool {
    if (x == y) return true;
    const gx = genericSym(ctx, x) orelse return false;
    const gy = genericSym(ctx, y) orelse return false;
    return gx == gy;
}

pub fn genericSym(ctx: *const SemContext, ty: TypeId) ?SymbolId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym,
        // Every `Slot[n]` is one type constructor's.
        .slot => ctx.slot_sym_id,
        else => null,
    };
}

/// An addition is written in the module of its API or of its type, and
/// in the type's own module only under a bound (`add Wrap[T: Shape]`);
/// there a header says the rest. False after a diagnostic.
pub fn checkAddHome(ctx: *SemContext, conf: sema.Conformance, tname: []const u8, api_name: []const u8) Error!bool {
    const own_type = switch (ctx.types.get(conf.ty)) {
        .nominal => |s| !sema.isProxy(ctx.symbols.items[s]) and ctx.symbols.items[s].decl_pos != sema.builtin_decl_pos,
        .parameterized_nominal => |pn| !sema.isProxy(ctx.symbols.items[pn.sym]) and ctx.symbols.items[pn.sym].decl_pos != sema.builtin_decl_pos,
        else => false,
    };
    if (own_type) {
        const conditional = for (conf.params) |p| {
            if (sema.hasBounds(ctx.symbols.items[p])) break true;
        } else false;
        if (conditional) return true;
        const decl = sema.nominalDecl(ctx, conf.ty).?.symbol();
        const is_enum = for (decl.fields orelse &.{}) |f| {
            if (f.is_variant) break true;
        } else false;
        const params: []const u8 = if (genericSym(ctx, conf.ty) != null) try ctx.arena.allocator().print("[{s}]", .{tparamNames(ctx, decl)}) else "";
        try ctx.err(conf.pos, "`{s}` is declared in this module, so it names `{s}` on its header: `{s} {s}{s}: {s}`; `add` is for a type of another module, a built-in type, or an API a type provides only under a bound", .{ decl.name, api_name, if (is_enum) "enum" else "obj", decl.name, params, api_name });
        return false;
    }
    if (conf.api.module_id != ctx.module_id) {
        try ctx.err(conf.pos, "`add {s}: {s}` is written in the module that declares `{s}`, or the one that declares `{s}`", .{ tname, api_name, api_name, tname });
        return false;
    }
    // It provides the APIs its API builds on too, each of which it may
    // provide only here as well: elsewhere two modules could each give
    // the type one, neither seeing the other.
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (try sema.apiClosure(ctx, scratch.allocator(), conf.api)) |c| {
        if (c.module_id == ctx.module_id) continue;
        const cname = try sema.apiName(ctx, c);
        try ctx.err(conf.pos, "`add {s}: {s}` gives `{s}` `{s}` too, which `{s}` builds on, outside the module of `{s}` and of `{s}`: a type provides an API once in the whole program, in its own module or the API's", .{ tname, api_name, tname, cname, api_name, cname, tname });
        return false;
    }
    return true;
}

pub fn tparamNames(ctx: *SemContext, sym: sema.Symbol) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = ctx.arena.allocator();
    for (sym.type_params orelse &.{}, 0..) |tp, i| {
        if (i > 0) out.appendSlice(a, ", ") catch return "T";
        out.appendSlice(a, ctx.symbols.items[tp].name) catch return "T";
    }
    return out.items;
}

/// The header of the method whose name is at `pos` in `source`, as
/// written: `fun area(?@) -> Float`, without its comment.
pub fn headerText(source: []const u8, pos: u32) []const u8 {
    const start = (std.mem.findScalarLast(u8, source[0..pos], '\n') orelse 0);
    const end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;
    var line = source[start..end];
    if (std.mem.findScalar(u8, line, '#')) |h| line = line[0..h];
    line = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.startsWith(u8, line, "pub ")) line = line[4..];
    return line;
}

/// The method's name, parameters, and result, as its header writes them:
/// `size(?@) -> Int!Bad`; `with_result` false stops after the
/// parameters, `next(!@)`.
pub fn signatureText(source: []const u8, pos: u32, with_result: bool) []const u8 {
    const header = headerText(source, pos);
    const name_at = @intFromPtr(source.ptr + pos) -| @intFromPtr(header.ptr);
    if (name_at >= header.len) return header;
    const sig = header[name_at..];
    if (!with_result) {
        var depth: usize = 0;
        for (sig, 0..) |c, i| switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -|= 1;
                if (depth == 0) return sig[0 .. i + 1];
            },
            else => {},
        };
        return sig;
    }
    return clauseless(sig);
}

/// `text` without its `from` and `keeps` clauses.
pub fn clauseless(text: []const u8) []const u8 {
    var end = text.len;
    for ([_][]const u8{ " from ", " keeps " }) |w| if (std.mem.find(u8, text, w)) |i| {
        end = @min(end, i);
    };
    return std.mem.trimEnd(u8, text[0..end], " ");
}

/// The result the header of the method at `pos` writes: `-> Int!Bad`.
pub fn resultText(source: []const u8, pos: u32) []const u8 {
    const sig = signatureText(source, pos, true);
    var depth: usize = 0;
    for (sig, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        '-' => if (depth == 0 and i + 1 < sig.len and sig[i + 1] == '>') return sig[i..],
        else => {},
    };
    return "";
}

/// The method `have` meets the API method `w` (of a conformance of
/// `tname`): the same self, parameters and their modes, compile-time
/// parameters, `once`, and result, its failure included; its `from`
/// and `keeps` within the API's, by position.
pub fn checkMethodMeets(ctx: *SemContext, conf: sema.Conformance, tname: []const u8, w: ApiMethod, have: Field) Error!void {
    const a = ctx.arena.allocator();
    const owner = try a.print("{s}.{s}", .{ tname, have.name });
    const aname = try sema.apiName(ctx, w.api);
    const src = w.home.source;
    const pos = w.field.decl_pos;
    const header = headerText(src, pos);
    if (have.self_mode != w.field.self_mode) {
        try ctx.err(have.decl_pos, "`{s}` takes `self` as `{s}`, but `{s}` declares `{s}`; a method meets its API with the same self: write `{s}`", .{ owner, selfSigil(have.self_mode), aname, signatureText(src, pos, false), header });
        return;
    }
    const want_ty = try apiMethodType(ctx, w, conf, have) orelse return;
    const want = ctx.types.get(want_ty).function;
    const got = switch (ctx.types.get(have.ty)) {
        .function => |f| f,
        else => return,
    };
    if (sema.containsPoison(ctx, have.ty) or sema.containsPoison(ctx, want_ty)) return;
    if (want.ct_params.len != got.ct_params.len) {
        try ctx.err(have.decl_pos, "`{s}` takes {d} compile-time parameter{s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, got.ct_params.len, plural(got.ct_params.len), aname, signatureText(src, pos, true), header });
        return;
    }
    // Each the same kind, of the same type, with the same bounds: a call
    // through the API passes what its brackets promise.
    const api_ct_syms = switch (w.home.types.get(w.field.ty)) {
        .function => |f| f.ct_syms,
        else => &.{},
    };
    for (want.ct_params, got.ct_params, 0..) |wc, gc, i| {
        const gsym: ?sema.Symbol = if (i < got.ct_syms.len and got.ct_syms[i] != sema.symbol_invalid) ctx.symbols.items[got.ct_syms[i]] else null;
        const gname = if (gsym) |s| s.name else "?";
        if (wc != gc) {
            const as: []const u8 = if (ctx.types.get(gc) == .type_var) "a type" else try a.print("`{s}`", .{try sema.formatType(ctx, gc)});
            try ctx.err(have.decl_pos, "`{s}` takes `{s}` as {s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, gname, as, aname, signatureText(src, pos, true), header });
            return;
        }
        if (ctx.types.get(gc) != .type_var or i >= api_ct_syms.len or api_ct_syms[i] == sema.symbol_invalid) continue;
        const g = gsym orelse continue;
        if (try sameBounds(w.home, w.home.symbols.items[api_ct_syms[i]], ctx, g)) continue;
        const written = try sema.formatBounds(ctx, a, g, null);
        const by: []const u8 = if (written.len == 0) "nothing" else try a.print("`{s}`", .{written});
        try ctx.err(have.decl_pos, "`{s}` bounds `{s}` by {s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, gname, by, aname, signatureText(src, pos, true), header });
        return;
    }
    if (want.params.len != got.params.len) {
        try ctx.err(have.decl_pos, "`{s}` takes {d} parameter{s}, but `{s}` declares `{s}`; a method meets its API with the same parameters: write `{s}`", .{ owner, got.params.len - 1, plural(got.params.len - 1), aname, signatureText(src, pos, false), header });
        return;
    }
    const names = have.param_names orelse &.{};
    for (want.params[1..], got.params[1..], 1..) |wp, gp, i| {
        if (wp == gp) continue;
        try ctx.err(have.decl_pos, "`{s}` takes `{s}` as `{s}`, but `{s}` declares `{s}`; a method meets its API with the same parameters: write `{s}`", .{ owner, if (i < names.len) names[i] else "?", try sema.formatType(ctx, gp), aname, signatureText(src, pos, false), header });
        return;
    }
    // The same names: a call through the API passes its arguments by the
    // API's names, which are the implementation's. A parameter its body
    // ignores may be `_`, as in any function (SPEC "Functions").
    const api_names = w.field.param_names orelse &.{};
    for (names, 0..) |n, i| {
        if (i == 0 or i >= api_names.len or std.mem.eql(u8, n, api_names[i])) continue;
        if (std.mem.eql(u8, n, "_") or std.mem.eql(u8, api_names[i], "_")) continue;
        try ctx.err(have.decl_pos, "`{s}` names its parameter `{s}` where `{s}` declares `{s}`; a method meets its API with the same names: write `{s}`", .{ owner, n, aname, api_names[i], header });
        return;
    }
    if (want.returns != got.returns) {
        const fails = ctx.types.get(want.returns) == .fallible or ctx.types.get(got.returns) == .fallible;
        const same_ok = sema.okOf(ctx, want.returns) == sema.okOf(ctx, got.returns);
        const got_shown = try sema.formatType(ctx, got.returns);
        const verb: []const u8 = if (ctx.types.get(got.returns) == .fallible) "fails with" else "gives";
        const what: []const u8 = if (fails and same_ok) "set" else "result";
        const result = resultText(src, pos);
        if (result.len == 0) {
            try ctx.err(have.decl_pos, "`{s}` {s} `{s}`, but `{s}` declares `{s}`, which gives nothing; a method meets its API with the same result: write `{s}`", .{ owner, verb, got_shown, aname, signatureText(src, pos, true), header });
        } else try ctx.err(have.decl_pos, "`{s}` {s} `{s}`, but `{s}` declares `{s}`; a method meets its API with the same {s}: write `{s}`", .{ owner, verb, got_shown, aname, signatureText(src, pos, true), what, result });
        return;
    }
    if (have.origins.once != w.field.origins.once) {
        const at = @ctz(have.origins.once ^ w.field.origins.once);
        const pname = if (at < names.len) names[at] else "?";
        try ctx.err(have.decl_pos, "`{s}` takes `{s}` {s} `once`, but `{s}` declares `{s}`; a method meets its API with the same `once`: write `{s}`", .{ owner, pname, if (have.origins.once & sema.paramBit(at) != 0) "with" else "without", aname, signatureText(src, pos, false), header });
        return;
    }
    // `keeps` and `from` may be narrower, never wider: a call through
    // the API keeps and views what the API says.
    const kept = have.origins.stores & have.origins.viewed;
    const api_kept = w.field.origins.stores & w.field.origins.viewed;
    if (kept & ~api_kept != 0) {
        const extra = kept & ~api_kept;
        const first = @ctz(extra);
        const pname = if (first < names.len) names[first] else "?";
        try ctx.err(have.decl_pos, "`{s}` keeps {s}, but `{s}.{s}` keeps {s}: a call through `{s}` would leave `{s}` free while `{s}` still views it; add `keeps {s}` to `{s}.{s}`", .{ owner, try maskNames(a, names, extra), aname, w.field.name, try maskNames(a, api_names, api_kept), aname, pname, tname, if (first < api_names.len) api_names[first] else pname, aname, w.field.name });
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    if ((try sema.viewTargets(ctx, scratch.allocator(), got.returns)).isEmpty()) return;
    const viewed = have.origins.result & ~w.field.origins.result & paramsMask(got.params.len);
    if (viewed != 0) {
        const first = @ctz(viewed);
        const pname = if (first < names.len) names[first] else "?";
        const fix = if (have.origins.declared)
            try a.print("add `{s}` to the `from` of `{s}.{s}`", .{ pname, aname, w.field.name })
        else
            try a.print("write `from {s}` on `{s}`", .{ try maskList(a, api_names, w.field.origins.result & paramsMask(got.params.len)), owner });
        try ctx.err(have.decl_pos, "`{s}` may give a view of `{s}`, but `{s}.{s}` does not: a call through `{s}` would leave `{s}` free while the result still views it; {s}", .{ owner, pname, aname, w.field.name, aname, pname, fix });
    }
}

/// Whether type parameters `x` (of module `xc`) and `y` (of `yc`) are
/// bounded alike: the same built-in APIs and the same of a program's own,
/// with what each implies and builds on (`[K: Hash]` is `[K: Hash +
/// Eq]`).
pub fn sameBounds(xc: *const SemContext, x: sema.Symbol, yc: *const SemContext, y: sema.Symbol) Error!bool {
    if (!sema.boundApis(xc, x).eql(sema.boundApis(yc, y))) return false;
    var scratch = std.heap.ArenaAllocator.init(xc.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var xs: std.ArrayList(sema.ApiRef) = .empty;
    var ys: std.ArrayList(sema.ApiRef) = .empty;
    for (x.user_apis) |r| try xs.appendSlice(a, try sema.apiClosure(xc, a, r));
    for (y.user_apis) |r| try ys.appendSlice(a, try sema.apiClosure(yc, a, r));
    for ([_][2][]const sema.ApiRef{ .{ xs.items, ys.items }, .{ ys.items, xs.items } }) |pair| {
        for (pair[0]) |r| {
            const found = for (pair[1]) |o| {
                if (o.eql(r)) break true;
            } else false;
            if (!found) return false;
        }
    }
    return true;
}

pub fn selfSigil(r: sema.SelfMode) []const u8 {
    return switch (r) {
        .read => "?@",
        .write => "!@",
        .value => "<@",
        .none => "nothing",
    };
}

/// The parameters `mask` names, as an error lists them: `` `s` ``,
/// `` `s`, `t` ``, or `nothing`.
pub fn maskNames(a: std.mem.Allocator, names: []const []const u8, mask: sema.ParamMask) Error![]const u8 {
    if (mask == 0) return "nothing";
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i >= 64 or mask & sema.paramBit(i) == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.print(a, "`{s}`", .{n});
    }
    return out.items;
}

/// The parameters `mask` names, joined for a `from` clause: `@, a`.
pub fn maskList(a: std.mem.Allocator, names: []const []const u8, mask: sema.ParamMask) Error![]const u8 {
    if (mask == 0) return "static";
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i >= 64 or mask & sema.paramBit(i) == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

/// The type the API method `w` gives a conformance's method, in this
/// module's types: `Self` is the conformance's type, and each of the
/// API method's compile-time parameters the method's own (`have`), in
/// order. Null when the two take different numbers of them, which the
/// caller reports.
pub fn apiMethodType(ctx: *SemContext, w: ApiMethod, conf: sema.Conformance, have: Field) Error!?TypeId {
    const local_ty = if (w.home == @as(*const SemContext, ctx)) w.field.ty else try sema.importType(ctx, w.home, w.field.ty, w.api.module_id);
    const f = switch (ctx.types.get(local_ty)) {
        .function => |f| f,
        else => return null,
    };
    const got = switch (ctx.types.get(have.ty)) {
        .function => |g| g,
        else => return null,
    };
    const api_sym = sema.apiSymbol(ctx, w.api) orelse return null;
    const home_self = (api_sym.type_params orelse return null)[0];
    const self_param = if (w.home == @as(*const SemContext, ctx)) home_self else try sema.proxyOf(ctx, .{ .module_id = w.api.module_id, .sym = home_self });
    var params: std.ArrayList(SymbolId) = .empty;
    var args: std.ArrayList(TypeId) = .empty;
    const a = ctx.arena.allocator();
    try params.append(a, self_param);
    try args.append(a, conf.ty);
    if (f.ct_syms.len == got.ct_syms.len) for (f.ct_syms, got.ct_syms, 0..) |p, g, i| {
        if (p == sema.symbol_invalid or g == sema.symbol_invalid) continue;
        try params.append(a, p);
        const is_type = ctx.types.get(got.ct_params[i]) == .type_var;
        try args.append(a, try ctx.intern(if (is_type) .{ .type_var = g } else .{ .ct_param = g }));
    };
    return try sema.substituteType(ctx, local_ty, .{ .params = params.items, .args = args.items });
}

/// Why `==` is not defined for a type, as a diagnostic says it.
pub fn notEquatableReason(ctx: *SemContext, n: sema.NotEquatable) Error![]const u8 {
    const a = ctx.arena.allocator();
    const t = try sema.formatType(ctx, n.ty);
    if (n.path.len > 0) return switch (n.why) {
        .handle => a.print("field `{s}` is a handle `{s}`, which could compare by identity or by content", .{ n.path, t }),
        .closure => a.print("field `{s}` is an owned closure `{s}`", .{ n.path, t }),
        .function => a.print("field `{s}` is a function value", .{n.path}),
        .no_eq => a.print("field `{s}` is a `{s}`, which has no `==`", .{ n.path, t }),
        .view => a.print("field `{s}` holds a `?T`, `!T`, or slice", .{n.path}),
        .drop => a.print("field `{s}` is a `{s}`: `{s}` declares `drop`", .{ n.path, t, t }),
        .unique => a.print("field `{s}` is a `{s}`, which is unique", .{ n.path, t }),
        .lanes => a.print("field `{s}` is a `{s}`, whose `==` compares lane by lane; compare the fields and reduce the mask: `(x.{s} == y.{s}).all()`", .{ n.path, t, n.path, n.path }),
        .float => a.print("field `{s}` is a `{s}`, and `==` calls `0.0` and `-0.0` equal and NaN equal to nothing", .{ n.path, t }),
        .own_eq => a.print("field `{s}` is a `{s}`, which declares its own `==` and no hash of its own", .{ n.path, t }),
        .object => a.print("field `{s}` is a `{s}`, and two API objects may hide two types, which `==` cannot compare", .{ n.path, t }),
    };
    return switch (n.why) {
        .handle => a.print("`{s}` is a handle, which could compare by identity or by content", .{t}),
        .closure => a.print("`{s}` is an owned closure", .{t}),
        .function => a.print("`{s}` is a function value", .{t}),
        .no_eq => a.print("`{s}` has no `==`", .{t}),
        .view => a.print("`{s}` is a view", .{t}),
        .drop => a.print("`{s}` declares `drop`", .{t}),
        .unique => a.print("`{s}` is unique", .{t}),
        .lanes => a.print("`{s}` holds a vector, whose `==` compares lane by lane", .{t}),
        .float => a.print("`==` calls `0.0` and `-0.0` equal and NaN equal to nothing; hash its bits, `x.to_bits().hash()`", .{}),
        .own_eq => sema.ownEqUnhashed(ctx, n.ty),
        .object => a.print("two API objects may hide two types, which `==` cannot compare", .{}),
    };
}

pub fn satisfies(ctx: *SemContext, ty: TypeId, req: Requirement) Error!bool {
    return switch (req) {
        .numeric, .bytes => sema.isNumeric(ctx, ty),
        .records => switch (try sema.bytesRecord(ctx, ty)) {
            // A generic body's bytes are not an embedded file's, known
            // where the call is written, so every bit pattern is a value.
            .record => |r| r.checks.len == 0,
            .not => false,
        },
        .ordered => sema.isNumeric(ctx, ty) or ctx.types.get(ty) == .string_view or ctx.types.get(ty) == .static or sema.isOrderedEnum(ctx, ty) or (try sema.lacks(ctx, ty, .Ord)) == null,
        .integer => sema.isInteger(ctx, ty),
        .signed => switch (ctx.types.get(ty)) {
            .int => |info| info.signed,
            .float => true,
            else => false,
        },
        .float => ctx.types.get(ty) == .float,
        .fits => |v| sema.isNumeric(ctx, ty) and holdsInt(ctx, ty, v),
        .shift => |v| switch (ctx.types.get(ty)) {
            .int => |info| v < intBounds(info).bits,
            else => false,
        },
        .copies => sema.copies(ctx, ty) != .no,
        .clones => (try sema.lacks(ctx, ty, .Clone)) == null,
        .no_cleanup => !sema.typeHasDropGlue(ctx, ty),
        .lane_count => switch (ctx.types.get(ty)) {
            .ct_value => |v| sema.lanesInRange(v.int),
            else => false,
        },
        .slot_count => sema.slotCount(ctx, ty) != null,
        .sized => !sema.holdsVector(ctx, ty),
        .array_len => switch (ctx.types.get(ty)) {
            .ct_value => |v| v.int >= 0 and v.int <= sema.max_array_len,
            else => false,
        },
        .equatable => sema.isEquatable(ctx, ty),
        .hashable => isText(ctx, ty) or (try sema.notHashable(ctx, ty, null)) == null,
        .whole_division => sema.isInteger(ctx, ty),
        // An API object prints only by the `Print` its braces or API name.
        .printable => try sema.printable(ctx, ty) and try sema.objectUnprinted(ctx, ty) == null,
        .not_error => ctx.types.get(ty) != .any_error and !sema.isErrorSet(ctx, ty),
        .error_set => sema.isErrorValue(ctx, ty),
        .not_function => ctx.types.get(ty) != .function,
        .named => sema.unnameable(ctx, ty) == null,
        .frozen => (try sema.frozenBlocker(ctx, ty)) == null,
        .no_task => !sema.holdsTask(ctx, ty),
        .task => |reach| (try sema.taskBlocker(ctx, ty, reach)) == null,
        .meets => |api| (try sema.lacks(ctx, ty, api)) == null,
        .order => (try sema.lacks(ctx, ty, .Ord)) == null,
    };
}

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
const typecheck_source = @embedFile("typecheck.zig") ++ @embedFile("check/builtins.zig") ++ @embedFile("check/calls.zig") ++ @embedFile("check/closures.zig") ++ @embedFile("check/expr.zig") ++ @embedFile("check/flow.zig") ++ @embedFile("check/patterns.zig") ++ @embedFile("check/stdforms.zig") ++ @embedFile("check/stmt.zig") ++ @embedFile("check/views.zig");

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

test "check: every read of a view as a value is decided by writeViewRead" {
    // `readOf` is the one place type checking records that a view is read
    // as the value it reaches, and it asks `writeViewRead` first. Another
    // call of `recordRead` would read a written `!x` as a value with its
    // `!` ignored, past the decider.
    const needle = "ctx." ++ "recordRead(";
    const src = typecheck_source;
    try std.testing.expectEqual(1, std.mem.count(u8, src, needle));
    const at = std.mem.find(u8, src, needle).?;
    const fn_at = std.mem.findLast(u8, src[0..at], "pub fn ").?;
    try std.testing.expect(std.mem.startsWith(u8, src[fn_at..], "pub fn readOf("));
    try std.testing.expect(std.mem.find(u8, src[fn_at..at], "self.writeViewRead(") != null);
    // Every pass after type checking reads the fact; none records it.
    for ([_][]const u8{ @embedFile("emit.zig"), @embedFile("ownership.zig"), @embedFile("storage.zig"), @embedFile("resolve.zig") }) |other| {
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
    for ([_][]const u8{ @embedFile("ownership.zig"), @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, "sema." ++ "misplaced("));
        try std.testing.expectEqual(0, std.mem.count(u8, other, "sema." ++ "writeViewMisplaced("));
    }
    // A value holding a Cell is made only at a home (`cellMadeAway`),
    // asked of every expression typed (`synthExpr`, `checkExpr`).
    try std.testing.expectEqual(2, std.mem.count(u8, tc, "self." ++ "cellMadeAway("));
    // Every view of a branch, written or in place, asks `viewsBranch`:
    // a sigil, a slice, a write view of a temporary, a weak handle `*`
    // upgrades, a temporary viewed to read, a header's subject, and a view
    // a context takes in place.
    const call = "self." ++ "viewsBranch(";
    var from: usize = 0;
    for ([_][]const u8{ "headerViewsBranch", "makeViewOf", "checkWriteView", "viewSlice", "weakUpgrade", "viewTempIn", "checkExpr" }) |want| {
        from = std.mem.findPos(u8, tc, from, call).?;
        const fn_at = std.mem.findLast(u8, tc[0..from], "pub fn ").?;
        const got = tc[fn_at + "pub fn ".len .. fn_at + std.mem.findScalar(u8, tc[fn_at..], '(').?];
        try std.testing.expectEqualStrings(want, got);
        from += call.len;
    }
    try std.testing.expect(std.mem.findPos(u8, tc, from, call) == null);
    // What a Cell kept by value needed is gone: no per-instance
    // interior mutability, Cell temporaries, or write through a field.
    for ([_][]const u8{ "interior" ++ "Mutable", "ReadPtr" ++ "(", "Cell" ++ "Temp", "refuseHeld" ++ "Cell", "payloadReads" ++ "ThroughWrite", "headerCopies" ++ "WriteView" }) |gone| {
        for ([_][]const u8{ sema_src, tc, res, @embedFile("ownership.zig"), @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig"), @embedFile("runtime.zig") }) |src| {
            try std.testing.expectEqual(0, std.mem.count(u8, src, gone));
        }
    }
    // A read view changes nothing, a Cell included (Core sentence 4): neither
    // the emitter nor the ownership checker treats a read view of a value
    // that holds a Cell differently from any other.
    for ([_][]const u8{ @embedFile("ownership.zig"), @embedFile("emit.zig"), @embedFile("facts.zig") }) |src| {
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
    try std.testing.expectEqual(2, std.mem.count(u8, @embedFile("ownership.zig"), "self.loan" ++ "Of("));
    for ([_][]const u8{ @embedFile("ownership.zig"), @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig") }) |other| {
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
    var at: usize = 0;
    for ([_][]const u8{ "pub fn loopElement(", "pub fn bindMatchView(", "pub fn asAccess(" }) |want| {
        at = std.mem.findPos(u8, tc, at, decide).?;
        const fn_at = std.mem.findLast(u8, tc[0..at], "pub fn ").?;
        try std.testing.expect(std.mem.startsWith(u8, tc[fn_at..], want));
        at += decide.len;
    }
    // The access is recorded where each binding's type is: in
    // `checkOptionalBinding`, `checkFor`, and `bindMatchView`, each also
    // marking it decided for the check that the two agree
    // (`sema.checkBindingAccess`).
    try std.testing.expectEqual(3, std.mem.count(u8, tc, record));
    try std.testing.expectEqual(3, std.mem.count(u8, tc, "flags.access_decided" ++ " = true"));
    // One helper builds a binding's type from its access, for every kind
    // of binding: `viewOfAccess`, called from the three binding sites.
    const derive = "self." ++ "viewOfAccess(";
    try std.testing.expectEqual(3, std.mem.count(u8, tc, derive));
    at = 0;
    for ([_][]const u8{ "pub fn checkOptionalBinding(", "pub fn loopElement(", "pub fn bindMatchView(" }) |want| {
        at = std.mem.findPos(u8, tc, at, derive).?;
        const fn_at = std.mem.findLast(u8, tc[0..at], "pub fn ").?;
        try std.testing.expect(std.mem.startsWith(u8, tc[fn_at..], want));
        at += derive.len;
    }
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
        .{ .call = "self." ++ "headerViewsBranch(", .callers = &.{ "checkOptionalBinding", "checkFor", "checkMatchSubject" } },
    }) |shared| {
        try std.testing.expectEqual(shared.callers.len, std.mem.count(u8, tc, shared.call));
        var from: usize = 0;
        for (shared.callers) |want| {
            from = std.mem.findPos(u8, tc, from, shared.call).?;
            const fn_at = std.mem.findLast(u8, tc[0..from], "pub fn ").?;
            const got = tc[fn_at + "pub fn ".len .. fn_at + std.mem.findScalar(u8, tc[fn_at..], '(').?];
            try std.testing.expectEqualStrings(want, got);
            from += shared.call.len;
        }
    }
    // The decider is sema's alone.
    try std.testing.expectEqual(1, std.mem.count(u8, @embedFile("sema.zig"), "pub fn " ++ "decideBindingAccess("));
    for ([_][]const u8{ @embedFile("ownership.zig"), @embedFile("emit.zig"), @embedFile("storage.zig"), @embedFile("facts.zig"), @embedFile("resolve.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, decide));
        try std.testing.expectEqual(0, std.mem.count(u8, other, record));
    }
    // Ownership views a binding by its access, in `viewTarget` alone,
    // which reads neither the binding's type (`ref`) nor how the match
    // reached it (`payload_view`, `matchMode`).
    const own = @embedFile("ownership.zig");
    const read_fact = "ctx." ++ "bindingAccess(";
    try std.testing.expectEqual(1, std.mem.count(u8, own, read_fact));
    const target_at = std.mem.find(u8, own, "    fn " ++ "viewTarget(").?;
    const body = own[target_at..std.mem.findPos(u8, own, target_at, "\n    }\n").?];
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
    try checkFrames(&r.ctx);
    try expectDiagnostic(&r.ctx, "cannot count the values this `inline` call adds to the frame it is in (the call does not bind every parameter its values hold)");
    // A function no module declares.
    ic.* = saved;
    ic.fun.module +%= 1000;
    try checkFrames(&r.ctx);
    try expectDiagnostic(&r.ctx, "cannot count the values this `inline` call adds to the frame it is in (its module is not loaded)");
}
