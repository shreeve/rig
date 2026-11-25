//! The checker's view of each body's LIR (`src/lir.zig`): the statements
//! of a body or block are its regions' (`stmtsOf`), a binding's symbol is
//! the one its `lir.Var` declares (`bindingAt`), a name's use finds its
//! binding through the var it reads (`symbolOf`), a statement's
//! temporaries are the vars its region declares for them (`holdsTemp`),
//! and the uses that liveness reads are the names its vars are read at
//! (`indexUses`).
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
const live = @import("live.zig");
const notes = @import("notes.zig");
const types = @import("types.zig");
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

/// The lowered body `root` declares, whose block or expression is
/// `body`, indexed; null when the checker walks the tree
/// (`Checker.on_lir` unset), or when the body was not lowered.
pub fn enter(self: *Checker, root: Sexp, body: Sexp) Error!?*Body {
    if (!self.on_lir) return null;
    const m = &(self.sema.lowered orelse return null);
    const i = m.roots.get(sema.decisionKeyOf(root) orelse return null) orelse return null;
    const f = m.owners[i].func orelse return null;
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
    var it = self.uses.valueIterator();
    while (it.next()) |list| std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
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
    self.uses = .empty;
    self.defer_used = .empty;
    self.last_use.clearRetainingCapacity();
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
pub fn usesDiffer(c: *const Checker, tree_uses: *const std.AutoHashMapUnmanaged(SymbolId, std.ArrayList(u32)), tree_deferred: *const std.AutoHashMapUnmanaged(SymbolId, void)) ?SymbolId {
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
        var it = pair[0].iterator();
        while (it.next()) |kv| {
            if (!binding.is(c, kv.key_ptr.*)) continue;
            const other = pair[1].get(kv.key_ptr.*) orelse return kv.key_ptr.*;
            for (kv.value_ptr.items) |p| if (std.mem.findScalar(u32, other.items, p) == null) return kv.key_ptr.*;
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
