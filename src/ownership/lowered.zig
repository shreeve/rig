//! The checker's view of each body's LIR (`src/lir.zig`). Every walk
//! reads the statements of a body or block from its regions
//! (`stmtsOf`), the operands of a statement from its step (`stepOf`,
//! `stepOperand`), and the operands of an expression from its LIR
//! operation (`Expr`, `operand`). The checkers' lowering lowers every
//! body the checker walks (`lower.Options.checked`).
//!
//! A self-checking build walks each module twice, the second time with
//! `Checker.on_lir` set, which also reads bindings (`bindingAt`), a
//! name's binding through the var its use reads (`symbolOf`), a
//! statement's temporaries (`holdsTemp`), and the uses liveness reads
//! (`indexUses`) from LIR, and compares the two walks' diagnostics
//! (`compare`): the shadow of the checker on LIR.

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const lir = @import("../lir.zig");
const diag = @import("../diag.zig");
const rig = @import("../rig.zig");
const self_check = @import("build_options").self_check;
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const live = @import("live.zig");
const notes = @import("notes.zig");
const types = @import("types.zig");
const Checker = state.Checker;

/// A value for each node of a body: a list node's in an array by its id
/// less `lo`, where the body's list nodes' ids lie close enough
/// together (the parser numbers them in the order it makes them); any
/// other node's in a table by its key.
pub const NodeTable = struct {
    dense: []u32 = &.{},
    lo: u32 = 0,
    map: sema.FastMap(u64, u32) = .empty,

    const none = std.math.maxInt(u32);

    fn slot(t: *const NodeTable, node: Sexp) ?*u32 {
        if (node != .list or t.dense.len == 0) return null;
        const i = node.list.id -% t.lo;
        return if (i < t.dense.len) &t.dense[i] else null;
    }

    pub fn get(t: *const NodeTable, node: Sexp) ?u32 {
        if (t.slot(node)) |at| return if (at.* == none) null else at.*;
        return t.map.get(sema.decisionKeyOf(node) orelse return null);
    }

    /// Record `v` for `node`, unless one is recorded (`first`) or
    /// over it.
    fn put(t: *NodeTable, a: std.mem.Allocator, node: Sexp, v: u32, first: bool) Error!void {
        if (t.slot(node)) |at| {
            if (!first or at.* == none) at.* = v;
            return;
        }
        const gop = try t.map.getOrPut(a, sema.decisionKeyOf(node) orelse return);
        if (!first or !gop.found_existing) gop.value_ptr.* = v;
    }
};

/// A body lowered, and what the walk looks up in it by tree node.
pub const Body = struct {
    f: *const lir.Func,
    /// The outermost expression made for each node: each list node's,
    /// and in the shadow each leaf's too (`leaves`).
    exprs: NodeTable = .{},
    leaves: bool = false,
    /// The region made for each block: the body's by the function's
    /// block, a `defer`'s by its body, a `catch`'s by its handler.
    regions: NodeTable = .{},
    /// The region of each statement, which holds its temporaries.
    stmts: NodeTable = .{},
    /// The calls and array literals that evaluate parts first, in a
    /// region of kind `call`, by their nodes' keys.
    calls: sema.FastMap(u64, void) = .empty,
    /// The binding each var of a binding declares, by its declaring
    /// name's key.
    binds: sema.FastMap(u64, SymbolId) = .empty,
    /// The nodes whose value a statement holds in a temporary it drops.
    temps: sema.FastMap(u64, void) = .empty,
    /// The value each hidden var a region evaluates first holds (a part
    /// a call or an assignment holds), by the var: the operand that
    /// reads the var is walked as that value, where it stands.
    /// By var id; empty where no region holds a part first.
    hoisted: []lir.ExprId = &.{},
};

/// An expression the walk reaches: its tree node, and, in a lowered
/// body, the LIR expression made for it (`id`), whose operands the
/// walk takes as the operands of the node.
pub const Expr = struct {
    node: Sexp,
    id: ?lir.ExprId = null,
};

/// The value hidden var `v` holds, where a region evaluates it first.
fn hoistedOf(b: *const Body, v: lir.VarId) ?lir.ExprId {
    if (v >= b.hoisted.len or b.hoisted[v] == NodeTable.none) return null;
    return b.hoisted[v];
}

/// Tree node `node` as the walk reaches it: with the outermost LIR
/// expression made for it, in a lowered body.
pub fn exprAt(self: *const Checker, node: Sexp) Expr {
    const b = self.lir_body orelse return .{ .node = node };
    // A leaf's expression has no operands: only the shadow, which reads
    // the var a name's use reads, looks one up.
    if (!b.leaves and node != .list) return .{ .node = node };
    return .{ .node = node, .id = b.exprs.get(node) };
}

/// The node LIR expression `id` of body `b` is the value of.
pub fn nodeOf(b: *const Body, id: lir.ExprId) Sexp {
    return switch (b.f.exprs.items[id]) {
        .@"var" => |x| x.node,
        .leaf => |l| l,
        .op => |o| o.node,
        .hold => |h| nodeOf(b, h.value),
        .block => |r| b.f.regions.items[r].node,
        .branch => |x| x.node,
        .choice => |x| x.node,
        .closure => |x| x.node,
        .coerce => |x| x.node,
    };
}

/// The operation `e` is, under the coercions and holds of its node, a
/// var that holds it first, and the region that holds its parts or
/// ends its temporaries; null for any other expression, and outside a
/// lowered body.
pub fn opOf(self: *const Checker, e: Expr) ?lir.Expr.Op {
    const b = self.lir_body orelse return null;
    var id = e.id orelse return null;
    while (true) switch (b.f.exprs.items[id]) {
        .coerce => |c| id = c.value,
        .hold => |h| id = h.value,
        .@"var" => |x| id = hoistedOf(b, x.v) orelse return null,
        .block => |r| {
            const reg = &b.f.regions.items[r];
            switch (reg.kind) {
                .call, .header, .value => id = reg.value orelse return null,
                else => return null,
            }
        },
        .op => |o| return if (sema.decisionKeyOf(o.node) == sema.decisionKeyOf(e.node)) o else null,
        else => return null,
    };
}

/// Operand `i` of `e`: the LIR's, where `e` is an operation of a
/// lowered body, else the tree's child `i`.
pub fn operand(self: *const Checker, e: Expr, i: usize) Expr {
    const o = opOf(self, e) orelse return exprAt(self, rig.children(e.node)[i]);
    const id = o.args[i];
    const node = nodeOf(self.lir_body.?, id);
    if (self_check) {
        const child = rig.children(e.node)[i];
        if (sema.decisionKeyOf(node) != sema.decisionKeyOf(child)) std.debug.panic("internal error: an operand of a lowered `{s}` is not its tree child", .{@tagName(e.node.kind() orelse .module)});
    }
    return .{ .node = node, .id = id };
}

/// Whether call or array literal `e` evaluates parts first, in a region
/// of its own, before it runs: then each operand no hidden var holds
/// (`heldFirst`) is read where it runs. Null outside a lowered body.
pub fn holdsParts(self: *const Checker, e: Expr) ?bool {
    const b = self.lir_body orelse return null;
    return b.calls.contains(sema.decisionKeyOf(e.node) orelse return false);
}

/// Whether operand `e` is a part its region evaluates first, held in a
/// hidden var, under the coercions made where the var is read.
pub fn heldFirst(self: *const Checker, e: Expr) bool {
    const b = self.lir_body orelse return false;
    var id = e.id orelse return false;
    while (true) switch (b.f.exprs.items[id]) {
        .coerce => |c| id = c.value,
        .@"var" => |x| return hoistedOf(b, x.v) != null,
        else => return false,
    };
}

/// How many operands `e` has: its tree children.
pub fn operandCount(e: Expr) usize {
    return rig.children(e.node).len;
}

/// The lowered body `root` declares, whose block or expression is
/// `body`, indexed; null when the body was not lowered.
pub fn enter(self: *Checker, root: Sexp, body: Sexp) Error!?*Body {
    const m = &(self.sema.lowered orelse return null);
    const f = blk: {
        const i = m.roots.get(sema.decisionKeyOf(root) orelse break :blk null) orelse break :blk null;
        break :blk m.owners[i].func;
    } orelse {
        // The checkers' lowering lowers every body they walk.
        if (self_check) {
            const at = diag.lineCol(self.source, self.sema.startOf(root));
            std.debug.panic("{s}:{d}:{d}: internal error: the ownership checker walks a `{s}` with no LIR", .{ self.sema.name, at.line, at.col, @tagName(root.kind() orelse .module) });
        }
        return null;
    };
    // A function's index lives while its walk does: the function arena
    // is reset after each module-level function. The module's own body
    // lives until it is walked (`dropConstants`).
    const a = if (root.isKind(.module)) self.const_arena_state.allocator() else self.fn_arena_state.allocator();
    const out = try a.create(Body);
    out.* = .{ .f = f, .leaves = self.on_lir };
    // The ids of the body's list nodes, which the parser numbers in
    // the order it makes them, mostly lie in one stretch: an array over
    // it finds each without hashing.
    var lists: u32 = 0;
    var leaves: u32 = 0;
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    for (f.exprs.items) |e| {
        const node = nodeOfExpr(e);
        if (node == .list and node.list.id != 0) {
            lists += 1;
            lo = @min(lo, node.list.id);
            hi = @max(hi, node.list.id);
        } else if (node == .src) leaves += 1;
    }
    var regions: u32 = 0;
    var hoists = false;
    for (f.regions.items) |r| {
        if (r.node == .list and r.node.list.id != 0) {
            regions += 1;
            lo = @min(lo, r.node.list.id);
            hi = @max(hi, r.node.list.id);
        }
        for (r.steps.items) |s| switch (s) {
            .bind => |x| if (f.vars.items[x.v].name == .hidden) {
                if (!hoists) {
                    out.hoisted = try a.alloc(lir.ExprId, f.vars.items.len);
                    @memset(out.hoisted, NodeTable.none);
                    hoists = true;
                }
                out.hoisted[x.v] = x.value;
            },
            else => {},
        };
    }
    if (lists + regions > 0 and hi - lo < 4 * (lists + regions) + 256) {
        // One array for the three tables.
        const n = hi - lo + 1;
        const all = try a.alloc(u32, 3 * n);
        @memset(all, NodeTable.none);
        out.exprs.dense, out.stmts.dense, out.regions.dense = .{ all[0..n], all[n .. 2 * n], all[2 * n ..] };
        out.exprs.lo, out.stmts.lo, out.regions.lo = .{ lo, lo, lo };
        lists = 0;
    } else try out.stmts.map.ensureTotalCapacity(a, regions);
    try out.exprs.map.ensureTotalCapacity(a, lists + if (out.leaves) leaves else 0);
    if (self.on_lir) for (f.vars.items) |v| switch (v.name) {
        .binding => |s| if (sema.decisionKeyOf(v.node)) |key| try out.binds.put(a, key, s),
        .hidden => |k| if (k == .temp) if (sema.decisionKeyOf(v.node)) |key| try out.temps.put(a, key, {}),
    };
    try out.regions.put(a, body, f.body, false);
    try index(out, a, f.body);
    return out;
}

/// The module's compile-time body is walked: free its index, and,
/// outside a self-checking build (whose shadow walks it again), its LIR.
pub fn dropConstants(self: *Checker) void {
    _ = self.const_arena_state.reset(.free_all);
    if (!self_check) if (self.interner.lowered) |*m| m.dropConstants();
}

/// Index region `r` and everything in it, outermost first.
fn index(b: *Body, a: std.mem.Allocator, r: lir.RegionId) Error!void {
    const reg = &b.f.regions.items[r];
    if (sema.decisionKeyOf(reg.node)) |key| switch (reg.kind) {
        .block => {
            // A `defer`'s region is its body's, a `catch`'s its handler's.
            const body = switch (reg.node.kind() orelse .module) {
                .@"defer", .@"errdefer" => ir.get(reg.node, .body),
                .@"catch" => ir.Catch.handler(reg.node),
                else => reg.node,
            };
            try b.regions.put(a, if (sema.decisionKeyOf(body) != null) body else reg.node, r, true);
        },
        .stmt => try b.stmts.put(a, reg.node, r, false),
        .call => try b.calls.put(a, key, {}),
        else => {},
    };
    for (reg.steps.items) |s| switch (s) {
        .bind => |x| try expr(b, a, x.value),
        .store => |x| {
            try expr(b, a, x.target);
            try expr(b, a, x.value);
        },
        .eval => |e| try expr(b, a, e),
        .drop => {},
        .jump => |j| if (j.value) |e| try expr(b, a, e),
        .region => |sub| try index(b, a, sub),
        .@"if" => |i| {
            try expr(b, a, i.cond);
            try index(b, a, i.then);
            if (i.@"else") |e| try index(b, a, e);
        },
        .loop => |lp| {
            try expr(b, a, lp.cond);
            try index(b, a, lp.body);
            if (lp.step) |st| try index(b, a, st);
        },
        .each => |ea| {
            try expr(b, a, ea.source);
            try index(b, a, ea.body);
        },
        .match => |c| {
            try expr(b, a, c.subject);
            for (c.arms) |arm| try index(b, a, arm);
        },
    };
    if (reg.value) |e| try expr(b, a, e);
}

/// The node expression `e` is indexed by: none for a hold or a block,
/// whose value is indexed by its own.
fn nodeOfExpr(e: lir.Expr) Sexp {
    return switch (e) {
        .@"var" => |x| x.node,
        .leaf => |l| l,
        .op => |o| o.node,
        .hold, .block => .nil,
        .branch => |x| x.node,
        .choice => |x| x.node,
        .closure => |x| x.node,
        .coerce => |x| x.node,
    };
}

fn expr(b: *Body, a: std.mem.Allocator, id: lir.ExprId) Error!void {
    const e = b.f.exprs.items[id];
    const node = nodeOfExpr(e);
    if (b.leaves or node == .list) try b.exprs.put(a, node, id, true);
    switch (e) {
        .@"var", .leaf, .closure => {},
        .op => |o| for (o.args) |x| try expr(b, a, x),
        .hold => |h| try expr(b, a, h.value),
        .block => |r| try index(b, a, r),
        .branch => |x| {
            try expr(b, a, x.cond);
            try index(b, a, x.then);
            if (x.@"else") |r| try index(b, a, r);
        },
        .choice => |x| {
            try expr(b, a, x.subject);
            for (x.arms) |r| try index(b, a, r);
        },
        .coerce => |x| try expr(b, a, x.value),
    }
    if (e == .closure) for (e.closure.captures) |x| try expr(b, a, x);
}

/// The statements of block or body `body` as the regions of its lowered
/// body list them. A statement whose value the body yields comes last,
/// as `yields` says. A block with no region of statements is reported
/// as an internal error, and has none.
pub fn stmtsOf(self: *Checker, body: Sexp) Error!Stmts {
    const b = self.lir_body orelse return noStmts(self, body);
    const r = b.regions.get(body) orelse return noStmts(self, body);
    const reg = &b.f.regions.items[r];
    var out: std.ArrayList(Sexp) = .empty;
    const a = self.arena();
    try out.ensureTotalCapacity(a, reg.steps.items.len + 1);
    for (reg.steps.items) |s| switch (s) {
        .region => |sub| out.appendAssumeCapacity(b.f.regions.items[sub].node),
        else => return noStmts(self, body),
    };
    var yields = false;
    if (reg.value) |v| switch (b.f.exprs.items[v]) {
        .block => |sub| {
            out.appendAssumeCapacity(b.f.regions.items[sub].node);
            yields = true;
        },
        else => return noStmts(self, body),
    };
    return .{ .list = out.items, .yields = yields };
}

fn noStmts(self: *Checker, body: Sexp) Error!Stmts {
    if (self_check) {
        const at = diag.lineCol(self.source, self.sema.startOf(body));
        std.debug.panic("{s}:{d}:{d}: internal error: a `{s}` the ownership checker walks has no LIR statements", .{ self.sema.name, at.line, at.col, @tagName(body.kind() orelse .module) });
    }
    try notes.errAt(self, body, "internal error: this block has no lowered statements", .{});
    return .{ .list = &.{}, .yields = false };
}

/// The step of statement `stmt` that does what it says: its region's
/// last, after the parts it holds first; null for a statement with no
/// region of its own (a target of `q, r = f()`).
pub fn stepOf(self: *const Checker, stmt: Sexp) ?lir.Step {
    const steps = stepsOf(self, stmt);
    return if (steps.len > 0) steps[steps.len - 1] else null;
}

/// The steps of statement `stmt`'s region, in order.
pub fn stepsOf(self: *const Checker, stmt: Sexp) []const lir.Step {
    const b = self.lir_body orelse return &.{};
    const r = b.stmts.get(stmt) orelse return &.{};
    return b.f.regions.items[r].steps.items;
}

/// Statement `stmt`, whose value its body yields, as its region's value.
pub fn yieldOf(self: *const Checker, stmt: Sexp) Expr {
    const b = self.lir_body orelse return exprAt(self, stmt);
    const r = b.stmts.get(stmt) orelse return exprAt(self, stmt);
    return stepOperand(self, stmt, b.f.regions.items[r].value orelse return exprAt(self, stmt));
}

/// Statement operand `node` (the value an assignment stores, a jump
/// leaves with, or a drop takes) as step expression `id` holds it.
/// A self-checking build panics where the step's expression is not
/// the node's.
pub fn stepOperand(self: *const Checker, node: Sexp, id: lir.ExprId) Expr {
    if (self_check) {
        const n = nodeOf(self.lir_body.?, id);
        if (sema.decisionKeyOf(n) != sema.decisionKeyOf(node)) std.debug.panic("internal error: a lowered statement's operand is not its tree's (`{s}` for `{s}`)", .{ @tagName(n.kind() orelse .module), @tagName(node.kind() orelse .module) });
    }
    return .{ .node = node, .id = id };
}

pub const Stmts = struct { list: []const Sexp, yields: bool };

/// The binding a var of the lowered body declares at name `node`.
pub fn bindingAt(self: *const Checker, node: Sexp) ?SymbolId {
    if (!self.on_lir) return null;
    const b = self.lir_body orelse return null;
    return b.binds.get(sema.decisionKeyOf(node) orelse return null);
}

/// The binding name `node` reads, as the var its use reads in the
/// lowered body says; null for a node the body made no var read of.
pub fn symbolOf(self: *const Checker, node: Sexp) ?SymbolId {
    if (!self.on_lir) return null;
    const b = self.lir_body orelse return null;
    var id = exprAt(self, node).id orelse return null;
    while (true) switch (b.f.exprs.items[id]) {
        .coerce => |c| id = c.value,
        .hold => |h| id = h.value,
        .@"var" => |x| return switch (b.f.vars.items[x.v].name) {
            .binding => |s| s,
            .hidden => null,
        },
        else => return null,
    };
}

/// Whether the lowered body holds the value of `node` in a temporary
/// its statement drops; null for a node outside any lowered body.
pub fn holdsTemp(self: *const Checker, node: Sexp) ?bool {
    if (!self.on_lir) return null;
    const b = self.lir_body orelse return null;
    return b.temps.contains(sema.decisionKeyOf(node) orelse return false);
}

/// Note each use of a binding that `live.indexUses` notes from the
/// tree, from lowered body `f` and the closures it makes: each name a
/// var's read or a leaf reads, and each binding's declaring name, a use
/// in a `defer` body noted as deferred, and one in a `while` step at
/// the step's place (`notes.stepAt`).
pub fn indexUses(self: *Checker, f: *const lir.Func) Error!void {
    var u: Uses = .{ .c = self, .f = f };
    try u.region(f.body);
    // In source order, as the tree lists them: LIR evaluates an
    // assignment's value before its target.
    for (self.uses.all()) |e| std.mem.sort(u32, e.at.items, {}, std.sort.asc(u32));
}

const Uses = struct {
    c: *Checker,
    f: *const lir.Func,
    in_defer: bool = false,
    at: ?u32 = null,

    fn note(u: *Uses, sym: SymbolId, node: Sexp) Error!void {
        if (node != .src) return;
        try live.noteUse(u.c, sym, u.at orelse node.src.pos, u.in_defer);
    }

    fn region(u: *Uses, r: lir.RegionId) Error!void {
        const reg = &u.f.regions.items[r];
        const saved = u.in_defer;
        defer u.in_defer = saved;
        if (reg.node.isKind(.@"defer") or reg.node.isKind(.@"errdefer")) u.in_defer = true;
        // A pattern is not lowered: its names are read from the tree,
        // an alternative's among them, which declares no var.
        if (reg.kind == .arm) try live.indexUses(u.c, ir.Arm.pattern(reg.node), u.in_defer, u.at);
        for (reg.decls.items) |x| {
            const v = u.f.vars.items[x];
            switch (v.name) {
                .binding => |sym| try u.declared(sym, v.node),
                .hidden => {},
            }
        }
        for (reg.steps.items) |s| switch (s) {
            .bind => |x| try u.expr(x.value),
            .store => |x| {
                try u.expr(x.target);
                try u.expr(x.value);
            },
            .eval => |e| try u.expr(e),
            .drop => |x| switch (u.f.vars.items[x.v].name) {
                .binding => |sym| try u.note(sym, x.node),
                .hidden => {},
            },
            .jump => |j| if (j.value) |e| try u.expr(e),
            .region => |sub| try u.region(sub),
            .@"if" => |i| {
                try u.expr(i.cond);
                try u.region(i.then);
                if (i.@"else") |e| try u.region(e);
            },
            .loop => |lp| {
                try u.expr(lp.cond);
                try u.region(lp.body);
                if (lp.step) |st| {
                    const saved_at = u.at;
                    defer u.at = saved_at;
                    if (u.at == null) u.at = notes.stepAt(u.c, lp.node);
                    try u.region(st);
                }
            },
            .each => |ea| {
                try u.expr(ea.source);
                try u.region(ea.body);
            },
            .match => |c| {
                try u.expr(c.subject);
                for (c.arms) |arm| try u.region(arm);
            },
        };
        if (reg.value) |e| try u.expr(e);
    }

    /// A binding's declaring name, and, for a capture, the binding it
    /// captures, whose use it is where the closure is made.
    fn declared(u: *Uses, sym: SymbolId, node: Sexp) Error!void {
        try u.note(sym, node);
        const d = u.c.sema.symbols.items[sym];
        if (d.kind == .capture and node == .src and d.decl_pos == node.src.pos and d.origin != sema.symbol_invalid) try u.note(d.origin, node);
    }

    fn expr(u: *Uses, id: lir.ExprId) Error!void {
        switch (u.f.exprs.items[id]) {
            .@"var" => |x| switch (u.f.vars.items[x.v].name) {
                .binding => |sym| try u.note(sym, x.node),
                .hidden => {},
            },
            .leaf => |l| if (u.c.sema.symbolOf(l)) |sym| try u.note(sym, l),
            .op => |o| for (o.args) |a| try u.expr(a),
            .hold => |h| try u.expr(h.value),
            .block => |r| try u.region(r),
            .branch => |x| {
                try u.expr(x.cond);
                try u.region(x.then);
                if (x.@"else") |r| try u.region(r);
            },
            .choice => |x| {
                try u.expr(x.subject);
                for (x.arms) |r| try u.region(r);
            },
            .closure => |x| {
                for (x.captures) |c| try u.expr(c);
                const m = &(u.c.sema.lowered orelse return);
                const g = m.owners[x.owner].func orelse return;
                var inner: Uses = .{ .c = u.c, .f = g, .in_defer = u.in_defer, .at = u.at };
                try inner.region(g.body);
            },
            .coerce => |x| try u.expr(x.value),
        }
    }
};

/// Index the uses of lowered body `f` (`indexUses`) in place of those
/// the tree gave (`live.indexUses`), and report, at `at`, an internal
/// error where the two differ for a binding.
pub fn reindexUses(self: *Checker, f: *const lir.Func, at: Sexp) Error!void {
    var tree_uses = self.uses;
    var tree_deferred = self.defer_used;
    self.uses = .{};
    self.defer_used = .empty;
    defer {
        tree_uses.deinit(self.gpa);
        tree_deferred.deinit(self.gpa);
    }
    try indexUses(self, f);
    if (usesDiffer(self, &tree_uses, &tree_deferred)) |sym|
        try notes.errAt(self, at, "internal error: the uses of `{s}` in this body's LIR are not those of its tree", .{self.sema.symbols.items[sym].name});
}

/// The binding symbols whose uses `live.indexUses` and `indexUses` note
/// differently, for the shadow's report: the first, or null. Only a
/// binding that may hold a loan is compared: liveness matters only for
/// a var holding one, and a compile-time value named in a type, which
/// LIR does not lower, holds none.
pub fn usesDiffer(c: *const Checker, tree_uses: *const state.Uses, tree_deferred: *const std.AutoHashMapUnmanaged(SymbolId, void)) ?SymbolId {
    const binding = struct {
        fn is(ch: *const Checker, sym: SymbolId) bool {
            const d = ch.sema.symbols.items[sym];
            return switch (d.kind) {
                .param, .local, .capture => types.mayCarryLoan(ch, types.known(ch, d.ty)),
                else => false,
            };
        }
    };
    inline for (.{ .{ tree_uses, &c.uses }, .{ &c.uses, tree_uses } }) |pair| {
        for (pair[0].all()) |e| {
            if (!binding.is(c, e.sym)) continue;
            const other = pair[1].get(e.sym) orelse return e.sym;
            for (e.at.items) |p| if (std.mem.findScalar(u32, other.items, p) == null) return e.sym;
        }
    }
    var it = tree_deferred.keyIterator();
    while (it.next()) |k| if (binding.is(c, k.*) and !c.defer_used.contains(k.*)) return k.*;
    var it2 = c.defer_used.keyIterator();
    while (it2.next()) |k| if (binding.is(c, k.*) and !tree_deferred.contains(k.*)) return k.*;
    return null;
}

/// Panic, in a self-checking build, where the walk of each body's LIR
/// (`shadow`) reports other diagnostics than the walk of its tree
/// (`tree`), naming the first that differs.
pub fn compare(name: []const u8, source: []const u8, tree: []const diag.Diagnostic, shadow: []const diag.Diagnostic) void {
    const n = @min(tree.len, shadow.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = tree[i];
        const b = shadow[i];
        if (a.severity != b.severity or a.pos != b.pos or a.end != b.end or a.module != b.module or !std.mem.eql(u8, a.message, b.message)) break;
    }
    if (i == tree.len and i == shadow.len) return;
    const t: ?diag.Diagnostic = if (i < tree.len) tree[i] else null;
    const s: ?diag.Diagnostic = if (i < shadow.len) shadow[i] else null;
    const at = diag.lineCol(source, if (t) |d| d.pos else s.?.pos);
    std.debug.panic("{s}:{d}:{d}: internal error: ownership on LIR disagrees with the tree walk ({d} and {d} diagnostics): the tree says \"{s}\", the LIR \"{s}\"", .{
        name,                                   at.line, at.col, tree.len, shadow.len,
        if (t) |d| d.message else "(nothing)", if (s) |d| d.message else "(nothing)",
    });
}
