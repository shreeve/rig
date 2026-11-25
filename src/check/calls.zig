//! Typecheck's calls: callees, arguments, compile-time arguments,
//! inference, instantiation, and method lookup.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema.zig");
const Wide = sema.Wide;
const resolve = @import("../resolve.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const FunctionType = sema.FunctionType;
const SelfMode = sema.SelfMode;
const TypeSubst = sema.TypeSubst;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CompatCheck = @import("compat.zig");
const GenericCheck = @import("generics.zig");
const BuiltinCheck = @import("builtins.zig");
const ClosureCheck = @import("closures.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// `module.Byte`: an imported alias of a number type.
pub fn importedNumberAlias(self: *Checker, obj: Sexp) Error!?TypeId {
    const module_sym = (try moduleNamed(self, ir.Member.object(obj))) orelse return null;
    const name = ir.Member.name(obj);
    const found = foreignLookup(self, module_sym, self.text(name)) orelse return null;
    if (found.sym.kind != .type_alias or !sema.isNumeric(found.ctx, found.sym.ty)) return null;
    _ = (try foreignSymbol(self, module_sym, self.text(name), name.src.pos)) orelse return self.t().invalid_id;
    return try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
}

/// A field or method reached through weak handle `obj`, which does not
/// keep its value alive: `*w` upgrades it. A box or a counted handle
/// holds no weak handle (`sema.heapStacked`), so `obj` is the weak
/// handle or a view of one.
pub fn weakReach(self: *Checker, obj: Sexp, weak: TypeId, pos: u32) Error!void {
    const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(obj));
    try self.err(pos, "a weak handle `{s}` reaches its value only once upgraded with `*{s}`: `if *{s} as s`", .{ try self.tyName(weak), shown, shown });
}

/// Member `e` of `obj`, a value of type `obj_ty`.
pub fn memberOf(self: *Checker, e: Sexp, obj: Sexp, obj_ty: TypeId) Error!TypeId {
    const field_node = ir.Member.name(e);
    const field = self.text(field_node);
    const pos = srcPos(field_node, self.startOf(obj));
    if (self.isPoison(obj_ty)) return obj_ty;
    const peeled = sema.unwrapAccess(self.ctx, obj_ty);

    switch (self.ctx.types.get(peeled)) {
        .optional => {
            try self.err(pos, "cannot access `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ field, try self.tyName(peeled) });
            return self.t().invalid_id;
        },
        .array, .slice, .string_view, .static, .string => if (std.mem.eql(u8, field, "len")) return self.t().int_id,
        .parameterized_nominal => if ((CompatCheck.listElementType(self.ctx, peeled) != null or sema.tableElem(self.ctx, peeled) != null or CompatCheck.cellListElement(self.ctx, peeled) != null or sema.isTaskSet(self.ctx, peeled)) and std.mem.eql(u8, field, "len")) return self.t().int_id,
        .type_var => {
            try self.err(pos, "a generic parameter `{s}` has no fields; generic bodies can only move, copy, and compare `{s}` values", .{ try self.tyName(peeled), try self.tyName(peeled) });
            return self.t().invalid_id;
        },
        else => {},
    }

    // `s.text`: a symbol's name, its one member.
    if (peeled == self.t().symbol_id) {
        if (std.mem.eql(u8, field, "text")) {
            try self.ctx.record(.enum_texts, e, {});
            return self.t().static_id;
        }
        try self.err(pos, "a `Symbol` has no field `{s}`; its one member is its name, `.text`", .{field});
        return self.t().invalid_id;
    }
    // `e.text`: the name of a plain enum value's variant.
    if (std.mem.eql(u8, field, "text") and enumValues(self, peeled) != null) {
        if (hasVariantNames(self, peeled)) {
            try self.ctx.record(.enum_texts, e, {});
            return self.t().static_id;
        }
        if ((try findMethod(self, obj_ty, field)) == null) {
            try self.err(pos, "`.text` is the name of a plain enum's variant; `{s}` {s}", .{ try self.tyName(peeled), CompatCheck.notPlainWhy(self.ctx, peeled) });
            return self.t().invalid_id;
        }
    }
    // `value` names a Cell's constructor argument, not a field to read.
    if (std.mem.eql(u8, field, "value") and CompatCheck.cellElementType(self.ctx, peeled) != null) {
        try self.err(pos, "a Cell is read with `c.get()` and written with `!c.set(v)`, not through `.value`", .{});
        return self.t().invalid_id;
    }

    if (try dataField(self, obj_ty, field, pos, e)) |ty| return ty;
    const decl = sema.nominalDecl(self.ctx, peeled) orelse {
        // An element method named without its call.
        const has_elems = switch (self.ctx.types.get(peeled)) {
            .array, .slice, .string_view, .static => true,
            else => CompatCheck.listElementType(self.ctx, peeled) != null,
        };
        if (has_elems) if (std.meta.stringToEnum(sema.ElemOp, field)) |op| if (!op.isBits() and !op.isSimd() and !op.isTypeFn() and !op.isFloat() and op != .hash and op != .order) {
            const shown = switch (op) {
                .copy => "!xs.copy(src)",
                .fill => "!xs.fill(v)",
                .swap => "!xs.swap(i, j)",
                .read => "xs.read[U32, .little](at)",
                .write => "!xs.write[U32, .little](at, v)",
                .sum => "xs.sum()",
                .prefetch => "xs.prefetch(i)",
                .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .lanes, .any, .all, .array, .with, .select, .lookup, .lag, .hash, .order, .min, .max, .clamp, .total_order => unreachable,
            };
            try self.err(pos, "`{s}` is a method of `{s}`, only called: `{s}`", .{ field, try self.tyName(obj_ty), shown });
            return self.t().invalid_id;
        };
        if (self.ctx.types.get(peeled) == .weak) {
            try weakReach(self, obj, peeled, pos);
        } else try self.err(pos, "type `{s}` has no field `{s}`", .{ try self.tyName(obj_ty), field });
        return self.t().invalid_id;
    };
    const owner = decl.symbol();
    if ((try findMethod(self, obj_ty, field)) != null) {
        const m = (try findMethod(self, obj_ty, field)).?;
        const options = m.field.has_groups or if (m.field.param_defaults) |d| for (d) |x| {
            if (x != null) break true;
        } else false else false;
        if (owner.kind == .generic_type or options) {
            try self.err(pos, "method `{s}` must be called; wrap it in a closure to pass it as a value", .{field});
        } else {
            const tname = if (decl.module_id != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ decl.ctx.name, owner.name }) else owner.name;
            try self.err(pos, "method `{s}` must be called; to pass it as a function that takes `self` first, name it through its type: `{s}.{s}`", .{ field, tname, field });
        }
    } else if (sema.actorOfHandle(self.ctx, obj_ty) orelse sema.actorValue(self.ctx, obj_ty)) |value| {
        try self.err(pos, "an actor's fields are its own: reach `{s}` through a method of `{s}`", .{ field, try self.tyName(value) });
    } else if (owner.fields == null) {
        try self.err(pos, "opaque type `{s}` has no accessible fields", .{owner.name});
    } else {
        const hint = sema.stdRenamed(decl.ctx, owner.name, field) orelse try ExprCheck.memberHint(self, owner.fields.?, field, .field);
        try self.err(pos, "no field `{s}` on type `{s}`{s}", .{ field, owner.name, hint });
        try PatternCheck.noteDeclared(self, owner, decl.module_id == null);
    }
    return self.t().invalid_id;
}

/// The type of data field `name` of a self's nominal type, local
/// or imported, used at `pos`: another module's field must be `pub`.
/// `member`, the access `x.name`, is recorded when the field is
/// read-only here (`noteReadOnly`).
pub fn dataField(self: *Checker, obj_ty: TypeId, name: []const u8, pos: u32, member: Sexp) Error!?TypeId {
    if (try sema.lookupDataField(self.ctx, obj_ty, name)) |f| {
        const owner = self.ctx.symbols.items[f.nominal_sym];
        try checkVisible(self, f.field, owner, null, pos);
        try noteReadOnly(self, member, f.field, owner, null);
        return f.ty;
    }
    const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return null;
    const module_id = decl.module_id orelse return null;
    const f = (try CompatCheck.findDataField(self.ctx, decl.symbol().fields orelse &.{}, name)) orelse return null;
    try checkVisible(self, f, decl.symbol(), module_id, pos);
    try noteReadOnly(self, member, f, decl.symbol(), module_id);
    return try sema.importType(self.ctx, self.ctx.foreign_semas.get(module_id).?, f.ty, module_id);
}

/// Record the member access `member` when its field `f`, of `owner`
/// (declared in module `module`, or here, where a proxy stands for
/// another module's generic type), is `pub ?name: T` in another
/// module: read-only here. The one place this is decided.
pub fn noteReadOnly(self: *Checker, member: Sexp, f: Field, owner: sema.Symbol, module: ?u32) Error!void {
    if (member == .nil or !f.read_only) return;
    const m = module orelse if (sema.isProxy(owner)) owner.from.module_id else return;
    if (m == self.ctx.module_id) return;
    const foreign = self.ctx.foreign_semas.get(m) orelse return;
    // An imported type is named as checkVisible names it; a proxy is
    // already named as this module spells it (`lib.Wrap`).
    const owner_name = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, owner.name }) else owner.name;
    try self.ctx.record(.read_only_fields, member, .{ .field = f.name, .owner = owner_name, .module = foreign.name });
}

/// A field or method of a type another module declares, used at
/// `pos`, must be declared `pub` there; variants always are visible.
/// `owner` is the type's symbol: in module `module` (an imported
/// type), or here (a proxy stands for another module's generic type).
pub fn checkVisible(self: *Checker, f: Field, owner: sema.Symbol, module: ?u32, pos: u32) Error!void {
    if (f.is_pub or f.is_variant) return;
    const m = module orelse if (sema.isProxy(owner)) owner.from.module_id else return;
    if (m == self.ctx.module_id) return;
    const foreign = self.ctx.foreign_semas.get(m) orelse return;
    // A proxy is named as this module spells it already: `lib.Wrap`.
    const tname = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, owner.name }) else owner.name;
    if (f.is_method) {
        // A proxy's methods have this module's types.
        const types = if (module != null) foreign.types else self.t();
        const is_sub = switch (types.get(f.ty)) {
            .function => |fty| fty.is_sub,
            else => false,
        };
        const kw = if (is_sub) "sub" else "fun";
        if (foreign.is_std) {
            try self.err(pos, "method `{s}` of `{s}` is private to the standard library's module `{s}`", .{ f.name, tname, foreign.name });
        } else {
            // A method declared outside its type's body names the type.
            const shown = if (f.outside) try self.ctx.arena.allocator().print("{s}.{s}", .{ owner.name, f.name }) else f.name;
            try self.err(pos, "method `{s}` of `{s}` is private to module `{s}`; declare it `pub {s} {s}` there to call it from here", .{ f.name, tname, foreign.name, kw, shown });
        }
    } else if (foreign.is_std) {
        try self.err(pos, "field `{s}` of `{s}` is private to the standard library's module `{s}`", .{ f.name, tname, foreign.name });
    } else {
        try self.err(pos, "field `{s}` of `{s}` is private to module `{s}`; declare it `pub {s}: ...` there to use it from here", .{ f.name, tname, foreign.name, f.name });
    }
    if (f.decl_pos < sema.imported_decl_pos) try self.ctx.noteIn(m, f.decl_pos, "`{s}` declared here", .{f.name});
}

pub fn findMethod(self: *Checker, obj_ty: TypeId, name: []const u8) Error!?Checker.Method {
    if (try sema.lookupMethod(self.ctx, obj_ty, name)) |m| {
        return .{ .field = m.field, .fn_ty = m.fn_ty, .owner = self.ctx.symbols.items[m.nominal_sym].name, .nominal_sym = m.nominal_sym, .source = declSource(self, m.nominal_sym), .owner_sym = self.ctx.symbols.items[m.nominal_sym], .args = m.subst.args };
    }
    const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return null;
    const module_id = decl.module_id orelse return null;
    const foreign = self.ctx.foreign_semas.get(module_id).?;
    const fields = decl.symbol().fields orelse &.{};
    const f = fields[(try sema.findMember(self.ctx, fields, name, .method)) orelse return null];
    const ty = self.ctx.types.get(try sema.importType(self.ctx, foreign, f.ty, module_id));
    if (ty != .function) return null;
    return .{ .field = f, .fn_ty = ty.function, .owner = decl.symbol().name, .nominal_sym = sema.symbol_invalid, .source = foreign.source, .owner_sym = decl.symbol(), .module = module_id };
}

/// `module.name` as a value. Null when `obj` does not name a module.
pub fn moduleMember(self: *Checker, obj: Sexp, field: []const u8, pos: u32) Error!?TypeId {
    const id = (try moduleNamed(self, obj)) orelse return null;
    const found = (try foreignSymbol(self, id, field, pos)) orelse return self.t().invalid_id;
    if (found.sym.kind == .nominal_type or found.sym.kind == .generic_type or found.sym.kind == .type_alias) {
        try self.err(pos, "`{s}.{s}` is a type, not a value", .{ self.text(obj), field });
        return self.t().invalid_id;
    }
    const ty = try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
    if (found.sym.kind == .function) {
        const name = try self.ctx.arena.allocator().print("{s}.{s}", .{ self.text(obj), field });
        if (try ExprCheck.optionsValue(self, found.sym.param_defaults, found.sym.flags.has_groups, name, pos)) return self.t().invalid_id;
        return try ExprCheck.functionValue(self, ty, name, pos, found.sym.flags.inline_marked);
    }
    return ty;
}

pub fn namedType(self: *Checker, obj: Sexp) Error!?Checker.NamedType {
    if (rig.isBracketList(obj)) {
        const target = (try instTarget(self, ir.get(obj, .object))) orelse return null;
        // `Simd[T, n]` and `Slot[n]` are built-in types, not nominal
        // ones (`builtinTypeNamed`).
        if (target != .generic or self.ctx.ref(target.generic.id) == self.ctx.builtins.simd or self.ctx.ref(target.generic.id) == self.ctx.builtins.slot) return null;
        var nt = target.generic;
        const ty = try typeInstance(self, obj, nt);
        const arity = if (nt.sym.type_params) |tps| tps.len else 0;
        nt.args = if (self.isPoison(ty)) try poisonArgs(self, arity) else switch (self.ctx.types.get(ty)) {
            .parameterized_nominal => |pn| pn.args,
            else => return null,
        };
        return nt;
    }
    if (obj == .src) {
        const id = lookupQuiet(self, obj) orelse return null;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind == .type_alias) {
            const nt = aliasNamedType(self, sym.ty) orelse return null;
            if (nt.foreign == null) try self.ctx.recordName(obj, nt.id);
            return nt;
        }
        if (sym.kind != .nominal_type and sym.kind != .generic_type) return null;
        try self.ctx.recordName(obj, id);
        return .{ .id = id, .sym = sym };
    }
    if (!obj.isKind(.member)) return null;
    const id = (try moduleNamed(self, ir.Member.object(obj))) orelse return null;
    const name = ir.Member.name(obj);
    const found = (try foreignSymbol(self, id, self.text(name), name.src.pos)) orelse return null;
    if (found.sym.kind == .type_alias) return aliasNamedType(self, try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id));
    if (found.sym.kind == .generic_type) return try foreignGeneric(self, found);
    if (found.sym.kind != .nominal_type) return null;
    return .{ .id = found.id, .sym = found.sym, .foreign = .{ .ctx = found.ctx, .module_id = found.module_id } };
}

/// The object or enum an alias names, `ty` being the aliased type in
/// this module's terms: the alias constructs its values and reaches
/// its members as the type itself does. Null for an alias of any
/// other type.
pub fn aliasNamedType(self: *Checker, ty: TypeId) ?Checker.NamedType {
    return switch (self.ctx.types.get(ty)) {
        .nominal => |r| if (self.ctx.owns(r)) .{ .id = r.sym, .sym = self.ctx.symbols.items[r.sym] } else blk: {
            const foreign = self.ctx.foreign_semas.get(r.module_id) orelse break :blk null;
            break :blk .{ .id = r.sym, .sym = foreign.symbols.items[r.sym], .foreign = .{ .ctx = foreign, .module_id = r.module_id } };
        },
        .parameterized_nominal => |pn| .{ .id = self.ctx.localSym(pn.sym), .sym = sema.symbolAt(self.ctx, pn.sym).*, .args = pn.args },
        else => null,
    };
}

/// A named type as this module spells it: `lib.Point` for another
/// module's (a generic one's proxy is named so already).
pub fn namedTypeName(self: *Checker, nt: Checker.NamedType) Error![]const u8 {
    const fo = nt.foreign orelse return nt.sym.name;
    return self.ctx.arena.allocator().print("{s}.{s}", .{ fo.ctx.name, nt.sym.name });
}

/// Another module's generic type, named here by its proxy
/// (`sema.proxyOf`), whose members are in this module's types.
pub fn foreignGeneric(self: *Checker, found: Checker.Foreign) Error!Checker.NamedType {
    const id = try sema.proxyOf(self.ctx, .{ .module_id = found.module_id, .sym = found.id });
    return .{ .id = id, .sym = self.ctx.symbols.items[id] };
}

/// The source of the module that declares symbol `id`'s members and
/// defaults: another module's, for a proxy.
pub fn declSource(self: *Checker, id: SymbolId) []const u8 {
    const sym = self.ctx.symbols.items[id];
    if (!sema.isProxy(sym)) return self.ctx.source;
    return (self.ctx.foreign_semas.get(sym.from.module_id) orelse return self.ctx.source).source;
}

/// The type a (non-generic) named type denotes.
pub fn namedTypeValue(self: *Checker, nt: Checker.NamedType) Error!TypeId {
    if (nt.foreign) |fo| return self.ctx.intern(.{ .nominal = .{ .module_id = fo.module_id, .sym = nt.id } });
    return self.ctx.intern(.{ .nominal = self.ctx.ref(nt.id) });
}

/// `Type.variant`: a variant without a payload.
pub fn typeMember(self: *Checker, nt: Checker.NamedType, field: []const u8, pos: u32) Error!TypeId {
    const tname = try namedTypeName(self, nt);
    const members = nt.sym.fields orelse {
        if (nt.sym.error_parts != null) {
            try self.err(pos, "`{s}` is a union of error sets, which lists no members of its own: name the member with its set (`E.{s}`)", .{ tname, field });
        } else try self.err(pos, "opaque type `{s}` has no members", .{tname});
        return self.t().invalid_id;
    };
    // The first member of that name decides.
    found: {
        const m = members[(try sema.findMember(self.ctx, members, field, .any)) orelse break :found];
        // `Type.method` is a plain function value whose first
        // parameter is self.
        if (m.is_method) {
            try checkVisible(self, m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, pos);
            if (nt.sym.kind == .generic_type) {
                try self.err(pos, "method `{s}.{s}` of a generic type must be called; wrap it in a closure to pass it as a value", .{ tname, field });
                return self.t().invalid_id;
            }
            const name = try self.ctx.arena.allocator().print("{s}.{s}", .{ tname, field });
            if (try ExprCheck.optionsValue(self, m.param_defaults, m.has_groups, name, pos)) return self.t().invalid_id;
            return ExprCheck.functionValue(self, try memberType(self, nt.foreign, m.ty), name, pos, m.inline_marked);
        }
        if (!m.is_variant) break :found;
        if (nt.sym.kind == .generic_type and nt.args == null) {
            try self.err(pos, "variant of generic enum `{s}` needs its type; write `{s}[...].{s}`, or `.{s}` where a `{s}[...]` is expected", .{ tname, tname, field, field, tname });
            return self.t().invalid_id;
        }
        if (m.payload != null and m.payload.?.len > 0 and !(nt.sym.flags.error_set and self.expect.member_pattern != .nil and pos == self.startOf(ir.Member.name(self.expect.member_pattern)))) {
            try self.err(pos, "variant `{s}.{s}` carries a payload; construct it with `{s}.{s}(...)`", .{ tname, field, tname, field });
            return self.t().invalid_id;
        }
        if (nt.args) |given| return ViewCheck.instantiate(self, nt.id, given, pos);
        return namedTypeValue(self, nt);
    }
    try self.err(pos, "no member `{s}` on type `{s}`", .{ field, tname });
    try PatternCheck.noteDeclared(self, nt.sym, nt.foreign == null);
    return self.t().invalid_id;
}

/// `X[...]` where `X` is a type that takes no type arguments here.
pub fn notGeneric(self: *Checker, at: Sexp, target: Checker.InstTarget) Error!void {
    switch (target) {
        .reported => {},
        .not_generic => |name| try self.errAt(at, "`{s}` is not a generic type; it takes no type arguments", .{name}),
        else => unreachable,
    }
}

pub fn instTarget(self: *Checker, obj: Sexp) Error!?Checker.InstTarget {
    if (obj == .src) {
        const id = lookupQuiet(self, obj) orelse {
            const name = self.text(obj);
            return if (resolve.isBuiltinTypeName(self.ctx, name)) .{ .not_generic = name } else null;
        };
        const sym = self.ctx.symbols.items[id];
        switch (sym.kind) {
            .function, .@"extern" => return .{ .function = fnTarget(self.ctx, sym.ty) },
            .generic_type => {
                try self.ctx.recordName(obj, id);
                return .{ .generic = .{ .id = id, .sym = sym } };
            },
            .nominal_type, .type_alias => return .{ .not_generic = sym.name },
            else => return null,
        }
    }
    if (!obj.isKind(.member)) return null;
    const inner = ir.Member.object(obj);
    const name = self.text(ir.Member.name(obj));
    if (inner == .src) if (lookupQuiet(self, inner)) |id| if (self.ctx.symbols.items[id].kind == .module) {
        const f = foreignLookup(self, id, name) orelse return null;
        return switch (f.sym.kind) {
            .function, .@"extern" => .{ .function = fnTarget(f.ctx, f.sym.ty) },
            .nominal_type, .type_alias => .{ .not_generic = sourceText(self, obj) },
            .generic_type => blk: {
                try self.ctx.recordName(inner, id);
                const found = (try foreignSymbol(self, id, name, ir.Member.name(obj).src.pos)) orelse break :blk .reported;
                break :blk .{ .generic = try foreignGeneric(self, found) };
            },
            else => null,
        };
    };
    if (try namedType(self, inner)) |nt| {
        const fields = nt.sym.fields orelse &.{};
        const m = fields[(try sema.findMember(self.ctx, fields, name, .method)) orelse return null];
        return .{ .function = fnTarget(if (nt.foreign) |fo| fo.ctx else self.ctx, m.ty) };
    }
    return .value_member;
}

/// The `FnTarget` of function type `ty` (of `ctx`).
pub fn fnTarget(ctx: *const SemContext, ty: TypeId) Checker.FnTarget {
    const f = ctx.types.get(ty);
    if (f != .function) return .{ .ct_params = true, .takes_args = true };
    return .{ .ct_params = f.function.ct_params.len > 0, .takes_args = f.function.params.len > 0 };
}

/// The name and parameters of the `fun` or `sub` named `name`, as
/// written (`main()`, `load(path: ?String)`), for a hint that shows
/// its header; `f(...)` when there is no name.
pub fn headerText(self: *Checker, name: Sexp) []const u8 {
    if (name == .nil) return "f(...)";
    const sp = self.ctx.span(name);
    const src = self.ctx.source;
    var i = sp.end;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '(', '[' => depth += 1,
            ')', ']' => {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0 and src[i] == ')') return src[sp.start .. i + 1];
            },
            '\n' => break,
            else => {},
        }
    }
    return self.ctx.arena.allocator().print("{s}(...)", .{self.text(name)}) catch "f(...)";
}

/// The source text of a node, for messages.
pub fn sourceText(self: *Checker, node: Sexp) []const u8 {
    const sp = self.ctx.span(node);
    return diag.textOf(self.ctx.source, sp);
}

/// `n` poison type arguments, for a generic whose given arguments
/// were rejected.
pub fn poisonArgs(self: *Checker, n: usize) Error![]const TypeId {
    const out = try self.ctx.arena.allocator().alloc(TypeId, n);
    @memset(out, self.t().invalid_id);
    return out;
}

/// A bracket list of compile-time arguments where a value is
/// expected: a type, or a function that is not called.
pub fn misusedInstance(self: *Checker, e: Sexp, target: Checker.InstTarget) Error!TypeId {
    switch (target) {
        .generic => |nt| {
            if (!self.isPoison(try typeInstance(self, e, nt))) try self.errAt(e, "`{s}` is a type, not a value", .{sourceText(self, e)});
        },
        .function => |f| {
            const call = sourceText(self, e);
            if (!f.ct_params) {
                const name = sourceText(self, ir.get(e, .object));
                try self.errAt(e, "`{s}` takes no compile-time arguments; call it with `{s}(...)`", .{ name, name });
            } else try self.errAt(e, "`{s}` is a function with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (f.takes_args) "..." else "" });
        },
        .not_generic, .reported => try notGeneric(self, e, target),
        .value_member => unreachable,
    }
    return self.t().invalid_id;
}

/// `cap[8]`: a call of a compile-time function, whose value the
/// checker computes here (`cteval.callAt`) and records
/// (`Instance.ct_call`). Each argument is a value known where the
/// call is written; in a compile-time function's body, where the
/// evaluator runs the call, any value of the parameter's type
/// (`ctCallInBody`).
pub fn synthCtCall(self: *Checker, e: Sexp) Error!TypeId {
    const callee = sema.cteval.calleeOf(e);
    const name = sourceText(self, callee);
    const given = sema.cteval.argsOf(e);
    const target = (try ctTarget(self, callee)) orelse {
        for (given) |g| _ = try FlowCheck.synthQuiet(self, g);
        return self.t().invalid_id;
    };
    const f = (try sema.cteval.signatureOf(target)) orelse {
        for (given) |g| _ = try FlowCheck.synthQuiet(self, g);
        return self.t().invalid_id;
    };
    if (!try sema.cteval.arityFits(self.ctx, e, f, name)) {
        for (given) |g| _ = try FlowCheck.synthQuiet(self, g);
        return self.t().invalid_id;
    }
    if (self.in_ct_fun) return ctCallInBody(self, e, target, f, name);
    const names: resolve.ConstNames = .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
    const vals = (try sema.cteval.argValues(self.ctx, e, target, f, name, names, self)) orelse return self.t().invalid_id;
    const c = (try sema.cteval.callAt(self.ctx, e, target, vals)) orelse return self.t().invalid_id;
    try sema.cteval.recordCall(self.ctx, e, target, vals, c, self.scope != self.module_scope);
    return c.ty;
}

/// The compile-time function `callee` names, `cap` or `lib.cap`, as
/// `cteval.markCalls` found; null after a diagnostic.
pub fn ctTarget(self: *Checker, callee: Sexp) Error!?sema.cteval.Target {
    if (callee == .src) {
        const id = lookupQuiet(self, callee) orelse return null;
        try self.ctx.recordName(callee, id);
        if (!sema.cteval.isCtFunction(self.ctx, id)) return null;
        return .{ .ctx = self.ctx, .sym = id, .module_id = self.ctx.module_id };
    }
    const obj = ir.Member.object(callee);
    const module = lookupQuiet(self, obj) orelse return null;
    try self.ctx.recordName(obj, module);
    const found = (try foreignSymbol(self, module, self.text(ir.Member.name(callee)), ir.Member.name(callee).src.pos)) orelse return null;
    if (!sema.cteval.isCtFunction(found.ctx, found.id)) return null;
    return .{ .ctx = found.ctx, .sym = found.id, .module_id = found.module_id };
}

/// A compile-time call in a compile-time function's body: the
/// evaluator runs it, knowing every value, so an argument is any
/// value of its parameter's type, but one for a parameter the
/// result's type names, which follows the rule of compile-time
/// arguments (`ctIntArg`): the body is typed once, and `[n - 1]T` is
/// no type it can spell.
pub fn ctCallInBody(self: *Checker, e: Sexp, target: sema.cteval.Target, f_there: sema.FunctionType, name: []const u8) Error!TypeId {
    const a = self.ctx.arena.allocator();
    // Another module's signature, as this module reads it: its
    // integer parameters are proxies here (`sema.importType`), so a
    // result sized by one is typed as a local one is.
    const f = if (target.ctx == self.ctx) f_there else blk: {
        const fn_ty = try sema.importType(self.ctx, target.ctx, target.ctx.symbols.items[target.sym].ty, target.module_id);
        break :blk self.ctx.types.get(fn_ty).function;
    };
    var params: std.ArrayList(SymbolId) = .empty;
    var args: std.ArrayList(TypeId) = .empty;
    var ok = true;
    for (sema.cteval.argsOf(e), f.ct_params, 0..) |g, pty, i| {
        const sym = if (i < f.ct_syms.len) f.ct_syms[i].sym else sema.symbol_invalid;
        const sized = sym != sema.symbol_invalid and self.ctx.types.get(pty) == .int and sema.usesParams(self.ctx, f.returns, &.{sym});
        if (!sized) {
            try ViewCheck.checkExpr(self, g, pty);
            continue;
        }
        const arg = (try StdFormCheck.ctIntArg(self, g, sym, i, name)) orelse {
            ok = false;
            continue;
        };
        try params.append(a, sym);
        try args.append(a, arg);
    }
    try self.ctx.record(.ct_calls, e, .{ .result = null });
    if (!ok) return self.t().invalid_id;
    return sema.substituteType(self.ctx, f.returns, .{ .params = params.items, .args = args.items });
}

/// The instance of generic type `nt` that bracket list `e` names
/// (`Pair[Int, ?String]`), recorded for `e`; poison after a
/// diagnostic.
pub fn typeInstance(self: *Checker, e: Sexp, nt: Checker.NamedType) Error!TypeId {
    const params = nt.sym.type_params orelse &.{};
    var given = sema.bracketArgs(e);
    // `List[T, inline: n]()`: the first `n` elements live inside the List.
    var inline_len: u32 = 0;
    if (given.len > 0 and given[given.len - 1].isKind(.kwarg)) {
        const kw = given[given.len - 1];
        given = given[0 .. given.len - 1];
        const key = self.text(ir.Kwarg.name(kw));
        if (self.ctx.ref(nt.id) != self.ctx.builtins.list or !std.mem.eql(u8, key, "inline")) {
            try self.errAt(kw, "`{s}:` names no argument of `{s}`; only a List takes one, `List[T, inline: n]`", .{ key, nt.sym.name });
            return self.t().invalid_id;
        }
        var r = self.resolver();
        inline_len = (try r.inlineLen(ir.Kwarg.value(kw))) orelse return self.t().invalid_id;
    }
    if (given.len != params.len) {
        try self.errAt(e, "generic type `{s}` expects {d} {s} argument{s}, got {d}", .{ nt.sym.name, params.len, resolve.argsNoun(self.ctx, params), CompatCheck.plural(params.len), given.len });
        return self.t().invalid_id;
    }
    const args = try self.ctx.arena.allocator().alloc(TypeId, given.len);
    var bad = false;
    // What a task gives may fail: `Tasks[Int!]()`.
    const gives = self.ctx.ref(nt.id) == self.ctx.builtins.task or self.ctx.ref(nt.id) == self.ctx.builtins.tasks;
    for (given, args, params, 0..) |g, *a, tp, i| {
        a.* = if (self.ctx.symbols.items[tp].kind == .param)
            (try StdFormCheck.ctIntArg(self, g, tp, i, nt.sym.name)) orelse self.t().invalid_id
        else if (gives and g.isKind(.propagate)) blk: {
            const inner = try typeArg(self, ir.Propagate.value(g));
            break :blk if (self.isPoison(inner)) inner else try self.ctx.intern(.{ .fallible = .{ .ok = inner } });
        } else if (gives and g.isKind(.error_union)) blk: {
            // `Task[T!E]`, as a declaration names it.
            const inner = try typeArg(self, ir.ErrorUnion.type(g));
            if (self.isPoison(inner)) break :blk inner;
            var r = self.resolver();
            break :blk try r.taskResult(g, inner);
        } else try typeArg(self, g);
        if (self.isPoison(a.*)) bad = true;
        // A frozen value lives only behind `*`, never as an argument.
        if (sema.frozenValue(self.ctx, a.*) != null) {
            try self.errAt(g, sema.frozen_misplaced, .{try self.tyName(a.*)});
            bad = true;
        }
    }
    if (bad) return self.t().invalid_id;
    var ty = try ViewCheck.instantiate(self, nt.id, args, self.startOf(e));
    if (inline_len > 0 and !self.isPoison(ty))
        ty = try self.ctx.internCopy(.{ .parameterized_nominal = .{ .sym = self.ctx.ref(nt.id), .args = args, .inline_len = inline_len } });
    try self.ctx.record(.instances, e, .{ .type = ty });
    return ty;
}

/// A type argument written in an expression (`List[*Node]()`): a
/// name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[Y]`.
pub fn typeArg(self: *Checker, e: Sexp) Error!TypeId {
    var r = self.resolver();
    switch (e) {
        .src => if (!CompatCheck.isLiteralText(self.text(e))) return r.resolveType(e),
        .list => switch (e.kind() orelse return self.t().invalid_id) {
            .member => if (ir.Member.object(e) == .src) return r.resolveType(e),
            .box => {
                if (try optionalHandleArg(self, e)) |ty| return ty;
                const inner_node = ir.Box.operand(e);
                const inner = try typeArg(self, inner_node);
                if (self.isPoison(inner)) return inner;
                if (self.ctx.types.get(inner) == .function) {
                    try self.errAt(e, sema.boxed_function, .{});
                    return self.t().invalid_id;
                }
                if (sema.heapStacked(self.ctx, inner)) {
                    try self.errAt(e, sema.heap_stacked, .{try ViewCheck.stackedSpelling(self, '^', inner)});
                    return self.t().invalid_id;
                }
                return r.boxOf(inner, self.startOf(e));
            },
            .share, .weak, .read, .write, .propagate_none => {
                if (e.isKind(.share) or e.isKind(.weak)) if (try optionalHandleArg(self, e)) |ty| return ty;
                const inner_node = ir.get(e, if (e.isKind(.propagate_none)) .value else .operand);
                const inner = try typeArg(self, inner_node);
                if (self.isPoison(inner)) return inner;
                if (e.isKind(.share) and sema.heapStacked(self.ctx, inner)) {
                    try self.errAt(e, sema.heap_stacked, .{try ViewCheck.stackedSpelling(self, '*', inner)});
                    return self.t().invalid_id;
                }
                if ((e.isKind(.share) or e.isKind(.weak)) and sema.isReadOrWriteView(self.ctx, inner)) {
                    try self.errAt(e, "a handle holds a value, not a view: `{s}` has no handle", .{try self.tyName(inner)});
                    return self.t().invalid_id;
                }
                if (e.isKind(.share) or e.isKind(.weak)) try sema.requireHandleOf(self.ctx, inner, self.startOf(e), if (e.isKind(.share)) "`*`" else "`~`");
                // `List[?Actor[T]]()`: a view of an actor views its handle.
                if ((e.isKind(.read) or e.isKind(.write)) and sema.actorMisplaced(self.ctx, inner, .viewed)) {
                    try self.errAt(e, sema.actor_viewed, .{ if (e.isKind(.read)) "?" else "!", try self.tyName(inner) });
                    return self.t().invalid_id;
                }
                return self.ctx.intern(switch (e.kind().?) {
                    .share => .{ .shared = inner },
                    .weak => .{ .weak = inner },
                    .read => .{ .read_view = inner },
                    .write => .{ .write_view = inner },
                    else => .{ .optional = inner },
                });
            },
            .propagate, .error_union => {
                try self.errAt(e, "a fallible type `{s}` stands only where a call's result is named: a function's return type, or a task's, `Task[T!]`", .{sourceText(self, e)});
                return self.t().invalid_id;
            },
            .ct_call => {
                try self.errAt(e, "`{s}` is a compile-time value, not a type", .{sourceText(self, e)});
                return self.t().invalid_id;
            },
            .index, .inst => if (try instTarget(self, ir.get(e, .object))) |target| switch (target) {
                .generic => |nt| return typeInstance(self, e, nt),
                .not_generic, .reported => {
                    try notGeneric(self, e, target);
                    return self.t().invalid_id;
                },
                else => {},
            },
            else => {},
        },
        else => {},
    }
    try self.errAt(e, "`{s}` is not a type; a type argument in an expression is a name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or `X[T]`", .{sourceText(self, e)});
    return self.t().invalid_id;
}

/// `*T?`, `~T?`, `*~T?` written as a type argument: an optional
/// handle, since a handle binds tighter than a suffix. An expression
/// reads it as the handles of `T?`, so the suffixes move outside the
/// whole chain of handles. A handle to an optional, `*(T?)`, has no
/// expression spelling, and a fallible one is only a return type.
/// Null when the chain has no suffix to move.
pub fn optionalHandleArg(self: *Checker, e: Sexp) Error!?TypeId {
    var handles: std.ArrayList(Sexp) = .empty;
    var op = e;
    while (op.isKind(.share) or op.isKind(.weak) or op.isKind(.box)) : (op = ir.get(op, .operand)) try handles.append(self.ctx.arena.allocator(), op);
    if (!op.isKind(.propagate_none) and !op.isKind(.propagate)) return null;
    if (self.ctx.parser) |p| if (p.hasParenSuffix(e)) {
        try self.errAt(e, "a handle to an optional has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead", .{});
        return self.t().invalid_id;
    };
    var count: u32 = 0;
    var base = op;
    while (base.isKind(.propagate_none) or base.isKind(.propagate)) : (count += 1) {
        if (base.isKind(.propagate)) {
            try self.errAt(e, "a fallible type `{s}` stands only where a call's result is named: a function's return type, or a task's, `Task[T!]`", .{sourceText(self, e)});
            return self.t().invalid_id;
        }
        base = ir.PropagateNone.value(base);
    }
    var ty = try typeArg(self, base);
    var inner_node = base;
    var i = handles.items.len;
    while (i > 0) {
        i -= 1;
        if (self.isPoison(ty)) return ty;
        const h = handles.items[i];
        if (h.isKind(.share) and sema.heapStacked(self.ctx, ty)) {
            try self.errAt(h, sema.heap_stacked, .{try ViewCheck.stackedSpelling(self, '*', ty)});
            return self.t().invalid_id;
        }
        if (h.isKind(.box) and sema.heapStacked(self.ctx, ty)) {
            try self.errAt(h, sema.heap_stacked, .{try ViewCheck.stackedSpelling(self, '^', ty)});
            return self.t().invalid_id;
        }
        if (h.isKind(.box)) {
            var r = self.resolver();
            ty = try r.boxOf(ty, self.startOf(h));
        } else ty = try self.ctx.intern(if (h.isKind(.share)) .{ .shared = ty } else .{ .weak = ty });
        inner_node = h;
    }
    while (count > 0) : (count -= 1) ty = try self.ctx.intern(.{ .optional = ty });
    return ty;
}

/// `Wrap[Int](v: 3)`, `List[Int]()`: a generic type constructed at the
/// given arguments.
pub fn constructInstance(self: *Checker, call: Sexp, e: Sexp, nt: Checker.NamedType, args: []const Sexp) Error!TypeId {
    const ty = try typeInstance(self, e, nt);
    if (self.isPoison(ty)) return skipCall(self, args);
    if (self.ctx.ref(nt.id) == self.ctx.builtins.list) {
        try BuiltinCheck.checkListConstruction(self, call, ty);
        return ty;
    }
    if (self.ctx.ref(nt.id) == self.ctx.builtins.table) {
        try StdFormCheck.checkTableConstruction(self, call);
        return ty;
    }
    if (self.ctx.ref(nt.id) == self.ctx.builtins.signal and !CompatCheck.sameNode(call, self.expect.shared_operand)) return badCall(self, args, e, Checker.stack_signal, .{});
    if (self.ctx.ref(nt.id) == self.ctx.builtins.chan) return StdFormCheck.chanMake(self, call, e, ty, args);
    if (self.ctx.ref(nt.id) == self.ctx.builtins.frozen) {
        const made = try StdFormCheck.frozenMake(self, call, e, args);
        if (!self.isPoison(made) and made != ty) return badCall(self, args, e, "`{s}` freezes a `{s}`", .{ try self.tyName(ty), try self.tyName(made) });
        return made;
    }
    const subst: TypeSubst = .{ .params = nt.sym.type_params orelse &.{}, .args = self.ctx.types.get(ty).parameterized_nominal.args };
    return construct(self, nt.id, args, self.startOf(e), subst, null);
}

/// The module a name leaf denotes, recorded as its symbol; null when
/// it denotes no module.
pub fn moduleNamed(self: *Checker, leaf: Sexp) Error!?SymbolId {
    if (leaf != .src) return null;
    const id = lookupQuiet(self, leaf) orelse return null;
    if (self.ctx.symbols.items[id].kind != .module) return null;
    try self.ctx.recordName(leaf, id);
    return id;
}

/// The symbol a name leaf denotes where it is written, without
/// diagnostics.
pub fn lookupQuiet(self: *Checker, leaf: Sexp) ?SymbolId {
    return lookupAt(self, self.scope, self.text(leaf), leaf.src.pos);
}

/// `name` as seen at `pos` from `scope`: declaration order counts.
pub fn lookupAt(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
    var sid: ?ScopeId = scope;
    while (sid) |s| {
        if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
        if (ExprCheck.visibleIn(self, s, name, pos)) |id| return id;
        sid = self.ctx.scopes.items[s].parent;
    }
    return null;
}

/// A module-level symbol of an imported module, public or not.
pub fn foreignLookup(self: *Checker, module_sym: SymbolId, name: []const u8) ?Checker.Foreign {
    const origin = self.ctx.module_refs.get(module_sym) orelse return null;
    const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
    const fid = foreign.moduleMember(name) orelse return null;
    return .{ .ctx = foreign, .module_id = origin, .id = fid, .sym = foreign.symbols.items[fid] };
}

/// A public module-level symbol of an imported module.
pub fn foreignSymbol(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32) Error!?Checker.Foreign {
    const module_name = self.ctx.symbols.items[module_sym].name;
    const origin = self.ctx.module_refs.get(module_sym) orelse {
        try self.err(pos, "module `{s}` was not loaded", .{module_name});
        return null;
    };
    if (self.ctx.foreign_semas.get(origin) == null) return null;
    const found = foreignLookup(self, module_sym, name) orelse {
        const foreign = self.ctx.foreign_semas.get(origin).?;
        try self.err(pos, "no member `{s}` in module `{s}`{s}", .{ name, module_name, sema.stdNameHint(foreign, name) });
        return null;
    };
    if (!found.sym.flags.is_public) {
        try sema.notPublic(self.ctx, pos, module_name, name, found.ctx);
        return null;
    }
    sema.noteRuntimeRead(self.ctx, found.ctx, name);
    return found;
}

pub fn synthIndex(self: *Checker, e: Sexp) Error!TypeId {
    const object = ir.get(e, .object);
    if (e.isKind(.index) and ir.Index.index(e).isKind(.@"..")) return synthSlice(self, e, false);
    if (try instTarget(self, object)) |target| {
        if (target != .value_member) return misusedInstance(self, e, target);
        // `value.name[...]`: a method's compile-time arguments, which
        // only a call takes, or an element of a field.
        const inner = ir.Member.object(object);
        // A field of a temporary is read where it stands.
        const inner_ty = if (ViewCheck.hands(self, inner).hasStorage()) try ViewCheck.synthOperand(self, inner) else try ViewCheck.synthReadTemp(self, inner);
        if (!self.isPoison(inner_ty)) if (try findMethod(self, inner_ty, self.text(ir.Member.name(object)))) |m| {
            const call = sourceText(self, e);
            const takes_args = m.fn_ty.params.len > @intFromBool(m.field.self_mode != .none);
            try self.errAt(e, "`{s}` is a method with compile-time arguments; call it with `{s}({s})`", .{ call, call, if (takes_args) "..." else "" });
            return self.t().invalid_id;
        };
        const field_ty = try memberOf(self, object, inner, inner_ty);
        try self.ctx.recordType(object, field_ty);
        return indexInto(self, e, field_ty);
    }
    // An element of a temporary is read where it stands, and the
    // statement drops the temporary.
    if (!ViewCheck.hands(self, object).hasStorage() and e.isKind(.index)) return indexInto(self, e, try ViewCheck.synthReadTemp(self, object));
    return indexInto(self, e, try ViewCheck.synthOperand(self, object));
}

/// Element `e` (an `index` node) of a value of type `obj_ty`.
pub fn indexInto(self: *Checker, e: Sexp, obj_ty: TypeId) Error!TypeId {
    const object = ir.get(e, .object);
    if (e.isKind(.inst)) {
        for (ir.Inst.args(e)) |a| _ = try FlowCheck.synthQuiet(self, a);
        if (self.isPoison(obj_ty)) return obj_ty;
        try self.errAt(e, "an index is one value with no trailing comma; a list in brackets gives compile-time arguments, which only a generic type or a function with compile-time parameters takes", .{});
        return self.t().invalid_id;
    }
    const index = ir.Index.index(e);
    if (self.isPoison(obj_ty)) {
        _ = try FlowCheck.synthQuiet(self, index);
        return obj_ty;
    }
    // A slot of a table: with a `Slot[n]` of its own `n`, a place with
    // no test; with an integer, tested against `n`.
    if (sema.tableElem(self.ctx, sema.unwrapReadAccess(self.ctx, obj_ty))) |elem| return tableIndex(self, index, sema.unwrapReadAccess(self.ctx, obj_ty), elem);
    // A type an integer cannot index is said so first, whatever the
    // index is: one error, not two.
    if (!integerIndexed(self, obj_ty)) {
        const quiet_ty = try FlowCheck.synthQuiet(self, index);
        if (self.isPoison(quiet_ty)) return quiet_ty;
        return rejectIndexed(self, e, obj_ty, quiet_ty);
    }
    const idx_ty = try ViewCheck.synthValue(self, index);
    if (self.isPoison(idx_ty)) return idx_ty;
    if (!sema.isInteger(self.ctx, idx_ty)) {
        try self.errAt(index, "an index must be an integer; got `{s}`{s}", .{ try self.tyName(idx_ty), try FlowCheck.loopOrderHint(self, index, self.t().int_id) });
    } else if (idx_ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, index);
    // A lane of a vector is a value: the vector is read, and a constant
    // index is checked against the lane count now.
    if (sema.simdOf(self.ctx, obj_ty)) |v| {
        _ = try ViewCheck.readThrough(self, object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
        try StdFormCheck.checkLaneIndex(self, index, sema.unwrapViews(self.ctx, obj_ty));
        return v.elem;
    }
    const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
    switch (self.ctx.types.get(peeled)) {
        .array => |a| {
            // A known length is part of the type, so a constant index
            // is checked now.
            if (sema.arrayLen(self.ctx, a)) |n| if (ExprCheck.constInt(self, index)) |i| if (i < 0 or i >= n) {
                try self.errAt(index, "index `{d}` is out of bounds for an array of length {d}", .{ i, n });
            };
            return a.elem;
        },
        .slice => |s| {
            _ = try ViewCheck.reachThrough(self, object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
            return s.elem;
        },
        .string_view, .static => {
            _ = try ViewCheck.reachThrough(self, object, obj_ty, sema.unwrapViews(self.ctx, obj_ty));
            return ViewCheck.byteType(self);
        },
        // A List's element is a place, as a field is: what its context
        // does with it is checked where it is used.
        .parameterized_nominal => if (CompatCheck.listElementType(self.ctx, peeled)) |elem| {
            return elem;
        } else if (CompatCheck.cellListElement(self.ctx, peeled)) |elem| {
            if ((try ViewCheck.cannotCopy(self, elem, self.startOf(object), "reads an element of a Cell's List"))) {
                try self.errAt(object, CompatCheck.cell_list_handle, .{try self.tyName(peeled)});
                return self.t().invalid_id;
            }
            return elem;
        },
        else => {},
    }
    return rejectIndexed(self, e, obj_ty, idx_ty);
}

/// Whether an integer indexes a value of type `obj_ty`: a vector, an
/// array, a slice, a `?String` or `Static`, a List, or a Cell's List.
pub fn integerIndexed(self: *Checker, obj_ty: TypeId) bool {
    if (sema.simdOf(self.ctx, obj_ty) != null) return true;
    const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
    return switch (self.ctx.types.get(peeled)) {
        .array, .slice, .string_view, .static => true,
        .parameterized_nominal => CompatCheck.listElementType(self.ctx, peeled) != null or CompatCheck.cellListElement(self.ctx, peeled) != null,
        else => false,
    };
}

/// `m[k]` of a value `obj_ty` an integer cannot index, whose index has
/// type `idx_ty`. A Map, HashMap, Set, or HashSet is told its own way
/// of doing what the program wrote (`hashFix`).
pub fn rejectIndexed(self: *Checker, e: Sexp, obj_ty: TypeId, idx_ty: TypeId) Error!TypeId {
    const object = ir.get(e, .object);
    if (sema.unwrapViews(self.ctx, obj_ty) == self.t().string_id) {
        try self.errAt(object, "cannot index a value of type `{s}`; index its `?String` view: `(?{s}[..])[i]`", .{ try self.tyName(obj_ty), try ViewCheck.plainText(self, CompatCheck.stripSigil(object)) });
        return self.t().invalid_id;
    }
    if (try hashFix(self, e, obj_ty, idx_ty)) return self.t().invalid_id;
    try self.errAt(object, "cannot index a value of type `{s}`", .{try self.tyName(obj_ty)});
    return self.t().invalid_id;
}

/// The error for `m[k]` on a Map, HashMap, Set, or HashSet, whose
/// entry is no place (an absent key has none, and an assignment would
/// hide an insertion), with the form of what the program wrote, built
/// from its own text. True when reported.
pub fn hashFix(self: *Checker, e: Sexp, obj_ty: TypeId, idx_ty: TypeId) Error!bool {
    const peeled = sema.unwrapReadAccess(self.ctx, obj_ty);
    const pn = switch (self.ctx.types.get(peeled)) {
        .parameterized_nominal => |pn| pn,
        else => return false,
    };
    const sym = self.ctx.symbols.items[self.ctx.localSym(pn.sym)];
    const is_map = std.mem.eql(u8, sym.name, "Map") or std.mem.eql(u8, sym.name, "HashMap");
    const is_set = std.mem.eql(u8, sym.name, "Set") or std.mem.eql(u8, sym.name, "HashSet");
    if (!is_map and !is_set) return false;
    // Only the prelude's, which hold their entries in a table.
    const fields = sym.fields orelse return false;
    const table = (try CompatCheck.findDataField(self.ctx, fields, "t")) orelse return false;
    const tsym = switch (self.ctx.types.get(table.ty)) {
        .parameterized_nominal => |tp| tp.sym,
        else => return false,
    };
    if (!sema.isHashTable(self.ctx, tsym)) return false;
    if (pn.args.len != (if (is_set) @as(usize, 1) else 2)) return false;
    const key = pn.args[0];
    const object = ir.get(e, .object);
    const index = ir.Index.index(e);
    const shown = try self.tyName(peeled);
    const m = try StdFormCheck.selfText(self, object);
    const m_plain = try ViewCheck.plainText(self, object);
    const alloc = self.ctx.arena.allocator();
    // The key as the Map's own type takes it: a literal String where
    // the key is a String is made one.
    const k_text = try ViewCheck.plainText(self, index);
    const key_fits = CompatCheck.compatible(self.ctx, idx_ty, key) or (sema.isStringLiteralText(k_text) and key == self.t().string_id and idx_ty == self.t().static_id);
    const k = try asType(self, k_text, key);
    const use = if (CompatCheck.sameExpr(e, self.expect.index_use.at)) self.expect.index_use else Checker.IndexUse{};
    if (is_set) {
        try self.errAt(object, "cannot index a value of type `{s}`: a {s} holds keys and no values, so `{s}[k]` is no place; test a key with `{s}.has({s})`, add one with `!{s}.add({s})`", .{ shown, sym.name, m_plain, m, if (key_fits) k_text else "k", m_plain, if (key_fits) k else "k" });
        return true;
    }
    const val = pn.args[1];
    const what: []const u8 = switch (use.form) {
        .assign => "an assignment would hide an insertion, so it is written",
        .compound => "to change a value in place, or add the key with a starting value, write",
        .write_view => "to write the value in place, take its write view, which is `none` when the key is absent",
        .read => "read the value, which is `none` when the key is absent, with",
    };
    const head = try alloc.print("cannot index a value of type `{s}`: a key may be absent, so `{s}[k]` is no place; ", .{ shown, m_plain });
    if (!key_fits) {
        try self.errAt(object, "{s}{s} `{s}.put(k, v)`, `{s}.get(k)`, `{s}.edit(k)` (its keys are `{s}`)", .{ head, "use", m, m, m, try self.tyName(key) });
        return true;
    }
    const numeric = sema.isNumeric(self.ctx, val);
    const zero: []const u8 = if (sema.isFloatType(self.ctx, val)) "0.0" else "0";
    const fix: []const u8 = switch (use.form) {
        .assign => try alloc.print("`!{s}.put({s}, {s})`", .{ m, k, try asType(self, use.rhs_text, val) }),
        .compound => if (numeric) try alloc.print("`(!{s}).ensure({s}, {s}) {s} {s}`", .{ m, k, zero, use.op, use.rhs_text }) else try alloc.print("`if !{s}.edit({s}) as v`", .{ m, k_text }),
        .write_view => try alloc.print("`if !{s}.edit({s}) as v`", .{ m, k_text }),
        .read => if (numeric) try alloc.print("`{s}.get({s}) ?? {s}`", .{ m, k_text, zero }) else try alloc.print("`if {s}.get({s}) as v`", .{ m, k_text }),
    };
    try self.errAt(object, "{s}{s}: {s}", .{ head, what, fix });
    return true;
}

/// `text`, an argument of type `ty` where the program wrote a
/// literal: a string literal is made a `String` where one is taken.
pub fn asType(self: *Checker, written: []const u8, ty: TypeId) Error![]const u8 {
    if (ty == self.t().string_id and sema.isStringLiteralText(written)) return self.ctx.arena.allocator().print("String({s})", .{written});
    return written;
}

/// Slot `index` of a table of type `table` (Core §10, "Tables"): a
/// place of type `elem`, as a List's element is. A `Slot[n]` of the
/// table's own `n` needs no test; an integer is tested `0 <= i < n`;
/// a slot of another count is a type error.
pub fn tableIndex(self: *Checker, index: Sexp, table: TypeId, elem: TypeId) Error!TypeId {
    const want = (try sema.tableSlot(self.ctx, table)).?;
    const idx_ty = sema.unwrapViews(self.ctx, try ViewCheck.synthValue(self, index));
    if (self.isPoison(idx_ty)) return elem;
    if (self.ctx.types.get(idx_ty) == .slot) {
        if (idx_ty != want) try self.errAt(index, "type mismatch: expected `{s}`, got `{s}`; a slot indexes a table of its own `n` (convert with `{s}.of(Int(s))`)", .{ try self.tyName(want), try self.tyName(idx_ty), try self.tyName(want) });
        return elem;
    }
    if (!sema.isInteger(self.ctx, idx_ty)) {
        try self.errAt(index, "a table's index is a `{s}`, or an integer it tests; got `{s}`", .{ try self.tyName(want), try self.tyName(idx_ty) });
    } else if (idx_ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, index);
    return elem;
}

/// The element of List `peeled` (the type of `object`), sliced. Null
/// after a diagnostic.
pub fn listSliceElem(self: *Checker, object: Sexp, obj_ty: TypeId, peeled: TypeId) Error!?TypeId {
    const elem = CompatCheck.listElementType(self.ctx, peeled) orelse {
        try self.errAt(object, "cannot slice a value of type `{s}`; slice a `?String`, an array, a List, or a `[]T`", .{try self.tyName(obj_ty)});
        return null;
    };
    return elem;
}

/// `xs[a..b]`: the elements from `a` up to, not including, `b`. A
/// `?String` gives a `?String` viewing what it views, and a `[]T` a `[]T`
/// viewing the same elements. An array or a `List` of plain data gives
/// a `[]T`, and a String a `?String`, only as `?xs[a..b]` (`viewed`), or
/// as an argument, where it is viewed as `?xs[a..b]` would be and its
/// context decides whether it takes the view (`viewByRows`): the slice
/// is a read view of `xs`.
pub fn synthSlice(self: *Checker, e: Sexp, written: bool) Error!TypeId {
    const object = ir.Index.object(e);
    const range = ir.Index.index(e);
    const arg = !written and CompatCheck.sameExpr(e, self.expect.view_arg);
    // A slice of a temporary is reported below, once. An argument's
    // is viewed only where the slice views what it slices.
    const obj_ty = if (ViewCheck.hands(self, object).hasStorage() or !(written or arg)) try ViewCheck.synthOperand(self, object) else if (written) try PatternCheck.synthExpr(self, object) else blk: {
        if (try ViewCheck.rejectSharedTemporary(self, object)) break :blk self.t().invalid_id;
        const ty = try PatternCheck.synthExpr(self, object);
        if (!self.isPoison(ty) and !sliceViewsObject(self, ty)) try ViewCheck.rejectResourceTemporary(self, object, ty);
        break :blk ty;
    };
    const viewed = written or (arg and !self.isPoison(obj_ty) and sliceViewsObject(self, obj_ty));
    try checkSliceRange(self, range);
    if (self.isPoison(obj_ty)) return obj_ty;
    // What the slice views, which the ownership checker reads.
    if (sema.sliceView(self.ctx, obj_ty)) |view| try self.ctx.record(.slice_views, e, view);
    // A boxed String is sliced through its box.
    const peeled = CompatCheck.stringOrBoxed(self.ctx, sema.unwrapViews(self.ctx, obj_ty));
    const elem: TypeId = switch (self.ctx.types.get(peeled)) {
        .string_view, .static, .slice => {
            _ = try ViewCheck.reachThrough(self, object, obj_ty, peeled);
            try checkSliceBounds(self, range, null);
            // A `![]T` is viewed like the array it views: a read
            // slice of it keeps it from being written meanwhile.
            if (!viewed and sliceViewsObject(self, obj_ty)) {
                try self.errAt(e, "a slice of a `![]T` views it; write `?{s}` or `!{s}`", .{ try ViewCheck.plainText(self, e), try ViewCheck.plainText(self, e) });
                return self.t().invalid_id;
            }
            return peeled;
        },
        .array => |a| a.elem,
        // A view of a String is a `?String` that views it.
        .string => {
            try checkSliceBounds(self, range, null);
            // A slice of a view of a String views what that view does,
            // as a slice of a `?String` does.
            if (!viewed and sliceViewsObject(self, obj_ty)) {
                try self.errAt(e, "a slice of a String views it; write `?{s}`", .{try ViewCheck.plainText(self, e)});
                return self.t().invalid_id;
            }
            if (viewed and !StmtCheck.placeOf(self, object).named()) try ViewCheck.viewTempIn(self, object, e);
            return self.t().string_view_id;
        },
        else => (try listSliceElem(self, object, obj_ty, peeled)) orelse return self.t().invalid_id,
    };
    const len: ?u64 = if (self.ctx.types.get(peeled) == .array) sema.arrayLen(self.ctx, self.ctx.types.get(peeled).array) else null;
    try checkSliceBounds(self, range, len);
    if (!viewed) {
        try self.errAt(e, "a slice of an array or List views it; write `?{s}`", .{try ViewCheck.plainText(self, e)});
        return self.t().invalid_id;
    }
    if (!StmtCheck.placeOf(self, object).named()) try ViewCheck.viewTempIn(self, object, e);
    return self.ctx.intern(.{ .slice = .{ .elem = elem } });
}

/// Whether a slice of a value of type `obj_ty` views that value, as
/// `?xs[a..b]` does (Core §4), so that nothing frees or overwrites
/// what the slice views while it is used. Decided here, once, for
/// every slice, written `?` or not, an argument or bound, by what
/// holds the elements and how it is reached:
/// - the elements of an array or a List, owned or through any view,
///   box, or handle: viewed;
/// - the elements a `![]T` views, which it writes: viewed;
/// - the bytes of a String, owned, in a box or a `*T`, or through a
///   write view of one, which may add to the String or replace it:
///   viewed;
/// - the bytes of a String through a read view (`?String`, `?*String`,
///   `?^String`), which cannot change while that view's loan
///   lives, and the slice carries it: not viewed, a `?String` of its
///   own;
/// - what a `?String` or a `[]T` views, which writing the `?String` or the
///   `[]T` itself does not free: not viewed.
pub fn sliceViewsObject(self: *Checker, obj_ty: TypeId) bool {
    if (sema.writeSliceElem(self.ctx, obj_ty) != null) return true;
    return switch (self.ctx.types.get(CompatCheck.stringOrBoxed(self.ctx, sema.unwrapViews(self.ctx, obj_ty)))) {
        .string_view, .static, .slice => false,
        .string => self.ctx.types.get(obj_ty) != .read_view,
        else => true,
    };
}

/// Whether `e` is a slice written with no sigil that an argument
/// views, as `?e` would (`synthSlice`).
pub fn slicedArg(self: *Checker, e: Sexp) bool {
    if (!rig.isRangeIndex(e) or !CompatCheck.sameExpr(e, self.expect.view_arg)) return false;
    const ty = self.ctx.typeOf(ir.Index.object(e)) orelse return false;
    return !self.isPoison(ty) and sliceViewsObject(self, ty);
}

/// A slice's bounds are integers: of one type when both are given,
/// and `Int` when that is all a literal says. An open side
/// (`xs[a..]`, `xs[..b]`) is the start or the end.
pub fn checkSliceRange(self: *Checker, range: Sexp) Error!void {
    const lo = ir.@"..".left(range);
    const hi = ir.@"..".right(range);
    if (lo != .nil and hi != .nil) {
        _ = try ExprCheck.checkIntDefaultOperands(self, range, if (rig.isInclusive(range)) "..=" else "..", .integer, null);
        return;
    }
    const bound = if (lo != .nil) lo else hi;
    if (bound == .nil) return;
    const ty = try ViewCheck.synthOperandValue(self, bound);
    if (self.isPoison(ty)) return;
    if (!sema.isInteger(self.ctx, ty)) return self.errAt(bound, "a slice bound must be an integer; got `{s}`", .{try self.tyName(ty)});
    if (ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, bound);
}

/// Constant bounds are checked now: `0 <= a <= b`, and `b <= len` for
/// an array, whose length is part of its type; `a..=b` ends at
/// `b + 1`. Others are checked when the slice is taken. An open end
/// is the length.
pub fn checkSliceBounds(self: *Checker, range: Sexp, len: ?u64) Error!void {
    const lo_node = ir.@"..".left(range);
    const hi_node = ir.@"..".right(range);
    const lo: ?Wide = if (lo_node == .nil) 0 else ExprCheck.constInt(self, lo_node);
    if (lo) |a| if (a < 0) return self.errAt(lo_node, "a slice bound cannot be negative; got `{d}`", .{a});
    if (hi_node == .nil) {
        if (lo) |a| if (len) |n| if (a > n) return self.errAt(lo_node, "slice start `{d}` is past the end of an array of length {d}", .{ a, n });
        return;
    }
    if (ExprCheck.constInt(self, hi_node)) |b| {
        if (b < 0) return self.errAt(hi_node, "a slice bound cannot be negative; got `{d}`", .{b});
        if (rig.isInclusive(range)) {
            if (len) |n| if (b >= n) return self.errAt(hi_node, "slice end `{d}` is past the last index of an array of length {d}", .{ b, n });
            if (lo_node != .nil) if (lo) |a| if (a > b + 1) return self.errAt(range, "slice `{d}..={d}` starts after it ends", .{ a, b });
            return;
        }
        if (len) |n| if (b > n) return self.errAt(hi_node, "slice end `{d}` is past the end of an array of length {d}", .{ b, n });
        if (lo_node != .nil) if (lo) |a| if (a > b) return self.errAt(range, "slice `{d}..{d}` starts after it ends", .{ a, b });
    }
}

pub fn synthArray(self: *Checker, node: Sexp) Error!TypeId {
    const elems = ir.Array.elems(node);
    if (elems.len == 0) {
        try self.errAt(node, "an empty array literal needs a type annotation (`xs: [0]Int = []`)", .{});
        return self.t().invalid_id;
    }
    const elem_tys = try self.ctx.arena.allocator().alloc(TypeId, elems.len);
    var elem = try synthElem(self, elems[0]);
    elem_tys[0] = elem;
    for (elems[1..], 1..) |e, i| {
        const ty = try synthElem(self, e);
        elem_tys[i] = ty;
        elem = (try BuiltinCheck.unify(self, elem, ty, self.startOf(e))) orelse return self.t().invalid_id;
    }
    const concrete = ExprCheck.canonical(self, elem);
    if (sema.writeViewMisplaced(self.ctx, concrete, .element)) {
        try self.errAt(node, sema.write_view_misplaced, .{try self.tyName(concrete)});
        return self.t().invalid_id;
    }
    if (concrete != elem) {
        for (elems) |e| try ViewCheck.checkExpr(self, e, concrete);
    } else for (elems, elem_tys) |e, ty| try FlowCheck.adaptLiteral(self, e, ty, concrete);
    // An array holds owners as a List does; a generic body's array
    // of a `T` needs each instance to own nothing.
    _ = try ViewCheck.needsCleanup(self, concrete, self.startOf(node), "puts in an array a value");
    const ty = try self.ctx.intern(.{ .array = .{ .elem = concrete, .len = try sema.ctInt(self.ctx, elems.len) } });
    if (self.expect.under_poison) return ty;
    return if (try sema.checkArrayBytes(self.ctx, self.startOf(node), ty)) ty else self.t().invalid_id;
}

/// An array literal's element: a template there is a String the
/// array holds, as one bound to a name is (SPEC "Templates").
pub fn synthElem(self: *Checker, e: Sexp) Error!TypeId {
    const saved = self.expect.template_ok;
    defer self.expect.template_ok = saved;
    if (e.isKind(.template)) self.expect.template_ok = e;
    return PatternCheck.synthExpr(self, e);
}

pub fn checkArray(self: *Checker, node: Sexp, expected: TypeId) Error!?TypeId {
    const et = self.ctx.types.get(expected);
    if (et != .array) return null;
    const elems = ir.Array.elems(node);
    if (sema.arrayLen(self.ctx, et.array)) |n| {
        if (elems.len != n) try self.errAt(node, "array literal has {d} element{s}; `{s}` needs {d}", .{ elems.len, CompatCheck.plural(elems.len), try self.tyName(expected), n });
    } else if (self.ctx.types.get(et.array.len) == .ct_param) {
        const len = try self.tyName(et.array.len);
        try self.errAt(node, "an array of compile-time length `{s}` is built with `[{s} of x]`, not a list of elements", .{ len, len });
    }
    for (elems) |e| try ViewCheck.checkExpr(self, e, et.array.elem);
    return expected;
}

/// `[n of x]`: an array of `n` copies of `x`, where `n` is a
/// compile-time integer. Its type is `[n]T` for `x`'s type `T`, or
/// the array type `expected`, whose length it must have. The element
/// is plain data: it is copied into every slot.
pub fn checkArrayFill(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
    const value = ir.ArrayFill.value(node);
    var r = self.resolver();
    const len = try r.resolveCtInt(ir.ArrayFill.size(node), .array_len);
    var elem: TypeId = undefined;
    if (expected) |ex| {
        elem = self.ctx.types.get(ex).array.elem;
        try ViewCheck.checkExpr(self, value, elem);
    } else {
        const ty = try PatternCheck.synthExpr(self, value);
        elem = ExprCheck.canonical(self, ty);
        if (elem != ty) try ViewCheck.checkExpr(self, value, elem);
        switch (self.ctx.types.get(elem)) {
            .none_literal, .void, .noreturn => {
                try self.errAt(value, "the element of `[n of x]` needs a type; give it where the array goes (`xs: [n]T? = [n of none]`)", .{});
                return self.t().invalid_id;
            },
            else => {},
        }
    }
    if (self.isPoison(elem) or self.isPoison(len)) return self.t().invalid_id;
    if (try ViewCheck.cannotCopy(self, elem, self.startOf(value), "copies into every slot of `[n of x]` a value")) {
        try ViewCheck.notDuplicated(self, value, "`[n of x]` copies its element into every slot", elem, "`for 0..n` with `!xs.push(+x)`, into a List", ", or write the elements out, `[+x, +x]`");
        return self.t().invalid_id;
    }
    const ty = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
    // An expected array type was checked where it was spelled or
    // inferred.
    if (expected == null and !self.expect.under_poison and !try sema.checkArrayBytes(self.ctx, self.startOf(node), ty)) return self.t().invalid_id;
    if (expected) |ex| if (ex != ty) {
        try self.errAt(node, "`{s}` has length `{s}`; `{s}` needs `{s}`", .{ sourceText(self, node), try self.tyName(len), try self.tyName(ex), try self.tyName(self.ctx.types.get(ex).array.len) });
        return self.t().invalid_id;
    };
    return ty;
}

/// A List made through a `List[T, inline: n]` named in the call,
/// `List[T, inline: n](a)` or `List[T, inline: n].filled(k, x)`, is
/// that instance, which the List's own signature, of `List[T]`, does
/// not say.
pub fn inlineResult(self: *Checker, callee: Sexp, ty: TypeId) Error!TypeId {
    const inst_node = if (callee.isKind(.member)) ir.Member.object(callee) else callee;
    if (!inst_node.isKind(.inst) and !inst_node.isKind(.index)) return ty;
    const inst = self.ctx.instanceOf(inst_node) orelse return ty;
    const named = switch (inst) {
        .type => |inst_ty| inst_ty,
        else => return ty,
    };
    const want = switch (self.ctx.types.get(named)) {
        .parameterized_nominal => |pn| pn,
        else => return ty,
    };
    if (want.inline_len == 0) return ty;
    const got = switch (self.ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return ty,
    };
    if (got.sym != want.sym or got.inline_len != 0 or !std.mem.eql(TypeId, got.args, want.args)) return ty;
    return named;
}

/// A call whose type is `T!` must be the operand of `!` or `catch`:
/// the failure path is never implicit.
pub fn synthCall(self: *Checker, node: Sexp) Error!TypeId {
    const handled = CompatCheck.sameNode(node, self.expect.handled);
    const saved = self.expect.current_call;
    self.expect.current_call = node;
    defer self.expect.current_call = saved;
    const saved_callee = self.expect.callee_node;
    self.expect.callee_node = null;
    defer self.expect.callee_node = saved_callee;
    // What the call reaches, recorded where it resolves to a Rig
    // function (`noteTarget`); any other call reaches none.
    try self.ctx.record(.call_targets, node, .none);
    // `>t` (the wrapper's `<t.wait()`), `<t.cancel()`: the move of `t` there takes a task
    // given a write view.
    const saved_wait = self.expect.task_wait;
    defer self.expect.task_wait = saved_wait;
    const callee_node = ir.Call.callee(node);
    const member_name = if (callee_node.isKind(.member)) self.text(ir.Member.name(callee_node)) else "";
    if (std.mem.eql(u8, member_name, "wait") or std.mem.eql(u8, member_name, "cancel")) {
        const obj = ir.Member.object(callee_node);
        if (obj.isKind(.move)) self.expect.task_wait = ir.Move.operand(obj);
    }
    try self.checkShorthands(ir.Call.args(node));
    const ty = try inlineResult(self, callee_node, try StdFormCheck.synthCallInner(self, node));
    if (ir.Call.task(node) != .nil) return taskOf(self, node, ty);
    // Only a task that can fail can be stopped: one that cannot runs
    // to its end.
    if (std.mem.eql(u8, member_name, "cancel")) if (self.ctx.typeOf(ir.Member.object(callee_node))) |obj_ty| {
        const peeled = sema.unwrapViews(self.ctx, obj_ty);
        if (sema.isTask(self.ctx, peeled) and !self.isPoison(ty) and self.ctx.types.get(ty) != .fallible) {
            const obj = ir.Member.object(callee_node);
            const held = if (obj.isKind(.move)) ir.Move.operand(obj) else obj;
            try self.errAt(ir.Member.name(callee_node), "`{s}` cannot fail, so it cannot be canceled: it runs to its end; wait for it, `>{s}`", .{ try self.tyName(peeled), sourceText(self, held) });
            return self.t().invalid_id;
        }
    };
    // A call that gives several results stands only where each is
    // bound at once, or where they are returned whole.
    if (sema.resultsOf(self.ctx, ty) != null and !CompatCheck.sameNode(node, self.expect.results_ok)) {
        try StmtCheck.misplacedResults(self, node, ty);
        return self.t().invalid_id;
    }
    if (!handled and self.ctx.types.get(ty) == .fallible and rig.isWaitCall(node)) {
        const written = sourceText(self, node);
        try self.errAt(node, "the task `{s}` can fail: pass its failure on, `{s}!`, or handle it, `{s} catch ...`", .{ written[1..], written, written });
    } else if (!handled and self.ctx.types.get(ty) == .fallible) {
        const callee = ir.Call.callee(node);
        const name = try StdFormCheck.calleeName(self, callee);
        try self.errAt(callee, "fallible call to `{s}` must be wrapped with `!` (propagate) or `catch` (handle)", .{name});
        if (CompatCheck.sameNode(self.expect.maker_runtime.call, node)) {
            if (self.expect.maker_runtime.literal)
                try self.noteAt(self.expect.maker_runtime.arg, "`{s}` is not a plain string literal, so `{s}` can fail as the program runs; with a plain string literal it is checked as Rig compiles", .{ try ViewCheck.plainText(self, self.expect.maker_runtime.arg), try ViewCheck.plainText(self, node) })
            else
                try self.noteAt(self.expect.maker_runtime.arg, "`{s}` is not a constant, so `{s}` can fail as the program runs; with every argument a constant it is checked as Rig compiles", .{ try ViewCheck.plainText(self, self.expect.maker_runtime.arg), try ViewCheck.plainText(self, node) });
        }
        if (self.ctx.symbolOf(callee)) |id| {
            const sym = self.ctx.symbols.items[id];
            if (sym.decl_pos != sema.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared as fallible here", .{name});
        }
    }
    return ty;
}

/// `f(x)&`: the call made a task, of type `Task[T]` for the call's
/// result `T`, a fallible one too, whose failure `>t!` passes
/// on (docs/design/concurrency.md, "Tasks"). The callee is a Rig function or
/// method, and every argument, and a method's self (`@`), may go to
/// another core as it is passed, or the task is local, pinned to this
/// thread (`crossCheck`).
pub fn taskOf(self: *Checker, node: Sexp, ty: TypeId) Error!TypeId {
    if (self.isPoison(ty)) return self.t().invalid_id;
    const callee = ir.Call.callee(node);
    if (sema.resultsOf(self.ctx, ty) != null) {
        try self.errAt(callee, "a call that gives several results cannot be a task; make it a call, or have the function give one value", .{});
        return self.t().invalid_id;
    }
    // `c.m(x)&` through an actor's handle: the call as a task, which
    // holds a handle of its own; `actorCall` checked what crosses, and
    // a `!` marks the call, making no write view.
    if (self.ctx.isActorCall(node)) {
        self.ctx.makes_tasks = true;
        return self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.task, .args = try self.ctx.dupeIds(&.{ty}) } });
    }
    const target = self.ctx.callTargetOf(node) orelse .none;
    // A call through an API reaches a Rig method through its witness.
    const static: ?sema.Dispatch.Static = if (self.ctx.dispatchOf(node)) |d| switch (d) {
        .static => |st| st,
        .direct, .dynamic => null,
    } else null;
    // A call through an API object's table: its self is the object,
    // which goes to no task (`sema.blockerIn`).
    const dynamic: ?sema.Dispatch.Dynamic = if (self.ctx.dispatchOf(node)) |d| switch (d) {
        .dynamic => |dy| dy,
        else => null,
    } else null;
    if (target != .function and static == null and dynamic == null) {
        try self.errAt(callee, "a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`", .{});
        return self.t().invalid_id;
    }
    if (!try ExprCheck.waitHoldsStop(self, self.startOf(callee), ty, try StdFormCheck.calleeName(self, callee))) return self.t().invalid_id;
    var parts: std.ArrayList(Sexp) = .empty;
    // A method's self, `@`, is passed as the method takes it.
    var self_mode: sema.SelfMode = .none;
    const has_self = callee.isKind(.member) and !(if (static) |st| st.self_arg else if (dynamic) |dy| dy.self_arg else false);
    if (has_self) {
        const obj = ir.Member.object(callee);
        try parts.append(self.ctx.arena.allocator(), obj);
        if (static) |st| {
            self_mode = st.self_mode;
        } else if (dynamic) |dy| {
            self_mode = dy.self_mode;
        } else if (self.ctx.typeOf(obj)) |obj_ty| self_mode = sema.methodSelfMode(self.ctx, obj_ty, self.text(ir.Member.name(callee))) orelse .none;
    }
    for (ir.Call.args(node)) |arg| try parts.append(self.ctx.arena.allocator(), if (arg.isKind(.kwarg)) ir.get(arg, .value) else arg);
    // A task given a write view keeps its write loan while it runs, and
    // no value holds a write view: it stays where it is bound, and is
    // only waited for there. A `!x` that puts only a read loan on `x`
    // (`recordLoan`) gives the task nothing to write, as `?x` does not.
    const views_write = for (parts.items) |part| {
        if (part.isKind(.write)) {
            if (self.ctx.loanOf(part) == .write) break true;
            continue;
        }
        if (self.ctx.typeOf(part)) |pt| if (self.ctx.types.get(pt) == .write_view) break true;
    } else false;
    if (views_write) {
        if (!CompatCheck.sameNode(node, self.expect.local_value)) {
            // A method's self given a write view shows its `!`, which
            // the call's own text, from its self on, leaves out.
            const shown = sourceText(self, node);
            const bang = has_self and ir.Member.object(callee).isKind(.write) and !std.mem.startsWith(u8, shown, "!");
            try self.errAt(callee, "this task holds a write view while it runs, so it stays where it is bound: `t = {s}{s}`, then `>t`", .{ if (bang) "!" else "", shown });
            return self.t().invalid_id;
        }
        if (self.ctx.symbolOf(self.expect.local_target)) |id| try self.write_tasks.put(self.ctx.arena.allocator(), id, {});
    }
    var gone: std.ArrayList(Checker.Gone) = .empty;
    for (parts.items, 0..) |part, i| {
        const part_ty = self.ctx.typeOf(part) orelse continue;
        if (self.isPoison(part_ty)) continue;
        const as_self: ?sema.SelfMode = if (i == 0 and has_self) self_mode else null;
        if (!try StdFormCheck.crossCheck(self, node, part, part_ty, as_self, &gone, parts.items)) return self.t().invalid_id;
    }
    // Whether the task is local is decided by all its parts, once for
    // every instance of a generic body.
    for (gone.items) |g| try StdFormCheck.requireTask(self, g.ty, g.how, g.pos, g.passed, self.ctx.isLocalTask(node));
    // A task that may run on another core hands its result back to
    // the one that waits for it, so the result moves (as `par.map`'s
    // values and an actor call's do); a local task's stays on this
    // thread.
    if (!self.ctx.isLocalTask(node)) {
        const result = if (self.ctx.types.get(ty) == .fallible) self.ctx.types.get(ty).fallible.ok else ty;
        if (try sema.crossingBlocker(self.ctx, result, .moves)) |blocker| {
            if (try StdFormCheck.statedCrossing(self, blocker, .moves, self.startOf(callee))) return self.t().invalid_id;
            try self.errAt(callee, "`{s}` may run on another core, so what it gives must be sent to the task that waits for it: `{s}` {s}", .{ sourceText(self, node), try self.tyName(result), try StdFormCheck.blockerReason(self, blocker, false, if (blocker == result) "is" else null) });
            return self.t().invalid_id;
        }
        try StdFormCheck.requireTask(self, result, .moves, self.startOf(callee), "is given back by a task", false);
    }
    self.ctx.makes_tasks = true;
    return self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.task, .args = try self.ctx.dupeIds(&.{ty}) } });
}

/// Call a value: a function-typed binding, a closure, or an owned
/// closure handle.
pub fn callValue(self: *Checker, callee: Sexp, ty: TypeId, args: []const Sexp, name: []const u8) Error!TypeId {
    const pos = self.startOf(callee);
    if (self.isPoison(ty)) return skipCall(self, args);
    const f = sema.calledFn(self.ctx, ty) orelse
        return badCall(self, args, pos, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(ty) });
    var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
    defer scratch.deinit();
    try checkArgs(self, args, f, .{}, name, pos, .{ .origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f) });
    return f.returns;
}

/// A call that cannot be checked: its arguments are still checked on
/// their own, and it has no type.
pub fn skipCall(self: *Checker, args: []const Sexp) Error!TypeId {
    try synthArgs(self, args);
    return self.t().invalid_id;
}

/// `skipCall` for a call that passes `f`, the function it calls,
/// given `params` (a `sub` when `sub`), and cannot build on what `f`
/// gives: a closure literal there is checked aloud given `params`
/// (`closureErrors`), after the arguments before it, so its own
/// errors are reported in order, and not again with no parameter
/// types (`closures_reported`).
pub fn skipClosureCall(self: *Checker, args: []const Sexp, f: Sexp, params: []const TypeId, sub: bool) Error!TypeId {
    if (!f.isKind(.lambda)) return try skipCall(self, args);
    for (args, 0..) |a, i| {
        const e = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (!CompatCheck.sameNode(e, f)) continue;
        try synthArgs(self, args[0..i]);
        try StdFormCheck.closureErrors(self, f, params, sub);
        try synthArgs(self, args[i + 1 ..]);
        break;
    } else try synthArgs(self, args);
    return self.t().invalid_id;
}

/// Report why a call cannot be checked, at `at` (a node or a
/// position), then `skipCall`.
pub fn badCall(self: *Checker, args: []const Sexp, at: anytype, comptime fmt: []const u8, fmt_args: anytype) Error!TypeId {
    if (@TypeOf(at) == Sexp) try self.errAt(at, fmt, fmt_args) else try self.err(at, fmt, fmt_args);
    return skipCall(self, args);
}

/// The arguments of a call that cannot be checked: each is checked
/// on its own, and nothing that needs a parameter's type (`[]` has
/// none, and whether a slice is viewed depends on it) is reported.
/// A closure literal whose errors were reported is left out
/// (`closures_reported`).
pub fn synthArgs(self: *Checker, args: []const Sexp) Error!void {
    const saved = self.expect.under_poison;
    const saved_view = self.expect.view_arg;
    defer {
        self.expect.under_poison = saved;
        self.expect.view_arg = saved_view;
    }
    self.expect.under_poison = true;
    for (args) |a| {
        const e = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (e.isKind(.array) and ir.Array.elems(e).len == 0) continue;
        const literal = if (e.isKind(.share)) ir.Share.operand(e) else e;
        if (literal.isKind(.lambda) and self.ctx.closures_reported.contains(CompatCheck.nodeId(literal))) continue;
        self.expect.view_arg = e;
        _ = try PatternCheck.synthExpr(self, e);
    }
}

/// `I32(x)`, `U8(x)`, `Float(n)`, `Int(f)`: a numeric conversion to
/// the named type. A conversion to an integer type is checked: a
/// value that does not fit panics when the program runs, and a float
/// is truncated toward zero; a constant argument is converted now,
/// so it must fit. A conversion to a float type rounds to the nearest
/// value, a constant argument included.
pub fn checkConversion(self: *Checker, target: TypeId, name: []const u8, args: []const Sexp, pos: u32) Error!TypeId {
    if (args.len != 1 or args[0].isKind(.kwarg)) {
        try self.err(pos, "`{s}(x)` converts one number; it takes exactly one argument", .{name});
        try synthArgs(self, args);
        return target;
    }
    const arg = args[0];
    // A string literal takes the target type, as an integer literal
    // does: `U8('>')` is a byte (`byteString`).
    if (arg == .src and sema.isStringLiteralText(self.text(arg)) and CompatCheck.isU8(self.ctx, target)) {
        try ViewCheck.checkExpr(self, arg, target);
        return target;
    }
    const from = try ViewCheck.synthValue(self, arg);
    if (self.isPoison(from)) return target;
    if (enumValues(self, from)) |values| {
        const shown = try ViewCheck.plainText(self, arg);
        const bare = sema.unwrapViews(self.ctx, from);
        if (isBuiltinEnumTy(self, bare)) {
            try self.errAt(arg, "`{s}(x)` takes a declared enum's value; the built-in enum `{s}` has no integer value", .{ name, try self.tyName(bare) });
        } else if (!values) {
            try self.errAt(arg, "`{s}(x)` takes a plain enum's value; `{s}` has variants with payloads, which have no integer value", .{ name, try self.tyName(bare) });
        } else if (self.ctx.types.get(target) != .int) {
            try self.errAt(arg, "`{s}(x)` converts an enum's value to an integer type only; write `{s}(Int(...))`", .{ name, name });
        } else if (try variantValue(self, arg)) |v| if (!CompatCheck.holdsInt(self.ctx, target, v)) {
            try self.errAt(arg, "`{s}` has the value {d}, which does not fit in `{s}`", .{ shown, v, try self.tyName(target) });
        };
        return target;
    }
    // A slot's number: `Int(s)`.
    if (self.ctx.types.get(sema.unwrapViews(self.ctx, from)) == .slot) return target;
    if (!sema.isNumeric(self.ctx, from)) {
        try self.errAt(arg, "`{s}(x)` converts a number; `x` has type `{s}`", .{ name, try self.tyName(from) });
    } else if (self.ctx.types.get(target) == .int) {
        // A literal takes the target type; a typed argument keeps its
        // own, and only its value, when constant, must fit.
        if (!sema.isInteger(self.ctx, from)) {
            try checkFloatFits(self, arg, target);
        } else if (from == self.t().int_literal_id or sema.constInt(self.ctx, arg) != .not_constant) try BuiltinCheck.checkLiteralFits(self, arg, target);
    }
    return target;
}

pub fn enumValues(self: *Checker, ty: TypeId) ?bool {
    return sema.enumValues(self.ctx, ty);
}

/// Whether `ty` is a plain enum, every variant without a payload: one
/// whose values are integers (`enumValues`), or a built-in one,
/// `Endian`, `Arch`, `Os`, or `Feature`, whose values are Zig's. Each
/// has `e.text` and `E.from_text(word)`.
pub fn hasVariantNames(self: *Checker, ty: TypeId) bool {
    return enumValues(self, ty) == true or isBuiltinEnumTy(self, ty);
}

/// Whether `ty`, read through views, is a built-in enum, `Endian`,
/// `Arch`, `Os`, or `Feature`: no payloads, but variants that are Zig's,
/// with no integer Rig fixes.
pub fn isBuiltinEnumTy(self: *Checker, ty: TypeId) bool {
    const decl = sema.nominalDecl(self.ctx, sema.unwrapViews(self.ctx, ty)) orelse return false;
    return sema.isBuiltinEnum(decl.ctx, decl.ctx.ref(decl.sym));
}

/// The value of a variant named through its type, `Status.ok` or
/// `lib.Status.ok`; null for any other expression.
pub fn variantValue(self: *Checker, e: Sexp) Error!?Wide {
    if (!e.isKind(.member)) return null;
    const nt = (try namedType(self, ir.Member.object(e))) orelse return null;
    const name = self.text(ir.Member.name(e));
    const fields = nt.sym.fields orelse return null;
    return fields[(try sema.findMember(self.ctx, fields, name, .variant)) orelse return null].value;
}

/// A constant float converted to integer type `target`: its integer
/// part must fit.
pub fn checkFloatFits(self: *Checker, arg: Sexp, target: TypeId) Error!void {
    const f = CompatCheck.constFloatOf(self.ctx.source, arg) orelse return;
    const b = CompatCheck.intBounds(self.ctx.types.get(target).int);
    const whole = @trunc(f);
    if (whole >= CompatCheck.wideToFloat(f64, b.min) and whole < CompatCheck.wideToFloat(f64, b.max) + 1) return;
    if (@abs(f) < 1e18) {
        try self.errAt(arg, "`{d}` does not fit in `{s}`", .{ f, try self.tyName(target) });
    } else try self.errAt(arg, "`{e}` does not fit in `{s}`", .{ f, try self.tyName(target) });
}

/// `swap(!a, !b)`: exchange the values of two places of one type.
/// `old = swap(!x, v)`: put `v` in the place and give back what was
/// there, owned. The second argument is a place when it is a write
/// view, `!b` or a held `!T` (`sema.swapsTwoPlaces`), and a value
/// otherwise.
/// What it exchanges is decided here, once, and recorded
/// (`SemContext.swapCallOf`), for the ownership checker and emit.
pub fn checkSwap(self: *Checker, call: Sexp, callee: Sexp, args: []const Sexp) Error!TypeId {
    if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) {
        try self.ctx.record(.builtins, call, .{ .swap = .value });
        return badCall(self, args, callee, "`swap` takes a write view of a place, and another to exchange it with, `swap(!a, !b)`, or a value to put in it, `old = swap(!x, v)`", .{});
    }
    const places = sema.swapsTwoPlaces(self.ctx, args[1], StdFormCheck.heldViewType(self, args[1]));
    try self.ctx.record(.builtins, call, .{ .swap = if (places) .places else .value });
    const a = (try StdFormCheck.swapPlace(self, args[0], "swap")) orelse return skipCall(self, args[1..]);
    if (places) {
        const b = (try StdFormCheck.swapPlace(self, args[1], "swap")) orelse return self.t().void_id;
        if (a != b) try self.errAt(args[1], "`swap` exchanges two places of one type; got `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
        return self.t().void_id;
    }
    try ViewCheck.checkExpr(self, args[1], a);
    return a;
}

/// The parameters of function `sym`, declared in `source`.
pub fn paramsOf(sym: sema.Symbol, source: []const u8) Checker.ParamInfo {
    return .{ .names = sym.param_names, .defaults = sym.param_defaults, .source = source, .durations = sym.param_durations, .group_pos = if (sym.flags.has_groups) sym.decl_pos else null };
}

/// The parameters of method `f`, declared in `source`, after the
/// self when `skip_self`.
pub fn methodParams(f: Field, skip_self: bool, source: []const u8) Checker.ParamInfo {
    const skip: usize = @intFromBool(skip_self);
    return .{
        .names = if (f.param_names) |n| n[@min(skip, n.len)..] else null,
        .defaults = if (f.param_defaults) |d| d[@min(skip, d.len)..] else null,
        .source = source,
        .durations = f.param_durations >> @intCast(skip),
        .group_pos = if (f.has_groups) f.decl_pos else null,
        .group_skip = @intCast(skip),
    };
}

/// `info` with its groups read from the module that declares the
/// callee (`ParamInfo.group_pos`), whose source is `info.source`.
pub fn withGroups(self: *Checker, info: Checker.ParamInfo) Checker.ParamInfo {
    const at = info.group_pos orelse return info;
    var out = info;
    const home: *const SemContext = if (info.source.ptr == self.ctx.source.ptr) self.ctx else blk: {
        for (self.ctx.foreign_semas.items.items) |m| if (m) |fc| if (fc.source.ptr == info.source.ptr) break :blk fc;
        return info;
    };
    const g = home.group_params.get(at) orelse return info;
    out.groups = g[@min(info.group_skip, g.len)..];
    return out;
}

/// The names a diagnostic gives the parameters of `info`, as `from`
/// and `keeps` name them: a group's field by its group's name.
pub fn clauseNames(self: *Checker, info: Checker.ParamInfo) Error!?[]const []const u8 {
    const names = info.names orelse return null;
    const groups = info.groups orelse return names;
    const out = try self.ctx.arena.allocator().dupe([]const u8, names);
    for (out, 0..) |*n, i| if (i < groups.len) if (groups[i]) |g| {
        n.* = g.group;
    };
    return out;
}

/// The first parameter of `f` that is a group's field and takes a
/// duration, which a unit's keyword never fills, or null.
pub fn groupDuration(self: *Checker, f: FunctionType, info: Checker.ParamInfo) ?usize {
    if (info.names == null) return null;
    for (f.params, 0..) |p, i| {
        if (info.group(i) == null or i >= info.names.?.len) continue;
        if (sema.durationParam(self.ctx, p) != null) return i;
    }
    return null;
}

/// Arguments against a signature: arity, types, keyword arguments
/// by parameter name, and defaults for omitted parameters. A call
/// that uses keywords or defaults records its argument slots, and
/// every complete call what fills each parameter (`CallParams`).
pub fn checkArgs(self: *Checker, args: []const Sexp, f: FunctionType, info_grouped: Checker.ParamInfo, callee: []const u8, pos: u32, site: Checker.CallSite) Error!void {
    const info_in = withGroups(self, info_grouped);
    if (try self.optionsCall(args, info_in, callee)) return;
    var info = info_in;
    const call = self.expect.current_call;
    // A task's arguments are made as it starts, and its failure is
    // taken where it is waited, so a conversion joins no failure there.
    if (info.durations != 0) info.fold = if (call != null and ir.Call.task(call.?) != .nil) null else StdFormCheck.durationFold(self, f.returns, info.datetime);
    const mark = self.ctx.diagnostics.items.len;
    const saved_slot = self.expect.slot;
    defer self.expect.slot = saved_slot;
    self.expect.slot = .{ .call = call orelse .nil, .params = site.declared, .views = try argViews(self, args, f, info) };
    const retains = StdFormCheck.callRetains(self, f, self.expect.view_recv);
    const recv_param = self.expect.view_recv;
    const views = self.expect.view_call and !retains;
    self.expect.view_call = false;
    self.expect.view_recv = null;
    var first_kw: ?usize = null;
    for (args, 0..) |a, i| {
        if (a.isKind(.kwarg)) {
            if (first_kw == null) first_kw = i;
        } else if (first_kw != null and !trailingClosure(args, i)) {
            try self.errAt(a, "positional arguments must come before keyword arguments; only a closure written last may follow them", .{});
            try synthArgs(self, args);
            return;
        }
    }
    // A closure written last fills the parameter that takes a
    // function (`closureParam`): after the keyword arguments, or where
    // its position would give an option.
    const trailing: ?Sexp = if (first_kw != null and !args[args.len - 1].isKind(.kwarg))
        args[args.len - 1]
    else if (first_kw == null and closureParam(self, args, f.params, info) != null)
        args[args.len - 1]
    else
        null;
    const positional = args[0 .. first_kw orelse args.len - @intFromBool(trailing != null)];
    const keyword = args[positional.len .. args.len - @intFromBool(trailing != null)];
    if (keyword.len > 0 and info.names == null) {
        try self.errAt(keyword[0], "`{s}` takes positional arguments only", .{callee});
        try synthArgs(self, args);
        return;
    }
    // A name given twice is the call's fault, reported alone: counted,
    // its arguments would be too many, or one parameter left unfilled.
    const unit_param = info.unitParam();
    var repeated = false;
    for (keyword, 0..) |kw, k| {
        const kname = self.text(ir.Kwarg.name(kw));
        for (keyword[0..k]) |prev| {
            if (!std.mem.eql(u8, self.text(ir.Kwarg.name(prev)), kname)) continue;
            if (unit_param != null and sema.duration.unitNs(kname) != null) {
                try self.errAt(ir.Kwarg.name(kw), "the unit `{s}:` is given twice: a duration's units add up, each given at most once", .{kname});
            } else try self.errAt(ir.Kwarg.name(kw), "parameter `{s}` of `{s}` is given twice", .{ kname, callee });
            repeated = true;
            break;
        }
    }
    if (repeated) return synthArgs(self, args);
    // A duration is written once: bare, by its parameter's name, or
    // with units' keywords, which add up (`sema.DurationParts`).
    var units: usize = 0;
    if (unit_param) |u| {
        // The forms given in the order written: bare, by name, and the
        // units, which are one form however many there are.
        const own = if (info.names) |n| (if (u < n.len) n[u] else "") else "";
        var forms: [3][]const u8 = undefined;
        var at: [3]Sexp = undefined;
        var count: usize = 0;
        if (u < positional.len) {
            forms[0] = try ViewCheck.plainText(self, positional[u]);
            at[0] = positional[u];
            count = 1;
        }
        for (keyword) |kw| {
            const kname = self.text(ir.Kwarg.name(kw));
            const is_unit = sema.duration.unitNs(kname) != null;
            if (!is_unit and !std.mem.eql(u8, kname, own)) continue;
            if (is_unit) {
                units += 1;
                if (units > 1) continue;
            }
            forms[count] = if (is_unit) try StdFormCheck.unitsText(self, keyword) else try ViewCheck.plainText(self, kw);
            at[count] = kw;
            count += 1;
        }
        if (count > 1) {
            try self.errAt(at[1], "`{s}` takes one duration: `{s}` or `{s}`, not both", .{ callee, forms[0], forms[1] });
            return synthArgs(self, args);
        }
    } else if (info.durations != 0) {
        // Units, or `days:` and `weeks:`, given to a callee of two or
        // more durations, said once with the fix for all of them.
        var units_at: ?Sexp = null;
        var calendar = false;
        for (keyword) |kw| {
            const kname = self.text(ir.Kwarg.name(kw));
            const cal = sema.duration.isCalendar(kname) and for (info.names.?) |n| {
                if (std.mem.eql(u8, n, kname)) break false;
            } else true;
            if (sema.duration.unitNs(kname) == null and !cal) continue;
            calendar = calendar or cal;
            if (units_at == null) units_at = ir.Kwarg.name(kw);
        }
        if (units_at) |kname_node| {
            // The first duration parameter given neither by position
            // nor by its name.
            const free: ?[]const u8 = for (info.names.?, 0..) |n, i| {
                if (!info.isDuration(i) or i < positional.len) continue;
                const named = for (keyword) |other| {
                    if (std.mem.eql(u8, self.text(ir.Kwarg.name(other)), n)) break true;
                } else false;
                if (!named) break n;
            } else null;
            const form = if (calendar) try StdFormCheck.calendarFix(self, keyword) else try StdFormCheck.unitsText(self, keyword);
            if (free) |n| {
                try self.errAt(kname_node, "`{s}` takes {d} durations, so each is given by its own name: `{s}: time.duration({s})`", .{ callee, @popCount(info.durations), n, form });
            } else try self.errAt(kname_node, "`{s}` takes {d} durations, so each is given by its own name, not by a unit's keyword: give `time.duration({s})` to the one it is for", .{ callee, @popCount(info.durations), form });
            return synthArgs(self, args);
        }
    }
    // The parts of a duration fill one parameter: of a callee that
    // takes one, the keywords that name no parameter count as one
    // argument, the units' keywords, `days:`, or a misspelling, each
    // said below.
    var unnamed: usize = 0;
    if (unit_param != null) for (keyword) |kw| {
        const kname = self.text(ir.Kwarg.name(kw));
        for (info.names.?) |n| {
            if (std.mem.eql(u8, n, kname)) break;
        } else unnamed += 1;
    };
    const given = args.len - (unnamed -| 1);
    var required: usize = 0;
    for (0..f.params.len) |i| {
        if (info.default(i) == null) required += 1;
    }
    // A group's field left out, given by position, or named but no
    // parameter is said by name, below, as for a spread's call.
    if ((given > f.params.len and (info.groups == null or positional.len > f.params.len)) or (given < required and info.groups == null)) {
        if (required == f.params.len) {
            try self.err(pos, "call to `{s}` expects {d} argument{s}, got {d}", .{ callee, f.params.len, CompatCheck.plural(f.params.len), given });
        } else {
            try self.err(pos, "call to `{s}` expects {d} to {d} arguments, got {d}", .{ callee, required, f.params.len, given });
        }
        try synthArgs(self, args);
        return;
    }
    const slots = try self.ctx.arena.allocator().alloc(?sema.ArgSlot, f.params.len);
    @memset(slots, null);
    for (positional, 0..) |a, i| {
        slots[i] = .{ .arg = @intCast(i) };
        // A group's field is given by name (docs/design/options.md,
        // section 2).
        if (info.group(i)) |g| if (info.names) |names| if (i < names.len) {
            // A closure written last never fills a group's field.
            if (i == args.len - 1 and CompatCheck.stripSigil(a).isKind(.lambda)) {
                try self.errAt(a, "a closure written last fills the parameter that takes a function, and `{s}` has none: `{s}` is a field of group `{s}`, given by name", .{ callee, names[i], g.group });
                return synthArgs(self, args);
            }
            try self.errAt(a, "`{s}` is a field of group `{s}` of `{s}`, so it is given by name: `{s}: {s}`", .{ names[i], g.group, callee, names[i], try ViewCheck.plainText(self, a) });
            try StdFormCheck.checkArg(self, a, f, i, views);
            slots[i] = .{ .default = .{ .expr = .nil, .source = "" } };
            continue;
        };
        // A parameter with a default is an option, given by name
        // (SPEC "Functions").
        if (info.default(i) != null) if (info.names) |names| if (i < names.len) {
            const shown = try ViewCheck.plainText(self, a);
            // A function given last, where an option takes no function,
            // is meant for the parameter that takes one, which only a
            // closure fills by position.
            if (i == args.len - 1 and !takesFunction(self, f.params[i])) if (trailingParam(self, args, f.params, info.names, info.groups)) |cb| {
                const saved = self.expect.under_poison;
                self.expect.under_poison = true;
                const ty = ExprCheck.canonical(self, try PatternCheck.synthExpr(self, a));
                self.expect.under_poison = saved;
                if (takesFunction(self, sema.unwrapAccess(self.ctx, ty))) {
                    try self.errAt(a, "`{s}` has a default, so it is an option, given by name, and a function given last fills `{s}`: `{s}: {s}`", .{ names[i], names[cb], names[cb], shown });
                    return synthArgs(self, args);
                }
            };
            try self.errAt(a, "`{s}` has a default, so it is an option, given by name: `{s}: {s}`; to pass it by position, remove its default", .{ names[i], names[i], shown });
        };
        if (info.isDuration(i)) {
            _ = try StdFormCheck.checkDurationArg(self, a, f.params[i], null, info, false);
            continue;
        }
        try StdFormCheck.checkArg(self, a, f, i, views);
    }
    if (trailing) |a| {
        const idx = trailingParam(self, args, f.params, info.names, info.groups) orelse {
            try self.errAt(a, "a closure written after the keyword arguments fills the parameter that takes a function, and `{s}` has none left open", .{callee});
            try synthArgs(self, args);
            return;
        };
        slots[idx] = .{ .arg = @intCast(args.len - 1) };
        try StdFormCheck.checkArg(self, a, f, idx, views);
    }
    // The parts of a duration given by several units' keywords, and
    // whether each part is a constant the sum is checked by.
    var parts: std.ArrayList(u32) = .empty;
    var parts_ns: ?i128 = 0;
    var calendar = false;
    for (keyword, positional.len..) |kw, ai| {
        const kname_node = ir.Kwarg.name(kw);
        const kname = self.text(kname_node);
        // A unit's keyword fills the callee's one duration parameter.
        const unit = if (info.durations != 0) sema.duration.unitNs(kname) else null;
        const idx = (if (unit != null) unit_param else null) orelse for (info.names.?, 0..) |n, i| {
            if (std.mem.eql(u8, n, kname)) break i;
        } else {
            if (info.durations != 0) {
                // `days:` and `weeks:` are said once, with the fix for
                // every unit the call gives.
                if (sema.duration.isCalendar(kname)) {
                    if (!calendar) try StdFormCheck.calendarKeyword(self, kname_node, kname, keyword, if (info.zoneless) callee else null);
                    calendar = true;
                } else try StdFormCheck.badDurationKeyword(self, kname_node, kname, ir.Kwarg.value(kw), callee, if (unit_param) |u| (if (info.default(u) != null) info.names.?[u] else null) else null);
                // The duration it meant is not missing too.
                repeated = true;
            } else if (sema.duration.unitNs(kname) != null and groupDuration(self, f, info) != null) {
                // A unit's keyword never fills a group's field
                // (docs/design/options.md, section 4).
                const i = groupDuration(self, f, info).?;
                try self.errAt(kname_node, "`{s}:` cannot fill `{s}`, a field of group `{s}`: give it by name, `{s}: time.duration({s})`", .{ kname, info.names.?[i], info.group(i).?.group, info.names.?[i], try StdFormCheck.unitsText(self, keyword) });
                repeated = true;
            } else try self.errAt(kname_node, "`{s}` has no parameter `{s}`", .{ callee, kname });
            _ = try PatternCheck.synthExpr(self, ir.Kwarg.value(kw));
            continue;
        };
        if (unit != null and units > 1) {
            try parts.append(self.ctx.arena.allocator(), @intCast(ai));
            const ns = try StdFormCheck.checkDurationArg(self, ir.Kwarg.value(kw), f.params[idx], unit, info, true);
            parts_ns = if (parts_ns) |sum| (if (ns) |n| sum + n else null) else null;
            continue;
        }
        if (slots[idx] != null) {
            // A field given by position was said so; a spread's
            // keyword for it is no second error.
            if (slots[idx].? == .default) {
                _ = try PatternCheck.synthExpr(self, ir.Kwarg.value(kw));
                repeated = true;
                continue;
            }
            try self.errAt(kname_node, "parameter `{s}` of `{s}` is given twice", .{ kname, callee });
            _ = try PatternCheck.synthExpr(self, ir.Kwarg.value(kw));
            repeated = true;
            continue;
        }
        slots[idx] = .{ .arg = @intCast(ai) };
        if (info.isDuration(idx)) {
            _ = try StdFormCheck.checkDurationArg(self, ir.Kwarg.value(kw), f.params[idx], unit, info, false);
            continue;
        }
        try StdFormCheck.checkArg(self, ir.Kwarg.value(kw), f, idx, views);
    }
    if (repeated) return;
    if (unit_param) |u| if (units > 1) {
        const target = sema.durationParam(self.ctx, f.params[u]);
        const opt = if (target != null and !sema.isDurationType(self.ctx, f.params[u])) f.params[u] else sema.type_invalid;
        // A sum of constants is checked here; one with a part known
        // only as the program runs can leave the range, so it is
        // clamped in a wait, joins a call that can fail, and is
        // refused anywhere else.
        const how: sema.DurationHow = if (parts_ns != null) .total else if (info.waits) .clamped else if (info.fold) |into| .{ .folded = into } else {
            try self.errAt(args[parts.items[0]], "`{s}` can be beyond a `Duration`'s range as the program runs, and {s}: make the duration first, {s}, and pass that", .{ try StdFormCheck.unitsText(self, keyword), StdFormCheck.noFold(self), try StdFormCheck.durationFix(self, try StdFormCheck.unitsText(self, keyword)) });
            return;
        };
        slots[u] = .{ .parts = .{ .args = parts.items, .ty = target orelse sema.type_invalid, .opt = opt, .how = how } };
        if (parts_ns) |sum| try StdFormCheck.checkDurationSum(self, args[parts.items[0]], keyword, sum, info);
    };
    if (self.ctx.diagnostics.items.len == mark) try wastedClones(self, args, slots, f, recv_param);
    var complete = true;
    for (slots, 0..) |*slot, i| {
        if (slot.* != null) continue;
        if (info.default(i)) |d| {
            // A group's field's default is in its type's module.
            slot.* = .{ .default = .{ .expr = d, .source = if (info.group(i)) |g| g.source else info.source } };
            continue;
        }
        complete = false;
        const pname = if (info.names) |n| n[i] else "?";
        if (info.group(i)) |g| {
            try self.err(pos, "call to `{s}` is missing `{s}:`, a field of its group `{s}`, which has no default", .{ callee, pname, g.group });
            continue;
        }
        try self.err(pos, "call to `{s}` is missing an argument for parameter `{s}`", .{ callee, pname });
    }
    if (!complete) return;
    const call_node = call orelse return;
    const fills = try self.ctx.arena.allocator().alloc(sema.ParamFill, slots.len + @intFromBool(site.has_self));
    if (site.has_self) fills[0] = .self;
    for (slots, fills[@intFromBool(site.has_self)..]) |sl, *fill| fill.* = switch (sl.?) {
        .arg => |i| .{ .arg = i },
        .default => .default,
        .parts => .parts,
    };
    // A task keeps the loans of every argument, and of all of its
    // self, until it ends: its result is the call itself, still
    // running (docs/design/concurrency.md, "Loans and structure"), so
    // the paths of self a `from` names narrow nothing.
    var origins = site.origins;
    if (call_node.isKind(.call) and ir.Call.task(call_node) != .nil) {
        origins.result = sema.all_params;
        origins.declared = false;
        origins.self_paths = &.{};
    }
    const recorded: sema.CallParams = .{ .fills = fills, .origins = origins, .names = try clauseNames(self, info) };
    try self.ctx.record(.call_params, call_node, recorded);
    // A closure literal passed to a parameter the callee calls at most
    // once owns what it moves in, as its own parameters would.
    if (origins.once != 0) for (args, 0..) |a, ai| {
        const value = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (value.isKind(.lambda) and recorded.fillsOnce(ai)) try self.ctx.recordOnceClosure(value);
    };
    // What the call may store outlives its statement. A place viewed
    // by a parameter the call may keep is viewed with `?` written (Core
    // sentence 4): one its callee's `keeps` names, and, where nothing
    // narrows the stores, any view parameter the call may store by its
    // type (a function value, an owned closure, a built-in generic's
    // method at an instance whose `T` is a view).
    if (self.ctx.diagnostics.items.len == mark) {
        for (args, 0..) |a, i| {
            if (!recorded.stores(i)) continue;
            const value = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
            const param: ?usize = for (slots, 0..) |sl, k| {
                if (sl.? == .arg and sl.?.arg == i) break k;
            } else null;
            const viewed = if (param) |k| sema.viewParam(self.ctx, f.params[k]) else false;
            if ((recorded.keepsViewed(i) or viewed) and ViewCheck.implicitArgument(self, value)) {
                try ViewCheck.reportKept(self, call_node, value, .{ .stored = callee });
                continue;
            }
            try ViewCheck.keptViews(self, value, .{ .stored = callee });
        }
    }
    if (keyword.len == 0 and args.len == f.params.len) return;
    const out = try self.ctx.arena.allocator().alloc(sema.ArgSlot, slots.len);
    for (slots, out) |s, *o| o.* = s.?;
    try self.ctx.record(.call_slots, call_node, out);
}

/// `peek(+w)`: a clone into a read view (`?T`, `[]T`, `?String`) that
/// makes a new owner is made only to be read and dropped, so the call
/// views the original, `?w`. The clone stays where the same call makes
/// a write view of the original or moves it (`g(+p, !p)`): it keeps the
/// views apart. It stays too where it is made through a view and the
/// call writes or moves anything (`!m.take(+v.key)`, `v` a view of
/// `m`): the clone ends the view before the write starts (Core §6).
/// `recv` is a method's self parameter, null for a function.
pub fn wastedClones(self: *Checker, args: []const Sexp, slots: []const ?sema.ArgSlot, f: FunctionType, recv: ?TypeId) Error!void {
    const call = self.expect.current_call orelse return;
    // A task holds its arguments while it runs.
    if (call.isKind(.call) and ir.Call.task(call) != .nil) return;
    for (slots, 0..) |sl, k| {
        const i = switch (sl orelse continue) {
            .arg => |i| i,
            .default, .parts => continue,
        };
        const value = if (args[i].isKind(.kwarg)) ir.Kwarg.value(args[i]) else args[i];
        if (!value.isKind(.clone) or !sema.readViewField(self.ctx, f.params[k])) continue;
        const operand = ir.get(value, .operand);
        if (!clonesOwner(self, operand)) continue;
        const root = CompatCheck.placeRoot(operand) orelse continue;
        if (writesRoot(self, call, args, i, recv, self.text(root))) continue;
        if (throughView(self, root) and writesRoot(self, call, args, i, recv, null)) continue;
        try self.errAt(value, "pass `{s}` instead: a clone into a read view is only read, then dropped", .{try viewedText(self, operand)});
    }
}

/// `(+w).total()`, a clone into a method's read self: the method is
/// called on the original, `w.total()`, unless an argument makes a
/// write view of it or moves it, or, for a clone made through a view,
/// makes any write view or moves anything.
pub fn wastedCloneSelf(self: *Checker, obj: Sexp, args: []const Sexp) Error!void {
    if (!obj.isKind(.clone)) return;
    const call = self.expect.current_call orelse return;
    if (call.isKind(.call) and ir.Call.task(call) != .nil) return;
    const operand = ir.get(obj, .operand);
    if (!clonesOwner(self, operand)) return;
    const root = CompatCheck.placeRoot(operand) orelse return;
    const through = throughView(self, root);
    for (args) |a| {
        const value = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (writesName(self, value, self.text(root)) or (through and writesName(self, value, null))) return;
    }
    try self.errAt(obj, "call the method on `{s}` instead: a clone into a read self is only read, then dropped", .{sourceText(self, operand)});
}

/// Whether `+e` makes a new owner, a String's bytes or a value's parts
/// copied (`sema.cloneable`), not a bit copy or a handle's count.
pub fn clonesOwner(self: *Checker, e: Sexp) bool {
    const ty = self.ctx.typeOf(e) orelse return false;
    return switch (sema.cloneable(self.ctx, ty)) {
        .text, .deep => true,
        else => false,
    };
}

/// How `?e` reads in a call: a read view held by a name is passed on
/// bare, any other place with `?`.
pub fn viewedText(self: *Checker, e: Sexp) Error![]const u8 {
    const shown = sourceText(self, e);
    if (self.ctx.typeOf(e)) |ty| if (sema.readViewField(self.ctx, ty)) return shown;
    return self.ctx.arena.allocator().print("?{s}", .{shown});
}

/// Whether a clone rooted at the name `root` is made through a view:
/// one the name holds, which may view what the call writes.
pub fn throughView(self: *Checker, root: Sexp) bool {
    const ty = self.ctx.typeOf(root) orelse return false;
    return sema.mayHoldView(self.ctx, ty);
}

/// Whether call `call` makes a write view of the place rooted at
/// `root` (any place, when null), or moves it, other than in its
/// argument `skip`: through another argument, a closure that names it,
/// or a self taken to write or consumed.
pub fn writesRoot(self: *Checker, call: Sexp, args: []const Sexp, skip: usize, recv: ?TypeId, root: ?[]const u8) bool {
    for (args, 0..) |a, j| {
        if (j == skip) continue;
        if (writesName(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a, root)) return true;
    }
    const r = recv orelse return false;
    if (!call.isKind(.call)) return false;
    const callee = ir.Call.callee(call);
    if (!callee.isKind(.member)) return false;
    const obj = ir.Member.object(callee);
    const takes = switch (self.ctx.types.get(r)) {
        .read_view, .slice, .string_view => obj.isKind(.write) or obj.isKind(.move),
        else => true,
    };
    if (!takes) return writesName(self, obj, root);
    const name = root orelse return true;
    const at = CompatCheck.placeRoot(obj) orelse return writesName(self, obj, root);
    return std.mem.eql(u8, self.text(at), name) or writesName(self, obj, root);
}

/// Whether `e` makes a write view of a place rooted at `root` (any
/// place, when null), moves one, or holds a closure that names it.
pub fn writesName(self: *Checker, e: Sexp, root: ?[]const u8) bool {
    if (e == .src) return false;
    const h = e.kind() orelse return false;
    switch (h) {
        .write, .move => if (CompatCheck.placeRoot(ir.get(e, .operand))) |at| if (root == null or std.mem.eql(u8, self.text(at), root.?)) return true,
        .lambda => return if (root) |name| namesLeaf(self, e, name) else false,
        else => {},
    }
    for (e.items()) |c| if (writesName(self, c, root)) return true;
    return false;
}

/// Whether `e` holds a leaf whose text is `name`.
pub fn namesLeaf(self: *Checker, e: Sexp, name: []const u8) bool {
    if (e == .src) return std.mem.eql(u8, self.text(e), name);
    if (e != .list) return false;
    for (e.items()) |c| if (namesLeaf(self, c, name)) return true;
    return false;
}

/// A method's parameters as its type declares them, after the first
/// `skip`, when the type is this module's: the declaration's own
/// types, a type parameter of self's included.
pub fn declaredParams(self: *Checker, m: Field, module: ?u32, skip: usize) ?[]const TypeId {
    if (module != null) return null;
    const params = switch (self.ctx.types.get(m.ty)) {
        .function => |f| f.params,
        else => return null,
    };
    return if (params.len >= skip) params[skip..] else null;
}

/// The arguments of a call to `f` whose `!` their parameters ignore
/// (`plainSlotViews`), by position or by name.
pub fn argViews(self: *Checker, args: []const Sexp, f: FunctionType, info: Checker.ParamInfo) Error![]const Sexp {
    const a = self.ctx.arena.allocator();
    const values = try a.alloc(Sexp, args.len);
    const types = try a.alloc(TypeId, args.len);
    // A closure written last may fill the parameter that takes a
    // function (`closureParam`).
    const trailing: ?usize = closureParam(self, args, f.params, info);
    for (args, values, types, 0..) |arg, *v, *ty, at| {
        v.* = .nil;
        ty.* = sema.type_invalid;
        const i = if (trailing != null and at == args.len - 1) trailing.? else at;
        if (arg.isKind(.kwarg)) {
            const names = info.names orelse continue;
            const k = for (names, 0..) |n, j| {
                if (std.mem.eql(u8, n, self.text(ir.Kwarg.name(arg)))) break j;
            } else continue;
            if (k >= f.params.len) continue;
            v.* = ir.Kwarg.value(arg);
            ty.* = f.params[k];
        } else if (i < f.params.len) {
            v.* = arg;
            ty.* = f.params[i];
        }
    }
    return ViewCheck.plainSlotViews(self, values, types);
}

/// Whether `args[i]` is a closure written as the call's last
/// argument, which may follow its keyword arguments
/// (`trailingParam`).
pub fn trailingClosure(args: []const Sexp, i: usize) bool {
    return i == args.len - 1 and args[i].isKind(.lambda);
}

/// Whether the call's last argument is a closure written after its
/// keyword arguments.
pub fn hasTrailingClosure(args: []const Sexp) bool {
    if (args.len < 2 or !trailingClosure(args, args.len - 1)) return false;
    for (args[0 .. args.len - 1]) |a| if (a.isKind(.kwarg)) return true;
    return false;
}

/// Whether a parameter or value of type `ty` is a function: `fun`,
/// `sub`, or a view of one.
pub fn takesFunction(self: *Checker, ty: TypeId) bool {
    const inner = switch (self.ctx.types.get(ty)) {
        .read_view => |v| v,
        else => ty,
    };
    return switch (self.ctx.types.get(inner)) {
        .function, .callable => true,
        else => false,
    };
}

/// The parameter a closure written as a call's last argument fills
/// when it is the callback (`trailingParam`): after the keyword
/// arguments, or where its position would give an option, so
/// `repeat(|i| ...)` fills `f` of `repeat(times: Int = 1, f: ?sub(Int))`.
/// Null when it fills its position, or no parameter is open.
pub fn closureParam(self: *Checker, args: []const Sexp, params: []const TypeId, info: Checker.ParamInfo) ?usize {
    if (args.len == 0 or !args[args.len - 1].isKind(.lambda)) return null;
    if (!hasTrailingClosure(args) and info.default(args.len - 1) == null) return null;
    return trailingParam(self, args, params, info.names, info.groups);
}

/// The parameter a closure written last, after the keyword
/// arguments, fills: the parameter that takes a function and no
/// other argument fills, the last of them when several do, never a
/// group's field (`groups`). Null when none is open.
pub fn trailingParam(self: *Checker, args: []const Sexp, params: []const TypeId, names: ?[]const []const u8, groups: ?[]const ?sema.GroupParam) ?usize {
    var positional: usize = 0;
    for (args[0 .. args.len - 1]) |a| {
        if (!a.isKind(.kwarg)) positional += 1;
    }
    var i = params.len;
    while (i > positional) {
        i -= 1;
        const named = if (names) |ns| for (args[0 .. args.len - 1]) |a| {
            if (a.isKind(.kwarg) and i < ns.len and std.mem.eql(u8, ns[i], self.text(ir.Kwarg.name(a)))) break true;
        } else false else false;
        if (named) continue;
        if (groups) |gs| if (i < gs.len and gs[i] != null) continue;
        const ty = params[i];
        if (sema.callableFnTy(self.ctx, ty) != null or self.ctx.types.get(ty) == .function) return i;
    }
    return null;
}

/// The checks of a std method's arguments beyond their types where
/// it is called (`sema.stdArgCheck`): method `method` of type `owner`,
/// declared in module `module` (null for this one), given `args` after
/// self. False after a diagnostic.
pub fn stdArgChecks(self: *Checker, module: ?u32, owner: []const u8, method: []const u8, args: []const Sexp, pos: u32) Error!bool {
    const home = if (module) |m| self.ctx.foreign_semas.get(m) orelse self.ctx else self.ctx;
    // A spread's fields are field reads, which these checks of written
    // arguments read nothing of; `checkArgs` checks the spread
    // (docs/design/options.md, section 4).
    for (args) |a| if (a.isKind(.spread)) return true;
    return switch (sema.stdArgCheck(home, owner, method) orelse return true) {
        .unit_increment, .clock_increment, .day_increment, .instant_increment => |kind| checkUnitIncrement(self, method, args, pos, kind),
        .calendar_add => checkCalendarAdd(self, method, args),
    };
}

/// A call of a std maker (`sema.ConstMaker`), once its arguments are
/// checked: when every argument, and every default it leaves out, is
/// a constant (`constInt`), the check std's maker makes runs as Rig
/// compiles, and the call gives the plain `T` of `returns`, its `T!`,
/// or an error naming the part it refuses. An argument known only as
/// the program runs leaves the call `returns` (`maker_runtime`). The
/// answer is the call's own, the same in every instance of a generic
/// body: a compile-time parameter is not a constant there. A task of
/// the call is checked the same, and holds what the maker gives as
/// declared, `Task[T!]`, as a task of any fallible call does.
pub fn constMakerCall(self: *Checker, home: *const SemContext, maker: sema.ConstMaker, args: []const Sexp, returns: TypeId) Error!TypeId {
    const call = self.expect.current_call orelse return returns;
    const ok = switch (self.ctx.types.get(returns)) {
        .fallible => |fl| fl.ok,
        else => return returns,
    };
    if (maker == .zone_named) return zoneNamedCall(self, home, call, args, returns, ok);
    const parts = maker.params();
    var values: [7]Wide = undefined;
    var nodes: [7]Sexp = @splat(.nil);
    const slots = self.ctx.callSlotsOf(call);
    if (slots == null and args.len != parts.len) return returns;
    for (0..parts.len) |i| {
        const slot: sema.ArgSlot = if (slots) |sl| (if (i < sl.len) sl[i] else return returns) else .{ .arg = @intCast(i) };
        switch (slot) {
            .arg => |ai| {
                const value = if (args[ai].isKind(.kwarg)) ir.Kwarg.value(args[ai]) else args[ai];
                values[i] = ExprCheck.constInt(self, value) orelse {
                    self.expect.maker_runtime = .{ .call = call, .arg = value };
                    return returns;
                };
                nodes[i] = value;
            },
            .default => |d| values[i] = sema.constIntOf(home, d.expr) orelse return returns,
            .parts => return returns,
        }
    }
    const i = sema.makerFault(maker, values[0..parts.len]) orelse {
        if (ir.Call.task(call) != .nil) return returns;
        try self.ctx.record(.const_makers, call, {});
        return ok;
    };
    const a = self.ctx.arena.allocator();
    const v = values[i];
    const why: []const u8, const fix: []const u8 = switch (parts[i]) {
        .year => .{ try a.print("{d} is beyond the years of a date, -9999 to 9999", .{v}), "write a year from -9999 to 9999" },
        .month => .{ try a.print("{d} is not a month", .{v}), "write a month from 1 to 12" },
        .day => blk: {
            const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
            const n = sema.monthDays(values[0], values[1]);
            break :blk .{ try a.print("{s} {d} has {d} days", .{ names[@intCast(values[1] - 1)], values[0], n }), try a.print("write a day from 1 to {d}", .{n}) };
        },
        .hour => .{ try a.print("{d} is not an hour of the day", .{v}), "write an hour from 0 to 23" },
        .minute => .{ try a.print("{d} is not a minute of the hour", .{v}), "write a minute from 0 to 59" },
        .second => .{ try a.print("{d} is not a second of the minute", .{v}), "write a second from 0 to 59" },
        .ns => .{ try a.print("{d} is not a nanosecond of the second", .{v}), "write `ns` from 0 to 999_999_999" },
        .duration_s => .{ try a.print("{d} is not whole seconds a `Duration` holds, within ±(2^63 - 1)", .{v}), "write seconds from -9_223_372_036_854_775_807 to 9_223_372_036_854_775_807" },
        .duration_ns => if (v > -1_000_000_000 and v < 1_000_000_000)
            .{ try a.print("{d} nanoseconds and {d} seconds differ in sign", .{ v, values[0] }), "write the two of one sign, or either as 0" }
        else
            .{ try a.print("{d} is not nanoseconds below a second", .{v}), "write `ns` within ±999_999_999" },
        .unix_s => .{ try a.print("{d} seconds is beyond the range of instants, -009999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z", .{v}), "write seconds from -377_705_023_201 to 253_402_207_200" },
        .unix_ns => if (v > -1_000_000_000 and v < 1_000_000_000)
            .{ try a.print("{d} seconds and {d} nanoseconds is beyond the range of instants, -009999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z", .{ values[0], v }), "write an instant within the range" }
        else
            .{ try a.print("{d} is not nanoseconds within ±999,999,999", .{v}), "write `ns` within ±999_999_999, and the whole seconds as `s`" },
        .unix_ms => .{ try a.print("{d} milliseconds is beyond the range of instants, -009999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z", .{v}), "write milliseconds from -377_705_023_201_000 to 253_402_207_200_999" },
        .unix_us => .{ try a.print("{d} microseconds is beyond the range of instants, -009999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z", .{v}), "write microseconds from -377_705_023_201_000_000 to 253_402_207_200_999_999" },
        .zone_hours => .{ try a.print("{d} hours is beyond a fixed zone's offset, within ±25:59", .{v}), "write hours from -25 to 25" },
        .zone_minutes => if ((values[0] < 0 and v > 0) or (values[0] > 0 and v < 0))
            .{ try a.print("{d} hours and {d} minutes differ in sign", .{ values[0], v }), try a.print("write the two of one sign: `fixed(hours: {d}, minutes: {d})`", .{ values[0], -v }) }
        else
            .{ try a.print("{d} hours and {d} minutes is beyond a fixed zone's offset, within ±25:59", .{ values[0], v }), "write an offset from -25:59 to +25:59" },
    };
    // The call as written, without the `&` of a task of it.
    const shown = std.mem.trimEnd(u8, try ViewCheck.plainText(self, call), "& ");
    try self.errAt(if (nodes[i] != .nil) nodes[i] else call, "`{s}` always fails, its arguments being constants: {s}; {s}", .{ shown, why, fix });
    return self.t().invalid_id;
}

/// `TimeZone.named` (`sema.ConstMaker.zone_named`): a string literal
/// that names a zone of the data in std.datetime's names file, as
/// std reads one, gives the plain `TimeZone`; one that names none is
/// an error offering the nearest name. Any other argument leaves the
/// call `returns`, its `T!` (`maker_runtime`).
pub fn zoneNamedCall(self: *Checker, home: *const SemContext, call: Sexp, args: []const Sexp, returns: TypeId, ok: TypeId) Error!TypeId {
    if (args.len != 1 or home.zone_names.len == 0) return returns;
    // By position or by its name, `name: "..."`, the one argument.
    const value = if (args[0].isKind(.kwarg)) ir.Kwarg.value(args[0]) else args[0];
    const name = sema.zoneNameLiteral(self.ctx.source, value) orelse {
        self.expect.maker_runtime = .{ .call = call, .arg = value, .literal = true };
        return returns;
    };
    if (sema.zoneNamed(home.zone_names, name)) {
        if (ir.Call.task(call) != .nil) return returns;
        try self.ctx.record(.const_makers, call, {});
        return ok;
    }
    const shown = std.mem.trimEnd(u8, try ViewCheck.plainText(self, call), "& ");
    if (sema.nearestZoneName(home.zone_names, name)) |near|
        try self.errAt(value, "`{s}` always fails, its argument being a constant: the zone data has no zone named `{s}`; did you mean `\"{s}\"`?", .{ shown, name, near })
    else
        try self.errAt(value, "`{s}` always fails, its argument being a constant: the zone data has no zone named `{s}`; `datetime.zone_names()` lists every name", .{ shown, name });
    return self.t().invalid_id;
}

/// std.datetime's `format` (`sema.FormatType`): a format string known
/// as Rig compiles, a string literal or a module constant bound to
/// one, whose directives all suit the type, gives the plain `String`
/// of `returns`, its `String!` (docs/design/datetime.md §8.4). A
/// directive the type does not take is an error naming it and the
/// type, and a string made as the program runs an error whose fix is
/// `try_format`. The call is recorded as a maker's of constants is
/// (`Facts.const_makers`), so emit unwraps it as one.
pub fn formatCall(self: *Checker, ft: sema.FormatType, args: []const Sexp, returns: TypeId) Error!TypeId {
    const call = self.expect.current_call orelse return returns;
    const ok = switch (self.ctx.types.get(returns)) {
        .fallible => |fl| fl.ok,
        else => return returns,
    };
    if (args.len != 1) return returns;
    const value = if (args[0].isKind(.kwarg)) ir.Kwarg.value(args[0]) else args[0];
    const shown = std.mem.trimEnd(u8, try ViewCheck.plainText(self, call), "& ");
    const fmt_text = formatString(self, self.ctx, value, 0) orelse {
        // The fix is the call as written with its own member's name,
        // `format`, made `try_format`, by the source spans of the two.
        const callee = ir.Call.callee(call);
        const name = if (callee.isKind(.member)) ir.Member.name(callee) else return returns;
        const whole = self.ctx.span(call);
        const at = self.ctx.span(name);
        const written = std.mem.trimEnd(u8, self.ctx.source[whole.start..whole.end], "& ");
        const before = self.ctx.source[whole.start..at.start];
        const after = written[@min(at.end - whole.start, written.len)..];
        try self.errAt(value, "`{s}` takes a format string known as Rig compiles, a string literal or a module constant bound to one, which is checked against the `{s}`; for `{s}`, made as the program runs, write `{s}try_format{s}!`", .{ shown, ft.name(), try ViewCheck.plainText(self, value), before, after });
        return self.t().invalid_id;
    };
    const fault = sema.formatFault(ft, fmt_text) orelse {
        if (ir.Call.task(call) != .nil) return returns;
        try self.ctx.record(.const_makers, call, {});
        return ok;
    };
    const a = self.ctx.arena.allocator();
    const directive = fmt_text[fault.at..fault.end];
    const why: []const u8 = switch (fault.why) {
        .ends => "the string ends before its directive does; `%%` writes a `%`",
        .unknown => "it is not a directive `format` takes",
        .lacks => switch (fault.needs) {
            sema.format_date => try a.print("a `{s}` has no date", .{ft.name()}),
            sema.format_time => try a.print("a `{s}` has no time of day", .{ft.name()}),
            else => if (ft == .date_time)
                "a `DateTime` has no zone: `dt.in_zone(tz)!` gives a `ZonedDateTime`, which has one"
            else
                try a.print("a `{s}` has no zone", .{ft.name()}),
        },
        .flag => try a.print("`format` takes no flag `{c}`; `-`, which drops the padding, is its one flag", .{directive[1]}),
        .width => "`format` takes no width; a precision on the fraction, `%.3f`, is the one number it takes",
        .nopad => try a.print("`-` drops the padding, and `%{c}` has none", .{directive[directive.len - 1]}),
        .precision => "a precision is one digit, 1 to 9: `%.3f`",
    };
    const takes: []const u8 = switch (ft) {
        .date => "`%Y %m %d %e %A %a %B %b %j %F %u %G %V %%`",
        .time => "`%H %M %S %I %p %T %R %f %.f %%` and a precision, `%.3f`",
        .date_time => "the directives of a `Date` and of a `Time`",
        .zoned => "the directives of a `DateTime`, and `%z %:z %Z %s`",
    };
    try self.errAt(value, "`{s}`: `{s}` in the format string does not suit a `{s}`: {s}; a `{s}` takes {s}", .{ shown, directive, ft.name(), why, ft.name(), takes });
    return self.t().invalid_id;
}

/// The bytes of the format string `e` gives, known as Rig compiles: a
/// string literal's, or those of the one a module constant is bound
/// to, here or in another module (`lib.FMT`), through a chain of such
/// constants. Null for any other expression.
pub fn formatString(self: *Checker, ctx: *const SemContext, e: Sexp, depth: u32) ?[]const u8 {
    if (depth > 64) return null;
    if (e == .src) {
        const lit = diag.textOf(ctx.source, rig.leafSpan(ctx.source, e));
        if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'')) return CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), lit);
    }
    const c = sema.patternConst(ctx, e) orelse return null;
    if (c.ctx.symbols.items[c.id].flags.per_target) return null;
    const value = for (c.ctx.const_order.items) |decl| {
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        if (c.ctx.symbolOf(ir.Set.target(set)) == c.id) break ir.Set.value(set);
    } else return null;
    return formatString(self, c.ctx, value, depth + 1);
}

/// `add` or `checked_add` of a `Date` (`sema.ArgCheck.calendar_add`):
/// no duration, by position or by a unit's keyword, since a date has
/// no time of day.
pub fn checkCalendarAdd(self: *Checker, method: []const u8, args: []const Sexp) Error!bool {
    for (args) |a| {
        const time_of_day = if (!a.isKind(.kwarg)) blk: {
            // A `Float` or a `Duration` is a time of day, which a date
            // has none of; any other argument by position is an
            // amount, an option given by name (`checkArgs`).
            const saved = self.expect.under_poison;
            self.expect.under_poison = true;
            defer self.expect.under_poison = saved;
            const ty = ExprCheck.canonical(self, try PatternCheck.synthExpr(self, a));
            if (self.isPoison(ty)) return false;
            // An `Int` by position is most likely days.
            if (ty == self.t().int_id or ty == self.t().int_literal_id) {
                try self.errAt(a, "`{s}` of a `Date` takes its amounts as options, given by name: `{s}(days: {s})` for days, or `years:`, `months:`, `weeks:`", .{ method, method, try ViewCheck.plainText(self, a) });
                return false;
            }
            if (ty != self.t().float_id and ty != self.t().float_literal_id and !sema.isDurationType(self.ctx, sema.unwrapOptionals(self.ctx, ty))) continue;
            break :blk a;
        } else if (sema.duration.unitNs(self.text(ir.Kwarg.name(a))) != null) ir.Kwarg.name(a) else continue;
        // The fix keeps every amount written, on a `DateTime`, whose
        // duration is an option, given by name.
        var all: std.ArrayList(u8) = .empty;
        const al = self.ctx.arena.allocator();
        for (args, 0..) |b, i| try all.print(al, "{s}{s}{s}", .{ if (i > 0) ", " else "", if (b.isKind(.kwarg)) "" else "duration: ", try ViewCheck.plainText(self, b) });
        const what = if (a.isKind(.kwarg))
            try std.fmt.allocPrint(al, "`{s}:`", .{self.text(ir.Kwarg.name(a))})
        else
            try std.fmt.allocPrint(al, "duration, `{s}`", .{try ViewCheck.plainText(self, a)});
        try self.errAt(time_of_day, "a `Date` has no time of day, so `{s}` takes no {s}: a date and a time of day is a `DateTime`, `d.at(t).{s}({s})`", .{ method, what, method, all.items });
        return false;
    }
    return true;
}

/// The checks of `stdArgChecks` that read the arguments' types, once
/// `checkArgs` has given them: an increment is an `Int`, not an
/// optional nor `none`, which the declared `Int?` lets through.
pub fn stdArgTypes(self: *Checker, module: ?u32, owner: []const u8, method: []const u8, args: []const Sexp) Error!void {
    const home = if (module) |m| self.ctx.foreign_semas.get(m) orelse self.ctx else self.ctx;
    switch (sema.stdArgCheck(home, owner, method) orelse return) {
        .calendar_add => {},
        .unit_increment, .clock_increment, .day_increment, .instant_increment => for (args) |a| {
            if (!a.isKind(.kwarg)) continue;
            const value = ir.Kwarg.value(a);
            const ty = ExprCheck.canonical(self, self.ctx.typeOf(value) orelse continue);
            if (self.isPoison(ty) or ty == self.t().int_id or ty == self.t().int_literal_id) continue;
            const none = std.mem.eql(u8, identAt(self.ctx.source, value) orelse "", "none");
            try self.errAt(value, "an increment of `{s}` is an `Int`, and `{s}` is {s}: name one unit and a number, `{s}(seconds: 1)`", .{ method, try ViewCheck.plainText(self, value), if (none) "no number" else try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s} `{s}`", .{ CompatCheck.article(try self.tyName(ty)), try self.tyName(ty) }), method });
        },
    }
}

/// `round` or `floor` (`sema.ArgCheck.unit_increment` and its kin):
/// exactly one unit's keyword and its increment; an increment written
/// as a constant is from 1 to 1,000,000,000, and on a `Time` or a
/// `DateTime` divides the next larger unit and is smaller than it, or
/// for `days:` is 1, and on an `Instant` divides a day.
pub fn checkUnitIncrement(self: *Checker, method: []const u8, args: []const Sexp, pos: u32, kind: sema.ArgCheck) Error!bool {
    // An argument by position gives an option, which `checkArgs`
    // refuses.
    for (args) |a| if (!a.isKind(.kwarg)) return true;
    if (args.len == 0) {
        try self.err(pos, "`{s}` takes a unit and its increment: `{s}(seconds: 1)`", .{ method, method });
        return false;
    }
    if (args.len > 1) {
        try self.errAt(args[1], "`{s}` takes one unit and its increment, not {d}: {s}", .{ method, args.len, try oneIncrement(self, method, args, kind) });
        return false;
    }
    const name_node = ir.Kwarg.name(args[0]);
    const name = self.text(name_node);
    const days = kind == .day_increment and std.mem.eql(u8, name, "days");
    const unit_ns = sema.duration.unitNs(name);
    if (unit_ns == null and !days) {
        try self.errAt(name_node, "`{s}` takes a unit from `ns:` to `hours:`{s} and its increment, and `{s}:` is none of them", .{ method, if (kind == .day_increment) ", or `days: 1`," else "", name });
        return false;
    }
    const value = ir.Kwarg.value(args[0]);
    const v = ExprCheck.constInt(self, value) orelse {
        // A `Time`'s `round` and `floor` cannot fail, so their
        // increment is a constant; a step known only as the program
        // runs rounds a `DateTime`, whose `round` can fail with
        // `invalid` (docs/design/datetime.md §6.8).
        if (kind != .clock_increment) return true;
        try self.errAt(value, "an increment of a `Time`'s `{s}` is a constant, checked as Rig compiles, since its `{s}` cannot fail, and `{s}` is not one: a step known only as the program runs rounds a date and time, `d.at(t).{s}({s}: {s})!.time()`", .{ method, method, try ViewCheck.plainText(self, value), method, name, try ViewCheck.plainText(self, value) });
        return false;
    };
    if (v < 1 or v > 1_000_000_000) {
        try self.errAt(value, "an increment of `{s}` is from 1 to 1,000,000,000, and `{s}` is not", .{ method, try ViewCheck.plainText(self, value) });
        return false;
    }
    if (kind == .unit_increment) return true;
    if (kind == .instant_increment) {
        if (incrementAllowed(kind, unit_ns.?, v)) return true;
        const per_day: Wide = @divTrunc(86_400_000_000_000, unit_ns.?);
        try self.errAt(value, "an increment of `{s}` on an `Instant` divides a day, so `{s}:` takes a number that divides {s}, and `{s}` does not", .{ method, name, try groupedInt(self.ctx.arena.allocator(), per_day), try ViewCheck.plainText(self, value) });
        return false;
    }
    if (days) {
        if (v == 1) return true;
        try self.errAt(value, "`{s}` takes `days: 1` and no other number of days, and `{s}` is not 1", .{ method, try ViewCheck.plainText(self, value) });
        return false;
    }
    // The next larger unit: 1,000 of each below a second, 60
    // seconds and minutes, 24 hours.
    const limit: Wide = switch (unit_ns.?) {
        1, 1_000, 1_000_000 => 1_000,
        3_600_000_000_000 => 24,
        else => 60,
    };
    if (incrementAllowed(kind, unit_ns.?, v)) return true;
    var list: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    var k: Wide = 1;
    while (k < limit) : (k += 1) {
        if (@mod(limit, k) != 0) continue;
        // The divisors below `limit`, the last after `or`.
        if (list.items.len > 0) try list.appendSlice(a, if (k * 2 == limit) ", or " else ", ");
        try list.print(a, "{d}", .{k});
    }
    try self.errAt(value, "an increment of `{s}` divides the next larger unit and is smaller than it, so `{s}:` takes {s}, and `{s}` is not one of them", .{ method, name, list.items, try ViewCheck.plainText(self, value) });
    return false;
}

/// The fix for `round` or `floor` given several units, `args`: the
/// increment in the largest unit it is a whole number of when each is
/// a constant, `round(minutes: 90)` for `hours: 1, minutes: 30`; else
/// the smallest unit given to write it in. On a `Time` or a `DateTime`
/// (`kind`) the sum is offered only as an increment they take, one that
/// divides the next larger unit and is smaller than it; else the call
/// names one of the units given.
pub fn oneIncrement(self: *Checker, method: []const u8, args: []const Sexp, kind: sema.ArgCheck) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var smallest: ?i64 = null;
    var total: ?i128 = 0;
    for (args) |kw| {
        const unit = sema.duration.unitNs(self.text(ir.Kwarg.name(kw))) orelse {
            total = null;
            continue;
        };
        smallest = @min(smallest orelse unit, unit);
        const v = ExprCheck.constInt(self, ir.Kwarg.value(kw));
        total = if (total != null and v != null and @abs(v.?) <= 1_000_000_000) total.? + @as(i128, @intCast(v.?)) * unit else null;
    }
    const u = smallest orelse return std.fmt.allocPrint(a, "name one unit and its increment, `{s}(minutes: 15)`", .{method});
    // The largest unit the sum is a whole number of, as an increment
    // is written in every type that rounds (docs/design/datetime.md §6.8).
    if (total) |sum| for (sema.duration.units) |unit| {
        if (@rem(sum, unit[1]) != 0 or @divTrunc(sum, unit[1]) < 1 or @divTrunc(sum, unit[1]) > 1_000_000_000) continue;
        const n = @divTrunc(sum, unit[1]);
        if (!incrementAllowed(kind, unit[1], @intCast(n))) break;
        return std.fmt.allocPrint(a, "write the increment in one unit, `{s}({s}: {d})`", .{ method, unit[0], n });
    };
    if (kind != .unit_increment) {
        // The first unit given, with its increment when the check
        // takes it, or the largest increment below it that it takes.
        const name = self.text(ir.Kwarg.name(args[0]));
        const unit = sema.duration.unitNs(name) orelse return std.fmt.allocPrint(a, "name one of them, `{s}({s})`", .{ method, try ViewCheck.plainText(self, args[0]) });
        const v = ExprCheck.constInt(self, ir.Kwarg.value(args[0])) orelse return std.fmt.allocPrint(a, "name one of them, `{s}({s})`", .{ method, try ViewCheck.plainText(self, args[0]) });
        if (v >= 1 and v <= 1_000_000_000 and incrementAllowed(kind, unit, v)) return std.fmt.allocPrint(a, "name one of them, `{s}({s})`", .{ method, try ViewCheck.plainText(self, args[0]) });
        return std.fmt.allocPrint(a, "name one unit and an increment it takes, `{s}({s}: {d})`", .{ method, name, largestIncrement(kind, unit, v) });
    }
    return std.fmt.allocPrint(a, "write the increment in one unit, the smallest given, `{s}:`", .{sema.duration.unitName(u)});
}

/// Whether `n`, from 1 to 1,000,000,000, is an increment of a unit of
/// `unit_ns` nanoseconds that `round` and `floor` of `kind` take: any
/// for a `Duration`; one that divides a day for an `Instant`; one that
/// divides the next larger unit and is smaller than it for a `Time`
/// and a `DateTime` (docs/design/datetime.md §6.8).
pub fn incrementAllowed(kind: sema.ArgCheck, unit_ns: i64, n: Wide) bool {
    return switch (kind) {
        .instant_increment => @rem(@divTrunc(@as(Wide, 86_400_000_000_000), unit_ns), n) == 0,
        .clock_increment, .day_increment => blk: {
            const limit: Wide = switch (unit_ns) {
                1, 1_000, 1_000_000 => 1_000,
                3_600_000_000_000 => 24,
                else => 60,
            };
            break :blk n < limit and @rem(limit, n) == 0;
        },
        else => true,
    };
}

/// The largest increment of a unit of `unit_ns` nanoseconds at most
/// `v` that `round` and `floor` of `kind`, a `Time`, a `DateTime`, or
/// an `Instant`, take (`incrementAllowed`); 1 when `v` is below 1. An
/// instant's increments divide a day, whose count in any unit has no
/// prime factor but 2, 3, and 5, so they are found among those.
pub fn largestIncrement(kind: sema.ArgCheck, unit_ns: i64, v: Wide) Wide {
    const top = @min(v, 1_000_000_000);
    var best: Wide = 1;
    var p2: Wide = 1;
    while (p2 <= top) : (p2 *= 2) {
        var p3: Wide = p2;
        while (p3 <= top) : (p3 *= 3) {
            var p5: Wide = p3;
            while (p5 <= top) : (p5 *= 5) {
                if (p5 > best and incrementAllowed(kind, unit_ns, p5)) best = p5;
            }
        }
    }
    return best;
}

/// `n` with its thousands grouped by commas, as the docs write a
/// number: `86,400`.
pub fn groupedInt(a: std.mem.Allocator, n: Wide) Error![]const u8 {
    const digits = try std.fmt.allocPrint(a, "{d}", .{n});
    var out: std.ArrayList(u8) = .empty;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(a, ',');
        try out.append(a, c);
    }
    return out.items;
}

/// A method's type parameters and self's arguments for them:
/// the first part of an instance of a method with type parameters of
/// its own. Empty for a type that is not generic.
pub fn selfArgs(self: *Checker, recv_ty: TypeId) TypeSubst {
    const pn = switch (self.ctx.types.get(sema.unwrapReadAccess(self.ctx, recv_ty))) {
        .parameterized_nominal => |pn| pn,
        else => return .empty,
    };
    return .{ .params = self.ctx.symbols.items[self.ctx.localSym(pn.sym)].type_params orelse &.{}, .args = pn.args };
}

/// The signature a call of `f` uses: `f` itself, or for a generic
/// function the instance its bracket list `ct` gives (every
/// compile-time argument, in order) or, without one, the instance its
/// arguments determine (`args`, filling `f.params[skip..]`). Each
/// compile-time value must be known at compile time. The call's
/// type arguments (`genericCallOf`) and the instance, whose body must
/// allow them, are recorded. Null after a diagnostic that makes the
/// arguments not worth checking.
pub fn instantiateCall(self: *Checker, f: FunctionType, ct: ?Sexp, args: []const Sexp, info: Checker.ParamInfo, skip: usize, callee: []const u8, pos: u32, self_arg: bool, recv: TypeSubst) Error!?FunctionType {
    self.inst_own = .empty;
    self.inst_slots = &.{};
    if (ct) |b| try self.ctx.record(.instances, b, .function);
    // A compile-time parameter was rejected: the declaration's
    // diagnostic says what is wrong with every call.
    for (f.ct_params) |ty| if (self.isPoison(ty)) return null;
    const a = self.ctx.arena.allocator();
    const n = f.ct_params.len;
    // The parameters an instance binds: the type parameters and the
    // integer value parameters, at their slots.
    var own: std.ArrayList(SymbolId) = .empty;
    var own_slots: std.ArrayList(u32) = .empty;
    for (0..n) |i| {
        const sym = sema.ownParamOf(self.ctx, f, i) orelse continue;
        try own.append(a, sym);
        try own_slots.append(a, @intCast(i));
    }
    const given: []const Sexp = if (ct) |b| sema.bracketArgs(b) else &.{};
    if (ct) |b| if (given.len != n) {
        if (n == 0) {
            try self.errAt(b, "`{s}` takes no compile-time arguments; call it with `{s}(...)`", .{ callee, callee });
        } else try self.errAt(b, "`{s}` expects {d} compile-time argument{s}, got {d}", .{ callee, n, CompatCheck.plural(n), given.len });
        return null;
    };
    // A value is inferred only for an integer parameter that the
    // parameters' or the result's types hold (`[n]T`); a function
    // that takes another is given every compile-time argument in
    // brackets.
    if (ct == null) for (f.ct_params, 0..) |slot, i| {
        if (sema.typeParamOf(self.ctx, slot) != null) continue;
        if (sema.intParamOf(self.ctx, f, i)) |sym| if (signatureUses(self, f, sym)) continue;
        // A rejected parameter type may be what would have held it.
        for (f.params) |p| if (sema.containsPoison(self.ctx, p)) return null;
        const parens = if (f.params.len > skip) "(...)" else "()";
        // `f([1, 2])` for `f[1, 2]()`: the only argument is
        // an array, where the function takes none.
        if (f.params.len == skip and args.len == 1 and args[0].isKind(.array)) {
            const arg = sourceText(self, args[0]);
            try self.err(pos, "compile-time arguments go in brackets after the name: `{s}{s}{s}`", .{ callee, arg, parens });
        } else {
            try self.err(pos, "`{s}` takes {d} compile-time argument{s} in brackets: `{s}[...]{s}`", .{ callee, n, CompatCheck.plural(n), callee, parens });
        }
        return null;
    };
    const type_args = try a.alloc(TypeId, n);
    @memset(type_args, sema.type_invalid);
    var bad = false;
    if (ct != null) for (given, f.ct_params, 0..) |g, slot, i| {
        if (sema.typeParamOf(self.ctx, slot) != null) {
            type_args[i] = try typeArg(self, g);
            if (self.isPoison(type_args[i])) bad = true;
        } else if (sema.intParamOf(self.ctx, f, i)) |sym| {
            type_args[i] = (try StdFormCheck.ctIntArg(self, g, sym, i, callee)) orelse blk: {
                bad = true;
                break :blk sema.type_invalid;
            };
        } else try self.checkCtValue(g, slot, i, callee);
    };
    if (bad) return null;
    if (own.items.len == 0) {
        if (ct != null) try self.ctx.record(.generic_calls, self.expect.current_call.?, .{ .type_args = type_args, .self_arg = self_arg, .sets = setArgs(self, f), .fails_by_set = failsBySet(self, f), .witnesses = try ctWitnesses(self, f, type_args), .params = try ctParamSyms(self, f) });
        self.inst_own = .empty;
        self.inst_slots = &.{};
        return f;
    }
    if (ct == null) {
        const inferred = (try inferCallTypeArgs(self, f, own.items, args, info, skip, callee, pos)) orelse return null;
        for (own_slots.items, inferred) |i, ty| type_args[i] = ty;
    }
    const own_args = try a.alloc(TypeId, own.items.len);
    for (own_slots.items, own_args) |i, *arg| arg.* = type_args[i];
    const generic = try self.ctx.internCopy(.{ .function = f });
    const instance = try sema.substituteType(self.ctx, generic, .{ .params = own.items, .args = own_args });
    if (instance != generic) if (sema.findHeapStacked(self.ctx, instance)) |found| {
        try self.err(pos, "`{s}` at these types has `{s}` in its signature, which stacks one heap holding on another; " ++ sema.heap_stacked_rule, .{ callee, try self.tyName(found) });
        return null;
    };
    const result = self.ctx.types.get(instance).function;
    try self.ctx.record(.generic_calls, self.expect.current_call.?, .{ .type_args = type_args, .self_arg = self_arg, .sets = setArgs(self, f), .fails_by_set = failsBySet(self, f), .witnesses = try ctWitnesses(self, f, type_args), .params = try ctParamSyms(self, f) });
    self.inst_own = .{ .params = own.items, .args = own_args };
    self.inst_slots = own_slots.items;
    if (self.tentative == 0) {
        const inst: sema.FnInstance = .{
            .name = callee,
            .params = try std.mem.concat(a, SymbolId, &.{ recv.params, own.items }),
            .args = try std.mem.concat(a, TypeId, &.{ recv.args, own_args }),
            .own = @intCast(own.items.len),
        };
        // An instance at a generic body's own parameters meets its
        // bounds by theirs, here; a concrete one where it is checked
        // (`checkGenericInstantiations`).
        for (own_args) |arg| if (sema.containsTypeVar(self.ctx, arg)) {
            _ = try sema.checkBounds(self.ctx, own.items, own_args, pos, .{ .func = inst });
            try self.ctx.param_calls.append(self.ctx.allocator, .{ .params = try a.dupe(SymbolId, own.items), .args = own_args, .pos = pos, .body = self.body_pos });
            break;
        };
        _ = try self.ctx.recordFnInstanceIn(inst, pos, StdFormCheck.bodyRef(self));
    }
    return result;
}

/// The type parameter each compile-time slot of `f` declares
/// (`GenericCall.params`).
pub fn ctParamSyms(self: *Checker, f: FunctionType) Error![]const SymbolId {
    const params = try self.ctx.arena.allocator().alloc(SymbolId, f.ct_params.len);
    for (f.ct_params, params) |slot, *p| p.* = sema.typeParamOf(self.ctx, slot) orelse sema.symbol_invalid;
    return params;
}

/// The witnesses a call's type arguments give the parameters of `f`
/// they fill whose bounds name APIs of a program's own
/// (`sema.argWitnesses`); none when an argument does not provide one,
/// which the bound's check reports.
pub fn ctWitnesses(self: *Checker, f: FunctionType, type_args: []const TypeId) Error![]const sema.ArgWitness {
    const a = self.ctx.arena.allocator();
    const params = try a.alloc(SymbolId, f.ct_params.len);
    var any = false;
    for (f.ct_params, params) |slot, *p| {
        p.* = sema.typeParamOf(self.ctx, slot) orelse sema.symbol_invalid;
        if (p.* != sema.symbol_invalid and self.ctx.symbols.items[p.*].user_apis.len > 0) any = true;
    }
    if (!any) return &.{};
    for (type_args) |ty| if (ty == sema.type_invalid or self.isPoison(ty)) return &.{};
    return (try sema.argWitnesses(self.ctx, self.ctx, params, type_args)) orelse &.{};
}

/// Whether the types of `f`'s parameters or result hold `sym`.
pub fn signatureUses(self: *Checker, f: FunctionType, sym: SymbolId) bool {
    const params = [_]SymbolId{sym};
    for (f.params) |p| if (sema.usesParams(self.ctx, p, &params)) return true;
    return sema.usesParams(self.ctx, f.returns, &params);
}

/// Match each argument's type against the field or parameter it
/// fills (by position, or by keyword), binding the type parameters in
/// `own` that appear there. A parameter no argument other than a
/// literal binds takes its type from `result`, the declared result
/// and the type expected of it, when that says; otherwise a literal
/// binds its default type (`Int`, `Float`). The first argument that
/// disagrees with a binding is kept as a conflict.
pub fn inferBindings(self: *Checker, own: []const SymbolId, args: []const Sexp, from: Checker.InferFrom, result: ?Checker.ResultType) Error!Checker.Inference {
    var inf: Checker.Inference = .{ .own = own, .bound = try self.ctx.arena.allocator().alloc(Checker.Bound, own.len) };
    @memset(inf.bound, .{});
    // Closure literals are matched last, against the parameter types
    // the other arguments give them (`viewedLambdaTypes`).
    var lambdas: std.ArrayList(Checker.LambdaArg) = .empty;
    var positional: usize = 0;
    for (args, 1..) |arg, number| {
        var value = arg;
        var pattern: ?TypeId = null;
        if (arg.isKind(.kwarg)) {
            value = ir.Kwarg.value(arg);
            const kname = self.text(ir.Kwarg.name(arg));
            pattern = switch (from) {
                .fields, .payload => |fs| if (try CompatCheck.findDataField(self.ctx, fs, kname)) |f| f.ty else null,
                .params => |p| blk: {
                    const names = p.names orelse break :blk null;
                    for (names, 0..) |name, i| {
                        if (std.mem.eql(u8, name, kname) and i < p.params.len) break :blk p.params[i];
                    }
                    break :blk null;
                },
            };
        } else if (number == args.len and (hasTrailingClosure(args) or (from == .params and closureParam(self, args, from.params.params, .{ .names = from.params.names, .defaults = from.params.defaults }) != null))) {
            // A closure written last may fill the parameter that takes
            // a function (`closureParam`).
            pattern = switch (from) {
                .fields, .payload => null,
                .params => |p| if (trailingParam(self, args, p.params, p.names, null)) |i| p.params[i] else null,
            };
        } else {
            // An object's or variant's one field may be given
            // positionally; more fields are set by name.
            defer positional += 1;
            pattern = switch (from) {
                .fields, .payload => |fs| if (positional == 0 and args.len == 1) if (soleField(fs)) |f| f.ty else null else null,
                .params => |p| if (positional < p.params.len) p.params[positional] else null,
            };
        }
        const pat = pattern orelse continue;
        if (sema.containsPoison(self.ctx, pat)) inf.poisoned = true;
        if (!sema.containsTypeVar(self.ctx, pat)) continue;
        if (value.isKind(.lambda)) {
            // A closure literal where no function goes binds nothing:
            // checked against the parameter, it is reported there.
            const fn_pat = lambdaPattern(self.ctx, pat) orelse continue;
            try lambdas.append(self.ctx.arena.allocator(), .{ .pattern = fn_pat, .lambda = value, .arg = @intCast(number) });
            continue;
        }
        // An owned closure literal (`*|x| ...`) where a function goes
        // is matched by its parameters and result as a viewed one is:
        // whether its `*` fits is checked with the call's arguments.
        // Where a `T` goes, it is a value of its own type.
        if (value.isKind(.share) and ir.Share.operand(value).isKind(.lambda)) if (lambdaPattern(self.ctx, pat)) |fn_pat| {
            try lambdas.append(self.ctx.arena.allocator(), .{ .pattern = fn_pat, .lambda = ir.Share.operand(value), .arg = @intCast(number) });
            continue;
        };
        const actual = try argType(self, value);
        if (sema.containsPoison(self.ctx, actual)) inf.poisoned = true;
        try bindArg(self, &inf, pat, actual, @intCast(number), 0);
        // A mismatch inside the argument's type names the whole
        // parameter type and the whole argument type, as any call's
        // mismatch does.
        if (inf.mismatch) |*m| if (m.arg == number) {
            m.pattern = pat;
            m.actual = actual;
        };
    }
    if (result) |r| {
        if (sema.containsPoison(self.ctx, r.expected)) inf.poisoned = true;
        try bindExpected(self, &inf, r);
    }
    for (inf.bound, 0..) |*b, i| for (inf.literals.items) |lit| {
        if (lit.param != i) continue;
        // Checking the literal against the expected type's binding
        // reports one that does not fit.
        if (b.expected) continue;
        // Among literals alone, a float one makes the type `Float`,
        // whatever their order.
        if (b.ty == sema.type_invalid or (b.ty == self.t().int_id and lit.ty == self.t().float_id and onlyLiterals(self, inf, i, b.arg))) {
            b.ty = lit.ty;
            b.arg = lit.arg;
        } else if (b.conflict == sema.type_invalid and !literalFits(self, lit.ty, b.ty)) {
            b.conflict = lit.ty;
            b.conflict_arg = lit.arg;
        }
    };
    // A closure literal whose parameters are known binds what its
    // result gives, which may type another literal's parameters:
    // repeat until no literal is left or none makes progress.
    const done = try self.ctx.arena.allocator().alloc(bool, lambdas.items.len);
    @memset(done, false);
    var progress = true;
    while (progress) {
        progress = false;
        for (lambdas.items, done) |l, *d| {
            if (d.*) continue;
            const actual = (try viewedLambdaType(self, &inf, l.pattern, l.lambda)) orelse continue;
            // A closure whose result is poison binds nothing; the
            // diagnostic about it explains a parameter left unbound,
            // its own or another closure's that waits on it.
            if (sema.containsPoison(self.ctx, actual)) inf.poisoned = true;
            inf.lambda = true;
            defer inf.lambda = false;
            try bindArg(self, &inf, l.pattern, actual, l.arg, 1);
            d.* = true;
            progress = true;
        }
    }
    for (inf.bound, 0..) |*b, i| {
        if (i < 64 and b.ty == sema.type_invalid and inf.lambda_sets & (@as(u64, 1) << @intCast(i)) != 0) {
            b.ty = self.t().any_error_id;
            b.arg = inf.lambda_arg;
        }
    }
    // A `T` that a `Static` argument and a `?String` argument both
    // bind is the `?String`, which reads the `Static` (`meets`), unless
    // a place that holds it exactly (a `Cell[T]`, a `!T`) gives the
    // type: that one holds, and the argument that differs is reported
    // where it is checked.
    for (inf.bound) |*b| {
        if (b.conflict == sema.type_invalid) continue;
        const string_view_ty = self.t().string_view_id;
        const static_ty = self.t().static_id;
        if ((b.ty == static_ty and b.conflict == string_view_ty) or (b.ty == string_view_ty and b.conflict == static_ty)) {
            b.ty = if (b.held_ty == sema.type_invalid) string_view_ty else b.held_ty;
            b.conflict = sema.type_invalid;
        }
    }
    // A `T` that only `?T`s met a `?String` is the `String` it views:
    // a read view of `T` is that `?String`.
    for (inf.bound) |*b| if (b.text_view and b.conflict == sema.type_invalid) {
        b.ty = self.t().string_id;
        b.text_view = false;
    };
    return inf;
}

/// The function type a closure literal passed where parameter type
/// `pat` goes is checked against: `pat` itself, the callable a
/// `?fun(...)` views, or the function of an owned closure
/// `*fun(...)`.
pub fn lambdaPattern(ctx: *const SemContext, pat: TypeId) ?TypeId {
    if (sema.callableFnTy(ctx, pat)) |f| return f;
    return switch (ctx.types.get(pat)) {
        .function => pat,
        .shared => |inner| if (ctx.types.get(inner) == .function) inner else null,
        else => null,
    };
}

/// The type of closure literal `lambda` where function type `pattern`
/// goes, checked quietly: its parameters take the types the call's
/// other arguments bound in `pattern` (or their annotations), and its
/// result is its body's. Null when a parameter has no type yet.
pub fn viewedLambdaType(self: *Checker, inf: *Checker.Inference, pattern: TypeId, lambda: Sexp) Error!?TypeId {
    const a = self.ctx.arena.allocator();
    var params: std.ArrayList(SymbolId) = .empty;
    var types: std.ArrayList(TypeId) = .empty;
    for (inf.own, inf.bound) |p, b| {
        if (b.ty == sema.type_invalid or b.conflict != sema.type_invalid) continue;
        try params.append(a, p);
        try types.append(a, b.ty);
    }
    const f = self.ctx.types.get(pattern).function;
    const given = try a.alloc(TypeId, f.params.len);
    for (f.params, given) |p, *g| {
        const ty = try sema.substituteType(self.ctx, p, .{ .params = params.items, .args = types.items });
        g.* = if (sema.usesParams(self.ctx, ty, inf.own)) sema.type_invalid else ty;
    }
    // A closure where a result that can fail goes may propagate
    // with `!`: `?fun() -> R!` makes the body's `!` send its failure
    // to the caller, and `R` the type of the body's value.
    const fails = self.ctx.types.get(f.returns) == .fallible;
    const m = FlowCheck.beginQuiet(self);
    self.tentative += 1;
    const ty = try ClosureCheck.checkLambdaGiven(self, lambda, null, given, fails);
    self.tentative -= 1;
    const errors = try FlowCheck.endQuiet(self, m);
    const got = self.ctx.types.get(ty).function;
    // A parameter whose written type is in error never gets one: the
    // diagnostic about it explains what it leaves unbound.
    const nodes = ir.Lambda.params(lambda).items();
    for (got.params[0..@min(got.params.len, nodes.len)], nodes[0..@min(got.params.len, nodes.len)]) |p, node| {
        if (self.isPoison(p) and node.isKind(.@":")) inf.poisoned = true;
    }
    for (got.params) |p| if (self.isPoison(p)) return null;
    if (got.params.len != f.params.len) return null;
    if (errors != 0) try inf.failed.append(a, .{ .lambda = lambda, .given = given, .fails = fails, .pattern = pattern });
    return ty;
}

/// Reports the errors of a closure literal argument whose result
/// would bind type parameter `param` of a generic call, which nothing
/// bound, and whose quiet check found errors (`Inference.failed`):
/// checked aloud, with the parameter types the call gave it, they say
/// why `param` is unbound. Each closure is checked aloud once (bit
/// `i` of `reported`, for `inf.failed[i]`). Whether one was found.
pub fn lambdaLeftUnbound(self: *Checker, inf: *const Checker.Inference, param: SymbolId, reported: *u64) Error!bool {
    var found = false;
    for (inf.failed.items, 0..) |l, i| {
        const returns = self.ctx.types.get(l.pattern).function.returns;
        if (!sema.usesParams(self.ctx, returns, &.{param})) continue;
        found = true;
        const bit = @as(u64, 1) << @intCast(@min(i, 63));
        if (reported.* & bit != 0) continue;
        reported.* |= bit;
        _ = try ClosureCheck.checkLambdaGiven(self, l.lambda, null, l.given, l.fails);
        try self.ctx.putIn(.check, .closures_reported, CompatCheck.nodeId(l.lambda), {});
    }
    return found;
}

/// The call being checked's declared result `pattern`, with the type
/// expected of the call, when one is.
pub fn expectedResult(self: *Checker, pattern: TypeId) ?Checker.ResultType {
    const call = self.expect.current_call orelse return null;
    if (!CompatCheck.sameNode(call, self.expect.result_expected.call)) return null;
    return .{ .pattern = pattern, .expected = self.expect.result_expected.ty };
}

/// The declared result with what the call's value becomes where it
/// goes: a fallible result is propagated or caught to its value, and
/// a value where a `T?` or `T!` is expected is lifted from a `T`.
pub fn resultMatch(self: *Checker, r: Checker.ResultType) Checker.ResultType {
    var out = r;
    while (true) {
        const p = self.ctx.types.get(out.pattern);
        const e = self.ctx.types.get(out.expected);
        if (p == .fallible and e != .fallible) {
            out.pattern = p.fallible.ok;
        } else if (p != .fallible and e == .fallible) {
            out.expected = e.fallible.ok;
        } else if (p != .optional and p != .fallible and e == .optional) {
            out.expected = e.optional;
        } else return out;
    }
}

/// Bind the parameters of `inf` that no argument other than a literal
/// binds by matching the declared result against the type expected
/// of it, as an argument is matched against its parameter. A
/// parameter an argument binds keeps its type, and the type the
/// result wants is kept for the diagnostic.
pub fn bindExpected(self: *Checker, inf: *Checker.Inference, r: Checker.ResultType) Error!void {
    if (!sema.containsTypeVar(self.ctx, r.pattern)) return;
    const want = try bindResult(self, inf.own, resultMatch(self, r));
    // A parameter a `none` fills is the optional itself: `o: Int? =
    // id(none)` is `id[Int?]`.
    const exact = try bindResult(self, inf.own, r);
    inf.result_mismatch = want.mismatch != null;
    for (inf.bound, want.bound, exact.bound) |*b, lifted, same| {
        const w = if (b.none) same else lifted;
        if (w.ty == sema.type_invalid or w.conflict != sema.type_invalid) continue;
        if (b.ty == sema.type_invalid) {
            b.ty = w.ty;
            b.expected = true;
        } else if (b.ty != w.ty) b.wanted = w.ty;
    }
}

/// The bindings of `own` that make declared result `r.pattern` match
/// `r.expected`.
pub fn bindResult(self: *Checker, own: []const SymbolId, r: Checker.ResultType) Error!Checker.Inference {
    var inf: Checker.Inference = .{ .own = own, .bound = try self.ctx.arena.allocator().alloc(Checker.Bound, own.len) };
    @memset(inf.bound, .{});
    try bindArg(self, &inf, r.pattern, r.expected, 0, 0);
    return inf;
}

/// Whether the binding of parameter `i` by argument `arg` came from a
/// literal.
pub fn onlyLiterals(self: *Checker, inf: Checker.Inference, i: usize, arg: u32) bool {
    _ = self;
    for (inf.literals.items) |lit| {
        if (lit.param == i and lit.arg == arg) return true;
    }
    return false;
}

/// An argument's type for inference, synthesized once: the call checks
/// the argument again, and a generic call nested in its arguments
/// would otherwise be synthesized twice at every level.
pub fn argType(self: *Checker, e: Sexp) Error!TypeId {
    self.tentative += 1;
    defer self.tentative -= 1;
    // A slice there is viewed as it is where the argument is checked.
    const saved_view = self.expect.view_arg;
    defer self.expect.view_arg = saved_view;
    self.expect.view_arg = e;
    if (e != .list or e.list.id == 0) return FlowCheck.synthQuiet(self, e);
    if (self.arg_types.get(e.list.id)) |ty| return ty;
    var ty = try FlowCheck.synthQuiet(self, e);
    if (literalResult(self, e)) |lit| ty = lit;
    // A write view written here binds the value it reaches where that
    // is copied out, as the slot then reads it (`writeViewRead`), and
    // the view only where no copy could be meant.
    if (ViewCheck.writtenWriteView(self, e, ty) != null) if (sema.copiedThrough(self.ctx, ty)) |value| {
        ty = value;
    };
    try self.arg_types.put(self.ctx.allocator, e.list.id, ty);
    return ty;
}

/// The literal or `none` a generic call binds like as an argument
/// (`literal_results`): the call itself, or one propagated with `!`
/// or `?`.
pub fn literalResult(self: *Checker, e: Sexp) ?TypeId {
    const call, const path: Checker.ResultPath = switch (e.kind() orelse return null) {
        .call => .{ e, .direct },
        .propagate => .{ ir.Propagate.value(e), .propagate },
        .propagate_none => .{ ir.PropagateNone.value(e), .propagate_none },
        else => return null,
    };
    if (!call.isKind(.call) or call.list.id == 0) return null;
    const r = self.literal_results.get(call.list.id) orelse return null;
    return if (r.path == path) r.ty else null;
}

/// The two types of a conflict, in argument order, each with where
/// it came from: `argument 2`, or the type expected of the result
/// (argument 0, which comes first). Two from one argument, in the
/// order they were found, also say where inside it: `the parameter
/// of argument 1` and `the result of argument 1`.
pub fn conflictText(self: *Checker, b: Checker.Bound) Error!struct { first: []const u8, first_ty: TypeId, first_arg: u32, first_from: []const u8, second: []const u8, second_arg: u32, second_from: []const u8, later: TypeId, one_arg: bool } {
    const one_arg = b.arg == b.conflict_arg and !b.at.deep and !b.conflict_at.deep and !b.at.eql(b.conflict_at);
    const b_first = b.arg < b.conflict_arg or one_arg;
    const later = if (b_first) b.conflict else b.ty;
    const first_ty = if (b_first) b.ty else b.conflict;
    const first_arg = @min(b.arg, b.conflict_arg);
    const second_arg = @max(b.arg, b.conflict_arg);
    return .{
        .first = try self.tyName(first_ty),
        .first_ty = first_ty,
        .first_arg = first_arg,
        .first_from = if (one_arg) try whereText(self, b.arg, b.at) else try boundFrom(self, first_arg),
        .second = try self.tyName(later),
        .second_arg = second_arg,
        .second_from = if (one_arg) try whereText(self, b.arg, b.conflict_at) else try boundFrom(self, second_arg),
        .later = later,
        .one_arg = one_arg,
    };
}

/// Where inside argument `arg` (`boundFrom`) a binding was found,
/// innermost first: `the result of argument 1`, `parameter 2 of the
/// result of argument 1`, `type argument 2 of argument 1`.
pub fn whereText(self: *Checker, arg: u32, at: Checker.Where) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    var i = at.len;
    while (i > 0) {
        i -= 1;
        const step = at.steps[i];
        switch (step.kind) {
            .param => if (step.count == 1) try out.appendSlice(a, "the parameter of ") else try out.print(a, "parameter {d} of ", .{step.index + 1}),
            .result => try out.appendSlice(a, "the result of "),
            .type_arg => if (step.count == 1) try out.appendSlice(a, "the type argument of ") else try out.print(a, "type argument {d} of ", .{step.index + 1}),
        }
    }
    try out.appendSlice(a, try boundFrom(self, arg));
    return out.items;
}

/// Where inference took a binding from, for messages: argument
/// `arg`, or for 0 the type expected of the result.
pub fn boundFrom(self: *Checker, arg: u32) Error![]const u8 {
    if (arg == 0) return "the type expected of the result";
    return self.ctx.arena.allocator().print("argument {d}", .{arg});
}

/// A generic function's type arguments, one per parameter in `own`,
/// from the arguments of a call, which fill `f.params[skip..]`, and
/// the type expected of its result (`inferBindings`). Null after a
/// diagnostic.
pub fn inferCallTypeArgs(self: *Checker, f: FunctionType, own: []const SymbolId, args: []const Sexp, info: Checker.ParamInfo, skip: usize, callee: []const u8, pos: u32) Error!?[]TypeId {
    const call = self.expect.current_call orelse Sexp.nil;
    const inf = try inferBindings(self, own, args, .{ .params = .{ .params = f.params[@min(skip, f.params.len)..], .names = info.names, .defaults = info.defaults } }, expectedResult(self, f.returns));
    const result = try self.ctx.arena.allocator().alloc(TypeId, own.len);
    for (inf.bound, result) |b, *r| r.* = b.ty;
    if (call == .list and call.list.id != 0) try noteResultBinding(self, call.list.id, f, own, inf, callee);
    const parens = if (f.params.len > skip) "(...)" else "()";
    var ok = true;
    var lambdas_reported: u64 = 0;
    for (inf.bound, own, 0..) |b, param, i| {
        const pname = self.ctx.symbols.items[param].name;
        if (b.ty == sema.type_invalid) {
            ok = false;
            if (try lambdaLeftUnbound(self, &inf, param, &lambdas_reported)) continue;
            if (inf.poisoned) continue;
            // An argument of another shape says why, as for any call.
            if (inf.mismatch) |m| if (m.arg <= args.len) {
                try self.errAt(args[m.arg - 1], "type mismatch: expected `{s}`, got `{s}`", .{ try self.tyName(m.pattern), try self.tyName(m.actual) });
                break;
            };
            if (inf.result_mismatch) {
                try self.err(pos, "type mismatch: expected `{s}`, but `{s}` returns `{s}`", .{ try self.tyName(self.expect.result_expected.ty), callee, try self.tyName(f.returns) });
                break;
            }
            try self.err(pos, "cannot infer `{s}` for `{s}` from its arguments or the type expected of its result; {s}", .{ pname, callee, try inferHint(self, f, own, result, i, callee, parens) });
        } else if (b.conflict != sema.type_invalid) {
            ok = false;
            if (self.ctx.symbols.items[param].kind == .param) {
                const c = try conflictText(self, b);
                try self.err(pos, "conflicting values for `{s}` in the call to `{s}`: `{s}` ({s}) and `{s}` ({s})", .{ pname, callee, c.first, c.first_from, c.second, c.second_from });
                continue;
            }
            // The later argument's type is suggested, when the earlier
            // argument can have it; otherwise a conversion.
            const c = try conflictText(self, b);
            const literal = onlyLiterals(self, inf, i, c.first_arg);
            if (if (literal) literalFits(self, c.first_ty, c.later) else CompatCheck.compatible(self.ctx, c.first_ty, c.later)) {
                const fix = if (try bracketHint(self, result, i, c.later)) |brackets|
                    try self.ctx.arena.allocator().print("give it in brackets: `{s}[{s}]{s}`", .{ callee, brackets, parens })
                else
                    "give it in brackets, naming each array, slice, or function type in them with a `type` alias";
                try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` ({s}) and `{s}` ({s}); {s}", .{ pname, callee, c.first, c.first_from, c.second, c.second_from, fix });
            } else if (!c.one_arg and sema.isNumeric(self.ctx, c.first_ty) and sema.isNumeric(self.ctx, c.later)) {
                // Convert the argument that is not a literal; the
                // type expected of the result is not converted.
                const second = literal or c.first_arg == 0;
                const arg = if (second) c.second_arg else c.first_arg;
                try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` ({s}) and `{s}` ({s}); convert argument {d} with `{s}(...)`", .{ pname, callee, c.first, c.first_from, c.second, c.second_from, arg, if (second) c.first else c.second });
            } else {
                try self.err(pos, "conflicting types for `{s}` in the call to `{s}`: `{s}` ({s}) and `{s}` ({s}); they must have one type", .{ pname, callee, c.first, c.first_from, c.second, c.second_from });
            }
            ok = false;
        } else if (try viewedClosureBound(self, b.ty, pname, callee, pos) or !try valueBindingFits(self, param, b, callee, pos) or !try inferredTypeFits(self, b, args)) ok = false;
    }
    return if (ok) result else null;
}

/// Whether inference bound type parameter `pname` of `callee` to
/// what a view of a closure gives (`?f` where `?T` goes): a closure is
/// viewed only where `?fun(...)` is written, and no value holds one.
/// Reported.
pub fn viewedClosureBound(self: *Checker, ty: TypeId, pname: []const u8, callee: []const u8, pos: u32) Error!bool {
    if (!sema.holdsCallable(self.ctx, ty)) return false;
    if (sema.callableFn(self.ctx, ty) != null) {
        try self.err(pos, "`{s}` cannot take a callable view for `{s}`: a `{s}` is only a parameter's, a local's, or a result's type, and no value holds one", .{ callee, pname, try self.tyName(ty) });
        return true;
    }
    if (sema.holdsMarkedView(self.ctx, ty)) return false;
    try self.err(pos, "`{s}` cannot take a view of a closure for `{s}`: a closure is passed as a view (`?f`) only to a parameter declared `?fun(...)` or `?sub(...)`", .{ callee, pname });
    return true;
}

/// Whether the value inference gave value parameter `param` (when it
/// is one) is one it takes: a value its type holds, or a compile-time
/// parameter of the same type. Reports one that is not.
pub fn valueBindingFits(self: *Checker, param: SymbolId, b: Checker.Bound, callee: []const u8, pos: u32) Error!bool {
    const p = self.ctx.symbols.items[param];
    if (p.kind != .param or self.isPoison(p.ty)) return true;
    const from = if (b.expected) "the type expected of the result" else try boundFrom(self, b.arg);
    switch (self.ctx.types.get(b.ty)) {
        .ct_value => |v| if (!sema.intFits(self.ctx, p.ty, v.int)) {
            const name = try self.tyName(p.ty);
            try self.err(pos, "{s} gives `{s}` of `{s}` the value `{d}`, which {s} `{s}` cannot hold", .{ from, p.name, callee, v.int, resolve.an(name), name });
            return false;
        },
        .ct_param => |sym| {
            const ty = self.ctx.symbols.items[self.ctx.localSym(sym)].ty;
            if (!self.isPoison(ty) and ty != p.ty) {
                try self.err(pos, "{s} gives `{s}` of `{s}` the compile-time `{s}` `{s}`; `{s}` is a `{s}`", .{ from, p.name, callee, try self.tyName(ty), self.ctx.symbols.items[self.ctx.localSym(sym)].name, p.name, try self.tyName(p.ty) });
                return false;
            }
        },
        else => {},
    }
    return true;
}

/// A type inference took from an argument must fit
/// `sema.max_value_bytes`, as a spelled one must where it is spelled:
/// an array too large is reported at the argument.
pub fn inferredTypeFits(self: *Checker, b: Checker.Bound, args: []const Sexp) Error!bool {
    if (b.expected or b.arg == 0 or b.arg > args.len) return true;
    const arg = args[b.arg - 1];
    const value = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
    return sema.checkArraysIn(self.ctx, self.startOf(value), b.ty);
}

/// What a generic call's result says to the calls around it: whether
/// it gives a type parameter that only literals gave a type, or is an
/// optional nothing gave one (`literal_results`), and, where an
/// argument gives the parameter another type than the expected one,
/// the fix for the mismatch that follows (`result_hints`): converting
/// the result.
pub fn noteResultBinding(self: *Checker, id: parser.NodeId, f: FunctionType, own: []const SymbolId, inf: Checker.Inference, callee: []const u8) Error!void {
    _ = self.literal_results.remove(id);
    _ = self.result_hints.remove(id);
    const path: Checker.ResultPath, const value = switch (self.ctx.types.get(f.returns)) {
        .fallible => |inner| .{ .propagate, inner.ok },
        .optional => |inner| .{ .propagate_none, inner },
        else => .{ .direct, f.returns },
    };
    const tv = switch (self.ctx.types.get(value)) {
        .type_var => |tv| tv,
        else => return,
    };
    const i = std.mem.findScalar(SymbolId, own, self.ctx.localSym(tv)) orelse return;
    const b = inf.bound[i];
    if (b.ty == sema.type_invalid) {
        // `id(none)` and `nothing()` give some optional.
        if ((path == .direct and b.none) or path == .propagate_none) {
            try self.literal_results.put(self.ctx.allocator, id, .{ .ty = self.t().none_id, .path = .direct });
        }
        return;
    }
    if (b.conflict != sema.type_invalid) return;
    if (!b.expected and onlyLiterals(self, inf, i, b.arg)) {
        const lit = if (b.ty == self.t().float_id) self.t().float_literal_id else self.t().int_literal_id;
        try self.literal_results.put(self.ctx.allocator, id, .{ .ty = lit, .path = path });
    }
    if (path == .propagate_none) return;
    if (b.wanted == sema.type_invalid) return;
    const a = self.ctx.arena.allocator();
    const took = try a.print("`{s}` takes `{s} = {s}` from argument {d}", .{ callee, self.ctx.symbols.items[self.ctx.localSym(tv)].name, try self.tyName(b.ty), b.arg });
    if (sema.isNumeric(self.ctx, b.ty) and sema.isNumeric(self.ctx, b.wanted)) {
        try self.result_hints.put(self.ctx.allocator, id, try a.print("{s}; convert its result with `{s}(...)`", .{ took, try self.tyName(b.wanted) }));
        return;
    }
    // Brackets pass the type on to an argument that takes it from
    // where it goes, such as a nested generic call.
    const types = try a.alloc(TypeId, inf.bound.len);
    for (inf.bound, types) |bound, *ty| ty.* = bound.ty;
    const brackets = (try bracketHint(self, types, i, b.wanted)) orelse return self.result_hints.put(self.ctx.allocator, id, took);
    try self.result_hints.put(self.ctx.allocator, id, try a.print("{s}; to pass `{s}` on to it, give it in brackets: `{s}[{s}](...)`", .{ took, try self.tyName(b.wanted), callee, brackets }));
}

/// Whether a literal of type `lit` (an integer or float literal's
/// default type) can be a value of `ty`. Next to a type parameter, a
/// literal is reported where the argument is checked.
pub fn literalFits(self: *Checker, lit: TypeId, ty: TypeId) bool {
    if (self.ctx.types.get(ty) == .type_var) return true;
    const literal = if (lit == self.t().float_id) self.t().float_literal_id else self.t().int_literal_id;
    return CompatCheck.compatible(self.ctx, literal, ty);
}

/// The bracket list a diagnostic suggests: each type parameter's
/// inferred type, or `...` when unknown, with `at` for the one at
/// `index`. Null when a type in it has no expression spelling
/// (`spelledInBrackets`).
pub fn bracketHint(self: *Checker, types: []const TypeId, index: usize, at: ?TypeId) Error!?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    for (types, 0..) |ty, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        const shown = if (i == index) at orelse sema.type_invalid else ty;
        if (shown != sema.type_invalid and !CompatCheck.spelledInBrackets(self.ctx, shown)) return null;
        try buf.appendSlice(a, if (shown == sema.type_invalid) "..." else try self.tyName(shown));
    }
    return buf.items;
}

/// What to write for type parameter `index` of `callee`, which nothing
/// determines: the bracket list, or, where a type in it has no
/// expression spelling, the type where the value goes when the
/// result holds the parameter.
pub fn inferHint(self: *Checker, f: FunctionType, own: []const SymbolId, types: []const TypeId, index: usize, callee: []const u8, parens: []const u8) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const pname = self.ctx.symbols.items[own[index]].name;
    if (try bracketHint(self, types, index, null)) |brackets| return a.print("give `{s}` in brackets: `{s}[{s}]{s}`", .{ pname, callee, brackets, parens });
    // The result with each known type argument in place.
    const args = try a.alloc(TypeId, own.len);
    for (own, types, args) |p, ty, *arg| arg.* = if (ty == sema.type_invalid) try self.ctx.intern(.{ .type_var = self.ctx.ref(p) }) else ty;
    const shown = try sema.substituteType(self.ctx, f.returns, .{ .params = own, .args = args });
    const holds = (try sema.substituteType(self.ctx, f.returns, .{ .params = own[index .. index + 1], .args = &.{self.t().void_id} })) != f.returns;
    if (holds) return a.print("give the type where the value goes: `x: {s} = {s}{s}`, with a type in place of `{s}`", .{ try self.tyName(shown), callee, parens, pname });
    return a.print("give `{s}` in brackets, naming each array, slice, or function type in them with a `type` alias", .{pname});
}

/// Bind the type parameters of `inf` in `pattern`, a parameter's type,
/// so that it matches `actual`, argument number `arg`'s type. Where the
/// shapes differ nothing is bound, and checking the argument reports
/// the mismatch.
pub fn noteMismatch(self: *Checker, inf: *Checker.Inference, pattern: TypeId, actual: TypeId, arg: u32) void {
    if (inf.mismatch != null or self.ctx.types.get(actual) == .none_literal) return;
    inf.mismatch = .{ .arg = arg, .pattern = pattern, .actual = actual };
}

pub fn bindArg(self: *Checker, inf: *Checker.Inference, pattern: TypeId, actual: TypeId, arg: u32, depth: u8) Error!void {
    if (depth > 32 or self.isPoison(actual)) return;
    const at = self.ctx.types.get(actual);
    switch (self.ctx.types.get(pattern)) {
        .type_var => |tv| {
            const i = std.mem.findScalar(SymbolId, inf.own, self.ctx.localSym(tv)) orelse return;
            const value = CompatCheck.readValue(self.ctx, actual);
            switch (self.ctx.types.get(value)) {
                .none_literal => {
                    if (depth == 0) inf.bound[i].none = true;
                    return;
                },
                .noreturn, .void, .invalid, .unknown => return,
                .int_literal, .float_literal => return inf.literals.append(self.ctx.arena.allocator(), .{ .param = i, .ty = ExprCheck.canonical(self, value), .arg = arg }),
                else => {},
            }
            const b = &inf.bound[i];
            if (inf.exact > 0 and b.held_ty == sema.type_invalid) b.held_ty = value;
            if (b.ty == sema.type_invalid) {
                b.ty = value;
                b.arg = arg;
                b.at = inf.at;
                b.text_view = inf.viewing;
            } else if (b.ty == value) {
                if (!inf.viewing) b.text_view = false;
            } else if (b.ty == self.t().string_id and inf.viewing and (value == self.t().string_view_id or value == self.t().static_id)) {
                // A `?T` meets the read view of the `String` that `T`
                // is, and a `Static`, which is read as one (`meets`).
            } else if (b.text_view and value == self.t().string_id) {
                b.ty = value;
                b.arg = arg;
                b.at = inf.at;
                b.text_view = false;
            } else if (b.ty != value and b.conflict == sema.type_invalid) {
                b.conflict = value;
                b.conflict_arg = arg;
                b.conflict_at = inf.at;
            }
        },
        // A value where a `T?` goes is lifted; a value where a view
        // goes is matched as its view would be.
        .optional => |p| try bindArg(self, inf, p, if (at == .optional) at.optional else actual, arg, depth + 1),
        .read_view, .write_view => |p| {
            const held: u8 = @intFromBool(self.ctx.types.get(pattern) == .write_view);
            inf.exact += held;
            defer inf.exact -= held;
            const viewing = inf.viewing;
            defer inf.viewing = viewing;
            inf.viewing = (at == .string_view or at == .static) and self.ctx.types.get(pattern) == .read_view;
            const viewed = switch (at) {
                .read_view, .write_view => |inner| inner,
                else => actual,
            };
            try bindArg(self, inf, p, try reachedForView(self, p, viewed), arg, depth + 1);
        },
        .fallible => |p| if (at == .fallible) {
            try bindArg(self, inf, p.ok, at.fallible.ok, arg, depth + 1);
            try bindSet(self, inf, p.set, at.fallible.set, arg);
        } else noteMismatch(self, inf, pattern, actual, arg),
        .shared => |p| if (at == .shared) {
            inf.exact += 1;
            defer inf.exact -= 1;
            try bindArg(self, inf, p, at.shared, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        .weak => |p| if (at == .weak) {
            inf.exact += 1;
            defer inf.exact -= 1;
            try bindArg(self, inf, p, at.weak, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        // A `![]T` goes where a `[]T` does.
        .slice => |p| if (at == .slice)
            try bindArg(self, inf, p.elem, at.slice.elem, arg, depth + 1)
        else if (sema.writeSliceElem(self.ctx, actual)) |elem|
            try bindArg(self, inf, p.elem, elem, arg, depth + 1)
        else if (sema.viewedElem(self.ctx, actual)) |elem|
            // An array or a List viewed as a slice (`?a`, `!v`, a
            // temporary).
            try bindArg(self, inf, p.elem, elem, arg, depth + 1)
        else
            noteMismatch(self, inf, pattern, actual, arg),
        .array => |p| if (at == .array) {
            inf.exact += 1;
            defer inf.exact -= 1;
            try bindArg(self, inf, p.elem, at.array.elem, arg, depth + 1);
            try bindArg(self, inf, p.len, at.array.len, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        .simd => |p| if (at == .simd) {
            inf.exact += 1;
            defer inf.exact -= 1;
            try bindArg(self, inf, p.elem, at.simd.elem, arg, depth + 1);
            try bindArg(self, inf, p.len, at.simd.len, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        // A value parameter binds exactly the value (or parameter)
        // the argument's type holds there: an array length, or a
        // generic type's value argument.
        .ct_param => |p| {
            const i = std.mem.findScalar(SymbolId, inf.own, self.ctx.localSym(p)) orelse return;
            if (at != .ct_value and at != .ct_param) return;
            const b = &inf.bound[i];
            if (b.ty == sema.type_invalid) {
                b.ty = actual;
                b.arg = arg;
                b.at = inf.at;
            } else if (b.ty != actual and b.conflict == sema.type_invalid) {
                b.conflict = actual;
                b.conflict_arg = arg;
                b.conflict_at = inf.at;
            }
        },
        .slot => |p| if (at == .slot) {
            inf.exact += 1;
            defer inf.exact -= 1;
            try bindArg(self, inf, p, at.slot, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        .parameterized_nominal => |pn| if (sameGeneric(self, at, pn.sym)) |held| {
            inf.exact += 1;
            defer inf.exact -= 1;
            const outer = inf.at;
            defer inf.at = outer;
            for (pn.args, held.args, 0..) |pa, aa, k| {
                inf.at = outer.with(.{ .kind = .type_arg, .index = @intCast(@min(k, 255)), .count = @intCast(@min(pn.args.len, 255)) });
                try bindArg(self, inf, pa, aa, arg, depth + 1);
            }
        } else noteMismatch(self, inf, pattern, actual, arg),
        // What a callable view gives: a closure's, a function's,
        // or an owned closure's function type.
        .callable => |pf| switch (at) {
            .callable, .shared => |inner| try bindArg(self, inf, pf, inner, arg, depth + 1),
            .function => try bindArg(self, inf, pf, actual, arg, depth + 1),
            else => noteMismatch(self, inf, pattern, actual, arg),
        },
        .function => |pf| if (at == .function and at.function.params.len == pf.params.len) {
            inf.exact += 1;
            defer inf.exact -= 1;
            const outer = inf.at;
            defer inf.at = outer;
            for (pf.params, at.function.params, 0..) |pp, ap, k| {
                inf.at = outer.with(.{ .kind = .param, .index = @intCast(@min(k, 255)), .count = @intCast(@min(pf.params.len, 255)) });
                try bindArg(self, inf, pp, ap, arg, depth + 1);
            }
            inf.at = outer.with(.{ .kind = .result });
            try bindReturns(self, inf, pf.returns, at.function.returns, arg, depth + 1);
        } else noteMismatch(self, inf, pattern, actual, arg),
        else => {},
    }
}

/// The value a view argument of type `actual` reaches where a view of
/// `pattern` goes: through a box, a counted handle, and a frozen
/// value's handle, as the view table makes it (`sema.viewAs`). A pattern
/// that names a type of its own matches what it reaches: `first(?bx)`
/// of a `^List[P]` binds `T = P` in `first[T](xs: ?List[T])`, as
/// `first[P](?bx)` views it. A type parameter bounded by an API of
/// the program's own, which no handle provides, binds the value when
/// the box or handle does not provide it and the value does:
/// `f(?fz)` of a `*Frozen[Square]` is `f[Square]`. Any other type
/// parameter binds the box or handle itself.
pub fn reachedForView(self: *Checker, pattern: TypeId, actual: TypeId) Error!TypeId {
    switch (self.ctx.types.get(pattern)) {
        .type_var => |tv| {
            const apis = self.ctx.symbols.items[self.ctx.localSym(tv)].user_apis;
            if (apis.len == 0) return actual;
            const reached = GenericCheck.reachedValue(self.ctx, actual);
            if (reached == actual) return actual;
            for (apis) |api| if ((try sema.provides(self.ctx, actual, api)) != null) return actual;
            for (apis) |api| if ((try sema.provides(self.ctx, reached, api)) == null) return actual;
            return reached;
        },
        .shared, .weak => return actual,
        else => return if (sema.boxedType(self.ctx, pattern) != null) actual else GenericCheck.reachedValue(self.ctx, actual),
    }
}

/// A function's result where a function type's result `pattern`
/// goes: as `bindArg` binds it, except that a closure that returns
/// nothing, or fails with nothing, binds the `R` of `-> R` or
/// `-> R!` to `Void`, as `run[Void](...)` would.
pub fn bindReturns(self: *Checker, inf: *Checker.Inference, pattern: TypeId, actual: TypeId, arg: u32, depth: u8) Error!void {
    var p = pattern;
    var a = actual;
    if (self.ctx.types.get(p) == .fallible and self.ctx.types.get(a) == .fallible) {
        try bindSet(self, inf, self.ctx.types.get(p).fallible.set, self.ctx.types.get(a).fallible.set, arg);
        p = self.ctx.types.get(p).fallible.ok;
        a = self.ctx.types.get(a).fallible.ok;
    }
    if (a != self.t().void_id) return bindArg(self, inf, pattern, actual, arg, depth);
    const tv = switch (self.ctx.types.get(p)) {
        .type_var => |tv| tv,
        else => return bindArg(self, inf, pattern, actual, arg, depth),
    };
    const i = std.mem.findScalar(SymbolId, inf.own, self.ctx.localSym(tv)) orelse return;
    const b = &inf.bound[i];
    if (b.ty == sema.type_invalid) {
        b.ty = a;
        b.arg = arg;
        b.at = inf.at;
    } else if (b.ty != a and b.conflict == sema.type_invalid) {
        b.conflict = a;
        b.conflict_arg = arg;
        b.conflict_at = inf.at;
    }
}

/// Which of `f`'s compile-time parameters are set parameters, as
/// `GenericCall.sets` records them.
pub fn setArgs(self: *Checker, f: sema.FunctionType) u64 {
    var sets: u64 = 0;
    for (f.ct_params, 0..) |slot, i| {
        if (i < 64 and sema.isSetParam(self.ctx, slot)) sets |= @as(u64, 1) << @intCast(i);
    }
    return sets;
}

/// Whether `f` fails with one of its set parameters (`GenericCall.fails_by_set`).
pub fn failsBySet(self: *Checker, f: sema.FunctionType) bool {
    const ret = self.ctx.types.get(f.returns);
    return ret == .fallible and sema.isSetParam(self.ctx, ret.fallible.set);
}

/// The set a function-typed argument fails with, `actual`, where
/// the set parameter `pattern` goes: a callback failing with `Bad`
/// binds `E = Bad`, and one failing with any error `E = error`. A
/// closure literal's set is what it is checked against, so it binds
/// none: the set comes from another argument, the expected result,
/// or brackets.
pub fn bindSet(self: *Checker, inf: *Checker.Inference, pattern: TypeId, actual: TypeId, arg: u32) Error!void {
    if (!sema.isSetParam(self.ctx, pattern) or self.isPoison(actual)) return;
    const i = std.mem.findScalar(SymbolId, inf.own, self.ctx.localSym(self.ctx.types.get(pattern).type_var)) orelse return;
    if (inf.lambda) {
        if (i < 64) inf.lambda_sets |= @as(u64, 1) << @intCast(i);
        inf.lambda_arg = arg;
        return;
    }
    const b = &inf.bound[i];
    if (b.ty == sema.type_invalid) {
        b.ty = actual;
        b.arg = arg;
        b.at = inf.at;
    } else if (b.ty != actual and b.conflict == sema.type_invalid) {
        b.conflict = actual;
        b.conflict_arg = arg;
        b.conflict_at = inf.at;
    }
}

/// The instance of generic type `sym` that an argument of type `at`
/// is, or that the handle it is gives a view of: `*Cell[T]` where
/// `!Cell[T]` goes.
pub fn sameGeneric(self: *Checker, at: sema.Type, sym: sema.SymbolRef) ?sema.ParamNominal {
    switch (at) {
        .parameterized_nominal => |p| if (p.sym == sym) return p,
        .shared => |inner| switch (self.ctx.types.get(inner)) {
            .parameterized_nominal => |p| if (p.sym == sym) return p,
            else => {},
        },
        else => {},
    }
    return null;
}

/// Values Zig can evaluate at compile time.
pub fn isComptimeKnown(self: *Checker, e: Sexp) bool {
    switch (e) {
        .src => {
            const s = self.text(e);
            if (CompatCheck.isLiteralText(s) or std.mem.eql(u8, s, "none")) return true;
            const id = self.ctx.symbolOf(e) orelse (lookupQuiet(self, e) orelse return false);
            return self.ctx.symbols.items[id].flags.comptime_known;
        },
        .list => {
            const h = e.kind() orelse return false;
            return switch (h) {
                .enum_lit, .symbol => true,
                // A template of constant slots, fixed text
                // (`templateFolds`).
                .template => self.ctx.typeOf(e) == self.t().static_id,
                // `cap[8]`: a compile-time call, whose value the
                // checker computed.
                .ct_call => if (self.ctx.get(.ct_calls, e)) |c| c.result != null else false,
                // `$variants(T)`, and `$embed("f")`, whose bytes Zig
                // reads when it compiles.
                .builtin => std.mem.eql(u8, self.text(ir.Builtin.name(e)), "variants") or std.mem.eql(u8, self.text(ir.Builtin.name(e)), "embed"),
                // `U8(65)`: a constant integer as an integer type;
                // `target.has(.avx2)`: a fact of the target.
                .call => ExprCheck.constInt(self, e) != null or isTargetCall(self, e),
                .not => isComptimeKnown(self, ir.get(e, .operand)),
                .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or" => isComptimeKnown(self, ir.get(e, .left)) and isComptimeKnown(self, ir.get(e, .right)),
                // Rig checks arithmetic only on constants: a compile-time
                // parameter or a `=!` binding of one differs per call.
                .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => ExprCheck.constInt(self, e) != null or (isCtArithmetic(self, e) and !mentionsCtLocal(self, e)),
                .member => blk: {
                    const obj = ir.Member.object(e);
                    // A number type's limits.
                    if (namesNumberType(self, obj)) break :blk true;
                    // `lib.Mode.a`: a variant of an imported type.
                    if (obj.isKind(.member)) {
                        const foreign = foreignMember(self, obj) orelse break :blk false;
                        break :blk foreign.kind == .nominal_type;
                    }
                    if (obj != .src) break :blk false;
                    const id = lookupQuiet(self, obj) orelse break :blk false;
                    const sym = self.ctx.symbols.items[id];
                    if (sym.kind != .module) break :blk sym.kind == .nominal_type;
                    // An imported module's constant.
                    const foreign = foreignMember(self, e) orelse break :blk false;
                    break :blk foreign.flags.comptime_known;
                },
                else => false,
            };
        },
        else => return false,
    }
}

/// A call of a function of `std.target` on constants,
/// `target.has(.avx2)`: known at compile time, to Zig alone
/// (`SymbolFlags.per_target`).
pub fn isTargetCall(self: *Checker, e: Sexp) bool {
    const callee = ir.Call.callee(e);
    if (!callee.isKind(.member)) return false;
    const f = foreignMember(self, callee) orelse return false;
    if (f.kind != .function or !f.flags.per_target) return false;
    for (ir.Call.args(e)) |a| if (!isComptimeKnown(self, a)) return false;
    return true;
}

/// Whether `obj` names a number type: a built-in one, or an alias of
/// one in this module or an imported one.
pub fn namesNumberType(self: *Checker, obj: Sexp) bool {
    if (obj.isKind(.member)) {
        const m = ir.Member.object(obj);
        if (m != .src) return false;
        const id = lookupQuiet(self, m) orelse return false;
        if (self.ctx.symbols.items[id].kind != .module) return false;
        const found = foreignLookup(self, id, self.text(ir.Member.name(obj))) orelse return false;
        return found.sym.kind == .type_alias and sema.isNumeric(found.ctx, found.sym.ty);
    }
    if (obj != .src) return false;
    const id = lookupQuiet(self, obj) orelse return resolve.isNumericTypeName(self.text(obj));
    const sym = self.ctx.symbols.items[id];
    return sym.kind == .type_alias and sema.isNumeric(self.ctx, sym.ty);
}

/// The symbol `module.name` names in an imported module.
pub fn foreignMember(self: *Checker, e: Sexp) ?sema.Symbol {
    const m = ir.Member.object(e);
    if (m != .src) return null;
    const id = lookupQuiet(self, m) orelse return null;
    if (self.ctx.symbols.items[id].kind != .module) return null;
    return (foreignLookup(self, id, self.text(ir.Member.name(e))) orelse return null).sym;
}

/// Arithmetic whose operands are each known at compile time.
pub fn isCtArithmetic(self: *Checker, e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .neg => isCtOperand(self, ir.Neg.operand(e)),
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => isCtOperand(self, ir.get(e, .left)) and isCtOperand(self, ir.get(e, .right)),
        else => false,
    };
}

/// An operand of compile-time arithmetic: a value known at compile
/// time, or arithmetic on such values. (Each node is classified
/// once: `isComptimeKnown` of arithmetic would classify it again.)
pub fn isCtOperand(self: *Checker, o: Sexp) bool {
    if (!CompatCheck.isArithmetic(o)) return isComptimeKnown(self, o);
    return isCtArithmetic(self, o) or ExprCheck.constInt(self, o) != null;
}

/// Whether `e` names a compile-time parameter or a `=!` binding in a
/// function, whose value differs from call to call.
pub fn mentionsCtLocal(self: *Checker, e: Sexp) bool {
    return switch (e) {
        .src => {
            const id = self.ctx.symbolOf(e) orelse return false;
            const sym = self.ctx.symbols.items[id];
            return sym.flags.comptime_known and sym.scope != self.module_scope;
        },
        .list => for (e.items()) |c| {
            if (mentionsCtLocal(self, c)) break true;
        } else false,
        else => false,
    };
}

/// Construct an object (`User(name: ...)`). Field types go through
/// `subst` (generic constructors) or are imported from `foreign`.
pub fn construct(self: *Checker, sym_id: SymbolId, args: []const Sexp, pos: u32, subst: TypeSubst, foreign: ?Checker.ForeignFields) Error!TypeId {
    const sym = if (foreign) |fo| fo.ctx.symbols.items[sym_id] else self.ctx.symbols.items[sym_id];
    const result = if (foreign) |fo|
        try self.ctx.intern(.{ .nominal = .{ .module_id = fo.module_id, .sym = sym_id } })
    else if (subst.isEmpty())
        try self.ctx.intern(.{ .nominal = self.ctx.ref(sym_id) })
    else
        try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.ref(sym_id), .args = subst.args } });
    const fields = sym.fields orelse return badCall(self, args, pos, "opaque type `{s}` cannot be constructed", .{sym.name});
    const is_enum = for (fields) |f| {
        if (f.is_variant) break true;
    } else false;
    if (is_enum) return badCall(self, args, pos, "`{s}` is an enum; construct a variant with `{s}.name` or `.name(...)`", .{ sym.name, sym.name });
    for (args) |x| if (x.isKind(.spread)) {
        try self.objectUpdate(args, fields, result, sym.name);
        return result;
    };
    // `T()` of a type whose every field has a default makes the value
    // those defaults give, which the type itself chose: any module
    // may make one.
    if (!(args.len == 0 and everyFieldDefaulted(fields))) try checkConstructible(self, sym, fields, if (foreign) |fo| fo.module_id else null, pos, args.len == 0);
    const origin = if (sema.isProxy(sym)) sema.proxyOrigin(self.ctx, sym) else null;
    try checkFieldArgs(self, args, fields, .{
        .owner = sym.name,
        .decl_pos = if (origin) |o| o.pos else sym.decl_pos,
        .module_id = if (origin) |o| o.module_id else 0,
        .pos = pos,
        .subst = subst,
        .foreign = foreign,
        .kind = .constructor,
        .instance = result,
    });
    if (sema.namedNoneOf(self.ctx, result)) |none| try checkNoneArg(self, args, fields, none, sym.name);
    return result;
}

/// A constructor of an object that names its none (`none id == 0`)
/// given that value, as a constant, for its field: no value of the
/// object holds it. A value known only when the program runs is
/// checked then (`rig.notNone`).
pub fn checkNoneArg(self: *Checker, args: []const Sexp, fields: []const Field, none: sema.NamedNone, name: []const u8) Error!void {
    var data: usize = 0;
    for (fields) |f| {
        if (!f.is_method and !f.is_variant) data += 1;
    }
    for (args) |a| {
        const value = if (a.isKind(.kwarg)) blk: {
            if (!std.mem.eql(u8, self.text(ir.Kwarg.name(a)), none.field)) continue;
            break :blk ir.Kwarg.value(a);
        } else if (data == 1) a else continue;
        const is_none = if (none.variant) |v|
            std.mem.eql(u8, constVariant(self, value) orelse "", v)
        else switch (sema.constIntBy(self.ctx, value, resolve.ConstNames{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params })) {
            .value => |v| v == none.value,
            else => false,
        };
        if (is_none) try self.errAt(value, "a `{s}` never holds `{s}` {s}, which is what a `{s}?` holds for `none`; write `none` where no `{s}` is meant", .{ name, none.field, sourceText(self, value), name, name });
    }
}

/// The variant a plain enum's value `e` is when the checker knows it:
/// `.empty`, `Kind.empty`, a constant, a compile-time call's value, or
/// a binding that never changes of one (`fixed_variants`), as
/// `constIntBy` knows an integer's. Null for any other value.
pub fn constVariant(self: *Checker, e: Sexp) ?[]const u8 {
    if (e.isKind(.enum_lit)) return self.text(ir.EnumLit.name(e));
    if (e.isKind(.member) and StdFormCheck.isTypeName(self, ir.Member.object(e))) return self.text(ir.Member.name(e));
    if (sema.cteval.recorded(self.ctx, e)) |r| return if (r.value == .variant) sema.cteval.variantName(self.ctx, r.ty, r.value.variant) else null;
    if (e == .src) if (self.ctx.symbolOf(e)) |id| if (self.fixed_variants.get(id)) |v| return v;
    const c = sema.patternConst(self.ctx, e) orelse return null;
    const sc = sema.constScalar(c) orelse return null;
    return if (sc == .variant) sc.variant else null;
}

/// Whether every data field of a type has a default, so `T()` makes
/// a value (variants and methods are no fields).
pub fn everyFieldDefaulted(fields: []const Field) bool {
    for (fields) |f| {
        if (f.is_method or f.is_variant) continue;
        if (f.default == null) return false;
    }
    return true;
}

/// Another module's object is constructed here only when every one
/// of its fields is `pub`; a private field is that module's to set.
/// (`T()` of a type whose every field has a default is made anywhere:
/// `construct`.) `empty` is a call with no arguments, which names the
/// fields with no default. The standard library is one library: its
/// modules construct one another's objects (`io.stdin()` makes a
/// `file.File`).
pub fn checkConstructible(self: *Checker, sym: sema.Symbol, fields: []const Field, module: ?u32, pos: u32, empty: bool) Error!void {
    const m = module orelse if (sema.isProxy(sym)) sym.from.module_id else return;
    const foreign = self.ctx.foreign_semas.get(m) orelse return;
    if (foreign.is_std and self.ctx.is_std) return;
    var private: std.ArrayList(u8) = .empty;
    defer private.deinit(self.ctx.allocator);
    var count: usize = 0;
    // A read-only field (`pub ?name: T`) is set by its module only,
    // as a private one is.
    var read_only: usize = 0;
    for (fields) |f| {
        if (f.is_method or f.is_variant or (f.is_pub and !f.read_only)) continue;
        try private.appendSlice(self.ctx.allocator, if (count == 0) "`" else ", `");
        try private.appendSlice(self.ctx.allocator, f.name);
        try private.append(self.ctx.allocator, '`');
        count += 1;
        if (f.read_only) read_only += 1;
    }
    if (count == 0) return;
    const tname = if (module != null) try self.ctx.arena.allocator().print("{s}.{s}", .{ foreign.name, sym.name }) else sym.name;
    const kind = if (read_only == 0) "private" else if (read_only == count) "read-only" else "private or read-only";
    const which = .{ if (count == 1) "field" else "fields", private.items, if (count == 1) "is" else "are", kind };
    if (empty) {
        // `T()` makes an empty value only from defaults for every field.
        var bare: std.ArrayList(u8) = .empty;
        defer bare.deinit(self.ctx.allocator);
        var n: usize = 0;
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.default != null) continue;
            try bare.appendSlice(self.ctx.allocator, if (n == 0) "`" else ", `");
            try bare.appendSlice(self.ctx.allocator, f.name);
            try bare.append(self.ctx.allocator, '`');
            n += 1;
        }
        try self.err(pos, "`{s}()` makes a `{s}` from its fields' defaults, and {s} {s} no default; its {s} {s} {s} {s} to module `{s}`, which alone can set {s}", .{ tname, tname, bare.items, if (n == 1) "has" else "have" } ++ which ++ .{ foreign.name, if (count == 1) "it" else "them" });
    } else if (foreign.is_std) {
        try self.err(pos, "only the standard library's module `{s}` can construct `{s}`: its {s} {s} {s} {s}; make one with its `pub` functions", .{ foreign.name, tname } ++ which);
    } else if (read_only == count) {
        try self.err(pos, "only module `{s}` can construct `{s}`: its {s} {s} {s} {s}; make the value with `{s}()` if every field has a default, or with a `pub` function of `{s}`", .{ foreign.name, tname } ++ which ++ .{ tname, foreign.name });
    } else try self.err(pos, "only module `{s}` can construct `{s}`: its {s} {s} {s} {s}; declare every field `pub` there, or make the value with a `pub` function of `{s}`", .{ foreign.name, tname } ++ which ++ .{foreign.name});
    for (fields) |f| {
        if (f.is_method or f.is_variant or (f.is_pub and !f.read_only) or f.decl_pos >= sema.imported_decl_pos) continue;
        try self.ctx.noteIn(m, f.decl_pos, "`{s}` declared here", .{f.name});
    }
}

/// Keyword arguments against named fields: each names a real field
/// once, and every field without a default is given. A type or
/// variant with one field also takes it positionally: `Wrap(x)`,
/// `.some(7)`.
pub fn checkFieldArgs(self: *Checker, args: []const Sexp, fields: []const Field, info: Checker.FieldArgs) Error!void {
    const noun = if (info.kind == .constructor) "constructor of" else "variant";
    const saved_slot = self.expect.slot;
    defer self.expect.slot = saved_slot;
    self.expect.slot = try fieldSlot(self, info, args, fields);
    const saved_home = self.expect.cell_home;
    defer self.expect.cell_home = saved_home;
    // A built-in generic's value (a List's, box's, or Cell's) is no
    // field a Cell may be made in.
    const homes = switch (self.ctx.types.get(info.instance)) {
        .parameterized_nominal => |pn| !sema.isBuiltinGeneric(self.ctx, pn.sym),
        else => true,
    };
    if (args.len == 1 and !args[0].isKind(.kwarg)) {
        if (soleField(fields)) |f| {
            const ty = try fieldType(self, f, info);
            self.expect.slot.value = args[0];
            self.expect.slot.declared = f.ty;
            self.expect.cell_home = if (homes) args[0] else .nil;
            try ViewCheck.checkExpr(self, args[0], ty);
            return StdFormCheck.checkViewsVisibly(self, args[0], ty, "the field writes through");
        }
    }
    for (args) |a| {
        if (a.isKind(.kwarg)) continue;
        if (info.kind == .variant) {
            const first = for (fields) |f| {
                if (!f.is_method and !f.is_variant) break f.name;
            } else "field";
            if (soleField(fields) != null) {
                try self.err(info.pos, "variant `{s}` has one field: write `.{s}(value)` or `.{s}({s}: value)`", .{ info.owner, info.owner, info.owner, first });
            } else {
                try self.err(info.pos, "a variant with more than one field sets them by name: `.{s}({s}: ...)`", .{ info.owner, first });
            }
        } else try positionalFieldsError(self, fields, info.owner, info.pos);
        try synthArgs(self, args);
        return;
    }
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(self.ctx.allocator);
    // The fields an unknown name was likely meant as, which are not
    // reported missing too.
    var meant: std.StringHashMapUnmanaged(void) = .empty;
    defer meant.deinit(self.ctx.allocator);
    for (args) |a| {
        const value = ir.Kwarg.value(a);
        const fname = self.text(ir.Kwarg.name(a));
        const fpos = ir.Kwarg.name(a).src.pos;
        if (seen.get(fname)) |first| {
            try self.err(fpos, "duplicate field `{s}` in {s} `{s}`", .{ fname, noun, info.owner });
            try self.note(first, "first `{s}` here", .{fname});
            _ = try PatternCheck.synthExpr(self, value);
            continue;
        }
        try seen.put(self.ctx.allocator, fname, fpos);
        const f = (try CompatCheck.findDataField(self.ctx, fields, fname)) orelse {
            const likely = ExprCheck.memberSuggest(fields, fname, .field);
            if (likely.best) |b| try meant.put(self.ctx.allocator, b, {});
            try self.err(fpos, "no field `{s}` on {s} `{s}`{s}", .{ fname, if (info.kind == .constructor) "type" else "variant", info.owner, try likely.hint(self.ctx.arena.allocator()) });
            if (info.foreign == null and info.decl_pos < sema.imported_decl_pos and info.decl_pos != 0) try self.ctx.noteIn(info.module_id, info.decl_pos, "`{s}` declared here", .{info.owner});
            _ = try PatternCheck.synthExpr(self, value);
            continue;
        };
        const ty = try fieldType(self, f, info);
        self.expect.slot.value = value;
        self.expect.slot.declared = f.ty;
        self.expect.cell_home = if (homes) value else .nil;
        try ViewCheck.checkExpr(self, value, ty);
        try StdFormCheck.checkViewsVisibly(self, value, ty, "the field writes through");
    }
    for (fields) |f| {
        if (f.is_method or f.is_variant or f.default != null or seen.contains(f.name) or meant.contains(f.name)) continue;
        try self.err(info.pos, "{s} `{s}` is missing field `{s}`", .{ noun, info.owner, f.name });
        if (info.foreign == null and f.decl_pos < sema.imported_decl_pos) try self.ctx.noteIn(info.module_id, f.decl_pos, "field `{s}` declared here", .{f.name});
    }
}

/// The slot each field of a construction fills (`Slot`): the call,
/// and what it makes as written.
pub fn fieldSlot(self: *Checker, info: Checker.FieldArgs, args: []const Sexp, fields: []const Field) Error!Checker.Slot {
    const call = if (info.call != .nil) info.call else self.expect.current_call orelse return .{ .field = true, .owner = info.owner };
    const callee = ir.Call.callee(call);
    var slot: Checker.Slot = .{
        .call = call,
        .owner = sourceText(self, callee),
        .field = true,
        .subst = info.subst,
    };
    // The fields each argument fills, and their types.
    const a = self.ctx.arena.allocator();
    const values = try a.alloc(Sexp, args.len);
    const types = try a.alloc(TypeId, args.len);
    for (args, values, types) |arg, *v, *ty| {
        v.* = .nil;
        ty.* = sema.type_invalid;
        const f = if (arg.isKind(.kwarg)) try CompatCheck.findDataField(self.ctx, fields, self.text(ir.Kwarg.name(arg))) else if (args.len == 1) soleField(fields) else null;
        const field = f orelse continue;
        v.* = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
        ty.* = try fieldType(self, field, info);
    }
    slot.views = try ViewCheck.plainSlotViews(self, values, types);
    return slot;
}

/// A constructor given positional arguments it cannot take: a type
/// with one field takes exactly one, alone; one with more sets them
/// by name.
pub fn positionalFieldsError(self: *Checker, fields: []const Field, owner: []const u8, pos: u32) Error!void {
    var count: usize = 0;
    var first: []const u8 = "field";
    for (fields) |f| {
        if (f.is_method or f.is_variant) continue;
        if (count == 0) first = f.name;
        count += 1;
    }
    switch (count) {
        0 => try self.err(pos, "`{s}` has no fields: `{s}()`", .{ owner, owner }),
        1 => try self.err(pos, "`{s}` has one field, given by position alone (`{s}(x)`) or by name (`{s}({s}: x)`)", .{ owner, owner, owner, first }),
        else => try self.err(pos, "a type with more than one field sets them by name: `{s}({s}: ...)`", .{ owner, first }),
    }
}

/// A variant payload's one field, when it has exactly one.
pub fn soleField(fields: []const Field) ?Field {
    var found: ?Field = null;
    for (fields) |f| {
        if (f.is_method or f.is_variant) continue;
        if (found != null) return null;
        found = f;
    }
    return found;
}

pub fn fieldType(self: *Checker, f: Field, info: Checker.FieldArgs) Error!TypeId {
    if (info.foreign != null) return memberType(self, info.foreign, f.ty);
    return sema.substituteType(self.ctx, f.ty, info.subst);
}

/// A member type as the declaration of a type spells it, in this
/// module's types: imported when the type is `foreign`.
pub fn memberType(self: *Checker, foreign: ?Checker.ForeignFields, ty: TypeId) Error!TypeId {
    const fo = foreign orelse return ty;
    return sema.importType(self.ctx, fo.ctx, ty, fo.module_id);
}

/// `obj.name(args)`, a call whose callee is `(member obj name)`; the
/// callee node's type is the resolved method's signature. `ct` is
/// the bracket list of `obj.name[...](args)`, compile-time arguments
/// for a method, or the index of an element of a field holding
/// functions.
pub fn synthMemberCall(self: *Checker, callee: Sexp, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const saved = self.expect.callee_node;
    self.expect.callee_node = callee;
    defer self.expect.callee_node = saved;
    var obj = ir.Member.object(callee);
    const saved_in_place = self.expect.in_place;
    defer self.expect.in_place = saved_in_place;
    self.expect.in_place = obj;
    const name_node = ir.Member.name(callee);
    const method = self.text(name_node);
    const pos = srcPos(name_node, self.startOf(obj));

    // `<Point.origin()`: a function called through its type or module
    // has no self for the sigil to apply to.
    var misreached: ?Sexp = null;
    if (ViewCheck.isSelfSigil(self, obj)) {
        const place = ir.get(obj, .operand);
        if ((try moduleNamed(self, place)) != null or (try namedType(self, place)) != null or
            (try StdFormCheck.builtinTypeNamed(self, place, self.ctx.localSym(self.ctx.builtins.simd), .simd)) != null or
            (try StdFormCheck.builtinTypeNamed(self, place, self.ctx.localSym(self.ctx.builtins.slot), .slot)) != null)
        {
            if (obj.isKind(.read)) {
                try self.errAt(obj, "`{s}` is called through its type or module and has no `self`; to make a view of the call's result, write `?({s})`", .{ method, try FlowCheck.callWith(self, obj, sourceText(self, place), method) });
                try synthArgs(self, args);
                return self.t().invalid_id;
            }
            // `!lib.mk().bump()`: the `!` meant for the value the call
            // makes reaches the module or type instead, reported once
            // the call's type is known.
            if (obj.isKind(.write)) misreached = obj else try ViewCheck.misplacedSigil(self, obj, method, "is called through its type or module and has no `self`");
            obj = place;
        }
    }
    if (try moduleNamed(self, obj)) |id| {
        if (ct == null) if (try StdFormCheck.stdForm(self, id, method, pos, args)) |ty| return StdFormCheck.misreachedWrite(self, misreached, obj, method, ty);
        return StdFormCheck.misreachedWrite(self, misreached, obj, method, try ViewCheck.crossModuleCall(self, id, method, pos, args, ct));
    }
    if (try StdFormCheck.builtinTypeNamed(self, obj, self.ctx.localSym(self.ctx.builtins.simd), .simd)) |vt| return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.simdTypeCall(self, callee, vt, method, pos, args, ct));
    if (try StdFormCheck.builtinTypeNamed(self, obj, self.ctx.localSym(self.ctx.builtins.slot), .slot)) |st| return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.slotTypeCall(self, callee, st, method, pos, args, ct));
    if (StdFormCheck.symbolNamed(self, obj)) return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.symbolTypeCall(self, callee, method, pos, args, ct));
    if (try ViewCheck.numberType(self, obj)) |nty| return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.numberTypeCall(self, callee, obj, nty, method, pos, args, ct));
    if (try StdFormCheck.apiNamedCallee(self, obj)) |ref| return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.apiNameCall(self, ref, sourceText(self, obj), method, pos, args, ct));
    if (try namedType(self, obj)) |nt| {
        if (self.ctx.ref(nt.id) == self.ctx.builtins.actor) return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.actorSupervised(self, callee, method, pos, args));
        return StdFormCheck.misreachedWrite(self, misreached, obj, method, try StdFormCheck.associatedCall(self, obj, nt, method, pos, args, ct));
    }

    // A consuming (`<@`) method may take a temporary, and a
    // `?@` one reads it where it stands; a `!@` one needs it
    // given as a write view, `!mk().m()`, which keeps it in its
    // statement's slot.
    // A chain, on a value: no module's or type's function.
    if (ct == null and misreached == null and (rig.isChainConsumer(method) or rig.isChainStage(method))) {
        if (try StdFormCheck.chainCall(self, callee, method, args)) |ty| return ty;
    }
    const saved_self = self.expect.self_obj;
    self.expect.self_obj = obj;
    const obj_ty = try PatternCheck.synthExpr(self, obj);
    self.expect.self_obj = saved_self;
    if (self.isPoison(obj_ty)) {
        try synthArgs(self, args);
        return obj_ty;
    }

    if (rig.isWaitMember(callee)) {
        if (try StdFormCheck.waitOperand(self, obj, obj_ty, pos, args)) |ty| return ty;
    } else if (try StdFormCheck.spelledWait(self, obj, obj_ty, method, pos, args)) |ty| return ty;
    if (sema.actorOfHandle(self.ctx, obj_ty)) |value| return StdFormCheck.actorCall(self, callee, obj, value, method, pos, args, ct);
    if (std.mem.eql(u8, method, "reduce")) if (try StdFormCheck.reduceCall(self, obj, obj_ty, pos, args, ct)) |ty| return StdFormCheck.noteMethod(self, callee, .read, ty);
    if (try StdFormCheck.elemsCall(self, callee, obj, obj_ty, method, pos, args, ct)) |ty| {
        const reads = switch (std.meta.stringToEnum(sema.ElemOp, method) orelse .copy) {
            .read, .sum, .prefetch => true,
            else => false,
        };
        return StdFormCheck.noteMethod(self, callee, if (reads) .read else .write, ty);
    }
    if (try StdFormCheck.stringCall(self, callee, obj, obj_ty, method, pos, args, ct)) |ty| return StdFormCheck.noteMethod(self, callee, .write, ty);
    if (ct == null) if (try StdFormCheck.bitCall(self, callee, obj, obj_ty, method, pos, args)) |ty| return StdFormCheck.noteMethod(self, callee, .value, ty);
    if (ct == null) if (try StdFormCheck.floatCall(self, callee, obj, obj_ty, method, pos, args)) |ty| return StdFormCheck.noteMethod(self, callee, .value, ty);
    if (try StdFormCheck.simdCall(self, callee, obj, obj_ty, method, pos, args, ct)) |ty| return StdFormCheck.noteMethod(self, callee, .value, ty);
    const resolved_method = try findMethod(self, obj_ty, method);
    // `x.hash()`, unless the type declares a `hash` of its own.
    if (resolved_method == null and ct == null and std.mem.eql(u8, method, "hash") and !try StdFormCheck.hasDataField(self, obj_ty, method)) return StdFormCheck.hashCall(self, callee, obj, obj_ty, pos, args);
    // `a.order(?b)`, unless the type declares an `order` of its own.
    if (resolved_method == null and ct == null and std.mem.eql(u8, method, "order") and !try StdFormCheck.hasDataField(self, obj_ty, method)) if (try StdFormCheck.orderCall(self, callee, obj, obj_ty, pos, args)) |ty| return ty;
    // `!h.add(x)` of a Hasher.
    if (ct == null and std.mem.eql(u8, method, "add") and sema.unwrapViews(self.ctx, obj_ty) == try self.ctx.intern(.{ .nominal = self.ctx.builtins.hasher })) return StdFormCheck.hasherAdd(self, callee, obj, pos, args);
    // `!out.value(x)` of a Printer.
    if (ct == null and std.mem.eql(u8, method, "value") and sema.unwrapViews(self.ctx, obj_ty) == try self.ctx.intern(.{ .nominal = self.ctx.builtins.printer })) return StdFormCheck.printerValue(self, callee, obj, obj_ty, pos, args);
    // A method no type declares, which an API the type provides does.
    if (resolved_method == null) if (try StdFormCheck.apiShorthand(self, callee, obj, obj_ty, method, pos, args, ct)) |ty| return ty;
    // `x.f[i](args)` where `f` is a field: its element is called. A
    // type parameter's value has no fields, and its methods take
    // compile-time arguments through a bound (`typeParamCall`).
    if (ct != null and resolved_method == null and switch (self.ctx.types.get(sema.unwrapAccess(self.ctx, obj_ty))) {
        .type_var, .api_object => false,
        else => true,
    }) {
        const field_ty = try memberOf(self, callee, obj, obj_ty);
        try self.ctx.recordType(callee, field_ty);
        const elem_ty = try indexInto(self, ct.?, field_ty);
        try self.ctx.recordType(ct.?, elem_ty);
        if (ViewCheck.isSelfSigil(self, obj)) {
            try ViewCheck.fieldCallSigil(self, obj, method, "a field holding functions", elem_ty);
        } else try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
        return callValue(self, ct.?, elem_ty, args, sourceText(self, ct.?));
    }

    // A weak handle upgrades with `*w`, a shared handle has nothing to
    // upgrade, and an object's own `upgrade` is called as any method.
    if (std.mem.eql(u8, method, "upgrade")) {
        switch (self.ctx.types.get(sema.unwrapViews(self.ctx, obj_ty))) {
            .weak => {
                const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(obj));
                return badCall(self, args, pos, "a weak handle upgrades with `*{s}`, not a method: `if *{s} as s`", .{ shown, shown });
            },
            .shared => if (!sema.hasMethodNamed(self.ctx, obj_ty, method)) {
                return badCall(self, args, pos, "a shared handle `{s}` is already counted, and has no `upgrade`; a weak handle `w` of one (`~h`) upgrades with `*w`", .{try self.tyName(sema.unwrapViews(self.ctx, obj_ty))});
            },
            else => {},
        }
    }

    const peeled = sema.unwrapAccess(self.ctx, obj_ty);
    switch (self.ctx.types.get(peeled)) {
        .optional => return badCall(self, args, pos, "cannot call `{s}` on optional `{s}`; take the value out first with `x ?? fallback`", .{ method, try self.tyName(peeled) }),
        .type_var => |param| return StdFormCheck.typeParamCall(self, callee, obj, obj_ty, peeled, self.ctx.localSym(param), method, pos, args, ct),
        .api_object => |o| return StdFormCheck.objectCall(self, callee, obj, obj_ty, o, null, method, pos, args, ct, false),
        else => {},
    }

    if (try StdFormCheck.taskSetWait(self, callee, obj, obj_ty, method, pos, args)) |ty| return ty;
    if (CompatCheck.cellListElement(self.ctx, obj_ty)) |elem| if (try StdFormCheck.cellListCall(self, callee, obj, obj_ty, elem, pos, args)) |ty| {
        const mode: SelfMode = if (std.mem.eql(u8, method, "get")) .read else .write;
        if (mode == .read and ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "only reads the Cell");
        return StdFormCheck.noteMethod(self, callee, mode, ty);
    };
    if (resolved_method == null and std.mem.eql(u8, method, "get")) if (try StdFormCheck.sequenceGet(self, obj_ty, pos, args)) |ty| {
        try self.ctx.record(.builtin_calls, callee, .element_get);
        _ = try ViewCheck.checkSelfSigil(self, obj, .read, ty, method);
        return StdFormCheck.noteMethod(self, callee, .read, ty);
    };

    if (resolved_method == null and std.mem.eql(u8, method, "is_empty") and StdFormCheck.hasBuiltinLen(self, peeled)) {
        const f: FunctionType = .{
            .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .read_view = sema.unwrapViews(self.ctx, obj_ty) })}),
            .returns = self.t().bool_id,
            .is_sub = false,
        };
        try StdFormCheck.noteCallee(self, f);
        try self.ctx.record(.builtin_calls, callee, .is_empty);
        try checkArgs(self, args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = false }, .{}, "is_empty", pos, .{ .has_self = true });
        _ = try ViewCheck.checkSelfSigil(self, obj, .read, f.returns, method);
        return StdFormCheck.noteMethod(self, callee, .read, f.returns);
    }

    const resolved = resolved_method orelse {
        // A data field holding a function or a closure handle is
        // called like one.
        if (try dataField(self, obj_ty, method, pos, .nil)) |ty| {
            if (sema.ownedClosureFn(self.ctx, ty) != null or self.ctx.types.get(ty) == .function) {
                if (ViewCheck.isSelfSigil(self, obj)) {
                    try ViewCheck.fieldCallSigil(self, obj, method, "a field holding a function", ty);
                } else try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
                try StdFormCheck.noteCalleeType(self, ty);
                return callValue(self, callee, ty, args, method);
            }
            // An optional function is taken out of its optional first.
            const inner = switch (self.ctx.types.get(ty)) {
                .optional => |o| o,
                else => sema.type_invalid,
            };
            if (inner != sema.type_invalid and (sema.ownedClosureFn(self.ctx, inner) != null or self.ctx.types.get(inner) == .function)) {
                try self.err(pos, "field `{s}` holds an optional function, `{s}`: take the function out first, `if {s} as g`, then call `g(...)`", .{ method, try self.tyName(ty), try sema.memberText(self.ctx.arena.allocator(), try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)), method) });
                return skipCall(self, args);
            }
            // A data field is read, not called: `m.len`, not `m.len()`.
            if (!self.isPoison(ty)) {
                try self.err(pos, "`{s}` is a field of `{s}`, not a method: write `{s}`", .{ method, try self.tyName(peeled), try sema.memberText(self.ctx.arena.allocator(), try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)), method) });
                return skipCall(self, args);
            }
        }
        const has_len = CompatCheck.listElementType(self.ctx, peeled) != null or switch (self.ctx.types.get(peeled)) {
            .string_view, .static, .array, .slice => true,
            else => false,
        };
        if (CompatCheck.listElementType(self.ctx, peeled) != null and std.mem.eql(u8, method, "length")) {
            try self.err(pos, "a List has no `length()`; its length is `.len`, as for an array: `v.len`", .{});
        } else if (has_len and std.mem.eql(u8, method, "len")) {
            try self.err(pos, "no method `len` on type `{s}`; `len` is a field: write `{s}.len`", .{ try self.tyName(peeled), try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)) });
        } else if (sema.chanValue(self.ctx, peeled) != null and (std.mem.eql(u8, method, "on_recv") or std.mem.eql(u8, method, "on_send"))) {
            try self.err(pos, "`{s}` makes an arm of `task.select`, and stands only as one of its arguments: `task.select(name: !{s}.{s}(...), ...)`", .{ method, try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)), method });
        } else if (sema.isTask(self.ctx, peeled) and std.mem.eql(u8, method, "on_end")) {
            try self.err(pos, "`on_end` makes an arm of `task.select`, and stands only as one of its arguments: `task.select(name: ?{s}.on_end(), ...)`", .{try ViewCheck.plainText(self, CompatCheck.stripSigil(obj))});
        } else if (std.mem.eql(u8, method, "text") and (hasVariantNames(self, peeled) or peeled == self.t().symbol_id)) {
            try self.err(pos, "no method `text` on type `{s}`; a variant's name is a member, read without a call: `{s}.text`", .{ try self.tyName(peeled), try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)) });
        } else if (sema.nominalDecl(self.ctx, peeled)) |decl| {
            const sym = decl.symbol();
            const hint = sema.stdRenamed(decl.ctx, sym.name, method) orelse try ExprCheck.memberHint(self, sym.fields orelse &.{}, method, .method);
            try self.err(pos, "no method `{s}` on type `{s}`{s}", .{ method, sym.name, hint });
            try PatternCheck.noteDeclared(self, sym, decl.module_id == null);
        } else if (self.ctx.types.get(peeled) == .weak) {
            try weakReach(self, obj, peeled, pos);
        } else {
            try self.err(pos, "type `{s}` has no method `{s}`", .{ try self.tyName(obj_ty), method });
        }
        return skipCall(self, args);
    };
    const self_mode = resolved.field.self_mode;
    if (self.ctx.ref(resolved.nominal_sym) == self.ctx.builtins.cell) {
        if (!try StdFormCheck.cellMethod(self, obj_ty, method, pos)) return skipCall(self, args);
        // On the Cell itself, or a view of it; a shared handle's is
        // its value's.
        const Change = enum { set, swap, compare_swap, add, sub };
        const own = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, obj_ty))) {
            .parameterized_nominal => |pn| pn.sym == self.ctx.builtins.cell,
            else => false,
        };
        if (own and std.meta.stringToEnum(Change, method) != null) try self.ctx.record(.builtin_calls, callee, .cell_change);
    }
    _ = try StdFormCheck.noteMethod(self, callee, self_mode, resolved.fn_ty.returns);
    try StdFormCheck.noteCallee(self, resolved.fn_ty);
    const misplaced_sigil = self_mode != .none and try ViewCheck.checkSelfSigil(self, obj, self_mode, resolved.fn_ty.returns, method);
    switch (self_mode) {
        .value => try ViewCheck.recordUse(self, obj, .take),
        .write => try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view),
        .read, .none => {},
    }
    // (A write method on a value made here with no `!` is reported
    // as such: `checkSelfMode`.)
    if (self_mode == .read and !misplaced_sigil and !ViewCheck.hands(self, obj).hasStorage()) {
        try ViewCheck.readLeaf(self, obj);
    } else if (self_mode != .value and !misplaced_sigil and !(self_mode == .write and ViewCheck.hands(self, obj).kind == .made)) try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);

    try checkVisible(self, resolved.field, resolved.owner_sym, resolved.module, pos);

    if (self_mode == .none) {
        // An `@` without a sigil was reported where it is declared.
        const names = resolved.field.param_names orelse &.{};
        if (names.len == 0 or !std.mem.eql(u8, names[0], "@")) {
            try self.err(pos, "method `{s}` takes no self; call as `{s}.{s}(...)`", .{ method, resolved.owner, method });
        }
        try synthArgs(self, args);
        return resolved.fn_ty.returns;
    }
    if (!misplaced_sigil) {
        const saved_of = self.expect.self_of;
        defer self.expect.self_of = saved_of;
        self.expect.self_of = callee;
        try ViewCheck.checkSelfMode(self, obj, self_mode, CompatCheck.classifySelfType(self.ctx, obj_ty, resolved.nominal_sym), method, pos, resolved.fn_ty.returns);
    }
    if (!try stdArgChecks(self, resolved.module, resolved.owner, method, args, pos)) return skipCall(self, args);
    var info = methodParams(resolved.field, true, resolved.source);
    const home_ctx = if (resolved.module) |m| self.ctx.foreign_semas.get(m) orelse self.ctx else self.ctx;
    info.zoneless = sema.duration.zoneless(home_ctx, resolved.owner, method);
    info.datetime = home_ctx.is_std and std.mem.eql(u8, home_ctx.name, "std.datetime");
    const f = (try instantiateCall(self, resolved.fn_ty, ct, args, info, 1, method, pos, false, selfArgs(self, obj_ty))) orelse return skipCall(self, args);
    // The type's parameters are bound by the object self
    // reaches, through views, handles, and boxes, as the method was
    // found.
    try StdFormCheck.noteMethodTarget(self, resolved.field, resolved.owner_sym, resolved.module, selfArgs(self, sema.unwrapAccess(self.ctx, obj_ty)), sema.unwrapAccess(self.ctx, obj_ty), pos);
    if (!try ViewCheck.meetsNeeds(self, resolved.field, resolved.nominal_sym, resolved.args, pos, args)) return skipCall(self, args);
    if (!try ViewCheck.meetsOwnerBounds(self, resolved.field, resolved.owner_sym, resolved.module, selfArgs(self, sema.unwrapAccess(self.ctx, obj_ty)).args, pos, false)) return skipCall(self, args);
    if (sema.isGenericFn(self.ctx, resolved.fn_ty)) try StdFormCheck.noteCallee(self, f);
    const rest: FunctionType = .{
        .params = f.params[1..],
        .returns = f.returns,
        .is_sub = f.is_sub,
    };
    // A `?@` or `!@` method that may keep a view of a temporary
    // self, in its result or through a write argument, views it
    // as `?e` does: the value it is part of is kept in its statement's
    // slot until the statement ends, where the view may still be used.
    // So is a value that branches which is read as a copy, not where
    // its leaves are (`sema.readByAddress`): plain data.
    if ((self_mode == .read or self_mode == .write) and !misplaced_sigil and !obj.isKind(.read)) {
        const viewed = CompatCheck.stripSigil(obj);
        const base = if (ViewCheck.hands(self, viewed).kind == .part_of_made) StmtCheck.placeOf(self, viewed).base else viewed;
        const copied = switch (ViewCheck.hands(self, base).kind) {
            .made => true,
            .branches => if (self.ctx.typeOf(base)) |ty| !sema.readByAddress(self.ctx, ty) else false,
            else => false,
        };
        if (copied and ViewCheck.isTemporary(self, viewed) and (sema.mayHoldView(self.ctx, f.returns) or StdFormCheck.callRetains(self, rest, f.params[0]))) try ViewCheck.viewTemp(self, viewed);
    }
    self.expect.view_call = true;
    self.expect.view_recv = f.params[0];
    const mark = self.ctx.diagnostics.items.len;
    try checkArgs(self, args, rest, info, method, pos, .{ .has_self = true, .origins = resolved.field.origins, .declared = declaredParams(self, resolved.field, resolved.module, 1) orelse resolved.fn_ty.params[1..] });
    try stdArgTypes(self, resolved.module, resolved.owner, method, args);
    if (self_mode == .read and !misplaced_sigil) try wastedCloneSelf(self, obj, args);
    // A self the method keeps is viewed with `?` written (Core
    // sentence 4).
    const o = resolved.field.origins;
    if (self_mode == .read and !misplaced_sigil and self.ctx.diagnostics.items.len == mark and o.stores & o.viewed & sema.paramBit(0) != 0 and ViewCheck.implicitSelf(self, obj)) {
        if (self.expect.current_call) |call| try ViewCheck.reportKept(self, call, obj, .{ .stored = method });
    }
    // std.datetime's `format` checks its string (§8.4); an argument
    // with an error of its own asks for no `!` besides.
    if (sema.formatOwner(home_ctx, resolved.owner, method)) |ft|
        return if (self.ctx.diagnostics.items.len == mark) formatCall(self, ft, args, f.returns) else self.t().invalid_id;
    return f.returns;
}
