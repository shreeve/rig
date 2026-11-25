//! Lower: each body of a module to its LIR (`src/lir.zig`), from the
//! typed tree and the recorded facts.
//!
//! A body is a function, a `sub`, a test, a `drop` body, or a closure:
//! a frame owner (`sema.FrameOwner`). Lowering walks it once, in the
//! order it runs, and makes a var for each binding and for each piece of
//! hidden storage, asking the questions the storage plan asks
//! (`src/storage.zig`). A node's vars are numbered after its operands'
//! (the plan's order), and its steps are placed in the order they run.
//!
//! In a self-checking build every module is lowered as it is checked,
//! and `shadow` asserts, per body, that the hidden vars and their order
//! are the var table's (`storage.Vars`), each held the same way, that
//! each statement's temporaries are `sema.stmtTemps`', and that each
//! binding drops as its row says. Nothing reads LIR yet: a body using a
//! construct lowering does not cover is skipped and counted.

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

/// Whether every module is lowered and checked against its var table as
/// it is checked (`-Dself-check`).
pub const enabled = @import("build_options").self_check;

/// A module's bodies, lowered.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    /// Each frame owner of the module (`SemContext.frame_owners`), by its
    /// index there.
    owners: []Owner = &.{},
    /// The index of each owner, by its root's key.
    roots: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// The var of each node and kind, and of each binding, in every body
    /// lowered: the storage emit prints.
    vars: std.AutoHashMapUnmanaged(storage.Vars.Key, *const lir.Var) = .empty,
    bindings: std.AutoHashMapUnmanaged(SymbolId, *const lir.Var) = .empty,
    /// The calls and array literals that hold their parts (a `call`
    /// region).
    holders: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The owning temporaries of each statement and header that makes
    /// any, by its key, in the order they are made.
    temps: std.AutoHashMapUnmanaged(u64, []const Sexp) = .empty,

    pub const Owner = struct {
        root: Sexp,
        /// The body around it, for a closure.
        parent: ?u32,
        func: ?*lir.Func = null,
        /// Why it was not lowered: the first construct lowering does not
        /// cover, and its family.
        skip: ?Skip = null,
    };

    pub const Skip = struct { node: Sexp, family: []const u8 };

    pub fn deinit(m: *Module) void {
        m.arena.deinit();
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

    /// The var of binding `sym`.
    pub fn bindingOf(m: *const Module, sym: SymbolId) ?*const lir.Var {
        return m.bindings.get(sym);
    }
};

/// What `shadow` checked of a module.
pub const Coverage = struct {
    bodies: u32 = 0,
    lowered: u32 = 0,
    vars: u32 = 0,
    checked: u32 = 0,
    /// Vars of nodes in no body: a compile-time function's, or a module
    /// constant's.
    outside: u32 = 0,
};

/// A problem `check` found, and the body it is in.
pub const Problem = struct {
    node: Sexp,
    what: []const u8,
    func: ?*const lir.Func = null,
};

/// Lower every body of module `tree` (a module sema checked without
/// errors).
pub fn lowerModule(gpa: std.mem.Allocator, ctx: *SemContext, tree: Sexp) !Module {
    var m: Module = .{ .arena = .init(gpa) };
    errdefer m.deinit();
    const a = m.arena.allocator();
    _ = tree;
    m.owners = try a.alloc(Module.Owner, ctx.frame_owners.items.len);
    for (ctx.frame_owners.items, m.owners, 0..) |fo, *o, i| {
        o.* = .{ .root = fo.root, .parent = fo.parent };
        try m.roots.put(a, sema.decisionKeyOf(fo.root).?, @intCast(i));
    }
    var l: Lowerer = .{ .a = a, .ctx = ctx, .module = &m };
    l.flags = try .initEmpty(a, ctx.symbols.items.len);
    for (m.owners, 0..) |o, i| {
        if (o.root.isKind(.lambda)) continue;
        l.lowerBody(@intCast(i)) catch |err| switch (err) {
            error.Uncovered => m.owners[i].skip = l.skip,
            else => |e| return e,
        };
    }
    // A closure is lowered with the body around it, or skipped with it.
    for (m.owners) |*o| if (o.func == null and o.skip == null) {
        o.skip = if (o.parent) |p| m.owners[p].skip else null;
    };
    // A binding's flag is set by any use in the module that may move it.
    for (m.owners) |o| if (o.func) |f| {
        for (f.vars.items) |*v| switch (v.name) {
            .binding => |s| {
                v.flag = l.flags.isSet(s);
                try m.bindings.put(a, s, v);
            },
            .hidden => |k| if (sema.decisionKeyOf(v.node)) |key| try m.vars.put(a, .{ .node = key, .kind = k }, v),
        };
        for (f.regions.items) |r| if (r.kind == .call) try m.holders.put(a, sema.decisionKeyOf(r.node).?, {});
    };
    return m;
}

/// Lower module `tree` and check its LIR against the var table the plan
/// made (`storage.plan`): an internal error where they differ.
pub fn shadow(ctx: *SemContext, tree: Sexp) !void {
    if (ctx.hasErrors()) return;
    var cov: Coverage = .{};
    var m = try lowerModule(ctx.allocator, ctx, tree);
    defer m.deinit();
    if (try check(ctx, &m, tree, &cov)) |p| {
        const at = diag.lineCol(ctx.source, ctx.startOf(p.node));
        // The body the problem is in, as text, before the report.
        if (p.func) |f| {
            var buffer: [4096]u8 = undefined;
            const w = std.debug.lockStderr(&buffer);
            defer std.debug.unlockStderr();
            lir.write(f, ctx, &w.file_writer.interface) catch {};
            w.file_writer.interface.flush() catch {};
        }
        std.debug.panic("{s}:{d}:{d}: internal error: lir: {s}", .{ ctx.name, at.line, at.col, p.what });
    }
}

/// Write module `tree`'s LIR (`rig check --facts=lir`): each lowered
/// body, then each body not lowered and the construct that stopped it,
/// then what the check against the var table covered.
pub fn writeModule(gpa: std.mem.Allocator, ctx: *SemContext, tree: Sexp, w: *std.Io.Writer) !void {
    var m = try lowerModule(gpa, ctx, tree);
    defer m.deinit();
    for (m.owners) |o| if (o.func) |f| try lir.write(f, ctx, w);
    for (m.owners) |o| if (o.skip) |s| {
        const at = diag.lineCol(ctx.source, ctx.startOf(o.root));
        const why = diag.lineCol(ctx.source, ctx.startOf(s.node));
        try w.print("not lowered: {s} {d}:{d}: {s} at {d}:{d}\n", .{ @tagName(o.root.kind().?), at.line, at.col, s.family, why.line, why.col });
    };
    var cov: Coverage = .{};
    if (try check(ctx, &m, tree, &cov)) |p| {
        const at = diag.lineCol(ctx.source, ctx.startOf(p.node));
        if (p.func) |f| try lir.write(f, ctx, w);
        try w.print("lir: {d}:{d}: {s}\n", .{ at.line, at.col, p.what });
    }
    try w.print("lowered {d} of {d} bodies; {d} of {d} vars checked, {d} outside every body\n", .{ cov.lowered, cov.bodies, cov.checked, cov.vars, cov.outside });
}

// =============================================================================
// The check against the var table
// =============================================================================

/// Check each lowered body of `m`: its LIR is well formed (`lir.verify`),
/// its hidden vars are the var table's rows for nodes in it, in their
/// order, each held as its row says, and each binding drops as its row
/// says. Counts what it checked in `cov`; returns the first problem.
pub fn check(ctx: *const SemContext, m: *Module, root: Sexp, cov: *Coverage) !?Problem {
    const gpa = ctx.allocator;
    const a = m.arena.allocator();
    const rows = ctx.vars.rows.items;
    // The node and kind of each row, and the body it is in.
    const row_node = try a.alloc(Sexp, rows.len);
    const row_kind = try a.alloc(StorageKind, rows.len);
    const row_owner = try a.alloc(?u32, rows.len);
    @memset(row_owner, null);
    var by_key: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty;
    var it = ctx.vars.index.iterator();
    while (it.next()) |e| {
        row_kind[e.value_ptr.*] = e.key_ptr.kind;
        const gop = try by_key.getOrPut(a, e.key_ptr.node);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, e.value_ptr.*);
    }
    try ownRows(&by_key, row_node, row_owner, &m.roots, root, null);
    // Each body's rows, in the table's order.
    const of_owner = try a.alloc(std.ArrayList(u32), m.owners.len);
    @memset(of_owner, .empty);
    for (row_owner, 0..) |o, r| if (o) |oi| try of_owner[oi].append(a, @intCast(r)) else {
        cov.outside += 1;
    };

    cov.bodies += @intCast(m.owners.len);
    cov.vars += @intCast(rows.len);
    for (m.owners, of_owner) |o, mine| {
        const f = o.func orelse continue;
        cov.lowered += 1;
        if (try lir.verify(gpa, f)) |p| return .{ .node = p.node, .what = p.what, .func = f };
        if (try checkVars(ctx, a, f, mine.items, row_node, row_kind, cov)) |p| return .{ .node = p.node, .what = p.what, .func = f };
    }
    return null;
}

/// Body `f`'s vars against its rows, `mine`, in the table's order.
fn checkVars(ctx: *const SemContext, a: std.mem.Allocator, f: *const lir.Func, mine: []const u32, row_node: []const Sexp, row_kind: []const StorageKind, cov: *Coverage) !?lir.Problem {
    const rows = ctx.vars.rows.items;
    var next: usize = 0;
    for (f.vars.items) |v| switch (v.name) {
        .binding => |s| {
            const b = ctx.vars.binding(s);
            if (b.drop != v.drop) return .{ .node = v.node, .what = "a binding drops other than its row says" };
            if (b.flag != v.flag) return .{ .node = v.node, .what = "a binding's flag differs from its row" };
        },
        .hidden => |k| {
            if (k == .temp or k == .header_copy) continue;
            if (next == mine.len) return .{ .node = v.node, .what = try std.fmt.allocPrint(a, "lowering made a `{s}` var the plan did not", .{@tagName(k)}) };
            const row = mine[next];
            const r = rows[row];
            const same_node = sema.decisionKeyOf(row_node[row]) == sema.decisionKeyOf(v.node);
            if (!same_node or row_kind[row] != k) return .{ .node = v.node, .what = try std.fmt.allocPrint(a, "lowering made a `{s}` var where the plan's next is a `{s}` at {d}:{d}", .{ @tagName(k), @tagName(row_kind[row]), diag.lineCol(ctx.source, ctx.startOf(row_node[row])).line, diag.lineCol(ctx.source, ctx.startOf(row_node[row])).col }) };
            if (r.by != v.by or r.life != v.life or r.drop != v.drop or !std.mem.eql(?sema.ResourceKind, r.parts, v.parts))
                return .{ .node = v.node, .what = try std.fmt.allocPrint(a, "a `{s}` var held other than its row: {s} {s} {s}, the row {s} {s} {s}", .{ @tagName(k), @tagName(v.by), @tagName(v.life), if (v.drop) |d| @tagName(d) else "none", @tagName(r.by), @tagName(r.life), if (r.drop) |d| @tagName(d) else "none" }) };
            next += 1;
            cov.checked += 1;
        },
    };
    if (next < mine.len) return .{ .node = row_node[mine[next]], .what = try std.fmt.allocPrint(a, "the plan made a `{s}` var lowering did not", .{@tagName(row_kind[mine[next]])}) };
    return null;
}

/// Record the node of each row keyed in `e`, and the body it is in: a
/// closure's parameters and body are its own, and its captures the body
/// around it.
fn ownRows(by_key: *const std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)), row_node: []Sexp, row_owner: []?u32, roots: *const std.AutoHashMapUnmanaged(u64, u32), e: Sexp, cur: ?u32) !void {
    if (e != .list and e != .src) return;
    if (sema.decisionKeyOf(e)) |k| if (by_key.get(k)) |rs| for (rs.items) |r| {
        row_node[r] = e;
        row_owner[r] = cur;
    };
    if (e != .list) return;
    // A compile-time function's body is in no frame: it never runs when
    // the program does (`typecheck.recordFrameOwners`).
    const inner: ?u32 = if (e.isKind(.fun) or e.isKind(.sub)) (if (rig.isCtFun(e)) null else roots.get(sema.decisionKeyOf(e).?) orelse cur) else roots.get(sema.decisionKeyOf(e) orelse 0) orelse cur;
    for (e.items(), 0..) |c, i| {
        // A closure's captures are made by the body around it.
        const in = if (e.isKind(.lambda) and i == 1) cur else inner;
        try ownRows(by_key, row_node, row_owner, roots, c, in);
    }
}

// =============================================================================
// Lowering
// =============================================================================

const Error = error{ OutOfMemory, Uncovered };

const Lowerer = struct {
    a: std.mem.Allocator,
    /// Mutable only for the frame count a task's record asks
    /// (`storage.taskRecordIn`).
    ctx: *SemContext,
    module: *Module,
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
    exprs: std.AutoHashMapUnmanaged(u64, ExprId) = .empty,
    hidden: std.AutoHashMapUnmanaged(storage.Vars.Key, VarId) = .empty,
    bindings: std.AutoHashMapUnmanaged(SymbolId, VarId) = .empty,
    call_blocks: std.AutoHashMapUnmanaged(u64, RegionId) = .empty,
    arms: std.AutoHashMapUnmanaged(u64, RegionId) = .empty,
    /// The headers that make temporaries, each lowered in a region of its
    /// own that ends them (`sema.firstStmtTemp`), and that region.
    headers: std.AutoHashMapUnmanaged(u64, ?RegionId) = .empty,
    /// The region that declares the bindings an `as` names: the body
    /// its condition guards.
    guarded: RegionId = 0,
    /// The region that declares the bindings of the `match` an `as_match`
    /// condition part is.
    as_match_scope: ?RegionId = null,
    /// The bindings a use may move out (`storage.Binding.flag`).
    flags: std.DynamicBitSetUnmanaged = .{},
    skip: ?Module.Skip = null,

    fn uncovered(l: *Lowerer, node: Sexp, family: []const u8) Error {
        l.skip = .{ .node = node, .family = family };
        return error.Uncovered;
    }

    fn addExpr(l: *Lowerer, e: lir.Expr) Error!ExprId {
        return l.f.addExpr(l.a, e);
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
        const gop = try l.hidden.getOrPut(l.a, .{ .node = key, .kind = kind });
        if (gop.found_existing) return null;
        const v = try l.f.addVar(l.a, .{ .node = node, .name = .{ .hidden = kind }, .by = by, .life = life, .drop = drop });
        gop.value_ptr.* = v;
        try l.declare(in, v);
        return v;
    }

    /// A hidden var for `node` that holds its value where it stands.
    fn holdVar(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId) Error!void {
        const v = (try l.hiddenVar(node, kind, by, life, drop, in)) orelse return;
        if (l.exprOf(node)) |e| try l.f.holdIn(l.a, e, v);
    }

    /// A hidden var for `node` that its region `in` evaluates first, in
    /// its turn: the node's place in the tree reads the var.
    fn hoistVar(l: *Lowerer, node: Sexp, kind: StorageKind, by: StorageBy, life: StorageLife, drop: ?sema.ResourceKind, in: RegionId) Error!void {
        const v = (try l.hiddenVar(node, kind, by, life, drop, in)) orelse return;
        const e = l.exprOf(node) orelse return;
        const moved = try l.addExpr(l.f.exprs.items[e]);
        l.f.exprs.items[e] = .{ .@"var" = v };
        try l.step(in, .{ .bind = .{ .v = v, .value = moved } });
    }

    fn exprOf(l: *Lowerer, node: Sexp) ?ExprId {
        return l.exprs.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// The var of binding `name`, declared in the current block.
    fn bindingVar(l: *Lowerer, name: Sexp, in: RegionId) Error!?VarId {
        const sym = l.ctx.symbolOf(name) orelse return null;
        const s = l.ctx.symbols.items[sym];
        const drop: ?sema.ResourceKind = switch (s.kind) {
            .param, .local, .capture => if (storage.known(l.ctx, s.ty)) |t| sema.resourceKind(l.ctx, t) else null,
            else => null,
        };
        const v = try l.f.addVar(l.a, .{ .node = name, .name = .{ .binding = sym }, .drop = drop });
        try l.bindings.put(l.a, sym, v);
        try l.declare(in, v);
        return v;
    }

    // -------------------------------------------------------------------------
    // Bodies
    // -------------------------------------------------------------------------

    fn lowerBody(l: *Lowerer, oi: u32) Error!void {
        const decl = l.module.owners[oi].root;
        const f = try l.a.create(lir.Func);
        f.* = .{ .root = decl };
        l.f = f;
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
        if (decl.isKind(.fun) or decl.isKind(.sub)) {
            if (storage.fnType(l.ctx, storage.typeOf(l.ctx, ir.get(decl, .name)))) |ft| l.results = sema.resultsOf(l.ctx, ft.returns);
        }
        try l.consumed(decl);
        const params: Sexp = if (decl.isKind(.@"test")) .nil else ir.get(decl, .params);
        if (params == .list) for (params.items()) |par| {
            // A `<@` or `<x` parameter is a move the plan counts.
            try l.consumed(par);
            const name = sema.paramNameNode(par) orelse continue;
            _ = try l.bindingVar(name, f.body);
            if (par.isKind(.default)) {
                // A default is evaluated where each call is: storage in
                // one is not lowered.
                const before = f.vars.items.len;
                _ = try l.expr(ir.get(par, .value));
                if (f.vars.items.len != before) return l.uncovered(par, "default values");
            }
        };
        const body = ir.get(decl, .body);
        const value = try l.stmts(body, f.body, decl.isKind(.fun) and ir.Fun.returns(decl) != .nil);
        f.region(f.body).value = value;
        try l.heldHeaders(decl, body);
        l.module.owners[oi].func = f;
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
    /// (`held_header`, `storage.planHeldHeaders`).
    fn heldHeaders(l: *Lowerer, decl: Sexp, body: Sexp) Error!void {
        const ctx = l.ctx;
        if (!decl.isKind(.fun) and !decl.isKind(.sub)) return;
        const params = ir.get(decl, .params);
        if (params != .list) return;
        const f = storage.fnType(ctx, storage.typeOf(ctx, ir.get(decl, .name))) orelse return;
        if (sema.mayHoldMarkedView(ctx, f.returns)) return;
        if (storage.containsKind(body, .raw_block)) return;
        for (params.items()) |par| {
            const name = sema.paramNameNode(par) orelse continue;
            if (std.mem.eql(u8, rig.leafText(ctx.source, name.src), "@")) continue;
            const sym = ctx.symbolOf(name) orelse continue;
            const ty = storage.known(ctx, ctx.symbols.items[sym].ty) orelse continue;
            if (!storage.holdsHeaderType(ctx, ty)) continue;
            if (!storage.usedIn(ctx, body, sym, .loop)) continue;
            if (storage.usedIn(ctx, body, sym, .escape)) continue;
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
        l.stmt_region = o.stmt;
        l.temps.shrinkRetainingCapacity(o.temps);
        try l.step(into, .{ .region = o.region });
    }

    /// Record the temporaries statement `s` made, from `first` in
    /// `temps`. A self-checking build asks that they are those
    /// `sema.stmtTemps` lists, in its order.
    fn checkTemps(l: *Lowerer, s: Sexp, first: usize) Error!void {
        const have = l.temps.items[first..];
        if (have.len > 0) {
            const nodes = try l.a.alloc(Sexp, have.len);
            for (have, nodes) |v, *n| n.* = l.f.vars.items[v].node;
            try l.module.temps.put(l.a, sema.decisionKeyOf(s).?, nodes);
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

    fn stmtBody(l: *Lowerer, s: Sexp, r: RegionId) Error!void {
        try l.consumed(s);
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
                try l.consumed(inner);
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
            if (l.ctx.symbolOf(target)) |sym| if (l.bindings.get(sym)) |v| return l.step(r, .{ .drop = v });
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
        const target_e = if (declares) blk: {
            declared = try l.bindingVar(target, l.block);
            const e = try l.addExpr(.{ .@"var" = declared.? });
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

    /// An assignment to a field or element (`storage.Planner.placeAssign`).
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
        if (sema.decisionKeyOf(n)) |k| try l.exprs.put(l.a, k, e);
    }

    /// Expression `e`: its operands first, in the tree's order, then the
    /// vars it makes.
    fn expr(l: *Lowerer, e: Sexp) Error!ExprId {
        switch (e) {
            .src => {
                const id = if (l.ctx.symbolOf(e)) |sym| (if (l.bindings.get(sym)) |v| try l.addExpr(.{ .@"var" = v }) else try l.addExpr(.{ .leaf = e })) else try l.addExpr(.{ .leaf = e });
                try l.note(e, id);
                try l.viewRules(e);
                return id;
            },
            .list => {},
            else => return l.addExpr(.{ .leaf = e }),
        }
        if (l.headers.get(sema.decisionKeyOf(e).?)) |h| if (h == null) return l.header(e, sema.decisionKeyOf(e).?);
        try l.consumed(e);
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
            .matches => return l.uncovered(e, "match"),
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
        try l.headers.put(l.a, key, h);
        const o: Open = .{ .region = h, .stmt = l.stmt_region, .temps = l.temps.items.len };
        l.stmt_region = h;
        const value_5 = try l.expr(e);
        l.region(h).value = value_5;
        try l.checkTemps(e, o.temps);
        l.stmt_region = o.stmt;
        l.temps.shrinkRetainingCapacity(o.temps);
        return l.addExpr(.{ .block = h });
    }

    /// The operation of `e` over its children, then the vars it makes.
    fn op(l: *Lowerer, e: Sexp) Error!ExprId {
        const kids = if (e.kind() == null) e.items() else rig.children(e);
        const args = try l.a.alloc(ExprId, kids.len);
        for (kids, args) |c, *x| x.* = try l.expr(c);
        const id = try l.addExpr(.{ .op = .{ .node = e, .args = args } });
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
        try l.temps.append(l.a, v);
        try l.f.holdIn(l.a, l.exprOf(e).?, v);
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
        const id = try l.addExpr(.{ .op = .{ .node = e, .args = args } });
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
                if (sema.firstStmtTemp(p.l.ctx, h) != null) try p.l.headers.put(p.l.a, sema.decisionKeyOf(h).?, null);
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
        for (names, args[1..]) |n, *x| x.* = if (try l.bindingVar(n, l.guarded)) |v| try l.addExpr(.{ .@"var" = v }) else try l.expr(n);
        const id = try l.addExpr(.{ .op = .{ .node = e, .args = args } });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        return id;
    }

    /// The vars the guard parts of `if` or `while` node `e` make
    /// (`storage.Planner.condition`), once its operands are lowered.
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

    /// `if … as` or `while … as` (`storage.Planner.optional`).
    fn optional(l: *Lowerer, cond: Sexp, body: RegionId) Error!void {
        const ctx = l.ctx;
        const value = ir.As.value(cond);
        const name = ir.As.name(cond);
        const used = if (name == .src) (if (ctx.symbolOf(name)) |s| ctx.isUsed(s) else false) else false;
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

    /// `for x, i in source` and its body (`storage.Planner.forLoop`): the
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
        for ([_]Sexp{ if (range) ir.@"..".left(source) else source, if (range) ir.@"..".right(source) else .nil }) |h| {
            if (h != .nil and sema.firstStmtTemp(ctx, h) != null) try l.headers.put(l.a, sema.decisionKeyOf(h).?, null);
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
            if (h != .nil and sema.firstStmtTemp(ctx, h) != null) try l.headers.put(l.a, sema.decisionKeyOf(h).?, null);
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
        try l.arms.put(l.a, sema.decisionKeyOf(a).?, r);
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
        if (cond != .nil and sema.firstStmtTemp(l.ctx, cond) != null) try l.headers.put(l.a, sema.decisionKeyOf(cond).?, null);
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
                try l.consumed(p);
                for (p.items()) |c| try l.pattern(c, r);
            },
            else => {},
        }
    }

    /// The vars match `m` makes (`storage.Planner.match`), declared in
    /// `scope`, or for an arm's, in the arm's region.
    fn matchRules(l: *Lowerer, m: Sexp, scope: RegionId) Error!void {
        const ctx = l.ctx;
        const mode = storage.matchMode(ctx, m);
        const subject = storage.viewedPlace(ir.Match.subject(m));
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
            try l.consumed(cap);
            const name = ir.get(cap, .name);
            const value = ir.get(cap, .value);
            if (value != .nil) {
                x.* = try l.expr(value);
            } else {
                // `|x|` reads the binding it captures where the closure is
                // made.
                const origin: ?SymbolId = if (ctx.symbolOf(name)) |s| ctx.symbols.items[s].origin else null;
                x.* = if (origin) |o| (if (l.bindings.get(o)) |v| try l.addExpr(.{ .@"var" = v }) else try l.addExpr(.{ .leaf = name })) else try l.addExpr(.{ .leaf = name });
                try l.note(name, x.*);
                try l.viewRules(name);
            }
        }
        // The body, with the lowerer's state its own. A body not lowered
        // stops its whole module's walk of the body around it, so the
        // state need not come back on an error.
        const saved = .{ l.f, l.stmt_region, l.block, l.results, l.guarded, l.as_match_scope, l.bindings };
        l.bindings = .empty;
        const f = try l.a.create(lir.Func);
        f.* = .{ .root = e };
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
            try l.consumed(par);
            const name = sema.paramNameNode(par) orelse continue;
            _ = try l.bindingVar(name, f.body);
        };
        const value = try l.stmts(ir.Lambda.body(e), f.body, storage.lambdaYields(ctx, e));
        f.region(f.body).value = value;
        l.module.owners[oi].func = f;
        l.f, l.stmt_region, l.block, l.results, l.guarded, l.as_match_scope, l.bindings = saved;
        const id = try l.addExpr(.{ .closure = .{ .node = e, .owner = oi, .captures = values } });
        try l.note(e, id);
        try l.temp(e);
        try l.viewRules(e);
        return id;
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// The region that evaluates the parts call `c` (lowered to `id`)
    /// holds first: `c` becomes a value block that yields the call.
    fn callBlock(l: *Lowerer, c: Sexp, id: ExprId) Error!RegionId {
        const key = sema.decisionKeyOf(c).?;
        if (l.call_blocks.get(key)) |r| return r;
        const r = try l.f.addRegion(l.a, c, .value);
        const moved = try l.addExpr(l.f.exprs.items[id]);
        l.f.exprs.items[id] = .{ .block = r };
        l.region(r).value = moved;
        try l.call_blocks.put(l.a, key, r);
        return r;
    }

    /// How call `c` holds what it is passed (`storage.Planner.call`).
    fn call(l: *Lowerer, c: Sexp, id: ExprId) Error!void {
        const ctx = l.ctx;
        const callee = ctx.calleeOf(c);
        const hoists = ctx.elemCallOf(callee) == null and storage.hoistsArgs(ctx, c);
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
    /// region `r` (`storage.Planner.argument`).
    fn argument(l: *Lowerer, v: Sexp, param: ?TypeId, life: StorageLife, r: RegionId) Error!void {
        const ctx = l.ctx;
        if (storage.isPureArg(ctx, v)) return;
        const by: StorageBy = switch (storage.argumentHold(ctx, v)) {
            .closure => by: {
                _ = try l.hiddenVar(v, .environment, .owned, life, null, r);
                break :by .owned;
            },
            .callable => .owned,
            .viewed => .pointer,
            .value => if (param) |t| (if (storage.isPtrViewTy(ctx, t)) .pointer else .owned) else .owned,
        };
        try l.hoistVar(v, .argument, by, life, if (by == .pointer or ctx.viewsTempArray(v)) null else storage.dropOf(ctx, v), r);
    }

    /// A call through an API object's table: the object, read once
    /// unless a name holds it, and the place a large result is written
    /// to (`storage.Planner.objectCall`).
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
        switch (storage.leafStep(l.ctx, e)) {
            .place, .part, .view, .jump => {},
            .made => if (!l.ctx.dropsTemp(e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
            .literal => if (!storage.isNoneLeaf(l.ctx, e)) try l.holdVar(e, .zig_temp, .owned, .statement, null, l.stmt_region),
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

    // -------------------------------------------------------------------------
    // Bindings a use may move out
    // -------------------------------------------------------------------------

    /// The bindings node `e` may move out (`storage.planConsumed`).
    fn consumed(l: *Lowerer, e: Sexp) Error!void {
        const ctx = l.ctx;
        switch (e.kind() orelse return) {
            .move => l.consumeName(ir.Move.operand(e)),
            .drop => l.consumeName(ir.Drop.target(e)),
            .@"return" => if (ir.Return.value(e).isKind(.results)) {
                for (ir.Results.values(ir.Return.value(e))) |part| try l.consumeTail(part);
            } else try l.consumeTail(ir.Return.value(e)),
            .@"break" => try l.consumeTail(ir.Break.value(e)),
            .@"for" => {
                if (ir.For.mode(e).tag == .move) l.consumeName(ir.For.source(e));
                try l.consumeTail(e);
            },
            .@"if" => if (ir.If.@"else"(e) != .nil) try l.consumeTail(e),
            .@"??", .@"catch", .match, .@"while", .raw_block => try l.consumeTail(e),
            .cap_move => if (ctx.symbolOf(ir.get(e, .name))) |cap| l.flags.set(ctx.symbols.items[cap].origin),
            .fun => if (ir.Fun.returns(e) != .nil) try l.consumeTail(ir.Fun.body(e)),
            .lambda => if (storage.lambdaYields(ctx, e)) try l.consumeTail(ir.Lambda.body(e)),
            else => {},
        }
    }

    fn consumeName(l: *Lowerer, node: Sexp) void {
        if (node != .src) return;
        const sym = l.ctx.symbolOf(node) orelse return;
        l.flags.set(sym);
    }

    fn consumeTail(l: *Lowerer, value: Sexp) Error!void {
        if (value == .src) return l.consumeName(value);
        try sema.eachTailPart(value, l, consumeTail);
    }
};
