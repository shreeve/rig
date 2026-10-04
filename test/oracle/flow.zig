//! The dataflow over the core: which vars are live (backward), which
//! may be empty and which loans each var carries (forward, to a
//! fixpoint), and the checks each op must pass. A loan is live where a
//! var carrying it is live (Core: "a loan lasts until the last use of
//! every view that carries it").

const std = @import("std");
const core = @import("core.zig");

const VarId = core.VarId;
const LoanId = core.LoanId;

/// A set of small integers.
const Bits = struct {
    words: []u64,

    fn init(a: std.mem.Allocator, n: usize) !Bits {
        const w = try a.alloc(u64, (n + 63) / 64);
        @memset(w, 0);
        return .{ .words = w };
    }

    fn clone(self: Bits, a: std.mem.Allocator) !Bits {
        return .{ .words = try a.dupe(u64, self.words) };
    }

    fn set(self: Bits, i: usize) void {
        self.words[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }

    fn unset(self: Bits, i: usize) void {
        self.words[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
    }

    fn has(self: Bits, i: usize) bool {
        return self.words[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }

    fn clear(self: Bits) void {
        @memset(self.words, 0);
    }

    fn copyFrom(self: Bits, other: Bits) void {
        @memcpy(self.words, other.words);
    }

    /// self |= other; whether anything changed.
    fn merge(self: Bits, other: Bits) bool {
        var changed = false;
        for (self.words, other.words) |*x, y| {
            const n = x.* | y;
            if (n != x.*) changed = true;
            x.* = n;
        }
        return changed;
    }
};

/// What is known before an op: the vars that may be empty, and the
/// loans each var may carry.
const State = struct {
    empty: Bits,
    holds: []Bits,

    fn init(a: std.mem.Allocator, nv: usize, nl: usize) !State {
        const holds = try a.alloc(Bits, nv);
        for (holds) |*h| h.* = try Bits.init(a, nl);
        return .{ .empty = try Bits.init(a, nv), .holds = holds };
    }

    fn clone(self: State, a: std.mem.Allocator) !State {
        const holds = try a.alloc(Bits, self.holds.len);
        for (holds, self.holds) |*h, s| h.* = try s.clone(a);
        return .{ .empty = try self.empty.clone(a), .holds = holds };
    }

    fn merge(self: State, other: State) bool {
        var changed = self.empty.merge(other.empty);
        for (self.holds, other.holds) |h, o| changed = h.merge(o) or changed;
        return changed;
    }
};

const Checker = struct {
    a: std.mem.Allocator,
    f: *core.Func,
    nv: usize,
    nl: usize,
    live_out: []Bits,
    /// The read loan each write loan reads as, in what a call returns.
    twins: []?LoanId,
    finding: ?core.Finding = null,

    fn report(self: *Checker, rule: core.Rule, pos: u32, comptime fmt: []const u8, args: anytype) !void {
        if (self.finding != null) return;
        self.finding = .{ .rule = rule, .pos = pos, .reason = try self.a.print(fmt, args) };
    }

    fn name(self: *Checker, v: VarId) []const u8 {
        return self.f.vars.items[v].name;
    }

    // ---- liveness -------------------------------------------------------

    /// live-before from live-after, across one op.
    fn liveStep(self: *Checker, op: core.Op, live: Bits) void {
        if (op.def) |d| live.unset(d);
        if (op.kill) |k| {
            live.unset(k);
            // A user `drop` body reads what the value views.
            if (self.f.vars.items[k].drop_reads) live.set(k);
        }
        for (op.reads) |v| live.set(v);
        for (op.moves) |v| live.set(v);
        for (op.uses) |v| live.set(v);
        for (op.keep) |v| live.set(v);
    }

    fn liveness(self: *Checker) !void {
        const blocks = self.f.blocks.items;
        self.live_out = try self.a.alloc(Bits, blocks.len);
        const live_in = try self.a.alloc(Bits, blocks.len);
        for (self.live_out, live_in) |*o, *i| {
            o.* = try Bits.init(self.a, self.nv);
            i.* = try Bits.init(self.a, self.nv);
        }
        const tmp = try Bits.init(self.a, self.nv);
        var changed = true;
        while (changed) {
            changed = false;
            var bi = blocks.len;
            while (bi > 0) {
                bi -= 1;
                const b = blocks[bi];
                for (b.succs.items) |s| changed = self.live_out[bi].merge(live_in[s]) or changed;
                tmp.copyFrom(self.live_out[bi]);
                var oi = b.ops.items.len;
                while (oi > 0) {
                    oi -= 1;
                    self.liveStep(b.ops.items[oi], tmp);
                }
                changed = live_in[bi].merge(tmp) or changed;
            }
        }
    }

    // ---- loans ----------------------------------------------------------

    /// The loans an op hands to what it defines (Core: one lend makes one
    /// loan, which every copy of the view carries).
    fn flowOf(self: *Checker, op: core.Op, st: State, out: Bits) void {
        out.clear();
        for (op.reads) |v| _ = out.merge(st.holds[v]);
        for (op.moves) |v| _ = out.merge(st.holds[v]);
        if (op.loan) |l| out.set(l);
        _ = self;
    }

    /// Add the flowing loans a var can carry: none if its type holds no
    /// view; a pointer's loan only if it can hold a pointer (a String
    /// read out through a `?String` carries the String's loans, not the
    /// loan on the place it was read from).
    fn take(self: *Checker, v: VarId, st: State, flow: Bits) void {
        const vr = self.f.vars.items[v];
        if (!vr.holds_views) return;
        if (vr.holds_pointers) {
            _ = st.holds[v].merge(flow);
            return;
        }
        for (self.f.loans.items, 0..) |l, li| {
            if (flow.has(li) and l.reachesStrings()) st.holds[v].set(li);
        }
    }

    /// A var a call or store may have left a view in takes the flowing
    /// loans, but never a loan on itself.
    fn gain(self: *Checker, g: VarId, st: State, flow: Bits) void {
        const vr = self.f.vars.items[g];
        if (!vr.holds_views) return;
        for (self.f.loans.items, 0..) |l, li| {
            if (!flow.has(li) or (!l.external and l.root == g)) continue;
            if (!vr.holds_pointers and !l.reachesStrings()) continue;
            st.holds[g].set(li);
        }
    }

    /// Replace each write loan in a flow by its read twin.
    fn readOnly(self: *Checker, flow: Bits) void {
        for (self.twins, 0..) |twin, li| {
            if (twin) |t| if (flow.has(li)) {
                flow.unset(li);
                flow.set(t);
            };
        }
    }

    /// Apply an op to the state (after its checks).
    fn transfer(self: *Checker, op: core.Op, st: State, flow: Bits) void {
        self.flowOf(op, st, flow);
        // What a call hands back or stores is a read view of what it was
        // lent to write, unless it is itself a write view: a String made
        // from a `!Text` reads it (Core s7).
        if (op.what == .call) {
            const wants_write = if (op.def) |d| self.f.vars.items[d].kind == .write_view else false;
            if (!wants_write) self.readOnly(flow);
        }
        for (op.moves) |v| {
            st.empty.set(v);
            st.holds[v].clear();
        }
        if (op.def) |d| {
            st.holds[d].clear();
            self.take(d, st, flow);
            st.empty.unset(d);
        }
        if (op.weak) |w| self.take(w, st, flow);
        // A call may store what it was handed in what it was lent to
        // write (Core s6, SPEC §7 "Second-class borrows").
        for (op.gains) |g| self.gain(g, st, flow);
        // What a write view stores into, or lets a call store into, is
        // what its write loans are on.
        for (op.through) |t| {
            for (self.f.loans.items, 0..) |l, li| {
                if (!st.holds[t].has(li) or l.external or l.mode == .read or !l.stores_views) continue;
                self.gain(l.root, st, flow);
            }
        }
        if (op.kill) |k| {
            st.empty.set(k);
            st.holds[k].clear();
        }
    }

    // ---- checks ---------------------------------------------------------

    /// Whether an access conflicts with a loan a var carries.
    fn conflicts(l: core.Loan, li: LoanId, acc: core.Access) bool {
        if (l.external or l.root != acc.root) return false;
        if (acc.except) |e| if (e == li) return false;
        // The places of one `swap` may be different fields of one value.
        if (l.group != 0 and l.group == acc.group and disjoint(l.path, acc.path)) return false;
        return switch (acc.kind) {
            .read => l.mode == .write,
            .reserve => l.mode != .read,
            .write, .whole => true,
        };
    }

    fn disjoint(x: []const core.Step, y: []const core.Step) bool {
        const n = @min(x.len, y.len);
        for (x[0..n], y[0..n]) |s, t| {
            if (s == .elem or t == .elem) return false;
            if (!std.mem.eql(u8, s.field, t.field)) return true;
        }
        return false;
    }

    fn checkOp(self: *Checker, op: core.Op, st: State, live_after: Bits) !void {
        // C1 (s1, s2): every var read, moved, or used holds a value.
        const groups = [_][]const VarId{ op.reads, op.moves, op.uses };
        for (groups) |g| for (g) |v| {
            if (st.empty.has(v)) {
                const vr = self.f.vars.items[v];
                if (vr.hidden) {
                    try self.report(.C1, op.pos, "use of a value that was moved", .{});
                } else try self.report(.C1, op.pos, "use of `{s}` after move", .{vr.name});
                return;
            }
        };
        // C4 (s5, s6): an access meets no live loan it conflicts with.
        if (op.access) |acc| {
            const live = try live_after.clone(self.a);
            if (op.def) |d| live.unset(d);
            for (op.reads) |v| live.set(v);
            for (op.moves) |v| live.set(v);
            for (op.uses) |v| live.set(v);
            for (0..self.nv) |u| {
                if (!live.has(u)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[u].has(li)) continue;
                    if (op.loan != null and op.loan.? == li) continue;
                    if (!conflicts(l, @intCast(li), acc)) continue;
                    try self.report(.C4, op.pos, "cannot {s} `{s}` while a {s} loan of it is live (L{d}, carried by `{s}`#{d})", .{
                        switch (acc.kind) {
                            .read => "read",
                            .reserve, .write => "write",
                            .whole => "move",
                        },
                        self.name(acc.root),
                        if (l.mode == .read) "read" else "write",
                        li,
                        self.name(@intCast(u)),
                        u,
                    });
                    return;
                }
            }
        }
        // C5 (s3, s6, §3): a var is not dropped while a loan of its own
        // storage is live.
        if (op.kill) |k| if (!st.empty.has(k) or op.uses.len > 0) {
            for (0..self.nv) |u| {
                if (!live_after.has(u) and !(u == k and self.f.vars.items[k].drop_reads)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (l.external or l.deref or l.root != k or !st.holds[u].has(li)) continue;
                    if (op.scope_end) {
                        const vr = self.f.vars.items[k];
                        if (vr.hidden)
                            try self.report(.C5, op.pos, "a loan of a temporary outlives its statement", .{})
                        else
                            try self.report(.C5, op.pos, "`{s}` does not live long enough: a loan of it is still live", .{vr.name});
                    } else try self.report(.C5, op.pos, "cannot drop `{s}` while a loan of it is live", .{self.name(k)});
                    return;
                }
            }
        };
        // C6 (s7): what leaves the function views only what it was lent,
        // or what lives for the whole program.
        if (op.what == .ret) {
            for ([_][]const VarId{ op.reads, op.keep }) |g| for (g) |v| {
                if (st.empty.has(v)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li) or l.external or l.deref) continue;
                    try self.report(.C6, op.pos, "a view of `{s}` leaves the function, which was not lent it", .{self.name(l.root)});
                    return;
                }
            };
        }
    }
};

pub fn check(a: std.mem.Allocator, f: *core.Func) !?core.Finding {
    if (f.early) |e| return e;
    // The caller's loan on each parameter that can carry one.
    var entry_loans: std.ArrayList(struct { VarId, LoanId }) = .empty;
    for (f.params.items) |p| {
        if (!f.vars.items[p].holds_views) continue;
        try f.loans.append(a, .{ .root = p, .path = &.{}, .mode = .read, .external = true, .pointer = false, .pos = 0 });
        try entry_loans.append(a, .{ p, @intCast(f.loans.items.len - 1) });
    }
    const n = f.loans.items.len;
    const twins = try a.alloc(?LoanId, n);
    for (twins, 0..) |*t, li| {
        const l = f.loans.items[li];
        t.* = null;
        if (l.mode == .read or l.external) continue;
        var twin = l;
        twin.mode = .read;
        try f.loans.append(a, twin);
        t.* = @intCast(f.loans.items.len - 1);
    }
    var c: Checker = .{ .a = a, .f = f, .nv = f.vars.items.len, .nl = f.loans.items.len, .live_out = &.{}, .twins = twins };
    try c.liveness();

    const blocks = f.blocks.items;
    const in_states = try a.alloc(?State, blocks.len);
    @memset(in_states, null);
    var entry = try State.init(a, c.nv, c.nl);
    for (0..c.nv) |v| entry.empty.set(v);
    for (f.params.items) |p| entry.empty.unset(p);
    for (entry_loans.items) |pl| entry.holds[pl[0]].set(pl[1]);
    in_states[0] = entry;

    const flow = try Bits.init(a, c.nl);
    var changed = true;
    while (changed) {
        changed = false;
        for (blocks, 0..) |b, bi| {
            const in = in_states[bi] orelse continue;
            const st = try in.clone(a);
            for (b.ops.items) |op| c.transfer(op, st, flow);
            for (b.succs.items) |s| {
                if (in_states[s]) |*existing| {
                    if (existing.merge(st)) changed = true;
                } else {
                    in_states[s] = try st.clone(a);
                    changed = true;
                }
            }
        }
    }

    // The checks, on the fixpoint.
    const live = try Bits.init(a, c.nv);
    for (blocks, 0..) |b, bi| {
        const in = in_states[bi] orelse continue;
        const st = try in.clone(a);
        // live-after for each op, from the block's end backward.
        const after = try a.alloc(Bits, b.ops.items.len);
        live.copyFrom(c.live_out[bi]);
        var oi = b.ops.items.len;
        while (oi > 0) {
            oi -= 1;
            after[oi] = try live.clone(a);
            c.liveStep(b.ops.items[oi], live);
        }
        for (b.ops.items, 0..) |op, i| {
            try c.checkOp(op, st, after[i]);
            if (c.finding) |found| return found;
            c.transfer(op, st, flow);
        }
    }
    return null;
}
