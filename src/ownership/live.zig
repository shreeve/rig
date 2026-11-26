//! Liveness: a loan is in force only while the var holding it may be
//! used again, so a view ends at its last use (Core sentence 6).

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const LoopCtx = state.LoopCtx;
const Value = state.Value;
const VarId = state.VarId;

// -----------------------------------------------------------------------------
// Liveness: a view ends at its last use (Core sentence 6)
// -----------------------------------------------------------------------------

/// Record the last use of every symbol in `e` (a function's parameters
/// and body), and the symbols deferred code uses. A capture's own
/// leaf is also a use of the binding it captures. A `while` loop's
/// step runs after the body, so its uses count there (`stepAt`), or
/// at `at` when `e` is in a step already. (An assignment's target is
/// used after its value, which `after_value` records as the value is
/// walked.)
pub fn indexUses(self: *Checker, e: Sexp, in_defer: bool, at: ?u32) Error!void {
    switch (e) {
        .src => |s| {
            const ctx = self.sema;
            const sym = ctx.symbolOf(e) orelse return;
            try noteUse(self, sym, at orelse s.pos, in_defer);
            const d = ctx.symbols.items[sym];
            if (d.kind == .capture and d.decl_pos == s.pos and d.origin != sema.symbol_invalid) {
                try noteUse(self, d.origin, at orelse s.pos, in_defer);
            }
        },
        .list => {
            const deferred = in_defer or e.isKind(.@"defer") or e.isKind(.@"errdefer");
            for (e.items()) |c| {
                const step_at = if (sema.isWhileStep(e, c)) at orelse notes.stepAt(self, e) else at;
                try indexUses(self, c, deferred, step_at);
            }
        },
        else => {},
    }
}

/// Where a use at `pos` happens: its own position, or, for a leaf a
/// rewrite wrote past the source's end (a spread's copied operand),
/// its home there, so liveness orders it with the source's uses.
pub fn usePos(self: *const Checker, pos: u32) u32 {
    if (pos < self.source.len) return pos;
    const p = self.sema.parser orelse return pos;
    return p.homeOf(pos);
}

pub fn noteUse(self: *Checker, sym: SymbolId, written: u32, in_defer: bool) Error!void {
    const pos = usePos(self, written);
    if (in_defer) try self.defer_used.put(self.gpa, sym, {});
    try self.uses.note(self.gpa, sym, pos, self.sema.symbols.items.len);
}

/// Whether `holder` still uses what it views once a statement's
/// temporary it views is dropped there. A temporary of the same
/// statement, dropped after it, uses its views as any owner's drop
/// does, only through a `drop` body (Core sentence 6), or through a
/// live value that views it; any other holder as `holderLive` says.
pub fn holdsPastDrop(self: *const Checker, holder: VarId, depth: u8) bool {
    if (!self.isStmtTemp(holder) or depth > 16) return holderLive(self, holder, null);
    const ctx = self.sema;
    const ty = self.vars.items[holder].ty orelse return true;
    if (sema.dropRunsBody(ctx, ty) != .no) return true;
    if (self.isViewed(holder)) for (self.flows.items, 0..) |f, j| {
        if (j == holder) continue;
        for (f.loans) |l| if (l.root == holder and !l.ext) {
            if (holdsPastDrop(self, @intCast(j), depth + 1)) return true;
            break;
        };
    };
    return false;
}

/// Whether the value var `id` holds may still be used after the
/// current point (or after position `at`, a scope's end), so the
/// loans it holds are still in force. It is live when the var is used
/// later in the code, or anywhere in a loop around this point that
/// does not also enclose its declaration (the next iteration runs
/// that code again), or in deferred code, or by the target of an
/// assignment whose value is being walked (`after_value`), or when
/// its drop at scope exit may run a `drop` body, which could read
/// what it views
/// (`sema.dropRunsBody`; any other drop only releases memory, and
/// uses no view), or when a live var or temporary views it in turn.
/// Otherwise its last use is behind, and its views have ended.
pub fn holderLive(self: *const Checker, id: VarId, at: ?u32) bool {
    return holderLiveDepth(self, id, at, 0);
}

pub fn holderLiveDepth(self: *const Checker, id: VarId, at: ?u32, depth: u8) bool {
    if (!self.nll or depth > 16) return true;
    const ctx = self.sema;
    const v = self.vars.items[id];
    // An owning temporary is used by its `drop` body, or through what
    // views it.
    if (v.temp_value) {
        if (v.ty == null or sema.dropRunsBody(ctx, v.ty.?) != .no) return true;
        return viewedByLive(self, id, at, depth);
    }
    // A parameter is live at every exit: the caller uses the value
    // it gave a view of after the return.
    if (v.kind == .hidden or v.kind == .param or v.env_drop_reads or self.isGlobal(id)) return true;
    const sym = v.sym orelse return true;
    if (self.defer_used.contains(sym)) return true;
    for (self.after_value.items) |a| if (a.sym == sym) return true;
    const ty = v.ty orelse return true;
    // A var that owns its value drops it at scope exit, which uses
    // its views only through a `drop` body. (A match payload or a
    // viewed loop element only views a value.)
    const owns = !v.payload_view and !v.loop_view and v.ref == .none;
    if (owns and sema.dropRunsBody(ctx, ty) != .no) return true;
    if (self.uses.last(sym)) |last| {
        // A use in the statement being walked counts while it is
        // ahead; in a loop the var was declared outside of, every use
        // in the loop runs again.
        const from = liveFrom(self, v.decl, at);
        if (last >= from and (at != null or from < stmtStart(self) or last >= stmtEnd(self) or useAhead(self, sym, from))) return true;
    }
    return viewedByLive(self, id, at, depth);
}

/// Whether a live var or a temporary views var `id`.
pub fn viewedByLive(self: *const Checker, id: VarId, at: ?u32, depth: u8) bool {
    if (self.isViewed(id)) for (self.flows.items, 0..) |f, j| {
        if (j == id) continue;
        for (f.loans) |l| if (l.root == id and !l.ext) {
            if (holderLiveDepth(self, @intCast(j), at, depth + 1)) return true;
            break;
        };
    };
    for (self.temps.items) |l| if (l.root == id) return true;
    return false;
}

/// Whether symbol `sym` has a use at or after `from` not walked yet.
pub fn useAhead(self: *const Checker, sym: SymbolId, from: u32) bool {
    const all = self.uses.get(sym) orelse return true;
    for (all.items) |p| {
        if (p >= from and std.mem.findScalar(u32, self.walked.items, p) == null) return true;
    }
    return false;
}

/// The use at `pos` is walked: unless a consumer being walked reads
/// it where it runs (`late`).
pub fn markWalked(self: *Checker, at: u32) Error!void {
    const pos = usePos(self, at);
    if (!self.nll or std.mem.findScalar(u32, self.late.items, pos) != null) return;
    try self.walked.append(self.gpa, pos);
}

/// The uses `late` gained since `mark` are walked: their consumer is
/// done.
pub fn endLate(self: *Checker, mark: usize) Error!void {
    const from = @min(mark, self.late.items.len);
    try self.walked.appendSlice(self.gpa, self.late.items[from..]);
    self.late.shrinkRetainingCapacity(from);
}

/// Mark the name `e` reads (a name, or a view or move of one), a part
/// a consumer reads where it runs, as used there (`late`).
pub fn holdLate(self: *Checker, e: Sexp) Error!void {
    const name = switch (e) {
        .src => e,
        .list => if ((e.isKind(.read) or e.isKind(.write) or e.isKind(.move)) and ir.get(e, .operand) == .src) ir.get(e, .operand) else return,
        else => return,
    };
    try self.late.append(self.gpa, usePos(self, name.src.pos));
}

/// The parts of a call or an array literal that it reads
/// where it runs (`storage.isPureArg`), after the others: where it
/// evaluates the rest into temporaries first (`hoists`), or passes its
/// keyword arguments in its parameters' order.
pub fn holdLateParts(self: *Checker, parts: []const Sexp, hoists: bool) Error!void {
    const ctx = self.sema;
    if (!self.nll) return;
    if (!hoists) {
        for (parts) |a| {
            if (a.isKind(.kwarg)) break;
        } else return;
    }
    for (parts) |a| {
        const v = storage.argValue(a);
        if (storage.isPureArg(ctx, v)) try holdLate(self, v);
    }
}

/// The first position whose uses of a var declared at `decl` still
/// lie ahead: the current statement (or `at`), or the start of an
/// enclosing loop the var was declared outside of, one around a
/// deferred body being walked included (`defer_loops`).
pub fn liveFrom(self: *const Checker, decl: u32, at: ?u32) u32 {
    var from: u32 = loopStartFrom(self.loop, decl, if (at) |a| usePos(self, a) else stmtStart(self));
    for (self.defer_loops.items) |outer| from = loopStartFrom(outer, decl, from);
    return from;
}

/// `from`, or the start of a loop of the chain from `loop` outward
/// that starts after `decl`, whichever is earlier.
pub fn loopStartFrom(loop: ?*LoopCtx, decl: u32, from: u32) u32 {
    var out = from;
    var l = loop;
    while (l) |ctx| : (l = ctx.parent) {
        if (ctx.is_loop and ctx.start > decl) out = @min(out, ctx.start);
    }
    return out;
}

/// Where the current statement starts: its first source position
/// (not always its first leaf, for `stmt if cond`), or where a
/// loop's step runs.
pub fn stmtStart(self: *const Checker) u32 {
    if (self.step_at) |at| return at;
    const ext = notes.extent(self, self.cur_stmt);
    return if (ext.hi >= ext.lo) ext.lo else self.anchor;
}

/// The first position after the current statement.
pub fn stmtEnd(self: *const Checker) u32 {
    if (self.step_at) |at| return at +| 1;
    return notes.extent(self, self.cur_stmt).hi +| 1;
}

pub fn addTemp(self: *Checker, l: Loan) Error!void {
    try self.temps.append(self.gpa, l);
}

/// Loans carried by the current value of var `id`.
pub fn varValue(self: *Checker, id: VarId) Value {
    const v = self.vars.items[id];
    if (!v.closure and !types.mayCarryLoan(self, v.ty)) {
        if (generic.genericType(self, v.ty)) {
            // A value of a type parameter's type carries, in an
            // instance, what its binding views (a match payload's
            // view of the matched value), and a parameter taken by
            // value what its caller's argument viewed.
            generic.taintGeneric(self, v.ty, .{ .loans = self.flows.items[id].loans });
            if (v.kind == .param and v.ref == .none) if (v.param_index) |i| {
                self.func.generic |= sema.paramBit(i);
            };
        }
        return .{};
    }
    return .{ .loans = self.flows.items[id].loans };
}
