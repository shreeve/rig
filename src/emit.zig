//! Zig code generation.
//!
//! Lowers the semantic IR (`docs/INTERNALS.md`) of one checked module to Zig
//! 0.16 source. The program has already passed sema, effects, and
//! ownership checking; this pass only chooses a representation, and it
//! reads everything it needs to know about names and types from sema's
//! facts table (`types.zig`): which symbol a name denotes, whether a
//! `set` declares or reassigns, and the type of every expression.
//!
//! - A binding is `const` unless it is reassigned, written through
//!   (`!x`, `x.f = ...`), or has a type whose methods take `*Self`.
//! - A resource binding (`*T`, `~T`, a value with drop glue, or an
//!   optional of one) is dropped at scope exit by a `defer`. When the
//!   binding may be moved, dropped, or returned, the defer tests a
//!   `__rig_alive_<name>` flag, and the consuming site clears it.
//! - `!T` parameters, `!self` receivers, and borrow bindings are
//!   pointers; reads go through `.*`.
//! - Every Rig name is written with `rig.writeZigIdent`; a local that
//!   would shadow another visible Zig name is renamed.
//!
//! Anything the emitter cannot lower is an internal error: sema must
//! reject it first.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const sema_decls = @import("sema_decls.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;

/// The runtime shipped with every emitted program: `src/runtime.zig`,
/// written byte for byte next to the emitted modules, which import it
/// as `rig`.
pub const runtime_filename = "rig/runtime.zig";
pub const runtime_source = @embedFile("runtime.zig");
const Tag = rig.Tag;
const Writer = std.Io.Writer;
const TypeId = types.TypeId;
const SymbolId = types.SymbolId;

pub const Error = std.mem.Allocator.Error || Writer.Error || rig.BindingKindError || error{Unsupported};

/// How a resource binding is released.
const ResourceKind = enum {
    /// `*T`: `x.dropStrong()`.
    shared,
    /// `~T`: `x.dropWeak()`.
    weak,
    /// A value with drop glue (`Vec`, a struct owning resources, ...):
    /// `rig.drop(&x)`. Needs `var` storage.
    value,
    /// An optional resource such as `(*T)?`: `rig.drop(&x)`. Needs `var`.
    optional,
};

/// How a binding's scope-exit drop is armed.
const Guard = enum {
    /// Not dropped here (plain data, borrows, captures, loop elements).
    none,
    /// Always dropped at scope exit: `defer x.dropStrong();`.
    scope,
    /// Dropped at scope exit unless consumed first.
    flag,
};

const Local = struct {
    sym: SymbolId,
    /// The Zig spelling: a renamed or escaped identifier, or a path such
    /// as `__rig_self.cap_x` for a closure capture.
    zig_name: []const u8,
    ty: ?TypeId = null,
    kind: ?ResourceKind = null,
    guard: Guard = .none,
    /// `zig_name` holds a pointer to the Rig value.
    is_ptr: bool = false,
    /// A closure literal bound to a name: calls lower to `.invoke(...)`.
    stack_closure: bool = false,
    /// Name of the alive flag when `guard == .flag`.
    flag: []const u8 = "",
    /// A match payload binding: the scrutinee it views. Moving it out
    /// consumes the scrutinee.
    scrutinee: ?SymbolId = null,
    /// The local of the same symbol this one hides until its scope ends.
    shadowed: ?LocalRef = null,
    /// A by-value parameter copied into a `var` at the top of the body,
    /// because it holds a Cell that a borrow of it may change.
    mutable_copy: bool = false,
};

const LocalRef = struct { scope: u32, index: u32 };

const Scope = struct {
    locals: std.ArrayListUnmanaged(Local) = .empty,
};

/// State for the function whose body is being emitted.
const FunState = struct {
    /// Declared return type.
    return_ty: ?TypeId = null,
    /// Parameters to bind at the top of the body.
    params: ?Sexp = null,
    leak_check: bool = false,
};

const Nominal = struct {
    /// How `Self` is spelled: the type name, or `Self` inside a generic.
    name: []const u8,
    members: []const Sexp,
};

/// Facts about bindings the emitter derives from one walk over the
/// module, keyed by sema symbol.
const Usage = struct {
    /// Referenced somewhere after the declaration.
    used: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// May be moved, dropped, or returned: a resource binding with this
    /// fact needs an alive flag.
    consumed: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Match payload (or catch-all) binding -> the scrutinee binding.
    views: std.AutoHashMapUnmanaged(SymbolId, SymbolId) = .empty,

    fn deinit(self: *Usage, a: std.mem.Allocator) void {
        self.used.deinit(a);
        self.consumed.deinit(a);
        self.views.deinit(a);
    }
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    w: *Writer,
    indent: u32 = 0,
    /// Generated names and other emit-lifetime allocations.
    arena: std.heap.ArenaAllocator,
    sema: *const types.SemContext,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Symbol -> its innermost local in `scopes`.
    local_by_sym: std.AutoHashMapUnmanaged(SymbolId, LocalRef) = .empty,
    /// The Zig names of the locals in `scopes`, with how many locals use each.
    local_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Suffix source for generated labels, temporaries, and renames.
    counter: u32 = 0,
    /// Every module-level Zig name, which locals must not shadow.
    module_names: std.StringHashMapUnmanaged(void) = .empty,
    usage: Usage = .{},
    /// `test` blocks emitted so far: the Rig name literal and the Zig function.
    tests: std.ArrayListUnmanaged(struct { name: []const u8, func: []const u8 }) = .empty,
    fun: FunState = .{},
    /// Closure bodies being emitted around the current point. Each names
    /// its environment `__rig_self`, `__rig_self1`, ... so a closure
    /// inside another does not shadow the outer one's.
    closure_depth: u32 = 0,
    nominal: ?Nominal = null,
    /// The next expression sits in a delimited position (after `=`,
    /// between commas, inside parentheses) and needs no outer parentheses.
    bare: bool = false,
    /// The value being emitted is a write borrow: a pointer local in tail
    /// position yields the pointer, not the value behind it.
    ptr_tail: bool = false,
    /// Emitting an operand of arithmetic or an index: compile-time names
    /// (`pre` parameters, `=!` constants) are read through `rig.rt` so Zig
    /// evaluates the operation at run time, as Rig checked it.
    rt_names: bool = false,
    /// Emitting a `pre` argument, which must stay compile-time known.
    keep_comptime: bool = false,
    /// Emitting the object chain of an assignment target: an indexed
    /// element in it is a slot, not a copy.
    place_chain: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer, sema: *const types.SemContext) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .sema = sema,
        };
    }

    pub fn deinit(self: *Emitter) void {
        for (self.scopes.items) |*s| s.locals.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.local_by_sym.deinit(self.allocator);
        self.local_names.deinit(self.allocator);
        self.module_names.deinit(self.allocator);
        self.usage.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        try self.w.print("const rig = @import(\"{s}\");\n", .{runtime_filename});
        if (!sexp.isKind(.@"module")) return;
        const decls = ir.Module.decls(sexp);
        try self.collectModule(decls);
        var scan: Scan = .{ .e = self };
        try scan.walk(sexp);
        for (decls) |decl| {
            try self.w.writeAll("\n");
            try self.emitDecl(decl);
        }
        try self.emitTestTable();
    }

    // =========================================================================
    // Module-level declarations
    // =========================================================================

    fn collectModule(self: *Emitter, decls: []const Sexp) Error!void {
        const a = self.allocator;
        try self.module_names.put(a, "std", {});
        try self.module_names.put(a, "rig", {});
        for (decls) |d0| {
            const d = unwrapPub(d0);
            const kind = d.kind() orelse continue;
            if (!ir.has(kind, .name)) continue;
            const name = self.text(ir.get(d, .name)) orelse continue;
            try self.module_names.put(a, try self.fmt("{f}", .{self.ident(name)}), {});
        }
    }

    fn emitDecl(self: *Emitter, sexp: Sexp) Error!void {
        switch (sexp.kind().?) {
            // Every declaration is emitted `pub`, so `pub` adds nothing.
            .@"pub" => try self.emitDecl(ir.Pub.decl(sexp)),
            .@"fun", .@"sub" => try self.emitFun(sexp),
            .@"extern_fun", .@"extern_sub" => try self.emitExternFun(sexp),
            .@"extern" => try self.emitExternVar(sexp),
            .@"use" => try self.emitUse(sexp),
            .@"struct" => try self.emitStruct(sexp),
            .@"enum" => try self.emitEnum(sexp),
            .@"errors" => try self.emitErrorSet(sexp),
            .@"generic_type" => try self.emitGenericType(sexp),
            .@"generic_enum" => try self.emitGenericEnum(sexp),
            .@"type" => try self.emitTypeAlias(sexp),
            .@"test" => try self.emitTest(sexp),
            else => return self.unsupported(sexp, "this top-level form"),
        }
    }

    fn emitUse(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Use.name(node));
        try self.w.print("const {f} = @import(\"{s}.zig\");\n", .{ self.ident(name), name });
    }

    /// `(extern_fun name params returns)` / `(extern_sub name params)`.
    fn emitExternFun(self: *Emitter, node: Sexp) Error!void {
        try self.w.print("extern fn {f}(", .{self.ident(self.srcText(ir.get(node, .name)))});
        for (ir.get(node, .params).items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.w.print("{f}: ", .{self.ident(self.srcText(paramNameNode(p).?))});
            try self.emitType(ir.get(p, .type));
        }
        try self.w.writeAll(") ");
        const returns: Sexp = if (node.isKind(.@"extern_fun")) ir.ExternFun.returns(node) else .nil;
        if (returns != .nil) try self.emitType(returns) else try self.w.writeAll("void");
        try self.w.writeAll(";\n");
    }

    /// `(extern _ name type)`: an extern variable, or an extern function
    /// given by a function type.
    fn emitExternVar(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Extern.name(node));
        const ty = ir.Extern.type(node);
        if (ty.isKind(.@"fun_type")) {
            try self.w.print("extern fn {f}(", .{self.ident(name)});
            for (ir.FunType.params(ty).items(), 0..) |p, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.emitType(p);
            }
            try self.w.writeAll(") ");
            const returns = ir.FunType.returns(ty);
            if (returns != .nil) try self.emitType(returns) else try self.w.writeAll("void");
            return self.w.writeAll(";\n");
        }
        try self.w.print("extern var {f}: ", .{self.ident(name)});
        try self.emitType(ty);
        try self.w.writeAll(";\n");
    }

    fn emitTypeAlias(self: *Emitter, node: Sexp) Error!void {
        try self.w.print("pub const {f} = ", .{self.ident(self.srcText(ir.Type.name(node)))});
        try self.emitType(ir.Type.type(node));
        try self.w.writeAll(";\n");
    }

    /// `(test "name" body)` → a function listed in the module's
    /// `__rig_tests` table, which `rig test` runs (`rig.runTests`).
    fn emitTest(self: *Emitter, node: Sexp) Error!void {
        const func = try self.fmt("__rig_test_{d}", .{self.tests.items.len});
        try self.tests.append(self.allocator, .{ .name = self.srcText(ir.Test.name(node)), .func = func });
        try self.w.print("fn {s}() anyerror!void ", .{func});
        self.fun = .{};
        try self.emitBlock(ir.Test.body(node));
        try self.w.writeAll("\n");
    }

    fn emitTestTable(self: *Emitter) Error!void {
        if (self.tests.items.len == 0) return;
        try self.w.writeAll("\npub const __rig_tests = [_]rig.Test{\n");
        for (self.tests.items) |t| try self.w.print("    .{{ .name = {s}, .func = {s} }},\n", .{ t.name, t.func });
        try self.w.writeAll("};\n");
    }

    // -------------------------------------------------------------------------
    // Nominal types
    // -------------------------------------------------------------------------

    /// `(struct Name (: field type)... methods...)`.
    fn emitStruct(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Struct.name(node));
        const members = ir.Struct.members(node);
        try self.w.print("pub const {f} = struct {{\n", .{self.ident(name)});
        const prev = self.enterNominal(try self.fmt("{f}", .{self.ident(name)}), members);
        defer self.nominal = prev;
        try self.emitFields(members, 1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_type Name (T...) members...)` → a type-returning function.
    fn emitGenericType(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericType.members(node);
        try self.w.print("pub fn {f}(", .{self.ident(self.srcText(ir.GenericType.name(node)))});
        try self.emitTypeParams(ir.GenericType.params(node));
        try self.w.writeAll(") type {\n    return struct {\n        const Self = @This();\n\n");
        const prev = self.enterNominal("Self", members);
        defer self.nominal = prev;
        try self.emitFields(members, 2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(enum Name variants... methods...)`: a Zig enum, an enum with
    /// explicit values, or a tagged union when any variant has a payload.
    fn emitEnum(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Enum.name(node));
        const members = ir.Enum.members(node);
        const prev = self.enterNominal(try self.fmt("{f}", .{self.ident(name)}), members);
        defer self.nominal = prev;

        var has_values = false;
        var has_payloads = false;
        for (members) |m| {
            if (m.isKind(.@"valued")) has_values = true;
            if (m.isKind(.@"variant")) has_payloads = true;
        }
        if (has_payloads) {
            try self.w.print("pub const {f} = union(enum) {{\n", .{self.ident(name)});
            try self.emitUnionVariants(members, 1);
        } else {
            try self.w.print("pub const {f} = enum{s} {{\n", .{ self.ident(name), if (has_values) "(u32)" else "" });
            for (members) |m| switch (m) {
                .src => try self.w.print("    {f},\n", .{self.ident(self.srcText(m))}),
                .list => if (m.isKind(.@"valued")) {
                    try self.w.print("    {f} = ", .{self.ident(self.srcText(ir.Valued.name(m)))});
                    try self.emitExpr(ir.Valued.value(m));
                    try self.w.writeAll(",\n");
                },
                else => {},
            };
        }
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_enum Name (T...) variants... methods...)`.
    fn emitGenericEnum(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericEnum.members(node);
        try self.w.print("pub fn {f}(", .{self.ident(self.srcText(ir.GenericEnum.name(node)))});
        try self.emitTypeParams(ir.GenericEnum.params(node));
        try self.w.writeAll(") type {\n    return union(enum) {\n        const Self = @This();\n\n");
        const prev = self.enterNominal("Self", members);
        defer self.nominal = prev;
        try self.emitUnionVariants(members, 2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v...)` → a Zig error set.
    fn emitErrorSet(self: *Emitter, node: Sexp) Error!void {
        try self.w.print("pub const {f} = error{{\n", .{self.ident(self.srcText(ir.Errors.name(node)))});
        for (ir.Errors.members(node)) |v| if (v == .src) try self.w.print("    {f},\n", .{self.ident(self.srcText(v))});
        try self.w.writeAll("};\n");
    }

    fn enterNominal(self: *Emitter, name: []const u8, members: []const Sexp) ?Nominal {
        const prev = self.nominal;
        self.nominal = .{ .name = name, .members = members };
        return prev;
    }

    fn emitTypeParams(self: *Emitter, params: Sexp) Error!void {
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.w.print("comptime {f}: type", .{self.ident(self.srcText(p))});
        }
    }

    fn emitFields(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            if (!m.isKind(.@":")) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{self.ident(self.srcText(ir.@":".name(m)))});
            try self.emitType(ir.@":".type(m));
            try self.w.writeAll(",\n");
        }
    }

    /// Variants of a tagged union: bare → `void`, one payload field →
    /// its type, several → an anonymous struct.
    fn emitUnionVariants(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const vname: []const u8 = switch (m) {
                .src => self.srcText(m),
                .list => if (m.isKind(.@"variant") or m.isKind(.@"valued")) self.srcText(ir.get(m, .name)) else continue,
                else => continue,
            };
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{self.ident(vname)});
            const fields: []const Sexp = if (m.isKind(.@"variant")) ir.Variant.params(m).items() else &.{};
            if (fields.len == 0) {
                try self.w.writeAll("void");
            } else if (fields.len == 1) {
                try self.emitType(ir.@":".type(fields[0]));
            } else {
                try self.w.writeAll("struct { ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("{f}: ", .{self.ident(self.srcText(ir.@":".name(f)))});
                    try self.emitType(ir.@":".type(f));
                }
                try self.w.writeAll(" }");
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Methods of a nominal type, and its `drop` body.
    fn emitMethods(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const head = m.kind() orelse continue;
            if (head != .@"fun" and head != .@"sub" and head != .@"drop_decl") continue;
            try self.w.writeAll("\n");
            try self.writeIndent(depth);
            const prev_indent = self.indent;
            self.indent = depth;
            defer self.indent = prev_indent;
            if (head == .@"drop_decl") {
                try self.emitDropDecl(m);
            } else {
                try self.emitFun(m);
            }
        }
    }

    /// `(drop_decl params block)`: the body becomes `__rig_user_drop`, and
    /// `__rig_drop` runs it and then drops every field.
    fn emitDropDecl(self: *Emitter, node: Sexp) Error!void {
        const nom = self.nominal.?.name;
        try self.w.print("fn __rig_user_drop(self: *{s}) void ", .{nom});
        const params = ir.DropDecl.params(node);
        self.fun = .{ .params = params };
        try self.pushScope();
        try self.bindParams(params);
        try self.emitBlock(ir.DropDecl.body(node));
        try self.popScope();
        try self.w.writeAll("\n\n");
        try self.writeIndent(self.indent);
        try self.w.print("pub fn __rig_drop(self: *{s}) void {{\n", .{nom});
        try self.writeIndent(self.indent + 1);
        try self.w.writeAll("self.__rig_user_drop();\n");
        try self.writeIndent(self.indent + 1);
        try self.w.writeAll("rig.dropFields(self);\n");
        try self.writeIndent(self.indent);
        try self.w.writeAll("}\n");
    }

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// `(fun name params returns body)` / `(sub name params _ body)`.
    fn emitFun(self: *Emitter, node: Sexp) Error!void {
        const is_sub = node.isKind(.@"sub");
        const name_node = ir.get(node, .name);
        const name = self.srcText(name_node);
        const params = ir.get(node, .params);
        const returns = rig.returnType(node);
        const body = ir.get(node, .body);
        const is_main = self.nominal == null and is_sub and std.mem.eql(u8, name, "main");
        const fn_ty = self.fnType(self.sema.typeOf(name_node));
        const return_ty: ?TypeId = if (fn_ty) |f| (if (f.returns == self.sema.types.void_id) null else f.returns) else null;

        self.fun = .{ .return_ty = return_ty, .params = params, .leak_check = is_main };

        // The runtime's panic handler flushes buffered `print` output first.
        if (is_main) try self.w.writeAll("pub const panic = rig.panic;\n\n");
        try self.w.print("pub fn {f}(", .{self.ident(name)});
        try self.pushScope();
        defer self.popScope() catch {};
        try self.bindParams(params);
        try self.emitParamList(params);
        try self.w.writeAll(") ");
        if (returns != .nil) {
            try self.emitParamType(returns);
        } else if (is_main and containsPropagate(body)) {
            try self.w.writeAll("!void");
        } else {
            try self.w.writeAll("void");
        }
        try self.w.writeAll(" ");
        if (return_ty != null) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
    }

    /// Bind each parameter in the current scope. Owned resource values
    /// are copied into a `var` at the top of the body so they can be
    /// dropped; the Zig parameter gets a `__rig_` name.
    fn bindParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.items()) |p| {
            const name_node = paramNameNode(p) orelse continue;
            const sym = self.sema.symbolOf(name_node) orelse continue;
            const ty = self.symType(sym);
            var local: Local = .{ .sym = sym, .zig_name = "", .ty = ty };
            if (paramIsWriteBorrow(p) or (ty != null and self.isPtrBorrowTy(ty.?))) {
                local.is_ptr = true;
            } else if (ty) |t| {
                local.kind = self.kindOf(t);
                local.mutable_copy = local.kind == null and types.holdsCellByValue(self.sema, t);
            }
            if (local.kind != null) local.guard = if (self.usage.consumed.contains(sym)) .flag else .scope;
            _ = try self.declare(local, self.srcText(name_node));
        }
    }

    /// The Zig spelling of a parameter as the signature names it.
    fn paramZigName(self: *Emitter, local: *const Local) Error![]const u8 {
        if (local.kind == .value or local.kind == .optional or local.mutable_copy) return self.fmt("__rig_{s}", .{local.zig_name});
        return local.zig_name;
    }

    fn emitParamList(self: *Emitter, params: Sexp) Error!void {
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitParam(p);
        }
    }

    fn emitParam(self: *Emitter, p: Sexp) Error!void {
        const name_node = paramNameNode(p).?;
        const local = self.localOf(name_node).?;
        const zig_name = try self.paramZigName(local);
        switch (p.kind() orelse return self.unsupported(p, "this parameter")) {
            .@":", .@"default" => {
                try self.w.print("{s}: ", .{zig_name});
                try self.emitParamType(ir.get(p, .type));
            },
            .@"pre_param" => {
                try self.w.print("comptime {s}: ", .{zig_name});
                try self.emitType(ir.PreParam.type(p));
            },
            // `?self` / `!self` receivers.
            .@"read", .@"write" => {
                const ptr: []const u8 = if (p.isKind(.@"write")) "*" else if (local.is_ptr) "*const " else "";
                try self.w.print("{s}: {s}{s}", .{ zig_name, ptr, self.nominal.?.name });
            },
            else => return self.unsupported(p, "this parameter"),
        }
    }

    /// A parameter type: `!T` is a pointer, everything else by value.
    fn emitParamType(self: *Emitter, t: Sexp) Error!void {
        try self.emitType(t);
    }

    /// Statements at the top of a function body: in `main`, the deferred
    /// `rig.finish()` (flush output, check for leaks), then parameter
    /// copies and guards, and discards for unused parameters.
    fn emitFunPrologue(self: *Emitter) Error!void {
        if (self.fun.leak_check) {
            self.fun.leak_check = false;
            try self.line("defer rig.finish();", .{});
        }
        const params = self.fun.params orelse return;
        self.fun.params = null;
        if (params != .list) return;
        for (params.items()) |p| {
            const local = self.localOf(paramNameNode(p) orelse continue) orelse continue;
            if (local.kind == .value or local.kind == .optional) {
                try self.line("var {s} = {s};", .{ local.zig_name, try self.paramZigName(local) });
            } else if (local.mutable_copy) {
                try self.line("var {s} = {s};", .{ local.zig_name, try self.paramZigName(local) });
                try self.line("_ = &{s};", .{local.zig_name});
                continue;
            }
            if (local.guard != .none) {
                try self.writeIndent(self.indent);
                try self.emitGuard(local);
                try self.w.writeAll("\n");
            } else if (!self.usage.used.contains(local.sym) and !std.mem.eql(u8, local.zig_name, "_")) {
                try self.line("_ = {s};", .{local.zig_name});
            }
        }
    }

    // =========================================================================
    // Scopes and names
    // =========================================================================

    fn pushScope(self: *Emitter) Error!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn popScope(self: *Emitter) Error!void {
        var top = self.scopes.pop() orelse return;
        var i = top.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = top.locals.items[i];
            if (l.shadowed) |prev| {
                self.local_by_sym.putAssumeCapacity(l.sym, prev);
            } else {
                _ = self.local_by_sym.remove(l.sym);
            }
            const uses = self.local_names.getPtr(l.zig_name).?;
            uses.* -= 1;
            if (uses.* == 0) _ = self.local_names.remove(l.zig_name);
        }
        top.locals.deinit(self.allocator);
    }

    /// Declare `local` in the innermost scope, choosing its Zig name from
    /// `rig_name` unless one is given. Returns the stored entry.
    fn declare(self: *Emitter, local: Local, rig_name: []const u8) Error!*Local {
        if (self.scopes.items.len == 0) try self.pushScope();
        var l = local;
        // A pointer borrow is held as a pointer wherever it is bound.
        if (l.ty) |t| if (self.isPtrBorrowTy(t)) {
            l.is_ptr = true;
        };
        if (l.zig_name.len == 0) l.zig_name = try self.zigNameFor(rig_name);
        if (l.guard == .flag and l.flag.len == 0) {
            l.flag = try self.fmt("__rig_alive_{s}", .{if (isPlainIdent(l.zig_name)) l.zig_name else try self.fresh(rig_name)});
        }
        const scope: u32 = @intCast(self.scopes.items.len - 1);
        const top = &self.scopes.items[scope];
        const ref: LocalRef = .{ .scope = scope, .index = @intCast(top.locals.items.len) };
        const latest = try self.local_by_sym.getOrPut(self.allocator, l.sym);
        l.shadowed = if (latest.found_existing) latest.value_ptr.* else null;
        latest.value_ptr.* = ref;
        const uses = try self.local_names.getOrPut(self.allocator, l.zig_name);
        uses.value_ptr.* = if (uses.found_existing) uses.value_ptr.* + 1 else 1;
        try top.locals.append(self.allocator, l);
        return &top.locals.items[ref.index];
    }

    /// The local an identifier leaf denotes, if it names one.
    fn localOf(self: *Emitter, leaf: Sexp) ?*Local {
        const sym = self.sema.symbolOf(leaf) orelse return null;
        return self.localBySym(sym);
    }

    fn localBySym(self: *Emitter, sym: SymbolId) ?*Local {
        const ref = self.local_by_sym.get(sym) orelse return null;
        return &self.scopes.items[ref.scope].locals.items[ref.index];
    }

    /// A Zig name for a new binding: the Rig name (escaped if needed)
    /// unless that would shadow a visible Zig name.
    fn zigNameFor(self: *Emitter, rig_name: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, rig_name, "_")) return "_";
        const base = try self.fmt("{f}", .{self.ident(rig_name)});
        if (!self.nameTaken(base)) return base;
        return self.fresh(rig_name);
    }

    fn nameTaken(self: *Emitter, zig_name: []const u8) bool {
        if (self.module_names.contains(zig_name)) return true;
        if (self.nominal) |n| {
            if (std.mem.eql(u8, n.name, zig_name)) return true;
            for (n.members) |m| {
                if (!m.isKind(.@"fun") and !m.isKind(.@"sub")) continue;
                if (std.mem.eql(u8, self.srcText(ir.get(m, .name)), zig_name)) return true;
            }
        }
        return self.local_names.contains(zig_name);
    }

    fn fresh(self: *Emitter, base: []const u8) Error![]const u8 {
        while (true) {
            self.counter += 1;
            const name = try self.fmt("{s}_{d}", .{ base, self.counter });
            if (!self.nameTaken(name)) return name;
        }
    }

    fn nextId(self: *Emitter) u32 {
        self.counter += 1;
        return self.counter;
    }

    fn fmt(self: *Emitter, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), f, args);
    }

    // =========================================================================
    // Resource guards
    // =========================================================================

    /// `defer ...` that drops `local` at scope exit.
    fn emitGuard(self: *Emitter, local: *const Local) Error!void {
        const kind = local.kind orelse return;
        switch (local.guard) {
            .none => {},
            .scope => {
                try self.w.writeAll("defer ");
                try self.writeDrop(local.zig_name, kind);
                try self.w.writeAll(";");
            },
            .flag => {
                // The defer clears the flag itself, so the flag is a mutated
                // `var` even when nothing consumes the binding.
                try self.w.print("var {s} = true;\n", .{local.flag});
                try self.writeIndent(self.indent);
                try self.w.print("defer if ({s}) {{ {s} = false; ", .{ local.flag, local.flag });
                try self.writeDrop(local.zig_name, kind);
                try self.w.writeAll("; };");
            },
        }
    }

    fn writeDrop(self: *Emitter, place: []const u8, kind: ResourceKind) Error!void {
        switch (kind) {
            .shared => try self.w.print("{s}.dropStrong()", .{place}),
            .weak => try self.w.print("{s}.dropWeak()", .{place}),
            .value, .optional => try self.w.print("rig.drop(&{s})", .{place}),
        }
    }

    /// The alive flag that must be cleared when `local`'s value leaves:
    /// its own, or its scrutinee's for a match payload binding.
    fn consumeFlag(self: *Emitter, local: *const Local) ?[]const u8 {
        if (local.guard == .flag) return local.flag;
        // A Copy payload is copied out; the scrutinee keeps its value.
        if (local.kind == null) return null;
        const s = local.scrutinee orelse return null;
        const scrut = self.localBySym(s) orelse return null;
        return if (scrut.guard == .flag) scrut.flag else null;
    }

    // =========================================================================
    // Blocks and statements
    // =========================================================================

    /// The statements of a block, or a lone statement as a list of one.
    fn stmtsOf(self: *Emitter, body: Sexp) Error![]const Sexp {
        if (body.isKind(.@"block")) return ir.Block.stmts(body);
        return self.arena.allocator().dupe(Sexp, &.{body});
    }

    fn openBrace(self: *Emitter) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();
    }

    fn closeBrace(self: *Emitter) Error!void {
        try self.popScope();
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// `{ stmts }` for a statement-position block.
    fn emitBlock(self: *Emitter, body: Sexp) Error!void {
        try self.openBrace();
        try self.emitFunPrologue();
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitStmts(self: *Emitter, stmts: []const Sexp) Error!void {
        for (stmts) |stmt| {
            try self.writeIndent(self.indent);
            try self.emitStmt(stmt);
            try self.w.writeAll("\n");
        }
    }

    /// A function body whose last expression statement is its value.
    fn emitValueBody(self: *Emitter, body: Sexp) Error!void {
        try self.openBrace();
        try self.emitFunPrologue();
        const stmts = try self.stmtsOf(body);
        const last = stmts.len - 1;
        try self.emitStmts(stmts[0..last]);
        try self.writeIndent(self.indent);
        if (isValueStmt(stmts[last])) {
            try self.w.writeAll("return ");
            try self.emitReturnValue(stmts[last]);
            try self.w.writeAll(";");
        } else {
            try self.emitStmt(stmts[last]);
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    fn emitStmt(self: *Emitter, sexp: Sexp) Error!void {
        const head = sexp.kind() orelse {
            try self.w.writeAll("_ = ");
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        };
        switch (head) {
            .@"set" => try self.emitSet(sexp),
            .@"drop" => try self.emitDrop(sexp),
            .@"return" => try self.emitReturn(sexp),
            .@"break" => try self.emitBreak(sexp),
            .@"continue" => try self.emitContinue(sexp),
            .@"if" => try self.emitIf(sexp),
            .@"while" => try self.emitWhile(sexp, null),
            .@"for" => try self.emitFor(sexp, null),
            .@"labeled" => try self.emitLabeled(sexp),
            .@"match" => try self.emitMatch(sexp, false),
            .@"block" => try self.emitBlock(sexp),
            // `raw` marks an audit boundary for sema; it lowers to a block.
            .@"raw_block" => try self.emitBlock(ir.RawBlock.body(sexp)),
            .@"defer", .@"errdefer" => {
                try self.w.print("{s} ", .{@tagName(head)});
                const body = ir.get(sexp, .body);
                if (body.isKind(.@"block")) try self.emitBlock(body) else try self.emitStmt(body);
            },
            else => {
                if (self.discardsValue(sexp)) try self.w.writeAll("_ = ");
                try self.emitExpr(sexp);
                try self.w.writeAll(";");
            },
        }
    }

    /// True when `expr` in statement position produces a value that Zig
    /// requires to be used.
    fn discardsValue(self: *Emitter, expr: Sexp) bool {
        var e = expr;
        while (e.isKind(.@"propagate")) e = ir.Propagate.value(e);
        if (!e.isKind(.@"call")) return true;
        if (self.isPrintCall(e)) return false;
        // A call lowered to a labeled block is an expression Zig will not
        // take as a statement.
        if (ir.Call.callee(e).isKind(.@"lambda")) return true;
        if (self.sema.callSlotsOf(e)) |slots| if (reordersEffects(slots, ir.Call.args(e))) return true;
        const ty = self.typeOf(e) orelse return true;
        return switch (self.sema.types.get(ty)) {
            .void, .noreturn => false,
            else => true,
        };
    }

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    /// `(set kind target type expr)`.
    fn emitSet(self: *Emitter, sexp: Sexp) Error!void {
        const kind = try rig.bindingKindOf(ir.Set.op(sexp));
        const target = ir.Set.target(sexp);
        const type_node = ir.Set.type(sexp);
        const expr = ir.Set.value(sexp);
        const is_move = kind == .move;

        if (kind.operator()) |op| return self.emitCompound(target, op, expr);
        if (target != .src) {
            return switch (kind) {
                .default, .move => self.emitPlaceAssign(target, expr, is_move),
                else => self.unsupported(sexp, "this binding target"),
            };
        }
        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"&=", .@"|=", .@"^=", .@"<<=", .@">>=" => unreachable,
            .default, .move, .fixed, .shadow => {
                if (std.mem.eql(u8, self.srcText(target), "_")) {
                    // A discarded resource is dropped at once.
                    const owned: ?ResourceKind = if (self.typeOf(expr)) |t| self.kindOf(t) else null;
                    if (owned != null) {
                        const tmp = try self.fmt("__rig_discard_{d}", .{self.nextId()});
                        try self.w.print("{{ var {s} = ", .{tmp});
                        try self.emitValueOf(expr, is_move);
                        try self.w.print("; rig.drop(&{s}); }}", .{tmp});
                        return;
                    }
                    // A named place is discarded by address: it may be used
                    // elsewhere, and Zig rejects discarding a used name.
                    var place = expr;
                    if (place.isKind(.@"read") or place.isKind(.@"write")) place = ir.get(place, .operand);
                    if (!is_move and isPlace(place) and !place.isKind(.@"index")) {
                        try self.w.writeAll("_ = &");
                        try self.emitPlace(place);
                        return self.w.writeAll(";");
                    }
                    try self.w.writeAll("_ = ");
                    try self.emitValueOf(expr, is_move);
                    try self.w.writeAll(";");
                    return;
                }
                // Sema decides whether the name declares a binding or
                // reassigns one.
                const sym = self.sema.symbolOf(target) orelse return self.unsupported(target, "an unresolved binding");
                if (self.sema.symbols.items[sym].decl_pos == target.src.pos) {
                    try self.emitBind(target, sym, type_node, expr, is_move);
                } else {
                    const local = self.localBySym(sym) orelse return self.unsupported(target, "an assignment to this name");
                    try self.emitRebind(local.*, expr, is_move);
                }
            },
        }
    }

    /// `expr`, or `<expr` when `is_move`.
    fn emitValueOf(self: *Emitter, expr: Sexp, is_move: bool) Error!void {
        if (is_move) return self.emitMoved(expr);
        return self.emitBare(expr);
    }

    /// A new binding.
    fn emitBind(self: *Emitter, name_node: Sexp, sym: SymbolId, type_node: Sexp, expr: Sexp, is_move: bool) Error!void {
        if (expr.isKind(.@"lambda")) return self.emitClosureBinding(name_node, sym, expr);

        const s = self.sema.symbols.items[sym];
        const ty = self.symType(sym);
        const binds_borrow = if (ty) |t| switch (self.sema.types.get(t)) {
            .borrow_read, .borrow_write => true,
            else => false,
        } else true;
        const is_borrow = !is_move and binds_borrow and (expr.isKind(.@"read") or expr.isKind(.@"write"));
        // A write borrow is held as a pointer however it was obtained.
        const holds_ptr = is_borrow or (ty != null and self.isPtrBorrowTy(ty.?));
        var local: Local = .{ .sym = sym, .zig_name = "", .ty = ty, .is_ptr = holds_ptr };
        if (!holds_ptr) {
            if (ty) |t| local.kind = self.kindOf(t);
        }
        if (local.kind != null) local.guard = if (self.usage.consumed.contains(sym)) .flag else .scope;

        // A Cell can change through any path to it, so a value holding
        // one lives in mutable storage.
        const needs_ptr_self = local.kind == .value or local.kind == .optional or
            (ty != null and types.holdsCellByValue(self.sema, ty.?));
        // A constant initializer would make a Zig `const` compile-time
        // known, and Zig would then evaluate later arithmetic on it at
        // compile time; Rig treats it as a run-time value.
        const is_var = s.flags.reassigned or (!holds_ptr and (s.flags.written or needs_ptr_self or
            (!s.flags.comptime_known and !is_move and (self.isZigComptime(expr) or self.sema.const_ints.contains(sym)))));

        // Evaluate the value before the new name is visible, so a shadow
        // (`new x = x + 1`) reads the old binding.
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            if (is_borrow) {
                try self.emitAddressOf(ir.get(expr, .operand));
            } else if (holds_ptr) {
                try self.emitBorrowValue(expr);
            } else try self.emitValueOf(expr, is_move);
        }

        const stored = try self.declare(local, self.srcText(name_node));
        try self.w.print("{s} {s}", .{ if (is_var) "var" else "const", stored.zig_name });
        if (holds_ptr) {
            // A rebindable borrow needs its pointer type spelled out.
            if (is_var and ty != null) {
                try self.w.writeAll(": ");
                try self.emitPointerTy(ty.?);
            }
        } else {
            if (type_node != .nil) {
                try self.w.writeAll(": ");
                try self.emitType(type_node);
            } else if (ty != null and (self.isPlainTy(ty.?) or self.isEnumTy(ty.?))) {
                // Literal and branch values need a runtime type, and so
                // does a bare variant of an enum with payloads.
                try self.w.writeAll(": ");
                try self.emitTypeTy(ty.?);
            }
        }
        try self.w.print(" = {s};", .{value_buf.written()});

        if (stored.guard != .none) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitGuard(stored);
        } else if (is_var) {
            // Zig rejects a `var` it never sees mutated. A reassignment
            // is emitted as one; any other reason for `var` (a write
            // through the binding, which may land behind a pointer
            // field, run-time arithmetic, a `*Self` method) needs the
            // discard.
            if (!s.flags.reassigned) try self.w.print(" _ = &{s};", .{stored.zig_name});
        } else if (!self.usage.used.contains(sym)) {
            try self.w.print(" _ = {s};", .{stored.zig_name});
        } else if (self.sema.const_ints.contains(sym)) {
            // A constant's uses may all be folded away.
            try self.w.print(" _ = &{s};", .{stored.zig_name});
        }
    }

    /// Reassign an existing binding. A resource's old value is dropped
    /// after the new one has been computed (so `a = +a` works), and the
    /// guard is re-armed.
    fn emitRebind(self: *Emitter, local: Local, value: Sexp, is_move: bool) Error!void {
        const writes_through = self.sema.symbols.items[local.sym].kind == .param or self.sema.symbols.items[local.sym].flags.pattern_bound;
        if (local.is_ptr and !writes_through) {
            // A borrow local is rebound to borrow something else.
            try self.w.print("{s} = ", .{local.zig_name});
            if (value.isKind(.@"read") or value.isKind(.@"write")) try self.emitAddressOf(ir.get(value, .operand)) else try self.emitBorrowValue(value);
            return self.w.writeAll(";");
        }
        if (local.is_ptr) {
            // Through a `!T` parameter: the caller's value is replaced.
            const pointee = if (local.ty) |t| self.peelBorrows(t) else null;
            if (pointee != null and self.kindOf(pointee.?) != null) {
                const id = self.nextId();
                try self.w.writeAll("{ ");
                try self.writeTemp(try self.fmt("__rig_new_{d}", .{id}), pointee);
                try self.emitValueOf(value, is_move);
                try self.w.print("; rig.drop({s}); {s}.* = __rig_new_{d}; }}", .{ local.zig_name, local.zig_name, id });
                return;
            }
        }
        const kind = local.kind orelse {
            try self.writeLocalPlace(&local);
            try self.w.writeAll(" = ");
            try self.emitValueOf(value, is_move);
            try self.w.writeAll(";");
            return;
        };
        const tmp = try self.fmt("__rig_new_{d}", .{self.nextId()});
        try self.w.writeAll("{ ");
        try self.writeTemp(tmp, local.ty);
        try self.emitValueOf(value, is_move);
        try self.w.writeAll("; ");
        if (local.guard == .flag) try self.w.print("if ({s}) ", .{local.flag});
        try self.writeDrop(local.zig_name, kind);
        try self.w.print("; {s} = {s};", .{ local.zig_name, tmp });
        if (local.guard == .flag) try self.w.print(" {s} = true;", .{local.flag});
        try self.w.writeAll(" }");
    }

    /// `const name: T = ` for a temporary holding a new value; the type
    /// lets a context-typed value (`Vec()`, `.variant(...)`) resolve.
    fn writeTemp(self: *Emitter, name: []const u8, ty: ?TypeId) Error!void {
        try self.w.print("const {s}", .{name});
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
    }

    /// Assignment to a field or element. When the place may hold a
    /// resource, the old value is dropped after the new one is computed.
    fn emitPlaceAssign(self: *Emitter, target: Sexp, value: Sexp, is_move: bool) Error!void {
        const place_ty = self.typeOf(target);
        if (target != .src and self.isWriteBorrowExpr(target)) {
            // A field or element holding a write borrow is rebound.
            try self.emitBorrowValue(target);
            try self.w.writeAll(" = ");
            try self.emitBorrowValue(value);
            return self.w.writeAll(";");
        }
        const may_own = if (place_ty) |t| self.kindOf(t) != null else true;
        if (!may_own) {
            try self.emitPlace(target);
            try self.w.writeAll(" = ");
            try self.emitValueOf(value, is_move);
            try self.w.writeAll(";");
            return;
        }
        const id = self.nextId();
        try self.w.writeAll("{ ");
        try self.writeTemp(try self.fmt("__rig_new_{d}", .{id}), place_ty);
        try self.emitValueOf(value, is_move);
        try self.w.print("; const __rig_slot_{d} = &", .{id});
        try self.emitPlace(target);
        try self.w.print("; rig.drop(__rig_slot_{d}); __rig_slot_{d}.* = __rig_new_{d}; }}", .{ id, id, id });
    }

    /// `x op= e` on a name or place, with the place evaluated once. The
    /// operators that lower to a builtin (`@divTrunc` for integer `/`,
    /// `@rem`, `@shlExact`) assign the builtin's result; the others use
    /// Zig's own compound assignment.
    fn emitCompound(self: *Emitter, target: Sexp, op: Tag, value: Sexp) Error!void {
        const builtin: ?[]const u8 = switch (op) {
            .@"/" => if (self.isFloatExpr(target)) null else "@divTrunc",
            .@"%" => "@rem",
            .@"<<" => "@shlExact",
            else => null,
        };
        const shift = op == .@"<<" or op == .@">>";
        if (builtin) |b| {
            var slot: []const u8 = "";
            if (target == .src) {
                try self.emitPlace(target);
                try self.w.print(" = {s}(", .{b});
                try self.emitPlace(target);
            } else {
                const id = self.nextId();
                slot = try self.fmt("__rig_slot_{d}", .{id});
                try self.w.print("{{ const {s} = &", .{slot});
                try self.emitPlace(target);
                try self.w.print("; {s}.* = {s}({s}.*", .{ slot, b, slot });
            }
            try self.w.writeAll(if (shift) ", @intCast(" else ", ");
            try self.emitBare(value);
            if (shift) try self.w.writeAll(")");
            try self.w.writeAll(if (target == .src) ");" else "); }");
            return;
        }
        try self.emitPlace(target);
        try self.w.print(" {s}= ", .{@tagName(op)});
        if (shift) try self.w.writeAll("@intCast(");
        try self.emitBare(value);
        if (shift) try self.w.writeAll(")");
        try self.w.writeAll(";");
    }

    /// An assignable place: a binding, field, or element.
    fn emitPlace(self: *Emitter, target: Sexp) Error!void {
        if (target == .src) if (self.localOf(target)) |local| return self.writeLocalPlace(local);
        if (target.isKind(.@"index")) return self.emitIndex(target, true);
        // A field of an element (`v[i].x = ...`) is reached through the
        // element's slot.
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = true;
        try self.emitExpr(target);
    }

    fn writeLocalPlace(self: *Emitter, local: *const Local) Error!void {
        try self.w.writeAll(local.zig_name);
        if (local.is_ptr) try self.w.writeAll(".*");
    }

    /// `-x`: drop now.
    fn emitDrop(self: *Emitter, sexp: Sexp) Error!void {
        const local = self.localOf(ir.Drop.name(sexp)) orelse {
            // An unused borrow or plain value: nothing to release.
            const sym = self.sema.symbolOf(ir.Drop.name(sexp)) orelse return self.unsupported(sexp, "this drop");
            const ty = self.symType(sym) orelse return self.unsupported(sexp, "this drop");
            if (self.kindOf(ty) == null) return self.w.writeAll("{}");
            return self.unsupported(sexp, "this drop");
        };
        if (local.kind) |kind| {
            if (local.guard == .flag) {
                try self.w.print("{s} = false; ", .{local.flag});
            } else if (local.guard == .none) {
                // A match payload: the value leaves its scrutinee, and the
                // capture is a constant, so it is dropped from a copy.
                const flag = self.consumeFlag(local) orelse return self.w.writeAll("{}");
                try self.w.print("{s} = false; ", .{flag});
                if (kind == .value or kind == .optional) {
                    const id = self.nextId();
                    return self.w.print("{{ var __rig_drop_{d} = {s}; rig.drop(&__rig_drop_{d}); }}", .{ id, local.zig_name, id });
                }
            }
            try self.writeDrop(local.zig_name, kind);
            try self.w.writeAll(";");
            return;
        }
        // Ending a borrow or dropping plain data has no runtime effect.
        try self.w.writeAll("{}");
    }

    // -------------------------------------------------------------------------
    // Control flow
    // -------------------------------------------------------------------------

    /// `(return value?)`.
    fn emitReturn(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        if (value == .nil) return self.w.writeAll("return;");
        try self.w.writeAll("return ");
        try self.emitReturnValue(value);
        try self.w.writeAll(";");
    }

    /// A value leaving the function. Resource bindings reached in tail
    /// position (directly, or through `if`/`match` branches) are moved
    /// out, so their scope-exit drop is disarmed.
    fn emitReturnValue(self: *Emitter, value: Sexp) Error!void {
        if (self.fun.return_ty) |r| if (self.isPtrBorrowTy(r)) return self.emitBorrowValue(value);
        self.bare = true;
        try self.emitValue(value, true);
    }

    /// `(break value-or-_ label?)`.
    fn emitBreak(self: *Emitter, node: Sexp) Error!void {
        try self.w.writeAll("break");
        const label = ir.Break.label(node);
        if (label != .nil) try self.w.print(" :{f}", .{self.ident(self.srcText(label))});
        try self.w.writeAll(";");
    }

    /// `(continue label?)`.
    fn emitContinue(self: *Emitter, node: Sexp) Error!void {
        try self.w.writeAll("continue");
        const label = ir.Continue.label(node);
        if (label != .nil) try self.w.print(" :{f}", .{self.ident(self.srcText(label))});
        try self.w.writeAll(";");
    }

    /// Statement `if`: `(if cond then else?)`.
    fn emitIf(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        try self.w.writeAll("if ");
        if (cond.isKind(.@"as")) {
            try self.pushScope();
            const prelude = try self.emitOptionalHead(cond);
            try self.emitBodyWith(ir.If.then(sexp), prelude);
            try self.popScope();
        } else {
            try self.emitCond(cond);
            try self.emitBranchStmt(ir.If.then(sexp));
        }
        if (else_ != .nil) {
            try self.w.writeAll(" else ");
            if (else_.isKind(.@"if")) try self.emitIf(else_) else try self.emitBranchStmt(else_);
        }
    }

    /// `(cond) ` for `if`/`while`.
    fn emitCond(self: *Emitter, cond: Sexp) Error!void {
        try self.w.writeAll("(");
        try self.emitBare(cond);
        try self.w.writeAll(") ");
    }

    /// A statement-position body that starts with `prelude`.
    fn emitBodyWith(self: *Emitter, body: Sexp, prelude: Prelude) Error!void {
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitBranchStmt(self: *Emitter, branch: Sexp) Error!void {
        if (branch.isKind(.@"block")) return self.emitBlock(branch);
        try self.w.writeAll("{ ");
        try self.emitStmt(branch);
        try self.w.writeAll(" }");
    }

    /// `(labeled name stmt)`: a labeled loop or block.
    fn emitLabeled(self: *Emitter, sexp: Sexp) Error!void {
        const stmt = ir.Labeled.stmt(sexp);
        const label = self.srcText(ir.Labeled.label(sexp));
        // Zig rejects a label nothing jumps to.
        if (!self.labelUsed(stmt, label)) return self.emitStmt(stmt);
        if (stmt.isKind(.@"while")) return self.emitWhile(stmt, label);
        if (stmt.isKind(.@"for")) return self.emitFor(stmt, label);
        if (stmt.isKind(.@"block")) {
            try self.w.print("{f}: ", .{self.ident(label)});
            return self.emitBlock(stmt);
        }
        return self.unsupported(sexp, "a label on this statement");
    }

    /// Whether a `break` or `continue` inside `node` names `label`.
    fn labelUsed(self: *Emitter, node: Sexp, label: []const u8) bool {
        switch (node.kind() orelse return false) {
            .@"break", .@"continue" => {
                const l = ir.get(node, .label);
                return l != .nil and std.mem.eql(u8, self.srcText(l), label);
            },
            .@"lambda" => return false,
            else => {},
        }
        for (rig.children(node)) |c| if (self.labelUsed(c, label)) return true;
        return false;
    }

    fn writeLabel(self: *Emitter, label: ?[]const u8) Error!void {
        if (label) |l| try self.w.print("{f}: ", .{self.ident(l)});
    }

    /// `(while cond continuation body else?)`.
    fn emitWhile(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const cond = ir.While.cond(sexp);
        const step = ir.While.step(sexp);
        const else_ = ir.While.@"else"(sexp);
        try self.writeLabel(label);
        try self.w.writeAll("while ");
        try self.pushScope();
        var prelude: Prelude = .{};
        if (cond.isKind(.@"as")) prelude = try self.emitOptionalHead(cond) else try self.emitCond(cond);
        if (step != .nil) {
            try self.w.writeAll(": (");
            try self.emitContinuation(step);
            try self.w.writeAll(") ");
        }
        try self.emitBodyWith(ir.While.body(sexp), prelude);
        try self.popScope();
        if (else_ != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(else_);
        }
    }

    /// The `: step` of a while, written as a Zig continue expression.
    fn emitContinuation(self: *Emitter, step: Sexp) Error!void {
        if (step.isKind(.@"set") and ir.Set.target(step) == .src) {
            const op: ?[]const u8 = switch (try rig.bindingKindOf(ir.Set.op(step))) {
                .@"+=" => "+=",
                .@"-=" => "-=",
                .@"*=" => "*=",
                .default => "=",
                else => null,
            };
            if (op) |o| if (self.localOf(ir.Set.target(step))) |local| {
                try self.writeLocalPlace(local);
                try self.w.print(" {s} ", .{o});
                try self.emitBare(ir.Set.value(step));
                return;
            };
        }
        if (step.isKind(.@"call")) return self.emitExpr(step);
        // Anything else runs as a block.
        try self.w.writeAll("{ ");
        try self.emitStmt(step);
        try self.w.writeAll(" }");
    }

    /// `(for mode binding index-binding source body else?)`.
    fn emitFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const mode = ir.For.mode(sexp).tag;
        const binding = ir.For.@"var"(sexp);
        const index_binding = ir.For.index(sexp);
        const source = ir.For.source(sexp);
        const body = ir.For.body(sexp);

        if (source.isKind(.@"..")) return self.emitRangeFor(sexp, label);

        const src_ty = self.typeOf(source);
        const is_vec = src_ty != null and self.isVecTy(src_ty.?);
        if (is_vec and mode == .@"move") return self.emitConsumingFor(sexp, label);
        const elem_sym = self.sema.symbolOf(binding);
        const elem_ty: ?TypeId = if (elem_sym) |s| self.symType(s) else null;
        // A resource element is a borrowed view of its slot.
        const by_ptr = (mode == .@"ptr" or mode == .@"write") or
            (elem_ty != null and self.sema.types.get(elem_ty.?) == .borrow_read);

        try self.pushScope();
        try self.writeLabel(label);
        try self.w.writeAll("for (");
        // Writing an array's elements in place iterates through a pointer.
        const array_ptr = by_ptr and !is_vec and src_ty != null and self.sema.types.get(self.peelBorrows(src_ty.?)) == .array;
        if (array_ptr) try self.emitAddressOf(source) else try self.emitExpr(source);
        if (is_vec) try self.w.writeAll(".items()");
        // An index nobody reads needs no counter.
        const index_sym: ?SymbolId = if (self.sema.symbolOf(index_binding)) |i| (if (self.usage.used.contains(i)) i else null) else null;
        if (index_sym != null) try self.w.writeAll(", 0..");
        try self.w.writeAll(") |");

        var elem_name: []const u8 = "_";
        if (elem_sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .zig_name = "", .ty = elem_ty, .is_ptr = by_ptr }, self.srcText(binding));
            elem_name = stored.zig_name;
        };
        try self.w.print("{s}{s}", .{ if (by_ptr and !std.mem.eql(u8, elem_name, "_")) "*" else "", elem_name });

        var index_decl: ?[]const u8 = null;
        if (index_sym) |isym| {
            const raw = try self.fmt("__rig_i_{d}", .{self.nextId()});
            const stored = try self.declare(.{ .sym = isym, .zig_name = "", .ty = self.symType(isym) }, self.srcText(index_binding));
            try self.w.print(", {s}", .{raw});
            index_decl = try self.fmt("const {s}: {s} = @intCast({s});", .{ stored.zig_name, int_zig, raw });
        }
        try self.w.writeAll("| ");
        try self.openBrace();
        if (index_decl) |d| try self.line("{s}", .{d});
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
        try self.popScope();
        if (ir.For.@"else"(sexp) != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(ir.For.@"else"(sexp));
        }
    }

    /// `for x in <v`: the Vec is consumed; each element is handed to `x`,
    /// which owns it for one iteration. Elements a `break` or `return`
    /// leaves behind are dropped with the buffer.
    ///
    ///     { var it = v.intoIter(); defer it.deinit();
    ///       while (it.next()) |e| { var x = e; defer rig.drop(&x); ... } }
    fn emitConsumingFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const binding = ir.For.@"var"(sexp);
        const index_binding = ir.For.index(sexp);
        const source = ir.For.source(sexp);
        const id = self.nextId();
        const it = try self.fmt("__rig_it_{d}", .{id});
        const tmp = try self.fmt("__rig_elem_{d}", .{id});
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const index_sym: ?SymbolId = if (self.sema.symbolOf(index_binding)) |i| (if (self.usage.used.contains(i)) i else null) else null;

        try self.openBrace();
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = ", .{it});
        try self.emitMoved(source);
        try self.w.writeAll(".intoIter();\n");
        try self.line("defer {s}.deinit();", .{it});
        if (index_sym != null) try self.line("var {s}: usize = 0;", .{counter});
        try self.writeIndent(self.indent);
        try self.writeLabel(label);
        try self.w.print("while ({s}.next()) |{s}| ", .{ it, tmp });
        if (index_sym != null) try self.w.print(": ({s} += 1) ", .{counter});
        try self.pushScope();
        try self.openBrace();
        if (self.sema.symbolOf(binding)) |sym| {
            const ty = self.symType(sym);
            if (ty != null and self.kindOf(ty.?) != null) {
                try self.bindOptionalResource(.{ .name = binding, .tmp = tmp });
            } else if (self.usage.used.contains(sym)) {
                const local = try self.declare(.{ .sym = sym, .zig_name = "", .ty = ty }, self.srcText(binding));
                try self.line("const {s} = {s};", .{ local.zig_name, tmp });
            } else try self.line("_ = {s};", .{tmp});
        } else try self.line("_ = {s};", .{tmp});
        if (index_sym) |isym| {
            const local = try self.declare(.{ .sym = isym, .zig_name = "", .ty = self.symType(isym) }, self.srcText(index_binding));
            try self.line("const {s}: {s} = @intCast({s});", .{ local.zig_name, int_zig, counter });
        }
        try self.emitStmts(try self.stmtsOf(ir.For.body(sexp)));
        try self.closeBrace();
        try self.popScope();
        if (ir.For.@"else"(sexp) != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(ir.For.@"else"(sexp));
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// `for i in a..b`: a half-open integer range.
    fn emitRangeFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const binding = ir.For.@"var"(sexp);
        const range = ir.For.source(sexp);
        const id = self.nextId();
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const end = try self.fmt("__rig_end_{d}", .{id});
        const sym = self.sema.symbolOf(binding);
        const int_ty: TypeId = if (sym) |s| (self.symType(s) orelse self.sema.types.int_id) else self.sema.types.int_id;

        try self.openBrace();
        try self.writeIndent(self.indent);
        try self.w.print("var {s}: ", .{counter});
        try self.emitTypeTy(int_ty);
        try self.w.writeAll(" = ");
        try self.emitBare(ir.@"..".left(range));
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.w.print("const {s}: ", .{end});
        try self.emitTypeTy(int_ty);
        try self.w.writeAll(" = ");
        try self.emitBare(ir.@"..".right(range));
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.writeLabel(label);
        try self.w.print("while ({s} < {s}) : ({s} += 1) ", .{ counter, end, counter });
        try self.openBrace();
        if (sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .zig_name = "", .ty = int_ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ stored.zig_name, counter });
        };
        try self.emitStmts(try self.stmtsOf(ir.For.body(sexp)));
        try self.closeBrace();
        if (ir.For.@"else"(sexp) != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(ir.For.@"else"(sexp));
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    // -------------------------------------------------------------------------
    // Match
    // -------------------------------------------------------------------------

    /// `(match scrutinee arm...)` → `switch`. In value position each arm
    /// yields a value.
    fn emitMatch(self: *Emitter, sexp: Sexp, value_pos: bool) Error!void {
        const scrutinee = ir.Match.subject(sexp);
        const scrut_ty = self.typeOf(scrutinee);
        const error_set = if (scrut_ty) |t| self.isErrorSetTy(t) else false;

        try self.w.writeAll("switch (");
        try self.emitBare(scrutinee);
        try self.w.writeAll(") {\n");
        self.indent += 1;

        var has_default = false;
        for (ir.Match.arms(sexp)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            const body = ir.Arm.body(arm);
            try self.writeIndent(self.indent);
            try self.pushScope();
            defer self.popScope() catch {};

            var aliases: []const Alias = &.{};
            switch (pattern) {
                .src => {
                    const text_ = self.srcText(pattern);
                    if (isLiteralText(text_)) {
                        try self.emitExpr(pattern);
                        try self.w.writeAll(" => ");
                    } else {
                        has_default = true;
                        try self.w.writeAll("else => ");
                        if (!isWildcard(text_)) try self.emitCapture(pattern);
                    }
                },
                .list => switch (pattern.kind().?) {
                    .@"enum_lit", .@"variant_pattern" => {
                        const vname = self.srcText(ir.get(pattern, .name));
                        try self.w.print("{s}{f} => ", .{ if (error_set) "error." else ".", self.ident(vname) });
                        const captures: []const Sexp = if (pattern.isKind(.@"variant_pattern")) ir.VariantPattern.bindings(pattern) else &.{};
                        if (captures.len == 1) {
                            try self.emitCapture(captures[0]);
                        } else if (captures.len > 1) {
                            aliases = try self.payloadAliases(captures, scrut_ty.?, vname);
                            if (aliases.len > 0) try self.w.writeAll("|__rig_payload| ");
                        }
                    },
                    .@"range_pattern" => {
                        // `lo..hi` is half-open; Zig's `lo...hi` is inclusive.
                        // Sema checked both bounds are constants.
                        const lo = types.constIntOf(self.sema, ir.RangePattern.lo(pattern)) orelse return self.unsupported(pattern, "this range pattern");
                        const hi = types.constIntOf(self.sema, ir.RangePattern.hi(pattern)) orelse return self.unsupported(pattern, "this range pattern");
                        try self.w.print("{d}...{d} => ", .{ lo, hi - 1 });
                    },
                    else => {
                        try self.emitExpr(pattern);
                        try self.w.writeAll(" => ");
                    },
                },
                else => return self.unsupported(arm, "this pattern"),
            }
            try self.emitArmBody(body, .{ .aliases = aliases }, value_pos);
            try self.w.writeAll(",\n");
        }
        // A statement match whose arms leave some values out runs no arm
        // for them (sema requires a value-position match to be complete).
        if (!has_default and !self.sema.isExhaustive(sexp)) {
            try self.line("else => {{}},", .{});
        }
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    const Alias = struct { zig_name: []const u8, field: []const u8 };

    /// Bindings a branch body starts with: multi-field payload aliases,
    /// or the owning binding of `if expr as name`.
    const Prelude = struct {
        aliases: []const Alias = &.{},
        optional: ?OptionalBinding = null,
        /// The error a `catch |err|` handler names, captured as `tmp`.
        err_capture: ?struct { zig_name: []const u8, tmp: []const u8 } = null,

        fn isEmpty(p: Prelude) bool {
            return p.aliases.len == 0 and p.optional == null and p.err_capture == null;
        }
    };

    /// A resource bound by `as`: captured as `tmp`, then owned by a local
    /// declared at the top of the body (or dropped at once for `as _`).
    const OptionalBinding = struct { name: Sexp, tmp: []const u8 };

    /// A payload binding local, viewing the scrutinee.
    fn payloadLocal(self: *Emitter, name_node: Sexp) ?Local {
        const sym = self.sema.symbolOf(name_node) orelse return null;
        if (!self.usage.used.contains(sym)) return null;
        const ty = self.symType(sym);
        return .{ .sym = sym, .zig_name = "", .ty = ty, .kind = if (ty) |t| self.kindOf(t) else null, .scrutinee = self.usage.views.get(sym) };
    }

    /// `|name| ` for a payload or catch-all binding that the body uses.
    fn emitCapture(self: *Emitter, name_node: Sexp) Error!void {
        const local = self.payloadLocal(name_node) orelse return;
        const stored = try self.declare(local, self.srcText(name_node));
        try self.w.print("|{s}| ", .{stored.zig_name});
    }

    /// Bindings for a multi-field payload, declared in the arm's scope.
    fn payloadAliases(self: *Emitter, captures: []const Sexp, scrut_ty: TypeId, variant: []const u8) Error![]const Alias {
        const fields = self.variantPayload(scrut_ty, variant) orelse return self.unsupported(captures[0], "this payload pattern");
        var out: std.ArrayListUnmanaged(Alias) = .empty;
        for (captures, fields) |c, f| {
            const local = self.payloadLocal(c) orelse continue;
            const stored = try self.declare(local, self.srcText(c));
            try out.append(self.arena.allocator(), .{ .zig_name = stored.zig_name, .field = f.name });
        }
        return out.items;
    }

    fn emitArmBody(self: *Emitter, body: Sexp, prelude: Prelude, value_pos: bool) Error!void {
        if (value_pos) return self.emitValueBlock(body, prelude);
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitPrelude(self: *Emitter, prelude: Prelude) Error!void {
        for (prelude.aliases) |a| try self.line("const {s} = __rig_payload.{f};", .{ a.zig_name, self.ident(a.field) });
        if (prelude.optional) |o| try self.bindOptionalResource(o);
        if (prelude.err_capture) |c| try self.line("const {s}: anyerror = {s};", .{ c.zig_name, c.tmp });
    }

    /// `(expr) |capture| ` for `if expr as name` / `while expr as name`.
    /// Plain data is captured under the binding's name; a resource is
    /// captured as a temporary that the returned prelude hands to an
    /// owning local inside the body.
    fn emitOptionalHead(self: *Emitter, cond: Sexp) Error!Prelude {
        const name = ir.As.name(cond);
        const value = ir.As.value(cond);
        try self.w.writeAll("(");
        try self.emitBare(value);
        try self.w.writeAll(") ");
        const sym = self.sema.symbolOf(name) orelse {
            // `as _`: a resource inside is dropped at once.
            const opt = self.typeOf(value) orelse return .{};
            const inner = switch (self.sema.types.get(self.peelBorrows(opt))) {
                .optional => |i| i,
                else => return .{},
            };
            if (self.kindOf(inner) == null) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.fmt("__rig_opt_{d}", .{self.nextId()});
            try self.w.print("|{s}| ", .{tmp});
            return .{ .optional = .{ .name = .nil, .tmp = tmp } };
        };
        const ty = self.symType(sym);
        if (ty != null and self.kindOf(ty.?) != null) {
            const tmp = try self.fmt("__rig_opt_{d}", .{self.nextId()});
            try self.w.print("|{s}| ", .{tmp});
            return .{ .optional = .{ .name = name, .tmp = tmp } };
        }
        if (!self.usage.used.contains(sym)) {
            try self.w.writeAll("|_| ");
        } else {
            const local = try self.declare(.{ .sym = sym, .zig_name = "", .ty = ty }, self.srcText(name));
            try self.w.print("|{s}| ", .{local.zig_name});
        }
        return .{};
    }

    /// The owning local of a resource bound by `as`, dropped at the end
    /// of the body unless it is moved out.
    fn bindOptionalResource(self: *Emitter, o: OptionalBinding) Error!void {
        if (o.name == .nil) {
            const id = self.nextId();
            return self.line("var __rig_discard_{d} = {s}; rig.drop(&__rig_discard_{d});", .{ id, o.tmp, id });
        }
        const sym = self.sema.symbolOf(o.name).?;
        const ty = self.symType(sym).?;
        const kind = self.kindOf(ty).?;
        const local = try self.declare(.{
            .sym = sym,
            .zig_name = "",
            .ty = ty,
            .kind = kind,
            .guard = if (self.usage.consumed.contains(sym)) .flag else .scope,
        }, self.srcText(o.name));
        const is_var = kind == .value or kind == .optional;
        try self.line("{s} {s} = {s};", .{ if (is_var) "var" else "const", local.zig_name, o.tmp });
        try self.writeIndent(self.indent);
        try self.emitGuard(local);
        try self.w.writeAll("\n");
    }

    // =========================================================================
    // Expressions
    // =========================================================================

    fn emitExpr(self: *Emitter, sexp: Sexp) Error!void {
        return self.emitValue(sexp, false);
    }

    /// An expression in a delimited position: no outer parentheses.
    fn emitBare(self: *Emitter, sexp: Sexp) Error!void {
        self.bare = true;
        return self.emitValue(sexp, false);
    }

    /// Emit an expression. With `tail`, the expression's value leaves
    /// its scope (return, break value): resource bindings in tail
    /// position are moved out.
    fn emitValue(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const bare = self.bare;
        self.bare = false;
        switch (sexp) {
            .src => try self.emitName(sexp, tail),
            .list => try self.emitList(sexp, tail, bare),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    fn emitName(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const name = self.srcText(sexp);
        if (self.localOf(sexp)) |local| {
            if (self.rt_names and !self.keep_comptime and self.sema.symbols.items[local.sym].flags.comptime_known) {
                return self.w.print("rig.rt({s})", .{local.zig_name});
            }
            if (tail and self.ptr_tail and local.is_ptr) return self.w.writeAll(local.zig_name);
            if (tail) if (self.consumeFlag(local)) |flag| return self.writeTake(flag, local);
            return self.writeLocalPlace(local);
        }
        if (std.mem.eql(u8, name, "none")) return self.w.writeAll("null");
        if (name[0] == '\'') return writeSingleQuoted(self.w, name);
        if (types.isFloatLiteralText(name)) {
            // Typed, so arithmetic on literals rounds like run-time Float math.
            try self.w.writeAll("@as(");
            try self.emitTypeTy(self.typeOf(sexp) orelse self.sema.types.float_id);
            return self.w.print(", {s}{s})", .{ if (name[0] == '.') "0" else "", name });
        }
        if (isLiteralText(name)) return self.w.writeAll(name);
        try self.w.print("{f}", .{self.ident(name)});
    }

    /// `rig.take(&flag, x)`: yields `x` and disarms a scope-exit drop.
    fn writeTake(self: *Emitter, flag: []const u8, local: *const Local) Error!void {
        try self.w.print("rig.take(&{s}, ", .{flag});
        try self.writeLocalPlace(local);
        try self.w.writeAll(")");
    }

    /// A value stored into a field, payload, or element: a write borrow is
    /// stored as its pointer.
    fn emitStored(self: *Emitter, e: Sexp) Error!void {
        if (self.isWriteBorrowExpr(e)) return self.emitBorrowValue(e);
        try self.emitBare(e);
    }

    /// Whether every name in `e` is a constant binding, so folding it
    /// drops no reference Zig would miss (a branch a constant condition
    /// skips may name other locals).
    fn onlyConstantLeaves(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => {
                const sym = self.sema.symbolOf(e) orelse return true;
                return self.sema.const_ints.contains(sym);
            },
            .list => {
                for (e.items()) |c| if (!self.onlyConstantLeaves(c)) return false;
                return true;
            },
            else => return true,
        }
    }

    fn emitIntConstant(self: *Emitter, sexp: Sexp, v: i128) Error!void {
        const t = self.typeOf(sexp);
        const concrete = t != null and self.sema.types.get(t.?) == .int;
        if (concrete) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(t.?);
            return self.w.print(", {d})", .{v});
        }
        if (v < 0) return self.w.print("({d})", .{v});
        try self.w.print("{d}", .{v});
    }

    /// The number type an expression yields, with literal types at their
    /// defaults; null for anything else.
    fn numericValueTy(self: *Emitter, e: Sexp) ?TypeId {
        const t = self.typeOf(e) orelse return null;
        return switch (self.sema.types.get(t)) {
            .int, .float => t,
            .int_literal => self.sema.types.int_id,
            .float_literal => self.sema.types.float_id,
            else => null,
        };
    }

    fn hasPayloadVariants(self: *Emitter, ty: TypeId) bool {
        const decl = types.nominalDecl(self.sema, ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
        }
        return false;
    }

    fn isEnumTy(self: *Emitter, ty: TypeId) bool {
        const decl = types.nominalDecl(self.sema, ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| if (f.is_variant) return true;
        return false;
    }

    fn isZigComptime(self: *Emitter, e: Sexp) bool {
        return isZigComptimeIn(self, e, 0);
    }

    /// An expression whose value is a pointer borrow (see `isPtrBorrowTy`).
    fn isWriteBorrowExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.isPtrBorrowTy(t);
    }

    /// A borrow held as a pointer: a write borrow, and a read borrow of a
    /// `Cell`, whose value can change while it is borrowed. Other read
    /// borrows are held by value: nothing can change what they see.
    fn isPtrBorrowTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(ty)) {
            .borrow_write => true,
            .borrow_read => |inner| types.holdsCellByValue(self.sema, inner),
            else => false,
        };
    }

    /// `holdsCellByValue` for a type expression.
    fn sexpHoldsCell(self: *Emitter, t: Sexp, depth: u8) bool {
        if (depth > 32) return false;
        switch (t) {
            .src => {
                const id = self.sema.symbolOf(t) orelse return false;
                const sym = self.sema.symbols.items[id];
                return switch (sym.kind) {
                    .nominal_type => types.symHoldsCell(self.sema, id, 0),
                    .type_alias => types.holdsCellByValue(self.sema, sym.ty),
                    else => false,
                };
            },
            .list => switch (t.kind().?) {
                .@"optional", .@"error_union" => return self.sexpHoldsCell(ir.get(t, .type), depth + 1),
                .@"generic_inst" => {
                    const id = self.sema.symbolOf(ir.GenericInst.name(t)) orelse return false;
                    if (id == self.sema.cell_sym_id) return true;
                    if (id == self.sema.vec_sym_id or id == self.sema.signal_sym_id) return false;
                    for (ir.GenericInst.args(t)) |a| if (self.sexpHoldsCell(a, depth + 1)) return true;
                    return types.symHoldsCell(self.sema, id, 0);
                },
                else => return false,
            },
            else => return false,
        }
    }

    /// `isPtrBorrowTy` for a type expression.
    fn isPtrBorrowSexp(self: *Emitter, t: Sexp) bool {
        if (t.isKind(.@"borrow_write")) return true;
        if (!t.isKind(.@"borrow_read")) return false;
        return self.sexpHoldsCell(ir.BorrowRead.type(t), 0);
    }

    /// A write-borrow value: the pointer a `!T` expression denotes.
    fn emitBorrowValue(self: *Emitter, e: Sexp) Error!void {
        const saved = self.ptr_tail;
        defer self.ptr_tail = saved;
        self.ptr_tail = true;
        self.bare = true;
        try self.emitValue(e, true);
    }

    /// `*T` / `*const T` for a borrow type.
    fn emitPointerTy(self: *Emitter, ty: TypeId) Error!void {
        switch (self.sema.types.get(ty)) {
            .borrow_write => |inner| {
                try self.w.writeAll("*");
                try self.emitTypeTy(inner);
            },
            .borrow_read => |inner| {
                try self.w.writeAll("*const ");
                try self.emitTypeTy(inner);
            },
            else => try self.emitTypeTy(ty),
        }
    }

    /// `<x`: the value leaves its binding.
    fn emitMoved(self: *Emitter, inner: Sexp) Error!void {
        if (inner == .src) if (self.localOf(inner)) |local| {
            if (self.consumeFlag(local)) |flag| return self.writeTake(flag, local);
        };
        try self.emitBare(inner);
    }

    fn emitList(self: *Emitter, sexp: Sexp, tail: bool, bare: bool) Error!void {
        const head = sexp.kind().?;
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"&", .@"|", .@"^", .@"neg", .@"if" => {
                // Sema computed a constant integer expression (and checked
                // that it fits); its value is written as a literal, so Zig
                // does not evaluate it again with other intermediate types.
                if (types.constIntOf(self.sema, sexp)) |v| if (self.onlyConstantLeaves(sexp)) return self.emitIntConstant(sexp, v);
            },
            else => {},
        }
        switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"neg", .@"index" => self.rt_names = true,
            else => {},
        }
        switch (head) {
            .@"read" => {
                // `?x` of a value held by pointer (a Cell) is its address.
                if (self.isWriteBorrowExpr(sexp)) return self.emitAddressOf(ir.Read.operand(sexp));
                self.bare = bare;
                try self.emitValue(ir.Read.operand(sexp), tail);
            },
            // `!x` as a value (an argument, a receiver) is the place's address.
            .@"write" => try self.emitAddressOf(ir.Write.operand(sexp)),
            .@"move" => {
                self.bare = bare;
                const operand = ir.Move.operand(sexp);
                if (tail and self.ptr_tail) try self.emitValue(operand, true) else try self.emitMoved(operand);
            },
            .@"share" => try self.emitShare(sexp),
            .@"clone" => {
                // `+b` of a borrowed handle clones the handle it borrows.
                const operand = ir.Clone.operand(sexp);
                const kind: ?ResourceKind = if (self.typeOf(operand)) |t| self.kindOf(self.peelBorrows(t)) else null;
                if (kind == .optional) {
                    try self.w.writeAll("rig.cloneOptional(");
                    try self.emitBare(operand);
                    return self.w.writeAll(")");
                }
                if (kind == .value) return self.unsupported(sexp, "a clone of a value with drop glue");
                try self.emitExpr(operand);
                if (kind == .shared) try self.w.writeAll(".cloneStrong()");
                if (kind == .weak) try self.w.writeAll(".cloneWeak()");
            },
            .@"weak" => {
                try self.emitExpr(ir.Weak.operand(sexp));
                try self.w.writeAll(".weakRef()");
            },
            .@"call" => try self.emitCall(sexp),
            .@"member", .@"index" => {
                if (head == .@"member") try self.emitMember(sexp) else try self.emitIndex(sexp, false);
                // A field or element holding a write borrow denotes the
                // borrowed value, unless the pointer itself is wanted.
                if (self.isWriteBorrowExpr(sexp) and !(tail and self.ptr_tail)) try self.w.writeAll(".*");
            },
            .@"builtin" => try self.emitBuiltin(sexp),
            .@"propagate" => {
                try self.w.writeAll("try ");
                try self.emitExpr(ir.Propagate.value(sexp));
            },
            .@"neg" => {
                const operand = ir.Neg.operand(sexp);
                // Zig rejects the literal `-0` as ambiguous; `0 - 0` is 0.
                if (operand == .src and isIntZeroText(self.srcText(operand))) return self.w.writeAll("0");
                try self.w.writeAll("-");
                try self.emitExpr(operand);
            },
            .@"not" => {
                try self.w.writeAll("!");
                try self.emitExpr(ir.Not.operand(sexp));
            },
            .@"enum_lit" => {
                const in_error_set = if (self.typeOf(sexp)) |t| self.isErrorSetTy(t) else false;
                try self.w.print("{s}{f}", .{ if (in_error_set) "error." else ".", self.ident(self.srcText(ir.EnumLit.name(sexp))) });
            },
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^" => try self.emitInfix(sexp, bare),
            .@"and", .@"or" => {
                if (!bare) try self.w.writeAll("(");
                try self.emitExpr(ir.get(sexp, .left));
                try self.w.writeAll(if (head == .@"and") " and " else " or ");
                try self.emitExpr(ir.get(sexp, .right));
                if (!bare) try self.w.writeAll(")");
            },
            .@"<<" => {
                // Like `+`, a left shift that loses bits (or the sign)
                // overflows. The shift amount is cast to the width Zig
                // requires; the shifted value has the expression's type.
                try self.w.writeAll("@shlExact(@as(");
                try self.emitTypeTy(self.typeOf(sexp) orelse self.sema.types.int_id);
                try self.w.writeAll(", ");
                try self.emitBare(ir.@"<<".left(sexp));
                try self.w.writeAll("), @intCast(");
                try self.emitBare(ir.@"<<".right(sexp));
                try self.w.writeAll("))");
            },
            .@">>" => {
                if (!bare) try self.w.writeAll("(");
                try self.w.writeAll("@as(");
                try self.emitTypeTy(self.typeOf(sexp) orelse self.sema.types.int_id);
                try self.w.writeAll(", ");
                try self.emitBare(ir.@">>".left(sexp));
                try self.w.writeAll(") >> @intCast(");
                try self.emitBare(ir.@">>".right(sexp));
                try self.w.writeAll(")");
                if (!bare) try self.w.writeAll(")");
            },
            .@"/" => try self.emitDivision(sexp, "@divTrunc"),
            .@"%" => try self.emitDivision(sexp, "@rem"),
            .@"??" => {
                try self.w.writeAll("(");
                try self.emitExpr(ir.@"??".left(sexp));
                try self.w.writeAll(" orelse ");
                try self.emitValue(ir.@"??".right(sexp), true);
                try self.w.writeAll(")");
            },
            .@"catch" => {
                // `(catch expr name? handler)`: the handler replaces the
                // value. A named error is held as `anyerror`, so it
                // compares and matches with any error value.
                try self.w.writeAll("(");
                try self.emitExpr(ir.Catch.value(sexp));
                try self.w.writeAll(" catch ");
                const name = ir.Catch.name(sexp);
                const handler = ir.Catch.handler(sexp);
                const sym: ?SymbolId = if (name != .nil) self.sema.symbolOf(name) else null;
                if (sym != null and self.usage.used.contains(sym.?)) {
                    const tmp = try self.fmt("__rig_err_{d}", .{self.nextId()});
                    try self.w.print("|{s}| ", .{tmp});
                    try self.pushScope();
                    const local = try self.declare(.{ .sym = sym.?, .zig_name = "", .ty = self.symType(sym.?) }, self.srcText(name));
                    try self.emitValueBlock(handler, .{ .err_capture = .{ .zig_name = local.zig_name, .tmp = tmp } });
                    try self.popScope();
                } else try self.emitValue(handler, true);
                try self.w.writeAll(")");
            },
            .@"if", .@"match" => {
                // Literal branches under a run-time condition need the
                // result's type spelled out.
                const num = self.numericValueTy(sexp);
                if (num) |t| {
                    try self.w.writeAll("@as(");
                    try self.emitTypeTy(t);
                    try self.w.writeAll(", ");
                } else if (!bare and head == .@"if") try self.w.writeAll("(");
                if (head == .@"if") try self.emitIfExpr(sexp) else try self.emitMatch(sexp, true);
                if (num != null) try self.w.writeAll(")") else if (!bare and head == .@"if") try self.w.writeAll(")");
            },
            .@"block" => try self.emitValueBlock(sexp, .{}),
            .@"raw_block" => try self.emitValueBlock(ir.RawBlock.body(sexp), .{}),
            .@"array" => try self.emitArray(sexp),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    fn isNoneLeaf(self: *Emitter, e: Sexp) bool {
        return e == .src and self.sema.symbolOf(e) == null and std.mem.eql(u8, self.srcText(e), "none");
    }

    /// `&place`, or the pointer itself when the place is already one.
    fn emitAddressOf(self: *Emitter, place: Sexp) Error!void {
        if (place == .src) if (self.localOf(place)) |local| {
            if (local.is_ptr) return self.w.writeAll(local.zig_name);
        };
        if (self.isWriteBorrowExpr(place)) return self.emitBorrowValue(place);
        try self.w.writeAll("&");
        try self.emitPlace(place);
    }

    /// A binary operator node: `(op left right)`.
    fn emitInfix(self: *Emitter, sexp: Sexp, bare: bool) Error!void {
        const kind = sexp.kind().?;
        const op = @tagName(kind);
        const is_eq = kind == .@"==" or kind == .@"!=";
        const operands = [2]Sexp{ ir.get(sexp, .left), ir.get(sexp, .right) };
        // A temporary optional resource compared with `none` is dropped.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const other = operands[1 - i];
            if (!self.isNoneLeaf(other) or isPlace(operands[i])) continue;
            const t = self.typeOf(operands[i]) orelse continue;
            if (self.kindOf(t) == null) continue;
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("rig.isNone(");
            try self.emitBare(operands[i]);
            return self.w.writeAll(")");
        };
        if (is_eq and (self.isStringExpr(operands[0]) or self.isStringExpr(operands[1]))) {
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("std.mem.eql(u8, ");
            try self.emitExpr(operands[0]);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[1]);
            try self.w.writeAll(")");
            return;
        }
        if (!bare) try self.w.writeAll("(");
        try self.emitExpr(operands[0]);
        try self.w.print(" {s} ", .{op});
        try self.emitExpr(operands[1]);
        if (!bare) try self.w.writeAll(")");
    }

    /// `/` truncates toward zero for integers (`@divTrunc`); `%` is the
    /// remainder with the dividend's sign (`@rem`), for integers and
    /// floats alike. Float `/` is ordinary division.
    fn emitDivision(self: *Emitter, sexp: Sexp, builtin: []const u8) Error!void {
        const left = ir.get(sexp, .left);
        const right = ir.get(sexp, .right);
        if (sexp.isKind(.@"/") and (self.isFloatExpr(left) or self.isFloatExpr(right))) {
            return self.emitInfix(sexp, false);
        }
        try self.w.print("{s}(", .{builtin});
        try self.emitBare(left);
        try self.w.writeAll(", ");
        try self.emitBare(right);
        try self.w.writeAll(")");
    }

    /// `[a, b, c]` → `[_]T{ a, b, c }`.
    fn emitArray(self: *Emitter, sexp: Sexp) Error!void {
        const elems = ir.Array.elems(sexp);
        const ty = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped array literal");
        const arr = self.sema.types.get(self.peelBorrows(ty));
        if (arr != .array) return self.unsupported(sexp, "this array literal");
        try self.w.writeAll("[_]");
        try self.emitTypeTy(arr.array.elem);
        try self.w.writeAll("{");
        for (elems, 0..) |e, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitStored(e);
        }
        try self.w.writeAll(if (elems.len > 0) " }" else "}");
    }

    /// `x[i]`: bounds-checked element of an array, slice, string, or
    /// `Vec` of plain data. As a place, a `Vec` element is `x.slot(i).*`.
    fn emitIndex(self: *Emitter, sexp: Sexp, as_place: bool) Error!void {
        const base = ir.Index.object(sexp);
        const index = ir.Index.index(sexp);
        const base_ty = self.typeOf(base);
        // The index itself is a value, even inside an assignment target.
        const saved_chain = self.place_chain;
        defer self.place_chain = saved_chain;

        if (base_ty != null and self.isVecTy(base_ty.?)) {
            try self.emitExpr(base);
            try self.w.writeAll(if (as_place) ".slot(" else ".at(");
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(if (as_place) ").*" else ")");
            return;
        }
        // An array literal is indexed through parentheses: `([_]T{ ... })[i]`.
        const literal = base.isKind(.@"array");
        if (literal) try self.w.writeAll("(");
        try self.emitExpr(base);
        if (literal) try self.w.writeAll(")");
        try self.w.writeAll("[");
        self.place_chain = false;
        // Sema checked a constant index against an array's length; a
        // string's length is only known when it runs.
        const array_len: ?usize = if (base_ty) |t| switch (self.sema.types.get(self.peelBorrows(t))) {
            .array => |a| a.len,
            else => null,
        } else null;
        if (array_len != null and isNonNegativeIntLiteral(self.source, index)) {
            try self.emitExpr(index);
        } else if (array_len) |n| {
            // The length is part of the type; the base is evaluated once.
            try self.w.writeAll("rig.index(");
            try self.emitBare(index);
            try self.w.print(", {d})", .{n});
        } else {
            try self.w.writeAll("rig.index(");
            try self.emitBare(index);
            try self.w.writeAll(", ");
            try self.emitExpr(base);
            try self.w.writeAll(".len)");
        }
        try self.w.writeAll("]");
    }

    /// `(member obj name)`. A shared handle auto-dereferences through
    /// `.value`; `.len` of an array, slice, or string is an `Int`.
    fn emitMember(self: *Emitter, sexp: Sexp) Error!void {
        const obj = ir.Member.object(sexp);
        const field = self.srcText(ir.Member.name(sexp));
        const obj_ty = self.typeOf(obj);
        // `Shape.dot` of an enum with payloads names the tag; the value
        // is the union holding it.
        if (obj_ty == null and self.isTypeCallee(obj)) if (self.typeOf(sexp)) |t| if (self.hasPayloadVariants(t)) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(t);
            try self.w.writeAll(", ");
            try self.emitMemberBase(obj, obj_ty);
            return self.w.print(".{f})", .{self.ident(field)});
        };
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.hasLen(obj_ty.?)) {
            try self.w.writeAll("rig.len(");
            try self.emitMemberBase(obj, obj_ty);
            try self.w.writeAll(".len)");
            return;
        }
        try self.emitMemberBase(obj, obj_ty);
        if (obj_ty) |t| if (self.isSharedTy(t)) try self.w.writeAll(".value");
        try self.w.print(".{f}", .{self.ident(field)});
    }

    /// The object of a member access. Borrow sigils on a receiver are
    /// implicit in Zig's method call syntax; pointers to structs
    /// auto-dereference.
    fn emitMemberBase(self: *Emitter, obj: Sexp, obj_ty: ?TypeId) Error!void {
        var o = obj;
        while (o.isKind(.@"read") or o.isKind(.@"write")) o = ir.get(o, .operand);
        if (self.place_chain and o.isKind(.@"index")) return self.emitIndex(o, true);
        // `Box.make(...)` of a generic type: the instance sema inferred.
        if (o == .src) if (self.sema.symbolOf(o)) |id| if (self.sema.symbols.items[id].kind == .generic_type) {
            if (obj_ty) |t| return self.emitTypeTy(t);
        };
        if (o == .src) if (self.localOf(o)) |local| {
            if (local.is_ptr and obj_ty != null and self.isStructLike(obj_ty.?)) return self.w.writeAll(local.zig_name);
            return self.writeLocalPlace(local);
        };
        const needs_parens = if (o.kind()) |h| switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"neg", .@"not", .@"if", .@"match", .@"??", .@"catch", .@"propagate", .@"call", .@"array" => true,
            else => false,
        } else false;
        if (needs_parens) try self.w.writeAll("(");
        try self.emitExpr(o);
        if (needs_parens) try self.w.writeAll(")");
    }

    /// `@name(args)`. Arguments that name Rig types are spelled as Zig types.
    fn emitBuiltin(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.print("@{s}(", .{self.srcText(ir.Builtin.name(sexp))});
        for (ir.Builtin.args(sexp), 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (self.isTypeArg(a)) try self.emitType(a) else try self.emitBare(a);
        }
        try self.w.writeAll(")");
    }

    fn isTypeArg(self: *Emitter, a: Sexp) bool {
        if (a.isKind(.@"generic_inst") or a.isKind(.@"shared") or a.isKind(.@"optional")) return true;
        if (a != .src) return false;
        const name = self.srcText(a);
        if (!std.mem.eql(u8, mapTypeName(name), name)) return true;
        const id = self.sema.symbolOf(a) orelse return false;
        return switch (self.sema.symbols.items[id].kind) {
            .nominal_type, .type_alias, .generic_type => true,
            else => false,
        };
    }

    /// `*expr`: move `expr` into a new reference-counted box.
    fn emitShare(self: *Emitter, sexp: Sexp) Error!void {
        const inner = ir.Share.operand(sexp);
        if (inner.isKind(.@"lambda")) return self.emitOwnedClosure(inner);
        const payload_ty: ?TypeId = if (self.typeOf(sexp)) |t| self.sharedInner(t) else null;
        try self.w.writeAll("rig.rcNew(");
        // A constructor call spells its own type: `rig.rcNew(Node{ ... })`.
        const typed = payload_ty != null and self.isConstructorCall(inner) and
            if (self.typeOf(inner)) |inner_ty| inner_ty == payload_ty.? else false;
        if (payload_ty != null and !typed) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(payload_ty.?);
            try self.w.writeAll(", ");
            try self.emitBare(inner);
            try self.w.writeAll(")");
        } else {
            try self.emitBare(inner);
        }
        try self.w.writeAll(")");
    }

    // -------------------------------------------------------------------------
    // Value-position blocks and branches
    // -------------------------------------------------------------------------

    /// `(if cond then else)` as a value.
    fn emitIfExpr(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        if (else_ == .nil) return self.unsupported(sexp, "an `if` without `else` in value position");
        try self.w.writeAll("if ");
        try self.pushScope();
        var prelude: Prelude = .{};
        if (cond.isKind(.@"as")) prelude = try self.emitOptionalHead(cond) else try self.emitCond(cond);
        try self.emitValueBlock(ir.If.then(sexp), prelude);
        try self.popScope();
        try self.w.writeAll(" else ");
        try self.emitValueBlock(else_, .{});
    }

    /// A block that yields its last expression: inline when it is a
    /// single expression, otherwise a labeled block. The value leaves the
    /// block, so a resource binding in tail position is moved out. A block
    /// ending in `return`/`break`/`continue` yields nothing and needs no
    /// label.
    fn emitValueBlock(self: *Emitter, body: Sexp, prelude: Prelude) Error!void {
        const stmts = try self.stmtsOf(body);
        if (stmts.len == 0) return self.unsupported(body, "an empty block in value position");
        const last = stmts[stmts.len - 1];
        if (stmts.len == 1 and prelude.isEmpty() and isValueStmt(last)) return self.emitValue(last, true);

        const terminates = isTerminatingStmt(last);
        if (!terminates and !isValueStmt(last)) return self.unsupported(last, "a block without a value in value position");
        var label: []const u8 = "";
        if (!terminates) {
            label = try self.fmt("rig_blk_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
        }
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(stmts[0 .. stmts.len - 1]);
        try self.writeIndent(self.indent);
        if (terminates) {
            try self.emitStmt(last);
        } else {
            try self.w.print("break :{s} ", .{label});
            self.bare = true;
            try self.emitValue(last, true);
            try self.w.writeAll(";");
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    fn isPrintCall(self: *Emitter, call: Sexp) bool {
        const callee = ir.Call.callee(call);
        return callee == .src and self.sema.symbolOf(callee) == null and std.mem.eql(u8, self.srcText(callee), "print");
    }

    fn emitCall(self: *Emitter, sexp: Sexp) Error!void {
        const callee = ir.Call.callee(sexp);
        const args = ir.Call.args(sexp);

        if (self.isPrintCall(sexp)) return self.emitPrint(args);
        if (callee == .src and self.sema.symbolOf(callee) == null and sema_decls.isNumericTypeName(self.srcText(callee))) return self.emitConversion(sexp);
        if (callee.isKind(.@"enum_lit")) return self.emitVariantLit(sexp);
        if (callee.isKind(.@"lambda")) return self.emitInlineInvoke(sexp);

        if (callee == .src) {
            if (self.localOf(callee)) |local| if (local.stack_closure) {
                try self.w.print("{s}.invoke(", .{local.zig_name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            };
            if (self.sema.symbolOf(callee)) |sym_id| {
                if (sym_id == self.sema.vec_sym_id) return self.emitVecConstruction(args);
                if (sym_id == self.sema.signal_sym_id) return self.emitSignalConstruction(args);
                switch (self.sema.symbols.items[sym_id].kind) {
                    .nominal_type, .generic_type => return self.emitConstructor(sexp, sym_id),
                    else => {},
                }
            }
        }
        // A variant named through its enum: `Shape.circle(r: 2)`,
        // `m.Shape.circle(r: 2)`.
        if (callee.isKind(.@"member")) if (self.typeOf(sexp)) |t| {
            const vname = self.srcText(ir.Member.name(callee));
            if (self.sema.typeOf(callee) == null and self.variantPayload(t, vname) != null) {
                try self.w.writeAll("@as(");
                try self.emitTypeTy(t);
                try self.w.writeAll(", ");
                try self.emitVariantPayload(sexp, t, vname);
                return self.w.writeAll(")");
            }
        };
        // A cross-module constructor: `m.Type(field: v)`.
        if (callee.isKind(.@"member")) if (self.typeOf(sexp)) |t| {
            if (self.sema.types.get(t) == .imported_nominal and self.sema.typeOf(callee) == null) {
                try self.emitMember(callee);
                return self.emitFieldInit(args);
            }
        };
        // An owned closure handle, held by a name or a field.
        if (self.typeOf(callee)) |t| if (self.isOwnedClosureTy(t)) {
            if (callee.isKind(.@"member")) try self.emitMember(callee) else try self.emitExpr(callee);
            try self.w.writeAll(".value.invoke(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };

        // `set` / `replace` change a Cell through any path to it: the
        // receiver's address, which may be a `*const` read borrow, is
        // cast to a mutable pointer. Sema keeps every Cell in mutable
        // storage, so the cast is sound.
        if (callee.isKind(.@"member")) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isCellTy(t) and self.sema.types.get(self.peelBorrows(t)) != .shared) {
            const m = self.srcText(ir.Member.name(callee));
            if (std.mem.eql(u8, m, "set") or std.mem.eql(u8, m, "replace")) {
                var obj = ir.Member.object(callee);
                while (obj.isKind(.@"read") or obj.isKind(.@"write")) obj = ir.get(obj, .operand);
                try self.w.writeAll("@constCast(");
                try self.emitAddressOf(obj);
                try self.w.print(").{s}(", .{m});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        if (self.sema.callSlotsOf(sexp)) |slots| {
            if (reordersEffects(slots, args)) return self.emitCallInSourceOrder(sexp, slots);
        }
        if (callee.isKind(.@"member")) try self.emitMember(callee) else try self.emitExpr(callee);
        try self.w.writeAll("(");
        try self.emitArgs(sexp);
        try self.w.writeAll(")");
    }

    /// `I32(x)` → `@as(i32, @intCast(@as(i64, x)))`, with the builtin
    /// chosen by the kinds of the two types. Zig checks that the value
    /// fits in safe builds; `@intFromFloat` truncates toward zero.
    fn emitConversion(self: *Emitter, call: Sexp) Error!void {
        const target = self.typeOf(call) orelse return self.unsupported(call, "an untyped conversion");
        const arg = argValue(ir.Call.args(call)[0]);
        const arg_ty = self.typeOf(arg) orelse return self.unsupported(call, "this conversion");
        const from = switch (self.sema.types.get(self.peelBorrows(arg_ty))) {
            .int, .float => self.peelBorrows(arg_ty),
            .int_literal => self.sema.types.int_id,
            .float_literal => self.sema.types.float_id,
            else => return self.unsupported(call, "this conversion"),
        };
        const to_int = self.sema.types.get(target) == .int;
        const from_int = self.sema.types.get(from) == .int;
        const builtin = if (to_int) (if (from_int) "@intCast" else "@intFromFloat") else (if (from_int) "@floatFromInt" else "@floatCast");
        try self.w.writeAll("@as(");
        try self.emitTypeTy(target);
        try self.w.print(", {s}(@as(", .{builtin});
        try self.emitTypeTy(from);
        try self.w.writeAll(", ");
        try self.emitBare(arg);
        try self.w.writeAll(")))");
    }

    /// `(|n| print n)()`: the closure is built and called in a block.
    fn emitInlineInvoke(self: *Emitter, call: Sexp) Error!void {
        const id = self.nextId();
        const name = try self.fmt("__rig_fn_{d}", .{id});
        try self.w.print("rig_call_{d}: {{\n", .{id});
        self.indent += 1;
        try self.writeIndent(self.indent);
        const owns = try self.emitStackClosure(name, ir.Call.callee(call));
        if (owns) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("defer rig.dropFields(&{s});", .{name});
        }
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :rig_call_{d} {s}.invoke(", .{ id, name });
        try self.emitArgs(call);
        try self.w.writeAll(");\n");
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// A call's arguments in parameter order: keyword arguments in their
    /// parameters' places and defaults for omitted ones.
    fn emitArgs(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        const params = self.paramTypes(call);
        const pre = self.preMask(call);
        if (self.sema.callSlotsOf(call)) |slots| return self.emitSlots(args, slots, null, params, pre);
        for (args, 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitArg(a, if (i < params.len) params[i] else null, isPreSlot(pre, i));
        }
    }

    /// An argument: a `!T` parameter receives a pointer; a `pre`
    /// parameter a compile-time value.
    fn emitArg(self: *Emitter, arg: Sexp, param: ?TypeId, is_pre: bool) Error!void {
        const value = argValue(arg);
        if (param) |p| if (self.isPtrBorrowTy(p)) return self.emitBorrowValue(value);
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        if (is_pre) self.keep_comptime = true;
        try self.emitBare(value);
    }

    /// Which of a call's arguments fill `pre` parameters (bit per slot).
    fn preMask(self: *Emitter, call: Sexp) u32 {
        const callee = ir.Call.callee(call);
        const f = self.fnType(self.typeOf(callee)) orelse return 0;
        if (!callee.isKind(.@"member")) return f.pre_mask;
        if (self.isTypeCallee(ir.Member.object(callee))) return f.pre_mask;
        return f.pre_mask >> 1;
    }

    /// The object of `Type.f(...)`, `module.f(...)`, or
    /// `module.Type.f(...)`: a call passing every parameter.
    fn isTypeCallee(self: *Emitter, obj: Sexp) bool {
        if (obj.isKind(.@"member")) {
            const m = ir.Member.object(obj);
            const id = self.sema.symbolOf(m) orelse return false;
            return self.sema.symbols.items[id].kind == .module;
        }
        const id = self.sema.symbolOf(obj) orelse return false;
        return switch (self.sema.symbols.items[id].kind) {
            .nominal_type, .generic_type, .module => true,
            else => false,
        };
    }

    /// The parameter types a call's arguments fill (without a method's
    /// receiver), or none when unknown.
    fn paramTypes(self: *Emitter, call: Sexp) []const TypeId {
        const callee = ir.Call.callee(call);
        const f = self.fnType(self.typeOf(callee)) orelse return &.{};
        if (!callee.isKind(.@"member")) return f.params;
        // `Type.method(...)` and `module.f(...)` pass every parameter;
        // `value.method(...)` passes all but the receiver.
        if (self.isTypeCallee(ir.Member.object(callee))) return f.params;
        return if (f.params.len > 0) f.params[1..] else f.params;
    }

    fn emitSlots(self: *Emitter, args: []const Sexp, slots: []const types.ArgSlot, temps: ?[]const ?[]const u8, params: []const TypeId, pre: u32) Error!void {
        for (slots, 0..) |slot, i| {
            if (i > 0) try self.w.writeAll(", ");
            switch (slot) {
                .arg => |ai| {
                    if (temps) |t| if (t[ai]) |name| {
                        try self.w.writeAll(name);
                        continue;
                    };
                    try self.emitArg(args[ai], if (i < params.len) params[i] else null, isPreSlot(pre, i));
                },
                .default => |d| try writeLiteral(self.w, d.source, d.expr),
            }
        }
    }

    /// Whether binding keyword arguments reorders two arguments that
    /// have side effects, which must then run in source order.
    fn reordersEffects(slots: []const types.ArgSlot, args: []const Sexp) bool {
        var last: ?usize = null;
        for (slots) |slot| {
            const ai = switch (slot) {
                .arg => |a| a,
                .default => continue,
            };
            if (isPureArg(args[ai])) continue;
            if (last) |l| if (ai < l) return true;
            last = ai;
        }
        return false;
    }

    /// `f(b: g(), a: h())` evaluates `g()` before `h()`:
    ///
    ///     rig_call_N: {
    ///         const __rig_arg_N_0 = g();
    ///         const __rig_arg_N_1 = h();
    ///         break :rig_call_N f(__rig_arg_N_1, __rig_arg_N_0);
    ///     }
    fn emitCallInSourceOrder(self: *Emitter, call: Sexp, slots: []const types.ArgSlot) Error!void {
        const callee = ir.Call.callee(call);
        const args = ir.Call.args(call);
        const params = self.paramTypes(call);
        const id = self.nextId();
        const temps = try self.arena.allocator().alloc(?[]const u8, args.len);
        @memset(temps, null);
        try self.w.print("rig_call_{d}: {{\n", .{id});
        self.indent += 1;
        for (args, 0..) |a, ai| {
            if (isPureArg(a)) continue;
            const value = argValue(a);
            const name = try self.fmt("__rig_arg_{d}_{d}", .{ id, ai });
            temps[ai] = name;
            try self.writeIndent(self.indent);
            try self.w.print("const {s}", .{name});
            if (self.typeOf(value)) |t| if (self.isPlainTy(t)) {
                try self.w.writeAll(": ");
                try self.emitTypeTy(t);
            };
            try self.w.writeAll(" = ");
            const param: ?TypeId = for (slots, 0..) |slot, pi| {
                if (slot == .arg and slot.arg == ai and pi < params.len) break params[pi];
            } else null;
            try self.emitArg(a, param, false);
            try self.w.writeAll(";\n");
        }
        try self.writeIndent(self.indent);
        try self.w.print("break :rig_call_{d} ", .{id});
        if (callee.isKind(.@"member")) try self.emitMember(callee) else try self.emitExpr(callee);
        try self.w.writeAll("(");
        try self.emitSlots(args, slots, temps, params, self.preMask(call));
        try self.w.writeAll(");\n");
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// A call `emitCall` lowers with `emitConstructor`, whose Zig spells
    /// the value's type.
    fn isConstructorCall(self: *Emitter, e: Sexp) bool {
        if (!e.isKind(.@"call") or ir.Call.callee(e) != .src) return false;
        if (self.localOf(ir.Call.callee(e))) |local| if (local.stack_closure) return false;
        const sym_id = self.sema.symbolOf(ir.Call.callee(e)) orelse return false;
        if (sym_id == self.sema.vec_sym_id or sym_id == self.sema.signal_sym_id) return false;
        return switch (self.sema.symbols.items[sym_id].kind) {
            .nominal_type, .generic_type => true,
            else => false,
        };
    }

    /// Constructor call `Name(field: v, ...)`: a struct literal typed by
    /// sema (a generic type's arguments come from the call's type).
    fn emitConstructor(self: *Emitter, call: Sexp, sym_id: SymbolId) Error!void {
        if (self.sema.symbols.items[sym_id].kind == .generic_type) {
            const ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped generic constructor");
            try self.emitTypeTy(ty);
        } else {
            try self.w.print("{f}", .{self.ident(self.srcText(ir.Call.callee(call)))});
        }
        try self.emitFieldInit(ir.Call.args(call));
    }

    /// `{ .a = x, ... }` from keyword arguments.
    fn emitFieldInit(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".{f} = ", .{self.ident(self.srcText(ir.Kwarg.name(a)))});
            try self.emitStored(ir.Kwarg.value(a));
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// `Vec()` / `Vec(capacity: n)`: a decl literal typed by its result
    /// location.
    fn emitVecConstruction(self: *Emitter, args: []const Sexp) Error!void {
        if (args.len == 1) {
            try self.w.writeAll(".initCapacity(rig.defaultAllocator(), ");
            try self.emitBare(ir.Kwarg.value(args[0]));
            return self.w.writeAll(")");
        }
        try self.w.writeAll(".init(rig.defaultAllocator())");
    }

    /// `Signal(value: v)`.
    fn emitSignalConstruction(self: *Emitter, args: []const Sexp) Error!void {
        if (args.len != 1) return self.unsupported(.nil, "this Signal construction");
        try self.w.writeAll(".init(");
        try self.emitBare(ir.Kwarg.value(args[0]));
        try self.w.writeAll(")");
    }

    /// `.variant(args)` → `.{ .variant = payload }`. A single-field
    /// payload is the value itself; several fields form a struct.
    fn emitVariantLit(self: *Emitter, call: Sexp) Error!void {
        const vname = self.srcText(ir.EnumLit.name(ir.Call.callee(call)));
        if (ir.Call.args(call).len == 0) return self.w.print(".{f}", .{self.ident(vname)});
        const enum_ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped variant");
        return self.emitVariantPayload(call, enum_ty, vname);
    }

    fn emitVariantPayload(self: *Emitter, call: Sexp, enum_ty: TypeId, vname: []const u8) Error!void {
        const args = ir.Call.args(call);
        const fields = self.variantPayload(enum_ty, vname) orelse return self.unsupported(call, "this variant");
        try self.w.print(".{{ .{f} = ", .{self.ident(vname)});
        if (fields.len == 1) {
            try self.emitStored(argValue(args[0]));
        } else {
            try self.w.writeAll(".{");
            for (args, 0..) |a, i| {
                try self.w.writeAll(if (i == 0) " " else ", ");
                const fname = if (a.isKind(.@"kwarg")) self.srcText(ir.Kwarg.name(a)) else fields[i].name;
                try self.w.print(".{f} = ", .{self.ident(fname)});
                try self.emitStored(argValue(a));
            }
            try self.w.writeAll(" }");
        }
        try self.w.writeAll(" }");
    }

    /// `print(a, b)`: the runtime writes each value the way Rig spells it.
    fn emitPrint(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("rig.print(.{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitBare(a);
        }
        try self.w.writeAll(if (args.len > 0) " })" else "})");
    }

    // =========================================================================
    // Closures
    // =========================================================================

    const Capture = struct {
        mode: Tag,
        /// The capture's own symbol, seen inside the body.
        sym: SymbolId,
        name: []const u8,
        ty: TypeId,
        /// The captured binding, where the closure is created.
        outer: ?Local,
    };

    fn captureInfo(self: *Emitter, captures: Sexp) Error![]const Capture {
        var out: std.ArrayListUnmanaged(Capture) = .empty;
        for (types.captureList(captures)) |cap| {
            const name_node = types.captureNameNode(cap).?;
            const sym = self.sema.symbolOf(name_node) orelse return self.unsupported(cap, "an unresolved capture");
            const s = self.sema.symbols.items[sym];
            const outer: ?Local = if (self.localBySym(s.origin)) |l| l.* else null;
            try out.append(self.arena.allocator(), .{ .mode = cap.kind().?, .sym = sym, .name = s.name, .ty = s.ty, .outer = outer });
        }
        return out.items;
    }

    /// `f = |captures| body` → a struct holding the captures with an
    /// `invoke` method; calls lower to `f.invoke(...)`. When a capture
    /// owns a resource, the closure is dropped at scope exit, which drops
    /// its fields.
    fn emitClosureBinding(self: *Emitter, name_node: Sexp, sym: SymbolId, lambda: Sexp) Error!void {
        const local = try self.declare(.{ .sym = sym, .zig_name = "", .stack_closure = true }, self.srcText(name_node));
        const zig_name = local.zig_name;
        const owns = try self.emitStackClosure(zig_name, lambda);
        if (owns) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("defer rig.dropFields(&{s});", .{zig_name});
        } else {
            try self.w.print(" _ = &{s};", .{zig_name});
        }
    }

    /// `var name = struct { captures, fn invoke }{ inits };`. Returns
    /// whether a capture owns a resource.
    fn emitStackClosure(self: *Emitter, zig_name: []const u8, lambda: Sexp) Error!bool {
        const caps = try self.captureInfo(ir.Lambda.captures(lambda));
        try self.w.print("var {s} = ", .{zig_name});
        try self.emitClosureStruct(lambda, caps);
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";");
        for (caps) |c| if (self.kindOf(c.ty) != null) return true;
        return false;
    }

    /// A closure's environment: its captures as fields and an `invoke`
    /// method taking its parameters.
    ///
    ///     struct { cap_x: T, pub fn invoke(__rig_self: *@This(), a: A) R { ... } }
    fn emitClosureStruct(self: *Emitter, lambda: Sexp, caps: []const Capture) Error!void {
        const params = ir.Lambda.params(lambda);
        const ret = self.lambdaReturn(lambda);

        try self.w.writeAll("struct {\n");
        self.indent += 1;
        try self.emitCaptureFields(caps);
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        const env = try self.envName();
        try self.w.print("pub fn invoke({s}: *@This()", .{env});
        try self.pushScope();
        try self.bindCaptures(caps, env);
        self.closure_depth += 1;
        defer self.closure_depth -= 1;
        const saved_fun = self.fun;
        defer self.fun = saved_fun;
        self.fun = .{ .return_ty = ret, .params = params };
        {
            try self.bindParams(params);
            for (params.items()) |p| {
                const local = self.localOf(paramNameNode(p).?).?;
                try self.w.print(", {s}: ", .{try self.paramZigName(local)});
                try self.emitParamTypeTy(local.ty orelse self.sema.types.invalid_id);
            }
        }
        try self.w.writeAll(") ");
        if (ret) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        try self.emitClosureBody(ir.Lambda.body(lambda), caps, env, ret != null);
        try self.popScope();
        try self.w.writeAll("\n");
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// A parameter of sema type `ty`: `!T` is a pointer, everything else
    /// by value.
    fn emitParamTypeTy(self: *Emitter, ty: TypeId) Error!void {
        try self.emitTypeTy(ty);
    }

    fn emitCaptureFields(self: *Emitter, caps: []const Capture) Error!void {
        for (caps) |c| {
            try self.writeIndent(self.indent);
            try self.w.print("cap_{s}: ", .{c.name});
            try self.emitTypeTy(c.ty);
            try self.w.writeAll(",\n");
        }
    }

    /// The environment parameter of the closure about to be emitted.
    fn envName(self: *Emitter) Error![]const u8 {
        if (self.closure_depth == 0) return "__rig_self";
        return self.fmt("__rig_self{d}", .{self.closure_depth});
    }

    /// Declare captures inside a closure body as `<env>.cap_<name>`.
    fn bindCaptures(self: *Emitter, caps: []const Capture, env: []const u8) Error!void {
        for (caps) |c| {
            _ = try self.declare(.{ .sym = c.sym, .zig_name = try self.fmt("{s}.cap_{s}", .{ env, c.name }), .ty = c.ty }, c.name);
        }
    }

    /// `{ .cap_x = init, ... }` evaluated where the closure is created.
    fn emitCaptureInit(self: *Emitter, caps: []const Capture) Error!void {
        if (caps.len == 0) return self.w.writeAll("{}");
        try self.w.writeAll("{");
        for (caps, 0..) |c, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".cap_{s} = ", .{c.name});
            const outer = c.outer orelse return self.unsupported(.nil, "a capture of a name that is not a local");
            switch (c.mode) {
                .@"cap_clone" => {
                    try self.writeLocalPlace(&outer);
                    // A borrowed handle clones the handle it borrows.
                    const kind = if (outer.kind) |k| k else if (outer.ty) |t| self.kindOf(self.peelBorrows(t)) else null;
                    if (kind) |k| switch (k) {
                        .shared => try self.w.writeAll(".cloneStrong()"),
                        .weak => try self.w.writeAll(".cloneWeak()"),
                        else => {},
                    };
                },
                .@"cap_weak" => {
                    try self.writeLocalPlace(&outer);
                    try self.w.writeAll(".weakRef()");
                },
                .@"cap_move" => if (outer.is_ptr and self.isPtrBorrowTy(c.ty)) {
                    // A moved pointer borrow moves the pointer.
                    try self.w.writeAll(outer.zig_name);
                } else if (self.consumeFlag(&outer)) |flag| try self.writeTake(flag, &outer) else try self.writeLocalPlace(&outer),
                else => try self.writeLocalPlace(&outer),
            }
        }
        try self.w.writeAll(" }");
    }

    /// A closure body; its environment `env` is discarded when no
    /// capture is used.
    fn emitClosureBody(self: *Emitter, body: Sexp, caps: []const Capture, env: []const u8, returns_value: bool) Error!void {
        try self.openBrace();
        var uses_self = false;
        for (caps) |c| uses_self = uses_self or self.usage.used.contains(c.sym);
        if (!uses_self) try self.line("_ = {s};", .{env});
        try self.emitFunPrologue();
        const stmts = try self.stmtsOf(body);
        if (returns_value and isValueStmt(stmts[stmts.len - 1])) {
            try self.emitStmts(stmts[0 .. stmts.len - 1]);
            try self.writeIndent(self.indent);
            try self.w.writeAll("return ");
            try self.emitReturnValue(stmts[stmts.len - 1]);
            try self.w.writeAll(";\n");
        } else {
            try self.emitStmts(stmts);
        }
        try self.closeBrace();
    }

    /// `*|captures, params| body` → a heap-allocated environment, erased
    /// into the runtime closure and boxed:
    ///
    ///     rig_closure_N: {
    ///         const __rig_Env_N = struct { cap_x: T, pub fn invoke(...) R { ... } };
    ///         const __rig_env_N = rig.create(__rig_Env_N);
    ///         __rig_env_N.* = .{ .cap_x = ... };
    ///         break :rig_closure_N rig.rcNew(rig.Closure(&.{ A }, R).init(__rig_Env_N, __rig_env_N));
    ///     }
    ///
    /// The environment is freed when the last strong handle drops.
    fn emitOwnedClosure(self: *Emitter, lambda: Sexp) Error!void {
        const f = self.fnType(self.typeOf(lambda)) orelse return self.unsupported(lambda, "an untyped closure");
        const caps = try self.captureInfo(ir.Lambda.captures(lambda));
        const id = self.nextId();
        const env = try self.fmt("__rig_Env_{d}", .{id});
        const env_ptr = try self.fmt("__rig_env_{d}", .{id});

        try self.w.print("rig_closure_{d}: {{\n", .{id});
        self.indent += 1;
        try self.writeIndent(self.indent);
        try self.w.print("const {s} = ", .{env});
        try self.emitClosureStruct(lambda, caps);
        try self.w.writeAll(";\n");
        try self.line("const {s} = rig.create({s});", .{ env_ptr, env });
        try self.writeIndent(self.indent);
        try self.w.print("{s}.* = .", .{env_ptr});
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :rig_closure_{d} rig.rcNew(", .{id});
        try self.emitClosureTy(f);
        try self.w.print(".init({s}, {s}));\n", .{ env, env_ptr });
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// The runtime closure behind `*fun(A, B) R`: `rig.Closure(&.{ A, B }, R)`.
    fn emitClosureTy(self: *Emitter, f: types.FunctionType) Error!void {
        try self.w.writeAll("rig.Closure(&.{");
        for (f.params, 0..) |p, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitTypeTy(p);
        }
        try self.w.writeAll(if (f.params.len > 0) " }, " else "}, ");
        if (f.is_sub) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
        try self.w.writeAll(")");
    }

    /// The value type a closure literal's body produces, or null.
    fn lambdaReturn(self: *Emitter, lambda: Sexp) ?TypeId {
        const f = self.fnType(self.typeOf(lambda)) orelse return null;
        return switch (self.sema.types.get(f.returns)) {
            .void, .unknown, .invalid, .noreturn => null,
            else => f.returns,
        };
    }

    // =========================================================================
    // Types
    // =========================================================================

    /// What a `*T` / `~T` handle points at; for an owned closure
    /// (`*fun(A) R`) that is the type-erased closure.
    fn emitHandleTarget(self: *Emitter, t: Sexp) Error!void {
        if (!t.isKind(.@"fun_type")) return self.emitType(t);
        const ft = t.items();
        try self.w.writeAll("rig.Closure(&.{");
        if (ft[1] == .list) for (ft[1].items(), 0..) |p, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitType(p);
        };
        try self.w.writeAll(if (ft[1] == .list and ft[1].items().len > 0) " }, " else "}, ");
        if (ft[2] != .nil) try self.emitType(ft[2]) else try self.w.writeAll("void");
        try self.w.writeAll(")");
    }

    /// A type expression from the IR.
    fn emitType(self: *Emitter, t: Sexp) Error!void {
        switch (t) {
            .src => {
                const name = self.srcText(t);
                if (std.mem.eql(u8, name, "Self")) if (self.nominal) |n| return self.w.writeAll(n.name);
                const mapped = mapTypeName(name);
                if (mapped.ptr != name.ptr) return self.w.writeAll(mapped);
                try self.writeNominalName(name);
            },
            .list => switch (t.kind().?) {
                .@"optional" => {
                    try self.w.writeAll("?");
                    try self.emitType(ir.Optional.type(t));
                },
                .@"error_union" => {
                    try self.w.writeAll("!");
                    try self.emitType(ir.ErrorUnion.type(t));
                },
                // A read borrow is held by value (a Cell's by pointer); a
                // write borrow is a pointer.
                .@"borrow_read" => {
                    if (self.isPtrBorrowSexp(t)) try self.w.writeAll("*const ");
                    try self.emitType(ir.BorrowRead.type(t));
                },
                .@"borrow_write" => {
                    try self.w.writeAll("*");
                    try self.emitType(ir.BorrowWrite.type(t));
                },
                .@"shared" => {
                    try self.w.writeAll("*rig.RcBox(");
                    try self.emitHandleTarget(ir.Shared.type(t));
                    try self.w.writeAll(")");
                },
                .@"weak" => {
                    try self.w.writeAll("rig.WeakHandle(");
                    try self.emitHandleTarget(ir.Weak.operand(t));
                    try self.w.writeAll(")");
                },
                .@"slice" => {
                    try self.w.writeAll("[]const ");
                    try self.emitType(ir.Slice.type(t));
                },
                .@"array_type" => {
                    try self.w.print("[{s}]", .{self.srcText(ir.ArrayType.size(t))});
                    try self.emitType(ir.ArrayType.type(t));
                },
                .@"generic_inst" => {
                    const name = self.srcText(ir.GenericInst.name(t));
                    try self.writeNominalName(name);
                    try self.w.writeAll("(");
                    for (ir.GenericInst.args(t), 0..) |arg, i| {
                        if (i > 0) try self.w.writeAll(", ");
                        try self.emitType(arg);
                    }
                    try self.w.writeAll(")");
                },
                .@"member" => try self.w.print("{f}.{f}", .{ self.ident(self.srcText(ir.Member.object(t))), self.ident(self.srcText(ir.Member.name(t))) }),
                .@"fun_type" => {
                    try self.w.writeAll("*const fn (");
                    for (ir.FunType.params(t).items(), 0..) |p, i| {
                        if (i > 0) try self.w.writeAll(", ");
                        try self.emitType(p);
                    }
                    try self.w.writeAll(") ");
                    const returns = ir.FunType.returns(t);
                    if (returns != .nil) try self.emitType(returns) else try self.w.writeAll("void");
                },
                else => return self.unsupported(t, "this type"),
            },
            else => return self.unsupported(t, "this type"),
        }
    }

    /// A sema type.
    fn emitTypeTy(self: *Emitter, ty: TypeId) Error!void {
        const sema = self.sema;
        switch (sema.types.get(ty)) {
            .void => try self.w.writeAll("void"),
            .any_error => try self.w.writeAll("anyerror"),
            .bool => try self.w.writeAll("bool"),
            .string => try self.w.writeAll("[]const u8"),
            .int_literal => try self.w.writeAll(int_zig),
            .float_literal => try self.w.writeAll(float_zig),
            .int => |i| if (i.bits == 0) try self.w.writeAll(int_zig) else try self.w.print("{c}{d}", .{ @as(u8, if (i.signed) 'i' else 'u'), i.bits }),
            .float => |f| if (f.bits == 0) try self.w.writeAll(float_zig) else try self.w.print("f{d}", .{f.bits}),
            .optional => |inner| {
                try self.w.writeAll("?");
                try self.emitTypeTy(inner);
            },
            .fallible => |inner| {
                try self.w.writeAll("!");
                try self.emitTypeTy(inner);
            },
            .borrow_read => |inner| {
                if (types.holdsCellByValue(sema, inner)) try self.w.writeAll("*const ");
                try self.emitTypeTy(inner);
            },
            .borrow_write => |inner| {
                try self.w.writeAll("*");
                try self.emitTypeTy(inner);
            },
            .shared => |inner| {
                try self.w.writeAll("*rig.RcBox(");
                switch (sema.types.get(inner)) {
                    .function => |f| try self.emitClosureTy(f),
                    else => try self.emitTypeTy(inner),
                }
                try self.w.writeAll(")");
            },
            .weak => |inner| {
                try self.w.writeAll("rig.WeakHandle(");
                switch (sema.types.get(inner)) {
                    .function => |f| try self.emitClosureTy(f),
                    else => try self.emitTypeTy(inner),
                }
                try self.w.writeAll(")");
            },
            .slice => |s| {
                try self.w.writeAll("[]const ");
                try self.emitTypeTy(s.elem);
            },
            .array => |a| {
                try self.w.print("[{d}]", .{a.len});
                try self.emitTypeTy(a.elem);
            },
            .nominal => |sym_id| try self.writeNominalName(sema.symbols.items[sym_id].name),
            .imported_nominal => |in| {
                const foreign = sema.foreign_semas.get(in.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
                const type_name = foreign.symbols.items[in.sym_id].name;
                for (sema.imports) |imp| {
                    if (imp.module_id == in.module_id) return self.w.print("{f}.{f}", .{ self.ident(imp.local_name), self.ident(type_name) });
                }
                // A module reached only through an import.
                for (sema.transitive) |t| {
                    if (t.module_id == in.module_id) return self.w.print("@import(\"{s}.zig\").{f}", .{ t.local_name, self.ident(type_name) });
                }
                return self.unsupported(.nil, "a type from an unimported module");
            },
            .parameterized_nominal => |pn| {
                const name = sema.symbols.items[pn.sym].name;
                try self.writeNominalName(name);
                try self.w.writeAll("(");
                for (pn.args, 0..) |arg, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.emitTypeTy(arg);
                }
                try self.w.writeAll(")");
            },
            .type_var => |sym_id| try self.w.print("{f}", .{self.ident(sema.symbols.items[sym_id].name)}),
            .function => |f| {
                try self.w.writeAll("*const fn (");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.emitTypeTy(p);
                }
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
            },
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// A user nominal, or a runtime one (`Vec` → `rig.Vec`).
    fn writeNominalName(self: *Emitter, name: []const u8) Error!void {
        if (builtinZigName(name)) |z| return self.w.print("rig.{s}", .{z});
        try self.w.print("{f}", .{self.ident(name)});
    }

    // -------------------------------------------------------------------------
    // Type queries (all from sema's facts)
    // -------------------------------------------------------------------------

    /// The type sema recorded for an expression. Poison types count as
    /// unknown.
    fn typeOf(self: *Emitter, expr: Sexp) ?TypeId {
        const ty = self.sema.typeOf(expr) orelse return null;
        return self.known(ty);
    }

    fn symType(self: *Emitter, sym: SymbolId) ?TypeId {
        return self.known(self.sema.symbols.items[sym].ty);
    }

    fn known(self: *Emitter, ty: TypeId) ?TypeId {
        if (ty == self.sema.types.unknown_id or ty == self.sema.types.invalid_id) return null;
        return ty;
    }

    fn fnType(self: *Emitter, ty: ?TypeId) ?types.FunctionType {
        const t = ty orelse return null;
        return switch (self.sema.types.get(t)) {
            .function => |f| f,
            else => null,
        };
    }

    fn peelBorrows(self: *Emitter, ty: TypeId) TypeId {
        return types.unwrapBorrows(self.sema, ty);
    }

    /// The payload fields of variant `vname` of an enum type.
    fn variantPayload(self: *Emitter, enum_ty: TypeId, vname: []const u8) ?[]const types.Field {
        const decl = types.nominalDecl(self.sema, enum_ty) orelse return null;
        for (decl.symbol().fields orelse return null) |f| {
            if (f.is_variant and std.mem.eql(u8, f.name, vname)) return f.payload orelse &.{};
        }
        return null;
    }

    fn sharedInner(self: *Emitter, ty: TypeId) ?TypeId {
        return switch (self.sema.types.get(ty)) {
            .shared => |inner| inner,
            else => null,
        };
    }

    /// How a value of this type is released, or null for plain data.
    /// Sema decides whether it owns anything (`typeHasDropGlue`, or
    /// `maybeDropGlue` for values of a type parameter, which `rig.drop`
    /// releases only if the instance needs it); this only picks the call.
    fn kindOf(self: *Emitter, ty: TypeId) ?ResourceKind {
        if (!types.typeHasDropGlue(self.sema, ty) and !types.maybeDropGlue(self.sema, ty)) return null;
        return switch (self.sema.types.get(ty)) {
            .shared => .shared,
            .weak => .weak,
            .optional => .optional,
            else => .value,
        };
    }

    fn isSharedTy(self: *Emitter, ty: TypeId) bool {
        return self.sema.types.get(self.peelBorrows(ty)) == .shared;
    }

    fn isOwnedClosureTy(self: *Emitter, ty: TypeId) bool {
        return types.ownedClosureFn(self.sema, ty) != null;
    }

    fn isBuiltinInstance(self: *Emitter, ty: TypeId, sym_id: SymbolId) bool {
        return switch (self.sema.types.get(self.peelBorrows(ty))) {
            .parameterized_nominal => |pn| pn.sym == sym_id,
            else => false,
        };
    }

    fn isVecTy(self: *Emitter, ty: TypeId) bool {
        return self.isBuiltinInstance(ty, self.sema.vec_sym_id);
    }

    fn isCellTy(self: *Emitter, ty: TypeId) bool {
        return self.isBuiltinInstance(ty, self.sema.cell_sym_id);
    }

    fn isStructLike(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(self.peelBorrows(ty))) {
            .nominal, .parameterized_nominal, .imported_nominal => true,
            else => false,
        };
    }

    fn hasLen(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(self.peelBorrows(ty))) {
            .array, .slice, .string => true,
            else => false,
        };
    }

    /// Numbers, Bool, String, and optionals of them: bindings of these
    /// types are annotated, since a literal or branch value alone has no
    /// runtime type.
    fn isPlainTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string => true,
            .optional => |inner| self.isPlainTy(inner),
            else => false,
        };
    }

    /// An error set (local or imported) or any error: its members are
    /// spelled `error.name`.
    fn isErrorSetTy(self: *Emitter, ty: TypeId) bool {
        const t = self.peelBorrows(ty);
        return self.sema.types.get(t) == .any_error or types.isErrorSet(self.sema, t);
    }

    fn isStringExpr(self: *Emitter, expr: Sexp) bool {
        const ty = self.typeOf(expr) orelse return false;
        return self.sema.types.get(self.peelBorrows(ty)) == .string;
    }

    fn isFloatExpr(self: *Emitter, expr: Sexp) bool {
        const ty = self.typeOf(expr) orelse return false;
        return switch (self.sema.types.get(self.peelBorrows(ty))) {
            .float, .float_literal => true,
            else => false,
        };
    }

    // =========================================================================
    // Output helpers
    // =========================================================================

    fn text(self: *Emitter, sexp: Sexp) ?[]const u8 {
        return switch (sexp) {
            .src => |s| self.source[s.pos..][0..s.len],
            else => null,
        };
    }

    fn srcText(self: *Emitter, sexp: Sexp) []const u8 {
        return self.source[sexp.src.pos..][0..sexp.src.len];
    }

    fn ident(self: *Emitter, name: []const u8) Ident {
        _ = self;
        return .{ .name = name };
    }

    fn writeIndent(self: *Emitter, depth: u32) Error!void {
        for (0..depth) |_| try self.w.writeAll("    ");
    }

    /// One indented line.
    fn line(self: *Emitter, comptime f: []const u8, args: anytype) Error!void {
        try self.writeIndent(self.indent);
        try self.w.print(f ++ "\n", args);
    }

    /// Report a construct the emitter cannot lower. Sema is responsible
    /// for rejecting it with a proper diagnostic; reaching this is a
    /// compiler bug.
    fn unsupported(self: *Emitter, node: Sexp, what: []const u8) Error {
        const lc = diag.lineCol(self.source, self.sema.startOf(node));
        std.debug.print("{d}:{d}: internal error: cannot emit {s} (sema should reject it)\n", .{ lc.line, lc.col, what });
        return error.Unsupported;
    }
};

// =============================================================================
// Usage scan
// =============================================================================

/// One walk over the module that records, per symbol, what the emitter
/// needs before it writes a binding: whether it is used or consumed, and
/// which match bindings view which scrutinee.
const Scan = struct {
    e: *Emitter,

    fn put(s: *Scan, set: *std.AutoHashMapUnmanaged(SymbolId, void), sym: SymbolId) Error!void {
        try set.put(s.e.allocator, sym, {});
    }

    fn consume(s: *Scan, node: Sexp) Error!void {
        if (node != .src) return;
        const sym = s.e.sema.symbolOf(node) orelse return;
        try s.put(&s.e.usage.consumed, sym);
        // Moving a resource payload out consumes its scrutinee.
        if (s.e.usage.views.get(sym)) |scrut| {
            const ty = s.e.symType(sym) orelse return;
            if (s.e.kindOf(ty) != null) try s.put(&s.e.usage.consumed, scrut);
        }
    }

    /// The name a branch yields, when it yields a bare name.
    fn consumeTail(s: *Scan, branch: Sexp) Error!void {
        const stmts = try s.e.stmtsOf(branch);
        if (stmts.len > 0) try s.consume(stmts[stmts.len - 1]);
    }

    /// Every name in a value that may leave the function.
    fn consumeAll(s: *Scan, node: Sexp) Error!void {
        switch (node) {
            .src => try s.consume(node),
            .list => |items| for (items.items()) |c| try s.consumeAll(c),
            else => {},
        }
    }

    fn walk(s: *Scan, sexp: Sexp) Error!void {
        switch (sexp) {
            .src => |leaf| {
                const sym = s.e.sema.symbolOf(sexp) orelse return;
                if (s.e.sema.symbols.items[sym].decl_pos != leaf.pos) try s.put(&s.e.usage.used, sym);
                return;
            },
            .list => {},
            else => return,
        }
        const head = sexp.kind() orelse return;
        switch (head) {
            .@"set" => if (try rig.bindingKindOf(ir.Set.op(sexp)) == .move) try s.consume(ir.Set.value(sexp)),
            .@"move" => try s.consume(ir.Move.operand(sexp)),
            .@"drop" => {
                // Dropping plain data or a borrow emits nothing: not a use.
                const name = ir.Drop.name(sexp);
                try s.consume(name);
                const sym = s.e.sema.symbolOf(name) orelse return;
                const ty = s.e.symType(sym) orelse return;
                if (s.e.kindOf(ty) != null) try s.put(&s.e.usage.used, sym);
                return;
            },
            .@"return", .@"break" => try s.consumeAll(ir.get(sexp, .value)),
            .@"for" => if (ir.For.mode(sexp).tag == .@"move") try s.consume(ir.For.source(sexp)),
            .@"if" => if (ir.If.@"else"(sexp) != .nil) {
                // An `if` with `else` may be a value: its branches yield.
                try s.consumeTail(ir.If.then(sexp));
                try s.consumeTail(ir.If.@"else"(sexp));
            },
            .@"match" => {
                var scrut = ir.Match.subject(sexp);
                while (scrut.isKind(.@"read") or scrut.isKind(.@"write")) scrut = ir.get(scrut, .operand);
                const scrut_sym = if (scrut == .src) s.e.sema.symbolOf(scrut) else null;
                for (ir.Match.arms(sexp)) |arm| {
                    const pattern = ir.Arm.pattern(arm);
                    const binds: []const Sexp = if (pattern.isKind(.@"variant_pattern")) ir.VariantPattern.bindings(pattern) else (&pattern)[0..1];
                    if (scrut_sym) |ss| for (binds) |b| {
                        if (s.e.sema.symbolOf(b)) |bs| try s.e.usage.views.put(s.e.allocator, bs, ss);
                    };
                    try s.consumeTail(ir.Arm.body(arm));
                }
            },
            .@"cap_clone", .@"cap_weak", .@"cap_move" => {
                const cap = s.e.sema.symbolOf(ir.get(sexp, .name)) orelse return;
                const origin = s.e.sema.symbols.items[cap].origin;
                try s.put(&s.e.usage.used, origin);
                if (head == .@"cap_move") {
                    try s.put(&s.e.usage.consumed, origin);
                }
                return;
            },
            .@"fun" => if (ir.Fun.returns(sexp) != .nil) {
                const stmts = try s.e.stmtsOf(ir.Fun.body(sexp));
                try s.consumeAll(stmts[stmts.len - 1]);
            },
            .@"lambda" => if (s.e.lambdaReturn(sexp) != null) {
                const stmts = try s.e.stmtsOf(ir.Lambda.body(sexp));
                try s.consumeAll(stmts[stmts.len - 1]);
            },
            else => {},
        }
        for (rig.children(sexp)) |c| try s.walk(c);
    }
};

// =============================================================================
// Free helpers
// =============================================================================

/// Zig spellings of Rig's default numeric types.
const int_zig = "i64";
const float_zig = "f64";

/// Formats a Rig identifier as a Zig identifier (`rig.writeZigIdent`).
const Ident = struct {
    name: []const u8,

    pub fn format(self: Ident, w: *Writer) Writer.Error!void {
        try rig.writeZigIdent(w, self.name);
    }
};

/// A default argument value: a literal, written from the source of the
/// module that declares it.
fn writeLiteral(w: *Writer, source: []const u8, e: Sexp) Error!void {
    switch (e) {
        .src => |s| {
            const t = source[s.pos..][0..s.len];
            if (std.mem.eql(u8, t, "none")) return w.writeAll("null");
            if (t[0] == '\'') return writeSingleQuoted(w, t);
            try w.writeAll(t);
        },
        // `-1`, `.red`: the sign or dot, then the literal.
        .list => {
            try w.writeAll(if (e.isKind(.@"neg")) "-" else ".");
            try writeLiteral(w, source, ir.get(e, if (e.isKind(.@"neg")) .operand else .name));
        },
        else => {},
    }
}

/// A Rig single-quoted string as a Zig string literal.
fn writeSingleQuoted(w: *Writer, lit: []const u8) Error!void {
    try w.writeAll("\"");
    const inner = lit[1 .. lit.len - 1];
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
            try w.writeAll("'");
            i += 1;
        } else if (c == '"' or c == '\\') {
            try w.writeByte('\\');
            try w.writeByte(c);
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeAll("\"");
}

fn isPlainIdent(name: []const u8) bool {
    return name.len > 0 and name[0] != '@' and std.mem.indexOfScalar(u8, name, '.') == null;
}

/// Literal source text: numbers, quoted strings, and the value keywords.
/// Whether Zig could evaluate `e` at compile time: it is built only from
/// literals, compile-time names (`pre` parameters, `=!` constants),
/// constructors, and operators. Conservative: true when unsure.
fn isZigComptimeIn(em: *Emitter, e: Sexp, depth: u8) bool {
    if (depth > 32) return true;
    switch (e) {
        .src => {
            const t = em.srcText(e);
            if (isLiteralText(t) or std.mem.eql(u8, t, "none")) return true;
            const sym = em.sema.symbolOf(e) orelse return true;
            const sd = em.sema.symbols.items[sym];
            return switch (sd.kind) {
                .local, .param, .capture => sd.flags.comptime_known,
                else => true,
            };
        },
        .list => {
            const h = e.kind() orelse return true;
            switch (h) {
                .@"call" => {
                    // A constructor or variant of constant arguments is
                    // constant; a function call is not.
                    const callee = ir.Call.callee(e);
                    const ctor = callee.isKind(.@"enum_lit") or (callee == .src and if (em.sema.symbolOf(callee)) |id| switch (em.sema.symbols.items[id].kind) {
                        .nominal_type, .generic_type => true,
                        else => false,
                    } else false);
                    if (!ctor) return false;
                    for (ir.Call.args(e)) |a| if (!isZigComptimeIn(em, argValue(a), depth + 1)) return false;
                    return true;
                },
                .@"share", .@"clone", .@"weak", .@"move", .@"read", .@"write", .@"lambda", .@"propagate", .@"catch" => return false,
                else => {
                    for (rig.children(e)) |c| {
                        if (c == .tag or c == .nil) continue;
                        if (!isZigComptimeIn(em, c, depth + 1)) return false;
                    }
                    return true;
                },
            }
        },
        else => return true,
    }
}

fn isIntZeroText(t: []const u8) bool {
    if (!types.isIntLiteralText(t)) return false;
    const v = std.fmt.parseInt(i128, t, 0) catch return false;
    return v == 0;
}

fn isPreSlot(mask: u32, i: usize) bool {
    return i < 32 and (mask >> @intCast(i)) & 1 == 1;
}

fn isLiteralText(t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.ascii.isDigit(t[0]) or t[0] == '"' or t[0] == '\'' or t[0] == '.') return true;
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false");
}

fn isWildcard(t: []const u8) bool {
    return std.mem.eql(u8, t, "_") or std.mem.eql(u8, t, "else");
}

fn isNonNegativeIntLiteral(source: []const u8, s: Sexp) bool {
    if (s != .src) return false;
    const t = source[s.src.pos..][0..s.src.len];
    for (t) |c| if (!std.ascii.isDigit(c) and c != '_') return false;
    return t.len > 0;
}

fn unwrapPub(s: Sexp) Sexp {
    return if (s.isKind(.@"pub")) ir.Pub.decl(s) else s;
}

/// Storage with an owner: a name, a field or element, or a borrow of one.
fn isPlace(e: Sexp) bool {
    const h = e.kind() orelse return e == .src;
    return h == .@"member" or h == .@"index" or h == .@"read" or h == .@"write";
}

/// The value of a call argument: a `(kwarg name value)` stands for its value.
fn argValue(a: Sexp) Sexp {
    return if (a.isKind(.@"kwarg")) ir.Kwarg.value(a) else a;
}

/// An argument whose evaluation has no side effects.
fn isPureArg(arg: Sexp) bool {
    return switch (arg) {
        .src, .nil => true,
        .list => switch (arg.kind().?) {
            .@"kwarg" => isPureArg(ir.Kwarg.value(arg)),
            .@"read", .@"write", .@"move", .@"member", .@"neg", .@"not", .@"enum_lit",
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or",
            => for (rig.children(arg)) |c| {
                if (!isPureArg(c)) break false;
            } else true,
            else => false,
        },
        else => false,
    };
}

fn paramNameNode(p: Sexp) ?Sexp {
    return types.paramNameNode(p);
}

fn paramIsWriteBorrow(p: Sexp) bool {
    if (p.isKind(.@"write")) return true;
    return (p.isKind(.@":") or p.isKind(.@"default")) and ir.get(p, .type).isKind(.@"borrow_write");
}

/// The runtime's name for a built-in generic type, or null.
fn builtinZigName(name: []const u8) ?[]const u8 {
    const names = [_][2][]const u8{
        .{ "Cell", "Cell" }, .{ "Vec", "Vec" }, .{ "Signal", "Signal" },
    };
    for (names) |n| if (std.mem.eql(u8, name, n[0])) return n[1];
    return null;
}

fn mapTypeName(rig_name: []const u8) []const u8 {
    const map = .{
        .{ "Int", int_zig }, .{ "Float", float_zig }, .{ "I8", "i8" },   .{ "I16", "i16" },
        .{ "I32", "i32" },   .{ "I64", "i64" },       .{ "U8", "u8" },   .{ "U16", "u16" },
        .{ "U32", "u32" },   .{ "U64", "u64" },       .{ "F32", "f32" }, .{ "F64", "f64" },
        .{ "Bool", "bool" }, .{ "String", "[]const u8" },
        .{ "Void", "void" },
    };
    inline for (map) |m| if (std.mem.eql(u8, rig_name, m[0])) return m[1];
    return rig_name;
}

/// Statements that produce a value (and can end a value block).
fn isValueStmt(s: Sexp) bool {
    const h = s.kind() orelse return true;
    return switch (h) {
        .@"set", .@"drop", .@"return", .@"break", .@"continue", .@"defer", .@"errdefer", .@"block", .@"while", .@"for", .@"labeled" => false,
        .@"if" => ir.If.@"else"(s) != .nil,
        else => true,
    };
}

fn isTerminatingStmt(s: Sexp) bool {
    const h = s.kind() orelse return false;
    return h == .@"return" or h == .@"break" or h == .@"continue";
}

fn containsPropagate(sexp: Sexp) bool {
    const h = sexp.kind() orelse return false;
    switch (h) {
        .@"propagate" => return true,
        .@"fun", .@"sub", .@"lambda" => return false,
        else => {},
    }
    for (sexp.items()) |c| if (containsPropagate(c)) return true;
    return false;
}

// =============================================================================
// Tests
// =============================================================================

fn emitSourceToString(allocator: std.mem.Allocator, rig_source: []const u8) ![]u8 {
    var p = parser.Parser.init(allocator, rig_source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var sema = try types.check(allocator, rig_source, tree);
    defer sema.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var em = Emitter.init(allocator, rig_source, &out.writer, &sema);
    defer em.deinit();
    try em.emit(tree);
    return try allocator.dupe(u8, out.written());
}

test "emit: hello world" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  print "hello, rig"
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rig.print") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hello, rig\"") != null);
}

test "emit: const for unmutated, var for reassigned or constant" {
    const out = try emitSourceToString(std.testing.allocator,
        \\fun two() -> Int
        \\  2
        \\
        \\sub main()
        \\  x = 1
        \\  y = two()
        \\  z = 5
        \\  if y > 1
        \\    x = 3
        \\  print(x + y + z)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x: " ++ int_zig ++ " = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const y: " ++ int_zig ++ " = two()") != null);
    // A constant initializer is kept out of Zig's compile-time evaluation.
    try std.testing.expect(std.mem.indexOf(u8, out, "var z: " ++ int_zig ++ " = 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x = 3;") != null);
}

test "emit: fixed binding is const" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  user =! 1
        \\  print(user)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const user: " ++ int_zig ++ " = 1") != null);
}

test "emit: propagate becomes try" {
    const out = try emitSourceToString(std.testing.allocator,
        \\fun bar() -> Int!
        \\  2
        \\
        \\fun foo() -> Int!
        \\  bar()!
        \\
        \\sub main()
        \\  x = foo()!
        \\  print(x)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "try bar()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn foo() !" ++ int_zig) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn main() !void") != null);
}

test "emit: Zig keywords and emitter names are escaped" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  var = 3
        \\  rig = 4
        \\  print(var + rig)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var @\"var\": " ++ int_zig ++ " = 3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var @\"rig'\": " ++ int_zig ++ " = 4;") != null);
}
