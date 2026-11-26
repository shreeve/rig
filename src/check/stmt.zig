//! Typecheck's statements: bindings, assignments, returns, discards, and
//! the check of a statement again in the form typecheck rewrites it into
//! (`checkRewritten`).

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CompatCheck = @import("compat.zig");
const GenericCheck = @import("generics.zig");
const CallCheck = @import("calls.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const ViewCheck = @import("views.zig");

pub fn checkStmt(self: *Checker, stmt: Sexp) Error!void {
    const head = stmt.kind() orelse return checkExprStmt(self, stmt);
    if (FlowCheck.isValueLoop(self, stmt)) {
        try self.errAt(stmt, "the value of this loop is not used; bind it (`x = loop` ...) or `break` without a value", .{});
        _ = try FlowCheck.checkLoopValue(self, stmt, null, false);
        return;
    }
    switch (head) {
        .set => {
            const mark = self.ctx.diagnostics.items.len;
            try checkSet(self, stmt);
            if (self.ctx.diagnostics.items.len == mark) try ViewCheck.checkKeptSet(self, stmt);
        },
        .destructure => try checkDestructure(self, stmt),
        .@"return" => {
            const mark = self.ctx.diagnostics.items.len;
            try checkReturn(self, stmt);
            const value = ir.Return.value(stmt);
            // Each of several results is checked where it is checked.
            if (value != .nil and !value.isKind(.results) and self.ctx.diagnostics.items.len == mark) try ViewCheck.keptViews(self, value, .returned);
        },
        .@"if" => _ = try FlowCheck.checkIfValue(self, stmt, null, .statement),
        .@"while" => try FlowCheck.checkWhile(self, stmt),
        .@"for" => try FlowCheck.checkFor(self, stmt),
        .match => _ = try PatternCheck.checkMatch(self, stmt, .statement, null),
        .block => {
            const prev = self.enter(stmt);
            defer self.scope = prev;
            for (ir.Block.stmts(stmt)) |*c| try self.checkRewritten(c, checkStmt, .{});
        },
        .drop => {
            const name = ir.Drop.target(stmt);
            // `<e` of anything but a name drops what it takes, as
            // `_ = <e` does; a view made there takes nothing.
            if (name != .src) {
                const operand = ir.Move.operand(name);
                if (operand.isKind(.read) or operand.isKind(.write)) {
                    _ = try PatternCheck.synthExpr(self, operand);
                    return self.errAt(stmt, "this expression does nothing as a statement: `{s}` moves a view nowhere, and a view owns nothing to drop", .{CallCheck.sourceText(self, name)});
                }
                return checkDiscard(self, name);
            }
            const ty = try PatternCheck.synthExpr(self, name);
            if (self.ctx.symbolOf(name)) |id| try self.ctx.recordWrite(stmt, id, .move);
            if (try PatternCheck.payloadViewTaken(self, name, "drop")) return;
            // Plain data owns nothing, and ends a loan only when it
            // may hold a view (a `?String` may view a String).
            if (!self.isPoison(ty) and sema.holdsNoLoanButText(self.ctx, ty) and !sema.mayHoldView(self.ctx, ty)) {
                try self.errAt(stmt, "`<{s}` drops nothing: `{s}` is plain data", .{ self.text(name), self.text(name) });
            }
        },
        .@"break" => try FlowCheck.checkBreak(self, stmt),
        .@"continue" => _ = try FlowCheck.resolveJump(self, stmt),
        .panic => _ = try StdFormCheck.checkPanic(self, stmt),
        .pass, .rarely => {},
        .@"defer", .@"errdefer" => {
            if (head == .@"errdefer") try checkErrdeferCanRun(self, stmt);
            const saved = self.body;
            defer self.body = saved;
            self.body.fail_to = .deferred;
            self.body.loops = null;
            const body = ir.get(stmt, .body);
            // A deferred statement runs at scope exit already: one
            // deferred again there means nothing more.
            if (body.isKind(.@"defer") or body.isKind(.@"errdefer")) {
                return self.errAt(body, "a deferred statement cannot itself be a `defer` or an `errdefer`: write one", .{});
            }
            try checkStmt(self, body);
            // The statement runs at scope exit: a name it declared
            // would be visible to code that runs before it. So would
            // each name several results bind (`defer q, r = f()`).
            const sets: []const Sexp = if (body.isKind(.destructure)) ir.Destructure.targets(body).items() else &.{body};
            for (sets) |set| if (set.isKind(.set) and ir.Set.target(set) == .src) if (self.ctx.symbolOf(ir.Set.target(set))) |id| {
                const target = ir.Set.target(set);
                if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                    (try self.ctx.symbolMut(id)).ty = self.t().invalid_id;
                    try self.errAt(target, "a deferred statement runs at scope exit and cannot declare `{s}`; use an indented `{s}` block", .{ self.text(target), @tagName(stmt.kind().?) });
                }
            };
        },
        .raw_block => {
            self.raw_depth += 1;
            defer self.raw_depth -= 1;
            try checkStmt(self, ir.RawBlock.body(stmt));
        },
        .labeled => {
            const inner = ir.Labeled.stmt(stmt);
            const label = self.text(ir.Labeled.label(stmt));
            if (inner.isKind(.@"while") or inner.isKind(.@"for")) {
                self.expect.loop_label = label;
                return checkStmt(self, inner);
            }
            // Only a loop, a `match`, a `raw` block, or the block a
            // label on a line of its own names has a use for a label;
            // the statement is still checked as if it took one.
            if (inner.isKind(.labeled)) {
                try self.errAt(stmt, "a loop, `match`, `raw` block, or block takes one label; `${s}` labels a statement already labeled `${s}`", .{ label, self.text(ir.Labeled.label(inner)) });
            } else if (!inner.isKind(.match) and !inner.isKind(.raw_block) and !inner.isKind(.block)) {
                const prefix = "a label names a loop, `match`, or `raw` block that `break` or `continue` can leave, or, on a line of its own, the block under it";
                switch (inner.kind() orelse .labeled) {
                    .@"if" => try self.errAt(stmt, "{s}; `${s}` cannot label an `if`", .{ prefix, label }),
                    .@"defer" => try self.errAt(stmt, "{s}; `${s}` cannot label a `defer`", .{ prefix, label }),
                    .@"errdefer" => try self.errAt(stmt, "{s}; `${s}` cannot label an `errdefer`", .{ prefix, label }),
                    else => try self.errAt(stmt, "{s}; `${s}` on this statement would do nothing", .{ prefix, label }),
                }
            }
            var frame: Checker.LoopFrame = .{ .label = label, .node = inner, .is_loop = false, .parent = self.body.loops };
            try FlowCheck.enterFrame(self, &frame);
            defer self.body.loops = frame.parent;
            try checkStmt(self, inner);
        },
        .fun, .sub, .@"struct", .@"enum", .errors, .error_join, .type, .generic_struct, .generic_enum, .use, .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .@"test", .@"pub" => {
            try self.errAt(stmt, "declarations are only allowed at module level", .{});
        },
        else => try checkExprStmt(self, stmt),
    }
}

/// An `errdefer` runs only when its function fails: one where
/// nothing can fail would never run.
pub fn checkErrdeferCanRun(self: *Checker, stmt: Sexp) Error!void {
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
pub fn checkExprStmt(self: *Checker, stmt: Sexp) Error!void {
    // A closure runs only when called.
    if (stmt.isKind(.lambda)) {
        _ = try PatternCheck.synthExpr(self, stmt);
        return self.errAt(stmt, Checker.never_called, .{});
    }
    // A task as a statement is dropped at the statement's end, which
    // cancels it and waits for it: it would never run concurrently.
    if (stmt.isKind(.call) and ir.Call.task(stmt) != .nil) {
        _ = try PatternCheck.synthExpr(self, stmt);
        try self.errAt(stmt, "this task is dropped as soon as it starts, which waits for it to end: bind it, `t = {s}`, and wait for it later, or call without `&`", .{CallCheck.sourceText(self, stmt)});
        return;
    }
    // A statement `-x` negates `x` and discards the result; a drop is
    // written `<x`.
    if (stmt.isKind(.neg)) {
        const operand = ir.Neg.operand(stmt);
        const ty = try PatternCheck.synthExpr(self, operand);
        // The operand's own error is the one reported.
        if (self.isPoison(ty)) return;
        const owns_or_views = !sema.holdsNoLoanButText(self.ctx, ty) or sema.mayHoldView(self.ctx, ty);
        const shown = try ViewCheck.plainText(self, operand);
        // `<x` is offered only where it drops `x` (`sema.undroppable`,
        // by which the ownership checker rejects it).
        const negates = "this expression does nothing as a statement: `{s}` negates a value and discards it; ";
        const why = sema.undroppable(self.ctx, operand);
        if (why != null and (why.? == .view_param or owns_or_views)) switch (why.?) {
            .view_param => try self.errAt(stmt, negates ++ "a view parameter is not dropped, since the caller owns what it views", .{CallCheck.sourceText(self, stmt)}),
            .capture => try self.errAt(stmt, negates ++ "a closure keeps what it captures for every call, so `{s}` is not dropped here", .{ CallCheck.sourceText(self, stmt), shown }),
            .loop_slot => try self.errAt(stmt, negates ++ "`{s}` views an element the loop walks, which is dropped with what holds it", .{ CallCheck.sourceText(self, stmt), shown }),
        } else if (owns_or_views and sema.handsOver(self.ctx, operand).kind == .place) {
            // `<` takes a binding, or an optional field or element.
            const takes = operand == .src or self.ctx.types.get(ty) == .optional;
            if (takes) {
                try self.errAt(stmt, "this expression does nothing as a statement; to drop `{s}` now, write `<{s}`", .{ shown, shown });
            } else try self.errAt(stmt, "this expression does nothing as a statement; `{s}` is dropped with what holds it, or replaced by assigning to it", .{shown});
        } else try self.errAt(stmt, "this expression does nothing as a statement: `{s}` negates a value and discards it", .{CallCheck.sourceText(self, stmt)});
        return;
    }
    const saved = self.expect.discarded;
    defer self.expect.discarded = saved;
    self.expect.discarded = stmt;
    const saved_named = self.expect.discard_named;
    defer self.expect.discard_named = saved_named;
    self.expect.discard_named = false;
    try self.ctx.recordDiscard(stmt);
    // A call's several results are discarded whole, as one result is.
    const saved_ok = self.expect.results_ok;
    defer self.expect.results_ok = saved_ok;
    self.expect.results_ok = CompatCheck.resultCall(stmt) orelse .nil;
    const ty = try PatternCheck.synthExpr(self, stmt);
    // A closure literal alone is reported by the ownership checker.
    if (self.isPoison(ty) or stmt.isKind(.lambda)) return;
    if (try StdFormCheck.discardedSwap(self, stmt)) return;
    // A test's last line is its value: a `Bool` decides the test.
    if (self.body.in_test and CompatCheck.sameSite(stmt, self.expect.test_tail) and ExprCheck.canonical(self, ty) == self.t().bool_id) return self.ctx.record(.test_checks, stmt, try testReport(self, stmt));
    if (!hasEffect(stmt)) {
        // A statement `<e` is a drop everywhere but on a line whose
        // value is used, which a closure's last line is, though this
        // closure gives none.
        if (stmt.isKind(.move)) {
            const shown = try ViewCheck.plainText(self, ir.Move.operand(stmt));
            return self.errAt(stmt, "a closure's last line is its value, and so is the last line of a branch that ends it, so `<{s}` here is no drop, and this closure gives no value; to drop `{s}` here, write `_ = <{s}`", .{ shown, shown, shown });
        }
        if (stmt.kind() == null and self.ctx.types.get(ty) == .function)
            return self.errAt(stmt, "`{s}` is a function; call it with `{s}()`", .{ self.text(stmt), self.text(stmt) });
        return self.errAt(stmt, "this expression does nothing as a statement; use its value, or discard it with `_ = ...`", .{});
    }
    if ((try ViewCheck.needsCleanup(self, ty, self.startOf(stmt), "discards a value"))) {
        if (sema.resultsOf(self.ctx, ty)) |parts| {
            const shown = CallCheck.sourceText(self, stmt);
            return self.errAt(stmt, "this statement gives the results `{s}`, which own what they must release, and does not use them; bind each (`{s} = {s}`), or drop them now with `_ = {s}`", .{ try self.tyName(ty), try resultNames(self, parts.len), shown, shown });
        }
        try self.errAt(stmt, "this statement makes a `{s}`, which owns what it must release, and does not use it; bind it (`x = ...`), drop it now with `_ = ...`, or move it into a place that keeps it", .{try self.tyName(ty)});
    }
}

/// Whether evaluating `e` runs code or leaves: a call, a builtin, a
/// propagation, or a `catch`.
pub fn hasEffect(e: Sexp) bool {
    return effectIn(e, false) != null;
}

/// The first part of `e` whose evaluation runs code or leaves: a
/// call, a propagation, or a `catch`, and with `sigils` also a move,
/// a write view, a clone, a box, a shared or weak handle, or a
/// `panic`. A builtin only computes a value from its arguments, and a
/// closure literal inside `e` runs nothing until it is called.
pub fn effectIn(e: Sexp, sigils: bool) ?Sexp {
    const kind = e.kind() orelse return null;
    switch (kind) {
        .call, .propagate, .propagate_none, .@"catch" => return e,
        .move, .write, .clone, .box, .share, .weak, .panic => if (sigils) return e,
        .lambda => return null,
        else => {},
    }
    for (rig.children(e)) |c| if (effectIn(c, sigils)) |found| return found;
    return null;
}

/// What `effectIn` found, as a diagnostic names it.
pub fn effectName(e: Sexp) []const u8 {
    return switch (e.kind().?) {
        .call => "the call",
        .propagate, .propagate_none => "the propagation",
        .@"catch" => "the `catch`",
        .move => "the move",
        .write => "the write view",
        .clone => "the clone",
        .box => "the box",
        .share => "the shared handle",
        .weak => "the weak handle",
        else => "the panic",
    };
}

pub fn checkReturn(self: *Checker, node: Sexp) Error!void {
    const value = ir.Return.value(node);
    if (self.body.in_test and value.isKind(.results)) return self.errAt(value, "a test returns one `Bool`, and `false` fails it; it gives no several results", .{});
    if (value.isKind(.results)) return checkReturnResults(self, node, value);
    // `return f()` gives the several results `f` gives, whole.
    const saved_ok = self.expect.results_ok;
    defer self.expect.results_ok = saved_ok;
    if (sema.resultsOf(self.ctx, self.body.ret) != null) self.expect.results_ok = CompatCheck.resultCall(value) orelse .nil;
    if (value != .nil) try ViewCheck.recordUse(self, value, .take);
    const ret = self.body.ret;
    if (self.body.fail_to == .deferred) try self.errAt(node, "cannot `return` inside `defer`; the deferred code runs as the function exits", .{});
    // A test returns the `Bool` that decides it.
    if (self.body.in_test and value != .nil) {
        const ty = try PatternCheck.synthExpr(self, value);
        if (self.isPoison(ty)) return;
        if (ExprCheck.canonical(self, ty) != self.t().bool_id) return self.errAt(value, "a test returns a `Bool`, and `false` fails it; this `return` gives `{s}`", .{try self.tyName(ty)});
        return self.ctx.record(.test_checks, node, try testReport(self, node));
    }
    if (self.body.returns) |sites| {
        const ty: ?TypeId = if (value == .nil) null else try PatternCheck.synthExpr(self, value);
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
        const ty = try PatternCheck.synthExpr(self, value);
        if (sema.isErrorSet(self.ctx, ty)) {
            try self.errAt(value, "a `sub` that cannot fail returns no error; declare it fallible to fail: `sub {s}!`", .{CallCheck.headerText(self, self.body.name)});
        } else try self.errAt(value, "a `sub` returns no value; remove the value or declare a `fun`", .{});
        return;
    }
    const saved = self.expect.return_operand;
    defer self.expect.return_operand = saved;
    self.expect.return_operand = value;
    try ViewCheck.checkExpr(self, value, ret);
    // A fallible `sub` returns an error or nothing: a value that gives
    // nothing (`return say(1)!`) is no error, and runs as a statement.
    if (self.body.is_sub) if (self.ctx.typeOf(value)) |ty| if (ExprCheck.canonical(self, ty) == self.t().void_id) {
        try self.errAt(value, "a `sub` returns no value, and fails only by returning an error: write `{s}` on its own line, then `return`", .{CallCheck.sourceText(self, value)});
    };
}

/// What `rig test` reports when the `Bool` that `node`, a test's last
/// line or a `return` in it, gives is `false`: `t == "a" is false`,
/// written on one line. For a `return false`, the rest of its line,
/// which holds any guard: `return false if n > 3`. For a last line
/// `false`, where it is: `reached false on line 12`.
pub fn testReport(self: *Checker, node: Sexp) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const value = if (node.isKind(.@"return")) ir.Return.value(node) else node;
    if (node == .src and std.mem.eql(u8, CallCheck.sourceText(self, node), "false")) {
        return a.print("reached false on line {d}", .{diag.lineCol(self.ctx.source, self.ctx.span(node).start).line});
    }
    if (node.isKind(.@"return") and value == .src and std.mem.eql(u8, CallCheck.sourceText(self, value), "false")) {
        const src = self.ctx.source;
        const start = self.ctx.span(node).start;
        const end = std.mem.findScalarPos(u8, src, start, '\n') orelse src.len;
        const rest = try CompatCheck.withoutComments(a, src[start..end]);
        return std.mem.trimEnd(u8, rest, " \t\r");
    }
    return a.print("{s} is false", .{try CompatCheck.oneLine(a, CallCheck.sourceText(self, value))});
}

/// Whether `e` is a branch leaf of the `return` operand being
/// checked, where an error value may meet a `T!`: the operand, or a
/// branch of a ternary or an arm of a `match` that is a leaf, never
/// anything deeper.
pub fn isReturnLeaf(self: *const Checker, e: Sexp) bool {
    return isBranchLeaf(self.expect.return_operand, e);
}

pub fn isBranchLeaf(value: Sexp, e: Sexp) bool {
    if (CompatCheck.sameNode(value, e) or (value == .src and e == .src and value.src.pos == e.src.pos)) return true;
    switch (value.kind() orelse return false) {
        .@"if" => return isBranchLeaf(ir.If.then(value), e) or isBranchLeaf(ir.If.@"else"(value), e),
        .match => for (ir.Match.arms(value)) |arm| {
            if (isBranchLeaf(ir.Arm.body(arm), e)) return true;
        },
        else => {},
    }
    return false;
}

/// `q, r = f()`: the call's several results, each bound to its
/// target left to right as `x = e` binds `e` (each target but `_` is
/// `(set op x _ (result_part))`). The value is a call that gives
/// them, alone or under `!`, `?`, or a fallback that jumps
/// (docs/internals/INTERNALS.md, "Several results").
pub fn checkDestructure(self: *Checker, node: Sexp) Error!void {
    const value = ir.Destructure.value(node);
    const targets = ir.Destructure.targets(node).items();
    if (value.isKind(.results)) return parallelAssignment(self, node, targets, value);
    var ok = try checkResultTargets(self, targets);
    const call = CompatCheck.resultCall(value) orelse Sexp.nil;
    if (ok and !isResultsValue(self, value)) {
        try self.errAt(value, "several results are bound from a call that gives them: `{s} = f()`, `f()!`, `f()?`, or a fallback that jumps (`f() ?? return`, `f() catch return`, `catch break`, `catch continue`); a value cannot stand for several results", .{try targetNames(self, targets)});
        _ = try FlowCheck.synthQuiet(self, value);
        for (targets) |tg| if (tg.isKind(.set)) try poisonTarget(self, tg);
        return;
    }
    const saved_ok = self.expect.results_ok;
    defer self.expect.results_ok = saved_ok;
    self.expect.results_ok = call;
    try ViewCheck.recordUse(self, value, .take);
    // `new q, r = f(q)` reads the `q` it shadows, as `new x = e` does.
    const saved_names = self.expect.pending_names;
    defer self.expect.pending_names = saved_names;
    if (rig.shadows(ir.Destructure.op(node))) {
        var names: std.ArrayList(SymbolId) = .empty;
        for (targets) |tg| if (tg.isKind(.set) and ir.Set.target(tg) == .src) if (self.ctx.symbolOf(ir.Set.target(tg))) |id| {
            try names.append(self.ctx.arena.allocator(), id);
        };
        self.expect.pending_names = names.items;
    }
    const ty = try PatternCheck.synthExpr(self, value);
    self.expect.pending_names = saved_names;
    var parts: []const TypeId = &.{};
    if (!self.isPoison(ty)) switch (self.ctx.types.get(ty)) {
        .results => |r| parts = r,
        // Reported where the call is typed (`synthCall`).
        .fallible => ok = false,
        else => if (ok) {
            const name = if (call != .nil) try StdFormCheck.calleeName(self, ir.Call.callee(call)) else CallCheck.sourceText(self, value);
            const shown = CallCheck.sourceText(self, value);
            if (sema.resultsOf(self.ctx, ty) != null) {
                try self.errAt(value, "`{s}` gives several results inside an optional, `{s}`: test it first, `{s}?`, `{s} ?? return`, or `if {s} as {s}`", .{ name, try self.tyName(ty), shown, shown, shown, try targetNames(self, targets) });
            } else try self.errAt(value, "`{s}` gives one result, of type `{s}`; bind it to one name", .{ name, try self.tyName(ty) });
            ok = false;
        },
    };
    if (ok and parts.len > 0 and parts.len != targets.len) {
        try self.errAt(value, "`{s}` gives {d} results, but {d} names are bound", .{ try StdFormCheck.calleeName(self, ir.Call.callee(call)), parts.len, targets.len });
        ok = false;
    }
    const saved_part = self.expect.part_ty;
    defer self.expect.part_ty = saved_part;
    const mark = self.ctx.diagnostics.items.len;
    for (targets, 0..) |tg, j| {
        if (!tg.isKind(.set)) continue;
        self.expect.part_ty = if (ok and j < parts.len) parts[j] else self.t().invalid_id;
        if (ok) try checkSet(self, tg) else try poisonTarget(self, tg);
    }
    // A view a kept result carries is written (Core sentence 4). A
    // read view is kept by a result that only reads, so one is named
    // first.
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
    if (keeper != .nil) try ViewCheck.keptViews(self, value, .{ .binding = self.text(ir.Set.target(keeper)) });
}

/// The targets of a destructure: names or `_`, each named once. A
/// field or element is not one: its indexes would run in the middle
/// of the bindings. False when one is reported.
pub fn checkResultTargets(self: *Checker, targets: []const Sexp) Error!bool {
    var ok = true;
    for (targets, 0..) |tg, j| {
        if (!tg.isKind(.set)) continue;
        const target = ir.Set.target(tg);
        if (target != .src) {
            const shown = CallCheck.sourceText(self, target);
            const reads = for (targets) |o| {
                if (!o.isKind(.set) or ir.Set.target(o) != .src) continue;
                const name = self.text(ir.Set.target(o));
                if (CompatCheck.readsNameIn(self.ctx.source, target, name)) break name;
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
pub fn isResultsValue(self: *const Checker, value: Sexp) bool {
    _ = self;
    const head = value.kind() orelse return false;
    return switch (head) {
        .call => true,
        .propagate => ir.Propagate.value(value).isKind(.call),
        .propagate_none => ir.PropagateNone.value(value).isKind(.call),
        .@"??" => ir.@"??".left(value).isKind(.call) and CompatCheck.isJumpNode(ir.@"??".right(value)),
        .@"catch" => ir.Catch.value(value).isKind(.call) and CompatCheck.isJumpNode(ir.Catch.handler(value)),
        else => false,
    };
}

/// A destructure target checked after its statement was reported:
/// its name gets no type, so its uses report nothing more.
pub fn poisonTarget(self: *Checker, set: Sexp) Error!void {
    const target = ir.Set.target(set);
    if (target != .src) return;
    const sym = self.ctx.symbolOf(target) orelse return;
    if (self.ctx.symbols.items[sym].decl_pos == target.src.pos) (try self.ctx.symbolMut(sym)).ty = self.t().invalid_id;
    try self.ctx.recordType(ir.Set.value(set), self.t().invalid_id);
}

/// `a, b = b, a` and `q, r = 1, 2`: Rig has no parallel assignment.
pub fn parallelAssignment(self: *Checker, node: Sexp, targets: []const Sexp, value: Sexp) Error!void {
    const values = ir.Results.values(value);
    for (values) |v| _ = try PatternCheck.synthExpr(self, v);
    for (targets) |tg| if (tg.isKind(.set)) try poisonTarget(self, tg);
    // Two names given each other's values: a swap.
    if (targets.len == 2 and values.len == 2 and values[0] == .src and values[1] == .src and targets[0].isKind(.set) and targets[1].isKind(.set)) {
        const a = ir.Set.target(targets[0]);
        const b = ir.Set.target(targets[1]);
        if (a == .src and b == .src and std.mem.eql(u8, self.text(a), self.text(values[1])) and std.mem.eql(u8, self.text(b), self.text(values[0]))) {
            return self.errAt(node, "Rig has no parallel assignment: write `swap(!{s}, !{s})` to exchange two places", .{ self.text(a), self.text(b) });
        }
    }
    try self.errAt(node, "Rig has no parallel assignment: bind each name on its own line; several results come from a call, `{s} = f()`", .{try targetNames(self, targets)});
}

/// The targets of a destructure as written: `q, r`.
pub fn targetNames(self: *Checker, targets: []const Sexp) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    for (targets, 0..) |tg, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, CallCheck.sourceText(self, if (tg.isKind(.set)) ir.Set.target(tg) else tg));
    }
    return out.items;
}

/// The function being checked, for a message: `` `f` ``, or this
/// closure.
pub fn bodyName(self: *Checker) Error![]const u8 {
    if (self.body.name == .nil) return "this closure";
    return self.ctx.arena.allocator().print("`{s}`", .{self.text(self.body.name)});
}

/// `n` names for a hint that binds several results: `a, b`.
pub fn resultNames(self: *Checker, n: usize) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    for (0..n) |i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.append(a, @as(u8, @intCast(@as(usize, 'a') + @min(i, 25))));
    }
    return out.items;
}

/// A call that gives several results, where they may not stand.
pub fn misplacedResults(self: *Checker, call: Sexp, ty: TypeId) Error!void {
    const n = sema.resultsOf(self.ctx, ty).?.len;
    const name = try StdFormCheck.calleeName(self, ir.Call.callee(call));
    if (CompatCheck.sameNode(call, self.expect.bound_call)) {
        return self.errAt(call, "`{s}` gives {d} results; bind each: `{s} = {s}`", .{ name, n, try resultNames(self, n), CallCheck.sourceText(self, self.expect.bound_value) });
    }
    // A `for` over an iterator calls its `next` for one value a step.
    const callee = ir.Call.callee(call);
    if (callee.isKind(.member) and rig.isHiddenLeaf(ir.Member.name(callee))) {
        return self.errAt(call, "a `for` binds one value each step, and this iterator's `next` gives {d} results: bind them with `while (!it).next() as {s}`", .{ n, try resultNames(self, n) });
    }
    if (CompatCheck.sameNode(call, self.expect.as_call)) {
        return self.errAt(call, "`{s}` gives {d} results: bind each, `if {s} as {s}`", .{ name, n, CallCheck.sourceText(self, call), try resultNames(self, n) });
    }
    if (CompatCheck.sameNode(call, self.expect.results_tail)) {
        return self.errAt(call, "several results are given with `return`: `return {s}`", .{CallCheck.sourceText(self, call)});
    }
    try self.errAt(call, "a call that gives several results stands only where each result is bound: `{s} = {s}`", .{ try resultNames(self, n), CallCheck.sourceText(self, call) });
}

/// `(a, b)` as a value: Rig has no tuples.
pub fn tupleValue(self: *Checker, e: Sexp) Error!TypeId {
    const elems = ir.Tuple.elems(e);
    for (elems) |x| _ = try PatternCheck.synthExpr(self, x);
    const src = CallCheck.sourceText(self, e);
    const inner = std.mem.trim(u8, src[1 .. src.len - 1], " ");
    if (sema.resultsOf(self.ctx, self.body.ret) != null) {
        try self.errAt(e, "Rig has no tuple values: give several results with `return {s}`", .{inner});
    } else try self.errAt(e, "Rig has no tuple values: name an object for a group of values, or give a function several results, `-> (A, B)`, with `return {s}`", .{inner});
    return self.t().invalid_id;
}

/// `return a, b`: each part is a result, checked as `return x` checks
/// its value against the result type in its position.
pub fn checkReturnResults(self: *Checker, node: Sexp, value: Sexp) Error!void {
    const parts = ir.Results.values(value);
    if (self.body.fail_to == .deferred) try self.errAt(node, "cannot `return` inside `defer`; the deferred code runs as the function exits", .{});
    for (parts) |p| try ViewCheck.recordUse(self, p, .take);
    const ret = self.body.ret;
    const tys: ?[]const TypeId = if (self.body.returns != null) null else sema.resultsOf(self.ctx, ret);
    const want = tys orelse {
        for (parts) |p| _ = try PatternCheck.synthExpr(self, p);
        // A closure whose result is inferred gives one.
        if (self.body.returns != null) return self.errAt(value, "a closure gives several results only where its type says so: `?fun(...) -> (A, B)`", .{});
        if (self.isPoison(ret)) return;
        if (self.body.is_sub) return self.errAt(value, "a `sub` returns no value; several results are a `fun`'s: `-> (A, B)`", .{});
        return self.errAt(value, "{s} gives one result, of type `{s}`; several are declared `-> (A, B)`", .{ try bodyName(self), try self.tyName(ret) });
    };
    if (want.len != parts.len) {
        for (parts) |p| _ = try PatternCheck.synthExpr(self, p);
        return self.errAt(value, "{s} gives {d} results, but `return` gives {d}", .{ try bodyName(self), want.len, parts.len });
    }
    const saved = self.expect.return_operand;
    defer self.expect.return_operand = saved;
    for (parts, want) |p, ty| {
        self.expect.return_operand = p;
        const mark = self.ctx.diagnostics.items.len;
        try ViewCheck.checkExpr(self, p, ty);
        if (self.ctx.diagnostics.items.len == mark) try ViewCheck.keptViews(self, p, .returned);
    }
}

/// `_ = e`, and a statement `<e` that drops what it takes: `e` is
/// taken, and dropped at the statement's end.
pub fn checkDiscard(self: *Checker, value: Sexp) Error!void {
    try ViewCheck.recordUse(self, value, .take);
    _ = try PatternCheck.synthExpr(self, value);
}

pub fn checkSet(self: *Checker, node: Sexp) Error!void {
    const kind = rig.bindingKindOf(ir.Set.op(node));
    const target = ir.Set.target(node);
    const type_node = ir.Set.type(node);
    const rhs = ir.Set.value(node);
    const saved_bound = .{ self.expect.bound_value, self.expect.bound_call, self.expect.local_value, self.expect.local_target };
    defer self.expect.bound_value, self.expect.bound_call, self.expect.local_value, self.expect.local_target = saved_bound;
    self.expect.bound_value = rhs;
    self.expect.bound_call = CompatCheck.resultCall(rhs) orelse .nil;
    self.expect.local_value = if (target == .src) rhs else .nil;
    self.expect.local_target = target;
    if (kind == .default) try StdFormCheck.checkTemplateGrows(self, rhs, target);
    // A binding, an assignment, and `_ = e` take the value.
    try ViewCheck.recordUse(self, rhs, .take);

    // `(q, r) = f()`: several results are bound by the bare list.
    if (target.isKind(.tuple)) {
        _ = try FlowCheck.synthQuiet(self, rhs);
        const src = CallCheck.sourceText(self, target);
        return self.errAt(target, "write `{s} = {s}`; parentheses aren't needed on the left", .{ std.mem.trim(u8, src[1 .. src.len - 1], " "), CallCheck.sourceText(self, rhs) });
    }
    if (target != .src) return checkPlaceAssign(self, kind, target, type_node, rhs);

    const name = self.text(target);
    if (std.mem.eql(u8, name, "_")) {
        // `x op= e` reads `x`.
        if (kind.operator() != null) try self.errAt(target, Checker.discard_read, .{});
        if (kind == .fixed) try self.errAt(target, "`_` binds nothing, so it cannot be fixed; discard with `_ = ...`", .{});
        // `_ =` discards the value, so a write call there is a
        // statement's (`isDiscardedCall`).
        const saved = self.expect.discarded;
        defer self.expect.discarded = saved;
        self.expect.discarded = rhs;
        const saved_named = self.expect.discard_named;
        defer self.expect.discard_named = saved_named;
        self.expect.discard_named = true;
        // `_ = f()` discards every result `f` gives.
        const saved_ok = self.expect.results_ok;
        defer self.expect.results_ok = saved_ok;
        self.expect.results_ok = CompatCheck.resultCall(rhs) orelse .nil;
        _ = try PatternCheck.synthExpr(self, rhs);
        if (rhs.isKind(.lambda)) try self.errAt(rhs, Checker.never_called, .{});
        return;
    }
    // A compound assignment names an existing binding.
    const sym_id = self.ctx.symbolOf(target) orelse (try ExprCheck.useName(self, target)) orelse {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    };
    // A copy: resolving the annotation may add symbols (`sema.proxyOf`).
    const sym = self.ctx.symbols.items[sym_id];
    const is_decl = sym.decl_pos == target.src.pos;

    // Assigning a view to a `!T` local points it at another place;
    // assigning a value writes the value it views (Core §6). A
    // parameter never changes: a `!T` one only writes through.
    const repoints = !is_decl and sema.assignWritesThrough(self.ctx, sym.ty) and kind == .default and try handsOverWriteView(self, rhs);
    if (repoints and (sym.kind != .local or sym.flags.fixed or sym.flags.pattern_bound or sym.flags.as_bound)) {
        const src = CallCheck.sourceText(self, rhs);
        if (sym.kind == .param) {
            if (sema.writeSliceElem(self.ctx, sym.ty) != null) {
                try self.errAt(rhs, "cannot point parameter `{s}` at another place: parameters are immutable, and `{s}[i] = v` writes its elements; bind another name to `{s}`", .{ name, name, src });
            } else try self.errAt(rhs, "cannot point parameter `{s}` at another place: parameters are immutable, and `{s} = v` writes the value it views; bind another name to `{s}`", .{ name, name, src });
        } else try self.errAt(rhs, "`{s} = {s}` would point `{s}` at another place, which only a local's own name does; write `new {s} = {s}`", .{ name, src, name, name, src });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    const writes_through = !repoints and sema.assignWritesThrough(self.ctx, sym.ty);
    // Nothing but a method writes the value an API object views: its
    // type is erased (docs/design/apis.md, Stage 4).
    if (!is_decl and writes_through and sema.isErasedView(self.ctx, sym.ty)) {
        const inner = sema.unwrapViews(self.ctx, sym.ty);
        try self.errAt(target, "cannot assign through `{s}`, a `{s}`: the value it views may be of another type; call its methods, or hold a `^{s}` and replace the box", .{ name, try self.tyName(sym.ty), try self.tyName(inner) });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    // A `![]T` binding views elements it does not own; there is no
    // whole value to write through to.
    if (!is_decl and writes_through and sema.writeSliceElem(self.ctx, sym.ty) != null) {
        try self.errAt(target, "cannot assign to `{s}`, a `{s}` {s}; write its elements with `{s}[i] = v` or `!{s}.copy(src)`", .{ name, try self.tyName(sym.ty), if (sym.kind == .param) "parameter" else "binding", name, name });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (repoints) {
        try self.ctx.record(.repoints, node, {});
        (try self.ctx.symbolMut(sym_id)).flags.repointed = true;
    }
    if (writes_through) {
        try self.ctx.record(.write_throughs, node, {});
    } else if (!is_decl) (try self.ctx.symbolMut(sym_id)).flags.rebound = true;
    // Assigning a binding writes it without reading it; writing
    // through a `!T` binding reaches the viewed value.
    if (!is_decl and (repoints or self.ctx.types.get(sym.ty) != .write_view)) try self.ctx.putIn(.check, .writes, target.src.leaf, {});
    // The binding must be one that may change.
    if (!is_decl and !try requireAccess(self, placeOf(self, target), .assign, target)) {
        if (kind.operator() == null) try ViewCheck.checkExpr(self, rhs, if (writes_through) sema.unwrapViews(self.ctx, sym.ty) else sym.ty) else _ = try PatternCheck.synthExpr(self, rhs);
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
            try checkCompound(self, kind, declared, rhs, target.src.pos, what);
            try self.ctx.recordType(target, declared);
            return;
        },
        else => {},
    }

    const saved_pending = self.expect.pending;
    defer self.expect.pending = saved_pending;
    if (rig.shadows(ir.Set.op(node))) self.expect.pending = sym_id;
    var rhs_ty: TypeId = undefined;
    if (!self.isPoison(declared) or type_node != .nil) {
        const saved_target = self.expect.static_target;
        const saved_value = self.expect.static_target_value;
        defer {
            self.expect.static_target = saved_target;
            self.expect.static_target_value = saved_value;
        }
        if (!is_decl and type_node == .nil and declared == self.t().static_id) {
            self.expect.static_target = name;
            self.expect.static_target_value = rhs;
        }
        try ViewCheck.checkExpr(self, rhs, declared);
        rhs_ty = declared;
    } else {
        // An unannotated local binding holds the String a template
        // makes; a module's constant is fixed text.
        const saved_template = .{ self.expect.template_ok, self.expect.template_fixed };
        defer self.expect.template_ok, self.expect.template_fixed = saved_template;
        if (rhs.isKind(.template)) {
            if (self.ctx.symbols.items[sym_id].scope != self.module_scope) self.expect.template_ok = rhs else self.expect.template_fixed = rhs;
        }
        rhs_ty = try PatternCheck.synthExpr(self, rhs);
        // A binding holds the write view a call or a sigil hands over
        // (`yieldsWriteView`), as `w: !T = e` does, so assigning it
        // writes through (Core §6). A bare name or place only reads
        // (Core sentence 1): a name, field, element, or loop value of
        // type `!T`, or a branching value of them, binds the value it
        // reaches when that copies (`sema.copiedThrough`). A read view
        // is copied, but one of a scalar binds the scalar
        // (`readValue`).
        const holds_write_view = self.ctx.types.get(rhs_ty) == .write_view and try ViewCheck.yieldsWriteView(self, rhs);
        // A write view of an API object reaches a value of no type a
        // binding could copy or move.
        if (!rhs.isKind(.read) and !holds_write_view and sema.isErasedView(self.ctx, rhs_ty) and self.ctx.types.get(rhs_ty) == .write_view) {
            const shown = CallCheck.sourceText(self, rhs);
            try self.errAt(rhs, "`{s}` is a `{s}`, whose value's type is erased, so `{s} = {s}` neither copies nor moves it: pass it on as a view, `{s} = ?{s}` or `{s} = !{s}`", .{ shown, try self.tyName(rhs_ty), name, shown, name, shown, name, shown });
            rhs_ty = self.t().invalid_id;
        } else if (!rhs.isKind(.read) and !holds_write_view) rhs_ty = try ViewCheck.readThrough(self, rhs, rhs_ty, CompatCheck.bindingValue(self.ctx, rhs_ty));
        rhs_ty = try defaultBindingType(self, rhs, rhs_ty, name);
    }

    const s = try self.ctx.symbolMut(sym_id);
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
    if (kind == .fixed and (ternary_const or CallCheck.isComptimeKnown(self, rhs))) s.flags.comptime_known = true;
    // A `=!` local of a value the target sets is set by it too.
    if (s.flags.comptime_known and s.scope != self.module_scope and sema.perTargetLeaf(self.ctx, rhs) != null) s.flags.per_target = true;
    // `k =! n` stands for the compile-time parameter `n` where an
    // array length or a compile-time argument names it.
    if (kind == .fixed and is_decl and s.kind == .local) if (try StdFormCheck.ctParamOf(self, rhs)) |ct| try self.ctx.putIn(.check, .ct_locals, sym_id, ct);
    try self.ctx.recordType(target, s.ty);
    // A binding that never changes keeps a constant value.
    // (A module constant's was folded before any type was resolved.)
    if (is_decl and s.kind == .local and s.scope != self.module_scope and !s.flags.reassigned and !s.flags.written and sema.isInteger(self.ctx, s.ty)) {
        if (ExprCheck.constInt(self, rhs)) |v| try self.ctx.putIn(.check, .const_ints, sym_id, .{ .value = v, .int = switch (self.ctx.types.get(s.ty)) {
            .int => |i| i,
            else => .{},
        } });
    } else if (is_decl and s.kind == .local and s.scope != self.module_scope and !s.flags.reassigned and !s.flags.written) {
        if (CallCheck.constVariant(self, rhs)) |v| try self.fixed_variants.put(self.ctx.arena.allocator(), sym_id, v);
    }
    // So does one of a `Float`, here and at module level (`cteval.foldFloat`).
    if (is_decl and s.kind == .local and !s.flags.reassigned and !s.flags.written and ExprCheck.canonical(self, s.ty) == self.t().float_id) switch (sema.cteval.foldFloat(f64, self.ctx, rhs, true)) {
        .value => |v| try self.ctx.putIn(.check, .const_floats, sym_id, v),
        else => {},
    };
}

/// Whether `rhs` hands over a write view where it is assigned: `!m`
/// makes one, `<w` moves one, and a call or branching value of type
/// `!T` yields one. A bare name or path of type `!T` reads the value
/// it reaches.
pub fn handsOverWriteView(self: *Checker, rhs: Sexp) Error!bool {
    const kind = rhs.kind() orelse return false;
    return switch (kind) {
        .write => true,
        .member, .index => false,
        else => self.ctx.types.get(try CallCheck.argType(self, rhs)) == .write_view,
    };
}

/// The type an unannotated binding gets from its initializer.
pub fn defaultBindingType(self: *Checker, rhs: Sexp, ty: TypeId, name: []const u8) Error!TypeId {
    const pos = self.startOf(rhs);
    switch (self.ctx.types.get(ty)) {
        .int_literal => {
            try ViewCheck.defaultIntLiteral(self, rhs);
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
pub fn checkPlaceAssign(self: *Checker, kind: rig.BindingKind, target: Sexp, type_node: Sexp, rhs: Sexp) Error!void {
    const head = target.kind();
    const through = storage.assignedThrough(target);
    if (head != .member and head != .index and !through) {
        if (head == .propagate or head == .propagate_none) {
            _ = try PatternCheck.synthExpr(self, ir.get(target, .value));
            try self.errAt(target, "cannot assign to `{s}`: only a call that returns a write view (`!T`), or that call's `!` or `?`, is assigned through", .{CallCheck.sourceText(self, target)});
        } else try self.errAt(target, "cannot assign to this expression", .{});
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (type_node != .nil) {
        try self.errAt(type_node, "a field or element assignment cannot carry a type annotation", .{});
    }
    switch (kind) {
        .fixed, .shadow => {
            try self.errAt(target, "`{s}` binds a name; a field or element can only be assigned with `=`", .{if (kind == .fixed) "=!" else "new"});
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        },
        else => {},
    }
    const saved_use = self.expect.index_use;
    defer self.expect.index_use = saved_use;
    if (head == .index) self.expect.index_use = .{
        .at = target,
        .form = if (kind.operator() != null) .compound else .assign,
        .rhs_text = try ViewCheck.plainText(self, rhs),
        .op = switch (kind) {
            inline else => |c| @tagName(c),
        },
    };
    const place_ty = try PatternCheck.synthExpr(self, target);
    self.expect.index_use = saved_use;
    if (through) return assignThroughCall(self, kind, target, place_ty, rhs);
    if (try StdFormCheck.rejectLane(self, target, .assign)) {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    const place = placeOf(self, target);
    if (place.cell_list_elem) |elem| {
        if (!CompatCheck.sameNode(elem, target) or kind.operator() != null) {
            try self.errAt(target, "an element of a Cell's List is written whole, with `c[i] = e`: copy it out, change the copy, and write it back", .{});
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        }
        if (self.isPoison(place_ty)) {
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        }
        // The Cell changes, so the write view that changes it is
        // written, unless a write view of it already stands there.
        const cell = ir.get(elem, .object);
        const cell_ty = self.ctx.typeOf(cell) orelse sema.type_invalid;
        if (!place.marked and self.ctx.types.get(cell_ty) != .write_view and ViewCheck.viewOf(self, place.base) == null) {
            try self.errAt(target, "write `(!{s})[i] = e`: changing a shared Cell is marked with `!`", .{try ViewCheck.plainText(self, cell)});
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        }
        return ViewCheck.checkExpr(self, rhs, place_ty);
    }
    if (!try requireAccess(self, place, .assign, target)) {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    // Assigning an element drops the value it held, as assigning a
    // field does; a generic body's element of a `T` needs each
    // instance to own nothing.
    if (head == .index) _ = try ViewCheck.needsCleanup(self, place_ty, self.startOf(target), "overwrites an element");
    if (kind.operator() != null) return checkCompound(self, kind, place_ty, rhs, self.startOf(target), "this place has type");
    try ViewCheck.checkExpr(self, rhs, place_ty);
}

/// `f(x) = v` or `f(x) op= v`, where the call returns a write view
/// `!T`, and so `f(x)! = v` and `f(x)? = v` of a call that returns a
/// fallible or optional one (`storage.assignedThrough`): the `T` the
/// view reaches is written, as `__v: T = v; w = f(x); w op= __v`
/// writes it through a hidden binding `w` (Core §6). The value runs
/// first, then the call, as any target's base does
/// (`storage.eachSetStep`). A call that returns a value, a read view,
/// or a `![]T` is not assigned through.
pub fn assignThroughCall(self: *Checker, kind: rig.BindingKind, target: Sexp, view_ty: TypeId, rhs: Sexp) Error!void {
    if (self.isPoison(view_ty)) {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    const viewed = switch (self.ctx.types.get(view_ty)) {
        .write_view => |inner| inner,
        .read_view => {
            try self.errAt(target, "cannot assign through a read view (`?T`), which this call returns; a call that returns a write view (`!T`) is assigned through", .{});
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        },
        else => {
            const name = try self.tyName(view_ty);
            try self.errAt(target, "cannot assign to a call's result, {s} `{s}`; only a write view (`!T`) a call returns is assigned through", .{ CompatCheck.article(name), name });
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        },
    };
    if (sema.writeSliceElem(self.ctx, view_ty) != null) {
        try self.errAt(target, "cannot assign to a `{s}` a call returns; write its elements with `{s}[i] = v`", .{ try self.tyName(view_ty), CallCheck.sourceText(self, target) });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (!try requireAccess(self, placeOf(self, target), .assign, target)) {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (kind.operator() != null) return checkCompound(self, kind, viewed, rhs, self.startOf(target), "the value this call's write view reaches has type");
    try ViewCheck.checkExpr(self, rhs, viewed);
}

/// `x op= e` is `x = x op e` with `x` evaluated once, and `x` keeps its
/// type: arithmetic needs a numeric target, bitwise operators and
/// shifts an integer one. `e` has the target's type, except a shift
/// amount, which may be any integer.
pub fn checkCompound(self: *Checker, kind: rig.BindingKind, target_ty: TypeId, rhs: Sexp, pos: u32, what: []const u8) Error!void {
    const op = kind.operator().?;
    const spelled = @tagName(kind);
    if (self.isPoison(target_ty)) {
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    const req: Requirement = switch (op) {
        .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|" => .integer,
        else => .numeric,
    };
    if (sema.simdOf(self.ctx, target_ty) != null) return StdFormCheck.simdCompound(self, op, spelled, sema.unwrapViews(self.ctx, target_ty), rhs, pos);
    const tv: ?SymbolId = switch (self.ctx.types.get(target_ty)) {
        .type_var => |tv| self.ctx.localSym(tv),
        else => null,
    };
    if (tv) |param| {
        try ExprCheck.require(self, param, req, pos, spelled);
    } else if (!(if (req == .integer) sema.isInteger(self.ctx, target_ty) else sema.isNumeric(self.ctx, target_ty))) {
        try self.err(pos, "`{s}` requires {s} target; {s} `{s}`", .{ spelled, if (req == .integer) "an integer" else "a numeric", what, try self.tyName(target_ty) });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (op == .@"<<" or op == .@"<<%" or op == .@">>") {
        _ = try ExprCheck.checkShiftAmount(self, rhs, target_ty, spelled);
        return;
    }
    if (tv) |param| {
        // A generic `T` target takes another `T` or a literal it holds.
        const ty = try ViewCheck.synthOperandValue(self, rhs);
        if (ExprCheck.meetsTypeVar(self, target_ty, ty, req)) {
            try ExprCheck.requireHoldsLiteral(self, param, ty, rhs, pos, spelled);
        } else if (!self.isPoison(ty)) try ViewCheck.mismatch(self, rhs, target_ty, ty);
    } else try ViewCheck.checkExpr(self, rhs, target_ty);
    _ = try ExprCheck.checkDivisor(self, op, target_ty, rhs);
}

/// The place `e` names, read once (`Place`).
pub fn placeOf(self: *Checker, e: Sexp) Checker.Place {
    var place: Checker.Place = .{ .node = e };
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
            if (place.cell_list_elem == null and CompatCheck.cellListElement(self.ctx, ty) != null) place.cell_list_elem = step;
            const is_text = obj == .string_view or obj == .static;
            if (is_text or (obj == .slice and sema.writeSliceElem(self.ctx, ty) == null)) {
                place.block(if (is_text) .string else .slice, self.startOf(p));
                if (!crossed) place.leaf_blocked = true;
                // A `[]T` is a read view of its elements: nothing
                // changes through it, a handle it holds included, nor
                // a Cell behind one (Core sentence 4).
                if (!is_text) {
                    place.view_blocked = true;
                    if (place.view == null) place.view = .{ .ty = ty, .pos = self.startOf(p) };
                }
            }
        } else if (if (sema.namedNoneOf(self.ctx, inner)) |n| std.mem.eql(u8, n.field, self.text(ir.Member.name(step))) else false) {
            place.block(.none_field, self.startOf(ir.Member.name(step)));
            if (!crossed) place.leaf_blocked = true;
        } else if (self.ctx.get(.read_only_fields, step)) |field| {
            place.block(.read_only, self.startOf(ir.Member.name(step)));
            if (place.blocked.?.why == .read_only) place.read_only = field;
            if (!crossed) place.leaf_blocked = true;
        } else if (self.ctx.isEnumText(step)) {
            place.block(if (inner == self.t().symbol_id) .symbol_text else .text, self.startOf(ir.Member.name(step)));
            if (!crossed) place.leaf_blocked = true;
        } else if (std.mem.eql(u8, self.text(ir.Member.name(step)), "len") and (obj == .slice or obj == .string_view or obj == .static or obj == .string or obj == .array or CompatCheck.listElementType(self.ctx, inner) != null or sema.tableElem(self.ctx, inner) != null or CompatCheck.cellListElement(self.ctx, inner) != null or sema.isTaskSet(self.ctx, inner))) {
            place.block(.len, self.startOf(ir.Member.name(step)));
            if (!crossed) place.leaf_blocked = true;
        }
        switch (self.ctx.types.get(ty)) {
            // Nothing changes through a read view: not what it
            // views, nor a Cell or Signal behind a handle it views or
            // reaches (SPEC §10, "Cell").
            .read_view => {
                place.indirect = true;
                place.block(.read_view, self.startOf(p));
                place.leaf_blocked = true;
                place.view_blocked = true;
                place.view = .{ .ty = ty, .pos = self.startOf(p) };
            },
            // A write view of a read view (`!?T`, an element of
            // `for x in !vs` over a `List[?T]`) reaches its value
            // through the read view. A write view of a value that
            // changes by a marked call views shared storage, which
            // only its Cells and Signals change in, asked of the one
            // classifier (`sema.changesByMark`): an API object's view
            // may be of any value, and is written through its methods.
            .write_view => |viewed| {
                place.indirect = true;
                if (sema.viewedReadView(self.ctx, viewed)) |view| {
                    place.block(.read_view, self.startOf(p));
                    place.leaf_blocked = true;
                    place.view_blocked = true;
                    place.view = .{ .ty = view, .pos = self.startOf(p) };
                } else if (sema.changesByMark(self.ctx, viewed)) place.block(.shared, 0);
            },
            // A slice views elements held elsewhere.
            .shared, .slice => place.indirect = true,
            else => {},
        }
        // A box of a read view (`^?T`, and a view of one) reaches its
        // value through the view, as a `?T` does.
        if (self.ctx.types.get(ty) != .read_view) if (sema.boxedReadView(self.ctx, ty)) |view| {
            place.indirect = true;
            place.block(.read_view, self.startOf(p));
            place.leaf_blocked = true;
            place.view_blocked = true;
            place.view = .{ .ty = view, .pos = self.startOf(p) };
        };
        if (sema.accessThroughShared(self.ctx, ty)) {
            crossed = true;
            place.crossed = true;
            place.block(.shared, 0);
        }
    }
    place.base = p;
    place.pos = self.startOf(p);
    if (self.ctx.typeOf(e)) |ty| if (sema.viewedReadView(self.ctx, ty) != null) {
        place.holds_view = self.startOf(e);
    };
    if (ViewCheck.viewOf(self, p)) |made| place.marked = made.isKind(.write);
    if (p == .src) {
        place.sym = self.ctx.symbolOf(p);
        if (place.sym) |id| place.root = rootOf(self, self.ctx.symbols.items[id]);
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
pub fn rootOf(self: *Checker, sym: sema.Symbol) Checker.Root {
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

/// Whether a write view of `place` is the marked call of a change
/// through a shared handle: the place is a handle that changes by a
/// marked call (the handle is viewed, not rebound), or a Cell, a
/// Signal, or a value that holds a Cell, reached through a handle
/// with no read view between it and the handle.
pub fn viewsMarked(self: *Checker, place: Checker.Place) bool {
    const ty = self.ctx.typeOf(place.node) orelse return false;
    return sema.changesByMark(self.ctx, ty) and !place.leaf_blocked;
}

/// Whether a write view of `place` writes none of what holds the
/// handle it reaches: it is a handle that changes by a marked call, or
/// a Cell, Signal, or value holding a Cell reached through one.
pub fn viewsPath(self: *Checker, place: Checker.Place) bool {
    return viewsHandle(self, place) or (place.crossed and viewsMarked(self, place));
}

/// Whether the handle `place` names may be written where it stands,
/// so that a view of it may be the handle's own: `requireAccess` with
/// no exemption for a handle that changes by a marked call.
pub fn handleWritable(self: *Checker, place: Checker.Place, operand: Sexp) Error!bool {
    const saved = self.expect.handle_exempt;
    self.expect.handle_exempt = false;
    defer self.expect.handle_exempt = saved;
    const m = FlowCheck.beginQuiet(self);
    const writable = try requireAccess(self, place, .write_viewed, operand);
    _ = try FlowCheck.endQuiet(self, m);
    return writable;
}

/// Whether `place` is a handle that changes by a marked call
/// (`sema.changesByMark`), which `!` views without writing the handle.
pub fn viewsHandle(self: *Checker, place: Checker.Place) bool {
    const ty = self.ctx.typeOf(place.node) orelse return false;
    return !place.view_blocked and self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .shared and sema.changesByMark(self.ctx, ty);
}

/// Whether `place` may be used as `access` asks. Nothing is written
/// through a `*T` or a `?T`, or into an element of a `[]T` or a
/// `?String`, or a `.len`; a temporary would lose the change; and
/// without a view or handle on the way, the binding the path starts
/// from must be one that may change (`requireBinding`). A diagnostic
/// with no better position is at `at`. False after a diagnostic.
pub fn requireAccess(self: *Checker, place_in: Checker.Place, access: Checker.Access, at: Sexp) Error!bool {
    if (!self.expect.trial_take) try recordTableWrites(self, place_in.node);
    // A write view or a write iteration of a place that holds a read
    // view goes through that view, as a step across one does.
    var place = place_in;
    if (access == .write_viewed or access == .write_iterate) if (place.holds_view) |pos| {
        place.block(.read_view, pos);
        place.leaf_blocked = true;
        place.view_blocked = true;
    };
    const verb = access.verb();
    // No write view is made through a read view, a Cell or a
    // Signal behind a handle it views or reaches included (SPEC §10,
    // "Cell"): the read view, not the handle, says why.
    if (access == .write_viewed and place.crossed) if (place.view) |v| {
        const hint = try PatternCheck.readMatchHint(self, place.sym);
        try self.err(v.pos, "cannot make a write view through a read view `{s}`{s}", .{ try self.tyName(v.ty), if (hint.len > 0) hint else "; take a write view, or share a handle of your own with `+h`" });
        return false;
    };
    if (place.blocked) |b| {
        const through: Checker.Verb = switch (access) {
            .assign => .{ .head = "assign" },
            .write_viewed => .{ .head = "make a write view" },
            else => verb,
        };
        // A handle that changes by a marked call is viewed, wherever
        // it is held: the view writes neither the slice nor the view
        // that holds the handle, nor what it reaches.
        if (access == .write_viewed and self.expect.handle_exempt and viewsHandle(self, place)) return true;
        switch (b.why) {
            // A Cell or a Signal changes through the handle by a
            // marked call, a write view.
            .shared, .read_view => if (access == .write_viewed and (self.expect.handle_exempt or !viewsHandle(self, place)) and viewsMarked(self, place)) {
                return true;
            } else if (b.why == .read_view) {
                const hint = try PatternCheck.readMatchHint(self, place.sym);
                if (hint.len > 0) {
                    try self.err(b.pos, "cannot {s}{s} through a read view (`?T`){s}", .{ through.head, through.tail, hint });
                } else try self.err(b.pos, "cannot {s}{s} through a read view (`?T`); take a write view (`!T`) to mutate", .{ through.head, through.tail });
            } else if (access == .assign and place.cell_list_elem != null and place.marked) {
                return true;
            } else if (access == .assign and place.cell_list_elem != null) {
                const cell = ir.get(place.cell_list_elem.?, .object);
                try self.errAt(at, "write `(!{s})[i] = e`: changing a shared Cell is marked with `!`", .{try ViewCheck.plainText(self, cell)});
            } else if (access == .assign and CompatCheck.cellElementType(self.ctx, self.ctx.typeOf(place.node) orelse sema.type_invalid) != null) {
                const shown = try ViewCheck.plainText(self, place.node);
                try self.errAt(at, "cannot assign through a shared handle (`*T`); other handles may exist. `{s}` is a Cell: change its value with `!{s}.set(...)`", .{ shown, shown });
            } else try self.errAt(at, "cannot {s}{s} through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.", .{ through.head, through.tail }),
            .slice => try self.err(b.pos, "cannot {s}{s} through a slice; a `[]T` is read-only{s}", .{ through.head, through.tail, try PatternCheck.readMatchHint(self, place.sym) }),
            .string => try self.err(b.pos, "cannot {s} a byte of a `?String`{s}; a `?String` is read-only", .{ verb.head, verb.tail }),
            .len => try self.err(b.pos, "cannot {s} `.len`{s}; a length is read-only", .{ verb.head, verb.tail }),
            .text => try self.err(b.pos, "cannot {s} `.text`{s}; a variant's name is read-only", .{ verb.head, verb.tail }),
            .symbol_text => try self.err(b.pos, "cannot {s} `.text`{s}; a symbol's name is read-only", .{ verb.head, verb.tail }),
            .none_field => {
                const obj_ty = sema.unwrapViews(self.ctx, self.ctx.typeOf(ir.get(place.node, .object)) orelse sema.type_invalid);
                try self.err(b.pos, "cannot {s} `{s}`{s}: `{s}` names the none of `{s}` (`none {s} == ...`), so only its constructor sets it; make a new `{s}`", .{ verb.head, try ViewCheck.plainText(self, place.node), verb.tail, self.text(ir.Member.name(place.node)), try self.tyName(obj_ty), self.text(ir.Member.name(place.node)), try self.tyName(obj_ty) });
            },
            .read_only => {
                const f = place.read_only.?;
                try self.err(b.pos, "cannot {s} `{s}`{s}: field `{s}` of `{s}` is read-only {s}", .{ verb.head, try ViewCheck.plainText(self, place.node), verb.tail, f.field, f.owner, try GenericCheck.readOnlyWhere(self.ctx, f, true) });
            },
        }
        return false;
    }
    if (place.root == .temporary) {
        switch (access) {
            // `!` makes a write view of any value: the temporary is
            // held in its statement's slot (`checkWriteView`).
            .write_viewed => return true,
            .assign => try self.errAt(at, "cannot assign to a field or element of a temporary; bind the value first (`t = ...`), then assign to `t`", .{}),
            .take => try self.errAt(at, "cannot take out of a temporary: nothing would see it emptied; bind it to a name first", .{}),
            else => try self.errAt(at, "cannot {s}{s} a temporary; bind it to a name first", .{ access.verb().head, access.verb().tail }),
        }
        return false;
    }
    if (place.indirect) return true;
    // A handle that changes by a marked call is viewed, not rebound,
    // so the binding that holds it need not be writable.
    if (access == .write_viewed and self.expect.handle_exempt and place.steps == 0 and viewsHandle(self, place)) return true;
    return requireBinding(self, place, access);
}

/// Every slot of a table on the path of place `e`, which a write
/// reaches: reached to write (`Facts.table_writes`), where any
/// other slot is reached read-only.
pub fn recordTableWrites(self: *Checker, e: Sexp) Error!void {
    var p = CompatCheck.stripSigil(e);
    while (p.isKind(.member) or p.isKind(.index)) : (p = ir.get(p, .object)) {
        if (!p.isKind(.index)) continue;
        const ty = self.ctx.typeOf(ir.get(p, .object)) orelse continue;
        if (sema.tableElem(self.ctx, sema.unwrapReadAccess(self.ctx, ty)) != null) try self.ctx.record(.table_writes, p, {});
    }
}

/// Whether the binding `place` starts from may be written: a
/// parameter or capture only when it is a `!T`; a fixed binding or
/// constant never; a loop or pattern binding only when it holds a
/// write view of a place it may write, or owns a resource moved
/// into it, and never when assigned whole. (Reassigning a fixed
/// binding is the ownership checker's to report.) False after a
/// diagnostic.
pub fn requireBinding(self: *Checker, place: Checker.Place, access: Checker.Access) Error!bool {
    const id = place.sym orelse return true;
    const sym = self.ctx.symbols.items[id];
    const name = sym.name;
    const root = place.root;
    const verb = access.verb();
    const pos = place.pos;
    // Another module's bindings are its constants. (Their types are
    // in that module's store.)
    if (root == .module) {
        const leaf = self.text(ir.Member.name(place.module_member orelse return true));
        const foreign = CallCheck.foreignLookup(self, id, leaf) orelse return true;
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
            if (std.mem.eql(u8, name, "@")) {
                try self.err(pos, "cannot {s} `@`{s}; a method changes self only when it takes `!@`, which writes through to the caller", .{ verb.head, verb.tail });
            } else if (sym.flags.group) {
                // A group as written: it stays so, and this is said
                // again by every check (`rig.GroupSite`).
                try self.err(pos, "cannot {s} group `{s}`{s}: parameters are immutable (bind a copy with `new copy = {s}`)", .{ verb.head, name, verb.tail, name });
                try self.refused.put(self.ctx.allocator, sym.decl_pos, {});
            } else if (sym.flags.group_field) {
                // A group's field, read through its group as written.
                const group = self.ctx.group_fields.get(id) orelse "";
                try self.err(pos, "cannot {s} `{s}.{s}`{s}; group `{s}` is a parameter, and parameters are immutable (bind a copy with `new copy = {s}`)", .{ verb.head, group, name, verb.tail, group, group });
            } else try self.err(pos, "cannot {s} parameter `{s}`{s}; parameters are immutable (bind a copy with `new {s} = {s}`, or take `{s}: !{s}` to write through to the caller)", .{ verb.head, name, verb.tail, name, name, name, try self.tyName(sema.unwrapViews(self.ctx, sym.ty)) });
            return false;
        },
        // A captured write view is passed on, as a `!T` parameter is.
        .capture => if (!writes and !poison) {
            try self.err(pos, "cannot {s} captured `{s}`{s}; captures are fixed when the closure is created", .{ verb.head, name, verb.tail });
            return false;
        },
        // A fixed write view is passed on and written through, never
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
            const shown = try ViewCheck.plainText(self, from.place);
            try self.err(pos, "cannot {s} `{s}`{s}: `match {s}{s}` reads `{s}`, and so do its bindings; to write through `{s}`, {s}", .{ verb.head, name, verb.tail, if (from.kind == .match_read) "?" else "", shown, shown, name, try PatternCheck.writeMatchAdvice(self, from.place) });
            return false;
        },
        .pattern => if (!poison) {
            // An `as` or `match <x` binding of a value that moves,
            // moved into it, is not a copy: its fields can be written
            // and taken.
            const owned = sym.flags.as_bound or self.owned_bindings.contains(id);
            if (!whole and owned and sema.moves(self.ctx, sym.ty) == .yes) return true;
            if (self.copied_from.get(id)) |from| {
                const shown = try ViewCheck.plainText(self, from.place);
                switch (from.kind) {
                    .loop => try self.err(pos, "cannot {s} `{s}`{s}: it is a copy of an element of `{s}`; to change the elements in place, loop with `for {s} in !{s}`", .{ verb.head, name, verb.tail, shown, name, shown }),
                    .as => try self.err(pos, "cannot {s} `{s}`{s}: it is a copy of the value inside `{s}`; to change that value in place, bind it with `!{s} as {s}`", .{ verb.head, name, verb.tail, shown, shown, name }),
                    .match_copy, .match_read => try self.err(pos, "cannot {s} `{s}`{s}: it is {s} of {s}`{s}`; to change {s} in place, {s}", .{ verb.head, name, verb.tail, if (from.kind == .match_copy and sema.moves(self.ctx, sym.ty) != .yes and self.ctx.types.get(sym.ty) != .read_view) "a copy" else "a read view", if (from.whole) "" else "a field of ", shown, if (from.whole) "it" else "the field", if (from.pattern != .nil) try self.ctx.arena.allocator().print("test it with `!{s} matches {s}`", .{ shown, try ViewCheck.plainText(self, from.pattern) }) else try PatternCheck.writeMatchAdvice(self, from.place) }),
                }
                return false;
            }
            // A value that may move (a type parameter's) moves into
            // the new binding.
            if (sema.moves(self.ctx, sym.ty) != .no) {
                try self.err(pos, "cannot {s} `{s}`{s}; loop and pattern bindings are immutable (move it into a new binding with `new {s} = <{s}`)", .{ verb.head, name, verb.tail, name, name });
            } else try self.err(pos, "cannot {s} `{s}`{s}; loop and pattern bindings are immutable (bind a copy with `new {s} = {s}`)", .{ verb.head, name, verb.tail, name, name });
            return false;
        },
        else => {},
    }
    return true;
}
