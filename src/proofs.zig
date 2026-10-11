//! Proven checks: which of a node's tests are known to pass
//! (docs/INTERNALS.md, "Proven checks").
//!
//! A check is the test an operation makes before it acts: `s[i]` tests
//! `0 <= i` and `i < s.len`, `s.read[T, e](i)` tests `0 <= i` and
//! `i + @size(T) <= s.len`, and `i + c` tests that the sum fits. This pass
//! runs on a module the ownership checker accepted, walks each body in the
//! order the emitted Zig runs, and records on each such node the tests
//! that a guard or a check already made on every path to it, about values
//! nothing has written since (`SemContext.recordProven`). Emit omits those
//! tests; a debug build still makes each one, as an assertion of the proof.
//!
//! The pass tracks three facts about bindings, by symbol:
//!
//! - `nonneg(i)`: `0 <= i`;
//! - `below(i, k, b)`: `i + k <= b`, exactly, where the bound `b` is
//!   `len(s)`, the length of a slice view `s`, or `int(n)`, the value of
//!   an `Int` binding `n`;
//! - `fits(s)`: `s.len <= max_len`, which `rig.len` tests where a length
//!   is read.
//!
//! What makes a fact, what a fact proves, and which writes end one are
//! positive lists: a shape not listed makes nothing and proves nothing.
//! Writes are the ones resolve and typecheck record (`recordWrite`), and
//! the walk applies each where it runs. Within one expression the order
//! of evaluation is not relied on: a fact a part of the expression could
//! end is ended before any part is read (`walkAtomic`). Where control
//! flow joins, the facts are those from before the construct less every
//! write inside it, so a fact made in one branch, or in an earlier
//! iteration of a loop, is never assumed.
//!
//! Its soundness rests on the Core: a binding changes only where an
//! assignment or a `!` says so (sentences 4 and 9), every such site is
//! recorded, and a write view made before a guard and used after it makes
//! the guard's read a rejection (sentences 5 and 6), so in an accepted
//! module no write slips between a fact and its use unseen.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const Proven = sema.Proven;

/// The longest length a length read lets through (`rig.len`): no target
/// holds more.
pub const max_len: u64 = (1 << 62) - 1;
/// The largest constant a fact or a use names, so every sum the pass
/// reasons about fits in an `Int`.
pub const max_k: u64 = 1 << 62;

const Bound = union(enum) {
    /// The length of the slice view a binding holds.
    len: SymbolId,
    /// The value of an `Int` binding.
    int: SymbolId,

    fn sym(b: Bound) SymbolId {
        return switch (b) {
            inline else => |s| s,
        };
    }
};

const Below = struct { i: SymbolId, k: u64, b: Bound };

const Fact = union(enum) {
    nonneg: SymbolId,
    below: Below,
    fits: SymbolId,
};

/// The facts that hold at a point of the walk.
const State = struct {
    facts: std.ArrayList(Fact) = .empty,

    fn clone(st: *const State, a: std.mem.Allocator) !State {
        return .{ .facts = try st.facts.clone(a) };
    }

    fn clear(st: *State) void {
        st.facts.clearRetainingCapacity();
    }

    fn hasNonneg(st: *const State, i: SymbolId) bool {
        for (st.facts.items) |f| if (f == .nonneg and f.nonneg == i) return true;
        return false;
    }

    fn hasFits(st: *const State, s: SymbolId) bool {
        for (st.facts.items) |f| if (f == .fits and f.fits == s) return true;
        return false;
    }

    /// The largest `k` with `below(i, k, b)`, or null.
    fn belowK(st: *const State, i: SymbolId, b: Bound) ?u64 {
        var best: ?u64 = null;
        for (st.facts.items) |f| if (f == .below and f.below.i == i and std.meta.eql(f.below.b, b)) {
            best = @max(best orelse 0, f.below.k);
        };
        return best;
    }

    fn add(st: *State, a: std.mem.Allocator, fact: Fact) !void {
        switch (fact) {
            .nonneg => |i| if (st.hasNonneg(i)) return,
            .fits => |s| if (st.hasFits(s)) return,
            // One `below` per binding and bound: the largest `k`.
            .below => |nb| for (st.facts.items) |*f| if (f.* == .below and f.below.i == nb.i and std.meta.eql(f.below.b, nb.b)) {
                f.below.k = @max(f.below.k, nb.k);
                return;
            },
        }
        try st.facts.append(a, fact);
    }
};

/// What a write does to the facts about the binding it writes.
const Effect = struct {
    sym: SymbolId,
    /// `i += c` or `i = i + c` with a literal `c >= 0`: the sum either
    /// panics or is at least `i`, so `0 <= i` stays true.
    keeps_nonneg: bool,
    /// A write through a slice view (`!s`, `s[j] = x`) changes elements,
    /// never the view's length.
    keeps_len: bool,
};

/// The writes inside a construct, merged by binding; `all` for a `raw`
/// block, after which no fact is kept.
const Kills = struct {
    all: bool = false,
    effects: std.ArrayList(Effect) = .empty,

    fn add(k: *Kills, a: std.mem.Allocator, e: Effect) !void {
        for (k.effects.items) |*x| if (x.sym == e.sym) {
            x.keeps_nonneg = x.keeps_nonneg and e.keeps_nonneg;
            x.keeps_len = x.keeps_len and e.keeps_len;
            return;
        };
        try k.effects.append(a, e);
    }

    fn effectOn(k: *const Kills, sym: SymbolId) ?Effect {
        for (k.effects.items) |e| if (e.sym == sym) return e;
        return null;
    }
};

pub const Error = std.mem.Allocator.Error;

const Pass = struct {
    ctx: *SemContext,
    a: std.mem.Allocator,
    /// The scope of the function or closure whose body is being walked:
    /// a fact names only that body's own locals and parameters.
    body_root: ?ScopeId = null,
    /// What the walk proved of each node, before it is recorded: a node
    /// reached twice keeps only what both visits proved.
    proven: std.AutoHashMapUnmanaged(sema.NodeKey, Proven) = .empty,
    /// The writes under each list node (`killsOf`), computed once.
    kills_memo: std.AutoHashMapUnmanaged(sema.NodeKey, Kills) = .empty,
    /// When set, each assignment's node id, in the order the walk visits
    /// it outside closures and defers (`walkOrder`).
    trace: ?*std.ArrayList(sema.NodeKey) = null,
    /// Closures and defers being walked around the current point.
    untraced: u32 = 0,

    // ------------------------------------------------------------------
    // Subjects and bounds (positive lists)
    // ------------------------------------------------------------------

    fn source(p: *const Pass) []const u8 {
        return p.ctx.source;
    }

    /// A local or parameter of the body being walked: not a capture, a
    /// field, a module constant, or another body's binding.
    fn ownBinding(p: *const Pass, sym: SymbolId) bool {
        const s = p.ctx.symbols.items[sym];
        if (s.kind != .local and s.kind != .param) return false;
        const root = p.body_root orelse return false;
        return p.ctx.bodyRoot(s.scope) == root;
    }

    /// `i`, a binding a fact may be about, and `n` of a bound `int(n)`:
    /// an own binding of type `Int` (not a view of one).
    fn intLocal(p: *const Pass, e: Sexp) ?SymbolId {
        if (e != .src) return null;
        const sym = p.ctx.symbolOf(e) orelse return null;
        if (!p.ownBinding(sym)) return null;
        if (p.ctx.symbols.items[sym].ty != p.ctx.types.int_id) return null;
        return sym;
    }

    /// `s` of a bound `len(s)`: an own binding that is a slice view, a
    /// `?String`, `[]T`, or `![]T`, whose length changes only when the
    /// binding is assigned.
    fn sliceView(p: *const Pass, e: Sexp) ?SymbolId {
        if (e != .src) return null;
        const sym = p.ctx.symbolOf(e) orelse return null;
        if (!p.ownBinding(sym)) return null;
        const ty = p.ctx.symbols.items[sym].ty;
        const types = &p.ctx.types;
        switch (types.get(ty)) {
            .string_view, .slice => {},
            .write_view => |inner| if (types.get(inner) != .slice) return null,
            else => return null,
        }
        return sym;
    }

    /// An integer literal written in decimal, hex, octal, or binary.
    fn intLiteral(p: *const Pass, e: Sexp) ?u64 {
        if (e != .src) return null;
        const text = sema.identAt(p.source(), e) orelse return null;
        if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
        return std.fmt.parseInt(u64, text, 0) catch null;
    }

    /// `s.len` of a slice view.
    fn lenOf(p: *const Pass, e: Sexp) ?SymbolId {
        if (!e.isKind(.member)) return null;
        const name = sema.identAt(p.source(), ir.Member.name(e)) orelse return null;
        if (!std.mem.eql(u8, name, "len")) return null;
        return p.sliceView(ir.Member.object(e));
    }

    /// A bound as a guard writes it: `s.len`, or a bare `n`.
    fn boundOf(p: *const Pass, e: Sexp) ?Bound {
        if (p.lenOf(e)) |s| return .{ .len = s };
        if (p.intLocal(e)) |n| return .{ .int = n };
        return null;
    }

    /// `i + c` (or `c + i`) with a literal `c`, of type `Int`: the
    /// binding and the constant. `+%` is another node and never counts.
    fn plusConst(p: *const Pass, e: Sexp, either_order: bool) ?struct { i: SymbolId, c: u64 } {
        if (!e.isKind(.@"+")) return null;
        if (p.ctx.typeOf(e) != p.ctx.types.int_id) return null;
        const l = ir.get(e, .left);
        const r = ir.get(e, .right);
        if (p.intLocal(l)) |i| if (p.intLiteral(r)) |c| return .{ .i = i, .c = c };
        if (either_order) if (p.intLocal(r)) |i| if (p.intLiteral(l)) |c| return .{ .i = i, .c = c };
        return null;
    }

    /// The size in bytes of the number type a `read` or `write` names,
    /// when it is concrete.
    fn numSize(p: *const Pass, ty: sema.TypeId) ?u64 {
        return switch (p.ctx.types.get(ty)) {
            .int => |info| info.width() / 8,
            .float => |info| (if (info.bits == 0) 64 else info.bits) / 8,
            else => null,
        };
    }

    // ------------------------------------------------------------------
    // Writes
    // ------------------------------------------------------------------

    /// What the write at `node` does to the facts about `w.sym`.
    fn effectOf(p: *const Pass, node: Sexp, w: sema.WriteSite) Effect {
        return .{
            .sym = w.sym,
            .keeps_nonneg = p.isAdditive(node, w),
            .keeps_len = w.kind == .lend_write or w.kind == .elem_store,
        };
    }

    /// `i += c` or `i = i + c`, `c` a literal `>= 0`.
    fn isAdditive(p: *const Pass, node: Sexp, w: sema.WriteSite) bool {
        if (!node.isKind(.set)) return false;
        const target = ir.Set.target(node);
        if (target != .src or p.ctx.symbolOf(target) != w.sym) return false;
        const value = ir.Set.value(node);
        return switch (w.kind) {
            .compound => rig.bindingKindOf(ir.Set.op(node)) == .@"+=" and
                (if (p.intLiteral(value)) |c| c <= max_k else false),
            .assign => if (p.plusConst(value, false)) |pc| pc.i == w.sym and pc.c <= max_k else false,
            else => false,
        };
    }

    /// Every write under `node`, `node` included.
    fn killsOf(p: *Pass, node: Sexp) Error!Kills {
        const key: ?sema.NodeKey = if (node == .list and node.list.id != 0) node.list.id else null;
        if (key) |k| if (p.kills_memo.get(k)) |hit| return hit;
        var out: Kills = .{};
        try p.collectKills(node, &out);
        if (key) |k| try p.kills_memo.put(p.a, k, out);
        return out;
    }

    fn collectKills(p: *Pass, node: Sexp, out: *Kills) Error!void {
        if (node != .list) return;
        if (node.isKind(.raw_block)) {
            out.all = true;
            return;
        }
        if (p.ctx.writeSiteOf(node)) |w| try out.add(p.a, p.effectOf(node, w));
        for (node.items()) |c| try p.collectKills(c, out);
    }

    /// End every fact a write in `k` may have made false.
    fn applyKills(st: *State, k: *const Kills) void {
        if (k.all) return st.clear();
        if (k.effects.items.len == 0) return;
        var keep: usize = 0;
        for (st.facts.items) |f| {
            const dies = switch (f) {
                .nonneg => |i| if (k.effectOn(i)) |e| !e.keeps_nonneg else false,
                .fits => |s| if (k.effectOn(s)) |e| !e.keeps_len else false,
                .below => |b| k.effectOn(b.i) != null or switch (b.b) {
                    .len => |s| if (k.effectOn(s)) |e| !e.keeps_len else false,
                    .int => |n| k.effectOn(n) != null,
                },
            };
            if (!dies) {
                st.facts.items[keep] = f;
                keep += 1;
            }
        }
        st.facts.shrinkRetainingCapacity(keep);
    }

    fn applyEffect(p: *Pass, st: *State, e: Effect) Error!void {
        var k: Kills = .{};
        try k.add(p.a, e);
        applyKills(st, &k);
    }

    // ------------------------------------------------------------------
    // Uses
    // ------------------------------------------------------------------

    fn record(p: *Pass, node: Sexp, proven: Proven) Error!void {
        const key: sema.NodeKey = if (node == .list and node.list.id != 0) node.list.id else return;
        const gop = try p.proven.getOrPut(p.a, key);
        if (gop.found_existing) {
            gop.value_ptr.lower = gop.value_ptr.lower and proven.lower;
            gop.value_ptr.upper = gop.value_ptr.upper and proven.upper;
            gop.value_ptr.no_overflow = gop.value_ptr.no_overflow and proven.no_overflow;
        } else gop.value_ptr.* = proven;
    }

    /// The bounds test of an index or byte access at `i` of `width`
    /// elements into `s`.
    fn rangeProven(st: *const State, i: SymbolId, s: SymbolId, width: u64) Proven {
        return .{
            .lower = st.hasNonneg(i),
            .upper = if (st.belowK(i, .{ .len = s })) |k| k >= width else false,
        };
    }

    /// Whether `i + c` fits: `i + c <= i + k <= b <= Int.max` under
    /// `below(i, k, b)` with `k >= c`, or, for a length bound,
    /// `i + c <= max_len + c <= Int.max` under `fits(s)`.
    fn addFits(st: *const State, i: SymbolId, c: u64) bool {
        if (c == 0 or c > max_k) return false;
        for (st.facts.items) |f| if (f == .below and f.below.i == i) {
            if (f.below.k >= c) return true;
            if (f.below.b == .len and st.hasFits(f.below.b.len)) return true;
        };
        return false;
    }

    /// Record what `node` proves, from the facts that hold where it runs.
    fn recordUse(p: *Pass, node: Sexp, st: *const State) Error!void {
        switch (node.kind() orelse return) {
            .index => {
                const index = ir.Index.index(node);
                const s = p.sliceView(ir.Index.object(node)) orelse return;
                const i = p.intLocal(index) orelse return;
                try p.record(node, rangeProven(st, i, s, 1));
            },
            .call => {
                const callee = p.ctx.calleeOf(node);
                const ec = p.ctx.elemCallOf(callee) orelse return;
                if (ec.op != .read and ec.op != .write) return;
                const width = p.numSize(ec.num) orelse return;
                var obj = ir.Member.object(callee);
                if (ec.op == .write and obj.isKind(.write)) obj = ir.Write.operand(obj);
                const s = p.sliceView(obj) orelse return;
                const args = ir.Call.args(node);
                if (args.len == 0) return;
                const i = p.intLocal(args[0]) orelse return;
                try p.record(callee, rangeProven(st, i, s, width));
            },
            .@"+" => {
                const pc = p.plusConst(node, false) orelse return;
                try p.record(node, .{ .no_overflow = addFits(st, pc.i, pc.c) });
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Facts a guard or a check makes (gen)
    // ------------------------------------------------------------------

    /// G1: a guard, on its true edge. `e` is a comparison; either way
    /// round, `i < b`, `i <= b`, `i + k < b`, `i + k <= b`, and `0 <= i`,
    /// `0 < i`.
    fn genGuard(p: *Pass, e: Sexp, st: *State) Error!void {
        const kind = e.kind() orelse return;
        const strict, const swap = switch (kind) {
            .@"<" => .{ true, false },
            .@"<=" => .{ false, false },
            .@">" => .{ true, true },
            .@">=" => .{ false, true },
            else => return,
        };
        var lo = ir.get(e, .left);
        var hi = ir.get(e, .right);
        if (swap) std.mem.swap(Sexp, &lo, &hi);
        // `0 <= i`, `0 < i`.
        if (p.intLiteral(lo)) |z| if (z == 0) if (p.intLocal(hi)) |i| return st.add(p.a, .{ .nonneg = i });
        const b = p.boundOf(hi) orelse return;
        const i: SymbolId, const k: u64 = if (p.intLocal(lo)) |i|
            .{ i, 0 }
        else if (p.plusConst(lo, true)) |pc|
            .{ pc.i, pc.c }
        else
            return;
        if (k > max_k) return;
        try st.add(p.a, .{ .below = .{ .i = i, .k = @min(k + @intFromBool(strict), max_k), .b = b } });
    }

    /// G2: a check that ran. After `x = s[i]`, `x = s.read[T, e](i)`, or
    /// the statement `!s.write[T, e](i, v)`, the test passed (or the
    /// program stopped): `0 <= i` and `i + width <= s.len`.
    fn genCheck(p: *Pass, value: Sexp, st: *State) Error!void {
        const i: SymbolId, const s: SymbolId, const width: u64 = switch (value.kind() orelse return) {
            .index => .{
                p.intLocal(ir.Index.index(value)) orelse return,
                p.sliceView(ir.Index.object(value)) orelse return,
                1,
            },
            .call => blk: {
                const callee = p.ctx.calleeOf(value);
                const ec = p.ctx.elemCallOf(callee) orelse return;
                if (ec.op != .read and ec.op != .write) return;
                var obj = ir.Member.object(callee);
                if (ec.op == .write and obj.isKind(.write)) obj = ir.Write.operand(obj);
                const args = ir.Call.args(value);
                if (args.len == 0) return;
                break :blk .{
                    p.intLocal(args[0]) orelse return,
                    p.sliceView(obj) orelse return,
                    p.numSize(ec.num) orelse return,
                };
            },
            else => return,
        };
        try st.add(p.a, .{ .nonneg = i });
        try st.add(p.a, .{ .below = .{ .i = i, .k = width, .b = .{ .len = s } } });
    }

    // ------------------------------------------------------------------
    // The walk, in the order the emitted Zig runs
    // ------------------------------------------------------------------

    fn walk(p: *Pass, node: Sexp, st: *State) Error!void {
        if (node != .list) return;
        const kind = node.kind() orelse {
            for (node.items()) |c| try p.walk(c, st);
            return;
        };
        switch (kind) {
            .block => try p.walkBlock(node, st),
            .set => try p.walkSet(node, st),
            .@"if" => try p.walkIf(node, st),
            .@"while" => try p.walkWhile(node, st),
            .@"for" => try p.walkFor(node, st),
            .match => try p.walkMatch(node, st),
            .labeled => {
                const stmt = ir.Labeled.stmt(node);
                if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) return p.walk(stmt, st);
                try p.walkJoin(node, st, &.{stmt});
            },
            // The right operand runs only on one edge of the left: a
            // value of `and` keeps only the facts true on both.
            .@"and" => {
                var t = try st.clone(p.a);
                try p.walkGuard(node, &t);
                applyKills(st, &(try p.killsOf(node)));
            },
            .@"or", .@"??" => try p.walkJoin(node, st, &.{ ir.get(node, .left), ir.get(node, .right) }),
            .@"catch" => try p.walkJoin(node, st, &.{ ir.Catch.value(node), ir.Catch.handler(node) }),
            .@"return", .@"break", .@"continue" => {
                for (rig.children(node)) |c| try p.walk(c, st);
                // What follows a jump does not run.
                st.clear();
            },
            .lambda => try p.walkLambda(node, st),
            // Nothing inside `raw` is proven, and no fact outlives it.
            .raw_block => st.clear(),
            .@"defer", .@"errdefer" => try p.walkDeferBody(node),
            else => try p.walkAtomic(node, st),
        }
    }

    /// An expression whose parts run in an order this pass does not rely
    /// on: every write in it ends its facts before any part is read, and
    /// again after.
    fn walkAtomic(p: *Pass, node: Sexp, st: *State) Error!void {
        const kills = try p.killsOf(node);
        applyKills(st, &kills);
        // Each part starts from the facts before the expression, so no part
        // relies on another having run first; what each makes holds once
        // all have run.
        const pre = try st.clone(p.a);
        for (rig.children(node)) |c| {
            var part = try pre.clone(p.a);
            try p.walk(c, &part);
            for (part.facts.items) |f| try st.add(p.a, f);
        }
        try p.recordUse(node, st);
        // G4: a length read ran `rig.len`'s test.
        if (p.lenOf(node)) |s| try st.add(p.a, .{ .fits = s });
        applyKills(st, &kills);
    }

    /// `parts` run in order, each maybe not at all: afterwards, the facts
    /// from before `node` less every write inside it.
    fn walkJoin(p: *Pass, node: Sexp, st: *State, parts: []const Sexp) Error!void {
        var t = try st.clone(p.a);
        for (parts) |part| try p.walk(part, &t);
        applyKills(st, &(try p.killsOf(node)));
    }

    fn walkBlock(p: *Pass, node: Sexp, st: *State) Error!void {
        var defers: std.ArrayList(Sexp) = .empty;
        for (ir.Block.stmts(node)) |stmt| {
            if (stmt.isKind(.@"defer") or stmt.isKind(.@"errdefer")) {
                try p.walkDeferBody(stmt);
                try defers.append(p.a, stmt);
                continue;
            }
            try p.walk(stmt, st);
            // G2: the statement `!s.write[T, e](i, v)`, when nothing in it
            // writes `i` or `s`.
            if (stmt.isKind(.call) and p.ctx.elemCallOf(p.ctx.calleeOf(stmt)) != null) {
                const kills = try p.killsOf(stmt);
                var fresh: State = .{};
                try p.genCheck(stmt, &fresh);
                if (!kills.all) for (fresh.facts.items) |f| {
                    const touched = switch (f) {
                        .nonneg => |i| kills.effectOn(i) != null,
                        .below => |b| kills.effectOn(b.i) != null or (if (kills.effectOn(b.b.sym())) |e| !e.keeps_len else false),
                        .fits => unreachable,
                    };
                    if (!touched) try st.add(p.a, f);
                };
            }
        }
        // The block's defers run where it ends.
        for (defers.items) |d| applyKills(st, &(try p.killsOf(d)));
    }

    /// A `defer` or `errdefer` body runs at its scope's exits, from facts
    /// this pass does not track: it is walked from none.
    fn walkDeferBody(p: *Pass, node: Sexp) Error!void {
        p.untraced += 1;
        defer p.untraced -= 1;
        var fresh: State = .{};
        try p.walk(ir.get(node, .body), &fresh);
    }

    /// An assignment: its value, then its target's indexes, then the
    /// store (docs/INTERNALS.md, "Assignments").
    fn walkSet(p: *Pass, node: Sexp, st: *State) Error!void {
        if (p.trace) |t| if (p.untraced == 0 and node == .list) try t.append(p.a, node.list.id);
        const target = ir.Set.target(node);
        const value = ir.Set.value(node);
        const kind = rig.bindingKindOf(ir.Set.op(node));
        const before = try st.clone(p.a);
        try p.walk(value, st);
        // G2, before the store, which may end what it gives.
        if (kind.operator() == null) try p.genCheck(value, st);
        // Emit finds the place after the value only when the value can act
        // (`actsBeforeStore`), and otherwise Zig may find it first: the
        // target's indexes see what holds either way, the facts from
        // before the value less what the value writes.
        if (target != .src) {
            var t = before;
            applyKills(&t, &(try p.killsOf(value)));
            try p.walk(target, &t);
            applyKills(st, &(try p.killsOf(target)));
        }
        // `i += c`: the add's own test.
        if (kind == .@"+=") if (p.intLocal(target)) |i| if (p.intLiteral(value)) |c| {
            try p.record(node, .{ .no_overflow = addFits(st, i, c) });
        };
        if (p.ctx.writeSiteOf(node)) |w| try p.applyEffect(st, p.effectOf(node, w));
        // G3: `i = c`, `i = s.len`, `i = j` with `0 <= j`.
        if (kind.operator() == null) if (p.intLocal(target)) |i| {
            const nonneg = if (p.intLiteral(value) != null)
                true
            else if (p.lenOf(value) != null)
                true
            else if (p.intLocal(value)) |j|
                j != i and st.hasNonneg(j)
            else
                false;
            if (nonneg) try st.add(p.a, .{ .nonneg = i });
        };
    }

    fn walkIf(p: *Pass, node: Sexp, st: *State) Error!void {
        const cond = ir.If.cond(node);
        var t = try st.clone(p.a);
        try p.walkCondParts(cond, &t);
        try p.walk(ir.If.then(node), &t);
        const else_b = ir.If.@"else"(node);
        if (else_b != .nil) {
            // A false edge gives nothing.
            var e = try st.clone(p.a);
            applyKills(&e, &(try p.killsOf(cond)));
            try p.walk(else_b, &e);
        }
        applyKills(st, &(try p.killsOf(node)));
    }

    /// A condition's parts in order: an `as` part's value, and each
    /// guard, whose facts the parts after it see.
    fn walkCondParts(p: *Pass, cond: Sexp, t: *State) Error!void {
        if (rig.isConditionJoin(cond)) {
            try p.walkCondParts(ir.get(cond, .left), t);
            return p.walkCondParts(ir.get(cond, .right), t);
        }
        if (cond.isKind(.as)) return p.walk(ir.As.value(cond), t);
        try p.walkGuard(cond, t);
    }

    /// A guard, leaving `t` as the facts on its true edge: each part of
    /// an `and` chain sees the parts before it.
    fn walkGuard(p: *Pass, e: Sexp, t: *State) Error!void {
        if (e.isKind(.@"and")) {
            try p.walkCondParts(ir.get(e, .left), t);
            return p.walkCondParts(ir.get(e, .right), t);
        }
        try p.walk(e, t);
        try p.genGuard(e, t);
    }

    /// `while cond : step` (docs/INTERNALS.md, "Loops"): the condition
    /// parts, the body, then the step, each iteration.
    fn walkWhile(p: *Pass, node: Sexp, st: *State) Error!void {
        const cond = ir.While.cond(node);
        const step = ir.While.step(node);
        const body = ir.While.body(node);
        // A fact holds at every iteration's start only if nothing in the
        // loop writes what it names.
        var entry = try st.clone(p.a);
        applyKills(&entry, &(try p.killsOf(cond)));
        applyKills(&entry, &(try p.killsOf(step)));
        applyKills(&entry, &(try p.killsOf(body)));
        var t = try entry.clone(p.a);
        try p.walkCondParts(cond, &t);
        var b = try t.clone(p.a);
        try p.walk(body, &b);
        // The step, and a `continue` to it, follow some of the body; a
        // `continue` in the condition reaches it before the guard holds.
        if (step != .nil) {
            var s = try (if (hasContinue(cond)) entry else t).clone(p.a);
            applyKills(&s, &(try p.killsOf(body)));
            try p.walk(step, &s);
        }
        const else_b = ir.While.@"else"(node);
        if (else_b != .nil) {
            var e = try entry.clone(p.a);
            try p.walk(else_b, &e);
        }
        applyKills(st, &(try p.killsOf(node)));
    }

    /// Whether `node` holds a `continue`.
    fn hasContinue(node: Sexp) bool {
        if (node != .list) return false;
        if (node.isKind(.@"continue")) return true;
        for (node.items()) |c| if (hasContinue(c)) return true;
        return false;
    }

    /// `for`: its source once, then the body each iteration. A `for`
    /// binding gets no facts.
    fn walkFor(p: *Pass, node: Sexp, st: *State) Error!void {
        const body = ir.For.body(node);
        var t = try st.clone(p.a);
        try p.walk(ir.For.source(node), &t);
        // `for x in !xs` lends its source to write for the whole loop.
        if (p.ctx.writeSiteOf(node)) |w| try p.applyEffect(&t, p.effectOf(node, w));
        applyKills(&t, &(try p.killsOf(body)));
        var b = try t.clone(p.a);
        try p.walk(body, &b);
        const else_b = ir.For.@"else"(node);
        if (else_b != .nil) {
            var e = try t.clone(p.a);
            try p.walk(else_b, &e);
        }
        applyKills(st, &(try p.killsOf(node)));
    }

    /// `match`: its subject, then the arms. An arm runs after the guards
    /// of the arms before it failed, so each starts with what no guard
    /// writes.
    fn walkMatch(p: *Pass, node: Sexp, st: *State) Error!void {
        var t = try st.clone(p.a);
        try p.walk(ir.Match.subject(node), &t);
        for (ir.Match.arms(node)) |arm| applyKills(&t, &(try p.killsOf(ir.Arm.guard(arm))));
        for (ir.Match.arms(node)) |arm| {
            var a = try t.clone(p.a);
            try p.walk(ir.Arm.guard(arm), &a);
            try p.walk(ir.Arm.body(arm), &a);
        }
        applyKills(st, &(try p.killsOf(node)));
    }

    /// A closure's body starts with no facts; making it is the writes its
    /// `|!x|` captures make.
    fn walkLambda(p: *Pass, node: Sexp, st: *State) Error!void {
        p.untraced += 1;
        defer p.untraced -= 1;
        try p.walkBody(node, ir.Lambda.body(node));
        applyKills(st, &(try p.killsOf(ir.Lambda.captures(node))));
    }

    /// A function's or closure's body, from no facts.
    fn walkBody(p: *Pass, owner: Sexp, body: Sexp) Error!void {
        if (body == .nil) return;
        const saved = p.body_root;
        defer p.body_root = saved;
        p.body_root = p.ctx.scopeOf(owner);
        var fresh: State = .{};
        try p.walk(body, &fresh);
    }

    fn walkDecl(p: *Pass, decl: Sexp) Error!void {
        switch (decl.kind() orelse return) {
            .@"pub" => try p.walkDecl(ir.Pub.decl(decl)),
            .fun, .sub, .drop_decl, .@"test" => try p.walkBody(decl, ir.get(decl, .body)),
            .@"struct", .@"enum", .generic_struct, .generic_enum => for (ir.rest(decl, .members)) |m| try p.walkDecl(m),
            else => {},
        }
    }
};

/// Record the tests each node of a module the ownership checker accepted
/// is known to pass (`SemContext.provenOf`).
pub fn check(ctx: *SemContext, root: Sexp) Error!void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var p: Pass = .{ .ctx = ctx, .a = arena.allocator() };
    if (root.kind() == .module) {
        for (ir.Module.decls(root)) |d| try p.walkDecl(d);
    }
    var it = p.proven.iterator();
    while (it.next()) |e| if (e.value_ptr.any()) try ctx.proven.put(ctx.allocator, e.key_ptr.*, e.value_ptr.*);
}

/// The assignments of a module's functions, outside closures and defers,
/// in the order the pass walks them (appended to `out`, in `a`).
pub fn walkOrder(ctx: *SemContext, a: std.mem.Allocator, root: Sexp, out: *std.ArrayList(sema.NodeKey)) Error!void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var trace: std.ArrayList(sema.NodeKey) = .empty;
    var p: Pass = .{ .ctx = ctx, .a = arena.allocator(), .trace = &trace };
    if (root.kind() == .module) {
        for (ir.Module.decls(root)) |d| try p.walkDecl(d);
    }
    try out.appendSlice(a, trace.items);
}

/// `rig check --facts=proofs`: each node with a test known to pass, one
/// per line in source order, as `L:C KIND TESTS`: `index`, `read`,
/// `write`, `+`, or `+=`, then which of `lower`, `upper`, and
/// `no_overflow` are proven.
pub fn writeDump(ctx: *const SemContext, a: std.mem.Allocator, root: Sexp, w: *std.Io.Writer) !void {
    const Line = struct {
        start: u32,
        text: []const u8,

        fn lessThan(_: void, x: @This(), y: @This()) bool {
            if (x.start != y.start) return x.start < y.start;
            return std.mem.order(u8, x.text, y.text) == .lt;
        }
    };
    var out: std.ArrayList(Line) = .empty;
    var lines: diag.Lines = .{ .source = ctx.source };
    var stack: std.ArrayList(Sexp) = .empty;
    try stack.append(a, root);
    while (stack.pop()) |n| {
        if (n != .list) continue;
        try stack.appendSlice(a, n.list.items());
        const p = ctx.provenOf(n);
        if (!p.any()) continue;
        const kind: []const u8 = switch (n.kind() orelse continue) {
            .index => "index",
            .@"+" => "+",
            .set => "+=",
            .member => sema.identAt(ctx.source, ir.Member.name(n)) orelse "member",
            else => @tagName(n.kind().?),
        };
        const span = if (ctx.parser) |pr| pr.base.span(n) else diag.leafSpan(n);
        var text: std.Io.Writer.Allocating = .init(a);
        const t = &text.writer;
        const lc = lines.at(span.start);
        try t.print("{d}:{d} {s}", .{ lc.line, lc.col, kind });
        if (p.lower) try t.writeAll(" lower");
        if (p.upper) try t.writeAll(" upper");
        if (p.no_overflow) try t.writeAll(" no_overflow");
        try out.append(a, .{ .start = span.start, .text = text.written() });
    }
    std.mem.sort(Line, out.items, {}, Line.lessThan);
    for (out.items) |l| try w.print("{s}\n", .{l.text});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const ownership = @import("ownership.zig");

/// The `--facts=proofs` dump of a one-module program the checkers accept.
fn dumpOf(source: []const u8) ![]u8 {
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var ctx = try sema.check(a, source, tree, .{ .parser = &p, .is_root = true });
    defer ctx.deinit();
    var own = try ownership.Checker.initWithSema(a, source, &ctx);
    defer own.deinit();
    try own.check(tree);
    if (ctx.hasErrors() or own.diagnostics.items.len > 0) {
        for (ctx.diagnostics.items) |d| std.debug.print("sema: {s}\n", .{d.message});
        for (own.diagnostics.items) |d| std.debug.print("ownership: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
    try check(&ctx, tree);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeDump(&ctx, arena.allocator(), tree, &out.writer);
    return a.dupe(u8, out.written());
}

fn expectDump(source: []const u8, expected: []const u8) !void {
    const got = try dumpOf(source);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "G1: each guard shape, either way round, on its true edge" {
    // `i < b` and `b > i`: room for one element.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U8
        \\  if i < s.len
        \\    return s[i]
        \\  if s.len > i
        \\    return s[i]
        \\  0
        \\
    ,
        \\3:12 index upper
        \\5:12 index upper
        \\
    );
    // `i <= b`: no room, so no element, but `i + 1` fits under a length.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> Int
        \\  if i <= s.len
        \\    print(s[i])
        \\    return i + 1
        \\  0
        \\
    ,
        \\4:12 + no_overflow
        \\
    );
    // `i + k < b`, `k + i <= b`, `b >= i + k`: room for `k + 1`, `k`, `k`.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U32
        \\  if i + 3 < s.len
        \\    return s.read[U32, .little](i)
        \\  if 4 + i <= s.len
        \\    return s.read[U32, .little](i)
        \\  if s.len >= i + 4
        \\    return s.read[U32, .little](i)
        \\  if i + 3 <= s.len
        \\    return s.read[U32, .little](i)
        \\  0
        \\
    ,
        \\3:12 read upper
        \\5:12 read upper
        \\7:12 read upper
        \\
    );
    // `0 <= i`, `i >= 0`, `0 < i`, `i > 0`: the sign.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U8
        \\  if 0 <= i
        \\    print(s[i])
        \\  if i >= 0
        \\    print(s[i])
        \\  if 0 < i
        \\    print(s[i])
        \\  if i > 0
        \\    print(s[i])
        \\  0
        \\
    ,
        \\3:11 index lower
        \\5:11 index lower
        \\7:11 index lower
        \\9:11 index lower
        \\
    );
    // An `Int` bound proves an add, not an index.
    try expectDump(
        \\fun f(s: ?String, i: Int, n: Int) -> Int
        \\  if i < n
        \\    print(s[i])
        \\    return i + 1
        \\  0
        \\
    ,
        \\4:12 + no_overflow
        \\
    );
}

test "G1: a near miss proves nothing" {
    try expectDump(
        \\obj C
        \\  i: Int
        \\
        \\fun f(s: ?String, i: Int, u: U64, c: ?C) -> Int
        \\  if i - 1 < s.len
        \\    print(s[i])
        \\  if i < s.len + 0
        \\    print(s[i])
        \\  if i * 1 < s.len
        \\    print(s[i])
        \\  if i +% 1 <= s.len
        \\    print(s[i])
        \\  if not (i >= s.len)
        \\    print(s[i])
        \\  if i < s.len or i < 2
        \\    print(s[i])
        \\  if u < 3
        \\    print(s[u])
        \\  if c.i < s.len
        \\    print(s[c.i])
        \\  g = |+i, ?s| s[i] if i < s.len else 0
        \\  print(g())
        \\  0
        \\
    ,
        \\
    );
}

test "G2 and G3: a check that ran, and a non-negative assignment" {
    // `c = s[i]` shows `0 <= i` and room for one; a read, room for its
    // width; the statement `!s.write`, the same.
    try expectDump(
        \\sub f(s: ![]U8, i: Int)
        \\  c = s[i]
        \\  print(c, s[i], i + 1)
        \\  d = s.read[U32, .little](i)
        \\  print(d, s.read[U16, .little](i), i + 4)
        \\  !s.write[U64, .little](i, 0)
        \\  print(s.read[U64, .little](i))
        \\
    ,
        \\3:12 index lower upper
        \\3:18 + no_overflow
        \\4:7 read lower
        \\5:12 read lower upper
        \\5:37 + no_overflow
        \\6:4 write lower
        \\7:9 read lower upper
        \\
    );
    // `i = c`, `i = s.len`, and `i = j` with `0 <= j`.
    try expectDump(
        \\fun f(s: ?String, at: Int) -> U8
        \\  i = 0
        \\  print(s[i])
        \\  i = s.len
        \\  print(s[i])
        \\  j = at
        \\  i = j
        \\  print(s[i])
        \\  k = i
        \\  print(s[k], s[j])
        \\  0
        \\
    ,
        \\3:9 index lower
        \\5:9 index lower
        \\
    );
    // A check whose value assigns its own index keeps none of its facts.
    try expectDump(
        \\fun f(s: ?String, at: Int) -> U8
        \\  i: Int = at
        \\  i = Int(s[i])
        \\  s[i]
        \\
    ,
        \\
    );
}

test "kills: each write site ends what it names" {
    // `i = e`, `i op= e`, `!i`, a write capture, and `raw` end every fact
    // about `i`; `i += c` keeps only `0 <= i`.
    try expectDump(
        \\sub bump(n: !Int)
        \\  n += 1
        \\
        \\fun f(s: ?String) -> Int
        \\  i = 0
        \\  if i < s.len
        \\    i = i + 1
        \\    print(s[i])
        \\  if i < s.len
        \\    i += 1
        \\    print(s[i])
        \\  if i < s.len
        \\    i -= 1
        \\    print(s[i])
        \\  if i < s.len
        \\    bump(!i)
        \\    print(s[i])
        \\  if i < s.len
        \\    g = |!i| i += 1
        \\    g()
        \\    print(s[i])
        \\  if i < s.len
        \\    raw
        \\      print(1)
        \\    print(s[i])
        \\  i
        \\
    ,
        \\7:9 + no_overflow
        \\8:11 index lower
        \\10:5 += no_overflow
        \\11:11 index lower
        \\
    );
    // Re-pointing `s` ends what its length bounded; writing through it
    // does not.
    try expectDump(
        \\sub f(s: ![]U8, t: ?String, i: Int)
        \\  if i < s.len
        \\    s[0] = 1
        \\    !s.write[U8, .little](0, 2)
        \\    print(s[i])
        \\  u = t
        \\  if i < u.len
        \\    u = t[..1]
        \\    print(u[i])
        \\
    ,
        \\5:11 index upper
        \\
    );
}

test "joins: a fact made in a branch ends with it; a loop keeps only what it does not write" {
    try expectDump(
        \\fun f(s: ?String, at: Int, k: Int) -> Int
        \\  i = at
        \\  if k > 0
        \\    i = 0
        \\  print(s[i])
        \\  j = 0
        \\  while j < k
        \\    print(s[j])
        \\    j += 1
        \\  n = 0
        \\  while n < k : n += 1
        \\    print(s[n])
        \\  i + j + n
        \\
    ,
        \\8:11 index lower
        \\9:5 += no_overflow
        \\11:17 += no_overflow
        \\12:11 index lower
        \\
    );
}

/// The assignments of a module's functions, outside closures, defers,
/// and `raw` blocks, in source order: the ones both the walk and emit's
/// trace hold.
fn collectSets(a: std.mem.Allocator, node: Sexp, out: *std.AutoHashMapUnmanaged(sema.NodeKey, void)) !void {
    if (node != .list) return;
    if (node.kind()) |k| switch (k) {
        .lambda, .@"defer", .@"errdefer", .raw_block => return,
        .set => try out.put(a, node.list.id, {}),
        else => {},
    };
    for (node.items()) |c| try collectSets(a, c, out);
}

fn collectBodies(a: std.mem.Allocator, decl: Sexp, out: *std.AutoHashMapUnmanaged(sema.NodeKey, void)) !void {
    switch (decl.kind() orelse return) {
        .@"pub" => try collectBodies(a, ir.Pub.decl(decl), out),
        .fun, .sub, .drop_decl, .@"test" => try collectSets(a, ir.get(decl, .body), out),
        .@"struct", .@"enum", .generic_struct, .generic_enum => for (ir.rest(decl, .members)) |m| try collectBodies(a, m, out),
        else => {},
    }
}

test "the walk visits each assignment where the emitted Zig runs it" {
    // Every program of test/behavior/emit: the order in which the pass
    // walks the assignments of each function body (a loop's condition,
    // its body, then its step; each branch in turn) is the order emit
    // writes them, with a step Zig runs as a loop's continue expression
    // placed after the body, where it runs. Closures, defers, and `raw`
    // blocks are left out of both: the pass walks the first two from no
    // facts, and proves nothing in the third.
    const emit = @import("emit.zig");
    const facts = @import("facts.zig");
    const modules = @import("modules.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "test/behavior/emit", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".rig")) try std.fs.path.join(a, &.{ "test/behavior/emit", entry.name }) else continue,
            .directory => try std.fs.path.join(a, &.{ "test/behavior/emit", entry.name, "main.rig" }),
            else => continue,
        };
        try names.append(a, path);
    }
    try std.testing.expect(names.items.len > 100);
    var compared: usize = 0;
    for (names.items) |path| {
        var graph = modules.ModuleGraph.init(a, io);
        defer graph.deinit();
        graph.loadRoot(path) catch continue;
        if (graph.hasErrors()) continue;
        const m = graph.root();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var eligible: std.AutoHashMapUnmanaged(sema.NodeKey, void) = .empty;
        if (m.ir.kind() == .module) for (ir.Module.decls(m.ir)) |d| try collectBodies(aa, d, &eligible);
        var walked: std.ArrayList(sema.NodeKey) = .empty;
        try walkOrder(m.sema, aa, m.ir, &walked);
        var emitted: std.ArrayList(u32) = .empty;
        defer emitted.deinit(a);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var em = emit.Emitter.init(a, m.source, &out.writer, facts.Facts.of(m.sema));
        defer em.deinit();
        em.trace = &emitted;
        try em.emit(m.ir);
        var want: std.ArrayList(sema.NodeKey) = .empty;
        for (emitted.items) |id| if (eligible.contains(id)) try want.append(aa, id);
        var got: std.ArrayList(sema.NodeKey) = .empty;
        for (walked.items) |id| if (eligible.contains(id)) try got.append(aa, id);
        std.testing.expectEqualSlices(sema.NodeKey, want.items, got.items) catch |err| {
            std.debug.print("{s}: the walk's assignments differ from emit's\n", .{path});
            return err;
        };
        compared += 1;
    }
    try std.testing.expect(compared > 100);
}
