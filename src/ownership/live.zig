//! Liveness: a loan is in force only while the var holding it may be
//! used again, so a view ends at its last use (Core sentence 6).
//!
//! The last use is found on the body's LIR, in the order it runs
//! (`Flow`): each expression, step, and region end is a point, and the
//! points are joined as control goes between them, through branches,
//! loops, jumps, and the exits that run deferred code. A binding is
//! live after a point when a path from it reaches a use of the binding
//! before a store that re-points it. The walk keeps the point it is
//! at (`Checker.point`), so a view is in force exactly while what holds
//! it may still be used where the code goes on.

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const lir = @import("../lir.zig");
const lowering = @import("../lower.zig");
const rig = @import("../rig.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const lowered = @import("lowered.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const Value = state.Value;
const VarId = state.VarId;

/// No point: an expression no path reaches.
pub const no_point = std.math.maxInt(u32);

const exit_bit: u64 = 1 << 63;
const scope_bit: u64 = 1 << 62;

// -----------------------------------------------------------------------------
// The flow of a body: its points in the order they run
// -----------------------------------------------------------------------------

/// A lowered body's points and the paths between them, and where each
/// binding is used and re-pointed.
pub const Flow = struct {
    n: u32 = 0,
    /// The point of each expression, after its operands; `no_point` for
    /// one no step reaches.
    expr_pt: []u32 = &.{},
    /// Where each region starts and ends.
    r_in: []u32 = &.{},
    r_out: []u32 = &.{},
    /// Where a path goes on once the defers of an exit have run: past a
    /// jump (by its step's address), a failure (`e!`, `e?`, by its
    /// expression, `exit_bit` set), or a scope that ends as the code
    /// falls through (by its node's key, `scope_bit` set).
    past: sema.FastMap(u64, u32) = .empty,
    /// Where each `if`, `match`, and loop goes on (`exit`), and a
    /// loop's head and step, by its node's key.
    ctl: sema.FastMap(u64, Ctl) = .empty,
    /// The points that go on to the next one, a bit each; and the other
    /// points each point goes on to: `to[off[p]..off[p + 1]]`.
    seq: []const u64 = &.{},
    off: []u32 = &.{},
    to: []u32 = &.{},
    /// The points that go on to each point: `from[from_off[p]..from_off[p + 1]]`.
    from_off: []u32 = &.{},
    from: []u32 = &.{},
    /// The uses and re-pointings of the bindings, by symbol, then point.
    events: []Event = &.{},
    by_sym: sema.FastMap(SymbolId, [2]u32) = .empty,
    /// Where each binding asked about is live, a bit for each point.
    cache: sema.FastMap(SymbolId, []u64) = .empty,
    arena: std.mem.Allocator,

    pub const Use = struct { pos: u32, ahead: bool };

    pub const Ctl = struct { head: u32 = no_point, exit: u32 = no_point, step: u32 = no_point };

    /// A use of binding `sym` at point `p` (written at `pos`), or a
    /// store that re-points it (`kill`).
    pub const Event = struct { sym: SymbolId, p: u32, pos: u32, kill: bool };

    fn next(fl: *const Flow, p: u32) bool {
        return p / 64 < fl.seq.len and fl.seq[p / 64] & (@as(u64, 1) << @intCast(p % 64)) != 0;
    }

    fn succ(fl: *const Flow, p: u32) []const u32 {
        return fl.to[fl.off[p]..fl.off[p + 1]];
    }

    /// Where `sym` is live as each point starts: used there, or not
    /// re-pointed there and live where a path from it goes on.
    fn liveBits(fl: *Flow, sym: SymbolId) Error![]const u64 {
        if (fl.cache.get(sym)) |b| return b;
        const r = fl.by_sym.get(sym) orelse return &.{};
        const words = (fl.n + 63) / 64;
        const bits = try fl.arena.alloc(u64, words * 2);
        @memset(bits, 0);
        const live = bits[0..words];
        const kills = bits[words..];
        const evs = fl.events[r[0]..r[1]];
        for (evs) |e| if (e.kill) {
            kills[e.p / 64] |= @as(u64, 1) << @intCast(e.p % 64);
        };
        // Back from each use, through the points that do not re-point it.
        var work: std.ArrayList(u32) = .empty;
        for (evs) |e| if (!e.kill) try work.append(fl.arena, e.p);
        while (work.pop()) |q| {
            const bit = @as(u64, 1) << @intCast(q % 64);
            if (live[q / 64] & bit != 0) continue;
            live[q / 64] |= bit;
            if (q > 0 and fl.next(q - 1)) {
                const x = q - 1;
                const xb = @as(u64, 1) << @intCast(x % 64);
                if (live[x / 64] & xb == 0 and kills[x / 64] & xb == 0) try work.append(fl.arena, x);
            }
            for (fl.from[fl.from_off[q]..fl.from_off[q + 1]]) |x| {
                const xb = @as(u64, 1) << @intCast(x % 64);
                if (live[x / 64] & xb == 0 and kills[x / 64] & xb == 0) try work.append(fl.arena, x);
            }
        }
        work.deinit(fl.arena);
        try fl.cache.put(fl.arena, sym, live);
        return live;
    }

    /// Whether `sym` is live as point `p` starts.
    pub fn liveAt(fl: *Flow, sym: SymbolId, p: u32) Error!bool {
        if (p >= fl.n) return true;
        const bits = try fl.liveBits(sym);
        return bits.len > 0 and bits[p / 64] & (@as(u64, 1) << @intCast(p % 64)) != 0;
    }

    /// Whether `sym` is live after point `p`: where a path from it goes on.
    pub fn liveAfter(fl: *Flow, sym: SymbolId, p: u32) Error!bool {
        if (p >= fl.n) return true;
        const bits = try fl.liveBits(sym);
        if (bits.len == 0) return false;
        if (fl.next(p) and bits[(p + 1) / 64] & (@as(u64, 1) << @intCast((p + 1) % 64)) != 0) return true;
        for (fl.succ(p)) |q| if (bits[q / 64] & (@as(u64, 1) << @intCast(q % 64)) != 0) return true;
        return false;
    }

    /// The uses of `sym` a path from point `p` reaches before a store
    /// re-points it, appended to `out`: where each is written, and
    /// whether it runs later in the same pass (its point is after `p`).
    pub fn usesAfter(fl: *Flow, a: std.mem.Allocator, sym: SymbolId, p: u32, out: *std.ArrayList(Use)) Error!void {
        if (p >= fl.n) return;
        const r = fl.by_sym.get(sym) orelse return;
        const evs = fl.events[r[0]..r[1]];
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(a, fl.n);
        var work: std.ArrayList(u32) = .empty;
        if (fl.next(p)) try work.append(a, p + 1);
        for (fl.succ(p)) |q| try work.append(a, q);
        while (work.pop()) |q| {
            if (seen.isSet(q)) continue;
            seen.set(q);
            var used = false;
            var killed = false;
            for (evs) |e| if (e.p == q) {
                if (e.kill) killed = true else {
                    used = true;
                    try out.append(a, .{ .pos = e.pos, .ahead = e.p > p });
                }
            };
            if (killed and !used) continue;
            if (fl.next(q)) try work.append(a, q + 1);
            for (fl.succ(q)) |s| try work.append(a, s);
        }
    }
};

/// Build the flow of body `b`.
pub fn build(self: *const Checker, b: *const lowered.Body, a: std.mem.Allocator) Error!*Flow {
    const f = b.f;
    const fl = try a.create(Flow);
    fl.* = .{ .arena = a };
    fl.expr_pt = try a.alloc(u32, f.exprs.items.len);
    @memset(fl.expr_pt, no_point);
    fl.r_in = try a.alloc(u32, f.regions.items.len);
    @memset(fl.r_in, no_point);
    fl.r_out = try a.alloc(u32, f.regions.items.len);
    @memset(fl.r_out, no_point);
    var bd: Builder = .{ .c = self, .a = a, .f = f, .b = b, .fl = fl };
    try bd.region(f.body);
    // The function's exit, where a `return` and a failure go.
    const exit = try bd.new();
    for (bd.to_exit.items) |p| try bd.edge(p, exit);
    fl.seq = bd.seq.items;
    // A part a region holds first is walked where it is held.
    if (b.hoisted.len > 0) for (f.exprs.items, 0..) |e, i| switch (e) {
        .@"var" => |x| if (b.hoisted[x.v] != std.math.maxInt(u32)) {
            fl.expr_pt[i] = fl.expr_pt[lowered.under(b, @intCast(i))];
        },
        else => {},
    };

    // The paths, by the point each starts from.
    fl.off = try a.alloc(u32, fl.n + 1);
    @memset(fl.off, 0);
    for (bd.edges.items) |e| fl.off[e[0] + 1] += 1;
    for (1..fl.off.len) |i| fl.off[i] += fl.off[i - 1];
    fl.to = try a.alloc(u32, bd.edges.items.len);
    const fill = try a.dupe(u32, fl.off[0..fl.n]);
    for (bd.edges.items) |e| {
        fl.to[fill[e[0]]] = e[1];
        fill[e[0]] += 1;
    }
    fl.from_off = try a.alloc(u32, fl.n + 1);
    @memset(fl.from_off, 0);
    for (bd.edges.items) |e| fl.from_off[e[1] + 1] += 1;
    for (1..fl.from_off.len) |i| fl.from_off[i] += fl.from_off[i - 1];
    fl.from = try a.alloc(u32, bd.edges.items.len);
    @memcpy(fill, fl.from_off[0..fl.n]);
    for (bd.edges.items) |e| {
        fl.from[fill[e[1]]] = e[0];
        fill[e[1]] += 1;
    }
    // The events, by symbol and then point.
    std.mem.sort(Flow.Event, bd.events.items, {}, struct {
        fn lt(_: void, x: Flow.Event, y: Flow.Event) bool {
            return if (x.sym != y.sym) x.sym < y.sym else x.p < y.p;
        }
    }.lt);
    fl.events = bd.events.items;
    var i: u32 = 0;
    while (i < fl.events.len) {
        var j = i;
        while (j < fl.events.len and fl.events[j].sym == fl.events[i].sym) j += 1;
        try fl.by_sym.put(a, fl.events[i].sym, .{ i, j });
        i = j;
    }
    return fl;
}

const Builder = struct {
    c: *const Checker,
    a: std.mem.Allocator,
    f: *const lir.Func,
    b: *const lowered.Body,
    fl: *Flow,
    /// The point the next one follows, or null where no path goes on.
    prev: ?u32 = null,
    /// The points that go on to the next (`Flow.seq`), and the other paths.
    seq: std.ArrayList(u64) = .empty,
    edges: std.ArrayList([2]u32) = .empty,
    events: std.ArrayList(Flow.Event) = .empty,
    /// The regions open around the point being made that run deferred
    /// code as they end, each with the defers registered in it so far.
    scopes: std.ArrayList(std.ArrayList(Deferred)) = .empty,
    /// The constructs open around it that a jump goes to.
    targets: std.ArrayList(Target) = .empty,
    /// The points whose paths go on at the function's exit.
    to_exit: std.ArrayList(u32) = .empty,

    /// A `defer` or `errdefer` body: where it starts and ends.
    const Deferred = struct { in: u32, end: ?u32, err: bool };

    const Target = struct {
        key: u64,
        /// The scopes open when it starts: a jump leaves those after.
        scopes: usize,
        head: u32 = no_point,
        exits: std.ArrayList(u32) = .empty,
        steps: std.ArrayList(u32) = .empty,
    };

    fn new(bd: *Builder) Error!u32 {
        const p = bd.fl.n;
        bd.fl.n += 1;
        if (bd.prev) |q| {
            if (q + 1 == p) {
                while (bd.seq.items.len <= q / 64) try bd.seq.append(bd.a, 0);
                bd.seq.items[q / 64] |= @as(u64, 1) << @intCast(q % 64);
            } else try bd.edge(q, p);
        }
        bd.prev = p;
        return p;
    }

    fn edge(bd: *Builder, from: u32, to: u32) Error!void {
        try bd.edges.append(bd.a, .{ from, to });
    }

    fn event(bd: *Builder, sym: SymbolId, p: u32, node: Sexp, kill: bool) Error!void {
        try bd.events.append(bd.a, .{ .sym = sym, .p = p, .pos = homePos(bd.c, node), .kill = kill });
    }

    /// A point of its own after `last`, where the path goes on once an
    /// exit's defers have run, recorded as `key`'s.
    fn past(bd: *Builder, last: ?u32, key: u64) Error!?u32 {
        const l = last orelse return null;
        const p = bd.fl.n;
        bd.fl.n += 1;
        try bd.edge(l, p);
        try bd.fl.past.put(bd.a, key, p);
        return p;
    }

    /// Run the defers of `defers`, newest first, from point `from`; an
    /// `errdefer` only where the path fails. Gives the point the path
    /// goes on from.
    fn chain(bd: *Builder, from: u32, defers: []const Deferred, fails: bool) Error!?u32 {
        var last: ?u32 = from;
        var i = defers.len;
        while (i > 0) {
            i -= 1;
            const d = defers[i];
            if (d.err and !fails) continue;
            try bd.edge(last orelse return null, d.in);
            last = d.end;
        }
        return last;
    }

    /// Leave the scopes opened since there were `depth`, from `from`.
    fn leave(bd: *Builder, from: u32, depth: usize, fails: bool) Error!?u32 {
        var last: ?u32 = from;
        var i = bd.scopes.items.len;
        while (i > depth) {
            i -= 1;
            last = try bd.chain(last orelse return null, bd.scopes.items[i].items, fails);
        }
        return last;
    }

    fn region(bd: *Builder, r: lir.RegionId) Error!void {
        const reg = &bd.f.regions.items[r];
        const scope = reg.kind == .body or reg.kind == .block or reg.kind == .arm;
        if (scope) try bd.scopes.append(bd.a, .empty);
        const in = try bd.new();
        bd.fl.r_in[r] = in;
        // Each entry gives its bindings new values.
        for (reg.decls.items) |x| switch (bd.f.vars.items[x].name) {
            .binding => |sym| try bd.event(sym, in, bd.f.vars.items[x].node, true),
            .hidden => {},
        };
        // A pattern is not lowered: the names it reads are the tree's.
        if (reg.kind == .arm) try bd.patternUses(ir.Arm.pattern(reg.node), reg, in);
        for (reg.steps.items) |*s| try bd.step(s);
        if (reg.value) |v| try bd.expr(v);
        const out = try bd.new();
        bd.fl.r_out[r] = out;
        if (scope) {
            const defers = bd.scopes.pop().?;
            if (bd.prev != null) {
                const key = if (reg.kind == .body) scope_bit else scope_bit | ((sema.decisionKeyOf(reg.node) orelse 0) & ~(exit_bit | scope_bit));
                bd.prev = try bd.past(try bd.chain(out, defers.items, false), key);
            }
        }
    }

    fn patternUses(bd: *Builder, e: Sexp, reg: *const lir.Region, p: u32) Error!void {
        switch (e) {
            .src => {
                const sym = bd.c.sema.symbolOf(e) orelse return;
                for (reg.decls.items) |x| switch (bd.f.vars.items[x].name) {
                    .binding => |s| if (s == sym) return,
                    .hidden => {},
                };
                try bd.event(sym, p, e, false);
            },
            .list => for (e.items()) |x| try bd.patternUses(x, reg, p),
            else => {},
        }
    }

    fn step(bd: *Builder, s: *const lir.Step) Error!void {
        switch (s.*) {
            .bind => |x| {
                try bd.expr(x.value);
                _ = try bd.new();
            },
            .store => |x| {
                // A value read where it runs (`lowering.isPureArg`) is
                // read at the store, after the target's base and indexes.
                if (lowering.isPureArg(bd.c.sema, lowered.nodeOf(bd.b, x.value))) {
                    try bd.target(x.node, x.target);
                    try bd.expr(x.value);
                } else {
                    try bd.expr(x.value);
                    try bd.target(x.node, x.target);
                }
                _ = try bd.new();
            },
            .eval => |e| try bd.expr(e),
            .drop => |x| {
                const p = try bd.new();
                switch (bd.f.vars.items[x.v].name) {
                    .binding => |sym| try bd.event(sym, p, x.node, false),
                    .hidden => {},
                }
            },
            .jump => |j| {
                if (j.value) |v| try bd.expr(v);
                try bd.jump(j.node, try bd.new(), @intFromPtr(s));
            },
            .region => |sub| {
                const node = bd.f.regions.items[sub].node;
                if (node.isKind(.@"defer") or node.isKind(.@"errdefer")) {
                    // Run where its scope is left, not here.
                    const saved = bd.prev;
                    bd.prev = null;
                    try bd.region(sub);
                    const d: Deferred = .{ .in = bd.fl.r_in[sub], .end = bd.prev, .err = node.isKind(.@"errdefer") };
                    bd.prev = saved;
                    if (bd.scopes.items.len > 0) try bd.scopes.items[bd.scopes.items.len - 1].append(bd.a, d);
                } else try bd.region(sub);
            },
            .@"if" => |x| _ = try bd.branch(x),
            .loop => |x| try bd.loop(x.node, x.cond, x.body, x.step),
            .each => |x| try bd.each(x.node, x.source, x.body),
            .match => |x| _ = try bd.choice(x),
        }
    }

    /// The target of a store `node`: a binding it re-points takes a new
    /// value there; a binding it combines with or writes through, and
    /// each name a field or element target reads, is used there.
    fn target(bd: *Builder, node: Sexp, id: lir.ExprId) Error!void {
        switch (bd.f.exprs.items[id]) {
            .@"var" => |x| switch (bd.f.vars.items[x.v].name) {
                .binding => |sym| if (repoints(bd.c, node)) {
                    const p = try bd.new();
                    bd.fl.expr_pt[id] = p;
                    return bd.event(sym, p, x.node, true);
                },
                .hidden => {},
            },
            else => {},
        }
        try bd.expr(id);
    }

    fn jump(bd: *Builder, node: Sexp, p: u32, key: u64) Error!void {
        bd.prev = null;
        if (node.isKind(.@"return")) {
            if (try bd.past(try bd.leave(p, 0, true), key)) |last| try bd.to_exit.append(bd.a, last);
            return;
        }
        const dest = bd.c.sema.jumpDestOf(node);
        const target_key = if (dest) |d| sema.decisionKeyOf(d.target) else null;
        var i = bd.targets.items.len;
        while (i > 0) {
            i -= 1;
            const t = &bd.targets.items[i];
            if (target_key == null or t.key != target_key.?) continue;
            const last = try bd.past(try bd.leave(p, t.scopes, false), key) orelse return;
            switch (dest.?.to) {
                .exit => try t.exits.append(bd.a, last),
                .step => try t.steps.append(bd.a, last),
                .head => try bd.edge(last, t.head),
            }
            return;
        }
        // A target not found: on to every construct around it.
        for (bd.targets.items) |*t| try t.exits.append(bd.a, p);
        try bd.to_exit.append(bd.a, p);
    }

    fn pushTarget(bd: *Builder, node: Sexp) Error!void {
        try bd.targets.append(bd.a, .{ .key = sema.decisionKeyOf(node) orelse 0, .scopes = bd.scopes.items.len });
    }

    /// `if`: the condition, then either branch, which join after it.
    fn branch(bd: *Builder, x: lir.Expr.If) Error!u32 {
        try bd.expr(x.cond);
        const c = bd.prev;
        try bd.region(x.then);
        const t_end = bd.prev;
        bd.prev = c;
        if (x.@"else") |r| try bd.region(r);
        const e_end = bd.prev;
        bd.prev = null;
        const join = try bd.new();
        if (t_end) |p| try bd.edge(p, join);
        if (e_end) |p| try bd.edge(p, join);
        try bd.putCtl(x.node, .{ .exit = join });
        return join;
    }

    /// `match`: the subject, then the arm it fits; an arm whose guard
    /// fails goes on to test the arms after it.
    fn choice(bd: *Builder, x: lir.Expr.Choice) Error!u32 {
        try bd.expr(x.subject);
        const s = bd.prev;
        try bd.pushTarget(x.node);
        var ends: std.ArrayList(u32) = .empty;
        var guards: std.ArrayList(u32) = .empty;
        for (x.arms) |arm| {
            bd.prev = s;
            try bd.region(arm);
            for (guards.items) |g| try bd.edge(g, bd.fl.r_in[arm]);
            if (bd.prev) |p| try ends.append(bd.a, p);
            const steps = bd.f.regions.items[arm].steps.items;
            if (steps.len > 0 and steps[steps.len - 1] == .@"if" and steps[steps.len - 1].@"if".@"else" == null) {
                const g = bd.fl.expr_pt[steps[steps.len - 1].@"if".cond];
                if (g != no_point) try guards.append(bd.a, g);
            }
        }
        var t = bd.targets.pop().?;
        bd.prev = null;
        const join = try bd.new();
        for (ends.items) |p| try bd.edge(p, join);
        for (t.exits.items) |p| try bd.edge(p, join);
        t.exits = .empty;
        try bd.putCtl(x.node, .{ .exit = join });
        return join;
    }

    /// `while cond: step`: the head, the condition, the body, the step,
    /// and back to the head; the loop ends where the condition fails.
    fn loop(bd: *Builder, node: Sexp, cond: lir.ExprId, body: lir.RegionId, st: ?lir.RegionId) Error!void {
        try bd.pushTarget(node);
        const head = try bd.new();
        bd.targets.items[bd.targets.items.len - 1].head = head;
        try bd.expr(cond);
        const c = bd.prev;
        try bd.region(body);
        var step_in: u32 = no_point;
        if (st) |r| {
            try bd.region(r);
            step_in = bd.fl.r_in[r];
        }
        if (bd.prev) |p| try bd.edge(p, head);
        const t = bd.targets.pop().?;
        for (t.steps.items) |p| try bd.edge(p, if (step_in != no_point) step_in else head);
        bd.prev = null;
        const exit = try bd.new();
        if (c) |p| try bd.edge(p, exit);
        for (t.exits.items) |p| try bd.edge(p, exit);
        try bd.putCtl(node, .{ .head = head, .exit = exit, .step = step_in });
    }

    /// `for x in source`: the source, then the head, which runs the body
    /// again or ends the loop.
    fn each(bd: *Builder, node: Sexp, source: lir.ExprId, body: lir.RegionId) Error!void {
        try bd.expr(source);
        try bd.pushTarget(node);
        const head = try bd.new();
        bd.targets.items[bd.targets.items.len - 1].head = head;
        try bd.region(body);
        if (bd.prev) |p| try bd.edge(p, head);
        const t = bd.targets.pop().?;
        for (t.steps.items) |p| try bd.edge(p, head);
        bd.prev = null;
        const exit = try bd.new();
        try bd.edge(head, exit);
        for (t.exits.items) |p| try bd.edge(p, exit);
        try bd.putCtl(node, .{ .head = head, .exit = exit });
    }

    fn putCtl(bd: *Builder, node: Sexp, c: Flow.Ctl) Error!void {
        try bd.fl.ctl.put(bd.a, sema.decisionKeyOf(node) orelse return, c);
    }

    fn expr(bd: *Builder, id: lir.ExprId) Error!void {
        const p: u32 = switch (bd.f.exprs.items[id]) {
            .@"var" => |x| blk: {
                const p = try bd.new();
                switch (bd.f.vars.items[x.v].name) {
                    .binding => |sym| try bd.event(sym, p, x.node, false),
                    .hidden => {},
                }
                break :blk p;
            },
            // No binding of the body is a leaf.
            .leaf => try bd.new(),
            .op => |o| try bd.op(id, o),
            .hold => |h| blk: {
                try bd.expr(h.value);
                break :blk try bd.new();
            },
            .block => |r| blk: {
                try bd.region(r);
                break :blk try bd.new();
            },
            .branch => |x| try bd.branch(x),
            .choice => |x| try bd.choice(x),
            .closure => |x| blk: {
                for (x.captures) |cap| try bd.expr(cap);
                const p = try bd.new();
                // Each binding a capture names is used where the
                // closure is made.
                const m = &(bd.c.sema.lowered orelse break :blk p);
                const g = m.owners[x.owner].func orelse break :blk p;
                for (g.vars.items) |v| switch (v.name) {
                    .binding => |sym| {
                        const d = bd.c.sema.symbols.items[sym];
                        if (d.kind == .capture and d.origin != sema.symbol_invalid) try bd.event(d.origin, p, v.node, false);
                    },
                    .hidden => {},
                };
                break :blk p;
            },
            .coerce => |x| blk: {
                try bd.expr(x.value);
                break :blk try bd.new();
            },
        };
        bd.fl.expr_pt[id] = p;
    }

    fn op(bd: *Builder, id: lir.ExprId, o: lir.Expr.Op) Error!u32 {
        const node = o.node;
        // A part that may not run: the right of `and`, `or`, and `??`,
        // and a `catch` handler.
        const skips = switch (o.kind) {
            .logic => node.isKind(.@"and") or node.isKind(.@"or"),
            .nullish, .@"catch" => true,
            else => false,
        };
        if (skips and o.args.len == 2) {
            try bd.expr(o.args[0]);
            const s = bd.prev;
            try bd.expr(o.args[1]);
            const p = try bd.new();
            if (s) |q| try bd.edge(q, p);
            return p;
        }
        if (o.kind == .as) {
            // `v as name` gives the names it binds new values.
            for (o.args, 0..) |x, i| switch (bd.f.exprs.items[x]) {
                .@"var" => |u| if (i > 0 and bd.f.vars.items[u.v].name == .binding) {
                    const q = try bd.new();
                    bd.fl.expr_pt[x] = q;
                    try bd.event(bd.f.vars.items[u.v].name.binding, q, u.node, true);
                } else try bd.expr(x),
                else => try bd.expr(x),
            };
        } else for (o.args) |x| try bd.expr(x);
        const p = try bd.new();
        switch (o.kind) {
            .propagate, .propagate_none => if (try bd.past(try bd.leave(p, 0, true), exit_bit | id)) |last| try bd.to_exit.append(bd.a, last),
            .panic => bd.prev = null,
            else => {},
        }
        return p;
    }
};

/// Whether the store `node` gives a binding target a new value, not
/// combining with its old one (`x op= v`) or writing through it (a
/// `!T` local given a value).
fn repoints(self: *const Checker, node: Sexp) bool {
    if (!node.isKind(.set)) return false;
    const kind = rig.bindingKindOf(ir.Set.op(node));
    if (kind.operator() != null) return false;
    return !(kind == .default and self.sema.writesThrough(node));
}

/// Where a use at `node` is written: its own position, or, for a leaf a
/// rewrite wrote past the source's end (a spread's copied operand),
/// its home there.
fn homePos(self: *const Checker, node: Sexp) u32 {
    const pos = if (node == .src) node.src.pos else self.sema.startOf(node);
    if (pos < self.source.len) return pos;
    const p = self.sema.parser orelse return pos;
    return p.homeOf(pos);
}

// -----------------------------------------------------------------------------
// Where the walk is
// -----------------------------------------------------------------------------

/// A place in a body's flow, named by what is there, so the flow is
/// built only where liveness is asked (`resolve`): an expression, a
/// region's start or end, a store or a binding's declaration, the
/// point past an exit's defers, or where a construct goes on, its head,
/// or its step. Where `kind` names nothing in the flow, `alt` does.
pub const Loc = struct {
    kind: Kind = .none,
    id: u64 = 0,
    alt: Alt = .{},

    pub const Kind = enum(u8) { none, expr, r_in, r_out, step, past, exit, head, step_in };
    pub const Alt = struct { kind: Kind = .none, id: u64 = 0 };

    fn of(kind: Kind, id: u64) Loc {
        return .{ .kind = kind, .id = id };
    }
};

/// The point `loc` names in flow `fl`, or null.
fn resolve(fl: *const Flow, loc: Loc) ?u32 {
    return one(fl, loc.kind, loc.id) orelse one(fl, loc.alt.kind, loc.alt.id);
}

fn one(fl: *const Flow, kind: Loc.Kind, id: u64) ?u32 {
    const p: u32 = switch (kind) {
        .none => return null,
        .expr => fl.expr_pt[@intCast(id)],
        .r_in => fl.r_in[@intCast(id)],
        .r_out => fl.r_out[@intCast(id)],
        .step => switch (@as(*const lir.Step, @ptrFromInt(@as(usize, @intCast(id)))).*) {
            .store => |x| (@max(fl.expr_pt[x.target] +% 1, fl.expr_pt[x.value] +% 1) -% 1) +% 1,
            .bind => |x| fl.expr_pt[x.value] +% 1,
            else => return null,
        },
        .past => fl.past.get(id) orelse return null,
        .exit, .head, .step_in => blk: {
            const c = fl.ctl.get(id) orelse return null;
            break :blk switch (kind) {
                .exit => c.exit,
                .head => c.head,
                else => c.step,
            };
        },
    };
    return if (p >= fl.n) null else p;
}

/// The flow of body `b`, built the first time it is asked for.
fn flowOf(self: *const Checker, b: *lowered.Body) ?*Flow {
    if (b.flow == null and !b.f.root.isKind(.module)) b.flow = build(self, b, b.arena) catch return null;
    return b.flow;
}

/// The walk is at expression `id`: where it runs, after its operands.
pub fn atExpr(self: *Checker, id: lir.ExprId) void {
    self.point = .of(.expr, id);
}

/// The walk is at step `s`, a store or a binding's declaration: the
/// point after its value and target.
pub fn atStep(self: *Checker, s: *const lir.Step) void {
    self.point = .of(.step, @intFromPtr(s));
}

/// Where expression `e` runs, after its operands (for a part a region
/// holds first, where it is held).
pub fn ptOf(self: *const Checker, e: lowered.Expr) ?Loc {
    const b = self.lir_body orelse return null;
    return .of(.expr, lowered.under(b, e.id orelse return null));
}

/// The walk is past the defers jump `steps` ends with (a `break`,
/// `continue`, or `return`) runs: where the path goes on.
pub fn atJump(self: *Checker, steps: []const lir.Step) void {
    if (steps.len > 0) self.point = .{ .kind = .past, .id = @intFromPtr(&steps[steps.len - 1]), .alt = .{ .kind = self.point.kind, .id = self.point.id } };
}

/// The walk is past the defers failure `e` (`e!`, `e?`) runs.
pub fn atFailure(self: *Checker, e: lowered.Expr) void {
    const b = self.lir_body orelse return;
    self.point = .{ .kind = .past, .id = exit_bit | lowered.under(b, e.id orelse return), .alt = .{ .kind = self.point.kind, .id = self.point.id } };
}

/// The walk is past the defers of the scope over `node` (null for the
/// function's body), which ends as the code falls through.
pub fn atScopeEnd(self: *Checker, node: Sexp) void {
    const key = if (node == .nil) scope_bit else scope_bit | ((sema.decisionKeyOf(node) orelse return) & ~(exit_bit | scope_bit));
    self.point = .{ .kind = .past, .id = key, .alt = .{ .kind = self.point.kind, .id = self.point.id } };
}

/// Where region `r` ends.
pub fn outOf(r: lir.RegionId) Loc {
    return .of(.r_out, r);
}

/// Where region `r` starts.
pub fn inOf(r: lir.RegionId) Loc {
    return .of(.r_in, r);
}

/// Where construct `node` (an `if`, a `match`, a loop) goes on, its
/// head, and its step.
pub fn ctlOf(node: Sexp) struct { exit: ?Loc, head: ?Loc, step: ?Loc } {
    const key = sema.decisionKeyOf(node) orelse return .{ .exit = null, .head = null, .step = null };
    return .{ .exit = .of(.exit, key), .head = .of(.head, key), .step = .of(.step_in, key) };
}

/// Where statement `e` ends: its own region's end, or, for a condition
/// walked as a statement, where its expression runs.
pub fn stmtOut(self: *const Checker, e: lowered.Expr) ?Loc {
    const b = self.lir_body orelse return null;
    if (e.r) |r| {
        const reg = &b.f.regions.items[r];
        if (reg.kind == .stmt and sema.decisionKeyOf(reg.node) == sema.decisionKeyOf(e.node)) return outOf(r);
    }
    return ptOf(self, e);
}

/// The flow that holds binding `sym`, and the point the walk is at in
/// it: the body walked, or one around it whose closure is made there.
fn holding(self: *const Checker, sym: SymbolId) ?struct { fl: *Flow, p: ?u32, here: bool } {
    var b = self.lir_body;
    var loc = self.point;
    while (b) |body| {
        for (body.f.vars.items) |v| switch (v.name) {
            .binding => |s| if (s == sym) {
                const fl = flowOf(self, body) orelse return null;
                return .{ .fl = fl, .p = resolve(fl, loc), .here = body == self.lir_body.? };
            },
            .hidden => {},
        };
        loc = body.outer_point;
        b = body.outer;
    }
    return null;
}

/// Whether binding `sym` may be used again after the walk's point, or,
/// at `at`, where a path goes on.
fn usedAfter(self: *const Checker, sym: SymbolId, at: ?Loc) bool {
    const w = holding(self, sym) orelse return true;
    if (at) |x| if (w.here) if (resolve(w.fl, x)) |p| return w.fl.liveAt(sym, p) catch true;
    return w.fl.liveAfter(sym, w.p orelse return true) catch true;
}

/// The uses of binding `sym` a path from the walk's point reaches,
/// where each is written.
pub fn usesAhead(self: *const Checker, sym: SymbolId) []const Flow.Use {
    const w = holding(self, sym) orelse return &.{};
    var out: std.ArrayList(Flow.Use) = .empty;
    w.fl.usesAfter(w.fl.arena, sym, w.p orelse return &.{}, &out) catch return &.{};
    return out.items;
}

// -----------------------------------------------------------------------------
// Liveness: a view ends at its last use (Core sentence 6)
// -----------------------------------------------------------------------------

/// Whether `holder` still uses what it views once a statement's
/// temporary it views is dropped there. A temporary of the same
/// statement, dropped after it, uses its views as any owner's drop
/// does, only through a `drop` body (Core sentence 6), or through a
/// live value that views it; any other holder as `holderLive` says.
pub fn holdsPastDrop(self: *const Checker, holder: VarId, depth: u8) bool {
    if (!self.isStmtTemp(holder) or depth > 16) return holderLive(self, holder, null);
    const ctx = self.sema;
    const ty = self.vars.items[holder].ty orelse return true;
    if (sema.dropRunsBody(ctx, ty) != .no) return true;
    if (self.isViewed(holder)) for (self.flows.items, 0..) |f, j| {
        if (j == holder) continue;
        for (f.loans) |l| if (l.root == holder and !l.ext) {
            if (holdsPastDrop(self, @intCast(j), depth + 1)) return true;
            break;
        };
    };
    return false;
}

/// Whether the value var `id` holds may still be used after the
/// walk's point (or at point `at`, where a path goes on), so the loans
/// it holds are still in force. It is live when a path from there
/// reaches a use of the var before a store re-points it (`Flow`), deferred code
/// and a loop's next pass among them, or when its drop at scope exit
/// may run a `drop` body, which could read what it views
/// (`sema.dropRunsBody`; any other drop only releases memory, and
/// uses no view), or when a live var or temporary views it in turn.
/// Otherwise its last use is behind, and its views have ended.
pub fn holderLive(self: *const Checker, id: VarId, at: ?Loc) bool {
    return holderLiveDepth(self, id, at, 0);
}

pub fn holderLiveDepth(self: *const Checker, id: VarId, at: ?Loc, depth: u8) bool {
    if (!self.nll or depth > 16) return true;
    const ctx = self.sema;
    const v = self.vars.items[id];
    // An owning temporary is used by its `drop` body, or through what
    // views it.
    if (v.temp_value) {
        if (v.ty == null or sema.dropRunsBody(ctx, v.ty.?) != .no) return true;
        return viewedByLive(self, id, at, depth);
    }
    // A parameter is live at every exit: the caller uses the value
    // it gave a view of after the return.
    if (v.kind == .hidden or v.kind == .param or v.env_drop_reads or self.isGlobal(id)) return true;
    const sym = v.sym orelse return true;
    const ty = v.ty orelse return true;
    // A var that owns its value drops it at scope exit, which uses
    // its views only through a `drop` body. (A match payload or a
    // viewed loop element only views a value.)
    const owns = !v.payload_view and !v.loop_view and v.ref == .none;
    if (owns and sema.dropRunsBody(ctx, ty) != .no) return true;
    if (usedAfter(self, sym, at)) return true;
    return viewedByLive(self, id, at, depth);
}

/// Whether a live var or a temporary views var `id`.
pub fn viewedByLive(self: *const Checker, id: VarId, at: ?Loc, depth: u8) bool {
    if (self.isViewed(id)) for (self.flows.items, 0..) |f, j| {
        if (j == id) continue;
        for (f.loans) |l| if (l.root == id and !l.ext) {
            if (holderLiveDepth(self, @intCast(j), at, depth + 1)) return true;
            break;
        };
    };
    for (self.temps.items) |l| if (l.root == id) return true;
    return false;
}

pub fn addTemp(self: *Checker, l: Loan) Error!void {
    try self.temps.append(self.gpa, l);
}

/// Loans carried by the current value of var `id`.
pub fn varValue(self: *Checker, id: VarId) Value {
    const v = self.vars.items[id];
    if (!v.closure and !types.mayCarryLoan(self, v.ty)) {
        if (generic.genericType(self, v.ty)) {
            // A value of a type parameter's type carries, in an
            // instance, what its binding views (a match payload's
            // view of the matched value), and a parameter taken by
            // value what its caller's argument viewed.
            generic.taintGeneric(self, v.ty, .{ .loans = self.flows.items[id].loans });
            if (v.kind == .param and v.ref == .none) if (v.param_index) |i| {
                self.func.generic |= sema.paramBit(i);
            };
        }
        return .{};
    }
    return .{ .loans = self.flows.items[id].loans };
}
