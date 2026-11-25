//! Messages: diagnostics, and the notes that name both ends of a view
//! (where it was made, and where it is still used).

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const diag = @import("../diag.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const Checker = state.Checker;
const Flow = state.Flow;
const Loan = state.Loan;
const Owning = state.Owning;
const PathId = state.PathId;
const Reader = state.Reader;
const Sink = state.Sink;
const Value = state.Value;
const Var = state.Var;
const VarId = state.VarId;
const hasLoanFrom = state.hasLoanFrom;
const whole_path = state.whole_path;

/// Why `<` cannot leave a part that copies done (`MoveSource.part`).
pub const part_copies_rule = "cannot move out of `{s}`: it copies, so `<` would leave it as it was; remove the `<` to copy it";

/// Why a module's constant cannot be moved or dropped.
pub const module_level_rule = "cannot {s} module-level `{s}` inside a function; later calls would still use it";

/// Why a loop view cannot leave its slot, for diagnostics.
pub const loop_view_rule = "a `for x in ?list` element is a read view of the List slot and cannot be cloned, moved, dropped, or stored";

/// The article before a type's name in a message: "an `Int`", "an
/// `R`" (said "ar").
pub fn article(name: []const u8) []const u8 {
    if (name.len == 0) return "a";
    if (name.len == 1 or !std.ascii.isLower(name[1])) return switch (name[0]) {
        'A', 'E', 'F', 'H', 'I', 'L', 'M', 'N', 'O', 'R', 'S', 'X' => "an",
        else => "a",
    };
    return switch (name[0]) {
        'A', 'E', 'I', 'O', 'a', 'e', 'i', 'o' => "an",
        else => "a",
    };
}

// -----------------------------------------------------------------------------
// Diagnostics
// -----------------------------------------------------------------------------

pub fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
    return self.errSpan(.{ .start = pos, .end = pos }, fmt, args);
}

/// An error about `node`, reported at its span.
pub fn errAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
    return self.errSpan(self.span(node), fmt, args);
}

/// A bound on the checker's work is hit at `pos`, by `what` there:
/// the program is rejected, never accepted unchecked.
pub fn tooComplex(self: *Checker, pos: u32, what: []const u8) Error!void {
    return self.err(pos, "this {s} is too complex for the ownership checker; split it into smaller functions", .{what});
}

pub fn errSpan(self: *Checker, at: diag.Span, comptime fmt: []const u8, args: anytype) Error!void {
    self.last_err_kept = false;
    self.errors_found += 1;
    if (self.quiet > 0) return;
    const msg = try self.gpa.print(fmt, args);
    for (self.diagnostics.items) |d| {
        if (d.severity == .@"error" and d.pos == at.start and std.mem.eql(u8, d.message, msg)) {
            self.gpa.free(msg);
            return;
        }
    }
    try self.diagnostics.append(self.gpa, .{ .severity = .@"error", .pos = at.start, .end = at.end, .message = msg });
    self.last_err_kept = true;
}

pub fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
    return self.noteIn(0, pos, fmt, args);
}

/// A note at `pos` in module `module_id`'s source (0 for this one).
pub fn noteIn(self: *Checker, module_id: u32, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
    if (self.quiet > 0 or !self.last_err_kept) return;
    const msg = try self.gpa.print(fmt, args);
    try self.diagnostics.append(self.gpa, .{ .severity = .note, .pos = pos, .message = msg, .module = module_id });
}

/// Where the step of `while` loop `node` runs: after its body.
pub fn stepAt(self: *const Checker, node: Sexp) u32 {
    return self.extent(ir.While.body(node)).hi +| 1;
}

/// Where a path that skips the rest of `node` goes on: at `next`, a
/// later part of it, or else past its end.
pub fn resumeAt(self: *const Checker, next: Sexp, node: Sexp) u32 {
    return self.resumeBefore(next, self.extent(node).hi +| 1);
}

/// Where a path that skips to `next` goes on, in a node whose end is
/// `past` (`resumeAt` with that node's end found once).
pub fn resumeBefore(self: *const Checker, next: Sexp, past: u32) u32 {
    return if (next == .nil) past else @min(self.extent(next).lo, past);
}

/// The first and last leaf positions in `s`, every one where its
/// span puts it: a hidden leaf a rewrite padded past the source's end
/// (a chain's names, a closure's padded parameter) stands at its
/// home in the source (`Parser.span`), so no scope, statement, or
/// loop ends past every use. `lo > hi` when it has none.
pub fn extent(self: *const Checker, s: Sexp) struct { lo: u32, hi: u32 } {
    switch (s) {
        .src => |leaf| {
            const at = if (leaf.pos < self.source.len) leaf.pos else self.startOf(s);
            return .{ .lo = at, .hi = at };
        },
        .list => {
            var lo: u32 = std.math.maxInt(u32);
            var hi: u32 = 0;
            for (s.items()) |c| {
                const e = self.extent(c);
                if (e.hi < e.lo) continue;
                lo = @min(lo, e.lo);
                hi = @max(hi, e.hi);
            }
            return .{ .lo = lo, .hi = hi };
        },
        else => return .{ .lo = std.math.maxInt(u32), .hi = 0 },
    }
}

/// The source range of a node: its span from the parser.
pub fn span(self: *const Checker, node: Sexp) diag.Span {
    return self.sema.span(node);
}

/// Where a node starts in the source.
pub fn startOf(self: *const Checker, node: Sexp) u32 {
    return self.span(node).start;
}

/// Note pointing at the move or drop that invalidated `v`.
pub fn noteInvalidated(self: *Checker, id: VarId, use_pos: u32) Error!void {
    const v = self.vars.items[id];
    const f = self.flows.items[id];
    // `>t` takes the task it waits for.
    const waited = f.status != .dropped and f.at > 0 and f.at <= self.source.len and self.source[f.at - 1] == '>' and if (v.ty) |t| sema.isTask(self.sema, t) or sema.isTaskSet(self.sema, t) else false;
    const what = if (f.status == .dropped) "dropped" else if (waited) "waited for" else "moved";
    const why = if (waited) "; a wait takes what it waits for, so it waits once" else "";
    // Deferred code runs after the code that follows it, and a
    // loop's step after its body.
    if (self.loop != null and f.at >= (self.step_at orelse use_pos) and !self.in_defer) {
        try self.note(f.at, "`{s}` was {s} here, in a previous iteration of the loop{s}", .{ try self.varText(v), what, why });
    } else {
        try self.note(f.at, "`{s}` was {s} here{s}", .{ try self.varText(v), what, why });
    }
}

pub fn noteLoan(self: *Checker, loan: Loan) Error!void {
    if (self.quiet > 0 or !self.last_err_kept) return;
    const viewed = try self.pathText(loan.root, loan.path);
    if (loan.place_hold) {
        try self.note(loan.pos, "a view of `{s}` is made here, and the place is found up to each index before the index runs", .{viewed});
    } else if (loan.held_read != .none) {
        try self.note(loan.pos, "`{s}` read here: the value shares its storage, and {s}", .{ viewed, heldUse(loan.held_read) });
    } else if (loan.reserved) {
        try self.note(loan.pos, "a write view of `{s}` is made here, as `self`, which is read until the call starts", .{viewed});
    } else if (loan.read_of_write) {
        try self.note(loan.pos, "a write view of `{s}` is made here, and kept as a read view by a value that only reads it", .{viewed});
    } else if (self.kept_views.get(loan.pos)) |k| {
        try self.note(loan.pos, "a {s} view of `{s}` is made here, and `{s}` keeps it in `{s}` (its signature says `keeps {s}`), so the view lasts while `{s}` is used", .{ self.viewWord(loan), viewed, k.callee, k.holder, k.param, k.holder });
    } else try self.note(loan.pos, "a {s} view of `{s}` is made here", .{ self.viewWord(loan), viewed });
}

/// How what reads a value in place uses it, after the operands that
/// follow it run.
pub fn heldUse(reader: Reader) []const u8 {
    return switch (reader) {
        .none, .argument => "the call uses it after its later arguments run",
        .self => "the call uses it as `self` after its arguments run",
        .callee => "the call runs it after its arguments run",
        .operand => "the operator uses it after its right operand runs",
        .base => "it is indexed after its index runs",
    };
}

/// How a message names the view loan `l` records, by the sigil
/// written: a cell's `!c` is a write view though its loan is a read
/// loan, and a write self is one though it is read until its call
/// starts. A result that only reads what `!v` gave it is a read view.
pub fn viewWord(self: *const Checker, l: Loan) []const u8 {
    if (l.kind == .write or l.reserved) return "write";
    if (l.read_of_write) return "read";
    return if (self.bangAt(l.pos)) "write" else "read";
}

/// Whether `!` is written at `pos`, or just before it: a loan's
/// position is its sigil's (a write self) or its operand's, which the
/// sigil touches.
pub fn bangAt(self: *const Checker, pos: u32) bool {
    if (pos < self.source.len and self.source[pos] == '!') return true;
    return pos > 0 and pos <= self.source.len and self.source[pos - 1] == '!';
}

/// How a message names the view loan `l` records, after a use of
/// place `path` of the same var: `a read view of it`, or `a write
/// view of `p.a`` when that view is of another place.
pub fn viewOfText(self: *Checker, l: Loan, path: PathId) Error![]const u8 {
    return self.arena().print("a {s} view of {s}", .{ self.viewWord(l), try self.viewedText(l, path) });
}

/// How a message names what loan `l` is on, after a use of place
/// `path` of the same var: `it`, or the place `l` is on where that is
/// another.
pub fn viewedText(self: *Checker, l: Loan, path: PathId) Error![]const u8 {
    if (l.path == path) return "it";
    return self.arena().print("`{s}`", .{try self.pathText(l.root, l.path)});
}

// -----------------------------------------------------------------------------
// Where a view is still used: a conflict's second note
// -----------------------------------------------------------------------------

/// Note the other end of the view loan `l` records, which blocks
/// what is done at `at`: the use that keeps it in force. That is
/// the next use, after `at`, of what holds it, for a task its wait;
/// or the drop, at the end of its scope, of a task or of a value
/// whose `drop` body reads it; or the `task.select` whose arms hold
/// it. It mirrors `holderLive`, which decided the view is in force,
/// and reads only what the walk keeps anyway (`uses`, `walked`), so a
/// program without errors pays nothing for it.
pub fn noteStillUsed(self: *Checker, l: Loan, at: u32) Error!void {
    if (self.quiet > 0 or !self.last_err_kept) return;
    if (l.place_hold or l.held_read != .none) return;
    if (self.holderOf(l)) |h| return self.noteHolderUse(h, l, at, null, 0);
    return self.noteStmtUse(l, at);
}

/// The var whose value holds loan `l` and is still live after the
/// current point, as `findLoan` found it.
pub fn holderOf(self: *const Checker, l: Loan) ?VarId {
    for (self.flows.items, 0..) |f, h| {
        for (f.loans) |x| if (x.root == l.root and x.path == l.path and x.pos == l.pos and x.kind == l.kind and !x.ext) {
            if (self.holderLive(@intCast(h), null)) return @intCast(h);
            break;
        };
    }
    return null;
}

/// `noteStillUsed` for loan `l`, which the statement in flight holds:
/// the `task.select` whose arms hold it, or the call that takes it,
/// which runs after its arguments. A view made before the statement
/// came into it in a var's value, written as an argument.
pub fn noteStmtUse(self: *Checker, l: Loan, at_sigil: u32) Error!void {
    const stmt = self.cur_stmt;
    if (stmt == .nil) return;
    // A position may be a sigil's, before the leaf it touches.
    var at = at_sigil;
    while (at < self.source.len and std.mem.findScalar(u8, "!?<+~>*^-", self.source[at]) != null) at += 1;
    if (self.selectWith(stmt, at, l.pos)) |sel|
        return self.note(self.startOf(sel), "still used here: `task.select` makes every arm before it runs one, and each arm's views last until it returns", .{});
    const sp = self.span(stmt);
    const inside = l.pos >= sp.start and l.pos < sp.end;
    const made = if (inside) l.pos else self.carrierIn(stmt, l) orelse return;
    const call = self.callWith(stmt, made, at, !inside) orelse return;
    const callee = ir.Call.callee(call);
    const pos = if (callee.isKind(.member)) self.startOf(ir.Member.name(callee)) else self.startOf(callee);
    try self.note(pos, "still used here, by the call, which runs after its arguments", .{});
}

/// The innermost call in `node` that has positions `a` and `b` in
/// it; when `direct`, `a` must be the last leaf of its self or of
/// an argument.
pub fn callWith(self: *const Checker, node: Sexp, a: u32, b: u32, direct: bool) ?Sexp {
    if (node != .list) return null;
    const sp = self.span(node);
    if (a < sp.start or a >= sp.end or b < sp.start or b >= sp.end) return null;
    for (node.items()) |c| if (self.callWith(c, a, b, direct)) |call| return call;
    if (!node.isKind(.call)) return null;
    if (!direct) return node;
    const callee = ir.Call.callee(node);
    if (callee.isKind(.member) and self.extent(ir.Member.object(callee)).hi == a) return node;
    for (ir.Call.args(node)) |arg| if (self.extent(arg).hi == a) return node;
    return null;
}

/// The leaf in `node` of a var whose value carried loan `l` into the
/// statement: it holds the loan still, or moved there.
pub fn carrierIn(self: *const Checker, node: Sexp, l: Loan) ?u32 {
    switch (node) {
        .src => |leaf| {
            const sym = self.sema.symbolOf(node) orelse return null;
            for (self.vars.items, self.flows.items) |v, f| if (v.sym != null and v.sym.? == sym) {
                if (f.status == .moved and f.at <= leaf.pos and f.at +| 1 >= leaf.pos) return leaf.pos;
                for (f.loans) |x| if (x.root == l.root and x.pos == l.pos) return leaf.pos;
            };
            return null;
        },
        .list => {
            for (node.items()) |c| if (self.carrierIn(c, l)) |p| return p;
            return null;
        },
        else => return null,
    }
}

/// `noteStillUsed` for loan `l`, which var `h` holds: the next use of
/// `h`, the deferred code or the caller that uses it, its drop, the
/// loop that reads it again, or where what views `h` in turn is
/// still used. `end` is set where `at` is a scope's end, where the
/// liveness of `h` is asked (`releaseVarsFrom`).
pub fn noteHolderUse(self: *Checker, h: VarId, l: Loan, at: u32, end: ?u32, depth: u8) Error!void {
    if (depth > 16) return;
    const ctx = self.sema;
    const v = self.vars.items[h];
    if (v.call_held) return self.noteStmtUse(l, at);
    if (v.kind == .hidden and !v.temp_value and v.arm_of.len == 0 and v.erased_of.len == 0) {
        // The source a loop walks, held while it runs: it takes its
        // next element from it.
        var lp = self.loop;
        while (lp) |c| : (lp = c.parent) {
            if (!c.is_loop) continue;
            const body = if (c.node.isKind(.@"for")) ir.For.body(c.node) else if (c.node.isKind(.@"while")) ir.While.body(c.node) else continue;
            if (v.decl >= self.startOf(c.node) and v.decl < self.extent(body).lo)
                return self.note(self.startOf(c.node), "still used here, by the loop, which takes its next element from it", .{});
        }
        // What a `match` holds of its subject while it chooses an arm:
        // it reads the subject again after a guard (`walkMatch`).
        if (v.name.len == 0 and self.afterMatch(v.decl))
            return self.note(v.decl, "still used here, by the `match`, which reads its subject again after a guard to test the next arm", .{});
    }
    if (!v.temp_value and v.kind != .hidden and !self.isGlobal(h)) if (v.sym) |sym| {
        if (self.nextUse(v, sym, at, end)) |u| {
            // A use before the statement in flight (before the scope's
            // end) runs again in the loop's next iteration.
            const before = if (end) |e| u < e else u < self.stmtStart();
            // A task's use is its wait, `>t`: point at the wait.
            const wait = u > 0 and u <= self.source.len and self.source[u - 1] == '>' and if (v.ty) |ty| sema.isTask(ctx, ty) or sema.isTaskSet(ctx, ty) else false;
            if (!before) return self.note(if (wait) u - 1 else u, "still used here", .{});
            if (self.inDeferred(u)) return self.note(u, "still used here, in deferred code, which runs at the end of its scope", .{});
            return self.note(u, "still used here, in the next iteration of the loop", .{});
        }
        // The target of an assignment whose value is being walked is
        // used after it.
        for (self.after_value.items) |a| if (a.sym == sym) if (self.targetUse(sym, at)) |u|
            return self.note(u, "still used here", .{});
        if (self.defer_used.contains(sym)) if (self.deferredUse(sym)) |u|
            return self.note(u, "still used here, in deferred code, which runs at the end of its scope", .{});
        if (v.kind == .param)
            return self.note(v.decl, "still used by the caller, through `{s}`, after the function returns", .{v.name});
    };
    // A value that owns what it holds uses its views where it is
    // dropped only through a `drop` body; a task's waits for its call.
    const owns = !v.payload_view and !v.loop_view and v.ref == .none;
    if (owns and v.name.len > 0) if (v.ty) |ty| if (sema.dropRunsBody(ctx, ty) != .no) {
        if (self.scopeEnd(h)) |e| {
            if (sema.isTaskSet(ctx, ty))
                return self.note(e, "`{s}` is dropped here, at the end of its scope, and waits for its tasks, which still use the view", .{v.name});
            if (sema.isTask(ctx, ty))
                return self.note(e, "`{s}` is dropped here, at the end of its scope, and waits for its task, which still uses the view", .{v.name});
            return self.note(e, "`{s}` is dropped here, at the end of its scope, and its `drop` body could still read the view", .{v.name});
        }
    };
    // Through a live var that views `h`, or the statement in flight.
    if (self.isViewed(h)) for (self.flows.items, 0..) |f, j| {
        if (j == h) continue;
        for (f.loans) |x| if (x.root == h and !x.ext) {
            if (self.holderLiveDepth(@intCast(j), end, depth + 1)) return self.noteHolderUse(@intCast(j), x, at, end, depth + 1);
            break;
        };
    };
    for (self.temps.items) |x| if (x.root == h) {
        if (x.held_read != .none) return self.note(x.pos, "still used here: {s}", .{heldUse(x.held_read)});
        return self.noteStmtUse(x, at);
    };
}

/// Whether `pos` follows the keyword `match`: a match's subject.
pub fn afterMatch(self: *const Checker, pos: u32) bool {
    const before = std.mem.trimEnd(u8, self.source[0..@min(pos, self.source.len)], " \t");
    if (!std.mem.endsWith(u8, before, "match")) return false;
    const k = before.len - "match".len;
    return k == 0 or !(std.ascii.isAlphanumeric(before[k - 1]) or before[k - 1] == '_');
}

/// The target of an assignment around `at` whose value is being
/// walked: the use of `sym` not walked yet nearest before `at`.
pub fn targetUse(self: *const Checker, sym: SymbolId, at_in: u32) ?u32 {
    const at = self.usePos(at_in);
    const all = self.uses.get(sym) orelse return null;
    var best: ?u32 = null;
    for (all.items) |p| {
        if (p > at or std.mem.findScalar(u32, self.walked.items, p) != null) continue;
        if (best == null or p > best.?) best = p;
    }
    return best;
}

/// The use of var `v` (symbol `sym`) that keeps it live past `at`,
/// as `holderLiveDepth` counts uses: the first after `at`, or else
/// the first in the loop around, which runs again. A use that reads
/// the value comes before one that only assigns the var, which
/// counts too.
pub fn nextUse(self: *const Checker, v: Var, sym: SymbolId, at_in: u32, end: ?u32) ?u32 {
    const at = self.usePos(at_in);
    const all = self.uses.get(sym) orelse return null;
    const from = self.liveFrom(v.decl, end);
    const any_walked = end != null or from < self.stmtStart();
    // By whether the use only assigns, then whether it is after `at`.
    var best: [2][2]?u32 = .{ .{ null, null }, .{ null, null } };
    for (all.items) |p| {
        if (p < from or p == v.decl) continue;
        if (!any_walked and p < self.stmtEnd() and std.mem.findScalar(u32, self.walked.items, p) != null) continue;
        const slot = &best[@intFromBool(self.assignsOnly(p))][@intFromBool(p <= at)];
        if (slot.* == null or p < slot.*.?) slot.* = p;
    }
    return best[0][0] orelse best[0][1] orelse best[1][0] orelse best[1][1];
}

/// Whether the name at `pos` is only assigned there (`x = e`, `x: T
/// = e`), not read.
pub fn assignsOnly(self: *const Checker, pos: u32) bool {
    var i = pos;
    while (i < self.source.len and (std.ascii.isAlphanumeric(self.source[i]) or self.source[i] == '_')) i += 1;
    while (i < self.source.len and self.source[i] == ' ') i += 1;
    if (i >= self.source.len) return false;
    if (self.source[i] == ':') return true;
    return self.source[i] == '=' and (i + 1 >= self.source.len or self.source[i + 1] != '=');
}

/// Whether `pos` lies in the body of a `defer` or `errdefer` of a
/// scope still open.
pub fn inDeferred(self: *const Checker, pos: u32) bool {
    for (self.scopes.items) |s| for (s.defers.items) |d| {
        const x = self.extent(d.body);
        if (pos >= x.lo and pos <= x.hi) return true;
    };
    return false;
}

/// A use of symbol `sym` in deferred code of a scope still open.
pub fn deferredUse(self: *const Checker, sym: SymbolId) ?u32 {
    const all = self.uses.get(sym) orelse return null;
    for (all.items) |p| if (self.inDeferred(p)) return p;
    return null;
}

/// Where var `id` is dropped at the end of its scope: just past the
/// scope's last character, or null where the scope's code is not
/// known.
pub fn scopeEnd(self: *const Checker, id: VarId) ?u32 {
    const s = self.scopes.items[self.scopeOf(id)];
    return self.endOf(if (s.kind == .function) self.fn_body else s.node);
}

/// Just past the last character of `node`, or null for none.
pub fn endOf(self: *const Checker, node: Sexp) ?u32 {
    if (node == .nil) return null;
    const ext = self.extent(node);
    if (ext.hi < ext.lo) return null;
    var end = @min(@max(self.span(node).end, ext.hi +| 1), @as(u32, @intCast(self.source.len)));
    while (end > ext.hi +| 1 and std.ascii.isWhitespace(self.source[end - 1])) end -= 1;
    return end;
}

/// Note the views in `v`, which call `node` keeps through `param`, as
/// kept in what its write self or arguments lead to.
pub fn noteKept(self: *Checker, callee: Sexp, v: Value, param: []const u8, write_recv: ?VarId, arg_values: []const Value) Error!void {
    var holder = write_recv;
    if (holder == null) find: for (arg_values) |av| {
        for (av.loans) |l| if (l.kind == .write) {
            holder = l.root;
            break :find;
        };
    };
    const h = holder orelse return;
    const name = if (callee.isKind(.member)) self.text(ir.Member.name(callee)) else if (callee == .src) self.text(callee) else return;
    for (v.loans) |l| {
        if (l.ext) continue;
        try self.kept_views.put(self.gpa, l.pos, .{ .callee = name, .param = param, .holder = self.vars.items[h].name });
    }
}

/// The end of a conflict's message for a read held in place: what
/// holds it, and of what (`it`, or the place it reads).
pub fn heldReadClause(self: *Checker, reader: Reader, of: []const u8) Error![]const u8 {
    const who = switch (reader) {
        .none, .argument => "an earlier argument's",
        .self => "`self`'s",
        .callee => "the callee's",
        .operand => "the left operand's",
        .base => "the indexed value's",
    };
    return self.arena().print("while {s} read of {s} is still in use", .{ who, of });
}

/// Whether var `id` holds a handle to a cell (`*Cell[T]`, a
/// `Signal`, …), which changes only through its own calls: for
/// diagnostics.
pub fn holdsCellHandle(self: *const Checker, id: VarId) bool {
    const ctx = self.sema;
    const ty = self.vars.items[id].ty orelse return false;
    return switch (ctx.types.get(ty)) {
        .shared => |inner| sema.holdsMarkedValue(ctx, inner),
        else => false,
    };
}

/// Whether positions `a` and `b` lie in two arms of one `task.select`
/// in `node`.
pub fn inTwoArms(self: *const Checker, node: Sexp, a: u32, b: u32) bool {
    return self.selectWith(node, a, b) != null;
}

/// The `task.select` in `node` that has positions `a` and `b` in two
/// of its arms.
pub fn selectWith(self: *const Checker, node: Sexp, a: u32, b: u32) ?Sexp {
    const ctx = self.sema;
    if (node != .list) return null;
    if (node.isKind(.call)) {
        var arm_a: ?usize = null;
        var arm_b: ?usize = null;
        for (ir.Call.args(node), 0..) |arg, i| {
            if (!arg.isKind(.call) or ctx.selectArmOf(arg) == null) continue;
            const x = self.extent(arg);
            if (a >= x.lo and a <= x.hi) arm_a = i;
            if (b >= x.lo and b <= x.hi) arm_b = i;
        }
        if (arm_a != null and arm_b != null) return if (arm_a.? != arm_b.?) node else null;
    }
    for (node.items()) |c| if (self.selectWith(c, a, b)) |sel| return sel;
    return null;
}

/// The fix for a call that makes a write view of all of `recv` (place
/// `path` of var `id`) while loan `l` is on a part of it: a method
/// views all of its self (Core §5), so view only the fields it writes.
pub fn noteWholeSelf(self: *Checker, id: VarId, path: PathId, l: Loan, callee: Sexp, pos: u32) Error!void {
    if (self.paths.depth(l.path) <= self.paths.depth(path)) return;
    const recv = try self.pathText(id, path);
    const method = self.text(ir.Member.name(callee));
    try self.note(pos, "the call makes a write view of all of `{s}`: make write views of the fields it writes, `(!{s}.field).method(...)`, or make `{s}` a function of those fields", .{ recv, recv, method });
}

/// The fix for a call of an owned closure held in what the call
/// writes or moves: a handle of its own keeps the closure alive
/// whatever the call does to its holder (Core §7).
pub fn noteCloneCallee(self: *Checker, pos: u32) Error!void {
    const ctx = self.sema;
    const call = self.callWithCalleeAt(self.cur_stmt, pos) orelse return;
    const callee = ctx.calleeOf(call);
    if (sema.ownedClosureFn(ctx, self.exprType(callee) orelse return) == null) return;
    const args = ir.Call.args(call);
    const a = self.arena();
    var shown: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, i| {
        if (i > 0) try shown.appendSlice(a, ", ");
        try shown.appendSlice(a, self.spanText(arg));
    }
    try self.note(pos, "clone the handle first: `f = +{s}`, then `f({s})`", .{ self.spanText(callee), shown.items });
}

/// The call in `node` whose callee starts at `pos`.
pub fn callWithCalleeAt(self: *const Checker, node: Sexp, pos: u32) ?Sexp {
    if (node != .list) return null;
    const ctx = self.sema;
    if (node.isKind(.call)) {
        if (self.startOf(ctx.calleeOf(node)) == pos) return node;
    }
    for (node.items()) |c| if (self.callWithCalleeAt(c, pos)) |found| return found;
    return null;
}

// -----------------------------------------------------------------------------
// Reports
// -----------------------------------------------------------------------------

/// Report loan `l` on a var leaving scope, which `holder` (when
/// known) keeps. Where the scope ends as the code falls through, at
/// `drop` (and at `end` for liveness), the drop is what meets the
/// view.
pub fn reportShortLived(self: *Checker, l: Loan, holder: ?VarId, drop: ?struct { at: u32, end: u32 }) Error!void {
    const root = self.vars.items[l.root];
    if (root.erased_of.len > 0) return self.reportErasedCopy(l, root);
    if (root.arm_of.len > 0) return self.reportArmView(l);
    if (root.call_held) return self.reportCallHeld(l, holder);
    if (root.kind == .hidden and root.name.len > 0) return self.reportTempOutlived(l, holder);
    if (drop) |d| if (holder) |h| if (self.vars.items[h].name.len > 0) {
        // A jump out of the scope that drops it first reported it
        // where the view is made: counted, as a repeated error is.
        for (self.diagnostics.items) |x| if (x.severity == .@"error" and x.pos == l.pos and std.mem.endsWith(u8, x.message, "does not live long enough")) {
            self.errors_found += 1;
            self.last_err_kept = false;
            return;
        };
        try self.err(d.at, "`{s}` is dropped here, at the end of its scope, while {s} is still in use", .{ root.name, try self.viewOfText(l, whole_path) });
        try self.noteLoan(l);
        if (self.quiet == 0 and self.last_err_kept) try self.noteHolderUse(h, l, d.end, d.end, 0);
        return self.noteStringViewOfString(l, self.vars.items[h].ty);
    };
    try self.err(l.pos, "`{s}` does not live long enough", .{root.name});
    if (holder) |h| {
        const hv = self.vars.items[h];
        if (hv.name.len > 0) {
            try self.note(root.decl, "`{s}` goes out of scope while `{s}` still views it", .{ root.name, hv.name });
            return self.noteStringViewOfString(l, hv.ty);
        }
    }
    try self.note(root.decl, "`{s}` goes out of scope while a view of it is still in use", .{root.name});
}

/// An API object that views a copy, a local of the block that erased
/// it (`Var.erased_of`), kept past that block by `l`.
pub fn reportErasedCopy(self: *Checker, l: Loan, root: Var) Error!void {
    const ctx = self.sema;
    const view = try sema.formatTypeIn(ctx, self.arena(), root.erased_view orelse return);
    const ty = root.ty orelse return;
    const why = if (ctx.types.get(ty) == .type_var)
        try std.fmt.allocPrint(self.arena(), "since a `{s}` may be held as a copy", .{try sema.formatTypeIn(ctx, self.arena(), ty)})
    else
        try std.fmt.allocPrint(self.arena(), "since `{s}` is plain data", .{try sema.formatTypeIn(ctx, self.arena(), ty)});
    try self.err(l.pos, "`{s}` of `{s}` views a copy held in this block, {s}, so it cannot leave the block; make the view of the value where it lives, or take `{s}: {s}`", .{ view, root.erased_of, why, root.erased_of, view });
}

/// Where loan `l` of a String outlives the String in a value of type
/// `held` whose only views are Strings (a `?String` field or result):
/// the `?String` was meant to own its text.
pub fn noteStringViewOfString(self: *Checker, l: Loan, held: ?TypeId) Error!void {
    return self.noteStringView(l, held, "store a `String` to own it");
}

/// `noteStringViewOfString` for a result: the function gives text of
/// its own by returning a `String`.
pub fn noteStringResultOfString(self: *Checker, l: Loan, held: ?TypeId) Error!void {
    return self.noteStringView(l, held, "return a `String` to give text of its own");
}

pub fn noteStringView(self: *Checker, l: Loan, held: ?TypeId, fix: []const u8) Error!void {
    const ctx = self.sema;
    const t = held orelse return;
    if (!self.isString(self.vars.items[l.root].ty) or !sema.holdsViewOnly(ctx, t)) return;
    try self.note(l.pos, "a `?String` views text it doesn't own; {s}", .{fix});
}

/// A view of a read match's binding `l` names, kept past its arm.
/// The hint offers a clone only of a binding that has one, and a
/// take only of a subject that is an owner's name, so each form it
/// names compiles.
pub fn reportArmView(self: *Checker, l: Loan) Error!void {
    var end = l.pos;
    while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_')) end += 1;
    const name = diag.textBetween(self.source, l.pos, end);
    const root = self.vars.items[l.root];
    const clones = if (self.sema.symbolAt(l.pos)) |sym| sema.cloneable(self.sema, self.sema.symbols.items[sym].ty) != .no else false;
    const a = self.arena();
    const take = if (root.arm_take.len > 0) try std.fmt.allocPrint(a, "take the subject with `match <{s}` and move it with `<{s}`", .{ root.arm_take, name }) else "";
    const hint = if (clones and take.len > 0)
        try std.fmt.allocPrint(a, "use it in the arm, or keep an owner of what it holds: copy it with `+{s}`, or {s}", .{ name, take })
    else if (clones)
        try std.fmt.allocPrint(a, "use it in the arm, or keep an owner of what it holds: copy it with `+{s}`", .{name})
    else if (take.len > 0)
        try std.fmt.allocPrint(a, "use it in the arm, or {s}", .{take})
    else
        "use it in the arm";
    try self.err(l.pos, "a view of `{s}` does not outlive the `match` that reads `{s}`: {s}", .{ name, root.arm_of, hint });
}

/// The owner's name a read match on `scrut` (`x` or `?x`) could take
/// instead with `match <x`: a name whose value moves and is no view
/// or handle. Empty for any other subject.
pub fn takeableSubject(self: *Checker, scrut: Sexp) []const u8 {
    const ctx = self.sema;
    const name = if (scrut.isKind(.read)) ir.Read.operand(scrut) else scrut;
    if (name != .src) return "";
    const ty = self.exprType(name) orelse return "";
    if (sema.isReadOrWriteView(ctx, ty) or sema.moves(ctx, ty) != .yes) return "";
    switch (self.typeData(ty)) {
        .shared, .weak => return "",
        else => {},
    }
    return self.spanText(name);
}

/// A view `l` of what a call holds only while it runs, which the
/// call's result or `holder` keeps after the call returns.
pub fn reportCallHeld(self: *Checker, l: Loan, holder: ?VarId) Error!void {
    const name = self.vars.items[l.root].name;
    try self.err(l.pos, "a view of `{s}` outlives the call, which holds `{s}` only while it runs; bind `{s}` to a name first", .{ name, name, name });
    if (!self.last_err_kept) return;
    const h = holder orelse return;
    const hv = self.vars.items[h];
    if (hv.name.len > 0) try self.note(hv.decl, "`{s}` still holds it after the call", .{hv.name});
}

/// A view `l` of a statement's temporary that `holder` keeps past
/// the statement.
pub fn reportTempOutlived(self: *Checker, l: Loan, holder: ?VarId) Error!void {
    const name = self.vars.items[l.root].name;
    // A template is written as it is, between its own backticks.
    const temp = if (name.len > 0 and name[0] == '`') name else try std.fmt.allocPrint(self.arena(), "`{s}`", .{name});
    // A temporary made before it in the statement is dropped after
    // it, so holds the view past the temporary's drop.
    if (holder) |h| if (self.isStmtTemp(h) and self.vars.items[h].name.len > 0) {
        const hv = self.vars.items[h];
        try self.err(l.pos, "a view of the temporary {s} is held by `{s}`, a temporary its statement drops after it; bind the value to a name first", .{ temp, hv.name });
        if (self.last_err_kept) try self.note(hv.decl, "`{s}` is made before `{s}`, so dropped after it", .{ hv.name, name });
        return;
    };
    // A view the statement holds owns nothing it could drop: what
    // it views is held only while the statement runs.
    const is_view = if (self.vars.items[l.root].ty) |t| sema.isReadOrWriteView(self.sema, t) else false;
    if (is_view) {
        try self.err(l.pos, "a view reached through `{s}` outlives its statement, which holds `{s}`, itself a view, only while it runs; bind `{s}` to a name first", .{ name, name, name });
    } else try self.err(l.pos, "a view of the temporary {s} outlives its statement, which drops it; bind the value to a name first", .{temp});
    if (!self.last_err_kept) return;
    const h = holder orelse return;
    const hv = self.vars.items[h];
    if (hv.name.len > 0) try self.note(hv.decl, "`{s}` still holds it after the statement", .{hv.name});
}

/// A statement's temporary, made since there were `depth` vars, that
/// `holder` (whose flow is `f`) still views after the statement,
/// which drops it: reported once.
pub fn reportTempHolder(self: *Checker, f: Flow, holder: VarId, depth: u32) Error!void {
    for (f.loans) |l| {
        if (l.root < depth or !self.isStmtTemp(l.root)) continue;
        if (self.holderLive(holder, self.stmtEnd())) try self.reportTempOutlived(l, holder);
        return;
    }
}

/// Report each var below `depth` that keeps a loan on a var at
/// `depth` or above, which leaves scope, where the holder is live at
/// `at` (after the current statement when null); or, when it is not,
/// a loan on a statement's temporary that it keeps past its
/// statement. Each holder is reported once.
pub fn reportDropped(self: *Checker, depth: u32, at: ?u32) Error!void {
    if (!self.viewedFrom(depth)) return;
    for (self.flows.items[0..@min(depth, self.flows.items.len)], 0..) |f, holder| {
        if (!hasLoanFrom(f.loans, depth)) continue;
        if (!(try self.reportHolder(f, @intCast(holder), depth, at, .nil))) try self.reportTempHolder(f, @intCast(holder), depth);
    }
}

/// Report each loan on a var at `depth` or above that `holder`
/// (whose flow is `f`) keeps, where the holder is live at `at` (after
/// the current statement when null). Whether it is. `scope` is the
/// code of a scope that ends as the code falls through, which drops
/// those vars at its end (`.nil` for another exit).
pub fn reportHolder(self: *Checker, f: Flow, holder: VarId, depth: u32, at: ?u32, scope: Sexp) Error!bool {
    if (!self.holderLive(holder, at)) return false;
    // Where the scope that drops them ends, when it ends as the code
    // falls through: worked out only here, for the message.
    const drop_at = self.endOf(scope);
    for (f.loans) |l| if (l.root >= depth) try self.reportShortLived(l, holder, if (drop_at) |d| .{ .at = d, .end = at.? } else null);
    return true;
}

/// `<e` of a branching value (`a if c else b`, `a ?? b`, `e catch h`,
/// `e!`, `e?`): `<` takes only what its leaves give up, a value made
/// there. Any other leaf (`sema.moveLeaves`) would be left as it was,
/// or moved while its owner still drops it, so the move is written
/// where the leaf is. The first such leaf is reported; whether one was.
pub fn reportMoveLeaves(self: *Checker, top: Sexp) Error!bool {
    const ctx = self.sema;
    var leaves: std.ArrayList(sema.MoveLeaf) = .empty;
    try sema.moveLeaves(self.arena(), ctx, top, &leaves);
    for (leaves.items) |leaf| switch (leaf.source) {
        // The type checker reported it.
        .made_part => {},
        else => {
            try self.reportMoveLeaf(leaf, top);
            return true;
        },
    };
    return false;
}

pub fn reportMoveLeaf(self: *Checker, leaf: sema.MoveLeaf, top: Sexp) Error!void {
    const place = leaf.node;
    // A part of a branching value is shown as written.
    const shown = if (leaf.source == .branch_part) self.spanText(place) else try self.placeText(place);
    const at_exit = top.isKind(.propagate) or top.isKind(.propagate_none);
    const ty = self.exprType(place);
    // An optional field that moves like a name (`sema.moveSource`) is
    // moved inside the branch, as a binding is.
    const moves = leaf.source == .part and ty != null and self.typeData(ty.?) == .optional;
    switch (leaf.source) {
        .capture => try self.errAt(place, "`<` here would leave `{s}` as it was: the closure keeps its capture for every call; remove the `<` to copy it", .{shown}),
        .declared => try self.errAt(place, "`<` here would leave `{s}` as it was: it lives for the whole program; remove the `<` to copy it", .{shown}),
        else => if (moves or leaf.source == .binding or leaf.source == .optional_part) {
            const verb = if (leaf.source == .optional_part) "take" else "move";
            if (at_exit) {
                try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it before the `?` or `!`: `(<{s}){s}`", .{ shown, verb, shown, if (top.isKind(.propagate)) "!" else "?" });
            } else try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it inside the branch: `<{s}`", .{ shown, verb, shown });
        } else if (ty != null and (self.copies(ty) or self.refOfType(ty) == .read)) {
            try self.errAt(place, "`<` here would leave `{s}` as it was: it copies; remove the `<` to copy it", .{shown});
        } else if (leaf.source == .branch_part) {
            try self.errAt(place, "`<` here would copy `{s}` out without moving it, and the binding its branch reads would still drop it; exchange the part where it is owned, with `swap`", .{shown});
        } else try self.errAt(place, "`<` here would copy `{s}` out without moving it, and a field that is not optional cannot be moved out; {s}", .{ shown, try self.exchangeHint(ty, shown, "exchange it") }),
    }
}

/// What a bare use that would copy a moving value names: a binding,
/// or a field or element, which stays where it is.
pub const Aliased = enum { name, field, element };

/// A bare use that would copy a value that moves: say what holds the
/// value, and every way to write what is meant (move, clone, view).
pub fn reportAlias(self: *Checker, pos: u32, what: []const u8, aliased: Aliased, k: Owning, sink: Sink, ty: ?TypeId, part: ?Sexp) Error!void {
    if (k == .generic) {
        // Fine for plain data: each instantiation is checked.
        if (ty) |t| try self.requirePlain(pos, t, false);
        return;
    }
    const a = self.arena();
    const ctx = self.sema;
    const t = ty orelse return;
    const shown = try sema.formatTypeIn(ctx, a, t);
    const is_name = aliased == .name;
    var fixes: std.ArrayList([]const u8) = .empty;
    // A name moves; a part moves out only from an optional, which
    // `<` leaves `none`, unless nothing can assign its binding
    // (`sema.moveSource`).
    // A part of what a match binds by reading a place moves once the
    // match takes the place: `<` there comes first.
    const subject: []const u8 = if (part) |p| if (self.resolvePlace(p)) |at| self.vars.items[at.root].read_subject else "" else "";
    if (!is_name and subject.len > 0 and sema.cloneable(ctx, t) != .bump) {
        try fixes.append(a, try a.print("`<{s}` where it is matched, so its fields are owned, then `<{s}` to move this one", .{ subject, what }));
    }
    if (is_name) {
        try fixes.append(a, try a.print("`<{s}` to move it", .{what}));
    } else if (self.typeData(t) == .optional and if (part) |p| sema.moveSource(ctx, p) == .part else false) {
        try fixes.append(a, try a.print("`<{s}` to move it out", .{what}));
    } else if (self.typeData(t) == .optional and !(if (part) |p| ctx.untakeableAt(p) else true)) {
        try fixes.append(a, try a.print("`<{s}` to take it out (leaving `none`)", .{what}));
    }
    switch (sema.cloneable(ctx, t)) {
        .no => {},
        .bump => try fixes.append(a, try a.print("`+{s}` for another handle", .{what})),
        else => try fixes.append(a, try a.print("`+{s}` to {s}", .{ what, if (sink == .argument) "pass a clone" else "clone it" })),
    }
    if (sink == .binding) try fixes.append(a, try a.print("`?{s}` to view it", .{what}));
    const callee = if (sink == .argument) try self.ownerCallee(pos) else null;
    var msg: std.ArrayList(u8) = .empty;
    if (callee) |f| {
        try msg.print(a, "`{s}` takes ownership of {s} `{s}`, and `{s}` can't be copied", .{ f.name, article(shown), shown, what });
    } else {
        const holds = switch (k) {
            .shared, .weak => try a.print("is {s} `{s}` handle", .{ article(shown), shown }),
            .unique => try a.print("is a unique `{s}`", .{shown}),
            else => try a.print("owns {s} `{s}`", .{ article(shown), shown }),
        };
        const into = switch (sink) {
            .binding => "by `=`",
            .argument => "into an argument",
            .field => "into a field",
            .element => "into an array",
            .allocation => "into a counted handle",
            .box => "into a box",
            .ret => "out by `return`",
            .brk => "out by `break`",
        };
        try msg.print(a, "`{s}` {s}, which can't be copied {s}", .{ what, holds, into });
    }
    if (fixes.items.len > 0) {
        try msg.appendSlice(a, ": write ");
        for (fixes.items, 0..) |fix, n| {
            if (n > 0) try msg.appendSlice(a, if (n + 1 < fixes.items.len) ", " else if (fixes.items.len > 2) ", or " else " or ");
            try msg.appendSlice(a, fix);
        }
    } else {
        try msg.appendSlice(a, if (aliased == .element) ", has no clone, and can't be moved out of what holds it" else ", has no clone, and can't be moved out of its parent");
    }
    if (callee) |f| {
        const param = f.param orelse shown;
        if (param.len == 0) {
            try msg.print(a, "; if `{s}` only reads it, make its parameter a read view", .{f.name});
        } else try msg.print(a, "; if `{s}` only reads it, make its parameter {s} `?{s}`", .{ f.name, article(param), param });
    }
    try self.err(pos, "{s}", .{msg.items});
}

/// The function or method whose argument at `pos` is the one being
/// walked (`arg_call`), when it is declared: its parameter could be
/// a view. Null for a constructor, a closure, or a built-in method.
/// `param` is the parameter's declared type where it mentions a type
/// parameter (`T`), which the hint writes in place of the argument's,
/// or empty where that parameter is not known.
pub fn ownerCallee(self: *Checker, pos: u32) Error!?struct { name: []const u8, param: ?[]const u8 = null } {
    const call = self.arg_call orelse return null;
    const ctx = self.sema;
    const args = ir.Call.args(call);
    const index = for (args, 0..) |arg, i| {
        const sp = ctx.span(arg);
        if (pos >= sp.start and pos < sp.end) break i;
    } else return null;
    const callee = ir.Call.callee(call);
    if (callee == .src) {
        const sym = ctx.symbols.items[ctx.symbolOf(callee) orelse return null];
        if (sym.kind != .function) return null;
        const f = switch (ctx.types.get(sym.ty)) {
            .function => |f| f,
            else => return .{ .name = self.text(callee) },
        };
        // A generic parameter is named as declared; a positional
        // argument fills the parameter at its place.
        if (!sema.isGenericFn(ctx, f)) return .{ .name = self.text(callee) };
        // By name, the parameter is not known here: the hint names
        // no type (`param` empty).
        for (args[0 .. index + 1]) |arg| if (arg.isKind(.kwarg)) return .{ .name = self.text(callee), .param = "" };
        if (index >= f.params.len) return .{ .name = self.text(callee), .param = "" };
        if (!sema.containsTypeVar(ctx, f.params[index])) return .{ .name = self.text(callee) };
        return .{ .name = self.text(callee), .param = try sema.formatTypeIn(ctx, self.arena(), f.params[index]) };
    }
    if (!callee.isKind(.member) or self.namesType(callee) or self.callsFunctionField(call, callee)) return null;
    var obj = ir.Member.object(callee);
    if (obj.isKind(.write) or obj.isKind(.read) or obj.isKind(.move)) obj = ir.get(obj, .operand);
    if (self.builtinName(self.exprType(obj)) != null) return null;
    return .{ .name = self.text(ir.Member.name(callee)) };
}

/// A store of view `l` into var `id`, which `l` is a loan on a part
/// of (`absorbLoans`): the part it went in by is the view in `views`
/// on `id`, if there is one.
pub fn reportSelfView(self: *Checker, id: VarId, l: Loan, views: []const Loan, pos: u32, via: ?[]const u8) Error!void {
    const into_path = for (views) |x| {
        if (x.root == id and !x.ext) break x.path;
    } else whole_path;
    const into = try self.pathText(id, into_path);
    const viewed = try self.pathText(l.root, l.path);
    // One the closure's captures were reported for, where it is made.
    const pair = try std.fmt.allocPrint(self.arena(), "{s} <- {s}", .{ into, viewed });
    for (self.closure_self_views.items) |p| if (std.mem.eql(u8, p, pair)) return;
    if (self.capturing) try self.closure_self_views.append(self.arena(), pair);
    if (via != null) {
        try self.err(pos, "cannot store in `{s}` a view of `{s}`: a value never holds a view of itself", .{ into, viewed });
    } else try self.err(pos, "cannot let this call store a view of `{s}` in `{s}`: a value never holds a view of itself", .{ viewed, into });
    try self.noteLoan(l);
}

/// How a move-out diagnostic says to exchange `path`, of type `ty`:
/// with `swap`, or, for a Cell, which `swap` never exchanges, with the
/// Cell's own swap; a value that holds a Cell is never exchanged
/// (`sema.holdsMarkedValue`, the one classifier).
pub fn exchangeHint(self: *Checker, ty: ?TypeId, path: []const u8, lead: []const u8) Error![]const u8 {
    const ctx = self.sema;
    if (ty) |t| if (sema.holdsMarkedValue(ctx, t)) {
        if (sema.isCell(ctx, t)) return std.fmt.allocPrint(self.arena(), "exchange its value with the Cell's own swap instead: `old = (!{s}).swap(v)`", .{path});
        return std.fmt.allocPrint(self.arena(), "it changes only by its marked calls, and is never exchanged whole", .{});
    };
    return std.fmt.allocPrint(self.arena(), "{s}: `old = swap(!{s}, v)`", .{ lead, path });
}

/// What to write instead of taking a captured `name` of type `ty` out
/// of its closure: what `+` gives, where it gives anything, and for
/// a shared handle a weak one too.
pub fn captureFix(self: *Checker, name: []const u8, ty: ?TypeId) Error![]const u8 {
    const ctx = self.sema;
    const t = ty orelse return "";
    const a = self.arena();
    return switch (sema.cloneable(ctx, t)) {
        .no, .depends => "",
        .bump => if (self.owningKind(t)) |k| switch (k) {
            .shared => a.print("; write `+{s}` for another handle, or `~{s}` for a weak one", .{ name, name }),
            else => a.print("; write `+{s}` for another weak handle", .{name}),
        } else "",
        else => a.print("; write `+{s}` for a clone", .{name}),
    };
}

/// A closure binding used as a value.
pub fn errClosureValue(self: *Checker, pos: u32, name: []const u8) Error!void {
    try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or copied; call it as `{s}()`, pass it to a call as `?{s}`, or make the literal owned (`*|...| body`) to pass it around", .{ name, name, name });
}

pub fn errOnceUse(self: *Checker, e: Sexp) Error!void {
    const name = self.text(e);
    try self.err(e.src.pos, "`{s}` is called at most once (`once`), so it is only called, `{s}()`, or passed to another `once` parameter", .{ name, name });
}

/// `!a[i]` and `!a[j]`: write views of two elements of the one
/// collection `a`, as the source spells them.
pub fn sameCollection(self: *const Checker, a: Sexp, b: Sexp) ?struct { base: []const u8, i: []const u8, j: []const u8 } {
    if (!a.isKind(.write) or !b.isKind(.write)) return null;
    const ea = ir.Write.operand(a);
    const eb = ir.Write.operand(b);
    if (!ea.isKind(.index) or !eb.isKind(.index) or rig.isRangeIndex(ea) or rig.isRangeIndex(eb)) return null;
    const base = self.spanText(ir.Index.object(ea));
    if (base.len == 0 or !std.mem.eql(u8, base, self.spanText(ir.Index.object(eb)))) return null;
    return .{ .base = base, .i = self.spanText(ir.Index.index(ea)), .j = self.spanText(ir.Index.index(eb)) };
}

// -----------------------------------------------------------------------------
// Names of places and values, as messages spell them
// -----------------------------------------------------------------------------

pub fn spanText(self: *const Checker, node: Sexp) []const u8 {
    const sp = self.span(node);
    return diag.textOf(self.source, sp);
}

/// Place `path` of var `root`, as the source names it (`p.a.b`).
/// How var `v` is named to a reader: its name, or, for the parameter
/// a group's field became, `group.field`, as the body reads it.
pub fn varText(self: *Checker, v: Var) Error![]const u8 {
    const sym = v.sym orelse return v.name;
    const group = self.sema.group_fields.get(sym) orelse return v.name;
    return sema.memberText(self.arena(), group, v.name);
}

pub fn pathText(self: *Checker, root: VarId, path: PathId) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(self.arena(), try self.varText(self.vars.items[root]));
    try self.paths.appendText(self.arena(), &out, path);
    // Self's member is `@name`, with no `.`.
    if (std.mem.eql(u8, self.vars.items[root].name, "@") and out.items.len > 2) _ = out.orderedRemove(1);
    return out.items;
}

pub fn placeText(self: *Checker, e: Sexp) Error![]const u8 {
    switch (e) {
        .src => return self.text(e),
        .list => switch (e.kind() orelse return "expression") {
            .member => return sema.memberText(self.arena(), try self.placeText(ir.Member.object(e)), self.text(ir.Member.name(e))),
            .index => return self.arena().print("{s}[{s}]", .{ try self.placeText(ir.Index.object(e)), self.spanText(ir.Index.index(e)) }),
            // A sigil: the place it wraps.
            .read, .write, .move, .clone, .share, .box, .weak => return self.placeText(ir.get(e, .operand)),
            // Any other value (`mk()`): as written.
            else => return self.spanText(e),
        },
        else => return "expression",
    }
}
