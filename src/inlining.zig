//! Which functions are emitted `inline`: decided once, for the whole
//! program, after every module is checked (docs/INTERNALS.md, "Inlining").
//!
//! A function marked `inline fun` is emitted `inline fn`, whatever its
//! size, and one marked `called fun` or `rarely fun` never is; the rule
//! below decides the rest. A cycle of calls of marked `inline` functions
//! is an error (`forcedCycles`). What a marked function's values land in
//! each frame owner that calls it is typecheck's to count (the account's
//! `marked` part, `typecheck.checkFrames`); what the rule inlines into it
//! lands in that owner too, so this pass counts it there (`added`). The
//! sizes below never undo a marker, they only choose among the functions
//! the compiler picked.
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
//!     and inlined as any function), and holds no closure,
//!   - and the frame of every frame owner it lands in stays within its
//!     account's limits (`fit`).
//!
//! A member of a generic type is one declaration Zig writes once for all
//! its instances, so it is decided once, under the largest frame of its
//! instances (`collect`), which bounds each.
//!
//! What a call reaches is the one fact typecheck records where it
//! resolves the call (`SemContext.callTargetOf`): a function by its
//! symbol, a method by its receiver's type. A call no check resolved
//! reaches, by its name, every function of that name (`Group`), so the
//! analysis only ever finds more cycles than there are, never fewer. A
//! call of a marked `inline` function is always resolved: none is read
//! by its name.
//!
//! Every frame Zig writes is a frame owner (`sema.FrameOwner`), and every
//! call is in exactly one (`SemContext.ownerOf`): the pass reads both from
//! typecheck and finds neither itself. An inlined function's body lands in
//! the owner of each call of it, so each owner's account
//! (`sema.Account`) holds what the rule inlines into it, through the
//! marked `inline` functions it calls as well.
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
const Error = std.mem.Allocator.Error;

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
    /// Whether the declaration alone allows the rule to inline it.
    eligible: bool,
    /// Its marker: `inline` inlines it at every call, `called` and
    /// `rarely` never.
    marker: rig.Marker,
    /// Mentioned other than as a callee.
    used_as_value: bool = false,
    /// The functions with a call of it, once for each such call.
    callers: std.ArrayList(u32) = .empty,
    /// Its name's group (`Group`).
    group: u32 = 0,
    inlined: bool = false,
    /// What it adds to a caller's frame (`frame`).
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
    /// The search for cycles of marked `inline` functions (`forcedCycles`).
    color: enum { white, gray, black } = .white,
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
    /// What marked `inline` calls land in it, as `checkFrames` counted
    /// them, or for a generic one what the largest of its instances adds
    /// to `own` (`collect`).
    marked: FrameCount = .none,
    /// Its parameters' copies where it is inlined
    /// (`sema.FrameOwner.params`), the largest of a generic one's.
    params: u128 = 0,
    /// Whether this build compiles it: a test block, and what is in one,
    /// only under `rig test` (`ModuleGraph.with_tests`), and only the
    /// root module's; a generic one only at an instance. A frame Zig
    /// never writes holds nothing the rule inlines, so its account bounds
    /// nothing.
    compiled: bool = true,
    /// What its calls reach, once for each call, with the copies of it.
    calls: std.ArrayList(Edge) = .empty,
    /// How messages name its function's type, for a method.
    type_name: []const u8 = "",
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

/// The largest frame of a generic owner's instances: its own values, and
/// its own with what marked calls land in it, each the largest of any
/// instance.
const Instances = struct { own: FrameCount, total: FrameCount, params: u128 = 0 };

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
    /// Each generic owner's frame at its instances (`Instances`).
    instances: std.AutoHashMapUnmanaged(OwnerKey, Instances) = .empty,
    /// The compile-time parameters some instance the program makes binds,
    /// each by its declaration (`instanceMade`).
    bound: std.AutoHashMapUnmanaged(sema.ForeignRef, void) = .empty,
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
    /// The cycles of marked `inline` functions reported.
    cycles: u32 = 0,

    fn ctx(self: *Pass, module: usize) *const SemContext {
        return self.mods[module].sema;
    }

    /// The owners of module `module`, and its functions among them.
    fn collect(self: *Pass, module: usize) !void {
        const c = self.ctx(module);
        const base = self.owner_base[module];
        for (c.frame_owners.items, 0..) |o, k| {
            const index: u32 = base + @as(u32, @intCast(k));
            const parent_fn = if (o.parent) |p| self.owners.items[base + p].in_fn else null;
            var compiled = if (o.parent) |p| self.owners.items[base + p].compiled else o.kind != .test_block or (self.with_tests and self.mods[module].id == 1);
            var own: ?FrameCount = o.own;
            var marked = o.marked;
            var params = o.params;
            // A generic owner's frame is its instances': the largest of
            // them. One no instance the program makes binds is a frame Zig
            // never writes; one whose instances made no count is unknown,
            // never none.
            if (o.per_instance) {
                if (self.instances.get(.{ .module = c.module_id, .pos = o.pos })) |in| {
                    own = in.own;
                    marked = .{ .bytes = in.total.bytes - in.own.bytes, .reach = in.total.reach - in.own.reach };
                    params = in.params;
                } else {
                    own = null;
                    marked = .none;
                    if (!try self.instanceMade(c, o)) compiled = false;
                }
            }
            try self.owners.append(self.a, .{ .fun = null, .in_fn = parent_fn, .own = own, .marked = marked, .params = params, .compiled = compiled, .type_name = o.type_name });
            if (o.kind != .function) continue;
            const v = try self.add(module, index, o);
            self.owners.items[index].fun = v;
            self.owners.items[index].in_fn = v;
        }
    }

    /// Whether some instance the program makes binds every compile-time
    /// parameter the frame of the generic owner `o` of `c` holds: those
    /// it does not bind leave the frame generic, and Zig writes none.
    fn instanceMade(self: *Pass, c: *const SemContext, o: sema.FrameOwner) !bool {
        for (c.generic_frames.items) |fr| {
            if (fr.module_id != 0 or fr.pos != o.pos) continue;
            for (fr.tys) |ty| if (!try self.paramsBound(c, ty)) return false;
            return true;
        }
        // No generic frame: the owner holds nothing generic, which
        // `checkFrames` counted on its own, so it is never per instance.
        return true;
    }

    /// Whether every compile-time parameter `ty` holds is bound by some
    /// instance the program makes (`bound`).
    fn paramsBound(self: *Pass, c: *const SemContext, ty: sema.TypeId) !bool {
        if (!c.typeInfo(ty).has_type_var) return true;
        switch (c.types.get(ty)) {
            .type_var, .ct_param => |sym| return self.bound.contains(originOf(c, sym)),
            else => {},
        }
        var it = sema.typeChildren(c, ty);
        while (it.next()) |child| if (!try self.paramsBound(c, child)) return false;
        return true;
    }

    /// The parameters every instance module `c` makes binds (`bound`):
    /// a generic type's, and a generic function's, its type's included.
    fn bind(self: *Pass, c: *const SemContext) !void {
        var it = c.instantiation_sites.keyIterator();
        while (it.next()) |ty| switch (c.types.get(ty.*)) {
            .parameterized_nominal => |pn| for (c.symbols.items[pn.sym].type_params orelse &.{}) |p| try self.bound.put(self.a, originOf(c, p), {}),
            else => {},
        };
        for (c.fn_instances.items) |f| for (f.inst.params) |p| try self.bound.put(self.a, originOf(c, p), {});
    }

    fn add(self: *Pass, module: usize, owner: u32, o: sema.FrameOwner) !u32 {
        const c = self.ctx(module);
        const node = o.root;
        const name = textOf(c, ir.get(node, .name));
        const body = ir.get(node, .body);
        const is_main = !o.member and self.mods[module].id == 1 and std.mem.eql(u8, name, "main");
        const marker = rig.markerOf(node);
        var eligible = body != .nil and !is_main and onlyValueParams(node) and marker == .none;
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
            .marker = marker,
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
    /// calls, at every copy of the call, through each marked `inline`
    /// callee, whose own inlined calls land in `o` too.
    fn added(self: *Pass, o: u32) Error!u128 {
        var total: u128 = 0;
        for (self.owners.items[o].calls.items) |e| total += e.copies * try self.calleeFrame(e.callee);
        return total;
    }

    /// What a call of `t` adds to a frame beside what typecheck counted:
    /// the frames of the functions it reaches that the rule inlines, and
    /// what the rule inlines into a marked `inline` one (`frame`). A call
    /// by name never reaches a marked one (`byRule`).
    fn calleeFrame(self: *Pass, t: Callee) Error!u128 {
        if (t & group_bit == 0) return if (self.fns.items[t].inlined) self.frame(t) else 0;
        try self.settle(.frame, t);
        return self.groups.items[t & ~group_bit].frame.?;
    }

    /// What an inlined function adds to the frame of a call of it, with
    /// its own inlined calls in it, beside what typecheck counted there:
    /// for one the rule inlines, its own values, its parameters' copies,
    /// what marked calls land in it, and what the rule inlines into it;
    /// for a marked `inline`
    /// one, whose values and marked calls typecheck counts in the caller
    /// (`sema.Account.marked`), what the rule inlines into it. No cycle
    /// of calls is inlined (`forcedCycles`, `isCyclic`), so this ends, and
    /// the own frame of a function the rule inlines is known (`decide`).
    fn frame(self: *Pass, v: u32) Error!u128 {
        try self.settle(.frame, v);
        return self.fns.items[v].frame.?;
    }

    /// The size of an inlined function with its own inlined calls in it.
    fn expanded(self: *Pass, v: u32) Error!u64 {
        try self.settle(.weight, v);
        return self.fns.items[v].weight.?;
    }

    /// What a call of `t` adds to a size: the expansions of the inlined
    /// functions it reaches, marked or by the rule; by name, those the
    /// rule inlines.
    fn calleeWeight(self: *Pass, t: Callee) Error!u64 {
        if (t & group_bit == 0) return if (self.fns.items[t].inlined) self.expanded(t) else 0;
        try self.settle(.weight, t);
        return self.groups.items[t & ~group_bit].weight.?;
    }

    /// What `settle` finds of a function or group: its frame (`frame`,
    /// `calleeFrame`) or its expansion (`expanded`, `calleeWeight`).
    const Memo = enum { frame, weight };

    fn known(self: *const Pass, m: Memo, t: Callee) bool {
        if (t & group_bit != 0) {
            const g = self.groups.items[t & ~group_bit];
            return if (m == .frame) g.frame != null else g.weight != null;
        }
        const f = self.fns.items[t];
        return if (m == .frame) f.frame != null else f.weight != null;
    }

    /// The `i`th function or group that `t`'s frame and expansion count
    /// when it leads to it (`leadsTo`): what a function's calls reach, a
    /// group's functions; null past the last.
    fn countedAt(self: *const Pass, t: Callee, i: usize) ?Callee {
        if (t & group_bit != 0) {
            const members = self.groups.items[t & ~group_bit].members.items;
            return if (i < members.len) members[i] else null;
        }
        const calls_of = self.owners.items[self.fns.items[t].owner].calls.items;
        return if (i < calls_of.len) calls_of[i].callee else null;
    }

    /// Whether `t`'s frame and expansion count those of `to`: a call of an
    /// inlined function or of a group, a group's function the rule inlines.
    fn leadsTo(self: *const Pass, t: Callee, to: Callee) bool {
        if (t & group_bit != 0) return self.byRule(to);
        return to & group_bit != 0 or self.fns.items[to].inlined;
    }

    /// A function or group whose memo `settle` finds once those it counts
    /// (`countedAt`, from `next` on) are found.
    const Pending = struct { t: Callee, next: usize = 0 };

    /// Finds memo `m` of `start`, and first that of each function and
    /// group it counts, deepest first. The walk keeps a stack of its own,
    /// as long as the program's chain of inlined calls, rather than
    /// recursing once a call; no cycle of calls is inlined (`isCyclic`),
    /// so no path through them is longer than their count.
    fn settle(self: *Pass, m: Memo, start: Callee) Error!void {
        if (self.known(m, start)) return;
        var stack: std.ArrayList(Pending) = .empty;
        defer stack.deinit(self.a);
        try stack.append(self.a, .{ .t = start });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (self.countedAt(top.t, top.next)) |to| {
                top.next += 1;
                if (!self.leadsTo(top.t, to) or self.known(m, to)) continue;
                if (stack.items.len > self.fns.items.len + self.groups.items.len)
                    std.debug.panic("internal error: a cycle of inlined calls", .{});
                try stack.append(self.a, .{ .t = to });
                continue;
            }
            const t = stack.pop().?.t;
            if (!self.known(m, t)) try self.compute(m, t);
        }
    }

    /// Memo `m` of `t`, from those of the functions and groups it counts,
    /// each found (`settle`).
    fn compute(self: *Pass, m: Memo, t: Callee) Error!void {
        if (t & group_bit != 0) {
            const g = t & ~group_bit;
            var frame_total: u128 = 0;
            var weight_total: u64 = 0;
            for (self.groups.items[g].members.items) |w| if (self.byRule(w)) {
                if (m == .frame) frame_total += self.fns.items[w].frame.? else weight_total += self.fns.items[w].weight.?;
            };
            if (m == .frame) self.groups.items[g].frame = frame_total else self.groups.items[g].weight = weight_total;
            return;
        }
        const o = self.fns.items[t].owner;
        if (m == .weight) {
            var total: u64 = self.fns.items[t].size;
            for (self.owners.items[o].calls.items) |e| total += try self.calleeWeight(e.callee);
            self.fns.items[t].weight = total;
            return;
        }
        self.fns.items[t].frame = if (self.fns.items[t].marker == .@"inline")
            try self.added(o)
        else
            self.owners.items[o].own.?.reach + self.owners.items[o].params + self.owners.items[o].marked.reach + try self.added(o);
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
    /// what marked calls land in it and them stays within
    /// `sema.max_frame_bytes`, and its reach with them within
    /// `sema.max_frame_reach` (`reach_factor` times over). An owner whose
    /// own frame no count knows fits only with nothing inlined into it by
    /// the rule; one this build does not compile fits. A marked `inline`
    /// function's frame Zig never writes: its own values and what marked
    /// calls land in it are checked in each caller's, so only the rule's
    /// part is held to its 64 KiB here, as it is again in each caller at
    /// each call (`added`).
    fn fits(self: *Pass, o: u32) Error!bool {
        if (!self.owners.items[o].compiled) return true;
        if (self.owners.items[o].fun) |v| if (self.fns.items[v].marker == .@"inline") return try self.added(o) <= max_inlined_frame_bytes;
        const auto = try self.added(o);
        const own = self.owners.items[o].own orelse return auto == 0;
        const marked = self.owners.items[o].marked;
        return auto <= max_inlined_frame_bytes and own.bytes + marked.bytes + auto <= sema.max_frame_bytes and (own.reach + marked.reach + auto) * sema.reach_factor <= sema.max_frame_reach;
    }

    /// Stop inlining until every owner's account fits (`fits`), no
    /// function the rule inlines has a frame of more than
    /// `max_inlined_frame_bytes` with the inlined calls in it, and none
    /// expands to more than `max_expanded` nodes: in order, at the first
    /// owner that breaks a rule, stop inlining it or the largest of the
    /// functions the rule inlines into it, and look again.
    ///
    /// Each step only shrinks frames and expansions, so no owner before the
    /// one that broke a rule breaks one after it: the search goes on from
    /// that owner, not from the first, and forgets only the frames and
    /// expansions that counted the call no longer inlined (`uninline`).
    ///
    /// A function marked `inline` stays inlined: no rule undoes it. What
    /// its values land in each caller is typecheck's to check
    /// (`checkFrames`); what the rule inlines into it, here, in each.
    fn fit(self: *Pass) !void {
        var i: usize = 0;
        while (i < self.owners.items.len) {
            const o: u32 = @intCast(i);
            if (self.owners.items[i].fun) |v| {
                const f = &self.fns.items[v];
                if (self.byRule(v) and (try self.frame(v) > max_inlined_frame_bytes or (try self.expanded(v) > max_expanded and !self.oncePerInstance(f)))) {
                    try self.uninline(v);
                    continue;
                }
            }
            if (try self.fits(o)) {
                i += 1;
                continue;
            }
            // The largest of the functions the rule inlines into it, the
            // first of them in the order of the calls and of a group's
            // functions, through the marked functions it calls.
            const biggest = (try self.largestIn(o)) orelse
                std.debug.panic("internal error: {s} does not fit its frame, and the rule inlines nothing into it", .{self.ownerName(o)});
            try self.uninline(biggest);
        }
    }

    /// The function the rule inlines into owner `o` with the largest
    /// frame, of those its calls reach and those the marked `inline`
    /// functions it calls hold.
    fn largestIn(self: *Pass, o: u32) Error!?u32 {
        var biggest: ?u32 = null;
        for (self.owners.items[o].calls.items) |e| {
            const w = (try self.largest(e.callee)) orelse continue;
            if (biggest == null or try self.frame(w) > try self.frame(biggest.?)) biggest = w;
        }
        return biggest;
    }

    /// The function the rule inlines with the largest frame that a call
    /// of `t` lands in its caller: `t` itself, or through a marked one the
    /// largest it holds, or the first of a group's in its order.
    fn largest(self: *Pass, t: Callee) Error!?u32 {
        if (t & group_bit == 0) {
            if (self.byRule(t)) return t;
            if (self.fns.items[t].marker == .@"inline") return self.largestIn(self.fns.items[t].owner);
            return null;
        }
        const gi = t & ~group_bit;
        if (self.groups.items[gi].top) |top| return top.fun;
        var best: ?u32 = null;
        for (self.groups.items[gi].members.items) |w| {
            if (!self.byRule(w)) continue;
            if (best == null or try self.frame(w) > try self.frame(best.?)) best = w;
        }
        self.groups.items[gi].top = .{ .fun = best };
        return best;
    }

    /// Inlined by the rule, not by a marker: what a call by name counts,
    /// and what `fit` may stop inlining.
    fn byRule(self: *const Pass, w: u32) bool {
        return self.fns.items[w].inlined and self.fns.items[w].marker != .@"inline";
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

    /// How a message names owner `o`.
    fn ownerName(self: *Pass, o: u32) []const u8 {
        const v = self.owners.items[o].fun orelse return "a frame owner";
        return self.fns.items[v].name;
    }

    // ---- cycles of marked functions --------------------------------------

    /// Report each cycle of calls whose functions are all marked `inline`,
    /// which Zig cannot inline into itself, once, at the function it
    /// returns to. Its edges are the calls typecheck resolved to a marked
    /// function in each one's own frame: a closure is a frame of its own,
    /// which calls the function as any caller does.
    fn forcedCycles(self: *Pass) !bool {
        for (self.fns.items, 0..) |f, v| {
            if (f.marker == .@"inline" and f.color == .white) try self.forcedVisit(@intCast(v));
        }
        return self.cycles > 0;
    }

    fn forcedVisit(self: *Pass, v: u32) !void {
        self.fns.items[v].color = .gray;
        try self.stack.append(self.a, v);
        for (self.owners.items[self.fns.items[v].owner].calls.items) |e| {
            if (e.callee & group_bit != 0) continue;
            const w = e.callee;
            if (self.fns.items[w].marker != .@"inline") continue;
            switch (self.fns.items[w].color) {
                .white => try self.forcedVisit(w),
                .gray => try self.cycleError(w),
                .black => {},
            }
        }
        _ = self.stack.pop();
        self.fns.items[v].color = .black;
    }

    /// The cycle on the search's stack from `w` back to it.
    fn cycleError(self: *Pass, w: u32) !void {
        self.cycles += 1;
        const f = self.fns.items[w];
        const c = self.mods[f.module].sema;
        const at = std.mem.lastIndexOfScalar(u32, self.stack.items, w).?;
        const path = self.stack.items[at + 1 ..];
        if (path.len == 0) {
            try c.err(f.pos, "`{s}` is `inline` and calls itself, so no call of it can be inlined; drop `inline`", .{try self.shown(w)});
            return;
        }
        var through: std.ArrayList(u8) = .empty;
        for (path, 0..) |g, i| {
            if (i > 0) try through.appendSlice(self.a, ", ");
            try through.print(self.a, "`{s}`", .{try self.shown(g)});
        }
        try c.err(f.pos, "`{s}` is `inline` and calls itself through {s}, also `inline`, so no call of it can be inlined; drop `inline` from one of them", .{ try self.shown(w), through.items });
    }

    /// A function as a message names it: `f`, or a method `Type.m`.
    fn shown(self: *Pass, v: u32) ![]const u8 {
        const f = self.fns.items[v];
        const type_name = self.owners.items[f.owner].type_name;
        if (type_name.len == 0) return f.name;
        return std.fmt.allocPrint(self.a, "{s}.{s}", .{ type_name, f.name });
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

    /// A node Tarjan's search has entered and not left: the next of its
    /// edges to follow, and whether one of them leads back to it.
    const Visit = struct { v: u32, next: usize = 0, self_loop: bool = false };

    /// Mark every function on a cycle of calls (Tarjan), a call that
    /// reaches a group leading to each function in it: a function with a
    /// call of its own group is on a cycle, as one that calls itself is.
    /// The search keeps a stack of its own (`visits`), as long as the
    /// program's chain of calls, rather than recursing once a call.
    fn strong(self: *Pass, root: u32) !void {
        var visits: std.ArrayList(Visit) = .empty;
        defer visits.deinit(self.a);
        try self.enter(root);
        try visits.append(self.a, .{ .v = root });
        while (visits.items.len > 0) {
            const top = &visits.items[visits.items.len - 1];
            const v = top.v;
            if (self.edges(v, top.next)) |w| {
                top.next += 1;
                if (w == v) top.self_loop = true;
                if (self.state(w).index == 0) {
                    try self.enter(w);
                    try visits.append(self.a, .{ .v = w });
                } else if (self.state(w).on_stack) {
                    self.state(v).low = @min(self.state(v).low, self.state(w).index);
                }
                continue;
            }
            if (visits.pop().?.self_loop) self.cyclic.items[v] = true;
            self.leave(v);
            if (visits.items.len > 0) {
                const parent = visits.items[visits.items.len - 1].v;
                self.state(parent).low = @min(self.state(parent).low, self.state(v).low);
            }
        }
    }

    /// Number node `v` and put it on Tarjan's stack.
    fn enter(self: *Pass, v: u32) !void {
        const sv = self.state(v);
        sv.index = self.next_index;
        sv.low = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.a, v);
        sv.on_stack = true;
    }

    /// Once every edge of `v` is followed: when it roots a component, take
    /// the component off the stack, marking its nodes when it is a cycle.
    fn leave(self: *Pass, v: u32) void {
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

/// The declaration parameter `sym` of `c` stands for: its proxy's
/// origin, or itself.
fn originOf(c: *const SemContext, sym: sema.SymbolId) sema.ForeignRef {
    const s = c.symbols.items[sym];
    return if (sema.isProxy(s)) s.from else .{ .module_id = c.module_id, .sym = sym };
}

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
/// largest body to inline (`max_size`). A cycle of marked `inline`
/// functions is reported in its module's diagnostics, and decides
/// nothing.
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
    // the largest, and the parameters some instance binds.
    for (mods) |m| {
        for (m.sema.frame_sizes.items) |fr| {
            const total: FrameCount = .{ .bytes = fr.bytes + fr.marked.bytes, .reach = fr.reach + fr.marked.reach };
            const gop = try pass.instances.getOrPut(a, .{ .module = fr.module, .pos = fr.decl });
            if (!gop.found_existing) gop.value_ptr.* = .{ .own = .none, .total = .none };
            const in = gop.value_ptr;
            in.own = .{ .bytes = @max(in.own.bytes, fr.bytes), .reach = @max(in.own.reach, fr.reach) };
            in.total = .{ .bytes = @max(in.total.bytes, total.bytes), .reach = @max(in.total.reach, total.reach) };
            in.params = @max(in.params, fr.params);
        }
        try pass.bind(m.sema);
    }
    var base: u32 = 0;
    for (mods, 0..) |m, i| {
        pass.owner_base[i] = base;
        base += @intCast(m.sema.frame_owners.items.len);
    }
    for (0..mods.len) |i| try pass.collect(i);
    for (mods, 0..) |m, i| try pass.mentions(i, m.ir);
    for (0..mods.len) |i| try pass.calls(i);
    pass.countCalls();
    // A cycle of marked `inline` functions is an error, and the program
    // is not emitted.
    if (try pass.forcedCycles()) return;
    try pass.findCycles();
    // A large frame found at an instance another module makes marks its
    // declaration in its own module (module ids count from 1).
    for (mods) |m| for (m.sema.large_foreign_frames.items) |fr| try mods[fr.module - 1].sema.large_frames.put(allocator, fr.pos, {});
    for (pass.fns.items, 0..) |*f, v| {
        // A marked `inline` function is never a value (typecheck rejects
        // one), and one on a cycle of marked ones is an error above.
        if (f.marker == .@"inline") {
            f.inlined = true;
            continue;
        }
        if (!f.eligible or f.used_as_value or pass.isCyclic(@intCast(v)) or f.size > max) continue;
        const own = pass.owners.items[f.owner].own orelse continue;
        if (own.reach + pass.owners.items[f.owner].params + pass.owners.items[f.owner].marked.reach > max_inlined_frame_bytes or mods[f.module].sema.large_frames.contains(f.pos)) continue;
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
        const marked = pass.owners.items[index].marked;
        const auto = try pass.added(index);
        o.account = .{ .own = own, .marked = marked, .auto = auto };
        if (pass.owners.items[index].fun) |v| if (pass.fns.items[v].inlined) continue;
        const known = own orelse continue;
        if ((known.reach + marked.reach + auto) * sema.reach_factor >= sema.noinline_reach) try m.sema.large_frames.put(allocator, o.pos, {});
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
