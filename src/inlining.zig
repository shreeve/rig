//! Which functions are emitted `inline`: decided once, for the whole
//! program, after every module is checked (docs/INTERNALS.md, "Inlining").
//!
//! A function marked `called fun` or `rarely fun` is never inlined; the
//! rule below decides the rest.
//!
//! Zig inlines a small function only when asked, and LLVM leaves a
//! small hot helper as a call when its body grows. A `fun` or `sub` with
//! no marker is emitted as an `inline fn` when
//!
//!   - its body has at most `max_size` nodes (`size`),
//!   - it is not on a cycle of calls, directly or through others,
//!   - no mention of it is anything but the callee of a call: it is
//!     never passed, stored, returned, or made into a closure,
//!   - it is not the program's `main`, has no compile-time type
//!     parameters (an instance of one with compile-time values is sized
//!     and inlined as any function), is not a member of a generic type,
//!     and holds no closure.
//!
//! A call resolves by name (a method by its name alone, a function by
//! its symbol), so two functions of one name stand for each other: the
//! analysis only ever finds more cycles and more value uses than there
//! are, never fewer. A call by name is one edge to the group of the
//! functions of that name (`Group`), not one to each.
//!
//! Zig inlines by analyzing the body at each call, so an argument it knows
//! at compile time is known inside, and `a + 1` on a constant `255` would
//! become a compile error where Rig specifies a panic at run time. Emit
//! therefore binds every parameter of an inlined function through
//! `rig.rt` (`Emitter.emitFunPrologue`), which makes it a run-time value:
//! the body means what it means in a function Zig calls.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const modules = @import("modules.zig");
const rig = @import("rig.zig");
const typecheck = @import("typecheck.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;

/// The most nodes (each form of the tree: a call, an operator, a
/// statement) a body may have and be inlined.
pub const max_size = 60;

/// The most reach (`typecheck.checkFrames`) the inlined calls in one
/// function may add to it, and an inlined function may have, each
/// inlined call counted at every call. Zig writes an inlined body, its
/// locals and its temporaries, again at each call, in the caller's frame,
/// so a function's own frame with the inlined ones in it also stays
/// within `sema.max_frame_bytes`, which `typecheck.checkFrames` holds the
/// function's own frame to, and its reach within `sema.max_frame_reach`:
/// inlining stops short of either.
pub const max_inlined_frame_bytes: u128 = 64 << 10;

/// The most nodes an inlined function may expand to at a call, counting
/// the inlined calls in it (each of them as often as it is called):
/// otherwise a chain of functions that each call the next twice would make
/// Zig analyze a body 2^n times. A function with one call, in a function
/// with compile-time values, is exempt: its expansion is counted in each
/// instance of the caller. std.json, the program that set
/// `max_size`, has a hot helper (`key`) that expands to 287.
pub const max_expanded = 320;

const Fn = struct {
    module: usize,
    node: Sexp,
    name: []const u8,
    /// Where the name is declared, which `Facts.isInlined` asks by.
    pos: u32,
    size: u32 = 0,
    /// Whether the declaration alone allows inlining.
    eligible: bool,
    /// Mentioned other than as a callee.
    used_as_value: bool = false,
    /// What its calls reach, once for each call (`Callee`).
    calls: std.ArrayList(Callee) = .empty,
    /// The functions with a call of it, once for each such call.
    callers: std.ArrayList(u32) = .empty,
    /// Its name's group (`Group`).
    group: u32 = 0,
    /// Its reach (`typecheck.checkFrames`): what its code may take of
    /// the stack, which an inlined call adds to its caller's at each call;
    /// 0 when that depends on generic parameters.
    own: u128 = 0,
    /// The bytes of values it keeps on its stack, as `sema.max_frame_bytes`
    /// counts them.
    count: u128 = 0,
    inlined: bool = false,
    /// Its frame with the inlined calls in it (`frames`).
    frame: ?u128 = null,
    /// How many calls may reach it: those of it, and those of its name's
    /// group.
    call_sites: u32 = 0,
    /// The function of the first call that may reach it.
    first_caller: ?u32 = null,
    /// Its size with the inlined calls in it (`expanded`).
    weight: ?u64 = null,
    /// The calls of it, and the first (`First`).
    direct_calls: u32 = 0,
    first: ?First = null,
    /// The step of `fit` that last forgot its frame and expansion.
    forgot: u32 = 0,
    node_state: Tarjan = .{},
};

/// The functions of one name, which a call that resolves by name reaches
/// all of: such a call is one edge to the group, not one to each, so the
/// calls of a name every module declares cost no more than any other.
const Group = struct {
    members: std.ArrayList(u32) = .empty,
    /// The calls of the group, and the first.
    calls: u32 = 0,
    first: ?First = null,
    /// The functions with a call of the group, once for each such call.
    callers: std.ArrayList(u32) = .empty,
    /// What its inlined members add to a caller's frame, and to its size.
    frame: ?u128 = null,
    weight: ?u64 = null,
    /// The first of its inlined members with the largest frame, if any
    /// (`largest`).
    top: ?Top = null,
    forgot: u32 = 0,
    node_state: Tarjan = .{},
};

const Top = struct { fun: ?u32 };

/// A call, by the order the calls are visited in, and the function it is in.
const First = struct { seq: u32, caller: ?u32 };

const Tarjan = struct {
    index: u32 = 0,
    low: u32 = 0,
    on_stack: bool = false,
};

/// What a call reaches: one function, or every function of a name (the
/// group, with `group_bit` set).
const Callee = u32;
const group_bit: Callee = 1 << 31;

/// The name a leaf spells, including a name the iterator rewrite makes
/// (the `next` of a `for` over an iterator), which no source text holds.
fn textOf(c: *const SemContext, leaf: Sexp) []const u8 {
    return if (leaf == .src) rig.leafText(c.source, leaf.src) else "";
}

/// A call and what it may reach.
const Site = struct { module: usize, id: parser.NodeId, callee: Callee };

const Pass = struct {
    a: std.mem.Allocator,
    mods: []const *modules.Module,
    fns: std.ArrayList(Fn) = .empty,
    groups: std.ArrayList(Group) = .empty,
    /// Each call that may reach a function, and what.
    sites: std.ArrayList(Site) = .empty,
    /// A name -> its group.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    /// Per module: the function declared at a position.
    by_pos: []std.AutoHashMapUnmanaged(u32, u32),
    max: u32,
    /// The calls visited so far.
    seq: u32 = 0,
    // Tarjan's, over the functions and the groups: `nodeOf` numbers them.
    next_index: u32 = 1,
    stack: std.ArrayList(u32) = .empty,
    cyclic: std.ArrayList(bool) = .empty,
    // `uninline`: its steps, and the functions and groups it has yet to
    // visit.
    epoch: u32 = 0,
    work: std.ArrayList(Callee) = .empty,

    fn ctx(self: *Pass, module: usize) *const SemContext {
        return self.mods[module].sema;
    }

    fn collect(self: *Pass, module: usize, root: Sexp) !void {
        for (ir.Module.decls(root)) |d| try self.collectDecl(module, d, false);
    }

    fn collectDecl(self: *Pass, module: usize, decl: Sexp, member: bool) !void {
        var d = decl;
        if (d.isKind(.@"pub")) d = ir.Pub.decl(d);
        const kind = d.kind() orelse return;
        switch (kind) {
            .fun, .sub => try self.add(module, d, member, false),
            .@"struct" => for (ir.Struct.members(d)) |m| try self.collectDecl(module, m, true),
            .@"enum" => for (ir.Enum.members(d)) |m| try self.collectDecl(module, m, true),
            .errors => for (ir.Errors.members(d)) |m| try self.collectDecl(module, m, true),
            .generic_struct => for (ir.GenericStruct.members(d)) |m| try self.collectGeneric(module, m),
            .generic_enum => for (ir.GenericEnum.members(d)) |m| try self.collectGeneric(module, m),
            else => {},
        }
    }

    fn collectGeneric(self: *Pass, module: usize, member: Sexp) !void {
        var m = member;
        if (m.isKind(.@"pub")) m = ir.Pub.decl(m);
        if (m.isKind(.fun) or m.isKind(.sub)) try self.add(module, m, true, true);
    }

    fn add(self: *Pass, module: usize, node: Sexp, member: bool, generic_owner: bool) !void {
        const c = self.ctx(module);
        const name_node = ir.get(node, .name);
        const name = textOf(c, name_node);
        const body = ir.get(node, .body);
        const is_main = !member and self.mods[module].id == 1 and std.mem.eql(u8, name, "main");
        const eligible = body != .nil and !is_main and !generic_owner and onlyValueParams(node) and rig.markerOf(node) == .none;
        const idx: u32 = @intCast(self.fns.items.len);
        const pos = c.startOf(name_node);
        const gop = try self.by_name.getOrPut(self.a, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.groups.items.len);
            try self.groups.append(self.a, .{});
        }
        try self.groups.items[gop.value_ptr.*].members.append(self.a, idx);
        try self.fns.append(self.a, .{
            .module = module,
            .node = node,
            .name = name,
            .pos = pos,
            .eligible = eligible,
            .size = if (body != .nil) size(body) else 0,
            .group = gop.value_ptr.*,
        });
        if (body != .nil and holdsClosure(body)) self.fns.items[idx].eligible = false;
        try self.by_pos[module].put(self.a, pos, idx);
    }

    /// Every mention of a function in `e`, inside the function `cur`.
    fn visit(self: *Pass, module: usize, cur: ?u32, e: Sexp) std.mem.Allocator.Error!void {
        if (e == .src) return self.mention(module, e);
        if (e != .list) return;
        const kind = e.kind() orelse {
            for (e.items()) |c| try self.visit(module, cur, c);
            return;
        };
        switch (kind) {
            .use => return,
            .fun, .sub => {
                const idx = self.by_pos[module].get(self.ctx(module).startOf(ir.get(e, .name)));
                // Everything but the name.
                for (e.items()[2..]) |c| try self.visit(module, idx orelse cur, c);
            },
            .call => try self.visitCall(module, cur, e),
            .member => {
                const obj = ir.Member.object(e);
                try self.visit(module, cur, obj);
                self.mentionMember(module, e);
            },
            else => for (e.items()) |c| try self.visit(module, cur, c),
        }
    }

    /// A name that is not the callee of a call.
    fn mention(self: *Pass, module: usize, e: Sexp) void {
        const c = self.ctx(module);
        const id = c.symbolOf(e) orelse return;
        const s = c.symbols.items[id];
        if (s.kind != .function) return;
        if (self.by_pos[module].get(s.decl_pos)) |f| self.fns.items[f].used_as_value = true;
    }

    /// `object.name` that is not a callee: a field, or a function or
    /// method taken as a value.
    fn mentionMember(self: *Pass, module: usize, e: Sexp) void {
        const c = self.ctx(module);
        const name = textOf(c, ir.Member.name(e));
        const g = self.by_name.get(name) orelse return;
        // A data field of the receiver's type is not a method.
        if (c.typeOf(ir.Member.object(e))) |t| if (sema.nominalDecl(c, t)) |nom| {
            if (nom.ctx.symbols.items[nom.sym].fields) |fields| {
                if (sema.memberIn(nom.ctx, fields, name, .data) != null or sema.memberIn(nom.ctx, fields, name, .variant) != null) return;
            }
        };
        for (self.groups.items[g].members.items) |f| self.fns.items[f].used_as_value = true;
    }

    fn visitCall(self: *Pass, module: usize, cur: ?u32, call: Sexp) std.mem.Allocator.Error!void {
        const c = self.ctx(module);
        const raw = ir.Call.callee(call);
        const callee = c.calleeOf(call);
        var target: ?Callee = null;
        switch (callee.kind() orelse .set) {
            .member => {
                try self.visit(module, cur, ir.Member.object(callee));
                target = self.named(textOf(c, ir.Member.name(callee)));
            },
            else => if (callee == .src) {
                const id = c.symbolOf(callee);
                if (id) |sid| {
                    const s = c.symbols.items[sid];
                    if (s.kind == .function) target = self.by_pos[module].get(s.decl_pos);
                } else target = self.named(textOf(c, callee));
            } else try self.visit(module, cur, callee),
        }
        if (target) |t| {
            const first: First = .{ .seq = self.seq, .caller = cur };
            self.seq += 1;
            if (t & group_bit != 0) {
                const g = &self.groups.items[t & ~group_bit];
                g.calls += 1;
                if (g.first == null) g.first = first;
                if (cur) |from| try g.callers.append(self.a, from);
            } else {
                const f = &self.fns.items[t];
                f.direct_calls += 1;
                if (f.first == null) f.first = first;
                if (cur) |from| try f.callers.append(self.a, from);
            }
            if (cur) |from| try self.fns.items[from].calls.append(self.a, t);
            if (call.list.id != 0) try self.sites.append(self.a, .{ .module = module, .id = call.list.id, .callee = t });
        }
        // The bracket list of a generic call, `f[T](x)`.
        if (raw.isKind(.inst)) for (raw.items()[2..]) |a| try self.visit(module, cur, a);
        for (ir.Call.args(call)) |a| try self.visit(module, cur, a);
    }

    /// The group of the functions named `name`, which a call that resolves
    /// by name reaches.
    fn named(self: *Pass, name: []const u8) ?Callee {
        const g = self.by_name.get(name) orelse return null;
        return group_bit | g;
    }

    /// How many calls may reach each function, and the first of them:
    /// those of it, and those of its name's group.
    fn countCalls(self: *Pass) void {
        for (self.fns.items) |*f| {
            const g = &self.groups.items[f.group];
            f.call_sites = f.direct_calls + g.calls;
            const first = if (f.first) |x| (if (g.first) |y| (if (y.seq < x.seq) y else x) else x) else g.first;
            f.first_caller = if (first) |x| x.caller else null;
        }
    }

    /// What the calls of `v` that are inlined add to its frame: the sum, over
    /// its call sites, of the frame of each inlined callee.
    fn added(self: *Pass, v: u32) u128 {
        var total: u128 = 0;
        for (self.fns.items[v].calls.items) |t| total += self.calleeFrame(t);
        return total;
    }

    /// What a call of `t` adds to a frame: the frames of the inlined
    /// functions it reaches.
    fn calleeFrame(self: *Pass, t: Callee) u128 {
        if (t & group_bit == 0) return if (self.fns.items[t].inlined) self.frame(t) else 0;
        const g = &self.groups.items[t & ~group_bit];
        if (g.frame) |b| return b;
        var total: u128 = 0;
        for (g.members.items) |w| {
            if (self.fns.items[w].inlined) total += self.frame(w);
        }
        self.groups.items[t & ~group_bit].frame = total;
        return total;
    }

    /// The frame of an inlined function with its own inlined calls in it.
    /// No cycle of calls is inlined, so this ends.
    fn frame(self: *Pass, v: u32) u128 {
        if (self.fns.items[v].frame) |b| return b;
        const b = self.fns.items[v].own + self.added(v);
        self.fns.items[v].frame = b;
        return b;
    }

    /// The size of an inlined function with its own inlined calls in it.
    fn expanded(self: *Pass, v: u32) u64 {
        if (self.fns.items[v].weight) |w| return w;
        var total: u64 = self.fns.items[v].size;
        for (self.fns.items[v].calls.items) |t| total += self.calleeWeight(t);
        self.fns.items[v].weight = total;
        return total;
    }

    /// What a call of `t` adds to a size: the expansions of the inlined
    /// functions it reaches.
    fn calleeWeight(self: *Pass, t: Callee) u64 {
        if (t & group_bit == 0) return if (self.fns.items[t].inlined) self.expanded(t) else 0;
        const g = &self.groups.items[t & ~group_bit];
        if (g.weight) |w| return w;
        var total: u64 = 0;
        for (g.members.items) |w| {
            if (self.fns.items[w].inlined) total += self.expanded(w);
        }
        self.groups.items[t & ~group_bit].weight = total;
        return total;
    }

    /// Whether `f` is called from one place, in a function with
    /// compile-time values: each instance of that function holds a copy of
    /// `f`, which no one call site of an ordinary function does, so the
    /// copies are the ones Zig counts and LLVM cannot merge.
    fn oncePerInstance(self: *Pass, f: *const Fn) bool {
        if (f.call_sites != 1) return false;
        const caller = f.first_caller orelse return false;
        return sema.tparamsOf(self.fns.items[caller].node) != .nil;
    }

    /// Stop inlining until no function adds more than
    /// `max_inlined_frame_bytes` of reach to its frame, no function has a
    /// frame of more than `sema.max_frame_bytes` with the reach of the
    /// inlined calls in it, no inlined function has a reach of more than
    /// `max_inlined_frame_bytes`, and none expands to more than
    /// `max_expanded` nodes: in order, at the first function that breaks
    /// a rule, stop inlining it or the largest of its inlined calls, and
    /// look again.
    ///
    /// Each step only shrinks frames and expansions, so no function before
    /// the one that broke a rule breaks one after it: the search goes on
    /// from that function, not from the first, and forgets only the frames
    /// and expansions that counted the call no longer inlined
    /// (`uninline`).
    fn fit(self: *Pass) !void {
        var i: usize = 0;
        while (i < self.fns.items.len) {
            const v: u32 = @intCast(i);
            const f = &self.fns.items[i];
            if (f.inlined and (self.frame(v) > max_inlined_frame_bytes or (self.expanded(v) > max_expanded and !self.oncePerInstance(f)))) {
                try self.uninline(v);
                continue;
            }
            if (self.added(v) <= max_inlined_frame_bytes and f.count + self.added(v) <= sema.max_frame_bytes) {
                i += 1;
                continue;
            }
            // The largest of the inlined calls, the first of them in the
            // order of the calls and of a group's functions.
            var biggest: ?u32 = null;
            for (f.calls.items) |t| {
                const w = self.largest(t) orelse continue;
                if (biggest == null or self.frame(w) > self.frame(biggest.?)) biggest = w;
            }
            try self.uninline(biggest.?);
        }
    }

    /// The inlined function a call of `t` reaches with the largest frame,
    /// the first of them in a group's order.
    fn largest(self: *Pass, t: Callee) ?u32 {
        if (t & group_bit == 0) return if (self.fns.items[t].inlined) t else null;
        const gi = t & ~group_bit;
        if (self.groups.items[gi].top) |top| return top.fun;
        var best: ?u32 = null;
        for (self.groups.items[gi].members.items) |w| {
            if (!self.fns.items[w].inlined) continue;
            if (best == null or self.frame(w) > self.frame(best.?)) best = w;
        }
        self.groups.items[gi].top = .{ .fun = best };
        return best;
    }

    /// Stop inlining `w`, and forget the frame and expansion of every
    /// function and group that counted it: those with a call of it or of
    /// its group, and theirs through each function inlined.
    fn uninline(self: *Pass, w: u32) !void {
        self.fns.items[w].inlined = false;
        self.epoch += 1;
        self.work.clearRetainingCapacity();
        try self.reachers(w);
        while (self.work.pop()) |t| {
            if (t & group_bit != 0) {
                const g = &self.groups.items[t & ~group_bit];
                if (g.forgot == self.epoch) continue;
                g.forgot = self.epoch;
                g.frame = null;
                g.weight = null;
                g.top = null;
                try self.work.appendSlice(self.a, g.callers.items);
            } else {
                const u = &self.fns.items[t];
                if (u.forgot == self.epoch) continue;
                u.forgot = self.epoch;
                u.frame = null;
                u.weight = null;
                if (u.inlined) try self.reachers(t);
            }
        }
    }

    /// Queue for `uninline` what counts the frame of `w`: the functions
    /// with a call of it, and its group.
    fn reachers(self: *Pass, w: u32) !void {
        try self.work.appendSlice(self.a, self.fns.items[w].callers.items);
        try self.work.append(self.a, group_bit | self.fns.items[w].group);
    }

    // ---- cycles ----------------------------------------------------------

    /// The node Tarjan's search numbers `t` by: a function by its index,
    /// a group after every function.
    fn nodeOf(self: *const Pass, t: Callee) u32 {
        return if (t & group_bit != 0) @as(u32, @intCast(self.fns.items.len)) + (t & ~group_bit) else t;
    }

    fn state(self: *Pass, n: u32) *Tarjan {
        const nf: u32 = @intCast(self.fns.items.len);
        return if (n < nf) &self.fns.items[n].node_state else &self.groups.items[n - nf].node_state;
    }

    /// What node `n` leads to: a function's calls, a group's functions.
    fn edges(self: *Pass, n: u32, i: usize) ?u32 {
        const nf: u32 = @intCast(self.fns.items.len);
        if (n < nf) {
            const calls = self.fns.items[n].calls.items;
            return if (i < calls.len) self.nodeOf(calls[i]) else null;
        }
        const members = self.groups.items[n - nf].members.items;
        return if (i < members.len) members[i] else null;
    }

    /// Mark every function on a cycle of calls (Tarjan), a call that
    /// reaches a group leading to each function in it: a function with a
    /// call of its own group is on a cycle, as one that calls itself is.
    fn strong(self: *Pass, v: u32) !void {
        const sv = self.state(v);
        sv.index = self.next_index;
        sv.low = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.a, v);
        sv.on_stack = true;
        var self_loop = false;
        var i: usize = 0;
        while (self.edges(v, i)) |w| : (i += 1) {
            if (w == v) self_loop = true;
            if (self.state(w).index == 0) {
                try self.strong(w);
                self.state(v).low = @min(self.state(v).low, self.state(w).low);
            } else if (self.state(w).on_stack) {
                self.state(v).low = @min(self.state(v).low, self.state(w).index);
            }
        }
        if (self_loop) self.cyclic.items[v] = true;
        if (self.state(v).low == self.state(v).index) {
            var members: u32 = 0;
            const start = self.stack.items.len;
            var k = start;
            while (k > 0) {
                k -= 1;
                members += 1;
                if (self.stack.items[k] == v) break;
            }
            for (self.stack.items[k..start]) |w| {
                self.state(w).on_stack = false;
                if (members > 1) self.cyclic.items[w] = true;
            }
            self.stack.shrinkRetainingCapacity(k);
        }
    }

    fn findCycles(self: *Pass) !void {
        const n = self.fns.items.len + self.groups.items.len;
        try self.cyclic.appendNTimes(self.a, false, n);
        for (0..n) |v| if (self.state(@intCast(v)).index == 0) try self.strong(@intCast(v));
    }

    fn isCyclic(self: *const Pass, v: u32) bool {
        return self.cyclic.items[v];
    }
};

/// The forms in `e`, each node of the tree once.
pub fn size(e: Sexp) u32 {
    if (e != .list) return 0;
    var n: u32 = if (e.kind() != null) 1 else 0;
    for (e.items()) |c| n += size(c);
    return n;
}

/// Whether every compile-time parameter of `node` is a value (`n: Int`,
/// `dense: Bool`), none a type (`T`): each instance is then a function of
/// a known frame, sized and inlined as any other.
fn onlyValueParams(node: Sexp) bool {
    const tp = sema.tparamsOf(node);
    if (tp == .nil) return true;
    for (tp.items()) |p| if (p != .list) return false;
    return true;
}

fn holdsClosure(e: Sexp) bool {
    if (e != .list) return false;
    if (e.isKind(.lambda)) return true;
    for (e.items()) |c| if (holdsClosure(c)) return true;
    return false;
}

/// Decide, for every module of a program with no errors, which functions
/// are emitted `inline`, and record them in the modules' contexts.
/// `max` is the largest body to inline (`max_size`).
pub fn decide(allocator: std.mem.Allocator, graph: *modules.ModuleGraph, max: u32) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = try a.alloc(*modules.Module, graph.modules.items.len);
    for (graph.modules.items, mods) |*m, *out| out.* = m;
    var pass: Pass = .{ .a = a, .mods = mods, .by_pos = try a.alloc(std.AutoHashMapUnmanaged(u32, u32), mods.len), .max = max };
    for (pass.by_pos) |*m| m.* = .empty;
    for (mods, 0..) |m, i| try pass.collect(i, m.ir);
    for (mods, 0..) |m, i| try pass.visit(i, null, m.ir);
    pass.countCalls();
    try pass.findCycles();
    // A large frame found at an instance another module makes marks its
    // declaration in its own module (module ids count from 1).
    for (mods) |m| for (m.sema.large_foreign_frames.items) |fr| try mods[fr.module - 1].sema.large_frames.put(allocator, fr.pos, {});
    for (pass.fns.items) |*f| {
        if (ir.get(f.node, .body) == .nil) continue;
        const fc = (try typecheck.frameBytesOfFunction(mods[f.module].sema, f.node)) orelse {
            // A frame that depends on a compile-time value is unknown.
            if (sema.tparamsOf(f.node) != .nil) f.eligible = false;
            continue;
        };
        f.own = fc.reach;
        f.count = fc.bytes;
    }
    for (pass.fns.items, 0..) |*f, v| {
        if (!f.eligible or f.used_as_value or pass.isCyclic(@intCast(v)) or f.size > max) continue;
        if (f.own > max_inlined_frame_bytes or mods[f.module].sema.large_frames.contains(f.pos)) continue;
        f.inlined = true;
    }
    try pass.fit();
    for (pass.fns.items, 0..) |f, v| {
        if (f.inlined) try mods[f.module].sema.inlined.put(allocator, f.pos, {});
        // A function large with the calls inlined into it is never inlined
        // by Zig either.
        if (!f.inlined and (f.own + pass.added(@intCast(v))) * sema.reach_factor >= sema.noinline_reach)
            try mods[f.module].sema.large_frames.put(allocator, f.pos, {});
    }
    // A call that may reach an inlined function hands back a value Zig
    // would know at compile time (`Emitter.emitCallDirect`).
    for (pass.sites.items) |site| {
        const one = [1]u32{site.callee};
        const reached: []const u32 = if (site.callee & group_bit != 0) pass.groups.items[site.callee & ~group_bit].members.items else &one;
        for (reached) |t| if (pass.fns.items[t].inlined) {
            try mods[site.module].sema.inlined_calls.put(allocator, site.id, {});
            break;
        };
    }
}
