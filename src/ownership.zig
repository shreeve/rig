//! Ownership checker: moves, drops, views, and aliasing of owning values.
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
//! * A `Loan` is a read or write view of a root var. Loans travel with
//!   values: `r = ?a` stores a read loan on `a` in `r`; `View(box: ?a)`
//!   carries it into the struct. A call passes on only the loans its
//!   signature shows (Core sentence 7): its result carries the loans of
//!   its callee (what a callable holds) and of the arguments whose
//!   parameters' types could hold what it views, and it may store, in
//!   its write receiver and in what its `!x` arguments and other write
//!   views lead to, the loans of the arguments (its receiver among
//!   them) whose types could be held there (`sema.CallParams`). A body
//!   is checked against its signature (`checkOrigins`). A loan that is
//!   not stored anywhere is a temporary and ends with its statement.
//! * Hidden storage emit makes is read from the storage facts
//!   (`sema.Storage`): a receiver or copied argument a call holds while
//!   it runs is a hidden var the call is lent, which ends when the call
//!   returns (`holdForCall`).
//! * Cells, Signals and owned closures hold no views: every handle to
//!   one reaches what it holds, so tracking loans per handle var would
//!   miss the other handles.
//! * A String is a view: one taken from a Text (`?t[a..b]`) views it,
//!   and any value whose type holds a String carries loans as a view
//!   does.
//! * A view carries the loans of only what could hold what it views
//!   (`carry`): a loan on a var whose type reaches that memory only
//!   through a read view it holds stands for that var's own loans, and
//!   a lend through a read view keeps what the view keeps
//!   (`walkThroughView`).
//! * View parameters hold an *external* loan on themselves: it marks
//!   a view that came from the caller, which may be returned or stored
//!   into other view parameters, and it never conflicts. A loan
//!   stored into what a view parameter reaches goes in that
//!   parameter's flow, and the parameter is live at every exit (the
//!   caller uses its value after the return), so the loan stays in
//!   force for the rest of the body.
//! * Types come from ctx's facts table (`typeOf`, `symbolAt`); an
//!   unknown type is assumed to be able to hold a view.
//! * A loan is in force only while the var holding it is live: while
//!   it may be used again (see `holderLive`). Views end at their last
//!   use, not at the end of their block.
//!
//! Control flow
//! ------------
//! * `if`, `match`, ternaries, `catch` and `??` walk every branch from the
//!   same entry state and `join` the results: a value moved or dropped on any
//!   path is moved or dropped afterwards, and loans are unioned. A guard
//!   that fails runs on the way to the later arms, which start from the
//!   join of the entry state with what each failed guard left. A match
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
//! * A moved or dropped value cannot be used, viewed, moved or dropped.
//!   Reassigning a binding makes it live again.
//! * Read views exclude writes, moves, drops and reassignment of their
//!   root; write views exclude every other use. A method call views
//!   its receiver for the whole call (`rc.show(<rc)` is rejected), and
//!   an argument that reads a value sharing storage its place owns
//!   holds that place read until the call ends (`print(v, grow(!v))`
//!   is rejected). The indexes of a viewed place (a view, a slice,
//!   a receiver) cannot lend to write or move its root, whose address is
//!   found before they run (`!ps[0].a[grow(!ps)]` is rejected); an
//!   assignment evaluates its value, then its target's indexes, then
//!   stores, so there they may.
//! * A view may not outlive its root: when a scope ends (normally or by
//!   `break`, `continue` or `!`), no surviving value may hold a loan on a
//!   var declared in it. A returned value, or one stored into something
//!   the caller owns, may only carry views the caller handed in.
//! * Values that own resources (`*T`, `~T`, `Vec[T]`, anything with drop
//!   glue) cannot be copied implicitly. In a consuming position (binding,
//!   argument, field, return, the branches of an `if`/`match` in such a
//!   position) a place expression of such a type must be written `<x` or
//!   `+x`; only a bare name returned directly moves implicitly. A value
//!   holding a write view cannot be copied either, except as a call
//!   argument (which lends it on for the call).
//! * Only whole bindings move. Moving a non-Copy value out of a field or
//!   element (`<p.a`, `<v[0]`) is rejected: a viewed or shared parent
//!   still owns it, and an owned parent would drop it again.
//! * View parameters cannot be dropped or move-captured. Functions may
//!   read module-level constants but not move them.
//! * A match payload binding of `match x` or `match ?x` views the
//!   scrutinee, and one of `match !x` lends it to write: none can be moved
//!   out. `match <x` moves `x`, and its bindings own what they bind.
//! * A closure literal may only be bound (`f = |...|`), called in place,
//!   lent to a call as a callable view (its value carries its
//!   captures' loans), or made owned with `*|...|`; closure bindings
//!   cannot be copied, and `?f` lends one. A
//!   closure body may only use outer locals it captures. Resources
//!   captured into a closure are owned by its environment: the body may
//!   use and clone them but not move, drop or reassign them.
//! * A `defer` body cannot move or drop outer bindings, and is re-checked
//!   against the state at every exit of its scope; an `errdefer` body at
//!   every exit that fails (`!`, or returning an error). At an exit the
//!   path goes on past (`e!`, `e?`, a result that may be an error), its
//!   effects are undone after the check.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");

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

/// Which loans a query looks for: any, or only write loans.
const LoanQuery = enum { any, write };

const LoanKind = enum(u1) { read, write };

/// What reads a value in place before the operands after it run: a call
/// argument, a method's receiver, the value a call calls, the left
/// operand of a binary operator, or a value that is no place being
/// indexed (see `holdRead`).
const Reader = enum(u3) { none, argument, receiver, callee, operand, base };

const Loan = struct {
    root: VarId,
    kind: LoanKind,
    /// Source position of the lend, for diagnostics.
    pos: u32,
    /// A loan provided by the caller through a parameter: may be
    /// returned and never conflicts.
    ext: bool = false,
    /// A slice of an array held in the root's own storage: it points
    /// into this function's frame even when the root is a parameter
    /// that carries the caller's views.
    frame: bool = false,
    /// What reads the root in place, by value, while the operands after
    /// it run; the value shares storage the root owns (see `holdRead`).
    held_read: Reader = .none,
    /// The root of a place whose address is being found while its
    /// indices run (see `walkIndicesHeld`).
    place_hold: bool = false,
    /// A write lend that a view which only reads it keeps as a read loan
    /// (`carryLoan`), for diagnostics.
    read_of_write: bool = false,

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

/// How a var refers to its value: owned, or through a view.
const Ref = enum { none, read, write };

/// How a match payload binding reaches the scrutinee.
const Via = enum { owned, viewed, shared };

const Var = struct {
    name: []const u8,
    decl: u32,
    ty: ?TypeId = null,
    kind: VarKind = .local,
    ref: Ref = .none,
    fixed: bool = false,
    closure: bool = false,
    /// A closure whose environment's drop may run a `drop` body
    /// (`sema.dropRunsBody`): dropping it at scope exit may read what it
    /// captured.
    env_drop_reads: bool = false,
    /// Element of `for x in ?vec` over a resource Vec: a view of
    /// the slot.
    loop_view: bool = false,
    /// Element of a loop that does not consume its collection: a view of
    /// a slot the collection still owns.
    elem_view: bool = false,
    /// A loop element: the var holding the collection it walks, whose
    /// loans are the views its elements may hold.
    elem_of: ?VarId = null,
    /// The ctx symbol it binds, for its uses (see `holderLive`).
    sym: ?SymbolId = null,
    /// Resource captured into a closure environment (`|+x|`, `|~x|`,
    /// `|<x|`): the body sees a view of the env slot.
    capture_resource: bool = false,
    /// Match payload binding: the var the scrutinee is, or is a field
    /// of, and the field's path (empty for the whole var).
    alias_of: ?VarId = null,
    alias_path: []const u8 = "",
    /// The hidden var of a read match's arm that its bindings which are
    /// no plain data view: the subject the match reads, as written. A
    /// loan on it ends with the arm (`arm_view` bindings).
    arm_of: []const u8 = "",
    /// The name `match <name` would take, for a read match whose subject
    /// is an owner's name (`arm_of`); empty when no take would compile.
    arm_take: []const u8 = "",
    /// A value a call holds in storage of its own, which lives only
    /// while the call runs (`sema.Storage` of life `call`): the receiver
    /// or argument it is lent (`holdForCall`).
    call_held: bool = false,
    /// The var with the same name this one hides, for name lookup.
    shadows: ?VarId = null,
    via: Via = .owned,
    /// A run-time parameter of the function or closure being checked:
    /// its index in the signature (a method's receiver is 0).
    param_index: ?u8 = null,
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
    defers: std.ArrayList(Deferred) = .empty,
    /// The code the scope covers, whose end is where its vars go out of
    /// scope; `.nil` when not known.
    node: Sexp = .nil,
};

/// A `defer` or `errdefer` body, and the number of vars declared before
/// it: the rest are dropped before it runs. An `errdefer` runs only at
/// an exit that fails.
const Deferred = struct { body: Sexp, vars: u32, err_only: bool };

/// An exit at which defers run, and so are re-checked (`exitTo`).
const Exit = union(enum) {
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
    fn goesOn(e: Exit) bool {
        return switch (e) {
            .scope_end, .jump, .@"return" => false,
            .propagate => true,
        };
    }
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
    /// The return type can carry views: returned values are checked
    /// for loans on locals.
    ret_may_view: bool = false,
    /// The return type, when the body returns a value.
    ret_ty: ?TypeId = null,
    /// Checking a closure body.
    in_closure: bool = false,
    /// In a closure body, the first var declared in it: a returned
    /// view of an enclosing function's value is carried by the closure
    /// into its call's result.
    closure_base: VarId = 0,
    /// Which arguments a call of this function passes loans on from: what
    /// its body may return and store (`checkOrigins`).
    origins: sema.Origins = .{},
    /// The parameters whose loans the body returns, and those whose loans
    /// it stores in what a parameter leads to (`recordResult`,
    /// `recordStore`).
    returned: sema.ParamMask = 0,
    stored: sema.ParamMask = 0,
    /// Where each was first returned or stored, for the diagnostic.
    returned_at: [@bitSizeOf(sema.ParamMask)]u32 = @splat(0),
    stored_at: [@bitSizeOf(sema.ParamMask)]u32 = @splat(0),
    /// The run-time parameters bound so far.
    params: u32 = 0,
    /// Binding run-time parameters (`bindParam`), which get an index.
    binding_params: bool = false,
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
    breaks: std.ArrayList(State) = .empty,
    conts: std.ArrayList(State) = .empty,
    /// The loans of the values `break` gives a loop used as a value.
    value: Value = .{},
    parent: ?*LoopCtx,
    /// False for a labeled block: only `break :label` leaves it.
    is_loop: bool = true,
    /// Source position where the loop starts: code from here on may run
    /// again in the next iteration.
    start: u32 = 0,
    /// Its value is read through (`SemContext.readsThrough`), so a
    /// `break` value that is a view of a Copy value is copied.
    reads: bool = false,
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

/// Why a loop view cannot leave its slot, for diagnostics.
const loop_view_rule = "a `for x in ?vec` element is a read view of the Vec slot and cannot be cloned, moved, dropped, or stored";

/// Owning kinds that cannot be copied implicitly.
const Owning = union(enum) {
    shared,
    weak,
    vec,
    box,
    text,
    drop_glue: []const u8, // type name
    /// A unique value that needs no cleanup (`sema.isUnique`).
    unique: []const u8, // type name
    /// A value inside a generic body whose type holds type parameters:
    /// it owns a resource if an instantiation's argument does.
    generic,
};

/// The consuming context of a value that yields through its parts
/// (`sema.eachTailPart`); `node` is its list.
const Tail = struct {
    /// The node (`if`, `match`, block, ...) consumed by `sink`.
    node: parser.NodeId,
    sink: Sink,
    /// The vars `>= vars` are declared inside the value, after `sink`
    /// checked its names: a tail name among them moves out.
    vars: u32,
};

const PlainRequirement = sema.PlainRequirement;

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
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    vars: std.ArrayList(Var) = .empty,
    /// The innermost var with each name (see `Var.shadows`).
    names: std.StringHashMapUnmanaged(VarId) = .empty,
    /// What generic bodies copy: this module's, found while walking them,
    /// then those of other modules' bodies its instances use.
    plain_reqs: std.ArrayList(PlainRequirement) = .empty,
    /// A value that yields through its parts (`if`, `match`, a block,
    /// ...) whose result is taken (bound, passed, returned): the tails
    /// of its parts leave them. Set just before walking that node; see
    /// `takeTail`.
    tail: ?Tail = null,
    /// `mayOwnView`'s answers, by holder and view type.
    reaches: std.AutoHashMapUnmanaged(ReachKey, sema.ViewReach) = .empty,
    /// The struct or enum whose members are being walked: the owner of a
    /// method (`declOrigins`).
    decl_owner: ?SymbolId = null,
    /// The current read match arm's hidden var (`Var.arm_of`), made when
    /// a binding first needs it.
    arm_var: ?VarId = null,
    /// The subject of the match whose arm is being bound, as written.
    arm_subject: []const u8 = "",
    /// The owner's name that subject could take instead (`Var.arm_take`).
    arm_take: []const u8 = "",
    /// The value a header holds for its construct (`Header.held`): the
    /// node that makes it, read as the hidden var `id` holding it.
    held: ?Held = null,
    /// A source position at or before the statement being walked, for
    /// statements without one of their own (`break`, `continue`).
    anchor: u32 = 0,
    flows: std.ArrayList(Flow) = .empty,
    /// For each var, the number of loans on it that flows hold, so the
    /// checks can skip a scan for an unlent var.
    loan_counts: std.ArrayList(u32) = .empty,
    /// Every change to `flows`, so a branch can be undone back to a
    /// `Point` instead of copying the whole state (see `setFlow`).
    trail: std.ArrayList(Change) = .empty,
    /// Scratch space for `capture`.
    scratch: std.ArrayList(VarId) = .empty,
    /// Views end at their last use (see `holderLive`): for the function
    /// being checked, the last position each symbol is used at, and the
    /// symbols used in deferred code, which runs at scope exit.
    last_use: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    defer_used: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// `last_use` describes the code being walked.
    nll: bool = false,
    /// The innermost statement being walked.
    cur_stmt: Sexp = .nil,
    scopes: std.ArrayList(Scope) = .empty,
    /// Loans taken by the current statement and not stored in a var.
    temps: std.ArrayList(Loan) = .empty,
    /// The hidden vars holding the owning temporaries of the statements
    /// being walked (`sema.dropsTemp`), each with its position: dropped
    /// when its statement ends.
    stmt_drops: std.ArrayList(struct { id: VarId, pos: u32 }) = .empty,
    /// The hidden vars holding what the calls being walked keep in
    /// storage of their own (`holdForCall`): each ends when its call
    /// returns (`endCallHeld`).
    call_held: std.ArrayList(VarId) = .empty,
    reachable: bool = true,
    /// Non-zero while computing a loop fixpoint: diagnostics suppressed.
    quiet: u32 = 0,

    func: FnCtx = .{},
    loop: ?*LoopCtx = null,
    /// The label of the loop about to be walked (`:name while ...`).
    pending_label: []const u8 = "",
    /// Set immediately before walking a lambda literal that sits in an
    /// allowed position (binding RHS, call callee, lent argument, `*|...|`).
    lambda_ok: bool = false,
    /// Walking the arguments of a call the type checker rejected.
    in_rejected_call: bool = false,
    /// `checkNoImplicitCopy` is inside an expression whose context reads
    /// the value a view reaches (`SemContext.readsThrough`).
    copy_reads: bool = false,
    /// The next value `walkConsumed` takes is read the same way: a
    /// `break` or `else` value of a loop whose value is read.
    value_reads: bool = false,
    /// The loop about to be walked is labeled, and its value is read.
    pending_reads: bool = false,
    /// Scopes `(lo, hi]` are invisible to name lookup (while re-checking
    /// a deferred body at a scope exit).
    hidden: ?struct { lo: usize, hi: usize } = null,
    /// Walking a deferred body.
    in_defer: bool = false,
    /// Re-checking a deferred body at a scope exit: vars from this one on
    /// were declared after the `defer`, so they are dropped before it runs.
    defer_floor: ?u32 = null,
    /// Whether the last error was recorded (notes attach only to a
    /// recorded error; duplicates from re-walked code are dropped).
    last_err_kept: bool = false,
    /// Errors found so far, reported or not (quiet walks count too), so a
    /// step can tell whether an earlier one already reported a mistake.
    errors_found: u32 = 0,
    /// How many of `plain_reqs` this module's own bodies record.
    own_plain_reqs: usize = 0,

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

    /// The copies this module's generic bodies make, for the modules that
    /// import it (`sema.SemContext.plain_reqs`).
    pub fn ownPlainReqs(self: *const Checker) []const PlainRequirement {
        return self.plain_reqs.items[0..self.own_plain_reqs];
    }

    pub fn deinit(self: *Checker) void {
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.vars.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.plain_reqs.deinit(self.gpa);
        self.stmt_drops.deinit(self.gpa);
        self.call_held.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        self.loan_counts.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.last_use.deinit(self.gpa);
        self.defer_used.deinit(self.gpa);
        for (self.scopes.items) |*s| s.defers.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
        self.temps.deinit(self.gpa);
        self.reaches.deinit(self.gpa);
        self.fn_arena_state.deinit();
        self.arena_state.deinit();
    }

    pub fn check(self: *Checker, sexp: Sexp) Error!void {
        try self.walkDecl(sexp);
        self.own_plain_reqs = self.plain_reqs.items.len;
        if (self.sema) |ctx| for (ctx.plain_reqs.items) |r| {
            if (r.module_id != 0) try self.plain_reqs.append(self.gpa, r);
        };
        try self.checkInstantiations();
    }

    /// Generic bodies are checked once, for a `T` that may own a resource
    /// and holds no view. Each instantiation the module makes must fit
    /// that: an argument with drop glue only where the bodies never copy
    /// a `T`, and no views in the arguments of a type with methods or of
    /// a generic function. A method's instance checks its own parameters;
    /// its type's are checked with the receiver's instance.
    fn checkInstantiations(self: *Checker) Error!void {
        const ctx = self.sema orelse return;
        for (ctx.fn_instances.items) |f| {
            const shown = try sema.formatFnInstanceIn(ctx, self.arena(), f.inst);
            for (f.inst.ownParams(), f.inst.ownArgs()) |param, arg| {
                if (!self.holdsMarkedViewType(arg)) {
                    try self.checkCopies(f.site, shown, param, arg);
                    try self.checkViews(f.site, shown, param, arg);
                    continue;
                }
                const pname = ctx.symbols.items[param].name;
                try self.err(f.site, "`{s}` cannot use `{s} = {s}`: a generic function is checked for a `{s}` that holds no `?T`, `!T`, or slice; take `?{s}` or `!{s}` in its signature instead", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, pname, pname });
            }
        }
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
                if (has_methods and self.holdsMarkedViewType(arg)) {
                    try self.err(site, "`{s}` cannot use `{s} = {s}`: the methods of `{s}` are checked for a `{s}` that holds no `?T`, `!T`, or slice", .{ shown, pname, aname, base.name, pname });
                    continue;
                }
                try self.checkCopies(site, shown, param, arg);
                try self.checkViews(site, shown, param, arg);
            }
        }
    }

    /// An instance whose argument for `param` holds a String, which may
    /// view a Text, where a generic body stores a `param` where no loan
    /// is tracked.
    fn checkViews(self: *Checker, site: u32, shown: []const u8, param: SymbolId, arg: TypeId) Error!void {
        const ctx = self.sema orelse return;
        if (!self.mayCarryLoan(arg) or sema.holdsMarkedView(ctx, arg)) return;
        const pname = ctx.symbols.items[param].name;
        for (self.plain_reqs.items) |r| {
            if (r.param != param or !r.view) continue;
            try self.err(site, "`{s}` cannot use `{s} = {s}`: the generic body stores a `{s}` in a Cell, a Signal, or an owned closure, which carries no loan, and a String may view a Text", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname });
            try self.noteIn(r.module_id, r.pos, "`{s}` stored here", .{pname});
            return;
        }
    }

    /// An instance whose argument for `param` owns a resource, where a
    /// generic body copies a `param`.
    fn checkCopies(self: *Checker, site: u32, shown: []const u8, param: SymbolId, arg: TypeId) Error!void {
        const ctx = self.sema orelse return;
        if (sema.moves(ctx, arg) != .yes) return;
        const pname = ctx.symbols.items[param].name;
        for (self.plain_reqs.items) |r| {
            if (r.param != param or r.view) continue;
            if (sema.typeHasDropGlue(ctx, arg)) {
                try self.err(site, "`{s}` cannot use `{s} = {s}`: the generic body copies a `{s}`, which would duplicate the resource `{s}` owns", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, try sema.formatTypeIn(ctx, self.arena(), arg) });
            } else try self.err(site, "`{s}` cannot use `{s} = {s}`: the generic body copies a `{s}`, and `{s}` is unique", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, try sema.formatTypeIn(ctx, self.arena(), arg) });
            if (r.element) {
                try self.noteIn(r.module_id, r.pos, "a `{s}` element is taken here while its collection still owns it; take the elements with `for x in <v`", .{pname});
            } else try self.noteIn(r.module_id, r.pos, "`{s}` copied here; move it with `<` instead", .{pname});
            return;
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

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        return self.noteIn(0, pos, fmt, args);
    }

    /// A note at `pos` in module `module_id`'s source (0 for this one).
    fn noteIn(self: *Checker, module_id: u32, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.quiet > 0 or !self.last_err_kept) return;
        const msg = try self.gpa.print(fmt, args);
        try self.diagnostics.append(self.gpa, .{ .severity = .note, .pos = pos, .message = msg, .module = module_id });
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
        if (loan.place_hold) {
            try self.note(loan.pos, "`{s}` is lent here, and the place is found up to each index before the index runs", .{self.vars.items[loan.root].name});
        } else if (loan.held_read != .none) {
            const uses = switch (loan.held_read) {
                .none, .argument => "the call uses it after its later arguments run",
                .receiver => "the call uses it as the receiver after its arguments run",
                .callee => "the call runs it after its arguments run",
                .operand => "the operator uses it after its right operand runs",
                .base => "it is indexed after its index runs",
            };
            try self.note(loan.pos, "`{s}` read here: the value shares its storage, and {s}", .{ self.vars.items[loan.root].name, uses });
        } else if (loan.read_of_write) {
            try self.note(loan.pos, "lent to write here, and kept lent to read by a view that only reads it", .{});
        } else try self.note(loan.pos, "lent to {s} here", .{@tagName(loan.kind)});
    }

    /// The end of a conflict's message for a read held in place: what
    /// holds it.
    fn heldReadClause(reader: Reader) []const u8 {
        return switch (reader) {
            .none, .argument => "while an earlier argument's read of it is in use",
            .receiver => "while the receiver's read of it is in use",
            .callee => "while the callee's read of it is in use",
            .operand => "while the left operand's read of it is in use",
            .base => "while the indexed value's read of it is in use",
        };
    }

    /// What is done to a var, for a loan conflict.
    const Access = union(enum) {
        read,
        write,
        /// Moving it (the verb: "move", "move-capture").
        consume: []const u8,
    };

    /// Report a live loan on var `id` that `access` at `pos` conflicts
    /// with: a read lend conflicts with a write loan, anything else
    /// with every loan. Returns whether there was one.
    fn conflicts(self: *Checker, id: VarId, access: Access, pos: u32) Error!bool {
        const l = self.findLoan(id, if (access == .read) .write else .any, null) orelse return false;
        const name = self.vars.items[id].name;
        const in_index = "in an index of a place it is lending";
        const held = heldReadClause(l.held_read);
        switch (access) {
            .read => if (l.held_read != .none)
                try self.err(pos, "cannot lend `{s}` to read, which holds a Cell, {s}", .{ name, held })
            else
                try self.err(pos, "cannot lend `{s}` to read while a write loan is live", .{name}),
            .write => if (l.place_hold)
                try self.err(pos, "cannot lend `{s}` to write " ++ in_index, .{name})
            else if (l.held_read != .none)
                try self.err(pos, "cannot lend `{s}` to write {s}", .{ name, held })
            else switch (l.kind) {
                .read => try self.err(pos, "cannot lend `{s}` to write while a read loan is live", .{name}),
                .write => try self.err(pos, "cannot lend `{s}` to write while a write loan is live", .{name}),
            },
            .consume => |verb| if (l.place_hold)
                try self.err(pos, "cannot {s} `{s}` " ++ in_index, .{ verb, name })
            else if (l.held_read != .none)
                try self.err(pos, "cannot {s} `{s}` {s}", .{ verb, name, held })
            else
                try self.err(pos, "cannot {s} `{s}` while a {s} loan is live", .{ verb, name, @tagName(l.kind) }),
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
            _ = try self.exitTo(.{ .exit = .scope_end });
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
        const lent = for (self.loan_counts.items[@min(start, self.loan_counts.items.len)..]) |n| {
            if (n > 0) break true;
        } else false;
        if (lent) {
            if (report) for (self.flows.items[0..@min(start, self.flows.items.len)], 0..) |f, holder| {
                if (hasLoanFrom(f.loans, start)) _ = try self.reportHolder(f, @intCast(holder), start, end);
            };
            for (0..@min(start, self.flows.items.len)) |holder| {
                var f = self.flows.items[holder];
                if (!hasLoanFrom(f.loans, start)) continue;
                f.loans = try self.filterLoansBelow(f.loans, start);
                try self.setFlow(@intCast(holder), f);
            }
        }
        // A `temps` entry reserves a var for the statement in flight (a
        // returned `?user.name`, an arm's `o = ?t[..]`); it holds nothing
        // past the statement, which every holder's own loans cover, so
        // the scope's end removes it, and a reused var id is not left
        // reserved.
        var i: usize = 0;
        while (i < self.temps.items.len) {
            if (self.temps.items[i].root >= start) {
                _ = self.temps.orderedRemove(i);
            } else i += 1;
        }
    }

    fn reportShortLived(self: *Checker, l: Loan, holder: ?VarId) Error!void {
        const root = self.vars.items[l.root];
        if (root.arm_of.len > 0) return self.reportArmView(l);
        if (root.call_held) return self.reportCallHeld(l, holder);
        if (root.kind == .hidden and root.name.len > 0) return self.reportTempOutlived(l, holder);
        try self.err(l.pos, "`{s}` does not live long enough", .{root.name});
        if (holder) |h| {
            const hv = self.vars.items[h];
            if (hv.name.len > 0) {
                try self.note(root.decl, "`{s}` goes out of scope while `{s}` still views it", .{ root.name, hv.name });
                return self.noteStringOfText(l, hv.ty);
            }
        }
        try self.note(root.decl, "`{s}` goes out of scope while it is still lent", .{root.name});
    }

    /// Where loan `l` of a Text outlives the Text in a value of type
    /// `held` whose only views are Strings (a String field or result):
    /// the String was meant to own its text.
    fn noteStringOfText(self: *Checker, l: Loan, held: ?TypeId) Error!void {
        const ctx = self.sema orelse return;
        const t = held orelse return;
        if (!self.isText(self.vars.items[l.root].ty) or !sema.holdsViewOnly(ctx, t)) return;
        try self.note(l.pos, "a `String` views text it doesn't own; store a `Text` to own it", .{});
    }

    /// A view of a read match's binding `l` names, kept past its arm.
    /// The hint offers a clone only of a binding that has one, and a
    /// take only of a subject that is an owner's name, so each form it
    /// names compiles.
    fn reportArmView(self: *Checker, l: Loan) Error!void {
        var end = l.pos;
        while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_')) end += 1;
        const name = self.source[l.pos..end];
        const root = self.vars.items[l.root];
        const clones = if (self.sema) |ctx| (if (ctx.symbolAt(l.pos)) |sym| sema.cloneable(ctx, ctx.symbols.items[sym].ty) != .no else false) else false;
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
    fn takeableSubject(self: *Checker, scrut: Sexp) []const u8 {
        const ctx = self.sema orelse return "";
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

    /// Whether var `id` holds a statement's temporary (`holdTemp`).
    fn isStmtTemp(self: *const Checker, id: VarId) bool {
        if (id >= self.vars.items.len) return false;
        const v = self.vars.items[id];
        return v.kind == .hidden and v.name.len > 0 and !v.call_held;
    }

    /// A view `l` of what a call holds only while it runs, which the
    /// call's result or `holder` keeps after the call returns.
    fn reportCallHeld(self: *Checker, l: Loan, holder: ?VarId) Error!void {
        const name = self.vars.items[l.root].name;
        try self.err(l.pos, "a view of `{s}` outlives the call, which holds `{s}` only while it runs; bind `{s}` to a name first", .{ name, name, name });
        if (!self.last_err_kept) return;
        const h = holder orelse return;
        const hv = self.vars.items[h];
        if (hv.name.len > 0) try self.note(hv.decl, "`{s}` still holds it after the call", .{hv.name});
    }

    /// A view `l` of a statement's temporary that `holder` keeps past
    /// the statement.
    fn reportTempOutlived(self: *Checker, l: Loan, holder: ?VarId) Error!void {
        try self.err(l.pos, "a view of the temporary `{s}` outlives its statement, which drops it; bind the value to a name first", .{self.vars.items[l.root].name});
        if (!self.last_err_kept) return;
        const h = holder orelse return;
        const hv = self.vars.items[h];
        if (hv.name.len > 0) try self.note(hv.decl, "`{s}` still holds it after the statement", .{hv.name});
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
    fn isLent(self: *const Checker, root: VarId) bool {
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

    /// Go back to point `p`: undo every change since. Scopes are
    /// balanced, so every var declared since `p` has left scope, except
    /// hidden ones no scope holds (a statement's temporaries, a match's
    /// `hold` var); changes to vars that have left are skipped.
    fn rewind(self: *Checker, p: Point) Error!void {
        std.debug.assert(self.vars.items.len >= p.vars);
        for (self.vars.items[p.vars..]) |v| std.debug.assert(v.kind == .hidden);
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

    /// The current state relative to point `p`: of the vars in scope
    /// there, and of the loans on them. A path that leaves the scopes
    /// opened since carries nothing else: `exitTo`, its only caller,
    /// reports what it loses.
    fn capture(self: *Checker, p: Point) Error!State {
        const len = p.vars;
        self.scratch.clearRetainingCapacity();
        for (self.trail.items[p.trail..]) |c| {
            if (c.id < len and c.id < self.flows.items.len) try self.scratch.append(self.gpa, c.id);
        }
        std.mem.sort(VarId, self.scratch.items, {}, std.sort.asc(VarId));
        var entries: std.ArrayList(Entry) = .empty;
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

    /// A statement's temporary, made since there were `depth` vars, that
    /// `holder` (whose flow is `f`) still views after the statement,
    /// which drops it: reported once.
    fn reportTempHolder(self: *Checker, f: Flow, holder: VarId, depth: u32) Error!void {
        for (f.loans) |l| {
            if (l.root < depth or !self.isStmtTemp(l.root)) continue;
            if (self.holderLive(holder, extent(self.cur_stmt).hi +| 1)) try self.reportTempOutlived(l, holder);
            return;
        }
    }

    /// How a path ends (`exitTo`).
    const ExitTo = struct {
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
    };

    /// The one way a path ends. It runs the defers its exit runs (their
    /// effects stay only where the path ends, `Exit.goesOn`), reports
    /// each loan the path drops that a holder still live where it goes
    /// on keeps (`reportDropped`), and gives the path's state relative to
    /// `x.to`.
    fn exitTo(self: *Checker, x: ExitTo) Error!State {
        if (x.exit) |e| {
            // The defers that `e` runs, re-checked against the state here.
            const back: ?Point = if (e.goesOn()) try self.here() else null;
            const top = self.scopes.items.len - 1;
            switch (e) {
                .scope_end => try self.runDefers(top, false),
                .jump => |depth| try self.runDefersTo(depth, false),
                .@"return", .propagate => |fails| try self.runDefersTo(0, fails),
            }
            if (back) |p| try self.rewind(p);
        }
        const to = x.to orelse return .{ .reachable = false };
        try self.reportDropped(to.vars, x.resume_at);
        return self.capture(to);
    }

    /// Report each var below `depth` that keeps a loan on a var at
    /// `depth` or above, which leaves scope, where the holder is live at
    /// `at` (after the current statement when null); or, when it is not,
    /// a loan on a statement's temporary that it keeps past its
    /// statement. Each holder is reported once.
    fn reportDropped(self: *Checker, depth: u32, at: ?u32) Error!void {
        for (self.flows.items[0..@min(depth, self.flows.items.len)], 0..) |f, holder| {
            if (!hasLoanFrom(f.loans, depth)) continue;
            if (!(try self.reportHolder(f, @intCast(holder), depth, at))) try self.reportTempHolder(f, @intCast(holder), depth);
        }
    }

    /// Report each loan on a var at `depth` or above that `holder`
    /// (whose flow is `f`) keeps, where the holder is live at `at` (after
    /// the current statement when null). Whether it is.
    fn reportHolder(self: *Checker, f: Flow, holder: VarId, depth: u32, at: ?u32) Error!bool {
        if (!self.holderLive(holder, at)) return false;
        for (f.loans) |l| if (l.root >= depth) try self.reportShortLived(l, holder);
        return true;
    }

    /// Make state `s` current. The current state must be its point's.
    fn apply(self: *Checker, s: State) Error!void {
        for (s.changes) |e| try self.setFlow(e.id, e.flow);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, s.temps);
        self.reachable = s.reachable;
    }

    /// Leave the current path for point `p`, going on at `resume_at`
    /// (`exitTo`): its state relative to `p`, after going back to `p`.
    fn leave(self: *Checker, p: Point, resume_at: ?u32) Error!State {
        const s = try self.exitTo(.{ .to = p, .resume_at = resume_at });
        try self.rewind(p);
        return s;
    }

    /// Make current the join of the current state, which goes on at
    /// `resume_at`, with `states`, all relative to point `p`.
    fn joinAt(self: *Checker, p: Point, states: []const State, resume_at: ?u32) Error!void {
        var out = try self.leave(p, resume_at);
        for (states) |s| out = try self.join(out, s);
        try self.apply(out);
    }

    /// The single merge operator of the analysis: moved or dropped on
    /// either path is moved or dropped, and loans are unioned. `a` and `b`
    /// are relative to one point, which must be the current state.
    fn join(self: *Checker, a: State, b: State) Error!State {
        if (!a.reachable) return b;
        if (!b.reachable) return a;
        var out: std.ArrayList(Entry) = .empty;
        var pairs: Pairs = .{ .a = a.changes, .b = b.changes };
        while (pairs.next(self)) |p| {
            const joined = try self.joinFlow(p.fa, p.fb);
            if (!flowEql(joined, self.flows.items[p.id])) try out.append(self.arena(), .{ .id = p.id, .flow = joined });
        }
        return .{ .changes = out.items, .temps = try self.unionLoans(a.temps, b.temps), .reachable = true };
    }

    fn joinFlow(self: *Checker, fa: Flow, fb: Flow) Error!Flow {
        const status: Status = @fromBackingInt(@intCast(@max(@backingInt(fa.status), @backingInt(fb.status))));
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
        var out: std.ArrayList(Loan) = .empty;
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
    fn findLoan(self: *Checker, root: VarId, q: LoanQuery, skip_alias_of: ?VarId) ?Loan {
        if (self.isLent(root)) for (self.flows.items, self.vars.items, 0..) |f, v, holder| {
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
    // Liveness: a view ends at its last use
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
    /// that code again), or in deferred code, or when its drop at scope
    /// exit may run a `drop` body, which could read what it views
    /// (`sema.dropRunsBody`; any other drop only releases memory, and
    /// uses no view), or when a live var or temporary views it in turn.
    /// Otherwise its last use is behind, and its views have ended.
    fn holderLive(self: *const Checker, id: VarId, at: ?u32) bool {
        return self.holderLiveDepth(id, at, 0);
    }

    fn holderLiveDepth(self: *const Checker, id: VarId, at: ?u32, depth: u8) bool {
        if (!self.nll or depth > 16) return true;
        const ctx = self.sema orelse return true;
        const v = self.vars.items[id];
        // A parameter is live at every exit: the caller uses the value
        // it lent a viewed one after the return.
        if (v.kind == .hidden or v.kind == .param or v.env_drop_reads or self.isGlobal(id)) return true;
        const sym = v.sym orelse return true;
        if (self.defer_used.contains(sym)) return true;
        const ty = v.ty orelse return true;
        // A var that owns its value drops it at scope exit, which uses
        // its views only through a `drop` body. (A match payload or a
        // viewed loop element only views a value.)
        const owns = v.alias_of == null and !v.loop_view and v.ref == .none;
        if (owns and sema.dropRunsBody(ctx, ty) != .no) return true;
        if (self.last_use.get(sym)) |last| if (last >= self.liveFrom(v.decl, at)) return true;
        if (self.isLent(id)) for (self.flows.items, 0..) |f, j| {
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
        if (!v.closure and !self.mayCarryLoan(v.ty)) return .{};
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
            .fun, .sub => try self.walkFun(ir.get(sexp, .name), sema.tparamsOf(sexp), ir.get(sexp, .params), rig.returnType(sexp), ir.get(sexp, .body)),
            .drop_decl => try self.walkFun(.nil, .nil, ir.DropDecl.params(sexp), .nil, ir.DropDecl.body(sexp)),
            .@"struct", .@"enum", .errors, .generic_struct => {
                const saved = self.decl_owner;
                defer self.decl_owner = saved;
                self.decl_owner = if (self.sema) |ctx| ctx.symbolOf(ir.get(sexp, .name)) else null;
                for (ir.rest(sexp, .members)) |c| try self.walkDecl(c);
            },
            .@"pub" => try self.walkDecl(ir.Pub.decl(sexp)),
            .@"test" => try self.walkFun(.nil, .nil, .nil, .nil, ir.Test.body(sexp)),
            .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_extern, .variant, .@":" => {},
            else => try self.walkStmt(sexp),
        }
    }

    /// Walk a function, method, drop body or test body. `tparams`: its
    /// compile-time parameters, whose values (`n: Int`) are Copy.
    fn walkFun(self: *Checker, name: Sexp, tparams: Sexp, params: Sexp, returns: Sexp, body: Sexp) Error!void {
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
        self.func = .{ .ret_may_view = returns_value and self.returnMayView(ret_ty, returns), .ret_ty = if (returns_value) ret_ty else null, .origins = self.declOrigins(name) };
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
        for (tparams.items()) |p| if (p != .src) try self.bindParam(p);
        try self.bindParams(params);
        try self.walkBody(body, returns_value);
        try self.popScope();
        if (name != .nil) try self.checkOrigins(try std.fmt.allocPrint(self.arena(), "`{s}`", .{self.text(name)}), name, params);
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

    /// Bind the run-time parameters `params` of the function or closure
    /// being checked, each with its index.
    fn bindParams(self: *Checker, params: Sexp) Error!void {
        self.func.binding_params = true;
        defer self.func.binding_params = false;
        for (params.items()) |p| try self.bindParam(p);
    }

    fn bindParam(self: *Checker, p: Sexp) Error!void {
        var name_node: Sexp = .nil;
        var type_node: Sexp = .nil;
        var sugar: Ref = .none;
        switch (p) {
            .src => name_node = p,
            .list => switch (p.kind() orelse return) {
                .@":", .default => {
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
                // `<self`: `self: Self`, owned.
                .move => name_node = ir.Move.operand(p),
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
        const index = self.func.params;
        if (self.func.binding_params) self.func.params += 1;
        const id = try self.addVar(.{
            .name = self.text(name_node),
            .decl = pos,
            .ty = ty,
            .kind = .param,
            .ref = ref,
            .param_index = if (self.func.binding_params and index < @bitSizeOf(sema.ParamMask)) @intCast(index) else null,
        }, .{});
        // Views handed in by the caller: an external loan on the param
        // itself marks them as returnable and conflict-free.
        if (ref != .none or (ty != null and self.mayCarryLoan(ty))) {
            self.replaceFlow(id, .{ .loans = try self.oneLoan(.{ .root = id, .kind = if (ref == .write) .write else .read, .pos = pos, .ext = true }) });
        }
    }

    // -------------------------------------------------------------------------
    // Statements and blocks
    // -------------------------------------------------------------------------

    fn walkStmt(self: *Checker, stmt: Sexp) Error!void {
        _ = try self.walkStmtValue(stmt, null);
    }

    /// Walk one statement; its temporary views end with it. With
    /// `sink`, its value is consumed there (a loop's `as` condition).
    fn walkStmtValue(self: *Checker, stmt: Sexp, sink: ?Sink) Error!Value {
        const p = self.span(stmt);
        if (!p.isEmpty()) self.anchor = p.start;
        if (!self.reachable) return .{};
        // The temporaries from before stay first: every state the
        // statement reaches keeps them, and a scope it leaves is younger.
        const temps_len = self.temps.items.len;
        const saved_stmt = self.cur_stmt;
        self.cur_stmt = stmt;
        defer self.cur_stmt = saved_stmt;
        const drops = self.stmt_drops.items.len;
        const v = if (sink) |k| try self.walkConsumed(stmt, k) else try self.walk(stmt);
        self.temps.shrinkRetainingCapacity(@min(temps_len, self.temps.items.len));
        try self.dropStmtTemps(drops);
        return v;
    }

    /// An owning temporary only read where it stands lives in a hidden
    /// var until its statement ends; what views it views that var.
    fn holdTemp(self: *Checker, node: Sexp, v: Value) Error!Value {
        const pos = self.startOf(node);
        const id = try self.addVar(.{ .name = self.spanText(node), .decl = pos, .ty = self.exprType(node), .kind = .hidden }, .{ .loans = v.loans });
        try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
        return .{ .loans = try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos }) };
    }

    /// Drop the temporaries statement-held since `start`: a value that
    /// still views one after the statement would outlive it. One whose
    /// scope already ended (a branch's) was released there.
    fn dropStmtTemps(self: *Checker, start: usize) Error!void {
        var i = self.stmt_drops.items.len;
        while (i > start) {
            i -= 1;
            const d = self.stmt_drops.items[i];
            if (d.id >= self.vars.items.len) continue;
            const t = self.vars.items[d.id];
            if (t.kind != .hidden or t.decl != d.pos) continue;
            if (self.isLent(d.id)) for (0..self.flows.items.len) |holder| {
                if (holder == d.id) continue;
                var f = self.flows.items[holder];
                var reported = false;
                var kept: std.ArrayList(Loan) = .empty;
                for (f.loans) |l| {
                    if (l.root != d.id) {
                        try kept.append(self.arena(), l);
                    } else if (!reported and self.holderLive(@intCast(holder), null)) {
                        try self.reportTempOutlived(l, @intCast(holder));
                        reported = true;
                    }
                }
                if (kept.items.len == f.loans.len) continue;
                f.loans = kept.items;
                try self.setFlow(@intCast(holder), f);
            };
            try self.setFlow(d.id, .{ .status = .dropped, .at = d.pos });
        }
        self.stmt_drops.shrinkRetainingCapacity(start);
    }

    /// A loan in `v` on a temporary held since `stmt_drops` held
    /// `drops`: one a header made, which ends with the header.
    fn headerTempLoan(self: *const Checker, drops: usize, v: Value) ?Loan {
        for (v.loans) |l| for (self.stmt_drops.items[@min(drops, self.stmt_drops.items.len)..]) |d| {
            if (d.id == l.root) return l;
        };
        return null;
    }

    /// Walk a `(block ...)` in its own scope; its value is the value of
    /// its last statement, which may not view the block's own locals.
    fn walkBlock(self: *Checker, block: Sexp) Error!Value {
        const stmts = ir.Block.stmts(block);
        const t = self.takeTail(block);
        try self.pushScopeFor(.block, block);
        var v: Value = .{};
        for (stmts, 0..) |s, i| {
            try self.checkAfterJump(stmts, i);
            if (!self.reachable) break;
            if (i < stmts.len - 1) {
                try self.walkStmt(s);
                continue;
            }
            // The value leaves: its tail name moves before the block's
            // defers run, as emit takes it there.
            if (t) |ctx| self.markTail(s, ctx);
            v = try self.walkStmtValue(s, null);
            if (t) |ctx| if (s == .src and self.reachable) try self.consumeTailName(s, ctx);
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
        // The value a header holds is read from its hidden var.
        if (self.held) |h| if (sexp.list.ptr == h.base.list.ptr) {
            try self.checkReadable(h.id, self.startOf(sexp));
            return self.varValue(h.id);
        };
        // A temporary is taken into its statement's slot: a block or
        // `match` value's tail leaves its scope as it would for a binding.
        if (self.sema) |ctx| if (ctx.dropsTemp(sexp)) {
            try self.checkNoImplicitCopy(sexp, .binding, false);
            self.setTail(sexp, .binding);
            return self.holdTemp(sexp, try self.walkList(sexp, kind));
        };
        // A view its context reads through gives the value it reaches;
        // when that holds no view, the loans taken to reach it end here.
        if (self.sema) |ctx| if (ctx.readsThrough(sexp)) if (ctx.typeOf(sexp)) |ty| {
            const reached = sema.unwrapViews(ctx, ty);
            if (!self.mayCarryLoan(reached)) {
                const temps_start = self.temps.items.len;
                _ = try self.walkList(sexp, kind);
                self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
                return .{};
            }
            // A view read through a view is a copy of the view: it
            // keeps what the view keeps, not the view that reached it.
            // A String's views end here but for those it keeps.
            if (sema.holdsViewOnly(ctx, reached)) {
                const temps_start = self.temps.items.len;
                return self.keepViewTemps(temps_start, try self.carry(reached, try self.walkList(sexp, kind)));
            }
            return self.carry(reached, try self.walkList(sexp, kind));
        };
        return self.walkList(sexp, kind);
    }

    fn walkList(self: *Checker, sexp: Sexp, kind: Tag) Error!Value {
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
                .move => if (self.takes(sexp)) self.walkTake(ir.Move.operand(sexp)) else self.walkMove(ir.Move.operand(sexp)),
                // A view the type checker rejected lends nothing.
                .read, .write => if (self.rejected(sexp))
                    self.walkRejectedLend(ir.get(sexp, .operand))
                else if (self.lendsElements(sexp))
                    // `?a` lent as `?a[..]`, `!a` as `!a[..]`, `?t` of a
                    // Text as `?t[..]`.
                    self.walkElems(sexp, ir.get(sexp, .operand), if (sexp.isKind(.read)) .read else .write)
                else
                    self.walkLend(ir.get(sexp, .operand), if (sexp.isKind(.read)) .read else .write),
                .clone, .weak => self.walkCloneWeak(sexp),
                .share => self.walkShare(sexp),
                .lambda => self.walkLambda(sexp, false),
                .@"if" => self.walkIf(sexp),
                .@"while" => self.walkWhile(sexp),
                .@"for" => self.walkFor(sexp),
                .labeled => self.walkLabeled(sexp),
                .match => self.walkMatch(sexp),
                .@"catch" => self.walkCatch(sexp),
                .@"??" => self.walkNullish(sexp),
                .propagate, .propagate_none => self.walkPropagate(sexp),
                .call => self.walkCall(sexp),
                .member, .index, .inst => if (self.isInstance(sexp)) .{} else self.walkMember(sexp),
                .kwarg => self.walkConsumed(ir.Kwarg.value(sexp), .argument),
                .array => blk: {
                    var v: Value = .{};
                    for (ir.Array.elems(sexp)) |e| v = try self.valueUnion(v, try self.walkConsumed(e, .element));
                    break :blk v;
                },
                .array_fill => self.walkConsumed(ir.ArrayFill.value(sexp), .element),
                .raw_block => self.walkTailPart(ir.RawBlock.body(sexp), self.takeTail(sexp)),
                .enum_lit, .use, .type, .generic_struct, .generic_inst => .{},
                // Operators on values produce fresh Copy results. A binary
                // operator reads its left operand where it runs, and uses
                // it after the right one runs.
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@">>", .@".." => blk: {
                    const operands = rig.children(sexp);
                    if (operands.len == 2) {
                        _ = try self.walkThenHeld(operands[0], .operand, operands[1]);
                    } else for (operands) |c| _ = try self.walk(c);
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

    /// The operand of a view the type checker rejected: a closure
    /// binding there was reported with it.
    fn walkRejectedLend(self: *Checker, operand: Sexp) Error!Value {
        if (operand == .src) if (self.find(self.text(operand))) |id| if (self.vars.items[id].closure) return .{};
        return self.walk(operand);
    }

    /// Walk an expression in a position that takes ownership of its value.
    fn walkConsumed(self: *Checker, expr: Sexp, sink: Sink) Error!Value {
        // A bare value lent to read where a view is expected is walked as
        // `?expr` (`Lend.implicit`).
        if (self.lendOf(expr)) |lend| if (lend.implicit) return self.walkImplicitLend(expr, lend);
        if (isLambda(expr)) {
            // A closure literal lent to a call as a callable view
            // lives for the call; anywhere else it is reported by
            // walkLambda.
            if (sink == .argument and (self.lendsBy(expr, .callable) or self.in_rejected_call or self.rejected(expr))) self.lambda_ok = true;
            return self.walk(expr);
        }
        self.copy_reads = self.value_reads;
        self.value_reads = false;
        try self.checkNoImplicitCopy(expr, sink, false);
        self.copy_reads = false;
        // Passing a held write view (`w`, `e.t`) lends it on: like `!w`,
        // its holder is lent to write for as long as the result may keep
        // the view.
        // A `![]T` passed where a `[]T` is expected is lent to read.
        if (sink == .argument and self.isWriteViewPlace(expr)) return self.walkLend(expr, if (self.lendsBy(expr, .read_only)) .read else .write);
        self.setTail(expr, sink);
        return self.walk(expr);
    }

    /// Mark `expr`, if it yields through its parts, as consumed by `sink`.
    fn setTail(self: *Checker, expr: Sexp, sink: Sink) void {
        self.markTail(expr, .{ .node = 0, .sink = sink, .vars = @intCast(self.vars.items.len) });
    }

    /// Mark `expr`, a part of the value `t` consumes, as consumed too.
    /// A loop's `else` is consumed by the loop's own value (`walkLoop`).
    fn markTail(self: *Checker, expr: Sexp, t: Tail) void {
        if (!sema.yieldsThroughParts(expr) or expr.isKind(.@"while") or expr.isKind(.@"for") or expr.isKind(.labeled)) return;
        self.tail = .{ .node = expr.list.id, .sink = t.sink, .vars = t.vars };
    }

    /// The consuming context of the branching `node`, if any.
    fn takeTail(self: *Checker, node: Sexp) ?Tail {
        const t = self.tail orelse return null;
        if (t.node != node.list.id) return null;
        self.tail = null;
        return t;
    }

    /// Walk a part of a consumed value (a branch, an arm, a handler):
    /// its tail leaves it. A block part moves its tail name before its
    /// defers run (`walkBlock`); a bare name part moves here.
    fn walkTailPart(self: *Checker, body: Sexp, t: ?Tail) Error!Value {
        const ctx = t orelse return self.walk(body);
        self.markTail(body, ctx);
        const v = try self.walk(body);
        self.tail = null;
        if (body == .src) try self.consumeTailName(body, ctx);
        return v;
    }

    /// `node`, a bare name at the tail of a value `t` consumes, leaves
    /// its binding there, as emit takes it. A name the value itself
    /// declares, which `t.sink` could not check, or one the function
    /// returns, moves out, as `<x` would. A match payload named there
    /// moves out of its scrutinee, which the check before the walk could
    /// not see (the name is bound in the arm).
    fn consumeTailName(self: *Checker, node: Sexp, t: Tail) Error!void {
        const sink = t.sink;
        const ctx = self.sema orelse return;
        const sym = ctx.symbolOf(node) orelse return;
        const id = self.find(self.text(node)) orelse return;
        const v = self.vars.items[id];
        if (v.decl != ctx.symbols.items[sym].decl_pos) return;
        if (!self.flowLive(id)) return;
        if (v.alias_of == null) {
            if ((sink == .ret or id >= t.vars) and !v.closure and !v.loop_view and !v.capture_resource and self.returnMoves(v)) {
                _ = try self.moveVar(id, node.src.pos, .move);
            }
            return;
        }
        const k = self.owningKind(v.ty) orelse return;
        if (k == .generic and v.via != .owned) {
            // A copy for plain data; each instantiation is checked.
            return self.reportAlias(node.src.pos, v.name, .name, k, .binding, v.ty);
        }
        _ = try self.movePayload(id, node.src.pos, "move");
    }

    /// A place whose value holds a write view (`w`, `e.t`, a struct
    /// with a `!T` field): passing it on lends that view.
    fn isWriteViewPlace(self: *Checker, expr: Sexp) bool {
        if (!self.carriesWriteView(self.exprType(expr))) return false;
        return switch (self.hands(expr).kind) {
            .place, .part_of_made => true,
            .made, .lend, .branches, .jump, .none => false,
        };
    }

    /// What `e` hands over to its context (`sema.handsOver`).
    fn hands(self: *const Checker, e: Sexp) sema.Hands {
        return sema.handsOverIn(self.source, self.sema, e);
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
        try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or aliased; call it as `{s}()`, lend it to a call as `?{s}`, or make the literal owned (`*|...| body`) to pass it around", .{ name, name, name });
    }

    /// `?f` of closure binding `id`: a read loan on the closure, and the
    /// loans its captures hold.
    fn lendClosure(self: *Checker, id: VarId, pos: u32) Error!Value {
        const v = (try self.lendVar(id, .read, pos)) orelse return .{};
        return .{ .loans = try self.unionLoans(v.loans, self.flows.items[id].loans) };
    }

    /// Reading `id`: it must be live and not lent to write.
    fn checkReadable(self: *Checker, id: VarId, pos: u32) Error!void {
        const v = self.vars.items[id];
        if (!try self.checkLive(id, pos)) return;
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "use of `{s}` while a write loan is live", .{v.name});
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
        if (self.defer_floor) |floor| try self.checkDeferredReach(id, floor, pos);
        if (self.flowLive(id)) return true;
        const what = if (self.flows.items[id].status == .dropped) "drop" else "move";
        try self.err(pos, "use of `{s}` after {s}", .{ self.vars.items[id].name, what });
        try self.noteInvalidated(id, pos);
        return false;
    }

    /// Deferred code reading `id` reads what it views, directly or
    /// through what that views, which must not be a var declared after
    /// the `defer` (from `floor` on): that is dropped before it runs.
    fn checkDeferredReach(self: *Checker, id: VarId, floor: u32, pos: u32) Error!void {
        var reach: std.ArrayList(VarId) = .empty;
        try reach.append(self.arena(), id);
        var k: usize = 0;
        while (k < reach.items.len) : (k += 1) {
            for (self.flows.items[reach.items[k]].loans) |l| {
                if (l.ext or std.mem.findScalar(VarId, reach.items, l.root) != null) continue;
                if (l.root >= floor) {
                    try self.err(pos, "deferred code reads `{s}` through `{s}`, but `{s}` is declared after the `defer` and dropped before it runs", .{ self.vars.items[l.root].name, self.vars.items[id].name, self.vars.items[l.root].name });
                    try self.noteLoan(l);
                    return;
                }
                try reach.append(self.arena(), l.root);
            }
        }
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
        /// Some step goes through a view (a viewed root or a
        /// view-typed field).
        through_view: bool = false,
    };

    /// The var a place (`sema.Hands.Kind.place`) starts from, and how
    /// it gets there. Null for anything else, and for a name the closure
    /// body did not capture (walking the expression reports it).
    fn resolvePlace(self: *const Checker, e: Sexp) ?Place {
        // The value a header holds is its hidden var.
        if (self.held) |h| if (e == .list and e.list.ptr == h.base.list.ptr) return .{ .root = h.id, .whole = true };
        if (self.hands(e).kind != .place and !self.heldPath(e)) return null;
        switch (e) {
            .src => {
                const id = self.find(self.text(e)) orelse return null;
                return .{ .root = id, .whole = true, .through_view = self.vars.items[id].ref != .none };
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
                        if (ty == .read_view or ty == .write_view) p.through_view = true;
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

    /// The indices of place `e`, whose address is taken (a view, a
    /// slice, a method's receiver): the place up to each index is found
    /// before the index runs, so while the indices run, `root` is held
    /// read, and an index cannot lend to write or move it
    /// (`!ps[0].a[grow(!ps)]` would write into the buffer `grow` freed).
    /// An assignment finds its target only after its indices run
    /// (`walkFieldAssign`).
    fn walkIndicesHeld(self: *Checker, e: Sexp, root: VarId) Error!void {
        const mark = self.temps.items.len;
        try self.addTemp(.{ .root = root, .kind = .read, .pos = self.startOf(e), .place_hold = true });
        try self.walkPlaceIndices(e);
        if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
    }

    /// A `member` or `index`.
    fn walkMember(self: *Checker, e: Sexp) Error!Value {
        const object = ir.get(e, .object);
        // A value that is no place is read where it runs, and indexed
        // after its index runs; a place is found after it.
        const obj = if (e.isKind(.index) and self.resolvePlace(object) == null)
            try self.walkThenHeld(object, .base, ir.Index.index(e))
        else blk: {
            const v = try self.walk(object);
            if (e.isKind(.index)) _ = try self.walk(ir.Index.index(e));
            break :blk v;
        };
        if (!self.mayCarryLoan(self.exprType(e))) return .{};
        return self.carry(self.exprType(e), obj);
    }

    /// The loans a value of type `ty` needs, of those `v` carries (Core
    /// sentence 7): a view carries the loans of only what could hold
    /// what it views. A loan on a var whose type could hold that memory
    /// only through a read view, or not at all (`sema.ViewReach`), stands
    /// for the loans the var holds, judged the same way: `it.next()` of a
    /// `!it` iterator holding Strings views what `it` views, not `it`. A
    /// loan on a var that may own that memory, or hold a write view of
    /// it, stays. A value that holds only Strings reads what it views, so
    /// what it keeps are read loans; one holding a write view, a type
    /// parameter, or a type not known keeps every loan.
    fn carry(self: *Checker, ty: ?TypeId, v: Value) Error!Value {
        return self.carryAs(ty, v, false);
    }

    /// The loans a call's result keeps of `v` (Core sentence 7), as
    /// `carry` keeps them. A result that holds no write view reads what
    /// it views, so every loan it keeps is a read loan, also one of an
    /// argument or receiver lent to write: while the result lives, that
    /// owner may be read but not written. What the call stores keeps its
    /// loans where it stores them (`absorbThroughWrites`).
    fn carryResult(self: *Checker, ty: ?TypeId, v: Value) Error!Value {
        return self.carryAs(ty, v, true);
    }

    fn carryAs(self: *Checker, ty: ?TypeId, v: Value, result: bool) Error!Value {
        const ctx = self.sema orelse return v;
        const t = ty orelse return v;
        if (v.loans.len == 0) return v;
        const info = ctx.typeInfo(t);
        if (info.poison or info.holds_type_var or info.views.write or !(info.views.marked or info.views.string)) return v;
        const reads = result or sema.holdsViewOnly(ctx, t);
        var out: std.ArrayList(Loan) = .empty;
        for (v.loans) |l| try self.carryLoan(&out, t, reads, l, 0);
        return .{ .loans = out.items };
    }

    /// The views taken since `temps_start` to compute view `v` end,
    /// but for those `v` keeps: `!it.next()` twice in one statement.
    fn keepViewTemps(self: *Checker, temps_start: usize, v: Value) Error!Value {
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        for (v.loans) |l| if (!l.ext) try self.addTemp(l);
        return v;
    }

    fn carryLoan(self: *Checker, out: *std.ArrayList(Loan), ty: TypeId, reads: bool, l: Loan, depth: u8) Error!void {
        if (l.ext or depth >= 16 or try self.mayOwnView(l.root, ty)) {
            var kept = l;
            if (reads and !l.ext and l.kind == .write) {
                kept.kind = .read;
                kept.read_of_write = true;
            }
            if (!containsLoan(out.items, kept)) try out.append(self.arena(), kept);
            return;
        }
        for (self.flows.items[l.root].loans) |h| try self.carryLoan(out, ty, reads, h, depth + 1);
    }

    /// Whether var `id`'s value may own memory a value of type `view`
    /// views, or hold a write view of it (`sema.ViewReach.owned`). A
    /// closure, and a var whose type is not known, may.
    fn mayOwnView(self: *Checker, id: VarId, view: TypeId) Error!bool {
        const ctx = self.sema orelse return true;
        const v = self.vars.items[id];
        if (v.closure) return true;
        const t = v.ty orelse return true;
        if (self.isPoisonType(t) or ctx.types.get(t) == .unknown) return true;
        const key: ReachKey = .{ .holder = t, .view = view };
        if (self.reaches.get(key)) |r| return r == .owned;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const r = try sema.viewReach(ctx, scratch.allocator(), t, view);
        try self.reaches.put(self.gpa, key, r);
        return r == .owned;
    }

    const ReachKey = struct { holder: TypeId, view: TypeId };

    // -------------------------------------------------------------------------
    // View, move, clone, drop
    // -------------------------------------------------------------------------

    /// How `e` is lent where a view of another type is expected
    /// (`SemContext.lendOf`).
    fn lendOf(self: *const Checker, e: Sexp) ?sema.Lend {
        const ctx = self.sema orelse return null;
        return ctx.lendOf(e);
    }

    /// Whether `e`, a lend written here, lends the elements of its
    /// operand (an array's or a Vec's, or a Text's bytes) rather than a
    /// view of the operand or of what it holds.
    fn lendsElements(self: *const Checker, e: Sexp) bool {
        const lend = self.lendOf(e) orelse return false;
        for (lend.steps()) |step| switch (step) {
            .lift => {},
            .elems, .text => return true,
            else => return false,
        };
        return false;
    }

    /// `e`, a bare value lent to read where a view is expected, walked as
    /// the lend `?e` would be: of its elements (`?a[..]`, `?t[..]`) when
    /// the lend's first row is theirs, of the value otherwise.
    fn walkImplicitLend(self: *Checker, e: Sexp, lend: sema.Lend) Error!Value {
        for (lend.steps()) |step| switch (step) {
            .lift => {},
            .elems, .text => return self.walkElems(e, e, .read),
            else => break,
        };
        return self.walkLend(e, .read);
    }

    /// Whether `e` is lent by `step` of the lend table.
    fn lendsBy(self: *const Checker, e: Sexp, step: sema.LendStep) bool {
        const lend = self.lendOf(e) orelse return false;
        return lend.has(step);
    }

    /// Whether `ty` is the type of something the type checker rejected.
    fn isPoisonType(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return ty == null or ty == ctx.types.invalid_id;
    }

    /// Whether the type checker rejected `e` (its type is invalid).
    fn rejected(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        return ctx.typeOf(e) == ctx.types.invalid_id;
    }

    fn walkLend(self: *Checker, inner: Sexp, kind: LoanKind) Error!Value {
        if (rig.isRangeIndex(inner)) return self.walkElems(inner, ir.Index.object(inner), kind);
        if (kind == .read and self.throughReadView(inner)) return self.walkThroughView(inner);
        const place = self.resolvePlace(inner) orelse return self.walkViewedPath(inner);
        try self.walkIndicesHeld(inner, place.root);
        const id = place.root;
        const v = self.vars.items[id];
        const pos = self.startOf(inner);
        if (v.closure) {
            if (kind == .read and place.whole) return self.lendClosure(id, pos);
            try self.err(pos, "closure `{s}` cannot be lent to write; lend it as `?{s}`", .{ v.name, v.name });
            return .{};
        }
        return (try self.lendVar(id, kind, pos)) orelse .{};
    }

    /// A view of a path that starts from no var (`?f(?h).r`): it keeps
    /// what the path's start views, whatever the type of each step.
    fn walkViewedPath(self: *Checker, e: Sexp) Error!Value {
        if (!e.isKind(.member) and !e.isKind(.index)) return self.walk(e);
        const obj = try self.walkViewedPath(ir.get(e, .object));
        if (e.isKind(.index)) _ = try self.walk(ir.Index.index(e));
        return obj;
    }

    /// Lend a place in var `id` at `pos`: null when `id` is moved or
    /// the lend conflicts, both reported.
    fn lendVar(self: *Checker, id: VarId, kind: LoanKind, pos: u32) Error!?Value {
        if (!try self.checkLive(id, pos)) return null;
        if (try self.conflicts(id, if (kind == .write) .write else .read, pos)) return null;
        const loan: Loan = .{ .root = id, .kind = kind, .pos = pos };
        try self.addTemp(loan);
        return try self.lendOn(id, loan);
    }

    /// A view of the elements of `object`: `slice` is a slice of it
    /// (`?xs[a..b]`, `!xs[a..b]`), or a view of the whole array lent as
    /// one (`?a`). A slice of a String or a `[]T` views what that value
    /// views. A slice of a Vec views the Vec, whose buffer it points
    /// into, and one of a `![]T` views the `![]T`, as a view of a
    /// view does. A slice of an array held in the storage of the var it
    /// is reached from, which may be a copy (a by-value parameter, a loop
    /// or pattern binding), also holds a frame loan on that var, so it
    /// cannot outlive it.
    fn walkElems(self: *Checker, slice: Sexp, object: Sexp, kind: LoanKind) Error!Value {
        // The place's own indexes, and a slice's bounds.
        const indices = if (rig.isRangeIndex(slice)) slice else object;
        // A slice the type checker rejected views nothing.
        if (self.rejected(slice)) {
            _ = try self.walk(object);
            try self.walkPlaceIndices(indices);
            return .{};
        }
        // What it lends, as the type checker recorded it: the elements
        // or bytes the value holds, through handles and boxes, or a
        // `![]T` lent on. A view's elements are what the view views.
        const lend = (if (self.sema) |ctx| ctx.sliceLendOf(slice) orelse ctx.lendOf(slice) else null) orelse return self.walkOperand(slice, object);
        if (!lend.has(.elems) and !lend.has(.text) and !lend.has(.read_only)) return self.walkOperand(slice, object);
        const ty = self.exprType(object) orelse return self.walkOperand(slice, object);
        const peeled = self.pointee(ty) orelse ty;
        // An array reached through a read view (an element of a `[]T`)
        // is viewed as that view views it.
        if (self.throughReadView(object)) {
            const v = try self.walkThroughView(object);
            if (rig.isRangeIndex(slice)) _ = try self.walk(ir.Index.index(slice));
            return v;
        }
        // A path from no var (a temporary's part, `?mk().v[..]`) keeps
        // what its start views, as a view of one does.
        const place = self.resolvePlace(object) orelse {
            const v = try self.walkViewedPath(object);
            if (rig.isRangeIndex(slice)) _ = try self.walk(ir.Index.index(slice));
            return v;
        };
        try self.walkIndicesHeld(indices, place.root);
        const id = place.root;
        const pos = self.startOf(slice);
        const v = (try self.lendVar(id, kind, pos)) orelse return .{};
        if (self.typeData(peeled) != .array or !self.inVarStorage(object)) return v;
        return .{ .loans = try self.unionLoans(v.loans, try self.oneLoan(.{ .root = id, .kind = kind, .pos = pos, .frame = true })) };
    }

    /// A slice walked as a plain value, or a whole-array view's operand.
    fn walkOperand(self: *Checker, slice: Sexp, object: Sexp) Error!Value {
        return self.walk(if (rig.isRangeIndex(slice)) slice else object);
    }

    /// Whether place `e` reaches its value through a read view: a step
    /// past a `?T`, a read-only `[]T`, or a String (`c.items[0]` with
    /// `items: ?Vec[Item]`). Its memory is the view's, which the place's
    /// var does not own.
    fn throughReadView(self: *const Checker, e: Sexp) bool {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) {
            const obj = ir.get(p, .object);
            if (self.exprType(obj)) |t| switch (self.typeData(t)) {
                .read_view, .slice, .string => return true,
                else => {},
            };
            p = obj;
        }
        return false;
    }

    /// A lend of place `e` through a read view (`throughReadView`),
    /// which is the lend through a copy of that view (`?c.items[0]` is
    /// `t = c.items` then `?t[0]`): it keeps what the view keeps, which
    /// the place's var holds, and no loan on the var (Core sentence 7).
    /// The var is held while the place's indexes run, as for any lend.
    fn walkThroughView(self: *Checker, e: Sexp) Error!Value {
        const place = self.resolvePlace(e) orelse return self.walkViewedPath(e);
        try self.walkIndicesHeld(e, place.root);
        try self.checkReadable(place.root, self.startOf(e));
        return self.varValue(place.root);
    }

    /// Whether the value of place `e` is stored in the var the place
    /// starts from, rather than behind a pointer, a handle, or a Vec's
    /// buffer, whose own loans cover it. A read view copies only
    /// scalars and views, which hold no array, so an array reached
    /// through one is behind a pointer.
    fn inVarStorage(self: *const Checker, e: Sexp) bool {
        if (self.exprType(e)) |ty| switch (self.typeData(ty)) {
            .write_view, .read_view, .shared, .slice => return false,
            else => if (self.isVec(ty)) return false,
        };
        if (e.isKind(.member) or e.isKind(.index)) return self.inVarStorage(ir.get(e, .object));
        return true;
    }

    /// The loans of a view of (a path inside) var `id`. Lending
    /// through a read view copies that view; lending an owned value
    /// or through a write view lends the var itself.
    fn lendOn(self: *Checker, id: VarId, loan: Loan) Error!Value {
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
        const place = self.resolvePlace(inner) orelse {
            if (try self.movedTail(inner, inner, false)) |_| return .{};
            return self.walk(inner);
        };
        if (place.whole) return self.moveVar(place.root, self.startOf(inner), .move);
        return self.movePath(inner, place);
    }

    fn takes(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        return ctx.takes(e);
    }

    /// `<p.f` of an optional field or element: the value is taken out
    /// and `none` left behind, so the place stays whole. The place is
    /// written: no other view of it may be live. What the value
    /// views, the place viewed.
    fn walkTake(self: *Checker, inner: Sexp) Error!Value {
        const place = self.resolvePlace(inner) orelse return self.walkViewedPath(inner);
        try self.walkPlaceIndices(inner);
        const id = place.root;
        const pos = self.startOf(inner);
        if (!try self.checkLive(id, pos)) return .{};
        if (try self.conflicts(id, .write, pos)) return .{};
        if (!self.mayCarryLoan(self.exprType(inner))) return .{};
        return self.varValue(id);
    }

    /// `<e` where `e` yields a binding or field it does not own: a
    /// branch, `?`, `!`, `??`, or `catch` whose value is a place holding
    /// an owning value. Moving it would leave the owner still dropping
    /// it, so the move is written where the place is. Reported; the
    /// offending place, or null.
    fn movedTail(self: *Checker, e: Sexp, top: Sexp, nested: bool) Error!?Sexp {
        switch (self.hands(e).kind) {
            .place, .part_of_made => return if (nested and self.ownsPlace(e)) try self.reportMovedTail(e, top) else null,
            .made, .lend, .branches, .jump, .none => {},
        }
        // A value one of whose parts it is (`sema.valueParts`).
        var parts = sema.valueParts(e);
        while (parts.next()) |p| if (try self.movedTail(p.node, top, true)) |place| return place;
        return null;
    }

    /// A binding or field whose value owns a resource.
    fn ownsPlace(self: *Checker, e: Sexp) bool {
        if (self.resolvePlace(e) == null) return false;
        return self.owningKind(self.exprType(e)) != null;
    }

    fn reportMovedTail(self: *Checker, place: Sexp, top: Sexp) Error!Sexp {
        const shown = try self.placeText(place);
        const at_exit = top.isKind(.propagate) or top.isKind(.propagate_none);
        const optional = if (self.exprType(place)) |t| self.typeData(t) == .optional else false;
        if (place != .src and !optional) {
            try self.errAt(place, "`<` here would copy `{s}` out without moving it, and a field that is not optional cannot be moved out; exchange it: `replace(!{s}, v)`", .{ shown, shown });
        } else if (at_exit) {
            try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it before the `?` or `!`: `(<{s}){s}`", .{ shown, if (place == .src) "move" else "take", shown, if (top.isKind(.propagate)) "!" else "?" });
        } else {
            try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it inside the branch: `<{s}`", .{ shown, if (place == .src) "move" else "take", shown });
        }
        return place;
    }

    fn moveVar(self: *Checker, id: VarId, pos: u32, verb: MoveVerb) Error!Value {
        const v = self.vars.items[id];
        const vt = verb.text();
        if (v.closure) {
            try self.errClosureValue(pos, v.name);
            return .{};
        }
        if (try self.rejectConsumedView(id, pos, vt)) return .{};
        if (verb == .capture and v.kind == .param and v.ref != .none) {
            const handle = if (self.pointee(v.ty)) |t| self.typeData(t) == .shared or self.typeData(t) == .weak else false;
            if (handle) {
                try self.err(pos, "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture a clone with `|+{s}|`", .{ v.name, v.name });
            } else try self.err(pos, "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture the view with `|{s}{s}|`", .{ v.name, if (v.ref == .write) "!" else "?", v.name });
            return .{};
        }
        if (!(if (verb == .capture) try self.checkCapturable(id, pos) else try self.checkLive(id, pos))) return .{};
        const value = self.varValue(id);
        if (try self.rejectGlobal(id, pos, vt)) return .{};

        // A payload that views its scrutinee cannot leave it; a copied
        // payload is not a view (`bindPayload`).
        if (v.alias_of != null) return self.movePayload(id, pos, vt);

        if (try self.conflicts(id, .{ .consume = vt }, pos)) return .{};
        // `<x` ends `x`, whatever its type: a Copy value or a view is
        // copied out, and the name is done.
        try self.markInvalid(id, .moved, pos);
        try self.holdMoved(value);
        return value;
    }

    /// The loans a moved value carries stay in force until the end of the
    /// statement or call that consumes it, so a later argument of the
    /// same call cannot lend or move their roots.
    fn holdMoved(self: *Checker, value: Value) Error!void {
        for (value.loans) |l| if (!l.ext) try self.addTemp(l);
    }

    /// Move (or drop, `op`) a match payload binding out of its
    /// scrutinee: a view of a value the match does not consume, so it is
    /// rejected, with the way to take it.
    fn movePayload(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!Value {
        const v = self.vars.items[id];
        const root = v.alias_of.?;
        const r = self.vars.items[root];
        switch (v.via) {
            .viewed => {
                try self.err(pos, "cannot move out of `{s}`: it is a view of `{s}`", .{ v.name, r.name });
                return .{};
            },
            .shared => {
                try self.err(pos, "cannot move out of `{s}`: `{s}` is a shared handle and other handles may still use it", .{ v.name, r.name });
                return .{};
            },
            .owned => {},
        }
        if (try self.rejectConsumedView(root, pos, op)) return .{};
        if (v.alias_path.len > 0) {
            try self.err(pos, "cannot {s} `{s}` out of `{s}`: `{s}` still owns it (partial moves are not supported)", .{ op, v.name, v.alias_path, r.name });
            return .{};
        }
        // A bare match reads what it matches; `match <x` hands its
        // fields to the arm.
        try self.err(pos, "cannot {s} `{s}` out of `{s}`: `match {s}` reads `{s}`; write `match <{s}` to take its fields", .{ op, v.name, r.name, r.name, r.name, r.name });
        return .{};
    }

    /// `<p.a` / `<v[i]`: only Copy values can leave a field or element.
    fn movePath(self: *Checker, inner: Sexp, place: Place) Error!Value {
        const value = try self.walk(inner);
        const ty = self.exprType(inner);
        if (ty != null and self.copies(ty)) return value;
        if (ty != null and self.refOfType(ty) == .read) return value;
        const path = try self.placeText(inner);
        const root = self.vars.items[place.root].name;
        const pos = self.startOf(inner);
        if (place.through_view) {
            try self.err(pos, "cannot move out of `{s}`: `{s}` is a view; exchange it instead: `replace(!{s}, v)`", .{ path, root, path });
        } else if (place.through_shared) {
            try self.err(pos, "cannot move out of `{s}`: it is reached through a shared handle and other handles may still use it; clone it with `+{s}`", .{ path, path });
        } else if (place.indexed) {
            try self.err(pos, "cannot move out of `{s}`: elements cannot be moved out of their container", .{path});
        } else {
            try self.err(pos, "cannot move out of `{s}`: `{s}` would still drop it (partial moves are not supported); move `{s}` whole, or exchange the field: `replace(!{s}, v)`", .{ path, root, root, path });
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
    fn rejectConsumedView(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
        const v = self.vars.items[id];
        // An element of generic type is taken as a copy: each instance
        // must be plain data.
        if (v.elem_view and v.ref == .none) if (self.owningKind(v.ty)) |k| if (k == .generic) {
            try self.requirePlain(pos, v.ty.?, true);
        };
        if (v.loop_view) {
            try self.err(pos, "cannot {s} loop view `{s}`; " ++ loop_view_rule, .{ op, v.name });
            return true;
        }
        if (v.capture_resource) {
            if (v.ref != .none) {
                try self.err(pos, "cannot {s} captured view `{s}`; the closure holds it for every call. Use it through the view, or pass it to a call", .{ op, v.name });
                return true;
            }
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
    /// A new handle is independent of the view it was reached through
    /// (a loop element, a `?*T` parameter), but reaches whatever the
    /// shared value holds; a write view held there cannot be duplicated,
    /// whoever lent it.
    fn newHandle(self: *Checker, pos: u32, what: []const u8, ty: ?TypeId, id: ?VarId, v: Value, weak: bool) Error!Value {
        if (!self.mayCarryLoan(ty)) return .{};
        const out = self.heldThroughHandle(ty, id) orelse v;
        if (self.carriesWriteView(ty)) {
            try self.err(pos, "cannot {s} `{s}`: it holds a write view, which cannot be duplicated", .{ if (weak) "take a weak handle to" else "clone", what });
            for (out.loans) |l| if (l.kind == .write) {
                try self.noteLoan(l);
                break;
            };
            return .{};
        }
        return out;
    }

    /// What a shared value of handle type `ty` holds: nothing when its
    /// type holds no view, the loans of the collection a loop element
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
        if (!self.mayCarryLoan(boxed)) return .{};
        if (id) |i| if (self.vars.items[i].elem_of) |c| return .{ .loans = self.flows.items[c].loans };
        return null;
    }

    fn walkDrop(self: *Checker, node: Sexp) Error!void {
        const target = ir.Drop.name(node);
        const pos = target.src.pos;
        const name = self.text(target);
        const id = self.find(name) orelse return;
        const v = self.vars.items[id];
        if (try self.rejectConsumedView(id, pos, "drop")) return;
        if (v.kind == .param and v.ref != .none) {
            try self.err(pos, "cannot drop view parameter `{s}`; the caller owns what it views", .{name});
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
            try self.err(pos, "cannot drop `{s}` while it is lent", .{name});
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
        // Reported by the type checker.
        if (self.rejected(expr)) return;
        // The value a view reaches is copied where its context reads
        // it, in the branches of what is read too.
        const saved_reads = self.copy_reads;
        defer self.copy_reads = saved_reads;
        if (self.readsValue(expr)) self.copy_reads = true;
        switch (expr) {
            .src => {
                const v = self.vars.items[self.boundVar(expr) orelse return];
                const pos = expr.src.pos;
                const name = v.name;
                if (v.closure) return; // reported by walkName
                if (v.loop_view) {
                    try self.err(pos, "bare use of loop view `{s}` in {s} would carry the viewed handle past the loop; " ++ loop_view_rule, .{ name, sink.text() });
                    return;
                }
                // A captured read view or Copy value is copied out, and
                // a captured view passed to a call is lent for the call.
                const copied = v.ref == .read or self.copies(v.ty) or (sink == .argument and v.ref != .none);
                if (v.capture_resource and !copied and v.ref == .write) {
                    try self.err(pos, "bare use of captured write view `{s}` in {s} would hand the write view, which is unique, out of the closure environment, again at each call; use it inside the closure instead", .{ name, sink.text() });
                    return;
                }
                if (v.capture_resource and !copied) {
                    try self.err(pos, "bare use of captured resource `{s}` in {s} would smuggle the handle out of the closure environment; use `+{s}` to clone a fresh handle, or `~{s}` for a weak reference", .{ name, sink.text(), name, name });
                    return;
                }
                if (top_return) return;
                if (self.owningKind(v.ty)) |k| return self.reportAlias(pos, name, .name, k, sink, v.ty);
                if (sink == .argument) return;
                // A write view of a Copy value is copied where the
                // value is read; where a `!T` goes, the view would be.
                if (v.ref == .write and !self.readsThroughWriteView(v.ty)) {
                    try self.err(pos, "bare use of write view `{s}` in {s} would copy a write view, which is unique; use `<{s}` to move it", .{ name, sink.text(), name });
                } else if (v.ref != .write and self.carriesWriteView(v.ty)) {
                    try self.err(pos, "bare use of `{s}` in {s} would copy the write view it holds; use `<{s}` to move it", .{ name, sink.text(), name });
                }
            },
            .list => switch (self.hands(expr).kind) {
                .place, .part_of_made => {
                    // `Enum.variant` is a new value, not a field.
                    if (self.namesType(ir.get(expr, .object))) return;
                    const ty = self.exprType(expr);
                    if (self.owningKind(ty)) |k| {
                        return self.reportAlias(self.startOf(expr), try self.placeText(expr), if (expr.isKind(.index)) .element else .field, k, sink, ty);
                    }
                    // A field or element that is a write view of a Copy
                    // value reads the value where its context reads it,
                    // as a bare write-view name does.
                    if (sink != .argument and self.carriesWriteView(ty) and !self.readsThroughWriteView(ty)) {
                        const stays = if (expr.isKind(.index)) "an element cannot be moved out of its container" else "a field cannot be moved out of its parent";
                        try self.errAt(expr, "bare use of `{s}` in {s} would copy a write view; {s}", .{ try self.placeText(expr), sink.text(), stays });
                    }
                },
                // A value that is one of its parts (`sema.valueParts`):
                // a tail it returns moves out, like a bare return; an
                // operand it passes through does not. `m?` copies out
                // the value inside `m`, which only matters when that
                // value owns or holds a write view.
                .made, .branches => {
                    const ty = self.exprType(expr);
                    var parts = sema.valueParts(expr);
                    while (parts.next()) |p| switch (p.via) {
                        .tail => try self.checkNoImplicitCopy(p.node, sink, top_return),
                        .operand => try self.checkNoImplicitCopy(p.node, sink, false),
                        .unwrapped => if (self.owningKind(ty) != null or self.carriesWriteView(ty)) try self.checkNoImplicitCopy(p.node, sink, false),
                    };
                },
                .lend, .jump, .none => {},
            },
            else => {},
        }
    }

    /// Whether a bare name, field, or element of type `ty` hands over the
    /// value a write view reaches rather than the view: `ty` is a write
    /// view of a value that reads as a value (`sema.readsAsValue`), and
    /// the context reads it (`copy_reads`, `SemContext.readsThrough`).
    /// `x = h.w`, with `w: !Int`, copies the Int.
    fn readsThroughWriteView(self: *const Checker, ty: ?TypeId) bool {
        return self.copy_reads and self.refOfType(ty) == .write and self.readsAsValue(self.pointee(ty));
    }

    /// The var the name `expr` refers to, once the walk has bound it:
    /// null for a name the value being checked declares itself (a
    /// block's local at its tail), even where an outer binding has the
    /// same name.
    fn boundVar(self: *const Checker, expr: Sexp) ?VarId {
        const id = self.find(self.text(expr)) orelse return null;
        const ctx = self.sema orelse return id;
        const sym = ctx.symbolOf(expr) orelse return id;
        if (self.vars.items[id].sym == sym) return id;
        var i = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (self.vars.items[i].sym == sym) return @intCast(i);
        }
        return null;
    }

    /// Whether the context of `e` reads the value the view it yields
    /// reaches (`SemContext.readsThrough`).
    fn readsValue(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        return ctx.readsThrough(e);
    }

    /// Whether `e` names a type (`Shape`, `lib.Shape`, `Opt[Int]`) rather
    /// than a value.
    fn namesType(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        if (ctx.instanceOf(e)) |inst| return inst == .type;
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

    /// Every type parameter `ty` holds must be plain data in each
    /// instance, because the value is copied (or taken as an `element`).
    fn requirePlain(self: *Checker, pos: u32, ty: TypeId, element: bool) Error!void {
        return self.addRequirement(pos, ty, .{ .param = 0, .pos = pos, .element = element });
    }

    /// Every type parameter `ty` holds must hold no String in each
    /// instance, because the value is stored where no loan is tracked:
    /// in a Cell, a Signal, or an owned closure.
    fn requireNoView(self: *Checker, pos: u32, ty: ?TypeId) Error!void {
        return self.addRequirement(pos, ty orelse return, .{ .param = 0, .pos = pos, .view = true });
    }

    fn addRequirement(self: *Checker, pos: u32, ty: TypeId, req: PlainRequirement) Error!void {
        const ctx = self.sema orelse return;
        var held: std.ArrayList(SymbolId) = .empty;
        try sema.heldTypeVars(ctx, ty, &held, self.arena());
        for (held.items) |param| {
            for (self.plain_reqs.items) |r| {
                if (r.param == param and r.pos == pos and r.view == req.view) break;
            } else {
                var r = req;
                r.param = param;
                try self.plain_reqs.append(self.gpa, r);
            }
        }
    }

    /// What a bare use that would copy a moving value names: a binding,
    /// or a field or element, which stays where it is.
    const Aliased = enum { name, field, element };

    /// Whether `ty`, or the value an optional of it holds, is an array.
    fn isArrayOf(self: *const Checker, ty: TypeId) bool {
        var t = ty;
        while (self.typeData(t) == .optional) t = self.typeData(t).optional;
        return self.typeData(t) == .array;
    }

    fn reportAlias(self: *Checker, pos: u32, what: []const u8, aliased: Aliased, k: Owning, sink: Sink, ty: ?TypeId) Error!void {
        const where = sink.text();
        const is_name = aliased == .name;
        // Why a part cannot be moved out instead.
        const stays = if (aliased == .element) "an element cannot be moved out of its container" else "a field cannot be moved out of its parent";
        // An array whose elements own is named by its type.
        if (ty) |t| if (self.sema) |ctx| if (k == .drop_glue and self.isArrayOf(t)) {
            const shown = try sema.formatTypeIn(ctx, self.arena(), t);
            if (is_name) {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would copy its owning elements, which both would drop. Use `<{s}` to move it", .{ shown, what, where, what });
            } else try self.err(pos, "bare use of `{s}` value `{s}` in {s} would copy its owning elements; {s}", .{ shown, what, where, stays });
            return;
        };
        switch (k) {
            // Fine for plain data: each instantiation is checked.
            .generic => if (ty) |t| try self.requirePlain(pos, t, false),
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
                try self.err(pos, "bare use of `Vec` value `{s}` in {s} would copy the buffer pointer; {s}", .{ what, where, stays });
            },
            .box => if (is_name) {
                try self.err(pos, "bare use of `Box` value `{s}` in {s} would copy the box's pointer and free its value twice; use `<{s}` to move ownership", .{ what, where, what });
            } else {
                try self.err(pos, "bare use of `Box` value `{s}` in {s} would copy the box's pointer; {s}. Lend it instead: `?{s}` or `!{s}`", .{ what, where, stays, what, what });
            },
            .text => if (is_name) {
                try self.err(pos, "bare use of `Text` value `{s}` in {s} would copy the buffer pointer and free it twice; use `<{s}` to move ownership, or `+{s}` to copy the text", .{ what, where, what, what });
            } else {
                try self.err(pos, "bare use of `Text` value `{s}` in {s} would copy the buffer pointer; {s}. Lend it (`?{s}`) or copy the text (`+{s}`)", .{ what, where, stays, what, what });
            },
            .unique => |tname| if (is_name) {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would copy a unique value; use `<{s}` to move it", .{ tname, what, where, what });
            } else {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would copy a unique value; a field or element cannot be moved out of what holds it", .{ tname, what, where });
            },
            .drop_glue => |tname| if (is_name) {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue (resource fields or a user `drop` declaration), so two bindings would each run the destructor. Use `<{s}` to move ownership", .{ tname, what, where, tname, what });
            } else {
                try self.err(pos, "bare use of `{s}` value `{s}` in {s} would alias an owning value; `{s}` carries drop glue and {s}", .{ tname, what, where, tname, stays });
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
        if (target != .src) return self.walkFieldAssign(target, expr);

        const pos = target.src.pos;
        const name = self.text(target);
        const is_lambda = isLambda(expr);
        // A write-view local re-pointed by a view its right side does not
        // read, and cannot leave early, never uses its old view again:
        // that view's loans end here (Core sentence 6), before the right
        // side lends anew.
        if (kind == .default and (if (self.sema) |ctx| ctx.repoints(node) else false)) if (self.find(name)) |id| {
            if (!self.readsName(expr, name) and !leavesEarly(expr)) try self.setFlow(id, .{ .status = self.flows.items[id].status, .at = self.flows.items[id].at });
        };
        const value: Value = switch (kind) {
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
            .default => {
                if (self.find(name)) |id| {
                    const repoints = if (self.sema) |ctx| ctx.repoints(node) else false;
                    try self.reassign(id, pos, value, repoints);
                    return;
                } else {
                    try self.bindNew(target, false, is_lambda, value);
                }
            },
            // Compound assignment (`+=`, ...).
            else => {
                const id = self.find(name) orelse return;
                try self.checkReadable(id, pos);
                try self.checkAssignable(id, pos);
                return;
            },
        }
        if (is_lambda) self.vars.items[self.vars.items.len - 1].env_drop_reads = self.envDropReads(expr);
    }

    /// Whether `e` names `name` anywhere.
    fn readsName(self: *const Checker, e: Sexp, name: []const u8) bool {
        switch (e) {
            .src => return std.mem.eql(u8, self.text(e), name),
            .list => {
                for (e.items()) |item| if (self.readsName(item, name)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// Whether evaluating `e` may leave before it gives its value: a
    /// propagation, a `return`, a `break`, or a `continue` inside it.
    fn leavesEarly(e: Sexp) bool {
        if (e != .list) return false;
        if (e.kind()) |k| switch (k) {
            .propagate, .propagate_none, .@"return", .@"break", .@"continue" => return true,
            else => {},
        };
        for (e.items()) |item| if (leavesEarly(item)) return true;
        return false;
    }

    /// Whether dropping the environment of closure literal `lambda` may
    /// run a `drop` body (`sema.dropRunsBody`).
    fn envDropReads(self: *const Checker, lambda: Sexp) bool {
        const ctx = self.sema orelse return true;
        for (sema.captureList(ir.Lambda.captures(lambda))) |cap| {
            const ty = self.symType(sema.captureNameNode(cap).?.src.pos) orelse return true;
            if (sema.dropRunsBody(ctx, ty) != .no) return true;
        }
        return false;
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
        }, .{ .loans = if (closure) value.loans else if (self.mayCarryLoan(ty)) (try self.carry(ty, value)).loans else &.{} });
    }

    /// Checks shared by reassignment and compound assignment.
    fn checkAssignable(self: *Checker, id: VarId, pos: u32) Error!void {
        const v = self.vars.items[id];
        if (v.closure) {
            try self.err(pos, "cannot reassign closure binding `{s}`; closure bindings are fixed", .{v.name});
            try self.note(v.decl, "`{s}` was bound here as a closure", .{v.name});
            return;
        }
        if (v.fixed and self.isGlobal(id)) {
            try self.err(pos, "cannot reassign constant `{s}`", .{v.name});
            try self.note(v.decl, "`{s}` is declared here", .{v.name});
            return;
        }
        if (v.fixed) {
            try self.err(pos, "cannot reassign fixed binding `{s}`", .{v.name});
            try self.note(v.decl, "`{s}` was bound here with `const`", .{v.name});
            return;
        }
        // Assigning a captured write view writes through it.
        // (A capture the type checker rejected is reported there.)
        const writes_capture = v.kind == .capture and (v.ref == .write or self.isPoisonType(v.ty));
        if (!writes_capture and try self.rejectConsumedView(id, pos, "reassign")) return;
        if (!self.copies(v.ty) and try self.rejectGlobal(id, pos, "reassign")) return;
        if (v.alias_of != null and v.ref != .write and !self.isPoisonType(v.ty)) {
            try self.err(pos, "cannot reassign match binding `{s}`; it views the matched value", .{v.name});
            return;
        }
        if (self.findLoan(id, .any, null)) |l| {
            try self.err(pos, "cannot reassign `{s}` while it is lent", .{v.name});
            try self.noteLoan(l);
        }
    }

    /// `x = value`. A `!T` local given a view (`repoints`) points at
    /// another place, as any binding takes a new value: the loans it held
    /// end, and it holds the view's.
    fn reassign(self: *Checker, id: VarId, pos: u32, value: Value, repoints: bool) Error!void {
        const before = self.diagnostics.items.len;
        try self.checkAssignable(id, pos);
        if (self.diagnostics.items.len != before and self.quiet == 0) return;
        const v = self.vars.items[id];
        if (v.kind == .capture and v.ref == .write) {
            // Assigning a captured write view writes into the value it
            // views.
            return self.storeThroughCapture(v, pos, value);
        }
        if (v.closure or v.fixed or v.loop_view or v.capture_resource) return;
        if (self.isGlobal(id) and !self.copies(v.ty)) return;
        if (self.findLoan(id, .any, null) != null) return;
        if (v.ref == .write and !repoints) {
            // Assigning a write view writes into the value it views:
            // it still views it. Through a `!T` parameter (or a loop or
            // pattern binding) the new value may only carry views the
            // caller handed in; through a local, it lands in what the
            // local views, which then holds them.
            if (!try self.checkLive(id, pos)) return;
            if (self.writesThroughLocal(id)) return self.storeThroughLocal(id, pos, value, 1);
            for (value.loans) |l| if (self.isLocalLoan(l)) {
                const stored = self.vars.items[l.root].name;
                if (v.kind != .param) if (self.viewedRoot(id)) |root| {
                    try self.err(pos, "cannot store a view of `{s}` through `{s}`: `{s}` views `{s}`, which outlives it", .{ stored, v.name, v.name, self.vars.items[root].name });
                    return;
                };
                try self.err(pos, "cannot store a view of `{s}` through `{s}`: what `{s}` views outlives it", .{ stored, v.name, v.name });
                return;
            };
            return self.storeInLent(id, pos, value, 1);
        }
        // The old value is dropped (if still owned) and the binding is
        // live again with the new value.
        try self.setFlow(id, .{ .loans = if (self.mayCarryLoan(v.ty)) (try self.carry(v.ty, value)).loans else &.{} });
    }

    /// The var a view held by var `id` views, when it holds one of
    /// a var of this function.
    fn viewedRoot(self: *const Checker, id: VarId) ?VarId {
        if (self.vars.items[id].ref == .none) return null;
        for (self.flows.items[id].loans) |l| if (!l.ext and l.root != id) return l.root;
        return null;
    }

    /// Var `id` is a local write view of a var of this function (a
    /// `match !x` binding views `x` as one does): a store through it
    /// lands in what it views.
    fn writesThroughLocal(self: *const Checker, id: VarId) bool {
        const v = self.vars.items[id];
        if (v.ref != .write or !(v.kind == .local or (v.kind == .pattern and v.alias_of != null))) return false;
        return self.viewedRoot(id) != null;
    }

    /// `w = e` through local write view `id`: `e` is stored in what
    /// `w` views. A view parameter or module-level binding reached
    /// that way outlives this function's values.
    fn storeThroughLocal(self: *Checker, id: VarId, pos: u32, value: Value, depth: u32) Error!void {
        const held = self.varValue(id);
        for (held.loans) |w| {
            if (w.kind != .write) continue;
            const r = self.vars.items[w.root];
            if (!w.ext and !(r.kind == .param and r.ref != .none) and !self.isGlobal(w.root)) continue;
            for (value.loans) |l| if (self.isLocalLoan(l)) {
                try self.err(pos, "cannot store a view of `{s}` through `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, self.vars.items[id].name, r.name });
                return;
            };
        }
        try self.absorbThroughWrites(held, value, pos, self.vars.items[id].name, depth);
    }

    /// `p.f = e` / `v[i] = e`.
    fn walkFieldAssign(self: *Checker, target: Sexp, expr: Sexp) Error!void {
        const value = try self.walkConsumed(expr, .field);
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
            try self.err(pos, "cannot assign to `{s}` while `{s}` is lent", .{ try self.placeText(target), v.name });
            try self.noteLoan(l);
            return;
        }
        // An element of a Cell's Vec, or a field of one, is stored in
        // the Cell, which every handle to it reaches: it may hold no loan.
        if (self.inCellVec(target)) {
            try self.requireNoView(pos, self.exprType(target));
            const loans = (try self.carry(self.exprType(target), value)).loans;
            if (loans.len > 0) try self.err(pos, "cannot store a view of `{s}` in a `Cell`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one", .{self.vars.items[loans[0].root].name});
            return;
        }
        if (value.loans.len == 0 or !self.mayCarryLoan(self.exprType(target))) return;
        // A value stored through a `!T` field or element lands in what
        // the field views, which `v` holds a write loan on.
        const through = if (self.sema) |ctx| ctx.writesThrough(target) else false;
        if (through) return self.absorbThroughWrites(self.varValue(id), value, pos, v.name, self.placeDepth(target, true));
        if (v.kind == .capture and !place.through_shared) return self.storeThroughCapture(v, pos, value);
        if (!place.through_shared and self.writesThroughLocal(id)) return self.storeThroughLocal(id, pos, value, self.placeDepth(target, false));
        if (v.ref != .none or place.through_view or place.through_shared or self.isGlobal(id)) {
            // Stored into something the caller owns: only views the
            // caller handed in may go there.
            for (value.loans) |l| if (self.isLocalLoan(l) or self.isGlobal(id)) {
                const stored = self.vars.items[l.root].name;
                const into = try self.placeText(target);
                // A local view: what outlives it is what `v` views.
                if (v.kind != .param) if (self.viewedRoot(id)) |root| {
                    try self.err(pos, "cannot store a view of `{s}` in `{s}`: `{s}` views `{s}`, which outlives it", .{ stored, into, v.name, self.vars.items[root].name });
                    return;
                };
                try self.err(pos, "cannot store a view of `{s}` in `{s}`: `{s}` outlives it", .{ stored, into, v.name });
                return self.noteStringOfText(l, self.exprType(target));
            };
            return self.storeInLent(id, pos, value, self.placeDepth(target, false));
        }
        var f = self.flows.items[id];
        f.loans = try self.unionLoans(f.loans, value.loans);
        try self.setFlow(id, f);
    }

    /// `value`, which carries only loans the caller handed in, was stored
    /// into what var `id` reaches through a view: a parameter's value,
    /// or the value a loop or pattern binding writes through. Whatever
    /// holds the stored value now holds its loans: a parameter, as any
    /// var does (`absorbLoans`), and a binding's write loans lead to it
    /// within `depth` steps (`absorbThroughWrites`).
    fn storeInLent(self: *Checker, id: VarId, pos: u32, value: Value, depth: u32) Error!void {
        const v = self.vars.items[id];
        if (v.kind == .param) return self.absorbLoans(id, value, pos, &.{}, v.name, false);
        return self.absorbThroughWrites(self.varValue(id), value, pos, v.name, depth);
    }

    /// Whether place `target` is, or is a field of, an element of the Vec
    /// a Cell holds (`c[i] = v`, `c[i].f = v`).
    fn inCellVec(self: *const Checker, target: Sexp) bool {
        const ctx = self.sema orelse return false;
        var e = target;
        while (e.isKind(.member) or e.isKind(.index)) : (e = ir.get(e, .object)) {
            if (!e.isKind(.index)) continue;
            const ty = self.exprType(ir.Index.object(e)) orelse continue;
            switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
                .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id) return true,
                else => {},
            }
        }
        return false;
    }

    /// Store `value` into `target`, reached through capture `v` of the
    /// closure being checked. The captured value outlives every call of
    /// the closure, while its parameters and its own values (its locals,
    /// and what it moved or copied into its environment) live for one
    /// call at most: a loan on any of them is rejected. A loan the
    /// closure captured is on a value outside it, and the closure's
    /// creation already let the captured value hold it (`walkLambda`).
    fn storeThroughCapture(self: *Checker, v: Var, pos: u32, value: Value) Error!void {
        for (value.loans) |l| if (l.root >= self.func.closure_base) {
            try self.err(pos, "cannot store a view of `{s}` through captured `{s}`: `{s}` outlives every call of the closure, and the closure's parameters and own values last one call at most", .{ self.vars.items[l.root].name, v.name, v.name });
            return;
        };
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// A call. What it holds in storage of its own lives only while it
    /// runs (`holdForCall`), so a view of that ends with it.
    fn walkCall(self: *Checker, node: Sexp) Error!Value {
        const mark = self.call_held.items.len;
        const v = try self.walkCallBody(node);
        return self.endCallHeld(node, mark, v);
    }

    /// Hold `v`, the value of `node`, which the emitted call keeps in
    /// storage of its own (`sema.Storage` of life `call`: a receiver, or
    /// a copied argument), in a hidden var the call is lent (`kind`), so
    /// a view of it is a view of that storage.
    fn holdForCall(self: *Checker, node: Sexp, v: Value, kind: LoanKind) Error!Value {
        const pos = self.startOf(node);
        const id = try self.addVar(.{ .name = self.spanText(node), .decl = pos, .ty = self.exprType(node), .kind = .hidden, .call_held = true }, .{ .loans = v.loans });
        try self.call_held.append(self.gpa, id);
        return .{ .loans = try self.oneLoan(.{ .root = id, .kind = kind, .pos = pos }) };
    }

    /// The node a call holds in storage of its own that lives only while
    /// it runs, and that it lends (a copy, or a value the storage owns),
    /// when the storage facts record one of `kind` for it: a receiver
    /// without its lend sigils, an argument as written.
    fn heldForCall(self: *const Checker, e: Sexp, kind: sema.StorageKind) ?Sexp {
        const ctx = self.sema orelse return null;
        const node = if (kind == .receiver) storage.lentPlace(e) else e;
        const s = ctx.storageOf(node, kind) orelse return null;
        if (s.life != .call or s.by == .pointer) return null;
        // An owned argument is the callee's own value, not a lend of it.
        if (kind == .argument and s.by != .copy) return null;
        return node;
    }

    /// The storage of the call `node` held since `mark` ends as it
    /// returns `v`: the result, unless the statement discards it, and
    /// every var the call stored a view of it in, may not keep one.
    fn endCallHeld(self: *Checker, node: Sexp, mark: usize, v: Value) Error!Value {
        var out = v;
        var i = self.call_held.items.len;
        while (i > mark) {
            i -= 1;
            const id = self.call_held.items[i];
            if (self.reachable) {
                // Only a value nothing uses (an expression statement's,
                // `sema.discardsValue`) may keep no loan without a report.
                const discarded = if (self.sema) |ctx| ctx.discardsValue(node) else false;
                if (!discarded) for (out.loans) |l| if (l.root == id) {
                    try self.reportCallHeld(l, null);
                    break;
                };
            }
            var kept: std.ArrayList(Loan) = .empty;
            for (out.loans) |l| if (l.root != id) try kept.append(self.arena(), l);
            out.loans = kept.items;
            if (self.isLent(id)) for (0..self.flows.items.len) |holder| {
                if (holder == id) continue;
                var f = self.flows.items[holder];
                if (!hasLoanOn(f.loans, id)) continue;
                if (self.reachable and self.holderLive(@intCast(holder), null)) for (f.loans) |l| if (l.root == id) {
                    try self.reportCallHeld(l, @intCast(holder));
                    break;
                };
                var left: std.ArrayList(Loan) = .empty;
                for (f.loans) |l| if (l.root != id) try left.append(self.arena(), l);
                f.loans = left.items;
                try self.setFlow(@intCast(holder), f);
            };
            var t: usize = 0;
            while (t < self.temps.items.len) {
                if (self.temps.items[t].root == id) _ = self.temps.orderedRemove(t) else t += 1;
            }
            try self.setFlow(id, .{ .status = .dropped, .at = self.startOf(node) });
        }
        self.call_held.shrinkRetainingCapacity(mark);
        return out;
    }

    fn walkCallBody(self: *Checker, node: Sexp) Error!Value {
        const temps_start = self.temps.items.len;
        // Compile-time arguments (`f[3](x)`) are constants: no effect.
        const callee = if (self.sema) |s| s.calleeOf(node) else ir.Call.callee(node);
        const args = ir.Call.args(node);
        if (self.swapBuiltin(callee)) |swap| if (args.len == 2) return self.walkSwapCall(args, swap);
        // The value the call calls (a closure's captures, what a lent
        // callable lends), which its result always carries, and its
        // receiver's value.
        var result: Value = .{};
        var recv_value: Value = .{};

        // Method call: the receiver is lent for the whole call. A
        // write receiver is reserved (read) while the arguments are
        // evaluated and must be otherwise unlent when the call starts.
        var recv_root: ?VarId = null;
        var recv_mode: sema.MethodReceiver = .read;
        var reservation: usize = 0;
        // What the call reads in place before its arguments run (the value
        // it calls, or a receiver that is no place) is copied there, so it
        // is held until the call runs (`holdRead`).
        const callee_found = self.errors_found;
        if (callee.isKind(.member) and self.callsFunctionField(node, callee)) {
            // A function held in a field is called with the arguments
            // alone; it reaches nothing of the value holding it.
            result = try self.walk(ir.Member.object(callee));
            if (self.errors_found == callee_found) try self.holdRead(callee, .callee);
        } else if (callee.isKind(.member)) {
            var obj = ir.Member.object(callee);
            var explicit_write = false;
            if (obj.isKind(.write) or obj.isKind(.read)) {
                explicit_write = obj.isKind(.write);
                obj = ir.get(obj, .operand);
            }
            recv_mode = if (explicit_write) .write else self.receiverMode(obj, callee);
            const place = if (recv_mode == .value) null else self.resolvePlace(obj);
            if (place) |p| {
                const found = self.errors_found;
                // The receiver is passed by address: its indices are held
                // as a viewed place's are.
                const mark = self.temps.items.len;
                try self.addTemp(.{ .root = p.root, .kind = .read, .pos = self.startOf(obj), .place_hold = true });
                const recv_val = try self.walk(obj);
                if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
                const id = p.root;
                // A receiver already reported (used while a write loan is live)
                // is not reported again as a conflicting write view.
                if (self.flowLive(id) and !self.isScalar(self.vars.items[id].ty) and self.errors_found == found) {
                    const pos = self.startOf(obj);
                    reservation = self.temps.items.len;
                    try self.addTemp(.{ .root = id, .kind = .read, .pos = pos });
                    recv_root = id;
                    // A built-in's methods hand out values, never views
                    // of the receiver.
                    const kind: LoanKind = if (recv_mode == .write) .write else .read;
                    recv_value = if (self.builtinName(self.exprType(obj)) != null) recv_val else try self.valueUnion(recv_val, try self.lendOn(id, .{ .root = id, .kind = kind, .pos = pos }));
                }
            } else if (recv_mode == .value) {
                // A consuming receiver is taken like an argument: a name
                // it yields through a branch is moved with `<`.
                recv_value = try self.walkConsumed(ir.Member.object(callee), .argument);
            } else {
                recv_value = try self.walk(ir.Member.object(callee));
                if (self.errors_found == callee_found) try self.holdRead(ir.Member.object(callee), .receiver);
                // A built-in's methods hand out values, never views of
                // the receiver.
                if ((recv_mode == .read or recv_mode == .write) and !self.namesType(callee) and self.builtinName(self.exprType(obj)) == null) {
                    const kind: LoanKind = if (recv_mode == .write) .write else .read;
                    // A receiver the call holds in storage of its own is
                    // lent from there; any other is lent where its leaves
                    // are.
                    recv_value = if (self.heldForCall(obj, .receiver)) |held|
                        try self.holdForCall(held, recv_value, kind)
                    else
                        try self.valueUnion(recv_value, try self.receiverLeaves(obj, kind));
                }
            }
        } else if (callee == .src) {
            // A callable's result may view what the callable holds: a
            // closure its captures, a callable view what it lends.
            result = try self.walkName(callee, true);
            if (self.errors_found == callee_found) try self.holdRead(callee, .callee);
        } else if (isLambda(callee)) {
            self.lambda_ok = true;
            result = try self.walk(callee);
        } else {
            result = try self.walk(callee);
            if (self.errors_found == callee_found) try self.holdRead(callee, .callee);
        }

        // `print`, `Text(...)`, and `!t.add(...)` only read their
        // arguments, and hold none of them past the call: a Text keeps
        // their text, not them.
        const text_op = if (self.sema) |ctx| ctx.textCallOf(node) orelse ctx.textCallOf(callee) else null;
        if (self.isPrint(callee) or text_op != null) {
            for (args) |a| {
                _ = try self.walk(a);
                try self.holdRead(a, .argument);
            }
            if (recv_root) |id| if (recv_mode == .write) {
                const reserved = self.temps.orderedRemove(reservation);
                _ = try self.conflicts(id, .write, self.startOf(ir.Member.object(callee)));
                try self.temps.insert(self.gpa, reservation, reserved);
            };
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        }
        // Every handle to a Cell or Signal reaches what it holds, so what
        // goes in (`Cell(v)`, `set`, `replace`, `subscribe`) may
        // not hold a view.
        const into = if (callee.isKind(.member) and !self.namesType(callee))
            self.builtinName(self.exprType(ir.Member.object(callee)))
        else if (self.namesType(callee)) self.builtinName(self.exprType(node)) else null;
        const cell: ?[]const u8 = if (into != null and !std.mem.eql(u8, into.?, "Vec")) into else null;
        // A consuming receiver is passed like an argument.
        const consumed_recv = if (recv_mode == .value and callee.isKind(.member)) recv_value else Value{};
        // Which arguments the call passes loans on from (Core sentence
        // 7): the callee's origins, by the parameter each argument fills.
        const params = if (self.sema) |ctx| ctx.callParamsOf(node) else null;
        if (params == null or params.?.resultCarriesReceiver()) result = try self.valueUnion(result, recv_value);
        const arg_values = try self.arena().alloc(Value, args.len);
        // What the call may store, and what its result carries. A method
        // may store a view of what its receiver holds, or is, in what it
        // was lent to write (`h.r = ?self.items[..]`).
        var stored: Value = if (params == null or params.?.storesReceiver()) recv_value else .{};
        var carried: Value = .{};
        // A closure literal passed to a call the type checker rejected
        // was reported there.
        const saved_rejected = self.in_rejected_call;
        defer self.in_rejected_call = saved_rejected;
        for (args, arg_values, 0..) |a, *v, i| {
            self.in_rejected_call = self.rejected(node);
            const found = self.errors_found;
            v.* = try self.walkConsumed(a, .argument);
            if (self.errors_found == found) try self.holdRead(a, .argument);
            // An argument the call copies into storage of its own is lent
            // from the copy.
            if (self.heldForCall(storage.argValue(a), .argument)) |held| v.* = try self.holdForCall(held, v.*, .read);
            // A generic body's `T` holds no loan here, but an instance's
            // may be a String viewing a Text.
            if (cell != null) try self.requireNoView(self.startOf(a), self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a));
            if (cell != null and v.loans.len > 0 and !self.rejected(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a)) {
                const held = v.*;
                v.* = .{};
                if (self.readsPlainValue(a)) continue;
                // A view of a String stores the String it reaches: what
                // it views, not the view.
                const arg_ty = self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a);
                const loans = (try self.carry(self.reachedType(arg_ty), held)).loans;
                if (loans.len == 0) continue;
                try self.errAt(a, "cannot store a view of `{s}` in a `{s}`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one", .{ self.vars.items[loans[0].root].name, cell.? });
                continue;
            }
            if (!self.keepsCallable(node, a)) continue;
            if (params == null or params.?.stores(i)) stored = try self.valueUnion(stored, v.*);
            if (params == null or params.?.resultCarries(i)) carried = try self.valueUnion(carried, v.*);
        }
        result = try self.valueUnion(result, carried);

        // A write receiver is lent when the call starts, before the
        // callee stores anything.
        if (recv_root) |id| if (recv_mode == .write) {
            // The reservation itself is no conflict.
            const reserved = self.temps.orderedRemove(reservation);
            _ = try self.conflicts(id, .write, self.startOf(ir.Member.object(callee)));
            try self.temps.insert(self.gpa, reservation, reserved);
        };

        // The callee may store what its arguments view into anything it
        // can mutate: the receiver, and whatever the write views passed
        // to it lead to (`!x`, a write view passed on or moved in, a
        // value holding one). A built-in element method (`!dst.copy(src)`)
        // stores only elements, which may hold no view to store.
        if (stored.loans.len > 0 and !self.storesNothing(callee)) {
            // A receiver lent to read is never written (Core sentence 9:
            // what changes through one is a Cell, which holds no loan).
            if (recv_root) |id| if (recv_mode == .write) {
                const obj = ir.Member.object(callee);
                // What the receiver is, not the view lending it.
                if (self.mayCarryLoan(self.pointee(self.exprType(obj)))) try self.absorbLoans(id, stored, self.startOf(obj), &.{}, null, true);
            };
            try self.absorbThroughWrites(consumed_recv, stored, self.startOf(callee), null, null);
            for (args, arg_values) |a, v| try self.absorbThroughWrites(v, stored, self.startOf(a), null, null);
        }

        // The views passed to the call end when it returns, unless its
        // result can carry them.
        if (!self.mayCarryLoan(self.exprType(node))) {
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        }
        // The result views only what could hold it (Core sentence 7). A
        // String's views end here but for those it keeps.
        const ty = self.exprType(node) orelse return result;
        if (self.sema) |ctx| if (sema.holdsViewOnly(ctx, ty)) return self.keepViewTemps(temps_start, try self.carryResult(ty, result));
        return self.carryResult(ty, result);
    }

    /// A value read in place, by value, before the operands after it run
    /// (`reader`: a call argument, a method's receiver, the value a call
    /// calls, a binary operator's left operand, an indexed value that is
    /// no place), when the value shares storage the place it reads owns
    /// (a Vec's buffer, a box, a shared handle, a struct holding one;
    /// through a write view, what it reaches). Its consumer uses that
    /// value only after the later operands run, so until then the place's
    /// root holds a read loan, and a later operand cannot lend to write or
    /// move it. Plain data is copied whole when it is read, and what a
    /// read view reaches is covered by its own loans.
    fn holdRead(self: *Checker, operand: Sexp, reader: Reader) Error!void {
        const ctx = self.sema orelse return;
        const e = if (operand.isKind(.kwarg)) ir.Kwarg.value(operand) else operand;
        const place = self.resolvePlace(e) orelse return self.holdBranchReads(e, reader);
        const v = self.vars.items[place.root];
        if (v.ref == .read or v.closure or !self.flowLive(place.root)) return;
        var ty = self.exprType(e) orelse return;
        while (ctx.types.get(ty) == .write_view) ty = ctx.types.get(ty).write_view;
        if (!sema.readByAddress(ctx, ty)) return;
        try self.addTemp(.{ .root = place.root, .kind = .read, .pos = self.startOf(e), .held_read = reader });
    }

    /// The places a value that is no place reads in place: what a read
    /// branching value (`a if c else b`, `o ?? d`, `e catch d`, `o?`) may
    /// be (`sema.valueLeaves`), and a field or element of one, held as
    /// `holdRead` holds a place. The value is copied where it runs, so a
    /// place holding a Cell is held against any later lend: one that
    /// changes the Cell would leave the copy stale.
    fn holdBranchReads(self: *Checker, e: Sexp, reader: Reader) Error!void {
        // A field or element that owns storage is read where the value
        // holding it is.
        if (self.isPartOfNoPlace(e)) {
            const ctx = self.sema orelse return;
            const ty = self.exprType(e) orelse return;
            if (!sema.readByAddress(ctx, ty)) return;
            return self.holdBranchReads(ir.get(e, .object), reader);
        }
        var leaves: std.ArrayList(Sexp) = .empty;
        try sema.valueLeaves(self.arena(), e, &leaves);
        for (leaves.items) |leaf| {
            if (self.isPartOfNoPlace(leaf)) try self.holdBranchReads(leaf, reader) else try self.holdBranchLeaf(leaf, reader);
        }
    }

    /// What a method called on `obj`, a receiver that is no place, is
    /// lent: the method runs on the receiver where it is, so a view it
    /// returns may view whatever the receiver may be (Core sentence 7).
    /// For each leaf of the value its fields and elements are read from
    /// (`sema.valueLeaves`: each branch of `a if c else b`, `o ?? d`,
    /// `e catch d`), a loan on the place a name holds, or on the
    /// statement's temporary a made value is, which ends with the
    /// statement (Core §3).
    fn receiverLeaves(self: *Checker, obj: Sexp, kind: LoanKind) Error!Value {
        var base = obj;
        while (self.isPartOfNoPlace(base)) base = ir.get(base, .object);
        // A value its statement keeps in a slot (`dropsTemp`), a copy of a
        // branching value's leaf included, is lent there.
        if (self.sema) |ctx| if (ctx.dropsTemp(base)) {
            const pos = self.startOf(base);
            var i = self.stmt_drops.items.len;
            while (i > 0) {
                i -= 1;
                const d = self.stmt_drops.items[i];
                if (d.pos == pos) return .{ .loans = try self.oneLoan(.{ .root = d.id, .kind = .read, .pos = pos }) };
            }
        };
        var leaves: std.ArrayList(Sexp) = .empty;
        try sema.valueLeaves(self.arena(), base, &leaves);
        var out: Value = .{};
        for (leaves.items) |leaf| {
            const pos = self.startOf(leaf);
            if (self.resolvePlace(leaf)) |p| {
                if (!self.flowLive(p.root)) continue;
                out = try self.valueUnion(out, try self.lendOn(p.root, .{ .root = p.root, .kind = kind, .pos = pos }));
                continue;
            }
            if (self.isPartOfNoPlace(leaf)) {
                out = try self.valueUnion(out, try self.receiverLeaves(leaf, kind));
                continue;
            }
            // A name that is no var (a module's, a constant's) names no
            // storage of this function.
            if (leaf == .src) continue;
            // A made value: the temporary its statement holds, made here
            // if the value needs no drop.
            const held = for (self.stmt_drops.items) |d| {
                if (d.pos == pos) break d.id;
            } else null;
            const loan: Loan = .{ .root = held orelse (try self.holdTemp(leaf, .{})).loans[0].root, .kind = .read, .pos = pos };
            out = try self.valueUnion(out, .{ .loans = try self.oneLoan(loan) });
        }
        return out;
    }

    /// Whether `e` is a field or element of a value that is no place.
    fn isPartOfNoPlace(self: *Checker, e: Sexp) bool {
        if (!e.isKind(.member) and !e.isKind(.index)) return false;
        return self.resolvePlace(e) == null and !rig.isRangeIndex(e);
    }

    fn holdBranchLeaf(self: *Checker, leaf: Sexp, reader: Reader) Error!void {
        const ctx = self.sema orelse return;
        const place = self.resolvePlace(leaf) orelse return;
        const v = self.vars.items[place.root];
        if (v.ref == .read or v.closure or !self.flowLive(place.root)) return;
        const ty = self.exprType(leaf) orelse return;
        if (!sema.readByAddress(ctx, ty)) return;
        const kind: LoanKind = if (sema.holdsCellByValue(ctx, sema.unwrapViews(ctx, ty))) .write else .read;
        try self.addTemp(.{ .root = place.root, .kind = kind, .pos = self.startOf(leaf), .held_read = reader });
    }

    /// Walk `earlier`, then `later` while what `earlier` reads in place is
    /// held (`holdRead`): the consumer of both, a binary operator or an
    /// index of a value that is no place, uses `earlier` after `later`
    /// runs. The hold ends there.
    fn walkThenHeld(self: *Checker, earlier: Sexp, reader: Reader, later: Sexp) Error!Value {
        const found = self.errors_found;
        const first = try self.walk(earlier);
        const mark = self.temps.items.len;
        if (self.errors_found == found) try self.holdRead(earlier, reader);
        var held = self.temps.items.len - mark;
        _ = try self.walk(later);
        while (held > 0 and mark < self.temps.items.len and self.temps.items[mark].held_read == reader) : (held -= 1) {
            _ = self.temps.orderedRemove(mark);
        }
        return first;
    }

    /// Whether call `call` may keep what argument `arg` views. No value
    /// holds a callable view, so a callable lent to a call is kept
    /// only by a result that is one, or through what it returns when
    /// that can hold a view.
    fn keepsCallable(self: *const Checker, call: Sexp, arg: Sexp) bool {
        const ctx = self.sema orelse return true;
        const value = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
        const fn_ty = ctx.callableOf(value) orelse blk: {
            const ty = self.exprType(value) orelse return true;
            if (sema.callableFn(ctx, ty) == null) return true;
            break :blk sema.callableFnTy(ctx, ty).?;
        };
        if (sema.holdsCallable(ctx, self.exprType(call) orelse return true)) return true;
        return self.mayCarryLoan(ctx.types.get(fn_ty).function.returns);
    }

    /// A call of a built-in element method whose elements hold no
    /// view: it stores none of its arguments' views.
    fn storesNothing(self: *const Checker, callee: Sexp) bool {
        const ctx = self.sema orelse return false;
        const ec = ctx.elemCallOf(callee) orelse return false;
        return !self.mayCarryLoan(ec.elem);
    }

    /// A view of plain data (`k` with `k: ?Int`) passed where a value
    /// is expected is read by value: what it views is not stored.
    fn readsPlainValue(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        const arg = if (e.isKind(.kwarg)) ir.Kwarg.value(e) else e;
        return switch (self.typeData(self.exprType(arg) orelse return false)) {
            .read_view, .write_view => |inner| sema.isPlainData(ctx, inner) and !self.mayCarryLoan(inner),
            else => false,
        };
    }

    /// Whether `callee` is the built-in `swap` (true) or `replace`
    /// (false); null for anything else.
    fn swapBuiltin(self: *Checker, callee: Sexp) ?bool {
        if (callee != .src) return null;
        const name = self.text(callee);
        const swap = std.mem.eql(u8, name, "swap");
        if (!swap and !std.mem.eql(u8, name, "replace")) return null;
        if (self.sema) |ctx| return if (ctx.symbolOf(callee) == null) swap else null;
        return if (self.find(name) == null) swap else null;
    }

    /// `replace(!place, v)` / `swap(!a, !b)`: the places are lent to write
    /// for the call, and `v` moves in. The two places of a `swap` may be
    /// different fields of one value (`swap(!t.left, !t.right)`); neither
    /// may hold the other. The result holds no view.
    fn walkSwapCall(self: *Checker, args: []const Sexp, swap: bool) Error!Value {
        const start = self.temps.items.len;
        const first = try self.walkConsumed(args[0], .argument);
        const lent = self.temps.items.len;
        var saved: std.ArrayList(Loan) = .empty;
        defer saved.deinit(self.gpa);
        const elements = if (swap) self.sameCollection(args[0], args[1]) else null;
        if (elements) |e| {
            // Two elements of one collection: its own `swap` exchanges
            // them.
            try self.err(self.startOf(ir.Write.operand(args[1])), "cannot lend `{s}` to write while a write loan is live: to swap two elements of `{s}`, write `!{s}.swap({s}, {s})`", .{ e.base, e.base, e.base, e.i, e.j });
        }
        if (swap and (elements != null or self.disjointFields(args[0], args[1]))) {
            try saved.appendSlice(self.gpa, self.temps.items[start..lent]);
            self.temps.shrinkRetainingCapacity(start);
        }
        const second = try self.walkConsumed(args[1], .argument);
        try self.temps.appendSlice(self.gpa, saved.items);
        // The places hold no view, but may hold Strings: what `replace`
        // hands back views what the place viewed, and each place now
        // views what went in.
        var result: Value = .{};
        const ty = self.exprType(args[1]);
        if (!swap and self.mayCarryLoan(ty)) result = try self.carry(ty, first);
        try self.absorbThroughWrites(first, second, self.startOf(args[1]), null, null);
        if (swap) try self.absorbThroughWrites(second, first, self.startOf(args[0]), null, null);
        self.temps.shrinkRetainingCapacity(start);
        return result;
    }

    /// `!a[i]` and `!a[j]`: write views of two elements of the one
    /// collection `a`, as the source spells them.
    fn sameCollection(self: *const Checker, a: Sexp, b: Sexp) ?struct { base: []const u8, i: []const u8, j: []const u8 } {
        if (!a.isKind(.write) or !b.isKind(.write)) return null;
        const ea = ir.Write.operand(a);
        const eb = ir.Write.operand(b);
        if (!ea.isKind(.index) or !eb.isKind(.index) or rig.isRangeIndex(ea) or rig.isRangeIndex(eb)) return null;
        const base = self.spanText(ir.Index.object(ea));
        if (base.len == 0 or !std.mem.eql(u8, base, self.spanText(ir.Index.object(eb)))) return null;
        return .{ .base = base, .i = self.spanText(ir.Index.index(ea)), .j = self.spanText(ir.Index.index(eb)) };
    }

    fn spanText(self: *const Checker, node: Sexp) []const u8 {
        const sp = self.span(node);
        return self.source[sp.start..sp.end];
    }

    /// `!a.x` and `!a.y`: write views of two fields of one binding,
    /// neither inside the other.
    fn disjointFields(self: *Checker, a: Sexp, b: Sexp) bool {
        if (!a.isKind(.write) or !b.isKind(.write)) return false;
        var fa: [16]Sexp = undefined;
        var fb: [16]Sexp = undefined;
        const na = fieldChain(ir.Write.operand(a), &fa) orelse return false;
        const nb = fieldChain(ir.Write.operand(b), &fb) orelse return false;
        if (na == 0 or nb == 0 or !std.mem.eql(u8, self.text(fa[0]), self.text(fb[0]))) return false;
        for (1..@min(na, nb)) |i| {
            if (!std.mem.eql(u8, self.text(fa[i]), self.text(fb[i]))) return true;
        }
        return false;
    }

    fn isPrint(self: *Checker, callee: Sexp) bool {
        if (callee != .src or !std.mem.eql(u8, self.text(callee), "print")) return false;
        if (self.sema) |ctx| return ctx.symbolOf(callee) == null;
        return self.find("print") == null;
    }

    /// `Cell`, `Signal`, or `Vec` when a value of type `ty` is one,
    /// through views and shared handles.
    fn builtinName(self: *const Checker, ty: ?TypeId) ?[]const u8 {
        const ctx = self.sema orelse return null;
        var t = ty orelse return null;
        while (true) switch (ctx.types.get(t)) {
            .read_view, .write_view, .shared => |i| t = i,
            .parameterized_nominal => |pn| {
                if (pn.sym == ctx.cell_sym_id) return "Cell";
                if (pn.sym == ctx.signal_sym_id) return "Signal";
                if (pn.sym == ctx.vec_sym_id) return "Vec";
                return null;
            },
            else => return null,
        };
    }

    /// Record that the values the write loans in `v` lead to may now hold
    /// the loans in `stored`. Those write loans are the path to them, not
    /// something stored. `via` names the write view an assignment
    /// stores through; without it, a call stores them.
    ///
    /// Without a `depth` (a call, which may store anywhere its arguments
    /// reach), every value the write loans lead to, however deep, may
    /// hold them. An assignment goes through `depth` write views from
    /// `v` (`placeDepth`): the values within that many write loans may
    /// hold them, and the ones further on, which only what it wrote
    /// views, do not. A write view var on the way (`w2 = !w`) is a
    /// name for what it views, and takes no step of its own.
    fn absorbThroughWrites(self: *Checker, v: Value, stored: Value, pos: u32, via: ?[]const u8, depth: ?u32) Error!void {
        var level: std.ArrayList(VarId) = .empty;
        try self.appendWriteRoots(&level, v, &.{});
        const d = depth orelse {
            for (level.items) |r| {
                // Only a value that can hold a view can have one stored in it.
                if (!self.mayCarryLoan(self.pointee(self.vars.items[r].ty))) continue;
                try self.absorbLoans(r, stored, pos, level.items, via, true);
            }
            return;
        };
        // The values reached, found before any of them takes the loans.
        var seen: std.ArrayList(VarId) = .empty;
        var remaining = d;
        while (level.items.len > 0 and seen.items.len <= 64) {
            var next: std.ArrayList(VarId) = .empty;
            var i: usize = 0;
            while (i < level.items.len) : (i += 1) {
                const r = level.items[i];
                if (std.mem.findScalar(VarId, seen.items, r) != null) continue;
                try seen.append(self.arena(), r);
                const c = self.vars.items[r];
                if ((c.kind == .param and c.ref != .none) or self.isGlobal(r)) continue;
                if (c.ref == .write) {
                    try self.appendWriteRoots(&level, self.varValue(r), seen.items);
                } else if (remaining > 1) try self.appendWriteRoots(&next, self.varValue(r), seen.items);
            }
            if (remaining <= 1) break;
            remaining -= 1;
            level = next;
        }
        if (seen.items.len > 64) return self.absorbThroughWrites(v, stored, pos, via, null);
        for (seen.items) |r| {
            if (!self.mayCarryLoan(self.pointee(self.vars.items[r].ty))) continue;
            try self.absorbLoans(r, stored, pos, seen.items, via, false);
        }
    }

    /// Append to `out` the roots of the write loans in `v` not in `out`
    /// or `skip`.
    fn appendWriteRoots(self: *Checker, out: *std.ArrayList(VarId), v: Value, skip: []const VarId) Error!void {
        for (v.loans) |l| {
            if (l.kind != .write or std.mem.findScalar(VarId, out.items, l.root) != null or std.mem.findScalar(VarId, skip, l.root) != null) continue;
            try out.append(self.arena(), l.root);
        }
    }

    /// The number of write views a store to `target` goes through from
    /// its root var's value: each one the path reaches through, the root
    /// included, and the `!T` the place itself holds when the store
    /// writes through it.
    fn placeDepth(self: *const Checker, target: Sexp, writes_through: bool) u32 {
        var n: u32 = @intFromBool(writes_through);
        var e = target;
        while (e.isKind(.member) or e.isKind(.index)) {
            e = ir.get(e, .object);
            // A root var holding a write view (a `match !x` binding
            // among them, whatever its type) is one.
            const root_is_write_view = e == .src and if (self.find(self.text(e))) |id| self.vars.items[id].ref == .write else false;
            const is_write_view = if (self.exprType(e)) |t| self.typeData(t) == .write_view else false;
            if (root_is_write_view or is_write_view) n += 1;
        }
        return n;
    }

    /// Record that var `id` may now hold the loans in `v`, and so may
    /// every value it lends to write: a store through a write view lands
    /// there. `through` are the vars whose write views led to `id`;
    /// their own loans are the path, not something stored. A viewed
    /// parameter or a module-level binding outlives this function's
    /// values: storing a view of one into it is rejected, and a
    /// view parameter holds the loans the caller handed in, as any
    /// var does. `via` is as for `absorbThroughWrites`.
    fn absorbLoans(self: *Checker, id: VarId, v_in: Value, pos: u32, through: []const VarId, via: ?[]const u8, deeper: bool) Error!void {
        // A value that holds only Strings keeps only what leads to a Text.
        // What lands in a value that holds only Strings needs only what
        // could hold them (`carry`).
        const t = self.pointee(self.vars.items[id].ty);
        const strings = if (self.sema) |ctx| if (t) |inner| sema.holdsViewOnly(ctx, inner) else false else false;
        const v = if (strings) try self.carry(t, v_in) else v_in;
        var out: std.ArrayList(Loan) = .empty;
        for (v.loans) |l| {
            if (l.root != id and std.mem.findScalar(VarId, through, l.root) == null) try out.append(self.arena(), l);
        }
        if (out.items.len == 0) return;
        const c = self.vars.items[id];
        if ((c.kind == .param and c.ref != .none) or self.isGlobal(id)) {
            // The caller accounts for views it passed in; only views
            // of this function's own values cannot be stored. Nothing
            // viewed may be stored in a module-level binding.
            for (out.items) |l| if (self.isLocalLoan(l) or self.isGlobal(id)) {
                const name = self.vars.items[l.root].name;
                if (via) |w| {
                    try self.err(pos, "cannot store a view of `{s}` through `{s}`: `{s}` outlives it", .{ name, w, c.name });
                } else try self.err(pos, "cannot let this call store a view of `{s}` in `{s}`: `{s}` outlives it", .{ name, c.name, c.name });
                return;
            };
            // The parameter holds what is stored in the value the caller
            // lent it. It is live at every exit (`holderLive`), since the
            // caller reads that value after the return, so each loan stays
            // in force for the rest of the body.
            self.recordStore(id, out.items, pos);
            var pf = self.flows.items[id];
            pf.loans = try self.unionLoans(pf.loans, out.items);
            return self.setFlow(id, pf);
        }
        var f = self.flows.items[id];
        const held = f.loans;
        f.loans = try self.unionLoans(held, out.items);
        try self.setFlow(id, f);
        if (!deeper or through.len > 16) return;
        const next = try std.mem.concat(self.arena(), VarId, &.{ through, &.{id} });
        for (held) |l| {
            if (l.kind != .write or std.mem.findScalar(VarId, next, l.root) != null) continue;
            // Only a value that can hold a view can have one stored in it.
            if (!self.mayCarryLoan(self.pointee(self.vars.items[l.root].ty))) continue;
            try self.absorbLoans(l.root, v, pos, next, via, true);
        }
    }

    /// A loan on a value owned by the current function (as opposed to one
    /// the caller handed in through a view parameter, or a
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
        var cap_values: std.ArrayList(Value) = .empty;
        const caps = sema.captureList(ir.Lambda.captures(node));
        for (caps) |cap| {
            const cv = try self.applyCapture(cap);
            try cap_values.append(self.arena(), cv);
            if (owned) try self.requireNoView(sema.captureNameNode(cap).?.src.pos, self.symType(sema.captureNameNode(cap).?.src.pos));
            // An owned closure is a shared handle that may be stored
            // anywhere, including in a Cell or Signal: it holds no view.
            if (owned and cv.loans.len > 0) {
                const name = self.text(sema.captureNameNode(cap).?);
                const l = cv.loans[0];
                const mode = sema.captureModeOf(cap).?;
                if (mode == .cap_read or mode == .cap_write) {
                    try self.err(sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture a view of `{s}`: it can be stored anywhere, so it could outlive `{s}`; capture an owned value, or use a stack closure (`|...|`)", .{ name, name });
                    value = try self.valueUnion(value, cv);
                    continue;
                }
                try self.err(sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture `{s}`, which holds a view{s}{s}{s}; capture an owned value, or use a stack closure (`|...|`)", .{
                    name,
                    if (l.ext) "" else " of `",
                    if (l.ext) "" else self.vars.items[l.root].name,
                    if (l.ext) "" else "`",
                });
                try self.noteLoan(l);
            }
            value = try self.valueUnion(value, cv);
        }
        // The body may store what one capture views into what a
        // captured write view leads to, as a call may with its
        // arguments: that value now holds those loans.
        if (!owned and caps.len > 1) for (caps, cap_values.items) |cap, cv| {
            try self.absorbThroughWrites(cv, value, sema.captureNameNode(cap).?.src.pos, null, null);
        };

        // The body is checked as its own function; it cannot affect the
        // enclosing state.
        const snap = try self.here();
        const saved_func = self.func;
        const saved_loop = self.loop;
        const fn_ty = self.exprType(node);
        const ret_ty: ?TypeId = if (fn_ty) |t| switch (self.typeData(t)) {
            .function => |f| f.returns,
            else => null,
        } else null;
        const returns_value = ret_ty != null and !self.isVoid(ret_ty);
        self.func = .{
            .in_closure = true,
            .ret_may_view = returns_value and self.mayCarryLoan(ret_ty),
            .ret_ty = if (returns_value) ret_ty else null,
            .closure_base = @intCast(self.vars.items.len),
            .origins = try self.typeOrigins(fn_ty),
        };
        self.loop = null;
        self.reachable = true;
        try self.pushScopeFor(.closure, body);
        for (caps, cap_values.items) |cap, cv| {
            const name = sema.captureNameNode(cap).?;
            const ty = self.symType(name.src.pos);
            // A capture the type checker rejected holds nothing.
            const resource = !self.isPoisonType(ty) and switch (sema.captureModeOf(cap).?) {
                .cap_clone => !self.copies(ty),
                .cap_weak, .cap_move, .cap_read, .cap_write => true,
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
        try self.bindParams(params);
        try self.walkBody(body, returns_value);
        try self.popScope();
        try self.checkOrigins("this closure", .nil, params);
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
            if (mode == .cap_read) return self.lendClosure(id, pos);
            // Reported by the type checker.
            if (self.isPoisonType(self.symType(pos))) return .{};
            try self.err(pos, "cannot capture closure `{s}`; closures cannot be copied. Lend it with `|?{s}|`", .{ name, name });
            return .{};
        }
        if (mode == .cap_move) return self.moveVar(id, pos, .capture);
        // `|?x|` / `|!x|` view `x` for as long as the closure lives.
        if (mode == .cap_read or mode == .cap_write) return (try self.lendVar(id, if (mode == .cap_read) .read else .write, pos)) orelse .{};
        if (!try self.checkCapturable(id, pos)) return .{};
        if (self.findLoan(id, .write, null)) |l| {
            try self.err(pos, "cannot capture `{s}` while a write loan is live", .{name});
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
        _ = try self.exitTo(.{ .exit = .{ .@"return" = value != .nil and self.mayFail(value) } });
        self.reachable = false;
    }

    /// A value leaving the function: a bare local moves out; anything
    /// else must not copy an owning value; views must come from
    /// view parameters.
    fn walkReturnValue(self: *Checker, expr: Sexp) Error!void {
        var value: Value = .{};
        if (expr == .src) {
            try self.checkNoImplicitCopy(expr, .ret, true);
            if (self.find(self.text(expr))) |id| {
                const v = self.vars.items[id];
                if (v.closure) {
                    value = try self.walkName(expr, false);
                } else if (!v.loop_view and !v.capture_resource) {
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
        if (self.func.ret_may_view and self.reachable) {
            try self.checkEscape(value);
            self.recordResult(value, self.startOf(expr));
        }
    }

    /// A bare name that leaves the function moves out: a match payload
    /// out of its scrutinee, and an owning value out of its binding, so
    /// deferred code at that exit sees it moved.
    fn returnMoves(self: *const Checker, v: Var) bool {
        if (v.alias_of != null) return true;
        return self.owningKind(v.ty) != null;
    }

    /// The origins of the function or method declared with name `name`:
    /// which arguments its callers pass loans on from.
    fn declOrigins(self: *const Checker, name: Sexp) sema.Origins {
        const ctx = self.sema orelse return .{};
        if (name != .src) return .{};
        if (self.decl_owner) |owner| {
            for (ctx.symbols.items[owner].fields orelse &.{}) |f| {
                if (f.is_method and f.decl_pos == name.src.pos) return f.origins;
            }
            return .{};
        }
        const sym = ctx.symbolOf(name) orelse return .{};
        const s = ctx.symbols.items[sym];
        return if (s.kind == .function) s.origins else .{};
    }

    /// The origins a call of a value of function type `fn_ty` has: those
    /// its type gives (`sema.defaultOrigins`).
    fn typeOrigins(self: *Checker, fn_ty: ?TypeId) Error!sema.Origins {
        const ctx = self.sema orelse return .{};
        const f = switch (ctx.types.get(fn_ty orelse return .{})) {
            .function => |f| f,
            else => return .{},
        };
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        return sema.defaultOrigins(ctx, scratch.allocator(), f);
    }

    /// The index of the current function's run-time parameter that
    /// loan `l` is on, if any: a loan the caller handed in through it,
    /// or one of it as a view (`?p` with `p: !T`).
    fn paramOf(self: *const Checker, l: Loan) ?u8 {
        if (self.func.in_closure and l.root < self.func.closure_base) return null;
        const r = self.vars.items[l.root];
        if (r.kind != .param) return null;
        return r.param_index;
    }

    /// Record that the function returns `v`: the parameters whose loans
    /// it carries are among those a call's result carries.
    fn recordResult(self: *Checker, v: Value, pos: u32) void {
        // A loan on what is the function's own (a parameter taken by
        // value) cannot leave it, which `checkEscape` reports.
        for (v.loans) |l| if (!self.isLocalLoan(l)) if (self.paramOf(l)) |i| {
            const bit = sema.paramBit(i);
            if (self.func.returned & bit == 0) self.func.returned_at[i] = pos;
            self.func.returned |= bit;
        };
    }

    /// Record that the function stores `loans` in what parameter `into`
    /// leads to: the parameters they are on are among those a call may
    /// store.
    fn recordStore(self: *Checker, into: VarId, loans: []const Loan, pos: u32) void {
        // What cannot hold a view keeps no loan (`w = other` through
        // `w: !Int` copies a number).
        if (!self.mayCarryLoan(self.pointee(self.vars.items[into].ty))) return;
        for (loans) |l| if (l.root != into) if (self.paramOf(l)) |i| {
            const bit = sema.paramBit(i);
            if (self.func.stored & bit == 0) self.func.stored_at[i] = pos;
            self.func.stored |= bit;
        };
    }

    /// A body passes on only the loans its signature shows (Core
    /// sentence 7): what it returns and stores comes from the parameters
    /// its origins name. `params` are its run-time parameters.
    fn checkOrigins(self: *Checker, what: []const u8, name: Sexp, params: Sexp) Error!void {
        const o = self.func.origins;
        const items = params.items();
        const n = @min(items.len, @bitSizeOf(sema.ParamMask));
        for (0..n) |i| {
            const bit = sema.paramBit(i);
            const pname = if (sema.paramNameNode(items[i])) |pn| self.text(pn) else "?";
            if (self.func.returned & bit != 0 and o.result & bit == 0) {
                if (o.declared) {
                    const only = try self.paramList(items, o.result, true);
                    if (only.len == 0) {
                        try self.err(self.func.returned_at[i], "{s} returns a view of `{s}`, but its signature says it views only what lives for the whole program", .{ what, pname });
                    } else try self.err(self.func.returned_at[i], "{s} returns a view of `{s}`, but its signature says it views only {s}", .{ what, pname, only });
                    if (self.declaredFrom(name)) |d| {
                        const all = try self.paramList(items, self.func.returned, false);
                        if (self.namesStatic(items, self.func.returned)) {
                            try self.note(self.startOf(d.returns), "`from static` means what lives for the whole program, not the parameter `static`; rename the parameter to name it in `from`", .{});
                        } else try self.note(self.startOf(d.returns), "say so: `-> {s} from {s}`, or return a view of what it names only", .{ self.spanText(d.returns), all });
                    }
                    return;
                }
                try self.err(self.func.returned_at[i], "{s} returns a view of `{s}`, but a call of it carries no loan of `{s}`: its type cannot hold what the result views", .{ what, pname, pname });
            }
            if (self.func.stored & bit != 0 and o.stores & bit == 0) {
                try self.err(self.func.stored_at[i], "{s} stores a view of `{s}` where its caller can reach it, but a call of it keeps no loan of `{s}`: its type cannot hold what the write parameters hold", .{ what, pname, pname });
            }
        }
    }

    /// Whether a parameter of `mask` among `items` is named `static`,
    /// which `from` cannot name.
    fn namesStatic(self: *const Checker, items: []const Sexp, mask: sema.ParamMask) bool {
        for (items, 0..) |p, i| {
            if (mask & sema.paramBit(i) == 0) continue;
            const pn = sema.paramNameNode(p) orelse continue;
            if (std.mem.eql(u8, self.text(pn), "static")) return true;
        }
        return false;
    }

    /// The `from` clause of the function named `name`, if it writes one.
    fn declaredFrom(self: *const Checker, name: Sexp) ?sema.DeclaredOrigins {
        const ctx = self.sema orelse return null;
        if (name != .src) return null;
        return ctx.declared_origins.get(name.src.pos);
    }

    /// The parameters of `mask` among `items`, as a `from` list (`a, b`),
    /// each in backquotes when `quoted`.
    fn paramList(self: *Checker, items: []const Sexp, mask: sema.ParamMask, quoted: bool) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (items, 0..) |p, i| {
            if (mask & sema.paramBit(i) == 0) continue;
            const pn = if (sema.paramNameNode(p)) |n| self.text(n) else continue;
            if (out.items.len > 0) try out.appendSlice(self.arena(), ", ");
            if (quoted) try out.append(self.arena(), '`');
            try out.appendSlice(self.arena(), pn);
            if (quoted) try out.append(self.arena(), '`');
        }
        return out.items;
    }

    fn checkEscape(self: *Checker, v: Value) Error!void {
        for (v.loans, 0..) |l, i| {
            if (!self.isLocalLoan(l)) continue;
            if (self.func.in_closure and l.root < self.func.closure_base) continue;
            const r = self.vars.items[l.root];
            if (r.arm_of.len > 0) {
                try self.reportArmView(l);
                continue;
            }
            const seen = for (v.loans[0..i]) |p| {
                if (p.root == l.root and !p.ext) break true;
            } else false;
            if (seen) continue;
            if (r.kind == .param) {
                const shown = if (self.sema != null and r.ty != null) try sema.formatTypeIn(self.sema.?, self.arena(), r.ty.?) else "T";
                try self.err(l.pos, "cannot return a view of `{s}`: a parameter taken by value belongs to this function and ends with it; take `{s}: ?{s}` to return a view of the caller's value", .{ r.name, r.name, shown });
                try self.noteStringOfText(l, self.func.ret_ty);
                continue;
            }
            try self.err(l.pos, "cannot return a view of `{s}`, which this function was not lent", .{r.name});
            try self.note(r.decl, "`{s}` is local to this {s}", .{ r.name, if (self.func.in_closure) "closure" else "function" });
            try self.noteStringOfText(l, self.func.ret_ty);
        }
    }

    // -------------------------------------------------------------------------
    // Branches
    // -------------------------------------------------------------------------

    fn walkIf(self: *Checker, node: Sexp) Error!Value {
        const t = self.takeTail(node);
        const cond = ir.If.cond(node);
        if (cond.isKind(.as) or rig.isConditionJoin(cond)) return self.walkIfBinding(node, t);
        const then_b = ir.If.then(node);
        const else_b = ir.If.@"else"(node);
        // The condition is a header, its own statement.
        try self.walkStmt(cond);
        const base = try self.here();
        const past = resumeAt(.nil, node);
        const v1 = try self.walkTailPart(then_b, t);
        const s1 = try self.leave(base, past);
        const v2 = if (else_b != .nil) try self.walkTailPart(else_b, t) else Value{};
        const s2 = try self.leave(base, past);
        try self.apply(try self.join(s1, s2));
        return self.valueUnion(v1, v2);
    }

    /// `if a as x` and `if a as x and ...`: the parts run in order, each
    /// binding in a scope over the rest and the then-branch. The `else`
    /// runs when a part fails, so it starts from the state after the
    /// parts with their bindings gone.
    fn walkIfBinding(self: *Checker, node: Sexp, t: ?Tail) Error!Value {
        const then_b = ir.If.then(node);
        const else_b = ir.If.@"else"(node);
        const base = try self.here();
        const depth = self.scopes.items.len;
        try self.walkConditionParts(ir.If.cond(node), then_b);
        // A failing part goes on to the `else`, or past the `if`.
        const failed = try self.exitTo(.{ .to = base, .resume_at = resumeAt(else_b, node) });
        var v1 = try self.walkTailPart(then_b, t);
        while (self.scopes.items.len > depth) {
            v1 = try self.checkValueEscapesScope(v1);
            try self.popScope();
        }
        const past = resumeAt(.nil, node);
        const s1 = try self.leave(base, past);
        try self.apply(failed);
        const v2 = if (else_b != .nil) try self.walkTailPart(else_b, t) else Value{};
        const s2 = try self.leave(base, past);
        try self.apply(try self.join(s1, s2));
        return self.valueUnion(v1, v2);
    }

    /// The parts of a binding condition, in order. Each `as` moves the
    /// value inside its optional into a binding, in a new scope over
    /// `body`, which the caller pops. The binding holds what the value
    /// views; the loans taken to compute it end there, so the path
    /// where there is no value is free to use them.
    fn walkConditionParts(self: *Checker, cond: Sexp, body: Sexp) Error!void {
        if (rig.isConditionJoin(cond)) {
            try self.walkConditionParts(ir.get(cond, .left), body);
            return self.walkConditionParts(ir.get(cond, .right), body);
        }
        // Each part is a header, its own statement: its temporaries end
        // with it, after the binding takes what it binds.
        if (!cond.isKind(.as)) return self.walkStmt(cond);
        // A bare place is bound as `if ?p as x` binds it, and a part of a
        // made value in a hidden var the `if` holds, in a scope the
        // caller ends with the body's (docs/INTERNALS.md, "Header
        // subjects").
        const header = self.headerOf(cond);
        const saved_held = self.held;
        defer self.held = saved_held;
        if (header == .held) try self.holdBase(cond);
        const temps_start = self.temps.items.len;
        const drops = self.stmt_drops.items.len;
        const bound = if (header != null) try self.walkLend(ir.As.value(cond), .read) else try self.walkConsumed(ir.As.value(cond), .binding);
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        try self.pushScopeFor(.block, body);
        try self.bindNew(ir.As.name(cond), false, false, bound);
        try self.dropStmtTemps(drops);
    }

    /// `(catch expr name? handler)`: the handler runs when `expr` fails.
    fn walkCatch(self: *Checker, node: Sexp) Error!Value {
        const t = self.takeTail(node);
        const v1 = try self.walk(ir.Catch.value(node));
        const base = try self.here();
        const handler = ir.Catch.handler(node);
        try self.pushScopeFor(.block, handler);
        const name = ir.Catch.name(node);
        if (name != .nil) {
            _ = try self.addVar(.{ .name = self.text(name), .decl = name.src.pos, .ty = self.symType(name.src.pos) }, .{});
        }
        var v2 = try self.walkTailPart(handler, t);
        v2 = try self.checkValueEscapesScope(v2);
        try self.popScope();
        const s = try self.leave(base, resumeAt(.nil, node));
        try self.apply(try self.join(stateAt(base), s));
        return self.valueUnion(v1, v2);
    }

    /// `a ?? b`: `b` runs only when `a` is `none`. It may be a jump, which
    /// leaves the rest of the code reachable through the other path.
    fn walkNullish(self: *Checker, node: Sexp) Error!Value {
        const t = self.takeTail(node);
        const v1 = try self.walk(ir.@"??".left(node));
        const base = try self.here();
        const v2 = try self.walkTailPart(ir.@"??".right(node), t);
        const s = try self.leave(base, resumeAt(.nil, node));
        try self.apply(try self.join(stateAt(base), s));
        return self.valueUnion(v1, v2);
    }

    const Held = struct { base: Sexp, id: VarId };

    /// How the header `node` has its bare subject (`SemContext.headerOf`).
    fn headerOf(self: *const Checker, node: Sexp) ?sema.Header {
        const ctx = self.sema orelse return null;
        return ctx.headerOf(node);
    }

    /// Hold the value the header `node` makes of which its subject is a
    /// part (`SemContext.heldBaseOf`) in a hidden var of a scope opened
    /// for the construct: `var _h = <base`, whose part the construct
    /// views. The caller pops the scope where the construct ends.
    fn holdBase(self: *Checker, node: Sexp) Error!void {
        const ctx = self.sema orelse return;
        const base = ctx.heldBaseOf(node) orelse return;
        const v = try self.walkConsumed(base, .binding);
        try self.pushScopeFor(.block, node);
        const id = try self.addVar(.{ .name = self.spanText(base), .decl = self.startOf(base), .ty = self.exprType(base), .kind = .hidden }, .{ .loans = v.loans });
        self.held = .{ .base = base, .id = id };
    }

    /// Whether place `e` is a path from the value a header holds.
    fn heldPath(self: *const Checker, e: Sexp) bool {
        const h = self.held orelse return false;
        var base = e;
        while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
        return base == .list and base.list.ptr == h.base.list.ptr;
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
        const saved_arm = .{ self.arm_var, self.arm_subject, self.arm_take };
        defer {
            self.arm_var = saved_arm[0];
            self.arm_subject = saved_arm[1];
            self.arm_take = saved_arm[2];
        }
        // A bare place is matched as `match ?p`; a part of a made value
        // in a hidden var the match holds (docs/INTERNALS.md, "Header
        // subjects").
        const header = self.headerOf(match);
        const saved_held = self.held;
        defer self.held = saved_held;
        if (header == .held) try self.holdBase(match);
        var info: Scrutinee = .{};
        var node = scrut;
        const written = scrut.isKind(.read) or scrut.isKind(.write);
        const lent = written or header == .viewed or header == .held;
        if (lent) {
            if (written) node = ir.get(scrut, .operand);
            info.via = .viewed;
        }
        if (self.resolvePlace(node)) |p| {
            info.root = p.root;
            const v = self.vars.items[p.root];
            if (p.through_view or v.alias_of != null) info.via = .viewed;
            if (p.through_shared) info.via = .shared;
            if (self.exprType(node)) |t| if (self.typeData(t) == .shared) {
                info.via = .shared;
            };
            if (!p.whole) info.path = try self.placeText(node);
        }
        const scrut_temps = self.temps.items.len;
        // The subject is a header: its temporaries end with it.
        const drops = self.stmt_drops.items.len;
        const scrut_value = if (header == .viewed) try self.walkLend(scrut, .read) else try self.walk(scrut);
        const header_temps = try self.arena().alloc(VarId, self.stmt_drops.items.len - @min(drops, self.stmt_drops.items.len));
        for (header_temps, self.stmt_drops.items[self.stmt_drops.items.len - header_temps.len ..]) |*t, d| t.* = d.id;
        // A view the subject yields, which the match reads where it points
        // (its tag, its payloads) after the header: one that carries a
        // loan on a temporary the header made reads it after its drop.
        if (self.sema) |ctx| if (!sema.handsOver(ctx, scrut).hasStorage()) if (ctx.typeOf(scrut)) |ty| if (sema.viewHeldAsPointer(ctx, ty)) {
            for (scrut_value.loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null) {
                const temp = self.vars.items[l.root].name;
                try self.err(l.pos, "this `match` reads the view its subject returns after its header drops the temporary `{s}` it points into; bind `{s}` to a name first", .{ temp, temp });
                break;
            };
        };
        try self.dropStmtTemps(drops);
        var outlived = false;
        // A payload binding holds its own loan on the matched place, so
        // the view of the subject ends with the bindings, not the match.
        if (lent and info.root != null) self.temps.shrinkRetainingCapacity(@min(scrut_temps, self.temps.items.len));
        // The match reads its subject again after a guard runs, to test
        // the next arm's pattern: what the subject views stays lent while
        // the arm is chosen, through every guard. (An arm's bindings hold
        // their own loans on it.)
        var held: std.ArrayList(Loan) = .empty;
        for (scrut_value.loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) == null) try held.append(self.arena(), l);
        const hold = try self.addVar(.{ .name = "", .decl = self.startOf(scrut), .kind = .hidden }, .{ .loans = held.items });

        const base = try self.here();
        // The state an arm starts from: the entry state joined with what
        // each failed guard before it left.
        var start = stateAt(base);
        var acc: ?State = null;
        var value: Value = .{};
        var catch_all = false;
        const arms = ir.Match.arms(match);
        for (arms, 0..) |arm, i| {
            const pattern = ir.Arm.pattern(arm);
            const guard = ir.Arm.guard(arm);
            const body = ir.Arm.body(arm);
            try self.apply(start);
            try self.pushScopeFor(.block, arm);
            self.arm_var = null;
            self.arm_subject = self.spanText(scrut);
            self.arm_take = self.takeableSubject(scrut);
            // A guarded arm may not run for the values its pattern
            // matches. The views the guard takes end with it.
            const bound = self.vars.items.len;
            if (try self.bindPattern(pattern, info, scrut_value) and guard == .nil) catch_all = true;
            // A binding that views a temporary the subject made would
            // outlive it.
            if (!outlived) for (bound..self.vars.items.len) |id| {
                for (self.flows.items[id].loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null and self.holderLive(@intCast(id), null)) {
                    try self.reportTempOutlived(l, @intCast(id));
                    outlived = true;
                    break;
                };
                if (outlived) break;
            };
            var failed: ?State = null;
            if (guard != .nil) {
                // A header, its own statement.
                try self.walkStmt(guard);
                // A failing guard goes on to the next arm, or past the match.
                failed = try self.exitTo(.{ .to = base, .resume_at = resumeAt(if (i + 1 < arms.len) arms[i + 1] else .nil, match) });
            }
            // The arm is chosen: the subject is read no more.
            if (self.flows.items[hold].loans.len > 0) try self.setFlow(hold, .{});
            var v = try self.walkTailPart(body, tail_ctx);
            v = try self.checkValueEscapesScope(v);
            try self.popScope();
            value = try self.valueUnion(value, v);
            const s = try self.leave(base, resumeAt(.nil, match));
            acc = if (acc) |a| try self.join(a, s) else s;
            if (failed) |f| start = try self.join(start, f);
        }
        // Without a catch-all arm, no arm may run.
        if (!catch_all) acc = if (acc) |a| try self.join(a, start) else start;
        try self.apply(acc orelse start);
        if (self.flows.items[hold].loans.len > 0) try self.setFlow(hold, .{});
        // The value the match held ends with it.
        if (header == .held) {
            value = try self.checkValueEscapesScope(value);
            try self.popScope();
        }
        return value;
    }

    /// Bind a pattern's names. Returns true for a catch-all pattern.
    fn bindPattern(self: *Checker, pattern: Sexp, info: Scrutinee, scrut_value: Value) Error!bool {
        switch (pattern) {
            .src => {
                const name = self.text(pattern);
                if (std.mem.eql(u8, name, "_")) return true;
                // Literal patterns match one value; an identifier binds the
                // whole scrutinee and matches everything.
                if (!isIdentStart(name[0]) or std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) return false;
                _ = try self.bindPayload(pattern, info, scrut_value);
                return true;
            },
            .list => {
                if (pattern.isKind(.variant_pattern)) {
                    for (ir.VariantPattern.bindings(pattern)) |b| {
                        if (b == .src and !std.mem.eql(u8, self.text(b), "_")) _ = try self.bindPayload(b, info, scrut_value);
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
        // A payload that copies (`sema.copyable`) is copied out of the
        // matched value, which stays whole. A view the match makes of a
        // field (`match ?e`) views the matched value instead.
        const copied = self.copies(ty) and v.ref == .none;
        // A copy views what the matched value views.
        if (copied and self.mayCarryLoan(ty)) {
            const r_loans: []const Loan = if (info.root) |r| self.flows.items[r].loans else &.{};
            loans = (try self.carry(ty, .{ .loans = try self.unionLoans(scrut_value.loans, r_loans) })).loans;
        } else if (!copied) {
            if (info.root) |r| {
                v.alias_of = r;
                v.alias_path = info.path;
                v.via = info.via;
                // The binding views the matched value: its root stays
                // viewed (lent to write when the view holds a write
                // view, which must not be reached twice), and a viewed
                // root lends what it holds.
                loans = try self.oneLoan(.{ .root = r, .kind = if (self.carriesWriteView(ty)) .write else .read, .pos = pos });
                if (info.via == .viewed) loans = try self.unionLoans(loans, self.flows.items[r].loans);
            } else {
                loans = scrut_value.loans;
            }
        }
        // A read match's binding that is no plain data is usable within
        // its arm only: emit may match a copy of the subject (a guarded
        // match evaluates it first, a generic one reads it as a value), so
        // a view of the binding never outlives the arm (docs/INTERNALS.md,
        // "Header subjects").
        if (self.sema) |ctx| if (ctx.symbolAt(pos)) |sym| if (ctx.symbols.items[sym].flags.arm_view) {
            const arm = self.arm_var orelse blk: {
                const id = try self.addVar(.{ .name = "", .decl = pos, .kind = .hidden, .arm_of = self.arm_subject, .arm_take = self.arm_take }, .{});
                self.arm_var = id;
                break :blk id;
            };
            loans = try self.unionLoans(loans, try self.oneLoan(.{ .root = arm, .kind = .read, .pos = pos }));
        };
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
        /// `while a as x` or `while a as x and ...`: a condition of parts
        /// (`walkConditionParts`).
        cond_binds: bool = false,
        cont: ?Sexp = null,
        body: Sexp,
        /// `for` loops: element bindings and the source loan.
        elem1: Sexp = .nil,
        elem2: Sexp = .nil,
        source_root: ?VarId = null,
        /// `for x in <v`, or a collection the source makes: the loans it
        /// held, which its elements carry.
        moved: []const Loan = &.{},
        source_loan: LoanKind = .read,
        source_pos: u32 = 0,
        resource_vec: bool = false,
        /// The loop walks a collection it does not consume.
        elem_view: bool = false,
    };

    /// A statement that gives a value (`sema.yieldsValue`).
    fn isValue(self: *const Checker, e: Sexp) bool {
        return sema.yieldsValue(self.source, e);
    }

    fn walkWhile(self: *Checker, node: Sexp) Error!Value {
        const cond = ir.While.cond(node);
        const step = ir.While.step(node);
        return self.walkLoop(.{
            .node = node,
            .cond = cond,
            .cond_binds = cond.isKind(.as) or rig.isConditionJoin(cond),
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
        // A bare place is walked as `for x in ?p`, an array made here as
        // `for x in <e`, and a part of a made value in a hidden var the
        // loop holds (docs/INTERNALS.md, "Header subjects").
        const header = self.headerOf(node);
        const saved_held = self.held;
        defer self.held = saved_held;
        if (header == .held) try self.holdBase(node);
        // The source is a header: its temporaries end with it, before
        // the loop walks what it gives.
        const drops = self.stmt_drops.items.len;
        if (mode == .move) {
            spec.moved = (try self.walkMove(source)).loans;
        } else if (header == .taken) {
            spec.moved = (try self.walkConsumed(source, .binding)).loans;
        } else {
            spec.elem_view = true;
            const found = self.errors_found;
            const value = try self.walk(source);
            if (self.headerTempLoan(drops, value)) |l| try self.reportTempOutlived(l, null);
            // The elements of a collection the source makes (an array of
            // views, a call's result) carry the views it holds.
            if (self.resolvePlace(source) == null) spec.moved = value.loans;
            // A source already reported (used while a write loan is live) is
            // not reported again as a conflicting view.
            if (self.errors_found == found) if (self.resolvePlace(source)) |p| {
                const id = p.root;
                const kind: LoanKind = if (mode == .write) .write else .read;
                spec.source_root = id;
                spec.source_loan = kind;
                spec.source_pos = self.startOf(source);
                spec.resource_vec = (mode == .read or header != null) and self.isResourceVec(self.exprType(source));
                if (!self.flowLive(id) or try self.conflicts(id, if (kind == .write) .write else .read, spec.source_pos)) {
                    spec.source_root = null;
                }
            };
        }
        try self.dropStmtTemps(drops);
        var v = try self.walkLoop(spec);
        // The value the loop held ends with it.
        if (header == .held) {
            v = try self.checkValueEscapesScope(v);
            try self.popScope();
        }
        return v;
    }

    /// `(labeled name stmt)`: a labeled loop, or a labeled `match` or
    /// `raw` block, which `break :name` leaves.
    fn walkLabeled(self: *Checker, node: Sexp) Error!Value {
        const label = self.text(ir.Labeled.label(node));
        const stmt = ir.Labeled.stmt(node);
        if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) {
            self.pending_label = label;
            self.pending_reads = self.readsValue(node);
            const v = try self.walk(stmt);
            self.pending_label = "";
            self.pending_reads = false;
            return v;
        }
        var ctx: LoopCtx = .{ .label = label, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .is_loop = false };
        self.loop = &ctx;
        defer self.loop = ctx.parent;
        try self.walkStmt(stmt);
        try self.joinAt(ctx.point, ctx.breaks.items, resumeAt(.nil, node));
        return .{};
    }

    fn walkLoop(self: *Checker, spec: LoopSpec) Error!Value {
        var ctx: LoopCtx = .{ .label = self.pending_label, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .start = extent(spec.node).lo, .reads = self.pending_reads or self.readsValue(spec.node) };
        self.pending_label = "";
        self.pending_reads = false;
        self.loop = &ctx;
        defer self.loop = ctx.parent;
        const entry = ctx.point;

        // The loop head: relative to the entry, the join of the entry, the
        // end of the body, and every `continue`.
        var head = stateAt(entry);
        // Inside another loop's fixpoint nothing is reported, so the last
        // round, which walked the body from the settled head, is the
        // final walk.
        const outer_quiet = self.quiet > 0;
        self.quiet += 1;
        // The join only grows the state, over finitely many variables and
        // loans, so this reaches a fixpoint. The bound is a backstop: a
        // loop the analysis cannot settle is rejected, never accepted.
        var rounds: usize = 0;
        var it: Iteration = undefined;
        const converged = while (rounds < 100_000) : (rounds += 1) {
            try self.apply(head);
            it = try self.loopIteration(spec, &ctx);
            try self.rewind(entry);
            const next = try self.join(head, it.back);
            if (self.statesEql(next, head)) break true;
            head = next;
        } else false;
        self.quiet -= 1;
        if (!converged) try self.errAt(spec.body, "this loop is too complex for the ownership checker; split it into smaller functions", .{});

        if (!outer_quiet or !converged) {
            try self.apply(head);
            it = try self.loopIteration(spec, &ctx);
            try self.rewind(entry);
        }
        try self.apply(it.exit);
        // The `else` runs after the loop: a jump in it leaves the loop
        // around this one. A loop used as a value yields the `else` value
        // or a `break` value.
        self.loop = ctx.parent;
        var value = ctx.value;
        const e = ir.get(spec.node, .@"else");
        if (e != .nil) {
            if (sema.hasValueBreaks(self.source, spec.node)) {
                self.value_reads = ctx.reads;
                value = try self.valueUnion(value, try self.walkStmtValue(e, .brk));
                self.value_reads = false;
            } else try self.walkStmt(e);
        }
        try self.joinAt(ctx.point, ctx.breaks.items, resumeAt(.nil, spec.node));
        return value;
    }

    /// One walk of a loop: the states at the back edge and where the
    /// condition fails, relative to the loop entry.
    const Iteration = struct { back: State, exit: State };

    fn loopIteration(self: *Checker, spec: LoopSpec, ctx: *LoopCtx) Error!Iteration {
        ctx.breaks.clearRetainingCapacity();
        ctx.conts.clearRetainingCapacity();
        ctx.value = .{};
        const depth = self.scopes.items.len;
        // The loop ends when its condition fails: for a binding
        // condition, when a part fails, with the bindings before it gone.
        var exit: State = .{ .reachable = false };
        if (spec.cond_binds) {
            try self.walkConditionParts(spec.cond.?, spec.body);
            // A failing part leaves the loop for its `else`, or past it.
            self.loop = ctx.parent;
            defer self.loop = ctx;
            exit = try self.exitTo(.{ .to = ctx.point, .resume_at = resumeAt(ir.get(spec.node, .@"else"), spec.node) });
        } else {
            if (spec.cond) |c| try self.walkStmt(c);
            if (!spec.cond_always_true) exit = try self.exitTo(.{ .to = ctx.point, .resume_at = resumeAt(ir.get(spec.node, .@"else"), spec.node) });
        }
        try self.pushScopeFor(.block, spec.body);
        try self.bindLoopElems(spec);
        try self.walkStmt(spec.body);
        while (self.scopes.items.len > depth) try self.popScope();

        // A `continue` and the end of the body go back to the loop's
        // head.
        if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items, ctx.start);
        if (spec.cont) |c| try self.walkStmt(c);
        return .{ .back = try self.exitTo(.{ .to = ctx.point, .resume_at = ctx.start }), .exit = exit };
    }

    fn bindLoopElems(self: *Checker, spec: LoopSpec) Error!void {
        var elem_loans: []const Loan = &.{};
        if (spec.source_root) |root| if (self.flowLive(root)) {
            // The source stays lent for the whole loop.
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
                .loop_view = spec.resource_vec,
                .elem_view = spec.elem_view,
                .elem_of = if (elem_loans.len > 0) spec.source_root else null,
            }, .{ .loans = if (self.mayCarryLoan(ty)) try self.unionLoans(elem_loans, spec.moved) else &.{} });
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
        var target = self.loop;
        while (target) |t| : (target = t.parent) {
            if (label.len == 0) {
                if (t.is_loop) break;
            } else if (std.mem.eql(u8, t.label, label)) break;
        }
        // A `break` value leaves the loop like a returned value leaves the
        // function: it is consumed, and it may not view what the loop
        // declared.
        if (target) |t| self.value_reads = t.reads;
        const v: Value = if (value != .nil) try self.walkConsumed(value, .brk) else .{};
        self.value_reads = false;
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
            const s = try self.exitTo(.{ .to = t.point, .exit = .{ .jump = t.scope_depth } });
            switch (jump) {
                .brk => try t.breaks.append(self.arena(), s),
                .cont => try t.conts.append(self.arena(), s),
            }
        }
        self.reachable = false;
    }

    /// `e!` / `e?`: on failure or `none`, control leaves for the caller.
    fn walkPropagate(self: *Checker, node: Sexp) Error!Value {
        const v = try self.walk(ir.get(node, .value));
        if (self.reachable) _ = try self.exitTo(.{ .exit = .{ .propagate = node.isKind(.propagate) } });
        return v;
    }

    /// Whether returning `e` may make the function fail, which runs its
    /// `errdefer`s: `e` is an error, or may be one.
    fn mayFail(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return true;
        const ty = self.exprType(e) orelse return true;
        return switch (ctx.types.get(ty)) {
            .fallible, .any_error, .invalid, .unknown => true,
            else => sema.isErrorSet(ctx, ty),
        };
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
        try self.scopes.items[self.scopes.items.len - 1].defers.append(self.gpa, .{ .body = body, .vars = @intCast(self.vars.items.len), .err_only = node.isKind(.@"errdefer") });
    }

    /// Walk a `defer` body: where it is written (`report_changes`), and
    /// its effects undone; at an exit, where it runs, leaving them to
    /// `exitDefers`.
    fn checkDeferBody(self: *Checker, body: Sexp, report_changes: bool) Error!void {
        const snap = try self.here();
        const saved_loop = self.loop;
        const saved_in_defer = self.in_defer;
        self.loop = null;
        self.in_defer = true;
        try self.walkStmt(body);
        self.loop = saved_loop;
        self.in_defer = saved_in_defer;
        if (!report_changes) return;
        const after = try self.leave(snap, null);
        for (after.changes) |e| {
            if (e.flow.status != self.flows.items[e.id].status) {
                try self.errAt(body, "a `defer` body cannot move or drop `{s}`; it runs when the scope exits", .{self.vars.items[e.id].name});
                break;
            }
        }
    }

    /// Re-check the defers of scope `scope_idx` at an exit, with its
    /// `errdefer`s when the exit `fails`.
    fn runDefers(self: *Checker, scope_idx: usize, fails: bool) Error!void {
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
            try self.checkDeferBody(d.body, false);
        }
    }

    /// Run the defers of the scopes an early exit leaves (every scope at
    /// index `scope_depth` or above, up to the enclosing function), and
    /// check the order their vars are dropped in.
    fn runDefersTo(self: *Checker, scope_depth: usize, fails: bool) Error!void {
        // An exit from inside a deferred body leaves only that body.
        if (self.in_defer) return;
        var si = self.scopes.items.len;
        while (si > scope_depth) {
            si -= 1;
            if (self.scopes.items[si].defers.items.len > 0) try self.runDefers(si, fails);
            if (self.scopes.items[si].kind != .block) break;
        }
        if (si < self.scopes.items.len) try self.checkDropOrder(self.scopes.items[si].start);
    }

    /// Leaving scopes drops vars `>= start`, youngest first. A value whose
    /// drop runs a user `drop` body must not view, directly or through
    /// what it views, a younger value dropped (or out of scope) before
    /// it: the body could read it after.
    fn checkDropOrder(self: *Checker, start: u32) Error!void {
        const ctx = self.sema orelse return;
        const len: u32 = @intCast(self.vars.items.len);
        var reach: std.ArrayList(VarId) = .empty;
        for (start..len) |i| {
            const h = self.vars.items[i];
            if (!self.flowLive(@intCast(i)) or h.alias_of != null or h.loop_view or h.ref != .none) continue;
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
                    if (!glue and self.scopeOf(l.root) == self.scopeOf(@intCast(i))) continue;
                    try self.err(l.pos, "`{s}` is dropped before `{s}`, whose `drop` body could still read it through this view", .{ x.name, h.name });
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

    fn returnMayView(self: *Checker, ret_ty: ?TypeId, returns: Sexp) bool {
        if (sexpMentionsView(returns)) return true;
        if (self.sema == null) return false;
        return ret_ty != null and self.mayCarryLoan(ret_ty);
    }

    fn refOfType(self: *const Checker, ty: ?TypeId) Ref {
        const t = ty orelse return .none;
        return switch (self.typeData(t)) {
            .read_view => .read,
            .write_view => .write,
            else => .none,
        };
    }

    /// The type a view type refers to.
    fn pointee(self: *const Checker, ty: ?TypeId) ?TypeId {
        const t = ty orelse return null;
        return switch (self.typeData(t)) {
            .read_view, .write_view => |inner| inner,
            else => t,
        };
    }

    /// A value copied implicitly where it is used (`sema.copyable`):
    /// not one whose copying depends on a type parameter.
    fn copies(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.copyable(ctx, ty orelse return false) == .yes;
    }

    /// A value read through a write view as the value itself
    /// (`sema.readsAsValue`).
    fn readsAsValue(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.readsAsValue(ctx, ty orelse return false);
    }

    /// A scalar: a number, `Bool`, `String`, or an error. A method call
    /// takes any other receiver by address, so a later argument must
    /// not change it before the call reads it.
    fn isScalar(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return sema.isCopyPrimitive(ctx, t) or ctx.types.get(t) == .any_error;
    }

    /// A `Text`, whose bytes a String may view.
    fn isText(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return t == ctx.types.text_id or sema.boxedType(ctx, t) == ctx.types.text_id;
    }

    /// A `Vec[T]`.
    fn isVec(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ctx.types.get(ty);
        return t == .parameterized_nominal and t.parameterized_nominal.sym == ctx.vec_sym_id;
    }

    /// A Vec (or a view of one) whose elements move (`sema.moves`):
    /// walked by a view of each slot.
    fn isResourceVec(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        const pt = ctx.types.get(sema.unwrapViews(ctx, t));
        if (pt != .parameterized_nominal or pt.parameterized_nominal.sym != ctx.vec_sym_id) return false;
        if (pt.parameterized_nominal.args.len != 1) return false;
        return sema.moves(ctx, pt.parameterized_nominal.args[0]) == .yes;
    }

    /// Values of this type move (`sema.moves`) and cannot be copied
    /// implicitly: null for a value that copies. The kind only chooses
    /// the diagnostic (`kindLabel`).
    fn owningKind(self: *const Checker, ty: ?TypeId) ?Owning {
        const ctx = self.sema orelse return null;
        const t = ty orelse return null;
        return switch (sema.moves(ctx, t)) {
            .no => null,
            .depends => .generic,
            .yes => self.kindLabel(t),
        };
    }

    /// How a diagnostic names the kind of a value that moves.
    fn kindLabel(self: *const Checker, t: TypeId) Owning {
        const ctx = self.sema.?;
        var inner = t;
        while (ctx.types.get(inner) == .optional) inner = ctx.types.get(inner).optional;
        const name = switch (ctx.types.get(inner)) {
            .parameterized_nominal => |pn| ctx.symbols.items[pn.sym].name,
            else => if (sema.nominalDecl(ctx, inner)) |d| d.symbol().name else "value",
        };
        if (!sema.typeHasDropGlue(ctx, t)) {
            // An array of unique values is named by its element.
            var elem = inner;
            while (ctx.types.get(elem) == .array or ctx.types.get(elem) == .optional) elem = switch (ctx.types.get(elem)) {
                .array => |a| a.elem,
                .optional => |o| o,
                else => unreachable,
            };
            return .{ .unique = switch (ctx.types.get(elem)) {
                .parameterized_nominal => |pn| ctx.symbols.items[pn.sym].name,
                else => if (sema.nominalDecl(ctx, elem)) |d| d.symbol().name else "value",
            } };
        }
        return switch (ctx.types.get(inner)) {
            .shared => .shared,
            .weak => .weak,
            .text => .text,
            .parameterized_nominal => |pn| if (pn.sym == ctx.vec_sym_id) .vec else if (pn.sym == ctx.box_sym_id) .box else .{ .drop_glue = name },
            else => .{ .drop_glue = name },
        };
    }

    /// Whether a value of this type can hold a marked view, or a String that
    /// may view a Text. Unknown types are assumed to.
    fn mayCarryLoan(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return true;
        return sema.mayHoldView(ctx, ty orelse return true);
    }

    /// The type a value of type `ty` reaches through its views.
    fn reachedType(self: *const Checker, ty: ?TypeId) ?TypeId {
        const ctx = self.sema orelse return ty;
        return sema.unwrapViews(ctx, ty orelse return null);
    }

    /// Whether a value of this type holds a marked view (a String aside).
    fn holdsMarkedViewType(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return true;
        return sema.holdsMarkedView(ctx, ty);
    }

    /// Whether a value of this type holds a write view, which must not
    /// be duplicated.
    fn carriesWriteView(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.holdsWriteView(ctx, ty orelse return false);
    }

    /// A bracket list of compile-time arguments (`Vec[Int]`, `max[Int]`),
    /// which names a type or a function and holds no value.
    fn isInstance(self: *const Checker, e: Sexp) bool {
        const s = self.sema orelse return false;
        return s.instanceOf(e) != null;
    }

    /// `p.f(...)` where `f` is a data field holding a plain function or
    /// an owned closure (not a method): the call has no receiver
    /// (`storage.hasReceiver`), and neither can keep a view of an
    /// argument in `p`.
    fn callsFunctionField(self: *const Checker, call: Sexp, callee: Sexp) bool {
        const ctx = self.sema orelse return false;
        return !storage.isTypeCallee(ctx, ir.Member.object(callee)) and !storage.hasReceiver(ctx, call);
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
            .write_view => .write,
            .nominal, .parameterized_nominal, .imported_nominal => .value,
            else => .read,
        };
    }

    fn placeText(self: *Checker, e: Sexp) Error![]const u8 {
        switch (e) {
            .src => return self.text(e),
            .list => switch (e.kind() orelse return "expression") {
                .member => return self.arena().print("{s}.{s}", .{ try self.placeText(ir.Member.object(e)), self.text(ir.Member.name(e)) }),
                .index => return self.arena().print("{s}[...]", .{try self.placeText(ir.Index.object(e))}),
                // A sigil: the place it wraps.
                .read, .write, .move, .clone, .share, .weak => return self.placeText(ir.get(e, .operand)),
                // Any other value (`mk()`): as written.
                else => return self.spanText(e),
            },
            else => return "expression",
        }
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// The root name and field names of a field path `a.b.c`, into `out`:
/// its length, or null when the path has an index or anything else.
fn fieldChain(e: Sexp, out: *[16]Sexp) ?usize {
    if (e == .src) {
        out[0] = e;
        return 1;
    }
    if (!e.isKind(.member)) return null;
    const n = fieldChain(ir.Member.object(e), out) orelse return null;
    if (n >= out.len) return null;
    out[n] = ir.Member.name(e);
    return n + 1;
}

fn isLambda(s: Sexp) bool {
    return s.isKind(.lambda);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn loanMatches(l: Loan, root: VarId, q: LoanQuery) bool {
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

fn hasLoanOn(loans: []const Loan, root: VarId) bool {
    for (loans) |l| if (l.root == root) return true;
    return false;
}

fn refOfTypeSexp(t: Sexp) Ref {
    if (t.isKind(.read_view)) return .read;
    if (t.isKind(.write_view)) return .write;
    return .none;
}

fn sexpMentionsView(t: Sexp) bool {
    if (t != .list) return false;
    for (t.items()) |c| {
        if (c == .tag and (c.tag == .read_view or c.tag == .write_view)) return true;
        if (sexpMentionsView(c)) return true;
    }
    return false;
}

/// Where a path that skips the rest of `node` goes on: at `next`, a
/// later part of it, or else past its end.
fn resumeAt(next: Sexp, node: Sexp) u32 {
    const past = extent(node).hi +| 1;
    return if (next == .nil) past else @min(extent(next).lo, past);
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
// as owning and possibly lending)
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
            if (d.severity == .@"error" and std.mem.find(u8, d.message, needle) != null) return true;
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
        \\  send(<packet)
        \\  log(?packet)
        \\
    , "use of `packet` after move");
}

test "hello passes" {
    try expectClean(
        \\sub main()
        \\  print("hello")
        \\
    );
}

test "fixed binding cannot be reassigned" {
    try expectError(
        \\sub main()
        \\  const user = make()
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

test "a temporary read lend's loan ends at statement end" {
    try expectClean(
        \\sub main()
        \\  user = make_user()
        \\  print(?user)
        \\  rename(!user)
        \\
    );
}

test "a bound view blocks a write" {
    try expectError(
        \\sub main()
        \\  user = make_user()
        \\  r = ?user
        \\  rename(!user)
        \\
    , "cannot lend `user` to write while a read loan is live");
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

test "a view may not outlive an inner scope" {
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

test "a view chosen by if keeps both roots lent" {
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
    , "cannot drop `b` while it is lent");
}

test "a view returned from a call views the argument" {
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
    , "cannot drop `h` while it is lent");
}

test "a returned view of a local is rejected" {
    try expectError(
        \\fun bad() -> ?User
        \\  user = make()
        \\  ?user
        \\
    , "cannot return a view of `user`, which this function was not lent");
}

test "a returned view of a view parameter is fine" {
    try expectClean(
        \\fun first(a: ?User, b: ?User) -> ?User
        \\  if pick()
        \\    a
        \\  else
        \\    b
        \\
    );
}

test "a method receiver is lent for the whole call" {
    try expectError(
        \\sub main()
        \\  rc = make()
        \\  rc.show(<rc)
        \\
    , "cannot move `rc` while a read loan is live");
}

test "dropping a view parameter is rejected" {
    try expectError(
        \\sub kill(rc: ?Wrap)
        \\  -rc
        \\
    , "cannot drop view parameter `rc`");
}

test "move-capturing a view parameter is rejected" {
    try expectError(
        \\sub f(rc: ?Wrap)
        \\  g = |<rc|
        \\    look(rc)
        \\  g()
        \\
    , "cannot move-capture view parameter `rc`");
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

test "a view parameter may store views the caller passed in" {
    try expectClean(
        \\sub put(v: !View, b: ?Wrap)
        \\  v.box = b
        \\  fill(!v, b)
        \\
    );
    try expectError(
        \\sub put(v: !View)
        \\  b = make()
        \\  fill(!v, ?b)
        \\
    , "cannot let this call store a view of `b` in `v`");
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
