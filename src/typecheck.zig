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
//! expected (`readValue`); and anything where poison (`unknown` /
//! `invalid`) is involved, so one error does not cascade.
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
        .fn_return = ctx.types.void_id,
    };
    for (ir.Module.decls(tree)) |decl| try c.checkDecl(decl);
}

const Checker = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,
    /// Type `return` values must have; `unknown` inside lambdas.
    fn_return: TypeId,
    is_sub: bool = true,
    nominal: NominalContext = NominalContext.none,
    /// Callee node of the method call being checked; its resolved
    /// signature is recorded as the node's type.
    callee_node: ?Sexp = null,
    /// The call being checked, for its argument-slot fact.
    current_call: ?Sexp = null,
    /// The `new x` binding whose value is being checked: not visible yet.
    pending: SymbolId = sema.symbol_invalid,
    /// The `return`s of the closure whose return type is being inferred.
    lambda_returns: ?*std.ArrayListUnmanaged(ReturnSite) = null,
    /// Where a `!` in the code being checked sends its failure.
    fail_to: FailTarget = .module,
    /// Enclosing `raw` blocks.
    raw_depth: u32 = 0,
    /// The operand of the `!` or `catch` being checked: a fallible call
    /// there is handled.
    handled: Sexp = .nil,

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
        switch (sexp.kind() orelse return) {
            .@"pub" => try self.checkDecl(ir.Pub.decl(sexp)),
            .fun, .sub => {
                const fn_ty = if (self.ctx.symbolOf(ir.get(sexp, .name))) |id| self.ctx.symbols.items[id].ty else self.t().invalid_id;
                try self.checkFunction(sexp, fn_ty);
            },
            .@"struct", .@"enum", .errors, .generic_type, .generic_enum => try self.checkNominal(sexp),
            .@"test" => {
                const prev_scope = self.enter(sexp);
                defer self.scope = prev_scope;
                // A test fails by returning an error, which `rig test`
                // reports.
                self.fail_to = .caller;
                defer self.fail_to = .module;
                try self.checkBody(ir.Test.body(sexp), self.t().void_id, true);
            },
            .set => {
                try self.errAt(sexp, "module-level bindings are not supported yet; bind values inside a function", .{});
                try self.checkSet(sexp);
            },
            .use, .type, .@"extern", .extern_fun, .extern_sub => {},
            else => try self.errAt(sexp, "only declarations and bindings are allowed at module level; move this statement into a function", .{}),
        }
    }

    /// A `struct`, `enum`, `errors`, `generic_type`, or `generic_enum`.
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
                .drop_decl => {
                    const prev_scope = self.enter(m);
                    defer self.scope = prev_scope;
                    const prev_ret = self.fn_return;
                    const prev_sub = self.is_sub;
                    defer {
                        self.fn_return = prev_ret;
                        self.is_sub = prev_sub;
                    }
                    self.fn_return = self.t().void_id;
                    self.is_sub = true;
                    self.fail_to = .drop;
                    defer self.fail_to = .module;
                    try self.checkBody(ir.DropDecl.body(m), self.t().void_id, true);
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
        const prev_ret = self.fn_return;
        const prev_sub = self.is_sub;
        defer {
            self.scope = prev_scope;
            self.fn_return = prev_ret;
            self.is_sub = prev_sub;
        }
        self.fn_return = ret;
        self.is_sub = is_sub;
        // `sub main` lowers to a fallible `main`.
        const name = ir.get(node, .name);
        const is_main = is_sub and self.nominal.isEmpty() and std.mem.eql(u8, self.text(name), "main");
        self.fail_to = if (is_main or rig.returnType(node).isKind(.error_union)) .caller else .{ .infallible = name };
        defer self.fail_to = .module;
        for (ir.get(node, .params).items()) |p| try self.checkDefault(p);
        try self.checkBody(ir.get(node, .body), ret, is_sub);
    }

    /// A parameter's default value is a literal of the parameter's type:
    /// it is written at each call site that omits the argument.
    fn checkDefault(self: *Checker, param: Sexp) Error!void {
        if (!param.isKind(.default)) return;
        const value = ir.Default.value(param);
        const ty = self.ctx.bindingTypeOf(ir.Default.name(param)) orelse self.t().unknown_id;
        if (!isDefaultLiteral(self.ctx.source, value)) {
            try self.errAt(value, "a default parameter value must be a literal: a number, a string, `true` / `false`, `none`, or `.variant`", .{});
            return;
        }
        try self.checkExpr(value, ty);
    }

    /// A body's statements; in a `fun`, the last one is its value.
    fn checkBody(self: *Checker, body: Sexp, ret: TypeId, is_sub: bool) Error!void {
        const wants_value = !is_sub and ret != self.t().void_id;
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
        for (stmts, 0..) |s, i| {
            if (wants_value and i == stmts.len - 1) {
                if (loopsForever(self.ctx.source, s)) {
                    try self.checkStmt(s);
                    continue;
                }
                if (isStatementForm(s) and !s.isKind(.@"return")) {
                    try self.checkStmt(s);
                    try self.errAt(s, "a function returning `{s}` must end with a value; this `{s}` produces none", .{ try self.tyName(ret), @tagName(s.kind().?) });
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
        const head = stmt.kind() orelse {
            _ = try self.synthExpr(stmt);
            return;
        };
        switch (head) {
            .set => try self.checkSet(stmt),
            .@"return" => try self.checkReturn(stmt),
            .@"if" => try self.checkIf(stmt, null),
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
            .@"break" => if (ir.Break.value(stmt) != .nil) {
                try self.errAt(ir.Break.value(stmt), "`break` with a value is not supported yet", .{});
            },
            .@"continue" => {},
            .@"defer", .@"errdefer" => {
                const prev = self.fail_to;
                defer self.fail_to = prev;
                self.fail_to = .deferred;
                try self.checkStmt(ir.get(stmt, .body));
            },
            .raw_block => {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                try self.checkStmt(ir.RawBlock.body(stmt));
            },
            .labeled => try self.checkStmt(ir.Labeled.stmt(stmt)),
            .fun, .sub, .@"struct", .@"enum", .errors, .type, .generic_type, .generic_enum, .use, .@"extern", .extern_fun, .extern_sub, .@"test", .@"pub" => {
                try self.errAt(stmt, "declarations are only allowed at module level", .{});
            },
            else => {
                const ty = try self.synthExpr(stmt);
                if ((try self.ownsResource(ty, self.startOf(stmt), "discards a value"))) {
                    try self.errAt(stmt, "expression result of type `{s}` carries drop glue and would leak as a discarded statement; bind it to a name (`old = {s}.replace(<new)`), explicitly drop with `-name`, or move it into a receiver", .{
                        try self.tyName(ty), self.discardedReceiverName(stmt),
                    });
                }
            },
        }
    }

    fn discardedReceiverName(self: *Checker, stmt: Sexp) []const u8 {
        if (stmt.isKind(.call) and ir.Call.callee(stmt).isKind(.member)) {
            const obj = ir.Member.object(ir.Call.callee(stmt));
            if (obj == .src) return self.text(obj);
        }
        return "expr";
    }

    fn checkReturn(self: *Checker, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        const ret = self.fn_return;
        if (self.lambda_returns) |sites| {
            const ty: ?TypeId = if (value == .nil) null else try self.synthExpr(value);
            try sites.append(self.ctx.allocator, .{ .node = node, .ty = ty });
            return;
        }
        if (value == .nil) {
            if (!self.is_sub and ret != self.t().void_id and !self.isPoison(ret)) {
                try self.errAt(node, "`return` needs a value of type `{s}`", .{try self.tyName(ret)});
            }
            return;
        }
        if (self.is_sub and ret == self.t().void_id) {
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
            _ = try self.synthExpr(rhs);
            return;
        }
        const sym_id = self.ctx.symbolOf(target) orelse blk: {
            // `<-` and compound assignment name an existing binding.
            const id = (try self.useName(target)) orelse {
                _ = try self.synthExpr(rhs);
                return;
            };
            break :blk id;
        };
        try self.ctx.recordName(target, sym_id);
        const sym = &self.ctx.symbols.items[sym_id];
        const is_decl = sym.decl_pos == target.src.pos;

        if (!is_decl and sym.kind == .param and self.ctx.types.get(sym.ty) != .borrow_write) {
            try self.errAt(target, "cannot assign to parameter `{s}`; parameters are immutable (bind a copy with `new {s} = {s}`, or take `{s}: !T` to write through to the caller)", .{ name, name, name, name });
        }
        if (!is_decl and sym.kind == .capture) {
            try self.errAt(target, "cannot assign to captured `{s}`; captures are fixed when the closure is created", .{name});
        }
        const writes_through = sym.kind == .param or sym.flags.pattern_bound;
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

        if (self.ctx.signal_sym_id != sema.symbol_invalid) {
            const d = self.ctx.types.get(declared);
            if (d == .parameterized_nominal and d.parameterized_nominal.sym == self.ctx.signal_sym_id) {
                try self.errAt(target, "stack-local `Signal(T)` is not supported; Signal owns a subscriber `Vec` that requires heap ownership. Use `*Signal(T)` instead: `{s}: *Signal(...) = *Signal(value: ...)`", .{name});
                self.poisonIfUntyped(sym_id);
                return;
            }
        }

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
        if (!self.isPoison(declared)) {
            try self.checkExpr(rhs, declared);
            rhs_ty = declared;
        } else {
            rhs_ty = try self.synthExpr(rhs);
            // Binding a borrowed Copy value copies the value; an explicit
            // `?x` / `!x` binds the borrow.
            if (!rhs.isKind(.read) and !rhs.isKind(.write)) rhs_ty = readValue(self.ctx, rhs_ty);
            rhs_ty = try self.defaultBindingType(rhs, rhs_ty, name);
        }

        const s = &self.ctx.symbols.items[sym_id];
        if (s.ty == self.t().unknown_id) s.ty = rhs_ty;
        if (kind == .fixed and self.isComptimeKnown(rhs)) s.flags.comptime_known = true;
        try self.ctx.recordType(target, s.ty);
        // A binding that never changes keeps a constant value.
        if (is_decl and s.kind == .local and !s.flags.reassigned and !s.flags.written and sema.isInteger(self.ctx, s.ty)) {
            if (self.constInt(rhs)) |v| try self.ctx.const_ints.put(self.ctx.allocator, sym_id, v);
        }
    }

    fn poisonIfUntyped(self: *Checker, id: SymbolId) void {
        const sym = &self.ctx.symbols.items[id];
        if (sym.ty == self.t().unknown_id) sym.ty = self.t().invalid_id;
    }

    /// The type an unannotated binding gets from its initializer.
    fn defaultBindingType(self: *Checker, rhs: Sexp, ty: TypeId, name: []const u8) Error!TypeId {
        const pos = self.startOf(rhs);
        switch (self.ctx.types.get(ty)) {
            .int_literal => {
                try self.checkLiteralFits(rhs, self.t().int_id);
                try self.ctx.recordType(rhs, self.t().int_id);
                return self.t().int_id;
            },
            .float_literal => {
                try self.ctx.recordType(rhs, self.t().float_id);
                return self.t().float_id;
            },
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
            else => return ty,
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
        if (try self.placeThroughShared(target)) {
            try self.errAt(target, "cannot assign through shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell(T)` for mutation through shared ownership.", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        if (try self.placeThroughReadBorrow(target)) |pos| {
            try self.err(pos, "cannot assign through a read borrow (`?T`); take a write borrow (`!T`) to mutate", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        const place_ty = try self.synthExpr(target);
        try self.checkWritable(target, "assign to");
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
            const ty = readValue(self.ctx, try self.synthExpr(rhs));
            if (ty == target_ty or ty == self.t().int_literal_id or (req != .integer and ty == self.t().float_literal_id)) {
                try self.requireHoldsLiteral(param, ty, rhs, pos, spelled);
            } else if (!self.isPoison(ty)) try self.errAt(rhs, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(target_ty), try self.tyName(ty) });
        } else try self.checkExpr(rhs, target_ty);
        _ = try self.checkDivisor(op, target_ty, rhs);
    }

    /// Writing to `place` (a name, or a field or element of one) writes
    /// the binding it is rooted in, unless the path goes through a
    /// pointer: that binding must be mutable. Fixed (`=!`), loop and
    /// pattern bindings, captures, and parameters other than `!T` ones
    /// are not.
    fn checkWritable(self: *Checker, place: Sexp, verb: []const u8) Error!void {
        var p = place;
        while (p.kind()) |h| {
            if (h != .member and h != .index) return;
            const obj = ir.get(p, .object);
            const obj_ty = self.ctx.typeOf(obj) orelse return;
            switch (self.ctx.types.get(obj_ty)) {
                .borrow_read, .borrow_write, .shared => return,
                else => {},
            }
            p = obj;
        }
        if (p != .src) return;
        const id = self.ctx.symbolOf(p) orelse return;
        const sym = self.ctx.symbols.items[id];
        const name = sym.name;
        const pos = p.src.pos;
        switch (sym.kind) {
            .param => if (self.ctx.types.get(sym.ty) != .borrow_write) {
                try self.err(pos, "cannot {s} parameter `{s}`; parameters are immutable (take `{s}: !T` to write through to the caller)", .{ verb, name, name });
            },
            .capture => try self.err(pos, "cannot {s} captured `{s}`; captures are fixed when the closure is created", .{ verb, name }),
            .local => if (sym.flags.fixed) {
                try self.err(pos, "cannot {s} fixed binding `{s}` (bound with `=!`)", .{ verb, name });
            } else if (sym.flags.pattern_bound and self.ctx.types.get(sym.ty) != .borrow_write) {
                try self.err(pos, "cannot {s} `{s}`; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ verb, name, name, name });
            },
            else => {},
        }
    }

    /// Does an assignment target reach its storage through a `*T`?
    fn placeThroughShared(self: *Checker, place: Sexp) Error!bool {
        const h = place.kind() orelse return false;
        if (h != .member and h != .index) return false;
        const obj = ir.get(place, .object);
        const obj_ty = try self.synthQuiet(obj);
        if (self.ctx.types.get(sema.unwrapBorrows(self.ctx, obj_ty)) == .shared) return true;
        return self.placeThroughShared(obj);
    }

    /// Position of a `?T` the assignment target reaches through, if any.
    fn placeThroughReadBorrow(self: *Checker, place: Sexp) Error!?u32 {
        const h = place.kind() orelse return null;
        if (h != .member and h != .index) return null;
        const obj = ir.get(place, .object);
        const obj_ty = try self.synthQuiet(obj);
        if (self.ctx.types.get(obj_ty) == .borrow_read) return self.startOf(obj);
        return self.placeThroughReadBorrow(obj);
    }

    /// Synthesize without reporting diagnostics (the full check reports them).
    fn synthQuiet(self: *Checker, e: Sexp) Error!TypeId {
        const mark = self.ctx.diagnostics.items.len;
        const ty = try self.synthExpr(e);
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        return ty;
    }

    // ---- conditionals and loops ---------------------------------------------

    /// `if` at statement position (`expected == null`) or as a value.
    fn checkIf(self: *Checker, node: Sexp, expected: ?TypeId) Error!void {
        _ = try self.checkIfValue(node, expected, .statement);
    }

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
        if ((try self.ownsResource(inner, self.startOf(expr), "moves out of a borrow a value")) and (expr.isKind(.read) or expr.isKind(.write))) {
            try self.errAt(expr, "a borrow cannot give up the resource inside it; bind a new handle with `+x` instead", .{});
        }
        self.scope = self.ctx.scopeOf(node) orelse self.scope;
        if (self.ctx.symbolOf(name)) |sym| {
            self.ctx.symbols.items[sym].ty = inner;
            try self.ctx.recordType(name, inner);
        }
    }

    fn checkWhile(self: *Checker, node: Sexp) Error!void {
        const prev = self.scope;
        try self.checkCondition(ir.While.cond(node));
        const step = ir.While.step(node);
        if (step != .nil) try self.checkStmt(step);
        try self.checkStmt(ir.While.body(node));
        self.scope = prev;
        const else_ = ir.While.@"else"(node);
        if (else_ != .nil) try self.checkStmt(else_);
    }

    fn checkFor(self: *Checker, node: Sexp) Error!void {
        const mode = ir.For.mode(node).tag;
        const binding = ir.For.@"var"(node);
        const index_binding = ir.For.index(node);
        const source = ir.For.source(node);

        if (index_binding != .nil and source.isKind(.@"..")) {
            try self.errAt(index_binding, "a range has no index binding; the element is already the position (`for i in a..b`)", .{});
        }

        var elem_ty = self.t().invalid_id;
        if (source.isKind(.@"..")) {
            elem_ty = try self.checkRange(source);
        } else {
            const peeled_source = if (source.isKind(.read)) ir.Read.operand(source) else source;
            const source_ty = try self.synthExpr(source);
            try self.recordType(source, source_ty);
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
        const else_ = ir.For.@"else"(node);
        if (else_ != .nil) try self.checkStmt(else_);
    }

    fn recordType(self: *Checker, node: Sexp, ty: TypeId) Error!void {
        try self.ctx.recordType(node, ty);
    }

    /// `a..b` as a loop source: both bounds integers of one type.
    fn checkRange(self: *Checker, range: Sexp) Error!TypeId {
        const ty = try self.checkNumericOperands(range, "..", .integer);
        const elem = if (ty == self.t().int_literal_id) self.t().int_id else ty;
        if (ty == self.t().int_literal_id) {
            const lo = ir.@"..".left(range);
            const hi = ir.@"..".right(range);
            try self.checkLiteralFits(lo, elem);
            try self.checkLiteralFits(hi, elem);
            try self.ctx.recordType(lo, elem);
            try self.ctx.recordType(hi, elem);
        }
        const r = try self.ctx.intern(.{ .range = elem });
        try self.ctx.recordType(range, r);
        return elem;
    }

    /// The element of `for x in !xs`: a write borrow of each slot. The
    /// source must be a place the loop may write.
    fn writeElement(self: *Checker, source: Sexp, inner_source: Sexp, elem: TypeId) Error!TypeId {
        if (!isFieldPath(inner_source)) {
            try self.errAt(source, "`for x in !xs` writes each element in place; `xs` must be a binding or a field of one", .{});
        } else if (try self.placeThroughShared(inner_source)) {
            try self.errAt(source, "cannot write-iterate through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell(T)` for mutation through shared ownership.", .{});
        } else if (try self.placeThroughReadBorrow(inner_source)) |p| {
            try self.err(p, "cannot write-iterate through a read borrow (`?T`); take a write borrow (`!T`) to mutate", .{});
        } else try self.checkWritable(inner_source, "write-iterate");
        return self.ctx.intern(.{ .borrow_write = elem });
    }

    fn elementTypeForLoop(self: *Checker, source: Sexp, inner_source: Sexp, source_ty: TypeId, mode: ?Tag) Error!TypeId {
        const pos = self.startOf(source);
        if (self.isPoison(source_ty)) return self.t().invalid_id;
        const peeled = sema.unwrapBorrows(self.ctx, source_ty);
        switch (self.ctx.types.get(peeled)) {
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.vec_sym_id and pn.args.len == 1) {
                const elem = pn.args[0];
                const is_resource = switch (self.ctx.types.get(elem)) {
                    .shared, .weak => true,
                    else => false,
                };
                if (is_resource) {
                    if (mode != .read and mode != .write and mode != .move) {
                        try self.err(pos, "resource Vec(T) iteration requires an explicit read borrow; write `for x in ?vec`", .{});
                    }
                    if (!isFieldPath(inner_source)) {
                        try self.err(pos, "resource Vec(T) iteration requires a Vec binding or a field of one as the source; got an expression. Bind the result to a `Vec(T)` local first.", .{});
                    }
                }
                if (mode == .write) return self.writeElement(source, inner_source, elem);
                // `for x in <v` hands each element over.
                if (mode == .move) return elem;
                return if (is_resource) try self.ctx.intern(.{ .borrow_read = elem }) else elem;
            },
            .array => |a| {
                if (mode == .write) return self.writeElement(source, inner_source, a.elem);
                return a.elem;
            },
            .slice, .string => {
                if (mode == .write) {
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

        var cov: MatchCoverage = .{};
        const ArmValue = struct { node: Sexp, ty: TypeId };
        var arm_values: std.ArrayListUnmanaged(ArmValue) = .empty;
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
            const body = ir.Arm.body(arm);
            switch (position) {
                .statement => try self.checkStmt(body),
                .value => {
                    if (result) |r| {
                        if (expected != null) {
                            try self.checkExpr(body, r);
                        } else {
                            const ty = try self.synthExpr(body);
                            result = (try self.unify(r, ty, self.startOf(body))) orelse r;
                            try arm_values.append(self.ctx.allocator, .{ .node = body, .ty = ty });
                        }
                    } else {
                        result = try self.synthExpr(body);
                        if (expected == null) try arm_values.append(self.ctx.allocator, .{ .node = body, .ty = result.? });
                    }
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
                if (!resolve.isWildcardPattern(self.ctx.source, pattern)) {
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
            try self.ctx.recordType(hi_node, if (st == .int) sema.unwrapBorrows(self.ctx, scrutinee) else self.t().int_id);
            if (hi_node.isKind(.neg)) try self.ctx.recordType(ir.Neg.operand(hi_node), if (st == .int) sema.unwrapBorrows(self.ctx, scrutinee) else self.t().int_id);
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
            const sym = self.ctx.symbolOf(b) orelse continue;
            self.ctx.symbols.items[sym].ty = f.ty;
            try self.ctx.recordType(b, f.ty);
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
        if (decl.module_id == null and sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
    }

    // =========================================================================
    // Expressions: synthesis
    // =========================================================================

    fn synthExpr(self: *Checker, e: Sexp) Error!TypeId {
        const ty = try self.synthInner(e);
        try self.ctx.recordType(e, self.canonical(ty));
        return ty;
    }

    /// Literal pseudo-types as the concrete type they default to.
    fn canonical(self: *Checker, ty: TypeId) TypeId {
        if (ty == self.t().int_literal_id) return self.t().int_id;
        if (ty == self.t().float_literal_id) return self.t().float_id;
        return ty;
    }

    fn synthInner(self: *Checker, e: Sexp) Error!TypeId {
        return switch (e) {
            .nil => self.t().void_id,
            .src => self.synthLeaf(e),
            .str => self.t().string_id,
            .tag => self.t().invalid_id,
            .list => blk: {
                if (e.kind() == null) break :blk self.t().invalid_id;
                break :blk self.synthList(e);
            },
        };
    }

    /// A string's escapes: `\n`, `\r`, `\t`, `\\`, `\'`, `\"`, `\xNN`,
    /// and `\u{N...}`.
    fn checkEscapes(self: *Checker, s: []const u8, pos: u32) Error!void {
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
            try self.checkEscapes(s, leaf.src.pos);
            return self.t().string_id;
        }
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return self.t().bool_id;
        if (std.mem.eql(u8, s, "none")) return self.t().none_id;
        if (sema.isFloatLiteralText(s)) return self.t().float_literal_id;
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
            else => return sym.ty,
        }
    }

    /// Resolve an identifier use, record the fact, and diagnose unbound
    /// names and outer locals referenced from inside a closure.
    fn useName(self: *Checker, leaf: Sexp) Error!?SymbolId {
        if (leaf != .src) return null;
        const name = self.text(leaf);
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
                    try self.errAt(leaf, "`{s}` is a local of the enclosing function; capture it to use it inside the closure (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|~{s}|` holds it weakly)", .{ name, name, name, name });
                }
                return id;
            }
            const scope = self.ctx.scopes.items[s];
            if (scope.kind == .lambda) crossed_lambda = true;
            sid = scope.parent;
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
            if (sym.kind == .local and (sym.decl_pos > pos or id == self.pending)) {
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
            .index => self.synthIndex(e),
            .propagate => self.synthPropagate(e),
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
            .@"+", .@"-", .@"*", .@"/", .@"%" => self.checkNumericOperands(e, @tagName(head), .numeric),
            .@"&", .@"|", .@"^" => self.checkNumericOperands(e, @tagName(head), .integer),
            .@"<<", .@">>" => self.synthShift(e, @tagName(head)),
            .@"<", .@">", .@"<=", .@">=" => blk: {
                const ty = try self.checkNumericOperands(e, @tagName(head), .ordered);
                // Two literal operands are compared as `Int`s.
                if (ty == self.t().int_literal_id) {
                    try self.checkLiteralFits(ir.get(e, .left), self.t().int_id);
                    try self.checkLiteralFits(ir.get(e, .right), self.t().int_id);
                }
                break :blk self.t().bool_id;
            },
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
            .enum_lit => blk: {
                const name = self.text(ir.EnumLit.name(e));
                try self.errAt(e, "enum literal `.{s}` needs a known enum type; write `Type.{s}` or annotate the binding", .{ name, name });
                break :blk self.t().invalid_id;
            },
            .lambda => self.synthLambda(e),
            .builtin => self.synthBuiltin(e, null),
            .@"..",
            => blk: {
                try self.errAt(e, "a range `a..b` can only be used as a `for` loop source", .{});
                break :blk self.t().invalid_id;
            },
            .set, .@"while", .@"for", .drop, .@"defer", .@"errdefer", .labeled => blk: {
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

    /// Both operands numeric (or integer) and of one type. Literals adapt
    /// to the other operand; generic parameters record a requirement.
    /// A binary operator node: `(op left right)`.
    fn checkNumericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement) Error!TypeId {
        const ty = try self.numericOperands(e, op, req);
        if (self.isPoison(ty)) return ty;
        if (!(try self.checkDivisor(e.kind().?, ty, ir.get(e, .right)))) return self.t().invalid_id;
        // Constant operands are computed now, so the result must fit.
        if (self.ctx.types.get(ty) == .int) try self.checkLiteralFits(e, ty);
        return ty;
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
        const ty = readValue(self.ctx, try self.synthExpr(left));
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
        const ty = readValue(self.ctx, try self.synthExpr(amount));
        if (self.isPoison(ty)) return false;
        switch (self.ctx.types.get(ty)) {
            .type_var => |tv| try self.require(tv, .integer, self.startOf(amount), op),
            else => if (!sema.isInteger(self.ctx, ty)) {
                try self.errAt(amount, "a shift amount must be an integer; got `{s}`", .{try self.tyName(ty)});
                return false;
            },
        }
        if (ty == self.t().int_literal_id) try self.ctx.recordType(amount, self.t().int_id);
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

    fn constBool(self: *Checker, e: Sexp) ?bool {
        return sema.constBoolOf(self.ctx, e);
    }

    fn numericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement) Error!TypeId {
        const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
        const a = readValue(self.ctx, try self.synthExpr(operands[0]));
        const b = readValue(self.ctx, try self.synthExpr(operands[1]));
        const pos = self.startOf(operands[0]);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().invalid_id;

        const ta = self.ctx.types.get(a);
        const tb = self.ctx.types.get(b);
        if (ta == .type_var or tb == .type_var) {
            const tv = if (ta == .type_var) a else b;
            const other = if (ta == .type_var) b else a;
            const other_ok = other == tv or other == self.t().int_literal_id or (req != .integer and other == self.t().float_literal_id);
            if (!other_ok) {
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
                try self.errAt(operands[i], "operator `{s}` requires {s} operands; got `{s}`", .{ op, if (want_int) "integer" else "numeric", try self.tyName(ty) });
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
        const ty = readValue(self.ctx, try self.synthExpr(operand));
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
        // A contextual operand (`.red`, `none`) takes the other side's type.
        if (isContextual(self.ctx.source, l) and !isContextual(self.ctx.source, r)) {
            try self.checkExpr(l, try self.synthExpr(r));
            return self.t().bool_id;
        }
        if (isContextual(self.ctx.source, r)) {
            try self.checkExpr(r, try self.synthExpr(l));
            return self.t().bool_id;
        }
        const a = readValue(self.ctx, try self.synthExpr(l));
        const b = readValue(self.ctx, try self.synthExpr(r));
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
        if (sema.isNumeric(self.ctx, a) and sema.isNumeric(self.ctx, b)) {
            _ = try self.checkNumericComparison(l, r, a, b, op);
            return self.t().bool_id;
        }
        const ta = self.ctx.types.get(a);
        const tb = self.ctx.types.get(b);
        if (ta == .type_var or tb == .type_var) {
            if (a != b and !(ta == .type_var and sema.isNumeric(self.ctx, b)) and !(tb == .type_var and sema.isNumeric(self.ctx, a))) {
                try self.errAt(l, "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
                return self.t().bool_id;
            }
            const tv = if (ta == .type_var) ta.type_var else tb.type_var;
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

    fn checkEquatable(self: *Checker, ty: TypeId, node: Sexp, op: []const u8) Error!void {
        if (self.isPoison(ty)) return;
        const ok = switch (self.ctx.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string, .any_error => true,
            .optional => |inner| satisfies(self.ctx, inner, .equatable),
            .nominal, .imported_nominal => sema.isPlainEnum(self.ctx, ty),
            .type_var => |tv| blk: {
                try self.require(tv, .equatable, self.startOf(node), op);
                break :blk true;
            },
            else => false,
        };
        if (!ok) {
            try self.errAt(node, "`{s}` is not defined for `{s}`", .{ op, try self.tyName(ty) });
        }
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
            try self.errAt(left, "`??` on an optional `{s}` would copy an owning handle out of it; optionals of resource handles can only be compared with `none`", .{try self.tyName(opt)});
            return self.t().invalid_id;
        }
        const result = expected orelse inner;
        if (expected != null and !compatible(self.ctx, inner, result)) {
            try self.errAt(left, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(result), try self.tyName(inner) });
        }
        try self.checkExpr(right, inner);
        return inner;
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
        _ = expected;
        try self.checkExpr(handler, inner);
        return inner;
    }

    /// `e!`: the value of fallible `e`; its failure goes to `fail_to`.
    fn synthPropagate(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Propagate.value(e);
        switch (self.fail_to) {
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
        const inner = try self.synthOperand(operand);
        if (self.isPoison(inner)) return inner;
        if (kind == .write) {
            if (try self.placeThroughShared(operand)) {
                try self.errAt(operand, "cannot write-borrow through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell(T)` for mutation through shared ownership.", .{});
                return self.t().invalid_id;
            }
            if (try self.placeThroughReadBorrow(operand)) |pos| {
                try self.err(pos, "cannot write-borrow through a read borrow (`?T`); take a write borrow (`!T`) to mutate", .{});
                return self.t().invalid_id;
            }
            try self.checkWritable(operand, "write-borrow");
        }
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

    fn synthShare(self: *Checker, e: Sexp) Error!TypeId {
        const operand = ir.Share.operand(e);
        if (operand.isKind(.lambda)) return self.ownedClosure(operand, null);
        const inner = try self.synthExpr(operand);
        if (self.isPoison(inner)) return inner;
        if (self.ctx.types.get(inner) == .function) {
            try self.errAt(operand, "`*` makes an owned closure only from a closure literal: `*|...| body`", .{});
            return self.t().invalid_id;
        }
        if (self.ctx.types.get(inner) == .shared) {
            try self.errAt(operand, "this value is already a shared handle `{s}`; `*` would nest handles. Clone it with `+x` for another handle", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        return self.ctx.intern(.{ .shared = inner });
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
        const value = sema.unwrapBorrows(self.ctx, inner);
        switch (self.ctx.types.get(value)) {
            .shared, .weak => return value,
            // An optional handle clones to another optional handle.
            .optional => |o| switch (self.ctx.types.get(o)) {
                .shared, .weak => return value,
                else => {},
            },
            else => {},
        }
        if ((try self.ownsResource(inner, self.startOf(operand), "clones a value"))) {
            try self.errAt(operand, "`+x` cannot clone a `{s}`; only `*T` and `~T` handles (or optionals of them) and plain values can be cloned", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        return sema.unwrapBorrows(self.ctx, inner);
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

        if (obj == .src) {
            if (try self.qualifiedMember(obj, field_node)) |ty| return ty;
        }

        // `module.Enum.variant`
        if (try self.qualifiedImportedType(obj)) |found| return self.importedTypeMember(found, field, pos);

        const obj_ty = try self.synthOperand(obj);
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
        const pty = self.ctx.types.get(peeled);

        switch (pty) {
            .optional => {
                try self.err(pos, "cannot access `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ field, try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            .array, .slice, .string => if (std.mem.eql(u8, field, "len")) return self.t().int_id,
            .imported_nominal => |in| return self.importedField(in, field, pos),
            .type_var => {
                try self.err(pos, "a generic parameter `{s}` has no fields; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            else => {},
        }

        if (std.mem.eql(u8, field, "value")) {
            if (cellElementType(self.ctx, obj_ty)) |elem| {
                if ((try self.ownsResource(elem, pos, "reads `cell.value`"))) {
                    try self.err(pos, "`cell.value` reads `T` by value but `T = {s}` has drop glue; a copy would alias the cell's owned value. Use `cell.replace(<new)` to swap-and-yield the old value.", .{try self.tyName(elem)});
                    return self.t().invalid_id;
                }
            }
        }

        if (try sema.lookupDataField(self.ctx, obj_ty, field)) |f| return f.ty;

        const owner = sema.nominalSymOfReceiver(self.ctx, peeled);
        if (sema.hasMethodNamed(self.ctx, obj_ty, field)) {
            try self.err(pos, "method `{s}` on type `{s}` must be called; a bare method reference is not supported", .{ field, if (owner) |o| self.ctx.symbols.items[o].name else try self.tyName(peeled) });
            return self.t().invalid_id;
        }
        if (owner) |o| {
            const sym = self.ctx.symbols.items[o];
            if (sym.fields == null) {
                try self.err(pos, "opaque type `{s}` has no accessible fields", .{sym.name});
            } else {
                try self.err(pos, "no field `{s}` on type `{s}`", .{ field, sym.name });
                if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
            }
            return self.t().invalid_id;
        }
        try self.err(pos, "type `{s}` has no field `{s}`", .{ try self.tyName(obj_ty), field });
        return self.t().invalid_id;
    }

    /// `Type.variant`, `Type.method`, or `module.name`. Null when `obj`
    /// is an ordinary value.
    fn qualifiedMember(self: *Checker, obj: Sexp, field_node: Sexp) Error!?TypeId {
        const name = self.text(obj);
        const id = self.lookupQuiet(obj) orelse return null;
        const sym = self.ctx.symbols.items[id];
        const field = self.text(field_node);
        const pos = srcPos(field_node, 0);
        switch (sym.kind) {
            .nominal_type, .generic_type => {
                try self.ctx.recordName(obj, id);
                const members = sym.fields orelse {
                    try self.err(pos, "opaque type `{s}` has no members", .{sym.name});
                    return self.t().invalid_id;
                };
                for (members) |m| {
                    if (!std.mem.eql(u8, m.name, field)) continue;
                    if (m.is_method) {
                        try self.err(pos, "method `{s}.{s}` must be called; a bare method reference is not supported", .{ sym.name, field });
                        return self.t().invalid_id;
                    }
                    if (m.is_variant and sym.kind == .nominal_type) {
                        if (m.payload != null and m.payload.?.len > 0) {
                            try self.err(pos, "variant `{s}.{s}` carries a payload; construct it with `{s}.{s}(...)`", .{ sym.name, field, sym.name, field });
                            return self.t().invalid_id;
                        }
                        return try self.ctx.intern(.{ .nominal = id });
                    }
                    if (m.is_variant) {
                        try self.err(pos, "variant of generic enum `{s}` needs its type; write `.{s}` where a `{s}(...)` is expected", .{ sym.name, field, sym.name });
                        return self.t().invalid_id;
                    }
                    break;
                }
                try self.err(pos, "no member `{s}` on type `{s}`", .{ field, sym.name });
                if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
                return self.t().invalid_id;
            },
            .module => {
                try self.ctx.recordName(obj, id);
                const found = (try self.foreignSymbol(id, field, pos)) orelse return self.t().invalid_id;
                if (found.sym.kind == .nominal_type) {
                    try self.err(pos, "`{s}.{s}` is a type, not a value", .{ name, field });
                    return self.t().invalid_id;
                }
                return try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
            },
            else => return null,
        }
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

    /// `module.Type` written as the object of a member access: the type,
    /// when it is one.
    fn qualifiedImportedType(self: *Checker, obj: Sexp) Error!?Foreign {
        if (!obj.isKind(.member) or ir.Member.object(obj) != .src) return null;
        const module = ir.Member.object(obj);
        const name = ir.Member.name(obj);
        const id = self.lookupQuiet(module) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        try self.ctx.recordName(module, id);
        const found = (try self.foreignSymbol(id, self.text(name), name.src.pos)) orelse return null;
        if (found.sym.kind != .nominal_type) return null;
        return found;
    }

    fn importedTypeOf(self: *Checker, found: Foreign) Error!TypeId {
        return self.ctx.intern(.{ .imported_nominal = .{ .module_id = found.module_id, .sym_id = found.id } });
    }

    /// `module.Enum.variant` (a bare variant).
    fn importedTypeMember(self: *Checker, found: Foreign, field: []const u8, pos: u32) Error!TypeId {
        for (found.sym.fields orelse &.{}) |m| {
            if (!std.mem.eql(u8, m.name, field)) continue;
            if (m.is_method) {
                try self.err(pos, "method `{s}.{s}` must be called; a bare method reference is not supported", .{ found.sym.name, field });
                return self.t().invalid_id;
            }
            if (m.is_variant) {
                if (m.payload != null and m.payload.?.len > 0) {
                    try self.err(pos, "variant `{s}.{s}` carries a payload; construct it with `{s}.{s}(...)`", .{ found.sym.name, field, found.sym.name, field });
                    return self.t().invalid_id;
                }
                return self.importedTypeOf(found);
            }
            break;
        }
        try self.err(pos, "no member `{s}` on type `{s}`", .{ field, found.sym.name });
        return self.t().invalid_id;
    }

    /// `module.Type.function(args)` or `module.Enum.variant(payload)`.
    fn importedAssociatedCall(self: *Checker, found: Foreign, name: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
        for (found.sym.fields orelse &.{}) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (m.is_method and !m.is_drop_method) {
                const local = try sema.importType(self.ctx, found.ctx, m.ty, found.module_id);
                const fty = self.ctx.types.get(local);
                if (fty != .function) break;
                if (m.receiver != .none) {
                    try self.err(pos, "method `{s}` takes `self`; call it on a value (`x.{s}(...)`)", .{ name, name });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.noteCallee(fty.function);
                var params = self.methodParams(m, false);
                params.source = found.ctx.source;
                try self.checkArgs(args, fty.function, params, name, pos);
                return fty.function.returns;
            }
            if (m.is_variant) {
                const ty = try self.importedTypeOf(found);
                const resolved = (try sema.lookupVariant(self.ctx, ty, name)) orelse break;
                if (resolved.payload.len == 0) {
                    try self.err(pos, "variant `{s}.{s}` takes no payload", .{ found.sym.name, name });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.checkFieldArgs(args, resolved.payload, .{ .owner = name, .decl_pos = sema.builtin_decl_pos, .pos = pos, .kind = .variant });
                return ty;
            }
            break;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ name, found.sym.name });
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    /// A public module-level symbol of an imported module.
    fn foreignSymbol(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32) Error!?Foreign {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const origin = self.ctx.module_refs.get(module_sym) orelse {
            try self.err(pos, "module `{s}` was not loaded", .{module_name});
            return null;
        };
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        const fid = foreign.lookupInScopeOnly(1, name) orelse {
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

    fn importedField(self: *Checker, in: sema.ImportedNominal, field: []const u8, pos: u32) Error!TypeId {
        const foreign = self.ctx.foreign_semas.get(in.module_id) orelse return self.t().invalid_id;
        const sym = foreign.symbols.items[in.sym_id];
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant or !std.mem.eql(u8, f.name, field)) continue;
            return sema.importType(self.ctx, foreign, f.ty, in.module_id);
        }
        try self.err(pos, "no field `{s}` on type `{s}`", .{ field, sym.name });
        return self.t().invalid_id;
    }

    fn synthIndex(self: *Checker, e: Sexp) Error!TypeId {
        const object = ir.Index.object(e);
        const index = ir.Index.index(e);
        const obj_ty = try self.synthOperand(object);
        if (index.isKind(.@"..")) {
            try self.errAt(index, "slicing `xs[a..b]` is not supported yet", .{});
            return self.t().invalid_id;
        }
        const idx_ty = try self.synthExpr(index);
        if (!self.isPoison(idx_ty) and !sema.isInteger(self.ctx, idx_ty)) {
            try self.errAt(index, "an index must be an integer; got `{s}`", .{try self.tyName(idx_ty)});
        } else if (idx_ty == self.t().int_literal_id) {
            try self.ctx.recordType(index, self.t().int_id);
            try self.checkLiteralFits(index, self.t().int_id);
        }
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .array => |a| {
                // The length is part of the type, so a constant index is
                // checked now.
                if (self.constInt(index)) |i| if (i < 0 or i >= a.len) {
                    try self.errAt(index, "index `{d}` is out of bounds for an array of length {d}", .{ i, a.len });
                };
                return a.elem;
            },
            .slice => |s| return s.elem,
            .string => return self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.vec_sym_id and pn.args.len == 1) {
                if ((try self.ownsResource(pn.args[0], self.startOf(object), "copies an element out of a Vec"))) {
                    try self.errAt(object, "indexing a `{s}` would copy an owning handle out of the Vec; iterate with `for x in ?v` instead", .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                return pn.args[0];
            },
            else => {},
        }
        try self.errAt(object, "cannot index a value of type `{s}`", .{try self.tyName(obj_ty)});
        return self.t().invalid_id;
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
        return self.ctx.intern(.{ .array = .{ .elem = concrete, .len = elems.len } });
    }

    fn checkArray(self: *Checker, node: Sexp, expected: TypeId) Error!bool {
        const et = self.ctx.types.get(expected);
        if (et != .array) return false;
        const elems = ir.Array.elems(node);
        if (elems.len != et.array.len) {
            try self.errAt(node, "array literal has {d} element{s}; `{s}` needs {d}", .{ elems.len, plural(elems.len), try self.tyName(expected), et.array.len });
        }
        for (elems) |e| try self.checkExpr(e, et.array.elem);
        try self.ctx.recordType(node, expected);
        return true;
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
        const callee = ir.Call.callee(node);
        const args = ir.Call.args(node);

        if (callee == .src) {
            const name = self.text(callee);
            const id = self.lookupQuiet(callee) orelse {
                if (std.mem.eql(u8, name, "print")) return self.checkPrint(args);
                if (resolve.isNumericTypeName(name)) {
                    var r = self.resolver();
                    return self.checkConversion(try r.resolveType(callee), name, args, callee.src.pos);
                }
                try self.errAt(callee, "use of unbound name `{s}`", .{name});
                try self.synthArgs(args);
                return self.t().invalid_id;
            };
            const sym_id = (try self.useName(callee)).?;
            _ = id;
            const sym = self.ctx.symbols.items[sym_id];
            if (sym.kind != .nominal_type and sym.kind != .generic_type and sym.kind != .type_alias and sym.kind != .module) {
                try self.ctx.recordType(callee, sym.ty);
            }
            switch (sym.kind) {
                .function, .@"extern" => {
                    const fty = self.ctx.types.get(sym.ty);
                    if (fty != .function) {
                        try self.errAt(callee, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(sym.ty) });
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    }
                    if (sym.kind == .@"extern" and self.raw_depth == 0) {
                        try self.errAt(callee, "call to extern function `{s}` requires `raw` block; extern functions are the FFI boundary and bypass Rig's ownership and effect checks", .{name});
                    }
                    try self.checkArgs(args, fty.function, self.paramsOf(sym_id), name, callee.src.pos);
                    return fty.function.returns;
                },
                .nominal_type => return self.construct(sym_id, args, callee.src.pos, TypeSubst.empty, null),
                .type_alias => {
                    try self.errAt(callee, "`{s}` is a type alias for `{s}` and cannot be called as a constructor; construct the aliased type directly", .{ name, try self.tyName(sym.ty) });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                .generic_type => {
                    // The type arguments come from the fields' values.
                    if (sym_id == self.ctx.vec_sym_id) {
                        try self.errAt(callee, "`Vec()` needs its element type from where it goes; write `v: Vec(T) = Vec()`", .{});
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    }
                    const subst = (try self.inferTypeArgs(sym_id, args, .{ .fields = sym.fields orelse &.{} }, callee.src.pos)) orelse {
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    };
                    _ = try self.instantiate(sym_id, subst.args, callee.src.pos);
                    return self.construct(sym_id, args, callee.src.pos, subst, null);
                },
                .module => {
                    try self.errAt(callee, "module `{s}` cannot be called", .{name});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                else => return self.callValue(callee, sym.ty, args, name),
            }
        }

        if (callee.isKind(.member)) return self.synthMemberCall(callee, args);

        if (callee.isKind(.enum_lit)) {
            try self.errAt(callee, "variant `.{s}(...)` needs a known enum type; annotate the binding", .{self.text(ir.EnumLit.name(callee))});
            try self.synthArgs(args);
            return self.t().invalid_id;
        }

        const callee_ty = try self.synthOperand(callee);
        return self.callValue(callee, callee_ty, args, "expression");
    }

    /// Call a value: a function-typed binding, a closure, or an owned
    /// closure handle.
    fn callValue(self: *Checker, callee: Sexp, ty: TypeId, args: []const Sexp, name: []const u8) Error!TypeId {
        const pos = self.startOf(callee);
        if (self.isPoison(ty)) {
            try self.synthArgs(args);
            return self.t().invalid_id;
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
        try self.err(pos, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(ty) });
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    fn synthArgs(self: *Checker, args: []const Sexp) Error!void {
        for (args) |a| {
            if (a.isKind(.kwarg)) {
                _ = try self.synthExpr(ir.Kwarg.value(a));
            } else _ = try self.synthExpr(a);
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
        const from = readValue(self.ctx, try self.synthExpr(arg));
        if (self.isPoison(from)) return target;
        if (!sema.isNumeric(self.ctx, from)) {
            try self.errAt(arg, "`{s}(x)` converts a number; `x` has type `{s}`", .{ name, try self.tyName(from) });
            return target;
        }
        const tt = self.ctx.types.get(target);
        if (tt != .int) return target;
        if (sema.isInteger(self.ctx, from)) {
            try self.checkLiteralFits(arg, target);
            return target;
        }
        // A constant float: its integer part must fit.
        try self.checkFloatFits(arg, target);
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
            // Literal values print as `Int` / `Float`.
            if (ty == self.t().int_literal_id) {
                try self.ctx.recordType(a, self.t().int_id);
                try self.checkLiteralFits(a, self.t().int_id);
            } else if (ty == self.t().float_literal_id) try self.ctx.recordType(a, self.t().float_id);
            switch (self.ctx.types.get(ty)) {
                .void => try self.errAt(a, "`print` needs a value; this expression produces no value (`Void`)", .{}),
                .none_literal => try self.errAt(a, "cannot print a bare `none`", .{}),
                .function => try self.errAt(a, "cannot print a function", .{}),
                else => {},
            }
        }
        return self.t().void_id;
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

    fn paramsOf(self: *Checker, sym_id: SymbolId) ParamInfo {
        const sym = self.ctx.symbols.items[sym_id];
        return .{ .names = sym.param_names, .defaults = sym.param_defaults, .source = self.ctx.source };
    }

    fn methodParams(self: *Checker, f: Field, skip_self: bool) ParamInfo {
        var names = f.param_names;
        var defaults = f.param_defaults;
        if (skip_self) {
            if (names) |n| if (n.len > 0) {
                names = n[1..];
            };
            if (defaults) |d| if (d.len > 0) {
                defaults = d[1..];
            };
        }
        return .{ .names = names, .defaults = defaults, .source = self.ctx.source };
    }

    /// Arguments against a signature: arity, types, keyword arguments
    /// by parameter name, defaults for omitted parameters, and
    /// compile-time-known values for `pre` parameters. A call that uses
    /// keywords or defaults records its argument slots.
    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info: ParamInfo, callee: []const u8, pos: u32) Error!void {
        const call = self.current_call;
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
            try self.checkArg(a, f, i, callee);
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
            try self.checkArg(ir.Kwarg.value(kw), f, idx, callee);
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

    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, callee: []const u8) Error!void {
        try self.checkExpr(arg, f.params[i]);
        if (f.isPre(i) and !self.isComptimeKnown(arg)) {
            try self.errAt(arg, "argument {d} of `{s}` is a `pre` parameter and must be known at compile time; pass a literal, an enum value, a `pre` parameter, or a `=!` binding of one", .{ i + 1, callee });
        }
    }

    /// Values Zig can evaluate at compile time.
    fn isComptimeKnown(self: *Checker, e: Sexp) bool {
        switch (e) {
            .src => {
                const s = self.text(e);
                if (isLiteralText(s)) return true;
                const id = self.ctx.symbolOf(e) orelse (self.lookupQuiet(e) orelse return false);
                return self.ctx.symbols.items[id].flags.comptime_known;
            },
            .list => {
                const h = e.kind() orelse return false;
                return switch (h) {
                    .enum_lit => true,
                    .neg, .not => self.isComptimeKnown(ir.get(e, .operand)),
                    .@"+", .@"-", .@"*", .@"/", .@"%", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or" => self.isComptimeKnown(ir.get(e, .left)) and self.isComptimeKnown(ir.get(e, .right)),
                    .member => ir.Member.object(e) == .src and blk: {
                        const id = self.lookupQuiet(ir.Member.object(e)) orelse break :blk false;
                        break :blk self.ctx.symbols.items[id].kind == .nominal_type;
                    },
                    else => false,
                };
            },
            else => return false,
        }
    }

    /// Construct a struct (`User(name: ...)`) or, with `variant`, an enum
    /// payload variant. Field types go through `subst` (generic
    /// constructors) or are imported from `foreign`.
    fn construct(self: *Checker, sym_id: SymbolId, args: []const Sexp, pos: u32, subst: TypeSubst, foreign: ?ForeignFields) Error!TypeId {
        const sym = if (foreign) |fo| fo.ctx.symbols.items[sym_id] else self.ctx.symbols.items[sym_id];
        const result = if (foreign) |fo|
            try self.ctx.intern(.{ .imported_nominal = .{ .module_id = fo.module_id, .sym_id = sym_id } })
        else if (subst.isEmpty())
            try self.ctx.intern(.{ .nominal = sym_id })
        else
            try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = subst.args } });
        const fields = sym.fields orelse {
            try self.err(pos, "opaque type `{s}` cannot be constructed", .{sym.name});
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        var is_enum = false;
        for (fields) |f| {
            if (f.is_variant) is_enum = true;
        }
        if (is_enum) {
            try self.err(pos, "`{s}` is an enum; construct a variant with `{s}.name` or `.name(...)`", .{ sym.name, sym.name });
            try self.synthArgs(args);
            return self.t().invalid_id;
        }
        try self.checkFieldArgs(args, fields, .{ .owner = sym.name, .decl_pos = sym.decl_pos, .pos = pos, .subst = subst, .foreign = foreign, .kind = .constructor });
        return result;
    }

    const ForeignFields = struct { ctx: *SemContext, module_id: u32 };

    const FieldArgs = struct {
        owner: []const u8,
        decl_pos: u32,
        pos: u32,
        subst: TypeSubst = TypeSubst.empty,
        foreign: ?ForeignFields = null,
        kind: enum { constructor, variant },
    };

    /// Keyword arguments against named fields: each names a real field
    /// once, and every field without a default is given. Variants also
    /// accept all-positional payloads.
    fn checkFieldArgs(self: *Checker, args: []const Sexp, fields: []const Field, info: FieldArgs) Error!void {
        var positional: usize = 0;
        for (args) |a| {
            if (!a.isKind(.kwarg)) positional += 1;
        }
        const noun = if (info.kind == .constructor) "constructor of" else "variant";
        if (positional > 0) {
            if (info.kind == .variant and positional == args.len) {
                var n: usize = 0;
                for (fields) |f| {
                    if (!f.is_method and !f.is_variant) n += 1;
                }
                if (args.len != n) {
                    try self.err(info.pos, "variant `{s}` expects {d} payload field{s}, got {d}", .{ info.owner, n, plural(n), args.len });
                    try self.synthArgs(args);
                    return;
                }
                var i: usize = 0;
                for (fields) |f| {
                    if (f.is_method or f.is_variant) continue;
                    try self.checkExpr(args[i], try self.fieldType(f, info));
                    i += 1;
                }
                return;
            }
            try self.err(info.pos, "fields of `{s}` are set by name: `{s}(field: value)`", .{ info.owner, info.owner });
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
            const f = for (fields) |f| {
                if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, fname)) break f;
            } else {
                try self.err(fpos, "no field `{s}` on {s} `{s}`", .{ fname, if (info.kind == .constructor) "type" else "variant", info.owner });
                if (info.foreign == null and info.decl_pos != sema.builtin_decl_pos and info.decl_pos != 0) try self.note(info.decl_pos, "`{s}` declared here", .{info.owner});
                _ = try self.synthExpr(value);
                continue;
            };
            try self.checkExpr(value, try self.fieldType(f, info));
        }
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.has_default or seen.contains(f.name)) continue;
            if (info.kind == .constructor) {
                try self.err(info.pos, "constructor of `{s}` is missing field `{s}`", .{ info.owner, f.name });
            } else {
                try self.err(info.pos, "variant `{s}` is missing field `{s}`", .{ info.owner, f.name });
            }
            if (info.foreign == null and f.decl_pos != sema.builtin_decl_pos) try self.note(f.decl_pos, "field `{s}` declared here", .{f.name});
        }
    }

    fn fieldType(self: *Checker, f: Field, info: FieldArgs) Error!TypeId {
        if (info.foreign) |fo| return sema.importType(self.ctx, fo.ctx, f.ty, fo.module_id);
        return sema.substituteType(self.ctx, f.ty, info.subst);
    }

    // ---- method calls -----------------------------------------------------------

    /// Method calls also record the callee `(member obj name)` node's
    /// type: the resolved method's signature.
    /// A call whose callee is `(member obj name)`.
    fn synthMemberCall(self: *Checker, callee: Sexp, args: []const Sexp) Error!TypeId {
        const saved = self.callee_node;
        self.callee_node = callee;
        defer self.callee_node = saved;
        return self.synthMemberCallInner(callee, args);
    }

    fn noteCallee(self: *Checker, f: FunctionType) Error!void {
        try self.noteCalleeType(try self.ctx.intern(.{ .function = f }));
    }

    fn noteCalleeType(self: *Checker, ty: TypeId) Error!void {
        if (self.callee_node) |n| try self.ctx.recordType(n, ty);
    }

    fn synthMemberCallInner(self: *Checker, callee: Sexp, args: []const Sexp) Error!TypeId {
        const obj = ir.Member.object(callee);
        const name_node = ir.Member.name(callee);
        const method = self.text(name_node);
        const pos = srcPos(name_node, self.startOf(obj));

        if (obj == .src) {
            if (self.lookupQuiet(obj)) |id| {
                const sym = self.ctx.symbols.items[id];
                switch (sym.kind) {
                    .module => {
                        try self.ctx.recordName(obj, id);
                        return self.crossModuleCall(id, method, pos, args);
                    },
                    .nominal_type, .generic_type => {
                        try self.ctx.recordName(obj, id);
                        return self.associatedCall(obj, id, method, pos, args);
                    },
                    else => {},
                }
            }
        }

        if (try self.qualifiedImportedType(obj)) |found| return self.importedAssociatedCall(found, method, pos, args);

        // A consuming (`self: Self`) method may take a temporary; any
        // other receiver must already have an owner.
        const obj_ty = try self.synthExpr(obj);
        if (self.isPoison(obj_ty)) {
            try self.synthArgs(args);
            return obj_ty;
        }

        if (std.mem.eql(u8, method, "upgrade")) {
            switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, obj_ty))) {
                .weak => |inner| {
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
                    try self.err(pos, "`upgrade` is only available on weak handles (`~T`); receiver here is a shared handle (`*T`). Use `~rc` to obtain a weak reference, then `.upgrade()` on the weak.", .{});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                else => {},
            }
        }

        const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .optional => {
                try self.err(pos, "cannot call `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ method, try self.tyName(peeled) });
                try self.synthArgs(args);
                return self.t().invalid_id;
            },
            .imported_nominal => |in| return self.importedMethodCall(obj, obj_ty, in, method, pos, args),
            .type_var => {
                try self.err(pos, "a generic parameter `{s}` has no methods; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
                try self.synthArgs(args);
                return self.t().invalid_id;
            },
            else => {},
        }

        const resolved = (try sema.lookupMethod(self.ctx, obj_ty, method)) orelse {
            // A data field holding a closure handle is called like one.
            if (try sema.lookupDataField(self.ctx, obj_ty, method)) |f| {
                if (sema.ownedClosureFn(self.ctx, f.ty) != null) {
                    try self.rejectResourceTemporary(obj, obj_ty);
                    try self.noteCalleeType(f.ty);
                    return self.callValue(callee, f.ty, args, method);
                }
            }
            if (sema.nominalSymOfReceiver(self.ctx, peeled)) |owner| {
                const sym = self.ctx.symbols.items[owner];
                try self.err(pos, "no method `{s}` on type `{s}`", .{ method, sym.name });
                if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
            } else {
                try self.err(pos, "type `{s}` has no method `{s}`", .{ try self.tyName(obj_ty), method });
            }
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        const owner = self.ctx.symbols.items[resolved.nominal_sym];
        try self.noteCallee(resolved.fn_ty);
        if (resolved.receiver != .value) try self.rejectResourceTemporary(obj, obj_ty);

        // A `?self` method may change a Cell the value holds; a loop or
        // match binding is only a copy of it.
        if (resolved.nominal_sym != self.ctx.cell_sym_id and resolved.receiver == .read and sema.holdsCellByValue(self.ctx, obj_ty)) {
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
                    if ((try self.ownsResource(elem, pos, "copies out with `Cell.get` a value"))) {
                        try self.err(pos, "`Cell.get` returns `T` by value but `T = {s}` has drop glue; a copy would alias the cell's owned value. Use `cell.replace(<new)` to swap-and-yield the old value.", .{try self.tyName(elem)});
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    }
                }
            }
        }
        // `pop` removes the element, so it hands over ownership; `get`
        // would copy it out of the Vec.
        if (resolved.nominal_sym == self.ctx.vec_sym_id and std.mem.eql(u8, method, "get")) {
            if (resolved.fn_ty.returns != self.t().invalid_id) {
                const elem = self.ctx.types.get(resolved.fn_ty.returns).optional;
                if ((try self.ownsResource(elem, pos, "copies an element out of a Vec"))) {
                    try self.err(pos, "`Vec.{s}` would copy an owning handle out of a `Vec` of `{s}`; iterate with `for x in ?v` instead", .{ method, try self.tyName(elem) });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
            }
        }

        if (resolved.receiver == .none) {
            try self.err(pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{ method, owner.name, method });
            try self.synthArgs(args);
            return resolved.fn_ty.returns;
        }
        try self.checkReceiverMode(obj, resolved.receiver, classifyReceiverType(self.ctx, obj_ty, resolved.nominal_sym), method, pos);
        const rest: FunctionType = .{
            .params = resolved.fn_ty.params[1..],
            .returns = resolved.fn_ty.returns,
            .is_sub = resolved.fn_ty.is_sub,
            .pre_mask = resolved.fn_ty.pre_mask >> 1,
        };
        try self.checkArgs(args, rest, self.methodParams(resolved.field, true), method, pos);
        return resolved.fn_ty.returns;
    }

    /// `Type.method(args)` or `Type.variant(payload)`.
    fn associatedCall(self: *Checker, obj: Sexp, sym_id: SymbolId, name: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
        const sym = self.ctx.symbols.items[sym_id];
        const members = sym.fields orelse {
            try self.err(pos, "opaque type `{s}` has no members", .{sym.name});
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        for (members) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (m.is_method and !m.is_drop_method) {
                const fty = self.ctx.types.get(m.ty);
                if (fty != .function) break;
                var f = fty.function;
                if (sym.kind == .generic_type) {
                    // The type's arguments come from the call's arguments.
                    const subst = (try self.inferTypeArgs(sym_id, args, .{ .params = .{ .params = f.params, .names = m.param_names } }, pos)) orelse {
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    };
                    const inst = try self.instantiate(sym_id, subst.args, pos);
                    try self.ctx.recordType(obj, inst);
                    const sub_ty = try sema.substituteType(self.ctx, m.ty, subst);
                    f = self.ctx.types.get(sub_ty).function;
                }
                try self.noteCallee(f);
                try self.checkArgs(args, f, self.methodParams(m, false), name, pos);
                return f.returns;
            }
            if (m.is_variant) {
                const payload = m.payload orelse &.{};
                if (payload.len == 0) {
                    try self.err(pos, "variant `{s}.{s}` takes no payload", .{ sym.name, name });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                if (sym.kind == .generic_type) {
                    const subst = (try self.inferTypeArgs(sym_id, args, .{ .fields = payload }, pos)) orelse {
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    };
                    const inst = try self.instantiate(sym_id, subst.args, pos);
                    try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .pos = pos, .subst = subst, .kind = .variant });
                    return inst;
                }
                try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .pos = pos, .kind = .variant });
                return self.ctx.intern(.{ .nominal = sym_id });
            }
            break;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ name, sym.name });
        if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    /// Where an inferred generic's arguments are matched: the fields a
    /// constructor or variant fills, or an associated function's
    /// parameters (with their names, for keyword arguments).
    const InferFrom = union(enum) {
        fields: []const Field,
        params: struct { params: []const TypeId, names: ?[]const []const u8 },
    };

    /// The type arguments of generic `sym_id` that make `args` fit: each
    /// argument's type is matched against the field or parameter it
    /// fills, binding the type parameters that appear there. A literal
    /// binds its default type (`Int`, `Float`). Null, after a diagnostic,
    /// when some parameter is left unbound.
    fn inferTypeArgs(self: *Checker, sym_id: SymbolId, args: []const Sexp, from: InferFrom, pos: u32) Error!?TypeSubst {
        const sym = self.ctx.symbols.items[sym_id];
        const params = sym.type_params orelse &.{};
        const bound = try self.ctx.arena.allocator().alloc(TypeId, params.len);
        @memset(bound, sema.type_invalid);
        var positional: usize = 0;
        for (args) |a| {
            var value = a;
            var pattern: ?TypeId = null;
            if (a.isKind(.kwarg)) {
                value = ir.Kwarg.value(a);
                const kname = self.text(ir.Kwarg.name(a));
                pattern = switch (from) {
                    .fields => |fs| for (fs) |f| {
                        if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, kname)) break f.ty;
                    } else null,
                    .params => |p| blk: {
                        const names = p.names orelse break :blk null;
                        for (names, 0..) |n, j| {
                            if (std.mem.eql(u8, n, kname) and j < p.params.len) break :blk p.params[j];
                        }
                        break :blk null;
                    },
                };
            } else {
                defer positional += 1;
                pattern = switch (from) {
                    .fields => |fs| blk: {
                        var n: usize = 0;
                        for (fs) |f| {
                            if (f.is_method or f.is_variant) continue;
                            if (n == positional) break :blk f.ty;
                            n += 1;
                        }
                        break :blk null;
                    },
                    .params => |p| if (positional < p.params.len) p.params[positional] else null,
                };
            }
            const pat = pattern orelse continue;
            if (!sema.containsTypeVar(self.ctx, pat)) continue;
            const actual = try self.synthQuiet(value);
            self.bindTypeVars(pat, actual, params, bound, 0);
        }
        for (params, bound) |p, b| {
            if (b != sema.type_invalid) continue;
            try self.err(pos, "cannot infer `{s}` for `{s}` from the arguments; give the type where the value goes (`x: {s}(...) = ...`)", .{ self.ctx.symbols.items[p].name, sym.name, sym.name });
            return null;
        }
        return .{ .params = params, .args = bound };
    }

    /// Bind the type parameters in `pattern` so that it matches `actual`.
    /// The first binding of a parameter wins; a later argument that does
    /// not fit it is reported when the arguments are checked.
    fn bindTypeVars(self: *Checker, pattern: TypeId, actual: TypeId, params: []const SymbolId, bound: []TypeId, depth: u8) void {
        if (depth > 32 or self.isPoison(actual)) return;
        const a = self.ctx.types.get(actual);
        switch (self.ctx.types.get(pattern)) {
            .type_var => |tv| {
                const value = self.canonical(readValue(self.ctx, actual));
                switch (self.ctx.types.get(value)) {
                    .none_literal, .noreturn, .void => return,
                    else => {},
                }
                for (params, 0..) |p, i| {
                    if (p == tv and bound[i] == sema.type_invalid) bound[i] = value;
                }
            },
            .optional => |pi| if (a == .optional) self.bindTypeVars(pi, a.optional, params, bound, depth + 1) else self.bindTypeVars(pi, actual, params, bound, depth + 1),
            .borrow_read => |pi| if (a == .borrow_read) self.bindTypeVars(pi, a.borrow_read, params, bound, depth + 1) else if (a == .borrow_write) self.bindTypeVars(pi, a.borrow_write, params, bound, depth + 1),
            .borrow_write => |pi| if (a == .borrow_write) self.bindTypeVars(pi, a.borrow_write, params, bound, depth + 1),
            .shared => |pi| if (a == .shared) self.bindTypeVars(pi, a.shared, params, bound, depth + 1),
            .weak => |pi| if (a == .weak) self.bindTypeVars(pi, a.weak, params, bound, depth + 1),
            .array => |pa| if (a == .array) self.bindTypeVars(pa.elem, a.array.elem, params, bound, depth + 1),
            .parameterized_nominal => |pn| if (a == .parameterized_nominal and a.parameterized_nominal.sym == pn.sym) {
                for (pn.args, a.parameterized_nominal.args) |pa, aa| self.bindTypeVars(pa, aa, params, bound, depth + 1);
            },
            .function => |pf| if (a == .function and a.function.params.len == pf.params.len) {
                for (pf.params, a.function.params) |pp, ap| self.bindTypeVars(pp, ap, params, bound, depth + 1);
                self.bindTypeVars(pf.returns, a.function.returns, params, bound, depth + 1);
            },
            else => {},
        }
    }

    /// The instance of generic `sym_id` at `args`, checked like a spelled
    /// one: the built-in generics' element rules, and every generic's
    /// requirements (through its instantiation site).
    fn instantiate(self: *Checker, sym_id: SymbolId, args: []const TypeId, pos: u32) Error!TypeId {
        var r = self.resolver();
        if (try r.builtinArgError(sym_id, args)) |msg| try self.err(pos, "{s}", .{msg});
        const ty = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = try self.ctx.dupeIds(args) } });
        if (!sema.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else if (self.ctx.symbols.items[sym_id].decl_pos != sema.builtin_decl_pos) {
            for (self.ctx.generic_uses.items) |u| {
                if (u == ty) break;
            } else try self.ctx.generic_uses.append(self.ctx.allocator, ty);
        }
        return ty;
    }

    /// `module.function(args)` or `module.Type(fields)`.
    fn crossModuleCall(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const found = (try self.foreignSymbol(module_sym, name, pos)) orelse {
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        const qualified = try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}.{s}", .{ module_name, name });
        switch (found.sym.kind) {
            .function, .@"extern" => {
                const local = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
                const fty = self.ctx.types.get(local);
                if (fty != .function) {
                    try self.err(pos, "`{s}` cannot be called", .{qualified});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.noteCallee(fty.function);
                try self.checkArgs(args, fty.function, .{ .names = found.sym.param_names, .defaults = found.sym.param_defaults, .source = found.ctx.source }, qualified, pos);
                return fty.function.returns;
            },
            .nominal_type => return self.construct(found.id, args, pos, TypeSubst.empty, .{ .ctx = found.ctx, .module_id = found.module_id }),
            else => {
                try self.err(pos, "`{s}` cannot be called", .{qualified});
                try self.synthArgs(args);
                return self.t().invalid_id;
            },
        }
    }

    fn importedMethodCall(self: *Checker, obj: Sexp, obj_ty: TypeId, in: sema.ImportedNominal, method: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
        const foreign = self.ctx.foreign_semas.get(in.module_id) orelse {
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        const sym = foreign.symbols.items[in.sym_id];
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_method or f.is_drop_method or !std.mem.eql(u8, f.name, method)) continue;
            const local = try sema.importType(self.ctx, foreign, f.ty, in.module_id);
            const fty = self.ctx.types.get(local).function;
            try self.noteCalleeType(local);
            if (f.receiver == .none) {
                try self.err(pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{ method, sym.name, method });
                try self.synthArgs(args);
                return fty.returns;
            }
            // A consuming method takes over a temporary receiver.
            if (f.receiver != .value) try self.rejectResourceTemporary(obj, obj_ty);
            try self.checkReceiverMode(obj, f.receiver, classifyImportedReceiver(self.ctx, obj_ty), method, pos);
            const rest: FunctionType = .{ .params = fty.params[1..], .returns = fty.returns, .is_sub = fty.is_sub, .pre_mask = fty.pre_mask >> 1 };
            var params = self.methodParams(f, true);
            params.source = foreign.source;
            try self.checkArgs(args, rest, params, method, pos);
            return fty.returns;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ method, sym.name });
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    /// The loop or match binding a place is a part of, when the path to
    /// it stays inside that binding (a copy of the value it came from)
    /// rather than going through a borrow or handle.
    fn copiedBindingRoot(self: *Checker, place: Sexp) ?Sexp {
        var p = place;
        while (p.kind()) |h| {
            if (h != .member and h != .index) return null;
            const obj = ir.get(p, .object);
            if (self.ctx.typeOf(obj)) |ty| switch (self.ctx.types.get(ty)) {
                .borrow_read, .borrow_write, .shared => return null,
                else => {},
            };
            p = obj;
        }
        if (p != .src) return null;
        const id = self.ctx.symbolOf(p) orelse return null;
        const sym = self.ctx.symbols.items[id];
        if (!sym.flags.pattern_bound) return null;
        if (self.ctx.types.get(sym.ty) == .borrow_write or self.ctx.types.get(sym.ty) == .borrow_read) return null;
        return p;
    }

    /// A Cell is interior-mutable: `set` and `replace` change it through
    /// any path that reaches its storage, including a read borrow or a
    /// shared handle. The storage is a local binding (or a field or
    /// element of one), a capture held by a closure environment, or
    /// anything behind a borrow or handle. A by-value parameter is
    /// immutable, and a loop or match binding is a copy, so changing it
    /// would not change the value it came from.
    fn cellSettable(self: *Checker, recv: Sexp) bool {
        var p = recv;
        while (p.isKind(.read) or p.isKind(.write)) p = ir.get(p, .operand);
        while (true) {
            if (self.ctx.typeOf(p)) |ty| switch (self.ctx.types.get(ty)) {
                .borrow_read, .borrow_write, .shared => return true,
                else => {},
            };
            const h = p.kind() orelse break;
            if (h != .member and h != .index) return false;
            p = ir.get(p, .object);
        }
        if (p != .src) return false;
        const id = self.ctx.symbolOf(p) orelse return false;
        const sym = self.ctx.symbols.items[id];
        return switch (sym.kind) {
            .local => !sym.flags.pattern_bound,
            .capture => true,
            else => false,
        };
    }

    /// Receiver rules: `?self` auto-borrows; `!self` needs an explicit
    /// `(!x)`; a consuming `self` needs an explicit `(<x)`. Write and
    /// consuming receivers are refused through `?T` and `*T`.
    fn checkReceiverMode(self: *Checker, recv: Sexp, mode: MethodReceiver, kind: ReceiverTypeKind, method: []const u8, pos: u32) Error!void {
        const shape = classifyReceiverShape(recv);
        switch (mode) {
            .read => if (shape == .move_explicit) {
                try self.err(pos, "method `{s}` takes a read borrow of receiver; cannot move", .{method});
            },
            .write => {
                if (kind == .read_borrow) return self.err(pos, "method `{s}` requires a write-borrowed receiver; cannot upgrade a read borrow to a write borrow", .{method});
                if (kind == .shared) return self.err(pos, "cannot call write-receiver method `{s}` through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell(T)` for mutation through shared ownership.", .{method});
                switch (shape) {
                    .write_explicit => {},
                    .rvalue => if (kind != .owned_nominal and kind != .write_borrow and kind != .other) {
                        try self.err(pos, "method `{s}` requires a write-borrowed receiver; this expression yields a borrowed value, not an owned one", .{method});
                    },
                    .read_explicit => try self.err(pos, "method `{s}` requires a write-borrowed receiver; got `?...`; use `(!receiver).{s}(...)`", .{ method, method }),
                    .move_explicit => try self.err(pos, "method `{s}` requires a write-borrowed receiver; cannot move; use `(!receiver).{s}(...)`", .{ method, method }),
                    // A binding that already holds a write borrow (`x: !T`,
                    // `!self`) lends it to the call as it is.
                    .lvalue_bare => if (kind != .write_borrow) {
                        try self.err(pos, "method `{s}` requires a write-borrowed receiver; use `(!receiver).{s}(...)`", .{ method, method });
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
                    .read_explicit, .write_explicit => try self.err(pos, "method `{s}` consumes the receiver; borrow forms not allowed; use `(<receiver).{s}(...)`", .{ method, method }),
                    .lvalue_bare => try self.err(pos, "method `{s}` consumes the receiver; use `(<receiver).{s}(...)`", .{ method, method }),
                }
            },
            .none => {},
        }
    }

    // =========================================================================
    // Expressions: checking against an expected type
    // =========================================================================

    fn checkExpr(self: *Checker, e: Sexp, expected: TypeId) Error!void {
        if (self.isPoison(expected)) {
            _ = try self.synthExpr(e);
            return;
        }
        if (try self.checkContextual(e, expected)) return;

        const actual = try self.synthExpr(e);
        if (compatible(self.ctx, actual, expected)) {
            try self.recordAdapted(e, actual, expected);
            return;
        }
        // A fallible call where its value is expected: `synthCall`
        // reported the missing `!` / `catch`.
        const at = self.ctx.types.get(actual);
        if (at == .fallible and compatible(self.ctx, at.fallible, expected)) return;
        try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(actual) });
    }

    /// Forms whose type comes from context. Returns true if handled.
    fn checkContextual(self: *Checker, e: Sexp, expected: TypeId) Error!bool {
        const target = self.liftTarget(expected);
        switch (e) {
            .src => {
                const s = self.text(e);
                if (std.mem.eql(u8, s, "none")) {
                    try self.checkNone(e, expected, target);
                    return true;
                }
                if (sema.isIntLiteralText(s) and sema.isInteger(self.ctx, target)) {
                    try self.checkLiteralFits(e, target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .list => {},
            else => return false,
        }
        const head = e.kind() orelse return false;
        switch (head) {
            .neg => {
                const operand = ir.Neg.operand(e);
                if (operand == .src and sema.isIntLiteralText(self.text(operand)) and sema.isInteger(self.ctx, target)) {
                    try self.checkLiteralFits(e, target);
                    try self.ctx.recordType(operand, target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .enum_lit => {
                // Where a `T!` is expected, `.name` that is not a variant
                // of `T` is an error value.
                const name = ir.EnumLit.name(e);
                if (self.ctx.types.get(expected) == .fallible and
                    (try sema.lookupVariant(self.ctx, target, self.text(name))) == null and
                    sema.errorNameExists(self.ctx, self.text(name)))
                {
                    try self.ctx.recordType(e, self.t().any_error_id);
                    return true;
                }
                try self.checkEnumLit(name, target);
                try self.ctx.recordType(e, target);
                return true;
            },
            .call => {
                const callee = ir.Call.callee(e);
                if (callee.isKind(.enum_lit)) {
                    try self.checkPayloadVariant(e, target);
                    try self.ctx.recordType(callee, target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                if (callee == .src) {
                    const tt = self.ctx.types.get(target);
                    if (tt == .parameterized_nominal) {
                        if (self.lookupQuiet(callee)) |id| {
                            if (id == tt.parameterized_nominal.sym) {
                                _ = try self.useName(callee);
                                if (id == self.ctx.vec_sym_id) {
                                    try self.checkVecConstruction(e);
                                } else {
                                    const sym = self.ctx.symbols.items[id];
                                    _ = try self.construct(id, ir.Call.args(e), callee.src.pos, .{ .params = sym.type_params orelse &.{}, .args = tt.parameterized_nominal.args }, null);
                                }
                                try self.ctx.recordType(e, target);
                                return true;
                            }
                        }
                    }
                }
                return false;
            },
            .builtin => {
                _ = try self.synthBuiltin(e, target);
                return true;
            },
            .lambda => {
                if (self.ctx.types.get(target) == .function) {
                    try self.ctx.recordType(e, try self.checkLambda(e, target, false));
                    return true;
                }
                if (sema.ownedClosureFn(self.ctx, target) != null) {
                    try self.errAt(e, "`{s}` is an owned closure; write `*|...| body` to make one", .{try self.tyName(target)});
                    try self.ctx.recordType(e, try self.checkLambda(e, self.ctx.types.get(sema.unwrapBorrows(self.ctx, target)).shared, false));
                    return true;
                }
                return false;
            },
            .share => {
                const operand = ir.Share.operand(e);
                if (operand.isKind(.lambda)) {
                    const fn_ty: ?TypeId = if (sema.ownedClosureFn(self.ctx, target) != null) self.ctx.types.get(sema.unwrapBorrows(self.ctx, target)).shared else null;
                    const ty = try self.ownedClosure(operand, fn_ty);
                    try self.ctx.recordType(e, ty);
                    if (!compatible(self.ctx, ty, expected)) {
                        try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(ty) });
                    }
                    return true;
                }
                const tt = self.ctx.types.get(target);
                if (tt == .shared) {
                    try self.checkExpr(operand, tt.shared);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .array => return self.checkArray(e, target),
            .@"if" => {
                _ = try self.checkIfValue(e, expected, .value);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .match => {
                _ = try self.checkMatch(e, .value, expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .block => {
                _ = try self.synthBlock(e, expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .raw_block => {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                try self.checkExpr(ir.RawBlock.body(e), expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"??" => {
                const ty = try self.synthCoalesce(e, null);
                try self.ctx.recordType(e, ty);
                if (!compatible(self.ctx, ty, expected)) {
                    try self.errAt(e, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(ty) });
                } else try self.recordAdapted(e, ty, expected);
                return true;
            },
            else => return false,
        }
    }

    /// `none` where `expected` is required: an optional (possibly fallible).
    fn checkNone(self: *Checker, e: Sexp, expected: TypeId, target: TypeId) Error!void {
        var ty = expected;
        while (true) {
            switch (self.ctx.types.get(ty)) {
                .optional => {
                    try self.ctx.recordType(e, ty);
                    return;
                },
                .fallible => |i| ty = i,
                else => break,
            }
        }
        _ = target;
        const name = try self.tyName(expected);
        // A prefixed type takes parentheses before the `?`: `(*B)?`, `([2]Int)?`.
        const wrap = name.len > 0 and std.mem.indexOfScalar(u8, "*~?![", name[0]) != null;
        try self.errAt(e, "`none` needs an optional type; `{s}` is not optional (write `{s}{s}{s}?`)", .{ name, if (wrap) "(" else "", name, if (wrap) ")" else "" });
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

    /// Record the concrete type a literal took in context.
    fn recordAdapted(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
        if (actual != self.t().int_literal_id and actual != self.t().float_literal_id) return;
        const target = self.liftTarget(expected);
        if (!sema.isNumeric(self.ctx, target)) return;
        try self.ctx.recordType(e, target);
        if (actual == self.t().int_literal_id) try self.checkLiteralFits(e, target);
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
        try self.checkFieldArgs(args, resolved.payload, .{ .owner = name, .decl_pos = decl_pos, .pos = pos, .kind = .variant });
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
        if (compatible(self.ctx, a, b)) return b;
        if (compatible(self.ctx, b, a)) return a;
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
                .sizeOf, .alignOf => {
                    if (try self.builtinTypeArg(name, args, pos)) break :blk self.t().int_literal_id;
                    break :blk self.t().invalid_id;
                },
                .typeName => {
                    if (try self.builtinTypeArg(name, args, pos)) break :blk self.t().string_id;
                    break :blk self.t().invalid_id;
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
            const operand = readValue(self.ctx, try self.synthExpr(args[0]));
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
        if (expected) |e| {
            if (!self.isPoison(ty) and !compatible(self.ctx, ty, e)) {
                try self.errAt(node, "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(e), try self.tyName(ty) });
            }
            try self.ctx.recordType(node, if (ty == self.t().int_literal_id) self.liftTarget(e) else ty);
        } else {
            try self.ctx.recordType(node, self.canonical(ty));
        }
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

    /// `@sizeOf(T)` / `@sizeOf(@TypeOf(x))`.
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
        return !self.isPoison(ty);
    }

    // =========================================================================
    // Closures
    // =========================================================================

    fn synthLambda(self: *Checker, node: Sexp) Error!TypeId {
        return self.checkLambda(node, null, false);
    }

    /// `*|...| body`: an owned closure; `expected` is the function type
    /// its context gives it (`*fun(Int) Int` gives `fun(Int) Int`).
    fn ownedClosure(self: *Checker, lambda: Sexp, expected: ?TypeId) Error!TypeId {
        const lty = try self.checkLambda(lambda, expected, true);
        try self.ctx.recordType(lambda, lty);
        return self.ctx.intern(.{ .shared = lty });
    }

    /// A closure literal. Its type is a function type over its
    /// parameters. With an `expected` function type from context, bare
    /// parameters take its parameter types and the body is checked
    /// against its return type; without one, every parameter must be
    /// annotated and the return type is that of the body's last
    /// expression. `owned` closures pass only plain Copy values.
    fn checkLambda(self: *Checker, node: Sexp, expected: ?TypeId, owned: bool) Error!TypeId {
        const captures = sema.captureList(ir.Lambda.captures(node));
        const outer = self.scope;
        const prev = self.enter(node);
        const prev_ret = self.fn_return;
        const prev_sub = self.is_sub;
        const prev_sites = self.lambda_returns;
        const prev_fail = self.fail_to;
        defer {
            self.scope = prev;
            self.fn_return = prev_ret;
            self.is_sub = prev_sub;
            self.lambda_returns = prev_sites;
            self.fail_to = prev_fail;
        }
        self.lambda_returns = null;
        self.fail_to = .closure;

        if (self.ctx.bodyRoot(outer)) |root| {
            if (self.ctx.scopes.items[root].kind == .lambda) {
                for (captures) |cap| {
                    const n = sema.captureNameNode(cap) orelse continue;
                    try self.errAt(n, "nested closure capture of `{s}` is not supported; lift the capture to the outer scope", .{self.text(n)});
                }
            }
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
            const given: ?TypeId = if (want) |w| (if (i < w.params.len) w.params[i] else null) else null;
            var pty = self.t().invalid_id;
            if (p.isKind(.@":")) {
                pty = try r.resolveType(ir.@":".type(p));
                if (given) |g| if (!self.isPoison(pty) and !self.isPoison(g) and pty != g) {
                    try self.errAt(pn, "closure parameter `{s}` is declared `{s}`, but the closure's type passes `{s}`", .{ name, try self.tyName(pty), try self.tyName(g) });
                };
            } else if (given) |g| {
                pty = g;
            } else if (want == null and !self.namesOuterLocal(outer, name, srcPos(pn, 0))) {
                try self.errAt(pn, "closure parameter `{s}` needs a type: annotate it (`|{s}: Int|`) or write the closure where its type is known (`f: fun(Int) Int = |{s}| ...`)", .{ name, name, name });
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
            self.fn_return = w.returns;
            self.is_sub = w.is_sub;
            try self.checkBody(body, w.returns, w.is_sub);
            return expected.?;
        }

        self.fn_return = self.t().unknown_id;
        self.is_sub = false;
        var sites: std.ArrayListUnmanaged(ReturnSite) = .empty;
        defer sites.deinit(self.ctx.allocator);
        self.lambda_returns = &sites;
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
                const no_value = isStatementForm(last) or ifWithoutValue(last);
                ret = if (no_value) blk: {
                    try self.checkStmt(last);
                    break :blk self.t().void_id;
                } else try self.synthExpr(last);
            }
        } else ret = try self.synthExpr(body);
        self.lambda_returns = null;
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
                try self.errAt(site.node, "this closure returns `{s}`, but this `return` gives `{s}`", .{ try self.tyName(ret), try self.tyName(ty) });
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

    /// A Copy primitive, or an optional of one.
    fn isCopyValue(self: *Checker, ty: TypeId) bool {
        return sema.isPlainData(self.ctx, ty);
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
        const outer_ty = self.ctx.symbols.items[outer_id].ty;
        const oty = self.ctx.types.get(outer_ty);
        const bound: TypeId = switch (mode) {
            .cap_clone => switch (oty) {
                .shared, .weak => outer_ty,
                // Cloning through a borrow of a handle makes a new handle.
                .borrow_read, .borrow_write => |inner| switch (self.ctx.types.get(inner)) {
                    .shared, .weak => inner,
                    else => blk: {
                        try self.err(pos, "`|+{s}|` copies a Copy value or clones a `*T` / `~T` handle, but `{s}` is `{s}`; move it in with `|<{s}|`, or clone a handle into a local first and capture that", .{ name, name, try self.tyName(outer_ty), name });
                        break :blk self.t().invalid_id;
                    },
                },
                // Inside a generic body, copying a `T` requires plain data.
                else => if (self.isCopyValue(outer_ty) or self.isPoison(outer_ty) or
                    (sema.maybeDropGlue(self.ctx, outer_ty) and !(try self.ownsResource(outer_ty, pos, "copies into a closure a value")))) outer_ty else blk: {
                    try self.err(pos, "`|+{s}|` copies a Copy value or clones a `*T` / `~T` handle, but `{s}` is `{s}`; move it in with `|<{s}|`, or clone a handle into a local first and capture that", .{ name, name, try self.tyName(outer_ty), name });
                    break :blk self.t().invalid_id;
                },
            },
            .cap_weak => switch (oty) {
                .shared => |inner| try self.ctx.intern(.{ .weak = inner }),
                else => blk: {
                    try self.err(pos, "weak-capture `|~{s}|` requires a shared handle `*T`; got `{s}`", .{ name, try self.tyName(outer_ty) });
                    break :blk self.t().invalid_id;
                },
            },
            .cap_move => outer_ty,
        };
        self.ctx.symbols.items[cap_sym].ty = bound;
        self.ctx.symbols.items[cap_sym].origin = outer_id;
        try self.ctx.recordType(name_node, bound);
    }
};

// =============================================================================
// Compatibility and classification
// =============================================================================

/// A borrow of a Copy value reads as the value itself: `n + 1` with
/// `n: ?Int` or `n: !Int` is an `Int`.
pub fn readValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .borrow_write => |inner| if (sema.isCopyPrimitive(ctx, inner)) inner else ty,
        else => ty,
    };
}

/// Can a value of type `actual` be used where `expected` is required?
pub fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
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
        else => {},
    }
    return switch (a) {
        .int_literal => e == .int or e == .float,
        .float_literal => e == .float,
        .borrow_read, .borrow_write => readValue(ctx, actual) != actual and compatible(ctx, readValue(ctx, actual), expected),
        else => false,
    };
}

pub const ReceiverTypeKind = enum { owned_nominal, read_borrow, write_borrow, shared, other };

fn classifyReceiverType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) ReceiverTypeKind {
    const matches = struct {
        fn f(c: *const SemContext, id: TypeId, sym: SymbolId) bool {
            return switch (c.types.get(id)) {
                .nominal => |s| s == sym,
                .parameterized_nominal => |pn| pn.sym == sym,
                else => false,
            };
        }
    }.f;
    // A borrow of a shared handle (`(!h).m()` with `h: *T`) still reaches
    // the value through the handle.
    if (ctx.types.get(sema.unwrapBorrows(ctx, ty_id)) == .shared) return .shared;
    return switch (ctx.types.get(ty_id)) {
        .nominal, .parameterized_nominal => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
        .borrow_read => |i| if (matches(ctx, i, nominal_sym)) .read_borrow else .other,
        .borrow_write => |i| if (matches(ctx, i, nominal_sym)) .write_borrow else .other,
        else => .other,
    };
}

fn classifyImportedReceiver(ctx: *const SemContext, ty_id: TypeId) ReceiverTypeKind {
    if (ctx.types.get(sema.unwrapBorrows(ctx, ty_id)) == .shared) return .shared;
    return switch (ctx.types.get(ty_id)) {
        .imported_nominal => .owned_nominal,
        .borrow_read => .read_borrow,
        .borrow_write => .write_borrow,
        else => .other,
    };
}

pub const ReceiverShape = enum { read_explicit, write_explicit, move_explicit, rvalue, lvalue_bare };

/// How the receiver expression is written. Only heads that certainly
/// produce a fresh value count as rvalues; everything else is a place.
fn classifyReceiverShape(recv: Sexp) ReceiverShape {
    const h = recv.kind() orelse return .lvalue_bare;
    return switch (h) {
        .read => .read_explicit,
        .write => .write_explicit,
        .move => .move_explicit,
        .call, .builtin, .array, .clone, .share, .weak, .@"if", .match, .@"catch", .propagate => .rvalue,
        else => .lvalue_bare,
    };
}

/// The element type of a Cell receiver (`Cell(T)`, `?Cell(T)`, `*Cell(T)`, ...).
fn cellElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.cell_sym_id or pn.args.len != 1) return null;
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
    if (!s.isKind(.@"while")) return false;
    const cond = ir.While.cond(s);
    if (!std.mem.eql(u8, identAt(source, cond) orelse "", "true")) return false;
    return !breaksOut(ir.While.body(s));
}

/// Whether `e` holds a `break` that would leave the loop around it (one
/// not inside a nested loop or closure).
fn breaksOut(e: Sexp) bool {
    const h = e.kind() orelse return false;
    switch (h) {
        .@"break" => return true,
        .@"while", .@"for", .lambda, .labeled => return false,
        else => {},
    }
    for (rig.children(e)) |c| if (breaksOut(c)) return true;
    return false;
}

/// A name or a chain of fields off one: `v`, `t.kids`, `a.b.c`.
/// `a` and `b` are the same parsed node.
fn sameNode(a: Sexp, b: Sexp) bool {
    return a == .list and b == .list and a.list.ptr == b.list.ptr;
}

fn isFieldPath(e: Sexp) bool {
    if (e == .src) return true;
    if (!e.isKind(.member)) return false;
    return isFieldPath(ir.Member.object(e));
}

/// Forms whose type comes from the other operand: `.variant`, `none`.
fn isContextual(source: []const u8, e: Sexp) bool {
    return e.isKind(.enum_lit) or std.mem.eql(u8, identAt(source, e) orelse "", "none");
}

/// Literal forms allowed as default parameter values: the same text
/// means the same value at every call site, in any module.
pub fn isDefaultLiteral(source: []const u8, e: Sexp) bool {
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

fn isStatementForm(e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .set, .@"while", .@"for", .drop, .@"defer", .@"errdefer", .@"return", .@"break", .@"continue", .labeled => true,
        else => false,
    };
}

/// The value of a float literal, possibly negated: `2.5`, `-1e3`.
fn constFloatOf(source: []const u8, e: Sexp) ?f64 {
    if (e.isKind(.neg)) return -(constFloatOf(source, ir.Neg.operand(e)) orelse return null);
    const t = identAt(source, e) orelse return null;
    if (!sema.isFloatLiteralText(t)) return null;
    return std.fmt.parseFloat(f64, t) catch null;
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

/// Every instantiation of a generic type must support the operations
/// its bodies apply to the type parameters (`self.value + 1` requires a
/// numeric `T`). Checked after all bodies, against every instantiation
/// the module spells.
pub fn checkGenericInstantiations(ctx: *SemContext) Error!void {
    if (ctx.generic_requirements.items.len == 0) return;
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |entry| {
        const pn = switch (ctx.types.get(entry.key_ptr.*)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        const params = ctx.symbols.items[pn.sym].type_params orelse continue;
        for (params, 0..) |param, i| {
            if (i >= pn.args.len) break;
            const arg = pn.args[i];
            for (ctx.generic_requirements.items) |req| {
                if (req.param != param or satisfies(ctx, arg, req.req)) continue;
                const pname = ctx.symbols.items[param].name;
                if (req.req == .plain) {
                    try ctx.err(entry.value_ptr.*, "`{s}` cannot use `{s} = {s}`: the generic body {s} that holds a `{s}`, which would leak or duplicate the resource `{s}` owns", .{
                        try sema.formatType(ctx, entry.key_ptr.*), pname, try sema.formatType(ctx, arg), req.op, pname, try sema.formatType(ctx, arg),
                    });
                    try ctx.note(req.pos, "here", .{});
                    break;
                }
                if (req.req == .fits) {
                    try ctx.err(entry.value_ptr.*, "`{s}` cannot use `{s} = {s}`: the generic body applies `{s}` to a `{s}` and the literal `{d}`, which `{s}` cannot hold", .{
                        try sema.formatType(ctx, entry.key_ptr.*), pname, try sema.formatType(ctx, arg), req.op, pname, req.req.fits, try sema.formatType(ctx, arg),
                    });
                    try ctx.note(req.pos, "`{s}` used here", .{req.op});
                    break;
                }
                try ctx.err(entry.value_ptr.*, "`{s}` cannot use `{s} = {s}`: the generic body applies `{s}` to `{s}`, which `{s}` does not support", .{
                    try sema.formatType(ctx, entry.key_ptr.*), pname, try sema.formatType(ctx, arg), req.op, pname, try sema.formatType(ctx, arg),
                });
                try ctx.note(req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() });
                break;
            }
        }
    }
}

fn satisfies(ctx: *const SemContext, ty: TypeId, req: Requirement) bool {
    return switch (req) {
        .numeric, .ordered => sema.isNumeric(ctx, ty),
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
        .equatable => switch (ctx.types.get(ty)) {
            .int, .float, .bool => true,
            .nominal, .imported_nominal => sema.isPlainEnum(ctx, ty),
            else => false,
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { ctx: SemContext, p: parser.Parser, tree: Sexp } {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const tree = try p.parseProgram();
    const ctx = try sema.check(allocator, source, tree);
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
