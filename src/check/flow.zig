//! Typecheck's control flow: conditions and their bindings, `if`,
//! `while`, `for` (a `for` over an iterator checked as the `while` it
//! means), loops as values, and jumps.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const resolve = @import("../resolve.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const TypeId = sema.TypeId;
const Error = std.mem.Allocator.Error;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CompatCheck = @import("compat.zig");
const BuiltinCheck = @import("builtins.zig");
const CallCheck = @import("calls.zig");
const ExprCheck = @import("expr.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// Synthesize without reporting diagnostics (the full check reports them).
pub fn synthQuiet(self: *Checker, e: Sexp) Error!TypeId {
    const mark = self.ctx.diagnostics.items.len;
    self.ctx.quiet += 1;
    defer self.ctx.quiet -= 1;
    const ty = try PatternCheck.synthExpr(self, e);
    self.ctx.diagnostics.shrinkRetainingCapacity(mark);
    return ty;
}

/// Returns the if's type in value position.
pub fn checkIfValue(self: *Checker, node: Sexp, expected: ?TypeId, position: Checker.Position) Error!TypeId {
    const cond = ir.If.cond(node);
    const then_node = ir.If.then(node);
    const else_node = ir.If.@"else"(node);

    const prev = self.scope;
    // A ternary or a postfix guard has no block to hold what its
    // condition makes.
    const saved_hold = self.expect.no_hold;
    self.expect.no_hold = saved_hold or position == .value;
    const saved_cond = self.expect.ternary_cond;
    if (position == .value) self.expect.ternary_cond = cond;
    // An `if`, an `else if`, or a statement's guard narrows what it runs
    // (`plainTest`); a ternary does not.
    const saved_plain = self.expect.plain_cond;
    defer self.expect.plain_cond = saved_plain;
    self.expect.plain_cond = if (isBlockIf(self, node) or (position == .statement and else_node == .nil)) try BuiltinCheck.plainCondOf(self, cond, &.{then_node}) else null;
    // A ternary's names reach the value before `if`, as a block's
    // reach the block; a postfix guard, which has no `else`, binds
    // none.
    if (position == .statement and else_node == .nil and !isBlockIf(self, node) and rig.bindsInCondition(cond)) {
        try self.errAt(cond, "a postfix guard's condition binds no names; write an `if` block", .{});
    }
    try checkCondition(self, cond);
    self.expect.plain_cond = saved_plain;
    self.expect.ternary_cond = saved_cond;
    self.expect.no_hold = saved_hold;
    const then_ty = try branch(self, then_node, expected, position);
    self.scope = prev;

    if (position == .statement) {
        if (else_node != .nil) _ = try elseBranch(self, cond, else_node, expected, position);
        return self.t().void_id;
    }
    if (else_node == .nil) {
        try self.errAt(then_node, "`if` used as a value requires an `else` branch", .{});
        return self.t().invalid_id;
    }
    const else_ty = try elseBranch(self, cond, else_node, expected, position);
    if (expected) |e| return e;
    const u = (try BuiltinCheck.unify(self, then_ty, else_ty, self.startOf(else_node))) orelse return self.t().invalid_id;
    // All-literal branches take their type from the context later.
    if (u == self.t().int_literal_id or u == self.t().float_literal_id) return u;
    try adaptLiteral(self, then_node, then_ty, u);
    try adaptLiteral(self, else_node, else_ty, u);
    return u;
}

/// A branch or element whose value is a literal (`int_literal`) takes
/// the type the others settled on, and must fit it.
pub fn adaptLiteral(self: *Checker, node: Sexp, ty: TypeId, target: TypeId) Error!void {
    var value = node;
    while (value.isKind(.block) and ir.Block.stmts(value).len > 0) {
        const stmts = ir.Block.stmts(value);
        value = stmts[stmts.len - 1];
    }
    // All-literal branches still yield an `Int` (or `Float`).
    try ViewCheck.recordAdapted(self, value, ty, ExprCheck.canonical(self, target));
}

/// The `else` of an `if` whose condition is `cond`.
pub fn elseBranch(self: *Checker, cond: Sexp, node: Sexp, expected: ?TypeId, position: Checker.Position) Error!TypeId {
    const binds = rig.bindsInCondition(cond);
    if (binds) try self.else_conds.append(self.ctx.allocator, cond);
    defer if (binds) {
        _ = self.else_conds.pop();
    };
    return branch(self, node, expected, position);
}

/// Whether the binding condition `cond` binds `name`.
pub fn conditionBinds(self: *Checker, cond: Sexp, name: []const u8) Error!bool {
    for (try guardParts(self, cond)) |p| {
        const names: []const Sexp = switch (p.kind() orelse continue) {
            .as => (&ir.As.name(p))[0..1],
            .as_results => ir.AsResults.names(p).items(),
            .as_match => self.ctx.armPayloadBindings(ir.Arm.pattern(rig.asMatchArm(p))),
            else => continue,
        };
        for (names) |n| {
            const leaf = if (n.isKind(.set)) ir.Set.target(n) else n;
            if (leaf == .src and std.mem.eql(u8, self.text(leaf), name)) return true;
        }
    }
    return false;
}

pub fn branch(self: *Checker, node: Sexp, expected: ?TypeId, position: Checker.Position) Error!TypeId {
    if (position == .statement) {
        try StmtCheck.checkStmt(self, node);
        return self.t().void_id;
    }
    if (expected) |e| {
        try ViewCheck.checkExpr(self, node, e);
        return e;
    }
    return PatternCheck.synthExpr(self, node);
}

/// A Bool condition, or one that binds (`rig.bindsInCondition`): its
/// parts in order, each `(as expr name)` entering the scope that
/// binds `name`; the caller restores the scope.
pub fn checkCondition(self: *Checker, cond: Sexp) Error!void {
    const saved_hold = self.expect.no_hold;
    defer self.expect.no_hold = saved_hold;
    if (rig.isConditionJoin(cond)) self.expect.no_hold = true;
    const Parts = struct {
        c: *Checker,
        pub fn part(v: @This(), p: Sexp) Error!void {
            if (p.isKind(.as)) return checkOptionalBinding(v.c, p);
            if (p.isKind(.as_results)) return checkResultsBinding(v.c, p);
            if (p.isKind(.as_match)) return checkAsMatch(v.c, p);
            return ViewCheck.checkExpr(v.c, p, v.c.t().bool_id);
        }
        pub fn join(v: @This(), j: Sexp) Error!void {
            return v.c.ctx.recordType(j, v.c.t().bool_id);
        }
    };
    try rig.eachGuardPart(cond, Parts{ .c = self });
}

/// The guard parts of a condition (`rig.eachGuardPart`), in order.
pub fn guardParts(self: *Checker, cond: Sexp) Error![]const Sexp {
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
pub fn checkStepUses(self: *Checker, cond: Sexp, step: Sexp) Error!void {
    for (try guardParts(self, cond)) |p| {
        // The results `as` binds live only in the body.
        if (p.isKind(.as_results)) for (ir.AsResults.names(p).items()) |n| {
            if (!n.isKind(.set)) continue;
            const b = self.ctx.symbolOf(ir.Set.target(n)) orelse continue;
            const use = sema.findUse(self.ctx, step, b) orelse continue;
            try self.errAt(use, "the loop step cannot use `{s}`, a result the condition binds, which lives only in the body; use it at the end of the body instead", .{self.ctx.symbols.items[b].name});
        };
        // The fields a pattern binds live only in the body.
        if (p.isKind(.as_match)) {
            const pattern = ir.Arm.pattern(rig.asMatchArm(p));
            for (self.ctx.armPayloadBindings(pattern)) |n| {
                const b = self.ctx.symbolOf(n) orelse continue;
                const use = sema.findUse(self.ctx, step, b) orelse continue;
                try self.errAt(use, "the loop step cannot use `{s}`, a field the pattern binds, which lives only in the body; use it at the end of the body instead", .{self.ctx.symbols.items[b].name});
            }
            continue;
        }
        if (!p.isKind(.as)) continue;
        const b = self.ctx.symbolOf(ir.As.name(p)) orelse continue;
        const sym = self.ctx.symbols.items[b];
        const use = sema.findUse(self.ctx, step, b) orelse continue;
        if (sema.isReadOrWriteView(self.ctx, sym.ty)) {
            try self.errAt(use, "the loop step cannot use `{s}`: it is a view (`{s}`) that lives only in the body; use it at the end of the body instead", .{ sym.name, try self.tyName(sym.ty) });
        } else if (try ViewCheck.mustTake(self, sym.ty, self.startOf(use), "uses in a loop step a binding")) {
            try self.errAt(use, "the loop step cannot use `{s}`: the body owns this `{s}`, which ends with the body before the step runs", .{ sym.name, try self.tyName(sym.ty) });
        }
    }
}

/// A step that reads a binding of the condition runs inside the `if`s
/// that bind it, after the body (`storage.StepPoint.after_body`,
/// docs/internals/INTERNALS.md, "Loops"), so every binding there stays until the
/// step is done: each must be plain data (neither a view nor owning),
/// and no `continue` in the condition, which would go on past the
/// step (`resolveJump`), may skip binding one.
pub fn checkStepBindings(self: *Checker, frame: *const Checker.LoopFrame, loop: Sexp) Error!void {
    if (storage.stepPoint(self.ctx, loop) != .after_body) return;
    const step = ir.While.step(loop);
    const parts = try guardParts(self, ir.While.cond(loop));
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
pub fn isBlockIf(self: *Checker, node: Sexp) bool {
    // Without the Parser wrapper's spans, every `if` is taken for a
    // block.
    if (self.ctx.parser == null) return true;
    const at = self.ctx.span(node).start;
    const src = self.ctx.source;
    if (!std.mem.startsWith(u8, src[at..], "if")) return false;
    return at + 2 >= src.len or !(std.ascii.isAlphanumeric(src[at + 2]) or src[at + 2] == '_');
}

/// Whether the call on `recv`, returning `returns`, has a value that
/// is used: a task, whose value is always used, or a call anywhere
/// but a statement, alone or under `!`, `?`, or `catch`
/// (`isDiscardedCall`). Such a write call whose value is a `Bool`
/// is written `(!s).m(...)`, so its `!` never reads as negation
/// (`parenthesized`).
pub fn usesValue(self: *Checker, recv: Sexp, returns: TypeId) bool {
    if (self.expect.current_call) |c| if (ir.Call.task(c) != .nil) {
        const callee = ir.Call.callee(c);
        if (callee.isKind(.member) and CompatCheck.sameNode(ir.Member.object(callee), recv)) return true;
    };
    const result = self.ctx.types.get(returns);
    const value = if (result == .fallible) result.fallible.ok else returns;
    return value != self.t().void_id and !isDiscardedCall(self, recv);
}

/// Whether `ty`, a call's result, is a `Bool`, or a `Bool` that may
/// fail: the value a condition, `not`, `catch`, or `!` takes as one.
pub fn isBoolResult(self: *Checker, ty: TypeId) bool {
    const value = switch (self.ctx.types.get(ty)) {
        .fallible => |f| f.ok,
        else => ty,
    };
    return value == self.t().bool_id;
}

/// Whether a write call on `recv`, returning `returns`, is written
/// `(!s).m(...)`: its value is used (`usesValue`) and is a `Bool`
/// (`isBoolResult`), so its `!` never reads as `not`.
pub fn parenthesized(self: *Checker, recv: Sexp, returns: TypeId) bool {
    return isBoolResult(self, returns) and usesValue(self, recv, returns);
}

/// The whole write call a hint writes for `method` on `recv`, as
/// written but for its self: `!v.push(1)`, or `(!s).add(k)` where
/// its `Bool` value is used (`parenthesized`).
pub fn writeCallText(self: *Checker, recv: Sexp, method: []const u8, returns: TypeId) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const bare = ViewCheck.selfPlace(recv);
    const place = try ViewCheck.plainText(self, bare);
    const viewed = if (ViewCheck.sigilReaches(bare)) try a.print("!{s}", .{place}) else try a.print("!({s})", .{place});
    return callWith(self, recv, if (parenthesized(self, recv, returns)) try a.print("({s})", .{viewed}) else viewed, method);
}

/// The call being checked (`current_call`), written with its
/// self `recv` (with any sigil before it) as `with`: `<c.take()`
/// for `c.take()`. Without that call, `with.method(...)`.
pub fn callWith(self: *Checker, recv: Sexp, with: []const u8, method: []const u8) Error![]const u8 {
    if (self.expect.current_call) |c| {
        const callee = ir.Call.callee(c);
        if (callee.isKind(.member) and CompatCheck.sameSite(ir.Member.object(callee), recv)) {
            // A self written in parentheses, `(mk() if c else
            // d).m()`: `with` takes their place.
            const call = self.ctx.span(c);
            const r = self.ctx.span(recv);
            const src = self.ctx.source;
            if (r.start > call.start and r.end + 1 < call.end and src[r.start - 1] == '(' and src[r.end] == ')' and src[r.end + 1] == '.') {
                return std.mem.concat(self.ctx.arena.allocator(), u8, &.{ src[call.start .. r.start - 1], with, src[r.end + 1 .. call.end] });
            }
            return ViewCheck.spliced(self, c, &.{recv}, &.{with});
        }
    }
    return self.ctx.arena.allocator().print("{s}.{s}(...)", .{ with, method });
}

/// Whether `recv` is the self of a call whose value is
/// discarded: the expression statement, or the value of `_ =`, or the
/// operand of a `!`, `?`, or `catch` that is, or is that operand in
/// turn.
pub fn isDiscardedCall(self: *const Checker, recv: Sexp) bool {
    var e = self.expect.discarded;
    while (true) switch (e.kind() orelse return false) {
        .propagate => e = ir.Propagate.value(e),
        .propagate_none => e = ir.PropagateNone.value(e),
        .@"catch" => e = ir.Catch.value(e),
        .call => {
            const callee = ir.Call.callee(e);
            return callee.isKind(.member) and CompatCheck.sameExpr(ir.Member.object(callee), recv);
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
pub fn checkOptionalBinding(self: *Checker, node: Sexp) Error!void {
    const expr = ir.As.value(node);
    const name = ir.As.name(node);
    // The header binds the value inside: it takes the optional.
    try ViewCheck.recordUse(self, expr, .take);
    // A part of a value made here is bound in that value, which the
    // `if` holds (`Header.held`).
    const saved_held = self.expect.held_base;
    defer self.expect.held_base = saved_held;
    if (!self.expect.no_hold) self.expect.held_base = PatternCheck.madeBase(self, expr);
    const saved_as = self.expect.as_call;
    self.expect.as_call = CompatCheck.resultCall(expr) orelse .nil;
    const ty = try PatternCheck.synthExpr(self, expr);
    self.expect.as_call = saved_as;
    var inner = self.t().invalid_id;
    if (!self.isPoison(ty)) switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
        .optional => |i| inner = i,
        else => try self.errAt(expr, "`as` binds the value inside an optional; this expression has type `{s}`", .{try self.tyName(ty)}),
    };
    const through_view = sema.unwrapViews(self.ctx, ty) != ty;
    // A branch the header reads where it stands is viewed there.
    if (!self.isPoison(inner) and !try PatternCheck.headerViewsBranch(self, PatternCheck.headerSubject(expr))) inner = self.t().invalid_id;
    // How the binding reaches the value inside, from which its access
    // and type follow (`bindAsView`).
    var reach: sema.AsReach = .copied;
    if (through_view and !self.isPoison(inner) and !sema.isReadOrWriteView(self.ctx, inner)) {
        // `!o`, or a fresh write view (a call's result, `<w`).
        const writes = self.ctx.types.get(ty) == .write_view;
        if (try sema.makesWriteView(self.ctx, expr)) {
            reach = .written;
        } else if (!writes and sema.copies(self.ctx, inner) == .depends) {
            // A type parameter's value, which may own, is viewed where
            // it is in every instance, as an element `for` reads is.
            reach = .read;
        } else if (try ViewCheck.cannotCopy(self, inner, self.startOf(expr), "moves out of a view a value")) {
            if (writes) {
                // A held write view is passed on visibly, as `!o`; one a
                // temporary of the header holds ends with the header.
                if (sema.firstStmtTemp(self.ctx, expr)) |temp| {
                    try self.errAt(expr, "`as` over a write view in a header that makes a temporary, `{s}`, which ends with the header: bind it to a name first, then make a write view of the value inside with `!`", .{CallCheck.sourceText(self, temp)});
                } else try self.errAt(expr, "`as` over a write view passes it on: write `!{s}` to make a write view of the value inside", .{CallCheck.sourceText(self, expr)});
                try self.ctx.recordType(expr, self.t().invalid_id);
                inner = self.t().invalid_id;
            } else reach = .read;
        } else _ = try ViewCheck.reachThrough(self, expr, ty, sema.unwrapViews(self.ctx, ty));
    } else {
        _ = try ViewCheck.reachThrough(self, expr, ty, sema.unwrapViews(self.ctx, ty));
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
    // holds that value (docs/internals/INTERNALS.md, "Header subjects").
    var viewed = false;
    if (!through_view and !self.isPoison(inner) and sema.copies(self.ctx, inner) == .no) switch (ViewCheck.hands(self, expr).kind) {
        .place => {
            viewed = true;
            try self.ctx.recordHeader(node, .viewed, .nil);
            try self.ctx.record(.uses, expr, .view);
        },
        .part_of_made => if (self.expect.held_base != .nil) {
            if (try PatternCheck.holdsHeld(self, expr)) {
                viewed = true;
                try self.ctx.recordHeader(node, .held, self.expect.held_base);
            } else inner = self.t().invalid_id;
        } else {
            try self.errAt(expr, "`as` binds the value inside a place or takes one made here: bind this `{s}` to a name first", .{try self.tyName(ty)});
            inner = self.t().invalid_id;
        },
        .made, .view, .branches, .jump, .none => {},
    };
    // A part of plain data is read in the header, as any value is.
    if (!viewed and self.expect.held_base != .nil) try PatternCheck.releaseHeld(self);
    if (viewed) reach = .read;
    // What the binding views, unless it owns a value made here or
    // taken with `<`, may be a copy (`rejectHeaderCopy`).
    const owns = expr.isKind(.move) or (ViewCheck.hands(self, expr).kind == .made and !through_view);
    if (reach == .copied and owns) reach = .taken;
    const access = PatternCheck.asAccess(self, reach, inner);
    inner = try PatternCheck.viewOfAccess(self, access, inner);
    if (!owns and !self.isPoison(inner)) try PatternCheck.rejectHeaderCopy(self, node, expr, inner);
    _ = self.enter(node);
    if (self.ctx.symbolOf(name)) |sym| {
        (try self.ctx.symbolMut(sym)).access = access;
        (try self.ctx.symbolMut(sym)).flags.access_decided = true;
        (try self.ctx.symbolMut(sym)).ty = inner;
        // A read binding of a place's value, which `if !o as x` writes.
        if (access == .read and viewed) try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = expr, .kind = .as });
        try self.ctx.recordType(name, inner);
        if (!through_view and !viewed and ViewCheck.hands(self, expr).hasStorage()) try self.copied_from.put(self.ctx.allocator, sym, .{ .place = expr, .kind = .as });
    }
}

/// `s matches .circle(r)` in a condition: the one-arm `match` it is
/// (`checkMatchIn`), whose names the rest of the condition and the
/// body see.
pub fn checkAsMatch(self: *Checker, part: Sexp) Error!void {
    _ = try PatternCheck.checkMatchIn(self, rig.asMatchOf(part), .statement, null, true);
}

/// `if f() as a, b` / `while f() as a, b`: `f()` gives several
/// results inside an optional, `(A, B)?`, and each name binds one of
/// them, taken, as a destructure's target does (`checkDestructure`).
pub fn checkResultsBinding(self: *Checker, node: Sexp) Error!void {
    const value = ir.AsResults.value(node);
    const names = ir.AsResults.names(node).items();
    var ok = try StmtCheck.checkResultTargets(self, names);
    // A header's temporaries end with it, before its body runs, and a
    // result `_` discarded there would drop after them: each result
    // is bound to a name, which the body owns.
    for (names) |n| if (!n.isKind(.set)) {
        try self.errAt(n, "`as` binds each result to a name: name this one, and where the body does not use it, discard it there with `_ = name`", .{});
        ok = false;
    };
    try ViewCheck.recordUse(self, value, .take);
    const saved_ok = self.expect.results_ok;
    defer self.expect.results_ok = saved_ok;
    if (value.isKind(.call)) self.expect.results_ok = value;
    const ty = try PatternCheck.synthExpr(self, value);
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
        try self.errAt(value, "`{s}` gives {d} results, but {d} names are bound", .{ try StdFormCheck.calleeName(self, ir.Call.callee(value)), parts.len, names.len });
        ok = false;
    }
    _ = self.enter(node);
    const saved_part = self.expect.part_ty;
    defer self.expect.part_ty = saved_part;
    for (names, 0..) |n, j| {
        if (!n.isKind(.set)) continue;
        self.expect.part_ty = if (ok and j < parts.len) parts[j] else self.t().invalid_id;
        if (ok) try StmtCheck.checkSet(self, n) else try StmtCheck.poisonTarget(self, n);
    }
}

/// The frame of the loop being entered, which takes the pending label
/// and value.
pub fn enterLoop(self: *Checker, frame: *Checker.LoopFrame, node: Sexp) Error!void {
    frame.* = .{ .label = self.expect.loop_label, .node = node, .value = self.expect.loop_value, .parent = self.body.loops };
    self.expect.loop_label = "";
    self.expect.loop_value = null;
    try enterFrame(self, frame);
}

/// Make `frame` the innermost around the code being checked, and
/// record the jumps that name its construct (`sema.eachJumpTo`).
pub fn enterFrame(self: *Checker, frame: *Checker.LoopFrame) Error!void {
    const Record = struct {
        c: *Checker,
        node: Sexp,
        pub fn jump(r: @This(), j: Sexp) Error!void {
            try r.c.jump_targets.put(r.c.ctx.allocator, CompatCheck.nodeId(j), r.node);
        }
    };
    try sema.eachJumpTo(self.ctx.source, frame.node, frame.label, Record{ .c = self, .node = frame.node });
    self.body.loops = frame;
}

pub fn checkWhile(self: *Checker, node: Sexp) Error!void {
    var frame: Checker.LoopFrame = undefined;
    try enterLoop(self, &frame, node);
    defer frame.cond_continues.deinit(self.ctx.allocator);
    const prev = self.scope;
    const cond = ir.While.cond(node);
    const step = ir.While.step(node);
    frame.has_step = step != .nil;
    frame.part = .cond;
    const saved_hold = self.expect.no_hold;
    self.expect.no_hold = true;
    const saved_plain = self.expect.plain_cond;
    self.expect.plain_cond = try BuiltinCheck.plainCondOf(self, cond, &.{ step, ir.While.body(node) });
    try checkCondition(self, cond);
    self.expect.plain_cond = saved_plain;
    self.expect.no_hold = saved_hold;
    frame.part = .step;
    const call_step = step.isKind(.call) or (step.isKind(.propagate) and ir.Propagate.value(step).isKind(.call));
    if (step != .nil and !step.isKind(.set) and !call_step) {
        try self.errAt(step, "a `while` step is an assignment or a call", .{});
    } else if (step != .nil) {
        try StmtCheck.checkStmt(self, step);
        // The step runs after the body, which would see a name it
        // declares before it has a value.
        if (step.isKind(.set) and ir.Set.target(step) == .src) if (self.ctx.symbolOf(ir.Set.target(step))) |id| {
            const target = ir.Set.target(step);
            if (self.ctx.symbols.items[id].decl_pos == target.src.pos) {
                try self.errAt(target, "a `while` step runs after the body, so it cannot declare `{s}`; declare it before the loop", .{self.text(target)});
            }
        };
        const mark = self.ctx.diagnostics.items.len;
        try checkStepUses(self, cond, step);
        if ((rig.isConditionJoin(cond) or cond.isKind(.as)) and self.ctx.diagnostics.items.len == mark) try checkStepBindings(self, &frame, node);
    }
    try settleConditionJumps(self, &frame);
    frame.part = .body;
    try StmtCheck.checkStmt(self, ir.While.body(node));
    self.scope = prev;
    self.body.loops = frame.parent;
}

pub fn checkFor(self: *Checker, node: Sexp) Error!void {
    var frame: Checker.LoopFrame = undefined;
    try enterLoop(self, &frame, node);
    frame.part = .source;
    var mode = ir.For.mode(node).tag;
    const binding = ir.For.@"var"(node);
    const index_binding = ir.For.index(node);
    const source = ir.For.source(node);

    if (index_binding != .nil and source.isKind(.@"..")) {
        try self.errAt(index_binding, "a range has no index binding; the element is already the position (`for i in a..b`)", .{});
    }

    var elem_ty = self.t().invalid_id;
    self.expect.loop_access = null;
    // The loop's mode once a bare source is classified.
    var eff = mode;
    // A held source was rejected (`holdsHeld`).
    var elem_poisoned = false;
    // A loop over an iterator, checked as the `while` it means.
    var rewrite: ?struct { how: rig.IterSource, mark: sema.Mark } = null;
    if (source.isKind(.@"..")) {
        // Both bounds are integers of one type, the element's.
        elem_ty = try ExprCheck.checkIntDefaultOperands(self, source, if (rig.isInclusive(source)) "..=" else "..", .integer, null);
        try self.ctx.recordType(source, try self.ctx.intern(.{ .range = elem_ty }));
    } else {
        const peeled_source = if (source.isKind(.read)) ir.Read.operand(source) else source;
        // A part of a value made here is walked in that value, which
        // the loop holds (`Header.held`).
        const saved_held = self.expect.held_base;
        defer self.expect.held_base = saved_held;
        if (mode == .iter) self.expect.held_base = PatternCheck.madeBase(self, source);
        // `for x in ?xs[a..b]` walks a slice of `xs`.
        const saved_chain_for = self.expect.chain_for;
        self.expect.chain_for = node;
        defer self.expect.chain_for = saved_chain_for;
        // What checking the source records is taken back when the loop
        // is over an iterator (`elaborateFor`).
        const mark = self.ctx.mark();
        var source_ty = if ((mode == .read or mode == .write) and rig.isRangeIndex(source))
            try ViewCheck.viewSlice(self, source, if (mode == .read) .read else .write)
        else
            try PatternCheck.synthExpr(self, source);
        const iter = try iterLoop(self, node, source, mode, source_ty);
        if (iter == .rewrite and self.ctx.diagnostics.items.len == mark.diagnostics) {
            rewrite = .{ .how = iter.rewrite, .mark = mark };
        } else self.ctx.commit(mark);
        if (iter != .not_iterator) {
            elem_ty = self.t().invalid_id;
        } else {
            // A value made here is walked as its type says: a write
            // view a call gives is walked for writing, as `!xs` walks
            // a place (`for x in (!b).items()`), and the loop's mode
            // says so for every pass after this one.
            if (mode == .iter and self.ctx.types.get(source_ty) == .write_view and ViewCheck.hands(self, source).kind == .made) {
                mode = .write;
                eff = .write;
                @constCast(node.items())[ir.slot(.@"for", .mode)] = .{ .tag = .write };
            }
            // `for x in <e` moves `e` as `<e` does.
            if (mode == .move and !self.isPoison(source_ty)) _ = try ViewCheck.rejectMadeParts(self, source, source);
            // A branch the loop walks where it stands is viewed there,
            // as its mode views it (`for x in ?S`, `for x in !S`) or
            // read.
            if (mode != .move and !self.isPoison(source_ty) and !try PatternCheck.headerViewsBranch(self, .{ .node = peeled_source, .sigil = switch (mode) {
                .read => .read,
                .write => .write,
                else => null,
            } })) {
                // Reported once: the loop has no source to walk.
                source_ty = self.t().invalid_id;
                elem_poisoned = true;
            }
            // How the loop has a bare source (docs/internals/INTERNALS.md, "Header
            // subjects"): a place is walked where it stands, as
            // `for x in ?p`; an array made here whose elements move is
            // taken, as `for x in <e`; a part of a made value is walked
            // where the loop holds that value.
            const source_hands = ViewCheck.hands(self, source);
            if (mode == .iter and !self.isPoison(source_ty)) switch (source_hands.kind) {
                .place => {
                    eff = .read;
                    try self.ctx.recordHeader(node, .viewed, .nil);
                },
                .part_of_made => if (self.expect.held_base != .nil and sema.copies(self.ctx, source_ty) == .no) {
                    eff = .read;
                    if (try PatternCheck.holdsHeld(self, source)) {
                        try self.ctx.recordHeader(node, .held, self.expect.held_base);
                    } else elem_poisoned = true;
                },
                .made => if (self.ctx.types.get(source_ty) == .array and sema.copies(self.ctx, self.ctx.types.get(source_ty).array.elem) == .no) {
                    eff = .move;
                    try self.ctx.recordHeader(node, .taken, .nil);
                },
                .view, .branches, .jump, .none => {},
            };
            // A part of plain data is read in the header, as any value is.
            if (self.expect.held_base != .nil and self.ctx.headerOf(node) != .held and !elem_poisoned) try PatternCheck.releaseHeld(self);
            // A loop walks a place, or takes a value made here. A branching
            // value that may be a name's (`o?`, `a if c else mk()`) may be
            // a place on one path and a new value on another, which one
            // loop cannot both view and take, unless its elements copy.
            const peeled_hands = ViewCheck.hands(self, peeled_source);
            const unbound = (!peeled_hands.hasStorage() and peeled_hands.kind != .made) or (mode == .iter and peeled_hands.kind == .part_of_made and self.expect.held_base == .nil);
            const list = CompatCheck.listElementType(self.ctx, source_ty) != null or sema.tableElem(self.ctx, source_ty) != null;
            const moving = list or switch (self.ctx.types.get(sema.unwrapViews(self.ctx, source_ty))) {
                .array => |a| sema.copies(self.ctx, a.elem) == .no,
                else => false,
            };
            // A List whose elements move is reported by `elementTypeForLoop`.
            const list_moves = if (CompatCheck.listElementType(self.ctx, sema.unwrapViews(self.ctx, source_ty)) orelse sema.tableElem(self.ctx, sema.unwrapViews(self.ctx, source_ty))) |e| sema.moves(self.ctx, e) == .yes else false;
            if (mode != .move and unbound and !list_moves and (if (mode == .iter) moving else list) and !self.isPoison(source_ty)) {
                const what = if (list) "a List held in a place or made by a call" else "a place or takes a value made here";
                try self.errAt(peeled_source, "a `for` walks {s}: bind this `{s}` to a name first", .{ what, try self.tyName(source_ty) });
            }
            self.expect.loop_access = null;
            elem_ty = try elementTypeForLoop(self, source, peeled_source, source_ty, eff);
            if (elem_poisoned) elem_ty = self.t().invalid_id;
            // What the loop binds views the source, unless it takes it or
            // walks a slice of it, and may view a copy (`rejectHeaderCopy`).
            // The source is a header: a temporary it reads into ends with
            // it, before the loop walks it.
            const walks_temp = if (eff != .move and !self.isPoison(elem_ty)) PatternCheck.tempBase(self, source) else null;
            if (walks_temp) |temp| {
                try self.errAt(temp, "the loop would walk the temporary `{s}` after its header drops it; bind it to a name first", .{CallCheck.sourceText(self, temp)});
            } else if (eff != .move and !rig.isRangeIndex(source) and !self.isPoison(source_ty)) try PatternCheck.rejectHeaderCopy(self, node, source, elem_ty);
            // `for x in ?e` and `for x in !e` view `e`: one made here
            // would end with the header. A call's result is taken:
            // `for x in e`. A view a call returns, whose loans name only
            // places, is passed on (`?first(?ls)` is the view
            // `first(?ls)` gives).
            const views_on = sema.isReadOrWriteView(self.ctx, source_ty) and storage.livesIn(self.ctx, source).onlyPlaces();
            if ((mode == .read or mode == .write) and !views_on and !(unbound and list) and !source_hands.hasStorage() and !self.isPoison(source_ty) and !self.isPoison(elem_ty) and sema.moves(self.ctx, sema.unwrapViews(self.ctx, source_ty)) == .yes) {
                try self.errAt(source, "the loop would walk a view of the temporary `{s}` after its header drops it; take it with `for {s} in {s}`, or bind it to a name first", .{ CallCheck.sourceText(self, source), self.text(binding), CallCheck.sourceText(self, source) });
            }
        }
    }
    if (rewrite) |r| {
        self.body.loops = frame.parent;
        self.expect.loop_label = frame.label;
        self.expect.loop_value = frame.value;
        return elaborateFor(self, node, r.how, r.mark);
    }

    {
        const prev = self.enter(node);
        defer self.scope = prev;
        if (self.ctx.symbolOf(binding)) |sym| {
            (try self.ctx.symbolMut(sym)).access = if (self.isPoison(elem_ty)) null else self.expect.loop_access;
            (try self.ctx.symbolMut(sym)).flags.access_decided = true;
            (try self.ctx.symbolMut(sym)).ty = elem_ty;
            try self.ctx.recordType(binding, elem_ty);
            if (sema.forViewsSlot(self.ctx, node)) (try self.ctx.symbolMut(sym)).flags.slot_view = true;
            // An element of an array the loop takes is the body's own.
            if (eff == .move and !source.isKind(.@"..")) try self.owned_bindings.put(self.ctx.allocator, sym, {});
            if ((mode == .iter or mode == .read) and !source.isKind(.@"..") and ViewCheck.hands(self, source).hasStorage() and !sema.isReadOrWriteView(self.ctx, elem_ty)) try self.copied_from.put(self.ctx.allocator, sym, .{ .place = source, .kind = .loop });
        }
        if (self.ctx.symbolOf(index_binding)) |sym| {
            (try self.ctx.symbolMut(sym)).ty = self.t().int_id;
            try self.ctx.recordType(index_binding, self.t().int_id);
            if (self.ctx.symbolOf(binding)) |elem| {
                const pair: Checker.LoopPair = .{ .elem = elem, .index = sym, .source = source };
                try self.loop_pairs.put(self.ctx.allocator, elem, pair);
                try self.loop_pairs.put(self.ctx.allocator, sym, pair);
            }
        }
        frame.part = .body;
        try StmtCheck.checkStmt(self, ir.For.body(node));
    }
    self.body.loops = frame.parent;
}

/// The `for` over an iterator `node`, checked as the `while` it means
/// (docs/internals/INTERNALS.md, "Loops over an iterator"): what
/// checking its source recorded since `mark` is taken back, the tree
/// is rewritten where the loop stands (`rig.Parser.elaborateIterLoop`),
/// the new nodes get their names and scopes (`resolve.resolveIterWhile`),
/// and the statement that stands there now is checked.
pub fn elaborateFor(self: *Checker, node: Sexp, how: rig.IterSource, mark: sema.Mark) Error!void {
    try self.ctx.rollback(mark);
    const p = self.ctx.parser.?;
    const w = (try p.elaborateIterLoop(self.tree, node, how)).?;
    // The rewritten tree stays, inside a check an open mark may take
    // back, and so do the names and scopes of its new nodes.
    const open = self.ctx.pauseTrail();
    try resolve.resolveIterWhile(self.ctx, node, w);
    self.ctx.resumeTrail(open);
    try StmtCheck.checkStmt(self, w.stmt);
}

pub fn iteratorShape(self: *Checker, ty: TypeId) Error!Checker.IterShape {
    return switch (try sema.iterItem(self.ctx, ty)) {
        .not_iterator => .not_iterator,
        .malformed => |why| .{ .malformed = why },
        .item => .iterator,
    };
}

/// What to write for a `for` over an iterator made here. One that
/// holds no view is held by the loop (`for x in mk()`); one that views
/// a place (`b.each()`) keeps it viewed, so it is bound first with the
/// view written, then advanced in place.
pub fn madeIteratorFix(self: *Checker, head: []const u8, shown: []const u8, source_ty: TypeId) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    if (sema.holdsMarkedView(self.ctx, source_ty)) return a.print("it views a place it keeps read-only, so bind it first: `it = ?{s}`, then `{s}!it`", .{ shown, head });
    return a.print("write `{s}{s}`, which holds it for the loop", .{ head, shown });
}

/// A name, or fields from one: the places a loop over an iterator
/// advances where they stand.
pub fn isFieldPath(e: Sexp) bool {
    return e == .src or (e.isKind(.member) and isFieldPath(ir.Member.object(e)));
}

/// Whether a `for` is a loop over an iterator `it`, which is the
/// `while` it means, and how it walks its source.
pub fn iterLoop(self: *Checker, node: Sexp, source: Sexp, mode: Tag, source_ty: TypeId) Error!Checker.IterFor {
    if (self.isPoison(source_ty)) return .not_iterator;
    switch (try iteratorShape(self, source_ty)) {
        .not_iterator => return .not_iterator,
        .malformed => |why| {
            try self.errAt(source, "cannot iterate over `{s}`: a `for` walks a type with `next(!@) -> T?`, but its `next` {s}", .{ try self.tyName(source_ty), why });
            return .rejected;
        },
        .iterator => {},
    }
    const shown = CallCheck.sourceText(self, source);
    const name = self.text(ir.For.@"var"(node));
    // A bare `for xs` hints in its own form: `for !it`, not `for _ in !it`.
    const head = if (self.startOf(ir.For.@"var"(node)) == self.startOf(node))
        "for "
    else
        try self.ctx.arena.allocator().print("for {s} in ", .{name});
    const index = ir.For.index(node);
    if (index != .nil) {
        const bang: []const u8 = if (ViewCheck.hands(self, source).kind == .place) "!" else "";
        try self.errAt(index, "an iterator has no index binding; keep a count in the loop: `for {s} in {s}{s}`", .{ name, bang, shown });
        return .rejected;
    }
    // A place is evaluated again for each `next`, so it is a name or a
    // field path, which names one place however the body runs; an
    // element, whose index the body may change, is bound first.
    const kind = ViewCheck.hands(self, source).kind;
    if (kind == .place and !isFieldPath(source)) {
        try self.errAt(source, "a `for` advances an iterator named by a name or a field path (`it`, `a.b`); bind `{s}` to a name first", .{shown});
        return .rejected;
    }
    const how: rig.IterSource = switch (mode) {
        .read => {
            if (kind == .made) {
                try self.errAt(source, "`{s}?{s}` would only read an iterator made here, which `next` cannot advance; {s}", .{ head, shown, try madeIteratorFix(self, head, shown, source_ty) });
            } else try self.errAt(source, "`{s}?{s}` would only read an iterator, which `next` cannot advance; write `{s}!{s}` to advance it in place", .{ head, shown, head, shown });
            return .rejected;
        },
        .write => if (kind == .place) .place else {
            if (kind == .made) {
                try self.errAt(source, "`!{s}` advances a place, and this is a value made here; {s}", .{ shown, try madeIteratorFix(self, head, shown, source_ty) });
            } else try self.errAt(source, "a `for` walks an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
            return .rejected;
        },
        .move => if (kind == .place) .moved else if (kind == .made) .made else {
            try self.errAt(source, "a `for` takes an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
            return .rejected;
        },
        else => switch (kind) {
            // A bare `for x in it` does not advance a place: the
            // advance is written, `for x in !it`.
            .place => {
                try self.errAt(source, "write `{s}!{s}`: the loop advances `{s}`", .{ head, shown, shown });
                return .rejected;
            },
            .made => .made,
            else => {
                try self.errAt(source, "a `for` walks an iterator that is a place or a value made here; bind `{s}` to a name first", .{shown});
                return .rejected;
            },
        },
    };
    if (self.ctx.parser == null) {
        try self.errAt(source, "a `for` over an iterator needs the module graph, which rewrites it", .{});
        return .rejected;
    }
    return .{ .rewrite = how };
}

/// The hint for a value of the wrong type that is a binding of
/// `for x, i in xs` whose other binding has the type wanted: the loop
/// was likely written index first, as Python's `enumerate` is.
pub fn loopOrderHint(self: *Checker, e: Sexp, wanted: TypeId) Error![]const u8 {
    if (e != .src) return "";
    const sym = self.ctx.symbolOf(e) orelse return "";
    const pair = self.loop_pairs.get(sym) orelse return "";
    const other = if (sym == pair.elem) pair.index else pair.elem;
    const other_ty = self.ctx.symbols.items[other].ty;
    const fits = if (sym == pair.elem) sema.isInteger(self.ctx, wanted) else CompatCheck.compatible(self.ctx, other_ty, wanted);
    if (!fits) return "";
    const elem = self.ctx.symbols.items[pair.elem].name;
    const index = self.ctx.symbols.items[pair.index].name;
    return self.ctx.arena.allocator().print("; `{s}` is the index here: Rig writes the element first, `for {s}, {s} in {s}`", .{ index, index, elem, CallCheck.sourceText(self, pair.source) });
}

/// A `loop` with a `break` that carries a value: its value is used.
/// No other loop gives one (`checkBreak`, `noLoopValue`).
pub fn isValueLoop(self: *Checker, e: Sexp) bool {
    return sema.isLoop(self.ctx.source, e) and sema.hasValueBreaks(self.ctx.source, e);
}

/// A loop where a value is needed whose `break`s carry none: a `for`
/// or a `while`, which gives no value, or a `loop` some plain `break`
/// leaves, each of which is reported (`checkBreak`). Null for
/// anything else, a `loop` no `break` leaves among them.
pub fn noLoopValue(self: *Checker, e: Sexp, expected: ?TypeId) Error!?TypeId {
    if (sema.isLoop(self.ctx.source, e)) {
        if (!sema.breaksOut(self.ctx.source, e, false)) return null;
        return try checkLoopValue(self, e, expected, true);
    }
    const loop = if (e.isKind(.labeled)) ir.Labeled.stmt(e) else e;
    if (!loop.isKind(.@"while") and !loop.isKind(.@"for")) return null;
    try self.errAt(loop, "a `for` or `while` loop gives no value; use `loop` with `break v`, a chain such as `xs.find(f) ?? d`, or `return` from a function", .{});
    try StmtCheck.checkStmt(self, e);
    return self.t().invalid_id;
}

/// A statement that yields no value: a binding, a jump, a loop other
/// than a value loop.
pub fn yieldsNoValue(self: *Checker, e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .set, .@"while", .@"for", .drop, .pass, .rarely, .@"defer", .@"errdefer", .@"return", .@"break", .@"continue", .panic, .labeled => !isValueLoop(self, e),
        else => false,
    };
}

/// A `loop` used as a value: its `break` values meet in one type
/// (`expected`, when the context gives one). It ends only by a jump,
/// so every `break` that leaves it gives its value.
pub fn checkLoopValue(self: *Checker, node: Sexp, expected: ?TypeId, used: bool) Error!TypeId {
    const loop = if (node.isKind(.labeled)) ir.Labeled.stmt(node) else node;
    var lv: Checker.LoopValue = .{ .expected = expected };
    defer lv.values.deinit(self.ctx.allocator);
    if (node.isKind(.labeled)) self.expect.loop_label = self.text(ir.Labeled.label(node));
    self.expect.loop_value = &lv;
    try checkWhile(self, loop);
    const ty = if (expected) |e| e else ExprCheck.canonical(self, lv.ty orelse self.t().invalid_id);
    if (expected == null) for (lv.values.items) |v| try adaptLiteral(self, v.node, v.ty, ty);
    if (used and ty == self.t().void_id) try self.errAt(node, "a loop used as a value cannot yield `Void`", .{});
    try self.ctx.recordType(loop, ty);
    return ty;
}

/// A `break` value of a loop used as a value.
pub fn loopValue(self: *Checker, lv: *Checker.LoopValue, value: Sexp) Error!void {
    // A `break` value leaves the loop: its tail is taken.
    try ViewCheck.recordUse(self, value, .take);
    try ViewCheck.recordUse(self, sema.tailOf(value), .take);
    if (lv.expected) |e| return ViewCheck.checkExpr(self, value, e);
    const ty = try PatternCheck.synthExpr(self, value);
    try lv.values.append(self.ctx.allocator, .{ .node = value, .ty = ty });
    lv.ty = if (lv.ty) |cur| (try BuiltinCheck.unify(self, cur, ty, self.startOf(value))) orelse self.t().invalid_id else ty;
}

/// `(break value? label?)`: a `loop` used as a value takes a value
/// from every `break` that leaves it, and no other `break` carries
/// one.
pub fn checkBreak(self: *Checker, node: Sexp) Error!void {
    const value = ir.Break.value(node);
    const target = try resolveJump(self, node);
    const lv: ?*Checker.LoopValue = if (target) |f| f.value else null;
    if (value == .nil) {
        if (lv != null) try self.errAt(node, "this `break` leaves a loop used as a value; give it the value (`break value`)", .{});
        return;
    }
    if (lv) |v| return loopValue(self, v, value);
    _ = try PatternCheck.synthExpr(self, value);
    if (target) |f| {
        if (f.is_loop) {
            try self.errAt(value, "`break` in a `for` or `while` loop carries no value; give the value with `loop` and `break v`, or assign it to a name declared before the loop and `break`", .{});
        } else try self.errAt(value, "a labeled block has no value; `break ${s}` cannot carry one", .{f.label});
    }
}

/// Where `break` or `continue` `node` goes (`sema.JumpDest`), which
/// emit and the ownership checker read: the construct it names, as
/// recorded when that construct was entered (`sema.eachJumpTo`), and
/// the point of it the part of the loop being checked sends it to. A
/// `continue` from a `while`'s condition is recorded once the step's
/// point is decided (`settleConditionJumps`). Null for a jump that
/// names nothing it can leave, which is reported here.
pub fn resolveJump(self: *Checker, node: Sexp) Error!?*Checker.LoopFrame {
    const brk = node.isKind(.@"break");
    const label = ir.get(node, .label);
    var target = self.body.loops;
    if (self.jump_targets.get(CompatCheck.nodeId(node))) |named| {
        while (target) |f| : (target = f.parent) if (CompatCheck.sameNode(f.node, named)) break;
    } else target = null;
    const word = if (brk) "break" else "continue";
    const f = target orelse {
        const where = if (self.body.in_closure) " (a closure body cannot leave a loop around it)" else "";
        if (label == .nil) {
            try self.errAt(node, "`{s}` is not inside a loop{s}", .{ word, where });
        } else {
            try self.errAt(node, "`{s} ${s}` names no enclosing loop or block{s}", .{ word, self.text(label), where });
        }
        return null;
    };
    if (brk) {
        try self.ctx.record(.jump_dests, node, .{ .target = f.node, .to = .exit });
        return f;
    }
    if (!f.is_loop) {
        try self.errAt(node, "`continue ${s}` names a block, not a loop", .{f.label});
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
    try self.ctx.record(.jump_dests, node, .{ .target = f.node, .to = to });
    return f;
}

/// The `continue`s in the condition of `while` loop `frame`: to the
/// step when it is the loop's continue expression, or else to the
/// head, past a step that reads a binding they would leave unbound
/// (`checkStepBindings` rejects that).
pub fn settleConditionJumps(self: *Checker, frame: *const Checker.LoopFrame) Error!void {
    if (frame.cond_continues.items.len == 0) return;
    const to: sema.JumpDest.To = switch (storage.stepPoint(self.ctx, frame.node)) {
        .continue_expr => .step,
        .after_body => .head,
    };
    for (frame.cond_continues.items) |c| try self.ctx.record(.jump_dests, c, .{ .target = frame.node, .to = to });
}

/// The element of `for x in !xs`: a write view of each slot. The
/// source must be a place the loop may write.
pub fn writeElement(self: *Checker, source: Sexp, inner_source: Sexp, elem: TypeId) Error!TypeId {
    const place = StmtCheck.placeOf(self, inner_source);
    // A write view a call returns, whose loans name only places
    // (`first_mut(!ls)`), is written through where it points.
    if (!place.named() and writeViewOfPlaces(self, inner_source)) return loopElement(self, .write, elem);
    if (!place.named()) {
        try self.errAt(source, "`for x in !xs` writes each element in place; `xs` must be a binding, or a field or element of one", .{});
    } else _ = try StmtCheck.requireAccess(self, place, .write_iterate, source);
    return loopElement(self, .write, elem);
}

/// The type of a loop's element binding, of an element of type
/// `elem` the loop writes, takes, or reads: its access
/// (`sema.decideBindingAccess`, kept in `loop_access` for `checkFor`
/// to record) gives a write view of it, a read view of it, or, with
/// no access, the copy or the element taken.
pub fn loopElement(self: *Checker, mode: sema.LoopMode, elem: TypeId) Error!TypeId {
    if (self.isPoison(elem)) return elem;
    const access = sema.decideBindingAccess(self.ctx, .{ .loop = .{ .mode = mode, .elem = elem } });
    self.expect.loop_access = access;
    return PatternCheck.viewOfAccess(self, access, elem);
}

/// The element of a loop over the List or array `walked` that a
/// shared handle holds (`sema.loopWalks`): `?h` views the value the
/// handle holds, so the loop reads each element where it stands,
/// with the loan on `h`. Nothing is written through a handle, or
/// taken out through one.
pub fn sharedLoopElement(self: *Checker, source: Sexp, inner_source: Sexp, walked: TypeId, mode: ?Tag) Error!TypeId {
    const elem, const what = if (CompatCheck.listElementType(self.ctx, walked)) |e| .{ e, "a List" } else .{ self.ctx.types.get(walked).array.elem, "an array" };
    const pos = self.startOf(source);
    const shown = try ViewCheck.plainText(self, inner_source);
    if (mode == .write) {
        try self.err(pos, "cannot write-iterate through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.", .{});
        return self.t().invalid_id;
    }
    if (mode == .move) {
        try self.err(pos, "`<{s}` would move the elements out of {s} that a shared handle (`*T`) holds; loop over `?{s}`", .{ shown, what, shown });
        return self.t().invalid_id;
    }
    if (!walksPlace(self, inner_source)) {
        try self.err(pos, "a loop through a shared handle walks one that a name holds, or a field or element of one; bind `{s}` to a name first", .{shown});
        return self.t().invalid_id;
    }
    return try loopElement(self, .read, elem);
}

/// Whether `e` is a write view whose loans name only places
/// (`storage.livesIn`): what it points at outlives the statement.
pub fn writeViewOfPlaces(self: *Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return self.ctx.types.get(ty) == .write_view and storage.livesIn(self.ctx, e).onlyPlaces();
}

/// Whether a loop over `source` walks memory that outlives its header,
/// so it reads the elements where they are: a place a name holds, or
/// a field or element of one, or a view whose loans name only places
/// (`storage.livesIn`, CORE §9): `first(?ls)` views `ls`.
pub fn walksPlace(self: *Checker, source: Sexp) bool {
    return StmtCheck.placeOf(self, source).named() or storage.livesIn(self.ctx, source).onlyPlaces();
}

pub fn elementTypeForLoop(self: *Checker, source: Sexp, inner_source: Sexp, source_ty: TypeId, mode: ?Tag) Error!TypeId {
    const pos = self.startOf(source);
    if (self.isPoison(source_ty)) return self.t().invalid_id;
    const walked = sema.loopWalks(self.ctx, source_ty);
    if (walked != sema.unwrapViews(self.ctx, source_ty)) return sharedLoopElement(self, source, inner_source, walked, mode);
    const peeled = sema.unwrapViews(self.ctx, source_ty);
    switch (self.ctx.types.get(peeled)) {
        // A table's pushed slots, `0..len`, read or written in place, as
        // a List's elements are; a loop takes none of them out.
        .parameterized_nominal => if (sema.tableElem(self.ctx, peeled)) |elem| {
            if (mode == .move) {
                const shown = try ViewCheck.plainText(self, inner_source);
                try self.err(pos, "a loop takes no slot out of a table; loop over `?{s}` or `!{s}`", .{ shown, shown });
                return self.t().invalid_id;
            }
            if (sema.moves(self.ctx, elem) == .yes and !walksPlace(self, inner_source)) {
                try self.err(pos, "a loop over a table of `{s}` walks a table that a name holds, or a field or element of one; bind it to a name first", .{try self.tyName(elem)});
                return self.t().invalid_id;
            }
            if (mode == .write) return writeElement(self, source, inner_source, elem);
            return loopElement(self, .read, elem);
        } else if (CompatCheck.listElementType(self.ctx, peeled)) |elem| {
            // Elements that move (handles and boxes) are walked by
            // view; every other element is plain data.
            const is_resource = sema.moves(self.ctx, elem) == .yes;
            if (is_resource) {
                // The one diagnostic for such a loop over any other
                // source; `checkFor` reports nothing more of it.
                if (!walksPlace(self, inner_source)) {
                    // What to bind: the value made here that the
                    // source is, is a part of, or views (`mk()` in
                    // `first(?mk())`, `sema.madeIn`); a branching
                    // source is bound with each name taken
                    // (`<a if c else <b`).
                    const made = sema.madeIn(self.ctx, inner_source) orelse PatternCheck.madeBase(self, inner_source);
                    const bind = if (made != .nil) made else inner_source;
                    const hint = if (ViewCheck.hands(self, bind).kind == .branches) "bind the List to a name first" else try self.ctx.arena.allocator().print("bind `{s}` to a name first", .{CallCheck.sourceText(self, bind)});
                    try self.err(pos, "a loop over a List of `{s}` walks a List that a name holds, or a field or element of one; {s}", .{ try self.tyName(elem), hint });
                    return self.t().invalid_id;
                }
            }
            if (mode == .write) return writeElement(self, source, inner_source, elem);
            // `for x in <v` hands each element over, which only the
            // List's owner can do.
            if (mode == .move) {
                if (peeled == source_ty) return loopElement(self, .take, elem);
                const shown = try ViewCheck.plainText(self, inner_source);
                try self.err(pos, "`<{s}` would move the elements out of a List that `{s}` only views; loop over `?{s}` or `!{s}`, or move the List itself", .{ shown, shown, shown, shown });
                return self.ctx.intern(.{ .read_view = elem });
            }
            return loopElement(self, .read, elem);
        },
        .array => |a| {
            if (mode == .write) return writeElement(self, source, inner_source, a.elem);
            if (mode != .move) return loopElement(self, .read, a.elem);
            return loopElement(self, .take, a.elem);
        },
        .slice, .string_view, .static => {
            if (mode == .write) {
                if (sema.writeSliceElem(self.ctx, source_ty)) |elem| {
                    if (!rig.isRangeIndex(inner_source)) _ = try StmtCheck.requireAccess(self, StmtCheck.placeOf(self, inner_source), .write_iterate, source);
                    return loopElement(self, .write, elem);
                }
                try self.err(pos, "cannot write-iterate a `{s}`; its elements are read-only", .{try self.tyName(source_ty)});
                return self.t().invalid_id;
            }
            return switch (self.ctx.types.get(peeled)) {
                .slice => |sl| try loopElement(self, .read, sl.elem),
                else => try ViewCheck.byteType(self),
            };
        },
        else => {},
    }
    // `for b in ?t` walks the bytes of the `?String` `?t` makes.
    if (mode == .read and CompatCheck.stringOrBoxed(self.ctx, peeled) == self.t().string_id) {
        if (!StmtCheck.placeOf(self, source).named()) try ViewCheck.viewTemp(self, source);
        return ViewCheck.byteType(self);
    }
    const text_hint = if (sema.unwrapViews(self.ctx, source_ty) == self.t().string_id) "; walk a String's bytes through its `?String` view: `for b in ?t`" else "";
    try self.err(pos, "cannot iterate over `{s}`; a `for` source must be a range `a..b`, an array, a `?String`, a `List`, or an iterator (a type with `next(!@) -> T?`){s}", .{ try self.tyName(source_ty), text_hint });
    return self.t().invalid_id;
}

/// The subject of `match` `node`, or of the one-arm `match` an `as`
/// with a pattern is (`rig.asMatchOf`): how the match reaches it, and
/// the type its patterns are checked against. The caller restores
/// `held_base` and `in_place`, which the arms' checks may read.
pub fn checkMatchSubject(self: *Checker, node: Sexp) Error!Checker.MatchSubject {
    const subject = ir.Match.subject(node);
    var mode: tc.MatchMode = if (subject.isKind(.write)) .write else if (subject.isKind(.move)) .consume else .read;
    // `<e` names the value it moves, and a value made here is taken
    // as `<e` would take it. A subject is a header: a temporary it
    // reads ends with it.
    // A part of a value made here is matched in that value, which the
    // match holds (`Header.held`).
    if (mode == .read) self.expect.held_base = PatternCheck.madeBase(self, subject);
    // A header's subject is matched where it stands, which
    // `headerViewsBranch` decides for a branch.
    self.expect.in_place = subject;
    var scrutinee = if (mode == .write) try ViewCheck.synthOperand(self, subject) else try PatternCheck.synthExpr(self, subject);
    const subject_hands = ViewCheck.hands(self, subject);
    if (mode == .read and !self.isPoison(scrutinee)) switch (subject_hands.kind) {
        // A value made here that owns or is unique is the match's
        // own (`sema.moves`); a view it yields, a write view
        // included, stays a view.
        .made => if (try ViewCheck.mustTake(self, scrutinee, self.startOf(subject), "matches")) {
            mode = .consume;
            try self.ctx.recordHeader(node, .taken, .nil);
        },
        // A place is matched where it stands, as `match ?p` would,
        // and a part of a made value that is not plain data where the
        // match holds that value. (A part of plain data is read in the
        // header, and a part of a branching value, which may be a
        // name's part, is checked below as a branching value is.)
        .place, .part_of_made => if (subject_hands.kind == .place or self.expect.held_base != .nil) {
            const reached = sema.unwrapAccess(self.ctx, scrutinee);
            const plain = sema.copies(self.ctx, reached) != .no;
            const held = subject_hands.kind == .part_of_made and !plain;
            if (subject_hands.kind == .part_of_made and plain) try PatternCheck.releaseHeld(self);
            if (!held) try ViewCheck.readLeaf(self, subject);
            const views_inner = reached != sema.unwrapViews(self.ctx, scrutinee);
            if (held and !try PatternCheck.holdsHeld(self, subject)) {
                scrutinee = self.t().invalid_id;
            } else if (held or views_inner or (!plain and !sema.isReadOrWriteView(self.ctx, scrutinee))) {
                try self.ctx.recordHeader(node, if (held) .held else .viewed, if (held) self.expect.held_base else .nil);
                // A box or a handle gives a view of the value it holds:
                // plain data is read as its value, anything else
                // viewed.
                if (plain and views_inner) {
                    scrutinee = reached;
                } else if (!sema.isReadOrWriteView(self.ctx, scrutinee) or views_inner) scrutinee = try self.ctx.intern(.{ .read_view = reached });
            }
        } else try ViewCheck.readLeaf(self, subject),
        .view, .branches, .jump, .none => try ViewCheck.readLeaf(self, subject),
    };
    if (mode == .read and subject.isKind(.read) and !self.isPoison(scrutinee)) {
        // `match ?h` of a handle views the value it holds.
        const reached = sema.unwrapAccess(self.ctx, scrutinee);
        if (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee)) == .shared) scrutinee = try self.ctx.intern(.{ .read_view = reached });
    }
    if (mode == .write and subject.isKind(.write) and !self.isPoison(scrutinee)) {
        // `match !h` of a handle that changes by a marked call makes a
        // write view of the value it holds.
        const reached = sema.unwrapAccess(self.ctx, scrutinee);
        if (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee)) == .shared and sema.changesByMark(self.ctx, reached)) scrutinee = try self.ctx.intern(.{ .write_view = reached });
    }
    // What the arms bind views the subject, unless the match takes it,
    // and may view a copy (`rejectHeaderCopy`).
    // (A view a call returns, held as a pointer, is matched where it
    // points, temporaries or not.)
    const held_view = storage.holdsView(self.ctx, node);
    if (mode != .consume and !held_view and !self.isPoison(scrutinee)) try PatternCheck.rejectHeaderCopy(self, node, subject, sema.unwrapAccess(self.ctx, scrutinee));
    try ViewCheck.recordUse(self, subject, switch (mode) {
        .read => .read,
        .consume => .take,
        .write => .view,
    });
    const scrut_pos = self.startOf(subject);
    // A value that may be a name's, or a part of one, is matched
    // where it is, and one made here is taken: a branching value
    // that may be either is bound to a name first.
    const branching = subject_hands.kind == .branches or (subject_hands.kind == .part_of_made and self.expect.held_base == .nil);
    if (mode == .read and branching and !self.isPoison(scrutinee) and sema.moves(self.ctx, scrutinee) != .no) {
        try self.errAt(subject, "a `match` reads a place or takes a call's result; bind this `{s}` to a name first", .{try self.tyName(scrutinee)});
        scrutinee = self.t().invalid_id;
    }
    // A branch the match reads where it stands is viewed there.
    if (mode != .consume and !self.isPoison(scrutinee) and !try PatternCheck.headerViewsBranch(self, PatternCheck.headerSubject(subject))) scrutinee = self.t().invalid_id;
    // `match <e` takes the fields of a value `e` owns.
    if (subject.isKind(.move)) if (self.ctx.typeOf(ir.Move.operand(subject))) |held| switch (self.ctx.types.get(held)) {
        .read_view, .write_view => {
            const shown = try ViewCheck.plainText(self, ir.Move.operand(subject));
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
            // A box of a read view (`^?E`) reaches its value only to
            // read it.
            .write_view => if (sema.boxedReadView(self.ctx, scrutinee)) |view| {
                try self.errAt(subject, "cannot make a write view through a read view `{s}`, which the box holds; match it with `match {s}` to read it", .{ try self.tyName(view), CallCheck.sourceText(self, if (subject.isKind(.write)) ir.Write.operand(subject) else subject) });
                scrutinee = self.t().invalid_id;
            } else if (sema.accessThroughShared(self.ctx, scrutinee) and !sema.changesByMark(self.ctx, inner)) {
                const shown = CallCheck.sourceText(self, if (subject.isKind(.write)) ir.Write.operand(subject) else subject);
                try self.errAt(subject, "cannot `match !{s}`: the box holds a shared handle (`*T`), and other handles may exist; match it with `match {s}` to read it, and to change a value that handles share, hold it in a `Cell[T]`", .{ shown, shown });
                scrutinee = self.t().invalid_id;
            } else {
                scrutinee = try self.ctx.intern(.{ .write_view = inner });
            },
            else => {
                const place = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                const shown = try ViewCheck.plainText(self, place);
                if (mode == .consume) {
                    try self.errAt(subject, "a `match` reaches the value inside a box through a view of the box: `match ?{s}` or `match !{s}`; to take the value out, bind it first: `v = <{s}.unbox()`", .{ shown, shown, shown });
                    scrutinee = inner;
                } else {
                    try self.errAt(subject, "a `match` reaches the value inside a box through a view of the box: `match ?{s}`", .{shown});
                    scrutinee = self.t().invalid_id;
                }
            },
        }
    };
    if (scrutinee == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, subject);
    // A value of a set parameter is matched as an error of any set.
    scrutinee = try PatternCheck.setParamAsError(self, scrutinee);
    const matchable = CompatCheck.isText(self.ctx, scrutinee) or switch (self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee))) {
        .int, .int_literal, .bool, .symbol, .invalid, .unknown, .any_error => true,
        .nominal, .parameterized_nominal, .imported_nominal => sema.enumVariantCount(self.ctx, scrutinee) != null or sema.isErrorUnion(self.ctx, sema.unwrapViews(self.ctx, scrutinee)),
        else => false,
    };
    return .{ .mode = mode, .scrutinee = scrutinee, .hands = subject_hands, .pos = scrut_pos, .matchable = matchable };
}
