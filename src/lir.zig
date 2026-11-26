//! LIR: a function lowered once, in the order it runs.
//!
//! The lowered IR holds what the typed tree leaves implicit: the order
//! a function's parts are evaluated in, the hidden vars that hold its
//! values (each a kind of `storage.StorageKind`), the
//! bindings and how each drops, and which region declares each var, so
//! how long it lives. Control flow stays structured, as Zig needs it:
//! regions nest, and a region yields a value where an expression needs
//! one (docs/internals/architecture.md, "The one idea";
//! docs/internals/INTERNALS.md, "LIR").
//!
//! `src/lower.zig` builds it from the typed tree and the recorded
//! facts. This file holds the data, its verifier, and its text form.

const std = @import("std");
const parser = @import("parser.zig");
const storage = @import("storage.zig");
const sema = @import("sema.zig");
const diag = @import("diag.zig");
const rig = @import("rig.zig");
const self_check = @import("build_options").self_check;

const Sexp = parser.Sexp;

pub const VarId = u32;
pub const ExprId = u32;
pub const RegionId = u32;

/// A var of a function: a binding (a parameter, local, or capture), or
/// hidden storage the function makes for a value no name holds.
pub const Var = struct {
    /// The node it is made for: a binding's declaring name, or the
    /// expression or construct a hidden var holds.
    node: Sexp,
    name: Name,
    /// How a hidden var holds its value, and for how long.
    by: storage.StorageBy = .owned,
    life: storage.StorageLife = .block,
    /// How it drops the value it holds, or null when it owns nothing to
    /// drop.
    drop: ?sema.ResourceKind = null,
    /// How each of several results it holds drops.
    parts: []const ?sema.ResourceKind = &.{},
    /// A binding a use may move out: its drop is armed behind a flag.
    flag: bool = false,

    pub const Name = union(enum) {
        binding: sema.SymbolId,
        hidden: storage.StorageKind,
    };
};

/// A value, evaluated left to right: each operand before the operation.
pub const Expr = union(enum) {
    /// A var's value, read at `node`: the name as written, or the node
    /// whose value a var holds in its place.
    @"var": Use,
    /// A leaf read as written: a literal, or a name no var of the
    /// function holds (a constant, a function, a type, a module).
    leaf: Sexp,
    /// The operation of tree node `node`, over its operands in order.
    op: Op,
    /// `value`, held in `v`, which it then reads: storage made where the
    /// value stands, such as a statement's temporary.
    hold: struct { v: VarId, value: ExprId },
    /// A region that yields a value.
    block: RegionId,
    /// `if cond, then, else` where a value goes: each branch yields one.
    branch: If,
    /// `match` where a value goes: each arm yields one.
    choice: Choice,
    /// A closure literal: the body it is (`owner`, a body of the
    /// module), and the values its captures take, made here.
    closure: struct { node: Sexp, owner: u32, captures: []const ExprId },
    /// `value`, the value of `node`, made the type its context takes:
    /// `how`, one of the node's coercions (`lower.Module.Chain`).
    coerce: struct { node: Sexp, how: *const Coercion, value: ExprId },

    /// The operation of `node` over `args`: what it does, `kind`, and
    /// for a call, its record, `Func.calls[aux]`; for a `member` or an
    /// `index` that reaches a place, the place, `Func.places[aux - 1]`.
    pub const Op = struct { node: Sexp, args: []const ExprId, kind: OpKind = .other, aux: u32 = 0 };

    pub const Use = struct { v: VarId, node: Sexp };

    // An operation's kind and record index fit in the room a closure
    // takes, so an expression is no larger for them.
    comptime {
        std.debug.assert(@sizeOf(Op) <= @sizeOf(@FieldType(Expr, "closure")));
    }

    /// An `if`: its condition, then the branch it picks.
    pub const If = struct { node: Sexp, cond: ExprId, then: RegionId, @"else": ?RegionId };

    /// A `match`: its subject, then the arm whose pattern it fits.
    pub const Choice = struct { node: Sexp, subject: ExprId, arms: []const RegionId, answers: MatchAnswers = .{} };
};

/// What an operation does, by the form of its node: the facts that
/// decide more are recorded on the operation's own record (`Call`).
pub const OpKind = enum(u8) {
    /// `+`, `-`, `*`, `/`, `%`, their wrapping and saturating forms,
    /// the bitwise operators and shifts, and `neg`.
    arith,
    /// `==`, `!=`, `<`, `>`, `<=`, `>=`.
    compare,
    /// `and`, `or`, `not`.
    logic,
    /// `?x` and `!x`: a read view and a write view.
    view,
    /// `<x`.
    move,
    /// `+x`.
    clone,
    /// `~x`.
    weak,
    /// `*x`.
    share,
    /// `^x`.
    box,
    member,
    index,
    /// `f[T]`: a compile-time instance.
    inst,
    /// A call, whose record is `Func.calls[aux]`.
    call,
    array,
    array_fill,
    template,
    /// `v!`.
    propagate,
    /// `v?`.
    propagate_none,
    /// `a ?? b`.
    nullish,
    /// `v catch |e| handler`.
    @"catch",
    kwarg,
    panic,
    results,
    /// `.variant` and `:symbol`.
    literal,
    /// `v as name`, `f() as a, b`, and the `match` tests of a condition.
    as,
    /// Any other operation: its node says what it is.
    other,
};

/// What a call is, decided once by lowering (`lower.classifyCall`) in
/// the order emit's call ladder asks: a call that fits two forms is
/// the first of them here.
pub const CallKind = enum(u8) {
    /// An element operation of a slice, an array, or a List
    /// (`sema.ElemCall`).
    elem,
    /// `Simd[T, n](a)`.
    simd_conversion,
    /// `f(x)&`, and `c.m(x)&` through an actor's handle.
    task,
    actor_spawn,
    /// The built-ins (`sema.BuiltinCall`).
    print,
    warn,
    conversion,
    swap,
    /// `String(...)`, `!t.add(...)` (`facts.StringCall`).
    string,
    /// A call through a type alias: of a number, a List, a Signal, or
    /// an object.
    alias_conversion,
    alias_list,
    alias_signal,
    alias_object,
    /// `.variant(payload)`.
    variant,
    /// A closure literal called where it is written.
    inline_invoke,
    /// Through an API: the witness's method, or an API object's table.
    witness,
    object,
    /// A closure a local holds in the frame.
    stack_closure,
    /// The built-in types' makers, and an object's.
    list,
    table,
    signal,
    constructor,
    /// A member callee with no type of its own: an error with fields,
    /// a variant through its enum, an object of another module, an
    /// instance sema gave it.
    error_member,
    variant_member,
    foreign_object,
    instance,
    /// Through a callable view, and an owned closure handle.
    fn_ref,
    closure_handle,
    /// A method of a built-in type emit lowers on its own
    /// (`sema.BuiltinCall`).
    builtin_method,
    /// The runtime's calls: `task.all`, an actor's method, `task.select`
    /// (to a value, or into the slot), its arms, `http.serve`, `reduce`,
    /// `io.copy`, `task.supervise`, `task.isolate`, the `par` forms, and
    /// the waits of a set and of a task.
    task_join,
    actor_call,
    select_value,
    select_into,
    arm_recv,
    arm_send,
    arm_end,
    arm_after,
    http_serve,
    reduce,
    io_copy,
    supervise,
    isolate,
    par_map,
    par_each,
    par_workers,
    par_push,
    wait_all,
    wait,
    /// Any other call: a function, a method, or a function value.
    plain,
    /// Not classified: a call of the checkers' lowering, in a build that
    /// does not check itself. Only emit reads the kind.
    unclassified,
};

/// A call: what it is, how its callee is written, how it takes its
/// self, and what is opened around it. Emit's lowering records its kind
/// and wrap, the checkers' its flags; each records the callee and self.
pub const Call = struct {
    kind: CallKind,
    callee: Callee,
    /// How a method takes its self; null for a call with none.
    self: ?Self = null,
    wrap: Wrap = .{},
    flags: Flags = .{},

    /// How the callee is written, as the ownership checker walks it.
    pub const Callee = enum(u8) {
        /// A function a field holds, called with the arguments alone.
        field_fn,
        /// A method, through the member's object, its self.
        member,
        name,
        lambda,
        other,
    };

    pub const Self = struct {
        mode: sema.SelfMode,
        /// Written with its sigil: `!b.m()`, `?b.m()`.
        explicit: bool,
    };

    /// What emit opens around the call, outermost first.
    pub const Wrap = packed struct(u8) {
        /// A std maker checked as Rig compiles (`facts.isConstMaker`).
        const_maker: bool = false,
        /// Its parts are held first, in a `call` region.
        held: bool = false,
        /// It may reach an inlined function, whose optional, fallible,
        /// or other result is made a run-time value
        /// (`facts.callsInlined`).
        rt_optional: bool = false,
        rt_fallible: bool = false,
        rt_plain: bool = false,
        /// A duration form joins its failure.
        folds: bool = false,
        _: u2 = 0,
    };

    pub const Flags = packed struct(u8) {
        /// A task that stays on its maker's thread (`isLocalTask`), or
        /// that may take a dense stack (`isDenseCall`).
        local: bool = false,
        dense: bool = false,
        /// It only reads its arguments and keeps none of them: `print`
        /// and the `String` forms.
        text_only: bool = false,
        /// An actor's call or a select's arm: its result keeps no loan.
        keeps_no_loan: bool = false,
        /// `swap(a, b)` of two places or two values.
        swap: bool = false,
        _: u3 = 0,
    };
};

/// How an operation or a step uses an operand, decided once by lowering
/// (`Lowerer.role`) for each expression: an expression is the operand of
/// one operation or step, so its role is kept by its id
/// (`Func.roles`), in a self-checking build for now, where the ownership
/// checker asserts that it decides each the same.
pub const Operand = packed struct(u16) {
    use: Use = .read,
    sink: Sink = .none,
    /// Viewed to read where a view is expected, with no sigil
    /// (`sema.View.implicit`).
    implicit: bool = false,
    /// A view of the operand's elements, or a String's bytes: `?a`
    /// viewed as `?a[..]`.
    elems: bool = false,
    /// A held write view passed on where a read view is expected.
    read_only: bool = false,
    /// Held first in a hidden var of its call or array literal
    /// (`argument`).
    held: bool = false,
    _: u5 = 0,

    /// What an operand's user does with it (Core sentences 1, 2, 4, 5).
    pub const Use = enum(u3) {
        /// A place read where it stands, or a value read as it is.
        read,
        /// `<x`: the operand of a move.
        move,
        /// `?x` and `!x`: the operand of a view, or a value viewed to read
        /// where a view is expected (`Operand.implicit`).
        read_view,
        write_view,
        /// A held write view (`w`, `e.t`) passed to a call: it is a write
        /// view of its holder for as long as the result may keep it.
        pass_view,
        /// A value made where it stands, which its user takes.
        made,
    };

    /// Where a consumed operand goes (Core sentences 3, 7), as the ownership
    /// checker names it (`ownership.Sink`).
    pub const Sink = enum(u4) {
        none,
        binding,
        argument,
        field,
        element,
        allocation,
        box,
        ret,
        brk,
    };
};

/// A place: a var, then the fields and elements of it a `member` or
/// `index` operation reaches (`sema.Hands.place`). Its op names it by
/// `Func.places[aux - 1]`; recorded in a self-checking build, where the
/// ownership checker asserts that it finds each place so
/// (`resolvePlace`).
pub const Place = struct {
    /// Null for a place rooted at a leaf: a constant of the module.
    root: ?VarId,
    steps: []const PlaceStep,
};

pub const PlaceStep = packed struct(u8) {
    kind: Kind,
    /// Its object is the root, a read view: the field is on the root's
    /// path only for a self checked by path (`bindSelfPaths`).
    root_read_view: bool = false,
    /// Its object is a shared handle.
    through_shared: bool = false,
    _: u4 = 0,

    pub const Kind = enum(u2) {
        /// A data field of an object, of a box's, or of what a view of
        /// the root sees: a place of its own on the root's path (Core
        /// §5).
        field,
        /// Any other member, which ends the path.
        member,
        /// An element or a slice, which ends the path.
        index,
    };
};

/// How a value becomes the type its context takes, where it goes. Each
/// is a typing fact of the node it wraps, made explicit where the value
/// is read: a value held in a var first is coerced where the var is
/// written, or where it is read (`lower.Module.chainOf`).
pub const Coercion = union(enum) {
    /// A scalar beside a vector, standing for every lane: the vector's
    /// type (`sema.splatOf`).
    splat: sema.TypeId,
    /// A number given where a duration goes (`sema.Duration`).
    duration: sema.Duration,
    /// A box or a counted handle moved into one of an API object, which
    /// keeps its allocation (`sema.Erasure`, of form `box` or `shared`).
    erase: sema.Erasure,
    /// An error value the function fails with, held rather than made
    /// here, whose fields go through the caller's slot.
    fail,
    /// A `T` or `none` packed into an optional that goes through the
    /// optional helpers (`sema.Lift`).
    lift: sema.Lift,
    /// An error of a set without fields where one that carries fields
    /// goes (`SemContext.isCodeWidening`).
    widen,
    /// A view of the type its context takes, as the rows of the view
    /// table make it (`sema.View`).
    view: sema.View,
    /// A pointer view read through where its context takes the value
    /// (`SemContext.readsThrough`).
    deref,
};

/// How many levels of optional lift `lift` adds to its value: one for
/// `none`.
pub fn liftLevels(types: *const sema.TypeStore, lift: sema.Lift) u32 {
    if (lift.from == types.none_id) return 1;
    return optionalDepth(types, lift.into) -| optionalDepth(types, lift.from);
}

fn optionalDepth(types: *const sema.TypeStore, ty: sema.TypeId) u32 {
    var n: u32 = 0;
    var t = ty;
    while (types.get(t) == .optional) : (n += 1) t = types.get(t).optional;
    return n;
}

/// A step of a region, run in order.
pub const Step = union(enum) {
    /// Evaluate `value` into `v`; for a binding's declaration, the
    /// `set` that declares it.
    bind: struct { v: VarId, value: ExprId, set: Sexp = .nil, answers: Assign = .{} },
    /// Store `value` in the place `target`: the assignment `node`.
    store: struct { node: Sexp, target: ExprId, value: ExprId, answers: Assign = .{} },
    /// Evaluate `value` for what it does.
    eval: ExprId,
    /// Drop what `v` holds: `<x`, the name read at `node`.
    drop: Expr.Use,
    /// Leave: the `return`, `break`, or `continue` `node`.
    jump: struct { node: Sexp, value: ?ExprId },
    /// A region run in place.
    region: RegionId,
    /// `if cond, then, else`.
    @"if": Expr.If,
    /// `while cond: step`, running `body` while `cond` holds, then
    /// `step`.
    loop: struct { node: Sexp, cond: ExprId, body: RegionId, step: ?RegionId, step_point: storage.StepPoint = .continue_expr },
    /// `for x in source`, running `body` once for each element.
    each: struct { node: Sexp, source: ExprId, body: RegionId, fold: ?storage.Fold = null, string_bytes: bool = false },
    /// `match`, running the arm its subject fits.
    match: Expr.Choice,

    // What emit's lowering decides of a step fits in the room the
    // largest step (a `match`) takes, so a step is no larger for it.
    comptime {
        std.debug.assert(@sizeOf(Step) <= 56);
    }
};

/// What emit's lowering decides of an assignment or a binding's
/// declaration (its `set`), kept on its step for emit to read; the
/// checkers' lowering leaves it as it starts.
pub const Assign = struct {
    order: storage.SetOrder = @bitCast(@as(u8, 0)),
    fills_in_place: bool = false,
    lane_checked: bool = false,
    /// An operator's assignment: the call that makes it, if any.
    compound: ?storage.CompoundCall = null,
    /// A binding's declaration: what the binding holds.
    hold: ?storage.BindHold = null,
};

/// What emit's lowering decides of a `match` (`Expr.Choice`).
pub const MatchAnswers = packed struct(u8) {
    mode: storage.MatchMode = .read,
    in_place: bool = false,
    rereads: bool = false,
    block: bool = false,
    selects: bool = false,
    _: u2 = 0,
};

/// A stretch of a function that declares vars, which live until it ends.
pub const Region = struct {
    node: Sexp,
    kind: Kind,
    /// The vars it declares, in the order it declares them.
    decls: std.ArrayList(VarId) = .empty,
    steps: std.ArrayList(Step) = .empty,
    /// What it yields, for a region that is a value.
    value: ?ExprId = null,
    /// The var that is its value, for a header that ends its
    /// temporaries (`header_value`).
    label: ?VarId = null,
    /// For a `match` arm, whether its pattern fits any subject, and
    /// whether the name it binds then views the subject by address;
    /// decided by emit's lowering.
    catch_all: bool = false,
    catch_all_by_address: bool = false,

    pub const Kind = enum {
        /// A function's body.
        body,
        /// A block of statements.
        block,
        /// One statement, which holds its temporaries.
        stmt,
        /// A header that ends its temporaries, yielding its value.
        header,
        /// Parts evaluated first, then the value they make.
        value,
        /// The parts a call or an array literal holds, each evaluated
        /// first, in its turn, then the call or the array.
        call,
        /// An `if` or a `while` and the bindings its condition names,
        /// which the condition's later parts and its body see.
        guard,
        /// A `match` arm: its pattern, which declares its bindings, its
        /// guard, and its body.
        arm,
    };
};

/// A list a self-checking build keeps, and no other: there it is empty.
fn Checked(comptime T: type) type {
    return if (self_check) std.ArrayList(T) else struct {};
}

/// A function, a closure, a test, or a `drop` body, lowered.
pub const Func = struct {
    /// The `fun`, `sub`, `lambda`, `test`, or `drop_decl` node.
    root: Sexp,
    vars: std.ArrayList(Var) = .empty,
    exprs: std.ArrayList(Expr) = .empty,
    regions: std.ArrayList(Region) = .empty,
    /// The record of each call, which its op names (`Op.aux`).
    calls: std.ArrayList(Call) = .empty,
    /// The role of each expression as an operand, by its id; filled in
    /// a self-checking build, and shorter than `exprs` where the rest
    /// take the default.
    roles: Checked(Operand) = if (self_check) .empty else .{},
    /// The places `member` and `index` operations reach, each named by
    /// its op (`Op.aux - 1`); filled in a self-checking build.
    places: Checked(Place) = if (self_check) .empty else .{},
    body: RegionId = 0,

    pub fn addVar(f: *Func, a: std.mem.Allocator, v: Var) !VarId {
        try f.vars.append(a, v);
        return @intCast(f.vars.items.len - 1);
    }

    pub fn addExpr(f: *Func, a: std.mem.Allocator, e: Expr) !ExprId {
        try f.exprs.append(a, e);
        return @intCast(f.exprs.items.len - 1);
    }

    pub fn addRegion(f: *Func, a: std.mem.Allocator, node: Sexp, kind: Region.Kind) !RegionId {
        try f.regions.append(a, .{ .node = node, .kind = kind });
        return @intCast(f.regions.items.len - 1);
    }

    /// The role of expression `e` as an operand.
    pub fn roleOf(f: *const Func, e: ExprId) Operand {
        if (!self_check) return .{};
        return if (e < f.roles.items.len) f.roles.items[e] else .{};
    }

    pub fn region(f: *Func, r: RegionId) *Region {
        return &f.regions.items[r];
    }

    /// Hold the value of expression `e` in `v` where it stands: `e`
    /// becomes `hold(v, e)`, so a reader of `e` reads the var.
    pub fn holdIn(f: *Func, a: std.mem.Allocator, e: ExprId, v: VarId) !void {
        const inner = try f.addExpr(a, f.exprs.items[e]);
        f.exprs.items[e] = .{ .hold = .{ .v = v, .value = inner } };
    }
};

// =============================================================================
// The verifier
// =============================================================================

pub const Problem = struct {
    node: Sexp,
    what: []const u8,
};

/// Check that `f` is well formed: each expression and region is reached
/// once, from the body, as a tree; each var is declared by exactly one
/// region; and each var is read and written only inside the region that
/// declares it. Returns the first problem found.
pub fn verify(gpa: std.mem.Allocator, f: *const Func) !?Problem {
    var v: Verifier = .{ .f = f };
    defer v.deinit(gpa);
    v.declared = try gpa.alloc(?RegionId, f.vars.items.len);
    @memset(v.declared, null);
    v.seen_exprs = try std.DynamicBitSetUnmanaged.initEmpty(gpa, f.exprs.items.len);
    v.seen_regions = try std.DynamicBitSetUnmanaged.initEmpty(gpa, f.regions.items.len);
    v.open = try std.DynamicBitSetUnmanaged.initEmpty(gpa, f.vars.items.len);
    v.region(f.body) catch return v.problem;
    for (v.declared, 0..) |d, i| if (d == null) return .{ .node = f.vars.items[i].node, .what = "a var no region declares" };
    for (f.regions.items, 0..) |r, i| if (!v.seen_regions.isSet(i)) return .{ .node = r.node, .what = "a region the body never reaches" };
    return null;
}

const Verifier = struct {
    f: *const Func,
    declared: []?RegionId = &.{},
    seen_exprs: std.DynamicBitSetUnmanaged = .{},
    seen_regions: std.DynamicBitSetUnmanaged = .{},
    /// The vars of the regions open around the step being checked.
    open: std.DynamicBitSetUnmanaged = .{},
    problem: ?Problem = null,

    const Error = error{Invalid};

    fn deinit(v: *Verifier, gpa: std.mem.Allocator) void {
        gpa.free(v.declared);
        v.seen_exprs.deinit(gpa);
        v.seen_regions.deinit(gpa);
        v.open.deinit(gpa);
    }

    fn fail(v: *Verifier, node: Sexp, what: []const u8) Error {
        v.problem = .{ .node = node, .what = what };
        return error.Invalid;
    }

    fn region(v: *Verifier, id: RegionId) Error!void {
        if (id >= v.f.regions.items.len) return v.fail(v.f.root, "a region out of range");
        const r = &v.f.regions.items[id];
        if (v.seen_regions.isSet(id)) return v.fail(r.node, "a region reached twice");
        v.seen_regions.set(id);
        for (r.decls.items) |x| {
            if (x >= v.f.vars.items.len) return v.fail(r.node, "a var out of range");
            if (v.declared[x] != null) return v.fail(v.f.vars.items[x].node, "a var declared twice");
            v.declared[x] = id;
            v.open.set(x);
        }
        if (r.label) |l| try v.use(l, r.node);
        for (r.steps.items) |s| switch (s) {
            .bind => |b| {
                try v.use(b.v, r.node);
                try v.expr(b.value);
            },
            .store => |st| {
                try v.expr(st.target);
                try v.expr(st.value);
            },
            .eval => |e| try v.expr(e),
            .drop => |x| try v.use(x.v, r.node),
            .jump => |j| if (j.value) |e| try v.expr(e),
            .region => |sub| try v.region(sub),
            .@"if" => |i| {
                try v.expr(i.cond);
                try v.region(i.then);
                if (i.@"else") |e| try v.region(e);
            },
            .loop => |lp| {
                try v.expr(lp.cond);
                try v.region(lp.body);
                if (lp.step) |st| try v.region(st);
            },
            .each => |ea| {
                try v.expr(ea.source);
                try v.region(ea.body);
            },
            .match => |c| try v.choice(c),
        };
        if (r.value) |e| try v.expr(e);
        for (r.decls.items) |x| v.open.unset(x);
    }

    fn use(v: *Verifier, x: VarId, at: Sexp) Error!void {
        if (x >= v.f.vars.items.len) return v.fail(at, "a var out of range");
        if (!v.open.isSet(x)) return v.fail(v.f.vars.items[x].node, "a var used outside the region that declares it");
    }

    fn expr(v: *Verifier, id: ExprId) Error!void {
        if (id >= v.f.exprs.items.len) return v.fail(v.f.root, "an expression out of range");
        if (v.seen_exprs.isSet(id)) return v.fail(v.f.root, "an expression reached twice");
        v.seen_exprs.set(id);
        switch (v.f.exprs.items[id]) {
            .@"var" => |x| try v.use(x.v, x.node),
            .leaf => {},
            .op => |o| for (o.args) |a| try v.expr(a),
            .hold => |h| {
                try v.use(h.v, v.f.root);
                try v.expr(h.value);
            },
            .block => |r| try v.region(r),
            .branch => |b| {
                try v.expr(b.cond);
                try v.region(b.then);
                if (b.@"else") |e| try v.region(e);
            },
            .choice => |c| try v.choice(c),
            .closure => |c| for (c.captures) |x| try v.expr(x),
            .coerce => |c| try v.expr(c.value),
        }
    }

    fn choice(v: *Verifier, c: Expr.Choice) Error!void {
        try v.expr(c.subject);
        for (c.arms) |a| try v.region(a);
    }
};

// =============================================================================
// The text form
// =============================================================================

/// Write `f` as text, for `rig check --facts=lir`: its vars, one per
/// line, then its body, a region per brace.
pub fn write(f: *const Func, ctx: *const sema.SemContext, w: *std.Io.Writer) !void {
    const at = diag.lineCol(ctx.source, ctx.startOf(f.root));
    try w.print("{s} {d}:{d}\n", .{ @tagName(f.root.kind() orelse .module), at.line, at.col });
    for (f.vars.items, 0..) |v, i| {
        try w.print("  %{d} ", .{i});
        try writeVar(ctx, v, w);
        try w.writeAll("\n");
    }
    var p: Printer = .{ .f = f, .ctx = ctx, .w = w };
    try p.region(f.body, 1);
    try w.writeAll("\n");
}

pub fn writeVar(ctx: *const sema.SemContext, v: Var, w: *std.Io.Writer) !void {
    const at = diag.lineCol(ctx.source, ctx.startOf(v.node));
    switch (v.name) {
        .binding => |s| try w.print("{s} binding", .{ctx.symbols.items[s].name}),
        .hidden => |k| try w.print("{s} {s} {s}", .{ @tagName(k), @tagName(v.by), @tagName(v.life) }),
    }
    if (v.drop) |d| try w.print(" drop={s}", .{@tagName(d)});
    for (v.parts) |p| try w.print(" part={s}", .{if (p) |d| @tagName(d) else "none"});
    if (v.flag) try w.writeAll(" flag");
    try w.print(" @{d}:{d}", .{ at.line, at.col });
}

const Printer = struct {
    f: *const Func,
    ctx: *const sema.SemContext,
    w: *std.Io.Writer,

    fn indent(p: *Printer, depth: usize) !void {
        for (0..depth) |_| try p.w.writeAll("  ");
    }

    fn region(p: *Printer, id: RegionId, depth: usize) std.Io.Writer.Error!void {
        const r = &p.f.regions.items[id];
        try p.w.print("{s}", .{@tagName(r.kind)});
        if (r.label) |l| try p.w.print(" %{d}", .{l});
        if (r.decls.items.len > 0) {
            try p.w.writeAll(" [");
            for (r.decls.items, 0..) |x, i| try p.w.print("{s}%{d}", .{ if (i > 0) " " else "", x });
            try p.w.writeAll("]");
        }
        try p.w.writeAll(" {\n");
        for (r.steps.items) |s| {
            try p.indent(depth + 1);
            switch (s) {
                .bind => |b| {
                    try p.w.print("%{d} = ", .{b.v});
                    try p.expr(b.value, depth + 1);
                },
                .store => |st| {
                    try p.expr(st.target, depth + 1);
                    try p.w.writeAll(" := ");
                    try p.expr(st.value, depth + 1);
                },
                .eval => |e| try p.expr(e, depth + 1),
                .drop => |x| try p.w.print("drop %{d}", .{x.v}),
                .jump => |j| {
                    try p.w.writeAll(@tagName(j.node.kind() orelse .module));
                    if (j.value) |e| {
                        try p.w.writeAll(" ");
                        try p.expr(e, depth + 1);
                    }
                },
                .region => |sub| try p.region(sub, depth + 1),
                .@"if" => |i| try p.branch(i.cond, i.then, i.@"else", depth + 1),
                .loop => |lp| {
                    try p.w.writeAll("while ");
                    try p.expr(lp.cond, depth + 1);
                    if (lp.step) |st| {
                        try p.w.writeAll(" step ");
                        try p.region(st, depth + 1);
                    }
                    try p.w.writeAll(" do ");
                    try p.region(lp.body, depth + 1);
                },
                .match => |c| try p.choice(c, depth + 1),
                .each => |ea| {
                    try p.w.writeAll("for ");
                    try p.expr(ea.source, depth + 1);
                    try p.w.writeAll(" do ");
                    try p.region(ea.body, depth + 1);
                },
            }
            try p.w.writeAll("\n");
        }
        if (r.value) |e| {
            try p.indent(depth + 1);
            try p.w.writeAll("yield ");
            try p.expr(e, depth + 1);
            try p.w.writeAll("\n");
        }
        try p.indent(depth);
        try p.w.writeAll("}");
    }

    fn expr(p: *Printer, id: ExprId, depth: usize) std.Io.Writer.Error!void {
        switch (p.f.exprs.items[id]) {
            .@"var" => |x| try p.w.print("%{d}", .{x.v}),
            .leaf => |l| switch (l) {
                .src => |src| try p.w.writeAll(rig.leafText(p.ctx.source, src)),
                .tag => |t| try p.w.writeAll(@tagName(t)),
                else => try p.w.writeAll("_"),
            },
            .op => |o| {
                try p.w.print("{s}", .{@tagName(o.node.kind() orelse .module)});
                if (o.kind == .call) try p.w.print("/{s}", .{@tagName(p.f.calls.items[o.aux].kind)});
                try p.w.writeAll("(");
                for (o.args, 0..) |a, i| {
                    if (i > 0) try p.w.writeAll(", ");
                    try p.expr(a, depth);
                }
                try p.w.writeAll(")");
            },
            .hold => |h| {
                try p.w.print("hold %{d} ", .{h.v});
                try p.expr(h.value, depth);
            },
            .block => |r| try p.region(r, depth),
            .branch => |b| try p.branch(b.cond, b.then, b.@"else", depth),
            .choice => |c| try p.choice(c, depth),
            .closure => |c| {
                try p.w.print("closure #{d}(", .{c.owner});
                for (c.captures, 0..) |x, i| {
                    if (i > 0) try p.w.writeAll(", ");
                    try p.expr(x, depth);
                }
                try p.w.writeAll(")");
            },
            .coerce => |c| {
                try p.w.print("{s}(", .{@tagName(c.how.*)});
                try p.expr(c.value, depth);
                try p.w.writeAll(")");
            },
        }
    }

    fn choice(p: *Printer, c: Expr.Choice, depth: usize) std.Io.Writer.Error!void {
        try p.w.writeAll("match ");
        try p.expr(c.subject, depth);
        for (c.arms) |a| {
            try p.w.writeAll(" ");
            try p.region(a, depth);
        }
    }

    fn branch(p: *Printer, cond: ExprId, then: RegionId, @"else": ?RegionId, depth: usize) std.Io.Writer.Error!void {
        try p.w.writeAll("if ");
        try p.expr(cond, depth);
        try p.w.writeAll(" then ");
        try p.region(then, depth);
        if (@"else") |e| {
            try p.w.writeAll(" else ");
            try p.region(e, depth);
        }
    }
};

test "verify accepts a var used in its region, and finds one used outside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Func = .{ .root = .nil };
    f.body = try f.addRegion(a, .nil, .body);
    const inner = try f.addRegion(a, .nil, .stmt);
    const v = try f.addVar(a, .{ .node = .nil, .name = .{ .hidden = .temp } });
    try f.region(inner).decls.append(a, v);
    try f.region(inner).steps.append(a, .{ .bind = .{ .v = v, .value = try f.addExpr(a, .{ .leaf = .nil }) } });
    try f.region(f.body).steps.append(a, .{ .region = inner });
    try std.testing.expect(try verify(std.testing.allocator, &f) == null);
    // Read after the region that declares it ends.
    try f.region(f.body).steps.append(a, .{ .eval = try f.addExpr(a, .{ .@"var" = .{ .v = v, .node = .nil } }) });
    const p = (try verify(std.testing.allocator, &f)).?;
    try std.testing.expectEqualStrings("a var used outside the region that declares it", p.what);
}

test "verify finds an expression reached twice and a var declared twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Func = .{ .root = .nil };
    f.body = try f.addRegion(a, .nil, .body);
    const e = try f.addExpr(a, .{ .leaf = .nil });
    try f.region(f.body).steps.append(a, .{ .eval = e });
    try f.region(f.body).steps.append(a, .{ .eval = e });
    try std.testing.expectEqualStrings("an expression reached twice", (try verify(std.testing.allocator, &f)).?.what);
    var g: Func = .{ .root = .nil };
    g.body = try g.addRegion(a, .nil, .body);
    const v = try g.addVar(a, .{ .node = .nil, .name = .{ .hidden = .temp } });
    try g.region(g.body).decls.append(a, v);
    try g.region(g.body).decls.append(a, v);
    try std.testing.expectEqualStrings("a var declared twice", (try verify(std.testing.allocator, &g)).?.what);
}
