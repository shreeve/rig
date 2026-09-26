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
//! `?T` is expected; a borrow of a Copy value where the value is
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
const sema = @import("sema.zig");
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
    defer c.literal_results.deinit(ctx.allocator);
    defer c.result_hints.deinit(ctx.allocator);
    for (ir.Module.decls(tree)) |decl| if (rig.isModuleConst(decl)) try c.checkDecl(decl);
    for (ir.Module.decls(tree)) |decl| if (!rig.isModuleConst(decl)) try c.checkDecl(decl);
}

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
    /// The `new x` binding whose value is being checked: not visible yet.
    pending: SymbolId = sema.symbol_invalid,
    /// In a module constant's declaration, its position: the types in it
    /// name only earlier constants.
    const_before: u32 = std.math.maxInt(u32),
    /// Enclosing `raw` blocks.
    raw_depth: u32 = 0,
    /// The operand of the `!` or `catch` being checked: a fallible call
    /// there is handled.
    handled: Sexp = .nil,
    /// The operand of the `*x` being checked.
    shared_operand: Sexp = .nil,
    /// The `!x` being checked where a write borrow is expected, the one
    /// place a write borrow of a `Bool` is not read as its value.
    lent_write: Sexp = .nil,
    /// The argument being checked, when the call keeps no borrow of its
    /// arguments: a temporary array there may be lent as a `[]T`.
    lent_temp: Sexp = .nil,
    /// The argument being checked, where a closure literal may be lent
    /// as a borrowed callable, and the call when its result could hold
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
    /// The types inference found for arguments (`argType`).
    arg_types: std.AutoHashMapUnmanaged(parser.NodeId, TypeId) = .empty,
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
        returns: ?*std.ArrayListUnmanaged(ReturnSite) = null,
        /// The name of the `fun` or `sub` being checked, for messages.
        name: Sexp = .nil,
        /// The loops and labeled blocks around the code being checked,
        /// innermost first: what a `break` leaves.
        loops: ?*LoopFrame = null,
    };

    const LoopFrame = struct {
        label: []const u8,
        /// False for a labeled block, which only `break :label` leaves.
        is_loop: bool = true,
        /// The value of a loop used as one.
        value: ?*LoopValue = null,
        parent: ?*LoopFrame,
    };

    /// A loop used as a value: its `break` values and its `else` value.
    const LoopValue = struct {
        expected: ?TypeId,
        /// The type the values settle on, without `expected`.
        ty: ?TypeId = null,
        values: std.ArrayListUnmanaged(Typed) = .empty,
    };

    /// A branch, arm, or `break` value and the type it synthesized.
    const Typed = struct { node: Sexp, ty: TypeId };

    const ReturnSite = struct { node: Sexp, ty: ?TypeId };

    const FailTarget = union(enum) {
        /// The caller: in a `fun ... -> T!`, `sub main`, or a test.
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
        return .{ .ctx = self.ctx, .scope = self.scope, .nominal = self.nominal, .const_before = self.const_before };
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
            .use, .type, .@"extern", .extern_fun, .extern_sub => {},
            else => try self.errAt(sexp, not_at_module_level, .{}),
        }
    }

    /// A module-level binding is a constant, `name =! value`: its value
    /// is known at compile time and owns nothing, so no function can
    /// change it and nothing has to release it.
    fn checkModuleConst(self: *Checker, node: Sexp) Error!void {
        const target = ir.Set.target(node);
        if (target != .src) return self.errAt(node, not_at_module_level, .{});
        if (rig.bindingKindOf(ir.Set.op(node)) != .fixed) {
            return self.errAt(node, "a module-level binding is a constant; write `{s} =! value`", .{self.text(target)});
        }
        self.const_before = target.src.pos;
        defer self.const_before = std.math.maxInt(u32);
        try self.checkSet(node);
        const value = ir.Set.value(node);
        if (self.isPoison(self.ctx.typeOf(target) orelse self.t().invalid_id)) return;
        if (!self.isConstExpr(value)) {
            try self.errAt(value, "a module-level constant needs a value known at compile time: a literal, `.variant`, an earlier constant, or operators and arrays over them", .{});
        }
    }

    fn isConstExpr(self: *Checker, e: Sexp) bool {
        if (e.isKind(.array)) {
            for (ir.Array.elems(e)) |x| if (!self.isConstExpr(x)) return false;
            return true;
        }
        if (e.isKind(.array_fill)) return self.isConstExpr(ir.ArrayFill.value(e));
        return self.isComptimeKnown(e);
    }

    const not_at_module_level = "only declarations and bindings are allowed at module level; move this statement into a function";
    const discard_read = "`_` discards a value; it cannot be read";
    const stack_signal = "stack-local `Signal[T]` is not supported: a Signal lives behind a shared handle; construct it with `*Signal(value: ...)`";

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
        if (is_main and (!is_sub or ir.get(node, .params).items().len > 0 or sema.tparamsOf(node).items().len > 0)) {
            try self.errAt(name, "`main` must be `sub main`: the program's entry point takes no parameters and returns no value", .{});
        }
        for (ir.get(node, .params).items()) |p| if (p.isKind(.default)) {
            const ty = self.ctx.bindingTypeOf(ir.Default.name(p)) orelse self.t().unknown_id;
            try self.checkDefaultValue(ir.Default.value(p), ty, "parameter");
        };
        // `sub main` lowers to a fallible `main`.
        const fallible = (is_main and is_sub) or rig.returnType(node).isKind(.error_union);
        try self.checkBody(ir.get(node, .body), .{ .ret = ret, .is_sub = is_sub, .fail_to = if (fallible) .caller else .{ .infallible = name }, .name = name });
    }

    /// A parameter or field default: a literal of type `ty`, so it owns
    /// nothing and means the same value wherever it is filled in.
    fn checkDefaultValue(self: *Checker, value: Sexp, ty: TypeId, what: []const u8) Error!void {
        if (!isDefaultLiteral(self.ctx.source, value)) {
            try self.errAt(value, "a default {s} value must be a literal: a number, a string, `true` / `false`, `none`, or `.variant`", .{what});
            return;
        }
        try self.checkExpr(value, ty);
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
            if (wants_value) try self.checkExpr(body, ret) else try self.checkStmt(body);
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
                        .@"defer", .@"errdefer" => "deferred statement",
                        else => "jump",
                    };
                    try self.errAt(s, "a function returning `{s}` must end with a value; this {s} produces none", .{ try self.tyName(ret), what });
                    continue;
                }
                try self.checkExpr(s, ret);
            } else {
                try self.checkStmt(s);
            }
        }
    }

    // =========================================================================
    // Statements
    // =========================================================================

    fn checkStmt(self: *Checker, stmt: Sexp) Error!void {
        const head = stmt.kind() orelse return self.checkExprStmt(stmt);
        if (self.isValueLoop(stmt)) {
            try self.errAt(stmt, "the value of this loop is not used; bind it (`x = for ...`) or `break` without a value", .{});
            _ = try self.checkLoopValue(stmt, null, false);
            return;
        }
        switch (head) {
            .set => try self.checkSet(stmt),
            .@"return" => try self.checkReturn(stmt),
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
                _ = try self.synthExpr(ir.Drop.name(stmt));
            },
            .@"break" => try self.checkBreak(stmt),
            .@"continue" => {},
            .@"defer", .@"errdefer" => {
                const saved = self.body;
                defer self.body = saved;
                self.body.fail_to = .deferred;
                self.body.loops = null;
                try self.checkStmt(ir.get(stmt, .body));
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
                var frame: LoopFrame = .{ .label = label, .is_loop = false, .parent = self.body.loops };
                self.body.loops = &frame;
                defer self.body.loops = frame.parent;
                try self.checkStmt(inner);
            },
            .fun, .sub, .@"struct", .@"enum", .errors, .type, .generic_struct, .generic_enum, .use, .@"extern", .extern_fun, .extern_sub, .@"test", .@"pub" => {
                try self.errAt(stmt, "declarations are only allowed at module level", .{});
            },
            else => try self.checkExprStmt(stmt),
        }
    }

    /// An expression used as a statement must do something: call, fail
    /// over (`!`, `?`), or handle a failure. One that only reads a value
    /// and drops it is a mistake; a function name was meant as a call.
    fn checkExprStmt(self: *Checker, stmt: Sexp) Error!void {
        const ty = try self.synthExpr(stmt);
        // A closure literal alone is reported by the ownership checker.
        if (self.isPoison(ty) or stmt.isKind(.lambda)) return;
        if (!hasEffect(stmt)) {
            if (stmt.kind() == null and self.ctx.types.get(ty) == .function)
                return self.errAt(stmt, "`{s}` is a function; call it with `{s}()`", .{ self.text(stmt), self.text(stmt) });
            return self.errAt(stmt, "this expression does nothing as a statement; use its value, or discard it with `_ = ...`", .{});
        }
        if ((try self.ownsResource(ty, self.startOf(stmt), "discards a value"))) {
            try self.errAt(stmt, "expression result of type `{s}` carries drop glue and would leak as a discarded statement; bind it (`x = ...`), drop it now with `_ = ...`, or move it into a receiver", .{try self.tyName(ty)});
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
            try self.errAt(value, "a `sub` returns no value; remove the value or declare a `fun`", .{});
            _ = try self.synthExpr(value);
            return;
        }
        try self.checkExpr(value, ret);
    }

    // ---- bindings and assignment --------------------------------------------

    fn checkSet(self: *Checker, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const target = ir.Set.target(node);
        const type_node = ir.Set.type(node);
        const rhs = ir.Set.value(node);

        if (target != .src) return self.checkPlaceAssign(kind, target, type_node, rhs);

        const name = self.text(target);
        if (std.mem.eql(u8, name, "_")) {
            // `x op= e` reads `x`.
            if (kind.operator() != null) try self.errAt(target, discard_read, .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        // `<-` and compound assignment name an existing binding.
        const sym_id = self.ctx.symbolOf(target) orelse (try self.useName(target)) orelse {
            _ = try self.synthExpr(rhs);
            return;
        };
        try self.ctx.recordName(target, sym_id);
        // A copy: resolving the annotation may add symbols (`sema.proxyOf`).
        const sym = self.ctx.symbols.items[sym_id];
        const is_decl = sym.decl_pos == target.src.pos;

        if (!is_decl and sym.kind == .param and self.ctx.types.get(sym.ty) != .borrow_write) {
            try self.errAt(target, "cannot assign to parameter `{s}`; parameters are immutable (bind a copy with `new {s} = {s}`, or take `{s}: !T` to write through to the caller)", .{ name, name, name, name });
        }
        // A captured write borrow writes through to what it borrows.
        const captured_write = sym.kind == .capture and self.ctx.types.get(sym.ty) == .borrow_write;
        if (!is_decl and sym.kind == .capture and !captured_write and !self.isPoison(sym.ty)) {
            try self.errAt(target, "cannot assign to captured `{s}`; captures are fixed when the closure is created", .{name});
        }
        const writes_through = sym.kind == .param or sym.flags.pattern_bound or captured_write;
        // A `![]T` parameter or pattern binding views the caller's
        // elements; there is no whole value to write through to.
        if (!is_decl and writes_through and sema.writeSliceElem(self.ctx, sym.ty) != null) {
            try self.errAt(target, "cannot assign to `{s}`, a `{s}` {s}; write its elements with `{s}[i] = v` or `!{s}.copy(src)`", .{ name, try self.tyName(sym.ty), if (sym.kind == .param) "parameter" else "binding", name, name });
            _ = try self.synthExpr(rhs);
            return;
        }
        // Assigning a binding writes it without reading it; writing
        // through a `!T` binding reaches the borrowed value.
        if (!is_decl and self.ctx.types.get(sym.ty) != .borrow_write) try self.ctx.facts.writes.put(self.ctx.allocator, target.src.pos, {});
        if (!is_decl and sym.flags.pattern_bound and self.ctx.types.get(sym.ty) != .borrow_write) {
            try self.errAt(target, "cannot assign to `{s}`; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ name, name, name });
        }

        var declared = self.t().unknown_id;
        if (type_node != .nil) {
            var r = self.resolver();
            declared = try r.resolveType(type_node);
            if (!is_decl and sym.ty != self.t().unknown_id and declared != sym.ty) {
                try self.errAt(target, "`{s}` is already a `{s}`; a later assignment cannot re-annotate it", .{ name, try self.tyName(sym.ty) });
            }
        } else if (!is_decl or sym.ty != self.t().unknown_id) {
            declared = sym.ty;
        }
        // Assigning a `!T` parameter (or the element of `for x in !xs`)
        // writes through to the borrowed `T`.
        if (!is_decl and writes_through) switch (self.ctx.types.get(declared)) {
            .borrow_write => |inner| declared = inner,
            else => {},
        };

        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"&=", .@"|=", .@"^=", .@"<<=", .@">>=" => {
                const what = try std.fmt.allocPrint(self.ctx.arena.allocator(), "`{s}` has type", .{name});
                try self.checkCompound(kind, declared, rhs, target.src.pos, what);
                try self.ctx.recordType(target, declared);
                return;
            },
            else => {},
        }

        const saved_pending = self.pending;
        defer self.pending = saved_pending;
        if (kind == .shadow) self.pending = sym_id;
        var rhs_ty: TypeId = undefined;
        if (!self.isPoison(declared) or type_node != .nil) {
            try self.checkExpr(rhs, declared);
            rhs_ty = declared;
        } else {
            rhs_ty = try self.synthExpr(rhs);
            // Binding a borrowed Copy value copies the value; an explicit
            // `?x` / `!x` binds the borrow.
            if (!rhs.isKind(.read) and !rhs.isKind(.write)) rhs_ty = try self.readThrough(rhs, rhs_ty, readValue(self.ctx, rhs_ty));
            rhs_ty = try self.defaultBindingType(rhs, rhs_ty, name);
        }

        const s = &self.ctx.symbols.items[sym_id];
        // A rejected annotation leaves the binding without a type.
        if (s.ty == self.t().unknown_id) s.ty = if (type_node != .nil and self.isPoison(declared)) self.t().invalid_id else rhs_ty;
        if (is_decl and s.scope == self.module_scope and sema.holdsCallable(self.ctx, s.ty)) {
            try self.errAt(target, "a borrowed callable `{s}` lives only as long as what it borrows, so it cannot be a module-level binding", .{try self.tyName(s.ty)});
            s.ty = self.t().invalid_id;
        }
        if (kind == .fixed and self.isComptimeKnown(rhs)) s.flags.comptime_known = true;
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

    /// The type an unannotated binding gets from its initializer.
    fn defaultBindingType(self: *Checker, rhs: Sexp, ty: TypeId, name: []const u8) Error!TypeId {
        const pos = self.startOf(rhs);
        switch (self.ctx.types.get(ty)) {
            .int_literal => {
                try self.checkLiteralFits(rhs, self.t().int_id);
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

    /// `obj.field = v`, `xs[i] = v`, and compound forms.
    fn checkPlaceAssign(self: *Checker, kind: rig.BindingKind, target: Sexp, type_node: Sexp, rhs: Sexp) Error!void {
        const head = target.kind();
        if (head != .member and head != .index) {
            try self.errAt(target, "cannot assign to this expression", .{});
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
        if (self.cellVecElementIn(target) != null) {
            const whole = target.isKind(.index) and cellVecElement(self.ctx, self.ctx.typeOf(ir.Index.object(target)) orelse self.t().invalid_id) != null;
            if (!whole or kind.operator() != null) {
                try self.errAt(target, "an element of a Cell's Vec is written whole, with `c[i] = e`: copy it out, change the copy, and write it back", .{});
                _ = try self.synthExpr(rhs);
                return;
            }
            if (self.isPoison(place_ty)) {
                _ = try self.synthExpr(rhs);
                return;
            }
            if (!self.cellSettable(ir.Index.object(target))) {
                try self.errAt(target, "`c[i] = e` needs a Cell that has a place: a local binding, a field of one, or one reached through a borrow (`?T` or `!T`) or a shared handle (`*T`). A by-value parameter, a loop or match binding (a copy), or a temporary cannot be changed.", .{});
                _ = try self.synthExpr(rhs);
                return;
            }
            return self.checkExpr(rhs, place_ty);
        }
        if (!(try self.checkWritable(target, target, "assign to"))) {
            _ = try self.synthExpr(rhs);
            return;
        }
        if (head == .index and (try self.ownsResource(place_ty, self.startOf(target), "overwrites an element"))) {
            try self.errAt(target, "cannot replace an element of type `{s}` by assignment; the old handle would leak", .{try self.tyName(place_ty)});
            return;
        }
        if (kind.operator() != null) return self.checkCompound(kind, place_ty, rhs, self.startOf(target), "this place has type");
        try self.checkExpr(rhs, place_ty);
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
            .@"&", .@"|", .@"^", .@"<<", .@">>" => .integer,
            else => .numeric,
        };
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
        if (op == .@"<<" or op == .@">>") {
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

    /// Writing to `place` (a name, or a field or element of one, already
    /// synthesized) must not go through a `*T`, which other handles may
    /// share, or a `?T`. Without a borrow or handle on the path, it
    /// writes the binding the path starts from, which must be mutable:
    /// fixed (`=!`), loop and pattern bindings, captures, and parameters
    /// other than `!T` ones are not. False after a diagnostic about the
    /// path.
    fn checkWritable(self: *Checker, place: Sexp, at: Sexp, verb: []const u8) Error!bool {
        const path = self.placePath(place);
        const assign = std.mem.eql(u8, verb, "assign to");
        const through = if (assign) "assign" else verb;
        if (path.shared) {
            try self.errAt(at, "cannot {s} through {s}shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell[T]` for mutation through shared ownership.", .{ through, if (assign) "" else "a " });
            return false;
        }
        if (path.read_only) |ro| {
            switch (ro.what) {
                .slice => try self.err(ro.pos, "cannot {s} through a slice; a `[]T` is read-only", .{through}),
                .string => try self.err(ro.pos, "cannot {s} a byte of a String; a String is read-only", .{verb}),
                .len => try self.err(ro.pos, "cannot {s} `.len`; a length is read-only", .{verb}),
            }
            return false;
        }
        if (path.read_borrow) |pos| {
            try self.err(pos, "cannot {s} through a read borrow (`?T`); take a write borrow (`!T`) to mutate", .{through});
            return false;
        }
        const root = path.root orelse return true;
        const id = self.ctx.symbolOf(root) orelse return true;
        var sym = self.ctx.symbols.items[id];
        var name = sym.name;
        const pos = root.src.pos;
        // `module.name`: a binding of an imported module.
        if (sym.kind == .module) {
            const leaf = self.text(ir.Member.name(path.module_member orelse return true));
            const origin = self.ctx.module_refs.get(id) orelse return true;
            const foreign = self.ctx.foreign_semas.get(origin) orelse return true;
            sym = foreign.symbols.items[foreign.lookupInScopeOnly(sema.module_scope, leaf) orelse return true];
            name = try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ self.text(root), leaf });
        }
        _ = try self.checkBindingWritable(sym, name, pos, verb);
        return true;
    }

    /// Whether binding `sym`, written `name` at `pos`, may be written:
    /// a parameter only when it is a `!T`, never a capture, a fixed
    /// binding, or a loop or pattern binding that copies. False after a
    /// diagnostic.
    fn checkBindingWritable(self: *Checker, sym: sema.Symbol, name: []const u8, pos: u32, verb: []const u8) Error!bool {
        switch (sym.kind) {
            .param => if (self.ctx.types.get(sym.ty) != .borrow_write) {
                if (std.mem.eql(u8, name, "self")) {
                    try self.err(pos, "cannot {s} parameter `self`; parameters are immutable (take `!self` to write through to the caller)", .{verb});
                } else try self.err(pos, "cannot {s} parameter `{s}`; parameters are immutable (take `{s}: !T` to write through to the caller)", .{ verb, name, name });
                return false;
            },
            // A captured write borrow is lent on, as a `!T` parameter is.
            .capture => if (self.ctx.types.get(sym.ty) != .borrow_write) {
                try self.err(pos, "cannot {s} captured `{s}`; captures are fixed when the closure is created", .{ verb, name });
                return false;
            },
            .local => if (sym.flags.fixed) {
                try self.err(pos, "cannot {s} fixed binding `{s}` (bound with `=!`)", .{ verb, name });
                return false;
            } else if (sym.flags.pattern_bound and self.ctx.types.get(sym.ty) != .borrow_write) {
                try self.err(pos, "cannot {s} `{s}`; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ verb, name, name, name });
                return false;
            },
            else => {},
        }
        return true;
    }

    /// A write borrow held in a field or element (`b.t` with `t: !T`) is
    /// lent as it is when the place is used bare where a value holding a
    /// write borrow is expected, or called with a `!self` method. Reached through a `?T` or `*T`, it is read-only
    /// like the rest of what that path reaches: other borrows or handles
    /// may reach the same write borrow. False after a diagnostic.
    fn checkLendsWriteBorrow(self: *Checker, place: Sexp) Error!bool {
        if (!place.isKind(.member) and !place.isKind(.index)) return true;
        const path = self.placePath(place);
        if (path.shared) {
            try self.errAt(place, "cannot lend the write borrow held here through a shared handle (`*T`); other handles reach the same write borrow", .{});
            return false;
        }
        if (path.read_borrow orelse if (path.read_only) |ro| ro.pos else null) |pos| {
            try self.err(pos, "cannot lend the write borrow held here through a read borrow (`?T`); other borrows may reach the same write borrow", .{});
            return false;
        }
        return true;
    }

    /// How a place reaches its storage, read from the recorded types of
    /// the objects along its path (`a` and `a.b` in `a.b.c`).
    const PlacePath = struct {
        /// The name the path starts from, when no borrow or handle is on
        /// the way.
        root: ?Sexp = null,
        /// A borrow or handle is on the way.
        indirect: bool = false,
        /// A `*T` (or a borrow of one) is on the way.
        shared: bool = false,
        /// Where the path goes through a `?T`.
        read_borrow: ?u32 = null,
        /// `module.name` when the root is an imported module.
        module_member: ?Sexp = null,
        /// Where the path reaches read-only storage: an element of a
        /// slice or String, or a `.len`.
        read_only: ?struct { what: enum { slice, string, len }, pos: u32 } = null,
    };

    /// Whether a value is reached through a `?T` or `*T`: it is one, or
    /// a place whose path goes through one.
    fn readOnlyPlace(self: *Checker, e: Sexp) bool {
        if (self.ctx.typeOf(e)) |ty| switch (self.ctx.types.get(ty)) {
            .borrow_read, .shared => return true,
            else => {},
        };
        const path = self.placePath(e);
        return path.shared or path.read_borrow != null or path.read_only != null;
    }

    fn placePath(self: *Checker, place: Sexp) PlacePath {
        var path: PlacePath = .{};
        var p = place;
        while (p.kind()) |h| {
            if (h != .member and h != .index) return path;
            const obj = ir.get(p, .object);
            if (h == .member) path.module_member = p;
            if (self.ctx.typeOf(obj)) |ty| {
                if (path.read_only == null) {
                    const base_ty = sema.unwrapBorrows(self.ctx, ty);
                    const base = self.ctx.types.get(base_ty);
                    if (h == .index) {
                        if (base == .slice and sema.writeSliceElem(self.ctx, ty) == null) path.read_only = .{ .what = .slice, .pos = self.startOf(obj) };
                        if (base == .string) path.read_only = .{ .what = .string, .pos = self.startOf(obj) };
                    } else if ((base == .slice or base == .string or base == .array or vecElementType(self.ctx, base_ty) != null or cellVecElement(self.ctx, base_ty) != null) and std.mem.eql(u8, self.text(ir.Member.name(p)), "len")) {
                        path.read_only = .{ .what = .len, .pos = self.startOf(ir.Member.name(p)) };
                    }
                }
                switch (self.ctx.types.get(ty)) {
                    .borrow_read => {
                        path.indirect = true;
                        if (path.read_borrow == null) path.read_borrow = self.startOf(obj);
                    },
                    .borrow_write, .shared => path.indirect = true,
                    else => {},
                }
                if (self.ctx.types.get(sema.unwrapBorrows(self.ctx, ty)) == .shared) path.shared = true;
            }
            p = obj;
        }
        if (p == .src and !path.indirect) path.root = p;
        return path;
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
        try self.checkCondition(cond);
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

    /// A Bool condition, or an optional binding `(as expr name)`, which
    /// enters the scope binding `name`; the caller restores the scope.
    fn checkCondition(self: *Checker, cond: Sexp) Error!void {
        if (cond.isKind(.as)) return self.checkOptionalBinding(cond);
        return self.checkExpr(cond, self.t().bool_id);
    }

    /// `if expr as name` / `while expr as name`: `expr` is an optional,
    /// and `name` holds the value inside it. A resource moves into the
    /// binding, which owns it; it cannot be copied out of a place.
    fn checkOptionalBinding(self: *Checker, node: Sexp) Error!void {
        const expr = ir.As.value(node);
        const name = ir.As.name(node);
        const ty = try self.synthExpr(expr);
        var inner = self.t().invalid_id;
        if (!self.isPoison(ty)) switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, ty))) {
            .optional => |i| inner = i,
            else => try self.errAt(expr, "`as` binds the value inside an optional; this expression has type `{s}`", .{try self.tyName(ty)}),
        };
        const borrowed = sema.unwrapBorrows(self.ctx, ty) != ty;
        if (borrowed and try self.ownsResource(inner, self.startOf(expr), "moves out of a borrow a value")) {
            const handle = switch (self.ctx.types.get(inner)) {
                .shared, .weak => true,
                else => false,
            };
            const hint = if (handle) "bind a new handle with `+x` instead" else "unwrap the optional where it is owned (`if <m as x`)";
            try self.errAt(expr, "a borrow cannot give up the resource inside it; {s}", .{hint});
        } else _ = try self.readThrough(expr, ty, sema.unwrapBorrows(self.ctx, ty));
        _ = self.enter(node);
        if (self.ctx.symbolOf(name)) |sym| {
            self.ctx.symbols.items[sym].ty = inner;
            try self.ctx.recordType(name, inner);
        }
    }

    /// The frame of the loop being entered, which takes the pending label
    /// and value.
    fn enterLoop(self: *Checker, frame: *LoopFrame) void {
        frame.* = .{ .label = self.loop_label, .value = self.loop_value, .parent = self.body.loops };
        self.loop_label = "";
        self.loop_value = null;
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
        self.enterLoop(&frame);
        const prev = self.scope;
        const cond = ir.While.cond(node);
        try self.checkCondition(cond);
        const step = ir.While.step(node);
        const call_step = step.isKind(.call) or (step.isKind(.propagate) and ir.Propagate.value(step).isKind(.call));
        if (step != .nil and !step.isKind(.set) and !call_step) {
            try self.errAt(step, "a `while` step is an assignment or a call", .{});
        } else if (step != .nil) {
            try self.checkStmt(step);
            // The body drops an owning `as` binding before the step runs.
            if (cond.isKind(.as)) if (self.ctx.symbolOf(ir.As.name(cond))) |b| {
                const sym = self.ctx.symbols.items[b];
                if (findUse(self.ctx, step, b)) |use| if (try self.ownsResource(sym.ty, self.startOf(use), "uses in a loop step a binding")) {
                    try self.errAt(use, "the loop step cannot use `{s}`: it owns a `{s}`, which the body drops before the step runs", .{ sym.name, try self.tyName(sym.ty) });
                };
            };
        }
        try self.checkStmt(ir.While.body(node));
        self.scope = prev;
        try self.checkLoopElse(&frame, ir.While.@"else"(node));
    }

    fn checkFor(self: *Checker, node: Sexp) Error!void {
        var frame: LoopFrame = undefined;
        self.enterLoop(&frame);
        const mode = ir.For.mode(node).tag;
        const binding = ir.For.@"var"(node);
        const index_binding = ir.For.index(node);
        const source = ir.For.source(node);

        if (index_binding != .nil and source.isKind(.@"..")) {
            try self.errAt(index_binding, "a range has no index binding; the element is already the position (`for i in a..b`)", .{});
        }

        var elem_ty = self.t().invalid_id;
        if (source.isKind(.@"..")) {
            // Both bounds are integers of one type, the element's.
            elem_ty = try self.checkIntDefaultOperands(source, "..", .integer, null);
            try self.ctx.recordType(source, try self.ctx.intern(.{ .range = elem_ty }));
        } else {
            const peeled_source = if (source.isKind(.read)) ir.Read.operand(source) else source;
            // `for x in ?xs[a..b]` walks a slice of `xs`.
            const source_ty = if ((mode == .read or mode == .write) and rig.isRangeIndex(source))
                try self.borrowSlice(source, if (mode == .read) .read else .write)
            else
                try self.synthExpr(source);
            elem_ty = try self.elementTypeForLoop(source, peeled_source, source_ty, mode);
        }

        {
            const prev = self.enter(node);
            defer self.scope = prev;
            if (self.ctx.symbolOf(binding)) |sym| {
                self.ctx.symbols.items[sym].ty = elem_ty;
                try self.ctx.recordType(binding, elem_ty);
            }
            if (self.ctx.symbolOf(index_binding)) |sym| {
                self.ctx.symbols.items[sym].ty = self.t().int_id;
                try self.ctx.recordType(index_binding, self.t().int_id);
            }
            try self.checkStmt(ir.For.body(node));
        }
        try self.checkLoopElse(&frame, ir.For.@"else"(node));
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
            .set, .@"while", .@"for", .drop, .@"defer", .@"errdefer", .@"return", .@"break", .@"continue", .labeled => !self.isValueLoop(e),
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
        if (lv.expected) |e| return self.checkExpr(value, e);
        const ty = try self.synthExpr(value);
        try lv.values.append(self.ctx.allocator, .{ .node = value, .ty = ty });
        lv.ty = if (lv.ty) |cur| (try self.unify(cur, ty, self.startOf(value))) orelse self.t().invalid_id else ty;
    }

    /// `(break value? label?)`: a loop used as a value takes a value from
    /// every `break` that leaves it, and no other `break` carries one.
    fn checkBreak(self: *Checker, node: Sexp) Error!void {
        const value = ir.Break.value(node);
        const label = ir.Break.label(node);
        var target = self.body.loops;
        while (target) |f| : (target = f.parent) {
            if (label == .nil) {
                if (f.is_loop) break;
            } else if (std.mem.eql(u8, f.label, self.text(label))) break;
        }
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
            } else try self.errAt(value, "a labeled block has no value; `break :{s}` cannot carry one", .{f.label});
        }
    }

    /// The element of `for x in !xs`: a write borrow of each slot. The
    /// source must be a place the loop may write.
    fn writeElement(self: *Checker, source: Sexp, inner_source: Sexp, elem: TypeId) Error!TypeId {
        if (!isFieldPath(inner_source)) {
            try self.errAt(source, "`for x in !xs` writes each element in place; `xs` must be a binding or a field of one", .{});
        } else _ = try self.checkWritable(inner_source, source, "write-iterate");
        return self.ctx.intern(.{ .borrow_write = elem });
    }

    fn elementTypeForLoop(self: *Checker, source: Sexp, inner_source: Sexp, source_ty: TypeId, mode: ?Tag) Error!TypeId {
        const pos = self.startOf(source);
        if (self.isPoison(source_ty)) return self.t().invalid_id;
        const peeled = sema.unwrapBorrows(self.ctx, source_ty);
        switch (self.ctx.types.get(peeled)) {
            .parameterized_nominal => if (vecElementType(self.ctx, peeled)) |elem| {
                const is_resource = switch (self.ctx.types.get(elem)) {
                    .shared, .weak => true,
                    else => false,
                };
                if (is_resource) {
                    if (mode != .read and mode != .write and mode != .move) {
                        try self.err(pos, "resource Vec[T] iteration requires an explicit read borrow; write `for x in ?vec`", .{});
                    }
                    if (!isFieldPath(inner_source)) {
                        try self.err(pos, "resource Vec[T] iteration requires a Vec binding or a field of one as the source; got an expression. Bind the result to a `Vec[T]` local first.", .{});
                    }
                }
                if (mode == .write) return self.writeElement(source, inner_source, elem);
                // `for x in <v` hands each element over.
                if (mode == .move) return elem;
                return if (is_resource) try self.ctx.intern(.{ .borrow_read = elem }) else elem;
            },
            .array => |a| {
                if (mode == .write) return self.writeElement(source, inner_source, a.elem);
                if (mode != .move and sema.holdsWriteBorrow(self.ctx, a.elem)) {
                    try self.err(pos, "each element holds a write borrow, which a loop binding would copy; write through them with `for x in !xs`", .{});
                }
                return a.elem;
            },
            .slice, .string => {
                if (mode == .write) {
                    if (sema.writeSliceElem(self.ctx, source_ty)) |elem| {
                        if (!rig.isRangeIndex(inner_source)) _ = try self.checkWritable(inner_source, source, "write-iterate");
                        return self.ctx.intern(.{ .borrow_write = elem });
                    }
                    try self.err(pos, "cannot write-iterate a `{s}`; its elements are read-only", .{try self.tyName(source_ty)});
                    return self.t().invalid_id;
                }
                return switch (self.ctx.types.get(peeled)) {
                    .slice => |sl| sl.elem,
                    else => try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
                };
            },
            else => {},
        }
        try self.err(pos, "cannot iterate over `{s}`; a `for` source must be a range `a..b`, an array, a String, or a `Vec`", .{try self.tyName(source_ty)});
        return self.t().invalid_id;
    }

    // ---- match ----------------------------------------------------------------

    fn checkMatch(self: *Checker, node: Sexp, position: Position, expected: ?TypeId) Error!TypeId {
        const subject = ir.Match.subject(node);
        if (subject.isKind(.move)) {
            try self.errAt(subject, "a `match` reads its scrutinee, so moving it in would leave nothing to drop it; match the binding itself (`match s`)", .{});
        }
        const scrutinee = try self.synthOperand(subject);
        const scrut_pos = self.startOf(subject);
        if (scrutinee == self.t().int_literal_id) try self.checkLiteralFits(subject, self.t().int_id);
        const matchable = switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, scrutinee))) {
            .int, .int_literal, .bool, .invalid, .unknown, .any_error => true,
            .nominal, .parameterized_nominal, .imported_nominal => sema.enumVariantCount(self.ctx, scrutinee) != null,
            else => false,
        };
        if (!matchable) {
            try self.err(scrut_pos, "cannot `match` on a value of type `{s}`; match works on enums, errors, integers, and Bool", .{try self.tyName(scrutinee)});
        }

        // A binding copies what it binds, so one holding a write borrow
        // would be a second writer when the matched value is only read.
        const read_only = subject.isKind(.read) or self.readOnlyPlace(subject);
        var cov: MatchCoverage = .{};
        var arm_values: std.ArrayListUnmanaged(Typed) = .empty;
        defer arm_values.deinit(self.ctx.allocator);
        defer cov.deinit(self.ctx.allocator);
        var result: ?TypeId = expected;

        for (ir.Match.arms(node)) |arm| {
            const prev = self.enter(arm);
            defer self.scope = prev;
            const pattern = ir.Arm.pattern(arm);
            if (cov.has_default or self.coversAll(&cov, scrutinee)) {
                try self.errAt(pattern, "this arm never runs: the arms before it cover every value", .{});
            }
            try self.checkPattern(pattern, scrutinee, &cov);
            if (read_only) try self.rejectWriteBorrowBindings(pattern);
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

        if (result) |r| for (arm_values.items) |av| try self.adaptLiteral(av.node, av.ty, r);
        const exhaustive = self.coversAll(&cov, scrutinee);
        if (exhaustive) try self.ctx.recordExhaustive(node);
        if (position == .value and !cov.has_default and !exhaustive and !self.isPoison(scrutinee)) {
            if (sema.enumVariantCount(self.ctx, scrutinee)) |total| {
                try self.err(scrut_pos, "value-position `match` is not exhaustive (covered {d} of {d} variants and no default arm)", .{ cov.variants.count(), total });
            } else {
                try self.err(scrut_pos, "value-position `match` on `{s}` needs a default arm", .{try self.tyName(scrutinee)});
            }
        }
        if (position == .statement) return self.t().void_id;
        return result orelse self.t().invalid_id;
    }

    /// What the arms of a match have covered so far.
    const MatchCoverage = struct {
        variants: std.StringHashMapUnmanaged(u32) = .empty,
        bools: [2]bool = .{ false, false },
        /// Inclusive integer intervals.
        ints: std.ArrayListUnmanaged([2]i128) = .empty,
        has_default: bool = false,

        fn deinit(c: *MatchCoverage, a: std.mem.Allocator) void {
            c.variants.deinit(a);
            c.ints.deinit(a);
        }
    };

    /// Whether the arms so far match every value of the scrutinee type.
    fn coversAll(self: *Checker, cov: *MatchCoverage, scrutinee: TypeId) bool {
        const ty = sema.unwrapBorrows(self.ctx, scrutinee);
        if (sema.enumVariantCount(self.ctx, ty)) |total| return cov.variants.count() >= total;
        switch (self.ctx.types.get(ty)) {
            .bool => return cov.bools[0] and cov.bools[1],
            .int, .int_literal => {
                const bounds = intBounds(if (self.ctx.types.get(ty) == .int) self.ctx.types.get(ty).int else .{});
                var next = bounds.min;
                const max = bounds.max;
                // Sweep the intervals in order of their low ends.
                std.mem.sort([2]i128, cov.ints.items, {}, struct {
                    fn lt(_: void, a: [2]i128, b: [2]i128) bool {
                        return a[0] < b[0];
                    }
                }.lt);
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

    /// Record an integer interval a pattern matches; it may not overlap
    /// an earlier one.
    fn coverInts(self: *Checker, cov: *MatchCoverage, lo: i128, hi: i128, pos: u32) Error!void {
        for (cov.ints.items) |iv| {
            if (hi >= iv[0] and lo <= iv[1]) {
                try self.err(pos, "this pattern overlaps an earlier arm", .{});
                return;
            }
        }
        try cov.ints.append(self.ctx.allocator, .{ lo, hi });
    }

    fn checkPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *MatchCoverage) Error!void {
        const covered = &cov.variants;
        switch (pattern) {
            .src => {
                const name = self.text(pattern);
                if (isLiteralText(name)) {
                    try self.checkExpr(pattern, scrutinee);
                    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
                        const i: usize = if (name[0] == 't') 1 else 0;
                        if (cov.bools[i]) try self.errAt(pattern, "this pattern overlaps an earlier arm", .{});
                        cov.bools[i] = true;
                    } else if (self.constInt(pattern)) |v| try self.coverInts(cov, v, v, pattern.src.pos);
                    return;
                }
                cov.has_default = true;
                if (resolve.patternBinds(self.ctx.source, pattern)) {
                    if (self.ctx.symbolOf(pattern)) |sym| {
                        self.ctx.symbols.items[sym].ty = scrutinee;
                        try self.ctx.recordType(pattern, scrutinee);
                    }
                }
            },
            .list => {
                const h = pattern.kind() orelse return;
                switch (h) {
                    .enum_lit => {
                        const name = ir.EnumLit.name(pattern);
                        try self.checkVariantName(name, scrutinee);
                        try self.ctx.recordType(pattern, scrutinee);
                        try self.recordCovered(self.text(name), self.startOf(pattern), covered);
                    },
                    .variant_pattern => try self.checkVariantPattern(pattern, scrutinee, covered),
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
        const st = self.ctx.types.get(sema.unwrapBorrows(self.ctx, scrutinee));
        if (hi_literal and (st == .int or st == .int_literal)) {
            // Record the bound's type without the fit check a value gets.
            const bound_ty = if (st == .int) sema.unwrapBorrows(self.ctx, scrutinee) else self.t().int_id;
            try self.ctx.recordType(hi_node, bound_ty);
            if (hi_node.isKind(.neg)) try self.ctx.recordType(ir.Neg.operand(hi_node), bound_ty);
        } else try self.checkExpr(hi_node, scrutinee);
        if (self.isPoison(scrutinee)) return;
        const lo = self.constInt(lo_node);
        const hi = self.constInt(hi_node);
        if (lo == null or hi == null) {
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

    fn recordCovered(self: *Checker, name: []const u8, pos: u32, covered: *std.StringHashMapUnmanaged(u32)) Error!void {
        if (covered.get(name)) |first| {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            try self.note(first, "first arm here", .{});
            return;
        }
        try covered.put(self.ctx.allocator, name, pos);
    }

    fn rejectWriteBorrowBindings(self: *Checker, pattern: Sexp) Error!void {
        const binds: []const Sexp = if (pattern.isKind(.variant_pattern)) ir.VariantPattern.bindings(pattern) else &.{pattern};
        for (binds) |b| {
            const sym = self.ctx.symbolOf(b) orelse continue;
            if (!sema.holdsWriteBorrow(self.ctx, self.ctx.symbols.items[sym].ty)) continue;
            try self.errAt(b, "cannot bind `{s}`: it holds a write borrow, and the matched value is reached through a read borrow or shared handle, which cannot write", .{self.text(b)});
        }
    }

    fn checkVariantPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, covered: *std.StringHashMapUnmanaged(u32)) Error!void {
        const name = ir.VariantPattern.name(pattern);
        const vname = self.text(name);
        const vpos = name.src.pos;
        try self.recordCovered(vname, vpos, covered);
        if (sema.unwrapBorrows(self.ctx, scrutinee) == self.t().any_error_id) {
            try self.err(vpos, "an error has no payload to destructure; match it as `.{s}`", .{vname});
            return;
        }
        const resolved = (try sema.lookupVariant(self.ctx, scrutinee, vname)) orelse {
            try self.reportMissingVariant(scrutinee, vname, vpos);
            return;
        };
        const bindings = ir.VariantPattern.bindings(pattern);
        if (resolved.payload.len == 0) {
            if (bindings.len > 0) try self.err(vpos, "variant `{s}` has no payload to destructure", .{vname});
            return;
        }
        if (bindings.len != resolved.payload.len) {
            try self.err(vpos, "variant `{s}` has {d} payload field{s}, pattern destructures {d}", .{
                vname, resolved.payload.len, plural(resolved.payload.len), bindings.len,
            });
            return;
        }
        for (bindings, resolved.payload) |b, f| {
            try self.ctx.recordType(b, f.ty);
            if (self.ctx.symbolOf(b)) |sym| self.ctx.symbols.items[sym].ty = f.ty;
        }
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
        try self.err(pos, "no variant `{s}` on enum `{s}`", .{ vname, try self.tyName(sema.unwrapBorrows(self.ctx, enum_ty)) });
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
            .str => self.t().string_id,
            .tag => self.t().invalid_id,
            .list => if (e.kind() == null) self.t().invalid_id else try self.synthList(e),
        };
        try self.ctx.recordType(e, self.canonical(ty));
        return ty;
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
            return self.t().string_id;
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
            if (std.fmt.parseInt(u64, s, 0)) |_| {} else |_| {
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
                return self.functionValue(sym.ty, s, leaf.src.pos);
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
    /// an instance per call, and no single function value.
    fn functionValue(self: *Checker, ty: TypeId, name: []const u8, pos: u32) Error!TypeId {
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
                    try self.errAt(leaf, "`{s}` is a local of the enclosing function; capture it to use it inside the closure (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|?{s}|` or `|!{s}|` borrows it, `|~{s}|` holds it weakly)", .{ name, name, name, name, name, name });
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
        try self.errAt(leaf, "use of unbound name `{s}`", .{name});
        return null;
    }

    /// The binding `name` denotes at `pos` among those declared directly
    /// in `scope`: the latest one whose declaration comes before `pos`,
    /// excluding a `new x = ...` whose value is still being checked (its
    /// right side reads the previous `x`).
    fn visibleIn(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
        var id = self.ctx.lookupInScopeOnly(scope, name) orelse return null;
        while (id != sema.symbol_invalid) {
            const sym = self.ctx.symbols.items[id];
            // A module-level constant is visible in every function body,
            // and in later constants.
            const later = sym.decl_pos > pos and (scope != self.module_scope or self.scope == self.module_scope);
            if (sym.kind == .local and (later or id == self.pending)) {
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
            .read => self.synthBorrow(e, .read),
            .write => self.synthBorrow(e, .write),
            .move => self.synthExpr(ir.Move.operand(e)),
            .share => self.synthShare(e),
            .weak => self.synthWeak(e),
            .clone => self.synthClone(e),
            .@"+", .@"-", .@"*", .@"/", .@"%" => self.checkNumericOperands(e, @tagName(head), .numeric, null),
            .@"&", .@"|", .@"^" => self.checkNumericOperands(e, @tagName(head), .integer, null),
            .@"<<", .@">>" => self.synthShift(e, @tagName(head)),
            .@"<", .@">", .@"<=", .@">=" => self.synthOrdering(e, @tagName(head)),
            .@"==", .@"!=" => self.synthEquality(e),
            .@"and", .@"or" => blk: {
                try self.checkExpr(ir.get(e, .left), self.t().bool_id);
                try self.checkExpr(ir.get(e, .right), self.t().bool_id);
                break :blk self.t().bool_id;
            },
            .not => blk: {
                try self.checkExpr(ir.Not.operand(e), self.t().bool_id);
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
            .lambda => self.checkLambda(e, null, false),
            .builtin => self.synthBuiltin(e, null),
            .@"..",
            => blk: {
                try self.errAt(e, "a range `a..b` can only be used as a `for` loop source", .{});
                break :blk self.t().invalid_id;
            },
            .@"while", .@"for", .labeled, .set, .drop, .@"defer", .@"errdefer" => if (self.isValueLoop(e)) self.checkLoopValue(e, null, true) else blk: {
                try self.checkStmt(e);
                break :blk self.t().void_id;
            },
            .@"return" => blk: {
                try self.checkReturn(e);
                break :blk self.t().noreturn_id;
            },
            .@"break", .@"continue" => blk: {
                try self.checkStmt(e);
                break :blk self.t().noreturn_id;
            },
            .kwarg => blk: {
                try self.errAt(e, "`name: value` is only allowed as a call argument", .{});
                break :blk self.t().invalid_id;
            },
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
        // Constant operands are computed now, so the result must fit.
        if (self.ctx.types.get(ty) == .int) try self.checkLiteralFits(e, ty);
        // Literals default to `Float` unless a type is given them later.
        if (ty == self.t().float_literal_id) try self.checkFloatConstant(e, self.t().float_id);
        return ty;
    }

    /// `checkNumericOperands` where two literal operands, which take no
    /// type from each other, are `Int`s.
    fn checkIntDefaultOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
        const ty = try self.checkNumericOperands(e, op, req, synthesized);
        if (ty != self.t().int_literal_id) return ty;
        try self.checkLiteralFits(ir.get(e, .left), self.t().int_id);
        try self.checkLiteralFits(ir.get(e, .right), self.t().int_id);
        return self.t().int_id;
    }

    /// `a < b`, `<=`, `>`, `>=`: two numbers as for arithmetic, or two
    /// Strings or two `[]U8` slices, ordered by their bytes.
    fn synthOrdering(self: *Checker, e: Sexp, op: []const u8) Error!TypeId {
        const l = ir.get(e, .left);
        const r = ir.get(e, .right);
        const a = try self.synthReached(l);
        const b = try self.synthReached(r);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
        if (!self.isBytes(a) and !self.isBytes(b)) {
            _ = try self.checkIntDefaultOperands(e, op, .ordered, .{ a, b });
            return self.t().bool_id;
        }
        if (a != b) try self.errAt(l, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
        return self.t().bool_id;
    }

    /// A String or a `[]U8`: bytes ordered as text is.
    fn isBytes(self: *Checker, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .string => true,
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
        switch (self.ctx.types.get(ty)) {
            .type_var => |tv| try self.require(tv, .integer, self.startOf(left), op),
            else => if (!sema.isInteger(self.ctx, ty)) {
                try self.errAt(left, "operator `{s}` requires integer operands; got `{s}`", .{ op, try self.tyName(ty) });
                _ = try self.synthExpr(ir.get(e, .right));
                return self.t().invalid_id;
            },
        }
        if (!(try self.checkShiftAmount(ir.get(e, .right), ty, op))) return self.t().invalid_id;
        // Constant operands are computed now, so the result must fit.
        if (self.ctx.types.get(ty) == .int) try self.checkLiteralFits(e, ty);
        return ty;
    }

    /// A shift amount may be any integer; a constant one must be below
    /// the width of the shifted type (`Int` for a literal).
    fn checkShiftAmount(self: *Checker, amount: Sexp, shifted: TypeId, op: []const u8) Error!bool {
        const ty = try self.synthOperandValue(amount);
        if (self.isPoison(ty)) return false;
        switch (self.ctx.types.get(ty)) {
            .type_var => |tv| try self.require(tv, .integer, self.startOf(amount), op),
            else => if (!sema.isInteger(self.ctx, ty)) {
                try self.errAt(amount, "a shift amount must be an integer; got `{s}`", .{try self.tyName(ty)});
                return false;
            },
        }
        const v = self.constInt(amount) orelse return true;
        const width: ?i128 = switch (self.ctx.types.get(shifted)) {
            .int => |info| intBounds(info).bits,
            .type_var => |tv| blk: {
                if (v >= 0) try self.require(tv, .{ .shift = v }, self.startOf(amount), op);
                break :blk null;
            },
            else => 64,
        };
        if (v >= 0 and (width == null or v < width.?)) return true;
        if (width) |w| {
            try self.errAt(amount, "shift amount `{d}` is out of range for `{s}` (0..{d})", .{ v, try self.tyName(self.canonical(shifted)), w - 1 });
        } else try self.errAt(amount, "shift amount `{d}` is negative", .{v});
        return false;
    }

    fn constInt(self: *Checker, e: Sexp) ?i128 {
        return sema.constIntOf(self.ctx, e);
    }

    fn numericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
        const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
        const a = if (synthesized) |ts| ts[0] else try self.synthOperandValue(operands[0]);
        const b = if (synthesized) |ts| ts[1] else try self.synthOperandValue(operands[1]);
        const pos = self.startOf(operands[0]);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().invalid_id;

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
                    try self.errAt(operands[i], "operator `{s}` orders numbers, Strings, and `[]U8` slices; got `{s}`", .{ op, try self.tyName(ty) });
                } else try self.errAt(operands[i], "operator `{s}` requires {s} operands; got `{s}`", .{ op, if (want_int) "integer" else "numeric", try self.tyName(ty) });
                return self.t().invalid_id;
            }
        }
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        if (a_lit and b_lit) {
            return if (a == self.t().float_literal_id or b == self.t().float_literal_id) self.t().float_literal_id else self.t().int_literal_id;
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
        if (lit_ty == self.t().float_literal_id) try self.require(param, .float, pos, op);
        if (lit_ty == self.t().int_literal_id) if (self.constInt(lit)) |v| try self.require(param, .{ .fits = v }, pos, op);
    }

    fn synthNeg(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Neg.operand(e);
        const ty = try self.synthOperandValue(operand);
        if (self.isPoison(ty)) return ty;
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
            const reached = try self.readThrough(other, ty, sema.unwrapBorrows(self.ctx, ty));
            try self.checkExpr(lit, reached);
            if (lit.isKind(.call)) try self.checkEquatable(reached, l, op);
            return self.t().bool_id;
        }
        // A borrowed operand compares as the value it reaches, and an
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
            a = try self.synthReached(l);
            b = try self.synthReached(r);
        }
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
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
        if (a != b) {
            try self.errAt(l, "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
            return self.t().bool_id;
        }
        try self.checkEquatable(a, l, op);
        return self.t().bool_id;
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
        if (value != inner and !(literal and (param != null or compatible(self.ctx, value, inner)))) return false;
        if (param) |tv| try self.requireHoldsLiteral(tv, value, value_node, self.startOf(at), op);
        try self.recordAdapted(value_node, value, inner);
        return true;
    }

    /// Numeric equality: same rules as arithmetic, with operands already synthesized.
    fn checkNumericComparison(self: *Checker, l: Sexp, r: Sexp, a: TypeId, b: TypeId, op: []const u8) Error!void {
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        if (a_lit and !b_lit) return self.checkExpr(l, b);
        if (b_lit and !a_lit) return self.checkExpr(r, a);
        // Two literal operands are compared as `Int`s.
        if (a == self.t().int_literal_id and b == self.t().int_literal_id) {
            try self.checkLiteralFits(l, self.t().int_id);
            try self.checkLiteralFits(r, self.t().int_id);
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
        var params: std.ArrayListUnmanaged(SymbolId) = .empty;
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
        const last = stmts[stmts.len - 1];
        if (expected) |e| {
            try self.checkExpr(last, e);
            return e;
        }
        return self.synthExpr(last);
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
        const inner = switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, opt))) {
            .optional => |i| i,
            else => {
                try self.errAt(left, "`??` needs an optional on its left; this expression has type `{s}`", .{try self.tyName(opt)});
                _ = try self.synthExpr(right);
                return self.t().invalid_id;
            },
        };
        if ((try self.ownsResource(inner, self.startOf(left), "copies out with `??` a value"))) {
            try self.errAt(left, "`??` on an optional `{s}` would copy an owning handle out of it; take the handle out with `if x as h`", .{try self.tyName(opt)});
            return self.t().invalid_id;
        }
        _ = try self.readThrough(left, opt, sema.unwrapBorrows(self.ctx, opt));
        const result = self.fallbackType(inner, expected);
        try self.checkExpr(right, result);
        return result;
    }

    /// The type of `a ?? b` or `a catch b`, where `a` gives an `inner`:
    /// `inner`, or the optional its context expects, which lets the
    /// fallback `b` be `none` or another optional.
    fn fallbackType(self: *Checker, inner: TypeId, expected: ?TypeId) TypeId {
        const e = expected orelse return inner;
        return switch (self.ctx.types.get(e)) {
            .optional => |i| if (compatible(self.ctx, inner, i)) e else inner,
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
        const result = self.fallbackType(inner, expected);
        try self.checkExpr(handler, result);
        return result;
    }

    /// `e!`: the value of fallible `e`; its failure goes to `fail_to`.
    fn synthPropagate(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Propagate.value(e);
        switch (self.body.fail_to) {
            .caller, .module => {},
            .deferred => try self.errAt(operand, "cannot use `!` inside `defer`; a deferred expression cannot propagate failure, so handle it with `catch`", .{}),
            .closure => try self.errAt(operand, "use of `!` propagation requires a fallible enclosing function; a closure body cannot propagate failure, so handle it with `catch`", .{}),
            .drop => try self.errAt(operand, "a `drop` body cannot propagate failure; handle it with `catch`", .{}),
            .infallible => |name| {
                try self.errAt(operand, "use of `!` propagation requires the enclosing function `{s}` to declare a fallible return type (`-> T!`)", .{self.text(name)});
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
    /// A resource inside `e` is handed over, so `e` cannot be a borrow.
    fn synthPropagateNone(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.PropagateNone.value(e);
        switch (self.body.fail_to) {
            .deferred => try self.errAt(operand, "cannot use `?` inside `defer`; deferred code cannot return, so take the value out with `if x as v` or `??`", .{}),
            .closure => try self.errAt(operand, "a closure body cannot return `none` with `?`; take the value out with `if x as v` or `??`", .{}),
            .drop => try self.errAt(operand, "a `drop` body cannot return `none` with `?`; take the value out with `if x as v` or `??`", .{}),
            .caller, .infallible, .module => if (!self.returnsOptional(self.body.ret)) {
                const name = self.body.name;
                if (name == .nil) {
                    try self.errAt(operand, "use of `?` requires the enclosing function to return an optional (`-> T?`)", .{});
                } else {
                    try self.errAt(operand, "use of `?` requires the enclosing function `{s}` to return an optional (`-> T?`)", .{self.text(name)});
                    try self.noteAt(name, "`{s}` declared here", .{self.text(name)});
                }
            },
        }
        const ty = try self.synthExpr(operand);
        if (self.isPoison(ty)) return ty;
        const inner = switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, ty))) {
            .optional => |i| i,
            else => {
                try self.errAt(operand, "`?` needs an optional operand; this expression has type `{s}`", .{try self.tyName(self.canonical(ty))});
                return self.t().invalid_id;
            },
        };
        const borrowed = sema.unwrapBorrows(self.ctx, ty) != ty;
        if (borrowed and (try self.ownsResource(inner, self.startOf(operand), "moves out of a borrow a value"))) {
            try self.errAt(operand, "a borrow cannot give up the resource inside it; take a new handle with `+x` instead", .{});
            return self.t().invalid_id;
        }
        _ = try self.readThrough(operand, ty, sema.unwrapBorrows(self.ctx, ty));
        return inner;
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

    const BorrowKind = enum { read, write };

    /// `?x` / `!x`. Borrowing a borrowed value reborrows it rather than
    /// nesting (`?b` with `b: ?B` is `?B`).
    fn synthBorrow(self: *Checker, e: Sexp, kind: BorrowKind) Error!TypeId {
        const operand = ir.get(e, .operand);
        if (rig.isRangeIndex(operand)) return self.borrowSlice(operand, kind);
        const inner = try self.synthOperand(operand);
        if (self.isPoison(inner)) return inner;
        if (self.cellVecElementIn(operand) != null) {
            try self.errAt(operand, "cannot borrow an element of a Cell's Vec: the cell may change while the borrow lives; copy the element out with `c[i]`", .{});
            return self.t().invalid_id;
        }
        // `?f` of a stack closure lends it as a borrowed callable.
        if (self.closureBinding(operand)) {
            if (kind == .read) return sema.callableOfFn(self.ctx, inner);
            try self.errAt(e, "a call never changes a closure's environment, so a closure is lent to read: write `?{s}`", .{try self.sourceText(operand)});
            return self.t().invalid_id;
        }
        // Anywhere but where a `!Bool` is expected, `!flag` is read as
        // a `Bool`: the habit of `!` as negation.
        if (kind == .write and readValue(self.ctx, inner) == self.t().bool_id and !sameNode(e, self.lent_write)) {
            try self.errAt(e, "`!` is a write borrow; use `not` for negation", .{});
            return self.t().invalid_id;
        }
        // `![]T` is a writable slice, which a read-only `[]T` cannot give.
        if (kind == .write and self.ctx.types.get(inner) == .slice) {
            try self.errAt(operand, "cannot write-borrow a `{s}`: its elements are read-only; take a writable slice of the array or Vec it views with `!xs[a..b]`", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        if (kind == .write and !self.hasStorage(operand)) {
            try self.errAt(operand, "cannot write-borrow a temporary: the change would be lost; bind it to a name first", .{});
            return self.t().invalid_id;
        }
        if (kind == .write and !(try self.checkWritable(operand, operand, "write-borrow"))) return self.t().invalid_id;
        // A borrow of a value holding a Cell can change the Cell, which a
        // loop or match binding only copies.
        if (kind == .read and sema.holdsCellByValue(self.ctx, inner)) {
            if (self.copiedBindingRoot(operand)) |root| {
                try self.errAt(operand, "cannot borrow this: it holds a Cell, and `{s}` is a loop or match binding, a copy, so changes through the borrow would be lost", .{self.text(root)});
                return self.t().invalid_id;
            }
            if (!isPlaceExpr(operand)) {
                try self.errAt(operand, "cannot borrow a temporary that holds a Cell: a change through the borrow would have no place; bind it to a name first", .{});
                return self.t().invalid_id;
            }
        }
        switch (self.ctx.types.get(inner)) {
            .borrow_read => {
                if (kind == .read) return inner;
                try self.errAt(operand, "cannot write-borrow through a read borrow `{s}`", .{try self.tyName(inner)});
                return self.t().invalid_id;
            },
            .borrow_write => |base| {
                return if (kind == .write) inner else self.ctx.intern(.{ .borrow_read = base });
            },
            else => {},
        }
        return self.ctx.intern(if (kind == .read) Type{ .borrow_read = inner } else Type{ .borrow_write = inner });
    }

    /// Whether `e` names a stack closure binding.
    fn closureBinding(self: *Checker, e: Sexp) bool {
        if (e != .src) return false;
        const id = self.ctx.symbolOf(e) orelse return false;
        return self.ctx.symbols.items[id].flags.closure;
    }

    /// A named binding, or a field or element of one or of what a write
    /// borrow points to: storage a write borrow can change.
    fn hasStorage(self: *Checker, place: Sexp) bool {
        var p = place;
        while (p.kind()) |k| switch (k) {
            .member => p = ir.Member.object(p),
            .index => {
                if (rig.isRangeIndex(p)) return false;
                p = ir.Index.object(p);
            },
            else => {
                const ty = self.ctx.typeOf(p) orelse return true;
                return self.ctx.types.get(ty) == .borrow_write;
            },
        };
        return p == .src and self.ctx.symbolOf(p) != null;
    }

    /// `?xs[a..b]`: a read-only slice `[]T`; `!xs[a..b]`: a writable one,
    /// `![]T`.
    fn borrowSlice(self: *Checker, slice: Sexp, kind: BorrowKind) Error!TypeId {
        const ty = if (kind == .read) try self.synthSlice(slice, true) else try self.writeSlice(slice);
        try self.ctx.recordType(slice, ty);
        return ty;
    }

    /// `!xs[a..b]`: a write borrow of the elements from `a` up to `b`, of
    /// an array or a Vec of plain data the code may write, or of a
    /// `![]T`. A String and a `[]T` are read-only.
    fn writeSlice(self: *Checker, slice: Sexp) Error!TypeId {
        const object = ir.Index.object(slice);
        const range = ir.Index.index(slice);
        const obj_ty = try self.synthOperand(object);
        try self.checkSliceRange(range);
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .string => {
                try self.errAt(object, "cannot write-borrow a slice of a String; a String is read-only", .{});
                return self.t().invalid_id;
            },
            .slice => |s| blk: {
                if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
                    try self.errAt(object, "cannot write-borrow a slice of a `{s}`; a `[]T` is read-only (a writable slice is a `![]T`)", .{try self.tyName(obj_ty)});
                    return self.t().invalid_id;
                }
                break :blk s.elem;
            },
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            else => blk: {
                const elem = vecElementType(self.ctx, peeled) orelse {
                    try self.errAt(object, "cannot slice a value of type `{s}`; slice a String, an array, a Vec, or a `[]T`", .{try self.tyName(obj_ty)});
                    return self.t().invalid_id;
                };
                if ((try self.ownsResource(elem, self.startOf(object), "slices a Vec"))) {
                    try self.errAt(object, "cannot slice a `{s}`: a slice would copy owning handles out of the Vec; iterate with `for x in !v` instead", .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                break :blk elem;
            },
        };
        try self.checkSliceBounds(range, len);
        // A `![]T` may be resliced wherever it comes from; an array or a
        // Vec is sliced where it is stored.
        if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
            if (!self.hasStorage(object)) {
                try self.errAt(object, "cannot write-borrow a temporary: the change would be lost; bind it to a name first", .{});
                return self.t().invalid_id;
            }
            if (!isStoragePath(object)) {
                try self.errAt(object, "only a named array or Vec, or a field or element of one, can be sliced; bind this value to a name first", .{});
                return self.t().invalid_id;
            }
        }
        // The binding it reaches may be one no borrow can write (a
        // parameter, a fixed or loop binding): reported, nothing lent.
        const mark = self.ctx.diagnostics.items.len;
        if (!(try self.checkWritable(slice, object, "write-borrow")) or self.ctx.diagnostics.items.len != mark) return self.t().invalid_id;
        return self.ctx.intern(.{ .borrow_write = try self.ctx.intern(.{ .slice = .{ .elem = elem } }) });
    }

    fn synthShare(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Share.operand(e);
        if (operand.isKind(.lambda)) return self.ownedClosure(operand, null);
        const ty = try self.shareOperand(operand, null);
        // A literal takes its default type.
        if (ty == self.t().int_literal_id) try self.checkLiteralFits(operand, self.t().int_id);
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
        switch (self.ctx.types.get(inner)) {
            .borrow_read, .borrow_write => {
                try self.errAt(operand, "a handle holds a value, not a borrow; `{s}` is a borrow: share an owned value instead", .{try self.tyName(inner)});
                return self.t().invalid_id;
            },
            else => {},
        }
        return self.ctx.intern(.{ .shared = inner });
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

    fn synthClone(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Clone.operand(e);
        const inner = try self.synthOperand(operand);
        if (self.isPoison(inner)) return inner;
        // A `![]T` reaches elements it does not own; a copy of the view
        // would be a second path to them.
        if (sema.writeSliceElem(self.ctx, inner) != null) {
            try self.errAt(operand, "`+x` cannot clone a `{s}`: it is a write borrow of elements it does not own; move it with `<x`, or take a read slice with `?x[..]`", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        // A clone reads the value a borrow reaches.
        const value = try self.readThrough(operand, inner, sema.unwrapBorrows(self.ctx, inner));
        switch (self.ctx.types.get(value)) {
            .shared, .weak => return value,
            // An optional handle clones to another optional handle.
            .optional => |o| switch (self.ctx.types.get(o)) {
                .shared, .weak => return value,
                else => {},
            },
            else => {},
        }
        if ((try self.ownsResource(value, self.startOf(operand), "clones a value"))) {
            try self.errAt(operand, "`+x` cannot clone a `{s}`; only `*T` and `~T` handles (or optionals of them) and plain values can be cloned", .{try self.tyName(value)});
            return self.t().invalid_id;
        }
        return value;
    }

    /// The value an operator reads from `e` (`operandValue`).
    fn synthOperandValue(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, operandValue(self.ctx, ty));
    }

    /// The value a borrow `e` reaches, or `e`'s own value.
    fn synthReached(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, sema.unwrapBorrows(self.ctx, ty));
    }

    /// The value `e` gives where a value is read: a borrowed Copy value
    /// reads as the value (`readValue`).
    fn synthValue(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthExpr(e);
        return self.readThrough(e, ty, readValue(self.ctx, ty));
    }

    /// `value`, the value `e` of type `ty` gives where it is read; when
    /// that is what a borrow reaches, `e` reads through it (`recordRead`).
    fn readThrough(self: *Checker, e: Sexp, ty: TypeId, value: TypeId) Error!TypeId {
        if (value != ty) try self.ctx.recordRead(e);
        return value;
    }

    /// Synthesize the operand of a borrow, clone, member access, index,
    /// or method call. The operand is not bound to a name, so a fresh
    /// value that owns a resource there would never be dropped.
    fn synthOperand(self: *Checker, operand: Sexp) Error!TypeId {
        // `*Name(...)` is a new allocation whatever its type turns out to be.
        if (operand.isKind(.share) and ir.Share.operand(operand).isKind(.call) and ir.Call.callee(ir.Share.operand(operand)) == .src) {
            try self.errAt(operand, "this `*{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{self.text(ir.Call.callee(ir.Share.operand(operand)))});
            return self.t().invalid_id;
        }
        const ty = try self.synthExpr(operand);
        try self.rejectResourceTemporary(operand, ty);
        return ty;
    }

    /// Whether a value of `ty` owns a resource, for a check that rejects
    /// `op` on one. Inside a generic body a type holding type parameters
    /// may or may not: `op` is then allowed, and every instantiation must
    /// supply plain data for them.
    fn ownsResource(self: *Checker, ty: TypeId, pos: u32, op: []const u8) Error!bool {
        if (sema.typeHasDropGlue(self.ctx, ty)) return true;
        if (!sema.maybeDropGlue(self.ctx, ty)) return false;
        var held: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer held.deinit(self.ctx.allocator);
        try sema.heldTypeVars(self.ctx, ty, &held, self.ctx.allocator);
        for (held.items) |param| try self.ctx.generic_requirements.append(self.ctx.allocator, .{ .param = param, .req = .plain, .pos = pos, .op = op });
        return false;
    }

    /// A fresh value (a call result, `*x`, `+x`, `<x`, ...) that owns a
    /// resource, where nothing takes ownership of it.
    fn rejectResourceTemporary(self: *Checker, operand: Sexp, ty: TypeId) Error!void {
        if (isPlaceExpr(operand) or !(try self.ownsResource(ty, self.startOf(operand), "leaves a temporary"))) return;
        try self.errAt(operand, "this `{s}` is a temporary that owns a resource, and nothing would drop it; bind it to a name first", .{try self.tyName(ty)});
    }

    // ---- member access and indexing -------------------------------------------

    fn synthMember(self: *Checker, e: Sexp) Error!TypeId {
        const obj = ir.Member.object(e);
        const field_node = ir.Member.name(e);
        const field = self.text(field_node);
        const pos = srcPos(field_node, self.startOf(obj));

        if (try self.moduleMember(obj, field, pos)) |ty| return ty;
        if (try self.namedType(obj)) |nt| return self.typeMember(nt, field, pos);
        return self.memberOf(e, obj, try self.synthOperand(obj));
    }

    /// Member `e` of `obj`, a value of type `obj_ty`.
    fn memberOf(self: *Checker, e: Sexp, obj: Sexp, obj_ty: TypeId) Error!TypeId {
        const field_node = ir.Member.name(e);
        const field = self.text(field_node);
        const pos = srcPos(field_node, self.startOf(obj));
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);

        switch (self.ctx.types.get(peeled)) {
            .optional => {
                try self.err(pos, "cannot access `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ field, try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            .array, .slice, .string => if (std.mem.eql(u8, field, "len")) return self.t().int_id,
            .parameterized_nominal => if ((vecElementType(self.ctx, peeled) != null or cellVecElement(self.ctx, peeled) != null) and std.mem.eql(u8, field, "len")) return self.t().int_id,
            .type_var => {
                try self.err(pos, "a generic parameter `{s}` has no fields; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            else => {},
        }

        // `value` names a Cell's constructor argument, not a field to read.
        if (std.mem.eql(u8, field, "value") and cellElementType(self.ctx, peeled) != null) {
            try self.err(pos, "a Cell is read with `c.get()` and written with `c.set(v)`, not through `.value`", .{});
            return self.t().invalid_id;
        }

        if (try self.dataField(obj_ty, field)) |ty| return ty;
        const decl = sema.nominalDecl(self.ctx, peeled) orelse {
            // An element method named without its call.
            const has_elems = switch (self.ctx.types.get(peeled)) {
                .array, .slice, .string => true,
                else => vecElementType(self.ctx, peeled) != null,
            };
            if (has_elems) if (std.meta.stringToEnum(sema.ElemOp, field)) |op| {
                const shown = switch (op) {
                    .copy => "!xs.copy(src)",
                    .fill => "!xs.fill(v)",
                    .swap => "!xs.swap(i, j)",
                    .read => "xs.read[U32, .little](at)",
                    .write => "!xs.write[U32, .little](at, v)",
                };
                try self.err(pos, "`{s}` is a method of `{s}`, only called: `{s}`", .{ field, try self.tyName(obj_ty), shown });
                return self.t().invalid_id;
            };
            try self.err(pos, "type `{s}` has no field `{s}`", .{ try self.tyName(obj_ty), field });
            return self.t().invalid_id;
        };
        const owner = decl.symbol();
        if ((try self.findMethod(obj_ty, field)) != null) {
            if (owner.kind == .generic_type) {
                try self.err(pos, "method `{s}` must be called; wrap it in a closure to pass it as a value", .{field});
            } else {
                const tname = if (decl.module_id != null) try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ decl.ctx.name, owner.name }) else owner.name;
                try self.err(pos, "method `{s}` must be called; to pass it as a function that takes the receiver first, name it through its type: `{s}.{s}`", .{ field, tname, field });
            }
        } else if (owner.fields == null) {
            try self.err(pos, "opaque type `{s}` has no accessible fields", .{owner.name});
        } else {
            try self.err(pos, "no field `{s}` on type `{s}`", .{ field, owner.name });
            try self.noteDeclared(owner, decl.module_id == null);
        }
        return self.t().invalid_id;
    }

    /// The type of data field `name` of a receiver's nominal type, local
    /// or imported.
    fn dataField(self: *Checker, obj_ty: TypeId, name: []const u8) Error!?TypeId {
        if (try sema.lookupDataField(self.ctx, obj_ty, name)) |f| return f.ty;
        const decl = sema.nominalDecl(self.ctx, sema.unwrapReadAccess(self.ctx, obj_ty)) orelse return null;
        const module_id = decl.module_id orelse return null;
        const f = findDataField(decl.symbol().fields orelse &.{}, name) orelse return null;
        return try sema.importType(self.ctx, self.ctx.foreign_semas.get(module_id).?, f.ty, module_id);
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
    };

    fn findMethod(self: *Checker, obj_ty: TypeId, name: []const u8) Error!?Method {
        if (try sema.lookupMethod(self.ctx, obj_ty, name)) |m| {
            return .{ .field = m.field, .fn_ty = m.fn_ty, .owner = self.ctx.symbols.items[m.nominal_sym].name, .nominal_sym = m.nominal_sym, .source = self.declSource(m.nominal_sym) };
        }
        const decl = sema.nominalDecl(self.ctx, sema.unwrapReadAccess(self.ctx, obj_ty)) orelse return null;
        const module_id = decl.module_id orelse return null;
        const foreign = self.ctx.foreign_semas.get(module_id).?;
        for (decl.symbol().fields orelse &.{}) |f| {
            if (!f.is_method or f.is_drop_method or !std.mem.eql(u8, f.name, name)) continue;
            const ty = self.ctx.types.get(try sema.importType(self.ctx, foreign, f.ty, module_id));
            if (ty != .function) return null;
            return .{ .field = f, .fn_ty = ty.function, .owner = decl.symbol().name, .nominal_sym = sema.symbol_invalid, .source = foreign.source };
        }
        return null;
    }

    /// `module.name` as a value. Null when `obj` does not name a module.
    fn moduleMember(self: *Checker, obj: Sexp, field: []const u8, pos: u32) Error!?TypeId {
        const id = (try self.moduleNamed(obj)) orelse return null;
        const found = (try self.foreignSymbol(id, field, pos)) orelse return self.t().invalid_id;
        if (found.sym.kind == .nominal_type or found.sym.kind == .generic_type) {
            try self.err(pos, "`{s}.{s}` is a type, not a value", .{ self.text(obj), field });
            return self.t().invalid_id;
        }
        const ty = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
        if (found.sym.kind == .function) return try self.functionValue(ty, try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ self.text(obj), field }), pos);
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
        /// A generic type's arguments, when given (`Pair[Int, String]`).
        args: ?[]const TypeId = null,
    };

    fn namedType(self: *Checker, obj: Sexp) Error!?NamedType {
        if (rig.isBracketList(obj)) {
            const target = (try self.instTarget(ir.get(obj, .object))) orelse return null;
            if (target != .generic) return null;
            var nt = target.generic;
            const ty = try self.typeInstance(obj, nt);
            const arity = if (nt.sym.type_params) |tps| tps.len else 0;
            nt.args = if (self.isPoison(ty)) try self.poisonArgs(arity) else self.ctx.types.get(ty).parameterized_nominal.args;
            return nt;
        }
        if (obj == .src) {
            var id = self.lookupQuiet(obj) orelse return null;
            if (self.aliasedNominal(id)) |target| id = target;
            const sym = self.ctx.symbols.items[id];
            if (sym.kind != .nominal_type and sym.kind != .generic_type) return null;
            try self.ctx.recordName(obj, id);
            return .{ .id = id, .sym = sym };
        }
        if (!obj.isKind(.member)) return null;
        const id = (try self.moduleNamed(ir.Member.object(obj))) orelse return null;
        const name = ir.Member.name(obj);
        const found = (try self.foreignSymbol(id, self.text(name), name.src.pos)) orelse return null;
        if (found.sym.kind == .generic_type) return try self.foreignGeneric(found);
        if (found.sym.kind != .nominal_type) return null;
        return .{ .id = found.id, .sym = found.sym, .foreign = .{ .ctx = found.ctx, .module_id = found.module_id } };
    }

    /// A named type as this module spells it: `lib.Point` for another
    /// module's (a generic one's proxy is named so already).
    fn namedTypeName(self: *Checker, nt: NamedType) Error![]const u8 {
        const fo = nt.foreign orelse return nt.sym.name;
        return std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ fo.ctx.name, nt.sym.name });
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

    /// The type an alias of a local struct or enum names (`Point` for
    /// `type P2 = Point`): the alias constructs its values and reaches its
    /// members as the type itself does.
    fn aliasedNominal(self: *Checker, id: SymbolId) ?SymbolId {
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .type_alias) return null;
        return switch (self.ctx.types.get(sym.ty)) {
            .nominal => |target| target,
            else => null,
        };
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
        for (members) |m| {
            if (!std.mem.eql(u8, m.name, field)) continue;
            // `Type.method` is a plain function value whose first
            // parameter is the receiver.
            if (m.is_method) {
                if (nt.sym.kind == .generic_type) {
                    try self.err(pos, "method `{s}.{s}` of a generic type must be called; wrap it in a closure to pass it as a value", .{ tname, field });
                    return self.t().invalid_id;
                }
                const name = try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ tname, field });
                return self.functionValue(try self.memberType(nt.foreign, m.ty), name, pos);
            }
            if (!m.is_variant) break;
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
        /// A generic type, local or built in: `Vec[Int]`.
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
            const origin = self.ctx.module_refs.get(id) orelse return null;
            const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
            const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse return null;
            const fsym = foreign.symbols.items[fid];
            return switch (fsym.kind) {
                .function, .@"extern" => .{ .function = fnTarget(foreign, fsym.ty) },
                .nominal_type, .type_alias => .{ .not_generic = try self.sourceText(obj) },
                .generic_type => blk: {
                    try self.ctx.recordName(inner, id);
                    const found = (try self.foreignSymbol(id, name, ir.Member.name(obj).src.pos)) orelse break :blk .reported;
                    break :blk .{ .generic = try self.foreignGeneric(found) };
                },
                else => null,
            };
        };
        if (try self.namedType(inner)) |nt| {
            for (nt.sym.fields orelse &.{}) |m| {
                if (m.is_method and !m.is_drop_method and std.mem.eql(u8, m.name, name)) return .{ .function = fnTarget(if (nt.foreign) |fo| fo.ctx else self.ctx, m.ty) };
            }
            return null;
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
    fn sourceText(self: *Checker, node: Sexp) Error![]const u8 {
        const sp = self.ctx.span(node);
        return self.ctx.source[sp.start..sp.end];
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
                if (!self.isPoison(try self.typeInstance(e, nt))) try self.errAt(e, "`{s}` is a type, not a value", .{try self.sourceText(e)});
            },
            .function => |f| {
                const call = try self.sourceText(e);
                if (!f.ct_params) {
                    const name = try self.sourceText(ir.get(e, .object));
                    try self.errAt(e, "`{s}` takes no compile-time arguments; call it with `{s}(...)`", .{ name, name });
                } else try self.errAt(e, "`{s}` is a function with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (f.takes_args) "..." else "" });
            },
            .not_generic, .reported => try self.notGeneric(e, target),
            .value_member => unreachable,
        }
        return self.t().invalid_id;
    }

    /// The instance of generic type `nt` that bracket list `e` names
    /// (`Pair[Int, String]`), recorded for `e`; poison after a
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

    /// A type argument written in an expression (`Vec[*Node]()`): a
    /// name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[Y]`.
    fn typeArg(self: *Checker, e: Sexp) Error!TypeId {
        var r = self.resolver();
        switch (e) {
            .src => if (!isLiteralText(self.text(e))) return r.resolveType(e),
            .list => switch (e.kind() orelse return self.t().invalid_id) {
                .member => if (ir.Member.object(e) == .src) return r.resolveType(e),
                .share, .weak, .read, .write, .propagate_none => {
                    if (e.isKind(.share) or e.isKind(.weak)) if (try self.optionalHandleArg(e)) |ty| return ty;
                    const inner_node = ir.get(e, if (e.isKind(.propagate_none)) .value else .operand);
                    const inner = try self.typeArg(inner_node);
                    if (self.isPoison(inner)) return inner;
                    if (e.isKind(.share) and self.ctx.types.get(inner) == .shared) {
                        try self.errAt(inner_node, "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                        return self.t().invalid_id;
                    }
                    if ((e.isKind(.share) or e.isKind(.weak)) and sema.isBorrowType(self.ctx, inner)) {
                        try self.errAt(e, "a handle holds a value, not a borrow: `{s}` has no handle", .{try self.tyName(inner)});
                        return self.t().invalid_id;
                    }
                    return self.ctx.intern(switch (e.kind().?) {
                        .share => .{ .shared = inner },
                        .weak => .{ .weak = inner },
                        .read => .{ .borrow_read = inner },
                        .write => .{ .borrow_write = inner },
                        else => .{ .optional = inner },
                    });
                },
                .propagate => {
                    try self.errAt(e, "a fallible type `{s}` is only allowed as a function's return type", .{try self.sourceText(e)});
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
        try self.errAt(e, "`{s}` is not a type; a type argument in an expression is a name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[T]`", .{try self.sourceText(e)});
        return self.t().invalid_id;
    }

    /// `*T?`, `~T?`, `*~T?` written as a type argument: an optional
    /// handle, since a handle binds tighter than a suffix. An expression
    /// reads it as the handles of `T?`, so the suffixes move outside the
    /// whole chain of handles. A handle to an optional, `*(T?)`, has no
    /// expression spelling, and a fallible one is only a return type.
    /// Null when the chain has no suffix to move.
    fn optionalHandleArg(self: *Checker, e: Sexp) Error!?TypeId {
        var handles: std.ArrayListUnmanaged(Sexp) = .empty;
        var op = e;
        while (op.isKind(.share) or op.isKind(.weak)) : (op = ir.get(op, .operand)) try handles.append(self.ctx.arena.allocator(), op);
        if (!op.isKind(.propagate_none) and !op.isKind(.propagate)) return null;
        if (self.ctx.parser) |p| if (p.hasParenSuffix(e)) {
            try self.errAt(e, "a handle to an optional has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead", .{});
            return self.t().invalid_id;
        };
        var count: u32 = 0;
        var base = op;
        while (base.isKind(.propagate_none) or base.isKind(.propagate)) : (count += 1) {
            if (base.isKind(.propagate)) {
                try self.errAt(e, "a fallible type `{s}` is only allowed as a function's return type", .{try self.sourceText(e)});
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
            if (h.isKind(.share) and self.ctx.types.get(ty) == .shared) {
                try self.errAt(inner_node, "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                return self.t().invalid_id;
            }
            ty = try self.ctx.intern(if (h.isKind(.share)) .{ .shared = ty } else .{ .weak = ty });
            inner_node = h;
        }
        while (count > 0) : (count -= 1) ty = try self.ctx.intern(.{ .optional = ty });
        return ty;
    }

    /// `Wrap[Int](v: 3)`, `Vec[Int]()`: a generic type constructed at the
    /// given arguments.
    fn constructInstance(self: *Checker, call: Sexp, e: Sexp, nt: NamedType, args: []const Sexp) Error!TypeId {
        const ty = try self.typeInstance(e, nt);
        if (self.isPoison(ty)) return self.skipCall(args);
        if (nt.id == self.ctx.vec_sym_id) {
            try self.checkVecConstruction(call);
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

    /// A public module-level symbol of an imported module.
    fn foreignSymbol(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32) Error!?Foreign {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const origin = self.ctx.module_refs.get(module_sym) orelse {
            try self.err(pos, "module `{s}` was not loaded", .{module_name});
            return null;
        };
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse {
            try self.err(pos, "no member `{s}` in module `{s}`", .{ name, module_name });
            return null;
        };
        const fsym = foreign.symbols.items[fid];
        if (!fsym.flags.is_public and fsym.decl_pos != sema.builtin_decl_pos) {
            try self.err(pos, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ module_name, name, module_name });
            return null;
        }
        return .{ .ctx = foreign, .module_id = origin, .id = fid, .sym = fsym };
    }

    fn synthIndex(self: *Checker, e: Sexp) Error!TypeId {
        const object = ir.get(e, .object);
        if (e.isKind(.index) and ir.Index.index(e).isKind(.@"..")) return self.synthSlice(e, false);
        if (try self.instTarget(object)) |target| {
            if (target != .value_member) return self.misusedInstance(e, target);
            // `value.name[...]`: a method's compile-time arguments, which
            // only a call takes, or an element of a field.
            const inner = ir.Member.object(object);
            const inner_ty = try self.synthOperand(inner);
            if (!self.isPoison(inner_ty)) if (try self.findMethod(inner_ty, self.text(ir.Member.name(object)))) |m| {
                const call = try self.sourceText(e);
                const takes_args = m.fn_ty.params.len > @intFromBool(m.field.receiver != .none);
                try self.errAt(e, "`{s}` is a method with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (takes_args) "..." else "" });
                return self.t().invalid_id;
            };
            const field_ty = try self.memberOf(object, inner, inner_ty);
            try self.ctx.recordType(object, field_ty);
            return self.indexInto(e, field_ty);
        }
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
            try self.errAt(index, "an index must be an integer; got `{s}`", .{try self.tyName(idx_ty)});
        } else if (idx_ty == self.t().int_literal_id) try self.checkLiteralFits(index, self.t().int_id);
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
                _ = try self.readThrough(object, obj_ty, sema.unwrapBorrows(self.ctx, obj_ty));
                return s.elem;
            },
            .string => {
                _ = try self.readThrough(object, obj_ty, sema.unwrapBorrows(self.ctx, obj_ty));
                return self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
            },
            .parameterized_nominal => if (vecElementType(self.ctx, peeled)) |elem| {
                if ((try self.ownsResource(elem, self.startOf(object), "copies an element out of a Vec"))) {
                    try self.errAt(object, "indexing a `{s}` would copy an owning handle out of the Vec; iterate with `for x in ?v` instead", .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                return elem;
            } else if (cellVecElement(self.ctx, peeled)) |elem| {
                if ((try self.ownsResource(elem, self.startOf(object), "reads an element of a Cell's Vec"))) {
                    try self.errAt(object, cell_vec_handle, .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                return elem;
            },
            else => {},
        }
        try self.errAt(object, "cannot index a value of type `{s}`", .{try self.tyName(obj_ty)});
        return self.t().invalid_id;
    }

    /// `xs[a..b]`: the elements from `a` up to, not including, `b`. A
    /// String gives a String, which borrows nothing: every String is a
    /// static literal. A `[]T` gives a `[]T` viewing the same elements.
    /// An array or a `Vec` of plain data gives a `[]T` only as
    /// `?xs[a..b]` (`borrowed`): the slice is a read borrow of `xs`.
    fn synthSlice(self: *Checker, e: Sexp, borrowed: bool) Error!TypeId {
        const object = ir.Index.object(e);
        const range = ir.Index.index(e);
        const obj_ty = try self.synthOperand(object);
        try self.checkSliceRange(range);
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .string, .slice => {
                _ = try self.readThrough(object, obj_ty, peeled);
                try self.checkSliceBounds(range, null);
                // A `![]T` is borrowed like the array it views: a read
                // slice of it keeps it from being written meanwhile.
                if (!borrowed and sema.writeSliceElem(self.ctx, obj_ty) != null) {
                    const sp = self.ctx.span(e);
                    try self.errAt(e, "a slice of a `![]T` borrows it; write `?{s}` or `!{s}`", .{ self.ctx.source[sp.start..sp.end], self.ctx.source[sp.start..sp.end] });
                    return self.t().invalid_id;
                }
                return peeled;
            },
            .array => |a| a.elem,
            else => blk: {
                const elem = vecElementType(self.ctx, peeled) orelse {
                    try self.errAt(object, "cannot slice a value of type `{s}`; slice a String, an array, a Vec, or a `[]T`", .{try self.tyName(obj_ty)});
                    return self.t().invalid_id;
                };
                if ((try self.ownsResource(elem, self.startOf(object), "slices a Vec"))) {
                    try self.errAt(object, "cannot slice a `{s}`: a slice would copy owning handles out of the Vec; iterate with `for x in ?v` instead", .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                break :blk elem;
            },
        };
        const len: ?u64 = if (self.ctx.types.get(peeled) == .array) sema.arrayLen(self.ctx, self.ctx.types.get(peeled).array) else null;
        try self.checkSliceBounds(range, len);
        if (!borrowed) {
            const sp = self.ctx.span(e);
            try self.errAt(e, "a slice of an array or Vec borrows it; write `?{s}`", .{self.ctx.source[sp.start..sp.end]});
            return self.t().invalid_id;
        }
        if (!isStoragePath(object)) {
            try self.errAt(object, "only a named array or Vec, or a field or element of one, can be sliced; bind this value to a name first", .{});
            return self.t().invalid_id;
        }
        return self.ctx.intern(.{ .slice = .{ .elem = elem } });
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
        if (ty == self.t().int_literal_id) try self.checkLiteralFits(bound, self.t().int_id);
    }

    /// Constant bounds are checked now: `0 <= a <= b`, and `b <= len` for
    /// an array, whose length is part of its type. Others are checked
    /// when the slice is taken. An open end is the length.
    fn checkSliceBounds(self: *Checker, range: Sexp, len: ?u64) Error!void {
        const lo_node = ir.@"..".left(range);
        const hi_node = ir.@"..".right(range);
        const lo: ?i128 = if (lo_node == .nil) 0 else self.constInt(lo_node);
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
        if (concrete != elem) {
            for (elems) |e| try self.checkExpr(e, concrete);
        } else for (elems, elem_tys) |e, ty| try self.adaptLiteral(e, ty, concrete);
        if ((try self.ownsResource(concrete, self.startOf(node), "puts in an array a value"))) {
            try self.errAt(node, "arrays cannot hold values that own resources (`{s}`); use a `Vec`", .{try self.tyName(concrete)});
            return self.t().invalid_id;
        }
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
        if (try self.ownsResource(elem, self.startOf(value), "copies into every slot of `[n of x]` a value")) {
            try self.errAt(value, "`[n of x]` copies its element into every slot; `{s}` owns a resource, so an array cannot hold it (use a `Vec`)", .{try self.tyName(elem)});
            return self.t().invalid_id;
        }
        if (sema.holdsBorrow(self.ctx, elem)) {
            try self.errAt(value, "`[n of x]` copies its element into every slot; `{s}` holds a borrow, and its element must be plain data", .{try self.tyName(elem)});
            return self.t().invalid_id;
        }
        const ty = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
        // An expected array type was checked where it was spelled or
        // inferred.
        if (expected == null and !self.under_poison and !try sema.checkArrayBytes(self.ctx, self.startOf(node), ty)) return self.t().invalid_id;
        if (expected) |ex| if (ex != ty) {
            try self.errAt(node, "`{s}` has length `{s}`; `{s}` needs `{s}`", .{ try self.sourceText(node), try self.tyName(len), try self.tyName(ex), try self.tyName(self.ctx.types.get(ex).array.len) });
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
        const ty = try self.synthCallInner(node);
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
            if (obj == .src) return std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ self.text(obj), name });
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
            .generic => |nt| return self.constructInstance(node, callee, nt, args),
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
                if (resolve.isNumericTypeName(name)) {
                    var r = self.resolver();
                    return self.checkConversion(try r.resolveType(callee), name, args, callee.src.pos);
                }
            }
            var sym_id = (try self.useName(callee)) orelse return self.skipCall(args);
            if (self.aliasedNominal(sym_id)) |target| {
                try self.ctx.recordName(callee, target);
                sym_id = target;
            }
            const sym = self.ctx.symbols.items[sym_id];
            if (sym.kind != .nominal_type and sym.kind != .generic_type and sym.kind != .type_alias and sym.kind != .module) {
                try self.ctx.recordType(callee, sym.ty);
            }
            switch (sym.kind) {
                .function, .@"extern" => return self.functionCall(callee, sym, ct, args),
                .nominal_type => return self.construct(sym_id, args, callee.src.pos, TypeSubst.empty, null),
                .type_alias => return self.badCall(args, callee, "`{s}` is a type alias for `{s}` and cannot be called as a constructor; construct the aliased type directly", .{ name, try self.tyName(sym.ty) }),
                .generic_type => {
                    if (sym_id == self.ctx.vec_sym_id) return self.badCall(args, callee, "`Vec()` needs its element type: name it (`Vec[T]()`), or give it where the value goes (`v: Vec[T] = Vec()`)", .{});
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
        return self.callValue(callee, callee_ty, args, try self.sourceText(callee));
    }

    /// `Wrap(v: 3)`, `lib.Wrap(v: 3)`: generic type `sym_id`, named `name`
    /// by `callee`, constructed at the type arguments its fields' values
    /// and the type expected of it give.
    fn constructGeneric(self: *Checker, callee: Sexp, sym_id: SymbolId, args: []const Sexp, name: []const u8, pos: u32) Error!TypeId {
        if (args.len > 0 and self.isTypeName(args[0])) {
            try self.errAt(callee, "type arguments go in brackets: `{s}[{s}](...)`", .{ name, self.text(args[0]) });
            return self.t().invalid_id;
        }
        // Fields are set by name; a positional argument binds nothing to
        // infer from.
        for (args) |a| if (!a.isKind(.kwarg)) return self.badCall(args, pos, "fields of `{s}` are set by name: `{s}(field: value)`", .{ name, name });
        const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
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
        if (fty != .function) return self.badCall(args, callee, "`{s}` has type `{s}` and cannot be called{s}", .{ name, try self.tyName(sym.ty), try self.prefixHint(callee, name, args) });
        if (sym.kind == .@"extern" and self.raw_depth == 0) {
            try self.errAt(callee, "call to extern function `{s}` requires `raw` block; extern functions are the FFI boundary and bypass Rig's ownership and effect checks", .{name});
        }
        const info = paramsOf(sym, self.ctx.source);
        const f = (try self.instantiateCall(fty.function, ct, args, info, 0, name, callee.src.pos, false, .empty)) orelse return self.skipCall(args);
        // A generic function's callee has the instance's signature.
        if (fty.function.ct_params.len > 0) try self.ctx.recordType(callee, try self.ctx.internCopy(.{ .function = f }));
        self.lend_call = true;
        try self.checkArgs(args, f, info, name, callee.src.pos);
        return f.returns;
    }

    /// Call a value: a function-typed binding, a closure, or an owned
    /// closure handle.
    fn callValue(self: *Checker, callee: Sexp, ty: TypeId, args: []const Sexp, name: []const u8) Error!TypeId {
        const pos = self.startOf(callee);
        if (self.isPoison(ty)) return self.skipCall(args);
        if (sema.callableFn(self.ctx, ty)) |f| {
            try self.checkArgs(args, f, .{}, name, pos);
            return f.returns;
        }
        if (sema.ownedClosureFn(self.ctx, ty)) |f| {
            try self.checkArgs(args, f, .{}, name, pos);
            return f.returns;
        }
        const fty = self.ctx.types.get(sema.unwrapBorrows(self.ctx, ty));
        if (fty == .function) {
            try self.checkArgs(args, fty.function, .{}, name, pos);
            return fty.function.returns;
        }
        return self.badCall(args, pos, "`{s}` has type `{s}` and cannot be called{s}", .{ name, try self.tyName(ty), try self.prefixHint(callee, name, args) });
    }

    /// For a paren-free call `a -1` whose callee cannot be called: the
    /// sigil touching the argument is a prefix, and the infix operator
    /// it also spells takes a space on both sides.
    fn prefixHint(self: *Checker, callee: Sexp, name: []const u8, args: []const Sexp) Error![]const u8 {
        if (args.len == 0) return "";
        const arg = args[0];
        const op: []const u8, const verb: []const u8, const operand = switch (arg.kind() orelse return "") {
            .neg => .{ "-", "subtract", ir.Neg.operand(arg) },
            .move => .{ "<", "compare", ir.Move.operand(arg) },
            .share => .{ "*", "multiply", ir.Share.operand(arg) },
            .clone => .{ "+", "add", ir.Clone.operand(arg) },
            else => return "",
        };
        const gap = self.ctx.source[self.ctx.span(callee).end..self.startOf(arg)];
        if (gap.len == 0 or std.mem.indexOfNone(u8, gap, " ") != null) return "";
        return std.fmt.allocPrint(self.ctx.arena.allocator(), "; a sigil touching its operand is a prefix: to {s}, write `{s} {s} {s}`", .{ verb, name, op, try self.sourceText(operand) });
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
    /// none) is reported.
    fn synthArgs(self: *Checker, args: []const Sexp) Error!void {
        const saved = self.under_poison;
        defer self.under_poison = saved;
        self.under_poison = true;
        for (args) |a| {
            const e = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
            if (e.isKind(.array) and ir.Array.elems(e).len == 0) continue;
            _ = try self.synthExpr(e);
        }
    }

    /// `I32(x)`, `U8(x)`, `Float(n)`, `Int(f)`: a numeric conversion to
    /// the named type. It is checked: a value that does not fit panics
    /// when the program runs, and a float converted to an integer is
    /// truncated toward zero. A constant argument is converted now, so
    /// it must fit.
    fn checkConversion(self: *Checker, target: TypeId, name: []const u8, args: []const Sexp, pos: u32) Error!TypeId {
        if (args.len != 1 or args[0].isKind(.kwarg)) {
            try self.err(pos, "`{s}(x)` converts one number; it takes exactly one argument", .{name});
            try self.synthArgs(args);
            return target;
        }
        const arg = args[0];
        const from = try self.synthValue(arg);
        if (self.isPoison(from)) return target;
        if (!sema.isNumeric(self.ctx, from)) {
            try self.errAt(arg, "`{s}(x)` converts a number; `x` has type `{s}`", .{ name, try self.tyName(from) });
        } else if (self.ctx.types.get(target) == .int) {
            if (sema.isInteger(self.ctx, from)) try self.checkLiteralFits(arg, target) else try self.checkFloatFits(arg, target);
        }
        return target;
    }

    /// A constant float converted to integer type `target`: its integer
    /// part must fit.
    fn checkFloatFits(self: *Checker, arg: Sexp, target: TypeId) Error!void {
        const f = constFloatOf(self.ctx.source, arg) orelse return;
        const b = intBounds(self.ctx.types.get(target).int);
        const whole = @trunc(f);
        if (whole >= @as(f64, @floatFromInt(b.min)) and whole < @as(f64, @floatFromInt(b.max)) + 1) return;
        if (@abs(f) < 1e18) {
            try self.errAt(arg, "`{d}` does not fit in `{s}`", .{ f, try self.tyName(target) });
        } else try self.errAt(arg, "`{e}` does not fit in `{s}`", .{ f, try self.tyName(target) });
    }

    /// `print(a, b, ...)`: any number of values, printed on one line.
    fn checkPrint(self: *Checker, args: []const Sexp) Error!TypeId {
        for (args) |a| {
            if (a.isKind(.kwarg)) {
                try self.errAt(a, "`print` takes no keyword arguments", .{});
                continue;
            }
            const ty = try self.synthOperand(a);
            // An integer literal prints as an `Int`, which must hold it.
            if (ty == self.t().int_literal_id) try self.checkLiteralFits(a, self.t().int_id);
            switch (self.ctx.types.get(ty)) {
                .void => try self.errAt(a, "`print` needs a value; this expression produces no value (`Void`)", .{}),
                .none_literal => try self.errAt(a, "cannot print a bare `none`", .{}),
                else => {
                    var seen: std.ArrayListUnmanaged(ByteSliceVisit) = .empty;
                    defer seen.deinit(self.ctx.allocator);
                    if (try holdsByteSlice(self.ctx, ty, &seen, self.ctx.allocator)) {
                        const name = try self.tyName(ty);
                        const direct = std.mem.eql(u8, name, "[]U8");
                        try self.errAt(a, "cannot print a `{s}`: {s}would print as text, like a String; print the bytes one by one", .{ name, if (direct) "it " else "the `[]U8` it holds " });
                    }
                },
            }
        }
        return self.t().void_id;
    }

    const ByteSliceVisit = struct { ctx: *const SemContext, sym: SymbolId };

    /// Whether a value of `ty` holds a `[]U8`, directly or through a
    /// wrapper, field, payload, or type argument. A `[]U8` and a String
    /// are both Zig `[]const u8`, so `print` cannot tell them apart.
    fn holdsByteSlice(ctx: *const SemContext, ty: TypeId, seen: *std.ArrayListUnmanaged(ByteSliceVisit), a: std.mem.Allocator) Error!bool {
        switch (ctx.types.get(ty)) {
            .slice => |sl| return switch (ctx.types.get(sl.elem)) {
                .int => |i| i.bits == 8 and !i.signed,
                else => holdsByteSlice(ctx, sl.elem, seen, a),
            },
            .optional, .fallible, .borrow_read, .borrow_write, .shared => |inner| return holdsByteSlice(ctx, inner, seen, a),
            .array => |arr| return holdsByteSlice(ctx, arr.elem, seen, a),
            .parameterized_nominal => |pn| for (pn.args) |arg| {
                if (try holdsByteSlice(ctx, arg, seen, a)) return true;
            },
            .nominal, .imported_nominal => {},
            else => return false,
        }
        const decl = sema.nominalDecl(ctx, ty) orelse return false;
        for (seen.items) |v| if (v.ctx == decl.ctx and v.sym == decl.sym) return false;
        try seen.append(a, .{ .ctx = decl.ctx, .sym = decl.sym });
        for (decl.ctx.symbols.items[decl.sym].fields orelse &.{}) |*f| {
            for (sema.dataFields(f)) |d| if (try holdsByteSlice(decl.ctx, d.ty, seen, a)) return true;
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

    /// Arguments against a signature: arity, types, keyword arguments
    /// by parameter name, and defaults for omitted parameters. A call
    /// that uses keywords or defaults records its argument slots.
    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo, callee: []const u8, pos: u32) Error!void {
        const call = self.current_call;
        const lends = self.lend_call and !self.callRetains(f, self.lend_recv);
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
        if (!complete or (keyword.len == 0 and args.len == f.params.len)) return;
        const call_node = call orelse return;
        const out = try self.ctx.arena.allocator().alloc(sema.ArgSlot, slots.len);
        for (slots, out) |s, *o| o.* = s.?;
        try self.ctx.recordCallSlots(call_node, out);
    }

    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, lends: bool) Error!void {
        const saved = self.lent_temp;
        const saved_callable = self.lent_callable;
        const saved_kept = self.callable_kept;
        defer {
            self.lent_temp = saved;
            self.lent_callable = saved_callable;
            self.callable_kept = saved_kept;
        }
        self.lent_temp = if (lends) arg else .nil;
        // A closure literal lives for the call, so the call's result may
        // not hold it.
        const kept = sema.holdsCallable(self.ctx, f.returns);
        self.lent_callable = if (kept) .nil else arg;
        self.callable_kept = if (kept) arg else .nil;
        try self.checkExpr(arg, f.params[i]);
    }

    /// Whether a call of `f` (with receiver parameter `recv`) may keep a
    /// borrow of an argument past the call: in its result, or through a
    /// write borrow into something that can hold one.
    fn callRetains(self: *Checker, f: FunctionType, recv: ?TypeId) bool {
        if (sema.mayHoldBorrow(self.ctx, f.returns)) return true;
        for (f.params) |p| if (self.storesBorrow(p)) return true;
        return if (recv) |r| self.storesBorrow(r) else false;
    }

    /// A write borrow into something that can hold a borrow.
    fn storesBorrow(self: *Checker, param: TypeId) bool {
        const inner = switch (self.ctx.types.get(param)) {
            .borrow_write => |inner| inner,
            else => return false,
        };
        const held = if (sema.writeSliceElem(self.ctx, param)) |elem| elem else inner;
        return sema.mayHoldBorrow(self.ctx, held);
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
            .not_constant => try self.errAt(a, "compile-time argument {d} of `{s}` must be an integer known at compile time: an integer, a constant, a compile-time parameter, or arithmetic on constants", .{ i + 1, callee }),
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
        if (ct) |b| try self.ctx.recordInstance(b, .function);
        // A compile-time parameter was rejected: the declaration's
        // diagnostic says what is wrong with every call.
        for (f.ct_params) |ty| if (self.isPoison(ty)) return null;
        const a = self.ctx.arena.allocator();
        const n = f.ct_params.len;
        // The parameters an instance binds: the type parameters and the
        // integer value parameters, at their slots.
        var own: std.ArrayListUnmanaged(SymbolId) = .empty;
        var own_slots: std.ArrayListUnmanaged(usize) = .empty;
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
            // `f [1, 2](...)` for `f[1, 2](...)`: the only argument is
            // an array, where the function takes none.
            if (f.params.len == skip and args.len == 1 and args[0].isKind(.array)) {
                const arg = try self.sourceText(args[0]);
                try self.err(pos, "compile-time arguments touch the name: `{s}{s}{s}`", .{ callee, arg, parens });
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
            return f;
        }
        if (ct == null) {
            const inferred = (try self.inferCallTypeArgs(f, own.items, args, info, skip, callee, pos)) orelse return null;
            for (own_slots.items, inferred) |i, ty| type_args[i] = ty;
        }
        const own_args = try a.alloc(TypeId, own.items.len);
        for (own_slots.items, own_args) |i, *arg| arg.* = type_args[i];
        const generic = try self.ctx.internCopy(.{ .function = f });
        const result = self.ctx.types.get(try sema.substituteType(self.ctx, generic, .{ .params = own.items, .args = own_args })).function;
        try self.ctx.recordGenericCall(self.current_call.?, .{ .type_args = type_args, .receiver_arg = receiver_arg });
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
    };

    /// A literal argument where a type parameter goes: it gives the
    /// parameter its default type (`Int`, `Float`) only when no other
    /// argument gives it a type.
    const LiteralBound = struct { param: usize, ty: TypeId, arg: u32 };

    const Inference = struct {
        own: []const SymbolId,
        bound: []Bound,
        literals: std.ArrayListUnmanaged(LiteralBound) = .empty,
        /// The first argument whose type does not have the shape of the
        /// type it fills (`?[3]Int` where `[]T` goes).
        mismatch: ?struct { arg: u32, pattern: TypeId, actual: TypeId } = null,
        /// The type expected of the result does not have the declared
        /// result's shape.
        result_mismatch: bool = false,
        /// An argument's type or the expected type holds poison: a
        /// diagnostic about it explains a parameter left unbound.
        poisoned: bool = false,
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
        var lambdas: std.ArrayListUnmanaged(LambdaArg) = .empty;
        var positional: usize = 0;
        for (args, 1..) |arg, number| {
            var value = arg;
            var pattern: ?TypeId = null;
            if (arg.isKind(.kwarg)) {
                value = ir.Kwarg.value(arg);
                const kname = self.text(ir.Kwarg.name(arg));
                pattern = switch (from) {
                    .fields, .payload => |fs| if (findDataField(fs, kname)) |f| f.ty else null,
                    .params => |p| blk: {
                        const names = p.names orelse break :blk null;
                        for (names, 0..) |name, i| {
                            if (std.mem.eql(u8, name, kname) and i < p.params.len) break :blk p.params[i];
                        }
                        break :blk null;
                    },
                };
            } else {
                // A struct's fields are set only by name; a variant's one
                // field may be given positionally.
                defer positional += 1;
                pattern = switch (from) {
                    .fields => null,
                    .payload => |fs| if (positional == 0 and args.len == 1) if (soleField(fs)) |f| f.ty else null else null,
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
        // A literal whose parameters are known binds what its result
        // gives, which may type another literal's parameters: repeat
        // until no literal is left or none makes progress.
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
        return inf;
    }

    /// A closure literal argument of a generic call, and the function
    /// type its parameter gives it.
    const LambdaArg = struct { pattern: TypeId, lambda: Sexp, arg: u32 };

    /// The function type a closure literal passed where parameter type
    /// `pat` goes is checked against: `pat` itself, or the callable a
    /// `?fun(...)` borrows.
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
        var params: std.ArrayListUnmanaged(SymbolId) = .empty;
        var types: std.ArrayListUnmanaged(TypeId) = .empty;
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
        const ty = try self.checkLambdaGiven(lambda, null, given, false);
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
        if (e != .list or e.list.id == 0) return self.synthQuiet(e);
        if (self.arg_types.get(e.list.id)) |ty| return ty;
        var ty = try self.synthQuiet(e);
        if (self.literalResult(e)) |lit| ty = lit;
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
                        try std.fmt.allocPrint(self.ctx.arena.allocator(), "give it in brackets: `{s}[{s}]{s}`", .{ callee, brackets, parens })
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
            try self.err(pos, "`{s}` cannot take a borrowed callable for `{s}`: a `{s}` is only a parameter's, a local's, or a result's type, and no value holds one", .{ callee, pname, try self.tyName(ty) });
            return true;
        }
        if (sema.holdsBorrow(self.ctx, ty)) return false;
        try self.err(pos, "`{s}` cannot take a lent closure for `{s}`: a closure is lent (`?f`) only to a parameter declared `?fun(...)` or `?sub(...)`", .{ callee, pname });
        return true;
    }

    /// Whether the value inference gave value parameter `param` (when it
    /// is one) is one it takes: a value its type holds, or a compile-time
    /// parameter of the same type. Reports one that is not.
    fn valueBindingFits(self: *Checker, param: SymbolId, b: Bound, callee: []const u8, pos: u32) Error!bool {
        const p = self.ctx.symbols.items[param];
        if (p.kind != .param or self.isPoison(p.ty)) return true;
        const from = if (b.expected) "the type expected of the result" else try std.fmt.allocPrint(self.ctx.arena.allocator(), "argument {d}", .{b.arg});
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
        const i = std.mem.indexOfScalar(SymbolId, own, tv) orelse return;
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
        const took = try std.fmt.allocPrint(a, "`{s}` takes `{s} = {s}` from argument {d}", .{ callee, self.ctx.symbols.items[tv].name, try self.tyName(b.ty), b.arg });
        if (sema.isNumeric(self.ctx, b.ty) and sema.isNumeric(self.ctx, b.wanted)) {
            try self.result_hints.put(self.ctx.allocator, id, try std.fmt.allocPrint(a, "{s}; convert its result with `{s}(...)`", .{ took, try self.tyName(b.wanted) }));
            return;
        }
        // Brackets pass the type on to an argument that takes it from
        // where it goes, such as a nested generic call.
        const types = try a.alloc(TypeId, inf.bound.len);
        for (inf.bound, types) |bound, *ty| ty.* = bound.ty;
        const brackets = (try self.bracketHint(types, i, b.wanted)) orelse return self.result_hints.put(self.ctx.allocator, id, took);
        try self.result_hints.put(self.ctx.allocator, id, try std.fmt.allocPrint(a, "{s}; to pass `{s}` on to it, give it in brackets: `{s}[{s}](...)`", .{ took, try self.tyName(b.wanted), callee, brackets }));
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
        var buf: std.ArrayListUnmanaged(u8) = .empty;
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
        if (try self.bracketHint(types, index, null)) |brackets| return std.fmt.allocPrint(a, "give `{s}` in brackets: `{s}[{s}]{s}`", .{ pname, callee, brackets, parens });
        // The result with each known type argument in place.
        const args = try a.alloc(TypeId, own.len);
        for (own, types, args) |p, ty, *arg| arg.* = if (ty == sema.type_invalid) try self.ctx.intern(.{ .type_var = p }) else ty;
        const shown = try sema.substituteType(self.ctx, f.returns, .{ .params = own, .args = args });
        const holds = (try sema.substituteType(self.ctx, f.returns, .{ .params = own[index .. index + 1], .args = &.{self.t().void_id} })) != f.returns;
        if (holds) return std.fmt.allocPrint(a, "give the type where the value goes: `x: {s} = {s}{s}`, with a type in place of `{s}`", .{ try self.tyName(shown), callee, parens, pname });
        return std.fmt.allocPrint(a, "give `{s}` in brackets, naming each array, slice, or function type in them with a `type` alias", .{pname});
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
                const i = std.mem.indexOfScalar(SymbolId, inf.own, tv) orelse return;
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
                if (b.ty == sema.type_invalid) {
                    b.ty = value;
                    b.arg = arg;
                } else if (b.ty != value and b.conflict == sema.type_invalid) {
                    b.conflict = value;
                    b.conflict_arg = arg;
                }
            },
            // A value where a `T?` goes is lifted; a value where a borrow
            // goes is matched as its borrow would be.
            .optional => |p| try self.bindArg(inf, p, if (at == .optional) at.optional else actual, arg, depth + 1),
            .borrow_read, .borrow_write => |p| try self.bindArg(inf, p, switch (at) {
                .borrow_read, .borrow_write => |inner| inner,
                else => actual,
            }, arg, depth + 1),
            .fallible => |p| if (at == .fallible) try self.bindArg(inf, p, at.fallible, arg, depth + 1) else self.noteMismatch(inf, pattern, actual, arg),
            .shared => |p| if (at == .shared) try self.bindArg(inf, p, at.shared, arg, depth + 1) else self.noteMismatch(inf, pattern, actual, arg),
            .weak => |p| if (at == .weak) try self.bindArg(inf, p, at.weak, arg, depth + 1) else self.noteMismatch(inf, pattern, actual, arg),
            // A `![]T` goes where a `[]T` does.
            .slice => |p| if (at == .slice)
                try self.bindArg(inf, p.elem, at.slice.elem, arg, depth + 1)
            else if (sema.writeSliceElem(self.ctx, actual)) |elem|
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else if (arrayElem(self.ctx, actual)) |elem|
                // An array lent as a slice (`?a`, a temporary).
                try self.bindArg(inf, p.elem, elem, arg, depth + 1)
            else
                self.noteMismatch(inf, pattern, actual, arg),
            .array => |p| if (at == .array) {
                try self.bindArg(inf, p.elem, at.array.elem, arg, depth + 1);
                try self.bindArg(inf, p.len, at.array.len, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            // A value parameter binds exactly the value (or parameter)
            // the argument's type holds there: an array length, or a
            // generic type's value argument.
            .ct_param => |p| {
                const i = std.mem.indexOfScalar(SymbolId, inf.own, p) orelse return;
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
            .parameterized_nominal => |pn| if (at == .parameterized_nominal and at.parameterized_nominal.sym == pn.sym) {
                for (pn.args, at.parameterized_nominal.args) |pa, aa| try self.bindArg(inf, pa, aa, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            // What a borrowed callable lends: a closure's, a function's,
            // or an owned closure's function type.
            .callable => |pf| switch (at) {
                .callable, .shared => |inner| try self.bindArg(inf, pf, inner, arg, depth + 1),
                .function => try self.bindArg(inf, pf, actual, arg, depth + 1),
                else => self.noteMismatch(inf, pattern, actual, arg),
            },
            .function => |pf| if (at == .function and at.function.params.len == pf.params.len) {
                for (pf.params, at.function.params) |pp, ap| try self.bindArg(inf, pp, ap, arg, depth + 1);
                try self.bindArg(inf, pf.returns, at.function.returns, arg, depth + 1);
            } else self.noteMismatch(inf, pattern, actual, arg),
            else => {},
        }
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
                    .not => self.isComptimeKnown(ir.get(e, .operand)),
                    .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or" => self.isComptimeKnown(ir.get(e, .left)) and self.isComptimeKnown(ir.get(e, .right)),
                    // Rig checks arithmetic only on constants: a compile-time
                    // parameter or a `=!` binding of one differs per call.
                    .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"&", .@"|", .@"^" => self.constInt(e) != null or (self.isCtArithmetic(e) and !self.mentionsCtLocal(e)),
                    .member => blk: {
                        const obj = ir.Member.object(e);
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

    /// The symbol `module.name` names in an imported module.
    fn foreignMember(self: *Checker, e: Sexp) ?sema.Symbol {
        const m = ir.Member.object(e);
        if (m != .src) return null;
        const id = self.lookupQuiet(m) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        const origin = self.ctx.module_refs.get(id) orelse return null;
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        const member = foreign.lookupInScopeOnly(sema.module_scope, self.text(ir.Member.name(e))) orelse return null;
        return foreign.symbols.items[member];
    }

    /// Arithmetic whose operands are each known at compile time.
    fn isCtArithmetic(self: *Checker, e: Sexp) bool {
        const h = e.kind() orelse return false;
        return switch (h) {
            .neg => self.isComptimeKnown(ir.Neg.operand(e)) or self.isCtArithmetic(ir.Neg.operand(e)),
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"&", .@"|", .@"^" => for ([_]Sexp{ ir.get(e, .left), ir.get(e, .right) }) |o| {
                if (!self.isComptimeKnown(o) and !self.isCtArithmetic(o)) break false;
            } else true,
            else => false,
        };
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
        const origin = if (sema.isProxy(sym)) sema.proxyOrigin(self.ctx, sym) else null;
        try self.checkFieldArgs(args, fields, .{
            .owner = sym.name,
            .decl_pos = if (origin) |o| o.pos else sym.decl_pos,
            .module_id = if (origin) |o| o.module_id else 0,
            .pos = pos,
            .subst = subst,
            .foreign = foreign,
            .kind = .constructor,
        });
        return result;
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
    };

    /// Keyword arguments against named fields: each names a real field
    /// once, and every field without a default is given. A variant with
    /// one field also takes it positionally: `.some(7)`.
    fn checkFieldArgs(self: *Checker, args: []const Sexp, fields: []const Field, info: FieldArgs) Error!void {
        const noun = if (info.kind == .constructor) "constructor of" else "variant";
        if (info.kind == .variant and args.len == 1 and !args[0].isKind(.kwarg)) {
            if (soleField(fields)) |f| return self.checkExpr(args[0], try self.fieldType(f, info));
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
            } else {
                try self.err(info.pos, "fields of `{s}` are set by name: `{s}(field: value)`", .{ info.owner, info.owner });
            }
            try self.synthArgs(args);
            return;
        }
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        defer seen.deinit(self.ctx.allocator);
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
            const f = findDataField(fields, fname) orelse {
                try self.err(fpos, "no field `{s}` on {s} `{s}`", .{ fname, if (info.kind == .constructor) "type" else "variant", info.owner });
                if (info.foreign == null and info.decl_pos < sema.imported_decl_pos and info.decl_pos != 0) try self.ctx.noteIn(info.module_id, info.decl_pos, "`{s}` declared here", .{info.owner});
                _ = try self.synthExpr(value);
                continue;
            };
            try self.checkExpr(value, try self.fieldType(f, info));
        }
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.default != null or seen.contains(f.name)) continue;
            try self.err(info.pos, "{s} `{s}` is missing field `{s}`", .{ noun, info.owner, f.name });
            if (info.foreign == null and f.decl_pos < sema.imported_decl_pos) try self.ctx.noteIn(info.module_id, f.decl_pos, "field `{s}` declared here", .{f.name});
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

    /// A call whose callee is `(member obj name)`. The callee node's type
    /// is recorded too: the resolved method's signature.
    /// `obj.name(args)`; `ct` is the bracket list of `obj.name[...](args)`,
    /// compile-time arguments for a method, or the index of an element of
    /// a field holding functions.
    fn synthMemberCall(self: *Checker, callee: Sexp, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const saved = self.callee_node;
        self.callee_node = callee;
        defer self.callee_node = saved;
        var obj = ir.Member.object(callee);
        const name_node = ir.Member.name(callee);
        const method = self.text(name_node);
        const pos = srcPos(name_node, self.startOf(obj));

        // `<Point.origin()`: a function called through its type or module
        // has no receiver for the sigil to apply to.
        if (self.isReceiverSigil(obj)) {
            const place = ir.get(obj, .operand);
            if ((try self.moduleNamed(place)) != null or (try self.namedType(place)) != null) {
                try self.misplacedSigil(obj, method, "is called through its type or module and has no receiver");
                obj = place;
            }
        }
        if (try self.moduleNamed(obj)) |id| return self.crossModuleCall(id, method, pos, args, ct);
        if (try self.namedType(obj)) |nt| return self.associatedCall(obj, nt, method, pos, args, ct);

        // A consuming (`<self`) method may take a temporary; any
        // other receiver must already have an owner.
        const obj_ty = try self.synthExpr(obj);
        if (self.isPoison(obj_ty)) {
            try self.synthArgs(args);
            return obj_ty;
        }

        if (try self.elemsCall(callee, obj, obj_ty, method, pos, args, ct)) |ty| return ty;
        const resolved_method = try self.findMethod(obj_ty, method);
        // `x.f[i](args)` where `f` is a field: its element is called.
        if (ct != null and resolved_method == null) {
            const field_ty = try self.memberOf(callee, obj, obj_ty);
            try self.ctx.recordType(callee, field_ty);
            const elem_ty = try self.indexInto(ct.?, field_ty);
            try self.ctx.recordType(ct.?, elem_ty);
            if (self.isReceiverSigil(obj)) {
                try self.fieldCallSigil(obj, method, "a field holding functions", elem_ty);
            } else try self.rejectResourceTemporary(obj, obj_ty);
            return self.callValue(ct.?, elem_ty, args, try self.sourceText(ct.?));
        }

        if (std.mem.eql(u8, method, "upgrade")) {
            switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, obj_ty))) {
                .weak => |inner| {
                    if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "only reads the weak handle");
                    try self.rejectResourceTemporary(obj, obj_ty);
                    if (args.len != 0) {
                        try self.err(pos, "weak `upgrade` takes no arguments; got {d}", .{args.len});
                        try self.synthArgs(args);
                    }
                    const result = try self.ctx.intern(.{ .optional = try self.ctx.intern(.{ .shared = inner }) });
                    try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{obj_ty}), .returns = result, .is_sub = false });
                    return result;
                },
                .shared => if (!sema.hasMethodNamed(self.ctx, obj_ty, method)) {
                    return self.badCall(args, pos, "`upgrade` is only available on weak handles (`~T`); receiver here is a shared handle (`*T`). Use `~rc` to obtain a weak reference, then `.upgrade()` on the weak.", .{});
                },
                else => {},
            }
        }

        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .optional => return self.badCall(args, pos, "cannot call `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ method, try self.tyName(peeled) }),
            .type_var => return self.badCall(args, pos, "a generic parameter `{s}` has no methods; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) }),
            else => {},
        }

        if (cellVecElement(self.ctx, obj_ty)) |elem| if (try self.cellVecCall(obj, obj_ty, elem, method, pos, args)) |ty| {
            if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "changes a Cell through any path to it");
            return ty;
        };

        const resolved = resolved_method orelse {
            // A data field holding a function or a closure handle is
            // called like one.
            if (try self.dataField(obj_ty, method)) |ty| {
                if (sema.ownedClosureFn(self.ctx, ty) != null or self.ctx.types.get(ty) == .function) {
                    if (self.isReceiverSigil(obj)) {
                        try self.fieldCallSigil(obj, method, "a field holding a function", ty);
                    } else try self.rejectResourceTemporary(obj, obj_ty);
                    try self.noteCalleeType(ty);
                    return self.callValue(callee, ty, args, method);
                }
            }
            if (vecElementType(self.ctx, peeled) != null and std.mem.eql(u8, method, "length")) {
                try self.err(pos, "a Vec has no `length()`; its length is `.len`, as for an array: `v.len`", .{});
            } else if (sema.nominalDecl(self.ctx, peeled)) |decl| {
                const sym = decl.symbol();
                try self.err(pos, "no method `{s}` on type `{s}`", .{ method, sym.name });
                try self.noteDeclared(sym, decl.module_id == null);
            } else {
                try self.err(pos, "type `{s}` has no method `{s}`", .{ try self.tyName(obj_ty), method });
            }
            return self.skipCall(args);
        };
        const receiver = resolved.field.receiver;
        try self.noteCallee(resolved.fn_ty);
        const misplaced_sigil = receiver != .none and try self.checkReceiverSigil(obj, receiver, resolved.fn_ty.returns, method);
        if (receiver != .value and !misplaced_sigil) try self.rejectResourceTemporary(obj, obj_ty);

        // A `?self` method may change a Cell the value holds; a loop or
        // match binding is only a copy of it.
        if (resolved.nominal_sym != self.ctx.cell_sym_id and receiver == .read and sema.holdsCellByValue(self.ctx, obj_ty)) {
            if (self.copiedBindingRoot(obj)) |root| {
                try self.errAt(obj, "cannot call `{s}` here: the value holds a Cell the method may change, and `{s}` is a loop or match binding, a copy, so the change would be lost", .{ method, self.text(root) });
            } else if (!isPlaceExpr(obj)) {
                try self.errAt(obj, "cannot call `{s}` on a temporary that holds a Cell the method may change; bind it to a name first", .{method});
            }
        }
        if (resolved.nominal_sym == self.ctx.cell_sym_id) {
            const stores = std.mem.eql(u8, method, "set") or std.mem.eql(u8, method, "replace");
            if (stores and !self.cellSettable(obj)) {
                try self.err(pos, "`Cell.{s}` needs a Cell that has a place: a local binding, a field of one, or one reached through a borrow (`?T` or `!T`) or a shared handle (`*T`). A by-value parameter, a loop or match binding (a copy), or a temporary cannot be changed.", .{method});
                try self.synthArgs(args);
                return if (std.mem.eql(u8, method, "set")) self.t().void_id else resolved.fn_ty.returns;
            }
            if (std.mem.eql(u8, method, "get")) {
                if (cellElementType(self.ctx, obj_ty)) |elem| {
                    if ((try self.ownsResource(elem, pos, "copies out with `Cell.get` a value"))) return self.badCall(args, pos, "`Cell.get` returns `T` by value but `T = {s}` has drop glue; a copy would alias the cell's owned value. Use `cell.replace(<new)` to swap-and-yield the old value.", .{try self.tyName(elem)});
                }
            }
        }
        // `pop` removes the element, so it hands over ownership; `get`
        // would copy it out of the Vec.
        if (resolved.nominal_sym == self.ctx.vec_sym_id and std.mem.eql(u8, method, "get")) {
            if (resolved.fn_ty.returns != self.t().invalid_id) {
                const elem = self.ctx.types.get(resolved.fn_ty.returns).optional;
                if ((try self.ownsResource(elem, pos, "copies an element out of a Vec"))) return self.badCall(args, pos, "`Vec.{s}` would copy an owning handle out of a `Vec` of `{s}`; iterate with `for x in ?v` instead", .{ method, try self.tyName(elem) });
            }
        }

        if (receiver == .none) {
            try self.err(pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{ method, resolved.owner, method });
            try self.synthArgs(args);
            return resolved.fn_ty.returns;
        }
        if (!misplaced_sigil) try self.checkReceiverMode(obj, receiver, classifyReceiverType(self.ctx, obj_ty, resolved.nominal_sym), method, pos);
        const info = methodParams(resolved.field, true, resolved.source);
        const f = (try self.instantiateCall(resolved.fn_ty, ct, args, info, 1, method, pos, false, self.receiverArgs(obj_ty))) orelse return self.skipCall(args);
        if (sema.isGenericFn(self.ctx, resolved.fn_ty)) try self.noteCallee(f);
        const rest: FunctionType = .{
            .params = f.params[1..],
            .returns = f.returns,
            .is_sub = f.is_sub,
        };
        self.lend_call = true;
        self.lend_recv = f.params[0];
        try self.checkArgs(args, rest, info, method, pos);
        return f.returns;
    }

    /// `copy`, `fill`, and `swap`: built-in methods on the elements of a
    /// slice, an array, or a Vec, which write them in place; and `read`
    /// and `write` on bytes (`bytesCall`). Null when `method` is none of
    /// them or the receiver has no elements.
    fn elemsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
        const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        var len: ?u64 = null;
        const elem: TypeId = switch (self.ctx.types.get(peeled)) {
            .slice => |sl| sl.elem,
            .array => |a| blk: {
                len = sema.arrayLen(self.ctx, a);
                break :blk a.elem;
            },
            .string => try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            else => vecElementType(self.ctx, peeled) orelse return null,
        };
        if (obj.isKind(.move) and self.isReceiverSigil(obj)) {
            try self.misplacedSigil(obj, method, "does not consume its receiver");
            return try self.skipCall(args);
        }
        if (op == .read or op == .write) return try self.bytesCall(callee, obj, obj_ty, elem, len, op, pos, args, ct);
        if (ct) |b| return try self.badCall(args, b, "`{s}` takes no compile-time arguments", .{method});
        if (!try self.writesElements(obj, obj_ty, peeled, method)) return try self.skipCall(args);
        if (op != .swap and try self.ownsResource(elem, pos, "copies into the elements a value")) {
            return try self.badCall(args, pos, "`{s}` copies values into the elements; a `{s}` owns a resource", .{ method, try self.tyName(elem) });
        }
        // As in `[n of x]`: a copy of a value holding a borrow would
        // duplicate the borrow, and a write borrow has one holder.
        if (op != .swap and sema.holdsBorrow(self.ctx, elem)) {
            return try self.badCall(args, pos, "`{s}` copies {s}; `{s}` holds a borrow, and the elements must be plain data", .{ method, if (op == .fill) "its value into every element" else "its source into the elements", try self.tyName(elem) });
        }
        for (args) |a| if (a.isKind(.kwarg)) return try self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        const want: usize = if (op == .swap) 2 else 1;
        if (args.len != want) return try self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, switch (op) {
            .copy => "one argument, the `[]T` to copy from",
            .fill => "one argument, the value for every element",
            .swap => "two arguments, the indexes of the elements to swap",
            .read, .write => unreachable,
        }, args.len, if (args.len == 1) "" else "s" });
        const recv = try self.ctx.intern(.{ .borrow_write = peeled });
        const params: []const TypeId = switch (op) {
            .copy => &.{ recv, try self.ctx.intern(.{ .slice = .{ .elem = elem } }) },
            .fill => &.{ recv, elem },
            .swap => &.{ recv, self.t().int_id, self.t().int_id },
            .read, .write => unreachable,
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
            .read, .write => unreachable,
        }
        return self.t().void_id;
    }

    /// `bytes.read[T, e](at)` and `!bytes.write[T, e](at, v)`: the integer
    /// or float `T` held in the `@sizeOf(T)` bytes from `at`, in byte
    /// order `e`, a compile-time `Endian`. The bytes are a `[]U8`, an
    /// `![]U8`, a `[N]U8`, a `Vec[U8]`, or (for `read`) a String; `at` is
    /// checked now against an array's length when it is constant, and
    /// when the program runs otherwise.
    fn bytesCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, len: ?u64, op: sema.ElemOp, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const method = @tagName(op);
        const peeled = sema.unwrapBorrows(self.ctx, obj_ty);
        const byte = try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
        if (elem != byte) return self.badCall(args, obj, "`{s}` works on bytes: a `[]U8`, an `![]U8`, a `[N]U8`, a `Vec[U8]`, or a String; got `{s}`", .{ method, try self.tyName(obj_ty) });
        if (op == .write) {
            if (!try self.writesElements(obj, obj_ty, peeled, method)) return self.skipCall(args);
        } else if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "only reads its receiver");
        const example = if (op == .read) "read[U32, .little](at)" else "write[U32, .little](at, value)";
        const b = ct orelse return self.badCall(args, pos, "`{s}` takes the type and the byte order in brackets: `{s}`", .{ method, example });
        try self.ctx.recordInstance(b, .function);
        const given = sema.bracketArgs(b);
        if (given.len != 2) return self.badCall(args, b, "`{s}` takes two compile-time arguments, the type and the byte order: `{s}`", .{ method, example });
        const num = try self.typeArg(given[0]);
        if (self.isPoison(num)) return self.skipCall(args);
        switch (self.ctx.types.get(num)) {
            .int, .float => {},
            // A type parameter: each instance must be a number.
            .type_var => |param| try self.require(param, .bytes, self.startOf(given[0]), method),
            else => return self.badCall(args, given[0], "`{s}` {s} an integer or float type; got `{s}`", .{ method, if (op == .read) "reads" else "writes", try self.tyName(num) }),
        }
        const endian = try self.ctx.intern(.{ .nominal = self.ctx.endian_sym_id });
        try self.checkCtValue(given[1], endian, 1, method);
        for (args) |a| if (a.isKind(.kwarg)) return self.badCall(args, a, "`{s}` takes no keyword arguments", .{method});
        const want: usize = if (op == .read) 1 else 2;
        if (args.len != want) return self.badCall(args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, if (op == .read) "one argument, the offset of the first byte" else "two arguments, the offset of the first byte and the value", args.len, if (args.len == 1) "" else "s" });
        const recv = try self.ctx.intern(if (op == .read) Type{ .borrow_read = peeled } else Type{ .borrow_write = peeled });
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
        if (ty == self.t().int_literal_id) try self.checkLiteralFits(a, self.t().int_id);
        const at = self.constInt(a) orelse return;
        const size: i128 = switch (self.ctx.types.get(num)) {
            .int => |i| if (i.bits == 0) 8 else i.bits / 8,
            .float => |f| if (f.bits == 0) 8 else f.bits / 8,
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
        if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an index must be an integer; got `{s}`", .{try self.tyName(ty)});
        if (ty == self.t().int_literal_id) try self.checkLiteralFits(a, self.t().int_id);
        if (len) |n| if (self.constInt(a)) |i| if (i < 0 or i >= n) {
            try self.errAt(a, "index `{d}` is out of bounds for an array of length {d}", .{ i, n });
        };
    }

    /// The receiver of a method that writes the elements of `peeled` (a
    /// slice, an array, or a Vec): a `![]T`, or a place written `!xs`.
    /// False after a diagnostic.
    fn writesElements(self: *Checker, obj: Sexp, obj_ty: TypeId, peeled: TypeId, method: []const u8) Error!bool {
        switch (self.ctx.types.get(peeled)) {
            .string => {
                try self.errAt(obj, "cannot `{s}` a String; a String is read-only", .{method});
                return false;
            },
            .slice => if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
                try self.errAt(obj, "cannot `{s}` a `{s}`; its elements are read-only (a writable slice is a `![]T`)", .{ method, try self.tyName(obj_ty) });
                return false;
            },
            else => {},
        }
        // `!xs.fill(v)`: the write borrow took the checks.
        if (obj.isKind(.write)) return true;
        // A binding that holds a write borrow lends it as it is.
        if (self.ctx.types.get(obj_ty) == .borrow_write and !obj.isKind(.read)) return self.checkLendsWriteBorrow(obj);
        const place = if (obj.isKind(.read) or obj.isKind(.move)) ir.get(obj, .operand) else obj;
        // A receiver `!` could not write (through a `*T` or `?T`, or of
        // a parameter) is reported as such, not with a `!` to add.
        const mark = self.ctx.diagnostics.items.len;
        if (!try self.checkWritable(place, obj, "write-borrow") or self.ctx.diagnostics.items.len != mark) return false;
        const sp = self.ctx.span(place);
        try self.errAt(obj, "`{s}` writes the elements; write the receiver with `!`: `!{s}.{s}(...)`", .{ method, self.ctx.source[sp.start..sp.end], method });
        return false;
    }

    /// A `Cell[Vec[E]]` answers its Vec's `push`, `pop`, `clear`, and,
    /// for a plain-data `E`, `get(i)`, through any path to the cell, as
    /// `set` does. Null for the Cell's own members.
    fn cellVecCall(self: *Checker, obj: Sexp, obj_ty: TypeId, elem: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
        const Member = enum { push, pop, clear, get };
        const member = std.meta.stringToEnum(Member, method) orelse return null;
        if (member == .get and args.len == 0) return null;
        const recv = try self.ctx.intern(.{ .borrow_read = sema.unwrapReadAccess(self.ctx, obj_ty) });
        const opt_elem = try self.ctx.intern(.{ .optional = elem });
        const params: []const TypeId = switch (member) {
            .push => &.{ recv, elem },
            .pop, .clear => &.{recv},
            .get => &.{ recv, self.t().int_id },
        };
        const f: FunctionType = .{
            .params = try self.ctx.dupeIds(params),
            .returns = switch (member) {
                .push, .clear => self.t().void_id,
                .pop, .get => opt_elem,
            },
            .is_sub = member == .push or member == .clear,
        };
        try self.noteCallee(f);
        if (member == .get) {
            if (try self.ownsResource(elem, pos, "copies an element out of a Cell's Vec")) {
                _ = try self.badCall(args, pos, cell_vec_handle, .{try self.tyName(sema.unwrapReadAccess(self.ctx, obj_ty))});
                return f.returns;
            }
        } else if (!self.cellSettable(obj)) {
            try self.err(pos, "`Cell.{s}` needs a Cell that has a place: a local binding, a field of one, or one reached through a borrow (`?T` or `!T`) or a shared handle (`*T`). A by-value parameter, a loop or match binding (a copy), or a temporary cannot be changed.", .{method});
            try self.synthArgs(args);
            return f.returns;
        }
        try self.checkArgs(args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub }, .{}, method, pos);
        return f.returns;
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
        for (members) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (m.is_method and !m.is_drop_method) {
                const fty = self.ctx.types.get(try self.memberType(nt.foreign, m.ty));
                if (fty != .function) break;
                var f = fty.function;
                var recv: TypeSubst = .empty;
                if (generic) {
                    // The type's arguments are given (`Pair[Int, String].make`)
                    // or come from the call's arguments.
                    const subst = if (nt.args) |given| TypeSubst{ .params = nt.sym.type_params orelse &.{}, .args = given } else (try self.inferTypeArgs(nt.id, args, .{ .params = .{ .params = f.params, .names = m.param_names } }, pos, self.expectedResult(f.returns), name)) orelse return self.skipCall(args);
                    if (nt.args == null) try self.ctx.recordType(obj, try self.instantiate(nt.id, subst.args, pos));
                    f = self.ctx.types.get(try sema.substituteType(self.ctx, m.ty, subst)).function;
                    recv = subst;
                }
                const source = if (nt.foreign) |fo| fo.ctx.source else self.declSource(nt.id);
                const info = methodParams(m, false, source);
                f = (try self.instantiateCall(f, ct, args, info, 0, name, pos, m.receiver != .none, recv)) orelse return self.skipCall(args);
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, name, pos);
                return f.returns;
            }
            if (ct) |b| return self.badCall(args, b, "`{s}.{s}` is not a function; it takes no compile-time arguments", .{ tname, name });
            if (!m.is_variant) break;
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
            try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .module_id = nt.sym.from.module_id, .pos = pos, .subst = subst, .foreign = nt.foreign, .kind = .variant });
            return ty;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ name, tname });
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
        const took = try std.fmt.allocPrint(a, "`{s}.{s}` takes `{s} = {s}` from argument {d}", .{ sym.name, member, self.ctx.symbols.items[sym.type_params.?[i]].name, try self.tyName(b.ty), b.arg });
        const named = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = try self.ctx.dupeIds(types) } });
        const hint = if (spelledInBrackets(self.ctx, named)) try std.fmt.allocPrint(a, "{s}; to pass `{s}` on to it, name the type: `{s}.{s}(...)`", .{ took, try self.tyName(types[i]), try self.tyName(named), member }) else took;
        try self.result_hints.put(self.ctx.allocator, call.list.id, hint);
    }

    /// The instance of generic `sym_id` at `args`, checked like a spelled
    /// one: the built-in generics' element rules, and every generic's
    /// requirements (through its instantiation site).
    fn instantiate(self: *Checker, sym_id: SymbolId, args: []const TypeId, pos: u32) Error!TypeId {
        if (try resolve.builtinElementError(self.ctx, sym_id, args)) |msg| try self.err(pos, "{s}", .{msg});
        const ty = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = try self.ctx.dupeIds(args) } });
        if (!sema.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else {
            for (self.ctx.generic_uses.items) |u| {
                if (u == ty) break;
            } else try self.ctx.generic_uses.append(self.ctx.allocator, ty);
        }
        return ty;
    }

    /// `module.function(args)` or `module.Type(fields)`.
    fn crossModuleCall(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const found = (try self.foreignSymbol(module_sym, name, pos)) orelse return self.skipCall(args);
        const qualified = try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ module_name, name });
        switch (found.sym.kind) {
            .function, .@"extern" => {
                const local = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
                const fty = self.ctx.types.get(local);
                if (fty != .function) return self.badCall(args, pos, "`{s}` cannot be called", .{qualified});
                const info = paramsOf(found.sym, found.ctx.source);
                const f = (try self.instantiateCall(fty.function, ct, args, info, 0, qualified, pos, false, .empty)) orelse return self.skipCall(args);
                // A generic function's callee has the instance's signature.
                try self.noteCallee(f);
                self.lend_call = true;
                try self.checkArgs(args, f, info, qualified, pos);
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

    /// The loop or match binding a place is a part of, when the path to
    /// it stays inside that binding (a copy of the value it came from)
    /// rather than going through a borrow or handle.
    fn copiedBindingRoot(self: *Checker, place: Sexp) ?Sexp {
        const root = self.placePath(place).root orelse return null;
        const sym = self.ctx.symbols.items[self.ctx.symbolOf(root) orelse return null];
        if (!sym.flags.pattern_bound) return null;
        return switch (self.ctx.types.get(sym.ty)) {
            .borrow_read, .borrow_write => null,
            else => root,
        };
    }

    /// A Cell is interior-mutable: `set` and `replace` change it through
    /// any path that reaches its storage, including a read borrow or a
    /// shared handle. The storage is a local binding (or a field or
    /// element of one), a capture held by a closure environment, or
    /// anything behind a borrow or handle. A by-value parameter is
    /// immutable, and a loop or match binding is a copy, so changing it
    /// would not change the value it came from.
    /// The `c[i]` a place goes through, where `c` is a `Cell[Vec[E]]`:
    /// such an element is a copy, read or written whole.
    fn cellVecElementIn(self: *Checker, place: Sexp) ?Sexp {
        var p = place;
        while (p.kind()) |h| {
            if (h != .member and h != .index) return null;
            const obj = ir.get(p, .object);
            if (h == .index) if (self.ctx.typeOf(obj)) |ty| if (cellVecElement(self.ctx, ty) != null) return p;
            p = obj;
        }
        return null;
    }

    fn cellSettable(self: *Checker, recv: Sexp) bool {
        var p = recv;
        while (p.isKind(.read) or p.isKind(.write)) p = ir.get(p, .operand);
        if (self.ctx.typeOf(p)) |ty| switch (self.ctx.types.get(ty)) {
            .borrow_read, .borrow_write, .shared => return true,
            else => {},
        };
        const path = self.placePath(p);
        if (path.indirect) return true;
        const sym = self.ctx.symbols.items[self.ctx.symbolOf(path.root orelse return false) orelse return false];
        return switch (sym.kind) {
            .local => !sym.flags.pattern_bound,
            .capture => true,
            else => false,
        };
    }

    /// Whether `node` is the `!p` or `<p` of `!p.m(...)` or `<p.m(...)`,
    /// written before the call rather than in parentheses.
    fn isReceiverSigil(self: *Checker, node: Sexp) bool {
        const p = self.ctx.parser orelse return false;
        return p.isReceiverSigil(node);
    }

    /// `!p.m(...)` or `<p.m(...)` where `m` takes no receiver the sigil
    /// could apply to.
    fn misplacedSigil(self: *Checker, recv: Sexp, method: []const u8, why: []const u8) Error!void {
        try self.errAt(recv, "`{s}` {s}; drop the `{s}`", .{ method, why, if (recv.isKind(.write)) "!" else "<" });
    }

    /// `!p.f(...)` or `<p.f[i](...)`, where `f` is a field holding
    /// functions: there is no receiver for the sigil. A `!` before a call
    /// whose value is a `Bool` was meant as negation.
    fn fieldCallSigil(self: *Checker, recv: Sexp, field: []const u8, what: []const u8, fn_ty: TypeId) Error!void {
        const returns: ?TypeId = if (sema.ownedClosureFn(self.ctx, fn_ty)) |f| f.returns else switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, fn_ty))) {
            .function => |f| f.returns,
            else => null,
        };
        if (recv.isKind(.write) and returns == self.t().bool_id) {
            return self.errAt(recv, "`{s}` is {s}, not a method with a receiver; for negation use `not`", .{ field, what });
        }
        try self.errAt(recv, "`{s}` is {s}, not a method with a receiver; drop the `{s}`", .{ field, what, if (recv.isKind(.write)) "!" else "<" });
    }

    /// `!p.m(...)` and `<p.m(...)` (see `Parser.receiverSigil`): the sigil
    /// is the receiver mode of `m`, so a `!` before a method that only
    /// reads is the habit of `!` as negation, and a `!` call whose value
    /// is a `Bool` is written `(!p).m(...)` so it never reads as one.
    /// Returns whether it reported an error.
    fn checkReceiverSigil(self: *Checker, recv: Sexp, mode: MethodReceiver, returns: TypeId, method: []const u8) Error!bool {
        if (!self.isReceiverSigil(recv)) return false;
        const place = ir.get(recv, .operand);
        const at = self.ctx.span(place);
        const name = self.ctx.source[at.start..at.end];
        if (recv.isKind(.write)) switch (mode) {
            .write => {
                const result = self.ctx.types.get(returns);
                const value = if (result == .fallible) result.fallible else returns;
                if (value != self.t().bool_id) return false;
                try self.errAt(recv, "a write-borrowing call that returns `Bool` is written `(!{s}).{s}(...)`, so it is never read as negation", .{ name, method });
            },
            else => try self.errAt(recv, "`{s}` does not write its receiver; for negation use `not`", .{method}),
        } else switch (mode) {
            .value => return false,
            .write => try self.errAt(recv, "`{s}` does not consume its receiver; it writes it: `!{s}.{s}(...)`, and its result needs no `<`", .{ method, name, method }),
            else => try self.errAt(recv, "`{s}` does not consume its receiver; drop the `<`: a call's result moves without it", .{method}),
        }
        return true;
    }

    /// Receiver rules: `?self` auto-borrows; `!self` needs an explicit
    /// `!x.m()`; a consuming `self` needs an explicit `<x.m()`. Write and
    /// consuming receivers are refused through `?T` and `*T`.
    fn checkReceiverMode(self: *Checker, recv: Sexp, mode: MethodReceiver, kind: ReceiverTypeKind, method: []const u8, pos: u32) Error!void {
        const shape = classifyReceiverShape(recv);
        switch (mode) {
            .read => if (shape == .move_explicit) {
                try self.err(pos, "method `{s}` takes a read borrow of receiver; cannot move", .{method});
            },
            .write => {
                if (kind == .read_borrow) return self.err(pos, "method `{s}` requires a write-borrowed receiver; cannot upgrade a read borrow to a write borrow", .{method});
                if (kind == .shared) return self.err(pos, "cannot call write-receiver method `{s}` through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell[T]` for mutation through shared ownership.", .{method});
                switch (shape) {
                    .write_explicit => {},
                    .rvalue => if (kind != .owned_nominal and kind != .write_borrow and kind != .other) {
                        try self.err(pos, "method `{s}` requires a write-borrowed receiver; this expression yields a borrowed value, not an owned one", .{method});
                    },
                    .read_explicit => try self.err(pos, "method `{s}` requires a write-borrowed receiver; got `?...`; use `!receiver.{s}(...)`", .{ method, method }),
                    .move_explicit => try self.err(pos, "method `{s}` requires a write-borrowed receiver; cannot move; use `!receiver.{s}(...)`", .{ method, method }),
                    // A binding that already holds a write borrow (`x: !T`,
                    // `!self`) lends it to the call as it is.
                    .lvalue_bare => if (kind != .write_borrow) {
                        try self.err(pos, "method `{s}` requires a write-borrowed receiver; use `!receiver.{s}(...)`", .{ method, method });
                    } else {
                        _ = try self.checkLendsWriteBorrow(recv);
                    },
                }
            },
            .value => {
                switch (kind) {
                    .read_borrow, .write_borrow => return self.err(pos, "method `{s}` consumes the receiver; cannot consume through a borrowed value", .{method}),
                    .shared => return self.err(pos, "method `{s}` consumes the receiver; cannot consume the inner value through a shared handle (`*T`) — other handles may still reference it", .{method}),
                    else => {},
                }
                switch (shape) {
                    .move_explicit, .rvalue => {},
                    .read_explicit, .write_explicit => try self.err(pos, "method `{s}` consumes the receiver; borrow forms not allowed; use `<receiver.{s}(...)`", .{ method, method }),
                    .lvalue_bare => try self.err(pos, "method `{s}` consumes the receiver; use `<receiver.{s}(...)`", .{ method, method }),
                }
            },
            .none => {},
        }
    }

    // =========================================================================
    // Expressions: checking against an expected type
    // =========================================================================

    fn checkExpr(self: *Checker, e: Sexp, expected: TypeId) Error!void {
        const prev_lent = self.lent_write;
        defer self.lent_write = prev_lent;
        if (e.isKind(.write) and self.ctx.types.get(expected) == .borrow_write) self.lent_write = e;
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
        if (try self.checkContextual(e, expected)) |ty| return self.ctx.recordType(e, ty);

        const actual = try self.synthExpr(e);
        if (try self.arrayAsSlice(e, actual, expected)) return;
        if (sema.callableFn(self.ctx, expected) != null and try self.lendCallable(e, actual, expected)) return;
        if (self.ctx.types.get(expected) == .function and sema.callableFnTy(self.ctx, actual) == expected) {
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; a lent closure goes to a parameter declared `{s}`", .{ try self.tyName(expected), try self.tyName(actual), try self.tyName(actual) });
        }
        if (compatible(self.ctx, actual, expected)) {
            try self.recordAdapted(e, actual, expected);
            if (sema.writeSliceElem(self.ctx, actual) != null and self.ctx.types.get(expected) == .slice) try self.ctx.recordReadView(e);
            if (sema.holdsWriteBorrow(self.ctx, expected)) _ = try self.checkLendsWriteBorrow(e);
            return;
        }
        // A fallible call where its value is expected: `synthCall`
        // reported the missing `!` / `catch`.
        const at = self.ctx.types.get(actual);
        if (at == .fallible and compatible(self.ctx, at.fallible, expected)) return;
        if (resultCall(e)) |call| if (call.list.id != 0) if (self.result_hints.get(call.list.id)) |hint| {
            return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; {s}", .{ try self.tyName(expected), try self.tyName(actual), hint });
        };
        // Only a number, `Bool`, `String`, or plain enum reads as the
        // value a borrow reaches (`readValue`).
        switch (at) {
            .borrow_read, .borrow_write => |inner| if (compatible(self.ctx, inner, expected)) {
                const name = try self.tyName(inner);
                return self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; only a number, `Bool`, `String`, or plain enum is copied out of a borrow: take the borrow where it goes (`?{s}` or `!{s}`)", .{ try self.tyName(expected), try self.tyName(actual), name, name });
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
        try self.checkExpr(e, try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } }));
        try self.ctx.recordArrayView(e, .temporary);
        return true;
    }

    /// An array where a slice is expected: `?a` as `?a[..]` where a `[]T`
    /// is, `!a` as `!a[..]` where a `![]T` is, and a temporary array as
    /// a `[]T` argument of a call that keeps no borrow of it. A bare
    /// named array is rejected with the borrow to write. True when
    /// handled.
    fn arrayAsSlice(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const want_write = sema.writeSliceElem(self.ctx, expected) != null;
        const elem = sema.writeSliceElem(self.ctx, expected) orelse switch (self.ctx.types.get(expected)) {
            .slice => |sl| sl.elem,
            else => return false,
        };
        const arr_of = struct {
            fn f(ctx: *const SemContext, ty: TypeId, want: TypeId) bool {
                return switch (ctx.types.get(ty)) {
                    .array => |a| a.elem == want,
                    else => false,
                };
            }
        }.f;
        switch (self.ctx.types.get(actual)) {
            .borrow_read => |inner| if (!want_write and e.isKind(.read) and isStoragePath(ir.Read.operand(e)) and arr_of(self.ctx, inner, elem)) {
                try self.ctx.recordType(e, expected);
                try self.ctx.recordArrayView(e, .borrowed);
                return true;
            },
            .borrow_write => |inner| if (want_write and e.isKind(.write) and isStoragePath(ir.Write.operand(e)) and arr_of(self.ctx, inner, elem)) {
                try self.ctx.recordType(e, expected);
                try self.ctx.recordArrayView(e, .borrowed);
                return true;
            },
            .array => |a| if (a.elem == elem) {
                if (isPlaceExpr(e)) {
                    const sp = self.ctx.span(e);
                    const shown = self.ctx.source[sp.start..sp.end];
                    const sigil: u8 = if (want_write) '!' else '?';
                    try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`; write `{c}{s}` or `{c}{s}[..]`", .{ try self.tyName(expected), try self.tyName(actual), sigil, shown, sigil, shown });
                    return true;
                }
                if (!want_write and sameNode(e, self.lent_temp)) {
                    try self.ctx.recordArrayView(e, .temporary);
                    return true;
                }
                if (!want_write) {
                    try self.errAt(e, "a temporary array is lent as a `{s}` only to a call that keeps no borrow of it; bind it to a name and pass `?name`", .{try self.tyName(expected)});
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn mismatch(self: *Checker, e: Sexp, expected: TypeId, actual: TypeId) Error!void {
        try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(actual) });
    }

    /// A form whose type comes from context: its type, or null when `e`
    /// is not one.
    fn checkContextual(self: *Checker, e: Sexp, expected: TypeId) Error!?TypeId {
        const target = self.liftTarget(expected);
        switch (e) {
            .src => {
                const s = self.text(e);
                if (std.mem.eql(u8, s, "none")) return try self.checkNone(e, expected);
                if (!sema.isIntLiteralText(s) or !sema.isInteger(self.ctx, target)) return null;
                try self.checkLiteralFits(e, target);
                return target;
            },
            .list => {},
            else => return null,
        }
        const head = e.kind() orelse return null;
        switch (head) {
            .neg => {
                const operand = ir.Neg.operand(e);
                if (operand != .src or !sema.isIntLiteralText(self.text(operand)) or !sema.isInteger(self.ctx, target)) return null;
                try self.checkLiteralFits(e, target);
                try self.ctx.recordType(operand, target);
                return target;
            },
            .enum_lit => {
                // Where a `T!` is expected, `.name` that is not a variant
                // of `T` is an error value.
                const name = ir.EnumLit.name(e);
                if (self.ctx.types.get(expected) == .fallible and
                    (try sema.lookupVariant(self.ctx, target, self.text(name))) == null and
                    sema.errorNameExists(self.ctx, self.text(name)))
                {
                    return self.t().any_error_id;
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
                } else if (id == self.ctx.vec_sym_id) {
                    try self.checkVecConstruction(e);
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
                    const ty = try self.checkLambda(e, target, false);
                    if (!sameNode(e, self.lent_callable) and !sameNode(e, self.callable_kept)) return ty;
                    // Reported here; the closure is not checked as escaping.
                    try self.errAt(e, "a closure literal is not a function value `{s}`; declare the parameter `?{s}` to lend the closure to the call", .{ try self.tyName(target), try self.tyName(target) });
                    return self.t().invalid_id;
                }
                if (sema.callableFn(self.ctx, target) != null) return try self.lentLambda(e, target);
                const fn_ty = self.ownedClosureType(target) orelse return null;
                try self.errAt(e, "`{s}` is an owned closure; write `*|...| body` to make one", .{try self.tyName(target)});
                _ = try self.checkLambda(e, fn_ty, false);
                return self.t().invalid_id;
            },
            .share => {
                const operand = ir.Share.operand(e);
                if (operand.isKind(.lambda) and sema.callableFn(self.ctx, target) != null) {
                    try self.errAt(e, "`{s}` borrows a closure for the call; write the closure without `*` (drop the `*`)", .{try self.tyName(target)});
                    _ = try self.checkLambda(operand, sema.callableFnTy(self.ctx, target).?, false);
                    return target;
                }
                if (operand.isKind(.lambda)) {
                    const ty = try self.ownedClosure(operand, self.ownedClosureType(target));
                    if (!compatible(self.ctx, ty, expected)) try self.mismatch(e, expected, ty);
                    return ty;
                }
                const tt = self.ctx.types.get(target);
                if (tt != .shared) return null;
                _ = try self.shareOperand(operand, tt.shared);
                return target;
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
                if (!compatible(self.ctx, ty, expected)) try self.mismatch(e, expected, ty);
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
    /// context gives: a borrow of a Copy value is read through
    /// (`recordRead`), and a literal takes a concrete type.
    fn recordAdapted(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        if (readValue(self.ctx, actual) != actual and !isBorrow(self.ctx, self.liftTarget(expected))) return self.ctx.recordRead(e);
        if (actual != self.t().int_literal_id and actual != self.t().float_literal_id) return;
        const target = self.liftTarget(expected);
        if (!sema.isNumeric(self.ctx, target)) return;
        try self.ctx.recordType(e, target);
        if (actual == self.t().int_literal_id) try self.checkLiteralFits(e, target);
        try self.checkFloatConstant(e, target);
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
                    const v = std.fmt.parseInt(i128, s, 0) catch return;
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
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"&", .@"|", .@"^" => {
                    try self.checkLiteralFits(ir.get(e, .left), target);
                    try self.checkLiteralFits(ir.get(e, .right), target);
                },
                .@"<<", .@">>" => try self.checkLiteralFits(ir.get(e, .left), target),
                .neg => try self.checkLiteralFits(ir.Neg.operand(e), target),
                .@"if" => {
                    try self.checkLiteralFits(ir.If.then(e), target);
                    try self.checkLiteralFits(ir.If.@"else"(e), target);
                },
                else => {},
            },
        }
    }

    /// `.name` where any error is expected: a member of some error set.
    fn checkErrorName(self: *Checker, name_node: Sexp) Error!void {
        const name = self.text(name_node);
        if (sema.errorNameExists(self.ctx, name)) return;
        try self.errAt(name_node, "no error set has a member `{s}`", .{name});
    }

    fn checkEnumLit(self: *Checker, name_node: Sexp, expected: TypeId) Error!void {
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        if (self.isPoison(expected)) return;
        if (expected == self.t().any_error_id) return self.checkErrorName(name_node);
        if (try sema.lookupVariant(self.ctx, expected, name)) |v| {
            if (v.payload.len > 0) {
                try self.err(pos, "variant `{s}` carries a payload; construct it with `.{s}(...)`", .{ name, name });
            }
            return;
        }
        try self.reportMissingVariant(expected, name, pos);
    }

    /// `.variant` as a pattern: any variant of the scrutinee's enum.
    fn checkVariantName(self: *Checker, name_node: Sexp, scrutinee: TypeId) Error!void {
        if (self.isPoison(scrutinee)) return;
        if (sema.unwrapBorrows(self.ctx, scrutinee) == self.t().any_error_id) return self.checkErrorName(name_node);
        const name = self.text(name_node);
        if ((try sema.lookupVariant(self.ctx, scrutinee, name)) == null) {
            try self.reportMissingVariant(scrutinee, name, srcPos(name_node, 0));
        }
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
        try self.checkFieldArgs(args, resolved.payload, .{ .owner = name, .decl_pos = decl_pos, .module_id = module_id, .pos = pos, .kind = .variant });
    }

    /// `Vec()` / `Vec(capacity: n)`.
    fn checkVecConstruction(self: *Checker, call: Sexp) Error!void {
        var seen: ?u32 = null;
        for (ir.Call.args(call)) |a| {
            if (!a.isKind(.kwarg)) {
                try self.errAt(a, "`Vec` constructor takes no positional arguments; use `Vec()` (empty) or `Vec(capacity: N)`", .{});
                _ = try self.synthExpr(a);
                continue;
            }
            const name = self.text(ir.Kwarg.name(a));
            const pos = ir.Kwarg.name(a).src.pos;
            if (!std.mem.eql(u8, name, "capacity")) {
                try self.err(pos, "`Vec` constructor accepts only `capacity` as a kwarg; got `{s}`", .{name});
                _ = try self.synthExpr(ir.Kwarg.value(a));
                continue;
            }
            if (seen) |first| {
                try self.err(pos, "duplicate `capacity` kwarg in `Vec` constructor", .{});
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
        // A borrowed Copy value meets a value as the value.
        const va = readValue(self.ctx, a);
        const vb = readValue(self.ctx, b);
        if (va != a or vb != b) return self.unify(va, vb, pos);
        try self.err(pos, "incompatible types `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
        return null;
    }

    // =========================================================================
    // Builtins
    // =========================================================================

    /// Every builtin Rig has. The compile-time type queries are safe
    /// anywhere; the casts only inside `raw`.
    const Builtin = enum {
        sizeOf,
        alignOf,
        typeName,
        TypeOf,
        bitCast,
        intCast,
        floatCast,
        truncate,
        intFromFloat,
        floatFromInt,
        enumFromInt,

        fn isSafe(b: Builtin) bool {
            return switch (b) {
                .sizeOf, .alignOf, .typeName, .TypeOf => true,
                else => false,
            };
        }
    };

    fn synthBuiltin(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const name_node = ir.Builtin.name(node);
        const name = self.text(name_node);
        const pos = name_node.src.pos;
        const args = ir.Builtin.args(node);
        const ty: TypeId = blk: {
            const builtin = std.meta.stringToEnum(Builtin, name) orelse {
                try self.err(pos, "builtin `@{s}` is not supported; the builtins are `@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`, and, inside `raw`, `@bitCast`, `@intCast`, `@floatCast`, `@truncate`, `@intFromFloat`, `@floatFromInt`, `@enumFromInt`", .{name});
                try self.synthArgs(args);
                break :blk self.t().invalid_id;
            };
            if (!builtin.isSafe() and self.raw_depth == 0) {
                try self.err(pos, "builtin `@{s}` is not in the safe whitelist; wrap it in a `raw` block. Safe builtins: `@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`", .{name});
            }
            switch (builtin) {
                .sizeOf, .alignOf, .typeName => {
                    if (!(try self.builtinTypeArg(name, args, pos))) break :blk self.t().invalid_id;
                    break :blk if (builtin == .typeName) self.t().string_id else self.t().int_literal_id;
                },
                .TypeOf => {
                    try self.err(pos, "`@TypeOf` is only allowed as the argument of `@sizeOf`, `@alignOf`, or `@typeName`", .{});
                    try self.synthArgs(args);
                    break :blk self.t().invalid_id;
                },
                else => {},
            }
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
                    .intFromFloat => try self.checkFloatFits(args[0], to),
                    .enumFromInt => if (self.constInt(args[0]) != null) {
                        try self.errAt(args[0], "`@enumFromInt` of a constant: name the variant instead (`.name`)", .{});
                    },
                    else => {},
                }
            }
            break :blk target;
        };
        if (expected) |e| if (!self.isPoison(ty) and !compatible(self.ctx, ty, e)) try self.mismatch(node, e, ty);
        return ty;
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
            .intFromFloat => if (!f_float or t_ != .int) return "it converts a float to an integer",
            .floatFromInt => if (!f_int or t_ != .float) return "it converts an integer to a float",
            .enumFromInt => if (!f_int or !sema.isPlainEnum(self.ctx, to)) return "it converts an integer to a plain enum",
            .bitCast => {
                const fb = numericBits(f) orelse return "it reinterprets a number of the same size";
                const tb = numericBits(t_) orelse return "it reinterprets a number of the same size";
                if (fb != tb) return "both must have the same size";
            },
            .sizeOf, .alignOf, .typeName, .TypeOf => {},
        }
        return null;
    }

    /// `@sizeOf(T)` / `@sizeOf(@TypeOf(x))`. A type argument is recorded
    /// with the type it names.
    fn builtinTypeArg(self: *Checker, name: []const u8, args: []const Sexp, pos: u32) Error!bool {
        if (args.len != 1) {
            try self.err(pos, "`@{s}` takes one type argument", .{name});
            return false;
        }
        const a = args[0];
        if (a.isKind(.builtin) and ir.Builtin.args(a).len >= 1 and std.mem.eql(u8, self.text(ir.Builtin.name(a)), "TypeOf")) {
            _ = try self.synthExpr(ir.Builtin.args(a)[0]);
            return true;
        }
        var r = self.resolver();
        const ty = try r.resolveType(a);
        if (self.isPoison(ty)) return false;
        try self.ctx.recordType(a, ty);
        return true;
    }

    // =========================================================================
    // Closures
    // =========================================================================

    /// A closure literal lent where borrowed callable `target` (a
    /// `?fun(...)`) is expected: only as a call's argument, and only to a
    /// call whose result cannot hold it, since it lives for the call.
    fn lentLambda(self: *Checker, e: Sexp, target: TypeId) Error!TypeId {
        const fn_ty = sema.callableFnTy(self.ctx, target).?;
        if (sameNode(e, self.callable_kept)) {
            try self.errAt(e, "this call's result may hold the callable it is lent, and a closure literal lives only for the call; bind the closure (`f = |...| ...`) and lend it as `?f`", .{});
        } else if (!sameNode(e, self.lent_callable)) {
            try self.errAt(e, "a closure literal is lent as `{s}` only as a call's argument; bind the closure (`f = |...| ...`) and lend it as `?f`", .{try self.tyName(target)});
        }
        const ty = try self.checkLambda(e, fn_ty, false);
        try self.ctx.recordCallable(e, fn_ty);
        return ty;
    }

    /// `e`, of type `actual`, lent where borrowed callable `expected`
    /// (a `?fun(...)`) is: a function, or a borrowed owned closure of
    /// its function type. Returns whether `e` was handled.
    fn lendCallable(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!bool {
        const fn_ty = sema.callableFnTy(self.ctx, expected).?;
        // A function, or a read borrow of a function value (`?g`).
        const plain = switch (self.ctx.types.get(actual)) {
            .borrow_read => |inner| inner,
            else => actual,
        };
        if (plain == fn_ty) {
            try self.ctx.recordCallable(e, fn_ty);
            return true;
        }
        const owned = sema.ownedClosureFn(self.ctx, actual) orelse return false;
        if (self.ctx.types.get(sema.unwrapBorrows(self.ctx, actual)).shared != fn_ty) return false;
        if (!isBorrow(self.ctx, actual)) {
            _ = owned;
            // The handle is lent from its binding; reported once.
            const place = switch (e.kind() orelse .lambda) {
                .move, .clone => ir.get(e, .operand),
                else => e,
            };
            if (isPlaceExpr(place)) {
                try self.errAt(e, "an owned closure is lent to a `{s}` parameter: write `?{s}`", .{ try self.tyName(expected), try self.sourceText(place) });
            } else try self.errAt(e, "an owned closure is lent to a `{s}` parameter from a binding: bind it first (`cb = ...`), then lend it with `?cb`", .{try self.tyName(expected)});
            try self.ctx.recordType(e, self.t().invalid_id);
            return true;
        }
        try self.ctx.recordCallable(e, fn_ty);
        return true;
    }

    /// `*|...| body`: an owned closure; `expected` is the function type
    /// its context gives it (`*fun(Int) -> Int` gives `fun(Int) -> Int`).
    fn ownedClosure(self: *Checker, lambda: Sexp, expected: ?TypeId) Error!TypeId {
        const lty = try self.checkLambda(lambda, expected, true);
        try self.ctx.recordType(lambda, lty);
        return self.ctx.intern(.{ .shared = lty });
    }

    /// The function type of owned closure type `ty` (`fun(Int) -> Int` for
    /// `*fun(Int) -> Int`, possibly borrowed).
    fn ownedClosureType(self: *Checker, ty: TypeId) ?TypeId {
        if (sema.ownedClosureFn(self.ctx, ty) == null) return null;
        return self.ctx.types.get(sema.unwrapBorrows(self.ctx, ty)).shared;
    }

    /// A closure literal. Its type is a function type over its
    /// parameters. With an `expected` function type from context, bare
    /// parameters take its parameter types and the body is checked
    /// against its return type; without one, every parameter must be
    /// annotated and the return type is that of the body's last
    /// expression. `owned` closures pass only plain Copy values.
    fn checkLambda(self: *Checker, node: Sexp, expected: ?TypeId, owned: bool) Error!TypeId {
        return self.checkLambdaGiven(node, expected, &.{}, owned);
    }

    /// `checkLambda`, where without an `expected` type the parameters
    /// may take types from `given` (`type_invalid` for none).
    fn checkLambdaGiven(self: *Checker, node: Sexp, expected: ?TypeId, given_params: []const TypeId, owned: bool) Error!TypeId {
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
        const param_nodes = ir.Lambda.params(node).items();
        if (want) |w| if (param_nodes.len != w.params.len) {
            try self.errAt(node, "this closure takes {d} parameter{s}, but its type `{s}` passes {d}", .{ param_nodes.len, plural(param_nodes.len), try self.tyName(expected.?), w.params.len });
        };

        var params: std.ArrayListUnmanaged(TypeId) = .empty;
        defer params.deinit(self.ctx.allocator);
        var r = self.resolver();
        for (param_nodes, 0..) |p, i| {
            const pn = sema.paramNameNode(p) orelse continue;
            const name = self.text(pn);
            const given: ?TypeId = if (want) |w| (if (i < w.params.len) w.params[i] else null) else if (i < given_params.len and given_params[i] != sema.type_invalid) given_params[i] else null;
            var pty = self.t().invalid_id;
            if (p.isKind(.@":")) {
                pty = try r.resolveType(ir.@":".type(p));
                if (given) |g| if (!self.isPoison(pty) and !self.isPoison(g) and pty != g) {
                    try self.errAt(pn, "closure parameter `{s}` is declared `{s}`, but the closure's type passes `{s}`", .{ name, try self.tyName(pty), try self.tyName(g) });
                };
            } else if (given) |g| {
                pty = g;
            } else if (want == null and !self.under_poison and !self.namesOuterLocal(outer, name, srcPos(pn, 0))) {
                try self.errAt(pn, "closure parameter `{s}` needs a type: annotate it (`|{s}: Int|`) or write the closure where its type is known (`f: fun(Int) -> Int = |{s}| ...`)", .{ name, name, name });
            }
            if (owned and given == null and !sema.isClosureValue(self.ctx, pty)) {
                try self.errAt(pn, "an owned closure takes plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); parameter `{s}` is `{s}`", .{ name, try self.tyName(pty) });
            }
            try params.append(self.ctx.allocator, pty);
            if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            try self.ctx.recordType(pn, pty);
        }

        const body = ir.Lambda.body(node);
        if (want) |w| {
            try self.checkBody(body, .{ .ret = w.returns, .is_sub = w.is_sub, .fail_to = .closure });
            return expected.?;
        }

        var sites: std.ArrayListUnmanaged(ReturnSite) = .empty;
        defer sites.deinit(self.ctx.allocator);
        self.body = .{ .ret = self.t().unknown_id, .is_sub = false, .fail_to = .closure, .returns = &sites };
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
                ret = if (no_value) blk: {
                    try self.checkStmt(last);
                    break :blk self.t().void_id;
                } else try self.synthExpr(last);
            }
        } else ret = try self.synthExpr(body);
        ret = self.canonical(ret);
        if (ret == self.t().noreturn_id) ret = self.t().void_id;
        ret = try self.reconcileReturns(sites.items, ret, ends_in_return, body);
        if (owned and ret != self.t().void_id and !sema.isClosureValue(self.ctx, ret)) {
            try self.errAt(body, "an owned closure returns plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); this one returns `{s}`", .{try self.tyName(ret)});
        }

        return self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(params.items), .returns = ret, .is_sub = ret == self.t().void_id } });
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
            if (!compatible(self.ctx, ty, ret)) {
                // A generic call only literals typed would take the type.
                const hint = if (self.literalResult(ir.Return.value(site.node)) != null and sema.isNumeric(self.ctx, ret))
                    try std.fmt.allocPrint(self.ctx.arena.allocator(), "; give the closure its type where it goes (`f: fun(...) -> {s} = |...| ...`), and every `return` takes it", .{try self.tyName(ret)})
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

    /// `|?x|` / `|!x|`: the type of the borrow of outer binding `id`
    /// the closure holds, as `?x` / `!x` would have it. Poison after a
    /// diagnostic.
    fn captureBorrow(self: *Checker, id: SymbolId, name: []const u8, pos: u32, kind: BorrowKind) Error!TypeId {
        const sym = self.ctx.symbols.items[id];
        const ty = sym.ty;
        if (self.isPoison(ty)) return ty;
        const sigil: []const u8 = if (kind == .read) "?" else "!";
        switch (self.ctx.types.get(ty)) {
            .borrow_read => {
                if (kind == .read) return ty;
                try self.err(pos, "cannot write-borrow through a read borrow `{s}`; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
                return self.t().invalid_id;
            },
            .borrow_write => |base| return if (kind == .write) ty else self.ctx.intern(.{ .borrow_read = base }),
            .slice => if (kind == .write) {
                try self.err(pos, "cannot write-borrow a `{s}`: its elements are read-only; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
                return self.t().invalid_id;
            },
            .function => if (sym.flags.closure) {
                if (kind == .read) return sema.callableOfFn(self.ctx, ty);
                try self.err(pos, "a call never changes a closure's environment, so a closure is lent to read; capture it with `|?{s}|`", .{name});
                return self.t().invalid_id;
            },
            else => {},
        }
        if (kind == .write and !(try self.checkBindingWritable(sym, name, pos, "write-borrow"))) return self.t().invalid_id;
        if (kind == .read and sym.flags.pattern_bound and sema.holdsCellByValue(self.ctx, ty)) {
            try self.err(pos, "cannot capture `{s}{s}`: it holds a Cell, and `{s}` is a loop or match binding, a copy, so changes through the borrow would be lost", .{ sigil, name, name });
            return self.t().invalid_id;
        }
        return self.ctx.intern(if (kind == .read) Type{ .borrow_read = ty } else Type{ .borrow_write = ty });
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
            const ty = try self.captureBorrow(outer_id, name, pos, if (mode == .cap_read) .read else .write);
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
            .cap_clone => switch (self.ctx.types.get(outer_ty)) {
                .shared, .weak => outer_ty,
                // Cloning through a borrow of a handle makes a new handle.
                .borrow_read, .borrow_write => |inner| switch (self.ctx.types.get(inner)) {
                    .shared, .weak => inner,
                    else => null,
                },
                // Inside a generic body, copying a `T` requires plain data.
                else => if (sema.isPlainData(self.ctx, outer_ty) or self.isPoison(outer_ty) or
                    (sema.maybeDropGlue(self.ctx, outer_ty) and !(try self.ownsResource(outer_ty, pos, "copies into a closure a value")))) outer_ty else null,
            },
        };
        if (bound == null) if (mode == .cap_weak) {
            try self.err(pos, "weak-capture `|~{s}|` requires a shared handle `*T`; got `{s}`", .{ name, try self.tyName(outer_ty) });
        } else if (outer_sym.flags.closure or isBorrow(self.ctx, outer_ty)) {
            // A closure or a borrow is captured as a borrow.
            const sigil: []const u8 = if (self.ctx.types.get(outer_ty) == .borrow_write) "!" else "?";
            try self.err(pos, "`|+{s}|` copies a Copy value or clones a `*T` / `~T` handle, but `{s}` is {s}`{s}`; capture it with `|{s}{s}|`", .{ name, name, if (outer_sym.flags.closure) "a closure of type " else "", try self.tyName(outer_ty), sigil, name });
        } else {
            try self.err(pos, "`|+{s}|` copies a Copy value or clones a `*T` / `~T` handle, but `{s}` is `{s}`; move it in with `|<{s}|`, or clone a handle into a local first and capture that", .{ name, name, try self.tyName(outer_ty), name });
        };
        self.ctx.symbols.items[cap_sym].ty = bound orelse self.t().invalid_id;
        self.ctx.symbols.items[cap_sym].origin = outer_id;
        try self.ctx.recordType(name_node, bound orelse self.t().invalid_id);
    }
};

// =============================================================================
// Compatibility and classification
// =============================================================================

/// The type an operator reads from an operand: a borrowed Copy value
/// (`readValue`), or the `T` a borrowed type parameter reaches. Every
/// `T` an operator's requirement admits is plain data, so reading one
/// through its borrow copies no resource.
fn operandValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .borrow_write => |inner| if (ctx.types.get(inner) == .type_var) inner else readValue(ctx, ty),
        else => ty,
    };
}

/// A borrow of a Copy value (a primitive, a plain enum, or an error)
/// reads as the value itself: `n + 1` with `n: ?Int` or `n: !Int` is an
/// `Int`.
fn readValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .borrow_write => |inner| if (sema.isCopyPrimitive(ctx, inner) or sema.isPlainEnum(ctx, inner)) inner else ty,
        else => ty,
    };
}

/// Whether `ty` can be written in an expression's bracket list
/// (`id[Wrap[Int]](...)`): array, slice, and function types cannot.
fn spelledInBrackets(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .slice, .array, .function => false,
        .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak => |inner| spelledInBrackets(ctx, inner),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (!spelledInBrackets(ctx, arg)) break false;
        } else true,
        else => true,
    };
}

fn isBorrow(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .borrow_write => true,
        else => false,
    };
}

/// Can a value of type `actual` be used where `expected` is required?
fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    if (actual == expected) return true;
    const ts = &ctx.types;
    if (actual == ts.invalid_id or actual == ts.unknown_id or expected == ts.invalid_id or expected == ts.unknown_id) return true;
    if (actual == ts.noreturn_id) return true;
    const a = ts.get(actual);
    const e = ts.get(expected);
    switch (e) {
        .optional => |inner| {
            if (a == .none_literal) return true;
            return compatible(ctx, actual, inner);
        },
        // A `T!` holds a `T`, or the error it failed with.
        .fallible => |inner| return compatible(ctx, actual, inner) or sema.isErrorValue(ctx, actual),
        .borrow_read => |inner| if (a == .borrow_write) return a.borrow_write == inner,
        // A `![]T` (or a `?[]T`) reads as the `[]T` it borrows.
        .slice => switch (a) {
            .borrow_read, .borrow_write => |inner| if (inner == expected) return true,
            else => {},
        },
        else => {},
    }
    return switch (a) {
        .int_literal => e == .int or e == .float,
        .float_literal => e == .float,
        .borrow_read, .borrow_write => readValue(ctx, actual) != actual and compatible(ctx, readValue(ctx, actual), expected),
        else => false,
    };
}

const ReceiverTypeKind = enum { owned_nominal, read_borrow, write_borrow, shared, other };

/// What kind of value a method's receiver is, for the type whose symbol
/// is `nominal_sym` (`symbol_invalid` for an imported type).
fn classifyReceiverType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) ReceiverTypeKind {
    const matches = struct {
        fn f(c: *const SemContext, id: TypeId, sym: SymbolId) bool {
            return switch (c.types.get(id)) {
                .nominal => |s| s == sym,
                .parameterized_nominal => |pn| pn.sym == sym,
                .imported_nominal => sym == sema.symbol_invalid,
                else => false,
            };
        }
    }.f;
    // A borrow of a shared handle (`!h.m()` with `h: *T`) still reaches
    // the value through the handle.
    if (ctx.types.get(sema.unwrapBorrows(ctx, ty_id)) == .shared) return .shared;
    return switch (ctx.types.get(ty_id)) {
        .borrow_read => |i| if (matches(ctx, i, nominal_sym)) .read_borrow else .other,
        .borrow_write => |i| if (matches(ctx, i, nominal_sym)) .write_borrow else .other,
        else => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
    };
}

const ReceiverShape = enum { read_explicit, write_explicit, move_explicit, rvalue, lvalue_bare };

/// How the receiver expression is written. Only heads that certainly
/// produce a fresh value count as rvalues; everything else is a place.
fn classifyReceiverShape(recv: Sexp) ReceiverShape {
    const h = recv.kind() orelse return .lvalue_bare;
    return switch (h) {
        .read => .read_explicit,
        .write => .write_explicit,
        .move => .move_explicit,
        .call, .builtin, .array, .array_fill, .clone, .share, .weak, .@"if", .match, .@"catch", .propagate, .propagate_none => .rvalue,
        else => .lvalue_bare,
    };
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

/// The element type of a Cell holding a Vec (`Cell[Vec[E]]`, `?Cell[Vec[E]]`, `*Cell[Vec[E]]`, ...).
fn cellVecElement(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return vecElementType(ctx, cellElementType(ctx, ty) orelse return null);
}

const cell_vec_handle = "cannot read or overwrite an element of a `{s}` in place: its elements are handles, which would be copied out or released while the cell holds them; `pop` the element, or `replace` the Vec to work on it";

/// The data field (not a method or variant) named `name`.
fn findDataField(fields: []const Field, name: []const u8) ?Field {
    for (fields) |f| {
        if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// The element type of a `Vec[T]`.
fn vecElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.vec_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// Storage that already has an owner: a name, a field or element of
/// one, or a borrow of one.
fn isPlaceExpr(e: Sexp) bool {
    const h = e.kind() orelse return e == .src;
    return switch (h) {
        .member, .index, .read, .write => true,
        else => false,
    };
}

fn numericBits(t: sema.Type) ?u16 {
    return switch (t) {
        .int => |i| intBounds(i).bits,
        .float => |f| if (f.bits == 0) 64 else f.bits,
        else => null,
    };
}

const IntBounds = struct { min: i128, max: i128, bits: u8 };

/// The width and value range of an integer type.
fn intBounds(info: sema.IntInfo) IntBounds {
    const bits: u8 = if (info.bits == 0) 64 else info.bits;
    const half = @as(i128, 1) << @intCast(bits - 1);
    return if (info.signed) .{ .min = -half, .max = half - 1, .bits = bits } else .{ .min = 0, .max = 2 * half - 1, .bits = bits };
}

/// Whether numeric type `ty` holds the integer `v`: in range for an
/// integer type, exactly representable for a float type (Zig rejects a
/// constant that would round).
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
            return @floatFromInt(std.fmt.parseInt(i128, t, 0) catch return null);
        },
        .list => {
            const h = e.kind() orelse return null;
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

fn holdsInt(ctx: *const SemContext, ty: TypeId, v: i128) bool {
    return switch (ctx.types.get(ty)) {
        .int => |info| v >= intBounds(info).min and v <= intBounds(info).max,
        .float => |f| blk: {
            const mantissa: u8 = if (f.bits == 32) 24 else 53;
            const a = @abs(v);
            break :blk a == 0 or 128 - @clz(a) - @ctz(a) <= mantissa;
        },
        else => true,
    };
}

/// `while true` with no `break` out of it: the loop only ends by
/// `return`, so a function may end with it.
fn loopsForever(source: []const u8, s: Sexp) bool {
    var label: []const u8 = "";
    var loop = s;
    if (s.isKind(.labeled)) {
        label = identAt(source, ir.Labeled.label(s)) orelse "";
        loop = ir.Labeled.stmt(s);
    }
    return isWhileTrue(source, loop) and !sema.breaksOut(source, ir.While.body(loop), label, false, false);
}

fn isWhileTrue(source: []const u8, loop: Sexp) bool {
    return loop.isKind(.@"while") and std.mem.eql(u8, identAt(source, ir.While.cond(loop)) orelse "", "true");
}

/// The first name in `node` that denotes symbol `sym`.
fn findUse(ctx: *const SemContext, node: Sexp, sym: SymbolId) ?Sexp {
    if (node == .src) return if (ctx.symbolOf(node) == sym) node else null;
    for (rig.children(node)) |c| if (findUse(ctx, c, sym)) |use| return use;
    return null;
}

/// The call whose value `e` is: `e` itself, or the call under a `!`,
/// `?`, `catch`, or on the left of `??`.
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
/// The element type of an array, or of a borrow of one.
fn arrayElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(sema.unwrapBorrows(ctx, ty))) {
        .array => |a| a.elem,
        else => null,
    };
}

fn sameNode(a: Sexp, b: Sexp) bool {
    return a == .list and b == .list and a.list.ptr == b.list.ptr;
}

/// A name, or a field or element of one: storage with an owner.
fn isStoragePath(e: Sexp) bool {
    if (e == .src) return true;
    if (e.isKind(.member)) return isStoragePath(ir.Member.object(e));
    if (e.isKind(.index) and !rig.isRangeIndex(e)) return isStoragePath(ir.Index.object(e));
    return false;
}

/// A name or a chain of fields off one: `v`, `t.kids`, `a.b.c`.
fn isFieldPath(e: Sexp) bool {
    if (e == .src) return true;
    if (!e.isKind(.member)) return false;
    return isFieldPath(ir.Member.object(e));
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
pub fn checkGenericInstantiations(ctx: *SemContext) Error!void {
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |entry| {
        const pn = switch (ctx.types.get(entry.key_ptr.*)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        const params = ctx.symbols.items[pn.sym].type_params orelse continue;
        const of: sema.InstanceRoot = .{ .type = entry.key_ptr.* };
        if (try checkRequirements(ctx, params, pn.args, entry.value_ptr.*, of)) try checkInstanceSizes(ctx, params, pn.args, entry.value_ptr.*, of);
    }
    // A method's instance checks only its own parameters; its type's
    // are checked with the receiver's instance.
    var i: usize = 0;
    while (i < ctx.fn_instances.items.len) : (i += 1) {
        const f = ctx.fn_instances.items[i];
        const of: sema.InstanceRoot = .{ .func = f.inst };
        if (try checkRequirements(ctx, f.inst.ownParams(), f.inst.ownArgs(), f.site, of)) {
            try checkInstanceSizes(ctx, f.inst.params, f.inst.args, f.site, of);
        } else if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
    }
}

// ---- stack frames -----------------------------------------------------------

/// Every function, method, closure, test, and drop body keeps at most
/// `sema.max_frame_bytes` of values on its stack: each binding it
/// declares and each by-value parameter, once, and each array literal,
/// fill, and call whose value no binding takes directly (a temporary). A
/// closure's captures count in the frame that makes it. A frame whose
/// size depends on generic parameters is checked at each instance
/// (`checkInstanceSizes`).
pub fn checkFrames(ctx: *SemContext, tree: Sexp) Error!void {
    var w: FrameWalker = .{ .ctx = ctx };
    try w.walk(tree, null, false);
}

const FrameWalker = struct {
    ctx: *SemContext,

    const Slots = std.ArrayListUnmanaged(TypeId);

    fn walk(self: *FrameWalker, node: Sexp, frame: ?*Slots, bound: bool) Error!void {
        const ctx = self.ctx;
        if (node == .src) {
            const f = frame orelse return;
            const id = ctx.symbolOf(node) orelse return;
            const sym = ctx.symbols.items[id];
            switch (sym.kind) {
                .local, .param, .capture => {},
                else => return,
            }
            if (sym.decl_pos != node.src.pos or sym.flags.comptime_known or sym.scope == sema.module_scope) return;
            try f.append(ctx.allocator, sym.ty);
            return;
        }
        // A group (a parameter list) has no kind.
        const kind = node.kind() orelse {
            for (node.items()) |c| try self.walk(c, frame, false);
            return;
        };
        switch (kind) {
            .fun, .sub => {
                const name = ir.get(node, .name);
                const label = try std.fmt.allocPrint(ctx.arena.allocator(), "`{s}`", .{sema.identAt(ctx.source, name) orelse "?"});
                try self.frameOf(label, ctx.startOf(name), &.{ ir.get(node, .params), ir.get(node, .body) });
            },
            .@"test" => {
                const label = try std.fmt.allocPrint(ctx.arena.allocator(), "test {s}", .{sema.identAt(ctx.source, ir.get(node, .name)) orelse "?"});
                try self.frameOf(label, ctx.startOf(node), &.{ir.get(node, .body)});
            },
            .drop_decl => try self.frameOf("`drop`", ctx.startOf(node), &.{ ir.get(node, .params), ir.get(node, .body) }),
            .lambda => {
                // The captures are stored where the closure is made.
                try self.walk(ir.Lambda.captures(node), frame, false);
                try self.frameOf("a closure", ctx.startOf(node), &.{ ir.Lambda.params(node), ir.Lambda.body(node) });
            },
            .set => {
                try self.walk(ir.Set.target(node), frame, false);
                try self.walk(ir.Set.value(node), frame, true);
            },
            else => {
                if (frame) |f| switch (kind) {
                    .array, .array_fill, .call => if (!bound) if (ctx.typeOf(node)) |ty| try f.append(ctx.allocator, ty),
                    else => {},
                };
                for (rig.children(node)) |c| try self.walk(c, frame, false);
            },
        }
    }

    /// The frame of the body `parts` make up, checked now or, when its
    /// size depends on generic parameters, at each instance.
    fn frameOf(self: *FrameWalker, label: []const u8, pos: u32, parts: []const Sexp) Error!void {
        const ctx = self.ctx;
        var slots: Slots = .empty;
        defer slots.deinit(ctx.allocator);
        for (parts) |p| try self.walk(p, &slots, false);
        const tys = slots.items;
        if (tys.len == 0) return;
        for (tys) |ty| if (sema.containsTypeVar(ctx, ty)) {
            try ctx.generic_frames.append(ctx.allocator, .{ .label = label, .pos = pos, .tys = try ctx.arena.allocator().dupe(TypeId, tys) });
            return;
        };
        const bytes = (try frameBytes(ctx, tys)) orelse return;
        if (bytes > sema.max_frame_bytes) try reportFrame(ctx, pos, label, bytes, null);
    }
};

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

fn reportFrame(ctx: *SemContext, pos: u32, label: []const u8, bytes: u128, of: ?sema.InstanceRoot) Error!void {
    const in = if (of) |root| try std.fmt.allocPrint(ctx.arena.allocator(), " in `{s}`", .{try sema.rootName(ctx, root)}) else "";
    try ctx.err(pos, "{s} keeps {d} bytes of values on its stack{s}; a function keeps at most {d} (16 MiB), the size of the stack. Keep large data in a `Vec`", .{ label, bytes, in, sema.max_frame_bytes });
}

/// The arrays a generic declaration makes, in one instance, and a generic
/// type's instance itself, must fit `sema.max_value_bytes`.
fn checkInstanceSizes(ctx: *SemContext, params: []const SymbolId, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!void {
    for (args) |a| if (sema.containsPoison(ctx, a)) return;
    const subst: sema.TypeSubst = .{ .params = params, .args = args };
    var i: usize = 0;
    while (i < ctx.generic_arrays.items.len) : (i += 1) {
        const g = ctx.generic_arrays.items[i];
        if (!sema.usesParams(ctx, g.ty, params)) continue;
        const ty = try sema.substituteType(ctx, g.ty, subst);
        if (sema.containsTypeVar(ctx, ty) or sema.containsPoison(ctx, ty)) continue;
        const bytes = (try sema.arrayOversized(ctx, ty)) orelse continue;
        try ctx.oversized.put(ctx.allocator, ty, {});
        if (of == .type) try ctx.oversized.put(ctx.allocator, of.type, {});
        try ctx.err(at, "`{s}` makes `{s}`, which takes {d} bytes; a value takes at most {d} (8 MiB), since it may live on the stack. Keep larger data in a `Vec`", .{ try sema.rootName(ctx, of), try sema.formatType(ctx, ty), bytes, sema.max_value_bytes });
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
    var buf: std.ArrayListUnmanaged(TypeId) = .empty;
    defer buf.deinit(ctx.allocator);
    frames: for (ctx.generic_frames.items) |fr| {
        const uses = for (fr.tys) |ty| {
            if (sema.usesParams(ctx, ty, own)) break true;
        } else false;
        if (!uses) continue;
        buf.clearRetainingCapacity();
        for (fr.tys) |ty| {
            const t = try sema.substituteType(ctx, ty, subst);
            if (sema.containsTypeVar(ctx, t)) continue :frames;
            try buf.append(ctx.allocator, t);
        }
        const bytes = (try frameBytes(ctx, buf.items)) orelse continue;
        if (bytes <= sema.max_frame_bytes) continue;
        try reportFrame(ctx, at, fr.label, bytes, of);
        try ctx.noteIn(fr.module_id, fr.pos, "{s} is declared here", .{fr.label});
        return;
    }
}

/// False after a diagnostic.
fn checkRequirements(ctx: *SemContext, params: []const SymbolId, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    var ok = true;
    for (params, 0..) |param, i| {
        if (i >= args.len) break;
        const arg = args[i];
        // A diagnostic was reported about the argument.
        if (sema.containsPoison(ctx, arg)) continue;
        for (ctx.generic_requirements.items) |req| {
            if (req.param != param or try satisfies(ctx, arg, req.req)) continue;
            const inst = try sema.rootName(ctx, of);
            const pname = ctx.symbols.items[param].name;
            const aname = try sema.formatType(ctx, arg);
            const cannot = "`{s}` cannot use `{s} = {s}`: the generic body ";
            switch (req.req) {
                .plain => try ctx.err(at, cannot ++ "{s} that holds a `{s}`, which would leak or duplicate the resource `{s}` owns", .{ inst, pname, aname, req.op, pname, aname }),
                .array_len => try ctx.err(at, cannot ++ "uses `{s}` as an array length, which runs from 0 to {d}", .{ inst, pname, aname, pname, sema.max_array_len }),
                .bytes => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` in bytes, which takes an integer or float type", .{ inst, pname, aname, req.op, pname }),
                .fits => |v| try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and the literal `{d}`, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, v, aname }),
                .float => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and a float literal, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, aname }),
                .shift => |v| try ctx.err(at, cannot ++ "shifts a `{s}` by {d} bits, which `{s}` is too narrow for", .{ inst, pname, aname, pname, v, aname }),
                .equatable => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support: {s}", .{ inst, pname, aname, req.op, pname, aname, try notEquatableReason(ctx, (try sema.notEquatable(ctx, arg, null)).?) }),
                else => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support", .{ inst, pname, aname, req.op, pname, aname }),
            }
            switch (req.req) {
                .plain => try ctx.noteIn(req.module_id, req.pos, "here", .{}),
                .array_len => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as an array length here", .{pname}),
                .bytes => try ctx.noteIn(req.module_id, req.pos, "`{s}` used here", .{req.op}),
                .fits, .float, .shift => try ctx.noteIn(req.module_id, req.pos, "`{s}` used here", .{req.op}),
                else => try ctx.noteIn(req.module_id, req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() }),
            }
            ok = false;
            break;
        }
    }
    return ok;
}

/// Why `==` is not defined for a type, as a diagnostic says it.
fn notEquatableReason(ctx: *SemContext, n: sema.NotEquatable) Error![]const u8 {
    const a = ctx.arena.allocator();
    // Another module's type is named as this module spells it.
    const t = if (n.origin) |m| try sema.formatType(ctx, try sema.importType(ctx, @constCast(n.ctx), n.ty, m)) else try sema.formatType(ctx, n.ty);
    if (n.path.len > 0) return switch (n.why) {
        .handle => std.fmt.allocPrint(a, "field `{s}` is a handle `{s}`, which could compare by identity or by content", .{ n.path, t }),
        .closure => std.fmt.allocPrint(a, "field `{s}` is an owned closure `{s}`", .{ n.path, t }),
        .function => std.fmt.allocPrint(a, "field `{s}` is a function value", .{n.path}),
        .no_eq => std.fmt.allocPrint(a, "field `{s}` is a `{s}`, which has no `==`", .{ n.path, t }),
        .borrow => std.fmt.allocPrint(a, "field `{s}` holds a borrow", .{n.path}),
        .drop => std.fmt.allocPrint(a, "field `{s}` is a `{s}`: `{s}` declares `drop`", .{ n.path, t, t }),
    };
    return switch (n.why) {
        .handle => std.fmt.allocPrint(a, "`{s}` is a handle, which could compare by identity or by content", .{t}),
        .closure => std.fmt.allocPrint(a, "`{s}` is an owned closure", .{t}),
        .function => std.fmt.allocPrint(a, "`{s}` is a function value", .{t}),
        .no_eq => std.fmt.allocPrint(a, "`{s}` has no `==`", .{t}),
        .borrow => std.fmt.allocPrint(a, "`{s}` is a borrow", .{t}),
        .drop => std.fmt.allocPrint(a, "`{s}` declares `drop`", .{t}),
    };
}

fn satisfies(ctx: *SemContext, ty: TypeId, req: Requirement) Error!bool {
    return switch (req) {
        .numeric, .bytes => sema.isNumeric(ctx, ty),
        .ordered => sema.isNumeric(ctx, ty) or ctx.types.get(ty) == .string,
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
        .plain => !sema.typeHasDropGlue(ctx, ty),
        .array_len => switch (ctx.types.get(ty)) {
            .ct_value => |v| v.int >= 0 and v.int <= sema.max_array_len,
            else => false,
        },
        .equatable => sema.isEquatable(ctx, ty),
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
        if (std.mem.indexOf(u8, d.message, needle) != null) return;
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
    try expectDiagnostic(&r.ctx, "requires numeric operands; got `String`");
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

test "check: reborrow of a borrowed parameter" {
    var r = try checkSource(std.testing.allocator,
        \\struct B
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
        \\struct U
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
    try expectDiagnostic(&r.ctx, "a closure body cannot propagate");
}

test "check: each distinct instance of a generic function is recorded once" {
    var r = try checkSource(std.testing.allocator,
        \\struct P
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
