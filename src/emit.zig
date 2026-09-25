//! Zig code generation.
//!
//! Lowers the semantic IR (`docs/INTERNALS.md`) of one checked module to Zig
//! 0.16 source. The program has already passed sema and ownership
//! checking; this pass only chooses a representation, and it
//! reads everything it needs to know about names and types from sema's
//! facts table (`sema.zig`): which symbol a name denotes, whether a
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
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
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
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;

pub const Error = std.mem.Allocator.Error || Writer.Error || error{Unsupported};

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
    zig_name: []const u8 = "",
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
    /// A parameter copied into `zig_name` at the top of the body: the
    /// name the signature gives it.
    param_name: []const u8 = "",
};

const LocalRef = struct { scope: u32, index: u32 };

/// An argument evaluated into the temporary `name`. An owned one is
/// dropped at scope exit while `flag` is set; the call clears it.
const Hoisted = struct { node: Sexp, name: []const u8, flag: []const u8 = "" };

/// A loop used as a value: its Rig label (empty when it has none), the
/// Zig block its `break` values leave, and its type.
const ValueLoop = struct { rig: []const u8, block: []const u8, ty: TypeId };

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
    /// A closure's environment parameter, when no capture is used.
    unused_env: []const u8 = "",
};

const Nominal = struct {
    /// How `Self` is spelled: the type name, or `Self` inside a generic.
    name: []const u8,
    sym: SymbolId,
    members: []const Sexp,
};

/// Facts about bindings the emitter derives from one walk over the
/// module, keyed by symbol.
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
    sema: *const sema.SemContext,

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
    /// Emitting an operand of float arithmetic whose operands are
    /// literals: an integer literal is a value of this float type, so
    /// `7 / 2` in a `Float` is `3.5`.
    float_literals: ?TypeId = null,
    /// Emitting the object chain of an assignment target: an indexed
    /// element in it is a slot, not a copy.
    place_chain: bool = false,
    /// Arguments and receivers of the calls being emitted that were
    /// evaluated into temporaries first (`emitHoistedCall`), innermost
    /// call last.
    hoisted: std.ArrayListUnmanaged(Hoisted) = .empty,
    /// The labeled statements around the current point, innermost last:
    /// each Rig label and the Zig label it was given.
    labels: std.ArrayListUnmanaged(struct { rig: []const u8, zig: []const u8 }) = .empty,
    /// The loops used as values around the current point, innermost last.
    value_loops: std.ArrayListUnmanaged(ValueLoop) = .empty,
    /// The place being emitted is only read: a Vec element on its path
    /// is reached through `constSlot`.
    read_place: bool = false,
    /// The `else` of the loop used as a value being emitted, which is
    /// written after the loop as the block's value.
    value_else: Sexp = .nil,
    /// A name was qualified as `__rig_module.name` (`writeModuleName`).
    uses_module: bool = false,
    /// The module declares an `extern "c"`, so the program links libc.
    links_libc: bool = false,
    /// The statement or declaration being emitted, where an internal
    /// error about a node without a position is reported.
    stmt: Sexp = .nil,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer, ctx: *const sema.SemContext) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .sema = ctx,
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
        self.hoisted.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.value_loops.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        try self.w.print("const rig = @import(\"{s}\");\n", .{runtime_filename});
        if (!sexp.isKind(.module)) return;
        const decls = ir.Module.decls(sexp);
        try self.collectModule(decls);
        var scan: Scan = .{ .e = self };
        try scan.walk(sexp);
        for (decls) |decl| {
            try self.w.writeAll("\n");
            try self.emitDecl(decl);
        }
        try self.emitTestTable();
        if (self.uses_module) try self.w.writeAll("\nconst __rig_module = @This();\n");
    }

    // =========================================================================
    // Module-level declarations
    // =========================================================================

    fn collectModule(self: *Emitter, decls: []const Sexp) Error!void {
        const a = self.allocator;
        try self.module_names.put(a, "std", {});
        try self.module_names.put(a, "rig", {});
        for (decls) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            const kind = d.kind() orelse continue;
            const name = if (kind == .set) ir.Set.target(d) else if (ir.has(kind, .name)) ir.get(d, .name) else continue;
            if (name != .src) continue;
            try self.module_names.put(a, try self.fmt("{f}", .{ident(self.srcText(name))}), {});
        }
    }

    fn emitDecl(self: *Emitter, sexp: Sexp) Error!void {
        self.stmt = sexp;
        switch (sexp.kind().?) {
            // Every declaration is emitted `pub`, so `pub` adds nothing.
            .@"pub" => try self.emitDecl(ir.Pub.decl(sexp)),
            .fun, .sub => try self.emitFun(sexp),
            .extern_fun, .extern_sub => try self.emitExtern(ir.get(sexp, .name)),
            .@"extern" => try self.emitExtern(ir.Extern.name(sexp)),
            .use => try self.emitUse(sexp),
            .@"struct" => try self.emitStruct(sexp),
            .@"enum" => try self.emitEnum(sexp),
            .errors => try self.emitErrorSet(sexp),
            .generic_type => try self.emitGenericType(sexp),
            .generic_enum => try self.emitGenericEnum(sexp),
            .type => try self.emitTypeAlias(sexp),
            .@"test" => try self.emitTest(sexp),
            .set => try self.emitConst(sexp),
            else => return self.unsupported(sexp, "this top-level form"),
        }
    }

    /// A module-level constant, `name =! value`.
    fn emitConst(self: *Emitter, node: Sexp) Error!void {
        const target = ir.Set.target(node);
        try self.w.print("pub const {f}: ", .{ident(self.srcText(target))});
        try self.emitTypeTy(self.typeOf(target) orelse return self.unsupported(node, "an untyped constant"));
        try self.w.writeAll(" = ");
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        self.keep_comptime = true;
        try self.emitBare(ir.Set.value(node));
        try self.w.writeAll(";\n");
    }

    fn emitUse(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Use.name(node));
        try self.w.print("const {f} = @import(\"{s}.zig\");\n", .{ ident(name), name });
    }

    /// `extern_fun` / `extern_sub`, and `(extern _ name type)`: a C
    /// function or variable.
    fn emitExtern(self: *Emitter, name_node: Sexp) Error!void {
        self.links_libc = true;
        const ty = try self.declType(name_node);
        const f = self.fnType(ty) orelse {
            try self.w.print("extern \"c\" var {f}: ", .{ident(self.srcText(name_node))});
            try self.emitTypeTy(ty);
            return self.w.writeAll(";\n");
        };
        try self.w.print("extern \"c\" fn {f}(", .{ident(self.srcText(name_node))});
        try self.emitTypeList(f.params);
        try self.w.writeAll(") ");
        try self.emitTypeTy(f.returns);
        try self.w.writeAll(";\n");
    }

    fn emitTypeAlias(self: *Emitter, node: Sexp) Error!void {
        const name = ir.Type.name(node);
        try self.w.print("pub const {f} = ", .{ident(self.srcText(name))});
        try self.emitTypeTy(try self.declType(name));
        try self.w.writeAll(";\n");
    }

    /// The type sema gave the declaration named by `name_node`.
    fn declType(self: *Emitter, name_node: Sexp) Error!TypeId {
        const sym = self.sema.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved declaration");
        return self.symType(sym) orelse self.unsupported(name_node, "an untyped declaration");
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
        for (self.tests.items) |t| {
            try self.w.writeAll("    .{ .name = ");
            if (t.name[0] == '\'') try writeSingleQuoted(self.w, t.name) else try self.w.writeAll(t.name);
            try self.w.print(", .func = {s} }},\n", .{t.func});
        }
        try self.w.writeAll("};\n");
    }

    // -------------------------------------------------------------------------
    // Nominal types
    // -------------------------------------------------------------------------

    /// `(struct Name (: field type)... methods...)`.
    fn emitStruct(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Struct.name(node));
        const members = ir.Struct.members(node);
        try self.w.print("pub const {f} = struct {{\n", .{ident(name)});
        const prev = try self.enterNominal(ir.Struct.name(node), false, members);
        defer self.nominal = prev;
        try self.emitFields(1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_type Name (T...) members...)` → a type-returning function.
    fn emitGenericType(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericType.members(node);
        const prev = try self.enterNominal(ir.GenericType.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericType.params(node), members, "struct");
        try self.emitFields(2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(enum Name variants... methods...)`: a Zig enum, an enum with
    /// explicit values, or a tagged union when any variant has a payload.
    fn emitEnum(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Enum.name(node));
        const members = ir.Enum.members(node);
        const prev = try self.enterNominal(ir.Enum.name(node), false, members);
        defer self.nominal = prev;

        var has_values = false;
        var has_payloads = false;
        for (members) |m| {
            if (m.isKind(.valued)) has_values = true;
            if (m.isKind(.variant)) has_payloads = true;
        }
        if (has_payloads) {
            try self.w.print("pub const {f} = union(enum) {{\n", .{ident(name)});
            try self.emitUnionVariants(1);
        } else {
            try self.w.print("pub const {f} = enum{s} {{\n", .{ ident(name), if (has_values) "(u32)" else "" });
            for (members) |m| switch (m) {
                .src => try self.w.print("    {f},\n", .{ident(self.srcText(m))}),
                .list => if (m.isKind(.valued)) {
                    try self.w.print("    {f} = ", .{ident(self.srcText(ir.Valued.name(m)))});
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
        const prev = try self.enterNominal(ir.GenericEnum.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericEnum.params(node), members, "union(enum)");
        try self.emitUnionVariants(2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v...)` → a Zig error set.
    fn emitErrorSet(self: *Emitter, node: Sexp) Error!void {
        try self.w.print("pub const {f} = error{{\n", .{ident(self.srcText(ir.Errors.name(node)))});
        for (ir.Errors.members(node)) |v| if (v == .src) try self.w.print("    {f},\n", .{ident(self.srcText(v))});
        try self.w.writeAll("};\n");
    }

    fn enterNominal(self: *Emitter, name_node: Sexp, generic: bool, members: []const Sexp) Error!?Nominal {
        const prev = self.nominal;
        const sym = self.sema.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved type");
        const name = if (generic) "Self" else try self.fmt("{f}", .{ident(self.srcText(name_node))});
        self.nominal = .{ .name = name, .sym = sym, .members = members };
        return prev;
    }

    /// `pub fn Name(comptime T: type, ...) type { return <container> {`,
    /// with a discard for each type parameter nothing in the body names.
    fn emitGenericHead(self: *Emitter, params: Sexp, members: []const Sexp, container: []const u8) Error!void {
        try self.w.print("pub fn {f}(", .{ident(self.sema.symbols.items[self.nominal.?.sym].name)});
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.w.print("comptime {f}: type", .{ident(self.srcText(p))});
        }
        try self.w.writeAll(") type {\n");
        for (self.sema.symbols.items[self.nominal.?.sym].type_params orelse &.{}) |tp| {
            const used = for (members) |m| {
                if (self.mentions(m, tp)) break true;
            } else false;
            if (!used) try self.w.print("    _ = {f};\n", .{ident(self.sema.symbols.items[tp].name)});
        }
        try self.w.print("    return {s} {{\n        const Self = @This();\n\n", .{container});
    }

    /// Whether a leaf under `node` names `sym`.
    fn mentions(self: *Emitter, node: Sexp, sym: SymbolId) bool {
        return switch (node) {
            .src => self.sema.symbolOf(node) == sym,
            .list => for (node.items()) |c| {
                if (self.mentions(c, sym)) break true;
            } else false,
            else => false,
        };
    }

    /// The fields and variants of the nominal type being emitted, in
    /// declaration order.
    fn nominalFields(self: *Emitter) []const sema.Field {
        return self.sema.symbols.items[self.nominal.?.sym].fields orelse &.{};
    }

    fn emitFields(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |f| {
            if (f.is_method or f.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(f.name)});
            try self.emitTypeTy(f.ty);
            if (f.default) |d| {
                try self.w.writeAll(" = ");
                try writeLiteral(self.w, self.source, d);
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Variants of a tagged union: bare → `void`, one payload field →
    /// its type, several → a struct that `print` knows as a payload.
    fn emitUnionVariants(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |v| {
            if (!v.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(v.name)});
            const fields = v.payload orelse &.{};
            if (fields.len == 0) {
                try self.w.writeAll("void");
            } else if (fields.len == 1) {
                try self.emitTypeTy(fields[0].ty);
            } else {
                try self.w.writeAll("struct { ");
                for (fields) |f| {
                    try self.w.print("{f}: ", .{ident(f.name)});
                    try self.emitTypeTy(f.ty);
                    try self.w.writeAll(", ");
                }
                try self.w.writeAll("pub const __rig_payload = {}; }");
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Methods of a nominal type, and its `drop` body.
    fn emitMethods(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const head = m.kind() orelse continue;
            if (head != .fun and head != .sub and head != .drop_decl) continue;
            try self.w.writeAll("\n");
            try self.writeIndent(depth);
            const prev_indent = self.indent;
            self.indent = depth;
            defer self.indent = prev_indent;
            if (head == .drop_decl) {
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
        try self.line("pub fn __rig_drop(self: *{s}) void {{", .{nom});
        try self.line("    self.__rig_user_drop();", .{});
        try self.line("    rig.dropFields(self);", .{});
        try self.line("}}", .{});
    }

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// `(fun name params returns body)` / `(sub name params _ body)`.
    fn emitFun(self: *Emitter, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        const name = self.srcText(name_node);
        const params = ir.get(node, .params);
        const body = ir.get(node, .body);
        const f = self.fnType(self.sema.typeOf(name_node)) orelse return self.unsupported(name_node, "an untyped function");
        // Only the root module's `main` is the program's entry point.
        const is_main = self.sema.is_root and self.nominal == null and node.isKind(.sub) and std.mem.eql(u8, name, "main");
        const return_ty: ?TypeId = if (f.returns == self.sema.types.void_id) null else f.returns;

        self.fun = .{ .return_ty = return_ty, .params = params, .leak_check = is_main };

        // The runtime's panic handler flushes buffered `print` output first.
        if (is_main) try self.w.writeAll("pub const panic = rig.panic;\n\n");
        try self.w.print("pub fn {f}(", .{ident(name)});
        try self.pushScope();
        defer self.popScope() catch {};
        try self.bindParams(params);
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitParam(p);
        }
        try self.w.writeAll(") ");
        if (return_ty) |r| {
            try self.emitTypeTy(r);
        } else {
            // `main` may propagate a failure out of the program.
            try self.w.writeAll(if (is_main and contains(body, &.{.propagate})) "anyerror!void" else "void");
        }
        try self.w.writeAll(" ");
        if (return_ty != null) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
    }

    /// Bind each parameter in the current scope. An owned value (or one
    /// holding a Cell) is copied into a `var` at the top of the body, so
    /// it can be dropped or changed; the Zig parameter then gets a
    /// generated name. An owning `_` is dropped under a hidden name.
    fn bindParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.items()) |p| {
            const name_node = sema.paramNameNode(p) orelse continue;
            const sym = self.sema.symbolOf(name_node) orelse continue;
            const ty = self.symType(sym) orelse return self.unsupported(p, "an untyped parameter");
            const rig_name = self.srcText(name_node);
            const unused = std.mem.eql(u8, rig_name, "_");
            var local: Local = .{ .sym = sym, .ty = ty };
            if (!self.isPtrBorrowTy(ty)) {
                local.kind = self.kindOf(ty);
                local.mutable_copy = local.kind == null and !unused and sema.holdsCellByValue(self.sema, ty);
            }
            if (local.kind != null) {
                local.guard = self.resourceGuard(sym);
                if (unused) local.zig_name = try self.fresh("__rig_unused");
            }
            if (local.kind == .value or local.kind == .optional or local.mutable_copy) {
                local.param_name = try self.fmt("__rig_arg_{d}", .{self.nextId()});
            }
            _ = try self.declare(local, rig_name);
        }
    }

    /// `name: T` in a signature; `comptime` for a `pre` parameter.
    fn emitParam(self: *Emitter, p: Sexp) Error!void {
        const local = self.localOf(sema.paramNameNode(p).?).?;
        const name = if (local.param_name.len > 0) local.param_name else local.zig_name;
        try self.w.print("{s}{s}: ", .{ if (p.isKind(.pre_param)) "comptime " else "", name });
        try self.emitTypeTy(local.ty.?);
    }

    /// Statements at the top of a function body: in `main`, the deferred
    /// `rig.finish()` (flush output, check for leaks), then parameter
    /// copies and guards, and discards for unused parameters.
    fn emitFunPrologue(self: *Emitter) Error!void {
        if (self.fun.leak_check) {
            self.fun.leak_check = false;
            try self.line("defer rig.finish();", .{});
        }
        if (self.fun.unused_env.len > 0) {
            try self.line("_ = {s};", .{self.fun.unused_env});
            self.fun.unused_env = "";
        }
        const params = self.fun.params orelse return;
        self.fun.params = null;
        if (params != .list) return;
        for (params.items()) |p| {
            const local = self.localOf(sema.paramNameNode(p) orelse continue) orelse continue;
            if (local.param_name.len > 0) {
                try self.line("var {s} = {s};", .{ local.zig_name, local.param_name });
                if (local.mutable_copy) {
                    try self.line("_ = &{s};", .{local.zig_name});
                    continue;
                }
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
        const base = try self.fmt("{f}", .{ident(rig_name)});
        if (!self.nameTaken(base)) return base;
        return self.fresh(rig_name);
    }

    fn nameTaken(self: *Emitter, zig_name: []const u8) bool {
        if (self.module_names.contains(zig_name)) return true;
        if (self.nominal) |n| {
            if (std.mem.eql(u8, n.name, zig_name)) return true;
            for (n.members) |m| {
                if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
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

    /// How a resource binding's drop is armed: behind an alive flag when
    /// it may be consumed first.
    fn resourceGuard(self: *Emitter, sym: SymbolId) Guard {
        return if (self.usage.consumed.contains(sym)) .flag else .scope;
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
        if (body.isKind(.block)) return ir.Block.stmts(body);
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
        if (self.yieldsValue(stmts[last])) {
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
        self.stmt = sexp;
        // A local read for nothing is discarded by address: Zig rejects
        // discarding a name that is used elsewhere.
        const e = unborrowed(sexp);
        if (e == .src) if (self.localOf(e)) |local| return self.w.print("_ = &{s};", .{local.zig_name});
        const head = sexp.kind() orelse {
            try self.w.writeAll("_ = ");
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        };
        switch (head) {
            .set => try self.emitSet(sexp),
            .drop => try self.emitDrop(sexp),
            .@"return" => try self.emitReturn(sexp),
            .@"break" => try self.emitBreak(sexp),
            .@"continue" => try self.emitContinue(sexp),
            .@"if" => try self.emitIf(sexp),
            .@"while" => try self.emitWhile(sexp, null),
            .@"for" => try self.emitFor(sexp, null),
            .labeled => try self.emitLabeled(sexp),
            .match => try self.emitMatch(sexp, false),
            .block => try self.emitBlock(sexp),
            // `raw` marks an audit boundary for sema; it lowers to a block.
            .raw_block => try self.emitBlock(ir.RawBlock.body(sexp)),
            .@"defer", .@"errdefer" => {
                try self.w.print("{s} ", .{@tagName(head)});
                const body = ir.get(sexp, .body);
                if (body.isKind(.block)) try self.emitBlock(body) else try self.emitStmt(body);
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
        while (e.isKind(.propagate)) e = ir.Propagate.value(e);
        if (!e.isKind(.call)) return true;
        if (self.isPrintCall(e)) return false;
        // A call lowered to a labeled block is an expression Zig will not
        // take as a statement.
        if (ir.Call.callee(e).isKind(.lambda)) return true;
        if (self.hoistsArgs(e)) return true;
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
        const kind = rig.bindingKindOf(ir.Set.op(sexp));
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
        if (std.mem.eql(u8, self.srcText(target), "_")) {
            // A discarded resource is dropped at once.
            if (self.typeOf(expr)) |t| if (self.kindOf(t) != null) {
                try self.w.writeAll("rig.discard(");
                try self.emitValueOf(expr, is_move);
                return self.w.writeAll(");");
            };
            // A named place is discarded by address: it may be used
            // elsewhere, and Zig rejects discarding a used name.
            var place = expr;
            if (place.isKind(.read) or place.isKind(.write)) place = ir.get(place, .operand);
            if (!is_move and isPlace(place) and !place.isKind(.index)) {
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
    }

    /// `expr`, or `<expr` when `is_move`.
    fn emitValueOf(self: *Emitter, expr: Sexp, is_move: bool) Error!void {
        if (is_move) return self.emitMoved(expr);
        return self.emitBare(expr);
    }

    /// A new binding.
    fn emitBind(self: *Emitter, name_node: Sexp, sym: SymbolId, type_node: Sexp, expr: Sexp, is_move: bool) Error!void {
        if (expr.isKind(.lambda)) return self.emitClosureBinding(name_node, sym, expr);

        const s = self.sema.symbols.items[sym];
        const ty = self.symType(sym);
        const binds_borrow = if (ty) |t| switch (self.sema.types.get(t)) {
            .borrow_read, .borrow_write => true,
            else => false,
        } else true;
        const is_borrow = !is_move and binds_borrow and (expr.isKind(.read) or expr.isKind(.write));
        // A write borrow is held as a pointer however it was obtained.
        const holds_ptr = is_borrow or (ty != null and self.isPtrBorrowTy(ty.?));
        var local: Local = .{ .sym = sym, .ty = ty, .is_ptr = holds_ptr };
        if (!holds_ptr) {
            if (ty) |t| local.kind = self.kindOf(t);
        }
        if (local.kind != null) local.guard = self.resourceGuard(sym);

        // A Cell can change through any path to it, so a value holding
        // one lives in mutable storage.
        const needs_ptr_self = local.kind == .value or local.kind == .optional or
            (ty != null and sema.holdsCellByValue(self.sema, ty.?));
        // A constant initializer would make a Zig `const` compile-time
        // known, and Zig would then evaluate later arithmetic on it at
        // compile time; Rig treats it as a run-time value.
        const is_var = s.flags.reassigned or (!holds_ptr and (s.flags.written or needs_ptr_self or
            (!s.flags.comptime_known and !is_move and (isZigComptimeIn(self, expr, 0) or self.sema.const_ints.contains(sym)))));

        // Evaluate the value before the new name is visible, so a shadow
        // (`new x = x + 1`) reads the old binding.
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            if (is_borrow) {
                try self.emitBorrowOf(expr);
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
            if (ty != null and (type_node != .nil or self.isPlainTy(ty.?) or self.isEnumTy(ty.?))) {
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
            if (value.isKind(.read) or value.isKind(.write)) try self.emitBorrowOf(value) else try self.emitBorrowValue(value);
            return self.w.writeAll(";");
        }
        if (local.is_ptr) {
            // Through a `!T` parameter: the caller's value is replaced.
            const pointee = if (local.ty) |t| self.peelBorrows(t) else null;
            if (pointee != null and self.kindOf(pointee.?) != null) {
                const id = try self.openNewValue(pointee, value, is_move);
                return self.w.print("; rig.drop({s}); {s}.* = __rig_new_{d}; }}", .{ local.zig_name, local.zig_name, id });
            }
        }
        const kind = local.kind orelse {
            try self.writeLocalPlace(&local);
            try self.w.writeAll(" = ");
            try self.emitValueOf(value, is_move);
            try self.w.writeAll(";");
            return;
        };
        const id = try self.openNewValue(local.ty, value, is_move);
        try self.w.writeAll("; ");
        if (local.guard == .flag) try self.w.print("if ({s}) ", .{local.flag});
        try self.writeDrop(local.zig_name, kind);
        try self.w.print("; {s} = __rig_new_{d};", .{ local.zig_name, id });
        if (local.guard == .flag) try self.w.print(" {s} = true;", .{local.flag});
        try self.w.writeAll(" }");
    }

    /// `{ const __rig_new_N: T = value`: a new value, computed before the
    /// one it replaces is dropped. The type lets a context-typed value
    /// (`Vec()`, `.variant(...)`) resolve. Returns `N`.
    fn openNewValue(self: *Emitter, ty: ?TypeId, value: Sexp, is_move: bool) Error!u32 {
        const id = self.nextId();
        try self.w.print("{{ const __rig_new_{d}", .{id});
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitValueOf(value, is_move);
        return id;
    }

    /// Assignment to a field or element. When the place may hold a
    /// resource, the old value is dropped after the new one is computed.
    fn emitPlaceAssign(self: *Emitter, target: Sexp, value: Sexp, is_move: bool) Error!void {
        const place_ty = self.typeOf(target);
        if (target != .src and self.isPtrBorrowExpr(target)) {
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
        const id = try self.openNewValue(place_ty, value, is_move);
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
            .@"/", .@"%" => self.divBuiltin(op, target, value),
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
        if (target.isKind(.index)) return self.emitIndex(target, true);
        // A field of an element (`v[i].x = ...`) is reached through the
        // element's slot.
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = true;
        try self.emitExpr(target);
    }

    fn writeLocalPlace(self: *Emitter, local: *const Local) Error!void {
        if (local.is_ptr) if (self.genericReadBorrow(local.ty orelse return self.w.writeAll(local.zig_name))) |inner| {
            try self.writeBorrowedOpen(inner);
            try self.w.writeAll(local.zig_name);
            return self.w.writeAll(")");
        };
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
                if (kind == .value or kind == .optional) return self.w.print("rig.discard({s});", .{local.zig_name});
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
        if (self.fun.return_ty) |r| if (self.isPtrBorrowTy(self.unwrapOptional(r))) return self.emitBorrowValue(value);
        self.bare = true;
        try self.emitValue(value, true);
    }

    /// `(break value-or-_ label?)`. A value leaves the block of the loop
    /// it gives a value to.
    fn emitBreak(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Break.value(node);
        if (value != .nil) {
            const label = ir.Break.label(node);
            const target = self.valueLoop(if (label == .nil) "" else self.srcText(label)) orelse return self.unsupported(node, "a `break` value outside a loop used as a value");
            try self.w.print("break :{s} ", .{target.block});
            self.bare = true;
            try self.emitValueAs(value, target.ty);
            return self.w.writeAll(";");
        }
        try self.w.writeAll("break");
        try self.writeJumpLabel(ir.Break.label(node));
        try self.w.writeAll(";");
    }

    /// `(continue label?)`.
    fn emitContinue(self: *Emitter, node: Sexp) Error!void {
        try self.w.writeAll("continue");
        try self.writeJumpLabel(ir.Continue.label(node));
        try self.w.writeAll(";");
    }

    /// ` :label` of a `break` or `continue`: the innermost label of that name.
    fn writeJumpLabel(self: *Emitter, label: Sexp) Error!void {
        if (label == .nil) return;
        const name = self.srcText(label);
        const zig = self.zigLabel(name) orelse return self.unsupported(label, "a jump to an unknown label");
        try self.w.print(" :{s}", .{zig});
    }

    fn zigLabel(self: *Emitter, name: []const u8) ?[]const u8 {
        var i = self.labels.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.labels.items[i].rig, name)) return self.labels.items[i].zig;
        }
        return null;
    }

    /// Statement `if`: `(if cond then else?)`.
    fn emitIf(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        try self.w.writeAll("if ");
        if (cond.isKind(.as)) {
            try self.pushScope();
            try self.emitBodyWith(ir.If.then(sexp), try self.emitCond(cond));
            try self.popScope();
        } else {
            _ = try self.emitCond(cond);
            try self.emitBranchStmt(ir.If.then(sexp));
        }
        if (else_ != .nil) {
            try self.w.writeAll(" else ");
            if (else_.isKind(.@"if")) try self.emitIf(else_) else try self.emitBranchStmt(else_);
        }
    }

    /// `(cond) ` for `if`/`while`, or the head of `if expr as name`,
    /// whose prelude binds the name (`emitOptionalHead`).
    fn emitCond(self: *Emitter, cond: Sexp) Error!Prelude {
        if (cond.isKind(.as)) return self.emitOptionalHead(cond);
        try self.w.writeAll("(");
        try self.emitBare(cond);
        try self.w.writeAll(") ");
        return .{};
    }

    /// A statement-position body that starts with `prelude`.
    fn emitBodyWith(self: *Emitter, body: Sexp, prelude: Prelude) Error!void {
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitBranchStmt(self: *Emitter, branch: Sexp) Error!void {
        if (branch.isKind(.block)) return self.emitBlock(branch);
        try self.w.writeAll("{ ");
        try self.emitStmt(branch);
        try self.w.writeAll(" }");
    }

    /// `(labeled name stmt)`: a labeled loop, or any other statement,
    /// which `break :name` leaves as it leaves a labeled block.
    fn emitLabeled(self: *Emitter, sexp: Sexp) Error!void {
        const stmt = ir.Labeled.stmt(sexp);
        const label = self.srcText(ir.Labeled.label(sexp));
        // Zig rejects a label nothing jumps to.
        if (!self.labelUsed(stmt, label)) return self.emitStmt(stmt);
        // Zig also rejects a label inside another of the same name.
        const zig = if (self.zigLabel(label) == null)
            try self.fmt("{f}", .{ident(label)})
        else
            try self.fmt("__rig_label_{d}", .{self.nextId()});
        try self.labels.append(self.allocator, .{ .rig = label, .zig = zig });
        defer _ = self.labels.pop();
        if (stmt.isKind(.@"while")) return self.emitWhile(stmt, zig);
        if (stmt.isKind(.@"for")) return self.emitFor(stmt, zig);
        try self.w.print("{s}: ", .{zig});
        try self.openBrace();
        try self.emitStmts(&.{stmt});
        try self.closeBrace();
    }

    /// Whether a `break` or `continue` inside `node` jumps to `label`
    /// (and not to an inner label of the same name).
    fn labelUsed(self: *Emitter, node: Sexp, label: []const u8) bool {
        if (node != .list) return false;
        if (node.kind()) |k| switch (k) {
            .@"break", .@"continue" => {
                // A `break` value leaves the block of its loop instead.
                if (k == .@"break" and ir.Break.value(node) != .nil) return false;
                const l = ir.get(node, .label);
                return l != .nil and std.mem.eql(u8, self.srcText(l), label);
            },
            .labeled => if (std.mem.eql(u8, self.srcText(ir.Labeled.label(node)), label)) return false,
            .lambda => return false,
            else => {},
        };
        for (node.items()) |c| if (self.labelUsed(c, label)) return true;
        return false;
    }

    fn writeLabel(self: *Emitter, label: ?[]const u8) Error!void {
        if (label) |l| try self.w.print("{s}: ", .{l});
    }

    /// `(while cond continuation body else?)`.
    fn emitWhile(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const cond = ir.While.cond(sexp);
        const step = ir.While.step(sexp);
        try self.writeLabel(label);
        try self.w.writeAll("while ");
        try self.pushScope();
        const prelude = try self.emitCond(cond);
        if (step != .nil) {
            // A statement, so an assignment drops the value it replaces.
            try self.w.writeAll(": ({ ");
            try self.emitStmt(step);
            try self.w.writeAll(" }) ");
        }
        try self.emitBodyWith(ir.While.body(sexp), prelude);
        try self.popScope();
        try self.emitElse(ir.While.@"else"(sexp));
    }

    /// The innermost loop used as a value with Rig label `label`, or the
    /// innermost one for an unlabeled `break`.
    fn valueLoop(self: *Emitter, label: []const u8) ?ValueLoop {
        var i = self.value_loops.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.value_loops.items[i];
            if (label.len == 0 or std.mem.eql(u8, l.rig, label)) return l;
        }
        return null;
    }

    /// A loop used as a value: a labeled block holding the loop without
    /// its `else`, then the `else` value, which runs when no `break`
    /// leaves the block with a value first.
    ///
    ///     @as(T, __rig_loop_N: {
    ///         for (xs) |x| { ... break :__rig_loop_N v; ... }
    ///         break :__rig_loop_N else_value;
    ///     })
    fn emitLoopValue(self: *Emitter, sexp: Sexp) Error!void {
        const labeled = sexp.isKind(.labeled);
        const loop = if (labeled) ir.Labeled.stmt(sexp) else sexp;
        const ty = self.typeOf(loop) orelse return self.unsupported(sexp, "an untyped loop value");
        const block = try self.fmt("__rig_loop_{d}", .{self.nextId()});
        try self.writeAsOpen(ty);
        try self.w.print("{s}: ", .{block});
        try self.openBrace();
        try self.value_loops.append(self.allocator, .{ .rig = if (labeled) self.srcText(ir.Labeled.label(sexp)) else "", .block = block, .ty = ty });
        const else_ = ir.get(loop, .@"else");
        const saved_else = self.value_else;
        self.value_else = else_;
        try self.emitStmts(&.{sexp});
        self.value_else = saved_else;
        _ = self.value_loops.pop();
        if (else_ != .nil) {
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{block});
            try self.emitValueBlock(else_, .{}, ty);
            try self.w.writeAll(";\n");
        }
        try self.closeBrace();
        try self.w.writeAll(")");
    }

    /// ` else { ... }` of a loop, if it has one.
    fn emitElse(self: *Emitter, else_: Sexp) Error!void {
        if (else_ == .nil or sameNode(else_, self.value_else)) return;
        try self.w.writeAll(" else ");
        try self.emitBranchStmt(else_);
    }

    /// The index binding of `for x, i in ...` when the body reads it.
    fn loopIndex(self: *Emitter, sexp: Sexp) ?SymbolId {
        const sym = self.sema.symbolOf(ir.For.index(sexp)) orelse return null;
        return if (self.usage.used.contains(sym)) sym else null;
    }

    /// `const i: Int = @intCast(counter);` at the top of a loop body.
    fn bindLoopIndex(self: *Emitter, sexp: Sexp, counter: []const u8) Error!void {
        const sym = self.loopIndex(sexp) orelse return;
        const local = try self.declare(.{ .sym = sym, .ty = self.symType(sym) }, self.srcText(ir.For.index(sexp)));
        try self.line("const {s}: {s} = @intCast({s});", .{ local.zig_name, int_zig, counter });
    }

    /// `(for mode binding index-binding source body else?)`.
    fn emitFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const mode = ir.For.mode(sexp).tag;
        const binding = ir.For.@"var"(sexp);
        const source = ir.For.source(sexp);
        if (source.isKind(.@"..")) return self.emitRangeFor(sexp, label);

        const src_ty = self.typeOf(source);
        const is_vec = src_ty != null and self.isVecTy(src_ty.?);
        // A Vec the loop consumes, or one its source expression creates,
        // hands its elements over one at a time.
        if (is_vec and (mode == .move or (!isPlace(source) and self.kindOf(src_ty.?) != null))) {
            return self.emitConsumingFor(sexp, label);
        }
        const elem_sym = self.sema.symbolOf(binding);
        const elem_ty: ?TypeId = if (elem_sym) |s| self.symType(s) else null;
        // A resource element is a borrowed view of its slot.
        const by_ptr = mode == .write or
            (elem_ty != null and self.sema.types.get(elem_ty.?) == .borrow_read);

        try self.pushScope();
        try self.writeLabel(label);
        try self.w.writeAll("for (");
        // Writing an array's elements in place iterates through a pointer.
        const array_ptr = by_ptr and !is_vec and src_ty != null and self.sema.types.get(self.peelBorrows(src_ty.?)) == .array;
        if (array_ptr) try self.emitAddressOf(source) else try self.emitExpr(source);
        if (is_vec) try self.w.writeAll(".items()");
        const counter = try self.fmt("__rig_i_{d}", .{self.nextId()});
        // An index nobody reads needs no counter.
        const indexed = self.loopIndex(sexp) != null;
        try self.w.writeAll(if (indexed) ", 0..) |" else ") |");
        var elem_name: []const u8 = "_";
        if (elem_sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .ty = elem_ty, .is_ptr = by_ptr }, self.srcText(binding));
            elem_name = try self.fmt("{s}{s}", .{ if (by_ptr) "*" else "", stored.zig_name });
        };
        try self.w.print("{s}{s}{s}| ", .{ elem_name, if (indexed) ", " else "", if (indexed) counter else "" });
        try self.openBrace();
        try self.bindLoopIndex(sexp, counter);
        try self.emitStmts(try self.stmtsOf(ir.For.body(sexp)));
        try self.closeBrace();
        try self.popScope();
        try self.emitElse(ir.For.@"else"(sexp));
    }

    /// `for x in <v`: the Vec is consumed; each element is handed to `x`,
    /// which owns it for one iteration. Elements a `break` or `return`
    /// leaves behind are dropped with the buffer.
    ///
    ///     { var it = v.intoIter(); defer it.deinit();
    ///       while (it.next()) |e| { var x = e; defer rig.drop(&x); ... } }
    fn emitConsumingFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const binding = ir.For.@"var"(sexp);
        const id = self.nextId();
        const it = try self.fmt("__rig_it_{d}", .{id});
        const tmp = try self.fmt("__rig_elem_{d}", .{id});
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const indexed = self.loopIndex(sexp) != null;

        try self.openBrace();
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = ", .{it});
        try self.emitMoved(ir.For.source(sexp));
        try self.w.writeAll(".intoIter();\n");
        try self.line("defer {s}.deinit();", .{it});
        if (indexed) try self.line("var {s}: usize = 0;", .{counter});
        try self.writeIndent(self.indent);
        try self.writeLabel(label);
        try self.w.print("while ({s}.next()) |{s}| ", .{ it, tmp });
        if (indexed) try self.w.print(": ({s} += 1) ", .{counter});
        try self.openBrace();
        const sym = self.sema.symbolOf(binding);
        const ty: ?TypeId = if (sym) |s| self.symType(s) else null;
        if (ty != null and self.kindOf(ty.?) != null) {
            try self.bindOptionalResource(.{ .name = binding, .tmp = tmp });
        } else if (sym != null and self.usage.used.contains(sym.?)) {
            const local = try self.declare(.{ .sym = sym.?, .ty = ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ local.zig_name, tmp });
        } else try self.line("_ = {s};", .{tmp});
        try self.bindLoopIndex(sexp, counter);
        try self.emitStmts(try self.stmtsOf(ir.For.body(sexp)));
        try self.closeBrace();
        try self.emitElse(ir.For.@"else"(sexp));
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
        for ([2][]const u8{ counter, end }, [2]Sexp{ ir.@"..".left(range), ir.@"..".right(range) }, [2][]const u8{ "var", "const" }) |name, bound, decl| {
            try self.writeIndent(self.indent);
            try self.w.print("{s} {s}: ", .{ decl, name });
            try self.emitTypeTy(int_ty);
            try self.w.writeAll(" = ");
            try self.emitBare(bound);
            try self.w.writeAll(";\n");
        }
        try self.writeIndent(self.indent);
        try self.writeLabel(label);
        try self.w.print("while ({s} < {s}) : ({s} += 1) ", .{ counter, end, counter });
        try self.openBrace();
        if (sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .ty = int_ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ stored.zig_name, counter });
        };
        try self.emitStmts(try self.stmtsOf(ir.For.body(sexp)));
        try self.closeBrace();
        try self.emitElse(ir.For.@"else"(sexp));
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

        // `match ?t` / `match !t` switch on the value borrowed, and so
        // does a match on a call returning a borrow held by pointer.
        const subject = unborrowed(scrutinee);
        try self.w.writeAll("switch (");
        if (!isPlace(subject) and subject != .src and self.isPtrBorrowExpr(subject)) try self.emitDeref(subject) else try self.emitBare(subject);
        try self.w.writeAll(") ");
        try self.openBrace();

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
                    .enum_lit, .variant_pattern => {
                        const vname = self.srcText(ir.get(pattern, .name));
                        try self.w.print("{s}{f} => ", .{ if (error_set) "error." else ".", ident(vname) });
                        const captures: []const Sexp = if (pattern.isKind(.variant_pattern)) ir.VariantPattern.bindings(pattern) else &.{};
                        if (captures.len == 1) {
                            try self.emitCapture(captures[0]);
                        } else if (captures.len > 1) {
                            aliases = try self.payloadAliases(captures, scrut_ty.?, vname);
                            if (aliases.len > 0) try self.w.writeAll("|__rig_payload| ");
                        }
                    },
                    .range_pattern => {
                        // `lo..hi` is half-open; Zig's `lo...hi` is inclusive.
                        // Sema checked both bounds are constants.
                        const lo = sema.constIntOf(self.sema, ir.RangePattern.lo(pattern)) orelse return self.unsupported(pattern, "this range pattern");
                        const hi = sema.constIntOf(self.sema, ir.RangePattern.hi(pattern)) orelse return self.unsupported(pattern, "this range pattern");
                        try self.w.print("{d}...{d} => ", .{ lo, hi - 1 });
                    },
                    else => {
                        try self.emitExpr(pattern);
                        try self.w.writeAll(" => ");
                    },
                },
                else => return self.unsupported(arm, "this pattern"),
            }
            const prelude: Prelude = .{ .aliases = aliases };
            if (value_pos) try self.emitValueBlock(body, prelude, self.typeOf(sexp)) else try self.emitBodyWith(body, prelude);
            try self.w.writeAll(",\n");
        }
        // A statement match whose arms leave some values out runs no arm
        // for them (sema requires a value-position match to be complete).
        if (!has_default and !self.sema.isExhaustive(sexp)) {
            try self.line("else => {{}},", .{});
        }
        try self.closeBrace();
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
        return .{ .sym = sym, .ty = ty, .kind = if (ty) |t| self.kindOf(t) else null, .scrutinee = self.usage.views.get(sym) };
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

    fn emitPrelude(self: *Emitter, prelude: Prelude) Error!void {
        for (prelude.aliases) |a| try self.line("const {s} = __rig_payload.{f};", .{ a.zig_name, ident(a.field) });
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
        // `as _` binds no symbol; a resource inside is dropped at once.
        const sym = self.sema.symbolOf(name);
        const ty: ?TypeId = if (sym) |s| self.symType(s) else if (self.typeOf(value)) |t| switch (self.sema.types.get(self.peelBorrows(t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        if (ty != null and self.kindOf(ty.?) != null) {
            const tmp = try self.fmt("__rig_opt_{d}", .{self.nextId()});
            try self.w.print("|{s}| ", .{tmp});
            return .{ .optional = .{ .name = if (sym != null) name else .nil, .tmp = tmp } };
        }
        if (sym == null or !self.usage.used.contains(sym.?)) {
            try self.w.writeAll("|_| ");
        } else {
            const local = try self.declare(.{ .sym = sym.?, .ty = ty }, self.srcText(name));
            try self.w.print("|{s}| ", .{local.zig_name});
        }
        return .{};
    }

    /// The owning local of a resource bound by `as`, dropped at the end
    /// of the body unless it is moved out.
    fn bindOptionalResource(self: *Emitter, o: OptionalBinding) Error!void {
        if (o.name == .nil) return self.line("rig.discard({s});", .{o.tmp});
        const sym = self.sema.symbolOf(o.name).?;
        const ty = self.symType(sym).?;
        const kind = self.kindOf(ty).?;
        const local = try self.declare(.{
            .sym = sym,
            .ty = ty,
            .kind = kind,
            .guard = self.resourceGuard(sym),
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
        if (self.hoistedOf(sexp)) |h| {
            if (h.flag.len > 0) return self.w.print("rig.take(&{s}, {s})", .{ h.flag, h.name });
            return self.w.writeAll(h.name);
        }
        const float_literals = self.float_literals;
        self.float_literals = null;
        defer self.float_literals = float_literals;
        switch (sexp) {
            .src => if (float_literals != null and sema.isIntLiteralText(self.srcText(sexp))) {
                try self.writeAsOpen(float_literals.?);
                try self.w.print("{s})", .{self.srcText(sexp)});
            } else try self.emitName(sexp, tail),
            .list => try self.emitList(sexp, tail, bare, float_literals),
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
            return if (tail) self.writeTake(local) else self.writeLocalPlace(local);
        }
        if (std.mem.eql(u8, name, "none")) return self.w.writeAll("null");
        if (name[0] == '\'') return writeSingleQuoted(self.w, name);
        if (sema.isFloatLiteralText(name)) {
            // Typed, so arithmetic on literals rounds like run-time Float math.
            try self.writeAsOpen(self.typeOf(sexp) orelse self.sema.types.float_id);
            return self.w.print("{s}{s})", .{ if (name[0] == '.') "0" else "", name });
        }
        if (isLiteralText(name)) return self.w.writeAll(name);
        if (self.rt_names and !self.keep_comptime and self.isModuleConst(sexp)) {
            try self.w.writeAll("rig.rt(");
            try self.writeModuleName(name);
            return self.w.writeAll(")");
        }
        try self.writeModuleName(name);
    }

    fn isModuleConst(self: *Emitter, sexp: Sexp) bool {
        const id = self.sema.symbolOf(sexp) orelse return false;
        const sym = self.sema.symbols.items[id];
        return sym.kind == .local and sym.flags.comptime_known;
    }

    /// A module-level name. Inside a type with a method of the same name,
    /// Zig would find both, so it is qualified with the module itself.
    fn writeModuleName(self: *Emitter, name: []const u8) Error!void {
        if (self.nominal) |n| for (n.members) |m| {
            if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
            if (!std.mem.eql(u8, self.srcText(ir.get(m, .name)), name)) continue;
            self.uses_module = true;
            try self.w.writeAll("__rig_module.");
            break;
        };
        try self.w.print("{f}", .{ident(name)});
    }

    /// `local`'s value moving out: `rig.take(&flag, x)`, which yields `x`
    /// and disarms a scope-exit drop (`consumeFlag`), or `x` when no drop
    /// is armed.
    fn writeTake(self: *Emitter, local: *const Local) Error!void {
        const flag = self.consumeFlag(local) orelse return self.writeLocalPlace(local);
        try self.w.print("rig.take(&{s}, ", .{flag});
        try self.writeLocalPlace(local);
        try self.w.writeAll(")");
    }

    /// A value stored into a field, payload, or element: a write borrow is
    /// stored as its pointer.
    fn emitStored(self: *Emitter, e: Sexp) Error!void {
        if (self.isPtrBorrowExpr(e)) return self.emitBorrowValue(e);
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
            try self.writeAsOpen(t.?);
            return self.w.print("{d})", .{v});
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
        const decl = sema.nominalDecl(self.sema, ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
        }
        return false;
    }

    fn isEnumTy(self: *Emitter, ty: TypeId) bool {
        const decl = sema.nominalDecl(self.sema, ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| if (f.is_variant) return true;
        return false;
    }

    /// An expression whose value is a pointer borrow (see `isPtrBorrowTy`).
    fn isPtrBorrowExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.isPtrBorrowTy(t);
    }

    /// A borrow held as a pointer: a write borrow, and a read borrow of a
    /// value that owns resources or holds a `Cell` (see `readBorrowIsPtr`).
    fn isPtrBorrowTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(ty)) {
            .borrow_write => true,
            .borrow_read => |inner| self.readBorrowIsPtr(inner),
            else => false,
        };
    }

    /// A read borrow of plain data is a copy: nothing can change what it
    /// sees. A borrowed Cell can change while it is borrowed, and a copy
    /// of a value that owns resources would be dropped with whatever
    /// holds it, so those are held as `*const T`.
    fn readBorrowIsPtr(self: *Emitter, inner: TypeId) bool {
        return self.kindOf(inner) != null or sema.holdsCellByValue(self.sema, inner);
    }

    /// The `T` of a read borrow `?T` whose form depends on a generic
    /// type's arguments: `T` holds a type parameter and neither owns
    /// resources nor holds a Cell on its own. It is emitted as
    /// `rig.ReadBorrow(T)`, which applies `readBorrowIsPtr`'s rule to each
    /// instance, so an instance agrees with the code that uses it
    /// (`?Box(Int)` is a copy). Code that depends on the form goes through
    /// `rig.lend` and `rig.borrowed`; the rest treats it as a pointer, since
    /// Zig reaches fields and methods through either.
    fn genericReadBorrow(self: *Emitter, ty: TypeId) ?TypeId {
        const inner = switch (self.sema.types.get(ty)) {
            .borrow_read => |inner| inner,
            else => return null,
        };
        if (!sema.maybeDropGlue(self.sema, inner) or sema.holdsCellByValue(self.sema, inner)) return null;
        return inner;
    }

    fn genericReadBorrowOf(self: *Emitter, e: Sexp) ?TypeId {
        return self.genericReadBorrow(self.typeOf(e) orelse return null);
    }

    /// `?x` or `!x` held by pointer: the address of `x`, or for a generic
    /// read borrow, `rig.lend` of it.
    fn emitBorrowOf(self: *Emitter, borrow: Sexp) Error!void {
        const operand = ir.get(borrow, .operand);
        const reborrow = if (self.typeOf(operand)) |t| self.sema.types.get(t) == .borrow_read else false;
        if (reborrow or !borrow.isKind(.read) or self.genericReadBorrowOf(borrow) == null) return self.emitAddressOf(operand);
        try self.w.writeAll("rig.lend(");
        try self.emitAddressOf(operand);
        try self.w.writeAll(")");
    }

    /// `rig.borrowed(T, `: the value a generic read borrow reaches; the
    /// caller writes the borrow and the `)`.
    fn writeBorrowedOpen(self: *Emitter, inner: TypeId) Error!void {
        try self.w.writeAll("rig.borrowed(");
        try self.emitTypeTy(inner);
        try self.w.writeAll(", ");
    }

    /// `e` yielded where a value of `ty` goes: a write borrow of a Copy
    /// value (`!m`, or a call returning `!Int`) yields the value it reaches.
    /// A borrow yielded where a borrow or an optional borrow goes stays a
    /// borrow.
    fn emitValueAs(self: *Emitter, e: Sexp, ty: ?TypeId) Error!void {
        if (ty) |t| if (self.isPtrBorrowExpr(e)) {
            if (self.isPtrBorrowTy(self.unwrapOptional(t))) return self.emitBorrowValue(e);
            return self.emitDeref(e);
        };
        try self.emitValue(e, true);
    }

    /// The type an optional `ty` holds; any other type itself.
    fn unwrapOptional(self: *Emitter, ty: TypeId) TypeId {
        return switch (self.sema.types.get(ty)) {
            .optional => |inner| inner,
            else => ty,
        };
    }

    /// `(e).*`: the value a write borrow reaches.
    fn emitDeref(self: *Emitter, e: Sexp) Error!void {
        if (self.genericReadBorrowOf(e)) |inner| {
            try self.writeBorrowedOpen(inner);
            try self.emitBorrowValue(e);
            return self.w.writeAll(")");
        }
        try self.w.writeAll("(");
        try self.emitBorrowValue(e);
        try self.w.writeAll(").*");
    }

    /// A write-borrow value: the pointer a `!T` expression denotes.
    fn emitBorrowValue(self: *Emitter, e: Sexp) Error!void {
        const saved = self.ptr_tail;
        defer self.ptr_tail = saved;
        self.ptr_tail = true;
        self.bare = true;
        try self.emitValue(e, true);
    }

    /// `@as(T, `: the caller writes the value and the `)`.
    fn writeAsOpen(self: *Emitter, ty: TypeId) Error!void {
        try self.w.writeAll("@as(");
        try self.emitTypeTy(ty);
        try self.w.writeAll(", ");
    }

    /// `*T` / `*const T` for a borrow type.
    fn emitPointerTy(self: *Emitter, ty: TypeId) Error!void {
        if (self.genericReadBorrow(ty) != null) return self.emitTypeTy(ty);
        switch (self.sema.types.get(ty)) {
            .borrow_read, .borrow_write => |inner| {
                try self.w.writeAll(if (self.sema.types.get(ty) == .borrow_read) "*const " else "*");
                try self.emitTypeTy(inner);
            },
            else => try self.emitTypeTy(ty),
        }
    }

    /// `<x`: the value leaves its binding.
    fn emitMoved(self: *Emitter, inner: Sexp) Error!void {
        if (inner == .src) if (self.localOf(inner)) |local| {
            if (self.consumeFlag(local) != null) return self.writeTake(local);
        };
        try self.emitBare(inner);
    }

    fn emitList(self: *Emitter, sexp: Sexp, tail: bool, bare: bool, float_literals: ?TypeId) Error!void {
        const head = sexp.kind().?;
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        switch (head) {
            // Literal operands of float arithmetic are floats.
            .@"+", .@"-", .@"*", .@"/", .@"%", .neg => if (float_literals orelse self.floatTypeOf(sexp)) |f| {
                self.float_literals = f;
            },
            else => {},
        }
        if (self.float_literals == null) switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"&", .@"|", .@"^", .neg, .@"if" => {
                // Sema computed a constant integer expression (and checked
                // that it fits); its value is written as a literal, so Zig
                // does not evaluate it again with other intermediate types.
                if (sema.constIntOf(self.sema, sexp)) |v| if (self.onlyConstantLeaves(sexp)) return self.emitIntConstant(sexp, v);
            },
            else => {},
        };
        switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .neg, .index => self.rt_names = true,
            else => {},
        }
        switch (head) {
            .read => {
                // `?x` of a value held by pointer (a Cell) is its address.
                if (self.isPtrBorrowExpr(sexp)) return self.emitBorrowOf(sexp);
                // A borrow never moves its operand, even in tail position.
                self.bare = bare;
                try self.emitValue(ir.Read.operand(sexp), false);
            },
            // `!x` as a value (an argument, a receiver) is the place's address.
            .write => try self.emitAddressOf(ir.Write.operand(sexp)),
            .move => {
                self.bare = bare;
                const operand = ir.Move.operand(sexp);
                if (tail and self.ptr_tail) try self.emitValue(operand, true) else try self.emitMoved(operand);
            },
            .share => try self.emitShare(sexp),
            .clone => {
                // `+b` of a borrowed handle clones the handle it borrows.
                const operand = ir.Clone.operand(sexp);
                const kind: ?ResourceKind = if (self.typeOf(operand)) |t| self.kindOf(self.peelBorrows(t)) else null;
                if (kind == .optional) {
                    try self.w.writeAll("rig.cloneOptional(");
                    try self.emitBare(operand);
                    return self.w.writeAll(")");
                }
                // A generic `T` is cloned only where each instance is plain
                // data, so it is copied.
                if (kind == .value and !sema.maybeDropGlue(self.sema, self.peelBorrows(self.typeOf(operand).?))) return self.unsupported(sexp, "a clone of a value with drop glue");
                try self.emitExpr(operand);
                if (kind == .shared) try self.w.writeAll(".cloneStrong()");
                if (kind == .weak) try self.w.writeAll(".cloneWeak()");
            },
            .weak => {
                try self.emitExpr(ir.Weak.operand(sexp));
                try self.w.writeAll(".weakRef()");
            },
            .call => if (self.hoistsArgs(sexp)) try self.emitHoistedCall(sexp) else try self.emitCallDirect(sexp),
            .member, .index => {
                // A field or element holding a write borrow denotes the
                // borrowed value, unless the pointer itself is wanted.
                const deref = self.isPtrBorrowExpr(sexp) and !(tail and self.ptr_tail);
                const generic = if (deref) self.genericReadBorrowOf(sexp) else null;
                if (generic) |inner| try self.writeBorrowedOpen(inner);
                if (head == .member) try self.emitMember(sexp) else try self.emitIndex(sexp, self.place_chain);
                if (generic != null) try self.w.writeAll(")") else if (deref) try self.w.writeAll(".*");
            },
            .builtin => try self.emitBuiltin(sexp),
            .propagate => {
                try self.w.writeAll("try ");
                try self.emitExpr(ir.Propagate.value(sexp));
            },
            .propagate_none => {
                const operand = ir.PropagateNone.value(sexp);
                try self.w.writeAll("(");
                if (self.isPtrBorrowExpr(operand)) try self.emitDeref(operand) else try self.emitExpr(operand);
                try self.w.writeAll(" orelse return null)");
            },
            .neg => {
                const operand = ir.Neg.operand(sexp);
                // Zig rejects the literal `-0` as ambiguous; `0 - 0` is 0.
                if (operand == .src and isIntZeroText(self.srcText(operand))) return self.w.writeAll("0");
                try self.w.writeAll("-");
                try self.emitExpr(operand);
            },
            .not => {
                try self.w.writeAll("!");
                try self.emitExpr(ir.Not.operand(sexp));
            },
            .enum_lit => {
                const in_error_set = if (self.typeOf(sexp)) |t| self.isErrorSetTy(t) else false;
                try self.w.print("{s}{f}", .{ if (in_error_set) "error." else ".", ident(self.srcText(ir.EnumLit.name(sexp))) });
            },
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^" => try self.emitInfix(sexp, bare),
            .@"and", .@"or" => {
                if (!bare) try self.w.writeAll("(");
                try self.emitExpr(ir.get(sexp, .left));
                try self.w.writeAll(if (head == .@"and") " and " else " or ");
                try self.emitExpr(ir.get(sexp, .right));
                if (!bare) try self.w.writeAll(")");
            },
            .@"<<", .@">>" => {
                // Like `+`, a left shift that loses bits (or the sign)
                // overflows (`@shlExact`). The shift amount is cast to the
                // width Zig requires; the shifted value has the
                // expression's type.
                const shl = head == .@"<<";
                const parens = !shl and !bare;
                if (parens) try self.w.writeAll("(");
                if (shl) try self.w.writeAll("@shlExact(");
                try self.writeAsOpen(self.typeOf(sexp) orelse self.sema.types.int_id);
                try self.emitBare(ir.get(sexp, .left));
                try self.w.writeAll(if (shl) "), @intCast(" else ") >> @intCast(");
                try self.emitBare(ir.get(sexp, .right));
                try self.w.writeAll(if (shl) "))" else ")");
                if (parens) try self.w.writeAll(")");
            },
            .@"/", .@"%" => try self.emitDivision(sexp),
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
                    const local = try self.declare(.{ .sym = sym.?, .ty = self.symType(sym.?) }, self.srcText(name));
                    try self.emitValueBlock(handler, .{ .err_capture = .{ .zig_name = local.zig_name, .tmp = tmp } }, self.typeOf(sexp));
                    try self.popScope();
                } else try self.emitValue(handler, true);
                try self.w.writeAll(")");
            },
            .@"if", .match => {
                // Literal branches under a run-time condition need the
                // result's type spelled out.
                const num = self.numericValueTy(sexp);
                if (num) |t| {
                    try self.writeAsOpen(t);
                } else if (!bare and head == .@"if") try self.w.writeAll("(");
                if (head == .@"if") try self.emitIfExpr(sexp) else try self.emitMatch(sexp, true);
                if (num != null) try self.w.writeAll(")") else if (!bare and head == .@"if") try self.w.writeAll(")");
            },
            .block => try self.emitValueBlock(sexp, .{}, self.typeOf(sexp)),
            .raw_block => try self.emitValueBlock(ir.RawBlock.body(sexp), .{}, self.typeOf(sexp)),
            .@"while", .@"for", .labeled => if (sema.hasValueBreaks(self.source, sexp)) try self.emitLoopValue(sexp) else return self.unsupported(sexp, "a loop without a value in value position"),
            .array => try self.emitArray(sexp),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// A statement that produces a value, including a loop used as one.
    fn yieldsValue(self: *Emitter, s: Sexp) bool {
        return isValueStmt(s) or sema.hasValueBreaks(self.source, s);
    }

    fn isNoneLeaf(self: *Emitter, e: Sexp) bool {
        return e == .src and self.sema.symbolOf(e) == null and std.mem.eql(u8, self.srcText(e), "none");
    }

    /// `&place`, or the pointer itself when the place is already one.
    fn emitAddressOf(self: *Emitter, place: Sexp) Error!void {
        if (place == .src) if (self.localOf(place)) |local| {
            if (local.is_ptr) return self.w.writeAll(local.zig_name);
        };
        if (self.isPtrBorrowExpr(place)) return self.emitBorrowValue(place);
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
            const optional = self.isOptStringExpr(operands[0]) or self.isOptStringExpr(operands[1]);
            try self.w.writeAll(if (optional) "rig.eqlOptStr(" else "std.mem.eql(u8, ");
            try self.emitExpr(operands[0]);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[1]);
            try self.w.writeAll(")");
            return;
        }
        // Zig compares an optional with a value, but not an optional error.
        if (is_eq) for (operands) |o| {
            const inner = self.optionalErrorOf(o) orelse continue;
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("rig.eqlOpt(");
            try self.emitTypeTy(inner);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[0]);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[1]);
            return self.w.writeAll(")");
        };
        if (!bare) try self.w.writeAll("(");
        try self.emitExpr(operands[0]);
        try self.w.print(" {s} ", .{op});
        try self.emitExpr(operands[1]);
        if (!bare) try self.w.writeAll(")");
    }

    /// `a / b` and `a % b` (see `divBuiltin`).
    fn emitDivision(self: *Emitter, sexp: Sexp) Error!void {
        const left = ir.get(sexp, .left);
        const right = ir.get(sexp, .right);
        const builtin = self.divBuiltin(sexp.kind().?, left, right) orelse return self.emitInfix(sexp, false);
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
        const borrows = self.isPtrBorrowTy(arr.array.elem);
        for (elems, 0..) |e, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (!borrows and self.isPtrBorrowExpr(e)) try self.emitDeref(e) else try self.emitStored(e);
        }
        try self.w.writeAll(if (elems.len > 0) " }" else "}");
    }

    /// `x[i]`: bounds-checked element of an array, slice, string, or
    /// `Vec` of plain data. As a place, a `Vec` element is `x.slot(i).*`,
    /// and the base of any element is a place too.
    fn emitIndex(self: *Emitter, sexp: Sexp, as_place: bool) Error!void {
        const base = ir.Index.object(sexp);
        const index = ir.Index.index(sexp);
        const base_ty = self.typeOf(base);
        const saved_chain = self.place_chain;
        defer self.place_chain = saved_chain;
        self.place_chain = as_place;

        if (index.isKind(.@"..")) return self.emitSlice(base, base_ty, index);
        if (base_ty != null and self.isVecTy(base_ty.?)) {
            try self.emitExpr(base);
            try self.w.writeAll(if (!as_place) ".at(" else if (self.read_place) ".constSlot(" else ".slot(");
            // The index itself is a value, even inside an assignment target.
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(if (as_place) ").*" else ")");
            return;
        }
        const array_len: ?usize = if (base_ty) |t| switch (self.sema.types.get(self.peelBorrows(t))) {
            .array => |a| a.len,
            else => null,
        } else null;
        const n = array_len orelse {
            // A string or slice, which is never assigned to: its length is
            // only known when it runs, and `rig.at` evaluates it once.
            try self.w.writeAll("rig.at(");
            try self.emitBare(base);
            try self.w.writeAll(", ");
            self.place_chain = false;
            try self.emitBare(index);
            return self.w.writeAll(")");
        };
        // An array literal is indexed through parentheses: `([_]T{ ... })[i]`.
        const literal = base.isKind(.array);
        if (literal) try self.w.writeAll("(");
        try self.emitExpr(base);
        if (literal) try self.w.writeAll(")");
        try self.w.writeAll("[");
        self.place_chain = false;
        // Sema checked a constant index against the array's length.
        if (isNonNegativeIntLiteral(self.source, index)) {
            try self.emitExpr(index);
        } else {
            try self.w.writeAll("rig.index(");
            try self.emitBare(index);
            try self.w.print(", {d})", .{n});
        }
        try self.w.writeAll("]");
    }

    /// `xs[a..b]` → `rig.slice(items, a, b)`, which checks the bounds. An
    /// array is sliced in place, through its address; a Vec through its
    /// items.
    fn emitSlice(self: *Emitter, base: Sexp, base_ty: ?TypeId, range: Sexp) Error!void {
        self.place_chain = false;
        try self.w.writeAll("rig.slice(");
        const ty = self.peelBorrows(base_ty orelse return self.unsupported(base, "a slice of an untyped value"));
        // A constant is sliced where it is stored, not through a copy.
        const saved_rt = self.rt_names;
        self.rt_names = false;
        if (self.isVecTy(ty)) {
            try self.emitExpr(base);
            try self.w.writeAll(".items()");
        } else if (self.sema.types.get(ty) == .array) {
            // Only read through: a Vec element on the way is reached
            // through a read-only slot.
            const saved_read = self.read_place;
            self.read_place = true;
            try self.emitAddressOf(base);
            self.read_place = saved_read;
        } else try self.emitBare(base);
        self.rt_names = saved_rt;
        try self.w.writeAll(", ");
        try self.emitBare(ir.@"..".left(range));
        try self.w.writeAll(", ");
        try self.emitBare(ir.@"..".right(range));
        try self.w.writeAll(")");
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
            try self.writeAsOpen(t);
            try self.emitMemberBase(obj, obj_ty);
            return self.w.print(".{f})", .{ident(field)});
        };
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.hasLen(obj_ty.?)) {
            try self.w.writeAll("rig.len(");
            try self.emitMemberBase(obj, obj_ty);
            try self.w.writeAll(".len)");
            return;
        }
        // An imported constant is read at run time, like a local one.
        if (self.rt_names and !self.keep_comptime and self.isModuleValue(obj, sexp)) {
            try self.w.writeAll("rig.rt(");
            try self.writeModuleName(self.srcText(obj));
            return self.w.print(".{f})", .{ident(field)});
        }
        try self.emitMemberBase(obj, obj_ty);
        if (obj_ty) |t| if (self.sema.types.get(self.peelBorrows(t)) == .shared) try self.w.writeAll(".value");
        try self.w.print(".{f}", .{ident(field)});
    }

    /// `module.name` naming a constant (not a function or a type).
    fn isModuleValue(self: *Emitter, obj: Sexp, member: Sexp) bool {
        if (obj != .src) return false;
        const id = self.sema.symbolOf(obj) orelse return false;
        if (self.sema.symbols.items[id].kind != .module) return false;
        const ty = self.typeOf(member) orelse return false;
        return self.fnType(ty) == null;
    }

    /// The object of a member access. Borrow sigils on a receiver are
    /// implicit in Zig's method call syntax; pointers to structs
    /// auto-dereference.
    fn emitMemberBase(self: *Emitter, obj: Sexp, obj_ty: ?TypeId) Error!void {
        const o = unborrowed(obj);
        if (self.place_chain and o.isKind(.index)) return self.emitIndex(o, true);
        // `Box.make(...)` of a generic type: the instance sema inferred.
        if (o == .src) if (self.sema.symbolOf(o)) |id| if (self.sema.symbols.items[id].kind == .generic_type) {
            if (obj_ty) |t| return self.emitTypeTy(t);
        };
        if (o == .src) if (self.localOf(o)) |local| {
            if (local.is_ptr and obj_ty != null and self.isStructLike(obj_ty.?)) return self.w.writeAll(local.zig_name);
            return self.writeLocalPlace(local);
        };
        const needs_parens = if (o.kind()) |h| switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .neg, .not, .@"if", .match, .@"??", .@"catch", .propagate, .call, .array => true,
            else => false,
        } else false;
        if (needs_parens) try self.w.writeAll("(");
        try self.emitExpr(o);
        if (needs_parens) try self.w.writeAll(")");
        // A call yielding a borrow held by pointer: Zig reaches a field
        // through a pointer to a struct, but not through one to a handle.
        if (o.isKind(.call) and obj_ty != null and self.isPtrBorrowTy(obj_ty.?) and !self.isStructLike(obj_ty.?)) try self.w.writeAll(".*");
    }

    /// `@name(args)`. Arguments that name Rig types are spelled as Zig types.
    fn emitBuiltin(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.print("@{s}(", .{self.srcText(ir.Builtin.name(sexp))});
        for (ir.Builtin.args(sexp), 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (self.isTypeArg(sexp, a)) try self.emitTypeTy(self.typeOf(a).?) else try self.emitBare(a);
        }
        try self.w.writeAll(")");
    }

    /// Every argument of `@sizeOf`, `@alignOf`, and `@typeName` is a
    /// type, except `@TypeOf(x)`.
    fn isTypeArg(self: *Emitter, builtin: Sexp, a: Sexp) bool {
        if (a.isKind(.builtin)) return false;
        const name = self.srcText(ir.Builtin.name(builtin));
        return std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf") or std.mem.eql(u8, name, "typeName");
    }

    /// `*expr`: move `expr` into a new reference-counted box.
    fn emitShare(self: *Emitter, sexp: Sexp) Error!void {
        const inner = ir.Share.operand(sexp);
        if (inner.isKind(.lambda)) return self.emitOwnedClosure(inner);
        const payload_ty: ?TypeId = if (self.typeOf(sexp)) |t| switch (self.sema.types.get(t)) {
            .shared => |p| p,
            else => null,
        } else null;
        try self.w.writeAll("rig.rcNew(");
        // A constructor call spells its own type: `rig.rcNew(Node{ ... })`.
        const typed = payload_ty != null and self.isConstructorCall(inner) and
            if (self.typeOf(inner)) |inner_ty| inner_ty == payload_ty.? else false;
        const cast = payload_ty != null and !typed;
        if (cast) try self.writeAsOpen(payload_ty.?);
        try self.emitBare(inner);
        try self.w.writeAll(if (cast) "))" else ")");
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
        const prelude = try self.emitCond(cond);
        try self.emitValueBlock(ir.If.then(sexp), prelude, self.typeOf(sexp));
        try self.popScope();
        try self.w.writeAll(" else ");
        try self.emitValueBlock(else_, .{}, self.typeOf(sexp));
    }

    /// A block that yields its last expression: inline when it is a
    /// single expression, otherwise a labeled block. The value leaves the
    /// block, so a resource binding in tail position is moved out. A block
    /// ending in `return`/`break`/`continue` yields nothing and needs no
    /// label. `result` is the type the block yields.
    fn emitValueBlock(self: *Emitter, body: Sexp, prelude: Prelude, result: ?TypeId) Error!void {
        const stmts = try self.stmtsOf(body);
        if (stmts.len == 0) return self.unsupported(body, "an empty block in value position");
        const last = stmts[stmts.len - 1];
        if (stmts.len == 1 and prelude.isEmpty() and self.yieldsValue(last)) return self.emitValueAs(last, result);

        const terminates = isTerminatingStmt(last);
        if (!terminates and !self.yieldsValue(last)) return self.unsupported(last, "a block without a value in value position");
        var label: []const u8 = "";
        if (!terminates) {
            label = try self.fmt("__rig_blk_{d}", .{self.nextId()});
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
            try self.emitValueAs(last, result);
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

    fn emitCallDirect(self: *Emitter, sexp: Sexp) Error!void {
        const callee = ir.Call.callee(sexp);
        const args = ir.Call.args(sexp);

        if (self.isPrintCall(sexp)) return self.emitPrint(args);
        if (callee == .src and self.sema.symbolOf(callee) == null and resolve.isNumericTypeName(self.srcText(callee))) return self.emitConversion(sexp);
        if (callee.isKind(.enum_lit)) return self.emitVariantLit(sexp);
        if (callee.isKind(.lambda)) return self.emitInlineInvoke(sexp);

        if (callee == .src) {
            if (self.localOf(callee)) |local| if (local.stack_closure) {
                try self.w.print("{s}.invoke(", .{local.zig_name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            };
            if (self.sema.symbolOf(callee)) |sym_id| {
                if (sym_id == self.sema.vec_sym_id) return self.emitVecConstruction(args);
                if (sym_id == self.sema.signal_sym_id) return self.emitSignalConstruction(sexp);
                if (self.isTypeSym(sym_id)) return self.emitConstructor(sexp, sym_id);
            }
        }
        // A member callee without a type of its own names a variant
        // through its enum (`Shape.circle(r: 2)`, `m.Shape.circle(r: 2)`)
        // or a type in another module (`m.Type(field: v)`).
        if (callee.isKind(.member) and self.sema.typeOf(callee) == null) if (self.typeOf(sexp)) |t| {
            const vname = self.srcText(ir.Member.name(callee));
            if (self.variantPayload(t, vname) != null) {
                try self.writeAsOpen(t);
                try self.emitVariantPayload(sexp, t, vname);
                return self.w.writeAll(")");
            }
            if (self.sema.types.get(t) == .imported_nominal) {
                try self.emitMember(callee);
                return self.emitFieldInit(args);
            }
        };
        // An owned closure handle, held by a name or a field.
        if (self.typeOf(callee)) |t| if (sema.ownedClosureFn(self.sema, t) != null) {
            try self.emitExpr(callee);
            try self.w.writeAll(".value.invoke(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };

        // `set` / `replace` change a Cell through any path to it: the
        // receiver's address, which may be a `*const` read borrow, is
        // cast to a mutable pointer. Sema keeps every Cell in mutable
        // storage, so the cast is sound.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isBuiltinInstance(t, self.sema.cell_sym_id)) {
            const m = self.srcText(ir.Member.name(callee));
            if (std.mem.eql(u8, m, "set") or std.mem.eql(u8, m, "replace")) {
                try self.w.writeAll("@constCast(");
                try self.emitAddressOf(unborrowed(ir.Member.object(callee)));
                try self.w.print(").{s}(", .{m});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        try self.emitExpr(callee);
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
        try self.writeAsOpen(target);
        try self.w.print("{s}(", .{builtin});
        try self.writeAsOpen(from);
        // A constant is converted at run time, where Zig checks it as Rig
        // does, not at compile time.
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        self.rt_names = true;
        try self.emitBare(arg);
        try self.w.writeAll(")))");
    }

    /// `(|n| print n)()`: the closure is built and called in a block.
    fn emitInlineInvoke(self: *Emitter, call: Sexp) Error!void {
        const id = self.nextId();
        const name = try self.fmt("__rig_fn_{d}", .{id});
        try self.w.print("__rig_inline_{d}: ", .{id});
        try self.openBrace();
        try self.writeIndent(self.indent);
        if (try self.emitStackClosure(name, ir.Call.callee(call))) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("defer rig.dropFields(&{s});", .{name});
        }
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_inline_{d} {s}.invoke(", .{ id, name });
        try self.emitArgs(call);
        try self.w.writeAll(");\n");
        try self.closeBrace();
    }

    /// A call's arguments in parameter order: keyword arguments in their
    /// parameters' places and defaults for omitted ones.
    fn emitArgs(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        const params = self.callParams(call);
        const slots = self.sema.callSlotsOf(call) orelse {
            for (args, 0..) |a, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.emitArg(a, params, i);
            }
            return;
        };
        for (slots, 0..) |slot, i| {
            if (i > 0) try self.w.writeAll(", ");
            switch (slot) {
                .arg => |ai| try self.emitArg(args[ai], params, i),
                .default => |d| try writeLiteral(self.w, d.source, d.expr),
            }
        }
    }

    /// The argument filling parameter slot `i`: a `!T` parameter receives
    /// a pointer; a `pre` parameter a compile-time value.
    fn emitArg(self: *Emitter, arg: Sexp, params: CallParams, i: usize) Error!void {
        const value = argValue(arg);
        if (i < params.tys.len and self.isPtrBorrowTy(params.tys[i])) return self.emitBorrowValue(value);
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        if (i < 32 and (params.pre >> @intCast(i)) & 1 == 1) self.keep_comptime = true;
        try self.emitBare(value);
    }

    /// The parameters a call's arguments fill, in slot order.
    const CallParams = struct {
        tys: []const TypeId = &.{},
        /// Which slots are `pre` parameters, one bit per slot.
        pre: u32 = 0,
    };

    /// The parameters a call's arguments fill: all of them for `f(...)`,
    /// `Type.method(...)`, and `module.f(...)`; all but the receiver for
    /// `value.method(...)`.
    fn callParams(self: *Emitter, call: Sexp) CallParams {
        const callee = ir.Call.callee(call);
        const f = self.fnType(self.typeOf(callee)) orelse return .{};
        if (!callee.isKind(.member) or self.isTypeCallee(ir.Member.object(callee))) return .{ .tys = f.params, .pre = f.pre_mask };
        return .{ .tys = if (f.params.len > 0) f.params[1..] else f.params, .pre = f.pre_mask >> 1 };
    }

    /// The object of `Type.f(...)`, `module.f(...)`, or
    /// `module.Type.f(...)`: a call passing every parameter.
    fn isTypeCallee(self: *Emitter, obj: Sexp) bool {
        if (obj.isKind(.member)) {
            const m = ir.Member.object(obj);
            const id = self.sema.symbolOf(m) orelse return false;
            return self.sema.symbols.items[id].kind == .module;
        }
        const id = self.sema.symbolOf(obj) orelse return false;
        return self.isTypeSym(id) or self.sema.symbols.items[id].kind == .module;
    }

    /// A struct, enum, or generic type: calling it constructs a value.
    fn isTypeSym(self: *Emitter, id: SymbolId) bool {
        return switch (self.sema.symbols.items[id].kind) {
            .nominal_type, .generic_type => true,
            else => false,
        };
    }
    /// Whether a call's arguments must be evaluated into temporaries
    /// first: when binding keyword arguments reorders two that have side
    /// effects, or when an argument may leave (`!`, a `catch` that
    /// returns) after an owned value was produced, which would be lost.
    fn hoistsArgs(self: *Emitter, call: Sexp) bool {
        if (!call.isKind(.call) or self.isPrintCall(call)) return false;
        const args = ir.Call.args(call);
        if (self.sema.callSlotsOf(call)) |slots| {
            var last: ?usize = null;
            for (slots) |slot| {
                const ai = switch (slot) {
                    .arg => |a| a,
                    .default => continue,
                };
                if (self.isPureArg(argValue(args[ai]))) continue;
                if (last) |l| if (ai < l) return true;
                last = ai;
            }
        }
        const callee = ir.Call.callee(call);
        // Zig passes a temporary receiver to a `!self` method as a constant.
        if (self.receiverOf(call)) |recv| if (!isPlace(recv) and recv.kind() != .move and self.receiverWrites(call)) return true;
        var owned = (callee.isKind(.member) and ir.Member.object(callee).isKind(.move)) or self.consumedTemporary(call) != null;
        for (args) |a| {
            const v = argValue(a);
            // A `!` or `?`, or a `return`, `break`, or `continue` in a
            // `catch` handler or a branch, leaves the enclosing block.
            if (owned and contains(v, &.{ .propagate, .propagate_none, .@"return", .@"break", .@"continue" })) return true;
            if (self.isOwnedValue(v)) owned = true;
        }
        return false;
    }

    /// The receiver of `value.method(...)` when it is an owned temporary
    /// the method consumes (`mk().consume(...)`).
    fn consumedTemporary(self: *Emitter, call: Sexp) ?Sexp {
        const callee = ir.Call.callee(call);
        if (!callee.isKind(.member)) return null;
        const obj = ir.Member.object(callee);
        if (isPlace(obj) or obj.isKind(.move) or self.isTypeCallee(obj) or !self.isOwnedValue(obj)) return null;
        const f = self.fnType(self.typeOf(callee)) orelse return null;
        if (f.params.len == 0) return null;
        return switch (self.sema.types.get(f.params[0])) {
            .borrow_read, .borrow_write => null,
            else => obj,
        };
    }

    /// A value whose evaluation has no side effect and reads nothing a
    /// later argument could change: a literal, a constant, a function,
    /// or a borrow or move of a name.
    fn isPureArg(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => {
                if (isLiteralText(self.srcText(e)) or self.isNoneLeaf(e)) return true;
                const sym = self.sema.symbolOf(e) orelse return false;
                const s = self.sema.symbols.items[sym];
                return switch (s.kind) {
                    .local, .param, .capture => s.flags.fixed or s.flags.comptime_known,
                    else => true,
                };
            },
            .list => return switch (e.kind().?) {
                .enum_lit => true,
                .read, .write, .move => ir.get(e, .operand) == .src,
                .neg => ir.Neg.operand(e) == .src and isLiteralText(self.srcText(ir.Neg.operand(e))),
                else => false,
            },
            else => return false,
        }
    }

    /// An argument that hands the callee a value it must release.
    fn isOwnedValue(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.kindOf(t) != null;
    }

    /// The receiver of `value.method(...)`.
    fn receiverOf(self: *Emitter, call: Sexp) ?Sexp {
        const callee = ir.Call.callee(call);
        if (!callee.isKind(.member)) return null;
        const obj = ir.Member.object(callee);
        if (self.isTypeCallee(obj)) return null;
        return obj;
    }

    /// Whether the method of `value.method(...)` takes `!self`.
    fn receiverWrites(self: *Emitter, call: Sexp) bool {
        const f = self.fnType(self.typeOf(ir.Call.callee(call))) orelse return false;
        return f.params.len > 0 and self.sema.types.get(f.params[0]) == .borrow_write;
    }

    /// Evaluate the receiver of a method call whose arguments are hoisted
    /// into `__rig_recv_N` first, so it runs before them, as written: the
    /// address of a place, or a temporary value, dropped after the call.
    fn hoistReceiver(self: *Emitter, call: Sexp, id: u32) Error!void {
        // Borrow sigils on a receiver are implicit in Zig's method calls.
        const recv = unborrowed(self.receiverOf(call) orelse return);
        const writes = self.receiverWrites(call);
        const temporary = !isPlace(recv) and !recv.isKind(.move);
        if (!contains(recv, &.{.call}) and !(writes and temporary)) return;
        const name = try self.fmt("__rig_recv_{d}", .{id});
        try self.writeIndent(self.indent);
        if (!temporary) {
            const saved = self.read_place;
            defer self.read_place = saved;
            self.read_place = !writes;
            try self.w.print("const {s} = ", .{name});
            try self.emitAddressOf(recv);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = recv, .name = name });
        }
        const ty = self.typeOf(recv);
        const ptr = if (ty) |t| self.isPtrBorrowTy(t) else false;
        const kind: ?ResourceKind = if (ptr) null else if (ty) |t| self.kindOf(t) else null;
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional or (writes and !ptr)) "var" else "const", name });
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitBare(recv);
        try self.w.writeAll(";\n");
        if (kind) |k| {
            try self.writeIndent(self.indent);
            try self.w.writeAll("defer ");
            try self.writeDrop(name, k);
            try self.w.writeAll(";\n");
        }
        try self.hoisted.append(self.allocator, .{ .node = recv, .name = name });
    }

    /// Every argument that is not pure goes into a typed temporary, in
    /// source order, after the receiver (see `hoistReceiver`), and the
    /// call itself runs last. An owned temporary, including a receiver
    /// the method consumes, is dropped if a later argument leaves, and
    /// handed to the callee (its flag cleared) only when the call runs.
    /// `pair(mk(1)!, mk(2)!)`, with `mk` returning a `Vec(Int)`:
    ///
    ///     __rig_call_N: {
    ///         var __rig_arg_N_0: rig.Vec(i64) = try mk(1);
    ///         var __rig_live_N_0 = true;
    ///         defer if (__rig_live_N_0) rig.drop(&__rig_arg_N_0);
    ///         var __rig_arg_N_1: rig.Vec(i64) = try mk(2);
    ///         ...
    ///         break :__rig_call_N pair(rig.take(&__rig_live_N_0, __rig_arg_N_0), ...);
    ///     }
    fn emitHoistedCall(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        const params = self.callParams(call);
        const slots = self.sema.callSlotsOf(call);
        const fields = self.buildsValue(call);
        const id = self.nextId();
        try self.w.print("__rig_call_{d}: ", .{id});
        try self.openBrace();
        const first = self.hoisted.items.len;
        if (self.consumedTemporary(call)) |recv| {
            try self.hoist(.{ .node = recv, .name = try self.fmt("__rig_recv_{d}", .{id}), .flag = try self.fmt("__rig_live_{d}_recv", .{id}) }, .{}, 0, false);
        } else try self.hoistReceiver(call, id);
        for (args, 0..) |a, ai| {
            const value = argValue(a);
            if (self.isPureArg(value)) continue;
            const slot: usize = if (slots) |ss| for (ss, 0..) |s, i| {
                if (s == .arg and s.arg == ai) break i;
            } else ai else ai;
            try self.hoist(.{ .node = value, .name = try self.fmt("__rig_arg_{d}_{d}", .{ id, ai }), .flag = try self.fmt("__rig_live_{d}_{d}", .{ id, ai }) }, params, slot, fields);
        }
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_call_{d} ", .{id});
        try self.emitCallDirect(call);
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.writeAll(";\n");
        try self.closeBrace();
    }

    /// Evaluate `h.node`, the argument for parameter slot `slot` (or a
    /// field value when the call `fields` builds a value), into the
    /// temporary `h.name`. One that owns a resource is dropped at the end
    /// of the call's block unless the call takes it, clearing `h.flag`.
    fn hoist(self: *Emitter, h: Hoisted, params: CallParams, slot: usize, fields: bool) Error!void {
        const ty = self.typeOf(h.node);
        const ptr = slot < params.tys.len and self.isPtrBorrowTy(params.tys[slot]);
        const kind: ?ResourceKind = if (ptr) null else if (ty) |t| self.kindOf(t) else null;
        try self.writeIndent(self.indent);
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional) "var" else "const", h.name });
        // The value alone may have no Zig type (`.empty`, `null`, a literal).
        if (ty) |t| if (!ptr) {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        };
        try self.w.writeAll(" = ");
        if (fields) try self.emitStored(h.node) else try self.emitArg(h.node, params, slot);
        try self.w.writeAll(";\n");
        const k = kind orelse return self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
        try self.line("var {s} = true;", .{h.flag});
        try self.writeIndent(self.indent);
        try self.w.print("defer if ({s}) ", .{h.flag});
        try self.writeDrop(h.name, k);
        try self.w.writeAll(";\n");
        try self.hoisted.append(self.allocator, h);
    }

    /// The temporary an argument or receiver was evaluated into, if it was.
    fn hoistedOf(self: *Emitter, e: Sexp) ?Hoisted {
        var i = self.hoisted.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.hoisted.items[i];
            if (sameNode(h.node, e)) return h;
        }
        return null;
    }

    /// A call whose arguments become the fields of the value it builds:
    /// a constructor or a variant.
    fn buildsValue(self: *Emitter, call: Sexp) bool {
        const callee = ir.Call.callee(call);
        if (callee.isKind(.enum_lit)) return true;
        if (callee.isKind(.member)) return self.sema.typeOf(callee) == null;
        return self.isConstructorCall(call);
    }

    /// A call `emitCall` lowers with `emitConstructor`, whose Zig spells
    /// the value's type.
    fn isConstructorCall(self: *Emitter, e: Sexp) bool {
        if (!e.isKind(.call) or ir.Call.callee(e) != .src) return false;
        if (self.localOf(ir.Call.callee(e))) |local| if (local.stack_closure) return false;
        const sym_id = self.sema.symbolOf(ir.Call.callee(e)) orelse return false;
        return sym_id != self.sema.vec_sym_id and sym_id != self.sema.signal_sym_id and self.isTypeSym(sym_id);
    }

    /// Constructor call `Name(field: v, ...)`: a struct literal typed by
    /// sema (a generic type's arguments come from the call's type).
    fn emitConstructor(self: *Emitter, call: Sexp, sym_id: SymbolId) Error!void {
        if (self.sema.symbols.items[sym_id].kind == .generic_type) {
            const ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped generic constructor");
            try self.emitTypeTy(ty);
        } else {
            try self.writeNominalName(sym_id);
        }
        try self.emitFieldInit(ir.Call.args(call));
    }

    /// `{ .a = x, ... }` from keyword arguments.
    fn emitFieldInit(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".{f} = ", .{ident(self.srcText(ir.Kwarg.name(a)))});
            try self.emitStored(ir.Kwarg.value(a));
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// `Vec()` / `Vec(capacity: n)`: a decl literal typed by its result
    /// location.
    fn emitVecConstruction(self: *Emitter, args: []const Sexp) Error!void {
        if (args.len == 1) {
            try self.w.writeAll(".initCapacity(");
            try self.emitBare(ir.Kwarg.value(args[0]));
            return self.w.writeAll(")");
        }
        try self.w.writeAll(".empty");
    }

    /// `Signal(value: v)`.
    fn emitSignalConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        if (args.len != 1) return self.unsupported(call, "this Signal construction");
        try self.w.writeAll(".init(");
        try self.emitBare(ir.Kwarg.value(args[0]));
        try self.w.writeAll(")");
    }

    /// `.variant(args)` → `.{ .variant = payload }`. A single-field
    /// payload is the value itself; several fields form a struct.
    fn emitVariantLit(self: *Emitter, call: Sexp) Error!void {
        const vname = self.srcText(ir.EnumLit.name(ir.Call.callee(call)));
        if (ir.Call.args(call).len == 0) return self.w.print(".{f}", .{ident(vname)});
        const enum_ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped variant");
        return self.emitVariantPayload(call, enum_ty, vname);
    }

    fn emitVariantPayload(self: *Emitter, call: Sexp, enum_ty: TypeId, vname: []const u8) Error!void {
        const args = ir.Call.args(call);
        const fields = self.variantPayload(enum_ty, vname) orelse return self.unsupported(call, "this variant");
        try self.w.print(".{{ .{f} = ", .{ident(vname)});
        if (fields.len == 1) {
            try self.emitStored(argValue(args[0]));
        } else {
            try self.w.writeAll(".{");
            for (args, 0..) |a, i| {
                try self.w.writeAll(if (i == 0) " " else ", ");
                const fname = if (a.isKind(.kwarg)) self.srcText(ir.Kwarg.name(a)) else fields[i].name;
                try self.w.print(".{f} = ", .{ident(fname)});
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
        node: Sexp,
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
        for (sema.captureList(captures)) |cap| {
            const name_node = sema.captureNameNode(cap).?;
            const sym = self.sema.symbolOf(name_node) orelse return self.unsupported(cap, "an unresolved capture");
            const s = self.sema.symbols.items[sym];
            const outer: ?Local = if (self.localBySym(s.origin)) |l| l.* else null;
            try out.append(self.arena.allocator(), .{ .node = cap, .mode = cap.kind().?, .sym = sym, .name = s.name, .ty = s.ty, .outer = outer });
        }
        return out.items;
    }

    /// `f = |captures| body` → a struct holding the captures with an
    /// `invoke` method; calls lower to `f.invoke(...)`. When a capture
    /// owns a resource, the closure is dropped at scope exit, which drops
    /// its fields.
    fn emitClosureBinding(self: *Emitter, name_node: Sexp, sym: SymbolId, lambda: Sexp) Error!void {
        var local: Local = .{ .sym = sym, .stack_closure = true };
        for (try self.captureInfo(ir.Lambda.captures(lambda))) |c| {
            if (self.kindOf(c.ty) != null) local.kind = .value;
        }
        if (local.kind != null) local.guard = self.resourceGuard(sym);
        const stored = try self.declare(local, self.srcText(name_node));
        _ = try self.emitStackClosure(stored.zig_name, lambda);
        if (stored.guard != .none) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitGuard(stored);
        } else {
            try self.w.print(" _ = &{s};", .{stored.zig_name});
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

        try self.w.writeAll("struct ");
        try self.openBrace();
        const env = if (self.closure_depth == 0) "__rig_self" else try self.fmt("__rig_self{d}", .{self.closure_depth});
        var uses_env = false;
        for (caps) |c| {
            try self.writeIndent(self.indent);
            try self.w.print("cap_{s}: ", .{c.name});
            try self.emitTypeTy(c.ty);
            try self.w.writeAll(",\n");
            uses_env = uses_env or self.usage.used.contains(c.sym);
            // Inside the body, a capture is a field of the environment.
            _ = try self.declare(.{ .sym = c.sym, .zig_name = try self.fmt("{s}.cap_{s}", .{ env, c.name }), .ty = c.ty }, c.name);
        }
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.print("pub fn invoke({s}: *@This()", .{env});
        self.closure_depth += 1;
        defer self.closure_depth -= 1;
        const saved_fun = self.fun;
        defer self.fun = saved_fun;
        self.fun = .{ .return_ty = ret, .params = params, .unused_env = if (uses_env) "" else env };
        try self.bindParams(params);
        for (params.items()) |p| {
            try self.w.writeAll(", ");
            try self.emitParam(p);
        }
        try self.w.writeAll(") ");
        if (ret) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        const body = ir.Lambda.body(lambda);
        if (ret != null) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// `{ .cap_x = init, ... }` evaluated where the closure is created.
    fn emitCaptureInit(self: *Emitter, caps: []const Capture) Error!void {
        if (caps.len == 0) return self.w.writeAll("{}");
        try self.w.writeAll("{");
        for (caps, 0..) |c, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".cap_{s} = ", .{c.name});
            const outer = c.outer orelse return self.unsupported(c.node, "a capture of a name that is not a local");
            switch (c.mode) {
                .cap_clone => {
                    try self.writeLocalPlace(&outer);
                    // A borrowed handle clones the handle it borrows.
                    const kind = if (outer.kind) |k| k else if (outer.ty) |t| self.kindOf(self.peelBorrows(t)) else null;
                    if (kind) |k| switch (k) {
                        .shared => try self.w.writeAll(".cloneStrong()"),
                        .weak => try self.w.writeAll(".cloneWeak()"),
                        else => {},
                    };
                },
                .cap_weak => {
                    try self.writeLocalPlace(&outer);
                    try self.w.writeAll(".weakRef()");
                },
                .cap_move => if (outer.is_ptr and self.isPtrBorrowTy(c.ty)) {
                    // A moved pointer borrow moves the pointer.
                    try self.w.writeAll(outer.zig_name);
                } else try self.writeTake(&outer),
                else => try self.writeLocalPlace(&outer),
            }
        }
        try self.w.writeAll(" }");
    }

    /// `*|captures, params| body` → a heap-allocated environment, erased
    /// into the runtime closure and boxed:
    ///
    ///     __rig_closure_N: {
    ///         const __rig_Env_N = struct { cap_x: T, pub fn invoke(...) R { ... } };
    ///         const __rig_env_N = rig.create(__rig_Env_N);
    ///         __rig_env_N.* = .{ .cap_x = ... };
    ///         break :__rig_closure_N rig.rcNew(rig.Closure(&.{ A }, R).init(__rig_Env_N, __rig_env_N));
    ///     }
    ///
    /// The environment is freed when the last strong handle drops.
    fn emitOwnedClosure(self: *Emitter, lambda: Sexp) Error!void {
        const f = self.fnType(self.typeOf(lambda)) orelse return self.unsupported(lambda, "an untyped closure");
        const caps = try self.captureInfo(ir.Lambda.captures(lambda));
        const id = self.nextId();
        const env = try self.fmt("__rig_Env_{d}", .{id});
        const env_ptr = try self.fmt("__rig_env_{d}", .{id});

        try self.w.print("__rig_closure_{d}: ", .{id});
        try self.openBrace();
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
        try self.w.print("break :__rig_closure_{d} rig.rcNew(", .{id});
        try self.emitClosureTy(f);
        try self.w.print(".init({s}, {s}));\n", .{ env, env_ptr });
        try self.closeBrace();
    }

    /// The runtime closure behind `*fun(A, B) R`: `rig.Closure(&.{ A, B }, R)`.
    fn emitClosureTy(self: *Emitter, f: sema.FunctionType) Error!void {
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

    /// A type sema resolved.
    fn emitTypeTy(self: *Emitter, ty: TypeId) Error!void {
        const ctx = self.sema;
        switch (ctx.types.get(ty)) {
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
            // Rig functions do not declare their errors.
            .fallible => |inner| {
                try self.w.writeAll("anyerror!");
                try self.emitTypeTy(inner);
            },
            .borrow_read => |inner| {
                if (self.genericReadBorrow(ty) != null) {
                    try self.w.writeAll("rig.ReadBorrow(");
                    try self.emitTypeTy(inner);
                    return self.w.writeAll(")");
                }
                if (self.readBorrowIsPtr(inner)) try self.w.writeAll("*const ");
                try self.emitTypeTy(inner);
            },
            .borrow_write => |inner| {
                try self.w.writeAll("*");
                try self.emitTypeTy(inner);
            },
            .shared, .weak => |inner| {
                try self.w.writeAll(if (ctx.types.get(ty) == .shared) "*rig.RcBox(" else "rig.WeakHandle(");
                switch (ctx.types.get(inner)) {
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
            .nominal => |sym_id| try self.writeNominalName(sym_id),
            .imported_nominal => |in| {
                const foreign = ctx.foreign_semas.get(in.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
                const type_name = foreign.symbols.items[in.sym_id].name;
                for (ctx.imports) |imp| {
                    if (imp.module_id == in.module_id) {
                        try self.writeModuleName(imp.local_name);
                        return self.w.print(".{f}", .{ident(type_name)});
                    }
                }
                // A module reached only through an import.
                return self.w.print("@import(\"{s}.zig\").{f}", .{ foreign.name, ident(type_name) });
            },
            .parameterized_nominal => |pn| {
                if (self.isSelfInstance(pn)) return self.w.writeAll("Self");
                try self.writeNominalName(pn.sym);
                try self.w.writeAll("(");
                try self.emitTypeList(pn.args);
                try self.w.writeAll(")");
            },
            .type_var => |sym_id| try self.w.print("{f}", .{ident(ctx.symbols.items[sym_id].name)}),
            .function => |f| {
                try self.w.writeAll("*const fn (");
                try self.emitTypeList(f.params);
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
            },
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// `A, B, C`.
    fn emitTypeList(self: *Emitter, tys: []const TypeId) Error!void {
        for (tys, 0..) |t, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitTypeTy(t);
        }
    }

    /// A user nominal, or a runtime one (`Vec` → `rig.Vec`).
    fn writeNominalName(self: *Emitter, sym: SymbolId) Error!void {
        const name = self.sema.symbols.items[sym].name;
        if (sym == self.sema.vec_sym_id or sym == self.sema.cell_sym_id or sym == self.sema.signal_sym_id) {
            return self.w.print("rig.{s}", .{name});
        }
        try self.writeModuleName(name);
    }

    /// The generic type being emitted, applied to its own parameters:
    /// `Self` inside its body.
    fn isSelfInstance(self: *Emitter, pn: sema.ParamNominal) bool {
        const n = self.nominal orelse return false;
        if (pn.sym != n.sym) return false;
        const params = self.sema.symbols.items[n.sym].type_params orelse return false;
        if (params.len != pn.args.len) return false;
        for (params, pn.args) |p, a| switch (self.sema.types.get(a)) {
            .type_var => |v| if (v != p) return false,
            else => return false,
        };
        return true;
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

    fn fnType(self: *Emitter, ty: ?TypeId) ?sema.FunctionType {
        const t = ty orelse return null;
        return switch (self.sema.types.get(t)) {
            .function => |f| f,
            else => null,
        };
    }

    fn peelBorrows(self: *Emitter, ty: TypeId) TypeId {
        return sema.unwrapBorrows(self.sema, ty);
    }

    /// The payload fields of variant `vname` of an enum type.
    fn variantPayload(self: *Emitter, enum_ty: TypeId, vname: []const u8) ?[]const sema.Field {
        const decl = sema.nominalDecl(self.sema, enum_ty) orelse return null;
        for (decl.symbol().fields orelse return null) |f| {
            if (f.is_variant and std.mem.eql(u8, f.name, vname)) return f.payload orelse &.{};
        }
        return null;
    }

    /// How a value of this type is released, or null for plain data.
    /// Sema decides whether it owns anything (`typeHasDropGlue`, or
    /// `maybeDropGlue` for values of a type parameter, which `rig.drop`
    /// releases only if the instance needs it); this only picks the call.
    fn kindOf(self: *Emitter, ty: TypeId) ?ResourceKind {
        if (!sema.typeHasDropGlue(self.sema, ty) and !sema.maybeDropGlue(self.sema, ty)) return null;
        return switch (self.sema.types.get(ty)) {
            .shared => .shared,
            .weak => .weak,
            .optional => .optional,
            else => .value,
        };
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

    /// Numbers, Bool, String, functions, and optionals of them: bindings
    /// of these types are annotated, since a literal or branch value alone
    /// has no runtime type, and a function name alone is a function body,
    /// not a pointer to one.
    fn isPlainTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.sema.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string, .function => true,
            .optional => |inner| self.isPlainTy(inner),
            else => false,
        };
    }

    /// An error set (local or imported) or any error: its members are
    /// spelled `error.name`.
    fn isErrorSetTy(self: *Emitter, ty: TypeId) bool {
        const t = self.peelBorrows(ty);
        return self.sema.types.get(t) == .any_error or sema.isErrorSet(self.sema, t);
    }

    /// The type of a float-typed expression (a `Float` literal is a `Float`).
    fn floatTypeOf(self: *Emitter, e: Sexp) ?TypeId {
        const ty = self.typeOf(e) orelse return null;
        return switch (self.sema.types.get(ty)) {
            .float => ty,
            .float_literal => self.sema.types.float_id,
            else => null,
        };
    }

    /// The error set of an operand of type `E?`.
    fn optionalErrorOf(self: *Emitter, e: Sexp) ?TypeId {
        const ty = self.typeOf(e) orelse return null;
        return switch (self.sema.types.get(self.peelBorrows(ty))) {
            .optional => |inner| if (self.isErrorSetTy(inner)) inner else null,
            else => null,
        };
    }

    /// A `String` or `String?` operand.
    fn isStringExpr(self: *Emitter, expr: Sexp) bool {
        const ty = self.typeOf(expr) orelse return false;
        return self.sema.types.get(self.peelBorrows(ty)) == .string or self.isOptStringExpr(expr);
    }

    fn isOptStringExpr(self: *Emitter, expr: Sexp) bool {
        const ty = self.typeOf(expr) orelse return false;
        const t = self.sema.types.get(self.peelBorrows(ty));
        return t == .optional and self.sema.types.get(t.optional) == .string;
    }

    /// The builtin `left op right` lowers to for `/` and `%`, or null for
    /// float `/`, which is ordinary division. Integer `/` truncates toward
    /// zero (`@divTrunc`), and a type parameter's values divide as their
    /// instance does (`rig.div`). `%` is the remainder with the dividend's
    /// sign (`@rem`), for integers and floats alike.
    fn divBuiltin(self: *Emitter, op: Tag, left: Sexp, right: Sexp) ?[]const u8 {
        if (op == .@"%") return "@rem";
        if (self.float_literals != null) return null;
        var builtin: []const u8 = "@divTrunc";
        for ([2]Sexp{ left, right }) |e| {
            const ty = self.typeOf(e) orelse continue;
            switch (self.sema.types.get(self.peelBorrows(ty))) {
                .float, .float_literal => return null,
                .type_var => builtin = "rig.div",
                else => {},
            }
        }
        return builtin;
    }

    // =========================================================================
    // Output helpers
    // =========================================================================

    fn srcText(self: *Emitter, sexp: Sexp) []const u8 {
        return self.source[sexp.src.pos..][0..sexp.src.len];
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
        const lc = diag.lineCol(self.source, self.sema.startOf(if (node == .nil) self.stmt else node));
        std.debug.print("{d}:{d}: internal error: cannot emit {s} (sema should have rejected it)\n", .{ lc.line, lc.col, what });
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

    /// The names a value moves out of their bindings when it leaves its
    /// scope: a bare name in tail position, through blocks and branches
    /// (the positions `emitValue` is given `tail` for).
    fn consumeTail(s: *Scan, value: Sexp) Error!void {
        if (value == .src) return s.consume(value);
        switch (value.kind() orelse return) {
            .block, .raw_block => {
                const stmts = try s.e.stmtsOf(if (value.isKind(.raw_block)) ir.RawBlock.body(value) else value);
                if (stmts.len > 0) try s.consumeTail(stmts[stmts.len - 1]);
            },
            .@"if" => {
                try s.consumeTail(ir.If.then(value));
                try s.consumeTail(ir.If.@"else"(value));
            },
            .match => for (ir.Match.arms(value)) |arm| try s.consumeTail(ir.Arm.body(arm)),
            .@"??" => try s.consumeTail(ir.@"??".right(value)),
            .@"catch" => try s.consumeTail(ir.Catch.handler(value)),
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
            .set => if (rig.bindingKindOf(ir.Set.op(sexp)) == .move) try s.consume(ir.Set.value(sexp)),
            .move => try s.consume(ir.Move.operand(sexp)),
            .drop => {
                // Dropping plain data or a borrow emits nothing: not a use.
                const name = ir.Drop.name(sexp);
                try s.consume(name);
                const sym = s.e.sema.symbolOf(name) orelse return;
                const ty = s.e.symType(sym) orelse return;
                if (s.e.kindOf(ty) != null) try s.put(&s.e.usage.used, sym);
                return;
            },
            .@"return" => try s.consumeTail(ir.Return.value(sexp)),
            .@"for" => if (ir.For.mode(sexp).tag == .move) try s.consume(ir.For.source(sexp)),
            // An `if` with `else`, a `match`, `??`, and `catch` may be
            // values: their branches yield.
            .@"if" => if (ir.If.@"else"(sexp) != .nil) try s.consumeTail(sexp),
            .@"??", .@"catch" => try s.consumeTail(sexp),
            .match => {
                const scrut = unborrowed(ir.Match.subject(sexp));
                const scrut_sym = if (scrut == .src) s.e.sema.symbolOf(scrut) else null;
                for (ir.Match.arms(sexp)) |arm| {
                    const pattern = ir.Arm.pattern(arm);
                    const binds: []const Sexp = if (pattern.isKind(.variant_pattern)) ir.VariantPattern.bindings(pattern) else (&pattern)[0..1];
                    if (scrut_sym) |ss| for (binds) |b| {
                        if (s.e.sema.symbolOf(b)) |bs| try s.e.usage.views.put(s.e.allocator, bs, ss);
                    };
                }
                try s.consumeTail(sexp);
            },
            .cap_clone, .cap_weak, .cap_move => {
                const cap = s.e.sema.symbolOf(ir.get(sexp, .name)) orelse return;
                const origin = s.e.sema.symbols.items[cap].origin;
                try s.put(&s.e.usage.used, origin);
                if (head == .cap_move) {
                    try s.put(&s.e.usage.consumed, origin);
                }
                return;
            },
            .fun => if (ir.Fun.returns(sexp) != .nil) try s.consumeTail(ir.Fun.body(sexp)),
            .lambda => if (s.e.lambdaReturn(sexp) != null) try s.consumeTail(ir.Lambda.body(sexp)),
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

fn ident(name: []const u8) Ident {
    return .{ .name = name };
}

/// A default argument value: a literal, written from the source of the
/// module that declares it.
fn writeLiteral(w: *Writer, source: []const u8, e: Sexp) Error!void {
    switch (e) {
        .src => |s| {
            const t = source[s.pos..][0..s.len];
            if (std.mem.eql(u8, t, "none")) return w.writeAll("null");
            if (t[0] == '\'') return writeSingleQuoted(w, t);
            // Zig has no `.5`.
            if (t[0] == '.') try w.writeAll("0");
            try w.writeAll(t);
        },
        // `-1`, `.red`: the sign or dot, then the literal.
        .list => {
            try w.writeAll(if (e.isKind(.neg)) "-" else ".");
            try writeLiteral(w, source, ir.get(e, if (e.isKind(.neg)) .operand else .name));
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
                .call => {
                    // A constructor or variant of constant arguments is
                    // constant; a function call is not.
                    const callee = ir.Call.callee(e);
                    const ctor = callee.isKind(.enum_lit) or (callee == .src and if (em.sema.symbolOf(callee)) |id| em.isTypeSym(id) else false);
                    if (!ctor) return false;
                    for (ir.Call.args(e)) |a| if (!isZigComptimeIn(em, argValue(a), depth + 1)) return false;
                    return true;
                },
                .share, .clone, .weak, .move, .read, .write, .lambda, .propagate, .propagate_none, .@"catch" => return false,
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
    if (!sema.isIntLiteralText(t)) return false;
    const v = std.fmt.parseInt(i128, t, 0) catch return false;
    return v == 0;
}

/// Literal source text: numbers, quoted strings, and the value keywords.
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

/// `e` without the borrow sigils around it.
fn unborrowed(e: Sexp) Sexp {
    var x = e;
    while (x.isKind(.read) or x.isKind(.write)) x = ir.get(x, .operand);
    return x;
}

/// Storage with an owner: a name, a field or element, or a borrow of one.
fn isPlace(e: Sexp) bool {
    const h = e.kind() orelse return e == .src;
    return h == .member or h == .index or h == .read or h == .write;
}

/// The value of a call argument: a `(kwarg name value)` stands for its value.
fn argValue(a: Sexp) Sexp {
    return if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
}

/// Whether `e` holds a node of one of `kinds`, outside the closures in it.
fn contains(e: Sexp, kinds: []const Tag) bool {
    if (e != .list) return false;
    if (e.kind()) |h| {
        if (h == .lambda) return false;
        if (std.mem.indexOfScalar(Tag, kinds, h) != null) return true;
    }
    for (e.items()) |c| if (contains(c, kinds)) return true;
    return false;
}

/// The same IR node: the same leaf, or the same list.
fn sameNode(a: Sexp, b: Sexp) bool {
    return switch (a) {
        .src => |s| b == .src and b.src.pos == s.pos,
        .list => b == .list and a.items().ptr == b.items().ptr,
        else => false,
    };
}

/// Statements that produce a value (and can end a value block).
fn isValueStmt(s: Sexp) bool {
    const h = s.kind() orelse return true;
    return switch (h) {
        .set, .drop, .@"return", .@"break", .@"continue", .@"defer", .@"errdefer", .block, .@"while", .@"for", .labeled => false,
        .@"if" => ir.If.@"else"(s) != .nil,
        else => true,
    };
}

fn isTerminatingStmt(s: Sexp) bool {
    const h = s.kind() orelse return false;
    return h == .@"return" or h == .@"break" or h == .@"continue";
}
