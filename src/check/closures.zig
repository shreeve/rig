//! Typecheck's closures: their types, captures, and returns.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const FunctionType = sema.FunctionType;
const Error = std.mem.Allocator.Error;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CallCheck = @import("calls.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// A closure literal passed where callable view `target` (a
/// `?fun(...)`) is expected: only as a call's argument, and only to a
/// call whose result cannot hold it, since it lives for the call.
pub fn viewedLambda(self: *Checker, e: Sexp, target: TypeId) Error!TypeId {
    const fn_ty = sema.callableFnTy(self.ctx, target).?;
    if (tc.sameNode(e, self.expect.callable_kept)) {
        try self.errAt(e, "this call's result may hold the closure passed to it, and a closure literal lives only for the call; bind the closure (`f = |...| ...`) and pass it as `?f`", .{});
    } else if (!tc.sameNode(e, self.expect.viewed_callable)) {
        try self.errAt(e, "a closure literal is passed as `{s}` only as a call's argument; bind the closure (`f = |...| ...`) and pass it as `?f`", .{try self.tyName(target)});
    }
    const ty = try checkLambda(self, e, fn_ty);
    try self.ctx.recordView(e, sema.viewAs(self.ctx, fn_ty, .read, target).?);
    return ty;
}

/// `*|...| body`: an owned closure; `expected` is the function type
/// its context gives it (`*fun(Int) -> Int` gives `fun(Int) -> Int`).
pub fn ownedClosure(self: *Checker, lambda: Sexp, expected: ?TypeId) Error!TypeId {
    const lty = try checkLambda(self, lambda, expected);
    try self.ctx.recordType(lambda, lty);
    // No owned closure holds a task (Core §4): its type does not show
    // its captures, so a task in one would leave `task.isolate`, or
    // hide in an API object, where no rule waits for it.
    for (sema.captureList(ir.Lambda.captures(lambda))) |cap| {
        const name_node = sema.captureNameNode(cap) orelse continue;
        const id = self.ctx.symbolOf(name_node) orelse continue;
        const cty = self.ctx.symbols.items[id].ty;
        if (self.isPoison(cty)) continue;
        if (!try StdFormCheck.hidesNoTask(self, name_node, cty, .captured, "")) return self.t().invalid_id;
    }
    return self.ctx.intern(.{ .shared = lty });
}

/// The function type of owned closure type `ty` (`fun(Int) -> Int` for
/// `*fun(Int) -> Int`, possibly as a view).
pub fn ownedClosureType(self: *Checker, ty: TypeId) ?TypeId {
    if (sema.ownedClosureFn(self.ctx, ty) == null) return null;
    return self.ctx.types.get(sema.unwrapViews(self.ctx, ty)).shared;
}

/// A closure literal. Its type is a function type over its
/// parameters. With an `expected` function type from context, bare
/// parameters take its parameter types and the body is checked
/// against its return type; without one, every parameter must be
/// annotated and the return type is that of the body's last
/// expression.
pub fn checkLambda(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
    return checkLambdaGiven(self, node, expected, &.{}, false);
}

/// `checkLambda`, where without an `expected` type the parameters
/// may take types from `given` (`type_invalid` for none), and the
/// result can fail when `fails`.
pub fn checkLambdaGiven(self: *Checker, node: Sexp, expected: ?TypeId, given_params: []const TypeId, fails: bool) Error!TypeId {
    const captures = sema.captureList(ir.Lambda.captures(node));
    const outer = self.scope;
    const prev = self.enter(node);
    const saved = self.body;
    defer {
        self.scope = prev;
        self.body = saved;
    }

    for (captures) |cap| try checkCapture(self, cap, outer);

    const want: ?FunctionType = if (expected) |e| self.ctx.types.get(e).function else null;
    // A closure that declares fewer parameters than the type it is
    // checked against is the closure with `_` for each trailing
    // parameter it leaves out (docs/internals/INTERNALS.md, "Closures with
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
        try self.errAt(node, "this closure takes {d} parameter{s}, but its type `{s}` passes {d}; a closure may take fewer, never more", .{ param_nodes.len, tc.plural(param_nodes.len), try self.tyName(expected.?), w.params.len });
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
            // A parameter's type is checked as a written one is,
            // though the closure's type gave it; `_` binds nothing
            // to write through.
            if (sema.writesView(self.ctx, g) and !std.mem.eql(u8, name, "_")) {
                const viewed = sema.viewWritten(self.ctx, g);
                if (viewed == self.t().string_view_id) {
                    try self.errAt(pn, "closure parameter `{s}` is a `{s}`, from the closure's type `{s}`; " ++ sema.write_text_view, .{ name, try self.tyName(g), try self.tyName(expected orelse g) });
                } else {
                    const shown = try self.tyName(viewed);
                    try self.errAt(pn, "closure parameter `{s}` is a `{s}`, from the closure's type `{s}`; " ++ sema.write_read_view, .{ name, try self.tyName(g), try self.tyName(expected orelse g), shown, shown });
                }
                pty = self.t().invalid_id;
            }
        } else if (want == null and !self.expect.under_poison and !namesOuterLocal(self, outer, name, srcPos(pn, 0))) {
            try self.errAt(pn, "closure parameter `{s}` needs a type: annotate it (`|{s}: Int|`) or write the closure where its type is known (`f: fun(Int) -> Int = |{s}| ...`)", .{ name, name, name });
        }
        try params.append(self.ctx.allocator, pty);
        if (self.ctx.symbolOf(pn)) |pid| (try self.ctx.symbolMut(pid)).ty = pty;
        try self.ctx.recordType(pn, pty);
    }

    if (want) |w| if (sema.returnsNothing(self.ctx, w.returns)) {
        // A closure that returns nothing has no value: its last line
        // is a statement, as a `sub`'s is.
        if (self.ctx.parser) |p| try p.dropTail(node);
    };
    const body = ir.Lambda.body(node);
    if (want) |w| {
        // A closure whose type can fail sends a failure `!`
        // propagates to its caller.
        const can_fail = self.ctx.types.get(w.returns) == .fallible;
        try self.checkBody(body, .{ .ret = w.returns, .is_sub = w.is_sub, .fail_to = if (can_fail) .caller else .closure, .in_closure = true });
        return expected.?;
    }

    var sites: std.ArrayList(Checker.ReturnSite) = .empty;
    defer sites.deinit(self.ctx.allocator);
    self.body = .{ .ret = self.t().unknown_id, .is_sub = false, .fail_to = if (fails) .caller else .closure, .returns = &sites, .in_closure = true };
    var ret = self.t().void_id;
    var ends_in_return = false;
    if (body.isKind(.block)) {
        const bprev = self.enter(body);
        defer self.scope = bprev;
        const stmts = ir.Block.stmts(body);
        if (stmts.len > 0) {
            for (stmts[0 .. stmts.len - 1]) |*s| try self.checkRewritten(s, StmtCheck.checkStmt, .{});
            const last = &stmts[stmts.len - 1];
            ends_in_return = last.isKind(.@"return") or last.isKind(.panic);
            // A closure ending in a statement, or an `if` without
            // `else`, returns nothing.
            const no_value = FlowCheck.yieldsNoValue(self, last.*) or tc.ifWithoutValue(last.*);
            // A closure's value is its result: it leaves the body,
            // as `return` takes it.
            ret = if (no_value) blk: {
                try self.checkRewritten(last, StmtCheck.checkStmt, .{});
                break :blk self.t().void_id;
            } else blk: {
                try ViewCheck.recordUse(self, last.*, .take);
                const mark = self.ctx.diagnostics.items.len;
                const ty = try self.checkRewritten(last, Checker.synthTail, .{null});
                if (self.ctx.diagnostics.items.len == mark) try ViewCheck.keptViews(self, last.*, .returned);
                break :blk ty;
            };
        }
    } else {
        try ViewCheck.recordUse(self, body, .take);
        const mark = self.ctx.diagnostics.items.len;
        ret = try self.synthTail(body, null);
        if (self.ctx.diagnostics.items.len == mark) try ViewCheck.keptViews(self, body, .returned);
    }
    ret = ExprCheck.canonical(self, ret);
    if (ret == self.t().noreturn_id) ret = self.t().void_id;
    // A closure whose value is a write view it captured, of a value
    // that copies (`|!n| ... n`), gives that value, as a `-> Int`
    // function gives a `!Int` parameter's: a write view has one
    // holder and never leaves the closure.
    const tail = sema.tailOf(body);
    if (tail == .src and self.ctx.types.get(ret) == .write_view) if (sema.copiedThrough(self.ctx, ret)) |inner| {
        try ViewCheck.readOf(self, tail, ret, .{ .value = inner });
        ret = inner;
    };
    ret = try reconcileReturns(self, sites.items, ret, ends_in_return, body);
    if (fails and !self.isPoison(ret) and self.ctx.types.get(ret) != .fallible) ret = try self.ctx.intern(.{ .fallible = .{ .ok = ret } });

    return self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(params.items), .returns = ret, .is_sub = sema.returnsNothing(self.ctx, ret) } });
}

/// The return type of a closure inferred from its body's value `ret`
/// and its `return`s: a body ending in `return v` returns `v`'s type,
/// and every `return` must agree with the result.
pub fn reconcileReturns(self: *Checker, sites: []const Checker.ReturnSite, body_ret: TypeId, ends_in_return: bool, body: Sexp) Error!TypeId {
    var ret = body_ret;
    if (ret == self.t().void_id) {
        for (sites) |site| if (site.ty) |ty| {
            ret = ExprCheck.canonical(self, ty);
            if (!ends_in_return and !self.isPoison(ret)) {
                try self.errAt(tc.lastStmt(body), "this closure returns `{s}` with `return`, so its body must end with a value or a `return`", .{try self.tyName(ret)});
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
        if (!fails and !tc.compatible(self.ctx, ty, ret)) {
            // A generic call only literals typed would take the type.
            const hint = if (CallCheck.literalResult(self, ir.Return.value(site.node)) != null and sema.isNumeric(self.ctx, ret))
                try self.ctx.arena.allocator().print("; give the closure its type where it goes (`f: fun(...) -> {s} = |...| ...`), and every `return` takes it", .{try self.tyName(ret)})
            else
                "";
            try self.errAt(site.node, "this closure returns `{s}`, but this `return` gives `{s}`{s}", .{ try self.tyName(ret), try self.tyName(ty), hint });
        } else try ViewCheck.recordAdapted(self, ir.Return.value(site.node), ty, ret);
    }
    return ret;
}

/// `name` is a local of the function enclosing a closure. A closure
/// parameter with that name is already reported as a missing sigil.
pub fn namesOuterLocal(self: *Checker, outer: ScopeId, name: []const u8, pos: u32) bool {
    const id = CallCheck.lookupAt(self, outer, name, pos) orelse return false;
    return switch (self.ctx.symbols.items[id].kind) {
        .local, .param, .capture => true,
        else => false,
    };
}

/// When the closure of scope `lambda` captures a field path of `name`
/// (`|?p.a|`) and the body reaches `name` outside it (`p`, `p.b`),
/// reports so, naming the place to capture, and returns true.
pub fn pastPathCapture(self: *Checker, leaf: Sexp, name: []const u8, lambda: ScopeId) Error!bool {
    const captured = for (self.ctx.scopes.items[lambda].symbols.items) |id| {
        const sym = self.ctx.symbols.items[id];
        if (sym.kind == .capture and sema.pathHolds(name, sym.name)) break sym.name;
    } else return false;
    // The place the body names: `name`, the steps after it that it
    // shares with the captured path, and the step where they part.
    const src = self.ctx.source;
    var end: usize = leaf.src.pos + leaf.src.len;
    while (end - leaf.src.pos < captured.len and end < src.len and src[end] == captured[end - leaf.src.pos]) end += 1;
    while (end < src.len and (std.ascii.isAlphanumeric(src[end]) or src[end] == '_')) end += 1;
    const shown = src[leaf.src.pos..end];
    // `@n()`, a method, is called on the root itself.
    const call = end < src.len and src[end] == '(';
    if (std.mem.eql(u8, shown, name) or call) {
        try self.errAt(leaf, "the closure captured `{s}`, not `{s}`: capture `?{s}` instead", .{ captured, name, name });
    } else try self.errAt(leaf, "the closure captured `{s}`, not `{s}`: capture `?{s}` too", .{ captured, shown, shown });
    return true;
}

/// Whether looking `name` up from `scope` leaves a closure body
/// before finding it.
pub fn closureBetween(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) bool {
    var sid: ?ScopeId = scope;
    while (sid) |s| {
        if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
        if (ExprCheck.visibleIn(self, s, name, pos) != null) return false;
        if (self.ctx.scopes.items[s].kind == .lambda) return true;
        sid = self.ctx.scopes.items[s].parent;
    }
    return false;
}

/// `|?x|` / `|!x|`: the type of the view of outer binding `id`
/// the closure holds, as `?x` / `!x` would have it. Poison after a
/// diagnostic.
pub fn captureView(self: *Checker, id: SymbolId, name: []const u8, pos: u32, kind: Checker.ViewKind) Error!TypeId {
    const sym = self.ctx.symbols.items[id];
    const ty = sym.ty;
    if (self.isPoison(ty)) return ty;
    switch (self.ctx.types.get(ty)) {
        .read_view => {
            if (kind == .read) return ty;
            const hint = try PatternCheck.readMatchHint(self, id);
            if (hint.len > 0) {
                try self.err(pos, "cannot make a write view through a read view `{s}`{s}", .{ try self.tyName(ty), hint });
            } else try self.err(pos, "cannot make a write view through a read view `{s}`; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
            return self.t().invalid_id;
        },
        .write_view => |base| return if (kind == .write) ty else self.ctx.intern(.{ .read_view = base }),
        .string_view => {
            if (kind == .read) return ty;
            try self.err(pos, "cannot make a write view of `{s}`: it holds a read view of text, `?String`, which is pointed at other text by assigning to it; to change text in place, hold a `String`", .{name});
            return self.t().invalid_id;
        },
        .slice => if (kind == .write) {
            try self.err(pos, "cannot make a write view of a `{s}`: its elements are read-only; capture it with `|?{s}|`", .{ try self.tyName(ty), name });
            return self.t().invalid_id;
        },
        .function => if (sym.flags.closure) {
            if (kind == .read) return sema.callableOfFn(self.ctx, ty);
            try self.err(pos, "a call never changes what a closure captures, so a closure is passed as a read view; capture it with `|?{s}|`", .{name});
            return self.t().invalid_id;
        },
        else => {},
    }
    const root = StmtCheck.rootOf(self, sym);
    if (kind == .write and !try StmtCheck.requireAccess(self, .{ .pos = pos, .sym = id, .root = root }, .write_viewed, .nil)) return self.t().invalid_id;
    return self.ctx.intern(if (kind == .read) Type{ .read_view = ty } else Type{ .write_view = ty });
}

/// Validate one capture against the outer binding and give the
/// capture symbol its type.
pub fn checkCapture(self: *Checker, cap: Sexp, outer: ScopeId) Error!void {
    const mode = sema.captureModeOf(cap) orelse return;
    const name_node = sema.captureNameNode(cap) orelse return;
    const name = self.text(name_node);
    const pos = srcPos(name_node, 0);
    const cap_sym = self.ctx.symbolOf(name_node) orelse return;

    // A field path is viewed, copied, taken, or held weakly as its
    // sigil does it in an expression, where the closure is made.
    const value = sema.captureValue(cap);
    if (value != .nil) {
        const inner = self.scope;
        self.scope = outer;
        const ty = try PatternCheck.synthExpr(self, value);
        self.scope = inner;
        var root = ir.get(value, .operand);
        while (root.isKind(.member)) root = ir.Member.object(root);
        const root_sym = self.ctx.symbolOf(root);
        const place = if (root_sym) |r| switch (self.ctx.symbols.items[r].kind) {
            .local, .param, .capture => self.ctx.symbols.items[r].scope != sema.module_scope,
            else => false,
        } else true;
        if (!place) {
            try self.err(pos, "a capture names a local or a field of one, and `{s}` is not a local: use `{s}` in the closure directly", .{ self.text(root), name });
            (try self.ctx.symbolMut(cap_sym)).ty = self.t().invalid_id;
            return;
        }
        (try self.ctx.symbolMut(cap_sym)).ty = ty;
        if (root_sym) |r| (try self.ctx.symbolMut(cap_sym)).origin = r;
        try self.ctx.recordType(name_node, ty);
        return;
    }

    const outer_id = CallCheck.lookupAt(self, outer, name, pos) orelse {
        try self.err(pos, "captured name `{s}` is not in scope", .{name});
        (try self.ctx.symbolMut(cap_sym)).ty = self.t().invalid_id;
        return;
    };
    const outer_sym = self.ctx.symbols.items[outer_id];
    // A capture of a group as written uses it whole (`rig.GroupUse`).
    if (outer_sym.flags.group) try self.group_uses.append(self.ctx.allocator, .{ .group = outer_sym.decl_pos, .pos = pos });
    const local = switch (outer_sym.kind) {
        .local, .param, .capture => outer_sym.scope != sema.module_scope,
        else => false,
    };
    if (!local) {
        try self.err(pos, "only a local can be captured; `{s}` is declared at module level, so use it in the closure directly", .{name});
        (try self.ctx.symbolMut(cap_sym)).ty = self.t().invalid_id;
        return;
    }
    // A closure reaches outer locals only through its own captures,
    // so a closure nested in one captures from what that one holds.
    if (closureBetween(self, outer, name, pos)) {
        try self.err(pos, "`{s}` is a local outside the enclosing closure; capture `{s}` in the enclosing closure first", .{ name, name });
        (try self.ctx.symbolMut(cap_sym)).ty = self.t().invalid_id;
        return;
    }
    const outer_ty = self.ctx.symbols.items[outer_id].ty;
    if (mode == .cap_read or mode == .cap_write) {
        const ty = try captureView(self, outer_id, name, pos, if (mode == .cap_read) .read else .write);
        (try self.ctx.symbolMut(cap_sym)).ty = ty;
        (try self.ctx.symbolMut(cap_sym)).origin = outer_id;
        try self.ctx.recordType(name_node, ty);
        return;
    }
    const bound: ?TypeId = switch (mode) {
        .cap_read, .cap_write => unreachable,
        .cap_move => outer_ty,
        .cap_weak => switch (self.ctx.types.get(outer_ty)) {
            .shared => |inner| if (sema.frozenValue(self.ctx, inner) != null) {
                try self.err(pos, "a frozen value has no weak handle: `|+{s}|` shares it", .{name});
                (try self.ctx.symbolMut(cap_sym)).ty = self.t().invalid_id;
                return;
            } else try self.ctx.intern(.{ .weak = inner }),
            else => null,
        },
        .cap_clone => try cloneCapture(self, outer_ty, outer_sym.flags.closure, pos),
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
    (try self.ctx.symbolMut(cap_sym)).ty = bound orelse self.t().invalid_id;
    (try self.ctx.symbolMut(cap_sym)).origin = outer_id;
    try self.ctx.recordType(name_node, bound orelse self.t().invalid_id);
}

/// The type `|+x|` captures for an `x` of type `ty`: what `+x` gives
/// (Core §7). A handle, or one a view reaches, is counted again; a
/// value that copies is copied (`sema.copies`), read through a view
/// (`sema.copiedThrough`); an owner, or one a view reaches, is cloned
/// part by part (`sema.cloneable`). Inside a generic body, copying a
/// `T` requires that each instance copies. Null for a closure, a
/// callable, or a value with no clone.
pub fn cloneCapture(self: *Checker, ty: TypeId, closure: bool, pos: u32) Error!?TypeId {
    if (self.isPoison(ty)) return ty;
    if (closure or sema.holdsCallable(self.ctx, ty)) return null;
    switch (self.ctx.types.get(ty)) {
        .read_view, .write_view => {
            if (sema.copiedThrough(self.ctx, ty)) |value| return value;
            const value = sema.unwrapViews(self.ctx, ty);
            return switch (sema.cloneable(self.ctx, ty)) {
                .bump, .text, .deep => value,
                .depends => {
                    try ViewCheck.requireOf(self, value, .clones, pos, "clones into a closure a value");
                    return value;
                },
                .copy, .no => null,
            };
        },
        else => {},
    }
    return switch (sema.cloneable(self.ctx, ty)) {
        .copy, .bump, .deep => ty,
        // A `?String` view clones into the `String` that owns its bytes.
        .text => if (ty == self.t().string_view_id) self.t().string_id else ty,
        .depends => {
            try ViewCheck.requireOf(self, ty, .clones, pos, "clones into a closure a value");
            return ty;
        },
        .no => null,
    };
}
