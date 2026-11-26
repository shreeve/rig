//! The checker's view of each body's LIR (`src/lir.zig`). Every walk
//! reads the statements of a body or block from its regions
//! (`stmtsOf`), the operands of a statement from its steps (`stepsIn`,
//! `stepValue`), and the operands of an expression from its LIR
//! operation (`Expr`, `operand`); an `if`, a loop, or a `match` is its
//! LIR step (`controlOf`), and each of its parts the region made for it
//! (`exprIn`). The uses liveness reads are the LIR's (`indexUses`).
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

/// No value: an empty slot of `Body.hoisted` or `Body.made`.
const none = std.math.maxInt(u32);

/// A body lowered, and what the walk records of it.
pub const Body = struct {
    f: *const lir.Func,
    /// The calls and array literals that evaluate parts first, in a
    /// region of kind `call`, by their nodes' keys.
    calls: sema.FastMap(u64, void) = .empty,
    /// The value each hidden var a region evaluates first holds (a part
    /// a call or an assignment holds), by the var: the operand that
    /// reads the var is walked as that value, where it stands.
    /// By var id; empty where no region holds a part first.
    hoisted: []lir.ExprId = &.{},
    /// The checker var the walk made last for each hidden var, by LIR
    /// var (`noteMade`); empty until it makes one.
    made: []state.VarId = &.{},
};

/// An expression the walk reaches: its tree node, and, in a lowered
/// body, the LIR expression made for it (`id`), whose operands the
/// walk takes as the operands of the node.
pub const Expr = struct {
    node: Sexp,
    id: ?lir.ExprId = null,
    /// The region whose steps run it: a statement's own, a block's, or,
    /// for a construct that is no expression (an `if` in a branch), the
    /// region that ends with it.
    r: ?lir.RegionId = null,
};

/// The value hidden var `v` holds, where a region evaluates it first.
fn hoistedOf(b: *const Body, v: lir.VarId) ?lir.ExprId {
    if (v >= b.hoisted.len or b.hoisted[v] == none) return null;
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

/// The hidden var of `kind` lowering made for `node` in the body being
/// walked.
pub fn hiddenOf(self: *const Checker, node: Sexp, kind: lir.StorageKind) ?lir.VarId {
    const b = self.lir_body orelse return null;
    const vars = b.f.vars.items;
    if (self.sema.lowered) |m| if (m.varOf(node, kind)) |v| {
        const at = @intFromPtr(v);
        const lo = @intFromPtr(vars.ptr);
        if (at >= lo and at < lo + vars.len * @sizeOf(lir.Var)) return @intCast((at - lo) / @sizeOf(lir.Var));
    };
    // The module's compile-time body is in no index of the module's.
    if (!b.f.root.isKind(.module)) return null;
    const key = sema.decisionKeyOf(node) orelse return null;
    for (vars, 0..) |v, i| switch (v.name) {
        .hidden => |k| if (k == kind and sema.decisionKeyOf(v.node) == key) return @intCast(i),
        .binding => {},
    };
    return null;
}

/// Record checker var `id` as the one the walk made for hidden var `lv`.
pub fn noteMade(self: *Checker, lv: ?lir.VarId, id: state.VarId) Error!void {
    const v = lv orelse return;
    const b = self.lir_body orelse return;
    if (b.made.len == 0) {
        b.made = try bodyArena(self, b).alloc(state.VarId, b.f.vars.items.len);
        @memset(b.made, none);
    }
    b.made[v] = id;
}

/// The arena that lives while body `b`'s walk does (`enter`).
fn bodyArena(self: *Checker, b: *const Body) std.mem.Allocator {
    return if (b.f.root.isKind(.module)) self.const_arena_state.allocator() else self.fn_arena_state.allocator();
}

/// The checker var the walk made last for hidden var `lv` and has not
/// ended (`endsOf`), if any.
pub fn madeOf(self: *const Checker, lv: lir.VarId) ?state.VarId {
    const b = self.lir_body orelse return null;
    if (b.made.len == 0) return null;
    const id = b.made[lv];
    return if (id == none or id >= self.vars.items.len) null else id;
}

/// The region of `kind` expression `e` is, under its coercions, holds,
/// and view sigils, whose node is `e`'s: a header's that ends its
/// temporaries, or the one a call holds its parts in.
pub fn regionOf(self: *const Checker, e: Expr, kind: lir.Region.Kind) ?lir.RegionId {
    const b = self.lir_body orelse return null;
    var key = sema.decisionKeyOf(e.node) orelse return null;
    var id = e.id orelse return null;
    while (true) switch (b.f.exprs.items[id]) {
        .coerce => |c| id = c.value,
        .op => |o| {
            if (o.kind != .view or o.args.len != 1) return null;
            key = sema.decisionKeyOf(ir.get(o.node, .operand)) orelse return null;
            id = o.args[0];
        },
        .hold => |h| id = h.value,
        .@"var" => |x| id = hoistedOf(b, x.v) orelse return null,
        .block => |r| {
            const reg = &b.f.regions.items[r];
            if (sema.decisionKeyOf(reg.node) != key) return null;
            if (reg.kind == kind or (kind == .call and reg.kind == .value)) return r;
            id = reg.value orelse return null;
        },
        else => return null,
    };
}

/// The region of statement `e`, which holds its temporaries: its own,
/// or, for a condition walked as a statement, its header's.
pub fn stmtRegion(self: *const Checker, e: Expr) ?lir.RegionId {
    const b = self.lir_body orelse return null;
    if (e.r) |r| {
        const reg = &b.f.regions.items[r];
        if (reg.kind == .stmt and sema.decisionKeyOf(reg.node) == sema.decisionKeyOf(e.node)) return r;
    }
    return regionOf(self, e, .header);
}

/// The checker vars made since var `mark` for the hidden vars region `r`
/// declares, newest first, that are still held: those a call holds
/// (`call`), or a statement's. Leaving `r` ends them, so none is made
/// for its LIR var any more (`madeOf`).
pub fn endsOf(self: *Checker, r: ?lir.RegionId, mark: state.VarId, call: bool) Error![]const state.VarId {
    const b = self.lir_body orelse return &.{};
    if (b.made.len == 0) return &.{};
    const decls = b.f.regions.items[r orelse return &.{}].decls.items;
    var n: usize = 0;
    for (decls) |lv| n += @intFromBool(endsHere(self, b, lv, mark, call) != null);
    if (n == 0) return &.{};
    const out = try bodyArena(self, b).alloc(state.VarId, n);
    var i = decls.len;
    while (i > 0) {
        i -= 1;
        if (endsHere(self, b, decls[i], mark, call)) |id| {
            n -= 1;
            out[out.len - 1 - n] = id;
            b.made[decls[i]] = none;
        }
    }
    return out;
}

/// The checker var made since `mark` for hidden var `lv` that is still
/// held: by a call (`call`), or not.
fn endsHere(self: *const Checker, b: *const Body, lv: lir.VarId, mark: state.VarId, call: bool) ?state.VarId {
    const id = b.made[lv];
    if (id == none or id < mark or id >= self.vars.items.len) return null;
    const v = &self.vars.items[id];
    if (v.kind != .hidden or v.call_held != call or v.decl != notes.startOf(self, b.f.vars.items[lv].node)) return null;
    return id;
}

/// The checker vars that end where header `e` ends (`endsOf`): its
/// header region's, or, for a range, each bound's, the last one's first.
pub fn headerEnds(self: *Checker, e: Expr, mark: state.VarId) Error![]const state.VarId {
    if (regionOf(self, e, .header)) |r| return endsOf(self, r, mark, false);
    const b = self.lir_body orelse return &.{};
    const o = switch (b.f.exprs.items[e.id orelse return &.{}]) {
        .op => |o| o,
        else => return &.{},
    };
    if (!o.node.isKind(.@"..")) return &.{};
    var out: std.ArrayList(state.VarId) = .empty;
    var i = o.args.len;
    while (i > 0) {
        i -= 1;
        switch (b.f.exprs.items[o.args[i]]) {
            .block => |r| if (b.f.regions.items[r].kind == .header) try out.appendSlice(bodyArena(self, b), try endsOf(self, r, mark, false)),
            else => {},
        }
    }
    return out.items;
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

/// Statement region `r` as the walk reaches it (`exprIn`).
pub fn stmtAt(self: *const Checker, r: lir.RegionId) Expr {
    return exprIn(self, self.lir_body.?.f.regions.items[r].node, r);
}

/// Node `node` as region `r`, which LIR made for it, runs it (a
/// statement, a branch, an arm's or a loop's body): with the expression
/// `r` yields, or evaluates last, where that is `node`'s; else with
/// none, for a statement whose steps say what it does (`stepsIn`), a
/// block, or a construct `r` runs (`controlOf`).
pub fn exprIn(self: *const Checker, node: Sexp, r: lir.RegionId) Expr {
    const b = self.lir_body.?;
    const reg = &b.f.regions.items[r];
    const key = sema.decisionKeyOf(node);
    const steps = reg.steps.items;
    if (reg.value) |v| if (sema.decisionKeyOf(nodeOf(b, v)) == key) return .{ .node = node, .id = v, .r = r };
    if (steps.len > 0 and steps[steps.len - 1] == .eval and sema.decisionKeyOf(nodeOf(b, steps[steps.len - 1].eval)) == key) return .{ .node = node, .id = steps[steps.len - 1].eval, .r = r };
    return .{ .node = node, .r = r };
}

/// The statements of body or block region `r`: its steps' regions,
/// then its value's, a statement whose value it yields.
pub const Stmts = struct {
    b: *const Body,
    r: lir.RegionId,

    pub fn len(s: Stmts) usize {
        const reg = &s.b.f.regions.items[s.r];
        return reg.steps.items.len + @intFromBool(reg.value != null);
    }

    /// Whether statement `i` is the one whose value the region yields.
    pub fn yields(s: Stmts, i: usize) bool {
        return i == s.b.f.regions.items[s.r].steps.items.len;
    }

    pub fn at(s: Stmts, i: usize) lir.RegionId {
        const reg = &s.b.f.regions.items[s.r];
        if (i < reg.steps.items.len) return reg.steps.items[i].region;
        return s.b.f.exprs.items[reg.value.?].block;
    }

    pub fn node(s: Stmts, i: usize) Sexp {
        return s.b.f.regions.items[s.at(i)].node;
    }
};

/// The statements of body or block region `r`.
pub fn stmtsOf(self: *const Checker, r: lir.RegionId) Stmts {
    return .{ .b = self.lir_body.?, .r = r };
}

/// The block region block `e` is walked by: the region its walk is on,
/// or, for a statement, the one its region runs; else the region its
/// expression is, or the one that one yields, whose node is `e`'s.
pub fn blockOf(self: *const Checker, e: Expr) ?lir.RegionId {
    const b = self.lir_body orelse return null;
    const key = sema.decisionKeyOf(e.node);
    var r = e.r orelse switch (b.f.exprs.items[under(b, e.id orelse return null)]) {
        .block => |r| r,
        else => return null,
    };
    while (true) {
        const reg = &b.f.regions.items[r];
        if (reg.kind == .block and (r == e.r or sema.decisionKeyOf(reg.node) == key)) return r;
        const steps = reg.steps.items;
        if (steps.len > 0 and steps[steps.len - 1] == .region) {
            r = steps[steps.len - 1].region;
        } else switch (b.f.exprs.items[reg.value orelse return null]) {
            .block => |sub| r = sub,
            else => return null,
        }
    }
}

/// Statement `node`, which block region `b` runs alone (a `defer`'s
/// body, a loop's step, a `match` arm's body): a block is walked by
/// `b`, any other statement is `b`'s one.
pub fn bodyStmt(self: *const Checker, node: Sexp, b: lir.RegionId) Expr {
    if (node.isKind(.block)) return .{ .node = node, .r = b };
    const st = stmtsOf(self, b);
    if (st.len() != 1) return uncovered(self, node);
    return stmtAt(self, st.at(0));
}

/// The body of arm `i` of the match `c` controls, `body` in the tree.
pub fn armBody(self: *const Checker, c: ?Control, i: usize, body: Sexp) Expr {
    const m = c orelse return uncovered(self, body);
    if (m != .match or i >= m.match.arms.len) return uncovered(self, body);
    const steps = self.lir_body.?.f.regions.items[m.match.arms[i]].steps.items;
    if (steps.len == 0) return uncovered(self, body);
    return bodyStmt(self, body, switch (steps[steps.len - 1]) {
        .region => |r| r,
        .@"if" => |x| x.then,
        else => return uncovered(self, body),
    });
}

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
    return controlFrom(b, e.r orelse return null, key);
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

/// Construct `inner` of labeled construct `e` (what a label names): a
/// statement of its own, its region the last step of `e`'s; else run
/// by `e`'s region, or, for a value, by the region its expression runs.
pub fn within(self: *const Checker, e: Expr, inner: Sexp) Expr {
    const b = self.lir_body orelse return uncovered(self, inner);
    const r = e.r orelse return .{ .node = inner, .id = e.id };
    const steps = b.f.regions.items[r].steps.items;
    if (steps.len > 0 and steps[steps.len - 1] == .region) {
        const sub = steps[steps.len - 1].region;
        if (b.f.regions.items[sub].kind == .stmt and sema.decisionKeyOf(b.f.regions.items[sub].node) == sema.decisionKeyOf(inner)) return stmtAt(self, sub);
    }
    return .{ .node = inner, .r = r };
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

/// The lowered body `root` declares; null when the body was not
/// lowered.
pub fn enter(self: *Checker, root: Sexp) Error!?*Body {
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
    // A function's record lives while its walk does: the function arena
    // is reset after each module-level function. The module's own body
    // lives until it is walked (`dropConstants`).
    const a = if (root.isKind(.module)) self.const_arena_state.allocator() else self.fn_arena_state.allocator();
    const out = try a.create(Body);
    out.* = .{ .f = f };
    for (f.regions.items) |r| {
        if (r.kind == .call) if (sema.decisionKeyOf(r.node)) |key| try out.calls.put(a, key, {});
        for (r.steps.items) |s| switch (s) {
            .bind => |x| if (f.vars.items[x.v].name == .hidden) {
                if (out.hoisted.len == 0) {
                    out.hoisted = try a.alloc(lir.ExprId, f.vars.items.len);
                    @memset(out.hoisted, none);
                }
                out.hoisted[x.v] = x.value;
            },
            else => {},
        };
    }
    return out;
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

/// The steps that run statement `e`: for a statement where a value
/// goes, those of the region its expression is; else those of the
/// region it is walked from.
pub fn stepsIn(self: *const Checker, e: Expr) []const lir.Step {
    const b = self.lir_body orelse return &.{};
    const r = if (e.id) |id| switch (b.f.exprs.items[under(b, id)]) {
        .block => |r| r,
        else => e.r orelse return &.{},
    } else e.r orelse return &.{};
    return b.f.regions.items[r].steps.items;
}

/// The value the last of `steps` takes, `node` in the tree: what it
/// stores, binds, evaluates, or leaves with.
pub fn stepValue(self: *const Checker, steps: []const lir.Step, node: Sexp) Expr {
    if (node == .nil) return .{ .node = .nil };
    if (steps.len > 0) switch (steps[steps.len - 1]) {
        .store => |x| return stepOperand(self, node, x.value),
        .bind => |x| return stepOperand(self, node, x.value),
        .eval => |x| return stepOperand(self, node, x),
        .jump => |j| if (j.value) |id| return stepOperand(self, node, id),
        else => {},
    };
    return uncovered(self, node);
}

/// The steps of target `j` of a destructuring, `targets` in the tree: a
/// stretch of `steps`, those of its targets' region, that holds its
/// parts first, then stores, binds, or discards its result.
pub fn targetSteps(self: *const Checker, steps: []const lir.Step, targets: []const Sexp, j: usize) []const lir.Step {
    const f = (self.lir_body orelse return &.{}).f;
    var start: usize = 0;
    var i: usize = 0;
    for (targets[0 .. j + 1], 0..) |t, k| {
        if (!t.isKind(.set)) continue;
        while (i < steps.len and isHold(f, steps[i])) i += 1;
        if (i == steps.len) return &.{};
        i += 1;
        if (k == j) return steps[start..i];
        start = i;
    }
    return &.{};
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
