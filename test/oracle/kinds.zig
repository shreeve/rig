//! The four kinds of value (Core §1), read from sema's types: what a
//! bare use of a value does, whether it may carry a loan, and whether
//! dropping it runs a user `drop` body. A unique type (`struct T
//! unique`, or one holding it) moves like an owner (Core §1, built); a
//! type holding a `Cell` copies, unless the planned rule that makes it
//! unique too is on (`Kinds.planned`).

const std = @import("std");
const lib = @import("rig_lib");
const sema = lib.sema;

const TypeId = sema.TypeId;
const SemContext = sema.SemContext;

pub const Kind = enum {
    /// Copies: owns nothing and views nothing (Core §1, "plain").
    plain,
    /// Moves; one owner; dropped once (Core §1, "owning"). A handle,
    /// `*T` or `~T`, is one too (Core §1: "moves; `+h` adds a count"):
    /// what it holds is the box's, read through it, and dropping the
    /// last count drops it.
    owning,
    /// A read view: copies, and every copy carries its loans (Core §1).
    read_view,
    /// A write view: moves (Core §1).
    write_view,

    /// A bare use copies (Core s1).
    pub fn copies(k: Kind) bool {
        return k == .plain or k == .read_view;
    }
};

pub const Info = struct {
    kind: Kind,
    /// Values may carry a loan (Core §4: a view, or a value holding one).
    holds_views: bool,
    /// Values may hold a `?T`, `!T`, or slice.
    holds_pointers: bool,
    /// Values may hold a write view, which a call may store in them as
    /// it was lent (Core §5: a container of write views).
    holds_writes: bool = false,
    /// Dropping it runs a user `drop` body somewhere inside.
    drop_reads: bool,
    /// Why the oracle does not model values of this type yet.
    unsupported: ?[]const u8,
    /// In a generic body: it moves only because it holds a type
    /// parameter, whose instances may copy (SPEC "Generic bodies").
    generic_copy: bool = false,
};

pub const Kinds = struct {
    a: std.mem.Allocator,
    ctx: *const SemContext,
    /// Apply the Core's planned rules: a type holding a `Cell` is unique
    /// (Core §1, planned).
    planned: bool,
    memo: std.AutoHashMapUnmanaged(TypeId, Info) = .empty,
    /// Kinds in a generic body: a type parameter is owning and holds no
    /// view (SPEC "Generic bodies"), which is what the compiler checks
    /// the body for; each instance is checked against what the body
    /// does with it.
    generic: bool = false,

    pub fn init(a: std.mem.Allocator, ctx: *const SemContext, planned: bool) Kinds {
        return .{ .a = a, .ctx = ctx, .planned = planned };
    }

    pub fn of(self: *Kinds, ty: TypeId) !Info {
        if (self.memo.get(ty)) |info| return info;
        const ctx = self.ctx;
        if (callableInfo(ctx, ty)) |info| {
            try self.memo.put(self.a, ty, info);
            return info;
        }
        const ti = ctx.typeInfo(ty);
        var scan: Scan = .{ .a = self.a };
        defer scan.seen.deinit(self.a);
        try scan.walk(ctx, ty, 0, self.generic);
        const kind: Kind = switch (ctx.types.get(ty)) {
            .borrow_write => .write_view,
            .borrow_read, .slice, .string => .read_view,
            // A unique value moves and is dropped once, like an owner
            // (Core §1): a declared one, and under the planned rule one
            // holding a Cell.
            else => if (ti.glue or ti.unique or (self.planned and ti.cell) or (self.generic and (ti.holds_type_var or ctx.types.get(ty) == .type_var)))
                .owning
            else if (ti.borrows.write)
                .write_view
            else if (ti.borrows.any or ti.borrows.view)
                .read_view
            else
                .plain,
        };
        const info: Info = .{
            .kind = kind,
            .holds_views = ti.borrows.any or ti.borrows.view,
            .holds_pointers = ti.borrows.any,
            .holds_writes = ti.borrows.write,
            .drop_reads = scan.drop_body and kind == .owning,
            .unsupported = if (ti.poison) "a type with an error" else scan.unsupported,
            .generic_copy = kind == .owning and !(ti.glue or ti.unique or (self.planned and ti.cell)),
        };
        try self.memo.put(self.a, ty, info);
        return info;
    }
};

/// A closure, a function value, or a view of one (Core §7). A stack
/// closure is never copied or moved, and its environment carries the
/// loans of what it captured; a view of one (`?fun`) is a read view.
/// An owned closure is a handle whose captures carry no loan (Core s9).
fn callableInfo(ctx: *const SemContext, ty: TypeId) ?Info {
    const t = ctx.types.get(ty);
    const env: Info = .{ .kind = .owning, .holds_views = true, .holds_pointers = true, .drop_reads = false, .unsupported = null };
    return switch (t) {
        .function => env,
        .callable => .{ .kind = .read_view, .holds_views = true, .holds_pointers = true, .drop_reads = false, .unsupported = null },
        .borrow_read, .borrow_write => |inner| if (ctx.types.get(inner) == .function or ctx.types.get(inner) == .callable) .{
            .kind = if (t == .borrow_read) .read_view else .write_view,
            .holds_views = true,
            .holds_pointers = true,
            .drop_reads = false,
            .unsupported = null,
        } else null,
        .shared, .weak => |inner| if (ctx.types.get(inner) == .function) .{ .kind = .owning, .holds_views = false, .holds_pointers = false, .drop_reads = false, .unsupported = null } else null,
        else => null,
    };
}

/// A walk over what a type holds, through the fields of nominal types
/// in whichever module declares them.
const Scan = struct {
    a: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(struct { usize, TypeId, bool, bool }, void) = .empty,
    unsupported: ?[]const u8 = null,
    drop_body: bool = false,
    /// Walking what a weak handle holds, which it never drops.
    under_weak: bool = false,
    /// Walking what a read view or a handle reaches, which is only read.
    read_only: bool = false,

    fn walk(self: *Scan, ctx: *const SemContext, ty: TypeId, depth: u32, in_generic: bool) std.mem.Allocator.Error!void {
        const gop = try self.seen.getOrPut(self.a, .{ @intFromPtr(ctx), ty, self.under_weak, self.read_only });
        if (gop.found_existing) return;
        switch (ctx.types.get(ty)) {
            .invalid, .unknown => self.mark("a type with an error"),
            // A handle carries its contents' loans (Core s9), and
            // dropping a counted one may drop them.
            // An owned closure carries no loan (Core s9).
            .shared => |inner| if (ctx.types.get(inner) != .function) {
                const saved = self.read_only;
                self.read_only = true;
                defer self.read_only = saved;
                try self.walk(ctx, inner, depth + 1, in_generic);
            },
            // A weak handle never drops what it holds.
            .weak => |inner| if (ctx.types.get(inner) != .function) {
                const saved = self.under_weak;
                const saved_ro = self.read_only;
                self.under_weak = true;
                self.read_only = true;
                defer self.under_weak = saved;
                defer self.read_only = saved_ro;
                try self.walk(ctx, inner, depth + 1, in_generic);
            },
            .function, .callable => self.mark("a function or closure value"),
            .type_var, .ct_param => if (!in_generic) self.mark("a generic parameter"),
            .ct_value => {},
            // A write view held in a container, an optional, or a field
            // is a place that moves with its holder: a store re-points it
            // and a write goes through it (Core §5, §6). One a read view
            // or a handle reaches could only be read, which the oracle
            // does not model.
            .borrow_write => |inner| {
                if (self.read_only) self.mark("a write view seen through a read view or a handle");
                try self.walk(ctx, inner, depth + 1, in_generic);
            },
            .borrow_read => |inner| {
                const saved = self.read_only;
                self.read_only = true;
                defer self.read_only = saved;
                try self.walk(ctx, inner, depth + 1, in_generic);
            },
            .optional, .fallible, .range => |inner| try self.walk(ctx, inner, depth + 1, in_generic),
            .slice => |s| try self.walk(ctx, s.elem, depth + 1, in_generic),
            .array => |arr| try self.walk(ctx, arr.elem, depth + 1, in_generic),
            .nominal => |sym| try self.fields(ctx, sym, depth, in_generic),
            .imported_nominal => |in| {
                const foreign = ctx.foreign_semas.get(in.module_id) orelse return self.mark("an unknown module's type");
                try self.fields(foreign, in.sym_id, depth, in_generic);
            },
            .parameterized_nominal => |pn| {
                // A Cell or Signal changes through any path, and holds
                // only values that carry no loan (Core s9): what it holds
                // carries none, and a store into it is checked (C8). One
                // of a `?T`, `!T`, or slice is the compiler's to reject.
                if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) {
                    for (pn.args) |arg| {
                        if (ctx.typeInfo(arg).borrows.any) return self.mark("a `Cell` or `Signal` of a view");
                        try self.walk(ctx, arg, depth + 1, in_generic);
                    }
                    return;
                }
                for (pn.args) |arg| try self.walk(ctx, arg, depth + 1, in_generic);
                if (pn.sym != ctx.vec_sym_id and pn.sym != ctx.box_sym_id) try self.fields(ctx, pn.sym, depth, true);
            },
            else => {},
        }
    }

    fn fields(self: *Scan, ctx: *const SemContext, sym_id: sema.SymbolId, depth: u32, in_generic: bool) !void {
        const sym = ctx.symbols.items[sym_id];
        if (sema.isProxy(sym)) {
            if (sym.from.module_id != 0) if (ctx.foreign_semas.get(sym.from.module_id)) |foreign| {
                return self.fields(foreign, sym.from.sym, depth, in_generic);
            };
            return self.mark("an imported generic type");
        }
        for (sym.fields orelse &.{}) |*f| {
            if (f.is_drop_method and !self.under_weak) self.drop_body = true;
            for (sema.dataFields(f)) |d| try self.walk(ctx, d.ty, depth + 1, in_generic);
        }
    }

    fn mark(self: *Scan, why: []const u8) void {
        if (self.unsupported == null) self.unsupported = why;
    }
};

/// What a view may point into, and which values may lead there (Core
/// sentence 7: "a call passes on only the loans its signature shows";
/// "a view reached through another view carries that view's loans, not
/// a loan on its holder"). The memory a view points into has a type: a
/// `?T` or `!T` a `T`, a `[]T` or `![]T` its `T` elements, a String a
/// Text's or a literal's bytes. A function, a lent callable, a type
/// parameter, and a type not known may point anywhere.
pub const Reach = struct {
    a: std.mem.Allocator,

    /// A type, spelled the same in every module: a declared type as
    /// where it is declared, any other by its structure.
    fn key(self: *Reach, ctx: *const SemContext, ty: TypeId, subst: ?*const Subst) std.mem.Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a);
        spell(&out.writer, ctx, ty, subst, 0) catch return error.OutOfMemory;
        return out.written();
    }

    fn spell(w: *std.Io.Writer, ctx: *const SemContext, ty: TypeId, subst: ?*const Subst, depth: u32) std.Io.Writer.Error!void {
        if (depth > 32) return w.writeAll("...");
        const t = ctx.types.get(ty);
        switch (t) {
            .nominal => |sym| if (sym == ctx.endian_sym_id) try w.writeAll("Endian") else try w.print("N{d}.{d}", .{ ctx.module_id, sym }),
            .imported_nominal => |n| try w.print("N{d}.{d}", .{ n.module_id, n.sym_id }),
            .parameterized_nominal => |pn| {
                const sym = ctx.symbols.items[pn.sym];
                if (sym.decl_pos == sema.builtin_decl_pos) try w.print("{s}[", .{sym.name}) else if (sema.isProxy(sym)) try w.print("G{d}.{d}[", .{ sym.from.module_id, sym.from.sym }) else try w.print("G{d}.{d}[", .{ ctx.module_id, pn.sym });
                for (pn.args) |arg| {
                    try spell(w, ctx, arg, subst, depth + 1);
                    try w.writeAll(",");
                }
                try w.writeAll("]");
            },
            .type_var => |sym| if (subst) |s| if (s.lookup(sym)) |b| return spell(w, b.ctx, b.ty, null, depth + 1),
            .borrow_read, .borrow_write, .optional, .fallible, .shared, .weak => |inner| {
                try w.print("{s}(", .{@tagName(t)});
                try spell(w, ctx, inner, subst, depth + 1);
                try w.writeAll(")");
            },
            .slice => |s| {
                try w.writeAll("slice(");
                try spell(w, ctx, s.elem, subst, depth + 1);
                try w.writeAll(")");
            },
            .array => |arr| {
                try w.writeAll("array(");
                try spell(w, ctx, arr.elem, subst, depth + 1);
                try w.writeAll(")");
            },
            .int => |i| try w.print("int{d}{s}", .{ i.bits, if (i.signed) "s" else "u" }),
            .float => |f| try w.print("float{d}", .{f.bits}),
            else => try w.writeAll(@tagName(t)),
        }
        if (t == .type_var) try w.writeAll("T?");
    }

    /// A generic type's parameters bound to an instance's arguments.
    const Subst = struct {
        params: []const sema.SymbolId,
        args: []const TypeId,
        ctx: *const SemContext,
        outer: ?*const Subst,

        fn lookup(self: *const Subst, sym: sema.SymbolId) ?struct { ctx: *const SemContext, ty: TypeId } {
            for (self.params, 0..) |p, i| if (p == sym and i < self.args.len) return .{ .ctx = self.ctx, .ty = self.args[i] };
            return null;
        }
    };

    /// What views of a type point into.
    const Targets = struct {
        any: bool = false,
        bytes: bool = false,
        types: std.ArrayList([]const u8) = .empty,
        /// Types a slice views: an element of an array, a slice, or a
        /// built-in container, never a field.
        elems: std.ArrayList([]const u8) = .empty,
    };

    /// One type to walk: in its module, under a generic instance's
    /// bindings, and how it was reached.
    const Node = struct { ctx: *const SemContext, ty: TypeId, subst: ?*const Subst = null, past_read: bool = false, past_view: bool = false, elem: bool = false };

    /// The parts a value of `n` holds by value.
    fn parts(self: *Reach, n: Node, out: *std.ArrayList(Node)) std.mem.Allocator.Error!void {
        const ctx = n.ctx;
        switch (ctx.types.get(n.ty)) {
            .optional, .fallible, .shared, .weak => |inner| try out.append(self.a, .{ .ctx = ctx, .ty = inner, .subst = n.subst, .past_read = n.past_read, .past_view = n.past_view }),
            .array => |arr| try out.append(self.a, .{ .ctx = ctx, .ty = arr.elem, .subst = n.subst, .past_read = n.past_read, .past_view = n.past_view, .elem = true }),
            .type_var => |sym| if (n.subst) |s| if (s.lookup(sym)) |b| try out.append(self.a, .{ .ctx = b.ctx, .ty = b.ty, .subst = s.outer, .past_read = n.past_read, .past_view = n.past_view }),
            .nominal => |sym| try self.fieldsOf(ctx, sym, n, null, out),
            .imported_nominal => |in| {
                const foreign = ctx.foreign_semas.get(in.module_id) orelse return;
                try self.fieldsOf(foreign, in.sym_id, n, null, out);
            },
            .parameterized_nominal => |pn| {
                const sym = ctx.symbols.items[pn.sym];
                const s = try self.a.create(Subst);
                s.* = .{ .params = sym.type_params orelse &.{}, .args = pn.args, .ctx = ctx, .outer = n.subst };
                // A built-in generic holds its arguments' values (a
                // Vec's buffer, a Box's value, a Cell's).
                if (sym.decl_pos == sema.builtin_decl_pos) {
                    for (pn.args) |arg| try out.append(self.a, .{ .ctx = ctx, .ty = arg, .subst = n.subst, .past_read = n.past_read, .past_view = n.past_view, .elem = true });
                }
                try self.fieldsOf(ctx, pn.sym, n, s, out);
            },
            else => {},
        }
    }

    fn fieldsOf(self: *Reach, ctx: *const SemContext, sym_id: sema.SymbolId, n: Node, s: ?*const Subst, out: *std.ArrayList(Node)) std.mem.Allocator.Error!void {
        for (ctx.symbols.items[sym_id].fields orelse &.{}) |*f| {
            for (sema.dataFields(f)) |d| try out.append(self.a, .{ .ctx = ctx, .ty = d.ty, .subst = s, .past_read = n.past_read, .past_view = n.past_view });
        }
    }

    /// `n`, or what the type parameter it is stands for.
    fn bound(n: Node) Node {
        var m = n;
        while (true) switch (m.ctx.types.get(m.ty)) {
            .type_var => |sym| {
                const s = m.subst orelse return m;
                const b = s.lookup(sym) orelse return m;
                m = .{ .ctx = b.ctx, .ty = b.ty, .subst = s.outer, .past_read = m.past_read, .past_view = m.past_view, .elem = m.elem };
            },
            else => return m,
        };
    }

    /// Whether `n` may stand for anything.
    fn anything(n: Node) bool {
        return switch (n.ctx.types.get(n.ty)) {
            .function, .callable, .invalid, .unknown => true,
            .type_var => |sym| if (n.subst) |s| s.lookup(sym) == null else true,
            else => false,
        };
    }

    fn targetsOf(self: *Reach, ctx: *const SemContext, view: TypeId) std.mem.Allocator.Error!Targets {
        var t: Targets = .{};
        var work: std.ArrayList(Node) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try work.append(self.a, .{ .ctx = ctx, .ty = view });
        while (work.pop()) |popped| {
            const n = bound(popped);
            if (anything(n)) {
                t.any = true;
                continue;
            }
            const k = try self.key(n.ctx, n.ty, n.subst);
            if ((try seen.getOrPut(self.a, k)).found_existing) continue;
            // A var carries the loans of what its views view, and of what
            // the views there view in turn: each target's own views point
            // into more targets.
            const target: ?Node = switch (n.ctx.types.get(n.ty)) {
                .borrow_read => |inner| .{ .ctx = n.ctx, .ty = inner, .subst = n.subst },
                // A `![]T` points at its elements.
                .borrow_write => |inner| switch (n.ctx.types.get(inner)) {
                    .slice => |sl| .{ .ctx = n.ctx, .ty = sl.elem, .subst = n.subst, .elem = true },
                    else => .{ .ctx = n.ctx, .ty = inner, .subst = n.subst },
                },
                .slice => |sl| .{ .ctx = n.ctx, .ty = sl.elem, .subst = n.subst, .elem = true },
                .string => blk: {
                    t.bytes = true;
                    break :blk null;
                },
                else => blk: {
                    try self.parts(n, &work);
                    break :blk null;
                },
            };
            if (target) |x| {
                try self.addTarget(&t, x);
                try work.append(self.a, x);
            }
        }
        return t;
    }

    fn addTarget(self: *Reach, t: *Targets, n: Node) std.mem.Allocator.Error!void {
        if (anything(n)) {
            t.any = true;
            return;
        }
        try (if (n.elem) &t.elems else &t.types).append(self.a, try self.key(n.ctx, n.ty, n.subst));
    }

    /// How a value of `holder` reaches memory `t` names: `owned`
    /// (through what it holds by value or a write view), `viewed` (only
    /// past some view), each when it does.
    const Found = struct { owned: bool = false, viewed: bool = false };

    fn walk(self: *Reach, ctx: *const SemContext, holder: TypeId, t: Targets) std.mem.Allocator.Error!Found {
        var r: Found = .{};
        if (!t.any and !t.bytes and t.types.items.len == 0 and t.elems.items.len == 0) return r;
        var work: std.ArrayList(Node) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try work.append(self.a, .{ .ctx = ctx, .ty = holder });
        while (work.pop()) |popped| {
            const n = bound(popped);
            const hit = anything(n) or t.any or blk: {
                const k = try self.key(n.ctx, n.ty, n.subst);
                for (t.types.items) |x| if (std.mem.eql(u8, x, k)) break :blk true;
                if (n.elem) for (t.elems.items) |x| if (std.mem.eql(u8, x, k)) break :blk true;
                break :blk false;
            };
            if (hit) {
                if (!n.past_read) r.owned = true;
                if (n.past_view or anything(n)) r.viewed = true;
            }
            if (anything(n)) continue;
            const k = try std.fmt.allocPrint(self.a, "{s}|{}{}{}", .{ try self.key(n.ctx, n.ty, n.subst), n.past_read, n.past_view, n.elem });
            if ((try seen.getOrPut(self.a, k)).found_existing) continue;
            switch (n.ctx.types.get(n.ty)) {
                .borrow_read => |inner| try work.append(self.a, .{ .ctx = n.ctx, .ty = inner, .subst = n.subst, .past_read = true, .past_view = true }),
                .slice => |sl| try work.append(self.a, .{ .ctx = n.ctx, .ty = sl.elem, .subst = n.subst, .past_read = true, .past_view = true, .elem = true }),
                .borrow_write => |inner| switch (n.ctx.types.get(inner)) {
                    .slice => |sl| try work.append(self.a, .{ .ctx = n.ctx, .ty = sl.elem, .subst = n.subst, .past_read = n.past_read, .past_view = true, .elem = true }),
                    else => try work.append(self.a, .{ .ctx = n.ctx, .ty = inner, .subst = n.subst, .past_read = n.past_read, .past_view = true }),
                },
                .string => if (t.bytes) {
                    r.viewed = true;
                },
                .text => if (t.bytes) {
                    if (!n.past_read) r.owned = true;
                    if (n.past_view) r.viewed = true;
                },
                else => try self.parts(n, &work),
            }
        }
        return r;
    }

    /// Whether a value of type `holder` may itself own, or reach through
    /// a write view, memory a value of type `view` points into: if not,
    /// such a value reached from it points into memory the read views it
    /// holds see, whose loans it holds.
    pub fn owns(self: *Reach, ctx: *const SemContext, holder: TypeId, view: TypeId) std.mem.Allocator.Error!bool {
        return (try self.walk(ctx, holder, try self.targetsOf(ctx, view))).owned;
    }

    /// Whether an argument for a parameter of type `param` may lead to
    /// memory a value of type `view` points into, past a view: the
    /// parameter's own memory is the callee's.
    pub fn leads(self: *Reach, ctx: *const SemContext, param: TypeId, view: TypeId) std.mem.Allocator.Error!bool {
        return (try self.walk(ctx, param, try self.targetsOf(ctx, view))).viewed;
    }

    /// Whether a call with parameters `params` may store an argument for
    /// `params[i]` in what a write parameter leads to: memory past a
    /// write view, which the call may put any value of its slots' types
    /// in.
    pub fn stores(self: *Reach, ctx: *const SemContext, params: []const TypeId, i: usize) std.mem.Allocator.Error!bool {
        var t: Targets = .{};
        for (params) |p| try self.writable(ctx, p, &t);
        return (try self.walk(ctx, params[i], t)).viewed;
    }

    /// Add to `t` what views held in memory a value of `ty` reaches past
    /// a write view point into.
    fn writable(self: *Reach, ctx: *const SemContext, ty: TypeId, t: *Targets) std.mem.Allocator.Error!void {
        var work: std.ArrayList(Node) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try work.append(self.a, .{ .ctx = ctx, .ty = ty });
        while (work.pop()) |popped| {
            const n = bound(popped);
            if (anything(n)) {
                if (n.past_view) t.any = true;
                continue;
            }
            const k = try std.fmt.allocPrint(self.a, "{s}|{}", .{ try self.key(n.ctx, n.ty, n.subst), n.past_view });
            if ((try seen.getOrPut(self.a, k)).found_existing) continue;
            const tt = n.ctx.types.get(n.ty);
            // A slot in written memory may get any value of its type.
            if (n.past_view) switch (tt) {
                .borrow_read, .borrow_write, .slice, .string => {
                    const v = try self.targetsOf(n.ctx, n.ty);
                    if (v.any) t.any = true;
                    if (v.bytes) t.bytes = true;
                    try t.types.appendSlice(self.a, v.types.items);
                    try t.elems.appendSlice(self.a, v.elems.items);
                },
                else => {},
            };
            switch (tt) {
                .borrow_write => |inner| {
                    const elem = switch (n.ctx.types.get(inner)) {
                        .slice => |sl| sl.elem,
                        else => inner,
                    };
                    try work.append(self.a, .{ .ctx = n.ctx, .ty = elem, .subst = n.subst, .past_view = true });
                },
                .borrow_read, .slice, .string => {},
                // What a handle holds is only read, but a handle stored in
                // a slot brings what its box holds.
                .shared, .weak => |inner| if (n.past_view) {
                    const v = try self.targetsOf(n.ctx, inner);
                    if (v.any) t.any = true;
                    if (v.bytes) t.bytes = true;
                    try t.types.appendSlice(self.a, v.types.items);
                    try t.elems.appendSlice(self.a, v.elems.items);
                },
                else => try self.parts(n, &work),
            }
        }
    }
};
