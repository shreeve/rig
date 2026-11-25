//! Typecheck's APIs of a program's own: their declarations and what a
//! type that provides one must have.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const SymbolRef = sema.SymbolRef;
const TypeId = sema.TypeId;
const Field = sema.Field;
const SelfMode = sema.SelfMode;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const tc = @import("../typecheck.zig");
const CompatCheck = @import("compat.zig");

/// This module's APIs, and each conformance it writes: a header that
/// names an API, or an addition. An API builds on others without a
/// cycle and takes their methods as they are; each of its methods says
/// what its result views. A conformance provides every method its API
/// and those it builds on declare, each matching its declaration
/// exactly but for `from` and `keeps`, which may be narrower; meets the
/// built-in APIs they build on; and is the only one of its type and API
/// in the program, written in the type's module or the API's.
pub fn checkApis(ctx: *SemContext) Error!void {
    for (ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and !sema.isProxy(sym)) try checkApiDecl(ctx, @intCast(i));
    }
    for (ctx.conformances.items, 0..) |_, i| try checkConformance(ctx, i);
}

pub fn checkApiDecl(ctx: *SemContext, id: SymbolId) Error!void {
    const a = ctx.arena.allocator();
    const sym = ctx.symbols.items[id];
    const self_ref: sema.ApiRef = .{ .module_id = ctx.module_id, .sym = id };
    for (sym.user_apis) |s| {
        const closure = try sema.apiClosure(ctx, a, s);
        for (closure) |c| if (c.eql(self_ref)) {
            try ctx.err(sym.decl_pos, "`{s}` builds on itself, through `{s}`: an API builds on others without a cycle", .{ sym.name, try sema.apiName(ctx, s) });
            return;
        };
    }
    try recordObjectTable(ctx, id);
    const own = sym.fields orelse &.{};
    // Each associated type is what a provider's methods give where the
    // API's required methods name it (`sema.inferAssoc`), so one names it.
    const params = sym.type_params orelse &.{};
    if (params.len > 1) for (params[1..]) |p| {
        const named = for (own) |m| {
            if (m.is_method and !m.is_default and sema.usesParams(ctx, m.ty, &.{ctx.ref(p)})) break true;
        } else false;
        if (!named) try ctx.err(ctx.symbols.items[p].decl_pos, "`{s}` declares `type {s}`, which none of its required methods names: a provider's `{s}` is what its methods give in their place", .{ sym.name, ctx.symbols.items[p].name, ctx.symbols.items[p].name });
    };
    for (own) |m| {
        // An API takes the methods of those it builds on as they are.
        supers: for (sym.user_apis) |s| for (try sema.apiClosure(ctx, a, s)) |c| {
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            for (csym.fields orelse &.{}) |f| if (std.mem.eql(u8, f.name, m.name)) {
                try ctx.err(m.decl_pos, "`{s}` builds on `{s}`, which declares `{s}`: an API takes the methods of those it builds on as they are, and declares none of them again", .{ sym.name, try sema.apiName(ctx, c), m.name });
                break :supers;
            };
        };
        // A call through the API passes every argument: an implementation
        // has no default to fill, and one of the API's would be a second.
        if (m.has_groups) for (ctx.group_params.get(m.decl_pos) orelse &.{}) |g| if (g) |x| {
            try ctx.err(m.decl_pos, "`{s}.{s}` takes the group `{s}`, and an API's method takes none: a call through the API passes each argument", .{ sym.name, m.name, x.group });
            break;
        };
        for (m.param_defaults orelse &.{}, 0..) |d, i| if (d != null) {
            const pname = if (m.param_names) |ns| (if (i < ns.len) ns[i] else "?") else "?";
            try ctx.err(m.decl_pos, "`{s}.{s}` gives `{s}` a default, and an API's method takes none: a call through the API passes each argument", .{ sym.name, m.name, pname });
            break;
        };
        const f = switch (ctx.types.get(m.ty)) {
            .function => |f| f,
            else => continue,
        };
        if (m.origins.declared or sema.containsPoison(ctx, f.returns)) continue;
        var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
        defer scratch.deinit();
        if ((try sema.viewTargets(ctx, scratch.allocator(), f.returns)).isEmpty()) continue;
        const ret = try sema.formatType(ctx, f.returns);
        try ctx.err(m.decl_pos, "`{s}.{s}` gives `{s}`, which may view what it is passed, and an API's method says what with `from`: `-> {s} from @`", .{ sym.name, m.name, ret, ret });
    }
}

/// The entries of the table of API `id` (`sema.TableEntry`): each method
/// a call through an object of it reaches, its type brought into this
/// module, where emit writes the table (docs/design/apis.md, Stage 4).
pub fn recordObjectTable(ctx: *SemContext, id: SymbolId) Error!void {
    const a = ctx.arena.allocator();
    const ref: sema.ApiRef = .{ .module_id = ctx.module_id, .sym = id };
    var entries: std.ArrayList(sema.TableEntry) = .empty;
    for (try sema.objectMethods(ctx, a, ref)) |m| {
        const slot = m.slot orelse continue;
        const home = sema.apiContext(ctx, m.api) orelse continue;
        const fn_ty = if (home == @as(*const SemContext, ctx)) m.field.ty else try sema.importType(ctx, home, m.field.ty, m.api.module_id);
        if (ctx.types.get(fn_ty) != .function or sema.containsPoison(ctx, fn_ty)) continue;
        // An associated type an entry names is the object's, built with
        // the braces that name it (open question 7).
        const f = ctx.types.get(fn_ty).function;
        const named_param = for (f.params[@min(1, f.params.len)..]) |p| {
            if (sema.containsTypeVar(ctx, p)) break true;
        } else false;
        if (named_param or sema.containsTypeVar(ctx, f.returns)) continue;
        try entries.append(a, .{ .name = m.field.name, .slot = slot, .self_mode = m.field.self_mode, .fn_ty = fn_ty, .result_out = try sema.resultOut(ctx, f.returns) });
    }
    try ctx.object_tables.put(ctx.allocator, id, entries.items);
}

/// An API method a conformance must provide: its field, and the API of
/// the closure that declares it.
pub const ApiMethod = struct { api: sema.ApiRef, home: *const SemContext, field: Field };

pub fn checkConformance(ctx: *SemContext, index: usize) Error!void {
    const a = ctx.arena.allocator();
    const conf = ctx.conformances.items[index];
    const api_sym = sema.apiSymbol(ctx, conf.api) orelse return;
    const api_name = try sema.apiName(ctx, conf.api);
    if (sema.containsPoison(ctx, conf.ty)) return;
    // The type's own symbol, for a type a module declares.
    const decl = sema.nominalDecl(ctx, conf.ty);
    const tname: []const u8 = if (conf.kind == .header) ctx.symbols.items[decl.?.sym].name else try sema.formatType(ctx, conf.ty);
    if (conf.kind == .add and !try checkAddHome(ctx, conf, tname, api_name)) return;
    // Once in the program: a type and an API take one conformance.
    for (ctx.conformances.items[0..index]) |other| {
        if (!try sameProvider(ctx, conf.ty, other.ty)) continue;
        const overlap = if (conf.kind == .header and other.kind == .header) other.api.eql(conf.api) else try buildsOn(ctx, conf.api, other.api) or try buildsOn(ctx, other.api, conf.api);
        if (!overlap) continue;
        try ctx.err(conf.pos, "`{s}` provides `{s}` twice: a type provides an API once in the whole program", .{ tname, api_name });
        try ctx.note(other.pos, "`{s}` provides `{s}` here", .{ tname, try sema.apiName(ctx, other.api) });
        return;
    }
    // The built-in APIs it builds on, which the type's parts give.
    const closure = try sema.apiClosure(ctx, a, conf.api);
    for (closure) |c| {
        const csym = sema.apiSymbol(ctx, c) orelse continue;
        var it = csym.apis.iterator();
        while (it.next()) |b| {
            const lack = (try sema.lacks(ctx, conf.ty, b)) orelse continue;
            // An iterator is one by its `next`, not by its fields.
            const by_field = if (b == .Iter) null else try fieldLacking(ctx, decl, b);
            const detail = by_field orelse try sema.lackDetail(ctx, a, conf.ty, b, lack);
            const shown = if (std.mem.startsWith(u8, detail, "; ")) try a.print(": {s}", .{detail[2..]}) else detail;
            try ctx.err(conf.pos, "`{s}` provides `{s}`, which builds on `{s}`, but `{s}` {s}{s}", .{ tname, api_name, @tagName(b), tname, sema.cannotDo(b), shown });
            return;
        }
    }
    // Every method of the API and those it builds on.
    var wanted: std.ArrayList(ApiMethod) = .empty;
    for (closure) |c| {
        const home = sema.apiContext(ctx, c) orelse continue;
        const csym = sema.apiSymbol(ctx, c) orelse continue;
        for (csym.fields orelse &.{}) |f| try wanted.append(a, .{ .api = c, .home = home, .field = f });
    }
    const provider = providerMethods(conf, decl);
    // An addition's methods are its APIs', and none its type has already.
    if (conf.kind == .add) for (conf.methods) |m| {
        const declared = for (wanted.items) |w| {
            if (std.mem.eql(u8, w.field.name, m.name)) break true;
        } else false;
        if (!declared and !try anotherApiDeclares(ctx, conf, m.name)) try ctx.err(m.decl_pos, "`add {s}: {s}` declares `{s}`, which `{s}` does not: an addition's methods are its API's", .{ tname, api_name, m.name, api_name });
        const has = if (decl) |d| typeHasMethod(d.symbol(), m.name) else false;
        if (declared and (has or builtinMember(ctx, conf.ty, m.name))) {
            try ctx.err(m.decl_pos, "`add {s}: {s}` declares `{s}`, which `{s}` has already: an addition neither adopts nor replaces a method of its type", .{ tname, api_name, m.name, tname });
        }
    };
    var members: std.ArrayList(sema.WitnessMember) = .empty;
    defer ctx.conformances.items[index].members = members.items;
    for (wanted.items, 0..) |w, wi| {
        // Each name once, by the first API that declares it.
        const first = for (wanted.items[0..wi]) |e| {
            if (std.mem.eql(u8, e.field.name, w.field.name)) break false;
        } else true;
        if (!first) continue;
        const have = findMethod(provider, w.field.name) orelse {
            if (w.field.is_default) {
                try members.append(a, .{ .name = w.field.name, .from = .{ .default = w.api } });
                // Two defaults for one name, until the type writes it: from
                // the APIs this one builds on, or another API the type
                // provides.
                const other: ?sema.ApiRef = for (wanted.items[wi + 1 ..]) |e| {
                    if (std.mem.eql(u8, e.field.name, w.field.name) and e.field.is_default and !e.api.eql(w.api)) break e.api;
                } else try laterDefault(ctx, index, w.field.name, w.api);
                if (other) |o| try ctx.err(conf.pos, "`{s}` provides `{s}` and `{s}`, which both give `{s}` a default: declare `{s}` in `{s}` to choose", .{ tname, try sema.apiName(ctx, w.api), try sema.apiName(ctx, o), w.field.name, w.field.name, tname });
                continue;
            }
            try ctx.err(conf.pos, "`{s}` provides `{s}` but has no method `{s}`; declare `{s}` in `{s}`", .{ tname, api_name, w.field.name, headerText(w.home.source, w.field.decl_pos), if (conf.kind == .add) try a.print("add {s}: {s}", .{ tname, api_name }) else tname });
            continue;
        };
        try members.append(a, .{ .name = w.field.name, .from = if (conf.kind == .add) .added else .own });
        // A method under bounds the header does not state meets no API on
        // it: only an addition under those bounds gives the API.
        if (conf.kind == .header and have.owner_bounds.len > 0) {
            const tsym = ctx.symbols.items[decl.?.sym];
            const tparams = tsym.type_params orelse &.{};
            var names: std.ArrayList(u8) = .empty;
            for (tparams, 0..) |p, i| try names.print(a, "{s}{s}", .{ if (i > 0) ", " else "", ctx.symbols.items[p].name });
            const under = try sema.ownerBoundsText(ctx, ctx, a, tparams, have.owner_bounds);
            try ctx.err(have.decl_pos, "`{s}.{s}` is declared under `{s}`, which `{s}[{s}]: {s}` does not state: a conformance is met only by methods its own bounds imply; take `{s}` off the header and write `add {s}[{s}]: {s}`, which declares `{s}`", .{ tname, have.name, under, tname, names.items, api_name, api_name, tname, try boundParamsText(ctx, a, tparams, have.owner_bounds), api_name, have.name });
            continue;
        }
        try checkMethodMeets(ctx, conf, tname, w, have);
        // A call through the API gives each argument by position, so a
        // method that meets it has no option (SPEC "Functions"); the API's
        // own method has none either (`checkApiDecl`).
        if (have.has_groups) for (ctx.group_params.get(have.decl_pos) orelse &.{}) |g| if (g) |x| {
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}` of `{s}`, so it takes no group, and it takes `{s}`: a call through the API gives each argument by position", .{ tname, have.name, w.field.name, try sema.apiName(ctx, w.api), x.group });
            break;
        };
        for (have.param_defaults orelse &.{}, 0..) |d, i| if (d != null) {
            const pname = if (have.param_names) |ns| (if (i < ns.len) ns[i] else "?") else "?";
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}` of `{s}`, so `{s}` has no default: a call through the API gives each argument by position", .{ tname, have.name, w.field.name, try sema.apiName(ctx, w.api), pname });
            break;
        };
        // A method that meets a `pub` API on a `pub` type is `pub`.
        if (conf.kind == .header and api_sym.flags.is_public and ctx.symbols.items[decl.?.sym].flags.is_public and !have.is_pub) {
            try ctx.err(have.decl_pos, "`{s}.{s}` meets `{s}`, a `pub` API, on `{s}`, a `pub` type, so it is `pub`: write `pub {s}`", .{ tname, have.name, api_name, tname, headerText(ctx.source, have.decl_pos) });
        }
    }
}

/// A generic type's parameters with the bounds a method adds written in:
/// `T: Print, U`.
pub fn boundParamsText(ctx: *SemContext, a: std.mem.Allocator, tparams: []const SymbolId, bounds: []const sema.OwnerBound) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (tparams, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        const b = for (bounds) |b| {
            if (b.param == i) break b;
        } else null;
        if (b) |one| {
            try out.appendSlice(a, try sema.ownerBoundsText(ctx, ctx, a, tparams, &.{one}));
        } else try out.appendSlice(a, ctx.symbols.items[p].name);
    }
    return out.items;
}

/// An API other than `api` that a later conformance of the same type
/// gives a default method `name`, which the type does not write.
pub fn laterDefault(ctx: *SemContext, index: usize, name: []const u8, api: sema.ApiRef) Error!?sema.ApiRef {
    const conf = ctx.conformances.items[index];
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (ctx.conformances.items[index + 1 ..]) |o| {
        if (!try sameProvider(ctx, conf.ty, o.ty)) continue;
        for (try sema.apiClosure(ctx, scratch.allocator(), o.api)) |c| {
            if (c.eql(api)) continue;
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            const f = findMethod(csym.fields orelse &.{}, name) orelse continue;
            if (f.is_default) return c;
        }
    }
    return null;
}

/// Why a value of `ty`, which holds a task (`sema.holdsTask`), holds
/// one: its first field that does (`taskField`), or "a `T` holds one".
pub fn taskWhy(ctx: *SemContext, ty: TypeId) Error![]const u8 {
    if (taskField(ctx, sema.nominalDecl(ctx, ty))) |f| return f;
    return ctx.arena.allocator().print("a `{s}` holds one", .{try sema.formatType(ctx, ty)});
}

/// The first field or payload of `decl` that holds a task (`sema.holdsTask`),
/// as `its field `t` is a `Task[Int]``; null when none of its own does.
pub fn taskField(ctx: *SemContext, decl: ?sema.NominalDecl) ?[]const u8 {
    const d = decl orelse return null;
    if (d.ctx != @as(*const SemContext, ctx)) return null;
    for (d.symbol().fields orelse &.{}) |*f| {
        for (sema.dataFields(f)) |df| {
            if (!sema.holdsTask(ctx, df.ty)) continue;
            return ctx.arena.allocator().print("its {s} `{s}` is a `{s}`", .{ if (f.is_variant) "payload" else "field", df.name, sema.formatType(ctx, df.ty) catch return null }) catch null;
        }
    }
    return null;
}

/// The first field of the object `decl` whose type lacks `api`, as the
/// end of an error says it: `; its field `cache` is a `*Cell[Int]``.
pub fn fieldLacking(ctx: *SemContext, decl: ?sema.NominalDecl, api: sema.Api) Error!?[]const u8 {
    const d = decl orelse return null;
    if (d.ctx != @as(*const SemContext, ctx)) return null;
    for (d.symbol().fields orelse &.{}) |f| {
        if (f.is_method or f.is_variant) continue;
        if (try sema.lacks(ctx, f.ty, api) == null) continue;
        return try ctx.arena.allocator().print("; its field `{s}` is a `{s}`", .{ f.name, try sema.formatType(ctx, f.ty) });
    }
    return null;
}

/// Whether another API of the addition that writes `conf` (`add Int:
/// Shape + Named`), or one it builds on, declares a method `name`.
pub fn anotherApiDeclares(ctx: *SemContext, conf: sema.Conformance, name: []const u8) Error!bool {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (ctx.conformances.items) |o| {
        if (o.kind != .add or o.pos != conf.pos or o.api.eql(conf.api)) continue;
        for (try sema.apiClosure(ctx, scratch.allocator(), o.api)) |c| {
            const csym = sema.apiSymbol(ctx, c) orelse continue;
            if (findMethod(csym.fields orelse &.{}, name) != null) return true;
        }
    }
    return false;
}

/// The methods a conformance provides its API by: an addition's own, or
/// the type's.
pub fn providerMethods(conf: sema.Conformance, decl: ?sema.NominalDecl) []const Field {
    if (conf.kind == .add) return conf.methods;
    return (decl orelse return &.{}).symbol().fields orelse &.{};
}

pub fn findMethod(fields: []const Field, name: []const u8) ?Field {
    for (fields) |f| if (f.is_method and !f.is_drop_method and std.mem.eql(u8, f.name, name)) return f;
    return null;
}

pub fn typeHasMethod(sym: sema.Symbol, name: []const u8) bool {
    return findMethod(sym.fields orelse &.{}, name) != null;
}

/// Whether built-in type `ty` has a member `name` no declaration holds:
/// the `len` and `is_empty` of text, an array, a slice, or a List, a
/// String's `add`, `push`, `reserve`, and `clear`, a `Symbol`'s `text`.
pub fn builtinMember(ctx: *SemContext, ty: TypeId, name: []const u8) bool {
    const t = ctx.types.get(ty);
    const has_len = switch (t) {
        .array, .slice, .string_view, .static, .string => true,
        .parameterized_nominal => CompatCheck.listElementType(ctx, ty) != null or CompatCheck.cellListElement(ctx, ty) != null,
        else => false,
    };
    if (has_len and (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "is_empty"))) return true;
    if (t == .string) if (std.meta.stringToEnum(sema.StringCall, name)) |op| switch (op) {
        .add, .push, .reserve, .clear => return true,
        else => {},
    };
    return t == .symbol and std.mem.eql(u8, name, "text");
}

/// Whether API `a` is `b` or builds on it.
pub fn buildsOn(ctx: *SemContext, x: sema.ApiRef, y: sema.ApiRef) Error!bool {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (try sema.apiClosure(ctx, scratch.allocator(), x)) |c| if (c.eql(y)) return true;
    return false;
}

/// Whether `x` and `y`, types of this module's conformances, are one
/// type constructor: one conformance covers both.
pub fn sameProvider(ctx: *SemContext, x: TypeId, y: TypeId) Error!bool {
    if (x == y) return true;
    const gx = genericSym(ctx, x) orelse return false;
    const gy = genericSym(ctx, y) orelse return false;
    return gx == gy;
}

pub fn genericSym(ctx: *const SemContext, ty: TypeId) ?sema.SymbolRef {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym,
        // Every `Slot[n]` is one type constructor's.
        .slot => ctx.builtins.slot,
        else => null,
    };
}

/// An addition is written in the module of its API or of its type, and
/// in the type's own module only under a bound (`add Wrap[T: Shape]`);
/// there a header says the rest. False after a diagnostic.
pub fn checkAddHome(ctx: *SemContext, conf: sema.Conformance, tname: []const u8, api_name: []const u8) Error!bool {
    const own_type = switch (ctx.types.get(conf.ty)) {
        .nominal => |s| ctx.owns(s) and !sema.isProxy(ctx.symbols.items[s.sym]) and ctx.symbols.items[s.sym].decl_pos != sema.builtin_decl_pos,
        .parameterized_nominal => |pn| !sema.isProxy(sema.symbolAt(ctx, pn.sym).*) and sema.symbolAt(ctx, pn.sym).decl_pos != sema.builtin_decl_pos,
        else => false,
    };
    if (own_type) {
        const conditional = for (conf.params) |p| {
            if (sema.hasBounds(ctx.symbols.items[p])) break true;
        } else false;
        if (conditional) return true;
        const decl = sema.nominalDecl(ctx, conf.ty).?.symbol();
        const is_enum = for (decl.fields orelse &.{}) |f| {
            if (f.is_variant) break true;
        } else false;
        const params: []const u8 = if (genericSym(ctx, conf.ty) != null) try ctx.arena.allocator().print("[{s}]", .{tparamNames(ctx, decl)}) else "";
        try ctx.err(conf.pos, "`{s}` is declared in this module, so it names `{s}` on its header: `{s} {s}{s}: {s}`; `add` is for a type of another module, a built-in type, or an API a type provides only under a bound", .{ decl.name, api_name, if (is_enum) "enum" else "obj", decl.name, params, api_name });
        return false;
    }
    if (conf.api.module_id != ctx.module_id) {
        try ctx.err(conf.pos, "`add {s}: {s}` is written in the module that declares `{s}`, or the one that declares `{s}`", .{ tname, api_name, api_name, tname });
        return false;
    }
    // It provides the APIs its API builds on too, each of which it may
    // provide only here as well: elsewhere two modules could each give
    // the type one, neither seeing the other.
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (try sema.apiClosure(ctx, scratch.allocator(), conf.api)) |c| {
        if (c.module_id == ctx.module_id) continue;
        const cname = try sema.apiName(ctx, c);
        try ctx.err(conf.pos, "`add {s}: {s}` gives `{s}` `{s}` too, which `{s}` builds on, outside the module of `{s}` and of `{s}`: a type provides an API once in the whole program, in its own module or the API's", .{ tname, api_name, tname, cname, api_name, cname, tname });
        return false;
    }
    return true;
}

pub fn tparamNames(ctx: *SemContext, sym: sema.Symbol) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = ctx.arena.allocator();
    for (sym.type_params orelse &.{}, 0..) |tp, i| {
        if (i > 0) out.appendSlice(a, ", ") catch return "T";
        out.appendSlice(a, ctx.symbols.items[tp].name) catch return "T";
    }
    return out.items;
}

/// The header of the method whose name is at `pos` in `source`, as
/// written: `fun area(?@) -> Float`, without its comment.
pub fn headerText(source: []const u8, pos: u32) []const u8 {
    const start = (std.mem.findScalarLast(u8, source[0..pos], '\n') orelse 0);
    const end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;
    var line = source[start..end];
    if (std.mem.findScalar(u8, line, '#')) |h| line = line[0..h];
    line = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.startsWith(u8, line, "pub ")) line = line[4..];
    return line;
}

/// The method's name, parameters, and result, as its header writes them:
/// `size(?@) -> Int!Bad`; `with_result` false stops after the
/// parameters, `next(!@)`.
pub fn signatureText(source: []const u8, pos: u32, with_result: bool) []const u8 {
    const header = headerText(source, pos);
    const name_at = @intFromPtr(source.ptr + pos) -| @intFromPtr(header.ptr);
    if (name_at >= header.len) return header;
    const sig = header[name_at..];
    if (!with_result) {
        var depth: usize = 0;
        for (sig, 0..) |c, i| switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -|= 1;
                if (depth == 0) return sig[0 .. i + 1];
            },
            else => {},
        };
        return sig;
    }
    return clauseless(sig);
}

/// `text` without its `from` and `keeps` clauses.
pub fn clauseless(text: []const u8) []const u8 {
    var end = text.len;
    for ([_][]const u8{ " from ", " keeps " }) |w| if (std.mem.find(u8, text, w)) |i| {
        end = @min(end, i);
    };
    return std.mem.trimEnd(u8, text[0..end], " ");
}

/// The result the header of the method at `pos` writes: `-> Int!Bad`.
pub fn resultText(source: []const u8, pos: u32) []const u8 {
    const sig = signatureText(source, pos, true);
    var depth: usize = 0;
    for (sig, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        '-' => if (depth == 0 and i + 1 < sig.len and sig[i + 1] == '>') return sig[i..],
        else => {},
    };
    return "";
}

/// The method `have` meets the API method `w` (of a conformance of
/// `tname`): the same self, parameters and their modes, compile-time
/// parameters, `once`, and result, its failure included; its `from`
/// and `keeps` within the API's, by position.
pub fn checkMethodMeets(ctx: *SemContext, conf: sema.Conformance, tname: []const u8, w: ApiMethod, have: Field) Error!void {
    const a = ctx.arena.allocator();
    const owner = try a.print("{s}.{s}", .{ tname, have.name });
    const aname = try sema.apiName(ctx, w.api);
    const src = w.home.source;
    const pos = w.field.decl_pos;
    const header = headerText(src, pos);
    if (have.self_mode != w.field.self_mode) {
        try ctx.err(have.decl_pos, "`{s}` takes `self` as `{s}`, but `{s}` declares `{s}`; a method meets its API with the same self: write `{s}`", .{ owner, selfSigil(have.self_mode), aname, signatureText(src, pos, false), header });
        return;
    }
    const want_ty = try apiMethodType(ctx, w, conf, have) orelse return;
    const want = ctx.types.get(want_ty).function;
    const got = switch (ctx.types.get(have.ty)) {
        .function => |f| f,
        else => return,
    };
    if (sema.containsPoison(ctx, have.ty) or sema.containsPoison(ctx, want_ty)) return;
    if (want.ct_params.len != got.ct_params.len) {
        try ctx.err(have.decl_pos, "`{s}` takes {d} compile-time parameter{s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, got.ct_params.len, CompatCheck.plural(got.ct_params.len), aname, signatureText(src, pos, true), header });
        return;
    }
    // Each the same kind, of the same type, with the same bounds: a call
    // through the API passes what its brackets promise.
    const api_ct_syms = switch (w.home.types.get(w.field.ty)) {
        .function => |f| f.ct_syms,
        else => &.{},
    };
    for (want.ct_params, got.ct_params, 0..) |wc, gc, i| {
        const gsym: ?sema.Symbol = if (i < got.ct_syms.len and got.ct_syms[i].sym != sema.symbol_invalid) sema.symbolAt(ctx, got.ct_syms[i]).* else null;
        const gname = if (gsym) |s| s.name else "?";
        if (wc != gc) {
            const as: []const u8 = if (ctx.types.get(gc) == .type_var) "a type" else try a.print("`{s}`", .{try sema.formatType(ctx, gc)});
            try ctx.err(have.decl_pos, "`{s}` takes `{s}` as {s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, gname, as, aname, signatureText(src, pos, true), header });
            return;
        }
        if (ctx.types.get(gc) != .type_var or i >= api_ct_syms.len or api_ct_syms[i].sym == sema.symbol_invalid) continue;
        const g = gsym orelse continue;
        if (try sameBounds(w.home, sema.symbolAt(w.home, api_ct_syms[i]).*, ctx, g)) continue;
        const written = try sema.formatBounds(ctx, a, g, null);
        const by: []const u8 = if (written.len == 0) "nothing" else try a.print("`{s}`", .{written});
        try ctx.err(have.decl_pos, "`{s}` bounds `{s}` by {s}, but `{s}` declares `{s}`; a method meets its API with the same compile-time parameters: write `{s}`", .{ owner, gname, by, aname, signatureText(src, pos, true), header });
        return;
    }
    if (want.params.len != got.params.len) {
        try ctx.err(have.decl_pos, "`{s}` takes {d} parameter{s}, but `{s}` declares `{s}`; a method meets its API with the same parameters: write `{s}`", .{ owner, got.params.len - 1, CompatCheck.plural(got.params.len - 1), aname, signatureText(src, pos, false), header });
        return;
    }
    const names = have.param_names orelse &.{};
    for (want.params[1..], got.params[1..], 1..) |wp, gp, i| {
        if (wp == gp) continue;
        try ctx.err(have.decl_pos, "`{s}` takes `{s}` as `{s}`, but `{s}` declares `{s}`; a method meets its API with the same parameters: write `{s}`", .{ owner, if (i < names.len) names[i] else "?", try sema.formatType(ctx, gp), aname, signatureText(src, pos, false), header });
        return;
    }
    // The same names: a call through the API passes its arguments by the
    // API's names, which are the implementation's. A parameter its body
    // ignores may be `_`, as in any function (SPEC "Functions").
    const api_names = w.field.param_names orelse &.{};
    for (names, 0..) |n, i| {
        if (i == 0 or i >= api_names.len or std.mem.eql(u8, n, api_names[i])) continue;
        if (std.mem.eql(u8, n, "_") or std.mem.eql(u8, api_names[i], "_")) continue;
        try ctx.err(have.decl_pos, "`{s}` names its parameter `{s}` where `{s}` declares `{s}`; a method meets its API with the same names: write `{s}`", .{ owner, n, aname, api_names[i], header });
        return;
    }
    if (want.returns != got.returns) {
        const fails = ctx.types.get(want.returns) == .fallible or ctx.types.get(got.returns) == .fallible;
        const same_ok = sema.okOf(ctx, want.returns) == sema.okOf(ctx, got.returns);
        const got_shown = try sema.formatType(ctx, got.returns);
        const verb: []const u8 = if (ctx.types.get(got.returns) == .fallible) "fails with" else "gives";
        const what: []const u8 = if (fails and same_ok) "set" else "result";
        const result = resultText(src, pos);
        if (result.len == 0) {
            try ctx.err(have.decl_pos, "`{s}` {s} `{s}`, but `{s}` declares `{s}`, which gives nothing; a method meets its API with the same result: write `{s}`", .{ owner, verb, got_shown, aname, signatureText(src, pos, true), header });
        } else try ctx.err(have.decl_pos, "`{s}` {s} `{s}`, but `{s}` declares `{s}`; a method meets its API with the same {s}: write `{s}`", .{ owner, verb, got_shown, aname, signatureText(src, pos, true), what, result });
        return;
    }
    if (have.origins.once != w.field.origins.once) {
        const at = @ctz(have.origins.once ^ w.field.origins.once);
        const pname = if (at < names.len) names[at] else "?";
        try ctx.err(have.decl_pos, "`{s}` takes `{s}` {s} `once`, but `{s}` declares `{s}`; a method meets its API with the same `once`: write `{s}`", .{ owner, pname, if (have.origins.once & sema.paramBit(at) != 0) "with" else "without", aname, signatureText(src, pos, false), header });
        return;
    }
    // `keeps` and `from` may be narrower, never wider: a call through
    // the API keeps and views what the API says.
    const kept = have.origins.stores & have.origins.viewed;
    const api_kept = w.field.origins.stores & w.field.origins.viewed;
    if (kept & ~api_kept != 0) {
        const extra = kept & ~api_kept;
        const first = @ctz(extra);
        const pname = if (first < names.len) names[first] else "?";
        try ctx.err(have.decl_pos, "`{s}` keeps {s}, but `{s}.{s}` keeps {s}: a call through `{s}` would leave `{s}` free while `{s}` still views it; add `keeps {s}` to `{s}.{s}`", .{ owner, try maskNames(a, names, extra), aname, w.field.name, try maskNames(a, api_names, api_kept), aname, pname, tname, if (first < api_names.len) api_names[first] else pname, aname, w.field.name });
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    if ((try sema.viewTargets(ctx, scratch.allocator(), got.returns)).isEmpty()) return;
    const viewed = have.origins.result & ~w.field.origins.result & CompatCheck.paramsMask(got.params.len);
    if (viewed != 0) {
        const first = @ctz(viewed);
        const pname = if (first < names.len) names[first] else "?";
        const fix = if (have.origins.declared)
            try a.print("add `{s}` to the `from` of `{s}.{s}`", .{ pname, aname, w.field.name })
        else
            try a.print("write `from {s}` on `{s}`", .{ try maskList(a, api_names, w.field.origins.result & CompatCheck.paramsMask(got.params.len)), owner });
        try ctx.err(have.decl_pos, "`{s}` may give a view of `{s}`, but `{s}.{s}` does not: a call through `{s}` would leave `{s}` free while the result still views it; {s}", .{ owner, pname, aname, w.field.name, aname, pname, fix });
    }
}

/// Whether type parameters `x` (of module `xc`) and `y` (of `yc`) are
/// bounded alike: the same built-in APIs and the same of a program's own,
/// with what each implies and builds on (`[K: Hash]` is `[K: Hash +
/// Eq]`).
pub fn sameBounds(xc: *const SemContext, x: sema.Symbol, yc: *const SemContext, y: sema.Symbol) Error!bool {
    if (!sema.boundApis(xc, x).eql(sema.boundApis(yc, y))) return false;
    var scratch = std.heap.ArenaAllocator.init(xc.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var xs: std.ArrayList(sema.ApiRef) = .empty;
    var ys: std.ArrayList(sema.ApiRef) = .empty;
    for (x.user_apis) |r| try xs.appendSlice(a, try sema.apiClosure(xc, a, r));
    for (y.user_apis) |r| try ys.appendSlice(a, try sema.apiClosure(yc, a, r));
    for ([_][2][]const sema.ApiRef{ .{ xs.items, ys.items }, .{ ys.items, xs.items } }) |pair| {
        for (pair[0]) |r| {
            const found = for (pair[1]) |o| {
                if (o.eql(r)) break true;
            } else false;
            if (!found) return false;
        }
    }
    return true;
}

pub fn selfSigil(r: sema.SelfMode) []const u8 {
    return switch (r) {
        .read => "?@",
        .write => "!@",
        .value => "<@",
        .none => "nothing",
    };
}

/// The parameters `mask` names, as an error lists them: `` `s` ``,
/// `` `s`, `t` ``, or `nothing`.
pub fn maskNames(a: std.mem.Allocator, names: []const []const u8, mask: sema.ParamMask) Error![]const u8 {
    if (mask == 0) return "nothing";
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i >= 64 or mask & sema.paramBit(i) == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.print(a, "`{s}`", .{n});
    }
    return out.items;
}

/// The parameters `mask` names, joined for a `from` clause: `@, a`.
pub fn maskList(a: std.mem.Allocator, names: []const []const u8, mask: sema.ParamMask) Error![]const u8 {
    if (mask == 0) return "static";
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i >= 64 or mask & sema.paramBit(i) == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

/// The type the API method `w` gives a conformance's method, in this
/// module's types: `Self` is the conformance's type, and each of the
/// API method's compile-time parameters the method's own (`have`), in
/// order. Null when the two take different numbers of them, which the
/// caller reports.
pub fn apiMethodType(ctx: *SemContext, w: ApiMethod, conf: sema.Conformance, have: Field) Error!?TypeId {
    const local_ty = if (w.home == @as(*const SemContext, ctx)) w.field.ty else try sema.importType(ctx, w.home, w.field.ty, w.api.module_id);
    const f = switch (ctx.types.get(local_ty)) {
        .function => |f| f,
        else => return null,
    };
    const got = switch (ctx.types.get(have.ty)) {
        .function => |g| g,
        else => return null,
    };
    const api_sym = sema.apiSymbol(ctx, w.api) orelse return null;
    const home_self = (api_sym.type_params orelse return null)[0];
    const self_param = if (w.home == @as(*const SemContext, ctx)) home_self else try sema.proxyOf(ctx, .{ .module_id = w.api.module_id, .sym = home_self });
    var params: std.ArrayList(SymbolRef) = .empty;
    var args: std.ArrayList(TypeId) = .empty;
    const a = ctx.arena.allocator();
    try params.append(a, ctx.ref(self_param));
    try args.append(a, conf.ty);
    if (f.ct_syms.len == got.ct_syms.len) for (f.ct_syms, got.ct_syms, 0..) |p, g, i| {
        if (p.sym == sema.symbol_invalid or g.sym == sema.symbol_invalid) continue;
        try params.append(a, p);
        const is_type = ctx.types.get(got.ct_params[i]) == .type_var;
        try args.append(a, try ctx.intern(if (is_type) .{ .type_var = g } else .{ .ct_param = g }));
    };
    return try sema.substituteType(ctx, local_ty, .{ .params = params.items, .args = args.items });
}

/// Why `==` is not defined for a type, as a diagnostic says it.
pub fn notEquatableReason(ctx: *SemContext, n: sema.NotEquatable) Error![]const u8 {
    const a = ctx.arena.allocator();
    const t = try sema.formatType(ctx, n.ty);
    if (n.path.len > 0) return switch (n.why) {
        .handle => a.print("field `{s}` is a handle `{s}`, which could compare by identity or by content", .{ n.path, t }),
        .closure => a.print("field `{s}` is an owned closure `{s}`", .{ n.path, t }),
        .function => a.print("field `{s}` is a function value", .{n.path}),
        .no_eq => a.print("field `{s}` is a `{s}`, which has no `==`", .{ n.path, t }),
        .view => a.print("field `{s}` holds a `?T`, `!T`, or slice", .{n.path}),
        .drop => a.print("field `{s}` is a `{s}`: `{s}` declares `drop`", .{ n.path, t, t }),
        .unique => a.print("field `{s}` is a `{s}`, which is unique", .{ n.path, t }),
        .lanes => a.print("field `{s}` is a `{s}`, whose `==` compares lane by lane; compare the fields and reduce the mask: `(x.{s} == y.{s}).all()`", .{ n.path, t, n.path, n.path }),
        .float => a.print("field `{s}` is a `{s}`, and `==` calls `0.0` and `-0.0` equal and NaN equal to nothing", .{ n.path, t }),
        .own_eq => a.print("field `{s}` is a `{s}`, which declares its own `==` and no hash of its own", .{ n.path, t }),
        .object => a.print("field `{s}` is a `{s}`, and two API objects may hide two types, which `==` cannot compare", .{ n.path, t }),
    };
    return switch (n.why) {
        .handle => a.print("`{s}` is a handle, which could compare by identity or by content", .{t}),
        .closure => a.print("`{s}` is an owned closure", .{t}),
        .function => a.print("`{s}` is a function value", .{t}),
        .no_eq => a.print("`{s}` has no `==`", .{t}),
        .view => a.print("`{s}` is a view", .{t}),
        .drop => a.print("`{s}` declares `drop`", .{t}),
        .unique => a.print("`{s}` is unique", .{t}),
        .lanes => a.print("`{s}` holds a vector, whose `==` compares lane by lane", .{t}),
        .float => a.print("`==` calls `0.0` and `-0.0` equal and NaN equal to nothing; hash its bits, `x.to_bits().hash()`", .{}),
        .own_eq => sema.ownEqUnhashed(ctx, n.ty),
        .object => a.print("two API objects may hide two types, which `==` cannot compare", .{}),
    };
}

pub fn satisfies(ctx: *SemContext, ty: TypeId, req: Requirement) Error!bool {
    return switch (req) {
        .numeric, .bytes => sema.isNumeric(ctx, ty),
        .records => switch (try sema.bytesRecord(ctx, ty)) {
            // A generic body's bytes are not an embedded file's, known
            // where the call is written, so every bit pattern is a value.
            .record => |r| r.checks.len == 0,
            .not => false,
        },
        .ordered => sema.isNumeric(ctx, ty) or ctx.types.get(ty) == .string_view or ctx.types.get(ty) == .static or sema.isOrderedEnum(ctx, ty) or (try sema.lacks(ctx, ty, .Ord)) == null,
        .integer => sema.isInteger(ctx, ty),
        .signed => switch (ctx.types.get(ty)) {
            .int => |info| info.signed,
            .float => true,
            else => false,
        },
        .float => ctx.types.get(ty) == .float,
        .fits => |v| sema.isNumeric(ctx, ty) and CompatCheck.holdsInt(ctx, ty, v),
        .shift => |v| switch (ctx.types.get(ty)) {
            .int => |info| v < info.width(),
            else => false,
        },
        .copies => sema.copies(ctx, ty) != .no,
        .clones => (try sema.lacks(ctx, ty, .Clone)) == null,
        .no_cleanup => !sema.typeHasDropGlue(ctx, ty),
        .lane_count => switch (ctx.types.get(ty)) {
            .ct_value => |v| sema.lanesInRange(v.int),
            else => false,
        },
        .slot_count => sema.slotCount(ctx, ty) != null,
        .sized => !sema.holdsVector(ctx, ty),
        .array_len => switch (ctx.types.get(ty)) {
            .ct_value => |v| v.int >= 0 and v.int <= sema.max_array_len,
            else => false,
        },
        .equatable => sema.isEquatable(ctx, ty),
        .hashable => CompatCheck.isText(ctx, ty) or (try sema.notHashable(ctx, ty, null)) == null,
        .whole_division => sema.isInteger(ctx, ty),
        // An API object prints only by the `Print` its braces or API name.
        .printable => try sema.printable(ctx, ty) and try sema.objectUnprinted(ctx, ty) == null,
        .not_error => ctx.types.get(ty) != .any_error and !sema.isErrorSet(ctx, ty),
        .error_set => sema.isErrorValue(ctx, ty),
        .not_function => ctx.types.get(ty) != .function,
        .named => sema.unnameable(ctx, ty) == null,
        .frozen => (try sema.frozenBlocker(ctx, ty)) == null,
        .no_task => !sema.holdsTask(ctx, ty),
        .task => |reach| (try sema.taskBlocker(ctx, ty, reach)) == null,
        .meets => |api| (try sema.lacks(ctx, ty, api)) == null,
        .order => (try sema.lacks(ctx, ty, .Ord)) == null,
    };
}
