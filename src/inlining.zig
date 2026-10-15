//! Which functions are emitted `inline`: decided once, for the whole
//! program, after every module is checked (docs/INTERNALS.md, "Inlining").
//!
//! A function marked `inline fun` is emitted `inline fn`, whatever its
//! size, and one marked `called fun` or `rarely fun` never is; the rule
//! below decides the rest. A cycle of calls of marked `inline` functions
//! is an error; the frames they make are checked with every other frame
//! (`typecheck.checkFrames`). The sizes below never undo a marker, they
//! only choose among the functions the compiler picked.
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

/// The most bytes of values the inlined calls in one function may add to
/// its frame. Zig puts the locals of an inlined body in the caller's
/// frame, so a function's own frame with the inlined ones in it also stays
/// within `sema.max_frame_bytes`, which `typecheck.checkFrames` holds the
/// function's own frame to: inlining stops short of a frame that big.
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
    /// Its marker: `inline` inlines it at every call, `called` and
    /// `rarely` never.
    marker: rig.Marker,
    /// The object type it is a method of; empty for a module's function.
    owner: []const u8,
    /// The marked `inline` functions its calls reach, as typecheck
    /// recorded them (`SemContext.inline_calls`), once for each call, but
    /// those in its closures, which are functions of their own: the edges
    /// of a cycle of `inline` functions, and how their frames and sizes
    /// reach it.
    inline_calls: std.ArrayList(InlineEdge) = .empty,
    /// The search for cycles of marked `inline` functions (`forcedCycles`).
    color: enum { white, gray, black } = .white,
    /// Mentioned other than as a callee.
    used_as_value: bool = false,
    /// What its calls reach, once for each call (`Callee`).
    calls: std.ArrayList(Callee) = .empty,
    /// The functions with a call of it, once for each such call.
    callers: std.ArrayList(u32) = .empty,
    /// Its name's group (`Group`).
    group: u32 = 0,
    /// The bytes of values it keeps on its stack; null when that depends
    /// on compile-time parameters.
    own: ?u128 = null,
    /// What the functions the rule inlines add to its frame (`added`).
    auto: ?u128 = null,
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

/// A recorded call of a marked `inline` function: the function, and what
/// it adds to the caller's frame at the call's instance, as typecheck's
/// frame check counted it; null where only each instance of the caller
/// knows (`InlineCall.bytes`).
const InlineEdge = struct { fun: u32, bytes: ?u128 };

/// A frame no count knows. Every limit fails it, so a function whose
/// frame holds one is never inlined by the rule: an unknown frame is
/// never counted as small. Sums of it stay in range.
const unknown_frame: u128 = std.math.maxInt(u64);

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
    /// The cycles of marked `inline` functions reported.
    cycles: u32 = 0,
    /// How many closures the visit is inside.
    closures: u32 = 0,
    /// A function's declaration (`nodeIn`) -> it.
    by_node: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn ctx(self: *Pass, module: usize) *const SemContext {
        return self.mods[module].sema;
    }

    fn collect(self: *Pass, module: usize, root: Sexp) !void {
        for (ir.Module.decls(root)) |d| try self.collectDecl(module, d, null);
    }

    /// A declaration, a member of the object type named `owner` if any.
    fn collectDecl(self: *Pass, module: usize, decl: Sexp, owner: ?[]const u8) !void {
        var d = decl;
        if (d.isKind(.@"pub")) d = ir.Pub.decl(d);
        const kind = d.kind() orelse return;
        switch (kind) {
            .fun, .sub => try self.add(module, d, owner, false),
            .@"struct" => for (ir.Struct.members(d)) |m| try self.collectDecl(module, m, self.nameOf(module, d)),
            .@"enum" => for (ir.Enum.members(d)) |m| try self.collectDecl(module, m, self.nameOf(module, d)),
            .errors => for (ir.Errors.members(d)) |m| try self.collectDecl(module, m, self.nameOf(module, d)),
            .generic_struct => for (ir.GenericStruct.members(d)) |m| try self.collectGeneric(module, m, self.nameOf(module, d)),
            .generic_enum => for (ir.GenericEnum.members(d)) |m| try self.collectGeneric(module, m, self.nameOf(module, d)),
            else => {},
        }
    }

    fn nameOf(self: *Pass, module: usize, decl: Sexp) []const u8 {
        return textOf(self.ctx(module), ir.get(decl, .name));
    }

    fn collectGeneric(self: *Pass, module: usize, member: Sexp, owner: []const u8) !void {
        var m = member;
        if (m.isKind(.@"pub")) m = ir.Pub.decl(m);
        if (m.isKind(.fun) or m.isKind(.sub)) try self.add(module, m, owner, true);
    }

    fn add(self: *Pass, module: usize, node: Sexp, owner: ?[]const u8, generic_owner: bool) !void {
        const member = owner != null;
        const c = self.ctx(module);
        const name_node = ir.get(node, .name);
        const name = textOf(c, name_node);
        const body = ir.get(node, .body);
        const is_main = !member and self.mods[module].id == 1 and std.mem.eql(u8, name, "main");
        const marker = rig.markerOf(node);
        const eligible = body != .nil and !is_main and !generic_owner and onlyValueParams(node) and marker != .called and marker != .rarely;
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
            .marker = marker,
            .owner = owner orelse "",
            .size = if (body != .nil) size(body) else 0,
            .group = gop.value_ptr.*,
        });
        if (body != .nil and holdsClosure(body)) self.fns.items[idx].eligible = false;
        try self.by_pos[module].put(self.a, pos, idx);
        if (node.list.id != 0) try self.by_node.put(self.a, nodeIn(module, node.list.id), idx);
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
            .lambda => {
                self.closures += 1;
                defer self.closures -= 1;
                for (e.items()) |c| try self.visit(module, cur, c);
            },
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
        if (cur) |from| if (self.closures == 0) if (self.ctx(module).inlineCallOf(call)) |ic| try self.fns.items[from].inline_calls.append(self.a, .{ .fun = self.declared(ic.fun), .bytes = ic.bytes });
        // The bracket list of a generic call, `f[T](x)`.
        if (raw.isKind(.inst)) for (raw.items()[2..]) |a| try self.visit(module, cur, a);
        for (ir.Call.args(call)) |a| try self.visit(module, cur, a);
    }

    /// The function `fun` names, by its declaration, which typecheck
    /// recorded a call of and resolve recorded under the same key: there
    /// is always one.
    fn declared(self: *Pass, fun: sema.FnRef) u32 {
        for (self.mods, 0..) |m, mi| if (m.sema.module_id == fun.module) {
            const node = m.sema.inline_decls.get(fun.key()) orelse break;
            return self.by_node.get(nodeIn(mi, node.list.id)) orelse break;
        };
        std.debug.panic("an inline call's function {d}:{d}:{d} is not among the program's", .{ fun.module, fun.owner, fun.index });
    }

    /// Report each cycle of calls whose functions are all marked `inline`,
    /// which Zig cannot inline into itself, once, at the function it
    /// returns to, by the calls typecheck recorded (`inline_calls`).
    fn forcedCycles(self: *Pass) !bool {
        for (self.fns.items, 0..) |f, v| {
            if (f.marker == .@"inline" and f.color == .white) try self.forcedVisit(@intCast(v));
        }
        return self.cycles > 0;
    }

    fn forcedVisit(self: *Pass, v: u32) !void {
        self.fns.items[v].color = .gray;
        try self.stack.append(self.a, v);
        for (self.fns.items[v].inline_calls.items) |e| switch (self.fns.items[e.fun].color) {
            .white => try self.forcedVisit(e.fun),
            .gray => try self.cycleError(e.fun),
            .black => {},
        };
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
        if (f.owner.len == 0) return f.name;
        return std.fmt.allocPrint(self.a, "{s}.{s}", .{ f.owner, f.name });
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

    /// What the functions the rule inlines add to `v`'s frame: the frame
    /// of each that a call of `v` reaches, and of each that the marked
    /// `inline` functions `v` calls hold, since those land in `v` too.
    /// What a marked function keeps itself is typecheck's to count in
    /// `v`'s frame (`checkFrames`), so it is not here; it is in `v`'s own
    /// frame where `v` is inlined (`frame`). No cycle of marked functions
    /// is left (`forcedCycles`), and no function the rule inlines is on a
    /// cycle, so this ends.
    fn added(self: *Pass, v: u32) u128 {
        if (self.fns.items[v].auto) |b| return b;
        var total: u128 = 0;
        for (self.fns.items[v].calls.items) |t| total += self.calleeFrame(t);
        for (self.fns.items[v].inline_calls.items) |e| total += self.added(e.fun);
        self.fns.items[v].auto = total;
        return total;
    }

    /// What a call of `t` adds to a frame: the frames of the functions it
    /// reaches that the rule inlines. A marked `inline` function's is
    /// counted by the calls typecheck recorded of it (`added`), so a call
    /// by name never reaches one.
    fn calleeFrame(self: *Pass, t: Callee) u128 {
        if (t & group_bit == 0) return if (self.byRule(t)) self.frame(t) else 0;
        const g = &self.groups.items[t & ~group_bit];
        if (g.frame) |b| return b;
        var total: u128 = 0;
        for (g.members.items) |w| {
            if (self.byRule(w)) total += self.frame(w);
        }
        self.groups.items[t & ~group_bit].frame = total;
        return total;
    }

    /// The frame of a function the rule inlines, as it lands in a caller:
    /// its own values, those of the functions inlined in it, and the
    /// marked `inline` functions it calls at each call's instance, as
    /// typecheck counted them. A count no one knows is `unknown_frame`.
    fn frame(self: *Pass, v: u32) u128 {
        if (self.fns.items[v].frame) |b| return b;
        var b = (self.fns.items[v].own orelse unknown_frame) + self.added(v);
        for (self.fns.items[v].inline_calls.items) |e| b += e.bytes orelse unknown_frame;
        self.fns.items[v].frame = b;
        return b;
    }

    /// The size of an inlined function with its own inlined calls in it.
    fn expanded(self: *Pass, v: u32) u64 {
        if (self.fns.items[v].weight) |w| return w;
        var total: u64 = self.fns.items[v].size;
        for (self.fns.items[v].calls.items) |t| total += self.calleeWeight(t);
        for (self.fns.items[v].inline_calls.items) |e| total += self.expanded(e.fun);
        self.fns.items[v].weight = total;
        return total;
    }

    /// What a call of `t` adds to a size: the expansions of the functions
    /// it reaches that the rule inlines (`calleeFrame`).
    fn calleeWeight(self: *Pass, t: Callee) u64 {
        if (t & group_bit == 0) return if (self.byRule(t)) self.expanded(t) else 0;
        const g = &self.groups.items[t & ~group_bit];
        if (g.weight) |w| return w;
        var total: u64 = 0;
        for (g.members.items) |w| {
            if (self.byRule(w)) total += self.expanded(w);
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
    /// `max_inlined_frame_bytes` to its frame, no function has a frame of
    /// more than `sema.max_frame_bytes` with the inlined calls in it, no inlined function has a
    /// frame of more than that, and none expands to more than
    /// `max_expanded` nodes: in order, at the first function that breaks
    /// a rule, stop inlining it or the largest of its inlined calls, and
    /// look again.
    ///
    /// Each step only shrinks frames and expansions, so no function before
    /// the one that broke a rule breaks one after it: the search goes on
    /// from that function, not from the first, and forgets only the frames
    /// and expansions that counted the call no longer inlined
    /// (`uninline`).
    ///
    /// A function marked `inline` stays inlined: no rule undoes it. The
    /// frames it makes are typecheck's to check (`checkFrames`), which
    /// counts each at the instance its call makes.
    fn fit(self: *Pass) !void {
        var i: usize = 0;
        while (i < self.fns.items.len) {
            const v: u32 = @intCast(i);
            const f = &self.fns.items[i];
            if (f.inlined and f.marker != .@"inline" and (self.frame(v) > max_inlined_frame_bytes or (self.expanded(v) > max_expanded and !self.oncePerInstance(f)))) {
                try self.uninline(v);
                continue;
            }
            // The functions the rule inlines add at most 64 KiB to any
            // frame: what bounds them beside typecheck's count of the rest.
            // A function whose own frame its instances decide is held to
            // the limit by each instance's check (`checkInstanceSizes`).
            const own_fits = if (f.own) |own| own + self.added(v) <= sema.max_frame_bytes else true;
            if (self.added(v) <= max_inlined_frame_bytes and own_fits) {
                i += 1;
                continue;
            }
            // The largest of the inlined calls, the first of them in the
            // order of the calls and of a group's functions, through the
            // marked `inline` functions it calls, whose own inlined calls
            // land in it too.
            const biggest = self.largestIn(v);
            if (biggest) |w| {
                try self.uninline(w);
                continue;
            }
            i += 1;
        }
    }

    /// The function the rule inlines with the largest frame, of those `v`'s
    /// calls reach and those the marked `inline` functions it calls hold.
    fn largestIn(self: *Pass, v: u32) ?u32 {
        var biggest: ?u32 = null;
        for (self.fns.items[v].calls.items) |t| {
            const w = self.largest(t) orelse continue;
            if (biggest == null or self.frame(w) > self.frame(biggest.?)) biggest = w;
        }
        for (self.fns.items[v].inline_calls.items) |e| {
            const w = self.largestIn(e.fun) orelse continue;
            if (biggest == null or self.frame(w) > self.frame(biggest.?)) biggest = w;
        }
        return biggest;
    }

    /// The inlined function a call of `t` reaches with the largest frame,
    /// the first of them in a group's order, of those not marked `inline`.
    fn largest(self: *Pass, t: Callee) ?u32 {
        if (t & group_bit == 0) return if (self.byRule(t)) t else null;
        const gi = t & ~group_bit;
        if (self.groups.items[gi].top) |top| return top.fun;
        var best: ?u32 = null;
        for (self.groups.items[gi].members.items) |w| {
            if (!self.byRule(w)) continue;
            if (best == null or self.frame(w) > self.frame(best.?)) best = w;
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
                u.auto = null;
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

/// A node of module `module`'s tree, by its id: node ids are numbered in
/// each module's parse.
fn nodeIn(module: usize, id: parser.NodeId) u64 {
    return @as(u64, @intCast(module)) << 32 | id;
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
/// are emitted `inline`, and record them in the modules' contexts.
/// `max` is the largest body to inline (`max_size`). A marked `inline`
/// function Zig cannot inline is reported in its module's diagnostics.
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
    for (pass.fns.items) |*f| {
        if (ir.get(f.node, .body) == .nil) continue;
        f.own = (try typecheck.frameBytesOfFunction(mods[f.module].sema, f.node)) orelse {
            // A frame that depends on a compile-time value is unknown.
            if (sema.tparamsOf(f.node) != .nil) f.eligible = false;
            continue;
        };
    }
    // A cycle of marked `inline` functions is an error, and the program
    // is not emitted.
    if (try pass.forcedCycles()) return;
    for (pass.fns.items, 0..) |*f, v| {
        // A marked `inline` function is never a value (typecheck rejects
        // one), and one on a cycle of marked ones is an error above.
        if (f.marker == .@"inline") {
            f.inlined = true;
            continue;
        }
        if (!f.eligible or f.used_as_value or pass.isCyclic(@intCast(v)) or f.size > max) continue;
        if ((f.own orelse unknown_frame) > max_inlined_frame_bytes) continue;
        f.inlined = true;
    }
    try pass.fit();
    for (pass.fns.items) |f| {
        if (f.inlined) try mods[f.module].sema.inlined.put(allocator, f.pos, {});
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
