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
    /// Scratch: an op's flow before its write loans are read only.
    full: Bits = undefined,
    /// Scratch: what an op stores (`gains`, `through`), before and after
    /// its write loans are read only; and `take`'s loans.
    stored: Bits = undefined,
    stored_full: Bits = undefined,
    seen: Bits = undefined,
    work: Bits = undefined,
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
    /// A call's result, and what it stores, carry the loans of only some
    /// of what it reads and takes (`skip` the others, Core s7).
    fn flowOf(self: *Checker, op: core.Op, st: State, out: Bits, skip: []const VarId, with_loan: bool) void {
        out.clear();
        for (op.reads) |v| if (std.mem.findScalar(VarId, skip, v) == null) {
            _ = out.merge(st.holds[v]);
        };
        for (op.moves) |v| if (std.mem.findScalar(VarId, skip, v) == null) {
            _ = out.merge(st.holds[v]);
        };
        if (op.carry) {
            for (self.f.loans.items, 0..) |l, li| {
                if (l.pointer and !l.external) out.unset(li);
            }
        }
        if (op.unpoint) {
            const extra = self.full;
            extra.clear();
            for (self.f.loans.items, 0..) |l, li| {
                if (!out.has(li) or !l.pointer or l.external) continue;
                out.unset(li);
                _ = extra.merge(st.holds[l.root]);
            }
            _ = out.merge(extra);
        }
        if (op.loan) |l| if (with_loan) out.set(l);
    }

    /// Add the flowing loans a var can carry: none if its type holds no
    /// view, and only those it keeps (`core.Func.keeps`): a String read
    /// out through a `?String` carries the String's loans, not the loan
    /// on the place it was read from.
    fn take(self: *Checker, v: VarId, st: State, flow: Bits) void {
        const vr = self.f.vars.items[v];
        if (!vr.holds_views) return;
        // A loan the var does not keep stands for the loans its place's
        // var holds now, judged the same way.
        const seen = self.seen;
        seen.clear();
        var pending = true;
        const work = self.work;
        work.copyFrom(flow);
        while (pending) {
            pending = false;
            for (self.f.loans.items, 0..) |l, li| {
                if (!work.has(li) or seen.has(li)) continue;
                seen.set(li);
                if (l.external or self.f.keeps(v, li)) {
                    st.holds[v].set(li);
                } else if (l.root != v and work.merge(st.holds[l.root])) pending = true;
            }
        }
    }

    /// A var a call or store may have left a view in takes the flowing
    /// loans, but never a loan on itself.
    fn gain(self: *Checker, g: VarId, st: State, flow: Bits) void {
        const vr = self.f.vars.items[g];
        if (!vr.holds_views) return;
        for (self.f.loans.items, 0..) |l, li| {
            if (!flow.has(li) or (!l.external and l.root == g)) continue;
            if (!vr.holds_pointers and !(l.external or self.f.keeps(g, li))) continue;
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
        self.flowOf(op, st, flow, op.no_result, op.result_loan);
        const stored = self.stored;
        self.flowOf(op, st, stored, op.no_store, op.store_loan);
        // What a call hands back or stores is a read view of what it was
        // lent to write, unless it may itself be or hold a write view: a
        // String made from a `!Text` reads it (Core s7), and a write view
        // pushed into a Vec of them stays one (Core §5).
        const stored_full = self.stored_full;
        stored_full.copyFrom(stored);
        if (op.what == .call) {
            self.readOnly(stored);
            const wants_write = if (op.def) |d| self.f.vars.items[d].kind == .write_view or self.f.vars.items[d].holds_writes else false;
            if (!wants_write) self.readOnly(flow);
        }
        // A call may store what it was handed in what it was lent to
        // write (Core s6, SPEC §7 "Second-class views"), before its
        // result is handed back: a loan its result does not keep stands
        // for what its place holds after the call (`take`).
        for (op.gains) |g| self.gain(g, st, if (self.f.vars.items[g].holds_writes) stored_full else stored);
        // What a write view stores into, or lets a call store into, is
        // what its write loans are on.
        for (op.through) |t| {
            for (self.f.loans.items, 0..) |l, li| {
                if (!st.holds[t].has(li) or l.external or l.mode == .read or !l.stores_views) continue;
                self.gain(l.root, st, if (self.f.vars.items[l.root].holds_writes) stored_full else stored);
            }
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
                        if (vr.arm)
                            try self.report(.C5, op.pos, "a view of a payload of a read `match` outlives its arm", .{})
                        else if (vr.hidden)
                            try self.report(.C5, op.pos, "a loan of a temporary outlives its statement", .{})
                        else
                            try self.report(.C5, op.pos, "`{s}` does not live long enough: a loan of it is still live", .{vr.name});
                    } else try self.report(.C5, op.pos, "cannot drop `{s}` while a loan of it is live", .{self.name(k)});
                    return;
                }
            }
        };
        // C8 (s9): an owned closure, a Cell, or a Signal takes no value
        // that carries a loan.
        if (op.no_loans) {
            for (op.moves) |v| {
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li)) continue;
                    try self.report(.C8, op.pos, "a value carrying a loan of `{s}` would be stored where every handle reaches it; an owned closure, a Cell, or a Signal holds only values that carry no loan", .{self.name(l.root)});
                    return;
                }
            }
        }
        // C6 (s7): what leaves the function views only what it was lent,
        // or what lives for the whole program. What a closure captured
        // to write outlives each call, so it keeps no view of what one
        // call received (Core §7).
        if (op.what == .ret) {
            // A function that says what its result views views nothing
            // else its caller lent it (Core s7).
            if (self.f.from) |from| for (op.reads) |v| {
                if (st.empty.has(v)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li) or !l.external) continue;
                    const i = std.mem.findScalar(VarId, self.f.params.items, l.root) orelse continue;
                    if (i < 64 and from & (@as(u64, 1) << @intCast(i)) != 0) continue;
                    try self.report(.C6, op.pos, "a view of `{s}` leaves the function, whose `from` does not name it", .{self.name(l.root)});
                    return;
                }
            };
            for (op.keep) |v| {
                if (st.empty.has(v) or !self.f.vars.items[v].capture) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li) or !l.call_only) continue;
                    try self.report(.C6, op.pos, "a view of `{s}`, which lasts one call, is stored in what the closure captured", .{self.name(l.root)});
                    return;
                }
            }
            // What one call received is the caller's, which may outlive
            // the closure: it keeps no view of what the closure captured
            // (Core §7; the call does not pass those loans on).
            for (op.keep) |v| {
                if (st.empty.has(v) or !self.f.vars.items[v].call_only) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li) or !self.f.vars.items[l.root].capture) continue;
                    try self.report(.C6, op.pos, "a view of `{s}`, which the closure captured, is stored in what one call received", .{self.name(l.root)});
                    return;
                }
            }
            // A closure's result is handed out at every call: it views no
            // place the closure captured to write (Core §7: only a
            // captured read lend may be the closure's value).
            for (op.reads) |v| {
                if (st.empty.has(v)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li)) continue;
                    const root = self.f.vars.items[l.root];
                    if (!root.capture or root.kind != .write_view) continue;
                    try self.report(.C6, op.pos, "a view of `{s}`, which the closure captured to write, leaves each call", .{root.name});
                    return;
                }
            }
            for ([_][]const VarId{ op.reads, op.keep }) |g| for (g) |v| {
                if (st.empty.has(v)) continue;
                for (self.f.loans.items, 0..) |l, li| {
                    if (!st.holds[v].has(li) or l.external or l.deref) continue;
                    if (self.f.vars.items[l.root].arm)
                        try self.report(.C6, op.pos, "a view of a payload of a read `match` leaves the function", .{})
                    else
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
        try f.loans.append(a, .{ .root = p, .path = &.{}, .mode = .read, .external = true, .call_only = f.vars.items[p].call_only, .pointer = false, .pos = 0 });
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
    // Each loan added here is kept as the lowering decided for the loan
    // it is the twin of; a caller's loan is external.
    if (f.keep.len > 0) {
        const nv = f.vars.items.len;
        const keep = try a.alloc(bool, nv * f.loans.items.len);
        @memset(keep, true);
        for (0..nv) |v| for (twins, 0..) |twin, li| {
            if (li >= f.keep_loans) continue;
            keep[v * f.loans.items.len + li] = f.keep[v * f.keep_loans + li];
            if (twin) |t| keep[v * f.loans.items.len + t] = f.keep[v * f.keep_loans + li];
        };
        f.keep = keep;
        f.keep_loans = f.loans.items.len;
    }
    var c: Checker = .{ .a = a, .f = f, .nv = f.vars.items.len, .nl = f.loans.items.len, .live_out = &.{}, .twins = twins };
    try c.liveness();
    c.full = try Bits.init(a, c.nl);
    c.stored = try Bits.init(a, c.nl);
    c.stored_full = try Bits.init(a, c.nl);
    c.seen = try Bits.init(a, c.nl);
    c.work = try Bits.init(a, c.nl);

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
