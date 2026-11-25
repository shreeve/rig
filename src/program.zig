//! The program-wide decisions, made once every module is checked, which
//! emit reads.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const storage = @import("storage.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const typeOf = storage.typeOf;

/// Decide which word-sized objects (`sema.wordBits`) emit holds as one
/// word, a Zig `packed struct`, for the whole program at once: every
/// module's views can reach a type another module declares. A type stays
/// a plain struct where a write view anywhere (`!x.a`, a `!@` call on a
/// place) takes the address of one of its fields, which a word has none
/// of; or the address of one of a 64-bit type inside another object,
/// where it is held at that object's 4-byte alignment (`align(4)`), not
/// its own, as it is inside an optional (`rig.Opt`); and where a word
/// inside it stays plain. Its read views copy it whole, so a read takes
/// no address.
/// Recorded on the declaring module's context (`SemContext.word_held`).
pub fn decideWords(mods: []const *SemContext, trees: []const Sexp) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const a = gpa.allocator();
    // Declared sym -> plain, per declaring context.
    var plain: std.AutoHashMapUnmanaged(struct { *const SemContext, SymbolId }, void) = .empty;
    for (mods, trees) |ctx, tree| try viewsInto(a, ctx, tree, &plain);
    // A word holds the words inside it as bits of its own, so it is held
    // as one only when each of them is.
    var changed = true;
    while (changed) {
        changed = false;
        for (mods) |ctx| for (ctx.symbols.items, 0..) |sym, i| {
            const id: SymbolId = @intCast(i);
            if (sema.wordBitsOfSym(ctx, id) == null or plain.contains(.{ ctx, id })) continue;
            for (sym.fields orelse &.{}) |f| {
                if (f.is_method or f.is_variant) continue;
                const d = sema.nominalDecl(ctx, f.ty) orelse continue;
                if (!plain.contains(.{ d.ctx, d.sym })) continue;
                try plain.put(a, .{ ctx, id }, {});
                changed = true;
                break;
            }
        };
    }
    for (mods) |ctx| {
        ctx.word_held.clearRetainingCapacity();
        for (ctx.symbols.items, 0..) |_, i| {
            const sym: SymbolId = @intCast(i);
            if (sema.wordBitsOfSym(ctx, sym) == null) continue;
            if (plain.contains(.{ ctx, sym })) continue;
            try ctx.word_held.put(ctx.allocator, sym, {});
        }
    }
}

/// Give each plain enum an `exact` object holds, in a field or a fixed
/// array, in any module, its tag type (`SemContext.exact_enums`): a Zig
/// `extern struct` holds no enum of an inferred tag, and the tag's bytes
/// are the enum's in the object's layout (`sema.enumBytes`). For the
/// whole program at once, since the enum may be another module's.
pub fn decideExactEnums(mods: []const *SemContext) !void {
    for (mods) |ctx| ctx.exact_enums.clearRetainingCapacity();
    for (mods) |ctx| for (ctx.symbols.items) |sym| {
        if (sema.isProxy(sym) or sym.kind != .nominal_type or !sym.flags.exact) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant or f.is_drop_method) continue;
            try exactEnum(ctx, f.ty);
        }
    };
}

fn exactEnum(ctx: *SemContext, ty: TypeId) !void {
    switch (ctx.types.get(ty)) {
        .array => |arr| return exactEnum(ctx, arr.elem),
        .nominal, .imported_nominal => {},
        else => return,
    }
    if (!sema.isPlainEnum(ctx, ty)) return;
    const d = sema.nominalDecl(ctx, ty) orelse return;
    if (d.symbol().flags.enum_valued or d.symbol().flags.error_set) return;
    const bytes = sema.enumBytes(d.ctx, d.sym) orelse return;
    if (bytes == 0) return;
    // The declaring module's context, which emit reads for the enum.
    const home: *SemContext = @constCast(d.ctx);
    try home.exact_enums.put(home.allocator, d.sym, @intCast(bytes));
}

fn optionalWord(a: std.mem.Allocator, ctx: *const SemContext, t: TypeId, plain: anytype) !void {
    var ty = sema.unwrapViews(ctx, t);
    var opt = false;
    while (true) switch (ctx.types.get(ty)) {
        .optional => |inner| {
            opt = true;
            ty = inner;
        },
        else => break,
    };
    if (opt and sema.wordBits(ctx, ty) == 64) if (sema.nominalDecl(ctx, ty)) |d| try plain.put(a, .{ d.ctx, d.sym }, {});
}

fn viewsInto(a: std.mem.Allocator, ctx: *const SemContext, e: Sexp, plain: anytype) !void {
    if (e != .list) return;
    if (e.isKind(.write)) {
        // A 64-bit word inside an optional is held at four-byte
        // alignment too (`rig.Opt`).
        if (typeOf(ctx, ir.Write.operand(e))) |t| try optionalWord(a, ctx, t, plain);
        var cur = ir.Write.operand(e);
        while (cur == .list) {
            if (cur.isKind(.member)) {
                const obj = ir.Member.object(cur);
                if (typeOf(ctx, obj)) |ot| {
                    const inner = sema.unwrapViews(ctx, ot);
                    // A field of a word.
                    if (sema.wordBits(ctx, inner) != null) if (sema.nominalDecl(ctx, inner)) |d| try plain.put(a, .{ d.ctx, d.sym }, {});
                    // A 64-bit word held inside another object, which is
                    // plain, or is made so just above.
                    if (typeOf(ctx, cur)) |ft| {
                        const fi = sema.unwrapViews(ctx, ft);
                        if (sema.wordBits(ctx, fi) == 64) if (sema.nominalDecl(ctx, fi)) |d| try plain.put(a, .{ d.ctx, d.sym }, {});
                    }
                }
                cur = obj;
            } else if (cur.isKind(.index)) {
                cur = ir.Index.object(cur);
            } else break;
        }
    }
    for (e.items()) |c| try viewsInto(a, ctx, c, plain);
}
