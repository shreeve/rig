//! Frame accounts: what each frame owner of a module keeps on its stack
//! and may copy there, counted from its LIR (docs/internals/INTERNALS.md,
//! "The program's stack").
//!
//! A frame's values are the vars its regions declare that hold a value
//! of their own: each binding (a parameter or a local), once, a closure's
//! captures in the frame that makes it, and a fork's record
//! (`task_record`); and each call, array literal, and fill whose value no
//! binding or place takes directly, a temporary. A call's result counts
//! as a temporary even when a binding takes it, since a debug build holds
//! it in one first. The values are a limit on what a program keeps on its
//! stack (`sema.max_frame_bytes`).
//!
//! A frame's reach is its values and a copy of every value its code makes
//! or copies (`Walker.copy`): Zig's code may hold each in a temporary of
//! its own, so the stack the frame really takes is at most
//! `sema.reach_factor` times its reach. A value is copied where it is used
//! unless the use reads it in place, by a positive list (`copiedIn`): a
//! callee, a place's base, a view's operand, a value a binding or place
//! takes, a part held in a var first, read where the var is. Code Zig
//! writes more than once counts once for each copy: a `defer` or
//! `errdefer` body at every exit it covers (`deferBody`), and a marked
//! `inline` function at every call (`addInlined`); what the rule inlines,
//! `inlining.decide` adds per call.
//!
//! The same walk counts each body's operations (`sema.FrameOwner.ops`),
//! the size `inlining.decide` measures a function by: each step but a
//! region and an expression statement's, whose operations count, and
//! each operation, coercion, hold, branch, choice, and closure.
//!
//! A frame whose types mention generic parameters is checked at each
//! instance (`check/generics.zig`, `checkInstanceFrames`). The module's
//! LIR exists from `lower.lowerChecked` until its checks finish, so the
//! accounts are counted there; a module with an error is not lowered, and
//! counts no frame.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");
const lir = @import("lir.zig");
const lowering = @import("lower.zig");
const generics = @import("check/generics.zig");
const compat = @import("check/compat.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const TypeId = sema.TypeId;
const Error = std.mem.Allocator.Error;

/// The most calls of marked `inline` functions that may nest, each
/// inlined into the one around it: Zig's own analysis recurses once for
/// each, and runs out of its stack some thousands deep.
pub const max_inline_depth = 256;

/// Count and check every frame owner of the module, from its LIR, then
/// what each marked `inline` function it declares lands in a caller's
/// frame, for the modules that import this one; then the frames of the
/// instances the module makes (`checkInstanceFrames`). A module that was
/// not lowered counts nothing.
pub fn count(ctx: *SemContext) Error!void {
    const m = if (ctx.lowered) |*m| m else return;
    var i: u32 = 0;
    while (i < ctx.frame_owners.items.len) i = try ownerTree(ctx, m, i);
    var it = ctx.inline_decls.keyIterator();
    while (it.next()) |pos| _ = try inlineFrame(ctx, m, pos.*, 1);
    for (ctx.instance_frames.items) |f| try generics.checkInstanceFrames(ctx, f.params, f.args, f.at, f.of);
}

/// Count owner `i` after the closures in it, in source order, as a
/// closure's frame is met inside its maker's: so a message about a
/// closure comes before one about the frame around it. The owners are
/// listed with each one's closures right after it. Returns the owner
/// after them.
fn ownerTree(ctx: *SemContext, m: *const lowering.Module, i: u32) Error!u32 {
    const owners = ctx.frame_owners.items;
    var j = i + 1;
    while (j < owners.len and owners[j].parent == i) j = try ownerTree(ctx, m, j);
    try ownerFrame(ctx, m, i);
    return j;
}

/// What the `inline` function declared at `pos` in this module lands in
/// the frame of a call of it: the values it keeps and its copies, those
/// of the `inline` functions it calls in turn, each at the instance its
/// call makes, and its parameters' copies. Null while it is being worked
/// out: a call on a cycle of `inline` functions, which `inlining.decide`
/// reports, so the program is never emitted.
fn inlineFrame(ctx: *SemContext, m: *const lowering.Module, pos: u32, depth: u32) Error!?[]const sema.FrameSlot {
    if (ctx.inline_frames.get(pos)) |known| return known;
    const node = ctx.inline_decls.get(pos).?;
    try ctx.inline_frames.put(ctx.allocator, pos, null);
    const oi = m.roots.get(sema.decisionKeyOf(node).?) orelse return null;
    const f = m.owners[oi].func orelse return null;
    var w: Walker = .{ .ctx = ctx, .m = m, .f = f, .depth = depth };
    defer w.deinit();
    try w.func();
    try w.paramCopies(&w.slots);
    const kept = try ctx.arena.allocator().dupe(sema.FrameSlot, w.slots.items);
    try ctx.inline_frames.put(ctx.allocator, pos, kept);
    try ctx.inline_heights.put(ctx.allocator, pos, w.height);
    return kept;
}

/// The frame of owner `index`, checked now or, when its size depends on
/// generic parameters, at each instance; its own count goes into the
/// owner (`sema.FrameOwner.own`). An owner with no LIR has no count, so
/// nothing is inlined into it.
fn ownerFrame(ctx: *SemContext, m: *const lowering.Module, index: u32) Error!void {
    const owner = ctx.frame_owners.items[index];
    const f = m.owners[index].func orelse return;
    var w: Walker = .{ .ctx = ctx, .m = m, .f = f };
    defer w.deinit();
    try w.func();
    ctx.frame_owners.items[index].ops = w.ops;
    // A function's parameters, copied where the rule inlines it.
    var params: Walker.Slots = .empty;
    defer params.deinit(ctx.allocator);
    if (owner.kind == .function) try w.paramCopies(&params);
    const items = w.slots.items;
    if (items.len + params.items.len == 0) {
        ctx.frame_owners.items[index].own = .none;
        return;
    }
    // The values first, then the copies; in each, its own, then what
    // marked calls land in it; then the parameters' copies.
    const arena = ctx.arena.allocator();
    const tys = try arena.alloc(TypeId, items.len + params.items.len);
    const names = try arena.alloc([]const u8, tys.len);
    var n: usize = 0;
    var parts: generics.FrameParts = .{};
    for ([_]bool{ false, true }) |copies| for ([_]bool{ false, true }) |mark| for (items) |s| if (s.copy == copies and s.marked == mark) {
        tys[n] = s.ty;
        names[n] = s.name;
        n += 1;
        if (copies) parts.copies += 1;
        if (mark and copies) parts.marked_copies += 1;
        if (mark and !copies) parts.marked += 1;
    };
    for (params.items) |s| {
        tys[n] = s.ty;
        names[n] = s.name;
        n += 1;
    }
    parts.params = @intCast(params.items.len);
    for (tys) |ty| if (sema.containsTypeVar(ctx, ty)) {
        try ctx.addGeneric(.frames, .{ .label = owner.label, .pos = owner.pos, .tys = tys, .names = names, .copies = parts.copies, .marked = parts.marked, .marked_copies = parts.marked_copies, .params = parts.params });
        ctx.frame_owners.items[index].per_instance = true;
        return;
    };
    const counted = (try generics.checkFrame(ctx, owner.pos, owner.label, null, tys, names, parts, owner.pos)) orelse return;
    ctx.frame_owners.items[index].own = counted.own;
    ctx.frame_owners.items[index].marked = counted.marked;
    ctx.frame_owners.items[index].params = counted.params;
}

/// One walk of a body's LIR, in the order it runs, collecting its slots.
const Walker = struct {
    ctx: *SemContext,
    m: *const lowering.Module,
    f: *const lir.Func,
    /// How deep in calls of marked `inline` functions the body walked is
    /// (`inlineFrame`): 0 for an owner's own.
    depth: u32 = 0,
    /// The deepest nesting of marked calls below the body walked, which
    /// `inlineFrame` records (`SemContext.inline_heights`).
    height: u32 = 0,
    /// The operations the body runs (`sema.FrameOwner.ops`).
    ops: u32 = 0,
    slots: Slots = .empty,
    /// The value each hidden var a part is held in first is bound to,
    /// where a `var` expression reads that var in the part's place: the
    /// value is counted there, in the context of that place.
    held: []?lir.ExprId = &.{},

    const Slot = sema.FrameSlot;
    const Slots = std.ArrayList(Slot);

    fn deinit(w: *Walker) void {
        w.slots.deinit(w.ctx.allocator);
        w.ctx.allocator.free(w.held);
    }

    fn func(w: *Walker) Error!void {
        const f = w.f;
        w.held = try w.ctx.allocator.alloc(?lir.ExprId, f.vars.items.len);
        @memset(w.held, null);
        // A part held first: a hidden var bound in a region whose value a
        // `var` expression for the part's node reads.
        var read = try std.DynamicBitSetUnmanaged.initEmpty(w.ctx.allocator, f.vars.items.len);
        defer read.deinit(w.ctx.allocator);
        for (f.exprs.items) |e| switch (e) {
            .@"var" => |u| if (f.vars.items[u.v].name == .hidden and sema.decisionKeyOf(u.node) == sema.decisionKeyOf(f.vars.items[u.v].node)) read.set(u.v),
            else => {},
        };
        for (f.regions.items) |r| for (r.steps.items) |s| switch (s) {
            .bind => |b| if (read.isSet(b.v)) {
                w.held[b.v] = b.value;
            },
            else => {},
        };
        try w.region(f.body, false, true, &w.slots);
    }

    fn sym(w: *const Walker, id: sema.SymbolId) sema.Symbol {
        return w.ctx.symbols.items[id];
    }

    /// Whether binding `s` keeps a value in the frame: a parameter or a
    /// local, not one known at compile time; a closure's captures are its
    /// maker's (`closure`).
    fn keeps(s: sema.Symbol) bool {
        return (s.kind == .local or s.kind == .param) and !s.flags.comptime_known and s.scope != sema.module_scope;
    }

    /// The values the vars of region `r` hold: each binding it declares,
    /// and a fork's record.
    fn decls(w: *Walker, r: *const lir.Region, slots: *Slots) Error!void {
        const ctx = w.ctx;
        for (r.decls.items) |x| {
            const v = w.f.vars.items[x];
            switch (v.name) {
                .binding => |id| {
                    const s = w.sym(id);
                    if (keeps(s)) try slots.append(ctx.allocator, .{ .ty = s.ty, .name = s.name });
                },
                .hidden => |k| if (k == .task_record) {
                    const bytes = (try storage.taskRecordBytes(ctx, v.node)).?;
                    const byte = try ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
                    const record = try ctx.intern(.{ .array = .{ .elem = byte, .len = try sema.ctInt(ctx, @intCast(bytes)) } });
                    try slots.append(ctx.allocator, .{ .ty = record, .name = "a task's record" });
                },
            }
        }
    }

    /// Region `r`: its vars, its steps, and its value, which the context
    /// takes as `bound` and `copied` say.
    fn region(w: *Walker, id: lir.RegionId, bound: bool, copied: bool, slots: *Slots) Error!void {
        const r = &w.f.regions.items[id];
        try w.decls(r, slots);
        for (r.steps.items, 0..) |s, j| {
            // A region runs its own steps, and a statement that is an
            // expression runs its operations: neither step is one more.
            if (s != .region and s != .eval) w.ops += 1;
            switch (s) {
                .bind => |b| {
                    const v = w.f.vars.items[b.v];
                    switch (v.name) {
                        // A declaration takes its value directly; a fill
                        // built in the local makes no copy.
                        .binding => try w.expr(b.value, true, !(r.node.isKind(.set) and storage.fillsInPlace(w.ctx, r.node)), slots),
                        // A part held first is counted where the var is
                        // read (`held`); any other is copied into its var.
                        .hidden => if (w.held[b.v] == null) try w.expr(b.value, false, true, slots),
                    }
                },
                .store => |st| {
                    try w.expr(st.target, false, false, slots);
                    try w.expr(st.value, true, !storage.fillsInPlace(w.ctx, st.node), slots);
                },
                .eval => |e| try w.expr(e, false, true, slots),
                .drop => |u| try w.copy(u.node, slots),
                .jump => |jp| if (jp.value) |e| try w.expr(e, false, true, slots),
                .region => |sub| if (isDefer(w.f.regions.items[sub].node))
                    try w.deferBody(sub, r.steps.items[j + 1 ..], slots)
                else
                    try w.region(sub, false, true, slots),
                .@"if" => |i| {
                    try w.expr(i.cond, false, true, slots);
                    try w.region(i.then, false, true, slots);
                    if (i.@"else") |e| try w.region(e, false, true, slots);
                },
                .loop => |lp| {
                    try w.expr(lp.cond, false, true, slots);
                    try w.region(lp.body, false, true, slots);
                    if (lp.step) |st| try w.region(st, false, true, slots);
                },
                .each => |ea| {
                    try w.expr(ea.source, false, true, slots);
                    try w.region(ea.body, false, true, slots);
                },
                .match => |c| try w.choice(c, slots),
            }
        }
        if (r.value) |e| try w.expr(e, bound, copied, slots);
    }

    fn choice(w: *Walker, c: lir.Expr.Choice, slots: *Slots) Error!void {
        try w.expr(c.subject, false, true, slots);
        for (c.arms) |a| try w.region(a, false, true, slots);
    }

    /// A `defer` or `errdefer` statement's region, whose body Zig writes
    /// again at each exit of its block it covers: every exit among the
    /// statements after it (`check/generics.zig`, `countExits`), and the
    /// block's end. The body's values and copies count once more for each
    /// exit past the first, as copies.
    fn deferBody(w: *Walker, sub: lir.RegionId, rest: []const lir.Step, slots: *Slots) Error!void {
        const ctx = w.ctx;
        const start = slots.items.len;
        try w.region(sub, false, false, slots);
        // Each later step of a block is a statement's region.
        var exits: usize = 1;
        for (rest) |s| if (s == .region) {
            exits += generics.countExits(w.f.regions.items[s.region].node);
        };
        const once = try ctx.arena.allocator().dupe(Slot, slots.items[start..]);
        for (1..exits) |_| for (once) |slot| try slots.append(ctx.allocator, .{ .ty = slot.ty, .name = "", .copy = true, .marked = slot.marked });
    }

    /// The node expression `id` stands for.
    fn nodeOf(w: *const Walker, id: lir.ExprId) Sexp {
        return switch (w.f.exprs.items[id]) {
            .@"var" => |u| u.node,
            .leaf => |l| l,
            .op => |o| o.node,
            .hold => |h| w.nodeOf(h.value),
            .block => |r| w.f.regions.items[r].node,
            .branch => |b| b.node,
            .choice => |c| c.node,
            .closure => |c| c.node,
            .coerce => |c| c.node,
        };
    }

    /// Expression `id`, whose context takes its value directly when
    /// `bound` (a binding or a place), and makes or copies it when
    /// `copied` (`copiedIn`).
    fn expr(w: *Walker, id: lir.ExprId, bound: bool, copied: bool, slots: *Slots) Error!void {
        const ctx = w.ctx;
        switch (w.f.exprs.items[id]) {
            .@"var" => |u| {
                // A part held first, counted here, in its place.
                if (w.held[u.v]) |e| return w.expr(e, bound, copied, slots);
                if (copied and !w.declares(u.node)) try w.copy(u.node, slots);
            },
            .leaf => |l| if (copied and !w.declares(l)) try w.copy(l, slots),
            .hold => |h| {
                w.ops += 1;
                try w.expr(h.value, bound, copied, slots);
            },
            .coerce => |c| {
                w.ops += 1;
                try w.expr(c.value, bound, copied, slots);
            },
            .block => |r| {
                // A region that yields its own node's value (a call that
                // holds its parts, a header, a statement's value, a value
                // `if` or `match`) stands for that node; any other is a
                // block whose value is copied out of it, once, as its
                // value.
                const reg = &w.f.regions.items[r];
                const through = if (reg.value) |v| sameNode(w.nodeOf(v), reg.node) else false;
                try w.region(r, if (through) bound else false, if (through) copied else true, slots);
            },
            .branch => |b| {
                w.ops += 1;
                if (copied) try w.copy(b.node, slots);
                try w.expr(b.cond, false, true, slots);
                try w.region(b.then, false, true, slots);
                if (b.@"else") |e| try w.region(e, false, true, slots);
            },
            .choice => |c| {
                w.ops += 1;
                if (copied) try w.copy(c.node, slots);
                try w.choice(c, slots);
            },
            .closure => |c| {
                w.ops += 1;
                // The captures are stored where the closure is made; its
                // body is a frame of its own.
                if (w.m.owners[c.owner].func) |body| {
                    const top = &body.regions.items[body.body];
                    for (top.decls.items) |x| switch (body.vars.items[x].name) {
                        .binding => |s| {
                            const cs = w.sym(s);
                            if (cs.kind == .capture and !cs.flags.comptime_known) try slots.append(ctx.allocator, .{ .ty = cs.ty, .name = cs.name });
                        },
                        .hidden => {},
                    };
                }
                const caps = ir.get(c.node, .captures);
                const nodes: []const Sexp = if (caps == .list) rig.children(caps) else &.{};
                for (c.captures, 0..) |x, i| if (i < nodes.len and ir.get(nodes[i], .value) != .nil) try w.expr(x, false, true, slots);
            },
            .op => |o| try w.op(o, bound, copied, slots),
        }
    }

    /// Whether `node` is the name a binding is declared by: its value is
    /// the binding's, counted where it is declared (`decls`).
    fn declares(w: *const Walker, node: Sexp) bool {
        if (node != .src) return false;
        const id = w.ctx.symbolOf(node) orelse return false;
        return w.sym(id).decl_pos == node.src.pos;
    }

    fn op(w: *Walker, o: lir.Expr.Op, bound: bool, copied: bool, slots: *Slots) Error!void {
        const ctx = w.ctx;
        const node = o.node;
        const kind = node.kind() orelse {
            // A group (a parameter list) has no kind.
            for (o.args) |a| try w.expr(a, false, false, slots);
            return;
        };
        // A keyword argument counts as its value: its name emits nothing,
        // so naming an option never changes a decision.
        if (kind != .kwarg) w.ops += 1;
        if (kind == .box) {
            // A fill built in the box's allocation is no temporary.
            const in_place = storage.fillsInPlace(ctx, node);
            const kids = rig.children(node);
            for (o.args, 0..) |a, i| if (i < kids.len and compat.sameSite(kids[i], ir.Box.operand(node))) try w.expr(a, in_place, !in_place, slots);
            return;
        }
        switch (kind) {
            .array, .array_fill => if (!bound) if (ctx.typeOf(node)) |ty| try slots.append(ctx.allocator, .{ .ty = ty, .name = "" }),
            .call => if (ctx.typeOf(node)) |ty| {
                // A constructor builds its value where a binding takes it.
                if (!bound or w.callsFunction(node)) try slots.append(ctx.allocator, .{ .ty = ty, .name = "" });
            },
            else => {},
        }
        if (copied) try w.copy(node, slots);
        if (kind == .call) {
            // A self a method takes by value is copied.
            if (storage.selfOf(ctx, node)) |recv| if (w.takesSelf(node)) try w.copy(recv, slots);
            try w.addInlined(node, slots);
        }
        const kids = rig.children(node);
        const by_child = o.args.len == kids.len;
        for (o.args, 0..) |a, i| try w.expr(a, false, if (by_child) copiedIn(ctx, node, kids[i]) else true, slots);
    }

    /// A copy of the value of `node` in the frame's reach, unless it is
    /// viewed where it is used (a pointer) or fits in registers. A view its
    /// context reads through (`readsThrough`: a use that expects the
    /// value copies it out) counts at the size of what it views.
    fn copy(w: *Walker, node: Sexp, slots: *Slots) Error!void {
        const ctx = w.ctx;
        if (ctx.viewOf(node) != null) return;
        const seen = ctx.typeOf(node) orelse return;
        const ty = if (ctx.readsThrough(node)) sema.unwrapViews(ctx, seen) else seen;
        if (!sema.containsTypeVar(ctx, ty)) {
            if (sema.containsPoison(ctx, ty)) return;
            const b = (try sema.minBytes(ctx, ty)) orelse return;
            if (b <= sema.register_bytes) return;
        }
        try slots.append(ctx.allocator, .{ .ty = ty, .name = "", .copy = true });
    }

    /// Whether `call` calls a function or method, not a type's constructor.
    fn callsFunction(w: *const Walker, call: Sexp) bool {
        const callee = w.ctx.calleeOf(call);
        if (callee.isKind(.member)) return true;
        const id = w.ctx.symbolOf(callee) orelse return false;
        return w.sym(id).kind == .function;
    }

    /// Whether the method `call` calls takes its self by value, not
    /// through a view.
    fn takesSelf(w: *const Walker, call: Sexp) bool {
        const ctx = w.ctx;
        const f = storage.fnType(ctx, storage.typeOf(ctx, ctx.calleeOf(call))) orelse return false;
        if (f.params.len == 0) return false;
        return switch (ctx.types.get(f.params[0])) {
            .read_view, .write_view => false,
            else => true,
        };
    }

    /// A copy of each parameter of the function: where it is inlined,
    /// Zig's code copies each into a local of its own (`rig.rt`), beside
    /// the argument a call makes and the parameter itself.
    fn paramCopies(w: *Walker, slots: *Slots) Error!void {
        const top = &w.f.regions.items[w.f.body];
        for (top.decls.items) |x| switch (w.f.vars.items[x].name) {
            .binding => |id| {
                const s = w.sym(id);
                if (s.kind != .param or s.flags.comptime_known) continue;
                try slots.append(w.ctx.allocator, .{ .ty = s.ty, .name = "", .copy = true });
            },
            .hidden => {},
        };
    }

    /// The values a call of a marked `inline` function lands in the frame
    /// it is in (`sema.InlineCall`): the function's own values and copies
    /// and those of the marked functions it calls in turn
    /// (`inlineFrame`), at the instance the call makes, in this module's
    /// types, each marked. The count fails closed: a frame no count knows,
    /// or one the instance does not make concrete, is an error at the
    /// call, never no values.
    fn addInlined(w: *Walker, call: Sexp, slots: *Slots) Error!void {
        const ctx = w.ctx;
        const ic = ctx.inlineCallOf(call) orelse return;
        const decl = ctx.declaringContext(ic.fun) orelse return w.unknownFrame(call, "its module is not loaded");
        const local = decl == @as(*const SemContext, ctx);
        if (!decl.inline_decls.contains(ic.fun.pos)) return w.unknownFrame(call, "its declaration is not recorded");
        // Zig inlines each call into the body it is in, nested as deep as
        // the calls are: past `max_inline_depth` Zig itself runs out of
        // stack, so a deeper nesting is an error, found before this walk
        // goes deeper.
        if (w.depth + 1 > max_inline_depth) return w.tooDeep(call);
        const found = if (local)
            // Null on a cycle of `inline` functions, which
            // `inlining.decide` reports, so the program is never emitted.
            (try inlineFrame(ctx, w.m, ic.fun.pos, w.depth + 1)) orelse return
        else
            // The module that declares it worked out its frame (`count`),
            // unless that module failed its check.
            (decl.inline_frames.get(ic.fun.pos) orelse return w.unknownFrame(call, "its module did not count it")) orelse return w.unknownFrame(call, "its module did not count it");
        const below = decl.inline_heights.get(ic.fun.pos) orelse 0;
        if (w.depth + 1 + below > max_inline_depth) return w.tooDeep(call);
        w.height = @max(w.height, below + 1);
        // The instance binds every parameter the frame mentions: with each
        // argument poisoned, none is left.
        const a = ctx.arena.allocator();
        const blank = try a.alloc(TypeId, ic.subst.args.len);
        @memset(blank, ctx.types.invalid_id);
        for (found) |slot| {
            const ty = if (local) slot.ty else try sema.importType(ctx, decl, slot.ty, ic.fun.module);
            if (sema.containsTypeVar(ctx, try sema.substituteType(ctx, ty, .{ .params = ic.subst.params, .args = blank })))
                return w.unknownFrame(call, "the call does not bind every parameter its values hold");
            try slots.append(ctx.allocator, .{ .ty = try sema.substituteType(ctx, ty, ic.subst), .name = slot.name, .copy = slot.copy, .marked = true });
        }
    }

    fn unknownFrame(w: *Walker, call: Sexp, why: []const u8) Error!void {
        try w.ctx.errAt(ir.Call.callee(call), "cannot count the values this `inline` call adds to the frame it is in ({s}); a frame must be known to be checked", .{why});
    }

    fn tooDeep(w: *Walker, call: Sexp) Error!void {
        try w.ctx.errAt(ir.Call.callee(call), "calls of `inline` functions nest more than {d} deep through this one, which no build can inline; drop `inline` from one of them", .{max_inline_depth});
    }
};

/// Whether `node` is a `defer` or `errdefer` statement: its region holds
/// its body's.
fn isDefer(node: Sexp) bool {
    return node.isKind(.@"defer") or node.isKind(.@"errdefer");
}

/// Whether the value of `child` is made or copied where `parent` uses
/// it, by a positive list of the uses that read it in place: a callee,
/// and the base of a field or element path or the operand of a view
/// that is storage (`storage.hasStorage`) or reached where its leaf is
/// (`storage.reachesLeaf`); any other base or operand is made into a
/// temporary first.
fn copiedIn(ctx: *SemContext, parent: Sexp, child: Sexp) bool {
    return switch (parent.kind().?) {
        .member, .index => !compat.sameSite(child, ir.get(parent, .object)) or !readsInPlace(ctx, child),
        .read, .write => !readsInPlace(ctx, child),
        .call => !compat.sameSite(child, ctx.calleeOf(parent)),
        else => true,
    };
}

fn readsInPlace(ctx: *SemContext, e: Sexp) bool {
    return storage.hasStorage(ctx, e) or storage.reachesLeaf(ctx, e);
}

fn sameNode(a: Sexp, b: Sexp) bool {
    const ka = sema.decisionKeyOf(a) orelse return false;
    return ka == sema.decisionKeyOf(b);
}
