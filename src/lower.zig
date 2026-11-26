//! Lower: each body of a module to its LIR (`src/lir.zig`), from the
//! typed tree and the recorded facts.
//!
//! A body is a function, a `sub`, a test, a `drop` body, a closure, or
//! a compile-time function's: a frame owner (`sema.FrameOwner`), or a
//! body the ownership checker walks though it never runs. Lowering walks
//! it once, in the order it runs, and makes a var for each binding and
//! for each piece of hidden storage, asking the storage deciders
//! (`src/storage.zig`). A node's vars are numbered after its operands',
//! and its steps are placed in the order they run.
//!
//! Every module sema accepts is lowered as it is checked, before the
//! ownership checker runs (`lowerChecked`), and kept in
//! `SemContext.lowered` until its checks finish: the ownership checker
//! reads from it the storage a call holds. Emit lowers each module again
//! as it writes it, reads the storage it writes from the vars, regions,
//! and statement temporaries indexed in `Module`, and asks its questions
//! of every node as it starts (`answerAll`). A self-checking build asks
//! that each statement's temporaries are those `sema.stmtTemps` lists.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");
const lir = @import("lir.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const StorageKind = storage.StorageKind;
const StorageBy = storage.StorageBy;
const StorageLife = storage.StorageLife;
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
    /// The answer to each question emit asks about a node of the module
    /// (`Ask`), by the node's key and the question, encoded: asked as
    /// emit starts on the module (`answerAll`).
    answers: sema.FastMap(AnswerKey, u8) = .empty,
    /// The record of each call, by the call's key, for the self-checking
    /// build's asserts that it is what emit and the ownership checker
    /// decide (`callOf`).
    calls: sema.FastMap(u64, *const lir.Call) = .empty,

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

    /// The answer to `ask` about `node`; null for a node no question of
    /// its kind is asked about.
    pub fn answer(m: *const Module, node: Sexp, comptime ask: Ask) ?Answer(ask) {
        const a = m.answers.get(.{ .key = sema.decisionKeyOf(node) orelse return null, .ask = ask }) orelse return null;
        return switch (@typeInfo(Answer(ask))) {
            .bool => a != 0,
            .@"enum" => @enumFromInt(a),
            .optional => |o| if (a == no_answer) @as(Answer(ask), null) else @as(o.child, @enumFromInt(a)),
            .@"struct" => @bitCast(a),
            else => comptime unreachable,
        };
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

    /// The record of call `node`; null in a build that does not check
    /// itself, or for a call no body lowered.
    pub fn callOf(m: *const Module, node: Sexp) ?*const lir.Call {
        if (!enabled) return null;
        return m.calls.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// In a self-checking build, that call `node`'s recorded kind is
    /// `kind`, the form `consumer` chose for it.
    pub fn expectCall(m: *const Module, ctx: *const SemContext, node: Sexp, kind: lir.CallKind, consumer: []const u8) void {
        if (!enabled) return;
        const c = m.callOf(node) orelse return;
        if (c.kind == kind) return;
        const at = diag.lineCol(ctx.source, ctx.startOf(node));
        std.debug.panic("{s}:{d}:{d}: internal error: lir: a call recorded as `{s}` that {s} writes as `{s}`", .{ ctx.name, at.line, at.col, @tagName(c.kind), consumer, @tagName(kind) });
    }

    /// In a self-checking build, that `ok` holds of call `node`'s record:
    /// what the ownership checker decides of the call, `what`.
    pub fn expectCallFact(m: *const Module, ctx: *const SemContext, node: Sexp, comptime what: []const u8, ok: fn (*const lir.Call) bool) void {
        if (!enabled) return;
        const c = m.callOf(node) orelse return;
        if (ok(c)) return;
        const at = diag.lineCol(ctx.source, ctx.startOf(node));
        std.debug.panic("{s}:{d}:{d}: internal error: lir: a call recorded as `{s}`, callee `{s}`, that the ownership checker finds " ++ what, .{ ctx.name, at.line, at.col, @tagName(c.kind), @tagName(c.callee) });
    }

    /// The var of binding `sym`.
    pub fn bindingOf(m: *const Module, sym: SymbolId) ?*const lir.Var {
        return m.bindings.get(sym);
    }
};

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
        .lambda => if (storage.lambdaYields(ctx, e)) try moveTail(ctx, ir.Lambda.body(e)),
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
        for (f.regions.items) |r| if (r.kind == .call) try m.holders.put(a, sema.decisionKeyOf(r.node).?, {});
        if (enabled) for (f.exprs.items) |e| switch (e) {
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
    /// (`storage.taskRecordIn`).
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
        const v = try l.f.addVar(l.a, .{ .node = name, .name = .{ .binding = sym }, .drop = storage.bindingDrop(l.ctx, sym) });
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
            if (storage.fnType(l.ctx, storage.typeOf(l.ctx, ir.get(decl, .name)))) |ft| l.results = sema.resultsOf(l.ctx, ft.returns);
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
    /// no inline room (`storage.holdsHeaderType`), which the body uses in
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
        const f = storage.fnType(ctx, storage.typeOf(ctx, ir.get(decl, .name))) orelse return;
        if (sema.mayHoldMarkedView(ctx, f.returns)) return;
        var raw: ?bool = null;
        for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            if (std.mem.eql(u8, rig.leafText(ctx.source, name.src), "@")) continue;
            const sym = ctx.symbolOf(name) orelse continue;
            const ty = storage.known(ctx, ctx.symbols.items[sym].ty) orelse continue;
            if (!storage.holdsHeaderType(ctx, ty)) continue;
            if (!storage.usedIn(ctx, body, sym, .loop)) continue;
            if (storage.usedIn(ctx, body, sym, .escape)) continue;
            // None is held in a body with a `raw` block, found once.
            if (raw == null) raw = storage.containsKind(body, .raw_block);
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
        try l.checkTemps(s, o.temps);
        if (l.temps.items.len > o.temps) try l.flatten(o.region);
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
    /// (`storage.taskRecordIn`).
    fn blockTasks(l: *Lowerer, block: Sexp, r: RegionId) Error!void {
        if (!block.isKind(.block)) return;
        for (rig.children(block)) |s| {
            const task = (try storage.taskRecordIn(l.ctx, s, block)) orelse continue;
            _ = try l.hiddenVar(task, .task_record, .owned, .block, null, r);
        }
    }

    fn jump(l: *Lowerer, s: Sexp, r: RegionId) Error!void {
        const value: Sexp = if (s.isKind(.@"continue")) .nil else ir.get(s, .value);
        const v: ?ExprId = if (value != .nil) try l.expr(value) else null;
        if (s.isKind(.@"return")) try l.returnParts(s);
        try l.step(r, .{ .jump = .{ .node = s, .value = v } });
    }

    /// The parts of `return a, b` its `argument` var holds: how each of
    /// the function's results drops.
    fn returnParts(l: *Lowerer, s: Sexp) Error!void {
        const value = ir.Return.value(s);
        if (!value.isKind(.results) or !storage.hoistsResults(l.ctx, value)) return;
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
        try l.holdVar(target, .discard, .owned, .statement, storage.dropOf(l.ctx, target), l.stmt_region);
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
        std.mem.rotate(VarId, l.temps.items[t0..], t1 - t0);
        const order = storage.setOrder(ctx, set);
        if (kind.operator() != null) {
            try l.openAssign(set, order, r);
            if (storage.compoundCall(ctx, set) != null and target != .src) try l.hoistVar(target, .slot, .pointer, .assignment, null, r);
            return l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e } });
        }
        if (target != .src) {
            if (kind == .default) try l.placeAssign(set, order, r);
            return l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e } });
        }
        if (std.mem.eql(u8, rig.leafText(ctx.source, target.src), "_")) {
            try l.holdVar(value, .discard, .owned, .statement, storage.dropOf(ctx, value), l.stmt_region);
            return l.step(r, .{ .eval = value_e });
        }
        if (declared) |v| return l.step(r, .{ .bind = .{ .v = v, .value = value_e } });
        // A reassigned resource's new value is made before the old one is
        // dropped, as any store whose value can act is.
        if (sym != null and (order.drops_old or storage.storesAfterValue(ctx, set))) {
            try l.hoistVar(value, .new_value, .owned, .assignment, storage.dropOf(ctx, value), r);
            value_e = l.exprOf(value) orelse value_e;
        }
        try l.step(r, .{ .store = .{ .node = set, .target = target_e, .value = value_e } });
    }

    /// An assignment to a field or element.
    fn placeAssign(l: *Lowerer, set: Sexp, order: storage.SetOrder, r: RegionId) Error!void {
        const ctx = l.ctx;
        const target = ir.Set.target(set);
        const through = storage.assignedThrough(target);
        const place_ty = if (through) (if (storage.typeOf(ctx, target)) |t| sema.writtenThrough(ctx, t) else null) else storage.typeOf(ctx, target);
        if (target.isKind(.index)) if (storage.typeOf(ctx, ir.Index.object(target))) |t| if (storage.isCellListTy(ctx, t)) return l.openAssign(set, order, r);
        const holds_view = if (through) (if (place_ty) |t| storage.isPtrViewTy(ctx, t) else false) else (target != .src and storage.isPtrViewExpr(ctx, target));
        if (holds_view or !order.drops_old) return l.openAssign(set, order, r);
        try l.hoistVar(ir.Set.value(set), .new_value, .owned, .assignment, storage.dropOf(ctx, ir.Set.value(set)), r);
        if (order.held) try l.targetSteps(set, order, r);
        try l.hoistVar(target, .slot, .pointer, .assignment, null, r);
    }

    fn openAssign(l: *Lowerer, set: Sexp, order: storage.SetOrder, r: RegionId) Error!void {
        if (!order.held) return;
        const value = ir.Set.value(set);
        if (!storage.isPureArg(l.ctx, value)) try l.hoistVar(value, .new_value, .owned, .assignment, storage.dropOf(l.ctx, value), r);
        try l.targetSteps(set, order, r);
    }

    fn targetSteps(l: *Lowerer, set: Sexp, order: storage.SetOrder, r: RegionId) Error!void {
        const Steps = struct {
            l: *Lowerer,
            order: storage.SetOrder,
            r: RegionId,

            pub fn step(st: @This(), s: storage.SetStep) Error!void {
                switch (s.role) {
                    .value => {},
                    .base => if (st.order.base) try st.l.hoistVar(s.node, .base, .pointer, .assignment, null, st.r),
                    .index => if (!storage.isPureArg(st.l.ctx, s.node)) try st.l.hoistVar(s.node, .index, .owned, .assignment, null, st.r),
                }
            }
        };
        try storage.eachTargetStep(ir.Set.target(set), Steps{ .l = l, .order = order, .r = r });
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
        const tys: []const TypeId = if (storage.typeOf(l.ctx, value)) |t| switch (l.ctx.types.get(t)) {
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

    /// Record that node `n` lowered to `e`.
    fn note(l: *Lowerer, n: Sexp, e: ExprId) Error!void {
        if (sema.decisionKeyOf(n)) |k| try l.exprs.put(l.gpa, k, e);
    }

    /// Expression `e`: its operands first, in the tree's order, then the
    /// vars it makes, then the coercions that make its value the type its
    /// context takes.
    fn expr(l: *Lowerer, e: Sexp) Error!ExprId {
        if (e == .list) if (l.headers.get(sema.decisionKeyOf(e).?)) |h| if (h == null) return l.header(e, sema.decisionKeyOf(e).?);
        const id = try l.made(e);
        try l.coerce(e, id);
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
        for (kids, args) |c, *x| x.* = try l.expr(c);
        var o: lir.Expr.Op = .{ .node = e, .args = args, .kind = opKind(e) };
        if (o.kind == .call) {
            o.aux = @intCast(l.f.calls.items.len);
            try l.f.calls.append(l.a, l.callRecord(e));
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
        if (storage.viewsInsideOptional(view)) try l.holdVar(e, .viewed, .pointer, .expression, null, l.stmt_region);
        // An API object of a value that may be held as a copy views a
        // copy, a local of the erasing block (`sema.Erasure.copy`).
        if (view.has(.erase)) if (l.ctx.erasureOf(e)) |er| if (er.copy) try l.holdVar(e, .erased_copy, .copy, .block, null, l.block);
        try l.leaves(if (e.isKind(.read) or e.isKind(.write)) ir.get(e, .operand) else e);
    }

    /// The vars a node of its kind makes, once its operands are lowered.
    fn kindRules(l: *Lowerer, e: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        switch (e.kind() orelse return) {
            .member => try l.leaves(storage.viewedPlace(ir.Member.object(e))),
            .index => try l.leaves(ir.Index.object(e)),
            .call => {
                try l.call(e, id);
                try l.objectCall(e, id);
            },
            .array => if (storage.hoistsArgs(ctx, e)) {
                const r = try l.callBlock(e, id);
                l.region(r).kind = .call;
                for (ir.Array.elems(e)) |v| try l.argument(v, null, .call, r);
            },
            // The parts of `return a, b`, made first when a later one can
            // leave, each held as the function's result in its place.
            .results => if (storage.hoistsResults(ctx, e)) try l.holdVar(e, .argument, .owned, .call, null, l.stmt_region),
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
                if (sema.firstStmtTemp(p.l.ctx, h) != null) try p.l.headers.put(p.l.gpa, sema.decisionKeyOf(h).?, null);
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
    /// (`storage.headerPoints`), or its value.
    fn subjectHeader(l: *Lowerer, e: Sexp) Error!void {
        if (e == .nil or sema.firstStmtTemp(l.ctx, e) == null) return;
        const points = storage.headerPoints(l.ctx, e);
        try l.headerVarBy(e, if (points) .pointer else .copy);
        if (points and sema.handsOver(l.ctx, e).kind == .branches and !storage.isPtrViewExpr(l.ctx, e)) try l.leaf(e);
    }

    /// Header `node` (a `match`, a `for`, or an `as`) over `subject`,
    /// whose temporaries (`sema.firstStmtTemp`) end with it, yields the
    /// address of a place the subject reaches (`storage.headerPoints`),
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
        if (storage.headerPoints(ctx, storage.headerSubject(node))) return;
        try ctx.recordHeaderCopy(node);
        if (sema.handsOver(ctx, subject).kind == .made and (if (bound) |b| sema.holdsNoLoanButText(ctx, sema.unwrapViews(ctx, b)) else true)) return;
        const what = if (inPart(subject, first, .index)) "the index" else if (inPart(subject, first, .call)) "the argument" else try std.fmt.allocPrint(l.a, "`{s}`", .{diag.textOf(ctx.source, ctx.span(first))});
        try ctx.errAt(first, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind {s} to a name first", .{what});
    }

    /// A step of `while` loop `w` that reads a binding of its condition
    /// runs inside the `if`s that bind it, after the body
    /// (`storage.StepPoint.after_body`, the same walk), so every binding there stays
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
        if (storage.typeOf(ctx, value)) |t| {
            const peeled = sema.unwrapViews(ctx, t);
            const owns = value.isKind(.move) or (sema.handsOver(ctx, value).kind == .made and peeled == t);
            if (!owns) switch (ctx.types.get(peeled)) {
                .optional => |inner| try l.headerCopy(cond, value, try boundOf(ctx, name, inner, ctx.types.get(t) == .write_view)),
                else => {},
            };
        }
        if (ctx.headerOf(cond)) |how| {
            if (how == .held) _ = try l.hiddenVar(cond, .held, .owned, .construct, if (ctx.heldBaseOf(cond)) |b| storage.dropOf(ctx, b) else null, l.stmt_region);
            try l.subjectHeader(value);
            if (used) _ = try l.hiddenVar(cond, .as_value, .pointer, .body, null, body);
            return;
        }
        if (storage.viewsOptionalValue(ctx, value)) {
            const generic = if (storage.typeOf(ctx, value)) |t| storage.genericReadView(ctx, t) != null else false;
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
        const ty: ?TypeId = if (sym) |s| storage.known(ctx, ctx.symbols.items[s].ty) else if (storage.typeOf(ctx, value)) |t| switch (ctx.types.get(sema.unwrapViews(ctx, t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        if (ty != null and storage.owns(ctx, ty.?)) _ = try l.hiddenVar(cond, .as_value, .owned, .body, null, body);
        if (used and storage.bindsStringBytes(ctx, cond)) _ = try l.hiddenVar(cond, .as_value, .pointer, .body, null, body);
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
        try l.step(scope, .{ .loop = .{ .node = w, .cond = cond, .body = body_r, .step = step_r } });
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
            if (storage.typeOf(ctx, source)) |t| if (loopElem(ctx, t)) |e| {
                try l.headerCopy(loop, source, try boundOf(ctx, ir.For.@"var"(loop), e, ir.For.mode(loop).tag == .write));
            } else try l.headerCopy(loop, source, null);
        }
        for ([_]Sexp{ if (range) ir.@"..".left(source) else source, if (range) ir.@"..".right(source) else .nil }) |h| {
            if (h != .nil and sema.firstStmtTemp(ctx, h) != null) try l.headers.put(l.gpa, sema.decisionKeyOf(h).?, null);
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
        if (storage.bindsStringBytes(ctx, loop) and used) _ = try l.hiddenVar(loop, .element, .pointer, .iteration, null, body_r);
        if (range) {
            _ = try l.hiddenVar(loop, .range_start, .owned, .construct, null, scope);
            _ = try l.hiddenVar(loop, .range_end, .owned, .construct, null, scope);
            if (rig.isInclusive(source)) _ = try l.hiddenVar(loop, .range_more, .owned, .construct, null, scope);
            try l.headerVar(ir.@"..".left(source));
            try l.headerVar(ir.@"..".right(source));
        } else if (storage.forConsumes(ctx, loop)) {
            _ = try l.hiddenVar(loop, .iterator, .owned, .construct, null, scope);
            _ = try l.hiddenVar(loop, .element, .owned, .iteration, null, body_r);
            try l.headerVar(source);
        } else {
            const how = ctx.headerOf(loop);
            if (how == .held) _ = try l.hiddenVar(loop, .held, .owned, .construct, if (ctx.heldBaseOf(loop)) |b| storage.dropOf(ctx, b) else null, scope);
            if (how == .taken) {
                _ = try l.hiddenVar(loop, .taken, .owned, .construct, null, scope);
                try l.headerVar(source);
            } else try l.subjectHeader(source);
        }
        try l.step(scope, .{ .each = .{ .node = loop, .source = src, .body = body_r } });
        try l.step(r, .{ .region = scope });
    }

    const Match = struct { scope: RegionId, choice: lir.Expr.Choice };

    /// `match` node `m`: its subject, a header, in a scope that holds what
    /// the match keeps for its arms, then each arm in a region of its own.
    fn matchOf(l: *Lowerer, m: Sexp, value: bool) Error!Match {
        const ctx = l.ctx;
        const scope = try l.f.addRegion(l.a, m, .guard);
        const raw = ir.Match.subject(m);
        const subject = storage.viewedPlace(raw);
        // The header that ends the subject's temporaries is the one
        // `matchRules` makes a var for; of two, the outer.
        const mode = storage.matchMode(ctx, m);
        var held: ?Sexp = null;
        var reread = false;
        var temp_subject = false;
        var selects = false;
        if (storage.matchBlock(ctx, m)) {
            if (storage.subjectHold(ctx, m)) |by| {
                held = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                temp_subject = mode == .consume and by == .owned;
            }
            reread = true;
            selects = storage.matchSelects(ctx, m);
        } else if (storage.matchRereads(ctx, m)) reread = true;
        const whole = !selects and !(temp_subject or (reread and mode != .consume));
        for ([_]Sexp{ if (whole) subject else .nil, if (held != null and !whole) held.? else .nil }) |h| {
            if (h != .nil and sema.firstStmtTemp(ctx, h) != null) try l.headers.put(l.gpa, sema.decisionKeyOf(h).?, null);
        }
        const subject_e = try l.expr(raw);
        const arms = ir.Match.arms(m);
        const regions = try l.a.alloc(RegionId, arms.len);
        for (arms, regions) |a, *r| r.* = try l.arm(a, value);
        if (!value) try l.matchRules(m, scope);
        return .{ .scope = scope, .choice = .{ .node = m, .subject = subject_e, .arms = regions } };
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
        if (cond != .nil and sema.firstStmtTemp(l.ctx, cond) != null) try l.headers.put(l.gpa, sema.decisionKeyOf(cond).?, null);
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
        const mode = storage.matchMode(ctx, m);
        const raw = ir.Match.subject(m);
        const subject = storage.viewedPlace(raw);
        // What the arms bind, unless the match takes its subject or
        // matches a view a call returns where it points, may be a copy.
        if (!raw.isKind(.move) and !ctx.takesSubject(m) and !storage.holdsView(ctx, m)) {
            if (storage.typeOf(ctx, raw)) |t| try l.headerCopy(m, raw, try matchBound(ctx, raw, t));
        }
        if (ctx.headerOf(m) == .held) _ = try l.hiddenVar(m, .held, .owned, .construct, if (ctx.heldBaseOf(m)) |b| storage.dropOf(ctx, b) else null, scope);
        var reread = false;
        var temp_subject = false;
        if (storage.matchBlock(ctx, m)) {
            if (storage.subjectHold(ctx, m)) |by| {
                _ = try l.hiddenVar(m, .subject, by, .construct, null, scope);
                const value = if (subject.isKind(.move)) ir.Move.operand(subject) else subject;
                if (subject.isKind(.move)) try l.headerVar(value) else try l.subjectHeader(value);
                temp_subject = mode == .consume and by == .owned;
            }
            reread = true;
            if (storage.matchSelects(ctx, m)) {
                for (ir.Match.arms(m)) |a| {
                    try l.headerVar(ir.Arm.guard(a));
                    if (mode == .consume) _ = try l.hiddenVar(a, .whole, .owned, .arm, null, l.armRegion(a));
                }
                return;
            }
        } else if (storage.matchRereads(ctx, m)) reread = true;
        if (!(temp_subject or (reread and mode != .consume))) try l.subjectHeader(subject);
        const ty = storage.matchedType(ctx, m);
        for (ir.Match.arms(m)) |a| {
            const in = l.armRegion(a);
            const pat = ir.Arm.pattern(a);
            if (storage.catchesAll(ctx, a)) {
                if (mode == .consume) _ = try l.hiddenVar(a, .whole, .owned, .arm, null, in);
                continue;
            }
            const prongs = storage.prongsOf(ctx, &pat);
            if (mode == .consume) {
                var payload = false;
                for (prongs) |prong| {
                    const variant = prong.isKind(.variant_pattern) or prong.isKind(.enum_lit) or (prong.isKind(.member) and ctx.isErrorMember(prong));
                    if (!variant) {
                        _ = try l.hiddenVar(a, .whole, .owned, .arm, null, in);
                    } else if (storage.variantPayload(ctx, storage.armType(ctx, prong, ty) orelse continue, rig.leafText(ctx.source, (if (prong.isKind(.variant_pattern)) rig.variantPatternName(prong) else ir.get(prong, .name)).src))) |fields| {
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
                    if (storage.bindsByAddress(ctx, b, m)) by_addr = true;
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
        l.results = if (storage.fnType(ctx, storage.typeOf(ctx, e))) |ft| sema.resultsOf(ctx, ft.returns) else null;
        for (cap_nodes) |cap| {
            const name = ir.get(cap, .name);
            if (name != .nil) _ = try l.bindingVar(name, f.body);
        }
        const params = ir.get(e, .params);
        if (params == .list) for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            _ = try l.bindingVar(name, f.body);
        };
        const value = try l.stmts(ir.Lambda.body(e), f.body, storage.lambdaYields(ctx, e));
        f.region(f.body).value = value;
        try l.seal(f);
        l.module.owners[oi].func = f;
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// The record of call `c`: how its callee is written and its self
    /// taken; for the checkers, its flags; and for emit, its kind
    /// (`classifyCall`) and what is opened around it, which the checkers'
    /// lowering records only in a self-checking build.
    fn callRecord(l: *Lowerer, c: Sexp) lir.Call {
        const ctx = l.ctx;
        const callee = ctx.calleeOf(c);
        var rec: lir.Call = .{ .kind = .unclassified, .callee = calleeForm(ctx, c, callee) };
        if (rec.callee == .member) {
            const obj = ir.Member.object(callee);
            const explicit = obj.isKind(.write) or obj.isKind(.read);
            rec.self = .{ .explicit = explicit, .mode = if (obj.isKind(.write)) .write else selfMode(ctx, if (explicit) ir.get(obj, .operand) else obj, callee) };
        }
        if (l.opts.checked) {
            rec.flags = .{
                .local = ctx.isLocalTask(c),
                .dense = c == .list and ctx.decides(.dense_calls, c.list.id),
                .text_only = ctx.isPrintCall(c) or (ctx.stringCallOf(c) orelse ctx.stringCallOf(callee)) != null,
                .keeps_no_loan = ctx.isActorCall(c) or ctx.selectArmOf(c) != null,
                .swap = ctx.swapCallOf(c) != null and ir.Call.args(c).len == 2,
            };
            if (!enabled) return rec;
        }
        rec.kind = classifyCall(ctx, c, &l.stack_closures);
        rec.wrap.const_maker = ctx.isConstMaker(c);
        if (c == .list and ctx.decides(.inlined_calls, c.list.id)) {
            const ty = storage.typeOf(ctx, c);
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
        const hoists = ctx.elemCallOf(callee) == null and storage.hoistsArgs(ctx, c);
        // Its record is the last made: its operands' calls were lowered
        // before it.
        l.f.calls.items[l.f.calls.items.len - 1].wrap.held = hoists;
        // A temporary array viewed as a slice by a call that evaluates its
        // arguments where they stand is viewed where Zig holds it.
        if (!hoists) for (ir.Call.args(c)) |a| if (ctx.viewsTempArray(storage.argValue(a))) try l.holdVar(storage.argValue(a), .zig_temp, .owned, .statement, null, l.stmt_region);
        if (ctx.elemCallOf(callee) != null) return;
        // A closure literal called where it is written is built first.
        if (callee.isKind(.lambda)) try l.hoistVar(callee, .invoked, .owned, .call, null, try l.callBlock(c, id));
        if (!hoists) return;
        const r = try l.callBlock(c, id);
        l.region(r).kind = .call;
        // The parts of `task.select` are its arms' (`storage.hoistsArgs`).
        if (ctx.isSelect(c)) {
            for (ir.Call.args(c)) |a| try l.callParts(storage.argValue(a), .select, r);
        } else try l.callParts(c, .call, r);
    }

    /// The parts of call `c` evaluated first, held in region `r` for
    /// `life`: its self or callee (`storage.heldFirst`), then its
    /// arguments.
    fn callParts(l: *Lowerer, c: Sexp, life: StorageLife, r: RegionId) Error!void {
        const ctx = l.ctx;
        if (storage.selfHold(ctx, c)) |hold| {
            const first: storage.HeldFirst = if (hold == .consumed) .{ .node = storage.consumedTemporary(ctx, c).?, .kind = .self } else storage.heldFirst(ctx, c).?;
            const by = hold.by(storage.hasStorage(ctx, first.node));
            const drop = if (hold == .consumed)
                (if (ctx.viewsTempArray(first.node)) null else storage.dropOf(ctx, first.node))
            else if (by == .pointer or storage.isPtrViewExpr(ctx, first.node)) null else storage.dropOf(ctx, first.node);
            try l.hoistVar(first.node, first.kind, by, life, drop, r);
        }
        for (ir.Call.args(c), 0..) |a, ai| try l.argument(storage.argValue(a), storage.argumentParam(ctx, c, ai), life, r);
    }

    /// `v`, a part of a call or an array literal evaluated first, held in
    /// region `r`.
    fn argument(l: *Lowerer, v: Sexp, param: ?TypeId, life: StorageLife, r: RegionId) Error!void {
        const ctx = l.ctx;
        if (storage.isPureArg(ctx, v)) return;
        const hold = storage.argumentHold(ctx, v);
        const by: StorageBy = switch (hold) {
            .closure => by: {
                _ = try l.hiddenVar(v, .environment, .owned, life, null, r);
                break :by .owned;
            },
            .callable => .owned,
            .viewed => .pointer,
            .value => if (param) |t| (if (storage.isPtrViewTy(ctx, t)) .pointer else .owned) else .owned,
        };
        // A value held as the view its parameter takes, or as what a
        // duration form becomes, is held as the optional it becomes.
        const ty = if (ctx.durationOf(v)) |d| d.written(ctx.types.int_id) else storage.typeOf(ctx, v);
        const shown = if (hold == .viewed) param else ty;
        const lifted = shown != ty;
        try l.hoistHeld(v, .argument, by, life, if (by == .pointer or ctx.viewsTempArray(v)) null else storage.dropOf(ctx, v), r, if (lifted) .lifted else .read);
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
        const recv = storage.viewedPlace(if (d.self_arg) ir.Call.args(c)[0] else storage.selfOf(ctx, c) orelse return);
        if (recv != .src) try l.hoistVar(recv, .api_object, .copy, .call, null, try l.callBlock(c, id));
        const entry = sema.tableEntry(ctx, d) orelse return;
        if (entry.result_out) _ = try l.hiddenVar(c, .result_place, .owned, .call, null, try l.callBlock(c, id));
    }

    // -------------------------------------------------------------------------
    // Leaves
    // -------------------------------------------------------------------------

    /// The branches of `e`, a value read where its leaves are
    /// (`storage.reachesLeaf`), that capture a payload by address.
    fn leaves(l: *Lowerer, e: Sexp) Error!void {
        if (storage.reachesLeaf(l.ctx, e)) try l.leaf(e);
    }

    fn leaf(l: *Lowerer, e: Sexp) Error!void {
        const how = storage.leafStep(l.ctx, e);
        if (!l.inConstants()) if (sema.decisionKeyOf(e)) |key| try l.module.answers.put(l.ma, .{ .key = key, .ask = .leaf_step }, encode(.leaf_step, how));
        switch (how) {
            .place, .part, .view, .jump => {},
            .made => if (!l.ctx.dropsTemp(e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
            .literal => if (!sema.isNoneLeaf(l.ctx, e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
            .@"if" => {
                try l.leaf(storage.lastValue(ir.If.then(e)));
                try l.leaf(storage.lastValue(ir.If.@"else"(e)));
            },
            .fallback => {
                try l.holdVar(e, .leaf, .pointer, .expression, null, l.stmt_region);
                if (e.isKind(.@"??")) {
                    try l.leaf(ir.@"??".left(e));
                    try l.leaf(ir.@"??".right(e));
                } else {
                    try l.leaf(ir.Catch.value(e));
                    try l.leaf(storage.lastValue(ir.Catch.handler(e)));
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
    const ty = storage.typeOf(ctx, c);
    if (ctx.elemCallOf(callee) != null) return .elem;
    if (ty) |t| if (types.get(t) == .simd) {
        const written = ir.Call.callee(c);
        if (storage.isTypeCallee(ctx, written)) return .simd_conversion;
        if (ctx.symbolOf(written)) |id| if (ctx.symbols.items[id].kind == .type_alias) return .simd_conversion;
    };
    if (ir.Call.task(c) != .nil) return if (ctx.isActorCall(c)) .actor_spawn else .task;
    if (ctx.builtinOf(c)) |b| return switch (b) {
        .print => .print,
        .warn => .warn,
        .conversion => .conversion,
        .swap => .swap,
    };
    if (storage.stringCall(ctx, c) != null) return .string;
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
            if (storage.isTypeSym(ctx, sym)) return .constructor;
        }
    }
    if (callee.isKind(.member) and ctx.typeOf(callee) == null) if (ty) |t| {
        const vname = rig.leafText(ctx.source, ir.Member.name(callee).src);
        const peeled = sema.unwrapViews(ctx, t);
        const error_set = types.get(peeled) == .any_error or sema.isErrorSet(ctx, peeled) or sema.isSetParam(ctx, peeled);
        if (error_set and storage.variantPayload(ctx, t, vname) != null) return .error_member;
        if (storage.variantPayload(ctx, t, vname) != null) return .variant_member;
        if (switch (types.get(t)) {
            .nominal => |r| !ctx.owns(r),
            else => false,
        }) return .foreign_object;
        if (types.get(t) == .parameterized_nominal and storage.isTypeCallee(ctx, callee)) return .instance;
    };
    if (storage.typeOf(ctx, callee)) |t| {
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
    if (callee.isKind(.member)) if (storage.typeOf(ctx, ir.Member.object(callee))) |t| {
        if (isBuiltinInstance(ctx, t, ctx.builtins.tasks) and rig.isWaitMember(callee)) return .wait_all;
        if (isBuiltinInstance(ctx, t, ctx.builtins.task)) return .wait;
    };
    return .plain;
}

/// How call `c`'s callee is written, as the ownership checker walks it
/// (`walkCallBody`).
fn calleeForm(ctx: *const SemContext, c: Sexp, callee: Sexp) lir.Call.Callee {
    if (callee.isKind(.member)) {
        const keeps_no_loan = ctx.isActorCall(c) or ctx.selectArmOf(c) != null;
        if (!keeps_no_loan and !storage.isTypeCallee(ctx, ir.Member.object(callee)) and !storage.hasSelf(ctx, c)) return .field_fn;
        return .member;
    }
    if (callee == .src) return .name;
    if (callee.isKind(.lambda)) return .lambda;
    return .other;
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

/// Whether a duration form of call `c` joins its failure
/// (`sema.DurationHow.folded`).
fn callFolds(ctx: *const SemContext, c: Sexp) bool {
    for (ir.Call.args(c)) |a| {
        if (ctx.durationOf(storage.argValue(a))) |d| if (d.how == .folded) return true;
    }
    if (ctx.callSlotsOf(c)) |slots| for (slots) |sl| switch (sl) {
        .parts => |p| if (p.how == .folded) return true,
        else => {},
    };
    return false;
}

/// A callee naming a type alias, this module's or an imported one.
fn isAliasCallee(ctx: *const SemContext, callee: Sexp) bool {
    if (callee.isKind(.member)) return if (storage.moduleMemberSym(ctx, callee)) |m| m.kind == .type_alias else false;
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
    const ty = storage.typeOf(ctx, e) orelse return false;
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
    return ctx.readsThrough(e) and storage.isPtrViewExpr(ctx, e);
}

// =============================================================================
// Answers
// =============================================================================

/// A question about a node whose answer emit reads (`Module.answer`):
/// each a decider of `src/storage.zig`, asked once, from the typing
/// facts, of every node of its kind in the module.
pub const Ask = enum(u8) {
    leaf_step,
    reaches_leaf,
    hands,
    views_optional_value,
    drops_when_tested,
    self_hold,
    consumes_self,
    argument_hold,
    prints_by_address,
    lane_checked,
    fills_in_place,
    set_order,
    compound_call,
    bind_hold,
    step_point,
    fold,
    binds_string_bytes,
    through_write,
    match_mode,
    matches_in_place,
    match_rereads,
    match_block,
    match_selects,
    catch_all,
    catch_all_by_address,
    payload_by_address,
    hoists_results,
};

pub const AnswerKey = struct { key: u64, ask: Ask };

/// The type of the answer to `ask`.
pub fn Answer(comptime ask: Ask) type {
    return switch (ask) {
        .leaf_step => storage.LeafStep,
        .hands => sema.Hands.Kind,
        .self_hold => ?storage.SelfHold,
        .argument_hold => storage.ArgumentHold,
        .set_order => storage.SetOrder,
        .compound_call => ?storage.CompoundCall,
        .bind_hold => storage.BindHold,
        .step_point => storage.StepPoint,
        .fold => ?storage.Fold,
        .through_write => ?storage.ThroughWrite,
        .match_mode => storage.MatchMode,
        else => bool,
    };
}

const no_answer = 255;

fn encode(comptime ask: Ask, a: Answer(ask)) u8 {
    return switch (@typeInfo(Answer(ask))) {
        .bool => @intFromBool(a),
        .@"enum" => @intFromEnum(a),
        .optional => if (a) |v| @intFromEnum(v) else no_answer,
        .@"struct" => @bitCast(a),
        else => comptime unreachable,
    };
}

/// Answer each question of `Ask` about every node of `e` it is asked of.
pub fn answerAll(m: *Module, ctx: *const SemContext, e: Sexp) !void {
    switch (e) {
        .list => for (if (e.kind() == null) e.items() else rig.children(e)) |c| try answerAll(m, ctx, c),
        .src => {},
        else => return,
    }
    const A = struct {
        m: *Module,
        ctx: *const SemContext,
        fn put(x: @This(), node: Sexp, comptime ask: Ask, a: Answer(ask)) !void {
            const key = sema.decisionKeyOf(node) orelse return;
            try x.m.answers.put(x.m.arena.allocator(), .{ .key = key, .ask = ask }, encode(ask, a));
        }
    };
    const x: A = .{ .m = m, .ctx = ctx };
    try x.put(e, .reaches_leaf, storage.reachesLeaf(ctx, e));
    try x.put(e, .hands, storage.handsKind(ctx, e));
    if (e != .list) return;
    const subject = storage.headerSubject(e);
    if (subject != .nil) {
        if (e.isKind(.as)) try x.put(subject, .views_optional_value, storage.viewsOptionalValue(ctx, subject));
    }
    switch (e.kind() orelse return) {
        .@"==", .@"!=" => for ([2]Sexp{ ir.get(e, .left), ir.get(e, .right) }) |operand| {
            try x.put(operand, .drops_when_tested, storage.dropsWhenTested(ctx, operand));
        },
        .call => {
            try x.put(e, .self_hold, storage.selfHold(ctx, e));
            try x.put(e, .consumes_self, storage.consumedTemporary(ctx, e) != null);
            for (ir.Call.args(e)) |a| try x.put(storage.argValue(a), .argument_hold, storage.argumentHold(ctx, storage.argValue(a)));
            if (ctx.isPrintCall(e) or storage.stringCall(ctx, e) != null) for (ir.Call.args(e)) |a| {
                try x.put(a, .prints_by_address, storage.printsByAddress(ctx, a));
            };
        },
        .array => for (ir.Array.elems(e)) |v| try x.put(v, .argument_hold, storage.argumentHold(ctx, v)),
        .panic => for (ir.Panic.args(e)) |a| try x.put(a, .prints_by_address, storage.printsByAddress(ctx, a)),
        .template => for (0..rig.Template.slotCount(e)) |i| {
            const v = rig.Template.value(e, i);
            try x.put(v, .prints_by_address, storage.printsByAddress(ctx, v));
        },
        .set => {
            try x.put(e, .lane_checked, storage.laneChecked(ctx, e));
            try x.put(e, .fills_in_place, storage.fillsInPlace(ctx, e));
            try x.put(e, .set_order, storage.setOrder(ctx, e));
            const target = ir.Set.target(e);
            if (rig.bindingKindOf(ir.Set.op(e)).operator() != null) try x.put(e, .compound_call, storage.compoundCall(ctx, e));
            if (target == .src) if (ctx.symbolOf(target)) |sym| if (ctx.symbols.items[sym].decl_pos == target.src.pos) {
                try x.put(e, .bind_hold, storage.bindHold(ctx, e));
            };
        },
        .box => try x.put(e, .fills_in_place, storage.fillsInPlace(ctx, e)),
        .@"+", .@"-", .@"*", .neg => try x.put(e, .lane_checked, storage.laneChecked(ctx, e)),
        .@"while" => try x.put(e, .step_point, storage.stepPoint(ctx, e)),
        .@"for" => {
            try x.put(e, .fold, storage.fold(ctx, e));
            try x.put(e, .binds_string_bytes, storage.bindsStringBytes(ctx, e));
        },
        .as => {
            try x.put(e, .binds_string_bytes, storage.bindsStringBytes(ctx, e));
            try x.put(e, .through_write, storage.throughWrite(ctx, e));
        },
        .results => try x.put(e, .hoists_results, storage.hoistsResults(ctx, e)),
        .match => {
            try x.put(e, .match_mode, storage.matchMode(ctx, e));
            try x.put(e, .matches_in_place, storage.matchesInPlace(ctx, e));
            try x.put(e, .match_rereads, storage.matchRereads(ctx, e));
            try x.put(e, .match_block, storage.matchBlock(ctx, e));
            try x.put(e, .match_selects, storage.matchSelects(ctx, e));
            for (ir.Match.arms(e)) |arm| {
                const pattern = ir.Arm.pattern(arm);
                const all = storage.catchesAll(ctx, arm);
                try x.put(arm, .catch_all, all);
                if (all) {
                    if (ctx.symbolOf(pattern) != null) try x.put(pattern, .catch_all_by_address, storage.catchAllCaptured(ctx, pattern, e));
                } else for (storage.prongsOf(ctx, &pattern)) |prong| if (prong.isKind(.variant_pattern)) {
                    for (ctx.payloadBindings(prong) orelse continue) |b| if (b != .nil) {
                        try x.put(b, .payload_by_address, storage.bindsByAddress(ctx, b, e));
                    };
                };
            }
        },
        else => {},
    }
}
