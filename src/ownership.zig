//! Ownership checker: moves, drops, borrows, and aliasing of owning values.
//!
//! Runs on the normalized semantic IR after ctx, one function body at a
//! time, as a flow-sensitive abstract interpretation.
//!
//! Abstract state
//! --------------
//! * Every binding in scope is a `Var` (static facts: name, type, kind)
//!   paired with a `Flow` (status `live` / `moved` / `dropped`, plus the
//!   loans its value holds). Vars form a stack; leaving a scope truncates
//!   it, so a var index is valid exactly while the var is in scope.
//! * Every write to a flow goes on a trail with the value it replaced.
//!   Going back to a `Point` undoes the writes since; a branch or jump
//!   captures its `State` as the flows changed since its construct's
//!   point, so snapshots and joins cost what changed, not the scope.
//! * A `Loan` is a read or write borrow of a root var. Loans travel with
//!   values: `r = ?a` stores a read loan on `a` in `r`; `View(box: ?a)`
//!   carries it into the struct; a call whose result type can hold a
//!   borrow carries the loans of all of its arguments (so a returned
//!   borrow borrows from every borrowed argument), and a call may store
//!   its arguments' loans into its receiver and into what its `!x`
//!   arguments and other write borrows lead to. A loan that is not
//!   stored anywhere is a temporary and ends with its statement.
//! * Cells, Signals and owned closures hold no borrows: every handle to
//!   one reaches what it holds, so tracking loans per handle var would
//!   miss the other handles.
//! * Borrowed parameters hold an *external* loan on themselves: it marks
//!   a borrow that came from the caller, which may be returned or stored
//!   into other borrowed parameters, and it never conflicts.
//! * Types come from ctx's facts table (`typeOf`, `symbolAt`); an
//!   unknown type is assumed to be able to hold a borrow.
//! * A loan is in force only while the var holding it is live: while
//!   it may be used again (see `holderLive`). Borrows end at their last
//!   use, not at the end of their block.
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
//!   unreachable.
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
//!   read module-level constants but not move them.
//! * A match payload binding views the scrutinee. Moving it out consumes
//!   an owned local scrutinee and is rejected for a borrowed or shared one.
//! * A closure literal may only be bound (`f = |...|`), called in place,
//!   or made owned with `*|...|`; closure bindings cannot be copied. A
//!   closure body may only use outer locals it captures. Resources
//!   captured into a closure are owned by its environment: the body may
//!   use and clone them but not move, drop or reassign them.
//! * A `defer` body cannot move or drop outer bindings, and is re-checked
//!   against the state at every exit of its scope.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;

const diag = @import("diag.zig");

pub const Diagnostic = diag.Diagnostic;

pub const Error = std.mem.Allocator.Error;

// =============================================================================
// Abstract state
// =============================================================================

const VarId = u32;

/// Which borrows a query looks for: any, or only write borrows.
const BorrowQuery = enum { any, write };

const LoanKind = enum(u1) { read, write };

const Loan = struct {
    root: VarId,
    kind: LoanKind,
    /// Source position of the borrow, for diagnostics.
    pos: u32,
    /// Borrow provided by the caller through a parameter: may be
    /// returned and never conflicts.
    ext: bool = false,
    /// A slice of an array held in the root's own storage: it points
    /// into this function's frame even when the root is a borrowed
    /// parameter, which is a copy of the caller's value.
    frame: bool = false,

    fn sameAs(a: Loan, b: Loan) bool {
        return a.root == b.root and a.kind == b.kind and a.ext == b.ext and a.frame == b.frame;
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
    /// A loop element: the var holding the collection it walks, whose
    /// loans are the borrows its elements may hold.
    elem_of: ?VarId = null,
    /// The ctx symbol it binds, for its uses (see `holderLive`).
    sym: ?SymbolId = null,
    /// Resource captured into a closure environment (`|+x|`, `|~x|`,
    /// `|<x|`): the body sees a borrowed view of the env slot.
    capture_resource: bool = false,
    /// Match payload binding: the var the scrutinee is, or is a field
    /// of, and the field's path (empty for the whole var).
    alias_of: ?VarId = null,
    alias_path: []const u8 = "",
    /// The var with the same name this one hides, for name lookup.
    shadows: ?VarId = null,
    via: Via = .owned,
    /// Match payload binding whose variant has another field that owns
    /// a resource: moving this one out would leave that one undropped.
    /// Holds a position of such a field, for the diagnostic.
    owning_sibling: ?u32 = null,
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
    /// The code the scope covers, whose end is where its vars go out of
    /// scope; `.nil` when not known.
    node: Sexp = .nil,
};

/// One change to a var's flow, kept so it can be undone.
const Change = struct { id: VarId, old: Flow };

/// A program point to come back to: the length of the change trail and
/// of the var stack there, the temporaries, and whether it is
/// reachable. Branches, loops, and jumps capture their states relative
/// to one, so a state costs what changed since, not the whole scope.
const Point = struct {
    trail: u32,
    vars: u32,
    temps: []const Loan,
    reachable: bool,
};

/// The flow of one var in a captured state.
const Entry = struct { id: VarId, flow: Flow };

/// The state at a program point, relative to an earlier `Point`: the
/// vars (of those in scope there) whose flow differs from it, sorted by
/// var, plus the temporaries and reachability. States relative to one
/// point are joined and compared only while the current state is that
/// point's.
const State = struct {
    changes: []const Entry = &.{},
    temps: []const Loan = &.{},
    reachable: bool = true,
};

/// The abstract value of an expression: the loans it carries.
const Value = struct {
    loans: []const Loan = &.{},
};

const FnCtx = struct {
    /// The return type can carry borrows: returned values are checked
    /// for loans on locals.
    ret_may_borrow: bool = false,
    /// Checking a closure body.
    in_closure: bool = false,
};

/// A loop, or a labeled block, that `break` / `continue` can leave.
const LoopCtx = struct {
    /// The `:label` naming it, or empty.
    label: []const u8 = "",
    /// The state at loop entry; `breaks` and `conts` are relative to it.
    /// Its var count is the number of vars in scope at loop entry.
    point: Point,
    /// Number of scopes open at loop entry.
    scope_depth: usize,
    breaks: std.ArrayListUnmanaged(State) = .empty,
    conts: std.ArrayListUnmanaged(State) = .empty,
    /// The loans of the values `break` gives a loop used as a value.
    value: Value = .{},
    parent: ?*LoopCtx,
    /// False for a labeled block: only `break :label` leaves it.
    is_loop: bool = true,
    /// Source position where the loop starts: code from here on may run
    /// again in the next iteration.
    start: u32 = 0,
};

/// Where a value is being consumed, for alias diagnostics.
const Sink = enum {
    binding,
    argument,
    field,
    element,
    allocation,
    ret,
    brk,

    fn text(s: Sink) []const u8 {
        return switch (s) {
            .binding => "binding",
            .argument => "call argument",
            .field => "field assignment",
            .element => "array element",
            .allocation => "shared allocation",
            .ret => "return value",
            .brk => "`break` value",
        };
    }
};

/// Why a loop-borrow alias cannot leave its slot, for diagnostics.
const loop_borrow_rule = "a `for x in ?vec` element is a read borrow of the Vec slot and cannot be cloned, moved, dropped, or stored";

/// Owning kinds that cannot be copied implicitly.
const Owning = union(enum) {
    shared,
    weak,
    vec,
    drop_glue: []const u8, // type name
    /// A value inside a generic body whose type holds type parameters:
    /// it owns a resource if an instantiation's argument does.
    generic,
};

/// The consuming context of a branching value; `node` is its list.
const Tail = struct {
    /// The `if` or `match` node consumed by `sink`.
    node: parser.NodeId,
    sink: Sink,
};

/// A generic body copies a value of a type parameter: every
/// instantiation's argument for it must be plain data.
const PlainRequirement = struct {
    param: SymbolId,
    pos: u32,
};

// =============================================================================
// Checker
// =============================================================================

pub const Checker = struct {
    gpa: std.mem.Allocator,
    /// Allocations that outlive a function: module-level walks and the
    /// instantiation checks.
    arena_state: std.heap.ArenaAllocator,
    /// Allocations made while checking one module-level function (loans,
    /// captured states, message text): reset when it is done, so memory
    /// follows the function being checked, not the whole module.
    fn_arena_state: std.heap.ArenaAllocator,
    /// Depth of `walkFun` calls; `arena()` is the function arena inside one.
    fn_depth: u32 = 0,
    source: []const u8,
    sema: ?*const sema.SemContext = null,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    vars: std.ArrayListUnmanaged(Var) = .empty,
    /// The innermost var with each name (see `Var.shadows`).
    names: std.StringHashMapUnmanaged(VarId) = .empty,
    plain_reqs: std.ArrayListUnmanaged(PlainRequirement) = .empty,
    /// A branching value (`if` / `match` / block) whose result is taken
    /// (bound, passed, returned): the tails of its branches leave them.
    /// Set just before walking that node; see `takeTail`.
    tail: ?Tail = null,
    /// A source position at or before the statement being walked, for
    /// statements without one of their own (`break`, `continue`).
    anchor: u32 = 0,
    flows: std.ArrayListUnmanaged(Flow) = .empty,
    /// For each var, the number of loans on it that flows hold, so the
    /// checks can skip a scan for an unborrowed var.
    loan_counts: std.ArrayListUnmanaged(u32) = .empty,
    /// Every change to `flows`, so a branch can be undone back to a
    /// `Point` instead of copying the whole state (see `setFlow`).
    trail: std.ArrayListUnmanaged(Change) = .empty,
    /// Scratch space for `capture`.
    scratch: std.ArrayListUnmanaged(VarId) = .empty,
    /// Borrows end at their last use (see `holderLive`): for the function
    /// being checked, the last position each symbol is used at, and the
    /// symbols used in deferred code, which runs at scope exit.
    last_use: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    defer_used: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// `last_use` describes the code being walked.
    nll: bool = false,
    /// The innermost statement being walked.
    cur_stmt: Sexp = .nil,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Loans taken by the current statement and not stored in a var.
    temps: std.ArrayListUnmanaged(Loan) = .empty,
    reachable: bool = true,
    /// Non-zero while computing a loop fixpoint: diagnostics suppressed.
    quiet: u32 = 0,

    func: FnCtx = .{},
    loop: ?*LoopCtx = null,
    /// The label of the loop about to be walked (`:name while ...`).
    pending_label: []const u8 = "",
    /// Set immediately before walking a lambda literal that sits in an
    /// allowed position (binding RHS, call callee, `*|...|`).
    lambda_ok: bool = false,
    /// Scopes `(lo, hi]` are invisible to name lookup (while re-checking
    /// a deferred body at a scope exit).
    hidden: ?struct { lo: usize, hi: usize } = null,
    /// Walking a deferred body.
    in_defer: bool = false,
    /// Whether the last error was recorded (notes attach only to a
    /// recorded error; duplicates from re-walked code are dropped).
    last_err_kept: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Checker {
        var c = Checker{
            .gpa = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .fn_arena_state = std.heap.ArenaAllocator.init(allocator),
            .source = source,
        };
        try c.scopes.append(allocator, .{ .start = 0, .kind = .function });
        return c;
    }

    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, ctx: *const sema.SemContext) Error!Checker {
        var c = try init(allocator, source);
        c.sema = ctx;
        return c;
    }

    pub fn deinit(self: *Checker) void {
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.vars.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.plain_reqs.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        self.loan_counts.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.last_use.deinit(self.gpa);
        self.defer_used.deinit(self.gpa);
        for (self.scopes.items) |*s| s.defers.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
        self.temps.deinit(self.gpa);
        self.fn_arena_state.deinit();
        self.arena_state.deinit();
    }

    pub fn check(self: *Checker, sexp: Sexp) Error!void {
        try self.walkDecl(sexp);
        try self.checkInstantiations();
    }

    /// Generic bodies are checked once, for a `T` that may own a resource
    /// and holds no borrow. Each instantiation the module spells must fit
    /// that: an argument with drop glue only where the bodies never copy
    /// a `T`, and no borrows in the arguments of a type with methods.
    fn checkInstantiations(self: *Checker) Error!void {
        const ctx = self.sema orelse return;
        var it = ctx.instantiation_sites.iterator();
        while (it.next()) |entry| {
            const pn = switch (ctx.types.get(entry.key_ptr.*)) {
                .parameterized_nominal => |pn| pn,
                else => continue,
            };
            const base = ctx.symbols.items[pn.sym];
            if (base.decl_pos == sema.builtin_decl_pos) continue;
            const params = base.type_params orelse continue;
            const site = entry.value_ptr.*;
            const shown = try sema.formatTypeIn(ctx, self.arena(), entry.key_ptr.*);
            var has_methods = false;
            for (base.fields orelse &.{}) |f| {
                if (f.is_method and !f.is_drop_method) has_methods = true;
            }
            for (params, 0..) |param, i| {
                if (i >= pn.args.len) break;
                const arg = pn.args[i];
                const pname = ctx.symbols.items[param].name;
                const aname = try sema.formatTypeIn(ctx, self.arena(), arg);
                if (has_methods and self.mayCarryBorrow(arg)) {
                    try self.err(site, "`{s}` cannot use `{s} = {s}`: the methods of `{s}` are checked for a `{s}` that holds no borrow", .{ shown, pname, aname, base.name, pname });
                    continue;
                }
                if (!sema.typeHasDropGlue(ctx, arg)) continue;
                for (self.plain_reqs.items) |r| {
                    if (r.param != param) continue;
                    try self.err(site, "`{s}` cannot use `{s} = {s}`: the generic body copies a `{s}`, which would duplicate the resource `{s}` owns", .{ shown, pname, aname, pname, aname });
                    try self.note(r.pos, "`{s}` copied here; move it with `<` instead", .{pname});
                    break;
                }
            }
        }
    }

    pub fn hasErrors(self: *const Checker) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    fn arena(self: *Checker) std.mem.Allocator {
        if (self.fn_depth > 0) return self.fn_arena_state.allocator();
        return self.arena_state.allocator();
    }

    // -------------------------------------------------------------------------
    // Diagnostics
    // -------------------------------------------------------------------------

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.errSpan(.{ .start = pos, .end = pos }, fmt, args);
    }

    /// An error about `node`, reported at its span.
    fn errAt(self: *Checker, node: Sexp, comptime fmt: []const u8, args: anytype) Error!void {
        return self.errSpan(self.span(node), fmt, args);
    }

    fn errSpan(self: *Checker, at: diag.Span, comptime fmt: []const u8, args: anytype) Error!void {
        self.last_err_kept = false;
        if (self.quiet > 0) return;
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error" and d.pos == at.start and std.mem.eql(u8, d.message, msg)) {
                self.gpa.free(msg);
                return;
            }
        }
        try self.diagnostics.append(self.gpa, .{ .severity = .@"error", .pos = at.start, .end = at.end, .message = msg });
        self.last_err_kept = true;
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.quiet > 0 or !self.last_err_kept) return;
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.diagnostics.append(self.gpa, .{ .severity = .note, .pos = pos, .message = msg });
    }

    /// The source range of a node: its span from the parser, or from its
    /// leaves when checking without ctx.
    fn span(self: *const Checker, node: Sexp) diag.Span {
        if (self.sema) |s| return s.span(node);
        return diag.leafSpan(node);
    }

    /// Where a node starts in the source.
    fn startOf(self: *const Checker, node: Sexp) u32 {
        return self.span(node).start;
    }

    /// Note pointing at the move or drop that invalidated `v`.
    fn noteInvalidated(self: *Checker, id: VarId, use_pos: u32) Error!void {
        const v = self.vars.items[id];
        const f = self.flows.items[id];
        const what = if (f.status == .dropped) "dropped" else "moved";
        // Deferred code runs after the code that follows it.
        if (self.loop != null and f.at >= use_pos and !self.in_defer) {
            try self.note(f.at, "`{s}` was {s} here, in a previous iteration of the loop", .{ v.name, what });
        } else {
            try self.note(f.at, "`{s}` was {s} here", .{ v.name, what });
        }
    }

    fn noteLoan(self: *Checker, loan: Loan) Error!void {
        try self.note(loan.pos, "{s} borrow taken here", .{@tagName(loan.kind)});
    }

    /// What is done to a var, for a borrow conflict.
    const Access = union(enum) {
        read,
        write,
        /// Moving it (the verb: "move", "move-capture").
        consume: []const u8,
    };

    /// Report a live loan on var `id` that `access` at `pos` conflicts
    /// with: a read borrow conflicts with a write loan, anything else
    /// with every loan. Returns whether there was one.
    fn conflicts(self: *Checker, id: VarId, access: Access, pos: u32) Error!bool {
        const l = self.findLoan(id, if (access == .read) .write else .any, null) orelse return false;
        const name = self.vars.items[id].name;
        switch (access) {
            .read => try self.err(pos, "cannot read-borrow `{s}` while a write borrow is live", .{name}),
            .write => switch (l.kind) {
                .read => try self.err(pos, "cannot write-borrow `{s}` while a read borrow is live", .{name}),
                .write => try self.err(pos, "cannot take a second write borrow on `{s}`", .{name}),
            },
            .consume => |verb| try self.err(pos, "cannot {s} `{s}` while it is {s}-borrowed", .{ verb, name, @tagName(l.kind) }),
        }
        try self.noteLoan(l);
        return true;
    }

    // -------------------------------------------------------------------------
    // Vars and scopes
    // -------------------------------------------------------------------------

    /// A scope covering `node` (`.nil` when not known).
    fn pushScopeFor(self: *Checker, kind: ScopeKind, node: Sexp) Error!void {
        try self.scopes.append(self.gpa, .{ .start = @intCast(self.vars.items.len), .kind = kind, .node = node });
    }

    /// Leave the innermost scope: run its defers, check that nothing that
    /// survives holds a loan on a var declared in it, then drop its vars.
    fn popScope(self: *Checker) Error!void {
        const idx = self.scopes.items.len - 1;
        if (self.reachable) {
            try self.runDefers(idx);
            try self.checkDropOrder(self.scopes.items[idx].start);
        }
        var scope = self.scopes.pop().?;
        defer scope.defers.deinit(self.gpa);
        const start = scope.start;
        const ext = extent(scope.node);
        try self.releaseVarsFrom(start, self.reachable, if (ext.hi >= ext.lo) ext.hi +| 1 else null);
        self.truncateVars(start);
    }

    /// Remove every loan on vars `>= start` from vars below `start` and
    /// from the temporaries, reporting each surviving loan when `report`
    /// and its holder is still live at position `end`, where the scope
    /// ends (or after the current statement when null).
    fn releaseVarsFrom(self: *Checker, start: u32, report: bool, end: ?u32) Error!void {
        const borrowed = for (self.loan_counts.items[@min(start, self.loan_counts.items.len)..]) |n| {
            if (n > 0) break true;
        } else false;
        if (borrowed) for (0..@min(start, self.flows.items.len)) |holder| {
            var f = self.flows.items[holder];
            if (!hasLoanFrom(f.loans, start)) continue;
            if (report and self.holderLive(@intCast(holder), end)) {
                for (f.loans) |l| if (l.root >= start) try self.reportShortLived(l, @intCast(holder));
            }
            f.loans = try self.filterLoansBelow(f.loans, start);
            try self.setFlow(@intCast(holder), f);
        };
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

    fn addVar(self: *Checker, var_: Var, flow: Flow) Error!VarId {
        const id: VarId = @intCast(self.vars.items.len);
        var v = var_;
        if (v.kind != .hidden) if (self.sema) |ctx| {
            v.sym = ctx.symbolAt(v.decl);
        };
        if (v.name.len > 0) {
            const gop = try self.names.getOrPut(self.gpa, v.name);
            v.shadows = if (gop.found_existing) gop.value_ptr.* else null;
            gop.value_ptr.* = id;
        }
        try self.vars.append(self.gpa, v);
        try self.flows.append(self.gpa, flow);
        try self.loan_counts.append(self.gpa, 0);
        self.countLoans(flow.loans, true);
        return id;
    }

    /// Drop the vars `>= start`, youngest first, so each name they hid
    /// is visible again.
    fn truncateVars(self: *Checker, start: u32) void {
        var i = self.vars.items.len;
        while (i > start) {
            i -= 1;
            const v = self.vars.items[i];
            self.countLoans(self.flows.items[i].loans, false);
            if (v.name.len == 0) continue;
            if (v.shadows) |prev| {
                self.names.putAssumeCapacity(v.name, prev);
            } else {
                _ = self.names.remove(v.name);
            }
        }
        self.vars.shrinkRetainingCapacity(start);
        self.flows.shrinkRetainingCapacity(start);
        self.loan_counts.shrinkRetainingCapacity(start);
    }

    /// The innermost visible var named `name`. A local of a function
    /// enclosing the current closure body is not visible: typecheck
    /// reports its use.
    fn find(self: *const Checker, name: []const u8) ?VarId {
        var id = self.names.get(name) orelse return null;
        while (self.isHiddenVar(id)) id = self.vars.items[id].shadows orelse return null;
        var crossed = false;
        var si = self.scopes.items.len;
        while (si > 0) {
            si -= 1;
            const sc = self.scopes.items[si];
            if (sc.start <= id) break;
            if (sc.kind == .closure and !self.isHiddenScope(si)) crossed = true;
        }
        return if (crossed and si > 0) null else id;
    }

    fn isHiddenScope(self: *const Checker, si: usize) bool {
        const h = self.hidden orelse return false;
        return si > h.lo and si <= h.hi;
    }

    fn isHiddenVar(self: *const Checker, id: VarId) bool {
        const h = self.hidden orelse return false;
        if (h.hi <= h.lo) return false;
        const scopes = self.scopes.items;
        const end = if (h.hi + 1 < scopes.len) scopes[h.hi + 1].start else self.vars.items.len;
        return id >= scopes[h.lo + 1].start and id < end;
    }

    /// A module-level binding seen from inside a function body.
    fn isGlobal(self: *const Checker, id: VarId) bool {
        return self.scopes.items.len > 1 and id < self.scopes.items[1].start;
    }

    // -------------------------------------------------------------------------
    // State: points, captured states, join
    // -------------------------------------------------------------------------

    /// Every write to a var's flow goes through here, so it can be undone.
    fn setFlow(self: *Checker, id: VarId, flow: Flow) Error!void {
        try self.trail.append(self.gpa, .{ .id = id, .old = self.flows.items[id] });
        self.replaceFlow(id, flow);
    }

    fn replaceFlow(self: *Checker, id: VarId, flow: Flow) void {
        self.countLoans(self.flows.items[id].loans, false);
        self.countLoans(flow.loans, true);
        self.flows.items[id] = flow;
    }

    /// Add (or remove) `loans` to (from) `loan_counts`.
    fn countLoans(self: *Checker, loans: []const Loan, add: bool) void {
        for (loans) |l| {
            if (l.root >= self.loan_counts.items.len) continue;
            if (add) self.loan_counts.items[l.root] += 1 else self.loan_counts.items[l.root] -= 1;
        }
    }

    /// Whether some var's flow holds a loan on `root` (a temporary may
    /// still).
    fn isBorrowed(self: *const Checker, root: VarId) bool {
        return self.loan_counts.items[root] > 0;
    }

    /// The current program point.
    fn here(self: *Checker) Error!Point {
        return .{
            .trail = @intCast(self.trail.items.len),
            .vars = @intCast(self.vars.items.len),
            .temps = try self.arena().dupe(Loan, self.temps.items),
            .reachable = self.reachable,
        };
    }

    /// Go back to point `p`: undo every change since. The var stack is
    /// back at `p`'s depth whenever this is called (scopes are balanced),
    /// so changes to vars that have left scope since are skipped.
    fn rewind(self: *Checker, p: Point) Error!void {
        var i = self.trail.items.len;
        while (i > p.trail) {
            i -= 1;
            const c = self.trail.items[i];
            if (c.id < self.flows.items.len) self.replaceFlow(c.id, c.old);
        }
        self.trail.shrinkRetainingCapacity(p.trail);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, p.temps);
        self.reachable = p.reachable;
    }

    /// The state at point `p` itself.
    fn stateAt(p: Point) State {
        return .{ .temps = p.temps, .reachable = p.reachable };
    }

    /// The current state relative to point `p`.
    fn capture(self: *Checker, p: Point) Error!State {
        return self.captureBelow(p, p.vars);
    }

    /// The current state relative to point `p`, keeping only the first
    /// `len` vars and the loans on them: the state a jump carries out of
    /// the scopes above `len`.
    fn captureBelow(self: *Checker, p: Point, len: u32) Error!State {
        self.scratch.clearRetainingCapacity();
        for (self.trail.items[p.trail..]) |c| {
            if (c.id < len and c.id < self.flows.items.len) try self.scratch.append(self.gpa, c.id);
        }
        std.mem.sort(VarId, self.scratch.items, {}, std.sort.asc(VarId));
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var prev: ?VarId = null;
        for (self.scratch.items) |id| {
            if (prev == id) continue;
            prev = id;
            var f = self.flows.items[id];
            f.loans = try self.filterLoansBelow(f.loans, len);
            try entries.append(self.arena(), .{ .id = id, .flow = f });
        }
        return .{
            .changes = entries.items,
            .temps = try self.arena().dupe(Loan, try self.filterLoansBelow(self.temps.items, len)),
            .reachable = self.reachable,
        };
    }

    /// Make state `s` current. The current state must be its point's.
    fn apply(self: *Checker, s: State) Error!void {
        for (s.changes) |e| try self.setFlow(e.id, e.flow);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, s.temps);
        self.reachable = s.reachable;
    }

    /// Leave the current path: its state relative to point `p`, after
    /// going back to `p`.
    fn leave(self: *Checker, p: Point) Error!State {
        const s = try self.capture(p);
        try self.rewind(p);
        return s;
    }

    /// Make current the join of the current state with `states`, all
    /// relative to point `p`.
    fn joinAt(self: *Checker, p: Point, states: []const State) Error!void {
        var out = try self.leave(p);
        for (states) |s| out = try self.join(out, s);
        try self.apply(out);
    }

    /// The single merge operator of the analysis: moved or dropped on
    /// either path is moved or dropped, and loans are unioned. `a` and `b`
    /// are relative to one point, which must be the current state.
    fn join(self: *Checker, a: State, b: State) Error!State {
        if (!a.reachable) return b;
        if (!b.reachable) return a;
        var out: std.ArrayListUnmanaged(Entry) = .empty;
        var pairs: Pairs = .{ .a = a.changes, .b = b.changes };
        while (pairs.next(self)) |p| {
            const joined = try self.joinFlow(p.fa, p.fb);
            if (!flowEql(joined, self.flows.items[p.id])) try out.append(self.arena(), .{ .id = p.id, .flow = joined });
        }
        return .{ .changes = out.items, .temps = try self.unionLoans(a.temps, b.temps), .reachable = true };
    }

    fn joinFlow(self: *Checker, fa: Flow, fb: Flow) Error!Flow {
        const status: Status = @enumFromInt(@max(@intFromEnum(fa.status), @intFromEnum(fb.status)));
        return .{
            .status = status,
            .at = if (fa.status == status) fa.at else fb.at,
            .loans = try self.unionLoans(fa.loans, fb.loans),
        };
    }

    /// Whether two states relative to the current point are the same.
    fn statesEql(self: *const Checker, a: State, b: State) bool {
        if (a.reachable != b.reachable) return false;
        if (!loanSetEql(a.temps, b.temps)) return false;
        var pairs: Pairs = .{ .a = a.changes, .b = b.changes };
        while (pairs.next(self)) |p| if (!flowEql(p.fa, p.fb)) return false;
        return true;
    }

    /// Walks the vars two states relative to the current point change,
    /// in order, with each var's flow in both (its current flow in a
    /// state that does not change it).
    const Pairs = struct {
        a: []const Entry,
        b: []const Entry,
        i: usize = 0,
        j: usize = 0,

        fn next(p: *Pairs, c: *const Checker) ?struct { id: VarId, fa: Flow, fb: Flow } {
            const in_a = p.i < p.a.len;
            const in_b = p.j < p.b.len;
            if (!in_a and !in_b) return null;
            const id = if (!in_b or (in_a and p.a[p.i].id < p.b[p.j].id)) p.a[p.i].id else p.b[p.j].id;
            var fa = c.flows.items[id];
            var fb = fa;
            if (p.i < p.a.len and p.a[p.i].id == id) {
                fa = p.a[p.i].flow;
                p.i += 1;
            }
            if (p.j < p.b.len and p.b[p.j].id == id) {
                fb = p.b[p.j].flow;
                p.j += 1;
            }
            return .{ .id = id, .fa = fa, .fb = fb };
        }
    };

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

    /// A loan set holding just `l`.
    fn oneLoan(self: *Checker, l: Loan) Error![]const Loan {
        const one = try self.arena().alloc(Loan, 1);
        one[0] = l;
        return one;
    }

    fn valueUnion(self: *Checker, a: Value, b: Value) Error!Value {
        return .{ .loans = try self.unionLoans(a.loans, b.loans) };
    }

    // -------------------------------------------------------------------------
    // Loan queries
    // -------------------------------------------------------------------------

    /// A live, non-external loan on `root` held by a var or a temporary.
    /// Vars that view `skip_alias_of` (payload bindings of that scrutinee)
    /// are ignored.
    fn findLoan(self: *Checker, root: VarId, q: BorrowQuery, skip_alias_of: ?VarId) ?Loan {
        if (self.isBorrowed(root)) for (self.flows.items, self.vars.items, 0..) |f, v, holder| {
            if (skip_alias_of != null and v.alias_of == skip_alias_of) continue;
            for (f.loans) |l| if (loanMatches(l, root, q)) {
                if (self.holderLive(@intCast(holder), null)) return l;
                break;
            };
        };
        for (self.temps.items) |l| if (loanMatches(l, root, q)) return l;
        return null;
    }

    // -------------------------------------------------------------------------
    // Liveness: a borrow ends at its last use
    // -------------------------------------------------------------------------

    /// Record the last use of every symbol in `e` (a function's parameters
    /// and body), and the symbols deferred code uses. A capture's own
    /// leaf is also a use of the binding it captures.
    fn indexUses(self: *Checker, e: Sexp, in_defer: bool) Error!void {
        switch (e) {
            .src => |s| {
                const ctx = self.sema orelse return;
                const sym = ctx.symbolOf(e) orelse return;
                try self.noteUse(sym, s.pos, in_defer);
                const d = ctx.symbols.items[sym];
                if (d.kind == .capture and d.decl_pos == s.pos and d.origin != sema.symbol_invalid) {
                    try self.noteUse(d.origin, s.pos, in_defer);
                }
            },
            .list => {
                const deferred = in_defer or e.isKind(.@"defer") or e.isKind(.@"errdefer");
                for (e.items()) |c| try self.indexUses(c, deferred);
            },
            else => {},
        }
    }

    fn noteUse(self: *Checker, sym: SymbolId, pos: u32, in_defer: bool) Error!void {
        const gop = try self.last_use.getOrPut(self.gpa, sym);
        if (!gop.found_existing or gop.value_ptr.* < pos) gop.value_ptr.* = pos;
        if (in_defer) try self.defer_used.put(self.gpa, sym, {});
    }

    /// Whether the value var `id` holds may still be used after the
    /// current point (or after position `at`, a scope's end), so the
    /// loans it holds are still in force. It is live when the var is used
    /// later in the code, or anywhere in a loop around this point that
    /// does not also enclose its declaration (the next iteration runs
    /// that code again), or in deferred code, or when its type has drop
    /// glue (its drop at scope exit may reach what it borrows), or when a
    /// live var or temporary borrows it in turn. Otherwise its last use
    /// is behind, and its borrows have ended.
    fn holderLive(self: *const Checker, id: VarId, at: ?u32) bool {
        return self.holderLiveDepth(id, at, 0);
    }

    fn holderLiveDepth(self: *const Checker, id: VarId, at: ?u32, depth: u8) bool {
        if (!self.nll or depth > 16) return true;
        const ctx = self.sema orelse return true;
        const v = self.vars.items[id];
        if (v.kind == .hidden or v.kind == .param or v.closure or self.isGlobal(id)) return true;
        const sym = v.sym orelse return true;
        if (self.defer_used.contains(sym)) return true;
        const ty = v.ty orelse return true;
        // A var that owns its value drops it at scope exit. (A match
        // payload or a borrowed loop element only views a value.)
        const owns = v.alias_of == null and !v.loop_borrow and v.ref == .none;
        if (owns and (sema.typeHasDropGlue(ctx, ty) or sema.maybeDropGlue(ctx, ty))) return true;
        if (self.last_use.get(sym)) |last| if (last >= self.liveFrom(v.decl, at)) return true;
        if (self.isBorrowed(id)) for (self.flows.items, 0..) |f, j| {
            if (j == id) continue;
            for (f.loans) |l| if (l.root == id and !l.ext) {
                if (self.holderLiveDepth(@intCast(j), at, depth + 1)) return true;
                break;
            };
        };
        for (self.temps.items) |l| if (l.root == id) return true;
        return false;
    }

    /// The first position whose uses of a var declared at `decl` still
    /// lie ahead: the current statement (or `at`), or the start of an
    /// enclosing loop the var was declared outside of.
    fn liveFrom(self: *const Checker, decl: u32, at: ?u32) u32 {
        var from: u32 = at orelse self.stmtStart();
        var l = self.loop;
        while (l) |ctx| : (l = ctx.parent) {
            if (ctx.is_loop and ctx.start > decl) from = @min(from, ctx.start);
        }
        return from;
    }

    /// Where the current statement starts: its first source position
    /// (not always its first leaf, for `stmt if cond`).
    fn stmtStart(self: *const Checker) u32 {
        const ext = extent(self.cur_stmt);
        return if (ext.hi >= ext.lo) ext.lo else self.anchor;
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
        switch (sexp.kind() orelse return) {
            .module => {
                for (ir.Module.decls(sexp)) |c| if (rig.isModuleConst(c)) try self.walkDecl(c);
                for (ir.Module.decls(sexp)) |c| if (!rig.isModuleConst(c)) try self.walkDecl(c);
            },
            .fun, .sub => try self.walkFun(ir.get(sexp, .name), ir.get(sexp, .params), rig.returnType(sexp), ir.get(sexp, .body)),
            .drop_decl => try self.walkFun(.nil, ir.DropDecl.params(sexp), .nil, ir.DropDecl.body(sexp)),
            .@"struct", .@"enum", .errors, .generic_type => for (ir.rest(sexp, .members)) |c| try self.walkDecl(c),
            .@"pub" => try self.walkDecl(ir.Pub.decl(sexp)),
            .@"test" => try self.walkFun(.nil, .nil, .nil, ir.Test.body(sexp)),
            .use, .type, .@"extern", .extern_fun, .extern_sub, .variant, .@":" => {},
            else => try self.walkStmt(sexp),
        }
    }

    /// Walk a function, method, drop body or test body.
    fn walkFun(self: *Checker, name: Sexp, params: Sexp, returns: Sexp, body: Sexp) Error!void {
        const saved_func = self.func;
        const saved_loop = self.loop;
        const saved_reachable = self.reachable;
        defer {
            self.func = saved_func;
            self.loop = saved_loop;
            self.reachable = saved_reachable;
        }
        const ret_ty = self.fnReturnType(name);
        const returns_value = returns != .nil and !self.isVoid(ret_ty);
        self.func = .{ .ret_may_borrow = returns_value and self.returnMayBorrow(ret_ty, returns) };
        self.loop = null;
        // The body runs when called, not here: its effects on anything
        // outside it are undone afterwards.
        const outer = try self.here();
        self.reachable = true;
        const top = self.fn_depth == 0;
        if (top and self.sema != null) {
            self.last_use.clearRetainingCapacity();
            self.defer_used.clearRetainingCapacity();
            try self.indexUses(params, false);
            try self.indexUses(body, false);
            self.nll = true;
        }
        defer if (top) {
            self.nll = false;
        };
        self.fn_depth += 1;
        defer self.fn_depth -= 1;

        try self.pushScopeFor(.function, .nil);
        for (params.items()) |p| try self.bindParam(p);
        try self.walkBody(body, returns_value);
        try self.popScope();
        try self.rewind(outer);
        // Nothing allocated for a module-level function outlives it.
        if (self.fn_depth == 1) _ = self.fn_arena_state.reset(.{ .retain_with_limit = 1 << 20 });
    }

    /// Walk a function body in the current scope. When the function
    /// returns a value, its last expression is the return value.
    fn walkBody(self: *Checker, body: Sexp, returns_value: bool) Error!void {
        const stmts: []const Sexp = if (body.isKind(.block)) ir.Block.stmts(body) else (&body)[0..1];
        for (stmts, 0..) |stmt, i| {
            try self.checkAfterJump(stmts, i);
            if (!self.reachable) break;
            if (returns_value and i == stmts.len - 1 and self.isValue(stmt)) {
                const saved_stmt = self.cur_stmt;
                self.cur_stmt = stmt;
                defer self.cur_stmt = saved_stmt;
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
            .list => switch (p.kind() orelse return) {
                .@":", .pre_param, .default => {
                    name_node = ir.get(p, .name);
                    type_node = ir.get(p, .type);
                },
                // `?self` / `!self` sugar.
                .read => {
                    name_node = ir.Read.operand(p);
                    sugar = .read;
                },
                .write => {
                    name_node = ir.Write.operand(p);
                    sugar = .write;
                },
                else => {},
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
            self.replaceFlow(id, .{ .loans = try self.oneLoan(.{ .root = id, .kind = if (ref == .write) .write else .read, .pos = pos, .ext = true }) });
        }
    }

    // -------------------------------------------------------------------------
    // Statements and blocks
    // -------------------------------------------------------------------------

    fn walkStmt(self: *Checker, stmt: Sexp) Error!void {
        _ = try self.walkStmtValue(stmt, null);
    }

    /// Walk one statement; its temporary borrows end with it. With
    /// `sink`, its value is consumed there (a loop's `as` condition).
    fn walkStmtValue(self: *Checker, stmt: Sexp, sink: ?Sink) Error!Value {
        const p = self.span(stmt);
        if (!p.isEmpty()) self.anchor = p.start;
        if (!self.reachable) return .{};
        var saved: std.ArrayListUnmanaged(Loan) = .empty;
        defer saved.deinit(self.gpa);
        try saved.appendSlice(self.gpa, self.temps.items);
        const saved_stmt = self.cur_stmt;
        self.cur_stmt = stmt;
        defer self.cur_stmt = saved_stmt;
        const v = if (sink) |k| try self.walkConsumed(stmt, k) else try self.walk(stmt);
        // The temporaries as they were before, less those on vars that
        // have left scope since.
        self.temps.clearRetainingCapacity();
        for (saved.items) |l| if (l.root < self.vars.items.len) try self.temps.append(self.gpa, l);
        return v;
    }

    /// Walk a `(block ...)` in its own scope; its value is the value of
    /// its last statement, which may not borrow the block's own locals.
    fn walkBlock(self: *Checker, block: Sexp) Error!Value {
        const stmts = ir.Block.stmts(block);
        try self.pushScopeFor(.block, block);
        var v: Value = .{};
        for (stmts, 0..) |s, i| {
            try self.checkAfterJump(stmts, i);
            if (!self.reachable) break;
            if (i == stmts.len - 1) v = try self.walkStmtValue(s, null) else try self.walkStmt(s);
        }
        v = try self.checkValueEscapesScope(v);
        try self.popScope();
        return if (self.reachable) v else .{};
    }

    /// Report loans in `v` on vars of the innermost scope and drop them.
    fn checkValueEscapesScope(self: *Checker, v: Value) Error!Value {
        if (!self.reachable) return .{};
        return self.escapeVarsFrom(v, self.scopes.items[self.scopes.items.len - 1].start);
    }

    /// Value `v` leaving the scopes of the vars `>= start`: report its
    /// loans on them and drop those.
    fn escapeVarsFrom(self: *Checker, v: Value, start: u32) Error!Value {
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
        const kind = sexp.kind() orelse return .{};
        switch (kind) {
            .fun, .sub, .drop_decl, .@"struct", .@"enum", .errors => try self.walkDecl(sexp),
            .set => try self.walkSet(sexp),
            .drop => try self.walkDrop(sexp),
            .@"return" => try self.walkReturn(sexp),
            .@"break" => try self.walkJump(sexp, .brk),
            .@"continue" => try self.walkJump(sexp, .cont),
            .@"defer", .@"errdefer" => try self.walkDefer(sexp),
            else => return switch (kind) {
                .block => self.walkBlock(sexp),
                .move => self.walkMove(ir.Move.operand(sexp)),
                .read => self.walkBorrow(ir.Read.operand(sexp), .read),
                .write => self.walkBorrow(ir.Write.operand(sexp), .write),
                .clone, .weak => self.walkCloneWeak(sexp),
                .share => self.walkShare(sexp),
                .lambda => self.walkLambda(sexp, false),
                .@"if" => self.walkIf(sexp),
                .@"while" => self.walkWhile(sexp),
                .@"for" => self.walkFor(sexp),
                .labeled => self.walkLabeled(sexp),
                .match => self.walkMatch(sexp),
                .@"catch" => self.walkCatch(sexp),
                .propagate, .propagate_none => self.walkPropagate(sexp),
                .call => self.walkCall(sexp),
                .member, .index => self.walkMember(sexp),
                .kwarg => self.walkConsumed(ir.Kwarg.value(sexp), .argument),
                .array => blk: {
                    var v: Value = .{};
                    for (ir.Array.elems(sexp)) |e| v = try self.valueUnion(v, try self.walkConsumed(e, .element));
                    break :blk v;
                },
                .raw_block => self.walk(ir.RawBlock.body(sexp)),
                .enum_lit, .use, .type, .generic_type, .generic_inst => .{},
                // Operators on values produce fresh Copy results.
                .@"+", .@"-", .@"*", .@"/", .@"%", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@">>", .@".." => blk: {
                    for (rig.children(sexp)) |c| _ = try self.walk(c);
                    break :blk .{};
                },
                else => blk: {
                    var v: Value = .{};
                    for (rig.children(sexp)) |c| v = try self.valueUnion(v, try self.walk(c));
                    break :blk v;
                },
            },
        }
        return .{};
    }

    /// Walk an expression in a position that takes ownership of its value.
    fn walkConsumed(self: *Checker, expr: Sexp, sink: Sink) Error!Value {
        if (isLambda(expr)) return self.walk(expr); // reported by walkLambda
        try self.checkNoImplicitCopy(expr, sink, false);
        // Passing a held write borrow (`w`, `e.t`) lends it on: like `!w`,
        // its holder is write-borrowed for as long as the result may keep
        // the borrow.
        if (sink == .argument and self.isWriteBorrowPlace(expr)) return self.walkBorrow(expr, .write);
        self.setTail(expr, sink);
        return self.walk(expr);
    }

    /// Mark `expr`, if it branches, as consumed by `sink`.
    fn setTail(self: *Checker, expr: Sexp, sink: Sink) void {
        const e = tailOf(expr);
        if (e.isKind(.@"if") or e.isKind(.match)) {
            self.tail = .{ .node = e.list.id, .sink = sink };
        }
    }

    /// The consuming context of the branching `node`, if any.
    fn takeTail(self: *Checker, node: Sexp) ?Tail {
        const t = self.tail orelse return null;
        if (t.node != node.list.id) return null;
        self.tail = null;
        return t;
    }

    /// Walk a branch of a consumed branching value: its tail leaves it.
    /// A match payload named there moves out of its scrutinee, which the
    /// check before the walk could not see (the name is bound in the arm).
    fn walkTailBranch(self: *Checker, body: Sexp, t: ?Tail) Error!Value {
        const ctx = t orelse return self.walk(body);
        const tail = tailOf(body);
        self.setTail(tail, ctx.sink);
        const v = try self.walk(body);
        self.tail = null;
        if (tail == .src) try self.consumeTailName(tail, ctx.sink);
        return v;
    }

    fn consumeTailName(self: *Checker, node: Sexp, sink: Sink) Error!void {
        const ctx = self.sema orelse return;
        const sym = ctx.symbolOf(node) orelse return;
        const id = self.find(self.text(node)) orelse return;
        const v = self.vars.items[id];
        if (v.decl != ctx.symbols.items[sym].decl_pos) return;
        if (!self.flowLive(id)) return;
        if (v.alias_of == null) {
            // A bare owning name returned through a branch moves out.
            if (sink == .ret and !v.closure and !v.loop_borrow and !v.capture_resource and self.returnMoves(v)) {
                _ = try self.moveVar(id, node.src.pos, .move);
            }
            return;
        }
        const k = self.owningKind(v.ty) orelse return;
        if (k == .generic and v.via != .owned) {
            // A copy for plain data; each instantiation is checked.
            return self.reportAlias(node.src.pos, v.name, true, k, .binding, v.ty);
        }
        _ = try self.movePayload(id, node.src.pos, "move");
    }

    /// A place whose value holds a write borrow (`w`, `e.t`, a struct
    /// with a `!T` field): passing it on lends that borrow.
    fn isWriteBorrowPlace(self: *Checker, expr: Sexp) bool {
        if (!self.carriesWriteBorrow(self.exprType(expr))) return false;
        return switch (expr) {
            .src => true,
            .list => expr.isKind(.member) or expr.isKind(.index),
            else => false,
        };
    }

    /// A bare use of a name.
    fn walkName(self: *Checker, node: Sexp, as_callee: bool) Error!Value {
        const pos = node.src.pos;
        const name = self.text(node);
        const id = self.find(name) orelse return .{};
        const v = self.vars.items[id];
        if (v.closure and !as_callee) {
            try self.errClosureValue(pos, name);
            return .{};
        }
        try self.checkReadable(id, pos);
        return self.varValue(id);
    }

    /// A closure binding used as a value.
    fn errClosureValue(self: *Checker, pos: u32, name: []const u8) Error!void {
        try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or aliased; call it as `{s}()`, or make the literal owned (`*|...| body`) to pass it around", .{ name, name });
    }

    /// Reading `id`: it must be live and not write-borrowed.
    fn checkReadable(self: *Checker, id: VarId, pos: u32) Error!void {
        const v = self.vars.items[id];
        if (!try self.checkLive(id, pos)) return;
        if (self.isCopy(v.ty)) return;
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "use of `{s}` while a write borrow is live", .{v.name});
            try self.noteLoan(l);
        }
    }

    /// Report a capture of a moved or dropped var. Returns whether it is
    /// live.
    fn checkCapturable(self: *Checker, id: VarId, pos: u32) Error!bool {
        if (self.flowLive(id)) return true;
        const what = if (self.flows.items[id].status == .dropped) "drop" else "move";
        try self.err(pos, "cannot capture `{s}` after {s}", .{ self.vars.items[id].name, what });
        try self.noteInvalidated(id, pos);
        return false;
    }

    /// Report a use of a moved or dropped var. Returns whether it is live.
    fn checkLive(self: *Checker, id: VarId, pos: u32) Error!bool {
        if (self.flowLive(id)) return true;
        const what = if (self.flows.items[id].status == .dropped) "drop" else "move";
        try self.err(pos, "use of `{s}` after {s}", .{ self.vars.items[id].name, what });
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

    /// The var a place expression starts from, and how it gets there.
    /// Null for anything else, and for a name the closure body did not
    /// capture (walking the expression reports it).
    fn resolvePlace(self: *const Checker, e: Sexp) ?Place {
        switch (e) {
            .src => {
                const id = self.find(self.text(e)) orelse return null;
                return .{ .root = id, .whole = true, .through_borrow = self.vars.items[id].ref != .none };
            },
            .list => switch (e.kind() orelse return null) {
                .member, .index => {
                    const object = ir.get(e, .object);
                    var p = self.resolvePlace(object) orelse return null;
                    p.whole = false;
                    if (e.isKind(.index)) p.indexed = true;
                    if (self.exprType(object)) |t| {
                        const ty = self.typeData(t);
                        if (ty == .shared) p.through_shared = true;
                        if (ty == .borrow_read or ty == .borrow_write) p.through_borrow = true;
                    }
                    return p;
                },
                else => return null,
            },
            else => return null,
        }
    }

    /// Walk the index expressions inside a place.
    fn walkPlaceIndices(self: *Checker, e: Sexp) Error!void {
        switch (e.kind() orelse return) {
            .member => try self.walkPlaceIndices(ir.Member.object(e)),
            .index => {
                try self.walkPlaceIndices(ir.Index.object(e));
                _ = try self.walk(ir.Index.index(e));
            },
            else => {},
        }
    }

    /// A `member` or `index`.
    fn walkMember(self: *Checker, e: Sexp) Error!Value {
        const obj = try self.walk(ir.get(e, .object));
        if (e.isKind(.index)) _ = try self.walk(ir.Index.index(e));
        if (!self.mayCarryBorrow(self.exprType(e))) return .{};
        return obj;
    }

    // -------------------------------------------------------------------------
    // Borrow, move, clone, drop
    // -------------------------------------------------------------------------

    fn walkBorrow(self: *Checker, inner: Sexp, kind: LoanKind) Error!Value {
        if (rig.isRangeIndex(inner)) return self.walkSlice(inner);
        const place = self.resolvePlace(inner) orelse return self.walk(inner);
        try self.walkPlaceIndices(inner);
        const id = place.root;
        const v = self.vars.items[id];
        const pos = self.startOf(inner);
        if (v.closure) {
            try self.err(pos, "closure `{s}` cannot be borrowed; call it as `{s}()`", .{ v.name, v.name });
            return .{};
        }
        return (try self.borrowVar(id, kind, pos)) orelse .{};
    }

    /// Borrow a place in var `id` at `pos`: null when `id` is moved or
    /// the borrow conflicts, both reported.
    fn borrowVar(self: *Checker, id: VarId, kind: LoanKind, pos: u32) Error!?Value {
        if (!try self.checkLive(id, pos)) return null;
        if (try self.conflicts(id, if (kind == .write) .write else .read, pos)) return null;
        const loan: Loan = .{ .root = id, .kind = kind, .pos = pos };
        try self.addTemp(loan);
        return try self.reborrow(id, loan);
    }

    /// `?xs[a..b]`. A slice of a String or a `[]T` views what that value
    /// views. A slice of a Vec borrows the Vec, whose buffer it points
    /// into. A slice of an array held in the storage of the var it is
    /// reached from, which may be a copy (a borrowed parameter, a read
    /// borrow of plain data, a loop or pattern binding), also holds a
    /// frame loan on that var, so it cannot outlive it.
    fn walkSlice(self: *Checker, slice: Sexp) Error!Value {
        const object = ir.Index.object(slice);
        const ty = self.exprType(object) orelse return self.walk(slice);
        const peeled = self.pointee(ty) orelse ty;
        if (self.typeData(peeled) != .array and !self.isVec(peeled)) return self.walk(slice);
        const place = self.resolvePlace(slice) orelse return self.walk(slice);
        try self.walkPlaceIndices(slice);
        const id = place.root;
        const pos = self.startOf(slice);
        const v = (try self.borrowVar(id, .read, pos)) orelse return .{};
        if (self.typeData(peeled) != .array or !self.inVarStorage(object)) return v;
        return .{ .loans = try self.unionLoans(v.loans, try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos, .frame = true })) };
    }

    /// Whether the value of place `e` is stored in the var the place
    /// starts from, rather than behind a pointer, a handle, or a Vec's
    /// buffer, whose own loans cover it. A read borrow of plain data is a
    /// copy; one of a value that owns resources or holds a Cell is a
    /// pointer.
    fn inVarStorage(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return true;
        if (self.exprType(e)) |ty| switch (self.typeData(ty)) {
            .borrow_write, .shared, .slice => return false,
            .borrow_read => |inner| if (sema.typeHasDropGlue(ctx, inner) or sema.holdsCellByValue(ctx, inner)) return false,
            else => if (self.isVec(ty)) return false,
        };
        if (e.isKind(.member) or e.isKind(.index)) return self.inVarStorage(ir.get(e, .object));
        return true;
    }

    /// The loans of a borrow of (a path inside) var `id`. Borrowing
    /// through a read borrow copies that borrow; borrowing an owned value
    /// or through a write borrow borrows the var itself.
    fn reborrow(self: *Checker, id: VarId, loan: Loan) Error!Value {
        const v = self.vars.items[id];
        const held = self.flows.items[id].loans;
        if (v.ref == .read or v.alias_of != null) return .{ .loans = held };
        const one = try self.oneLoan(loan);
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
    fn walkMove(self: *Checker, inner: Sexp) Error!Value {
        const place = self.resolvePlace(inner) orelse return self.walk(inner);
        if (place.whole) return self.moveVar(place.root, self.startOf(inner), .move);
        return self.movePath(inner, place);
    }

    fn moveVar(self: *Checker, id: VarId, pos: u32, verb: MoveVerb) Error!Value {
        const v = self.vars.items[id];
        const vt = verb.text();
        if (v.closure) {
            try self.errClosureValue(pos, v.name);
            return .{};
        }
        if (try self.rejectBorrowedView(id, pos, vt)) return .{};
        if (verb == .capture and v.kind == .param and v.ref != .none) {
            try self.err(pos, "cannot move-capture borrowed parameter `{s}`; the caller still owns it. Capture a clone with `|+{s}|`", .{ v.name, v.name });
            return .{};
        }
        if (!(if (verb == .capture) try self.checkCapturable(id, pos) else try self.checkLive(id, pos))) return .{};
        const value = self.varValue(id);
        if (try self.rejectGlobal(id, pos, vt)) return .{};

        // A Copy payload is copied out of its scrutinee, which stays whole.
        if (v.alias_of != null and !self.isCopy(v.ty)) return self.movePayload(id, pos, vt);

        if (try self.conflicts(id, .{ .consume = vt }, pos)) return .{};
        // `<x` ends `x`, whatever its type: a Copy value or a borrow is
        // copied out, and the name is done.
        try self.markInvalid(id, .moved, pos);
        try self.holdMoved(value);
        return value;
    }

    /// The loans a moved value carries stay in force until the end of the
    /// statement or call that consumes it, so a later argument of the
    /// same call cannot borrow or move their roots.
    fn holdMoved(self: *Checker, value: Value) Error!void {
        for (value.loans) |l| if (!l.ext) try self.addTemp(l);
    }

    /// Move (or drop, `op`) a match payload binding out of its
    /// scrutinee. The value carries what the scrutinee held.
    fn movePayload(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!Value {
        const v = self.vars.items[id];
        const root = v.alias_of.?;
        const r = self.vars.items[root];
        if (v.owning_sibling) |sib| {
            try self.err(pos, "cannot move `{s}` out of `{s}`: another field of the variant owns a resource that would never be dropped", .{ v.name, r.name });
            try self.note(sib, "this field also owns a resource", .{});
            return .{};
        }
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
        if (try self.rejectBorrowedView(root, pos, op)) return .{};
        if (v.alias_path.len > 0) {
            try self.err(pos, "cannot {s} `{s}` out of `{s}`: `{s}` still owns it (partial moves are not supported)", .{ op, v.name, v.alias_path, r.name });
            return .{};
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
        const value = self.varValue(root);
        try self.markInvalid(root, .moved, pos);
        try self.markInvalid(id, .moved, pos);
        try self.holdMoved(value);
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
        const pos = self.startOf(inner);
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

    fn markInvalid(self: *Checker, id: VarId, status: Status, pos: u32) Error!void {
        try self.setFlow(id, .{ .status = status, .at = pos });
    }

    fn flowLive(self: *Checker, id: VarId) bool {
        return self.flows.items[id].status == .live;
    }

    /// Loop elements and captured resources are views of a slot owned
    /// elsewhere: they cannot be consumed. Returns true if rejected.
    fn rejectBorrowedView(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
        const v = self.vars.items[id];
        if (v.loop_borrow) {
            try self.err(pos, "cannot {s} loop-borrow alias `{s}`; " ++ loop_borrow_rule, .{ op, v.name });
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

    /// `+x` / `~x`.
    fn walkCloneWeak(self: *Checker, e: Sexp) Error!Value {
        const inner = ir.get(e, .operand);
        const v = try self.walk(inner);
        const p = self.resolvePlace(inner);
        const id: ?VarId = if (p != null and p.?.whole) p.?.root else null;
        return self.newHandle(self.startOf(inner), try self.placeText(inner), self.exprType(e), id, v, e.isKind(.weak));
    }

    /// The value of type `ty` that a clone or weak handle (`+x`, `~x`,
    /// `|+x|`, `|~x|`) makes from var `id` or another value carrying `v`.
    /// A new handle is independent of the borrow it was reached through
    /// (a loop element, a `?*T` parameter), but reaches whatever the
    /// shared value holds; a write borrow held there cannot be duplicated.
    fn newHandle(self: *Checker, pos: u32, what: []const u8, ty: ?TypeId, id: ?VarId, v: Value, weak: bool) Error!Value {
        if (!self.mayCarryBorrow(ty)) return .{};
        const out = self.heldThroughHandle(ty, id) orelse v;
        for (out.loans) |l| if (l.kind == .write) {
            try self.err(pos, "cannot {s} `{s}`: it holds a write borrow, which cannot be duplicated", .{ if (weak) "take a weak handle to" else "clone", what });
            try self.noteLoan(l);
            return .{};
        };
        return out;
    }

    /// What a shared value of handle type `ty` holds: nothing when its
    /// type holds no borrow, the loans of the collection a loop element
    /// `id` walks, or null to use the handle's own loans.
    fn heldThroughHandle(self: *const Checker, ty: ?TypeId, id: ?VarId) ?Value {
        const t = self.pointee(ty) orelse return null;
        const boxed: TypeId = switch (self.typeData(t)) {
            .shared, .weak => |b| b,
            .optional => |o| switch (self.typeData(o)) {
                .shared, .weak => |b| b,
                else => return null,
            },
            else => return null,
        };
        if (!self.mayCarryBorrow(boxed)) return .{};
        if (id) |i| if (self.vars.items[i].elem_of) |c| return .{ .loans = self.flows.items[c].loans };
        return null;
    }

    fn walkDrop(self: *Checker, node: Sexp) Error!void {
        const target = ir.Drop.name(node);
        const pos = target.src.pos;
        const name = self.text(target);
        const id = self.find(name) orelse return;
        const v = self.vars.items[id];
        if (try self.rejectBorrowedView(id, pos, "drop")) return;
        if (v.kind == .param and v.ref != .none) {
            try self.err(pos, "cannot drop borrowed parameter `{s}`; the caller owns it", .{name});
            return;
        }
        if (try self.rejectGlobal(id, pos, "drop")) return;
        if (!self.flowLive(id)) {
            if (self.flows.items[id].status == .moved) {
                try self.err(pos, "cannot drop `{s}` after it was moved", .{name});
            } else try self.err(pos, "cannot drop `{s}` twice", .{name});
            try self.noteInvalidated(id, pos);
            return;
        }
        if (v.alias_of != null) {
            _ = try self.movePayload(id, pos, "drop");
            if (!self.flowLive(id)) try self.markInvalid(id, .dropped, pos);
            return;
        }
        if (self.findLoan(id, .any, null)) |l| {
            try self.err(pos, "cannot drop `{s}` while borrows are live", .{name});
            try self.noteLoan(l);
            return;
        }
        try self.markInvalid(id, .dropped, pos);
    }

    // -------------------------------------------------------------------------
    // Implicit copies of owning values
    // -------------------------------------------------------------------------

    /// Reject an implicit copy of an owning value in a consuming position.
    /// `top_return`: a bare name directly in return position is a move.
    fn checkNoImplicitCopy(self: *Checker, expr: Sexp, sink: Sink, top_return: bool) Error!void {
        switch (expr) {
            .src => {
                const v = self.vars.items[self.find(self.text(expr)) orelse return];
                const pos = expr.src.pos;
                const name = v.name;
                if (v.closure) return; // reported by walkName
                if (v.loop_borrow) {
                    try self.err(pos, "bare use of loop-borrow alias `{s}` in {s} would smuggle the borrowed handle past the loop; " ++ loop_borrow_rule, .{ name, sink.text() });
                    return;
                }
                // A captured borrow passed to a call is lent for the call.
                if (v.capture_resource and !(sink == .argument and v.ref != .none)) {
                    try self.err(pos, "bare use of captured resource `{s}` in {s} would smuggle the handle out of the closure environment; use `+{s}` to clone a fresh handle, or `~{s}` for a weak reference", .{ name, sink.text(), name, name });
                    return;
                }
                if (top_return) return;
                if (self.owningKind(v.ty)) |k| return self.reportAlias(pos, name, true, k, sink, v.ty);
                if (sink == .argument) return;
                if (v.ref == .write and !self.isCopy(self.pointee(v.ty))) {
                    try self.err(pos, "bare use of write borrow `{s}` in {s} would duplicate a unique borrow; use `<{s}` to move it", .{ name, sink.text(), name });
                } else if (v.ref != .write and self.carriesWriteBorrow(v.ty)) {
                    try self.err(pos, "bare use of `{s}` in {s} would duplicate the write borrow it holds; use `<{s}` to move it", .{ name, sink.text(), name });
                }
            },
            .list => {
                switch (expr.kind() orelse return) {
                    .member, .index => {
                        // `Enum.variant` is a new value, not a field.
                        if (self.namesType(ir.get(expr, .object))) return;
                        const ty = self.exprType(expr);
                        if (self.owningKind(ty)) |k| {
                            return self.reportAlias(self.startOf(expr), try self.placeText(expr), false, k, sink, ty);
                        }
                        if (sink != .argument and self.carriesWriteBorrow(ty)) {
                            try self.errAt(expr, "bare use of `{s}` in {s} would duplicate a write borrow; a field cannot be moved out of its parent", .{ try self.placeText(expr), sink.text() });
                        }
                    },
                    // A value returned through a branch moves out, like a bare return.
                    .@"if" => {
                        try self.checkNoImplicitCopy(tailOf(ir.If.then(expr)), sink, top_return);
                        try self.checkNoImplicitCopy(tailOf(ir.If.@"else"(expr)), sink, top_return);
                    },
                    .match => for (ir.Match.arms(expr)) |arm| {
                        try self.checkNoImplicitCopy(tailOf(ir.Arm.body(arm)), sink, top_return);
                    },
                    .block => if (ir.Block.stmts(expr).len > 0) try self.checkNoImplicitCopy(tailOf(expr), sink, top_return),
                    // Operators that yield one of their operands.
                    .@"??" => {
                        try self.checkNoImplicitCopy(ir.@"??".left(expr), sink, false);
                        try self.checkNoImplicitCopy(ir.@"??".right(expr), sink, false);
                    },
                    .@"catch" => {
                        try self.checkNoImplicitCopy(ir.Catch.value(expr), sink, false);
                        try self.checkNoImplicitCopy(tailOf(ir.Catch.handler(expr)), sink, false);
                    },
                    .propagate => try self.checkNoImplicitCopy(ir.Propagate.value(expr), sink, false),
                    // `m?` copies out the value inside `m`, which only
                    // matters when that value owns or holds a write borrow.
                    .propagate_none => {
                        const ty = self.exprType(expr);
                        if (self.owningKind(ty) != null or self.carriesWriteBorrow(ty)) try self.checkNoImplicitCopy(ir.PropagateNone.value(expr), sink, false);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Whether `e` names a type (`Shape`, `lib.Shape`) rather than a value.
    fn namesType(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        const leaf = if (e.isKind(.member)) ir.Member.name(e) else e;
        if (leaf != .src) return false;
        if (e.isKind(.member)) {
            // `module.Type`: the module has no value.
            const m = ir.Member.object(e);
            if (m != .src) return false;
            const id = ctx.symbolOf(m) orelse return false;
            return ctx.symbols.items[id].kind == .module;
        }
        const id = ctx.symbolOf(e) orelse return false;
        return switch (ctx.symbols.items[id].kind) {
            .nominal_type, .generic_type, .type_alias => true,
            else => false,
        };
    }

    fn reportAlias(self: *Checker, pos: u32, what: []const u8, is_name: bool, k: Owning, sink: Sink, ty: ?TypeId) Error!void {
        const where = sink.text();
        switch (k) {
            .generic => {
                // Fine for plain data: each instantiation is checked.
                const ctx = self.sema orelse return;
                const t = ty orelse return;
                var held: std.ArrayListUnmanaged(SymbolId) = .empty;
                try sema.heldTypeVars(ctx, t, &held, self.arena());
                for (held.items) |param| {
                    for (self.plain_reqs.items) |r| {
                        if (r.param == param and r.pos == pos) break;
                    } else try self.plain_reqs.append(self.gpa, .{ .param = param, .pos = pos });
                }
            },
            .shared, .weak => {
                const kind = if (k == .shared) "shared (`*T`)" else "weak (`~T`)";
                if (is_name) {
                    try self.err(pos, "bare use of {s} handle `{s}` in {s} would alias the handle; use `<{s}` to move or `+{s}` to clone", .{ kind, what, where, what, what });
                } else {
                    try self.err(pos, "bare use of {s} handle `{s}` in {s} would alias the handle; use `+{s}` to clone", .{ kind, what, where, what });
                }
            },
            .vec => if (is_name) {
                try self.err(pos, "bare use of `Vec` value `{s}` in {s} would copy the buffer pointer and double-free on scope exit; use `<{s}` to move ownership", .{ what, where, what });
            } else {
                try self.err(pos, "bare use of `Vec` value `{s}` in {s} would copy the buffer pointer; a field cannot be moved out of its parent", .{ what, where });
            },
            .drop_glue => |tname| if (is_name) {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue (resource fields or a user `drop` declaration), so two bindings would each run the destructor. Use `<{s}` to move ownership", .{ tname, what, where, tname, what });
            } else {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue and a field cannot be moved out of its parent", .{ tname, what, where, tname });
            },
        }
    }

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    fn walkSet(self: *Checker, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const target = ir.Set.target(node);
        const expr = ir.Set.value(node);
        if (target != .src) return self.walkFieldAssign(target, expr, kind == .move);

        const pos = target.src.pos;
        const name = self.text(target);
        const is_lambda = isLambda(expr);
        const value: Value = switch (kind) {
            .move => try self.walkMove(expr),
            .default, .fixed, .shadow => if (is_lambda) blk: {
                self.lambda_ok = true;
                break :blk try self.walk(expr);
            } else try self.walkConsumed(expr, .binding),
            else => try self.walk(expr),
        };

        if (std.mem.eql(u8, name, "_")) return;

        switch (kind) {
            .shadow => try self.bindNew(target, false, is_lambda, value),
            .fixed => try self.bindNew(target, true, is_lambda, value),
            .default, .move => {
                if (self.find(name)) |id| {
                    try self.reassign(id, pos, value);
                } else {
                    try self.bindNew(target, false, is_lambda, value);
                }
            },
            // Compound assignment (`+=`, ...).
            else => {
                const id = self.find(name) orelse return;
                try self.checkReadable(id, pos);
                try self.checkAssignable(id, pos);
            },
        }
    }

    /// A new binding named by `node`, holding `value`.
    fn bindNew(self: *Checker, node: Sexp, fixed: bool, closure: bool, value: Value) Error!void {
        const pos = node.src.pos;
        const ty = self.symType(pos);
        _ = try self.addVar(.{
            .name = self.text(node),
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
        if (v.ref == .write and self.writesThrough(v)) {
            // Assigning a `!T` parameter (or loop or pattern binding)
            // writes into the value it borrows: it still borrows it, and
            // the new value may only carry borrows the caller handed in.
            // A local write borrow is rebound instead.
            for (value.loans) |l| if (self.isLocalLoan(l)) {
                try self.err(pos, "cannot store a borrow of `{s}` through `{s}`: the caller's value outlives it", .{ self.vars.items[l.root].name, v.name });
                return;
            };
            return;
        }
        // The old value is dropped (if still owned) and the binding is
        // live again with the new value.
        try self.setFlow(id, .{ .loans = if (self.mayCarryBorrow(v.ty)) value.loans else &.{} });
    }

    /// Whether assigning var `v` writes through it (a parameter, or a
    /// loop or pattern binding) rather than rebinding it.
    fn writesThrough(self: *const Checker, v: Var) bool {
        const ctx = self.sema orelse return true;
        const s = ctx.symbols.items[v.sym orelse return true];
        return s.kind == .param or s.flags.pattern_bound;
    }

    /// `p.f = e` / `v[i] = e`.
    fn walkFieldAssign(self: *Checker, target: Sexp, expr: Sexp, is_move: bool) Error!void {
        const value = if (is_move) try self.walkMove(expr) else try self.walkConsumed(expr, .field);
        const place = self.resolvePlace(target) orelse {
            _ = try self.walk(target);
            return;
        };
        try self.walkPlaceIndices(target);
        const id = place.root;
        const pos = self.startOf(target);
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
        var f = self.flows.items[id];
        f.loans = try self.unionLoans(f.loans, value.loans);
        try self.setFlow(id, f);
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    fn walkCall(self: *Checker, node: Sexp) Error!Value {
        const temps_start = self.temps.items.len;
        const callee = ir.Call.callee(node);
        const args = ir.Call.args(node);
        var result: Value = .{};

        // Method call: the receiver is borrowed for the whole call. A
        // write receiver is reserved (read) while the arguments are
        // evaluated and must be otherwise unborrowed when the call starts.
        var recv_root: ?VarId = null;
        var recv_mode: sema.MethodReceiver = .read;
        var reservation: usize = 0;
        if (callee.isKind(.member)) {
            var obj = ir.Member.object(callee);
            var explicit_write = false;
            if (obj.isKind(.write) or obj.isKind(.read)) {
                explicit_write = obj.isKind(.write);
                obj = ir.get(obj, .operand);
            }
            recv_mode = if (explicit_write) .write else self.receiverMode(obj, callee);
            const place = if (recv_mode == .value) null else self.resolvePlace(obj);
            if (place) |p| {
                const recv_val = try self.walk(obj);
                const id = p.root;
                if (self.flowLive(id) and !self.isCopy(self.vars.items[id].ty)) {
                    const pos = self.startOf(obj);
                    reservation = self.temps.items.len;
                    try self.addTemp(.{ .root = id, .kind = .read, .pos = pos });
                    recv_root = id;
                    // A built-in's methods hand out values, never borrows
                    // of the receiver.
                    const kind: LoanKind = if (recv_mode == .write) .write else .read;
                    result = if (self.builtinName(self.exprType(obj)) != null) recv_val else try self.valueUnion(recv_val, try self.reborrow(id, .{ .root = id, .kind = kind, .pos = pos }));
                }
            } else {
                result = try self.walk(ir.Member.object(callee));
            }
        } else if (callee == .src) {
            _ = try self.walkName(callee, true);
        } else if (isLambda(callee)) {
            self.lambda_ok = true;
            _ = try self.walk(callee);
        } else {
            _ = try self.walk(callee);
        }

        // `print` only reads its arguments.
        if (self.isPrint(callee)) {
            for (args) |a| _ = try self.walk(a);
            return .{};
        }
        // Every handle to a Cell or Signal reaches what it holds, so what
        // goes in (`Cell(value: v)`, `set`, `replace`, `subscribe`) may
        // not hold a borrow.
        const into = if (callee.isKind(.member) and !self.namesType(callee))
            self.builtinName(self.exprType(ir.Member.object(callee)))
        else if (self.namesType(callee)) self.builtinName(self.exprType(node)) else null;
        const cell: ?[]const u8 = if (into != null and !std.mem.eql(u8, into.?, "Vec")) into else null;
        var stored: Value = .{};
        for (args) |a| {
            const v = try self.walkConsumed(a, .argument);
            if (cell != null and v.loans.len > 0) {
                try self.errAt(a, "cannot store a borrow of `{s}` in a `{s}`: every handle to it could reach the borrow; a value stored in a Cell or Signal may not hold one", .{ self.vars.items[v.loans[0].root].name, cell.? });
                continue;
            }
            stored = try self.valueUnion(stored, v);
        }
        result = try self.valueUnion(result, stored);

        // The callee may store what its arguments borrow into anything it
        // can mutate: the receiver, and the values `!x` arguments and
        // other write borrows lead to.
        if (stored.loans.len > 0) {
            if (recv_root) |id| {
                const obj = ir.Member.object(callee);
                if (self.mayCarryBorrow(self.exprType(obj))) try self.absorbLoans(id, stored, self.startOf(obj), &.{});
            }
            for (args) |a| {
                const arg = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
                if (self.containerRoot(arg)) |id| try self.absorbLoans(id, stored, self.startOf(arg), &.{});
            }
        }

        if (recv_root) |id| if (recv_mode == .write) {
            // The reservation itself is no conflict.
            const reserved = self.temps.orderedRemove(reservation);
            _ = try self.conflicts(id, .write, self.startOf(ir.Member.object(callee)));
            try self.temps.insert(self.gpa, reservation, reserved);
        };

        // The borrows passed to the call end when it returns, unless its
        // result can carry them.
        if (!self.mayCarryBorrow(self.exprType(node))) {
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        }
        return result;
    }

    fn isPrint(self: *Checker, callee: Sexp) bool {
        if (callee != .src or !std.mem.eql(u8, self.text(callee), "print")) return false;
        if (self.sema) |ctx| return ctx.symbolOf(callee) == null;
        return self.find("print") == null;
    }

    /// `Cell`, `Signal`, or `Vec` when a value of type `ty` is one,
    /// through borrows and shared handles.
    fn builtinName(self: *const Checker, ty: ?TypeId) ?[]const u8 {
        const ctx = self.sema orelse return null;
        var t = ty orelse return null;
        while (true) switch (ctx.types.get(t)) {
            .borrow_read, .borrow_write, .shared => |i| t = i,
            .parameterized_nominal => |pn| {
                if (pn.sym == ctx.cell_sym_id) return "Cell";
                if (pn.sym == ctx.signal_sym_id) return "Signal";
                if (pn.sym == ctx.vec_sym_id) return "Vec";
                return null;
            },
            else => return null,
        };
    }

    /// The var behind an argument the callee can store into: `!x`, or a
    /// value holding a write borrow (`w`, `e.t`, `e`).
    fn containerRoot(self: *Checker, arg: Sexp) ?VarId {
        const inner = if (arg.isKind(.write)) ir.Write.operand(arg) else if (self.isWriteBorrowPlace(arg)) arg else return null;
        // What the callee could store into is the value behind a borrow.
        if (!self.mayCarryBorrow(self.pointee(self.exprType(inner)))) return null;
        const place = self.resolvePlace(inner) orelse return null;
        return place.root;
    }

    /// Record that var `id` may now hold the loans in `v`, and so may
    /// every value it write-borrows: a store through a write borrow lands
    /// there. `through` are the vars whose write borrows led to `id`;
    /// their own loans are the path, not something stored. A borrowed
    /// parameter or a module-level binding outlives this function's
    /// values: storing a borrow of one into it is rejected.
    fn absorbLoans(self: *Checker, id: VarId, v: Value, pos: u32, through: []const VarId) Error!void {
        var out: std.ArrayListUnmanaged(Loan) = .empty;
        for (v.loans) |l| {
            if (l.root != id and std.mem.indexOfScalar(VarId, through, l.root) == null) try out.append(self.arena(), l);
        }
        if (out.items.len == 0) return;
        const c = self.vars.items[id];
        if ((c.kind == .param and c.ref != .none) or self.isGlobal(id)) {
            // The caller accounts for borrows it passed in; only borrows
            // of this function's own values cannot be stored. Nothing
            // borrowed may be stored in a module-level binding.
            for (out.items) |l| if (self.isLocalLoan(l) or self.isGlobal(id)) {
                try self.err(pos, "cannot let this call store a borrow of `{s}` in `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, c.name, c.name });
                return;
            };
            return;
        }
        var f = self.flows.items[id];
        const held = f.loans;
        f.loans = try self.unionLoans(held, out.items);
        try self.setFlow(id, f);
        if (through.len > 16) return;
        const next = try std.mem.concat(self.arena(), VarId, &.{ through, &.{id} });
        for (held) |l| {
            if (l.kind == .write and std.mem.indexOfScalar(VarId, next, l.root) == null) try self.absorbLoans(l.root, v, pos, next);
        }
    }

    /// A loan on a value owned by the current function (as opposed to one
    /// the caller handed in through a borrowed parameter, or a
    /// module-level constant, which outlives every function).
    fn isLocalLoan(self: *const Checker, l: Loan) bool {
        if (l.ext or self.isGlobal(l.root)) return false;
        if (l.frame) return true;
        const r = self.vars.items[l.root];
        return !(r.kind == .param and r.ref != .none);
    }

    // -------------------------------------------------------------------------
    // Closures and shared allocation
    // -------------------------------------------------------------------------

    fn walkShare(self: *Checker, node: Sexp) Error!Value {
        const inner = ir.Share.operand(node);
        // `*|...| body`: an owned closure.
        if (isLambda(inner)) {
            self.lambda_ok = true;
            return self.walkLambda(inner, true);
        }
        return self.walkConsumed(inner, .allocation);
    }

    /// A closure literal; `owned` for `*|...| body`.
    fn walkLambda(self: *Checker, node: Sexp, owned: bool) Error!Value {
        const params = ir.Lambda.params(node);
        const body = ir.Lambda.body(node);
        if (!self.lambda_ok) {
            try self.errAt(node, "closures cannot escape their defining scope; bind the closure to a local (`f = |...| ...`) and call `f()`, or make it owned (`*|...| body`) to pass, store, or return it", .{});
        }
        self.lambda_ok = false;

        // Captures take effect on the enclosing scope, at construction.
        var value: Value = .{};
        var cap_values: std.ArrayListUnmanaged(Value) = .empty;
        const caps = sema.captureList(ir.Lambda.captures(node));
        for (caps) |cap| {
            const cv = try self.applyCapture(cap);
            try cap_values.append(self.arena(), cv);
            // An owned closure is a shared handle that may be stored
            // anywhere, including in a Cell or Signal: it holds no borrow.
            if (owned and cv.loans.len > 0) {
                const name = self.text(sema.captureNameNode(cap).?);
                const l = cv.loans[0];
                try self.err(sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture `{s}`, which holds a borrow{s}{s}{s}; capture an owned value, or use a stack closure (`|...|`)", .{
                    name,
                    if (l.ext) "" else " of `",
                    if (l.ext) "" else self.vars.items[l.root].name,
                    if (l.ext) "" else "`",
                });
                try self.noteLoan(l);
            }
            value = try self.valueUnion(value, cv);
        }

        // The body is checked as its own function; it cannot affect the
        // enclosing state.
        const snap = try self.here();
        const saved_func = self.func;
        const saved_loop = self.loop;
        self.func = .{ .in_closure = true };
        self.loop = null;
        self.reachable = true;
        try self.pushScopeFor(.closure, body);
        for (caps, cap_values.items) |cap, cv| {
            const name = sema.captureNameNode(cap).?;
            const ty = self.symType(name.src.pos);
            const resource = switch (sema.captureModeOf(cap).?) {
                .cap_clone => !self.isCopy(ty),
                .cap_weak, .cap_move => true,
            };
            _ = try self.addVar(.{
                .name = self.text(name),
                .decl = name.src.pos,
                .ty = ty,
                .kind = .capture,
                .ref = self.refOfType(ty),
                .capture_resource = resource,
            }, .{ .loans = cv.loans });
        }
        for (params.items()) |p| try self.bindParam(p);
        try self.walkBody(body, false);
        try self.popScope();
        self.func = saved_func;
        self.loop = saved_loop;
        try self.rewind(snap);
        return if (owned) .{} else value;
    }

    fn applyCapture(self: *Checker, cap: Sexp) Error!Value {
        const mode = sema.captureModeOf(cap).?;
        const node = sema.captureNameNode(cap).?;
        const pos = node.src.pos;
        const name = self.text(node);
        // Unresolved or nested captures are diagnosed by ctx.
        const id = self.find(name) orelse return .{};
        const v = self.vars.items[id];
        if (v.closure) {
            try self.err(pos, "cannot capture closure `{s}`; closures cannot be copied", .{name});
            return .{};
        }
        if (mode == .cap_move) return self.moveVar(id, pos, .capture);
        if (!try self.checkCapturable(id, pos)) return .{};
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "cannot capture `{s}` while a write borrow is live", .{name});
            try self.noteLoan(l);
            return .{};
        }
        return self.newHandle(pos, name, self.symType(pos), id, self.varValue(id), mode == .cap_weak);
    }

    // -------------------------------------------------------------------------
    // Return and escape
    // -------------------------------------------------------------------------

    fn walkReturn(self: *Checker, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        if (value != .nil) try self.walkReturnValue(value);
        try self.runDefersTo(0);
        self.reachable = false;
    }

    /// A value leaving the function: a bare local moves out; anything
    /// else must not copy an owning value; borrows must come from
    /// borrowed parameters.
    fn walkReturnValue(self: *Checker, expr: Sexp) Error!void {
        var value: Value = .{};
        if (expr == .src) {
            try self.checkNoImplicitCopy(expr, .ret, true);
            if (self.find(self.text(expr))) |id| {
                const v = self.vars.items[id];
                if (v.closure) {
                    value = try self.walkName(expr, false);
                } else if (!v.loop_borrow and !v.capture_resource) {
                    if (self.returnMoves(v)) {
                        value = try self.moveVar(id, expr.src.pos, .move);
                    } else if (try self.checkLive(id, expr.src.pos)) {
                        value = self.varValue(id);
                    }
                }
            }
        } else if (self.isValue(expr)) {
            try self.checkNoImplicitCopy(expr, .ret, true);
            self.setTail(expr, .ret);
            value = try self.walk(expr);
        } else {
            _ = try self.walk(expr);
            return;
        }
        if (self.func.ret_may_borrow and self.reachable) try self.checkEscape(value);
    }

    /// A bare name that leaves the function moves out: a match payload
    /// out of its scrutinee, and an owning value out of its binding, so
    /// deferred code at that exit sees it moved.
    fn returnMoves(self: *const Checker, v: Var) bool {
        if (v.alias_of != null) return !self.isCopy(v.ty);
        return self.owningKind(v.ty) != null;
    }

    fn checkEscape(self: *Checker, v: Value) Error!void {
        for (v.loans, 0..) |l, i| {
            if (!self.isLocalLoan(l)) continue;
            const r = self.vars.items[l.root];
            const seen = for (v.loans[0..i]) |p| {
                if (p.root == l.root and !p.ext) break true;
            } else false;
            if (seen) continue;
            if (r.kind == .param) {
                try self.err(l.pos, "cannot return a slice of `{s}`: a read-borrowed parameter of plain data is this function's own copy of the caller's value; take a `[]T` parameter to return part of an array", .{r.name});
                continue;
            }
            try self.err(l.pos, "returned borrow of `{s}` does not originate from a borrowed parameter", .{r.name});
            try self.note(r.decl, "`{s}` is local to this function", .{r.name});
        }
    }

    // -------------------------------------------------------------------------
    // Branches
    // -------------------------------------------------------------------------

    fn walkIf(self: *Checker, node: Sexp) Error!Value {
        const t = self.takeTail(node);
        const cond = ir.If.cond(node);
        const then_b = ir.If.then(node);
        const else_b = ir.If.@"else"(node);
        // `if expr as name`: the value inside the optional moves into
        // `name`, which the then-branch owns.
        const as_cond = cond.isKind(.as);
        const bound = if (as_cond) try self.walkConsumed(ir.As.value(cond), .binding) else try self.walk(cond);
        const base = try self.here();
        var v1: Value = undefined;
        if (as_cond) {
            try self.pushScopeFor(.block, then_b);
            try self.bindNew(ir.As.name(cond), false, false, bound);
            v1 = try self.checkValueEscapesScope(try self.walkTailBranch(then_b, t));
            try self.popScope();
        } else v1 = try self.walkTailBranch(then_b, t);
        const s1 = try self.leave(base);
        const v2 = if (else_b != .nil) try self.walkTailBranch(else_b, t) else Value{};
        const s2 = try self.leave(base);
        try self.apply(try self.join(s1, s2));
        return self.valueUnion(v1, v2);
    }

    /// `(catch expr name? handler)`: the handler runs when `expr` fails.
    fn walkCatch(self: *Checker, node: Sexp) Error!Value {
        const v1 = try self.walk(ir.Catch.value(node));
        const base = try self.here();
        const handler = ir.Catch.handler(node);
        try self.pushScopeFor(.block, handler);
        const name = ir.Catch.name(node);
        if (name != .nil) {
            _ = try self.addVar(.{ .name = self.text(name), .decl = name.src.pos, .ty = self.symType(name.src.pos) }, .{});
        }
        var v2 = try self.walk(handler);
        v2 = try self.checkValueEscapesScope(v2);
        try self.popScope();
        const s = try self.leave(base);
        try self.apply(try self.join(stateAt(base), s));
        return self.valueUnion(v1, v2);
    }

    const Scrutinee = struct {
        root: ?VarId = null,
        via: Via = .owned,
        /// The matched field (`h.s`) when it is not a whole binding.
        path: []const u8 = "",
    };

    fn walkMatch(self: *Checker, match: Sexp) Error!Value {
        const tail_ctx = self.takeTail(match);
        const scrut = ir.Match.subject(match);
        var info: Scrutinee = .{};
        var node = scrut;
        if (scrut.isKind(.read) or scrut.isKind(.write)) {
            node = ir.get(scrut, .operand);
            info.via = .borrowed;
        }
        if (self.resolvePlace(node)) |p| {
            info.root = p.root;
            const v = self.vars.items[p.root];
            if (p.through_borrow or v.alias_of != null) info.via = .borrowed;
            if (p.through_shared) info.via = .shared;
            if (self.exprType(node)) |t| if (self.typeData(t) == .shared) {
                info.via = .shared;
            };
            if (!p.whole) info.path = try self.placeText(node);
        }
        const scrut_value = try self.walk(scrut);

        const base = try self.here();
        var acc: ?State = null;
        var value: Value = .{};
        var catch_all = false;
        for (ir.Match.arms(match)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            const body = ir.Arm.body(arm);
            try self.pushScopeFor(.block, arm);
            if (try self.bindPattern(pattern, info, scrut_value)) catch_all = true;
            var v = try self.walkTailBranch(body, tail_ctx);
            v = try self.checkValueEscapesScope(v);
            try self.popScope();
            value = try self.valueUnion(value, v);
            const s = try self.leave(base);
            acc = if (acc) |a| try self.join(a, s) else s;
        }
        // Without a catch-all arm, no arm may run.
        if (!catch_all) acc = if (acc) |a| try self.join(a, stateAt(base)) else stateAt(base);
        try self.apply(acc orelse stateAt(base));
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
                _ = try self.bindPayload(pattern, info, scrut_value);
                return true;
            },
            .list => {
                if (pattern.isKind(.variant_pattern)) {
                    const binds = ir.VariantPattern.bindings(pattern);
                    for (binds, 0..) |b, i| {
                        if (b == .src and !std.mem.eql(u8, self.text(b), "_")) {
                            const id = try self.bindPayload(b, info, scrut_value);
                            for (binds, 0..) |other, j| {
                                if (j != i and self.owningKind(self.exprType(other)) != null) self.vars.items[id].owning_sibling = self.startOf(other);
                            }
                        }
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    fn bindPayload(self: *Checker, node: Sexp, info: Scrutinee, scrut_value: Value) Error!VarId {
        const pos = node.src.pos;
        const ty = self.symType(pos);
        var v: Var = .{ .name = self.text(node), .decl = pos, .ty = ty, .kind = .pattern, .ref = self.refOfType(ty) };
        var loans: []const Loan = &.{};
        if (!self.isCopy(ty)) {
            if (info.root) |r| {
                v.alias_of = r;
                v.alias_path = info.path;
                v.via = info.via;
                // The binding views the matched value: its root stays
                // borrowed (write-borrowed when the view holds a write
                // borrow, which must not be reached twice), and a borrowed
                // root lends what it holds.
                loans = try self.oneLoan(.{ .root = r, .kind = if (self.carriesWriteBorrow(ty)) .write else .read, .pos = pos });
                if (info.via == .borrowed) loans = try self.unionLoans(loans, self.flows.items[r].loans);
            } else {
                loans = scrut_value.loans;
            }
        }
        return self.addVar(v, .{ .loans = loans });
    }

    // -------------------------------------------------------------------------
    // Loops
    // -------------------------------------------------------------------------

    const LoopSpec = struct {
        /// The `while` or `for` node.
        node: Sexp,
        cond: ?Sexp = null,
        cond_always_true: bool = false,
        /// `while expr as name`: the binding the condition's value moves into.
        cond_binding: Sexp = .nil,
        cont: ?Sexp = null,
        body: Sexp,
        /// `for` loops: element bindings and the source loan.
        elem1: Sexp = .nil,
        elem2: Sexp = .nil,
        source_root: ?VarId = null,
        /// `for x in <v`: the loans the moved collection held, which its
        /// elements carry.
        moved: []const Loan = &.{},
        source_loan: LoanKind = .read,
        source_pos: u32 = 0,
        resource_vec: bool = false,
    };

    /// An expression that yields a value, including a loop used as one.
    fn isValue(self: *const Checker, e: Sexp) bool {
        return isValueExpr(e) or sema.hasValueBreaks(self.source, e);
    }

    fn walkWhile(self: *Checker, node: Sexp) Error!Value {
        const as_cond = ir.While.cond(node).isKind(.as);
        const cond = if (as_cond) ir.As.value(ir.While.cond(node)) else ir.While.cond(node);
        const step = ir.While.step(node);
        return self.walkLoop(.{
            .node = node,
            .cond = cond,
            .cond_binding = if (as_cond) ir.As.name(ir.While.cond(node)) else .nil,
            .cond_always_true = cond == .src and std.mem.eql(u8, self.text(cond), "true"),
            .cont = if (step == .nil) null else step,
            .body = ir.While.body(node),
        });
    }

    fn walkFor(self: *Checker, node: Sexp) Error!Value {
        const mode = ir.For.mode(node).tag;
        const source = ir.For.source(node);
        var spec: LoopSpec = .{
            .node = node,
            .body = ir.For.body(node),
            .elem1 = ir.For.@"var"(node),
            .elem2 = ir.For.index(node),
        };
        if (mode == .move) {
            spec.moved = (try self.walkMove(source)).loans;
        } else {
            _ = try self.walk(source);
            if (self.resolvePlace(source)) |p| {
                const id = p.root;
                const kind: LoanKind = if (mode == .write) .write else .read;
                spec.source_root = id;
                spec.source_loan = kind;
                spec.source_pos = self.startOf(source);
                spec.resource_vec = mode == .read and self.isResourceVec(self.exprType(source));
                if (!self.flowLive(id) or try self.conflicts(id, if (kind == .write) .write else .read, spec.source_pos)) {
                    spec.source_root = null;
                }
            }
        }
        return self.walkLoop(spec);
    }

    /// `(labeled name stmt)`: a labeled loop, or a labeled block that
    /// `break :name` leaves.
    fn walkLabeled(self: *Checker, node: Sexp) Error!Value {
        const label = self.text(ir.Labeled.label(node));
        const stmt = ir.Labeled.stmt(node);
        if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) {
            self.pending_label = label;
            const v = try self.walk(stmt);
            self.pending_label = "";
            return v;
        }
        var ctx: LoopCtx = .{ .label = label, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .is_loop = false };
        self.loop = &ctx;
        defer self.loop = ctx.parent;
        try self.walkStmt(stmt);
        try self.joinAt(ctx.point, ctx.breaks.items);
        return .{};
    }

    fn walkLoop(self: *Checker, spec: LoopSpec) Error!Value {
        var ctx: LoopCtx = .{ .label = self.pending_label, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .start = extent(spec.node).lo };
        self.pending_label = "";
        self.loop = &ctx;
        defer self.loop = ctx.parent;
        const entry = ctx.point;

        // The loop head: relative to the entry, the join of the entry, the
        // end of the body, and every `continue`.
        var head = stateAt(entry);
        self.quiet += 1;
        // The join only grows the state, over finitely many variables and
        // loans, so this reaches a fixpoint. The bound is a backstop: a
        // loop the analysis cannot settle is rejected, never accepted.
        var rounds: usize = 0;
        const converged = while (rounds < 100_000) : (rounds += 1) {
            try self.apply(head);
            const it = try self.loopIteration(spec, &ctx);
            try self.rewind(entry);
            const next = try self.join(head, it.back);
            if (self.statesEql(next, head)) break true;
            head = next;
        } else false;
        self.quiet -= 1;
        if (!converged) try self.errAt(spec.body, "this loop is too complex for the ownership checker; split it into smaller functions", .{});

        try self.apply(head);
        const it = try self.loopIteration(spec, &ctx);
        try self.rewind(entry);
        try self.apply(it.exit);
        // The `else` runs after the loop: a jump in it leaves the loop
        // around this one. A loop used as a value yields the `else` value
        // or a `break` value.
        self.loop = ctx.parent;
        var value = ctx.value;
        const e = ir.get(spec.node, .@"else");
        if (e != .nil) {
            if (sema.hasValueBreaks(self.source, spec.node)) {
                value = try self.valueUnion(value, try self.walkStmtValue(e, .brk));
            } else try self.walkStmt(e);
        }
        try self.joinAt(ctx.point, ctx.breaks.items);
        return value;
    }

    fn loopIteration(self: *Checker, spec: LoopSpec, ctx: *LoopCtx) Error!struct { back: State, exit: State } {
        ctx.breaks.clearRetainingCapacity();
        ctx.conts.clearRetainingCapacity();
        ctx.value = .{};
        const bound: Value = if (spec.cond) |c| try self.walkStmtValue(c, if (spec.cond_binding != .nil) .binding else null) else .{};
        const exit: State = if (spec.cond_always_true) .{ .reachable = false } else try self.capture(ctx.point);

        try self.pushScopeFor(.block, spec.body);
        if (spec.cond_binding != .nil) try self.bindNew(spec.cond_binding, false, false, bound);
        try self.bindLoopElems(spec);
        try self.walkStmt(spec.body);
        try self.popScope();

        if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items);
        if (spec.cont) |c| try self.walkStmt(c);
        return .{ .back = try self.capture(ctx.point), .exit = exit };
    }

    fn bindLoopElems(self: *Checker, spec: LoopSpec) Error!void {
        var elem_loans: []const Loan = &.{};
        if (spec.source_root) |root| if (self.flowLive(root)) {
            // The source stays borrowed for the whole loop.
            elem_loans = try self.oneLoan(.{ .root = root, .kind = spec.source_loan, .pos = spec.source_pos });
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
                .elem_of = if (elem_loans.len > 0) spec.source_root else null,
            }, .{ .loans = if (self.mayCarryBorrow(ty)) try self.unionLoans(elem_loans, spec.moved) else &.{} });
        }
        if (spec.elem2 == .src) {
            const pos = spec.elem2.src.pos;
            _ = try self.addVar(.{ .name = self.text(spec.elem2), .decl = pos, .ty = self.symType(pos), .kind = .loop_elem }, .{});
        }
    }

    const Jump = enum { brk, cont };

    /// Code right after `return`, `break`, or `continue` in the same
    /// block never runs; Zig rejects it, and so does Rig.
    fn checkAfterJump(self: *Checker, stmts: []const Sexp, i: usize) Error!void {
        if (i == 0) return;
        const prev = stmts[i - 1];
        if (!(prev.isKind(.@"return") or prev.isKind(.@"break") or prev.isKind(.@"continue"))) return;
        try self.errSpan(self.stmtSpan(stmts[i]), "unreachable code: this statement follows a `{s}`", .{@tagName(prev.kind().?)});
    }

    /// A statement's range: its span, or the last statement position
    /// when it has none (a bare `break` checked without the parser's
    /// spans).
    fn stmtSpan(self: *const Checker, s: Sexp) diag.Span {
        const sp = self.span(s);
        return if (sp.isEmpty()) .{ .start = self.anchor, .end = self.anchor } else sp;
    }

    /// `(break value-or-_ label?)` / `(continue label?)`: the state here
    /// flows to the loop (or labeled block) the jump names, or the
    /// innermost loop.
    fn walkJump(self: *Checker, node: Sexp, jump: Jump) Error!void {
        const label = self.text(ir.get(node, .label));
        const value = if (jump == .brk) ir.Break.value(node) else .nil;
        // A `break` value leaves the loop like a returned value leaves the
        // function: it is consumed, and it may not borrow what the loop
        // declared.
        const v: Value = if (value != .nil) try self.walkConsumed(value, .brk) else .{};
        var target = self.loop;
        while (target) |t| : (target = t.parent) {
            if (label.len == 0) {
                if (t.is_loop) break;
            } else if (std.mem.eql(u8, t.label, label)) break;
        }
        const word = if (jump == .brk) "break" else "continue";
        const at = self.stmtSpan(node);
        if (target == null) {
            const where = if (self.func.in_closure) " (a closure body cannot leave a loop around it)" else "";
            if (label.len == 0) {
                try self.errSpan(at, "`{s}` is not inside a loop{s}", .{ word, where });
            } else {
                try self.errSpan(at, "`{s} :{s}` names no enclosing loop or block{s}", .{ word, label, where });
            }
        } else if (jump == .cont and !target.?.is_loop) {
            try self.errSpan(at, "`continue :{s}` names a block, not a loop", .{label});
        }
        if (target) |t| {
            t.value = try self.valueUnion(t.value, try self.escapeVarsFrom(v, t.point.vars));
            const s = try self.exitState(t.point, t.scope_depth);
            switch (jump) {
                .brk => try t.breaks.append(self.arena(), s),
                .cont => try t.conts.append(self.arena(), s),
            }
        }
        self.reachable = false;
    }

    /// The state at a jump out to point `target` (leaving the scopes
    /// above `scope_depth`), relative to it: the scopes' defers run, and
    /// nothing that survives may borrow what is left behind.
    fn exitState(self: *Checker, target: Point, scope_depth: usize) Error!State {
        try self.runDefersTo(scope_depth);
        const depth = target.vars;
        for (self.flows.items[0..depth], 0..) |f, holder| {
            if (!hasLoanFrom(f.loans, depth) or !self.holderLive(@intCast(holder), null)) continue;
            for (f.loans) |l| if (l.root >= depth) try self.reportShortLived(l, @intCast(holder));
        }
        return self.captureBelow(target, depth);
    }

    /// `e!` / `e?`: on failure or `none`, control leaves for the caller.
    fn walkPropagate(self: *Checker, node: Sexp) Error!Value {
        const v = try self.walk(ir.get(node, .value));
        if (self.reachable) try self.runDefersTo(0);
        return v;
    }

    // -------------------------------------------------------------------------
    // Defer
    // -------------------------------------------------------------------------

    /// `defer` / `errdefer`: the body runs at scope exit. It is checked
    /// where it is written (and may not change outer state), then again
    /// at each exit of its scope against the state there.
    fn walkDefer(self: *Checker, node: Sexp) Error!void {
        const body = ir.get(node, .body);
        try self.checkDeferBody(body, true);
        try self.scopes.items[self.scopes.items.len - 1].defers.append(self.gpa, body);
    }

    fn checkDeferBody(self: *Checker, body: Sexp, report_changes: bool) Error!void {
        const snap = try self.here();
        const saved_loop = self.loop;
        const saved_in_defer = self.in_defer;
        self.loop = null;
        self.in_defer = true;
        try self.walkStmt(body);
        self.loop = saved_loop;
        self.in_defer = saved_in_defer;
        const after = try self.leave(snap);
        if (report_changes) {
            for (after.changes) |e| {
                if (e.flow.status != self.flows.items[e.id].status) {
                    try self.errAt(body, "a `defer` body cannot move or drop `{s}`; it runs when the scope exits", .{self.vars.items[e.id].name});
                    break;
                }
            }
        }
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

    /// Run the defers of the scopes an early exit leaves (every scope at
    /// index `scope_depth` or above, up to the enclosing function), and
    /// check the order their vars are dropped in.
    fn runDefersTo(self: *Checker, scope_depth: usize) Error!void {
        // An exit from inside a deferred body leaves only that body.
        if (self.in_defer) return;
        var si = self.scopes.items.len;
        while (si > scope_depth) {
            si -= 1;
            if (self.scopes.items[si].defers.items.len > 0) try self.runDefers(si);
            if (self.scopes.items[si].kind != .block) break;
        }
        if (si < self.scopes.items.len) try self.checkDropOrder(self.scopes.items[si].start);
    }

    /// Leaving scopes drops vars `>= start`, youngest first. A value whose
    /// drop runs a user `drop` body must not borrow, directly or through
    /// what it borrows, a younger value dropped (or out of scope) before
    /// it: the body could read it after.
    fn checkDropOrder(self: *Checker, start: u32) Error!void {
        const ctx = self.sema orelse return;
        const len: u32 = @intCast(self.vars.items.len);
        var reach: std.ArrayListUnmanaged(VarId) = .empty;
        for (start..len) |i| {
            const h = self.vars.items[i];
            if (!self.flowLive(@intCast(i)) or h.alias_of != null or h.loop_borrow or h.ref != .none) continue;
            if (!self.runsDropBody(h.ty orelse continue, &.{})) continue;
            reach.clearRetainingCapacity();
            try reach.append(self.arena(), @intCast(i));
            var k: usize = 0;
            while (k < reach.items.len) : (k += 1) {
                for (self.flows.items[reach.items[k]].loans) |l| {
                    if (l.ext or l.root < start or std.mem.indexOfScalar(VarId, reach.items, l.root) != null) continue;
                    try reach.append(self.arena(), l.root);
                    const x = self.vars.items[l.root];
                    if (l.root < i or !self.flowLive(l.root)) continue;
                    const glue = if (x.ty) |t| sema.typeHasDropGlue(ctx, t) else true;
                    if (!glue and self.scopeOf(l.root) == self.scopeOf(@intCast(i))) continue;
                    try self.err(l.pos, "`{s}` is dropped before `{s}`, whose `drop` body could still read it through this borrow", .{ x.name, h.name });
                    try self.note(x.decl, "`{s}` is declared after `{s}`, so it is dropped first; declare it before `{s}`", .{ x.name, h.name, h.name });
                }
            }
        }
    }

    /// The index of the innermost scope var `id` is declared in.
    fn scopeOf(self: *const Checker, id: VarId) usize {
        var si = self.scopes.items.len;
        while (si > 0) {
            si -= 1;
            if (self.scopes.items[si].start <= id) return si;
        }
        return 0;
    }

    /// Whether dropping a value of type `ty` may run a user `drop` body.
    /// `path` holds the types being looked into: a cycle adds nothing.
    fn runsDropBody(self: *const Checker, ty: TypeId, path: []const SymbolId) bool {
        const ctx = self.sema orelse return false;
        return switch (ctx.types.get(ty)) {
            .shared, .optional, .fallible => |i| self.runsDropBody(i, path),
            .array => |a| self.runsDropBody(a.elem, path),
            .imported_nominal => sema.typeHasDropGlue(ctx, ty),
            .nominal => |sid| self.fieldsRunDropBody(sid, path),
            .parameterized_nominal => |pn| blk: {
                for (pn.args) |a| if (self.runsDropBody(a, path)) break :blk true;
                break :blk self.fieldsRunDropBody(pn.sym, path);
            },
            else => false,
        };
    }

    fn fieldsRunDropBody(self: *const Checker, sid: SymbolId, path: []const SymbolId) bool {
        if (std.mem.indexOfScalar(SymbolId, path, sid) != null) return false;
        // Past any real nesting depth, assume the worst.
        if (path.len >= 32) return true;
        var buf: [32]SymbolId = undefined;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = sid;
        const inner = buf[0 .. path.len + 1];
        const fields = self.sema.?.symbols.items[sid].fields orelse return false;
        for (fields) |f| if (f.is_drop_method) return true;
        for (fields) |f| {
            if (f.is_method) continue;
            if (f.is_variant) {
                for (f.payload orelse &.{}) |pf| if (self.runsDropBody(pf.ty, inner)) return true;
            } else if (self.runsDropBody(f.ty, inner)) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Types, from ctx's facts
    // -------------------------------------------------------------------------

    fn text(self: *const Checker, node: Sexp) []const u8 {
        return switch (node) {
            .src => |s| self.source[s.pos..][0..s.len],
            else => "",
        };
    }

    /// The structure of a type (`.unknown` without ctx).
    fn typeData(self: *const Checker, id: TypeId) sema.Type {
        const ctx = self.sema orelse return .unknown;
        return ctx.types.get(id);
    }

    /// The type of the symbol declared at `decl_pos`.
    fn symType(self: *const Checker, decl_pos: u32) ?TypeId {
        const ctx = self.sema orelse return null;
        const sid = ctx.symbolAt(decl_pos) orelse return null;
        return self.known(ctx.symbols.items[sid].ty);
    }

    /// The type ctx recorded for an expression.
    fn exprType(self: *const Checker, e: Sexp) ?TypeId {
        const ctx = self.sema orelse return null;
        return self.known(ctx.typeOf(e) orelse return null);
    }

    fn known(self: *const Checker, ty: TypeId) ?TypeId {
        const ctx = self.sema orelse return null;
        if (ty == ctx.types.unknown_id or ty == ctx.types.invalid_id) return null;
        return ty;
    }

    fn isVoid(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return self.typeData(t) == .void;
    }

    /// The declared return type of the function or method named at `name`.
    fn fnReturnType(self: *const Checker, name: Sexp) ?TypeId {
        const t = self.typeData(self.exprType(name) orelse return null);
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
        return switch (self.typeData(t)) {
            .borrow_read => .read,
            .borrow_write => .write,
            else => .none,
        };
    }

    /// The type a borrow type refers to.
    fn pointee(self: *const Checker, ty: ?TypeId) ?TypeId {
        const t = ty orelse return null;
        return switch (self.typeData(t)) {
            .borrow_read, .borrow_write => |inner| inner,
            else => t,
        };
    }

    /// A primitive copied freely: numbers, `Bool`, `String`, errors.
    fn isCopy(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return sema.isCopyPrimitive(ctx, t) or ctx.types.get(t) == .any_error;
    }

    /// A `Vec(T)`.
    fn isVec(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ctx.types.get(ty);
        return t == .parameterized_nominal and t.parameterized_nominal.sym == ctx.vec_sym_id;
    }

    /// A Vec (or a borrow of one) whose elements own resources: walked
    /// by borrowed slot.
    fn isResourceVec(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        const pt = ctx.types.get(sema.unwrapBorrows(ctx, t));
        if (pt != .parameterized_nominal or pt.parameterized_nominal.sym != ctx.vec_sym_id) return false;
        if (pt.parameterized_nominal.args.len != 1) return false;
        return sema.typeHasDropGlue(ctx, pt.parameterized_nominal.args[0]);
    }

    /// Values of this type own a resource (ctx's drop glue) and cannot
    /// be copied implicitly. The kind only chooses the diagnostic.
    fn owningKind(self: *const Checker, ty: ?TypeId) ?Owning {
        const ctx = self.sema orelse return null;
        const t = ty orelse return null;
        if (!sema.typeHasDropGlue(ctx, t)) return if (sema.maybeDropGlue(ctx, t)) .generic else null;
        var inner = t;
        while (ctx.types.get(inner) == .optional) inner = ctx.types.get(inner).optional;
        return switch (ctx.types.get(inner)) {
            .shared => .shared,
            .weak => .weak,
            .parameterized_nominal => |pn| if (pn.sym == ctx.vec_sym_id) .vec else .{ .drop_glue = ctx.symbols.items[pn.sym].name },
            else => .{ .drop_glue = if (sema.nominalDecl(ctx, inner)) |d| d.symbol().name else "value" },
        };
    }

    /// Whether a value of this type can hold a borrow. Unknown types are
    /// assumed to.
    fn mayCarryBorrow(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return true;
        return sema.holdsBorrow(ctx, ty orelse return true);
    }

    /// Whether a value of this type holds a write borrow, which must not
    /// be duplicated.
    fn carriesWriteBorrow(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.holdsWriteBorrow(ctx, ty orelse return false);
    }

    /// How a method call takes its receiver, from the signature ctx
    /// resolved for the callee: `!self` writes, a `Self` value is consumed,
    /// anything else reads. A shared handle is only ever read through.
    fn receiverMode(self: *const Checker, obj: Sexp, callee: Sexp) sema.MethodReceiver {
        if (obj.isKind(.move)) return .value;
        if (self.exprType(obj)) |t| if (self.typeData(t) == .shared) return .read;
        const f = self.typeData(self.exprType(callee) orelse return .read);
        if (f != .function or f.function.params.len == 0) return .read;
        return switch (self.typeData(f.function.params[0])) {
            .borrow_write => .write,
            .nominal, .parameterized_nominal, .imported_nominal => .value,
            else => .read,
        };
    }

    fn placeText(self: *Checker, e: Sexp) Error![]const u8 {
        switch (e) {
            .src => return self.text(e),
            .list => switch (e.kind() orelse return "expression") {
                .member => return std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ try self.placeText(ir.Member.object(e)), self.text(ir.Member.name(e)) }),
                .index => return std.fmt.allocPrint(self.arena(), "{s}[...]", .{try self.placeText(ir.Index.object(e))}),
                // A sigil or other wrapper: the place it wraps.
                else => {
                    const children = rig.children(e);
                    return if (children.len > 0) self.placeText(children[0]) else "expression";
                },
            },
            else => return "expression",
        }
    }
};

// =============================================================================
// Helpers
// =============================================================================

fn isLambda(s: Sexp) bool {
    return s.isKind(.lambda);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn loanMatches(l: Loan, root: VarId, q: BorrowQuery) bool {
    return l.root == root and !l.ext and (q == .any or l.kind == .write);
}

fn containsLoan(set: []const Loan, l: Loan) bool {
    for (set) |x| if (x.sameAs(l)) return true;
    return false;
}

/// Two flows agree for the analysis (the position of a move is only
/// for messages).
fn flowEql(a: Flow, b: Flow) bool {
    return a.status == b.status and loanSetEql(a.loans, b.loans);
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
    if (s.isKind(.block)) {
        const stmts = ir.Block.stmts(s);
        if (stmts.len == 0) return .nil;
        return tailOf(stmts[stmts.len - 1]);
    }
    return s;
}

/// Whether a statement produces a value (as opposed to binding, jumping
/// or looping).
fn isValueExpr(s: Sexp) bool {
    if (s != .list) return s == .src;
    return switch (s.kind() orelse return false) {
        .set, .@"return", .@"break", .@"continue", .@"while", .@"for", .drop, .@"defer", .@"errdefer", .labeled => false,
        else => true,
    };
}

fn refOfTypeSexp(t: Sexp) Ref {
    if (t.isKind(.borrow_read)) return .read;
    if (t.isKind(.borrow_write)) return .write;
    return .none;
}

fn sexpMentionsBorrow(t: Sexp) bool {
    if (t != .list) return false;
    for (t.items()) |c| {
        if (c == .tag and (c.tag == .borrow_read or c.tag == .borrow_write)) return true;
        if (sexpMentionsBorrow(c)) return true;
    }
    return false;
}

/// The lowest and highest source positions in `s`; `lo > hi` when it
/// has none.
fn extent(s: Sexp) struct { lo: u32, hi: u32 } {
    switch (s) {
        .src => |src| return .{ .lo = src.pos, .hi = src.pos },
        .list => {
            var lo: u32 = std.math.maxInt(u32);
            var hi: u32 = 0;
            for (s.items()) |c| {
                const e = extent(c);
                if (e.hi < e.lo) continue;
                lo = @min(lo, e.lo);
                hi = @max(hi, e.hi);
            }
            return .{ .lo = lo, .hi = hi };
        },
        else => return .{ .lo = std.math.maxInt(u32), .hi = 0 },
    }
}

// =============================================================================
// Tests (without ctx: every type is unknown, so every value is treated
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
    const tree = try p.parseProgram();
    var c = try Checker.init(allocator, source);
    errdefer c.deinit();
    try c.check(tree);
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
