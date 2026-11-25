//! The program table: the decisions made once for the whole program,
//! after every module is checked, which emit reads. Each is keyed by a
//! module's id and a place in it: where a function's or method's name is
//! declared, a call's node, or a declared symbol.
//!
//! | Decision | Keyed by | Decider |
//! |---|---|---|
//! | `inlined`: Zig inlines it at every call | name | `inlining.decide` |
//! | `entry_checks`: its entry checks for work left waiting | name | `inlining.decide` |
//! | `inlined_calls`: the call may reach an inlined function | call | `inlining.decide` |
//! | `dense_calls`: a task the call starts may take a dense stack, and the most stack it may take | call | `inlining.decide` |
//! | `never_returns`: Zig's result for it is `noreturn` | name | `returns.decide` |
//! | `split_units`: the unit that owns it in a split build | name | `units.decide` |
//! | `word_held`: the object is held as one word, a `packed struct` | symbol | `decideWords` |
//! | `exact_enums`: the plain enum's tag bytes, where an `exact` object holds it | symbol | `decideExactEnums` |
//! | `text_tables`: the plain enum emits its table of names for `from_text` | symbol | `ModuleGraph.decide` |
//!
//! The graph owns the table (`ModuleGraph.table`); every module's
//! context points at it (`SemContext.program`), which `Facts` reads.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const modules = @import("modules.zig");
const storage = @import("storage.zig");
const fastmap = @import("fastmap.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const typeOf = storage.typeOf;

/// A place in module `module`: a name's position, a node, or a symbol.
pub const Key = struct { module: u32, at: u32 };

/// A map by place, carrying `V` for each.
pub fn Of(comptime V: type) type {
    return fastmap.Map(Key, V);
}

pub const Table = struct {
    allocator: std.mem.Allocator,
    inlined: Of(void) = .empty,
    entry_checks: Of(void) = .empty,
    inlined_calls: Of(void) = .empty,
    dense_calls: Of(u64) = .empty,
    never_returns: Of(void) = .empty,
    split_units: Of(u16) = .empty,
    word_held: Of(void) = .empty,
    exact_enums: Of(u8) = .empty,
    text_tables: Of(void) = .empty,

    pub const Decision = std.meta.FieldEnum(Table);

    /// What decision `d` carries for each place it records.
    pub fn Value(comptime d: Decision) type {
        return @FieldType(@FieldType(Table, @tagName(d)).KV, "value");
    }

    pub fn deinit(t: *Table) void {
        inline for (@typeInfo(Table).@"struct".field_names[1..]) |name| @field(t, name).deinit(t.allocator);
    }

    /// Records decision `d` for place `at` of module `module`, with
    /// `value` for a decision that carries one.
    pub fn put(t: *Table, comptime d: Decision, module: u32, at: u32, value: Value(d)) !void {
        try @field(t, @tagName(d)).put(t.allocator, .{ .module = module, .at = at }, value);
    }

    pub fn has(t: *const Table, comptime d: Decision, module: u32, at: u32) bool {
        return @field(t, @tagName(d)).contains(.{ .module = module, .at = at });
    }

    pub fn get(t: *const Table, comptime d: Decision, module: u32, at: u32) ?Value(d) {
        return @field(t, @tagName(d)).get(.{ .module = module, .at = at });
    }
};

/// The program's types: one store every module interns in, and the facts
/// of each type (`sema.TypeInfo`), worked out by the module that interns
/// it first. A module's own types get their final facts once its
/// declarations are resolved (`SemContext.types_start`); every type
/// before them is an earlier module's and final. The graph owns it
/// (`ModuleGraph.types`); a context outside a graph owns its own.
pub const Types = struct {
    store: sema.TypeStore,
    info: std.ArrayList(sema.TypeInfo) = .empty,
    /// The types every store starts with, before any module interns one.
    primitives: TypeId,
    /// The facts of every type in the store are final: a module has
    /// resolved its declarations, and each module after it starts with
    /// the store as it is (`SemContext.types_start`).
    ready: bool = false,
    /// The generic instances checked so far, each by its key
    /// (`sema.InstanceKey`), with what the module that checked it found:
    /// the first module to make an instance checks it, and every later one
    /// leaves it (`sema.checkedBefore`). Kept in `keys`.
    checked: std.StringHashMapUnmanaged(sema.Checked) = .empty,
    keys: std.heap.ArenaAllocator,

    pub fn init(a: std.mem.Allocator) !Types {
        const store = try sema.TypeStore.init(a);
        return .{ .store = store, .primitives = @intCast(store.items.items.len), .keys = .init(a) };
    }

    pub fn deinit(t: *Types, a: std.mem.Allocator) void {
        t.store.deinit(a);
        t.info.deinit(a);
        t.keys.deinit();
    }
};

/// The table of a program not yet decided, which decides nothing.
pub const none: Table = .{ .allocator = std.mem.Allocator.failing };

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
/// Recorded in the program table (`Table.word_held`).
pub fn decideWords(mods: []const modules.Module, t: *Table) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const a = gpa.allocator();
    // Declared sym -> plain, per declaring context.
    var plain: std.AutoHashMapUnmanaged(struct { *const SemContext, SymbolId }, void) = .empty;
    for (mods) |m| try viewsInto(a, m.sema, m.ir, &plain);
    // A word holds the words inside it as bits of its own, so it is held
    // as one only when each of them is.
    var changed = true;
    while (changed) {
        changed = false;
        for (mods) |m| for (m.sema.symbols.items, 0..) |sym, i| {
            const id: SymbolId = @intCast(i);
            if (sema.wordBitsOfSym(m.sema, id) == null or plain.contains(.{ m.sema, id })) continue;
            for (sym.fields orelse &.{}) |f| {
                if (f.is_method or f.is_variant) continue;
                const d = sema.nominalDecl(m.sema, f.ty) orelse continue;
                if (!plain.contains(.{ d.ctx, d.sym })) continue;
                try plain.put(a, .{ m.sema, id }, {});
                changed = true;
                break;
            }
        };
    }
    for (mods) |m| for (m.sema.symbols.items, 0..) |_, i| {
        const sym: SymbolId = @intCast(i);
        if (sema.wordBitsOfSym(m.sema, sym) == null) continue;
        if (plain.contains(.{ m.sema, sym })) continue;
        try t.put(.word_held, m.sema.module_id, sym, {});
    };
}

/// Give each plain enum an `exact` object holds, in a field or a fixed
/// array, in any module, its tag type (`Table.exact_enums`): a Zig
/// `extern struct` holds no enum of an inferred tag, and the tag's bytes
/// are the enum's in the object's layout (`sema.enumBytes`). For the
/// whole program at once, since the enum may be another module's.
pub fn decideExactEnums(mods: []const modules.Module, t: *Table) !void {
    for (mods) |m| for (m.sema.symbols.items) |sym| {
        if (sema.isProxy(sym) or sym.kind != .nominal_type or !sym.flags.exact) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method or f.is_variant or f.is_drop_method) continue;
            try exactEnum(m.sema, f.ty, t);
        }
    };
}

fn exactEnum(ctx: *SemContext, ty: TypeId, t: *Table) !void {
    switch (ctx.types.get(ty)) {
        .array => |arr| return exactEnum(ctx, arr.elem, t),
        .nominal => {},
        else => return,
    }
    if (!sema.isPlainEnum(ctx, ty)) return;
    const d = sema.nominalDecl(ctx, ty) orelse return;
    if (d.symbol().flags.enum_valued or d.symbol().flags.error_set) return;
    const bytes = sema.enumBytes(d.ctx, d.sym) orelse return;
    if (bytes == 0) return;
    // Keyed by the declaring module, which emit reads for the enum.
    try t.put(.exact_enums, d.ctx.module_id, d.sym, @intCast(bytes));
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
