//! Ownership checker: moves, drops, borrows, and aliasing of owning values.
//!
//! Runs on the normalized semantic IR after sema, one function body at a
//! time, as a flow-sensitive abstract interpretation.
//!
//! Abstract state
//! --------------
//! * Every binding in scope is a `Var` (static facts: name, type, kind)
//!   paired with a `Flow` (status `live` / `moved` / `dropped`, plus the
//!   loans its value holds). Vars form a stack; leaving a scope truncates
//!   it, so a var index is valid exactly while the var is in scope.
//! * A `Loan` is a read or write borrow of a root var. Loans travel with
//!   values: `r = ?a` stores a read loan on `a` in `r`; `View(box: ?a)`
//!   carries it into the struct; a call whose result type can hold a
//!   borrow carries the loans of all of its arguments (so a returned
//!   borrow borrows from every borrowed argument), and a call may store
//!   its arguments' loans into its receiver, its `!x` arguments and the
//!   shared handles it is given. A loan that is not stored anywhere is a
//!   temporary and ends with its statement.
//! * Borrowed parameters hold an *external* loan on themselves: it marks
//!   a borrow that came from the caller, which may be returned or stored
//!   into other borrowed parameters, and it never conflicts.
//! * Types come from sema's symbol table (`exprType`); an unknown type is
//!   assumed to be able to hold a borrow.
//!
//! Control flow
//! ------------
//! * `if`, `match`, ternaries and `catch` walk every branch from the same
//!   entry state and `join` the results: a value moved or dropped on any
//!   path is moved or dropped afterwards, and loans are unioned. A match
//!   without a catch-all arm also joins the state where no arm ran.
//! * Loops iterate to a fixpoint over the back edge: the loop-head state
//!   is the join of the entry state, the end of the body and every
//!   `continue`. The state after the loop joins the condition-false state
//!   with every `break`. Diagnostics are only reported on the final walk.
//! * `return`, `break` and `continue` make the rest of their block
//!   unreachable; a `!` propagation inside `try` feeds the `catch` state.
//!
//! Rules
//! -----
//! * A moved or dropped value cannot be used, borrowed, moved or dropped.
//!   Reassigning a binding makes it live again.
//! * Read borrows exclude writes, moves, drops and reassignment of their
//!   root; write borrows exclude every other use. A method call borrows
//!   its receiver for the whole call (`rc.show(<rc)` is rejected).
//! * A borrow may not outlive its root: when a scope ends (normally or by
//!   `break`, `continue` or `!`), no surviving value may hold a loan on a
//!   var declared in it. A returned value, or one stored into something
//!   the caller owns, may only carry borrows the caller handed in.
//! * Values that own resources (`*T`, `~T`, `Vec(T)`, anything with drop
//!   glue) cannot be copied implicitly. In a consuming position (binding,
//!   argument, field, return, the branches of an `if`/`match` in such a
//!   position) a place expression of such a type must be written `<x` or
//!   `+x`; only a bare name returned directly moves implicitly. A value
//!   holding a write borrow cannot be copied either, except as a call
//!   argument (which reborrows it for the call).
//! * Only whole bindings move. Moving a non-Copy value out of a field or
//!   element (`<p.a`, `<v[0]`) is rejected: a borrowed or shared parent
//!   still owns it, and an owned parent would drop it again.
//! * Borrowed parameters cannot be dropped or move-captured. Functions may
//!   read module-level bindings but not move, drop or replace owning ones.
//! * A match payload binding views the scrutinee. Moving it out consumes
//!   an owned local scrutinee and is rejected for a borrowed or shared one.
//! * A closure literal may only be bound (`f = |...|`), called in place,
//!   or wrapped in `*Closure(...)`; closure bindings cannot be copied. A
//!   closure body may only use outer locals it captures. Resources
//!   captured into a closure are owned by its environment: the body may
//!   use and clone them but not move, drop or reassign them.
//! * A `defer` body cannot move or drop outer bindings, and is re-checked
//!   against the state at every exit of its scope.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const TypeId = types.TypeId;
const SymbolId = types.SymbolId;

pub const Severity = enum { @"error", note };

pub const Diagnostic = struct {
    severity: Severity,
    pos: u32,
    message: []const u8,
};

pub const Error = std.mem.Allocator.Error || rig.BindingKindError;

// =============================================================================
// Abstract state
// =============================================================================

const VarId = u32;

const LoanKind = enum(u1) { read, write };

const Loan = struct {
    root: VarId,
    kind: LoanKind,
    /// Source position of the borrow, for diagnostics.
    pos: u32,
    /// Borrow provided by the caller through a parameter: may be
    /// returned and never conflicts.
    ext: bool = false,

    fn sameAs(a: Loan, b: Loan) bool {
        return a.root == b.root and a.kind == b.kind and a.ext == b.ext;
    }
};

const Status = enum(u2) { live, moved, dropped };

/// The flow-sensitive part of a var: joined at merges, compared for the
/// loop fixpoint.
const Flow = struct {
    status: Status = .live,
    /// Position of the move or drop that produced `status`.
    at: u32 = 0,
    /// Loans held by the var's current value. Arena-owned, immutable.
    loans: []const Loan = &.{},
};

const VarKind = enum { local, param, capture, pattern, loop_elem, hidden };

/// How a var refers to its value: owned, or through a borrow.
const Ref = enum { none, read, write };

/// How a match payload binding reaches the scrutinee.
const Via = enum { owned, borrowed, shared };

const Var = struct {
    name: []const u8,
    decl: u32,
    ty: ?TypeId = null,
    kind: VarKind = .local,
    ref: Ref = .none,
    fixed: bool = false,
    closure: bool = false,
    /// Element of `for x in ?vec` over a resource Vec: a borrowed view of
    /// the slot.
    loop_borrow: bool = false,
    /// Resource captured into a closure environment (`|+x|`, `|~x|`,
    /// `|<x|`): the body sees a borrowed view of the env slot.
    capture_resource: bool = false,
    /// Match payload binding: the scrutinee var it views.
    alias_of: ?VarId = null,
    via: Via = .owned,
};

const ScopeKind = enum {
    block,
    /// A function body. Module-level names stay visible through it.
    function,
    /// A closure body: locals of enclosing functions must be captured.
    closure,
};

const Scope = struct {
    start: u32,
    kind: ScopeKind,
    defers: std.ArrayListUnmanaged(Sexp) = .empty,
};

/// A snapshot of the flow state at one program point.
const State = struct {
    flows: []const Flow,
    temps: []const Loan,
    reachable: bool,
};

/// The abstract value of an expression: the loans it carries.
const Value = struct {
    loans: []const Loan = &.{},
};

const FnCtx = struct {
    /// The return type can carry borrows: returned values are checked
    /// for loans on locals.
    ret_may_borrow: bool = false,
};

const LoopCtx = struct {
    /// Number of vars in scope at loop entry.
    depth: u32,
    /// Number of scopes open at loop entry.
    scope_depth: usize,
    breaks: std.ArrayListUnmanaged(State) = .empty,
    conts: std.ArrayListUnmanaged(State) = .empty,
    parent: ?*LoopCtx,
};

const TryCtx = struct {
    /// Number of vars and scopes at entry to the try body.
    depth: u32,
    scope_depth: usize,
    /// Join of the states at every `!` propagation in the try body.
    fail: ?State = null,
};

/// Where a value is being consumed, for alias diagnostics.
const Sink = enum {
    binding,
    argument,
    field,
    element,
    allocation,
    ret,

    fn text(s: Sink) []const u8 {
        return switch (s) {
            .binding => "binding",
            .argument => "call argument",
            .field => "field assignment",
            .element => "array element",
            .allocation => "shared allocation",
            .ret => "return value",
        };
    }
};

/// Owning kinds that cannot be copied implicitly.
const Owning = union(enum) {
    shared,
    weak,
    vec,
    drop_glue: []const u8, // type name
};

// =============================================================================
// Checker
// =============================================================================

pub const Checker = struct {
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    source: []const u8,
    sema: ?*const types.SemContext = null,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    vars: std.ArrayListUnmanaged(Var) = .empty,
    flows: std.ArrayListUnmanaged(Flow) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Loans taken by the current statement and not stored in a var.
    temps: std.ArrayListUnmanaged(Loan) = .empty,
    reachable: bool = true,
    /// Non-zero while computing a loop fixpoint: diagnostics suppressed.
    quiet: u32 = 0,

    func: FnCtx = .{},
    loop: ?*LoopCtx = null,
    try_ctx: ?*TryCtx = null,
    /// Set immediately before walking a lambda literal that sits in an
    /// allowed position (binding RHS, call callee, `*Closure(...)`).
    lambda_ok: bool = false,
    /// Scopes `(lo, hi]` are invisible to name lookup (while re-checking
    /// a deferred body at a scope exit).
    hidden: ?struct { lo: usize, hi: usize } = null,
    /// Walking a deferred body.
    in_defer: bool = false,
    /// Whether the last error was recorded (notes attach only to a
    /// recorded error; duplicates from re-walked code are dropped).
    last_err_kept: bool = false,

    /// Sema lookups, built once: declaration position → symbol, and
    /// method declaration position → function type.
    sym_at: std.AutoHashMapUnmanaged(u32, SymbolId) = .empty,
    method_at: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Checker {
        var c = Checker{
            .gpa = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .source = source,
        };
        try c.scopes.append(allocator, .{ .start = 0, .kind = .function });
        return c;
    }

    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, sema: *const types.SemContext) Error!Checker {
        var c = try init(allocator, source);
        c.sema = sema;
        for (sema.symbols.items, 0..) |sym, i| {
            if (i == 0) continue;
            const gop = try c.sym_at.getOrPut(allocator, sym.decl_pos);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
            if (sym.kind == .nominal_type) {
                for (sym.fields orelse &.{}) |f| {
                    if (f.is_method) try c.method_at.put(allocator, f.decl_pos, f.ty);
                }
            }
        }
        return c;
    }

    pub fn deinit(self: *Checker) void {
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.vars.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        for (self.scopes.items) |*s| s.defers.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
        self.temps.deinit(self.gpa);
        self.sym_at.deinit(self.gpa);
        self.method_at.deinit(self.gpa);
        self.arena_state.deinit();
    }

    pub fn check(self: *Checker, sexp: Sexp) Error!void {
        try self.walkDecl(sexp);
    }

    pub fn hasErrors(self: *const Checker) bool {
        for (self.diagnostics.items) |d| if (d.severity == .@"error") return true;
        return false;
    }

    pub fn writeDiagnostics(self: *const Checker, file_path: []const u8, w: anytype) !void {
        for (self.diagnostics.items) |d| {
            const lc = lineCol(self.source, d.pos);
            const tag = switch (d.severity) {
                .@"error" => "error",
                .note => "  note",
            };
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, lc.line, lc.col, tag, d.message });
        }
    }

    fn arena(self: *Checker) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    // -------------------------------------------------------------------------
    // Diagnostics
    // -------------------------------------------------------------------------

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        self.last_err_kept = false;
        if (self.quiet > 0) return;
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error" and d.pos == pos and std.mem.eql(u8, d.message, msg)) {
                self.gpa.free(msg);
                return;
            }
        }
        try self.diagnostics.append(self.gpa, .{ .severity = .@"error", .pos = pos, .message = msg });
        self.last_err_kept = true;
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.quiet > 0 or !self.last_err_kept) return;
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.diagnostics.append(self.gpa, .{ .severity = .note, .pos = pos, .message = msg });
    }

    /// Note pointing at the move or drop that invalidated `v`.
    fn noteInvalidated(self: *Checker, id: VarId, use_pos: u32) Error!void {
        const v = self.vars.items[id];
        const f = self.flows.items[id];
        const what = if (f.status == .dropped) "dropped" else "moved";
        if (self.loop != null and f.at >= use_pos) {
            try self.note(f.at, "`{s}` was {s} here, in a previous iteration of the loop", .{ v.name, what });
        } else {
            try self.note(f.at, "`{s}` was {s} here", .{ v.name, what });
        }
    }

    fn noteLoan(self: *Checker, loan: Loan) Error!void {
        switch (loan.kind) {
            .read => try self.note(loan.pos, "read borrow taken here", .{}),
            .write => try self.note(loan.pos, "write borrow taken here", .{}),
        }
    }

    // -------------------------------------------------------------------------
    // Vars and scopes
    // -------------------------------------------------------------------------

    fn pushScope(self: *Checker, kind: ScopeKind) Error!void {
        try self.scopes.append(self.gpa, .{ .start = @intCast(self.vars.items.len), .kind = kind });
    }

    /// Leave the innermost scope: run its defers, check that nothing that
    /// survives holds a loan on a var declared in it, then drop its vars.
    fn popScope(self: *Checker) Error!void {
        const idx = self.scopes.items.len - 1;
        if (self.reachable) try self.runDefers(idx);
        var scope = self.scopes.pop().?;
        defer scope.defers.deinit(self.gpa);
        const start = scope.start;
        try self.releaseVarsFrom(start, self.reachable);
        self.vars.shrinkRetainingCapacity(start);
        self.flows.shrinkRetainingCapacity(start);
    }

    /// Remove every loan on vars `>= start` from vars below `start` and
    /// from the temporaries, reporting each surviving loan when `report`.
    fn releaseVarsFrom(self: *Checker, start: u32, report: bool) Error!void {
        for (self.flows.items[0..@min(start, self.flows.items.len)], 0..) |*f, holder| {
            if (!hasLoanFrom(f.loans, start)) continue;
            if (report) {
                for (f.loans) |l| if (l.root >= start) try self.reportShortLived(l, @intCast(holder));
            }
            f.loans = try self.filterLoansBelow(f.loans, start);
        }
        var i: usize = 0;
        while (i < self.temps.items.len) {
            if (self.temps.items[i].root >= start) {
                _ = self.temps.orderedRemove(i);
            } else i += 1;
        }
    }

    fn reportShortLived(self: *Checker, l: Loan, holder: ?VarId) Error!void {
        const root = self.vars.items[l.root];
        try self.err(l.pos, "`{s}` does not live long enough", .{root.name});
        if (holder) |h| {
            const hv = self.vars.items[h];
            if (hv.name.len > 0) {
                try self.note(root.decl, "`{s}` goes out of scope while `{s}` still borrows it", .{ root.name, hv.name });
                return;
            }
        }
        try self.note(root.decl, "`{s}` goes out of scope while still borrowed", .{root.name});
    }

    fn addVar(self: *Checker, v: Var, flow: Flow) Error!VarId {
        const id: VarId = @intCast(self.vars.items.len);
        try self.vars.append(self.gpa, v);
        try self.flows.append(self.gpa, flow);
        return id;
    }

    const Found = struct { id: VarId, crossed: bool };

    /// Find the innermost var named `name`. `crossed` is set when it is a
    /// local of a function enclosing the current closure body.
    fn find(self: *const Checker, name: []const u8) ?Found {
        if (name.len == 0) return null;
        var crossed = false;
        var si = self.scopes.items.len;
        var end: usize = self.vars.items.len;
        while (si > 0) {
            si -= 1;
            const sc = self.scopes.items[si];
            if (self.hidden) |h| if (si > h.lo and si <= h.hi) {
                end = sc.start;
                continue;
            };
            var i = end;
            while (i > sc.start) {
                i -= 1;
                if (std.mem.eql(u8, self.vars.items[i].name, name)) return .{ .id = @intCast(i), .crossed = crossed and si > 0 };
            }
            end = sc.start;
            if (sc.kind == .closure) crossed = true;
        }
        return null;
    }

    /// A module-level binding seen from inside a function body.
    fn isGlobal(self: *const Checker, id: VarId) bool {
        return self.scopes.items.len > 1 and id < self.scopes.items[1].start;
    }

    /// Resolve a value-position name. A local of an enclosing function
    /// seen from inside a closure body is an error: it must be captured.
    fn lookup(self: *Checker, pos: u32, name: []const u8) Error!?VarId {
        const f = self.find(name) orelse return null;
        if (f.crossed) {
            try self.err(pos, "closure body uses `{s}` without capturing it; add it to the capture list (`|+{s}|`, `|<{s}|`, or `|{s}|` for Copy values)", .{ name, name, name, name });
            return null;
        }
        return f.id;
    }

    fn lookupCurrent(self: *Checker, name: []const u8) ?VarId {
        const sc = self.scopes.items[self.scopes.items.len - 1];
        var i = self.vars.items.len;
        while (i > sc.start) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) return @intCast(i);
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // State: snapshot, restore, join
    // -------------------------------------------------------------------------

    fn snapshot(self: *Checker) Error!State {
        return .{
            .flows = try self.arena().dupe(Flow, self.flows.items),
            .temps = try self.arena().dupe(Loan, self.temps.items),
            .reachable = self.reachable,
        };
    }

    fn restore(self: *Checker, s: State) Error!void {
        const n = @min(s.flows.len, self.flows.items.len);
        @memcpy(self.flows.items[0..n], s.flows[0..n]);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, s.temps);
        self.reachable = s.reachable;
    }

    fn unreachableState(self: *Checker) Error!State {
        var s = try self.snapshot();
        s.reachable = false;
        return s;
    }

    /// The single merge operator of the analysis.
    fn join(self: *Checker, a: State, b: State) Error!State {
        if (!a.reachable) return b;
        if (!b.reachable) return a;
        const n = @min(a.flows.len, b.flows.len);
        const flows = try self.arena().alloc(Flow, n);
        for (flows, a.flows[0..n], b.flows[0..n]) |*out, fa, fb| {
            const status: Status = @enumFromInt(@max(@intFromEnum(fa.status), @intFromEnum(fb.status)));
            out.* = .{
                .status = status,
                .at = if (fa.status == status) fa.at else fb.at,
                .loans = try self.unionLoans(fa.loans, fb.loans),
            };
        }
        return .{ .flows = flows, .temps = try self.unionLoans(a.temps, b.temps), .reachable = true };
    }

    fn statesEql(a: State, b: State) bool {
        if (a.reachable != b.reachable) return false;
        if (a.flows.len != b.flows.len) return false;
        for (a.flows, b.flows) |fa, fb| {
            if (fa.status != fb.status) return false;
            if (!loanSetEql(fa.loans, fb.loans)) return false;
        }
        return loanSetEql(a.temps, b.temps);
    }

    /// Restrict a state to the first `len` vars (leaving their scopes).
    fn truncState(self: *Checker, s: State, len: u32) Error!State {
        const flows = try self.arena().dupe(Flow, s.flows[0..@min(len, s.flows.len)]);
        for (flows) |*f| f.loans = try self.filterLoansBelow(f.loans, len);
        return .{ .flows = flows, .temps = try self.filterLoansBelow(s.temps, len), .reachable = s.reachable };
    }

    fn unionLoans(self: *Checker, a: []const Loan, b: []const Loan) Error![]const Loan {
        if (b.len == 0) return a;
        if (a.len == 0) return b;
        var extra: usize = 0;
        for (b) |lb| {
            if (!containsLoan(a, lb)) extra += 1;
        }
        if (extra == 0) return a;
        const out = try self.arena().alloc(Loan, a.len + extra);
        @memcpy(out[0..a.len], a);
        var i = a.len;
        for (b) |lb| {
            if (!containsLoan(a, lb)) {
                out[i] = lb;
                i += 1;
            }
        }
        return out;
    }

    fn filterLoansBelow(self: *Checker, loans: []const Loan, len: u32) Error![]const Loan {
        if (!hasLoanFrom(loans, len)) return loans;
        var out: std.ArrayListUnmanaged(Loan) = .empty;
        for (loans) |l| if (l.root < len) try out.append(self.arena(), l);
        return out.items;
    }

    fn valueUnion(self: *Checker, a: Value, b: Value) Error!Value {
        return .{ .loans = try self.unionLoans(a.loans, b.loans) };
    }

    // -------------------------------------------------------------------------
    // Loan queries
    // -------------------------------------------------------------------------

    const LoanQuery = enum { any, write };

    /// A live, non-external loan on `root` held by a var or a temporary.
    /// Vars that view `skip_alias_of` (payload bindings of that scrutinee)
    /// are ignored.
    fn findLoan(self: *Checker, root: VarId, q: LoanQuery, skip_alias_of: ?VarId) ?Loan {
        for (self.flows.items, self.vars.items) |f, v| {
            if (skip_alias_of != null and v.alias_of == skip_alias_of) continue;
            for (f.loans) |l| if (loanMatches(l, root, q)) return l;
        }
        for (self.temps.items) |l| if (loanMatches(l, root, q)) return l;
        return null;
    }

    fn addTemp(self: *Checker, l: Loan) Error!void {
        try self.temps.append(self.gpa, l);
    }

    /// Loans carried by the current value of var `id`.
    fn varValue(self: *Checker, id: VarId) Value {
        const v = self.vars.items[id];
        if (!v.closure and !self.mayCarryBorrow(v.ty)) return .{};
        return .{ .loans = self.flows.items[id].loans };
    }

    // -------------------------------------------------------------------------
    // Declarations and functions
    // -------------------------------------------------------------------------

    fn walkDecl(self: *Checker, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return;
        const items = sexp.list;
        switch (items[0].tag) {
            .@"module" => for (items[1..]) |c| try self.walkDecl(c),
            .@"fun", .@"sub" => if (items.len >= 4) try self.walkFun(items[1], items[2], items[3], items[4..]),
            .@"drop_decl" => if (items.len >= 3) try self.walkFun(.nil, items[1], .nil, items[2..3]),
            .@"struct", .@"enum", .@"errors", .@"generic_type" => for (items[1..]) |c| try self.walkDecl(c),
            .@"pub", .@"export", .@"packed", .@"callconv", .@"extern" => {
                if (items.len >= 2) try self.walkDecl(items[items.len - 1]);
            },
            .@"test" => if (items.len >= 2) try self.walkFun(.nil, .nil, .nil, items[items.len - 1 ..]),
            .@"use", .@"type", .@"opaque", .@"extern_fun", .@"extern_sub", .@"variant", .@":" => {},
            else => try self.walkStmt(sexp),
        }
    }

    /// Walk a function, method, drop body or closure body. `body` is empty
    /// for body-less declarations.
    fn walkFun(self: *Checker, name: Sexp, params: Sexp, returns: Sexp, body: []const Sexp) Error!void {
        if (body.len == 0) return;
        const saved_func = self.func;
        const saved_loop = self.loop;
        const saved_try = self.try_ctx;
        const saved_reachable = self.reachable;
        defer {
            self.func = saved_func;
            self.loop = saved_loop;
            self.try_ctx = saved_try;
            self.reachable = saved_reachable;
        }
        const ret_ty = self.fnReturnType(name);
        const returns_value = returns != .nil and !self.isVoid(ret_ty);
        self.func = .{ .ret_may_borrow = returns_value and self.returnMayBorrow(ret_ty, returns) };
        self.loop = null;
        self.try_ctx = null;
        self.reachable = true;

        try self.pushScope(.function);
        if (params == .list) for (params.list) |p| try self.bindParam(p);
        try self.walkBody(body[0], returns_value);
        try self.popScope();
    }

    /// Walk a function body in the current scope. When the function
    /// returns a value, its last expression is the return value.
    fn walkBody(self: *Checker, body: Sexp, returns_value: bool) Error!void {
        const stmts: []const Sexp = if (isTag(body, .@"block")) body.list[1..] else (&body)[0..1];
        for (stmts, 0..) |stmt, i| {
            if (!self.reachable) break;
            if (returns_value and i == stmts.len - 1 and isValueExpr(stmt)) {
                try self.walkReturnValue(stmt);
            } else {
                try self.walkStmt(stmt);
            }
        }
    }

    fn bindParam(self: *Checker, p: Sexp) Error!void {
        var name_node: Sexp = .nil;
        var type_node: Sexp = .nil;
        var sugar: Ref = .none;
        switch (p) {
            .src => name_node = p,
            .list => |items| {
                if (items.len >= 2 and items[0] == .tag) {
                    switch (items[0].tag) {
                        .@":", .pre_param, .default, .aligned => {
                            name_node = items[1];
                            if (items.len >= 3) type_node = items[2];
                        },
                        // `?self` / `!self` sugar.
                        .@"read" => {
                            name_node = items[1];
                            sugar = .read;
                        },
                        .@"write" => {
                            name_node = items[1];
                            sugar = .write;
                        },
                        else => {},
                    }
                }
            },
            else => return,
        }
        if (name_node != .src) return;
        const pos = name_node.src.pos;
        const ty = self.symType(pos);
        var ref = sugar;
        if (ref == .none) ref = self.refOfType(ty);
        if (ref == .none) ref = refOfTypeSexp(type_node);
        const id = try self.addVar(.{
            .name = self.text(name_node),
            .decl = pos,
            .ty = ty,
            .kind = .param,
            .ref = ref,
        }, .{});
        // Borrows handed in by the caller: an external loan on the param
        // itself marks them as returnable and conflict-free.
        if (ref != .none or (ty != null and self.mayCarryBorrow(ty))) {
            const loans = try self.arena().alloc(Loan, 1);
            loans[0] = .{ .root = id, .kind = if (ref == .write) .write else .read, .pos = pos, .ext = true };
            self.flows.items[id].loans = loans;
        }
    }

    // -------------------------------------------------------------------------
    // Statements and blocks
    // -------------------------------------------------------------------------

    fn walkStmt(self: *Checker, stmt: Sexp) Error!void {
        _ = try self.walkStmtValue(stmt);
    }

    /// Walk one statement; its temporary borrows end with it.
    fn walkStmtValue(self: *Checker, stmt: Sexp) Error!Value {
        if (!self.reachable) return .{};
        const saved = try self.arena().dupe(Loan, self.temps.items);
        const v = try self.walk(stmt);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, try self.filterLoansBelow(saved, @intCast(self.vars.items.len)));
        return v;
    }

    /// Walk a `(block ...)` in its own scope; its value is the value of
    /// its last statement, which may not borrow the block's own locals.
    fn walkBlock(self: *Checker, stmts: []const Sexp) Error!Value {
        try self.pushScope(.block);
        var v: Value = .{};
        for (stmts, 0..) |s, i| {
            if (!self.reachable) break;
            if (i == stmts.len - 1) v = try self.walkStmtValue(s) else try self.walkStmt(s);
        }
        v = try self.checkValueEscapesScope(v);
        try self.popScope();
        return if (self.reachable) v else .{};
    }

    /// Report loans in `v` on vars of the innermost scope and drop them.
    fn checkValueEscapesScope(self: *Checker, v: Value) Error!Value {
        if (!self.reachable) return .{};
        const start = self.scopes.items[self.scopes.items.len - 1].start;
        if (!hasLoanFrom(v.loans, start)) return v;
        for (v.loans) |l| if (l.root >= start) try self.reportShortLived(l, null);
        return .{ .loans = try self.filterLoansBelow(v.loans, start) };
    }

    // -------------------------------------------------------------------------
    // Expression walk
    // -------------------------------------------------------------------------

    fn walk(self: *Checker, sexp: Sexp) Error!Value {
        switch (sexp) {
            .src => return self.walkName(sexp, false),
            .list => {},
            else => return .{},
        }
        const items = sexp.list;
        if (items.len == 0 or items[0] != .tag) return .{};
        return switch (items[0].tag) {
            .@"fun", .@"sub", .@"drop_decl", .@"struct", .@"enum", .@"errors" => blk: {
                try self.walkDecl(sexp);
                break :blk .{};
            },
            .@"block" => self.walkBlock(items[1..]),
            .@"set" => blk: {
                try self.walkSet(items);
                break :blk .{};
            },
            .@"drop" => blk: {
                try self.walkDrop(items);
                break :blk .{};
            },
            .@"move" => if (items.len >= 2) self.walkMove(items[1], .move) else .{},
            .@"read" => if (items.len >= 2) self.walkBorrow(items[1], .read) else .{},
            .@"write" => if (items.len >= 2) self.walkBorrow(items[1], .write) else .{},
            .@"clone", .@"weak" => self.walkCloneWeak(items),
            .@"pin", .@"raw" => if (items.len >= 2) self.walk(items[1]) else .{},
            .@"share" => self.walkShare(items),
            .@"lambda" => self.walkLambda(items),
            .@"if" => self.walkIf(items),
            .@"ternary" => self.walkTernary(items),
            .@"while" => blk: {
                try self.walkWhile(items);
                break :blk .{};
            },
            .@"for" => blk: {
                try self.walkFor(items);
                break :blk .{};
            },
            .@"labeled" => if (items.len >= 3) self.walk(items[2]) else .{},
            .@"match" => self.walkMatch(items),
            .@"return" => blk: {
                try self.walkReturn(items);
                break :blk .{};
            },
            .@"break" => blk: {
                try self.walkJump(items, .brk);
                break :blk .{};
            },
            .@"continue" => blk: {
                try self.walkJump(items, .cont);
                break :blk .{};
            },
            .@"try_block" => blk: {
                try self.walkTryBlock(items);
                break :blk .{};
            },
            .@"catch" => self.walkCatch(items),
            .@"propagate", .@"try" => self.walkPropagate(items),
            .@"defer", .@"errdefer" => blk: {
                try self.walkDefer(items);
                break :blk .{};
            },
            .@"call" => self.walkCall(items),
            .@"member" => self.walkMember(sexp),
            .@"index" => self.walkMember(sexp),
            .@"deref" => if (items.len >= 2) self.walk(items[1]) else .{},
            .@"kwarg" => if (items.len >= 3) self.walkConsumed(items[2], .argument) else .{},
            .@"record" => blk: {
                var v: Value = .{};
                for (items[2..]) |m| v = try self.valueUnion(v, try self.walk(m));
                break :blk v;
            },
            .@"array" => blk: {
                var v: Value = .{};
                for (items[1..]) |e| v = try self.valueUnion(v, try self.walkConsumed(e, .element));
                break :blk v;
            },
            .@"raw_block" => if (items.len >= 2) self.walk(items[1]) else .{},
            .@"enum_lit", .@"use", .@"type", .@"generic_type", .@"generic_inst", .@"opaque" => .{},
            // Operators on values produce fresh Copy results.
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"**", .@"neg", .@"not", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@">>", .@".." => blk: {
                for (items[1..]) |c| _ = try self.walk(c);
                break :blk .{};
            },
            else => blk: {
                var v: Value = .{};
                for (items[1..]) |c| v = try self.valueUnion(v, try self.walk(c));
                break :blk v;
            },
        };
    }

    /// Walk an expression in a position that takes ownership of its value.
    fn walkConsumed(self: *Checker, expr: Sexp, sink: Sink) Error!Value {
        if (isLambda(expr)) return self.walk(expr); // reported by walkLambda
        try self.checkNoImplicitCopy(expr, sink, false);
        return self.walk(expr);
    }

    /// A bare use of a name.
    fn walkName(self: *Checker, node: Sexp, as_callee: bool) Error!Value {
        const pos = node.src.pos;
        const name = self.text(node);
        const id = (try self.lookup(pos, name)) orelse return .{};
        const v = self.vars.items[id];
        if (v.closure and !as_callee) {
            try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or aliased; call it as `{s}()`, or wrap the literal in `*Closure(...)` to pass it around", .{ name, name });
            return .{};
        }
        try self.checkReadable(id, pos);
        return self.varValue(id);
    }

    /// Reading `id`: it must be live and not write-borrowed.
    fn checkReadable(self: *Checker, id: VarId, pos: u32) Error!void {
        const v = self.vars.items[id];
        if (self.isCopy(v.ty)) return;
        if (!try self.checkLive(id, pos)) return;
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "use of `{s}` while a write borrow is live", .{v.name});
            try self.noteLoan(l);
        }
    }

    /// Report a use of a moved or dropped var. Returns whether it is live.
    fn checkLive(self: *Checker, id: VarId, pos: u32) Error!bool {
        const f = self.flows.items[id];
        const name = self.vars.items[id].name;
        switch (f.status) {
            .live => return true,
            .moved => try self.err(pos, "use of `{s}` after move", .{name}),
            .dropped => try self.err(pos, "use of `{s}` after drop", .{name}),
        }
        try self.noteInvalidated(id, pos);
        return false;
    }

    // -------------------------------------------------------------------------
    // Places: `x`, `x.f`, `x[i]`
    // -------------------------------------------------------------------------

    const Place = struct {
        root: VarId,
        whole: bool,
        /// Some step goes through an element index.
        indexed: bool = false,
        /// Some step dereferences a shared handle.
        through_shared: bool = false,
        /// Some step goes through a borrow (a borrowed root or a
        /// borrow-typed field).
        through_borrow: bool = false,
    };

    fn resolvePlace(self: *Checker, e: Sexp) Error!?Place {
        switch (e) {
            .src => {
                const id = (try self.lookup(e.src.pos, self.text(e))) orelse return null;
                return .{ .root = id, .whole = true, .through_borrow = self.vars.items[id].ref != .none };
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return null;
                switch (items[0].tag) {
                    .@"member", .@"index" => {
                        var p = (try self.resolvePlace(items[1])) orelse return null;
                        p.whole = false;
                        if (items[0].tag == .@"index") p.indexed = true;
                        if (self.exprType(items[1])) |t| {
                            const ty = self.typeOf(t);
                            if (ty == .shared) p.through_shared = true;
                            if (ty == .borrow_read or ty == .borrow_write) p.through_borrow = true;
                        }
                        return p;
                    },
                    .@"deref" => return self.resolvePlace(items[1]),
                    else => return null,
                }
            },
            else => return null,
        }
    }

    /// Walk the index expressions inside a place.
    fn walkPlaceIndices(self: *Checker, e: Sexp) Error!void {
        if (e != .list or e.list.len < 2 or e.list[0] != .tag) return;
        const items = e.list;
        switch (items[0].tag) {
            .@"member", .@"deref" => try self.walkPlaceIndices(items[1]),
            .@"index" => {
                try self.walkPlaceIndices(items[1]);
                for (items[2..]) |i| _ = try self.walk(i);
            },
            else => {},
        }
    }

    fn walkMember(self: *Checker, e: Sexp) Error!Value {
        const items = e.list;
        if (items.len < 2) return .{};
        const obj = try self.walk(items[1]);
        if (items[0].tag == .@"index") for (items[2..]) |i| {
            _ = try self.walk(i);
        };
        if (!self.mayCarryBorrow(self.exprType(e))) return .{};
        return obj;
    }

    // -------------------------------------------------------------------------
    // Borrow, move, clone, drop
    // -------------------------------------------------------------------------

    fn walkBorrow(self: *Checker, inner: Sexp, kind: LoanKind) Error!Value {
        const place = (try self.resolvePlace(inner)) orelse return self.walk(inner);
        try self.walkPlaceIndices(inner);
        const id = place.root;
        const v = self.vars.items[id];
        const pos = innerPos(inner);
        if (v.closure) {
            try self.err(pos, "closure `{s}` cannot be borrowed; call it as `{s}()`", .{ v.name, v.name });
            return .{};
        }
        if (!try self.checkLive(id, pos)) return .{};
        switch (kind) {
            .read => if (self.findLoan(id, .write, null)) |l| {
                try self.err(pos, "cannot read-borrow `{s}` while a write borrow is live", .{v.name});
                try self.noteLoan(l);
                return .{};
            },
            .write => if (self.findLoan(id, .any, null)) |l| {
                switch (l.kind) {
                    .read => try self.err(pos, "cannot write-borrow `{s}` while a read borrow is live", .{v.name}),
                    .write => try self.err(pos, "cannot take a second write borrow on `{s}`", .{v.name}),
                }
                try self.noteLoan(l);
                return .{};
            },
        }
        const loan: Loan = .{ .root = id, .kind = kind, .pos = pos };
        try self.addTemp(loan);
        return self.reborrow(id, loan);
    }

    /// The loans of a borrow of (a path inside) var `id`. Borrowing
    /// through a read borrow copies that borrow; borrowing an owned value
    /// or through a write borrow borrows the var itself.
    fn reborrow(self: *Checker, id: VarId, loan: Loan) Error!Value {
        const v = self.vars.items[id];
        const held = self.flows.items[id].loans;
        if (v.ref == .read or v.alias_of != null) return .{ .loans = held };
        const one = try self.arena().alloc(Loan, 1);
        one[0] = loan;
        if (v.ref == .write) return .{ .loans = try self.unionLoans(one, held) };
        return .{ .loans = one };
    }

    const MoveVerb = enum {
        move,
        capture,

        fn text(m: MoveVerb) []const u8 {
            return switch (m) {
                .move => "move",
                .capture => "move-capture",
            };
        }
    };

    /// `<e`: move a whole binding, or reject moving out of a path.
    fn walkMove(self: *Checker, inner: Sexp, verb: MoveVerb) Error!Value {
        const place = (try self.resolvePlace(inner)) orelse return self.walk(inner);
        if (place.whole) return self.moveVar(place.root, innerPos(inner), verb);
        return self.movePath(inner, place);
    }

    fn moveVar(self: *Checker, id: VarId, pos: u32, verb: MoveVerb) Error!Value {
        const v = self.vars.items[id];
        const vt = verb.text();
        if (v.closure) {
            try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or aliased; call it as `{s}()`, or wrap the literal in `*Closure(...)` to pass it around", .{ v.name, v.name });
            return .{};
        }
        if (try self.rejectBorrowedView(id, pos, vt)) return .{};
        if (verb == .capture and v.kind == .param and v.ref != .none) {
            try self.err(pos, "cannot move-capture borrowed parameter `{s}`; the caller still owns it. Capture a clone with `|+{s}|`", .{ v.name, v.name });
            return .{};
        }
        if (!self.flowLive(id)) {
            if (verb == .capture) {
                try self.err(pos, "cannot capture `{s}` after {s}", .{ v.name, if (self.flows.items[id].status == .dropped) "drop" else "move" });
                try self.noteInvalidated(id, pos);
            } else {
                _ = try self.checkLive(id, pos);
            }
            return .{};
        }
        const value = self.varValue(id);
        if (self.isCopy(v.ty)) return value;
        if (try self.rejectGlobal(id, pos, vt)) return .{};

        if (v.alias_of) |root| return self.movePayload(id, root, pos, value);

        if (self.findLoan(id, .any, null)) |l| {
            switch (l.kind) {
                .read => try self.err(pos, "cannot {s} `{s}` while it is read-borrowed", .{ vt, v.name }),
                .write => try self.err(pos, "cannot {s} `{s}` while it is write-borrowed", .{ vt, v.name }),
            }
            try self.noteLoan(l);
            return .{};
        }
        // Moving a read borrow copies it; it stays usable.
        if (v.ref == .read) return value;
        self.markInvalid(id, .moved, pos);
        return value;
    }

    /// Move a match payload binding out of its scrutinee.
    fn movePayload(self: *Checker, id: VarId, root: VarId, pos: u32, value: Value) Error!Value {
        const v = self.vars.items[id];
        const r = self.vars.items[root];
        switch (v.via) {
            .borrowed => {
                try self.err(pos, "cannot move out of `{s}`: it is borrowed from `{s}`", .{ v.name, r.name });
                return .{};
            },
            .shared => {
                try self.err(pos, "cannot move out of `{s}`: `{s}` is a shared handle and other handles may still use it", .{ v.name, r.name });
                return .{};
            },
            .owned => {},
        }
        if (!self.flowLive(root)) {
            try self.err(pos, "cannot move `{s}` out of `{s}`: `{s}` was already moved", .{ v.name, r.name, r.name });
            try self.noteInvalidated(root, pos);
            return .{};
        }
        if (self.findLoan(root, .any, root)) |l| {
            try self.err(pos, "cannot move `{s}` out of `{s}` while `{s}` is borrowed", .{ v.name, r.name, r.name });
            try self.noteLoan(l);
            return .{};
        }
        // Moving the payload consumes the scrutinee.
        self.markInvalid(root, .moved, pos);
        self.markInvalid(id, .moved, pos);
        return value;
    }

    /// `<p.a` / `<v[i]`: only Copy values can leave a field or element.
    fn movePath(self: *Checker, inner: Sexp, place: Place) Error!Value {
        const value = try self.walk(inner);
        const ty = self.exprType(inner);
        if (ty != null and self.isCopy(ty)) return value;
        if (ty != null and self.refOfType(ty) == .read) return value;
        const path = try self.placeText(inner);
        const root = self.vars.items[place.root].name;
        const pos = innerPos(inner);
        if (place.through_borrow) {
            try self.err(pos, "cannot move out of `{s}`: `{s}` is borrowed", .{ path, root });
        } else if (place.through_shared) {
            try self.err(pos, "cannot move out of `{s}`: it is reached through a shared handle and other handles may still use it; clone it with `+{s}`", .{ path, path });
        } else if (place.indexed) {
            try self.err(pos, "cannot move out of `{s}`: elements cannot be moved out of their container", .{path});
        } else {
            try self.err(pos, "cannot move out of `{s}`: `{s}` would still drop it (partial moves are not supported); move `{s}` whole instead", .{ path, root, root });
        }
        return .{};
    }

    fn markInvalid(self: *Checker, id: VarId, status: Status, pos: u32) void {
        self.flows.items[id] = .{ .status = status, .at = pos };
    }

    fn flowLive(self: *Checker, id: VarId) bool {
        return self.flows.items[id].status == .live;
    }

    /// Loop elements and captured resources are views of a slot owned
    /// elsewhere: they cannot be consumed. Returns true if rejected.
    fn rejectBorrowedView(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
        const v = self.vars.items[id];
        if (v.loop_borrow) {
            try self.err(pos, "cannot {s} loop-borrow alias `{s}`; a `for x in ?vec` element is a read borrow of the Vec slot and cannot be cloned, moved, dropped, or stored", .{ op, v.name });
            return true;
        }
        if (v.capture_resource) {
            try self.err(pos, "cannot {s} captured resource `{s}`; closure captures are owned by the closure environment, which may be invoked again. Use `+{s}` to clone a fresh handle, `~{s}` for a weak reference, or call its methods", .{ op, v.name, v.name, v.name });
            return true;
        }
        return false;
    }

    /// A module-level binding outlives every call of the function using
    /// it: a function cannot consume or replace it.
    fn rejectGlobal(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
        if (!self.isGlobal(id)) return false;
        const name = self.vars.items[id].name;
        try self.err(pos, "cannot {s} module-level `{s}` inside a function; later calls would still use it", .{ op, name });
        return true;
    }

    fn walkCloneWeak(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 2) return .{};
        const inner = items[1];
        if (inner == .src) {
            if (try self.lookup(inner.src.pos, self.text(inner))) |id| {
                const v = self.vars.items[id];
                if (v.loop_borrow) {
                    const op = if (items[0].tag == .@"clone") "clone" else "take a weak reference to";
                    _ = try self.rejectBorrowedView(id, inner.src.pos, op);
                    return .{};
                }
            }
        }
        return self.walk(inner);
    }

    fn walkDrop(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const target = items[1];
        if (target != .src) {
            _ = try self.walk(target);
            try self.err(innerPos(target), "only a whole binding can be dropped", .{});
            return;
        }
        const pos = target.src.pos;
        const name = self.text(target);
        const id = (try self.lookup(pos, name)) orelse return;
        const v = self.vars.items[id];
        if (try self.rejectBorrowedView(id, pos, "drop")) return;
        if (v.kind == .param and v.ref != .none) {
            try self.err(pos, "cannot drop borrowed parameter `{s}`; the caller owns it", .{name});
            return;
        }
        if (try self.rejectGlobal(id, pos, "drop")) return;
        switch (self.flows.items[id].status) {
            .live => {},
            .moved => {
                try self.err(pos, "cannot drop `{s}` after it was moved", .{name});
                try self.noteInvalidated(id, pos);
                return;
            },
            .dropped => {
                try self.err(pos, "cannot drop `{s}` twice", .{name});
                try self.noteInvalidated(id, pos);
                return;
            },
        }
        if (v.alias_of) |root| {
            _ = try self.movePayload(id, root, pos, .{});
            if (!self.flowLive(id)) self.markInvalid(id, .dropped, pos);
            return;
        }
        if (self.findLoan(id, .any, null)) |l| {
            try self.err(pos, "cannot drop `{s}` while borrows are live", .{name});
            try self.noteLoan(l);
            return;
        }
        self.markInvalid(id, .dropped, pos);
    }

    // -------------------------------------------------------------------------
    // Implicit copies of owning values
    // -------------------------------------------------------------------------

    /// Reject an implicit copy of an owning value in a consuming position.
    /// `top_return`: a bare name directly in return position is a move.
    fn checkNoImplicitCopy(self: *Checker, expr: Sexp, sink: Sink, top_return: bool) Error!void {
        switch (expr) {
            .src => {
                const f = self.find(self.text(expr)) orelse return;
                if (f.crossed) return;
                const v = self.vars.items[f.id];
                const pos = expr.src.pos;
                const name = v.name;
                if (v.closure) return; // reported by walkName
                if (v.loop_borrow) {
                    try self.err(pos, "bare use of loop-borrow alias `{s}` in {s} would smuggle the borrowed handle past the loop; a `for x in ?vec` element is a read borrow of the Vec slot and cannot be cloned, moved, dropped, or stored", .{ name, sink.text() });
                    return;
                }
                if (v.capture_resource) {
                    try self.err(pos, "bare use of captured resource `{s}` in {s} would smuggle the handle out of the closure environment; use `+{s}` to clone a fresh handle, or `~{s}` for a weak reference", .{ name, sink.text(), name, name });
                    return;
                }
                if (top_return) return;
                if (self.owningKind(v.ty)) |k| return self.reportAlias(pos, name, true, k, sink);
                if (sink == .argument) return;
                if (v.ref == .write) {
                    try self.err(pos, "bare use of write borrow `{s}` in {s} would duplicate a unique borrow; use `<{s}` to move it", .{ name, sink.text(), name });
                } else if (self.carriesWriteBorrow(v.ty)) {
                    try self.err(pos, "bare use of `{s}` in {s} would duplicate the write borrow it holds; use `<{s}` to move it", .{ name, sink.text(), name });
                }
            },
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return;
                switch (items[0].tag) {
                    .@"member", .@"index" => {
                        const ty = self.exprType(expr);
                        if (self.owningKind(ty)) |k| {
                            return self.reportAlias(innerPos(expr), try self.placeText(expr), false, k, sink);
                        }
                        if (sink != .argument and self.carriesWriteBorrow(ty)) {
                            try self.err(innerPos(expr), "bare use of `{s}` in {s} would duplicate a write borrow; a field cannot be moved out of its parent", .{ try self.placeText(expr), sink.text() });
                        }
                    },
                    // A value returned through a branch moves out, like a bare return.
                    .@"if" => for (items[2..]) |b| try self.checkNoImplicitCopy(tailOf(b), sink, top_return),
                    .@"ternary" => for (items[2..]) |b| try self.checkNoImplicitCopy(tailOf(b), sink, top_return),
                    .@"match" => for (items[2..]) |arm| {
                        if (isTag(arm, .@"arm") and arm.list.len >= 2) {
                            try self.checkNoImplicitCopy(tailOf(arm.list[arm.list.len - 1]), sink, top_return);
                        }
                    },
                    .@"block" => if (items.len >= 2) try self.checkNoImplicitCopy(tailOf(expr), sink, top_return),
                    // Operators that yield one of their operands.
                    .@"??" => for (items[1..]) |c| try self.checkNoImplicitCopy(c, sink, false),
                    .@"catch" => if (items.len >= 3) {
                        try self.checkNoImplicitCopy(items[1], sink, false);
                        try self.checkNoImplicitCopy(tailOf(items[items.len - 1]), sink, false);
                    },
                    .@"propagate", .@"try" => try self.checkNoImplicitCopy(items[1], sink, false),
                    else => {},
                }
            },
            else => {},
        }
    }

    fn reportAlias(self: *Checker, pos: u32, what: []const u8, is_name: bool, k: Owning, sink: Sink) Error!void {
        const ctx = sink.text();
        switch (k) {
            .shared, .weak => {
                const kind = if (k == .shared) "shared (`*T`)" else "weak (`~T`)";
                if (is_name) {
                    try self.err(pos, "bare use of {s} handle `{s}` in {s} would alias the handle; use `<{s}` to move or `+{s}` to clone", .{ kind, what, ctx, what, what });
                } else {
                    try self.err(pos, "bare use of {s} handle `{s}` in {s} would alias the handle; use `+{s}` to clone", .{ kind, what, ctx, what });
                }
            },
            .vec => if (is_name) {
                try self.err(pos, "bare use of `Vec` value `{s}` in {s} would copy the buffer pointer and double-free on scope exit; use `<{s}` to move ownership", .{ what, ctx, what });
            } else {
                try self.err(pos, "bare use of `Vec` value `{s}` in {s} would copy the buffer pointer; a field cannot be moved out of its parent", .{ what, ctx });
            },
            .drop_glue => |tname| if (is_name) {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue (resource fields or a user `drop` declaration), so two bindings would each run the destructor. Use `<{s}` to move ownership", .{ tname, what, ctx, tname, what });
            } else {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue and a field cannot be moved out of its parent", .{ tname, what, ctx, tname });
            },
        }
    }

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    fn walkSet(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 5) return;
        const kind = try rig.bindingKindOf(items[1]);
        const target = items[2];
        const expr = items[4];
        const compound = switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=" => true,
            else => false,
        };

        if (target != .src) return self.walkFieldAssign(target, expr, kind == .@"move");

        const pos = target.src.pos;
        const name = self.text(target);
        const is_lambda = isLambda(expr);
        const value: Value = if (kind == .@"move")
            try self.walkMove(expr, .move)
        else if (compound)
            try self.walk(expr)
        else if (is_lambda) blk: {
            self.lambda_ok = true;
            break :blk try self.walk(expr);
        } else try self.walkConsumed(expr, .binding);

        if (std.mem.eql(u8, name, "_")) return;

        switch (kind) {
            .shadow => try self.bindNew(name, pos, false, is_lambda, value),
            .fixed => {
                if (self.lookupCurrent(name)) |prev| {
                    try self.err(pos, "binding `{s}` already exists in this scope", .{name});
                    try self.note(self.vars.items[prev].decl, "previous binding here", .{});
                    return;
                }
                try self.bindNew(name, pos, true, is_lambda, value);
            },
            .default, .@"move" => {
                if (try self.lookup(pos, name)) |id| {
                    try self.reassign(id, pos, value);
                } else if (self.find(name) == null) {
                    try self.bindNew(name, pos, false, is_lambda, value);
                }
            },
            .@"+=", .@"-=", .@"*=", .@"/=" => {
                const id = (try self.lookup(pos, name)) orelse {
                    if (self.find(name) == null) try self.err(pos, "compound assignment on undefined `{s}`", .{name});
                    return;
                };
                try self.checkReadable(id, pos);
                try self.checkAssignable(id, pos);
            },
        }
    }

    fn bindNew(self: *Checker, name: []const u8, pos: u32, fixed: bool, closure: bool, value: Value) Error!void {
        const ty = self.symType(pos);
        _ = try self.addVar(.{
            .name = name,
            .decl = pos,
            .ty = ty,
            .ref = self.refOfType(ty),
            .fixed = fixed or closure,
            .closure = closure,
        }, .{ .loans = if (closure or self.mayCarryBorrow(ty)) value.loans else &.{} });
    }

    /// Checks shared by reassignment and compound assignment.
    fn checkAssignable(self: *Checker, id: VarId, pos: u32) Error!void {
        const v = self.vars.items[id];
        if (v.closure) {
            try self.err(pos, "cannot reassign closure binding `{s}`; closure bindings are fixed", .{v.name});
            try self.note(v.decl, "`{s}` was bound here as a closure", .{v.name});
            return;
        }
        if (v.fixed) {
            try self.err(pos, "cannot reassign fixed binding `{s}`", .{v.name});
            try self.note(v.decl, "`{s}` was bound here with `=!`", .{v.name});
            return;
        }
        if (try self.rejectBorrowedView(id, pos, "reassign")) return;
        if (!self.isCopy(v.ty) and try self.rejectGlobal(id, pos, "reassign")) return;
        if (v.alias_of != null and !self.isCopy(v.ty)) {
            try self.err(pos, "cannot reassign match binding `{s}`; it views the matched value", .{v.name});
            return;
        }
        if (self.findLoan(id, .any, null)) |l| {
            try self.err(pos, "cannot reassign `{s}` while borrows are live", .{v.name});
            try self.noteLoan(l);
        }
    }

    fn reassign(self: *Checker, id: VarId, pos: u32, value: Value) Error!void {
        const before = self.diagnostics.items.len;
        try self.checkAssignable(id, pos);
        if (self.diagnostics.items.len != before and self.quiet == 0) return;
        const v = self.vars.items[id];
        if (v.closure or v.fixed or v.loop_borrow or v.capture_resource) return;
        if (self.isGlobal(id) and !self.isCopy(v.ty)) return;
        if (self.findLoan(id, .any, null) != null) return;
        // The old value is dropped (if still owned) and the binding is
        // live again with the new value.
        self.flows.items[id] = .{ .loans = if (self.mayCarryBorrow(v.ty)) value.loans else &.{} };
    }

    /// `p.f = e` / `v[i] = e`.
    fn walkFieldAssign(self: *Checker, target: Sexp, expr: Sexp, is_move: bool) Error!void {
        const value = if (is_move) try self.walkMove(expr, .move) else try self.walkConsumed(expr, .field);
        const place = (try self.resolvePlace(target)) orelse {
            _ = try self.walk(target);
            return;
        };
        try self.walkPlaceIndices(target);
        const id = place.root;
        const pos = innerPos(target);
        if (!try self.checkLive(id, pos)) return;
        const v = self.vars.items[id];
        if (self.findLoan(id, .any, null)) |l| {
            try self.err(pos, "cannot assign to `{s}` while `{s}` is borrowed", .{ try self.placeText(target), v.name });
            try self.noteLoan(l);
            return;
        }
        if (value.loans.len == 0 or !self.mayCarryBorrow(self.exprType(target))) return;
        if (v.ref != .none or place.through_borrow or place.through_shared or self.isGlobal(id)) {
            // Stored into something the caller owns: only borrows the
            // caller handed in may go there.
            for (value.loans) |l| if (self.isLocalLoan(l) or self.isGlobal(id)) {
                try self.err(pos, "cannot store a borrow of `{s}` in `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, try self.placeText(target), v.name });
                return;
            };
            return;
        }
        self.flows.items[id].loans = try self.unionLoans(self.flows.items[id].loans, value.loans);
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    fn walkCall(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 2) return .{};
        const callee = items[1];
        const args = items[2..];
        var result: Value = .{};

        // Method call: the receiver is borrowed for the whole call. A
        // write receiver is reserved (read) while the arguments are
        // evaluated and must be otherwise unborrowed when the call starts.
        var recv_root: ?VarId = null;
        var recv_mode: types.MethodReceiver = .read;
        var reservation: usize = 0;
        if (isTag(callee, .@"member") and callee.list.len >= 3) {
            var obj = callee.list[1];
            const method = self.text(callee.list[2]);
            var explicit_write = false;
            if ((isTag(obj, .@"write") or isTag(obj, .@"read")) and obj.list.len >= 2) {
                explicit_write = isTag(obj, .@"write");
                obj = obj.list[1];
            }
            recv_mode = if (explicit_write) .write else self.receiverMode(obj, method);
            const place = if (recv_mode == .value) null else try self.resolvePlace(obj);
            if (place) |p| {
                const recv_val = try self.walk(obj);
                const id = p.root;
                if (self.flowLive(id) and !self.isCopy(self.vars.items[id].ty)) {
                    const pos = innerPos(obj);
                    reservation = self.temps.items.len;
                    try self.addTemp(.{ .root = id, .kind = .read, .pos = pos });
                    recv_root = id;
                    const kind: LoanKind = if (recv_mode == .write) .write else .read;
                    result = try self.valueUnion(recv_val, try self.reborrow(id, .{ .root = id, .kind = kind, .pos = pos }));
                }
            } else {
                result = try self.walk(callee.list[1]);
            }
        } else if (callee == .src) {
            _ = try self.walkName(callee, true);
        } else if (isLambda(callee)) {
            self.lambda_ok = true;
            _ = try self.walk(callee);
        } else {
            _ = try self.walk(callee);
        }

        var stored: Value = .{};
        for (args) |a| {
            const v = try self.walkConsumed(a, .argument);
            stored = try self.valueUnion(stored, v);
        }
        result = try self.valueUnion(result, stored);

        // The callee may store what its arguments borrow into anything it
        // can mutate: the receiver, `!x` arguments, and shared handles.
        if (stored.loans.len > 0) {
            if (recv_root) |id| {
                const obj = callee.list[1];
                if (self.mayCarryBorrow(self.exprType(obj))) try self.absorbLoans(id, stored, innerPos(obj));
            }
            for (args) |a| {
                const arg = if (isTag(a, .@"kwarg") and a.list.len >= 3) a.list[2] else a;
                if (try self.containerRoot(arg)) |id| try self.absorbLoans(id, stored, innerPos(arg));
            }
        }

        if (recv_root) |id| if (recv_mode == .write) {
            const name = self.vars.items[id].name;
            const conflict: ?Loan = blk: {
                for (self.temps.items, 0..) |l, i| {
                    if (i != reservation and loanMatches(l, id, .any)) break :blk l;
                }
                for (self.flows.items) |f| for (f.loans) |l| {
                    if (loanMatches(l, id, .any)) break :blk l;
                };
                break :blk null;
            };
            if (conflict) |l| {
                const pos = innerPos(callee.list[1]);
                switch (l.kind) {
                    .read => try self.err(pos, "cannot write-borrow `{s}` while a read borrow is live", .{name}),
                    .write => try self.err(pos, "cannot take a second write borrow on `{s}`", .{name}),
                }
                try self.noteLoan(l);
            }
        };

        if (!self.mayCarryBorrow(self.callResultType(items))) return .{};
        return result;
    }

    /// The var behind an argument the callee can store into: `!x`, or a
    /// shared handle or write borrow passed by name (or cloned).
    fn containerRoot(self: *Checker, arg: Sexp) Error!?VarId {
        var inner = arg;
        const explicit_write = isTag(arg, .@"write");
        if ((explicit_write or isTag(arg, .@"clone")) and arg.list.len >= 2) inner = arg.list[1];
        const place = (try self.resolvePlace(inner)) orelse return null;
        const ty = self.exprType(inner);
        if (!self.mayCarryBorrow(ty)) return null;
        if (!explicit_write) {
            const t = ty orelse return null;
            const tag = self.typeOf(t);
            if (tag != .shared and tag != .borrow_write) return null;
        }
        return place.root;
    }

    /// Record that var `id` may now hold the loans in `v`. A borrowed or
    /// module-level container outlives this function's values: storing
    /// any borrow into it is rejected.
    fn absorbLoans(self: *Checker, id: VarId, v: Value, pos: u32) Error!void {
        var out: std.ArrayListUnmanaged(Loan) = .empty;
        for (v.loans) |l| if (l.root != id) try out.append(self.arena(), l);
        if (out.items.len == 0) return;
        const c = self.vars.items[id];
        if (c.ref != .none or self.isGlobal(id)) {
            // The caller accounts for borrows it passed in; only borrows
            // of this function's own values cannot be stored. Nothing
            // borrowed may be stored in a module-level binding.
            for (out.items) |l| if (self.isLocalLoan(l) or self.isGlobal(id)) {
                try self.err(pos, "cannot let this call store a borrow of `{s}` in `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, c.name, c.name });
                return;
            };
            return;
        }
        self.flows.items[id].loans = try self.unionLoans(self.flows.items[id].loans, out.items);
    }

    /// A loan on a value owned by the current function (as opposed to one
    /// the caller handed in through a borrowed parameter).
    fn isLocalLoan(self: *const Checker, l: Loan) bool {
        if (l.ext) return false;
        const r = self.vars.items[l.root];
        return !(r.kind == .param and r.ref != .none);
    }

    // -------------------------------------------------------------------------
    // Closures and shared allocation
    // -------------------------------------------------------------------------

    fn walkShare(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 2) return .{};
        const inner = items[1];
        if (ownedClosureLambda(self, inner)) |lambda| {
            self.lambda_ok = true;
            return self.walk(lambda);
        }
        return self.walkConsumed(inner, .allocation);
    }

    /// `(call Closure (lambda ...))` and the `Closure1(T)` / `Closure2(A, B)`
    /// forms: returns the lambda literal.
    fn ownedClosureLambda(self: *Checker, inner: Sexp) ?Sexp {
        if (!isTag(inner, .@"call") or inner.list.len != 3) return null;
        const callee = inner.list[1];
        const name = if (callee == .src)
            self.text(callee)
        else if (isTag(callee, .@"call") and callee.list.len >= 2 and callee.list[1] == .src)
            self.text(callee.list[1])
        else
            return null;
        const ok = if (callee == .src)
            std.mem.eql(u8, name, "Closure")
        else
            std.mem.eql(u8, name, "Closure1") or std.mem.eql(u8, name, "Closure2");
        if (!ok or !isLambda(inner.list[2])) return null;
        return inner.list[2];
    }

    fn walkLambda(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 5) return .{};
        const captures = items[1];
        const params = items[2];
        const body = items[4];
        if (!self.lambda_ok) {
            try self.err(firstSrcPos(.{ .list = items }), "closures cannot escape their defining scope; bind the closure to a local (`f = |...| ...`) and call `f()`, or wrap it in `*Closure(...)` to store or return it", .{});
        }
        self.lambda_ok = false;

        // Captures take effect on the enclosing scope, at construction.
        var value: Value = .{};
        var cap_values: std.ArrayListUnmanaged(Value) = .empty;
        const caps: []const Sexp = if (isTag(captures, .@"captures")) captures.list[1..] else &.{};
        for (caps) |cap| {
            try cap_values.append(self.arena(), try self.applyCapture(cap));
            value = try self.valueUnion(value, cap_values.items[cap_values.items.len - 1]);
        }

        // The body is checked as its own function; it cannot affect the
        // enclosing state.
        const snap = try self.snapshot();
        const saved_func = self.func;
        const saved_loop = self.loop;
        const saved_try = self.try_ctx;
        self.func = .{};
        self.loop = null;
        self.try_ctx = null;
        self.reachable = true;
        try self.pushScope(.closure);
        for (caps, cap_values.items) |cap, cv| {
            if (cap != .list or cap.list.len < 2 or cap.list[0] != .tag or cap.list[1] != .src) continue;
            const node = cap.list[1];
            const ty = self.symType(node.src.pos);
            const resource = switch (cap.list[0].tag) {
                .@"cap_clone", .@"cap_weak", .@"cap_move" => true,
                else => false,
            };
            _ = try self.addVar(.{
                .name = self.text(node),
                .decl = node.src.pos,
                .ty = ty,
                .kind = .capture,
                .ref = self.refOfType(ty),
                .capture_resource = resource,
            }, .{ .loans = cv.loans });
        }
        if (params == .list) for (params.list) |p| try self.bindParam(p);
        try self.walkBody(body, false);
        try self.popScope();
        self.func = saved_func;
        self.loop = saved_loop;
        self.try_ctx = saved_try;
        try self.restore(snap);
        return value;
    }

    fn applyCapture(self: *Checker, cap: Sexp) Error!Value {
        if (cap != .list or cap.list.len < 2 or cap.list[0] != .tag or cap.list[1] != .src) return .{};
        const mode = cap.list[0].tag;
        const node = cap.list[1];
        const pos = node.src.pos;
        const name = self.text(node);
        // Unresolved or nested captures are diagnosed by sema.
        const f = self.find(name) orelse return .{};
        if (f.crossed) return .{};
        const id = f.id;
        const v = self.vars.items[id];
        if (v.closure) {
            try self.err(pos, "cannot capture closure `{s}`; closures cannot be copied", .{name});
            return .{};
        }
        if (mode == .@"cap_move") return self.moveVar(id, pos, .capture);
        if (!self.flowLive(id)) {
            try self.err(pos, "cannot capture `{s}` after {s}", .{ name, if (self.flows.items[id].status == .dropped) "drop" else "move" });
            try self.noteInvalidated(id, pos);
            return .{};
        }
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "cannot capture `{s}` while a write borrow is live", .{name});
            try self.noteLoan(l);
            return .{};
        }
        return self.varValue(id);
    }

    // -------------------------------------------------------------------------
    // Return and escape
    // -------------------------------------------------------------------------

    fn walkReturn(self: *Checker, items: []const Sexp) Error!void {
        const value: Sexp = if (items.len >= 2) items[1] else .nil;
        const guard: Sexp = if (items.len >= 3) items[2] else .nil;
        var fallthrough: ?State = null;
        if (guard != .nil) {
            _ = try self.walk(guard);
            fallthrough = try self.snapshot();
        }
        if (value != .nil) try self.walkReturnValue(value);
        try self.runDefersTo(0);
        self.reachable = false;
        if (fallthrough) |s| try self.restore(s);
    }

    /// A value leaving the function: a bare local moves out; anything
    /// else must not copy an owning value; borrows must come from
    /// borrowed parameters.
    fn walkReturnValue(self: *Checker, expr: Sexp) Error!void {
        var value: Value = .{};
        if (expr == .src) {
            try self.checkNoImplicitCopy(expr, .ret, true);
            if (try self.lookup(expr.src.pos, self.text(expr))) |id| {
                const v = self.vars.items[id];
                if (v.closure) {
                    value = try self.walkName(expr, false);
                } else if (!v.loop_borrow and !v.capture_resource) {
                    if (try self.checkLive(id, expr.src.pos)) {
                        value = self.varValue(id);
                        if (v.alias_of) |root| {
                            if (!self.isCopy(v.ty)) _ = try self.movePayload(id, root, expr.src.pos, value);
                        }
                    }
                }
            }
        } else if (isValueExpr(expr)) {
            try self.checkNoImplicitCopy(expr, .ret, true);
            value = try self.walk(expr);
        } else {
            _ = try self.walk(expr);
            return;
        }
        if (self.func.ret_may_borrow and self.reachable) try self.checkEscape(value);
    }

    fn checkEscape(self: *Checker, v: Value) Error!void {
        for (v.loans, 0..) |l, i| {
            if (!self.isLocalLoan(l)) continue;
            const r = self.vars.items[l.root];
            var seen = false;
            for (v.loans[0..i]) |p| if (p.root == l.root and !p.ext) {
                seen = true;
            };
            if (seen) continue;
            try self.err(l.pos, "returned borrow of `{s}` does not originate from a borrowed parameter", .{r.name});
            try self.note(r.decl, "`{s}` is local to this function", .{r.name});
        }
    }

    // -------------------------------------------------------------------------
    // Branches
    // -------------------------------------------------------------------------

    fn walkIf(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 3) return .{};
        _ = try self.walk(items[1]);
        return self.walkBranches(items[2], if (items.len >= 4) items[3] else null);
    }

    /// `(ternary cond then else)`
    fn walkTernary(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 4) return .{};
        _ = try self.walk(items[1]);
        return self.walkBranches(items[2], items[3]);
    }

    fn walkBranches(self: *Checker, then_b: Sexp, else_b: ?Sexp) Error!Value {
        const base = try self.snapshot();
        const v1 = try self.walk(then_b);
        const s1 = try self.snapshot();
        try self.restore(base);
        const v2 = if (else_b) |e| try self.walk(e) else Value{};
        const s2 = try self.snapshot();
        try self.restore(try self.join(s1, s2));
        return self.valueUnion(v1, v2);
    }

    /// `(catch expr name? handler)`: the handler runs when `expr` fails.
    fn walkCatch(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 3) return .{};
        const v1 = try self.walk(items[1]);
        const base = try self.snapshot();
        const handler = items[items.len - 1];
        try self.pushScope(.block);
        if (items.len >= 4 and items[2] == .src) {
            _ = try self.addVar(.{ .name = self.text(items[2]), .decl = items[2].src.pos, .ty = self.symType(items[2].src.pos) }, .{});
        }
        var v2 = try self.walk(handler);
        v2 = try self.checkValueEscapesScope(v2);
        try self.popScope();
        try self.restore(try self.join(base, try self.snapshot()));
        return self.valueUnion(v1, v2);
    }

    const Scrutinee = struct {
        root: ?VarId = null,
        via: Via = .owned,
    };

    fn walkMatch(self: *Checker, items: []const Sexp) Error!Value {
        if (items.len < 2) return .{};
        const scrut = items[1];
        var info: Scrutinee = .{};
        var node = scrut;
        if ((isTag(scrut, .@"read") or isTag(scrut, .@"write")) and scrut.list.len >= 2) {
            node = scrut.list[1];
            info.via = .borrowed;
        }
        if (node == .src) {
            if (self.find(self.text(node))) |f| if (!f.crossed) {
                info.root = f.id;
                const v = self.vars.items[f.id];
                if (v.ref != .none or v.alias_of != null) info.via = .borrowed;
                if (v.ty) |t| if (self.typeOf(t) == .shared) {
                    info.via = .shared;
                };
            };
        }
        const scrut_value = try self.walk(scrut);

        const base = try self.snapshot();
        var acc: ?State = null;
        var value: Value = .{};
        var catch_all = false;
        for (items[2..]) |arm| {
            if (!isTag(arm, .@"arm") or arm.list.len < 3) continue;
            const pattern = arm.list[1];
            const guard: Sexp = if (arm.list.len >= 4) arm.list[2] else .nil;
            const body = arm.list[arm.list.len - 1];
            try self.restore(base);
            try self.pushScope(.block);
            if (try self.bindPattern(pattern, info, scrut_value)) catch_all = true;
            if (guard != .nil) _ = try self.walk(guard);
            var v = try self.walk(body);
            v = try self.checkValueEscapesScope(v);
            try self.popScope();
            value = try self.valueUnion(value, v);
            const s = try self.snapshot();
            acc = if (acc) |a| try self.join(a, s) else s;
        }
        // Without a catch-all arm, no arm may run.
        if (!catch_all) acc = if (acc) |a| try self.join(a, base) else base;
        try self.restore(acc orelse base);
        return value;
    }

    /// Bind a pattern's names. Returns true for a catch-all pattern.
    fn bindPattern(self: *Checker, pattern: Sexp, info: Scrutinee, scrut_value: Value) Error!bool {
        switch (pattern) {
            .src => {
                const name = self.text(pattern);
                if (std.mem.eql(u8, name, "_") or std.mem.eql(u8, name, "else")) return true;
                // Literal patterns match one value; an identifier binds the
                // whole scrutinee and matches everything.
                if (!isIdentStart(name[0]) or std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) return false;
                try self.bindPayload(pattern, info, scrut_value);
                return true;
            },
            .list => |items| {
                if (items.len >= 2 and items[0] == .tag and items[0].tag == .@"variant_pattern") {
                    for (items[2..]) |b| {
                        if (b == .src and !std.mem.eql(u8, self.text(b), "_")) try self.bindPayload(b, info, scrut_value);
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    fn bindPayload(self: *Checker, node: Sexp, info: Scrutinee, scrut_value: Value) Error!void {
        const pos = node.src.pos;
        const ty = self.symType(pos);
        var v: Var = .{ .name = self.text(node), .decl = pos, .ty = ty, .kind = .pattern, .ref = self.refOfType(ty) };
        var loans: []const Loan = &.{};
        if (!self.isCopy(ty)) {
            if (info.root) |r| {
                v.alias_of = r;
                v.via = info.via;
                if (info.via == .borrowed) {
                    loans = self.flows.items[r].loans;
                    if (loans.len == 0) {
                        const one = try self.arena().alloc(Loan, 1);
                        one[0] = .{ .root = r, .kind = .read, .pos = pos };
                        loans = one;
                    }
                } else {
                    const one = try self.arena().alloc(Loan, 1);
                    one[0] = .{ .root = r, .kind = .read, .pos = pos };
                    loans = one;
                }
            } else {
                loans = scrut_value.loans;
            }
        }
        _ = try self.addVar(v, .{ .loans = loans });
    }

    // -------------------------------------------------------------------------
    // Loops
    // -------------------------------------------------------------------------

    const LoopSpec = struct {
        cond: ?Sexp = null,
        cond_always_true: bool = false,
        cont: ?Sexp = null,
        body: Sexp,
        else_body: ?Sexp = null,
        /// `for` loops: element bindings and the source loan.
        elem1: Sexp = .nil,
        elem2: Sexp = .nil,
        source_root: ?VarId = null,
        source_loan: LoanKind = .read,
        source_pos: u32 = 0,
        resource_vec: bool = false,
    };

    fn walkWhile(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 4) return;
        const cond = items[1];
        try self.walkLoop(.{
            .cond = cond,
            .cond_always_true = cond == .src and std.mem.eql(u8, self.text(cond), "true"),
            .cont = if (items[2] == .nil) null else items[2],
            .body = items[3],
            .else_body = if (items.len >= 5 and items[4] != .nil) items[4] else null,
        });
    }

    fn walkFor(self: *Checker, items: []const Sexp) Error!void {
        // (for mode binding1 binding2 source body else?)
        if (items.len < 6) return;
        const mode: Tag = if (items[1] == .tag) items[1].tag else .iter;
        const source = items[4];
        var spec: LoopSpec = .{
            .body = items[5],
            .else_body = if (items.len >= 7 and items[6] != .nil) items[6] else null,
            .elem1 = items[2],
            .elem2 = items[3],
        };
        if (mode == .@"move") {
            _ = try self.walkMove(source, .move);
        } else {
            _ = try self.walk(source);
            if (try self.resolvePlace(source)) |p| {
                const id = p.root;
                const kind: LoanKind = if (mode == .@"write" or mode == .ptr) .write else .read;
                spec.source_root = id;
                spec.source_loan = kind;
                spec.source_pos = innerPos(source);
                spec.resource_vec = mode == .@"read" and source == .src and self.isResourceVec(self.vars.items[id].ty);
                if (self.flowLive(id)) {
                    if (kind == .write) {
                        if (self.findLoan(id, .any, null)) |l| {
                            try self.err(spec.source_pos, "cannot write-borrow `{s}` while a read borrow is live", .{self.vars.items[id].name});
                            try self.noteLoan(l);
                            spec.source_root = null;
                        }
                    } else if (self.findLoan(id, .write, null)) |l| {
                        try self.err(spec.source_pos, "cannot read-borrow `{s}` while a write borrow is live", .{self.vars.items[id].name});
                        try self.noteLoan(l);
                        spec.source_root = null;
                    }
                } else spec.source_root = null;
            }
        }
        try self.walkLoop(spec);
    }

    fn walkLoop(self: *Checker, spec: LoopSpec) Error!void {
        var ctx: LoopCtx = .{ .depth = @intCast(self.vars.items.len), .scope_depth = self.scopes.items.len, .parent = self.loop };
        self.loop = &ctx;
        defer self.loop = ctx.parent;

        const entry = try self.snapshot();
        var head = entry;
        self.quiet += 1;
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            try self.restore(head);
            const it = try self.loopIteration(spec, &ctx);
            const next = try self.join(head, it.back);
            if (statesEql(next, head)) break;
            head = next;
        }
        self.quiet -= 1;

        try self.restore(head);
        const it = try self.loopIteration(spec, &ctx);
        try self.restore(it.exit);
        if (spec.else_body) |e| try self.walkStmt(e);
        var out = try self.snapshot();
        for (ctx.breaks.items) |b| out = try self.join(out, b);
        try self.restore(out);
    }

    fn loopIteration(self: *Checker, spec: LoopSpec, ctx: *LoopCtx) Error!struct { back: State, exit: State } {
        ctx.breaks.clearRetainingCapacity();
        ctx.conts.clearRetainingCapacity();
        if (spec.cond) |c| try self.walkStmt(c);
        const exit = if (spec.cond_always_true) try self.unreachableState() else try self.snapshot();

        try self.pushScope(.block);
        try self.bindLoopElems(spec);
        try self.walkStmt(spec.body);
        try self.popScope();

        var back = try self.snapshot();
        for (ctx.conts.items) |c| back = try self.join(back, c);
        try self.restore(back);
        if (spec.cont) |c| try self.walkStmt(c);
        return .{ .back = try self.snapshot(), .exit = exit };
    }

    fn bindLoopElems(self: *Checker, spec: LoopSpec) Error!void {
        var elem_loans: []const Loan = &.{};
        if (spec.source_root) |root| if (self.flowLive(root)) {
            // The source stays borrowed for the whole loop.
            const one = try self.arena().alloc(Loan, 1);
            one[0] = .{ .root = root, .kind = spec.source_loan, .pos = spec.source_pos };
            elem_loans = one;
            _ = try self.addVar(.{ .name = "", .decl = spec.source_pos, .kind = .hidden }, .{ .loans = elem_loans });
        };
        if (spec.elem1 == .src) {
            const pos = spec.elem1.src.pos;
            const ty = self.symType(pos);
            _ = try self.addVar(.{
                .name = self.text(spec.elem1),
                .decl = pos,
                .ty = ty,
                .kind = .loop_elem,
                .ref = self.refOfType(ty),
                .loop_borrow = spec.resource_vec,
            }, .{ .loans = if (self.mayCarryBorrow(ty)) elem_loans else &.{} });
        }
        if (spec.elem2 == .src) {
            const pos = spec.elem2.src.pos;
            _ = try self.addVar(.{ .name = self.text(spec.elem2), .decl = pos, .ty = self.symType(pos), .kind = .loop_elem }, .{});
        }
    }

    const Jump = enum { brk, cont };

    fn walkJump(self: *Checker, items: []const Sexp, jump: Jump) Error!void {
        // (break label value guard) / (continue label guard)
        const label: Sexp = if (items.len >= 2) items[1] else .nil;
        const value: Sexp = if (jump == .brk and items.len >= 3) items[2] else .nil;
        const guard: Sexp = if (jump == .brk) (if (items.len >= 4) items[3] else .nil) else (if (items.len >= 3) items[2] else .nil);
        var fallthrough: ?State = null;
        if (guard != .nil) {
            _ = try self.walk(guard);
            fallthrough = try self.snapshot();
        }
        if (value != .nil) _ = try self.walk(value);
        var target = self.loop;
        while (target) |t| : (target = t.parent) {
            const s = try self.exitState(t.depth, t.scope_depth);
            switch (jump) {
                .brk => try t.breaks.append(self.arena(), s),
                .cont => try t.conts.append(self.arena(), s),
            }
            // An unlabeled jump targets the innermost loop; a labeled one
            // is conservatively joined into every enclosing loop.
            if (label == .nil) break;
        }
        self.reachable = false;
        if (fallthrough) |s| try self.restore(s);
    }

    /// The state at a jump out of the scopes above `depth` vars /
    /// `scope_depth` scopes: their defers run, and nothing that survives
    /// may borrow what is left behind.
    fn exitState(self: *Checker, depth: u32, scope_depth: usize) Error!State {
        try self.runDefersTo(scope_depth);
        for (self.flows.items[0..depth], 0..) |f, holder| {
            for (f.loans) |l| if (l.root >= depth) try self.reportShortLived(l, @intCast(holder));
        }
        return self.truncState(try self.snapshot(), depth);
    }

    /// `e!`: on failure, control leaves for the enclosing `catch` or the
    /// caller.
    fn walkPropagate(self: *Checker, items: []const Sexp) Error!Value {
        const v = if (items.len >= 2) try self.walk(items[1]) else Value{};
        if (!self.reachable) return v;
        if (self.try_ctx) |t| {
            const s = try self.exitState(t.depth, t.scope_depth);
            t.fail = if (t.fail) |f| try self.join(f, s) else s;
        } else {
            try self.runDefersTo(0);
        }
        return v;
    }

    fn walkTryBlock(self: *Checker, items: []const Sexp) Error!void {
        // (try_block body (catch_block name body)?)
        if (items.len < 2) return;
        var ctx: TryCtx = .{ .depth = @intCast(self.vars.items.len), .scope_depth = self.scopes.items.len };
        const saved = self.try_ctx;
        self.try_ctx = &ctx;
        try self.walkStmt(items[1]);
        self.try_ctx = saved;
        const after = try self.snapshot();
        const fail = ctx.fail orelse try self.unreachableState();
        if (items.len >= 3 and isTag(items[2], .@"catch_block") and items[2].list.len >= 3) {
            const cb = items[2].list;
            try self.restore(fail);
            try self.pushScope(.block);
            if (cb[1] == .src) _ = try self.addVar(.{ .name = self.text(cb[1]), .decl = cb[1].src.pos, .ty = self.symType(cb[1].src.pos) }, .{});
            try self.walkStmt(cb[2]);
            try self.popScope();
            try self.restore(try self.join(after, try self.snapshot()));
        } else {
            try self.restore(try self.join(after, fail));
        }
    }

    // -------------------------------------------------------------------------
    // Defer
    // -------------------------------------------------------------------------

    /// A deferred body runs at scope exit. It is checked where it is
    /// written (and may not change outer state), then again at each exit
    /// of its scope against the state there.
    fn walkDefer(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const body = items[1];
        try self.checkDeferBody(body, true);
        try self.scopes.items[self.scopes.items.len - 1].defers.append(self.gpa, body);
    }

    fn checkDeferBody(self: *Checker, body: Sexp, report_changes: bool) Error!void {
        const snap = try self.snapshot();
        const saved_loop = self.loop;
        const saved_try = self.try_ctx;
        const saved_in_defer = self.in_defer;
        self.loop = null;
        self.try_ctx = null;
        self.in_defer = true;
        try self.walkStmt(body);
        self.loop = saved_loop;
        self.try_ctx = saved_try;
        self.in_defer = saved_in_defer;
        if (report_changes) {
            for (snap.flows, self.flows.items[0..snap.flows.len], 0..) |before, after, i| {
                if (before.status != after.status) {
                    try self.err(innerPos(body), "a `defer` body cannot move or drop `{s}`; it runs when the scope exits", .{self.vars.items[i].name});
                    break;
                }
            }
        }
        try self.restore(snap);
    }

    fn runDefers(self: *Checker, scope_idx: usize) Error!void {
        // The body sees the names of its own scope, not those of scopes
        // opened after the defer.
        const saved = self.hidden;
        self.hidden = .{ .lo = scope_idx, .hi = self.scopes.items.len - 1 };
        defer self.hidden = saved;
        var i = self.scopes.items[scope_idx].defers.items.len;
        while (i > 0) {
            i -= 1;
            try self.checkDeferBody(self.scopes.items[scope_idx].defers.items[i], false);
        }
    }

    /// Run the defers of the scopes an early exit leaves: every scope at
    /// index `scope_depth` or above, up to the enclosing function.
    fn runDefersTo(self: *Checker, scope_depth: usize) Error!void {
        // An exit from inside a deferred body leaves only that body.
        if (self.in_defer) return;
        var si = self.scopes.items.len;
        while (si > scope_depth) {
            si -= 1;
            if (self.scopes.items[si].defers.items.len > 0) try self.runDefers(si);
            if (self.scopes.items[si].kind != .block) break;
        }
    }

    // -------------------------------------------------------------------------
    // Types (a local view of sema's facts)
    // -------------------------------------------------------------------------

    fn text(self: *const Checker, node: Sexp) []const u8 {
        return switch (node) {
            .src => |s| self.source[s.pos..][0..s.len],
            else => "",
        };
    }

    fn typeOf(self: *const Checker, id: TypeId) types.Type {
        const sema = self.sema orelse return .unknown;
        return sema.types.get(id);
    }

    fn symType(self: *const Checker, decl_pos: u32) ?TypeId {
        const sema = self.sema orelse return null;
        const sid = self.sym_at.get(decl_pos) orelse return null;
        const ty = sema.symbols.items[sid].ty;
        return self.known(ty);
    }

    fn known(self: *const Checker, ty: TypeId) ?TypeId {
        const sema = self.sema orelse return null;
        if (ty == sema.types.unknown_id or ty == sema.types.invalid_id) return null;
        return ty;
    }

    fn isVoid(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return self.typeOf(t) == .void;
    }

    fn fnReturnType(self: *const Checker, name: Sexp) ?TypeId {
        if (name != .src) return null;
        const sema = self.sema orelse return null;
        const fn_ty = if (self.method_at.get(name.src.pos)) |m| m else if (self.sym_at.get(name.src.pos)) |sid| sema.symbols.items[sid].ty else return null;
        const t = sema.types.get(fn_ty);
        if (t != .function) return null;
        return self.known(t.function.returns);
    }

    fn returnMayBorrow(self: *Checker, ret_ty: ?TypeId, returns: Sexp) bool {
        if (sexpMentionsBorrow(returns)) return true;
        if (self.sema == null) return false;
        return ret_ty != null and self.mayCarryBorrow(ret_ty);
    }

    fn refOfType(self: *const Checker, ty: ?TypeId) Ref {
        const t = ty orelse return .none;
        return switch (self.typeOf(t)) {
            .borrow_read => .read,
            .borrow_write => .write,
            else => .none,
        };
    }

    fn isCopy(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return switch (self.typeOf(t)) {
            .bool, .int, .float, .string, .int_literal, .float_literal => true,
            else => false,
        };
    }

    fn isResourceVec(self: *const Checker, ty: ?TypeId) bool {
        const sema = self.sema orelse return false;
        const t = ty orelse return false;
        const pt = sema.types.get(types.unwrapBorrows(sema, t));
        if (pt != .parameterized_nominal or pt.parameterized_nominal.sym != sema.vec_sym_id) return false;
        if (pt.parameterized_nominal.args.len != 1) return false;
        return switch (sema.types.get(pt.parameterized_nominal.args[0])) {
            .shared, .weak => true,
            else => false,
        };
    }

    /// Values of this type own a resource and cannot be copied implicitly.
    fn owningKind(self: *const Checker, ty: ?TypeId) ?Owning {
        const sema = self.sema orelse return null;
        const t = ty orelse return null;
        return switch (sema.types.get(t)) {
            .shared => .shared,
            .weak => .weak,
            .optional => |child| self.owningKind(child),
            .parameterized_nominal => |pn| blk: {
                if (pn.sym == sema.vec_sym_id) break :blk .vec;
                if (types.typeHasDropGlue(sema, t)) break :blk .{ .drop_glue = sema.symbols.items[pn.sym].name };
                break :blk null;
            },
            .nominal => |s| if (sema.symbols.items[s].flags.has_drop_glue) .{ .drop_glue = sema.symbols.items[s].name } else null,
            else => null,
        };
    }

    /// Whether a value of this type can hold a borrow. Unknown types are
    /// assumed to.
    fn mayCarryBorrow(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return true;
        return self.typeCarries(t, .any, 0);
    }

    /// Whether a value of this type holds a write borrow, which must not
    /// be duplicated.
    fn carriesWriteBorrow(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return self.typeCarries(t, .write, 0);
    }

    const BorrowQuery = enum { any, write };

    fn typeCarries(self: *const Checker, t: TypeId, q: BorrowQuery, depth: u8) bool {
        const sema = self.sema orelse return q == .any;
        if (depth > 8) return q == .any;
        return switch (sema.types.get(t)) {
            .invalid, .unknown => false,
            .void, .bool, .string, .int, .float, .int_literal, .float_literal, .function => false,
            .none_literal, .noreturn, .range => false,
            .borrow_write => true,
            .borrow_read, .slice => q == .any,
            .type_var, .imported_nominal => q == .any,
            .optional => |i| self.typeCarries(i, q, depth + 1),
            .fallible => |i| self.typeCarries(i, q, depth + 1),
            .shared => |i| self.typeCarries(i, q, depth + 1),
            .weak => |i| self.typeCarries(i, q, depth + 1),
            .array => |a| self.typeCarries(a.elem, q, depth + 1),
            .nominal => |s| self.fieldsCarry(s, q, depth),
            .parameterized_nominal => |pn| blk: {
                // A closure carries whatever its captures borrow, and a
                // Signal whatever its subscribers borrow.
                if (pn.sym == sema.closure_sym_id or pn.sym == sema.closure1_sym_id or
                    pn.sym == sema.closure2_sym_id or pn.sym == sema.signal_sym_id) break :blk q == .any;
                for (pn.args) |a| if (self.typeCarries(a, q, depth + 1)) break :blk true;
                break :blk self.fieldsCarry(pn.sym, q, depth);
            },
        };
    }

    fn fieldsCarry(self: *const Checker, sid: SymbolId, q: BorrowQuery, depth: u8) bool {
        const sema = self.sema.?;
        for (sema.symbols.items[sid].fields orelse &.{}) |f| {
            if (f.is_method) continue;
            if (f.is_variant) {
                for (f.payload orelse &.{}) |pf| {
                    if (self.typeCarries(pf.ty, q, depth + 1)) return true;
                }
                continue;
            }
            if (sema.types.get(f.ty) == .type_var) continue; // covered by the args
            if (self.typeCarries(f.ty, q, depth + 1)) return true;
        }
        return false;
    }

    /// The nominal symbol behind a receiver type (through borrows and
    /// shared handles), with its type arguments.
    const NominalRef = struct { sym: SymbolId, args: []const TypeId = &.{} };

    fn nominalOf(self: *const Checker, t: TypeId) ?NominalRef {
        const sema = self.sema orelse return null;
        return switch (sema.types.get(types.unwrapReadAccess(sema, t))) {
            .nominal => |s| .{ .sym = s },
            .parameterized_nominal => |pn| .{ .sym = pn.sym, .args = pn.args },
            else => null,
        };
    }

    /// Substitute a direct type variable with its argument; other
    /// generic types are unknown here.
    fn substitute(self: *const Checker, n: NominalRef, t: TypeId) ?TypeId {
        const sema = self.sema.?;
        switch (sema.types.get(t)) {
            .type_var => |tv| {
                const params = sema.symbols.items[n.sym].type_params orelse return null;
                for (params, 0..) |p, i| if (p == tv and i < n.args.len) return n.args[i];
                return null;
            },
            else => return self.known(t),
        }
    }

    fn fieldType(self: *const Checker, recv: TypeId, name: []const u8) ?TypeId {
        const n = self.nominalOf(recv) orelse return null;
        for (self.sema.?.symbols.items[n.sym].fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant) continue;
            if (std.mem.eql(u8, f.name, name)) return self.substitute(n, f.ty);
        }
        return null;
    }

    fn methodOf(self: *const Checker, recv: TypeId, name: []const u8) ?types.Field {
        const n = self.nominalOf(recv) orelse return null;
        for (self.sema.?.symbols.items[n.sym].fields orelse &.{}) |f| {
            if (f.is_method and std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    fn receiverMode(self: *const Checker, obj: Sexp, name: []const u8) types.MethodReceiver {
        if (isTag(obj, .@"move")) return .value;
        const t = self.exprType(obj) orelse return .read;
        if (self.typeOf(t) == .shared) return .read;
        const m = self.methodOf(t, name) orelse return .read;
        return switch (m.receiver) {
            .write => .write,
            .value => .value,
            else => .read,
        };
    }

    /// The result type of a call, when known.
    fn callResultType(self: *const Checker, items: []const Sexp) ?TypeId {
        const sema = self.sema orelse return null;
        const callee = items[1];
        if (callee == .src) {
            const name = self.text(callee);
            // A local closure binding: closures return nothing that borrows.
            if (self.find(name)) |f| {
                if (self.vars.items[f.id].closure) return sema.types.void_id;
                return null;
            }
            for (sema.symbols.items) |sym| {
                if (sym.scope > 1 or !std.mem.eql(u8, sym.name, name)) continue;
                switch (sym.kind) {
                    .function, .@"extern" => {
                        const t = sema.types.get(sym.ty);
                        if (t == .function) return self.known(t.function.returns);
                        return null;
                    },
                    .nominal_type, .generic_type => return self.findType(sym),
                    else => {},
                }
            }
            return null;
        }
        if (isTag(callee, .@"member") and callee.list.len >= 3) {
            const name = self.text(callee.list[2]);
            const obj = callee.list[1];
            const recv = self.exprType(obj) orelse {
                // `Type.method(...)` / `module.fn(...)` / builtins.
                if (std.mem.eql(u8, name, "upgrade")) return sema.types.void_id;
                return null;
            };
            if (std.mem.eql(u8, name, "upgrade") and self.typeOf(recv) == .weak) return sema.types.void_id;
            const m = self.methodOf(recv, name) orelse return null;
            const t = sema.types.get(m.ty);
            if (t != .function) return null;
            return self.substitute(self.nominalOf(recv).?, t.function.returns);
        }
        return null;
    }

    /// The TypeId sema interned for a nominal declaration.
    fn findType(self: *const Checker, sym: types.Symbol) ?TypeId {
        const sema = self.sema.?;
        const sid: SymbolId = for (sema.symbols.items, 0..) |s, i| {
            if (s.decl_pos == sym.decl_pos and std.mem.eql(u8, s.name, sym.name)) break @intCast(i);
        } else return null;
        for (sema.types.items.items, 0..) |t, i| {
            if (t == .nominal and t.nominal == sid) return @intCast(i);
        }
        return null;
    }

    /// The type of an expression, as far as it can be read off sema's
    /// symbol table. Null when unknown.
    fn exprType(self: *const Checker, e: Sexp) ?TypeId {
        if (self.sema == null) return null;
        switch (e) {
            .src => {
                const f = self.find(self.text(e)) orelse return null;
                return self.vars.items[f.id].ty;
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return null;
                return switch (items[0].tag) {
                    .@"member" => if (items.len >= 3) self.fieldType(self.exprType(items[1]) orelse return null, self.text(items[2])) else null,
                    .@"index" => blk: {
                        const sema = self.sema.?;
                        const t = self.exprType(items[1]) orelse break :blk null;
                        break :blk switch (sema.types.get(types.unwrapReadAccess(sema, t))) {
                            .parameterized_nominal => |pn| if (pn.sym == sema.vec_sym_id and pn.args.len == 1) pn.args[0] else null,
                            .array => |a| a.elem,
                            .slice => |s| s.elem,
                            else => null,
                        };
                    },
                    .@"move", .@"clone", .@"deref", .@"pin" => self.exprType(items[1]),
                    .@"propagate" => blk: {
                        const t = self.exprType(items[1]) orelse break :blk null;
                        break :blk switch (self.typeOf(t)) {
                            .fallible => |i| i,
                            else => t,
                        };
                    },
                    .@"call" => self.callResultType(items),
                    .@"block" => self.exprType(items[items.len - 1]),
                    .@"if" => if (items.len >= 3) self.exprType(tailOf(items[2])) else null,
                    else => null,
                };
            },
            else => return null,
        }
    }

    fn placeText(self: *Checker, e: Sexp) Error![]const u8 {
        switch (e) {
            .src => return self.text(e),
            .list => |items| {
                if (items.len >= 3 and items[0] == .tag and items[0].tag == .@"member") {
                    return std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ try self.placeText(items[1]), self.text(items[2]) });
                }
                if (items.len >= 2 and items[0] == .tag and items[0].tag == .@"index") {
                    return std.fmt.allocPrint(self.arena(), "{s}[...]", .{try self.placeText(items[1])});
                }
                if (items.len >= 2 and items[0] == .tag) return self.placeText(items[1]);
                return "expression";
            },
            else => return "expression",
        }
    }
};

// =============================================================================
// Helpers
// =============================================================================

fn isTag(s: Sexp, tag: Tag) bool {
    return s == .list and s.list.len > 0 and s.list[0] == .tag and s.list[0].tag == tag;
}

fn isLambda(s: Sexp) bool {
    return isTag(s, .@"lambda");
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn loanMatches(l: Loan, root: VarId, q: Checker.LoanQuery) bool {
    return l.root == root and !l.ext and (q == .any or l.kind == .write);
}

fn containsLoan(set: []const Loan, l: Loan) bool {
    for (set) |x| if (x.sameAs(l)) return true;
    return false;
}

fn loanSetEql(a: []const Loan, b: []const Loan) bool {
    for (a) |l| if (!containsLoan(b, l)) return false;
    for (b) |l| if (!containsLoan(a, l)) return false;
    return true;
}

fn hasLoanFrom(loans: []const Loan, start: u32) bool {
    for (loans) |l| if (l.root >= start) return true;
    return false;
}

/// The expression whose value a branch produces: the last statement of
/// a block, or the branch itself.
fn tailOf(s: Sexp) Sexp {
    if (isTag(s, .@"block")) {
        if (s.list.len < 2) return .nil;
        return tailOf(s.list[s.list.len - 1]);
    }
    return s;
}

/// Whether a statement produces a value (as opposed to binding, jumping
/// or looping).
fn isValueExpr(s: Sexp) bool {
    if (s != .list) return s == .src;
    if (s.list.len == 0 or s.list[0] != .tag) return false;
    return switch (s.list[0].tag) {
        .@"set", .@"return", .@"break", .@"continue", .@"while", .@"for", .@"drop", .@"defer", .@"errdefer", .@"labeled" => false,
        else => true,
    };
}

fn refOfTypeSexp(t: Sexp) Ref {
    if (isTag(t, .borrow_read)) return .read;
    if (isTag(t, .borrow_write)) return .write;
    return .none;
}

fn sexpMentionsBorrow(t: Sexp) bool {
    if (t != .list) return false;
    for (t.list) |c| {
        if (c == .tag and (c.tag == .borrow_read or c.tag == .borrow_write)) return true;
        if (sexpMentionsBorrow(c)) return true;
    }
    return false;
}

fn innerPos(sexp: Sexp) u32 {
    return firstSrcPos(sexp);
}

fn firstSrcPos(s: Sexp) u32 {
    return switch (s) {
        .src => |x| x.pos,
        .list => |items| blk: {
            for (items) |c| {
                const p = firstSrcPos(c);
                if (p > 0) break :blk p;
            }
            break :blk 0;
        },
        else => 0,
    };
}

const LineCol = struct { line: u32, col: u32 };

fn lineCol(source: []const u8, pos: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    const end = @min(pos, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

// =============================================================================
// Tests (without sema: every type is unknown, so every value is treated
// as owning and possibly borrowing)
// =============================================================================

const TestRig = struct {
    parser_obj: parser.Parser,
    checker: Checker,

    fn deinit(self: *TestRig) void {
        self.checker.deinit();
        self.parser_obj.deinit();
    }

    fn hasError(self: *const TestRig, needle: []const u8) bool {
        for (self.checker.diagnostics.items) |d| {
            if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, needle) != null) return true;
        }
        return false;
    }
};

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !TestRig {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const ir = try p.parseProgram();
    var c = try Checker.init(allocator, source);
    errdefer c.deinit();
    try c.check(ir);
    return .{ .parser_obj = p, .checker = c };
}

fn expectClean(source: []const u8) !void {
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    if (t.checker.hasErrors()) {
        for (t.checker.diagnostics.items) |d| std.debug.print("unexpected: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
}

fn expectError(source: []const u8, needle: []const u8) !void {
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    if (!t.hasError(needle)) {
        std.debug.print("expected error containing \"{s}\"; got:\n", .{needle});
        for (t.checker.diagnostics.items) |d| std.debug.print("  {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
}

test "use after move" {
    try expectError(
        \\sub main()
        \\  packet = make_packet()
        \\  send <packet
        \\  log ?packet
        \\
    , "use of `packet` after move");
}

test "hello passes" {
    try expectClean(
        \\sub main()
        \\  print "hello"
        \\
    );
}

test "fixed binding cannot be reassigned" {
    try expectError(
        \\sub main()
        \\  user =! make()
        \\  user = remake()
        \\
    , "cannot reassign fixed binding `user`");
}

test "explicit shadow allowed" {
    try expectClean(
        \\sub main()
        \\  x = 1
        \\  new x = 2
        \\
    );
}

test "temporary read borrow ends at statement end" {
    try expectClean(
        \\sub main()
        \\  user = make_user()
        \\  print ?user
        \\  rename !user
        \\
    );
}

test "bound borrow blocks write" {
    try expectError(
        \\sub main()
        \\  user = make_user()
        \\  r = ?user
        \\  rename !user
        \\
    , "cannot write-borrow `user` while a read borrow is live");
}

test "move in loop body is seen by the next iteration" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\
    , "use of `rc` after move");
}

test "move in loop then reassign is fine" {
    try expectClean(
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\    rc = make()
        \\
    );
}

test "move then break leaves the loop" {
    try expectClean(
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    if done()
        \\      eat(<rc)
        \\      break
        \\    look(?rc)
        \\
    );
}

test "move after loop exit via break is still a move" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\    break
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "move then continue is seen at the loop head" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    if skip()
        \\      eat(<rc)
        \\      continue
        \\    look(?rc)
        \\
    , "use of `rc` after move");
}

test "move then return in a branch keeps the value live after the if" {
    try expectClean(
        \\sub go(c: Bool)
        \\  rc = make()
        \\  if c
        \\    eat(<rc)
        \\    return
        \\  look(?rc)
        \\
    );
}

test "moves in two match arms are independent" {
    try expectClean(
        \\sub go(n: Int)
        \\  rc = make()
        \\  match n
        \\    1 => eat(<rc)
        \\    _ => eat(<rc)
        \\
    );
}

test "move in one match arm is a move after the match" {
    try expectError(
        \\sub go(n: Int)
        \\  rc = make()
        \\  match n
        \\    1 => eat(<rc)
        \\    _ => look(?rc)
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "borrow may not outlive an inner scope" {
    try expectError(
        \\sub main()
        \\  a = make()
        \\  r = ?a
        \\  if c()
        \\    b = make()
        \\    r = ?b
        \\  look(r)
        \\
    , "`b` does not live long enough");
}

test "borrow chosen by if keeps both roots borrowed" {
    try expectError(
        \\sub main()
        \\  a = make()
        \\  b = make()
        \\  r = if c()
        \\    ?a
        \\  else
        \\    ?b
        \\  -b
        \\  look(r)
        \\
    , "cannot drop `b` while borrows are live");
}

test "borrow returned from a call borrows the argument" {
    try expectError(
        \\fun view(h: ?Holder) -> ?Holder
        \\  h
        \\
        \\sub main()
        \\  h = make()
        \\  r = view(?h)
        \\  -h
        \\  look(r)
        \\
    , "cannot drop `h` while borrows are live");
}

test "returned borrow of a local is rejected" {
    try expectError(
        \\fun bad() -> ?User
        \\  user = make()
        \\  ?user
        \\
    , "returned borrow of `user` does not originate from a borrowed parameter");
}

test "returned borrow of a borrowed parameter is fine" {
    try expectClean(
        \\fun first(a: ?User, b: ?User) -> ?User
        \\  if pick()
        \\    a
        \\  else
        \\    b
        \\
    );
}

test "method receiver is borrowed for the whole call" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  rc.show(<rc)
        \\
    , "cannot move `rc` while it is read-borrowed");
}

test "dropping a borrowed parameter is rejected" {
    try expectError(
        \\sub kill(rc: ?Box)
        \\  -rc
        \\
    , "cannot drop borrowed parameter `rc`");
}

test "move-capturing a borrowed parameter is rejected" {
    try expectError(
        \\sub f(rc: ?Box)
        \\  g = |<rc|
        \\    look(rc)
        \\  g()
        \\
    , "cannot move-capture borrowed parameter `rc`");
}

test "moving out of a field is rejected" {
    try expectError(
        \\sub steal(p: ?Pair)
        \\  eat(<p.a)
        \\
    , "cannot move out of `p.a`");
}

test "closure body must capture outer locals" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  f = |+n|
        \\    eat(<rc)
        \\  f()
        \\
    , "closure body uses `rc` without capturing it");
}

test "move inside try is seen by catch" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  try
        \\    eat(<rc)
        \\    risky()!
        \\    rc = make()
        \\  catch |e|
        \\    look(?rc)
        \\
    , "use of `rc` after move");
}

test "a match without a catch-all arm may run no arm" {
    try expectError(
        \\sub go(n: Int)
        \\  rc = make()
        \\  eat(<rc)
        \\  match n
        \\    1 => rc = make()
        \\    2 => rc = make()
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "an exit inside a deferred body does not re-run the defers" {
    try expectClean(
        \\sub main()
        \\  defer print(g()!)
        \\  print(1)
        \\
    );
}

test "a deferred body is checked against the state at scope exit" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  defer look(?rc)
        \\  if c()
        \\    eat(<rc)
        \\    return
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "a borrowed parameter may store borrows the caller passed in" {
    try expectClean(
        \\sub put(v: !View, b: ?Box)
        \\  v.box = b
        \\  fill(!v, b)
        \\
    );
    try expectError(
        \\sub put(v: !View)
        \\  b = make()
        \\  fill(!v, ?b)
        \\
    , "cannot let this call store a borrow of `b` in `v`");
}

test "module-level bindings are visible in functions but cannot be consumed" {
    try expectClean(
        \\limit = make()
        \\
        \\sub main()
        \\  look(?limit)
        \\
    );
    try expectError(
        \\limit = make()
        \\
        \\sub main()
        \\  eat(<limit)
        \\
    , "cannot move module-level `limit` inside a function");
}
