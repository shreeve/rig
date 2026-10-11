//! Which functions are emitted `inline`: decided once, for the whole
//! program, after every module is checked (docs/INTERNALS.md, "Inlining").
//!
//! Zig inlines a small function only when asked, and LLVM leaves a
//! small hot helper as a call when its body grows. A `fun` or `sub` is
//! emitted as an `inline fn` when
//!
//!   - its body has at most `max_size` nodes (`size`),
//!   - it is not on a cycle of calls, directly or through others,
//!   - no mention of it is anything but the callee of a call: it is
//!     never passed, stored, returned, or made into a closure,
//!   - it is not the program's `main`, has no compile-time parameters,
//!     is not a member of a generic type, and holds no closure.
//!
//! A call resolves by name (a method by its name alone, a function by
//! its symbol), so two functions of one name stand for each other: the
//! analysis only ever finds more cycles and more value uses than there
//! are, never fewer.
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
/// frame, and the stack guard (`rig.guardStack`) is sized for a frame of
/// 16 MiB, which `typecheck.checkFrames` holds each function to.
pub const max_inlined_frame_bytes: u128 = 64 << 10;

/// The most nodes an inlined function may expand to at a call, counting
/// the inlined calls in it (each of them as often as it is called):
/// otherwise a chain of functions that each call the next twice would make
/// Zig analyze a body 2^n times. Trig's JSON parser, the program that set
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
    calls: std.ArrayList(u32) = .empty,
    /// The bytes of values it keeps on its stack, once it is a candidate.
    own: u128 = 0,
    inlined: bool = false,
    /// Its frame with the inlined calls in it (`frames`).
    frame: ?u128 = null,
    /// Its size with the inlined calls in it (`expanded`).
    weight: ?u64 = null,
    // Tarjan's.
    index: u32 = 0,
    low: u32 = 0,
    on_stack: bool = false,
    cyclic: bool = false,
};

/// The name a leaf spells, including a name the iterator rewrite makes
/// (the `next` of a `for` over an iterator), which no source text holds.
fn textOf(c: *const SemContext, leaf: Sexp) []const u8 {
    return if (leaf == .src) rig.leafText(c.source, leaf.src) else "";
}

/// A call and the functions it may reach.
const Site = struct { module: usize, id: parser.NodeId, targets: []const u32 };

const Pass = struct {
    a: std.mem.Allocator,
    mods: []const *modules.Module,
    fns: std.ArrayList(Fn) = .empty,
    /// Each call that may reach a function, and which.
    sites: std.ArrayList(Site) = .empty,
    by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// Per module: the function declared at a position.
    by_pos: []std.AutoHashMapUnmanaged(u32, u32),
    max: u32,
    // Tarjan's.
    next_index: u32 = 1,
    stack: std.ArrayList(u32) = .empty,

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
        const eligible = body != .nil and !is_main and !generic_owner and sema.tparamsOf(node) == .nil;
        const idx: u32 = @intCast(self.fns.items.len);
        const pos = c.startOf(name_node);
        try self.fns.append(self.a, .{
            .module = module,
            .node = node,
            .name = name,
            .pos = pos,
            .eligible = eligible,
            .size = if (body != .nil) size(body) else 0,
        });
        if (body != .nil and holdsClosure(body)) self.fns.items[idx].eligible = false;
        try self.by_pos[module].put(self.a, pos, idx);
        const gop = try self.by_name.getOrPut(self.a, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.a, idx);
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
        const all = self.by_name.get(name) orelse return;
        // A data field of the receiver's type is not a method.
        if (c.typeOf(ir.Member.object(e))) |t| if (sema.nominalDecl(c, t)) |nom| {
            if (nom.ctx.symbols.items[nom.sym].fields) |fields| for (fields) |f| {
                if (std.mem.eql(u8, f.name, name) and !f.is_method) return;
            };
        };
        for (all.items) |f| self.fns.items[f].used_as_value = true;
    }

    fn visitCall(self: *Pass, module: usize, cur: ?u32, call: Sexp) std.mem.Allocator.Error!void {
        const c = self.ctx(module);
        const raw = ir.Call.callee(call);
        const callee = c.calleeOf(call);
        var targets: std.ArrayList(u32) = .empty;
        switch (callee.kind() orelse .set) {
            .member => {
                try self.visit(module, cur, ir.Member.object(callee));
                try self.named(&targets, textOf(c, ir.Member.name(callee)));
            },
            else => if (callee == .src) {
                const id = c.symbolOf(callee);
                if (id) |sid| {
                    const s = c.symbols.items[sid];
                    if (s.kind == .function) {
                        if (self.by_pos[module].get(s.decl_pos)) |to| try targets.append(self.a, to);
                    }
                } else try self.named(&targets, textOf(c, callee));
            } else try self.visit(module, cur, callee),
        }
        if (cur) |from| try self.fns.items[from].calls.appendSlice(self.a, targets.items);
        if (targets.items.len > 0 and call.list.id != 0) try self.sites.append(self.a, .{ .module = module, .id = call.list.id, .targets = targets.items });
        // The bracket list of a generic call, `f[T](x)`.
        if (raw.isKind(.inst)) for (raw.items()[2..]) |a| try self.visit(module, cur, a);
        for (ir.Call.args(call)) |a| try self.visit(module, cur, a);
    }

    fn named(self: *Pass, targets: *std.ArrayList(u32), name: []const u8) !void {
        const all = self.by_name.get(name) orelse return;
        try targets.appendSlice(self.a, all.items);
    }

    /// What the calls of `v` that are inlined add to its frame: the sum, over
    /// its call sites, of the frame of each inlined callee.
    fn added(self: *Pass, v: u32) u128 {
        var total: u128 = 0;
        for (self.fns.items[v].calls.items) |w| {
            if (self.fns.items[w].inlined) total += self.frame(w);
        }
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
        for (self.fns.items[v].calls.items) |w| {
            if (self.fns.items[w].inlined) total += self.expanded(w);
        }
        self.fns.items[v].weight = total;
        return total;
    }

    /// Stop inlining until no function adds more than
    /// `max_inlined_frame_bytes` to its frame, no inlined function has a
    /// frame of more than that, and none expands to more than
    /// `max_expanded` nodes.
    fn fit(self: *Pass) void {
        var again = true;
        while (again) {
            again = false;
            for (self.fns.items) |*f| {
                f.frame = null;
                f.weight = null;
            }
            for (self.fns.items, 0..) |*f, i| {
                const v: u32 = @intCast(i);
                if (f.inlined and (self.frame(v) > max_inlined_frame_bytes or self.expanded(v) > max_expanded)) {
                    f.inlined = false;
                    again = true;
                    break;
                }
                if (self.added(v) <= max_inlined_frame_bytes) continue;
                // The largest of the inlined calls.
                var biggest: ?u32 = null;
                for (f.calls.items) |w| {
                    if (!self.fns.items[w].inlined) continue;
                    if (biggest == null or self.frame(w) > self.frame(biggest.?)) biggest = w;
                }
                self.fns.items[biggest.?].inlined = false;
                again = true;
                break;
            }
        }
    }

    /// Mark every function on a cycle of calls (Tarjan).
    fn strong(self: *Pass, v: u32) !void {
        const f = &self.fns.items[v];
        f.index = self.next_index;
        f.low = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.a, v);
        f.on_stack = true;
        var self_loop = false;
        var i: usize = 0;
        while (i < self.fns.items[v].calls.items.len) : (i += 1) {
            const w = self.fns.items[v].calls.items[i];
            if (w == v) self_loop = true;
            if (self.fns.items[w].index == 0) {
                try self.strong(w);
                self.fns.items[v].low = @min(self.fns.items[v].low, self.fns.items[w].low);
            } else if (self.fns.items[w].on_stack) {
                self.fns.items[v].low = @min(self.fns.items[v].low, self.fns.items[w].index);
            }
        }
        if (self_loop) self.fns.items[v].cyclic = true;
        if (self.fns.items[v].low == self.fns.items[v].index) {
            var members: u32 = 0;
            const start = self.stack.items.len;
            var k = start;
            while (k > 0) {
                k -= 1;
                members += 1;
                if (self.stack.items[k] == v) break;
            }
            for (self.stack.items[k..start]) |w| {
                self.fns.items[w].on_stack = false;
                if (members > 1) self.fns.items[w].cyclic = true;
            }
            self.stack.shrinkRetainingCapacity(k);
        }
    }
};

/// The forms in `e`, each node of the tree once.
pub fn size(e: Sexp) u32 {
    if (e != .list) return 0;
    var n: u32 = if (e.kind() != null) 1 else 0;
    for (e.items()) |c| n += size(c);
    return n;
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
    for (0..pass.fns.items.len) |v| if (pass.fns.items[v].index == 0) try pass.strong(@intCast(v));
    for (pass.fns.items) |*f| {
        if (!f.eligible or f.used_as_value or f.cyclic or f.size > max) continue;
        const own = (try typecheck.frameBytesOfFunction(mods[f.module].sema, f.node)) orelse continue;
        if (own > max_inlined_frame_bytes) continue;
        f.own = own;
        f.inlined = true;
    }
    pass.fit();
    for (pass.fns.items) |f| {
        if (f.inlined) try mods[f.module].sema.inlined.put(allocator, f.pos, {});
    }
    // A call that may reach an inlined function hands back a value Zig
    // would know at compile time (`Emitter.emitCallDirect`).
    for (pass.sites.items) |site| {
        for (site.targets) |t| if (pass.fns.items[t].inlined) {
            try mods[site.module].sema.inlined_calls.put(allocator, site.id, {});
            break;
        };
    }
}
