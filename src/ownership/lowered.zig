//! The checker's view of each body's LIR (`src/lir.zig`). Every walk
//! reads the statements of a body or block from its regions
//! (`stmtsOf`), the operands of a statement from its step (`stepOf`,
//! `stepOperand`), and the operands of an expression from its LIR
//! operation (`Expr`, `operand`); an `if`, a loop, or a `match` is its
//! LIR step (`controlOf`), and each of its parts the region made for it
//! (`partExpr`). The uses liveness reads are the LIR's (`indexUses`).
//! The checkers' lowering lowers every body the checker walks
//! (`lower.Options.checked`).

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const lir = @import("../lir.zig");
const lower = @import("../lower.zig");
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
/// Steps `start..end` of region `r`.
pub const Steps = struct { r: lir.RegionId, start: u32, end: u32 };

pub const Body = struct {
    f: *const lir.Func,
    /// The region made for each block: the body's by the function's
    /// block, a `defer`'s by its body, a `catch`'s by its handler.
    regions: NodeTable = .{},
    /// The region of each statement, which holds its temporaries, and of
    /// each jump the region that ends with it.
    stmts: NodeTable = .{},
    /// The calls and array literals that evaluate parts first, in a
    /// region of kind `call`, by their nodes' keys.
    calls: sema.FastMap(u64, void) = .empty,
    /// The steps of each target of `q, r = f()`, by the target's node:
    /// a stretch of the region of the destructuring's targets.
    targets: sema.FastMap(u64, Steps) = .empty,
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
    /// For a construct that is no expression (an `if` in a branch), the
    /// region whose steps run it.
    r: ?lir.RegionId = null,
};

/// The value hidden var `v` holds, where a region evaluates it first.
fn hoistedOf(b: *const Body, v: lir.VarId) ?lir.ExprId {
    if (v >= b.hoisted.len or b.hoisted[v] == NodeTable.none) return null;
    return b.hoisted[v];
}

/// Expression `id` under the coercions and holds of its node, and the
/// var that holds it first, where a region evaluates it first.
fn under(b: *const Body, start: lir.ExprId) lir.ExprId {
    var id = start;
    while (true) switch (b.f.exprs.items[id]) {
        .coerce => |c| id = c.value,
        .hold => |h| id = h.value,
        .@"var" => |x| id = hoistedOf(b, x.v) orelse return id,
        else => return id,
    };
}

/// Node `node`, which the walk reaches with no LIR expression made for
/// it: the checkers' lowering lowers every body the checker walks, and
/// each part of it, so a self-checking build panics. Its operands are
/// then read from the tree.
pub fn uncovered(self: *const Checker, node: Sexp) Expr {
    if (self_check) {
        const at = diag.lineCol(self.source, self.sema.startOf(node));
        std.debug.panic("{s}:{d}:{d}: internal error: the ownership checker walks a `{s}` with no LIR", .{ self.sema.name, at.line, at.col, if (node == .list) @tagName(node.kind() orelse .module) else "leaf" });
    }
    return .{ .node = node };
}

/// Statement `stmt` as the walk reaches it: with the expression its
/// region evaluates last, for a statement that is an expression, or
/// with none, for one whose step says what it does (`stepOf`). A
/// statement with no region of its own is looked up (`uncovered`).
pub fn stmtExpr(self: *const Checker, stmt: Sexp) Expr {
    const b = self.lir_body orelse return .{ .node = stmt };
    // A block is walked by its region, by node.
    if (stmt.isKind(.block)) return .{ .node = stmt };
    const r = b.stmts.get(stmt) orelse return uncovered(self, stmt);
    const reg = &b.f.regions.items[r];
    const key = sema.decisionKeyOf(stmt);
    const steps = reg.steps.items;
    // A statement whose value its body yields is its region's value.
    const out: Expr = if (reg.value != null and sema.decisionKeyOf(nodeOf(b, reg.value.?)) == key)
        .{ .node = stmt, .id = reg.value.? }
    else if (steps.len == 0) .{ .node = stmt } else switch (steps[steps.len - 1]) {
        .eval => |e| if (sema.decisionKeyOf(nodeOf(b, e)) == key) .{ .node = stmt, .id = e } else .{ .node = stmt },
        else => .{ .node = stmt },
    };
    return out;
}

/// The control step of construct `e` (an `if`, `while`, `for`, or
/// `match`): where `e` is a value, the branch or choice its expression
/// is; else the last step of its statement's region, or of the region
/// that step runs, whose node is `e`'s. Null where neither is found.
pub fn controlOf(self: *const Checker, e: Expr) ?Control {
    const b = self.lir_body orelse return null;
    const key = sema.decisionKeyOf(e.node) orelse return null;
    if (e.id) |start| {
        var id = start;
        while (true) switch (b.f.exprs.items[under(b, id)]) {
            // A region that runs the construct (a value `loop`).
            .block => |r| id = b.f.regions.items[r].value orelse return controlFrom(b, r, key),
            .branch => |x| return if (sema.decisionKeyOf(x.node) == key) .{ .@"if" = x } else null,
            .choice => |x| return if (sema.decisionKeyOf(x.node) == key) .{ .match = x } else null,
            else => return null,
        };
    }
    return controlFrom(b, e.r orelse b.stmts.get(e.node) orelse return null, key);
}

/// The control step with node key `key` that region `start` ends with,
/// or the regions it ends with do.
fn controlFrom(b: *const Body, start: lir.RegionId, key: u64) ?Control {
    var r = start;
    while (true) {
        const steps = b.f.regions.items[r].steps.items;
        if (steps.len == 0) return null;
        const c: Control = switch (steps[steps.len - 1]) {
            .region => |sub| {
                r = sub;
                continue;
            },
            .@"if" => |x| .{ .@"if" = x },
            .match => |x| .{ .match = x },
            .loop => |x| .{ .loop = .{ .node = x.node, .cond = x.cond, .body = x.body, .step = x.step } },
            .each => |x| .{ .each = .{ .node = x.node, .source = x.source, .body = x.body } },
            else => return null,
        };
        return if (sema.decisionKeyOf(c.node()) == key) c else null;
    }
}

pub const Control = union(enum) {
    @"if": lir.Expr.If,
    match: lir.Expr.Choice,
    loop: struct { node: Sexp, cond: lir.ExprId, body: lir.RegionId, step: ?lir.RegionId },
    each: struct { node: Sexp, source: lir.ExprId, body: lir.RegionId },

    fn node(c: Control) Sexp {
        return switch (c) {
            inline else => |x| x.node,
        };
    }
};

/// Guard `guard` of arm `i` of the match `c` controls, as the arm's
/// region tests it before its body.
pub fn guardOf(self: *const Checker, c: ?Control, i: usize, guard: Sexp) Expr {
    const b = self.lir_body orelse return uncovered(self, guard);
    const m = c orelse return uncovered(self, guard);
    if (m != .match or i >= m.match.arms.len) return uncovered(self, guard);
    const steps = b.f.regions.items[m.match.arms[i]].steps.items;
    if (steps.len == 0 or steps[steps.len - 1] != .@"if") return uncovered(self, guard);
    return exprFor(self, guard, steps[steps.len - 1].@"if".cond);
}

/// The value capture `i` of closure `e` takes, `value` in the tree.
pub fn captureOf(self: *const Checker, e: Expr, i: usize, value: Sexp) Expr {
    // A capture of a name takes no value.
    if (value == .nil) return .{ .node = .nil };
    const b = self.lir_body orelse return uncovered(self, value);
    return switch (b.f.exprs.items[under(b, e.id orelse return uncovered(self, value))]) {
        .closure => |c| if (i < c.captures.len) exprFor(self, value, c.captures[i]) else uncovered(self, value),
        else => uncovered(self, value),
    };
}

/// The subject of the `match` of `as_match` condition part `e`, `scrut`
/// in the tree, as the match LIR made for the part tests it.
pub fn asMatchSubject(self: *const Checker, e: Expr, match: Sexp, scrut: Sexp) Expr {
    const o = opOf(self, e) orelse return uncovered(self, scrut);
    if (o.args.len == 0) return uncovered(self, scrut);
    const c = controlOf(self, .{ .node = match, .id = o.args[0] }) orelse return uncovered(self, scrut);
    return if (c == .match) exprFor(self, scrut, c.match.subject) else uncovered(self, scrut);
}

/// The value a header holds for its construct, `base` in the tree: the
/// root of the path that subject `e` reads.
pub fn baseOf(self: *const Checker, e: Expr, base: Sexp) Expr {
    var at = e;
    const key = sema.decisionKeyOf(base);
    while (sema.decisionKeyOf(at.node) != key) {
        if (!(at.node.isKind(.member) or at.node.isKind(.index) or at.node.isKind(.read) or at.node.isKind(.write))) return uncovered(self, base);
        at = operand(self, at, 0);
    }
    return at;
}

/// Construct `inner` of labeled construct `e` (what a label names),
/// found from the statement's region, or, for a value, from the region
/// its expression runs.
pub fn within(self: *const Checker, e: Expr, inner: Sexp) Expr {
    const b = self.lir_body orelse return uncovered(self, inner);
    if (b.stmts.get(e.node)) |r| return .{ .node = inner, .r = r };
    return .{ .node = inner, .id = e.id };
}

/// The region operand `i` of operation `e` is, where it is one.
pub fn argRegion(self: *const Checker, e: Expr, i: usize) ?lir.RegionId {
    const o = opOf(self, e) orelse return null;
    if (i >= o.args.len) return null;
    return switch (self.lir_body.?.f.exprs.items[o.args[i]]) {
        .block => |r| r,
        else => null,
    };
}

/// Node `node` as LIR expression `id` holds it, where `id` is made for
/// it; else as the walk looks it up (`uncovered`).
pub fn exprFor(self: *const Checker, node: Sexp, id: lir.ExprId) Expr {
    const b = self.lir_body.?;
    if (sema.decisionKeyOf(nodeOf(b, id)) != sema.decisionKeyOf(node)) return uncovered(self, node);
    return .{ .node = node, .id = id };
}

/// Part `node` of a construct (a branch, an arm's body, a loop's body)
/// as the walk reaches it from region `r`, which LIR made for it: a
/// block is walked by its region, by node; an expression is the value
/// the region yields.
pub fn partExpr(self: *const Checker, node: Sexp, r: lir.RegionId) Expr {
    const b = self.lir_body.?;
    const reg = &b.f.regions.items[r];
    const key = sema.decisionKeyOf(node);
    const out: Expr = if (node.isKind(.block))
        .{ .node = node }
    else if (reg.value) |v| (if (sema.decisionKeyOf(nodeOf(b, v)) == key) .{ .node = node, .id = v } else return uncovered(self, node)) else blk: {
        // A statement the region evaluates (`stmt if cond`), or a
        // construct it runs, an `else if`'s `if`.
        const steps = reg.steps.items;
        if (steps.len > 0 and steps[steps.len - 1] == .eval and sema.decisionKeyOf(nodeOf(b, steps[steps.len - 1].eval)) == key) break :blk .{ .node = node, .id = steps[steps.len - 1].eval };
        if (controlFrom(b, r, key orelse return uncovered(self, node)) != null) break :blk .{ .node = node, .r = r };
        return uncovered(self, node);
    };
    return out;
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

/// The record lowering made of call `call` (`lower.checkedCall`): how
/// its callee is written, how it takes its self, and its flags.
pub fn callOf(self: *const Checker, call: Expr) lir.Call {
    if (opOf(self, call)) |o| if (o.kind == .call) return self.lir_body.?.f.calls.items[o.aux];
    const node = uncovered(self, call.node).node;
    var rec = lower.checkedCall(self.sema, node);
    rec.wrap.held = lower.holdsParts(self.sema, node);
    return rec;
}

/// The view operand `e` is made where a view is expected with no sigil
/// (`sema.View.implicit`): in a lowered body, the `view` coercion
/// lowering made of its node, else the typing facts'.
pub fn implicitView(self: *const Checker, e: Expr) ?sema.View {
    const out = blk: {
        const b = self.lir_body orelse break :blk self.sema.viewOf(e.node);
        var id = e.id orelse break :blk self.sema.viewOf(e.node);
        while (true) switch (b.f.exprs.items[id]) {
            .coerce => |c| switch (c.how.*) {
                .view => |v| break :blk v,
                else => id = c.value,
            },
            .hold => |h| id = h.value,
            .@"var" => |x| id = hoistedOf(b, x.v) orelse break :blk null,
            else => break :blk null,
        };
    };
    const view = if (out) |v| (if (v.implicit) v else null) else null;
    if (self_check) {
        const want = self.sema.viewOf(e.node);
        const same = if (want) |w| (if (w.implicit) view != null and view.?.ty == w.ty and view.?.fn_ty == w.fn_ty and std.mem.eql(sema.ViewStep, view.?.steps(), w.steps()) else view == null) else view == null;
        if (!same) {
            const at = diag.lineCol(self.source, self.sema.startOf(e.node));
            std.debug.panic("{s}:{d}:{d}: internal error: lir: an implicit view lowering made of an operand that the typing facts do not record, or the other way", .{ self.sema.name, at.line, at.col });
        }
    }
    return view;
}

/// Operand `i` of `e`: the LIR's, where `e` is an operation of a
/// lowered body, else the tree's child `i`.
pub fn operand(self: *const Checker, e: Expr, i: usize) Expr {
    const o = opOf(self, e) orelse return uncovered(self, rig.children(e.node)[i]);
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
    if (e.id == null) return null;
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
    out.* = .{ .f = f };
    // The ids of the body's list nodes, which the parser numbers in
    // the order it makes them, mostly lie in one stretch: an array over
    // it finds each without hashing.
    var regions: u32 = 0;
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
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
    if (regions > 0 and hi - lo < 4 * regions + 256) {
        const n = hi - lo + 1;
        const all = try a.alloc(u32, 2 * n);
        @memset(all, NodeTable.none);
        out.stmts.dense, out.regions.dense = .{ all[0..n], all[n..] };
        out.stmts.lo, out.regions.lo = .{ lo, lo };
    } else try out.stmts.map.ensureTotalCapacity(a, regions);
    try out.regions.put(a, body, f.body, false);
    // A region is made before the regions it holds, so the regions'
    // order is the outermost first.
    for (f.regions.items, 0..) |*reg, i| try indexRegion(out, a, reg, @intCast(i));
    return out;
}

/// Record region `r` in the tables the walk finds it by.
fn indexRegion(b: *Body, a: std.mem.Allocator, reg: *const lir.Region, r: lir.RegionId) Error!void {
    if (sema.decisionKeyOf(reg.node)) |key| switch (reg.kind) {
        .block => {
            // A `defer`'s region is its body's, a `catch`'s its handler's.
            const body = switch (reg.node.kind() orelse .module) {
                .@"defer", .@"errdefer" => ir.get(reg.node, .body),
                .@"catch" => ir.Catch.handler(reg.node),
                else => reg.node,
            };
            // A `defer` of one statement runs it as the region's.
            if (reg.node.isKind(.@"defer") or reg.node.isKind(.@"errdefer")) if (!body.isKind(.block) and sema.decisionKeyOf(body) != null) return b.stmts.put(a, body, r, true);
            try b.regions.put(a, if (sema.decisionKeyOf(body) != null) body else reg.node, r, true);
        },
        .stmt => try b.stmts.put(a, reg.node, r, false),
        .call => try b.calls.put(a, key, {}),
        // A name `if f() as a, b` takes a result into is bound by its
        // region's step. Each target of a destructuring has a stretch
        // of its targets' region, ending with the step that stores,
        // binds, or discards its result, after those that hold its
        // parts first.
        .value => if (reg.node.isKind(.set)) try b.stmts.put(a, reg.node, r, true) else if (reg.node.isKind(.destructure)) {
            var start: u32 = 0;
            var i: u32 = 0;
            for (ir.Destructure.targets(reg.node).items()) |t| {
                if (!t.isKind(.set)) continue;
                while (i < reg.steps.items.len and isHold(b.f, reg.steps.items[i])) i += 1;
                if (i == reg.steps.items.len) break;
                i += 1;
                try b.targets.put(a, sema.decisionKeyOf(t) orelse continue, .{ .r = r, .start = start, .end = i });
                start = i;
            }
        },
        else => {},
    };
    // A jump that is no statement of its own (a branch, an arm's body,
    // the right of `??`) is found by the region that ends with it.
    const steps = reg.steps.items;
    if (reg.kind != .stmt and steps.len > 0 and steps[steps.len - 1] == .jump) try b.stmts.put(a, steps[steps.len - 1].jump.node, r, true);
}

/// Whether step `s` binds a hidden var, holding a part first.
fn isHold(f: *const lir.Func, s: lir.Step) bool {
    return s == .bind and f.vars.items[s.bind.v].name == .hidden;
}

/// The module's compile-time body is walked: free its tables and its
/// LIR.
pub fn dropConstants(self: *Checker) void {
    _ = self.const_arena_state.reset(.free_all);
    if (self.interner.lowered) |*m| m.dropConstants();
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
    const r = b.stmts.get(stmt) orelse {
        const t = b.targets.get(sema.decisionKeyOf(stmt) orelse return &.{}) orelse return &.{};
        return b.f.regions.items[t.r].steps.items[t.start..t.end];
    };
    return b.f.regions.items[r].steps.items;
}

/// The value statement `stmt`'s step takes, `node` in the tree: what
/// it stores, binds, evaluates, or leaves with.
pub fn stepValue(self: *const Checker, stmt: Sexp, node: Sexp) Expr {
    if (node == .nil) return .{ .node = .nil };
    if (stepOf(self, stmt)) |step| switch (step) {
        .store => |x| return stepOperand(self, node, x.value),
        .bind => |x| return stepOperand(self, node, x.value),
        .eval => |x| return stepOperand(self, node, x),
        .jump => |j| if (j.value) |id| return stepOperand(self, node, id),
        else => {},
    };
    return uncovered(self, node);
}

/// Statement `stmt`, whose value its body yields, as its region's value.
pub fn yieldOf(self: *const Checker, stmt: Sexp) Expr {
    const b = self.lir_body orelse return uncovered(self, stmt);
    const r = b.stmts.get(stmt) orelse return uncovered(self, stmt);
    return stepOperand(self, stmt, b.f.regions.items[r].value orelse return uncovered(self, stmt));
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

/// Note each use of a binding in lowered body `f` and the closures it
/// makes: each name a var's read or a leaf reads, and each binding's
/// declaring name, a use
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
