//! The checker's view of each body's LIR (`src/lir.zig`): the statements
//! of a body or block are its regions' (`stmtsOf`), a binding's symbol is
//! the one its `lir.Var` declares (`bindingAt`), a name's use finds its
//! binding through the var it reads (`symbolOf`), and a statement's
//! temporaries are the vars its region declares for them (`holdsTemp`).
//!
//! A self-checking build walks each module twice, the second time with
//! `Checker.on_lir` set, and compares the two walks' diagnostics
//! (`compare`): the shadow of the checker on LIR.

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const lir = @import("../lir.zig");
const diag = @import("../diag.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const Checker = state.Checker;

/// A body lowered, and what the walk looks up in it by tree node.
pub const Body = struct {
    f: *const lir.Func,
    /// The outermost expression made for each node, by its key.
    exprs: sema.FastMap(u64, lir.ExprId) = .empty,
    /// The region made for each block, by its node's key: the body's
    /// by the key of the function's block.
    regions: sema.FastMap(u64, lir.RegionId) = .empty,
    /// The binding each var of a binding declares, by its declaring
    /// name's key.
    binds: sema.FastMap(u64, SymbolId) = .empty,
    /// The nodes whose value a statement holds in a temporary it drops.
    temps: sema.FastMap(u64, void) = .empty,
};

/// The lowered body whose block or expression is `body`, indexed; null
/// when the checker walks the tree (`Checker.on_lir` unset), or when the
/// body was not lowered.
pub fn enter(self: *Checker, body: Sexp) Error!?*Body {
    if (!self.on_lir) return null;
    const m = &(self.sema.lowered orelse return null);
    if (self.lir_bodies.count() == 0) for (m.owners) |o| {
        const f = o.func orelse continue;
        const b = bodyOf(o.root);
        if (b == .nil) continue;
        try self.lir_bodies.put(self.gpa, sema.decisionKeyOf(b) orelse continue, f);
    };
    const f = self.lir_bodies.get(sema.decisionKeyOf(body) orelse return null) orelse return null;
    const a = self.arena();
    const out = try a.create(Body);
    out.* = .{ .f = f };
    for (f.vars.items) |v| switch (v.name) {
        .binding => |s| if (sema.decisionKeyOf(v.node)) |key| try out.binds.put(a, key, s),
        .hidden => |k| if (k == .temp) if (sema.decisionKeyOf(v.node)) |key| try out.temps.put(a, key, {}),
    };
    try out.regions.put(a, sema.decisionKeyOf(body).?, f.body);
    try index(out, a, f.body);
    return out;
}

/// The body of `root`, a lowered body's root: a function's, a test's, a
/// `drop` body's, or a closure's.
fn bodyOf(root: Sexp) Sexp {
    return switch (root.kind() orelse return .nil) {
        .fun, .sub => ir.get(root, .body),
        .@"test" => ir.Test.body(root),
        .drop_decl => ir.DropDecl.body(root),
        .lambda => ir.Lambda.body(root),
        else => .nil,
    };
}

/// Index region `r` and everything in it, outermost first.
fn index(b: *Body, a: std.mem.Allocator, r: lir.RegionId) Error!void {
    const reg = &b.f.regions.items[r];
    if (sema.decisionKeyOf(reg.node)) |key| switch (reg.kind) {
        .block => {
            const gop = try b.regions.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = r;
        },
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

fn expr(b: *Body, a: std.mem.Allocator, id: lir.ExprId) Error!void {
    const e = b.f.exprs.items[id];
    const node: Sexp = switch (e) {
        .@"var" => |x| x.node,
        .leaf => |l| l,
        .op => |o| o.node,
        .hold, .block => .nil,
        .branch => |x| x.node,
        .choice => |x| x.node,
        .closure => |x| x.node,
        .coerce => |x| x.node,
    };
    if (sema.decisionKeyOf(node)) |key| {
        const gop = try b.exprs.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = id;
    }
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
/// body list them, or null for one not lowered. A statement whose value
/// the body yields comes last, as `value` says.
pub fn stmtsOf(self: *Checker, body: Sexp) Error!?Stmts {
    const b = self.lir_body orelse return null;
    const r = b.regions.get(sema.decisionKeyOf(body) orelse return null) orelse return null;
    const reg = &b.f.regions.items[r];
    var out: std.ArrayList(Sexp) = .empty;
    const a = self.arena();
    for (reg.steps.items) |s| switch (s) {
        .region => |sub| try out.append(a, b.f.regions.items[sub].node),
        else => return null,
    };
    var yields = false;
    if (reg.value) |v| switch (b.f.exprs.items[v]) {
        .block => |sub| {
            try out.append(a, b.f.regions.items[sub].node);
            yields = true;
        },
        else => return null,
    };
    return .{ .list = out.items, .yields = yields };
}

pub const Stmts = struct { list: []const Sexp, yields: bool };

/// The binding a var of the lowered body declares at name `node`.
pub fn bindingAt(self: *const Checker, node: Sexp) ?SymbolId {
    const b = self.lir_body orelse return null;
    return b.binds.get(sema.decisionKeyOf(node) orelse return null);
}

/// The binding name `node` reads, as the var its use reads in the
/// lowered body says; null for a node the body made no var read of.
pub fn symbolOf(self: *const Checker, node: Sexp) ?SymbolId {
    const b = self.lir_body orelse return null;
    var id = b.exprs.get(sema.decisionKeyOf(node) orelse return null) orelse return null;
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
    const b = self.lir_body orelse return null;
    return b.temps.contains(sema.decisionKeyOf(node) orelse return false);
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
