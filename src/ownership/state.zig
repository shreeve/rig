//! The ownership checker's abstract state: vars, flows, loans, and their
//! join, and the `Checker` that holds them. Each other file of
//! src/ownership/ holds its part of the checker as functions whose first
//! parameter is the `*Checker`; docs/internals/INTERNALS.md ("Ownership")
//! says which file holds what.

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const diag = @import("../diag.zig");
const self_check = @import("build_options").self_check;
const Sexp = parser.Sexp;
const ir = parser.ir;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const Diagnostic = diag.Diagnostic;
const Error = std.mem.Allocator.Error;
const live = @import("live.zig");
const transfer = @import("transfer.zig");
const rules = @import("rules.zig");
const exits = @import("exits.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Place = transfer.Place;

pub const VarId = u32;

/// Which loans a query looks for: any, or only write loans.
pub const LoanQuery = enum { any, write };

pub const LoanKind = enum(u1) { read, write };

/// The part of a var a place names: the fields after the name (Core §5,
/// "A field is a place of its own"), decided by `resolvePlace` and kept
/// interned in `Paths`. `whole_path` is the var itself.
pub const PathId = u32;

pub const whole_path: PathId = 0;

/// The paths of the places the checker has met: a trie of fields, so a
/// path is a number and its prefixes are its ancestors.
pub const Paths = struct {
    /// The path `i + 1`: its parent and its last field.
    nodes: std.ArrayList(Node) = .empty,
    index: std.HashMapUnmanaged(Key, PathId, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Each field step's path, by its node: decided by syntax and types
    /// alone, so `resolvePlace` classifies a step once (`extendsPath`).
    steps: std.AutoHashMapUnmanaged(u32, Step) = .empty,

    const Step = struct { path: PathId, ended: bool };

    /// A path is cut at this many fields, which only adds conflicts.
    pub const max_depth = sema.max_path_fields;

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

    pub fn deinit(self: *Paths, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.index.deinit(gpa);
        self.steps.deinit(gpa);
    }

    /// The path `parent` and then `field`.
    pub fn child(self: *Paths, gpa: std.mem.Allocator, parent: PathId, field: []const u8) Error!PathId {
        const gop = try self.index.getOrPut(gpa, .{ .parent = parent, .field = field });
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.index.removeByPtr(gop.key_ptr);
        try self.nodes.append(gpa, .{ .parent = parent, .field = field, .depth = self.depth(parent) + 1 });
        gop.value_ptr.* = @intCast(self.nodes.items.len);
        return gop.value_ptr.*;
    }

    pub fn depth(self: *const Paths, p: PathId) u8 {
        return if (p == whole_path) 0 else self.nodes.items[p - 1].depth;
    }

    /// Two places of one var conflict when one path is a prefix of the
    /// other (Core sentence 5): `p` and `p.a`, `p.a` and `p.a.b`, but not
    /// `p.a` and `p.b`.
    pub fn overlap(self: *const Paths, a: PathId, b: PathId) bool {
        var x = a;
        var y = b;
        while (self.depth(x) > self.depth(y)) x = self.nodes.items[x - 1].parent;
        while (self.depth(y) > self.depth(x)) y = self.nodes.items[y - 1].parent;
        return x == y;
    }

    /// Whether path `p` is `of` or below it: `p.a.b` is within `p.a`.
    pub fn within(self: *const Paths, p: PathId, of: PathId) bool {
        var x = p;
        while (self.depth(x) > self.depth(of)) x = self.nodes.items[x - 1].parent;
        return x == of;
    }

    /// Append the fields of path `p`, each after a `.`, to `out`.
    pub fn appendText(self: *const Paths, a: std.mem.Allocator, out: *std.ArrayList(u8), p: PathId) Error!void {
        if (p == whole_path) return;
        const n = self.nodes.items[p - 1];
        try self.appendText(a, out, n.parent);
        try out.append(a, '.');
        try out.appendSlice(a, n.field);
    }
};

/// What reads a value in place before the operands after it run: a call
/// argument, a method's self, the value a call calls, the left
/// operand of a binary operator, or a value that is no place being
/// indexed (see `holdRead`).
pub const Reader = enum(u3) { none, argument, self, callee, operand, base };

pub const Loan = struct {
    root: VarId,
    /// The place of the root the loan is on (`resolvePlace`).
    path: PathId = whole_path,
    kind: LoanKind,
    /// Source position of the view, for diagnostics.
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
    /// A write view that a view which only reads it keeps as a read loan
    /// (`carryLoan`), for diagnostics.
    read_of_write: bool = false,
    /// A write self's view, a read loan until its call starts (Core
    /// §6), for diagnostics.
    reserved: bool = false,
    /// A loan on a binding that holds a write view, made by a view
    /// through it (`!s.value` with `s: !Slot`; `throughBinding`): it
    /// keeps the binding unused while the view lives, and ends with the
    /// binding's scope, since the binding's own loans cover what the
    /// view sees (Core sentence 7). So it is never reported as leaving
    /// its scope or the function.
    deref: bool = false,

    pub fn sameAs(a: Loan, b: Loan) bool {
        return a.root == b.root and a.path == b.path and a.kind == b.kind and a.ext == b.ext and a.frame == b.frame and a.deref == b.deref;
    }
};

pub const Status = enum(u2) { live, moved, dropped };

/// A field moved out of a var that owns an object (Core §5, "A field of
/// an owned object moves like a name"): its path, and where it moved.
pub const Part = struct { path: PathId, at: u32 };

/// The flow-sensitive part of a var: joined at merges, compared for the
/// loop fixpoint.
pub const Flow = struct {
    status: Status = .live,
    /// Position of the move or drop that produced `status`.
    at: u32 = 0,
    /// Loans held by the var's current value. Arena-owned, immutable.
    loans: []const Loan = &.{},
    /// The fields moved out of a live var, until each is assigned again:
    /// the var is partly moved. Arena-owned, immutable.
    parts: []const Part = &.{},
    /// The optional fields known to hold `none`: taken with `<p.f` on
    /// every path here, and neither written nor given a write view since
    /// (`noneAt`). An assignment to one drops no old value
    /// (`SemContext.old_nones`). Arena-owned, immutable.
    nones: []const PathId = &.{},
};

pub const VarKind = enum { local, param, capture, pattern, loop_elem, hidden };

/// How a var refers to its value: owned, or through a view.
pub const Ref = enum { none, read, write };

/// How a match payload binding reaches the scrutinee.
pub const Via = enum { owned, viewed, shared };

pub const Var = struct {
    name: []const u8,
    decl: u32,
    /// For a binding of a match that reads a place, the place as
    /// written: taking it with `<` would give the binding its field to
    /// move (`reportAlias`).
    read_subject: []const u8 = "",
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
    /// A type parameter's value an `as` binds where it stands, inside an
    /// optional a read view reaches (`bindNew`).
    as_view: bool = false,
    /// A loop element: the var holding the collection it walks, whose
    /// loans are the views its elements may hold.
    elem_of: ?VarId = null,
    /// The ctx symbol it binds, for its uses (see `holderLive`).
    sym: ?SymbolId = null,
    /// Resource captured into a closure environment (`|+x|`, `|~x|`,
    /// `|<x|`): the body sees a view of the env slot.
    capture_resource: bool = false,
    /// A parameter written `f: once ?fun() -> T`: a call of it, or a
    /// pass to another `once` parameter, uses it up (`walkCall`).
    once: bool = false,
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
    /// while the call runs (`storage.Var` of life `call`): self
    /// or argument it is given (`holdForCall`).
    call_held: bool = false,
    /// An owning temporary its statement holds (`holdTemp`): in use while
    /// a value in flight views it, or its drop runs a `drop` body.
    temp_value: bool = false,
    /// The copy an API object views (`sema.Erasure.copy`), a local of the
    /// erasing block: the view it copies, as written, and the object's
    /// type, for the error when a loan on it outlives the block.
    erased_of: []const u8 = "",
    erased_view: ?TypeId = null,
    /// The var of the same binding this one hides, for lookup.
    shadows: ?VarId = null,
    via: Via = .owned,
    /// A run-time parameter of the function or closure being checked:
    /// its index in the signature (a method's self is 0).
    param_index: ?u8 = null,
};

pub const ScopeKind = enum {
    block,
    /// A function body. Module-level names stay visible through it.
    function,
    /// A closure body: locals of enclosing functions must be captured.
    closure,
};

pub const Scope = struct {
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
pub const Deferred = struct { body: Sexp, vars: u32, err_only: bool };

/// One change to a var's flow, kept so it can be undone.
pub const Change = struct { id: VarId, old: Flow };

/// A program point to come back to: the length of the change trail and
/// of the var stack there, the temporaries, and whether it is
/// reachable. Branches, loops, and jumps capture their states relative
/// to one, so a state costs what changed since, not the whole scope.
pub const Point = struct {
    trail: u32,
    vars: u32,
    temps: []const Loan,
    reachable: bool,
};

/// The flow of one var in a captured state.
pub const Entry = struct { id: VarId, flow: Flow };

/// The state at a program point, relative to an earlier `Point`: the
/// vars (of those in scope there) whose flow differs from it, sorted by
/// var, plus the temporaries and reachability. States relative to one
/// point are joined and compared only while the current state is that
/// point's.
pub const State = struct {
    changes: []const Entry = &.{},
    temps: []const Loan = &.{},
    reachable: bool = true,
};

/// The abstract value of an expression: the loans it carries.
pub const Value = struct {
    loans: []const Loan = &.{},
};

pub const FnCtx = struct {
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
    /// The expression each was first returned by, so the diagnostic
    /// points at the branch that gives the view (`resultPos`).
    returned_by: [@bitSizeOf(sema.ParamMask)]Sexp = @splat(.nil),
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
    /// A method whose `from` names paths of self (`from @text`): its
    /// self, and those paths, which the loans the caller handed in
    /// through self are tagged with where a place of self is viewed or
    /// read (`tagSelf`), so the body is checked against them.
    self_var: ?VarId = null,
    self_paths: []const PathId = &.{},
    /// The first view of self the body returns, or lets reach a value of
    /// a type parameter's type it returns, outside those paths.
    self_escape: ?SelfEscape = null,
    generic_self_path: ?SelfEscape = null,
    /// The run-time parameters bound so far.
    params: u32 = 0,
    /// Binding run-time parameters (`bindParam`), which get an index.
    binding_params: bool = false,
};

/// A view of self a method returns outside the paths its `from` names:
/// the path, and where.
pub const SelfEscape = struct { path: PathId, at: u32 };

/// `e` without a view or move sigil written on it.
pub fn unsigiled(e: Sexp) Sexp {
    return if (e.isKind(.write) or e.isKind(.read) or e.isKind(.move)) ir.get(e, .operand) else e;
}

/// A store in a generic body, of a value whose type mentions a type
/// parameter, in what parameter `param` leads to.
pub const GenericStore = struct { param: u8, pos: u32, name: []const u8 };

/// A loop, or a labeled block, that `break` / `continue` can leave.
pub const LoopCtx = struct {
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
    /// False for a labeled block: only `break $label` leaves it.
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
pub const AfterValue = struct { sym: SymbolId, loop: ?*LoopCtx };

/// Where a value is being consumed, for alias diagnostics.
pub const Sink = enum {
    binding,
    argument,
    field,
    element,
    allocation,
    box,
    ret,
    brk,

    pub fn text(s: Sink) []const u8 {
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

/// Owning kinds that cannot be copied implicitly.
pub const Owning = union(enum) {
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
pub const Tail = struct {
    /// The node (`if`, `match`, block, ...) consumed by `sink`.
    node: parser.NodeId,
    sink: Sink,
    /// The vars `>= vars` are declared inside the value, after `sink`
    /// checked its names: a tail name among them moves out.
    vars: u32,
};

pub const PlainRequirement = sema.PlainRequirement;

/// A call of a method of a generic type (`Checker.method_calls`): where
/// it is, the method it reaches, self's type and the arguments
/// it gives the type's parameters, and the method of a generic type the
/// call is made in, if any.
pub const MethodCall = struct {
    pos: u32,
    target: sema.FnRef,
    recv: TypeId,
    params: []const sema.SymbolRef,
    args: []const TypeId,
    scope: ?u32,
};

/// A view a call kept (`kept_views`): the callee, the parameter its
/// `keeps` names, and the var the call stored it in.
pub const KeptView = struct { callee: []const u8, param: []const u8, holder: []const u8 };

/// What is done to a var, for a loan conflict.
pub const Access = union(enum) {
    read,
    write,
    /// Moving it (the verb: "move", "move-capture").
    consume: []const u8,
};

pub const ReachKey = struct { holder: TypeId, view: TypeId };

pub const Held = struct { base: Sexp, id: VarId };

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
    sema: *const sema.SemContext,
    /// The same context, through which the instance check of a function
    /// value's type (`PlainRequirement.callable`) makes the type at the
    /// instance's arguments; nothing else is written through it.
    interner: *sema.SemContext,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    vars: std.ArrayList(Var) = .empty,
    /// The innermost var of each binding sema resolved (see
    /// `Var.shadows`).
    syms: std.AutoHashMapUnmanaged(SymbolId, VarId) = .empty,
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
    /// The method of a generic type being walked, by its name's position
    /// (`PlainRequirement.method`).
    method_pos: ?u32 = null,
    /// A call of a function value is storing what it is passed through
    /// one of its write arguments (`genericStoreIn`): the value's type,
    /// where the call is, and that argument's own loans, which are the
    /// path, not something stored.
    held_store: ?struct { callable: TypeId, pos: u32, own: []const Loan } = null,
    /// The calls of methods of generic types this module makes, whose
    /// bodies' requirements are checked at self's type
    /// (`checkMethodCalls`).
    method_calls: std.ArrayList(MethodCall) = .empty,
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
    /// checks can skip a scan for an unviewed var.
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
    /// Every position each symbol is used at (`indexUses`), so a use in
    /// the statement being walked counts only while it is ahead
    /// (`useAhead`).
    uses: std.AutoHashMapUnmanaged(SymbolId, std.ArrayList(u32)) = .empty,
    /// The positions of the uses walked so far in the statements being
    /// walked, each statement's dropped when it ends (`walkStmtValue`).
    walked: std.ArrayList(u32) = .empty,
    /// The uses a consumer being walked reads where it runs, after the
    /// operands that follow them (`storage.isPureArg` parts of a call
    /// that evaluates its arguments first, an assignment's value): walked
    /// only once that consumer is done (`walkLate`).
    late: std.ArrayList(u32) = .empty,
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
    /// The views a call kept because its callee's `keeps` names their
    /// parameter, by where each was made: what a conflict's note says
    /// (`noteLoan`).
    kept_views: std.AutoHashMapUnmanaged(u32, KeptView) = .empty,
    /// The hidden vars holding what the calls being walked keep in
    /// storage of their own (`holdForCall`): each ends when its call
    /// returns (`endCallHeld`).
    call_held: std.ArrayList(VarId) = .empty,
    /// The positions where a `once` parameter is used as it may be: the
    /// callee of a call, or an argument to another `once` parameter.
    once_uses: std.ArrayList(u32) = .empty,
    /// The views of a value in itself reported where a closure being
    /// walked is made (`walkLambda`), as "`into` <- `viewed`": its body's
    /// stores of the same are not reported again.
    closure_self_views: std.ArrayList([]const u8) = .empty,
    /// True while a closure's captures are walked where it is made.
    capturing: bool = false,
    reachable: bool = true,
    /// Non-zero while computing a loop fixpoint: diagnostics suppressed.
    quiet: u32 = 0,

    func: FnCtx = .{},
    /// The body of the function being walked, at whose end its own scope
    /// ends: where a conflict's note says a var of that scope is dropped
    /// (`scopeEnd`).
    fn_body: Sexp = .nil,
    loop: ?*LoopCtx = null,
    /// The loops around each deferred body being walked, innermost
    /// last: `loop` is null at a deferred body's start, so a jump in it
    /// leaves no loop outside it, but the body runs inside those loops,
    /// so liveness (`liveFrom`) still counts them.
    defer_loops: std.ArrayList(?*LoopCtx) = .empty,
    /// Set immediately before walking a lambda literal that sits in an
    /// allowed position (binding RHS, call callee, view argument, `*|...|`).
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
    /// The call being walked reaches its method through an API's witness
    /// (`sema.Dispatch.static`): what its declaration keeps, it stores,
    /// in a value of a type parameter's type too (`genericStoreIn`).
    api_call: bool = false,
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
    /// Each assignment to a field, by its node's id: whether the field
    /// held `none` on every walk that reached it (`Flow.nones`), so its
    /// store drops no old value (`oldNones`).
    old_nones: std.AutoHashMapUnmanaged(u32, OldNone) = .empty,
    /// While a generic body is walked again as at an instance whose
    /// associated type `item` (`S.Item`) may view memory its base owns
    /// (`walkItemInstances`): a value of a type that reaches it is a view
    /// that only reads, which keeps viewed what the call that gave it was
    /// passed.
    item: ?SymbolId = null,
    /// The associated types the calls of the module-level function being
    /// walked give values of (`noteItems`), each walked again so.
    items_seen: std.ArrayList(SymbolId) = .empty,

    // -------------------------------------------------------------------------
    // The checker: its life, and the module it checks
    // -------------------------------------------------------------------------

    /// A checker of `source`, whose names, types, and facts sema has
    /// recorded in `ctx`.
    pub fn init(allocator: std.mem.Allocator, source: []const u8, ctx: *sema.SemContext) Error!Checker {
        const paths = try allocator.create(Paths);
        paths.* = .{};
        var c = Checker{
            .gpa = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .fn_arena_state = std.heap.ArenaAllocator.init(allocator),
            .source = source,
            .paths = paths,
            .sema = ctx,
            .interner = ctx,
        };
        errdefer c.deinit();
        try c.scopes.append(allocator, .{ .start = 0, .kind = .function });
        return c;
    }

    /// The copies this module's generic bodies make, for the modules that
    /// import it (`sema.SemContext.plain_reqs`).
    pub fn ownPlainReqs(self: *const Checker) []const PlainRequirement {
        return self.plain_reqs.items[0..self.own_plain_reqs];
    }

    /// An assignment to a field, and whether the field held `none` on
    /// every walk that reached it.
    pub const OldNone = struct { set: Sexp, none: bool };

    /// The assignments whose old value is `none` wherever they run, for
    /// emit, which drops nothing there (`sema.SemContext.old_nones`).
    pub fn oldNones(self: *const Checker, gpa: std.mem.Allocator) Error![]const Sexp {
        var out: std.ArrayList(Sexp) = .empty;
        var it = self.old_nones.valueIterator();
        while (it.next()) |o| if (o.none) try out.append(gpa, o.set);
        return out.toOwnedSlice(gpa);
    }

    pub fn deinit(self: *Checker) void {
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.vars.deinit(self.gpa);
        self.syms.deinit(self.gpa);
        self.plain_reqs.deinit(self.gpa);
        self.old_nones.deinit(self.gpa);
        self.method_calls.deinit(self.gpa);
        self.items_seen.deinit(self.gpa);
        self.stmt_drops.deinit(self.gpa);
        self.part_temps.deinit(self.gpa);
        self.kept_views.deinit(self.gpa);
        self.call_held.deinit(self.gpa);
        self.once_uses.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        self.loan_counts.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.last_use.deinit(self.gpa);
        self.defer_used.deinit(self.gpa);
        self.uses.deinit(self.gpa);
        self.walked.deinit(self.gpa);
        self.late.deinit(self.gpa);
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
        try transfer.walkDecl(self, sexp);
        try generic.checkMethodCalls(self);
        self.own_plain_reqs = self.plain_reqs.items.len;
        try generic.checkBoundedCopies(self);
        try generic.checkInstantiations(self);
    }

    pub fn hasErrors(self: *const Checker) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    pub fn arena(self: *Checker) std.mem.Allocator {
        if (self.fn_depth > 0) return self.fn_arena_state.allocator();
        return self.arena_state.allocator();
    }

    // -------------------------------------------------------------------------
    // Vars and scopes
    // -------------------------------------------------------------------------

    /// A scope covering `node` (`.nil` when not known).
    pub fn pushScopeFor(self: *Checker, kind: ScopeKind, node: Sexp) Error!void {
        try self.scopes.append(self.gpa, .{ .start = @intCast(self.vars.items.len), .kind = kind, .node = node });
    }

    /// Leave the innermost scope: run its defers, check that nothing that
    /// survives holds a loan on a var declared in it, then drop its vars.
    pub fn popScope(self: *Checker) Error!void {
        return self.popScopeWith(&.{});
    }

    /// Leave the innermost scope with `v`, the value it gives: `v` may not
    /// view a var declared in it, and what else `v` views is in use while
    /// the scope's defers run (`ExitTo.result`). Gives what `v` keeps.
    pub fn leaveScope(self: *Checker, v: Value) Error!Value {
        const kept = try rules.checkValueEscapesScope(self, v);
        try self.popScopeWith(try self.withDerefs(kept, v));
        return kept;
    }

    /// The loans `kept`, what value `v` keeps past a scope, and `v`'s
    /// loans on the scope's write-view bindings (`Loan.deref`): the
    /// scope's defers run while the value lives, so they may not use a
    /// binding it is viewed through.
    pub fn withDerefs(self: *Checker, kept: Value, v: Value) Error![]const Loan {
        var out = kept.loans;
        for (v.loans) |l| if (l.deref) {
            out = try self.unionLoans(out, try self.oneLoan(l));
        };
        return out;
    }

    /// `popScope`, where the path leaves with a value carrying `result`.
    pub fn popScopeWith(self: *Checker, result: []const Loan) Error!void {
        const idx = self.scopes.items.len - 1;
        if (self.reachable) {
            _ = try exits.exitTo(self, .{ .exit = .scope_end, .result = result });
            try exits.checkDropOrder(self, self.scopes.items[idx].start);
            try exits.checkLostTasks(self, self.scopes.items[idx].start);
        }
        var scope = self.scopes.pop().?;
        defer scope.defers.deinit(self.gpa);
        const start = scope.start;
        const ext = notes.extent(self, scope.node);
        try self.releaseVarsFrom(start, self.reachable, if (ext.hi >= ext.lo) ext.hi +| 1 else null, scope.node);
        self.truncateVars(start);
    }

    /// Remove every loan on vars `>= start` from vars below `start` and
    /// from the temporaries, reporting each surviving loan when `report`
    /// and its holder is still live at position `end`, where the scope
    /// ends (or after the current statement when null). The scope
    /// covers `node`, at whose end its vars are dropped.
    pub fn releaseVarsFrom(self: *Checker, start: u32, report: bool, end: ?u32, node: Sexp) Error!void {
        if (self.viewedFrom(start)) {
            if (report) for (self.flows.items[0..@min(start, self.flows.items.len)], 0..) |f, holder| {
                if (hasLoanFrom(f.loans, start)) _ = try notes.reportHolder(self, f, @intCast(holder), start, end, if (end != null) node else .nil);
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

    pub fn addVar(self: *Checker, var_: Var, flow: Flow) Error!VarId {
        const id: VarId = @intCast(self.vars.items.len);
        var v = var_;
        const ctx = self.sema;
        if (v.kind != .hidden) {
            v.sym = ctx.symbolAt(v.decl);
        }
        // Emit holds a binding as lowering made its var
        // (`storage.bindingDrop`): the checker treats as owning exactly
        // the bindings whose var holds a value that moves.
        if (self_check) if (v.sym) |sym| if (v.ty) |t| {
            const drop = storage.bindingDrop(ctx, sym);
            switch (ctx.symbols.items[sym].kind) {
                .param, .local, .capture => if ((drop != null) != (types.owningKind(self, t) != null))
                    try notes.err(self, v.decl, "internal error: the checker holds `{s}` as {s}, but its var holds {s}", .{ v.name, if (types.owningKind(self, t) != null) "owning" else "owning nothing", if (drop) |h| @tagName(h) else "nothing to drop" }),
                else => {},
            }
        };
        if (v.sym) |sym| {
            const gop = try self.syms.getOrPut(self.gpa, sym);
            v.shadows = if (gop.found_existing) gop.value_ptr.* else null;
            gop.value_ptr.* = id;
        }
        try self.vars.append(self.gpa, v);
        try self.flows.append(self.gpa, flow);
        try self.loan_counts.append(self.gpa, 0);
        self.countLoans(flow.loans, true);
        return id;
    }

    /// Drop the vars `>= start`, youngest first, so each var they hid
    /// is visible again.
    pub fn truncateVars(self: *Checker, start: u32) void {
        var i = self.vars.items.len;
        while (i > start) {
            i -= 1;
            const v = self.vars.items[i];
            self.countLoans(self.flows.items[i].loans, false);
            const sym = v.sym orelse continue;
            if (v.shadows) |prev| {
                self.syms.putAssumeCapacity(sym, prev);
            } else {
                _ = self.syms.remove(sym);
            }
        }
        self.vars.shrinkRetainingCapacity(start);
        self.flows.shrinkRetainingCapacity(start);
        self.loan_counts.shrinkRetainingCapacity(start);
    }

    /// The innermost visible var of the binding leaf `node` names, as
    /// sema resolved it.
    pub fn find(self: *const Checker, node: Sexp) ?VarId {
        return self.varOf(self.sema.symbolOf(node) orelse return null);
    }

    /// The innermost visible var of binding `sym`. A local of a
    /// function enclosing the current closure body is not visible:
    /// typecheck reports its use.
    pub fn varOf(self: *const Checker, sym: SymbolId) ?VarId {
        var id = self.syms.get(sym) orelse return null;
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

    pub fn isHiddenScope(self: *const Checker, si: usize) bool {
        const h = self.hidden orelse return false;
        return si > h.lo and si <= h.hi;
    }

    pub fn isHiddenVar(self: *const Checker, id: VarId) bool {
        const h = self.hidden orelse return false;
        if (h.hi <= h.lo) return false;
        const scopes = self.scopes.items;
        const end = if (h.hi + 1 < scopes.len) scopes[h.hi + 1].start else self.vars.items.len;
        return id >= scopes[h.lo + 1].start and id < end;
    }

    /// A module-level binding seen from inside a function body.
    pub fn isGlobal(self: *const Checker, id: VarId) bool {
        return self.scopes.items.len > 1 and id < self.scopes.items[1].start;
    }

    /// Whether var `id` holds a statement's temporary (`holdTemp`).
    pub fn isStmtTemp(self: *const Checker, id: VarId) bool {
        if (id >= self.vars.items.len) return false;
        const v = self.vars.items[id];
        return v.kind == .hidden and v.name.len > 0 and !v.call_held;
    }

    // -------------------------------------------------------------------------
    // Flows: points, captured states, join
    // -------------------------------------------------------------------------

    /// Every write to a var's flow goes through here, so it can be undone.
    pub fn setFlow(self: *Checker, id: VarId, flow: Flow) Error!void {
        try self.trail.append(self.gpa, .{ .id = id, .old = self.flows.items[id] });
        self.replaceFlow(id, flow);
    }

    pub fn replaceFlow(self: *Checker, id: VarId, flow: Flow) void {
        self.countLoans(self.flows.items[id].loans, false);
        self.countLoans(flow.loans, true);
        self.flows.items[id] = flow;
    }

    pub fn markInvalid(self: *Checker, id: VarId, status: Status, pos: u32) Error!void {
        try self.setFlow(id, .{ .status = status, .at = pos });
    }

    pub fn flowLive(self: *Checker, id: VarId) bool {
        return self.flows.items[id].status == .live;
    }

    /// Add (or remove) `loans` to (from) `loan_counts`.
    pub fn countLoans(self: *Checker, loans: []const Loan, add: bool) void {
        for (loans) |l| {
            if (l.root >= self.loan_counts.items.len) continue;
            if (add) self.loan_counts.items[l.root] += 1 else self.loan_counts.items[l.root] -= 1;
        }
    }

    /// Whether some var's flow holds a loan on a var `>= start`.
    pub fn viewedFrom(self: *const Checker, start: u32) bool {
        return for (self.loan_counts.items[@min(start, self.loan_counts.items.len)..]) |n| {
            if (n > 0) break true;
        } else false;
    }

    /// Whether some var's flow holds a loan on `root` (a temporary may
    /// still).
    pub fn isViewed(self: *const Checker, root: VarId) bool {
        return self.loan_counts.items[root] > 0;
    }

    /// The current program point.
    pub fn here(self: *Checker) Error!Point {
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
    pub fn rewind(self: *Checker, p: Point) Error!void {
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
    pub fn stateAt(p: Point) State {
        return .{ .temps = p.temps, .reachable = p.reachable };
    }

    /// The current state relative to point `p`: of the vars in scope
    /// there, and of the loans on them. A path that leaves the scopes
    /// opened since carries nothing else: `exitTo`, its only caller,
    /// reports what it loses.
    pub fn capture(self: *Checker, p: Point) Error!State {
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

    /// Make state `s` current. The current state must be its point's.
    pub fn apply(self: *Checker, s: State) Error!void {
        for (s.changes) |e| try self.setFlow(e.id, e.flow);
        self.temps.clearRetainingCapacity();
        try self.temps.appendSlice(self.gpa, s.temps);
        self.reachable = s.reachable;
    }

    /// Leave the current path for point `p`, going on at `resume_at`
    /// (`exitTo`): its state relative to `p`, after going back to `p`.
    pub fn leave(self: *Checker, p: Point, resume_at: ?u32) Error!State {
        const s = try exits.exitTo(self, .{ .to = p, .resume_at = resume_at });
        try self.rewind(p);
        return s;
    }

    /// Make current the join of the current state, which goes on at
    /// `resume_at`, with `states`, all relative to point `p`.
    pub fn joinAt(self: *Checker, p: Point, states: []const State, resume_at: ?u32) Error!void {
        var out = try self.leave(p, resume_at);
        for (states) |s| out = try self.join(out, s);
        try self.apply(out);
    }

    /// The single merge operator of the analysis: moved or dropped on
    /// either path is moved or dropped, and loans are unioned. `a` and `b`
    /// are relative to one point, which must be the current state.
    pub fn join(self: *Checker, a: State, b: State) Error!State {
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

    pub fn joinFlow(self: *Checker, fa: Flow, fb: Flow) Error!Flow {
        const status: Status = @fromBackingInt(@intCast(@max(@backingInt(fa.status), @backingInt(fb.status))));
        return .{
            .status = status,
            .at = if (fa.status == status) fa.at else fb.at,
            .loans = try self.unionLoans(fa.loans, fb.loans),
            .parts = try self.unionParts(fa.parts, fb.parts),
            .nones = try self.intersectNones(fa.nones, fb.nones),
        };
    }

    /// The fields known to hold `none` on both paths.
    pub fn intersectNones(self: *Checker, a: []const PathId, b: []const PathId) Error![]const PathId {
        if (a.len == 0 or pathSetEql(a, b)) return a;
        var out: std.ArrayList(PathId) = .empty;
        for (a) |p| if (std.mem.findScalar(PathId, b, p) != null) try out.append(self.arena(), p);
        return out.items;
    }

    /// Whether field `path` of var `id` holds `none` here (`Flow.nones`).
    pub fn noneAt(self: *const Checker, id: VarId, path: PathId) bool {
        return std.mem.findScalar(PathId, self.flows.items[id].nones, path) != null;
    }

    /// Place `place`, just taken with `<p.f`, holds `none`: a field of
    /// its root reached by fields alone, through no index, shared
    /// handle, or path cut short.
    pub fn markNone(self: *Checker, place: Place) Error!void {
        if (place.path == whole_path or place.path_ended or place.indexed or place.through_shared) return;
        if (self.noneAt(place.root, place.path)) return;
        var f = self.flows.items[place.root];
        const out = try self.arena().alloc(PathId, f.nones.len + 1);
        @memcpy(out[0..f.nones.len], f.nones);
        out[f.nones.len] = place.path;
        f.nones = out;
        try self.setFlow(place.root, f);
    }

    /// Place `path` of var `id` is written, given a write view, or moved: no
    /// field it overlaps is known to hold `none` any more.
    pub fn clearNones(self: *Checker, id: VarId, path: PathId) Error!void {
        const f = self.flows.items[id];
        if (f.nones.len == 0) return;
        var out: std.ArrayList(PathId) = .empty;
        for (f.nones) |p| if (!self.paths.overlap(p, path)) try out.append(self.arena(), p);
        if (out.items.len == f.nones.len) return;
        var g = f;
        g.nones = out.items;
        try self.setFlow(id, g);
    }

    /// The fields moved out on either path: moved out after the join.
    pub fn unionParts(self: *Checker, a: []const Part, b: []const Part) Error![]const Part {
        if (b.len == 0) return a;
        if (a.len == 0) return b;
        var out: std.ArrayList(Part) = .empty;
        try out.appendSlice(self.arena(), a);
        for (b) |pb| {
            if (!hasPart(a, pb.path)) try out.append(self.arena(), pb);
        }
        if (out.items.len == a.len) return a;
        return out.items;
    }

    /// Walks the vars two states relative to the current point change,
    /// in order, with each var's flow in both (its current flow in a
    /// state that does not change it).
    pub const Pairs = struct {
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

    /// Whether two states relative to the current point are the same.
    pub fn statesEql(self: *const Checker, a: State, b: State) bool {
        if (a.reachable != b.reachable) return false;
        if (!loanSetEql(a.temps, b.temps)) return false;
        var pairs: Pairs = .{ .a = a.changes, .b = b.changes };
        while (pairs.next(self)) |p| if (!flowEql(p.fa, p.fb)) return false;
        return true;
    }

    pub fn unionLoans(self: *Checker, a: []const Loan, b: []const Loan) Error![]const Loan {
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

    pub fn filterLoansBelow(self: *Checker, loans: []const Loan, len: u32) Error![]const Loan {
        if (!hasLoanFrom(loans, len)) return loans;
        var out: std.ArrayList(Loan) = .empty;
        for (loans) |l| if (l.root < len) try out.append(self.arena(), l);
        return out.items;
    }

    /// A loan set holding just `l`.
    pub fn oneLoan(self: *Checker, l: Loan) Error![]const Loan {
        const one = try self.arena().alloc(Loan, 1);
        one[0] = l;
        return one;
    }

    pub fn valueUnion(self: *Checker, a: Value, b: Value) Error!Value {
        return .{ .loans = try self.unionLoans(a.loans, b.loans) };
    }

    // -------------------------------------------------------------------------
    // Loans: which loan a var holds
    // -------------------------------------------------------------------------

    /// A live, non-external loan on a place of `root` that overlaps
    /// `path` (`Paths.overlap`), held by a var or a temporary. Vars that
    /// view `skip_alias_of` (payload bindings of that scrutinee) are
    /// ignored.
    pub fn findLoan(self: *Checker, root: VarId, path: PathId, q: LoanQuery, skip_alias_of: ?VarId) ?Loan {
        if (self.isViewed(root)) for (self.flows.items, self.vars.items, 0..) |f, v, holder| {
            if (skip_alias_of != null and v.alias_of == skip_alias_of) continue;
            for (f.loans) |l| if (self.loanMatches(l, root, path, q)) {
                if (live.holderLive(self, @intCast(holder), null)) return l;
                break;
            };
        };
        for (self.temps.items) |l| if (self.loanMatches(l, root, path, q)) return l;
        return null;
    }

    /// Whether `l` is a loan `q` asks for on a place of `root` that
    /// overlaps `path`. Only this compares paths.
    pub fn loanMatches(self: *const Checker, l: Loan, root: VarId, path: PathId, q: LoanQuery) bool {
        return l.root == root and !l.ext and (q == .any or l.kind == .write) and self.paths.overlap(l.path, path);
    }
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

pub fn containsLoan(set: []const Loan, l: Loan) bool {
    for (set) |x| if (x.sameAs(l)) return true;
    return false;
}

/// Two flows agree for the analysis (the position of a move is only
/// for messages).
pub fn flowEql(a: Flow, b: Flow) bool {
    return a.status == b.status and loanSetEql(a.loans, b.loans) and partSetEql(a.parts, b.parts) and pathSetEql(a.nones, b.nones);
}

pub fn pathSetEql(a: []const PathId, b: []const PathId) bool {
    if (a.len != b.len) return false;
    for (a) |p| if (std.mem.findScalar(PathId, b, p) == null) return false;
    return true;
}

pub fn hasPart(parts: []const Part, path: PathId) bool {
    for (parts) |p| if (p.path == path) return true;
    return false;
}

pub fn partSetEql(a: []const Part, b: []const Part) bool {
    if (a.len != b.len) return false;
    for (a) |p| if (!hasPart(b, p.path)) return false;
    return true;
}

pub fn loanSetEql(a: []const Loan, b: []const Loan) bool {
    for (a) |l| if (!containsLoan(b, l)) return false;
    for (b) |l| if (!containsLoan(a, l)) return false;
    return true;
}

pub fn hasLoanFrom(loans: []const Loan, start: u32) bool {
    for (loans) |l| if (l.root >= start) return true;
    return false;
}

/// The same IR node: the same leaf, or the same list.
pub fn sameNode(a: Sexp, b: Sexp) bool {
    return switch (a) {
        .src => |s| b == .src and b.src.pos == s.pos,
        .list => b == .list and a.items().ptr == b.items().ptr,
        else => false,
    };
}
