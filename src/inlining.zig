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
//!     and holds no closure,
//!   - and the frame of every frame owner it lands in stays within its
//!     account's limits (`fit`).
//!
//! What a call reaches is the one fact typecheck records where it
//! resolves the call (`SemContext.callTargetOf`): a function by its
//! symbol, a method by its receiver's type. A call no check resolved
//! reaches, by its name, every function of that name (`Group`), so the
//! analysis only ever finds more cycles than there are, never fewer.
//!
//! Every frame Zig writes is a frame owner (`sema.FrameOwner`), and every
//! call is in exactly one (`SemContext.ownerOf`): the pass reads both from
//! typecheck and finds neither itself. An inlined function's body lands in
//! the owner of each call of it, so each owner's account
//! (`sema.Account`) holds what the rule inlines into it.
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

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const FrameCount = sema.FrameCount;

/// The most nodes (each form of the tree: a call, an operator, a
/// statement) a body may have and be inlined.
pub const max_size = 60;

/// The most reach (`typecheck.checkFrames`) the functions the rule
/// inlines may add to one frame owner, and an inlined function may have,
/// each inlined call counted at every call and at every copy Zig writes
/// of it. Zig writes an inlined body, its locals and its temporaries,
/// again at each call, in the caller's frame, so an owner's own frame
/// with the inlined ones in it also stays within `sema.max_frame_bytes`,
/// which `typecheck.checkFrames` holds the owner's own frame to, and its
/// reach within `sema.max_frame_reach`: inlining stops short of either.
pub const max_inlined_frame_bytes: u128 = 64 << 10;

/// The most nodes an inlined function may expand to at a call, counting
/// the inlined calls in it (each of them as often as it is called):
/// otherwise a chain of functions that each call the next twice would make
/// Zig analyze a body 2^n times. A function with one call, in a function
/// with compile-time values, is exempt: its expansion is counted in each
/// instance of the caller. std.json, the program that set
/// `max_size`, has a hot helper (`key`) that expands to 287.
pub const max_expanded = 320;

/// A function or method, the one frame owner the rule may inline.
const Fn = struct {
    module: usize,
    /// Its frame owner (`Pass.owners`).
    owner: u32,
    node: Sexp,
    name: []const u8,
    /// Where the name is declared, which `Facts.isInlined` asks by.
    pos: u32,
    size: u32 = 0,
    /// Whether the declaration alone allows inlining.
    eligible: bool,
    /// Mentioned other than as a callee.
    used_as_value: bool = false,
    /// The functions with a call of it, once for each such call.
    callers: std.ArrayList(u32) = .empty,
    /// Its name's group (`Group`).
    group: u32 = 0,
    inlined: bool = false,
    /// Its frame with the inlined calls in it (`frame`).
    frame: ?u128 = null,
    /// How many calls may reach it: those of it, and those of its name's
    /// group.
    call_sites: u32 = 0,
    /// The function around the first call that may reach it.
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

/// A frame owner (`sema.FrameOwner`), as the pass counts it.
const Owner = struct {
    /// Its function, for a function.
    fun: ?u32,
    /// The function whose instances it is written in: its own, a closure's
    /// nearest function around it; null for a test or a `drop` body
    /// (`oncePerInstance`).
    in_fn: ?u32,
    /// Its own frame: the count `checkFrames` made, or for a generic one
    /// the largest of its instances'; null when no count knows it.
    own: ?FrameCount,
    /// Whether this build compiles it: a test block, and what is in one,
    /// only under `rig test` (`ModuleGraph.with_tests`), and only the
    /// root module's. A frame Zig never writes holds nothing the rule
    /// inlines, so its account bounds nothing.
    compiled: bool = true,
    /// What its calls reach, once for each call, with the copies of it.
    calls: std.ArrayList(Edge) = .empty,
};

const Edge = struct { callee: Callee, copies: u32 };

/// The functions of one name, which a call no check resolved reaches all
/// of: such a call is one edge to the group, not one to each, so the
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

/// A call, by the order the calls are met in, and the function around it.
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

/// An owner's frame, by its declaring module's id and where it is
/// declared (`sema.FrameSize`).
const OwnerKey = struct { module: u32, pos: u32 };

const Pass = struct {
    a: std.mem.Allocator,
    mods: []const *modules.Module,
    fns: std.ArrayList(Fn) = .empty,
    owners: std.ArrayList(Owner) = .empty,
    /// Per module: the index in `owners` of its first owner.
    owner_base: []u32,
    groups: std.ArrayList(Group) = .empty,
    /// Each call that may reach a function, and what.
    sites: std.ArrayList(Site) = .empty,
    /// A name -> its group.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    /// Per module: the function declared at a position.
    by_pos: []std.AutoHashMapUnmanaged(u32, u32),
    max: u32,
    /// Whether this build compiles the root module's tests.
    with_tests: bool,
    /// The calls met so far.
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

    /// The owners of module `module`, and its functions among them.
    fn collect(self: *Pass, module: usize, instances: *const std.AutoHashMapUnmanaged(OwnerKey, FrameCount)) !void {
        const c = self.ctx(module);
        const base = self.owner_base[module];
        for (c.frame_owners.items, 0..) |o, k| {
            const index: u32 = base + @as(u32, @intCast(k));
            const parent_fn = if (o.parent) |p| self.owners.items[base + p].in_fn else null;
            const compiled = if (o.parent) |p| self.owners.items[base + p].compiled else o.kind != .test_block or (self.with_tests and self.mods[module].id == 1);
            // A generic owner's frame is its instances': the largest of
            // them, and none if no instance is made, since Zig writes no
            // frame for it then.
            const own: ?FrameCount = if (o.per_instance)
                instances.get(.{ .module = c.module_id, .pos = o.pos }) orelse .{ .bytes = 0, .reach = 0 }
            else
                o.own;
            try self.owners.append(self.a, .{ .fun = null, .in_fn = parent_fn, .own = own, .compiled = compiled });
            if (o.kind != .function) continue;
            const v = try self.add(module, index, o);
            self.owners.items[index].fun = v;
            self.owners.items[index].in_fn = v;
        }
    }

    fn add(self: *Pass, module: usize, owner: u32, o: sema.FrameOwner) !u32 {
        const c = self.ctx(module);
        const node = o.root;
        const name = textOf(c, ir.get(node, .name));
        const body = ir.get(node, .body);
        const is_main = !o.member and self.mods[module].id == 1 and std.mem.eql(u8, name, "main");
        var eligible = body != .nil and !is_main and !o.of_generic_type and onlyValueParams(node) and rig.markerOf(node) == .none;
        if (body != .nil and holdsClosure(body)) eligible = false;
        // A frame that depends on a compile-time value is unknown.
        if (o.per_instance and sema.tparamsOf(node) != .nil) eligible = false;
        const idx: u32 = @intCast(self.fns.items.len);
        const gop = try self.by_name.getOrPut(self.a, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.groups.items.len);
            try self.groups.append(self.a, .{});
        }
        try self.groups.items[gop.value_ptr.*].members.append(self.a, idx);
        try self.fns.append(self.a, .{
            .module = module,
            .owner = owner,
            .node = node,
            .name = name,
            .pos = o.pos,
            .eligible = eligible,
            .size = if (body != .nil) size(body) else 0,
            .group = gop.value_ptr.*,
        });
        try self.by_pos[module].put(self.a, o.pos, idx);
        return idx;
    }

    /// Every mention of a function in `e` that is not a call's callee.
    fn mentions(self: *Pass, module: usize, e: Sexp) std.mem.Allocator.Error!void {
        if (e == .src) return self.mention(module, e);
        if (e != .list) return;
        const kind = e.kind() orelse {
            for (e.items()) |c| try self.mentions(module, c);
            return;
        };
        switch (kind) {
            .use => return,
            // Everything but the name.
            .fun, .sub => for (e.items()[2..]) |c| try self.mentions(module, c),
            .call => {
                const raw = ir.Call.callee(e);
                const callee = self.ctx(module).calleeOf(e);
                if (callee.isKind(.member)) {
                    try self.mentions(module, ir.Member.object(callee));
                } else if (callee != .src) try self.mentions(module, callee);
                // The bracket list of a generic call, `f[T](x)`.
                if (raw.isKind(.inst)) for (raw.items()[2..]) |a| try self.mentions(module, a);
                for (ir.Call.args(e)) |a| try self.mentions(module, a);
            },
            .member => {
                try self.mentions(module, ir.Member.object(e));
                self.mentionMember(module, e);
            },
            else => for (e.items()) |c| try self.mentions(module, c),
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

    /// What the call `fc` of module `module` reaches: the function
    /// typecheck resolved it to, or, for a call no check resolved, every
    /// function its callee's name may stand for.
    fn target(self: *Pass, module: usize, call: Sexp) ?Callee {
        const c = self.ctx(module);
        if (c.callTargetOf(call)) |t| switch (t) {
            .none => return null,
            .function => |ref| {
                if (ref.module >= 1 and ref.module <= self.mods.len) {
                    if (self.by_pos[ref.module - 1].get(ref.pos)) |f| return f;
                }
            },
        };
        const callee = c.calleeOf(call);
        if (callee.isKind(.member)) return self.named(textOf(c, ir.Member.name(callee)));
        if (callee != .src) return null;
        const id = c.symbolOf(callee) orelse return self.named(textOf(c, callee));
        const s = c.symbols.items[id];
        if (s.kind != .function) return null;
        return self.by_pos[module].get(s.decl_pos) orelse self.named(textOf(c, callee));
    }

    /// The calls of module `module`, each to its owner (`ownerOf`).
    fn calls(self: *Pass, module: usize) !void {
        const c = self.ctx(module);
        const base = self.owner_base[module];
        for (c.frame_calls.items) |fc| {
            const t = self.target(module, fc.node) orelse continue;
            const owner: ?u32 = if (fc.owner) |o| base + o else null;
            const from: ?u32 = if (owner) |o| self.owners.items[o].fun else null;
            const first: First = .{ .seq = self.seq, .caller = if (owner) |o| self.owners.items[o].in_fn else null };
            self.seq += 1;
            if (t & group_bit != 0) {
                const g = &self.groups.items[t & ~group_bit];
                g.calls += 1;
                if (g.first == null) g.first = first;
                if (from) |f| try g.callers.append(self.a, f);
            } else {
                const f = &self.fns.items[t];
                f.direct_calls += 1;
                if (f.first == null) f.first = first;
                if (from) |v| try f.callers.append(self.a, v);
            }
            if (owner) |o| try self.owners.items[o].calls.append(self.a, .{ .callee = t, .copies = fc.copies });
            if (fc.node == .list and fc.node.list.id != 0) try self.sites.append(self.a, .{ .module = module, .id = fc.node.list.id, .callee = t });
        }
    }

    /// The group of the functions named `name`, which a call no check
    /// resolved reaches.
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

    /// What the functions the rule inlines add to owner `o`'s frame (its
    /// account's `auto`): the frame of each inlined callee of each of its
    /// calls, at every copy of the call.
    fn added(self: *Pass, o: u32) u128 {
        var total: u128 = 0;
        for (self.owners.items[o].calls.items) |e| total += e.copies * self.calleeFrame(e.callee);
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
    /// No cycle of calls is inlined, so this ends, and an inlined
    /// function's own frame is known (`collect`).
    fn frame(self: *Pass, v: u32) u128 {
        if (self.fns.items[v].frame) |b| return b;
        const o = self.fns.items[v].owner;
        const b = self.owners.items[o].own.?.reach + self.added(o);
        self.fns.items[v].frame = b;
        return b;
    }

    /// The size of an inlined function with its own inlined calls in it.
    fn expanded(self: *Pass, v: u32) u64 {
        if (self.fns.items[v].weight) |w| return w;
        var total: u64 = self.fns.items[v].size;
        for (self.owners.items[self.fns.items[v].owner].calls.items) |e| total += self.calleeWeight(e.callee);
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

    /// Whether owner `o`'s account fits: the functions the rule inlines
    /// into it add at most `max_inlined_frame_bytes`, its own frame with
    /// them stays within `sema.max_frame_bytes`, and its reach with them
    /// within `sema.max_frame_reach` (`reach_factor` times over). An owner
    /// whose own frame no count knows fits only with nothing inlined into
    /// it; one this build does not compile fits.
    fn fits(self: *Pass, o: u32) bool {
        if (!self.owners.items[o].compiled) return true;
        const auto = self.added(o);
        const own = self.owners.items[o].own orelse return auto == 0;
        return auto <= max_inlined_frame_bytes and own.bytes + auto <= sema.max_frame_bytes and (own.reach + auto) * sema.reach_factor <= sema.max_frame_reach;
    }

    /// Stop inlining until every owner's account fits (`fits`), no
    /// inlined function has a frame of more than `max_inlined_frame_bytes`
    /// with the inlined calls in it, and none expands to more than
    /// `max_expanded` nodes: in order, at the first owner that breaks a
    /// rule, stop inlining it or the largest of its inlined calls, and look
    /// again.
    ///
    /// Each step only shrinks frames and expansions, so no owner before the
    /// one that broke a rule breaks one after it: the search goes on from
    /// that owner, not from the first, and forgets only the frames and
    /// expansions that counted the call no longer inlined (`uninline`).
    fn fit(self: *Pass) !void {
        var i: usize = 0;
        while (i < self.owners.items.len) {
            const o: u32 = @intCast(i);
            if (self.owners.items[i].fun) |v| {
                const f = &self.fns.items[v];
                if (f.inlined and (self.frame(v) > max_inlined_frame_bytes or (self.expanded(v) > max_expanded and !self.oncePerInstance(f)))) {
                    try self.uninline(v);
                    continue;
                }
            }
            if (self.fits(o)) {
                i += 1;
                continue;
            }
            // The largest of the inlined calls, the first of them in the
            // order of the calls and of a group's functions.
            var biggest: ?u32 = null;
            for (self.owners.items[i].calls.items) |e| {
                const w = self.largest(e.callee) orelse continue;
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
            const calls_of = self.owners.items[self.fns.items[n].owner].calls.items;
            return if (i < calls_of.len) self.nodeOf(calls_of[i].callee) else null;
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
/// are emitted `inline`, record them in the modules' contexts, and fill
/// every frame owner's account (`SemContext.account`). `max` is the
/// largest body to inline (`max_size`).
pub fn decide(allocator: std.mem.Allocator, graph: *modules.ModuleGraph, max: u32) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = try a.alloc(*modules.Module, graph.modules.items.len);
    for (graph.modules.items, mods) |*m, *out| out.* = m;
    var pass: Pass = .{
        .a = a,
        .mods = mods,
        .by_pos = try a.alloc(std.AutoHashMapUnmanaged(u32, u32), mods.len),
        .owner_base = try a.alloc(u32, mods.len),
        .max = max,
        .with_tests = graph.with_tests,
    };
    for (pass.by_pos) |*m| m.* = .empty;
    // Each generic owner's frame at its instances, wherever they are made:
    // the largest.
    var instances: std.AutoHashMapUnmanaged(OwnerKey, FrameCount) = .empty;
    for (mods) |m| for (m.sema.frame_sizes.items) |fr| {
        const gop = try instances.getOrPut(a, .{ .module = fr.module, .pos = fr.decl });
        if (!gop.found_existing) gop.value_ptr.* = .{ .bytes = 0, .reach = 0 };
        gop.value_ptr.bytes = @max(gop.value_ptr.bytes, fr.bytes);
        gop.value_ptr.reach = @max(gop.value_ptr.reach, fr.reach);
    };
    var base: u32 = 0;
    for (mods, 0..) |m, i| {
        pass.owner_base[i] = base;
        base += @intCast(m.sema.frame_owners.items.len);
    }
    for (0..mods.len) |i| try pass.collect(i, &instances);
    for (mods, 0..) |m, i| try pass.mentions(i, m.ir);
    for (0..mods.len) |i| try pass.calls(i);
    pass.countCalls();
    try pass.findCycles();
    // A large frame found at an instance another module makes marks its
    // declaration in its own module (module ids count from 1).
    for (mods) |m| for (m.sema.large_foreign_frames.items) |fr| try mods[fr.module - 1].sema.large_frames.put(allocator, fr.pos, {});
    for (pass.fns.items, 0..) |*f, v| {
        if (!f.eligible or f.used_as_value or pass.isCyclic(@intCast(v)) or f.size > max) continue;
        const own = pass.owners.items[f.owner].own orelse continue;
        if (own.reach > max_inlined_frame_bytes or mods[f.module].sema.large_frames.contains(f.pos)) continue;
        f.inlined = true;
    }
    try pass.fit();
    for (pass.fns.items) |f| {
        if (f.inlined) try mods[f.module].sema.inlined.put(allocator, f.pos, {});
    }
    // Every owner's account. An owner large with the calls inlined into it
    // is never inlined by Zig either: a function, a closure's body, or a
    // `drop` body (`Facts.isLargeFrame`, `Facts.isLargeOwner`).
    for (mods, 0..) |m, i| for (m.sema.frame_owners.items, 0..) |*o, k| {
        const index = pass.owner_base[i] + @as(u32, @intCast(k));
        const own = pass.owners.items[index].own;
        const auto = pass.added(index);
        o.account = .{ .own = own, .auto = auto };
        if (pass.owners.items[index].fun) |v| if (pass.fns.items[v].inlined) continue;
        const known = own orelse continue;
        if ((known.reach + auto) * sema.reach_factor >= sema.noinline_reach) try m.sema.large_frames.put(allocator, o.pos, {});
    };
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
