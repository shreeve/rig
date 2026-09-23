//! Zig code generation.
//!
//! Lowers the semantic IR (`docs/IR.md`) of one checked module to Zig
//! 0.16 source. The program has already passed sema, effects, and
//! ownership checking; this pass only chooses a representation:
//!
//! - A binding is `const` unless it is reassigned, write-borrowed,
//!   field-assigned, or has a type whose methods take `*Self`.
//! - A resource binding (`*T`, `~T`, a value with drop glue, or an
//!   optional of one) is dropped at scope exit by a `defer`. When the
//!   function may move, drop, or return the binding, the defer tests a
//!   `__rig_alive_<name>` flag, and the consuming site clears it.
//! - `!T` parameters, `!self` receivers, and borrow bindings are
//!   pointers; reads go through `.*`.
//! - A Rig name that is a Zig keyword or would shadow another visible
//!   Zig name is renamed.
//!
//! Names resolve through the emitter's scope stack, which mirrors Rig's
//! block scoping and records each binding's sema type, so auto-deref,
//! print formats, and drop decisions follow the binding actually in
//! scope. Anything the emitter cannot lower is an internal error: sema
//! must reject it first.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const Writer = std.Io.Writer;

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

const Callable = enum { none, stack_closure, owned_closure };

/// A sema type, plus the generic substitution in effect where it was
/// found (a field of `Box(Int)` is `T` under `T := Int`).
const Ty = struct {
    id: types.TypeId,
    subst: types.TypeSubst = .empty,
};

const Local = struct {
    rig_name: []const u8,
    /// The Zig spelling: a renamed or escaped identifier, or a path such
    /// as `self.cap_x` for a closure capture.
    zig_name: []const u8,
    ty: ?Ty = null,
    kind: ?ResourceKind = null,
    guard: Guard = .none,
    /// `zig_name` holds a pointer to the Rig value.
    is_ptr: bool = false,
    callable: Callable = .none,
    /// Return type of a stack closure.
    ret: ?Ty = null,
    /// Name of the alive flag when `guard == .flag`.
    flag: []const u8 = "",
};

const Scope = struct {
    locals: std.ArrayListUnmanaged(Local) = .empty,
};

/// Declarations visible across the whole module.
const ModuleInfo = struct {
    /// Every module-level Zig name, which locals must not shadow.
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Parameter lists of top-level functions, for keyword arguments.
    funs: std.StringHashMapUnmanaged(Sexp) = .empty,
    /// Parameter lists of methods, keyed `Type.method`.
    methods: std.StringHashMapUnmanaged(Sexp) = .empty,
    /// Names of `error` sets, whose members are spelled `error.x`.
    error_sets: std.StringHashMapUnmanaged(void) = .empty,
};

/// State for the function whose body is being emitted.
const FunState = struct {
    /// Declaration positions of bindings that need Zig `var`.
    mutated: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Names the function may move, drop, or return. A resource binding
    /// with one of these names needs an alive flag.
    consumed: std.StringHashMapUnmanaged(void) = .empty,
    /// Declared return type, for error-set literals.
    returns: ?Sexp = null,
    return_ty: ?Ty = null,
    /// Parameters to bind at the top of the body.
    params: ?Sexp = null,
    leak_check: bool = false,
};

const Nominal = struct {
    /// How `Self` is spelled: the type name, or `Self` inside a generic.
    name: []const u8,
    members: []const Sexp,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    w: *Writer,
    indent: u32 = 0,
    /// Generated names and other emit-lifetime allocations.
    arena: std.heap.ArenaAllocator,
    sema: ?*const types.SemContext = null,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Suffix source for generated labels, temporaries, and renames.
    counter: u32 = 0,
    module: ModuleInfo = .{},
    fun: FunState = .{},
    nominal: ?Nominal = null,
    /// Statements after the one being emitted in the current block;
    /// decides whether a new binding needs `_ = x;`.
    rest: []const Sexp = &.{},
    /// The next expression sits in a delimited position (after `=`,
    /// between commas, inside parentheses) and needs no outer parentheses.
    bare: bool = false,
    /// Type expected for the expression being emitted, when known
    /// (binding annotation, parameter, field, or return type).
    expected: ?Ty = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, w: *Writer, sema: *const types.SemContext) Emitter {
        var e = init(allocator, source, w);
        e.sema = sema;
        return e;
    }

    pub fn deinit(self: *Emitter) void {
        for (self.scopes.items) |*s| s.locals.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.module.names.deinit(self.allocator);
        self.module.funs.deinit(self.allocator);
        self.module.methods.deinit(self.allocator);
        self.module.error_sets.deinit(self.allocator);
        self.fun.mutated.deinit(self.allocator);
        self.fun.consumed.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        try self.w.writeAll("const rig = @import(\"_runtime.zig\");\n");
        if (!isTagged(sexp, .@"module")) return;
        const decls = sexp.list[1..];
        try self.collectModule(decls);
        for (decls) |decl| {
            try self.w.writeAll("\n");
            try self.emitDecl(decl);
        }
    }

    // =========================================================================
    // Module-level declarations
    // =========================================================================

    fn collectModule(self: *Emitter, decls: []const Sexp) Error!void {
        const a = self.allocator;
        try self.module.names.put(a, "std", {});
        try self.module.names.put(a, "rig", {});
        for (decls) |d0| {
            const d = unwrapPub(d0);
            if (d != .list or d.list.len < 2 or d.list[0] != .tag) continue;
            const items = d.list;
            switch (items[0].tag) {
                .@"fun", .@"sub", .@"extern_fun", .@"extern_sub" => {
                    const name = self.text(items[1]) orelse continue;
                    try self.module.names.put(a, name, {});
                    if (items.len >= 3) try self.module.funs.put(a, name, items[2]);
                },
                .@"extern" => if (items.len >= 3) {
                    if (self.text(items[2])) |name| try self.module.names.put(a, name, {});
                },
                .@"use", .@"type", .@"opaque" => {
                    if (self.text(items[1])) |name| try self.module.names.put(a, name, {});
                },
                .@"struct", .@"enum", .@"errors", .@"generic_type", .@"generic_enum" => {
                    const name = self.text(items[1]) orelse continue;
                    try self.module.names.put(a, name, {});
                    if (items[0].tag == .@"errors") try self.module.error_sets.put(a, name, {});
                    for (items[2..]) |m| {
                        if (!isTagged(m, .@"fun") and !isTagged(m, .@"sub")) continue;
                        if (m.list.len < 3) continue;
                        const mname = self.text(m.list[1]) orelse continue;
                        const key = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ name, mname });
                        try self.module.methods.put(a, key, m.list[2]);
                    }
                },
                .@"set" => if (items.len >= 3) {
                    if (self.text(items[2])) |name| try self.module.names.put(a, name, {});
                },
                else => {},
            }
        }
    }

    fn emitDecl(self: *Emitter, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return self.unsupported(sexp, "this top-level form");
        const items = sexp.list;
        switch (items[0].tag) {
            // Every declaration is emitted `pub`, so `pub` adds nothing.
            .@"pub" => if (items.len >= 2) try self.emitDecl(items[1]),
            .@"fun" => try self.emitFun(items, false),
            .@"sub" => try self.emitFun(items, true),
            .@"extern_fun" => try self.emitExternFun(items, false),
            .@"extern_sub" => try self.emitExternFun(items, true),
            .@"extern" => try self.emitExternDecl(sexp),
            .@"use" => try self.emitUse(items),
            .@"struct" => try self.emitStruct(items),
            .@"enum" => try self.emitEnum(items),
            .@"errors" => try self.emitErrorSet(items),
            .@"generic_type" => try self.emitGenericType(items),
            .@"generic_enum" => try self.emitGenericEnum(items),
            .@"type" => try self.emitTypeAlias(items),
            .@"opaque" => {
                const name = self.text(items[1]) orelse return self.unsupported(sexp, "this opaque declaration");
                try self.w.print("pub const {f} = opaque {{}};\n", .{self.ident(name)});
            },
            .@"test" => try self.emitTest(items),
            .@"set" => try self.emitModuleConst(sexp),
            else => return self.unsupported(sexp, "this top-level form"),
        }
    }

    fn emitUse(self: *Emitter, items: []const Sexp) Error!void {
        const name = self.text(items[1]) orelse return;
        if (std.mem.eql(u8, name, "std")) return;
        try self.w.print("const {f} = @import(\"{s}.zig\");\n", .{ self.ident(name), name });
    }

    /// `(extern_fun name params returns)` / `(extern_sub name params)`.
    fn emitExternFun(self: *Emitter, items: []const Sexp, is_sub: bool) Error!void {
        const name = self.text(items[1]) orelse return;
        try self.w.print("extern fn {f}(", .{self.ident(name)});
        if (items.len >= 3) try self.emitParamList(items[2]);
        try self.w.writeAll(") ");
        if (!is_sub and items.len >= 4 and items[3] != .nil) try self.emitType(items[3]) else try self.w.writeAll("void");
        try self.w.writeAll(";\n");
    }

    /// `(extern kind name type)`: an extern function given by a function
    /// type, or an extern variable.
    fn emitExternDecl(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len < 4) return self.unsupported(sexp, "this extern declaration");
        const name = self.text(items[2]) orelse return self.unsupported(sexp, "this extern declaration");
        const ty = items[3];
        if (isTagged(ty, .@"fun_type")) {
            try self.w.print("extern fn {f}(", .{self.ident(name)});
            if (ty.list[1] == .list) {
                for (ty.list[1].list, 0..) |p, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.emitType(p);
                }
            }
            try self.w.writeAll(") ");
            if (ty.list.len >= 3 and ty.list[2] != .nil) try self.emitType(ty.list[2]) else try self.w.writeAll("void");
            try self.w.writeAll(";\n");
            return;
        }
        const kw: []const u8 = if (items[1] == .tag and items[1].tag == .fixed) "const" else "var";
        try self.w.print("extern {s} {f}: ", .{ kw, self.ident(name) });
        try self.emitType(ty);
        try self.w.writeAll(";\n");
    }

    fn emitTypeAlias(self: *Emitter, items: []const Sexp) Error!void {
        const name = self.text(items[1]) orelse return;
        try self.w.print("pub const {f} = ", .{self.ident(name)});
        try self.emitType(items[2]);
        try self.w.writeAll(";\n");
    }

    fn emitTest(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 3) return;
        try self.w.writeAll("test ");
        try self.emitExpr(items[1]);
        try self.w.writeAll(" ");
        self.resetFun();
        try self.scanFunction(null, items[2], false);
        try self.emitBlock(items[2]);
        try self.w.writeAll("\n");
    }

    /// A module-level binding: `pub const name = expr;`.
    fn emitModuleConst(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len < 5) return;
        const name = self.text(items[2]) orelse return self.unsupported(sexp, "this module-level binding");
        try self.w.print("pub const {f}", .{self.ident(name)});
        if (items[3] != .nil) {
            try self.w.writeAll(": ");
            try self.emitType(items[3]);
        }
        try self.w.writeAll(" = ");
        try self.emitExpr(items[4]);
        try self.w.writeAll(";\n");
    }

    // -------------------------------------------------------------------------
    // Nominal types
    // -------------------------------------------------------------------------

    /// `(struct Name (: field type)... methods...)`.
    fn emitStruct(self: *Emitter, items: []const Sexp) Error!void {
        const name = self.text(items[1]) orelse return;
        const members = items[2..];
        try self.w.print("pub const {f} = struct {{\n", .{self.ident(name)});
        const prev = self.enterNominal(name, members);
        defer self.nominal = prev;
        try self.emitFields(members, 1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_type Name (T...) members...)` → a type-returning function.
    fn emitGenericType(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 3) return;
        const name = self.text(items[1]) orelse return;
        const members = items[3..];
        try self.w.print("pub fn {f}(", .{self.ident(name)});
        try self.emitTypeParams(items[2]);
        try self.w.writeAll(") type {\n    return struct {\n        const Self = @This();\n\n");
        const prev = self.enterNominal("Self", members);
        defer self.nominal = prev;
        try self.emitFields(members, 2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(enum Name variants... methods...)`: a Zig enum, an enum with
    /// explicit values, or a tagged union when any variant has a payload.
    fn emitEnum(self: *Emitter, items: []const Sexp) Error!void {
        const name = self.text(items[1]) orelse return;
        const members = items[2..];
        const prev = self.enterNominal(name, members);
        defer self.nominal = prev;

        var has_values = false;
        var has_payloads = false;
        for (members) |m| {
            if (isTagged(m, .@"valued")) has_values = true;
            if (isTagged(m, .@"variant")) has_payloads = true;
        }
        if (has_payloads) {
            try self.w.print("pub const {f} = union(enum) {{\n", .{self.ident(name)});
            try self.emitUnionVariants(members, 1);
        } else {
            try self.w.print("pub const {f} = enum{s} {{\n", .{ self.ident(name), if (has_values) "(u32)" else "" });
            for (members) |m| switch (m) {
                .src => try self.w.print("    {f},\n", .{self.ident(self.srcText(m))}),
                .list => if (isTagged(m, .@"valued") and m.list.len >= 3) {
                    try self.w.print("    {f} = ", .{self.ident(self.text(m.list[1]) orelse "_")});
                    try self.emitExpr(m.list[2]);
                    try self.w.writeAll(",\n");
                },
                else => {},
            };
        }
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_enum Name (T...) variants... methods...)`.
    fn emitGenericEnum(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 3) return;
        const name = self.text(items[1]) orelse return;
        const members = items[3..];
        try self.w.print("pub fn {f}(", .{self.ident(name)});
        try self.emitTypeParams(items[2]);
        try self.w.writeAll(") type {\n    return union(enum) {\n        const Self = @This();\n\n");
        const prev = self.enterNominal("Self", members);
        defer self.nominal = prev;
        try self.emitUnionVariants(members, 2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v...)` → a Zig error set.
    fn emitErrorSet(self: *Emitter, items: []const Sexp) Error!void {
        const name = self.text(items[1]) orelse return;
        try self.w.print("pub const {f} = error{{\n", .{self.ident(name)});
        for (items[2..]) |v| if (v == .src) try self.w.print("    {f},\n", .{self.ident(self.srcText(v))});
        try self.w.writeAll("};\n");
    }

    fn enterNominal(self: *Emitter, name: []const u8, members: []const Sexp) ?Nominal {
        const prev = self.nominal;
        self.nominal = .{ .name = name, .members = members };
        return prev;
    }

    fn emitTypeParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        var first = true;
        for (params.list) |p| {
            if (p != .src) continue;
            if (!first) try self.w.writeAll(", ");
            first = false;
            try self.w.print("comptime {f}: type", .{self.ident(self.srcText(p))});
        }
    }

    fn emitFields(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const is_field = isTagged(m, .@":") or isTagged(m, .@"aligned") or isTagged(m, .@"default");
            if (!is_field or m.list.len < 3) continue;
            const fname = self.text(m.list[1]) orelse "_";
            // The grammar still admits a few statement keywords as field
            // names; none can be written back as a Rig expression.
            if (isRigStatementKeyword(fname)) return self.unsupported(m.list[1], "a field named by a keyword");
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{self.ident(fname)});
            try self.emitType(m.list[2]);
            if (isTagged(m, .@"aligned") and m.list.len >= 4) {
                try self.w.writeAll(" align(");
                try self.emitExpr(m.list[3]);
                try self.w.writeAll(")");
            }
            if (isTagged(m, .@"default") and m.list.len >= 4) {
                try self.w.writeAll(" = ");
                try self.emitExpr(m.list[3]);
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Variants of a tagged union: bare → `void`, one payload field →
    /// its type, several → an anonymous struct.
    fn emitUnionVariants(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const vname: []const u8 = switch (m) {
                .src => self.srcText(m),
                .list => if (isTagged(m, .@"variant") or isTagged(m, .@"valued"))
                    self.text(m.list[1]) orelse continue
                else
                    continue,
                else => continue,
            };
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{self.ident(vname)});
            const fields: []const Sexp = if (isTagged(m, .@"variant") and m.list.len >= 3 and m.list[2] == .list)
                m.list[2].list
            else
                &.{};
            if (fields.len == 0) {
                try self.w.writeAll("void");
            } else if (fields.len == 1 and isTagged(fields[0], .@":")) {
                try self.emitType(fields[0].list[2]);
            } else {
                try self.w.writeAll("struct { ");
                for (fields, 0..) |f, i| {
                    if (!isTagged(f, .@":") or f.list.len < 3) continue;
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("{f}: ", .{self.ident(self.text(f.list[1]) orelse "_")});
                    try self.emitType(f.list[2]);
                }
                try self.w.writeAll(" }");
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Methods of a nominal type, and its `drop` body. A user `drop`
    /// becomes `__rig_drop`, which runs the body and then drops the
    /// fields; without one, the runtime drops fields structurally.
    fn emitMethods(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            if (m != .list or m.list.len == 0 or m.list[0] != .tag) continue;
            const head = m.list[0].tag;
            if (head != .@"fun" and head != .@"sub" and head != .@"drop_decl") continue;
            try self.w.writeAll("\n");
            try self.writeIndent(depth);
            const prev_indent = self.indent;
            self.indent = depth;
            defer self.indent = prev_indent;
            if (head == .@"drop_decl") {
                try self.emitDropDecl(m.list);
            } else {
                try self.emitFun(m.list, head == .@"sub");
            }
        }
    }

    /// `(drop_decl params block)`: the body becomes `__rig_user_drop`, and
    /// `__rig_drop` runs it and then drops every field.
    fn emitDropDecl(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 3) return;
        const nom = self.nominal.?.name;
        try self.w.print("fn __rig_user_drop(self: *{s}) void ", .{nom});
        self.resetFun();
        try self.scanFunction(items[1], items[2], false);
        self.fun.params = items[1];
        try self.pushScope();
        try self.bindParams(items[1]);
        try self.emitBlock(items[2]);
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
    fn emitFun(self: *Emitter, items: []const Sexp, is_sub: bool) Error!void {
        if (items.len < 5) return;
        const name = self.text(items[1]) orelse "anon";
        const params = items[2];
        const returns: ?Sexp = if (is_sub or items[3] == .nil) null else items[3];
        const body = items[4];
        const is_main = self.nominal == null and is_sub and std.mem.eql(u8, name, "main");

        self.resetFun();
        try self.scanFunction(params, body, returns != null);
        self.fun.returns = returns;
        self.fun.return_ty = if (returns != null) self.funReturnTy(items[1]) else null;
        self.fun.params = params;
        self.fun.leak_check = is_main;

        try self.w.print("pub fn {f}(", .{self.ident(name)});
        try self.pushScope();
        defer self.popScope() catch {};
        try self.bindParams(params);
        try self.emitParamList(params);
        try self.w.writeAll(") ");
        if (returns) |r| {
            try self.emitType(r);
        } else if (is_main and containsPropagate(body)) {
            try self.w.writeAll("!void");
        } else {
            try self.w.writeAll("void");
        }
        try self.w.writeAll(" ");
        if (returns != null) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
    }

    /// Bind each parameter in the current scope. Owned resource values
    /// are copied into a `var` at the top of the body so they can be
    /// dropped; the Zig parameter gets a `__rig_` name.
    fn bindParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.list) |p| {
            const name_node = paramNameNode(p) orelse continue;
            const rig_name = self.text(name_node) orelse continue;
            const ty = self.declTy(name_node);
            var local: Local = .{ .rig_name = rig_name, .zig_name = "", .ty = ty };
            if (paramIsWriteBorrow(p)) {
                local.is_ptr = true;
            } else if (ty) |t| {
                local.kind = self.kindOf(t);
                local.callable = if (self.isOwnedClosureTy(t)) .owned_closure else .none;
            }
            if (local.kind != null) local.guard = if (self.fun.consumed.contains(rig_name)) .flag else .scope;
            _ = try self.declare(local);
        }
    }

    /// The Zig spelling of a parameter as the signature names it.
    fn paramZigName(self: *Emitter, local: *const Local) Error![]const u8 {
        if (local.kind == .value or local.kind == .optional) return self.fmt("__rig_{s}", .{local.zig_name});
        return local.zig_name;
    }

    fn emitParamList(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.list, 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitParam(p);
        }
    }

    fn emitParam(self: *Emitter, p: Sexp) Error!void {
        const name_node = paramNameNode(p) orelse return self.unsupported(p, "this parameter");
        const rig_name = self.text(name_node) orelse "_";
        const zig_name: []const u8 = if (self.lookupCurrent(rig_name)) |local|
            try self.paramZigName(local)
        else
            try self.fmt("{f}", .{self.ident(rig_name)});
        switch (p) {
            .src => try self.w.print("{s}: anytype", .{zig_name}),
            .list => |items| switch (items[0].tag) {
                .@":", .@"default", .@"aligned" => {
                    try self.w.print("{s}: ", .{zig_name});
                    if (items.len >= 3) try self.emitParamType(items[2]) else try self.w.writeAll("anytype");
                },
                .@"pre_param" => {
                    try self.w.print("comptime {s}: ", .{zig_name});
                    if (items.len >= 3) try self.emitType(items[2]) else try self.w.writeAll("anytype");
                },
                // `?self` / `!self` receivers.
                .@"read", .@"write" => {
                    const ptr: []const u8 = if (items[0].tag == .@"write") "*" else "";
                    const nom = if (self.nominal) |n| n.name else "anytype";
                    try self.w.print("{s}: {s}{s}", .{ zig_name, ptr, nom });
                },
                else => return self.unsupported(p, "this parameter"),
            },
            else => return self.unsupported(p, "this parameter"),
        }
    }

    /// A parameter type: `!T` is a pointer, everything else by value.
    fn emitParamType(self: *Emitter, t: Sexp) Error!void {
        if (isTagged(t, .@"borrow_write")) {
            try self.w.writeAll("*");
            return self.emitType(t.list[1]);
        }
        try self.emitType(t);
    }

    /// Statements at the top of a function body: the leak check in
    /// `main`, parameter copies and guards, and discards for unused
    /// parameters.
    fn emitFunPrologue(self: *Emitter, body_stmts: []const Sexp) Error!void {
        if (self.fun.leak_check) {
            self.fun.leak_check = false;
            try self.line("defer rig.checkLeaks();", .{});
        }
        const params = self.fun.params orelse return;
        self.fun.params = null;
        if (params != .list) return;
        for (params.list) |p| {
            const name_node = paramNameNode(p) orelse continue;
            const rig_name = self.text(name_node) orelse continue;
            const local = self.lookup(rig_name) orelse continue;
            if (local.kind == .value or local.kind == .optional) {
                try self.line("var {s} = {s};", .{ local.zig_name, try self.paramZigName(local) });
            }
            if (local.guard != .none) {
                try self.writeIndent(self.indent);
                try self.emitGuard(local);
                try self.w.writeAll("\n");
            } else if (!usesNameInStmts(self.source, body_stmts, rig_name)) {
                try self.line("_ = {s};", .{local.zig_name});
            }
        }
    }

    /// Start a new function: clear per-function state.
    fn resetFun(self: *Emitter) void {
        var mutated = self.fun.mutated;
        var consumed = self.fun.consumed;
        mutated.clearRetainingCapacity();
        consumed.clearRetainingCapacity();
        self.fun = .{ .mutated = mutated, .consumed = consumed };
    }

    // =========================================================================
    // Scopes and names
    // =========================================================================

    fn pushScope(self: *Emitter) Error!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn popScope(self: *Emitter) Error!void {
        var top = self.scopes.pop() orelse return;
        top.locals.deinit(self.allocator);
    }

    /// Declare `local` in the innermost scope, choosing its Zig name
    /// unless one is given. Returns the stored entry.
    fn declare(self: *Emitter, local: Local) Error!*Local {
        if (self.scopes.items.len == 0) try self.pushScope();
        var l = local;
        if (l.zig_name.len == 0) l.zig_name = try self.zigNameFor(l.rig_name);
        if (l.guard == .flag and l.flag.len == 0) {
            l.flag = try self.fmt("__rig_alive_{s}", .{if (isPlainIdent(l.zig_name)) l.zig_name else try self.fresh(l.rig_name)});
        }
        const top = &self.scopes.items[self.scopes.items.len - 1];
        try top.locals.append(self.allocator, l);
        return &top.locals.items[top.locals.items.len - 1];
    }

    fn lookup(self: *Emitter, rig_name: []const u8) ?*Local {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const locals = self.scopes.items[i].locals.items;
            var j = locals.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, locals[j].rig_name, rig_name)) return &locals[j];
            }
        }
        return null;
    }

    fn lookupCurrent(self: *Emitter, rig_name: []const u8) ?*Local {
        if (self.scopes.items.len == 0) return null;
        const locals = self.scopes.items[self.scopes.items.len - 1].locals.items;
        var j = locals.len;
        while (j > 0) {
            j -= 1;
            if (std.mem.eql(u8, locals[j].rig_name, rig_name)) return &locals[j];
        }
        return null;
    }

    /// A Zig name for a new binding: the Rig name (escaped if it is a Zig
    /// keyword) unless that would shadow a visible Zig name.
    fn zigNameFor(self: *Emitter, rig_name: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, rig_name, "_")) return "_";
        const base = try self.fmt("{f}", .{self.ident(rig_name)});
        if (!self.nameTaken(base)) return base;
        return self.fresh(rig_name);
    }

    fn nameTaken(self: *Emitter, zig_name: []const u8) bool {
        if (self.module.names.contains(zig_name)) return true;
        if (self.nominal) |n| {
            if (std.mem.eql(u8, n.name, zig_name)) return true;
            for (n.members) |m| {
                if (!isTagged(m, .@"fun") and !isTagged(m, .@"sub")) continue;
                if (m.list.len >= 2) if (self.text(m.list[1])) |mn| if (std.mem.eql(u8, mn, zig_name)) return true;
            }
        }
        for (self.scopes.items) |s| for (s.locals.items) |l| {
            if (std.mem.eql(u8, l.zig_name, zig_name)) return true;
        };
        return false;
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

    // =========================================================================
    // Blocks and statements
    // =========================================================================

    /// The statements of a block, or a lone statement as a list of one.
    fn stmtsOf(self: *Emitter, body: Sexp) Error![]const Sexp {
        if (isTagged(body, .@"block")) return body.list[1..];
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
        const stmts = try self.stmtsOf(body);
        try self.emitFunPrologue(stmts);
        try self.emitStmts(stmts);
        try self.closeBrace();
    }

    fn emitStmts(self: *Emitter, stmts: []const Sexp) Error!void {
        return self.emitStmtRange(stmts, stmts.len);
    }

    /// The first `count` of `stmts`; the others still count as `rest`.
    fn emitStmtRange(self: *Emitter, stmts: []const Sexp, count: usize) Error!void {
        const saved = self.rest;
        defer self.rest = saved;
        for (stmts[0..count], 0..) |stmt, i| {
            self.rest = stmts[i + 1 ..];
            try self.writeIndent(self.indent);
            try self.emitStmt(stmt);
            try self.w.writeAll("\n");
        }
    }

    /// A statement with nothing after it in its block.
    fn emitLastStmt(self: *Emitter, stmt: Sexp) Error!void {
        const saved = self.rest;
        defer self.rest = saved;
        self.rest = &.{};
        try self.emitStmt(stmt);
    }

    /// A function body whose last expression statement is its value.
    fn emitValueBody(self: *Emitter, body: Sexp) Error!void {
        try self.openBrace();
        const stmts = try self.stmtsOf(body);
        try self.emitFunPrologue(stmts);
        if (stmts.len == 0) return self.closeBrace();
        const last = stmts.len - 1;
        try self.emitStmtRange(stmts, last);
        try self.writeIndent(self.indent);
        if (isValueStmt(stmts[last])) {
            try self.w.writeAll("return ");
            try self.emitReturnValue(stmts[last]);
            try self.w.writeAll(";");
        } else {
            try self.emitLastStmt(stmts[last]);
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    fn emitStmt(self: *Emitter, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) {
            try self.w.writeAll("_ = ");
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        }
        const items = sexp.list;
        switch (items[0].tag) {
            .@"set" => try self.emitSet(sexp),
            .@"drop" => try self.emitDrop(sexp),
            .@"return" => try self.emitReturn(items),
            .@"break" => try self.emitBreak(items),
            .@"continue" => try self.emitContinue(items),
            .@"if" => try self.emitIf(sexp),
            .@"while", .@"for" => try self.emitLoop(sexp, null),
            .@"labeled" => try self.emitLabeled(sexp),
            .@"match" => try self.emitMatch(sexp, false),
            .@"block" => try self.emitBlock(sexp),
            // `raw` marks an audit boundary for sema; it lowers to a block.
            .@"raw_block" => try self.emitBlock(items[1]),
            .@"defer", .@"errdefer" => {
                try self.w.print("{s} ", .{@tagName(items[0].tag)});
                const saved = self.rest;
                self.rest = &.{};
                defer self.rest = saved;
                if (isTagged(items[1], .@"block")) try self.emitBlock(items[1]) else try self.emitStmt(items[1]);
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
        while (isTagged(e, .@"propagate") or isTagged(e, .@"try")) e = e.list[1];
        if (!isTagged(e, .@"call")) return true;
        if (self.isPrintCall(e)) return false;
        const ty = self.typeOf(e) orelse return true;
        return switch (self.sema.?.types.get(self.resolve(ty).id)) {
            .void => false,
            else => true,
        };
    }

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    /// `(set kind target type expr)`.
    fn emitSet(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len < 5) return self.unsupported(sexp, "this binding");
        const kind = try rig.bindingKindOf(items[1]);
        const target = items[2];
        const type_node = items[3];
        const expr = items[4];

        if (target != .src) {
            return switch (kind) {
                .default, .move => self.emitPlaceAssign(target, expr),
                .@"+=" => self.emitCompound(target, "+", expr),
                .@"-=" => self.emitCompound(target, "-", expr),
                .@"*=" => self.emitCompound(target, "*", expr),
                .@"/=" => self.emitCompound(target, "/", expr),
                .fixed, .shadow => self.unsupported(sexp, "this binding target"),
            };
        }
        const name = self.srcText(target);
        switch (kind) {
            .@"+=" => try self.emitCompound(target, "+", expr),
            .@"-=" => try self.emitCompound(target, "-", expr),
            .@"*=" => try self.emitCompound(target, "*", expr),
            .@"/=" => try self.emitCompound(target, "/", expr),
            .fixed, .shadow => try self.emitBind(target, type_node, expr),
            .default, .move => {
                const value: Sexp = if (kind == .move) try self.list(&.{ .{ .tag = .@"move" }, expr }) else expr;
                if (self.lookup(name)) |local| {
                    try self.emitRebind(local.*, value);
                } else {
                    try self.emitBind(target, type_node, value);
                }
            },
        }
    }

    /// A new binding.
    fn emitBind(self: *Emitter, name_node: Sexp, type_node: Sexp, expr: Sexp) Error!void {
        if (isTagged(expr, .@"lambda")) return self.emitClosureBinding(name_node, expr);

        const rig_name = self.srcText(name_node);
        const ty = self.declTy(name_node);
        const is_borrow = isTagged(expr, .@"read") or isTagged(expr, .@"write");
        var local: Local = .{ .rig_name = rig_name, .zig_name = "", .ty = ty, .is_ptr = is_borrow };
        if (!is_borrow) {
            if (ty) |t| local.kind = self.kindOf(t);
        }
        if (local.kind != null) local.guard = if (self.fun.consumed.contains(rig_name)) .flag else .scope;
        if ((ty != null and self.isOwnedClosureTy(ty.?)) or isOwnedClosureTypeNode(self.source, type_node) or
            classifyOwnedClosure(self.source, unwrapShare(expr)) != null)
        {
            local.callable = .owned_closure;
        }

        const needs_ptr_self = local.kind == .value or local.kind == .optional or
            (ty != null and self.isCellTy(ty.?));
        const mutated = self.fun.mutated.contains(name_node.src.pos);
        const is_var = !is_borrow and (mutated or needs_ptr_self);

        // Evaluate the value before the new name is visible, so a shadow
        // (`new x = x + 1`) reads the old binding.
        const saved_expected = self.expected;
        self.expected = ty;
        defer {
            self.expected = saved_expected;
        }
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            if (is_borrow) {
                try self.emitAddressOf(expr.list[1]);
            } else if (type_node != .nil and self.isErrorSetNode(type_node) and isTagged(expr, .@"enum_lit")) {
                try self.w.print("error.{f}", .{self.ident(self.text(expr.list[1]) orelse "_")});
            } else {
                try self.emitBare(expr);
            }
        }

        const stored = try self.declare(local);
        try self.w.print("{s} {s}", .{ if (is_var) "var" else "const", stored.zig_name });
        if (type_node != .nil and !is_borrow) {
            try self.w.writeAll(": ");
            try self.emitType(type_node);
        } else if (is_var and ty != null and self.isNumericOrBool(ty.?)) {
            try self.w.writeAll(": ");
            try self.emitTypeTy(ty.?);
        } else if (is_var and ty == null and isNumberLiteral(self.source, expr)) {
            // A mutable number needs a runtime type: Rig's defaults.
            try self.w.writeAll(if (self.isFloatExpr(unwrapNeg(expr))) ": f32" else ": i32");
        }
        try self.w.print(" = {s};", .{value_buf.written()});

        if (stored.guard != .none) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitGuard(stored);
        } else if (is_var and !mutated) {
            // Methods that take `*Self` mutate through the address.
            try self.w.print(" _ = &{s};", .{stored.zig_name});
        } else if (!self.usedLater(rig_name)) {
            try self.w.print(" _ = {s};", .{stored.zig_name});
        }
    }

    /// Whether `rig_name` is referenced by the rest of the current block
    /// (before any statement that shadows it).
    fn usedLater(self: *Emitter, rig_name: []const u8) bool {
        return usesNameInStmts(self.source, self.rest, rig_name);
    }

    /// Reassign an existing binding. A resource's old value is dropped
    /// after the new one has been computed (so `a = +a` works), and the
    /// guard is re-armed.
    fn emitRebind(self: *Emitter, local: Local, value: Sexp) Error!void {
        const kind = local.kind orelse {
            try self.writeLocalPlace(&local);
            try self.w.writeAll(" = ");
            try self.emitExprExpecting(value, local.ty);
            try self.w.writeAll(";");
            return;
        };
        const tmp = try self.fmt("__rig_new_{d}", .{self.nextId()});
        try self.w.print("{{ const {s} = ", .{tmp});
        try self.emitExprExpecting(value, local.ty);
        try self.w.writeAll("; ");
        if (local.guard == .flag) try self.w.print("if ({s}) ", .{local.flag});
        try self.writeDrop(local.zig_name, kind);
        try self.w.print("; {s} = {s};", .{ local.zig_name, tmp });
        if (local.guard == .flag) try self.w.print(" {s} = true;", .{local.flag});
        try self.w.writeAll(" }");
    }

    /// Assignment to a field, element, or dereference. When the place
    /// may hold a resource, the old value is dropped after the new one
    /// is computed.
    fn emitPlaceAssign(self: *Emitter, target: Sexp, value: Sexp) Error!void {
        const place_ty = self.typeOf(target);
        const may_own = if (place_ty) |t| self.kindOf(t) != null else true;
        if (!may_own) {
            try self.emitPlace(target);
            try self.w.writeAll(" = ");
            try self.emitExprExpecting(value, place_ty);
            try self.w.writeAll(";");
            return;
        }
        const id = self.nextId();
        try self.w.print("{{ const __rig_new_{d} = ", .{id});
        try self.emitExprExpecting(value, place_ty);
        try self.w.print("; const __rig_slot_{d} = &", .{id});
        try self.emitPlace(target);
        try self.w.print("; rig.drop(__rig_slot_{d}); __rig_slot_{d}.* = __rig_new_{d}; }}", .{ id, id, id });
    }

    /// `x op= e` on a name or place. Integer `/=` truncates.
    fn emitCompound(self: *Emitter, target: Sexp, op: []const u8, value: Sexp) Error!void {
        if (std.mem.eql(u8, op, "/") and !self.isFloatExpr(target)) {
            if (target == .src) {
                try self.emitPlace(target);
                try self.w.writeAll(" = @divTrunc(");
                try self.emitPlace(target);
            } else {
                // Evaluate the place once.
                const id = self.nextId();
                try self.w.print("{{ const __rig_slot_{d} = &", .{id});
                try self.emitPlace(target);
                try self.w.print("; __rig_slot_{d}.* = @divTrunc(__rig_slot_{d}.*", .{ id, id });
            }
            try self.w.writeAll(", ");
            try self.emitBare(value);
            try self.w.writeAll(if (target == .src) ");" else "); }");
            return;
        }
        try self.emitPlace(target);
        try self.w.print(" {s}= ", .{op});
        try self.emitBare(value);
        try self.w.writeAll(";");
    }

    /// An assignable place: a binding, field, element, or dereference.
    fn emitPlace(self: *Emitter, target: Sexp) Error!void {
        switch (target) {
            .src => if (self.lookup(self.srcText(target))) |local| try self.writeLocalPlace(local) else try self.emitExpr(target),
            .list => |items| if (items.len >= 3 and items[0] == .tag and items[0].tag == .@"index") {
                try self.emitIndex(items, true);
            } else {
                try self.emitExpr(target);
            },
            else => try self.emitExpr(target),
        }
    }

    fn writeLocalPlace(self: *Emitter, local: *const Local) Error!void {
        try self.w.writeAll(local.zig_name);
        if (local.is_ptr) try self.w.writeAll(".*");
    }

    /// `-x`: drop now.
    fn emitDrop(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len >= 2 and items[1] == .src) {
            if (self.lookup(self.srcText(items[1]))) |local| {
                if (local.kind) |kind| if (local.guard != .none) {
                    if (local.guard == .flag) try self.w.print("{s} = false; ", .{local.flag});
                    try self.writeDrop(local.zig_name, kind);
                    try self.w.writeAll(";");
                    return;
                };
                // Ending a borrow or dropping plain data has no runtime effect.
                try self.w.writeAll("{}");
                return;
            }
        }
        return self.unsupported(sexp, "this drop");
    }

    // -------------------------------------------------------------------------
    // Control flow
    // -------------------------------------------------------------------------

    /// `(return value? guard?)`.
    fn emitReturn(self: *Emitter, items: []const Sexp) Error!void {
        const value: Sexp = if (items.len >= 2) items[1] else .nil;
        const guard: Sexp = if (items.len >= 3) items[2] else .nil;
        if (guard != .nil) {
            try self.w.writeAll("if (");
            try self.emitBare(guard);
            try self.w.writeAll(") ");
        }
        if (value == .nil) {
            try self.w.writeAll("return;");
            return;
        }
        try self.w.writeAll("return ");
        try self.emitReturnValue(value);
        try self.w.writeAll(";");
    }

    /// A value leaving the function. Resource bindings reached in tail
    /// position (directly, or through `if`/`match`/ternary branches) are
    /// moved out, so their scope-exit drop is disarmed.
    fn emitReturnValue(self: *Emitter, value: Sexp) Error!void {
        const saved = self.expected;
        defer self.expected = saved;
        self.expected = self.returnTy();
        if (self.fun.returns) |r| {
            if (self.isErrorSetNode(r) and isTagged(value, .@"enum_lit")) {
                try self.w.print("error.{f}", .{self.ident(self.text(value.list[1]) orelse "_")});
                return;
            }
        }
        self.bare = true;
        try self.emitValue(value, true);
    }

    /// `(break value label guard)`.
    fn emitBreak(self: *Emitter, items: []const Sexp) Error!void {
        const value: Sexp = if (items.len >= 2) items[1] else .nil;
        const label: Sexp = if (items.len >= 3) items[2] else .nil;
        const guard: Sexp = if (items.len >= 4) items[3] else .nil;
        try self.emitGuardPrefix(guard);
        try self.w.writeAll("break");
        if (label != .nil) try self.w.print(" :{f}", .{self.ident(self.text(label) orelse "_")});
        if (value != .nil) {
            try self.w.writeAll(" ");
            self.bare = true;
            try self.emitValue(value, true);
        }
        try self.w.writeAll(";");
    }

    /// `(continue label guard)`.
    fn emitContinue(self: *Emitter, items: []const Sexp) Error!void {
        const label: Sexp = if (items.len >= 2) items[1] else .nil;
        const guard: Sexp = if (items.len >= 3) items[2] else .nil;
        try self.emitGuardPrefix(guard);
        try self.w.writeAll("continue");
        if (label != .nil) try self.w.print(" :{f}", .{self.ident(self.text(label) orelse "_")});
        try self.w.writeAll(";");
    }

    fn emitGuardPrefix(self: *Emitter, guard: Sexp) Error!void {
        if (guard == .nil) return;
        try self.w.writeAll("if (");
        try self.emitBare(guard);
        try self.w.writeAll(") ");
    }

    /// Statement `if`: `(if cond then)`, `(if cond then else)`, or
    /// `(if cond then err_name else)`.
    fn emitIf(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len < 3) return self.unsupported(sexp, "this if");
        try self.pushScope();
        try self.w.writeAll("if ");
        try self.emitCond(items[1]);
        try self.emitBranchStmt(items[2]);
        try self.popScope();
        if (items.len == 4) {
            try self.w.writeAll(" else ");
            if (isTagged(items[3], .@"if")) try self.emitIf(items[3]) else try self.emitBranchStmt(items[3]);
        } else if (items.len >= 5) {
            try self.pushScope();
            const err_name = self.text(items[3]) orelse "_";
            const local = try self.declare(.{ .rig_name = err_name, .zig_name = "" });
            try self.w.print(" else |{s}| ", .{local.zig_name});
            try self.emitBranchStmt(items[4]);
            try self.popScope();
        }
    }

    /// `(cond) ` for `if`/`while`. `(as expr name)` unwraps an optional
    /// into `name`, declared in the current scope: `(expr) |name| `.
    fn emitCond(self: *Emitter, cond: Sexp) Error!void {
        try self.w.writeAll("(");
        if (!isTagged(cond, .@"as")) {
            try self.emitBare(cond);
            return self.w.writeAll(") ");
        }
        try self.emitExpr(cond.list[1]);
        const name = self.text(cond.list[2]) orelse "_";
        const inner = if (self.typeOf(cond.list[1])) |t| self.optionalChild(t) else null;
        const local = try self.declare(.{ .rig_name = name, .zig_name = "", .ty = inner });
        try self.w.print(") |{s}| ", .{local.zig_name});
    }

    fn emitBranchStmt(self: *Emitter, branch: Sexp) Error!void {
        if (isTagged(branch, .@"block")) return self.emitBlock(branch);
        try self.w.writeAll("{ ");
        const saved = self.rest;
        self.rest = &.{};
        defer self.rest = saved;
        try self.emitStmt(branch);
        try self.w.writeAll(" }");
    }

    /// `(labeled name stmt)`: a labeled loop or block.
    fn emitLabeled(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        const label = self.text(items[1]) orelse return self.unsupported(sexp, "this label");
        const stmt = items[2];
        if (isTagged(stmt, .@"while") or isTagged(stmt, .@"for")) return self.emitLoop(stmt, label);
        if (isTagged(stmt, .@"block")) {
            try self.w.print("{f}: ", .{self.ident(label)});
            return self.emitBlock(stmt);
        }
        return self.unsupported(sexp, "a label on this statement");
    }

    fn emitLoop(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        if (isTagged(sexp, .@"while")) return self.emitWhile(sexp, label);
        return self.emitFor(sexp, label);
    }

    fn writeLabel(self: *Emitter, label: ?[]const u8) Error!void {
        if (label) |l| try self.w.print("{f}: ", .{self.ident(l)});
    }

    /// `(while cond continuation body else?)`.
    fn emitWhile(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const items = sexp.list;
        if (items.len < 4) return self.unsupported(sexp, "this while");
        try self.pushScope();
        try self.writeLabel(label);
        try self.w.writeAll("while ");
        try self.emitCond(items[1]);
        if (items[2] != .nil) {
            try self.w.writeAll(": (");
            try self.emitContinuation(items[2]);
            try self.w.writeAll(") ");
        }
        try self.emitBranchStmt(items[3]);
        try self.popScope();
        if (items.len >= 5 and items[4] != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(items[4]);
        }
    }

    /// The `: step` of a while, written as a Zig continue expression.
    fn emitContinuation(self: *Emitter, step: Sexp) Error!void {
        if (isTagged(step, .@"set") and step.list.len >= 5 and step.list[2] == .src) {
            const kind = try rig.bindingKindOf(step.list[1]);
            const op: ?[]const u8 = switch (kind) {
                .@"+=" => "+=",
                .@"-=" => "-=",
                .@"*=" => "*=",
                .default => "=",
                else => null,
            };
            if (op) |o| if (self.lookup(self.srcText(step.list[2]))) |local| {
                try self.writeLocalPlace(local);
                try self.w.print(" {s} ", .{o});
                try self.emitBare(step.list[4]);
                return;
            };
        }
        if (isTagged(step, .@"call")) return self.emitExpr(step);
        // Anything else runs as a block.
        try self.w.writeAll("{ ");
        const saved = self.rest;
        self.rest = &.{};
        defer self.rest = saved;
        try self.emitStmt(step);
        try self.w.writeAll(" }");
    }

    /// `(for mode binding index-binding source body else?)`.
    fn emitFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const items = sexp.list;
        if (items.len < 6) return self.unsupported(sexp, "this for");
        const mode = items[1];
        const binding = items[2];
        const index_binding = items[3];
        const source = items[4];
        const body = items[5];
        const else_body: Sexp = if (items.len >= 7) items[6] else .nil;

        if (isTagged(source, .@"..")) return self.emitRangeFor(sexp, label);

        const src_ty = self.typeOf(source);
        const elem_ty: ?Ty = if (src_ty) |t| self.elemTy(t) else null;
        const is_vec = if (src_ty) |t| self.isVecTy(t) else self.vecInfo(source) != null;
        const by_ptr = (mode == .tag and (mode.tag == .@"ptr" or mode.tag == .@"write")) or
            (is_vec and if (elem_ty) |t| self.kindOf(t) != null else if (self.vecInfo(source)) |v| v.is_resource else false);

        const body_stmts = try self.stmtsOf(body);
        try self.pushScope();
        try self.writeLabel(label);
        try self.w.writeAll("for (");
        try self.emitExpr(source);
        if (is_vec) try self.w.writeAll(".items()");
        if (index_binding != .nil) try self.w.writeAll(", 0..");
        try self.w.writeAll(") |");

        var elem_name: []const u8 = "_";
        if (binding == .src and usesNameInStmts(self.source, body_stmts, self.srcText(binding))) {
            var local: Local = .{ .rig_name = self.srcText(binding), .zig_name = "", .ty = elem_ty, .is_ptr = by_ptr };
            if (elem_ty) |t| {
                if (self.isOwnedClosureTy(t)) local.callable = .owned_closure;
            } else if (self.vecInfo(source)) |v| {
                if (v.is_closure) local.callable = .owned_closure;
            }
            const stored = try self.declare(local);
            elem_name = stored.zig_name;
        }
        try self.w.print("{s}{s}", .{ if (by_ptr and !std.mem.eql(u8, elem_name, "_")) "*" else "", elem_name });

        if (index_binding == .src) {
            const iname = self.srcText(index_binding);
            if (usesNameInStmts(self.source, body_stmts, iname)) {
                const raw = try self.fmt("__rig_i_{d}", .{self.nextId()});
                const stored = try self.declare(.{ .rig_name = iname, .zig_name = "", .ty = self.declTy(index_binding) });
                try self.w.print(", {s}", .{raw});
                try self.w.writeAll("| {\n");
                self.indent += 1;
                try self.line("const {s}: i32 = @intCast({s});", .{ stored.zig_name, raw });
            } else {
                try self.w.writeAll(", _| {\n");
                self.indent += 1;
            }
        } else {
            try self.w.writeAll("| {\n");
            self.indent += 1;
        }
        try self.pushScope();
        try self.emitStmts(body_stmts);
        try self.closeBrace();
        try self.popScope();
        if (else_body != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(else_body);
        }
    }

    /// `for i in a..b`: a half-open integer range.
    fn emitRangeFor(self: *Emitter, sexp: Sexp, label: ?[]const u8) Error!void {
        const items = sexp.list;
        const binding = items[2];
        const range = items[4];
        const body_stmts = try self.stmtsOf(items[5]);
        const else_body: Sexp = if (items.len >= 7) items[6] else .nil;
        const id = self.nextId();
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const end = try self.fmt("__rig_end_{d}", .{id});
        const int_ty: ?Ty = if (binding == .src) self.declTy(binding) else null;

        try self.openBrace();
        try self.writeIndent(self.indent);
        try self.w.print("var {s}: ", .{counter});
        if (int_ty != null and self.isNumericOrBool(int_ty.?)) try self.emitTypeTy(int_ty.?) else try self.w.writeAll("i32");
        try self.w.writeAll(" = ");
        try self.emitExpr(range.list[1]);
        try self.w.print(";\n", .{});
        try self.writeIndent(self.indent);
        try self.w.print("const {s} = ", .{end});
        try self.emitExpr(range.list[2]);
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.writeLabel(label);
        try self.w.print("while ({s} < {s}) : ({s} += 1) ", .{ counter, end, counter });
        try self.openBrace();
        if (binding == .src and usesNameInStmts(self.source, body_stmts, self.srcText(binding))) {
            const stored = try self.declare(.{ .rig_name = self.srcText(binding), .zig_name = "", .ty = int_ty });
            try self.line("const {s} = {s};", .{ stored.zig_name, counter });
        }
        try self.emitStmts(body_stmts);
        try self.closeBrace();
        if (else_body != .nil) {
            try self.w.writeAll(" else ");
            try self.emitBranchStmt(else_body);
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
        const items = sexp.list;
        if (items.len < 2) return self.unsupported(sexp, "this match");
        const scrutinee = items[1];
        const scrut_ty = self.typeOf(scrutinee);
        const error_set = if (scrut_ty) |t| self.isErrorSetTy(t) else false;

        try self.w.writeAll("switch (");
        try self.emitBare(scrutinee);
        try self.w.writeAll(") {\n");
        self.indent += 1;

        var has_default = false;
        var variants_seen: usize = 0;
        for (items[2..]) |arm| {
            if (!isTagged(arm, .@"arm") or arm.list.len < 4) continue;
            const pattern = arm.list[1];
            const as_name = arm.list[2];
            const body = arm.list[arm.list.len - 1];
            try self.writeIndent(self.indent);
            try self.pushScope();
            defer self.popScope() catch {};

            var captures: []const Sexp = &.{};
            var variant: ?[]const u8 = null;
            switch (pattern) {
                .src, .nil => {
                    has_default = true;
                    try self.w.writeAll("else => ");
                    const bind = if (pattern == .src and !std.mem.eql(u8, self.srcText(pattern), "_")) pattern else as_name;
                    if (bind == .src) try self.emitCapture(bind, scrut_ty, body);
                },
                .list => |p| switch (if (p.len > 0 and p[0] == .tag) p[0].tag else .@"block") {
                    .@"enum_lit", .@"enum_pattern", .@"variant_pattern" => {
                        const vname = self.text(p[1]) orelse "_";
                        variant = vname;
                        variants_seen += 1;
                        try self.w.print("{s}{f} => ", .{ if (error_set) "error." else ".", self.ident(vname) });
                        if (p[0].tag == .@"variant_pattern") captures = p[2..];
                        if (captures.len == 0 and as_name == .src) {
                            try self.emitCapture(as_name, self.variantPayloadTy(scrut_ty, vname, null), body);
                        }
                    },
                    .@"range_pattern" => {
                        // Patterns are inclusive: `1..3` covers 1, 2, 3.
                        try self.emitExpr(p[1]);
                        try self.w.writeAll("...");
                        try self.emitExpr(p[2]);
                        try self.w.writeAll(" => ");
                    },
                    else => {
                        try self.emitExpr(pattern);
                        try self.w.writeAll(" => ");
                    },
                },
                else => {
                    try self.emitExpr(pattern);
                    try self.w.writeAll(" => ");
                },
            }

            // Payload destructuring.
            var aliases: []const Alias = &.{};
            if (captures.len == 1 and captures[0] == .src) {
                try self.emitCapture(captures[0], self.variantPayloadTy(scrut_ty, variant.?, null), body);
            } else if (captures.len > 1) {
                aliases = try self.payloadAliases(captures, scrut_ty, variant.?, body);
                if (aliases.len > 0) try self.w.writeAll("|__rig_payload| ");
            }
            try self.emitArmBody(body, aliases, value_pos);
            try self.w.writeAll(",\n");
        }
        if (!has_default and !self.matchIsExhaustive(scrut_ty, variants_seen)) {
            try self.line("else => unreachable,", .{});
        }
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    const Alias = struct { zig_name: []const u8, field: []const u8 };

    /// `|name| ` for a payload or catch-all capture that the body uses.
    fn emitCapture(self: *Emitter, name_node: Sexp, ty: ?Ty, body: Sexp) Error!void {
        const name = self.srcText(name_node);
        if (!usesName(self.source, body, name)) return;
        const local = try self.declare(.{ .rig_name = name, .zig_name = "", .ty = ty, .callable = if (ty != null and self.isOwnedClosureTy(ty.?)) .owned_closure else .none });
        try self.w.print("|{s}| ", .{local.zig_name});
    }

    /// Bindings for a multi-field payload, declared in the arm's scope.
    fn payloadAliases(self: *Emitter, captures: []const Sexp, scrut_ty: ?Ty, variant: []const u8, body: Sexp) Error![]const Alias {
        const names = self.variantFieldNames(scrut_ty, variant) orelse return self.unsupported(captures[0], "this payload pattern");
        var out: std.ArrayListUnmanaged(Alias) = .empty;
        for (captures, 0..) |c, i| {
            if (c != .src or i >= names.len) continue;
            const name = self.srcText(c);
            if (std.mem.eql(u8, name, "_") or !usesName(self.source, body, name)) continue;
            const ty = self.variantPayloadTy(scrut_ty, variant, names[i]);
            const local = try self.declare(.{ .rig_name = name, .zig_name = "", .ty = ty });
            try out.append(self.arena.allocator(), .{ .zig_name = local.zig_name, .field = names[i] });
        }
        return out.items;
    }

    fn emitArmBody(self: *Emitter, body: Sexp, aliases: []const Alias, value_pos: bool) Error!void {
        if (value_pos) return self.emitValueBlock(body, aliases);
        try self.openBrace();
        for (aliases) |a| try self.line("const {s} = __rig_payload.{f};", .{ a.zig_name, self.ident(a.field) });
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn matchIsExhaustive(self: *Emitter, scrut_ty: ?Ty, variants_seen: usize) bool {
        const t = scrut_ty orelse return false;
        const sym_id = self.nominalSym(t) orelse return false;
        const sym = self.sema.?.symbols.items[sym_id];
        const fields = sym.fields orelse return false;
        var count: usize = 0;
        for (fields) |f| {
            if (f.is_variant) count += 1;
        }
        return count > 0 and variants_seen >= count;
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

    fn emitExprExpecting(self: *Emitter, sexp: Sexp, ty: ?Ty) Error!void {
        const saved = self.expected;
        defer self.expected = saved;
        self.expected = ty;
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
            .nil => try self.w.writeAll("undefined"),
            .src => try self.emitName(sexp, tail),
            .str => |s| try self.w.writeAll(s),
            .tag => return self.unsupported(sexp, "this expression"),
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return self.unsupported(sexp, "this expression");
                try self.emitList(sexp, tail, bare);
            },
        }
    }

    fn emitName(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const name = self.srcText(sexp);
        if (self.lookup(name)) |local| {
            if (tail and local.guard == .flag) return self.writeTake(local);
            return self.writeLocalPlace(local);
        }
        if (name.len >= 2 and name[0] == '\'') return self.writeSingleQuoted(name);
        if (isLiteralText(name)) return self.w.writeAll(name);
        try self.w.print("{f}", .{self.ident(name)});
    }

    /// `rig.take(&flag, x)`: yields `x` and disarms its scope-exit drop.
    fn writeTake(self: *Emitter, local: *const Local) Error!void {
        try self.w.print("rig.take(&{s}, {s})", .{ local.flag, local.zig_name });
    }

    fn emitList(self: *Emitter, sexp: Sexp, tail: bool, bare: bool) Error!void {
        const items = sexp.list;
        const head = items[0].tag;
        switch (head) {
            .@"read", .@"pin", .@"raw" => try self.emitValue(items[1], tail),
            // `!x` as a value (an argument, a receiver) is the place's address.
            .@"write" => try self.emitAddressOf(items[1]),
            .@"move" => {
                if (items[1] == .src) if (self.lookup(self.srcText(items[1]))) |local| {
                    if (local.guard == .flag) return self.writeTake(local);
                };
                try self.emitExpr(items[1]);
            },
            .@"share" => try self.emitShare(items[1]),
            .@"clone" => {
                const kind: ?ResourceKind = if (self.typeOf(items[1])) |t| self.kindOf(t) else null;
                if (kind == .optional) {
                    try self.w.writeAll("rig.cloneOptional(");
                    try self.emitBare(items[1]);
                    return self.w.writeAll(")");
                }
                if (kind == .value) return self.unsupported(sexp, "a clone of a value with drop glue");
                try self.emitExpr(items[1]);
                if (kind == .shared) try self.w.writeAll(".cloneStrong()");
                if (kind == .weak) try self.w.writeAll(".cloneWeak()");
            },
            .@"weak" => {
                try self.emitExpr(items[1]);
                try self.w.writeAll(".weakRef()");
            },
            .@"call" => try self.emitCall(sexp),
            .@"member" => try self.emitMember(items),
            .@"index" => try self.emitIndex(items, false),
            .@"deref" => {
                try self.emitExpr(items[1]);
                try self.w.writeAll(".*");
            },
            .@"builtin" => try self.emitBuiltin(items),
            .@"propagate", .@"try" => {
                try self.w.writeAll("try ");
                try self.emitExpr(items[1]);
            },
            .@"neg" => {
                try self.w.writeAll("-");
                try self.emitExpr(items[1]);
            },
            .@"not" => {
                try self.w.writeAll("!");
                try self.emitExpr(items[1]);
            },
            .@"addr_of" => {
                try self.w.writeAll("&");
                try self.emitExpr(items[1]);
            },
            .@"enum_lit" => try self.w.print(".{f}", .{self.ident(self.text(items[1]) orelse "_")}),
            .@"null", .@"undefined", .@"unreachable" => try self.w.writeAll(@tagName(head)),
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@">>" => try self.emitInfix(items, bare),
            .@"&&", .@"||" => {
                if (!bare) try self.w.writeAll("(");
                try self.emitExpr(items[1]);
                try self.w.writeAll(if (head == .@"&&") " and " else " or ");
                try self.emitExpr(items[2]);
                if (!bare) try self.w.writeAll(")");
            },
            .@"/" => try self.emitDivision(items, "@divTrunc"),
            .@"%" => try self.emitDivision(items, "@rem"),
            .@"**" => {
                try self.w.writeAll("std.math.pow(");
                if (self.typeOf(items[1])) |t| try self.emitTypeTy(t) else try self.w.writeAll(if (self.isFloatExpr(items[1])) "f32" else "i32");
                try self.w.writeAll(", ");
                try self.emitExpr(items[1]);
                try self.w.writeAll(", ");
                try self.emitExpr(items[2]);
                try self.w.writeAll(")");
            },
            .@"??" => {
                try self.w.writeAll("(");
                try self.emitExpr(items[1]);
                try self.w.writeAll(" orelse ");
                try self.emitValue(items[2], true);
                try self.w.writeAll(")");
            },
            .@"catch" => {
                try self.w.writeAll("(");
                try self.emitExpr(items[1]);
                try self.w.writeAll(" catch ");
                if (items.len >= 4) {
                    try self.pushScope();
                    const local = try self.declare(.{ .rig_name = self.text(items[2]) orelse "_", .zig_name = "" });
                    try self.w.print("|{s}| ", .{if (usesName(self.source, items[3], local.rig_name)) local.zig_name else "_"});
                    try self.emitValue(items[3], true);
                    try self.popScope();
                } else {
                    try self.emitValue(items[2], true);
                }
                try self.w.writeAll(")");
            },
            .@"|>" => try self.emitPipe(items),
            .@"ternary" => {
                // `(ternary cond then else)`
                try self.w.writeAll(if (bare) "if (" else "(if (");
                try self.emitBare(items[1]);
                try self.w.writeAll(") ");
                try self.emitValue(items[2], true);
                try self.w.writeAll(" else ");
                try self.emitValue(items[3], true);
                if (!bare) try self.w.writeAll(")");
            },
            .@"if" => {
                if (!bare) try self.w.writeAll("(");
                try self.emitIfExpr(sexp);
                if (!bare) try self.w.writeAll(")");
            },
            .@"match" => try self.emitMatch(sexp, true),
            .@"block" => try self.emitValueBlock(sexp, &.{}),
            .@"raw_block" => try self.emitValueBlock(items[1], &.{}),
            .@"array" => try self.emitArray(items),
            .@"anon_init" => try self.emitFieldInit(".", items[1..]),
            .@"record" => {
                try self.w.print("{f}", .{self.ident(self.text(items[1]) orelse "_")});
                try self.emitFieldInit("", items[2..]);
            },
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// `&place`, or the pointer itself when the place is already one.
    fn emitAddressOf(self: *Emitter, place: Sexp) Error!void {
        if (place == .src) if (self.lookup(self.srcText(place))) |local| {
            if (local.is_ptr) return self.w.writeAll(local.zig_name);
        };
        try self.w.writeAll("&");
        try self.emitPlace(place);
    }

    fn emitInfix(self: *Emitter, items: []const Sexp, bare: bool) Error!void {
        const op = @tagName(items[0].tag);
        const is_eq = items[0].tag == .@"==" or items[0].tag == .@"!=";
        if (is_eq and (self.isStringExpr(items[1]) or self.isStringExpr(items[2]))) {
            if (items[0].tag == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("std.mem.eql(u8, ");
            try self.emitExpr(items[1]);
            try self.w.writeAll(", ");
            try self.emitExpr(items[2]);
            try self.w.writeAll(")");
            return;
        }
        if (!bare) try self.w.writeAll("(");
        try self.emitExpr(items[1]);
        try self.w.print(" {s} ", .{op});
        try self.emitExpr(items[2]);
        if (!bare) try self.w.writeAll(")");
    }

    /// `/` truncates toward zero for integers (`@divTrunc`); `%` is the
    /// remainder with the dividend's sign (`@rem`), for integers and
    /// floats alike. Float `/` is ordinary division.
    fn emitDivision(self: *Emitter, items: []const Sexp, builtin: []const u8) Error!void {
        if (items[0].tag == .@"/" and (self.isFloatExpr(items[1]) or self.isFloatExpr(items[2]))) {
            return self.emitInfix(items, false);
        }
        try self.w.print("{s}(", .{builtin});
        try self.emitExpr(items[1]);
        try self.w.writeAll(", ");
        try self.emitExpr(items[2]);
        try self.w.writeAll(")");
    }

    /// `x |> f` → `f(x)`; `x |> f(a)` → `f(x, a)`.
    fn emitPipe(self: *Emitter, items: []const Sexp) Error!void {
        const arg = items[1];
        const f = items[2];
        if (isTagged(f, .@"call")) {
            var call: std.ArrayListUnmanaged(Sexp) = .empty;
            try call.appendSlice(self.arena.allocator(), f.list[0..2]);
            try call.append(self.arena.allocator(), arg);
            try call.appendSlice(self.arena.allocator(), f.list[2..]);
            return self.emitCall(.{ .list = call.items });
        }
        return self.emitCall(try self.list(&.{ .{ .tag = .@"call" }, f, arg }));
    }

    /// `.{ .a = x, ... }` / `Name{ ... }` from kwargs or positional args.
    fn emitFieldInit(self: *Emitter, prefix: []const u8, args: []const Sexp) Error!void {
        try self.w.print("{s}{{", .{prefix});
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (isTagged(a, .@"kwarg")) {
                try self.w.print(".{f} = ", .{self.ident(self.text(a.list[1]) orelse "_")});
                try self.emitExpr(a.list[2]);
            } else {
                try self.emitBare(a);
            }
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// `[a, b, c]` → `[_]T{ a, b, c }`.
    fn emitArray(self: *Emitter, items: []const Sexp) Error!void {
        const elems = items[1..];
        try self.w.writeAll("[_]");
        if (self.expected) |t| if (self.arrayElemTy(t)) |elem| {
            try self.emitTypeTy(elem);
        } else try self.emitLiteralElemType(elems) else try self.emitLiteralElemType(elems);
        try self.w.writeAll("{");
        for (elems, 0..) |e, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitExpr(e);
        }
        try self.w.writeAll(if (elems.len > 0) " }" else "}");
    }

    fn emitLiteralElemType(self: *Emitter, elems: []const Sexp) Error!void {
        if (elems.len > 0) if (self.typeOf(elems[0])) |t| return self.emitTypeTy(t);
        if (elems.len > 0 and self.isFloatExpr(elems[0])) return self.w.writeAll("f32");
        try self.w.writeAll("i32");
    }

    /// `x[i]`: bounds-checked element of an array, slice, string, or
    /// `Vec` of plain data. As a place, a `Vec` element is `x.slot(i).*`.
    fn emitIndex(self: *Emitter, items: []const Sexp, as_place: bool) Error!void {
        const base = items[1];
        const index = items[2];
        const base_ty = self.typeOf(base);
        if (base_ty != null and self.isVecTy(base_ty.?)) {
            try self.emitExpr(base);
            try self.w.writeAll(if (as_place) ".slot(" else ".at(");
            try self.emitExpr(index);
            try self.w.writeAll(if (as_place) ").*" else ")");
            return;
        }
        try self.emitExpr(base);
        try self.w.writeAll("[");
        if (isNonNegativeIntLiteral(self.source, index)) {
            try self.emitExpr(index);
        } else {
            try self.w.writeAll("rig.index(");
            try self.emitExpr(index);
            try self.w.writeAll(", ");
            try self.emitExpr(base);
            try self.w.writeAll(".len)");
        }
        try self.w.writeAll("]");
    }

    /// `(member obj name)`. A shared handle auto-dereferences through
    /// `.value`; `.len` of an array, slice, or string is an `Int`.
    fn emitMember(self: *Emitter, items: []const Sexp) Error!void {
        const obj = items[1];
        const field = self.text(items[2]) orelse return self.unsupported(items[2], "this member");
        const obj_ty = self.typeOf(obj);
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
    fn emitMemberBase(self: *Emitter, obj: Sexp, obj_ty: ?Ty) Error!void {
        var o = obj;
        while (isTagged(o, .@"read") or isTagged(o, .@"write")) o = o.list[1];
        if (o == .src) if (self.lookup(self.srcText(o))) |local| {
            if (local.is_ptr and obj_ty != null and self.isStructLike(obj_ty.?)) return self.w.writeAll(local.zig_name);
            return self.writeLocalPlace(local);
        };
        const needs_parens = o == .list and o.list.len > 0 and o.list[0] == .tag and switch (o.list[0].tag) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"neg", .@"not", .@"ternary", .@"if", .@"match", .@"??", .@"catch", .@"try", .@"propagate" => true,
            else => false,
        };
        if (needs_parens) try self.w.writeAll("(");
        try self.emitExpr(o);
        if (needs_parens) try self.w.writeAll(")");
    }

    /// `@name(args)`. Arguments that name Rig types are spelled as Zig types.
    fn emitBuiltin(self: *Emitter, items: []const Sexp) Error!void {
        try self.w.print("@{s}(", .{self.text(items[1]) orelse "_"});
        for (items[2..], 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (self.isTypeArg(a)) try self.emitType(a) else try self.emitBare(a);
        }
        try self.w.writeAll(")");
    }

    fn isTypeArg(self: *Emitter, a: Sexp) bool {
        if (isTagged(a, .@"generic_inst") or isTagged(a, .@"shared") or isTagged(a, .@"optional")) return true;
        if (a != .src) return false;
        const name = self.srcText(a);
        if (self.lookup(name) != null) return false;
        if (!std.mem.eql(u8, mapTypeName(name), name)) return true;
        const sema = self.sema orelse return false;
        const id = sema.lookup(1, name) orelse return false;
        return switch (sema.symbols.items[id].kind) {
            .nominal_type, .type_alias, .generic_type => true,
            else => false,
        };
    }

    /// `*expr`: move `expr` into a new reference-counted box.
    fn emitShare(self: *Emitter, inner: Sexp) Error!void {
        if (classifyOwnedClosure(self.source, inner)) |info| return self.emitOwnedClosure(info);
        const payload_ty: ?Ty = if (self.expected) |t| self.sharedInner(t) else null;
        const saved = self.expected;
        defer self.expected = saved;
        self.expected = payload_ty;
        try self.w.writeAll("rig.rcNew(");
        if (payload_ty != null and self.needsTypedPayload(inner)) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(payload_ty.?);
            try self.w.writeAll(", ");
            try self.emitExpr(inner);
            try self.w.writeAll(")");
        } else {
            try self.emitExpr(inner);
        }
        try self.w.writeAll(")");
    }

    /// True when `inner` lowers to an expression whose Zig type comes
    /// from its result location (an anonymous or decl literal, a number).
    fn needsTypedPayload(self: *Emitter, inner: Sexp) bool {
        if (inner == .src) return isLiteralText(self.srcText(inner));
        if (isTagged(inner, .@"enum_lit") or isTagged(inner, .@"anon_init") or isTagged(inner, .@"array")) return true;
        if (!isTagged(inner, .@"call")) return false;
        const callee = inner.list[1];
        if (isTagged(callee, .@"enum_lit")) return true;
        if (callee != .src) return false;
        const name = self.srcText(callee);
        return std.mem.eql(u8, name, "Vec") or std.mem.eql(u8, name, "Signal");
    }

    // -------------------------------------------------------------------------
    // Value-position blocks and branches
    // -------------------------------------------------------------------------

    /// `(if cond then else)` as a value.
    fn emitIfExpr(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        if (items.len != 4) return self.unsupported(sexp, "an `if` without `else` in value position");
        try self.pushScope();
        try self.w.writeAll("if ");
        try self.emitCond(items[1]);
        try self.emitValueBlock(items[2], &.{});
        try self.popScope();
        try self.w.writeAll(" else ");
        try self.emitValueBlock(items[3], &.{});
    }

    /// A block that yields its last expression: inline when it is a
    /// single expression, otherwise a labeled block. The value leaves the
    /// block, so a resource binding in tail position is moved out. A block ending in
    /// `return`/`break`/`continue` yields nothing and needs no label.
    fn emitValueBlock(self: *Emitter, body: Sexp, aliases: []const Alias) Error!void {
        const stmts = try self.stmtsOf(body);
        if (stmts.len == 0) return self.unsupported(body, "an empty block in value position");
        const last = stmts[stmts.len - 1];
        if (stmts.len == 1 and aliases.len == 0 and isValueStmt(last)) return self.emitValue(last, true);

        const terminates = isTerminatingStmt(last);
        if (!terminates and !isValueStmt(last)) return self.unsupported(last, "a block without a value in value position");
        var label: []const u8 = "";
        if (!terminates) {
            label = try self.fmt("rig_blk_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
        }
        try self.openBrace();
        for (aliases) |a| try self.line("const {s} = __rig_payload.{f};", .{ a.zig_name, self.ident(a.field) });
        try self.emitStmtRange(stmts, stmts.len - 1);
        try self.writeIndent(self.indent);
        if (terminates) {
            try self.emitLastStmt(last);
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
        return call.list.len >= 2 and call.list[1] == .src and std.mem.eql(u8, self.srcText(call.list[1]), "print") and
            self.lookup("print") == null;
    }

    fn emitCall(self: *Emitter, sexp: Sexp) Error!void {
        const items = sexp.list;
        const callee = items[1];
        const args = items[2..];

        if (self.isPrintCall(sexp)) return self.emitPrint(args);

        if (callee == .src) {
            const name = self.srcText(callee);
            if (self.lookup(name)) |local| switch (local.callable) {
                .stack_closure => return self.emitInvoke(local.zig_name, ".invoke(", args),
                .owned_closure => return self.emitInvoke(try self.placeText(local), ".value.invoke(", args),
                .none => {},
            };
            if (std.mem.eql(u8, name, "Vec") and self.lookup(name) == null) return self.emitVecConstruction(args);
            if (std.mem.eql(u8, name, "Signal") and self.lookup(name) == null) return self.emitSignalConstruction(args);
        }
        if (isTagged(callee, .@"enum_lit")) return self.emitVariantLit(callee.list[1], args);

        // A closure-typed field or other expression: `self.cb()`.
        if (!(callee == .src)) if (self.typeOf(callee)) |t| {
            if (self.isOwnedClosureTy(t)) {
                try self.emitExpr(callee);
                try self.w.writeAll(".value.invoke(");
                try self.emitArgList(args, null, 0);
                try self.w.writeAll(")");
                return;
            }
        };

        // Constructors.
        if (callee == .src) if (self.sema) |sema| if (sema.lookup(1, self.srcText(callee))) |sym_id| {
            switch (sema.symbols.items[sym_id].kind) {
                .nominal_type, .type_alias => {
                    try self.w.print("{f}", .{self.ident(self.srcText(callee))});
                    return self.emitConstructorFields(args, sym_id);
                },
                .generic_type => return self.emitConstructorFields(args, sym_id),
                else => {},
            }
        };
        if (callee == .src and self.lookup(self.srcText(callee)) == null and self.sema == null and hasKwarg(args)) {
            try self.w.print("{f}", .{self.ident(self.srcText(callee))});
            return self.emitFieldInit("", args);
        }

        // Function and method calls.
        const params = self.calleeParams(callee);
        const skip_self = params != null and isTagged(callee, .@"member") and paramsStartWithSelf(self.source, params.?);
        if (params != null and hasKwarg(args)) {
            const plist = paramSlice(params, if (skip_self) 1 else 0);
            const slots = try self.matchArgs(args, plist);
            if (reordersEffects(slots, args)) return self.emitCallInSourceOrder(callee, args, plist, slots);
        }
        if (isTagged(callee, .@"member")) {
            try self.emitMember(callee.list);
        } else {
            try self.emitExpr(callee);
        }
        try self.w.writeAll("(");
        try self.emitArgList(args, params, if (skip_self) 1 else 0);
        try self.w.writeAll(")");
    }

    fn placeText(self: *Emitter, local: *const Local) Error![]const u8 {
        return if (local.is_ptr) self.fmt("{s}.*", .{local.zig_name}) else local.zig_name;
    }

    fn emitInvoke(self: *Emitter, target: []const u8, method: []const u8, args: []const Sexp) Error!void {
        try self.w.print("{s}{s}", .{ target, method });
        try self.emitArgList(args, null, 0);
        try self.w.writeAll(")");
    }

    /// Arguments in parameter order. Keyword arguments are matched to
    /// parameter names and omitted parameters take their defaults.
    fn emitArgList(self: *Emitter, args: []const Sexp, params: ?Sexp, skip: usize) Error!void {
        const plist = paramSlice(params, skip);
        if (params == null or (!hasKwarg(args) and args.len >= plist.len)) {
            if (params == null and hasKwarg(args)) return self.unsupported(args[0], "keyword arguments to this callee");
            for (args, 0..) |a, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.emitArg(a, if (i < plist.len) plist[i] else null);
            }
            return;
        }
        try self.emitMatchedArgs(args, plist, try self.matchArgs(args, plist), null);
    }

    /// For each parameter, the index of the argument bound to it, or null
    /// when it takes its default.
    fn matchArgs(self: *Emitter, args: []const Sexp, plist: []const Sexp) Error![]const ?usize {
        const slots = try self.arena.allocator().alloc(?usize, plist.len);
        @memset(slots, null);
        var positional: usize = 0;
        for (args, 0..) |a, ai| {
            if (isTagged(a, .@"kwarg")) {
                const kname = self.text(a.list[1]) orelse continue;
                for (plist, 0..) |p, i| {
                    const pn = paramNameNode(p) orelse continue;
                    if (std.mem.eql(u8, self.text(pn) orelse "", kname)) slots[i] = ai;
                }
            } else {
                if (positional < slots.len) slots[positional] = ai;
                positional += 1;
            }
        }
        return slots;
    }

    fn emitMatchedArgs(self: *Emitter, args: []const Sexp, plist: []const Sexp, slots: []const ?usize, temps: ?[]const ?[]const u8) Error!void {
        for (plist, slots, 0..) |p, slot, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (slot) |ai| {
                if (temps) |t| if (t[ai]) |name| {
                    try self.w.writeAll(name);
                    continue;
                };
                try self.emitArg(args[ai], p);
            } else if (isTagged(p, .@"default") and p.list.len >= 4) {
                try self.emitBare(p.list[3]);
            } else {
                return self.unsupported(if (args.len > 0) args[0] else p, "a call missing an argument");
            }
        }
    }

    /// Whether binding keyword arguments reorders two arguments that
    /// have side effects, which must then run in source order.
    fn reordersEffects(slots: []const ?usize, args: []const Sexp) bool {
        var last: ?usize = null;
        for (slots) |slot| {
            const ai = slot orelse continue;
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
    fn emitCallInSourceOrder(self: *Emitter, callee: Sexp, args: []const Sexp, plist: []const Sexp, slots: []const ?usize) Error!void {
        const id = self.nextId();
        const temps = try self.arena.allocator().alloc(?[]const u8, args.len);
        @memset(temps, null);
        try self.w.print("rig_call_{d}: {{\n", .{id});
        self.indent += 1;
        for (args, 0..) |a, ai| {
            if (isPureArg(a)) continue;
            const param: ?Sexp = for (slots, 0..) |s, pi| {
                if (s == ai) break plist[pi];
            } else null;
            const name = try self.fmt("__rig_arg_{d}_{d}", .{ id, ai });
            temps[ai] = name;
            try self.writeIndent(self.indent);
            try self.w.print("const {s}", .{name});
            if (param) |p| if (p == .list and p.list.len >= 3 and (isTagged(p, .@":") or isTagged(p, .@"default"))) {
                try self.w.writeAll(": ");
                try self.emitParamType(p.list[2]);
            };
            try self.w.writeAll(" = ");
            try self.emitArg(a, param);
            try self.w.writeAll(";\n");
        }
        try self.writeIndent(self.indent);
        try self.w.print("break :rig_call_{d} ", .{id});
        if (isTagged(callee, .@"member")) try self.emitMember(callee.list) else try self.emitExpr(callee);
        try self.w.writeAll("(");
        try self.emitMatchedArgs(args, plist, slots, temps);
        try self.w.writeAll(");\n");
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    fn emitArg(self: *Emitter, arg: Sexp, param: ?Sexp) Error!void {
        const saved = self.expected;
        defer self.expected = saved;
        self.expected = if (param) |p| (if (paramNameNode(p)) |n| self.declTy(n) else null) else null;
        if (self.expected) |t| self.expected = self.peelBorrows(t);
        try self.emitBare(if (isTagged(arg, .@"kwarg")) arg.list[2] else arg);
    }

    /// Parameter list of the function or method a callee names.
    fn calleeParams(self: *Emitter, callee: Sexp) ?Sexp {
        if (callee == .src) {
            if (self.lookup(self.srcText(callee)) != null) return null;
            return self.module.funs.get(self.srcText(callee));
        }
        if (!isTagged(callee, .@"member")) return null;
        const method = self.text(callee.list[2]) orelse return null;
        var obj = callee.list[1];
        while (isTagged(obj, .@"read") or isTagged(obj, .@"write") or isTagged(obj, .@"move")) obj = obj.list[1];
        const type_name: []const u8 = blk: {
            if (obj == .src and self.lookup(self.srcText(obj)) == null) break :blk self.srcText(obj);
            const t = self.typeOf(obj) orelse return null;
            const sym = self.nominalSym(t) orelse return null;
            break :blk self.sema.?.symbols.items[sym].name;
        };
        const key = std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ type_name, method }) catch return null;
        return self.module.methods.get(key);
    }

    /// Constructor call `Name(field: v, ...)`: a struct literal. For a
    /// generic type the literal is anonymous and takes its type from
    /// the result location.
    fn emitConstructorFields(self: *Emitter, args: []const Sexp, sym_id: types.SymbolId) Error!void {
        const sema = self.sema.?;
        const sym = sema.symbols.items[sym_id];
        const is_generic = sym.kind == .generic_type;
        if (!is_generic) {
            try self.w.writeAll("{");
        } else if (self.expected != null and self.substOf(self.peelBorrows(self.expected.?)).sym == sym_id) {
            // A typed literal reads better than an anonymous one.
            try self.emitTypeTy(self.peelBorrows(self.expected.?));
            try self.w.writeAll("{");
        } else {
            try self.w.writeAll(".{");
        }
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (isTagged(a, .@"kwarg")) {
                const fname = self.text(a.list[1]) orelse "_";
                try self.w.print(".{f} = ", .{self.ident(fname)});
                var field_ty: ?Ty = null;
                if (self.expected) |t| field_ty = self.fieldTy(t, fname);
                if (field_ty == null and !is_generic) {
                    if (sym.fields) |fs| for (fs) |f| {
                        if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, fname)) field_ty = .{ .id = f.ty };
                    };
                }
                try self.emitExprExpecting(a.list[2], field_ty);
            } else {
                try self.emitExpr(a);
            }
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// `Vec()` / `Vec(capacity: n)`: a decl literal typed by its result
    /// location.
    fn emitVecConstruction(self: *Emitter, args: []const Sexp) Error!void {
        for (args) |a| if (isTagged(a, .@"kwarg") and std.mem.eql(u8, self.text(a.list[1]) orelse "", "capacity")) {
            try self.w.writeAll(".initCapacity(rig.defaultAllocator(), ");
            try self.emitExpr(a.list[2]);
            try self.w.writeAll(")");
            return;
        };
        try self.w.writeAll(".init(rig.defaultAllocator())");
    }

    /// `Signal(value: v)`.
    fn emitSignalConstruction(self: *Emitter, args: []const Sexp) Error!void {
        for (args) |a| if (isTagged(a, .@"kwarg") and std.mem.eql(u8, self.text(a.list[1]) orelse "", "value")) {
            try self.w.writeAll(".init(");
            try self.emitExpr(a.list[2]);
            try self.w.writeAll(")");
            return;
        };
        return self.unsupported(if (args.len > 0) args[0] else .nil, "this Signal construction");
    }

    /// `.variant(args)` → `.{ .variant = payload }`. A single-field
    /// payload is the value itself; several fields form a struct.
    fn emitVariantLit(self: *Emitter, name_node: Sexp, args: []const Sexp) Error!void {
        const vname = self.text(name_node) orelse "_";
        if (args.len == 0) return self.w.print(".{f}", .{self.ident(vname)});
        const single = if (self.variantFieldNames(self.expected, vname)) |names| names.len == 1 else self.variantArityAnywhere(vname) == 1;
        try self.w.print(".{{ .{f} = ", .{self.ident(vname)});
        if (single and args.len == 1) {
            const a = args[0];
            try self.emitExprExpecting(if (isTagged(a, .@"kwarg")) a.list[2] else a, self.variantPayloadTy(self.expected, vname, null));
        } else {
            try self.emitFieldInit(".", args);
        }
        try self.w.writeAll(" }");
    }

    /// `print(x)`: strings with `{s}`, everything else with `{any}`.
    fn emitPrint(self: *Emitter, args: []const Sexp) Error!void {
        if (args.len == 0) return self.w.writeAll("rig.print(\"\\n\", .{})");
        const f: []const u8 = if (self.isStringExpr(args[0])) "{s}" else "{any}";
        try self.w.print("rig.print(\"{s}\\n\", .{{", .{f});
        try self.emitBare(args[0]);
        try self.w.writeAll("})");
    }

    // =========================================================================
    // Closures
    // =========================================================================

    /// `f = |captures| body` → a struct holding the captures with an
    /// `invoke` method; calls lower to `f.invoke(...)`. When a capture
    /// owns a resource, the closure is dropped at scope exit, which drops
    /// its fields.
    fn emitClosureBinding(self: *Emitter, name_node: Sexp, lambda: Sexp) Error!void {
        const items = lambda.list;
        const captures = items[1];
        const params = items[2];
        const body = items[4];
        const caps = try self.captureInfo(captures);

        const local = try self.declare(.{ .rig_name = self.srcText(name_node), .zig_name = "", .callable = .stack_closure, .ret = self.lambdaReturn(lambda) });
        const zig_name = local.zig_name;

        try self.w.print("var {s} = struct {{\n", .{zig_name});
        self.indent += 1;
        try self.emitCaptureFields(caps);
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.writeAll("fn invoke(self: *@This()");
        try self.pushScope();
        try self.bindCaptures(caps);
        const saved_fun = self.fun;
        self.fun.returns = null;
        self.fun.return_ty = null;
        self.fun.params = null;
        self.fun.leak_check = false;
        defer self.fun = saved_fun;
        if (params == .list) {
            try self.bindParams(params);
            for (params.list) |p| {
                try self.w.writeAll(", ");
                try self.emitParam(p);
            }
        }
        try self.w.writeAll(") ");
        const ret = self.lambdaReturn(lambda);
        if (ret) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        self.fun.params = params;
        try self.emitClosureBody(body, caps, ret != null);
        try self.popScope();
        try self.w.writeAll("\n");
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";");

        var owns = false;
        for (caps) |c| owns = owns or c.kind != null;
        if (owns) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("defer rig.dropFields(&{s});", .{zig_name});
        } else {
            try self.w.print(" _ = &{s};", .{zig_name});
        }
    }

    const Capture = struct {
        mode: Tag,
        name: []const u8,
        /// The captured binding, copied: scope storage moves as locals are added.
        outer: ?Local,
        /// Resource kind of the captured value inside the closure.
        kind: ?ResourceKind,
        ty: ?Ty,
    };

    fn captureInfo(self: *Emitter, captures: Sexp) Error![]const Capture {
        if (!isTagged(captures, .@"captures")) return &.{};
        var out: std.ArrayListUnmanaged(Capture) = .empty;
        for (captures.list[1..]) |cap| {
            const name_node = captureNameSrc(cap) orelse continue;
            const name = self.srcText(name_node);
            const outer: ?Local = if (self.lookup(name)) |l| l.* else null;
            const mode = cap.list[0].tag;
            var ty: ?Ty = if (outer) |o| o.ty else null;
            if (ty == null) ty = self.findOuterCaptureType(name, name_node.src.pos);
            var kind: ?ResourceKind = if (ty) |t| self.kindOf(t) else null;
            if (mode == .@"cap_weak") kind = .weak;
            try out.append(self.arena.allocator(), .{ .mode = mode, .name = name, .outer = outer, .kind = kind, .ty = ty });
        }
        return out.items;
    }

    fn emitCaptureFields(self: *Emitter, caps: []const Capture) Error!void {
        for (caps) |c| {
            try self.writeIndent(self.indent);
            try self.w.print("cap_{s}: ", .{c.name});
            const t = c.ty orelse return self.unsupported(.nil, "a capture of unknown type");
            if (c.mode == .@"cap_weak") {
                try self.w.writeAll("rig.WeakHandle(");
                try self.emitTypeTy(self.sharedInner(t) orelse t);
                try self.w.writeAll(")");
            } else {
                try self.emitTypeTy(t);
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Declare captures inside a closure body as `self.cap_<name>`.
    fn bindCaptures(self: *Emitter, caps: []const Capture) Error!void {
        for (caps) |c| {
            var ty = c.ty;
            if (c.mode == .@"cap_weak") ty = null;
            _ = try self.declare(.{
                .rig_name = c.name,
                .zig_name = try self.fmt("self.cap_{s}", .{c.name}),
                .ty = ty,
                .callable = if (c.outer) |o| (if (o.callable == .owned_closure) .owned_closure else .none) else .none,
            });
        }
    }

    /// `{ .cap_x = init, ... }` evaluated where the closure is created.
    fn emitCaptureInit(self: *Emitter, caps: []const Capture) Error!void {
        if (caps.len == 0) return self.w.writeAll("{}");
        try self.w.writeAll("{");
        for (caps, 0..) |c, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".cap_{s} = ", .{c.name});
            const outer_name = if (c.outer) |o| try self.placeText(&o) else c.name;
            const outer_kind: ?ResourceKind = if (c.outer) |o| o.kind else null;
            switch (c.mode) {
                .@"cap_clone" => {
                    try self.w.writeAll(outer_name);
                    if (outer_kind) |k| switch (k) {
                        .shared => try self.w.writeAll(".cloneStrong()"),
                        .weak => try self.w.writeAll(".cloneWeak()"),
                        else => {},
                    };
                },
                .@"cap_weak" => try self.w.print("{s}.weakRef()", .{outer_name}),
                .@"cap_move" => if (c.outer) |o| {
                    if (o.guard == .flag) try self.writeTake(&o) else try self.w.writeAll(outer_name);
                } else try self.w.writeAll(outer_name),
                else => try self.w.writeAll(outer_name),
            }
        }
        try self.w.writeAll(" }");
    }

    /// A closure body. Without a capture reference, `self` is discarded.
    fn emitClosureBody(self: *Emitter, body: Sexp, caps: []const Capture, returns_value: bool) Error!void {
        try self.openBrace();
        var uses_self = false;
        for (caps) |c| uses_self = uses_self or usesName(self.source, body, c.name);
        if (!uses_self) try self.line("_ = self;", .{});
        const stmts = try self.stmtsOf(body);
        try self.emitFunPrologue(stmts);
        if (returns_value and isValueStmt(stmts[stmts.len - 1])) {
            try self.emitStmtRange(stmts, stmts.len - 1);
            try self.writeIndent(self.indent);
            try self.w.writeAll("return ");
            try self.emitValue(stmts[stmts.len - 1], true);
            try self.w.writeAll(";\n");
        } else {
            try self.emitStmts(stmts);
        }
        try self.closeBrace();
    }

    /// `*Closure(|captures| body)` (and `Closure1(T)` / `Closure2(A, B)`)
    /// → a heap-allocated environment with `invoke` and `drop` functions,
    /// wrapped in the type-erased runtime closure and boxed:
    ///
    ///     rig_closure_N: {
    ///         const Env_N = struct { cap_x: T, fn invoke(...) ..., fn drop(...) ... };
    ///         const env = rig.create(Env_N);
    ///         env.* = .{ .cap_x = ... };
    ///         break :rig_closure_N rig.rcNew(rig.Closure0{ ... });
    ///     }
    ///
    /// The environment is freed when the last strong handle drops.
    fn emitOwnedClosure(self: *Emitter, info: ClosureCtorInfo) Error!void {
        const items = info.lambda.list;
        const captures = items[1];
        const params = items[2];
        const body = items[4];
        const caps = try self.captureInfo(captures);
        const id = self.nextId();
        const env = try self.fmt("__rig_Env_{d}", .{id});
        const env_ptr = try self.fmt("__rig_env_{d}", .{id});

        try self.w.print("rig_closure_{d}: {{\n", .{id});
        self.indent += 1;
        try self.line("const {s} = struct {{", .{env});
        self.indent += 1;
        try self.emitCaptureFields(caps);

        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.writeAll("fn invoke(ctx: *anyopaque");
        try self.pushScope();
        try self.bindCaptures(caps);
        const saved_fun = self.fun;
        self.fun.returns = null;
        self.fun.return_ty = null;
        self.fun.params = null;
        self.fun.leak_check = false;
        defer self.fun = saved_fun;
        if (params == .list) {
            try self.bindParams(params);
            for (params.list, 0..) |p, i| {
                const pn = paramNameNode(p) orelse continue;
                const local = self.lookupCurrent(self.text(pn) orelse continue) orelse continue;
                try self.w.print(", {s}: ", .{local.zig_name});
                if (i < info.type_args.len) try self.emitType(info.type_args[i]) else try self.emitParamType(p.list[2]);
            }
        }
        try self.w.writeAll(") void ");
        try self.openBrace();
        var uses_self = false;
        for (caps) |c| uses_self = uses_self or usesName(self.source, body, c.name);
        if (uses_self) try self.line("const self: *@This() = @ptrCast(@alignCast(ctx));", .{}) else try self.line("_ = ctx;", .{});
        const stmts = try self.stmtsOf(body);
        self.fun.params = params;
        try self.emitFunPrologue(stmts);
        try self.emitStmts(stmts);
        try self.closeBrace();
        try self.popScope();
        try self.w.writeAll("\n\n");

        try self.line("fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {{", .{});
        try self.line("    const self: *@This() = @ptrCast(@alignCast(ctx));", .{});
        try self.line("    rig.dropFields(self);", .{});
        try self.line("    allocator.destroy(self);", .{});
        try self.line("}}", .{});
        self.indent -= 1;
        try self.line("}};", .{});

        try self.line("const {s} = rig.create({s});", .{ env_ptr, env });
        try self.writeIndent(self.indent);
        try self.w.print("{s}.* = .", .{env_ptr});
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :rig_closure_{d} rig.rcNew(", .{id});
        switch (info.kind) {
            .c0 => try self.w.writeAll("rig.Closure0"),
            .c1 => {
                try self.w.writeAll("rig.Closure1(");
                try self.emitType(info.type_args[0]);
                try self.w.writeAll(")");
            },
            .c2 => {
                try self.w.writeAll("rig.Closure2(");
                try self.emitType(info.type_args[0]);
                try self.w.writeAll(", ");
                try self.emitType(info.type_args[1]);
                try self.w.writeAll(")");
            },
        }
        try self.w.print("{{ .ctx = {s}, .invoke_fn = {s}.invoke, .drop_fn = {s}.drop, .allocator = rig.defaultAllocator() }});\n", .{ env_ptr, env, env });
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    fn lambdaReturn(self: *Emitter, lambda: Sexp) ?Ty {
        const sema = self.sema orelse return null;
        const id = sema.lambda_return_types.get(firstSrcPos(lambda)) orelse return null;
        return switch (sema.types.get(id)) {
            .void, .unknown, .invalid => null,
            else => .{ .id = id },
        };
    }

    /// Type of the closest preceding declaration of `name`: the capture's
    /// outer binding when the emitter has no scope entry for it.
    fn findOuterCaptureType(self: *Emitter, name: []const u8, cap_pos: u32) ?Ty {
        const sema = self.sema orelse return null;
        var best_pos: u32 = 0;
        var best: ?Ty = null;
        for (sema.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (sym.decl_pos == 0 or sym.decl_pos >= cap_pos or sym.decl_pos <= best_pos) continue;
            best_pos = sym.decl_pos;
            best = .{ .id = sym.ty };
        }
        return best;
    }

    // =========================================================================
    // Types
    // =========================================================================

    /// A type expression from the IR.
    fn emitType(self: *Emitter, t: Sexp) Error!void {
        switch (t) {
            .src => {
                const name = self.srcText(t);
                if (std.mem.eql(u8, name, "Self")) if (self.nominal) |n| return self.w.writeAll(n.name);
                const mapped = mapTypeName(name);
                if (mapped.ptr != name.ptr) return self.w.writeAll(mapped);
                if (isBuiltinNominalName(name)) return self.w.print("rig.{s}", .{builtinZigName(name)});
                try self.w.print("{f}", .{self.ident(name)});
            },
            .list => |items| {
                if (items.len == 3 and items[0] == .src and std.mem.eql(u8, self.srcText(items[0]), "(")) {
                    return self.emitType(items[1]);
                }
                if (items.len < 2 or items[0] != .tag) return self.unsupported(t, "this type");
                switch (items[0].tag) {
                    .@"optional" => {
                        try self.w.writeAll("?");
                        try self.emitType(items[1]);
                    },
                    .@"error_union" => {
                        try self.w.writeAll("!");
                        try self.emitType(items[1]);
                    },
                    // A borrow is a pointer only as a parameter (see `emitParamType`).
                    .@"borrow_read", .@"borrow_write" => try self.emitType(items[1]),
                    .@"shared" => {
                        try self.w.writeAll("*rig.RcBox(");
                        try self.emitType(items[1]);
                        try self.w.writeAll(")");
                    },
                    .@"weak" => {
                        try self.w.writeAll("rig.WeakHandle(");
                        try self.emitType(items[1]);
                        try self.w.writeAll(")");
                    },
                    .@"slice" => {
                        try self.w.writeAll("[]const ");
                        try self.emitType(items[1]);
                    },
                    .@"array_type" => {
                        try self.w.writeAll("[");
                        try self.emitExpr(items[1]);
                        try self.w.writeAll("]");
                        try self.emitType(items[2]);
                    },
                    .@"generic_inst" => {
                        const name = self.text(items[1]) orelse return self.unsupported(t, "this type");
                        if (std.mem.eql(u8, name, "Closure")) return self.w.writeAll("rig.Closure0");
                        if (isBuiltinNominalName(name)) try self.w.writeAll("rig.");
                        try self.w.print("{f}(", .{self.ident(name)});
                        for (items[2..], 0..) |arg, i| {
                            if (i > 0) try self.w.writeAll(", ");
                            try self.emitType(arg);
                        }
                        try self.w.writeAll(")");
                    },
                    .@"member" => {
                        try self.emitExpr(items[1]);
                        try self.w.print(".{f}", .{self.ident(self.text(items[2]) orelse "_")});
                    },
                    .@"fun_type" => {
                        try self.w.writeAll("*const fn (");
                        if (items[1] == .list) for (items[1].list, 0..) |p, i| {
                            if (i > 0) try self.w.writeAll(", ");
                            try self.emitType(p);
                        };
                        try self.w.writeAll(") ");
                        if (items.len >= 3 and items[2] != .nil) try self.emitType(items[2]) else try self.w.writeAll("void");
                    },
                    else => return self.unsupported(t, "this type"),
                }
            },
            else => return self.unsupported(t, "this type"),
        }
    }

    /// A sema type, with generic parameters substituted.
    fn emitTypeTy(self: *Emitter, ty0: Ty) Error!void {
        const sema = self.sema.?;
        const ty = self.resolve(ty0);
        switch (sema.types.get(ty.id)) {
            .void => try self.w.writeAll("void"),
            .bool => try self.w.writeAll("bool"),
            .string => try self.w.writeAll("[]const u8"),
            .int_literal => try self.w.writeAll("i32"),
            .float_literal => try self.w.writeAll("f32"),
            .int => |i| if (i.bits == 0) try self.w.writeAll("i32") else try self.w.print("{c}{d}", .{ @as(u8, if (i.signed) 'i' else 'u'), i.bits }),
            .float => |f| try self.w.print("f{d}", .{if (f.bits == 0) @as(u8, 32) else f.bits}),
            .optional => |inner| {
                try self.w.writeAll("?");
                try self.emitTypeTy(.{ .id = inner, .subst = ty.subst });
            },
            .fallible => |inner| {
                try self.w.writeAll("!");
                try self.emitTypeTy(.{ .id = inner, .subst = ty.subst });
            },
            .borrow_read, .borrow_write => |inner| try self.emitTypeTy(.{ .id = inner, .subst = ty.subst }),
            .shared => |inner| {
                try self.w.writeAll("*rig.RcBox(");
                try self.emitTypeTy(.{ .id = inner, .subst = ty.subst });
                try self.w.writeAll(")");
            },
            .weak => |inner| {
                try self.w.writeAll("rig.WeakHandle(");
                try self.emitTypeTy(.{ .id = inner, .subst = ty.subst });
                try self.w.writeAll(")");
            },
            .slice => |s| {
                try self.w.writeAll("[]const ");
                try self.emitTypeTy(.{ .id = s.elem, .subst = ty.subst });
            },
            .array => |a| {
                try self.w.print("[{d}]", .{a.len});
                try self.emitTypeTy(.{ .id = a.elem, .subst = ty.subst });
            },
            .nominal => |sym_id| try self.writeNominalName(sema.symbols.items[sym_id].name),
            .parameterized_nominal => |pn| {
                const name = sema.symbols.items[pn.sym].name;
                if (std.mem.eql(u8, name, "Closure")) return self.w.writeAll("rig.Closure0");
                try self.writeNominalName(name);
                try self.w.writeAll("(");
                for (pn.args, 0..) |arg, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.emitTypeTy(.{ .id = arg, .subst = ty.subst });
                }
                try self.w.writeAll(")");
            },
            .type_var => |sym_id| try self.w.print("{f}", .{self.ident(sema.symbols.items[sym_id].name)}),
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    fn writeNominalName(self: *Emitter, name: []const u8) Error!void {
        if (isBuiltinNominalName(name)) return self.w.print("rig.{s}", .{builtinZigName(name)});
        try self.w.print("{f}", .{self.ident(name)});
    }

    // -------------------------------------------------------------------------
    // Type queries
    // -------------------------------------------------------------------------

    /// The sema type of the binding declared at `name_node`.
    fn declTy(self: *Emitter, name_node: Sexp) ?Ty {
        const sema = self.sema orelse return null;
        if (name_node != .src) return null;
        const name = self.srcText(name_node);
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != name_node.src.pos or !std.mem.eql(u8, sym.name, name)) continue;
            if (sym.ty == sema.types.unknown_id or sym.ty == sema.types.invalid_id) return null;
            return .{ .id = sym.ty };
        }
        return null;
    }

    /// Follow type variables through the substitution.
    fn resolve(self: *Emitter, ty: Ty) Ty {
        const sema = self.sema orelse return ty;
        var t = ty;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            switch (sema.types.get(t.id)) {
                .type_var => |sym| t = .{ .id = t.subst.lookup(sym) orelse return t },
                else => return t,
            }
        }
        return t;
    }

    fn peelBorrows(self: *Emitter, ty: Ty) Ty {
        const sema = self.sema orelse return ty;
        var t = self.resolve(ty);
        while (true) switch (sema.types.get(t.id)) {
            .borrow_read, .borrow_write => |inner| t = self.resolve(.{ .id = inner, .subst = t.subst }),
            else => return t,
        };
    }

    /// Borrows and shared handles peeled: the type whose fields and
    /// methods a member access reaches.
    fn derefTy(self: *Emitter, ty: Ty) Ty {
        const sema = self.sema.?;
        const t = self.peelBorrows(ty);
        return switch (sema.types.get(t.id)) {
            .shared => |inner| self.peelBorrows(.{ .id = inner, .subst = t.subst }),
            else => t,
        };
    }

    /// The type of an expression, when the emitter can tell.
    fn typeOf(self: *Emitter, expr: Sexp) ?Ty {
        const sema = self.sema orelse return null;
        switch (expr) {
            .src => {
                const name = self.srcText(expr);
                if (self.lookup(name)) |local| return local.ty;
                if (name.len > 0 and (name[0] == '"' or name[0] == '\'')) return .{ .id = sema.types.string_id };
                if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) return .{ .id = sema.types.bool_id };
                return null;
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return null;
                return switch (items[0].tag) {
                    .@"read", .@"write", .@"move", .@"clone", .@"pin", .@"raw", .@"propagate", .@"try" => self.typeOf(items[1]),
                    .@"member" => blk: {
                        const obj = self.typeOf(items[1]) orelse break :blk null;
                        break :blk self.fieldTy(obj, self.text(items[2]) orelse break :blk null);
                    },
                    .@"index" => blk: {
                        const obj = self.typeOf(items[1]) orelse break :blk null;
                        break :blk self.elemTy(obj);
                    },
                    .@"call" => self.callReturnTy(items),
                    .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&&", .@"||", .@"not" => .{ .id = sema.types.bool_id },
                    .@"+", .@"-", .@"*", .@"/", .@"%", .@"neg" => self.typeOf(items[1]),
                    else => null,
                };
            },
            else => return null,
        }
    }

    fn callReturnTy(self: *Emitter, items: []const Sexp) ?Ty {
        const sema = self.sema.?;
        const callee = items[1];
        const fn_ty: Ty = blk: {
            if (callee == .src) {
                const name = self.srcText(callee);
                if (self.lookup(name)) |local| return switch (local.callable) {
                    .stack_closure => local.ret orelse .{ .id = sema.types.void_id },
                    .owned_closure => .{ .id = sema.types.void_id },
                    .none => null,
                };
                const id = sema.lookup(1, name) orelse return null;
                if (sema.symbols.items[id].kind != .function) return null;
                break :blk .{ .id = sema.symbols.items[id].ty };
            }
            if (!isTagged(callee, .@"member")) return null;
            const mname = self.text(callee.list[2]) orelse return null;
            var obj = callee.list[1];
            while (isTagged(obj, .@"read") or isTagged(obj, .@"write") or isTagged(obj, .@"move")) obj = obj.list[1];
            if (obj == .src and self.lookup(self.srcText(obj)) == null) {
                const id = sema.lookup(1, self.srcText(obj)) orelse return null;
                const sym = sema.symbols.items[id];
                const fields = sym.fields orelse return null;
                for (fields) |f| if (f.is_method and std.mem.eql(u8, f.name, mname)) break :blk .{ .id = f.ty };
                return null;
            }
            const recv = self.typeOf(obj) orelse return null;
            break :blk self.methodTy(recv, mname) orelse return null;
        };
        return switch (sema.types.get(fn_ty.id)) {
            .function => |f| .{ .id = f.returns, .subst = fn_ty.subst },
            else => null,
        };
    }

    /// The generic substitution of a nominal instance.
    fn substOf(self: *Emitter, ty: Ty) struct { sym: types.SymbolId, subst: types.TypeSubst } {
        const sema = self.sema.?;
        return switch (sema.types.get(ty.id)) {
            .nominal => |s| .{ .sym = s, .subst = .empty },
            .parameterized_nominal => |pn| .{ .sym = pn.sym, .subst = .{
                .params = sema.symbols.items[pn.sym].type_params orelse &.{},
                .args = pn.args,
            } },
            else => .{ .sym = types.symbol_invalid, .subst = .empty },
        };
    }

    fn nominalSym(self: *Emitter, ty: Ty) ?types.SymbolId {
        const s = self.substOf(self.derefTy(ty));
        return if (s.sym == types.symbol_invalid) null else s.sym;
    }

    fn fieldTy(self: *Emitter, owner: Ty, name: []const u8) ?Ty {
        const sema = self.sema orelse return null;
        const o = self.substOf(self.derefTy(owner));
        if (o.sym == types.symbol_invalid) return null;
        const fields = sema.symbols.items[o.sym].fields orelse return null;
        for (fields) |f| {
            if (f.is_method or f.is_variant or f.is_drop_method) continue;
            if (std.mem.eql(u8, f.name, name)) return self.resolve(.{ .id = f.ty, .subst = o.subst });
        }
        return null;
    }

    fn methodTy(self: *Emitter, owner: Ty, name: []const u8) ?Ty {
        const sema = self.sema orelse return null;
        const o = self.substOf(self.derefTy(owner));
        if (o.sym == types.symbol_invalid) return null;
        const fields = sema.symbols.items[o.sym].fields orelse return null;
        for (fields) |f| {
            if (f.is_method and std.mem.eql(u8, f.name, name)) return .{ .id = f.ty, .subst = o.subst };
        }
        return null;
    }

    fn variantOf(self: *Emitter, scrut: ?Ty, vname: []const u8) ?struct { fields: []const types.Field, subst: types.TypeSubst } {
        const sema = self.sema orelse return null;
        const t = scrut orelse return null;
        const o = self.substOf(self.derefTy(t));
        if (o.sym == types.symbol_invalid) return null;
        const fields = sema.symbols.items[o.sym].fields orelse return null;
        for (fields) |f| {
            if (f.is_variant and std.mem.eql(u8, f.name, vname)) return .{ .fields = f.payload orelse &.{}, .subst = o.subst };
        }
        return null;
    }

    fn variantFieldNames(self: *Emitter, scrut: ?Ty, vname: []const u8) ?[]const []const u8 {
        const v = self.variantOf(scrut, vname) orelse return self.variantNamesAnywhere(vname);
        const out = self.arena.allocator().alloc([]const u8, v.fields.len) catch return null;
        for (v.fields, 0..) |f, i| out[i] = f.name;
        return out;
    }

    /// Payload type of a variant: its single field, or the named one.
    fn variantPayloadTy(self: *Emitter, scrut: ?Ty, vname: []const u8, field: ?[]const u8) ?Ty {
        const v = self.variantOf(scrut, vname) orelse return null;
        for (v.fields) |f| {
            if (field == null or std.mem.eql(u8, f.name, field.?)) return self.resolve(.{ .id = f.ty, .subst = v.subst });
        }
        return null;
    }

    /// Payload field names of the first enum declaring `vname`; used
    /// when the scrutinee's type is unknown.
    fn variantNamesAnywhere(self: *Emitter, vname: []const u8) ?[]const []const u8 {
        const sema = self.sema orelse return null;
        for (sema.symbols.items) |sym| {
            if (sym.kind != .nominal_type and sym.kind != .generic_type) continue;
            const fields = sym.fields orelse continue;
            for (fields) |v| {
                if (!v.is_variant or !std.mem.eql(u8, v.name, vname)) continue;
                const payload = v.payload orelse continue;
                const out = self.arena.allocator().alloc([]const u8, payload.len) catch return null;
                for (payload, 0..) |f, i| out[i] = f.name;
                return out;
            }
        }
        return null;
    }

    fn variantArityAnywhere(self: *Emitter, vname: []const u8) usize {
        const names = self.variantNamesAnywhere(vname) orelse return 0;
        return names.len;
    }

    fn elemTy(self: *Emitter, ty: Ty) ?Ty {
        const sema = self.sema orelse return null;
        const t = self.derefTy(ty);
        return switch (sema.types.get(t.id)) {
            .array => |a| self.resolve(.{ .id = a.elem, .subst = t.subst }),
            .slice => |s| self.resolve(.{ .id = s.elem, .subst = t.subst }),
            .parameterized_nominal => |pn| if (pn.sym == sema.vec_sym_id and pn.args.len == 1)
                self.resolve(.{ .id = pn.args[0], .subst = t.subst })
            else
                null,
            else => null,
        };
    }

    fn arrayElemTy(self: *Emitter, ty: Ty) ?Ty {
        const sema = self.sema orelse return null;
        const t = self.peelBorrows(ty);
        return switch (sema.types.get(t.id)) {
            .array => |a| self.resolve(.{ .id = a.elem, .subst = t.subst }),
            else => null,
        };
    }

    fn optionalChild(self: *Emitter, ty: Ty) ?Ty {
        const sema = self.sema orelse return null;
        const t = self.peelBorrows(ty);
        return switch (sema.types.get(t.id)) {
            .optional => |inner| self.resolve(.{ .id = inner, .subst = t.subst }),
            else => null,
        };
    }

    fn sharedInner(self: *Emitter, ty: Ty) ?Ty {
        const sema = self.sema orelse return null;
        const t = self.resolve(ty);
        return switch (sema.types.get(t.id)) {
            .shared => |inner| self.resolve(.{ .id = inner, .subst = t.subst }),
            else => null,
        };
    }

    /// How a value of this type is released, or null for plain data.
    fn kindOf(self: *Emitter, ty0: Ty) ?ResourceKind {
        const sema = self.sema orelse return null;
        const ty = self.resolve(ty0);
        return switch (sema.types.get(ty.id)) {
            .shared => .shared,
            .weak => .weak,
            .optional => |inner| if (self.kindOf(.{ .id = inner, .subst = ty.subst }) != null) .optional else null,
            .nominal, .parameterized_nominal => if (types.typeHasDropGlue(sema, ty.id)) .value else null,
            else => null,
        };
    }

    fn isSharedTy(self: *Emitter, ty: Ty) bool {
        const t = self.peelBorrows(ty);
        return self.sema.?.types.get(t.id) == .shared;
    }

    fn isOwnedClosureTy(self: *Emitter, ty: Ty) bool {
        const sema = self.sema orelse return false;
        const inner = self.sharedInner(self.peelBorrows(ty)) orelse return false;
        const sym = switch (sema.types.get(inner.id)) {
            .nominal => |s| s,
            .parameterized_nominal => |pn| pn.sym,
            else => return false,
        };
        return sym != types.symbol_invalid and
            (sym == sema.closure_sym_id or sym == sema.closure1_sym_id or sym == sema.closure2_sym_id);
    }

    fn isBuiltinInstance(self: *Emitter, ty: Ty, sym_id: types.SymbolId) bool {
        const sema = self.sema orelse return false;
        const t = self.peelBorrows(ty);
        return switch (sema.types.get(t.id)) {
            .parameterized_nominal => |pn| pn.sym == sym_id,
            .nominal => |s| s == sym_id,
            else => false,
        };
    }

    fn isVecTy(self: *Emitter, ty: Ty) bool {
        return self.isBuiltinInstance(ty, self.sema.?.vec_sym_id);
    }

    fn isCellTy(self: *Emitter, ty: Ty) bool {
        return self.isBuiltinInstance(ty, self.sema.?.cell_sym_id);
    }

    fn isStructLike(self: *Emitter, ty: Ty) bool {
        const t = self.peelBorrows(ty);
        return switch (self.sema.?.types.get(t.id)) {
            .nominal, .parameterized_nominal => true,
            else => false,
        };
    }

    fn hasLen(self: *Emitter, ty: Ty) bool {
        const t = self.peelBorrows(ty);
        return switch (self.sema.?.types.get(t.id)) {
            .array, .slice, .string => true,
            else => false,
        };
    }

    fn isNumericOrBool(self: *Emitter, ty: Ty) bool {
        return switch (self.sema.?.types.get(self.resolve(ty).id)) {
            .int, .float, .int_literal, .float_literal, .bool => true,
            else => false,
        };
    }

    fn isErrorSetTy(self: *Emitter, ty: Ty) bool {
        const sym = self.nominalSym(ty) orelse return false;
        return self.module.error_sets.contains(self.sema.?.symbols.items[sym].name);
    }

    fn isErrorSetNode(self: *Emitter, node: Sexp) bool {
        return node == .src and self.module.error_sets.contains(self.srcText(node));
    }

    fn isStringExpr(self: *Emitter, expr: Sexp) bool {
        const ty = self.typeOf(expr) orelse return false;
        return self.sema.?.types.get(self.peelBorrows(ty).id) == .string;
    }

    fn isFloatExpr(self: *Emitter, expr: Sexp) bool {
        if (expr == .src) {
            const t = self.srcText(expr);
            if (t.len > 0 and std.ascii.isDigit(t[0]) and std.mem.indexOfAny(u8, t, ".eE") != null and
                !std.mem.startsWith(u8, t, "0x")) return true;
        }
        const ty = self.typeOf(expr) orelse return false;
        return switch (self.sema.?.types.get(self.resolve(ty).id)) {
            .float, .float_literal => true,
            else => false,
        };
    }

    fn returnTy(self: *Emitter) ?Ty {
        return self.fun.return_ty;
    }

    /// The declared return type of the function or method named at `name_node`.
    fn funReturnTy(self: *Emitter, name_node: Sexp) ?Ty {
        const sema = self.sema orelse return null;
        if (name_node != .src) return null;
        const fn_ty: types.TypeId = blk: {
            if (self.declTy(name_node)) |t| break :blk t.id;
            for (sema.symbols.items) |sym| {
                const fields = sym.fields orelse continue;
                for (fields) |f| if (f.is_method and f.decl_pos == name_node.src.pos) break :blk f.ty;
            }
            return null;
        };
        return switch (sema.types.get(fn_ty)) {
            .function => |f| .{ .id = f.returns },
            else => null,
        };
    }

    fn vecInfo(self: *Emitter, source: Sexp) ?types.VecIterInfo {
        const sema = self.sema orelse return null;
        if (source != .src) return null;
        return sema.for_source_vec_info.get(source.src.pos);
    }

    // =========================================================================
    // Function scan
    // =========================================================================

    /// Pre-scan a function body: which bindings need `var`, and which
    /// names the body may consume.
    fn scanFunction(self: *Emitter, params: ?Sexp, body: Sexp, returns_value: bool) Error!void {
        var scan: Scan = .{ .e = self };
        defer scan.deinit();
        try scan.push();
        if (params) |p| try scan.declareParams(p);
        try scan.walk(body);
        if (returns_value) {
            const stmts = try self.stmtsOf(body);
            if (stmts.len > 0) try scan.consumeAll(stmts[stmts.len - 1]);
        }
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

    fn list(self: *Emitter, items: []const Sexp) Error!Sexp {
        return .{ .list = try self.arena.allocator().dupe(Sexp, items) };
    }

    fn writeIndent(self: *Emitter, depth: u32) Error!void {
        for (0..depth) |_| try self.w.writeAll("    ");
    }

    /// One indented line.
    fn line(self: *Emitter, comptime f: []const u8, args: anytype) Error!void {
        try self.writeIndent(self.indent);
        try self.w.print(f ++ "\n", args);
    }

    /// A Rig single-quoted string as a Zig string literal.
    fn writeSingleQuoted(self: *Emitter, lit: []const u8) Error!void {
        try self.w.writeAll("\"");
        const inner = lit[1 .. lit.len - 1];
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '\\' and i + 1 < inner.len and inner[i + 1] == '\'') {
                try self.w.writeAll("'");
                i += 1;
            } else if (c == '"') {
                try self.w.writeAll("\\\"");
            } else {
                try self.w.writeByte(c);
            }
        }
        try self.w.writeAll("\"");
    }

    /// Report a construct the emitter cannot lower. Sema is responsible
    /// for rejecting it with a proper diagnostic; reaching this is a
    /// compiler bug.
    fn unsupported(self: *Emitter, node: Sexp, what: []const u8) Error {
        const pos = firstSrcPos(node);
        var line_no: usize = 1;
        var col: usize = 1;
        for (self.source[0..@min(pos, self.source.len)]) |c| {
            if (c == '\n') {
                line_no += 1;
                col = 1;
            } else col += 1;
        }
        std.debug.print("{d}:{d}: internal error: cannot emit {s} (sema should reject it)\n", .{ line_no, col, what });
        return error.Unsupported;
    }
};

// =============================================================================
// Function scan
// =============================================================================

/// Walks a function body tracking Rig scopes, to find the declarations
/// that need Zig `var` and the names that may be consumed.
const Scan = struct {
    e: *Emitter,
    scopes: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(u32)) = .empty,

    fn deinit(s: *Scan) void {
        for (s.scopes.items) |*m| m.deinit(s.e.allocator);
        s.scopes.deinit(s.e.allocator);
    }

    fn push(s: *Scan) Error!void {
        try s.scopes.append(s.e.allocator, .empty);
    }

    fn pop(s: *Scan) void {
        var m = s.scopes.pop().?;
        m.deinit(s.e.allocator);
    }

    fn declare(s: *Scan, node: Sexp) Error!void {
        if (node != .src) return;
        try s.scopes.items[s.scopes.items.len - 1].put(s.e.allocator, s.e.srcText(node), node.src.pos);
    }

    fn declareParams(s: *Scan, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.list) |p| if (paramNameNode(p)) |n| try s.declare(n);
    }

    fn visible(s: *Scan, name: []const u8) ?u32 {
        var i = s.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (s.scopes.items[i].get(name)) |pos| return pos;
        }
        return null;
    }

    /// The binding a place is rooted in needs `var`.
    fn mutate(s: *Scan, place: Sexp) Error!void {
        var p = place;
        while (p == .list and p.list.len >= 2 and p.list[0] == .tag) switch (p.list[0].tag) {
            .@"member", .@"index", .@"read", .@"write", .@"move" => p = p.list[1],
            else => return,
        };
        if (p != .src) return;
        if (s.visible(s.e.srcText(p))) |pos| try s.e.fun.mutated.put(s.e.allocator, pos, {});
    }

    fn consume(s: *Scan, node: Sexp) Error!void {
        if (node == .src) try s.e.fun.consumed.put(s.e.allocator, s.e.srcText(node), {});
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
            .list => |items| for (items) |c| try s.consumeAll(c),
            else => {},
        }
    }

    fn walkBlock(s: *Scan, items: []const Sexp) Error!void {
        try s.push();
        defer s.pop();
        for (items) |c| try s.walk(c);
    }

    fn walk(s: *Scan, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0) return;
        const items = sexp.list;
        if (items[0] != .tag) {
            for (items) |c| try s.walk(c);
            return;
        }
        switch (items[0].tag) {
            .@"block" => try s.walkBlock(items[1..]),
            .@"set" => {
                if (items.len < 5) return;
                try s.walk(items[4]);
                const kind = try rig.bindingKindOf(items[1]);
                const target = items[2];
                if (kind == .move) try s.consume(items[4]);
                if (target != .src) {
                    try s.mutate(target);
                    try s.walk(target);
                    return;
                }
                switch (kind) {
                    .@"+=", .@"-=", .@"*=", .@"/=" => try s.mutate(target),
                    .default, .move => if (s.visible(s.e.srcText(target)) != null) try s.mutate(target) else try s.declare(target),
                    .fixed, .shadow => try s.declare(target),
                }
            },
            .@"write" => {
                try s.mutate(items[1]);
                try s.walk(items[1]);
            },
            .@"move", .@"drop" => {
                try s.consume(items[1]);
                try s.walk(items[1]);
            },
            .@"return", .@"break" => {
                if (items.len >= 2) try s.consumeAll(items[1]);
                for (items[1..]) |c| try s.walk(c);
            },
            .@"for" => {
                if (items.len < 6) return;
                if (items[1] == .tag and items[1].tag == .@"move") try s.consume(items[4]);
                try s.walk(items[4]);
                try s.push();
                defer s.pop();
                try s.declare(items[2]);
                try s.declare(items[3]);
                try s.walk(items[5]);
                if (items.len >= 7) try s.walk(items[6]);
            },
            .@"arm" => {
                try s.push();
                defer s.pop();
                const pattern = items[1];
                if (pattern == .src) try s.declare(pattern);
                if (isTagged(pattern, .@"variant_pattern")) for (pattern.list[2..]) |c| try s.declare(c);
                if (items.len >= 3) try s.declare(items[2]);
                try s.walk(items[items.len - 1]);
            },
            .@"as" => {
                try s.walk(items[1]);
                try s.declare(items[2]);
            },
            .@"if", .@"while" => {
                // An `if` with `else` may be a value: its branches yield.
                if (items[0].tag == .@"if" and items.len == 4) {
                    try s.consumeTail(items[2]);
                    try s.consumeTail(items[3]);
                }
                // A capture in the condition scopes over the body.
                try s.push();
                defer s.pop();
                for (items[1..]) |c| try s.walk(c);
            },
            .@"match" => {
                for (items[2..]) |arm| if (isTagged(arm, .@"arm")) try s.consumeTail(arm.list[arm.list.len - 1]);
                for (items[1..]) |c| try s.walk(c);
            },
            .@"ternary" => {
                try s.consumeTail(items[2]);
                try s.consumeTail(items[3]);
                for (items[1..]) |c| try s.walk(c);
            },
            .@"lambda" => {
                if (isTagged(items[1], .@"captures")) for (items[1].list[1..]) |cap| {
                    if (isTagged(cap, .@"cap_move")) try s.consume(cap.list[1]);
                };
                // The body sees only its captures and parameters.
                var inner: Scan = .{ .e = s.e };
                defer inner.deinit();
                try inner.push();
                if (isTagged(items[1], .@"captures")) for (items[1].list[1..]) |cap| if (captureNameSrc(cap)) |n| try inner.declare(n);
                try inner.declareParams(items[2]);
                try inner.walk(items[4]);
                const stmts = try s.e.stmtsOf(items[4]);
                if (stmts.len > 0 and s.e.lambdaReturn(sexp) != null) try inner.consumeAll(stmts[stmts.len - 1]);
            },
            else => for (items[1..]) |c| try s.walk(c),
        }
    }
};

// =============================================================================
// Free helpers
// =============================================================================

/// Formats a Rig identifier as a Zig identifier, escaping Zig keywords
/// and primitive names (`var` → `@"var"`).
const Ident = struct {
    name: []const u8,

    pub fn format(self: Ident, w: *Writer) Writer.Error!void {
        if (needsEscape(self.name)) {
            try w.print("@\"{s}\"", .{self.name});
        } else {
            try w.writeAll(self.name);
        }
    }
};

fn needsEscape(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return false;
    if (std.zig.Token.getKeyword(name) != null) return true;
    if (isLiteralText(name)) return false;
    return std.zig.primitives.isPrimitive(name);
}

fn isRigStatementKeyword(name: []const u8) bool {
    const words = [_][]const u8{ "if", "else", "while", "for", "match", "return", "break", "continue" };
    for (words) |w| if (std.mem.eql(u8, name, w)) return true;
    return false;
}

fn isPlainIdent(name: []const u8) bool {
    return name.len > 0 and name[0] != '@' and std.mem.indexOfScalar(u8, name, '.') == null;
}

/// Literal source text: numbers, quoted strings, and the value keywords.
fn isLiteralText(t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.ascii.isDigit(t[0]) or t[0] == '"' or t[0] == '\'') return true;
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false") or
        std.mem.eql(u8, t, "null") or std.mem.eql(u8, t, "undefined");
}

fn unwrapNeg(s: Sexp) Sexp {
    return if (isTagged(s, .@"neg") and s.list.len >= 2) s.list[1] else s;
}

/// A numeric literal, possibly negated.
fn isNumberLiteral(source: []const u8, s: Sexp) bool {
    const n = unwrapNeg(s);
    return n == .src and std.ascii.isDigit(source[n.src.pos]);
}

fn isNonNegativeIntLiteral(source: []const u8, s: Sexp) bool {
    if (s != .src) return false;
    const t = source[s.src.pos..][0..s.src.len];
    for (t) |c| if (!std.ascii.isDigit(c) and c != '_') return false;
    return t.len > 0;
}

fn isTagged(s: Sexp, tag: Tag) bool {
    return s == .list and s.list.len > 0 and s.list[0] == .tag and s.list[0].tag == tag;
}

fn unwrapPub(s: Sexp) Sexp {
    return if (isTagged(s, .@"pub") and s.list.len >= 2) s.list[1] else s;
}

fn unwrapShare(s: Sexp) Sexp {
    return if (isTagged(s, .@"share") and s.list.len >= 2) s.list[1] else s;
}

fn paramSlice(params: ?Sexp, skip: usize) []const Sexp {
    const p = params orelse return &.{};
    if (p != .list) return &.{};
    return p.list[@min(skip, p.list.len)..];
}

/// An argument whose evaluation has no side effects.
fn isPureArg(arg: Sexp) bool {
    return switch (arg) {
        .src, .nil => true,
        .list => |items| items.len > 0 and items[0] == .tag and switch (items[0].tag) {
            .@"kwarg" => items.len >= 3 and isPureArg(items[2]),
            .@"read", .@"write", .@"move", .@"member", .@"deref", .@"neg", .@"not", .@"enum_lit",
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&&", .@"||",
            => for (items[1..]) |c| {
                if (!isPureArg(c)) break false;
            } else true,
            else => false,
        },
        else => false,
    };
}

fn hasKwarg(args: []const Sexp) bool {
    for (args) |a| if (isTagged(a, .@"kwarg")) return true;
    return false;
}

/// The name node of any parameter shape.
fn paramNameNode(p: Sexp) ?Sexp {
    return switch (p) {
        .src => p,
        .list => |items| if (items.len >= 2 and items[0] == .tag) switch (items[0].tag) {
            .@":", .@"pre_param", .@"default", .@"aligned", .@"read", .@"write" => items[1],
            else => null,
        } else null,
        else => null,
    };
}

fn paramIsWriteBorrow(p: Sexp) bool {
    if (isTagged(p, .@"write")) return true;
    if (p != .list or p.list.len < 3 or p.list[0] != .tag) return false;
    return switch (p.list[0].tag) {
        .@":", .@"default" => isTagged(p.list[2], .@"borrow_write"),
        else => false,
    };
}

fn paramsStartWithSelf(source: []const u8, params: Sexp) bool {
    if (params != .list or params.list.len == 0) return false;
    const n = paramNameNode(params.list[0]) orelse return false;
    return n == .src and std.mem.eql(u8, source[n.src.pos..][0..n.src.len], "self");
}

fn captureNameSrc(cap: Sexp) ?Sexp {
    if (cap != .list or cap.list.len < 2 or cap.list[0] != .tag) return null;
    return switch (cap.list[0].tag) {
        .@"cap_copy", .@"cap_clone", .@"cap_weak", .@"cap_move" => cap.list[1],
        else => null,
    };
}

/// Rig types implemented by the runtime.
fn isBuiltinNominalName(name: []const u8) bool {
    const names = [_][]const u8{ "Cell", "Closure", "Closure1", "Closure2", "Vec", "Signal" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn builtinZigName(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "Closure")) "Closure0" else name;
}

fn mapTypeName(rig_name: []const u8) []const u8 {
    const map = .{
        .{ "Int", "i32" },        .{ "Float", "f32" }, .{ "I8", "i8" },   .{ "I16", "i16" },
        .{ "I32", "i32" },        .{ "I64", "i64" },   .{ "U8", "u8" },   .{ "U16", "u16" },
        .{ "U32", "u32" },        .{ "U64", "u64" },   .{ "F32", "f32" }, .{ "F64", "f64" },
        .{ "Bool", "bool" },      .{ "String", "[]const u8" },            .{ "Bytes", "[]const u8" },
        .{ "Void", "void" },
    };
    inline for (map) |m| if (std.mem.eql(u8, rig_name, m[0])) return m[1];
    return rig_name;
}

const ClosureKind = enum { c0, c1, c2 };

const ClosureCtorInfo = struct {
    kind: ClosureKind,
    type_args: []const Sexp,
    lambda: Sexp,
};

/// `(call Closure (lambda ...))`, `(call (call Closure1 T) (lambda ...))`,
/// or `(call (call Closure2 A B) (lambda ...))`.
fn classifyOwnedClosure(source: []const u8, inner: Sexp) ?ClosureCtorInfo {
    if (!isTagged(inner, .@"call") or inner.list.len != 3 or !isTagged(inner.list[2], .@"lambda")) return null;
    const callee = inner.list[1];
    const lambda = inner.list[2];
    if (callee == .src) {
        if (!std.mem.eql(u8, source[callee.src.pos..][0..callee.src.len], "Closure")) return null;
        return .{ .kind = .c0, .type_args = &.{}, .lambda = lambda };
    }
    if (!isTagged(callee, .@"call") or callee.list.len < 2 or callee.list[1] != .src) return null;
    const name = source[callee.list[1].src.pos..][0..callee.list[1].src.len];
    const kind: ClosureKind = if (std.mem.eql(u8, name, "Closure1"))
        .c1
    else if (std.mem.eql(u8, name, "Closure2"))
        .c2
    else
        return null;
    return .{ .kind = kind, .type_args = callee.list[2..], .lambda = lambda };
}

/// `(shared (generic_inst Closure...))` type annotations.
fn isOwnedClosureTypeNode(source: []const u8, t: Sexp) bool {
    if (!isTagged(t, .@"shared") or !isTagged(t.list[1], .@"generic_inst")) return false;
    const n = t.list[1].list[1];
    if (n != .src) return false;
    const name = source[n.src.pos..][0..n.src.len];
    return std.mem.eql(u8, name, "Closure") or std.mem.eql(u8, name, "Closure1") or std.mem.eql(u8, name, "Closure2");
}

/// Statements that produce a value (and can end a value block).
fn isValueStmt(s: Sexp) bool {
    if (s != .list or s.list.len == 0 or s.list[0] != .tag) return true;
    return switch (s.list[0].tag) {
        .@"set", .@"drop", .@"return", .@"break", .@"continue", .@"defer", .@"errdefer", .@"block", .@"while", .@"for", .@"labeled" => false,
        .@"if" => s.list.len >= 4,
        else => true,
    };
}

fn isTerminatingStmt(s: Sexp) bool {
    if (s != .list or s.list.len == 0 or s.list[0] != .tag) return false;
    return switch (s.list[0].tag) {
        .@"return" => s.list.len < 3 or s.list[2] == .nil,
        .@"break" => s.list.len < 4 or s.list[3] == .nil,
        .@"continue" => s.list.len < 3 or s.list[2] == .nil,
        else => false,
    };
}

fn containsPropagate(sexp: Sexp) bool {
    if (sexp != .list or sexp.list.len == 0) return false;
    const items = sexp.list;
    if (items[0] == .tag) switch (items[0].tag) {
        .@"propagate", .@"try" => return true,
        .@"fun", .@"sub", .@"lambda" => return false,
        else => {},
    };
    for (items) |c| if (containsPropagate(c)) return true;
    return false;
}

fn firstSrcPos(s: Sexp) u32 {
    return switch (s) {
        .src => |x| x.pos,
        .list => |items| for (items) |c| {
            const p = firstSrcPos(c);
            if (p > 0) break p;
        } else 0,
        else => 0,
    };
}

/// Whether `name` is referenced in `stmts`, up to a statement that
/// shadows it with `new name = ...`.
fn usesNameInStmts(source: []const u8, stmts: []const Sexp, name: []const u8) bool {
    for (stmts) |s| {
        if (isTagged(s, .@"set") and s.list.len >= 5 and s.list[2] == .src and
            std.mem.eql(u8, source[s.list[2].src.pos..][0..s.list[2].src.len], name))
        {
            const kind = rig.bindingKindOf(s.list[1]) catch return true;
            if (kind == .shadow) return usesName(source, s.list[4], name);
        }
        if (usesName(source, s, name)) return true;
    }
    return false;
}

/// Whether `node` refers to `name`. Field names, keyword-argument
/// names, and enum literals are not references; a closure body sees
/// only its captures.
fn usesName(source: []const u8, node: Sexp, name: []const u8) bool {
    switch (node) {
        .src => |s| return std.mem.eql(u8, source[s.pos..][0..s.len], name),
        .list => |items| {
            if (items.len == 0) return false;
            if (items[0] == .tag) switch (items[0].tag) {
                .@"member" => return items.len >= 2 and usesName(source, items[1], name),
                .@"kwarg" => return items.len >= 3 and usesName(source, items[2], name),
                .@"enum_lit", .@"enum_pattern" => return false,
                // Ending a borrow early is not a read of it.
                .@"drop" => return false,
                .@"variant_pattern" => return false,
                .@"lambda" => return items.len >= 2 and usesName(source, items[1], name),
                .@"block" => return usesNameInStmts(source, items[1..], name),
                else => {},
            };
            for (items) |c| if (usesName(source, c, name)) return true;
            return false;
        },
        else => return false,
    }
}

// =============================================================================
// Tests
// =============================================================================

fn emitSourceToString(allocator: std.mem.Allocator, rig_source: []const u8) ![]u8 {
    var p = parser.Parser.init(allocator, rig_source);
    defer p.deinit();
    const ir = try p.parseProgram();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var em = Emitter.init(allocator, rig_source, &out.writer);
    defer em.deinit();
    try em.emit(ir);
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

test "emit: const for unmutated, var for mutated" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  x = 1
        \\  y = 2
        \\  x = 3
        \\  print(x + y)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x: i32 = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const y =") != null);
}

test "emit: fixed binding is const" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  user =! 1
        \\  print(user)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const user =") != null);
}

test "emit: propagate becomes try; signatures come from the IR" {
    const out = try emitSourceToString(std.testing.allocator,
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
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn foo() !i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "try foo()") != null);
}

test "emit: a bare fallible call is not tried" {
    const out = try emitSourceToString(std.testing.allocator,
        \\fun foo() -> Int!
        \\  1
        \\
        \\sub main()
        \\  x = foo()
        \\  print(x)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "try foo()") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "= foo()") != null);
}

test "emit: Zig keywords are escaped" {
    const out = try emitSourceToString(std.testing.allocator,
        \\sub main()
        \\  var = 3
        \\  print(var)
        \\
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const @\"var\" = 3;") != null);
}
