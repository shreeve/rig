//! Proven checks: which of a node's tests are known to pass
//! (docs/internals/INTERNALS.md, "Proven checks").
//!
//! A check is the test an operation makes before it acts: `s[i]` tests
//! `0 <= i` and `i < s.len`, `s.read[T, e](i)` tests `0 <= i` and
//! `i + @size(T) <= s.len`, and `i + c` tests that the sum fits. This pass
//! runs on a module the ownership checker accepted and records on each
//! such node the tests that a guard or a check already made, on every
//! path to it, about values nothing has written since
//! (`SemContext.recordProven`). Emit omits those tests; a debug build
//! still makes each one, as an assertion of the proof.
//!
//! The pass tracks five facts about bindings, by symbol:
//!
//! - `nonneg(i)`: `0 <= i`;
//! - `below(i, k, b)`: `i + k <= b`, exactly, where the bound `b` is
//!   `len(s)`, the length of a slice view `s`, or `int(n)`, the value of
//!   an `Int` binding `n`;
//! - `fits(s)`: `s.len <= max_len`, which holds where a length is read
//!   (`rig.lenOf`: by construction, or tested);
//! - `eq(n, s)`: `n == s.len`, after `n = s.len`;
//! - `upto(d, f, h)`: `0 <= d.f <= h`, after `d = g(...)` where `g`
//!   bounds the field `f` of its result.
//!
//! What a function bounds of its result (`sema.ResultBound`) is found
//! first, for every function of the module, from its return values:
//! each is a literal, a constructor whose field is a literal, or a call
//! of a function that bounds the same (`Summaries`). A caller's add
//! `i + x` is proven when `x` is such a field or result and `i` has room
//! below a bound.
//!
//! A body is cut into units (`rig.eachUnit`): a statement, a guard part,
//! a `while` step, a `for` source, a `match`'s selection, a `raw` block.
//! Inside a unit nothing is ordered: every check in unit `u` is proved
//! from the facts at its entry less every write anywhere in `u` (`A(u)`),
//! and a fact `u` makes (a guard, a check that ran, `i = 0`) holds only
//! once `u` is done, and only if `u` writes nothing it names. Between
//! units the walk follows the skeleton: block order, guard parts, the
//! loop step and the jumps to it (`JumpDest`), a selection before its
//! arms, the defers at a block's end. Where control flow joins, the facts
//! are those from before the construct less every write inside it. Emit
//! asserts that it writes each check, write, and hidden storage inside
//! the unit that holds it (`Emitter.inUnit`), so no order emit picks
//! inside a unit, and no hoist across units, goes unseen.
//!
//! What makes a fact, what a fact proves, and which writes end one are
//! positive lists: a shape not listed makes nothing and proves nothing.
//! Writes are the ones resolve and typecheck record (`recordWrite`).
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
const storage = @import("storage.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const NodeKey = sema.NodeKey;
const Proven = sema.Proven;
const UnitEvent = sema.UnitEvent;

/// The longest length a length read gives (`rig.lenOf`): no List grows
/// past it, and no target holds more.
pub const max_len: u64 = (1 << 62) - 1;
/// The largest constant a fact or a use names, so every sum the pass
/// reasons about fits in an `Int`.
pub const max_k: u64 = 1 << 62;

/// What a length bound is the length of: an own binding, or a List in a
/// field of one, reached through fields of objects held by value.
const Place = struct {
    root: SymbolId,
    /// The field path from the root (`Pass.paths`), 0 for the binding
    /// itself.
    path: u32 = 0,
    /// A List, whose length a write view of it may change; else a slice
    /// view, whose length only an assignment of the binding changes.
    list: bool = false,
};

const Bound = union(enum) {
    /// The length of a place.
    len: Place,
    /// The value of an `Int` binding.
    int: SymbolId,
};

const Below = struct { i: SymbolId, k: u64, b: Bound };

/// `0 <= d.name <= hi`, of a struct binding `d`.
const Upto = struct { d: SymbolId, name: []const u8, hi: u64 };

/// `n == s.len`.
const Eq = struct { n: SymbolId, s: Place };

const Fact = union(enum) {
    nonneg: SymbolId,
    below: Below,
    fits: Place,
    eq: Eq,
    upto: Upto,
};

/// A fact, and the flag it holds under: 0 for a fact of every path, or
/// the statement whose flag tested it (docs/internals/INTERNALS.md,
/// "Flags").
const Entry = struct { fact: Fact, flag: NodeKey = 0 };

/// The flag a fact made from facts under flags `x` and `y` holds under,
/// or null when they are two different flags.
fn joinFlags(x: NodeKey, y: NodeKey) ?NodeKey {
    if (x == 0) return y;
    if (y == 0 or y == x) return x;
    return null;
}

fn sameBelow(x: Below, i: SymbolId, b: Bound) bool {
    return x.i == i and std.meta.eql(x.b, b);
}

fn sameUpto(x: Upto, d: SymbolId, name: []const u8) bool {
    return x.d == d and std.mem.eql(u8, x.name, name);
}

/// The facts that hold at a point of the walk.
const State = struct {
    facts: std.ArrayList(Entry) = .empty,
    /// No path reaches the point: the identity of `meet`.
    dead: bool = false,

    fn clone(st: *const State, a: std.mem.Allocator) !State {
        return .{ .facts = try st.facts.clone(a), .dead = st.dead };
    }

    /// Whether `fact` holds on every path, or (`flag` not 0) while flag
    /// `flag` holds.
    fn holds(st: *const State, fact: Fact, flag: NodeKey) bool {
        for (st.facts.items) |e| if ((e.flag == 0 or e.flag == flag) and std.meta.eql(e.fact, fact)) return true;
        return false;
    }

    fn has(st: *const State, fact: Fact) bool {
        return st.holds(fact, 0);
    }

    fn hasNonneg(st: *const State, i: SymbolId, flag: NodeKey) bool {
        return st.holds(.{ .nonneg = i }, flag);
    }

    /// The flag `0 <= i` holds under: 0 on every path, else the first
    /// flag it holds under; null when it does not hold.
    fn nonnegFlag(st: *const State, i: SymbolId) ?NodeKey {
        var found: ?NodeKey = null;
        for (st.facts.items) |e| if (e.fact == .nonneg and e.fact.nonneg == i) {
            if (e.flag == 0) return 0;
            if (found == null) found = e.flag;
        };
        return found;
    }

    /// The largest `k` with `below(i, k, b)`, on every path or while flag
    /// `flag` holds, or null.
    fn belowK(st: *const State, i: SymbolId, b: Bound, flag: NodeKey) ?u64 {
        var best: ?u64 = null;
        for (st.facts.items) |e| if ((e.flag == 0 or e.flag == flag) and e.fact == .below and sameBelow(e.fact.below, i, b)) {
            best = @max(best orelse 0, e.fact.below.k);
        };
        return best;
    }

    /// The smallest `hi` of `upto(d, name, hi)` on every path, or null.
    fn uptoHi(st: *const State, d: SymbolId, name: []const u8) ?u64 {
        var best: ?u64 = null;
        for (st.facts.items) |e| if (e.flag == 0 and e.fact == .upto and sameUpto(e.fact.upto, d, name)) {
            best = @min(best orelse std.math.maxInt(u64), e.fact.upto.hi);
        };
        return best;
    }

    /// Add `fact` under `flag`, and what it gives with the facts held:
    /// `below(i, k, int(n))` with `eq(n, s)` is `below(i, k, len(s))`, and
    /// with `below(n, j, b)` it is `below(i, k + j, b)`.
    fn add(st: *State, a: std.mem.Allocator, fact: Fact, flag: NodeKey) std.mem.Allocator.Error!void {
        if (!try st.put(a, fact, flag)) return;
        switch (fact) {
            .below => |nb| try st.derive(a, nb, flag),
            .eq => |e| {
                var i: usize = 0;
                while (i < st.facts.items.len) : (i += 1) {
                    const f = st.facts.items[i];
                    if (f.fact == .below and f.fact.below.b == .int and f.fact.below.b.int == e.n) {
                        const tag = joinFlags(f.flag, flag) orelse continue;
                        try st.add(a, .{ .below = .{ .i = f.fact.below.i, .k = f.fact.below.k, .b = .{ .len = e.s } } }, tag);
                    }
                }
            },
            else => {},
        }
    }

    /// Record `fact` under `flag` unless what is held already gives it:
    /// one `below` per binding, bound, and flag (the largest `k`), and one
    /// `upto` per binding, field, and flag (the smallest `hi`). Whether
    /// it added anything.
    fn put(st: *State, a: std.mem.Allocator, fact: Fact, flag: NodeKey) std.mem.Allocator.Error!bool {
        switch (fact) {
            .nonneg, .fits, .eq => if (st.holds(fact, flag)) return false,
            .upto => |nu| for (st.facts.items) |*e| if (e.flag == flag and e.fact == .upto and sameUpto(e.fact.upto, nu.d, nu.name)) {
                if (nu.hi >= e.fact.upto.hi) return false;
                e.fact.upto.hi = nu.hi;
                return true;
            },
            .below => |nb| {
                if (st.belowK(nb.i, nb.b, flag)) |k| if (nb.k <= k) return false;
                for (st.facts.items) |*e| if (e.flag == flag and e.fact == .below and sameBelow(e.fact.below, nb.i, nb.b)) {
                    e.fact.below.k = nb.k;
                    return true;
                };
            },
        }
        try st.facts.append(a, .{ .fact = fact, .flag = flag });
        return true;
    }

    /// What `below(i, k, b)` gives with the facts held, one step: with
    /// `eq(n, s)` for `b = int(n)`, `below(i, k, len(s))`; with `below(n,
    /// j, c)` for `b = int(n)`, `below(i, k + j, c)`; and with `below(h, j,
    /// int(i))`, `below(h, j + k, b)`.
    fn derive(st: *State, a: std.mem.Allocator, nb: Below, flag: NodeKey) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < st.facts.items.len) : (i += 1) {
            const f = st.facts.items[i];
            const tag = joinFlags(f.flag, flag) orelse continue;
            switch (f.fact) {
                .eq => |e| if (nb.b == .int and e.n == nb.b.int)
                    try st.add(a, .{ .below = .{ .i = nb.i, .k = nb.k, .b = .{ .len = e.s } } }, tag),
                .below => |fb| {
                    if (nb.b == .int and fb.i == nb.b.int and fb.i != nb.i and nb.k + fb.k <= max_k)
                        _ = try st.put(a, .{ .below = .{ .i = nb.i, .k = nb.k + fb.k, .b = fb.b } }, tag);
                    if (fb.b == .int and fb.b.int == nb.i and fb.i != nb.i and nb.k + fb.k <= max_k)
                        _ = try st.put(a, .{ .below = .{ .i = fb.i, .k = fb.k + nb.k, .b = nb.b } }, tag);
                },
                else => {},
            }
        }
    }

    /// The facts both `x` and `y` hold: of each pair of entries about the
    /// same binding and bound, under one flag or none, the fact with the
    /// smaller `k` (`below`) or the larger `hi` (`upto`).
    fn meet(a: std.mem.Allocator, x: *const State, y: *const State) !State {
        if (x.dead) return y.clone(a);
        if (y.dead) return x.clone(a);
        var out: State = .{};
        for (x.facts.items) |ex| for (y.facts.items) |ey| {
            const tag = joinFlags(ex.flag, ey.flag) orelse continue;
            switch (ex.fact) {
                .below => |b| if (ey.fact == .below and sameBelow(ey.fact.below, b.i, b.b)) {
                    _ = try out.put(a, .{ .below = .{ .i = b.i, .k = @min(b.k, ey.fact.below.k), .b = b.b } }, tag);
                },
                .upto => |u| if (ey.fact == .upto and sameUpto(ey.fact.upto, u.d, u.name)) {
                    _ = try out.put(a, .{ .upto = .{ .d = u.d, .name = u.name, .hi = @max(u.hi, ey.fact.upto.hi) } }, tag);
                },
                else => if (std.meta.eql(ex.fact, ey.fact)) {
                    _ = try out.put(a, ex.fact, tag);
                },
            }
        };
        return out;
    }

    /// Drop every fact under a flag `keep` refuses.
    fn dropFlags(st: *State, ctx: anytype, comptime keep: fn (@TypeOf(ctx), NodeKey) bool) void {
        var n: usize = 0;
        for (st.facts.items) |e| if (e.flag == 0 or keep(ctx, e.flag)) {
            st.facts.items[n] = e;
            n += 1;
        };
        st.facts.shrinkRetainingCapacity(n);
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
    /// A store into an element of a List binding (`v[j] = x`, `v[j].f =
    /// x`) changes elements, never the List's length.
    keeps_list_len: bool,
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
            x.keeps_list_len = x.keeps_list_len and e.keeps_list_len;
            return;
        };
        try k.effects.append(a, e);
    }

    fn merge(k: *Kills, a: std.mem.Allocator, other: *const Kills) !void {
        k.all = k.all or other.all;
        for (other.effects.items) |e| try k.add(a, e);
    }

    fn effectOn(k: *const Kills, sym: SymbolId) ?Effect {
        for (k.effects.items) |e| if (e.sym == sym) return e;
        return null;
    }

    /// Whether a write in `k` may make `f` false.
    fn ends(k: *const Kills, f: Fact) bool {
        if (k.all) return true;
        return switch (f) {
            .nonneg => |i| if (k.effectOn(i)) |e| !e.keeps_nonneg else false,
            .fits => |s| k.movesLen(s),
            .below => |b| k.effectOn(b.i) != null or switch (b.b) {
                .len => |s| k.movesLen(s),
                .int => |n| k.effectOn(n) != null,
            },
            .eq => |e| k.effectOn(e.n) != null or k.movesLen(e.s),
            .upto => |u| k.effectOn(u.d) != null,
        };
    }

    /// Whether a write in `k` may change the length of `s`: any write of
    /// the binding a field path starts from, and of a binding itself, one
    /// that does not keep its length.
    fn movesLen(k: *const Kills, s: Place) bool {
        const e = k.effectOn(s.root) orelse return false;
        if (s.path != 0) return true;
        return !(if (s.list) e.keeps_list_len else e.keeps_len);
    }
};

/// End every fact a write in `k` may have made false.
fn applyKills(st: *State, k: *const Kills) void {
    var keep: usize = 0;
    for (st.facts.items) |e| if (!k.ends(e.fact)) {
        st.facts.items[keep] = e;
        keep += 1;
    };
    st.facts.shrinkRetainingCapacity(keep);
}

pub const Error = std.mem.Allocator.Error;

/// A `while` the walk is inside, whose step a `continue` may go to.
const LoopFrame = struct {
    node: NodeKey,
    /// The facts every `continue` to the step carries, met.
    step_in: State = .{ .dead = true },
    /// The blocks open around the loop (`Pass.depth`): a flag made inside
    /// it is out of the step's scope.
    depth: u32 = 0,
};

/// A use's tests: an index or byte access at `i + c` of `width` elements
/// into `s`, or an add of `c` to `i`.
const Use = union(enum) {
    range: struct { i: SymbolId, c: u64, s: Place, width: u64 },
    add: struct { i: SymbolId, c: u64 },
};

/// A test of a flag: `nonneg(i)`, or `below(i, k, len(s))`.
const FlagFact = Fact;

const Pass = struct {
    ctx: *SemContext,
    a: std.mem.Allocator,
    /// The scope of the function or closure whose body is being walked:
    /// a fact names only that body's own locals and parameters.
    body_root: ?ScopeId = null,
    /// What the walk proved of each node, before it is recorded: a node
    /// reached twice keeps only what both visits proved.
    proven: std.AutoHashMapUnmanaged(NodeKey, Proven) = .empty,
    /// The writes under each list node (`killsOf`), computed once.
    kills_memo: std.AutoHashMapUnmanaged(NodeKey, Kills) = .empty,
    /// The `defer`s registered in the blocks of the body open at the
    /// current point, which a jump out of them runs.
    defers: std.ArrayList(Sexp) = .empty,
    /// The `while` loops of the body around the current point.
    loops: std.ArrayList(LoopFrame) = .empty,
    /// When set, the units in the order the walk visits them, and where
    /// each jump goes (`checkUnitOrder`).
    trace: ?*std.ArrayList(UnitEvent) = null,
    /// Each field path a place names (`Place.path`, from 1), by its
    /// dotted text, and its field names.
    paths: std.StringHashMapUnmanaged(u32) = .empty,
    path_fields: std.ArrayList([]const []const u8) = .empty,
    /// What the walk proved of each node while a flag holds
    /// (`sema.ProvenIf`), before it is recorded; a node reached twice
    /// keeps only what both visits proved under the same flag.
    proven_if: std.AutoHashMapUnmanaged(NodeKey, sema.ProvenIf) = .empty,
    /// Each flag's tests, by its statement, and the blocks open where it
    /// is made (`depth`).
    flag_tests: std.AutoHashMapUnmanaged(NodeKey, []const FlagFact) = .empty,
    flag_depth: std.AutoHashMapUnmanaged(NodeKey, u32) = .empty,
    /// The blocks of the body open at the current point.
    depth: u32 = 0,
    /// Whether the body being walked may make flags: a function's, not a
    /// closure's.
    flags_on: bool = false,

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

    /// A slice view: a `?String`, `[]T`, or `![]T`.
    fn isSliceView(p: *const Pass, ty: sema.TypeId) bool {
        const types = &p.ctx.types;
        return switch (types.get(ty)) {
            .string_view, .slice => true,
            .write_view => |inner| types.get(inner) == .slice,
            else => false,
        };
    }

    /// A `List[T]`, held by value.
    fn isList(p: *const Pass, ty: sema.TypeId) bool {
        return switch (p.ctx.types.get(ty)) {
            .parameterized_nominal => |pn| pn.sym == p.ctx.list_sym_id,
            else => false,
        };
    }

    /// An object held by value, whose fields change only where a write of
    /// what holds it says so.
    fn isObject(p: *const Pass, ty: sema.TypeId) bool {
        return switch (p.ctx.types.get(ty)) {
            .nominal, .imported_nominal => true,
            else => false,
        };
    }

    /// `ty` without the read or write view around it.
    fn peelView(p: *const Pass, ty: sema.TypeId) sema.TypeId {
        return switch (p.ctx.types.get(ty)) {
            .read_view, .write_view => |inner| inner,
            else => ty,
        };
    }

    /// `s` of a bound `len(s)` (a positive list): an own binding that is
    /// a slice view, whose length changes only when the binding is
    /// assigned; an own binding that is a List or a view of one; or a
    /// field path `d.f.g` from an own binding `d`, an object or a view of
    /// one, through fields that hold objects by value, to a List, whose
    /// length changes only where a write of `d` says so.
    fn lenPlace(p: *Pass, e: Sexp) Error!?Place {
        if (e == .src) {
            const sym = p.ctx.symbolOf(e) orelse return null;
            if (!p.ownBinding(sym)) return null;
            const ty = p.ctx.symbols.items[sym].ty;
            if (p.isSliceView(ty)) return .{ .root = sym };
            if (p.isList(p.peelView(ty))) return .{ .root = sym, .list = true };
            return null;
        }
        if (!e.isKind(.member)) return null;
        if (!p.isList(p.ctx.typeOf(e) orelse return null)) return null;
        var names: [8][]const u8 = undefined;
        var n: usize = 0;
        var cur = e;
        while (cur.isKind(.member)) {
            if (n == names.len) return null;
            names[n] = sema.identAt(p.source(), ir.Member.name(cur)) orelse return null;
            n += 1;
            cur = ir.Member.object(cur);
            if (cur.isKind(.member) and !p.isObject(p.ctx.typeOf(cur) orelse return null)) return null;
        }
        if (cur != .src) return null;
        const sym = p.ctx.symbolOf(cur) orelse return null;
        if (!p.ownBinding(sym)) return null;
        if (!p.isObject(p.peelView(p.ctx.symbols.items[sym].ty))) return null;
        std.mem.reverse([]const u8, names[0..n]);
        const text = try std.mem.join(p.a, ".", names[0..n]);
        const gop = try p.paths.getOrPut(p.a, text);
        if (!gop.found_existing) {
            try p.path_fields.append(p.a, try p.a.dupe([]const u8, names[0..n]));
            gop.value_ptr.* = @intCast(p.path_fields.items.len);
        }
        return .{ .root = sym, .path = gop.value_ptr.*, .list = true };
    }

    /// An index as a use names it: `i`, `i + c`, or `c + i`, of an own
    /// `Int` `i` and a literal `c`.
    fn indexOf(p: *const Pass, e: Sexp) ?struct { i: SymbolId, c: u64 } {
        if (p.intLocal(e)) |i| return .{ .i = i, .c = 0 };
        const pc = p.plusConst(e, true) orelse return null;
        if (pc.c > max_k) return null;
        return .{ .i = pc.i, .c = pc.c };
    }

    /// An integer literal written in decimal, hex, octal, or binary.
    fn intLiteral(p: *const Pass, e: Sexp) ?u64 {
        return literalOf(p.ctx, e);
    }

    /// `d`, a binding an `upto` may be about: an own binding whose type is
    /// a struct held by value (not a view of one), whose fields change
    /// only where a write of `d` says so.
    fn structLocal(p: *const Pass, e: Sexp) ?SymbolId {
        if (e != .src) return null;
        const sym = p.ctx.symbolOf(e) orelse return null;
        if (!p.ownBinding(sym)) return null;
        return switch (p.ctx.types.get(p.ctx.symbols.items[sym].ty)) {
            .nominal, .imported_nominal => sym,
            else => null,
        };
    }

    /// `0 <= x <= hi` of an `Int` addend `x`: `d.f` under `upto(d, f,
    /// hi)`, or `g(...).f` or `g(...)` where `g` bounds that field or its
    /// result (`sema.ResultBound`).
    fn addendBound(p: *const Pass, e: Sexp, st: *const State) ?u64 {
        if (p.ctx.typeOf(e) != p.ctx.types.int_id) return null;
        if (e.isKind(.member)) {
            const name = sema.identAt(p.source(), ir.Member.name(e)) orelse return null;
            const obj = ir.Member.object(e);
            if (p.structLocal(obj)) |d| return st.uptoHi(d, name);
            if (obj.isKind(.call)) if (resultBoundOf(p.ctx, obj)) |b| return b.field(name);
            return null;
        }
        if (e.isKind(.call)) if (resultBoundOf(p.ctx, e)) |b| return b.whole;
        return null;
    }

    /// `s.len` of a place (`lenPlace`).
    fn lenOf(p: *Pass, e: Sexp) Error!?Place {
        if (!e.isKind(.member)) return null;
        const name = sema.identAt(p.source(), ir.Member.name(e)) orelse return null;
        if (!std.mem.eql(u8, name, "len")) return null;
        return p.lenPlace(ir.Member.object(e));
    }

    /// A bound as a guard writes it: `s.len`, or a bare `n`.
    fn boundOf(p: *Pass, e: Sexp) Error!?Bound {
        if (try p.lenOf(e)) |s| return .{ .len = s };
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

    /// The size in bytes of the type a `read` or `write` names, when it is
    /// concrete: a number, or a `Simd` of `n` numbers, `n` times the size
    /// of one (its bytes are read as an integer of that size is).
    fn numSize(p: *const Pass, ty: sema.TypeId) ?u64 {
        return switch (p.ctx.types.get(ty)) {
            .int => |info| info.width() / 8,
            .float => |info| (if (info.bits == 0) 64 else info.bits) / 8,
            .simd => |v| switch (p.ctx.types.get(v.elem)) {
                .int, .float => (p.numSize(v.elem) orelse return null) * (sema.simdLen(p.ctx, v) orelse return null),
                else => null,
            },
            else => null,
        };
    }

    /// `s.read[T, e](i)` or `!s.write[T, e](i, v)` of a slice view `s`, an
    /// own `Int` `i`, and a concrete `T`: the callee, `i`, `s`, and the
    /// width.
    fn byteAccess(p: *Pass, call: Sexp) Error!?struct { callee: Sexp, i: SymbolId, s: Place, width: u64 } {
        if (!call.isKind(.call)) return null;
        const callee = p.ctx.calleeOf(call);
        const ec = p.ctx.elemCallOf(callee) orelse return null;
        if (ec.op != .read and ec.op != .write) return null;
        const width = p.numSize(ec.num) orelse return null;
        var obj = ir.Member.object(callee);
        if (ec.op == .write and obj.isKind(.write)) obj = ir.Write.operand(obj);
        const args = ir.Call.args(call);
        if (args.len == 0) return null;
        const i = p.intLocal(args[0]) orelse return null;
        const s = (try p.lenPlace(obj)) orelse return null;
        if (s.list) return null;
        return .{ .callee = callee, .i = i, .s = s, .width = width };
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
            .keeps_list_len = w.kind == .elem_store and storesElement(node, w.sym, p.ctx),
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
        const key: ?NodeKey = if (node == .list and node.list.id != 0) node.list.id else null;
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
        // A statement that is never one (`rig.StmtClass.none`) is opaque,
        // as `raw` is.
        if (node.isKind(.block)) for (ir.Block.stmts(node)) |stmt| {
            if (stmt.kind()) |k| if (rig.stmtClass(k) == .none) {
                out.all = true;
            };
        };
        if (p.ctx.writeSiteOf(node)) |w| try out.add(p.a, p.effectOf(node, w));
        for (node.items()) |c| try p.collectKills(c, out);
    }

    /// `K(u)`, the writes of unit `root` before it ends: every write in
    /// it but an assignment's own store, which comes after every other
    /// step of the assignment (`storage.eachSetStep`).
    fn unitKills(p: *Pass, root: Sexp) Error!Kills {
        if (!root.isKind(.set)) return p.killsOf(root);
        var out: Kills = .{};
        for (root.items()) |c| try out.merge(p.a, &(try p.killsOf(c)));
        return out;
    }

    /// The writes of a statement `match`'s selection: its subject, its
    /// patterns, and its guards.
    fn selectionKills(p: *Pass, match: Sexp) Error!Kills {
        var out: Kills = .{};
        for (try rig.selectionParts(p.a, match)) |part| try out.merge(p.a, &(try p.killsOf(part)));
        return out;
    }

    fn applyEffect(p: *Pass, st: *State, e: Effect) Error!void {
        var k: Kills = .{};
        try k.add(p.a, e);
        applyKills(st, &k);
    }

    // ------------------------------------------------------------------
    // Uses
    // ------------------------------------------------------------------

    /// Record what `node` proves on every path (`proven`), and what it
    /// proves besides while a flag holds (`cond`). A node reached twice
    /// keeps only what both visits proved, and a test under a flag only
    /// when both proved it under the same flag.
    fn record(p: *Pass, node: Sexp, proven: Proven, cond: ?sema.ProvenIf) Error!void {
        const key: NodeKey = if (node == .list and node.list.id != 0) node.list.id else return;
        const gop = try p.proven.getOrPut(p.a, key);
        if (gop.found_existing) {
            gop.value_ptr.lower = gop.value_ptr.lower and proven.lower;
            gop.value_ptr.upper = gop.value_ptr.upper and proven.upper;
            gop.value_ptr.no_overflow = gop.value_ptr.no_overflow and proven.no_overflow;
            const old = p.proven_if.getPtr(key) orelse return;
            const new = cond orelse return p.dropProvenIf(key);
            if (old.flag != new.flag) return p.dropProvenIf(key);
            old.tests.lower = old.tests.lower and new.tests.lower;
            old.tests.upper = old.tests.upper and new.tests.upper;
            old.tests.no_overflow = old.tests.no_overflow and new.tests.no_overflow;
            if (!old.tests.any()) p.dropProvenIf(key);
        } else {
            gop.value_ptr.* = proven;
            if (cond) |c| try p.proven_if.put(p.a, key, c);
        }
    }

    fn dropProvenIf(p: *Pass, key: NodeKey) void {
        _ = p.proven_if.remove(key);
    }

    /// The tests of `u` that hold on every path (`flag` 0) or while flag
    /// `flag` holds: for a range, `0 <= i + c` under `nonneg(i)` (the add
    /// itself is tested, or proven), and room for `c + width` elements
    /// past `i`; for an add, room for `c` (`addFits`).
    fn proveUse(st: *const State, u: Use, flag: NodeKey) Proven {
        return switch (u) {
            .range => |r| .{
                .lower = st.hasNonneg(r.i, flag),
                .upper = if (st.belowK(r.i, .{ .len = r.s }, flag)) |k| k >= r.c + r.width else false,
            },
            .add => |x| .{ .no_overflow = addFits(st, x.i, x.c, flag) },
        };
    }

    fn complete(u: Use, t: Proven) bool {
        return switch (u) {
            .range => t.lower and t.upper,
            .add => t.no_overflow,
        };
    }

    fn minus(x: Proven, y: Proven) Proven {
        return .{ .lower = x.lower and !y.lower, .upper = x.upper and !y.upper, .no_overflow = x.no_overflow and !y.no_overflow };
    }

    fn count(t: Proven) u8 {
        return @as(u8, @intFromBool(t.lower)) + @intFromBool(t.upper) + @intFromBool(t.no_overflow);
    }

    /// Record the tests of use `u` at `node`: those of every path, and,
    /// with `flags`, the most the flag of any fact held adds to them.
    fn recordProof(p: *Pass, node: Sexp, st: *const State, u: Use, flags: bool) Error!void {
        const base = proveUse(st, u, 0);
        var best: ?sema.ProvenIf = null;
        if (flags and !complete(u, base)) for (st.facts.items, 0..) |e, n| {
            if (e.flag == 0) continue;
            // Each flag once.
            const seen = for (st.facts.items[0..n]) |x| {
                if (x.flag == e.flag) break true;
            } else false;
            if (seen) continue;
            const extra = minus(proveUse(st, u, e.flag), base);
            if (count(extra) > (if (best) |b| count(b.tests) else 0)) best = .{ .tests = extra, .flag = e.flag };
        };
        try p.record(node, base, best);
    }

    /// Whether `i + c` fits: `i + c <= i + k <= b <= Int.max` under
    /// `below(i, k, b)` with `k >= c`, or, for a length bound,
    /// `i + c <= max_len + c <= Int.max` under `fits(s)`; on every path,
    /// or (`flag` not 0) while flag `flag` holds.
    fn addFits(st: *const State, i: SymbolId, c: u64, flag: NodeKey) bool {
        if (c == 0 or c > max_k) return false;
        for (st.facts.items) |e| if ((e.flag == 0 or e.flag == flag) and e.fact == .below and e.fact.below.i == i) {
            const f = e.fact.below;
            if (f.k >= c) return true;
            if (f.b == .len and st.holds(.{ .fits = f.b.len }, flag)) return true;
        };
        return false;
    }

    /// Record what `node` proves, from the facts that hold where it runs.
    fn recordUse(p: *Pass, node: Sexp, st: *const State) Error!void {
        switch (node.kind() orelse return) {
            .index => {
                const s = (try p.lenPlace(ir.Index.object(node))) orelse return;
                const ix = p.indexOf(ir.Index.index(node)) orelse return;
                try p.recordProof(node, st, .{ .range = .{ .i = ix.i, .c = ix.c, .s = s, .width = 1 } }, true);
            },
            .call => {
                const b = (try p.byteAccess(node)) orelse return;
                try p.recordProof(b.callee, st, .{ .range = .{ .i = b.i, .c = 0, .s = b.s, .width = b.width } }, false);
            },
            .@"+" => {
                if (p.plusConst(node, false)) |pc| return p.recordProof(node, st, .{ .add = .{ .i = pc.i, .c = pc.c } }, true);
                // `i + x` with `0 <= x <= hi`: as `i + max(hi, 1)`.
                if (p.ctx.typeOf(node) != p.ctx.types.int_id) return;
                const i = p.intLocal(ir.get(node, .left)) orelse return;
                const hi = p.addendBound(ir.get(node, .right), st) orelse return;
                try p.recordProof(node, st, .{ .add = .{ .i = i, .c = @max(hi, 1) } }, true);
            },
            // `i += c`, and `i += x` with `0 <= x <= hi`: the add's own test.
            .set => if (rig.bindingKindOf(ir.Set.op(node)) == .@"+=") {
                const i = p.intLocal(ir.Set.target(node)) orelse return;
                const value = ir.Set.value(node);
                const c = p.intLiteral(value) orelse @max(p.addendBound(value, st) orelse return, 1);
                try p.recordProof(node, st, .{ .add = .{ .i = i, .c = c } }, true);
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Facts a unit makes, once it is done (gen)
    // ------------------------------------------------------------------

    /// G1: a guard part, on its true edge. `e` is a comparison; either
    /// way round, `i < b`, `i <= b`, `i + k < b`, `i + k <= b`, and
    /// `0 <= i`, `0 < i`. A bound `s.len` was read, so G4 gives `fits(s)`.
    fn genGuard(p: *Pass, e: Sexp, out: *State) Error!void {
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
        try p.genBelow(lo, hi, strict, out);
    }

    /// G1 on a guard's false edge: what a comparison shows when it fails,
    /// the comparison it negates on its true edge (`i >= b` fails as
    /// `i < b`, `i < 0` as `0 <= i`). An `or` fails only when each of
    /// its operands fails, so each one's false edge holds; any other
    /// condition shows nothing.
    fn genGuardFalse(p: *Pass, e: Sexp, out: *State) Error!void {
        const kind = e.kind() orelse return;
        if (kind == .@"or") {
            try p.genGuardFalse(ir.get(e, .left), out);
            return p.genGuardFalse(ir.get(e, .right), out);
        }
        // `a < b` fails as `b <= a`, `a <= b` as `b < a`, `a > b` as
        // `a <= b`, and `a >= b` as `a < b`.
        const strict, const swap = switch (kind) {
            .@"<" => .{ false, true },
            .@"<=" => .{ true, true },
            .@">" => .{ false, false },
            .@">=" => .{ true, false },
            else => return,
        };
        var lo = ir.get(e, .left);
        var hi = ir.get(e, .right);
        if (swap) std.mem.swap(Sexp, &lo, &hi);
        try p.genBelow(lo, hi, strict, out);
    }

    /// What `lo < hi` (`strict`) or `lo <= hi` shows of Int bindings:
    /// `0 <= i` or `0 < i`, or `i + k` below a bound, which, as `s.len`,
    /// was read, so G4 gives `fits(s)`.
    fn genBelow(p: *Pass, lo: Sexp, hi: Sexp, strict: bool, out: *State) Error!void {
        // `0 <= i`, `0 < i`.
        if (p.intLiteral(lo)) |z| if (z == 0) if (p.intLocal(hi)) |i| return out.add(p.a, .{ .nonneg = i }, 0);
        const b = (try p.boundOf(hi)) orelse return;
        if (b == .len) try out.add(p.a, .{ .fits = b.len }, 0);
        const i: SymbolId, const k: u64 = if (p.intLocal(lo)) |i|
            .{ i, 0 }
        else if (p.plusConst(lo, true)) |pc|
            .{ pc.i, pc.c }
        else
            return;
        if (k > max_k) return;
        try out.add(p.a, .{ .below = .{ .i = i, .k = @min(k + @intFromBool(strict), max_k), .b = b } }, 0);
    }

    /// G2: a check that ran. After `x = s[i]`, `x = s[i + c]`, or `x =
    /// s.read[T, e](i)` (`value`), or the statement `!s.write[T, e](i,
    /// v)`, the test passed (or the program stopped): `i + c + width <=
    /// s.len`, and, with no `c`, `0 <= i`.
    fn genCheck(p: *Pass, value: Sexp, out: *State) Error!void {
        const i: SymbolId, const c: u64, const s: Place, const width: u64 = switch (value.kind() orelse return) {
            .index => blk: {
                const ix = p.indexOf(ir.Index.index(value)) orelse return;
                break :blk .{ ix.i, ix.c, (try p.lenPlace(ir.Index.object(value))) orelse return, 1 };
            },
            .call => blk: {
                const b = (try p.byteAccess(value)) orelse return;
                break :blk .{ b.i, 0, b.s, b.width };
            },
            else => return,
        };
        if (c == 0) try out.add(p.a, .{ .nonneg = i }, 0);
        try out.add(p.a, .{ .below = .{ .i = i, .k = c + width, .b = .{ .len = s } } }, 0);
    }

    /// G3, E1, and E2, after an assignment's store: `i = c` (a literal),
    /// `i = j` with `0 <= j` before it, `n = s.len`, which also gives
    /// `eq(n, s)` and, from the length read, `fits(s)`, and `d = g(...)`,
    /// which gives `upto(d, f, hi)` of each field `g` bounds.
    fn genStore(p: *Pass, set: Sexp, before: *const State, out: *State) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(set));
        if (kind.operator() != null) return;
        // E2: `d = g(...)`, where `g` bounds fields of its result.
        if (p.structLocal(ir.Set.target(set))) |d| {
            const value = ir.Set.value(set);
            if (p.ctx.typeOf(value) != p.ctx.symbols.items[d].ty) return;
            const b = resultBoundOf(p.ctx, value) orelse return;
            for (b.fields) |f| try out.add(p.a, .{ .upto = .{ .d = d, .name = f.name, .hi = f.hi } }, 0);
            return;
        }
        const i = p.intLocal(ir.Set.target(set)) orelse return;
        const value = ir.Set.value(set);
        if (p.intLiteral(value) != null or p.fromUnsigned(value)) return out.add(p.a, .{ .nonneg = i }, 0);
        if (try p.lenOf(value)) |s| {
            try out.add(p.a, .{ .nonneg = i }, 0);
            try out.add(p.a, .{ .fits = s }, 0);
            return out.add(p.a, .{ .eq = .{ .n = i, .s = s } }, 0);
        }
        if (p.intLocal(value)) |j| if (j != i) if (before.nonnegFlag(j)) |flag| try out.add(p.a, .{ .nonneg = i }, flag);
    }

    /// `Int(u)` of an unsigned integer `u`: a value that fits, which the
    /// conversion tests, is not negative.
    fn fromUnsigned(p: *const Pass, e: Sexp) bool {
        if (!e.isKind(.call) or p.ctx.typeOf(e) != p.ctx.types.int_id) return false;
        const callee = ir.Call.callee(e);
        if (callee != .src or p.ctx.symbolOf(callee) != null) return false;
        if (!std.mem.eql(u8, sema.identAt(p.source(), callee) orelse return false, "Int")) return false;
        const args = ir.Call.args(e);
        if (args.len != 1 or args[0].isKind(.kwarg)) return false;
        return switch (p.ctx.types.get(p.ctx.typeOf(args[0]) orelse return false)) {
            .int => |info| !info.signed,
            else => false,
        };
    }

    /// Add to `st` each fact of `made` that no write in `k` ends.
    fn addMade(p: *Pass, st: *State, made: *State, k: *const Kills) Error!void {
        applyKills(made, k);
        for (made.facts.items) |e| try st.add(p.a, e.fact, e.flag);
    }

    // ------------------------------------------------------------------
    // The walk: units, and the skeleton between them
    // ------------------------------------------------------------------

    fn traceUnit(p: *Pass, ev: UnitEvent) Error!void {
        if (p.trace) |t| try t.append(p.a, ev);
    }

    /// A function's or closure's body, from no facts.
    fn walkBody(p: *Pass, owner: Sexp, body: Sexp) Error!void {
        if (body == .nil) return;
        const saved_root = p.body_root;
        const saved_defers = p.defers;
        const saved_loops = p.loops;
        const saved_flags = p.flags_on;
        const saved_depth = p.depth;
        defer {
            p.body_root = saved_root;
            p.defers = saved_defers;
            p.loops = saved_loops;
            p.flags_on = saved_flags;
            p.depth = saved_depth;
        }
        p.body_root = p.ctx.scopeOf(owner);
        p.defers = .empty;
        p.loops = .empty;
        // A closure's body makes no flags: emit writes its statements
        // inside the closure's own declaration.
        p.flags_on = !owner.isKind(.lambda);
        p.depth = 0;
        var fresh: State = .{};
        try p.walkBranch(body, &fresh);
    }

    /// A branch: a block, or one statement.
    fn walkBranch(p: *Pass, b: Sexp, st: *State) Error!void {
        if (b == .nil) return;
        if (b.isKind(.block)) return p.walkBlock(b, st, true);
        try p.walkStmt(b, st);
    }

    /// The statements in order; at the end, the block's `defer`s run. A
    /// block of statements (`stmts`, not a block inside a unit's
    /// expression) may make a flag before each of its statements
    /// (`proposeFlag`), whose facts end with the block, as its Zig scope
    /// does.
    fn walkBlock(p: *Pass, block: Sexp, st: *State, stmts: bool) Error!void {
        const mark = p.defers.items.len;
        p.depth += 1;
        const depth = p.depth;
        for (ir.Block.stmts(block)) |stmt| {
            // What no path reaches proves nothing.
            if (st.dead) st.* = .{};
            if (stmts) try p.proposeFlag(stmt, st);
            try p.walkStmt(stmt, st);
        }
        for (p.defers.items[mark..]) |d| applyKills(st, &(try p.killsOf(d)));
        p.defers.shrinkRetainingCapacity(mark);
        p.dropFlagsFrom(st, depth);
        p.depth -= 1;
    }

    /// Drop the facts under the flags made in the blocks open at `depth`
    /// or deeper.
    fn dropFlagsFrom(p: *Pass, st: *State, depth: u32) void {
        const Keep = struct {
            p: *Pass,
            depth: u32,
            fn keep(k: @This(), flag: NodeKey) bool {
                return (k.p.flag_depth.get(flag) orelse 0) < k.depth;
            }
        };
        st.dropFlags(Keep{ .p = p, .depth = depth }, Keep.keep);
    }

    /// A statement, by its skeleton (`rig.skeletonOf`), the one `eachUnit`
    /// lists the units by.
    fn walkStmt(p: *Pass, stmt: Sexp, st: *State) Error!void {
        switch (rig.skeletonOf(stmt)) {
            .unit => |kind| switch (kind) {
                .raw => try p.walkRaw(stmt, st),
                else => try p.walkUnit(stmt, kind, st),
            },
            .block => |b| try p.walkBlock(b, st, true),
            .@"if" => |x| try p.walkIf(stmt, x.cond, x.then, x.@"else", st),
            .@"while" => |x| try p.walkWhile(stmt, x.cond, x.body, x.step, x.@"else", st),
            .@"for" => |x| try p.walkFor(stmt, x.source, x.body, x.@"else", st),
            .match => |m| try p.walkMatch(m, st),
            .labeled => |inner| if (inner.isKind(.block)) try p.walkLabeledBlock(inner, st) else try p.walkStmt(inner, st),
            // A `defer` body runs at its block's exits, from facts this
            // pass does not track: it is walked from none.
            .@"defer" => |body| {
                var fresh: State = .{};
                try p.walkBranch(body, &fresh);
                try p.defers.append(p.a, stmt);
            },
        }
    }

    /// A unit: its checks from `A(u)`, the facts at its entry less every
    /// write in it; then the facts it made, its store, and what the store
    /// makes.
    fn walkUnit(p: *Pass, root: Sexp, kind: rig.UnitKind, st: *State) Error!void {
        if (root != .list) return;
        const k = try p.unitKills(root);
        applyKills(st, &k);
        try p.traceUnit(.{ .enter = root.list.id });
        try p.walkParts(root, st);
        try p.traceUnit(.{ .exit = root.list.id });
        // What follows a `return`, `break`, `continue`, or `panic` statement
        // does not run. (A failing `e!` leaves too, but only when it fails.)
        if (kind == .stmt and rig.leaves(root)) {
            st.dead = true;
            return;
        }
        var made: State = .{};
        if (root.isKind(.set)) {
            const kind_op = rig.bindingKindOf(ir.Set.op(root));
            if (kind_op.operator() == null) try p.genCheck(ir.Set.value(root), &made);
        } else if (kind == .stmt and root.isKind(.call)) {
            // G2 of the statement `!s.write[T, e](i, v)`.
            if (p.ctx.elemCallOf(p.ctx.calleeOf(root))) |ec| if (ec.op == .write) try p.genCheck(root, &made);
        }
        const before = try st.clone(p.a);
        try p.addMade(st, &made, &k);
        if (!root.isKind(.set)) return;
        if (p.ctx.writeSiteOf(root)) |w| try p.applyEffect(st, p.effectOf(root, w));
        var stored: State = .{};
        try p.genStore(root, &before, &stored);
        try p.addMade(st, &stored, &k);
    }

    /// The parts of unit code under `e`, each from `a_state`, `A(u)`: the
    /// checks it holds, its jumps, and the units of the blocks and closure
    /// bodies in it, each from `A(u)` too.
    fn walkParts(p: *Pass, e: Sexp, a_state: *const State) Error!void {
        if (e != .list) return;
        const kind = e.kind() orelse {
            for (e.items()) |c| try p.walkParts(c, a_state);
            return;
        };
        switch (kind) {
            .block => {
                var b = try a_state.clone(p.a);
                try p.walkBlock(e, &b, false);
                return;
            },
            .lambda => return p.walkBody(e, ir.Lambda.body(e)),
            else => {},
        }
        for (rig.children(e)) |c| try p.walkParts(c, a_state);
        if (rig.isJump(e)) try p.jump(e, a_state);
        try p.recordUse(e, a_state);
    }

    /// A `break` or `continue` carries the facts where it runs, less what
    /// the `defer`s it runs write, to where it goes (`JumpDest`). Only a
    /// loop's step joins what jumps carry; the head starts from what
    /// holds at every iteration, and an exit from the join after the
    /// loop.
    fn jump(p: *Pass, node: Sexp, st: *const State) Error!void {
        const dest = p.ctx.jumpDestOf(node) orelse return;
        try p.traceUnit(.{ .jump = .{ .node = node.list.id, .to = dest.to } });
        if (dest.to != .step) return;
        const target = if (dest.target == .list) dest.target.list.id else return;
        for (p.loops.items) |*frame| if (frame.node == target) {
            var carried = try st.clone(p.a);
            for (p.defers.items) |d| applyKills(&carried, &(try p.killsOf(d)));
            // A flag made inside the loop is out of the step's scope.
            p.dropFlagsFrom(&carried, frame.depth + 1);
            frame.step_in = try State.meet(p.a, &frame.step_in, &carried);
            return;
        };
    }

    /// A block a label names (`$done:`), which `break $done` leaves from
    /// anywhere in it: its statements from the facts before, and after
    /// it those facts less every write in it, as after a `match`.
    fn walkLabeledBlock(p: *Pass, block: Sexp, st: *State) Error!void {
        var b = try st.clone(p.a);
        try p.walkBlock(block, &b, true);
        applyKills(st, &(try p.killsOf(block)));
        st.dead = false;
    }

    /// `raw` is opaque: nothing in it is proven, and no fact outlives it.
    /// A jump out of it carries no fact.
    fn walkRaw(p: *Pass, node: Sexp, st: *State) Error!void {
        try p.traceUnit(.{ .enter = node.list.id });
        try p.rawJumps(node);
        try p.traceUnit(.{ .exit = node.list.id });
        st.* = .{};
    }

    fn rawJumps(p: *Pass, e: Sexp) Error!void {
        if (e != .list) return;
        if (e.isKind(.lambda)) return;
        for (e.items()) |c| try p.rawJumps(c);
        if (rig.isJump(e)) try p.jump(e, &.{});
    }

    /// The guard parts of a condition in order, each from the true edge
    /// of the one before (`rig.eachGuardPart`, `rig.eachGuardOperand`),
    /// leaving `t` as the true edge of the last.
    fn walkCond(p: *Pass, cond: Sexp, t: *State) Error!void {
        const Parts = struct {
            p: *Pass,
            t: *State,
            pub fn part(self: @This(), part_node: Sexp) Error!void {
                if (part_node.isKind(.as_match)) return self.p.walkSelection(rig.asMatchOf(part_node), self.t);
                try rig.eachGuardOperand(part_node, self, @This().operand);
            }
            fn operand(self: @This(), g: Sexp) Error!void {
                try self.p.walkGuard(g, self.t);
            }
        };
        try rig.eachGuardPart(cond, Parts{ .p = p, .t = t });
    }

    /// The selection unit of `match` `node`: its subject, then each arm's
    /// pattern and guard, from `sel`, the facts once the selection's kills
    /// apply. A part `s as .circle(r)` is the selection of its `match`
    /// (`rig.asMatchOf`), from whose true edge the rest goes on.
    fn walkSelection(p: *Pass, node: Sexp, sel: *State) Error!void {
        applyKills(sel, &(try p.selectionKills(node)));
        try p.traceUnit(.{ .enter = node.list.id });
        const none: State = .{};
        try p.walkParts(ir.Match.subject(node), if (storage.matchRereads(p.ctx, node)) &none else sel);
        for (ir.Match.arms(node)) |arm| {
            try p.walkParts(ir.Arm.pattern(arm), sel);
            try p.walkParts(ir.Arm.guard(arm), sel);
        }
        try p.traceUnit(.{ .exit = node.list.id });
    }

    /// A guard unit: G1 on its true edge, unless it writes what it names.
    fn walkGuard(p: *Pass, g: Sexp, t: *State) Error!void {
        if (g != .list) return;
        const k = try p.killsOf(g);
        applyKills(t, &k);
        try p.traceUnit(.{ .enter = g.list.id });
        try p.walkParts(g, t);
        try p.traceUnit(.{ .exit = g.list.id });
        if (rig.isAsPart(g)) return;
        var made: State = .{};
        try p.genGuard(g, &made);
        try p.addMade(t, &made, &k);
    }

    /// `if`: the guard parts, the `then` from the last one's true edge,
    /// the `else` from the false edge (`falseEdge`); after it, the facts
    /// before less every write in it. An `if` with no `else` whose `then`
    /// always leaves (`return 0 if i >= s.len`) is left only by its false
    /// edge, so what follows it starts there.
    fn walkIf(p: *Pass, node: Sexp, cond: Sexp, then: Sexp, else_b: Sexp, st: *State) Error!void {
        var t = try st.clone(p.a);
        try p.walkCond(cond, &t);
        try p.walkBranch(then, &t);
        var e = try st.clone(p.a);
        try p.falseEdge(cond, &e);
        if (else_b != .nil) {
            try p.walkBranch(else_b, &e);
        } else if (t.dead) {
            st.* = e;
            return;
        }
        applyKills(st, &(try p.killsOf(node)));
        st.dead = false;
    }

    /// The facts on condition `cond`'s false edge, from `st`, the facts
    /// before it: less every write in it, with what the failed condition
    /// shows (`genGuardFalse`), unless it writes what that names. A
    /// condition of several parts, or one that binds (`as`), shows
    /// nothing.
    fn falseEdge(p: *Pass, cond: Sexp, st: *State) Error!void {
        const k = try p.killsOf(cond);
        applyKills(st, &k);
        if (cond != .list or rig.isAsPart(cond) or cond.isKind(.@"and")) return;
        var made: State = .{};
        try p.genGuardFalse(cond, &made);
        try p.addMade(st, &made, &k);
    }

    /// `while cond : step` (docs/internals/INTERNALS.md, "Loops"): each iteration
    /// starts from `L`, the facts before less every write in the loop
    /// (`0 <= i` kept when every write of `i` adds a constant); the step
    /// from the facts at the body's end met with what each `continue` to
    /// it carries.
    fn walkWhile(p: *Pass, node: Sexp, cond: Sexp, body: Sexp, step: Sexp, else_b: Sexp, st: *State) Error!void {
        const kills = try p.killsOf(node);
        var head = try st.clone(p.a);
        applyKills(&head, &kills);
        try p.loops.append(p.a, .{ .node = node.list.id, .depth = p.depth });
        const frame = p.loops.items.len - 1;
        var t = try head.clone(p.a);
        try p.walkCond(cond, &t);
        try p.walkBranch(body, &t);
        if (step != .nil) {
            var s = try State.meet(p.a, &t, &p.loops.items[frame].step_in);
            try p.walkUnit(step, .step, &s);
        }
        p.loops.shrinkRetainingCapacity(frame);
        if (else_b != .nil) {
            var e = try head.clone(p.a);
            applyKills(&e, &(try p.killsOf(cond)));
            try p.walkBranch(else_b, &e);
        }
        applyKills(st, &kills);
        st.dead = false;
    }

    /// `for`: its source unit once, then the body each iteration from `L`.
    /// A `for` binding gets no facts.
    fn walkFor(p: *Pass, node: Sexp, source_node: Sexp, body: Sexp, else_b: Sexp, st: *State) Error!void {
        const kills = try p.killsOf(node);
        var head = try st.clone(p.a);
        try p.walkUnit(source_node, .source, &head);
        applyKills(&head, &kills);
        var b = try head.clone(p.a);
        try p.rangeFacts(node, source_node, &head, &kills, &b);
        try p.walkBranch(body, &b);
        if (else_b != .nil) {
            var e = try head.clone(p.a);
            try p.walkBranch(else_b, &e);
        }
        applyKills(st, &kills);
        st.dead = false;
    }

    /// What `for k in lo..hi` gives its body, for every iteration: `0 <=
    /// k` when `0 <= lo` (a literal, or a binding known not negative), and
    /// `k + 1 <= hi` when `hi` is a bound (`s.len`, or an `Int` binding)
    /// that nothing in the loop writes (`k <= hi` for `lo..=hi`). Emit
    /// reads both ends once, before the first iteration, and counts `k`
    /// up from `lo` while it is below `hi` (or, inclusive, up to it).
    fn rangeFacts(p: *Pass, loop: Sexp, source_node: Sexp, head: *const State, kills: *const Kills, body: *State) Error!void {
        if (!source_node.isKind(.@"..")) return;
        const k = p.intLocal(ir.For.@"var"(loop)) orelse return;
        const lo = ir.get(source_node, .left);
        const hi = ir.get(source_node, .right);
        if (p.intLiteral(lo) != null) {
            try body.add(p.a, .{ .nonneg = k }, 0);
        } else if (p.intLocal(lo)) |j| if (head.nonnegFlag(j)) |flag| try body.add(p.a, .{ .nonneg = k }, flag);
        const b = (try p.boundOf(hi)) orelse return;
        const fact: Fact = .{ .below = .{ .i = k, .k = @intFromBool(!rig.isInclusive(source_node)), .b = b } };
        if (kills.ends(fact)) return;
        if (b == .len) try body.add(p.a, .{ .fits = b.len }, 0);
        try body.add(p.a, fact, 0);
    }

    // ------------------------------------------------------------------
    // Flags (docs/internals/INTERNALS.md, "Flags")
    // ------------------------------------------------------------------

    /// Make a flag before statement `stmt` of a block when it would prove
    /// tests the facts held do not: its tests are facts of the bindings
    /// and lengths as `stmt` starts, which emit tests once there into a
    /// flag; the walk then holds them under the flag, and a use they prove
    /// makes the tests they prove only when the flag is false, so a
    /// failing test still fails where it is written, with its own
    /// message. Three shapes (a positive list):
    ///
    /// - a statement unit with two or more indexes `s[i + c]` of one place
    ///   and one binding (a record read from consecutive slots): `0 <= i`
    ///   and `i + cmax + 1 <= s.len`;
    /// - a `while` whose guard bounds `i` by an `Int` binding `n` (`i <
    ///   n`, `i + k <= n`) or by `s.len`, with indexes `s[i + c]` in its
    ///   body: `n + j <= s.len`, for room for every `c`, and `0 <= i`;
    /// - a `for k in lo..n` (not `lo..=n`) with indexes `s[k + c]` in its
    ///   body: `n + cmax <= s.len`, and `0 <= lo`.
    ///
    /// Each test is one no write in the statement (or the loop) ends,
    /// and none the facts held already give.
    fn proposeFlag(p: *Pass, stmt: Sexp, st: *State) Error!void {
        if (!p.flags_on or st.dead or stmt != .list or stmt.list.id == 0) return;
        var tests: std.ArrayList(FlagFact) = .empty;
        switch (rig.skeletonOf(stmt)) {
            .unit => |kind| if (kind == .stmt) try p.recordReadTests(stmt, st, &tests),
            .@"while" => |x| try p.whileTests(stmt, x.cond, x.body, st, &tests),
            .@"for" => |x| try p.rangeTests(stmt, x.source, x.body, st, &tests),
            else => {},
        }
        if (tests.items.len == 0) return;
        const id = stmt.list.id;
        try p.flag_tests.put(p.a, id, tests.items);
        try p.flag_depth.put(p.a, id, p.depth);
        for (tests.items) |f| try st.add(p.a, f, id);
    }

    /// The indexes `s[i + c]` under `e` (not in a closure's body), grouped
    /// by place and binding, with the largest `c` of each.
    const IndexGroup = struct { s: Place, i: SymbolId, uses: u32, cmax: u64 };

    fn collectIndexes(p: *Pass, e: Sexp, out: *std.ArrayList(IndexGroup)) Error!void {
        if (e != .list) return;
        if (e.isKind(.lambda)) return;
        if (e.isKind(.index)) if (try p.lenPlace(ir.Index.object(e))) |s| if (p.indexOf(ir.Index.index(e))) |ix| {
            for (out.items) |*g| {
                if (g.i != ix.i or !std.meta.eql(g.s, s)) continue;
                g.uses += 1;
                g.cmax = @max(g.cmax, ix.c);
                break;
            } else try out.append(p.a, .{ .s = s, .i = ix.i, .uses = 1, .cmax = ix.c });
        };
        for (e.items()) |c| try p.collectIndexes(c, out);
    }

    fn addTest(p: *Pass, tests: *std.ArrayList(FlagFact), f: FlagFact) Error!void {
        for (tests.items) |t| if (std.meta.eql(t, f)) return;
        try tests.append(p.a, f);
    }

    /// The tests for a record read: two or more indexes of one place at
    /// one binding in the unit `stmt`.
    fn recordReadTests(p: *Pass, stmt: Sexp, st: *const State, tests: *std.ArrayList(FlagFact)) Error!void {
        var groups: std.ArrayList(IndexGroup) = .empty;
        try p.collectIndexes(stmt, &groups);
        const k = try p.unitKills(stmt);
        for (groups.items) |g| {
            if (g.uses < 2) continue;
            const room = g.cmax + 1;
            const upper: Fact = .{ .below = .{ .i = g.i, .k = room, .b = .{ .len = g.s } } };
            if (k.ends(upper)) continue;
            if ((st.belowK(g.i, .{ .len = g.s }, 0) orelse 0) < room) try p.addTest(tests, upper);
            if (!st.hasNonneg(g.i, 0)) try p.addTest(tests, .{ .nonneg = g.i });
        }
    }

    /// The tests for a `while` loop: room in a length for the indexes of
    /// the binding its guard bounds, and that binding not negative.
    fn whileTests(p: *Pass, loop: Sexp, cond: Sexp, body: Sexp, st: *const State, tests: *std.ArrayList(FlagFact)) Error!void {
        const kills = try p.killsOf(loop);
        // What the guard's operands bound, on their true edges.
        var guard: State = .{};
        const Ops = struct {
            p: *Pass,
            out: *State,
            pub fn part(self: @This(), part_node: Sexp) Error!void {
                if (part_node.isKind(.as_match)) return;
                try rig.eachGuardOperand(part_node, self, @This().operand);
            }
            fn operand(self: @This(), g: Sexp) Error!void {
                try self.p.genGuard(g, self.out);
            }
        };
        try rig.eachGuardPart(cond, Ops{ .p = p, .out = &guard });
        var groups: std.ArrayList(IndexGroup) = .empty;
        try p.collectIndexes(body, &groups);
        for (groups.items) |g| {
            if (kills.movesLen(g.s)) continue;
            const room = g.cmax + 1;
            var bounded = false;
            for (guard.facts.items) |e| if (e.fact == .below and e.fact.below.i == g.i) {
                const gb = e.fact.below;
                switch (gb.b) {
                    .len => |s| if (std.meta.eql(s, g.s) and gb.k >= room) {
                        bounded = true;
                    },
                    .int => |n| {
                        // `i + gk <= n` and `n + j <= s.len`: `i + gk + j <= s.len`.
                        const j = room -| gb.k;
                        const t: Fact = .{ .below = .{ .i = n, .k = j, .b = .{ .len = g.s } } };
                        if (kills.ends(t)) continue;
                        bounded = true;
                        const have = st.belowK(n, .{ .len = g.s }, 0);
                        if (have == null or have.? < j) try p.addTest(tests, t);
                    },
                }
            };
            if (!bounded) continue;
            // `0 <= i` as the loop starts, kept by writes that add.
            if (!st.hasNonneg(g.i, 0) and !kills.ends(.{ .nonneg = g.i })) try p.addTest(tests, .{ .nonneg = g.i });
        }
    }

    /// The tests for `for k in lo..n`: room in a length for the indexes of
    /// `k`, and `lo` not negative.
    fn rangeTests(p: *Pass, loop: Sexp, source_node: Sexp, body: Sexp, st: *const State, tests: *std.ArrayList(FlagFact)) Error!void {
        if (!source_node.isKind(.@"..") or rig.isInclusive(source_node)) return;
        const k = p.intLocal(ir.For.@"var"(loop)) orelse return;
        const kills = try p.killsOf(loop);
        const lo = ir.get(source_node, .left);
        const n = p.intLocal(ir.get(source_node, .right));
        var groups: std.ArrayList(IndexGroup) = .empty;
        try p.collectIndexes(body, &groups);
        for (groups.items) |g| {
            if (g.i != k) continue;
            var any = false;
            // `k + 1 <= n` and `n + cmax <= s.len`.
            if (n) |nn| {
                const t: Fact = .{ .below = .{ .i = nn, .k = g.cmax, .b = .{ .len = g.s } } };
                if (!kills.ends(t) and !kills.ends(.{ .below = .{ .i = k, .k = 1, .b = .{ .int = nn } } })) {
                    any = true;
                    const have = st.belowK(nn, .{ .len = g.s }, 0);
                    if (have == null or have.? < g.cmax) try p.addTest(tests, t);
                }
            } else if (try p.lenOf(ir.get(source_node, .right))) |s| {
                // `k + 1 <= s.len` already: room for `c = 0` only.
                any = std.meta.eql(s, g.s);
            }
            if (!any) continue;
            if (p.intLocal(lo)) |j| if (!st.hasNonneg(j, 0) and !kills.ends(.{ .nonneg = j })) try p.addTest(tests, .{ .nonneg = j });
        }
    }

    /// A statement `match`: the selection unit (its subject, patterns, and
    /// guards), then each arm from the selection's end. A subject the
    /// match reads again after picking an arm (`storage.matchRereads`)
    /// proves nothing.
    fn walkMatch(p: *Pass, node: Sexp, st: *State) Error!void {
        var sel = try st.clone(p.a);
        try p.walkSelection(node, &sel);
        for (ir.Match.arms(node)) |arm| {
            var a = try sel.clone(p.a);
            try p.walkBranch(ir.Arm.body(arm), &a);
        }
        applyKills(st, &(try p.killsOf(node)));
        st.dead = false;
    }
};

/// Whether the store `set` writes into an element of the binding `sym`
/// (`v[j] = x`, `v[j].f = x`): the step of its target next to the binding
/// is an index, so the store changes no length the binding holds.
fn storesElement(set: Sexp, sym: SymbolId, ctx: *const SemContext) bool {
    if (!set.isKind(.set)) return false;
    var t = ir.Set.target(set);
    var element = false;
    while (true) {
        if (t.isKind(.index)) {
            if (ir.Index.index(t).isKind(.@"..")) return false;
            element = true;
            t = ir.Index.object(t);
        } else if (t.isKind(.member)) {
            element = false;
            t = ir.Member.object(t);
        } else break;
    }
    return element and t == .src and ctx.symbolOf(t) == sym;
}

/// Record what each function of a module the ownership checker accepted
/// bounds of its result (`SemContext.result_bounds`), and the tests each
/// node is known to pass (`SemContext.provenOf`).
pub fn check(ctx: *SemContext, root: Sexp) Error!void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var sums: Summaries = .{ .ctx = ctx, .a = arena.allocator() };
    try sums.all(root);
    var p: Pass = .{ .ctx = ctx, .a = arena.allocator() };
    try rig.eachBody(root, &p, walkDeclBody);
    var it = p.proven.iterator();
    while (it.next()) |e| if (e.value_ptr.any()) try ctx.proven.put(ctx.allocator, e.key_ptr.*, e.value_ptr.*);
    // Each flag a test rests on, with its tests as emit writes them.
    const keep = ctx.arena.allocator();
    var cond = p.proven_if.iterator();
    while (cond.next()) |e| {
        if (!e.value_ptr.tests.any()) continue;
        try ctx.proven_if.put(ctx.allocator, e.key_ptr.*, e.value_ptr.*);
        const flag = e.value_ptr.flag;
        if (ctx.flags.contains(flag)) continue;
        const facts = p.flag_tests.get(flag).?;
        const out = try keep.alloc(sema.FlagTest, facts.len);
        for (facts, out) |f, *t| t.* = switch (f) {
            .nonneg => |i| .{ .nonneg = i },
            .below => |b| .{ .below = .{ .i = b.i, .k = b.k, .s = .{
                .root = b.b.len.root,
                .fields = if (b.b.len.path == 0) &.{} else try keep.dupe([]const u8, p.path_fields.items[b.b.len.path - 1]),
            } } },
            else => unreachable,
        };
        try ctx.flags.put(ctx.allocator, flag, out);
    }
}

fn walkDeclBody(p: *Pass, owner: Sexp, body: Sexp) Error!void {
    try p.walkBody(owner, body);
}

// ---------------------------------------------------------------------------
// What a function bounds of its result
// ---------------------------------------------------------------------------

/// An integer literal written in decimal, hex, octal, or binary.
fn literalOf(ctx: *const SemContext, e: Sexp) ?u64 {
    if (e != .src) return null;
    const text = sema.identAt(ctx.source, e) orelse return null;
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
    return std.fmt.parseInt(u64, text, 0) catch null;
}

/// A function a call names: where its name is declared, in the module
/// that declares it.
const Callee = struct { ctx: *const SemContext, pos: u32 };

/// The function `call` calls, when it names one: `f(...)` of a function
/// of this module, or `m.f(...)` of a module `m`; not a closure, a
/// method, an extern, a generic instance, or a proxy of another module's
/// declaration.
fn calledFn(ctx: *const SemContext, call: Sexp) ?Callee {
    if (!call.isKind(.call)) return null;
    const callee = ir.Call.callee(call);
    if (ctx.instanceOf(callee) != null) return null;
    if (callee == .src) {
        const id = ctx.symbolOf(callee) orelse return null;
        const s = ctx.symbols.items[id];
        if (s.kind != .function or sema.isProxy(s)) return null;
        return .{ .ctx = ctx, .pos = s.decl_pos };
    }
    if (!callee.isKind(.member)) return null;
    const id = ctx.symbolOf(ir.Member.object(callee)) orelse return null;
    if (ctx.symbols.items[id].kind != .module) return null;
    const foreign = ctx.foreign_semas.get(ctx.module_refs.get(id) orelse return null) orelse return null;
    const name = sema.identAt(ctx.source, ir.Member.name(callee)) orelse return null;
    const fid = foreign.moduleMember(name) orelse return null;
    const s = foreign.symbols.items[fid];
    if (s.kind != .function or sema.isProxy(s)) return null;
    return .{ .ctx = foreign, .pos = s.decl_pos };
}

/// What the function `call` calls bounds of its result, once its module's
/// bounds are found (`Summaries`); null when it bounds nothing.
fn resultBoundOf(ctx: *const SemContext, call: Sexp) ?sema.ResultBound {
    const f = calledFn(ctx, call) orelse return null;
    return f.ctx.result_bounds.get(f.pos);
}

/// Whether `call` constructs a value of the struct `ty`: `T(...)` or
/// `m.T(...)` of a struct that is no generic instance.
fn constructs(ctx: *const SemContext, call: Sexp, ty: sema.TypeId) bool {
    if (!call.isKind(.call) or ctx.typeOf(call) != ty) return false;
    const callee = ir.Call.callee(call);
    if (ctx.instanceOf(callee) != null) return false;
    if (callee == .src) {
        const id = ctx.symbolOf(callee) orelse return false;
        return ctx.symbols.items[id].kind == .nominal_type;
    }
    if (!callee.isKind(.member)) return false;
    const s = storage.moduleMemberSym(ctx, callee) orelse return false;
    return s.kind == .nominal_type;
}

/// What each function of a module bounds of its result, from its return
/// values (docs/internals/INTERNALS.md, "Proven checks"). Each value a function can
/// return (every `return`'s, and the body's tail unless it is a
/// `return`) is, for an `Int` result, a literal or a call of a function
/// that bounds its result, and for a struct result, a constructor that
/// gives the field a literal, or a call of a function that bounds that
/// field. Anything else bounds nothing, and so does a function on a cycle
/// of calls, which reaches itself before its bound is known.
const Summaries = struct {
    ctx: *SemContext,
    a: std.mem.Allocator,
    /// Each function of the module, by where its name is declared.
    fns: std.AutoHashMapUnmanaged(u32, Sexp) = .empty,
    /// The functions whose bound is being found, or was.
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn all(s: *Summaries, root: Sexp) Error!void {
        for (ir.Module.decls(root)) |decl| {
            const d = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
            if (!d.isKind(.fun) or rig.isCtFun(d)) continue;
            try s.fns.put(s.a, s.ctx.startOf(ir.get(d, .name)), d);
        }
        var it = s.fns.keyIterator();
        while (it.next()) |pos| try s.visit(pos.*);
    }

    /// A function whose bound `visit` finds once the bounds of the
    /// functions it returns calls of (`callees`, from `next` on) are found.
    const Pending = struct { pos: u32, callees: []const u32, next: usize = 0 };

    /// Finds the bound of the function at `start`, and first those of the
    /// functions of this module it returns calls of, deepest first. The
    /// walk keeps a stack of its own, as long as the program's chain of
    /// calls, rather than recursing once a call. A function is seen when
    /// the walk reaches it, so one reached again on a cycle of calls,
    /// before its bound is found, bounds nothing there.
    fn visit(s: *Summaries, start: u32) Error!void {
        if ((try s.seen.getOrPut(s.a, start)).found_existing) return;
        var stack: std.ArrayList(Pending) = .empty;
        try stack.append(s.a, .{ .pos = start, .callees = try s.callees(start) });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < top.callees.len) {
                const pos = top.callees[top.next];
                top.next += 1;
                if ((try s.seen.getOrPut(s.a, pos)).found_existing) continue;
                try stack.append(s.a, .{ .pos = pos, .callees = try s.callees(pos) });
                continue;
            }
            const pos = top.pos;
            _ = stack.pop();
            const b = (try s.summarize(s.fns.get(pos).?, pos)) orelse continue;
            try s.ctx.result_bounds.put(s.ctx.allocator, pos, b);
        }
    }

    /// The functions of this module whose calls the function at `pos`
    /// returns, whose bounds its own is found from.
    fn callees(s: *Summaries, pos: u32) Error![]const u32 {
        const values = (try s.valuesOf(s.fns.get(pos).?)) orelse return &.{};
        var out: std.ArrayList(u32) = .empty;
        for (values) |v| {
            const f = calledFn(s.ctx, v) orelse continue;
            if (f.ctx == s.ctx and s.fns.contains(f.pos)) try out.append(s.a, f.pos);
        }
        return out.items;
    }

    /// The bound of the function that `call` calls: another module's,
    /// found with that module, or one of this module's, which `visit`
    /// found first.
    fn of(s: *Summaries, call: Sexp) Error!?sema.ResultBound {
        const f = calledFn(s.ctx, call) orelse return null;
        return f.ctx.result_bounds.get(f.pos);
    }

    /// Each value the function `node` can return: every `return`'s, and
    /// its body's tail unless that is a `return`. Null when one returns
    /// no value.
    fn valuesOf(s: *Summaries, node: Sexp) Error!?[]const Sexp {
        const body = ir.get(node, .body);
        if (body == .nil) return null;
        var values: std.ArrayList(Sexp) = .empty;
        if (!try s.returns(body, &values)) return null;
        const tail = sema.tailOf(body);
        if (tail == .nil) return null;
        if (!tail.isKind(.@"return")) try values.append(s.a, tail);
        return values.items;
    }

    fn summarize(s: *Summaries, node: Sexp, pos: u32) Error!?sema.ResultBound {
        const ctx = s.ctx;
        if (sema.tparamsOf(node) != .nil) return null;
        const name = sema.identAt(ctx.source, ir.get(node, .name)) orelse return null;
        const id = ctx.lookupInScopeOnly(sema.module_scope, name) orelse return null;
        const sym = ctx.symbols.items[id];
        if (sym.kind != .function or sym.decl_pos != pos) return null;
        const fty = switch (ctx.types.get(sym.ty)) {
            .function => |f| f,
            else => return null,
        };
        const ret = fty.returns;
        const values = (try s.valuesOf(node)) orelse return null;
        if (ret == ctx.types.int_id) {
            var hi: u64 = 0;
            for (values) |v| hi = @max(hi, (try s.wholeOf(v)) orelse return null);
            return .{ .whole = hi };
        }
        switch (ctx.types.get(ret)) {
            .nominal => {},
            else => return null,
        }
        // The fields some value gives a bound, each kept when every value
        // bounds it.
        var names: std.ArrayList([]const u8) = .empty;
        for (values) |v| {
            if (constructs(ctx, v, ret)) {
                for (ir.Call.args(v)) |arg| if (arg.isKind(.kwarg)) {
                    const n = sema.identAt(ctx.source, ir.Kwarg.name(arg)) orelse continue;
                    if (!contains(names.items, n)) try names.append(s.a, n);
                };
            } else if (try s.of(v)) |b| for (b.fields) |f| {
                if (!contains(names.items, f.name)) try names.append(s.a, f.name);
            };
        }
        var fields: std.ArrayList(sema.FieldBound) = .empty;
        next: for (names.items) |n| {
            var hi: u64 = 0;
            for (values) |v| hi = @max(hi, (try s.fieldOf(v, ret, n)) orelse continue :next);
            try fields.append(s.a, .{ .name = try ctx.arena.allocator().dupe(u8, n), .hi = hi });
        }
        if (fields.items.len == 0) return null;
        return .{ .fields = try ctx.arena.allocator().dupe(sema.FieldBound, fields.items) };
    }

    /// The value of every `return` in `e`, but those of the functions and
    /// closures declared in it; false when one returns no value.
    fn returns(s: *Summaries, e: Sexp, out: *std.ArrayList(Sexp)) Error!bool {
        if (e != .list) return true;
        switch (e.kind() orelse .set) {
            .lambda, .fun, .sub => return true,
            .@"return" => {
                const v = ir.Return.value(e);
                if (v == .nil) return false;
                try out.append(s.a, v);
            },
            else => {},
        }
        for (e.items()) |c| if (!try s.returns(c, out)) return false;
        return true;
    }

    /// The bound of an `Int` value: a literal, or a call of a function
    /// that bounds its result.
    fn wholeOf(s: *Summaries, v: Sexp) Error!?u64 {
        if (literalOf(s.ctx, v)) |c| return if (c <= max_k) c else null;
        const b = (try s.of(v)) orelse return null;
        return b.whole;
    }

    /// The bound of field `name` of a struct value of type `ty`: a
    /// constructor that gives it a literal, or a call of a function that
    /// bounds it.
    fn fieldOf(s: *Summaries, v: Sexp, ty: sema.TypeId, name: []const u8) Error!?u64 {
        if (constructs(s.ctx, v, ty)) {
            for (ir.Call.args(v)) |arg| if (arg.isKind(.kwarg)) {
                const n = sema.identAt(s.ctx.source, ir.Kwarg.name(arg)) orelse continue;
                if (!std.mem.eql(u8, n, name)) continue;
                const c = literalOf(s.ctx, ir.Kwarg.value(arg)) orelse return null;
                return if (c <= max_k) c else null;
            };
            return null;
        }
        if (s.ctx.typeOf(v) != ty) return null;
        const b = (try s.of(v)) orelse return null;
        return b.field(name);
    }
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The units of a module's bodies in the order the walk visits them, and
/// where each jump goes (appended to `out`, in `a`).
pub fn walkTrace(ctx: *SemContext, a: std.mem.Allocator, root: Sexp, out: *std.ArrayList(UnitEvent)) Error!void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var trace: std.ArrayList(UnitEvent) = .empty;
    var p: Pass = .{ .ctx = ctx, .a = arena.allocator(), .trace = &trace };
    try rig.eachBody(root, &p, walkDeclBody);
    try out.appendSlice(a, trace.items);
}

/// A unit, and the unit around it when it starts (null at a body's top).
const Placed = struct { unit: NodeKey, parent: ?NodeKey };

/// Each unit of `events` where it starts, with the unit open around it
/// then. A unit starts once: after it, only a `pause` and a `resume` of
/// it may write more of its code (`Emitter.pauseUnit`), and every unit
/// that starts while it is paused lies inside the construct it is the
/// unit of (a `match`'s arms; nothing, for an `as` part), so a resume
/// never comes after a later sibling. Returns the unit that breaks this,
/// or null.
fn placeUnits(a: std.mem.Allocator, root: Sexp, events: []const UnitEvent, out: *std.ArrayList(Placed)) Error!?NodeKey {
    var seen: std.AutoHashMapUnmanaged(NodeKey, void) = .empty;
    // Each paused unit -> how many units had started when it paused.
    var paused: std.AutoHashMapUnmanaged(NodeKey, usize) = .empty;
    var open: std.ArrayList(NodeKey) = .empty;
    // Each node of `root` with an id -> the nearest one around it, found
    // at the first resume.
    var up: ?std.AutoHashMapUnmanaged(NodeKey, NodeKey) = null;
    for (events) |ev| switch (ev) {
        .enter => |k| {
            if (seen.contains(k)) return k;
            try seen.put(a, k, {});
            try out.append(a, .{ .unit = k, .parent = open.getLastOrNull() });
            try open.append(a, k);
        },
        .exit => |k| if (open.pop() != k) return k,
        .pause => |k| {
            if (open.pop() != k) return k;
            try paused.put(a, k, out.items.len);
        },
        .@"resume" => |k| {
            const since = (paused.fetchRemove(k) orelse return k).value;
            if (up == null) {
                up = .empty;
                try mapParents(a, root, 0, &up.?);
            }
            if (!up.?.contains(k)) return k;
            for (out.items[since..]) |x| if (!within(&up.?, x.unit, k)) return k;
            try open.append(a, k);
        },
        .jump => {},
    };
    var left = paused.keyIterator();
    if (left.next()) |k| return k.*;
    return null;
}

/// The block each unit's statement lies in (`rig.eachUnit`): a body, or
/// a block inside another unit's expression. The units of one block run
/// in its order; those of two blocks of one unit, in whichever order the
/// unit's code reaches them, which nothing relies on.
const Groups = struct {
    a: std.mem.Allocator,
    of: std.AutoHashMapUnmanaged(NodeKey, NodeKey) = .empty,
    /// The block whose units are being listed, for each level of units.
    open: std.ArrayList(NodeKey) = .empty,

    pub fn enter(g: *Groups, root: Sexp, _: rig.UnitKind) Error!void {
        try g.of.put(g.a, root.list.id, g.open.getLast());
    }
    pub fn exit(_: *Groups, _: Sexp) Error!void {}
    pub fn nest(g: *Groups, block: Sexp, opening: bool) Error!void {
        if (opening) try g.open.append(g.a, block.list.id) else _ = g.open.pop();
    }

    fn body(g: *Groups, _: Sexp, b: Sexp) Error!void {
        try g.open.append(g.a, if (b == .list) b.list.id else 0);
        try rig.eachUnit(b, g);
        _ = g.open.pop();
    }
};

/// The unit-order test: the units emit wrote (`Emitter.unit_trace`) are
/// the ones the walk visited, each nested in the same unit, and the units
/// of each block in the same order; and each jump goes where the walk
/// sent its facts. Run on every module a debug build of the compiler
/// emits. Returns what differs, or null.
pub fn checkUnitOrder(ctx: *SemContext, a: std.mem.Allocator, root: Sexp, emitted: []const UnitEvent) Error!?[]const u8 {
    var walked: std.ArrayList(UnitEvent) = .empty;
    try walkTrace(ctx, a, root, &walked);
    var w: std.ArrayList(Placed) = .empty;
    if (try placeUnits(a, root, walked.items, &w)) |k| return try std.fmt.allocPrint(a, "{s}: the walk visits the unit twice", .{try where(ctx, a, root, k)});
    var e: std.ArrayList(Placed) = .empty;
    if (try placeUnits(a, root, emitted, &e)) |k| return try std.fmt.allocPrint(a, "{s}: emit writes the unit's code again after it ended, or after a later unit", .{try where(ctx, a, root, k)});
    var groups: Groups = .{ .a = a };
    try rig.eachBody(root, &groups, Groups.body);
    // A body emit leaves out (a `test` outside `rig test`) has no units in
    // its trace.
    var parent_of: std.AutoHashMapUnmanaged(NodeKey, ?NodeKey) = .empty;
    for (e.items) |x| try parent_of.put(a, x.unit, x.parent);
    var walk_seq: std.AutoHashMapUnmanaged(NodeKey, std.ArrayList(NodeKey)) = .empty;
    var kept: usize = 0;
    for (w.items) |x| {
        const parent = parent_of.get(x.unit) orelse continue;
        kept += 1;
        if (!std.meta.eql(x.parent, parent)) return try std.fmt.allocPrint(a, "{s}: the walk nests the unit in {s}, emit in {s}", .{ try where(ctx, a, root, x.unit), try where(ctx, a, root, x.parent), try where(ctx, a, root, parent) });
        const gop = try walk_seq.getOrPut(a, groups.of.get(x.unit) orelse 0);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, x.unit);
    }
    if (kept != e.items.len) {
        var visited: std.AutoHashMapUnmanaged(NodeKey, void) = .empty;
        for (w.items) |x| try visited.put(a, x.unit, {});
        for (e.items) |x| if (!visited.contains(x.unit)) return try std.fmt.allocPrint(a, "{s}: emit writes a unit the walk does not visit", .{try where(ctx, a, root, x.unit)});
    }
    var next: std.AutoHashMapUnmanaged(NodeKey, usize) = .empty;
    for (e.items) |x| {
        const g = groups.of.get(x.unit) orelse 0;
        const seq = walk_seq.get(g) orelse continue;
        const gop = try next.getOrPut(a, g);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const i = gop.value_ptr.*;
        if (i >= seq.items.len or seq.items[i] != x.unit) return try std.fmt.allocPrint(a, "{s}: emit writes the unit where the walk visits {s}", .{ try where(ctx, a, root, x.unit), if (i < seq.items.len) try where(ctx, a, root, seq.items[i]) else "none" });
        gop.value_ptr.* += 1;
    }
    var dests: std.AutoHashMapUnmanaged(NodeKey, sema.JumpDest.To) = .empty;
    for (walked.items) |ev| if (ev == .jump) try dests.put(a, ev.jump.node, ev.jump.to);
    var jumped: std.AutoHashMapUnmanaged(NodeKey, void) = .empty;
    for (emitted) |ev| if (ev == .jump) {
        const to = dests.get(ev.jump.node) orelse return try std.fmt.allocPrint(a, "{s}: emit writes a jump the walk does not visit", .{try where(ctx, a, root, ev.jump.node)});
        if (to != ev.jump.to) return try std.fmt.allocPrint(a, "{s}: the jump goes to its target's {s}, the walk sends it to its {s}", .{ try where(ctx, a, root, ev.jump.node), @tagName(ev.jump.to), @tagName(to) });
        if ((try jumped.getOrPut(a, ev.jump.node)).found_existing) return try std.fmt.allocPrint(a, "{s}: emit writes the jump twice", .{try where(ctx, a, root, ev.jump.node)});
    };
    return null;
}

/// `L:C` of the node with id `key` in `root`, for a message.
fn where(ctx: *const SemContext, a: std.mem.Allocator, root: Sexp, key: ?NodeKey) Error![]const u8 {
    const k = key orelse return "no unit";
    const node = findNode(root, k) orelse return std.fmt.allocPrint(a, "node {d}", .{k});
    const lc = diag.lineCol(ctx.source, ctx.startOf(node));
    return std.fmt.allocPrint(a, "{d}:{d}", .{ lc.line, lc.col });
}

/// Map each node with an id in `e` to the nearest node with an id around
/// it, or 0 for none: `around` for `e` itself. A node met twice keeps
/// where it is first met, as `findNode` finds it.
fn mapParents(a: std.mem.Allocator, e: Sexp, around: NodeKey, up: *std.AutoHashMapUnmanaged(NodeKey, NodeKey)) Error!void {
    if (e != .list) return;
    const id = e.list.id;
    if (id != 0) {
        const gop = try up.getOrPut(a, id);
        if (!gop.found_existing) gop.value_ptr.* = around;
    }
    for (e.items()) |c| try mapParents(a, c, if (id != 0) id else around, up);
}

/// Whether node `key` is node `outer` or lies inside it (`mapParents`).
fn within(up: *const std.AutoHashMapUnmanaged(NodeKey, NodeKey), key: NodeKey, outer: NodeKey) bool {
    var k = key;
    while (k != outer) k = up.get(k) orelse return false;
    return true;
}

fn findNode(e: Sexp, key: NodeKey) ?Sexp {
    if (e != .list) return null;
    if (e.list.id == key) return e;
    for (e.items()) |c| if (findNode(c, key)) |n| return n;
    return null;
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
        const always = ctx.provenOf(n);
        const cond: ?sema.ProvenIf = ctx.provenIfOf(n);
        if (!always.any() and cond == null) continue;
        const kind: []const u8 = switch (n.kind() orelse continue) {
            .index => "index",
            .@"+" => "+",
            .set => "+=",
            .member => sema.identAt(ctx.source, ir.Member.name(n)) orelse "member",
            else => @tagName(n.kind().?),
        };
        const span = if (ctx.parser) |pr| pr.base.span(n) else rig.leafSpan(ctx.source, n);
        // A directory module's position is in one of its files, named.
        const file: diag.File = .{ .source = ctx.source, .path = "", .parts = ctx.parts };
        const in = file.locate(span.start);
        const lc = if (ctx.parts.len == 0) lines.at(span.start) else diag.lineCol(in.text, span.start - in.start);
        // The tests of every path, then (`ok`) those a flag proves.
        for ([2]?Proven{ if (always.any()) always else null, if (cond) |c| c.tests else null }, [2][]const u8{ "", " ok" }) |tests, how| {
            const p = tests orelse continue;
            var text: std.Io.Writer.Allocating = .init(a);
            const t = &text.writer;
            if (ctx.parts.len != 0) try t.print("{s}:", .{in.path});
            try t.print("{d}:{d}{s} {s}", .{ lc.line, lc.col, how, kind });
            if (p.lower) try t.writeAll(" lower");
            if (p.upper) try t.writeAll(" upper");
            if (p.no_overflow) try t.writeAll(" no_overflow");
            try out.append(a, .{ .start = span.start, .text = text.written() });
        }
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

test "G1: a guard's false edge" {
    // A guard whose `then` leaves: what follows starts from its false
    // edge, `i >= s.len` failed as `i < s.len`, and an `or` as each part.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U8
        \\  return 0 if i >= s.len
        \\  s[i]
        \\
    ,
        \\3:3 index upper
        \\
    );
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U8
        \\  if i < 0 or s.len <= i
        \\    return 0
        \\  s[i]
        \\
    ,
        \\4:3 index lower upper
        \\
    );
    // An `else` from the false edge; an `and`, or a `then` that falls
    // through, shows nothing after.
    try expectDump(
        \\fun f(s: ?String, i: Int) -> U8
        \\  if i >= s.len
        \\    print(1)
        \\  else
        \\    print(s[i])
        \\  if i >= 0 and i < s.len
        \\    return 0
        \\  if i >= s.len
        \\    print(2)
        \\  s[i]
        \\
    ,
        \\5:11 index upper
        \\
    );
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
    // A check whose value assigns its own index keeps none of its facts;
    // the store makes its own: an `Int` of a byte is not negative.
    try expectDump(
        \\fun f(s: ?String, at: Int) -> U8
        \\  i: Int = at
        \\  i = Int(s[i])
        \\  s[i]
        \\
    ,
        \\4:3 index lower
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
        \\    !s.write[U8](0, 2)
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
        \\8:11 ok index upper
        \\9:5 += no_overflow
        \\11:17 += no_overflow
        \\12:11 index lower
        \\12:11 ok index upper
        \\
    );
}


test "units: a check is proved from the facts at its unit's entry less every write in the unit" {
    // A `continue` in the condition carries what held before the guard
    // after it: the step's `i += 1` is not proven.
    try expectDump(
        \\fun pick(i: Int) -> Int?
        \\  none
        \\
        \\fun run(at: Int, n: Int) -> Int
        \\  i = at
        \\  t = 0
        \\  while (pick(i) ?? continue) > 0 and i < n : i += 1
        \\    t += 1
        \\  t
        \\
    ,
        \\
    );
    // Every guard of a `match` is in its selection: a guard that writes
    // `i` ends what each arm would know of it.
    try expectDump(
        \\fun bump(n: !Int) -> Bool
        \\  n += 1
        \\  false
        \\
        \\fun pick(s: ?String, at: Int, k: Int) -> U8
        \\  i = at
        \\  if i < s.len
        \\    match k
        \\      1 if bump(!i) => print(1)
        \\      _ => return s[i]
        \\  0
        \\
    ,
        \\
    );
    // The value's check proves nothing in its own statement, whichever
    // of the value and the target runs first; a target's root that
    // writes `i`, or an index that does, ends the guard's facts in it.
    try expectDump(
        \\fun pick(t: ![]U8, n: !Int) -> ![]U8 from t
        \\  n += 1
        \\  t
        \\
        \\fun next(n: !Int) -> Int
        \\  n += 1
        \\  n
        \\
        \\sub put(t: ![]U8, s: ?String, at: Int)
        \\  i = at
        \\  t[i] = s[i]
        \\  if i < s.len
        \\    pick(!t, !i)[0] = s[i]
        \\  if i < s.len
        \\    pick(!t, !i)[0] += s[i]
        \\  if i < s.len
        \\    t[next(!i) - 4] = s[i]
        \\
    ,
        \\
    );
    // What a statement shows holds after it: `c = t[i]` proves both
    // accesses of the next statement.
    try expectDump(
        \\sub put(t: ![]U8, src: ?String, at: Int)
        \\  i = at
        \\  c = t[i]
        \\  t[i] = src[i] + c
        \\
    ,
        \\4:3 index lower upper
        \\4:10 index lower
        \\
    );
}

test "units: a guard in a value proves nothing" {
    try expectDump(
        \\fun f(s: ?String, i: Int, n: Int) -> Int
        \\  x = Int(s[i]) if i < s.len else 0
        \\  ok = i < n and s[i] == 32
        \\  y = (i + 1) if i < n else 0
        \\  x + y + (1 if ok else 0)
        \\
    ,
        \\
    );
}

test "E1: after `n = s.len`, a guard on `n` bounds `s`" {
    // A guard on `n` once `n = s.len` holds.
    try expectDump(
        \\fun count(src: ?String) -> Int
        \\  n = src.len
        \\  i = 0
        \\  while i < n and src[i] != 0
        \\    i += 1
        \\  i
        \\
    ,
        \\4:19 index lower upper
        \\5:5 += no_overflow
        \\
    );
    // `n = s.len` after the guard converts what the guard showed of `n`;
    // what it gave stays when `n` changes later.
    try expectDump(
        \\fun f(s: ?String, at: Int, m: Int) -> U8
        \\  n = m
        \\  i = at
        \\  if i < n
        \\    n = s.len
        \\    print(s[i])
        \\  n = s.len
        \\  if i < n
        \\    n -= 2
        \\    return s[i]
        \\  0
        \\
    ,
        \\10:12 index upper
        \\
    );
    // Re-pointing `s` ends the equality and what it gave.
    try expectDump(
        \\fun f(t: ?String, at: Int) -> U8
        \\  s = t
        \\  n = s.len
        \\  i = at
        \\  if i < n
        \\    s = t[..1]
        \\    return s[i]
        \\  n = s.len
        \\  s = t[..1]
        \\  if i < n
        \\    return s[i]
        \\  0
        \\
    ,
        \\
    );
}

/// Every `.rig` program of `dir` (a multi-file test's `main.rig`).
fn programsIn(a: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".rig")) try std.fs.path.join(a, &.{ dir_path, entry.name }) else continue,
            .directory => try std.fs.path.join(a, &.{ dir_path, entry.name, "main.rig" }),
            else => continue,
        };
        try out.append(a, path);
    }
}

test "the unit-order test: emit writes the units the walk visits, nested and ordered alike" {
    // Every program of the `emit` and `proofs` behavior tests, which
    // test/rig.rip writes out under .zig-cache/rig-tests/tree before it
    // builds and runs the unit tests, with a hash of them that runs the
    // tests again when they change (skipped where it has not run):
    // the units emit writes, in the order their code runs, are the ones the
    // walk visits, each in the same unit, and the units of each block in
    // the same order; each unit's code starts once, and each jump is
    // written once and goes where the walk sends its facts. A trace with
    // two units of a block swapped, a unit written twice, a paused unit
    // taken up again after a later unit, or a jump sent elsewhere fails
    // the test.
    const emit = @import("emit.zig");
    const facts = @import("facts.zig");
    const modules = @import("modules.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena_all = std.heap.ArenaAllocator.init(a);
    defer arena_all.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    const tree = ".zig-cache/rig-tests/tree/behavior";
    std.Io.Dir.cwd().access(io, tree, .{}) catch return error.SkipZigTest;
    try programsIn(arena_all.allocator(), tree ++ "/emit", &names);
    try programsIn(arena_all.allocator(), tree ++ "/proofs", &names);
    var compared: usize = 0;
    var units: usize = 0;
    var swapped: usize = 0;
    var late_resumes: usize = 0;
    for (names.items) |path| {
        // The compiler runs in an arena, as `rig` does.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var graph = modules.ModuleGraph.init(aa, io);
        defer graph.deinit();
        graph.loadRoot(path) catch continue;
        if (graph.hasErrors()) continue;
        const m = graph.root();
        var trace: std.ArrayList(UnitEvent) = .empty;
        defer trace.deinit(a);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var em = emit.Emitter.init(a, m.source, &out.writer, facts.Facts.of(m.sema));
        defer em.deinit();
        em.unit_trace = &trace;
        try em.emit(m.ir);
        if (try checkUnitOrder(m.sema, aa, m.ir, trace.items)) |what| {
            std.debug.print("{s}: {s}\n", .{ path, what });
            return error.TestUnexpectedResult;
        }
        compared += 1;
        for (trace.items) |ev| if (ev == .enter) {
            units += 1;
        };
        // Swap the first two units that start one after the other at a
        // body's top level: the test must see it.
        var placed: std.ArrayList(Placed) = .empty;
        try std.testing.expect(try placeUnits(aa, m.ir, trace.items, &placed) == null);
        var groups: Groups = .{ .a = aa };
        try rig.eachBody(m.ir, &groups, Groups.body);
        var i: usize = 0;
        while (i + 1 < placed.items.len) : (i += 1) {
            const x = placed.items[i];
            const y = placed.items[i + 1];
            if (x.parent != null or y.parent != null) continue;
            if (groups.of.get(x.unit) != groups.of.get(y.unit)) continue;
            var bad: std.ArrayList(UnitEvent) = .empty;
            const swap = struct {
                fn of(k: NodeKey, u: NodeKey, v: NodeKey) NodeKey {
                    return if (k == u) v else if (k == v) u else k;
                }
            }.of;
            for (trace.items) |ev| try bad.append(aa, switch (ev) {
                .enter => |k| .{ .enter = swap(k, x.unit, y.unit) },
                .exit => |k| .{ .exit = swap(k, x.unit, y.unit) },
                .pause => |k| .{ .pause = swap(k, x.unit, y.unit) },
                .@"resume" => |k| .{ .@"resume" = swap(k, x.unit, y.unit) },
                .jump => ev,
            });
            if (try checkUnitOrder(m.sema, aa, m.ir, bad.items) == null) {
                std.debug.print("{s}: two units swapped went unseen\n", .{path});
                return error.TestUnexpectedResult;
            }
            swapped += 1;
            break;
        }
        // A jump sent to another point of its target: the test must see it.
        for (trace.items, 0..) |ev, j| if (ev == .jump) {
            var bad = try std.ArrayList(UnitEvent).initCapacity(aa, trace.items.len);
            bad.appendSliceAssumeCapacity(trace.items);
            bad.items[j].jump.to = if (ev.jump.to == .exit) .head else .exit;
            if (try checkUnitOrder(m.sema, aa, m.ir, bad.items) == null) {
                std.debug.print("{s}: a jump sent elsewhere went unseen\n", .{path});
                return error.TestUnexpectedResult;
            }
            break;
        };
        // A paused unit taken up again only after a later unit ran: the
        // test must see it.
        late: for (trace.items, 0..) |ev, r| if (ev == .@"resume") {
            const k = ev.@"resume";
            // The resume's unit ends right after it.
            if (r + 1 >= trace.items.len or trace.items[r + 1] != .exit or trace.items[r + 1].exit != k) continue;
            // The next unit to start after it, and where it ends.
            var j = r + 2;
            while (j < trace.items.len and trace.items[j] != .enter) : (j += 1) {}
            if (j == trace.items.len) continue;
            const u = trace.items[j].enter;
            var end = j + 1;
            while (end < trace.items.len and !(trace.items[end] == .exit and trace.items[end].exit == u)) : (end += 1) {}
            if (end == trace.items.len) continue;
            var bad: std.ArrayList(UnitEvent) = .empty;
            try bad.appendSlice(aa, trace.items[0..r]);
            try bad.appendSlice(aa, trace.items[r + 2 .. end + 1]);
            try bad.appendSlice(aa, &.{ .{ .@"resume" = k }, .{ .exit = k } });
            try bad.appendSlice(aa, trace.items[end + 1 ..]);
            if (try checkUnitOrder(m.sema, aa, m.ir, bad.items) == null) {
                std.debug.print("{s}: a resume after a later unit went unseen\n", .{path});
                return error.TestUnexpectedResult;
            }
            late_resumes += 1;
            break :late;
        };
        // A unit written a second time after it ended: the test must see it.
        if (placed.items.len > 0) {
            var bad = try std.ArrayList(UnitEvent).initCapacity(aa, trace.items.len + 2);
            bad.appendSliceAssumeCapacity(trace.items);
            bad.appendAssumeCapacity(.{ .enter = placed.items[0].unit });
            bad.appendAssumeCapacity(.{ .exit = placed.items[0].unit });
            if (try checkUnitOrder(m.sema, aa, m.ir, bad.items) == null) {
                std.debug.print("{s}: a unit written twice went unseen\n", .{path});
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expect(compared > 100);
    try std.testing.expect(units > 1000);
    try std.testing.expect(swapped > 50);
    try std.testing.expect(late_resumes > 5);
}

test "E2: a bound a function gives its result proves a caller's add" {
    // `dec` returns `one()`'s size 1 or a size 4; `w` returns 1 or 2: so
    // `i + d.size`, `i + dec(s, i).size`, `i + w(...)`, and `i += d.size`
    // fit under `i < s.len`, and `e`'s fact lasts through a loop that
    // does not write `e`.
    try expectDump(
        \\obj D
        \\  rune: Int
        \\  size: Int
        \\
        \\fun one() -> D
        \\  D(rune: 0, size: 1)
        \\
        \\fun dec(s: ?String, i: Int) -> D
        \\  return one() if s[i] < 0x80
        \\  D(rune: 1, size: 4)
        \\
        \\fun w(b: U8) -> Int
        \\  return 1 if b < 0x80
        \\  2
        \\
        \\fun f(s: ?String, at: Int) -> Int
        \\  i = at
        \\  if i < s.len
        \\    d = dec(s, i)
        \\    print(i + d.size, i + dec(s, i).size, i + w(s[i]))
        \\    i += d.size
        \\  e = dec(s, 0)
        \\  while i < s.len
        \\    print(i + e.size)
        \\    i += 1
        \\  i
        \\
    ,
        \\20:11 + no_overflow
        \\20:23 + no_overflow
        \\20:43 + no_overflow
        \\20:49 index upper
        \\21:5 += no_overflow
        \\24:11 + no_overflow
        \\25:5 += no_overflow
        \\
    );
}

test "E2: a near miss bounds nothing" {
    // A size from a parameter, a negative one, a value `if`, one past
    // 2^62, one through a cycle of calls, a store into the field, a
    // reassignment from an unbounded call, a write view, a parameter
    // struct, the bound on the left of `+`, a loop that writes the
    // struct, and a `raw` block: only the loop's own `j += 1` is proven.
    try expectDump(
        \\obj D
        \\  rune: Int
        \\  size: Int
        \\
        \\sub bump(d: !D)
        \\  d.size += 1
        \\
        \\fun var(n: Int) -> D
        \\  D(rune: 0, size: n)
        \\
        \\fun neg() -> D
        \\  D(rune: 0, size: -1)
        \\
        \\fun cond(k: Int) -> D
        \\  D(rune: 0, size: 1) if k > 0 else D(rune: 0, size: 2)
        \\
        \\fun big() -> D
        \\  D(rune: 0, size: 0x4000000000000001)
        \\
        \\fun rec(k: Int) -> D
        \\  return rec(k - 1) if k > 0
        \\  D(rune: 0, size: 1)
        \\
        \\fun dec() -> D
        \\  D(rune: 0, size: 4)
        \\
        \\fun f(s: ?String, i: Int, p: D) -> Int
        \\  if i < s.len
        \\    a = var(3)
        \\    b = neg()
        \\    c = cond(1)
        \\    e = big()
        \\    w = rec(1)
        \\    h = dec()
        \\    h.size = 9
        \\    k = dec()
        \\    k = var(5)
        \\    m = dec()
        \\    bump(!m)
        \\    n = dec()
        \\    print(i + a.size, i + b.size, i + c.size, i + e.size, i + w.size, i + h.size, i + p.size, i + k.size, i + m.size, n.size + i)
        \\  0
        \\
        \\fun g(s: ?String, i: Int) -> Int
        \\  j = 0
        \\  d = dec()
        \\  while j < s.len
        \\    print(j + d.size)
        \\    d = var(9)
        \\    j += 1
        \\  raw
        \\    d = dec()
        \\  if i < s.len
        \\    print(i + d.size)
        \\  0
        \\
    ,
        \\50:5 += no_overflow
        \\
    );
}

test "Lists: a binding, a field path, a `for` range, and a bound through a bound" {
    try expectDump(
        \\obj Ast
        \\  words: List[Int]
        \\
        \\fun Ast.total(?@) -> Int
        \\  t = 0
        \\  for k in 0..@words.len
        \\    t += @words[k]
        \\  t
        \\
        \\fun total(xs: ?List[Int], n: Int) -> Int
        \\  t = 0
        \\  if n <= xs.len
        \\    for k in 0..n
        \\      t += xs[k]
        \\  t
        \\
        \\sub grow(xs: !List[Int])
        \\  for k in 0..xs.len
        \\    xs[k] = 0
        \\    !xs.push(k)
        \\    xs[k] = 1
        \\
    ,
        \\7:10 index lower upper
        \\14:12 index lower upper
        \\19:5 index lower
        \\21:5 index lower
        \\
    );
}

test "flags: a record read, and a range a flag bounds" {
    try expectDump(
        \\obj Ast
        \\  words: List[Int]
        \\
        \\fun Ast.pair(?@, d: Int) -> Int
        \\  @words[d] + @words[d + 1]
        \\
        \\fun sum(xs: ?List[Int], n: Int) -> Int
        \\  t = 0
        \\  for k in 0..n
        \\    t += xs[k]
        \\  t
        \\
        \\fun once(xs: ?List[Int], d: Int) -> Int
        \\  xs[d]
        \\
    ,
        \\5:3 ok index lower upper
        \\5:15 ok index lower upper
        \\5:22 ok + no_overflow
        \\10:10 index lower
        \\10:10 ok index upper
        \\
    );
}
