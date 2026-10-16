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
//! * A `Loan` is a read or write view of a place: a root var and the
//!   path of fields below it (`resolvePlace`, `Paths`), so `p.a` and
//!   `p.b` are lent apart, and two places conflict when one path is a
//!   prefix of the other. Loans travel with values: `r = ?a` stores a
//!   read loan on `a` in `r`; `View(box: ?a)` carries it into the
//!   struct. A call passes on only the loans its signature shows (Core
//!   sentence 7): its result carries the loans of
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
//! * A `?String` is a view: one taken from a String (`?t[a..b]`) views it,
//!   and any value whose type holds a `?String` carries loans as a view
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
//!   place; write views exclude every other use. A value never holds a
//!   view of itself: a store of a loan on a part of a var into that var
//!   is rejected. A method call views
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
//! * Values that own resources (`*T`, `~T`, `List[T]`, anything with drop
//!   glue) cannot be copied implicitly. In a consuming position (binding,
//!   argument, field, return, the branches of an `if`/`match` in such a
//!   position) a place expression of such a type must be written `<x` or
//!   `+x`; only a bare name returned directly moves implicitly. A value
//!   holding a write view cannot be copied either, except as a call
//!   argument (which lends it on for the call).
//! * `<` always leaves its source done (`MoveSource`): `<x` ends a
//!   binding, and `<p.f` or `<v[i]` of an optional empties it to `none`.
//!   Any other field or element (`<p.a`, `<v[0]`) is rejected: one that
//!   copies would stay as it was, and of one that moves a viewed or
//!   shared parent still owns it, or an owned parent would drop it
//!   again. A module's constant lives for the whole program.
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

/// The part of a var a place names: the fields after the name (Core §5,
/// "A field is a place of its own"), decided by `resolvePlace` and kept
/// interned in `Paths`. `whole_path` is the var itself.
const PathId = u32;
const whole_path: PathId = 0;

/// The paths of the places the checker has met: a trie of fields, so a
/// path is a number and its prefixes are its ancestors.
const Paths = struct {
    /// The path `i + 1`: its parent and its last field.
    nodes: std.ArrayList(Node) = .empty,
    index: std.HashMapUnmanaged(Key, PathId, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Each field step's path, by its node: decided by syntax and types
    /// alone, so `resolvePlace` classifies a step once (`extendsPath`).
    steps: std.AutoHashMapUnmanaged(u32, Step) = .empty,

    const Step = struct { path: PathId, ended: bool };

    /// A path is cut at this many fields, which only adds conflicts.
    const max_depth = 8;

    const Node = struct { parent: PathId, field: []const u8, depth: u8 };
    const Key = struct { parent: PathId, field: []const u8 };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h = std.hash.Wyhash.init(k.parent);
            h.update(k.field);
            return h.final();
        }
        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.parent == b.parent and std.mem.eql(u8, a.field, b.field);
        }
    };

    fn deinit(self: *Paths, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.index.deinit(gpa);
        self.steps.deinit(gpa);
    }

    /// The path `parent` and then `field`.
    fn child(self: *Paths, gpa: std.mem.Allocator, parent: PathId, field: []const u8) Error!PathId {
        const gop = try self.index.getOrPut(gpa, .{ .parent = parent, .field = field });
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.index.removeByPtr(gop.key_ptr);
        try self.nodes.append(gpa, .{ .parent = parent, .field = field, .depth = self.depth(parent) + 1 });
        gop.value_ptr.* = @intCast(self.nodes.items.len);
        return gop.value_ptr.*;
    }

    fn depth(self: *const Paths, p: PathId) u8 {
        return if (p == whole_path) 0 else self.nodes.items[p - 1].depth;
    }

    /// Two places of one var conflict when one path is a prefix of the
    /// other (Core sentence 5): `p` and `p.a`, `p.a` and `p.a.b`, but not
    /// `p.a` and `p.b`.
    fn overlap(self: *const Paths, a: PathId, b: PathId) bool {
        var x = a;
        var y = b;
        while (self.depth(x) > self.depth(y)) x = self.nodes.items[x - 1].parent;
        while (self.depth(y) > self.depth(x)) y = self.nodes.items[y - 1].parent;
        return x == y;
    }

    /// Append the fields of path `p`, each after a `.`, to `out`.
    fn appendText(self: *const Paths, a: std.mem.Allocator, out: *std.ArrayList(u8), p: PathId) Error!void {
        if (p == whole_path) return;
        const n = self.nodes.items[p - 1];
        try self.appendText(a, out, n.parent);
        try out.append(a, '.');
        try out.appendSlice(a, n.field);
    }
};

/// What reads a value in place before the operands after it run: a call
/// argument, a method's receiver, the value a call calls, the left
/// operand of a binary operator, or a value that is no place being
/// indexed (see `holdRead`).
const Reader = enum(u3) { none, argument, receiver, callee, operand, base };

const Loan = struct {
    root: VarId,
    /// The place of the root the loan is on (`resolvePlace`).
    path: PathId = whole_path,
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
    /// A write receiver's lend, a read loan until its call starts (Core
    /// §6), for diagnostics.
    reserved: bool = false,

    fn sameAs(a: Loan, b: Loan) bool {
        return a.root == b.root and a.path == b.path and a.kind == b.kind and a.ext == b.ext and a.frame == b.frame;
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
    /// Element of `for x in ?list` over a resource List: a view of
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
    /// A match payload binding that does not own what it binds
    /// (`bindPayload`): the match reads or writes its subject rather
    /// than taking it, and the binding is no copy. It views the var
    /// `alias_of`, or a value no var holds (`matched`).
    payload_view: bool = false,
    /// Match payload binding: the var the scrutinee is, or is a field
    /// of, and the field's path (empty for the whole var).
    alias_of: ?VarId = null,
    alias_path: []const u8 = "",
    /// A `payload_view` binding with no `alias_of`: the subject as
    /// written (`get(o)`, `a if c else b`).
    matched: []const u8 = "",
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
    /// The parameters whose loans reached a value of a type parameter's
    /// type, which carries no loan in a generic body (`taintGeneric`),
    /// and where the body first returns such a value.
    generic: sema.ParamMask = 0,
    generic_returned_at: ?u32 = null,
    /// The name of the parameter each was first stored in.
    stored_in: [@bitSizeOf(sema.ParamMask)][]const u8 = @splat(""),
    /// Where the body first stores a value of a type parameter's type in
    /// what each parameter leads to, past the parameter itself
    /// (`noteGenericStore`).
    generic_stores: [4]GenericStore = undefined,
    generic_store_count: u8 = 0,
    /// The run-time parameters bound so far.
    params: u32 = 0,
    /// Binding run-time parameters (`bindParam`), which get an index.
    binding_params: bool = false,
};

/// `e` without a lend or move sigil written on it.
fn unsigiled(e: Sexp) Sexp {
    return if (e.isKind(.write) or e.isKind(.read) or e.isKind(.move)) ir.get(e, .operand) else e;
}

/// A store in a generic body, of a value whose type mentions a type
/// parameter, in what parameter `param` leads to.
const GenericStore = struct { param: u8, pos: u32, name: []const u8 };

/// A loop, or a labeled block, that `break` / `continue` can leave.
const LoopCtx = struct {
    /// The construct a jump's `JumpDest` names: the `while` or `for`, or
    /// a labeled block's `match` or `raw` block.
    node: Sexp,
    /// The state at loop entry; `breaks` and `conts` are relative to it.
    /// Its var count is the number of vars in scope at loop entry.
    point: Point,
    /// Number of scopes open at loop entry.
    scope_depth: usize,
    breaks: std.ArrayList(State) = .empty,
    conts: std.ArrayList(State) = .empty,
    /// While the body of a `while` whose step runs after it is walked
    /// (`storage.StepPoint.after_body`): the state after the bindings,
    /// with `step_depth` scopes open, where a `continue` to the step goes.
    /// `step_conts` are relative to it.
    step_point: ?Point = null,
    step_depth: usize = 0,
    step_conts: std.ArrayList(State) = .empty,
    /// The loans of the values `break` gives a loop used as a value.
    value: Value = .{},
    parent: ?*LoopCtx,
    /// False for a labeled block: only `break @label` leaves it.
    is_loop: bool = true,
    /// Source position where the loop starts: code from here on may run
    /// again in the next iteration.
    start: u32 = 0,
    /// Its value is read through (`SemContext.readsThrough`), so a
    /// `break` value that is a view of a Copy value is copied.
    reads: bool = false,
};

/// A symbol an assignment's target reads, used after its value
/// (`Checker.after_value`), and the loop around the assignment.
const AfterValue = struct { sym: SymbolId, loop: ?*LoopCtx };

/// Where a value is being consumed, for alias diagnostics.
const Sink = enum {
    binding,
    argument,
    field,
    element,
    allocation,
    box,
    ret,
    brk,

    fn text(s: Sink) []const u8 {
        return switch (s) {
            .binding => "binding",
            .argument => "call argument",
            .field => "field assignment",
            .element => "array element",
            .allocation => "shared allocation",
            .box => "box",
            .ret => "return value",
            .brk => "`break` value",
        };
    }
};

/// Why `<` cannot leave a part that copies done (`MoveSource.part`).
const part_copies_rule = "cannot move out of `{s}`: it copies, so `<` would leave it as it was; remove the `<` to copy it";
/// Why a module's constant cannot be moved or dropped.
const module_level_rule = "cannot {s} module-level `{s}` inside a function; later calls would still use it";
/// Why a loop view cannot leave its slot, for diagnostics.
const loop_view_rule = "a `for x in ?list` element is a read view of the List slot and cannot be cloned, moved, dropped, or stored";

/// Owning kinds that cannot be copied implicitly.
const Owning = union(enum) {
    shared,
    weak,
    list,
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
    /// The paths of the places met so far (`resolvePlace`), shared by
    /// every function the checker walks.
    paths: *Paths,
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
    /// The place `walkMember` is reading: its base (the root's name, or
    /// a header's held value) and its path. Reading that base there reads
    /// only that place (`takePlaceRead`), whose path is decided only where
    /// a write loan on the root could conflict (`checkReadable`).
    place_read: ?struct { base: Sexp, place: Sexp } = null,
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
    /// While a `while` loop's step is walked: where it runs, after the
    /// body (`stepAt`), which stands for the step's statements in
    /// `last_use` and in the liveness checks.
    step_at: ?u32 = null,
    scopes: std.ArrayList(Scope) = .empty,
    /// What the targets of the assignments whose values are being walked
    /// read. An assignment is `{ __v = value; place op= __v }`, so its
    /// target is used after the whole value, every statement and scope
    /// in it included: while the value is walked, these symbols are
    /// live (`holderLive`), each with the loop around its assignment, so
    /// a jump out of the assignment, which never reaches the target,
    /// leaves them behind (`walkJump`).
    after_value: std.ArrayList(AfterValue) = .empty,
    /// Loans taken by the current statement and not stored in a var.
    temps: std.ArrayList(Loan) = .empty,
    /// The hidden vars holding the owning temporaries of the statements
    /// being walked (`sema.dropsTemp`), each with its position: dropped
    /// when its statement ends.
    stmt_drops: std.ArrayList(struct { id: VarId, pos: u32 }) = .empty,
    /// The hidden vars made, before the scope a `catch` handler opens,
    /// for the statement temporaries it makes (`holdPartTemps`), by node:
    /// `holdTemp` holds each there.
    part_temps: std.AutoHashMapUnmanaged(u32, VarId) = .empty,
    /// The lends a call kept because its callee's `keeps` names their
    /// parameter, by where each was lent: what a conflict's note says
    /// (`noteLoan`).
    kept_lends: std.AutoHashMapUnmanaged(u32, KeptLend) = .empty,
    /// The hidden vars holding what the calls being walked keep in
    /// storage of their own (`holdForCall`): each ends when its call
    /// returns (`endCallHeld`).
    call_held: std.ArrayList(VarId) = .empty,
    reachable: bool = true,
    /// Non-zero while computing a loop fixpoint: diagnostics suppressed.
    quiet: u32 = 0,

    func: FnCtx = .{},
    loop: ?*LoopCtx = null,
    /// The loops around each deferred body being walked, innermost
    /// last: `loop` is null at a deferred body's start, so a jump in it
    /// leaves no loop outside it, but the body runs inside those loops,
    /// so liveness (`liveFrom`) still counts them.
    defer_loops: std.ArrayList(?*LoopCtx) = .empty,
    /// Set immediately before walking a lambda literal that sits in an
    /// allowed position (binding RHS, call callee, lent argument, `*|...|`).
    lambda_ok: bool = false,
    /// The loans each of a call's several results carries, by result
    /// (`callResults`), for the destructure that binds them.
    results_of: ?struct { node: Sexp, parts: []const Value } = null,
    /// The loans the `result_part` being walked takes: its result's.
    part_value: Value = .{},
    /// The binding whose value is being walked, for its diagnostics.
    binding: ?struct { name: []const u8, value: Sexp, rejected: bool = false } = null,
    /// Walking the arguments of a call the type checker rejected.
    in_rejected_call: bool = false,
    /// The call whose arguments are being walked, for the diagnostic of
    /// an argument that would copy a value that moves.
    arg_call: ?Sexp = null,
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
        const paths = try allocator.create(Paths);
        paths.* = .{};
        var c = Checker{
            .gpa = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .fn_arena_state = std.heap.ArenaAllocator.init(allocator),
            .source = source,
            .paths = paths,
        };
        errdefer c.deinit();
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
        self.part_temps.deinit(self.gpa);
        self.kept_lends.deinit(self.gpa);
        self.call_held.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        self.loan_counts.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.last_use.deinit(self.gpa);
        self.defer_used.deinit(self.gpa);
        self.defer_loops.deinit(self.gpa);
        for (self.scopes.items) |*s| s.defers.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
        self.after_value.deinit(self.gpa);
        self.temps.deinit(self.gpa);
        self.reaches.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.gpa.destroy(self.paths);
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

    /// Generic bodies are checked once, for a `T` that may own a resource.
    /// Each instantiation the module makes must fit that: an argument
    /// with drop glue only where the bodies never copy a `T`, no write
    /// view in an argument (a write view is never stored in a value),
    /// and a view only where the body stores no `T` where no loan is
    /// tracked. A method's instance checks its own parameters; its
    /// type's are checked with the receiver's instance.
    fn checkInstantiations(self: *Checker) Error!void {
        const ctx = self.sema orelse return;
        for (ctx.fn_instances.items) |f| {
            const shown = try sema.formatFnInstanceIn(ctx, self.arena(), f.inst);
            for (f.inst.ownParams(), f.inst.ownArgs()) |param, arg| {
                if (self.carriesWriteView(arg)) {
                    const pname = ctx.symbols.items[param].name;
                    try self.err(f.site, "`{s}` cannot use `{s} = {s}`: a write view is never stored inside a value; take `!{s}` in its signature instead", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname });
                    continue;
                }
                try self.checkCopies(f.site, shown, param, arg);
                try self.checkViews(f.site, shown, param, arg);
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
            for (params, 0..) |param, i| {
                if (i >= pn.args.len) break;
                const arg = pn.args[i];
                const pname = ctx.symbols.items[param].name;
                const aname = try sema.formatTypeIn(ctx, self.arena(), arg);
                if (self.carriesWriteView(arg)) {
                    try self.err(site, "`{s}` cannot use `{s} = {s}`: a write view is never stored inside a value", .{ shown, pname, aname });
                    continue;
                }
                try self.checkCopies(site, shown, param, arg);
                try self.checkViews(site, shown, param, arg);
            }
        }
    }

    /// An instance whose argument for `param` holds a view, or a `?String`,
    /// which may view a String, where a generic body stores a `param`
    /// where no loan is tracked.
    fn checkViews(self: *Checker, site: u32, shown: []const u8, param: SymbolId, arg: TypeId) Error!void {
        const ctx = self.sema orelse return;
        if (!self.mayCarryLoan(arg)) return;
        const pname = ctx.symbols.items[param].name;
        for (self.plain_reqs.items) |r| {
            if (r.param != param or !r.view) continue;
            const why = if (sema.holdsMarkedView(ctx, arg)) "a view keeps what it views lent" else "a `?String` may view a String (a `Static` carries no loan)";
            try self.err(site, "`{s}` cannot use `{s} = {s}`: the generic body stores a `{s}` in a Cell, a Signal, or an owned closure, which carries no loan, and {s}", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, why });
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

    /// What to write for a parameter that only ever gets literal text and
    /// is stored where no loan is tracked: the loan `l` is the parameter's
    /// own (`ext`), and a `Static` has none.
    fn staticParamHint(l: Loan) []const u8 {
        return if (l.ext) "; if it is only passed literal text, declare the parameter `Static`, which carries no loan" else "";
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
        return rig.leafSpan(self.source, node);
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
        // Deferred code runs after the code that follows it, and a
        // loop's step after its body.
        if (self.loop != null and f.at >= (self.step_at orelse use_pos) and !self.in_defer) {
            try self.note(f.at, "`{s}` was {s} here, in a previous iteration of the loop", .{ v.name, what });
        } else {
            try self.note(f.at, "`{s}` was {s} here", .{ v.name, what });
        }
    }

    fn noteLoan(self: *Checker, loan: Loan) Error!void {
        if (self.quiet > 0 or !self.last_err_kept) return;
        const lent = try self.pathText(loan.root, loan.path);
        if (loan.place_hold) {
            try self.note(loan.pos, "`{s}` is lent here, and the place is found up to each index before the index runs", .{lent});
        } else if (loan.held_read != .none) {
            const uses = switch (loan.held_read) {
                .none, .argument => "the call uses it after its later arguments run",
                .receiver => "the call uses it as the receiver after its arguments run",
                .callee => "the call runs it after its arguments run",
                .operand => "the operator uses it after its right operand runs",
                .base => "it is indexed after its index runs",
            };
            try self.note(loan.pos, "`{s}` read here: the value shares its storage, and {s}", .{ lent, uses });
        } else if (loan.reserved) {
            try self.note(loan.pos, "`{s}` lent to write here, as the receiver, which is read until the call starts", .{lent});
        } else if (loan.read_of_write) {
            try self.note(loan.pos, "`{s}` lent to write here, and kept lent to read by a view that only reads it", .{lent});
        } else if (self.kept_lends.get(loan.pos)) |k| {
            try self.note(loan.pos, "`{s}` lent to {s} here, and `{s}` keeps it in `{s}` (its signature says `keeps {s}`), so the loan lasts while `{s}` is used", .{ lent, @tagName(loan.kind), k.callee, k.holder, k.param, k.holder });
        } else try self.note(loan.pos, "`{s}` lent to {s} here", .{ lent, @tagName(loan.kind) });
    }

    /// How a message names the place loan `l` is on, after a use of
    /// place `path` of the same var: nothing when it is that place, and
    /// ` on `p.a`` when one holds the other.
    fn loanOnText(self: *Checker, l: Loan, path: PathId) Error![]const u8 {
        if (l.path == path) return "";
        return self.arena().print(" on `{s}`", .{try self.pathText(l.root, l.path)});
    }

    /// How a message names what loan `l` is on, after a use of place
    /// `path` of the same var: `it`, or the place `l` is on where that is
    /// another.
    fn lentText(self: *Checker, l: Loan, path: PathId) Error![]const u8 {
        if (l.path == path) return "it";
        return self.arena().print("`{s}`", .{try self.pathText(l.root, l.path)});
    }

    /// A lend a call kept (`kept_lends`): the callee, the parameter its
    /// `keeps` names, and the var the call stored it in.
    const KeptLend = struct { callee: []const u8, param: []const u8, holder: []const u8 };

    /// Note the lends in `v`, which call `node` keeps through `param`, as
    /// kept in what its write receiver or arguments lead to.
    fn noteKept(self: *Checker, callee: Sexp, v: Value, param: []const u8, write_recv: ?VarId, arg_values: []const Value) Error!void {
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
            try self.kept_lends.put(self.gpa, l.pos, .{ .callee = name, .param = param, .holder = self.vars.items[h].name });
        }
    }

    /// The end of a conflict's message for a read held in place: what
    /// holds it, and of what (`it`, or the place it reads).
    fn heldReadClause(self: *Checker, reader: Reader, of: []const u8) Error![]const u8 {
        const who = switch (reader) {
            .none, .argument => "an earlier argument's",
            .receiver => "the receiver's",
            .callee => "the callee's",
            .operand => "the left operand's",
            .base => "the indexed value's",
        };
        return self.arena().print("while {s} read of {s} is in use", .{ who, of });
    }

    /// What is done to a var, for a loan conflict.
    const Access = union(enum) {
        read,
        write,
        /// Moving it (the verb: "move", "move-capture").
        consume: []const u8,
    };

    /// Report a live loan on place `path` of var `id` that `access` at
    /// `pos` conflicts with: a read lend conflicts with a write loan,
    /// anything else with every loan. Returns whether there was one.
    fn conflicts(self: *Checker, id: VarId, path: PathId, access: Access, pos: u32) Error!bool {
        return try self.conflictingLoan(id, path, access, pos) != null;
    }

    /// `conflicts`, giving the loan it reported.
    fn conflictingLoan(self: *Checker, id: VarId, path: PathId, access: Access, pos: u32) Error!?Loan {
        const l = self.findLoan(id, path, if (access == .read) .write else .any, null) orelse return null;
        // Diagnostics name both places: the one used, and the one lent
        // where it is not the same.
        const name = try self.pathText(id, path);
        const on = try self.loanOnText(l, path);
        const lent = try self.lentText(l, path);
        const in_index = if (l.path == path) "in an index of a place it is lending" else try self.arena().print("in an index of {s}, a place being lent", .{lent});
        const held = try self.heldReadClause(l.held_read, lent);
        switch (access) {
            .read => try self.err(pos, "cannot lend `{s}` to read while a write loan{s} is live", .{ name, on }),
            .write => if (l.place_hold)
                try self.err(pos, "cannot lend `{s}` to write {s}", .{ name, in_index })
            else if (l.held_read != .none)
                try self.err(pos, "cannot lend `{s}` to write {s}", .{ name, held })
            else switch (l.kind) {
                .read => try self.err(pos, "cannot lend `{s}` to write while a read loan{s} is live", .{ name, on }),
                .write => try self.err(pos, "cannot lend `{s}` to write while a write loan{s} is live", .{ name, on }),
            },
            .consume => |verb| if (l.place_hold)
                try self.err(pos, "cannot {s} `{s}` {s}", .{ verb, name, in_index })
            else if (l.held_read != .none)
                try self.err(pos, "cannot {s} `{s}` {s}", .{ verb, name, held })
            else
                try self.err(pos, "cannot {s} `{s}` while a {s} loan{s} is live", .{ verb, name, @tagName(l.kind), on }),
        }
        try self.noteLoan(l);
        if (access != .read and l.held_read == .callee) try self.noteCloneCallee(l.pos);
        return l;
    }

    /// The fix for a call that lends all of `recv` (place `path` of var
    /// `id`) to write while loan `l` is on a part of it: a method lends
    /// all of its receiver (Core §5), so lend only the fields it writes.
    fn noteWholeReceiver(self: *Checker, id: VarId, path: PathId, l: Loan, callee: Sexp, pos: u32) Error!void {
        if (self.paths.depth(l.path) <= self.paths.depth(path)) return;
        const recv = try self.pathText(id, path);
        const method = self.text(ir.Member.name(callee));
        try self.note(pos, "the call lends all of `{s}`: lend the fields it writes, `(!{s}.field).method(...)`, or make `{s}` a function of those fields", .{ recv, recv, method });
    }

    /// The fix for a call of an owned closure held in what the call
    /// writes or moves: a handle of its own keeps the closure alive
    /// whatever the call does to its holder (Core §7).
    fn noteCloneCallee(self: *Checker, pos: u32) Error!void {
        const ctx = self.sema orelse return;
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
    fn callWithCalleeAt(self: *const Checker, node: Sexp, pos: u32) ?Sexp {
        if (node != .list) return null;
        if (node.isKind(.call)) if (self.sema) |ctx| {
            if (self.startOf(ctx.calleeOf(node)) == pos) return node;
        };
        for (node.items()) |c| if (self.callWithCalleeAt(c, pos)) |found| return found;
        return null;
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
                return self.noteStringViewOfString(l, hv.ty);
            }
        }
        try self.note(root.decl, "`{s}` goes out of scope while it is still lent", .{root.name});
    }

    /// Where loan `l` of a String outlives the String in a value of type
    /// `held` whose only views are Strings (a `?String` field or result):
    /// the `?String` was meant to own its text.
    fn noteStringViewOfString(self: *Checker, l: Loan, held: ?TypeId) Error!void {
        const ctx = self.sema orelse return;
        const t = held orelse return;
        if (!self.isString(self.vars.items[l.root].ty) or !sema.holdsViewOnly(ctx, t)) return;
        try self.note(l.pos, "a `?String` views text it doesn't own; store a `String` to own it", .{});
    }

    /// A view of a read match's binding `l` names, kept past its arm.
    /// The hint offers a clone only of a binding that has one, and a
    /// take only of a subject that is an owner's name, so each form it
    /// names compiles.
    fn reportArmView(self: *Checker, l: Loan) Error!void {
        var end = l.pos;
        while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_')) end += 1;
        const name = diag.textBetween(self.source, l.pos, end);
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
        const name = self.vars.items[l.root].name;
        // A temporary made before it in the statement is dropped after
        // it, so holds the view past the temporary's drop.
        if (holder) |h| if (self.isStmtTemp(h) and self.vars.items[h].name.len > 0) {
            const hv = self.vars.items[h];
            try self.err(l.pos, "a view of the temporary `{s}` is held by `{s}`, a temporary its statement drops after it; bind the value to a name first", .{ name, hv.name });
            if (self.last_err_kept) try self.note(hv.decl, "`{s}` is made before `{s}`, so dropped after it", .{ hv.name, name });
            return;
        };
        // A view the statement holds owns nothing it could drop: what
        // it views is held only while the statement runs.
        const is_view = if (self.sema) |ctx| (if (self.vars.items[l.root].ty) |t| sema.isReadOrWriteView(ctx, t) else false) else false;
        if (is_view) {
            try self.err(l.pos, "a view reached through `{s}` outlives its statement, which holds `{s}`, itself a view, only while it runs; bind `{s}` to a name first", .{ name, name, name });
        } else try self.err(l.pos, "a view of the temporary `{s}` outlives its statement, which drops it; bind the value to a name first", .{name});
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
            if (self.holderLive(holder, self.stmtEnd())) try self.reportTempOutlived(l, holder);
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
        var s = try self.capture(to);
        // A jump leaves the statements it is in, which end there: the
        // loans they took and keep for their own ends (`temps`) do not go
        // on with it; the point it goes to has its own.
        if (x.exit) |e| if (e == .jump) {
            s.temps = to.temps;
        };
        return s;
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

    /// A live, non-external loan on a place of `root` that overlaps
    /// `path` (`Paths.overlap`), held by a var or a temporary. Vars that
    /// view `skip_alias_of` (payload bindings of that scrutinee) are
    /// ignored.
    fn findLoan(self: *Checker, root: VarId, path: PathId, q: LoanQuery, skip_alias_of: ?VarId) ?Loan {
        if (self.isLent(root)) for (self.flows.items, self.vars.items, 0..) |f, v, holder| {
            if (skip_alias_of != null and v.alias_of == skip_alias_of) continue;
            for (f.loans) |l| if (self.loanMatches(l, root, path, q)) {
                if (self.holderLive(@intCast(holder), null)) return l;
                break;
            };
        };
        for (self.temps.items) |l| if (self.loanMatches(l, root, path, q)) return l;
        return null;
    }

    /// Whether `l` is a loan `q` asks for on a place of `root` that
    /// overlaps `path`. Only this compares paths.
    fn loanMatches(self: *const Checker, l: Loan, root: VarId, path: PathId, q: LoanQuery) bool {
        return l.root == root and !l.ext and (q == .any or l.kind == .write) and self.paths.overlap(l.path, path);
    }

    // -------------------------------------------------------------------------
    // Liveness: a view ends at its last use
    // -------------------------------------------------------------------------

    /// Record the last use of every symbol in `e` (a function's parameters
    /// and body), and the symbols deferred code uses. A capture's own
    /// leaf is also a use of the binding it captures. A `while` loop's
    /// step runs after the body, so its uses count there (`stepAt`), or
    /// at `at` when `e` is in a step already. (An assignment's target is
    /// used after its value, which `after_value` records as the value is
    /// walked.)
    fn indexUses(self: *Checker, e: Sexp, in_defer: bool, at: ?u32) Error!void {
        switch (e) {
            .src => |s| {
                const ctx = self.sema orelse return;
                const sym = ctx.symbolOf(e) orelse return;
                try self.noteUse(sym, at orelse s.pos, in_defer);
                const d = ctx.symbols.items[sym];
                if (d.kind == .capture and d.decl_pos == s.pos and d.origin != sema.symbol_invalid) {
                    try self.noteUse(d.origin, at orelse s.pos, in_defer);
                }
            },
            .list => {
                const deferred = in_defer or e.isKind(.@"defer") or e.isKind(.@"errdefer");
                for (e.items()) |c| {
                    const step_at = if (sema.isWhileStep(e, c)) at orelse stepAt(e) else at;
                    try self.indexUses(c, deferred, step_at);
                }
            },
            else => {},
        }
    }

    fn noteUse(self: *Checker, sym: SymbolId, pos: u32, in_defer: bool) Error!void {
        const gop = try self.last_use.getOrPut(self.gpa, sym);
        if (!gop.found_existing or gop.value_ptr.* < pos) gop.value_ptr.* = pos;
        if (in_defer) try self.defer_used.put(self.gpa, sym, {});
    }

    /// Whether `holder` still uses what it views once a statement's
    /// temporary it views is dropped there. A temporary of the same
    /// statement, dropped after it, uses its views as any owner's drop
    /// does, only through a `drop` body (Core sentence 6), or through a
    /// live value that views it; any other holder as `holderLive` says.
    fn holdsPastDrop(self: *const Checker, holder: VarId) bool {
        return self.holdsPastDropDepth(holder, 0);
    }

    fn holdsPastDropDepth(self: *const Checker, holder: VarId, depth: u8) bool {
        if (!self.isStmtTemp(holder) or depth > 16) return self.holderLive(holder, null);
        const ctx = self.sema orelse return true;
        const ty = self.vars.items[holder].ty orelse return true;
        if (sema.dropRunsBody(ctx, ty) != .no) return true;
        if (self.isLent(holder)) for (self.flows.items, 0..) |f, j| {
            if (j == holder) continue;
            for (f.loans) |l| if (l.root == holder and !l.ext) {
                if (self.holdsPastDropDepth(@intCast(j), depth + 1)) return true;
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
        for (self.after_value.items) |a| if (a.sym == sym) return true;
        const ty = v.ty orelse return true;
        // A var that owns its value drops it at scope exit, which uses
        // its views only through a `drop` body. (A match payload or a
        // viewed loop element only views a value.)
        const owns = !v.payload_view and !v.loop_view and v.ref == .none;
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
    /// enclosing loop the var was declared outside of, one around a
    /// deferred body being walked included (`defer_loops`).
    fn liveFrom(self: *const Checker, decl: u32, at: ?u32) u32 {
        var from: u32 = loopStartFrom(self.loop, decl, at orelse self.stmtStart());
        for (self.defer_loops.items) |outer| from = loopStartFrom(outer, decl, from);
        return from;
    }

    /// `from`, or the start of a loop of the chain from `loop` outward
    /// that starts after `decl`, whichever is earlier.
    fn loopStartFrom(loop: ?*LoopCtx, decl: u32, from: u32) u32 {
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
    fn stmtStart(self: *const Checker) u32 {
        if (self.step_at) |at| return at;
        const ext = extent(self.cur_stmt);
        return if (ext.hi >= ext.lo) ext.lo else self.anchor;
    }

    /// The first position after the current statement.
    fn stmtEnd(self: *const Checker) u32 {
        if (self.step_at) |at| return at +| 1;
        return extent(self.cur_stmt).hi +| 1;
    }

    fn addTemp(self: *Checker, l: Loan) Error!void {
        try self.temps.append(self.gpa, l);
    }

    /// Loans carried by the current value of var `id`.
    fn varValue(self: *Checker, id: VarId) Value {
        const v = self.vars.items[id];
        if (!v.closure and !self.mayCarryLoan(v.ty)) {
            if (self.genericType(v.ty)) {
                // A value of a type parameter's type carries, in an
                // instance, what its binding views (a match payload's
                // view of the matched value), and a parameter taken by
                // value what its caller's argument viewed.
                self.taintGeneric(v.ty, .{ .loans = self.flows.items[id].loans });
                if (v.kind == .param and v.ref == .none) if (v.param_index) |i| {
                    self.func.generic |= sema.paramBit(i);
                };
            }
            return .{};
        }
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
            .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .variant, .@":" => {},
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
            try self.indexUses(params, false, null);
            try self.indexUses(body, false, null);
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
                try self.walkReturnValue(stmt, null);
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
        // itself marks them as returnable and conflict-free. It is a
        // write loan when the param holds a write view, as `!T` or
        // inside an optional (`(!T)?`): whatever unwraps it writes
        // through that loan to what the caller owns (`callerOwns`).
        if (ref != .none or (ty != null and self.mayCarryLoan(ty))) {
            const writes = ref == .write or self.carriesWriteView(ty);
            self.replaceFlow(id, .{ .loans = try self.oneLoan(.{ .root = id, .kind = if (writes) .write else .read, .pos = pos, .ext = true }) });
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
    /// var until its statement ends; what views it views that var. One a
    /// `catch` handler makes is held in the var made for it before the
    /// handler's scope opened (`holdPartTemps`).
    fn holdTemp(self: *Checker, node: Sexp, v: Value) Error!Value {
        const pos = self.startOf(node);
        if (node == .list) if (self.part_temps.fetchRemove(node.list.id)) |kv| if (self.isStmtTempVar(kv.value, pos)) {
            try self.setFlow(kv.value, .{ .loans = v.loans });
            return .{ .loans = try self.oneLoan(.{ .root = kv.value, .kind = .read, .pos = pos }) };
        };
        const id = try self.addVar(.{ .name = self.spanText(node), .decl = pos, .ty = self.exprType(node), .kind = .hidden }, .{ .loans = v.loans });
        try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
        return .{ .loans = try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos }) };
    }

    /// Make the hidden vars for the statement temporaries `part`, a
    /// `catch` handler, makes (`sema.stmtTemps`), before the caller opens
    /// the scope it binds the handler's name in: they are the
    /// statement's, as emit declares their slots for the statement, so
    /// they outlive that scope and end with the statement
    /// (`dropStmtTemps`). Each is made before the state a branch starts
    /// from, so a path that makes it and one that does not join.
    fn holdPartTemps(self: *Checker, part: Sexp) Error!void {
        const ctx = self.sema orelse return;
        var temps: std.ArrayList(Sexp) = .empty;
        try sema.stmtTemps(ctx, self.arena(), part, &temps);
        for (temps.items) |node| {
            const pos = self.startOf(node);
            const id = try self.addVar(.{ .name = self.spanText(node), .decl = pos, .ty = self.exprType(node), .kind = .hidden }, .{});
            try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
            try self.part_temps.put(self.gpa, node.list.id, id);
        }
    }

    /// Whether var `id` is still the hidden var of the statement
    /// temporary at `pos`: one whose scope ended is gone, and its id may
    /// name a newer var.
    fn isStmtTempVar(self: *const Checker, id: VarId, pos: u32) bool {
        if (id >= self.vars.items.len) return false;
        const v = self.vars.items[id];
        return v.kind == .hidden and v.decl == pos;
    }

    /// The hidden var of the live statement temporary at `pos`, if any.
    fn stmtTempAt(self: *const Checker, pos: u32) ?VarId {
        var i = self.stmt_drops.items.len;
        while (i > 0) {
            i -= 1;
            const d = self.stmt_drops.items[i];
            if (d.pos == pos and self.isStmtTempVar(d.id, pos)) return d.id;
        }
        return null;
    }

    /// Drop the temporaries statement-held since `start`: a value that
    /// still views one after the statement would outlive it. One whose
    /// scope already ended (a branch's) was released there.
    fn dropStmtTemps(self: *Checker, start: usize) Error!void {
        var i = self.stmt_drops.items.len;
        while (i > start) {
            i -= 1;
            const d = self.stmt_drops.items[i];
            if (!self.isStmtTempVar(d.id, d.pos)) continue;
            if (self.isLent(d.id)) for (0..self.flows.items.len) |holder| {
                if (holder == d.id) continue;
                var f = self.flows.items[holder];
                var reported = false;
                var kept: std.ArrayList(Loan) = .empty;
                for (f.loans) |l| {
                    if (l.root != d.id) {
                        try kept.append(self.arena(), l);
                    } else if (!reported and self.holdsPastDrop(@intCast(holder))) {
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
            v = try self.walkTailStmt(s, t);
        }
        v = try self.checkValueEscapesScope(v);
        try self.popScope();
        return if (self.reachable) v else .{};
    }

    /// Walk `stmt`, a block's last statement or a `match` arm's body, as
    /// a statement whose value `t`, if any, consumes: its temporaries
    /// end with it, and its tail name moves before the scope's defers
    /// run, as emit takes it there.
    fn walkTailStmt(self: *Checker, stmt: Sexp, t: ?Tail) Error!Value {
        if (t) |ctx| self.markTail(stmt, ctx);
        const v = try self.walkStmtValue(stmt, null);
        if (t) |ctx| {
            self.tail = null;
            if (stmt == .src and self.reachable) try self.consumeTailName(stmt, ctx);
        }
        return v;
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
            try self.checkReadable(h.id, self.takePlaceRead(sexp), self.startOf(sexp));
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
            const temps_start = self.temps.items.len;
            return self.copiedOut(sema.unwrapViews(ctx, ty), temps_start, try self.walkList(sexp, kind));
        };
        return self.walkList(sexp, kind);
    }

    /// `v`, a view walked from `temps_start`, read through for the value
    /// of type `reached` it reaches: a copy of that value. When the value
    /// holds no view, the loans taken to reach it end here. A view read
    /// through a view is a copy of the view: it keeps what the view
    /// keeps, not the view that reached it, and a `?String`'s views end
    /// here but for those it keeps.
    fn copiedOut(self: *Checker, reached: TypeId, temps_start: usize, v: Value) Error!Value {
        const ctx = self.sema orelse return v;
        if (!self.mayCarryLoan(reached)) {
            self.taintGeneric(reached, v);
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        }
        if (sema.holdsViewOnly(ctx, reached)) return self.keepViewTemps(temps_start, try self.carry(reached, v));
        return self.carry(reached, v);
    }

    /// The value `holder`, the operand of `a ?? b` or `a catch b` (`node`),
    /// gives the fallback form: what its payload views, copied out where
    /// `node` copies it (`SemContext.copiesPayload`), else the payload as
    /// it is.
    fn walkPayloadHolder(self: *Checker, node: Sexp, holder: Sexp) Error!Value {
        const ctx = self.sema orelse return self.walk(holder);
        if (!ctx.copiesPayload(node)) return self.walk(holder);
        const temps_start = self.temps.items.len;
        const v = try self.walk(holder);
        const viewed = sema.payloadViewed(ctx, ctx.typeOf(holder) orelse return v) orelse return v;
        return self.copiedOut(viewed, temps_start, v);
    }

    fn walkList(self: *Checker, sexp: Sexp, kind: Tag) Error!Value {
        switch (kind) {
            .fun, .sub, .drop_decl, .@"struct", .@"enum", .errors => try self.walkDecl(sexp),
            .set => try self.walkSet(sexp),
            .destructure => try self.walkDestructure(sexp),
            .drop => try self.walkDrop(sexp),
            .@"return" => try self.walkReturn(sexp),
            .@"break" => try self.walkJump(sexp, .brk),
            .@"continue" => try self.walkJump(sexp, .cont),
            .@"defer", .@"errdefer" => try self.walkDefer(sexp),
            else => return switch (kind) {
                .block => self.walkBlock(sexp),
                .move => self.walkMove(ir.Move.operand(sexp)),
                // A view the type checker rejected lends nothing.
                .read, .write => if (self.rejected(sexp))
                    self.walkRejectedLend(ir.get(sexp, .operand))
                else if (self.lendsElements(sexp))
                    // `?a` lent as `?a[..]`, `!a` as `!a[..]`, `?t` of a
                    // String as `?t[..]`.
                    self.walkElems(sexp, ir.get(sexp, .operand), if (sexp.isKind(.read)) .read else .write)
                else
                    self.walkLend(ir.get(sexp, .operand), if (sexp.isKind(.read)) .read else .write),
                .clone, .weak => self.walkCloneWeak(sexp),
                .share => self.walkShare(sexp),
                .box => self.walkConsumed(ir.Box.operand(sexp), .box),
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
                // A destructure's target takes its result's loans.
                .result_part => self.part_value,
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
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"or", .@"and", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@".." => blk: {
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
        if (!v.payload_view) {
            if ((sink == .ret or id >= t.vars) and !v.closure and !v.loop_view and !v.capture_resource and self.returnMoves(v)) {
                _ = try self.moveVar(id, node.src.pos, .move);
            }
            return;
        }
        const k = self.owningKind(v.ty) orelse return;
        if (k == .generic and v.via != .owned) {
            // A copy for plain data; each instantiation is checked.
            return self.reportAlias(node.src.pos, v.name, .name, k, .binding, v.ty, null);
        }
        _ = try self.movePayload(id, node.src.pos, "move");
    }

    /// A place whose value holds a write view (`w`, or a `(!T)?` name;
    /// no field or element holds one): passing it on lends that view.
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
        try self.checkReadable(id, self.takePlaceRead(node), pos);
        return self.varValue(id);
    }

    /// The place `walkMember` reads from `base`, once: a use touches the
    /// path it names (Core §5). Null, the whole var, for any other read.
    fn takePlaceRead(self: *Checker, base: Sexp) ?Sexp {
        const r = self.place_read orelse return null;
        if (!sameNode(r.base, base)) return null;
        self.place_read = null;
        return r.place;
    }

    /// The node a place's path starts from: its root's name, or a
    /// header's held value.
    fn placeBase(self: *const Checker, e: Sexp) Sexp {
        var base = e;
        while (base.isKind(.member) or base.isKind(.index)) {
            if (self.held) |h| if (base.list.ptr == h.base.list.ptr) break;
            base = ir.get(base, .object);
        }
        return base;
    }

    /// A closure binding used as a value.
    fn errClosureValue(self: *Checker, pos: u32, name: []const u8) Error!void {
        try self.err(pos, "closure `{s}` cannot be moved, returned, stored, or copied; call it as `{s}()`, lend it to a call as `?{s}`, or make the literal owned (`*|...| body`) to pass it around", .{ name, name, name });
    }

    /// `?f` of closure binding `id`: a read loan on the closure, and the
    /// loans its captures hold.
    fn lendClosure(self: *Checker, id: VarId, pos: u32) Error!Value {
        const v = (try self.lendVar(id, whole_path, .read, pos)) orelse return .{};
        return .{ .loans = try self.unionLoans(v.loans, self.flows.items[id].loans) };
    }

    /// Reading `id`, or the place `place` of it: it must be live and not
    /// lent to write. The place's path is decided only where some write
    /// loan on `id` is live.
    fn checkReadable(self: *Checker, id: VarId, place: ?Sexp, pos: u32) Error!void {
        if (!try self.checkLive(id, pos)) return;
        if (self.findLoan(id, whole_path, .write, null) == null) return;
        const path = if (place) |e| (if (self.resolvePlace(e)) |p| (if (p.root == id) p.path else whole_path) else whole_path) else whole_path;
        if (self.findLoan(id, path, .write, null)) |l| {
            try self.err(pos, "use of `{s}` while a write loan{s} is live", .{ try self.pathText(id, path), try self.loanOnText(l, path) });
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
        /// The part of the root the place names: its fields up to the
        /// first step that ends a path (`extendsPath`).
        path: PathId = whole_path,
        /// A step has ended the path: no later field extends it.
        path_ended: bool = false,
        /// Some step goes through an element index.
        indexed: bool = false,
        /// Some step dereferences a shared handle.
        through_shared: bool = false,
        /// Some step goes through a view (a viewed root or a
        /// view-typed field).
        through_view: bool = false,
    };

    /// The var a place (`sema.Hands.Kind.place`) starts from, the path
    /// it names below it, and how it gets there. Null for anything else,
    /// and for a name the closure body did not capture (walking the
    /// expression reports it). The path is decided here and nowhere else:
    /// each loan, use, and store of the place carries it.
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
                    const at_root = p.whole;
                    p.whole = false;
                    if (e.isKind(.index)) p.indexed = true;
                    if (!p.path_ended) {
                        if (self.paths.steps.get(e.list.id)) |step| {
                            p.path = step.path;
                            p.path_ended = step.ended;
                        } else {
                            if (self.paths.depth(p.path) < Paths.max_depth and self.extendsPath(e, at_root)) {
                                // Out of memory, the path is cut where it
                                // is, which only adds conflicts.
                                p.path = self.paths.child(self.gpa, p.path, self.text(ir.Member.name(e))) catch blk: {
                                    p.path_ended = true;
                                    break :blk p.path;
                                };
                            } else p.path_ended = true;
                            self.paths.steps.put(self.gpa, e.list.id, .{ .path = p.path, .ended = p.path_ended }) catch {};
                        }
                    }
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

    /// Whether `e`, a step of a place, goes on the place's path (Core §5,
    /// "A field is a place of its own"): a data field of a struct value,
    /// of a box's value (a box has one owner), or of what the root's own
    /// write view sees (`at_root`: `e`'s object is the root itself). Any
    /// other step ends the path, and a loan is on the path so far: an
    /// element or a slice (an index is a run-time value, and a push may
    /// move the buffer), a handle (other handles reach its contents), a
    /// read view (what it views is its own loans', not the holder's), an
    /// optional's value (it exists only while present), or a member of
    /// anything else.
    fn extendsPath(self: *const Checker, e: Sexp, at_root: bool) bool {
        const ctx = self.sema orelse return false;
        if (!e.isKind(.member)) return false;
        var t = self.exprType(ir.Member.object(e)) orelse return false;
        if (at_root) switch (ctx.types.get(t)) {
            .write_view => |inner| t = inner,
            else => {},
        };
        while (sema.boxedType(ctx, t)) |inner| t = inner;
        switch (ctx.types.get(t)) {
            .nominal, .imported_nominal => {},
            .parameterized_nominal => |pn| if (sema.isBuiltinGeneric(ctx, pn.sym)) return false,
            else => return false,
        }
        return sema.lookupDataFieldConst(ctx, t, self.text(ir.Member.name(e))) != null;
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
    /// before the index runs, so while the indices run, the place's path
    /// `path` of `root` is held read, and an index cannot lend to write or
    /// move it (`!ps[0].a[grow(!ps)]` would write into the buffer `grow`
    /// freed). An assignment finds its target only after its indices run
    /// (`walkFieldAssign`).
    fn walkIndicesHeld(self: *Checker, e: Sexp, root: VarId, path: PathId) Error!void {
        const mark = self.temps.items.len;
        try self.addTemp(.{ .root = root, .path = path, .kind = .read, .pos = self.startOf(e), .place_hold = true });
        try self.walkPlaceIndices(e);
        if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
    }

    /// The indices of place `e`, read or taken, each walked as
    /// `walkIndexOf` walks it.
    fn walkFoundIndices(self: *Checker, e: Sexp) Error!void {
        switch (e.kind() orelse return) {
            .member => try self.walkFoundIndices(ir.Member.object(e)),
            .index => {
                const object = ir.Index.object(e);
                try self.walkFoundIndices(object);
                try self.walkIndexOf(object, ir.Index.index(e));
            },
            else => {},
        }
    }

    /// `index` of place `object`, read or taken: `object` is found before
    /// the index runs (`v.constSlot(0).*.at(i)`). The index may lend the
    /// root to write or move it only where what it reads stays put: the
    /// element is read from an array held inline in `object`, or from a
    /// List's buffer that `at` reads after the index, and `object` lies
    /// in its root's own storage (`staysInRoot`): `vs[grow(!vs)]` finds
    /// `vs` where it was, and reads the element after. Anywhere else (a
    /// List past another List's buffer or a box, a handle, a String) the
    /// root is held read while the index runs: `v[0][grow(!v)]` would read
    /// the buffer `grow` freed, and `h[reh(!h)]` the List a re-pointed
    /// handle let go.
    fn walkIndexOf(self: *Checker, object: Sexp, index: Sexp) Error!void {
        const place = self.resolvePlace(object) orelse {
            _ = try self.walk(index);
            return;
        };
        if (self.readsAfterIndex(object) and self.staysInRoot(object)) {
            _ = try self.walk(index);
            return;
        }
        const mark = self.temps.items.len;
        try self.addTemp(.{ .root = place.root, .path = place.path, .kind = .read, .pos = self.startOf(object), .place_hold = true });
        _ = try self.walk(index);
        if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
    }

    /// Whether an element of place `object` is read where `object` is
    /// found: from an array held inline in it, from a List's buffer,
    /// which `at` reads after the index runs, or, for a root that is a
    /// slice (`xs: ![]T`), from the elements it views, which a lend of
    /// it may write but never move or free. A root is what a view it is
    /// views.
    fn readsAfterIndex(self: *const Checker, object: Sexp) bool {
        const ty = self.stepType(object) orelse return false;
        const root = !object.isKind(.member) and !object.isKind(.index);
        return switch (self.typeData(ty)) {
            .array => true,
            .slice => root,
            else => self.isList(ty),
        };
    }

    /// The type of `e`, a place or a step of one, as a step into it sees
    /// it: a root that is a view is what it views.
    fn stepType(self: *const Checker, e: Sexp) ?TypeId {
        const ty = self.exprType(e) orelse return null;
        if (e.isKind(.member) or e.isKind(.index)) return ty;
        return self.pointee(ty);
    }

    /// Whether place `e` is stored where its root's value is, every step
    /// to it a field of an object or an element of an array held there
    /// (`holdsInline`): a write of the root changes what is there but
    /// never moves it. A root is what a view it is views.
    fn staysInRoot(self: *const Checker, e: Sexp) bool {
        if (!e.isKind(.member) and !e.isKind(.index)) return true;
        const object = ir.get(e, .object);
        const ty = self.stepType(object) orelse return false;
        return self.holdsInline(ty) and self.staysInRoot(object);
    }

    /// Whether values of `ty` hold their parts where the value is: an
    /// array, or an object a module declares (`obj P`, `obj Wrap[T]`,
    /// declared in this module's source).
    fn holdsInline(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return false;
        return switch (ctx.types.get(ty)) {
            .array, .nominal, .imported_nominal => true,
            .parameterized_nominal => |pn| blk: {
                const sym = ctx.symbols.items[pn.sym];
                break :blk sym.kind == .generic_type and sym.decl_pos < sema.imported_decl_pos;
            },
            else => false,
        };
    }

    /// A `member` or `index`. A place is read as far as its path: its
    /// root's name is read there (`takePlaceRead`).
    fn walkMember(self: *Checker, e: Sexp) Error!Value {
        const object = ir.get(e, .object);
        // The outermost step of the place sets it; its root's name, read
        // first, takes it.
        var sets_read = false;
        defer if (sets_read) {
            self.place_read = null;
        };
        if (self.place_read == null) {
            self.place_read = .{ .base = self.placeBase(e), .place = e };
            sets_read = true;
        }
        // A value that is no place is read where it runs, and indexed
        // after its index runs; a place is found up to its index before
        // the index runs (`walkIndexOf`).
        const obj = if (e.isKind(.index) and self.resolvePlace(object) == null)
            try self.walkThenHeld(object, .base, ir.Index.index(e))
        else blk: {
            const v = try self.walk(object);
            if (e.isKind(.index)) try self.walkIndexOf(object, ir.Index.index(e));
            break :blk v;
        };
        if (!self.mayCarryLoan(self.exprType(e))) {
            self.taintGeneric(self.exprType(e), obj);
            return .{};
        }
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
        if (!self.viewsOnlyRead(t)) return v;
        const reads = result or sema.holdsViewOnly(ctx, t);
        var out: std.ArrayList(Loan) = .empty;
        for (v.loans) |l| try self.carryLoan(&out, t, reads, l, 0);
        return .{ .loans = out.items };
    }

    /// Whether values of `ty` hold views, and none that can write: no
    /// write view, type parameter, or type not known. The loans such a
    /// value keeps are narrowed by `carry`, and a call's result of the
    /// type keeps them as read loans (`carryResult`).
    fn viewsOnlyRead(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return false;
        const info = ctx.typeInfo(ty);
        if (info.poison or info.holds_type_var or info.views.write) return false;
        return info.views.marked or info.views.string_view;
    }

    /// A call whose result `v` only reads what it views has returned: the
    /// write lends its arguments made since `temps_start` end, as a lend
    /// ends at the last use of its view (Core sentence 6), but for those
    /// the call may have stored (`stored`), which last as long as before.
    /// What the result keeps stays lent, to read, for the rest of the
    /// statement, as any temporary view is (Core §3).
    fn endWriteLends(self: *Checker, temps_start: usize, stored: Value, v: Value) Error!Value {
        var i = @min(temps_start, self.temps.items.len);
        while (i < self.temps.items.len) {
            const l = self.temps.items[i];
            if (l.kind == .write and !hasLoanOn(stored.loans, l.root)) _ = self.temps.orderedRemove(i) else i += 1;
        }
        for (v.loans) |l| if (!l.ext) try self.addTemp(l);
        return v;
    }

    /// The views taken since `temps_start` to compute view `v` end,
    /// but for those `v` keeps: `!it.next()` twice in one statement.
    fn keepViewTemps(self: *Checker, temps_start: usize, v: Value) Error!Value {
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        for (v.loans) |l| if (!l.ext) try self.addTemp(l);
        return v;
    }

    fn carryLoan(self: *Checker, out: *std.ArrayList(Loan), ty: TypeId, reads: bool, l: Loan, depth: u8) Error!void {
        // A loan on a var whose scope ended was released with it
        // (`releaseVarsFrom`); one that survives is a lost track of the
        // walk, which no program is accepted with.
        if (l.root >= self.vars.items.len) return self.err(l.pos, "internal error: a loan outlives the var it is on", .{});
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
    /// operand (an array's or a List's, or a String's bytes) rather than a
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
        const place = self.resolvePlace(inner) orelse {
            const start = self.vars.items.len;
            const v = try self.walkViewedPath(inner);
            return if (kind == .write) self.lendTempToWrite(v, start) else v;
        };
        try self.walkIndicesHeld(inner, place.root, place.path);
        const id = place.root;
        const v = self.vars.items[id];
        const pos = self.startOf(inner);
        if (v.closure) {
            if (kind == .read and place.whole) return self.lendClosure(id, pos);
            try self.err(pos, "closure `{s}` cannot be lent to write; lend it as `?{s}`", .{ v.name, v.name });
            return .{};
        }
        return (try self.lendVar(id, place.path, kind, pos)) orelse .{};
    }

    /// `v`, the view of a path that starts from no var, lent to write:
    /// the statement temporary it starts from (held since there were
    /// `start` vars, `holdTemp`) is lent to write (`!mk().bump()`, Core
    /// sentence 4).
    fn lendTempToWrite(self: *Checker, v: Value, start: usize) Error!Value {
        var loans: ?[]Loan = null;
        for (v.loans, 0..) |l, i| {
            if (l.root < start or !self.isStmtTemp(l.root) or l.kind == .write) continue;
            const out = loans orelse try self.arena().dupe(Loan, v.loans);
            out[i].kind = .write;
            loans = out;
        }
        var w = v;
        if (loans) |ls| w.loans = ls;
        return w;
    }

    /// A view of a path that starts from no var (`?f(?h).r`): it keeps
    /// what the path's start views, whatever the type of each step.
    fn walkViewedPath(self: *Checker, e: Sexp) Error!Value {
        if (!e.isKind(.member) and !e.isKind(.index)) return self.walk(e);
        const obj = try self.walkViewedPath(ir.get(e, .object));
        if (e.isKind(.index)) _ = try self.walk(ir.Index.index(e));
        return obj;
    }

    /// Lend place `path` of var `id` at `pos`: null when `id` is moved or
    /// the lend conflicts, both reported.
    fn lendVar(self: *Checker, id: VarId, path: PathId, kind: LoanKind, pos: u32) Error!?Value {
        if (!try self.checkLive(id, pos)) return null;
        if (try self.conflicts(id, path, if (kind == .write) .write else .read, pos)) return null;
        const loan: Loan = .{ .root = id, .path = path, .kind = kind, .pos = pos };
        try self.addTemp(loan);
        return try self.lendOn(id, loan);
    }

    /// A view of the elements of `object`: `slice` is a slice of it
    /// (`?xs[a..b]`, `!xs[a..b]`), or a view of the whole array lent as
    /// one (`?a`). A slice of a `?String` or a `[]T` views what that value
    /// views. A slice of a List views the List, whose buffer it points
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
        // what its start views, as a view of one does; `!mk()[..]` lends
        // that temporary to write.
        const place = self.resolvePlace(object) orelse {
            const start = self.vars.items.len;
            var v = try self.walkViewedPath(object);
            if (kind == .write) v = try self.lendTempToWrite(v, start);
            if (rig.isRangeIndex(slice)) _ = try self.walk(ir.Index.index(slice));
            return v;
        };
        try self.walkIndicesHeld(indices, place.root, place.path);
        const id = place.root;
        const pos = self.startOf(slice);
        const v = (try self.lendVar(id, place.path, kind, pos)) orelse return .{};
        if (self.typeData(peeled) != .array or !self.inVarStorage(object)) return v;
        return .{ .loans = try self.unionLoans(v.loans, try self.oneLoan(.{ .root = id, .path = place.path, .kind = kind, .pos = pos, .frame = true })) };
    }

    /// A slice walked as a plain value, or a whole-array view's operand.
    fn walkOperand(self: *Checker, slice: Sexp, object: Sexp) Error!Value {
        return self.walk(if (rig.isRangeIndex(slice)) slice else object);
    }

    /// Whether place `e` reaches its value through a read view: a step
    /// past a `?T`, a read-only `[]T`, or a `?String` (`c.items[0]` with
    /// `items: ?List[Item]`). Its memory is the view's, which the place's
    /// var does not own.
    fn throughReadView(self: *const Checker, e: Sexp) bool {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) {
            const obj = ir.get(p, .object);
            if (self.exprType(obj)) |t| switch (self.typeData(t)) {
                .read_view, .slice, .string_view => return true,
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
        try self.walkIndicesHeld(e, place.root, place.path);
        try self.checkReadable(place.root, e, self.startOf(e));
        return self.varValue(place.root);
    }

    /// Whether the value of place `e` is stored in the var the place
    /// starts from, rather than behind a pointer, a handle, or a List's
    /// buffer, whose own loans cover it. A read view copies only
    /// scalars and views, which hold no array, so an array reached
    /// through one is behind a pointer.
    fn inVarStorage(self: *const Checker, e: Sexp) bool {
        if (self.exprType(e)) |ty| switch (self.typeData(ty)) {
            .write_view, .read_view, .shared, .slice => return false,
            else => if (self.isList(ty)) return false,
        };
        if (e.isKind(.member) or e.isKind(.index)) return self.inVarStorage(ir.get(e, .object));
        return true;
    }

    /// The loans of a view of (a path inside) var `id`, by what the var
    /// is (`lendTarget`).
    fn lendOn(self: *Checker, id: VarId, loan: Loan) Error!Value {
        const held = self.flows.items[id].loans;
        return switch (self.lendTarget(self.vars.items[id])) {
            .write_view => .{ .loans = try self.unionLoans(try self.oneLoan(loan), held) },
            .read_view => .{ .loans = held },
            .owner => .{ .loans = try self.oneLoan(loan) },
        };
    }

    const LendTarget = enum {
        /// A loan on the var.
        owner,
        /// A loan on the var, so nothing writes through it while the view
        /// lives, and the loans it holds.
        write_view,
        /// The loans it holds, as a copy of the view carries.
        read_view,
    };

    /// What a lend of var `v` puts a loan on, from the binding's access
    /// (`SemContext.bindingAccess`, docs/INTERNALS.md "Binding access"):
    /// a binding a write may go through is a write view, one no write goes
    /// through a read view, and any other var (one that owns or copies its
    /// value, or a value no binding names) an owner.
    fn lendTarget(self: *const Checker, v: Var) LendTarget {
        const ctx = self.sema orelse return .owner;
        const sym = v.sym orelse return .owner;
        const access = ctx.bindingAccess(sym) orelse return .owner;
        return switch (access) {
            .write => .write_view,
            .read => .read_view,
        };
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

    /// What `<e` does to its source (`sema.moveSource`). Without sema's
    /// facts (the checker's own unit tests), a name is a binding and a
    /// path a part.
    fn moveSource(self: *const Checker, inner: Sexp) sema.MoveSource {
        if (self.sema) |ctx| return sema.moveSource(ctx, inner);
        const place = self.resolvePlace(inner) orelse return .made;
        return if (place.whole) .binding else .part;
    }

    /// `<e`: a binding is ended, an optional part emptied (`walkTake`,
    /// where typecheck recorded the take), and any other source is
    /// rejected: `<` would leave it as it was, or move what its owner
    /// still drops. A value made here is taken, and a branching value
    /// leaf by leaf.
    fn walkMove(self: *Checker, inner: Sexp) Error!Value {
        switch (self.moveSource(inner)) {
            .binding => {
                const place = self.resolvePlace(inner) orelse return self.walk(inner);
                return self.moveVar(place.root, self.startOf(inner), .move);
            },
            .capture => {
                const place = self.resolvePlace(inner) orelse return self.walk(inner);
                // A capture that owns a resource, or holds a view, is
                // reported as one (`rejectConsumedView`).
                if (self.vars.items[place.root].capture_resource) return self.moveVar(place.root, self.startOf(inner), .move);
                _ = try self.walk(inner);
                try self.errAt(inner, "cannot move `{s}`, a copy capture: the closure keeps it for every call; remove the `<` to copy it", .{self.text(inner)});
                return .{};
            },
            .optional_part => return self.walkTake(inner),
            .part => {
                if (self.resolvePlace(inner)) |place| return self.movePart(inner, place, null, false);
                // A path that starts from no var reaches its value through
                // a view or a handle when one of the values on it is one,
                // by its type: `(!s).items`, `(?s if c else ?t).items`,
                // `wrap(!s).items`.
                if (self.viewOnPath(inner)) |via| return self.movePart(inner, .{ .root = 0, .whole = false, .through_view = !via.shared, .through_shared = via.shared }, via.value, false);
                // A root no var holds here (an outer name a closure did not
                // capture): walking reports it.
                return self.walk(inner);
            },
            .branch_part => return self.movePart(inner, .{ .root = 0, .whole = false }, sema.pathRoot(inner), true),
            // The type checker reported it (`rejectMadeParts`), and a
            // module with type errors is not checked here.
            .made_part => return self.walk(inner),
            .declared => return self.moveDeclared(inner),
            .made => return self.walk(inner),
            .branches => {
                if (try self.reportMoveLeaves(inner)) return .{};
                return self.walk(inner);
            },
        }
    }

    /// `<` of what lives for the whole program
    /// (`sema.MoveSource.declared`): rejected, since nothing could end it.
    fn moveDeclared(self: *Checker, inner: Sexp) Error!Value {
        _ = try self.walk(inner);
        const pos = self.startOf(inner);
        const shown = self.spanText(inner);
        const ty = self.exprType(inner);
        if (ty != null and self.typeData(ty.?) == .function) {
            try self.err(pos, "cannot move function `{s}`: a function lives for the whole program; remove the `<` to use it", .{shown});
        } else if (inner == .src or (inner.isKind(.member) and ir.Member.object(inner) == .src and self.namesModule(ir.Member.object(inner)))) {
            try self.err(pos, module_level_rule, .{ "move", shown });
        } else try self.err(pos, part_copies_rule, .{try self.placeText(inner)});
        return .{};
    }

    fn namesModule(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        const id = ctx.symbolOf(e) orelse return false;
        return ctx.symbols.items[id].kind == .module;
    }

    /// Whether `ty` is a shared or weak handle.
    fn isHandleType(self: *const Checker, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return switch (self.typeData(t)) {
            .shared, .weak => true,
            else => false,
        };
    }

    /// The value a field or element path reaches its place through that
    /// is a view (`?T`, `!T`, a slice) or a shared handle, by the type
    /// of each value on the path, as `resolvePlace` judges a place's:
    /// `(!s)` in `(!s).items[0]`, `wrap(!s)` in `wrap(!s).items`.
    fn viewOnPath(self: *const Checker, e: Sexp) ?struct { value: Sexp, shared: bool } {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) {
            const obj = ir.get(p, .object);
            if (self.exprType(obj)) |t| switch (self.typeData(t)) {
                .read_view, .write_view, .slice, .string_view => return .{ .value = obj, .shared = false },
                .shared => return .{ .value = obj, .shared = true },
                else => {},
            };
            p = obj;
        }
        return null;
    }

    /// `<p.f` of an optional field or element: the value is taken out
    /// and `none` left behind, so the place stays whole. The place is
    /// written: no other view of it may be live. What the value
    /// views, the place viewed.
    fn walkTake(self: *Checker, inner: Sexp) Error!Value {
        const place = self.resolvePlace(inner) orelse return self.walkViewedPath(inner);
        try self.walkFoundIndices(inner);
        const id = place.root;
        const pos = self.startOf(inner);
        if (!try self.checkLive(id, pos)) return .{};
        if (try self.conflicts(id, place.path, .write, pos)) return .{};
        if (!self.mayCarryLoan(self.exprType(inner))) {
            self.taintGeneric(self.exprType(inner), self.varValue(id));
            return .{};
        }
        return self.varValue(id);
    }

    /// `<e` of a branching value (`a if c else b`, `a ?? b`, `e catch h`,
    /// `e!`, `e?`): `<` takes only what its leaves give up, a value made
    /// there. Any other leaf (`sema.moveLeaves`) would be left as it was,
    /// or moved while its owner still drops it, so the move is written
    /// where the leaf is. The first such leaf is reported; whether one was.
    fn reportMoveLeaves(self: *Checker, top: Sexp) Error!bool {
        const ctx = self.sema orelse return false;
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

    fn reportMoveLeaf(self: *Checker, leaf: sema.MoveLeaf, top: Sexp) Error!void {
        const place = leaf.node;
        // A part of a branching value is shown as written.
        const shown = if (leaf.source == .branch_part) self.spanText(place) else try self.placeText(place);
        const at_exit = top.isKind(.propagate) or top.isKind(.propagate_none);
        const ty = self.exprType(place);
        switch (leaf.source) {
            .capture => try self.errAt(place, "`<` here would leave `{s}` as it was: the closure keeps its capture for every call; remove the `<` to copy it", .{shown}),
            .binding, .optional_part => {
                const verb = if (leaf.source == .binding) "move" else "take";
                if (at_exit) {
                    try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it before the `?` or `!`: `(<{s}){s}`", .{ shown, verb, shown, if (top.isKind(.propagate)) "!" else "?" });
                } else try self.errAt(place, "`<` here would copy `{s}` out without moving it; {s} it inside the branch: `<{s}`", .{ shown, verb, shown });
            },
            .declared => try self.errAt(place, "`<` here would leave `{s}` as it was: it lives for the whole program; remove the `<` to copy it", .{shown}),
            else => if (ty != null and (self.copies(ty) or self.refOfType(ty) == .read)) {
                try self.errAt(place, "`<` here would leave `{s}` as it was: it copies; remove the `<` to copy it", .{shown});
            } else if (leaf.source == .branch_part) {
                try self.errAt(place, "`<` here would copy `{s}` out without moving it, and the binding its branch reads would still drop it; exchange the part where it is owned, with `replace`", .{shown});
            } else try self.errAt(place, "`<` here would copy `{s}` out without moving it, and a field that is not optional cannot be moved out; exchange it: `replace(!{s}, v)`", .{ shown, shown }),
        }
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
        if (v.payload_view) return self.movePayload(id, pos, vt);

        if (try self.conflicts(id, whole_path, .{ .consume = vt }, pos)) return .{};
        // Emit arms a drop flag only for a binding the consumed fact
        // records (`SemContext.consumes`), so no other may move.
        if (self.sema) |ctx| if (ctx.symbolAt(v.decl)) |sym| if (!ctx.consumes(sym)) {
            try self.err(pos, "internal error: `{s}` moves here, but the consumed fact does not record it", .{v.name});
            return .{};
        };
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
        const viewed = if (v.alias_of) |root| self.vars.items[root].name else v.matched;
        switch (v.via) {
            .viewed => {
                try self.err(pos, "cannot move out of `{s}`: it is a view of `{s}`", .{ v.name, viewed });
                return .{};
            },
            .shared => {
                try self.err(pos, "cannot move out of `{s}`: `{s}` is a shared handle and other handles may still use it", .{ v.name, viewed });
                return .{};
            },
            .owned => {},
        }
        // Only a binding of a var the function owns is `owned`.
        const root = v.alias_of orelse return .{};
        const r = self.vars.items[root];
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

    /// `<p.f` or `<v[i]` of a part that can be neither ended nor emptied
    /// (`MoveSource.part`): rejected. One that copies would stay as it
    /// was; one that moves would stay owned by its parent, or by what
    /// `via` reaches it through (`viewOnPath`, `branchesOnPath`),
    /// whatever its syntax.
    fn movePart(self: *Checker, inner: Sexp, place: Place, via: ?Sexp, branching: bool) Error!Value {
        _ = try self.walk(inner);
        const ty = self.exprType(inner);
        const path = try self.placeText(inner);
        const pos = self.startOf(inner);
        // An optional is taken only out of a place (`sema.moveSource`).
        if (branching and ty != null and self.typeData(ty.?) == .optional) {
            const base = via.?;
            if (base.isKind(.@"if")) {
                try self.err(pos, "cannot take out of `{s}`: `{s}` reads a binding where it stands; take it inside each branch", .{ self.spanText(inner), self.spanText(base) });
            } else try self.err(pos, "cannot take out of `{s}`: `{s}` reads a binding where it stands, and `<` takes only out of a place", .{ self.spanText(inner), self.spanText(base) });
            return .{};
        }
        if (ty != null and (self.copies(ty) or self.refOfType(ty) == .read)) {
            try self.err(pos, part_copies_rule, .{if (via != null) self.spanText(inner) else path});
            return .{};
        }
        // A write view has one holder, which keeps it.
        if (via == null and self.refOfType(ty) == .write) {
            try self.err(pos, "cannot move out of `{s}`: a write view has one holder, and `{s}` keeps it; lend it on with `!{s}`", .{ path, self.vars.items[place.root].name, path });
            return .{};
        }
        if (via) |l| {
            const shown = self.spanText(inner);
            const lent_handle = (l.isKind(.read) or l.isKind(.write)) and self.isHandleType(self.exprType(ir.get(l, .operand)));
            if (place.through_shared or lent_handle) {
                const handle = if (lent_handle) ir.get(l, .operand) else l;
                try self.err(pos, "cannot move out of `{s}`: it is reached through the shared handle `{s}`, and other handles may still use it; clone it with `+({s})`", .{ shown, self.spanText(handle), shown });
            } else if (branching) {
                try self.err(pos, "cannot move out of `{s}`: `{s}` reads a binding where it stands, which would still drop it; exchange the part where it is owned, with `replace`", .{ shown, self.spanText(l) });
            } else if ((l.isKind(.read) or l.isKind(.write)) and self.resolvePlace(ir.get(l, .operand)) != null) {
                // A lend of a place: the place's own path names the part.
                try self.err(pos, "cannot move out of `{s}`: it is reached through `{s}`, a view; exchange it instead: `replace(!{s}, v)`", .{ shown, self.spanText(l), path });
            } else try self.err(pos, "cannot move out of `{s}`: it is reached through `{s}`, a view, which gives up nothing of what it views; exchange the part where it is owned, with `replace`", .{ shown, self.spanText(l) });
            return .{};
        }
        const root = self.vars.items[place.root].name;
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

    /// What to write instead of taking a captured `name` of type `ty` out
    /// of its closure: what `+` gives, where it gives anything, and for
    /// a shared handle a weak one too.
    fn captureFix(self: *Checker, name: []const u8, ty: ?TypeId) Error![]const u8 {
        const ctx = self.sema orelse return "";
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
            try self.err(pos, "cannot {s} captured `{s}`: the closure keeps what it captures for every call{s}", .{ op, v.name, try self.captureFix(v.name, v.ty) });
            return true;
        }
        return false;
    }

    /// A module-level binding outlives every call of the function using
    /// it: a function cannot consume or replace it.
    fn rejectGlobal(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
        if (!self.isGlobal(id)) return false;
        const name = self.vars.items[id].name;
        try self.err(pos, module_level_rule, .{ op, name });
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
        if (!self.mayCarryLoan(ty)) {
            self.taintGeneric(ty, v);
            return .{};
        }
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
        const target = ir.Drop.target(node);
        // `<e` of anything but a name drops what it takes, as `_ = <e`
        // does (`walkSet`).
        if (target != .src) {
            const saved = self.binding;
            defer self.binding = saved;
            self.binding = .{ .name = "_", .value = target };
            _ = try self.walkConsumed(target, .binding);
            return;
        }
        const pos = target.src.pos;
        const name = self.text(target);
        const id = self.find(name) orelse return;
        const v = self.vars.items[id];
        // Why `<x` cannot drop `x` is decided once (`sema.undroppable`),
        // which the type checker's hint for a statement `-x` reads too;
        // without its facts (this checker's unit tests), by the var.
        const why: ?sema.Undroppable = if (self.sema) |ctx| sema.undroppable(ctx, target) else if (v.loop_view) .loop_slot else if (v.capture_resource) .capture else if (v.kind == .param and v.ref != .none) .view_param else null;
        if (why) |w| return switch (w) {
            .view_param => self.err(pos, "cannot drop view parameter `{s}`; the caller owns what it views", .{name}),
            .capture => if (v.ref != .none)
                self.err(pos, "cannot drop captured view `{s}`; the closure holds it for every call. Use it through the view, or pass it to a call", .{name})
            else if (v.capture_resource)
                self.err(pos, "cannot drop captured `{s}`: the closure keeps what it captures for every call", .{name})
            else
                self.err(pos, "cannot drop captured `{s}`; the closure keeps what it captures for every call", .{name}),
            .loop_slot => self.err(pos, "cannot drop loop view `{s}`; " ++ loop_view_rule, .{name}),
        };
        if (try self.rejectConsumedView(id, pos, "drop")) return;
        if (try self.rejectGlobal(id, pos, "drop")) return;
        if (!self.flowLive(id)) {
            if (self.flows.items[id].status == .moved) {
                try self.err(pos, "cannot drop `{s}` after it was moved", .{name});
            } else try self.err(pos, "cannot drop `{s}` twice", .{name});
            try self.noteInvalidated(id, pos);
            return;
        }
        if (v.payload_view) {
            _ = try self.movePayload(id, pos, "drop");
            if (!self.flowLive(id)) try self.markInvalid(id, .dropped, pos);
            return;
        }
        if (self.findLoan(id, whole_path, .any, null)) |l| {
            try self.err(pos, "cannot drop `{s}` while {s} is lent", .{ name, try self.lentText(l, whole_path) });
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
                // A loop view passed to a call is lent on for the call, as
                // `?x` lends it; anywhere else it would be copied out.
                if (v.loop_view and !(sink == .argument and self.isView(v.ty))) {
                    try self.err(pos, "bare use of loop view `{s}` in {s} would carry the viewed handle past the loop; " ++ loop_view_rule, .{ name, sink.text() });
                    return;
                }
                // A captured read view or Copy value is copied out, and
                // a captured view passed to a call is lent for the call.
                const copied = v.ref == .read or self.copies(v.ty) or (sink == .argument and v.ref != .none);
                if (v.capture_resource and !copied and v.ref == .write) {
                    try self.err(pos, "`{s}` is a write view the closure captures, and a {s} would hand it out of the closure at each call, though a write view has one holder; use it inside the closure instead", .{ name, sink.text() });
                    return;
                }
                if (v.capture_resource and !copied) {
                    try self.err(pos, "`{s}` is captured by the closure, which keeps it for every call, so a {s} can't take it{s}", .{ name, sink.text(), try self.captureFix(name, v.ty) });
                    return;
                }
                if (top_return) return;
                if (self.owningKind(v.ty)) |k| return self.reportAlias(pos, name, .name, k, sink, v.ty, null);
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
                        return self.reportAlias(self.startOf(expr), try self.placeText(expr), if (expr.isKind(.index)) .element else .field, k, sink, ty, expr);
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
    /// view of a value that copies (`sema.copiedThrough`), and the
    /// context reads it (`copy_reads`, `SemContext.readsThrough`). A bare
    /// name or place only reads (Core sentence 1): `x = h.w`, with
    /// `w: !Int` or `w: !Point`, copies the value.
    fn readsThroughWriteView(self: *const Checker, ty: ?TypeId) bool {
        return self.copy_reads and self.refOfType(ty) == .write and self.copiedThrough(ty);
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

    /// Every type parameter `ty` holds must hold no `?String` in each
    /// instance, because the value is stored where no loan is tracked:
    /// in a Cell, a Signal, or an owned closure.
    fn requireNoView(self: *Checker, pos: u32, ty: ?TypeId) Error!void {
        return self.addRequirement(pos, ty orelse return, .{ .param = 0, .pos = pos, .view = true });
    }

    fn addRequirement(self: *Checker, pos: u32, ty: TypeId, req: PlainRequirement) Error!void {
        const ctx = self.sema orelse return;
        var held: std.ArrayList(SymbolId) = .empty;
        // A value stored where no loan is tracked carries the loans of
        // every `T` it reaches, however deep; a copy or cleanup
        // requirement is about what it holds by value.
        if (req.view) try sema.reachedTypeVars(ctx, ty, &held, self.arena()) else try sema.heldTypeVars(ctx, ty, &held, self.arena());
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

    /// A bare use that would copy a value that moves: say what holds the
    /// value, and every way to write what is meant (move, clone, view).
    fn reportAlias(self: *Checker, pos: u32, what: []const u8, aliased: Aliased, k: Owning, sink: Sink, ty: ?TypeId, part: ?Sexp) Error!void {
        if (k == .generic) {
            // Fine for plain data: each instantiation is checked.
            if (ty) |t| try self.requirePlain(pos, t, false);
            return;
        }
        const a = self.arena();
        const ctx = self.sema orelse return;
        const t = ty orelse return;
        const shown = try sema.formatTypeIn(ctx, a, t);
        const is_name = aliased == .name;
        var fixes: std.ArrayList([]const u8) = .empty;
        // A name moves; a part moves out only from an optional, which
        // `<` leaves `none`.
        if (is_name) {
            try fixes.append(a, try a.print("`<{s}` to move it", .{what}));
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
    fn ownerCallee(self: *Checker, pos: u32) Error!?struct { name: []const u8, param: ?[]const u8 = null } {
        const call = self.arg_call orelse return null;
        const ctx = self.sema orelse return null;
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

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    fn walkSet(self: *Checker, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const target = ir.Set.target(node);
        const expr = ir.Set.value(node);
        if (target != .src) {
            // The steps in the order emit evaluates them
            // (`storage.eachSetStep`): the value, the base of the target's
            // path, and its indexes from the base outward.
            const Steps = struct {
                c: *Checker,
                set: Sexp,
                placed: bool,
                value: Value = .{},
                base: ?Value = null,
                base_node: Sexp = .nil,

                pub fn step(st: *@This(), s: storage.SetStep) Error!void {
                    switch (s.role) {
                        .value => {
                            const mark = try st.c.useAfterValue(st.set);
                            defer st.c.after_value.shrinkRetainingCapacity(mark);
                            st.value = try st.c.walkConsumed(s.node, .field);
                        },
                        // The base of a target that is no place (a lend,
                        // `(!h).r`, or a write view a call returns,
                        // `wrap(!h).r`) runs here; a place is found at
                        // the store.
                        .base => if (!st.placed) {
                            st.base = try st.c.walk(s.node);
                            st.base_node = s.node;
                        },
                        .index => _ = try st.c.walk(s.node),
                    }
                }
            };
            var steps: Steps = .{ .c = self, .set = node, .placed = self.resolvePlace(target) != null };
            try storage.eachSetStep(node, &steps);
            return self.walkFieldAssign(target, steps.value, steps.base, steps.base_node);
        }

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
        const mark = try self.useAfterValue(node);
        const value: Value = switch (kind) {
            .default, .fixed, .shadow => if (is_lambda) blk: {
                self.lambda_ok = true;
                break :blk try self.walk(expr);
            } else blk: {
                const saved = self.binding;
                defer self.binding = saved;
                self.binding = .{ .name = name, .value = expr };
                const v = try self.walkConsumed(expr, .binding);
                // A binding reported for taking a held write view holds
                // nothing, so its later uses report nothing more.
                break :blk if (self.binding.?.rejected) Value{} else v;
            },
            else => try self.walk(expr),
        };
        self.after_value.shrinkRetainingCapacity(mark);

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
                try self.checkReadable(id, null, pos);
                try self.checkAssignable(id, pos);
                return;
            },
        }
        if (is_lambda) self.vars.items[self.vars.items.len - 1].env_drop_reads = self.envDropReads(expr);
    }

    /// An assignment is `{ __v = value; place op= __v }`: what its target
    /// reads is used after its value, so it is live while the value is
    /// walked (`after_value`). A name target reads its binding when the
    /// store combines with it (`x op= v`) or writes through it (a `!T`
    /// local given a value); a field or element target reads every name
    /// in it. Returns the mark to drop them back to once the value is
    /// walked.
    fn useAfterValue(self: *Checker, node: Sexp) Error!usize {
        const mark = self.after_value.items.len;
        const ctx = self.sema orelse return mark;
        const target = ir.Set.target(node);
        if (target != .src) {
            try self.useAfterValueIn(target);
            return mark;
        }
        const sym = ctx.symbolOf(target) orelse return mark;
        const s = ctx.symbols.items[sym];
        if (s.decl_pos == target.src.pos) return mark;
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const writes_through = kind == .default and !ctx.repoints(node) and sema.assignWritesThrough(ctx, s.ty);
        if (kind.operator() != null or writes_through) try self.after_value.append(self.gpa, .{ .sym = sym, .loop = self.loop });
        return mark;
    }

    fn useAfterValueIn(self: *Checker, e: Sexp) Error!void {
        switch (e) {
            .src => if (self.sema.?.symbolOf(e)) |sym| try self.after_value.append(self.gpa, .{ .sym = sym, .loop = self.loop }),
            .list => for (e.items()) |c| try self.useAfterValueIn(c),
            else => {},
        }
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
        if (rig.leavesBody(e) or rig.isJump(e)) return true;
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
        }, .{ .loans = if (closure) value.loans else if (self.mayCarryLoan(ty)) (try self.carry(ty, value)).loans else self.taintedNone(ty, value) });
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
            try self.note(v.decl, "`{s}` was bound here with `=!`", .{v.name});
            return;
        }
        // Assigning a captured write view writes through it.
        // (A capture the type checker rejected is reported there.)
        const writes_capture = v.kind == .capture and (v.ref == .write or self.isPoisonType(v.ty));
        if (!writes_capture and try self.rejectConsumedView(id, pos, "reassign")) return;
        if (!self.copies(v.ty) and try self.rejectGlobal(id, pos, "reassign")) return;
        if (v.payload_view and v.ref != .write and !self.isPoisonType(v.ty)) {
            try self.err(pos, "cannot reassign match binding `{s}`; it views the matched value", .{v.name});
            return;
        }
        if (self.findLoan(id, whole_path, .any, null)) |l| {
            try self.err(pos, "cannot reassign `{s}` while {s} is lent", .{ v.name, try self.lentText(l, whole_path) });
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
        if (self.findLoan(id, whole_path, .any, null) != null) return;
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
        try self.setFlow(id, .{ .loans = if (self.mayCarryLoan(v.ty)) (try self.carry(v.ty, value)).loans else self.taintedNone(v.ty, value) });
    }

    /// Whether storing `value` in a place of type `ty` may store a loan:
    /// it carries one and the place may hold a view, or the place's type
    /// mentions a type parameter (`noteGenericStore`).
    fn storesLoans(self: *const Checker, ty: ?TypeId, value: Value) bool {
        if (self.holdsGeneric(ty)) return true;
        return value.loans.len > 0 and self.mayCarryLoan(ty);
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
            if (!w.ext and !self.callerOwns(w.root) and !self.isGlobal(w.root)) continue;
            for (value.loans) |l| if (self.isLocalLoan(l)) {
                try self.err(pos, "cannot store a view of `{s}` through `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, self.vars.items[id].name, r.name });
                return;
            };
        }
        try self.absorbThroughWrites(held, value, pos, self.vars.items[id].name, depth);
    }

    /// The store of `value` into `target`, once its steps have run
    /// (`walkSet`); `base` is what a base that is no place, `base_node`,
    /// gave.
    fn walkFieldAssign(self: *Checker, target: Sexp, value: Value, base: ?Value, base_node: Sexp) Error!void {
        const place = self.resolvePlace(target) orelse {
            // A target whose path starts from a value no var holds is
            // reached through that value's write loans: what is stored
            // there lands in what they reach.
            const lent = base orelse Value{};
            // An element of a Cell's List, marked `(!c)[i] = v`, is stored
            // in the Cell as one a name reaches is.
            if (self.inCellList(target)) return self.storeInCellList(target, value);
            if (!self.storesLoans(self.exprType(target), value)) return;
            return self.storeThroughLend(lent, value, self.startOf(target), if (base_node == .nil) null else self.spanText(base_node));
        };
        const id = place.root;
        const pos = self.startOf(target);
        if (!try self.checkLive(id, pos)) return;
        const v = self.vars.items[id];
        if (self.findLoan(id, place.path, .any, null)) |l| {
            try self.err(pos, "cannot assign to `{s}` while `{s}` is lent", .{ try self.placeText(target), try self.pathText(l.root, l.path) });
            try self.noteLoan(l);
            return;
        }
        // An element of a Cell's List, or a field of one, is stored in
        // the Cell, which every handle to it reaches: it may hold no loan.
        if (self.inCellList(target)) return self.storeInCellList(target, value);
        if (!self.storesLoans(self.exprType(target), value)) return;
        // A value never holds a view of itself (Core §5): a part of `id`
        // may not take a loan on a part of `id`.
        if (try self.selfViewIn(id, value.loans, &.{}, &.{})) |l| {
            try self.err(pos, "cannot store in `{s}` a view of `{s}`: a value never holds a view of itself", .{ try self.placeText(target), try self.pathText(l.root, l.path) });
            return self.noteLoan(l);
        }
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
                return self.noteStringViewOfString(l, self.exprType(target));
            };
            return self.storeInLent(id, pos, value, self.placeDepth(target, false));
        }
        var f = self.flows.items[id];
        f.loans = try self.unionLoans(f.loans, value.loans);
        try self.setFlow(id, f);
    }

    /// `stored` is stored through the write lend `lent`, whatever the
    /// syntax that reaches it: a write receiver (`wrap(!h).keep(v)`,
    /// `(!a if c else !b).keep(v)`), or an assignment's target that no
    /// var holds (`(!h).r = v`, `wrap(!h).r = v`). Whatever its write
    /// loans reach holds `stored`'s loans from here on. `via` names
    /// the write view an assignment stores through; a call has none.
    fn storeThroughLend(self: *Checker, lent: Value, stored: Value, pos: u32, via: ?[]const u8) Error!void {
        try self.absorbThroughWrites(lent, stored, pos, via, null);
    }

    /// `value`, which carries only loans the caller handed in, was stored
    /// into what var `id` reaches through a view: a parameter's value,
    /// or the value a loop or pattern binding writes through. Whatever
    /// holds the stored value now holds its loans: a parameter, as any
    /// var does (`absorbLoans`), and a binding's write loans lead to it
    /// within `depth` steps (`absorbThroughWrites`).
    fn storeInLent(self: *Checker, id: VarId, pos: u32, value: Value, depth: u32) Error!void {
        const v = self.vars.items[id];
        if (v.kind == .param) return self.absorbLoans(id, value, pos, &.{}, v.name, false, &.{});
        return self.absorbThroughWrites(self.varValue(id), value, pos, v.name, depth);
    }

    /// `value` stored into `target`, an element of the List a Cell holds
    /// (`inCellList`): every handle to the Cell reaches it, so it holds no
    /// view.
    fn storeInCellList(self: *Checker, target: Sexp, value: Value) Error!void {
        const pos = self.startOf(target);
        try self.requireNoView(pos, self.exprType(target));
        const loans = (try self.carry(self.exprType(target), value)).loans;
        if (loans.len > 0) try self.err(pos, "cannot store a view of `{s}` in a `Cell`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one{s}", .{ self.vars.items[loans[0].root].name, staticParamHint(loans[0]) });
    }

    /// Whether place `target` is, or is a field of, an element of the List
    /// a Cell holds (`c[i] = v`, `c[i].f = v`).
    fn inCellList(self: *const Checker, target: Sexp) bool {
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
        const out = try self.endCallHeld(node, mark, v);
        // Each result keeps only what the call's value still carries.
        if (self.results_of) |r| if (sameNode(r.node, node) and out.loans.len != v.loans.len) {
            const parts = try self.arena().alloc(Value, r.parts.len);
            for (r.parts, parts) |part, *kept| {
                var loans: std.ArrayList(Loan) = .empty;
                for (part.loans) |l| if (containsLoan(out.loans, l)) try loans.append(self.arena(), l);
                kept.* = .{ .loans = loans.items };
            }
            self.results_of = .{ .node = node, .parts = parts };
        };
        return out;
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
        // A function a field holds is called, which reaches nothing of
        // the value holding it.
        var field_call = false;

        // Method call: the receiver is lent for the whole call. A
        // write receiver is reserved (read) while the arguments are
        // evaluated and must be otherwise unlent when the call starts.
        var recv_root: ?VarId = null;
        // The place of `recv_root` the receiver is (`resolvePlace`).
        var recv_path: PathId = whole_path;
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
            field_call = true;
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
                try self.addTemp(.{ .root = p.root, .path = p.path, .kind = .read, .pos = self.startOf(obj), .place_hold = true });
                const recv_val = try self.walk(obj);
                if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
                const id = p.root;
                // A receiver already reported (used while a write loan is live)
                // is not reported again as a conflicting write view.
                if (self.flowLive(id) and !self.isScalar(self.vars.items[id].ty) and self.errors_found == found) {
                    const pos = self.startOf(obj);
                    reservation = self.temps.items.len;
                    try self.addTemp(.{ .root = id, .path = p.path, .kind = .read, .pos = pos, .reserved = recv_mode == .write });
                    recv_root = id;
                    recv_path = p.path;
                    // A built-in's methods hand out values, never views
                    // of the receiver.
                    const kind: LoanKind = if (recv_mode == .write) .write else .read;
                    recv_value = if (self.builtinName(self.exprType(obj)) != null) recv_val else try self.valueUnion(recv_val, try self.lendOn(id, .{ .root = id, .path = p.path, .kind = kind, .pos = pos }));
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

        // `print`, `String(...)`, and `!t.add(...)` only read their
        // arguments, and hold none of them past the call: a String keeps
        // their text, not them.
        const text_op = if (self.sema) |ctx| ctx.stringCallOf(node) orelse ctx.stringCallOf(callee) else null;
        if (self.isPrint(callee) or text_op != null) {
            for (args) |a| {
                // A slice there is lent to read, as `?a` would be.
                if (self.lendOf(a)) |lend| if (lend.implicit) {
                    _ = try self.walkImplicitLend(a, lend);
                    continue;
                };
                _ = try self.walk(a);
                try self.holdRead(a, .argument);
            }
            if (recv_root) |id| if (recv_mode == .write) {
                const reserved = self.temps.orderedRemove(reservation);
                const at = self.startOf(ir.Member.object(callee));
                if (try self.conflictingLoan(id, recv_path, .write, at)) |l| try self.noteWholeReceiver(id, recv_path, l, callee, at);
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
        const cell: ?[]const u8 = if (into != null and !std.mem.eql(u8, into.?, "List")) into else null;
        // A consuming receiver is passed like an argument.
        const consumed_recv = if (recv_mode == .value and callee.isKind(.member)) recv_value else Value{};
        // Which arguments the call passes loans on from (Core sentence
        // 7): the callee's origins, by the parameter each argument fills.
        const params = if (self.sema) |ctx| ctx.callParamsOf(node) else null;
        // What the result carries of the receiver and arguments.
        var from_args: Value = .{};
        if (params == null or params.?.resultCarriesReceiver()) {
            result = try self.valueUnion(result, recv_value);
            from_args = recv_value;
        }
        const arg_values = try self.arena().alloc(Value, args.len);
        // What the call may store, and what its result carries. A method
        // may store a view of what its receiver holds, or is, in what it
        // was lent to write (`h.r = ?self.items[..]`).
        var stored: Value = if (params == null or params.?.storesReceiver()) recv_value else .{};
        // Whether it may store a value of a type parameter's type, which
        // carries no loan in a generic body (`noteGenericStore`).
        var stores_generic = (params == null or params.?.storesReceiver()) and callee.isKind(.member) and self.holdsGeneric(self.pointee(self.exprType(unsigiled(ir.Member.object(callee)))));
        var carried: Value = .{};
        // A closure literal passed to a call the type checker rejected
        // was reported there.
        const saved_rejected = self.in_rejected_call;
        defer self.in_rejected_call = saved_rejected;
        const saved_call = self.arg_call;
        defer self.arg_call = saved_call;
        self.arg_call = node;
        for (args, arg_values, 0..) |a, *v, i| {
            self.in_rejected_call = self.rejected(node);
            const found = self.errors_found;
            v.* = try self.walkConsumed(a, .argument);
            if (self.errors_found == found) try self.holdRead(a, .argument);
            // An argument the call copies into storage of its own is lent
            // from the copy.
            if (self.heldForCall(storage.argValue(a), .argument)) |held| v.* = try self.holdForCall(held, v.*, .read);
            // A value handed over that carries a write loan (a write view
            // a method's result keeps of its receiver) keeps its root lent
            // to write until the call returns, as a write lend in the
            // argument does (Core sentence 5): a later argument may not
            // lend, read, or move it.
            for (v.loans) |l| if (l.kind == .write and !l.ext and !containsLoan(self.temps.items[@min(temps_start, self.temps.items.len)..], l)) try self.addTemp(l);
            // A generic body's `T` holds no loan here, but an instance's
            // may be a `?String` viewing a String.
            if (cell != null) try self.requireNoView(self.startOf(a), self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a));
            if (cell != null and v.loans.len > 0 and !self.rejected(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a)) {
                const held = v.*;
                v.* = .{};
                if (self.readsPlainValue(a)) continue;
                // A view of a `?String` stores the `?String` it reaches: what
                // it views, not the view.
                const arg_ty = self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a);
                const loans = (try self.carry(self.reachedType(arg_ty), held)).loans;
                if (loans.len == 0) continue;
                try self.errAt(a, "cannot store a view of `{s}` in a `{s}`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one{s}", .{ self.vars.items[loans[0].root].name, cell.?, staticParamHint(loans[0]) });
                continue;
            }
            if (!self.keepsCallable(node, a)) continue;
            // `!dst.copy(src)` stores copies of the elements `src` views,
            // which carry what those elements carry, not `src`'s loan
            // on what holds them (Core sentence 7).
            if (params == null or params.?.stores(i)) {
                stored = try self.valueUnion(stored, if (self.copiedElem(callee)) |elem| try self.carry(elem, v.*) else v.*);
                if (self.holdsGeneric(self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a))) stores_generic = true;
            }
            if (params == null or params.?.resultCarries(i)) carried = try self.valueUnion(carried, v.*);
        }
        result = try self.valueUnion(result, carried);
        from_args = try self.valueUnion(from_args, carried);
        // What the call keeps by its callee's `keeps`, for a conflict's note.
        if (params) |p| if (p.origins.stores & p.origins.lent != 0) {
            const write_recv = if (recv_mode == .write) recv_root else null;
            if (p.keepsLentReceiver()) try self.noteKept(callee, recv_value, "self", write_recv, arg_values);
            for (arg_values, 0..) |v, i| if (p.keepsLent(i)) try self.noteKept(callee, v, p.paramName(i) orelse "?", write_recv, arg_values);
        };

        // A write receiver is lent when the call starts, before the
        // callee stores anything.
        if (recv_root) |id| if (recv_mode == .write) {
            // The reservation itself is no conflict.
            const reserved = self.temps.orderedRemove(reservation);
            const at = self.startOf(ir.Member.object(callee));
            if (try self.conflictingLoan(id, recv_path, .write, at)) |l| try self.noteWholeReceiver(id, recv_path, l, callee, at);
            try self.temps.insert(self.gpa, reservation, reserved);
        };

        // The callee may store what its arguments view into anything it
        // can mutate: the receiver, and whatever the write views passed
        // to it lead to (`!x`, a write view passed on or moved in, a
        // value holding one). A built-in element method (`!dst.fill(v)`,
        // `!dst.copy(src)`) stores elements, which hold a view only where
        // the element type does (`storesNothing`).
        if ((stored.loans.len > 0 or stores_generic) and !self.storesNothing(callee)) {
            // A receiver lent to read is never written (Core sentence 9:
            // what changes through one is a Cell, which holds no loan). A
            // receiver lent to write holds what the call stores, whatever
            // its form: what its write lend reaches, a place's var, or the
            // write loans its value carries (a write view a call returns,
            // each branch of a branching receiver, a value the call holds).
            if (recv_mode == .write and callee.isKind(.member)) {
                const obj = ir.Member.object(callee);
                // What the receiver is, not the view lending it.
                if (self.mayHoldInInstance(self.pointee(self.exprType(obj)))) {
                    const pos = self.startOf(obj);
                    const lent: Value = if (recv_root) |id| .{ .loans = try self.oneLoan(.{ .root = id, .path = recv_path, .kind = .write, .pos = pos }) } else recv_value;
                    try self.storeThroughLend(lent, stored, pos, null);
                }
            }
            // Only a value that can write leads a store: a write lend, or a
            // value holding a write view. A read view that carries the
            // write loans of what reached it (a parameter's own, a write
            // view's) writes nothing.
            if (callee.isKind(.member) and self.mayWrite(self.exprType(ir.Member.object(callee)))) try self.absorbThroughWrites(consumed_recv, stored, self.startOf(callee), null, null);
            for (args, arg_values) |a, v| {
                if (self.mayWrite(self.exprType(if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a))) try self.absorbThroughWrites(v, stored, self.startOf(a), null, null);
            }
        }

        // The views passed to the call end when it returns, unless its
        // result can carry them.
        if (!self.mayCarryLoan(self.exprType(node))) {
            self.taintGeneric(self.exprType(node), if (field_call) from_args else result);
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        }
        // The result views only what could hold it (Core sentence 7). A
        // `?String`'s views end here but for those it keeps.
        const ty = self.exprType(node) orelse return result;
        if (self.sema) |ctx| if (sema.resultsOf(ctx, ty)) |tys| return self.callResults(node, temps_start, stored, result, tys);
        if (self.sema) |ctx| if (sema.holdsViewOnly(ctx, ty)) return self.keepViewTemps(temps_start, try self.carryResult(ty, result));
        if (self.viewsOnlyRead(ty)) return self.endWriteLends(temps_start, stored, try self.carryResult(ty, result));
        return self.carryResult(ty, result);
    }

    /// A call that gives several results, `-> (A, B)`: each carries the
    /// loans its own type can hold of what the call passes on, as one
    /// result does (`carryResult` of each), recorded for the targets that
    /// take them (`results_of`). An argument's write lend ends at the
    /// return only when no result keeps it to write; while one may, every
    /// lend lasts to the statement's end, as for a `!T` result. The
    /// results are views of one call, so no two may break sentence 5: a
    /// write loan one carries and a loan another carries on the same place
    /// are reported (the declaration rejects them first, `sema`'s
    /// `checkResultViews`, but a function value's type may say less).
    fn callResults(self: *Checker, node: Sexp, temps_start: usize, stored: Value, result: Value, tys: []const TypeId) Error!Value {
        const ctx = self.sema.?;
        const parts = try self.arena().alloc(Value, tys.len);
        var whole: Value = .{};
        var view_only = true;
        var read_only = true;
        for (tys, parts) |t, *part| {
            part.* = if (self.mayCarryLoan(t)) try self.carryResult(t, result) else .{};
            whole = try self.valueUnion(whole, part.*);
            if (!self.mayCarryLoan(t) or sema.holdsViewOnly(ctx, t)) continue;
            view_only = false;
            if (!self.viewsOnlyRead(t)) read_only = false;
        }
        for (parts, 0..) |a, i| for (a.loans) |l| {
            if (l.kind != .write) continue;
            for (parts, 0..) |b, k| if (k != i) for (b.loans) |m| if (m.root == l.root and self.paths.overlap(m.path, l.path)) {
                try self.err(self.startOf(node), "the results of this call would view `{s}` twice while one of them writes it: a write view is the only view of what it views while it lives", .{self.vars.items[l.root].name});
                self.results_of = .{ .node = node, .parts = parts };
                return whole;
            };
        };
        self.results_of = .{ .node = node, .parts = parts };
        if (view_only) return self.keepViewTemps(temps_start, whole);
        if (read_only) return self.endWriteLends(temps_start, stored, whole);
        return whole;
    }

    /// `q, r = f()`: the call's several results go into the statement's
    /// hidden results var, which holds the loans of every result no
    /// target has taken yet; each target then takes its own, left to
    /// right, as the binding `x = e` it is (`walkSet` of `(set op x _
    /// (result_part))`), so a target is bound only while no result still
    /// pending views it. A result no target takes (`_`) stays in the var,
    /// which the statement's end drops (`dropStmtTemps`), when its drop
    /// runs a `drop` body; any other reads none of its views. This walks
    /// the desugaring: the results statement temporaries, each taken by
    /// its binding (docs/INTERNALS.md, "Several results").
    fn walkDestructure(self: *Checker, node: Sexp) Error!void {
        const value = ir.Destructure.value(node);
        const targets = ir.Destructure.targets(node).items();
        // What a target's store reads is used after the value, as an
        // assignment's target is.
        const mark = self.after_value.items.len;
        for (targets) |t| if (t.isKind(.set)) {
            _ = try self.useAfterValue(t);
        };
        // A write-view local a target re-points never uses its old view
        // again, when the value does not read it and cannot leave early:
        // its loans end before the call lends anew, as for `w = e`.
        if (self.sema) |ctx| if (!leavesEarly(value)) for (targets) |t| {
            if (!t.isKind(.set) or !ctx.repoints(t)) continue;
            const name = self.text(ir.Set.target(t));
            if (self.readsName(value, name)) continue;
            if (self.find(name)) |id| try self.setFlow(id, .{ .status = self.flows.items[id].status, .at = self.flows.items[id].at });
        };
        const saved_results = self.results_of;
        defer self.results_of = saved_results;
        self.results_of = null;
        const temps_start = self.temps.items.len;
        const whole = try self.walkConsumed(value, .binding);
        self.after_value.shrinkRetainingCapacity(mark);
        if (!self.reachable) return;
        const call = resultsCall(value);
        const parts: []const Value = blk: {
            if (self.results_of) |r| if (sameNode(r.node, call) and r.parts.len == targets.len) break :blk r.parts;
            const all = try self.arena().alloc(Value, targets.len);
            @memset(all, whole);
            break :blk all;
        };
        // Which results the statement holds to its end: each a target
        // takes, until it takes it, and each `_` discards whose drop runs
        // a `drop` body, which could read what it views. Any other
        // discarded result uses none of its views (Core sentence 6), so
        // its loans end here, but for those another result keeps.
        const held = try self.arena().alloc(bool, targets.len);
        const tys: []const TypeId = if (self.sema) |ctx| (if (self.exprType(value)) |t| sema.resultsOf(ctx, t) orelse &.{} else &.{}) else &.{};
        var kept: Value = .{};
        for (targets, held, parts, 0..) |t, *h, part, k| {
            h.* = t.isKind(.set) or k >= tys.len or (if (self.sema) |ctx| sema.dropRunsBody(ctx, tys[k]) != .no else true);
            if (h.*) kept = try self.valueUnion(kept, part);
        }
        for (held, parts) |h, part| if (!h) for (part.loans) |l| {
            if (containsLoan(kept.loans, l)) continue;
            var i = @min(temps_start, self.temps.items.len);
            while (i < self.temps.items.len) {
                if (self.temps.items[i].sameAs(l)) _ = self.temps.orderedRemove(i) else i += 1;
            }
        };
        const pos = self.startOf(node);
        const id = try self.addVar(.{ .name = "the call's results", .decl = pos, .ty = self.exprType(value), .kind = .hidden }, .{ .loans = kept.loans });
        try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
        const saved_part = self.part_value;
        defer self.part_value = saved_part;
        for (targets, 0..) |t, j| {
            if (!t.isKind(.set)) continue;
            // The result leaves the temporary for its binding, which keeps
            // the loans of those still pending and of those held to the
            // statement's end.
            var left: Value = .{};
            for (targets, parts, held, 0..) |o, part, h, k| {
                if (k == j or (k < j and o.isKind(.set)) or !h) continue;
                left = try self.valueUnion(left, part);
            }
            try self.setFlow(id, .{ .loans = left.loans });
            if (try self.pendingView(t, targets, parts, held, j)) continue;
            self.part_value = parts[j];
            try self.walkSet(t);
        }
    }

    /// The target of `set` (the `j`th of `targets`) names a binding that
    /// a result still pending views: binding it would change or drop what
    /// that result views (`s, rest = split(?s)`). Reported, true.
    fn pendingView(self: *Checker, set: Sexp, targets: []const Sexp, parts: []const Value, held: []const bool, j: usize) Error!bool {
        const target = ir.Set.target(set);
        if (target != .src) return false;
        const ctx = self.sema orelse return false;
        const sym = ctx.symbolOf(target) orelse return false;
        if (ctx.symbols.items[sym].decl_pos == target.src.pos) return false;
        const id = self.find(self.text(target)) orelse return false;
        for (targets, parts, held, 0..) |o, part, h, k| {
            if (k == j or (k < j and o.isKind(.set)) or !h) continue;
            for (part.loans) |l| if (l.root == id and !l.ext) {
                if (o.isKind(.set)) {
                    try self.err(target.src.pos, "cannot bind `{s}` while `{s}` views it", .{ self.text(target), self.text(ir.Set.target(o)) });
                } else try self.err(target.src.pos, "cannot bind `{s}` while the result `_` discards views it: that result's `drop` body runs at the statement's end", .{self.text(target)});
                return true;
            };
        }
        return false;
    }

    /// A value read in place, by value, before the operands after it run
    /// (`reader`: a call argument, a method's receiver, the value a call
    /// calls, a binary operator's left operand, an indexed value that is
    /// no place), when the value shares storage the place it reads owns
    /// (a List's buffer, a box, a shared handle, a struct holding one;
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
        try self.addTemp(.{ .root = place.root, .path = place.path, .kind = .read, .pos = self.startOf(e), .held_read = reader });
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
            if (self.stmtTempAt(pos)) |id| return .{ .loans = try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos }) };
        };
        var leaves: std.ArrayList(Sexp) = .empty;
        try sema.valueLeaves(self.arena(), base, &leaves);
        var out: Value = .{};
        for (leaves.items) |leaf| {
            const pos = self.startOf(leaf);
            if (self.resolvePlace(leaf)) |p| {
                if (!self.flowLive(p.root)) continue;
                out = try self.valueUnion(out, try self.lendOn(p.root, .{ .root = p.root, .path = p.path, .kind = kind, .pos = pos }));
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
            const held = self.stmtTempAt(pos);
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
        try self.addTemp(.{ .root = place.root, .path = place.path, .kind = .read, .pos = self.startOf(leaf), .held_read = reader });
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

    /// The element type of a call of `copy`, a built-in element method
    /// that stores copies of the elements its argument views.
    fn copiedElem(self: *const Checker, callee: Sexp) ?TypeId {
        const ctx = self.sema orelse return null;
        const ec = ctx.elemCallOf(callee) orelse return null;
        return if (ec.op == .copy) ec.elem else null;
    }

    /// A call of a built-in element method whose elements hold no
    /// view: it stores none of its arguments' views.
    fn storesNothing(self: *const Checker, callee: Sexp) bool {
        const ctx = self.sema orelse return false;
        const ec = ctx.elemCallOf(callee) orelse return false;
        return !self.mayCarryLoan(ec.elem);
    }

    /// A view of a value that copies and carries no loan (`k` with
    /// `k: ?Int`), passed where a value is expected, is read by value
    /// (`sema.copiedThrough`): what it views is not stored.
    fn readsPlainValue(self: *const Checker, e: Sexp) bool {
        const ctx = self.sema orelse return false;
        const arg = if (e.isKind(.kwarg)) ir.Kwarg.value(e) else e;
        const value = sema.copiedThrough(ctx, self.exprType(arg) orelse return false) orelse return false;
        return !self.mayCarryLoan(value);
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
    /// different fields of one value (`swap(!t.left, !t.right)`), two
    /// places, neither of which holds the other (Core sentence 5).
    /// `replace` is `t = <place; place = v` (`takenValue`): its result is
    /// no view of the place.
    fn walkSwapCall(self: *Checker, args: []const Sexp, swap: bool) Error!Value {
        const start = self.temps.items.len;
        const first = try self.walkConsumed(args[0], .argument);
        const lent = self.temps.items.len;
        var saved: std.ArrayList(Loan) = .empty;
        defer saved.deinit(self.gpa);
        if (if (swap) self.sameCollection(args[0], args[1]) else null) |e| {
            // Two elements of one collection: its own `swap` exchanges
            // them. Said once, here.
            try self.err(self.startOf(ir.Write.operand(args[1])), "cannot lend `{s}` to write while a write loan is live: to swap two elements of `{s}`, write `!{s}.swap({s}, {s})`", .{ e.base, e.base, e.base, e.i, e.j });
            try saved.appendSlice(self.gpa, self.temps.items[start..lent]);
            self.temps.shrinkRetainingCapacity(start);
        }
        const second = try self.walkConsumed(args[1], .argument);
        try self.temps.appendSlice(self.gpa, saved.items);
        // What `replace` hands back views what the place's value viewed,
        // and each place now views what went in. A `swap`'s two lends are
        // the ways in, not views stored.
        var result: Value = .{};
        const ty = self.exprType(args[1]);
        if (!swap and self.mayCarryLoan(ty)) result = try self.takenValue(args[0], ty, first) else if (!swap) self.taintGeneric(ty, first);
        // A `swap` stores in each place the value the other held, which
        // carries what that held (`takenValue`).
        const lends = if (swap) try self.unionLoans(first.loans, second.loans) else first.loans;
        const into_first = if (swap) try self.valueUnion(second, try self.takenValue(args[1], self.pointee(self.exprType(args[1])), second)) else second;
        try self.absorbThroughLends(first, into_first, lends, self.startOf(args[1]), null, null);
        if (swap) try self.absorbThroughLends(second, try self.valueUnion(first, try self.takenValue(args[0], self.pointee(self.exprType(args[0])), first)), lends, self.startOf(args[0]), null, null);
        self.temps.shrinkRetainingCapacity(start);
        return result;
    }

    /// What `replace(!p, v)` hands back, as `t = <p; p = v` takes it: the
    /// value that was in `p`, which carries what `p`'s value held and no
    /// loan on `p`, as `walkTake` gives `<p.f`. A place no var holds
    /// (`!f().x`) is known only by the loans of its view.
    fn takenValue(self: *Checker, lend: Sexp, ty: ?TypeId, first: Value) Error!Value {
        const inner = if (lend.isKind(.write)) ir.Write.operand(lend) else lend;
        const place = self.resolvePlace(inner) orelse return self.carry(ty, first);
        return self.carry(ty, self.varValue(place.root));
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
        return diag.textOf(self.source, sp);
    }

    fn isPrint(self: *Checker, callee: Sexp) bool {
        if (callee != .src or !std.mem.eql(u8, self.text(callee), "print")) return false;
        if (self.sema) |ctx| return ctx.symbolOf(callee) == null;
        return self.find("print") == null;
    }

    /// `Cell`, `Signal`, or `List` when a value of type `ty` is one,
    /// through views and shared handles.
    fn builtinName(self: *const Checker, ty: ?TypeId) ?[]const u8 {
        const ctx = self.sema orelse return null;
        var t = ty orelse return null;
        while (true) switch (ctx.types.get(t)) {
            .read_view, .write_view, .shared => |i| t = i,
            .parameterized_nominal => |pn| {
                if (pn.sym == ctx.cell_sym_id) return "Cell";
                if (pn.sym == ctx.signal_sym_id) return "Signal";
                if (pn.sym == ctx.list_sym_id) return "List";
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
        return self.absorbThroughLends(v, stored, v.loans, pos, via, depth);
    }

    /// `absorbThroughWrites`, where `lends` are the lends the store goes
    /// through (`absorbLoans`): `v`'s, and a `swap`'s other place's.
    fn absorbThroughLends(self: *Checker, v: Value, stored: Value, lends: []const Loan, pos: u32, via: ?[]const u8, depth: ?u32) Error!void {
        var level: std.ArrayList(VarId) = .empty;
        try self.appendWriteRoots(&level, v, &.{});
        const d = depth orelse {
            for (level.items) |r| {
                // Only a value that can hold a view can have one stored in it.
                if (!self.mayCarryLoan(self.pointee(self.vars.items[r].ty))) {
                    try self.genericStoreIn(r, stored, pos, 0);
                    continue;
                }
                try self.absorbLoans(r, stored, pos, level.items, via, true, lends);
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
                if (self.callerOwns(r) or self.isGlobal(r)) continue;
                if (c.ref == .write) {
                    try self.appendWriteRoots(&level, self.varValue(r), seen.items);
                } else if (remaining > 1) try self.appendWriteRoots(&next, self.varValue(r), seen.items);
            }
            if (remaining <= 1) break;
            remaining -= 1;
            level = next;
        }
        if (seen.items.len > 64) return self.absorbThroughLends(v, stored, lends, pos, via, null);
        // The write loans that lead from one value reached to the next are
        // lends the store goes through too.
        var through_lends: std.ArrayList(Loan) = .empty;
        try through_lends.appendSlice(self.arena(), lends);
        for (seen.items) |r| for (self.varValue(r).loans) |l| if (l.kind == .write) try through_lends.append(self.arena(), l);
        for (seen.items) |r| {
            if (!self.mayCarryLoan(self.pointee(self.vars.items[r].ty))) {
                try self.genericStoreIn(r, stored, pos, 0);
                continue;
            }
            try self.absorbLoans(r, stored, pos, seen.items, via, false, through_lends.items);
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
    ///
    /// A value never holds a view of itself (Core §5): a loan on a part
    /// of `id` stored into `id` is rejected, but for `lends`, the lends
    /// the store goes through (a write receiver's own, a write argument's,
    /// the write loans held on the way), which are the way in, not views
    /// stored.
    fn absorbLoans(self: *Checker, id: VarId, v_in: Value, pos: u32, through: []const VarId, via: ?[]const u8, deeper: bool, lends: []const Loan) Error!void {
        if (try self.selfViewIn(id, v_in.loans, lends, through)) |l| return self.reportSelfView(id, l, lends, pos, via);
        // A value that holds only Strings keeps only what leads to a String.
        // What lands in a value that holds only Strings needs only what
        // could hold them (`carry`).
        const t = self.pointee(self.vars.items[id].ty);
        const strings = if (self.sema) |ctx| if (t) |inner| sema.holdsViewOnly(ctx, inner) else false else false;
        const v = if (strings) try self.carry(t, v_in) else v_in;
        var out: std.ArrayList(Loan) = .empty;
        for (v.loans) |l| {
            if (l.root != id and std.mem.findScalar(VarId, through, l.root) == null) try out.append(self.arena(), l);
        }
        const c = self.vars.items[id];
        if (self.callerOwns(id) and self.holdsGeneric(t)) self.noteGenericStore(id, pos);
        if (self.callerOwns(id) or self.isGlobal(id)) {
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
        // Only a var that holds a write view writes what its write loans
        // lead to. Any other keeps a write loan only as what it copied
        // out through one (`k.a = r.s`): what is stored in it stays there.
        if (c.ref != .write and !self.mayWrite(c.ty)) return;
        const next = try std.mem.concat(self.arena(), VarId, &.{ through, &.{id} });
        for (held) |l| {
            if (l.kind != .write or std.mem.findScalar(VarId, next, l.root) != null) continue;
            // Only a value that can hold a view can have one stored in it.
            if (!self.mayCarryLoan(self.pointee(self.vars.items[l.root].ty))) continue;
            try self.absorbLoans(l.root, v, pos, next, via, true, try std.mem.concat(self.arena(), Loan, &.{ lends, &.{l} }));
        }
    }

    /// A loan on a part of var `id` that a value carrying `loans` keeps,
    /// directly or through what the vars they are on hold (a view of `r`
    /// keeps what `r` views), but for `lends` and the loans on `through`:
    /// the ways the store goes in (`absorbLoans`). A value never holds a
    /// view of itself (Core §5).
    fn selfViewIn(self: *Checker, id: VarId, loans: []const Loan, lends: []const Loan, through: []const VarId) Error!?Loan {
        // `loans`, then what the vars they are on hold, which is copied
        // only where there is some.
        var seen: std.ArrayList(VarId) = .empty;
        var work: std.ArrayList(Loan) = .empty;
        var i: usize = 0;
        while (true) : (i += 1) {
            const l = if (i < loans.len) loans[i] else if (i - loans.len < work.items.len) work.items[i - loans.len] else break;
            if (l.ext or l.root >= self.vars.items.len) continue;
            if (l.root == id) {
                if (!isLendOf(lends, l)) return l;
                continue;
            }
            const held = self.flows.items[l.root].loans;
            if (held.len == 0 or std.mem.findScalar(VarId, through, l.root) != null or std.mem.findScalar(VarId, seen.items, l.root) != null) continue;
            if (seen.items.len >= 64) break;
            try seen.append(self.arena(), l.root);
            try work.appendSlice(self.arena(), held);
        }
        return null;
    }

    /// A store of view `l` into var `id`, which `l` is a loan on a part
    /// of (`absorbLoans`): the part it went in by is the lend in `lends`
    /// on `id`, if there is one.
    fn reportSelfView(self: *Checker, id: VarId, l: Loan, lends: []const Loan, pos: u32, via: ?[]const u8) Error!void {
        const into_path = for (lends) |x| {
            if (x.root == id and !x.ext) break x.path;
        } else whole_path;
        const into = try self.pathText(id, into_path);
        const viewed = try self.pathText(l.root, l.path);
        if (via != null) {
            try self.err(pos, "cannot store in `{s}` a view of `{s}`: a value never holds a view of itself", .{ into, viewed });
        } else try self.err(pos, "cannot let this call store a view of `{s}` in `{s}`: a value never holds a view of itself", .{ viewed, into });
        try self.noteLoan(l);
    }

    /// Whether var `id` is a parameter whose value is what the caller
    /// lent: a view parameter (`?T`, `!T`), or one holding a write view
    /// (`(!T)?`), which every unwrapping of it (`w?`, `w ?? e`,
    /// `if <w as x`, a call's `!` or `catch`) writes through. A store
    /// a write loan leads to on it lands in what the caller owns, which
    /// outlives this function's own values.
    fn callerOwns(self: *const Checker, id: VarId) bool {
        const v = self.vars.items[id];
        return v.kind == .param and (v.ref != .none or self.carriesWriteView(v.ty));
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
        // `*w` upgrading a weak handle it reads reads it, as a `?self`
        // method reads its receiver; one it takes is moved, as `*<x` moves
        // `x`. The new handle reaches what `w` reaches.
        if (self.sema) |ctx| if (ctx.upgradeOf(node)) |how| {
            const v = if (how == .reads) try self.walk(inner) else try self.walkConsumed(inner, .allocation);
            return if (self.mayCarryLoan(self.exprType(node))) v else .{};
        };
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
                try self.err(sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture `{s}`, which holds a view{s}{s}{s}; capture an owned value, or use a stack closure (`|...|`){s}", .{
                    name,
                    if (l.ext) "" else " of `",
                    if (l.ext) "" else self.vars.items[l.root].name,
                    if (l.ext) "" else "`",
                    staticParamHint(l),
                });
                try self.noteLoan(l);
            }
            value = try self.valueUnion(value, cv);
        }
        // The body may store what one capture views into what a
        // captured write view leads to, as a call may with its
        // arguments: that value now holds those loans. Only a capture
        // that can write leads a store (as for a call's arguments).
        if (!owned and caps.len > 1) for (caps, cap_values.items) |cap, cv| {
            const pos = sema.captureNameNode(cap).?.src.pos;
            if (sema.captureModeOf(cap).? != .cap_write and !self.mayWrite(self.symType(pos))) continue;
            try self.absorbThroughWrites(cv, value, pos, null, null);
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
        if (mode == .cap_read or mode == .cap_write) return (try self.lendVar(id, whole_path, if (mode == .cap_read) .read else .write, pos)) orelse .{};
        if (!try self.checkCapturable(id, pos)) return .{};
        if (self.findLoan(id, whole_path, .write, null)) |l| {
            try self.err(pos, "cannot capture `{s}` while a write loan{s} is live", .{ name, try self.loanOnText(l, whole_path) });
            try self.noteLoan(l);
            return .{};
        }
        // `|+x|` through a view captures a copy or a clone of what the
        // view sees, which keeps what that holds, not the view's loan
        // on it (Core §7, sentence 7).
        const ty = self.symType(pos);
        const through = self.refOfType(v.ty) != .none and self.refOfType(ty) == .none;
        const held = if (through) try self.carry(ty, self.varValue(id)) else self.varValue(id);
        return self.newHandle(pos, name, ty, id, held, mode == .cap_weak);
    }

    // -------------------------------------------------------------------------
    // Return and escape
    // -------------------------------------------------------------------------

    fn walkReturn(self: *Checker, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        // `return a, b`: each part leaves the function as `return x`
        // does, left to right.
        if (value.isKind(.results)) {
            const tys: []const TypeId = if (self.sema) |ctx| (if (self.func.ret_ty) |r| sema.resultsOf(ctx, r) orelse &.{} else &.{}) else &.{};
            for (ir.Results.values(value), 0..) |part, i| {
                const ty: ?TypeId = if (i < tys.len) tys[i] else null;
                try self.walkReturnValue(part, ty);
                // A write view a part hands out as a write view leaves for
                // good, as `<w` would: a later part may not use it again.
                // One read as a value that copies is a copy.
                if (part == .src and ty != null and self.refOfType(ty) == .write) if (self.find(self.text(part))) |id| {
                    if (self.vars.items[id].ref == .write and self.flowLive(id)) try self.markInvalid(id, .moved, part.src.pos);
                };
            }
        } else if (value != .nil) try self.walkReturnValue(value, null);
        _ = try self.exitTo(.{ .exit = .{ .@"return" = value != .nil and self.mayFail(value) } });
        self.reachable = false;
    }

    /// A value leaving the function: a bare local moves out; anything
    /// else must not copy an owning value; views must come from
    /// view parameters.
    /// `part`, for a part of `return a, b`, is the type of the result it
    /// gives, by which its loans are judged (Core sentence 7, per result).
    fn walkReturnValue(self: *Checker, expr: Sexp, part: ?TypeId) Error!void {
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
        const ret = part orelse self.func.ret_ty;
        const may_view = if (part) |t| self.mayCarryLoan(t) else self.func.ret_may_view;
        if (may_view and self.reachable) {
            // A result keeps only the loans its own type could hold.
            const kept = if (part) |t| try self.carry(t, value) else value;
            try self.checkEscape(kept);
            self.recordResult(kept, self.startOf(expr));
        } else if (self.reachable and self.genericType(ret)) {
            self.recordResult(value, self.startOf(expr));
        }
        // A result that holds a value of a type parameter's type may carry,
        // in an instance, whatever reached one (`taintGeneric`).
        if (self.reachable and self.holdsGeneric(ret) and self.func.generic_returned_at == null) self.func.generic_returned_at = self.startOf(expr);
    }

    /// A bare name that leaves the function moves out: a match payload
    /// out of its scrutinee, and an owning value out of its binding, so
    /// deferred code at that exit sees it moved.
    fn returnMoves(self: *const Checker, v: Var) bool {
        if (v.payload_view) return true;
        return self.owningKind(v.ty) != null;
    }

    /// The origins of the function or method declared with name `name`:
    /// which arguments its callers pass loans on from.
    fn declOrigins(self: *const Checker, name: Sexp) sema.Origins {
        const ctx = self.sema orelse return .{};
        if (name != .src) return .{};
        if (self.decl_owner) |owner| {
            const fields = ctx.symbols.items[owner].fields orelse &.{};
            // The first method of its name, unless two share it.
            if (sema.memberIn(ctx, fields, self.text(name), .method)) |i| {
                if (fields[i].decl_pos == name.src.pos) return fields[i].origins;
            }
            for (fields) |f| {
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
        // `w: !Int` copies a number), unless an instance's may.
        const held = self.pointee(self.vars.items[into].ty);
        if (self.holdsGeneric(held)) self.noteGenericStore(into, pos);
        if (!self.mayCarryLoan(held) and !self.genericType(held)) return;
        for (loans) |l| if (l.root != into) if (self.paramOf(l)) |i| {
            const bit = sema.paramBit(i);
            if (self.func.stored & bit == 0) {
                self.func.stored_at[i] = pos;
                self.func.stored_in[i] = self.vars.items[into].name;
            }
            self.func.stored |= bit;
        };
    }

    /// A body passes on only the loans its signature shows (Core
    /// sentence 7): what it returns and stores comes from the parameters
    /// its origins name. `params` are its run-time parameters.
    fn checkOrigins(self: *Checker, what: []const u8, name: Sexp, params: Sexp) Error!void {
        const o = self.func.origins;
        const items = params.items();
        // What reached a value of a type parameter's type is returned and
        // stored wherever such a value is (`taintGeneric`).
        for (0..@min(items.len, @bitSizeOf(sema.ParamMask))) |i| {
            const bit = sema.paramBit(i);
            if (self.func.generic & bit == 0) continue;
            if (self.func.generic_returned_at) |at| if (self.func.returned & bit == 0) {
                self.func.returned |= bit;
                self.func.returned_at[i] = at;
            };
            if (self.func.stored & bit != 0) continue;
            for (self.func.generic_stores[0..self.func.generic_store_count]) |s| if (s.param != i) {
                self.func.stored |= bit;
                self.func.stored_at[i] = s.pos;
                self.func.stored_in[i] = s.name;
                break;
            };
        }
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
                if (o.lent & bit != 0) {
                    // A lent parameter is kept only where `keeps` names it.
                    const into = self.func.stored_in[i];
                    const kept = try self.paramList(items, (o.stores & o.lent) | (self.func.stored & o.lent), false);
                    try self.err(self.func.stored_at[i], "{s} stores a view of `{s}` in `{s}`, which its caller reaches, but its signature does not keep `{s}`; say so: `keeps {s}`", .{ what, pname, into, pname, kept });
                } else try self.err(self.func.stored_at[i], "{s} stores a view of `{s}` where its caller can reach it, but a call of it keeps no loan of `{s}`: its type cannot hold what the write parameters hold", .{ what, pname, pname });
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
                try self.noteStringViewOfString(l, self.func.ret_ty);
                continue;
            }
            try self.err(l.pos, "cannot return a view of `{s}`, which this function was not lent", .{r.name});
            try self.note(r.decl, "`{s}` is local to this {s}", .{ r.name, if (self.func.in_closure) "closure" else "function" });
            try self.noteStringViewOfString(l, self.func.ret_ty);
        }
    }

    // -------------------------------------------------------------------------
    // Branches
    // -------------------------------------------------------------------------

    fn walkIf(self: *Checker, node: Sexp) Error!Value {
        const t = self.takeTail(node);
        const cond = ir.If.cond(node);
        if (rig.isAsPart(cond) or rig.isConditionJoin(cond)) return self.walkIfBinding(node, t);
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
        const Parts = struct {
            c: *Checker,
            body: Sexp,
            pub fn part(v: @This(), p: Sexp) Error!void {
                return v.c.walkConditionPart(p, v.body);
            }
        };
        try rig.eachGuardPart(cond, Parts{ .c = self, .body = body });
    }

    /// One part of a condition (`rig.eachGuardPart`).
    fn walkConditionPart(self: *Checker, cond: Sexp, body: Sexp) Error!void {
        // Each part is a header, its own statement: its temporaries end
        // with it, after the binding takes what it binds.
        if (cond.isKind(.as_results)) return self.walkResultsBinding(cond, body);
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
        const v1 = try self.walkPayloadHolder(node, ir.Catch.value(node));
        const handler = ir.Catch.handler(node);
        try self.holdPartTemps(handler);
        const base = try self.here();
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
        const v1 = try self.walkPayloadHolder(node, ir.@"??".left(node));
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
        /// The place of `root` the subject is (`resolvePlace`), which its
        /// bindings view.
        place: PathId = whole_path,
        /// The subject as written, when no var holds the value it reads
        /// (`Var.matched`); empty when the match takes it.
        shown: []const u8 = "",
    };

    /// Whether `match` takes its subject, and its bindings own what they
    /// bind: `match <x`, or a value made there (`storage.matchMode`).
    fn takesSubject(self: *const Checker, match: Sexp) bool {
        const ctx = self.sema orelse return ir.Match.subject(match).isKind(.move);
        return storage.matchMode(ctx, match) == .consume;
    }

    /// Whether a `match` reads the value its subject `e` gives where
    /// another value holds it (`Hands`): storage, a lend, a branching
    /// value that may be a name's, or a view a call returns. A value
    /// made there is the match's own.
    fn readsInPlace(self: *const Checker, e: Sexp) bool {
        return switch (self.hands(e).kind) {
            .place, .part_of_made, .lend, .branches => true,
            .made => if (self.exprType(e)) |t| self.typeData(t) == .read_view or self.typeData(t) == .write_view else false,
            .jump, .none => false,
        };
    }

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
            info.place = p.path;
            const v = self.vars.items[p.root];
            if (p.through_view or v.payload_view) info.via = .viewed;
            if (p.through_shared) info.via = .shared;
            if (self.exprType(node)) |t| if (self.typeData(t) == .shared) {
                info.via = .shared;
            };
            if (!p.whole) info.path = try self.placeText(node);
        } else if (!self.takesSubject(match) and self.readsInPlace(scrut)) {
            // A value no var holds, which the match reads where it is:
            // its bindings view it, as they view a place.
            info.via = .viewed;
            if (self.exprType(node)) |t| if (self.typeData(t) == .shared) {
                info.via = .shared;
            };
            info.shown = self.spanText(node);
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
        if (self.sema) |ctx| if (storage.holdsView(ctx, match)) {
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
        const past = resumeAt(.nil, match);
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
                failed = try self.exitTo(.{ .to = base, .resume_at = resumeBefore(if (i + 1 < arms.len) arms[i + 1] else .nil, past) });
            }
            // The arm is chosen: the subject is read no more.
            if (self.flows.items[hold].loans.len > 0) try self.setFlow(hold, .{});
            // The body is a statement of its own (`sema.isArmBody`): its
            // temporaries end with it, in the arm's scope.
            var v = try self.walkTailStmt(body, tail_ctx);
            v = try self.checkValueEscapesScope(v);
            try self.popScope();
            value = try self.valueUnion(value, v);
            const s = try self.leave(base, past);
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
                    const ctx = self.sema orelse return false;
                    for (ctx.payloadBindings(pattern) orelse &.{}) |b| {
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
        // The bytes of a String field are a view of it, as any read view of
        // a field is, though a `?String` copies.
        const text_view = if (self.sema) |ctx| (if (ctx.payloadFieldOf(node)) |field| sema.viewsStringBytes(ctx, field, ty orelse sema.type_invalid) else false) else false;
        var v: Var = .{ .name = self.text(node), .decl = pos, .ty = ty, .kind = .pattern, .ref = if (text_view) .read else self.refOfType(ty) };
        var loans: []const Loan = &.{};
        // A payload that copies (`sema.copies`) is copied out of the
        // matched value, which stays whole. A view the match makes of a
        // field (`match ?e`) views the matched value instead.
        const copied = self.copies(ty) and v.ref == .none;
        // A copy views what the matched value views.
        if (copied and !self.mayCarryLoan(ty)) self.taintGeneric(ty, scrut_value);
        if (copied and self.mayCarryLoan(ty)) {
            const r_loans: []const Loan = if (info.root) |r| self.flows.items[r].loans else &.{};
            loans = (try self.carry(ty, .{ .loans = try self.unionLoans(scrut_value.loans, r_loans) })).loans;
        } else if (!copied) {
            // The binding views the matched value unless the match takes
            // it: a place's (`alias_of`), or one no var holds, which a
            // binding of a view type views by its type, and any other
            // (a `T` of a generic body) by this fact.
            v.payload_view = info.root != null or (info.shown.len > 0 and v.ref == .none);
            if (info.root == null and v.payload_view) {
                v.via = info.via;
                v.matched = info.shown;
            }
            if (info.root) |r| {
                v.alias_of = r;
                v.alias_path = info.path;
                v.via = info.via;
                // The binding views the matched value: its root stays
                // viewed (lent to write when the view holds a write
                // view, which must not be reached twice), and a viewed
                // root lends what it holds.
                loans = try self.oneLoan(.{ .root = r, .path = info.place, .kind = if (self.carriesWriteView(ty)) .write else .read, .pos = pos });
                if (info.via == .viewed) loans = try self.unionLoans(loans, self.flows.items[r].loans);
            } else {
                loans = scrut_value.loans;
            }
        }
        // A read match's binding that is no plain data of a subject emit
        // matches as a copy (not `storage.matchesInPlace`) is usable
        // within its arm only, so a view of it never outlives the copy
        // (docs/INTERNALS.md, "Header subjects").
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
        /// The place of `source_root` the source is (`resolvePlace`).
        source_path: PathId = whole_path,
        /// `for x in <v`, or a collection the source makes: the loans it
        /// held, which its elements carry.
        moved: []const Loan = &.{},
        source_loan: LoanKind = .read,
        source_pos: u32 = 0,
        resource_list: bool = false,
        /// The loop walks a collection it does not consume.
        elem_view: bool = false,
    };

    /// `if f() as a, b`: each name is a new binding that takes its result,
    /// as a destructure's target does (`walkDestructure`), in a scope over
    /// `body`, which the caller pops. The loans taken to make the results
    /// end with the header, as `as`'s do, and so do those of a result no
    /// name takes.
    fn walkResultsBinding(self: *Checker, cond: Sexp, body: Sexp) Error!void {
        const value = ir.AsResults.value(cond);
        const names = ir.AsResults.names(cond).items();
        const temps_start = self.temps.items.len;
        const drops = self.stmt_drops.items.len;
        const saved_results = self.results_of;
        defer self.results_of = saved_results;
        self.results_of = null;
        const whole = try self.walkConsumed(value, .binding);
        const parts: []const Value = blk: {
            if (self.results_of) |r| if (sameNode(r.node, value) and r.parts.len == names.len) break :blk r.parts;
            const all = try self.arena().alloc(Value, names.len);
            @memset(all, whole);
            break :blk all;
        };
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        try self.pushScopeFor(.block, body);
        const saved_part = self.part_value;
        defer self.part_value = saved_part;
        for (names, parts) |n, part| {
            if (!n.isKind(.set)) continue;
            self.part_value = part;
            try self.walkSet(n);
        }
        try self.dropStmtTemps(drops);
    }

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
            .cond_binds = rig.isAsPart(cond) or rig.isConditionJoin(cond),
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
        // A source the loop consumes (`storage.forConsumes`) is taken,
        // as emit hands its elements over.
        const consumes = if (self.sema) |ctx| storage.forConsumes(ctx, node) else false;
        if (mode == .move) {
            spec.moved = (try self.walkMove(source)).loans;
        } else if (header == .taken or consumes) {
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
                spec.source_path = p.path;
                spec.source_loan = kind;
                spec.source_pos = self.startOf(source);
                spec.resource_list = if (self.sema) |ctx| sema.forViewsSlot(ctx, node) else false;
                if (!self.flowLive(id) or try self.conflicts(id, p.path, if (kind == .write) .write else .read, spec.source_pos)) {
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
    /// `raw` block, which `break @name` leaves.
    fn walkLabeled(self: *Checker, node: Sexp) Error!Value {
        const stmt = ir.Labeled.stmt(node);
        if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) {
            self.pending_reads = self.readsValue(node);
            const v = try self.walk(stmt);
            self.pending_reads = false;
            return v;
        }
        var ctx: LoopCtx = .{ .node = stmt, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .is_loop = false };
        self.loop = &ctx;
        defer self.loop = ctx.parent;
        try self.walkStmt(stmt);
        try self.joinAt(ctx.point, ctx.breaks.items, resumeAt(.nil, node));
        return .{};
    }

    fn walkLoop(self: *Checker, spec: LoopSpec) Error!Value {
        var ctx: LoopCtx = .{ .node = spec.node, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .start = extent(spec.node).lo, .reads = self.pending_reads or self.readsValue(spec.node) };
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
        ctx.step_conts.clearRetainingCapacity();
        ctx.step_point = null;
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
        // The loop is `while true { x = a or break; body: { body }; step }`
        // (docs/INTERNALS.md, "Loops"): a `continue` in the body leaves
        // the body's block for the step. A step that runs after the body
        // (`storage.StepPoint`) runs in the bindings' scope, after the
        // body's own scope ends; any other runs after the bindings' scope
        // ends.
        const step_inside = if (self.sema) |sctx| spec.node.isKind(.@"while") and storage.stepPoint(sctx, spec.node) == .after_body else false;
        if (step_inside) {
            ctx.step_point = try self.here();
            ctx.step_depth = self.scopes.items.len;
        }
        try self.pushScopeFor(.block, spec.body);
        try self.bindLoopElems(spec);
        try self.walkStmt(spec.body);
        if (step_inside) {
            while (self.scopes.items.len > ctx.step_depth) try self.popScope();
            if (ctx.step_conts.items.len > 0) try self.joinAt(ctx.step_point.?, ctx.step_conts.items, stepAt(spec.node));
            ctx.step_point = null;
            try self.walkStep(spec.cont.?, spec.node);
        }
        while (self.scopes.items.len > depth) try self.popScope();

        // A `continue` and the end of the body go back to the loop's
        // head through any other step, as does a `continue` in the
        // condition (which the type checker rejects when the step runs
        // after the body, since it would skip binding what the step
        // reads); a `continue` in the step ends it.
        if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items, ctx.start);
        if (!step_inside) if (spec.cont) |c| {
            ctx.conts.clearRetainingCapacity();
            try self.walkStep(c, spec.node);
            if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items, ctx.start);
        };
        return .{ .back = try self.exitTo(.{ .to = ctx.point, .resume_at = ctx.start }), .exit = exit };
    }

    /// Walk the step of `while` loop `node`, which runs after its body
    /// (`stepAt`).
    fn walkStep(self: *Checker, step: Sexp, node: Sexp) Error!void {
        const saved = self.step_at;
        defer self.step_at = saved;
        if (saved == null) self.step_at = stepAt(node);
        try self.walkStmt(step);
    }

    fn bindLoopElems(self: *Checker, spec: LoopSpec) Error!void {
        var elem_loans: []const Loan = &.{};
        if (spec.source_root) |root| if (self.flowLive(root)) {
            // The source stays lent for the whole loop.
            elem_loans = try self.oneLoan(.{ .root = root, .path = spec.source_path, .kind = spec.source_loan, .pos = spec.source_pos });
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
                .loop_view = spec.resource_list,
                .elem_view = spec.elem_view,
                .elem_of = if (elem_loans.len > 0) spec.source_root else null,
            }, .{ .loans = if (self.mayCarryLoan(ty)) try self.unionLoans(elem_loans, spec.moved) else self.taintedNone(ty, .{ .loans = try self.unionLoans(elem_loans, spec.moved) }) });
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
    /// flows to where the jump goes, as the type checker resolved it
    /// (`sema.JumpDest`): past the construct it names, to the loop's step,
    /// or to the loop's head.
    fn walkJump(self: *Checker, node: Sexp, jump: Jump) Error!void {
        const value = if (jump == .brk) ir.Break.value(node) else .nil;
        const dest = if (self.sema) |ctx| ctx.jumpDestOf(node) else null;
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
        const moved = if (target) |t| try self.breakMovesName(value, t.point.vars) else null;
        const v: Value = if (value == .nil) .{} else if (moved) |id|
            (if (self.vars.items[id].payload_view) try self.movePayload(id, value.src.pos, "move") else try self.moveVar(id, value.src.pos, .move))
        else
            try self.walkConsumed(value, .brk);
        self.value_reads = false;
        const t = target orelse {
            // The type checker resolves every jump of a module it accepts.
            try self.errSpan(self.stmtSpan(node), "internal error: this `{s}` goes to no construct the checker is walking", .{if (jump == .brk) "break" else "continue"});
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
        t.value = try self.valueUnion(t.value, try self.escapeVarsFrom(v, t.point.vars));
        // A `continue` to a step that runs in the condition's bindings'
        // scope goes to that point; any other goes back to the loop's
        // head, through a step that is the loop's continue expression.
        const to_step = if (dest.?.to == .step) t.step_point else null;
        const s = try self.exitTo(.{ .to = to_step orelse t.point, .exit = .{ .jump = if (to_step != null) t.step_depth else t.scope_depth } });
        switch (dest.?.to) {
            .exit => try t.breaks.append(self.arena(), s),
            .step, .head => try (if (to_step != null) &t.step_conts else &t.conts).append(self.arena(), s),
        }
        try self.after_value.appendSlice(self.gpa, kept);
        self.reachable = false;
    }

    /// The binding `break value` moves out: a bare name declared since
    /// the loop's entry (`vars`), so its scope ends at this `break`,
    /// whose value owns, as `return x` moves one (`returnMoves`).
    fn breakMovesName(self: *Checker, value: Sexp, vars: u32) Error!?VarId {
        if (value != .src) return null;
        const id = self.boundVar(value) orelse return null;
        if (id < vars) return null;
        const v = self.vars.items[id];
        if (v.closure or v.loop_view or v.capture_resource or v.alias_of != null or !self.returnMoves(v)) return null;
        try self.checkNoImplicitCopy(value, .brk, true);
        return id;
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
        try self.defer_loops.append(self.gpa, self.loop);
        self.loop = null;
        self.in_defer = true;
        try self.walkStmt(body);
        _ = self.defer_loops.pop();
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
            .src => |s| rig.leafText(self.source, s),
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

    /// Whether `ty` is a view (`sema.isViewType`).
    fn isView(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.isViewType(ctx, ty orelse return false);
    }

    /// The type a view type refers to.
    fn pointee(self: *const Checker, ty: ?TypeId) ?TypeId {
        const t = ty orelse return null;
        return switch (self.typeData(t)) {
            .read_view, .write_view => |inner| inner,
            else => t,
        };
    }

    /// A value copied implicitly where it is used (`sema.copies`):
    /// not one whose copying depends on a type parameter.
    fn copies(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.copies(ctx, ty orelse return false) == .yes;
    }

    /// A view whose value is copied out where its context reads it
    /// (`sema.copiedThrough`).
    fn copiedThrough(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.copiedThrough(ctx, ty orelse return false) != null;
    }

    /// A scalar (`sema.isScalar`: a number, `Bool`, `?String`, or a
    /// vector), or an error. A method call takes any other receiver by
    /// address, so a later argument must not change it before the call
    /// reads it.
    fn isScalar(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return sema.isScalar(ctx, t) or ctx.types.get(t) == .any_error;
    }

    /// A `String`, whose bytes a `?String` may view.
    fn isString(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return t == ctx.types.string_id or sema.boxedType(ctx, t) == ctx.types.string_id;
    }

    /// A `List[T]`.
    fn isList(self: *const Checker, ty: TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ctx.types.get(ty);
        return t == .parameterized_nominal and t.parameterized_nominal.sym == ctx.list_sym_id;
    }

    /// A List (or a view of one) whose elements move (`sema.moves`):
    /// walked by a view of each slot.
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
        if (!sema.typeHasDropGlue(ctx, t) and sema.isUnique(ctx, t)) {
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
            .string => .text,
            .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id) .list else if (pn.sym == ctx.box_sym_id) .box else .{ .drop_glue = name },
            else => .{ .drop_glue = name },
        };
    }

    /// Whether a value of this type can hold a marked view, or a `?String` that
    /// may view a String. Unknown types are assumed to.
    fn mayCarryLoan(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return true;
        return sema.mayHoldView(ctx, ty orelse return true);
    }

    /// Whether a value of `ty` may hold a view, here or in an instance.
    fn mayHoldInInstance(self: *const Checker, ty: ?TypeId) bool {
        return self.mayCarryLoan(ty) or self.genericType(ty);
    }

    /// A store of `stored` in what var `id` leads to, a type that holds a
    /// type parameter (`genericType`), whose loans a generic body does not
    /// track: a parameter the caller lent is noted as holding them
    /// (`noteGenericStore`, `recordStore`), through the write views a
    /// local holds.
    fn genericStoreIn(self: *Checker, id: VarId, stored: Value, pos: u32, depth: u32) Error!void {
        if (depth > 16 or !self.holdsGeneric(self.pointee(self.vars.items[id].ty))) return;
        const c = self.vars.items[id];
        if (c.kind == .param and c.ref != .none) {
            var out: std.ArrayList(Loan) = .empty;
            for (stored.loans) |l| if (l.root != id and !self.isLocalLoan(l)) try out.append(self.arena(), l);
            self.recordStore(id, out.items, pos);
            return;
        }
        for (self.flows.items[id].loans) |l| {
            if (l.kind == .write and l.root != id) try self.genericStoreIn(l.root, stored, pos, depth + 1);
        }
    }

    /// Whether `ty` holds a type parameter by value and so may hold a view
    /// in an instance, though a generic body tracks no loan in a value of
    /// it (SPEC "Generic bodies"): what reaches one is recorded for the
    /// body check instead (`taintGeneric`, `noteGenericStore`).
    fn genericType(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        const t = ty orelse return false;
        return !sema.mayHoldView(ctx, t) and sema.holdsTypeParam(ctx, t);
    }

    /// Whether a value of `ty` may hold a value of a type parameter's
    /// type (`sema.holdsTypeParam`), which a generic body tracks no loan
    /// in.
    fn holdsGeneric(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.holdsTypeParam(ctx, ty orelse return false);
    }

    /// `v`'s loans reach a value of type `ty`, which a generic body keeps
    /// no loan in (`genericType`): the parameters they are on may be
    /// returned or stored wherever such a value is (`checkOrigins`).
    fn taintGeneric(self: *Checker, ty: ?TypeId, v: Value) void {
        if (v.loans.len == 0 or !self.genericType(ty)) return;
        for (v.loans) |l| if (self.paramOf(l)) |i| {
            self.func.generic |= sema.paramBit(i);
        };
    }

    /// No loans, for a value of `ty` that carries none, after `v`'s reach
    /// it (`taintGeneric`).
    fn taintedNone(self: *Checker, ty: ?TypeId, v: Value) []const Loan {
        self.taintGeneric(ty, v);
        return &.{};
    }

    /// The body stores, at `pos`, a value whose type mentions a type
    /// parameter in what parameter var `into` leads to: whatever reached
    /// such a value may be stored there (`checkOrigins`).
    fn noteGenericStore(self: *Checker, into: VarId, pos: u32) void {
        const i = self.vars.items[into].param_index orelse return;
        for (self.func.generic_stores[0..self.func.generic_store_count]) |s| if (s.param == i) return;
        if (self.func.generic_store_count == self.func.generic_stores.len) return;
        self.func.generic_stores[self.func.generic_store_count] = .{ .param = i, .pos = pos, .name = self.vars.items[into].name };
        self.func.generic_store_count += 1;
    }

    /// The type a value of type `ty` reaches through its views.
    fn reachedType(self: *const Checker, ty: ?TypeId) ?TypeId {
        const ctx = self.sema orelse return ty;
        return sema.unwrapViews(ctx, ty orelse return null);
    }

    /// Whether a value of type `ty` may write what it reaches: it holds a
    /// write view, or its type is not known.
    fn mayWrite(self: *const Checker, ty: ?TypeId) bool {
        return ty == null or self.sema == null or self.carriesWriteView(ty);
    }

    /// Whether a value of this type holds a write view, which must not
    /// be duplicated.
    fn carriesWriteView(self: *const Checker, ty: ?TypeId) bool {
        const ctx = self.sema orelse return false;
        return sema.holdsWriteView(ctx, ty orelse return false);
    }

    /// A bracket list of compile-time arguments (`List[Int]`, `max[Int]`),
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

    /// Place `path` of var `root`, as the source names it (`p.a.b`).
    fn pathText(self: *Checker, root: VarId, path: PathId) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena(), self.vars.items[root].name);
        try self.paths.appendText(self.arena(), &out, path);
        return out.items;
    }

    fn placeText(self: *Checker, e: Sexp) Error![]const u8 {
        switch (e) {
            .src => return self.text(e),
            .list => switch (e.kind() orelse return "expression") {
                .member => return self.arena().print("{s}.{s}", .{ try self.placeText(ir.Member.object(e)), self.text(ir.Member.name(e)) }),
                .index => return self.arena().print("{s}[{s}]", .{ try self.placeText(ir.Index.object(e)), self.spanText(ir.Index.index(e)) }),
                // A sigil: the place it wraps.
                .read, .write, .move, .clone, .share, .box, .weak => return self.placeText(ir.get(e, .operand)),
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

/// The call a destructure's value is: alone, or under `!`, `?`, or a
/// fallback that jumps.
fn resultsCall(value: Sexp) Sexp {
    return switch (value.kind() orelse return .nil) {
        .call => value,
        .propagate, .propagate_none => ir.get(value, .value),
        .@"??" => ir.@"??".left(value),
        .@"catch" => ir.Catch.value(value),
        else => .nil,
    };
}

fn isLambda(s: Sexp) bool {
    return s.isKind(.lambda);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Whether `l` is on the place of one of `lends`, whatever its kind: a
/// lend a store goes through, which a view that only reads it keeps as a
/// read loan (`carryLoan`).
fn isLendOf(lends: []const Loan, l: Loan) bool {
    for (lends) |x| if (x.root == l.root and x.path == l.path and !x.ext) return true;
    return false;
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

/// The same IR node: the same leaf, or the same list.
fn sameNode(a: Sexp, b: Sexp) bool {
    return switch (a) {
        .src => |s| b == .src and b.src.pos == s.pos,
        .list => b == .list and a.items().ptr == b.items().ptr,
        else => false,
    };
}

/// Whether loop (or labeled block) `outer` is `inner` or encloses it.
fn encloses(outer: *const LoopCtx, inner: ?*const LoopCtx) bool {
    var l = inner;
    while (l) |ctx| : (l = ctx.parent) if (ctx == outer) return true;
    return false;
}

/// Where the step of `while` loop `node` runs: after its body.
fn stepAt(node: Sexp) u32 {
    return extent(ir.While.body(node)).hi +| 1;
}

/// Where a path that skips the rest of `node` goes on: at `next`, a
/// later part of it, or else past its end.
fn resumeAt(next: Sexp, node: Sexp) u32 {
    return resumeBefore(next, extent(node).hi +| 1);
}

/// Where a path that skips to `next` goes on, in a node whose end is
/// `past` (`resumeAt` with that node's end found once).
fn resumeBefore(next: Sexp, past: u32) u32 {
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
    /// The program's facts, for a test checked with them (`checkWithSema`).
    ctx: ?*sema.SemContext = null,

    fn deinit(self: *TestRig) void {
        self.checker.deinit();
        if (self.ctx) |ctx| {
            ctx.deinit();
            std.testing.allocator.destroy(ctx);
        }
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

/// Check `source` as the compiler does: sema first, whose facts the
/// ownership checker reads (the jumps' destinations among them).
fn checkWithSema(source: []const u8) !TestRig {
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    errdefer p.deinit();
    const tree = try p.parseProgram();
    const ctx = try a.create(sema.SemContext);
    errdefer a.destroy(ctx);
    ctx.* = try sema.check(a, source, tree, .{});
    errdefer ctx.deinit();
    if (ctx.hasErrors()) {
        for (ctx.diagnostics.items) |d| std.debug.print("sema: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
    var c = try Checker.initWithSema(a, source, ctx);
    errdefer c.deinit();
    try c.check(tree);
    return .{ .parser_obj = p, .checker = c, .ctx = ctx };
}

/// The declarations the loop tests below call.
const loop_prelude =
    \\obj R unique
    \\  n: Int
    \\
    \\fun make() -> R
    \\  R(n: 1)
    \\
    \\sub eat(r: R)
    \\  print(r.n)
    \\
    \\sub look(r: ?R)
    \\  print(r.n)
    \\
    \\fun go() -> Bool
    \\  true
    \\
    \\fun done() -> Bool
    \\  false
    \\
;

fn expectCleanWithSema(source: []const u8) !void {
    var t = try checkWithSema(source);
    defer t.deinit();
    if (t.checker.hasErrors()) {
        for (t.checker.diagnostics.items) |d| std.debug.print("unexpected: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
}

fn expectErrorWithSema(source: []const u8, needle: []const u8) !void {
    var t = try checkWithSema(source);
    defer t.deinit();
    if (!t.hasError(needle)) {
        std.debug.print("expected error containing \"{s}\"; got:\n", .{needle});
        for (t.checker.diagnostics.items) |d| std.debug.print("  {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
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
    try expectCleanWithSema(loop_prelude ++
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
    try expectErrorWithSema(loop_prelude ++
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
    try expectErrorWithSema(loop_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    if done()
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
        \\  <b
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
        \\  <h
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
        \\  <rc
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

/// The article before a type's name in a message: "an `Int`", "an
/// `R`" (said "ar").
fn article(name: []const u8) []const u8 {
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
