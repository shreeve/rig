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
    /// Moves; one owner; dropped once (Core §1, "owning").
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
    /// Values are or hold a Text, whose bytes a String may view.
    reaches_text: bool,
    /// Dropping it runs a user `drop` body somewhere inside.
    drop_reads: bool,
    /// Why the oracle does not model values of this type yet.
    unsupported: ?[]const u8,
};

pub const Kinds = struct {
    a: std.mem.Allocator,
    ctx: *const SemContext,
    /// Apply the Core's planned rules: a type holding a `Cell` is unique
    /// (Core §1, planned).
    planned: bool,
    memo: std.AutoHashMapUnmanaged(TypeId, Info) = .empty,

    pub fn init(a: std.mem.Allocator, ctx: *const SemContext, planned: bool) Kinds {
        return .{ .a = a, .ctx = ctx, .planned = planned };
    }

    pub fn of(self: *Kinds, ty: TypeId) !Info {
        if (self.memo.get(ty)) |info| return info;
        const ctx = self.ctx;
        const ti = ctx.typeInfo(ty);
        var scan: Scan = .{ .a = self.a };
        defer scan.seen.deinit(self.a);
        try scan.walk(ctx, ty, 0, false);
        const kind: Kind = switch (ctx.types.get(ty)) {
            .borrow_write => .write_view,
            .borrow_read, .slice, .string => .read_view,
            // A unique value moves and is dropped once, like an owner
            // (Core §1): a declared one, and under the planned rule one
            // holding a Cell.
            else => if (ti.glue or ti.unique or (self.planned and ti.cell))
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
            .reaches_text = ti.borrows.text or ctx.types.get(ty) == .text,
            .drop_reads = scan.drop_body and kind == .owning,
            .unsupported = if (ti.poison) "a type with an error" else scan.unsupported,
        };
        try self.memo.put(self.a, ty, info);
        return info;
    }
};

/// A walk over what a type holds, through the fields of nominal types
/// in whichever module declares them.
const Scan = struct {
    a: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(struct { usize, TypeId }, void) = .empty,
    unsupported: ?[]const u8 = null,
    drop_body: bool = false,

    fn walk(self: *Scan, ctx: *const SemContext, ty: TypeId, depth: u32, in_generic: bool) std.mem.Allocator.Error!void {
        const gop = try self.seen.getOrPut(self.a, .{ @intFromPtr(ctx), ty });
        if (gop.found_existing) return;
        switch (ctx.types.get(ty)) {
            .invalid, .unknown => self.mark("a type with an error"),
            .shared, .weak => self.mark("a handle (`*T`, `~T`)"),
            .function, .callable => self.mark("a function or closure value"),
            .type_var, .ct_param => if (!in_generic) self.mark("a generic parameter"),
            .ct_value => {},
            .borrow_write => |inner| {
                if (depth > 0) self.mark("a write view held in a value");
                try self.walk(ctx, inner, depth + 1, in_generic);
            },
            .borrow_read, .optional, .fallible, .range => |inner| try self.walk(ctx, inner, depth + 1, in_generic),
            .slice => |s| try self.walk(ctx, s.elem, depth + 1, in_generic),
            .array => |arr| try self.walk(ctx, arr.elem, depth + 1, in_generic),
            .nominal => |sym| try self.fields(ctx, sym, depth, in_generic),
            .imported_nominal => |in| {
                const foreign = ctx.foreign_semas.get(in.module_id) orelse return self.mark("an unknown module's type");
                try self.fields(foreign, in.sym_id, depth, in_generic);
            },
            .parameterized_nominal => |pn| {
                // A Cell or Signal of plain data changes through any path
                // (Core s9); one that holds an owner or a view needs the
                // rule that it accepts only values carrying no loan, which
                // the oracle does not model yet.
                if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) {
                    for (pn.args) |arg| {
                        const ai = ctx.typeInfo(arg);
                        if (ai.glue or ai.unique or ai.borrows.any or ai.borrows.view or ai.has_type_var or ctx.types.get(arg) == .string) return self.mark("a `Cell` or `Signal` of an owner or a view");
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
            if (f.is_drop_method) self.drop_body = true;
            for (sema.dataFields(f)) |d| try self.walk(ctx, d.ty, depth + 1, in_generic);
        }
    }

    fn mark(self: *Scan, why: []const u8) void {
        if (self.unsupported == null) self.unsupported = why;
    }
};
