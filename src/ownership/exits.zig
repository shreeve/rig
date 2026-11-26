//! Exits: the one exit primitive every path leaves a scope through
//! (docs/CORE.md section 9), which runs defers, reports the loans it
//! would drop, and rewinds when the path goes on.

const std = @import("std");
const self_check = @import("build_options").self_check;
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const diag = @import("../diag.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const live = @import("live.zig");
const transfer = @import("transfer.zig");
const lowered = @import("lowered.zig");
const lir = @import("../lir.zig");
const rules = @import("rules.zig");
const notes = @import("notes.zig");
const AfterValue = state.AfterValue;
const Checker = state.Checker;
const Loan = state.Loan;
const LoopCtx = state.LoopCtx;
const Point = state.Point;
const State = state.State;
const Value = state.Value;
const VarId = state.VarId;
const containsLoan = state.containsLoan;
const partSetEql = state.partSetEql;
const sameNode = state.sameNode;

/// An exit at which defers run, and so are re-checked (`exitTo`).
pub const Exit = union(enum) {
    /// The innermost scope's end, where the path falls through.
    scope_end,
    /// `break` / `continue`, leaving the scopes at this index and above.
    jump: usize,
    /// `return`; it fails when the value may be an error.
    @"return": bool,
    /// `e!` (which fails) or `e?`: the path that leaves the function.
    propagate: bool,

    /// Whether the path being checked goes on past the exit. Where it
    /// ends, the defers run on it and what they do stays, so a view
    /// one stores is reported where it outlives what it views. Where
    /// it goes on, they run only on a path that leaves there: they are
    /// checked, and their effects undone.
    pub fn goesOn(e: Exit) bool {
        return switch (e) {
            .scope_end, .jump, .@"return" => false,
            .propagate => true,
        };
    }
};

/// Whether `l` holds a place only until a pending operation runs
/// (`Checker.dropPendingHolds`).
pub fn pendingHold(l: Loan) bool {
    return l.kind == .read and (l.reserved or l.place_hold or l.held_read != .none);
}

/// Whether loop (or labeled block) `outer` is `inner` or encloses it.
pub fn encloses(outer: *const LoopCtx, inner: ?*const LoopCtx) bool {
    var l = inner;
    while (l) |ctx| : (l = ctx.parent) if (ctx == outer) return true;
    return false;
}

// -----------------------------------------------------------------------------
// Core section 9: per path, one exit primitive
// -----------------------------------------------------------------------------

/// How a path ends (`exitTo`).
pub const ExitTo = struct {
    /// The point the path leaves for: on it, the vars declared since
    /// leave scope, and its state is relative to this point. Null
    /// where the path leaves the function (`return`, `e!`, `e?`, a
    /// failing result) or falls out of the innermost scope, whose end
    /// reports and drops its own vars (`popScope`).
    to: ?Point = null,
    /// The exit, whose defers run first; null where none run.
    exit: ?Exit = null,
    /// Where the path goes on, for liveness: a source position, or
    /// after the current statement when null.
    resume_at: ?u32 = null,
    /// The loans of the value the path leaves with: a result, a
    /// `break` value, a block's value. It is formed before the
    /// defers run and lives after them, so they run while it views
    /// what it views (`runDefers`).
    result: []const Loan = &.{},
};

/// The one way a path ends. It runs the defers its exit runs (their
/// effects stay only where the path ends, `Exit.goesOn`), reports
/// each loan the path drops that a holder still live where it goes
/// on keeps (`reportDropped`), and gives the path's state relative to
/// `x.to`.
pub fn exitTo(self: *Checker, x: ExitTo) Error!State {
    if (x.exit) |e| {
        // The defers that `e` runs, re-checked against the state here.
        const back: ?Point = if (e.goesOn()) try self.here() else null;
        const top = self.scopes.items.len - 1;
        const held = if (e == .scope_end) null else try dropPendingHolds(self, x.to);
        switch (e) {
            .scope_end => try runDefers(self, top, false, x.result),
            .jump => |depth| try runDefersTo(self, depth, false, x.result),
            .@"return", .propagate => |fails| try runDefersTo(self, 0, fails, x.result),
        }
        if (held) |h| {
            self.temps.clearRetainingCapacity();
            try self.temps.appendSlice(self.gpa, h);
        }
        if (back) |p| try self.rewind(p);
    }
    const to = x.to orelse return .{ .reachable = false };
    try notes.reportDropped(self, to.vars, x.resume_at);
    var s = try self.capture(to);
    // A jump leaves the statements it is in, which end there: the
    // loans they took and keep for their own ends (`temps`) do not go
    // on with it; the point it goes to has its own.
    if (x.exit) |e| if (e == .jump) {
        s.temps = to.temps;
    };
    return s;
}

/// Before the defers of an exit that leaves the statement it is in
/// run (a `return`, `e!`, `e?`, a jump), drop from the temporaries
/// the read loans that hold a place only until an operation the
/// exit abandons runs: a write self's reservation, which is read
/// until its call starts (`reserved`), a place found up to an index
/// (`place_hold`), and a value read in place for a consumer that
/// runs after the later operands (`held_read`). The exit leaves
/// before that operation, so it never runs: no call starts, nothing
/// reads the value, and none of them holds a value to drop. Each
/// other loan stays, a write view already made among them (`f(!v,
/// g()!)`), and so does every hold the point a jump goes to keeps
/// (`to`). Returns the temporaries to restore after.
pub fn dropPendingHolds(self: *Checker, to: ?Point) Error!?[]const Loan {
    var any = false;
    for (self.temps.items) |l| if (pendingHold(l) and !(if (to) |p| containsLoan(p.temps, l) else false)) {
        any = true;
        break;
    };
    if (!any) return null;
    const held = try self.arena().dupe(Loan, self.temps.items);
    var n: usize = 0;
    for (held) |l| {
        if (pendingHold(l) and !(if (to) |p| containsLoan(p.temps, l) else false)) continue;
        self.temps.items[n] = l;
        n += 1;
    }
    self.temps.shrinkRetainingCapacity(n);
    return held;
}

// -----------------------------------------------------------------------------
// Defer
// -----------------------------------------------------------------------------

/// `defer` / `errdefer`: the body runs at scope exit. It is checked
/// where it is written (and may not change outer state), then again
/// at each exit of its scope against the state there.
pub fn walkDefer(self: *Checker, e: lowered.Expr) Error!void {
    const node = e.node;
    const body = ir.get(node, .body);
    const steps = lowered.stepsIn(self, e);
    const r: ?lir.RegionId = if (steps.len > 0 and steps[steps.len - 1] == .region) steps[steps.len - 1].region else null;
    try checkDeferBody(self, body, r, true);
    try self.scopes.items[self.scopes.items.len - 1].defers.append(self.gpa, .{ .body = body, .r = r, .vars = @intCast(self.vars.items.len), .err_only = node.isKind(.@"errdefer") });
}

/// Walk a `defer` body, which region `r` runs: where it is written
/// (`report_changes`), and its effects undone; at an exit, where it
/// runs, leaving them to `exitDefers`.
pub fn checkDeferBody(self: *Checker, body: Sexp, r: ?lir.RegionId, report_changes: bool) Error!void {
    const snap = try self.here();
    const saved_loop = self.loop;
    const saved_in_defer = self.in_defer;
    try self.defer_loops.append(self.gpa, self.loop);
    self.loop = null;
    self.in_defer = true;
    _ = try transfer.walkStmtValueE(self, if (r) |dr| lowered.bodyStmt(self, body, dr) else lowered.uncovered(self, body), null);
    _ = self.defer_loops.pop();
    self.loop = saved_loop;
    self.in_defer = saved_in_defer;
    if (!report_changes) return;
    // A body that moves an outer binding and assigns it again
    // (`defer x = f(<x)`) leaves it as it was, and still moved it.
    if (movedInDefer(self, snap)) |m| {
        if (m.part) {
            try notes.errAt(self, body, "a `defer` body cannot move a field out of `{s}`; it runs when the scope exits", .{self.vars.items[m.id].name});
        } else try notes.errAt(self, body, "a `defer` body cannot move or drop `{s}`; it runs when the scope exits", .{self.vars.items[m.id].name});
        try self.rewind(snap);
        return;
    }
    const after = try self.leave(snap, null);
    for (after.changes) |e| {
        if (e.flow.status != self.flows.items[e.id].status) {
            try notes.errAt(self, body, "a `defer` body cannot move or drop `{s}`; it runs when the scope exits", .{self.vars.items[e.id].name});
            break;
        }
        if (!partSetEql(e.flow.parts, self.flows.items[e.id].parts)) {
            try notes.errAt(self, body, "a `defer` body cannot move a field out of `{s}`; it runs when the scope exits", .{self.vars.items[e.id].name});
            break;
        }
    }
}

/// The first var in scope at `p` that the code walked since moved,
/// dropped, or moved a field out of at some point, whatever it
/// holds now: each change on the trail since `p` records the flow it
/// replaced, which is compared with the var's flow at `p`.
pub fn movedInDefer(self: *Checker, p: Point) ?struct { id: VarId, part: bool } {
    const changes = self.trail.items[p.trail..];
    for (changes, 0..) |c, i| {
        if (c.id >= p.vars) continue;
        const first = for (changes[0..i]) |d| {
            if (d.id == c.id) break d.old;
        } else continue;
        if (first.status != .live) continue;
        if (c.old.status != .live) return .{ .id = c.id, .part = false };
        if (c.old.parts.len > first.parts.len) return .{ .id = c.id, .part = true };
    }
    return null;
}

/// Re-check the defers of scope `scope_idx` at an exit, with its
/// `errdefer`s when the exit `fails`. A `defer` runs after the value
/// the path leaves with is formed, and before it is used: the loans
/// that value carries (`result`) are in force while it runs, so it
/// may not touch what the value views. An `errdefer` runs only where
/// that value is an error, which views nothing.
pub fn runDefers(self: *Checker, scope_idx: usize, fails: bool, result: []const Loan) Error!void {
    // The body sees the names of its own scope, not those of scopes
    // opened after the defer.
    const saved = self.hidden;
    self.hidden = .{ .lo = scope_idx, .hi = self.scopes.items.len - 1 };
    defer self.hidden = saved;
    const saved_floor = self.defer_floor;
    defer self.defer_floor = saved_floor;
    var i = self.scopes.items[scope_idx].defers.items.len;
    while (i > 0) {
        i -= 1;
        const d = self.scopes.items[scope_idx].defers.items[i];
        if (d.err_only and !fails) continue;
        self.defer_floor = d.vars;
        const held = self.temps.items.len;
        if (!d.err_only) for (result) |l| if (!l.ext) try live.addTemp(self, l);
        try checkDeferBody(self, d.body, d.r, false);
        self.temps.shrinkRetainingCapacity(@min(held, self.temps.items.len));
    }
}

/// Run the defers of the scopes an early exit leaves (every scope at
/// index `scope_depth` or above, up to the enclosing function), and
/// check the order their vars are dropped in.
pub fn runDefersTo(self: *Checker, scope_depth: usize, fails: bool, result: []const Loan) Error!void {
    // An exit from inside a deferred body leaves only that body.
    if (self.in_defer) return;
    var si = self.scopes.items.len;
    while (si > scope_depth) {
        si -= 1;
        if (self.scopes.items[si].defers.items.len > 0) try runDefers(self, si, fails, result);
        if (self.scopes.items[si].kind != .block) break;
    }
    if (si < self.scopes.items.len) try checkDropOrder(self, self.scopes.items[si].start);
}

/// Leaving scopes drops vars `>= start`, youngest first. A value whose
/// drop runs a user `drop` body must not view, directly or through
/// what it views, a younger value dropped (or out of scope) before
/// it: the body could read it after.
pub fn checkDropOrder(self: *Checker, start: u32) Error!void {
    const ctx = self.sema;
    const len: u32 = @intCast(self.vars.items.len);
    var reach: std.ArrayList(VarId) = .empty;
    for (start..len) |i| {
        const h = self.vars.items[i];
        if (!self.flowLive(@intCast(i)) or h.payload_view or h.loop_view or h.ref != .none) continue;
        if (sema.dropRunsBody(ctx, h.ty orelse continue) != .yes) continue;
        reach.clearRetainingCapacity();
        try reach.append(self.arena(), @intCast(i));
        var k: usize = 0;
        while (k < reach.items.len) : (k += 1) {
            for (self.flows.items[reach.items[k]].loans) |l| {
                if (l.ext or l.root < start or std.mem.findScalar(VarId, reach.items, l.root) != null) continue;
                try reach.append(self.arena(), l.root);
                const x = self.vars.items[l.root];
                if (l.root < i or !self.flowLive(l.root)) continue;
                const glue = if (x.ty) |t| sema.typeHasDropGlue(ctx, t) else true;
                if (!glue and scopeOf(self, l.root) == scopeOf(self, @intCast(i))) continue;
                try notes.err(self, l.pos, "`{s}` is dropped before `{s}`, whose `drop` body could still read it through this view", .{ x.name, h.name });
                try notes.note(self, x.decl, "`{s}` is declared after `{s}`, so it is dropped first; declare it before `{s}`", .{ x.name, h.name, h.name });
            }
        }
    }
}

/// A task or a set of tasks that can fail, still held where its scope
/// ends normally, would be dropped without being waited for, and its
/// error lost (docs/design/concurrency.md, "Tasks"). On an early exit
/// (`return`, `!`, a `break`) the drop is what cancels it, and is not
/// reported.
pub fn checkLostTasks(self: *Checker, start: u32) Error!void {
    const ctx = self.sema;
    for (start..self.vars.items.len) |i| {
        const h = self.vars.items[i];
        const ty = h.ty orelse continue;
        if (!self.flowLive(@intCast(i))) continue;
        const result = sema.taskResult(ctx, ty) orelse continue;
        if (ctx.types.get(result) != .fallible) continue;
        if (sema.isTaskSet(ctx, ty)) {
            try notes.err(self, h.decl, "the tasks of `{s}` can fail, and they are dropped where its scope ends without being waited for, so their errors would be lost: wait for them, `>{s}!`, or handle the error with `catch`", .{ h.name, h.name });
        } else try notes.err(self, h.decl, "the task `{s}` can fail, and it is dropped where its scope ends without being waited for, so its error would be lost: wait for it, `>{s}!`, or handle its error with `catch`", .{ h.name, h.name });
    }
}

/// The index of the innermost scope var `id` is declared in.
pub fn scopeOf(self: *const Checker, id: VarId) usize {
    var si = self.scopes.items.len;
    while (si > 0) {
        si -= 1;
        if (self.scopes.items[si].start <= id) return si;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Jumps
// -----------------------------------------------------------------------------

pub const Jump = enum { brk, cont };

/// `(break value-or-_ label?)` / `(continue label?)`: the state here
/// flows to where the jump goes, as the type checker resolved it
/// (`sema.JumpDest`): past the construct it names, to the loop's step,
/// or to the loop's head.
pub fn walkJump(self: *Checker, e: lowered.Expr, jump: Jump) Error!void {
    const node = e.node;
    const value = if (jump == .brk) ir.Break.value(node) else .nil;
    const dest = self.sema.jumpDestOf(node);
    var target = self.loop;
    if (dest) |d| while (target) |t| : (target = t.parent) {
        if (sameNode(t.node, d.target)) break;
    };
    // A `break` value leaves the loop like a returned value leaves the
    // function: it is consumed, and it may not view what the loop
    // declared.
    if (target) |t| self.value_reads = t.reads;
    // A name declared in the loop leaves its scope with the value:
    // `break x` moves it, as `return x` does, before the scopes the
    // jump leaves run their defers. Any other name stays in scope
    // after the jump, so one that owns is written `<x`.
    const moved = if (target) |t| try transfer.breakMovesName(self, value, t.point.vars) else null;
    const v: Value = if (value == .nil) .{} else if (moved) |id|
        (if (self.vars.items[id].payload_view) try transfer.movePayload(self, id, value.src.pos, "move") else try transfer.moveVar(self, id, value.src.pos, .move))
    else blk: {
        const value_e = lowered.stepValue(self, lowered.stepsIn(self, e), value);
        if (self_check) transfer.expectRole(self, value_e, .{ .sink = .brk });
        break :blk try transfer.walkConsumedE(self, value_e, .brk);
    };
    self.value_reads = false;
    const t = target orelse {
        // The type checker resolves every jump of a module it accepts.
        try notes.errSpan(self, stmtSpan(self, node), "internal error: this `{s}` goes to no construct the checker is walking", .{if (jump == .brk) "break" else "continue"});
        self.reachable = false;
        return;
    };
    // A jump out of an assignment's value never reaches its
    // target: what the target reads is not used on this path.
    const pinned = self.after_value.items.len;
    const left = for (self.after_value.items, 0..) |a, i| {
        if (encloses(t, a.loop)) break i;
    } else pinned;
    const kept = try self.arena().dupe(AfterValue, self.after_value.items[left..]);
    self.after_value.shrinkRetainingCapacity(left);
    const left_with = try rules.escapeVarsFrom(self, v, t.point.vars);
    t.value = try self.valueUnion(t.value, left_with);
    // A `continue` to a step that runs in the condition's bindings'
    // scope goes to that point; any other goes back to the loop's
    // head, through a step that is the loop's continue expression.
    const to_step = if (dest.?.to == .step) t.step_point else null;
    const s = try exitTo(self, .{ .to = to_step orelse t.point, .exit = .{ .jump = if (to_step != null) t.step_depth else t.scope_depth }, .result = try self.withDerefs(left_with, v) });
    switch (dest.?.to) {
        .exit => try t.breaks.append(self.arena(), s),
        .step, .head => try (if (to_step != null) &t.step_conts else &t.conts).append(self.arena(), s),
    }
    try self.after_value.appendSlice(self.gpa, kept);
    self.reachable = false;
}

/// Whether the walk of block statements `stmts` stops before statement
/// `i`, which no path reaches; either way the statements it does not
/// walk are checked as `checkAfterJump` and `checkRestAfterJump` check them.
pub fn unreached(self: *Checker, stmts: lowered.Stmts, i: usize) Error!bool {
    if (i > 0) try checkAfterJump(self, stmts.node(i - 1), stmts.node(i));
    if (self.reachable) return false;
    try checkRestAfterJump(self, stmts, i);
    return true;
}

/// Code right after `return`, `break`, `continue`, or `panic` in the
/// same block never runs; Zig rejects it, and so does Rig: `stmt`,
/// after `prev`.
fn checkAfterJump(self: *Checker, prev: Sexp, stmt: Sexp) Error!void {
    if (!rig.leaves(prev)) return;
    try notes.errSpan(self, stmtSpan(self, stmt), "unreachable code: this statement follows a `{s}`", .{@tagName(prev.kind().?)});
}

/// Statements from `i` on, which are not walked: the one before `i`
/// never finishes (a `loop` no `break` leaves, or a jump, reported
/// already). Emit still writes them, so a statement right after a
/// jump among them, or in a block inside one, is reported as
/// `checkAfterJump` reports it.
fn checkRestAfterJump(self: *Checker, stmts: lowered.Stmts, i: usize) Error!void {
    if (i > 0 and rig.leaves(stmts.node(i - 1))) return;
    for (i..stmts.len()) |j| {
        if (j > i) try checkAfterJump(self, stmts.node(j - 1), stmts.node(j));
        try checkJumpsUnder(self, stmts.node(j));
    }
}

/// `checkAfterJump` for each block under `e`, which is not walked.
pub fn checkJumpsUnder(self: *Checker, e: Sexp) Error!void {
    if (e.isKind(.block)) {
        const stmts = ir.Block.stmts(e);
        for (stmts, 0..) |s, j| {
            if (j > 0) try checkAfterJump(self, stmts[j - 1], s);
            try checkJumpsUnder(self, s);
        }
        return;
    }
    for (rig.children(e)) |c| try checkJumpsUnder(self, c);
}

/// A statement's range: its span, or the last statement position
/// when it has none (a bare `break` checked without the parser's
/// spans).
pub fn stmtSpan(self: *const Checker, s: Sexp) diag.Span {
    const sp = notes.span(self, s);
    return if (sp.isEmpty()) .{ .start = self.anchor, .end = self.anchor } else sp;
}
