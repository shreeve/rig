//! Expression checking: the bodies of functions, methods, lambdas, and
//! tests, plus module-level bindings.
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
//! `T` where `T?` or `T!` is expected (the value is lifted); `!T` where
//! `?T` is expected; and anything where poison (`unknown` / `invalid`)
//! is involved, so one error does not cascade.
//!
//! Anything accepted here must be lowerable by emit. Constructs the
//! backend cannot express yet are rejected with a diagnostic that says
//! so rather than being passed through.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const decls = @import("sema_decls.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const SemContext = types.SemContext;
const SymbolId = types.SymbolId;
const ScopeId = types.ScopeId;
const TypeId = types.TypeId;
const Type = types.Type;
const Field = types.Field;
const FunctionType = types.FunctionType;
const MethodReceiver = types.MethodReceiver;
const NominalContext = types.NominalContext;
const TypeSubst = types.TypeSubst;
const Requirement = types.Requirement;
const Error = std.mem.Allocator.Error;

const identAt = types.identAt;
const srcPos = types.srcPos;
const headOf = types.headOf;
const isHead = types.isHead;
const firstSrcPos = types.diag.firstSrcPos;

pub fn checkModule(ctx: *SemContext, ir: Sexp, module_scope: ScopeId) Error!void {
    if (!isHead(ir, .@"module")) return;
    var c: Checker = .{
        .ctx = ctx,
        .scope = module_scope,
        .module_scope = module_scope,
        .fn_return = ctx.types.void_id,
    };
    for (ir.list[1..]) |decl| try c.checkDecl(decl);
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

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.err(pos, fmt, args);
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.ctx.note(pos, fmt, args);
    }

    fn tyName(self: *Checker, ty: TypeId) Error![]const u8 {
        return types.formatType(self.ctx, ty);
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

    fn resolver(self: *Checker) decls.TypeResolver {
        return .{ .ctx = self.ctx, .scope = self.scope, .nominal = self.nominal };
    }

    fn t(self: *Checker) *types.TypeStore {
        return &self.ctx.types;
    }

    fn isPoison(self: *Checker, ty: TypeId) bool {
        return ty == self.ctx.types.unknown_id or ty == self.ctx.types.invalid_id;
    }

    // =========================================================================
    // Declarations
    // =========================================================================

    fn checkDecl(self: *Checker, sexp: Sexp) Error!void {
        const head = headOf(sexp) orelse return;
        const items = sexp.list;
        switch (head) {
            .@"pub" => if (items.len >= 2) try self.checkDecl(items[1]),
            .@"export", .@"packed", .@"callconv" => {
                try self.err(firstSrcPos(sexp), "`{s}` declarations are not supported yet", .{@tagName(head)});
            },
            .@"extern" => if (items.len == 2) {
                try self.err(firstSrcPos(sexp), "an `extern` declaration with a body is not supported; declare the signature only (`extern fun f(x: Int) -> Int`)", .{});
            },
            .@"fun", .@"sub" => {
                const fn_ty = if (self.ctx.symbolOf(items[1])) |id| self.ctx.symbols.items[id].ty else self.t().invalid_id;
                try self.checkFunction(sexp, fn_ty);
            },
            .@"struct", .@"enum", .@"errors", .@"generic_type", .@"generic_enum" => try self.checkNominal(items),
            .@"test" => {
                const prev_scope = self.enter(sexp);
                defer self.scope = prev_scope;
                if (items.len >= 3) try self.checkBody(items[2], self.t().void_id, true);
            },
            .@"set" => {
                try self.err(firstSrcPos(sexp), "module-level bindings are not supported yet; bind values inside a function", .{});
                try self.checkSet(items);
            },
            .@"opaque" => try self.err(firstSrcPos(sexp), "`opaque` types are not supported yet", .{}),
            .@"use", .@"type", .@"extern_fun", .@"extern_sub" => {},
            else => try self.err(firstSrcPos(sexp), "only declarations and bindings are allowed at module level; move this statement into a function", .{}),
        }
    }

    fn checkNominal(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const sym_id = self.ctx.symbolOf(items[1]) orelse return;
        const prev = self.nominal;
        self.nominal = try types.makeNominalContext(self.ctx, sym_id);
        defer self.nominal = prev;
        const generic = items[0].tag == .@"generic_type" or items[0].tag == .@"generic_enum";
        const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
        for (items[if (generic) 3 else 2..]) |m| {
            const h = headOf(m) orelse continue;
            switch (h) {
                .@"fun", .@"sub" => {
                    const pos = srcPos(m.list[1], 0);
                    var fn_ty = self.t().invalid_id;
                    for (fields) |f| {
                        if (f.is_method and f.decl_pos == pos) fn_ty = f.ty;
                    }
                    try self.checkFunction(m, fn_ty);
                },
                .@"drop_decl" => {
                    if (m.list.len < 3) continue;
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
                    try self.checkBody(m.list[2], self.t().void_id, true);
                },
                else => {},
            }
        }
    }

    fn checkFunction(self: *Checker, node: Sexp, fn_ty_id: TypeId) Error!void {
        const items = node.list;
        if (items.len < 5) return;
        const is_sub = items[0].tag == .@"sub";
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
        try self.checkBody(items[items.len - 1], ret, is_sub);
    }

    /// A body's statements; in a `fun`, the last one is its value.
    fn checkBody(self: *Checker, body: Sexp, ret: TypeId, is_sub: bool) Error!void {
        const wants_value = !is_sub and ret != self.t().void_id;
        if (!isHead(body, .@"block")) {
            if (wants_value) try self.checkExpr(body, ret) else try self.checkStmt(body);
            return;
        }
        const prev = self.enter(body);
        defer self.scope = prev;
        const stmts = body.list[1..];
        if (stmts.len == 0) {
            if (wants_value) try self.err(firstSrcPos(body), "function body is empty but must produce a `{s}`", .{try self.tyName(ret)});
            return;
        }
        for (stmts, 0..) |s, i| {
            if (wants_value and i == stmts.len - 1) {
                if (isStatementForm(s) and !isHead(s, .@"return")) {
                    try self.checkStmt(s);
                    try self.err(firstSrcPos(s), "a function returning `{s}` must end with a value; this `{s}` produces none", .{ try self.tyName(ret), @tagName(headOf(s).?) });
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
        const head = headOf(stmt) orelse {
            _ = try self.synthExpr(stmt);
            return;
        };
        const items = stmt.list;
        switch (head) {
            .@"set" => try self.checkSet(items),
            .@"return" => try self.checkReturn(items),
            .@"if" => try self.checkIf(stmt, null),
            .@"while" => try self.checkWhile(stmt),
            .@"for" => try self.checkFor(stmt),
            .@"match" => _ = try self.checkMatch(stmt, .statement, null),
            .@"block" => {
                const prev = self.enter(stmt);
                defer self.scope = prev;
                for (items[1..]) |c| try self.checkStmt(c);
            },
            .@"drop" => if (items.len >= 2) {
                _ = try self.synthExpr(items[1]);
            },
            .@"break", .@"continue" => try self.checkJump(items),
            .@"defer", .@"errdefer" => if (items.len >= 2) try self.checkStmt(items[1]),
            .@"raw_block" => if (items.len >= 2) try self.checkStmt(items[1]),
            .@"labeled" => if (items.len >= 3) try self.checkStmt(items[2]),
            .@"fun", .@"sub", .@"struct", .@"enum", .@"errors", .@"type", .@"generic_type", .@"generic_enum", .@"use", .@"extern", .@"extern_fun", .@"extern_sub", .@"test", .@"opaque", .@"pub" => {
                try self.err(firstSrcPos(stmt), "declarations are only allowed at module level", .{});
            },
            else => {
                const ty = try self.synthExpr(stmt);
                if (types.typeHasDropGlue(self.ctx, ty)) {
                    try self.err(firstSrcPos(stmt), "expression result of type `{s}` carries drop glue and would leak as a discarded statement; bind it to a name (`old = {s}.replace(<new)`), explicitly drop with `-name`, or move it into a receiver", .{
                        try self.tyName(ty), self.discardedReceiverName(stmt),
                    });
                }
            },
        }
    }

    fn discardedReceiverName(self: *Checker, stmt: Sexp) []const u8 {
        if (isHead(stmt, .@"call") and stmt.list.len >= 2 and isHead(stmt.list[1], .@"member")) {
            const obj = stmt.list[1].list[1];
            if (obj == .src) return self.text(obj);
        }
        return "expr";
    }

    /// `(break value? label? guard?)` / `(continue label? guard?)`.
    fn checkJump(self: *Checker, items: []const Sexp) Error!void {
        const is_break = items[0].tag == .@"break";
        if (is_break and items.len >= 2 and items[1] != .nil) {
            try self.err(firstSrcPos(items[1]), "`break` with a value is not supported yet", .{});
        }
        const guard_index: usize = if (is_break) 3 else 2;
        if (items.len > guard_index and items[guard_index] != .nil) {
            try self.checkExpr(items[guard_index], self.t().bool_id);
        }
    }

    fn checkReturn(self: *Checker, items: []const Sexp) Error!void {
        const value: Sexp = if (items.len >= 2) items[1] else .{ .nil = {} };
        if (items.len >= 3 and items[2] != .nil) try self.checkExpr(items[2], self.t().bool_id);
        const ret = self.fn_return;
        if (value == .nil) {
            if (!self.is_sub and ret != self.t().void_id and !self.isPoison(ret)) {
                try self.err(firstSrcPos(.{ .list = items }), "`return` needs a value of type `{s}`", .{try self.tyName(ret)});
            }
            return;
        }
        if (self.is_sub and ret == self.t().void_id) {
            try self.err(firstSrcPos(value), "a `sub` returns no value; remove the value or declare a `fun`", .{});
            _ = try self.synthExpr(value);
            return;
        }
        try self.checkExpr(value, ret);
    }

    // ---- bindings and assignment --------------------------------------------

    fn checkSet(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 5) return;
        const kind = rig.bindingKindOf(items[1]) catch return;
        const target = items[2];
        const type_node = items[3];
        const rhs = items[4];

        if (target != .src) return self.checkPlaceAssign(kind, target, type_node, rhs);

        const name = self.text(target);
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

        if (!is_decl and sym.kind == .param) {
            try self.err(target.src.pos, "cannot assign to parameter `{s}`; parameters are immutable (bind a copy with `new {s} = {s}`)", .{ name, name, name });
        }
        if (!is_decl and sym.kind == .capture) {
            try self.err(target.src.pos, "cannot assign to captured `{s}`; captures are fixed when the closure is created", .{name});
        }
        if (!is_decl) sym.flags.reassigned = true;
        if (!is_decl and sym.flags.pattern_bound) {
            try self.err(target.src.pos, "cannot assign to `{s}`; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ name, name, name });
        }

        var declared = self.t().unknown_id;
        if (type_node != .nil) {
            var r = self.resolver();
            declared = try r.resolveType(type_node);
            if (!is_decl and sym.ty != self.t().unknown_id and declared != sym.ty) {
                try self.err(target.src.pos, "`{s}` is already a `{s}`; a later assignment cannot re-annotate it", .{ name, try self.tyName(sym.ty) });
            }
        } else if (!is_decl or sym.ty != self.t().unknown_id) {
            declared = sym.ty;
        }

        if (self.ctx.signal_sym_id != types.symbol_invalid) {
            const d = self.ctx.types.get(declared);
            if (d == .parameterized_nominal and d.parameterized_nominal.sym == self.ctx.signal_sym_id) {
                try self.err(target.src.pos, "stack-local `Signal(T)` is not supported; Signal owns a subscriber `Vec` that requires heap ownership. Use `*Signal(T)` instead: `{s}: *Signal(...) = *Signal(value: ...)`", .{name});
                self.poisonIfUntyped(sym_id);
                return;
            }
        }

        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=" => {
                const target_ty = declared;
                const op = @tagName(kind);
                if (!self.isPoison(target_ty) and !types.isNumeric(self.ctx, target_ty)) {
                    try self.err(target.src.pos, "`{s}` requires a numeric target; `{s}` has type `{s}`", .{ op, name, try self.tyName(target_ty) });
                    _ = try self.synthExpr(rhs);
                } else {
                    try self.checkExpr(rhs, target_ty);
                }
                try self.ctx.recordType(target, target_ty);
                return;
            },
            else => {},
        }

        var rhs_ty: TypeId = undefined;
        if (!self.isPoison(declared)) {
            try self.checkExpr(rhs, declared);
            rhs_ty = declared;
        } else {
            rhs_ty = try self.synthExpr(rhs);
            rhs_ty = try self.defaultBindingType(rhs, rhs_ty, name);
        }

        const s = &self.ctx.symbols.items[sym_id];
        if (s.ty == self.t().unknown_id) s.ty = rhs_ty;
        if (kind == .fixed and self.isComptimeKnown(rhs)) s.flags.comptime_known = true;
        try self.ctx.recordType(target, s.ty);
    }

    fn poisonIfUntyped(self: *Checker, id: SymbolId) void {
        const sym = &self.ctx.symbols.items[id];
        if (sym.ty == self.t().unknown_id) sym.ty = self.t().invalid_id;
    }

    /// The type an unannotated binding gets from its initializer.
    fn defaultBindingType(self: *Checker, rhs: Sexp, ty: TypeId, name: []const u8) Error!TypeId {
        const pos = firstSrcPos(rhs);
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
        const head = headOf(target);
        if (head != .@"member" and head != .@"index") {
            try self.err(firstSrcPos(target), "cannot assign to this expression", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        if (type_node != .nil) {
            try self.err(firstSrcPos(type_node), "a field or element assignment cannot carry a type annotation", .{});
        }
        switch (kind) {
            .fixed, .shadow => {
                try self.err(firstSrcPos(target), "`{s}` binds a name; a field or element can only be assigned with `=`", .{if (kind == .fixed) "=!" else "new"});
                _ = try self.synthExpr(rhs);
                return;
            },
            else => {},
        }
        if (try self.placeThroughShared(target)) {
            try self.err(firstSrcPos(target), "cannot assign through shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell(T)` for mutation through shared ownership.", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        if (try self.placeThroughReadBorrow(target)) |pos| {
            try self.err(pos, "cannot assign through a read borrow (`?T`); take a write borrow (`!T`) to mutate", .{});
            _ = try self.synthExpr(rhs);
            return;
        }
        const place_ty = try self.synthExpr(target);
        if (head == .@"index" and types.typeHasDropGlue(self.ctx, place_ty)) {
            try self.err(firstSrcPos(target), "cannot replace an element of type `{s}` by assignment; the old handle would leak", .{try self.tyName(place_ty)});
            return;
        }
        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=" => {
                if (!self.isPoison(place_ty) and !types.isNumeric(self.ctx, place_ty)) {
                    try self.err(firstSrcPos(target), "`{s}` requires a numeric target; this place has type `{s}`", .{ @tagName(kind), try self.tyName(place_ty) });
                    _ = try self.synthExpr(rhs);
                    return;
                }
            },
            else => {},
        }
        try self.checkExpr(rhs, place_ty);
    }

    /// Does an assignment target reach its storage through a `*T`?
    fn placeThroughShared(self: *Checker, place: Sexp) Error!bool {
        const h = headOf(place) orelse return false;
        if (h != .@"member" and h != .@"index") return false;
        const obj = place.list[1];
        const obj_ty = try self.synthQuiet(obj);
        if (self.ctx.types.get(types.unwrapBorrows(self.ctx, obj_ty)) == .shared) return true;
        return self.placeThroughShared(obj);
    }

    /// Position of a `?T` the assignment target reaches through, if any.
    fn placeThroughReadBorrow(self: *Checker, place: Sexp) Error!?u32 {
        const h = headOf(place) orelse return null;
        if (h != .@"member" and h != .@"index") return null;
        const obj = place.list[1];
        const obj_ty = try self.synthQuiet(obj);
        if (self.ctx.types.get(obj_ty) == .borrow_read) return firstSrcPos(obj);
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
        const items = node.list;
        if (items.len < 3) return self.t().invalid_id;
        if (items.len >= 5) {
            try self.err(firstSrcPos(items[3]), "`else as name` is not supported", .{});
            return self.t().invalid_id;
        }
        const cond = items[1];
        const then_node = items[2];
        const else_node: Sexp = if (items.len >= 4) items[3] else .{ .nil = {} };

        const prev = self.scope;
        try self.checkCondition(cond);
        const then_ty = try self.branch(then_node, expected, position);
        self.scope = prev;

        if (position == .statement) {
            if (else_node != .nil) _ = try self.branch(else_node, expected, position);
            return self.t().void_id;
        }
        if (else_node == .nil) {
            try self.err(firstSrcPos(then_node), "`if` used as a value requires an `else` branch", .{});
            return self.t().invalid_id;
        }
        const else_ty = try self.branch(else_node, expected, position);
        if (expected) |e| return e;
        return (try self.unify(then_ty, else_ty, firstSrcPos(else_node))) orelse self.t().invalid_id;
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

    /// A Bool condition, or `opt as name`, which binds `name` to the
    /// value inside the optional and leaves `self.scope` at the scope
    /// covering the guarded branch.
    fn checkCondition(self: *Checker, cond: Sexp) Error!void {
        if (!isHead(cond, .@"as")) return self.checkExpr(cond, self.t().bool_id);
        if (cond.list.len < 3) return;
        try self.err(firstSrcPos(cond), "unwrapping with `opt as name` is not supported yet; use `opt ?? fallback`", .{});
        const opt_ty = try self.synthExpr(cond.list[1]);
        _ = self.enter(cond);
        const name_node = cond.list[2];
        const sym = self.ctx.symbolOf(name_node) orelse return;
        var bound = self.t().invalid_id;
        switch (self.ctx.types.get(types.unwrapBorrows(self.ctx, opt_ty))) {
            .optional => |inner| {
                // A resource inside stays owned by the optional; the
                // name is a read borrow of it.
                bound = if (types.typeHasDropGlue(self.ctx, inner)) try self.ctx.intern(.{ .borrow_read = inner }) else inner;
            },
            else => if (!self.isPoison(opt_ty)) {
                try self.err(firstSrcPos(cond.list[1]), "`as` unwraps an optional; this expression has type `{s}`", .{try self.tyName(opt_ty)});
            },
        }
        self.ctx.symbols.items[sym].ty = bound;
        try self.ctx.recordType(name_node, bound);
    }

    fn checkWhile(self: *Checker, node: Sexp) Error!void {
        const items = node.list;
        if (items.len < 3) return;
        const prev = self.scope;
        try self.checkCondition(items[1]);
        // (while cond cont body else?)
        const body_end: usize = if (items.len >= 5) items.len - 1 else items.len;
        for (items[2..body_end]) |c| {
            if (c != .nil) try self.checkStmt(c);
        }
        self.scope = prev;
        if (items.len >= 5 and items[4] != .nil) try self.checkStmt(items[4]);
    }

    fn checkFor(self: *Checker, node: Sexp) Error!void {
        const items = node.list;
        if (items.len < 6) return;
        const mode: ?Tag = if (items[1] == .tag) items[1].tag else null;
        const binding = items[2];
        const index_binding = items[3];
        const source = items[4];
        const source_pos = firstSrcPos(source);

        if (mode == .ptr) {
            try self.err(source_pos, "by-reference for-loop binding `for *x in ...` is reserved; write `for x in ?xs` to read-iterate a Vec of resources, or `for x in xs` to iterate values", .{});
        }
        if (mode == .@"write" or mode == .@"move") {
            try self.err(source_pos, "{s} iteration (`for x in {s}xs`) is not supported yet; iterate by value or with `?xs`", .{
                if (mode == .@"write") "mutable" else "consuming", if (mode == .@"write") "!" else "<",
            });
        }
        if (index_binding != .nil) {
            try self.err(firstSrcPos(index_binding), "`for x, i in ...` index bindings are not supported yet", .{});
        }

        var elem_ty = self.t().invalid_id;
        if (isHead(source, .@"..")) {
            elem_ty = try self.checkRange(source);
        } else {
            const peeled_source = if (headOf(source) == .@"read") source.list[1] else source;
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
            try self.checkStmt(items[5]);
        }
        if (items.len > 6 and items[6] != .nil) try self.checkStmt(items[6]);
    }

    fn recordType(self: *Checker, node: Sexp, ty: TypeId) Error!void {
        try self.ctx.recordType(node, ty);
    }

    /// `a..b` as a loop source: both bounds integers of one type.
    fn checkRange(self: *Checker, range: Sexp) Error!TypeId {
        if (range.list.len < 3) return self.t().invalid_id;
        const ty = try self.checkNumericOperands(range.list, "..", .integer);
        const elem = if (ty == self.t().int_literal_id) self.t().int_id else ty;
        if (ty == self.t().int_literal_id) {
            try self.checkLiteralFits(range.list[1], elem);
            try self.checkLiteralFits(range.list[2], elem);
            try self.ctx.recordType(range.list[1], elem);
            try self.ctx.recordType(range.list[2], elem);
        }
        const r = try self.ctx.intern(.{ .range = elem });
        try self.ctx.recordType(range, r);
        return elem;
    }

    fn elementTypeForLoop(self: *Checker, source: Sexp, inner_source: Sexp, source_ty: TypeId, mode: ?Tag) Error!TypeId {
        const pos = firstSrcPos(source);
        if (self.isPoison(source_ty)) return self.t().invalid_id;
        const peeled = types.unwrapBorrows(self.ctx, source_ty);
        switch (self.ctx.types.get(peeled)) {
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.vec_sym_id and pn.args.len == 1) {
                const elem = pn.args[0];
                const is_resource = switch (self.ctx.types.get(elem)) {
                    .shared, .weak => true,
                    else => false,
                };
                if (is_resource) {
                    if (mode != .@"read" and mode != .ptr and mode != .@"write" and mode != .@"move") {
                        try self.err(pos, "resource Vec(T) iteration requires an explicit read borrow; write `for x in ?vec`", .{});
                    }
                    if (inner_source != .src) {
                        try self.err(pos, "resource Vec(T) iteration requires a bare local Vec binding as the source; got an expression. Bind the result to a `Vec(T)` local first.", .{});
                    }
                }
                if (inner_source == .src) {
                    try self.ctx.for_source_vec_info.put(self.ctx.allocator, inner_source.src.pos, .{
                        .elem_ty = elem,
                        .is_resource = is_resource,
                        .is_closure = self.isOwnedClosureHandle(elem),
                    });
                }
                return if (is_resource) try self.ctx.intern(.{ .borrow_read = elem }) else elem;
            },
            .array => |a| return a.elem,
            .slice => |s| return s.elem,
            .string => return try self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            else => {},
        }
        try self.err(pos, "cannot iterate over `{s}`; a `for` source must be a range `a..b`, an array, a String, or a `Vec`", .{try self.tyName(source_ty)});
        return self.t().invalid_id;
    }

    // ---- match ----------------------------------------------------------------

    fn checkMatch(self: *Checker, node: Sexp, position: Position, expected: ?TypeId) Error!TypeId {
        const items = node.list;
        if (items.len < 2) return self.t().invalid_id;
        const scrutinee = try self.synthExpr(items[1]);
        const scrut_pos = firstSrcPos(items[1]);
        switch (self.ctx.types.get(types.unwrapBorrows(self.ctx, scrutinee))) {
            .string, .optional, .fallible, .shared, .weak, .array, .slice, .float, .function => {
                try self.err(scrut_pos, "cannot `match` on a value of type `{s}`; match works on enums, integers, and Bool", .{try self.tyName(scrutinee)});
            },
            else => {},
        }

        var covered: std.StringHashMapUnmanaged(u32) = .empty;
        defer covered.deinit(self.ctx.allocator);
        var has_default = false;
        var result: ?TypeId = expected;

        for (items[2..]) |arm| {
            if (!isHead(arm, .@"arm") or arm.list.len < 3) continue;
            const prev = self.enter(arm);
            defer self.scope = prev;
            try self.checkPattern(arm.list[1], scrutinee, &covered, &has_default);
            if (arm.list.len >= 4) {
                if (self.ctx.symbolOf(arm.list[2])) |s| {
                    self.ctx.symbols.items[s].ty = scrutinee;
                    try self.ctx.recordType(arm.list[2], scrutinee);
                }
            }
            const body = arm.list[arm.list.len - 1];
            switch (position) {
                .statement => try self.checkStmt(body),
                .value => {
                    if (result) |r| {
                        if (expected != null) {
                            try self.checkExpr(body, r);
                        } else {
                            const ty = try self.synthExpr(body);
                            result = (try self.unify(r, ty, firstSrcPos(body))) orelse r;
                        }
                    } else {
                        result = try self.synthExpr(body);
                    }
                },
            }
        }

        if (position == .value and !has_default) {
            if (types.enumVariantCount(self.ctx, scrutinee)) |total| {
                if (covered.count() < total) {
                    try self.err(scrut_pos, "value-position `match` is not exhaustive (covered {d} of {d} variants and no default arm)", .{ covered.count(), total });
                }
            } else if (!self.isPoison(scrutinee) and self.ctx.types.get(scrutinee) != .bool) {
                try self.err(scrut_pos, "value-position `match` on `{s}` needs a default arm", .{try self.tyName(scrutinee)});
            }
        }
        if (position == .statement) return self.t().void_id;
        return result orelse self.t().invalid_id;
    }

    fn checkPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, covered: *std.StringHashMapUnmanaged(u32), has_default: *bool) Error!void {
        switch (pattern) {
            .src => {
                const name = self.text(pattern);
                if (isLiteralText(name)) {
                    try self.checkExpr(pattern, scrutinee);
                    return;
                }
                has_default.* = true;
                if (!std.mem.eql(u8, name, "_")) {
                    if (self.ctx.symbolOf(pattern)) |sym| {
                        self.ctx.symbols.items[sym].ty = scrutinee;
                        try self.ctx.recordType(pattern, scrutinee);
                    }
                }
            },
            .list => |items| {
                const h = headOf(pattern) orelse return;
                switch (h) {
                    .@"enum_lit", .@"enum_pattern" => {
                        if (items.len < 2) return;
                        try self.checkVariantName(items[1], scrutinee);
                        try self.ctx.recordType(pattern, scrutinee);
                        try self.recordCovered(self.text(items[1]), firstSrcPos(pattern), covered);
                    },
                    .@"variant_pattern" => try self.checkVariantPattern(items, scrutinee, covered),
                    .@"range_pattern" => if (items.len >= 3) {
                        try self.checkExpr(items[1], scrutinee);
                        try self.checkExpr(items[2], scrutinee);
                    },
                    else => try self.checkExpr(pattern, scrutinee),
                }
            },
            else => {},
        }
    }

    fn recordCovered(self: *Checker, name: []const u8, pos: u32, covered: *std.StringHashMapUnmanaged(u32)) Error!void {
        if (covered.get(name)) |first| {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            try self.note(first, "first arm here", .{});
            return;
        }
        try covered.put(self.ctx.allocator, name, pos);
    }

    fn checkVariantPattern(self: *Checker, items: []const Sexp, scrutinee: TypeId, covered: *std.StringHashMapUnmanaged(u32)) Error!void {
        const vname = self.text(items[1]);
        const vpos = srcPos(items[1], 0);
        try self.recordCovered(vname, vpos, covered);
        const resolved = (try types.lookupVariant(self.ctx, scrutinee, vname)) orelse {
            try self.reportMissingVariant(scrutinee, vname, vpos);
            return;
        };
        const bindings = items[2..];
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
            const sym = self.ctx.symbolOf(b) orelse continue;
            self.ctx.symbols.items[sym].ty = f.ty;
            try self.ctx.recordType(b, f.ty);
        }
    }

    fn reportMissingVariant(self: *Checker, enum_ty: TypeId, vname: []const u8, pos: u32) Error!void {
        const owner = types.nominalSymOfReceiver(self.ctx, enum_ty) orelse {
            if (!self.isPoison(enum_ty)) {
                try self.err(pos, "`.{s}` is an enum variant, but the expected type `{s}` is not an enum", .{ vname, try self.tyName(enum_ty) });
            }
            return;
        };
        const sym = self.ctx.symbols.items[owner];
        if (sym.fields == null) return;
        try self.err(pos, "no variant `{s}` on enum `{s}`", .{ vname, sym.name });
        if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
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
                if (headOf(e) == null) break :blk self.t().invalid_id;
                break :blk self.synthList(e);
            },
        };
    }

    fn synthLeaf(self: *Checker, leaf: Sexp) Error!TypeId {
        const s = self.text(leaf);
        if (s.len == 0) return self.t().invalid_id;
        if (s[0] == '"' or s[0] == '\'') return self.t().string_id;
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return self.t().bool_id;
        if (types.isFloatLiteralText(s)) return self.t().float_literal_id;
        if (types.isIntLiteralText(s)) {
            if (std.fmt.parseInt(u64, s, 0)) |_| {} else |_| {
                try self.err(leaf.src.pos, "integer literal `{s}` is too large", .{s});
                return self.t().invalid_id;
            }
            return self.t().int_literal_id;
        }
        const id = (try self.useName(leaf)) orelse return self.t().unknown_id;
        const sym = self.ctx.symbols.items[id];
        switch (sym.kind) {
            .nominal_type, .generic_type, .type_alias, .generic_param => {
                try self.err(leaf.src.pos, "`{s}` is a type, not a value", .{s});
                return self.t().invalid_id;
            },
            .module => {
                try self.err(leaf.src.pos, "`{s}` is a module, not a value; use `{s}.name`", .{ s, s });
                return self.t().invalid_id;
            },
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
            if (s == types.scope_invalid or s >= self.ctx.scopes.items.len) break;
            if (self.ctx.lookupInScopeOnly(s, name)) |id| {
                try self.ctx.recordName(leaf, id);
                const sym = self.ctx.symbols.items[id];
                const kind = sym.kind;
                if (kind == .local and sym.ty == self.t().unknown_id and sym.decl_pos != leaf.src.pos) {
                    try self.err(leaf.src.pos, "`{s}` is used before it has a value", .{name});
                }
                if (crossed_lambda and s != self.module_scope and (kind == .local or kind == .param or kind == .capture)) {
                    try self.err(leaf.src.pos, "`{s}` is a local of the enclosing function; capture it to use it inside the closure (`|{s}|`, `|+{s}|`, or `|<{s}|`)", .{ name, name, name, name });
                }
                return id;
            }
            const scope = self.ctx.scopes.items[s];
            if (scope.kind == .lambda) crossed_lambda = true;
            sid = scope.parent;
        }
        try self.err(leaf.src.pos, "use of unbound name `{s}`", .{name});
        return null;
    }

    fn synthList(self: *Checker, e: Sexp) Error!TypeId {
        const items = e.list;
        const head = items[0].tag;
        return switch (head) {
            .@"call" => self.synthCall(e),
            .@"member" => self.synthMember(items),
            .@"index" => self.synthIndex(items),
            .@"propagate", .@"try" => self.synthPropagate(items),
            .@"if" => self.checkIfValue(e, null, .value),
            .@"ternary" => self.synthTernary(items, null),
            .@"match" => self.checkMatch(e, .value, null),
            .@"block" => self.synthBlock(e, null),
            .@"raw_block" => if (items.len >= 2) self.synthExpr(items[1]) else self.t().void_id,
            .@"read" => self.synthBorrow(items, .read),
            .@"write" => self.synthBorrow(items, .write),
            .@"move" => if (items.len >= 2) self.synthExpr(items[1]) else self.t().invalid_id,
            .@"share" => self.synthShare(items),
            .@"weak" => self.synthWeak(items),
            .@"clone" => self.synthClone(items),
            .@"raw" => self.synthRawAccess(items),
            .@"pin" => blk: {
                try self.err(firstSrcPos(e), "pinning sigil `@x` is reserved; Rig does not support pinned/stable-address values. Remove the `@` prefix, or call a builtin such as `@sizeOf(T)`.", .{});
                break :blk self.t().invalid_id;
            },
            .@"+", .@"-", .@"*", .@"/", .@"%" => self.checkNumericOperands(items, @tagName(head), .numeric),
            .@"**" => blk: {
                try self.err(firstSrcPos(e), "operator `**` is not supported; multiply explicitly", .{});
                _ = try self.synthExpr(items[1]);
                _ = try self.synthExpr(items[2]);
                break :blk self.t().invalid_id;
            },
            .@"&", .@"|", .@"^", .@"<<", .@">>" => self.checkNumericOperands(items, @tagName(head), .integer),
            .@"<", .@">", .@"<=", .@">=" => blk: {
                _ = try self.checkNumericOperands(items, @tagName(head), .ordered);
                break :blk self.t().bool_id;
            },
            .@"==", .@"!=" => self.synthEquality(items),
            .@"&&", .@"||" => blk: {
                try self.checkExpr(items[1], self.t().bool_id);
                try self.checkExpr(items[2], self.t().bool_id);
                break :blk self.t().bool_id;
            },
            .@"not" => blk: {
                if (items.len >= 2) try self.checkExpr(items[1], self.t().bool_id);
                break :blk self.t().bool_id;
            },
            .@"neg" => self.synthNeg(items),
            .@"??" => self.synthCoalesce(items, null),
            .@"catch" => self.synthCatch(items, null),
            .@"null" => self.t().none_id,
            .@"array" => self.synthArray(e),
            .@"enum_lit" => blk: {
                try self.err(firstSrcPos(e), "enum literal `.{s}` needs a known enum type; write `Type.{s}` or annotate the binding", .{ self.text(items[1]), self.text(items[1]) });
                break :blk self.t().invalid_id;
            },
            .@"lambda" => self.synthLambda(e),
            .@"builtin" => self.synthBuiltin(e, null),
            .@"..", => blk: {
                try self.err(firstSrcPos(e), "a range `a..b` can only be used as a `for` loop source", .{});
                break :blk self.t().invalid_id;
            },
            .@"set", .@"while", .@"for", .@"drop", .@"defer", .@"errdefer", .@"labeled" => blk: {
                try self.checkStmt(e);
                break :blk self.t().void_id;
            },
            .@"return" => blk: {
                try self.checkReturn(items);
                break :blk self.t().noreturn_id;
            },
            .@"break", .@"continue" => blk: {
                try self.checkJump(items);
                break :blk self.t().noreturn_id;
            },
            .@"pre", .@"pre_block" => blk: {
                try self.err(firstSrcPos(e), "`pre` expression / block is reserved; only `pre` parameters (compile-time function parameters) are supported. Remove the `pre` modifier or use a regular binding.", .{});
                break :blk self.t().invalid_id;
            },
            .@"try_block" => blk: {
                try self.err(firstSrcPos(e), "value-yielding `try INDENT body OUTDENT [catch |e| ...]` block is reserved; use `expr!` to propagate or `expr catch handler` to recover", .{});
                break :blk self.t().invalid_id;
            },
            .@"zig" => blk: {
                try self.err(firstSrcPos(e), "inline `zig \"...\"` raw-Zig escape is reserved; the audit boundary is a `raw` block and the FFI boundary is `extern`", .{});
                break :blk self.t().invalid_id;
            },
            .@"record" => blk: {
                try self.err(firstSrcPos(e), "`Name {{...}}` record syntax is not supported; construct with `Name(field: value)`", .{});
                break :blk self.t().invalid_id;
            },
            .@"anon_init" => blk: {
                try self.err(firstSrcPos(e), "anonymous initializer `.{{...}}` is not supported; construct with `Type(field: value)`", .{});
                break :blk self.t().invalid_id;
            },
            .@"undefined" => blk: {
                try self.err(firstSrcPos(e), "`undefined` is not supported; initialize the value", .{});
                break :blk self.t().invalid_id;
            },
            .@"unreachable" => blk: {
                try self.err(firstSrcPos(e), "`unreachable` is not supported yet", .{});
                break :blk self.t().invalid_id;
            },
            .@"as" => blk: {
                try self.err(firstSrcPos(e), "`opt as name` is only allowed as an `if` or `while` condition", .{});
                break :blk self.t().invalid_id;
            },
            .@"kwarg" => blk: {
                try self.err(firstSrcPos(e), "`name: value` is only allowed as a call argument", .{});
                break :blk self.t().invalid_id;
            },
            else => blk: {
                try self.err(firstSrcPos(e), "`{s}` expressions are not supported", .{@tagName(head)});
                break :blk self.t().invalid_id;
            },
        };
    }

    // ---- operators ------------------------------------------------------------

    /// Both operands numeric (or integer) and of one type. Literals adapt
    /// to the other operand; generic parameters record a requirement.
    fn checkNumericOperands(self: *Checker, items: []const Sexp, op: []const u8, req: Requirement) Error!TypeId {
        if (items.len < 3) return self.t().invalid_id;
        const a = try self.synthExpr(items[1]);
        const b = try self.synthExpr(items[2]);
        const pos = firstSrcPos(items[1]);
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
            try self.require(self.ctx.types.get(tv).type_var, req, pos, op);
            return tv;
        }

        const want_int = req == .integer;
        for ([_]TypeId{ a, b }, 0..) |ty, i| {
            const ok = if (want_int) types.isInteger(self.ctx, ty) else types.isNumeric(self.ctx, ty);
            if (!ok) {
                try self.err(firstSrcPos(items[1 + i]), "operator `{s}` requires {s} operands; got `{s}`", .{ op, if (want_int) "integer" else "numeric", try self.tyName(ty) });
                return self.t().invalid_id;
            }
        }
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        if (a_lit and b_lit) {
            return if (a == self.t().float_literal_id or b == self.t().float_literal_id) self.t().float_literal_id else self.t().int_literal_id;
        }
        if (a_lit) {
            try self.checkExpr(items[1], b);
            return b;
        }
        if (b_lit) {
            try self.checkExpr(items[2], a);
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

    fn synthNeg(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        const ty = try self.synthExpr(items[1]);
        if (self.isPoison(ty)) return ty;
        switch (self.ctx.types.get(ty)) {
            .int => |info| if (!info.signed) {
                try self.err(firstSrcPos(items[1]), "cannot negate a value of unsigned type `{s}`", .{try self.tyName(ty)});
                return self.t().invalid_id;
            },
            .float, .int_literal, .float_literal => {},
            .type_var => |tv| try self.require(tv, .numeric, firstSrcPos(items[1]), "-"),
            else => {
                try self.err(firstSrcPos(items[1]), "operator `-` requires a numeric operand; got `{s}`", .{try self.tyName(ty)});
                return self.t().invalid_id;
            },
        }
        return ty;
    }

    fn synthEquality(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 3) return self.t().bool_id;
        const op = @tagName(items[0].tag);
        const l = items[1];
        const r = items[2];
        // A contextual operand (`.red`, `none`) takes the other side's type.
        if (isContextual(l) and !isContextual(r)) {
            try self.checkExpr(l, try self.synthExpr(r));
            return self.t().bool_id;
        }
        if (isContextual(r)) {
            try self.checkExpr(r, try self.synthExpr(l));
            return self.t().bool_id;
        }
        const a = try self.synthExpr(l);
        const b = try self.synthExpr(r);
        if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
        if (types.isNumeric(self.ctx, a) and types.isNumeric(self.ctx, b)) {
            _ = try self.checkNumericComparison(items, a, b, op);
            return self.t().bool_id;
        }
        const ta = self.ctx.types.get(a);
        const tb = self.ctx.types.get(b);
        if (ta == .type_var or tb == .type_var) {
            if (a != b and !(ta == .type_var and types.isNumeric(self.ctx, b)) and !(tb == .type_var and types.isNumeric(self.ctx, a))) {
                try self.err(firstSrcPos(l), "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
                return self.t().bool_id;
            }
            const tv = if (ta == .type_var) ta.type_var else tb.type_var;
            try self.require(tv, .equatable, firstSrcPos(l), op);
            return self.t().bool_id;
        }
        if (a != b) {
            try self.err(firstSrcPos(l), "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
            return self.t().bool_id;
        }
        try self.checkEquatable(a, l, op);
        return self.t().bool_id;
    }

    /// Numeric equality: same rules as arithmetic, with operands already synthesized.
    fn checkNumericComparison(self: *Checker, items: []const Sexp, a: TypeId, b: TypeId, op: []const u8) Error!void {
        const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
        const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
        if (a_lit and !b_lit) return self.checkExpr(items[1], b);
        if (b_lit and !a_lit) return self.checkExpr(items[2], a);
        if (!a_lit and a != b) {
            try self.err(firstSrcPos(items[1]), "cannot compare `{s}` with `{s}` using `{s}`", .{ try self.tyName(a), try self.tyName(b), op });
        }
    }

    fn checkEquatable(self: *Checker, ty: TypeId, node: Sexp, op: []const u8) Error!void {
        if (self.isPoison(ty)) return;
        const ok = switch (self.ctx.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string => true,
            .optional => |inner| satisfies(self.ctx, inner, .equatable),
            .nominal => |s| isPlainEnum(self.ctx, s),
            .type_var => |tv| blk: {
                try self.require(tv, .equatable, firstSrcPos(node), op);
                break :blk true;
            },
            else => false,
        };
        if (!ok) {
            try self.err(firstSrcPos(node), "`{s}` is not defined for `{s}`", .{ op, try self.tyName(ty) });
        }
    }

    fn synthTernary(self: *Checker, items: []const Sexp, expected: ?TypeId) Error!TypeId {
        if (items.len < 4) return self.t().invalid_id;
        try self.checkExpr(items[1], self.t().bool_id);
        if (expected) |e| {
            try self.checkExpr(items[2], e);
            try self.checkExpr(items[3], e);
            return e;
        }
        const a = try self.synthExpr(items[2]);
        const b = try self.synthExpr(items[3]);
        return (try self.unify(a, b, firstSrcPos(items[3]))) orelse self.t().invalid_id;
    }

    fn synthBlock(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const items = node.list;
        if (items.len <= 1) {
            if (expected) |e| if (!self.isPoison(e) and e != self.t().void_id) {
                try self.err(firstSrcPos(node), "empty block where a `{s}` is expected", .{try self.tyName(e)});
            };
            return self.t().void_id;
        }
        const prev = self.enter(node);
        defer self.scope = prev;
        for (items[1 .. items.len - 1]) |s| try self.checkStmt(s);
        const last = items[items.len - 1];
        if (expected) |e| {
            try self.checkExpr(last, e);
            return e;
        }
        return self.synthExpr(last);
    }

    /// `a ?? b`: the value inside optional `a`, or `b` when `a` is `none`.
    fn synthCoalesce(self: *Checker, items: []const Sexp, expected: ?TypeId) Error!TypeId {
        if (items.len < 3) return self.t().invalid_id;
        const opt = try self.synthExpr(items[1]);
        if (self.isPoison(opt)) {
            _ = try self.synthExpr(items[2]);
            return opt;
        }
        const inner = switch (self.ctx.types.get(types.unwrapBorrows(self.ctx, opt))) {
            .optional => |i| i,
            else => {
                try self.err(firstSrcPos(items[1]), "`??` needs an optional on its left; this expression has type `{s}`", .{try self.tyName(opt)});
                _ = try self.synthExpr(items[2]);
                return self.t().invalid_id;
            },
        };
        if (types.typeHasDropGlue(self.ctx, inner)) {
            try self.err(firstSrcPos(items[1]), "`??` on an optional `{s}` would copy an owning handle out of it; unwrap with `if opt as name` instead", .{try self.tyName(opt)});
            return self.t().invalid_id;
        }
        const result = expected orelse inner;
        if (expected != null and !compatible(self.ctx, inner, result)) {
            try self.err(firstSrcPos(items[1]), "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(result), try self.tyName(inner) });
        }
        try self.checkExpr(items[2], inner);
        return inner;
    }

    /// `expr catch handler`: the value of fallible `expr`, or `handler`.
    fn synthCatch(self: *Checker, items: []const Sexp, expected: ?TypeId) Error!TypeId {
        if (items.len < 3) return self.t().invalid_id;
        if (items.len >= 4) {
            try self.err(srcPos(items[2], firstSrcPos(.{ .list = items })), "naming the error in `catch |err|` is not supported yet; write `expr catch fallback`", .{});
            return self.t().invalid_id;
        }
        const ty = try self.synthExpr(items[1]);
        if (self.isPoison(ty)) {
            _ = try self.synthExpr(items[2]);
            return ty;
        }
        const inner = switch (self.ctx.types.get(ty)) {
            .fallible => |i| i,
            else => {
                try self.err(firstSrcPos(items[1]), "`catch` needs a fallible expression; this expression has type `{s}` and cannot fail", .{try self.tyName(ty)});
                _ = try self.synthExpr(items[2]);
                return self.t().invalid_id;
            },
        };
        _ = expected;
        try self.checkExpr(items[2], inner);
        return inner;
    }

    fn synthPropagate(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        const ty = try self.synthExpr(items[1]);
        // Propagating a value that cannot fail is reported by effects.
        return switch (self.ctx.types.get(ty)) {
            .fallible => |inner| inner,
            else => ty,
        };
    }

    // ---- ownership sigils -----------------------------------------------------

    const BorrowKind = enum { read, write };

    /// `?x` / `!x`. Borrowing a borrowed value reborrows it rather than
    /// nesting (`?b` with `b: ?B` is `?B`).
    fn synthBorrow(self: *Checker, items: []const Sexp, kind: BorrowKind) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        const inner = try self.synthOperand(items[1]);
        if (self.isPoison(inner)) return inner;
        switch (self.ctx.types.get(inner)) {
            .borrow_read => {
                if (kind == .read) return inner;
                try self.err(firstSrcPos(items[1]), "cannot write-borrow through a read borrow `{s}`", .{try self.tyName(inner)});
                return self.t().invalid_id;
            },
            .borrow_write => |base| {
                return if (kind == .write) inner else self.ctx.intern(.{ .borrow_read = base });
            },
            else => {},
        }
        return self.ctx.intern(if (kind == .read) Type{ .borrow_read = inner } else Type{ .borrow_write = inner });
    }

    fn synthShare(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        if (try self.ownedClosureConstruction(items[1])) |ty| return ty;
        const inner = try self.synthExpr(items[1]);
        if (self.isPoison(inner)) return inner;
        if (self.ctx.types.get(inner) == .shared) {
            try self.err(firstSrcPos(items[1]), "`*x` of a shared handle `{s}` would nest handles; clone it with `+x` instead", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        return self.ctx.intern(.{ .shared = inner });
    }

    fn synthWeak(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        const inner = try self.synthOperand(items[1]);
        if (self.isPoison(inner)) return inner;
        switch (self.ctx.types.get(inner)) {
            .shared => |target| return self.ctx.intern(.{ .weak = target }),
            else => {
                try self.err(firstSrcPos(items[1]), "`~` weak reference requires a shared handle `*T`; got `{s}`", .{try self.tyName(inner)});
                return self.t().invalid_id;
            },
        }
    }

    fn synthClone(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        const inner = try self.synthOperand(items[1]);
        if (self.isPoison(inner)) return inner;
        switch (self.ctx.types.get(types.unwrapBorrows(self.ctx, inner))) {
            .shared, .weak => return types.unwrapBorrows(self.ctx, inner),
            else => {},
        }
        if (types.typeHasDropGlue(self.ctx, inner)) {
            try self.err(firstSrcPos(items[1]), "`+x` cannot clone a `{s}`; only `*T` and `~T` handles and plain values can be cloned", .{try self.tyName(inner)});
            return self.t().invalid_id;
        }
        return types.unwrapBorrows(self.ctx, inner);
    }

    fn synthRawAccess(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 2) return self.t().invalid_id;
        return self.synthOperand(items[1]);
    }

    /// Synthesize the operand of a borrow, clone, member access, index,
    /// or method call. Such an operand is not bound to a name, so a fresh
    /// `*Foo(...)` or a call returning `*T` there would never be dropped.
    fn synthOperand(self: *Checker, operand: Sexp) Error!TypeId {
        if (isFreshResourceAlloc(operand)) {
            try self.err(firstSrcPos(operand), "resource allocation `*{s}` used as an anonymous temporary; bind it to a name first so it is dropped at scope exit", .{self.freshAllocName(operand)});
            return self.t().invalid_id;
        }
        const ty = try self.synthExpr(operand);
        if (isHead(operand, .@"call") and self.ctx.types.get(ty) == .shared) {
            try self.err(firstSrcPos(operand), "resource-valued call result used as an anonymous temporary; bind it to a name first so it is dropped at scope exit", .{});
            return self.t().invalid_id;
        }
        return ty;
    }

    fn freshAllocName(self: *Checker, operand: Sexp) []const u8 {
        const call = operand.list[1];
        if (call.list.len >= 2) {
            if (call.list[1] == .src) return self.text(call.list[1]);
        }
        return "Ctor";
    }

    // ---- member access and indexing -------------------------------------------

    fn synthMember(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 3) return self.t().invalid_id;
        const obj = items[1];
        const field_node = items[2];
        const field = self.text(field_node);
        const pos = srcPos(field_node, firstSrcPos(obj));

        if (obj == .src) {
            if (try self.qualifiedMember(obj, field_node)) |ty| return ty;
        }

        const obj_ty = try self.synthOperand(obj);
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = types.unwrapReadAccess(self.ctx, obj_ty);
        const pty = self.ctx.types.get(peeled);

        switch (pty) {
            .optional => {
                try self.err(pos, "cannot access `{s}` on optional `{s}`; unwrap it first with `if x as v` or `x ?? default`", .{ field, try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            .array, .slice, .string => if (std.mem.eql(u8, field, "len")) {
                return self.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } });
            },
            .imported_nominal => |in| return self.importedField(in, field, pos),
            .type_var => {
                try self.err(pos, "a generic parameter `{s}` has no fields; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
                return self.t().invalid_id;
            },
            else => {},
        }

        if (std.mem.eql(u8, field, "value")) {
            if (cellElementType(self.ctx, obj_ty)) |elem| {
                if (types.typeHasDropGlue(self.ctx, elem)) {
                    try self.err(pos, "`cell.value` reads `T` by value but `T = {s}` has drop glue; a copy would alias the cell's owned value. Use `cell.replace(<new)` to swap-and-yield the old value.", .{try self.tyName(elem)});
                    return self.t().invalid_id;
                }
            }
        }

        if (try types.lookupDataField(self.ctx, obj_ty, field)) |f| return f.ty;

        const owner = types.nominalSymOfReceiver(self.ctx, peeled);
        if (types.hasMethodNamed(self.ctx, obj_ty, field)) {
            try self.err(pos, "method `{s}` on type `{s}` must be called; a bare method reference is not supported", .{ field, if (owner) |o| self.ctx.symbols.items[o].name else try self.tyName(peeled) });
            return self.t().invalid_id;
        }
        if (owner) |o| {
            const sym = self.ctx.symbols.items[o];
            if (sym.fields == null) {
                try self.err(pos, "opaque type `{s}` has no accessible fields", .{sym.name});
            } else {
                try self.err(pos, "no field `{s}` on type `{s}`", .{ field, sym.name });
                if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
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
        const id = self.lookupQuiet(name) orelse return null;
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
                if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
                return self.t().invalid_id;
            },
            .module => {
                try self.ctx.recordName(obj, id);
                const found = (try self.foreignSymbol(id, field, pos)) orelse return self.t().invalid_id;
                if (found.sym.kind == .nominal_type) {
                    try self.err(pos, "`{s}.{s}` is a type, not a value", .{ name, field });
                    return self.t().invalid_id;
                }
                return try types.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
            },
            else => return null,
        }
    }

    fn lookupQuiet(self: *Checker, name: []const u8) ?SymbolId {
        return self.ctx.lookup(self.scope, name);
    }

    const Foreign = struct {
        ctx: *SemContext,
        module_id: u32,
        id: SymbolId,
        sym: types.Symbol,
    };

    /// A public module-level symbol of an imported module.
    fn foreignSymbol(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32) Error!?Foreign {
        const module_name = self.ctx.symbols.items[module_sym].name;
        const origin = self.ctx.module_refs.get(module_sym) orelse {
            try self.err(pos, "module `{s}` was not loaded", .{module_name});
            return null;
        };
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        if (foreign.scopes.items.len < 2) return null;
        for (foreign.scopes.items[1].symbols.items) |fid| {
            const fsym = foreign.symbols.items[fid];
            if (!std.mem.eql(u8, fsym.name, name)) continue;
            if (!fsym.flags.is_public and fsym.decl_pos != types.builtin_decl_pos) {
                try self.err(pos, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ module_name, name, module_name });
                return null;
            }
            return .{ .ctx = foreign, .module_id = origin, .id = fid, .sym = fsym };
        }
        try self.err(pos, "no member `{s}` in module `{s}`", .{ name, module_name });
        return null;
    }

    fn importedField(self: *Checker, in: types.ImportedNominal, field: []const u8, pos: u32) Error!TypeId {
        const foreign = self.ctx.foreign_semas.get(in.module_id) orelse return self.t().invalid_id;
        const sym = foreign.symbols.items[in.sym_id];
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant or !std.mem.eql(u8, f.name, field)) continue;
            return types.importType(self.ctx, foreign, f.ty, in.module_id);
        }
        try self.err(pos, "no field `{s}` on type `{s}`", .{ field, sym.name });
        return self.t().invalid_id;
    }

    fn synthIndex(self: *Checker, items: []const Sexp) Error!TypeId {
        if (items.len < 3) return self.t().invalid_id;
        const obj_ty = try self.synthOperand(items[1]);
        if (isHead(items[2], .@"..")) {
            try self.err(firstSrcPos(items[2]), "slicing `xs[a..b]` is not supported yet", .{});
            return self.t().invalid_id;
        }
        const idx_ty = try self.synthExpr(items[2]);
        if (!self.isPoison(idx_ty) and !types.isInteger(self.ctx, idx_ty)) {
            try self.err(firstSrcPos(items[2]), "an index must be an integer; got `{s}`", .{try self.tyName(idx_ty)});
        } else if (idx_ty == self.t().int_literal_id) {
            try self.ctx.recordType(items[2], self.t().int_id);
        }
        if (self.isPoison(obj_ty)) return obj_ty;
        const peeled = types.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .array => |a| return a.elem,
            .slice => |s| return s.elem,
            .string => return self.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } }),
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.vec_sym_id and pn.args.len == 1) {
                if (types.typeHasDropGlue(self.ctx, pn.args[0])) {
                    try self.err(firstSrcPos(items[1]), "indexing a `{s}` would copy an owning handle out of the Vec; iterate with `for x in ?v` instead", .{try self.tyName(peeled)});
                    return self.t().invalid_id;
                }
                return pn.args[0];
            },
            else => {},
        }
        try self.err(firstSrcPos(items[1]), "cannot index a value of type `{s}`", .{try self.tyName(obj_ty)});
        return self.t().invalid_id;
    }

    // ---- array literals ------------------------------------------------------

    fn synthArray(self: *Checker, node: Sexp) Error!TypeId {
        const elems = node.list[1..];
        if (elems.len == 0) {
            try self.err(firstSrcPos(node), "an empty array literal needs a type annotation (`xs: [0]Int = []`)", .{});
            return self.t().invalid_id;
        }
        var elem = try self.synthExpr(elems[0]);
        for (elems[1..]) |e| {
            const ty = try self.synthExpr(e);
            elem = (try self.unify(elem, ty, firstSrcPos(e))) orelse return self.t().invalid_id;
        }
        const concrete = self.canonical(elem);
        if (concrete != elem) {
            for (elems) |e| try self.checkExpr(e, concrete);
        }
        return self.ctx.intern(.{ .array = .{ .elem = concrete, .len = elems.len } });
    }

    fn checkArray(self: *Checker, node: Sexp, expected: TypeId) Error!bool {
        const et = self.ctx.types.get(expected);
        if (et != .array) return false;
        const elems = node.list[1..];
        if (elems.len != et.array.len) {
            try self.err(firstSrcPos(node), "array literal has {d} element{s}; `{s}` needs {d}", .{ elems.len, plural(elems.len), try self.tyName(expected), et.array.len });
        }
        for (elems) |e| try self.checkExpr(e, et.array.elem);
        try self.ctx.recordType(node, expected);
        return true;
    }

    // =========================================================================
    // Calls
    // =========================================================================

    fn synthCall(self: *Checker, node: Sexp) Error!TypeId {
        const items = node.list;
        if (items.len < 2) return self.t().invalid_id;
        const callee = items[1];
        const args = items[2..];

        if (callee == .src) {
            const name = self.text(callee);
            const id = self.lookupQuiet(name) orelse {
                if (std.mem.eql(u8, name, "print")) return self.checkPrint(args);
                try self.err(callee.src.pos, "use of unbound name `{s}`", .{name});
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
                        try self.err(callee.src.pos, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(sym.ty) });
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    }
                    try self.checkArgs(args, fty.function, self.paramNamesOf(sym_id), name, callee.src.pos);
                    return fty.function.returns;
                },
                .nominal_type => return self.construct(sym_id, args, callee.src.pos, TypeSubst.empty, null),
                .type_alias => {
                    try self.err(callee.src.pos, "`{s}` is a type alias for `{s}` and cannot be called as a constructor; construct the aliased type directly", .{ name, try self.tyName(sym.ty) });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                .generic_type => {
                    if (sym_id == self.ctx.closure_sym_id) {
                        try self.err(callee.src.pos, "owned closure must be wrapped with `*`; write `*Closure(|...| body)`", .{});
                    } else {
                        try self.err(callee.src.pos, "generic constructor `{s}` requires an expected type; write `b: {s}(T) = {s}(...)`", .{ name, name, name });
                    }
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                .module => {
                    try self.err(callee.src.pos, "module `{s}` cannot be called", .{name});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                else => return self.callValue(callee, sym.ty, args, name),
            }
        }

        if (isHead(callee, .@"member") and callee.list.len >= 3) return self.synthMemberCall(callee.list, args);

        if (isHead(callee, .@"enum_lit")) {
            try self.err(firstSrcPos(callee), "variant `.{s}(...)` needs a known enum type; annotate the binding", .{self.text(callee.list[1])});
            try self.synthArgs(args);
            return self.t().invalid_id;
        }

        const callee_ty = try self.synthExpr(callee);
        return self.callValue(callee, callee_ty, args, "expression");
    }

    /// Call a value: a function-typed binding, a closure, or an owned
    /// closure handle.
    fn callValue(self: *Checker, callee: Sexp, ty: TypeId, args: []const Sexp, name: []const u8) Error!TypeId {
        const pos = firstSrcPos(callee);
        if (self.isPoison(ty)) {
            try self.synthArgs(args);
            return self.t().invalid_id;
        }
        if (ownedClosureArgs(self.ctx, ty)) |params| {
            if (args.len != params.len) {
                try self.err(pos, "owned closure `{s}` invocation expects {d} argument(s); got {d}", .{ name, params.len, args.len });
                try self.synthArgs(args);
            } else {
                for (args, params) |a, p| try self.checkExpr(a, p);
            }
            return self.t().void_id;
        }
        const fty = self.ctx.types.get(types.unwrapBorrows(self.ctx, ty));
        if (fty == .function) {
            try self.checkArgs(args, fty.function, null, name, pos);
            return fty.function.returns;
        }
        try self.err(pos, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(ty) });
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    fn synthArgs(self: *Checker, args: []const Sexp) Error!void {
        for (args) |a| {
            if (isHead(a, .@"kwarg") and a.list.len >= 3) {
                _ = try self.synthExpr(a.list[2]);
            } else _ = try self.synthExpr(a);
        }
    }

    /// `print(x)`: one value (or none, for a blank line).
    fn checkPrint(self: *Checker, args: []const Sexp) Error!TypeId {
        if (args.len > 1) {
            try self.err(firstSrcPos(args[1]), "`print` takes one value; got {d}", .{args.len});
        }
        for (args) |a| {
            if (isHead(a, .@"kwarg")) {
                try self.err(firstSrcPos(a), "`print` takes no keyword arguments", .{});
                continue;
            }
            const ty = try self.synthExpr(a);
            switch (self.ctx.types.get(ty)) {
                .void => try self.err(firstSrcPos(a), "`print` needs a value; this expression produces no value (`Void`)", .{}),
                .none_literal => try self.err(firstSrcPos(a), "cannot print a bare `none`", .{}),
                .function => try self.err(firstSrcPos(a), "cannot print a function", .{}),
                else => {},
            }
        }
        return self.t().void_id;
    }

    fn paramNamesOf(self: *Checker, sym_id: SymbolId) ?[]const []const u8 {
        return self.ctx.symbols.items[sym_id].param_names;
    }

    /// Arguments against a signature: arity, types, keyword arguments
    /// by parameter name, and compile-time-known values for `pre`
    /// parameters.
    fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, names: ?[]const []const u8, callee: []const u8, pos: u32) Error!void {
        var first_kw: ?usize = null;
        for (args, 0..) |a, i| {
            if (isHead(a, .@"kwarg")) {
                if (first_kw == null) first_kw = i;
            } else if (first_kw != null) {
                try self.err(firstSrcPos(a), "positional arguments must come before keyword arguments", .{});
                try self.synthArgs(args);
                return;
            }
        }
        const positional = args[0 .. first_kw orelse args.len];
        const keyword = args[positional.len..];
        if (keyword.len > 0 and names == null) {
            try self.err(firstSrcPos(keyword[0]), "`{s}` takes positional arguments only", .{callee});
            try self.synthArgs(args);
            return;
        }
        if (args.len != f.params.len) {
            try self.err(pos, "call to `{s}` expects {d} argument{s}, got {d}", .{ callee, f.params.len, plural(f.params.len), args.len });
            try self.synthArgs(args);
            return;
        }
        var filled = try self.ctx.allocator.alloc(bool, f.params.len);
        defer self.ctx.allocator.free(filled);
        @memset(filled, false);
        for (positional, 0..) |a, i| {
            filled[i] = true;
            try self.checkArg(a, f, i, callee);
        }
        for (keyword) |kw| {
            const kname = self.text(kw.list[1]);
            const idx = for (names.?, 0..) |n, i| {
                if (std.mem.eql(u8, n, kname)) break i;
            } else {
                try self.err(srcPos(kw.list[1], pos), "`{s}` has no parameter `{s}`", .{ callee, kname });
                _ = try self.synthExpr(kw.list[2]);
                continue;
            };
            if (filled[idx]) {
                try self.err(srcPos(kw.list[1], pos), "parameter `{s}` of `{s}` is given twice", .{ kname, callee });
                _ = try self.synthExpr(kw.list[2]);
                continue;
            }
            filled[idx] = true;
            try self.checkArg(kw.list[2], f, idx, callee);
        }
    }

    fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, callee: []const u8) Error!void {
        try self.checkExpr(arg, f.params[i]);
        if (f.isPre(i) and !self.isComptimeKnown(arg)) {
            try self.err(firstSrcPos(arg), "argument {d} of `{s}` is a `pre` parameter and must be known at compile time; pass a literal, an enum value, a `pre` parameter, or a `=!` binding of one", .{ i + 1, callee });
        }
    }

    /// Values Zig can evaluate at compile time.
    fn isComptimeKnown(self: *Checker, e: Sexp) bool {
        switch (e) {
            .src => {
                const s = self.text(e);
                if (isLiteralText(s)) return true;
                const id = self.ctx.symbolOf(e) orelse (self.lookupQuiet(s) orelse return false);
                return self.ctx.symbols.items[id].flags.comptime_known;
            },
            .list => |items| {
                const h = headOf(e) orelse return false;
                return switch (h) {
                    .@"enum_lit", .@"null" => true,
                    .@"neg", .@"not" => items.len >= 2 and self.isComptimeKnown(items[1]),
                    .@"+", .@"-", .@"*", .@"/", .@"%", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&&", .@"||" => items.len >= 3 and self.isComptimeKnown(items[1]) and self.isComptimeKnown(items[2]),
                    .@"member" => items.len >= 3 and items[1] == .src and blk: {
                        const id = self.lookupQuiet(self.text(items[1])) orelse break :blk false;
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
            if (!isHead(a, .@"kwarg")) positional += 1;
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
            const fname = self.text(a.list[1]);
            const fpos = srcPos(a.list[1], info.pos);
            if (seen.get(fname)) |first| {
                try self.err(fpos, "duplicate field `{s}` in {s} `{s}`", .{ fname, noun, info.owner });
                try self.note(first, "first `{s}` here", .{fname});
                _ = try self.synthExpr(a.list[2]);
                continue;
            }
            try seen.put(self.ctx.allocator, fname, fpos);
            const f = for (fields) |f| {
                if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, fname)) break f;
            } else {
                try self.err(fpos, "no field `{s}` on {s} `{s}`", .{ fname, if (info.kind == .constructor) "type" else "variant", info.owner });
                if (info.foreign == null and info.decl_pos != types.builtin_decl_pos and info.decl_pos != 0) try self.note(info.decl_pos, "`{s}` declared here", .{info.owner});
                _ = try self.synthExpr(a.list[2]);
                continue;
            };
            try self.checkExpr(a.list[2], try self.fieldType(f, info));
        }
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.has_default or seen.contains(f.name)) continue;
            if (info.kind == .constructor) {
                try self.err(info.pos, "constructor of `{s}` is missing field `{s}`", .{ info.owner, f.name });
            } else {
                try self.err(info.pos, "variant `{s}` is missing field `{s}`", .{ info.owner, f.name });
            }
            if (info.foreign == null and f.decl_pos != types.builtin_decl_pos) try self.note(f.decl_pos, "field `{s}` declared here", .{f.name});
        }
    }

    fn fieldType(self: *Checker, f: Field, info: FieldArgs) Error!TypeId {
        if (info.foreign) |fo| return types.importType(self.ctx, fo.ctx, f.ty, fo.module_id);
        return types.substituteType(self.ctx, f.ty, info.subst);
    }

    // ---- method calls -----------------------------------------------------------

    /// Method calls also record the callee `(member obj name)` node's
    /// type: the resolved method's signature.
    fn synthMemberCall(self: *Checker, callee: []const Sexp, args: []const Sexp) Error!TypeId {
        const saved = self.callee_node;
        self.callee_node = .{ .list = callee };
        defer self.callee_node = saved;
        return self.synthMemberCallInner(callee, args);
    }

    fn noteCallee(self: *Checker, f: FunctionType) Error!void {
        try self.noteCalleeType(try self.ctx.intern(.{ .function = f }));
    }

    fn noteCalleeType(self: *Checker, ty: TypeId) Error!void {
        if (self.callee_node) |n| try self.ctx.recordType(n, ty);
    }

    fn synthMemberCallInner(self: *Checker, callee: []const Sexp, args: []const Sexp) Error!TypeId {
        const obj = callee[1];
        const name_node = callee[2];
        const method = self.text(name_node);
        const pos = srcPos(name_node, firstSrcPos(obj));

        if (obj == .src) {
            if (self.lookupQuiet(self.text(obj))) |id| {
                const sym = self.ctx.symbols.items[id];
                switch (sym.kind) {
                    .module => {
                        try self.ctx.recordName(obj, id);
                        return self.crossModuleCall(id, method, pos, args);
                    },
                    .nominal_type, .generic_type => {
                        try self.ctx.recordName(obj, id);
                        return self.associatedCall(id, method, pos, args);
                    },
                    else => {},
                }
            }
        }

        const obj_ty = try self.synthOperand(obj);
        if (self.isPoison(obj_ty)) {
            try self.synthArgs(args);
            return obj_ty;
        }

        if (std.mem.eql(u8, method, "upgrade")) {
            switch (self.ctx.types.get(types.unwrapBorrows(self.ctx, obj_ty))) {
                .weak => |inner| {
                    if (args.len != 0) {
                        try self.err(pos, "weak `upgrade` takes no arguments; got {d}", .{args.len});
                        try self.synthArgs(args);
                    }
                    const result = try self.ctx.intern(.{ .optional = try self.ctx.intern(.{ .shared = inner }) });
                    try self.noteCallee(.{ .params = try self.ctx.dupeIds(&.{obj_ty}), .returns = result, .is_sub = false });
                    return result;
                },
                .shared => if (!types.hasMethodNamed(self.ctx, obj_ty, method)) {
                    try self.err(pos, "`upgrade` is only available on weak handles (`~T`); receiver here is a shared handle (`*T`). Use `~rc` to obtain a weak reference, then `.upgrade()` on the weak.", .{});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                },
                else => {},
            }
        }

        const peeled = types.unwrapReadAccess(self.ctx, obj_ty);
        switch (self.ctx.types.get(peeled)) {
            .optional => {
                try self.err(pos, "cannot call `{s}` on optional `{s}`; unwrap it first with `if x as v` or `x ?? default`", .{ method, try self.tyName(peeled) });
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

        const resolved = (try types.lookupMethod(self.ctx, obj_ty, method)) orelse {
            // A data field holding a closure handle is called like one.
            if (try types.lookupDataField(self.ctx, obj_ty, method)) |f| {
                if (ownedClosureArgs(self.ctx, f.ty) != null) {
                    try self.noteCalleeType(f.ty);
                    return self.callValue(.{ .list = callee }, f.ty, args, method);
                }
            }
            if (types.nominalSymOfReceiver(self.ctx, peeled)) |owner| {
                const sym = self.ctx.symbols.items[owner];
                try self.err(pos, "no method `{s}` on type `{s}`", .{ method, sym.name });
                if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
            } else {
                try self.err(pos, "type `{s}` has no method `{s}`", .{ try self.tyName(obj_ty), method });
            }
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        const owner = self.ctx.symbols.items[resolved.nominal_sym];
        try self.noteCallee(resolved.fn_ty);

        if (resolved.nominal_sym == self.ctx.cell_sym_id) {
            if (std.mem.eql(u8, method, "set") and !self.isAddressableCell(obj, obj_ty)) {
                try self.err(pos, "`Cell.set` requires an addressable Cell receiver: a local Cell binding or a shared Cell handle (`*Cell(T)`). Cell parameters, borrows, and temporaries cannot be mutated.", .{});
                try self.synthArgs(args);
                return self.t().void_id;
            }
            if (std.mem.eql(u8, method, "get")) {
                if (cellElementType(self.ctx, obj_ty)) |elem| {
                    if (types.typeHasDropGlue(self.ctx, elem)) {
                        try self.err(pos, "`Cell.get` returns `T` by value but `T = {s}` has drop glue; a copy would alias the cell's owned value. Use `cell.replace(<new)` to swap-and-yield the old value.", .{try self.tyName(elem)});
                        try self.synthArgs(args);
                        return self.t().invalid_id;
                    }
                }
            }
        }
        if (resolved.nominal_sym == self.ctx.vec_sym_id and (std.mem.eql(u8, method, "get") or std.mem.eql(u8, method, "pop"))) {
            if (resolved.fn_ty.returns != self.t().invalid_id) {
                const elem = self.ctx.types.get(resolved.fn_ty.returns).optional;
                if (types.typeHasDropGlue(self.ctx, elem)) {
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
        try self.checkArgs(args, rest, self.methodParamNames(resolved.field, true), method, pos);
        return resolved.fn_ty.returns;
    }

    fn methodParamNames(self: *Checker, f: Field, skip_self: bool) ?[]const []const u8 {
        _ = self;
        const names = f.param_names orelse return null;
        if (skip_self and names.len > 0) return names[1..];
        return names;
    }

    /// `Type.method(args)` or `Type.variant(payload)`.
    fn associatedCall(self: *Checker, sym_id: SymbolId, name: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
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
                if (sym.kind == .generic_type) {
                    try self.err(pos, "associated function `{s}.{s}` of a generic type needs its type arguments, which cannot be written here yet", .{ sym.name, name });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.noteCallee(fty.function);
                try self.checkArgs(args, fty.function, self.methodParamNames(m, false), name, pos);
                return fty.function.returns;
            }
            if (m.is_variant and sym.kind == .nominal_type) {
                const payload = m.payload orelse &.{};
                if (payload.len == 0) {
                    try self.err(pos, "variant `{s}.{s}` takes no payload", .{ sym.name, name });
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.checkFieldArgs(args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .pos = pos, .kind = .variant });
                return self.ctx.intern(.{ .nominal = sym_id });
            }
            break;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ name, sym.name });
        if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
        try self.synthArgs(args);
        return self.t().invalid_id;
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
                const local = try types.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
                const fty = self.ctx.types.get(local);
                if (fty != .function) {
                    try self.err(pos, "`{s}` cannot be called", .{qualified});
                    try self.synthArgs(args);
                    return self.t().invalid_id;
                }
                try self.noteCallee(fty.function);
                try self.checkArgs(args, fty.function, found.sym.param_names, qualified, pos);
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

    fn importedMethodCall(self: *Checker, obj: Sexp, obj_ty: TypeId, in: types.ImportedNominal, method: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
        const foreign = self.ctx.foreign_semas.get(in.module_id) orelse {
            try self.synthArgs(args);
            return self.t().invalid_id;
        };
        const sym = foreign.symbols.items[in.sym_id];
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_method or f.is_drop_method or !std.mem.eql(u8, f.name, method)) continue;
            const local = try types.importType(self.ctx, foreign, f.ty, in.module_id);
            const fty = self.ctx.types.get(local).function;
            try self.noteCalleeType(local);
            if (f.receiver == .none) {
                try self.err(pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{ method, sym.name, method });
                try self.synthArgs(args);
                return fty.returns;
            }
            try self.checkReceiverMode(obj, f.receiver, classifyImportedReceiver(self.ctx, obj_ty), method, pos);
            const rest: FunctionType = .{ .params = fty.params[1..], .returns = fty.returns, .is_sub = fty.is_sub, .pre_mask = fty.pre_mask >> 1 };
            try self.checkArgs(args, rest, null, method, pos);
            return fty.returns;
        }
        try self.err(pos, "no method `{s}` on type `{s}`", .{ method, sym.name });
        try self.synthArgs(args);
        return self.t().invalid_id;
    }

    /// `Cell.set` mutates through a pointer, so the receiver must be a
    /// local Cell (emitted as `var`) or a `*Cell(T)` handle.
    fn isAddressableCell(self: *Checker, recv: Sexp, recv_ty: TypeId) bool {
        const ty = self.ctx.types.get(recv_ty);
        if (ty == .shared) return true;
        if (ty == .borrow_read or ty == .borrow_write) return false;
        if (recv != .src) return false;
        const id = self.ctx.symbolOf(recv) orelse return false;
        return self.ctx.symbols.items[id].kind == .local;
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
                    .lvalue_bare => try self.err(pos, "method `{s}` requires a write-borrowed receiver; use `(!receiver).{s}(...)`", .{ method, method }),
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
        // A fallible call where its value is expected: effects reports
        // the missing `!` / `catch`.
        const at = self.ctx.types.get(actual);
        if (at == .fallible and compatible(self.ctx, at.fallible, expected)) return;
        try self.err(firstSrcPos(e), "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(actual) });
    }

    /// Forms whose type comes from context. Returns true if handled.
    fn checkContextual(self: *Checker, e: Sexp, expected: TypeId) Error!bool {
        const target = self.liftTarget(expected);
        switch (e) {
            .src => {
                const s = self.text(e);
                if (types.isIntLiteralText(s) and types.isInteger(self.ctx, target)) {
                    try self.checkLiteralFits(e, target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .list => {},
            else => return false,
        }
        const items = e.list;
        const head = headOf(e) orelse return false;
        switch (head) {
            .@"null" => {
                if (self.ctx.types.get(target) == .optional or self.ctx.types.get(expected) == .optional) {
                    try self.ctx.recordType(e, if (self.ctx.types.get(expected) == .optional) expected else target);
                } else {
                    try self.err(firstSrcPos(e), "`none` needs an optional type; `{s}` is not optional (write `{s}?`)", .{ try self.tyName(expected), try self.tyName(expected) });
                }
                return true;
            },
            .@"neg" => {
                if (items.len >= 2 and items[1] == .src and types.isIntLiteralText(self.text(items[1])) and types.isInteger(self.ctx, target)) {
                    try self.checkLiteralFits(e, target);
                    try self.ctx.recordType(items[1], target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .@"enum_lit" => {
                if (items.len < 2) return true;
                try self.checkEnumLit(items[1], target);
                try self.ctx.recordType(e, target);
                return true;
            },
            .@"call" => {
                if (items.len >= 2 and isHead(items[1], .@"enum_lit")) {
                    try self.checkPayloadVariant(items, target);
                    try self.ctx.recordType(items[1], target);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                if (items.len >= 2 and items[1] == .src) {
                    const tt = self.ctx.types.get(target);
                    if (tt == .parameterized_nominal) {
                        if (self.lookupQuiet(self.text(items[1]))) |id| {
                            if (id == tt.parameterized_nominal.sym) {
                                _ = try self.useName(items[1]);
                                if (id == self.ctx.vec_sym_id) {
                                    try self.checkVecConstruction(items);
                                } else {
                                    const sym = self.ctx.symbols.items[id];
                                    _ = try self.construct(id, items[2..], items[1].src.pos, .{ .params = sym.type_params orelse &.{}, .args = tt.parameterized_nominal.args }, null);
                                }
                                try self.ctx.recordType(e, target);
                                return true;
                            }
                        }
                    }
                }
                if (items.len >= 2 and isHead(items[1], .@"builtin")) return false;
                return false;
            },
            .@"builtin" => {
                _ = try self.synthBuiltin(e, target);
                return true;
            },
            .@"share" => {
                if (items.len < 2) return false;
                if (try self.ownedClosureConstruction(items[1])) |ty| {
                    try self.ctx.recordType(e, ty);
                    if (!compatible(self.ctx, ty, expected)) {
                        try self.err(firstSrcPos(e), "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(ty) });
                    }
                    return true;
                }
                const tt = self.ctx.types.get(target);
                if (tt == .shared) {
                    try self.checkExpr(items[1], tt.shared);
                    try self.ctx.recordType(e, target);
                    return true;
                }
                return false;
            },
            .@"array" => return self.checkArray(e, target),
            .@"if" => {
                _ = try self.checkIfValue(e, expected, .value);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"ternary" => {
                _ = try self.synthTernary(items, expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"match" => {
                _ = try self.checkMatch(e, .value, expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"block" => {
                _ = try self.synthBlock(e, expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"raw_block" => {
                if (items.len >= 2) try self.checkExpr(items[1], expected);
                try self.ctx.recordType(e, expected);
                return true;
            },
            .@"??" => {
                const ty = try self.synthCoalesce(items, null);
                try self.ctx.recordType(e, ty);
                if (!compatible(self.ctx, ty, expected)) {
                    try self.err(firstSrcPos(e), "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(expected), try self.tyName(ty) });
                } else try self.recordAdapted(e, ty, expected);
                return true;
            },
            else => return false,
        }
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
        if (types.isNumeric(self.ctx, target)) try self.ctx.recordType(e, target);
    }

    /// An integer literal (or `-literal`) must fit the integer type it
    /// becomes.
    fn checkLiteralFits(self: *Checker, e: Sexp, target: TypeId) Error!void {
        const tt = self.ctx.types.get(target);
        if (tt != .int) return;
        var negative = false;
        var lit = e;
        if (isHead(e, .@"neg") and e.list.len >= 2) {
            negative = true;
            lit = e.list[1];
        }
        const s = self.text(lit);
        if (!types.isIntLiteralText(s)) return;
        const mag = std.fmt.parseInt(u64, s, 0) catch {
            try self.err(firstSrcPos(e), "integer literal `{s}` is too large", .{s});
            return;
        };
        const bits: u8 = if (tt.int.bits == 0) 32 else tt.int.bits;
        const sign = if (negative) "-" else "";
        const tname = try self.tyName(target);
        if (tt.int.signed) {
            const max: u64 = (@as(u64, 1) << @intCast(bits - 1)) - 1;
            const ok = if (negative) mag <= max + 1 else mag <= max;
            if (!ok) try self.err(firstSrcPos(e), "integer literal `{s}{s}` does not fit in `{s}` (-{d}..{d})", .{ sign, s, tname, max + 1, max });
        } else {
            const max: u64 = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
            const ok = if (negative) mag == 0 else mag <= max;
            if (!ok) try self.err(firstSrcPos(e), "integer literal `{s}{s}` does not fit in `{s}` (0..{d})", .{ sign, s, tname, max });
        }
    }

    fn checkEnumLit(self: *Checker, name_node: Sexp, expected: TypeId) Error!void {
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        if (self.isPoison(expected)) return;
        if (try types.lookupVariant(self.ctx, expected, name)) |v| {
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
        const name = self.text(name_node);
        if ((try types.lookupVariant(self.ctx, scrutinee, name)) == null) {
            try self.reportMissingVariant(scrutinee, name, srcPos(name_node, 0));
        }
    }

    /// `.variant(payload...)` against an expected enum.
    fn checkPayloadVariant(self: *Checker, items: []const Sexp, expected: TypeId) Error!void {
        const name_node = items[1].list[1];
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        const args = items[2..];
        const resolved = (try types.lookupVariant(self.ctx, expected, name)) orelse {
            try self.reportMissingVariant(expected, name, pos);
            try self.synthArgs(args);
            return;
        };
        const owner = self.ctx.symbols.items[resolved.nominal_sym].name;
        if (resolved.payload.len == 0) {
            if (args.len > 0) try self.err(pos, "variant `{s}` of enum `{s}` takes no payload", .{ name, owner });
            try self.synthArgs(args);
            return;
        }
        try self.checkFieldArgs(args, resolved.payload, .{ .owner = name, .decl_pos = resolved.field.decl_pos, .pos = pos, .kind = .variant });
    }

    /// `Vec()` / `Vec(capacity: n)`.
    fn checkVecConstruction(self: *Checker, items: []const Sexp) Error!void {
        var seen: ?u32 = null;
        for (items[2..]) |a| {
            if (!isHead(a, .@"kwarg")) {
                try self.err(firstSrcPos(a), "`Vec` constructor takes no positional arguments; use `Vec()` (empty) or `Vec(capacity: N)`", .{});
                _ = try self.synthExpr(a);
                continue;
            }
            const name = self.text(a.list[1]);
            const pos = srcPos(a.list[1], 0);
            if (!std.mem.eql(u8, name, "capacity")) {
                try self.err(pos, "`Vec` constructor accepts only `capacity` as a kwarg; got `{s}`", .{name});
                _ = try self.synthExpr(a.list[2]);
                continue;
            }
            if (seen) |first| {
                try self.err(pos, "duplicate `capacity` kwarg in `Vec` constructor", .{});
                try self.note(first, "first `capacity` here", .{});
            }
            seen = pos;
            try self.checkExpr(a.list[2], self.t().int_id);
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

    const builtin_casts = [_][]const u8{ "bitCast", "intCast", "floatCast", "truncate", "intFromFloat", "floatFromInt", "enumFromInt" };

    fn synthBuiltin(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
        const items = node.list;
        if (items.len < 2) return self.t().invalid_id;
        const name = self.text(items[1]);
        const pos = srcPos(items[1], firstSrcPos(node));
        const args = items[2..];
        const ty: TypeId = blk: {
            if (std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf")) {
                if (try self.builtinTypeArg(name, args, pos)) break :blk self.t().int_literal_id;
                break :blk self.t().invalid_id;
            }
            if (std.mem.eql(u8, name, "typeName")) {
                if (try self.builtinTypeArg(name, args, pos)) break :blk self.t().string_id;
                break :blk self.t().invalid_id;
            }
            for (builtin_casts) |c| {
                if (!std.mem.eql(u8, name, c)) continue;
                if (args.len != 1) {
                    try self.err(pos, "`@{s}` takes one argument", .{name});
                    try self.synthArgs(args);
                    break :blk self.t().invalid_id;
                }
                _ = try self.synthExpr(args[0]);
                const target = expected orelse {
                    try self.err(pos, "`@{s}` needs a known result type; bind it to an annotated name (`y: T = @{s}(x)`)", .{ name, name });
                    break :blk self.t().invalid_id;
                };
                break :blk target;
            }
            if (std.mem.eql(u8, name, "TypeOf")) {
                try self.err(pos, "`@TypeOf` is only allowed as the argument of `@sizeOf`, `@alignOf`, or `@typeName`", .{});
                try self.synthArgs(args);
                break :blk self.t().invalid_id;
            }
            try self.err(pos, "builtin `@{s}` is not supported", .{name});
            try self.synthArgs(args);
            break :blk self.t().invalid_id;
        };
        if (expected) |e| {
            if (!self.isPoison(ty) and !compatible(self.ctx, ty, e)) {
                try self.err(firstSrcPos(node), "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(e), try self.tyName(ty) });
            }
            try self.ctx.recordType(node, if (ty == self.t().int_literal_id) self.liftTarget(e) else ty);
        } else {
            try self.ctx.recordType(node, self.canonical(ty));
        }
        return ty;
    }

    /// `@sizeOf(T)` / `@sizeOf(@TypeOf(x))`.
    fn builtinTypeArg(self: *Checker, name: []const u8, args: []const Sexp, pos: u32) Error!bool {
        if (args.len != 1) {
            try self.err(pos, "`@{s}` takes one type argument", .{name});
            return false;
        }
        const a = args[0];
        if (isHead(a, .@"builtin") and a.list.len >= 3 and std.mem.eql(u8, self.text(a.list[1]), "TypeOf")) {
            _ = try self.synthExpr(a.list[2]);
            return true;
        }
        var r = self.resolver();
        const ty = try r.resolveType(a);
        return !self.isPoison(ty);
    }

    // =========================================================================
    // Lambdas and owned closures
    // =========================================================================

    fn synthLambda(self: *Checker, node: Sexp) Error!TypeId {
        return self.checkLambda(node, null);
    }

    /// A lambda literal. Its type is a function type over its declared
    /// parameters, returning the type of its body's last expression.
    /// `expected_params`, from `*Closure1(T)` / `*Closure2(A, B)`, must
    /// match the declared parameter types.
    fn checkLambda(self: *Checker, node: Sexp, expected_params: ?[]const TypeId) Error!TypeId {
        const items = node.list;
        if (items.len < 5) return self.t().invalid_id;
        const outer = self.scope;
        const prev = self.enter(node);
        const prev_ret = self.fn_return;
        const prev_sub = self.is_sub;
        defer {
            self.scope = prev;
            self.fn_return = prev_ret;
            self.is_sub = prev_sub;
        }

        if (self.ctx.bodyRoot(outer)) |root| {
            if (self.ctx.scopes.items[root].kind == .lambda) {
                for (types.captureList(items[1])) |cap| {
                    const n = types.captureNameNode(cap) orelse continue;
                    try self.err(srcPos(n, 0), "nested closure capture of `{s}` is not supported; lift the capture to the outer scope", .{self.text(n)});
                }
            }
        }
        for (types.captureList(items[1])) |cap| try self.checkCapture(cap, outer);

        var params: std.ArrayListUnmanaged(TypeId) = .empty;
        defer params.deinit(self.ctx.allocator);
        if (items[2] == .list) {
            var r = self.resolver();
            for (items[2].list, 0..) |p, i| {
                const pty = try r.resolveParamType(p);
                try params.append(self.ctx.allocator, pty);
                const pn = types.paramNameNode(p) orelse continue;
                if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
                if (expected_params) |ep| {
                    if (i < ep.len and !self.isPoison(pty) and pty != ep[i]) {
                        try self.err(types.paramPos(p, firstSrcPos(p)), "closure parameter `{s}` is declared `{s}`, but the closure type passes `{s}`", .{ self.text(pn), try self.tyName(pty), try self.tyName(ep[i]) });
                    }
                }
            }
        }

        self.fn_return = self.t().unknown_id;
        self.is_sub = false;
        const body = items[4];
        var ret = self.t().void_id;
        if (isHead(body, .@"block")) {
            const bprev = self.enter(body);
            defer self.scope = bprev;
            const stmts = body.list[1..];
            if (stmts.len > 0) {
                for (stmts[0 .. stmts.len - 1]) |s| try self.checkStmt(s);
                const last = stmts[stmts.len - 1];
                ret = if (isStatementForm(last)) blk: {
                    try self.checkStmt(last);
                    break :blk self.t().void_id;
                } else try self.synthExpr(last);
            }
        } else ret = try self.synthExpr(body);
        ret = self.canonical(ret);
        if (ret == self.t().noreturn_id) ret = self.t().void_id;

        const pos = firstSrcPos(node);
        if (pos != 0 and !self.isPoison(ret)) try self.ctx.lambda_return_types.put(self.ctx.allocator, pos, ret);
        return self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(params.items), .returns = ret, .is_sub = ret == self.t().void_id } });
    }

    /// Validate one capture against the outer binding and give the
    /// capture symbol its type.
    fn checkCapture(self: *Checker, cap: Sexp, outer: ScopeId) Error!void {
        const mode = types.captureModeOf(cap) orelse return;
        const name_node = types.captureNameNode(cap) orelse return;
        const name = self.text(name_node);
        const pos = srcPos(name_node, 0);
        const cap_sym = self.ctx.symbolOf(name_node) orelse return;

        const outer_id = self.ctx.lookup(outer, name) orelse {
            try self.err(pos, "captured name `{s}` is not in scope", .{name});
            self.ctx.symbols.items[cap_sym].ty = self.t().invalid_id;
            return;
        };
        const outer_ty = self.ctx.symbols.items[outer_id].ty;
        const oty = self.ctx.types.get(outer_ty);
        const bound: TypeId = switch (mode) {
            .cap_copy => switch (oty) {
                .shared => blk: {
                    try self.err(pos, "bare capture `|{s}|` of shared handle `*T` would hide a refcount bump; use `|+{s}|` to clone, `|<{s}|` to move, or `|~{s}|` to capture a weak ref", .{ name, name, name, name });
                    break :blk self.t().invalid_id;
                },
                .weak => blk: {
                    try self.err(pos, "bare capture `|{s}|` of weak handle `~T` would hide a refcount bump; use `|+{s}|` to clone or `|<{s}|` to move", .{ name, name, name });
                    break :blk self.t().invalid_id;
                },
                else => if (types.isCopyPrimitive(self.ctx, outer_ty) or self.isPoison(outer_ty)) outer_ty else blk: {
                    try self.err(pos, "bare capture `|{s}|` requires a Copy type; got `{s}`; use `|+{s}|` to clone or `|<{s}|` to move", .{ name, try self.tyName(outer_ty), name, name });
                    break :blk self.t().invalid_id;
                },
            },
            .cap_clone => switch (oty) {
                .shared, .weak => outer_ty,
                else => if (types.isCopyPrimitive(self.ctx, outer_ty) or self.isPoison(outer_ty)) outer_ty else blk: {
                    try self.err(pos, "clone-capture `|+{s}|` requires a shared `*T`, weak `~T`, or Copy type; got `{s}`", .{ name, try self.tyName(outer_ty) });
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
        try self.ctx.recordType(name_node, bound);
    }

    /// `*Closure(|...| body)`, `*Closure1(T)(|...| (a: T) body)`,
    /// `*Closure2(A, B)(...)`: the owned-closure constructions. `inner`
    /// is the operand of `*`. Returns null for any other shape.
    fn ownedClosureConstruction(self: *Checker, inner: Sexp) Error!?TypeId {
        if (!isHead(inner, .@"call") or inner.list.len < 2) return null;
        const items = inner.list;
        const callee = items[1];
        var sym: SymbolId = types.symbol_invalid;
        var type_args: []const Sexp = &.{};
        var name_node: Sexp = callee;
        if (callee == .src) {
            const id = self.lookupQuiet(self.text(callee)) orelse return null;
            if (id != self.ctx.closure_sym_id) return null;
            sym = id;
        } else if (isHead(callee, .@"call") and callee.list.len >= 2 and callee.list[1] == .src) {
            const id = self.lookupQuiet(self.text(callee.list[1])) orelse return null;
            if (id != self.ctx.closure1_sym_id and id != self.ctx.closure2_sym_id) return null;
            sym = id;
            type_args = callee.list[2..];
            name_node = callee.list[1];
        } else return null;
        try self.ctx.recordName(name_node, sym);

        const cname = self.ctx.symbols.items[sym].name;
        const pos = srcPos(name_node, 0);
        const arity: usize = if (sym == self.ctx.closure_sym_id) 0 else if (sym == self.ctx.closure1_sym_id) 1 else 2;
        if (type_args.len != arity) {
            try self.err(pos, "`{s}` requires {d} type argument(s); got {d}", .{ cname, arity, type_args.len });
        }
        const args = try self.ctx.arena.allocator().alloc(TypeId, type_args.len);
        var r = self.resolver();
        for (type_args, 0..) |ta, i| {
            args[i] = try r.resolveType(ta);
            if (!self.isPoison(args[i]) and !types.isCopyPrimitive(self.ctx, args[i])) {
                try self.err(firstSrcPos(ta), "`{s}` argument types must be Copy (Int, Float, Bool, String, or a sized number); got `{s}`", .{ cname, try self.tyName(args[i]) });
            }
        }

        const call_args = items[2..];
        if (call_args.len != 1) {
            if (call_args.len == 0) {
                try self.err(pos, "owned closure `*{s}(...)` requires a lambda argument; write `*{s}(...)(|...| body)`", .{ cname, cname });
            } else {
                try self.err(pos, "owned closure `*{s}(...)` takes exactly one lambda argument; got {d}", .{ cname, call_args.len });
                try self.synthArgs(call_args);
            }
        } else if (!isHead(call_args[0], .@"lambda")) {
            try self.err(firstSrcPos(call_args[0]), "owned closure `*{s}(...)` argument must be a lambda `|...| body`", .{cname});
            _ = try self.synthExpr(call_args[0]);
        } else {
            const lambda = call_args[0];
            const params = lambda.list[2];
            const nparams: usize = if (params == .list) params.list.len else 0;
            if (nparams != arity) {
                try self.err(firstSrcPos(lambda), "`{s}` closure body needs {d} param(s); got {d}", .{ cname, arity, nparams });
            }
            const lty = try self.checkLambda(lambda, args);
            try self.ctx.recordType(lambda, lty);
        }

        const closure = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym, .args = args } });
        const ty = try self.ctx.intern(.{ .shared = closure });
        try self.ctx.recordType(inner, closure);
        return ty;
    }

    fn isOwnedClosureHandle(self: *Checker, ty: TypeId) bool {
        return ownedClosureArgs(self.ctx, ty) != null;
    }
};

// =============================================================================
// Compatibility and classification
// =============================================================================

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
        .fallible => |inner| return compatible(ctx, actual, inner),
        .borrow_read => |inner| if (a == .borrow_write) return a.borrow_write == inner,
        else => {},
    }
    return switch (a) {
        .int_literal => e == .int or e == .float,
        .float_literal => e == .float,
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
    return switch (ctx.types.get(ty_id)) {
        .nominal, .parameterized_nominal => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
        .borrow_read => |i| if (matches(ctx, i, nominal_sym)) .read_borrow else .other,
        .borrow_write => |i| if (matches(ctx, i, nominal_sym)) .write_borrow else .other,
        .shared => |i| if (matches(ctx, i, nominal_sym)) .shared else .other,
        else => .other,
    };
}

fn classifyImportedReceiver(ctx: *const SemContext, ty_id: TypeId) ReceiverTypeKind {
    return switch (ctx.types.get(ty_id)) {
        .imported_nominal => .owned_nominal,
        .borrow_read => .read_borrow,
        .borrow_write => .write_borrow,
        .shared => .shared,
        else => .other,
    };
}

pub const ReceiverShape = enum { read_explicit, write_explicit, move_explicit, rvalue, lvalue_bare };

/// How the receiver expression is written. Only heads that certainly
/// produce a fresh value count as rvalues; everything else is a place.
fn classifyReceiverShape(recv: Sexp) ReceiverShape {
    const h = headOf(recv) orelse return .lvalue_bare;
    return switch (h) {
        .@"read" => .read_explicit,
        .@"write" => .write_explicit,
        .@"move" => .move_explicit,
        .@"call", .@"builtin", .@"record", .@"anon_init", .@"array", .@"clone", .@"share", .@"weak", .@"if", .@"match", .@"ternary", .@"catch", .@"try", .@"try_block", .@"propagate" => .rvalue,
        else => .lvalue_bare,
    };
}

/// The element type of a Cell receiver (`Cell(T)`, `?Cell(T)`, `*Cell(T)`, ...).
fn cellElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(types.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.cell_sym_id or pn.args.len != 1) return null;
    return pn.args[0];
}

/// Argument types of an owned closure handle `*Closure()`,
/// `*Closure1(T)`, `*Closure2(A, B)` (possibly borrowed).
fn ownedClosureArgs(ctx: *const SemContext, ty: TypeId) ?[]const TypeId {
    const inner = switch (ctx.types.get(types.unwrapBorrows(ctx, ty))) {
        .shared => |i| i,
        else => return null,
    };
    const pn = switch (ctx.types.get(inner)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym == ctx.closure_sym_id or pn.sym == ctx.closure1_sym_id or pn.sym == ctx.closure2_sym_id) return pn.args;
    return null;
}

/// An enum all of whose variants are bare (no payloads): comparable with `==`.
fn isPlainEnum(ctx: *const SemContext, sym_id: SymbolId) bool {
    const fields = ctx.symbols.items[sym_id].fields orelse return false;
    var any = false;
    for (fields) |f| {
        if (!f.is_variant) continue;
        any = true;
        if (f.payload != null and f.payload.?.len > 0) return false;
    }
    return any;
}

fn isFreshResourceAlloc(sexp: Sexp) bool {
    return isHead(sexp, .@"share") and sexp.list.len >= 2 and isHead(sexp.list[1], .@"call");
}

/// Forms whose type comes from the other operand: `.variant`, `none`.
fn isContextual(e: Sexp) bool {
    return isHead(e, .@"enum_lit") or isHead(e, .@"null");
}

fn isStatementForm(e: Sexp) bool {
    const h = headOf(e) orelse return false;
    return switch (h) {
        .@"set", .@"while", .@"for", .@"drop", .@"defer", .@"errdefer", .@"return", .@"break", .@"continue" => true,
        else => false,
    };
}

fn isLiteralText(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '"' or s[0] == '\'') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return true;
    return types.isIntLiteralText(s) or types.isFloatLiteralText(s);
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
                try ctx.err(entry.value_ptr.*, "`{s}` cannot use `{s} = {s}`: the generic body applies `{s}` to `{s}`, which `{s}` does not support", .{
                    try types.formatType(ctx, entry.key_ptr.*), pname, try types.formatType(ctx, arg), req.op, pname, try types.formatType(ctx, arg),
                });
                try ctx.note(req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() });
                break;
            }
        }
    }
}

fn satisfies(ctx: *const SemContext, ty: TypeId, req: Requirement) bool {
    return switch (req) {
        .numeric, .ordered => types.isNumeric(ctx, ty),
        .integer => types.isInteger(ctx, ty),
        .equatable => switch (ctx.types.get(ty)) {
            .int, .float, .bool => true,
            .nominal => |s| isPlainEnum(ctx, s),
            else => false,
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { ctx: SemContext, p: parser.Parser, ir: Sexp } {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const ir = try p.parseProgram();
    const ctx = try types.check(allocator, source, ir);
    return .{ .ctx = ctx, .p = p, .ir = ir };
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
