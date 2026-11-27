//! Lower: each body of a module to its LIR (`src/lir.zig`), from the
//! typed tree and the recorded facts.
//!
//! A body is a function, a `sub`, a test, a `drop` body, a closure, or
//! a compile-time function's: a frame owner (`sema.FrameOwner`), or a
//! body the ownership checker walks though it never runs. Lowering walks
//! it once, in the order it runs, and makes a var for each binding and
//! for each piece of hidden storage, asking the storage deciders below.
//! A node's vars are numbered after its operands', and its steps are
//! placed in the order they run.
//!
//! Every module sema accepts is lowered as it is checked, before the
//! ownership checker runs (`lowerChecked`), and kept in
//! `SemContext.lowered` until its checks finish: the ownership checker
//! reads from it the storage a call holds. Emit lowers each module again
//! as it writes it, reads the storage it writes from the vars, regions,
//! and statement temporaries indexed in `Module`, and what lowering
//! decided of each node, step, arm, and binding (`Module.answersOf`,
//! `stepOf`, `choiceOf`, `armOf`, `lir.Var`). A self-checking build asks
//! that each statement's temporaries are those `sema.stmtTemps` lists.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const lir = @import("lir.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const StorageKind = lir.StorageKind;
const StorageBy = lir.StorageBy;
const StorageLife = lir.StorageLife;
const VarId = lir.VarId;
const ExprId = lir.ExprId;
const RegionId = lir.RegionId;

/// Whether each statement's temporaries are checked against
/// `sema.stmtTemps` (`-Dself-check`).
pub const enabled = @import("build_options").self_check;

/// A module's bodies, lowered.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    /// The module's compile-time body (`Options.checked`), and its owner's
    /// index while it may be freed alone (`dropConstants`): when no
    /// closure in it was lowered with it.
    consts: std.heap.ArenaAllocator,
    constants: ?u32 = null,
    /// Each frame owner of the module (`SemContext.frame_owners`), by its
    /// index there, then each compile-time function. Lowered for the
    /// checkers (`Options.checked`), then the closures of compile-time
    /// functions, and last the module itself, whose body is its
    /// constants and what its types declare by value.
    owners: []Owner = &.{},
    /// The index of each owner, by its root's key.
    roots: sema.FastMap(u64, u32) = .empty,
    /// The var of each node and kind, and of each binding, in every body
    /// lowered: the storage emit prints.
    vars: sema.FastMap(VarKey, *const lir.Var) = .empty,
    bindings: sema.FastMap(SymbolId, *const lir.Var) = .empty,
    /// The calls and array literals that hold their parts (a `call`
    /// region).
    holders: sema.FastMap(u64, void) = .empty,
    /// The owning temporaries of each statement and header that makes
    /// any, by its key, in the order they are made.
    temps: sema.FastMap(u64, []const Sexp) = .empty,
    /// Where emit reads each node's coercions (`chainOf`): the
    /// expression at the place of each node coerced there, and the value
    /// each node held in a var first is written with, by the node's key.
    /// Kept for emit's lowering alone.
    places: sema.FastMap(u64, Chain) = .empty,
    held: sema.FastMap(u64, Chain) = .empty,
    /// The owning temporaries made before anything their statement does
    /// can act (`Lowerer.flatten`), by their keys: each is written into
    /// its slot ahead of the statement.
    flat: sema.FastMap(u64, void) = .empty,
    /// The record of each call, by the call's key (`callOf`): what emit
    /// writes it as, and in a self-checking build what the ownership
    /// checker asserts it decides.
    calls: sema.FastMap(u64, *const lir.Call) = .empty,
    /// The place of each `member` and `index` that reaches one, by its
    /// key, and the body that names its root, for the self-checking
    /// build's asserts (`placeOf`).
    place_of: sema.FastMap(u64, PlaceAt) = .empty,
    /// What lowering decided of each node, by its key (`answersOf`):
    /// each node a body lowered, as it was lowered, and each other node
    /// of the module (its constants, its types' declarations) after.
    /// Kept for emit's lowering alone: on no `lir.Func`, so the checkers'
    /// lowering carries nothing for it.
    answers: sema.FastMap(u64, lir.Answers) = .empty,
    /// Where emit reads what lowering decided of a statement: the step
    /// of each assignment and binding's declaration (by its `set`), loop,
    /// and `match`, and the `match` of each value, by the node's key; the
    /// region of each `match` arm, by the arm's. Kept for emit's lowering
    /// alone (`assignOf`, `stepOf`, `choiceOf`, `armOf`).
    steps: sema.FastMap(u64, *const lir.Step) = .empty,
    choices: sema.FastMap(u64, *const lir.Expr.Choice) = .empty,
    arms: sema.FastMap(u64, *const lir.Region) = .empty,

    pub const PlaceAt = struct { f: *const lir.Func, i: u32 };

    pub const VarKey = struct { node: u64, kind: StorageKind };

    pub const Owner = struct {
        root: Sexp,
        /// The body around it, for a closure.
        parent: ?u32,
        /// A compile-time function's, which no program runs: emit
        /// writes none.
        ct: bool = false,
        func: ?*lir.Func = null,
        /// Why it was not lowered: the first construct lowering does not
        /// cover, and its family.
        skip: ?Skip = null,
    };

    pub const Skip = struct { node: Sexp, family: []const u8 };

    pub fn deinit(m: *Module) void {
        m.consts.deinit();
        m.arena.deinit();
    }

    /// The checkers have walked the module's compile-time body: free it.
    pub fn dropConstants(m: *Module) void {
        const i = m.constants orelse return;
        m.owners[i].func = null;
        m.constants = null;
        _ = m.consts.reset(.free_all);
        if (enabled) m.readMaps();
    }

    /// Read every entry of every module map, as a self-checking build
    /// does once the constants are freed: there their arena takes its
    /// memory from the page allocator (`lowerModule`), which unmaps it,
    /// so a map grown in it faults here on every system.
    fn readMaps(m: *const Module) void {
        var n: usize = 0;
        const info = @typeInfo(Module).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "iterator") and @hasDecl(T, "KV")) {
                var it = @field(m, name).iterator();
                while (it.next()) |_| n += 1;
            }
        }
        std.mem.doNotOptimizeAway(n);
    }

    /// The hidden var of `kind` made for `node`.
    pub fn varOf(m: *const Module, node: Sexp, kind: StorageKind) ?*const lir.Var {
        return m.vars.get(.{ .node = sema.decisionKeyOf(node) orelse return null, .kind = kind });
    }

    /// Whether call or array literal `node` holds its parts, each
    /// evaluated first.
    pub fn holdsParts(m: *const Module, node: Sexp) bool {
        return m.holders.contains(sema.decisionKeyOf(node) orelse return false);
    }

    /// The owning temporaries statement or header `node` makes, in the
    /// order they are made: not those of the blocks, closures, or headers
    /// it holds, which are their own.
    pub fn tempsOf(m: *const Module, node: Sexp) []const Sexp {
        return m.temps.get(sema.decisionKeyOf(node) orelse return &.{}) orelse &.{};
    }

    /// Whether owning temporary `node` is made before anything its
    /// statement does can act, so its slot can take it ahead of the
    /// statement.
    pub fn isFlat(m: *const Module, node: Sexp) bool {
        return m.flat.contains(sema.decisionKeyOf(node) orelse return false);
    }

    /// What emit's lowering decided of `node`.
    pub fn answersOf(m: *const Module, node: Sexp) ?lir.Answers {
        return m.answers.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// What emit's lowering decided of assignment or declaration `set`,
    /// kept on its step; null for one no body lowered.
    pub fn assignOf(m: *const Module, set: Sexp) ?lir.Assign {
        return switch ((m.stepOf(set) orelse return null).*) {
            .store => |x| x.answers,
            .bind => |x| x.answers,
            else => null,
        };
    }

    /// The step of assignment, declaration, loop, or `match` `node`.
    pub fn stepOf(m: *const Module, node: Sexp) ?*const lir.Step {
        return m.steps.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// The `lir.Expr.Choice` of `match` `node`, a statement's or a
    /// value's.
    pub fn choiceOf(m: *const Module, node: Sexp) ?*const lir.Expr.Choice {
        const key = sema.decisionKeyOf(node) orelse return null;
        if (m.steps.get(key)) |s| return if (s.* == .match) &s.match else null;
        return m.choices.get(key);
    }

    /// The region of `match` arm `arm`.
    pub fn armOf(m: *const Module, arm: Sexp) ?*const lir.Region {
        return m.arms.get(sema.decisionKeyOf(arm) orelse return null);
    }

    /// The coercions of `node` made where it is written: at its place,
    /// or, for a node held in a var first (a part a call holds, an
    /// assignment's new value) and written as the var is, `held`, in the
    /// value the var is written with.
    pub fn chainOf(m: *const Module, node: Sexp, held: bool) Chain {
        const key = sema.decisionKeyOf(node) orelse return .{};
        if (held) if (m.held.get(key)) |c| return c;
        return m.places.get(key) orelse .{};
    }

    /// The coercions of a node an expression makes, outermost first: the
    /// `coerce` expressions at its top, through any `hold` around them.
    pub const Chain = struct {
        f: ?*const lir.Func = null,
        at: ExprId = 0,

        pub fn next(c: *Chain) ?lir.Coercion {
            const f = c.f orelse return null;
            while (true) switch (f.exprs.items[c.at]) {
                .hold => |h| c.at = h.value,
                .coerce => |x| {
                    c.at = x.value;
                    return x.how.*;
                },
                else => return null,
            };
        }
    };

    /// The record of call `node`: in emit's lowering, of every call; in
    /// the checkers', only in a self-checking build.
    pub fn callOf(m: *const Module, node: Sexp) ?*const lir.Call {
        return m.calls.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// The place `member` or `index` node `node` reaches in body `f`;
    /// null in a build that does not check itself.
    pub fn placeOf(m: *const Module, f: *const lir.Func, node: Sexp) ?lir.Place {
        if (!enabled) return null;
        const at = m.place_of.get(sema.decisionKeyOf(node) orelse return null) orelse return null;
        if (at.f != f) return null;
        return f.places.items[at.i];
    }

    /// The var of binding `sym`.
    pub fn bindingOf(m: *const Module, sym: SymbolId) ?*const lir.Var {
        return m.bindings.get(sym);
    }
};

/// Whether call `c` evaluates its parts first, in a region of kind
/// `call` (`hoistsArgs`): an element operation's never do.
pub fn holdsParts(ctx: *const SemContext, c: Sexp) bool {
    return ctx.elemCallOf(ctx.calleeOf(c)) == null and hoistsArgs(ctx, c);
}

/// How a module is lowered.
pub const Options = struct {
    /// Every object's optional is held as a tagged struct, so each lift
    /// into one is made (`RIG_STRICT_OPTIONALS`, `sema.optionalRouted`).
    strict_optionals: bool = false,
    /// Lowered for the checkers, which walk every body: the module's
    /// constants are a compile-time body of their own, the closures of
    /// compile-time functions are owners, and the constructs emit's
    /// lowering does not cover (`Lowerer.uncovered`) are lowered all the
    /// same, since emit never reads this lowering.
    checked: bool = false,
};

/// Lower module `tree`, which sema checked, into `ctx.lowered`: first
/// the facts lowering and the ownership checker read that no checker
/// records (`markUsed`, `markMoved`). A module with an error other than
/// a lint is not lowered: nothing after sema reads it, and its lowering
/// rejections (`Lowerer.headerCopy`, `Lowerer.stepBindings`) are not
/// reported with its errors. Nor is one kept that lowering rejects. The
/// module graph frees it once the module's checks finish.
pub fn lowerChecked(ctx: *SemContext, tree: Sexp) !void {
    try markUsed(ctx);
    ctx.moved.deinit(ctx.allocator);
    ctx.moved = try .initEmpty(ctx.allocator, ctx.symbols.items.len);
    try markMoved(ctx, tree);
    if (diag.hasTypeErrorsIn(ctx.diagnostics.items)) return;
    var m = try lowerModule(ctx.allocator, ctx, tree, .{ .checked = true });
    if (diag.hasTypeErrorsIn(ctx.diagnostics.items)) return m.deinit();
    ctx.lowered = m;
}

/// Record the symbols a name reads after its declaration (a later
/// alternative's binds it again, `rebinds`), or a closure captures
/// (`SemContext.used`).
fn markUsed(ctx: *SemContext) !void {
    ctx.used.deinit(ctx.allocator);
    ctx.used = try .initEmpty(ctx.allocator, ctx.symbols.items.len);
    var names = ctx.facts.names.iterator();
    while (names.next()) |e| if (ctx.symbols.items[e.value_ptr.*].decl_leaf != e.key_ptr.* and !ctx.facts.rebinds.contains(@intCast(e.key_ptr.*))) ctx.used.set(e.value_ptr.*);
    for (ctx.symbols.items) |s| if (s.kind == .capture and s.origin < ctx.used.bit_length) ctx.used.set(s.origin);
}

/// Record the bindings a use may move out (`SemContext.moved`): the
/// name `<x` takes, as a move or a drop, a `for x in <v` source, a
/// `|<x|` capture, and a bare name at a tail of a value that leaves its
/// scope (`sema.eachTailPart`): `return x`, `break x`, a function's or a
/// closure's last value, and a value `if`, `match`, `??`, `catch`, loop,
/// or block. With them, the fields `<p.a.b` may move out of a binding
/// (`fieldMove`). Whether such a use moves is the ownership checker's
/// decision; it moves no binding this fact leaves out.
fn markMoved(ctx: *SemContext, e: Sexp) !void {
    if (e != .list) return;
    const head = e.kind() orelse {
        for (e.items()) |c| try markMoved(ctx, c);
        return;
    };
    switch (head) {
        .move => {
            moveName(ctx, ir.Move.operand(e));
            try fieldMove(ctx, ir.Move.operand(e));
        },
        .drop => {
            moveName(ctx, ir.Drop.target(e));
            try fieldMove(ctx, ir.Drop.target(e));
        },
        // `return a, b` takes each part as `return x` takes `x`.
        .@"return" => if (ir.Return.value(e).isKind(.results)) {
            for (ir.Results.values(ir.Return.value(e))) |part| try moveTail(ctx, part);
        } else try moveTail(ctx, ir.Return.value(e)),
        .@"break" => try moveTail(ctx, ir.Break.value(e)),
        .@"for" => {
            if (ir.For.mode(e).tag == .move) {
                moveName(ctx, ir.For.source(e));
                try fieldMove(ctx, ir.For.source(e));
            }
            try moveTail(ctx, e);
        },
        .@"if" => if (ir.If.@"else"(e) != .nil) try moveTail(ctx, e),
        .@"??", .@"catch", .match, .@"while", .raw_block => try moveTail(ctx, e),
        .cap_move => if (ctx.symbolOf(ir.get(e, .name))) |cap| ctx.moved.set(ctx.symbols.items[cap].origin),
        .fun => if (ir.Fun.returns(e) != .nil) try moveTail(ctx, ir.Fun.body(e)),
        .lambda => if (lambdaYields(ctx, e)) try moveTail(ctx, ir.Lambda.body(e)),
        else => {},
    }
    for (rig.children(e)) |c| try markMoved(ctx, c);
}

fn moveName(ctx: *SemContext, node: Sexp) void {
    if (node != .src) return;
    ctx.moved.set(ctx.symbolOf(node) orelse return);
}

fn moveTail(ctx: *SemContext, value: Sexp) std.mem.Allocator.Error!void {
    if (value == .src) return moveName(ctx, value);
    try sema.eachTailPart(value, ctx, moveTail);
}

/// Record the field `<p.a.b` may move out of binding `p`
/// (`SemContext.field_moves`): a path of fields from a binding, which
/// `<` does not take (`sema.moveSource`: `<p.o` of an optional field a
/// take can empty leaves `none`).
fn fieldMove(ctx: *SemContext, node: Sexp) !void {
    if (!node.isKind(.member)) return;
    if (sema.moveSource(ctx, node) == .optional_part) return;
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(ctx.allocator);
    var e = node;
    while (e.isKind(.member)) : (e = ir.Member.object(e)) {
        const name = ir.Member.name(e);
        if (name != .src) return;
        try fields.append(ctx.allocator, rig.leafText(ctx.source, name.src));
    }
    if (e != .src) return;
    const sym = ctx.symbolOf(e) orelse return;
    switch (ctx.symbols.items[sym].kind) {
        .local, .param, .capture => {},
        else => return,
    }
    if (ctx.symbols.items[sym].scope == sema.module_scope) return;
    std.mem.reverse([]const u8, fields.items);
    const path = try std.mem.join(ctx.allocator, ".", fields.items);
    const gop = try ctx.field_moves.getOrPut(ctx.allocator, sym);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |have| if (std.mem.eql(u8, have, path)) {
        ctx.allocator.free(path);
        return;
    };
    try gop.value_ptr.append(ctx.allocator, path);
}

/// Lower every body of module `tree`.
pub fn lowerModule(gpa: std.mem.Allocator, ctx: *SemContext, tree: Sexp, opts: Options) !Module {
    // A self-checking build gives the constants' arena pages of its own,
    // unmapped when it is freed (`Module.readMaps`).
    var m: Module = .{ .arena = .init(gpa), .consts = .init(if (enabled) std.heap.page_allocator else gpa) };
    errdefer m.deinit();
    const a = m.arena.allocator();
    // Each frame owner, then each compile-time function, whose body the
    // ownership checker walks though it never runs.
    const decls: []const Sexp = if (tree.isKind(.module)) ir.Module.decls(tree) else &.{};
    var owners: std.ArrayList(Module.Owner) = .empty;
    for (ctx.frame_owners.items) |fo| try owners.append(a, .{ .root = fo.root, .parent = fo.parent });
    for (decls) |d| if (rig.isCtFun(d)) try owners.append(a, .{ .root = rig.unpub(d), .parent = null, .ct = true });
    if (opts.checked) {
        const n = owners.items.len;
        for (0..n) |i| if (owners.items[i].ct) try ctClosures(a, &owners, ir.get(owners.items[i].root, .body), @intCast(i));
        if (tree.isKind(.module)) try owners.append(a, .{ .root = tree, .parent = null, .ct = true });
    }
    m.owners = owners.items;
    for (m.owners, 0..) |o, i| try m.roots.put(a, sema.decisionKeyOf(o.root).?, @intCast(i));
    var l: Lowerer = .{ .a = a, .ma = a, .gpa = gpa, .ctx = ctx, .module = &m, .opts = opts };
    defer l.deinit();
    try l.coercibleNodes();
    for (m.owners, 0..) |o, i| {
        if (o.root.isKind(.lambda)) continue;
        // The module's compile-time body goes in an arena of its own,
        // freed once the checker has walked it (`dropConstants`), unless
        // a closure in it was lowered with it.
        const constant = o.root.isKind(.module);
        var funcs: usize = 0;
        if (constant) {
            for (m.owners) |x| funcs += @intFromBool(x.func != null);
            l.a = m.consts.allocator();
        }
        defer l.a = a;
        l.lowerBody(@intCast(i)) catch |err| switch (err) {
            error.Uncovered => m.owners[i].skip = l.skip,
            else => |e| return e,
        };
        if (constant) {
            var after: usize = 0;
            for (m.owners) |x| after += @intFromBool(x.func != null);
            if (after == funcs + 1 and m.owners[i].func != null) m.constants = @intCast(i);
        }
    }
    if (!opts.checked) try l.decideRest(tree);
    // A closure is lowered with the body around it, or skipped with it.
    for (m.owners) |*o| if (o.func == null and o.skip == null) {
        o.skip = if (o.parent) |p| m.owners[p].skip else null;
    };
    // A binding's flag is set by any use in the module that may move it.
    // The module's constants are the checkers' alone: what emit reads
    // stays as emit's lowering makes it.
    for (m.owners) |o| if (o.func) |f| {
        if (o.root.isKind(.module)) continue;
        for (f.vars.items) |*v| switch (v.name) {
            .binding => |s| {
                v.flag = ctx.mayMove(s);
                try m.bindings.put(a, s, v);
            },
            .hidden => |k| if (sema.decisionKeyOf(v.node)) |key| try m.vars.put(a, .{ .node = key, .kind = k }, v),
        };
        for (f.regions.items) |*r| {
            if (r.kind == .call) try m.holders.put(a, sema.decisionKeyOf(r.node).?, {});
            if (opts.checked) continue;
            if (r.kind == .arm) try m.arms.put(a, sema.decisionKeyOf(r.node).?, r);
            for (r.steps.items) |*s| if (sema.decisionKeyOf(switch (s.*) {
                .store => |x| x.node,
                .bind => |x| x.set,
                .loop => |x| x.node,
                .each => |x| x.node,
                .match => |x| x.node,
                else => .nil,
            })) |key| try m.steps.put(a, key, s);
        }
        if (!opts.checked) for (f.exprs.items) |*e| switch (e.*) {
            .choice => |*c| try m.choices.put(a, sema.decisionKeyOf(c.node).?, c),
            else => {},
        };
        if (enabled or !opts.checked) for (f.exprs.items) |e| switch (e) {
            .op => |x| if (x.kind == .call) try m.calls.put(a, sema.decisionKeyOf(x.node).?, &f.calls.items[x.aux]),
            else => {},
        };
    };
    return m;
}

/// Each closure in `e`, the body of compile-time owner `parent` or a
/// closure in it, as an owner of `owners`: no frame owner, since it
/// never runs when the program does, but a body the checkers walk.
fn ctClosures(a: std.mem.Allocator, owners: *std.ArrayList(Module.Owner), e: Sexp, parent: u32) !void {
    if (e != .list) return;
    var p = parent;
    if (e.isKind(.lambda)) {
        try owners.append(a, .{ .root = e, .parent = parent, .ct = true });
        p = @intCast(owners.items.len - 1);
    }
    for (e.items()) |c| try ctClosures(a, owners, c, p);
}

/// Write module `tree`'s LIR (`rig check --facts=lir`), lowered again:
/// each lowered body, then each body not lowered and the construct that
/// stopped it.
pub fn writeModule(gpa: std.mem.Allocator, ctx: *SemContext, tree: Sexp, w: *std.Io.Writer) !void {
    var lowered = try lowerModule(gpa, ctx, tree, .{});
    defer lowered.deinit();
    const m = &lowered;
    for (m.owners) |o| if (o.func) |f| try lir.write(f, ctx, w);
    for (m.owners) |o| if (o.skip) |s| {
        const at = diag.lineCol(ctx.source, ctx.startOf(o.root));
        const why = diag.lineCol(ctx.source, ctx.startOf(s.node));
        try w.print("not lowered: {s} {d}:{d}: {s} at {d}:{d}\n", .{ @tagName(o.root.kind().?), at.line, at.col, s.family, why.line, why.col });
    };
}

// =============================================================================
// Lowering
// =============================================================================

const Error = error{ OutOfMemory, Uncovered };

const Lowerer = struct {
    /// Holds the current body: the module's constants have an arena of
    /// their own, freed once the checker has walked them
    /// (`Module.dropConstants`).
    a: std.mem.Allocator,
    /// Holds the module's maps, which outlive any one body: never the
    /// constants' arena.
    ma: std.mem.Allocator,
    /// Holds the lowerer's own maps, and the list each body's
    /// expressions grow in, which an arena would move each time it
    /// cannot grow it in place (`scratch`, `seal`).
    gpa: std.mem.Allocator,
    scratch: std.ArrayList(lir.Expr) = .empty,
    /// Mutable only for the frame count a task's record asks
    /// (`taskRecordIn`).
    ctx: *SemContext,
    module: *Module,
    opts: Options,
    f: *lir.Func = undefined,
    /// The region that declares the current statement's temporaries and
    /// the vars that live for an expression.
    stmt_region: RegionId = 0,
    /// The region that declares the bindings of the current block.
    block: RegionId = 0,
    /// The current statement's temporaries, in the order `sema.stmtTemps`
    /// lists them.
    temps: std.ArrayList(VarId) = .empty,
    /// The several results the body gives.
    results: ?[]const TypeId = null,
    /// The expression each node lowered to, the hidden var of each node
    /// and kind, the var of each binding, and the region holding the
    /// parts each call evaluates first.
    exprs: sema.FastMap(u64, ExprId) = .empty,
    hidden: sema.FastMap(Module.VarKey, VarId) = .empty,
    bindings: sema.FastMap(SymbolId, VarId) = .empty,
    call_blocks: sema.FastMap(u64, RegionId) = .empty,
    arms: sema.FastMap(u64, RegionId) = .empty,
    /// The headers that make temporaries, each lowered in a region of its
    /// own that ends them (`sema.firstStmtTemp`), and that region.
    headers: sema.FastMap(u64, ?RegionId) = .empty,
    /// The region that declares the bindings an `as` names: the body
    /// its condition guards.
    guarded: RegionId = 0,
    /// The region that declares the bindings of the `match` an `as_match`
    /// condition part is.
    as_match_scope: ?RegionId = null,
    skip: ?Module.Skip = null,
    /// The nodes any coercion fact names (`coercibleNodes`): `coerce`
    /// asks its eight questions of these alone.
    coercible: sema.FastMap(u64, void) = .empty,
    /// The locals a closure literal declares, which hold it in the frame
    /// (`lir.CallKind.stack_closure`).
    stack_closures: sema.FastMap(SymbolId, void) = .empty,

    fn deinit(l: *Lowerer) void {
        l.scratch.deinit(l.gpa);
        l.stack_closures.deinit(l.gpa);
        l.coercible.deinit(l.gpa);
        l.temps.deinit(l.gpa);
        l.exprs.deinit(l.gpa);
        l.hidden.deinit(l.gpa);
        l.bindings.deinit(l.gpa);
        l.call_blocks.deinit(l.gpa);
        l.arms.deinit(l.gpa);
        l.headers.deinit(l.gpa);
    }

    fn uncovered(l: *Lowerer, node: Sexp, family: []const u8) Error {
        l.skip = .{ .node = node, .family = family };
        return error.Uncovered;
    }

    fn addExpr(l: *Lowerer, e: lir.Expr) Error!ExprId {
        return l.f.addExpr(l.gpa, e);
    }

    fn region(l: *Lowerer, r: RegionId) *lir.Region {
        return l.f.region(r);
    }

    fn step(l: *Lowerer, r: RegionId, s: lir.Step) Error!void {
        try l.region(r).steps.append(l.a, s);
    }

    fn declare(l: *Lowerer, r: RegionId, v: VarId) Error!void {
        try l.region(r).decls.append(l.a, v);
    }

    // -------------------------------------------------------------------------
    // Vars
    // -------------------------------------------------------------------------

    /// The hidden var of `kind` for `node`, declared in region `in`, or
    /// null when one is already made: one node has one var of a kind.
    fn hiddenVar(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId) Error!?VarId {
        const key = sema.decisionKeyOf(node) orelse return null;
        const gop = try l.hidden.getOrPut(l.gpa, .{ .node = key, .kind = kind });
        if (gop.found_existing) return null;
        const v = try l.f.addVar(l.a, .{ .node = node, .name = .{ .hidden = kind }, .by = by, .life = life, .drop = drop });
        gop.value_ptr.* = v;
        try l.declare(in, v);
        return v;
    }

    /// A hidden var for `node` that holds its value where it stands.
    fn holdVar(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId) Error!void {
        const v = (try l.hiddenVar(node, kind, by, life, drop, in)) orelse return;
        if (l.exprOf(node)) |e| try l.f.holdIn(l.gpa, e, v);
    }

    /// A hidden var for `node` that its region `in` evaluates first, in
    /// its turn: the node's place in the tree reads the var.
    fn hoistVar(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId) Error!void {
        // An assignment's new value is held as the type it is stored as.
        return l.hoistHeld(node, kind, by, life, drop, in, if (kind == .new_value) .all else .read);
    }

    /// Which coercions of a value held in a var first are made where the
    /// var is written: none of those made where it is read
    /// (`readCoercion`), those and its lift, or all.
    const Held = enum { read, lifted, all };

    /// `hoistVar`, making the coercions `held` says where the var is
    /// written, and the rest where it is read.
    fn hoistHeld(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId, held: Held) Error!void {
        const v = (try l.hiddenVar(node, kind, by, life, drop, in)) orelse return;
        var e = l.exprOf(node) orelse return;
        // The coercions made where the var is read stay there; the rest
        // are made as it is written.
        while (l.f.exprs.items[e] == .coerce and readCoercion(held, l.f.exprs.items[e].coerce.how.*)) e = l.f.exprs.items[e].coerce.value;
        const moved = try l.addExpr(l.f.exprs.items[e]);
        l.f.exprs.items[e] = .{ .@"var" = .{ .v = v, .node = node } };
        try l.step(in, .{ .bind = .{ .v = v, .value = moved } });
        if (!l.opts.checked) try l.module.held.put(l.ma, sema.decisionKeyOf(node).?, .{ .f = l.f, .at = moved });
    }

    /// Lowering the module's compile-time body, which only the checkers
    /// read, and whose arena is freed alone: the module's maps for emit
    /// (`temps`, `coerced`, `answers`) hold nothing of it.
    fn inConstants(l: *const Lowerer) bool {
        return l.f.root.isKind(.module);
    }

    fn exprOf(l: *Lowerer, node: Sexp) ?ExprId {
        return l.exprs.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// The var of binding `name`, declared in the current block.
    fn bindingVar(l: *Lowerer, name: Sexp, in: RegionId) Error!?VarId {
        const sym = l.ctx.symbolOf(name) orelse return null;
        const v = try l.f.addVar(l.a, .{ .node = name, .name = .{ .binding = sym }, .drop = bindingDrop(l.ctx, sym) });
        try l.bindings.put(l.gpa, sym, v);
        try l.declare(in, v);
        return v;
    }

    // -------------------------------------------------------------------------
    // Bodies
    // -------------------------------------------------------------------------

    fn lowerBody(l: *Lowerer, oi: u32) Error!void {
        const decl = l.module.owners[oi].root;
        const f = try l.a.create(lir.Func);
        f.* = .{ .root = decl, .exprs = l.scratch };
        l.scratch = .empty;
        l.f = f;
        errdefer f.exprs.deinit(l.gpa);
        l.exprs.clearRetainingCapacity();
        l.hidden.clearRetainingCapacity();
        l.bindings.clearRetainingCapacity();
        l.call_blocks.clearRetainingCapacity();
        l.arms.clearRetainingCapacity();
        l.headers.clearRetainingCapacity();
        l.temps.clearRetainingCapacity();
        f.body = try f.addRegion(l.a, decl, .body);
        l.block = f.body;
        l.stmt_region = f.body;
        l.results = null;
        if (decl.isKind(.module)) {
            try l.constants(decl, f.body);
            try l.seal(f);
            l.module.owners[oi].func = f;
            return;
        }
        if (decl.isKind(.fun) or decl.isKind(.sub)) {
            if (fnType(l.ctx, typeOf(l.ctx, ir.get(decl, .name)))) |ft| l.results = sema.resultsOf(l.ctx, ft.returns);
        }
        const params: Sexp = if (decl.isKind(.@"test")) .nil else ir.get(decl, .params);
        if (params == .list) for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            _ = try l.bindingVar(name, f.body);
            if (par.isKind(.default)) {
                // A default is evaluated where each call is: storage in
                // one is not lowered.
                const before = f.vars.items.len;
                _ = try l.expr(ir.get(par, .value));
                if (f.vars.items.len != before and !l.opts.checked) return l.uncovered(par, "default values");
            }
        };
        const body = ir.get(decl, .body);
        const value = try l.stmts(body, f.body, decl.isKind(.fun) and ir.Fun.returns(decl) != .nil);
        f.region(f.body).value = value;
        try l.heldHeaders(decl, body);
        try l.seal(f);
        l.module.owners[oi].func = f;
    }

    /// The statements of module `decl` that no function holds, into
    /// region `r`, each its own: its constants, and what its types
    /// declare by value, as the ownership checker walks them
    /// (`walkDecl`).
    fn constants(l: *Lowerer, decl: Sexp, r: RegionId) Error!void {
        switch (decl.kind() orelse return) {
            .module => {
                for (ir.Module.decls(decl)) |d| if (rig.isModuleConst(d)) try l.constants(d, r);
                for (ir.Module.decls(decl)) |d| if (!rig.isModuleConst(d)) try l.constants(d, r);
            },
            .@"struct", .@"enum", .errors, .generic_struct => for (ir.rest(decl, .members)) |c| try l.constants(c, r),
            .@"pub" => try l.constants(ir.Pub.decl(decl), r),
            .fun, .sub, .drop_decl, .@"test", .api, .api_add, .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .variant, .@":" => {},
            else => try l.stmt(decl, r),
        }
    }

    /// Copy body `f`'s expressions to the arena at their final size, and
    /// keep the larger of their list and `scratch` for the next body.
    fn seal(l: *Lowerer, f: *lir.Func) Error!void {
        var list = f.exprs;
        const n = list.items.len;
        f.exprs = .empty;
        if (n > 0) {
            // Copied over at once, so the arena need not fill it first.
            const bytes = l.a.rawAlloc(n * @sizeOf(lir.Expr), .of(lir.Expr), @returnAddress()) orelse return error.OutOfMemory;
            const out = @as([*]lir.Expr, @ptrCast(@alignCast(bytes)))[0..n];
            @memcpy(out, list.items);
            f.exprs = .fromOwnedSlice(out);
        }
        list.clearRetainingCapacity();
        if (list.capacity > l.scratch.capacity) std.mem.swap(std.ArrayList(lir.Expr), &list, &l.scratch);
        list.deinit(l.gpa);
    }

    /// The statements of `body` into region `into`; the value of the
    /// last, when `yields` and it is a value.
    fn stmts(l: *Lowerer, body: Sexp, into: RegionId, yields: bool) Error!?ExprId {
        const list: []const Sexp = if (body.isKind(.block)) ir.Block.stmts(body) else &.{body};
        var value: ?ExprId = null;
        for (list, 0..) |s, i| {
            if (yields and i == list.len - 1 and sema.yieldsValue(l.ctx.source, s) and !s.isKind(.labeled)) {
                value = try l.valueStmt(s);
            } else try l.stmt(s, into);
        }
        try l.blockTasks(body, into);
        return value;
    }

    /// The parameters whose header the body holds in a local
    /// (`held_header`): a write view of a `String`, or of a `List` with
    /// no inline room (`holdsHeaderType`), which the body uses in
    /// a loop. Emit copies the header in at the top of the body, binds
    /// the parameter's name to the copy, and writes it back by `defer`,
    /// so the loop keeps the length and capacity in registers. The call's
    /// write view is the caller's place's only one while the body runs
    /// (Core §2, sentence 5), so the copy cannot be told apart from the
    /// place. None is held where the body could hand the copy's address
    /// beyond the call: a task or closure that names the parameter, a
    /// `raw` block, or a result that holds a view.
    fn heldHeaders(l: *Lowerer, decl: Sexp, body: Sexp) Error!void {
        const ctx = l.ctx;
        if (!decl.isKind(.fun) and !decl.isKind(.sub)) return;
        const params = ir.get(decl, .params);
        if (params != .list) return;
        const f = fnType(ctx, typeOf(ctx, ir.get(decl, .name))) orelse return;
        if (sema.mayHoldMarkedView(ctx, f.returns)) return;
        var raw: ?bool = null;
        for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            if (std.mem.eql(u8, rig.leafText(ctx.source, name.src), "@")) continue;
            const sym = ctx.symbolOf(name) orelse continue;
            const ty = known(ctx, ctx.symbols.items[sym].ty) orelse continue;
            if (!holdsHeaderType(ctx, ty)) continue;
            if (!usedIn(ctx, body, sym, .loop)) continue;
            if (usedIn(ctx, body, sym, .escape)) continue;
            // None is held in a body with a `raw` block, found once.
            if (raw == null) raw = containsKind(body, .raw_block);
            if (raw.?) return;
            _ = try l.hiddenVar(name, .held_header, .copy, .block, null, l.f.body);
        }
    }

    // -------------------------------------------------------------------------
    // Statements
    // -------------------------------------------------------------------------

    /// Statement `s`, in a region of its own that holds its temporaries.
    fn stmt(l: *Lowerer, s: Sexp, into: RegionId) Error!void {
        const r = try l.openStmt(s);
        try l.stmtBody(s, r.region);
        try l.closeStmt(s, r, into);
    }

    /// The last statement of a body, whose value the body yields.
    fn valueStmt(l: *Lowerer, s: Sexp) Error!ExprId {
        const o = try l.openStmt(s);
        const value_1 = try l.expr(s);
        l.region(o.region).value = value_1;
        try l.checkTemps(s, o.temps);
        if (l.temps.items.len > o.temps) try l.flatten(o.region);
        l.stmt_region = o.stmt;
        l.temps.shrinkRetainingCapacity(o.temps);
        return l.addExpr(.{ .block = o.region });
    }

    const Open = struct { region: RegionId, stmt: RegionId, temps: usize };

    fn openStmt(l: *Lowerer, s: Sexp) Error!Open {
        const r = try l.f.addRegion(l.a, s, .stmt);
        const o: Open = .{ .region = r, .stmt = l.stmt_region, .temps = l.temps.items.len };
        l.stmt_region = r;
        return o;
    }

    fn closeStmt(l: *Lowerer, s: Sexp, o: Open, into: RegionId) Error!void {
        try l.closeStmtBy(s, o, into, true);
    }

    /// `closeStmt`, which records the statement's flat temporaries
    /// (`flatten`) only when `flat`.
    fn closeStmtBy(l: *Lowerer, s: Sexp, o: Open, into: RegionId, flat: bool) Error!void {
        try l.checkTemps(s, o.temps);
        if (flat and l.temps.items.len > o.temps) try l.flatten(o.region);
        l.stmt_region = o.stmt;
        l.temps.shrinkRetainingCapacity(o.temps);
        try l.step(into, .{ .region = o.region });
    }

    /// Record the temporaries statement `s` made, from `first` in
    /// `temps`. A self-checking build asks that they are those
    /// `sema.stmtTemps` lists, in its order.
    fn checkTemps(l: *Lowerer, s: Sexp, first: usize) Error!void {
        const have = l.temps.items[first..];
        if (have.len > 0 and !l.inConstants()) {
            const nodes = try l.ma.alloc(Sexp, have.len);
            for (have, nodes) |v, *n| n.* = l.f.vars.items[v].node;
            try l.module.temps.put(l.ma, sema.decisionKeyOf(s).?, nodes);
        }
        if (!enabled) return;
        var want: std.ArrayList(Sexp) = .empty;
        try sema.stmtTemps(l.ctx, l.a, s, &want);
        var ok = want.items.len == have.len;
        if (ok) for (want.items, have) |w, v| {
            if (sema.decisionKeyOf(w) != sema.decisionKeyOf(l.f.vars.items[v].node)) ok = false;
        };
        if (!ok) {
            const at = diag.lineCol(l.ctx.source, l.ctx.startOf(s));
            const first_want: Sexp = if (want.items.len > 0) want.items[0] else .nil;
            const w_at = diag.lineCol(l.ctx.source, l.ctx.startOf(first_want));
            std.debug.panic("{s}:{d}:{d}: internal error: lir: a statement's temporaries are not those sema lists ({d} made, {d} listed, the first a `{s}` at {d}:{d})", .{ l.ctx.name, at.line, at.col, have.len, want.items.len, @tagName(first_want.kind() orelse .module), w_at.line, w_at.col });
        }
    }

    /// Record which temporaries of statement or header region `r` are
    /// made before anything the statement does can act (`Module.flat`).
    /// Its parts are walked in the order they run while each part so far
    /// only reads (`Flat.walk`). A temporary reached so, whose value
    /// changes no var read before it (`Flat.changesAny`), is made the
    /// same whether its slot takes it in place or ahead of the
    /// statement. A statement that stores to anything but a name, or
    /// whose steps are not plain values, keeps every temporary in place.
    fn flatten(l: *Lowerer, r: RegionId) Error!void {
        const steps = l.region(r).steps.items;
        for (steps) |s| switch (s) {
            .eval, .bind, .jump => {},
            .store => |st| if (l.f.exprs.items[st.target] != .@"var" or rig.bindingKindOf(ir.Set.op(st.node)).operator() != null) return,
            else => return,
        };
        var w: Flat = .{ .l = l };
        defer w.read.deinit(l.gpa);
        for (steps) |s| switch (s) {
            .eval => |e| try w.walk(e),
            .bind => |b| try w.walk(b.value),
            .jump => |j| if (j.value) |v| try w.walk(v),
            .store => |st| try w.walk(st.value),
            else => unreachable,
        };
        if (l.region(r).value) |v| try w.walk(v);
    }

    /// The walk `flatten` makes of a statement's parts.
    const Flat = struct {
        l: *Lowerer,
        /// Every part walked so far only reads: a literal, a constant, a
        /// var, a field of one, a view of one, or a value made of those.
        clean: bool = true,
        /// The vars those parts read.
        read: std.ArrayList(VarId) = .empty,

        fn walk(w: *Flat, id: ExprId) Error!void {
            if (!w.clean) return;
            const l = w.l;
            switch (l.f.exprs.items[id]) {
                .leaf => {},
                .@"var" => |u| try w.read.append(l.gpa, u.v),
                .op => |o| {
                    const kind = o.node.kind();
                    // A `catch`, and a `!` in a function with no slot of
                    // its own, give their value the slot its failure's
                    // fields go in, which emit declares around it.
                    if (kind == .@"catch" or kind == .propagate) {
                        w.clean = false;
                        return;
                    }
                    for (o.args, 0..) |a, i| {
                        // `a and b`, `a or b`, and `a ?? b` run `b` only
                        // on a condition.
                        if (i > 0 and (kind == .@"and" or kind == .@"or" or kind == .@"??")) {
                            w.clean = false;
                            return;
                        }
                        try w.walk(a);
                    }
                    const reads = if (kind) |k| switch (k) {
                        .member, .read, .write, .kwarg, .enum_lit, .symbol, .paren, .array, .tuple => true,
                        else => false,
                    } else true;
                    if (!reads) w.clean = false;
                },
                .coerce => |c| {
                    try w.walk(c.value);
                    switch (c.how.*) {
                        .view, .deref, .lift, .widen, .splat => {},
                        .duration, .erase, .fail => w.clean = false,
                    }
                },
                .hold => |h| {
                    const before = w.read.items.len;
                    try w.walk(h.value);
                    switch (l.f.vars.items[h.v].name) {
                        .hidden => |k| switch (k) {
                            .temp => if (!w.changesAny(h.value, w.read.items[0..before])) {
                                try l.module.flat.put(l.ma, sema.decisionKeyOf(l.f.vars.items[h.v].node).?, {});
                                // Made ahead of the statement, it is no
                                // longer among the parts before the rest.
                                w.read.shrinkRetainingCapacity(before);
                                w.clean = true;
                            } else {
                                w.clean = false;
                            },
                            .new_value, .zig_temp, .leaf, .viewed => {},
                            else => w.clean = false,
                        },
                        .binding => w.clean = false,
                    }
                },
                .block, .branch, .choice, .closure => w.clean = false,
            }
        }

        /// Whether expression `id` may change what any of `vars` holds:
        /// a write view or a move of a place one of them roots, a read
        /// of a binding a use may move, or a construct with statements
        /// of its own.
        fn changesAny(w: *const Flat, id: ExprId, vars: []const VarId) bool {
            if (vars.len == 0) return false;
            const f = w.l.f;
            return switch (f.exprs.items[id]) {
                .leaf => false,
                .@"var" => |u| switch (f.vars.items[u.v].name) {
                    .binding => |sym| w.l.ctx.mayMove(sym) and std.mem.indexOfScalar(VarId, vars, u.v) != null,
                    .hidden => false,
                },
                .op => |o| blk: {
                    if (o.node.kind() == .write or o.node.kind() == .move) {
                        const root = w.rootVar(o.args[0]) orelse break :blk true;
                        if (std.mem.indexOfScalar(VarId, vars, root) != null) break :blk true;
                    }
                    for (o.args) |a| if (w.changesAny(a, vars)) break :blk true;
                    break :blk false;
                },
                .coerce => |c| w.changesAny(c.value, vars),
                .hold => |h| w.changesAny(h.value, vars),
                .block, .branch, .choice, .closure => true,
            };
        }

        /// The var at the root of place `id`, or null for a place not
        /// rooted at a var.
        fn rootVar(w: *const Flat, id: ExprId) ?VarId {
            const f = w.l.f;
            return switch (f.exprs.items[id]) {
                .@"var" => |u| u.v,
                .op => |o| if (o.args.len > 0 and (o.node.kind() == .member or o.node.kind() == .index or o.node.kind() == .paren)) w.rootVar(o.args[0]) else null,
                .coerce => |c| w.rootVar(c.value),
                else => null,
            };
        }
    };

    fn stmtBody(l: *Lowerer, s: Sexp, r: RegionId) Error!void {
        const head = s.kind() orelse return l.step(r, .{ .eval = try l.expr(s) });
        switch (head) {
            .set => try l.assign(s, r),
            .destructure => try l.destructure(s, r),
            .drop => try l.dropStmt(s, r),
            .@"return", .@"break", .@"continue" => try l.jump(s, r),
            .pass, .rarely => {},
            .block => {
                const b = try l.blockRegion(s, .block);
                try l.step(r, .{ .region = b });
            },
            .raw_block => {
                const b = try l.blockRegion(ir.RawBlock.body(s), .block);
                try l.step(r, .{ .region = b });
            },
            .@"defer", .@"errdefer" => {
                const body = ir.get(s, .body);
                const b = try l.f.addRegion(l.a, s, .block);
                const saved = l.block;
                defer l.block = saved;
                l.block = b;
                if (body.isKind(.block)) {
                    _ = try l.stmts(body, b, false);
                } else if (body == .list) {
                    // One statement is a statement of its own
                    // (`sema.sharesStmtTemps`), run where the `defer`
                    // runs, so none of its temporaries is made ahead.
                    const o = try l.openStmt(body);
                    try l.stmtBody(body, o.region);
                    try l.closeStmtBy(body, o, b, false);
                } else try l.stmtBody(body, b);
                try l.step(r, .{ .region = b });
            },
            .@"if" => {
                const g = try l.guard(s, false);
                try l.step(g.scope, .{ .@"if" = .{ .node = s, .cond = g.cond, .then = g.then, .@"else" = g.@"else" } });
                try l.step(r, .{ .region = g.scope });
            },
            .@"while" => try l.whileLoop(s, r),
            .labeled => {
                _ = try l.expr(ir.Labeled.label(s));
                const inner = ir.Labeled.stmt(s);
                if (inner.isKind(.@"for")) return l.forLoop(inner, r);
                // Any other statement a label names is a statement of its
                // own, in the block the label makes.
                if (!inner.isKind(.@"while")) return l.stmt(inner, r);
                try l.whileLoop(inner, r);
            },
            .@"for" => try l.forLoop(s, r),
            .match => {
                const c = try l.matchOf(s, false);
                try l.step(c.scope, .{ .match = c.choice });
                try l.step(r, .{ .region = c.scope });
            },
            else => try l.step(r, .{ .eval = try l.expr(s) }),
        }
    }

    /// A block's statements, in a region of `kind` that declares its
    /// bindings.
    fn blockRegion(l: *Lowerer, body: Sexp, kind: lir.Region.Kind) Error!RegionId {
        const b = try l.f.addRegion(l.a, body, kind);
        const saved = l.block;
        defer l.block = saved;
        l.block = b;
        _ = try l.stmts(body, b, false);
        return b;
    }

    /// The tasks of `block` whose records stay in its frame, region `r`
    /// (`taskRecordIn`).
    fn blockTasks(l: *Lowerer, block: Sexp, r: RegionId) Error!void {
        if (!block.isKind(.block)) return;
        for (rig.children(block)) |s| {
            const task = (try taskRecordIn(l.ctx, s, block)) orelse continue;
            _ = try l.hiddenVar(task, .task_record, .owned, .block, null, r);
        }
    }

    fn jump(l: *Lowerer, s: Sexp, r: RegionId) Error!void {
        const value: Sexp = if (s.isKind(.@"continue")) .nil else ir.get(s, .value);
        const v: ?ExprId = if (value != .nil) try l.expr(value) else null;
        if (enabled) if (v) |id| try l.role(id, value, if (s.isKind(.@"break")) .brk else .ret);
        if (s.isKind(.@"return")) try l.returnParts(s);
        try l.step(r, .{ .jump = .{ .node = s, .value = v } });
    }

    /// The parts of `return a, b` its `argument` var holds: how each of
    /// the function's results drops.
    fn returnParts(l: *Lowerer, s: Sexp) Error!void {
        const value = ir.Return.value(s);
        if (!value.isKind(.results) or !hoistsResults(l.ctx, value)) return;
        const tys = l.results orelse return;
        const key = sema.decisionKeyOf(value) orelse return;
        const v = l.hidden.get(.{ .node = key, .kind = .argument }) orelse return;
        const kinds = try l.a.alloc(?sema.ResourceKind, tys.len);
        for (tys, kinds) |t, *k| k.* = sema.resourceKind(l.ctx, t);
        l.f.vars.items[v].parts = kinds;
    }

    fn dropStmt(l: *Lowerer, s: Sexp, r: RegionId) Error!void {
        const target = ir.Drop.target(s);
        const e = try l.expr(target);
        if (target == .src) {
            if (l.ctx.symbolOf(target)) |sym| if (l.bindings.get(sym)) |v| return l.step(r, .{ .drop = .{ .v = v, .node = target } });
            return l.step(r, .{ .eval = e });
        }
        // `<e` of anything but a name drops what it takes.
        if (enabled) try l.role(e, target, .binding);
        try l.holdVar(target, .discard, .owned, .statement, dropOf(l.ctx, target), l.stmt_region);
        try l.step(r, .{ .eval = e });
    }

    /// An assignment, or a binding's declaration, into region `r`.
    fn assign(l: *Lowerer, set: Sexp, r: RegionId) Error!void {
        const ctx = l.ctx;
        const kind = rig.bindingKindOf(ir.Set.op(set));
        const target = ir.Set.target(set);
        const value = ir.Set.value(set);
        const sym: ?SymbolId = if (target == .src) ctx.symbolOf(target) else null;
        const declares = if (sym) |s| ctx.symbols.items[s].decl_pos == target.src.pos else false;
        // The value's temporaries are made before the target's (Core §6).
        const t0 = l.temps.items.len;
        var declared: ?VarId = null;
        if (declares and value.isKind(.lambda)) try l.stack_closures.put(l.gpa, sym.?, {});
        const target_e = if (declares) blk: {
            declared = try l.bindingVar(target, l.block);
            const e = try l.addExpr(.{ .@"var" = .{ .v = declared.?, .node = target } });
            try l.note(target, e);
            break :blk e;
        } else try l.expr(target);
        const t1 = l.temps.items.len;
        var value_e = try l.expr(value);
        // A field or element takes the value, as a binding does, but for
        // an operator's assignment to a name, which reads it.
        const sink: lir.Operand.Sink = if (target != .src) .field else switch (kind) {
            .default, .fixed, .shadow => .binding,
            else => .none,
        };
        if (enabled) try l.role(value_e, value, sink);
        std.mem.rotate(VarId, l.temps.items[t0..], t1 - t0);
        l.declareInOrder(l.temps.items[t0..]);
        const order = setOrder(ctx, set);
        if (kind.operator() != null) {
            try l.openAssign(set, order, r);
            if (compoundCall(ctx, set) != null and target != .src) try l.hoistVar(target, .slot, .pointer, .assignment, null, r);
            return l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e, .answers = l.assignAnswers(set, order, false) } });
        }
        if (target != .src) {
            if (kind == .default) try l.placeAssign(set, order, r);
            return l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e, .answers = l.assignAnswers(set, order, false) } });
        }
        if (std.mem.eql(u8, rig.leafText(ctx.source, target.src), "_")) {
            try l.holdVar(value, .discard, .owned, .statement, dropOf(ctx, value), l.stmt_region);
            return l.step(r, .{ .eval = value_e });
        }
        if (declared) |v| return l.step(r, .{ .bind = .{ .v = v, .value = value_e, .set = set, .answers = l.assignAnswers(set, order, true) } });
        // A reassigned resource's new value is made before the old one is
        // dropped, as any store whose value can act is.
        if (sym != null and (order.drops_old or storesAfterValue(ctx, set))) {
            try l.hoistVar(value, .new_value, .owned, .assignment, dropOf(ctx, value), r);
            value_e = l.exprOf(value) orelse value_e;
            if (enabled) try l.role(value_e, value, sink);
        }
        try l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e, .answers = l.assignAnswers(set, order, false) } });
    }

    /// What emit's lowering decides of assignment or declaration `set`,
    /// whose order is `order`; nothing in the checkers' lowering.
    fn assignAnswers(l: *const Lowerer, set: Sexp, order: lir.SetOrder, declares: bool) lir.Assign {
        if (l.opts.checked) return .{};
        const ctx = l.ctx;
        return .{
            .order = order,
            .fills_in_place = fillsInPlace(ctx, set),
            .lane_checked = laneChecked(ctx, set),
            .compound = if (rig.bindingKindOf(ir.Set.op(set)).operator() != null) compoundCall(ctx, set) else null,
            .hold = if (declares) bindHold(ctx, set) else null,
        };
    }

    /// Declare `temps`, temporaries of the current statement, in their
    /// region in the order given, the order emit drops them in: each
    /// takes the place of one of them among the region's decls.
    fn declareInOrder(l: *Lowerer, temps: []const VarId) void {
        if (temps.len < 2) return;
        var next: usize = 0;
        for (l.region(l.stmt_region).decls.items) |*d| {
            if (std.mem.indexOfScalar(VarId, temps, d.*) == null) continue;
            d.* = temps[next];
            next += 1;
            if (next == temps.len) return;
        }
    }

    /// An assignment to a field or element.
    fn placeAssign(l: *Lowerer, set: Sexp, order: lir.SetOrder, r: RegionId) Error!void {
        const ctx = l.ctx;
        const target = ir.Set.target(set);
        const through = assignedThrough(target);
        const place_ty = if (through) (if (typeOf(ctx, target)) |t| sema.writtenThrough(ctx, t) else null) else typeOf(ctx, target);
        if (target.isKind(.index)) if (typeOf(ctx, ir.Index.object(target))) |t| if (isCellListTy(ctx, t)) return l.openAssign(set, order, r);
        const holds_view = if (through) (if (place_ty) |t| sema.viewHeldAsPointer(ctx, t) else false) else (target != .src and isPtrViewExpr(ctx, target));
        if (holds_view or !order.drops_old) return l.openAssign(set, order, r);
        try l.hoistVar(ir.Set.value(set), .new_value, .owned, .assignment, dropOf(ctx, ir.Set.value(set)), r);
        if (order.held) try l.targetSteps(set, order, r);
        try l.hoistVar(target, .slot, .pointer, .assignment, null, r);
    }

    fn openAssign(l: *Lowerer, set: Sexp, order: lir.SetOrder, r: RegionId) Error!void {
        if (!order.held) return;
        const value = ir.Set.value(set);
        if (!isPureArg(l.ctx, value)) try l.hoistVar(value, .new_value, .owned, .assignment, dropOf(l.ctx, value), r);
        try l.targetSteps(set, order, r);
    }

    fn targetSteps(l: *Lowerer, set: Sexp, order: lir.SetOrder, r: RegionId) Error!void {
        const Steps = struct {
            l: *Lowerer,
            order: lir.SetOrder,
            r: RegionId,

            pub fn step(st: @This(), s: SetStep) Error!void {
                switch (s.role) {
                    .value => {},
                    .base => if (st.order.base) try st.l.hoistVar(s.node, .base, .pointer, .assignment, null, st.r),
                    .index => if (!isPureArg(st.l.ctx, s.node)) try st.l.hoistVar(s.node, .index, .owned, .assignment, null, st.r),
                }
            }
        };
        try eachTargetStep(ir.Set.target(set), Steps{ .l = l, .order = order, .r = r });
    }

    /// `q, r = f()`: the call's results, held for the statement while
    /// each target takes its own.
    fn destructure(l: *Lowerer, d: Sexp, r: RegionId) Error!void {
        const targets = try l.f.addRegion(l.a, d, .value);
        const group = ir.Destructure.targets(d);
        if (group == .list) for (group.items()) |t| {
            if (t.isKind(.set)) try l.assign(t, targets) else _ = try l.expr(t);
        };
        const value = ir.Destructure.value(d);
        const value_e = try l.expr(value);
        if (enabled) try l.role(value_e, value, .binding);
        const tys: []const TypeId = if (typeOf(l.ctx, value)) |t| switch (l.ctx.types.get(t)) {
            .results => |rs| rs,
            else => &.{},
        } else &.{};
        const v = (try l.hiddenVar(d, .results, .owned, .statement, null, r)) orelse return;
        const kinds = try l.a.alloc(?sema.ResourceKind, tys.len);
        for (tys, kinds) |t, *k| k.* = sema.resourceKind(l.ctx, t);
        l.f.vars.items[v].parts = kinds;
        try l.step(r, .{ .bind = .{ .v = v, .value = value_e } });
        try l.step(r, .{ .region = targets });
    }

    // -------------------------------------------------------------------------
    // Expressions
    // -------------------------------------------------------------------------

    /// Record that node `n` lowered to `e`; emit's lowering records
    /// where, and what it decides of `n` (`decide`).
    fn note(l: *Lowerer, n: Sexp, e: ExprId) Error!void {
        const k = sema.decisionKeyOf(n) orelse return;
        try l.exprs.put(l.gpa, k, e);
        if (!l.opts.checked) try l.decide(n, k);
    }

    /// What emit's lowering decides of node `n`, of key `k`, and of the
    /// operands its form decides of. Out of line, so the checkers'
    /// lowering pays nothing for it.
    noinline fn decide(l: *Lowerer, n: Sexp, k: u64) std.mem.Allocator.Error!void {
        const ctx = l.ctx;
        try l.module.answers.put(l.ma, k, .{});
        l.answer(n, .hands, sema.handsOver(ctx, n).kind);
        l.answer(n, .reaches_leaf, reachesLeaf(ctx, n));
        if (n != .list) return;
        switch (n.kind() orelse return) {
            .@"==", .@"!=" => for ([2]Sexp{ ir.get(n, .left), ir.get(n, .right) }) |operand| {
                l.answer(operand, .drops_when_tested, dropsWhenTested(ctx, operand));
            },
            .call => {
                l.answer(n, .self_hold, selfHold(ctx, n));
                l.answer(n, .consumes_self, consumedTemporary(ctx, n) != null);
                for (ir.Call.args(n)) |a| l.answer(argValue(a), .argument_hold, argumentHold(ctx, argValue(a)));
                if (ctx.isPrintCall(n) or stringCall(ctx, n) != null) for (ir.Call.args(n)) |a| {
                    l.answer(a, .prints_by_address, printsByAddress(ctx, a));
                };
            },
            .array => for (ir.Array.elems(n)) |v| l.answer(v, .argument_hold, argumentHold(ctx, v)),
            .panic => for (ir.Panic.args(n)) |a| l.answer(a, .prints_by_address, printsByAddress(ctx, a)),
            .template => for (0..rig.Template.slotCount(n)) |i| {
                const v = rig.Template.value(n, i);
                l.answer(v, .prints_by_address, printsByAddress(ctx, v));
            },
            .box => l.answer(n, .fills_in_place, fillsInPlace(ctx, n)),
            .@"+", .@"-", .@"*", .neg => l.answer(n, .lane_checked, laneChecked(ctx, n)),
            .as => {
                l.answer(ir.As.value(n), .views_optional_value, viewsOptionalValue(ctx, ir.As.value(n)));
                l.answer(n, .binds_string_bytes, bindsStringBytes(ctx, n));
                l.answer(n, .through_write, throughWrite(ctx, n));
            },
            .results => l.answer(n, .hoists_results, hoistsResults(ctx, n)),
            else => {},
        }
    }

    /// What emit's lowering decides of each node of `e` no body lowered
    /// (the module's constants, its types' declarations), operands first,
    /// as emit writes them from the tree.
    fn decideRest(l: *Lowerer, e: Sexp) std.mem.Allocator.Error!void {
        switch (e) {
            .list => {
                if (l.module.roots.get(sema.decisionKeyOf(e) orelse 0)) |i| if (l.module.owners[i].func != null) return;
                for (if (e.kind() == null) e.items() else rig.children(e)) |c| try l.decideRest(c);
            },
            .src => {},
            else => return,
        }
        const k = sema.decisionKeyOf(e) orelse return;
        if (!l.module.answers.contains(k)) try l.decide(e, k);
        if (e.isKind(.call)) {
            const rec = try l.ma.create(lir.Call);
            rec.* = l.callRecord(e);
            try l.module.calls.put(l.ma, k, rec);
        }
    }

    /// Keep `value` as what emit's lowering decides of `node`.
    fn answer(l: *Lowerer, node: Sexp, comptime field: std.meta.FieldEnum(lir.Answers), value: @FieldType(lir.Answers, @tagName(field))) void {
        const a = l.module.answers.getPtr(sema.decisionKeyOf(node) orelse return) orelse return;
        @field(a.*, @tagName(field)) = value;
    }

    /// Expression `e`: its operands first, in the tree's order, then the
    /// vars it makes, then the coercions that make its value the type its
    /// context takes.
    fn expr(l: *Lowerer, e: Sexp) Error!ExprId {
        const id = header: {
            if (e == .list) if (l.headers.get(sema.decisionKeyOf(e).?)) |h| if (h == null) break :header try l.header(e, sema.decisionKeyOf(e).?);
            const id = try l.made(e);
            try l.coerce(e, id);
            break :header id;
        };
        if (enabled) try l.role(id, e, .none);
        return id;
    }

    fn made(l: *Lowerer, e: Sexp) Error!ExprId {
        switch (e) {
            .src => {
                const id = if (l.ctx.symbolOf(e)) |sym| (if (l.bindings.get(sym)) |v| try l.addExpr(.{ .@"var" = .{ .v = v, .node = e } }) else try l.addExpr(.{ .leaf = e })) else try l.addExpr(.{ .leaf = e });
                try l.note(e, id);
                try l.viewRules(e);
                return id;
            },
            .list => {},
            else => return l.addExpr(.{ .leaf = e }),
        }
        const head = e.kind() orelse return l.op(e);
        switch (head) {
            .@"if" => {
                const g = try l.guard(e, true);
                const value_2 = try l.addExpr(.{ .branch = .{ .node = e, .cond = g.cond, .then = g.then, .@"else" = g.@"else" } });
                l.region(g.scope).value = value_2;
                const id = try l.addExpr(.{ .block = g.scope });
                try l.note(e, id);
                try l.temp(e);
                try l.viewRules(e);
                try l.conditionRules(e, g.scope);
                return id;
            },
            .as, .as_results => return l.asExpr(e),
            .match => {
                const c = try l.matchOf(e, true);
                const value = try l.addExpr(.{ .choice = c.choice });
                l.region(c.scope).value = value;
                const id = try l.addExpr(.{ .block = c.scope });
                try l.note(e, id);
                try l.temp(e);
                try l.viewRules(e);
                try l.matchRules(e, c.scope);
                return id;
            },
            .as_match => {
                const saved = l.as_match_scope;
                defer l.as_match_scope = saved;
                l.as_match_scope = l.guarded;
                return l.op(e);
            },
            .matches => return if (l.opts.checked) l.op(e) else l.uncovered(e, "match"),
            .lambda => return l.closure(e),
            .block => {
                const b = try l.f.addRegion(l.a, e, .block);
                const saved = l.block;
                l.block = b;
                defer l.block = saved;
                const value_3 = try l.stmts(e, b, true);
                l.region(b).value = value_3;
                const id = try l.addExpr(.{ .block = b });
                try l.note(e, id);
                try l.temp(e);
                try l.viewRules(e);
                return id;
            },
            .raw_block => {
                const b = try l.f.addRegion(l.a, e, .block);
                const saved = l.block;
                l.block = b;
                defer l.block = saved;
                const value_4 = try l.expr(ir.RawBlock.body(e));
                l.region(b).value = value_4;
                const id = try l.addExpr(.{ .block = b });
                try l.note(e, id);
                try l.temp(e);
                try l.viewRules(e);
                return id;
            },
            .@"return", .@"break", .@"continue", .set, .destructure, .drop, .@"defer", .@"errdefer", .@"while", .@"for", .labeled => {
                // A statement where a value goes: its temporaries are the
                // statement's around it.
                const r = try l.f.addRegion(l.a, e, .value);
                try l.stmtBody(e, r);
                const id = try l.addExpr(.{ .block = r });
                try l.note(e, id);
                // A loop a chain became gives a value (`Parser.desugarChains`).
                try l.temp(e);
                try l.viewRules(e);
                return id;
            },
            .@"catch" => return l.catchExpr(e),
            else => return l.op(e),
        }
    }

    /// Header `e`, which makes temporaries, in a region of its own that
    /// ends them and yields its value.
    fn header(l: *Lowerer, e: Sexp, key: u64) Error!ExprId {
        const h = try l.f.addRegion(l.a, e, .header);
        try l.headers.put(l.gpa, key, h);
        const o: Open = .{ .region = h, .stmt = l.stmt_region, .temps = l.temps.items.len };
        l.stmt_region = h;
        const value_5 = try l.expr(e);
        l.region(h).value = value_5;
        try l.checkTemps(e, o.temps);
        if (l.temps.items.len > o.temps) try l.flatten(h);
        l.stmt_region = o.stmt;
        l.temps.shrinkRetainingCapacity(o.temps);
        return l.addExpr(.{ .block = h });
    }

    /// Wrap expression `id`, node `e`'s, in each coercion its context
    /// makes of it, innermost first, and record them.
    /// Record the key of each node a coercion fact names.
    fn coercibleNodes(l: *Lowerer) std.mem.Allocator.Error!void {
        const f = &l.ctx.facts;
        const n = f.splats.count() + f.durations.count() + f.erasures.count() + f.failing_leaves.count() + f.lifts.count() + f.code_widenings.count() + f.views.count() + f.reads.count();
        try l.coercible.ensureTotalCapacity(l.gpa, n);
        inline for (.{ &f.splats, &f.durations, &f.erasures, &f.failing_leaves, &f.lifts, &f.code_widenings, &f.views, &f.reads }) |map| {
            var it = map.keyIterator();
            while (it.next()) |k| l.coercible.putAssumeCapacity(k.*, {});
        }
    }

    fn coerce(l: *Lowerer, e: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        const key = sema.decisionKeyOf(e) orelse return;
        if (!l.coercible.contains(key)) return;
        var list: [8]lir.Coercion = undefined;
        var n: usize = 0;
        // Outermost first.
        if (ctx.splatOf(e)) |vt| {
            list[n] = .{ .splat = vt };
            n += 1;
        }
        if (ctx.durationOf(e)) |d| {
            list[n] = .{ .duration = d };
            n += 1;
        }
        if (ctx.erasureOf(e)) |er| if (er.form == .box or er.form == .shared) {
            list[n] = .{ .erase = er };
            n += 1;
        };
        if (ctx.isFailingLeaf(e) and !ctx.namesErrorMember(e) and holdsErrorValue(ctx, e)) {
            list[n] = .fail;
            n += 1;
        }
        if (ctx.liftOf(e)) |lift| if (liftRouted(ctx, lift, l.opts.strict_optionals)) {
            list[n] = .{ .lift = lift };
            n += 1;
        };
        if (ctx.isCodeWidening(e)) {
            list[n] = .widen;
            n += 1;
        }
        if (ctx.viewOf(e)) |view| if (viewMade(ctx, view)) {
            list[n] = .{ .view = view };
            n += 1;
        };
        if (readsThrough(ctx, e)) {
            list[n] = .deref;
            n += 1;
        }
        if (n == 0) return;
        const kept = try l.a.dupe(lir.Coercion, list[0..n]);
        var i = n;
        while (i > 0) {
            i -= 1;
            const inner = try l.addExpr(l.f.exprs.items[id]);
            l.f.exprs.items[id] = .{ .coerce = .{ .node = e, .how = &kept[i], .value = inner } };
        }
        if (!l.opts.checked) try l.module.places.put(l.ma, key, .{ .f = l.f, .at = id });
    }

    /// The operation of `e` over its children, then the vars it makes.
    fn op(l: *Lowerer, e: Sexp) Error!ExprId {
        const kids = if (e.kind() == null) e.items() else rig.children(e);
        const args = try l.a.alloc(ExprId, kids.len);
        const written: Sexp = if (e.isKind(.call)) ir.Call.callee(e) else .nil;
        for (kids, args) |c, *x| {
            x.* = try l.expr(c);
            if (written == .list and c == .list and c.list.ptr == written.list.ptr) try l.selfTemps(e);
        }
        var o: lir.Expr.Op = .{ .node = e, .args = args, .kind = opKind(e) };
        if (o.kind == .call) {
            o.aux = @intCast(l.f.calls.items.len);
            try l.f.calls.append(l.a, l.callRecord(e));
        }
        if (enabled) {
            try l.operandRoles(o, kids);
            try l.placeOp(&o);
        }
        const id = try l.addExpr(.{ .op = o });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        try l.kindRules(e, id);
        return id;
    }

    /// An owning temporary its statement drops (`dropsTemp`): a var of
    /// the statement, which holds the value where it is made.
    fn temp(l: *Lowerer, e: Sexp) Error!void {
        if (!l.ctx.dropsTemp(e)) return;
        const v = try l.f.addVar(l.a, .{ .node = e, .name = .{ .hidden = .temp }, .by = if (e.isKind(.template)) .buffer else .owned, .life = .statement });
        try l.declare(l.stmt_region, v);
        try l.temps.append(l.gpa, v);
        try l.f.holdIn(l.gpa, l.exprOf(e).?, v);
    }

    /// The vars a view makes, for any node sema recorded a view of.
    fn viewRules(l: *Lowerer, e: Sexp) Error!void {
        const view = l.ctx.viewOf(e) orelse return;
        if (viewsInsideOptional(view)) try l.holdVar(e, .viewed, .pointer, .expression, null, l.stmt_region);
        // An API object of a value that may be held as a copy views a
        // copy, a local of the erasing block (`sema.Erasure.copy`).
        if (view.has(.erase)) if (l.ctx.erasureOf(e)) |er| if (er.copy) try l.holdVar(e, .erased_copy, .copy, .block, null, l.block);
        try l.leaves(if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e);
    }

    /// The vars a node of its kind makes, once its operands are lowered.
    fn kindRules(l: *Lowerer, e: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        switch (e.kind() orelse return) {
            .member => try l.leaves(viewedPlace(ir.Member.object(e))),
            .index => try l.leaves(ir.Index.object(e)),
            .call => {
                try l.call(e, id);
                try l.objectCall(e, id);
            },
            .array => if (hoistsArgs(ctx, e)) {
                const r = try l.callBlock(e, id);
                l.region(r).kind = .call;
                for (ir.Array.elems(e)) |v| try l.argument(v, null, .call, r);
            },
            // The parts of `return a, b`, made first when a later one can
            // leave, each held as the function's result in its place.
            .results => if (hoistsResults(ctx, e)) try l.holdVar(e, .argument, .owned, .call, null, l.stmt_region),
            .share => if (ir.Share.operand(e).isKind(.lambda)) try l.holdVar(ir.Share.operand(e), .closure_env, .owned, .expression, null, l.stmt_region),
            else => {},
        }
    }

    /// `v catch |e| handler`: the handler in a region of its own, which
    /// declares its binding and the error it names.
    fn catchExpr(l: *Lowerer, e: Sexp) Error!ExprId {
        const value = try l.expr(ir.Catch.value(e));
        const name = ir.Catch.name(e);
        _ = try l.expr(name);
        const h = try l.f.addRegion(l.a, e, .block);
        {
            const saved = l.block;
            defer l.block = saved;
            l.block = h;
            if (name != .nil) _ = try l.bindingVar(name, h);
            const handler = ir.Catch.handler(e);
            const handled = if (handler.isKind(.block)) try l.stmts(handler, h, true) else try l.expr(handler);
            l.region(h).value = handled;
        }
        const args = try l.a.dupe(ExprId, &.{ value, try l.addExpr(.{ .block = h }) });
        const id = try l.addExpr(.{ .op = .{ .node = e, .args = args, .kind = .@"catch" } });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        if (name == .src) if (l.ctx.symbolOf(name)) |sym| if (l.ctx.isUsed(sym)) {
            _ = try l.hiddenVar(e, .error_value, .owned, .handler, null, h);
        };
        return id;
    }

    // -------------------------------------------------------------------------
    // Conditions
    // -------------------------------------------------------------------------

    const Guard = struct { scope: RegionId, cond: ExprId, then: RegionId, @"else": ?RegionId };

    /// The condition and branches of `if` node `e`; each branch yields a
    /// value when `value`.
    fn guard(l: *Lowerer, e: Sexp, value: bool) Error!Guard {
        const scope = try l.f.addRegion(l.a, e, .guard);
        const then_r = try l.f.addRegion(l.a, ir.If.then(e), .block);
        const cond = try l.condition(ir.If.cond(e), scope);
        try l.branch(ir.If.then(e), then_r, value);
        var else_r: ?RegionId = null;
        if (ir.If.@"else"(e) != .nil) {
            else_r = try l.f.addRegion(l.a, ir.If.@"else"(e), .block);
            try l.branch(ir.If.@"else"(e), else_r.?, value);
        }
        if (!value) try l.conditionRules(e, scope);
        return .{ .scope = scope, .cond = cond, .then = then_r, .@"else" = else_r };
    }

    fn branch(l: *Lowerer, body: Sexp, r: RegionId, value: bool) Error!void {
        const saved = l.block;
        defer l.block = saved;
        l.block = r;
        // A branch that is no block, `a if c else b`, makes its
        // temporaries for the statement around it.
        if (!body.isKind(.block)) {
            if (!value) return l.stmtBody(body, r);
            const v = try l.expr(body);
            l.region(r).value = v;
            return;
        }
        const value_6 = try l.stmts(body, r, value);
        l.region(r).value = value_6;
    }

    /// Condition `cond`, whose `as` parts bind names in region `body`:
    /// each guard part that makes temporaries ends them in a region of
    /// its own (`sema.isHeaderOf`).
    fn condition(l: *Lowerer, cond: Sexp, body: RegionId) Error!ExprId {
        const Parts = struct {
            l: *Lowerer,
            pub fn part(p: @This(), c: Sexp) Error!void {
                // A `match`'s headers are its own.
                if (c.isKind(.as_match)) return;
                const h = if (c.isKind(.as) or c.isKind(.as_results)) ir.get(c, .value) else c;
                if (p.l.makesTemps(h)) try p.l.headers.put(p.l.gpa, sema.decisionKeyOf(h).?, null);
            }
        };
        try rig.eachGuardPart(cond, Parts{ .l = l });
        const saved = l.guarded;
        defer l.guarded = saved;
        l.guarded = body;
        return l.expr(cond);
    }

    /// `v as name`, or `f() as a, b`: the names are bindings of the body
    /// the condition guards.
    fn asExpr(l: *Lowerer, e: Sexp) Error!ExprId {
        const value = try l.expr(ir.get(e, .value));
        const names: []const Sexp = if (e.isKind(.as)) &.{ir.As.name(e)} else ir.AsResults.names(e).items();
        const args = try l.a.alloc(ExprId, 1 + names.len);
        args[0] = value;
        for (names, args[1..]) |n, *x| x.* = if (try l.bindingVar(n, l.guarded)) |v| try l.addExpr(.{ .@"var" = .{ .v = v, .node = n } }) else try l.expr(n);
        const id = try l.addExpr(.{ .op = .{ .node = e, .args = args, .kind = .as } });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        return id;
    }

    /// The vars the guard parts of `if` or `while` node `e` make, once
    /// its operands are lowered.
    fn conditionRules(l: *Lowerer, e: Sexp, body: RegionId) Error!void {
        const Parts = struct {
            l: *Lowerer,
            body: RegionId,
            pub fn part(p: @This(), c: Sexp) Error!void {
                const ll = p.l;
                if (c.isKind(.as)) return ll.optional(c, p.body);
                if (c.isKind(.as_match)) return ll.matchRules(rig.asMatchOf(c), p.body);
                if (c.isKind(.as_results)) {
                    try ll.subjectHeader(ir.AsResults.value(c));
                    _ = try ll.hiddenVar(c, .results, .owned, .body, null, p.body);
                    return;
                }
                try ll.headerVar(c);
            }
        };
        try rig.eachGuardPart(ir.get(e, .cond), Parts{ .l = l, .body = body });
    }

    /// The var a header that makes temporaries yields: its value.
    fn headerVar(l: *Lowerer, e: Sexp) Error!void {
        try l.headerVarBy(e, .copy);
    }

    fn headerVarBy(l: *Lowerer, e: Sexp, by: StorageBy) Error!void {
        if (e == .nil or sema.firstStmtTemp(l.ctx, e) == null) return;
        const v = (try l.hiddenVar(e, .header_value, by, .header, null, l.stmt_region)) orelse return;
        const h = (l.headers.get(sema.decisionKeyOf(e).?) orelse return) orelse return;
        l.region(h).label = v;
    }

    /// A construct's subject `e` that makes temporaries: the region that
    /// ends them yields the address of the place `e` reaches
    /// (`headerPoints`), or its value.
    fn subjectHeader(l: *Lowerer, e: Sexp) Error!void {
        if (e == .nil or sema.firstStmtTemp(l.ctx, e) == null) return;
        const points = headerPoints(l.ctx, e);
        try l.headerVarBy(e, if (points) .pointer else .copy);
        if (points and sema.handsOver(l.ctx, e).kind == .branches and !isPtrViewExpr(l.ctx, e)) try l.leaf(e);
    }

    /// Header `node` (a `match`, a `for`, or an `as`) over `subject`,
    /// whose temporaries (`sema.firstStmtTemp`) end with it, yields the
    /// address of a place the subject reaches (`headerPoints`),
    /// and the construct binds the place's own. It yields the value of any
    /// other subject, and what the construct binds is in that copy, which
    /// is recorded (the storage fact `header_copy`). A header that copies
    /// is rejected at the temporary, whatever it binds: a write, a Cell
    /// change, or a view, a catch-all's of plain data included, would
    /// reach the copy. A value made here, which no name holds, is the
    /// construct's own: it binds plain data of it by copy, which is what
    /// the copy holds. `bound` is the type the construct binds; null for a
    /// byte.
    fn headerCopy(l: *Lowerer, node: Sexp, subject: Sexp, bound: ?TypeId) Error!void {
        const ctx = l.ctx;
        if (!l.opts.checked) return;
        const first = sema.firstStmtTemp(ctx, subject) orelse return;
        if (headerPoints(ctx, headerSubject(node))) return;
        try ctx.recordHeaderCopy(node);
        if (sema.handsOver(ctx, subject).kind == .made and (if (bound) |b| sema.holdsNoLoanButText(ctx, sema.unwrapViews(ctx, b)) else true)) return;
        const what = if (inPart(subject, first, .index)) "the index" else if (inPart(subject, first, .call)) "the argument" else try std.fmt.allocPrint(l.a, "`{s}`", .{diag.textOf(ctx.source, ctx.span(first))});
        try ctx.errAt(first, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind {s} to a name first", .{what});
    }

    /// A step of `while` loop `w` that reads a binding of its condition
    /// runs inside the `if`s that bind it, after the body
    /// (`lir.StepPoint.after_body`, the same walk), so every binding there stays
    /// until the step is done: each must be plain data (neither a view nor
    /// owning), and no `continue` in the condition, which would go on past
    /// the step, may skip binding one.
    fn stepBindings(l: *Lowerer, w: Sexp) Error!void {
        const ctx = l.ctx;
        const cond = ir.While.cond(w);
        if (!l.opts.checked) return;
        const Parts = struct {
            ctx: *const SemContext,
            step: Sexp,
            use: ?Sexp = null,
            plain: ?SymbolId = null,
            pub fn part(p: *@This(), c: Sexp) error{}!void {
                if (!c.isKind(.as)) return;
                const b = p.ctx.symbolOf(ir.As.name(c)) orelse return;
                if (sema.findUse(p.ctx, p.step, b)) |u| p.use = u;
                const ty = p.ctx.symbols.items[b].ty;
                if (p.plain == null and (sema.isReadOrWriteView(p.ctx, ty) or sema.moves(p.ctx, ty) == .yes)) p.plain = b;
            }
        };
        var parts: Parts = .{ .ctx = ctx, .step = ir.While.step(w) };
        rig.eachGuardPart(cond, &parts) catch unreachable;
        const use = parts.use orelse return;
        const name = sema.identAt(ctx.source, use) orelse "";
        if (continuesTo(ctx, cond, w)) return ctx.errAt(use, "the loop step reads `{s}`, a binding of the condition, which a `continue` in the condition leaves unbound", .{name});
        const b = ctx.symbols.items[parts.plain orelse return];
        try ctx.errAt(use, "the loop step reads `{s}`, a binding of the condition, so each binding there must be plain data; `{s}` is a `{s}`", .{ name, b.name, try sema.formatType(ctx, b.ty) });
    }

    /// `if … as` or `while … as`.
    fn optional(l: *Lowerer, cond: Sexp, body: RegionId) Error!void {
        const ctx = l.ctx;
        const value = ir.As.value(cond);
        const name = ir.As.name(cond);
        const used = if (name == .src) (if (ctx.symbolOf(name)) |s| ctx.isUsed(s) else false) else false;
        // What the binding views, unless it owns a value made here or one
        // taken with `<`, may be a copy.
        if (typeOf(ctx, value)) |t| {
            const peeled = sema.unwrapViews(ctx, t);
            const own = value.isKind(.move) or (sema.handsOver(ctx, value).kind == .made and peeled == t);
            if (!own) switch (ctx.types.get(peeled)) {
                .optional => |inner| try l.headerCopy(cond, value, try boundOf(ctx, name, inner, ctx.types.get(t) == .write_view)),
                else => {},
            };
        }
        if (ctx.headerOf(cond)) |how| {
            if (how == .held) _ = try l.hiddenVar(cond, .held, .owned, .construct, if (ctx.heldBaseOf(cond)) |b| dropOf(ctx, b) else null, l.stmt_region);
            try l.subjectHeader(value);
            if (used) _ = try l.hiddenVar(cond, .as_value, .pointer, .body, null, body);
            return;
        }
        if (viewsOptionalValue(ctx, value)) {
            const generic = if (typeOf(ctx, value)) |t| genericReadView(ctx, t) != null else false;
            const copy = !generic and ctx.copiesHeader(cond);
            try l.subjectHeader(value);
            if (used) {
                _ = try l.hiddenVar(cond, .as_value, if (copy) .copy else .pointer, .body, null, body);
                if (copy) _ = try l.hiddenVar(cond, .as_copy, .copy, .body, null, body);
            }
            return;
        }
        if (value.isKind(.move)) try l.headerVar(value) else try l.subjectHeader(value);
        const sym = ctx.symbolOf(name);
        const ty: ?TypeId = if (sym) |s| known(ctx, ctx.symbols.items[s].ty) else if (typeOf(ctx, value)) |t| switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        if (ty != null and owns(ctx, ty.?)) _ = try l.hiddenVar(cond, .as_value, .owned, .body, null, body);
        if (used and bindsStringBytes(ctx, cond)) _ = try l.hiddenVar(cond, .as_value, .pointer, .body, null, body);
    }

    /// `while cond: step` and its body.
    fn whileLoop(l: *Lowerer, w: Sexp, r: RegionId) Error!void {
        try l.stepBindings(w);
        const scope = try l.f.addRegion(l.a, w, .guard);
        const body_r = try l.f.addRegion(l.a, ir.While.body(w), .block);
        const cond = try l.condition(ir.While.cond(w), scope);
        var step_r: ?RegionId = null;
        const st = ir.While.step(w);
        if (st != .nil) {
            step_r = try l.f.addRegion(l.a, st, .block);
            const saved = l.block;
            defer l.block = saved;
            l.block = step_r.?;
            try l.stmt(st, step_r.?);
        }
        try l.branch(ir.While.body(w), body_r, false);
        try l.conditionRules(w, scope);
        try l.step(scope, .{ .loop = .{ .node = w, .cond = cond, .body = body_r, .step = step_r, .step_point = if (l.opts.checked) .continue_expr else stepPoint(l.ctx, w) } });
        try l.step(r, .{ .region = scope });
    }

    /// `for x, i in source` and its body: the
    /// loop's storage lives in a scope around it, an element's in the
    /// body, made anew each pass.
    fn forLoop(l: *Lowerer, loop: Sexp, r: RegionId) Error!void {
        const ctx = l.ctx;
        const source = ir.For.source(loop);
        const scope = try l.f.addRegion(l.a, loop, .guard);
        const body_r = try l.f.addRegion(l.a, ir.For.body(loop), .block);
        // Each header that makes temporaries ends them in a region of its
        // own: a range's two ends, or the source.
        const range = source.isKind(.@"..");
        // What the loop binds, unless it takes its source or walks a slice
        // of it, may be a copy.
        if (!range and !rig.isRangeIndex(source) and ir.For.mode(loop).tag != .move and ctx.headerOf(loop) != .taken) {
            if (typeOf(ctx, source)) |t| if (loopElem(ctx, t)) |e| {
                try l.headerCopy(loop, source, try boundOf(ctx, ir.For.@"var"(loop), e, ir.For.mode(loop).tag == .write));
            } else try l.headerCopy(loop, source, null);
        }
        for ([_]Sexp{ if (range) ir.@"..".left(source) else source, if (range) ir.@"..".right(source) else .nil }) |h| {
            if (h != .nil and l.makesTemps(h)) try l.headers.put(l.gpa, sema.decisionKeyOf(h).?, null);
        }
        _ = try l.expr(ir.get(loop, .mode));
        for ([_]Sexp{ ir.For.@"var"(loop), ir.get(loop, .index) }) |n| {
            if (n == .nil) continue;
            if ((try l.bindingVar(n, body_r)) == null) _ = try l.expr(n);
        }
        const src = try l.expr(source);
        try l.branch(ir.For.body(loop), body_r, false);
        // The vars the loop makes, once its parts are lowered.
        const name = ir.For.@"var"(loop);
        const used = if (name == .src) (if (ctx.symbolOf(name)) |s| ctx.isUsed(s) else false) else false;
        if (bindsStringBytes(ctx, loop) and used) _ = try l.hiddenVar(loop, .element, .pointer, .iteration, null, body_r);
        if (range) {
            _ = try l.hiddenVar(loop, .range_start, .owned, .construct, null, scope);
            _ = try l.hiddenVar(loop, .range_end, .owned, .construct, null, scope);
            if (rig.isInclusive(source)) _ = try l.hiddenVar(loop, .range_more, .owned, .construct, null, scope);
            try l.headerVar(ir.@"..".left(source));
            try l.headerVar(ir.@"..".right(source));
        } else if (forConsumes(ctx, loop)) {
            _ = try l.hiddenVar(loop, .iterator, .owned, .construct, null, scope);
            _ = try l.hiddenVar(loop, .element, .owned, .iteration, null, body_r);
            try l.headerVar(source);
        } else {
            const how = ctx.headerOf(loop);
            if (how == .held) _ = try l.hiddenVar(loop, .held, .owned, .construct, if (ctx.heldBaseOf(loop)) |b| dropOf(ctx, b) else null, scope);
            if (how == .taken) {
                _ = try l.hiddenVar(loop, .taken, .owned, .construct, null, scope);
                try l.headerVar(source);
            } else try l.subjectHeader(source);
        }
        try l.step(scope, .{ .each = .{
            .node = loop,
            .source = src,
            .body = body_r,
            .fold = if (l.opts.checked) null else fold(ctx, loop),
            .string_bytes = !l.opts.checked and bindsStringBytes(ctx, loop),
        } });
        try l.step(r, .{ .region = scope });
    }

    const Match = struct { scope: RegionId, choice: lir.Expr.Choice };

    /// `match` node `m`: its subject, a header, in a scope that holds what
    /// the match keeps for its arms, then each arm in a region of its own.
    fn matchOf(l: *Lowerer, m: Sexp, value: bool) Error!Match {
        const ctx = l.ctx;
        const scope = try l.f.addRegion(l.a, m, .guard);
        const raw = ir.Match.subject(m);
        const subject = viewedPlace(raw);
        // The header that ends the subject's temporaries is the one
        // `matchRules` makes a var for; of two, the outer.
        const mode = matchMode(ctx, m);
        var held: ?Sexp = null;
        var reread = false;
        var temp_subject = false;
        var selects = false;
        if (matchBlock(ctx, m)) {
            if (subjectHold(ctx, m)) |by| {
                held = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                temp_subject = mode == .consume and by == .owned;
            }
            reread = true;
            selects = matchSelects(ctx, m);
        } else if (matchRereads(ctx, m)) reread = true;
        const whole = !selects and !(temp_subject or (reread and mode != .consume));
        for ([_]Sexp{ if (whole) subject else .nil, if (held != null and !whole) held.? else .nil }) |h| {
            if (h != .nil and l.makesTemps(h)) try l.headers.put(l.gpa, sema.decisionKeyOf(h).?, null);
        }
        const subject_e = try l.expr(raw);
        const arms = ir.Match.arms(m);
        const regions = try l.a.alloc(RegionId, arms.len);
        for (arms, regions) |a, *r| {
            r.* = try l.arm(a, value);
            if (l.opts.checked) continue;
            const arm_r = l.region(r.*);
            arm_r.catch_all = catchesAll(l.ctx, a);
            const p = ir.Arm.pattern(a);
            if (arm_r.catch_all) {
                if (l.bindings.get(ctx.symbolOf(p) orelse continue)) |v| l.f.vars.items[v].by_address = catchAllCaptured(ctx, p, m);
            } else for (prongsOf(ctx, &p)) |prong| if (prong.isKind(.variant_pattern)) {
                for (ctx.payloadBindings(prong) orelse continue) |b| if (b != .nil) {
                    const v = l.bindings.get(ctx.symbolOf(b) orelse continue) orelse continue;
                    l.f.vars.items[v].by_address = bindsByAddress(ctx, b, m);
                };
            };
        }
        if (!value) try l.matchRules(m, scope);
        const answers: lir.MatchAnswers = if (l.opts.checked) .{} else .{
            .mode = matchMode(l.ctx, m),
            .in_place = matchesInPlace(l.ctx, m),
            .rereads = matchRereads(l.ctx, m),
            .block = matchBlock(l.ctx, m),
            .selects = matchSelects(l.ctx, m),
        };
        return .{ .scope = scope, .choice = .{ .node = m, .subject = subject_e, .arms = regions, .answers = answers } };
    }

    /// A `match` arm: its pattern's bindings, its guard (a header), and
    /// its body, a statement of its own.
    fn arm(l: *Lowerer, a: Sexp, value: bool) Error!RegionId {
        const r = try l.f.addRegion(l.a, a, .arm);
        try l.arms.put(l.gpa, sema.decisionKeyOf(a).?, r);
        const saved = l.block;
        defer l.block = saved;
        l.block = r;
        // The bindings of `s matches .circle(r)` are the condition's, which
        // its later parts and its body see.
        try l.pattern(ir.Arm.pattern(a), l.as_match_scope orelse r);
        const saved_scope = l.as_match_scope;
        defer l.as_match_scope = saved_scope;
        l.as_match_scope = null;
        const cond = ir.Arm.guard(a);
        if (cond != .nil and l.makesTemps(cond)) try l.headers.put(l.gpa, sema.decisionKeyOf(cond).?, null);
        const g: ?ExprId = if (cond != .nil) try l.expr(cond) else null;
        const body = ir.Arm.body(a);
        const b = try l.f.addRegion(l.a, body, .block);
        // The body is a statement of its own (`sema.isArmBody`).
        if (body.isKind(.block)) {
            try l.branch(body, b, value);
        } else if (value and sema.yieldsValue(l.ctx.source, body) and !body.isKind(.labeled)) {
            const v = try l.valueStmt(body);
            l.region(b).value = v;
        } else try l.stmt(body, b);
        if (g) |guarded_by| {
            try l.step(r, .{ .@"if" = .{ .node = a, .cond = guarded_by, .then = b, .@"else" = null } });
        } else try l.step(r, .{ .region = b });
        return r;
    }

    /// A pattern: each name it declares is a binding of the arm.
    fn pattern(l: *Lowerer, p: Sexp, r: RegionId) Error!void {
        switch (p) {
            .src => {
                const sym = l.ctx.symbolOf(p) orelse return;
                if (l.ctx.symbols.items[sym].decl_pos != p.src.pos) return;
                if (l.bindings.contains(sym)) return;
                _ = try l.bindingVar(p, r);
            },
            .list => {
                for (p.items()) |c| try l.pattern(c, r);
            },
            else => {},
        }
    }

    /// The vars match `m` makes, declared in
    /// `scope`, or for an arm's, in the arm's region.
    fn matchRules(l: *Lowerer, m: Sexp, scope: RegionId) Error!void {
        const ctx = l.ctx;
        const mode = matchMode(ctx, m);
        const raw = ir.Match.subject(m);
        const subject = viewedPlace(raw);
        // What the arms bind, unless the match takes its subject or
        // matches a view a call returns where it points, may be a copy.
        if (!raw.isKind(.move) and !ctx.takesSubject(m) and !holdsView(ctx, m)) {
            if (typeOf(ctx, raw)) |t| try l.headerCopy(m, raw, try matchBound(ctx, raw, t));
        }
        if (ctx.headerOf(m) == .held) _ = try l.hiddenVar(m, .held, .owned, .construct, if (ctx.heldBaseOf(m)) |b| dropOf(ctx, b) else null, scope);
        var reread = false;
        var temp_subject = false;
        if (matchBlock(ctx, m)) {
            if (subjectHold(ctx, m)) |by| {
                _ = try l.hiddenVar(m, .subject, by, .construct, null, scope);
                const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                if (subject.isKind(.move)) try l.headerVar(value) else try l.subjectHeader(value);
                temp_subject = mode == .consume and by == .owned;
            }
            reread = true;
            if (matchSelects(ctx, m)) {
                for (ir.Match.arms(m)) |a| {
                    try l.headerVar(ir.Arm.guard(a));
                    if (mode == .consume) _ = try l.hiddenVar(a, .whole, .owned, .arm, null, l.armRegion(a));
                }
                return;
            }
        } else if (matchRereads(ctx, m)) reread = true;
        if (!(temp_subject or (reread and mode != .consume))) try l.subjectHeader(subject);
        const ty = matchedType(ctx, m);
        for (ir.Match.arms(m)) |a| {
            const in = l.armRegion(a);
            const pat = ir.Arm.pattern(a);
            if (catchesAll(ctx, a)) {
                if (mode == .consume) _ = try l.hiddenVar(a, .whole, .owned, .arm, null, in);
                continue;
            }
            const prongs = prongsOf(ctx, &pat);
            if (mode == .consume) {
                var payload = false;
                for (prongs) |prong| {
                    const variant = prong.isKind(.variant_pattern) or prong.isKind(.enum_lit) or (prong.isKind(.member) and ctx.isErrorMember(prong));
                    if (!variant) {
                        _ = try l.hiddenVar(a, .whole, .owned, .arm, null, in);
                    } else if (variantPayload(ctx, armType(ctx, prong, ty) orelse continue, rig.leafText(ctx.source, (if (prong.isKind(.variant_pattern)) rig.variantPatternName(prong) else ir.get(prong, .name)).src))) |fields| {
                        if (fields.len > 0) payload = true;
                    }
                }
                if (payload) _ = try l.hiddenVar(a, .payload, .owned, .arm, null, in);
                continue;
            }
            var any = false;
            var by_addr = mode == .write;
            for (prongs) |prong| if (prong.isKind(.variant_pattern)) {
                for (ctx.payloadBindings(prong) orelse continue) |b| {
                    if (b != .src) continue;
                    const s = ctx.symbolOf(b) orelse continue;
                    if (!ctx.isUsed(s)) continue;
                    any = true;
                    if (bindsByAddress(ctx, b, m)) by_addr = true;
                }
            };
            if (any) _ = try l.hiddenVar(a, .payload, if (by_addr) .pointer else .copy, .arm, null, in);
        }
    }

    /// The region arm `a` was lowered to.
    fn armRegion(l: *Lowerer, a: Sexp) RegionId {
        return l.arms.get(sema.decisionKeyOf(a).?).?;
    }

    /// A closure literal: its captures' values, made here, and its body,
    /// a body of its own, lowered as it is met.
    fn closure(l: *Lowerer, e: Sexp) Error!ExprId {
        const ctx = l.ctx;
        const oi = l.module.roots.get(sema.decisionKeyOf(e).?) orelse return l.uncovered(e, "closures");
        const caps = ir.get(e, .captures);
        const cap_nodes: []const Sexp = if (caps == .list) rig.children(caps) else &.{};
        const values = try l.a.alloc(ExprId, cap_nodes.len);
        for (cap_nodes, values) |cap, *x| {
            const name = ir.get(cap, .name);
            const value = ir.get(cap, .value);
            if (value != .nil) {
                x.* = try l.expr(value);
            } else {
                // `|x|` reads the binding it captures where the closure is
                // made.
                const origin: ?SymbolId = if (ctx.symbolOf(name)) |s| ctx.symbols.items[s].origin else null;
                x.* = if (origin) |o| (if (l.bindings.get(o)) |v| try l.addExpr(.{ .@"var" = .{ .v = v, .node = name } }) else try l.addExpr(.{ .leaf = name })) else try l.addExpr(.{ .leaf = name });
                try l.note(name, x.*);
                try l.viewRules(name);
            }
        }
        try l.closureBody(e, oi, cap_nodes);
        const id = try l.addExpr(.{ .closure = .{ .node = e, .owner = oi, .captures = values } });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        return id;
    }

    /// The body of closure `e`, the module's owner `oi`, lowered with the
    /// lowerer's state its own.
    fn closureBody(l: *Lowerer, e: Sexp, oi: u32, cap_nodes: []const Sexp) Error!void {
        const ctx = l.ctx;
        const saved = .{ l.f, l.stmt_region, l.block, l.results, l.guarded, l.as_match_scope, l.bindings };
        l.bindings = .empty;
        defer {
            l.bindings.deinit(l.gpa);
            l.f, l.stmt_region, l.block, l.results, l.guarded, l.as_match_scope, l.bindings = saved;
        }
        const f = try l.a.create(lir.Func);
        f.* = .{ .root = e, .exprs = l.scratch };
        l.scratch = .empty;
        errdefer f.exprs.deinit(l.gpa);
        l.f = f;
        f.body = try f.addRegion(l.a, e, .body);
        l.block = f.body;
        l.stmt_region = f.body;
        l.as_match_scope = null;
        l.results = if (fnType(ctx, typeOf(ctx, e))) |ft| sema.resultsOf(ctx, ft.returns) else null;
        for (cap_nodes) |cap| {
            const name = ir.get(cap, .name);
            if (name != .nil) _ = try l.bindingVar(name, f.body);
        }
        const params = ir.get(e, .params);
        if (params == .list) for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            _ = try l.bindingVar(name, f.body);
        };
        const value = try l.stmts(ir.Lambda.body(e), f.body, lambdaYields(ctx, e));
        f.region(f.body).value = value;
        try l.seal(f);
        l.module.owners[oi].func = f;
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// The made values call `c`'s self reaches that Zig holds in no
    /// slot, each a `zig_temp` of the statement, which the method's view
    /// of its self reaches: a self that is no place, viewed where it
    /// stands (`b.add(1).get()`), through each leaf of a value that
    /// branches. Declared for the checkers, as their walk meets them
    /// (`walkCallBody`, `selfLeaves`): after the callee, before the
    /// arguments.
    fn selfTemps(l: *Lowerer, c: Sexp) Error!void {
        if (!l.opts.checked) return;
        _ = try l.selfLeafTemps(l.selfViewed(c) orelse return, true);
    }

    /// The self of call `c` that `selfTemps` reaches the leaves of: one
    /// the method views, that is no place, a type, or a built-in's, and
    /// that no storage of the call holds; null for any other call.
    fn selfViewed(l: *Lowerer, c: Sexp) ?Sexp {
        const ctx = l.ctx;
        const callee = ctx.calleeOf(c);
        if (!callee.isKind(.member)) return null;
        // An actor's call and a select's arm keep no view of self.
        if (ctx.isActorCall(c) or ctx.selectArmOf(c) != null) return null;
        const written = ir.Member.object(callee);
        // A function a field holds is called without a self.
        if (!isTypeCallee(ctx, written) and !hasSelf(ctx, c)) return null;
        const obj = if (written.isKind(.write) or written.isKind(.read)) ir.get(written, .operand) else written;
        const mode: sema.SelfMode = if (written.isKind(.write)) .write else selfMode(ctx, obj, callee);
        if (mode == .value or l.isPlace(obj)) return null;
        if (namesType(ctx, callee) or builtinName(ctx, typeOf(ctx, obj))) return null;
        // A self the call holds in storage of its own that lives while it
        // runs is viewed there.
        if (ctx.elemCallOf(callee) == null and !ctx.isSelect(c) and hoistsArgs(ctx, c)) if (selfHold(ctx, c)) |hold| {
            const first: HeldFirst = if (hold == .consumed) .{ .node = consumedTemporary(ctx, c).?, .kind = .self } else heldFirst(ctx, c).?;
            const place = viewedPlace(obj);
            if (first.kind == .self and first.node == .list and place == .list and first.node.list.ptr == place.list.ptr and hold.by(hasStorage(ctx, first.node)) != .pointer) return null;
        };
        return obj;
    }

    /// Whether header `h` makes temporaries its region ends: an owning
    /// one (`sema.firstStmtTemp`), or, for the checkers, a Zig temporary
    /// a self view reaches (`selfTemps`), which they end with the header.
    fn makesTemps(l: *Lowerer, h: Sexp) bool {
        if (sema.firstStmtTemp(l.ctx, h) != null) return true;
        return l.opts.checked and l.makesSelfTemp(h);
    }

    /// Whether statement part `e` holds a call whose self `selfTemps`
    /// views as a Zig temporary.
    fn makesSelfTemp(l: *Lowerer, e: Sexp) bool {
        if (e != .list or e.isKind(.block) or e.isKind(.lambda)) return false;
        if (e.isKind(.call)) if (l.selfViewed(e)) |obj| if (l.selfLeafTemps(obj, false) catch true) return true;
        for (rig.children(e)) |c| {
            if (sema.sharesStmtTemps(e, c) and l.makesSelfTemp(c)) return true;
        }
        return false;
    }

    /// `selfTemps` of self value `e`: its base, through fields and
    /// elements of a value that is no place, then each leaf of that. Only
    /// finds whether there is one, unless `making`.
    fn selfLeafTemps(l: *Lowerer, e: Sexp, comptime making: bool) Error!bool {
        const ctx = l.ctx;
        var base = e;
        while (l.isPartOfNoPlace(base)) base = ir.get(base, .object);
        // A temporary its statement drops is viewed in its slot.
        if (ctx.dropsTemp(base)) return false;
        var found: std.ArrayList(Sexp) = .empty;
        defer found.deinit(l.gpa);
        try sema.valueLeaves(l.gpa, base, &found);
        var any = false;
        for (found.items) |part| {
            if (l.isPlace(part)) continue;
            if (l.isPartOfNoPlace(part)) {
                if (try l.selfLeafTemps(part, making)) any = true;
                if (any and !making) return true;
                continue;
            }
            if (part == .src) continue;
            if (!making) return true;
            // A temporary of the statement made where the leaf starts is
            // the one viewed.
            const pos = ctx.startOf(part);
            const held = for (l.temps.items) |t| {
                if (ctx.startOf(l.f.vars.items[t].node) == pos) break true;
            } else false;
            if (!held) try l.holdVar(part, .zig_temp, .owned, .statement, null, l.stmt_region);
            any = true;
        }
        return any;
    }

    /// Whether `e` is a place of the body: a name with a var, or a field
    /// or element of one that is handed over as a place.
    fn isPlace(l: *Lowerer, e: Sexp) bool {
        if (sema.handsOver(l.ctx, e).kind != .place) return false;
        return switch (e) {
            .src => if (l.ctx.symbolOf(e)) |sym| l.bindings.contains(sym) else false,
            .list => (e.isKind(.member) or e.isKind(.index)) and l.isPlace(ir.get(e, .object)),
            else => false,
        };
    }

    /// Whether `e` is a field or element of a value that is no place.
    fn isPartOfNoPlace(l: *Lowerer, e: Sexp) bool {
        if (!e.isKind(.member) and !e.isKind(.index)) return false;
        return !l.isPlace(e) and !rig.isRangeIndex(e);
    }

    /// The record of call `c`: how its callee is written and its self
    /// taken; for the checkers, its flags; and for emit, its kind
    /// (`classifyCall`) and what is opened around it, which the checkers'
    /// lowering records only in a self-checking build.
    fn callRecord(l: *Lowerer, c: Sexp) lir.Call {
        const ctx = l.ctx;
        if (l.opts.checked and !enabled) return checkedCall(ctx, c);
        var rec = if (l.opts.checked) checkedCall(ctx, c) else callShape(ctx, c, ctx.calleeOf(c));
        rec.kind = classifyCall(ctx, c, &l.stack_closures);
        rec.wrap.const_maker = ctx.isConstMaker(c);
        if (c == .list and ctx.decides(.inlined_calls, c.list.id)) {
            const ty = typeOf(ctx, c);
            const form = if (ty) |t| ctx.types.get(t) else .unknown;
            switch (form) {
                .optional => rec.wrap.rt_optional = true,
                .fallible => rec.wrap.rt_fallible = true,
                else => rec.wrap.rt_plain = true,
            }
        }
        rec.wrap.folds = callFolds(ctx, c);
        return rec;
    }

    /// The region that evaluates the parts call `c` (lowered to `id`)
    /// holds first: `c` becomes a value block that yields the call.
    fn callBlock(l: *Lowerer, c: Sexp, id: ExprId) Error!RegionId {
        const key = sema.decisionKeyOf(c).?;
        if (l.call_blocks.get(key)) |r| return r;
        const r = try l.f.addRegion(l.a, c, .value);
        const moved = try l.addExpr(l.f.exprs.items[id]);
        l.f.exprs.items[id] = .{ .block = r };
        l.region(r).value = moved;
        try l.call_blocks.put(l.gpa, key, r);
        return r;
    }

    /// How call `c` holds what it is passed.
    fn call(l: *Lowerer, c: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        const callee = ctx.calleeOf(c);
        const hoists = holdsParts(ctx, c);
        // Its record is the last made: its operands' calls were lowered
        // before it.
        l.f.calls.items[l.f.calls.items.len - 1].wrap.held = hoists;
        // A temporary array viewed as a slice by a call that evaluates its
        // arguments where they stand is viewed where Zig holds it.
        if (!hoists) for (ir.Call.args(c)) |a| if (ctx.viewsTempArray(argValue(a))) try l.holdVar(argValue(a), .zig_temp, .owned, .statement, null, l.stmt_region);
        if (ctx.elemCallOf(callee) != null) return;
        // A closure literal called where it is written is built first.
        if (callee.isKind(.lambda)) try l.hoistVar(callee, .invoked, .owned, .call, null, try l.callBlock(c, id));
        if (!hoists) return;
        const r = try l.callBlock(c, id);
        l.region(r).kind = .call;
        // The parts of `task.select` are its arms' (`hoistsArgs`).
        if (ctx.isSelect(c)) {
            for (ir.Call.args(c)) |a| try l.callParts(argValue(a), .select, r);
        } else try l.callParts(c, .call, r);
    }

    /// The parts of call `c` evaluated first, held in region `r` for
    /// `life`: its self or callee (`heldFirst`), then its
    /// arguments.
    fn callParts(l: *Lowerer, c: Sexp, life: StorageLife, r: RegionId) Error!void {
        const ctx = l.ctx;
        if (selfHold(ctx, c)) |hold| {
            const first: HeldFirst = if (hold == .consumed) .{ .node = consumedTemporary(ctx, c).?, .kind = .self } else heldFirst(ctx, c).?;
            const by = hold.by(hasStorage(ctx, first.node));
            const drop = if (hold == .consumed)
                (if (ctx.viewsTempArray(first.node)) null else dropOf(ctx, first.node))
            else if (by == .pointer or isPtrViewExpr(ctx, first.node)) null else dropOf(ctx, first.node);
            try l.hoistVar(first.node, first.kind, by, life, drop, r);
        }
        for (ir.Call.args(c), 0..) |a, ai| try l.argument(argValue(a), argumentParam(ctx, c, ai), life, r);
    }

    /// `v`, a part of a call or an array literal evaluated first, held in
    /// region `r`.
    fn argument(l: *Lowerer, v: Sexp, param: ?TypeId, life: StorageLife, r: RegionId) Error!void {
        const ctx = l.ctx;
        if (isPureArg(ctx, v)) return;
        const hold = argumentHold(ctx, v);
        const by: StorageBy = switch (hold) {
            .closure => by: {
                _ = try l.hiddenVar(v, .environment, .owned, life, null, r);
                break :by .owned;
            },
            .callable => .owned,
            .viewed => .pointer,
            .value => if (param) |t| (if (sema.viewHeldAsPointer(ctx, t)) .pointer else .owned) else .owned,
        };
        // A value held as the view its parameter takes, or as what a
        // duration form becomes, is held as the optional it becomes.
        const ty = if (ctx.durationOf(v)) |d| d.written(ctx.types.int_id) else typeOf(ctx, v);
        const shown = if (hold == .viewed) param else ty;
        const lifted = shown != ty;
        try l.hoistHeld(v, .argument, by, life, if (by == .pointer or ctx.viewsTempArray(v)) null else dropOf(ctx, v), r, if (lifted) .lifted else .read);
        if (enabled) if (l.exprOf(v)) |id| if (id < l.f.roles.items.len) {
            l.f.roles.items[id].held = true;
        };
    }

    /// A call through an API object's table: the object, read once
    /// unless a name holds it, and the place a large result is written
    /// to.
    fn objectCall(l: *Lowerer, c: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        const d = switch (ctx.dispatchOf(c) orelse return) {
            .dynamic => |d| d,
            else => return,
        };
        const recv = viewedPlace(if (d.self_arg) ir.Call.args(c)[0] else selfOf(ctx, c) orelse return);
        if (recv != .src) try l.hoistVar(recv, .api_object, .copy, .call, null, try l.callBlock(c, id));
        const entry = sema.tableEntry(ctx, d) orelse return;
        if (entry.result_out) _ = try l.hiddenVar(c, .result_place, .owned, .call, null, try l.callBlock(c, id));
    }

    // -------------------------------------------------------------------------
    // Operand roles
    // -------------------------------------------------------------------------

    /// Record how its user takes expression `id`, of node `e`, consumed
    /// into `sink` (`.none` where nothing consumes it), in a
    /// self-checking build, whose ownership checker asserts that it
    /// decides each the same.
    fn role(l: *Lowerer, id: ExprId, e: Sexp, sink: lir.Operand.Sink) Error!void {
        if (!enabled) return;
        const roles = &l.f.roles;
        if (roles.items.len <= id) try roles.appendNTimes(l.a, .{}, id + 1 - roles.items.len);
        var o = useOf(l.ctx, e, sink);
        o.held = roles.items[id].held;
        roles.items[id] = o;
    }

    /// The roles operation `o` gives its operands, the tree's `kids`:
    /// where each it consumes goes, and the operand of a move or a view.
    fn operandRoles(l: *Lowerer, o: lir.Expr.Op, kids: []const Sexp) Error!void {
        if (!enabled) return;
        const args = o.args;
        switch (o.node.kind() orelse return) {
            .call => {
                for (kids[2..], args[2..]) |c, x| try l.role(x, c, .argument);
                // A self the method takes by value is taken as an
                // argument is: the object of its member callee, under an
                // instance's.
                const s = l.f.calls.items[o.aux].self orelse return;
                if (s.mode != .value) return;
                var callee = l.opAt(args[1]) orelse return;
                if (callee.node.isKind(.inst)) callee = l.opAt(callee.args[0]) orelse return;
                if (callee.node.isKind(.member)) try l.role(callee.args[0], ir.Member.object(callee.node), .argument);
            },
            .kwarg => try l.role(args[1], kids[1], .argument),
            .array => for (kids, args) |c, x| try l.role(x, c, .element),
            .array_fill => try l.role(args[1], kids[1], .element),
            .box => try l.role(args[0], kids[0], .box),
            .share => try l.role(args[0], kids[0], .allocation),
            .move => l.f.roles.items[args[0]].use = .move,
            .read, .write => {
                const r = &l.f.roles.items[args[0]];
                r.use = if (o.node.isKind(.read)) .read_view else .write_view;
                r.elems = if (l.ctx.viewOf(o.node)) |v| viewsElems(v) else false;
            },
            else => {},
        }
    }

    /// The place `member` or `index` operation `o` reaches, when its
    /// value is one (`sema.Hands.place`) rooted at a var: its object's
    /// place, then this step.
    fn placeOp(l: *Lowerer, o: *lir.Expr.Op) Error!void {
        if (!enabled) return;
        const ctx = l.ctx;
        const e = o.node;
        if (!e.isKind(.member) and !e.isKind(.index)) return;
        if (sema.handsOver(ctx, e).kind != .place) return;
        const base: lir.Place = if (l.opAt(o.args[0])) |b| (if ((b.node.isKind(.member) or b.node.isKind(.index)) and b.aux > 0) l.f.places.items[b.aux - 1] else return) else root: {
            var at = o.args[0];
            while (true) switch (l.f.exprs.items[at]) {
                .coerce => |c| at = c.value,
                .@"var" => |u| break :root .{ .root = u.v, .steps = &.{} },
                .leaf => break :root .{ .root = null, .steps = &.{} },
                else => return,
            };
        };
        var at_step: lir.PlaceStep = .{ .kind = .index };
        const object = ir.get(e, .object);
        if (ctx.typeOf(object)) |ty| if (ty != ctx.types.unknown_id and ty != ctx.types.invalid_id) {
            at_step.through_shared = ctx.types.get(ty) == .shared;
            if (e.isKind(.member)) {
                at_step.kind = .member;
                var t = ty;
                if (base.steps.len == 0) switch (ctx.types.get(t)) {
                    .write_view => |inner| t = inner,
                    .read_view => |inner| {
                        t = inner;
                        at_step.root_read_view = true;
                    },
                    else => {},
                };
                while (sema.boxedType(ctx, t)) |inner| t = inner;
                const data = switch (ctx.types.get(t)) {
                    .nominal => true,
                    .parameterized_nominal => |pn| !sema.isBuiltinGeneric(ctx, pn.sym),
                    else => false,
                };
                const name = ir.Member.name(e);
                if (data and name == .src and sema.lookupDataFieldConst(ctx, t, rig.leafText(ctx.source, name.src)) != null) at_step.kind = .field;
            }
        } else if (e.isKind(.member)) {
            at_step.kind = .member;
        };
        const steps = try l.a.alloc(lir.PlaceStep, base.steps.len + 1);
        @memcpy(steps[0..base.steps.len], base.steps);
        steps[base.steps.len] = at_step;
        try l.f.places.append(l.a, .{ .root = base.root, .steps = steps });
        o.aux = @intCast(l.f.places.items.len);
        try l.module.place_of.put(l.ma, sema.decisionKeyOf(e).?, .{ .f = l.f, .i = o.aux - 1 });
    }

    /// The operation expression `id` is, under its coercions and holds.
    fn opAt(l: *const Lowerer, id: ExprId) ?lir.Expr.Op {
        var at = id;
        while (true) switch (l.f.exprs.items[at]) {
            .coerce => |c| at = c.value,
            .hold => |h| at = h.value,
            .op => |o| return o,
            else => return null,
        };
    }

    // -------------------------------------------------------------------------
    // Leaves
    // -------------------------------------------------------------------------

    /// The branches of `e`, a value read where its leaves are
    /// (`reachesLeaf`), that capture a payload by address.
    fn leaves(l: *Lowerer, e: Sexp) Error!void {
        if (reachesLeaf(l.ctx, e)) try l.leaf(e);
    }

    fn leaf(l: *Lowerer, e: Sexp) Error!void {
        const how = leafStep(l.ctx, e);
        if (!l.opts.checked) l.answer(e, .leaf_step, how);
        switch (how) {
            .place, .part, .view, .jump => {},
            .made => if (!l.ctx.dropsTemp(e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
            .literal => if (!sema.isNoneLeaf(l.ctx, e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
            .@"if" => {
                try l.leaf(lastValue(ir.If.then(e)));
                try l.leaf(lastValue(ir.If.@"else"(e)));
            },
            .fallback => {
                try l.holdVar(e, .leaf, .pointer, .expression, null, l.stmt_region);
                if (e.isKind(.@"??")) {
                    try l.leaf(ir.@"??".left(e));
                    try l.leaf(ir.@"??".right(e));
                } else {
                    try l.leaf(ir.Catch.value(e));
                    try l.leaf(lastValue(ir.Catch.handler(e)));
                }
            },
            .unwrap => {
                try l.holdVar(e, .leaf, .pointer, .expression, null, l.stmt_region);
                try l.leaf(if (e.isKind(.propagate)) ir.Propagate.value(e) else ir.PropagateNone.value(e));
            },
        }
    }
};

// =============================================================================
// Operations
// =============================================================================

/// What the operation of node `e` does, by its form.
/// How its user takes `e` consumed into `sink`, from its form and the
/// typing facts, in the order the ownership checker asks
/// (`walkConsumedE`): a value viewed to read where a view goes, a closure
/// literal, a held write view passed to a call, then what `e` hands over.
fn useOf(ctx: *const SemContext, e: Sexp, sink: lir.Operand.Sink) lir.Operand {
    var o: lir.Operand = .{ .sink = sink };
    const view = ctx.viewOf(e);
    if (view) |v| if (v.implicit) {
        o.use = .read_view;
        o.implicit = true;
        o.elems = viewsElems(v);
        return o;
    };
    if (e.isKind(.lambda)) {
        o.use = .made;
        return o;
    }
    if (sink == .argument and passesWriteView(ctx, e)) {
        o.use = .pass_view;
        o.read_only = if (view) |v| v.has(.read_only) else false;
        return o;
    }
    o.use = switch (sema.handsOver(ctx, e).kind) {
        .made, .view => .made,
        else => .read,
    };
    return o;
}

/// Whether `view` views the elements of its operand (an array's or a
/// List's, or a String's bytes): its first row past any lift is theirs.
fn viewsElems(view: sema.View) bool {
    for (view.steps()) |step| switch (step) {
        .lift => {},
        .elems, .text => return true,
        else => return false,
    };
    return false;
}

/// Whether `e` is a place whose value holds a write view (`w`, or a
/// `(!T)?` name): passing it to a call passes that view on.
fn passesWriteView(ctx: *const SemContext, e: Sexp) bool {
    const ty = ctx.typeOf(e) orelse return false;
    if (ty == ctx.types.unknown_id or ty == ctx.types.invalid_id) return false;
    if (!sema.holdsWriteView(ctx, ty) or sema.copiedOut(ctx, e)) return false;
    return switch (sema.handsOver(ctx, e).kind) {
        .place, .part_of_made => true,
        else => false,
    };
}

fn opKind(e: Sexp) lir.OpKind {
    const head = e.kind() orelse return .other;
    return switch (head) {
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .neg => .arith,
        .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => .compare,
        .@"and", .@"or", .not => .logic,
        .read, .write => .view,
        .move => .move,
        .clone => .clone,
        .weak => .weak,
        .share => .share,
        .box => .box,
        .member => .member,
        .index => .index,
        .inst => .inst,
        .call => .call,
        .array => .array,
        .array_fill => .array_fill,
        .template => .template,
        .propagate => .propagate,
        .propagate_none => .propagate_none,
        .@"??" => .nullish,
        .@"catch" => .@"catch",
        .kwarg => .kwarg,
        .panic => .panic,
        .results => .results,
        .enum_lit, .symbol => .literal,
        .as, .as_results, .as_match, .matches => .as,
        else => .other,
    };
}

/// What call `c` is: the first form of `lir.CallKind` it fits, in the
/// order emit's call ladder asks (`Emitter.emitCall`, `emitCallDirect`,
/// `emitTask`, `emitCallArgs`). `stack_closures` are the locals a
/// closure literal declares.
pub fn classifyCall(ctx: *const SemContext, c: Sexp, stack_closures: *const sema.FastMap(SymbolId, void)) lir.CallKind {
    const types = ctx.types;
    const callee = ctx.calleeOf(c);
    const ty = typeOf(ctx, c);
    if (ctx.elemCallOf(callee) != null) return .elem;
    if (ty) |t| if (types.get(t) == .simd) {
        const written = ir.Call.callee(c);
        if (isTypeCallee(ctx, written)) return .simd_conversion;
        if (ctx.symbolOf(written)) |id| if (ctx.symbols.items[id].kind == .type_alias) return .simd_conversion;
    };
    if (ir.Call.task(c) != .nil) return if (ctx.isActorCall(c)) .actor_spawn else .task;
    if (ctx.builtinOf(c)) |b| return switch (b) {
        .print => .print,
        .warn => .warn,
        .conversion => .conversion,
        .swap => .swap,
    };
    if (stringCall(ctx, c) != null) return .string;
    if (isAliasCallee(ctx, callee)) {
        const t = ty orelse return .alias_object;
        if (sema.isNumeric(ctx, t)) return .alias_conversion;
        if (types.get(t) == .parameterized_nominal) {
            const g = types.get(t).parameterized_nominal.sym;
            if (g == ctx.builtins.list) return .alias_list;
            if (g == ctx.builtins.signal) return .alias_signal;
        }
        return .alias_object;
    }
    if (callee.isKind(.enum_lit)) return .variant;
    if (callee.isKind(.lambda)) return .inline_invoke;
    if (ctx.dispatchOf(c)) |d| switch (d) {
        .static => return .witness,
        .dynamic => return .object,
        .direct => {},
    };
    if (callee == .src) {
        if (ctx.symbolOf(callee)) |sym| {
            if (stack_closures.contains(sym)) return .stack_closure;
            const ref = ctx.ref(sym);
            if (ref == ctx.builtins.list) return .list;
            if (ref == ctx.builtins.table) return .table;
            if (ref == ctx.builtins.signal) return .signal;
            if (isTypeSym(ctx, sym)) return .constructor;
        }
    }
    if (callee.isKind(.member) and ctx.typeOf(callee) == null) if (ty) |t| {
        const vname = rig.leafText(ctx.source, ir.Member.name(callee).src);
        const peeled = sema.unwrapViews(ctx, t);
        const error_set = types.get(peeled) == .any_error or sema.isErrorSet(ctx, peeled) or sema.isSetParam(ctx, peeled);
        if (error_set and variantPayload(ctx, t, vname) != null) return .error_member;
        if (variantPayload(ctx, t, vname) != null) return .variant_member;
        if (switch (types.get(t)) {
            .nominal => |r| !ctx.owns(r),
            else => false,
        }) return .foreign_object;
        if (types.get(t) == .parameterized_nominal and isTypeCallee(ctx, callee)) return .instance;
    };
    if (typeOf(ctx, callee)) |t| {
        if (sema.callableFn(ctx, t) != null) return .fn_ref;
        if (sema.ownedClosureFn(ctx, t) != null) return .closure_handle;
    }
    if (ctx.builtinCallOf(callee) != null) return .builtin_method;
    if (ctx.taskJoinOf(c) != null) return .task_join;
    if (ctx.isActorCall(c)) return .actor_call;
    if (ctx.isSelect(c)) return if (selectResult(ctx, ty)) .select_value else .select_into;
    if (ctx.selectArmOf(c)) |arm| return switch (arm) {
        .recv => .arm_recv,
        .send => .arm_send,
        .after => .arm_after,
        else => .arm_end,
    };
    if (ctx.isHttpServe(c)) return .http_serve;
    if (ctx.isReduceCall(c)) return .reduce;
    if (ctx.isIoCopy(c)) return .io_copy;
    if (ctx.isSuperviseCall(c)) return .supervise;
    if (ctx.isIsolateCall(c)) return .isolate;
    if (ctx.parCallOf(c)) |p| return switch (p) {
        .map => .par_map,
        .each => .par_each,
        .workers => .par_workers,
        .push => .par_push,
    };
    if (callee.isKind(.member)) if (typeOf(ctx, ir.Member.object(callee))) |t| {
        if (isBuiltinInstance(ctx, t, ctx.builtins.tasks) and rig.isWaitMember(callee)) return .wait_all;
        if (isBuiltinInstance(ctx, t, ctx.builtins.task)) return .wait;
    };
    return .plain;
}

/// The record the checkers read of call `c`: how its callee is written,
/// how it takes its self, and its flags. The ownership checker reads it
/// from the LIR (`lowered.callOf`).
pub fn checkedCall(ctx: *const SemContext, c: Sexp) lir.Call {
    const callee = ctx.calleeOf(c);
    var rec = callShape(ctx, c, callee);
    rec.flags.text_only = ctx.isPrintCall(c) or (ctx.stringCallOf(c) orelse ctx.stringCallOf(callee)) != null;
    rec.flags.swap = ctx.swapCallOf(c) != null and ir.Call.args(c).len == 2;
    if (!callee.isKind(.member)) rec.flags.keeps_no_loan = keepsNoLoan(ctx, c);
    return rec;
}

/// How call `c` is written, as the ownership checker walks it
/// (`walkCallBody`): its callee's form, and how a method takes its
/// self. A method call's `keeps_no_loan` is decided here, where its
/// callee's form needs it.
fn callShape(ctx: *const SemContext, c: Sexp, callee: Sexp) lir.Call {
    var rec: lir.Call = .{ .kind = .unclassified, .callee = .other };
    if (callee.isKind(.member)) {
        const obj = ir.Member.object(callee);
        // A type or a module named before the function is no self:
        // it has no value (`isTypeCallee`).
        const type_callee = isTypeCallee(ctx, obj);
        rec.flags.keeps_no_loan = keepsNoLoan(ctx, c);
        rec.callee = if (!rec.flags.keeps_no_loan and !type_callee and !hasSelf(ctx, c)) .field_fn else .member;
        if (!type_callee) {
            const explicit = obj.isKind(.write) or obj.isKind(.read);
            rec.self = .{ .explicit = explicit, .mode = if (obj.isKind(.write)) .write else selfMode(ctx, if (explicit) ir.get(obj, .operand) else obj, callee) };
        }
    } else if (callee == .src) {
        rec.callee = .name;
    } else if (callee.isKind(.lambda)) {
        rec.callee = .lambda;
    }
    return rec;
}

/// Whether call `c`'s result keeps no loan: an actor's call or a
/// select's arm.
fn keepsNoLoan(ctx: *const SemContext, c: Sexp) bool {
    return ctx.isActorCall(c) or ctx.selectArmOf(c) != null;
}

/// How method `callee` takes its self `obj`: by value when the self is
/// taken with `<` or the method's first parameter is an object, as a
/// write view when that parameter is one, else as a read view.
fn selfMode(ctx: *const SemContext, obj: Sexp, callee: Sexp) sema.SelfMode {
    if (obj.isKind(.move)) return .value;
    if (ctx.typeOf(obj)) |t| if (ctx.types.get(t) == .shared) return .read;
    const fty = ctx.typeOf(callee) orelse return .read;
    const f = ctx.types.get(fty);
    if (f != .function or f.function.params.len == 0) return .read;
    return switch (ctx.types.get(f.function.params[0])) {
        .write_view => .write,
        .nominal, .parameterized_nominal => .value,
        else => .read,
    };
}

/// Whether `e` names a type (`Shape`, `lib.Shape`, `Opt[Int]`) rather
/// than a value.
fn namesType(ctx: *const SemContext, e: Sexp) bool {
    if (ctx.instanceOf(e)) |inst| return inst == .type;
    const leaf = if (e.isKind(.member)) ir.Member.name(e) else e;
    if (leaf != .src) return false;
    if (e.isKind(.member)) {
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

/// Whether `ty`, through views and shared handles, is a Cell, a Signal,
/// a List, or a channel: a built-in whose methods hand out values,
/// never views of self.
fn builtinName(ctx: *const SemContext, ty: ?TypeId) bool {
    var t = ty orelse return false;
    while (true) switch (ctx.types.get(t)) {
        .read_view, .write_view, .shared => |i| t = i,
        .parameterized_nominal => |pn| return pn.sym == ctx.builtins.cell or pn.sym == ctx.builtins.signal or pn.sym == ctx.builtins.list or pn.sym == ctx.builtins.chan,
        else => return false,
    };
}

/// Whether a duration form of call `c` joins its failure
/// (`sema.DurationHow.folded`).
fn callFolds(ctx: *const SemContext, c: Sexp) bool {
    for (ir.Call.args(c)) |a| {
        if (ctx.durationOf(argValue(a))) |d| if (d.how == .folded) return true;
    }
    if (ctx.callSlotsOf(c)) |slots| for (slots) |sl| switch (sl) {
        .parts => |p| if (p.how == .folded) return true,
        else => {},
    };
    return false;
}

/// A callee naming a type alias, this module's or an imported one.
fn isAliasCallee(ctx: *const SemContext, callee: Sexp) bool {
    if (callee.isKind(.member)) return if (moduleMemberSym(ctx, callee)) |m| m.kind == .type_alias else false;
    if (callee != .src) return false;
    const id = ctx.symbolOf(callee) orelse return false;
    return ctx.symbols.items[id].kind == .type_alias;
}

/// Whether a select of result type `ty` gives the value of its own type
/// (`sema.selectType`), not a select of closures.
fn selectResult(ctx: *const SemContext, ty: ?TypeId) bool {
    const t = ty orelse return false;
    const ok = switch (ctx.types.get(t)) {
        .fallible => |f| f.ok,
        else => return false,
    };
    return switch (ctx.types.get(ok)) {
        .nominal => |sym| ctx.owns(sym) and ctx.symbols.items[sym.sym].flags.select_result,
        else => false,
    };
}

/// Whether `ty`, through its views, is an instance of built-in `sym`.
fn isBuiltinInstance(ctx: *const SemContext, ty: TypeId, sym: sema.SymbolRef) bool {
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == sym,
        else => false,
    };
}

/// An element of the table, List, array, or slice a `for` over a source
/// of type `ty` walks; null for a byte of text.
fn loopElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const walked = sema.loopWalks(ctx, ty);
    if (sema.tableElem(ctx, walked) orelse sema.listElem(ctx, walked)) |e| return e;
    return switch (ctx.types.get(walked)) {
        .array => |a| a.elem,
        .slice => |s| s.elem,
        else => null,
    };
}

/// The type binding `name` of a header has, binding a value of type
/// `reached`: the type typecheck gave it, or for `_`, which keeps none,
/// the view it makes, to write or, of a value that does not copy, to
/// read, interned as typecheck's is (a read view of a `String` is
/// `?String`).
fn boundOf(ctx: *SemContext, name: Sexp, reached: TypeId, write: bool) Error!TypeId {
    if (ctx.symbolOf(name)) |s| return ctx.symbols.items[s].ty;
    if (write) return ctx.intern(.{ .write_view = reached });
    return if (sema.copies(ctx, reached) == .no) ctx.intern(.{ .read_view = reached }) else reached;
}

/// What a `match` over `subject`, of type `ty`, binds through: the value
/// it reaches, a value a shared handle holds viewed as `?h` or `!h`
/// views it.
fn matchBound(ctx: *SemContext, subject: Sexp, ty: TypeId) Error!TypeId {
    const reached = sema.unwrapAccess(ctx, ty);
    if (ctx.types.get(sema.unwrapViews(ctx, ty)) != .shared) return reached;
    if (subject.isKind(.read)) return sema.unwrapAccess(ctx, try ctx.intern(.{ .read_view = reached }));
    if (subject.isKind(.write) and sema.changesByMark(ctx, reached)) return sema.unwrapAccess(ctx, try ctx.intern(.{ .write_view = reached }));
    return reached;
}

/// Whether `node` lies in an index (`.index`) or an argument (`.call`) of
/// a node of kind `kind` in `tree`.
fn inPart(tree: Sexp, node: Sexp, comptime kind: Tag) bool {
    if (tree != .list) return false;
    if (tree.isKind(kind)) switch (kind) {
        .index => if (holds(ir.Index.index(tree), node)) return true,
        .call => for (ir.Call.args(tree)) |a| if (holds(a, node)) return true,
        else => comptime unreachable,
    };
    for (tree.items()) |c| if (inPart(c, node, kind)) return true;
    return false;
}

/// Whether list node `node` is `tree` or inside it.
fn holds(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.list.ptr == node.list.ptr) return true;
    for (tree.items()) |c| if (holds(c, node)) return true;
    return false;
}

/// Whether condition `e` of `while` loop `w` holds a `continue` to `w`.
fn continuesTo(ctx: *const SemContext, e: Sexp, w: Sexp) bool {
    if (e != .list) return false;
    if (e.isKind(.@"continue")) if (ctx.jumpDestOf(e)) |d| if (d.target == .list and d.target.list.ptr == w.list.ptr) return true;
    for (e.items()) |c| if (continuesTo(ctx, c, w)) return true;
    return false;
}

// =============================================================================
// Coercions
// =============================================================================

/// Whether coercion `c` of a value held in a var first is made where the
/// var is read, not where it is written.
fn readCoercion(held: Lowerer.Held, c: lir.Coercion) bool {
    if (held == .all) return false;
    return switch (c) {
        .lift => held == .read,
        .splat, .erase, .fail, .widen => true,
        .duration, .view, .deref => false,
    };
}

/// Whether `e` is an error that may carry fields, a `rig.ErrorValue`.
fn holdsErrorValue(ctx: *const SemContext, e: Sexp) bool {
    const ty = typeOf(ctx, e) orelse return false;
    return sema.isErrorValueForm(ctx, sema.unwrapViews(ctx, ty));
}

/// Whether some level of the optional `lift` makes goes through the
/// optional helpers.
fn liftRouted(ctx: *const SemContext, lift: sema.Lift, strict: bool) bool {
    var o = lift.into;
    var levels = lir.liftLevels(ctx.types, lift);
    while (levels > 0) : (levels -= 1) {
        const inner = ctx.types.get(o).optional;
        if (sema.optionalRouted(ctx, inner, strict)) return true;
        o = inner;
    }
    return false;
}

/// Whether view `view` makes anything of its value: any view but one
/// that reads plain data as it is, and a read view of an API object,
/// read through its `read()`.
fn viewMade(ctx: *const SemContext, view: sema.View) bool {
    if (view.implicit or !view.has(.read_only)) return true;
    var t = view.ty;
    for (view.steps()) |row| if (row == .lift) {
        t = ctx.types.get(t).optional;
    };
    return sema.objectView(ctx, t) != null;
}

/// Whether `e` yields a pointer view where its context reads the value
/// behind it: `!x`, or a call returning `!Int`. A name, field, or element
/// holding a view reads through it already.
fn readsThrough(ctx: *const SemContext, e: Sexp) bool {
    if (e == .src or e.isKind(.member) or e.isKind(.index)) return false;
    return ctx.readsThrough(e) and isPtrViewExpr(ctx, e);
}

// =============================================================================

// =============================================================================
// The storage deciders
// =============================================================================

// Each is a pure function of the typing facts: which hidden storage a
// node needs, what it holds (`lir.StorageKind`), how, for how long, and
// how it drops (docs/internals/INTERNALS.md, "Storage facts"). Lowering
// asks them as it makes each body's vars, and the checkers ask the ones
// they share, so each fact is decided once.

/// The type sema recorded for an expression; null for none or poison.
pub fn typeOf(ctx: *const SemContext, e: Sexp) ?TypeId {
    return known(ctx, ctx.typeOf(e) orelse return null);
}

fn known(ctx: *const SemContext, ty: TypeId) ?TypeId {
    if (ty == ctx.types.unknown_id or ty == ctx.types.invalid_id) return null;
    return ty;
}

/// Whether a value of `ty` moves (`sema.moves`): emit holds it as a
/// resource, which its storage drops unless something takes it.
pub fn owns(ctx: *const SemContext, ty: TypeId) bool {
    return sema.moves(ctx, ty) != .no;
}

/// Whether a value of `ty` is an owning value its storage drops.
fn ownsValue(ctx: *const SemContext, e: Sexp) bool {
    return owns(ctx, typeOf(ctx, e) orelse return false);
}

/// Whether name `e` holds a view of a value, `?T` or `!T`.
fn isViewBinding(ctx: *const SemContext, e: Sexp) bool {
    return switch (ctx.types.get(typeOf(ctx, e) orelse return false)) {
        .read_view, .write_view => true,
        else => false,
    };
}

fn isPtrViewExpr(ctx: *const SemContext, e: Sexp) bool {
    return sema.viewHeldAsPointer(ctx, typeOf(ctx, e) orelse return false);
}

fn srcText(ctx: *const SemContext, leaf: Sexp) []const u8 {
    return rig.leafText(ctx.source, leaf.src);
}

/// Literal source text: numbers, quoted strings, and the value keywords.
pub fn isLiteralText(t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.ascii.isDigit(t[0]) or sema.isStringLiteralText(t) or t[0] == '.') return true;
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false");
}

/// The built-in String operation `call` is: `String(...)`, `!t.add(...)`,
/// or `!t.clear()`.
pub fn stringCall(ctx: *const SemContext, call: Sexp) ?sema.StringCall {
    if (!call.isKind(.call)) return null;
    return ctx.stringCallOf(call) orelse ctx.stringCallOf(ctx.calleeOf(call));
}

/// The object of `Type.f(...)`, `module.f(...)`, or
/// `module.Type.f(...)`: a call passing every parameter.
pub fn isTypeCallee(ctx: *const SemContext, obj: Sexp) bool {
    if (ctx.instanceOf(obj)) |inst| return inst == .type;
    if (obj.isKind(.member)) {
        const sym = moduleMemberSym(ctx, obj) orelse return false;
        return switch (sym.kind) {
            .nominal_type, .generic_type, .type_alias => true,
            else => false,
        };
    }
    const id = ctx.symbolOf(obj) orelse return false;
    return isTypeSym(ctx, id) or ctx.symbols.items[id].kind == .module;
}

/// The symbol `module.name` names in that module; null when `obj` is
/// not a module's member.
pub fn moduleMemberSym(ctx: *const SemContext, obj: Sexp) ?sema.Symbol {
    const f = ctx.foreignMember(ctx.symbolOf(ir.Member.object(obj)) orelse return null, srcText(ctx, ir.Member.name(obj))) orelse return null;
    return f.ctx.symbols.items[f.id];
}

/// An object, enum, or generic type: calling it constructs a value.
pub fn isTypeSym(ctx: *const SemContext, id: SymbolId) bool {
    return switch (ctx.symbols.items[id].kind) {
        .nominal_type, .generic_type => true,
        else => false,
    };
}

/// The function type of a function, closure, or callable view.
pub fn fnType(ctx: *const SemContext, ty: ?TypeId) ?sema.FunctionType {
    const t = ty orelse return null;
    return sema.calledFn(ctx, t);
}

/// Whether `e` is read from storage, not made for its context
/// (`sema.Hands.hasStorage`).
pub fn hasStorage(ctx: *const SemContext, e: Sexp) bool {
    return sema.handsOver(ctx, e).hasStorage();
}

/// Whether the arithmetic `e` (`+`, `-`, `*`, `-v`, or a compound
/// assignment of one) is made lane by lane on the integers of a vector,
/// by a runtime helper that checks each lane (`rig.vecAdd`). Float lanes
/// are not.
pub fn laneChecked(ctx: *const SemContext, e: Sexp) bool {
    const kind = e.kind() orelse return false;
    const op: Tag, const ty = switch (kind) {
        .set => .{ rig.bindingKindOf(ir.Set.op(e)).operator() orelse return false, typeOf(ctx, ir.Set.target(e)) orelse return false },
        .@"+", .@"-", .@"*", .neg => .{ kind, typeOf(ctx, e) orelse return false },
        else => return false,
    };
    switch (op) {
        .@"+", .@"-", .@"*", .neg => {},
        else => return false,
    }
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .simd => |v| ctx.types.get(v.elem) == .int,
        else => false,
    };
}

/// A value whose evaluation has no side effect and reads nothing a
/// later argument could change: a literal, a constant, a function,
/// a fixed binding that is no view, or a view or move of a name. A
/// fixed view binding (`r =! ?v[0]`) is read where the call writes
/// it, as a plain binding is (Core §6).
pub fn isPureArg(ctx: *const SemContext, e: Sexp) bool {
    switch (e) {
        .src => {
            if (isLiteralText(srcText(ctx, e)) or sema.isNoneLeaf(ctx, e)) return true;
            const sym = ctx.symbolOf(e) orelse return false;
            const s = ctx.symbols.items[sym];
            return switch (s.kind) {
                .local, .param, .capture => s.flags.comptime_known or (s.flags.fixed and !isViewBinding(ctx, e)),
                else => true,
            };
        },
        .list => return switch (e.kind().?) {
            .enum_lit, .symbol => true,
            // A view held as a pointer is the name's address; a view
            // held by value (a `?String`'s bytes, a slice, a copy of a
            // number) reads the name where the call runs, after the
            // arguments written before it.
            .read, .write => ir.get(e, .operand) == .src and ((isPtrViewExpr(ctx, e) and ctx.viewOf(e) == null) or isPureArg(ctx, ir.get(e, .operand))),
            .move => ir.get(e, .operand) == .src,
            .neg => ir.Neg.operand(e) == .src and isLiteralText(srcText(ctx, ir.Neg.operand(e))),
            else => false,
        },
        else => return false,
    }
}

/// The self of `value.method(...)`.
pub fn selfOf(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasSelf(ctx, call)) return null;
    return ir.Member.object(ctx.calleeOf(call));
}

/// What a call whose arguments are evaluated first holds as its self
/// (`selfHold`): the self of `value.method(...)`, the handle of an
/// actor's method, `h.m(...)`, which stands for its self, or the
/// channel of an arm of `task.select`, `ch` of `!ch.on_recv()`, which
/// the select evaluates in the arm's turn. A deadline arm,
/// `time.after(ms: 50)`, has none.
fn heldSelf(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (ctx.selectArmOf(call)) |arm| return if (arm == .after) null else ir.get(ir.Member.object(ctx.calleeOf(call)), .operand);
    if (ctx.isActorCall(call)) return ir.Member.object(ctx.calleeOf(call));
    return selfOf(ctx, call);
}

/// The part of a call it evaluates before its arguments, which a call
/// whose arguments are evaluated first holds in its turn, as written
/// (`selfHold`): its self (`heldSelf`), held as `self`, or else a
/// callee that is a value, `pick(k)(...)`, `fs[i](...)`, `mk().f(...)`,
/// `b.f(...)`, or a local `f` an argument may reassign, held as
/// `invoked`. A function, a constant, a fixed binding, a stack
/// closure, a type, a module's function, an instance, and a closure
/// literal (built first, `invoked`) are no such value.
pub fn heldFirst(ctx: *const SemContext, call: Sexp) ?HeldFirst {
    if (heldSelf(ctx, call)) |recv| return .{ .node = viewedPlace(recv), .kind = .self };
    const callee = ctx.calleeOf(call);
    if (callee == .src) {
        const sym = ctx.symbols.items[ctx.symbolOf(callee) orelse return null];
        switch (sym.kind) {
            .local, .param, .capture => if (sym.flags.closure or isPureArg(ctx, callee)) return null,
            else => return null,
        }
    }
    if (callee.isKind(.lambda) or ctx.instanceOf(callee) != null) return null;
    if (callee.isKind(.member) and isTypeCallee(ctx, ir.Member.object(callee))) return null;
    if (fnType(ctx, typeOf(ctx, callee)) == null) return null;
    return .{ .node = callee, .kind = .invoked };
}

/// The part `heldFirst` gives, without its view sigils, and the kind of
/// storage that holds it.
pub const HeldFirst = struct {
    node: Sexp,
    kind: lir.StorageKind,
};

/// Whether `call` passes a self, its callee's object, as its first
/// parameter (`value.method(...)`), as its recorded parameters say
/// (`SemContext.callParamsOf`): not `Type.f(...)`, `module.f(...)`, or a
/// callable a field holds (`s.cb(...)`). A call checked against no
/// signature has a self when its callee is a member of a value.
pub fn hasSelf(ctx: *const SemContext, call: Sexp) bool {
    const callee = ctx.calleeOf(call);
    if (!callee.isKind(.member)) return false;
    if (ctx.callParamsOf(call)) |filled| return filled.fills.len > 0 and filled.fills[0] == .self;
    return !isTypeCallee(ctx, ir.Member.object(callee));
}

/// Whether the method of `value.method(...)` takes `!@`.
pub fn selfWrites(ctx: *const SemContext, call: Sexp) bool {
    if (!hasSelf(ctx, call)) return false;
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return false;
    return f.params.len > 0 and ctx.types.get(f.params[0]) == .write_view;
}

/// The self of `value.method(...)` when it is an owned temporary
/// the method consumes (`mk().consume(...)`).
pub fn consumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    return if (decideConsumedTemporary(ctx, call) != null) selfOf(ctx, call) else null;
}

fn decideConsumedTemporary(ctx: *const SemContext, call: Sexp) ?Sexp {
    if (!hasSelf(ctx, call)) return null;
    const callee = ctx.calleeOf(call);
    const obj = ir.Member.object(callee);
    if (hasStorage(ctx, obj) or obj.isKind(.move) or !ownsValue(ctx, obj)) return null;
    const f = fnType(ctx, typeOf(ctx, callee)) orelse return null;
    if (f.params.len == 0) return null;
    return switch (ctx.types.get(f.params[0])) {
        .read_view, .write_view => null,
        else => obj,
    };
}

/// Whether a call's arguments, or an array literal's elements, must be
/// evaluated into temporaries first: when binding keyword arguments
/// reorders two that have side effects, or when a part may leave after
/// an owned value was produced (`leavesAfterOwned`), which would be lost.
pub fn hoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    if (call.isKind(.array)) return leavesAfterOwned(ctx, false, ir.Array.elems(call));
    if (!call.isKind(.call)) return false;
    // `task.select` evaluates its arms' parts first, in their order, in
    // storage that lives until the arm it commits has run; an arm holds
    // none of its own.
    if (ctx.selectArmOf(call) != null) return false;
    if (ctx.isSelect(call)) {
        var owned = false;
        for (ir.Call.args(call)) |named| {
            const arm = argValue(named);
            if (callHoistsArgs(ctx, arm)) return true;
            if (leavesAfterOwned(ctx, owned, ir.Call.args(arm))) return true;
            for (ir.Call.args(arm)) |a| owned = owned or ownsValue(ctx, argValue(a));
        }
        return false;
    }
    return callHoistsArgs(ctx, call);
}

fn callHoistsArgs(ctx: *const SemContext, call: Sexp) bool {
    if (ctx.isPrintCall(call) or stringCall(ctx, call) != null) return false;
    const args = ir.Call.args(call);
    // A closure literal passed to the call gets an environment first.
    for (args) |a| if (argValue(a).isKind(.lambda) and ctx.callableOf(argValue(a)) != null) return true;
    if (ctx.callSlotsOf(call)) |slots| {
        var last: ?usize = null;
        for (slots) |slot| {
            const given: []const u32 = switch (slot) {
                .arg => |*a| a[0..1],
                .default => continue,
                .parts => |p| p.args,
            };
            for (given) |ai| {
                if (isPureArg(ctx, argValue(args[ai]))) continue;
                if (last) |l| if (ai < l) return true;
                last = ai;
            }
        }
    }
    const callee = ctx.calleeOf(call);
    // Zig passes a temporary self to a `!@` method as a constant.
    if (selfOf(ctx, call)) |recv| if (!hasStorage(ctx, recv) and recv.kind() != .move and selfWrites(ctx, call)) return true;
    const owned = (callee.isKind(.member) and ir.Member.object(callee).isKind(.move)) or consumedTemporary(ctx, call) != null;
    return leavesAfterOwned(ctx, owned, args);
}

/// Whether a value built of several parts evaluated in order (a call's
/// arguments, an array literal's elements, the results of `return a,
/// b`) has a part that can leave after an earlier part that owns was
/// made, or after `owned` was: a `!` or `?`, or a `return`, `break`,
/// or `continue` in a `catch` handler or a branch, leaves the
/// enclosing block, and Zig, building the value as it goes, would lose
/// what was made. Such parts are evaluated into storage first, which
/// drops an owned one on the way out.
fn leavesAfterOwned(ctx: *const SemContext, owned_before: bool, parts: []const Sexp) bool {
    var owned = owned_before;
    for (parts) |a| {
        const v = argValue(a);
        if (owned and setLeaves(v)) return true;
        if (ownsValue(ctx, v)) owned = true;
    }
    return false;
}

/// How a call whose arguments are evaluated first holds its self, or
/// the callee it evaluates in its place (`heldFirst`), or null when it
/// is evaluated where the call is: a self, or a callee that owns, that
/// is a name or a field path off one, which the ownership checker
/// holds for the call, so no argument changes what it reads. A callee
/// that copies is copied in its turn, as plain data is read (Core
/// §6), which keeps no view.
fn selfHold(ctx: *const SemContext, call: Sexp) ?lir.SelfHold {
    if (consumedTemporary(ctx, call) != null) return .consumed;
    // View sigils on a self are implicit in Zig's method calls.
    const first = heldFirst(ctx, call) orelse return null;
    const recv = first.node;
    if (first.kind == .invoked and !ownsValue(ctx, recv)) return .value;
    const writes = selfWrites(ctx, call);
    const temporary = !hasStorage(ctx, recv) and !recv.isKind(.move);
    // A part that acts or leaves (`o?`, `o ?? return`, `mk()`) runs
    // before the arguments, and one that indexes picks its element
    // first.
    if (!contains(recv, &.{.index}) and !setActs(recv) and !(writes and temporary)) return null;
    if (reachesLeaf(ctx, recv)) return .leaf;
    if (temporary and keptInSlot(ctx, recv)) return .slot;
    if (!temporary) return .place;
    return .value;
}

fn argumentHold(ctx: *const SemContext, v: Sexp) lir.ArgumentHold {
    if (ctx.callableOf(v) != null) return if (v.isKind(.lambda)) .closure else .callable;
    if (ctx.viewOf(v) != null and !ctx.viewsTempArray(v)) return .viewed;
    return .value;
}

/// The types of the run-time parameters a call's arguments fill, in
/// slot order: every parameter but the one its self fills, as the
/// call's recorded parameters say (`SemContext.callParamsOf`). A callable
/// a field holds (`s.cb(...)`) has no self; `value.method(...)` does.
pub fn argParams(ctx: *const SemContext, call: Sexp) []const TypeId {
    const f = fnType(ctx, typeOf(ctx, ctx.calleeOf(call))) orelse return &.{};
    return if (hasSelf(ctx, call) and f.params.len > 0) f.params[1..] else f.params;
}

/// The type of the parameter argument `a` of `call` fills; null when
/// unknown.
fn argumentParam(ctx: *const SemContext, call: Sexp, ai: usize) ?TypeId {
    const params = argParams(ctx, call);
    const slot = if (ctx.callSlotsOf(call)) |slots| sema.slotOf(slots, ai) orelse ai else ai;
    return if (slot < params.len) params[slot] else null;
}

/// Whether `e` is a value its statement's slot keeps (`dropsTemp`), or
/// a field or element of one: Zig storage that lives until the
/// statement ends.
fn keptInSlot(ctx: *const SemContext, e: Sexp) bool {
    var p = viewedPlace(e);
    while (true) {
        if (ctx.dropsTemp(p)) return true;
        if (!p.isKind(.member) and !p.isKind(.index)) return false;
        p = viewedPlace(ir.get(p, .object));
    }
}

/// Whether `e`, a value that branches with a leaf that is not made
/// there (`sema.handsOver` is `branches`), is reached where the leaf
/// it takes is: it is read, not taken, and its type is read by
/// address (`sema.readByAddress`), as the ownership checker reads
/// each leaf in place (`holdBranchReads`). Zig would copy it into a
/// temporary, and a `?@` method would view the copy; an object, an
/// array, or a String is instead reached through the address of its
/// leaf, which Zig follows for a field, an element, or a method.
pub fn reachesLeaf(ctx: *const SemContext, e: Sexp) bool {
    if (sema.handsOver(ctx, e).kind != .branches) return false;
    if (ctx.useOf(e)) |use| if (use == .take) return false;
    const ty = typeOf(ctx, e) orelse return false;
    if (!sema.readByAddress(ctx, ty)) return false;
    return switch (ctx.types.get(ty)) {
        .string, .array, .nominal, .parameterized_nominal => true,
        else => false,
    };
}

pub fn leafStep(ctx: *const SemContext, e: Sexp) lir.LeafStep {
    if (sema.isBranchingForm(e)) return switch (e.kind().?) {
        .@"if" => .@"if",
        // One that copies the value its payload views out gives a value
        // made here, not the payload where it is.
        .@"??", .@"catch" => if (ctx.copiesPayload(e)) .made else .fallback,
        else => .unwrap,
    };
    return wholeStep(ctx, e);
}

/// The step that reaches `e` as one value, not through its parts: what
/// `leafStep` gives a value that is no branching form, and how a value
/// whose every leaf is made here (`sema.handsOver` is `made`) is reached
/// where no value that branches beside a name's encloses it.
fn wholeStep(ctx: *const SemContext, e: Sexp) lir.LeafStep {
    return switch (sema.handsOver(ctx, e).kind) {
        .place => .place,
        .part_of_made => .part,
        .view => .view,
        .jump => .jump,
        .made, .branches, .none => if (e == .src) .literal else .made,
    };
}

/// Whether a header over `e` (a `match` subject, a `for` source, an
/// `as` value) that makes statement temporaries yields the address of
/// what `e` reaches, not its value: the block that ends the temporaries
/// breaks with `&place`, and the construct binds through that pointer,
/// so what it binds is the place's own, never a copy. `e` reaches a
/// place when it is one (`sema.Hands.place`, its indexes evaluated in
/// the block) whose path starts outside the header's temporaries
/// (`startsOutsideHeader`), a view of one held as a pointer (`!v[i]`),
/// or a value that branches (`a if c else b`) each leaf of which reaches
/// one or jumps. A value made in the header, a part of one, or a place
/// inside a view of one (`id(?mk()).e`) has no place that outlives the
/// header, and the header yields its value.
pub fn headerPoints(ctx: *const SemContext, e: Sexp) bool {
    if (e == .nil or sema.firstStmtTemp(ctx, e) == null) return false;
    return reachesPlace(ctx, e);
}

/// The value a header (`match`, `for`, `as`) evaluates: a `match`'s
/// subject without its view sigils, a `for`'s source, an `as` value.
pub fn headerSubject(header: Sexp) Sexp {
    return switch (header.kind() orelse return .nil) {
        .match => viewedPlace(ir.Match.subject(header)),
        .@"for" => ir.For.source(header),
        .as => ir.As.value(header),
        else => .nil,
    };
}

fn reachesPlace(ctx: *const SemContext, e: Sexp) bool {
    // A slice is a view already, yielded as it is.
    if (rig.isRangeIndex(e)) return false;
    switch (sema.handsOver(ctx, e).kind) {
        .place => return startsOutsideHeader(ctx, e),
        // A read view of a scalar or a view is a copy.
        .view => return (e.isKind(.read) or e.isKind(.write)) and isPtrViewExpr(ctx, e) and reachesPlace(ctx, ir.get(e, .operand)),
        .branches => {
            if (!e.isKind(.@"if")) return false;
            var parts = sema.valueParts(e);
            var any = false;
            while (parts.next()) |part| switch (sema.handsOver(ctx, part.node).kind) {
                .jump => {},
                else => {
                    if (!reachesPlace(ctx, part.node)) return false;
                    any = true;
                },
            };
            return any;
        },
        .part_of_made, .made, .jump, .none => return false,
    }
}

/// Whether the field or element path `e` starts outside the statement
/// temporaries its header makes: at a name, or at a view whose
/// evaluation makes none (`get(!v)[idx(?String("a"))]`), which therefore
/// cannot point into one. A path from a view of a value the header makes
/// (`id(?mk()).e`, `(?mk()).e`, `id(?mkh()).xs`) lives inside a
/// temporary the header's block drops.
fn startsOutsideHeader(ctx: *const SemContext, e: Sexp) bool {
    var base = e;
    while (true) {
        if (base.isKind(.member) or base.isKind(.index)) {
            base = ir.get(base, .object);
        } else if (base.isKind(.read) or base.isKind(.write)) {
            base = ir.get(base, .operand);
        } else break;
    }
    return base == .src or sema.firstStmtTemp(ctx, base) == null;
}

/// Whether `if o as x` over `value` views the value inside the
/// optional rather than copying it (`checkOptionalBinding`).
pub fn viewsOptionalValue(ctx: *const SemContext, value: Sexp) bool {
    const ty = typeOf(ctx, value) orelse return false;
    return sema.viewHeldAsPointer(ctx, ty) and !ctx.readsThrough(value);
}

/// Whether a `match` subject can be read again as it is written: a
/// name, or a field of one. An element's index may have effects, and a
/// call makes a new value.
fn subjectRereadable(subject: Sexp) bool {
    var e = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
    while (e.isKind(.member)) e = ir.Member.object(e);
    return e == .src;
}

/// The type an arm's member pattern is of: an error member's own set,
/// which the subject may be one of; else the subject's, `subject`.
fn armType(ctx: *const SemContext, pattern: Sexp, subject: ?TypeId) ?TypeId {
    if (pattern.isKind(.variant_pattern) or pattern.isKind(.member)) if (ctx.typeOf(pattern)) |t| if (sema.isErrorSet(ctx, t)) return t;
    return subject;
}

/// The enum a `match` switches on: the one a box or handle holds, or
/// the subject's type.
pub fn matchedType(ctx: *const SemContext, match: Sexp) ?TypeId {
    const scrutinee = ir.Match.subject(match);
    const ty = typeOf(ctx, scrutinee) orelse return null;
    const reached = sema.unwrapAccess(ctx, ty);
    return if (reached != sema.unwrapViews(ctx, ty)) reached else ty;
}

pub fn matchMode(ctx: *const SemContext, match: Sexp) lir.MatchMode {
    const scrutinee = ir.Match.subject(match);
    if (scrutinee.isKind(.write)) return .write;
    const ty = matchedType(ctx, match) orelse return .read;
    if ((scrutinee.isKind(.move) or ctx.takesSubject(match)) and owns(ctx, ty)) return .consume;
    return .read;
}

/// Whether `pattern` is a catch-all arm's: a name that binds, or `_`;
/// not a literal, nor a module constant's name (`sema.patternConst`).
pub fn isCatchAll(ctx: *const SemContext, pattern: Sexp) bool {
    return pattern == .src and !isLiteralText(rig.leafText(ctx.source, pattern.src)) and sema.patternConst(ctx, pattern) == null;
}

/// Whether the pattern of `match` arm `arm` takes every value
/// (`isCatchAll`), decided once. Asked of the arm, not of its pattern: a
/// `matches` test's hidden `_` arm has its pattern at the position of the
/// pattern written, which may be a leaf as well.
pub fn catchesAll(ctx: *const SemContext, arm: Sexp) bool {
    return isCatchAll(ctx, ir.Arm.pattern(arm));
}

/// Whether some arm of `match` has a guard.
fn matchGuarded(match: Sexp) bool {
    for (ir.Match.arms(match)) |arm| if (ir.Arm.guard(arm) != .nil or rig.patternTests(ir.Arm.pattern(arm))) return true;
    return false;
}

/// Whether `match` picks its arm before it runs one: an arm has a guard,
/// or the match is on text, which a Zig `switch` cannot test. Decided
/// once.
pub fn matchSelects(ctx: *const SemContext, match: Sexp) bool {
    if (matchGuarded(match)) return true;
    const ty = matchedType(ctx, match) orelse return false;
    return sema.isText(ctx, sema.unwrapViews(ctx, ty));
}

/// The patterns an arm's pattern is emitted as, a prong each:
/// alternatives that bind names are a prong apiece (`emit.prongsOf`).
fn prongsOf(ctx: *const SemContext, pattern: *const Sexp) []const Sexp {
    if (ctx.altsBind(pattern.*)) return ir.AltPattern.alts(pattern.*);
    return pattern[0..1];
}

/// Whether `match` reads its subject again after picking an arm: a
/// `match !x` binding of the whole value points at the place, and a
/// `match <x` arm with alternatives drops the value from it.
pub fn matchRereads(ctx: *const SemContext, match: Sexp) bool {
    // An error that may carry fields is switched on by its code, and read
    // again for its fields.
    if (matchedType(ctx, match)) |ty| {
        const value = sema.unwrapViews(ctx, ty);
        if (ctx.types.get(value) == .any_error or sema.setHasFields(ctx, value)) return true;
    }
    const mode = matchMode(ctx, match);
    for (ir.Match.arms(match)) |arm| {
        const pattern = ir.Arm.pattern(arm);
        if (mode == .write and isCatchAll(ctx, pattern)) return true;
        if (mode == .consume and pattern.isKind(.alt_pattern) and !ctx.altsBind(pattern)) return true;
    }
    return false;
}

/// Whether `match` evaluates its subject first, or holds the value it is
/// a part of (`Header.held`), in a block around the match.
fn matchBlock(ctx: *const SemContext, match: Sexp) bool {
    return ctx.headerOf(match) == .held or matchSelects(ctx, match) or matchesGenericView(ctx, match) or
        (matchRereads(ctx, match) and !subjectRereadable(viewedPlace(ir.Match.subject(match))));
}

/// The `T` of a read view `?T` whose form depends on a generic type's
/// arguments: `T` holds a type parameter and neither owns resources nor
/// holds a Cell on its own. Emit writes it `rig.ReadView(T)`, a copy or
/// a pointer per instance; null for any other type. An object or an
/// enum with payloads, and an optional of one, is viewed by address in
/// every instance (`sema.copiedByReadView`), so its view is a pointer
/// whatever its arguments: `rig.ReadView` would ask Zig about the type,
/// which a view inside the type itself (`prev: (?Frame[T])?`) cannot.
pub fn genericReadView(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const inner = switch (ctx.types.get(ty)) {
        .read_view => |inner| inner,
        else => return null,
    };
    if (!sema.maybeDropGlue(ctx, inner) or sema.holdsCellByValue(ctx, inner)) return null;
    if (viewedByAddressAlways(ctx, inner)) return null;
    return inner;
}

/// Whether every instance of `ty` is viewed by address: an object or an
/// enum with a payload (`sema.isCompound`), or an optional of one.
fn viewedByAddressAlways(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .optional => |inner| viewedByAddressAlways(ctx, inner),
        else => sema.isCompound(ctx, ty),
    };
}

/// Whether `match`'s subject is a view a call returns whose form depends
/// on a generic type's arguments (`genericReadView`): the match holds it
/// in `__rig_subject` and switches where it points (`rig.viewedPtr`),
/// never on a copy of what it views.
fn matchesGenericView(ctx: *const SemContext, match: Sexp) bool {
    const subject = viewedPlace(ir.Match.subject(match));
    if (subject.isKind(.move) or hasStorage(ctx, subject) or !isPtrViewExpr(ctx, subject)) return false;
    return genericReadView(ctx, typeOf(ctx, subject) orelse return false) != null;
}

/// How a `match` that evaluates its subject first (`matchBlock`) holds
/// it in `__rig_subject`: the address of a place, which a header that
/// makes temporaries yields (`headerPoints`), a view a call returns as
/// the pointer it is, or the value; null when it reads the subject again
/// as it is written.
fn subjectHold(ctx: *const SemContext, match: Sexp) ?lir.StorageBy {
    const subject = viewedPlace(ir.Match.subject(match));
    if (subjectRereadable(subject)) return null;
    const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
    if (hasStorage(ctx, value) and !subject.isKind(.move) and sema.firstStmtTemp(ctx, value) == null) return .pointer;
    if (!subject.isKind(.move) and (headerPoints(ctx, value) or isPtrViewExpr(ctx, value))) return .pointer;
    return if (matchMode(ctx, match) == .consume) .owned else .copy;
}

/// The payload fields of variant `vname` of an enum type.
pub fn variantPayload(ctx: *const SemContext, enum_ty: TypeId, vname: []const u8) ?[]const sema.Field {
    const decl = sema.nominalDecl(ctx, enum_ty) orelse return null;
    const fields = decl.symbol().fields orelse return null;
    const i = sema.variantIn(ctx, fields, vname) orelse return null;
    return fields[i].payload orelse &.{};
}

/// Whether a `match !x` binding of a field of type `ty` points at the
/// field: every field but a view or slice, which is bound as it is.
fn fieldIsPointee(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .slice => false,
        else => true,
    };
}

/// Whether payload binding `b` points at the field it binds: a binding
/// a write goes through (`SemContext.bindingAccess`, `match !e`) binds a
/// pointer to each field, and a read binds one to a field it
/// views (`?F` of a field that is no view), and to a field of a type
/// parameter's value (`sema.copies` is `depends`) that the match reads
/// where its subject is (`in_place`, `matchesInPlace`): what each
/// instance reads is the subject's own, never a copy in the arm. A field
/// that is itself a view or a slice is bound as it is. The binding's
/// type and its field's (`SemContext.payloadFieldOf`) are typecheck's:
/// the field's type at the matched instance, so `v` of `Opt[?T]`'s
/// `v: T` is the view the field holds.
fn payloadByAddress(ctx: *const SemContext, b: Sexp, in_place: bool) bool {
    const sym = ctx.symbolOf(b) orelse return false;
    const writes = ctx.bindingAccess(sym) == .write;
    const field = ctx.payloadFieldOf(b) orelse return writes;
    if (!fieldIsPointee(ctx, field)) return false;
    if (writes) return true;
    const binding = known(ctx, ctx.bindingTypeOf(b) orelse return false) orelse return false;
    if (ctx.types.get(binding) == .read_view or sema.viewsStringBytes(ctx, field, binding)) return true;
    return in_place and !sema.isReadOrWriteView(ctx, binding) and sema.copies(ctx, binding) == .depends;
}

/// Whether a read match's catch-all binding of type `ty` is captured by
/// address where the match switches: a view held as a pointer, and a
/// value of a type parameter (`sema.copies` is `depends`) that the match
/// reads where its subject is (`in_place`, `matchesInPlace`), as
/// `payloadByAddress` binds a payload. Any other is a copy in the arm.
fn catchAllByAddress(ctx: *const SemContext, ty: TypeId, in_place: bool) bool {
    if (sema.viewHeldAsPointer(ctx, ty)) return true;
    return in_place and !sema.isReadOrWriteView(ctx, ty) and sema.copies(ctx, ty) == .depends;
}

/// Whether a `print`, `String(...)`, or `add` argument `a` is read where it
/// is, by address: a place that owns storage, or a view of one (a
/// function's binding, or a field or element of a value, not a slice,
/// which is a new value). Plain data is copied whole where it is read.
/// Decided once: emit passes its address, and the ownership checker holds
/// the place it reads while the later arguments run (`holdRead`).
fn printsByAddress(ctx: *const SemContext, a: Sexp) bool {
    const place = switch (a) {
        .src => if (ctx.symbolOf(a)) |id| switch (ctx.symbols.items[id].kind) {
            .param, .local, .capture => ctx.symbols.items[id].scope != sema.module_scope and ctx.callableOf(a) == null,
            else => false,
        } else false,
        .list => switch (a.kind() orelse return false) {
            .member => true,
            .index => !ir.Index.index(a).isKind(.@".."),
            else => false,
        },
        else => false,
    };
    const ty = typeOf(ctx, a) orelse return false;
    return place and sema.readByAddress(ctx, sema.unwrapViews(ctx, ty));
}

/// Whether `e`, an operand of `==` or `!=` beside `none` or a bare
/// `.variant`, is a value made here that moves and that no statement slot
/// keeps, which the test drops where it reads it (`rig.isNone`,
/// `rig.isVariantDiscard`). Decided once, for emit and the plan.
fn dropsWhenTested(ctx: *const SemContext, e: Sexp) bool {
    if (sema.handsOver(ctx, e).kind != .made or ctx.dropsTemp(e)) return false;
    const ty = typeOf(ctx, e) orelse return false;
    return owns(ctx, ty);
}

/// Whether `for` loop `loop` consumes its source, handing its elements
/// over one at a time: a List it takes (`for x in <v`) or that its source
/// makes and that owns resources, or an array of values that move, which
/// it takes or its source makes. Decided once: emit lowers the loop so,
/// the plan makes its iterator and elements, and the ownership checker
/// walks the source as taken.
pub fn forConsumes(ctx: *const SemContext, loop: Sexp) bool {
    const mode = ir.For.mode(loop).tag;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..")) return false;
    const t = typeOf(ctx, source) orelse return false;
    if (isListTy(ctx, t)) return mode == .move or (!hasStorage(ctx, source) and owns(ctx, t));
    return ctx.types.get(t) == .array and owns(ctx, ctx.types.get(t).array.elem) and (mode == .move or !hasStorage(ctx, source));
}

/// The `Fold` of `for` loop `loop`, or null when it is not one, decided
/// once.
pub fn fold(ctx: *const SemContext, loop: Sexp) ?lir.Fold {
    const mode = ir.For.mode(loop).tag;
    if (mode != .iter and mode != .read) return null;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..") or forConsumes(ctx, loop)) return null;
    if (ctx.headerOf(loop)) |how| if (how != .viewed) return null;
    if (ctx.symbolOf(ir.For.index(loop))) |i| if (ctx.isUsed(i)) return null;
    // A source a shared handle holds is walked where the handle reaches it.
    const t = typeOf(ctx, source) orelse return null;
    const walked = sema.loopWalks(ctx, t);
    if (walked != sema.unwrapViews(ctx, t)) return null;
    const elem = switch (ctx.types.get(walked)) {
        .slice => |sl| sl.elem,
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.list) pn.args[0] else return null,
        else => return null,
    };
    switch (ctx.types.get(elem)) {
        .int => |i| if (i.width() > 64) return null,
        else => return null,
    }
    const x = ctx.symbolOf(ir.For.@"var"(loop)) orelse return null;
    if (ctx.symbols.items[x].ty != elem) return null;
    const body = ir.For.body(loop);
    if (!body.isKind(.block) or ir.Block.stmts(body).len != 1) return null;
    const set = ir.Block.stmts(body)[0];
    if (!set.isKind(.set)) return null;
    const how: lir.Fold = switch (rig.bindingKindOf(ir.Set.op(set)).operator() orelse return null) {
        .@"+%" => .add_wrap,
        .@"+" => .add,
        .@"^" => .bit_xor,
        .@"|" => .bit_or,
        .@"&" => .bit_and,
        else => return null,
    };
    const target = ir.Set.target(set);
    const value = ir.Set.value(set);
    if (target != .src or value != .src or ctx.symbolOf(value) != x) return null;
    const s = ctx.symbolOf(target) orelse return null;
    const sum = ctx.symbols.items[s];
    if (s == x or sum.kind != .local or sum.access != null or sum.ty != elem) return null;
    return how;
}

/// Whether the binding of a read `for` or of an `if … as` is the bytes
/// of a String it reaches (`loopBindsStringBytes`,
/// `optionalBindsStringBytes`), decided once.
fn bindsStringBytes(ctx: *const SemContext, node: Sexp) bool {
    if (node.isKind(.@"for")) return loopBindsStringBytes(ctx, node);
    if (node.isKind(.as)) return optionalBindsStringBytes(ctx, node);
    return false;
}

/// Whether a read `for` over an array, a slice, or a List binds the bytes
/// of each String element: its binding is a `?String`, the read view of a
/// `String`, so the loop walks the elements by address and the binding is
/// each one's `.bytes()`.
fn loopBindsStringBytes(ctx: *const SemContext, loop: Sexp) bool {
    if (ir.For.mode(loop).tag == .write) return false;
    const source = ir.For.source(loop);
    if (source.isKind(.@"..") or forConsumes(ctx, loop)) return false;
    const sym = ctx.symbolOf(ir.For.@"var"(loop)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = sema.loopWalks(ctx, typeOf(ctx, source) orelse return false);
    const elem = switch (ctx.types.get(t)) {
        .array => |a| a.elem,
        .slice => |sl| sl.elem,
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.list or pn.sym == ctx.builtins.table) pn.args[0] else return false,
        else => return false,
    };
    return sema.viewsStringBytes(ctx, elem, bound);
}

/// Whether `if value as name` binds the bytes of a String that a write
/// view in the optional points at (`(!String)?`): the binding is a
/// `?String`, the read view of that String.
fn optionalBindsStringBytes(ctx: *const SemContext, cond: Sexp) bool {
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return false;
    const bound = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    const t = typeOf(ctx, ir.As.value(cond)) orelse return false;
    return switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .optional => |inner| ctx.types.get(inner) == .write_view and sema.viewsStringBytes(ctx, inner, bound),
        else => false,
    };
}

/// How the binding of `if value as name` reads through a write view, decided
/// once: when the optional holds one and the binding only reads
/// (`bindingAccess`), it is bound as the read view of what that write view
/// views. `.pointer`: the write view itself (a `?P`, or a `[]T` of a
/// `![]T`); `.value`: the value it points at, copied out, as a `?T` of a
/// scalar or a view is a copy (`sema.viewByValue`). Null for any other
/// binding.
pub fn throughWrite(ctx: *const SemContext, cond: Sexp) ?lir.ThroughWrite {
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return null;
    if (ctx.bindingAccess(sym) != .read) return null;
    const t = typeOf(ctx, ir.As.value(cond)) orelse return null;
    const reached = switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .optional => |inner| inner,
        else => return null,
    };
    return switch (ctx.types.get(reached)) {
        .write_view => |inner| if (ctx.types.get(inner) != .slice and sema.viewByValue(ctx, inner)) .value else .pointer,
        else => null,
    };
}

/// Whether payload binding `b` of `match` points at the field it binds
/// (`payloadByAddress`), decided once.

pub fn bindsByAddress(ctx: *const SemContext, b: Sexp, match: Sexp) bool {
    return payloadByAddress(ctx, b, matchesInPlace(ctx, match));
}

/// Whether the catch-all binding `pattern` of a read `match` is captured by
/// address where the match switches (`catchAllByAddress`), decided once.

pub fn catchAllCaptured(ctx: *const SemContext, pattern: Sexp, match: Sexp) bool {
    const sym = ctx.symbolOf(pattern) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    return catchAllByAddress(ctx, ty, matchesInPlace(ctx, match));
}

/// Whether `match`'s subject is a view a call returns, held as a pointer:
/// the match switches on it where it points, temporaries or not, and binds
/// no copy of it.
pub fn holdsView(ctx: *const SemContext, match: Sexp) bool {
    const subject = ir.Match.subject(match);
    return !hasStorage(ctx, subject) and isPtrViewExpr(ctx, subject);
}

/// Whether a read `match` switches on its subject where it is, never on
/// a copy: the subject reaches a place (`reachesPlace`), through its
/// header's temporaries or not, is a part of the made value the match
/// holds (`Header.held`), or is a view a call returns, switched on where
/// it points. A payload captured by pointer is then the subject's own.
pub fn matchesInPlace(ctx: *const SemContext, match: Sexp) bool {
    if (matchMode(ctx, match) != .read) return false;
    const subject = viewedPlace(ir.Match.subject(match));
    if (ctx.headerOf(match) == .held) return true;
    // A value that branches is matched where it points when it is a view
    // held as a pointer, or through the address its header yields; one
    // over bare places is a copy (`subjectHold`), so typecheck rejects
    // one that moves or may (`sema.moves` is not `no`).
    if (sema.handsOver(ctx, subject).kind == .branches) return headerPoints(ctx, subject) or isPtrViewExpr(ctx, subject);
    return reachesPlace(ctx, subject) or (!hasStorage(ctx, subject) and isPtrViewExpr(ctx, subject));
}

// =============================================================================
// The order of an assignment
// =============================================================================

/// One step of an assignment `place op= value`, in the order it runs
/// (`eachSetStep`): the value, then the value the target's path starts
/// from (its base), then each index on the path from the base outward,
/// a range's bounds left to right. The store follows the last step.
pub const SetStep = struct {
    node: Sexp,
    role: Role,

    pub const Role = enum { value, base, index };
};

/// Call `visitor.step(SetStep)` for each step of assignment `set`, in the
/// order it runs. The positive list of a target's steps: a field
/// (`.member`) and an element (`.index`) continue the path to their
/// object, and anything else is its base. A target that is a name has no
/// steps; a name as a base is one, which evaluates nothing (`baseStays`).
/// Emit, lowering, and the ownership checker all take an
/// assignment's steps from here.
pub fn eachSetStep(set: Sexp, visitor: anytype) !void {
    try visitor.step(.{ .node = ir.Set.value(set), .role = .value });
    try eachTargetStep(ir.Set.target(set), visitor);
}

/// Whether assignment target `e` is assigned through: a call, `f(x) =
/// v`, or a call's `!` or `?`, `f(x)? = v`, which writes the value the
/// write view `!T` it gives reaches (typecheck admits it only where the
/// call gives one, `assignThroughCall`). No field or element is on its
/// path, so the target is its own base (`eachSetStep`), and runs after
/// the value.
pub fn assignedThrough(e: Sexp) bool {
    if (e.isKind(.call)) return true;
    if (e.isKind(.propagate)) return ir.Propagate.value(e).isKind(.call);
    if (e.isKind(.propagate_none)) return ir.PropagateNone.value(e).isKind(.call);
    return false;
}

/// The steps of target `e` (`eachSetStep`).
pub fn eachTargetStep(e: Sexp, visitor: anytype) !void {
    if (e == .src) return;
    try eachPathStep(e, visitor);
}

fn eachPathStep(e: Sexp, visitor: anytype) !void {
    switch (e.kind() orelse return visitor.step(.{ .node = e, .role = .base })) {
        .member => try eachPathStep(ir.Member.object(e), visitor),
        .index => {
            try eachPathStep(ir.Index.object(e), visitor);
            const index = ir.Index.index(e);
            if (!index.isKind(.@"..")) return visitor.step(.{ .node = index, .role = .index });
            for ([2]Sexp{ ir.@"..".left(index), ir.@"..".right(index) }) |bound| if (bound != .nil) try visitor.step(.{ .node = bound, .role = .index });
        },
        else => try visitor.step(.{ .node = e, .role = .base }),
    }
}

/// How assignment `set` runs, decided once.
fn setOrder(ctx: *const SemContext, set: Sexp) lir.SetOrder {
    const Scan = struct {
        ctx: *const SemContext,
        /// Whether the value or an index can act; whether the base can.
        acts: bool = false,
        base_acts: bool = false,
        leaves: bool = false,
        base: Sexp = .nil,
        held_index: bool = false,

        pub fn step(sc: *@This(), s: SetStep) error{}!void {
            switch (s.role) {
                .value => {},
                .base => sc.base = s.node,
                .index => if (!isPureArg(sc.ctx, s.node)) {
                    sc.held_index = true;
                },
            }
            if (setActs(s.node)) {
                if (s.role == .base) sc.base_acts = true else sc.acts = true;
            }
            if (s.role != .value and setLeaves(s.node)) sc.leaves = true;
        }
    };
    var sc: Scan = .{ .ctx = ctx };
    eachSetStep(set, &sc) catch unreachable;
    // Zig evaluates the base, then the indexes, then the value: a base
    // that acts is in its turn unless a value that is not pure must run
    // before it.
    const held = sc.acts or (sc.base_acts and !isPureArg(ctx, ir.Set.value(set)));
    return .{
        .held = held,
        .base = held and sc.base != .nil and sc.held_index and !baseStays(sc.base),
        .guard = sc.leaves and ownsValue(ctx, ir.Set.value(set)),
        .drops_old = dropsOld(ctx, set),
    };
}

/// Whether assignment `set` replaces a value that moves (`SetOrder.drops_old`).
fn dropsOld(ctx: *const SemContext, set: Sexp) bool {
    const kind = rig.bindingKindOf(ir.Set.op(set));
    if (kind.operator() != null) return false;
    const target = ir.Set.target(set);
    if (target != .src) {
        if (kind != .default) return false;
        // A target assigned through, a call's write view, writes the
        // value the view reaches.
        const place_ty = if (assignedThrough(target)) (if (typeOf(ctx, target)) |t| sema.writtenThrough(ctx, t) else null) else typeOf(ctx, target);
        return if (place_ty) |t| owns(ctx, t) else true;
    }
    if (std.mem.eql(u8, srcText(ctx, target), "_")) return false;
    const sym = ctx.symbolOf(target) orelse return false;
    const s = ctx.symbols.items[sym];
    if (s.decl_pos == target.src.pos) return false;
    const ty = known(ctx, s.ty) orelse return false;
    if (!sema.viewHeldAsPointer(ctx, ty)) return owns(ctx, ty);
    const pointee = sema.writtenThrough(ctx, ty);
    return ctx.writesThrough(set) and !sema.viewHeldAsPointer(ctx, pointee) and owns(ctx, pointee);
}

/// How the value of `e`, which emit holds in a var or discards, drops
/// when nothing takes it (`sema.resourceKind` of its type), or null when
/// it owns nothing (`Var.drop`).
fn dropOf(ctx: *const SemContext, e: Sexp) ?sema.ResourceKind {
    return sema.resourceKind(ctx, typeOf(ctx, e) orelse return null);
}

/// Whether step `e` of an assignment can act when it runs: call, assign,
/// drop, leave, or end the program. Then the order of the steps and the
/// store is observable.
fn setActs(e: Sexp) bool {
    return contains(e, &([_]Tag{ .call, .builtin, .set, .drop, .panic } ++ leave_kinds));
}

/// Whether `return a, b` (`results`) evaluates its parts into storage
/// first, in their order (`argument` storage, one per part): a part that
/// can leave (`!`, `?`, a jump) comes after one that owns, which a
/// tuple Zig builds as it goes would lose on the way out. The storage
/// drops an owned part on that way, and the return takes each. Decided
/// once.
pub fn hoistsResults(ctx: *const SemContext, results: Sexp) bool {
    return leavesAfterOwned(ctx, false, ir.Results.values(results));
}

/// Whether step `e` of an assignment can leave before the store: `!`,
/// `?`, `return`, `break`, or `continue`.
fn setLeaves(e: Sexp) bool {
    return contains(e, &leave_kinds);
}

/// The nodes that leave the code around them: a body's exits and the
/// jumps (`rig.leavesBody`, `rig.isJump`).
pub const leave_kinds = rig.body_exit_kinds ++ rig.jump_kinds;

/// Whether the base of an assignment's path gives the same place however
/// late it is evaluated: a name, or a view of a name or of a field path
/// off one (`(!p)`, `(!p.q)`). A step that could change which place it
/// gives changes the name, which a live loan of the target forbids.
fn baseStays(e: Sexp) bool {
    var p = viewedPlace(e);
    while (p.isKind(.member)) p = ir.Member.object(p);
    return p == .src;
}

/// Whether assignment `set` to a name, which stores a value (a plain
/// local, or what a `!T` local views) rather than pointing a view
/// elsewhere, makes its value into `__rig_new` before the store: when
/// the value can act (`setOrder`). An assignment is
/// `{ __v = value; place op= __v }`, so the store goes through the
/// place as the value left it; Zig would take a `!T` local's pointer
/// before the value runs (`w.* = switch ...`).
fn storesAfterValue(ctx: *const SemContext, set: Sexp) bool {
    const target = ir.Set.target(set);
    const value = ir.Set.value(set);
    if (target != .src or !setOrder(ctx, set).held or isPureArg(ctx, value)) return false;
    const sym = ctx.symbolOf(target) orelse return false;
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse return false;
    if (sema.isReadOrWriteView(ctx, ty)) return ctx.writesThrough(set);
    return true;
}

/// Whether the fill `[n of x]` that `e` takes is built where its value
/// goes, never in a temporary on the stack first: a box's (`^[n of x]`),
/// in the box's allocation, or a binding's that declares or reassigns a
/// local array (`a = [n of x]`), in the local, by `@memset`. A
/// reassignment whose value is made first (`storesAfterValue`) is not.
pub fn fillsInPlace(ctx: *const SemContext, e: Sexp) bool {
    switch (e.kind() orelse return false) {
        .box => return ir.Box.operand(e).isKind(.array_fill),
        .set => {
            if (!ir.Set.value(e).isKind(.array_fill) or rig.bindingKindOf(ir.Set.op(e)).operator() != null) return false;
            const target = ir.Set.target(e);
            if (target != .src) return false;
            const sym = ctx.symbolOf(target) orelse return false;
            const s = ctx.symbols.items[sym];
            if (s.kind != .local or s.scope == sema.module_scope or s.flags.comptime_known) return false;
            const ty = known(ctx, s.ty) orelse return false;
            if (ctx.types.get(ty) != .array) return false;
            return s.decl_pos == target.src.pos or !storesAfterValue(ctx, e);
        },
        else => return false,
    }
}

/// Where the step of `while` loop `loop` runs, decided once.

/// A step that reads a name an `as` part of the condition binds runs in
/// the bindings' scope, after the body; any other is the continue
/// expression, which runs after that scope ends. A name reads a binding
/// when it is the binding or a closure's capture of it (`sema.findUse`).
pub fn stepPoint(ctx: *const SemContext, loop: Sexp) lir.StepPoint {
    const step = ir.While.step(loop);
    if (step == .nil) return .continue_expr;
    const Reads = struct {
        ctx: *const SemContext,
        step: Sexp,
        found: bool = false,
        pub fn part(r: *@This(), p: Sexp) error{}!void {
            if (!p.isKind(.as)) return;
            const sym = r.ctx.symbolOf(ir.As.name(p)) orelse return;
            if (sema.findUse(r.ctx, r.step, sym) != null) r.found = true;
        }
    };
    var reads: Reads = .{ .ctx = ctx, .step = step };
    rig.eachGuardPart(ir.While.cond(loop), &reads) catch unreachable;
    return if (reads.found) .after_body else .continue_expr;
}

/// Whether `e` holds a node of one of `kinds`, outside the closures in it.
pub fn contains(e: Sexp, kinds: []const Tag) bool {
    if (e != .list) return false;
    if (e.kind()) |h| {
        if (h == .lambda) return false;
        if (std.mem.findScalar(Tag, kinds, h) != null) return true;
    }
    for (e.items()) |c| if (contains(c, kinds)) return true;
    return false;
}

/// `e` without the view sigils around it.
pub fn viewedPlace(e: Sexp) Sexp {
    var x = e;
    while (x.isKind(.read) or x.isKind(.write)) x = ir.get(x, .operand);
    return x;
}

/// The value of a call argument: a `(kwarg name value)` stands for its value.
pub fn argValue(a: Sexp) Sexp {
    return if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
}

/// Whether a view reaches the value inside an optional on the way to its
/// view (the view table's `optional` row), which it captures by address.
fn viewsInsideOptional(view: sema.View) bool {
    if (view.callable() != null or view.has(.read_only)) return false;
    for (view.steps()) |step| switch (step) {
        .optional => return true,
        .elems, .text, .read_only => return false,
        else => {},
    };
    return false;
}

/// The value a block yields: its last statement, or a value that is
/// no block.
fn lastValue(e: Sexp) Sexp {
    if (!e.isKind(.block)) return e;
    const stmts = ir.Block.stmts(e);
    return if (stmts.len > 0) stmts[stmts.len - 1] else .nil;
}

// =============================================================================
// Held headers and units
// =============================================================================

/// Whether a parameter of type `ty` may hold its header: a write view of
/// a `String`, or of a `List[T]` with no inline room, viewed by pointer.
fn holdsHeaderType(ctx: *const SemContext, ty: TypeId) bool {
    const inner = switch (ctx.types.get(ty)) {
        .write_view => |inner| inner,
        else => return false,
    };
    if (!sema.viewHeldAsPointer(ctx, ty) or sema.containsTypeVar(ctx, inner)) return false;
    if (inner == ctx.types.string_id) return true;
    if (sema.listElem(ctx, inner) == null) return false;
    return switch (ctx.types.get(inner)) {
        .parameterized_nominal => |pn| pn.inline_len == 0,
        else => false,
    };
}

pub const Within = enum {
    /// Inside a `while` or `for`.
    loop,
    /// Inside a task's call, a closure, or a `raw` block.
    escape,
};

/// Whether `e` names `sym` within a node of the kind `within` asks for.
fn usedIn(ctx: *const SemContext, e: Sexp, sym: SymbolId, within: Within) bool {
    if (e == .src) return false;
    if (e != .list) return false;
    const inside = switch (within) {
        .loop => e.isKind(.@"while") or e.isKind(.@"for"),
        .escape => e.isKind(.lambda) or e.isKind(.raw_block) or (e.isKind(.call) and ir.get(e, .task) != .nil),
    };
    if (inside) return namesSym(ctx, e, sym);
    // A closure's body is its own: a loop in it is not the function's.
    if (within == .loop and e.isKind(.lambda)) return false;
    for (e.items()) |c| if (usedIn(ctx, c, sym, within)) return true;
    return false;
}

/// Whether `e` names `sym` anywhere, a closure's capture of it included.
fn namesSym(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    if (e == .src) {
        const s = ctx.symbolOf(e) orelse return false;
        return s == sym or (ctx.symbols.items[s].kind == .capture and ctx.symbols.items[s].origin == sym);
    }
    if (e != .list) return false;
    for (e.items()) |c| if (namesSym(ctx, c, sym)) return true;
    return false;
}

/// Whether `e` holds a node of `kind`.
fn containsKind(e: Sexp, kind: Tag) bool {
    if (e != .list) return false;
    if (e.isKind(kind)) return true;
    for (e.items()) |c| if (containsKind(c, kind)) return true;
    return false;
}

/// Whether closure literal `lambda` yields a value: a `fun` whose body
/// has a result.
pub fn lambdaYields(ctx: *const SemContext, lambda: Sexp) bool {
    const f = fnType(ctx, typeOf(ctx, lambda)) orelse return false;
    if (f.is_sub) return false;
    return switch (ctx.types.get(f.returns)) {
        .void, .unknown, .invalid, .noreturn => false,
        else => true,
    };
}

/// How binding `sym` drops its value: `sema.resourceKind` of its type
/// for a parameter, local, or capture, or null for one that owns
/// nothing to drop. Emit gives such a binding `var` storage and a drop
/// guard of this kind.
pub fn bindingDrop(ctx: *const SemContext, sym: SymbolId) ?sema.ResourceKind {
    const s = ctx.symbols.items[sym];
    return switch (s.kind) {
        .param, .local, .capture => if (known(ctx, s.ty)) |t| sema.resourceKind(ctx, t) else null,
        else => null,
    };
}

/// How the binding assignment `set` declares holds its value, decided
/// once: a view of a place made by address holds the place's address, any
/// other view held as a pointer holds the pointer, and everything else
/// the value. A write view of slice elements, a callable view, and a view
/// of an API object are values however they are made.
pub fn bindHold(ctx: *const SemContext, set: Sexp) lir.BindHold {
    const sym = ctx.symbolOf(ir.Set.target(set)) orelse return .value;
    const value = ir.Set.value(set);
    const ty = known(ctx, ctx.symbols.items[sym].ty) orelse
        return if (value.isKind(.read) or value.isKind(.write)) .view else .value;
    // A read view that copies (`sema.viewByValue`) is no address.
    const by_address = switch (ctx.types.get(ty)) {
        .read_view => sema.viewHeldAsPointer(ctx, ty) or genericReadView(ctx, ty) != null,
        .write_view => true,
        else => false,
    };
    if (by_address and (value.isKind(.read) or value.isKind(.write)) and
        sema.writeSliceElem(ctx, ty) == null and sema.callableFn(ctx, ty) == null and sema.objectView(ctx, ty) == null) return .view;
    return if (sema.viewHeldAsPointer(ctx, ty)) .pointer else .value;
}

/// The most bytes a task's record may take and stay in its maker's frame
/// (`task_record`): a larger one, such as one holding an array argument
/// by value, would grow every frame of a recursion that makes it.
const max_frame_task_bytes = 1024;

/// What a task's record holds besides its arguments and result, at most
/// (`sched.Record`: its `Job`'s header, its `tasks.Control`, and its
/// deadline), counted against `max_frame_task_bytes` and in its maker's
/// frame (`taskRecordBytes`). A unit test checks it against the runtime's.
const task_header_bytes = 512;

/// The task call of `stmt`, a statement of `block`, when its record stays
/// in a slot of `block`'s frame (`task_record`): a `frameTaskSite` whose
/// task never leaves its binding (`task_stays`), with a record of at most
/// `max_frame_task_bytes`. Asked by the plan (`Planner.frameTasks`) and by
/// the frame count, where the record counts (`accounts.count`).
pub fn taskRecordIn(ctx: *SemContext, stmt: Sexp, block: Sexp) !?Sexp {
    const task = frameTaskSite(ctx, stmt) orelse return null;
    if (!taskStays(ctx, stmt, block)) return null;
    const bytes = (try taskRecordBytes(ctx, task)) orelse return null;
    return if (bytes <= max_frame_task_bytes) task else null;
}

/// The bytes of the record of the task `call` makes: its header
/// (`task_header_bytes`), its self, its arguments, and its result; null
/// where a size is not known.
pub fn taskRecordBytes(ctx: *SemContext, task: Sexp) !?u128 {
    var bytes: u128 = task_header_bytes;
    const ty = typeOf(ctx, task) orelse return null;
    const result = sema.taskResult(ctx, ty) orelse return null;
    bytes += (try sema.minBytes(ctx, result)) orelse return null;
    if (selfOf(ctx, task)) |recv| {
        const rt_ = typeOf(ctx, recv) orelse return null;
        bytes += (try sema.minBytes(ctx, rt_)) orelse return null;
    }
    for (ir.Call.args(task)) |a| {
        const at = typeOf(ctx, argValue(a)) orelse return null;
        bytes += (try sema.minBytes(ctx, at)) orelse return null;
    }
    return bytes;
}

/// The task call of `stmt` if it is a site a task's record may stay in
/// its maker's frame at: an assignment, written `=`, that declares a fresh
/// name and whose whole value is a task call, `t = f(x)&`, not one through
/// an actor's handle, which the actor runs.
fn frameTaskSite(ctx: *const SemContext, stmt: Sexp) ?Sexp {
    if (!stmt.isKind(.set)) return null;
    // The value first: a task call is rare, and the name's lookup is not
    // free (the frame count asks of every statement).
    const value = ir.Set.value(stmt);
    if (!value.isKind(.call) or ir.Call.task(value) == .nil) return null;
    if (rig.bindingKindOf(ir.Set.op(stmt)) != .default) return null;
    const target = ir.Set.target(stmt);
    if (target != .src) return null;
    const sym = ctx.symbolOf(target) orelse return null;
    if (ctx.symbols.items[sym].decl_pos != target.src.pos) return null;
    if (ctx.isActorCall(value)) return null;
    return value;
}

/// Whether the task bound by `stmt`, a `frameTaskSite` in `block`, never
/// leaves its binding (`task_stays`), by a positive list of uses: every
/// later naming of the binding in the block is the task of `>t`, the self
/// of `<t.cancel()`, or a read view, `?t`, outside every closure. Its drop, which waits, then
/// runs before the block ends on every path. Any other naming, a move, a
/// `return`, a `Tasks` add, a stored field, a moving capture, or an
/// assignment, keeps the record on the heap.
fn taskStays(ctx: *const SemContext, stmt: Sexp, block: Sexp) bool {
    _ = frameTaskSite(ctx, stmt) orelse return false;
    const sym = ctx.symbolOf(ir.Set.target(stmt)) orelse return false;
    var after = false;
    for (rig.children(block)) |s| {
        if (s == .list and s.items().ptr == stmt.items().ptr) {
            after = true;
            continue;
        }
        if (after and !onlyStays(ctx, s, sym)) return false;
    }
    return after;
}

/// Whether every naming of `sym` within `e` is one that leaves the task
/// in its binding (`decideTaskStays`).
fn onlyStays(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    switch (e) {
        // A closure's capture of the binding is a symbol of its own.
        .src => return !namesSym(ctx, e, sym),
        .list => {},
        else => return true,
    }
    if (e.kind()) |kind| switch (kind) {
        // `?t`, a read view, and `?t.on_end()` through it.
        .read => if (isSym(ctx, ir.get(e, .operand), sym)) return true,
        // `>t` and `<t.cancel()`: the wait, and the cancel, which waits
        // for the end before it returns.
        .member => {
            const obj = ir.Member.object(e);
            if (obj.isKind(.move) and isSym(ctx, ir.Move.operand(obj), sym)) {
                const name = ir.Member.name(e);
                return rig.isWaitMember(e) or (name == .src and std.mem.eql(u8, srcText(ctx, name), "cancel"));
            }
        },
        else => {},
    };
    for (if (e.kind() == null) e.items() else rig.children(e)) |c| if (!onlyStays(ctx, c, sym)) return false;
    return true;
}

fn isSym(ctx: *const SemContext, e: Sexp, sym: SymbolId) bool {
    return e == .src and ctx.symbolOf(e) == sym;
}

/// The call compound assignment `set` lowers to, which assigns its
/// result, or null for Zig's own compound assignment; decided once.
pub fn compoundCall(ctx: *const SemContext, set: Sexp) ?lir.CompoundCall {
    const op = rig.bindingKindOf(ir.Set.op(set)).operator() orelse return null;
    const target = ir.Set.target(set);
    const lanes: ?sema.SimdType = if (typeOf(ctx, target)) |t| switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
        .simd => |v| v,
        else => null,
    } else null;
    if (lanes) |v| switch (op) {
        .@"&", .@"|", .@"^" => if (v.elem == ctx.types.bool_id) return .mask,
        .@"<<", .@"<<%", .@">>" => return .lane_shift,
        .@"+|", .@"-|" => return .lane_saturate,
        else => {},
    };
    return switch (op) {
        .@"%" => .rem,
        .@"/" => {
            var call: lir.CompoundCall = .div;
            for ([2]Sexp{ target, ir.Set.value(set) }) |e| {
                const ty = typeOf(ctx, e) orelse continue;
                switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
                    .float, .float_literal => return null,
                    .type_var => call = .div_generic,
                    else => {},
                }
            }
            return call;
        },
        .@"<<" => .shl,
        .@"+", .@"-", .@"*" => if (laneChecked(ctx, set)) .lane_checked else null,
        else => null,
    };
}

fn isListTy(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(sema.unwrapViews(ctx, ty))) {
        .parameterized_nominal => |pn| pn.sym == ctx.builtins.list,
        else => false,
    };
}

/// A Cell holding a List, reached by value, view, or shared handle.
fn isCellListTy(ctx: *const SemContext, ty: TypeId) bool {
    const cell = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.cell and pn.args.len == 1) pn.args[0] else return false,
        else => return false,
    };
    return isListTy(ctx, cell);
}

test "a task's record holds at most `task_header_bytes` besides its arguments and result" {
    const tasks = @import("tasks.zig");
    const F = struct {
        fn f() void {}
    };
    const Frame = tasks.Task(void).Frame(false, F.f, @TypeOf(.{}));
    try std.testing.expect(@sizeOf(Frame) <= task_header_bytes);
}
