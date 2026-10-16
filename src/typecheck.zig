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
const MethodReceiver = sema.MethodReceiver;
const NominalContext = sema.NominalContext;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;

const identAt = sema.identAt;
const srcPos = sema.srcPos;

pub fn checkModule(ctx: *SemContext, tree: Sexp, module_scope: ScopeId) Error!void {
    if (!tree.isKind(.module)) return;
    var c: Checker = .{
        .ctx = ctx,
        .scope = module_scope,
        .module_scope = module_scope,
        .body = .{ .ret = ctx.types.void_id },
    };
    defer c.arg_types.deinit(ctx.allocator);
    defer c.methods.deinit(ctx.allocator);
    defer c.expected.deinit(ctx.allocator);
    defer c.value_tails.deinit(ctx.allocator);
    defer c.kept_reported.deinit(ctx.allocator);
    defer c.lend_of.deinit(ctx.allocator);
    defer c.branch_lends.deinit(ctx.allocator);
    defer c.copied_from.deinit(ctx.allocator);
    defer c.read_subjects.deinit(ctx.allocator);
    defer c.loop_pairs.deinit(ctx.allocator);
    defer c.owned_bindings.deinit(ctx.allocator);
    defer c.literal_results.deinit(ctx.allocator);
    defer c.result_hints.deinit(ctx.allocator);
    defer c.jump_targets.deinit(ctx.allocator);
    for (ctx.const_order.items) |decl| try c.checkDecl(decl);
    for (ir.Module.decls(tree)) |decl| if (!rig.isModuleConst(decl)) try c.checkDecl(decl);
    for (ir.Module.decls(tree)) |decl| try c.checkLendBases(decl, decl, false, true);
}

/// The diagnostic for an operand of `<`, `<=`, `>`, or `>=` whose type
/// has no order: the operator, then the type.
const ordering_operands = "operator `{s}` orders numbers, plain enums, Strings, and `[]U8` slices; got `{s}`";

/// Where a binding that cannot be written got its value: a loop element
/// or `as` binding copied from a place, or a match binding of a field of
/// the place a bare match copies (`match_copy`) or a `?` match reads
/// (`match_read`).
const CopySource = struct { place: Sexp, kind: enum { loop, as, match_copy, match_read }, whole: bool = false };

/// How a match reaches its subject: `match e` and `match ?e` read it,
/// `match !e` writes its fields in place, and `match <e` consumes it.
const MatchMode = enum { read, write, consume };

const Checker = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,
    /// The function, method, closure, test, or drop body being checked.
    body: Body,
    nominal: NominalContext = NominalContext.none,
    /// Callee node of the method call being checked; its resolved
    /// signature is recorded as the node's type.
    callee_node: ?Sexp = null,
    /// The call being checked, for its argument-slot fact.
    current_call: ?Sexp = null,
    /// The compile-time parameters of its own and their arguments, of the
    /// instance the last `instantiateCall` made; empty for a function that
    /// has none (`noteTarget`).
    inst_own: TypeSubst = .empty,
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
    /// The value of the struct or enum field, or the field default, being
    /// checked: a value holding a Cell may be made there (`cellMadeAway`).
    cell_home: Sexp = .nil,
    /// The object of the member, method call, or lend being checked: a
    /// branch there is read in place, by address, never copied
    /// (`cellMadeAway`).
    in_place: Sexp = .nil,
    /// The operand of the `return` being checked: an error value meets a
    /// `T!` only in its branch leaves (`isReturnLeaf`).
    return_operand: Sexp = .nil,
    /// The expression statement being checked, whose value is
    /// discarded (`isDiscardedCall`).
    discarded: Sexp = .nil,
    /// The call that gives several results where they may stand: the
    /// value of a destructure, of `return` in a function that gives
    /// them, or of `if ... as a, b` (docs/INTERNALS.md, "Several
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
    /// The calls whose lasting lends were reported (`keptLends`), so that
    /// one reached from two kept values is reported once.
    kept_reported: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The `!x` being checked where a write view is expected, the one
    /// place a write view of a `Bool` is not read as its value.
    lent_write: Sexp = .nil,
    /// Whether a lend of a handle that changes by a marked call skips the
    /// writability checks (`handleWritable` turns it off).
    handle_exempt: bool = true,
    /// The receiver of the method call being checked, while it is typed.
    receiver_obj: Sexp = .nil,
    /// The operand of the `not` being checked, which must be a `Bool`.
    not_operand: Sexp = .nil,
    /// The `and` or `or` being checked, and its operands, which must be
    /// `Bool`s.
    logic_op: []const u8 = "",
    logic_operands: [2]Sexp = .{ .nil, .nil },
    /// The condition of the `if` value being checked.
    ternary_cond: Sexp = .nil,
    /// A call whose value a `!` written before it lends to write, with
    /// the sigil outside the call (`!(v.pop())`, `!o?.pop()`), or the
    /// source of a `for` whose `!` is the loop's mode: a write method on
    /// a temporary receiver there has a `!` that does not reach it.
    outer_write: Sexp = .nil,
    /// The member a method call is checked through, while its receiver
    /// mode is checked.
    receiver_of: Sexp = .nil,
    /// `outer_write` is a `for` source.
    outer_write_is_loop: bool = false,
    /// The argument being checked, when the call keeps no view of its
    /// arguments: a temporary array there may be lent as a `[]T`.
    lent_temp: Sexp = .nil,
    /// The argument being checked, or a generic call's type parameters
    /// inferred from: a bare value there is lent to read where a view is
    /// expected (`lendView`), and a slice there is lent as `?xs[a..b]`
    /// would be (`synthSlice`).
    view_arg: Sexp = .nil,
    /// The parameter or field the argument being checked fills, which a
    /// diagnostic names (`ignoredWriteLend`).
    slot: Slot = .{},
    /// A construction a field of which `writeLendRead` rejected: its own
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
    /// The argument being checked, where a closure literal may be lent
    /// as a callable view, and the call when its result could hold
    /// the literal instead.
    lent_callable: Sexp = .nil,
    callable_kept: Sexp = .nil,
    /// Set by a caller of `checkArgs` whose call may take a temporary
    /// array as a `[]T` argument (a function or method, not a closure),
    /// with a method's receiver parameter.
    lend_call: bool = false,
    lend_recv: ?TypeId = null,
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
    /// The types inference found for arguments (`argType`).
    arg_types: std.AutoHashMapUnmanaged(parser.NodeId, TypeId) = .empty,
    /// What typing found that the walk over paths reads
    /// (`checkLendBases`): the members a call resolved as a method, with
    /// how it takes its receiver and what it returns; the type each
    /// expression was checked against; the values that are a function's,
    /// a closure's, or a block's last value, which are used; and the
    /// lend each path's object is (`lendOf`).
    methods: std.AutoHashMapUnmanaged(parser.NodeId, MethodFact) = .empty,
    expected: std.AutoHashMapUnmanaged(parser.NodeId, TypeId) = .empty,
    value_tails: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    lend_of: std.AutoHashMapUnmanaged(parser.NodeId, ?Sexp) = .empty,
    /// Whether each branch lent (`?(a if c else b)`, or a path from one)
    /// may be (`lendsBranch`), decided once.
    branch_lends: std.AutoHashMapUnmanaged(parser.NodeId, bool) = .empty,
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
    /// `ty`.
    result_expected: struct { call: Sexp = .nil, ty: TypeId = sema.type_invalid } = .{},
    /// Inside `argType`, whose argument the call checks again with the
    /// type it is expected to have: the generic instances found there
    /// are not recorded.
    tentative: u32 = 0,
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
    const ResultPath = enum { direct, propagate, propagate_none };
    const LiteralResult = struct { ty: TypeId, path: ResultPath };

    const Body = struct {
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
    };

    const LoopFrame = struct {
        label: []const u8,
        /// The construct a jump to this frame names: a `while` or `for`,
        /// or a labeled block's `match` or `raw` block.
        node: Sexp,
        /// False for a labeled block, which only `break @label` leaves.
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
    const LoopPart = enum { source, cond, step, body };

    /// A member a call resolved as a method: how it takes its receiver,
    /// and what it returns.
    const MethodFact = struct { receiver: sema.MethodReceiver, returns: TypeId };

    /// A loop used as a value: its `break` values and its `else` value.
    const LoopValue = struct {
        expected: ?TypeId,
        /// The type the values settle on, without `expected`.
        ty: ?TypeId = null,
        values: std.ArrayList(Typed) = .empty,
    };

    /// A branch, arm, or `break` value and the type it synthesized.
    const Typed = struct { node: Sexp, ty: TypeId };

    const ReturnSite = struct { node: Sexp, ty: ?TypeId };

    const FailTarget = union(enum) {
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

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.err(pos, fmt, args);
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.note(pos, fmt, args);
    }

    fn errAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.errAt(node, fmt, args);
    }

    fn noteAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.noteAt(node, fmt, args);
    }

    /// Where a node starts in the source.
    fn startOf(self: *Checker, node: Sexp) u32 {
        return self.ctx.startOf(node);
    }

    fn tyName(self: *Checker, ty: TypeId) Error![]const u8 {
        return sema.formatType(self.ctx, ty);
    }

    fn text(self: *Checker, node: Sexp) []const u8 {
        return identAt(self.ctx.source, node) orelse "";
    }

    /// Make the scope `node` opened current; returns the previous scope.
    fn enter(self: *Checker, node: Sexp) ScopeId {
        const prev = self.scope;
        if (self.ctx.scopeOf(node)) |s| self.scope = s;
        return prev;
    }

    fn resolver(self: *Checker) resolve.TypeResolver {
        return .{ .ctx = self.ctx, .scope = self.scope, .nominal = self.nominal };
    }

    fn t(self: *Checker) *sema.TypeStore {
        return &self.ctx.types;
    }

    fn isPoison(self: *Checker, ty: TypeId) bool {
        return ty == self.ctx.types.unknown_id or ty == self.ctx.types.invalid_id;
    }

    // =========================================================================
    // Declarations
    // =========================================================================

    fn checkDecl(self: *Checker, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return self.errAt(sexp, not_at_module_level, .{})) {
            .@"pub" => try self.checkDecl(ir.Pub.decl(sexp)),
            .fun, .sub => {
                const fn_ty = if (self.ctx.symbolOf(ir.get(sexp, .name))) |id| self.ctx.symbols.items[id].ty else self.t().invalid_id;
                try self.checkFunction(sexp, fn_ty);
            },
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => try self.checkNominal(sexp),
            .@"test" => {
                try self.checkEscapes(ir.Test.name(sexp));
                const prev_scope = self.enter(sexp);
                defer self.scope = prev_scope;
                // A test fails by returning an error, which `rig test`
                // reports.
                try self.checkBody(ir.Test.body(sexp), .{ .ret = self.t().void_id, .fail_to = .caller });
            },
            .set => try self.checkModuleConst(sexp),
            .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_const => {},
            .zig_extern => for (ir.ZigExtern.decls(sexp)) |d| try self.checkDecl(d),
            else => try self.errAt(sexp, not_at_module_level, .{}),
        }
    }

    /// A module-level binding is a constant, `name = value`: its value
    /// is known at compile time and owns nothing, so no function can
    /// change it and nothing has to release it.
    fn checkModuleConst(self: *Checker, node: Sexp) Error!void {
        const target = ir.Set.target(node);
        if (target != .src) return self.errAt(node, not_at_module_level, .{});
        if (rig.bindingKindOf(ir.Set.op(node)) != .fixed) {
            if (self.ctx.symbolOf(target)) |id| if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                self.ctx.symbols.items[id].ty = self.t().invalid_id;
            };
            return self.errAt(node, "a module-level binding is a constant; write `{s} = value`", .{self.text(target)});
        }
        try self.checkSet(node);
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
    fn checkConstArithmetic(self: *Checker, e: Sexp) Error!void {
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
        try self.errAt(operand, "the operands of a module constant's arithmetic must be values Rig computes when it checks the program, and it does not compute `{s}`; branch on integers, or write each branch's value", .{self.sourceText(operand)});
    }

    /// The first operand of the arithmetic `e`, outside further
    /// arithmetic, whose value Rig does not compute; null when each has
    /// one (and `e` has none for another reason, reported elsewhere).
    fn unknownOperand(self: *Checker, e: Sexp) ?Sexp {
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
    fn perTarget(self: *Checker, node: Sexp, what: []const u8) Error!bool {
        const leaf = sema.perTargetLeaf(self.ctx, node) orelse return false;
        try self.errAt(node, "{s} must be known when Rig checks the program; " ++ sema.per_target_why, .{ what, self.sourceText(leaf) });
        return true;
    }

    fn isConstExpr(self: *Checker, e: Sexp) bool {
        if (e.isKind(.array)) {
            for (ir.Array.elems(e)) |x| if (!self.isConstExpr(x)) return false;
            return true;
        }
        if (e.isKind(.array_fill)) return self.isConstExpr(ir.ArrayFill.value(e));
        // A ternary `a if c else b` over constants.
        if (e.isKind(.@"if")) return self.isConstExpr(ir.If.cond(e)) and self.isConstExpr(ir.If.then(e)) and self.isConstExpr(ir.If.@"else"(e));
        return self.isComptimeKnown(e);
    }

    /// A call that makes a vector of its one argument: `Simd[T, n](a)`,
    /// `Block(a)` for an alias `Block` of a vector type, or `.splat(x)` of
    /// either.
    fn isVectorMade(self: *Checker, call: Sexp) bool {
        const ty = self.ctx.typeOf(call) orelse return false;
        if (self.ctx.types.get(ty) != .simd or ir.Call.args(call).len != 1) return false;
        const callee = ir.Call.callee(call);
        if (self.ctx.elemCallOf(callee)) |ec| return ec.op == .splat;
        const named = if (rig.isBracketList(callee)) ir.get(callee, .object) else callee;
        if (named != .src) return false;
        const id = self.ctx.symbolOf(named) orelse self.lookupQuiet(named) orelse return false;
        return if (rig.isBracketList(callee)) id == self.ctx.simd_sym_id else self.ctx.symbols.items[id].kind == .type_alias;
    }

    const not_at_module_level = "only declarations and bindings are allowed at module level; move this statement into a function";
    const discard_read = "`_` discards a value; it cannot be read";
    const stack_signal = "stack-local `Signal[T]` is not supported: a Signal lives behind a shared handle; construct it with `*Signal(...)`";

    /// A `struct`, `enum`, `errors`, `generic_struct`, or `generic_enum`.
    fn checkNominal(self: *Checker, node: Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(ir.get(node, .name)) orelse return;
        const prev = self.nominal;
        self.nominal = try sema.makeNominalContext(self.ctx, sym_id);
        defer self.nominal = prev;
        const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
        for (ir.rest(node, .members)) |m| {
            const h = m.kind() orelse continue;
            switch (h) {
                .fun, .sub => {
                    const pos = ir.get(m, .name).src.pos;
                    var fn_ty = self.t().invalid_id;
                    for (fields) |f| {
                        if (f.is_method and f.decl_pos == pos) fn_ty = f.ty;
                    }
                    try self.checkFunction(m, fn_ty);
                },
                .default => for (fields) |f| {
                    if (f.default != null and f.decl_pos == ir.Default.name(m).src.pos) try self.checkDefaultValue(f.default.?, f.ty, "field");
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

    /// A `fun` or `sub`.
    fn checkFunction(self: *Checker, node: Sexp, fn_ty_id: TypeId) Error!void {
        const is_sub = node.isKind(.sub);
        const fn_ty = self.ctx.types.get(fn_ty_id);
        const ret = if (fn_ty == .function) fn_ty.function.returns else self.t().unknown_id;

        const prev_scope = self.enter(node);
        defer self.scope = prev_scope;
        const name = ir.get(node, .name);
        // The root module's `main` is the program's entry point; in any
        // other module `main` is an ordinary function.
        const is_main = self.ctx.is_root and self.nominal.isEmpty() and std.mem.eql(u8, self.text(name), "main");
        // It returns nothing, or the process's exit status (`-> Int`, or
        // `-> Int!`).
        const status = ret == self.t().int_id or (self.ctx.types.get(ret) == .fallible and self.ctx.types.get(ret).fallible == self.t().int_id);
        if (is_main and ((!is_sub and !status) or ir.get(node, .params).items().len > 0 or sema.tparamsOf(node).items().len > 0)) {
            try self.errAt(name, "`main` must be `sub main()`, or `fun main() -> Int` returning the exit status (`-> Int!` if it may fail): the program's entry point takes no parameters", .{});
        }
        for (ir.get(node, .params).items()) |p| if (p.isKind(.default)) {
            const ty = self.ctx.bindingTypeOf(ir.Default.name(p)) orelse self.t().unknown_id;
            try self.checkDefaultValue(ir.Default.value(p), ty, "parameter");
        };
        // `main` lowers to a fallible Zig `main`.
        const fallible = is_main or rig.subFails(node) or rig.returnType(node).isKind(.error_union);
        if (node.isKind(.fun) and !is_main) try self.checkFunReturns(node, ret);
        // A Zig-backed declaration's body is its Zig function.
        if (ir.get(node, .body) == .nil) return;
        try self.checkBody(ir.get(node, .body), .{ .ret = ret, .is_sub = is_sub, .fail_to = if (fallible) .caller else .{ .infallible = name }, .name = name });
    }

    /// A `fun` returns a value: one without `-> T`, or returning `Void`,
    /// is a `sub` (`sub f(...)!` when it may fail).
    fn checkFunReturns(self: *Checker, node: Sexp, ret: TypeId) Error!void {
        const returns = rig.returnType(node);
        const name = self.text(ir.get(node, .name));
        if (returns == .nil) {
            return self.errAt(ir.get(node, .name), "a `fun` returns a value; declare `-> T`, or make `{s}` a `sub`", .{name});
        }
        const r = self.ctx.types.get(ret);
        if (ret == self.t().void_id) {
            try self.errAt(returns, "a `fun` returning nothing is a `sub`: `sub {s}(...)`", .{name});
        } else if (r == .fallible and r.fallible == self.t().void_id) {
            try self.errAt(returns, "a `fun` that returns nothing but may fail is a fallible `sub`: `sub {s}(...)!`", .{name});
        }
    }

    /// A parameter or field default, of type `ty`, means the same value
    /// wherever it is filled in: a literal, or a module constant (this
    /// module's or an imported one, or a number type's limit). A field's
    /// may also be an empty or literal constructor, `List()`, `String()`,
    /// `Cell(0)`, or `[n of 0]`, which each value gets a fresh one of.
    fn checkDefaultValue(self: *Checker, value: Sexp, ty: TypeId, what: []const u8) Error!void {
        const field = std.mem.eql(u8, what, "field");
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
        try self.checkExpr(value, ty);
    }

    /// A module constant, of this module or an imported one (`LIMIT`,
    /// `lib.LIMIT`), or a number type's limit (`U8.max`, `Byte.max`,
    /// `lib.Byte.max`).
    fn isConstantDefault(self: *Checker, e: Sexp) bool {
        if (e == .src) {
            const id = self.lookupQuiet(e) orelse return false;
            const sym = self.ctx.symbols.items[id];
            return sym.kind == .local and sym.scope == self.module_scope and sym.flags.fixed;
        }
        if (!e.isKind(.member)) return false;
        const obj = ir.Member.object(e);
        if (self.namesNumberType(obj)) return true;
        if (obj != .src) return false;
        const id = self.lookupQuiet(obj) orelse return false;
        if (self.ctx.symbols.items[id].kind != .module) return false;
        const foreign = self.foreignMember(e) orelse return false;
        return foreign.kind == .local and foreign.flags.fixed;
    }

    /// `List()`, `List[T]()`, `Cell(literal)`, `[n of literal]` (or of a
    /// constant), or `T()` of an object type whose every field has a
    /// default (`T`, `lib.T`, `T[A]`, `lib.T[A]`), which is made from
    /// those defaults.
    fn isConstructorDefault(self: *Checker, e: Sexp) Error!bool {
        if (e.isKind(.array_fill)) {
            const v = ir.ArrayFill.value(e);
            return isDefaultLiteral(self.ctx.source, v) or self.isConstantDefault(v);
        }
        if (!e.isKind(.call)) return false;
        var callee = ir.Call.callee(e);
        // `String()`: the empty text, which owns nothing yet.
        if (callee == .src and std.mem.eql(u8, self.text(callee), "String") and self.lookupQuiet(callee) == null) return ir.Call.args(e).len == 0;
        if (rig.isBracketList(callee)) callee = ir.get(callee, .object);
        const args = ir.Call.args(e);
        if (callee == .src) if (self.lookupQuiet(callee)) |id| {
            if (id == self.ctx.list_sym_id) return args.len == 0;
            if (id == self.ctx.cell_sym_id) return args.len == 1 and isDefaultLiteral(self.ctx.source, args[0]);
        };
        return args.len == 0 and try self.emptyConstructor(ir.Call.callee(e));
    }

    /// `T()` as a field default, of an object type with a field that has
    /// no default: reported naming those fields. True when reported.
    fn emptyConstructorGap(self: *Checker, e: Sexp) Error!bool {
        if (!e.isKind(.call) or ir.Call.args(e).len != 0) return false;
        const callee = ir.Call.callee(e);
        const nt = (try self.namedType(callee)) orelse return false;
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
        const shown = self.sourceText(callee);
        try self.errAt(e, "`{s}()` is a default only when every field of `{s}` has one, and {s} {s} none", .{ shown, shown, bare.items, if (n == 1) "has" else "have" });
        return true;
    }

    /// Whether `callee`, called with no arguments, names an object type
    /// whose every field has a default.
    fn emptyConstructor(self: *Checker, callee: Sexp) Error!bool {
        const nt = (try self.namedType(callee)) orelse return false;
        const fields = nt.sym.fields orelse return false;
        for (fields) |f| if (f.is_variant) return false;
        return everyFieldDefaulted(fields);
    }

    /// A body's statements, checked as `context`; in a `fun`, the last one
    /// is its value.
    fn checkBody(self: *Checker, body: Sexp, context: Body) Error!void {
        const saved = self.body;
        defer self.body = saved;
        self.body = context;
        const ret = context.ret;
        const wants_value = !context.is_sub and ret != self.t().void_id;
        if (!body.isKind(.block)) {
            if (wants_value) try self.checkTail(body, ret) else try self.checkStmt(body);
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
            .fallible => |inner| inner == self.t().void_id,
            else => false,
        };
        for (stmts, 0..) |s, i| {
            if (wants_value and i == stmts.len - 1) {
                if (loopsForever(self.ctx.source, s) or (ends_void and (self.yieldsNoValue(s) or isIfWithoutElse(s)))) {
                    try self.checkStmt(s);
                    continue;
                }
                if (self.yieldsNoValue(s) and !s.isKind(.@"return")) {
                    try self.checkStmt(s);
                    const what = switch (s.kind().?) {
                        .set => "assignment",
                        .@"while", .@"for" => "loop",
                        .labeled => switch (ir.Labeled.stmt(s).kind() orelse .labeled) {
                            .@"while", .@"for" => "loop",
                            .match => "labeled `match` (a label makes it a statement)",
                            .raw_block => "labeled `raw` block (a label makes it a statement)",
                            else => "labeled statement",
                        },
                        .drop => "drop",
                        .pass => "`pass`",
                        .@"defer", .@"errdefer" => "deferred statement",
                        else => "jump",
                    };
                    try self.errAt(s, "a function returning `{s}` must end with a value; this {s} produces none", .{ try self.tyName(ret), what });
                    continue;
                }
                const saved_tail = self.results_tail;
                defer self.results_tail = saved_tail;
                if (sema.resultsOf(self.ctx, ret) != null) self.results_tail = resultCall(s) orelse .nil;
                try self.checkTail(s, ret);
            } else {
                try self.checkStmt(s);
            }
        }
    }

    /// A function's last value, which is used (`value_tails`). It is the
    /// function's result, which hands its views to the caller, so a
    /// branch there is not lent where it stands (`checkExpr`).
    fn checkTail(self: *Checker, e: Sexp, ret: TypeId) Error!void {
        try self.noteValueTail(e);
        const mark = self.ctx.diagnostics.items.len;
        try self.checkExprAgainst(e, ret);
        if (self.ctx.diagnostics.items.len == mark) try self.keptLends(e, .returned);
    }

    /// A closure's or a block's last value, which is used.
    fn synthTail(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
        try self.noteValueTail(e);
        if (expected) |ty| {
            try self.checkExpr(e, ty);
            return ty;
        }
        return self.synthExpr(e);
    }

    // =========================================================================
    // Statements
    // =========================================================================

    fn noteValueTail(self: *Checker, e: Sexp) Error!void {
        if (e == .list) try self.value_tails.put(self.ctx.allocator, nodeId(e), {});
    }

    fn checkStmt(self: *Checker, stmt: Sexp) Error!void {
        const head = stmt.kind() orelse return self.checkExprStmt(stmt);
        if (self.isValueLoop(stmt)) {
            try self.errAt(stmt, "the value of this loop is not used; bind it (`x = for ...`) or `break` without a value", .{});
            _ = try self.checkLoopValue(stmt, null, false);
            return;
        }
        switch (head) {
            .set => {
                const mark = self.ctx.diagnostics.items.len;
                try self.checkSet(stmt);
                if (self.ctx.diagnostics.items.len == mark) try self.checkKeptSet(stmt);
            },
            .destructure => try self.checkDestructure(stmt),
            .@"return" => {
                const mark = self.ctx.diagnostics.items.len;
                try self.checkReturn(stmt);
                const value = ir.Return.value(stmt);
                // Each of several results is checked where it is checked.
                if (value != .nil and !value.isKind(.results) and self.ctx.diagnostics.items.len == mark) try self.keptLends(value, .returned);
            },
            .@"if" => _ = try self.checkIfValue(stmt, null, .statement),
            .@"while" => try self.checkWhile(stmt),
            .@"for" => try self.checkFor(stmt),
            .match => _ = try self.checkMatch(stmt, .statement, null),
            .block => {
                const prev = self.enter(stmt);
                defer self.scope = prev;
                for (ir.Block.stmts(stmt)) |c| try self.checkStmt(c);
            },
            .drop => {
                const name = ir.Drop.target(stmt);
                // `<e` of anything but a name drops what it takes, as
                // `_ = <e` does; a lend made there is a view, which takes
                // nothing.
                if (name != .src) {
                    const operand = ir.Move.operand(name);
                    if (operand.isKind(.read) or operand.isKind(.write)) {
                        _ = try self.synthExpr(operand);
                        return self.errAt(stmt, "this expression does nothing as a statement: `{s}` moves a view nowhere, and a view owns nothing to drop", .{self.sourceText(name)});
                    }
                    return self.checkDiscard(name);
                }
                const ty = try self.synthExpr(name);
                if (self.ctx.symbolOf(name)) |id| try self.ctx.recordWrite(stmt, id, .move);
                if (try self.payloadViewTaken(name, "drop")) return;
                // Plain data owns nothing, and ends a loan only when it
                // may hold a view (a `?String` may view a String).
                if (!self.isPoison(ty) and sema.isPlainData(self.ctx, ty) and !sema.mayHoldView(self.ctx, ty)) {
                    try self.errAt(stmt, "`<{s}` drops nothing: `{s}` is plain data", .{ self.text(name), self.text(name) });
                }
            },
            .@"break" => try self.checkBreak(stmt),
            .@"continue" => _ = try self.resolveJump(stmt),
            .pass => {},
            .@"defer", .@"errdefer" => {
                if (head == .@"errdefer") try self.checkErrdeferCanRun(stmt);
                const saved = self.body;
                defer self.body = saved;
                self.body.fail_to = .deferred;
                self.body.loops = null;
                const body = ir.get(stmt, .body);
                try self.checkStmt(body);
                // The statement runs at scope exit: a name it declared
                // would be visible to code that runs before it.
                if (body.isKind(.set) and ir.Set.target(body) == .src) if (self.ctx.symbolOf(ir.Set.target(body))) |id| {
                    const target = ir.Set.target(body);
                    if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                        self.ctx.symbols.items[id].ty = self.t().invalid_id;
                        try self.errAt(target, "a deferred statement runs at scope exit and cannot declare `{s}`; use an indented `{s}` block", .{ self.text(target), @tagName(stmt.kind().?) });
                    }
                };
            },
            .raw_block => {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                try self.checkStmt(ir.RawBlock.body(stmt));
            },
            .labeled => {
                const inner = ir.Labeled.stmt(stmt);
                const label = self.text(ir.Labeled.label(stmt));
                if (inner.isKind(.@"while") or inner.isKind(.@"for")) {
                    self.loop_label = label;
                    return self.checkStmt(inner);
                }
                // Only a loop, a `match`, or a `raw` block has a use for a
                // label; the statement is still checked as if it took one.
                if (inner.isKind(.labeled)) {
                    try self.errAt(stmt, "a loop, `match`, or `raw` block takes one label; `@{s}` labels a statement already labeled `@{s}`", .{ label, self.text(ir.Labeled.label(inner)) });
                } else if (!inner.isKind(.match) and !inner.isKind(.raw_block)) {
                    const prefix = "a label names a loop, `match`, or `raw` block that `break` or `continue` can leave";
                    switch (inner.kind() orelse .labeled) {
                        .@"if" => try self.errAt(stmt, "{s}; `@{s}` cannot label an `if`", .{ prefix, label }),
                        .@"defer" => try self.errAt(stmt, "{s}; `@{s}` cannot label a `defer`", .{ prefix, label }),
                        .@"errdefer" => try self.errAt(stmt, "{s}; `@{s}` cannot label an `errdefer`", .{ prefix, label }),
                        else => try self.errAt(stmt, "{s}; `@{s}` on this statement would do nothing", .{ prefix, label }),
                    }
                }
                var frame: LoopFrame = .{ .label = label, .node = inner, .is_loop = false, .parent = self.body.loops };
                try self.enterFrame(&frame);
                defer self.body.loops = frame.parent;
                try self.checkStmt(inner);
            },
            .fun, .sub, .@"struct", .@"enum", .errors, .type, .generic_struct, .generic_enum, .use, .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .@"test", .@"pub" => {
                try self.errAt(stmt, "declarations are only allowed at module level", .{});
            },
            else => try self.checkExprStmt(stmt),
        }
    }

    /// An `errdefer` runs only when its function fails: one where
    /// nothing can fail would never run.
    fn checkErrdeferCanRun(self: *Checker, stmt: Sexp) Error!void {
        const what = switch (self.body.fail_to) {
            .caller, .module => return,
            .infallible => |name| try self.ctx.arena.allocator().print("`{s}`", .{self.text(name)}),
            .closure => "this closure",
            .deferred => return self.errAt(stmt, "an `errdefer` inside deferred code never runs, since deferred code cannot fail; write its statement in the block directly", .{}),
            .drop => "a `drop` body",
        };
        try self.errAt(stmt, "`errdefer` runs only when the function fails, and {s} cannot fail; use `defer`", .{what});
    }

    /// An expression used as a statement must do something: call, fail
    /// over (`!`, `?`), or handle a failure. One that only reads a value
    /// and drops it is a mistake; a function name was meant as a call.
    fn checkExprStmt(self: *Checker, stmt: Sexp) Error!void {
        // A statement `-x` negates `x` and discards the result; a drop is
        // written `<x`.
        if (stmt.isKind(.neg)) {
            const operand = ir.Neg.operand(stmt);
            const ty = try self.synthExpr(operand);
            // The operand's own error is the one reported.
            if (self.isPoison(ty)) return;
            const owns_or_views = !sema.isPlainData(self.ctx, ty) or sema.mayHoldView(self.ctx, ty);
            const shown = try self.plainText(operand);
            // `<x` is offered only where it drops `x` (`sema.undroppable`,
            // by which the ownership checker rejects it).
            const negates = "this expression does nothing as a statement: `{s}` negates a value and discards it; ";
            const why = sema.undroppable(self.ctx, operand);
            if (why != null and (why.? == .view_param or owns_or_views)) switch (why.?) {
                .view_param => try self.errAt(stmt, negates ++ "a view parameter is not dropped, since the caller owns what it views", .{self.sourceText(stmt)}),
                .capture => try self.errAt(stmt, negates ++ "a closure keeps what it captures for every call, so `{s}` is not dropped here", .{ self.sourceText(stmt), shown }),
                .loop_slot => try self.errAt(stmt, negates ++ "`{s}` views an element the loop walks, which is dropped with what holds it", .{ self.sourceText(stmt), shown }),
            } else if (owns_or_views and sema.handsOver(self.ctx, operand).kind == .place) {
                // `<` takes a binding, or an optional field or element.
                const takes = operand == .src or self.ctx.types.get(ty) == .optional;
                if (takes) {
                    try self.errAt(stmt, "this expression does nothing as a statement; to drop `{s}` now, write `<{s}`", .{ shown, shown });
                } else try self.errAt(stmt, "this expression does nothing as a statement; `{s}` is dropped with what holds it, or replaced by assigning to it", .{shown});
            } else try self.errAt(stmt, "this expression does nothing as a statement: `{s}` negates a value and discards it", .{self.sourceText(stmt)});
            return;
        }
        const saved = self.discarded;
        defer self.discarded = saved;
        self.discarded = stmt;
        try self.ctx.recordDiscard(stmt);
        // A call's several results are discarded whole, as one result is.
        const saved_ok = self.results_ok;
        defer self.results_ok = saved_ok;
        self.results_ok = resultCall(stmt) orelse .nil;
        const ty = try self.synthExpr(stmt);
        // A closure literal alone is reported by the ownership checker.
        if (self.isPoison(ty) or stmt.isKind(.lambda)) return;
        if (!hasEffect(stmt)) {
            // A statement `<e` is a drop everywhere but on a line whose
            // value is used, which a closure's last line is, though this
            // closure gives none.
            if (stmt.isKind(.move)) {
                const shown = try self.plainText(ir.Move.operand(stmt));
                return self.errAt(stmt, "a closure's last line is its value, and so is the last line of a branch that ends it, so `<{s}` here is no drop, and this closure gives no value; to drop `{s}` here, write `_ = <{s}`", .{ shown, shown, shown });
            }
            if (stmt.kind() == null and self.ctx.types.get(ty) == .function)
                return self.errAt(stmt, "`{s}` is a function; call it with `{s}()`", .{ self.text(stmt), self.text(stmt) });
            return self.errAt(stmt, "this expression does nothing as a statement; use its value, or discard it with `_ = ...`", .{});
        }
        if ((try self.needsCleanup(ty, self.startOf(stmt), "discards a value"))) {
            if (sema.resultsOf(self.ctx, ty)) |parts| {
                const shown = self.sourceText(stmt);
                return self.errAt(stmt, "this statement gives the results `{s}`, which own what they must release, and does not use them; bind each (`{s} = {s}`), or drop them now with `_ = {s}`", .{ try self.tyName(ty), try self.resultNames(parts.len), shown, shown });
            }
            try self.errAt(stmt, "this statement makes a `{s}`, which owns what it must release, and does not use it; bind it (`x = ...`), drop it now with `_ = ...`, or move it into a receiver", .{try self.tyName(ty)});
        }
    }

    /// Whether evaluating `e` runs code or leaves: a call, a builtin, a
    /// propagation, or a `catch`. A closure literal inside `e` runs
    /// nothing until it is called.
    fn hasEffect(e: Sexp) bool {
        const kind = e.kind() orelse return false;
        switch (kind) {
            .call, .builtin, .propagate, .propagate_none, .@"catch" => return true,
            .lambda => return false,
            else => {},
        }
        for (rig.children(e)) |c| if (hasEffect(c)) return true;
        return false;
    }

    fn checkReturn(self: *Checker, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        if (value.isKind(.results)) return self.checkReturnResults(node, value);
        // `return f()` gives the several results `f` gives, whole.
        const saved_ok = self.results_ok;
        defer self.results_ok = saved_ok;
        if (sema.resultsOf(self.ctx, self.body.ret) != null) self.results_ok = resultCall(value) orelse .nil;
        if (value != .nil) try self.recordUse(value, .take);
        const ret = self.body.ret;
        if (self.body.fail_to == .deferred) try self.errAt(node, "cannot `return` inside `defer`; the deferred code runs as the function exits", .{});
        if (self.body.returns) |sites| {
            const ty: ?TypeId = if (value == .nil) null else try self.synthExpr(value);
            try sites.append(self.ctx.allocator, .{ .node = node, .ty = ty });
            return;
        }
        if (value == .nil) {
            if (!self.body.is_sub and ret != self.t().void_id and !self.isPoison(ret)) {
                try self.errAt(node, "`return` needs a value of type `{s}`", .{try self.tyName(ret)});
            }
            return;
        }
        if (self.body.is_sub and ret == self.t().void_id) {
            const ty = try self.synthExpr(value);
            if (sema.isErrorSet(self.ctx, ty)) {
                const name = if (self.body.name != .nil) self.text(self.body.name) else "f";
                try self.errAt(value, "a `sub` that cannot fail returns no error; declare it fallible to fail: `sub {s}(...)!`", .{name});
            } else try self.errAt(value, "a `sub` returns no value; remove the value or declare a `fun`", .{});
            return;
        }
        const saved = self.return_operand;
        defer self.return_operand = saved;
        self.return_operand = value;
        try self.checkExpr(value, ret);
    }

    /// Whether `e` is a branch leaf of the `return` operand being
    /// checked, where an error value may meet a `T!`: the operand, or a
    /// branch of a ternary or an arm of a `match` that is a leaf, never
    /// anything deeper.
    fn isReturnLeaf(self: *const Checker, e: Sexp) bool {
        return isBranchLeaf(self.return_operand, e);
    }

    fn isBranchLeaf(value: Sexp, e: Sexp) bool {
        if (sameNode(value, e) or (value == .src and e == .src and value.src.pos == e.src.pos)) return true;
        switch (value.kind() orelse return false) {
            .@"if" => return isBranchLeaf(ir.If.then(value), e) or isBranchLeaf(ir.If.@"else"(value), e),
            .match => for (ir.Match.arms(value)) |arm| {
                if (isBranchLeaf(ir.Arm.body(arm), e)) return true;
            },
            else => {},
        }
        return false;
    }

    // ---- bindings and assignment --------------------------------------------

    /// `_ = e`, and a statement `<e` that drops what it takes: `e` is
    /// taken, and dropped at the statement's end.
    // ---- several results ------------------------------------------------------

    /// `q, r = f()`: the call's several results, each bound to its
    /// target left to right as `x = e` binds `e` (each target but `_` is
    /// `(set op x _ (result_part))`). The value is a call that gives
    /// them, alone or under `!`, `?`, or a fallback that jumps
    /// (docs/INTERNALS.md, "Several results").
    fn checkDestructure(self: *Checker, node: Sexp) Error!void {
        const value = ir.Destructure.value(node);
        const targets = ir.Destructure.targets(node).items();
        if (value.isKind(.results)) return self.parallelAssignment(node, targets, value);
        var ok = try self.checkResultTargets(targets);
        const call = resultCall(value) orelse Sexp.nil;
        if (ok and !self.isResultsValue(value)) {
            try self.errAt(value, "several results are bound from a call that gives them: `{s} = f()`, `f()!`, `f()?`, `f() ?? return`, or `f() catch return`", .{try self.targetNames(targets)});
            _ = try self.synthQuiet(value);
            for (targets) |tg| if (tg.isKind(.set)) try self.poisonTarget(tg);
            return;
        }
        const saved_ok = self.results_ok;
        defer self.results_ok = saved_ok;
        self.results_ok = call;
        try self.recordUse(value, .take);
        // `new q, r = f(q)` reads the `q` it shadows, as `new x = e` does.
        const saved_names = self.pending_names;
        defer self.pending_names = saved_names;
        if (rig.shadows(ir.Destructure.op(node))) {
            var names: std.ArrayList(SymbolId) = .empty;
            for (targets) |tg| if (tg.isKind(.set) and ir.Set.target(tg) == .src) if (self.ctx.symbolOf(ir.Set.target(tg))) |id| {
                try names.append(self.ctx.arena.allocator(), id);
            };
            self.pending_names = names.items;
        }
        const ty = try self.synthExpr(value);
        self.pending_names = saved_names;
        var parts: []const TypeId = &.{};
        if (!self.isPoison(ty)) switch (self.ctx.types.get(ty)) {
            .results => |r| parts = r,
            // Reported where the call is typed (`synthCall`).
            .fallible => ok = false,
            else => if (ok) {
                const name = if (call != .nil) try self.calleeName(ir.Call.callee(call)) else self.sourceText(value);
                const shown = self.sourceText(value);
                if (sema.resultsOf(self.ctx, ty) != null) {
                    try self.errAt(value, "`{s}` gives several results inside an optional, `{s}`: test it first, `{s}?`, `{s} ?? return`, or `if {s} as {s}`", .{ name, try self.tyName(ty), shown, shown, shown, try self.targetNames(targets) });
                } else try self.errAt(value, "`{s}` gives one result, of type `{s}`; bind it to one name", .{ name, try self.tyName(ty) });
                ok = false;
            },
        };
        if (ok and parts.len > 0 and parts.len != targets.len) {
            try self.errAt(value, "`{s}` gives {d} results, but {d} names are bound", .{ try self.calleeName(ir.Call.callee(call)), parts.len, targets.len });
            ok = false;
        }
        const saved_part = self.part_ty;
        defer self.part_ty = saved_part;
        const mark = self.ctx.diagnostics.items.len;
        for (targets, 0..) |tg, j| {
            if (!tg.isKind(.set)) continue;
            self.part_ty = if (ok and j < parts.len) parts[j] else self.t().invalid_id;
            if (ok) try self.checkSet(tg) else try self.poisonTarget(tg);
        }
        // A lend a kept result carries is written (Core sentence 4). A
        // lend to read is kept by a result that only reads, so one is
        // named first.
        if (!ok or parts.len != targets.len or self.ctx.diagnostics.items.len != mark) return;
        var keeper: Sexp = .nil;
        for ([_]bool{ false, true }) |writes| {
            if (keeper != .nil) break;
            for (targets, parts) |tg, part| {
                if (!tg.isKind(.set) or !sema.mayHoldView(self.ctx, part)) continue;
                if (sema.holdsWriteView(self.ctx, part) != writes) continue;
                keeper = tg;
                break;
            }
        }
        if (keeper != .nil) try self.keptLends(value, .{ .binding = self.text(ir.Set.target(keeper)) });
    }

    /// The targets of a destructure: names or `_`, each named once. A
    /// field or element is not one: its indexes would run in the middle
    /// of the bindings. False when one is reported.
    fn checkResultTargets(self: *Checker, targets: []const Sexp) Error!bool {
        var ok = true;
        for (targets, 0..) |tg, j| {
            if (!tg.isKind(.set)) continue;
            const target = ir.Set.target(tg);
            if (target != .src) {
                const shown = self.sourceText(target);
                const reads = for (targets) |o| {
                    if (!o.isKind(.set) or ir.Set.target(o) != .src) continue;
                    const name = self.text(ir.Set.target(o));
                    if (readsNameIn(self.ctx.source, target, name)) break name;
                } else null;
                if (reads) |name| {
                    try self.errAt(target, "each result is bound to a name, and `{s}` reads `{s}`, which this statement binds, so the order would decide what it means: bind a name here, then assign `{s}` on the next line", .{ shown, name, shown });
                } else try self.errAt(target, "each result is bound to a name: bind one here, then assign `{s}` on the next line", .{shown});
                ok = false;
                continue;
            }
            const name = self.text(target);
            for (targets[0..j]) |o| if (o.isKind(.set) and ir.Set.target(o) == .src and std.mem.eql(u8, self.text(ir.Set.target(o)), name)) {
                try self.errAt(target, "`{s}` is bound twice by one statement; bind each result to its own name, or discard one with `_`", .{name});
                ok = false;
                break;
            };
        }
        return ok;
    }

    /// The value of a destructure, by a positive list: a call, alone or
    /// under `!` or `?`, or with a `??` or `catch` fallback that jumps.
    fn isResultsValue(self: *const Checker, value: Sexp) bool {
        _ = self;
        const head = value.kind() orelse return false;
        return switch (head) {
            .call => true,
            .propagate => ir.Propagate.value(value).isKind(.call),
            .propagate_none => ir.PropagateNone.value(value).isKind(.call),
            .@"??" => ir.@"??".left(value).isKind(.call) and isJumpNode(ir.@"??".right(value)),
            .@"catch" => ir.Catch.value(value).isKind(.call) and isJumpNode(ir.Catch.handler(value)),
            else => false,
        };
    }

    /// A destructure target checked after its statement was reported:
    /// its name gets no type, so its uses report nothing more.
    fn poisonTarget(self: *Checker, set: Sexp) Error!void {
        const target = ir.Set.target(set);
        if (target != .src) return;
        const sym = self.ctx.symbolOf(target) orelse return;
        if (self.ctx.symbols.items[sym].decl_pos == target.src.pos) self.ctx.symbols.items[sym].ty = self.t().invalid_id;
        try self.ctx.recordType(ir.Set.value(set), self.t().invalid_id);
    }

    /// `a, b = b, a` and `q, r = 1, 2`: Rig has no parallel assignment.
    fn parallelAssignment(self: *Checker, node: Sexp, targets: []const Sexp, value: Sexp) Error!void {
        const values = ir.Results.values(value);
        for (values) |v| _ = try self.synthExpr(v);
        for (targets) |tg| if (tg.isKind(.set)) try self.poisonTarget(tg);
        // Two names given each other's values: a swap.
        if (targets.len == 2 and values.len == 2 and values[0] == .src and values[1] == .src and targets[0].isKind(.set) and targets[1].isKind(.set)) {
            const a = ir.Set.target(targets[0]);
            const b = ir.Set.target(targets[1]);
            if (a == .src and b == .src and std.mem.eql(u8, self.text(a), self.text(values[1])) and std.mem.eql(u8, self.text(b), self.text(values[0]))) {
                return self.errAt(node, "Rig has no parallel assignment: write `swap(!{s}, !{s})` to exchange two places", .{ self.text(a), self.text(b) });
            }
        }
        try self.errAt(node, "Rig has no parallel assignment: bind each name on its own line; several results come from a call, `{s} = f()`", .{try self.targetNames(targets)});
    }

    /// The targets of a destructure as written: `q, r`.
    fn targetNames(self: *Checker, targets: []const Sexp) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = self.ctx.arena.allocator();
        for (targets, 0..) |tg, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, self.sourceText(if (tg.isKind(.set)) ir.Set.target(tg) else tg));
        }
        return out.items;
    }

    /// The function being checked, for a message: `` `f` ``, or this
    /// closure.
    fn bodyName(self: *Checker) Error![]const u8 {
        if (self.body.name == .nil) return "this closure";
        return self.ctx.arena.allocator().print("`{s}`", .{self.text(self.body.name)});
    }

    /// `n` names for a hint that binds several results: `a, b`.
    fn resultNames(self: *Checker, n: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = self.ctx.arena.allocator();
        for (0..n) |i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.append(a, @as(u8, @intCast(@as(usize, 'a') + @min(i, 25))));
        }
        return out.items;
    }

    /// A call that gives several results, where they may not stand.
    fn misplacedResults(self: *Checker, call: Sexp, ty: TypeId) Error!void {
        const n = sema.resultsOf(self.ctx, ty).?.len;
        const name = try self.calleeName(ir.Call.callee(call));
        if (sameNode(call, self.bound_call)) {
            return self.errAt(call, "`{s}` gives {d} results; bind each: `{s} = {s}`", .{ name, n, try self.resultNames(n), self.sourceText(self.bound_value) });
        }
        // A `for` over an iterator calls its `next` for one value a step.
        const callee = ir.Call.callee(call);
        if (callee.isKind(.member) and rig.isHiddenLeaf(ir.Member.name(callee))) {
            return self.errAt(call, "a `for` binds one value each step, and this iterator's `next` gives {d} results: bind them with `while (!it).next() as {s}`", .{ n, try self.resultNames(n) });
        }
        if (sameNode(call, self.as_call)) {
            return self.errAt(call, "`{s}` gives {d} results: bind each, `if {s} as {s}`", .{ name, n, self.sourceText(call), try self.resultNames(n) });
        }
        if (sameNode(call, self.results_tail)) {
            return self.errAt(call, "several results are given with `return`: `return {s}`", .{self.sourceText(call)});
        }
        try self.errAt(call, "a call that gives several results stands only where each result is bound: `{s} = {s}`", .{ try self.resultNames(n), self.sourceText(call) });
    }

    /// `(a, b)` as a value: Rig has no tuples.
    fn tupleValue(self: *Checker, e: Sexp) Error!TypeId {
        const elems = ir.Tuple.elems(e);
        for (elems) |x| _ = try self.synthExpr(x);
        const src = self.sourceText(e);
        const inner = std.mem.trim(u8, src[1 .. src.len - 1], " ");
        if (sema.resultsOf(self.ctx, self.body.ret) != null) {
            try self.errAt(e, "Rig has no tuple values: give several results with `return {s}`", .{inner});
        } else try self.errAt(e, "Rig has no tuple values: name an object for a group of values, or give a function several results, `-> (A, B)`, with `return {s}`", .{inner});
        return self.t().invalid_id;
    }

    /// `return a, b`: each part is a result, checked as `return x` checks
    /// its value against the result type in its position.
    fn checkReturnResults(self: *Checker, node: Sexp, value: Sexp) Error!void {
        const parts = ir.Results.values(value);
        if (self.body.fail_to == .deferred) try self.errAt(node, "cannot `return` inside `defer`; the deferred code runs as the function exits", .{});
        for (parts) |p| try self.recordUse(p, .take);
        const ret = self.body.ret;
        const tys: ?[]const TypeId = if (self.body.returns != null) null else sema.resultsOf(self.ctx, ret);
        const want = tys orelse {
            for (parts) |p| _ = try self.synthExpr(p);
            // A closure whose result is inferred gives one.
            if (self.body.returns != null) return self.errAt(value, "a closure gives several results only where its type says so: `?fun(...) -> (A, B)`", .{});
            if (self.isPoison(ret)) return;
            if (self.body.is_sub) return self.errAt(value, "a `sub` returns no value; several results are a `fun`'s: `-> (A, B)`", .{});
            return self.errAt(value, "{s} gives one result, of type `{s}`; several are declared `-> (A, B)`", .{ try self.bodyName(), try self.tyName(ret) });
        };
        if (want.len != parts.len) {
            for (parts) |p| _ = try self.synthExpr(p);
            return self.errAt(value, "{s} gives {d} results, but `return` gives {d}", .{ try self.bodyName(), want.len, parts.len });
        }
        const saved = self.return_operand;
        defer self.return_operand = saved;
        for (parts, want) |p, ty| {
            self.return_operand = p;
            const mark = self.ctx.diagnostics.items.len;
            try self.checkExpr(p, ty);
            if (self.ctx.diagnostics.items.len == mark) try self.keptLends(p, .returned);
        }
    }

    fn checkDiscard(self: *Checker, value: Sexp) Error!void {
        try self.recordUse(value, .take);
        _ = try self.synthExpr(value);
    }

    fn checkSet(self: *Checker, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const target = ir.Set.target(node);
        const type_node = ir.Set.type(node);
        const rhs = ir.Set.value(node);
        const saved_bound = .{ self.bound_value, self.bound_call };
        defer self.bound_value, self.bound_call = saved_bound;
        self.bound_value = rhs;
        self.bound_call = resultCall(rhs) orelse .nil;
        // A binding, an assignment, and `_ = e` take the value.
        try self.recordUse(rhs, .take);

        // `(q, r) = f()`: several results are bound by the bare list.
        if (target.isKind(.tuple)) {
            _ = try self.synthQuiet(rhs);
            const src = self.sourceText(target);
            return self.errAt(target, "write `{s} = {s}`; parentheses aren't needed on the left", .{ std.mem.trim(u8, src[1 .. src.len - 1], " "), self.sourceText(rhs) });
        }
        if (target != .src) return self.checkPlaceAssign(kind, target, type_node, rhs);

        const name = self.text(target);
        if (std.mem.eql(u8, name, "_")) {
            // `x op= e` reads `x`.
            if (kind.operator() != null) try self.errAt(target, discard_read, .{});
            if (kind == .fixed) try self.errAt(target, "`_` binds nothing, so it cannot be fixed; discard with `_ = ...`", .{});
            // `_ =` discards the value, so a write call there is a
            // statement's (`isDiscardedCall`).
            const saved = self.discarded;
            defer self.discarded = saved;
            self.discarded = rhs;
            // `_ = f()` discards every result `f` gives.
            const saved_ok = self.results_ok;
            defer self.results_ok = saved_ok;
            self.results_ok = resultCall(rhs) orelse .nil;
            _ = try self.synthExpr(rhs);
            return;
        }
        // A compound assignment names an existing binding.
        const sym_id = self.ctx.symbolOf(target) orelse (try self.useName(target)) orelse {
            _ = try self.synthExpr(rhs);
            return;
        };
        try self.ctx.recordName(target, sym_id);
        // A copy: resolving the annotation may add symbols (`sema.proxyOf`).
        const sym = self.ctx.symbols.items[sym_id];
        const is_decl = sym.decl_pos == target.src.pos;

        // Assigning a view to a `!T` local points it at another place;
        // assigning a value writes the value it views (Core §6). A
        // parameter never changes: a `!T` one only writes through.
        const repoints = !is_decl and sema.assignWritesThrough(self.ctx, sym.ty) and kind == .default and try self.handsOverWriteView(rhs);
        if (repoints and (sym.kind != .local or sym.flags.fixed or sym.flags.pattern_bound or sym.flags.as_bound)) {
            const src = self.sourceText(rhs);
            if (sym.kind == .param) {
                if (sema.writeSliceElem(self.ctx, sym.ty) != null) {
                    try self.errAt(rhs, "cannot point parameter `{s}` at another place: parameters are immutable, and `{s}[i] = v` writes its elements; bind another name to `{s}`", .{ name, name, src });
                } else try self.errAt(rhs, "cannot point parameter `{s}` at another place: parameters are immutable, and `{s} = v` writes the value it views; bind another name to `{s}`", .{ name, name, src });
            } else try self.errAt(rhs, "`{s} = {s}` would point `{s}` at another place, which only a local's own name does; write `new {s} = {s}`", .{ name, src, name, name, src });
            _ = try self.synthExpr(rhs);
            return;
        }
        const writes_through = !repoints and sema.assignWritesThrough(self.ctx, sym.ty);
        // A `![]T` binding views elements it does not own; there is no
        // whole value to write through to.
        if (!is_decl and writes_through and sema.writeSliceElem(self.ctx, sym.ty) != null) {
            try self.errAt(target, "cannot assign to `{s}`, a `{s}` {s}; write its elements with `{s}[i] = v` or `!{s}.copy(src)`", .{ name, try self.tyName(sym.ty), if (sym.kind == .param) "parameter" else "binding", name, name });
            _ = try self.synthExpr(rhs);
            return;
        }
        if (repoints) {
            try self.ctx.recordRepoint(node);
            self.ctx.symbols.items[sym_id].flags.repointed = true;
        }
        // Assigning a binding writes it without reading it; writing
        // through a `!T` binding reaches the viewed value.
        if (!is_decl and (repoints or self.ctx.types.get(sym.ty) != .write_view)) try self.ctx.facts.writes.put(self.ctx.allocator, target.src.pos, {});
        // The binding must be one that may change.
        if (!is_decl and !try self.requireAccess(self.placeOf(target), .assign, target)) {
            if (kind.operator() == null) try self.checkExpr(rhs, if (writes_through) sema.unwrapViews(self.ctx, sym.ty) else sym.ty) else _ = try self.synthExpr(rhs);
            return;
        }

        var declared = self.t().unknown_id;
        if (type_node != .nil) {
            var r = self.resolver();
            declared = try r.resolveType(type_node);
            if (try r.misplacedAt(type_node, declared, .binding)) declared = self.t().invalid_id;
            if (!is_decl and sym.ty != self.t().unknown_id and declared != sym.ty) {
                try self.errAt(target, "`{s}` is already a `{s}`; a later assignment cannot re-annotate it", .{ name, try self.tyName(sym.ty) });
            }
        } else if (!is_decl or sym.ty != self.t().unknown_id) {
            declared = sym.ty;
        }
        // Assigning a `!T` parameter (or the element of `for x in !xs`)
        // writes through to the viewed `T`.
        if (!is_decl and writes_through) switch (self.ctx.types.get(declared)) {
            .write_view => |inner| declared = inner,
            else => {},
        };

        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"+%=", .@"-%=", .@"*%=", .@"+|=", .@"-|=", .@"&=", .@"|=", .@"^=", .@"<<=", .@"<<%=", .@">>=" => {
                const what = try self.ctx.arena.allocator().print("`{s}` has type", .{name});
                try self.checkCompound(kind, declared, rhs, target.src.pos, what);
                try self.ctx.recordType(target, declared);
                return;
            },
            else => {},
        }

        const saved_pending = self.pending;
        defer self.pending = saved_pending;
        if (rig.shadows(ir.Set.op(node))) self.pending = sym_id;
        var rhs_ty: TypeId = undefined;
        if (!self.isPoison(declared) or type_node != .nil) {
            const saved_target = self.static_target;
            const saved_value = self.static_target_value;
            defer {
                self.static_target = saved_target;
                self.static_target_value = saved_value;
            }
            if (!is_decl and type_node == .nil and declared == self.t().static_id) {
                self.static_target = name;
                self.static_target_value = rhs;
            }
            try self.checkExpr(rhs, declared);
            rhs_ty = declared;
        } else {
            rhs_ty = try self.synthExpr(rhs);
            // A binding holds the write view a call or a lend hands over
            // (`yieldsWriteView`), as `w: !T = e` does, so assigning it
            // writes through (Core §6). A bare name or place only reads
            // (Core sentence 1): a name, field, element, or loop value of
            // type `!T`, or a branching value of them, binds the value it
            // reaches when that copies (`sema.copiedThrough`). A read view
            // is copied, but one of a scalar binds the scalar
            // (`readValue`).
            const holds_write_view = self.ctx.types.get(rhs_ty) == .write_view and try self.yieldsWriteView(rhs);
            if (!rhs.isKind(.read) and !holds_write_view) rhs_ty = try self.readThrough(rhs, rhs_ty, bindingValue(self.ctx, rhs_ty));
            rhs_ty = try self.defaultBindingType(rhs, rhs_ty, name);
        }

        const s = &self.ctx.symbols.items[sym_id];
        // A rejected annotation or initializer leaves the binding without
        // a type, which later uses do not report again.
        if (s.ty == self.t().unknown_id) s.ty = if ((type_node != .nil and self.isPoison(declared)) or rhs_ty == self.t().unknown_id) self.t().invalid_id else rhs_ty;
        if (is_decl and s.scope == self.module_scope and sema.holdsCallable(self.ctx, s.ty)) {
            try self.errAt(target, "a callable view `{s}` lives only as long as what it views, so it cannot be a module-level binding", .{try self.tyName(s.ty)});
            s.ty = self.t().invalid_id;
        }
        // A module constant's ternary over constants is constant too, so
        // a later constant may branch on it.
        const ternary_const = s.scope == self.module_scope and rhs.isKind(.@"if") and self.isConstExpr(rhs);
        if (kind == .fixed and (ternary_const or self.isComptimeKnown(rhs))) s.flags.comptime_known = true;
        // A `=!` local of a value the target sets is set by it too.
        if (s.flags.comptime_known and s.scope != self.module_scope and sema.perTargetLeaf(self.ctx, rhs) != null) s.flags.per_target = true;
        // `k =! n` stands for the compile-time parameter `n` where an
        // array length or a compile-time argument names it.
        if (kind == .fixed and is_decl and s.kind == .local) if (try self.ctParamOf(rhs)) |ct| try self.ctx.ct_locals.put(self.ctx.allocator, sym_id, ct);
        try self.ctx.recordType(target, s.ty);
        // A binding that never changes keeps a constant value.
        // (A module constant's was folded before any type was resolved.)
        if (is_decl and s.kind == .local and s.scope != self.module_scope and !s.flags.reassigned and !s.flags.written and sema.isInteger(self.ctx, s.ty)) {
            if (self.constInt(rhs)) |v| try self.ctx.const_ints.put(self.ctx.allocator, sym_id, .{ .value = v, .int = switch (self.ctx.types.get(s.ty)) {
                .int => |i| i,
                else => .{},
            } });
        }
    }

    /// Whether `rhs` hands over a write view where it is assigned: `!m`
    /// lends one, `<w` moves one, and a call or branching value of type
    /// `!T` yields one. A bare name or path of type `!T` reads the value
    /// it reaches.
    fn handsOverWriteView(self: *Checker, rhs: Sexp) Error!bool {
        const kind = rhs.kind() orelse return false;
        return switch (kind) {
            .write => true,
            .member, .index => false,
            else => self.ctx.types.get(try self.argType(rhs)) == .write_view,
        };
    }

    /// The type an unannotated binding gets from its initializer.
    fn defaultBindingType(self: *Checker, rhs: Sexp, ty: TypeId, name: []const u8) Error!TypeId {
        const pos = self.startOf(rhs);
        switch (self.ctx.types.get(ty)) {
            .int_literal => {
                try self.defaultIntLiteral(rhs);
                return self.t().int_id;
            },
            .float_literal => return self.t().float_id,
            .void => {
                try self.err(pos, "`{s}` would be bound to a value of type `Void`; this expression produces no value", .{name});
                return self.t().invalid_id;
            },
            .none_literal => {
                try self.err(pos, "cannot infer the type of `none`; annotate the binding (`{s}: T? = none`)", .{name});
                return self.t().invalid_id;
            },
            .noreturn => {
                try self.err(pos, "`{s}` would be bound to an expression that never produces a value", .{name});
                return self.t().invalid_id;
            },
            else => {
                if (sema.callableFn(self.ctx, ty) == null and sema.holdsCallable(self.ctx, ty)) {
                    try self.err(pos, sema.held_callable, .{try self.tyName(ty)});
                    return self.t().invalid_id;
                }
                return ty;
            },
        }
    }

    /// `obj.field = v`, `xs[i] = v`, `f(x) = v` where the call returns a
    /// write view (also `f(x)! = v` and `f(x)? = v`), and compound forms.
    fn checkPlaceAssign(self: *Checker, kind: rig.BindingKind, target: Sexp, type_node: Sexp, rhs: Sexp) Error!void {
        const head = target.kind();
        const through = storage.assignedThrough(target);
        if (head != .member and head != .index and !through) {
            if (head == .propagate or head == .propagate_none) {
                _ = try self.synthExpr(ir.get(target, .value));
                try self.errAt(target, "cannot assign to `{s}`: only a call that returns a write view (`!T`), or that call's `!` or `?`, is assigned through", .{self.sourceText(target)});
            } else try self.errAt(target, "cannot assign to this expression", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        if (type_node != .nil) {
            try self.errAt(type_node, "a field or element assignment cannot carry a type annotation", .{});
        }
        switch (kind) {
            .fixed, .shadow => {
                try self.errAt(target, "`{s}` binds a name; a field or element can only be assigned with `=`", .{if (kind == .fixed) "=!" else "new"});
                _ = try self.synthExpr(rhs);
                return;
            },
            else => {},
        }
        const place_ty = try self.synthExpr(target);
        if (through) return self.assignThroughCall(kind, target, place_ty, rhs);
        if (try self.rejectLane(target, .assign)) {
            _ = try self.synthExpr(rhs);
            return;
        }
        const place = self.placeOf(target);
        if (place.cell_list_elem) |elem| {
            if (!sameNode(elem, target) or kind.operator() != null) {
                try self.errAt(target, "an element of a Cell's List is written whole, with `c[i] = e`: copy it out, change the copy, and write it back", .{});
                _ = try self.synthExpr(rhs);
                return;
            }
            if (self.isPoison(place_ty)) {
                _ = try self.synthExpr(rhs);
                return;
            }
            // The Cell changes, so the lend that changes it is written,
            // unless a write view of it already stands there.
            const cell = ir.get(elem, .object);
            const cell_ty = self.ctx.typeOf(cell) orelse sema.type_invalid;
            if (!place.marked and self.ctx.types.get(cell_ty) != .write_view and self.lendOf(place.base) == null) {
                try self.errAt(target, "write `(!{s})[i] = e`: changing a shared Cell is marked with `!`", .{try self.plainText(cell)});
                _ = try self.synthExpr(rhs);
                return;
            }
            return self.checkExpr(rhs, place_ty);
        }
        if (!try self.requireAccess(place, .assign, target)) {
            _ = try self.synthExpr(rhs);
            return;
        }
        // Assigning an element drops the value it held, as assigning a
        // field does; a generic body's element of a `T` needs each
        // instance to own nothing.
        if (head == .index) _ = try self.needsCleanup(place_ty, self.startOf(target), "overwrites an element");
        if (kind.operator() != null) return self.checkCompound(kind, place_ty, rhs, self.startOf(target), "this place has type");
        try self.checkExpr(rhs, place_ty);
    }

    /// `f(x) = v` or `f(x) op= v`, where the call returns a write view
    /// `!T`, and so `f(x)! = v` and `f(x)? = v` of a call that returns a
    /// fallible or optional one (`storage.assignedThrough`): the `T` the
    /// view reaches is written, as `__v: T = v; w = f(x); w op= __v`
    /// writes it through a hidden binding `w` (Core §6). The value runs
    /// first, then the call, as any target's base does
    /// (`storage.eachSetStep`). A call that returns a value, a read view,
    /// or a `![]T` is not assigned through.
    fn assignThroughCall(self: *Checker, kind: rig.BindingKind, target: Sexp, view_ty: TypeId, rhs: Sexp) Error!void {
        if (self.isPoison(view_ty)) {
            _ = try self.synthExpr(rhs);
            return;
        }
        const viewed = switch (self.ctx.types.get(view_ty)) {
            .write_view => |inner| inner,
            .read_view => {
                try self.errAt(target, "cannot assign through a read view (`?T`), which this call returns; a call that returns a write view (`!T`) is assigned through", .{});
                _ = try self.synthExpr(rhs);
                return;
            },
            else => {
                const name = try self.tyName(view_ty);
                try self.errAt(target, "cannot assign to a call's result, {s} `{s}`; only a write view (`!T`) a call returns is assigned through", .{ article(name), name });
                _ = try self.synthExpr(rhs);
                return;
            },
        };
        if (sema.writeSliceElem(self.ctx, view_ty) != null) {
            try self.errAt(target, "cannot assign to a `{s}` a call returns; write its elements with `{s}[i] = v`", .{ try self.tyName(view_ty), self.sourceText(target) });
            _ = try self.synthExpr(rhs);
            return;
        }
        if (!try self.requireAccess(self.placeOf(target), .assign, target)) {
            _ = try self.synthExpr(rhs);
            return;
        }
        if (kind.operator() != null) return self.checkCompound(kind, viewed, rhs, self.startOf(target), "the value this call's write view reaches has type");
        try self.checkExpr(rhs, viewed);
    }

    /// `x op= e` is `x = x op e` with `x` evaluated once, and `x` keeps its
    /// type: arithmetic needs a numeric target, bitwise operators and
    /// shifts an integer one. `e` has the target's type, except a shift
    /// amount, which may be any integer.
    fn checkCompound(self: *Checker, kind: rig.BindingKind, target_ty: TypeId, rhs: Sexp, pos: u32, what: []const u8) Error!void {
        const op = kind.operator().?;
        const spelled = @tagName(kind);
        if (self.isPoison(target_ty)) {
            _ = try self.synthExpr(rhs);
            return;
        }
        const req: Requirement = switch (op) {
            .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|" => .integer,
            else => .numeric,
        };
        if (sema.simdOf(self.ctx, target_ty) != null) return self.simdCompound(op, spelled, sema.unwrapViews(self.ctx, target_ty), rhs, pos);
        const tv: ?SymbolId = switch (self.ctx.types.get(target_ty)) {
            .type_var => |tv| tv,
            else => null,
        };
        if (tv) |param| {
            try self.require(param, req, pos, spelled);
        } else if (!(if (req == .integer) sema.isInteger(self.ctx, target_ty) else sema.isNumeric(self.ctx, target_ty))) {
            try self.err(pos, "`{s}` requires {s} target; {s} `{s}`", .{ spelled, if (req == .integer) "an integer" else "a numeric", what, try self.tyName(target_ty) });
            _ = try self.synthExpr(rhs);
            return;
        }
        if (op == .@"<<" or op == .@"<<%" or op == .@">>") {
            _ = try self.checkShiftAmount(rhs, target_ty, spelled);
            return;
        }
        if (tv) |param| {
            // A generic `T` target takes another `T` or a literal it holds.
            const ty = try self.synthOperandValue(rhs);
            if (self.meetsTypeVar(target_ty, ty, req)) {
                try self.requireHoldsLiteral(param, ty, rhs, pos, spelled);
            } else if (!self.isPoison(ty)) try self.mismatch(rhs, target_ty, ty);
        } else try self.checkExpr(rhs, target_ty);
        _ = try self.checkDivisor(op, target_ty, rhs);
    }

    // ---- places -------------------------------------------------------------

    /// What is done with a place: written by assignment, `!p`, or
    /// `for x in !p`; emptied by `<p.f`; where it holds a `!T`, lent on
    /// (by `!p.f`, or passed where a value holding a `!T` goes) or
    /// written through; or, where it is a Cell, changed in place.
    const Access = enum {
        assign,
        lend_write,
        write_iterate,
        take,

        /// How a diagnostic names the access: "cannot {head} <object>{tail}".
        fn verb(a: Access) Verb {
            return switch (a) {
                .assign => .{ .head = "assign to" },
                .lend_write => Verb.lend_to_write,
                .write_iterate => .{ .head = "write-iterate" },
                .take => .{ .head = "take" },
            };
        }
    };

    /// The verb of a diagnostic about an access, around its object:
    /// "cannot lend `x` to write".
    const Verb = struct {
        head: []const u8,
        tail: []const u8 = "",

        const lend_to_write: Verb = .{ .head = "lend", .tail = " to write" };
    };

    /// Where a place starts.
    const Root = enum {
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
    /// enum's `.text`, or a field another module declared read-only; or
    /// a `?T` on the way.
    /// Where several apply, the first in that order.
    const Block = enum {
        shared,
        slice,
        string,
        len,
        /// `e.text`, the name of a plain enum value's variant.
        text,
        /// A field another module declared `pub ?name: T`.
        read_only,
        read_view,

        fn rank(b: Block) u2 {
            return switch (b) {
                .shared => 0,
                .slice, .string, .len, .text, .read_only => 1,
                .read_view => 2,
            };
        }
    };

    /// A place expression (a name, or a field or element of one),
    /// classified once from the recorded types of the objects along its
    /// path (`a` and `a.b` in `a.b.c`).
    const Place = struct {
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
        /// The path starts at a lend to write, `(!c)[i]`.
        marked: bool = false,
        /// A read view, a slice, a `?String`, or a `.len` stands between the
        /// path's end and the shared handle it crosses (or its base, if
        /// it crosses none).
        leaf_blocked: bool = false,
        /// A read view of something other than a handle stands on the path:
        /// nothing changes through it, a Cell behind a handle included.
        view_blocked: bool = false,
        /// The path crosses a shared handle (`sema.accessThroughShared`).
        crossed: bool = false,

        /// A name, or a field or element of one: storage with an owner.
        fn named(p: Place) bool {
            return p.base == .src and !p.sliced;
        }

        /// A name, or a chain of fields off one: `v`, `t.kids`, `a.b.c`.
        fn fieldPath(p: Place) bool {
            return p.base == .src and p.fields_only;
        }

        fn block(p: *Place, why: Block, pos: u32) void {
            if (p.blocked) |b| if (b.why.rank() <= why.rank()) return;
            p.blocked = .{ .why = why, .pos = pos };
        }
    };

    /// The place `e` names, read once (`Place`).
    fn placeOf(self: *Checker, e: Sexp) Place {
        var place: Place = .{ .node = e };
        var crossed = false;
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) : (place.steps += 1) {
            const step = p;
            const index = step.isKind(.index);
            p = ir.get(step, .object);
            if (index) place.fields_only = false else place.module_member = step;
            if (index and rig.isRangeIndex(step)) place.sliced = true;
            const ty = self.ctx.typeOf(p) orelse continue;
            const inner = sema.unwrapViews(self.ctx, ty);
            const obj = self.ctx.types.get(inner);
            if (index) {
                if (place.cell_list_elem == null and cellListElement(self.ctx, ty) != null) place.cell_list_elem = step;
                const is_text = obj == .string_view or obj == .static;
                if (is_text or (obj == .slice and sema.writeSliceElem(self.ctx, ty) == null)) {
                    place.block(if (is_text) .string else .slice, self.startOf(p));
                    if (!crossed) place.leaf_blocked = true;
                }
            } else if (self.ctx.readOnlyFieldOf(step)) |field| {
                place.block(.read_only, self.startOf(ir.Member.name(step)));
                if (place.blocked.?.why == .read_only) place.read_only = field;
                if (!crossed) place.leaf_blocked = true;
            } else if (self.ctx.isEnumText(step)) {
                place.block(.text, self.startOf(ir.Member.name(step)));
                if (!crossed) place.leaf_blocked = true;
            } else if (std.mem.eql(u8, self.text(ir.Member.name(step)), "len") and (obj == .slice or obj == .string_view or obj == .static or obj == .string or obj == .array or listElementType(self.ctx, inner) != null or cellListElement(self.ctx, inner) != null)) {
                place.block(.len, self.startOf(ir.Member.name(step)));
                if (!crossed) place.leaf_blocked = true;
            }
            switch (self.ctx.types.get(ty)) {
                .read_view => |viewed| {
                    place.indirect = true;
                    place.block(.read_view, self.startOf(p));
                    // A view of a handle views the handle, not what it
                    // reaches.
                    if (self.ctx.types.get(viewed) != .shared) {
                        place.leaf_blocked = true;
                        place.view_blocked = true;
                    }
                },
                // A write view of a value that holds a Cell views shared
                // storage, which only its Cells and Signals change in
                // (`sema.changesByMark`).
                .write_view => |viewed| {
                    place.indirect = true;
                    if (sema.holdsCellByValue(self.ctx, viewed)) place.block(.shared, 0);
                },
                // A slice views elements held elsewhere.
                .shared, .slice => place.indirect = true,
                else => {},
            }
            if (sema.accessThroughShared(self.ctx, ty)) {
                crossed = true;
                place.crossed = true;
                place.block(.shared, 0);
            }
        }
        place.base = p;
        place.pos = self.startOf(p);
        if (self.lendOf(p)) |lend| place.marked = lend.isKind(.write);
        if (p == .src) {
            place.sym = self.ctx.symbolOf(p);
            if (place.sym) |id| place.root = self.rootOf(self.ctx.symbols.items[id]);
        } else if (self.ctx.typeOf(p)) |ty| if (!self.isPoison(ty)) {
            // A handle reaches its owner's value; one no binding holds is
            // itself the temporary a view of it would change.
            place.root = switch (self.ctx.types.get(ty)) {
                .read_view, .write_view => .view,
                .shared => if (place.steps == 0) .temporary else .view,
                else => .temporary,
            };
        };
        return place;
    }

    /// Where a place that starts at binding `sym` starts.
    fn rootOf(self: *Checker, sym: sema.Symbol) Root {
        return switch (sym.kind) {
            .param => .param,
            .capture => .capture,
            .module => .module,
            .local => if (sym.scope == self.module_scope)
                (if (sym.flags.fixed) .constant else .global)
            else if (sym.flags.pattern_bound and self.ctx.types.get(sym.ty) != .write_view) .pattern else .local,
            else => .other,
        };
    }

    /// Whether a lend to write of `place` is the marked call of a change
    /// through a shared handle: the place is a handle that changes by a
    /// marked call (the handle is lent, not rebound), or a Cell, a
    /// Signal, or a value that holds a Cell, reached through a handle
    /// with no read view between it and the handle.
    fn lendsMarked(self: *Checker, place: Place) bool {
        const ty = self.ctx.typeOf(place.node) orelse return false;
        return sema.changesByMark(self.ctx, ty) and !place.leaf_blocked;
    }

    /// Whether a lend to write of `place` writes none of what holds the
    /// handle it reaches: it is a handle that changes by a marked call, or
    /// a Cell, Signal, or value holding a Cell reached through one.
    fn lendsPath(self: *Checker, place: Place) bool {
        return self.lendsHandle(place) or (place.crossed and self.lendsMarked(place));
    }

    /// Whether the handle `place` names may be written where it stands,
    /// so that a lend of it may be the handle's own: `requireAccess` with
    /// no exemption for a handle that changes by a marked call.
    fn handleWritable(self: *Checker, place: Place, operand: Sexp) bool {
        const mark = self.ctx.diagnostics.items.len;
        const saved = self.handle_exempt;
        self.handle_exempt = false;
        defer self.handle_exempt = saved;
        self.ctx.quiet += 1;
        defer self.ctx.quiet -= 1;
        const ok = self.requireAccess(place, .lend_write, operand) catch false;
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        return ok;
    }

    /// Whether `place` is a handle that changes by a marked call
    /// (`sema.changesByMark`), which `!` lends without writing the handle.
    fn lendsHandle(self: *Checker, place: Place) bool {
        const ty = self.ctx.typeOf(place.node) orelse return false;
        return !place.view_blocked and self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .shared and sema.changesByMark(self.ctx, ty);
    }

    /// Whether `place` may be used as `access` asks. Nothing is written
    /// through a `*T` or a `?T`, or into an element of a `[]T` or a
    /// `?String`, or a `.len`; a temporary would lose the change; and
    /// without a view or handle on the way, the binding the path starts
    /// from must be one that may change (`requireBinding`). A diagnostic
    /// with no better position is at `at`. False after a diagnostic.
    fn requireAccess(self: *Checker, place: Place, access: Access, at: Sexp) Error!bool {
        const verb = access.verb();
        if (place.blocked) |b| {
            const through: Verb = if (access == .assign) .{ .head = "assign" } else verb;
            // A handle that changes by a marked call is lent, wherever it
            // is held: the lend writes neither the slice nor the view that
            // holds the handle, nor what it reaches.
            if (access == .lend_write and self.handle_exempt and self.lendsHandle(place)) return true;
            switch (b.why) {
                // A Cell or a Signal changes through the handle by a
                // marked call, a lend to write.
                .shared, .read_view => if (access == .lend_write and (self.handle_exempt or !self.lendsHandle(place)) and self.lendsMarked(place)) {
                    return true;
                } else if (b.why == .read_view) {
                    const hint = try self.readMatchHint(place.sym);
                    if (hint.len > 0) {
                        try self.err(b.pos, "cannot {s}{s} through a read view (`?T`){s}", .{ through.head, through.tail, hint });
                    } else try self.err(b.pos, "cannot {s}{s} through a read view (`?T`); take a write view (`!T`) to mutate", .{ through.head, through.tail });
                } else if (access == .assign and place.cell_list_elem != null and place.marked) {
                    return true;
                } else if (access == .assign and place.cell_list_elem != null) {
                    const cell = ir.get(place.cell_list_elem.?, .object);
                    try self.errAt(at, "write `(!{s})[i] = e`: changing a shared Cell is marked with `!`", .{try self.plainText(cell)});
                } else if (access == .assign and cellElementType(self.ctx, self.ctx.typeOf(place.node) orelse sema.type_invalid) != null) {
                    const shown = try self.plainText(place.node);
                    try self.errAt(at, "cannot assign through a shared handle (`*T`); other handles may exist. `{s}` is a Cell: change its value with `!{s}.set(...)`", .{ shown, shown });
                } else try self.errAt(at, "cannot {s}{s} through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.", .{ through.head, through.tail }),
                .slice => try self.err(b.pos, "cannot {s}{s} through a slice; a `[]T` is read-only{s}", .{ through.head, through.tail, try self.readMatchHint(place.sym) }),
                .string => try self.err(b.pos, "cannot {s} a byte of a `?String`{s}; a `?String` is read-only", .{ verb.head, verb.tail }),
                .len => try self.err(b.pos, "cannot {s} `.len`{s}; a length is read-only", .{ verb.head, verb.tail }),
                .text => try self.err(b.pos, "cannot {s} `.text`{s}; a variant's name is read-only", .{ verb.head, verb.tail }),
                .read_only => {
                    const f = place.read_only.?;
                    try self.err(b.pos, "cannot {s} `{s}`{s}: field `{s}` of `{s}` is read-only outside module `{s}`, which declares it `pub ?{s}`", .{ verb.head, try self.plainText(place.node), verb.tail, f.field, f.owner, f.module, f.field });
                },
            }
            return false;
        }
        if (place.root == .temporary) {
            switch (access) {
                // `!` lends any value to write: the temporary is held in
                // its statement's slot (`lendsToWrite`).
                .lend_write => return true,
                .assign => try self.errAt(at, "cannot assign to a field or element of a temporary; bind the value first (`t = ...`), then assign to `t`", .{}),
                .take => try self.errAt(at, "cannot take out of a temporary: nothing would see it emptied; bind it to a name first", .{}),
                else => try self.errAt(at, "cannot {s}{s} a temporary; bind it to a name first", .{ access.verb().head, access.verb().tail }),
            }
            return false;
        }
        if (place.indirect) return true;
        // A handle that changes by a marked call is lent, not rebound,
        // so the binding that holds it need not be writable.
        if (access == .lend_write and self.handle_exempt and place.steps == 0 and self.lendsHandle(place)) return true;
        return self.requireBinding(place, access);
    }

    /// Whether the binding `place` starts from may be written: a
    /// parameter or capture only when it is a `!T`; a fixed binding or
    /// constant never; a loop or pattern binding only when it holds a
    /// write view of a place it may write, or owns a resource moved
    /// into it, and never when assigned whole. (Reassigning a fixed
    /// binding is the ownership checker's to report.) False after a
    /// diagnostic.
    fn requireBinding(self: *Checker, place: Place, access: Access) Error!bool {
        const id = place.sym orelse return true;
        const sym = self.ctx.symbols.items[id];
        const name = sym.name;
        const root = place.root;
        const verb: Verb = switch (access) {
            else => access.verb(),
        };
        const pos = place.pos;
        // Another module's bindings are its constants. (Their types are
        // in that module's store.)
        if (root == .module) {
            const leaf = self.text(ir.Member.name(place.module_member orelse return true));
            const foreign = self.foreignLookup(id, leaf) orelse return true;
            if (foreign.sym.kind != .local) return true;
            try self.err(pos, "cannot {s} constant `{s}.{s}`{s}", .{ verb.head, name, leaf, verb.tail });
            return false;
        }
        const whole = access == .assign and place.steps == 0;
        const writes = self.ctx.types.get(sym.ty) == .write_view;
        const poison = self.isPoison(sym.ty);
        switch (root) {
            .param => if (poison) {
                return false;
            } else if (!writes) {
                if (std.mem.eql(u8, name, "self")) {
                    try self.err(pos, "cannot {s} parameter `self`{s}; parameters are immutable (take `!self` to write through to the caller)", .{ verb.head, verb.tail });
                } else try self.err(pos, "cannot {s} parameter `{s}`{s}; parameters are immutable (bind a copy with `new {s} = {s}`, or take `{s}: !{s}` to write through to the caller)", .{ verb.head, name, verb.tail, name, name, name, try self.tyName(sema.unwrapViews(self.ctx, sym.ty)) });
                return false;
            },
            // A captured write view is lent on, as a `!T` parameter is.
            .capture => if (!writes and !poison) {
                try self.err(pos, "cannot {s} captured `{s}`{s}; captures are fixed when the closure is created", .{ verb.head, name, verb.tail });
                return false;
            },
            // A fixed write view is lent and written through, never
            // pointed elsewhere.
            .constant, .local => if (sym.flags.fixed and !writes) {
                if (whole) return true;
                if (root == .constant) {
                    try self.err(pos, "cannot {s} constant `{s}`{s}", .{ verb.head, name, verb.tail });
                } else try self.err(pos, "cannot {s} fixed binding `{s}`{s} (bound with `=!`)", .{ verb.head, name, verb.tail });
                return false;
            } else if (sym.flags.pattern_bound) {
                // A write view a match that only reads its subject binds
                // is read through too.
                const from = self.copied_from.get(id) orelse return true;
                if (from.kind != .match_copy and from.kind != .match_read) return true;
                const shown = try self.plainText(from.place);
                try self.err(pos, "cannot {s} `{s}`{s}: `match {s}{s}` reads `{s}`, and so do its bindings; to write through `{s}`, {s}", .{ verb.head, name, verb.tail, if (from.kind == .match_read) "?" else "", shown, shown, name, try self.writeMatchAdvice(from.place) });
                return false;
            },
            .pattern => if (!poison) {
                // An `as` or `match <x` binding of a value that moves,
                // moved into it, is not a copy: its fields can be written
                // and taken.
                const owned = sym.flags.as_bound or self.owned_bindings.contains(id);
                if (!whole and owned and sema.moves(self.ctx, sym.ty) == .yes) return true;
                if (self.copied_from.get(id)) |from| {
                    const shown = try self.plainText(from.place);
                    switch (from.kind) {
                        .loop => try self.err(pos, "cannot {s} `{s}`{s}: it is a copy of an element of `{s}`; to change the elements in place, loop with `for {s} in !{s}`", .{ verb.head, name, verb.tail, shown, name, shown }),
                        .as => try self.err(pos, "cannot {s} `{s}`{s}: it is a copy of the value inside `{s}`; to change that value in place, bind it with `!{s} as {s}`", .{ verb.head, name, verb.tail, shown, shown, name }),
                        .match_copy, .match_read => try self.err(pos, "cannot {s} `{s}`{s}: it is {s} of {s}`{s}`; to change {s} in place, {s}", .{ verb.head, name, verb.tail, if (from.kind == .match_copy and sema.moves(self.ctx, sym.ty) != .yes and self.ctx.types.get(sym.ty) != .read_view) "a copy" else "a read view", if (from.whole) "" else "a field of ", shown, if (from.whole) "it" else "the field", try self.writeMatchAdvice(from.place) }),
                    }
                    return false;
                }
                if (sema.moves(self.ctx, sym.ty) == .yes) {
                    try self.err(pos, "cannot {s} `{s}`{s}; loop and pattern bindings are immutable (move it into a new binding with `new {s} = <{s}`)", .{ verb.head, name, verb.tail, name, name });
                } else try self.err(pos, "cannot {s} `{s}`{s}; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ verb.head, name, verb.tail, name, name });
                return false;
            },
            else => {},
        }
        return true;
    }

    /// Synthesize without reporting diagnostics (the full check reports them).
    fn synthQuiet(self: *Checker, e: Sexp) Error!TypeId {
        const mark = self.ctx.diagnostics.items.len;
        self.ctx.quiet += 1;
        defer self.ctx.quiet -= 1;
        const ty = try self.synthExpr(e);
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        return ty;
    }

    // ---- conditionals and loops ---------------------------------------------

    const Position = enum { statement, value };

    /// Returns the if's type in value position.
    fn checkIfValue(self: *Checker, node: Sexp, expected: ?TypeId, position: Position) Error!TypeId {
        const cond = ir.If.cond(node);
        const then_node = ir.If.then(node);
        const else_node = ir.If.@"else"(node);

        const prev = self.scope;
        // A ternary or a postfix guard has no block to bind a name for.
        const saved_hold = self.no_hold;
        self.no_hold = saved_hold or position == .value;
        const saved_cond = self.ternary_cond;
        if (position == .value) self.ternary_cond = cond;
        if (!self.isBlockIf(node) and rig.bindsInCondition(cond)) {
            try self.checkExpr(cond, self.t().bool_id);
        } else try self.checkCondition(cond);
        self.ternary_cond = saved_cond;
        self.no_hold = saved_hold;
        const then_ty = try self.branch(then_node, expected, position);
        self.scope = prev;

        if (position == .statement) {
            if (else_node != .nil) _ = try self.branch(else_node, expected, position);
            return self.t().void_id;
        }
        if (else_node == .nil) {
            try self.errAt(then_node, "`if` used as a value requires an `else` branch", .{});
            return self.t().invalid_id;
        }
        const else_ty = try self.branch(else_node, expected, position);
        if (expected) |e| return e;
        const u = (try self.unify(then_ty, else_ty, self.startOf(else_node))) orelse return self.t().invalid_id;
        // All-literal branches take their type from the context later.
        if (u == self.t().int_literal_id or u == self.t().float_literal_id) return u;
        try self.adaptLiteral(then_node, then_ty, u);
        try self.adaptLiteral(else_node, else_ty, u);
        return u;
    }

    /// A branch or element whose value is a literal (`int_literal`) takes
    /// the type the others settled on, and must fit it.
    fn adaptLiteral(self: *Checker, node: Sexp, ty: TypeId, target: TypeId) Error!void {
        var value = node;
        while (value.isKind(.block) and ir.Block.stmts(value).len > 0) {
            const stmts = ir.Block.stmts(value);
            value = stmts[stmts.len - 1];
        }
        // All-literal branches still yield an `Int` (or `Float`).
        try self.recordAdapted(value, ty, self.canonical(target));
    }

    fn branch(self: *Checker, node: Sexp, expected: ?TypeId, position: Position) Error!TypeId {
        if (position == .statement) {
            try self.checkStmt(node);
            return self.t().void_id;
        }
        if (expected) |e| {
            try self.checkExpr(node, e);
            return e;
        }
        return self.synthExpr(node);
    }

    /// A Bool condition, or one that binds (`rig.bindsInCondition`): its
    /// parts in order, each `(as expr name)` entering the scope that
    /// binds `name`; the caller restores the scope.
    fn checkCondition(self: *Checker, cond: Sexp) Error!void {
        const saved_hold = self.no_hold;
        defer self.no_hold = saved_hold;
        if (rig.isConditionJoin(cond)) self.no_hold = true;
        const Parts = struct {
            c: *Checker,
            pub fn part(v: @This(), p: Sexp) Error!void {
                if (p.isKind(.as)) return v.c.checkOptionalBinding(p);
                if (p.isKind(.as_results)) return v.c.checkResultsBinding(p);
                return v.c.checkExpr(p, v.c.t().bool_id);
            }
            pub fn join(v: @This(), j: Sexp) Error!void {
                return v.c.ctx.recordType(j, v.c.t().bool_id);
            }
        };
        try rig.eachGuardPart(cond, Parts{ .c = self });
    }

    /// The guard parts of a condition (`rig.eachGuardPart`), in order.
    fn guardParts(self: *Checker, cond: Sexp) Error![]const Sexp {
        const Parts = struct {
            list: std.ArrayList(Sexp) = .empty,
            a: std.mem.Allocator,
            pub fn part(v: *@This(), p: Sexp) Error!void {
                try v.list.append(v.a, p);
            }
        };
        var parts: Parts = .{ .a = self.ctx.arena.allocator() };
        try rig.eachGuardPart(cond, &parts);
        return parts.list.items;
    }

    /// The step of `while cond: step` cannot use a binding of `cond` that
    /// moves, which the body owns and which ends before the step runs,
    /// or a view the condition binds, which lives only in the body.
    fn checkStepUses(self: *Checker, cond: Sexp, step: Sexp) Error!void {
        for (try self.guardParts(cond)) |p| {
            // The results `as` binds live only in the body.
            if (p.isKind(.as_results)) for (ir.AsResults.names(p).items()) |n| {
                if (!n.isKind(.set)) continue;
                const b = self.ctx.symbolOf(ir.Set.target(n)) orelse continue;
                const use = sema.findUse(self.ctx, step, b) orelse continue;
                try self.errAt(use, "the loop step cannot use `{s}`, a result the condition binds, which lives only in the body; use it at the end of the body instead", .{self.ctx.symbols.items[b].name});
            };
            if (!p.isKind(.as)) continue;
            const b = self.ctx.symbolOf(ir.As.name(p)) orelse continue;
            const sym = self.ctx.symbols.items[b];
            const use = sema.findUse(self.ctx, step, b) orelse continue;
            if (sema.isReadOrWriteView(self.ctx, sym.ty)) {
                try self.errAt(use, "the loop step cannot use `{s}`: it is a view (`{s}`) that lives only in the body; use it at the end of the body instead", .{ sym.name, try self.tyName(sym.ty) });
            } else if (try self.mustTake(sym.ty, self.startOf(use), "uses in a loop step a binding")) {
                try self.errAt(use, "the loop step cannot use `{s}`: the body owns this `{s}`, which ends with the body before the step runs", .{ sym.name, try self.tyName(sym.ty) });
            }
        }
    }

    /// A step that reads a binding of the condition runs inside the `if`s
    /// that bind it, after the body (`storage.StepPoint.after_body`,
    /// docs/INTERNALS.md, "Loops"), so every binding there stays until the
    /// step is done: each must be plain data (neither a view nor owning),
    /// and no `continue` in the condition, which would go on past the
    /// step (`resolveJump`), may skip binding one.
    fn checkStepBindings(self: *Checker, frame: *const LoopFrame, loop: Sexp) Error!void {
        if (storage.stepPoint(self.ctx, loop) != .after_body) return;
        const step = ir.While.step(loop);
        const parts = try self.guardParts(ir.While.cond(loop));
        var read: ?Sexp = null;
        for (parts) |p| if (p.isKind(.as)) if (self.ctx.symbolOf(ir.As.name(p))) |b| {
            if (sema.findUse(self.ctx, step, b)) |use| read = use;
        };
        const use = read orelse return;
        const name = self.text(use);
        if (frame.cond_continues.items.len > 0) return self.errAt(use, "the loop step reads `{s}`, a binding of the condition, which a `continue` in the condition leaves unbound", .{name});
        for (parts) |p| {
            if (!p.isKind(.as)) continue;
            const b = self.ctx.symbolOf(ir.As.name(p)) orelse continue;
            const sym = self.ctx.symbols.items[b];
            if (self.isPoison(sym.ty)) continue;
            if (sema.isReadOrWriteView(self.ctx, sym.ty) or sema.moves(self.ctx, sym.ty) == .yes) {
                return self.errAt(use, "the loop step reads `{s}`, a binding of the condition, so each binding there must be plain data; `{s}` is a `{s}`", .{ name, sym.name, try self.tyName(sym.ty) });
            }
        }
    }

    /// Whether `node` is a block `if` (`if c` then a block), not a
    /// ternary `a if c else b` or a postfix guard `stmt if c`, which
    /// start with their value or statement.
    fn isBlockIf(self: *Checker, node: Sexp) bool {
        // Without the Parser wrapper's spans, every `if` is taken for a
        // block.
        if (self.ctx.parser == null) return true;
        const at = self.ctx.span(node).start;
        const src = self.ctx.source;
        if (!std.mem.startsWith(u8, src[at..], "if")) return false;
        return at + 2 >= src.len or !(std.ascii.isAlphanumeric(src[at + 2]) or src[at + 2] == '_');
    }

    /// Whether the call on `recv`, returning `returns`, has a value that
    /// is used: anywhere but a statement, alone or under `!`, `?`, or
    /// `catch` (`isDiscardedCall`). Such a write call is written
    /// `(!s).m(...)`, so its `!` never reads as negation.
    fn usesValue(self: *Checker, recv: Sexp, returns: TypeId) bool {
        const result = self.ctx.types.get(returns);
        const value = if (result == .fallible) result.fallible else returns;
        return value != self.t().void_id and !self.isDiscardedCall(recv);
    }

    /// The write call a hint writes for `method` on the receiver `recv`,
    /// written `place`: `!place.m`, or `(!place).m` where the call's
    /// value is used (`usesValue`).
    fn writeCall(self: *Checker, recv: Sexp, place: []const u8, method: []const u8, returns: TypeId) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        return if (self.usesValue(recv, returns)) a.print("(!{s}).{s}", .{ place, method }) else a.print("!{s}.{s}", .{ place, method });
    }

    /// The whole write call a hint writes for `method` on `recv`, as
    /// written but for its receiver: `!v.push(1)`, or `(!v).pop()` where
    /// its value is used (`writeCall`).
    fn writeCallText(self: *Checker, recv: Sexp, method: []const u8, returns: TypeId) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        const bare = receiverPlace(recv);
        const place = try self.plainText(bare);
        const lent = if (sigilReaches(bare)) try a.print("!{s}", .{place}) else try a.print("!({s})", .{place});
        return self.callWith(recv, if (self.usesValue(recv, returns)) try a.print("({s})", .{lent}) else lent, method);
    }

    /// The call being checked (`current_call`), written with its
    /// receiver `recv` (with any sigil before it) as `with`: `<c.take()`
    /// for `c.take()`. Without that call, `with.method(...)`.
    fn callWith(self: *Checker, recv: Sexp, with: []const u8, method: []const u8) Error![]const u8 {
        if (self.current_call) |c| {
            const callee = ir.Call.callee(c);
            if (callee.isKind(.member) and sameSite(ir.Member.object(callee), recv)) {
                // A receiver written in parentheses, `(mk() if c else
                // d).m()`: `with` takes their place.
                const call = self.ctx.span(c);
                const r = self.ctx.span(recv);
                const src = self.ctx.source;
                if (r.start > call.start and r.end + 1 < call.end and src[r.start - 1] == '(' and src[r.end] == ')' and src[r.end + 1] == '.') {
                    return std.mem.concat(self.ctx.arena.allocator(), u8, &.{ src[call.start .. r.start - 1], with, src[r.end + 1 .. call.end] });
                }
                return self.spliced(c, &.{recv}, &.{with});
            }
        }
        return self.ctx.arena.allocator().print("{s}.{s}(...)", .{ with, method });
    }

    /// Whether `recv` is the receiver of a call whose value is
    /// discarded: the expression statement, or the value of `_ =`, or the
    /// operand of a `!`, `?`, or `catch` that is, or is that operand in
    /// turn.
    fn isDiscardedCall(self: *const Checker, recv: Sexp) bool {
        var e = self.discarded;
        while (true) switch (e.kind() orelse return false) {
            .propagate => e = ir.Propagate.value(e),
            .propagate_none => e = ir.PropagateNone.value(e),
            .@"catch" => e = ir.Catch.value(e),
            .call => {
                const callee = ir.Call.callee(e);
                return callee.isKind(.member) and sameExpr(ir.Member.object(callee), recv);
            },
            else => return false,
        };
    }

    /// `if expr as name` / `while expr as name`: `expr` is an optional,
    /// and `name` holds the value inside it. A resource moves into the
    /// binding, which owns it; it cannot be copied out of a place. Over
    /// a view of an optional (`?o`, `!o`, a `?T?` parameter), `name`
    /// views the value inside the same way: a write view always, a
    /// read view when the value owns a resource (plain data is copied).
    fn checkOptionalBinding(self: *Checker, node: Sexp) Error!void {
        const expr = ir.As.value(node);
        const name = ir.As.name(node);
        // The header binds the value inside: it takes the optional.
        try self.recordUse(expr, .take);
        // A part of a value made here is bound in that value, which the
        // `if` holds (`Header.held`).
        const saved_held = self.held_base;
        defer self.held_base = saved_held;
        if (!self.no_hold) self.held_base = self.madeBase(expr);
        const saved_as = self.as_call;
        self.as_call = resultCall(expr) orelse .nil;
        const ty = try self.synthExpr(expr);
        self.as_call = saved_as;
        var inner = self.t().invalid_id;
        if (!self.isPoison(ty)) switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .optional => |i| inner = i,
            else => try self.errAt(expr, "`as` binds the value inside an optional; this expression has type `{s}`", .{try self.tyName(ty)}),
        };
        const through_view = sema.unwrapViews(self.ctx, ty) != ty;
        // A branch the header reads where it stands is lent there.
        if (!self.isPoison(inner) and !try self.headerLendsBranch(headerSubject(expr))) inner = self.t().invalid_id;
        // How the binding reaches the value inside, from which its access
        // and type follow (`bindAsView`).
        var reach: sema.AsReach = .copied;
        if (through_view and !self.isPoison(inner) and !sema.isReadOrWriteView(self.ctx, inner)) {
            // `!o`, or a fresh write view (a call's result, `<w`).
            const writes = self.ctx.types.get(ty) == .write_view;
            if (try sema.makesWriteView(self.ctx, expr)) {
                reach = .written;
            } else if (try self.cannotCopy(inner, self.startOf(expr), "moves out of a view a value")) {
                if (writes) {
                    // A held write view is lent on visibly, as `!o`; one a
                    // temporary of the header holds ends with the header.
                    if (sema.firstStmtTemp(self.ctx, expr)) |temp| {
                        try self.errAt(expr, "`as` over a write view in a header that makes a temporary, `{s}`, which ends with the header: bind it to a name first, then lend the value inside with `!`", .{self.sourceText(temp)});
                    } else try self.errAt(expr, "`as` over a write view lends it on: write `!{s}` to lend the value inside", .{self.sourceText(expr)});
                    try self.ctx.recordType(expr, self.t().invalid_id);
                    inner = self.t().invalid_id;
                } else reach = .read;
            } else _ = try self.reachThrough(expr, ty, sema.unwrapViews(self.ctx, ty));
        } else {
            _ = try self.reachThrough(expr, ty, sema.unwrapViews(self.ctx, ty));
            // A view inside an optional reached through a read view or a
            // handle is bound to read, a write view included.
            // A view inside an optional is bound to write where the header
            // makes the write view (`!o`), and to read where it is reached
            // through a read view or a handle.
            if (through_view and !self.isPoison(inner) and sema.isReadOrWriteView(self.ctx, inner)) switch (self.ctx.types.get(ty)) {
                .read_view, .shared => reach = .read,
                .write_view => if (try sema.makesWriteView(self.ctx, expr)) {
                    reach = .written;
                },
                else => {},
            };
        }
        // A place whose value is not plain data is bound where it stands,
        // as `if ?o as x` binds it; a part of a made value where the `if`
        // holds that value (docs/INTERNALS.md, "Header subjects").
        var viewed = false;
        if (!through_view and !self.isPoison(inner) and sema.copies(self.ctx, inner) == .no) switch (self.hands(expr).kind) {
            .place => {
                viewed = true;
                try self.ctx.recordHeader(node, .viewed, .nil);
                try self.ctx.recordImplicitLend(expr);
            },
            .part_of_made => if (self.held_base != .nil) {
                if (try self.holdsHeld(expr)) {
                    viewed = true;
                    try self.ctx.recordHeader(node, .held, self.held_base);
                } else inner = self.t().invalid_id;
            } else {
                try self.errAt(expr, "`as` binds the value inside a place or takes one made here: bind this `{s}` to a name first", .{try self.tyName(ty)});
                inner = self.t().invalid_id;
            },
            .made, .lend, .branches, .jump, .none => {},
        };
        // A part of plain data is read in the header, as any value is.
        if (!viewed and self.held_base != .nil) try self.releaseHeld();
        if (viewed) reach = .read;
        // What the binding views, unless it owns a value made here or
        // taken with `<`, may be a copy (`rejectHeaderCopy`).
        const owns = expr.isKind(.move) or (self.hands(expr).kind == .made and !through_view);
        if (reach == .copied and owns) reach = .taken;
        const access = self.asAccess(reach, inner);
        inner = try self.viewOfAccess(access, inner);
        if (!owns and !self.isPoison(inner)) try self.rejectHeaderCopy(node, expr, inner);
        _ = self.enter(node);
        if (self.ctx.symbolOf(name)) |sym| {
            self.ctx.symbols.items[sym].access = access;
            self.ctx.symbols.items[sym].flags.access_decided = true;
            self.ctx.symbols.items[sym].ty = inner;
            // A read binding of a place's value, which `if !o as x` writes.
            if (access == .read and viewed) try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = expr, .kind = .as });
            try self.ctx.recordType(name, inner);
            if (!through_view and !viewed and self.hands(expr).hasStorage()) try self.copied_from.put(self.ctx.allocator, sym, .{ .place = expr, .kind = .as });
        }
    }

    /// `if f() as a, b` / `while f() as a, b`: `f()` gives several
    /// results inside an optional, `(A, B)?`, and each name binds one of
    /// them, taken, as a destructure's target does (`checkDestructure`).
    fn checkResultsBinding(self: *Checker, node: Sexp) Error!void {
        const value = ir.AsResults.value(node);
        const names = ir.AsResults.names(node).items();
        var ok = try self.checkResultTargets(names);
        // A header's temporaries end with it, before its body runs, and a
        // result `_` discarded there would drop after them: each result
        // is bound to a name, which the body owns.
        for (names) |n| if (!n.isKind(.set)) {
            try self.errAt(n, "`as` binds each result to a name: name this one, and where the body does not use it, discard it there with `_ = name`", .{});
            ok = false;
        };
        try self.recordUse(value, .take);
        const saved_ok = self.results_ok;
        defer self.results_ok = saved_ok;
        if (value.isKind(.call)) self.results_ok = value;
        const ty = try self.synthExpr(value);
        var parts: []const TypeId = &.{};
        if (ok and !self.isPoison(ty)) {
            const inner = switch (self.ctx.types.get(ty)) {
                .optional => |i| i,
                else => self.t().invalid_id,
            };
            switch (self.ctx.types.get(inner)) {
                .results => |r| parts = r,
                else => {
                    try self.errAt(value, "`as` binds several names to the results inside an optional, `(A, B)?`, that a call gives; this expression has type `{s}`", .{try self.tyName(ty)});
                    ok = false;
                },
            }
        }
        if (ok and parts.len > 0 and parts.len != names.len) {
            try self.errAt(value, "`{s}` gives {d} results, but {d} names are bound", .{ try self.calleeName(ir.Call.callee(value)), parts.len, names.len });
            ok = false;
        }
        _ = self.enter(node);
        const saved_part = self.part_ty;
        defer self.part_ty = saved_part;
        for (names, 0..) |n, j| {
            if (!n.isKind(.set)) continue;
            self.part_ty = if (ok and j < parts.len) parts[j] else self.t().invalid_id;
            if (ok) try self.checkSet(n) else try self.poisonTarget(n);
        }
    }

    /// The frame of the loop being entered, which takes the pending label
    /// and value.
    fn enterLoop(self: *Checker, frame: *LoopFrame, node: Sexp) Error!void {
        frame.* = .{ .label = self.loop_label, .node = node, .value = self.loop_value, .parent = self.body.loops };
        self.loop_label = "";
        self.loop_value = null;
        try self.enterFrame(frame);
    }

    /// Make `frame` the innermost around the code being checked, and
    /// record the jumps that name its construct (`sema.eachJumpTo`).
    fn enterFrame(self: *Checker, frame: *LoopFrame) Error!void {
        const Record = struct {
            c: *Checker,
            node: Sexp,
            pub fn jump(r: @This(), j: Sexp) Error!void {
                try r.c.jump_targets.put(r.c.ctx.allocator, nodeId(j), r.node);
            }
        };
        try sema.eachJumpTo(self.ctx.source, frame.node, frame.label, Record{ .c = self, .node = frame.node });
        self.body.loops = frame;
    }

    /// A loop's `else`, after the loop: a `break` there leaves the loop
    /// around it. In a loop used as a value, it is the value when no
    /// `break` gives one.
    fn checkLoopElse(self: *Checker, frame: *LoopFrame, else_: Sexp) Error!void {
        self.body.loops = frame.parent;
        if (else_ == .nil) return;
        if (frame.value) |lv| return self.loopValue(lv, else_);
        try self.checkStmt(else_);
    }

    fn checkWhile(self: *Checker, node: Sexp) Error!void {
        var frame: LoopFrame = undefined;
        try self.enterLoop(&frame, node);
        defer frame.cond_continues.deinit(self.ctx.allocator);
        const prev = self.scope;
        const cond = ir.While.cond(node);
        const step = ir.While.step(node);
        frame.has_step = step != .nil;
        frame.part = .cond;
        const saved_hold = self.no_hold;
        self.no_hold = true;
        try self.checkCondition(cond);
        self.no_hold = saved_hold;
        frame.part = .step;
        const call_step = step.isKind(.call) or (step.isKind(.propagate) and ir.Propagate.value(step).isKind(.call));
        if (step != .nil and !step.isKind(.set) and !call_step) {
            // `while x ?? break :outer`, a label in the old spelling: the
            // name reads as the step.
            const jump = if (step == .src) bareJumpAtEnd(cond) else null;
            if (jump) |j| {
                try self.errAt(step, "a label is written `@name`: the `:` in a `while` header starts the step, so `{s}` reads as the step; to name a label, write `{s} @{s}`", .{ self.text(step), j, self.text(step) });
            } else try self.errAt(step, "a `while` step is an assignment or a call", .{});
        } else if (step != .nil) {
            try self.checkStmt(step);
            // The step runs after the body, which would see a name it
            // declares before it has a value.
            if (step.isKind(.set) and ir.Set.target(step) == .src) if (self.ctx.symbolOf(ir.Set.target(step))) |id| {
                const target = ir.Set.target(step);
                if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                    try self.errAt(target, "a `while` step runs after the body, so it cannot declare `{s}`; declare it before the loop", .{self.text(target)});
                }
            };
            const mark = self.ctx.diagnostics.items.len;
            try self.checkStepUses(cond, step);
            if ((rig.isConditionJoin(cond) or cond.isKind(.as)) and self.ctx.diagnostics.items.len == mark) try self.checkStepBindings(&frame, node);
        }
        try self.settleConditionJumps(&frame);
        frame.part = .body;
        try self.checkStmt(ir.While.body(node));
        self.scope = prev;
        try self.checkLoopElse(&frame, ir.While.@"else"(node));
    }

    fn checkFor(self: *Checker, node: Sexp) Error!void {
        var frame: LoopFrame = undefined;
        try self.enterLoop(&frame, node);
        frame.part = .source;
        const mode = ir.For.mode(node).tag;
        const binding = ir.For.@"var"(node);
        const index_binding = ir.For.index(node);
        const source = ir.For.source(node);

        if (index_binding != .nil and source.isKind(.@"..")) {
            try self.errAt(index_binding, "a range has no index binding; the element is already the position (`for i in a..b`)", .{});
        }

        var elem_ty = self.t().invalid_id;
        self.loop_access = null;
        // The loop's mode once a bare source is classified.
        var eff = mode;
        // A held source was rejected (`holdsHeld`).
        var elem_poisoned = false;
        if (source.isKind(.@"..")) {
            // Both bounds are integers of one type, the element's.
            elem_ty = try self.checkIntDefaultOperands(source, "..", .integer, null);
            try self.ctx.recordType(source, try self.ctx.intern(.{ .range = elem_ty }));
        } else {
            const peeled_source = if (source.isKind(.read)) ir.Read.operand(source) else source;
            // A part of a value made here is walked in that value, which
            // the loop holds (`Header.held`).
            const saved_held = self.held_base;
            defer self.held_base = saved_held;
            if (mode == .iter) self.held_base = self.madeBase(source);
            // `for x in ?xs[a..b]` walks a slice of `xs`.
            const saved_outer = self.outer_write;
            const saved_loop = self.outer_write_is_loop;
            if (mode == .write and source.isKind(.call)) {
                self.outer_write = source;
                self.outer_write_is_loop = true;
            }
            var source_ty = if ((mode == .read or mode == .write) and rig.isRangeIndex(source))
                try self.lendSlice(source, if (mode == .read) .read else .write)
            else
                try self.synthExpr(source);
            // A `for` over an iterator is the `while` it means (`iterLoop`).
            if (try self.iterLoop(node, source, mode, source_ty)) {
                self.outer_write = saved_outer;
                self.outer_write_is_loop = saved_loop;
                elem_ty = self.t().invalid_id;
            } else {
                // `for x in <e` moves `e` as `<e` does.
                if (mode == .move and !self.isPoison(source_ty)) _ = try self.rejectMadeParts(source, source);
                self.outer_write = saved_outer;
                self.outer_write_is_loop = saved_loop;
                // A branch the loop walks where it stands is lent there, as
                // its mode lends it (`for x in ?S`, `for x in !S`) or read.
                if (mode != .move and !self.isPoison(source_ty) and !try self.headerLendsBranch(.{ .node = peeled_source, .sigil = switch (mode) {
                    .read => .read,
                    .write => .write,
                    else => null,
                } })) {
                    // Reported once: the loop has no source to walk.
                    source_ty = self.t().invalid_id;
                    elem_poisoned = true;
                }
                // How the loop has a bare source (docs/INTERNALS.md, "Header
                // subjects"): a place is walked where it stands, as
                // `for x in ?p`; an array made here whose elements move is
                // taken, as `for x in <e`; a part of a made value is walked
                // where the loop holds that value.
                const source_hands = self.hands(source);
                if (mode == .iter and !self.isPoison(source_ty)) switch (source_hands.kind) {
                    .place => {
                        eff = .read;
                        try self.ctx.recordHeader(node, .viewed, .nil);
                    },
                    .part_of_made => if (self.held_base != .nil and sema.copies(self.ctx, source_ty) == .no) {
                        eff = .read;
                        if (try self.holdsHeld(source)) {
                            try self.ctx.recordHeader(node, .held, self.held_base);
                        } else elem_poisoned = true;
                    },
                    .made => if (self.ctx.types.get(source_ty) == .array and sema.copies(self.ctx, self.ctx.types.get(source_ty).array.elem) == .no) {
                        eff = .move;
                        try self.ctx.recordHeader(node, .taken, .nil);
                    },
                    .lend, .branches, .jump, .none => {},
                };
                // A part of plain data is read in the header, as any value is.
                if (self.held_base != .nil and self.ctx.headerOf(node) != .held and !elem_poisoned) try self.releaseHeld();
                // A loop walks a place, or takes a value made here. A branching
                // value that may be a name's (`o?`, `a if c else mk()`) may be
                // a place on one path and a new value on another, which one
                // loop cannot both view and take, unless its elements copy.
                const peeled_hands = self.hands(peeled_source);
                const unbound = (!peeled_hands.hasStorage() and peeled_hands.kind != .made) or (mode == .iter and peeled_hands.kind == .part_of_made and self.held_base == .nil);
                const list = listElementType(self.ctx, source_ty) != null;
                const moving = list or switch (self.ctx.types.get(sema.unwrapViews(self.ctx, source_ty))) {
                    .array => |a| sema.copies(self.ctx, a.elem) == .no,
                    else => false,
                };
                // A List whose elements move is reported by `elementTypeForLoop`.
                const list_moves = if (listElementType(self.ctx, sema.unwrapViews(self.ctx, source_ty))) |e| sema.moves(self.ctx, e) == .yes else false;
                if (mode != .move and unbound and !list_moves and (if (mode == .iter) moving else list) and !self.isPoison(source_ty)) {
                    const what = if (list) "a List held in a place or made by a call" else "a place or takes a value made here";
                    try self.errAt(peeled_source, "a `for` walks {s}: bind this `{s}` to a name first", .{ what, try self.tyName(source_ty) });
                }
                self.loop_access = null;
                elem_ty = try self.elementTypeForLoop(source, peeled_source, source_ty, eff);
                if (elem_poisoned) elem_ty = self.t().invalid_id;
                // What the loop binds views the source, unless it takes it or
                // walks a slice of it, and may view a copy (`rejectHeaderCopy`).
                // The source is a header: a temporary it reads into ends with
                // it, before the loop walks it.
                const walks_temp = if (eff != .move and !self.isPoison(elem_ty)) self.tempBase(source) else null;
                if (walks_temp) |temp| {
                    try self.errAt(temp, "the loop would walk the temporary `{s}` after its header drops it; bind it to a name first", .{self.sourceText(temp)});
                } else if (eff != .move and !rig.isRangeIndex(source) and !self.isPoison(source_ty)) try self.rejectHeaderCopy(node, source, elem_ty);
                // `for x in ?e` and `for x in !e` lend `e`: one made here would
                // end with the header. A call's result is taken: `for x in e`.
                if ((mode == .read or mode == .write) and !(unbound and list) and !source_hands.hasStorage() and !self.isPoison(source_ty) and !self.isPoison(elem_ty) and sema.moves(self.ctx, sema.unwrapViews(self.ctx, source_ty)) == .yes) {
                    try self.errAt(source, "the loop would walk a view of the temporary `{s}` after its header drops it; take it with `for {s} in {s}`, or bind it to a name first", .{ self.sourceText(source), self.text(binding), self.sourceText(source) });
                }
            }
        }

        {
            const prev = self.enter(node);
            defer self.scope = prev;
            if (self.ctx.symbolOf(binding)) |sym| {
                self.ctx.symbols.items[sym].access = if (self.isPoison(elem_ty)) null else self.loop_access;
                self.ctx.symbols.items[sym].flags.access_decided = true;
                self.ctx.symbols.items[sym].ty = elem_ty;
                try self.ctx.recordType(binding, elem_ty);
                if (sema.forViewsSlot(self.ctx, node)) self.ctx.symbols.items[sym].flags.slot_view = true;
                // An element of an array the loop takes is the body's own.
                if (eff == .move and !source.isKind(.@"..")) try self.owned_bindings.put(self.ctx.allocator, sym, {});
                if ((mode == .iter or mode == .read) and !source.isKind(.@"..") and self.hands(source).hasStorage() and !sema.isReadOrWriteView(self.ctx, elem_ty)) try self.copied_from.put(self.ctx.allocator, sym, .{ .place = source, .kind = .loop });
            }
            if (self.ctx.symbolOf(index_binding)) |sym| {
                self.ctx.symbols.items[sym].ty = self.t().int_id;
                try self.ctx.recordType(index_binding, self.t().int_id);
                if (self.ctx.symbolOf(binding)) |elem| {
                    const pair: LoopPair = .{ .elem = elem, .index = sym, .source = source };
                    try self.loop_pairs.put(self.ctx.allocator, elem, pair);
                    try self.loop_pairs.put(self.ctx.allocator, sym, pair);
                }
            }
            frame.part = .body;
            try self.checkStmt(ir.For.body(node));
        }
        try self.checkLoopElse(&frame, ir.For.@"else"(node));
    }

    /// Whether a `for` source of type `ty` is an iterator: the one decision
    /// (docs/INTERNALS.md, "Loops over an iterator"). A positive list: a
    /// struct or enum the program declares, or a std one (not a `List`, an
    /// array, a slice, a `?String`, or a range, which keep their own
    /// meaning), that declares `next(!self) -> T?`. A type with a `next`
    /// of another shape is `.malformed`, so the mistake is reported where
    /// the loop is.
    const IterShape = union(enum) { not_iterator, malformed: []const u8, iterator };

    fn iteratorShape(self: *Checker, ty: TypeId) Error!IterShape {
        const peeled = sema.unwrapViews(self.ctx, ty);
        switch (self.ctx.types.get(peeled)) {
            .nominal, .imported_nominal => {},
            .parameterized_nominal => if (listElementType(self.ctx, peeled) != null) return .not_iterator,
            else => return .not_iterator,
        }
        const next = (try self.findMethod(peeled, "next")) orelse return .not_iterator;
        if (next.field.receiver != .write) return .{ .malformed = switch (next.field.receiver) {
            .read => "takes `?self`",
            .value => "takes `<self`",
            else => "takes no `self`",
        } };
        if (next.fn_ty.params.len != 1) return .{ .malformed = "takes more than `self`" };
        if (self.ctx.types.get(next.fn_ty.returns) != .optional) return .{ .malformed = "does not give an optional" };
        return .iterator;
    }

    /// Whether a bare `for x in it` over an iterator in a place advances it,
    /// or the advance must be written `for x in !it`. The one switch.
    const bare_place_advances = false;

    /// What to write for a `for` over an iterator made here. One that
    /// holds no view is held by the loop (`for x in mk()`); one that views
    /// a place (`b.each()`) keeps it lent, so it is bound first with the
    /// lend written, then advanced in place.
    fn madeIteratorFix(self: *Checker, head: []const u8, shown: []const u8, source_ty: TypeId) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        if (sema.holdsMarkedView(self.ctx, source_ty)) return a.print("it views a place it keeps lent, so bind it first: `it = ?{s}`, then `{s}!it`", .{ shown, head });
        return a.print("write `{s}{s}`, which holds it for the loop", .{ head, shown });
    }

    /// Whether the `?` of the `for` loop `node` reaches the receiver of
    /// its source's first method call (`Parser.loopReceiverSource`).
    fn loopLendsReceiver(self: *Checker, node: Sexp) bool {
        const p = self.ctx.parser orelse return false;
        return p.loopReceiverSource(node) != null;
    }

    /// A method call on a name or fields from one (`b.each()`), where a
    /// sigil written before it reaches that place.
    fn receiverCall(source: Sexp) bool {
        if (!source.isKind(.call)) return false;
        const callee = ir.Call.callee(source);
        if (!rig.isMethodCallee(callee)) return false;
        const member = if (callee.isKind(.member)) callee else ir.get(callee, .object);
        return isFieldPath(ir.Member.object(member));
    }

    /// A name, or fields from one: the places a loop over an iterator
    /// advances where they stand.
    fn isFieldPath(e: Sexp) bool {
        return e == .src or (e.isKind(.member) and isFieldPath(ir.Member.object(e)));
    }

    /// A `for` over an iterator `it` is the `while` it means: it is
    /// recorded (`SemContext.iter_loops`) and the module checked again on
    /// the rewritten tree (`rig.Parser.desugarIterLoops`), so this pass
    /// binds nothing for it. Returns whether the source is an iterator.
    fn iterLoop(self: *Checker, node: Sexp, source: Sexp, mode: Tag, source_ty: TypeId) Error!bool {
        if (self.isPoison(source_ty)) return false;
        switch (try self.iteratorShape(source_ty)) {
            .not_iterator => return false,
            .malformed => |why| {
                try self.errAt(source, "cannot iterate over `{s}`: a `for` walks a type with `next(!self) -> T?`, but its `next` {s}", .{ try self.tyName(source_ty), why });
                return true;
            },
            .iterator => {},
        }
        const shown = self.sourceText(source);
        const name = self.text(ir.For.@"var"(node));
        // A bare `for xs` hints in its own form: `for !it`, not `for _ in !it`.
        const head = if (self.startOf(ir.For.@"var"(node)) == self.startOf(node))
            try self.ctx.allocator.dupe(u8, "for ")
        else
            try std.fmt.allocPrint(self.ctx.allocator, "for {s} in ", .{name});
        const index = ir.For.index(node);
        if (index != .nil) {
            const bang: []const u8 = if (self.hands(source).kind == .place) "!" else "";
            try self.errAt(index, "an iterator has no index binding; keep a count in the loop: `for {s} in {s}{s}`", .{ name, bang, shown });
            return true;
        }
        // A place is evaluated again for each `next`, so it is a name or a
        // field path, which names one place however the body runs; an
        // element, whose index the body may change, is bound first.
        const kind = self.hands(source).kind;
        if (kind == .place and !isFieldPath(source)) {
            try self.errAt(source, "a `for` advances an iterator named by a name or a field path (`it`, `a.b`); bind `{s}` to a name first", .{shown});
            return true;
        }
        const how: rig.IterSource = switch (mode) {
            // `for x in ?b.each()`: the `?` reaches the call's receiver,
            // `(?b).each()`, and the loop holds the iterator it makes.
            .read, .write => if (kind == .made and self.loopLendsReceiver(node)) .lent else if (mode == .read) {
                if (kind == .made) {
                    try self.errAt(source, "`{s}?{s}` would only read an iterator made here, which `next` cannot advance; {s}", .{ head, shown, try self.madeIteratorFix(head, shown, source_ty) });
                } else try self.errAt(source, "`{s}?{s}` would only read an iterator, which `next` cannot advance; write `{s}!{s}` to advance it in place", .{ head, shown, head, shown });
                return true;
            } else if (kind == .place) .place else {
                if (kind == .made and receiverCall(source)) {
                    // A method that writes its receiver is reported where
                    // it is called, with `(!b).drain()` to write; any
                    // other method's iterator is held with `?`.
                    const callee = ir.Call.callee(source);
                    const writes = if (self.methods.get(nodeId(callee))) |m| m.receiver == .write else false;
                    if (!writes) try self.errAt(source, "`!{s}` advances a place, and this is a value made here, which holds no write view; write `{s}?{s}`, which holds it for the loop", .{ shown, head, shown });
                } else if (kind == .made) {
                    try self.errAt(source, "`!{s}` advances a place, and this is a value made here; {s}", .{ shown, try self.madeIteratorFix(head, shown, source_ty) });
                } else try self.errAt(source, "a `for` walks an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
                return true;
            },
            .move => if (kind == .place) .moved else if (kind == .made) .made else {
                try self.errAt(source, "a `for` takes an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
                return true;
            },
            else => switch (kind) {
                .place => if (bare_place_advances) .place else {
                    try self.errAt(source, "write `{s}!{s}`: the loop advances `{s}`", .{ head, shown, shown });
                    return true;
                },
                .made => .made,
                else => {
                    try self.errAt(source, "a `for` walks an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
                    return true;
                },
            },
        };
        if (self.ctx.parser == null) {
            try self.errAt(source, "a `for` over an iterator needs the module graph, which rewrites it", .{});
            return true;
        }
        const id = node.list.id;
        for (self.ctx.iter_loops.items) |l| if (l.node == id) return true;
        try self.ctx.iter_loops.append(self.ctx.allocator, .{ .node = id, .source = how });
        return true;
    }

    const LoopPair = struct { elem: SymbolId, index: SymbolId, source: Sexp };

    /// The hint for a value of the wrong type that is a binding of
    /// `for x, i in xs` whose other binding has the type wanted: the loop
    /// was likely written index first, as Python's `enumerate` is.
    fn loopOrderHint(self: *Checker, e: Sexp, wanted: TypeId) Error![]const u8 {
        if (e != .src) return "";
        const sym = self.ctx.symbolOf(e) orelse return "";
        const pair = self.loop_pairs.get(sym) orelse return "";
        const other = if (sym == pair.elem) pair.index else pair.elem;
        const other_ty = self.ctx.symbols.items[other].ty;
        const fits = if (sym == pair.elem) sema.isInteger(self.ctx, wanted) else compatible(self.ctx, other_ty, wanted);
        if (!fits) return "";
        const elem = self.ctx.symbols.items[pair.elem].name;
        const index = self.ctx.symbols.items[pair.index].name;
        return self.ctx.arena.allocator().print("; `{s}` is the index here: Rig writes the element first, `for {s}, {s} in {s}`", .{ index, index, elem, self.sourceText(pair.source) });
    }

    /// The `break` or `continue`, with no label or value, that `cond`
    /// ends in (`x ?? break`), which a label in the old spelling
    /// (`x ?? break :outer`) was meant for.
    fn bareJumpAtEnd(cond: Sexp) ?[]const u8 {
        var e = cond;
        while (e.isKind(.@"??") or e.isKind(.@"and") or e.isKind(.@"or")) e = ir.get(e, .right);
        if (e.isKind(.@"break") and ir.Break.label(e) == .nil and ir.Break.value(e) == .nil) return "break";
        if (e.isKind(.@"continue") and ir.Continue.label(e) == .nil) return "continue";
        return null;
    }

    /// A loop with a `break` that carries a value: its value is used.
    fn isValueLoop(self: *Checker, e: Sexp) bool {
        return sema.hasValueBreaks(self.ctx.source, e);
    }

    /// A statement that yields no value: a binding, a jump, a loop other
    /// than a value loop.
    fn yieldsNoValue(self: *Checker, e: Sexp) bool {
        const h = e.kind() orelse return false;
        return switch (h) {
            .set, .@"while", .@"for", .drop, .pass, .@"defer", .@"errdefer", .@"return", .@"break", .@"continue", .labeled => !self.isValueLoop(e),
            else => false,
        };
    }

    /// A loop used as a value: its `break` values and its `else` value
    /// meet in one type (`expected`, when the context gives one). Without
    /// an `else` the loop has no value when its condition fails, so only
    /// `while true` may omit it.
    fn checkLoopValue(self: *Checker, node: Sexp, expected: ?TypeId, used: bool) Error!TypeId {
        const loop = if (node.isKind(.labeled)) ir.Labeled.stmt(node) else node;
        var lv: LoopValue = .{ .expected = expected };
        defer lv.values.deinit(self.ctx.allocator);
        const else_ = ir.get(loop, .@"else");
        if (used and else_ == .nil and !isWhileTrue(self.ctx.source, loop)) {
            try self.errAt(loop, "a loop used as a value needs an `else` giving its value when no `break` does", .{});
        }
        if (node.isKind(.labeled)) self.loop_label = self.text(ir.Labeled.label(node));
        self.loop_value = &lv;
        if (loop.isKind(.@"while")) try self.checkWhile(loop) else try self.checkFor(loop);
        const ty = if (expected) |e| e else self.canonical(lv.ty orelse self.t().invalid_id);
        if (expected == null) for (lv.values.items) |v| try self.adaptLiteral(v.node, v.ty, ty);
        if (used and ty == self.t().void_id) try self.errAt(node, "a loop used as a value cannot yield `Void`", .{});
        try self.ctx.recordType(loop, ty);
        return ty;
    }

    /// A `break` value or an `else` value of a loop used as a value.
    fn loopValue(self: *Checker, lv: *LoopValue, value: Sexp) Error!void {
        // A `break` value, or a loop's `else`, leaves the loop: its tail
        // is taken.
        try self.recordUse(value, .take);
        try self.recordUse(sema.tailOf(value), .take);
        if (lv.expected) |e| return self.checkExpr(value, e);
        const ty = try self.synthExpr(value);
        try lv.values.append(self.ctx.allocator, .{ .node = value, .ty = ty });
        lv.ty = if (lv.ty) |cur| (try self.unify(cur, ty, self.startOf(value))) orelse self.t().invalid_id else ty;
    }

    /// `(break value? label?)`: a loop used as a value takes a value from
    /// every `break` that leaves it, and no other `break` carries one.
    fn checkBreak(self: *Checker, node: Sexp) Error!void {
        const value = ir.Break.value(node);
        const target = try self.resolveJump(node);
        const lv: ?*LoopValue = if (target) |f| f.value else null;
        if (value == .nil) {
            if (lv != null) try self.errAt(node, "this `break` leaves a loop used as a value; give it the value (`break value`)", .{});
            return;
        }
        if (lv) |v| return self.loopValue(v, value);
        _ = try self.synthExpr(value);
        if (target) |f| {
            if (f.is_loop) {
                try self.errAt(value, "`break` with a value needs a loop whose value is used (`x = for ...`)", .{});
            } else try self.errAt(value, "a labeled block has no value; `break @{s}` cannot carry one", .{f.label});
        }
    }

    /// Where `break` or `continue` `node` goes (`sema.JumpDest`), which
    /// emit and the ownership checker read: the construct it names, as
    /// recorded when that construct was entered (`sema.eachJumpTo`), and
    /// the point of it the part of the loop being checked sends it to. A
    /// `continue` from a `while`'s condition is recorded once the step's
    /// point is decided (`settleConditionJumps`). Null for a jump that
    /// names nothing it can leave, which is reported here.
    fn resolveJump(self: *Checker, node: Sexp) Error!?*LoopFrame {
        const brk = node.isKind(.@"break");
        const label = ir.get(node, .label);
        var target = self.body.loops;
        if (self.jump_targets.get(nodeId(node))) |named| {
            while (target) |f| : (target = f.parent) if (sameNode(f.node, named)) break;
        } else target = null;
        const word = if (brk) "break" else "continue";
        const f = target orelse {
            const where = if (self.body.in_closure) " (a closure body cannot leave a loop around it)" else "";
            if (label == .nil) {
                try self.errAt(node, "`{s}` is not inside a loop{s}", .{ word, where });
            } else {
                try self.errAt(node, "`{s} @{s}` names no enclosing loop or block{s}", .{ word, self.text(label), where });
            }
            return null;
        };
        if (brk) {
            try self.ctx.recordJumpDest(node, .{ .target = f.node, .to = .exit });
            return f;
        }
        if (!f.is_loop) {
            try self.errAt(node, "`continue @{s}` names a block, not a loop", .{f.label});
            return null;
        }
        const to: sema.JumpDest.To = switch (f.part) {
            .source => unreachable,
            // Where it goes from the condition depends on where the step
            // runs, which is decided once the step is checked.
            .cond => if (f.has_step) {
                try f.cond_continues.append(self.ctx.allocator, node);
                return f;
            } else .head,
            .body => if (f.has_step) .step else .head,
            .step => .head,
        };
        try self.ctx.recordJumpDest(node, .{ .target = f.node, .to = to });
        return f;
    }

    /// The `continue`s in the condition of `while` loop `frame`: to the
    /// step when it is the loop's continue expression, or else to the
    /// head, past a step that reads a binding they would leave unbound
    /// (`checkStepBindings` rejects that).
    fn settleConditionJumps(self: *Checker, frame: *const LoopFrame) Error!void {
        if (frame.cond_continues.items.len == 0) return;
        const to: sema.JumpDest.To = switch (storage.stepPoint(self.ctx, frame.node)) {
            .continue_expr => .step,
            .after_body => .head,
        };
        for (frame.cond_continues.items) |c| try self.ctx.recordJumpDest(c, .{ .target = frame.node, .to = to });
    }

    /// The element of `for x in !xs`: a write view of each slot. The
    /// source must be a place the loop may write.
    fn writeElement(self: *Checker, source: Sexp, inner_source: Sexp, elem: TypeId) Error!TypeId {
        const place = self.placeOf(inner_source);
        if (!place.named()) {
            try self.errAt(source, "`for x in !xs` writes each element in place; `xs` must be a binding, or a field or element of one", .{});
        } else _ = try self.requireAccess(place, .write_iterate, source);
        return self.loopElement(.write, elem);
    }

    /// The binding of an element a loop reads where it is: a copy of
    /// plain data, a view (`?E`) of anything else, so a unique value is
    /// never copied. Inside a generic body an element whose type depends
    /// on the instance is a copy, so every instance must supply one that
    /// copies.
    fn readElement(self: *Checker, pos: u32, elem: TypeId) Error!TypeId {
        if (sema.copies(self.ctx, elem) == .depends) try self.requireOf(elem, .copies, pos, "copies into a loop binding a value");
        return self.loopElement(.read, elem);
    }

    /// The type of a loop's element binding, of an element of type
    /// `elem` the loop writes, takes, or reads: its access
    /// (`sema.decideBindingAccess`, kept in `loop_access` for `checkFor`
    /// to record) gives a write view of it, a read view of it, or, with
    /// no access, the copy or the element taken.
    fn loopElement(self: *Checker, mode: sema.LoopMode, elem: TypeId) Error!TypeId {
        if (self.isPoison(elem)) return elem;
        const access = sema.decideBindingAccess(self.ctx, .{ .loop = .{ .mode = mode, .elem = elem } });
        self.loop_access = access;
        return self.viewOfAccess(access, elem);
    }

    fn elementTypeForLoop(self: *Checker, source: Sexp, inner_source: Sexp, source_ty: TypeId, mode: ?Tag) Error!TypeId {
        const pos = self.startOf(source);
        if (self.isPoison(source_ty)) return self.t().invalid_id;
        const peeled = sema.unwrapViews(self.ctx, source_ty);
        switch (self.ctx.types.get(peeled)) {
            .parameterized_nominal => if (listElementType(self.ctx, peeled)) |elem| {
                // Elements that move (handles and boxes) are walked by
                // view; every other element is plain data.
                const is_resource = sema.moves(self.ctx, elem) == .yes;
                if (is_resource) {
                    // The one diagnostic for such a loop over any other
                    // source; `checkFor` reports nothing more of it.
                    if (!self.placeOf(inner_source).named()) {
                        // What to bind: the value made here, of which the
                        // source may be a part; a branching source is
                        // bound with each name taken (`<a if c else <b`).
                        const made = self.madeBase(inner_source);
                        const bind = if (made != .nil) made else inner_source;
                        const hint = if (self.hands(bind).kind == .branches) "bind the List to a name first" else try self.ctx.arena.allocator().print("bind `{s}` to a name first", .{self.sourceText(bind)});
                        try self.err(pos, "a loop over a List of `{s}` walks a List that a name holds, or a field or element of one; {s}", .{ try self.tyName(elem), hint });
                        return self.t().invalid_id;
                    }
                }
                if (mode == .write) return self.writeElement(source, inner_source, elem);
                // `for x in <v` hands each element over, which only the
                // List's owner can do.
                if (mode == .move) {
                    if (peeled == source_ty) return self.loopElement(.take, elem);
                    const shown = try self.plainText(inner_source);
                    try self.err(pos, "`<{s}` would move the elements out of a List that `{s}` only views; loop over `?{s}` or `!{s}`, or move the List itself", .{ shown, shown, shown, shown });
                    return self.ctx.intern(.{ .read_view = elem });
                }
                return self.loopElement(.read, elem);
            },
            .array => |a| {
                if (mode == .write) return self.writeElement(source, inner_source, a.elem);
                if (mode != .move) return self.readElement(pos, a.elem);
                return self.loopElement(.take, a.elem);
            },
            .slice, .string_view, .static => {
                if (mode == .write) {
                    if (sema.writeSliceElem(self.ctx, source_ty)) |elem| {
                        if (!rig.isRangeIndex(inner_source)) _ = try self.requireAccess(self.placeOf(inner_source), .write_iterate, source);
                        return self.loopElement(.write, elem);
                    }
                    try self.err(pos, "cannot write-iterate a `{s}`; its elements are read-only", .{try self.tyName(source_ty)});
                    return self.t().invalid_id;
                }
                return switch (self.ctx.types.get(peeled)) {
                    .slice => |sl| try self.readElement(pos, sl.elem),
                    else => try self.byteType(),
                };
            },
            else => {},
        }
        // `for b in ?t` walks the bytes of the `?String` `?t` lends.
        if (mode == .read and stringOrBoxed(self.ctx, peeled) == self.t().string_id) {
            if (!self.placeOf(source).named()) try self.lendTemp(source);
            return self.byteType();
        }
        const text_hint = if (sema.unwrapViews(self.ctx, source_ty) == self.t().string_id) "; walk a String's bytes through its `?String` view: `for b in ?t`" else "";
        try self.err(pos, "cannot iterate over `{s}`; a `for` source must be a range `a..b`, an array, a `?String`, a `List`, or an iterator (a type with `next(!self) -> T?`){s}", .{ try self.tyName(source_ty), text_hint });
        return self.t().invalid_id;
    }

    // ---- match ----------------------------------------------------------------

    fn checkMatch(self: *Checker, node: Sexp, position: Position, expected: ?TypeId) Error!TypeId {
        const subject = ir.Match.subject(node);
        var mode: MatchMode = if (subject.isKind(.write)) .write else if (subject.isKind(.move)) .consume else .read;
        // `<e` names the value it moves, and a value made here is taken
        // as `<e` would take it. A subject is a header: a temporary it
        // reads ends with it.
        // A part of a value made here is matched in that value, which the
        // match holds (`Header.held`).
        const saved_held = self.held_base;
        defer self.held_base = saved_held;
        if (mode == .read) self.held_base = self.madeBase(subject);
        // A header's subject is matched where it stands, which
        // `headerLendsBranch` decides for a branch.
        const saved_in_place = self.in_place;
        defer self.in_place = saved_in_place;
        self.in_place = subject;
        var scrutinee = if (mode == .write) try self.synthOperand(subject) else try self.synthExpr(subject);
        const subject_hands = self.hands(subject);
        if (mode == .read and !self.isPoison(scrutinee)) switch (subject_hands.kind) {
            // A value made here that owns or is unique is the match's
            // own (`sema.moves`); a view it yields, a write view
            // included, stays a view.
            .made => if (try self.mustTake(scrutinee, self.startOf(subject), "matches")) {
                mode = .consume;
                try self.ctx.recordHeader(node, .taken, .nil);
            },
            // A place is matched where it stands, as `match ?p` would,
            // and a part of a made value that is not plain data where the
            // match holds that value. (A part of plain data is read in the
            // header, and a part of a branching value, which may be a
            // name's part, is checked below as a branching value is.)
            .place, .part_of_made => if (subject_hands.kind == .place or self.held_base != .nil) {
                const reached = sema.unwrapAccess(self.ctx, scrutinee);
                const plain = sema.copies(self.ctx, reached) != .no;
                const held = subject_hands.kind == .part_of_made and !plain;
                if (subject_hands.kind == .part_of_made and plain) try self.releaseHeld();
                if (!held) try self.readLeaf(subject);
                const lends_inner = reached != sema.unwrapViews(self.ctx, scrutinee);
                if (held and !try self.holdsHeld(subject)) {
                    scrutinee = self.t().invalid_id;
                } else if (held or lends_inner or (!plain and !sema.isReadOrWriteView(self.ctx, scrutinee))) {
                    try self.ctx.recordHeader(node, if (held) .held else .viewed, if (held) self.held_base else .nil);
                    // A box or a handle lends the value it holds: plain
                    // data is read as its value, anything else viewed.
                    if (plain and lends_inner) {
                        scrutinee = reached;
                    } else if (!sema.isReadOrWriteView(self.ctx, scrutinee) or lends_inner) scrutinee = try self.ctx.intern(.{ .read_view = reached });
                }
            } else try self.readLeaf(subject),
            .lend, .branches, .jump, .none => try self.readLeaf(subject),
        };
        if (mode == .read and subject.isKind(.read) and !self.isPoison(scrutinee)) {
            // `match ?h` of a handle views the value it holds.
            const reached = sema.unwrapAccess(self.ctx, scrutinee);
            if (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee)) == .shared) scrutinee = try self.ctx.intern(.{ .read_view = reached });
        }
        if (mode == .write and subject.isKind(.write) and !self.isPoison(scrutinee)) {
            // `match !h` of a handle that changes by a marked call lends the
            // value it holds to write.
            const reached = sema.unwrapAccess(self.ctx, scrutinee);
            if (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee)) == .shared and sema.changesByMark(self.ctx, reached)) scrutinee = try self.ctx.intern(.{ .write_view = reached });
        }
        // What the arms bind views the subject, unless the match takes it,
        // and may view a copy (`rejectHeaderCopy`).
        // (A view a call returns, held as a pointer, is matched where it
        // points, temporaries or not.)
        const held_view = storage.holdsView(self.ctx, node);
        if (mode != .consume and !held_view and !self.isPoison(scrutinee)) try self.rejectHeaderCopy(node, subject, sema.unwrapAccess(self.ctx, scrutinee));
        try self.recordUse(subject, switch (mode) {
            .read => .read,
            .consume => .take,
            .write => .lend,
        });
        const scrut_pos = self.startOf(subject);
        // A value that may be a name's, or a part of one, is matched
        // where it is, and one made here is taken: a branching value
        // that may be either is bound to a name first.
        const branching = subject_hands.kind == .branches or (subject_hands.kind == .part_of_made and self.held_base == .nil);
        if (mode == .read and branching and !self.isPoison(scrutinee) and sema.moves(self.ctx, scrutinee) != .no) {
            try self.errAt(subject, "a `match` reads a place or takes a call's result; bind this `{s}` to a name first", .{try self.tyName(scrutinee)});
            scrutinee = self.t().invalid_id;
        }
        // A branch the match reads where it stands is lent there.
        if (mode != .consume and !self.isPoison(scrutinee) and !try self.headerLendsBranch(headerSubject(subject))) scrutinee = self.t().invalid_id;
        // `match <e` takes the fields of a value `e` owns.
        if (subject.isKind(.move)) if (self.ctx.typeOf(ir.Move.operand(subject))) |held| switch (self.ctx.types.get(held)) {
            .read_view, .write_view => {
                const shown = try self.plainText(ir.Move.operand(subject));
                if (self.ctx.types.get(held) == .write_view) {
                    try self.errAt(subject, "`match <{s}` consumes an owned value, and `{s}` is a write view (`{s}`); write the payload in place with `match !{s}`, or read it with `match {s}`", .{ shown, shown, try self.tyName(held), shown, shown });
                } else try self.errAt(subject, "`match <{s}` consumes an owned value, and `{s}` is a view (`{s}`); match what it views with `match {s}`", .{ shown, shown, try self.tyName(held), shown });
            },
            else => {},
        };
        // A boxed enum is matched where it is, through a view of the box.
        if (sema.boxedType(self.ctx, sema.unwrapViews(self.ctx, scrutinee)) != null) if (sema.boxedNominal(self.ctx, scrutinee)) |inner| {
            switch (self.ctx.types.get(scrutinee)) {
                .read_view => scrutinee = try self.ctx.intern(.{ .read_view = inner }),
                .write_view => if (sema.accessThroughShared(self.ctx, scrutinee) and !sema.changesByMark(self.ctx, inner)) {
                    const shown = self.sourceText(if (subject.isKind(.write)) ir.Write.operand(subject) else subject);
                    try self.errAt(subject, "cannot `match !{s}`: the box holds a shared handle (`*T`), and other handles may exist; match it with `match {s}` to read it, and to change a value that handles share, hold it in a `Cell[T]`", .{ shown, shown });
                    scrutinee = self.t().invalid_id;
                } else {
                    scrutinee = try self.ctx.intern(.{ .write_view = inner });
                },
                else => {
                    const place = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                    const shown = try self.plainText(place);
                    if (mode == .consume) {
                        try self.errAt(subject, "a `match` reaches the value inside a box by lending the box: `match ?{s}` or `match !{s}`; to take the value out, bind it first: `v = <{s}.unbox()`", .{ shown, shown, shown });
                        scrutinee = inner;
                    } else {
                        try self.errAt(subject, "a `match` reaches the value inside a box by lending the box: `match ?{s}`", .{shown});
                        scrutinee = self.t().invalid_id;
                    }
                },
            }
        };
        if (scrutinee == self.t().int_literal_id) try self.defaultIntLiteral(subject);
        const matchable = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee))) {
            .int, .int_literal, .bool, .invalid, .unknown, .any_error => true,
            .nominal, .parameterized_nominal, .imported_nominal => sema.enumVariantCount(self.ctx, scrutinee) != null,
            else => false,
        };
        if (!matchable) {
            try self.err(scrut_pos, "cannot `match` on a value of type `{s}`; match works on enums, errors, integers, and Bool", .{try self.tyName(scrutinee)});
        }

        // The place a binding that cannot be written views, for the
        // diagnostic that says how to write it.
        const viewed: ?CopySource = if (mode != .read) null else if (subject.isKind(.read) and self.hands(ir.Read.operand(subject)).hasStorage())
            .{ .place = ir.Read.operand(subject), .kind = .match_read }
        else if (subject_hands.hasStorage()) .{ .place = subject, .kind = .match_copy } else null;
        const saved_arm_local = self.arm_local;
        defer self.arm_local = saved_arm_local;
        self.arm_local = mode == .read and !self.isPoison(scrutinee) and !storage.matchesInPlace(self.ctx, node);
        const saved_matching = self.matching;
        defer self.matching = saved_matching;
        self.matching = node;
        var cov: MatchCoverage = .{ .variant_total = sema.enumVariantCount(self.ctx, sema.unwrapViews(self.ctx, scrutinee)) };
        var arm_values: std.ArrayList(Typed) = .empty;
        defer arm_values.deinit(self.ctx.allocator);
        defer cov.deinit(self.ctx.allocator);
        var result: ?TypeId = expected;

        for (ir.Match.arms(node)) |arm| {
            const prev = self.enter(arm);
            defer self.scope = prev;
            const pattern = ir.Arm.pattern(arm);
            const guard = ir.Arm.guard(arm);
            if (cov.has_default or self.coversAll(&cov, scrutinee)) {
                try self.errAt(pattern, "this arm never runs: the arms before it cover every value", .{});
            }
            const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
            if (alts.len > 1) try self.checkAlternatives(alts);
            // A guarded arm may not run for the values its pattern
            // matches, so it covers none of them; later arms may repeat
            // its pattern.
            var guarded: MatchCoverage = .{ .before = &cov, .variant_total = cov.variant_total };
            defer guarded.deinit(self.ctx.allocator);
            for (alts) |alt| try self.checkPattern(alt, scrutinee, if (guard != .nil) &guarded else &cov, mode);
            if (guard != .nil) {
                var it = guarded.variants.keyIterator();
                while (it.next()) |k| try cov.guarded.put(self.ctx.allocator, k.*, {});
            }
            if (viewed) |v| {
                if (pattern.isKind(.variant_pattern)) {
                    for (self.ctx.payloadBindings(pattern) orelse &.{}) |b| if (self.ctx.symbolOf(b)) |sym| try self.copied_from.put(self.ctx.allocator, sym, v);
                } else if (pattern == .src) if (self.ctx.symbolOf(pattern)) |sym| {
                    var whole = v;
                    whole.whole = true;
                    try self.copied_from.put(self.ctx.allocator, sym, whole);
                };
            }
            if (mode == .consume) {
                const binds: []const Sexp = if (pattern.isKind(.variant_pattern)) self.ctx.payloadBindings(pattern) orelse &.{} else (&pattern)[0..1];
                for (binds) |b| if (self.ctx.symbolOf(b)) |sym| try self.owned_bindings.put(self.ctx.allocator, sym, {});
            }
            // Every read match's binding, for the hint that names the
            // match that writes (`readMatchHint`).
            if (mode == .read and viewed == null) {
                const shown_subject = if (subject.isKind(.read)) ir.Read.operand(subject) else subject;
                if (pattern.isKind(.variant_pattern)) {
                    for (self.ctx.payloadBindings(pattern) orelse &.{}) |b| if (self.ctx.symbolOf(b)) |sym| try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = shown_subject, .kind = .match_read });
                } else if (pattern == .src) if (self.ctx.symbolOf(pattern)) |sym| try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = shown_subject, .kind = .match_read, .whole = true });
            }
            if (guard != .nil) {
                try self.checkExpr(guard, self.t().bool_id);
                if (findMove(guard)) |m| try self.errAt(m, "a guard cannot move a value: when it fails, a later arm matches the same value", .{});
                if (self.guardWrite(guard, subject, pattern)) |w| try self.errAt(w, "a guard cannot change the value being matched: when it fails, a later arm matches the same value", .{});
            }
            const body = ir.Arm.body(arm);
            switch (position) {
                .statement => try self.checkStmt(body),
                .value => if (expected) |x| try self.checkExpr(body, x) else {
                    const ty = try self.synthExpr(body);
                    result = if (result) |r| (try self.unify(r, ty, self.startOf(body))) orelse r else ty;
                    try arm_values.append(self.ctx.allocator, .{ .node = body, .ty = ty });
                },
            }
        }

        // A binding views the subject through the body, and a temporary
        // the subject reads ends with the subject.
        if (self.tempBase(subject)) |temp| if (self.armsBind(node)) {
            try self.errAt(temp, "the arms' bindings would outlive the temporary `{s}`, which the `match` subject drops; bind it to a name first", .{self.sourceText(temp)});
        };
        if (result) |r| for (arm_values.items) |av| try self.adaptLiteral(av.node, av.ty, r);
        const exhaustive = self.coversAll(&cov, scrutinee);
        if (exhaustive) try self.ctx.recordExhaustive(node);
        if (matchable and !cov.has_default and !cov.rejected and !exhaustive and !self.isPoison(scrutinee)) try self.notExhaustive(&cov, scrutinee, scrut_pos);
        if (position == .statement) return self.t().void_id;
        return result orelse self.t().invalid_id;
    }

    /// What the arms of a match have covered so far.
    const MatchCoverage = struct {
        variants: std.StringHashMapUnmanaged(u32) = .empty,
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

        fn deinit(c: *MatchCoverage, a: std.mem.Allocator) void {
            c.variants.deinit(a);
            c.ints.deinit(a);
            c.guarded.deinit(a);
        }

        /// Where the pattern that first covered variant (or error) key
        /// `name` is.
        fn variantAt(c: *const MatchCoverage, name: []const u8) ?u32 {
            if (c.variants.get(name)) |pos| return pos;
            return if (c.before) |b| b.variantAt(name) else null;
        }

        /// Whether a pattern covered Bool value `i` (0 for `false`).
        fn hasBool(c: *const MatchCoverage, i: usize) bool {
            return c.bools[i] or if (c.before) |b| b.hasBool(i) else false;
        }

        /// Whether a pattern covered a value from `lo` to `hi`.
        fn overlapsInts(c: *const MatchCoverage, lo: Wide, hi: Wide) bool {
            const ints = c.ints.items;
            const at = intsAfter(ints, lo);
            if ((at > 0 and ints[at - 1][1] >= lo) or (at < ints.len and ints[at][0] <= hi)) return true;
            return if (c.before) |b| b.overlapsInts(lo, hi) else false;
        }

        /// The first of `ints` that starts after `lo`: of an interval
        /// from `lo`, only it and the one before it can overlap.
        fn intsAfter(ints: []const [2]Wide, lo: Wide) usize {
            return std.sort.upperBound([2]Wide, ints, lo, struct {
                fn order(key: Wide, iv: [2]Wide) std.math.Order {
                    return std.math.order(key, iv[0]);
                }
            }.order);
        }
    };

    /// The first write view in guard `g` of what the match reaches: the
    /// subject's binding, or a binding of the arm's `pattern`.
    fn guardWrite(self: *Checker, g: Sexp, subject: Sexp, pattern: Sexp) ?Sexp {
        if (g != .list) return null;
        const written: ?Sexp = if (g.isKind(.write)) ir.Write.operand(g) else if (g.isKind(.cap_write)) ir.CapWrite.name(g) else null;
        if (written) |w| if (placeRoot(w)) |leaf| if (self.ctx.symbolOf(leaf)) |sym| {
            if (placeRoot(subject)) |s| if (self.ctx.symbolOf(s) == sym) return g;
            if (patternBinds(self, pattern, sym)) return g;
            if (self.ctx.symbols.items[sym].kind == .capture) {
                const origin = self.ctx.symbols.items[sym].origin;
                if (placeRoot(subject)) |s| if (self.ctx.symbolOf(s) == origin) return g;
            }
        };
        for (g.items()) |c| if (self.guardWrite(c, subject, pattern)) |w| return w;
        return null;
    }

    /// The temporary place `e` reads into, where `e` is a field or
    /// element path, or a lend, of one (`mk().e`, `?mk()`).
    /// The value made here that `subject`, a part of it, is a path from
    /// (`mk()` in `mk().e[0]`), which a header holds for its construct;
    /// `.nil` for any other subject.
    fn madeBase(self: *Checker, subject: Sexp) Sexp {
        if (self.hands(subject).kind != .part_of_made) return .nil;
        var base = subject;
        while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
        return if (self.hands(base).kind == .made) base else .nil;
    }

    /// For binding `sym` that a read match binds to read (its access,
    /// `Symbol.access`), the hint naming the match that writes through
    /// it; empty for any other binding.
    fn readMatchHint(self: *Checker, sym: ?SymbolId) Error![]const u8 {
        const id = sym orelse return "";
        const s = self.ctx.symbols.items[id];
        if (s.access != .read) return "";
        if (self.read_subjects.get(id)) |from| if (from.kind == .as) {
            const shown = try self.plainText(from.place);
            // No `!` writes a field another module keeps read-only.
            if (self.placeOf(from.place).read_only) |f| return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`, and field `{s}` of `{s}` is read-only outside module `{s}`, so nothing here writes through it", .{ s.name, shown, f.field, f.owner, f.module });
            // A parameter taken by value is written once it is taken to
            // write (`o: !T`).
            if (self.placeOf(from.place).root == .param) return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`: to write through it, take the parameter to write (`{s}: !…`), then bind it with `if !{s} as {s}`", .{ s.name, shown, shown, shown, s.name });
            return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`: to write through it, bind it with `if !{s} as {s}`", .{ s.name, shown, shown, s.name });
        };
        const from = self.copied_from.get(id) orelse self.read_subjects.get(id) orelse return "";
        if (from.kind != .match_copy and from.kind != .match_read) return "";
        const what = if (from.whole) "" else "a field of ";
        const shown = try self.plainText(from.place);
        if (self.placeOf(from.place).read_only) |f| return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`, and field `{s}` of `{s}` is read-only outside module `{s}`, so nothing here writes through it", .{ s.name, what, shown, f.field, f.owner, f.module });
        // A subject reached through a read view or a shared handle is never
        // written through, however it is matched.
        if (self.readOnlyStep(from.place)) |why| return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`, which is reached through {s}, so nothing writes through it", .{ s.name, what, shown, why });
        return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`: to write through it, {s}", .{ s.name, what, shown, try self.writeMatchAdvice(from.place) });
    }

    /// What makes `subject` read-only: it, or a value on its path (the
    /// base, an object of a field or element, a leaf of a branch), is a
    /// read view or a shared handle, by its type; null for none.
    fn readOnlyStep(self: *Checker, subject: Sexp) ?[]const u8 {
        var e = subject;
        while (true) {
            if (self.ctx.typeOf(e)) |ty| switch (self.ctx.types.get(ty)) {
                .read_view => return "a read view",
                .shared => return "a shared handle",
                else => {},
            };
            if (e.isKind(.member) or e.isKind(.index)) {
                e = ir.get(e, .object);
            } else if (sema.isBranchingForm(e)) {
                var leaves: std.ArrayList(Sexp) = .empty;
                defer leaves.deinit(self.ctx.allocator);
                sema.valueLeaves(self.ctx.allocator, e, &leaves) catch return null;
                for (leaves.items) |leaf| if (self.ctx.typeOf(leaf)) |ty| switch (self.ctx.types.get(ty)) {
                    .read_view => return "a read view",
                    .shared => return "a shared handle",
                    else => {},
                };
                return null;
            } else return null;
        }
    }

    /// A header's subject without its sigil, and the sigil (`?S`, `!S`):
    /// the same for `match`, `if … as`, `while … as`, and `for` (whose `?`
    /// and `!` are its mode).
    const HeaderSubject = struct { node: Sexp, sigil: ?LendKind };

    fn headerSubject(e: Sexp) HeaderSubject {
        if (e.isKind(.read)) return .{ .node = ir.get(e, .operand), .sigil = .read };
        if (e.isKind(.write)) return .{ .node = ir.get(e, .operand), .sigil = .write };
        return .{ .node = e, .sigil = null };
    }

    /// A header reads its subject where it stands (Core sentence 1), so a
    /// branching value, or a path from one, is lent there, by its sigil or,
    /// bare, to read, and `lendsBranch` decides whether it may be: a
    /// branch is a value, never a place. A bare subject the header copies
    /// (plain data), or reads through a copy of a read view
    /// (`readsInPlace`), is read as a value, not lent. False when the lend
    /// is rejected (reported).
    fn headerLendsBranch(self: *Checker, subject: HeaderSubject) Error!bool {
        const kind = subject.sigil orelse kind: {
            const ty = self.ctx.typeOf(subject.node) orelse return true;
            if (sema.copies(self.ctx, ty) == .yes or !self.readsInPlace(subject.node)) return true;
            break :kind LendKind.read;
        };
        return self.lendsBranch(subject.node, .nil, kind);
    }

    /// How to write through the bindings of a read match of `subject`:
    /// `match !subject`, or, for a part of a value made in the header,
    /// that value bound to a name first.
    fn writeMatchAdvice(self: *Checker, subject: Sexp) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        // A part of a branch: the branch is named first, and its part
        // matched to write (`t = (!a if c else !b)`, then `match !t.e`).
        if (subject.isKind(.member) or subject.isKind(.index)) {
            const base = sema.pathRoot(subject);
            if (sema.isBranchingForm(base)) {
                const whole = try self.plainText(subject);
                const branch_text = try self.plainText(base);
                // The steps after the branch, as written: `.e`, `[0].e`.
                const end = self.ctx.span(base).end;
                const start = self.ctx.span(subject).start;
                const stop = self.ctx.span(subject).end;
                const rest = if (end >= start and end <= stop) std.mem.trimStart(u8, diag.textBetween(self.ctx.source, end, stop), ")") else whole;
                return a.print("bind the branch to a name first, `t = ({s})`, then match its part with `match !t{s}`", .{ branch_text, rest });
            }
        }
        switch (self.hands(subject).kind) {
            // A part of a value made in the header: the value is named
            // first.
            .part_of_made => {
                var base = subject;
                while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
                return a.print("bind `{s}` to a name first, then match its part with `match !`", .{try self.plainText(base)});
            },
            .place, .lend => if (self.placeOf(subject).named()) return a.print("match with `match !{s}`", .{try self.plainText(subject)}),
            // Each branch is lent to write: `match (!a if c else !b)`; the
            // value inside an optional is lent to write with `if !o as x`.
            .branches => if (subject.isKind(.@"if")) {
                return "lend each branch to write: `match (!a if c else !b)`";
            } else if (subject.isKind(.propagate_none)) {
                return a.print("lend the value inside to write first, `if !{s} as x`, then match it with `match !x`", .{try self.plainText(ir.PropagateNone.value(subject))});
            },
            .made, .jump, .none => {},
        }
        // A call that returns a read view writes nothing; one that
        // returns a write view is matched as it is.
        if (subject.isKind(.call)) return "match a write view instead: a place with `match !`, or a call that returns one";
        return a.print("bind `{s}` to a name first, then match it with `match !`", .{try self.plainText(subject)});
    }

    /// Report `e` when it is a read match's binding of a payload that is
    /// not plain data, which views the payload where it is, taken by
    /// `verb` (`move`, `drop`). True when reported.
    fn payloadViewTaken(self: *Checker, e: Sexp, verb: []const u8) Error!bool {
        if (e != .src) return false;
        const sym = self.ctx.symbolOf(e) orelse return false;
        const from = self.copied_from.get(sym) orelse return false;
        if (from.kind != .match_copy and from.kind != .match_read) return false;
        if (self.ctx.types.get(self.ctx.symbols.items[sym].ty) != .read_view) return false;
        const name = self.text(e);
        const shown = try self.plainText(from.place);
        const place = self.placeOf(from.place);
        const lent = from.kind == .match_read or place.indirect or if (self.ctx.typeOf(from.place)) |ty| sema.isReadOrWriteView(self.ctx, ty) else false;
        const shared = if (self.ctx.typeOf(place.base)) |ty| self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .shared else false;
        if (place.root == .capture) {
            try self.errAt(e, "cannot {s} captured resource `{s}`: `{s}` views a payload of it, and a closure never gives up what it captured", .{ verb, self.sourceText(place.base), name });
        } else if (shared) {
            try self.errAt(e, "cannot {s} out of `{s}`: `{s}` is a shared handle, which only reads its value", .{ verb, name, self.sourceText(place.base) });
        } else if (lent or place.root == .temporary) {
            try self.errAt(e, "cannot {s} out of `{s}`: it is a view of `{s}`", .{ verb, name, self.sourceText(place.base) });
        } else try self.errAt(e, "cannot {s} `{s}` out of `{s}`: `match {s}` reads `{s}`; write `match <{s}` to take its fields", .{ verb, name, shown, shown, shown, shown });
        return true;
    }

    /// The held base turns out to hold nothing (its part is plain data):
    /// it is read in the header as a temporary, as any made value is.
    fn releaseHeld(self: *Checker) Error!void {
        const base = self.held_base;
        self.held_base = .nil;
        self.ctx.forgetUse(base);
        try self.readLeaf(base);
    }

    /// Whether the header over `subject` may hold its base for the
    /// construct: the base makes no statement temporary, which would
    /// end with the header while the held value, and what it views,
    /// lives on. Reported when not.
    fn holdsHeld(self: *Checker, subject: Sexp) Error!bool {
        const base = self.held_base;
        if (!self.makesTemps(base, base)) return true;
        try self.errAt(subject, "this header holds `{s}` for its construct, but a temporary made inside it ends with the header; bind `{s}` to a name first", .{ self.sourceText(base), self.sourceText(base) });
        return false;
    }

    /// Whether `node`, inside the held base `base`, is or holds a
    /// statement temporary (`dropsTemp`).
    fn makesTemps(self: *Checker, node: Sexp, base: Sexp) bool {
        if (node != .list) return false;
        if (!sameNode(node, base) and self.ctx.dropsTemp(node)) return true;
        for (node.items()) |item| if (self.makesTemps(item, base)) return true;
        return false;
    }

    /// Header `node` (a `match`, a `for`, or an `as`) over `subject` that
    /// makes a statement temporary (`sema.firstStmtTemp`) is evaluated by
    /// emit in a block that ends the temporary. The block yields the
    /// address of a place the subject reaches (`storage.headerPoints`),
    /// and the construct binds the place's own, as it would with no
    /// temporary. It yields the value of any other subject, and what the
    /// construct binds is in that copy, which is recorded (the storage
    /// fact `header_copy`) for emit. A header that copies is rejected at
    /// the temporary, whatever it binds: a write, a Cell change, or a
    /// view, a catch-all's of plain data included, would reach the copy.
    /// A value made here, which no name holds, is the construct's own: it
    /// binds plain data of it by copy, which is what the copy holds.
    fn rejectHeaderCopy(self: *Checker, node: Sexp, subject: Sexp, bound: TypeId) Error!void {
        const temp = sema.firstStmtTemp(self.ctx, subject) orelse return;
        if (storage.headerPoints(self.ctx, storage.headerSubject(node))) return;
        try self.ctx.recordHeaderCopy(node);
        if (self.isPoison(bound)) return;
        if (self.hands(subject).kind == .made and sema.isPlainData(self.ctx, sema.unwrapViews(self.ctx, bound))) return;
        if (inIndex(subject, temp)) {
            try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind the index to a name first", .{});
        } else if (inArgument(subject, temp)) {
            try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind the argument to a name first", .{});
        } else try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind `{s}` to a name first", .{self.sourceText(temp)});
    }

    fn tempBase(self: *Checker, e: Sexp) ?Sexp {
        if (!self.hands(e).hasStorage()) return null;
        const base = self.placeOf(e).base;
        if (base != .list or !self.ctx.dropsTemp(base)) return null;
        return base;
    }

    /// Whether an arm of `match` binds a name that views the matched
    /// value: one that is not plain data copied out of it.
    fn armsBind(self: *Checker, match: Sexp) bool {
        for (ir.Match.arms(match)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
            for (alts) |alt| {
                if (alt == .src and self.viewsMatched(alt)) return true;
                if (alt.isKind(.variant_pattern)) for (self.ctx.payloadBindings(alt) orelse &.{}) |b| if (b == .src and self.viewsMatched(b)) return true;
            }
        }
        return false;
    }

    fn viewsMatched(self: *Checker, binding: Sexp) bool {
        const sym = self.ctx.symbolOf(binding) orelse return false;
        const ty = self.ctx.symbols.items[sym].ty;
        return !sema.isPlainData(self.ctx, ty) or sema.mayHoldView(self.ctx, ty);
    }

    /// Whether `pattern` binds symbol `sym`.
    fn patternBinds(self: *Checker, pattern: Sexp, sym: SymbolId) bool {
        if (pattern == .src) return self.ctx.symbolOf(pattern) == sym;
        if (!pattern.isKind(.variant_pattern)) return false;
        for (self.ctx.payloadBindings(pattern) orelse &.{}) |b| if (b == .src and self.ctx.symbolOf(b) == sym) return true;
        return false;
    }

    /// `a, b => ...`: each alternative is a literal, range, or variant;
    /// none binds a name or matches everything.
    fn checkAlternatives(self: *Checker, alts: []const Sexp) Error!void {
        var named = false;
        for (alts) |alt| {
            if (alt == .src and !isLiteralText(self.text(alt))) {
                try self.errAt(alt, "`{s}` matches every value, so the other alternatives never matter; give it an arm of its own", .{self.text(alt)});
                self.poisonBinding(alt);
                continue;
            }
            if (!alt.isKind(.variant_pattern)) continue;
            for (ir.VariantPattern.bindings(alt)) |bound| {
                const b = sema.bindingName(bound);
                if (b == .src and std.mem.eql(u8, self.text(b), "_")) continue;
                if (!named) try self.errAt(b, "an arm with alternatives cannot bind names: which alternative matched would decide what they hold; write `_`, or give each alternative an arm of its own", .{});
                named = true;
                self.poisonBinding(b);
            }
        }
    }

    /// Give a rejected pattern binding no type, so its uses report
    /// nothing more.
    fn poisonBinding(self: *Checker, b: Sexp) void {
        const sym = self.ctx.symbolOf(b) orelse return;
        self.ctx.symbols.items[sym].ty = self.t().invalid_id;
    }

    /// Whether the arms so far match every value of the scrutinee type.
    fn coversAll(self: *Checker, cov: *MatchCoverage, scrutinee: TypeId) bool {
        const ty = sema.unwrapViews(self.ctx, scrutinee);
        if (cov.variant_total) |total| return cov.variants.count() >= total;
        switch (self.ctx.types.get(ty)) {
            .bool => return cov.bools[0] and cov.bools[1],
            .int, .int_literal => {
                const bounds = intBounds(if (self.ctx.types.get(ty) == .int) self.ctx.types.get(ty).int else .{});
                var next = bounds.min;
                const max = bounds.max;
                for (cov.ints.items) |iv| {
                    if (iv[0] > next) return false;
                    if (iv[1] >= next) next = iv[1] + 1;
                    if (next > max) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// A `match` whose arms miss some values: the error names what they
    /// miss, the first few variants or the least integer.
    fn notExhaustive(self: *Checker, cov: *const MatchCoverage, scrutinee: TypeId, pos: u32) Error!void {
        const ty = sema.unwrapViews(self.ctx, scrutinee);
        const fix = "add an arm for it, or `_ =>` for the rest";
        if (sema.nominalDecl(self.ctx, ty)) |decl| if (decl.symbol().fields) |fields| {
            var missing: std.ArrayList(u8) = .empty;
            const a = self.ctx.arena.allocator();
            var count: usize = 0;
            for (fields) |f| {
                if (!f.is_variant or cov.variants.contains(f.name)) continue;
                count += 1;
                if (count <= 4) try missing.print(a, "{s}`.{s}`{s}", .{ if (count > 1) ", " else "", f.name, if (cov.guarded.contains(f.name)) " (its arm has a guard)" else "" });
            }
            if (count > 4) try missing.print(a, ", and {d} more", .{count - 4});
            if (count > 0) return self.err(pos, "`match` is not exhaustive: it misses {s}; {s}", .{ missing.items, if (count > 1) "add an arm for each, or `_ =>` for the rest" else fix });
        };
        switch (self.ctx.types.get(ty)) {
            .bool => return self.err(pos, "`match` is not exhaustive: it misses {s}; {s}", .{ if (cov.bools[0]) "`true`" else if (cov.bools[1]) "`false`" else "`true` and `false`", fix }),
            .int, .int_literal => {
                // The least value missed that is not negative, else the
                // greatest negative one.
                const bounds = intBounds(if (self.ctx.types.get(ty) == .int) self.ctx.types.get(ty).int else .{});
                var next: Wide = @max(bounds.min, 0);
                for (cov.ints.items) |iv| {
                    if (iv[0] > next) break;
                    if (iv[1] >= next) next = iv[1] + 1;
                }
                if (next > bounds.max) {
                    next = -1;
                    var i = cov.ints.items.len;
                    while (i > 0) : (i -= 1) {
                        const iv = cov.ints.items[i - 1];
                        if (iv[1] < next) break;
                        if (iv[0] <= next) next = iv[0] - 1;
                    }
                }
                return self.err(pos, "`match` on `{s}` is not exhaustive: it misses `{d}`; {s}", .{ try self.tyName(scrutinee), next, fix });
            },
            else => return self.err(pos, "`match` on `{s}` is not exhaustive; add `_ =>` for the values its arms miss", .{try self.tyName(ty)}),
        }
    }

    /// Record an integer interval a pattern matches; it may not overlap
    /// an earlier one. It joins an interval it touches, so a run of
    /// values is one interval and `coversAll` reads past it at once.
    fn coverInts(self: *Checker, cov: *MatchCoverage, lo: Wide, hi: Wide, pos: u32) Error!void {
        if (cov.overlapsInts(lo, hi)) return self.err(pos, "this pattern overlaps an earlier arm", .{});
        const ints = &cov.ints;
        const at = MatchCoverage.intsAfter(ints.items, lo);
        const joins_next = at < ints.items.len and ints.items[at][0] == hi + 1;
        if (at > 0 and ints.items[at - 1][1] + 1 == lo) {
            const prev = &ints.items[at - 1];
            prev[1] = if (joins_next) ints.items[at][1] else hi;
            if (joins_next) _ = ints.orderedRemove(at);
        } else if (joins_next) {
            ints.items[at][0] = lo;
        } else try ints.insert(self.ctx.allocator, at, .{ lo, hi });
    }

    fn checkPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *MatchCoverage, mode: MatchMode) Error!void {
        switch (pattern) {
            .src => {
                const name = self.text(pattern);
                if (isLiteralText(name)) {
                    try self.checkExpr(pattern, scrutinee);
                    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
                        const i: usize = if (name[0] == 't') 1 else 0;
                        if (cov.hasBool(i)) try self.errAt(pattern, "this pattern overlaps an earlier arm", .{});
                        cov.bools[i] = true;
                    } else if (self.constInt(pattern)) |v| try self.coverInts(cov, v, v, pattern.src.pos);
                    return;
                }
                cov.has_default = true;
                if (resolve.patternBinds(self.ctx.source, pattern)) {
                    if (self.ctx.symbolOf(pattern)) |sym| {
                        // A binding that is no plain data of a copy of the
                        // subject, or captured as a copy, is usable in its
                        // arm only.
                        const ty = try self.bindMatchView(pattern, mode, scrutinee);
                        const copied = self.arm_local or (mode == .read and !storage.catchAllCaptured(self.ctx, pattern, self.matching));
                        if (copied and mode == .read and sema.copies(self.ctx, sema.unwrapViews(self.ctx, scrutinee)) != .yes) self.ctx.symbols.items[sym].flags.arm_view = true;
                        try self.ctx.recordType(pattern, ty);
                    }
                }
            },
            .list => {
                const h = pattern.kind() orelse return;
                switch (h) {
                    .enum_lit => {
                        const name = ir.EnumLit.name(pattern);
                        // Against any error, `.name` is the member of the
                        // one error set that has it.
                        if (sema.unwrapViews(self.ctx, scrutinee) == self.t().any_error_id) {
                            const set = try self.resolveErrorName(name);
                            try self.ctx.recordType(pattern, set);
                            if (!self.isPoison(set)) try self.recordCovered(try self.errorArmKey(self.t().any_error_id, set, self.text(name)), self.startOf(pattern), cov);
                            return;
                        }
                        if (!self.isPoison(scrutinee) and (try sema.lookupVariant(self.ctx, scrutinee, self.text(name))) == null) {
                            try self.reportMissingVariant(scrutinee, self.text(name), srcPos(name, 0));
                        }
                        try self.ctx.recordType(pattern, scrutinee);
                        try self.recordCovered(self.text(name), self.startOf(pattern), cov);
                    },
                    .member => try self.checkQualifiedPattern(pattern, scrutinee, cov),
                    .variant_pattern => try self.checkVariantPattern(pattern, scrutinee, cov, mode),
                    .range_pattern => try self.checkRangePattern(pattern, scrutinee, cov),
                    else => {
                        try self.checkExpr(pattern, scrutinee);
                        if (self.constInt(pattern)) |v| try self.coverInts(cov, v, v, self.startOf(pattern));
                    },
                }
            },
            else => {},
        }
    }

    /// `lo..hi` matches `lo` up to, not including, `hi`, like every range.
    /// Both bounds are constant integers; `hi` may be one past the
    /// scrutinee type's largest value, so a range can reach it.
    fn checkRangePattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *MatchCoverage) Error!void {
        const lo_node = ir.RangePattern.lo(pattern);
        const pos = self.startOf(lo_node);
        try self.checkExpr(lo_node, scrutinee);
        const hi_node = ir.RangePattern.hi(pattern);
        const hi_literal = isIntLiteralNode(self.ctx.source, hi_node);
        const st = self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee));
        if (hi_literal and (st == .int or st == .int_literal)) {
            // Record the bound's type without the fit check a value gets.
            const bound_ty = if (st == .int) sema.unwrapViews(self.ctx, scrutinee) else self.t().int_id;
            try self.ctx.recordType(hi_node, bound_ty);
            if (hi_node.isKind(.neg)) try self.ctx.recordType(ir.Neg.operand(hi_node), bound_ty);
        } else try self.checkExpr(hi_node, scrutinee);
        if (self.isPoison(scrutinee)) return;
        const lo = self.constInt(lo_node);
        const hi = self.constInt(hi_node);
        if (lo == null or hi == null) {
            if (try self.perTarget(pattern, "the bounds of a range pattern")) return;
            try self.err(pos, "the bounds of a range pattern must be constant integers", .{});
            return;
        }
        if (st == .int) {
            const b = intBounds(st.int);
            if (hi.? > b.max + 1 or hi.? <= b.min) {
                try self.errAt(hi_node, "the end of range `{d}..{d}` does not fit `{s}`; it may be at most {d}, one past the largest value", .{ lo.?, hi.?, try self.tyName(scrutinee), b.max + 1 });
                return;
            }
        }
        if (lo.? >= hi.?) {
            try self.err(pos, "empty range `{d}..{d}`: a range pattern matches from its start up to, not including, its end", .{ lo.?, hi.? });
            return;
        }
        try self.coverInts(cov, lo.?, hi.? - 1, pos);
    }

    fn recordCovered(self: *Checker, name: []const u8, pos: u32, cov: *MatchCoverage) Error!void {
        if (cov.variantAt(name)) |first| {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            try self.note(first, "first arm here", .{});
            return;
        }
        try cov.variants.put(self.ctx.allocator, name, pos);
    }

    fn checkVariantPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *MatchCoverage, mode: MatchMode) Error!void {
        const name = ir.VariantPattern.name(pattern);
        const vname = self.text(name);
        const vpos = name.src.pos;
        const bindings = ir.VariantPattern.bindings(pattern);
        try self.recordCovered(vname, vpos, cov);
        if (sema.unwrapViews(self.ctx, scrutinee) == self.t().any_error_id) {
            try self.err(vpos, "an error has no payload to destructure; match it as `.{s}`", .{vname});
            for (bindings) |b| self.poisonBinding(sema.bindingName(b));
            return;
        }
        const resolved = (try sema.lookupVariant(self.ctx, scrutinee, vname)) orelse {
            try self.reportMissingVariant(scrutinee, vname, vpos);
            for (bindings) |b| self.poisonBinding(sema.bindingName(b));
            return;
        };
        if (resolved.payload.len == 0) {
            if (bindings.len > 0) try self.err(vpos, "variant `{s}` has no payload to destructure", .{vname});
            for (bindings) |b| self.poisonBinding(sema.bindingName(b));
            return;
        }
        const binds = (try self.fieldBindings(pattern, resolved.payload)) orelse {
            for (bindings) |b| self.poisonBinding(sema.bindingName(b));
            return;
        };
        try self.ctx.recordPayloadBindings(pattern, binds);
        for (binds, resolved.payload) |b, f| {
            // A field the pattern leaves out is read as a `_` field is.
            if (b == .nil) {
                // Read where the match reads in place when no instance
                // copies it.
                continue;
            }
            // The binding's type follows its access (`bindMatchView`).
            const view = !sema.isReadOrWriteView(self.ctx, f.ty) and self.ctx.types.get(f.ty) != .slice and !self.isPoison(f.ty);
            const ty = try self.bindMatchView(b, mode, f.ty);
            try self.ctx.recordType(b, ty);
            if (!self.isPoison(f.ty)) try self.ctx.recordPayloadField(b, f.ty);
            if (self.ctx.symbolOf(b)) |sym| {
                // A binding that is no plain data of a copy of the
                // subject is usable in its arm only.
                if (self.arm_local and mode == .read and view and sema.copies(self.ctx, f.ty) != .yes) self.ctx.symbols.items[sym].flags.arm_view = true;
            }
        }
    }

    /// How the match being checked reaches what its bindings bind
    /// (`sema.MatchReach`): it writes, takes, holds a value made there
    /// whole, or reads a value another holds.
    fn matchReach(self: *Checker, mode: MatchMode) Error!sema.MatchReach {
        return switch (mode) {
            .write => .written,
            .consume => .owned,
            .read => blk: {
                if (self.matching == .nil) break :blk .read;
                const subject = ir.Match.subject(self.matching);
                // A write view the subject makes, a call's or a branch of
                // write lends (`match (!a if c else !b)`), is lent on, as
                // `if … as` lends one on (`sema.makesWriteView`).
                if (try sema.makesWriteView(self.ctx, subject)) break :blk .written;
                // A value made here, an enum, an error, an integer, or a
                // Bool, is the match's whole.
                if (self.hands(subject).kind == .made) if (self.ctx.typeOf(subject)) |ty| switch (self.ctx.types.get(ty)) {
                    .nominal, .parameterized_nominal, .imported_nominal, .any_error, .int, .bool => break :blk .read_own,
                    else => {},
                };
                // Anything else is read.
                break :blk .read;
            },
        };
    }

    /// Give a `match` binding `b`, of a field or of the whole subject of
    /// type `reached`, its access (`sema.decideBindingAccess`, recorded on
    /// its symbol) and the type that access gives it: a write view of what
    /// it reaches, or a read view, `!T` read as `?T` and `![]T` as `[]T`,
    /// or, with no access, the copy or owner of `reached`. The one place a
    /// match binding's mode is decided (docs/INTERNALS.md, "Binding
    /// access").
    fn bindMatchView(self: *Checker, b: Sexp, mode: MatchMode, reached: TypeId) Error!TypeId {
        const access = if (self.isPoison(reached)) null else sema.decideBindingAccess(self.ctx, .{ .match = .{ .reach = try self.matchReach(mode), .reached = reached } });
        const ty = try self.viewOfAccess(access, reached);
        if (self.ctx.symbolOf(b)) |sym| {
            self.ctx.symbols.items[sym].access = access;
            self.ctx.symbols.items[sym].flags.access_decided = true;
            self.ctx.symbols.items[sym].ty = ty;
        }
        return ty;
    }

    /// The access of the binding of `if … as` or `while … as` of a value
    /// of type `inner` reached so (`sema.decideBindingAccess`); none for a
    /// poisoned value.
    fn asAccess(self: *Checker, reach: sema.AsReach, inner: TypeId) ?sema.Access {
        if (self.isPoison(inner)) return null;
        return sema.decideBindingAccess(self.ctx, .{ .as = .{ .reach = reach, .inner = inner } });
    }

    /// The type a binding with access `access` (`sema.decideBindingAccess`)
    /// has, of a value of type `reached`: a write view of it; a read view
    /// of it, a write view `!T` read as `?T` and `![]T` as `[]T`; or, with
    /// no access, the value, copied or owned. The one place any binding's
    /// type is built from its access: a match's, an `as`'s, and a loop's.
    fn viewOfAccess(self: *Checker, access: ?sema.Access, reached: TypeId) Error!TypeId {
        const a = access orelse return reached;
        return switch (a) {
            .write => switch (self.ctx.types.get(reached)) {
                .write_view => reached,
                else => try self.ctx.intern(.{ .write_view = reached }),
            },
            .read => switch (self.ctx.types.get(reached)) {
                .read_view, .slice, .string_view => reached,
                .write_view => |inner| switch (self.ctx.types.get(inner)) {
                    .slice => inner,
                    else => try self.ctx.intern(.{ .read_view = inner }),
                },
                else => if (sema.copies(self.ctx, reached) == .no) try self.ctx.intern(.{ .read_view = reached }) else reached,
            },
        };
    }

    /// The binding of each of `fields`, in field order, that the variant
    /// pattern `pattern` writes. A pattern binds a variant's fields either
    /// in order, all of them, or by name, any of them, and `.nil` stands
    /// for a field it leaves out (`sema.SemContext.payloadBindings`).
    /// Null after reporting a pattern that does neither.
    fn fieldBindings(self: *Checker, pattern: Sexp, fields: []const Field) Error!?[]const Sexp {
        const name = ir.VariantPattern.name(pattern);
        const vname = self.text(name);
        const bindings = ir.VariantPattern.bindings(pattern);
        var named: usize = 0;
        for (bindings) |b| {
            if (b.isKind(.kwarg)) named += 1;
        }
        if (named == 0) {
            if (bindings.len == fields.len) return bindings;
            try self.err(name.src.pos, "variant `{s}` has {d} payload field{s}, pattern destructures {d}; bind them all in order, or the ones you need by name: `.{s}({s}: x)`", .{
                vname, fields.len, plural(fields.len), bindings.len, vname, fields[0].name,
            });
            return null;
        }
        if (named < bindings.len) {
            try self.err(name.src.pos, "`.{s}` binds its fields both in order and by name; a pattern binds a variant's fields either in order, all of them, or by name, any of them", .{vname});
            return null;
        }
        const binds = try self.ctx.arena.allocator().alloc(Sexp, fields.len);
        @memset(binds, .nil);
        var ok = true;
        for (bindings) |b| {
            const field = ir.Kwarg.name(b);
            const fname = self.text(field);
            const i = (try sema.findMember(self.ctx, fields, fname, .any)) orelse {
                const likely = memberSuggest(fields, fname, .field);
                try self.err(field.src.pos, "no field `{s}` on variant `{s}`{s}", .{ fname, vname, try likely.hint(self.ctx.arena.allocator()) });
                ok = false;
                continue;
            };
            if (binds[i] != .nil) {
                try self.err(field.src.pos, "field `{s}` is bound twice", .{fname});
                try self.note(self.startOf(binds[i]), "first bound here", .{});
                ok = false;
                continue;
            }
            binds[i] = ir.Kwarg.value(b);
        }
        return if (ok) binds else null;
    }


    fn reportMissingVariant(self: *Checker, enum_ty: TypeId, vname: []const u8, pos: u32) Error!void {
        const decl = sema.nominalDecl(self.ctx, enum_ty) orelse {
            if (!self.isPoison(enum_ty)) {
                try self.err(pos, "`.{s}` is an enum variant, but the expected type `{s}` is not an enum", .{ vname, try self.tyName(enum_ty) });
            }
            return;
        };
        const sym = decl.symbol();
        if (sym.fields == null) return;
        try self.err(pos, "no variant `{s}` on enum `{s}`", .{ vname, try self.tyName(sema.unwrapViews(self.ctx, enum_ty)) });
        try self.noteDeclared(sym, decl.module_id == null);
    }

    /// Point at where type `sym` is declared, when that is in this
    /// module's source (`local`), or where the generic type a proxy
    /// stands for is.
    fn noteDeclared(self: *Checker, sym: sema.Symbol, local: bool) Error!void {
        if (sema.isProxy(sym)) {
            const origin = sema.proxyOrigin(self.ctx, sym) orelse return;
            return self.ctx.noteIn(origin.module_id, origin.pos, "`{s}` declared here", .{sym.name});
        }
        if (local and sym.decl_pos < sema.imported_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
    }

    // =========================================================================
    // Expressions: synthesis
    // =========================================================================

    fn synthExpr(self: *Checker, e: Sexp) Error!TypeId {
        const ty = switch (e) {
            .nil => self.t().void_id,
            .src => try self.synthLeaf(e),
            .str => self.t().static_id,
            .tag => self.t().invalid_id,
            .list => if (e.kind() == null) self.t().invalid_id else try self.synthList(e),
        };
        if (try self.cellMadeAway(e, ty)) {
            try self.ctx.recordType(e, self.t().invalid_id);
            return self.t().invalid_id;
        }
        try self.ctx.recordType(e, self.canonical(ty));
        try self.noteTakeable(e, ty);
        return ty;
    }

    /// Whether `e`, of type `ty`, makes a value holding a Cell by value
    /// where none may stand (`sema.misplaced`): such a value lives only
    /// behind a shared handle, so it is made only as the operand of `*`
    /// (`shared_operand`), as a field of a value made there, or as a
    /// field's default (`cell_home`). A call makes one; so does a value
    /// that branches (`sema.yieldsPart`) with a leaf a name holds, which
    /// would copy the Cell's holder out of its place while another handle
    /// changes the Cell. Such a branch is read only in place
    /// (`in_place`: a receiver, or the operand of a lend), or lent on each
    /// branch. True when reported.
    fn cellMadeAway(self: *Checker, e: Sexp, ty: TypeId) Error!bool {
        if (!e.isKind(.call) and !sema.yieldsPart(e)) return false;
        if (self.isPoison(ty) or !sema.holdsCellByValue(self.ctx, ty)) return false;
        // Typed only to infer a call's type arguments, it stands nowhere
        // yet: it is decided where it is checked.
        if (sameNode(e, self.shared_operand) or sameNode(e, self.cell_home) or self.ctx.quiet > 0) return false;
        if (!e.isKind(.call)) return self.cellCopiedByBranch(e, ty);
        const src = self.sourceText(e);
        try self.errAt(e, "`{s}` makes a `{s}`, which holds a Cell, so it lives only behind a shared handle: write `*{s}`", .{ src, try self.tyName(ty), src });
        return true;
    }

    /// `cellMadeAway` for a branching value `e`: rejected when a leaf is
    /// a place (a value a name holds, or a part of one), by a positive
    /// list of what may stand there: a value made there, a lend, a jump,
    /// or a constant.
    fn cellCopiedByBranch(self: *Checker, e: Sexp, ty: TypeId) Error!bool {
        if (sameNode(e, self.in_place)) return false;
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
        var place: Sexp = .nil;
        for (leaves.items) |leaf| switch (self.hands(leaf).kind) {
            .made, .lend, .jump => {},
            .place, .part_of_made, .branches, .none => if (!try self.isConstant(leaf)) {
                place = leaf;
                break;
            },
        };
        if (place == .nil) return false;
        const a = self.ctx.arena.allocator();
        const withs = try a.alloc([]const u8, leaves.items.len);
        for (leaves.items, withs) |leaf, *w| w.* = switch (self.hands(leaf).kind) {
            .made, .lend, .jump => self.sourceText(leaf),
            else => try a.print("?{s}", .{self.sourceText(leaf)}),
        };
        const src = self.sourceText(e);
        const multiline = std.mem.indexOfScalar(u8, src, '\n') != null;
        const what = if (multiline) "this value" else try a.print("`{s}`", .{src});
        const fix = if (multiline) "put a `?` before each branch's value" else try a.print("`{s}`", .{try self.spliced(e, leaves.items, withs)});
        try self.errAt(e, "{s} would copy a `{s}`, which holds a Cell, out of `{s}`, while another handle may change the Cell; lend each branch: {s}", .{ what, try self.tyName(ty), self.sourceText(place), fix });
        return true;
    }

    /// An optional field or element that moves, which a diagnostic may
    /// offer to take with `<e`: recorded when the take's own check
    /// (`requireAccess` of `.take`) would reject it, its diagnostics
    /// dropped.
    fn noteTakeable(self: *Checker, e: Sexp, ty: TypeId) Error!void {
        if (!e.isKind(.member) and !e.isKind(.index)) return;
        if (self.ctx.types.get(ty) != .optional or sema.moves(self.ctx, ty) != .yes) return;
        if (sema.moveSource(self.ctx, e) != .optional_part) return;
        const mark = self.ctx.diagnostics.items.len;
        const place = self.placeOf(e);
        const ok = place.cell_list_elem == null and try self.requireAccess(place, .take, e);
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        if (!ok) try self.ctx.recordUntakeable(e);
    }

    /// Literal pseudo-types as the concrete type they default to.
    fn canonical(self: *Checker, ty: TypeId) TypeId {
        if (ty == self.t().int_literal_id) return self.t().int_id;
        if (ty == self.t().float_literal_id) return self.t().float_id;
        return ty;
    }

    /// A double-quoted string literal's escapes: `\n`, `\r`, `\t`, `\\`,
    /// `\'`, `\"`, `\xNN`, and `\u{N...}`. A single-quoted string takes
    /// no escapes.
    fn checkEscapes(self: *Checker, leaf: Sexp) Error!void {
        const s = self.text(leaf);
        if (s.len == 0 or s[0] != '"') return;
        const pos = leaf.src.pos;
        var i: usize = 1;
        while (i + 1 < s.len) : (i += 1) {
            if (s[i] != '\\') continue;
            const c = s[i + 1];
            const ok = switch (c) {
                'n', 'r', 't', '\\', '\'', '"' => true,
                'x' => i + 3 < s.len and std.ascii.isHex(s[i + 2]) and std.ascii.isHex(s[i + 3]),
                'u' => blk: {
                    if (i + 2 >= s.len or s[i + 2] != '{') break :blk false;
                    var j = i + 3;
                    var digits: usize = 0;
                    while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) digits += 1;
                    if (j >= s.len or s[j] != '}' or digits == 0 or digits > 6) break :blk false;
                    const v = std.fmt.parseInt(u32, s[i + 3 .. j], 16) catch break :blk false;
                    break :blk v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF);
                },
                else => false,
            };
            if (!ok) {
                try self.err(pos + @as(u32, @intCast(i)), "invalid escape `\\{c}` in a string; the escapes are `\\n`, `\\r`, `\\t`, `\\\\`, `\\'`, `\\\"`, `\\xNN`, and `\\u{{N}}`", .{c});
                return;
            }
            i += 1;
        }
    }

    fn synthLeaf(self: *Checker, leaf: Sexp) Error!TypeId {
        const s = self.text(leaf);
        if (s.len == 0) return self.t().invalid_id;
        if (s[0] == '"' or s[0] == '\'') {
            try self.checkEscapes(leaf);
            return self.t().static_id;
        }
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return self.t().bool_id;
        if (std.mem.eql(u8, s, "none")) return self.t().none_id;
        if (sema.isFloatLiteralText(s)) {
            if (!std.math.isFinite(floatLiteralValue(s))) {
                try self.errAt(leaf, "float literal `{s}` is too large", .{s});
                return self.t().invalid_id;
            }
            return self.t().float_literal_id;
        }
        if (sema.isIntLiteralText(s)) {
            if (std.fmt.parseInt(u128, s, 0)) |_| {} else |_| {
                try self.errAt(leaf, "integer literal `{s}` is too large", .{s});
                return self.t().invalid_id;
            }
            return self.t().int_literal_id;
        }
        const id = (try self.useName(leaf)) orelse return self.t().unknown_id;
        const sym = self.ctx.symbols.items[id];
        switch (sym.kind) {
            .nominal_type, .generic_type, .type_alias, .generic_param => {
                try self.errAt(leaf, "`{s}` is a type, not a value", .{s});
                return self.t().invalid_id;
            },
            .module => {
                try self.errAt(leaf, "`{s}` is a module, not a value; use `{s}.name`", .{ s, s });
                return self.t().invalid_id;
            },
            .@"extern" => if (self.ctx.types.get(sym.ty) == .function) {
                try self.errAt(leaf, "an extern function can only be called, inside `raw`", .{});
                return self.t().invalid_id;
            } else return sym.ty,
            .function => {
                if (self.isEntryPoint(sym)) {
                    try self.errAt(leaf, entry_point_use, .{});
                    return self.t().invalid_id;
                }
                return self.functionValue(sym.ty, s, leaf.src.pos, sym.flags.inline_marked);
            },
            else => return sym.ty,
        }
    }

    const entry_point_use = "`main` is the program's entry point; it cannot be called or used as a value";

    /// The root module's `main`, which only the program calls.
    fn isEntryPoint(self: *Checker, sym: sema.Symbol) bool {
        return self.ctx.is_root and sym.kind == .function and sym.scope == sema.module_scope and std.mem.eql(u8, sym.name, "main");
    }

    /// A function named as a value. One with compile-time parameters has
    /// an instance per call, and no single function value; an `inline fun`
    /// is inlined at every call, and has no address.
    fn functionValue(self: *Checker, ty: TypeId, name: []const u8, pos: u32, inline_marked: bool) Error!TypeId {
        if (inline_marked) {
            try self.err(pos, "`{s}` is `inline`, inlined at every call, so it can only be called, not used as a value; to pass it, wrap the call in a closure", .{name});
            return self.t().invalid_id;
        }
        const f = self.ctx.types.get(ty);
        if (f == .function and f.function.ct_params.len != 0) {
            try self.err(pos, "`{s}` takes compile-time parameters, so it can only be called, not used as a value", .{name});
            return self.t().invalid_id;
        }
        return ty;
    }

    /// Resolve an identifier use, record the fact, and diagnose unbound
    /// names and outer locals referenced from inside a closure.
    fn useName(self: *Checker, leaf: Sexp) Error!?SymbolId {
        if (leaf != .src) return null;
        const name = self.text(leaf);
        if (std.mem.eql(u8, name, "_")) {
            try self.errAt(leaf, discard_read, .{});
            return null;
        }
        var sid: ?ScopeId = self.scope;
        var crossed_lambda = false;
        while (sid) |s| {
            if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
            if (self.visibleIn(s, name, leaf.src.pos)) |id| {
                try self.ctx.recordName(leaf, id);
                const sym = self.ctx.symbols.items[id];
                const kind = sym.kind;
                if (kind == .local and sym.ty == self.t().unknown_id and sym.decl_pos != leaf.src.pos) {
                    try self.errAt(leaf, "`{s}` is used before it has a value", .{name});
                }
                if (crossed_lambda and s != self.module_scope and (kind == .local or kind == .param or kind == .capture)) {
                    try self.errAt(leaf, "`{s}` is a local of the enclosing function; capture it to use it inside the closure (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|?{s}|` or `|!{s}|` lends it, `|~{s}|` holds it weakly)", .{ name, name, name, name, name, name });
                }
                return id;
            }
            const scope = self.ctx.scopes.items[s];
            if (scope.kind == .lambda) crossed_lambda = true;
            sid = scope.parent;
        }
        // A generic type's type parameters are in scope only as types; its
        // value parameters are compile-time values in its methods.
        const type_param = for (self.nominal.type_params) |tp| {
            if (!std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) continue;
            if (self.ctx.symbols.items[tp].kind == .param) {
                try self.ctx.recordName(leaf, tp);
                return tp;
            }
            break true;
        } else false;
        if (type_param or resolve.isBuiltinTypeName(self.ctx, name)) {
            try self.errAt(leaf, "`{s}` is a type, not a value", .{name});
            return null;
        }
        if (std.mem.eql(u8, name, "print")) {
            try self.errAt(leaf, "`print` is called with parentheses: `print(...)`", .{});
            return null;
        }
        // Inside a type's methods, a field or method is reached through
        // the receiver.
        if (!self.nominal.isEmpty()) {
            const has_self = self.lookupAt(self.scope, "self", leaf.src.pos) != null;
            const method = self.body.name;
            if (std.mem.eql(u8, name, "self") and method != .nil) {
                try self.errAt(leaf, "use of unbound name `self`; `{s}` declares no receiver: write `{s} {s}(?self)`, `(!self)`, or `(<self)`", .{ self.text(method), if (self.body.is_sub) "sub" else "fun", self.text(method) });
                return null;
            }
            if (self.ctx.symbols.items[self.nominal.sym].fields) |members| for (members) |m| {
                if (m.is_variant or !std.mem.eql(u8, m.name, name)) continue;
                const call: []const u8 = if (m.is_method) "(...)" else "";
                if (has_self) {
                    try self.errAt(leaf, "use of unbound name `{s}`; did you mean `self.{s}{s}`?", .{ name, name, call });
                } else try self.errAt(leaf, "use of unbound name `{s}`; `{s}` is a member of `{s}`, reached through a receiver: declare `(?self)` and write `self.{s}{s}`", .{ name, name, self.ctx.symbols.items[self.nominal.sym].name, name, call });
                return null;
            };
        }
        try self.errAt(leaf, "use of unbound name `{s}`{s}", .{ name, try self.unboundHint(leaf, name) });
        return null;
    }

    /// The member of `members` a name not found among them is a typo
    /// of: a data field, a method, or (called through the type) a
    /// method or variant.
    fn memberHint(self: *Checker, members: []const Field, name: []const u8, want: MemberKind) Error![]const u8 {
        return memberSuggest(members, name, want).hint(self.ctx.arena.allocator());
    }

    const MemberKind = enum { field, method, associated };

    fn memberSuggest(members: []const Field, name: []const u8, want: MemberKind) sema.Suggest {
        var s: sema.Suggest = .{ .name = name };
        for (members) |m| {
            if (m.is_drop_method) continue;
            const ok = switch (want) {
                .field => !m.is_method and !m.is_variant,
                .method => m.is_method,
                .associated => m.is_method or m.is_variant,
            };
            if (ok) s.offer(m.name);
        }
        return s;
    }

    /// What a name not found here was likely meant as: another
    /// language's spelling of a Rig one, or a visible name it is a typo
    /// of.
    fn unboundHint(self: *Checker, leaf: Sexp, name: []const u8) Error![]const u8 {
        if (sema.retiredNameHint(name)) |hint| return hint;
        const other = try self.ctx.otherFileUse(name);
        if (other.len > 0) return other;
        const Other = struct { []const u8, []const u8 };
        const others = [_]Other{
            .{ "null", "; Rig's absent value is `none`" },
            .{ "nil", "; Rig's absent value is `none`" },
            .{ "None", "; Rig's absent value is `none`" },
            .{ "NULL", "; Rig's absent value is `none`" },
            .{ "True", "; Rig writes `true`" },
            .{ "False", "; Rig writes `false`" },
            .{ "this", "; a method's receiver is `self`, declared as `(?self)`, `(!self)`, or `(<self)`" },
            .{ "self", "; `self` is the receiver of a method that declares one: `(?self)`, `(!self)`, or `(<self)`" },
            .{ "len", "; a length is a member: `x.len`" },
            .{ "println", "; Rig prints a line with `print(...)`" },
            .{ "puts", "; Rig prints a line with `print(...)`" },
            .{ "printf", "; Rig prints a line with `print(...)`" },
        };
        for (others) |o| if (std.mem.eql(u8, name, o[0])) return o[1];
        var s: sema.Suggest = .{ .name = name };
        self.ctx.offerVisible(&s, self.scope, leaf.src.pos, struct {
            fn keep(sym: sema.Symbol) bool {
                return sym.decl_pos != sema.builtin_decl_pos or sym.kind != .local;
            }
        }.keep);
        for ([_][]const u8{ "true", "false", "print" }) |w| s.offer(w);
        return s.hint(self.ctx.arena.allocator());
    }

    /// The binding `name` denotes at `pos` among those declared directly
    /// in `scope`: the latest one whose declaration comes before `pos`,
    /// excluding a `new x = ...` whose value is still being checked (its
    /// right side reads the previous `x`).
    fn visibleIn(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
        // A module is named where a `use` of its file binds it.
        if (scope == self.module_scope) if (self.ctx.fileModule(name, pos)) |id| return id;
        var id = self.ctx.lookupInScopeOnly(scope, name) orelse return null;
        while (id != sema.symbol_invalid) {
            const sym = self.ctx.symbols.items[id];
            // A module-level constant is visible in every function body,
            // and in every constant (`SemContext.const_order`).
            const later = sym.decl_pos > pos and scope != self.module_scope;
            if (sym.kind == .local and (later or id == self.pending or std.mem.findScalar(SymbolId, self.pending_names, id) != null)) {
                id = sym.prev_in_scope;
                continue;
            }
            return id;
        }
        return null;
    }

    fn synthList(self: *Checker, e: Sexp) Error!TypeId {
        const head = e.kind().?;
        return switch (head) {
            .call => self.synthCall(e),
            .member => self.synthMember(e),
            .index, .inst => self.synthIndex(e),
            .propagate => self.synthPropagate(e),
            .propagate_none => self.synthPropagateNone(e),
            .@"if" => self.checkIfValue(e, null, .value),
            .match => self.checkMatch(e, .value, null),
            .block => self.synthBlock(e, null),
            .raw_block => blk: {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                break :blk self.synthExpr(ir.RawBlock.body(e));
            },
            .read => self.synthLend(e, .read),
            .write => self.synthLend(e, .write),
            .move => self.synthMove(e),
            .share => self.synthShare(e),
            .box => self.synthBox(e, null),
            .weak => self.synthWeak(e),
            .clone => self.synthClone(e),
            .@"+", .@"-", .@"*", .@"/", .@"%" => self.checkNumericOperands(e, @tagName(head), .numeric, null),
            .@"&", .@"|", .@"^", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|" => self.checkNumericOperands(e, @tagName(head), .integer, null),
            .@"<<", .@"<<%", .@">>" => self.synthShift(e, @tagName(head)),
            .@"<", .@">", .@"<=", .@">=" => self.synthOrdering(e, @tagName(head)),
            .@"==", .@"!=" => self.synthEquality(e),
            .@"and", .@"or" => blk: {
                const saved_op = self.logic_op;
                const saved_operands = self.logic_operands;
                defer {
                    self.logic_op = saved_op;
                    self.logic_operands = saved_operands;
                }
                self.logic_op = @tagName(head);
                self.logic_operands = .{ ir.get(e, .left), ir.get(e, .right) };
                try self.checkExpr(ir.get(e, .left), self.t().bool_id);
                try self.checkExpr(ir.get(e, .right), self.t().bool_id);
                break :blk self.t().bool_id;
            },
            .not => blk: {
                const saved_not = self.not_operand;
                defer self.not_operand = saved_not;
                self.not_operand = ir.Not.operand(e);
                try self.checkExpr(ir.Not.operand(e), self.t().bool_id);
                try self.checkNotScope(e);
                break :blk self.t().bool_id;
            },
            .neg => self.synthNeg(e),
            .@"??" => self.synthCoalesce(e, null),
            .@"catch" => self.synthCatch(e, null),
            .array => self.synthArray(e),
            .array_fill => self.checkArrayFill(e, null),
            .enum_lit => blk: {
                const name = self.text(ir.EnumLit.name(e));
                try self.errAt(e, "enum literal `.{s}` needs a known enum type; write `Type.{s}` or annotate the binding", .{ name, name });
                break :blk self.t().invalid_id;
            },
            .lambda => self.checkLambda(e, null),
            .builtin => self.synthBuiltin(e, null),
            .@"..",
            => blk: {
                try self.errAt(e, "a range `a..b` can only be used as a `for` loop source", .{});
                break :blk self.t().invalid_id;
            },
            .@"while", .@"for", .labeled, .set, .destructure, .drop, .@"defer", .@"errdefer" => if (self.isValueLoop(e)) self.checkLoopValue(e, null, true) else blk: {
                try self.checkStmt(e);
                break :blk self.t().void_id;
            },
            .pass => blk: {
                try self.errAt(e, "`pass` does nothing and has no value, and a value is needed here", .{});
                break :blk self.t().invalid_id;
            },
            .@"return" => blk: {
                try self.checkReturn(e);
                break :blk self.t().noreturn_id;
            },
            .@"break", .@"continue" => blk: {
                try self.checkStmt(e);
                break :blk self.t().noreturn_id;
            },
            .as => blk: {
                try self.errAt(e, "`as` binds only in the condition of an `if` or `while` block, alone or joined to the rest by `and`", .{});
                _ = try self.synthExpr(ir.As.value(e));
                break :blk self.t().invalid_id;
            },
            .as_results => blk: {
                try self.errAt(e, "`as` binds only in the condition of an `if` or `while` block, alone or joined to the rest by `and`", .{});
                _ = try self.synthQuiet(ir.AsResults.value(e));
                for (ir.AsResults.names(e).items()) |n| if (n.isKind(.set)) try self.poisonTarget(n);
                break :blk self.t().invalid_id;
            },
            .kwarg => blk: {
                try self.errAt(e, "`name: value` is only allowed as a call argument", .{});
                break :blk self.t().invalid_id;
            },
            // A destructure's target takes the result in its position.
            .result_part => self.part_ty,
            .tuple => self.tupleValue(e),
            else => blk: {
                try self.errAt(e, "`{s}` expressions are not supported", .{@tagName(head)});
                break :blk self.t().invalid_id;
            },
        };
    }

    // ---- operators ------------------------------------------------------------

    /// The operands of binary operator `(op left right)`: both numeric
    /// (or integer) and of one type. Literals adapt to the other operand;
    /// generic parameters record a requirement. `synthesized` holds the
    /// operands' types when the caller has synthesized them.
    fn checkNumericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
        const ty = try self.numericOperands(e, op, req, synthesized);
        if (self.isPoison(ty)) return ty;
        if (!(try self.checkDivisor(e.kind().?, ty, ir.get(e, .right)))) return self.t().invalid_id;
        try self.checkConstantFits(e, ty);
        // Literals default to `Float` unless a type is given them later.
        if (ty == self.t().float_literal_id) {
            try self.checkWholeDivision(e);
            try self.checkFloatConstant(e, self.t().float_id);
        } else if (self.ctx.types.get(ty) == .float) try self.checkFloatConstant(e, ty);
        return ty;
    }

    /// Constant operands are computed now, so an integer result must fit.
    /// (The constant parts of an operation that is not constant were
    /// checked as operands.)
    fn checkConstantFits(self: *Checker, e: Sexp, ty: TypeId) Error!void {
        if (self.ctx.types.get(ty) != .int or sema.constInt(self.ctx, e) == .not_constant) return;
        try self.checkLiteralFits(e, ty);
    }

    /// `checkNumericOperands` where two literal operands, which take no
    /// type from each other, are `Int`s.
    fn checkIntDefaultOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
        const ty = try self.checkNumericOperands(e, op, req, synthesized);
        if (ty != self.t().int_literal_id) return ty;
        try self.defaultIntLiteral(ir.get(e, .left));
        try self.defaultIntLiteral(ir.get(e, .right));
        return self.t().int_id;
    }

    /// `a < b`, `<=`, `>`, `>=`: two numbers as for arithmetic, two
    /// values of one plain enum, by their variants' values, or two
    /// Strings or two `[]U8` slices, ordered by their bytes.
    fn synthOrdering(self: *Checker, e: Sexp, op: []const u8) Error!TypeId {
        const l = ir.get(e, .left);
        const r = ir.get(e, .right);
        // A `.variant` takes its enum type from the other side, as beside
        // `==`.
        if (l.isKind(.enum_lit) != r.isKind(.enum_lit)) {
            const lit, const other = if (l.isKind(.enum_lit)) .{ l, r } else .{ r, l };
            const ty = try self.synthReached(other);
            if (self.isPoison(ty)) return self.t().bool_id;
            const mark = self.ctx.diagnostics.items.len;
            try self.checkExpr(lit, ty);
            if (self.ctx.diagnostics.items.len == mark) try self.checkOrderedEnum(l, ty, op);
            return self.t().bool_id;
        }
        const a = try self.synthReached(l);
        const b = try self.synthReached(r);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
        if (self.enumValues(a) != null or self.enumValues(b) != null) {
            if (a != b) {
                try self.errAt(l, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
            } else try self.checkOrderedEnum(l, a, op);
            return self.t().bool_id;
        }
        // Lane by lane: a mask.
        if (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null) {
            const vt = try self.simdOperands(e, op, .ordered, a, b);
            return if (self.isPoison(vt)) vt else self.maskOf(self.ctx.types.get(vt).simd);
        }
        if (!self.isBytes(a) and !self.isBytes(b)) {
            _ = try self.checkIntDefaultOperands(e, op, .ordered, .{ a, b });
            return self.t().bool_id;
        }
        // Ordering reads both texts: a `Static` beside a `?String`.
        const a_read = if (a == self.t().static_id) self.t().string_view_id else a;
        const b_read = if (b == self.t().static_id) self.t().string_view_id else b;
        if (a_read != b_read) try self.errAt(l, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
        return self.t().bool_id;
    }

    /// Two values of type `ty` ordered by operator `op`, at `at`, where
    /// one is an enum's: a plain enum orders by its variants' values.
    fn checkOrderedEnum(self: *Checker, at: Sexp, ty: TypeId, op: []const u8) Error!void {
        if (sema.isOrderedEnum(self.ctx, ty)) return;
        const builtin = switch (self.ctx.types.get(ty)) {
            .nominal => |sym| sema.isBuiltinEnum(self.ctx, sym),
            else => false,
        };
        if (builtin) {
            try self.errAt(at, "operator `{s}` orders a declared enum's values; the built-in enum `{s}` has no integer value", .{ op, try self.tyName(ty) });
        } else if (self.ctx.types.get(ty) == .parameterized_nominal) {
            try self.errAt(at, "operator `{s}` orders a plain enum's values; `{s}` is a generic enum, whose variants have no integer value", .{ op, try self.tyName(ty) });
        } else if (self.enumValues(ty) == false) {
            try self.errAt(at, "operator `{s}` orders a plain enum's values; `{s}` has variants with payloads, which have no integer value", .{ op, try self.tyName(ty) });
        } else try self.errAt(at, ordering_operands, .{ op, try self.tyName(ty) });
    }

    /// `not` applies to the whole comparison after it: `not a > b` is
    /// `not (a > b)`, which reads as `(not a) > b` too. So a comparison
    /// directly under `not` is written in parentheses, or flipped where
    /// the flip means the same: `a <= b` for integers and text, `a != b`
    /// for any `==`. (`not (a > b)` is not `a <= b` for a Float NaN.)
    fn checkNotScope(self: *Checker, e: Sexp) Error!void {
        const operand = ir.Not.operand(e);
        const op: []const u8, const flipped: []const u8 = switch (operand.kind() orelse return) {
            .@"==" => .{ "==", "!=" },
            .@"!=" => .{ "!=", "==" },
            .@"<" => .{ "<", ">=" },
            .@">" => .{ ">", "<=" },
            .@"<=" => .{ "<=", ">" },
            .@">=" => .{ ">=", "<" },
            else => return,
        };
        const whole = self.ctx.span(e);
        const cmp = self.ctx.span(operand);
        // Written in parentheses: `not` ends past its operand, at `)`.
        if (whole.end > cmp.end) return;
        const a = self.ctx.arena.allocator();
        const shown = try oneLine(self.ctx.arena.allocator(), try withoutComments(self.ctx.arena.allocator(), self.sourceText(operand)));
        const equality = op[0] == '=' or op[0] == '!';
        const exact = equality or (self.flipsExactly(ir.get(operand, .left)) and self.flipsExactly(ir.get(operand, .right)));
        // The operator, between the two sides' spans (and any
        // parentheses around them).
        const gap_start = self.ctx.span(ir.get(operand, .left)).end;
        const gap_end = self.ctx.span(ir.get(operand, .right)).start;
        const at = if (exact and gap_start <= gap_end) std.mem.find(u8, diag.textBetween(self.ctx.source, gap_start, gap_end), op) else null;
        if (at) |i| {
            const o = gap_start + i;
            const flip = try oneLine(a, try withoutComments(a, try std.mem.concat(a, u8, &.{ diag.textBetween(self.ctx.source, cmp.start, o), flipped, diag.textBetween(self.ctx.source, o + op.len, cmp.end) })));
            return self.errAt(e, "write `{s}`, or `not ({s})`: `not` applies to the whole comparison", .{ flip, shown });
        }
        try self.errAt(e, "write `not ({s})`: `not` applies to the whole comparison", .{shown});
    }

    /// Whether a side of an ordering keeps its meaning when the ordering
    /// is flipped (`not (a > b)` is `a <= b`): an integer, a plain enum,
    /// or text, which are totally ordered, unlike a Float.
    fn flipsExactly(self: *Checker, side: Sexp) bool {
        const ty = self.ctx.typeOf(side) orelse return false;
        const v = sema.unwrapViews(self.ctx, ty);
        return sema.isInteger(self.ctx, v) or self.isBytes(v) or sema.isOrderedEnum(self.ctx, v);
    }

    /// A `?String` or a `[]U8`: bytes ordered as text is.
    fn isBytes(self: *Checker, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .string_view, .static => true,
            .slice => |s| switch (self.ctx.types.get(s.elem)) {
                .int => |info| info.bits == 8 and !info.signed,
                else => false,
            },
            else => false,
        };
    }

    /// Integer division by a constant zero is rejected; float division
    /// gives an infinity or NaN.
    fn checkDivisor(self: *Checker, op: Tag, ty: TypeId, divisor: Sexp) Error!bool {
        if (op != .@"/" and op != .@"%") return true;
        switch (self.ctx.types.get(ty)) {
            .float, .float_literal => return true,
            else => {},
        }
        if ((self.constInt(divisor) orelse return true) != 0) return true;
        try self.errAt(divisor, "division by zero", .{});
        return false;
    }

    /// `a << n` / `a >> n`: the result has the type of the integer `a`.
    fn synthShift(self: *Checker, e: Sexp, op: []const u8) Error!TypeId {
        const left = ir.get(e, .left);
        const ty = try self.synthOperandValue(left);
        if (self.isPoison(ty)) {
            _ = try self.synthExpr(ir.get(e, .right));
            return ty;
        }
        // A vector of integers shifts each lane by one amount, with the
        // rules of its lane type.
        if (sema.simdOf(self.ctx, ty)) |v| {
            if (!sema.isInteger(self.ctx, v.elem)) {
                try self.errAt(left, "operator `{s}` requires integer lanes; got `{s}`", .{ op, try self.tyName(sema.unwrapViews(self.ctx, ty)) });
                _ = try self.synthExpr(ir.get(e, .right));
                return self.t().invalid_id;
            }
            if (!(try self.checkShiftAmount(ir.get(e, .right), v.elem, op))) return self.t().invalid_id;
            return sema.unwrapViews(self.ctx, ty);
        }
        switch (self.ctx.types.get(ty)) {
            .type_var => |tv| try self.require(tv, .integer, self.startOf(left), op),
            else => if (!sema.isInteger(self.ctx, ty)) {
                try self.errAt(left, "operator `{s}` requires integer operands; got `{s}`", .{ op, try self.tyName(ty) });
                _ = try self.synthExpr(ir.get(e, .right));
                return self.t().invalid_id;
            },
        }
        if (!(try self.checkShiftAmount(ir.get(e, .right), ty, op))) return self.t().invalid_id;
        try self.checkConstantFits(e, ty);
        return ty;
    }

    /// A shift amount may be any integer; a constant one must be below
    /// the width of the shifted type. A literal's is checked when it
    /// takes its type (`recordLiteralType`).
    fn checkShiftAmount(self: *Checker, amount: Sexp, shifted: TypeId, op: []const u8) Error!bool {
        const ty = try self.synthOperandValue(amount);
        if (self.isPoison(ty)) return false;
        switch (self.ctx.types.get(ty)) {
            .type_var => |tv| try self.require(tv, .integer, self.startOf(amount), op),
            else => if (!sema.isInteger(self.ctx, ty)) {
                const each = if (sema.simdOf(self.ctx, ty) != null) "; a vector's lanes all shift by one integer" else "";
                try self.errAt(amount, "a shift amount must be an integer; got `{s}`{s}", .{ try self.tyName(ty), each });
                return false;
            },
        }
        const v = self.constInt(amount) orelse return true;
        const width: ?Wide = switch (self.ctx.types.get(shifted)) {
            .int => |info| intBounds(info).bits,
            .type_var => |tv| blk: {
                if (v >= 0) try self.require(tv, .{ .shift = v }, self.startOf(amount), op);
                break :blk null;
            },
            else => null,
        };
        if (v >= 0 and (width == null or v < width.?)) return true;
        if (width) |w| {
            try self.errAt(amount, "shift amount `{d}` is out of range for `{s}` (0..{d})", .{ v, try self.tyName(self.canonical(shifted)), w - 1 });
        } else try self.errAt(amount, "shift amount `{d}` is negative", .{v});
        return false;
    }

    fn constInt(self: *Checker, e: Sexp) ?Wide {
        return sema.constIntOf(self.ctx, e);
    }

    fn numericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
        const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
        const a = if (synthesized) |ts| ts[0] else try self.synthOperandValue(operands[0]);
        const b = if (synthesized) |ts| ts[1] else try self.synthOperandValue(operands[1]);
        const pos = self.startOf(operands[0]);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().invalid_id;
        if (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null) return self.simdOperands(e, op, req, a, b);

        const ta = self.ctx.types.get(a);
        const tb = self.ctx.types.get(b);
        if (ta == .type_var or tb == .type_var) {
            const tv = if (ta == .type_var) a else b;
            const other = if (ta == .type_var) b else a;
            if (!self.meetsTypeVar(tv, other, req)) {
                try self.err(pos, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
                return self.t().invalid_id;
            }
            const param = self.ctx.types.get(tv).type_var;
            try self.require(param, req, pos, op);
            try self.requireHoldsLiteral(param, other, if (ta == .type_var) operands[1] else operands[0], pos, op);
            return tv;
        }

        const want_int = req == .integer;
        for ([_]TypeId{ a, b }, 0..) |ty, i| {
            const ok = if (want_int) sema.isInteger(self.ctx, ty) else sema.isNumeric(self.ctx, ty);
            if (!ok) {
                if (req == .ordered) {
                    try self.errAt(operands[i], ordering_operands, .{ op, try self.tyName(ty) });
                } else {
                    // String is built, not added: `String(a, b)`, `!t.add(b)`.
                    const is_text = ty == self.t().string_view_id or ty == self.t().static_id or ty == self.t().string_id;
                    const hint = if (is_text and std.mem.eql(u8, op, "+")) "; Rig has no `+` on text: build it with `String(a, b)` or `!t.add(...)`" else "";
                    try self.errAt(operands[i], "operator `{s}` requires {s} operands; got `{s}`{s}", .{ op, if (want_int) "integer" else "numeric", try self.tyName(ty), hint });
                }
                return self.t().invalid_id;
            }
        }
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        if (a_lit and b_lit) {
            if (a == self.t().int_literal_id and b == self.t().int_literal_id) return a;
            // The integer literals become floats.
            for ([_]TypeId{ a, b }, operands) |ty, o| if (ty == self.t().int_literal_id) if (integerOnlyOp(o)) |int_op| {
                try self.errAt(int_op, "operator `{s}` is for integers, and its literal operands here take the type `Float`", .{@tagName(int_op.kind().?)});
                return self.t().invalid_id;
            };
            return self.t().float_literal_id;
        }
        if (a_lit) {
            try self.checkExpr(operands[0], b);
            return b;
        }
        if (b_lit) {
            try self.checkExpr(operands[1], a);
            return a;
        }
        if (a != b) {
            try self.err(pos, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
            return self.t().invalid_id;
        }
        return a;
    }

    /// Whether `other` meets generic `tv` in an operator: as another `tv`,
    /// or as a literal, which becomes a `tv` (a float literal only where
    /// `req` allows a float).
    fn meetsTypeVar(self: *Checker, tv: TypeId, other: TypeId, req: Requirement) bool {
        return other == tv or other == self.t().int_literal_id or (req != .integer and other == self.t().float_literal_id);
    }

    fn require(self: *Checker, param: SymbolId, req: Requirement, pos: u32, op: []const u8) Error!void {
        try self.ctx.generic_requirements.append(self.ctx.allocator, .{ .param = param, .req = req, .pos = pos, .op = op });
    }

    /// A literal operand next to a generic `T` becomes a `T`, so every
    /// `T` must hold it: a float literal needs a float `T`, an integer
    /// one a `T` that holds its value.
    fn requireHoldsLiteral(self: *Checker, param: SymbolId, lit_ty: TypeId, lit: Sexp, pos: u32, op: []const u8) Error!void {
        if (integerOnlyOp(lit)) |int_op| try self.require(param, .integer, self.startOf(int_op), @tagName(int_op.kind().?));
        if (lit_ty == self.t().float_literal_id) try self.require(param, .float, pos, op);
        if (lit_ty == self.t().int_literal_id) if (self.constInt(lit)) |v| try self.require(param, .{ .fits = v }, pos, op);
        if (wholeDivision(self.ctx.source, lit)) |div| try self.require(param, .whole_division, self.startOf(div), self.sourceText(div));
    }

    fn synthNeg(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Neg.operand(e);
        const ty = try self.synthOperandValue(operand);
        if (self.isPoison(ty)) return ty;
        const lane = if (sema.simdOf(self.ctx, ty)) |v| v.elem else ty;
        if (lane != ty) switch (self.ctx.types.get(lane)) {
            .int => |info| if (info.signed) return ty,
            .float => return ty,
            else => {},
        };
        if (lane != ty) {
            try self.errAt(operand, "operator `-` negates signed integer or float lanes; got `{s}`", .{try self.tyName(ty)});
            return self.t().invalid_id;
        }
        switch (self.ctx.types.get(ty)) {
            .int => |info| {
                if (!info.signed) {
                    try self.errAt(operand, "cannot negate a value of unsigned type `{s}`", .{try self.tyName(ty)});
                    return self.t().invalid_id;
                }
                // A constant operand is negated now, so the result must fit.
                try self.checkLiteralFits(e, ty);
            },
            .float, .int_literal, .float_literal => {},
            .type_var => |tv| try self.require(tv, .signed, self.startOf(operand), "-"),
            else => {
                try self.errAt(operand, "operator `-` requires a numeric operand; got `{s}`", .{try self.tyName(ty)});
                return self.t().invalid_id;
            },
        }
        return ty;
    }

    fn synthEquality(self: *Checker, e: Sexp) Error!TypeId {
        const op = @tagName(e.kind().?);
        const l = ir.get(e, .left);
        const r = ir.get(e, .right);
        // A contextual operand (`.red`, `.dot(at: p)`, `none`) takes the
        // type of the value the other side gives. `none` and a bare
        // `.variant` test which variant it holds, and compare no payload;
        // a payload literal compares its payload, so it needs `==`.
        if (isContextual(self.ctx.source, l) or isContextual(self.ctx.source, r)) {
            const lit, const other = if (isContextual(self.ctx.source, r)) .{ r, l } else .{ l, r };
            const ty = try self.synthExpr(other);
            // An `==` operand is read (Core §3). `none` and a bare
            // `.variant` test a value made there and drop it with the
            // test; any other operand whose value may move is read where
            // it is (`readLeaf`), as is a payload literal's operand and
            // the literal, a value made there.
            const owns = !self.isPoison(ty) and sema.moves(self.ctx, ty) != .no;
            if (owns and (lit.isKind(.call) or self.hands(other).kind != .made)) try self.readLeaf(other);
            const reached = try self.readThrough(other, ty, sema.unwrapViews(self.ctx, ty));
            try self.checkExpr(lit, reached);
            if (lit.isKind(.call)) {
                try self.checkEquatable(reached, l, op);
                if (self.ctx.typeOf(lit)) |lit_ty| if (!self.isPoison(lit_ty) and sema.moves(self.ctx, lit_ty) != .no) try self.readLeaf(lit);
            }
            return self.t().bool_id;
        }
        // A viewed operand compares as the value it reaches, and an
        // array literal beside an array takes its type.
        const l_array = l.isKind(.array) or l.isKind(.array_fill);
        const r_array = r.isKind(.array) or r.isKind(.array_fill);
        var a: TypeId = undefined;
        var b: TypeId = undefined;
        if (l_array != r_array) {
            const lit, const other = if (l_array) .{ l, r } else .{ r, l };
            const other_ty = try self.synthReached(other);
            if (self.ctx.types.get(other_ty) == .array) {
                try self.checkExpr(lit, other_ty);
                try self.checkEquatable(other_ty, l, op);
                return self.t().bool_id;
            }
            const lit_ty = try self.synthReached(lit);
            a, b = if (l_array) .{ lit_ty, other_ty } else .{ other_ty, lit_ty };
        } else {
            a = try self.synthEqOperand(l);
            b = try self.synthEqOperand(r);
        }
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
        // Lane by lane: a mask. (An optional vector has no `==`, which
        // the optional's comparison reports.)
        const optional = self.ctx.types.get(a) == .optional or self.ctx.types.get(b) == .optional;
        if (!optional and (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null)) {
            const vt = try self.simdOperands(e, op, .equatable, a, b);
            return if (self.isPoison(vt)) vt else self.maskOf(self.ctx.types.get(vt).simd);
        }
        // An operand whose value may move (an owner, a unique value, or
        // a type parameter's, which emit consumes) is read where it is,
        // and a temporary of it is dropped with its statement; a view
        // compared owns nothing.
        for ([2]Sexp{ l, r }) |operand| {
            const own = self.ctx.typeOf(operand) orelse continue;
            if (!self.isPoison(own) and sema.moves(self.ctx, own) != .no) try self.readLeaf(operand);
        }
        if (sema.isNumeric(self.ctx, a) and sema.isNumeric(self.ctx, b)) {
            _ = try self.checkNumericComparison(l, r, a, b, op);
            return self.t().bool_id;
        }
        if (try self.comparesWithOptional(a, b, r, l, op)) {
            try self.checkEquatable(a, l, op);
            return self.t().bool_id;
        }
        if (try self.comparesWithOptional(b, a, l, l, op)) {
            try self.checkEquatable(b, r, op);
            return self.t().bool_id;
        }
        const ta = self.ctx.types.get(a);
        const tb = self.ctx.types.get(b);
        if (ta == .type_var or tb == .type_var) {
            // A `T` compares with a `T`, or with a literal every `T` holds.
            const tv_ty = if (ta == .type_var) a else b;
            if (!self.meetsTypeVar(tv_ty, if (ta == .type_var) b else a, .equatable)) {
                try self.errAt(l, "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
                return self.t().bool_id;
            }
            const tv = self.ctx.types.get(tv_ty).type_var;
            try self.require(tv, .equatable, self.startOf(l), op);
            if (ta == .type_var) try self.requireHoldsLiteral(tv, b, r, self.startOf(l), op) else try self.requireHoldsLiteral(tv, a, l, self.startOf(l), op);
            return self.t().bool_id;
        }
        // Any error compares with a member of any error set.
        const any_err = self.t().any_error_id;
        if ((a == any_err and sema.isErrorValue(self.ctx, b)) or (b == any_err and sema.isErrorValue(self.ctx, a))) return self.t().bool_id;
        // A String, boxed or not, compares with a `?String` or a String by
        // content.
        const string_ty = self.t().string_id;
        const string_view_ty = self.t().string_view_id;
        // Comparing reads both texts: a `Static` beside a `?String`.
        const a_read = if (a == self.t().static_id) string_view_ty else a;
        const b_read = if (b == self.t().static_id) string_view_ty else b;
        const ta_text = stringOrBoxed(self.ctx, a_read);
        const tb_text = stringOrBoxed(self.ctx, b_read);
        // A shared handle is not text: it has no `==`, and its content is
        // compared through a view, `?a == ?b`.
        const handles = sema.accessThroughShared(self.ctx, a) or sema.accessThroughShared(self.ctx, b);
        if (!handles and (ta_text == string_ty or tb_text == string_ty) and (ta_text == string_ty or ta_text == string_view_ty) and (tb_text == string_ty or tb_text == string_view_ty)) return self.t().bool_id;
        if (a_read != b_read) {
            try self.errAt(l, "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
            return self.t().bool_id;
        }
        try self.checkEquatable(a, l, op);
        return self.t().bool_id;
    }

    /// An operand of `==`, as the value it reaches. A shared handle has
    /// no `==`; `?h` of a name holding one, `*T`, lends the handle's value
    /// as a `?T` (CORE §4), so `?a == ?b` compares two handles' contents.
    fn synthEqOperand(self: *Checker, e: Sexp) Error!TypeId {
        if (e.isKind(.read)) if (self.sharedContent(ir.Read.operand(e))) |content| {
            const view = if (content == self.t().string_id) self.t().string_view_id else try self.ctx.intern(.{ .read_view = content });
            try self.checkExpr(e, view);
            return self.readThrough(e, view, sema.unwrapViews(self.ctx, view));
        };
        return self.synthReached(e);
    }

    /// The value a name holding a shared handle `*T` reaches, `T`, or null.
    fn sharedContent(self: *Checker, e: Sexp) ?TypeId {
        if (e != .src) return null;
        const sym = self.lookupQuiet(e) orelse return null;
        const ty = self.ctx.symbols.items[sym].ty;
        return switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .shared => |inner| if (self.ctx.types.get(inner) == .function) null else inner,
            else => null,
        };
    }

    /// Whether `opt` is a `T?` and `value` a `T` (or a literal that is
    /// one): the two compare equal when the optional holds the value. A
    /// literal beside a generic `T?` must fit every `T` (`op` at `at`).
    fn comparesWithOptional(self: *Checker, opt: TypeId, value: TypeId, value_node: Sexp, at: Sexp, op: []const u8) Error!bool {
        const inner = switch (self.ctx.types.get(opt)) {
            .optional => |i| i,
            else => return false,
        };
        const literal = value == self.t().int_literal_id or value == self.t().float_literal_id;
        const param: ?SymbolId = switch (self.ctx.types.get(inner)) {
            .type_var => |tv| tv,
            else => null,
        };
        // Text beside an optional of text compares by its bytes, whatever
        // its type, as two texts do.
        if (isText(self.ctx, inner) and isText(self.ctx, value) and value != inner) return true;
        if (value != inner and !sema.readsAsStringView(self.ctx, value, inner) and !(literal and (param != null or compatible(self.ctx, value, inner)))) return false;
        if (param) |tv| try self.requireHoldsLiteral(tv, value, value_node, self.startOf(at), op);
        try self.recordAdapted(value_node, value, inner);
        return true;
    }

    /// Numeric equality: same rules as arithmetic, with operands already synthesized.
    fn checkNumericComparison(self: *Checker, l: Sexp, r: Sexp, a: TypeId, b: TypeId, op: []const u8) Error!void {
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        // Beside a float literal, integer literals compare as floats.
        if (a == self.t().int_literal_id and b == self.t().float_literal_id) try self.checkWholeDivision(l);
        if (b == self.t().int_literal_id and a == self.t().float_literal_id) try self.checkWholeDivision(r);
        if (a_lit and !b_lit) return self.checkExpr(l, b);
        if (b_lit and !a_lit) return self.checkExpr(r, a);
        // Two literal operands are compared as `Int`s.
        if (a == self.t().int_literal_id and b == self.t().int_literal_id) {
            try self.defaultIntLiteral(l);
            try self.defaultIntLiteral(r);
        }
        if (!a_lit and a != b) {
            try self.errAt(l, "cannot compare `{s}` with `{s}` using `{s}`", .{ try self.tyName(a), try self.tyName(b), op });
        }
    }

    /// `==` compares values of `ty` (`sema.notEquatable`); inside a
    /// generic body, in the instances where it compares the parameters
    /// `ty` holds.
    fn checkEquatable(self: *Checker, ty: TypeId, node: Sexp, op: []const u8) Error!void {
        if (self.isPoison(ty)) return;
        var params: std.ArrayList(SymbolId) = .empty;
        defer params.deinit(self.ctx.allocator);
        if (try sema.notEquatable(self.ctx, ty, &params)) |n| {
            return self.errAt(node, "`{s}` is not defined for `{s}`: {s}", .{ op, try self.tyName(ty), try notEquatableReason(self.ctx, n) });
        }
        for (params.items) |tv| try self.require(tv, .equatable, self.startOf(node), op);
    }

    fn synthBlock(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const stmts = ir.Block.stmts(node);
        if (stmts.len == 0) {
            if (expected) |e| if (!self.isPoison(e) and e != self.t().void_id) {
                try self.errAt(node, "empty block where a `{s}` is expected", .{try self.tyName(e)});
            };
            return self.t().void_id;
        }
        const prev = self.enter(node);
        defer self.scope = prev;
        for (stmts[0 .. stmts.len - 1]) |s| try self.checkStmt(s);
        return self.synthTail(stmts[stmts.len - 1], expected);
    }

    /// `a ?? b`: the value inside optional `a`, or `b` when `a` is `none`.
    fn synthCoalesce(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
        const left = ir.@"??".left(e);
        const right = ir.@"??".right(e);
        const opt = try self.synthExpr(left);
        if (self.isPoison(opt)) {
            _ = try self.synthExpr(right);
            return opt;
        }
        const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, opt))) {
            .optional => |i| i,
            else => {
                try self.errAt(left, "`??` needs an optional on its left; this expression has type `{s}`", .{try self.tyName(opt)});
                _ = try self.synthExpr(right);
                return self.t().invalid_id;
            },
        };
        // A view of an optional gives up nothing; the value inside stays
        // with the lender. Otherwise a read reads the value inside where
        // it is, and a take takes it, which the ownership checker requires
        // of each operand.
        const through_view = sema.unwrapViews(self.ctx, opt) != opt;
        if (through_view and try self.cannotCopy(inner, self.startOf(left), "copies out with `??` a value")) {
            try self.viewGivesUp(left, opt);
            return self.t().invalid_id;
        }
        _ = try self.readThrough(left, opt, sema.unwrapViews(self.ctx, opt));
        const view_result = try self.joinFallback(self.fallbackType(inner, expected), right);
        const result = if (try self.fallbackCopy(e, left, opt, view_result, right, expected)) |value| result: {
            if (self.isPoison(value)) {
                _ = try self.synthExpr(right);
                return value;
            }
            break :result self.fallbackType(value, expected);
        } else view_result;
        try self.checkExpr(right, result);
        return result;
    }

    /// The `T` that `a ?? b` or `a catch b` (`e`) gives when the payload
    /// of `holder`, `a`, of type `holder_ty`, is a view `?T` or `!T`
    /// (`sema.payloadViewed`), and the fallback `b` is no view of it: it
    /// meets neither the view nor `view_result`, the type the form has
    /// when it gives the view (so `none` where an optional view goes, a
    /// jump, and another view leave it the view), and it is the value, or
    /// its type comes only from its context (`.point`). The value the payload
    /// views is copied out where `a` has one, as `if a as v` then `v`
    /// else `b` copies `v` (Core sentence 1), and the form is recorded
    /// (`SemContext.recordPayloadCopy`). A `T` that does not copy is
    /// reported, with poison returned, and so is a `T` that may not copy in
    /// every instance of a generic body. Null where the form gives the
    /// view.
    fn fallbackCopy(self: *Checker, e: Sexp, holder: Sexp, holder_ty: TypeId, view_result: TypeId, fallback: Sexp, expected: ?TypeId) Error!?TypeId {
        const view = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, holder_ty))) {
            .optional, .fallible => |inner| inner,
            else => return null,
        };
        // A `?String` views a `String`, which never copies: reported.
        const viewed = sema.payloadViewed(self.ctx, holder_ty) orelse if (view == self.t().string_view_id) self.t().string_id else return null;
        const copies = copies: {
            const ty = ty: {
                self.tentative += 1;
                defer self.tentative -= 1;
                break :ty try self.synthQuiet(fallback);
            };
            // A fallback whose type only its context gives (`.point`,
            // `List()`) is a value made there, never a view.
            if (self.isPoison(ty)) break :copies true;
            if (meets(self.ctx, ty, view) or meets(self.ctx, ty, view_result)) break :copies false;
            // One that fits neither the view nor the value is reported
            // against the view, as it was; `none` alone, where no optional
            // is expected, fits neither, so a `??` in a fallback decides
            // the same with or without its context.
            break :copies meets(self.ctx, ty, self.fallbackType(viewed, expected));
        };
        // Decided where the form is checked for good: a quiet pass may
        // decide otherwise without its context.
        if (self.ctx.quiet == 0) try self.ctx.recordPayloadCopy(e, copies);
        if (!copies) return null;
        // Only a value that copies is copied out of a view; in a generic
        // body, a `T` that may not copy in every instance is not, as a
        // view read where its `T` is expected is not (`checkActual`).
        const answer = sema.copies(self.ctx, viewed);
        if (answer != .yes) {
            const name = try self.tyName(viewed);
            const lent = try self.spliced(e, &.{fallback}, &.{try self.lentFallbackText(fallback, viewed)});
            const head = "`{s}` would copy out the `{s}` that `{s}` views, since its fallback is a value, not a view; only a value that copies is copied out of a view, and ";
            if (answer == .depends) {
                try self.errAt(e, head ++ "`{s}` may not copy in every instance: lend the fallback, so the result is the view: `{s}`", .{ self.sourceText(e), name, self.sourceText(holder), name, lent });
            } else try self.errAt(e, head ++ "{s} `{s}` {s}: lend the fallback, so the result is the view, and clone that for {s} `{s}` of its own: `+({s})`", .{ self.sourceText(e), name, self.sourceText(holder), article(name), name, self.movesBecause(viewed), article(name), name, lent });
            return self.t().invalid_id;
        }
        return viewed;
    }

    /// The fallback `b` of `a ?? b` lent to read, as a hint writes it: a
    /// variant literal names its enum, `?(Val.v(...))`, since only its
    /// context gives `.v(...)` its type, and a call through a type is
    /// parenthesized, since `?Val.v(...)` would lend `Val`.
    fn lentFallbackText(self: *Checker, fallback: Sexp, viewed: TypeId) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        const src = self.sourceText(fallback);
        const variant = fallback.isKind(.enum_lit) or (fallback.isKind(.call) and ir.Call.callee(fallback).isKind(.enum_lit));
        if (variant) return a.print("?({s}{s})", .{ try self.tyName(viewed), src });
        if (fallback.isKind(.call) and ir.Call.callee(fallback).isKind(.member)) return a.print("?({s})", .{src});
        return a.print("?{s}", .{src});
    }

    /// The type of `a ?? b` or `a catch b` when `a` gives a `Static` and
    /// the fallback is a `?String`: the `?String`, which reads the `Static`
    /// (`readsAsStringView`), as a branch joins the two.
    fn joinFallback(self: *Checker, result: TypeId, fallback: Sexp) Error!TypeId {
        if (result != self.t().static_id) return result;
        self.tentative += 1;
        defer self.tentative -= 1;
        const ty = try self.synthQuiet(fallback);
        return if (readValue(self.ctx, ty) == self.t().string_view_id) self.t().string_view_id else result;
    }

    /// The type of `a ?? b` or `a catch b`, where `a` gives an `inner`:
    /// `inner`, or the optional its context expects, which lets the
    /// fallback `b` be `none` or another optional. `inner` widens to it
    /// only as itself (`meets`), or as a view held by value, which is
    /// its value: a view held by address stays the view, and the whole
    /// `??` or `catch` is copied out where its context expects the value
    /// (`copiedOut`).
    fn fallbackType(self: *Checker, inner: TypeId, expected: ?TypeId) TypeId {
        const e = expected orelse return inner;
        return switch (self.ctx.types.get(e)) {
            .optional => |i| if (meets(self.ctx, inner, i) or (!sema.viewHeldAsPointer(self.ctx, inner) and compatible(self.ctx, inner, i))) e else inner,
            else => inner,
        };
    }

    /// `expr catch handler`: the value of fallible `expr`, or `handler`.
    /// `expr catch |err| handler` names the error for the handler; it
    /// may be any error, since functions do not declare their errors.
    fn synthCatch(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
        const value = ir.Catch.value(e);
        const name = ir.Catch.name(e);
        const handler = ir.Catch.handler(e);
        const ty = try self.synthHandled(value);
        const prev = self.scope;
        defer self.scope = prev;
        if (name != .nil) {
            _ = self.enter(e);
            if (self.ctx.symbolOf(name)) |sym| {
                self.ctx.symbols.items[sym].ty = self.t().any_error_id;
                try self.ctx.recordType(name, self.t().any_error_id);
            }
        }
        if (self.isPoison(ty)) {
            _ = try self.synthExpr(handler);
            return ty;
        }
        const inner = switch (self.ctx.types.get(ty)) {
            .fallible => |i| i,
            else => {
                try self.errAt(value, "`catch` needs a fallible expression; this expression has type `{s}` and cannot fail", .{try self.tyName(ty)});
                _ = try self.synthExpr(handler);
                return self.t().invalid_id;
            },
        };
        const view_result = try self.joinFallback(self.fallbackType(inner, expected), handler);
        const result = if (try self.fallbackCopy(e, value, ty, view_result, handler, expected)) |copied| result: {
            if (self.isPoison(copied)) {
                _ = try self.synthExpr(handler);
                return copied;
            }
            break :result self.fallbackType(copied, expected);
        } else view_result;
        try self.checkExpr(handler, result);
        return result;
    }

    /// `e!`: the value of fallible `e`; its failure goes to `fail_to`.
    fn synthPropagate(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Propagate.value(e);
        switch (self.body.fail_to) {
            .caller, .module => {},
            .deferred => try self.errAt(operand, "cannot use `!` inside `defer`; a deferred expression cannot propagate failure, so handle it with `catch`", .{}),
            .closure => try self.errAt(operand, "use of `!` propagation requires a fallible enclosing function; a closure body propagates failure only when its type can fail (`?fun(A) -> T!`), so handle it with `catch`", .{}),
            .drop => try self.errAt(operand, "a `drop` body cannot propagate failure; handle it with `catch`", .{}),
            .infallible => |name| {
                if (self.body.is_sub) {
                    try self.errAt(operand, "use of `!` propagation requires the enclosing `{s}` to be fallible: `sub {s}(...)!`", .{ self.text(name), self.text(name) });
                } else try self.errAt(operand, "use of `!` propagation requires the enclosing function `{s}` to declare a fallible return type (`-> T!`)", .{self.text(name)});
                try self.noteAt(name, "`{s}` declared here", .{self.text(name)});
            },
        }
        const ty = try self.synthHandled(operand);
        return switch (self.ctx.types.get(ty)) {
            .fallible => |inner| inner,
            .unknown, .invalid => ty,
            else => {
                try self.errAt(operand, "`!` needs a fallible operand; this expression has type `{s}` and cannot fail", .{try self.tyName(self.canonical(ty))});
                return ty;
            },
        };
    }

    /// `e?`: the value inside optional `e`; when `e` is `none`, the
    /// enclosing function returns `none`, so it must return an optional.
    /// A resource inside `e` is handed over, so `e` cannot be a view.
    fn synthPropagateNone(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.PropagateNone.value(e);
        // A fallible call is handled here, by the one error below.
        const ty = try self.synthHandled(operand);
        if (self.isPoison(ty)) return ty;
        if (self.ctx.types.get(ty) == .fallible) {
            const shown = try self.plainText(operand);
            try self.errAt(operand, "`?` propagates `none`, and `{s}` fails with an error instead: propagate the failure with `{s}!`, or handle it with `catch`", .{ shown, shown });
            return self.ctx.types.get(ty).fallible;
        }
        const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .optional => |i| i,
            else => {
                // `*w?` is `*(w?)`; propagating a gone value is `(*w)?`.
                if (sameNode(e, self.shared_operand) and self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .weak) {
                    const shown = try self.plainText(operand);
                    try self.errAt(operand, "`*{s}?` is `*({s}?)`, and `{s}` is a weak handle, not an optional: to return `none` once its value is gone, write `(*{s})?`", .{ shown, shown, shown, shown });
                    return self.t().invalid_id;
                }
                try self.errAt(operand, "`?` needs an optional operand; this expression has type `{s}`", .{try self.tyName(self.canonical(ty))});
                return self.t().invalid_id;
            },
        };
        switch (self.body.fail_to) {
            .deferred => return self.noneNotReturned(operand, "cannot use `?` inside `defer`; deferred code cannot return, so take the value out with `if x as v` or `??`"),
            // An inferred closure's type returns no optional.
            .closure => if (self.body.returns != null or !self.returnsOptional(self.body.ret)) {
                return self.noneNotReturned(operand, "a closure body returns `none` with `?` only when its type returns an optional (`?fun(A) -> T?`); take the value out with `if x as v` or `??`");
            },
            .drop => return self.noneNotReturned(operand, "a `drop` body cannot return `none` with `?`; take the value out with `if x as v` or `??`"),
            .caller, .infallible, .module => if (!self.returnsOptional(self.body.ret)) {
                const name = self.body.name;
                const shown = try self.plainText(operand);
                if (name == .nil) {
                    try self.errAt(operand, "use of `?` requires the enclosing function to return an optional (`-> T?`)", .{});
                } else if (self.body.is_sub) {
                    try self.errAt(operand, "`?` returns `none` from `{s}`, which returns no value; handle the missing value with `{s} ?? fallback`, or `if {s} as {s}`", .{ self.text(name), shown, shown, bindingNameFor(shown) });
                } else {
                    try self.errAt(operand, "use of `?` requires the enclosing function `{s}` to return an optional (`-> T?`); or handle the missing value with `{s} ?? fallback`", .{ self.text(name), shown });
                    try self.noteAt(name, "`{s}` declared here", .{self.text(name)});
                }
                return self.t().invalid_id;
            },
        }
        const through_view = sema.unwrapViews(self.ctx, ty) != ty;
        if (through_view and (try self.cannotCopy(inner, self.startOf(operand), "moves out of a view a value"))) {
            try self.viewGivesUp(operand, ty);
            return self.t().invalid_id;
        }
        _ = try self.readThrough(operand, ty, sema.unwrapViews(self.ctx, ty));
        return inner;
    }

    /// `o ?? ...` or `o?` over a view `ty` of an optional that owns a
    /// resource: the view can lend the value inside, not give it up.
    fn viewGivesUp(self: *Checker, operand: Sexp, ty: TypeId) Error!void {
        const place = if (operand.isKind(.move)) ir.Move.operand(operand) else operand;
        const shown = try self.plainText(place);
        const sigil = if (self.ctx.types.get(ty) == .write_view and !place.isKind(.write)) "!" else "";
        const value = sema.unwrapViews(self.ctx, ty);
        const what = if (!sema.typeHasDropGlue(self.ctx, value) and sema.holdsWriteView(self.ctx, value)) "write view" else "resource";
        try self.errAt(operand, "a view cannot give up the {s} inside it; lend the value inside with `if {s}{s} as {s}`", .{ what, sigil, shown, bindingNameFor(shown) });
    }

    /// A name to suggest binding the value inside `shown` to, which
    /// does not shadow it.
    fn bindingNameFor(shown: []const u8) []const u8 {
        return if (std.mem.eql(u8, shown, "value")) "v" else "value";
    }

    /// `e?` where no `none` can be returned: the error, and no type.
    fn noneNotReturned(self: *Checker, operand: Sexp, comptime msg: []const u8) Error!TypeId {
        try self.errAt(operand, msg, .{});
        return self.t().invalid_id;
    }

    /// A return type `e?` can leave with `none`: `T?`, or `T?!`.
    fn returnsOptional(self: *Checker, ret: TypeId) bool {
        if (self.isPoison(ret)) return true;
        return switch (self.ctx.types.get(ret)) {
            .optional => true,
            .fallible => |inner| self.ctx.types.get(inner) == .optional,
            else => false,
        };
    }

    /// The operand of `!` or `catch`, where a fallible call is handled.
    fn synthHandled(self: *Checker, operand: Sexp) Error!TypeId {
        const prev = self.handled;
        defer self.handled = prev;
        self.handled = operand;
        return self.synthExpr(operand);
    }

    // ---- ownership sigils -----------------------------------------------------

    const LendKind = enum { read, write };

    /// `?x` / `!x`. Lending a view lends it on rather than
    /// nesting (`?b` with `b: ?B` is `?B`).
    fn synthLend(self: *Checker, e: Sexp, kind: LendKind) Error!TypeId {
        const operand = ir.get(e, .operand);
        try self.recordUse(operand, .lend);
        const saved_in_place = self.in_place;
        defer self.in_place = saved_in_place;
        self.in_place = operand;
        if (rig.isRangeIndex(operand)) {
            return self.lendSlice(operand, kind);
        }
        const saved_outer = self.outer_write;
        const saved_loop = self.outer_write_is_loop;
        defer {
            self.outer_write = saved_outer;
            self.outer_write_is_loop = saved_loop;
        }
        if (kind == .write and operand.isKind(.call)) {
            self.outer_write = operand;
            self.outer_write_is_loop = false;
        }
        // A temporary lent lives until its statement ends, which drops
        // it; the ownership checker keeps a view of it from outliving
        // the statement.
        const inner = if (!self.hands(operand).hasStorage())
            try self.synthExpr(operand)
        else
            try self.synthOperand(operand);
        if (self.isPoison(inner)) return inner;
        if (try self.rejectLane(operand, if (kind == .write) .lend_write else .lend_read)) return self.t().invalid_id;
        // A branch is a value, never a place: lent only where it is made.
        if (!try self.lendsBranch(operand, .nil, kind)) return self.t().invalid_id;
        // `?!x` only reads what `!x` lends.
        if (kind == .read and try self.writeLendRead(operand, inner, .lent_to_read)) return self.t().invalid_id;
        // `e.text` is a name the enum's type holds, no part of `e`: there
        // is nothing of `e` to lend.
        if (kind == .read and self.ctx.isEnumText(operand)) {
            try self.errAt(e, "`{s}` is a variant's name, a `Static`, not a part of the value to lend; pass it as it is: `{s}`", .{ self.sourceText(operand), self.sourceText(operand) });
            return self.t().invalid_id;
        }
        const place = self.placeOf(operand);
        if (place.cell_list_elem != null) {
            try self.errAt(operand, "cannot lend an element of a Cell's List: the cell may change while the view lives; copy the element out with `c[i]`", .{});
            return self.t().invalid_id;
        }
        // `?f` of a stack closure lends it as a callable view.
        if (self.closureBinding(operand)) {
            if (kind == .read) return sema.callableOfFn(self.ctx, inner);
            try self.errAt(e, "a call never changes what a closure captures, so a closure is lent to read: write `?{s}`", .{self.sourceText(operand)});
            return self.t().invalid_id;
        }
        // Anywhere but where a `!Bool` is expected, `!flag` is read as
        // a `Bool`: the habit of `!` as negation.
        if (kind == .write and readValue(self.ctx, inner) == self.t().bool_id and !sameNode(e, self.lent_write)) {
            try self.errAt(e, "`!` lends to write; use `not` for negation (a `Bool` is lent to write only where a `!Bool` is expected: `f(!flag)`)", .{});
            return self.t().invalid_id;
        }
        // A constant lives for the whole program and never changes.
        if (kind == .write and try self.isConstant(operand)) {
            try self.errAt(operand, "cannot lend constant `{s}` to write: it lives for the whole program and never changes; bind its value to a name first", .{self.sourceText(operand)});
            return self.t().invalid_id;
        }
        // `![]T` is a writable slice, which a read-only `[]T` cannot give.
        if (kind == .write and self.ctx.types.get(inner) == .slice) {
            try self.errAt(operand, "cannot lend a `{s}` to write: its elements are read-only; take a writable slice of the array or List it views with `!xs[a..b]`", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        if (kind == .write and inner == self.t().string_view_id) {
            try self.errAt(operand, "cannot lend `{s}` to write: it holds a read view of text, `?String`, which is pointed at other text by assigning to it; to change text in place, hold a `String`", .{self.sourceText(operand)});
            return self.t().invalid_id;
        }
        if (kind == .write and self.ctx.types.get(inner) == .read_view) {
            const handle_hint: []const u8 = if (self.lendsHandle(place)) "; take a write view, or share a handle of your own with `+h`" else "";
            try self.errAt(operand, "cannot lend to write through a read view `{s}`{s}{s}", .{ try self.tyName(inner), try self.readMatchHint(place.sym), handle_hint });
            return self.t().invalid_id;
        }
        // Where only the binding may not be written, the view keeps its
        // type, so what it is lent to is checked too.
        if (kind == .write and !try self.requireAccess(place, .lend_write, operand) and (place.blocked != null or place.root == .temporary)) return self.t().invalid_id;
        if (kind == .read) try self.lendsToRead(operand);
        if (kind == .write and !try self.lendsToWrite(operand)) return self.t().invalid_id;
        // `!c` lends the handle itself, which a callee may point elsewhere,
        // only where `c` may be written (`handleWritable`, the one fact
        // `requireAccess` decides). Anywhere else, and as a receiver never
        // matters, it lends what the handle holds: that value's write view.
        if (kind == .write and self.lendsHandle(place) and !sameNode(e, self.receiver_obj) and !self.handleWritable(place, operand)) {
            const handle = sema.unwrapViews(self.ctx, inner);
            const view = try self.ctx.intern(.{ .write_view = self.ctx.types.get(handle).shared });
            if (sema.lendsAs(self.ctx, handle, .write, view)) |lend| try self.ctx.recordLend(e, lend);
            return view;
        }
        switch (self.ctx.types.get(inner)) {
            // (A write view of a `?T` was rejected above.)
            .read_view => return inner,
            .write_view => |base| {
                if (kind == .write) return inner;
                return self.readViewOf(e, base);
            },
            else => {},
        }
        return if (kind == .read) self.readViewOf(e, inner) else self.ctx.intern(.{ .write_view = inner });
    }

    /// The read view `?x` of a value of type `base`, lent by the lend
    /// table's rows. The view of a `String` is its bytes, `?String`, so
    /// the lend records its `text` row.
    fn readViewOf(self: *Checker, e: Sexp, base: TypeId) Error!TypeId {
        const view = try self.ctx.intern(.{ .read_view = base });
        if (base == self.t().string_id) {
            if (sema.lendsAs(self.ctx, base, .read, view)) |lend| try self.ctx.recordLend(e, lend);
        }
        return view;
    }

    /// Whether a lend (`?` or `!`, `kind`) of `operand` may stand, by a
    /// positive list: an operand that is a branch (`a if c else b`,
    /// `a ?? b`, `e catch h`, `e?`, `e!`), or a path of fields, elements,
    /// and method calls from one (`?(a if c else b).e`), is lent only
    /// where every leaf (`sema.valueLeaves`) is a value made there (a
    /// call's result, a literal, a constructor), a constant, a lend
    /// itself, or a jump.
    /// A branch is a value, never a place: a lend of one with a leaf a
    /// place holds would lend a copy of that leaf's value, a write view
    /// included (Core §3, planned). Each branch is lent instead, which the
    /// error writes out in `whole` (the operand, or the slice it is the
    /// object of). Decided once per branch (`branch_lends`), so a lend
    /// that asks again, as a slice's object does, reports nothing new.
    /// False after reporting.
    fn lendsBranch(self: *Checker, operand: Sexp, whole: Sexp, kind: LendKind) Error!bool {
        const lent = lentBranch(operand);
        if (lent == .nil) return true;
        // A handle that changes by a marked call is lent, not what holds
        // it: the branch is only read.
        if (kind == .write and self.lendsPath(self.placeOf(operand))) return true;
        if (self.branch_lends.get(nodeId(lent))) |ok| return ok;
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        try sema.valueLeaves(self.ctx.allocator, lent, &leaves);
        var place: Sexp = .nil;
        for (leaves.items) |leaf| switch (self.hands(leaf).kind) {
            .made, .lend, .jump => {},
            // A constant (`Color.red`) is a value no binding holds.
            .place, .part_of_made, .branches, .none => if (!try self.isConstant(leaf)) {
                place = leaf;
                break;
            },
        };
        try self.branch_lends.put(self.ctx.allocator, nodeId(lent), place == .nil);
        if (place == .nil) return true;
        const a = self.ctx.arena.allocator();
        const sigil: u8 = if (kind == .write) '!' else '?';
        const withs = try a.alloc([]const u8, leaves.items.len);
        for (leaves.items, withs) |leaf, *w| w.* = switch (self.hands(leaf).kind) {
            .made, .lend, .jump => self.sourceText(leaf),
            else => try a.print("{c}{s}", .{ sigil, self.sourceText(leaf) }),
        };
        const to = if (kind == .write) " to write" else "";
        // What `o?` unwraps is lent and unwrapped in a header instead.
        const fix = if (self.unwrapped(place))
            try a.print("lend what it unwraps, and unwrap it in a header: `if {c}{s} as x`", .{ sigil, self.sourceText(place) })
        else if (whole != .nil or sameNode(operand, lent))
            try a.print("lend each branch: `{s}`", .{try self.spliced(if (whole != .nil) whole else operand, leaves.items, withs)})
        else
            // A path keeps its lend, now through each branch's view.
            try a.print("lend each branch: `{c}{s}`", .{ sigil, try self.spliced(operand, leaves.items, withs) });
        if (self.hands(place).kind == .part_of_made) {
            try self.errAt(lent, "cannot lend `{s}`{s}: it may be `{s}`, a part of the temporary `{s}`, which lending the branching value would copy; {s}", .{ self.sourceText(lent), to, self.sourceText(place), self.sourceText(self.placeOf(place).base), fix });
        } else try self.errAt(lent, "cannot lend `{s}`{s}: it may be `{s}`, a value a name holds, which lending the branching value would copy; {s}", .{ self.sourceText(lent), to, self.sourceText(place), fix });
        return false;
    }

    /// Whether `leaf` is the operand of a postfix `?` or `!` as written.
    fn unwrapped(self: *Checker, leaf: Sexp) bool {
        const end = self.ctx.span(leaf).end;
        return end < self.ctx.source.len and (self.ctx.source[end] == '?' or self.ctx.source[end] == '!');
    }

    /// The branch lend operand `operand` is, or a path of fields,
    /// elements, and method calls starts from; `.nil` for none.
    fn lentBranch(operand: Sexp) Sexp {
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

    /// `operand` lent to read, written `?e` or not: a temporary is held
    /// to its statement's end.
    fn lendsToRead(self: *Checker, operand: Sexp) Error!void {
        if (self.isTemporary(operand)) try self.lendTemp(operand);
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
    /// whatever it holds: `g = f` may be lent to write.
    fn isConstant(self: *Checker, e: Sexp) Error!bool {
        switch (e) {
            .src => {
                const id = self.ctx.symbolOf(e) orelse return self.hands(e).kind == .made;
                const sym = self.ctx.symbols.items[id];
                return sym.kind == .function or self.rootOf(sym) == .constant;
            },
            .list => {},
            else => return false,
        }
        {
            var leaves: std.ArrayList(Sexp) = .empty;
            defer leaves.deinit(self.ctx.allocator);
            try sema.valueLeaves(self.ctx.allocator, e, &leaves);
            // A value that branches.
            if (leaves.items.len != 1 or !sameNode(leaves.items[0], e)) {
                for (leaves.items) |leaf| if (!try self.isConstant(leaf)) return false;
                return leaves.items.len > 0;
            }
        }
        return switch (e.kind() orelse return false) {
            .enum_lit => true,
            .member => self.ctx.isErrorMember(e) or try self.namesTypeConstant(e) or self.namesModuleConstant(e),
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>" => for (rig.children(e)) |c| {
                if (!try self.isConstant(c)) break false;
            } else true,
            else => false,
        };
    }

    /// `T.name` of a type `T` (a number type, a struct, enum, or error
    /// set, an alias, here or in another module): a constant the type
    /// holds, a variant, an error value, a limit, or a function.
    fn namesTypeConstant(self: *Checker, e: Sexp) Error!bool {
        const obj = ir.Member.object(e);
        return (try self.numberType(obj)) != null or (try self.namedType(obj)) != null;
    }

    /// `m.name` of another module's function or constant.
    fn namesModuleConstant(self: *Checker, e: Sexp) bool {
        const sym = self.foreignMember(e) orelse return false;
        return sym.kind == .function or (sym.kind == .local and sym.flags.fixed);
    }

    /// `operand` lent to write (Core sentence 4: `!` lends any value to
    /// write, named or temporary): a temporary, or the value a part of
    /// one starts from, is held in its statement's slot until the
    /// statement ends (`lendTemp`), where the change is seen and dropped
    /// with it. A branching value that may be a name's would be lent as
    /// a copy, which the change would miss: each branch is lent instead.
    /// (A constant is never lent to write: `isConstant`.) False when
    /// the lend is rejected (reported).
    fn lendsToWrite(self: *Checker, operand: Sexp) Error!bool {
        if (!self.isTemporary(operand)) return true;
        // A handle that changes by a marked call is lent, not what holds
        // it: what holds it is only read, in place, as a read receiver's
        // value is.
        if (self.lendsPath(self.placeOf(operand))) {
            if (!self.hands(operand).hasStorage()) try self.readLeafAs(operand, false);
            return true;
        }
        const base = if (self.hands(operand).hasStorage()) self.placeOf(operand).base else operand;
        if (!try self.lendsBranch(operand, .nil, .write)) return false;
        try self.lendTemp(operand);
        if (base == .list) try self.ctx.recordWrittenTemp(base);
        return true;
    }

    /// `U8`, a `?String`'s byte.
    fn byteType(self: *Checker) Error!TypeId {
        return self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
    }

    /// Whether `e` names a stack closure binding: one bound to a closure
    /// literal, whose type is that function type (a binding declared as
    /// another type keeps that type, and the literal was rejected).
    fn closureBinding(self: *Checker, e: Sexp) bool {
        if (e != .src) return false;
        const id = self.ctx.symbolOf(e) orelse return false;
        const sym = self.ctx.symbols.items[id];
        return sym.flags.closure and self.ctx.types.get(sym.ty) == .function;
    }

    /// A value no binding holds, or a part of one: a view of it lives
    /// only until the end of its statement. A view made here views
    /// what it views, which outlives the statement.
    fn isTemporary(self: *Checker, e: Sexp) bool {
        return switch (self.hands(e).kind) {
            .part_of_made => true,
            .made, .branches => if (self.ctx.typeOf(e)) |ty| !sema.isReadOrWriteView(self.ctx, ty) else false,
            .place, .lend, .jump, .none => false,
        };
    }

    /// What the context of `e` does with it (`sema.Use`), recorded for a
    /// name and for a value that yields one of its parts: emit moves a
    /// name at a tail of the value out of its binding only where the
    /// value is taken.
    fn recordUse(self: *Checker, e: Sexp, use: sema.Use) Error!void {
        const yields = switch (e) {
            .src => self.hands(e).kind == .place,
            .list => sema.yieldsPart(e),
            else => false,
        };
        if (yields) try self.ctx.recordUse(e, use);
    }

    /// Whether `e`'s value needs cleanup.
    fn ownsResource(self: *Checker, e: Sexp) bool {
        const ty = self.ctx.typeOf(e) orelse return false;
        return !self.isPoison(ty) and sema.typeHasDropGlue(self.ctx, ty);
    }

    /// Whether `e` is a view whose value is copied out where a value is
    /// expected (`sema.copiedThrough`).
    fn copiesThrough(self: *const Checker, e: Sexp) bool {
        const ty = self.ctx.typeOf(e) orelse return false;
        return sema.copiedThrough(self.ctx, ty) != null;
    }

    /// Whether `e`'s value copies (`sema.copies`).
    fn copiesValue(self: *const Checker, e: Sexp) bool {
        const ty = self.ctx.typeOf(e) orelse return false;
        return sema.copies(self.ctx, ty) == .yes;
    }

    /// How receiver `recv` is written (`ReceiverShape`).
    fn receiverShape(self: *const Checker, recv: Sexp) ReceiverShape {
        if (recv.isKind(.read)) return .read_explicit;
        if (recv.isKind(.write)) return .write_explicit;
        if (recv.isKind(.move)) return .move_explicit;
        return switch (self.hands(recv).kind) {
            .made => .made,
            .branches => .branches,
            .place, .part_of_made, .lend, .jump, .none => .place,
        };
    }

    /// What `e` hands over to its context (`sema.handsOver`).
    fn hands(self: *const Checker, e: Sexp) sema.Hands {
        return sema.handsOver(self.ctx, e);
    }

    /// `?xs[a..b]`: a read-only slice `[]T`; `!xs[a..b]`: a writable one,
    /// `![]T`.
    fn lendSlice(self: *Checker, slice: Sexp, kind: LendKind) Error!TypeId {
        const ty = if (kind == .read) try self.synthSlice(slice, true) else try self.writeSlice(slice);
        try self.ctx.recordType(slice, ty);
        // A slice of a branch lends each branch's elements.
        if (!self.isPoison(ty) and !try self.lendsBranch(ir.Index.object(slice), slice, kind)) return self.t().invalid_id;
        return ty;
    }

    /// `!xs[a..b]`: a write view of the elements from `a` up to `b`, of
    /// an array or a List of plain data the code may write, or of a
    /// `![]T`. A `?String` and a `[]T` are read-only.
    fn writeSlice(self: *Checker, slice: Sexp) Error!TypeId {
        const object = ir.Index.object(slice);
        const range = ir.Index.index(slice);
        // A temporary sliced is held in its statement's slot (below).
        const obj_ty = if (!self.hands(object).hasStorage()) try self.synthExpr(object) else try self.synthOperand(object);
        try self.checkSliceRange(range);
        if (self.isPoison(obj_ty)) return obj_ty;
        if (sema.sliceLend(self.ctx, obj_ty)) |lend| try self.ctx.recordSliceLend(slice, lend);
        const peeled = sema.unwrapViews(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .string_view, .static => {
                try self.errAt(object, "cannot lend a slice of a `?String` to write; a `?String` is read-only", .{});
                return self.t().invalid_id;
            },
            .string => {
                try self.errAt(object, "cannot lend a slice of a String to write; a String changes only through its methods (`!t.add(...)`, `!t.push(b)`, `!t.clear()`)", .{});
                return self.t().invalid_id;
            },
            .slice => |s| blk: {
                if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
                    try self.errAt(object, "cannot lend a slice of a `{s}` to write; a `[]T` is read-only (a writable slice is a `![]T`)", .{try self.tyName(obj_ty)});
                    return self.t().invalid_id;
                }
                break :blk s.elem;
            },
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            else => (try self.listSliceElem(object, obj_ty, peeled)) orelse return self.t().invalid_id,
        };
        try self.checkSliceBounds(range, len);
        // The binding it reaches may be one no view can write (a
        // parameter, a fixed or loop binding): reported, nothing lent.
        const place = self.placeOf(slice);
        if (!try self.requireAccess(place, .lend_write, object)) return self.t().invalid_id;
        // A `![]T` may be resliced wherever it comes from; an array or a
        // List is sliced where it is stored, a temporary's in its
        // statement's slot.
        if (place.root == .temporary) {
            if (!try self.lendsToWrite(object)) return self.t().invalid_id;
        } else if (sema.writeSliceElem(self.ctx, obj_ty) == null and place.base != .src) {
            try self.errAt(object, slice_of_temporary, .{});
            return self.t().invalid_id;
        }
        return self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .slice = .{ .elem = elem } }) });
    }

    /// `<x`. What it does to its source is `sema.moveSource`: of a field
    /// or element holding an optional, `<p.f` takes the value out and
    /// leaves `none` behind, so the place is written, and must be
    /// reachable for writing. A part of a value made here is reported
    /// (`rejectMadeParts`); the ownership checker decides the rest.
    fn synthMove(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Move.operand(e);
        const ty = try self.synthExpr(operand);
        if (operand == .src) if (self.ctx.symbolOf(operand)) |id| try self.ctx.recordWrite(e, id, .move);
        if (try self.payloadViewTaken(operand, "move")) return self.t().invalid_id;
        if (self.isPoison(ty)) return ty;
        if (try self.rejectLane(operand, .take)) return self.t().invalid_id;
        if (try self.rejectMadeParts(e, operand)) return self.t().invalid_id;
        if (sema.moveSource(self.ctx, operand) != .optional_part) return ty;
        try self.ctx.recordTake(e);
        const place = self.placeOf(operand);
        if (place.cell_list_elem != null) {
            try self.errAt(e, "an element of a Cell's List is read and written whole: copy it out with `c[i]`, then write `c[i] = none`", .{});
            return ty;
        }
        if (!try self.requireAccess(place, .take, e)) return ty;
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
    fn rejectMadeParts(self: *Checker, at: Sexp, operand: Sexp) Error!bool {
        switch (sema.moveSource(self.ctx, operand)) {
            .made_part => {
                try self.rejectMadePart(at, operand);
                return true;
            },
            .branches => {
                var leaves: std.ArrayList(sema.MoveLeaf) = .empty;
                try sema.moveLeaves(self.ctx.arena.allocator(), self.ctx, operand, &leaves);
                for (leaves.items) |leaf| if (leaf.source == .made_part) {
                    try self.rejectMadePart(leaf.node, leaf.node);
                    return true;
                };
                return false;
            },
            else => return false,
        }
    }

    fn rejectMadePart(self: *Checker, at: Sexp, part: Sexp) Error!void {
        const ty = self.ctx.typeOf(part) orelse return;
        if (self.isPoison(ty)) return;
        const optional = self.ctx.types.get(ty) == .optional;
        // A handle made here reaches a box other handles may see.
        if (!optional and sema.copies(self.ctx, ty) == .yes) {
            try self.errAt(at, "cannot move out of `{s}`: it copies, so `<` would leave it as it was; remove the `<` to copy it", .{self.sourceText(part)});
        } else if (self.handleOnPath(part)) |handle| {
            try self.errAt(at, "cannot {s} `{s}`: it is reached through the shared handle `{s}`, and other handles may still use it", .{ if (optional) "take out of" else "move out of", self.sourceText(part), self.sourceText(handle) });
        } else if (optional) {
            try self.errAt(at, "cannot take out of a temporary: nothing would see it emptied; bind it to a name first", .{});
        } else {
            // A lend of a temporary names the temporary.
            const root = sema.pathRoot(part);
            const temp = if (root.isKind(.read) or root.isKind(.write)) ir.get(root, .operand) else root;
            try self.errAt(at, "cannot move a part out of the temporary `{s}`, which its statement drops; bind it to a name first", .{self.sourceText(temp)});
        }
    }

    /// The shared handle a field or element path passes through, by the
    /// type of each value on it.
    fn handleOnPath(self: *Checker, e: Sexp) ?Sexp {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) {
            p = ir.get(p, .object);
            const ty = self.ctx.typeOf(p) orelse continue;
            if (self.ctx.types.get(ty) == .shared) return p;
        }
        return null;
    }

    fn synthShare(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Share.operand(e);
        if (try self.shareOfNone(e, null)) return self.t().invalid_id;
        if (operand.isKind(.lambda)) return self.ownedClosure(operand, null);
        const ty = try self.shareOperand(operand, null);
        if (try self.weakUpgrade(e, ty)) |upgraded| return upgraded;
        // A literal takes its default type.
        if (ty == self.t().int_literal_id) try self.defaultIntLiteral(operand);
        const inner = self.canonical(ty);
        if (self.isPoison(inner)) return inner;
        if (self.ctx.types.get(inner) == .function) {
            try self.errAt(operand, "`*` makes an owned closure only from a closure literal: `*|...| body`", .{});
            return self.t().invalid_id;
        }
        if (self.ctx.types.get(inner) == .shared) {
            try self.errAt(operand, "this value is already a shared handle `{s}`; `*` would nest handles. Clone it with `+x` for another handle", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        if (sema.heapStacked(self.ctx, inner)) {
            // `*o` of an optional weak handle: `*` upgrades the handle
            // inside, once it is taken out.
            if (self.ctx.types.get(sema.unwrapOptionals(self.ctx, inner)) == .weak) {
                const shown = try self.plainText(stripSigil(operand));
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
    /// it reads a view, a place, a part of a value, a lend, or a branching
    /// value, and takes a weak handle made there (`*<w`, `*~h`, `*f()`),
    /// which is dropped once upgraded. Recorded
    /// (`SemContext.recordUpgrade`), which the ownership checker and emit
    /// read: a read is `w`'s, as a `?self` method's receiver is read; a
    /// take moves `w` as `*<x` moves `x`.
    fn weakUpgrade(self: *Checker, e: Sexp, ty: TypeId) Error!?TypeId {
        const operand = ir.Share.operand(e);
        if (self.isPoison(ty)) return null;
        const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .weak => |inner| inner,
            else => return null,
        };
        const how: sema.Upgrade = if (sema.isReadOrWriteView(self.ctx, ty)) .reads else switch (self.hands(operand).kind) {
            .place, .part_of_made, .lend, .branches => .reads,
            .made => .takes,
            .jump, .none => return null,
        };
        if (operand.isKind(.write)) {
            const shown = try self.plainText(stripSigil(operand));
            try self.errAt(operand, "`*` only reads the weak handle it upgrades: write `*{s}`", .{shown});
            return self.t().invalid_id;
        }
        if (how == .reads) {
            // A branching value that may be a name's is lent branch by
            // branch, `*(?a if c else ?b)`, as a receiver is.
            if (self.hands(operand).kind == .branches and !try self.lendsBranch(operand, e, .read)) return self.t().invalid_id;
            try self.rejectResourceTemporary(operand, ty);
        }
        try self.ctx.recordUpgrade(e, how);
        return try self.ctx.intern(.{ .optional = try self.ctx.intern(.{ .shared = inner }) });
    }

    /// Whether `e`'s type is its own wherever it stands, whatever is
    /// expected of it, by a positive list: a name, a field or element
    /// path, a lend, or a move (`checkContextual` types none of them).
    fn typedWhereItStands(self: *Checker, e: Sexp) bool {
        return switch (e) {
            .src => blk: {
                const s = self.text(e);
                break :blk s.len > 0 and (std.ascii.isAlphabetic(s[0]) or s[0] == '_') and
                    !std.mem.eql(u8, s, "none") and !std.mem.eql(u8, s, "true") and !std.mem.eql(u8, s, "false");
            },
            .list => if (e.kind()) |k| switch (k) {
                .member, .index => true,
                .read, .write, .move => self.typedWhereItStands(ir.get(e, .operand)),
                else => false,
            } else false,
            else => false,
        };
    }

    /// `*none` where no handle of an optional is expected (`target`, a
    /// `*(T?)`, holds `none`), which would make a handle of nothing, is
    /// rejected (reported): an optional handle with no value is `none`
    /// itself.
    fn shareOfNone(self: *Checker, e: Sexp, target: ?TypeId) Error!bool {
        const operand = ir.Share.operand(e);
        if (operand != .src or !std.mem.eql(u8, self.text(operand), "none")) return false;
        // Where the expected type was reported, nothing more is.
        if (self.under_poison) return false;
        if (target) |want| switch (self.ctx.types.get(want)) {
            .shared => |inner| if (self.ctx.types.get(inner) == .optional) return false,
            else => {},
        };
        try self.errAt(e, "`*none` makes a handle of nothing; write `none` where a `(*T)?` is expected", .{});
        return true;
    }

    /// The operand of `*x`, checked against `expected` when given: the
    /// one place a `Signal(...)` constructor may stand.
    fn shareOperand(self: *Checker, operand: Sexp, expected: ?TypeId) Error!TypeId {
        const prev = self.shared_operand;
        defer self.shared_operand = prev;
        self.shared_operand = operand;
        const e = expected orelse return self.synthExpr(operand);
        try self.checkExpr(operand, e);
        return e;
    }

    /// `^x`: `x` moved into a new box, checked against the box's value
    /// type when `target` is a box.
    /// The type `sigil` over `inner` would be, as a diagnostic spells it.
    fn stackedSpelling(self: *Checker, sigil: u8, inner: TypeId) Error![]const u8 {
        // A suffix binds tighter than a holding sigil: `*(~T?)`.
        const shown = try self.tyName(inner);
        if (self.ctx.types.get(inner) == .optional) return self.ctx.arena.allocator().print("{c}({s})", .{ sigil, shown });
        return self.ctx.arena.allocator().print("{c}{s}", .{ sigil, shown });
    }

    fn synthBox(self: *Checker, e: Sexp, target: ?TypeId) Error!TypeId {
        const operand = ir.Box.operand(e);
        if (try self.boxOfNone(e, target)) return self.t().invalid_id;
        if (operand.isKind(.lambda)) {
            try self.errAt(e, "`^` boxes a value, not a closure: an owned closure is `*|...| body`", .{});
            return self.t().invalid_id;
        }
        const want = if (target) |tt| sema.boxedType(self.ctx, tt) else null;
        const ty = if (want) |w| blk: {
            try self.checkExpr(operand, w);
            break :blk w;
        } else try self.synthExpr(operand);
        if (ty == self.t().int_literal_id) try self.defaultIntLiteral(operand);
        const inner = self.canonical(ty);
        if (self.isPoison(inner)) return inner;
        if (self.ctx.types.get(inner) == .function) {
            try self.errAt(operand, sema.boxed_function, .{});
            return self.t().invalid_id;
        }
        if (sema.heapStacked(self.ctx, inner)) {
            try self.errAt(operand, "this value is already `{s}`; `^` would hold it twice; " ++ sema.heap_stacked_rule, .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        var r = self.resolver();
        return r.boxOf(inner, self.startOf(e));
    }

    /// `^none` where no box of an optional is expected (`target`, a
    /// `^(T?)`, holds `none`) makes a box of nothing, which is
    /// rejected (reported): an optional box with no value is `none`
    /// itself.
    fn boxOfNone(self: *Checker, e: Sexp, target: ?TypeId) Error!bool {
        const operand = ir.Box.operand(e);
        if (operand != .src or !std.mem.eql(u8, self.text(operand), "none")) return false;
        if (self.under_poison) return false;
        if (target) |want| if (sema.boxedType(self.ctx, want)) |inner| if (self.ctx.types.get(inner) == .optional) return false;
        try self.errAt(e, "`^none` makes a box of nothing; write `none` where a `^T?` is expected", .{});
        return true;
    }

    fn synthWeak(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Weak.operand(e);
        const inner = try self.synthOperand(operand);
        if (self.isPoison(inner)) return inner;
        switch (self.ctx.types.get(inner)) {
            .shared => |target| return self.ctx.intern(.{ .weak = target }),
            else => {
                try self.errAt(operand, "`~` weak reference requires a shared handle `*T`; got `{s}`", .{try self.tyName(inner)});
                return self.t().invalid_id;
            },
        }
    }

    /// `+e` reads `e` (Core §3): a value made there is a temporary its
    /// statement drops, and a branching value's names are read in place.
    fn synthClone(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Clone.operand(e);
        if (try self.rejectSharedTemporary(operand)) return self.t().invalid_id;
        const inner = try self.synthReadTemp(operand);
        if (self.isPoison(inner)) return inner;
        // A `![]T` reaches elements it does not own; a copy of the view
        // would be a second path to them.
        if (sema.writeSliceElem(self.ctx, inner) != null) {
            try self.errAt(operand, "`+x` cannot clone a `{s}`: it is a write view of elements it does not own; move it with `<x`, or take a read slice with `?x[..]`", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        // A clone reads the value a view reaches.
        const value = try self.readThrough(operand, inner, sema.unwrapViews(self.ctx, inner));
        switch (sema.cloneable(self.ctx, inner)) {
            .copy, .bump, .text, .deep => {},
            .depends => try self.requireOf(value, .copies, self.startOf(operand), "clones a value"),
            .no => {
                const shown = try self.tyName(value);
                if (!sema.typeHasDropGlue(self.ctx, value) and sema.holdsWriteView(self.ctx, value)) {
                    try self.errAt(operand, "`+x` cannot clone a `{s}`: it holds a write view, which has one holder; move it with `<x`", .{shown});
                } else if (!sema.typeHasDropGlue(self.ctx, value)) {
                    try self.errAt(operand, "`+x` cannot clone a `{s}`: it is unique, and a copy would duplicate it; move it with `<x`", .{shown});
                } else if (sema.isUnique(self.ctx, value)) {
                    try self.errAt(operand, "`+x` cannot clone a `{s}`: it holds a unique value, which a copy would duplicate; move it with `<x`, or lend it", .{shown});
                } else if (sema.containsTypeVar(self.ctx, value)) {
                    try self.errAt(operand, "`+x` cannot clone a `{s}`: a type parameter has no deep clone in a generic body; move it with `<x`, or lend it", .{shown});
                } else try self.errAt(operand, "`+x` cannot clone a `{s}`: a value with a `drop` body, or holding a Signal, a write view, or a type from another module, has no clone; move it with `<x`, or lend it", .{shown});
                return self.t().invalid_id;
            },
        }
        // A `?String` view clones into the `String` that owns a copy of its bytes.
        return if (value == self.t().string_view_id) self.t().string_id else value;
    }

    /// The value an operator reads from `e` (`operandValue`).
    fn synthOperandValue(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, operandValue(self.ctx, ty));
    }

    /// The value a view `e` reaches, or `e`'s own value.
    fn synthReached(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, sema.unwrapViews(self.ctx, ty));
    }

    /// The value `e` gives where a value is read: a viewed Copy value
    /// reads as the value (`readValue`).
    fn synthValue(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, readValue(self.ctx, ty));
    }

    /// `value`, the value `e` of type `ty` gives where it is read; when
    /// that is what a view reaches, `e` reads through it (`readOf`).
    fn readThrough(self: *Checker, e: Sexp, ty: TypeId, value: TypeId) Error!TypeId {
        if (value != ty) try self.readOf(e, ty, .{ .value = value });
        return value;
    }

    /// `e`, of type `ty`, a view through which a place is reached (an
    /// element of a viewed slice or `?String`, a header's optional): read
    /// through, as no value but the place it reaches.
    fn reachThrough(self: *Checker, e: Sexp, ty: TypeId, value: TypeId) Error!TypeId {
        if (value != ty) try self.readOf(e, ty, .reach);
        return value;
    }

    /// Synthesize the operand of a view, clone, member access, index,
    /// or method call. The operand is not bound to a name, so a fresh
    /// value that owns a resource there would never be dropped.
    fn synthOperand(self: *Checker, operand: Sexp) Error!TypeId {
        if (try self.rejectSharedTemporary(operand)) return self.t().invalid_id;
        const ty = try self.synthExpr(operand);
        try self.rejectResourceTemporary(operand, ty);
        return ty;
    }

    /// `*Name(...)` where nothing binds it: a new allocation whatever its
    /// type turns out to be. True when reported.
    fn rejectSharedTemporary(self: *Checker, operand: Sexp) Error!bool {
        if (!operand.isKind(.share) or !ir.Share.operand(operand).isKind(.call) or ir.Call.callee(ir.Share.operand(operand)) != .src) return false;
        try self.errAt(operand, "this `*{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{self.text(ir.Call.callee(ir.Share.operand(operand)))});
        return true;
    }

    /// Whether a value of `ty` does not copy (`sema.copies`), for a
    /// check that rejects `op`, which copies one. Inside a generic body a
    /// type holding type parameters may or may not: `op` is then allowed,
    /// and every instantiation must supply values that copy
    /// (`Requirement.copies`).
    fn cannotCopy(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
        return switch (sema.copies(self.ctx, ty)) {
            .no => true,
            .yes => false,
            .depends => {
                try self.requireOf(ty, .copies, pos, op);
                return false;
            },
        };
    }

    /// Whether a value of `ty` moves (`sema.moves`), for a construct
    /// that takes such a value rather than reading a copy of it. Inside
    /// a generic body a type holding type parameters may or may not: the
    /// construct reads it, and every instantiation must supply values
    /// that copy (`Requirement.copies`).
    fn mustTake(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
        return switch (sema.moves(self.ctx, ty)) {
            .yes => true,
            .no => false,
            .depends => {
                try self.requireOf(ty, .copies, pos, op);
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
    fn needsCleanup(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
        if (sema.typeHasDropGlue(self.ctx, ty)) return true;
        if (sema.maybeDropGlue(self.ctx, ty)) try self.requireOf(ty, .no_cleanup, pos, op);
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
    fn meetsNeeds(self: *Checker, m: Field, owner_sym: SymbolId, args: []const TypeId, pos: u32) Error!bool {
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
            .copies => if (!try self.cannotCopy(param, pos, needs.op)) return true,
        }
        if ((try resolve.builtinElementError(self.ctx, owner_sym, args)) != null) return true;
        const owner = self.ctx.symbols.items[owner_sym].name;
        const shown = try self.tyName(param);
        switch (needs.says) {
            .element_out => |advice| try self.err(pos, "`{s}.{s}` would copy an element out of a `{s}` of `{s}`, which a copy cannot share; {s}", .{ owner, m.name, owner, shown, advice }),
            .value_out => |advice| try self.err(pos, "`{s}.{s}` returns a copy of the value, and {s} `{s}` {s}, so it can't be copied; {s}", .{ owner, m.name, article(shown), shown, if (sema.typeHasDropGlue(self.ctx, param)) "owns what it must release" else self.movesBecause(param), advice }),
            .into_elements => |d| try self.notDuplicated(pos, d.what, param, d.loop, d.tail),
        }
        return false;
    }

    /// The one diagnostic of a form that writes copies of a value it
    /// leaves in place (`copy`, `fill`, `[n of x]`, `List.filled`, and
    /// `resize`) when the element `elem` does not copy (docs/CORE.md §5,
    /// "Only a value that copies is duplicated without `+`"), at `at`, a
    /// node or a position. `what` says what the form copies, and `loop`
    /// is the loop that makes each element with `+x` instead, which the
    /// diagnostic offers, followed by `tail`, when `+x` clones `elem`.
    fn notDuplicated(self: *Checker, at: anytype, what: []const u8, elem: TypeId, loop: []const u8, tail: []const u8) Error!void {
        const shown = try self.tyName(elem);
        const why = self.movesBecause(elem);
        const args = .{ what, article(shown), shown, why };
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
        const with_loop = .{ what, article(shown), shown, why, loop, tail };
        if (@TypeOf(at) == Sexp) return self.errAt(at, fmt, with_loop);
        return self.err(at, fmt, with_loop);
    }

    /// Why a value of `ty`, which does not copy (`sema.copies`), cannot
    /// be copied, as a diagnostic says it.
    fn movesBecause(self: *const Checker, ty: TypeId) []const u8 {
        if (sema.typeHasDropGlue(self.ctx, ty)) return "owns a resource";
        if (sema.holdsWriteView(self.ctx, ty)) return "holds a write view, which has one holder";
        if (self.ctx.types.get(ty) == .any_error) return "is owning";
        if (sema.holdsAnyError(self.ctx, ty)) return "holds an `error`, which is owning";
        return "is unique";
    }

    /// Every type parameter `ty` holds must meet `req` in each instance.
    fn requireOf(self: *Checker, ty: TypeId, req: Requirement, pos: u32, op: []const u8) Error!void {
        var held: std.ArrayList(SymbolId) = .empty;
        defer held.deinit(self.ctx.allocator);
        try sema.heldTypeVars(self.ctx, ty, &held, self.ctx.allocator);
        for (held.items) |param| try self.ctx.generic_requirements.append(self.ctx.allocator, .{ .param = param, .req = req, .pos = pos, .op = op });
    }

    /// The temporary a read view of `operand` (or a slice of it) lends,
    /// the value itself or the value a field path starts from: it lives
    /// in a slot until its statement ends. A lend of a branching value
    /// that may be a name's value, or a part of a temporary, would copy
    /// that value into the slot, which a value that moves (an owner, or
    /// a unique value such as one holding a Cell) or a write view must
    /// not be: each branch is lent instead.
    fn lendTemp(self: *Checker, operand: Sexp) Error!void {
        return self.lendTempIn(operand, .nil);
    }

    /// `lendTemp` of `operand`, the object of the slice `whole` (or
    /// `.nil`), which the hint writes with each branch lent.
    fn lendTempIn(self: *Checker, operand: Sexp, whole: Sexp) Error!void {
        const base = if (self.hands(operand).hasStorage()) self.placeOf(operand).base else operand;
        if (base != .list) return;
        const ty = self.ctx.typeOf(base) orelse return;
        if (sema.moves(self.ctx, ty) == .yes or self.ctx.types.get(ty) == .write_view) if (!try self.lendsBranch(operand, whole, .read)) return;
        try self.ctx.recordTempDrop(base);
    }

    /// A leaf of `e` that is a value a name holds, where `e` hands over
    /// branches (`sema.handsOver`): a place, a part of one, or a lend.
    fn namedLeaf(self: *Checker, e: Sexp) ?Sexp {
        if (self.hands(e).kind != .branches) return null;
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        sema.valueLeaves(self.ctx.allocator, e, &leaves) catch return e;
        for (leaves.items) |leaf| if (self.hands(leaf).hasStorage()) return leaf;
        return null;
    }

    /// Synthesize `operand` where its value is only read (`readLeaf`).
    fn synthReadTemp(self: *Checker, operand: Sexp) Error!TypeId {
        const ty = try self.synthExpr(operand);
        if (!self.isPoison(ty)) try self.readLeaf(operand);
        return ty;
    }

    /// `e`, synthesized, is only read. Reading never moves a name: a
    /// read passes through a branching value (`a if c else b`, `??`,
    /// `catch`, `e!`, `e?`) to its leaves (`sema.valueLeaves`). A value
    /// made where it is only read (a call's result, a constructor, `+x`,
    /// `<x`, a block or `match` value) is a temporary: one that owns a
    /// resource is dropped when its statement ends.
    fn readLeaf(self: *Checker, e: Sexp) Error!void {
        return self.readLeafAs(e, true);
    }

    /// `readLeaf`, recording the use of `e` as a read only if `record_use`
    /// (a handle lent to write has its use recorded as a lend).
    fn readLeafAs(self: *Checker, e: Sexp, record_use: bool) Error!void {
        // A value a header holds is taken there, not read as a temporary.
        if (e == .list and sameNode(e, self.held_base)) return self.recordUse(e, .take);
        if (record_use) try self.recordUse(e, .read);
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        // A branching value whose every leaf is made here is itself a
        // value made here: one temporary.
        if (self.hands(e).kind == .branches) try sema.valueLeaves(self.ctx.allocator, e, &leaves) else try leaves.append(self.ctx.allocator, e);
        for (leaves.items) |leaf| {
            const leaf_hands = self.hands(leaf);
            // A name's value, or a part of one, is read where it is.
            if (leaf_hands.hasStorage()) {
                if (leaves.items.len > 1) try self.ctx.recordReadInPlace(leaf);
                continue;
            }
            if (leaf_hands.kind != .made) continue;
            // A literal, `none`, or a function lives for the whole program.
            if (leaf == .src) continue;
            const ty = self.ctx.typeOf(leaf) orelse continue;
            if (self.isPoison(ty) or sema.isReadOrWriteView(self.ctx, ty)) continue;
            // A fallible value's temporary holds what it gives on success.
            const held = switch (self.ctx.types.get(ty)) {
                .fallible => |inner| inner,
                else => ty,
            };
            if (try self.needsCleanup(held, self.startOf(leaf), "leaves a temporary")) try self.ctx.recordTempDrop(leaf);
        }
    }

    /// A fresh value (a call result, `*x`, `+x`, `<x`, ...) that owns a
    /// resource, where nothing takes ownership of it.
    fn rejectResourceTemporary(self: *Checker, operand: Sexp, ty: TypeId) Error!void {
        if (self.hands(operand).hasStorage() or !(try self.needsCleanup(ty, self.startOf(operand), "leaves a temporary"))) return;
        try self.errAt(operand, "this `{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{try self.tyName(ty)});
    }

    // ---- member access and indexing -------------------------------------------

    fn synthMember(self: *Checker, e: Sexp) Error!TypeId {
        const obj = ir.Member.object(e);
        const field_node = ir.Member.name(e);
        const field = self.text(field_node);
        const pos = srcPos(field_node, self.startOf(obj));
        const saved_in_place = self.in_place;
        defer self.in_place = saved_in_place;
        self.in_place = obj;

        if (try self.moduleMember(obj, field, pos)) |ty| return ty;
        if (try self.numberType(obj)) |ty| return self.numberLimit(obj, ty, field, pos);
        if (try self.namedType(obj)) |nt| {
            const ty = try self.typeMember(nt, field, pos);
            if (nt.sym.flags.error_set and !self.isPoison(ty)) try self.ctx.recordErrorMember(e);
            return ty;
        }
        // A field of a temporary is read where it stands, and the
        // statement drops the temporary. Taking an owning field out of it
        // is taking a part of its parent, which the ownership checker
        // rejects.
        if (!self.hands(obj).hasStorage()) return self.memberOf(e, obj, try self.synthReadTemp(obj));
        return self.memberOf(e, obj, try self.synthOperand(obj));
    }

    /// `U8.max`, `Int.min`, `F64.max`: the greatest or least value of a
    /// number type, a constant of it. A float's least is the most
    /// negative finite value.
    fn numberLimit(self: *Checker, obj: Sexp, ty: TypeId, field: []const u8, pos: u32) Error!TypeId {
        if (self.isPoison(ty)) return ty;
        if (std.mem.eql(u8, field, "min") or std.mem.eql(u8, field, "max")) return ty;
        try self.err(pos, "a number type has no member `{s}`; its limits are `{s}.min` and `{s}.max`", .{ field, self.sourceText(obj), self.sourceText(obj) });
        return self.t().invalid_id;
    }

    /// The number type `obj` names: a built-in one (`U8`), or an alias
    /// of one (`type Byte = U8`); null for anything else.
    fn numberType(self: *Checker, obj: Sexp) Error!?TypeId {
        if (obj.isKind(.member)) return self.importedNumberAlias(obj);
        if (obj != .src) return null;
        const id = self.lookupQuiet(obj) orelse {
            if (!resolve.isNumericTypeName(self.text(obj))) return null;
            var r = self.resolver();
            return try r.resolveType(obj);
        };
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .type_alias or !sema.isNumeric(self.ctx, sym.ty)) return null;
        try self.ctx.recordName(obj, id);
        return sym.ty;
    }

    /// `module.Byte`: an imported alias of a number type.
    fn importedNumberAlias(self: *Checker, obj: Sexp) Error!?TypeId {
        const module_sym = (try self.moduleNamed(ir.Member.object(obj))) orelse return null;
        const name = ir.Member.name(obj);
        const found = self.foreignLookup(module_sym, self.text(name)) orelse return null;
        if (found.sym.kind != .type_alias or !sema.isNumeric(found.ctx, found.sym.ty)) return null;
        _ = (try self.foreignSymbol(module_sym, self.text(name), name.src.pos)) orelse return self.t().invalid_id;
        return try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
    }

    /// A field or method reached through weak handle `obj`, which does not
    /// keep its value alive: `*w` upgrades it. A box or a counted handle
    /// holds no weak handle (`sema.heapStacked`), so `obj` is the weak
    /// handle or a view of one.
    fn weakReach(self: *Checker, obj: Sexp, weak: TypeId, pos: u32) Error!void {
        const shown = try self.plainText(stripSigil(obj));
        try self.err(pos, "a weak handle `{s}` reaches its value only once upgraded with `*{s}`: `if *{s} as s`", .{ try self.tyName(weak), shown, shown });
    }

    /// Member `e` of `obj`, a value of type `obj_ty`.
    fn memberOf(self: *Checker, e: Sexp, obj: Sexp, obj_ty: TypeId) Error!TypeId {
        const field_node = ir.Member.name(e);
        const field = self.text(field_node);
        const pos = srcPos(field_node, self.startOf(obj));
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapAccess(self.ctx, obj_ty);

        switch (self.ctx.types.get(peeled)) {
            .optional => {
                try self.err(pos, "cannot access `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ field, try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            .array, .slice, .string_view, .static, .string => if (std.mem.eql(u8, field, "len")) return self.t().int_id,
            .parameterized_nominal => if ((listElementType(self.ctx, peeled) != null or cellListElement(self.ctx, peeled) != null) and std.mem.eql(u8, field, "len")) return self.t().int_id,
            .type_var => {
                try self.err(pos, "a generic parameter `{s}` has no fields; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            else => {},
        }

        // `e.text`: the name of a plain enum value's variant.
        if (std.mem.eql(u8, field, "text") and self.enumValues(peeled) != null) {
            if (self.hasVariantNames(peeled)) {
                try self.ctx.recordEnumText(e);
                return self.t().static_id;
            }
            if ((try self.findMethod(obj_ty, field)) == null) {
                try self.err(pos, "`.text` is the name of a plain enum's variant; `{s}` {s}", .{ try self.tyName(peeled), notPlainWhy(self.ctx, peeled) });
                return self.t().invalid_id;
            }
        }
        // `value` names a Cell's constructor argument, not a field to read.
        if (std.mem.eql(u8, field, "value") and cellElementType(self.ctx, peeled) != null) {
            try self.err(pos, "a Cell is read with `c.get()` and written with `!c.set(v)`, not through `.value`", .{});
            return self.t().invalid_id;
        }

        if (try self.dataField(obj_ty, field, pos, e)) |ty| return ty;
        const decl = sema.nominalDecl(self.ctx, peeled) orelse {
            // An element method named without its call.
            const has_elems = switch (self.ctx.types.get(peeled)) {
                .array, .slice, .string_view, .static => true,
                else => listElementType(self.ctx, peeled) != null,
            };
            if (has_elems) if (std.meta.stringToEnum(sema.ElemOp, field)) |op| if (!op.isBits() and !op.isSimd() and !op.isTypeFn() and op != .hash) {
                const shown = switch (op) {
                    .copy => "!xs.copy(src)",
                    .fill => "!xs.fill(v)",
                    .swap => "!xs.swap(i, j)",
                    .read => "xs.read[U32, .little](at)",
                    .write => "!xs.write[U32, .little](at, v)",
                    .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag, .hash => unreachable,
                };
                try self.err(pos, "`{s}` is a method of `{s}`, only called: `{s}`", .{ field, try self.tyName(obj_ty), shown });
                return self.t().invalid_id;
            };
            if (self.ctx.types.get(peeled) == .weak) {
                try self.weakReach(obj, peeled, pos);
            } else try self.err(pos, "type `{s}` has no field `{s}`", .{ try self.tyName(obj_ty), field });
            return self.t().invalid_id;
        };
        const owner = decl.symbol();
        if ((try self.findMethod(obj_ty, field)) != null) {
            if (owner.kind == .generic_type) {
                try self.err(pos, "method `{s}` must be called; wrap it in a closure to pass it as a value", .{field});
            } else {
                const tname = if (decl.module_id != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ decl.ctx.name, owner.name }) else owner.name;
                try self.err(pos, "method `{s}` must be called; to pass it as a function that takes the receiver first, name it through its type: `{s}.{s}`", .{ field, tname, field });
            }
        } else if (owner.fields == null) {
            try self.err(pos, "opaque type `{s}` has no accessible fields", .{owner.name});
        } else {
            try self.err(pos, "no field `{s}` on type `{s}`{s}", .{ field, owner.name, try self.memberHint(owner.fields.?, field, .field) });
            try self.noteDeclared(owner, decl.module_id == null);
        }
        return self.t().invalid_id;
    }

    /// The type of data field `name` of a receiver's nominal type, local
    /// or imported, used at `pos`: another module's field must be `pub`.
    /// `member`, the access `x.name`, is recorded when the field is
    /// read-only here (`noteReadOnly`).
    fn dataField(self: *Checker, obj_ty: TypeId, name: []const u8, pos: u32, member: Sexp) Error!?TypeId {
        if (try sema.lookupDataField(self.ctx, obj_ty, name)) |f| {
            const owner = self.ctx.symbols.items[f.nominal_sym];
            try self.checkVisible(f.field, owner, null, pos);
            try self.noteReadOnly(member, f.field, owner, null);
            return f.ty;
        }
        const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return null;
        const module_id = decl.module_id orelse return null;
        const f = (try findDataField(self.ctx, decl.symbol().fields orelse &.{}, name)) orelse return null;
        try self.checkVisible(f, decl.symbol(), module_id, pos);
        try self.noteReadOnly(member, f, decl.symbol(), module_id);
        return try sema.importType(self.ctx, self.ctx.foreign_semas.get(module_id).?, f.ty, module_id);
    }

    /// Record the member access `member` when its field `f`, of `owner`
    /// (declared in module `module`, or here, where a proxy stands for
    /// another module's generic type), is `pub ?name: T` in another
    /// module: read-only here. The one place this is decided.
    fn noteReadOnly(self: *Checker, member: Sexp, f: Field, owner: sema.Symbol, module: ?u32) Error!void {
        if (member == .nil or !f.read_only) return;
        const m = module orelse if (sema.isProxy(owner)) owner.from.module_id else return;
        if (m == self.ctx.module_id) return;
        const foreign = self.ctx.foreign_semas.get(m) orelse return;
        // An imported type is named as checkVisible names it; a proxy is
        // already named as this module spells it (`lib.Wrap`).
        const owner_name = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, owner.name }) else owner.name;
        try self.ctx.recordReadOnlyField(member, .{ .field = f.name, .owner = owner_name, .module = foreign.name });
    }

    /// A field or method of a type another module declares, used at
    /// `pos`, must be declared `pub` there; variants always are visible.
    /// `owner` is the type's symbol: in module `module` (an imported
    /// type), or here (a proxy stands for another module's generic type).
    fn checkVisible(self: *Checker, f: Field, owner: sema.Symbol, module: ?u32, pos: u32) Error!void {
        if (f.is_pub or f.is_variant) return;
        const m = module orelse if (sema.isProxy(owner)) owner.from.module_id else return;
        if (m == self.ctx.module_id) return;
        const foreign = self.ctx.foreign_semas.get(m) orelse return;
        // A proxy is named as this module spells it already: `lib.Wrap`.
        const tname = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, owner.name }) else owner.name;
        if (f.is_method) {
            // A proxy's methods have this module's types.
            const types = if (module != null) &foreign.types else self.t();
            const is_sub = switch (types.get(f.ty)) {
                .function => |fty| fty.is_sub,
                else => false,
            };
            const kw = if (is_sub) "sub" else "fun";
            if (foreign.is_std) {
                try self.err(pos, "method `{s}` of `{s}` is private to the standard library's module `{s}`", .{ f.name, tname, foreign.name });
            } else {
                // A method declared outside its type's body names the type.
                const outside = if (foreign.parser) |fp| fp.outside_members.contains(f.decl_pos) else false;
                const shown = if (outside) try self.ctx.arena.allocator().print("{s}.{s}", .{ owner.name, f.name }) else f.name;
                try self.err(pos, "method `{s}` of `{s}` is private to module `{s}`; declare it `pub {s} {s}` there to call it from here", .{ f.name, tname, foreign.name, kw, shown });
            }
        } else if (foreign.is_std) {
            try self.err(pos, "field `{s}` of `{s}` is private to the standard library's module `{s}`", .{ f.name, tname, foreign.name });
        } else {
            try self.err(pos, "field `{s}` of `{s}` is private to module `{s}`; declare it `pub {s}: ...` there to use it from here", .{ f.name, tname, foreign.name, f.name });
        }
        if (f.decl_pos < sema.imported_decl_pos) try self.ctx.noteIn(m, f.decl_pos, "`{s}` declared here", .{f.name});
    }

    /// A method of a receiver's nominal type, local or imported, with
    /// its signature in this module's types.
    const Method = struct {
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

    fn findMethod(self: *Checker, obj_ty: TypeId, name: []const u8) Error!?Method {
        if (try sema.lookupMethod(self.ctx, obj_ty, name)) |m| {
            return .{ .field = m.field, .fn_ty = m.fn_ty, .owner = self.ctx.symbols.items[m.nominal_sym].name, .nominal_sym = m.nominal_sym, .source = self.declSource(m.nominal_sym), .owner_sym = self.ctx.symbols.items[m.nominal_sym], .args = m.subst.args };
        }
        const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return null;
        const module_id = decl.module_id orelse return null;
        const foreign = self.ctx.foreign_semas.get(module_id).?;
        const fields = decl.symbol().fields orelse &.{};
        const f = fields[(try sema.findMember(self.ctx, fields, name, .method)) orelse return null];
        const ty = self.ctx.types.get(try sema.importType(self.ctx, foreign, f.ty, module_id));
        if (ty != .function) return null;
        return .{ .field = f, .fn_ty = ty.function, .owner = decl.symbol().name, .nominal_sym = sema.symbol_invalid, .source = foreign.source, .owner_sym = decl.symbol(), .module = module_id };
    }

    /// `module.name` as a value. Null when `obj` does not name a module.
    fn moduleMember(self: *Checker, obj: Sexp, field: []const u8, pos: u32) Error!?TypeId {
        const id = (try self.moduleNamed(obj)) orelse return null;
        const found = (try self.foreignSymbol(id, field, pos)) orelse return self.t().invalid_id;
        if (found.sym.kind == .nominal_type or found.sym.kind == .generic_type or found.sym.kind == .type_alias) {
            try self.err(pos, "`{s}.{s}` is a type, not a value", .{ self.text(obj), field });
            return self.t().invalid_id;
        }
        const ty = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
        if (found.sym.kind == .function) return try self.functionValue(ty, try self.ctx.arena.allocator().print("{s}.{s}", .{ self.text(obj), field }), pos, found.sym.flags.inline_marked);
        return ty;
    }

    /// A nominal type named where a value could be (`Type`, or
    /// `module.Type` for an imported one), whose members `Type.name`
    /// and `Type.name(...)` reach.
    const NamedType = struct {
        id: SymbolId,
        sym: sema.Symbol,
        /// Where an imported type is declared.
        foreign: ?ForeignFields = null,
        /// A generic type's arguments, when given (`Pair[Int, ?String]`).
        args: ?[]const TypeId = null,
    };

    fn namedType(self: *Checker, obj: Sexp) Error!?NamedType {
        if (rig.isBracketList(obj)) {
            const target = (try self.instTarget(ir.get(obj, .object))) orelse return null;
            if (target != .generic or target.generic.id == self.ctx.simd_sym_id) return null;
            var nt = target.generic;
            const ty = try self.typeInstance(obj, nt);
            const arity = if (nt.sym.type_params) |tps| tps.len else 0;
            nt.args = if (self.isPoison(ty)) try self.poisonArgs(arity) else self.ctx.types.get(ty).parameterized_nominal.args;
            return nt;
        }
        if (obj == .src) {
            const id = self.lookupQuiet(obj) orelse return null;
            const sym = self.ctx.symbols.items[id];
            if (sym.kind == .type_alias) {
                const nt = self.aliasNamedType(sym.ty) orelse return null;
                if (nt.foreign == null) try self.ctx.recordName(obj, nt.id);
                return nt;
            }
            if (sym.kind != .nominal_type and sym.kind != .generic_type) return null;
            try self.ctx.recordName(obj, id);
            return .{ .id = id, .sym = sym };
        }
        if (!obj.isKind(.member)) return null;
        const id = (try self.moduleNamed(ir.Member.object(obj))) orelse return null;
        const name = ir.Member.name(obj);
        const found = (try self.foreignSymbol(id, self.text(name), name.src.pos)) orelse return null;
        if (found.sym.kind == .type_alias) return self.aliasNamedType(try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id));
        if (found.sym.kind == .generic_type) return try self.foreignGeneric(found);
        if (found.sym.kind != .nominal_type) return null;
        return .{ .id = found.id, .sym = found.sym, .foreign = .{ .ctx = found.ctx, .module_id = found.module_id } };
    }

    /// The struct or enum an alias names, `ty` being the aliased type in
    /// this module's terms: the alias constructs its values and reaches
    /// its members as the type itself does. Null for an alias of any
    /// other type.
    fn aliasNamedType(self: *Checker, ty: TypeId) ?NamedType {
        return switch (self.ctx.types.get(ty)) {
            .nominal => |id| .{ .id = id, .sym = self.ctx.symbols.items[id] },
            .imported_nominal => |in| blk: {
                const foreign = self.ctx.foreign_semas.get(in.module_id) orelse break :blk null;
                break :blk .{ .id = in.sym_id, .sym = foreign.symbols.items[in.sym_id], .foreign = .{ .ctx = foreign, .module_id = in.module_id } };
            },
            .parameterized_nominal => |pn| .{ .id = pn.sym, .sym = self.ctx.symbols.items[pn.sym], .args = pn.args },
            else => null,
        };
    }

    /// A named type as this module spells it: `lib.Point` for another
    /// module's (a generic one's proxy is named so already).
    fn namedTypeName(self: *Checker, nt: NamedType) Error![]const u8 {
        const fo = nt.foreign orelse return nt.sym.name;
        return self.ctx.arena.allocator().print("{s}.{s}", .{ fo.ctx.name, nt.sym.name });
    }

    /// Another module's generic type, named here by its proxy
    /// (`sema.proxyOf`), whose members are in this module's types.
    fn foreignGeneric(self: *Checker, found: Foreign) Error!NamedType {
        const id = try sema.proxyOf(self.ctx, .{ .module_id = found.module_id, .sym = found.id });
        return .{ .id = id, .sym = self.ctx.symbols.items[id] };
    }

    /// The source of the module that declares symbol `id`'s members and
    /// defaults: another module's, for a proxy.
    fn declSource(self: *Checker, id: SymbolId) []const u8 {
        const sym = self.ctx.symbols.items[id];
        if (!sema.isProxy(sym)) return self.ctx.source;
        return (self.ctx.foreign_semas.get(sym.from.module_id) orelse return self.ctx.source).source;
    }

    /// The type a (non-generic) named type denotes.
    fn namedTypeValue(self: *Checker, nt: NamedType) Error!TypeId {
        if (nt.foreign) |fo| return self.ctx.intern(.{ .imported_nominal = .{ .module_id = fo.module_id, .sym_id = nt.id } });
        return self.ctx.intern(.{ .nominal = nt.id });
    }

    /// `Type.variant`: a variant without a payload.
    fn typeMember(self: *Checker, nt: NamedType, field: []const u8, pos: u32) Error!TypeId {
        const tname = try self.namedTypeName(nt);
        const members = nt.sym.fields orelse {
            try self.err(pos, "opaque type `{s}` has no members", .{tname});
            return self.t().invalid_id;
        };
        // The first member of that name decides.
        found: {
            const m = members[(try sema.findMember(self.ctx, members, field, .any)) orelse break :found];
            // `Type.method` is a plain function value whose first
            // parameter is the receiver.
            if (m.is_method) {
                try self.checkVisible(m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, pos);
                if (nt.sym.kind == .generic_type) {
                    try self.err(pos, "method `{s}.{s}` of a generic type must be called; wrap it in a closure to pass it as a value", .{ tname, field });
                    return self.t().invalid_id;
                }
                const name = try self.ctx.arena.allocator().print("{s}.{s}", .{ tname, field });
                return self.functionValue(try self.memberType(nt.foreign, m.ty), name, pos, m.inline_marked);
            }
            if (!m.is_variant) break :found;
            if (nt.sym.kind == .generic_type and nt.args == null) {
                try self.err(pos, "variant of generic enum `{s}` needs its type; write `{s}[...].{s}`, or `.{s}` where a `{s}[...]` is expected", .{ tname, tname, field, field, tname });
                return self.t().invalid_id;
            }
            if (m.payload != null and m.payload.?.len > 0) {
                try self.err(pos, "variant `{s}.{s}` carries a payload; construct it with `{s}.{s}(...)`", .{ tname, field, tname, field });
                return self.t().invalid_id;
            }
            if (nt.args) |given| return self.instantiate(nt.id, given, pos);
            return self.namedTypeValue(nt);
        }
        try self.err(pos, "no member `{s}` on type `{s}`", .{ field, tname });
        try self.noteDeclared(nt.sym, nt.foreign == null);
        return self.t().invalid_id;
    }

    // ---- compile-time arguments ---------------------------------------------
    //
    // `x[...]` is an `index` (one argument) or an `inst` (more) in the IR.
    // It gives compile-time arguments when `x` names a generic type or a
    // function; otherwise it indexes. Each bracket list read as
    // compile-time arguments is recorded as an instance
    // (`SemContext.instanceOf`).

    /// What the object of a bracket list names, when that makes the list
    /// compile-time arguments; null when it is an index.
    const InstTarget = union(enum) {
        /// A generic type, local or built in: `List[Int]`.
        generic: NamedType,
        /// A function, named directly, through its module, or through
        /// its type: `check[.strict]`, `m.f[2]`, `Pair.make[1]`.
        function: FnTarget,
        /// `value.name[...]`: a method's compile-time arguments, or an
        /// element of a field; the receiver's type tells which.
        value_member,
        /// A type that takes no type arguments; its name.
        not_generic: []const u8,
        /// A generic type of another module that is not public, reported.
        reported,
    };

    /// `X[...]` where `X` is a type that takes no type arguments here.
    fn notGeneric(self: *Checker, at: Sexp, target: InstTarget) Error!void {
        switch (target) {
            .reported => {},
            .not_generic => |name| try self.errAt(at, "`{s}` is not a generic type; it takes no type arguments", .{name}),
            else => unreachable,
        }
    }

    fn instTarget(self: *Checker, obj: Sexp) Error!?InstTarget {
        if (obj == .src) {
            const id = self.lookupQuiet(obj) orelse {
                const name = self.text(obj);
                return if (resolve.isBuiltinTypeName(self.ctx, name)) .{ .not_generic = name } else null;
            };
            const sym = self.ctx.symbols.items[id];
            switch (sym.kind) {
                .function, .@"extern" => return .{ .function = fnTarget(self.ctx, sym.ty) },
                .generic_type => {
                    try self.ctx.recordName(obj, id);
                    return .{ .generic = .{ .id = id, .sym = sym } };
                },
                .nominal_type, .type_alias => return .{ .not_generic = sym.name },
                else => return null,
            }
        }
        if (!obj.isKind(.member)) return null;
        const inner = ir.Member.object(obj);
        const name = self.text(ir.Member.name(obj));
        if (inner == .src) if (self.lookupQuiet(inner)) |id| if (self.ctx.symbols.items[id].kind == .module) {
            const f = self.foreignLookup(id, name) orelse return null;
            return switch (f.sym.kind) {
                .function, .@"extern" => .{ .function = fnTarget(f.ctx, f.sym.ty) },
                .nominal_type, .type_alias => .{ .not_generic = self.sourceText(obj) },
                .generic_type => blk: {
                    try self.ctx.recordName(inner, id);
                    const found = (try self.foreignSymbol(id, name, ir.Member.name(obj).src.pos)) orelse break :blk .reported;
                    break :blk .{ .generic = try self.foreignGeneric(found) };
                },
                else => null,
            };
        };
        if (try self.namedType(inner)) |nt| {
            const fields = nt.sym.fields orelse &.{};
            const m = fields[(try sema.findMember(self.ctx, fields, name, .method)) orelse return null];
            return .{ .function = fnTarget(if (nt.foreign) |fo| fo.ctx else self.ctx, m.ty) };
        }
        return .value_member;
    }

    /// Whether a function has compile-time and run-time parameters.
    const FnTarget = struct { ct_params: bool, takes_args: bool };

    /// The `FnTarget` of function type `ty` (of `ctx`).
    fn fnTarget(ctx: *const SemContext, ty: TypeId) FnTarget {
        const f = ctx.types.get(ty);
        if (f != .function) return .{ .ct_params = true, .takes_args = true };
        return .{ .ct_params = f.function.ct_params.len > 0, .takes_args = f.function.params.len > 0 };
    }

    /// The source text of a node, for messages.
    fn sourceText(self: *Checker, node: Sexp) []const u8 {
        const sp = self.ctx.span(node);
        return diag.textOf(self.ctx.source, sp);
    }

    /// `n` poison type arguments, for a generic whose given arguments
    /// were rejected.
    fn poisonArgs(self: *Checker, n: usize) Error![]const TypeId {
        const out = try self.ctx.arena.allocator().alloc(TypeId, n);
        @memset(out, self.t().invalid_id);
        return out;
    }

    /// A bracket list of compile-time arguments where a value is
    /// expected: a type, or a function that is not called.
    fn misusedInstance(self: *Checker, e: Sexp, target: InstTarget) Error!TypeId {
        switch (target) {
            .generic => |nt| {
                if (!self.isPoison(try self.typeInstance(e, nt))) try self.errAt(e, "`{s}` is a type, not a value", .{self.sourceText(e)});
            },
            .function => |f| {
                const call = self.sourceText(e);
                if (!f.ct_params) {
                    const name = self.sourceText(ir.get(e, .object));
                    try self.errAt(e, "`{s}` takes no compile-time arguments; call it with `{s}(...)`", .{ name, name });
                } else try self.errAt(e, "`{s}` is a function with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (f.takes_args) "..." else "" });
            },
            .not_generic, .reported => try self.notGeneric(e, target),
            .value_member => unreachable,
        }
        return self.t().invalid_id;
    }

    /// The instance of generic type `nt` that bracket list `e` names
    /// (`Pair[Int, ?String]`), recorded for `e`; poison after a
    /// diagnostic.
    fn typeInstance(self: *Checker, e: Sexp, nt: NamedType) Error!TypeId {
        const params = nt.sym.type_params orelse &.{};
        const given = sema.bracketArgs(e);
        if (given.len != params.len) {
            try self.errAt(e, "generic type `{s}` expects {d} {s} argument{s}, got {d}", .{ nt.sym.name, params.len, resolve.argsNoun(self.ctx, params), plural(params.len), given.len });
            return self.t().invalid_id;
        }
        const args = try self.ctx.arena.allocator().alloc(TypeId, given.len);
        var bad = false;
        for (given, args, params, 0..) |g, *a, tp, i| {
            a.* = if (self.ctx.symbols.items[tp].kind == .param)
                (try self.ctIntArg(g, tp, i, nt.sym.name)) orelse self.t().invalid_id
            else
                try self.typeArg(g);
            if (self.isPoison(a.*)) bad = true;
        }
        if (bad) return self.t().invalid_id;
        const ty = try self.instantiate(nt.id, args, self.startOf(e));
        try self.ctx.recordInstance(e, .{ .type = ty });
        return ty;
    }

    /// A type argument written in an expression (`List[*Node]()`): a
    /// name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[Y]`.
    fn typeArg(self: *Checker, e: Sexp) Error!TypeId {
        var r = self.resolver();
        switch (e) {
            .src => if (!isLiteralText(self.text(e))) return r.resolveType(e),
            .list => switch (e.kind() orelse return self.t().invalid_id) {
                .member => if (ir.Member.object(e) == .src) return r.resolveType(e),
                .box => {
                    if (try self.optionalHandleArg(e)) |ty| return ty;
                    const inner_node = ir.Box.operand(e);
                    const inner = try self.typeArg(inner_node);
                    if (self.isPoison(inner)) return inner;
                    if (self.ctx.types.get(inner) == .function) {
                        try self.errAt(e, sema.boxed_function, .{});
                        return self.t().invalid_id;
                    }
                    if (sema.heapStacked(self.ctx, inner)) {
                        try self.errAt(e, sema.heap_stacked, .{try self.stackedSpelling('^', inner)});
                        return self.t().invalid_id;
                    }
                    return r.boxOf(inner, self.startOf(e));
                },
                .share, .weak, .read, .write, .propagate_none => {
                    if (e.isKind(.share) or e.isKind(.weak)) if (try self.optionalHandleArg(e)) |ty| return ty;
                    const inner_node = ir.get(e, if (e.isKind(.propagate_none)) .value else .operand);
                    const inner = try self.typeArg(inner_node);
                    if (self.isPoison(inner)) return inner;
                    if (e.isKind(.share) and sema.heapStacked(self.ctx, inner)) {
                        try self.errAt(e, sema.heap_stacked, .{try self.stackedSpelling('*', inner)});
                        return self.t().invalid_id;
                    }
                    if ((e.isKind(.share) or e.isKind(.weak)) and sema.isReadOrWriteView(self.ctx, inner)) {
                        try self.errAt(e, "a handle holds a value, not a view: `{s}` has no handle", .{try self.tyName(inner)});
                        return self.t().invalid_id;
                    }
                    if (e.isKind(.share) or e.isKind(.weak)) try sema.requireHandleOf(self.ctx, inner, self.startOf(e), if (e.isKind(.share)) "`*`" else "`~`");
                    return self.ctx.intern(switch (e.kind().?) {
                        .share => .{ .shared = inner },
                        .weak => .{ .weak = inner },
                        .read => .{ .read_view = inner },
                        .write => .{ .write_view = inner },
                        else => .{ .optional = inner },
                    });
                },
                .propagate => {
                    try self.errAt(e, "a fallible type `{s}` is only allowed as a function's return type", .{self.sourceText(e)});
                    return self.t().invalid_id;
                },
                .index, .inst => if (try self.instTarget(ir.get(e, .object))) |target| switch (target) {
                    .generic => |nt| return self.typeInstance(e, nt),
                    .not_generic, .reported => {
                        try self.notGeneric(e, target);
                        return self.t().invalid_id;
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        }
        try self.errAt(e, "`{s}` is not a type; a type argument in an expression is a name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[T]`", .{self.sourceText(e)});
        return self.t().invalid_id;
    }

    /// `*T?`, `~T?`, `*~T?` written as a type argument: an optional
    /// handle, since a handle binds tighter than a suffix. An expression
    /// reads it as the handles of `T?`, so the suffixes move outside the
    /// whole chain of handles. A handle to an optional, `*(T?)`, has no
    /// expression spelling, and a fallible one is only a return type.
    /// Null when the chain has no suffix to move.
    fn optionalHandleArg(self: *Checker, e: Sexp) Error!?TypeId {
        var handles: std.ArrayList(Sexp) = .empty;
        var op = e;
        while (op.isKind(.share) or op.isKind(.weak) or op.isKind(.box)) : (op = ir.get(op, .operand)) try handles.append(self.ctx.arena.allocator(), op);
        if (!op.isKind(.propagate_none) and !op.isKind(.propagate)) return null;
        if (self.ctx.parser) |p| if (p.hasParenSuffix(e)) {
            try self.errAt(e, "a handle to an optional has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead", .{});
            return self.t().invalid_id;
        };
        var count: u32 = 0;
        var base = op;
        while (base.isKind(.propagate_none) or base.isKind(.propagate)) : (count += 1) {
            if (base.isKind(.propagate)) {
                try self.errAt(e, "a fallible type `{s}` is only allowed as a function's return type", .{self.sourceText(e)});
                return self.t().invalid_id;
            }
            base = ir.PropagateNone.value(base);
        }
        var ty = try self.typeArg(base);
        var inner_node = base;
        var i = handles.items.len;
        while (i > 0) {
            i -= 1;
            if (self.isPoison(ty)) return ty;
            const h = handles.items[i];
            if (h.isKind(.share) and sema.heapStacked(self.ctx, ty)) {
                try self.errAt(h, sema.heap_stacked, .{try self.stackedSpelling('*', ty)});
                return self.t().invalid_id;
            }
            if (h.isKind(.box) and sema.heapStacked(self.ctx, ty)) {
                try self.errAt(h, sema.heap_stacked, .{try self.stackedSpelling('^', ty)});
                return self.t().invalid_id;
            }
            if (h.isKind(.box)) {
                var r = self.resolver();
                ty = try r.boxOf(ty, self.startOf(h));
            } else ty = try self.ctx.intern(if (h.isKind(.share)) .{ .shared = ty } else .{ .weak = ty });
            inner_node = h;
        }
        while (count > 0) : (count -= 1) ty = try self.ctx.intern(.{ .optional = ty });
        return ty;
    }

    /// `Wrap[Int](v: 3)`, `List[Int]()`: a generic type constructed at the
    /// given arguments.
    fn constructInstance(self: *Checker, call: Sexp, e: Sexp, nt: NamedType, args: []const Sexp) Error!TypeId {
        const ty = try self.typeInstance(e, nt);
        if (self.isPoison(ty)) return self.skipCall(args);
        if (nt.id == self.ctx.list_sym_id) {
            try self.checkListConstruction(call);
            return ty;
        }
        if (nt.id == self.ctx.signal_sym_id and !sameNode(call, self.shared_operand)) return self.badCall(args, e, stack_signal, .{});
        const subst: TypeSubst = .{ .params = nt.sym.type_params orelse &.{}, .args = self.ctx.types.get(ty).parameterized_nominal.args };
        return self.construct(nt.id, args, self.startOf(e), subst, null);
    }

    /// The module a name leaf denotes, recorded as its symbol; null when
    /// it denotes no module.
    fn moduleNamed(self: *Checker, leaf: Sexp) Error!?SymbolId {
        if (leaf != .src) return null;
        const id = self.lookupQuiet(leaf) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        try self.ctx.recordName(leaf, id);
        return id;
    }

    /// The symbol a name leaf denotes where it is written, without
    /// diagnostics.
    fn lookupQuiet(self: *Checker, leaf: Sexp) ?SymbolId {
        return self.lookupAt(self.scope, self.text(leaf), leaf.src.pos);
    }

    /// `name` as seen at `pos` from `scope`: declaration order counts.
    fn lookupAt(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
        var sid: ?ScopeId = scope;
        while (sid) |s| {
            if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
            if (self.visibleIn(s, name, pos)) |id| return id;
            sid = self.ctx.scopes.items[s].parent;
        }
        return null;
    }

    const Foreign = struct {
        ctx: *SemContext,
        module_id: u32,
        id: SymbolId,
        sym: sema.Symbol,
    };

    /// A module-level symbol of an imported module, public or not.
    fn foreignLookup(self: *Checker, module_sym: SymbolId, name: []const u8) ?Foreign {
        const origin = self.ctx.module_refs.get(module_sym) orelse return null;
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse return null;
        return .{ .ctx = foreign, .module_id = origin, .id = fid, .sym = foreign.symbols.items[fid] };
    }

    /// A public module-level symbol of an imported module.
    fn foreignSymbol(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32) Error!?Foreign {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const origin = self.ctx.module_refs.get(module_sym) orelse {
            try self.err(pos, "module `{s}` was not loaded", .{module_name});
            return null;
        };
        if (self.ctx.foreign_semas.get(origin) == null) return null;
        const found = self.foreignLookup(module_sym, name) orelse {
            const foreign = self.ctx.foreign_semas.get(origin).?;
            try self.err(pos, "no member `{s}` in module `{s}`{s}", .{ name, module_name, sema.stdNameHint(foreign, name) });
            return null;
        };
        if (!found.sym.flags.is_public and found.sym.decl_pos != sema.builtin_decl_pos) {
            try sema.notPublic(self.ctx, pos, module_name, name, found.ctx);
            return null;
        }
        return found;
    }

    fn synthIndex(self: *Checker, e: Sexp) Error!TypeId {
        const object = ir.get(e, .object);
        if (e.isKind(.index) and ir.Index.index(e).isKind(.@"..")) return self.synthSlice(e, false);
        if (try self.instTarget(object)) |target| {
            if (target != .value_member) return self.misusedInstance(e, target);
            // `value.name[...]`: a method's compile-time arguments, which
            // only a call takes, or an element of a field.
            const inner = ir.Member.object(object);
            // A field of a temporary is read where it stands.
            const inner_ty = if (self.hands(inner).hasStorage()) try self.synthOperand(inner) else try self.synthReadTemp(inner);
            if (!self.isPoison(inner_ty)) if (try self.findMethod(inner_ty, self.text(ir.Member.name(object)))) |m| {
                const call = self.sourceText(e);
                const takes_args = m.fn_ty.params.len > @intFromBool(m.field.receiver != .none);
                try self.errAt(e, "`{s}` is a method with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (takes_args) "..." else "" });
                return self.t().invalid_id;
            };
            const field_ty = try self.memberOf(object, inner, inner_ty);
            try self.ctx.recordType(object, field_ty);
            return self.indexInto(e, field_ty);
        }
        // An element of a temporary is read where it stands, and the
        // statement drops the temporary.
        if (!self.hands(object).hasStorage() and e.isKind(.index)) return self.indexInto(e, try self.synthReadTemp(object));
        return self.indexInto(e, try self.synthOperand(object));
    }

    /// Element `e` (an `index` node) of a value of type `obj_ty`.
    fn indexInto(self: *Checker, e: Sexp, obj_ty: TypeId) Error!TypeId {
        const object = ir.get(e, .object);
        if (e.isKind(.inst)) {
            for (ir.Inst.args(e)) |a| _ = try self.synthQuiet(a);
            if (self.isPoison(obj_ty)) return obj_ty;
            try self.errAt(e, "an index is one value with no trailing comma; a list in brackets gives compile-time arguments, which only a generic type or a function with compile-time parameters takes", .{});
            return self.t().invalid_id;
        }
        const index = ir.Index.index(e);
        if (self.isPoison(obj_ty)) {
            _ = try self.synthQuiet(index);
            return obj_ty;
        }
        const idx_ty = try self.synthValue(index);
        if (self.isPoison(idx_ty)) return idx_ty;
        if (!sema.isInteger(self.ctx, idx_ty)) {
            try self.errAt(index, "an index must be an integer; got `{s}`{s}", .{ try self.tyName(idx_ty), try self.loopOrderHint(index, self.t().int_id) });
        } else if (idx_ty == self.t().int_literal_id) try self.defaultIntLiteral(index);
        // A lane of a vector is a value: the vector is read, and a constant
        // index is checked against the lane count now.
        if (sema.simdOf(self.ctx, obj_ty)) |v| {
            _ = try self.readThrough(object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
            try self.checkLaneIndex(index, sema.unwrapViews(self.ctx, obj_ty));
            return v.elem;
        }
        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .array => |a| {
                // A known length is part of the type, so a constant index
                // is checked now.
                if (sema.arrayLen(self.ctx, a)) |n| if (self.constInt(index)) |i| if (i < 0 or i >= n) {
                    try self.errAt(index, "index `{d}` is out of bounds for an array of length {d}", .{ i, n });
                };
                return a.elem;
            },
            .slice => |s| {
                _ = try self.reachThrough(object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
                return s.elem;
            },
            .string_view, .static => {
                _ = try self.reachThrough(object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
                return self.byteType();
            },
            // A List's element is a place, as a field is: what its context
            // does with it is checked where it is used.
            .parameterized_nominal => if (listElementType(self.ctx, peeled)) |elem| {
                return elem;
            } else if (cellListElement(self.ctx, peeled)) |elem| {
                if ((try self.cannotCopy(elem, self.startOf(object), "reads an element of a Cell's List"))) {
                    try self.errAt(object, cell_list_handle, .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                return elem;
            },
            else => {},
        }
        if (sema.unwrapViews(self.ctx, obj_ty) == self.t().string_id) {
            try self.errAt(object, "cannot index a value of type `{s}`; index its `?String` view: `(?{s}[..])[i]`", .{ try self.tyName(obj_ty), try self.plainText(stripSigil(object)) });
            return self.t().invalid_id;
        }
        try self.errAt(object, "cannot index a value of type `{s}`", .{try self.tyName(obj_ty)});
        return self.t().invalid_id;
    }

    /// The element of List `peeled` (the type of `object`), sliced. Null
    /// after a diagnostic.
    fn listSliceElem(self: *Checker, object: Sexp, obj_ty: TypeId, peeled: TypeId) Error!?TypeId {
        const elem = listElementType(self.ctx, peeled) orelse {
            try self.errAt(object, "cannot slice a value of type `{s}`; slice a `?String`, an array, a List, or a `[]T`", .{try self.tyName(obj_ty)});
            return null;
        };
        return elem;
    }

    /// `xs[a..b]`: the elements from `a` up to, not including, `b`. A
    /// `?String` gives a `?String` viewing what it views, and a `[]T` a `[]T`
    /// viewing the same elements. An array or a `List` of plain data gives
    /// a `[]T`, and a String a `?String`, only as `?xs[a..b]` (`lent`), or as
    /// an argument, where it is lent as `?xs[a..b]` would be and its
    /// context decides whether it takes the view (`lendView`): the slice
    /// is a read view of `xs`.
    fn synthSlice(self: *Checker, e: Sexp, written: bool) Error!TypeId {
        const object = ir.Index.object(e);
        const range = ir.Index.index(e);
        const arg = !written and sameExpr(e, self.view_arg);
        // A slice of a temporary is reported below, once. An argument's
        // is lent only where the slice lends what it slices.
        const obj_ty = if (self.hands(object).hasStorage() or !(written or arg)) try self.synthOperand(object) else if (written) try self.synthExpr(object) else blk: {
            if (try self.rejectSharedTemporary(object)) break :blk self.t().invalid_id;
            const ty = try self.synthExpr(object);
            if (!self.isPoison(ty) and !self.sliceLendsObject(ty)) try self.rejectResourceTemporary(object, ty);
            break :blk ty;
        };
        const lent = written or (arg and !self.isPoison(obj_ty) and self.sliceLendsObject(obj_ty));
        try self.checkSliceRange(range);
        if (self.isPoison(obj_ty)) return obj_ty;
        // What the slice lends, which the ownership checker reads.
        if (sema.sliceLend(self.ctx, obj_ty)) |lend| try self.ctx.recordSliceLend(e, lend);
        // A boxed String is sliced through its box.
        const peeled = stringOrBoxed(self.ctx, sema.unwrapViews(self.ctx, obj_ty));
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .string_view, .static, .slice => {
                _ = try self.reachThrough(object, obj_ty, peeled);
                try self.checkSliceBounds(range, null);
                // A `![]T` is lent like the array it views: a read
                // slice of it keeps it from being written meanwhile.
                if (!lent and self.sliceLendsObject(obj_ty)) {
                    try self.errAt(e, "a slice of a `![]T` views it; write `?{s}` or `!{s}`", .{ try self.plainText(e), try self.plainText(e) });
                    return self.t().invalid_id;
                }
                return peeled;
            },
            .array => |a| a.elem,
            // A view of a String is a `?String` that views it.
            .string => {
                try self.checkSliceBounds(range, null);
                // A slice of a view of a String views what it lends, as a
                // slice of a `?String` does.
                if (!lent and self.sliceLendsObject(obj_ty)) {
                    try self.errAt(e, "a slice of a String views it; write `?{s}`", .{try self.plainText(e)});
                    return self.t().invalid_id;
                }
                if (lent and !self.placeOf(object).named()) try self.lendTempIn(object, e);
                return self.t().string_view_id;
            },
            else => (try self.listSliceElem(object, obj_ty, peeled)) orelse return self.t().invalid_id,
        };
        const len: ?u64 = if (self.ctx.types.get(peeled) == .array) sema.arrayLen(self.ctx, self.ctx.types.get(peeled).array) else null;
        try self.checkSliceBounds(range, len);
        if (!lent) {
            try self.errAt(e, "a slice of an array or List views it; write `?{s}`", .{try self.plainText(e)});
            return self.t().invalid_id;
        }
        if (!self.placeOf(object).named()) try self.lendTempIn(object, e);
        return self.ctx.intern(.{ .slice = .{ .elem = elem } });
    }

    /// Whether a slice of a value of type `obj_ty` lends that value, as
    /// `?xs[a..b]` does (Core §4), so that nothing frees or overwrites
    /// what the slice views while it is used. Decided here, once, for
    /// every slice, written `?` or not, an argument or bound, by what
    /// holds the elements and how it is reached:
    /// - the elements of an array or a List, owned or through any view,
    ///   box, or handle: lent;
    /// - the elements a `![]T` views, which it writes: lent;
    /// - the bytes of a String, owned, in a box or a `*T`, or through a
    ///   write view of one, which may add to the String or replace it:
    ///   lent;
    /// - the bytes of a String through a read view (`?String`, `?*String`,
    ///   `?^String`), which cannot change while that view's loan
    ///   lives, and the slice carries it: not lent, a `?String` of its own;
    /// - what a `?String` or a `[]T` views, which writing the `?String` or the
    ///   `[]T` itself does not free: not lent.
    fn sliceLendsObject(self: *Checker, obj_ty: TypeId) bool {
        if (sema.writeSliceElem(self.ctx, obj_ty) != null) return true;
        return switch (self.ctx.types.get(stringOrBoxed(self.ctx, sema.unwrapViews(self.ctx, obj_ty)))) {
            .string_view, .static, .slice => false,
            .string => self.ctx.types.get(obj_ty) != .read_view,
            else => true,
        };
    }

    /// Whether `e` is a slice written with no lend that an argument
    /// lends, as `?e` would (`synthSlice`).
    fn slicedArg(self: *Checker, e: Sexp) bool {
        if (!rig.isRangeIndex(e) or !sameExpr(e, self.view_arg)) return false;
        const ty = self.ctx.typeOf(ir.Index.object(e)) orelse return false;
        return !self.isPoison(ty) and self.sliceLendsObject(ty);
    }

    /// A slice's bounds are integers: of one type when both are given,
    /// and `Int` when that is all a literal says. An open side
    /// (`xs[a..]`, `xs[..b]`) is the start or the end.
    fn checkSliceRange(self: *Checker, range: Sexp) Error!void {
        const lo = ir.@"..".left(range);
        const hi = ir.@"..".right(range);
        if (lo != .nil and hi != .nil) {
            _ = try self.checkIntDefaultOperands(range, "..", .integer, null);
            return;
        }
        const bound = if (lo != .nil) lo else hi;
        if (bound == .nil) return;
        const ty = try self.synthOperandValue(bound);
        if (self.isPoison(ty)) return;
        if (!sema.isInteger(self.ctx, ty)) return self.errAt(bound, "a slice bound must be an integer; got `{s}`", .{try self.tyName(ty)});
        if (ty == self.t().int_literal_id) try self.defaultIntLiteral(bound);
    }

    /// Constant bounds are checked now: `0 <= a <= b`, and `b <= len` for
    /// an array, whose length is part of its type. Others are checked
    /// when the slice is taken. An open end is the length.
    fn checkSliceBounds(self: *Checker, range: Sexp, len: ?u64) Error!void {
        const lo_node = ir.@"..".left(range);
        const hi_node = ir.@"..".right(range);
        const lo: ?Wide = if (lo_node == .nil) 0 else self.constInt(lo_node);
        if (lo) |a| if (a < 0) return self.errAt(lo_node, "a slice bound cannot be negative; got `{d}`", .{a});
        if (hi_node == .nil) {
            if (lo) |a| if (len) |n| if (a > n) return self.errAt(lo_node, "slice start `{d}` is past the end of an array of length {d}", .{ a, n });
            return;
        }
        if (self.constInt(hi_node)) |b| {
            if (b < 0) return self.errAt(hi_node, "a slice bound cannot be negative; got `{d}`", .{b});
            if (len) |n| if (b > n) return self.errAt(hi_node, "slice end `{d}` is past the end of an array of length {d}", .{ b, n });
            if (lo_node != .nil) if (lo) |a| if (a > b) return self.errAt(range, "slice `{d}..{d}` starts after it ends", .{ a, b });
        }
    }

    // ---- array literals ------------------------------------------------------

    fn synthArray(self: *Checker, node: Sexp) Error!TypeId {
        const elems = ir.Array.elems(node);
        if (elems.len == 0) {
            try self.errAt(node, "an empty array literal needs a type annotation (`xs: [0]Int = []`)", .{});
            return self.t().invalid_id;
        }
        const elem_tys = try self.ctx.arena.allocator().alloc(TypeId, elems.len);
        var elem = try self.synthExpr(elems[0]);
        elem_tys[0] = elem;
        for (elems[1..], 1..) |e, i| {
            const ty = try self.synthExpr(e);
            elem_tys[i] = ty;
            elem = (try self.unify(elem, ty, self.startOf(e))) orelse return self.t().invalid_id;
        }
        const concrete = self.canonical(elem);
        if (sema.writeViewMisplaced(self.ctx, concrete, .element)) {
            try self.errAt(node, sema.write_view_misplaced, .{try self.tyName(concrete)});
            return self.t().invalid_id;
        }
        if (concrete != elem) {
            for (elems) |e| try self.checkExpr(e, concrete);
        } else for (elems, elem_tys) |e, ty| try self.adaptLiteral(e, ty, concrete);
        // An array holds owners as a List does; a generic body's array
        // of a `T` needs each instance to own nothing.
        _ = try self.needsCleanup(concrete, self.startOf(node), "puts in an array a value");
        const ty = try self.ctx.intern(.{ .array = .{ .elem = concrete, .len = try sema.ctInt(self.ctx, elems.len) } });
        if (self.under_poison) return ty;
        return if (try sema.checkArrayBytes(self.ctx, self.startOf(node), ty)) ty else self.t().invalid_id;
    }

    fn checkArray(self: *Checker, node: Sexp, expected: TypeId) Error!?TypeId {
        const et = self.ctx.types.get(expected);
        if (et != .array) return null;
        const elems = ir.Array.elems(node);
        if (sema.arrayLen(self.ctx, et.array)) |n| {
            if (elems.len != n) try self.errAt(node, "array literal has {d} element{s}; `{s}` needs {d}", .{ elems.len, plural(elems.len), try self.tyName(expected), n });
        } else if (self.ctx.types.get(et.array.len) == .ct_param) {
            const len = try self.tyName(et.array.len);
            try self.errAt(node, "an array of compile-time length `{s}` is built with `[{s} of x]`, not a list of elements", .{ len, len });
        }
        for (elems) |e| try self.checkExpr(e, et.array.elem);
        return expected;
    }

    /// `[n of x]`: an array of `n` copies of `x`, where `n` is a
    /// compile-time integer. Its type is `[n]T` for `x`'s type `T`, or
    /// the array type `expected`, whose length it must have. The element
    /// is plain data: it is copied into every slot.
    fn checkArrayFill(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const value = ir.ArrayFill.value(node);
        var r = self.resolver();
        const len = try r.resolveCtInt(ir.ArrayFill.size(node), .array_len);
        var elem: TypeId = undefined;
        if (expected) |ex| {
            elem = self.ctx.types.get(ex).array.elem;
            try self.checkExpr(value, elem);
        } else {
            const ty = try self.synthExpr(value);
            elem = self.canonical(ty);
            if (elem != ty) try self.checkExpr(value, elem);
            switch (self.ctx.types.get(elem)) {
                .none_literal, .void, .noreturn => {
                    try self.errAt(value, "the element of `[n of x]` needs a type; give it where the array goes (`xs: [n]T? = [n of none]`)", .{});
                    return self.t().invalid_id;
                },
                else => {},
            }
        }
        if (self.isPoison(elem) or self.isPoison(len)) return self.t().invalid_id;
        if (try self.cannotCopy(elem, self.startOf(value), "copies into every slot of `[n of x]` a value")) {
            try self.notDuplicated(value, "`[n of x]` copies its element into every slot", elem, "`for 0..n` with `!xs.push(+x)`, into a List", ", or write the elements out, `[+x, +x]`");
            return self.t().invalid_id;
        }
        const ty = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
        // An expected array type was checked where it was spelled or
        // inferred.
        if (expected == null and !self.under_poison and !try sema.checkArrayBytes(self.ctx, self.startOf(node), ty)) return self.t().invalid_id;
        if (expected) |ex| if (ex != ty) {
            try self.errAt(node, "`{s}` has length `{s}`; `{s}` needs `{s}`", .{ self.sourceText(node), try self.tyName(len), try self.tyName(ex), try self.tyName(self.ctx.types.get(ex).array.len) });
            return self.t().invalid_id;
        };
        return ty;
    }

    // =========================================================================
    // Calls
    // =========================================================================

    /// A call whose type is `T!` must be the operand of `!` or `catch`:
    /// the failure path is never implicit.
    fn synthCall(self: *Checker, node: Sexp) Error!TypeId {
        const handled = sameNode(node, self.handled);
        const saved = self.current_call;
        self.current_call = node;
        defer self.current_call = saved;
        // What the call reaches, recorded where it resolves to a Rig
        // function (`noteTarget`); any other call reaches none.
        try self.ctx.recordCallTarget(node, .none);
        const ty = try self.synthCallInner(node);
        // A call that gives several results stands only where each is
        // bound at once, or where they are returned whole.
        if (sema.resultsOf(self.ctx, ty) != null and !sameNode(node, self.results_ok)) {
            try self.misplacedResults(node, ty);
            return self.t().invalid_id;
        }
        if (!handled and self.ctx.types.get(ty) == .fallible) {
            const callee = ir.Call.callee(node);
            const name = try self.calleeName(callee);
            try self.errAt(callee, "fallible call to `{s}` must be wrapped with `!` (propagate) or `catch` (handle)", .{name});
            if (self.ctx.symbolOf(callee)) |id| {
                const sym = self.ctx.symbols.items[id];
                if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared as fallible here", .{name});
            }
        }
        return ty;
    }

    /// How a callee is spelled, for messages: `f`, `a.f`, or `.m`.
    fn calleeName(self: *Checker, callee: Sexp) Error![]const u8 {
        if (callee == .src) return self.text(callee);
        if (callee.isKind(.member)) {
            const obj = ir.Member.object(callee);
            const name = self.text(ir.Member.name(callee));
            if (obj == .src) return self.ctx.arena.allocator().print("{s}.{s}", .{ self.text(obj), name });
            return name;
        }
        return "expression";
    }

    fn synthCallInner(self: *Checker, node: Sexp) Error!TypeId {
        var callee = ir.Call.callee(node);
        const args = ir.Call.args(node);

        // `f[...](args)`, `Wrap[Int](args)`: compile-time arguments.
        var ct: ?Sexp = null;
        if (rig.isBracketList(callee)) if (try self.instTarget(ir.get(callee, .object))) |target| switch (target) {
            .generic => |nt| return if (nt.id == self.ctx.simd_sym_id) self.simdConvert(try self.typeInstance(callee, nt), args, self.startOf(callee)) else self.constructInstance(node, callee, nt, args),
            .function => {
                ct = callee;
                callee = ir.get(callee, .object);
            },
            .value_member => return self.synthMemberCall(ir.get(callee, .object), args, callee),
            .not_generic, .reported => {
                try self.notGeneric(callee, target);
                return self.skipCall(args);
            },
        };

        if (callee == .src) {
            const name = self.text(callee);
            if (self.lookupQuiet(callee) == null) {
                if (std.mem.eql(u8, name, "print")) return self.checkPrint(args);
                if (std.mem.eql(u8, name, "String")) return self.checkStringNew(node, args);
                if (std.mem.eql(u8, name, "replace")) return self.checkReplace(callee, args);
                if (std.mem.eql(u8, name, "swap")) return self.checkSwap(callee, args);
                if (resolve.isNumericTypeName(name)) {
                    var r = self.resolver();
                    return self.checkConversion(try r.resolveType(callee), name, args, callee.src.pos);
                }
            }
            const sym_id = (try self.useName(callee)) orelse return self.skipCall(args);
            const sym = self.ctx.symbols.items[sym_id];
            if (sym.kind != .nominal_type and sym.kind != .generic_type and sym.kind != .type_alias and sym.kind != .module) {
                try self.ctx.recordType(callee, sym.ty);
            }
            switch (sym.kind) {
                .function, .@"extern" => return self.functionCall(callee, sym, ct, args),
                .nominal_type => return self.construct(sym_id, args, callee.src.pos, TypeSubst.empty, null),
                .type_alias => return self.aliasCall(node, callee, name, sym.ty, args, callee.src.pos),
                .generic_type => {
                    if (sym_id == self.ctx.list_sym_id) return self.badCall(args, callee, "`List()` needs its element type: name it (`List[T]()`), or give it where the value goes (`v: List[T] = List()`)", .{});
                    if (sym_id == self.ctx.simd_sym_id) return self.badCall(args, callee, "a vector names its lane type and count: `Simd[U8, 16](array)`, or `Simd[U8, 16].splat(x)`", .{});
                    if (sym_id == self.ctx.signal_sym_id and !sameNode(node, self.shared_operand)) return self.badCall(args, callee, stack_signal, .{});
                    return self.constructGeneric(callee, sym_id, args, name, callee.src.pos);
                },
                .module => return self.badCall(args, callee, "module `{s}` cannot be called", .{name}),
                .generic_param => return self.badCall(args, callee, "`{s}` is a type parameter; it cannot be called or constructed", .{name}),
                else => return self.callValue(callee, sym.ty, args, name),
            }
        }

        if (callee.isKind(.member)) return self.synthMemberCall(callee, args, ct);

        if (callee.isKind(.enum_lit)) return self.badCall(args, callee, "variant `.{s}(...)` needs a known enum type; annotate the binding", .{self.text(ir.EnumLit.name(callee))});

        const callee_ty = try self.synthOperand(callee);
        return self.callValue(callee, callee_ty, args, self.sourceText(callee));
    }

    /// A call through an alias of type `ty` (in this module's terms),
    /// named `name`: it constructs the struct the alias names, or
    /// converts to the number type it names.
    fn aliasCall(self: *Checker, call: Sexp, callee: Sexp, name: []const u8, ty: TypeId, args: []const Sexp, pos: u32) Error!TypeId {
        if (self.isPoison(ty)) return self.skipCall(args);
        if (sema.isNumeric(self.ctx, ty)) return self.checkConversion(ty, name, args, pos);
        if (self.ctx.types.get(ty) == .simd) {
            if (callee == .src) if (self.lookupQuiet(callee)) |id| try self.ctx.recordName(callee, id);
            return self.simdConvert(ty, args, pos);
        }
        if (ty == self.t().string_id) return self.checkStringNew(call, args);
        if (sema.boxedType(self.ctx, ty) != null) return self.badCall(args, callee, "`{s}` is a type alias for `{s}`; a box is made with `^`: write `^value`", .{ name, try self.tyName(ty) });
        const nt = self.aliasNamedType(ty) orelse return self.badCall(args, callee, "`{s}` is a type alias for `{s}`, which has no constructor", .{ name, try self.tyName(ty) });
        if (nt.foreign) |fo| return self.construct(nt.id, args, pos, TypeSubst.empty, fo);
        if (nt.args) |targs| {
            if (nt.id == self.ctx.list_sym_id) {
                try self.checkListConstruction(call);
                return ty;
            }
            if (nt.id == self.ctx.signal_sym_id and !sameNode(call, self.shared_operand)) return self.badCall(args, callee, stack_signal, .{});
            return self.construct(nt.id, args, pos, .{ .params = nt.sym.type_params orelse &.{}, .args = targs }, null);
        }
        if (callee == .src) try self.ctx.recordName(callee, nt.id);
        return self.construct(nt.id, args, pos, TypeSubst.empty, null);
    }

    /// `Wrap(v: 3)`, `lib.Wrap(v: 3)`: generic type `sym_id`, named `name`
    /// by `callee`, constructed at the type arguments its fields' values
    /// and the type expected of it give.
    fn constructGeneric(self: *Checker, callee: Sexp, sym_id: SymbolId, args: []const Sexp, name: []const u8, pos: u32) Error!TypeId {
        if (args.len > 0 and self.isTypeName(args[0])) {
            try self.errAt(callee, "type arguments go in brackets: `{s}[{s}](...)`", .{ name, self.text(args[0]) });
            return self.t().invalid_id;
        }
        const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
        // Fields are set by name, but for one field given positionally.
        if (!(args.len == 1 and soleField(fields) != null)) for (args) |a| if (!a.isKind(.kwarg)) {
            try self.positionalFieldsError(fields, name, pos);
            return self.skipCall(args);
        };
        const subst = (try self.inferTypeArgs(sym_id, args, .{ .fields = fields }, pos, self.expectedResult((try sema.makeNominalContext(self.ctx, sym_id)).self_type), null)) orelse return self.skipCall(args);
        _ = try self.instantiate(sym_id, subst.args, pos);
        return self.construct(sym_id, args, pos, subst, null);
    }

    /// Call function `sym`, named by `callee`, with the compile-time
    /// arguments in bracket list `ct` (null for none).
    fn functionCall(self: *Checker, callee: Sexp, sym: sema.Symbol, ct: ?Sexp, args: []const Sexp) Error!TypeId {
        const name = self.text(callee);
        if (self.isEntryPoint(sym)) return self.badCall(args, callee, entry_point_use, .{});
        if (self.isPoison(sym.ty)) return self.skipCall(args);
        const fty = self.ctx.types.get(sym.ty);
        if (fty != .function) return self.badCall(args, callee, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(sym.ty) });
        if (sym.kind == .@"extern" and self.raw_depth == 0) {
            try self.errAt(callee, "call to extern function `{s}` requires `raw` block; extern functions are the FFI boundary and bypass Rig's ownership and effect checks", .{name});
        }
        const info = paramsOf(sym, self.ctx.source);
        const f = (try self.instantiateCall(fty.function, ct, args, info, 0, name, callee.src.pos, false, .empty)) orelse return self.skipCall(args);
        if (sym.kind == .function) try self.noteTarget(self.ctx.module_id, sym.decl_pos, sym.flags.inline_marked, .empty);
        // A generic function's callee has the instance's signature.
        if (fty.function.ct_params.len > 0) try self.ctx.recordType(callee, try self.ctx.internCopy(.{ .function = f }));
        self.lend_call = true;
        try self.checkArgs(args, f, info, name, callee.src.pos, .{ .origins = sym.origins, .declared = fty.function.params });
        return f.returns;
    }

    /// Call a value: a function-typed binding, a closure, or an owned
    /// closure handle.
    fn callValue(self: *Checker, callee: Sexp, ty: TypeId, args: []const Sexp, name: []const u8) Error!TypeId {
        const pos = self.startOf(callee);
        if (self.isPoison(ty)) return self.skipCall(args);
        const f = sema.calledFn(self.ctx, ty) orelse
            return self.badCall(args, pos, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(ty) });
        var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer scratch.deinit();
        try self.checkArgs(args, f, .{}, name, pos, .{ .origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f) });
        return f.returns;
    }

    /// A call that cannot be checked: its arguments are still checked on
    /// their own, and it has no type.
    fn skipCall(self: *Checker, args: []const Sexp) Error!TypeId {
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    /// Report why a call cannot be checked, at `at` (a node or a
    /// position), then `skipCall`.
    fn badCall(self: *Checker, args: []const Sexp, at: anytype, comptime fmt: []const u8, fmt_args: anytype) Error!TypeId {
        if (@TypeOf(at) == Sexp) try self.errAt(at, fmt, fmt_args) else try self.err(at, fmt, fmt_args);
        return self.skipCall(args);
    }

    /// The arguments of a call that cannot be checked: each is checked
    /// on its own, and nothing that needs a parameter's type (`[]` has
    /// none, and whether a slice is lent depends on it) is reported.
    fn synthArgs(self: *Checker, args: []const Sexp) Error!void {
        const saved = self.under_poison;
        const saved_view = self.view_arg;
        defer {
            self.under_poison = saved;
            self.view_arg = saved_view;
        }
        self.under_poison = true;
        for (args) |a| {
            const e = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
            if (e.isKind(.array) and ir.Array.elems(e).len == 0) continue;
            self.view_arg = e;
            _ = try self.synthExpr(e);
        }
    }

    /// `I32(x)`, `U8(x)`, `Float(n)`, `Int(f)`: a numeric conversion to
    /// the named type. A conversion to an integer type is checked: a
    /// value that does not fit panics when the program runs, and a float
    /// is truncated toward zero; a constant argument is converted now,
    /// so it must fit. A conversion to a float type rounds to the nearest
    /// value, a constant argument included.
    fn checkConversion(self: *Checker, target: TypeId, name: []const u8, args: []const Sexp, pos: u32) Error!TypeId {
        if (args.len != 1 or args[0].isKind(.kwarg)) {
            try self.err(pos, "`{s}(x)` converts one number; it takes exactly one argument", .{name});
            try self.synthArgs(args);
            return target;
        }
        const arg = args[0];
        const from = try self.synthValue(arg);
        if (self.isPoison(from)) return target;
        if (self.enumValues(from)) |values| {
            const shown = try self.plainText(arg);
            const bare = sema.unwrapViews(self.ctx, from);
            if (self.isBuiltinEnumTy(bare)) {
                try self.errAt(arg, "`{s}(x)` takes a declared enum's value; the built-in enum `{s}` has no integer value", .{ name, try self.tyName(bare) });
            } else if (!values) {
                try self.errAt(arg, "`{s}(x)` takes a plain enum's value; `{s}` has variants with payloads, which have no integer value", .{ name, try self.tyName(bare) });
            } else if (self.ctx.types.get(target) != .int) {
                try self.errAt(arg, "`{s}(x)` converts an enum's value to an integer type only; write `{s}(Int(...))`", .{ name, name });
            } else if (try self.variantValue(arg)) |v| if (!holdsInt(self.ctx, target, v)) {
                try self.errAt(arg, "`{s}` has the value {d}, which does not fit in `{s}`", .{ shown, v, try self.tyName(target) });
            };
            return target;
        }
        if (!sema.isNumeric(self.ctx, from)) {
            try self.errAt(arg, "`{s}(x)` converts a number; `x` has type `{s}`", .{ name, try self.tyName(from) });
        } else if (self.ctx.types.get(target) == .int) {
            // A literal takes the target type; a typed argument keeps its
            // own, and only its value, when constant, must fit.
            if (!sema.isInteger(self.ctx, from)) {
                try self.checkFloatFits(arg, target);
            } else if (from == self.t().int_literal_id or sema.constInt(self.ctx, arg) != .not_constant) try self.checkLiteralFits(arg, target);
        }
        return target;
    }

    fn enumValues(self: *Checker, ty: TypeId) ?bool {
        return sema.enumValues(self.ctx, ty);
    }

    /// Whether `ty` is a plain enum, every variant without a payload: one
    /// whose values are integers (`enumValues`), or a built-in one,
    /// `Endian` or `Arch`, whose values are Zig's. Each has `e.text` and
    /// `E.from_text(word)`.
    fn hasVariantNames(self: *Checker, ty: TypeId) bool {
        if (self.enumValues(ty) == true) return true;
        const decl = sema.nominalDecl(self.ctx, sema.unwrapViews(self.ctx, ty)) orelse return false;
        return sema.isBuiltinEnum(decl.ctx, decl.sym);
    }

    /// Whether `ty`, read through views, is a built-in enum, `Endian` or
    /// `Arch`: no payloads, but variants that are Zig's, with no integer
    /// Rig fixes.
    fn isBuiltinEnumTy(self: *Checker, ty: TypeId) bool {
        const decl = sema.nominalDecl(self.ctx, sema.unwrapViews(self.ctx, ty)) orelse return false;
        return sema.isBuiltinEnum(decl.ctx, decl.sym);
    }

    /// The value of a variant named through its type, `Status.ok` or
    /// `lib.Status.ok`; null for any other expression.
    fn variantValue(self: *Checker, e: Sexp) Error!?Wide {
        if (!e.isKind(.member)) return null;
        const nt = (try self.namedType(ir.Member.object(e))) orelse return null;
        const name = self.text(ir.Member.name(e));
        const fields = nt.sym.fields orelse return null;
        return fields[(try sema.findMember(self.ctx, fields, name, .variant)) orelse return null].value;
    }

    /// A constant float converted to integer type `target`: its integer
    /// part must fit.
    fn checkFloatFits(self: *Checker, arg: Sexp, target: TypeId) Error!void {
        const f = constFloatOf(self.ctx.source, arg) orelse return;
        const b = intBounds(self.ctx.types.get(target).int);
        const whole = @trunc(f);
        if (whole >= wideToFloat(f64, b.min) and whole < wideToFloat(f64, b.max) + 1) return;
        if (@abs(f) < 1e18) {
            try self.errAt(arg, "`{d}` does not fit in `{s}`", .{ f, try self.tyName(target) });
        } else try self.errAt(arg, "`{e}` does not fit in `{s}`", .{ f, try self.tyName(target) });
    }

    /// `replace(!place, v)`: store `v` in the place and hand back what
    /// was there, owned.
    fn checkReplace(self: *Checker, callee: Sexp, args: []const Sexp) Error!TypeId {
        if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) return self.badCall(args, callee, "`replace` takes a place lent to write and the value to put there: `replace(!x, v)`", .{});
        const ty = (try self.swapPlace(args[0], "replace")) orelse return self.skipCall(args[1..]);
        try self.checkExpr(args[1], ty);
        return ty;
    }

    /// `swap(!a, !b)`: exchange the values of two places of one type.
    fn checkSwap(self: *Checker, callee: Sexp, args: []const Sexp) Error!TypeId {
        if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) return self.badCall(args, callee, "`swap` takes two places lent to write: `swap(!a, !b)`", .{});
        const a = (try self.swapPlace(args[0], "swap")) orelse return self.skipCall(args[1..]);
        const b = (try self.swapPlace(args[1], "swap")) orelse return self.t().void_id;
        if (a != b) try self.errAt(args[1], "`swap` exchanges two places of one type; got `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
        return self.t().void_id;
    }

    /// The type of the place a `replace` or `swap` argument lends to write
    /// (`!x`, or a held `!T`), which holds no view; null after a
    /// diagnostic.
    fn swapPlace(self: *Checker, arg: Sexp, what: []const u8) Error!?TypeId {
        const ty = try self.synthExpr(arg);
        if (self.isPoison(ty)) return null;
        const place = switch (self.ctx.types.get(ty)) {
            .write_view => |inner| if (sema.writeSliceElem(self.ctx, ty) == null) inner else null,
            else => null,
        } orelse {
            try self.errAt(arg, "`{s}` takes a place lent to write: `!x`; got `{s}`", .{ what, try self.tyName(ty) });
            return null;
        };
        if (sema.holdsMarkedView(self.ctx, place)) {
            try self.errAt(arg, "`{s}` moves values that hold no `?T`, `!T`, or slice; `{s}` may hold one", .{ what, try self.tyName(place) });
            return null;
        }
        // A value that holds a Cell lives only behind a shared handle, whose
        // plain data handles only read: exchanging it as a whole would write
        // that data. (A Cell itself is exchanged by a marked call.)
        if (sema.holdsCellByValue(self.ctx, place) and !sema.isCell(self.ctx, place)) {
            try self.errAt(arg, "`{s}` moves values whole, and `{s}` holds a Cell, so it lives only behind a shared handle, whose other fields only read", .{ what, try self.tyName(place) });
            return null;
        }
        // A Signal changes only by its marked calls: exchanged whole, its
        // subscribers would move with it, while `set` may be running them.
        const signal = switch (self.ctx.types.get(place)) {
            .parameterized_nominal => |pn| pn.sym == self.ctx.signal_sym_id,
            else => false,
        };
        if (signal) {
            try self.errAt(arg, "`{s}` moves values whole, and a `{s}` changes only by its marked calls (`!s.set(v)`), which may be running its subscribers", .{ what, try self.tyName(place) });
            return null;
        }
        if (!arg.isKind(.write)) try self.checkLendsVisibly(arg, ty, "the call writes through");
        return place;
    }

    /// `print(a, b, ...)`: any number of values, printed on one line.
    fn checkPrint(self: *Checker, args: []const Sexp) Error!TypeId {
        try self.checkFormatArgs(args, "`print`", "print");
        return self.t().void_id;
    }

    /// The values `print`, `String(...)`, and `!t.add(...)` (`who`) write
    /// as text, each as `print` writes it: any value but a `Void`, a
    /// bare `none`, or one holding a `[]U8`, positionally. They are only
    /// read, and kept by nothing, so a viewed temporary lives long
    /// enough.
    fn checkFormatArgs(self: *Checker, args: []const Sexp, who: []const u8, verb: []const u8) Error!void {
        for (args) |a| {
            if (a.isKind(.kwarg)) {
                try self.errAt(a, "{s} takes no keyword arguments", .{who});
                _ = try self.synthQuiet(ir.Kwarg.value(a));
                continue;
            }
            // The values are only read, so a slice is lent the way a read
            // parameter's argument is: `print(w[1..3])`.
            const saved_view = self.view_arg;
            defer self.view_arg = saved_view;
            self.view_arg = a;
            const ty = try self.synthReadTemp(a);
            if (!self.isPoison(ty) and self.slicedArg(a)) if (sliceArgLend(self.ctx, ty, ty)) |lend| {
                var implicit = lend;
                implicit.implicit = true;
                try self.ctx.recordImplicitLend(a);
                try self.ctx.recordLend(a, implicit);
            };
            if (try self.writeLendRead(a, ty, .{ .value = sema.unwrapViews(self.ctx, ty) })) continue;
            // An integer literal is written as an `Int`, which must hold it.
            if (ty == self.t().int_literal_id) try self.defaultIntLiteral(a);
            switch (self.ctx.types.get(ty)) {
                .void => try self.errAt(a, "{s} needs a value; this expression produces no value (`Void`)", .{who}),
                .none_literal => try self.errAt(a, "cannot {s} a bare `none`", .{verb}),
                else => {
                    if (try holdsByteSlice(self.ctx, ty, self.ctx.allocator)) {
                        const name = try self.tyName(ty);
                        const direct = std.mem.eql(u8, name, "[]U8");
                        try self.errAt(a, "cannot {s} a `{s}`: {s}would {s} as text, like a `?String`; {s} the bytes one by one", .{ verb, name, if (direct) "it " else "the `[]U8` it holds ", verb, verb });
                    }
                },
            }
        }
    }

    /// `String(a, b, ...)`: a new String holding each value as `print` writes
    /// it, with no separators; `String()` is empty.
    fn checkStringNew(self: *Checker, call: Sexp, args: []const Sexp) Error!TypeId {
        try self.checkFormatArgs(args, "`String(...)`", "write");
        try self.ctx.recordStringCall(call, .new);
        return self.t().string_id;
    }

    /// `!t.add(a, b, ...)`, which appends each value as `print` writes
    /// it, and `!t.clear()`, on a String receiver written `!t`, recorded
    /// on the callee. Null when the receiver is no String or the method
    /// none of these.
    fn stringCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        // A box lends the String it holds.
        var held = sema.unwrapViews(self.ctx, obj_ty);
        while (sema.boxedType(self.ctx, held)) |inner| held = sema.unwrapViews(self.ctx, inner);
        if (held != self.t().string_id) return null;
        const op = std.meta.stringToEnum(sema.StringCall, method) orelse return null;
        if (op == .new or op == .push_int or op == .push_keep) return null;
        // Only `push` takes compile-time arguments: `push[T, e](v)`.
        if (ct != null and op != .push) return try self.badCall(args, ct.?, "`{s}` takes no compile-time arguments", .{method});
        const recv = try self.ctx.intern(.{ .write_view = self.t().string_id });
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{recv}), .returns = self.t().void_id, .is_sub = true });
        if (!try self.checkReceiverSigil(obj, .write, self.t().void_id, method)) {
            const kind: ReceiverTypeKind = switch (self.ctx.types.get(obj_ty)) {
                .read_view => .read_view,
                .write_view => .write_view,
                else => .owned_nominal,
            };
            // (A String made here with no `!` is reported as such.)
            const saved_of = self.receiver_of;
            defer self.receiver_of = saved_of;
            self.receiver_of = callee;
            try self.checkReceiverMode(obj, .write, kind, method, pos, self.t().void_id);
            if (self.hands(obj).kind != .made) try self.rejectResourceTemporary(obj, obj_ty);
        }
        switch (op) {
            .add => try self.checkFormatArgs(args, "`add`", "write"),
            // One byte, as a List's `push` takes one element.
            .push_int, .push_keep => unreachable,
            // `push[T, e](v)`: the bytes of an integer; `push(v, keep:
            // k)` the first `k` bytes of a vector.
            .push => if (ct) |b| {
                const wide = try self.pushWide(callee, b, pos, args);
                if (wide) return try self.finishStringCall(callee, if (self.pushKeepOf(args) != null) .push_keep else .push_int);
            } else if (self.pushKeepOf(args) != null) {
                if (try self.pushVector(callee, pos, args)) return try self.finishStringCall(callee, .push_keep);
            } else if (args.len == 1 and args[0].isKind(.kwarg)) {
                try self.errAt(args[0], "`push` takes its byte by position, not by name: `!t.push({s})`", .{self.sourceText(ir.Kwarg.value(args[0]))});
                try self.synthArgs(args);
            } else if (args.len != 1) {
                try self.err(pos, "`push` takes one byte, a `U8`; got {d} arguments", .{args.len});
                try self.synthArgs(args);
            } else try self.checkExpr(args[0], try self.byteType()),
            // Room for `n` more bytes.
            .reserve => if (args.len == 1 and args[0].isKind(.kwarg)) {
                try self.errAt(args[0], "`reserve` takes its count by position, not by name: `!t.reserve({s})`", .{self.sourceText(ir.Kwarg.value(args[0]))});
                try self.synthArgs(args);
            } else if (args.len != 1) {
                try self.err(pos, "`reserve` takes one argument, the number of bytes to make room for; got {d} arguments", .{args.len});
                try self.synthArgs(args);
            } else try self.checkExpr(args[0], self.t().int_id),
            else => if (args.len > 0) {
                try self.err(pos, "`clear` takes no arguments; got {d}", .{args.len});
                try self.synthArgs(args);
            },
        }
        return try self.finishStringCall(callee, op);
    }

    fn finishStringCall(self: *Checker, callee: Sexp, op: sema.StringCall) Error!TypeId {
        try self.ctx.recordStringCall(callee, op);
        return self.t().void_id;
    }

    /// `!t.push[T, e](v)`: the integer `v`, a `T`, appended as `@size(T)`
    /// bytes in byte order `e`, a compile-time `Endian`; a one-byte `T`
    /// takes no byte order. True when it checked, with the call's `T`
    /// recorded; after a diagnostic, false.
    fn pushWide(self: *Checker, callee: Sexp, b: Sexp, pos: u32, args: []const Sexp) Error!bool {
        const example = "push[U32, .little](value)";
        try self.ctx.recordInstance(b, .function);
        const given = sema.bracketArgs(b);
        if (given.len < 1 or given.len > 2) {
            _ = try self.badCall(args, b, "`push` takes the integer type and, for more than one byte, the byte order in brackets: `{s}`", .{example});
            return false;
        }
        const num = try self.typeArg(given[0]);
        if (self.isPoison(num)) {
            _ = try self.skipCall(args);
            return false;
        }
        var one_byte = false;
        switch (self.ctx.types.get(num)) {
            .int => |info| one_byte = intBounds(info).bits == 8,
            // A type parameter: each instance must be an integer.
            .type_var => |param| try self.require(param, .integer, self.startOf(given[0]), "push"),
            else => {
                _ = try self.badCall(args, given[0], "`push` appends an integer type; got `{s}`", .{try self.tyName(num)});
                return false;
            },
        }
        if (given.len == 2) {
            if (one_byte) {
                _ = try self.badCall(args, given[1], "`push` of a one-byte `{s}` takes no byte order: `push[{s}](byte)`", .{ try self.tyName(num), try self.tyName(num) });
                return false;
            }
            const endian = try self.ctx.intern(.{ .nominal = self.ctx.endian_sym_id });
            try self.checkCtValue(given[1], endian, 1, "push");
        } else if (!one_byte) {
            _ = try self.badCall(args, b, "`push` of a `{s}` takes a byte order too: `{s}`", .{ try self.tyName(num), example });
            return false;
        }
        const keep = self.pushKeepOf(args);
        for (args, 0..) |a, i| if (a.isKind(.kwarg) and !(keep != null and i == args.len - 1)) {
            _ = try self.badCall(args, a, "`push` takes no keyword argument but `keep:`, last: `push[U64, .little](word, keep: k)`", .{});
            return false;
        };
        const given_args = args.len - @intFromBool(keep != null);
        if (given_args != 1) {
            _ = try self.badCall(args, pos, "`push` takes one argument, the integer to append; got {d} arguments", .{given_args});
            return false;
        }
        try self.checkExpr(args[0], num);
        if (keep) |k| try self.checkKeep(ir.Kwarg.value(k), switch (self.ctx.types.get(num)) {
            .int => |info| intBounds(info).bits / 8,
            else => null,
        });
        try self.ctx.recordStringNum(callee, num);
        return true;
    }

    /// The `keep: k` argument of a `push`: the last argument, a keyword
    /// argument named `keep`; else null.
    fn pushKeepOf(self: *Checker, args: []const Sexp) ?Sexp {
        if (args.len == 0) return null;
        const last = args[args.len - 1];
        if (!last.isKind(.kwarg)) return null;
        const name = ir.Kwarg.name(last);
        if (!std.mem.eql(u8, self.text(name), "keep")) return null;
        return last;
    }

    /// `keep: k`: an `Int`, which must be `0..=size` where `size`, the
    /// bytes of the value pushed, is known and `k` is a constant;
    /// otherwise the push panics.
    fn checkKeep(self: *Checker, k: Sexp, size: ?u64) Error!void {
        try self.checkExpr(k, self.t().int_id);
        const v = self.constInt(k) orelse return;
        if (v < 0) {
            try self.errAt(k, "`keep: {d}` is negative; `push` keeps 0 up to the size of the value", .{v});
        } else if (size) |n| if (v > n) {
            try self.errAt(k, "`keep: {d}` is more than the {d} bytes pushed", .{ v, n });
        };
    }

    /// `!t.push(v, keep: k)`: the first `k` bytes of the vector `v`, a
    /// `Simd[U8, n]`. True when it checked, with the vector's type
    /// recorded; after a diagnostic, false.
    fn pushVector(self: *Checker, callee: Sexp, pos: u32, args: []const Sexp) Error!bool {
        const keep = self.pushKeepOf(args).?;
        for (args, 0..) |a, i| if (a.isKind(.kwarg) and i != args.len - 1) {
            _ = try self.badCall(args, a, "`push` takes no keyword argument but `keep:`, last: `push(block, keep: k)`", .{});
            return false;
        };
        if (args.len != 2) {
            _ = try self.badCall(args, pos, "`push(v, keep: k)` takes one value and `keep:`; got {d} arguments", .{args.len - 1});
            return false;
        }
        const ty = try self.synthExpr(args[0]);
        if (self.isPoison(ty)) {
            try self.synthArgs(args[1..]);
            return false;
        }
        const vec = sema.unwrapViews(self.ctx, ty);
        const simd = sema.simdOf(self.ctx, vec);
        const bytes = if (simd) |v| switch (self.ctx.types.get(v.elem)) {
            .int => |info| if (intBounds(info).bits == 8 and !info.signed) sema.simdLen(self.ctx, v) else null,
            else => null,
        } else null;
        if (bytes == null) {
            _ = try self.badCall(args, args[0], "`push` with `keep:` takes a vector of bytes, a `Simd[U8, n]`, or an integer with its byte order, `push[U64, .little](word, keep: k)`; got `{s}`", .{try self.tyName(ty)});
            return false;
        }
        try self.checkKeep(ir.Kwarg.value(keep), bytes.?);
        try self.ctx.recordStringNum(callee, vec);
        return true;
    }

    /// The methods of an integer's bits, all on its bit pattern, so a
    /// negative value counts as its two's complement: `x.not()`, the
    /// complement (every bit flipped), also of a `Bool`; `x.swap_bytes()`,
    /// the bytes reversed; both in the receiver's own type. And
    /// `x.leading_zeros()`, `x.trailing_zeros()`, and `x.count_ones()`,
    /// an `Int` (a zero has as many of each zero count as it has bits).
    /// Null when `method` is none of them or the receiver is not an
    /// integer.
    fn bitCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        if (!op.isBits()) return null;
        const value = sema.unwrapViews(self.ctx, obj_ty);
        if (op == .to_bits) return self.toBitsCall(callee, obj, value, method, pos, args);
        if (op == .fraction or op == .exponent) return self.frexpCall(callee, obj, value, op, method, pos, args);
        // `v.not()` of a vector: lane by lane, of integer or `Bool` lanes.
        // A mask's bits are counted as `bits()`'s.
        const lane = if (sema.simdOf(self.ctx, value)) |v| (if (op == .not) v.elem else {
            if (v.elem != self.t().bool_id or op == .swap_bytes) return null;
            const recv = try self.receiverText(obj);
            return try self.badCall(args, pos, "`{s}` counts an integer's bits, and `{s}` is a mask, `{s}`: count the bits `bits()` gives, `{s}.bits().{s}()`", .{ method, try self.plainText(obj), try self.tyName(value), recv, method });
        }) else value;
        const is_bool = lane == self.t().bool_id;
        if (!(is_bool and op == .not) and !sema.isInteger(self.ctx, lane)) return null;
        if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "does not consume its receiver");
        if (value == self.t().int_literal_id) try self.defaultIntLiteral(obj);
        const ty = if (value == self.t().int_literal_id) self.t().int_id else value;
        const result = switch (op) {
            .leading_zeros, .trailing_zeros, .count_ones => self.t().int_id,
            else => ty,
        };
        if (args.len > 0) {
            try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
            try self.synthArgs(args);
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{ty}), .returns = result, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = result, .num = ty });
        return result;
    }

    /// `f.to_bits()`: the IEEE bits of a float as the unsigned integer of
    /// its width. Null when the receiver is not a float.
    fn toBitsCall(self: *Checker, callee: Sexp, obj: Sexp, value: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
        const info = switch (self.ctx.types.get(value)) {
            .float => |f| f,
            else => return null,
        };
        if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "does not consume its receiver");
        const result = try self.bitsType(info);
        if (args.len > 0) {
            try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
            try self.synthArgs(args);
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{value}), .returns = result, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .to_bits, .elem = result, .num = value });
        return result;
    }

    /// `x.hash()`: a `U64` of the value `x` reaches, on exactly the
    /// types `==` compares, less a float and what holds one
    /// (`sema.notHashable`). Values `==` calls equal hash equal: text by
    /// its bytes whatever its type, an optional holding a value as that
    /// value. It reads `x` where it is, as `==` reads an operand; in a
    /// generic body, each parameter the value holds records `hashable`,
    /// checked at every instance.
    fn hashCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!TypeId {
        const u64_ty = try self.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } });
        if (self.isReceiverSigil(obj) and !obj.isKind(.read)) try self.misplacedSigil(obj, "hash", "only reads its receiver");
        var value = sema.unwrapViews(self.ctx, obj_ty);
        if (value == self.t().int_literal_id) {
            try self.defaultIntLiteral(obj);
            value = self.t().int_id;
        }
        if (args.len > 0) {
            try self.err(pos, "`hash` takes no arguments; got {d}", .{args.len});
            try self.synthArgs(args);
        }
        if (!isText(self.ctx, value)) {
            var params: std.ArrayList(SymbolId) = .empty;
            defer params.deinit(self.ctx.allocator);
            if (try sema.notHashable(self.ctx, value, &params)) |n| {
                try self.errAt(obj, "`.hash()` does not take a `{s}`: {s}", .{ try self.tyName(value), try notEquatableReason(self.ctx, n) });
                return u64_ty;
            }
            for (params.items) |tv| try self.require(tv, .hashable, self.startOf(obj), ".hash()");
        }
        if (!self.hands(obj).hasStorage()) try self.readLeaf(obj) else try self.rejectResourceTemporary(obj, obj_ty);
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .read_view = value })}), .returns = u64_ty, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .hash, .elem = u64_ty, .num = value });
        return self.noteMethod(callee, .read, u64_ty);
    }

    /// Whether `obj_ty` has a data field `name`, here or in the module
    /// that declares it.
    fn hasDataField(self: *Checker, obj_ty: TypeId, name: []const u8) Error!bool {
        if (try sema.lookupDataField(self.ctx, obj_ty, name)) |_| return true;
        const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return false;
        return (try findDataField(self.ctx, decl.symbol().fields orelse &.{}, name)) != null;
    }

    /// `f.fraction()` and `f.exponent()`, the two halves of what C,
    /// Python, and Go call `frexp`: the fraction, a float of the
    /// receiver's type, and the exponent, an `Int`. Null when the
    /// receiver is not a float.
    fn frexpCall(self: *Checker, callee: Sexp, obj: Sexp, value: TypeId, op: sema.ElemOp, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
        if (self.ctx.types.get(value) != .float) return null;
        if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "does not consume its receiver");
        const result = if (op == .fraction) value else self.t().int_id;
        if (args.len > 0) {
            try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
            try self.synthArgs(args);
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{value}), .returns = result, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = result, .num = value });
        return result;
    }

    /// The unsigned integer type as wide as a float of `info`.
    fn bitsType(self: *Checker, info: sema.FloatInfo) Error!TypeId {
        return self.ctx.intern(.{ .int = .{ .bits = if (info.bits == 32) 32 else 64, .signed = false } });
    }

    /// The functions of a number type: `Float.from_bits(u)`, the float
    /// whose IEEE bits are the unsigned integer `u`, and `I32.wrap(x)`, an
    /// integer converted to an integer type by keeping its low bits.
    fn numberTypeCall(self: *Checker, callee: Sexp, obj: Sexp, target: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        if (self.isPoison(target)) return self.skipCall(args);
        const shown = self.sourceText(obj);
        const tt = self.ctx.types.get(target);
        const is_wrap = std.mem.eql(u8, method, "wrap");
        const is_bits = std.mem.eql(u8, method, "from_bits");
        const special: ?sema.ElemOp = if (tt == .float and std.mem.eql(u8, method, "nan")) .nan else if (tt == .float and std.mem.eql(u8, method, "inf")) .inf else null;
        if (special) |op| {
            if (ct) |b| return self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});
            if (args.len != 0) return self.badCall(args, pos, "`{s}.{s}()` takes no arguments; got {d}", .{ shown, method, args.len });
            try self.noteCallee(.{ .params = &.{}, .returns = target, .is_sub = false });
            try self.ctx.recordElemCall(callee, .{ .op = op, .elem = target, .num = target });
            return target;
        }
        if ((is_wrap and tt != .int) or (is_bits and tt != .float) or !(is_wrap or is_bits)) {
            const fns: []const u8 = if (tt == .int) "`wrap`" else "`from_bits`, `nan`, and `inf`";
            return self.badCall(args, pos, "`{s}` has no function `{s}`; its function is {s}, and its limits are `{s}.min` and `{s}.max`", .{ shown, method, fns, shown, shown });
        }
        if (ct) |b| return self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});
        if (args.len != 1 or args[0].isKind(.kwarg)) return self.badCall(args, pos, "`{s}.{s}(x)` takes one argument; got {d}", .{ shown, method, args.len });
        const arg = args[0];
        if (is_bits) {
            const u = try self.bitsType(tt.float);
            try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{u}), .returns = target, .is_sub = false });
            try self.ctx.recordElemCall(callee, .{ .op = .from_bits, .elem = u, .num = target });
            try self.checkExpr(arg, u);
            return target;
        }
        var from = try self.synthValue(arg);
        if (self.isPoison(from)) return target;
        if (!sema.isInteger(self.ctx, from)) {
            try self.errAt(arg, "`{s}.wrap(x)` takes an integer; convert a Float with `Int(x)` first", .{shown});
            return target;
        }
        if (from == self.t().int_literal_id) {
            try self.defaultIntLiteral(arg);
            from = self.t().int_id;
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{from}), .returns = target, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .wrap, .elem = from, .num = target });
        return target;
    }

    /// `Status.from_int(n)`: the variant of plain enum `enum_ty` whose
    /// value is the integer `n`, or `none`.
    fn enumFromIntCall(self: *Checker, callee: Sexp, enum_ty: TypeId, shown: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const result = try self.ctx.intern(.{ .optional = enum_ty });
        if (ct) |b| return self.badCall(args, b, "`from_int` takes no compile-time arguments", .{});
        if (args.len != 1 or args[0].isKind(.kwarg)) return self.badCall(args, pos, "`{s}.from_int(n)` takes one argument, an integer; got {d}", .{ shown, args.len });
        const arg = args[0];
        var from = try self.synthValue(arg);
        if (self.isPoison(from)) return result;
        if (!sema.isInteger(self.ctx, from)) {
            try self.errAt(arg, "`{s}.from_int(n)` takes an integer; `n` has type `{s}`", .{ shown, try self.tyName(from) });
            return result;
        }
        if (from == self.t().int_literal_id) {
            try self.defaultIntLiteral(arg);
            from = self.t().int_id;
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{from}), .returns = result, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .from_int, .elem = from, .num = enum_ty });
        return result;
    }

    /// `Color.from_text(word)`: the variant of plain enum `enum_ty` named
    /// `word`, or `none`. `word` is passed as to a parameter `?String`.
    fn enumFromTextCall(self: *Checker, callee: Sexp, enum_ty: TypeId, shown: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const result = try self.ctx.intern(.{ .optional = enum_ty });
        if (ct) |b| return self.badCall(args, b, "`from_text` takes no compile-time arguments", .{});
        if (args.len != 1) return self.badCall(args, pos, "`{s}.from_text(word)` takes one argument, a `?String`; got {d}", .{ shown, args.len });
        if (args[0].isKind(.kwarg)) return self.badCall(args, pos, "`{s}.from_text(word)` takes its argument by position", .{shown});
        const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{self.t().string_view_id}), .returns = result, .is_sub = false };
        try self.noteCallee(f);
        var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer scratch.deinit();
        try self.checkArgs(args, f, .{}, "from_text", pos, .{ .origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f) });
        try self.ctx.recordElemCall(callee, .{ .op = .from_text, .elem = self.t().string_view_id, .num = enum_ty });
        try self.ctx.recordTextTable(sema.nominalDecl(self.ctx, enum_ty).?);
        return result;
    }

    // ---- vectors --------------------------------------------------------------

    /// What is done to a lane where a place would be.
    const LaneUse = enum { assign, lend_read, lend_write, take };

    /// `v[i]` assigned, lent, or taken: a lane of a vector is a part of
    /// its value, not a place (docs/CORE.md §1, `sema.isLane`), as an
    /// `Int`'s bits are. True when reported.
    fn rejectLane(self: *Checker, e: Sexp, use: LaneUse) Error!bool {
        if (!sema.isLane(self.ctx, e)) return false;
        const v = try self.plainText(ir.Index.object(e));
        const i = try self.plainText(ir.Index.index(e));
        switch (use) {
            .assign => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not assigned: write `{s} = {s}.with({s}, x)`", .{ v, v, v, i }),
            .lend_read => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not lent: read it as `{s}[{s}]`", .{ v, v, i }),
            .lend_write => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not lent to write: change it with `{s} = {s}.with({s}, x)`", .{ v, v, v, i }),
            .take => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not taken: read it as `{s}[{s}]`", .{ v, v, i }),
        }
        return true;
    }

    /// `e` as the receiver of a method, in parentheses unless it is a
    /// name, a field, an element, or a call: `(v == 1).any()`.
    fn receiverText(self: *Checker, e: Sexp) Error![]const u8 {
        const shown = try self.plainText(e);
        const bare = e == .src or e.isKind(.member) or e.isKind(.index) or e.isKind(.call);
        return if (bare) shown else self.ctx.arena.allocator().print("({s})", .{shown});
    }

    /// The mask a comparison of two `v`s gives: `Simd[Bool, n]`.
    fn maskOf(self: *Checker, v: sema.SimdType) Error!TypeId {
        return self.ctx.intern(.{ .simd = .{ .elem = self.t().bool_id, .len = v.len } });
    }

    /// The vector type `obj` names where a value could stand: `Simd[T, n]`
    /// (recorded as its instance), or an alias of one, also another
    /// module's (`lib.Block`); null when it names none. Poison after a
    /// diagnostic.
    fn simdNamed(self: *Checker, obj: Sexp) Error!?TypeId {
        if (rig.isBracketList(obj)) {
            const target = (try self.instTarget(ir.get(obj, .object))) orelse return null;
            if (target != .generic or target.generic.id != self.ctx.simd_sym_id) return null;
            return try self.typeInstance(obj, target.generic);
        }
        if (obj.isKind(.member)) {
            const id = (try self.moduleNamed(ir.Member.object(obj))) orelse return null;
            const found = self.foreignLookup(id, self.text(ir.Member.name(obj))) orelse return null;
            if (found.sym.kind != .type_alias or found.ctx.types.get(found.sym.ty) != .simd) return null;
            return try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
        }
        if (obj != .src) return null;
        const id = self.lookupQuiet(obj) orelse return null;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .type_alias or self.ctx.types.get(sym.ty) != .simd) return null;
        try self.ctx.recordName(obj, id);
        return sym.ty;
    }

    /// `Simd[T, n].splat(x)`: a vector of type `vt` whose every lane is
    /// `x`, a `T` or a literal that fits it. A vector type has no other
    /// function.
    fn simdTypeCall(self: *Checker, callee: Sexp, vt: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        if (self.isPoison(vt)) return self.skipCall(args);
        const v = self.ctx.types.get(vt).simd;
        if (!std.mem.eql(u8, method, "splat")) return self.badCall(args, pos, "`{s}` has no function `{s}`; a vector is made with `{s}.splat(x)`, every lane `x`, or from an array of its lanes, `{s}([...])`", .{ try self.tyName(vt), method, try self.tyName(vt), try self.tyName(vt) });
        if (ct) |b| return self.badCall(args, b, "`splat` takes no compile-time arguments", .{});
        if (args.len != 1 or args[0].isKind(.kwarg)) return self.badCall(args, pos, "`splat` takes one argument, the value of every lane; got {d}", .{args.len});
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{v.elem}), .returns = vt, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .splat, .elem = v.elem, .num = vt });
        try self.checkExpr(args[0], v.elem);
        return vt;
    }

    /// `Simd[T, n](a)`: the vector of type `vt` whose lanes are the
    /// elements of `a`, a `[n]T`.
    fn simdConvert(self: *Checker, vt: TypeId, args: []const Sexp, pos: u32) Error!TypeId {
        if (self.isPoison(vt)) return self.skipCall(args);
        const v = self.ctx.types.get(vt).simd;
        const arr = try self.ctx.intern(.{ .array = .{ .elem = v.elem, .len = v.len } });
        if (args.len != 1 or args[0].isKind(.kwarg)) {
            _ = try self.badCall(args, pos, "`{s}(a)` makes a vector of the lanes of an array `{s}`; it takes one argument", .{ try self.tyName(vt), try self.tyName(arr) });
            return vt;
        }
        try self.checkExpr(args[0], arr);
        return vt;
    }

    /// The methods of a vector (docs/SPEC.md, "Vectors"), which read the
    /// receiver as a value and make a new one: `m.bits()`, a `U64` whose
    /// bit `i` is lane `i` of mask `m`; `m.first()`, the index of its first
    /// true lane, or `none`; `m.any()` and `m.all()`;
    /// `m.select(a, b)`, lane `i` of `a` where `m`'s is true and of `b`
    /// where it is false; `v.array()`, the lanes as a `[n]T`; and
    /// `v.with(i, x)`, a copy of `v` whose lane `i` is `x`; `t.lookup(idx)`,
    /// lane `i` of table `t` at each index of `idx` (`lookupCall`); and
    /// `v.lag[k](prev)` (`lagCall`). Null when the receiver is no vector or
    /// `method` none of them.
    fn simdCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        const v = sema.simdOf(self.ctx, obj_ty) orelse return null;
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        if (!op.isSimd() or op == .splat) return null;
        const vt = sema.unwrapViews(self.ctx, obj_ty);
        const mask_op = op == .bits or op == .first or op == .any or op == .all or op == .select;
        if (mask_op and v.elem != self.t().bool_id) return try self.badCall(args, pos, "`{s}` is a method of a mask, `Simd[Bool, n]`, which a comparison gives; got `{s}`", .{ method, try self.tyName(vt) });
        if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "reads its receiver as a value");
        if (op == .lag) {
            const b = ct orelse return try self.badCall(args, pos, "`lag` takes how many lanes back in brackets: `v.lag[1](prev)`", .{});
            return try self.lagCall(callee, vt, b, pos, args);
        }
        if (ct) |b| return try self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});
        const want: usize = switch (op) {
            .select, .with => 2,
            .lookup => 1,
            else => 0,
        };
        for (args) |a| if (a.isKind(.kwarg)) return try self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        if (args.len != want) return try self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, switch (op) {
            .select => "two arguments, the lanes where the mask is true and where it is false",
            .with => "two arguments, the lane's index and its new value",
            .lookup => "one argument, a `Simd[U8, n]` of indexes into the table",
            else => "no arguments",
        }, args.len, plural(args.len) });
        if (op == .lookup) return try self.lookupCall(callee, obj, vt, args[0]);
        var elem = v.elem;
        const result: TypeId = switch (op) {
            .bits => try self.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } }),
            .first => try self.ctx.intern(.{ .optional = self.t().int_id }),
            .any, .all => self.t().bool_id,
            .array => try self.ctx.intern(.{ .array = .{ .elem = v.elem, .len = v.len } }),
            .with => vt,
            .select => blk: {
                const picked = (try self.selectOperands(args, v)) orelse return self.t().invalid_id;
                elem = self.ctx.types.get(picked).simd.elem;
                break :blk picked;
            },
            else => unreachable,
        };
        const params: []const TypeId = switch (op) {
            .with => &.{ vt, self.t().int_id, v.elem },
            .select => &.{ vt, result, result },
            else => &.{vt},
        };
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(params), .returns = result, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem, .num = vt });
        if (op == .with) {
            try self.checkIndexArg(args[0], null);
            try self.checkLaneIndex(args[0], vt);
            try self.checkExpr(args[1], v.elem);
        }
        return result;
    }

    /// `t.lookup(idx)`: a table `t` of 16, 32, or 64 `U8` lanes, and indexes
    /// `idx`, a `Simd[U8, n]`; lane `i` of the result is `t[idx[i]]`, or 0
    /// where `idx[i]` is past the table. The result's type is `idx`'s.
    fn lookupCall(self: *Checker, callee: Sexp, obj: Sexp, vt: TypeId, arg: Sexp) Error!?TypeId {
        const byte = try self.byteType();
        const v = self.ctx.types.get(vt).simd;
        const m = sema.simdLen(self.ctx, v);
        if (v.elem != byte or m == null or m.? < 16) {
            try self.errAt(obj, "`lookup` looks up bytes in a table of 16, 32, or 64 of them: a `Simd[U8, 16]`, `Simd[U8, 32]`, or `Simd[U8, 64]`; got `{s}`", .{try self.tyName(vt)});
            _ = try self.synthExpr(arg);
            return self.t().invalid_id;
        }
        const at = try self.synthOperandValue(arg);
        if (self.isPoison(at)) return self.t().invalid_id;
        const idx = sema.unwrapViews(self.ctx, at);
        const iv = sema.simdOf(self.ctx, idx);
        if (iv == null or iv.?.elem != byte) {
            try self.errAt(arg, "`lookup` takes its indexes as a `Simd[U8, n]`; got `{s}`", .{try self.tyName(at)});
            return self.t().invalid_id;
        }
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{ vt, idx }), .returns = idx, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .lookup, .elem = byte, .num = idx });
        return idx;
    }

    /// `cur.lag[k](prev)`: lane `i` is `cur[i - k]` for `i >= k`, and
    /// `prev[n - k + i]` below, for vectors `cur` and `prev` of one type.
    /// `k` is a constant integer from 1 to `n - 1`, checked now, so the
    /// lane count must be known too.
    fn lagCall(self: *Checker, callee: Sexp, vt: TypeId, b: Sexp, pos: u32, args: []const Sexp) Error!?TypeId {
        try self.ctx.recordInstance(b, .function);
        const given = sema.bracketArgs(b);
        if (given.len != 1) return try self.badCall(args, b, "`lag` takes one compile-time argument, how many lanes back: `v.lag[1](prev)`", .{});
        for (args) |a| if (a.isKind(.kwarg)) return try self.badCall(args, a, "`lag` takes no keyword arguments", .{});
        if (args.len != 1) return try self.badCall(args, pos, "`lag` takes one argument, the vector before this one; got {d} argument{s}", .{ args.len, plural(args.len) });
        const n = sema.simdLen(self.ctx, self.ctx.types.get(vt).simd);
        const mark = self.ctx.diagnostics.items.len;
        try self.checkCtValue(given[0], self.t().int_id, 0, "lag");
        if (self.ctx.diagnostics.items.len == mark) {
            const names: resolve.ConstNames = .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
            const k: ?Wide = switch (sema.constIntBy(self.ctx, given[0], names)) {
                .value => |c| c,
                else => null,
            };
            if (k == null and try self.perTarget(given[0], "the number of lanes `lag` takes")) {
                // Reported.
            } else if (k == null or n == null) {
                try self.errAt(given[0], "`lag` takes a constant number of lanes, on a vector whose lane count is known where it is checked; got `{s}` on a `{s}`", .{ self.sourceText(given[0]), try self.tyName(vt) });
            } else if (k.? < 1 or k.? >= n.?) {
                try self.errAt(given[0], "`lag` of a `{s}` takes 1 to {d} lanes; got `{d}`", .{ try self.tyName(vt), n.? - 1, k.? });
            }
        }
        try self.checkExpr(args[0], vt);
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{ vt, vt }), .returns = vt, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .lag, .elem = self.ctx.types.get(vt).simd.elem, .num = vt });
        return vt;
    }

    /// A constant lane index of a vector of type `vt` is checked against
    /// its lane count now; any other when the program runs.
    fn checkLaneIndex(self: *Checker, index: Sexp, vt: TypeId) Error!void {
        const n = sema.simdLen(self.ctx, self.ctx.types.get(vt).simd) orelse return;
        const i = self.constInt(index) orelse return;
        if (i >= 0 and i < n) return;
        try self.errAt(index, "lane `{d}` is out of range for `{s}`, whose lanes are 0 to {d}", .{ i, try self.tyName(vt), n - 1 });
    }

    /// The operands of `m.select(a, b)` for a mask of `mask`'s lanes:
    /// two vectors of one type with as many lanes, or a vector and a
    /// scalar of its lane type or a literal that fits it, or two scalars
    /// of one lane type; each scalar stands for every lane (a splat). The
    /// vector type they give, or null after a diagnostic.
    fn selectOperands(self: *Checker, args: []const Sexp, mask: sema.SimdType) Error!?TypeId {
        const a = try self.synthOperandValue(args[0]);
        const b = try self.synthOperandValue(args[1]);
        if (self.isPoison(a) or self.isPoison(b)) return null;
        const lit = [2]bool{ self.isLiteralType(a), self.isLiteralType(b) };
        if (sema.simdOf(self.ctx, a) != null and sema.simdOf(self.ctx, b) != null and a != b) {
            try self.errAt(args[0], "`select` picks lanes from two vectors of one type; got `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
            return null;
        }
        const vt: TypeId = if (sema.simdOf(self.ctx, a) != null) a else if (sema.simdOf(self.ctx, b) != null) b else blk: {
            // Two scalars: the lane type is theirs, an `Int` or a `Float`
            // for two literals.
            const lane = if (!lit[0]) a else if (!lit[1]) b else if (a == self.t().float_literal_id or b == self.t().float_literal_id) self.t().float_id else self.t().int_id;
            if (!sema.isLaneType(self.ctx, lane)) {
                try self.errAt(args[if (lit[0]) 1 else 0], "`select` picks lanes of a number or `Bool`; got `{s}`", .{try self.tyName(lane)});
                return null;
            }
            break :blk try self.ctx.intern(.{ .simd = .{ .elem = lane, .len = mask.len } });
        };
        const v = self.ctx.types.get(vt).simd;
        if (v.len != mask.len) {
            try self.errAt(args[0], "`select` on a mask of {s} lanes picks from vectors of as many lanes; got `{s}`", .{ try self.tyName(mask.len), try self.tyName(vt) });
            return null;
        }
        for (args, [2]TypeId{ a, b }) |arg, ty| {
            if (ty == vt) continue;
            if (!try self.splatOperand(arg, ty, vt, "select")) return null;
        }
        return vt;
    }

    /// Whether `ty` is an untyped literal's.
    fn isLiteralType(self: *Checker, ty: TypeId) bool {
        return ty == self.t().int_literal_id or ty == self.t().float_literal_id;
    }

    /// `operand`, of type `ty`, where a vector of type `vt` goes: a scalar
    /// of its lane type, or a literal that fits it, stands for every lane
    /// (recorded as a splat). False after a diagnostic.
    fn splatOperand(self: *Checker, operand: Sexp, ty: TypeId, vt: TypeId, op: []const u8) Error!bool {
        const v = self.ctx.types.get(vt).simd;
        if (self.isLiteralType(ty)) {
            const mark = self.ctx.diagnostics.items.len;
            try self.checkExpr(operand, v.elem);
            if (self.ctx.diagnostics.items.len != mark) return false;
        } else if (ty != v.elem) {
            const hint = if (sema.isLaneType(self.ctx, ty)) try self.ctx.arena.allocator().print("; a scalar beside a vector is of its lane type, `{s}`", .{try self.tyName(v.elem)}) else "";
            try self.errAt(operand, "operator `{s}` operands have different types `{s}` and `{s}`{s}", .{ op, try self.tyName(vt), try self.tyName(ty), hint });
            return false;
        }
        try self.ctx.recordSplat(operand, vt);
        return true;
    }

    /// A lane-wise operator `(op left right)` with a vector operand: both
    /// of one `Simd[T, n]`, or one a scalar of its lane type `T`, or a
    /// literal that fits it, which stands for every lane (`splatOperand`).
    /// `req` applies to `T` as it would to two scalars; `&`, `|`, and `^`
    /// combine masks too. `a` and `b` are the operands' value types. The
    /// vector's type, or poison after a diagnostic.
    fn simdOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, a: TypeId, b: TypeId) Error!TypeId {
        const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
        const vt = if (sema.simdOf(self.ctx, a) != null) a else b;
        const v = self.ctx.types.get(vt).simd;
        const head = e.kind().?;
        switch (head) {
            .@"/", .@"%" => {
                try self.errAt(operands[0], "operator `{s}` does not take a `Simd`: a vector has `+`, `-`, `*`, their wrapping and saturating forms, `&`, `|`, `^`, the shifts, and the comparisons", .{op});
                return self.t().invalid_id;
            },
            else => {},
        }
        const bitwise = head == .@"&" or head == .@"|" or head == .@"^";
        const lane_ok = switch (req) {
            .integer => sema.isInteger(self.ctx, v.elem) or (bitwise and v.elem == self.t().bool_id),
            .equatable => true,
            else => sema.isNumeric(self.ctx, v.elem),
        };
        if (!lane_ok) {
            if (req == .ordered) {
                try self.errAt(operands[0], "operator `{s}` orders numbers; the lanes of `{s}` are not", .{ op, try self.tyName(vt) });
            } else try self.errAt(operands[0], "operator `{s}` requires {s} operands; got `{s}`", .{ op, if (req == .integer) "integer" else "numeric", try self.tyName(vt) });
            return self.t().invalid_id;
        }
        for (operands, [2]TypeId{ a, b }) |operand, ty| {
            if (ty == vt) continue;
            if (sema.simdOf(self.ctx, ty) != null) {
                try self.errAt(operands[0], "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
                return self.t().invalid_id;
            }
            if (!try self.splatOperand(operand, ty, vt, op)) return self.t().invalid_id;
        }
        return vt;
    }

    /// `v op= x` of a vector `v` of type `vt`: the lane-wise operator, as
    /// `v = v op x` (`simdOperands`).
    fn simdCompound(self: *Checker, op: Tag, spelled: []const u8, vt: TypeId, rhs: Sexp, pos: u32) Error!void {
        const v = self.ctx.types.get(vt).simd;
        const req: Requirement = switch (op) {
            .@"+", .@"-", .@"*" => .numeric,
            .@"&", .@"|", .@"^", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>" => .integer,
            else => {
                try self.err(pos, "`{s}` does not take a `Simd`: a vector has `+=`, `-=`, `*=`, their wrapping and saturating forms, `&=`, `|=`, `^=`, and the shifts", .{spelled});
                _ = try self.synthExpr(rhs);
                return;
            },
        };
        const bitwise = op == .@"&" or op == .@"|" or op == .@"^";
        const lane_ok = if (req == .integer) sema.isInteger(self.ctx, v.elem) or (bitwise and v.elem == self.t().bool_id) else sema.isNumeric(self.ctx, v.elem);
        if (!lane_ok) {
            try self.err(pos, "`{s}` requires {s} lanes; got `{s}`", .{ spelled, if (req == .integer) "integer" else "numeric", try self.tyName(vt) });
            _ = try self.synthExpr(rhs);
            return;
        }
        if (op == .@"<<" or op == .@"<<%" or op == .@">>") {
            _ = try self.checkShiftAmount(rhs, v.elem, spelled);
            return;
        }
        const ty = try self.synthOperandValue(rhs);
        if (self.isPoison(ty) or ty == vt) return;
        if (sema.simdOf(self.ctx, ty) != null) return self.mismatch(rhs, vt, ty);
        _ = try self.splatOperand(rhs, ty, vt, spelled);
    }

    /// A mask where a `Bool` is expected: it is no `Bool`, so a condition,
    /// `and`, `or`, and `not` reject it, each with the form that reduces
    /// or combines it.
    fn maskAsBool(self: *Checker, e: Sexp, actual: TypeId) Error!void {
        const shown = try self.plainText(e);
        const recv = try self.receiverText(e);
        const ty = try self.tyName(actual);
        if (sameSite(e, self.not_operand)) return self.errAt(e, "`not` takes a Bool, and `{s}` is a mask, `{s}`: write `{s}.not()` for its lanes flipped, or reduce it with `.any()` or `.all()`", .{ shown, ty, recv });
        if (self.logic_op.len > 0 and (sameSite(e, self.logic_operands[0]) or sameSite(e, self.logic_operands[1]))) {
            const sym: []const u8 = if (std.mem.eql(u8, self.logic_op, "and")) "&" else "|";
            return self.errAt(e, "`{s}` takes Bools, and `{s}` is a mask, `{s}`: combine masks lane by lane with `{s}`, each in parentheses, or reduce each with `.any()` or `.all()`", .{ self.logic_op, shown, ty, sym });
        }
        if (sameSite(e, self.ternary_cond)) return self.errAt(e, "`{s}` is a mask, `{s}`, not a `Bool`: a ternary runs one side, so pick lanes with `{s}.select(a, b)`, or reduce the mask with `.any()` or `.all()`", .{ shown, ty, recv });
        try self.errAt(e, "`{s}` is a mask, `{s}`, not a `Bool`: write `{s}.any()` or `{s}.all()`", .{ shown, ty, recv, recv });
    }

    const ByteSliceVisit = struct { ctx: *const SemContext, sym: SymbolId };
    const ByteSliceItem = struct { ctx: *const SemContext, ty: TypeId };

    /// Whether a value of `ty` holds a `[]U8`, directly or through a
    /// wrapper, field, payload, or type argument. A `[]U8` and a `?String`
    /// are both Zig `[]const u8`, so `print` cannot tell them apart. The
    /// walk keeps a stack of its own, so a long chain of types, each
    /// holding the next, does not nest it; each declaration is walked once.
    fn holdsByteSlice(ctx: *const SemContext, ty: TypeId, a: std.mem.Allocator) Error!bool {
        var todo: std.ArrayList(ByteSliceItem) = .empty;
        defer todo.deinit(a);
        var seen: std.AutoHashMapUnmanaged(ByteSliceVisit, void) = .empty;
        defer seen.deinit(a);
        try todo.append(a, .{ .ctx = ctx, .ty = ty });
        while (todo.pop()) |item| {
            const c = item.ctx;
            switch (c.types.get(item.ty)) {
                .slice => |sl| {
                    switch (c.types.get(sl.elem)) {
                        .int => |i| if (i.bits == 8 and !i.signed) return true,
                        else => try todo.append(a, .{ .ctx = c, .ty = sl.elem }),
                    }
                    continue;
                },
                .optional, .fallible, .read_view, .write_view, .shared => |inner| {
                    try todo.append(a, .{ .ctx = c, .ty = inner });
                    continue;
                },
                .array => |arr| {
                    try todo.append(a, .{ .ctx = c, .ty = arr.elem });
                    continue;
                },
                .parameterized_nominal => |pn| for (pn.args) |arg| try todo.append(a, .{ .ctx = c, .ty = arg }),
                .nominal, .imported_nominal => {},
                else => continue,
            }
            const decl = sema.nominalDecl(c, item.ty) orelse continue;
            if ((try seen.getOrPut(a, .{ .ctx = decl.ctx, .sym = decl.sym })).found_existing) continue;
            for (decl.ctx.symbols.items[decl.sym].fields orelse &.{}) |*f| {
                for (sema.dataFields(f)) |d| try todo.append(a, .{ .ctx = decl.ctx, .ty = d.ty });
            }
        }
        return false;
    }

    /// What a call needs to know about a callee's parameters beyond its
    /// type: names for keyword arguments and default values.
    const ParamInfo = struct {
        names: ?[]const []const u8 = null,
        defaults: ?[]const ?Sexp = null,
        /// Source of the module that declares the defaults.
        source: []const u8 = "",

        fn default(self: ParamInfo, i: usize) ?Sexp {
            const d = self.defaults orelse return null;
            return if (i < d.len) d[i] else null;
        }
    };

    /// The parameters of function `sym`, declared in `source`.
    fn paramsOf(sym: sema.Symbol, source: []const u8) ParamInfo {
        return .{ .names = sym.param_names, .defaults = sym.param_defaults, .source = source };
    }

    /// The parameters of method `f`, declared in `source`, after the
    /// receiver when `skip_self`.
    fn methodParams(f: Field, skip_self: bool, source: []const u8) ParamInfo {
        const skip: usize = @intFromBool(skip_self);
        return .{
            .names = if (f.param_names) |n| n[@min(skip, n.len)..] else null,
            .defaults = if (f.param_defaults) |d| d[@min(skip, d.len)..] else null,
            .source = source,
        };
    }

    /// What fills a call's parameters besides its arguments, and which
    /// of them it passes loans on from (`sema.CallParams`).
    const CallSite = struct {
        /// A method called on a value: its receiver fills parameter 0,
        /// before those `checkArgs` checks.
        receiver: bool = false,
        origins: sema.Origins = .{},
        /// The parameters as declared, before a generic call's
        /// instance is substituted, when known: what a diagnostic says
        /// a parameter would have to be (`Slot`).
        declared: []const TypeId = &.{},
    };

    /// The parameter or field of a call or constructor that an argument
    /// fills, as a diagnostic names it (`ignoredWriteLend`).
    const Slot = struct {
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
        /// The arguments whose `!` their slots ignore (`plainSlotLends`).
        lends: []const Sexp = &.{},
    };

    /// Arguments against a signature: arity, types, keyword arguments
    /// by parameter name, and defaults for omitted parameters. A call
    /// that uses keywords or defaults records its argument slots, and
    /// every complete call what fills each parameter (`CallParams`).
    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo, callee: []const u8, pos: u32, site: CallSite) Error!void {
        const call = self.current_call;
        const mark = self.ctx.diagnostics.items.len;
        const saved_slot = self.slot;
        defer self.slot = saved_slot;
        self.slot = .{ .call = call orelse .nil, .params = site.declared, .lends = try self.argLends(args, f, info) };
        const retains = self.callRetains(f, self.lend_recv);
        const lends = self.lend_call and !retains;
        self.lend_call = false;
        self.lend_recv = null;
        var first_kw: ?usize = null;
        for (args, 0..) |a, i| {
            if (a.isKind(.kwarg)) {
                if (first_kw == null) first_kw = i;
            } else if (first_kw != null) {
                try self.errAt(a, "positional arguments must come before keyword arguments", .{});
                try self.synthArgs(args);
                return;
            }
        }
        const positional = args[0 .. first_kw orelse args.len];
        const keyword = args[positional.len..];
        if (keyword.len > 0 and info.names == null) {
            try self.errAt(keyword[0], "`{s}` takes positional arguments only", .{callee});
            try self.synthArgs(args);
            return;
        }
        var required: usize = 0;
        for (0..f.params.len) |i| {
            if (info.default(i) == null) required += 1;
        }
        if (args.len > f.params.len or args.len < required) {
            if (required == f.params.len) {
                try self.err(pos, "call to `{s}` expects {d} argument{s}, got {d}", .{ callee, f.params.len, plural(f.params.len), args.len });
            } else {
                try self.err(pos, "call to `{s}` expects {d} to {d} arguments, got {d}", .{ callee, required, f.params.len, args.len });
            }
            try self.synthArgs(args);
            return;
        }
        const slots = try self.ctx.arena.allocator().alloc(?sema.ArgSlot, f.params.len);
        @memset(slots, null);
        for (positional, 0..) |a, i| {
            slots[i] = .{ .arg = @intCast(i) };
            try self.checkArg(a, f, i, lends);
        }
        for (keyword, positional.len..) |kw, ai| {
            const kname_node = ir.Kwarg.name(kw);
            const kname = self.text(kname_node);
            const idx = for (info.names.?, 0..) |n, i| {
                if (std.mem.eql(u8, n, kname)) break i;
            } else {
                try self.errAt(kname_node, "`{s}` has no parameter `{s}`", .{ callee, kname });
                _ = try self.synthExpr(ir.Kwarg.value(kw));
                continue;
            };
            if (slots[idx] != null) {
                try self.errAt(kname_node, "parameter `{s}` of `{s}` is given twice", .{ kname, callee });
                _ = try self.synthExpr(ir.Kwarg.value(kw));
                continue;
            }
            slots[idx] = .{ .arg = @intCast(ai) };
            try self.checkArg(ir.Kwarg.value(kw), f, idx, lends);
        }
        var complete = true;
        for (slots, 0..) |*slot, i| {
            if (slot.* != null) continue;
            if (info.default(i)) |d| {
                slot.* = .{ .default = .{ .expr = d, .source = info.source } };
                continue;
            }
            complete = false;
            const pname = if (info.names) |n| n[i] else "?";
            try self.err(pos, "call to `{s}` is missing an argument for parameter `{s}`", .{ callee, pname });
        }
        if (!complete) return;
        const call_node = call orelse return;
        const fills = try self.ctx.arena.allocator().alloc(sema.ParamFill, slots.len + @intFromBool(site.receiver));
        if (site.receiver) fills[0] = .receiver;
        for (slots, fills[@intFromBool(site.receiver)..]) |sl, *fill| fill.* = switch (sl.?) {
            .arg => |i| .{ .arg = i },
            .default => .default,
        };
        const recorded: sema.CallParams = .{ .fills = fills, .origins = site.origins, .names = info.names };
        try self.ctx.recordCallParams(call_node, recorded);
        // What the call may store outlives its statement. A place lent to
        // a parameter the call may keep is lent with `?` written (Core
        // sentence 4): one its callee's `keeps` names, and, where nothing
        // narrows the stores, any lent parameter the call may store by its
        // type (a function value, an owned closure, a built-in generic's
        // method at an instance whose `T` is a view).
        if (self.ctx.diagnostics.items.len == mark) {
            for (args, 0..) |a, i| {
                if (!recorded.stores(i)) continue;
                const value = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
                const param: ?usize = for (slots, 0..) |sl, k| {
                    if (sl.? == .arg and sl.?.arg == i) break k;
                } else null;
                const lent = if (param) |k| sema.lentParam(self.ctx, f.params[k]) else false;
                if ((recorded.keepsLent(i) or lent) and self.implicitArgument(value)) {
                    try self.reportKept(call_node, value, false, .{ .stored = callee });
                    continue;
                }
                try self.keptLends(value, .{ .stored = callee });
            }
        }
        if (keyword.len == 0 and args.len == f.params.len) return;
        const out = try self.ctx.arena.allocator().alloc(sema.ArgSlot, slots.len);
        for (slots, out) |s, *o| o.* = s.?;
        try self.ctx.recordCallSlots(call_node, out);
    }

    /// A method's parameters as its type declares them, after the first
    /// `skip`, when the type is this module's: the declaration's own
    /// types, a type parameter of the receiver's included.
    fn declaredParams(self: *Checker, m: Field, module: ?u32, skip: usize) ?[]const TypeId {
        if (module != null) return null;
        const params = switch (self.ctx.types.get(m.ty)) {
            .function => |f| f.params,
            else => return null,
        };
        return if (params.len >= skip) params[skip..] else null;
    }

    /// The arguments of a call to `f` whose `!` their parameters ignore
    /// (`plainSlotLends`), by position or by name.
    fn argLends(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo) Error![]const Sexp {
        const a = self.ctx.arena.allocator();
        const values = try a.alloc(Sexp, args.len);
        const types = try a.alloc(TypeId, args.len);
        for (args, values, types, 0..) |arg, *v, *ty, i| {
            v.* = .nil;
            ty.* = sema.type_invalid;
            if (arg.isKind(.kwarg)) {
                const names = info.names orelse continue;
                const k = for (names, 0..) |n, j| {
                    if (std.mem.eql(u8, n, self.text(ir.Kwarg.name(arg)))) break j;
                } else continue;
                if (k >= f.params.len) continue;
                v.* = ir.Kwarg.value(arg);
                ty.* = f.params[k];
            } else if (i < f.params.len) {
                v.* = arg;
                ty.* = f.params[i];
            }
        }
        return self.plainSlotLends(values, types);
    }

    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, lends: bool) Error!void {
        const saved = self.lent_temp;
        const saved_callable = self.lent_callable;
        const saved_kept = self.callable_kept;
        const saved_view = self.view_arg;
        defer {
            self.view_arg = saved_view;
            self.lent_temp = saved;
            self.lent_callable = saved_callable;
            self.callable_kept = saved_kept;
        }
        self.lent_temp = if (lends) arg else .nil;
        self.view_arg = arg;
        self.slot.value = arg;
        self.slot.declared = if (i < self.slot.params.len) self.slot.params[i] else f.params[i];
        // A closure literal lives for the call, so the call's result may
        // not hold it.
        const kept = sema.holdsCallable(self.ctx, f.returns);
        self.lent_callable = if (kept) .nil else arg;
        self.callable_kept = if (kept) arg else .nil;
        try self.checkExpr(arg, f.params[i]);
        try self.checkLendsVisibly(arg, f.params[i], "the call writes through");
    }

    /// A write view a binding holds is lent on to a `!T` visibly, `!w`,
    /// as an owned value is: the receiver of the lent view writes through
    /// it. (A read view is lent on bare.)
    fn checkLendsVisibly(self: *Checker, arg: Sexp, expected: TypeId, what: []const u8) Error!void {
        if (self.ctx.types.get(expected) != .write_view or arg != .src) return;
        const ty = self.ctx.typeOf(arg) orelse return;
        if (self.ctx.types.get(ty) != .write_view) return;
        const src = self.sourceText(arg);
        try self.errAt(arg, "write `!{s}`: {s} `{s}`", .{ src, what, src });
    }

    /// Whether a call of `f` (with receiver parameter `recv`) may keep a
    /// view of an argument past the call: in its result, or through a
    /// write view into something that can hold one.
    fn callRetains(self: *Checker, f: FunctionType, recv: ?TypeId) bool {
        if (sema.mayHoldMarkedView(self.ctx, f.returns)) return true;
        for (f.params) |p| if (self.storesView(p)) return true;
        return if (recv) |r| self.storesView(r) else false;
    }

    /// A write view into something that can hold a view.
    fn storesView(self: *Checker, param: TypeId) bool {
        const inner = switch (self.ctx.types.get(param)) {
            .write_view => |inner| inner,
            else => return false,
        };
        const held = if (sema.writeSliceElem(self.ctx, param)) |elem| elem else inner;
        return sema.mayHoldMarkedView(self.ctx, held);
    }

    /// Whether `e` is a name that names a type.
    fn isTypeName(self: *Checker, e: Sexp) bool {
        if (e != .src) return false;
        const id = self.lookupQuiet(e) orelse return resolve.isBuiltinTypeName(self.ctx, self.text(e));
        return switch (self.ctx.symbols.items[id].kind) {
            .nominal_type, .generic_type, .type_alias, .generic_param => true,
            else => false,
        };
    }

    /// Compile-time argument `i` of `callee`, a value of type `ty`.
    fn checkCtValue(self: *Checker, a: Sexp, ty: TypeId, i: usize, callee: []const u8) Error!void {
        if (self.isTypeName(a)) return self.errAt(a, "compile-time argument {d} of `{s}` is a value of type `{s}`, not a type", .{ i + 1, callee, try self.tyName(ty) });
        const mark = self.ctx.diagnostics.items.len;
        try self.checkExpr(a, ty);
        if (self.ctx.diagnostics.items.len != mark or self.isComptimeKnown(a)) return;
        const fixed = a == .src and if (self.ctx.symbolOf(a)) |id| self.ctx.symbols.items[id].flags.fixed else false;
        if (self.isCtArithmetic(a)) {
            try self.errAt(a, "compile-time argument {d} of `{s}` does arithmetic on a compile-time parameter, which Rig cannot check for overflow or division by zero; use a parameter or a constant", .{ i + 1, callee });
        } else if (fixed) {
            try self.errAt(a, "compile-time argument {d} of `{s}` must be known at compile time; `{s}` is bound with `=!` to a value computed when the program runs", .{ i + 1, callee, self.text(a) });
        } else try self.errAt(a, "compile-time argument {d} of `{s}` must be known at compile time; pass a literal, an enum value, a module constant, a compile-time parameter, a `=!` binding of one, or arithmetic on them", .{ i + 1, callee });
    }

    /// The `ct_param` of the compile-time integer parameter (or `k =! n`
    /// binding of one) that `e` names; null for anything else.
    fn ctParamOf(self: *Checker, e: Sexp) Error!?TypeId {
        if (e != .src) return null;
        const id = self.ctx.symbolOf(e) orelse return null;
        if (self.ctx.ct_locals.get(id)) |ct| return ct;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .param or !sym.flags.comptime_known or self.ctx.types.get(sym.ty) != .int) return null;
        return try self.ctx.intern(.{ .ct_param = id });
    }

    /// Compile-time argument `i` of `callee` for integer value parameter
    /// `param`: its value folded to a `ct_value`, or the `ct_param` of a
    /// compile-time parameter passed on. Null after a diagnostic.
    fn ctIntArg(self: *Checker, a: Sexp, param: SymbolId, i: usize, callee: []const u8) Error!?TypeId {
        const ty = self.ctx.symbols.items[param].ty;
        const mark = self.ctx.diagnostics.items.len;
        try self.checkCtValue(a, ty, i, callee);
        if (self.ctx.diagnostics.items.len != mark) return null;
        if (try self.ctParamOf(a)) |ct| return ct;
        const names: resolve.ConstNames = .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
        switch (sema.constIntBy(self.ctx, a, names)) {
            .value => |v| {
                if (!sema.intFits(self.ctx, ty, v)) {
                    const name = try self.tyName(ty);
                    try self.errAt(a, "compile-time argument {d} of `{s}` is `{d}`, which `{s}`, {s} `{s}`, cannot hold", .{ i + 1, callee, v, self.ctx.symbols.items[param].name, resolve.an(name), name });
                    return null;
                }
                return try sema.ctInt(self.ctx, v);
            },
            .overflow => try self.errAt(a, "compile-time argument {d} of `{s}` is too large to compute", .{ i + 1, callee }),
            .not_constant => if (sema.perTargetLeaf(self.ctx, a)) |leaf| {
                try self.errAt(a, "compile-time argument {d} of `{s}` must be known when Rig checks the program; " ++ sema.per_target_why, .{ i + 1, callee, self.sourceText(leaf) });
            } else try self.errAt(a, "compile-time argument {d} of `{s}` must be an integer known at compile time: an integer, a constant, a compile-time parameter, or arithmetic on constants", .{ i + 1, callee }),
        }
        return null;
    }

    /// A method's type parameters and the receiver's arguments for them:
    /// the first part of an instance of a method with type parameters of
    /// its own. Empty for a type that is not generic.
    fn receiverArgs(self: *Checker, recv_ty: TypeId) TypeSubst {
        const pn = switch (self.ctx.types.get(sema.unwrapReadAccess(self.ctx, recv_ty))) {
            .parameterized_nominal => |pn| pn,
            else => return .empty,
        };
        return .{ .params = self.ctx.symbols.items[pn.sym].type_params orelse &.{}, .args = pn.args };
    }

    /// The signature a call of `f` uses: `f` itself, or for a generic
    /// function the instance its bracket list `ct` gives (every
    /// compile-time argument, in order) or, without one, the instance its
    /// arguments determine (`args`, filling `f.params[skip..]`). Each
    /// compile-time value must be known at compile time. The call's
    /// type arguments (`genericCallOf`) and the instance, whose body must
    /// allow them, are recorded. Null after a diagnostic that makes the
    /// arguments not worth checking.
    fn instantiateCall(self: *Checker, f: FunctionType, ct: ?Sexp, args: []const Sexp, info: ParamInfo, skip: usize, callee: []const u8, pos: u32, receiver_arg: bool, recv: TypeSubst) Error!?FunctionType {
        self.inst_own = .empty;
        if (ct) |b| try self.ctx.recordInstance(b, .function);
        // A compile-time parameter was rejected: the declaration's
        // diagnostic says what is wrong with every call.
        for (f.ct_params) |ty| if (self.isPoison(ty)) return null;
        const a = self.ctx.arena.allocator();
        const n = f.ct_params.len;
        // The parameters an instance binds: the type parameters and the
        // integer value parameters, at their slots.
        var own: std.ArrayList(SymbolId) = .empty;
        var own_slots: std.ArrayList(usize) = .empty;
        for (f.ct_params, 0..) |slot, i| {
            const sym = sema.typeParamOf(self.ctx, slot) orelse self.intSlot(f, i) orelse continue;
            try own.append(a, sym);
            try own_slots.append(a, i);
        }
        const given: []const Sexp = if (ct) |b| sema.bracketArgs(b) else &.{};
        if (ct) |b| if (given.len != n) {
            if (n == 0) {
                try self.errAt(b, "`{s}` takes no compile-time arguments; call it with `{s}(...)`", .{ callee, callee });
            } else try self.errAt(b, "`{s}` expects {d} compile-time argument{s}, got {d}", .{ callee, n, plural(n), given.len });
            return null;
        };
        // A value is inferred only for an integer parameter that the
        // parameters' or the result's types hold (`[n]T`); a function
        // that takes another is given every compile-time argument in
        // brackets.
        if (ct == null) for (f.ct_params, 0..) |slot, i| {
            if (sema.typeParamOf(self.ctx, slot) != null) continue;
            if (self.intSlot(f, i)) |sym| if (self.signatureUses(f, sym)) continue;
            // A rejected parameter type may be what would have held it.
            for (f.params) |p| if (sema.containsPoison(self.ctx, p)) return null;
            const parens = if (f.params.len > skip) "(...)" else "()";
            // `f([1, 2])` for `f[1, 2]()`: the only argument is
            // an array, where the function takes none.
            if (f.params.len == skip and args.len == 1 and args[0].isKind(.array)) {
                const arg = self.sourceText(args[0]);
                try self.err(pos, "compile-time arguments go in brackets after the name: `{s}{s}{s}`", .{ callee, arg, parens });
            } else {
                try self.err(pos, "`{s}` takes {d} compile-time argument{s} in brackets: `{s}[...]{s}`", .{ callee, n, plural(n), callee, parens });
            }
            return null;
        };
        const type_args = try a.alloc(TypeId, n);
        @memset(type_args, sema.type_invalid);
        var bad = false;
        if (ct != null) for (given, f.ct_params, 0..) |g, slot, i| {
            if (sema.typeParamOf(self.ctx, slot) != null) {
                type_args[i] = try self.typeArg(g);
                if (self.isPoison(type_args[i])) bad = true;
            } else if (self.intSlot(f, i)) |sym| {
                type_args[i] = (try self.ctIntArg(g, sym, i, callee)) orelse blk: {
                    bad = true;
                    break :blk sema.type_invalid;
                };
            } else try self.checkCtValue(g, slot, i, callee);
        };
        if (bad) return null;
        if (own.items.len == 0) {
            if (ct != null) try self.ctx.recordGenericCall(self.current_call.?, .{ .type_args = type_args, .receiver_arg = receiver_arg });
            self.inst_own = .empty;
            return f;
        }
        if (ct == null) {
            const inferred = (try self.inferCallTypeArgs(f, own.items, args, info, skip, callee, pos)) orelse return null;
            for (own_slots.items, inferred) |i, ty| type_args[i] = ty;
        }
        const own_args = try a.alloc(TypeId, own.items.len);
        for (own_slots.items, own_args) |i, *arg| arg.* = type_args[i];
        const generic = try self.ctx.internCopy(.{ .function = f });
        const instance = try sema.substituteType(self.ctx, generic, .{ .params = own.items, .args = own_args });
        if (instance != generic) if (sema.findHeapStacked(self.ctx, instance)) |found| {
            try self.err(pos, "`{s}` at these types has `{s}` in its signature, which stacks one heap holding on another; " ++ sema.heap_stacked_rule, .{ callee, try self.tyName(found) });
            return null;
        };
        const result = self.ctx.types.get(instance).function;
        try self.ctx.recordGenericCall(self.current_call.?, .{ .type_args = type_args, .receiver_arg = receiver_arg });
        self.inst_own = .{ .params = own.items, .args = own_args };
        if (self.tentative == 0) _ = try self.ctx.recordFnInstance(.{
            .name = callee,
            .params = try std.mem.concat(a, SymbolId, &.{ recv.params, own.items }),
            .args = try std.mem.concat(a, TypeId, &.{ recv.args, own_args }),
            .own = @intCast(own.items.len),
        }, pos, null);
        return result;
    }

    /// The symbol of compile-time slot `i` of `f` when it is an integer
    /// value parameter of this module's (`n: Int`), which an instance
    /// binds; null for any other slot.
    fn intSlot(self: *Checker, f: FunctionType, i: usize) ?SymbolId {
        if (i >= f.ct_syms.len or f.ct_syms[i] == sema.symbol_invalid) return null;
        if (self.ctx.types.get(f.ct_params[i]) != .int) return null;
        return f.ct_syms[i];
    }

    /// Whether the types of `f`'s parameters or result hold `sym`.
    fn signatureUses(self: *Checker, f: FunctionType, sym: SymbolId) bool {
        const params = [_]SymbolId{sym};
        for (f.params) |p| if (sema.usesParams(self.ctx, p, &params)) return true;
        return sema.usesParams(self.ctx, f.returns, &params);
    }

    /// What the arguments of a call say about one type parameter: the
    /// type the first non-literal argument gives it, and the first
    /// argument that gives it another.
    const Bound = struct {
        ty: TypeId = sema.type_invalid,
        arg: u32 = 0,
        conflict: TypeId = sema.type_invalid,
        conflict_arg: u32 = 0,
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
    const LiteralBound = struct { param: usize, ty: TypeId, arg: u32 };

    const Inference = struct {
        own: []const SymbolId,
        bound: []Bound,
        literals: std.ArrayList(LiteralBound) = .empty,
        /// The first argument whose type does not have the shape of the
        /// type it fills (`?[3]Int` where `[]T` goes).
        mismatch: ?struct { arg: u32, pattern: TypeId, actual: TypeId } = null,
        /// The type expected of the result does not have the declared
        /// result's shape.
        result_mismatch: bool = false,
        /// An argument's type or the expected type holds poison: a
        /// diagnostic about it explains a parameter left unbound.
        poisoned: bool = false,
        /// How many held places `bindArg` is inside (`Bound.held`).
        exact: u8 = 0,
        /// `bindArg` is matching the `T` of a `?T` against a `?String`.
        viewing: bool = false,
    };

    /// Match each argument's type against the field or parameter it
    /// fills (by position, or by keyword), binding the type parameters in
    /// `own` that appear there. A parameter no argument other than a
    /// literal binds takes its type from `result`, the declared result
    /// and the type expected of it, when that says; otherwise a literal
    /// binds its default type (`Int`, `Float`). The first argument that
    /// disagrees with a binding is kept as a conflict.
    fn inferBindings(self: *Checker, own: []const SymbolId, args: []const Sexp, from: InferFrom, result: ?ResultType) Error!Inference {
        var inf: Inference = .{ .own = own, .bound = try self.ctx.arena.allocator().alloc(Bound, own.len) };
        @memset(inf.bound, .{});
        // Closure literals are matched last, against the parameter types
        // the other arguments give them (`lentLambdaTypes`).
        var lambdas: std.ArrayList(LambdaArg) = .empty;
        var positional: usize = 0;
        for (args, 1..) |arg, number| {
            var value = arg;
            var pattern: ?TypeId = null;
            if (arg.isKind(.kwarg)) {
                value = ir.Kwarg.value(arg);
                const kname = self.text(ir.Kwarg.name(arg));
                pattern = switch (from) {
                    .fields, .payload => |fs| if (try findDataField(self.ctx, fs, kname)) |f| f.ty else null,
                    .params => |p| blk: {
                        const names = p.names orelse break :blk null;
                        for (names, 0..) |name, i| {
                            if (std.mem.eql(u8, name, kname) and i < p.params.len) break :blk p.params[i];
                        }
                        break :blk null;
                    },
                };
            } else {
                // A struct's or variant's one field may be given
                // positionally; more fields are set by name.
                defer positional += 1;
                pattern = switch (from) {
                    .fields, .payload => |fs| if (positional == 0 and args.len == 1) if (soleField(fs)) |f| f.ty else null else null,
                    .params => |p| if (positional < p.params.len) p.params[positional] else null,
                };
            }
            const pat = pattern orelse continue;
            if (sema.containsPoison(self.ctx, pat)) inf.poisoned = true;
            if (!sema.containsTypeVar(self.ctx, pat)) continue;
            if (value.isKind(.lambda)) if (lambdaPattern(self.ctx, pat)) |fn_pat| {
                try lambdas.append(self.ctx.arena.allocator(), .{ .pattern = fn_pat, .lambda = value, .arg = @intCast(number) });
                continue;
            };
            const actual = try self.argType(value);
            if (sema.containsPoison(self.ctx, actual)) inf.poisoned = true;
            try self.bindArg(&inf, pat, actual, @intCast(number), 0);
        }
        if (result) |r| {
            if (sema.containsPoison(self.ctx, r.expected)) inf.poisoned = true;
            try self.bindExpected(&inf, r);
        }
        for (inf.bound, 0..) |*b, i| for (inf.literals.items) |lit| {
            if (lit.param != i) continue;
            // Checking the literal against the expected type's binding
            // reports one that does not fit.
            if (b.expected) continue;
            // Among literals alone, a float one makes the type `Float`,
            // whatever their order.
            if (b.ty == sema.type_invalid or (b.ty == self.t().int_id and lit.ty == self.t().float_id and self.onlyLiterals(inf, i, b.arg))) {
                b.ty = lit.ty;
                b.arg = lit.arg;
            } else if (b.conflict == sema.type_invalid and !self.literalFits(lit.ty, b.ty)) {
                b.conflict = lit.ty;
                b.conflict_arg = lit.arg;
            }
        };
        // A closure literal whose parameters are known binds what its
        // result gives, which may type another literal's parameters:
        // repeat until no literal is left or none makes progress.
        const done = try self.ctx.arena.allocator().alloc(bool, lambdas.items.len);
        @memset(done, false);
        var progress = true;
        while (progress) {
            progress = false;
            for (lambdas.items, done) |l, *d| {
                if (d.*) continue;
                const actual = (try self.lentLambdaType(&inf, l.pattern, l.lambda)) orelse continue;
                try self.bindArg(&inf, l.pattern, actual, l.arg, 1);
                d.* = true;
                progress = true;
            }
        }
        // A `T` that a `Static` argument and a `?String` argument both
        // bind is the `?String`, which reads the `Static` (`meets`), unless
        // a place that holds it exactly (a `Cell[T]`, a `!T`) gives the
        // type: that one holds, and the argument that differs is reported
        // where it is checked.
        for (inf.bound) |*b| {
            if (b.conflict == sema.type_invalid) continue;
            const string_view_ty = self.t().string_view_id;
            const static_ty = self.t().static_id;
            if ((b.ty == static_ty and b.conflict == string_view_ty) or (b.ty == string_view_ty and b.conflict == static_ty)) {
                b.ty = if (b.held_ty == sema.type_invalid) string_view_ty else b.held_ty;
                b.conflict = sema.type_invalid;
            }
        }
        // A `T` that only `?T`s met a `?String` is the `String` it views:
        // a read view of `T` is that `?String`.
        for (inf.bound) |*b| if (b.text_view and b.conflict == sema.type_invalid) {
            b.ty = self.t().string_id;
            b.text_view = false;
        };
        return inf;
    }

    /// A closure literal argument of a generic call, and the function
    /// type its parameter gives it.
    const LambdaArg = struct { pattern: TypeId, lambda: Sexp, arg: u32 };

    /// The function type a closure literal passed where parameter type
    /// `pat` goes is checked against: `pat` itself, or the callable a
    /// `?fun(...)` lends.
    fn lambdaPattern(ctx: *const SemContext, pat: TypeId) ?TypeId {
        if (sema.callableFnTy(ctx, pat)) |f| return f;
        return if (ctx.types.get(pat) == .function) pat else null;
    }

    /// The type of closure literal `lambda` where function type `pattern`
    /// goes, checked quietly: its parameters take the types the call's
    /// other arguments bound in `pattern` (or their annotations), and its
    /// result is its body's. Null when a parameter has no type yet.
    fn lentLambdaType(self: *Checker, inf: *const Inference, pattern: TypeId, lambda: Sexp) Error!?TypeId {
        const a = self.ctx.arena.allocator();
        var params: std.ArrayList(SymbolId) = .empty;
        var types: std.ArrayList(TypeId) = .empty;
        for (inf.own, inf.bound) |p, b| {
            if (b.ty == sema.type_invalid or b.conflict != sema.type_invalid) continue;
            try params.append(a, p);
            try types.append(a, b.ty);
        }
        const f = self.ctx.types.get(pattern).function;
        const given = try a.alloc(TypeId, f.params.len);
        for (f.params, given) |p, *g| {
            const ty = try sema.substituteType(self.ctx, p, .{ .params = params.items, .args = types.items });
            g.* = if (sema.usesParams(self.ctx, ty, inf.own)) sema.type_invalid else ty;
        }
        const mark = self.ctx.diagnostics.items.len;
        self.ctx.quiet += 1;
        self.tentative += 1;
        defer {
            self.ctx.quiet -= 1;
            self.tentative -= 1;
            self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        }
        const ty = try self.checkLambdaGiven(lambda, null, given);
        const got = self.ctx.types.get(ty).function;
        for (got.params) |p| if (self.isPoison(p)) return null;
        if (got.params.len != f.params.len) return null;
        return ty;
    }

    /// A generic call's declared result, and the type expected of it.
    const ResultType = struct { pattern: TypeId, expected: TypeId };

    /// The call being checked's declared result `pattern`, with the type
    /// expected of the call, when one is.
    fn expectedResult(self: *Checker, pattern: TypeId) ?ResultType {
        const call = self.current_call orelse return null;
        if (!sameNode(call, self.result_expected.call)) return null;
        return .{ .pattern = pattern, .expected = self.result_expected.ty };
    }

    /// The declared result with what the call's value becomes where it
    /// goes: a fallible result is propagated or caught to its value, and
    /// a value where a `T?` or `T!` is expected is lifted from a `T`.
    fn resultMatch(self: *Checker, r: ResultType) ResultType {
        var out = r;
        while (true) {
            const p = self.ctx.types.get(out.pattern);
            const e = self.ctx.types.get(out.expected);
            if (p == .fallible and e != .fallible) {
                out.pattern = p.fallible;
            } else if (p != .fallible and e == .fallible) {
                out.expected = e.fallible;
            } else if (p != .optional and p != .fallible and e == .optional) {
                out.expected = e.optional;
            } else return out;
        }
    }

    /// Bind the parameters of `inf` that no argument other than a literal
    /// binds by matching the declared result against the type expected
    /// of it, as an argument is matched against its parameter. A
    /// parameter an argument binds keeps its type, and the type the
    /// result wants is kept for the diagnostic.
    fn bindExpected(self: *Checker, inf: *Inference, r: ResultType) Error!void {
        if (!sema.containsTypeVar(self.ctx, r.pattern)) return;
        const want = try self.bindResult(inf.own, self.resultMatch(r));
        // A parameter a `none` fills is the optional itself: `o: Int? =
        // id(none)` is `id[Int?]`.
        const exact = try self.bindResult(inf.own, r);
        inf.result_mismatch = want.mismatch != null;
        for (inf.bound, want.bound, exact.bound) |*b, lifted, same| {
            const w = if (b.none) same else lifted;
            if (w.ty == sema.type_invalid or w.conflict != sema.type_invalid) continue;
            if (b.ty == sema.type_invalid) {
                b.ty = w.ty;
                b.expected = true;
            } else if (b.ty != w.ty) b.wanted = w.ty;
        }
    }

    /// The bindings of `own` that make declared result `r.pattern` match
    /// `r.expected`.
    fn bindResult(self: *Checker, own: []const SymbolId, r: ResultType) Error!Inference {
        var inf: Inference = .{ .own = own, .bound = try self.ctx.arena.allocator().alloc(Bound, own.len) };
        @memset(inf.bound, .{});
        try self.bindArg(&inf, r.pattern, r.expected, 0, 0);
        return inf;
    }

    /// Whether the binding of parameter `i` by argument `arg` came from a
    /// literal.
    fn onlyLiterals(self: *Checker, inf: Inference, i: usize, arg: u32) bool {
        _ = self;
        for (inf.literals.items) |lit| {
            if (lit.param == i and lit.arg == arg) return true;
        }
        return false;
    }

    /// An argument's type for inference, synthesized once: the call checks
    /// the argument again, and a generic call nested in its arguments
    /// would otherwise be synthesized twice at every level.
    fn argType(self: *Checker, e: Sexp) Error!TypeId {
        self.tentative += 1;
        defer self.tentative -= 1;
        // A slice there is lent as it is where the argument is checked.
        const saved_view = self.view_arg;
        defer self.view_arg = saved_view;
        self.view_arg = e;
        if (e != .list or e.list.id == 0) return self.synthQuiet(e);
        if (self.arg_types.get(e.list.id)) |ty| return ty;
        var ty = try self.synthQuiet(e);
        if (self.literalResult(e)) |lit| ty = lit;
        // A write lend written here binds the value it reaches where that
        // is copied out, as the slot then reads it (`writeLendRead`), and
        // the view only where no copy could be meant.
        if (self.writtenWriteLend(e, ty) != null) if (sema.copiedThrough(self.ctx, ty)) |value| {
            ty = value;
        };
        try self.arg_types.put(self.ctx.allocator, e.list.id, ty);
        return ty;
    }

    /// The literal or `none` a generic call binds like as an argument
    /// (`literal_results`): the call itself, or one propagated with `!`
    /// or `?`.
    fn literalResult(self: *Checker, e: Sexp) ?TypeId {
        const call, const path: ResultPath = switch (e.kind() orelse return null) {
            .call => .{ e, .direct },
            .propagate => .{ ir.Propagate.value(e), .propagate },
            .propagate_none => .{ ir.PropagateNone.value(e), .propagate_none },
            else => return null,
        };
        if (!call.isKind(.call) or call.list.id == 0) return null;
        const r = self.literal_results.get(call.list.id) orelse return null;
        return if (r.path == path) r.ty else null;
    }

    /// The two types of a conflict, in argument order.
    fn conflictText(self: *Checker, b: Bound) Error!struct { first: []const u8, first_ty: TypeId, first_arg: u32, second: []const u8, second_arg: u32, later: TypeId } {
        const b_first = b.arg < b.conflict_arg;
        const later = if (b_first) b.conflict else b.ty;
        const first_ty = if (b_first) b.ty else b.conflict;
        return .{
            .first = try self.tyName(first_ty),
            .first_ty = first_ty,
            .first_arg = @min(b.arg, b.conflict_arg),
            .second = try self.tyName(later),
            .second_arg = @max(b.arg, b.conflict_arg),
            .later = later,
        };
    }

    /// A generic function's type arguments, one per parameter in `own`,
    /// from the arguments of a call, which fill `f.params[skip..]`, and
    /// the type expected of its result (`inferBindings`). Null after a
    /// diagnostic.
    fn inferCallTypeArgs(self: *Checker, f: FunctionType, own: []const SymbolId, args: []const Sexp, info: ParamInfo, skip: usize, callee: []const u8, pos: u32) Error!?[]TypeId {
        const call = self.current_call orelse Sexp.nil;
        const inf = try self.inferBindings(own, args, .{ .params = .{ .params = f.params[@min(skip, f.params.len)..], .names = info.names } }, self.expectedResult(f.returns));
        const result = try self.ctx.arena.allocator().alloc(TypeId, own.len);
        for (inf.bound, result) |b, *r| r.* = b.ty;
        if (call == .list and call.list.id != 0) try self.noteResultBinding(call.list.id, f, own, inf, callee);
        const parens = if (f.params.len > skip) "(...)" else "()";
        var ok = true;
        for (inf.bound, own, 0..) |b, param, i| {
            const pname = self.ctx.symbols.items[param].name;
            if (b.ty == sema.type_invalid) {
                ok = false;
                if (inf.poisoned) continue;
                // An argument of another shape says why, as for any call.
                if (inf.mismatch) |m| if (m.arg <= args.len) {
                    try self.errAt(args[m.arg - 1], "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(m.pattern), try self.tyName(m.actual) });
                    break;
                };
                if (inf.result_mismatch) {
                    try self.err(pos, "type mismatch: expected `{s}`, but `{s}` returns `{s}`", .{ try self.tyName(self.result_expected.ty), callee, try self.tyName(f.returns) });
                    break;
                }
                try self.err(pos, "cannot infer `{s}` for `{s}` from its arguments or the type expected of its result; {s}", .{ pname, callee, try self.inferHint(f, own, result, i, callee, parens) });
            } else if (b.conflict != sema.type_invalid) {
                ok = false;
                if (self.ctx.symbols.items[param].kind == .param) {
                    const c = try self.conflictText(b);
                    try self.err(pos, "conflicting values for `{s}` in the call to `{s}`: `{s}` (argument {d}) and `{s}` (argument {d})", .{ pname, callee, c.first, c.first_arg, c.second, c.second_arg });
                    continue;
                }
                // The later argument's type is suggested, when the earlier
                // argument can have it; otherwise a conversion.
                const c = try self.conflictText(b);
                const literal = self.onlyLiterals(inf, i, c.first_arg);
                if (if (literal) self.literalFits(c.first_ty, c.later) else compatible(self.ctx, c.first_ty, c.later)) {
                    const fix = if (try self.bracketHint(result, i, c.later)) |brackets|
                        try self.ctx.arena.allocator().print("give it in brackets: `{s}[{s}]{s}`", .{ callee, brackets, parens })
                    else
                        "give it in brackets, naming each array, slice, or function type in them with a `type` alias";
                    try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` (argument {d}) and `{s}` (argument {d}); {s}", .{ pname, callee, c.first, c.first_arg, c.second, c.second_arg, fix });
                } else if (sema.isNumeric(self.ctx, c.first_ty) and sema.isNumeric(self.ctx, c.later)) {
                    // Convert the argument that is not a literal.
                    const arg = if (literal) c.second_arg else c.first_arg;
                    try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` (argument {d}) and `{s}` (argument {d}); convert argument {d} with `{s}(...)`", .{ pname, callee, c.first, c.first_arg, c.second, c.second_arg, arg, if (literal) c.first else c.second });
                } else {
                    try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` (argument {d}) and `{s}` (argument {d}); they must have one type", .{ pname, callee, c.first, c.first_arg, c.second, c.second_arg });
                }
                ok = false;
            } else if (try self.lentClosureBound(b.ty, pname, callee, pos) or !try self.valueBindingFits(param, b, callee, pos) or !try self.inferredTypeFits(b, args)) ok = false;
        }
        return if (ok) result else null;
    }

    /// Whether inference bound type parameter `pname` of `callee` to
    /// what a lent closure lends (`?f` where `?T` goes): a closure is lent
    /// only where `?fun(...)` is written, and no value holds one.
    /// Reported.
    fn lentClosureBound(self: *Checker, ty: TypeId, pname: []const u8, callee: []const u8, pos: u32) Error!bool {
        if (!sema.holdsCallable(self.ctx, ty)) return false;
        if (sema.callableFn(self.ctx, ty) != null) {
            try self.err(pos, "`{s}` cannot take a callable view for `{s}`: a `{s}` is only a parameter's, a local's, or a result's type, and no value holds one", .{ callee, pname, try self.tyName(ty) });
            return true;
        }
        if (sema.holdsMarkedView(self.ctx, ty)) return false;
        try self.err(pos, "`{s}` cannot take a lent closure for `{s}`: a closure is lent (`?f`) only to a parameter declared `?fun(...)` or `?sub(...)`", .{ callee, pname });
        return true;
    }

    /// Whether the value inference gave value parameter `param` (when it
    /// is one) is one it takes: a value its type holds, or a compile-time
    /// parameter of the same type. Reports one that is not.
    fn valueBindingFits(self: *Checker, param: SymbolId, b: Bound, callee: []const u8, pos: u32) Error!bool {
        const p = self.ctx.symbols.items[param];
        if (p.kind != .param or self.isPoison(p.ty)) return true;
        const from = if (b.expected) "the type expected of the result" else try self.ctx.arena.allocator().print("argument {d}", .{b.arg});
        switch (self.ctx.types.get(b.ty)) {
            .ct_value => |v| if (!sema.intFits(self.ctx, p.ty, v.int)) {
                const name = try self.tyName(p.ty);
                try self.err(pos, "{s} gives `{s}` of `{s}` the value `{d}`, which {s} `{s}` cannot hold", .{ from, p.name, callee, v.int, resolve.an(name), name });
                return false;
            },
            .ct_param => |sym| {
                const ty = self.ctx.symbols.items[sym].ty;
                if (!self.isPoison(ty) and ty != p.ty) {
                    try self.err(pos, "{s} gives `{s}` of `{s}` the compile-time `{s}` `{s}`; `{s}` is a `{s}`", .{ from, p.name, callee, try self.tyName(ty), self.ctx.symbols.items[sym].name, p.name, try self.tyName(p.ty) });
                    return false;
                }
            },
            else => {},
        }
        return true;
    }

    /// A type inference took from an argument must fit
    /// `sema.max_value_bytes`, as a spelled one must where it is spelled:
    /// an array too large is reported at the argument.
    fn inferredTypeFits(self: *Checker, b: Bound, args: []const Sexp) Error!bool {
        if (b.expected or b.arg == 0 or b.arg > args.len) return true;
        const arg = args[b.arg - 1];
        const value = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
        return sema.checkArraysIn(self.ctx, self.startOf(value), b.ty);
    }

    /// What a generic call's result says to the calls around it: whether
    /// it gives a type parameter that only literals gave a type, or is an
    /// optional nothing gave one (`literal_results`), and, where an
    /// argument gives the parameter another type than the expected one,
    /// the fix for the mismatch that follows (`result_hints`): converting
    /// the result.
    fn noteResultBinding(self: *Checker, id: parser.NodeId, f: FunctionType, own: []const SymbolId, inf: Inference, callee: []const u8) Error!void {
        _ = self.literal_results.remove(id);
        _ = self.result_hints.remove(id);
        const path: ResultPath, const value = switch (self.ctx.types.get(f.returns)) {
            .fallible => |inner| .{ .propagate, inner },
            .optional => |inner| .{ .propagate_none, inner },
            else => .{ .direct, f.returns },
        };
        const tv = switch (self.ctx.types.get(value)) {
            .type_var => |tv| tv,
            else => return,
        };
        const i = std.mem.findScalar(SymbolId, own, tv) orelse return;
        const b = inf.bound[i];
        if (b.ty == sema.type_invalid) {
            // `id(none)` and `nothing()` give some optional.
            if ((path == .direct and b.none) or path == .propagate_none) {
                try self.literal_results.put(self.ctx.allocator, id, .{ .ty = self.t().none_id, .path = .direct });
            }
            return;
        }
        if (b.conflict != sema.type_invalid) return;
        if (!b.expected and self.onlyLiterals(inf, i, b.arg)) {
            const lit = if (b.ty == self.t().float_id) self.t().float_literal_id else self.t().int_literal_id;
            try self.literal_results.put(self.ctx.allocator, id, .{ .ty = lit, .path = path });
        }
        if (path == .propagate_none) return;
        if (b.wanted == sema.type_invalid) return;
        const a = self.ctx.arena.allocator();
        const took = try a.print("`{s}` takes `{s} = {s}` from argument {d}", .{ callee, self.ctx.symbols.items[tv].name, try self.tyName(b.ty), b.arg });
        if (sema.isNumeric(self.ctx, b.ty) and sema.isNumeric(self.ctx, b.wanted)) {
            try self.result_hints.put(self.ctx.allocator, id, try a.print("{s}; convert its result with `{s}(...)`", .{ took, try self.tyName(b.wanted) }));
            return;
        }
        // Brackets pass the type on to an argument that takes it from
        // where it goes, such as a nested generic call.
        const types = try a.alloc(TypeId, inf.bound.len);
        for (inf.bound, types) |bound, *ty| ty.* = bound.ty;
        const brackets = (try self.bracketHint(types, i, b.wanted)) orelse return self.result_hints.put(self.ctx.allocator, id, took);
        try self.result_hints.put(self.ctx.allocator, id, try a.print("{s}; to pass `{s}` on to it, give it in brackets: `{s}[{s}](...)`", .{ took, try self.tyName(b.wanted), callee, brackets }));
    }

    /// Whether a literal of type `lit` (an integer or float literal's
    /// default type) can be a value of `ty`. Next to a type parameter, a
    /// literal is reported where the argument is checked.
    fn literalFits(self: *Checker, lit: TypeId, ty: TypeId) bool {
        if (self.ctx.types.get(ty) == .type_var) return true;
        const literal = if (lit == self.t().float_id) self.t().float_literal_id else self.t().int_literal_id;
        return compatible(self.ctx, literal, ty);
    }

    /// The bracket list a diagnostic suggests: each type parameter's
    /// inferred type, or `...` when unknown, with `at` for the one at
    /// `index`. Null when a type in it has no expression spelling
    /// (`spelledInBrackets`).
    fn bracketHint(self: *Checker, types: []const TypeId, index: usize, at: ?TypeId) Error!?[]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const a = self.ctx.arena.allocator();
        for (types, 0..) |ty, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            const shown = if (i == index) at orelse sema.type_invalid else ty;
            if (shown != sema.type_invalid and !spelledInBrackets(self.ctx, shown)) return null;
            try buf.appendSlice(a, if (shown == sema.type_invalid) "..." else try self.tyName(shown));
        }
        return buf.items;
    }

    /// What to write for type parameter `index` of `callee`, which nothing
    /// determines: the bracket list, or, where a type in it has no
    /// expression spelling, the type where the value goes when the
    /// result holds the parameter.
    fn inferHint(self: *Checker, f: FunctionType, own: []const SymbolId, types: []const TypeId, index: usize, callee: []const u8, parens: []const u8) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        const pname = self.ctx.symbols.items[own[index]].name;
        if (try self.bracketHint(types, index, null)) |brackets| return a.print("give `{s}` in brackets: `{s}[{s}]{s}`", .{ pname, callee, brackets, parens });
        // The result with each known type argument in place.
        const args = try a.alloc(TypeId, own.len);
        for (own, types, args) |p, ty, *arg| arg.* = if (ty == sema.type_invalid) try self.ctx.intern(.{ .type_var = p }) else ty;
        const shown = try sema.substituteType(self.ctx, f.returns, .{ .params = own, .args = args });
        const holds = (try sema.substituteType(self.ctx, f.returns, .{ .params = own[index .. index + 1], .args = &.{self.t().void_id} })) != f.returns;
        if (holds) return a.print("give the type where the value goes: `x: {s} = {s}{s}`, with a type in place of `{s}`", .{ try self.tyName(shown), callee, parens, pname });
        return a.print("give `{s}` in brackets, naming each array, slice, or function type in them with a `type` alias", .{pname});
    }

    /// Bind the type parameters of `inf` in `pattern`, a parameter's type,
    /// so that it matches `actual`, argument number `arg`'s type. Where the
    /// shapes differ nothing is bound, and checking the argument reports
    /// the mismatch.
    fn noteMismatch(self: *Checker, inf: *Inference, pattern: TypeId, actual: TypeId, arg: u32) void {
        if (inf.mismatch != null or self.ctx.types.get(actual) == .none_literal) return;
        inf.mismatch = .{ .arg = arg, .pattern = pattern, .actual = actual };
    }

    fn bindArg(self: *Checker, inf: *Inference, pattern: TypeId, actual: TypeId, arg: u32, depth: u8) Error!void {
        if (depth > 32 or self.isPoison(actual)) return;
        const at = self.ctx.types.get(actual);
        switch (self.ctx.types.get(pattern)) {
            .type_var => |tv| {
                const i = std.mem.findScalar(SymbolId, inf.own, tv) orelse return;
                const value = readValue(self.ctx, actual);
                switch (self.ctx.types.get(value)) {
                    .none_literal => {
                        if (depth == 0) inf.bound[i].none = true;
                        return;
                    },
                    .noreturn, .void, .invalid, .unknown => return,
                    .int_literal, .float_literal => return inf.literals.append(self.ctx.arena.allocator(), .{ .param = i, .ty = self.canonical(value), .arg = arg }),
                    else => {},
                }
                const b = &inf.bound[i];
                if (inf.exact > 0 and b.held_ty == sema.type_invalid) b.held_ty = value;
                if (b.ty == sema.type_invalid) {
                    b.ty = value;
                    b.arg = arg;
                    b.text_view = inf.viewing;
                } else if (b.ty == value) {
                    if (!inf.viewing) b.text_view = false;
                } else if (b.ty == self.t().string_id and inf.viewing and value == self.t().string_view_id) {
                    // A `?T` meets the read view of the `String` that `T` is.
                } else if (b.text_view and value == self.t().string_id) {
                    b.ty = value;
                    b.arg = arg;
                    b.text_view = false;
                } else if (b.ty != value and b.conflict == sema.type_invalid) {
                    b.conflict = value;
                    b.conflict_arg = arg;
                }
            },
            // A value where a `T?` goes is lifted; a value where a view
            // goes is matched as its view would be.
            .optional => |p| try self.bindArg(inf, p, if (at == .optional) at.optional else actual, arg, depth + 1),
            .read_view, .write_view => |p| {
                const held: u8 = @intFromBool(self.ctx.types.get(pattern) == .write_view);
                inf.exact += held;
                defer inf.exact -= held;
                const viewing = inf.viewing;
                defer inf.viewing = viewing;
                inf.viewing = at == .string_view and self.ctx.types.get(pattern) == .read_view;
                try self.bindArg(inf, p, switch (at) {
                    .read_view, .write_view => |inner| inner,
                    else => actual,
                }, arg, depth + 1);
            },
            .fallible => |p| if (at == .fallible) try self.bindArg(inf, p, at.fallible, arg, depth + 1) else self.noteMismatch(inf, pattern, actual, arg),
            .shared => |p| if (at == .shared) {
                inf.exact += 1;
                defer inf.exact -= 1;
                try self.bindArg(inf, p, at.shared, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            .weak => |p| if (at == .weak) {
                inf.exact += 1;
                defer inf.exact -= 1;
                try self.bindArg(inf, p, at.weak, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            // A `![]T` goes where a `[]T` does.
            .slice => |p| if (at == .slice)
                try self.bindArg(inf, p.elem, at.slice.elem, arg, depth + 1)
            else if (sema.writeSliceElem(self.ctx, actual)) |elem|
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else if (sema.lentElem(self.ctx, actual)) |elem|
                // An array or a List lent as a slice (`?a`, `!v`, a
                // temporary).
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else
                self.noteMismatch(inf, pattern, actual, arg),
            .array => |p| if (at == .array) {
                inf.exact += 1;
                defer inf.exact -= 1;
                try self.bindArg(inf, p.elem, at.array.elem, arg, depth + 1);
                try self.bindArg(inf, p.len, at.array.len, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            .simd => |p| if (at == .simd) {
                inf.exact += 1;
                defer inf.exact -= 1;
                try self.bindArg(inf, p.elem, at.simd.elem, arg, depth + 1);
                try self.bindArg(inf, p.len, at.simd.len, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            // A value parameter binds exactly the value (or parameter)
            // the argument's type holds there: an array length, or a
            // generic type's value argument.
            .ct_param => |p| {
                const i = std.mem.findScalar(SymbolId, inf.own, p) orelse return;
                if (at != .ct_value and at != .ct_param) return;
                const b = &inf.bound[i];
                if (b.ty == sema.type_invalid) {
                    b.ty = actual;
                    b.arg = arg;
                } else if (b.ty != actual and b.conflict == sema.type_invalid) {
                    b.conflict = actual;
                    b.conflict_arg = arg;
                }
            },
            .parameterized_nominal => |pn| if (self.sameGeneric(at, pn.sym)) |held| {
                inf.exact += 1;
                defer inf.exact -= 1;
                for (pn.args, held.args) |pa, aa| try self.bindArg(inf, pa, aa, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            // What a callable view lends: a closure's, a function's,
            // or an owned closure's function type.
            .callable => |pf| switch (at) {
                .callable, .shared => |inner| try self.bindArg(inf, pf, inner, arg, depth + 1),
                .function => try self.bindArg(inf, pf, actual, arg, depth + 1),
                else => self.noteMismatch(inf, pattern, actual, arg),
            },
            .function => |pf| if (at == .function and at.function.params.len == pf.params.len) {
                inf.exact += 1;
                defer inf.exact -= 1;
                for (pf.params, at.function.params) |pp, ap| try self.bindArg(inf, pp, ap, arg, depth + 1);
                try self.bindArg(inf, pf.returns, at.function.returns, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            else => {},
        }
    }

    /// The instance of generic type `sym` that an argument of type `at`
    /// is, or that the handle it is lends: `*Cell[T]` where `!Cell[T]`
    /// goes.
    fn sameGeneric(self: *Checker, at: sema.Type, sym: SymbolId) ?sema.ParamNominal {
        switch (at) {
            .parameterized_nominal => |p| if (p.sym == sym) return p,
            .shared => |inner| switch (self.ctx.types.get(inner)) {
                .parameterized_nominal => |p| if (p.sym == sym) return p,
                else => {},
            },
            else => {},
        }
        return null;
    }

    /// Values Zig can evaluate at compile time.
    fn isComptimeKnown(self: *Checker, e: Sexp) bool {
        switch (e) {
            .src => {
                const s = self.text(e);
                if (isLiteralText(s) or std.mem.eql(u8, s, "none")) return true;
                const id = self.ctx.symbolOf(e) orelse (self.lookupQuiet(e) orelse return false);
                return self.ctx.symbols.items[id].flags.comptime_known;
            },
            .list => {
                const h = e.kind() orelse return false;
                return switch (h) {
                    .enum_lit => true,
                    .builtin => std.mem.eql(u8, self.text(ir.Builtin.name(e)), "variants"),
                    .not => self.isComptimeKnown(ir.get(e, .operand)),
                    .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or" => self.isComptimeKnown(ir.get(e, .left)) and self.isComptimeKnown(ir.get(e, .right)),
                    // Rig checks arithmetic only on constants: a compile-time
                    // parameter or a `=!` binding of one differs per call.
                    .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => self.constInt(e) != null or (self.isCtArithmetic(e) and !self.mentionsCtLocal(e)),
                    .member => blk: {
                        const obj = ir.Member.object(e);
                        // A number type's limits.
                        if (self.namesNumberType(obj)) break :blk true;
                        // `lib.Mode.a`: a variant of an imported type.
                        if (obj.isKind(.member)) {
                            const foreign = self.foreignMember(obj) orelse break :blk false;
                            break :blk foreign.kind == .nominal_type;
                        }
                        if (obj != .src) break :blk false;
                        const id = self.lookupQuiet(obj) orelse break :blk false;
                        const sym = self.ctx.symbols.items[id];
                        if (sym.kind != .module) break :blk sym.kind == .nominal_type;
                        // An imported module's constant.
                        const foreign = self.foreignMember(e) orelse break :blk false;
                        break :blk foreign.flags.comptime_known;
                    },
                    else => false,
                };
            },
            else => return false,
        }
    }

    /// Whether `obj` names a number type: a built-in one, or an alias of
    /// one in this module or an imported one.
    fn namesNumberType(self: *Checker, obj: Sexp) bool {
        if (obj.isKind(.member)) {
            const m = ir.Member.object(obj);
            if (m != .src) return false;
            const id = self.lookupQuiet(m) orelse return false;
            if (self.ctx.symbols.items[id].kind != .module) return false;
            const found = self.foreignLookup(id, self.text(ir.Member.name(obj))) orelse return false;
            return found.sym.kind == .type_alias and sema.isNumeric(found.ctx, found.sym.ty);
        }
        if (obj != .src) return false;
        const id = self.lookupQuiet(obj) orelse return resolve.isNumericTypeName(self.text(obj));
        const sym = self.ctx.symbols.items[id];
        return sym.kind == .type_alias and sema.isNumeric(self.ctx, sym.ty);
    }

    /// The symbol `module.name` names in an imported module.
    fn foreignMember(self: *Checker, e: Sexp) ?sema.Symbol {
        const m = ir.Member.object(e);
        if (m != .src) return null;
        const id = self.lookupQuiet(m) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        return (self.foreignLookup(id, self.text(ir.Member.name(e))) orelse return null).sym;
    }

    /// Arithmetic whose operands are each known at compile time.
    fn isCtArithmetic(self: *Checker, e: Sexp) bool {
        const h = e.kind() orelse return false;
        return switch (h) {
            .neg => self.isCtOperand(ir.Neg.operand(e)),
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => self.isCtOperand(ir.get(e, .left)) and self.isCtOperand(ir.get(e, .right)),
            else => false,
        };
    }

    /// An operand of compile-time arithmetic: a value known at compile
    /// time, or arithmetic on such values. (Each node is classified
    /// once: `isComptimeKnown` of arithmetic would classify it again.)
    fn isCtOperand(self: *Checker, o: Sexp) bool {
        if (!isArithmetic(o)) return self.isComptimeKnown(o);
        return self.isCtArithmetic(o) or self.constInt(o) != null;
    }

    /// Whether `e` names a compile-time parameter or a `=!` binding in a
    /// function, whose value differs from call to call.
    fn mentionsCtLocal(self: *Checker, e: Sexp) bool {
        return switch (e) {
            .src => {
                const id = self.ctx.symbolOf(e) orelse return false;
                const sym = self.ctx.symbols.items[id];
                return sym.flags.comptime_known and sym.scope != self.module_scope;
            },
            .list => for (e.items()) |c| {
                if (self.mentionsCtLocal(c)) break true;
            } else false,
            else => false,
        };
    }

    /// Construct a struct (`User(name: ...)`). Field types go through
    /// `subst` (generic constructors) or are imported from `foreign`.
    fn construct(self: *Checker, sym_id: SymbolId, args: []const Sexp, pos: u32, subst: TypeSubst, foreign: ?ForeignFields) Error!TypeId {
        const sym = if (foreign) |fo| fo.ctx.symbols.items[sym_id] else self.ctx.symbols.items[sym_id];
        const result = if (foreign) |fo|
            try self.ctx.intern(.{ .imported_nominal = .{ .module_id = fo.module_id, .sym_id = sym_id } })
        else if (subst.isEmpty())
            try self.ctx.intern(.{ .nominal = sym_id })
        else
            try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = subst.args } });
        const fields = sym.fields orelse return self.badCall(args, pos, "opaque type `{s}` cannot be constructed", .{sym.name});
        const is_enum = for (fields) |f| {
            if (f.is_variant) break true;
        } else false;
        if (is_enum) return self.badCall(args, pos, "`{s}` is an enum; construct a variant with `{s}.name` or `.name(...)`", .{ sym.name, sym.name });
        // `T()` of a type whose every field has a default makes the value
        // those defaults give, which the type itself chose: any module
        // may make one.
        if (!(args.len == 0 and everyFieldDefaulted(fields))) try self.checkConstructible(sym, fields, if (foreign) |fo| fo.module_id else null, pos, args.len == 0);
        const origin = if (sema.isProxy(sym)) sema.proxyOrigin(self.ctx, sym) else null;
        try self.checkFieldArgs(args, fields, .{
            .owner = sym.name,
            .decl_pos = if (origin) |o| o.pos else sym.decl_pos,
            .module_id = if (origin) |o| o.module_id else 0,
            .pos = pos,
            .subst = subst,
            .foreign = foreign,
            .kind = .constructor,
            .instance = result,
        });
        return result;
    }

    /// Whether every data field of a type has a default, so `T()` makes
    /// a value (variants and methods are no fields).
    fn everyFieldDefaulted(fields: []const Field) bool {
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            if (f.default == null) return false;
        }
        return true;
    }

    /// Another module's object is constructed here only when every one
    /// of its fields is `pub`; a private field is that module's to set.
    /// (`T()` of a type whose every field has a default is made anywhere:
    /// `construct`.) `empty` is a call with no arguments, which names the
    /// fields with no default.
    fn checkConstructible(self: *Checker, sym: sema.Symbol, fields: []const Field, module: ?u32, pos: u32, empty: bool) Error!void {
        const m = module orelse if (sema.isProxy(sym)) sym.from.module_id else return;
        const foreign = self.ctx.foreign_semas.get(m) orelse return;
        var private: std.ArrayList(u8) = .empty;
        defer private.deinit(self.ctx.allocator);
        var count: usize = 0;
        // A read-only field (`pub ?name: T`) is set by its module only,
        // as a private one is.
        var read_only: usize = 0;
        for (fields) |f| {
            if (f.is_method or f.is_variant or (f.is_pub and !f.read_only)) continue;
            try private.appendSlice(self.ctx.allocator, if (count == 0) "`" else ", `");
            try private.appendSlice(self.ctx.allocator, f.name);
            try private.append(self.ctx.allocator, '`');
            count += 1;
            if (f.read_only) read_only += 1;
        }
        if (count == 0) return;
        const tname = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, sym.name }) else sym.name;
        const kind = if (read_only == 0) "private" else if (read_only == count) "read-only" else "private or read-only";
        const which = .{ if (count == 1) "field" else "fields", private.items, if (count == 1) "is" else "are", kind };
        if (empty) {
            // `T()` makes an empty value only from defaults for every field.
            var bare: std.ArrayList(u8) = .empty;
            defer bare.deinit(self.ctx.allocator);
            var n: usize = 0;
            for (fields) |f| {
                if (f.is_method or f.is_variant or f.default != null) continue;
                try bare.appendSlice(self.ctx.allocator, if (n == 0) "`" else ", `");
                try bare.appendSlice(self.ctx.allocator, f.name);
                try bare.append(self.ctx.allocator, '`');
                n += 1;
            }
            try self.err(pos, "`{s}()` makes a `{s}` from its fields' defaults, and {s} {s} no default; its {s} {s} {s} {s} to module `{s}`, which alone can set {s}", .{ tname, tname, bare.items, if (n == 1) "has" else "have" } ++ which ++ .{ foreign.name, if (count == 1) "it" else "them" });
        } else if (foreign.is_std) {
            try self.err(pos, "only the standard library's module `{s}` can construct `{s}`: its {s} {s} {s} {s}; make one with its `pub` functions", .{ foreign.name, tname } ++ which);
        } else if (read_only == count) {
            try self.err(pos, "only module `{s}` can construct `{s}`: its {s} {s} {s} {s}; make the value with `{s}()` if every field has a default, or with a `pub` function of `{s}`", .{ foreign.name, tname } ++ which ++ .{ tname, foreign.name });
        } else try self.err(pos, "only module `{s}` can construct `{s}`: its {s} {s} {s} {s}; declare every field `pub` there, or make the value with a `pub` function of `{s}`", .{ foreign.name, tname } ++ which ++ .{foreign.name});
        for (fields) |f| {
            if (f.is_method or f.is_variant or (f.is_pub and !f.read_only) or f.decl_pos >= sema.imported_decl_pos) continue;
            try self.ctx.noteIn(m, f.decl_pos, "`{s}` declared here", .{f.name});
        }
    }

    const ForeignFields = struct { ctx: *SemContext, module_id: u32 };

    const FieldArgs = struct {
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

    /// Keyword arguments against named fields: each names a real field
    /// once, and every field without a default is given. A type or
    /// variant with one field also takes it positionally: `Wrap(x)`,
    /// `.some(7)`.
    fn checkFieldArgs(self: *Checker, args: []const Sexp, fields: []const Field, info: FieldArgs) Error!void {
        const noun = if (info.kind == .constructor) "constructor of" else "variant";
        const saved_slot = self.slot;
        defer self.slot = saved_slot;
        self.slot = try self.fieldSlot(info, args, fields);
        const saved_home = self.cell_home;
        defer self.cell_home = saved_home;
        // A built-in generic's value (a List's, box's, or Cell's) is no
        // field a Cell may be made in.
        const homes = switch (self.ctx.types.get(info.instance)) {
            .parameterized_nominal => |pn| !sema.isBuiltinGeneric(self.ctx, pn.sym),
            else => true,
        };
        if (args.len == 1 and !args[0].isKind(.kwarg)) {
            if (soleField(fields)) |f| {
                const ty = try self.fieldType(f, info);
                self.slot.value = args[0];
                self.slot.declared = f.ty;
                self.cell_home = if (homes) args[0] else .nil;
                try self.checkExpr(args[0], ty);
                return self.checkLendsVisibly(args[0], ty, "the field writes through");
            }
        }
        for (args) |a| {
            if (a.isKind(.kwarg)) continue;
            if (info.kind == .variant) {
                const first = for (fields) |f| {
                    if (!f.is_method and !f.is_variant) break f.name;
                } else "field";
                if (soleField(fields) != null) {
                    try self.err(info.pos, "variant `{s}` has one field: write `.{s}(value)` or `.{s}({s}: value)`", .{ info.owner, info.owner, info.owner, first });
                } else {
                    try self.err(info.pos, "a variant with more than one field sets them by name: `.{s}({s}: ...)`", .{ info.owner, first });
                }
            } else try self.positionalFieldsError(fields, info.owner, info.pos);
            try self.synthArgs(args);
            return;
        }
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        defer seen.deinit(self.ctx.allocator);
        // The fields an unknown name was likely meant as, which are not
        // reported missing too.
        var meant: std.StringHashMapUnmanaged(void) = .empty;
        defer meant.deinit(self.ctx.allocator);
        for (args) |a| {
            const value = ir.Kwarg.value(a);
            const fname = self.text(ir.Kwarg.name(a));
            const fpos = ir.Kwarg.name(a).src.pos;
            if (seen.get(fname)) |first| {
                try self.err(fpos, "duplicate field `{s}` in {s} `{s}`", .{ fname, noun, info.owner });
                try self.note(first, "first `{s}` here", .{fname});
                _ = try self.synthExpr(value);
                continue;
            }
            try seen.put(self.ctx.allocator, fname, fpos);
            const f = (try findDataField(self.ctx, fields, fname)) orelse {
                const likely = memberSuggest(fields, fname, .field);
                if (likely.best) |b| try meant.put(self.ctx.allocator, b, {});
                try self.err(fpos, "no field `{s}` on {s} `{s}`{s}", .{ fname, if (info.kind == .constructor) "type" else "variant", info.owner, try likely.hint(self.ctx.arena.allocator()) });
                if (info.foreign == null and info.decl_pos < sema.imported_decl_pos and info.decl_pos != 0) try self.ctx.noteIn(info.module_id, info.decl_pos, "`{s}` declared here", .{info.owner});
                _ = try self.synthExpr(value);
                continue;
            };
            const ty = try self.fieldType(f, info);
            self.slot.value = value;
            self.slot.declared = f.ty;
            self.cell_home = if (homes) value else .nil;
            try self.checkExpr(value, ty);
            try self.checkLendsVisibly(value, ty, "the field writes through");
        }
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.default != null or seen.contains(f.name) or meant.contains(f.name)) continue;
            try self.err(info.pos, "{s} `{s}` is missing field `{s}`", .{ noun, info.owner, f.name });
            if (info.foreign == null and f.decl_pos < sema.imported_decl_pos) try self.ctx.noteIn(info.module_id, f.decl_pos, "field `{s}` declared here", .{f.name});
        }
    }

    /// The slot each field of a construction fills (`Slot`): the call,
    /// and what it makes as written.
    fn fieldSlot(self: *Checker, info: FieldArgs, args: []const Sexp, fields: []const Field) Error!Slot {
        const call = if (info.call != .nil) info.call else self.current_call orelse return .{ .field = true, .owner = info.owner };
        const callee = ir.Call.callee(call);
        var slot: Slot = .{
            .call = call,
            .owner = self.sourceText(callee),
            .field = true,
            .subst = info.subst,
        };
        // The fields each argument fills, and their types.
        const a = self.ctx.arena.allocator();
        const values = try a.alloc(Sexp, args.len);
        const types = try a.alloc(TypeId, args.len);
        for (args, values, types) |arg, *v, *ty| {
            v.* = .nil;
            ty.* = sema.type_invalid;
            const f = if (arg.isKind(.kwarg)) try findDataField(self.ctx, fields, self.text(ir.Kwarg.name(arg))) else if (args.len == 1) soleField(fields) else null;
            const field = f orelse continue;
            v.* = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
            ty.* = try self.fieldType(field, info);
        }
        slot.lends = try self.plainSlotLends(values, types);
        return slot;
    }

    /// A constructor given positional arguments it cannot take: a type
    /// with one field takes exactly one, alone; one with more sets them
    /// by name.
    fn positionalFieldsError(self: *Checker, fields: []const Field, owner: []const u8, pos: u32) Error!void {
        var count: usize = 0;
        var first: []const u8 = "field";
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            if (count == 0) first = f.name;
            count += 1;
        }
        switch (count) {
            0 => try self.err(pos, "`{s}` has no fields: `{s}()`", .{ owner, owner }),
            1 => try self.err(pos, "`{s}` has one field, given by position alone (`{s}(x)`) or by name (`{s}({s}: x)`)", .{ owner, owner, owner, first }),
            else => try self.err(pos, "a type with more than one field sets them by name: `{s}({s}: ...)`", .{ owner, first }),
        }
    }

    /// A variant payload's one field, when it has exactly one.
    fn soleField(fields: []const Field) ?Field {
        var found: ?Field = null;
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            if (found != null) return null;
            found = f;
        }
        return found;
    }

    fn fieldType(self: *Checker, f: Field, info: FieldArgs) Error!TypeId {
        if (info.foreign != null) return self.memberType(info.foreign, f.ty);
        return sema.substituteType(self.ctx, f.ty, info.subst);
    }

    /// A member type as the declaration of a type spells it, in this
    /// module's types: imported when the type is `foreign`.
    fn memberType(self: *Checker, foreign: ?ForeignFields, ty: TypeId) Error!TypeId {
        const fo = foreign orelse return ty;
        return sema.importType(self.ctx, fo.ctx, ty, fo.module_id);
    }

    // ---- method calls -----------------------------------------------------------

    /// `obj.name(args)`, a call whose callee is `(member obj name)`; the
    /// callee node's type is the resolved method's signature. `ct` is
    /// the bracket list of `obj.name[...](args)`, compile-time arguments
    /// for a method, or the index of an element of a field holding
    /// functions.
    fn synthMemberCall(self: *Checker, callee: Sexp, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const saved = self.callee_node;
        self.callee_node = callee;
        defer self.callee_node = saved;
        var obj = ir.Member.object(callee);
        const saved_in_place = self.in_place;
        defer self.in_place = saved_in_place;
        self.in_place = obj;
        const name_node = ir.Member.name(callee);
        const method = self.text(name_node);
        const pos = srcPos(name_node, self.startOf(obj));

        // `<Point.origin()`: a function called through its type or module
        // has no receiver for the sigil to apply to.
        var misreached: ?Sexp = null;
        if (self.isReceiverSigil(obj)) {
            const place = ir.get(obj, .operand);
            if ((try self.moduleNamed(place)) != null or (try self.namedType(place)) != null) {
                if (obj.isKind(.read)) {
                    try self.errAt(obj, "`{s}` is called through its type or module and has no receiver; to lend the call's result, write `?({s})`", .{ method, try self.callWith(obj, self.sourceText(place), method) });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                // `!lib.mk().bump()`: the `!` meant for the value the call
                // makes reaches the module or type instead, reported once
                // the call's type is known.
                if (obj.isKind(.write)) misreached = obj else try self.misplacedSigil(obj, method, "is called through its type or module and has no receiver");
                obj = place;
            }
        }
        if (try self.moduleNamed(obj)) |id| return self.misreachedWrite(misreached, obj, method, try self.crossModuleCall(id, method, pos, args, ct));
        if (try self.simdNamed(obj)) |vt| return self.misreachedWrite(misreached, obj, method, try self.simdTypeCall(callee, vt, method, pos, args, ct));
        if (try self.numberType(obj)) |nty| return self.misreachedWrite(misreached, obj, method, try self.numberTypeCall(callee, obj, nty, method, pos, args, ct));
        if (try self.namedType(obj)) |nt| return self.misreachedWrite(misreached, obj, method, try self.associatedCall(obj, nt, method, pos, args, ct));

        // A consuming (`<self`) method may take a temporary, and a
        // `?self` one reads it where it stands; a `!self` one needs it
        // lent to write, `!mk().m()`, which keeps it in its statement's
        // slot.
        const saved_receiver = self.receiver_obj;
        self.receiver_obj = obj;
        const obj_ty = try self.synthExpr(obj);
        self.receiver_obj = saved_receiver;
        if (self.isPoison(obj_ty)) {
            try self.synthArgs(args);
            return obj_ty;
        }

        if (try self.elemsCall(callee, obj, obj_ty, method, pos, args, ct)) |ty| return self.noteMethod(callee, if (std.meta.stringToEnum(sema.ElemOp, method) == .read) .read else .write, ty);
        if (try self.stringCall(callee, obj, obj_ty, method, pos, args, ct)) |ty| return self.noteMethod(callee, .write, ty);
        if (ct == null) if (try self.bitCall(callee, obj, obj_ty, method, pos, args)) |ty| return self.noteMethod(callee, .value, ty);
        if (try self.simdCall(callee, obj, obj_ty, method, pos, args, ct)) |ty| return self.noteMethod(callee, .value, ty);
        const resolved_method = try self.findMethod(obj_ty, method);
        // `x.hash()`, unless the type declares a `hash` of its own.
        if (resolved_method == null and ct == null and std.mem.eql(u8, method, "hash") and !try self.hasDataField(obj_ty, method)) return self.hashCall(callee, obj, obj_ty, pos, args);
        // `x.f[i](args)` where `f` is a field: its element is called.
        if (ct != null and resolved_method == null) {
            const field_ty = try self.memberOf(callee, obj, obj_ty);
            try self.ctx.recordType(callee, field_ty);
            const elem_ty = try self.indexInto(ct.?, field_ty);
            try self.ctx.recordType(ct.?, elem_ty);
            if (self.isReceiverSigil(obj)) {
                try self.fieldCallSigil(obj, method, "a field holding functions", elem_ty);
            } else try self.rejectResourceTemporary(obj, obj_ty);
            return self.callValue(ct.?, elem_ty, args, self.sourceText(ct.?));
        }

        // A weak handle upgrades with `*w`, a shared handle has nothing to
        // upgrade, and an object's own `upgrade` is called as any method.
        if (std.mem.eql(u8, method, "upgrade")) {
            switch (self.ctx.types.get(sema.unwrapViews(self.ctx, obj_ty))) {
                .weak => {
                    const shown = try self.plainText(stripSigil(obj));
                    return self.badCall(args, pos, "a weak handle upgrades with `*{s}`, not a method: `if *{s} as s`", .{ shown, shown });
                },
                .shared => if (!sema.hasMethodNamed(self.ctx, obj_ty, method)) {
                    return self.badCall(args, pos, "a shared handle `{s}` is already counted, and has no `upgrade`; a weak handle `w` of one (`~h`) upgrades with `*w`", .{try self.tyName(sema.unwrapViews(self.ctx, obj_ty))});
                },
                else => {},
            }
        }

        const peeled = sema.unwrapAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .optional => return self.badCall(args, pos, "cannot call `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ method, try self.tyName(peeled) }),
            .type_var => return self.badCall(args, pos, "a generic parameter `{s}` has no methods; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) }),
            else => {},
        }

        if (cellListElement(self.ctx, obj_ty)) |elem| if (try self.cellListCall(callee, obj, obj_ty, elem, pos, args)) |ty| {
            const mode: MethodReceiver = if (std.mem.eql(u8, method, "get")) .read else .write;
            if (mode == .read and self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "only reads the Cell");
            return self.noteMethod(callee, mode, ty);
        };
        if (resolved_method == null and std.mem.eql(u8, method, "get")) if (try self.sequenceGet(obj_ty, pos, args)) |ty| {
            _ = try self.checkReceiverSigil(obj, .read, ty, method);
            return self.noteMethod(callee, .read, ty);
        };

        if (resolved_method == null and std.mem.eql(u8, method, "is_empty") and self.hasBuiltinLen(peeled)) {
            const f: FunctionType = .{
                .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .read_view = sema.unwrapViews(self.ctx, obj_ty) })}),
                .returns = self.t().bool_id,
                .is_sub = false,
            };
            try self.noteCallee(f);
            try self.checkArgs(args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = false }, .{}, "is_empty", pos, .{ .receiver = true });
            _ = try self.checkReceiverSigil(obj, .read, f.returns, method);
            return self.noteMethod(callee, .read, f.returns);
        }

        const resolved = resolved_method orelse {
            // A data field holding a function or a closure handle is
            // called like one.
            if (try self.dataField(obj_ty, method, pos, .nil)) |ty| {
                if (sema.ownedClosureFn(self.ctx, ty) != null or self.ctx.types.get(ty) == .function) {
                    if (self.isReceiverSigil(obj)) {
                        try self.fieldCallSigil(obj, method, "a field holding a function", ty);
                    } else try self.rejectResourceTemporary(obj, obj_ty);
                    try self.noteCalleeType(ty);
                    return self.callValue(callee, ty, args, method);
                }
                // An optional function is taken out of its optional first.
                const inner = switch (self.ctx.types.get(ty)) {
                    .optional => |o| o,
                    else => sema.type_invalid,
                };
                if (inner != sema.type_invalid and (sema.ownedClosureFn(self.ctx, inner) != null or self.ctx.types.get(inner) == .function)) {
                    try self.err(pos, "field `{s}` holds an optional function, `{s}`: take the function out first, `if {s}.{s} as g`, then call `g(...)`", .{ method, try self.tyName(ty), try self.plainText(stripSigil(obj)), method });
                    return self.skipCall(args);
                }
                // A data field is read, not called: `m.len`, not `m.len()`.
                if (!self.isPoison(ty)) {
                    try self.err(pos, "`{s}` is a field of `{s}`, not a method: write `{s}.{s}`", .{ method, try self.tyName(peeled), try self.plainText(stripSigil(obj)), method });
                    return self.skipCall(args);
                }
            }
            const has_len = listElementType(self.ctx, peeled) != null or switch (self.ctx.types.get(peeled)) {
                .string_view, .static, .array, .slice => true,
                else => false,
            };
            if (listElementType(self.ctx, peeled) != null and std.mem.eql(u8, method, "length")) {
                try self.err(pos, "a List has no `length()`; its length is `.len`, as for an array: `v.len`", .{});
            } else if (has_len and std.mem.eql(u8, method, "len")) {
                try self.err(pos, "no method `len` on type `{s}`; `len` is a field: write `{s}.len`", .{ try self.tyName(peeled), try self.plainText(stripSigil(obj)) });
            } else if (std.mem.eql(u8, method, "text") and self.hasVariantNames(peeled)) {
                try self.err(pos, "no method `text` on type `{s}`; a variant's name is a member, read without a call: `{s}.text`", .{ try self.tyName(peeled), try self.plainText(stripSigil(obj)) });
            } else if (sema.nominalDecl(self.ctx, peeled)) |decl| {
                const sym = decl.symbol();
                try self.err(pos, "no method `{s}` on type `{s}`{s}", .{ method, sym.name, try self.memberHint(sym.fields orelse &.{}, method, .method) });
                try self.noteDeclared(sym, decl.module_id == null);
            } else if (self.ctx.types.get(peeled) == .weak) {
                try self.weakReach(obj, peeled, pos);
            } else {
                try self.err(pos, "type `{s}` has no method `{s}`", .{ try self.tyName(obj_ty), method });
            }
            return self.skipCall(args);
        };
        const receiver = resolved.field.receiver;
        _ = try self.noteMethod(callee, receiver, resolved.fn_ty.returns);
        try self.noteCallee(resolved.fn_ty);
        const misplaced_sigil = receiver != .none and try self.checkReceiverSigil(obj, receiver, resolved.fn_ty.returns, method);
        switch (receiver) {
            .value => try self.recordUse(obj, .take),
            .write => try self.recordUse(stripSigil(obj), .lend),
            .read, .none => {},
        }
        // (A write method on a value made here with no `!` is reported
        // as such: `checkReceiverMode`.)
        if (receiver == .read and !misplaced_sigil and !self.hands(obj).hasStorage()) {
            try self.readLeaf(obj);
        } else if (receiver != .value and !misplaced_sigil and !(receiver == .write and self.hands(obj).kind == .made)) try self.rejectResourceTemporary(obj, obj_ty);

        try self.checkVisible(resolved.field, resolved.owner_sym, resolved.module, pos);

        if (receiver == .none) {
            // A `self` without a sigil was reported where it is declared.
            const names = resolved.field.param_names orelse &.{};
            if (names.len == 0 or !std.mem.eql(u8, names[0], "self")) {
                try self.err(pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{ method, resolved.owner, method });
            }
            try self.synthArgs(args);
            return resolved.fn_ty.returns;
        }
        if (!misplaced_sigil) {
            const saved_of = self.receiver_of;
            defer self.receiver_of = saved_of;
            self.receiver_of = callee;
            try self.checkReceiverMode(obj, receiver, classifyReceiverType(self.ctx, obj_ty, resolved.nominal_sym), method, pos, resolved.fn_ty.returns);
        }
        const info = methodParams(resolved.field, true, resolved.source);
        const f = (try self.instantiateCall(resolved.fn_ty, ct, args, info, 1, method, pos, false, self.receiverArgs(obj_ty))) orelse return self.skipCall(args);
        // The type's parameters are bound by the object the receiver
        // reaches, through views, handles, and boxes, as the method was
        // found.
        try self.noteMethodTarget(resolved.field, resolved.owner_sym, resolved.module, self.receiverArgs(sema.unwrapAccess(self.ctx, obj_ty)));
        if (!try self.meetsNeeds(resolved.field, resolved.nominal_sym, resolved.args, pos)) return self.skipCall(args);
        if (sema.isGenericFn(self.ctx, resolved.fn_ty)) try self.noteCallee(f);
        const rest: FunctionType = .{
            .params = f.params[1..],
            .returns = f.returns,
            .is_sub = f.is_sub,
        };
        // A `?self` or `!self` method that may keep a view of a temporary
        // receiver, in its result or through a write argument, lends it
        // as `?e` does: the value it is part of is kept in its statement's
        // slot until the statement ends, where the view may still be used.
        // So is a value that branches which is read as a copy, not where
        // its leaves are (`sema.readByAddress`): plain data.
        if ((receiver == .read or receiver == .write) and !misplaced_sigil and !obj.isKind(.read)) {
            const lent = stripSigil(obj);
            const base = if (self.hands(lent).kind == .part_of_made) self.placeOf(lent).base else lent;
            const copied = switch (self.hands(base).kind) {
                .made => true,
                .branches => if (self.ctx.typeOf(base)) |ty| !sema.readByAddress(self.ctx, ty) else false,
                else => false,
            };
            if (copied and self.isTemporary(lent) and (sema.mayHoldView(self.ctx, f.returns) or self.callRetains(rest, f.params[0]))) try self.lendTemp(lent);
        }
        self.lend_call = true;
        self.lend_recv = f.params[0];
        const mark = self.ctx.diagnostics.items.len;
        try self.checkArgs(args, rest, info, method, pos, .{ .receiver = true, .origins = resolved.field.origins, .declared = self.declaredParams(resolved.field, resolved.module, 1) orelse resolved.fn_ty.params[1..] });
        // A receiver the method keeps is lent with `?` written (Core
        // sentence 4).
        const o = resolved.field.origins;
        if (receiver == .read and !misplaced_sigil and self.ctx.diagnostics.items.len == mark and o.stores & o.lent & sema.paramBit(0) != 0 and self.implicitReceiver(obj)) {
            if (self.current_call) |call| try self.reportKept(call, obj, true, .{ .stored = method });
        }
        return f.returns;
    }

    /// Record the call being checked (`current_call`) as a call of the
    /// Rig function or method declared at `pos` in module `module`
    /// (`sema.CallTarget`): the one fact of what a call reaches, which
    /// `inlining.decide` reads. A built-in declares none. A call of a
    /// function marked `inline` also records the instance it makes
    /// (`sema.InlineCall`): its type's parameters bound by `recv`, then
    /// its own (`inst_own`, so this runs after `instantiateCall`), which
    /// the frame check lands its values at (`FrameWalker.addInlined`).
    fn noteTarget(self: *Checker, module: u32, pos: u32, marked: bool, recv: TypeSubst) Error!void {
        const call = self.current_call orelse return;
        if (pos >= sema.imported_decl_pos) return;
        const fun: sema.FnRef = .{ .module = module, .pos = pos };
        try self.ctx.recordCallTarget(call, .{ .function = fun });
        if (!marked) return;
        const a = self.ctx.arena.allocator();
        try self.ctx.recordInlineCall(call, .{ .fun = fun, .subst = .{
            .params = try std.mem.concat(a, SymbolId, &.{ recv.params, self.inst_own.params }),
            .args = try std.mem.concat(a, TypeId, &.{ recv.args, self.inst_own.args }),
        } });
    }

    /// `noteTarget` for the method `field` of the type `owner`, declared
    /// in module `module` (null for this one), or, for a proxy of
    /// another module's generic type, in the module the proxy stands for.
    fn noteMethodTarget(self: *Checker, field: Field, owner: sema.Symbol, module: ?u32, recv: TypeSubst) Error!void {
        if (owner.decl_pos == sema.builtin_decl_pos) return;
        const declared = module orelse if (sema.isProxy(owner)) owner.from.module_id else self.ctx.module_id;
        try self.noteTarget(declared, field.decl_pos, field.inline_marked, recv);
    }

    /// Records `callee` as the member a call resolved as a method, which
    /// takes its receiver as `receiver` and returns `returns`: its object
    /// is the receiver, no path's base (`checkLendBases`). Returns
    /// `returns`.
    fn noteMethod(self: *Checker, callee: Sexp, receiver: sema.MethodReceiver, returns: TypeId) Error!TypeId {
        if (callee == .list) try self.methods.put(self.ctx.allocator, nodeId(callee), .{ .receiver = receiver, .returns = returns });
        return returns;
    }

    /// `sigil`, a `!` the receiver-sigil rule moved onto `place`, a module
    /// or type through which a function is called, so it reaches no
    /// value: reported, with the form that lends the value the call
    /// makes (of type `ty`), or, before a `Bool`, the habit of `!` as
    /// negation (as `fieldCallSigil` does). `ty` when there is none.
    fn misreachedWrite(self: *Checker, sigil: ?Sexp, place: Sexp, method: []const u8, ty: TypeId) Error!TypeId {
        const s = sigil orelse return ty;
        const what = if ((try self.moduleNamed(place)) != null) "a module" else "a type";
        const shown = try self.plainText(place);
        const value = if (self.ctx.types.get(ty) == .fallible) self.ctx.types.get(ty).fallible else ty;
        const call = try self.callWith(s, shown, method);
        if (value == self.t().bool_id) {
            try self.errAt(s, "`!` here reaches `{s}`, {s}, and `{s}` makes a `Bool`; for negation use `not`", .{ shown, what, call });
        } else try self.errAt(s, "`!` here reaches `{s}`, {s}, not the value `{s}` makes: write `!({s})` to lend that value, or remove the `!`", .{ shown, what, call, call });
        return self.t().invalid_id;
    }

    /// `copy`, `fill`, and `swap`: built-in methods on the elements of a
    /// slice, an array, or a List, which write them in place; and `read`
    /// and `write` on bytes (`bytesCall`). Null when `method` is none of
    /// them or the receiver has no elements.
    fn elemsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        if (op.isBits() or op.isSimd() or op.isTypeFn() or op == .hash) return null;
        const peeled = sema.unwrapViews(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .slice => |sl| sl.elem,
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            .string_view, .static => try self.byteType(),
            else => listElementType(self.ctx, peeled) orelse return null,
        };
        if (obj.isKind(.move) and self.isReceiverSigil(obj)) {
            try self.misplacedSigil(obj, method, "does not consume its receiver");
            return try self.skipCall(args);
        }
        if (op == .read or op == .write) return try self.bytesCall(callee, obj, obj_ty, elem, len, op, pos, args, ct);
        if (ct) |b| return try self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});
        if (!try self.writesElements(obj, obj_ty, peeled, method)) return try self.skipCall(args);
        if (op != .swap and try self.cannotCopy(elem, pos, "copies into the elements a value")) {
            if (op == .fill) {
                try self.notDuplicated(pos, "`fill` copies its value into every element", elem, "`for i in 0..xs.len` with `xs[i] = +x`", "");
            } else try self.notDuplicated(pos, "`copy` copies every element of its source", elem, "`for i in 0..src.len` with `xs[i] = +src[i]`", "");
            return try self.skipCall(args);
        }
        for (args) |a| if (a.isKind(.kwarg)) return try self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        const want: usize = if (op == .swap) 2 else 1;
        if (args.len != want) return try self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, switch (op) {
            .copy => "one argument, the `[]T` to copy from",
            .fill => "one argument, the value for every element",
            .swap => "two arguments, the indexes of the elements to swap",
            .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag, .hash => unreachable,
        }, args.len, if (args.len == 1) "" else "s" });
        const recv = try self.ctx.intern(.{ .write_view = peeled });
        const params: []const TypeId = switch (op) {
            .copy => &.{ recv, try self.ctx.intern(.{ .slice = .{ .elem = elem } }) },
            .fill => &.{ recv, elem },
            .swap => &.{ recv, self.t().int_id, self.t().int_id },
            .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag, .hash => unreachable,
        };
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(params), .returns = self.t().void_id, .is_sub = true });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem });
        switch (op) {
            // `copy` keeps nothing of its source: a temporary array may
            // be lent as it.
            .copy => {
                const saved = self.lent_temp;
                defer self.lent_temp = saved;
                self.lent_temp = args[0];
                try self.checkExpr(args[0], params[1]);
            },
            .fill => try self.checkExpr(args[0], params[1]),
            .swap => for (args) |a| try self.checkIndexArg(a, len),
            .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag, .hash => unreachable,
        }
        return self.t().void_id;
    }

    /// `bytes.read[T, e](at)` and `!bytes.write[T, e](at, v)`: the integer
    /// or float `T` held in the `@size(T)` bytes from `at`, in byte
    /// order `e`, a compile-time `Endian`. The bytes are a `[]U8`, an
    /// `![]U8`, a `[N]U8`, a `List[U8]`, or (for `read`) a `?String`; `at` is
    /// checked now against an array's length when it is constant, and
    /// when the program runs otherwise.
    fn bytesCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, len: ?u64, op: sema.ElemOp, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const method = @tagName(op);
        const peeled = sema.unwrapViews(self.ctx, obj_ty);
        const byte = try self.byteType();
        if (elem != byte) return self.badCall(args, obj, "`{s}` works on bytes: a `[]U8`, an `![]U8`, a `[N]U8`, a `List[U8]`, or a `?String`; got `{s}`", .{ method, try self.tyName(obj_ty) });
        if (op == .write) {
            if (!try self.writesElements(obj, obj_ty, peeled, method)) return self.skipCall(args);
        } else if (self.isReceiverSigil(obj) and !obj.isKind(.read)) try self.misplacedSigil(obj, method, "only reads its receiver");
        const example = if (op == .read) "read[U32, .little](at)" else "write[U32, .little](at, value)";
        const b = ct orelse return self.badCall(args, pos, "`{s}` takes the type and the byte order in brackets: `{s}`", .{ method, example });
        try self.ctx.recordInstance(b, .function);
        const given = sema.bracketArgs(b);
        if (given.len < 1 or given.len > 2) return self.badCall(args, b, "`{s}` takes the type and the byte order, in brackets: `{s}`", .{ method, example });
        const num = try self.typeArg(given[0]);
        if (self.isPoison(num)) return self.skipCall(args);
        // A vector of numbers is read lane by lane, each lane in the byte
        // order; a value of one byte, or a vector of one-byte lanes, has
        // none.
        const lanes = if (sema.simdOf(self.ctx, num)) |v| v.elem else null;
        var one_byte = false;
        switch (self.ctx.types.get(lanes orelse num)) {
            .int => |info| one_byte = intBounds(info).bits == 8,
            .float => {},
            // A type parameter: each instance must be a number.
            .type_var => |param| try self.require(param, .bytes, self.startOf(given[0]), method),
            else => return self.badCall(args, given[0], "`{s}` {s} an integer or float type, or a `Simd` of them; got `{s}`", .{ method, if (op == .read) "reads" else "writes", try self.tyName(num) }),
        }
        if (one_byte) {
            if (given.len == 2) return self.badCall(args, given[1], "`{s}` of {s}`{s}`{s} takes no byte order: `{s}[{s}]{s}`", .{ method, if (lanes == null) "a one-byte " else "", try self.tyName(num), if (lanes == null) "" else ", whose lanes are one byte,", method, try self.tyName(num), if (op == .read) "(at)" else "(at, value)" });
        } else if (given.len != 2) {
            return self.badCall(args, b, "`{s}` of a `{s}` takes a byte order too: `{s}`", .{ method, try self.tyName(num), example });
        } else {
            const endian = try self.ctx.intern(.{ .nominal = self.ctx.endian_sym_id });
            try self.checkCtValue(given[1], endian, 1, method);
        }
        for (args) |a| if (a.isKind(.kwarg)) return self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        const want: usize = if (op == .read) 1 else 2;
        if (args.len != want) return self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, if (op == .read) "one argument, the offset of the first byte" else "two arguments, the offset of the first byte and the value", args.len, if (args.len == 1) "" else "s" });
        const recv = try self.ctx.intern(if (op == .read) Type{ .read_view = peeled } else Type{ .write_view = peeled });
        const params: []const TypeId = if (op == .read) &.{ recv, self.t().int_id } else &.{ recv, self.t().int_id, num };
        const returns = if (op == .read) num else self.t().void_id;
        try self.noteCallee(.{ .params = try self.ctx.dupeIds(params), .returns = returns, .is_sub = op == .write });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem, .num = num });
        try self.checkOffsetArg(args[0], num, len, method);
        if (op == .write) try self.checkExpr(args[1], num);
        return returns;
    }

    /// The offset of a `read` or `write` of a `num`: an integer, checked
    /// now against a known length when it is constant.
    fn checkOffsetArg(self: *Checker, a: Sexp, num: TypeId, len: ?u64, method: []const u8) Error!void {
        const ty = try self.synthValue(a);
        if (self.isPoison(ty)) return;
        if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an offset must be an integer; got `{s}`", .{try self.tyName(ty)});
        if (ty == self.t().int_literal_id) try self.defaultIntLiteral(a);
        const at = self.constInt(a) orelse return;
        const size: Wide = switch (self.ctx.types.get(num)) {
            .int => |i| if (i.bits == 0) 8 else i.bits / 8,
            .float => |f| if (f.bits == 0) 8 else f.bits / 8,
            .simd => |v| @intCast(((try sema.minBytes(self.ctx, v.elem)) orelse return) * (sema.simdLen(self.ctx, v) orelse return)),
            else => return,
        };
        if (at < 0) return self.errAt(a, "an offset cannot be negative; got `{d}`", .{at});
        if (len) |n| if (at + size > n) {
            try self.errAt(a, "`{s}` of a `{s}` at `{d}` runs past the end of an array of length {d}: it needs {d} bytes", .{ method, try self.tyName(num), at, n, size });
        };
    }

    /// An index argument: an integer (`Int` when that is all a literal
    /// says), checked now against a known length when it is constant.
    fn checkIndexArg(self: *Checker, a: Sexp, len: ?u64) Error!void {
        const ty = try self.synthValue(a);
        if (self.isPoison(ty)) return;
        if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an index must be an integer; got `{s}`{s}", .{ try self.tyName(ty), try self.loopOrderHint(a, self.t().int_id) });
        if (ty == self.t().int_literal_id) try self.defaultIntLiteral(a);
        if (len) |n| if (self.constInt(a)) |i| if (i < 0 or i >= n) {
            try self.errAt(a, "index `{d}` is out of bounds for an array of length {d}", .{ i, n });
        };
    }

    /// The receiver of a method that writes the elements of `peeled` (a
    /// slice, an array, or a List): a `![]T`, or a place written `!xs`.
    /// False after a diagnostic.
    fn writesElements(self: *Checker, obj: Sexp, obj_ty: TypeId, peeled: TypeId, method: []const u8) Error!bool {
        switch (self.ctx.types.get(peeled)) {
            .string_view, .static => {
                try self.errAt(obj, "cannot `{s}` a `?String`; a `?String` is read-only", .{method});
                return false;
            },
            .slice => if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
                try self.errAt(obj, "cannot `{s}` a `{s}`; its elements are read-only (a writable slice is a `![]T`)", .{ method, try self.tyName(obj_ty) });
                return false;
            },
            else => {},
        }
        // `!xs.fill(v)`: the write view took the checks.
        if (obj.isKind(.write)) return true;
        const place = if (obj.isKind(.read) or obj.isKind(.move)) ir.get(obj, .operand) else obj;
        // A receiver `!` could not write (through a `*T` or `?T`, or of
        // a parameter) is reported as such, not with a `!` to add.
        if (!try self.requireAccess(self.placeOf(place), .lend_write, obj)) return false;
        const shown = try self.plainText(place);
        const lent = if (sigilReaches(place)) try self.ctx.arena.allocator().print("!{s}", .{shown}) else try self.ctx.arena.allocator().print("!({s})", .{shown});
        try self.errAt(obj, "`{s}` writes the elements; write the receiver with `!`: `{s}`", .{ method, try self.callWith(obj, lent, method) });
        return false;
    }

    /// A `Cell[List[E]]` answers its List's `push`, `pop`, `keep`,
    /// `clear`, and, for a plain-data `E`, `get(i)`, through any path to
    /// the cell, as `set` does. Null for the Cell's own members.
    fn cellListCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
        const method = self.text(ir.Member.name(callee));
        const Member = enum { push, pop, keep, clear, get };
        const member = std.meta.stringToEnum(Member, method) orelse return null;
        if (member == .get and args.len == 0) return null;
        const cell = sema.unwrapReadAccess(self.ctx, obj_ty);
        const recv = try self.ctx.intern(if (member == .get) .{ .read_view = cell } else .{ .write_view = cell });
        const opt_elem = try self.ctx.intern(.{ .optional = elem });
        const params: []const TypeId = switch (member) {
            .push => &.{ recv, elem },
            .pop, .clear => &.{recv},
            .keep, .get => &.{ recv, self.t().int_id },
        };
        const f: FunctionType = .{
            .params = try self.ctx.dupeIds(params),
            .returns = switch (member) {
                .push, .keep, .clear => self.t().void_id,
                .pop, .get => opt_elem,
            },
            .is_sub = member == .push or member == .keep or member == .clear,
        };
        try self.noteCallee(f);
        if (member == .get) {
            // The receiver is read where it stands, as any `?self`
            // method's is (`readLeaf`).
            if (!self.hands(obj).hasStorage()) try self.readLeaf(obj);
            if (try self.cannotCopy(elem, pos, "copies an element out of a Cell's List")) {
                _ = try self.badCall(args, pos, cell_list_handle, .{try self.tyName(cell)});
                return f.returns;
            }
        } else {
            // A write method of the Cell's List, marked as any is
            // (`checkReceiverMode`); the Cell is the handle's own, so
            // the handle is lent, not the Cell exclusively.
            const misplaced_sigil = try self.checkReceiverSigil(obj, .write, f.returns, method);
            try self.recordUse(stripSigil(obj), .lend);
            if (!misplaced_sigil and self.hands(obj).kind != .made) try self.rejectResourceTemporary(obj, obj_ty);
            if (!misplaced_sigil) {
                const saved_of = self.receiver_of;
                defer self.receiver_of = saved_of;
                self.receiver_of = callee;
                try self.checkReceiverMode(obj, .write, classifyReceiverType(self.ctx, obj_ty, self.ctx.cell_sym_id), method, pos, f.returns);
            }
        }
        try self.checkArgs(args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub }, .{}, method, pos, .{ .receiver = true });
        return f.returns;
    }

    /// `xs.get(i)` on an array, a slice, or a `?String`: the element as
    /// `T?` (a `?String`'s byte as `U8?`), `none` when `i` is out of range.
    /// Null when `obj_ty` is none of these.
    fn sequenceGet(self: *Checker, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
        const seq = sema.unwrapViews(self.ctx, obj_ty);
        const elem: TypeId = switch (self.ctx.types.get(seq)) {
            .array => |a| a.elem,
            .slice => |sl| sl.elem,
            .string_view, .static => try self.byteType(),
            else => return null,
        };
        const recv = try self.ctx.intern(.{ .read_view = seq });
        const f: FunctionType = .{
            .params = try self.ctx.dupeIds(&.{ recv, self.t().int_id }),
            .returns = try self.ctx.intern(.{ .optional = elem }),
            .is_sub = false,
        };
        try self.noteCallee(f);
        if (try self.cannotCopy(elem, pos, "copies an element out of a sequence")) {
            return try self.badCall(args, pos, "`get` would copy an element out of a `{s}`, whose elements a copy cannot share; index it (`xs[i]`) or iterate over it instead", .{try self.tyName(seq)});
        }
        try self.checkArgs(args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = false }, .{}, "get", pos, .{ .receiver = true });
        return f.returns;
    }

    /// Whether `.len` (and so `is_empty()`) is built in on `ty`, a type
    /// with its views peeled: an array, a slice, a `?String`, a `Static`,
    /// a List, or a Cell holding a List.
    fn hasBuiltinLen(self: *Checker, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .array, .slice, .string_view, .static, .string => true,
            .parameterized_nominal => listElementType(self.ctx, ty) != null or cellListElement(self.ctx, ty) != null,
            else => false,
        };
    }

    fn noteCallee(self: *Checker, f: FunctionType) Error!void {
        try self.noteCalleeType(try self.ctx.intern(.{ .function = f }));
    }

    fn noteCalleeType(self: *Checker, ty: TypeId) Error!void {
        if (self.callee_node) |n| try self.ctx.recordType(n, ty);
    }

    /// `Type.function(args)` or `Type.variant(payload)`, for a type of
    /// this module or an imported one.
    fn associatedCall(self: *Checker, obj: Sexp, nt: NamedType, name: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const tname = try self.namedTypeName(nt);
        const members = nt.sym.fields orelse return self.badCall(args, pos, "opaque type `{s}` has no members", .{tname});
        const generic = nt.sym.kind == .generic_type;
        if (!generic and std.mem.eql(u8, name, "from_int")) {
            const enum_ty = try self.namedTypeValue(nt);
            if (self.enumValues(enum_ty)) |plain| {
                if (self.isBuiltinEnumTy(enum_ty)) return self.badCall(args, pos, "`{s}.from_int(n)` takes a declared enum; the built-in enum `{s}` has no integer value", .{ tname, tname });
                if (plain) return self.enumFromIntCall(self.callee_node orelse return self.skipCall(args), enum_ty, tname, pos, args, ct);
                const declared = (try sema.findMember(self.ctx, members, name, .any)) != null;
                if (!declared) return self.badCall(args, pos, "`{s}` has variants with payloads, which have no integer value", .{tname});
            }
        }
        // `from_text`, unless a payload enum declares its own.
        if (std.mem.eql(u8, name, "from_text") and !nt.sym.flags.error_set and (try sema.findMember(self.ctx, members, name, .any)) == null) {
            const is_enum = for (members) |m| {
                if (m.is_variant) break true;
            } else false;
            if (is_enum) {
                if (!generic) {
                    const enum_ty = try self.namedTypeValue(nt);
                    if (self.hasVariantNames(enum_ty)) return self.enumFromTextCall(self.callee_node orelse return self.skipCall(args), enum_ty, tname, pos, args, ct);
                }
                return self.badCall(args, pos, "`from_text` gives a plain enum's variant by its name; `{s}` {s}", .{ tname, if (generic) "is generic" else "has variants with payloads, which a name cannot build" });
            }
        }
        // The first member of that name decides.
        found: {
            const m = members[(try sema.findMember(self.ctx, members, name, .any)) orelse break :found];
            if (m.is_method and !m.is_drop_method) {
                try self.checkVisible(m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, pos);
                const fty = self.ctx.types.get(try self.memberType(nt.foreign, m.ty));
                if (fty != .function) break :found;
                var f = fty.function;
                var recv: TypeSubst = .empty;
                if (generic) {
                    // The type's arguments are given (`Pair[Int, ?String].make`)
                    // or come from the call's arguments.
                    const subst = if (nt.args) |given| TypeSubst{ .params = nt.sym.type_params orelse &.{}, .args = given } else (try self.inferTypeArgs(nt.id, args, .{ .params = .{ .params = f.params, .names = m.param_names } }, pos, self.expectedResult(f.returns), name)) orelse return self.skipCall(args);
                    if (nt.args == null) try self.ctx.recordType(obj, try self.instantiate(nt.id, subst.args, pos));
                    f = self.ctx.types.get(try sema.substituteType(self.ctx, m.ty, subst)).function;
                    recv = subst;
                }
                const source = if (nt.foreign) |fo| fo.ctx.source else self.declSource(nt.id);
                const info = methodParams(m, false, source);
                f = (try self.instantiateCall(f, ct, args, info, 0, name, pos, m.receiver != .none, recv)) orelse return self.skipCall(args);
                try self.noteMethodTarget(m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, recv);
                if (!try self.meetsNeeds(m, nt.id, recv.args, pos)) return self.skipCall(args);
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, name, pos, .{ .origins = m.origins, .declared = fty.function.params });
                return f.returns;
            }
            if (ct) |b| return self.badCall(args, b, "`{s}.{s}` is not a function; it takes no compile-time arguments", .{ tname, name });
            if (!m.is_variant) break :found;
            const payload = m.payload orelse &.{};
            if (payload.len == 0) return self.badCall(args, pos, "variant `{s}.{s}` takes no payload", .{ tname, name });
            var subst = TypeSubst.empty;
            var ty = try self.namedTypeValue(nt);
            if (nt.args) |given| {
                subst = .{ .params = nt.sym.type_params orelse &.{}, .args = given };
                ty = try self.instantiate(nt.id, given, pos);
            } else if (generic) {
                // Arguments that fill no field bind nothing to infer from:
                // say what the variant takes instead.
                const positional = for (args) |a| {
                    if (!a.isKind(.kwarg)) break true;
                } else false;
                if (args.len == 0 or (positional and !(args.len == 1 and soleField(payload) != null))) {
                    try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .module_id = nt.sym.from.module_id, .pos = pos, .foreign = nt.foreign, .kind = .variant });
                    return self.t().invalid_id;
                }
                const self_type = (try sema.makeNominalContext(self.ctx, nt.id)).self_type;
                subst = (try self.inferTypeArgs(nt.id, args, .{ .payload = payload }, pos, self.expectedResult(self_type), name)) orelse return self.skipCall(args);
                ty = try self.instantiate(nt.id, subst.args, pos);
            }
            try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .module_id = nt.sym.from.module_id, .pos = pos, .subst = subst, .foreign = nt.foreign, .kind = .variant, .instance = ty });
            return ty;
        }
        try self.err(pos, "no method `{s}` on type `{s}`{s}", .{ name, tname, try self.memberHint(nt.sym.fields orelse &.{}, name, .associated) });
        try self.noteDeclared(nt.sym, nt.foreign == null);
        return self.skipCall(args);
    }

    /// Where an inferred generic's arguments are matched: the fields a
    /// constructor or a variant's payload fills, or an associated
    /// function's parameters (with their names, for keyword arguments).
    const InferFrom = union(enum) {
        fields: []const Field,
        payload: []const Field,
        params: struct { params: []const TypeId, names: ?[]const []const u8 },
    };

    /// The type arguments of generic type `sym_id` that make `args` fit:
    /// each argument's type is matched against the field or parameter it
    /// fills (`inferBindings`). Null, after a diagnostic, when some
    /// parameter is left unbound or the arguments disagree on one.
    fn inferTypeArgs(self: *Checker, sym_id: SymbolId, args: []const Sexp, from: InferFrom, pos: u32, result: ?ResultType, member: ?[]const u8) Error!?TypeSubst {
        const sym = self.ctx.symbols.items[sym_id];
        const params = sym.type_params orelse &.{};
        const inf = try self.inferBindings(params, args, from, result);
        if (member) |name| try self.noteTypeArgsHint(sym_id, name, inf);
        for (params, inf.bound) |p, b| {
            const pname = self.ctx.symbols.items[p].name;
            if (b.ty == sema.type_invalid) {
                if (inf.poisoned) return null;
                try self.err(pos, "cannot infer `{s}` for `{s}` from the arguments; name it (`{s}[...]`), or give the type where the value goes (`x: {s}[...] = ...`)", .{ pname, sym.name, sym.name, sym.name });
                return null;
            }
            if (b.conflict == sema.type_invalid) {
                if (try self.lentClosureBound(b.ty, pname, sym.name, pos)) return null;
                if (!try self.valueBindingFits(p, b, sym.name, pos) or !try self.inferredTypeFits(b, args)) return null;
                continue;
            }
            const c = try self.conflictText(b);
            try self.err(pos, "conflicting {s} for `{s}` in `{s}`: `{s}` (argument {d}) and `{s}` (argument {d}); name it (`{s}[...]`)", .{ if (self.ctx.symbols.items[p].kind == .param) "values" else "types", pname, sym.name, c.first, c.first_arg, c.second, c.second_arg, sym.name });
            return null;
        }
        const bound = try self.ctx.arena.allocator().alloc(TypeId, params.len);
        for (inf.bound, bound) |b, *out| out.* = b.ty;
        return .{ .params = params, .args = bound };
    }

    /// Where an argument of `Type.member(...)` gives a type parameter
    /// another type than the one the expected type gives it, what to
    /// write for the mismatch that follows (`result_hints`): the type
    /// named, which passes the expected type on to the arguments.
    fn noteTypeArgsHint(self: *Checker, sym_id: SymbolId, member: []const u8, inf: Inference) Error!void {
        const call = self.current_call orelse return;
        if (call.list.id == 0) return;
        _ = self.result_hints.remove(call.list.id);
        const a = self.ctx.arena.allocator();
        const types = try a.alloc(TypeId, inf.bound.len);
        var first: ?usize = null;
        for (inf.bound, types, 0..) |b, *ty, i| {
            ty.* = if (b.wanted != sema.type_invalid) b.wanted else b.ty;
            if (b.wanted != sema.type_invalid and first == null) first = i;
        }
        const i = first orelse return;
        for (types) |ty| if (ty == sema.type_invalid) return;
        const sym = self.ctx.symbols.items[sym_id];
        const b = inf.bound[i];
        const took = try a.print("`{s}.{s}` takes `{s} = {s}` from argument {d}", .{ sym.name, member, self.ctx.symbols.items[sym.type_params.?[i]].name, try self.tyName(b.ty), b.arg });
        const named = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = try self.ctx.dupeIds(types) } });
        const hint = if (spelledInBrackets(self.ctx, named)) try a.print("{s}; to pass `{s}` on to it, name the type: `{s}.{s}(...)`", .{ took, try self.tyName(types[i]), try self.tyName(named), member }) else took;
        try self.result_hints.put(self.ctx.allocator, call.list.id, hint);
    }

    /// The instance of generic `sym_id` at `args`, checked like a spelled
    /// one: the built-in generics' element rules, and every generic's
    /// requirements (through its instantiation site).
    fn instantiate(self: *Checker, sym_id: SymbolId, args: []const TypeId, pos: u32) Error!TypeId {
        if (sym_id == self.ctx.simd_sym_id) return resolve.simdInstance(self.ctx, args, pos);
        if (try resolve.builtinElementError(self.ctx, sym_id, args)) |msg| try self.err(pos, "{s}", .{msg});
        const ty = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = try self.ctx.dupeIds(args) } });
        if (!sema.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) {
                gop.value_ptr.* = pos;
                // An instance first made here, in an expression, is checked
                // as a written one is (`resolve`'s `instance_stacking`).
                try sema.checkInstanceStacked(self.ctx, ty, pos);
            }
        } else try self.ctx.addGeneric(.uses, ty);
        return ty;
    }

    /// `module.function(args)` or `module.Type(fields)`.
    fn crossModuleCall(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const found = (try self.foreignSymbol(module_sym, name, pos)) orelse return self.skipCall(args);
        const qualified = try self.ctx.arena.allocator().print("{s}.{s}", .{ module_name, name });
        switch (found.sym.kind) {
            .type_alias => return self.aliasCall(self.current_call orelse Sexp.nil, self.callee_node orelse Sexp.nil, qualified, try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id), args, pos),
            .function, .@"extern" => {
                const local = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
                const fty = self.ctx.types.get(local);
                if (fty != .function) return self.badCall(args, pos, "`{s}` cannot be called", .{qualified});
                const info = paramsOf(found.sym, found.ctx.source);
                const f = (try self.instantiateCall(fty.function, ct, args, info, 0, qualified, pos, false, .empty)) orelse return self.skipCall(args);
                if (found.sym.kind == .function) try self.noteTarget(found.module_id, found.sym.decl_pos, found.sym.flags.inline_marked, .empty);
                // A generic function's callee has the instance's signature.
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, qualified, pos, .{ .origins = found.sym.origins, .declared = fty.function.params });
                return f.returns;
            },
            .nominal_type => if (ct == null) return self.construct(found.id, args, pos, TypeSubst.empty, .{ .ctx = found.ctx, .module_id = found.module_id }) else return self.badCall(args, ct.?, "`{s}` is not a generic type; it takes no type arguments", .{qualified}),
            .generic_type => {
                const nt = try self.foreignGeneric(found);
                return self.constructGeneric(self.callee_node orelse Sexp.nil, nt.id, args, qualified, pos);
            },
            else => return self.badCall(args, pos, "`{s}` cannot be called", .{qualified}),
        }
    }

    /// Whether `node` is the `?p`, `!p`, or `<p` of `?p.m(...)`,
    /// `!p.m(...)`, or `<p.m(...)`, written before the call rather than
    /// in parentheses.
    fn isReceiverSigil(self: *Checker, node: Sexp) bool {
        const p = self.ctx.parser orelse return false;
        return p.isReceiverSigil(node);
    }

    /// `?p.m(...)`, `!p.m(...)`, or `<p.m(...)` where `m` takes no
    /// receiver the sigil could apply to.
    fn misplacedSigil(self: *Checker, recv: Sexp, method: []const u8, why: []const u8) Error!void {
        try self.errAt(recv, "`{s}` {s}; remove the `{s}`", .{ method, why, sigilText(recv) });
    }

    /// `!p.f(...)` or `<p.f[i](...)`, where `f` is a field holding
    /// functions: there is no receiver for the sigil. A `!` before a call
    /// whose value is a `Bool` was meant as negation.
    fn fieldCallSigil(self: *Checker, recv: Sexp, field: []const u8, what: []const u8, fn_ty: TypeId) Error!void {
        const returns: ?TypeId = if (sema.ownedClosureFn(self.ctx, fn_ty)) |f| f.returns else switch (self.ctx.types.get(sema.unwrapViews(self.ctx, fn_ty))) {
            .function => |f| f.returns,
            else => null,
        };
        if (recv.isKind(.write) and returns == self.t().bool_id) {
            return self.errAt(recv, "`{s}` is {s}, not a method with a receiver; for negation use `not`", .{ field, what });
        }
        if (recv.isKind(.read)) return self.errAt(recv, "`{s}` is {s}, not a method with a receiver; remove the `?`, or lend the call's result with `?({s})`", .{ field, what, try self.callWith(recv, self.sourceText(ir.Read.operand(recv)), field) });
        try self.errAt(recv, "`{s}` is {s}, not a method with a receiver; remove the `{s}`", .{ field, what, sigilText(recv) });
    }

    /// `?p.m(...)`, `!p.m(...)`, and `<p.m(...)` (see
    /// `Parser.receiverSigil`): the sigil is the receiver mode of `m`, so
    /// a `!` before a method that only reads is the habit of `!` as
    /// negation, and a `!` call whose value is used is written
    /// `(!p).m(...)` so it never reads as one. A `?` spells out the read
    /// receiver a call takes anyway. Returns whether it reported an
    /// error.
    fn checkReceiverSigil(self: *Checker, recv: Sexp, mode: MethodReceiver, returns: TypeId, method: []const u8) Error!bool {
        if (!self.isReceiverSigil(recv)) return false;
        const place = ir.get(recv, .operand);
        const at = self.ctx.span(place);
        const name = diag.textOf(self.ctx.source, at);
        if (recv.isKind(.read)) {
            if (mode == .read) return false;
            const hint = if (returns == self.t().void_id) "" else try self.ctx.arena.allocator().print("; to lend the call's result, write `?({s})`", .{try self.callWith(recv, name, method)});
            if (mode == .write) {
                try self.errAt(recv, "`{s}` writes its receiver: write `{s}`{s}", .{ method, try self.writeCallText(recv, method, returns), hint });
            } else try self.errAt(recv, "`{s}` consumes its receiver: write `{s}`{s}", .{ method, try self.callWith(recv, try self.ctx.arena.allocator().print("<{s}", .{name}), method), hint });
        } else if (recv.isKind(.write)) switch (mode) {
            .write => {
                if (!self.usesValue(recv, returns)) return false;
                // `!(!b).m(...)` whose value is used: the receiver is lent
                // to write already, so the outer `!` is the one to remove,
                // not to parenthesize.
                if (place.isKind(.write)) {
                    const lent = self.sourceText(ir.get(place, .operand));
                    const call = if (self.current_call) |c| try self.spliced(c, &.{recv}, &.{self.sourceText(recv)[1..]}) else try self.ctx.arena.allocator().print("(!{s}).{s}(...)", .{ lent, method });
                    try self.errAt(recv, "`(!{s})` already lends `{s}` to write: remove the outer `!` and write `{s}`", .{ lent, lent, call });
                    return true;
                }
                const long = try self.ctx.arena.allocator().print("({s})", .{self.sourceText(recv)});
                const call = if (self.current_call) |c| try self.spliced(c, &.{recv}, &.{long}) else try self.ctx.arena.allocator().print("{s}.{s}(...)", .{ long, method });
                try self.errAt(recv, "write `{s}`: a write call whose value is used puts its `!` in parentheses", .{call});
            },
            else => if (returns == self.t().bool_id) {
                try self.errAt(recv, "`{s}` does not write its receiver; for negation use `not`", .{method});
            } else try self.errAt(recv, "`{s}` does not write its receiver; remove the `!`", .{method}),
        } else switch (mode) {
            .value => return false,
            .write => try self.errAt(recv, "`{s}` does not consume its receiver; it writes it: `{s}`, and its result needs no `<`", .{ method, try self.writeCallText(recv, method, returns) }),
            else => try self.errAt(recv, "`{s}` does not consume its receiver; remove the `<`: a call's result moves without it", .{method}),
        }
        return true;
    }

    /// Whether a write receiver `recv` of kind `kind` is a write view,
    /// which a write method writes through.
    fn writesThrough(self: *Checker, recv: Sexp, kind: ReceiverTypeKind) bool {
        if (kind == .write_view) return true;
        const ty = self.ctx.typeOf(recv) orelse return false;
        return self.ctx.types.get(ty) == .write_view;
    }

    /// A write method called on a temporary (a value made here, a part
    /// of one, or a branching value made in every branch) with no `!`:
    /// every change is marked by `!` (Core sentences 4 and 9), which
    /// lends the temporary to write.
    fn writeOfTemporary(self: *Checker, recv: Sexp, method: []const u8, returns: TypeId) Error!void {
        const shown = try self.plainText(recv);
        const a = self.ctx.arena.allocator();
        const lent = if (sigilReaches(recv)) try a.print("!{s}", .{shown}) else try a.print("!({s})", .{shown});
        const call = try self.callWith(recv, if (self.usesValue(recv, returns)) try a.print("({s})", .{lent}) else lent, method);
        // A `!` that is there but does not reach the receiver.
        const outer = self.outer_write;
        if (outer.isKind(.call) and sameNode(ir.Call.callee(outer), self.receiver_of)) {
            if (self.outer_write_is_loop) return self.errAt(recv, "`{s}` changes its receiver, a temporary no name holds; the `!` before a `for` source is the loop's mode, not a lend of the receiver: bind `{s}` to a name first", .{ method, shown });
            return self.errAt(recv, "`{s}` changes its receiver, a temporary no name holds; the `!` here lends what `{s}` returns, not its receiver: write `{s}`", .{ method, method, call });
        }
        try self.errAt(recv, "`{s}` changes its receiver, a temporary no name holds; add `!`: `{s}`", .{ method, call });
    }

    /// Whether `!` written before `recv` followed by a method call lends
    /// `recv` as the receiver (the receiver-sigil rule, `rig.Parser`): a
    /// postfix chain with no method call in it, or else `recv` must be
    /// parenthesized (`!(+s).bump()`, `!(a.make()).bump()`).
    fn sigilReaches(recv: Sexp) bool {
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
    /// branches lends (`!a if c else !b`), a handle included.
    fn isWriteViewValue(self: *Checker, e: Sexp) bool {
        const ty = self.ctx.typeOf(e) orelse return false;
        return self.ctx.types.get(ty) == .write_view;
    }

    /// Why a receiver that changes through a shared handle is marked, for
    /// a diagnostic that asks for the mark; empty for any other receiver.
    fn markNote(self: *Checker, recv: Sexp) []const u8 {
        const ty = self.ctx.typeOf(recv) orelse return "";
        return if (sema.changesByMark(self.ctx, ty)) ": changing a shared Cell is marked with `!`" else "";
    }

    /// Receiver rules: `?self` is lent implicitly; `!self` needs an explicit
    /// `!x.m()`; a consuming `self` needs an explicit `<x.m()`. Write and
    /// consuming receivers are refused through `?T` and `*T`.
    fn checkReceiverMode(self: *Checker, recv: Sexp, mode: MethodReceiver, kind: ReceiverTypeKind, method: []const u8, pos: u32, returns: TypeId) Error!void {
        const shape = self.receiverShape(recv);
        switch (mode) {
            .read => if (shape == .move_explicit) {
                try self.err(pos, "method `{s}` takes its receiver as a read view; cannot move", .{method});
            } else if (self.ctx.typeOf(recv)) |ty| {
                _ = try self.writeLendRead(recv, ty, .{ .read_receiver = method });
            },
            .write => {
                if (kind == .read_view) return self.err(pos, "method `{s}` needs its receiver lent to write; a read view cannot become a write view", .{method});
                if (kind == .shared and !sema.changesByMark(self.ctx, self.ctx.typeOf(recv) orelse sema.type_invalid)) return self.err(pos, "cannot call write-receiver method `{s}` through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.", .{method});
                switch (shape) {
                    .write_explicit => {},
                    // A value made here, or a part of one, is a temporary
                    // no name holds, which a write method changes only
                    // where `!` lends it (`!mk().bump()`). A write view
                    // made here writes through.
                    .made => if (!self.writesThrough(recv, kind)) try self.writeOfTemporary(recv, method, returns),
                    // A branch that is a write view writes through it; one
                    // that is a name's value would be written as a copy.
                    // (One that owns a resource is reported as a temporary
                    // nothing drops.)
                    .branches => if (kind != .write_view and !self.isWriteViewValue(recv) and !self.ownsResource(recv)) {
                        const leaf = self.namedLeaf(recv) orelse recv;
                        try self.errAt(recv, "method `{s}` writes its receiver, and `{s}` may be `{s}`, a value a name holds, which the call would write as a copy; call `{s}` on the name in each branch", .{ method, self.sourceText(recv), self.sourceText(leaf), method });
                    },
                    .read_explicit => try self.err(pos, "method `{s}` needs its receiver lent to write, not read; write `{s}`{s}", .{ method, try self.writeCallText(recv, method, returns), self.markNote(recv) }),
                    .move_explicit => try self.err(pos, "method `{s}` needs its receiver lent to write, not moved; write `{s}`", .{ method, try self.writeCallText(recv, method, returns) }),
                    // A binding that already holds a write view (`x: !T`,
                    // `!self`) lends it visibly too.
                    .place => if (kind != .write_view and self.hands(recv).kind == .part_of_made) {
                        try self.writeOfTemporary(recv, method, returns);
                    } else if (kind != .write_view) {
                        try self.err(pos, "method `{s}` needs its receiver lent to write; write `{s}`{s}", .{ method, try self.writeCallText(recv, method, returns), self.markNote(recv) });
                    } else {
                        const name = self.sourceText(recv);
                        try self.errAt(recv, "write `{s}`: the call writes `{s}`", .{ try self.writeCallText(recv, method, returns), name });
                    },
                }
            },
            .value => {
                switch (kind) {
                    // A view of a value that copies is copied out, as
                    // where a value is expected (Core §4).
                    .read_view, .write_view => if (!self.copiesThrough(recv)) return self.err(pos, "method `{s}` consumes the receiver; cannot consume through a view", .{method}),
                    .shared => return self.err(pos, "method `{s}` consumes the receiver; cannot consume the inner value through a shared handle (`*T`) — other handles may still reference it", .{method}),
                    else => {},
                }
                switch (shape) {
                    // A branching value is taken leaf by leaf: a name
                    // there is moved with `<` (the ownership checker).
                    .move_explicit, .made, .branches => {},
                    .read_explicit, .write_explicit => try self.err(pos, "method `{s}` consumes the receiver; a lend cannot give it up; write `{s}`", .{ method, try self.callWith(recv, try self.ctx.arena.allocator().print("<{s}", .{try self.plainText(receiverPlace(recv))}), method) }),
                    // A place whose value copies is read, as an argument
                    // is: the call takes a copy (Core sentence 1).
                    .place => if (!self.copiesValue(recv) and !self.copiesThrough(recv)) switch (sema.moveSource(self.ctx, recv)) {
                        .binding, .capture => try self.err(pos, "method `{s}` consumes the receiver; write `{s}`", .{ method, try self.callWith(recv, try self.ctx.arena.allocator().print("<{s}", .{self.sourceText(recv)}), method) }),
                        .made_part => try self.errAt(recv, "method `{s}` consumes its receiver, and `{s}` is a part of a temporary its statement drops; bind the value to a name first", .{ method, self.sourceText(recv) }),
                        else => try self.errAt(recv, "method `{s}` consumes its receiver, and `<` cannot move `{s}` out of the value that holds it; exchange it out first: `replace(!{s}, v).{s}(...)`", .{ method, self.sourceText(recv), self.sourceText(recv), method }),
                    },
                }
            },
            .none => {},
        }
    }

    // =========================================================================
    // Expressions: checking against an expected type
    // =========================================================================

    fn checkExpr(self: *Checker, e: Sexp, expected: TypeId) Error!void {
        try self.checkExprAgainst(e, expected);
        // A branching value, or a path from one, that goes where it
        // stands as a view is lent there (`lentInPlace`); a function's
        // result hands its views to the caller.
        if (lentBranch(e) == .nil or self.isReturnLeaf(e)) return;
        if (self.lentInPlace(e, expected)) |kind| _ = try self.lendsBranch(e, .nil, kind);
    }

    /// How `e`, checked against `expected`, goes where it stands as a
    /// view, by a positive list: lent on to write where a write view goes
    /// (bound, passed, or stored as one), and lent to read where a read
    /// view goes (`?T`, `[]T`, `?String`) and it is read in place
    /// (`readsInPlace`). Null where it is copied or read as a value.
    fn lentInPlace(self: *Checker, e: Sexp, expected: TypeId) ?LendKind {
        if (self.isPoison(expected)) return null;
        return switch (self.ctx.types.get(self.liftTarget(expected))) {
            .write_view => .write,
            .read_view, .slice, .string_view => if (self.readsInPlace(e)) .read else null,
            else => null,
        };
    }

    /// Whether a branching value `e`, or a path from one (`lentBranch`),
    /// is read where it stands when a view of it is used: a leaf of the
    /// branch (`sema.valueLeaves`) is a write view, which narrows, or a
    /// value that is no view. A branch whose every leaf is a read view (a
    /// `?T`, a `[]T`, a `?String`, or an optional of one) copies the view it
    /// takes, so it is read as a value.
    fn readsInPlace(self: *Checker, e: Sexp) bool {
        const root = lentBranch(e);
        if (root == .nil) return false;
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        sema.valueLeaves(self.ctx.allocator, root, &leaves) catch return true;
        for (leaves.items) |leaf| {
            const ty = self.ctx.typeOf(leaf) orelse continue;
            switch (self.ctx.types.get(self.liftTarget(ty))) {
                .read_view, .slice, .string_view, .static, .none_literal, .noreturn, .invalid, .unknown => {},
                else => return true,
            }
        }
        return false;
    }

    fn checkExprAgainst(self: *Checker, e: Sexp, expected: TypeId) Error!void {
        try self.checkExprAgainstType(e, expected);
        if (self.ctx.typeOf(e)) |actual| try self.recordLift(e, actual, expected);
    }

    fn checkExprAgainstType(self: *Checker, e: Sexp, expected: TypeId) Error!void {
        // A value checked against the type its context gives it is taken
        // there: a typed binding, an argument, a field, an element, a
        // result.
        try self.recordUse(e, .take);
        if (e == .list and self.ctx.quiet == 0) try self.expected.put(self.ctx.allocator, nodeId(e), expected);
        const prev_lent = self.lent_write;
        defer self.lent_write = prev_lent;
        if (e.isKind(.write) and self.ctx.types.get(expected) == .write_view) self.lent_write = e;
        const saved_result = self.result_expected;
        defer self.result_expected = saved_result;
        if (resultCall(e)) |call| self.result_expected = .{ .call = call, .ty = expected };
        // A poisoned expected type still reaches a generic call's
        // inference, which then reports nothing more.
        if (self.isPoison(expected)) {
            // `[]` has no type of its own to report on.
            if (e.isKind(.array) and ir.Array.elems(e).len == 0) return;
            const saved = self.under_poison;
            defer self.under_poison = saved;
            self.under_poison = true;
            _ = try self.synthExpr(e);
            return;
        }
        if (try self.lentTempLiteral(e, expected)) return;
        // A variant literal where a view held by address goes is the value
        // `E.v(...)` is, which goes there as that value goes.
        const viewed = try self.variantUnderView(e, expected);
        if (try self.checkContextual(e, viewed orelse expected)) |ty| {
            if (try self.cellMadeAway(e, ty)) return self.ctx.recordType(e, self.t().invalid_id);
            try self.ctx.recordType(e, ty);
            if (viewed == null or self.isPoison(ty)) return;
            return self.checkActual(e, ty, expected);
        }

        return self.checkActual(e, try self.synthExpr(e), expected);
    }

    /// `e`, of type `actual` (`synthExpr`), where `expected` goes: adapted
    /// or lent to it, or reported.
    fn checkActual(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        // A written `!x` where a read view goes only lends to read.
        if (self.readViewSlot(expected) and try self.writeLendRead(e, actual, .{ .read_view = expected })) return;
        if (try self.lendView(e, actual, expected)) return;
        if (try self.arrayAsSlice(e, actual, expected)) return;
        if (try self.stringAsStringView(e, actual, expected)) return;
        if (self.ctx.types.get(expected) == .function and sema.callableFnTy(self.ctx, actual) == expected) {
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; a lent closure goes to a parameter declared `{s}`", .{ try self.tyName(expected), try self.tyName(actual), try self.tyName(actual) });
        }
        if (compatible(self.ctx, actual, expected)) {
            try self.recordAdapted(e, actual, expected);
            return;
        }
        // Failing is written: an error value meets a `T!` only as the
        // operand of `return`.
        if (self.ctx.types.get(expected) == .fallible and sema.isErrorValue(self.ctx, actual)) {
            if (self.isReturnLeaf(e)) return;
            return self.errAt(e, "an error value meets `{s}` only as the operand of `return`: write `return {s}`", .{ try self.tyName(expected), self.sourceText(e) });
        }
        // A fallible call where its value is expected: `synthCall`
        // reported the missing `!` / `catch`.
        const at = self.ctx.types.get(actual);
        if (at == .fallible and compatible(self.ctx, at.fallible, expected)) return;
        if (sameExpr(e, self.ignored_in)) return;
        if (resultCall(e)) |call| if (call.list.id != 0) if (self.result_hints.get(call.list.id)) |hint| {
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; {s}", .{ try self.tyName(expected), try self.tyName(actual), hint });
        };
        // Only a value that copies is copied out of a view (`copiedOut`).
        switch (at) {
            .read_view, .write_view => |inner| if (compatible(self.ctx, inner, expected)) {
                if (try self.payloadViewTaken(e, "move")) return;
                const name = try self.tyName(inner);
                const why = if (sema.copies(self.ctx, inner) == .depends) "may not copy in every instance" else self.movesBecause(inner);
                return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; only a value that copies is copied out of a view, and `{s}` {s}: lend it on where it goes (`?{s}` or `!{s}`)", .{ try self.tyName(expected), try self.tyName(actual), name, why, name, name });
            },
            else => {},
        }
        try self.mismatch(e, expected, actual);
    }

    /// An array literal or fill lent as a `[]T` argument: its elements
    /// take the slice's element type. True when handled.
    fn lentTempLiteral(self: *Checker, e: Sexp, expected: TypeId) Error!bool {
        if (!e.isKind(.array) and !e.isKind(.array_fill)) return false;
        if (!sameNode(e, self.lent_temp)) return false;
        const elem = switch (self.ctx.types.get(expected)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        const synth = try self.synthQuiet(e);
        const len = switch (self.ctx.types.get(synth)) {
            .array => |a| a.len,
            else => return false,
        };
        const array = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
        try self.checkExpr(e, array);
        try self.lendTempArray(e, array, expected);
        return true;
    }

    /// `e`, of type `actual`, where a view of type `expected` goes, lent
    /// by the rows of the lend table that make it (`sema.lendsAs`): from
    /// a lend written here (`?a`, `!b`), a view `e` already is (a `?String`
    /// a call returns, a held `![]T`), or a function. True when handled.
    fn lendView(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const kind: sema.LendKind, const from: TypeId = switch (self.ctx.types.get(actual)) {
            .read_view => |inner| .{ .read, inner },
            .write_view => |inner| .{ .write, inner },
            else => .{ .read, actual },
        };
        // A slice argument is lent the way its name is: `total(w[1..3])`
        // is `total(?w[1..3])`, whose slice `synthSlice` made, so the
        // view goes where its own type does.
        const sliced = self.slicedArg(e);
        var lend = (if (sliced) sliceArgLend(self.ctx, actual, expected) else sema.lendsAs(self.ctx, from, kind, expected)) orelse
            return sliced and try self.sliceArgRejected(e, actual, expected);
        const view = sema.isReadOrWriteView(self.ctx, actual);
        // A bare value where a view argument goes is lent to read where it
        // is, as `?e` would lend it (Core sentence 1): a place, or a value
        // made here, which its statement holds. A function lends itself.
        const function = lend.callable() != null and self.ctx.types.get(from) == .function and !self.closureBinding(e);
        // (A temporary array lent as a `[]T` to a call that keeps no view
        // of it lives in a slot of the call: `arrayAsSlice`.)
        const temp_array = sameNode(e, self.lent_temp) and self.ctx.types.get(from) == .array;
        if (!view and sameExpr(e, self.view_arg) and !function and !temp_array) {
            switch (self.hands(e).kind) {
                .place, .part_of_made, .made => {},
                .lend, .branches, .jump, .none => return false,
            }
            // A slice held its own temporary, as `?xs[a..b]` does.
            if (!sliced) try self.lendsToRead(e);
            lend.implicit = true;
            try self.ctx.recordImplicitLend(e);
            try self.ctx.recordLend(e, lend);
            return true;
        }
        // `?x` where a `(?T)?` is expected is a view the context admits as
        // it is.
        if (lend.onlyLifts()) return false;
        if (lend.callable() != null) {
            if (sema.ownedClosureFn(self.ctx, from) != null and !view) {
                // The handle is lent from its binding; reported once.
                const place = switch (e.kind() orelse .lambda) {
                    .move, .clone => ir.get(e, .operand),
                    else => e,
                };
                if (self.hands(place).hasStorage()) {
                    try self.errAt(e, "an owned closure is lent to a `{s}` parameter: write `?{s}`", .{ try self.tyName(expected), self.sourceText(place) });
                } else try self.errAt(e, "an owned closure is lent to a `{s}` parameter from a binding: bind it first (`cb = ...`), then lend it with `?cb`", .{try self.tyName(expected)});
                try self.ctx.recordType(e, self.t().invalid_id);
                return true;
            }
        } else if (lend.has(.read_only)) {
            try self.recordAdapted(e, actual, expected);
        } else {
            // Every other row lends a value written `?x` or `!x` here, or
            // what a view `e` already is views.
            if (!view) return false;
            // A String made here is a temporary its statement drops.
            if (lend.has(.text) and e.isKind(.read) and !self.placeOf(ir.Read.operand(e)).named()) try self.lendTemp(ir.Read.operand(e));
            // A lend written here of an array's or a String's own elements
            // is the view it makes.
            if (e.isKind(.read) or e.isKind(.write)) for (lend.steps()) |step| switch (step) {
                .lift => {},
                .elems => try self.ctx.recordType(e, expected),
                .text => try self.ctx.recordType(e, self.t().string_view_id),
                else => break,
            };
        }
        try self.ctx.recordLend(e, lend);
        return true;
    }

    // ---- lasting lends --------------------------------------------------------

    /// Where a value that holds a view is kept past its statement: a
    /// binding or an assignment, named by its target, or a returned value.
    const Kept = union(enum) {
        binding: []const u8,
        returned,
        /// Stored by the call to this callee.
        stored: []const u8,
    };

    /// `stmt`, a binding or an assignment, keeps the value it is given.
    fn checkKeptSet(self: *Checker, stmt: Sexp) Error!void {
        const target = ir.Set.target(stmt);
        if (target == .src and std.mem.eql(u8, self.text(target), "_")) return;
        if (rig.bindingKindOf(ir.Set.op(stmt)).operator() != null) return;
        try self.keptLends(ir.Set.value(stmt), .{ .binding = if (target == .src) self.text(target) else self.sourceText(target) });
    }

    /// The one decider of a lasting lend (Core sentence 4: a lend kept
    /// in a binding is written). `value`, which holds a view and is kept
    /// (`Kept`), is a call whose result carries what an argument or the
    /// receiver views (`CallParams.resultCarries`); if that is lent
    /// implicitly, the loan outlives the statement, so the lend is
    /// written: `r = head(?v)`, `xs = ?b.all()`. A call whose result is
    /// used only within its statement lends implicitly, since its loan
    /// ends with the statement.
    fn keptLends(self: *Checker, value: Sexp, kept: Kept) Error!void {
        if (value != .list or self.under_poison) return;
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
        try self.copiedPayloadLeaves(value, &copied);
        leaf: for (leaves.items) |leaf| {
            for (copied.items) |c| if (sameNode(c, leaf)) continue :leaf;
            try self.keptLeaf(leaf, kept);
        }
    }

    /// The leaves of every operand in `e` whose payload a `??` or `catch`
    /// copies out (`SemContext.copiesPayload`): its view is read there,
    /// not kept, so what the copy keeps is what the value it views holds,
    /// as a binding `v` of `if a as v` keeps what `v` holds.
    fn copiedPayloadLeaves(self: *Checker, e: Sexp, out: *std.ArrayList(Sexp)) Error!void {
        if (e != .list) return;
        if (self.ctx.copiesPayload(e)) {
            const holder = if (e.isKind(.@"??")) ir.@"??".left(e) else ir.Catch.value(e);
            try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, holder, out);
        }
        for (e.items()) |c| try self.copiedPayloadLeaves(c, out);
    }

    fn keptLeaf(self: *Checker, e: Sexp, kept: Kept) Error!void {
        if (e != .list) return;
        const ty = self.ctx.typeOf(e) orelse return;
        if (self.isPoison(ty) or !sema.mayHoldView(self.ctx, ty)) return;
        switch (e.kind() orelse return) {
            // A part of a value a call made keeps what the call's
            // result carries.
            .member, .index => try self.keptLeaf(ir.get(e, .object), kept),
            .array => for (ir.Array.elems(e)) |el| try self.keptLeaf(el, kept),
            .call => {
                if (try self.kept_reported.fetchPut(self.ctx.allocator, nodeId(e), {}) != null) return;
                const callee = ir.Call.callee(e);
                const params = self.ctx.callParamsOf(e);
                const has_recv = if (params) |p| p.fills.len > 0 and p.fills[0] == .receiver else false;
                if (callee.isKind(.member) and has_recv and params.?.resultCarriesReceiver()) {
                    const recv = ir.Member.object(callee);
                    if (self.implicitReceiver(recv)) return self.reportKept(e, recv, true, kept);
                    try self.keptLeaf(recv, kept);
                }
                for (ir.Call.args(e), 0..) |a, i| {
                    if (params) |p| if (!p.resultCarries(i)) continue;
                    const arg = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
                    if (self.implicitArgument(arg)) return self.reportKept(e, arg, false, kept);
                    try self.keptLeaf(arg, kept);
                }
            },
            else => {},
        }
    }

    /// Whether `arg` is a place lent to read where a view goes, with no
    /// `?` written (`Lend.implicit`).
    fn implicitArgument(self: *Checker, arg: Sexp) bool {
        const lend = self.ctx.lendOf(arg) orelse return false;
        return lend.implicit and self.hands(arg).kind == .place;
    }

    /// Whether `recv`, the receiver of a method that reads it, is a place
    /// the call lends to read with no `?` written: an owner, not a view
    /// that is copied.
    fn implicitReceiver(self: *Checker, recv: Sexp) bool {
        if (recv.isKind(.read) or recv.isKind(.write) or recv.isKind(.move)) return false;
        const ty = self.ctx.typeOf(recv) orelse return false;
        if (self.isPoison(ty) or sema.isReadOrWriteView(self.ctx, ty)) return false;
        return self.hands(recv).kind == .place and self.placeOf(recv).named();
    }

    fn reportKept(self: *Checker, call: Sexp, lent: Sexp, receiver: bool, kept: Kept) Error!void {
        const a = self.ctx.arena.allocator();
        const shown = try self.plainText(lent);
        const fixed = try self.spliced(call, &.{lent}, &.{try a.print("?{s}", .{shown})});
        const call_text = self.sourceText(call);
        _ = receiver;
        switch (kept) {
            .binding => |name| if (std.mem.eql(u8, name, rig.hiddenIteratorName())) {
                try self.errAt(lent, "`{s}` keeps `{s}` lent while the loop walks it; write `for ... in {s}`", .{ call_text, shown, fixed });
            } else try self.errAt(lent, "`{s}` keeps `{s}` lent while `{s}` lives; write `{s}`", .{ call_text, shown, name, fixed }),
            .returned => try self.errAt(lent, "`{s}` keeps `{s}` lent in the value it returns; write `{s}`", .{ call_text, shown, fixed }),
            .stored => |callee| try self.errAt(lent, "`{s}` keeps `{s}` lent in what `{s}` stores; write `{s}`", .{ call_text, shown, callee, fixed }),
        }
    }

    /// A slice argument (`slicedArg`) where its context takes no read
    /// view of that type: lent to write, `!xs[a..b]`, where a `![]T`
    /// goes, and a copy where a value of its own does. True when
    /// reported; any other type is a mismatch, as for `?xs[a..b]`.
    fn sliceArgRejected(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const a = self.ctx.arena.allocator();
        const slot = self.slot;
        const in_call = sameExpr(e, slot.value) and slot.call != .nil and !slot.field and argOf(slot.call, e);
        const shown = try self.plainText(e);
        const callee = if (in_call) try a.print("`{s}`", .{try self.calleeName(ir.Call.callee(slot.call))}) else "the call";
        const object = try self.plainText(ir.Index.object(e));
        if (sema.writeSliceElem(self.ctx, expected)) |elem| {
            if (self.ctx.types.get(actual) != .slice or self.ctx.types.get(actual).slice.elem != elem) return false;
            const lent = try a.print("!{s}", .{shown});
            const fix = if (in_call) try self.spliced(slot.call, &.{e}, &.{lent}) else lent;
            try self.errAt(e, "{s} writes the elements of `{s}`, and a slice is lent to read unless it is written `!`; write `{s}`", .{ callee, shown, fix });
            return true;
        }
        if ((actual == self.t().string_view_id or actual == self.t().static_id) and self.liftTarget(expected) == self.t().string_id) {
            const copy = try a.print("String(?{s})", .{shown});
            const fix = if (in_call) try self.spliced(slot.call, &.{e}, &.{copy}) else copy;
            try self.errAt(e, "{s} takes a `String`, which owns its bytes, and `{s}` only views `{s}`'s; write `{s}` to pass a copy", .{ callee, shown, object, fix });
            return true;
        }
        const elem = switch (self.ctx.types.get(actual)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        const target = self.liftTarget(expected);
        const owns = switch (self.ctx.types.get(target)) {
            .array => |arr| arr.elem == elem,
            else => listElementType(self.ctx, target) == elem,
        };
        if (!owns) return false;
        try self.errAt(e, "{s} takes a `{s}`, which owns its elements, and `{s}` only views `{s}`'s", .{ callee, try self.tyName(expected), shown, object });
        return true;
    }

    /// A temporary array `e` of `elem`s lent as a `[]T` argument, with no
    /// `?` written (`total([1, 2])`). One whose elements need no cleanup
    /// lives where Zig holds it for the call; any other is held and
    /// dropped in its statement's slot, as `?[...]` holds it
    /// (`lendsToRead`).
    fn lendTempArray(self: *Checker, e: Sexp, array: TypeId, expected: TypeId) Error!void {
        const elem = self.ctx.types.get(array).array.elem;
        if (!sema.typeHasDropGlue(self.ctx, elem) and !sema.maybeDropGlue(self.ctx, elem)) return self.ctx.recordTempArray(e);
        var lend = sema.lendsAs(self.ctx, array, .read, expected) orelse return self.ctx.recordTempArray(e);
        try self.lendsToRead(e);
        lend.implicit = true;
        try self.ctx.recordImplicitLend(e);
        try self.ctx.recordLend(e, lend);
    }

    /// An array where a slice is expected: a temporary array as a `[]T`
    /// argument of a call that keeps no view of it. A bare named array
    /// is rejected with the lend to write. True when handled.
    fn arrayAsSlice(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const want_write = sema.writeSliceElem(self.ctx, expected) != null;
        const elem = sema.writeSliceElem(self.ctx, expected) orelse switch (self.ctx.types.get(expected)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        switch (self.ctx.types.get(actual)) {
            .array => |a| if (a.elem == elem or (!want_write and sema.readsAsStringView(self.ctx, a.elem, elem))) {
                if (self.hands(e).hasStorage()) {
                    const shown = try self.plainText(e);
                    const sigil: u8 = if (want_write) '!' else '?';
                    try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; write `{c}{s}` or `{c}{s}[..]`", .{ try self.tyName(expected), try self.tyName(actual), sigil, shown, sigil, shown });
                    return true;
                }
                if (!want_write and sameNode(e, self.lent_temp)) {
                    try self.lendTempArray(e, actual, expected);
                    return true;
                }
                if (!want_write) {
                    try self.errAt(e, "a temporary array is lent as a `{s}` only to a call that keeps no view of it; bind it to a name and pass `?name`", .{try self.tyName(expected)});
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// A String, or a write view of one, where a `?String` is expected: it
    /// is lent as a `?String` to read, `?t`. True when handled.
    fn stringAsStringView(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
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
        const shown = try self.plainText(stripSigil(e));
        try self.errAt(e, "type mismatch: expected `?String`, got `{s}`; lend it as a `?String` with `?{s}` or `?{s}[..]`", .{ try self.tyName(actual), shown, shown });
        return true;
    }

    fn mismatch(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error!void {
        // `!c` of a handle that may not be written here lends what it holds
        // (`synthLend`), which a `!*T` parameter cannot take.
        if (e.isKind(.write)) if (self.ctx.types.get(expected) == .write_view and self.ctx.types.get(actual) == .write_view) {
            const want = self.ctx.types.get(expected).write_view;
            if (self.ctx.types.get(want) == .shared and self.ctx.types.get(want).shared == self.ctx.types.get(actual).write_view) {
                return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`: this handle is read-only here; pass `+{s}` to share a new handle, or lend the contents", .{ try self.tyName(expected), try self.tyName(actual), self.sourceText(ir.Write.operand(e)) });
            }
        };
        // `?p.m()` reads `p`; where a view of the call's result is
        // expected, the view goes around the call.
        if (e.isKind(.call) and self.ctx.types.get(expected) == .read_view and compatible(self.ctx, actual, sema.unwrapViews(self.ctx, expected))) {
            const callee = ir.Call.callee(e);
            if (callee.isKind(.member) and ir.Member.object(callee).isKind(.read) and self.isReceiverSigil(ir.Member.object(callee))) {
                const recv = ir.Member.object(callee);
                const start = self.ctx.span(ir.Read.operand(recv)).start;
                const end = self.ctx.span(e).end;
                const call = diag.textBetween(self.ctx.source, start, end);
                return self.errAt(recv, "type mismatch: expected `{s}`, got `{s}`: `?{s}` reads `{s}` for the call; write `?({s})` to lend the call's result", .{ try self.tyName(expected), try self.tyName(actual), call, self.sourceText(ir.Read.operand(recv)), call });
            }
        }
        // A place where a view of it is expected: the sigil is missing.
        // (A literal is no place to lend.)
        const place = self.placeOf(e);
        switch (self.ctx.types.get(expected)) {
            .read_view, .write_view => |inner| if (place.named() and place.sym != null and compatible(self.ctx, actual, inner)) {
                const write = self.ctx.types.get(expected) == .write_view;
                // A read match's binding is written through `match !e`.
                if (write) {
                    const hint = try self.readMatchHint(place.sym);
                    if (hint.len > 0) return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}", .{ try self.tyName(expected), try self.tyName(actual), hint });
                }
                return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; lend it to {s}: `{c}{s}`", .{ try self.tyName(expected), try self.tyName(actual), if (write) "write" else "read", @as(u8, if (write) '!' else '?'), try self.plainText(e) });
            },
            else => {},
        }
        // A mask is no `Bool`: it is reduced or combined.
        if (expected == self.t().bool_id and sema.isMask(self.ctx, actual)) return self.maskAsBool(e, sema.unwrapViews(self.ctx, actual));
        // `not n` of an integer: the complement is a method.
        if (sameSite(e, self.not_operand) and expected == self.t().bool_id and sema.isInteger(self.ctx, sema.unwrapViews(self.ctx, actual))) {
            return self.errAt(e, "`not` takes a Bool; for the bitwise complement write `x.not()`", .{});
        }
        const match_hint = if (self.ctx.types.get(expected) == .write_view) try self.readMatchHint(place.sym) else "";
        if (match_hint.len > 0) return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}", .{ try self.tyName(expected), try self.tyName(actual), match_hint });
        try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`{s}{s}{s}", .{ try self.tyName(expected), try self.tyName(actual), try self.loopOrderHint(e, expected), self.staticHint(e, expected, actual), try self.ownerHint(e, expected, actual) });
    }

    /// Where a `String` is expected and a `?String` (or a `Static`) is
    /// given: a `String` owns its text, so the way out is a copy, or a
    /// place that only reads, `?String`.
    fn ownerHint(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error![]const u8 {
        if (expected != self.t().string_id) return "";
        if (actual != self.t().string_view_id and actual != self.t().static_id) return "";
        return self.ctx.arena.allocator().print("; a `String` owns its text: write `String({s})` to copy it, or declare the place `?String` to only read it", .{try self.plainText(e)});
    }

    /// Why a `?String` is not a `Static`, and the way out, when `actual`
    /// is the text of a `?String` (or a `String`) and `expected` a `Static`
    /// (also in an optional): the text may view a `String`, which a
    /// `Static` never does.
    fn staticHint(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) []const u8 {
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
        if (self.static_target.len > 0 and sameSite(e, self.static_target_value)) return self.ctx.arena.allocator().print("; `{s}` is a `Static`, bound to a literal's text, and a `?String` may view a `String`: declare it `{s}: ?String = ...` to hold other text", .{ self.static_target, self.static_target }) catch "";
        return "; a `Static` is a literal, or text derived only from literals, and a `?String` may view a `String`. A parameter or field that only reads its text is declared `?String`, which takes a `Static` too";
    }

    /// The type a variant literal (`.V`, `.V(...)`) takes where a view
    /// held by address goes (`?Val`, `!Color`, `(?Val)?`): the viewed
    /// type, as `Val.V(...)` has, so the literal is a value made where it
    /// stands, lent as one is or rejected. A view that holds a copy of
    /// the value (`?Color`, `sema.lendByValue`) takes the literal itself.
    /// Null for any other form or expected type, and for a name that is
    /// no variant of the viewed enum, which `checkContextual` reports
    /// (an error's name where a `T!` goes, too).
    fn variantUnderView(self: *Checker, e: Sexp, expected: TypeId) Error!?TypeId {
        const name = if (e.isKind(.enum_lit))
            ir.EnumLit.name(e)
        else if (e.isKind(.call) and ir.Call.callee(e).isKind(.enum_lit))
            ir.EnumLit.name(ir.Call.callee(e))
        else
            return null;
        const view = self.liftTarget(expected);
        switch (self.ctx.types.get(view)) {
            .read_view, .write_view => if (!sema.viewHeldAsPointer(self.ctx, view)) return null,
            else => return null,
        }
        const viewed = sema.unwrapViews(self.ctx, view);
        if (try sema.lookupVariant(self.ctx, viewed, self.text(name)) == null) return null;
        return viewed;
    }

    /// A form whose type comes from context: its type, or null when `e`
    /// is not one.
    fn checkContextual(self: *Checker, e: Sexp, expected: TypeId) Error!?TypeId {
        const target = self.liftTarget(expected);
        switch (e) {
            .src => {
                const s = self.text(e);
                if (std.mem.eql(u8, s, "none")) return try self.checkNone(e, expected);
                // A number literal where a view argument `?N` goes is lent
                // as `?5` is: a copy of the number.
                if (sameExpr(e, self.view_arg) and (sema.isIntLiteralText(s) or sema.isFloatLiteralText(s))) switch (self.ctx.types.get(expected)) {
                    .read_view => |inner| if (sema.isNumeric(self.ctx, inner)) {
                        try self.checkExpr(e, inner);
                        return inner;
                    },
                    else => {},
                };
                if (!sema.isIntLiteralText(s) or !sema.isInteger(self.ctx, target)) return null;
                try self.checkLiteralFits(e, target);
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
                try self.checkExpr(operand, inner);
                return expected;
            },
            .neg => {
                const operand = ir.Neg.operand(e);
                if (operand != .src or !sema.isIntLiteralText(self.text(operand)) or !sema.isInteger(self.ctx, target)) return null;
                try self.checkLiteralFits(e, target);
                try self.ctx.recordType(operand, target);
                return target;
            },
            .enum_lit => {
                // Where a `T!` is expected, `.name` is a variant of `T`: a
                // function fails only by naming the error set.
                const name = ir.EnumLit.name(e);
                if (target == self.t().any_error_id) return try self.resolveErrorName(name);
                if (self.ctx.types.get(expected) == .fallible and !self.isPoison(target) and
                    (try sema.lookupVariant(self.ctx, target, self.text(name))) == null)
                {
                    const sets = try sema.errorSetsWith(self.ctx, self.text(name));
                    if (sets.len > 0) {
                        try self.bareErrorName(name, target, sets);
                        return self.t().invalid_id;
                    }
                }
                try self.checkEnumLit(name, target);
                return target;
            },
            .call => {
                const callee = ir.Call.callee(e);
                if (callee.isKind(.enum_lit)) {
                    try self.checkPayloadVariant(e, target);
                    try self.ctx.recordType(callee, target);
                    return target;
                }
                // `Wrap(...)` where a `Wrap[Int]` is expected.
                const tt = self.ctx.types.get(target);
                if (callee != .src or tt != .parameterized_nominal) return null;
                const id = self.lookupQuiet(callee) orelse return null;
                if (id != tt.parameterized_nominal.sym) return null;
                _ = try self.useName(callee);
                if (id == self.ctx.signal_sym_id and !sameNode(e, self.shared_operand)) {
                    try self.errAt(callee, stack_signal, .{});
                    try self.synthArgs(ir.Call.args(e));
                } else if (id == self.ctx.list_sym_id) {
                    try self.checkListConstruction(e);
                } else {
                    const sym = self.ctx.symbols.items[id];
                    _ = try self.construct(id, ir.Call.args(e), callee.src.pos, .{ .params = sym.type_params orelse &.{}, .args = tt.parameterized_nominal.args }, null);
                }
                return target;
            },
            .builtin => {
                const ty = try self.synthBuiltin(e, target);
                return if (ty == self.t().int_literal_id) target else ty;
            },
            .lambda => {
                if (self.ctx.types.get(target) == .function) {
                    const ty = try self.checkLambda(e, target);
                    if (!sameNode(e, self.lent_callable) and !sameNode(e, self.callable_kept)) return ty;
                    // Reported here; the closure is not checked as escaping.
                    try self.errAt(e, "a closure literal is not a function value `{s}`; declare the parameter `?{s}` to lend the closure to the call", .{ try self.tyName(target), try self.tyName(target) });
                    return self.t().invalid_id;
                }
                if (sema.callableFn(self.ctx, target) != null) return try self.lentLambda(e, target);
                const fn_ty = self.ownedClosureType(target) orelse return null;
                try self.errAt(e, "`{s}` is an owned closure; write `*|...| body` to make one", .{try self.tyName(target)});
                _ = try self.checkLambda(e, fn_ty);
                return self.t().invalid_id;
            },
            .share => {
                const operand = ir.Share.operand(e);
                if (try self.shareOfNone(e, target)) return target;
                if (operand.isKind(.lambda) and sema.callableFn(self.ctx, target) != null) {
                    try self.errAt(e, "`{s}` views a closure for the call; write the closure without `*` (remove the `*`)", .{try self.tyName(target)});
                    _ = try self.checkLambda(operand, sema.callableFnTy(self.ctx, target).?);
                    return target;
                }
                if (operand.isKind(.lambda)) {
                    const ty = try self.ownedClosure(operand, self.ownedClosureType(target));
                    if (!compatible(self.ctx, ty, expected)) try self.mismatch(e, expected, ty);
                    return ty;
                }
                const tt = self.ctx.types.get(target);
                if (tt != .shared) return null;
                // `*` of a weak handle upgrades it whatever is expected
                // (`weakUpgrade`), so it makes no `*~T`: synthesized, it
                // mismatches. An operand typed where it stands is typed
                // first, and checked against the handle's value only where
                // it is no weak handle.
                if (self.ctx.types.get(sema.unwrapViews(self.ctx, tt.shared)) == .weak) return null;
                if (self.typedWhereItStands(operand)) {
                    const ty = try self.shareOperand(operand, null);
                    if (try self.weakUpgrade(e, ty)) |upgraded| {
                        if (!compatible(self.ctx, upgraded, expected)) try self.mismatch(e, expected, upgraded);
                        return upgraded;
                    }
                    if (self.isPoison(ty)) return target;
                    try self.recordUse(operand, .take);
                    if (operand == .list and self.ctx.quiet == 0) try self.expected.put(self.ctx.allocator, nodeId(operand), tt.shared);
                    try self.checkActual(operand, ty, tt.shared);
                    return target;
                }
                _ = try self.shareOperand(operand, tt.shared);
                return target;
            },
            .box => {
                if (sema.boxedType(self.ctx, target) == null) return null;
                const ty = try self.synthBox(e, target);
                return if (self.isPoison(ty)) ty else target;
            },
            .array => return self.checkArray(e, target),
            .array_fill => return if (self.ctx.types.get(target) == .array) try self.checkArrayFill(e, target) else null,
            .@"if" => _ = try self.checkIfValue(e, expected, .value),
            .match => _ = try self.checkMatch(e, .value, expected),
            .@"while", .@"for", .labeled => {
                if (!self.isValueLoop(e)) return null;
                _ = try self.checkLoopValue(e, expected, true);
            },
            .block => _ = try self.synthBlock(e, expected),
            .raw_block => {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                try self.checkExpr(ir.RawBlock.body(e), expected);
            },
            .@"??", .@"catch" => {
                const ty = if (head == .@"??") try self.synthCoalesce(e, expected) else try self.synthCatch(e, expected);
                // A view either branch gives is copied out where its
                // value is expected (`copiedOut`).
                if (compatible(self.ctx, ty, expected)) try self.recordAdapted(e, ty, expected) else try self.mismatch(e, expected, ty);
                return ty;
            },
            else => return null,
        }
        return expected;
    }

    /// `none` where `expected` is required: an optional (possibly
    /// fallible). Returns the optional type.
    fn checkNone(self: *Checker, e: Sexp, expected: TypeId) Error!TypeId {
        var ty = expected;
        while (true) {
            switch (self.ctx.types.get(ty)) {
                .optional => return ty,
                .fallible => |i| ty = i,
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
    fn liftTarget(self: *Checker, expected: TypeId) TypeId {
        var ty = expected;
        while (true) {
            switch (self.ctx.types.get(ty)) {
                .optional => |i| ty = i,
                .fallible => |i| ty = i,
                else => return ty,
            }
        }
    }

    /// Record how `e`, of type `actual`, adapts to the `expected` its
    /// context gives: a view copied out (`copiedOut`) is read through
    /// (`readOf`), and so is a write view lent where a read view that
    /// copies its value is expected; a literal takes a concrete type.
    fn recordAdapted(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        try self.recordAdaptedType(e, actual, expected);
        try self.recordLift(e, self.ctx.typeOf(e) orelse actual, expected);
    }

    /// Record the optional `e`'s value becomes where `expected` goes
    /// (`SemContext.recordLift`): `none`, which needs the optional's type,
    /// and a value of type `actual` (or the value a view of that type
    /// copies out, `copiedOut`) with fewer levels of optional than the
    /// optional `expected` is or holds, which Zig lifts into it on its own.
    /// Emit writes either explicitly where an optional is not Zig's `?T`
    /// (`sema.optionalRouted`). Any other value is no lift.
    fn recordLift(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        const ts = &self.ctx.types;
        var into = expected;
        while (ts.get(into) == .fallible) into = ts.get(into).fallible;
        if (ts.get(into) != .optional) return self.ctx.recordLift(e, null);
        if (e == .src and self.ctx.symbolOf(e) == null and std.mem.eql(u8, self.text(e), "none")) {
            return self.ctx.recordLift(e, .{ .into = into, .from = self.t().none_id });
        }
        var from = actual;
        while (!meets(self.ctx, from, into)) from = sema.copiedThrough(self.ctx, from) orelse return self.ctx.recordLift(e, null);
        switch (ts.get(from)) {
            .none_literal, .noreturn, .invalid, .unknown => return self.ctx.recordLift(e, null),
            else => {},
        }
        if (optionalDepth(self.ctx, from) >= optionalDepth(self.ctx, into)) return self.ctx.recordLift(e, null);
        try self.ctx.recordLift(e, .{ .into = into, .from = from });
    }

    fn recordAdaptedType(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        const lifted = self.liftTarget(expected);
        if (copiedOut(self.ctx, actual, expected)) return self.readOf(e, actual, .{ .slot = expected });
        if (self.ctx.types.get(actual) == .write_view) switch (self.ctx.types.get(lifted)) {
            .read_view => |inner| if (sema.lendByValue(self.ctx, inner)) return self.readOf(e, actual, .narrow),
            else => {},
        };
        if (actual != self.t().int_literal_id and actual != self.t().float_literal_id) return;
        const target = lifted;
        if (!sema.isNumeric(self.ctx, target)) return;
        if (self.ctx.types.get(target) == .float) if (integerOnlyOp(e)) |op| {
            return self.errAt(op, "operator `{s}` is for integers, and its literal operands here take the type `{s}`", .{ @tagName(op.kind().?), try self.tyName(target) });
        };
        try self.ctx.recordType(e, target);
        try self.recordLiteralType(e, target);
        if (actual == self.t().int_literal_id) try self.checkLiteralFits(e, target);
        if (self.ctx.types.get(target) == .float) try self.checkWholeDivision(e);
        try self.checkFloatConstant(e, target);
    }

    /// Whether `e` hands over a write view to a binding: each leaf of the
    /// value it gives (`sema.yieldedLeaves`: through an `if`, `match`,
    /// block, `??`, `catch`, `e!`, `e?`, and a loop used as a value) is a
    /// call's result, `!x`, `<w`, or a jump.
    fn yieldsWriteView(self: *Checker, e: Sexp) Error!bool {
        var leaves: std.ArrayList(Sexp) = .empty;
        defer leaves.deinit(self.ctx.allocator);
        try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
        if (leaves.items.len == 0) return false;
        for (leaves.items) |leaf| switch (leaf.kind() orelse return false) {
            .call, .result_part, .write, .move, .@"return", .@"break", .@"continue" => {},
            else => return false,
        };
        return true;
    }

    /// Every path in `decl` with a lend of a place as its base (`(!p).x`,
    /// `(?arr)[0]`, `(<(!p)).x`, `(?t).f(1)`): reported, in one walk over
    /// the typed tree that visits each field, element, and slice once, so
    /// no typing routine can route a path around the rule. The lend goes
    /// on the whole path (`!p.x`), and an assignment shows the write
    /// itself (`p.x = 5`). What a base is comes from `lendOf`. Not this
    /// rule's: a method's receiver (the positive fact `methods`), a value
    /// that branches (`(!a if c else !b).x`), which `lendOf` calls no
    /// lend, and a lend of a slice (`(?t[..])[0]`), whose written `!`
    /// only read is decided as any such read (`writeLendRead`).
    fn checkLendBases(self: *Checker, n: Sexp, root: Sexp, in_block: bool, module_level: bool) Error!void {
        if (n != .list) return;
        if (n.isKind(.member) or n.isKind(.index)) try self.lendBase(n, root, in_block, module_level);
        // A statement's parts are hinted at as that statement: each of a
        // block's statements, and an expression a function, a closure, or
        // a `match` arm has for its body. Only a block's statement can
        // have a binding put before it.
        const kind = n.kind() orelse .module;
        for (n.items()) |x| {
            const body = (kind == .lambda or kind == .fun or kind == .sub or kind == .arm) and x == .list and !x.isKind(.block) and isBodyOf(n, x);
            if (kind == .block or body) {
                try self.checkLendBases(x, x, kind == .block, false);
            } else try self.checkLendBases(x, root, in_block, module_level);
        }
    }

    /// Whether `x` is the body of `n`: a function's, a closure's, or an
    /// arm's.
    fn isBodyOf(n: Sexp, x: Sexp) bool {
        const body = switch (n.kind() orelse return false) {
            .lambda => ir.Lambda.body(n),
            .fun => ir.get(n, .body),
            .sub => ir.get(n, .body),
            .arm => ir.get(n, .body),
            else => return false,
        };
        return sameExpr(body, x);
    }

    /// `e`, a field, element, or slice, in statement `root` (a block's
    /// statement where `in_block`, or a module-level declaration):
    /// reported where its object is a lend of a place (`checkLendBases`).
    fn lendBase(self: *Checker, e: Sexp, root: Sexp, in_block: bool, module_level: bool) Error!void {
        const obj = ir.get(e, .object);
        const lend = self.lendOf(obj) orelse return;
        if (self.methods.contains(nodeId(e))) return;
        // The element of a Cell's List, assigned: the lend marks the Cell,
        // whose elements are copies and cannot be lent.
        if (e.isKind(.index) and lend.isKind(.write) and cellListElement(self.ctx, self.ctx.typeOf(obj) orelse sema.type_invalid) != null) return;
        if (isCallee(root, e)) {
            // The receiver sigil the parser moved onto a call of a field
            // holding functions (`!p.f[0]()`) is the call's to report, and
            // so is a method the call did not find (`(!s).nope()`).
            if (self.isReceiverSigil(obj)) return;
            if (!self.namesField(obj, e)) return;
        }
        var fix: LendBaseFix = .{ .c = self, .root = root };
        if (lendsSlice(lend)) {
            const ty = self.ctx.typeOf(obj) orelse return;
            if (self.writtenWriteLend(obj, ty) == null) return;
            if ((try fix.useOf(e, obj)).writes) return;
            _ = try self.writeLendRead(obj, ty, .{ .path = e });
            return;
        }
        try fix.collect(fix.root);
        const own = fix.edit(obj) orelse try fix.add(e, obj);
        const shown = try oneLine(self.ctx.arena.allocator(), self.sourceText(e));
        const head = "`{s}`: write a lend on the whole path, not its base";
        // No rewrite compiles where the path writes through a read lend
        // or a shared handle, takes a part that is no optional, or binds
        // a temporary where no statement can go first; each says why.
        if (own.writes and lend.isKind(.read)) return self.errAt(obj, head ++ "; and a read lend is not written through", .{shown});
        if (own.shared and (own.writes or std.mem.findScalar(u8, own.open, '!') != null)) return self.errAt(obj, head ++ "; and nothing is written through a shared handle (`*T`), which other handles may see", .{shown});
        if (own.taken and !own.temp and !own.optional) return self.errAt(obj, head ++ "; and `<` takes out only an optional field or element, leaving `none`", .{shown});
        // The hint is the line the statement is on: a statement spread
        // over lines, or a module-level value, which no plain path makes
        // constant, gets none. A lend its own check rejected gets none,
        // and so does a context no plain form fits.
        const src = self.ctx.source;
        const sp = self.ctx.span(obj);
        var ws: parser.Span = .{ .start = own.at, .end = own.at };
        while (ws.start > 0 and src[ws.start - 1] != '\n') ws.start -= 1;
        while (ws.start < own.at and (src[ws.start] == ' ' or src[ws.start] == '\t')) ws.start += 1;
        while (ws.end < src.len and src[ws.end] != '\n') ws.end += 1;
        var stmt = self.ownSpan(root);
        stmt.start = fix.start(root, stmt.start);
        const spread = stmt.start < ws.start or std.mem.trimEnd(u8, src[stmt.start..@max(stmt.start, stmt.end)], " \t\n").len > ws.end - stmt.start;
        if (own.none or own.to > ws.end or spread or module_level) return self.errAt(obj, head, .{shown});
        // An error inside the lend, or in the path after it (a field it
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
                if (!hasCodeWord(src, n)) break n;
            } else "tmp5";
            fix.named = .{ .lend = obj, .name = name };
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
    /// path's base, not a receiver.
    fn namesField(self: *Checker, obj: Sexp, e: Sexp) bool {
        if (!e.isKind(.member)) return true;
        const ty = self.ctx.typeOf(obj) orelse return false;
        if (self.isPoison(ty)) return false;
        return sema.lookupDataFieldConst(self.ctx, sema.unwrapAccess(self.ctx, ty), self.text(ir.Member.name(e))) != null;
    }

    /// The lend the object of a path, `e`, is: `?x` or `!x`, also moved,
    /// `<(!p)` (Core §4: a moved lend is the view it lends), by what `e`
    /// hands over (`sema.handsOver`), recorded the first time it is asked
    /// (`lend_of`). Null for anything else, a value that branches among
    /// them.
    fn lendOf(self: *Checker, e: Sexp) ?Sexp {
        if (e != .list) return null;
        const id = nodeId(e);
        if (self.lend_of.get(id)) |known| return known;
        const lend = self.lendUnder(e);
        self.lend_of.put(self.ctx.allocator, id, lend) catch {};
        return lend;
    }

    /// The place `lend` lends, under every sigil and every `<` of a lend
    /// on the way: `p` in `!(<(!p))`.
    fn lentThrough(self: *Checker, lend: Sexp) Sexp {
        var e = lentPlace(lend);
        while (e.isKind(.move)) {
            const inner = self.lendOf(e) orelse break;
            e = lentPlace(inner);
        }
        return e;
    }

    fn lendUnder(self: *const Checker, e: Sexp) ?Sexp {
        return switch (self.hands(e).kind) {
            .lend => e,
            .made => if (e.isKind(.move)) self.lendUnder(ir.Move.operand(e)) else null,
            else => null,
        };
    }

    /// `e`'s source with each lend that is a path's base taken off,
    /// for a diagnostic that names the place (`!p.o as v`).
    fn plainText(self: *Checker, e: Sexp) Error![]const u8 {
        var fix: LendBaseFix = .{ .c = self, .root = e, .bare = true };
        try fix.collect(e);
        if (fix.edits.items.len == 0) return self.sourceText(e);
        var out: std.ArrayList(u8) = .empty;
        const sp = self.ctx.span(e);
        try fix.write(&out, fix.start(e, sp.start), sp.end);
        return out.items;
    }

    /// The source of a statement with every lend written as a path's
    /// base (`lendBase`) taken off it, the whole path given the sigil its
    /// context takes (`useOf`).
    const LendBaseFix = struct {
        c: *Checker,
        root: Sexp,
        edits: std.ArrayList(Edit) = .empty,
        /// A temporary the hint binds to a name first, written as it.
        named: ?struct { lend: Sexp, name: []const u8 } = null,
        /// Every path written bare, its sigil dropped (`plainText`).
        bare: bool = false,

        const Edit = struct {
            lend: Sexp,
            /// The place lent, under its sigils and `<`.
            place: Sexp,
            top: Sexp,
            /// Whether the whole path is assigned to, a header's subject,
            /// taken (`<`), written as it stands (assigned, lent to write,
            /// taken, a `for` source written, or a write method's
            /// receiver), reached through a shared handle, or part of a
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
            /// Where a slice on the way ends, which is lent as a whole
            /// (`(?p.arr[0..2])[1]`), its parenthesis opened with `open`.
            slice_to: u32 = 0,
            /// Where the whole path starts and ends, and the lend's span
            /// with its parentheses.
            at: u32 = 0,
            to: u32 = 0,
            reach: u32 = 0,
            start: u32 = 0,
            end: u32 = 0,
        };

        fn collect(f: *LendBaseFix, n: Sexp) Error!void {
            if (n != .list or n.isKind(.lambda)) return;
            if (n.isKind(.member) or n.isKind(.index)) {
                const obj = ir.get(n, .object);
                if (f.c.lendOf(obj)) |lend| if (!lendsSlice(lend) and !f.c.methods.contains(nodeId(n)) and !(isCallee(f.root, n) and (f.c.isReceiverSigil(obj) or !f.c.namesField(obj, n)))) {
                    _ = try f.add(n, obj);
                };
            }
            for (n.items()) |x| try f.collect(x);
        }

        /// What the whole path that `path` with base `obj` starts is to
        /// its context, and the sigil that context takes: the facts typing
        /// recorded (the type expected there, a method's receiver mode, a
        /// value tail) and the tree around it.
        fn useOf(f: *LendBaseFix, path: Sexp, obj: Sexp) Error!Edit {
            const c = f.c;
            var top = path;
            while (parentIn(f.root, top)) |p| {
                if (!(p.isKind(.member) or p.isKind(.index)) or !sameExpr(ir.get(p, .object), top) or c.methods.contains(nodeId(p))) break;
                top = p;
            }
            const lend = c.lendOf(obj) orelse obj;
            const place = c.lentThrough(lend);
            var x: Edit = .{ .lend = obj, .place = place, .top = top };
            const sigil: []const u8 = if (lend.isKind(.write)) "!" else "?";
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
            if (c.hands(place).kind != .place) {
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
                // A header's subject: its binding takes the lend's sigil.
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
                    if (c.hands(place).kind != .place) x.none = true;
                },
                // A method's receiver: lent to write where the method
                // writes it (in parentheses where the call's `Bool` value
                // is used), and bare otherwise.
                .member => if (c.methods.get(nodeId(p))) |m| {
                    x.reach = c.ctx.span(p).end;
                    if (m.receiver == .write) {
                        x.writes = true;
                        const call = parentIn(f.root, p) orelse p;
                        const ret = c.ctx.types.get(m.returns);
                        const value = if (ret == .fallible) ret.fallible else m.returns;
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

        fn setValueSigil(f: *LendBaseFix, x: *Edit, top: Sexp, sigil: []const u8) void {
            if (f.valueSigil(top, sigil)) |open| {
                x.open = open;
            } else x.none = true;
        }

        /// The sigil a path read as a value takes from its context, or
        /// null where no plain form fits it:
        /// - a slice of an array, a List, or a String is a lend: `?` (`!`
        ///   where a write view goes);
        /// - where a write view is expected, `!`;
        /// - where a read view is, `?`, but none for an argument a `?T`
        ///   parameter takes (lent implicitly), or for a value that is a
        ///   view already;
        /// - where a value is, none if it copies, a clone `+` if it does
        ///   not, and null if it is not the value expected;
        /// - where nothing is expected, the lend's own sigil if the value
        ///   is taken and does not copy, and none otherwise.
        /// A leaf of a value that branches takes the branch's context.
        fn valueSigil(f: *LendBaseFix, top: Sexp, sigil: []const u8) ?[]const u8 {
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
            // A branch whose other leaves are lends takes their sigil.
            if (!sameExpr(at, top)) {
                var leaves: std.ArrayList(Sexp) = .empty;
                defer leaves.deinit(c.ctx.allocator);
                sema.yieldedLeaves(c.ctx.allocator, c.ctx.source, at, &leaves) catch return "";
                for (leaves.items) |l| {
                    if (l.isKind(.write)) return "!";
                    if (l.isKind(.read)) return "?";
                }
            }
            // A value taken that does not copy keeps the lend's sigil: a
            // binding's, an element's.
            if (!copies) {
                const taken = c.ctx.useOf(at) == .take or if (parentIn(f.root, at)) |p| p.isKind(.set) or p.isKind(.array) else false;
                if (taken) return sigil;
            }
            return "";
        }

        /// Whether `e` is an argument of a call of a function or a method,
        /// where a read view is lent without a written `?`; a type's
        /// constructor stores it.
        fn implicitArg(f: *LendBaseFix, e: Sexp) bool {
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

        fn spans(f: *const LendBaseFix, edit_: Edit, obj: Sexp) Edit {
            var x = edit_;
            const top = x.top;
            const src = f.c.ctx.source;
            var ls = f.c.ctx.span(obj);
            // Every pair of parentheses around the lend alone, `((!p))`,
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
            // A slice on the way below the top is lent as a whole: a lend
            // of a slice is a view, kept as a path's base.
            if (!f.bare) {
                var n = x.top;
                var slice: ?Sexp = null;
                while (n.isKind(.member) or n.isKind(.index)) : (n = ir.get(n, .object)) {
                    if (n.isKind(.index) and ir.Index.index(n).isKind(.@"..")) slice = n;
                    if (sameExpr(ir.get(n, .object), obj)) break;
                }
                // Only a place is sliced: a value that branches is not.
                if (slice != null and f.c.hands(x.place).kind != .place) x.none = true;
                if (slice) |sl| if (!sameExpr(sl, x.top)) {
                    const lend = f.c.lendOf(obj) orelse obj;
                    const sig: []const u8 = if (x.writes and lend.isKind(.write)) "(!" else "(?";
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

        fn add(f: *LendBaseFix, path: Sexp, obj: Sexp) Error!Edit {
            const x = try f.useOf(path, obj);
            try f.edits.append(f.c.ctx.arena.allocator(), x);
            return x;
        }

        fn edit(f: *const LendBaseFix, lend: Sexp) ?Edit {
            for (f.edits.items) |x| if (sameExpr(x.lend, lend)) return x;
            return null;
        }

        /// Where `n` starts: the first of its parts, which a sigil the
        /// tree moved inward (`!v[0].bump()`) may start before it.
        fn start(f: *const LendBaseFix, n: Sexp, from: u32) u32 {
            var s = from;
            if (n == .list and !n.isKind(.lambda)) {
                if (n.list.len > 1) s = @min(s, f.c.ctx.span(n).start);
                for (n.items()) |x| s = f.start(x, s);
            } else if (n == .src) s = @min(s, n.src.pos);
            return s;
        }

        /// The source from `from` to `to`, each edit within it applied.
        fn write(f: *const LendBaseFix, out: *std.ArrayList(u8), from: u32, to: u32) Error!void {
            return f.writeWithin(out, from, to, null);
        }

        /// `write`, inside the edit at `inside`, whose lend is not met again.
        fn writeWithin(f: *const LendBaseFix, out: *std.ArrayList(u8), from: u32, to: u32, inside: ?usize) Error!void {
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
                // sigil moved onto a path, a lend taken off it, or the
                // parenthesis that closes a path.
                const Step = enum { open, lend, close, slice_close };
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
                    next = .{ .i = i, .step = .lend };
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
                    .lend => {
                        if (f.named) |named| if (sameExpr(named.lend, x.lend)) {
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

    /// The part of statement `s` that is not another statement's: all of
    /// a simple statement, and the header of a loop, an `if`, or a
    /// `match`, up to its body.
    fn ownSpan(self: *Checker, s: Sexp) parser.Span {
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

    /// How a view is read as the value it reaches (`readOf`).
    const ViewRead = union(enum) {
        /// Copied out into a slot that stores or takes this plain type
        /// (`recordAdapted`).
        slot: TypeId,
        /// Read as this value: an operand, an index, a bound, a printed
        /// value.
        value: TypeId,
        /// Lent on to read: `?!x`.
        lent_to_read,
        /// Where this read view goes (a `?T`, a `[]T`, a `?String`), which
        /// only reads what it views.
        read_view: TypeId,
        /// A method's receiver it takes as a read view (`?self`).
        read_receiver: []const u8,
        /// The base of this path, which only reads what it reaches: a
        /// lend of a slice (`(!arr[..])[0]`, `lendBase`).
        path: Sexp,
        /// A held write view lent where a read view of a value that
        /// copies goes, which narrows it: no `!` is written there.
        narrow,
        /// Through it a place is reached, not read as a value.
        reach,
    };

    /// Record that `e`, a view of type `ty`, is read through (`recordRead`),
    /// the one place type checking records it: a read as a value is first
    /// decided by `writeLendRead`.
    fn readOf(self: *Checker, e: Sexp, ty: TypeId, how: ViewRead) Error!void {
        switch (how) {
            .slot, .value, .lent_to_read, .read_view, .read_receiver, .path => if (try self.writeLendRead(e, ty, how)) return,
            .narrow, .reach => {},
        }
        try self.ctx.recordRead(e);
    }

    /// The write lend written at `e`, of type `ty`: `!x`, or `<!x`, which
    /// moves the view `!x` makes. Its `!` says the view is held to write.
    /// Null for anything else, a held write view included (`w`, `h.w`, a
    /// `!T` parameter), which is read as a bare name is (Core sentence 1).
    fn writtenWriteLend(self: *Checker, e: Sexp, ty: TypeId) ?Sexp {
        if (self.ctx.types.get(ty) != .write_view) return null;
        return self.lendUnder(e);
    }

    /// Whether `e`, of type `ty`, read as a value `how` says, is a write
    /// lend written there (`writtenWriteLend`): its `!` would be ignored,
    /// so it is rejected (Core §4), and reported here. The one decider
    /// for every read of a view as a value (`readOf`), `print`'s values,
    /// and `?!x`; inference binds such a lend as the slot then reads it
    /// (`argType`).
    fn writeLendRead(self: *Checker, e: Sexp, ty: TypeId, how: ViewRead) Error!bool {
        const lend = self.writtenWriteLend(e, ty) orelse {
            // A value that branches or loops is read at each leaf it may
            // be (`sema.yieldedLeaves`), a written lend among them too.
            if (!sema.yieldsPart(e) and !self.isValueLoop(e)) return false;
            var leaves: std.ArrayList(Sexp) = .empty;
            defer leaves.deinit(self.ctx.allocator);
            try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
            var any = false;
            for (leaves.items) |leaf| {
                if (sameExpr(leaf, e)) continue;
                const leaf_ty = self.ctx.typeOf(leaf) orelse continue;
                if (try self.writeLendRead(leaf, leaf_ty, how)) any = true;
            }
            return any;
        };
        try self.ctx.recordType(e, self.t().invalid_id);
        // A `!` its operand's own check reported (one before a write
        // method's temporary receiver) is reported once.
        const sp = self.ctx.span(e);
        for (self.ctx.diagnostics.items) |d| if (d.severity == .@"error" and d.module == 0 and d.pos >= sp.start and d.pos < sp.end) return true;
        try self.ignoredWriteLend(e, lend, how);
        return true;
    }

    /// Whether a value of type `ty` goes where only a read view does: a
    /// `?T`, a `[]T`, or a `?String` (also as an optional), which holds no
    /// write view.
    fn readViewSlot(self: *Checker, ty: TypeId) bool {
        const lifted = self.liftTarget(ty);
        if (sema.holdsWriteView(self.ctx, lifted)) return false;
        return switch (self.ctx.types.get(lifted)) {
            .read_view, .slice, .string_view => true,
            else => false,
        };
    }

    /// The diagnostic for `e`, a write lend written where it is read as a
    /// value (`writeLendRead`), with the forms that say what is meant: a
    /// slot whose type holds the write view, or a copy written as one.
    fn ignoredWriteLend(self: *Checker, e: Sexp, lend: Sexp, how: ViewRead) Error!void {
        const a = self.ctx.arena.allocator();
        const place_node = unlent(lend);
        const place = self.sourceText(place_node);
        const head = "`{s}` here is read, not held: {s}. ";
        const shown = try self.plainText(e);
        const value_ty = switch (how) {
            .slot, .value => |slot_ty| slot_ty,
            else => sema.unwrapViews(self.ctx, self.ctx.typeOf(place_node) orelse self.t().invalid_id),
        };
        const ty = try self.tyName(value_ty);
        switch (how) {
            .slot => {},
            .lent_to_read => return self.errAt(e, head ++ "Write `?{s}`", .{ shown, "`?` lends it on to read", place }),
            .read_view => |view| {
                const slot = self.slot;
                const in_slot = sameExpr(e, slot.value) and slot.call != .nil and argOf(slot.call, e);
                const owner = if (!in_slot)
                    try a.print("a `{s}`", .{try self.tyName(view)})
                else if (slot.field)
                    try a.print("`{s}`", .{slot.owner})
                else
                    try a.print("`{s}`", .{try self.calleeName(ir.Call.callee(slot.call))});
                const lent = try a.print("?{s}", .{place});
                const fix = if (in_slot) try self.spliced(slot.call, &.{e}, &.{lent}) else lent;
                return self.errAt(e, "`{s}` here is read, not held: {s} only reads `{s}`; write `{s}`", .{ shown, owner, place, fix });
            },
            .path => |path| {
                // The slice lent to read: `(?arr[..])[0]`.
                const ps = self.ctx.span(path);
                const ls = self.ctx.span(lend);
                const fix = if (ls.start >= ps.start and ls.end <= ps.end) try std.mem.concat(a, u8, &.{ diag.textBetween(self.ctx.source, ps.start, ls.start), "?", place, diag.textBetween(self.ctx.source, ls.end, ps.end) }) else try a.print("?{s}", .{place});
                return self.errAt(e, head ++ "Write `{s}`", .{ shown, try a.print("`{s}` only reads the place it reaches", .{self.sourceText(path)}), fix });
            },
            .read_receiver => |method| {
                const call = self.current_call orelse Sexp.nil;
                const fix = if (call != .nil) try self.unparenthesized(call, e, place) else try a.print("{s}.{s}(...)", .{ place, method });
                return self.errAt(e, "`{s}` here is read, not held: `{s}` only reads `{s}`; write `{s}`", .{ shown, method, place, fix });
            },
            else => return self.errAt(e, head ++ "Write `{s}`", .{ shown, try a.print("only its `{s}` is read here", .{ty}), place }),
        }
        const slot = self.slot;
        const in_slot = sameExpr(e, slot.value) and slot.call != .nil and argOf(slot.call, e);
        if (in_slot and slot.field) self.ignored_in = slot.call;
        // What takes the value, and the value written without the `!`s
        // the slots of the call ignore.
        const what = if (!in_slot)
            try a.print("{s} `{s}` goes here", .{ article(ty), ty })
        else
            try a.print("`{s}` {s} {s} `{s}`", .{
                if (slot.field) slot.owner else try self.calleeName(ir.Call.callee(slot.call)),
                if (slot.field) "stores" else "takes",
                article(ty),
                ty,
            });
        const copy = if (in_slot) try self.withoutLends(slot.call, slot.lends, e) else place;
        const copied = if (!in_slot) "to copy the value" else if (slot.field) "to store a copy" else "to pass a copy";
        // A write view of a value made here would not outlive its
        // statement, and a field never holds one (`sema.misplaced`): the
        // copy is what can be meant.
        if (self.hands(place_node).kind != .place or (in_slot and slot.field)) return self.errAt(e, head ++ "Write `{s}` {s}", .{ shown, what, copy, copied });
        const must = if (in_slot)
            try a.print("to lend `{s}` to write, the parameter must be a `{s}`", .{ place, try self.tyName(try self.writeViewOf(if (slot.declared != sema.type_invalid) slot.declared else value_ty)) })
        else
            try a.print("to keep a write view of `{s}`, the type here must be `{s}`", .{ place, try self.tyName(try self.writeViewOf(value_ty)) });
        return self.errAt(e, head ++ "Write `{s}` {s}; {s}", .{ shown, what, copy, copied, must });
    }

    /// The source of `whole` with `part`, and the parentheses written
    /// around it (`(!p)` in `(!p).x`), written as `with`.
    fn unparenthesized(self: *Checker, whole: Sexp, part: Sexp, with: []const u8) Error![]const u8 {
        var ws = self.ctx.span(whole);
        if (whole.isKind(.call) and ir.Call.callee(whole).isKind(.member)) ws.start = @min(ws.start, self.ctx.span(ir.Member.object(ir.Call.callee(whole))).start);
        var ps = self.ctx.span(part);
        if (ps.start < ws.start or ps.end > ws.end) return with;
        // The parentheses stay where what is left needs them.
        const left = unlent(part);
        const bare = left == .src or left.isKind(.member) or left.isKind(.index) or left.isKind(.call);
        if (bare and ps.start > ws.start and ps.end < ws.end and diag.textBetween(self.ctx.source, ps.start - 1, ps.start).len == 1 and self.ctx.source[ps.start - 1] == '(' and diag.textBetween(self.ctx.source, ps.end, ps.end + 1).len == 1 and self.ctx.source[ps.end] == ')') {
            ps.start -= 1;
            ps.end += 1;
        }
        return std.mem.concat(self.ctx.arena.allocator(), u8, &.{ diag.textBetween(self.ctx.source, ws.start, ps.start), with, diag.textBetween(self.ctx.source, ps.end, ws.end) });
    }

    /// A method's receiver with the sigils written before it taken off
    /// (`?c`, `!c`, `<c`: `c`).
    fn receiverPlace(e: Sexp) Sexp {
        var node = e;
        while (node.isKind(.read) or node.isKind(.write) or node.isKind(.move)) node = ir.get(node, .operand);
        return node;
    }

    /// The place a write lend lends, every `!` and `<` written before it
    /// taken off (`!!n`, `<!n`: `n`).
    fn unlent(e: Sexp) Sexp {
        var node = e;
        while (node.isKind(.write) or node.isKind(.move)) node = ir.get(node, .operand);
        return node;
    }

    fn containsExpr(list: []const Sexp, e: Sexp) bool {
        for (list) |x| if (sameExpr(x, e)) return true;
        return false;
    }

    /// Whether `value` is one of `call`'s arguments, by position or by name.
    fn argOf(call: Sexp, value: Sexp) bool {
        if (!call.isKind(.call)) return false;
        for (ir.Call.args(call)) |arg| {
            const v = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
            if (sameExpr(v, value)) return true;
        }
        return false;
    }

    /// `call` as written with each of `lends`, arguments whose slots
    /// ignore their `!`, written as the place it lends; `e` is one.
    fn withoutLends(self: *Checker, call: Sexp, lends: []const Sexp, e: Sexp) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        var parts: std.ArrayList(Sexp) = .empty;
        var withs: std.ArrayList([]const u8) = .empty;
        var has_e = false;
        for (lends) |l| {
            if (sameExpr(l, e)) has_e = true;
            try parts.append(a, l);
            try withs.append(a, self.sourceText(unlent(l)));
        }
        if (!has_e) {
            try parts.append(a, e);
            try withs.append(a, self.sourceText(unlent(e)));
        }
        return self.spliced(call, parts.items, withs.items);
    }

    /// The arguments of a call or construction written `!x` (or `<!x`)
    /// whose slot type holds no write view: each would be read, its `!`
    /// ignored, which a diagnostic's suggested copy writes without.
    /// `types[i]` is the slot of `values[i]`.
    fn plainSlotLends(self: *Checker, values: []const Sexp, types: []const TypeId) Error![]const Sexp {
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
    fn writeViewOf(self: *Checker, ty: TypeId) Error!TypeId {
        return switch (self.ctx.types.get(ty)) {
            .optional => |inner| self.ctx.intern(.{ .optional = try self.writeViewOf(inner) }),
            .fallible => |inner| self.ctx.intern(.{ .fallible = try self.writeViewOf(inner) }),
            else => self.ctx.intern(.{ .write_view = ty }),
        };
    }

    /// The source of `whole` with each of `parts`, which it contains and
    /// which do not overlap, written as the matching `withs`.
    fn spliced(self: *Checker, whole: Sexp, parts: []const Sexp, withs: []const []const u8) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        var w = self.ctx.span(whole);
        // A receiver's sigil is written before the call's own span.
        if (whole.isKind(.call) and ir.Call.callee(whole).isKind(.member)) w.start = @min(w.start, self.ctx.span(ir.Member.object(ir.Call.callee(whole))).start);
        const order = try a.alloc(usize, parts.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, SpanOrder{ .ctx = self.ctx, .parts = parts }, SpanOrder.less);
        var out: std.ArrayList(u8) = .empty;
        var at = w.start;
        for (order) |i| {
            const p = self.ctx.span(parts[i]);
            if (p.start < at or p.end > w.end) continue;
            try out.appendSlice(a, diag.textBetween(self.ctx.source, at, p.start));
            try out.appendSlice(a, withs[i]);
            at = p.end;
        }
        try out.appendSlice(a, diag.textBetween(self.ctx.source, at, w.end));
        return out.items;
    }

    const SpanOrder = struct {
        ctx: *SemContext,
        parts: []const Sexp,
        fn less(o: SpanOrder, x: usize, y: usize) bool {
            return o.ctx.span(o.parts[x]).start < o.ctx.span(o.parts[y]).start;
        }
    };

    /// An operator in literal arithmetic `e` that only integers have
    /// (bitwise, shift, wrapping), whose literals cannot take a float
    /// type.
    fn integerOnlyOp(e: Sexp) ?Sexp {
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
    fn defaultIntLiteral(self: *Checker, e: Sexp) Error!void {
        try self.recordLiteralType(e, self.t().int_id);
        try self.checkLiteralFits(e, self.t().int_id);
    }

    /// Integer-literal arithmetic given integer type `target` is
    /// computed in it: each operation in `e` records the type, so that a
    /// wrapping one wraps there and a shift is folded in its width
    /// (`sema.ctFoldBy`), and the emitter types it so. A constant shift
    /// amount must be below that width.
    fn recordLiteralType(self: *Checker, e: Sexp, target: TypeId) Error!void {
        const h = e.kind() orelse return;
        switch (h) {
            .neg => try self.recordLiteralType(ir.Neg.operand(e), target),
            .@"if" => {
                try self.recordLiteralType(ir.If.then(e), target);
                try self.recordLiteralType(ir.If.@"else"(e), target);
            },
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^" => {
                try self.recordLiteralType(ir.get(e, .left), target);
                try self.recordLiteralType(ir.get(e, .right), target);
            },
            .@"<<", .@"<<%", .@">>" => {
                try self.recordLiteralType(ir.get(e, .left), target);
                if (self.ctx.types.get(target) != .int) return;
                const amount = ir.get(e, .right);
                const bits = intBounds(self.ctx.types.get(target).int).bits;
                if (self.constInt(amount)) |v| if (v >= bits) {
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
    fn checkWholeDivision(self: *Checker, e: Sexp) Error!void {
        const div = wholeDivision(self.ctx.source, e) orelse return;
        const left = ir.get(div, .left);
        const right = ir.get(div, .right);
        const op = @tagName(div.kind().?);
        const a = self.ctx.arena.allocator();
        const fix = if (left == .src)
            try a.print("{s}.0 {s} {s}", .{ self.text(left), op, self.sourceText(right) })
        else
            try a.print("Float({s}) {s} {s}", .{ self.sourceText(left), op, self.sourceText(right) });
        // A remainder of whole numbers is the same whole number as a
        // float's: only its type differs.
        if (div.isKind(.@"%")) return self.errAt(div, "`{s}` is a whole-number remainder; write `{s}` for a Float", .{ self.sourceText(div), fix });
        const whole: []const u8 = if (self.constInt(div)) |v| try a.print(" ({d})", .{v}) else "";
        if (floatConstIn(f64, self.ctx.source, div)) |f| {
            const shown = if (f == @trunc(f) and @abs(f) < 1e15) try a.print("{d}.0", .{f}) else try a.print("{d}", .{f});
            return self.errAt(div, "`{s}` divides whole numbers{s}; for {s} write `{s}`", .{ self.sourceText(div), whole, shown, fix });
        }
        try self.errAt(div, "`{s}` divides whole numbers{s}; for a float write `{s}`", .{ self.sourceText(div), whole, fix });
    }

    /// The number literals of an expression given float type `target`
    /// are values of it, and so is each operation on them, which the
    /// program computes in that type: a float literal must be in range,
    /// an integer literal exact, and a constant operation must not
    /// overflow. What was already found in `Float` arithmetic, where
    /// literals default to it, is not reported again for `F32`.
    fn checkFloatConstant(self: *Checker, e: Sexp, target: TypeId) Error!void {
        const bits = switch (self.ctx.types.get(target)) {
            .float => |f| f.bits,
            else => return,
        };
        switch (e) {
            .src => {
                const s = self.text(e);
                if (sema.isFloatLiteralText(s)) {
                    const v = floatLiteralValue(s);
                    if (bits == 32 and std.math.isFinite(v) and @abs(v) > std.math.floatMax(f32)) {
                        try self.errAt(e, "float literal `{s}` does not fit in `{s}`", .{ s, try self.tyName(target) });
                    }
                } else if (sema.isIntLiteralText(s)) {
                    const v = std.fmt.parseInt(Wide, s, 0) catch return;
                    if (!holdsInt(self.ctx, target, v) and (bits != 32 or holdsInt(self.ctx, self.t().float_id, v))) {
                        try self.errAt(e, "integer value `{d}` does not fit exactly in `{s}`", .{ v, try self.tyName(target) });
                    }
                }
            },
            .list => switch (e.kind() orelse return) {
                .neg => try self.checkFloatConstant(ir.Neg.operand(e), target),
                .@"if" => {
                    try self.checkFloatConstant(ir.If.then(e), target);
                    try self.checkFloatConstant(ir.If.@"else"(e), target);
                },
                .@"+", .@"-", .@"*", .@"/", .@"%" => {
                    try self.checkFloatConstant(ir.get(e, .left), target);
                    try self.checkFloatConstant(ir.get(e, .right), target);
                    const overflows = if (bits == 32)
                        floatOpOverflows(f32, self.ctx.source, e) and !floatOpOverflows(f64, self.ctx.source, e)
                    else
                        floatOpOverflows(f64, self.ctx.source, e);
                    if (overflows) try self.errAt(e, "this constant expression overflows `{s}`", .{try self.tyName(target)});
                },
                else => {},
            },
            else => {},
        }
    }

    /// A constant integer expression must fit the numeric type it gets:
    /// in range for an integer type, exactly for a float type.
    fn checkLiteralFits(self: *Checker, e: Sexp, target: TypeId) Error!void {
        const tt = self.ctx.types.get(target);
        if (tt != .int and tt != .float) return;
        switch (sema.constInt(self.ctx, e)) {
            .value => |v| if (!holdsInt(self.ctx, target, v)) switch (tt) {
                .int => |info| try self.errAt(e, "integer value `{d}` does not fit in `{s}` ({d}..{d})", .{ v, try self.tyName(target), intBounds(info).min, intBounds(info).max }),
                else => try self.errAt(e, "integer value `{d}` does not fit exactly in `{s}`", .{ v, try self.tyName(target) }),
            },
            .overflow => if (e == .src) {
                try self.errAt(e, "integer literal `{s}` is too large", .{self.text(e)});
            } else try self.errAt(e, "this constant expression overflows; its value does not fit in `{s}`", .{try self.tyName(target)}),
            // Not constant as a whole (a branch is chosen when the program
            // runs): its constant parts are values of the type too.
            .not_constant => if (e.kind()) |h| switch (h) {
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^" => {
                    try self.checkLiteralFits(ir.get(e, .left), target);
                    try self.checkLiteralFits(ir.get(e, .right), target);
                },
                .@"<<", .@"<<%", .@">>" => try self.checkLiteralFits(ir.get(e, .left), target),
                .neg => try self.checkLiteralFits(ir.Neg.operand(e), target),
                .@"if" => {
                    try self.checkLiteralFits(ir.If.then(e), target);
                    try self.checkLiteralFits(ir.If.@"else"(e), target);
                },
                else => {},
            },
        }
    }

    /// `.name` where a `T!` is expected names no variant of `T` but a
    /// member of an error set: say how to fail with it.
    fn bareErrorName(self: *Checker, name_node: Sexp, target: TypeId, sets: []const TypeId) Error!void {
        const name = self.text(name_node);
        const a = self.ctx.arena.allocator();
        const what = if (target == self.t().void_id)
            "a `sub` returns no value"
        else if (sema.enumVariantCount(self.ctx, target) != null)
            try a.print("`.{s}` is not a variant of `{s}`", .{ name, try self.tyName(target) })
        else
            try a.print("`.{s}` is not a value of `{s}`", .{ name, try self.tyName(target) });
        try self.errAt(name_node, "{s}; to fail, name the error set: {s}", .{ what, try self.errorChoices(sets, name, true) });
    }

    /// Error set `set` as this module writes it: `E`, or `m.E` for one
    /// of a module it imports as `m`, or of a module it only reaches,
    /// which it names by that module's name, and `import` is then set.
    const SetSpelling = struct { text: []const u8, import: ?[]const u8 = null };

    fn setSpelling(self: *Checker, set: TypeId) Error!SetSpelling {
        const a = self.ctx.arena.allocator();
        const decl = sema.nominalDecl(self.ctx, set) orelse return .{ .text = try self.tyName(set) };
        const sname = decl.symbol().name;
        const module = decl.module_id orelse return .{ .text = sname };
        for (self.ctx.imports) |imp| if (imp.module_id == module) return .{ .text = try a.print("{s}.{s}", .{ imp.local_name, sname }) };
        return .{ .text = try a.print("{s}.{s}", .{ decl.ctx.name, sname }), .import = decl.ctx.name };
    }

    /// `A.x`, `B.x`, or `C.x`: each of `sets` (with its member `name`,
    /// when `members`), saying which modules must be imported to write it.
    fn errorChoices(self: *Checker, sets: []const TypeId, name: []const u8, members: bool) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        const conj = if (members) "or" else "and";
        for (sets, 0..) |set, i| {
            if (i + 1 < sets.len) {
                if (i > 0) try out.appendSlice(a, ", ");
            } else if (i > 0) try out.print(a, "{s} {s} ", .{ if (sets.len > 2) "," else "", conj });
            const sp = try self.setSpelling(set);
            if (members) try out.print(a, "`{s}.{s}`", .{ sp.text, name }) else try out.print(a, "`{s}`", .{sp.text});
            if (members) if (sp.import) |m| try out.print(a, " (import `{s}` to name it)", .{m});
        }
        return out.items;
    }

    /// `.name` where any error is expected: the member of the one error
    /// set it may mean (`sema.errorSetsWith`). Its type is that set's, or
    /// poison when no set or several have it.
    fn resolveErrorName(self: *Checker, name_node: Sexp) Error!TypeId {
        const name = self.text(name_node);
        const sets = try sema.errorSetsWith(self.ctx, name);
        if (sets.len == 1) return sets[0];
        if (sets.len == 0) {
            try self.errAt(name_node, "no error set has a member `{s}`", .{name});
        } else {
            try self.errAt(name_node, "error sets {s} {s} have a member `{s}`; name the set: {s}", .{ try self.errorChoices(sets, name, false), if (sets.len == 2) "both" else "all", name, try self.errorChoices(sets, name, true) });
        }
        return self.t().invalid_id;
    }

    /// What a pattern for member `name` of error set `set` covers: the
    /// member alone where the subject is of that set, the set and the
    /// member where it may be any error.
    fn errorArmKey(self: *Checker, subject: TypeId, set: TypeId, name: []const u8) Error![]const u8 {
        if (subject != self.t().any_error_id) return name;
        return self.ctx.arena.allocator().print("{s}.{s}", .{ try self.tyName(set), name });
    }

    /// `E.name` or `m.E.name` as a pattern: a member of error set `E`,
    /// where the subject is of that set or is any error.
    fn checkQualifiedPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *MatchCoverage) Error!void {
        const ty = try self.synthExpr(pattern);
        const subject = sema.unwrapViews(self.ctx, scrutinee);
        const obj = ir.Member.object(pattern);
        const shown = try self.plainText(pattern);
        const name = self.text(ir.Member.name(pattern));
        if (self.isPoison(ty) or self.isPoison(subject)) {
            cov.rejected = true;
            return;
        }
        if (!self.ctx.isErrorMember(pattern)) {
            const module = if (obj == .src) if (self.ctx.symbolOf(obj)) |id| self.ctx.symbols.items[id].kind == .module else false else false;
            const value = module or self.ctx.typeOf(obj) != null;
            // `Color.red` meant `.red`, which the arm covers; what any
            // other rejected pattern meant is unknown.
            if (!value and ty == subject and (try sema.lookupVariant(self.ctx, ty, name)) != null) {
                try self.recordCovered(name, self.startOf(pattern), cov);
                return self.errAt(pattern, "a pattern names a variant without its enum: `.{s}`; only an error's pattern names its set", .{name});
            }
            cov.rejected = true;
            if (module) return self.errAt(pattern, "`{s}` is a constant, which a pattern cannot name; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
            if (value) return self.errAt(pattern, "`{s}` is a value, which a pattern cannot name; compare with it in a guard: `x if x == {s} =>`", .{ shown, shown });
            return self.errAt(pattern, "`{s}` is not a pattern; a qualified pattern names a member of an error set: `E.name`", .{shown});
        }
        if (subject != self.t().any_error_id and subject != ty) {
            cov.rejected = true;
            return self.errAt(pattern, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(subject), try self.tyName(ty) });
        }
        try self.recordCovered(try self.errorArmKey(subject, ty, name), self.startOf(pattern), cov);
    }

    fn checkEnumLit(self: *Checker, name_node: Sexp, expected: TypeId) Error!void {
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        if (self.isPoison(expected)) return;
        if (try sema.lookupVariant(self.ctx, expected, name)) |v| {
            if (v.payload.len > 0) {
                try self.err(pos, "variant `{s}` carries a payload; construct it with `.{s}(...)`", .{ name, name });
            }
            return;
        }
        try self.reportMissingVariant(expected, name, pos);
    }

    /// `.variant(payload...)` against an expected enum.
    /// `(call (enum_lit name) args...)`.
    fn checkPayloadVariant(self: *Checker, call: Sexp, expected: TypeId) Error!void {
        const name_node = ir.EnumLit.name(ir.Call.callee(call));
        const name = self.text(name_node);
        const pos = name_node.src.pos;
        const args = ir.Call.args(call);
        const resolved = (try sema.lookupVariant(self.ctx, expected, name)) orelse {
            try self.reportMissingVariant(expected, name, pos);
            try self.synthArgs(args);
            return;
        };
        const owner = resolved.owner_name;
        if (resolved.payload.len == 0) {
            if (args.len > 0) try self.err(pos, "variant `{s}` of enum `{s}` takes no payload", .{ name, owner });
            try self.synthArgs(args);
            return;
        }
        const decl_pos = if (resolved.nominal_sym == sema.symbol_invalid) sema.builtin_decl_pos else resolved.field.decl_pos;
        const module_id = if (resolved.nominal_sym == sema.symbol_invalid) 0 else self.ctx.symbols.items[resolved.nominal_sym].from.module_id;
        try self.checkFieldArgs(args, resolved.payload, .{ .owner = name, .decl_pos = decl_pos, .module_id = module_id, .pos = pos, .kind = .variant, .call = call });
    }

    /// `List()` / `List(capacity: n)`.
    fn checkListConstruction(self: *Checker, call: Sexp) Error!void {
        var seen: ?u32 = null;
        for (ir.Call.args(call)) |a| {
            if (!a.isKind(.kwarg)) {
                try self.errAt(a, "`List` constructor takes no positional arguments; use `List()` (empty) or `List(capacity: N)`", .{});
                _ = try self.synthExpr(a);
                continue;
            }
            const name = self.text(ir.Kwarg.name(a));
            const pos = ir.Kwarg.name(a).src.pos;
            if (!std.mem.eql(u8, name, "capacity")) {
                try self.err(pos, "`List` constructor accepts only `capacity` as a kwarg; got `{s}`", .{name});
                _ = try self.synthExpr(ir.Kwarg.value(a));
                continue;
            }
            if (seen) |first| {
                try self.err(pos, "duplicate `capacity` kwarg in `List` constructor", .{});
                try self.note(first, "first `capacity` here", .{});
            }
            seen = pos;
            try self.checkExpr(ir.Kwarg.value(a), self.t().int_id);
        }
    }

    /// Best-effort common type of two branches; reports on mismatch.
    fn unify(self: *Checker, a: TypeId, b: TypeId, pos: u32) Error!?TypeId {
        if (a == b) return a;
        if (self.isPoison(a) or a == self.t().noreturn_id) return b;
        if (self.isPoison(b) or b == self.t().noreturn_id) return a;
        if (a == self.t().none_id and self.ctx.types.get(b) == .optional) return b;
        if (b == self.t().none_id and self.ctx.types.get(a) == .optional) return a;
        // Integer and float literals meet as a float literal.
        if ((a == self.t().int_literal_id and b == self.t().float_literal_id) or (b == self.t().int_literal_id and a == self.t().float_literal_id)) return self.t().float_literal_id;
        if (compatible(self.ctx, a, b)) return b;
        if (compatible(self.ctx, b, a)) return a;
        // A viewed Copy value meets a value as the value.
        const va = readValue(self.ctx, a);
        const vb = readValue(self.ctx, b);
        if (va != a or vb != b) return self.unify(va, vb, pos);
        try self.err(pos, "incompatible types `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
        return null;
    }

    // =========================================================================
    // Builtins
    // =========================================================================

    /// Every builtin Rig has. Rig's own, the compile-time type queries
    /// `@size(T)`, `@align(T)`, `@name(T)`, and `@type(x)` as their
    /// argument, work anywhere. Zig's keep their Zig names and work only
    /// inside `raw`: the casts, and the queries under Zig's names
    /// (`@sizeOf`), which mean what Rig's do.
    const Builtin = enum {
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

        fn isSafe(b: Builtin) bool {
            return switch (b) {
                .size, .@"align", .name, .type, .variants => true,
                else => false,
            };
        }

        /// The type query `b` spells, by its Rig name, or null for a cast.
        fn query(b: Builtin) ?Builtin {
            return switch (b) {
                .size, .sizeOf => .size,
                .@"align", .alignOf => .@"align",
                .name, .typeName => .name,
                .type, .TypeOf => .type,
                else => null,
            };
        }
    };

    /// `@sizeOf(I64)` as Rig writes it, `@size(I64)`: each of Zig's
    /// names for a type query in `call` becomes Rig's.
    fn rigSpelling(self: *Checker, call: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = self.ctx.arena.allocator();
        var i: usize = 0;
        outer: while (i < call.len) {
            if (call[i] == '@') {
                for ([_][2][]const u8{ .{ "sizeOf", "size" }, .{ "alignOf", "align" }, .{ "typeName", "name" }, .{ "TypeOf", "type" } }) |pair| {
                    const after = i + 1 + pair[0].len;
                    if (std.mem.startsWith(u8, call[i + 1 ..], pair[0]) and (after == call.len or !(std.ascii.isAlphanumeric(call[after]) or call[after] == '_'))) {
                        try out.print(a, "@{s}", .{pair[1]});
                        i = after;
                        continue :outer;
                    }
                }
            }
            try out.append(a, call[i]);
            i += 1;
        }
        return out.items;
    }

    /// Zig's name for a type query outside `raw`: the fix-it writes the
    /// call `node` with Rig's names.
    fn zigQueryName(self: *Checker, node: Sexp, written: []const u8, rig_name: []const u8) Error!void {
        // From the name on: `@ sizeOf(I64)` is fixed as `@size(I64)`.
        const args = diag.textBetween(self.ctx.source, self.ctx.span(ir.Builtin.name(node)).end, self.ctx.span(node).end);
        const short = args.len <= 60 and std.mem.findScalar(u8, args, '\n') == null;
        const fix = if (short) try self.ctx.arena.allocator().print("@{s}{s}", .{ rig_name, try self.rigSpelling(args) }) else try self.ctx.arena.allocator().print("@{s}(...)", .{rig_name});
        try self.errAt(node, "write `{s}`: Rig's builtin is `@{s}`; Zig's `@{s}` works only inside `raw`", .{ fix, rig_name, written });
    }

    fn synthBuiltin(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const name_node = ir.Builtin.name(node);
        const name = self.text(name_node);
        const pos = name_node.src.pos;
        const args = ir.Builtin.args(node);
        const ty: TypeId = blk: {
            const builtin = std.meta.stringToEnum(Builtin, name) orelse {
                if (std.mem.eql(u8, name, "enumFromInt")) {
                    try self.err(pos, "builtin `@enumFromInt` is not supported; an integer becomes a plain enum with `@fromBackingInt`", .{});
                } else if (std.mem.eql(u8, name, "intFromFloat")) {
                    try self.err(pos, "builtin `@intFromFloat` is not supported; a float becomes an integer with `@trunc`", .{});
                } else {
                    try self.err(pos, "builtin `@{s}` is not supported; the builtins are `@size`, `@align`, `@type`, `@name`, `@variants`, and, inside `raw`, `@bitCast`, `@intCast`, `@floatCast`, `@truncate`, `@trunc`, `@floatFromInt`, `@fromBackingInt`", .{name});
                }
                try self.synthArgs(args);
                break :blk self.t().invalid_id;
            };
            if (builtin == .variants) break :blk try self.variantsOf(args, pos);
            const query = builtin.query();
            if (self.raw_depth == 0 and !builtin.isSafe()) {
                if (query) |q| {
                    try self.zigQueryName(node, name, @tagName(q));
                } else {
                    try self.err(pos, "builtin `@{s}` is not in the safe whitelist; wrap it in a `raw` block. Safe builtins: `@size`, `@align`, `@type`, `@name`, `@variants`", .{name});
                }
            }
            if (query) |q| switch (q) {
                .type => {
                    try self.err(pos, "`@{s}` is only allowed as the argument of `@size`, `@align`, or `@name`", .{name});
                    try self.synthArgs(args);
                    break :blk self.t().invalid_id;
                },
                else => {
                    if (!(try self.builtinTypeArg(name, args, pos))) break :blk self.t().invalid_id;
                    break :blk if (q == .name) self.t().string_view_id else self.t().int_literal_id;
                },
            };
            if (args.len != 1) {
                try self.err(pos, "`@{s}` takes one argument", .{name});
                try self.synthArgs(args);
                break :blk self.t().invalid_id;
            }
            const operand = try self.synthValue(args[0]);
            const target = expected orelse {
                try self.err(pos, "`@{s}` needs a known result type; bind it to an annotated name (`y: T = @{s}(x)`)", .{ name, name });
                break :blk self.t().invalid_id;
            };
            if (!self.isPoison(operand) and !self.isPoison(target)) {
                const to = self.liftTarget(target);
                if (self.castProblem(builtin, operand, to)) |why| {
                    try self.err(pos, "`@{s}` cannot turn `{s}` into `{s}`: {s}", .{ name, try self.tyName(operand), try self.tyName(target), why });
                    break :blk self.t().invalid_id;
                }
                // Zig converts a constant operand when it compiles, so the
                // value must convert.
                switch (builtin) {
                    .intCast, .floatFromInt => try self.checkLiteralFits(args[0], to),
                    .trunc => try self.checkFloatFits(args[0], to),
                    .fromBackingInt => if (self.constInt(args[0]) != null) {
                        try self.errAt(args[0], "`@fromBackingInt` of a constant: name the variant instead (`.name`)", .{});
                    },
                    else => {},
                }
            }
            break :blk target;
        };
        if (expected) |e| if (!self.isPoison(ty) and !compatible(self.ctx, ty, e)) try self.mismatch(node, e, ty);
        return ty;
    }

    /// `@variants(T)`: every variant of plain enum `T`, in declaration
    /// order, a `[N]T`.
    fn variantsOf(self: *Checker, args: []const Sexp, pos: u32) Error!TypeId {
        if (!(try self.builtinTypeArg("variants", args, pos))) return self.t().invalid_id;
        const ty = self.ctx.typeOf(args[0]) orelse return self.t().invalid_id;
        if (self.isPoison(ty)) return ty;
        const direct = switch (self.ctx.types.get(ty)) {
            .nominal, .imported_nominal => true,
            else => false,
        };
        if (!direct) {
            switch (self.ctx.types.get(ty)) {
                .optional, .read_view, .write_view => |inner| if (self.enumValues(inner) != null) {
                    const what: []const u8 = switch (self.ctx.types.get(ty)) {
                        .optional => "an optional",
                        .read_view => "a read view",
                        else => "a write view",
                    };
                    try self.errAt(args[0], "`@variants` takes an enum type; `{s}` is {s} of one: write `@variants({s})`", .{ try self.tyName(ty), what, try self.tyName(inner) });
                    return self.t().invalid_id;
                },
                else => {},
            }
            try self.errAt(args[0], "`@variants` takes an enum type; `{s}` is not one", .{try self.tyName(ty)});
            return self.t().invalid_id;
        }
        const plain = self.enumValues(ty) orelse {
            try self.errAt(args[0], "`@variants` takes an enum type; `{s}` is not an enum", .{try self.tyName(ty)});
            return self.t().invalid_id;
        };
        if (self.isBuiltinEnumTy(ty)) {
            try self.errAt(args[0], "`@variants(T)` takes a declared enum; `{s}` is a built-in enum", .{try self.tyName(ty)});
            return self.t().invalid_id;
        }
        if (!plain) {
            try self.errAt(args[0], "`@variants(T)` takes a plain enum; `{s}` has variants with payloads", .{try self.tyName(ty)});
            return self.t().invalid_id;
        }
        const decl = sema.nominalDecl(self.ctx, ty).?;
        var n: Wide = 0;
        for (decl.symbol().fields orelse &.{}) |f| {
            if (f.is_variant) n += 1;
        }
        return self.ctx.intern(.{ .array = .{ .elem = ty, .len = try sema.ctInt(self.ctx, n) } });
    }

    /// Why Zig would reject the cast builtin `cast` from `from` to `to`,
    /// or null when it accepts it.
    fn castProblem(self: *Checker, cast: Builtin, from: TypeId, to: TypeId) ?[]const u8 {
        const f = self.ctx.types.get(from);
        const t_ = self.ctx.types.get(to);
        const f_int = f == .int or f == .int_literal;
        const f_float = f == .float or f == .float_literal;
        switch (cast) {
            .intCast => if (!f_int or t_ != .int) return "it converts one integer type to another",
            .truncate => {
                if (!f_int or t_ != .int) return "it converts one integer type to another";
                if (f == .int) {
                    if (f.int.signed != t_.int.signed) return "both must be signed, or both unsigned";
                    if (numericBits(t_).? > numericBits(f).?) return "the result may not be wider";
                }
            },
            .floatCast => if (!f_float or t_ != .float) return "it converts one float type to another",
            .trunc => if (!f_float or t_ != .int) return "it converts a float to an integer",
            .floatFromInt => if (!f_int or t_ != .float) return "it converts an integer to a float",
            .fromBackingInt => if (!f_int or !sema.isPlainEnum(self.ctx, to)) return "it converts an integer to a plain enum",
            .bitCast => {
                const fb = numericBits(f) orelse return "it reinterprets a number of the same size";
                const tb = numericBits(t_) orelse return "it reinterprets a number of the same size";
                if (fb != tb) return "both must have the same size";
            },
            .size, .@"align", .name, .type, .sizeOf, .alignOf, .typeName, .TypeOf, .variants => {},
        }
        return null;
    }

    /// `@size(T)` / `@size(@type(x))`. A type argument, written as one is
    /// in an expression (`typeArg`), is recorded with the type it names.
    fn builtinTypeArg(self: *Checker, name: []const u8, args: []const Sexp, pos: u32) Error!bool {
        if (args.len != 1) {
            try self.err(pos, "`@{s}` takes one type argument", .{name});
            return false;
        }
        const a = args[0];
        if (a.isKind(.builtin) and ir.Builtin.args(a).len >= 1) {
            const inner = self.text(ir.Builtin.name(a));
            if (std.meta.stringToEnum(Builtin, inner)) |b| if (b.query() == .type) {
                // Under a query spelled Zig's way, its fix-it covers this one.
                const outer_rig = std.meta.stringToEnum(Builtin, name).?.isSafe();
                if (b != .type and self.raw_depth == 0 and outer_rig) try self.zigQueryName(a, inner, "type");
                const of = try self.synthExpr(ir.Builtin.args(a)[0]);
                try self.requireNamed(name, of, a);
                return true;
            };
        }
        // Written as in an expression: `List[Int]`, `?Point`, `Int?`.
        const ty = try self.typeArg(a);
        if (self.isPoison(ty)) return false;
        try self.ctx.recordType(a, ty);
        try self.requireNamed(name, ty, a);
        // A vector's size and alignment are the target's, so Rig gives
        // neither, nor those of a type that holds one inline.
        if (!std.mem.eql(u8, name, "name")) {
            if (sema.holdsVector(self.ctx, ty)) {
                try self.err(pos, "`@{s}` takes no type that holds a vector: `{s}` holds a `Simd`, whose size and alignment differ from target to target", .{ name, try self.tyName(ty) });
                return false;
            }
            var params: std.ArrayList(SymbolId) = .empty;
            try sema.heldTypeVars(self.ctx, ty, &params, self.ctx.arena.allocator());
            for (params.items) |param| try self.require(param, .sized, self.startOf(a), name);
        }
        return true;
    }

    /// `@name` of a type that holds type parameters names each one's
    /// instance as the program runs (`rig.typeName`), from its Zig type:
    /// each instance must hold no view it could not tell apart
    /// (`Requirement.named`).
    fn requireNamed(self: *Checker, builtin: []const u8, ty: TypeId, at: Sexp) Error!void {
        // Zig's `@typeName`, inside `raw`, names the Zig type.
        if (!std.mem.eql(u8, builtin, "name")) return;
        var params: std.ArrayList(SymbolId) = .empty;
        try sema.reachedTypeVars(self.ctx, ty, &params, self.ctx.arena.allocator());
        for (params.items) |param| try self.require(param, .named, self.startOf(at), "@name");
    }

    // =========================================================================
    // Closures
    // =========================================================================

    /// A closure literal lent where callable view `target` (a
    /// `?fun(...)`) is expected: only as a call's argument, and only to a
    /// call whose result cannot hold it, since it lives for the call.
    fn lentLambda(self: *Checker, e: Sexp, target: TypeId) Error!TypeId {
        const fn_ty = sema.callableFnTy(self.ctx, target).?;
        if (sameNode(e, self.callable_kept)) {
            try self.errAt(e, "this call's result may hold the callable it is lent, and a closure literal lives only for the call; bind the closure (`f = |...| ...`) and lend it as `?f`", .{});
        } else if (!sameNode(e, self.lent_callable)) {
            try self.errAt(e, "a closure literal is lent as `{s}` only as a call's argument; bind the closure (`f = |...| ...`) and lend it as `?f`", .{try self.tyName(target)});
        }
        const ty = try self.checkLambda(e, fn_ty);
        try self.ctx.recordLend(e, sema.lendsAs(self.ctx, fn_ty, .read, target).?);
        return ty;
    }

    /// `*|...| body`: an owned closure; `expected` is the function type
    /// its context gives it (`*fun(Int) -> Int` gives `fun(Int) -> Int`).
    fn ownedClosure(self: *Checker, lambda: Sexp, expected: ?TypeId) Error!TypeId {
        const lty = try self.checkLambda(lambda, expected);
        try self.ctx.recordType(lambda, lty);
        return self.ctx.intern(.{ .shared = lty });
    }

    /// The function type of owned closure type `ty` (`fun(Int) -> Int` for
    /// `*fun(Int) -> Int`, possibly as a view).
    fn ownedClosureType(self: *Checker, ty: TypeId) ?TypeId {
        if (sema.ownedClosureFn(self.ctx, ty) == null) return null;
        return self.ctx.types.get(sema.unwrapViews(self.ctx, ty)).shared;
    }

    /// A closure literal. Its type is a function type over its
    /// parameters. With an `expected` function type from context, bare
    /// parameters take its parameter types and the body is checked
    /// against its return type; without one, every parameter must be
    /// annotated and the return type is that of the body's last
    /// expression.
    fn checkLambda(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        return self.checkLambdaGiven(node, expected, &.{});
    }

    /// `checkLambda`, where without an `expected` type the parameters
    /// may take types from `given` (`type_invalid` for none).
    fn checkLambdaGiven(self: *Checker, node: Sexp, expected: ?TypeId, given_params: []const TypeId) Error!TypeId {
        const captures = sema.captureList(ir.Lambda.captures(node));
        const outer = self.scope;
        const prev = self.enter(node);
        const saved = self.body;
        defer {
            self.scope = prev;
            self.body = saved;
        }

        for (captures) |cap| try self.checkCapture(cap, outer);

        const want: ?FunctionType = if (expected) |e| self.ctx.types.get(e).function else null;
        // A closure that declares fewer parameters than the type it is
        // checked against is the closure with `_` for each trailing
        // parameter it leaves out (docs/INTERNALS.md, "Closures with
        // fewer parameters").
        const known: usize = if (want) |w| w.params.len else given_params.len;
        if (known > ir.Lambda.params(node).items().len and (want != null or known > 0)) {
            if (self.ctx.parser) |p| try p.padLambda(node, known);
            // The resolver ran before the padding: declare the new `_`s as
            // it declares the written ones.
            for (ir.Lambda.params(node).items()) |p| {
                if (self.ctx.symbolOf(p) != null) continue;
                const id = try self.ctx.addSymbol(.{
                    .name = "_",
                    .kind = .param,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = srcPos(p, 0),
                    .scope = self.scope,
                    .flags = .{},
                });
                try self.ctx.addToScope(self.scope, id);
                try self.ctx.recordName(p, id);
            }
        }
        const param_nodes = ir.Lambda.params(node).items();
        if (want) |w| if (param_nodes.len > w.params.len) {
            try self.errAt(node, "this closure takes {d} parameter{s}, but its type `{s}` passes {d}; a closure may take fewer, never more", .{ param_nodes.len, plural(param_nodes.len), try self.tyName(expected.?), w.params.len });
        };

        var params: std.ArrayList(TypeId) = .empty;
        defer params.deinit(self.ctx.allocator);
        var r = self.resolver();
        for (param_nodes, 0..) |p, i| {
            const pn = sema.paramNameNode(p) orelse continue;
            const name = self.text(pn);
            const given: ?TypeId = if (want) |w| (if (i < w.params.len) w.params[i] else null) else if (i < given_params.len and given_params[i] != sema.type_invalid) given_params[i] else null;
            var pty = self.t().invalid_id;
            if (p.isKind(.@":")) {
                pty = try r.resolveType(ir.@":".type(p));
                if (try r.misplacedAt(ir.@":".type(p), pty, .signature)) pty = self.t().invalid_id;
                if (given) |g| if (!self.isPoison(pty) and !self.isPoison(g) and pty != g) {
                    try self.errAt(pn, "closure parameter `{s}` is declared `{s}`, but the closure's type passes `{s}`", .{ name, try self.tyName(pty), try self.tyName(g) });
                };
            } else if (given) |g| {
                pty = g;
            } else if (want == null and !self.under_poison and !self.namesOuterLocal(outer, name, srcPos(pn, 0))) {
                try self.errAt(pn, "closure parameter `{s}` needs a type: annotate it (`|{s}: Int|`) or write the closure where its type is known (`f: fun(Int) -> Int = |{s}| ...`)", .{ name, name, name });
            }
            try params.append(self.ctx.allocator, pty);
            if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            try self.ctx.recordType(pn, pty);
        }

        if (want) |w| if (sema.returnsNothing(self.ctx, w.returns)) {
            // A closure that returns nothing has no value: its last line
            // is a statement, as a `sub`'s is.
            if (self.ctx.parser) |p| try p.dropTail(&@constCast(node.items())[ir.slot(.lambda, .body)]);
        };
        const body = ir.Lambda.body(node);
        if (want) |w| {
            // A closure whose type can fail sends a failure `!`
            // propagates to its caller.
            const fails = self.ctx.types.get(w.returns) == .fallible;
            try self.checkBody(body, .{ .ret = w.returns, .is_sub = w.is_sub, .fail_to = if (fails) .caller else .closure, .in_closure = true });
            return expected.?;
        }

        var sites: std.ArrayList(ReturnSite) = .empty;
        defer sites.deinit(self.ctx.allocator);
        self.body = .{ .ret = self.t().unknown_id, .is_sub = false, .fail_to = .closure, .returns = &sites, .in_closure = true };
        var ret = self.t().void_id;
        var ends_in_return = false;
        if (body.isKind(.block)) {
            const bprev = self.enter(body);
            defer self.scope = bprev;
            const stmts = ir.Block.stmts(body);
            if (stmts.len > 0) {
                for (stmts[0 .. stmts.len - 1]) |s| try self.checkStmt(s);
                const last = stmts[stmts.len - 1];
                ends_in_return = last.isKind(.@"return");
                // A closure ending in a statement, or an `if` without
                // `else`, returns nothing.
                const no_value = self.yieldsNoValue(last) or ifWithoutValue(last);
                // A closure's value is its result: it leaves the body,
                // as `return` takes it.
                ret = if (no_value) blk: {
                    try self.checkStmt(last);
                    break :blk self.t().void_id;
                } else blk: {
                    try self.recordUse(last, .take);
                    const mark = self.ctx.diagnostics.items.len;
                    const ty = try self.synthTail(last, null);
                    if (self.ctx.diagnostics.items.len == mark) try self.keptLends(last, .returned);
                    break :blk ty;
                };
            }
        } else {
            try self.recordUse(body, .take);
            const mark = self.ctx.diagnostics.items.len;
            ret = try self.synthTail(body, null);
            if (self.ctx.diagnostics.items.len == mark) try self.keptLends(body, .returned);
        }
        ret = self.canonical(ret);
        if (ret == self.t().noreturn_id) ret = self.t().void_id;
        ret = try self.reconcileReturns(sites.items, ret, ends_in_return, body);

        return self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(params.items), .returns = ret, .is_sub = sema.returnsNothing(self.ctx, ret) } });
    }

    /// The return type of a closure inferred from its body's value `ret`
    /// and its `return`s: a body ending in `return v` returns `v`'s type,
    /// and every `return` must agree with the result.
    fn reconcileReturns(self: *Checker, sites: []const ReturnSite, body_ret: TypeId, ends_in_return: bool, body: Sexp) Error!TypeId {
        var ret = body_ret;
        if (ret == self.t().void_id) {
            for (sites) |site| if (site.ty) |ty| {
                ret = self.canonical(ty);
                if (!ends_in_return and !self.isPoison(ret)) {
                    try self.errAt(lastStmt(body), "this closure returns `{s}` with `return`, so its body must end with a value or a `return`", .{try self.tyName(ret)});
                }
                break;
            };
        }
        for (sites) |site| {
            const ty = site.ty orelse {
                if (ret != self.t().void_id and !self.isPoison(ret)) {
                    try self.errAt(site.node, "a bare `return` in a closure that returns `{s}`; give it a value", .{try self.tyName(ret)});
                }
                continue;
            };
            // Each site is a `return`, whose operand may be an error value.
            const fails = self.ctx.types.get(ret) == .fallible and sema.isErrorValue(self.ctx, ty);
            if (!fails and !compatible(self.ctx, ty, ret)) {
                // A generic call only literals typed would take the type.
                const hint = if (self.literalResult(ir.Return.value(site.node)) != null and sema.isNumeric(self.ctx, ret))
                    try self.ctx.arena.allocator().print("; give the closure its type where it goes (`f: fun(...) -> {s} = |...| ...`), and every `return` takes it", .{try self.tyName(ret)})
                else
                    "";
                try self.errAt(site.node, "this closure returns `{s}`, but this `return` gives `{s}`{s}", .{ try self.tyName(ret), try self.tyName(ty), hint });
            } else try self.recordAdapted(ir.Return.value(site.node), ty, ret);
        }
        return ret;
    }

    /// `name` is a local of the function enclosing a closure. A closure
    /// parameter with that name is already reported as a missing sigil.
    fn namesOuterLocal(self: *Checker, outer: ScopeId, name: []const u8, pos: u32) bool {
        const id = self.lookupAt(outer, name, pos) orelse return false;
        return switch (self.ctx.symbols.items[id].kind) {
            .local, .param, .capture => true,
            else => false,
        };
    }

    /// Whether looking `name` up from `scope` leaves a closure body
    /// before finding it.
    fn closureBetween(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) bool {
        var sid: ?ScopeId = scope;
        while (sid) |s| {
            if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
            if (self.visibleIn(s, name, pos) != null) return false;
            if (self.ctx.scopes.items[s].kind == .lambda) return true;
            sid = self.ctx.scopes.items[s].parent;
        }
        return false;
    }

    /// `|?x|` / `|!x|`: the type of the view of outer binding `id`
    /// the closure holds, as `?x` / `!x` would have it. Poison after a
    /// diagnostic.
    fn captureLend(self: *Checker, id: SymbolId, name: []const u8, pos: u32, kind: LendKind) Error!TypeId {
        const sym = self.ctx.symbols.items[id];
        const ty = sym.ty;
        if (self.isPoison(ty)) return ty;
        switch (self.ctx.types.get(ty)) {
            .read_view => {
                if (kind == .read) return ty;
                const hint = try self.readMatchHint(id);
                if (hint.len > 0) {
                    try self.err(pos, "cannot lend to write through a read view `{s}`{s}", .{ try self.tyName(ty), hint });
                } else try self.err(pos, "cannot lend to write through a read view `{s}`; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
                return self.t().invalid_id;
            },
            .write_view => |base| return if (kind == .write) ty else self.ctx.intern(.{ .read_view = base }),
            .string_view => {
                if (kind == .read) return ty;
                try self.err(pos, "cannot lend `{s}` to write: it holds a read view of text, `?String`, which is pointed at other text by assigning to it; to change text in place, hold a `String`", .{name});
                return self.t().invalid_id;
            },
            .slice => if (kind == .write) {
                try self.err(pos, "cannot lend a `{s}` to write: its elements are read-only; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
                return self.t().invalid_id;
            },
            .function => if (sym.flags.closure) {
                if (kind == .read) return sema.callableOfFn(self.ctx, ty);
                try self.err(pos, "a call never changes what a closure captures, so a closure is lent to read; capture it with `|?{s}|`", .{name});
                return self.t().invalid_id;
            },
            else => {},
        }
        const root = self.rootOf(sym);
        if (kind == .write and !try self.requireAccess(.{ .pos = pos, .sym = id, .root = root }, .lend_write, .nil)) return self.t().invalid_id;
        return self.ctx.intern(if (kind == .read) Type{ .read_view = ty } else Type{ .write_view = ty });
    }

    /// Validate one capture against the outer binding and give the
    /// capture symbol its type.
    fn checkCapture(self: *Checker, cap: Sexp, outer: ScopeId) Error!void {
        const mode = sema.captureModeOf(cap) orelse return;
        const name_node = sema.captureNameNode(cap) orelse return;
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        const cap_sym = self.ctx.symbolOf(name_node) orelse return;

        const outer_id = self.lookupAt(outer, name, pos) orelse {
            try self.err(pos, "captured name `{s}` is not in scope", .{name});
            self.ctx.symbols.items[cap_sym].ty = self.t().invalid_id;
            return;
        };
        const outer_sym = self.ctx.symbols.items[outer_id];
        const local = switch (outer_sym.kind) {
            .local, .param, .capture => outer_sym.scope != sema.module_scope,
            else => false,
        };
        if (!local) {
            try self.err(pos, "only a local can be captured; `{s}` is declared at module level, so use it in the closure directly", .{name});
            self.ctx.symbols.items[cap_sym].ty = self.t().invalid_id;
            return;
        }
        // A closure reaches outer locals only through its own captures,
        // so a closure nested in one captures from what that one holds.
        if (self.closureBetween(outer, name, pos)) {
            try self.err(pos, "`{s}` is a local outside the enclosing closure; capture `{s}` in the enclosing closure first", .{ name, name });
            self.ctx.symbols.items[cap_sym].ty = self.t().invalid_id;
            return;
        }
        const outer_ty = self.ctx.symbols.items[outer_id].ty;
        if (mode == .cap_read or mode == .cap_write) {
            const ty = try self.captureLend(outer_id, name, pos, if (mode == .cap_read) .read else .write);
            self.ctx.symbols.items[cap_sym].ty = ty;
            self.ctx.symbols.items[cap_sym].origin = outer_id;
            try self.ctx.recordType(name_node, ty);
            return;
        }
        const bound: ?TypeId = switch (mode) {
            .cap_read, .cap_write => unreachable,
            .cap_move => outer_ty,
            .cap_weak => switch (self.ctx.types.get(outer_ty)) {
                .shared => |inner| try self.ctx.intern(.{ .weak = inner }),
                else => null,
            },
            .cap_clone => try self.cloneCapture(outer_ty, outer_sym.flags.closure, pos),
        };
        if (bound == null) if (mode == .cap_weak) {
            try self.err(pos, "weak-capture `|~{s}|` requires a shared handle `*T`; got `{s}`", .{ name, try self.tyName(outer_ty) });
        } else if (outer_sym.flags.closure or sema.isReadOrWriteView(self.ctx, outer_ty)) {
            // A closure or a view is captured as a view.
            const sigil: []const u8 = if (self.ctx.types.get(outer_ty) == .write_view) "!" else "?";
            try self.err(pos, "`|+{s}|` captures what `+x` gives (a copy, a new count of a handle, or a deep copy), but `{s}` is {s}`{s}`; capture it with `|{s}{s}|`", .{ name, name, if (outer_sym.flags.closure) "a closure of type " else "", try self.tyName(outer_ty), sigil, name });
        } else {
            try self.err(pos, "`|+{s}|` captures what `+x` gives (a copy, a new count of a handle, or a deep copy), but `{s}` is `{s}`, which has no clone; move it in with `|<{s}|`", .{ name, name, try self.tyName(outer_ty), name });
        };
        self.ctx.symbols.items[cap_sym].ty = bound orelse self.t().invalid_id;
        self.ctx.symbols.items[cap_sym].origin = outer_id;
        try self.ctx.recordType(name_node, bound orelse self.t().invalid_id);
    }

    /// The type `|+x|` captures for an `x` of type `ty`: what `+x` gives
    /// (Core §7). A handle, or one a view reaches, is counted again; a
    /// value that copies is copied (`sema.copies`), read through a view
    /// (`sema.copiedThrough`); an owner, or one a view reaches, is cloned
    /// part by part (`sema.cloneable`). Inside a generic body, copying a
    /// `T` requires that each instance copies. Null for a closure, a
    /// callable, or a value with no clone.
    fn cloneCapture(self: *Checker, ty: TypeId, closure: bool, pos: u32) Error!?TypeId {
        if (self.isPoison(ty)) return ty;
        if (closure or sema.holdsCallable(self.ctx, ty)) return null;
        switch (self.ctx.types.get(ty)) {
            .read_view, .write_view => {
                if (sema.copiedThrough(self.ctx, ty)) |value| return value;
                const value = sema.unwrapViews(self.ctx, ty);
                return switch (sema.cloneable(self.ctx, ty)) {
                    .bump, .text, .deep => value,
                    .copy, .depends, .no => null,
                };
            },
            else => {},
        }
        return switch (sema.cloneable(self.ctx, ty)) {
            .copy, .bump, .deep => ty,
            // A `?String` view clones into the `String` that owns its bytes.
            .text => if (ty == self.t().string_view_id) self.t().string_id else ty,
            .depends => if (try self.cannotCopy(ty, pos, "copies into a closure a value")) null else ty,
            .no => null,
        };
    }
};

// =============================================================================
// Compatibility and classification
// =============================================================================

/// The type an operator reads from an operand: a viewed Copy value
/// (`readValue`), or the `T` a viewed type parameter reaches. Every
/// `T` an operator's requirement admits is plain data, so reading one
/// through its view copies no resource.
fn operandValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| if (ctx.types.get(inner) == .type_var) inner else readValue(ctx, ty),
        else => ty,
    };
}

/// A view of a scalar (`sema.readsAsValue`) reads as the scalar to an
/// operator: `n + 1` with `n: ?Int` or `n: !Int` is an `Int`.
fn readValue(ctx: *const SemContext, ty: TypeId) TypeId {
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
fn bindingValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .write_view => sema.copiedThrough(ctx, ty) orelse ty,
        else => readValue(ctx, ty),
    };
}

/// Whether `ty` can be written in an expression's bracket list
/// (`id[Wrap[Int]](...)`): array, slice, and function types cannot.
fn spelledInBrackets(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .slice, .array, .function => false,
        .optional, .fallible, .read_view, .write_view, .shared, .weak => |inner| spelledInBrackets(ctx, inner),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (!spelledInBrackets(ctx, arg)) break false;
        } else true,
        else => true,
    };
}

/// `x` of `?x`, `!x`, or `<x`; any other node as it is.
fn stripSigil(e: Sexp) Sexp {
    return if (e.isKind(.read) or e.isKind(.write) or e.isKind(.move)) ir.get(e, .operand) else e;
}

/// The place `?x` or `!x` lends (through any number of them); any other
/// node, `<x` among them, as it is.
fn lentPlace(e: Sexp) Sexp {
    var p = e;
    while (p.isKind(.read) or p.isKind(.write)) p = ir.get(p, .operand);
    return p;
}

/// The leaf a place starts from: `a` in `!a.b[i]`.
fn placeRoot(e: Sexp) ?Sexp {
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
fn findMove(e: Sexp) ?Sexp {
    if (e != .list) return null;
    if (e.isKind(.move)) return e;
    for (e.items()) |c| if (findMove(c)) |m| return m;
    return null;
}

/// Can a value of type `actual` be used where `expected` is required?
/// As itself (`meets`), or as a copy of the value a view of it reaches
/// (`copiedOut`).
fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    return meets(ctx, actual, expected) or copiedOut(ctx, actual, expected);
}

/// Whether a view `actual` meets `expected` only as a copy of the value
/// it reaches (`sema.copiedThrough`): that value meets `expected`,
/// and the view itself does not. A view of a value that copies is copied
/// out where the value is expected (Core §4), and the view is read
/// through there (`Checker.recordAdapted`).
fn copiedOut(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    const inner = sema.copiedThrough(ctx, actual) orelse return false;
    return !meets(ctx, actual, expected) and compatible(ctx, inner, expected);
}

/// How many levels of optional `ty` has.
fn optionalDepth(ctx: *const SemContext, ty: TypeId) u32 {
    var n: u32 = 0;
    var t = ty;
    while (ctx.types.get(t) == .optional) : (n += 1) t = ctx.types.get(t).optional;
    return n;
}

/// Can a value of type `actual` be used as itself where `expected` is
/// required?
fn meets(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
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
        .read_view => |inner| if (sema.readsAsStringView(ctx, actual, expected)) return true else if (a == .write_view) return a.write_view == inner,
        // A `T!` holds a `T`; an error value meets it only as `return`'s
        // operand (`Checker.isReturnLeaf`).
        .fallible => |inner| return meets(ctx, actual, inner),
        // `error` holds an error of any set.
        .any_error => if (sema.isErrorSet(ctx, actual)) return true,
        // A `![]T` (or a `?[]T`) reads as the `[]T` it views.
        .slice => |want| switch (a) {
            .read_view, .write_view => |inner| if (inner == expected) return true,
            // The elements of a `[]Static` are read as `?String`s.
            .slice => |have| if (sema.readsAsStringView(ctx, have.elem, want.elem)) return true,
            else => {},
        },
        else => {},
    }
    return switch (a) {
        .int_literal => e == .int or e == .float,
        .float_literal => e == .float,
        else => false,
    };
}

const ReceiverTypeKind = enum { owned_nominal, read_view, write_view, shared, other };

/// What kind of value a method's receiver is, for the type whose symbol
/// is `nominal_sym` (`symbol_invalid` for an imported type).
fn classifyReceiverType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) ReceiverTypeKind {
    const matches = struct {
        fn f(c: *const SemContext, id: TypeId, sym: SymbolId) bool {
            // A box's value is reached as the box is: owned, or viewed.
            if (sym != c.box_sym_id) if (sema.boxedType(c, id)) |inner| return f(c, inner, sym);
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
    return switch (ctx.types.get(ty_id)) {
        .read_view => |i| if (matches(ctx, i, nominal_sym)) .read_view else .other,
        .write_view => |i| if (matches(ctx, i, nominal_sym)) .write_view else .other,
        else => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
    };
}

/// How a receiver is written: with a receiver sigil (`?v.m()`, `!v.m()`,
/// `<v.m()`, Core §8), or bare, by what it hands over
/// (`Checker.receiverShape`).
const ReceiverShape = enum { read_explicit, write_explicit, move_explicit, made, branches, place };

/// The sigil of a receiver sigil node, as written.
fn sigilText(recv: Sexp) []const u8 {
    return if (recv.isKind(.read)) "?" else if (recv.isKind(.write)) "!" else "<";
}

/// The element type of a Cell receiver (`Cell[T]`, `?Cell[T]`, `*Cell[T]`, ...).
fn cellElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.cell_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// The element type of a Cell holding a List (`Cell[List[E]]`, `?Cell[List[E]]`, `*Cell[List[E]]`, ...).
/// Whether `node` lies in the index of an element read in `tree`.
fn inIndex(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.index) and contains(ir.Index.index(tree), node)) return true;
    for (tree.items()) |item| if (inIndex(item, node)) return true;
    return false;
}

/// Whether `node` lies in an argument of a call in `tree`.
fn inArgument(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.call)) for (ir.Call.args(tree)) |a| if (contains(a, node)) return true;
    for (tree.items()) |item| if (inArgument(item, node)) return true;
    return false;
}

/// Whether `node` is `tree` or inside it.
fn contains(tree: Sexp, node: Sexp) bool {
    if (sameNode(tree, node)) return true;
    if (tree != .list) return false;
    for (tree.items()) |item| if (contains(item, node)) return true;
    return false;
}

fn cellListElement(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return listElementType(ctx, cellElementType(ctx, ty) orelse return null);
}


const slice_of_temporary = "only a named array, List, or String, or a field or element of one, can be sliced; bind this value to a name first";

const cell_list_handle = "cannot read or overwrite an element of a `{s}` in place: its elements are handles, which would be copied out or released while the cell holds them; `pop` the element, or `replace` the List to work on it";

/// The data field (not a method or variant) named `name`.
fn findDataField(ctx: *SemContext, fields: []const Field, name: []const u8) Error!?Field {
    return fields[(try sema.findMember(ctx, fields, name, .data)) orelse return null];
}

/// The element type of a `List[T]`.
fn listElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.list_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// An arithmetic operation: unary minus or a binary arithmetic,
/// bitwise, or shift operator.
fn isArithmetic(e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => true,
        else => false,
    };
}

/// `String` for a type that reaches a String through boxes and handles
/// (`sema.unwrapAccess`), which is viewed through them; any other type as
/// it is.
/// What a slice argument (`Checker.slicedArg`) of type `actual` lends
/// where a `view` is expected: the view it is, which goes where its own
/// type does (a `[]T` or a `?String`, or an optional of one). Null
/// elsewhere.
fn sliceArgLend(ctx: *const SemContext, actual: TypeId, view: TypeId) ?sema.Lend {
    return if (compatible(ctx, actual, view)) .{ .view = view } else null;
}

fn stringOrBoxed(ctx: *const SemContext, ty: TypeId) TypeId {
    return if (sema.unwrapAccess(ctx, ty) == ctx.types.string_id) ctx.types.string_id else ty;
}

/// Why enum `ty`, which has variants, is not plain: its payloads, or its
/// type parameters.
fn notPlainWhy(ctx: *const SemContext, ty: TypeId) []const u8 {
    const generic = if (sema.nominalDecl(ctx, ty)) |d| d.symbol().type_params != null else false;
    return if (generic) "is generic" else "has variants with payloads";
}

/// A String (boxed or not, or viewed), a `?String`, or a `Static`: `==`
/// compares any two of them by their bytes. A shared handle `*String` is
/// not text: a handle has no `==` or `.hash()`.
fn isText(ctx: *const SemContext, ty: TypeId) bool {
    if (sema.accessThroughShared(ctx, ty)) return false;
    const t = stringOrBoxed(ctx, ty);
    return t == ctx.types.string_id or t == ctx.types.string_view_id or t == ctx.types.static_id;
}

fn numericBits(t: sema.Type) ?u16 {
    return switch (t) {
        .int => |i| intBounds(i).bits,
        .float => |f| if (f.bits == 0) 64 else f.bits,
        else => null,
    };
}

const IntBounds = struct { min: Wide, max: Wide, bits: u8 };

/// The width and value range of an integer type.
fn intBounds(info: sema.IntInfo) IntBounds {
    const bits: u8 = if (info.bits == 0) 64 else info.bits;
    const half = @as(Wide, 1) << @intCast(bits - 1);
    return if (info.signed) .{ .min = -half, .max = half - 1, .bits = bits } else .{ .min = 0, .max = 2 * half - 1, .bits = bits };
}

/// The value of a float literal (`inf` when it is out of `F64`'s range).
fn floatLiteralValue(lit: []const u8) f64 {
    return floatLiteralAs(f64, lit);
}

fn floatLiteralAs(comptime F: type, lit: []const u8) F {
    return std.fmt.parseFloat(F, lit) catch 0;
}

/// The value of a constant expression of number literals computed in
/// float type `F` as the program computes it: each literal and each
/// operation rounded to `F`. Null when `e` is not one, or when an
/// operation in it overflows.
fn floatConstIn(comptime F: type, source: []const u8, e: Sexp) ?F {
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
fn floatLimit(comptime F: type, source: []const u8, e: Sexp) ?F {
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
fn floatOpOverflows(comptime F: type, source: []const u8, e: Sexp) bool {
    const a = floatConstIn(F, source, ir.get(e, .left)) orelse return false;
    const b = floatConstIn(F, source, ir.get(e, .right)) orelse return false;
    return floatOverflows(F, e.kind().?, a, b);
}

/// An operation on finite values whose result is infinite. Division by
/// zero gives an infinity or NaN instead.
fn floatOverflows(comptime F: type, h: Tag, a: F, b: F) bool {
    if (b == 0 and (h == .@"/" or h == .@"%")) return false;
    return std.math.isFinite(a) and std.math.isFinite(b) and !std.math.isFinite(floatOp(F, h, a, b));
}

fn floatOp(comptime F: type, h: Tag, a: F, b: F) F {
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
fn wideToFloat(comptime F: type, v: Wide) F {
    if (std.math.cast(i128, v)) |n| return @floatFromInt(n);
    const lo: u128 = @truncate(@as(u256, @bitCast(v)));
    const hi: i128 = @truncate(v >> 128);
    return @floatCast(@as(f64, @floatFromInt(hi)) * 0x1p128 + @as(f64, @floatFromInt(lo)));
}

/// The first division of whole-number literals (`7 / 2`, `9 % 4`) that
/// a literal context reaches in `e`: through negation, a ternary's
/// branches, `+`, `-`, `*`, a comparison of literals, and a division
/// that is not one.
fn wholeDivision(source: []const u8, e: Sexp) ?Sexp {
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
/// arithmetic and builtins (`@size(T)`) over them.
fn wholeLiterals(source: []const u8, e: Sexp) bool {
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
fn holdsInt(ctx: *const SemContext, ty: TypeId, v: Wide) bool {
    return switch (ctx.types.get(ty)) {
        .int => |info| v >= intBounds(info).min and v <= intBounds(info).max,
        .float => |f| blk: {
            const mantissa: u8 = if (f.bits == 32) 24 else 53;
            const a = @abs(v);
            break :blk a == 0 or @bitSizeOf(Wide) - @clz(a) - @ctz(a) <= mantissa;
        },
        else => true,
    };
}

/// `while true` with no `break` out of it: the loop only ends by
/// `return`, so a function may end with it.
fn loopsForever(source: []const u8, s: Sexp) bool {
    const loop = if (s.isKind(.labeled)) ir.Labeled.stmt(s) else s;
    return isWhileTrue(source, loop) and !sema.breaksOut(source, s, false);
}

fn isWhileTrue(source: []const u8, loop: Sexp) bool {
    return loop.isKind(.@"while") and std.mem.eql(u8, identAt(source, ir.While.cond(loop)) orelse "", "true");
}

/// The call whose value `e` is: `e` itself, or the call under a `!`,
/// `?`, `catch`, or on the left of `??`.
/// `return`, `break`, or `continue`: a fallback that jumps.
fn isJumpNode(e: Sexp) bool {
    return e.isKind(.@"return") or e.isKind(.@"break") or e.isKind(.@"continue");
}

/// Whether `e` names `name` anywhere in `source`.
fn readsNameIn(source: []const u8, e: Sexp, name: []const u8) bool {
    return switch (e) {
        .src => |leaf| std.mem.eql(u8, rig.leafText(source, leaf), name),
        .list => for (e.items()) |c| {
            if (readsNameIn(source, c, name)) break true;
        } else false,
        else => false,
    };
}

fn resultCall(e: Sexp) ?Sexp {
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
fn sameNode(a: Sexp, b: Sexp) bool {
    return a == .list and b == .list and a.list.ptr == b.list.ptr;
}

/// Whether `a` and `b` are the same node, a leaf by its place in the
/// source.
fn sameSite(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos and a.src.len == b.src.len;
    return sameNode(a, b);
}

/// `text` with each comment (`#` to the end of its line, outside a
/// string) taken out, for a hint that writes source spanning lines.
fn withoutComments(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
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
fn oneLine(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
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

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The id a node is recorded by.
fn nodeId(e: Sexp) parser.NodeId {
    return if (e == .list) e.list.id else 0;
}

/// Whether `lend` lends a slice, the view it makes (`?t[..]`).
fn lendsSlice(lend: Sexp) bool {
    const lent = lentPlace(lend);
    return lent.isKind(.index) and ir.Index.index(lent).isKind(.@"..");
}

/// Whether a postfix written after `e` binds to all of it: a name, a
/// field, an element, or a call.
fn postfixBinds(e: Sexp) bool {
    return e == .src or e.isKind(.member) or e.isKind(.index) or e.isKind(.call);
}

/// The node within `root` that holds `target` as a child, outside the
/// closures in it.
fn parentIn(root: Sexp, target: Sexp) ?Sexp {
    if (root != .list or root.isKind(.lambda)) return null;
    for (root.items()) |c| {
        if (sameExpr(c, target)) return root;
        if (parentIn(c, target)) |p| return p;
    }
    return null;
}

/// Whether member `m` within `root` names the method a call calls, with
/// or without compile-time arguments (`(!w).put[2](3)`).
fn isCallee(root: Sexp, m: Sexp) bool {
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
fn hasCodeWord(src: []const u8, word: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.findScalar(u8, line, '#')) |h| line[0..h] else line;
        if (hasWord(code, word)) return true;
    }
    return false;
}

/// Whether `text` holds `word` as a whole name.
fn hasWord(text: []const u8, word: []const u8) bool {
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
fn sameExpr(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos;
    return sameNode(a, b);
}

/// Forms whose type comes from the other operand: `.variant`,
/// `.variant(field: value)`, `none`.
fn isContextual(source: []const u8, e: Sexp) bool {
    if (e.isKind(.call) and ir.Call.callee(e).isKind(.enum_lit)) return true;
    return e.isKind(.enum_lit) or std.mem.eql(u8, identAt(source, e) orelse "", "none");
}

/// Literal forms allowed as default parameter values: the same text
/// means the same value at every call site, in any module.
fn isDefaultLiteral(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => isLiteralText(identAt(source, e).?) or std.mem.eql(u8, identAt(source, e).?, "none"),
        .list => e.isKind(.enum_lit) or
            (e.isKind(.neg) and ir.Neg.operand(e) == .src and isLiteralText(identAt(source, ir.Neg.operand(e)).?)),
        else => false,
    };
}

/// The last statement of a block (the block itself when it is empty),
/// or a lone statement.
fn lastStmt(body: Sexp) Sexp {
    if (!body.isKind(.block)) return body;
    const stmts = ir.Block.stmts(body);
    return if (stmts.len > 0) stmts[stmts.len - 1] else body;
}

/// An `if` (or `else if` chain) that lacks a final `else`.
fn ifWithoutValue(e: Sexp) bool {
    if (!e.isKind(.@"if")) return false;
    const other = ir.If.@"else"(e);
    return other == .nil or ifWithoutValue(other);
}

/// The value of a float literal, possibly negated: `2.5`, `-1e3`.
fn constFloatOf(source: []const u8, e: Sexp) ?f64 {
    if (e.isKind(.neg)) return -(constFloatOf(source, ir.Neg.operand(e)) orelse return null);
    const t = identAt(source, e) orelse return null;
    if (!sema.isFloatLiteralText(t)) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// `if c` with no `else`: a statement, never a value.
fn isIfWithoutElse(s: Sexp) bool {
    return s.isKind(.@"if") and ir.If.@"else"(s) == .nil;
}

/// An integer literal, possibly negated: `42`, `-1`.
fn isIntLiteralNode(source: []const u8, e: Sexp) bool {
    if (e.isKind(.neg)) return isIntLiteralNode(source, ir.Neg.operand(e));
    return e == .src and sema.isIntLiteralText(identAt(source, e) orelse "");
}

fn isLiteralText(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '"' or s[0] == '\'') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return true;
    return sema.isIntLiteralText(s) or sema.isFloatLiteralText(s);
}

/// The article before a type's name in a diagnostic: "an `Int`",
/// "a `String`".
fn article(name: []const u8) []const u8 {
    if (name.len == 0) return "a";
    return switch (name[0]) {
        'A', 'E', 'I', 'O', 'a', 'e', 'i', 'o' => "an",
        else => "a",
    };
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// =============================================================================
// Generic requirements
// =============================================================================

/// Every instantiation of a generic type, and every instance of a
/// generic function, must support the operations its bodies apply to
/// the type parameters (`self.value + 1` requires a numeric `T`). Checked
/// after all bodies, against every instance the module's code makes.
/// An instance's type arguments, each standing as one (`sema.misplaced`):
/// a value holding a Cell by value, or a write view, is no type argument.
/// True when one was reported, at the instance's `site`.
fn misplacedArgs(ctx: *SemContext, args: []const TypeId, site: u32) Error!bool {
    for (args) |arg| {
        if (sema.containsPoison(ctx, arg)) continue;
        const shown = try sema.formatType(ctx, arg);
        switch (sema.misplaced(ctx, arg, .type_arg) orelse continue) {
            .cell => try ctx.err(site, sema.cell_misplaced, .{ shown, shown }),
            .write_view => try ctx.err(site, sema.write_view_misplaced, .{shown}),
        }
        return true;
    }
    return false;
}

pub fn checkGenericInstantiations(ctx: *SemContext) Error!void {
    var reqs: Requirements = .empty;
    defer {
        var lists = reqs.valueIterator();
        while (lists.next()) |l| l.deinit(ctx.allocator);
        reqs.deinit(ctx.allocator);
    }
    for (ctx.generic_requirements.items, 0..) |req, i| {
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
        if (try misplacedArgs(ctx, pn.args, entry.value_ptr.*)) continue;
        const of: sema.InstanceRoot = .{ .type = entry.key_ptr.* };
        if (try checkRequirements(ctx, &reqs, params, pn.args, entry.value_ptr.*, of)) try checkInstanceSizes(ctx, params, pn.args, entry.value_ptr.*, of);
    }
    // A method's instance checks only its own parameters; its type's
    // are checked with the receiver's instance.
    var i: usize = 0;
    while (i < ctx.fn_instances.items.len) : (i += 1) {
        const f = ctx.fn_instances.items[i];
        if (try misplacedArgs(ctx, f.inst.ownArgs(), f.site)) continue;
        const of: sema.InstanceRoot = .{ .func = f.inst };
        if (try checkRequirements(ctx, &reqs, f.inst.ownParams(), f.inst.ownArgs(), f.site, of)) {
            try checkInstanceSizes(ctx, f.inst.params, f.inst.args, f.site, of);
        } else if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
    }
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
fn inlineFrame(ctx: *SemContext, pos: u32, depth: u32) Error!?[]const sema.FrameSlot {
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
fn checkOwnerTree(w: *FrameWalker, i: u32) Error!u32 {
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

const OwnerWalker = struct {
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

const FrameWalker = struct {
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
                        // A receiver a method takes by value is copied.
                        if (storage.receiverOf(ctx, node)) |recv| if (self.takesReceiver(node)) try self.copy(recv, f);
                        try self.addInlined(node, f);
                    }
                }
                const kids = rig.children(node);
                for (kids, 0..) |c, i| {
                    if (frame) |f| if (c.isKind(.@"defer") or c.isKind(.@"errdefer")) {
                        try self.deferBody(c, f, kids[i + 1 ..]);
                        continue;
                    };
                    try self.walk(c, frame, false, self.copiedIn(node, c));
                }
            },
        }
    }

    /// Whether the value of `child` is made or copied where `parent` uses
    /// it, by a positive list of the uses that read it in place: a callee,
    /// and the base of a field or element path or the operand of a lend
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

    /// Whether the method `call` calls takes its receiver by value, not
    /// through a view.
    fn takesReceiver(self: *FrameWalker, call: Sexp) bool {
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
    /// lent where it is used (a pointer) or fits in registers. A view its
    /// context reads through (`readsThrough`: a use that expects the
    /// value copies it out) counts at the size of what it views.
    fn copy(self: *FrameWalker, node: Sexp, f: *Slots) Error!void {
        const ctx = self.ctx;
        if (ctx.lendOf(node) != null) return;
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
const FrameParts = struct { copies: u32 = 0, marked: u32 = 0, marked_copies: u32 = 0, params: u32 = 0 };

/// A frame's count: its own values, what marked calls land in it
/// (`sema.Account`), and the reach of its parameters' copies where it is
/// inlined (`sema.FrameOwner.params`).
const FrameCounted = struct { own: sema.FrameCount, marked: sema.FrameCount, params: u128 = 0 };

/// Check the frame of `label` whose types are `tys`, laid out as `parts`
/// says: its count, its own values and what marked calls land in it
/// together, against `sema.max_frame_bytes` and its reach against
/// `sema.max_frame_reach`. A large one marks its declaration, at `decl`
/// in `module` (0 for this one), `noinline` (`sema.SemContext.large_frames`).
/// A marked `inline` function's frame is counted, for what the rule
/// inlines through it (`inlining.decide`), and not checked: Zig never
/// writes it, and its values land in each caller's, which is.
fn checkFrame(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, decl: u32) Error!?FrameCounted {
    return checkFrameIn(ctx, pos, label, of, tys, names, parts, 0, decl);
}

/// The count of the frame, null when a value in it follows an error. It
/// is recorded (`SemContext.frame_sizes`) as the frame of the owner
/// declared at `decl` in module `module` (0 for this one).
fn checkFrameIn(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, module: u32, decl: u32) Error!?FrameCounted {
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
    if (declared == ctx.module_id) try ctx.large_frames.put(ctx.allocator, decl, {}) else try ctx.large_foreign_frames.append(ctx.allocator, .{ .module = module, .pos = decl });
    return counted;
}

/// The bytes of the copies `tys`, each that does not fit in registers;
/// null when one follows an error.
fn reachBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
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
fn frameBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
    var total: u128 = 0;
    for (tys) |ty| {
        if (sema.containsPoison(ctx, ty)) return null;
        const b = (try sema.minBytes(ctx, ty)) orelse return null;
        if (b > sema.max_value_bytes) return null;
        total += b;
    }
    return total;
}

fn reportFrame(ctx: *SemContext, pos: u32, label: []const u8, bytes: u128, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8) Error!void {
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
/// type's instance itself, must fit `sema.max_value_bytes`.
fn checkInstanceSizes(ctx: *SemContext, params: []const SymbolId, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!void {
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

/// The positions of `generic_requirements` on each parameter, in order.
const Requirements = std.AutoHashMapUnmanaged(SymbolId, std.ArrayList(u32));

/// False after a diagnostic.
fn checkRequirements(ctx: *SemContext, reqs: *const Requirements, params: []const SymbolId, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    var ok = true;
    for (params, 0..) |param, i| {
        if (i >= args.len) break;
        const arg = args[i];
        // A diagnostic was reported about the argument.
        if (sema.containsPoison(ctx, arg)) continue;
        const on = reqs.getPtr(param) orelse continue;
        for (on.items) |r| {
            const req = ctx.generic_requirements.items[r];
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
                .array_len => try ctx.err(at, cannot ++ "uses `{s}` as an array length, which runs from 0 to {d}", .{ inst, pname, aname, pname, sema.max_array_len }),
                .lane_count => try ctx.err(at, cannot ++ "uses `{s}` as a lane count, a power of two from 2 to 64", .{ inst, pname, aname, pname }),
                .sized => try ctx.err(at, cannot ++ "takes `@{s}` of a type that holds a `{s}`, and `{s}` holds a vector, whose size and alignment differ from target to target", .{ inst, pname, aname, req.op, pname, aname }),
                .bytes => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` in bytes, which takes an integer or float type", .{ inst, pname, aname, req.op, pname }),
                .fits => |v| try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and the literal `{d}`, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, v, aname }),
                .float => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and a float literal, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, aname }),
                .shift => |v| try ctx.err(at, cannot ++ "shifts a `{s}` by {d} bits, which `{s}` is too narrow for", .{ inst, pname, aname, pname, v, aname }),
                .whole_division => try ctx.err(at, cannot ++ "gives a `{s}` the division of whole numbers `{s}`, which divides integers, not a `{s}`", .{ inst, pname, aname, pname, req.op, aname }),
                .not_error => try ctx.err(at, "`{s}` cannot use `{s} = {s}`: a return type `{s}!` would make a failure and a success both `{s}` values", .{ inst, pname, aname, pname, aname }),
                .not_function => try ctx.err(at, cannot ++ "makes a handle `{s}{s}` of a `{s}`, and `{s}` is a function type: `*{s}` is an owned closure, not a handle of a function. Hold the owned closure itself in a `{s}`: `{s} = *{s}`", .{ inst, pname, aname, req.op[1..2], pname, pname, aname, aname, pname, pname, aname }),
                .named => {
                    const held = sema.unnameable(ctx, arg).?;
                    const what = if (held == arg) "is one" else try ctx.arena.allocator().print("holds `{s}`", .{try sema.formatType(ctx, held)});
                    try ctx.err(at, cannot ++ "names a type that holds a `{s}` with `@name`, which spells no view or slice in a type parameter's instance but a `?String`, and `{s}` {s}", .{ inst, pname, aname, pname, aname, what });
                },
                .equatable => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support: {s}", .{ inst, pname, aname, req.op, pname, aname, try notEquatableReason(ctx, (try sema.notEquatable(ctx, arg, null)).?) }),
                .hashable => if (try sema.notHashable(ctx, arg, null)) |n|
                    try ctx.err(at, cannot ++ "hashes a `{s}` with `.hash()`, which `{s}` does not support: {s}", .{ inst, pname, aname, pname, aname, try notEquatableReason(ctx, n) })
                else
                    try ctx.err(at, cannot ++ "hashes a `{s}` with the built-in `.hash()`, and `{s}` declares a `hash` of its own, which that would not call", .{ inst, pname, aname, pname, aname }),
                else => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support", .{ inst, pname, aname, req.op, pname, aname }),
            }
            switch (req.req) {
                .copies, .no_cleanup => try ctx.noteIn(req.module_id, req.pos, "here", .{}),
                .array_len => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as an array length here", .{pname}),
                .lane_count => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as a lane count here", .{pname}),
                .bytes, .fits, .float, .shift, .whole_division => try ctx.noteIn(req.module_id, req.pos, "`{s}` used here", .{req.op}),
                .not_error => try ctx.noteIn(req.module_id, req.pos, "`{s}!` returned here", .{pname}),
                .not_function => try ctx.noteIn(req.module_id, req.pos, "`{s}{s}` here", .{ req.op[1..2], pname }),
                .named => try ctx.noteIn(req.module_id, req.pos, "`@name` here", .{}),
                else => try ctx.noteIn(req.module_id, req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() }),
            }
            ok = false;
            break;
        }
    }
    return ok;
}

/// Whether `ty` is a type that declares a method `hash`, which a call
/// `x.hash()` on it reaches instead of the built-in one.
fn declaresHash(ctx: *SemContext, ty: TypeId) bool {
    return sema.methodReceiver(ctx, ty, "hash") != null;
}

/// Why `==` is not defined for a type, as a diagnostic says it.
fn notEquatableReason(ctx: *SemContext, n: sema.NotEquatable) Error![]const u8 {
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
    };
}

fn satisfies(ctx: *SemContext, ty: TypeId, req: Requirement) Error!bool {
    return switch (req) {
        .numeric, .bytes => sema.isNumeric(ctx, ty),
        .ordered => sema.isNumeric(ctx, ty) or ctx.types.get(ty) == .string_view or ctx.types.get(ty) == .static or sema.isOrderedEnum(ctx, ty),
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
        .no_cleanup => !sema.typeHasDropGlue(ctx, ty),
        .lane_count => switch (ctx.types.get(ty)) {
            .ct_value => |v| sema.lanesInRange(v.int),
            else => false,
        },
        .sized => !sema.holdsVector(ctx, ty),
        .array_len => switch (ctx.types.get(ty)) {
            .ct_value => |v| v.int >= 0 and v.int <= sema.max_array_len,
            else => false,
        },
        .equatable => sema.isEquatable(ctx, ty),
        .hashable => isText(ctx, ty) or ((try sema.notHashable(ctx, ty, null)) == null and !declaresHash(ctx, ty)),
        .whole_division => sema.isInteger(ctx, ty),
        .not_error => ctx.types.get(ty) != .any_error and !sema.isErrorSet(ctx, ty),
        .not_function => ctx.types.get(ty) != .function,
        .named => sema.unnameable(ctx, ty) == null,
    };
}

// =============================================================================
// Tests
// =============================================================================

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { ctx: SemContext, p: parser.Parser, tree: Sexp } {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const tree = try p.parseProgram();
    const ctx = try sema.check(allocator, source, tree, .{ .is_root = true });
    return .{ .ctx = ctx, .p = p, .tree = tree };
}

fn expectDiagnostic(ctx: *const SemContext, needle: []const u8) !void {
    for (ctx.diagnostics.items) |d| {
        if (std.mem.find(u8, d.message, needle) != null) return;
    }
    std.debug.print("missing diagnostic containing: {s}\n", .{needle});
    for (ctx.diagnostics.items) |d| std.debug.print("  got: {s}\n", .{d.message});
    return error.TestExpectedDiagnostic;
}

fn expectClean(ctx: *const SemContext) !void {
    for (ctx.diagnostics.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try std.testing.expect(!ctx.hasErrors());
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

test "check: lending on a view parameter" {
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
        \\  fun check(?self) -> Int!
        \\    self.n
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

test "check: every read of a view as a value is decided by writeLendRead" {
    // `readOf` is the one place type checking records that a view is read
    // as the value it reaches, and it asks `writeLendRead` first. Another
    // call of `recordRead` would read a written `!x` as a value with its
    // `!` ignored, past the decider.
    const needle = "ctx." ++ "recordRead(";
    const src = @embedFile("typecheck.zig");
    try std.testing.expectEqual(1, std.mem.count(u8, src, needle));
    const at = std.mem.indexOf(u8, src, needle).?;
    const fn_at = std.mem.lastIndexOf(u8, src[0..at], "    fn ").?;
    try std.testing.expect(std.mem.startsWith(u8, src[fn_at..], "    fn readOf("));
    try std.testing.expect(std.mem.indexOf(u8, src[fn_at..at], "self.writeLendRead(") != null);
    // Every pass after type checking reads the fact; none records it.
    for ([_][]const u8{ @embedFile("emit.zig"), @embedFile("ownership.zig"), @embedFile("storage.zig"), @embedFile("resolve.zig") }) |other| {
        try std.testing.expectEqual(0, std.mem.count(u8, other, needle));
    }
}

test "check: where a Cell and a write view stand, and a branch lent in place, are each decided once" {
    // Where a Cell and a write view may stand is one decider in sema,
    // `misplaced` (its write-view half, `writeViewMisplaced`, needs no
    // contents, so a type is rejected where it is written). Type
    // resolution asks it of every spelled type through `misplacedAt`,
    // typecheck of each generic instance's arguments, and of an array
    // literal's element; no other pass asks it.
    const sema_src = @embedFile("sema.zig");
    const tc = @embedFile("typecheck.zig");
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
    // Every lend of a branch, written or in place, asks `lendsBranch`:
    // a sigil, a slice, a write lend of a temporary, a weak handle `*`
    // upgrades, a temporary lent to read, a header's subject, and a view
    // a context takes in place.
    const call = "self." ++ "lendsBranch(";
    var from: usize = 0;
    for ([_][]const u8{ "headerLendsBranch", "synthLend", "lendsToWrite", "lendSlice", "weakUpgrade", "lendTempIn", "checkExpr" }) |want| {
        from = std.mem.indexOfPos(u8, tc, from, call).?;
        const fn_at = std.mem.lastIndexOf(u8, tc[0..from], "    fn ").?;
        const got = tc[fn_at + "    fn ".len .. fn_at + std.mem.indexOfScalar(u8, tc[fn_at..], '(').?];
        try std.testing.expectEqualStrings(want, got);
        from += call.len;
    }
    try std.testing.expect(std.mem.indexOfPos(u8, tc, from, call) == null);
    // What a Cell kept by value needed is gone: no per-instance
    // interior mutability, Cell temporaries, or write through a field.
    for ([_][]const u8{ "interior" ++ "Mutable", "ReadPtr" ++ "(", "lendsCell" ++ "Temp", "refuseHeld" ++ "Cell", "payloadReads" ++ "ThroughWrite", "headerCopies" ++ "WriteView" }) |gone| {
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

test "check: a binding's mode is decided once, by decideBindingAccess" {
    // A view binding's access (can a write go through it) is one fact,
    // decided by `sema.decideBindingAccess` and recorded on its symbol.
    // Typecheck derives the binding's type from it at each kind of binding
    // (a match, `as`, a loop), ownership the loan a lend of it makes, and
    // emit how it binds: no pass derives a binding's mode another way.
    const decide = "sema." ++ "decideBindingAccess(";
    const record = "].access" ++ " = ";
    const tc = @embedFile("typecheck.zig");
    try std.testing.expectEqual(3, std.mem.count(u8, tc, decide));
    var at: usize = 0;
    for ([_][]const u8{ "    fn loopElement(", "    fn bindMatchView(", "    fn asAccess(" }) |want| {
        at = std.mem.indexOfPos(u8, tc, at, decide).?;
        const fn_at = std.mem.lastIndexOf(u8, tc[0..at], "    fn ").?;
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
    for ([_][]const u8{ "    fn checkOptionalBinding(", "    fn loopElement(", "    fn bindMatchView(" }) |want| {
        at = std.mem.indexOfPos(u8, tc, at, derive).?;
        const fn_at = std.mem.lastIndexOf(u8, tc[0..at], "    fn ").?;
        try std.testing.expect(std.mem.startsWith(u8, tc[fn_at..], want));
        at += derive.len;
    }
    try std.testing.expectEqual(0, std.mem.count(u8, tc, "asBinding" ++ "Type("));
    // Whether a header lends on a write view its subject makes, and
    // whether it would copy one out of a place, are each one decider in
    // sema, by a positive list, which `match` and `as` share.
    const Shared = struct { call: []const u8, callers: []const []const u8 };
    for ([_]Shared{
        .{ .call = "sema." ++ "makesWriteView(", .callers = &.{ "checkOptionalBinding", "checkOptionalBinding", "matchReach" } },
        // Every header kind, `match`, `if … as` / `while … as`, and `for`,
        // lends a branching subject where it stands: none can skip it.
        .{ .call = "self." ++ "headerLendsBranch(", .callers = &.{ "checkOptionalBinding", "checkFor", "checkMatch" } },
    }) |shared| {
        try std.testing.expectEqual(shared.callers.len, std.mem.count(u8, tc, shared.call));
        var from: usize = 0;
        for (shared.callers) |want| {
            from = std.mem.indexOfPos(u8, tc, from, shared.call).?;
            const fn_at = std.mem.lastIndexOf(u8, tc[0..from], "    fn ").?;
            const got = tc[fn_at + "    fn ".len .. fn_at + std.mem.indexOfScalar(u8, tc[fn_at..], '(').?];
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
    // Ownership lends a binding by its access, in `lendTarget` alone,
    // which reads neither the binding's type (`ref`) nor how the match
    // reached it (`payload_view`, `matchMode`).
    const own = @embedFile("ownership.zig");
    const read_fact = "ctx." ++ "bindingAccess(";
    try std.testing.expectEqual(1, std.mem.count(u8, own, read_fact));
    const lend_at = std.mem.indexOf(u8, own, "    fn " ++ "lendTarget(").?;
    const body = own[lend_at .. std.mem.indexOfPos(u8, own, lend_at, "\n    }\n").?];
    try std.testing.expect(std.mem.indexOf(u8, body, read_fact) != null);
    for ([_][]const u8{ ".ref", "payload_view", "matchMode", "types.get" }) |other| {
        try std.testing.expect(std.mem.indexOf(u8, body, other) == null);
    }
    for ([_][]const u8{ "payload_" ++ "writes", "writes" ++ "Subject" }) |gone| {
        try std.testing.expectEqual(0, std.mem.count(u8, own, gone));
    }
    // Storage binds a payload by address from the same fact, not from the
    // match's mode.
    const st = @embedFile("storage.zig");
    const by_addr = std.mem.indexOf(u8, st, "fn " ++ "payloadByAddress(").?;
    const by_body = st[by_addr .. std.mem.indexOfPos(u8, st, by_addr, "\n}\n").?];
    try std.testing.expect(std.mem.indexOf(u8, by_body, "bindingAccess(") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_body, "matchMode") == null);
}

test "check: a written write lend read as a value is rejected" {
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
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "here is read, not held") != null) count += 1;
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
        \\  fun get(?self) -> Int
        \\    h(self.n)
        \\
        \\  drop(!self)
        \\    print(h(self.n))
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
