//! Zig code generation.
//!
//! Lowers the semantic IR (`docs/INTERNALS.md`) of one checked module to Zig
//! 0.17 source. The program has already passed sema and ownership
//! checking; this pass only chooses a representation, and it
//! reads everything it needs to know about names and types from sema's
//! facts table (`sema.zig`): which symbol a name denotes, whether a
//! `set` declares or reassigns, and the type of every expression.
//!
//! - A binding is `const` unless it is reassigned, written through
//!   (`!x`, `x.f = ...`), holds a Cell or a value with drop glue (whose
//!   methods take `*Self`), or has a compile-time-known initializer,
//!   which Zig would otherwise fold at compile time.
//! - A resource binding (`*T`, `~T`, a value with drop glue, or an
//!   optional of one) is dropped at scope exit by a `defer`. When the
//!   binding may be moved, dropped, or returned, the defer tests a
//!   `__rig_alive_<name>` flag, and the consuming site clears it.
//! - `!T` parameters, `!self` receivers, and write-view bindings are
//!   pointers; reads go through `.*`.
//! - Every Rig name is written with `rig.writeZigIdent`; a local that
//!   would shadow another visible Zig name is renamed.
//!
//! Anything the emitter cannot lower is an internal error: sema must
//! reject it first.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const facts = @import("facts.zig");
const Facts = facts.Facts;
const Wide = facts.Wide;
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
const TypeId = facts.TypeId;
const SymbolId = facts.SymbolId;

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
    /// An optional resource such as `*T?`: `rig.drop(&x)`. Needs `var`.
    optional,
};

/// How a binding's scope-exit drop is armed.
const Guard = enum {
    /// Not dropped here (plain data, views, captures, loop elements).
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
    /// A closure literal bound to a name: calls lower to `.__rig_invoke(...)`.
    stack_closure: bool = false,
    /// Name of the alive flag when `guard == .flag`.
    flag: []const u8 = "",
    /// The local of the same symbol this one hides until its scope ends.
    shadowed: ?LocalRef = null,
    /// A parameter copied into `zig_name` at the top of the body: the
    /// name the signature gives it.
    param_name: []const u8 = "",
};

const LocalRef = struct { scope: u32, index: u32 };

/// An argument evaluated into the temporary `name`. An owned one is
/// dropped at scope exit while `flag` is set; the call clears it. With
/// `ptr`, `name` holds the address of `node`, which stays where it is.
const Hoisted = struct { node: Sexp, name: []const u8, flag: []const u8 = "", ptr: bool = false };

/// How a branch yields its value: the value itself, or the address of
/// the leaf it takes (`Emitter.emitLeafPtr`).
const Yield = enum { value, leaf_ptr };

/// The slot an owning temporary is kept in until its statement ends,
/// and the flag saying it holds one.
const TempSlot = struct {
    node: parser.NodeId,
    name: []const u8,
};

/// A header being emitted (`openHeader`): the label of the block that
/// holds its temporaries' slots, if it makes any, and the slots before.
const Header = struct { label: []const u8 = "", first: usize };

/// A label of the Zig a loop or labeled block is lowered to, written
/// before its construct only when a jump was written to it
/// (`openLabeled`), since Zig rejects a label nothing jumps to.
const ZigLabel = struct { name: []const u8, used: bool = false };

/// A loop, or a labeled `match` or `raw` block, that a `break` or
/// `continue` can name (docs/INTERNALS.md, "Loops"). Jumps resolve to
/// one by lexical scope: an unlabeled jump to the innermost loop, a
/// labeled one to the innermost target of that name.
const JumpTarget = struct {
    /// Its Rig label, or "".
    rig_label: []const u8,
    /// False for a labeled `match` or `raw` block, which only
    /// `break :label` leaves.
    is_loop: bool = true,
    /// Where a `break` goes: the loop's result block, or the loop.
    brk: *ZigLabel,
    /// Where a `continue` goes from the part of the loop being emitted:
    /// `continue :loop` from the condition, `break :body` from the body,
    /// and `break :step` from the step.
    cont: ?ContinueTo = null,
    /// The type of a loop used as a value, whose `break` gives it one.
    value_ty: ?TypeId = null,
};

const ContinueTo = struct { word: []const u8, label: *ZigLabel };

/// A labeled construct being written into a buffer of its own, until
/// `closeLabeled` knows whether its label is used.
const Labeled = struct { label: *ZigLabel, saved: *Writer, buf: *Writer.Allocating };

const Scope = struct {
    locals: std.ArrayList(Local) = .empty,
};

/// State for the function whose body is being emitted.
const FunState = struct {
    /// Declared return type.
    return_ty: ?TypeId = null,
    /// Parameters to bind at the top of the body.
    params: ?Sexp = null,
    /// Compile-time parameters, bound at the top of the body as
    /// `params` are.
    tparams: Sexp = .nil,
    leak_check: bool = false,
    /// A closure's environment parameter, when no capture is used.
    unused_env: []const u8 = "",
};

const Nominal = struct {
    /// How `Self` is spelled: the type name, or `__rig_Self` inside a generic.
    name: []const u8,
    sym: SymbolId,
    members: []const Sexp,
};

/// Facts about bindings the emitter derives from one walk over the
/// module, keyed by symbol.
const Usage = struct {
    /// Referenced somewhere after the declaration.
    used: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

    fn deinit(self: *Usage, a: std.mem.Allocator) void {
        self.used.deinit(a);
    }
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    w: *Writer,
    indent: u32 = 0,
    /// Generated names and other emit-lifetime allocations.
    arena: std.heap.ArenaAllocator,
    facts: Facts,

    scopes: std.ArrayList(Scope) = .empty,
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
    tests: std.ArrayList(struct { name: []const u8, func: []const u8 }) = .empty,
    fun: FunState = .{},
    /// Closure bodies being emitted around the current point. Each names
    /// its environment `__rig_self`, `__rig_self1`, ... so a closure
    /// inside another does not shadow the outer one's.
    closure_depth: u32 = 0,
    nominal: ?Nominal = null,
    /// The next expression sits in a delimited position (after `=`,
    /// between commas, inside parentheses) and needs no outer parentheses.
    bare: bool = false,
    /// The value being emitted is a write view: a pointer local in tail
    /// position yields the pointer, not the value behind it.
    ptr_tail: bool = false,
    /// What the context of the value being emitted does with it
    /// (`facts.Use`), and the value it was recorded for or a part of that
    /// value (`facts.syntax.valueParts`) the use reaches.
    use: ?facts.Use = null,
    use_node: Sexp = .nil,
    /// The next expression is emitted as the pointer it yields, even where
    /// its context reads through it (`emitDeref`).
    want_ptr: bool = false,
    /// Emitting an operand of arithmetic or an index: compile-time names
    /// (compile-time parameters, `const` bindings) are read through `rig.rt` so Zig
    /// evaluates the operation at run time, as Rig checked it.
    rt_names: bool = false,
    /// Emitting a compile-time argument, which must stay compile-time known.
    keep_comptime: bool = false,
    /// Emitting an operand of arithmetic in a float type or a type
    /// parameter: an integer literal is a value of that type, so `7 / 2`
    /// in a `Float` is `3.5`, and in a `T` divides as `T`'s instance does.
    literal_ty: ?TypeId = null,
    /// Emitting the object chain of an assignment target: an indexed
    /// element in it is a slot, not a copy.
    place_chain: bool = false,
    /// The value `emitLend` is lending, which it emits as itself.
    lending: Sexp = .nil,
    /// Arguments and receivers of the calls being emitted that were
    /// evaluated into temporaries first (`emitHoistedCall`), innermost
    /// call last.
    hoisted: std.ArrayList(Hoisted) = .empty,
    /// The owning temporaries of the statements being emitted, each held
    /// in a slot its statement drops (`sema.dropsTemp`).
    temp_slots: std.ArrayList(TempSlot) = .empty,
    /// The temporary whose value is being written into its slot.
    keeping: Sexp = .nil,
    /// The loops and labeled blocks around the current point that a jump
    /// can name, innermost last.
    targets: std.ArrayList(JumpTarget) = .empty,
    /// The place being emitted is only read: a Vec element on its path
    /// is reached through `constSlot`.
    read_place: bool = false,
    /// The `match` subject being emitted, which it reaches where it is
    /// (`storage.matchesInPlace`): a generic read view held on its path,
    /// by its name, a field, or an element, is the value it reaches in
    /// place, `rig.viewedPtr(T, &view).*`, never a copy (`onSubjectPath`).
    subject_path: Sexp = .nil,
    /// A name was qualified as `__rig_module.name` (`writeModuleName`).
    uses_module: bool = false,
    /// A `@name` of a type parameter needs the module's table of names
    /// (`emitNamesTable`).
    uses_names: bool = false,
    /// The module declares an `extern "c"`, so the program links libc.
    links_libc: bool = false,
    /// Fill each hidden storage location with `0xAA` when its scope ends
    /// (`rig.poison`), so a view that outlives it reads garbage: set for
    /// the sanitizer (`RIG_SANITIZE`).
    poison: bool = false,
    /// The Zig error set of every error of the module's error sets,
    /// which its fallible Zig-backed functions may return.
    module_errors: []const u8 = "error{}",
    /// The statement or declaration being emitted, where an internal
    /// error about a node without a position is reported.
    stmt: Sexp = .nil,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer, ctx: Facts) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .facts = ctx,
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
        self.temp_slots.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        try self.w.print("const rig = @import(\"{s}\");\n", .{runtime_filename});
        if (!sexp.isKind(.module)) return;
        const decls = ir.Module.decls(sexp);
        try self.collectModule(decls);
        for (decls) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            if (!d.isKind(.errors)) continue;
            const set = try self.fmt("{f}", .{ident(self.srcText(ir.Errors.name(d)))});
            self.module_errors = if (std.mem.eql(u8, self.module_errors, "error{}")) set else try self.fmt("{s} || {s}", .{ self.module_errors, set });
        }
        var scan: Scan = .{ .e = self };
        try scan.walk(sexp);
        for (decls) |decl| {
            try self.w.writeAll("\n");
            try self.emitDecl(decl);
        }
        try self.emitTestTable();
        if (self.uses_module) try self.w.writeAll("\nconst __rig_module = @This();\n");
        if (self.uses_names) try self.emitNamesTable();
    }

    // =========================================================================
    // Module-level declarations
    // =========================================================================

    fn collectModule(self: *Emitter, decls: []const Sexp) Error!void {
        const a = self.allocator;
        try self.module_names.put(a, "std", {});
        try self.module_names.put(a, "rig", {});
        for (decls) |d0| {
            if (d0.isKind(.zig_extern)) try self.collectModule(ir.ZigExtern.decls(d0));
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
            .zig_extern => try self.emitZigExtern(sexp),
            .@"extern" => try self.emitExtern(ir.Extern.name(sexp)),
            .use => try self.emitUse(sexp),
            .@"struct" => try self.emitStruct(sexp),
            .@"enum" => try self.emitEnum(sexp),
            .errors => try self.emitErrorSet(sexp),
            .generic_struct => try self.emitGenericStruct(sexp),
            .generic_enum => try self.emitGenericEnum(sexp),
            .type => try self.emitTypeAlias(sexp),
            .@"test" => try self.emitTest(sexp),
            .set => try self.emitConst(sexp),
            else => return self.unsupported(sexp, "this top-level form"),
        }
    }

    /// A module-level constant, `name = value`.
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

    /// `use` binds its local name to the module's emitted file.
    fn emitUse(self: *Emitter, node: Sexp) Error!void {
        const path = ir.Use.name(node);
        const alias = ir.Use.alias(node);
        const name = self.srcText(if (alias != .nil) alias else if (path.isKind(.member)) ir.Member.name(path) else path);
        for (0..self.facts.importCount()) |i| {
            const imp = self.facts.importAt(i);
            if (std.mem.eql(u8, imp.local_name, name)) return self.w.print("const {f} = @import(\"{s}\");\n", .{ ident(name), imp.facts.zig_file });
        }
        return self.unsupported(node, "an unresolved `use`");
    }

    /// `extern_fun` / `extern_sub`, a C function, or `extern`, a C
    /// variable.
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

    /// `extern zig "file.zig"`: each declaration is the function of the
    /// same name in the standard library's Zig file, written beside the
    /// runtime as `rig/std/file.zig`, and a compile-time check that its
    /// Zig type is exactly the one the Rig signature lowers to. A
    /// fallible one's Zig function returns a narrower error set, only of
    /// the module's errors (`rig.expectShim`), so the declaration is a
    /// function of the Rig type that calls it.
    fn emitZigExtern(self: *Emitter, node: Sexp) Error!void {
        const file = self.srcText(ir.ZigExtern.file(node));
        const shim = try self.fmt("__rig_shim_{d}", .{self.nextId()});
        try self.w.print("const {s} = @import(\"rig/std/{s}\");\n", .{ shim, file[1 .. file.len - 1] });
        for (ir.ZigExtern.decls(node)) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            const name = ir.get(d, .name);
            const f = self.fnType(try self.declType(name)) orelse return self.unsupported(name, "an untyped function");
            if (self.facts.types.get(f.returns) == .fallible) {
                try self.w.print("pub fn {f}(", .{ident(self.srcText(name))});
                for (f.params, 0..) |p, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("__rig_a{d}: ", .{i});
                    try self.emitTypeTy(p);
                }
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
                try self.w.print(" {{\n    return {s}.{f}(", .{ shim, ident(self.srcText(name)) });
                for (0..f.params.len) |i| try self.w.print("{s}__rig_a{d}", .{ if (i > 0) ", " else "", i });
                try self.w.writeAll(");\n}\n");
            } else {
                try self.w.print("pub const {f} = {s}.{f};\n", .{ ident(self.srcText(name)), shim, ident(self.srcText(name)) });
            }
            try self.w.print("comptime {{\n    rig.expectShim({s}.{f}, fn (", .{ shim, ident(self.srcText(name)) });
            try self.emitTypeList(f.params);
            try self.w.writeAll(") ");
            if (f.returns == self.facts.types.void_id) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
            try self.w.print(", {s}, \"{s}.{s}\");\n}}\n", .{ self.module_errors, self.facts.name, self.srcText(name) });
        }
    }

    fn emitTypeAlias(self: *Emitter, node: Sexp) Error!void {
        const name = ir.Type.name(node);
        try self.w.print("pub const {f} = ", .{ident(self.srcText(name))});
        try self.emitTypeTy(try self.declType(name));
        try self.w.writeAll(";\n");
    }

    /// The type sema gave the declaration named by `name_node`.
    fn declType(self: *Emitter, name_node: Sexp) Error!TypeId {
        const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved declaration");
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
        try self.emitRigName(1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_struct Name (T...) members...)` → a type-returning function.
    fn emitGenericStruct(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericStruct.members(node);
        const prev = try self.enterNominal(ir.GenericStruct.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericStruct.tparams(node), "struct");
        try self.emitFields(2);
        try self.emitRigName(2);
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
            for (self.nominalFields()) |f| {
                if (!f.is_variant) continue;
                try self.w.print("    {f}", .{ident(f.name)});
                if (has_values) try self.w.print(" = {d}", .{f.value.?});
                try self.w.writeAll(",\n");
            }
        }
        try self.emitRigName(1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `(generic_enum Name (T...) variants... methods...)`.
    fn emitGenericEnum(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericEnum.members(node);
        const prev = try self.enterNominal(ir.GenericEnum.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericEnum.tparams(node), "union(enum)");
        try self.emitUnionVariants(2);
        try self.emitRigName(2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v...)` → a Zig error set of its members' Zig names
    /// (`writeErrorName`).
    fn emitErrorSet(self: *Emitter, node: Sexp) Error!void {
        const set = self.srcText(ir.Errors.name(node));
        try self.w.print("pub const {f} = error{{\n", .{ident(set)});
        for (ir.Errors.members(node)) |v| if (v == .src) {
            try self.w.writeAll("    ");
            try writeErrorName(self.w, self.facts, set, self.srcText(v));
            try self.w.writeAll(",\n");
        };
        try self.w.writeAll("};\n");
    }

    /// Member `name` of error set `set` as a Zig error value.
    fn writeError(self: *Emitter, set: TypeId, name: []const u8, at: Sexp) Error!void {
        const decl = self.facts.nominalDecl(set) orelse return self.unsupported(at, "an error of no error set");
        try self.w.writeAll("error.");
        try writeErrorName(self.w, decl.facts, decl.symbol().name, name);
    }

    fn enterNominal(self: *Emitter, name_node: Sexp, generic: bool, members: []const Sexp) Error!?Nominal {
        const prev = self.nominal;
        const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved type");
        const name = if (generic) "__rig_Self" else try self.fmt("{f}", .{ident(self.srcText(name_node))});
        self.nominal = .{ .name = name, .sym = sym, .members = members };
        return prev;
    }

    /// `pub fn Name(comptime T: type, comptime n: i64, ...) type { return
    /// <container> {`. Its name (`emitRigName`) names every parameter.
    fn emitGenericHead(self: *Emitter, params: Sexp, container: []const u8) Error!void {
        try self.w.print("pub fn {f}(", .{ident(self.facts.symbols.items[self.nominal.?.sym].name)});
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.w.print("comptime {f}: ", .{ident(facts.syntax.paramName(self.source, p).?)});
            if (p == .src) {
                try self.w.writeAll("type");
            } else try self.emitTypeTy(try self.declType(ir.get(p, .name)));
        }
        try self.w.writeAll(") type {\n");
        try self.w.print("    return {s} {{\n        const __rig_Self = @This();\n\n", .{container});
    }

    /// The fields and variants of the nominal type being emitted, in
    /// declaration order.
    fn nominalFields(self: *Emitter) []const facts.Field {
        return self.facts.symbols.items[self.nominal.?.sym].fields orelse &.{};
    }

    /// `pub const __rig_name = .{ .module = "geo", .name = .{ "Point" } };`:
    /// the type being emitted as sema's printer spells it, for `@name` of
    /// a type parameter (`rig.typeName`): its module (`nameModule`), and
    /// its spelling, a generic type's at the parameters of each instance
    /// (`.{ "Pair[", A, ", ", B, "]" }`).
    fn emitRigName(self: *Emitter, depth: u32) Error!void {
        const sym = self.nominal.?.sym;
        const a = self.arena.allocator();
        const spelling = if (self.facts.symbols.items[sym].type_params != null)
            try self.facts.formatGenericSelfMarked(a, sym)
        else
            try self.facts.formatTypeValue(a, .{ .nominal = sym });
        try self.writeIndent(depth);
        try self.w.print("pub const __rig_name = .{{ .module = \"{s}\", .name = ", .{nameModule(self.facts)});
        try self.writeSpelling(spelling, .parts, null);
        try self.w.writeAll(" };\n");
    }

    fn emitFields(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |f| {
            if (f.is_method or f.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(f.name)});
            try self.emitTypeTy(f.ty);
            if (f.default) |d| {
                try self.w.writeAll(" = ");
                try self.emitDefault(self.facts, d);
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Variants of a tagged union: bare → `void`, a payload → a struct
    /// of its fields.
    fn emitUnionVariants(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |v| {
            if (!v.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(v.name)});
            const fields = v.payload orelse &.{};
            if (fields.len == 0) {
                try self.w.writeAll("void");
            } else {
                try self.w.writeAll("struct { ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("{f}: ", .{ident(f.name)});
                    try self.emitTypeTy(f.ty);
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
        const f = self.fnType(self.facts.typeOf(name_node)) orelse return self.unsupported(name_node, "an untyped function");
        // Only the root module's `main` is the program's entry point.
        const is_main = self.facts.is_root and self.nominal == null and std.mem.eql(u8, name, "main");
        const return_ty: ?TypeId = if (f.returns == self.facts.types.void_id) null else f.returns;
        // `main` may fail out of the program (`!`, `sub main()!`, `-> Int!`),
        // and `fun main() -> Int` returns its exit status.
        const main_fails = is_main and (contains(body, &.{.propagate}) or rig.subFails(node) or (return_ty != null and self.facts.types.get(return_ty.?) == .fallible));
        const main_status = is_main and !f.is_sub;

        const tparams = facts.syntax.tparamsOf(node);
        self.fun = .{ .return_ty = return_ty, .params = params, .tparams = tparams, .leak_check = is_main };

        // The runtime's panic handler flushes buffered `print` output first.
        if (is_main) try self.w.writeAll("pub const panic = rig.panic;\n\n");
        // A `main` that may fail, or returns the exit status, is the body
        // of a Zig `main` that reports the failure as Rig shows errors
        // (`rig.failMain`) or sets the status (`rig.exitStatus`), after
        // every drop and the leak check.
        if (main_fails or main_status) {
            const catches = if (main_fails) " catch |err| rig.failMain(err)" else "";
            if (main_status) {
                try self.w.print("pub fn main(__rig_init: std.process.Init.Minimal) u8 {{\n    return rig.exitStatus(__rig_run_main(__rig_init){s});\n}}\n\n", .{catches});
            } else try self.w.print("pub fn main(__rig_init: std.process.Init.Minimal) void {{\n    __rig_run_main(__rig_init){s};\n}}\n\n", .{catches});
            try self.w.writeAll("fn __rig_run_main(");
        } else try self.w.print("pub fn {f}(", .{ident(name)});
        // Zig hands the arguments and environment only to `main`.
        if (is_main) try self.w.writeAll("__rig_init: std.process.Init.Minimal");
        try self.pushScope();
        defer self.popScope() catch {};
        // Compile-time parameters come first, after a method's receiver,
        // which Zig's method call syntax needs first.
        try self.bindParams(tparams);
        try self.bindParams(params);
        const rt = params.items();
        const recv: usize = @intFromBool(self.nominal != null and rt.len > 0 and self.isReceiverParam(rt[0]));
        var n: usize = 0;
        for ([_][]const Sexp{ rt[0..recv], tparams.items(), rt[recv..] }, 0..) |group, g| for (group) |p| {
            if (n > 0) try self.w.writeAll(", ");
            n += 1;
            try self.emitParam(p, g == 1);
        };
        try self.w.writeAll(") ");
        if (main_fails) {
            // `anyerror!void`, `anyerror!i64`: whether or not `-> Int!` says so.
            try self.w.writeAll("anyerror!");
            try self.emitTypeTy(if (main_status) self.facts.types.int_id else self.facts.types.void_id);
        } else if (return_ty) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        // A `sub` yields no value, even one that may fail (`Void!`).
        if (return_ty != null and !f.is_sub) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
    }

    /// Bind each parameter in the current scope. An owned value (or one
    /// holding a Cell) is copied into a `var` at the top of the body, so
    /// it can be dropped or changed; the Zig parameter then gets a
    /// generated name. An owning `_` is dropped under a hidden name.
    fn bindParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        for (params.items()) |p| {
            const name_node = facts.syntax.paramNameNode(p) orelse continue;
            const sym = self.facts.symbolOf(name_node) orelse continue;
            const rig_name = self.srcText(name_node);
            // A type parameter, `comptime T: type`.
            if (self.facts.symbols.items[sym].kind == .generic_param) {
                _ = try self.declare(.{ .sym = sym }, rig_name);
                continue;
            }
            const ty = self.symType(sym) orelse return self.unsupported(p, "an untyped parameter");
            const unused = std.mem.eql(u8, rig_name, "_");
            var local: Local = .{ .sym = sym, .ty = ty };
            if (!self.isPtrViewTy(ty)) local.kind = self.kindOf(ty);
            if (local.kind != null) {
                local.guard = self.resourceGuard(sym);
                if (unused) local.zig_name = try self.fresh("__rig_unused");
            }
            if (local.kind == .value or local.kind == .optional) {
                local.param_name = try self.fmt("__rig_arg_{d}", .{self.nextId()});
            }
            _ = try self.declare(local, rig_name);
        }
    }

    /// `name: T` in a signature; `comptime` for a compile-time parameter,
    /// and `comptime T: type` for a type parameter.
    fn emitParam(self: *Emitter, p: Sexp, ct: bool) Error!void {
        const local = self.localOf(facts.syntax.paramNameNode(p).?).?;
        const name = if (local.param_name.len > 0) local.param_name else local.zig_name;
        try self.w.print("{s}{s}: ", .{ if (ct) "comptime " else "", name });
        if (self.facts.symbols.items[local.sym].kind == .generic_param) return self.w.writeAll("type");
        try self.emitTypeTy(local.ty.?);
    }

    /// A method's receiver: `?self`, `!self`, or `self: T`.
    fn isReceiverParam(self: *Emitter, p: Sexp) bool {
        return std.mem.eql(u8, facts.syntax.paramName(self.source, p) orelse "", "self");
    }

    /// Statements at the top of a function body: in `main`,
    /// `rig.guardStack()` and the deferred `rig.finish()` (flush output,
    /// check for leaks), then parameter copies and guards, and discards
    /// for unused parameters.
    fn emitFunPrologue(self: *Emitter) Error!void {
        if (self.fun.leak_check) {
            self.fun.leak_check = false;
            try self.line("rig.guardStack();", .{});
            try self.line("rig.start(__rig_init);", .{});
            try self.line("defer rig.finish();", .{});
        }
        if (self.fun.unused_env.len > 0) {
            try self.line("_ = {s};", .{self.fun.unused_env});
            self.fun.unused_env = "";
        }
        const tparams = self.fun.tparams;
        self.fun.tparams = .nil;
        const params = self.fun.params orelse Sexp.nil;
        self.fun.params = null;
        for ([_]Sexp{ tparams, params }) |group| for (group.items()) |p| {
            const local = self.localOf(facts.syntax.paramNameNode(p) orelse continue) orelse continue;
            if (local.param_name.len > 0) {
                try self.line("var {s} = {s};", .{ local.zig_name, local.param_name });
            }
            if (local.guard != .none) {
                try self.writeIndent(self.indent);
                try self.emitGuard(local);
                try self.w.writeAll("\n");
            } else if (!self.usage.used.contains(local.sym) and !std.mem.eql(u8, local.zig_name, "_")) {
                try self.line("_ = {s};", .{local.zig_name});
            }
        };
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
        // A pointer view is held as a pointer wherever it is bound.
        if (l.ty) |t| if (self.isPtrViewTy(t)) {
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
        const sym = self.facts.symbolOf(leaf) orelse return null;
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

    /// How a hidden storage location's name ends (`hiddenStorage`).
    const StorageSuffix = union(enum) {
        /// A fresh number: `__rig_tmp_7`.
        next,
        /// The number of the construct it belongs to: `__rig_recv_3`.
        id: u32,
        /// That number and its place there: `__rig_arg_3_1`.
        pair: [2]u32,
        /// A name no local has: `__rig_whole`, `__rig_whole_4`.
        fresh,
        /// A copy of the storage named here: `__rig_opt_5_v`.
        copy_of: []const u8,
    };

    /// The Zig name of the hidden storage of `kind` emit makes for
    /// `node`, held `by` (`facts.Storage`). Every hidden storage location
    /// is named here: the storage facts must record it, held the same
    /// way, or emit would make storage the ownership checker did not walk.
    fn hiddenStorage(self: *Emitter, node: Sexp, kind: facts.StorageKind, by: facts.StorageBy, suffix: StorageSuffix) Error![]const u8 {
        const fact = self.facts.storageOf(node, kind) orelse return self.unsupported(node, "hidden storage the storage facts do not record");
        if (fact.by != by) return self.unsupported(node, "hidden storage held other than its storage fact says");
        const base: []const u8 = switch (kind) {
            .temp => "__rig_tmp",
            .header_value => "__rig_hdr",
            .held => "__rig_held",
            .taken => "__rig_src",
            .iterator => "__rig_it",
            .element => "__rig_elem",
            .range_start => "__rig_i",
            .range_end => "__rig_end",
            .subject => "__rig_subject",
            .whole => "__rig_whole",
            .payload => "__rig_payload",
            .as_value => "__rig_opt",
            .lent => "__rig_lent",
            .leaf => "__rig_leaf",
            .error_value => "__rig_err",
            .argument => "__rig_arg",
            .receiver => "__rig_recv",
            .environment, .closure_env => "__rig_env",
            .invoked => "__rig_fn",
            .new_value => "__rig_new",
            .index => "__rig_ix",
            .slot => "__rig_slot",
            // The storage of these is another's: the header's value, the
            // capture it copies, or Zig's (`zigTemporary`).
            .header_copy, .as_copy, .zig_temp => "",
        };
        return switch (suffix) {
            .next => self.fmt("{s}_{d}", .{ base, self.nextId() }),
            .id => |id| self.fmt("{s}_{d}", .{ base, id }),
            .pair => |p| self.fmt("{s}_{d}_{d}", .{ base, p[0], p[1] }),
            .fresh => self.fresh(base),
            .copy_of => |of| self.fmt("{s}_v", .{of}),
        };
    }

    /// Take the address of `node`, a value Zig holds for its statement in
    /// no slot: the storage facts must record it (`zig_temp`), so the
    /// checker knew emit reaches it there.
    fn zigTemporary(self: *Emitter, node: Sexp) Error!void {
        const fact = self.facts.storageOf(node, .zig_temp) orelse return self.unsupported(node, "an address of a value Zig holds that the storage facts do not record");
        if (fact.by != .owned) return self.unsupported(node, "a Zig temporary held other than its storage fact says");
    }

    /// A decision a pass made before emit (`facts.Question`), which emit
    /// only reads: one no pass made is an internal error.
    fn need(self: *Emitter, answer: anytype, node: Sexp) Error!@typeInfo(@TypeOf(answer)).optional.child {
        return answer orelse self.unsupported(node, "a decision no checker made: " ++ @typeName(@TypeOf(answer)));
    }

    fn nextId(self: *Emitter) u32 {
        self.counter += 1;
        return self.counter;
    }

    fn fmt(self: *Emitter, comptime f: []const u8, args: anytype) Error![]const u8 {
        return self.arena.allocator().print(f, args);
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
        return if (self.facts.consumes(sym)) .flag else .scope;
    }

    /// `var _h = base`, for a `header` that holds the value it makes of
    /// which its subject is a part (`SemContext.heldBaseOf`), dropped
    /// where the block the caller opened around the construct ends.
    /// Until the caller restores the returned hoisted count, emitting
    /// the base reads `_h`.
    fn emitHeld(self: *Emitter, header: Sexp) Error!usize {
        const base = self.facts.heldBaseOf(header) orelse return self.unsupported(header, "a held header without its base");
        const mark = self.hoisted.items.len;
        const name = try self.hiddenStorage(header, .held, .owned, .next);
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = ", .{name});
        try self.emitBare(base);
        try self.w.writeAll(";\n");
        try self.poisonAtExit(name);
        const k = if (self.typeOf(base)) |t| self.kindOf(t) else null;
        if (k) |kind| {
            try self.writeIndent(self.indent);
            try self.w.writeAll("defer ");
            try self.writeDrop(name, kind);
            try self.w.writeAll(";\n");
        } else try self.line("_ = &{s};", .{name});
        try self.hoisted.append(self.allocator, .{ .node = base, .name = name });
        return mark;
    }

    fn writeDrop(self: *Emitter, place: []const u8, kind: ResourceKind) Error!void {
        switch (kind) {
            .shared => try self.w.print("{s}.dropStrong()", .{place}),
            .weak => try self.w.print("{s}.dropWeak()", .{place}),
            .value, .optional => try self.w.print("rig.drop(&{s})", .{place}),
        }
    }

    /// The alive flag that must be cleared when `local`'s value leaves.
    fn consumeFlag(local: *const Local) ?[]const u8 {
        return if (local.guard == .flag) local.flag else null;
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
            const first = self.temp_slots.items.len;
            defer self.temp_slots.shrinkRetainingCapacity(first);
            try self.emitTempSlots(stmts[last]);
            try self.w.writeAll("return ");
            try self.emitReturnValue(stmts[last]);
            try self.w.writeAll(";");
        } else {
            try self.emitStmt(stmts[last]);
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// A statement, with the slots of the owning temporaries it drops at
    /// its end: declared before it, each with a `defer` for an exit from
    /// inside it (a failure, a jump), and dropped right after it.
    fn emitStmt(self: *Emitter, sexp: Sexp) Error!void {
        const first = self.temp_slots.items.len;
        try self.emitTempSlots(sexp);
        defer self.temp_slots.shrinkRetainingCapacity(first);
        try self.emitStmtOnly(sexp);
        if (isTerminatingStmt(sexp)) return;
        // The last made is dropped first, as the `defer`s would.
        var i = self.temp_slots.items.len;
        while (i > first) {
            i -= 1;
            try self.writeTempDrop(self.temp_slots.items[i].name);
        }
    }

    fn writeTempDrop(self: *Emitter, name: []const u8) Error!void {
        try self.w.print(" if ({s}_live) {{ {s}_live = false; rig.drop(&{s}); }}", .{ name, name, name });
        if (self.poison) try self.w.print(" rig.poison(&{s});", .{name});
    }

    /// Declare a slot for each owning temporary in statement `stmt` (not
    /// in the blocks or closures it holds, whose statements are emitted
    /// on their own, or in its headers, which are their own statements:
    /// `openHeader`) that has none yet, inline before the statement.
    fn emitTempSlots(self: *Emitter, stmt: Sexp) Error!void {
        var temps: std.ArrayList(Sexp) = .empty;
        try self.facts.stmtTemps(self.arena.allocator(), stmt, &temps);
        for (temps.items) |temp| {
            if (self.tempSlot(temp) != null) continue;
            const name = try self.hiddenStorage(temp, .temp, .owned, .next);
            try self.w.print("var {s}: ", .{name});
            try self.emitTypeTy(self.typeOf(temp) orelse return self.unsupported(temp, "an untyped temporary"));
            try self.w.print(" = undefined; var {s}_live = false; ", .{name});
            if (self.poison) try self.w.print("defer rig.poison(&{s}); ", .{name});
            try self.w.print("defer if ({s}_live) rig.drop(&{s}); ", .{ name, name });
            try self.temp_slots.append(self.allocator, .{ .node = temp.list.id, .name = name });
        }
    }

    fn tempSlot(self: *Emitter, node: Sexp) ?TempSlot {
        if (node != .list) return null;
        for (self.temp_slots.items) |t| if (t.node == node.list.id) return t;
        return null;
    }

    /// Whether statement `stmt` holds an owning temporary its end drops
    /// (`sema.firstStmtTemp`).
    fn hasTemps(self: *Emitter, stmt: Sexp) bool {
        return self.facts.firstStmtTemp(stmt) != null;
    }

    /// Start header `e` (`facts.syntax.isHeaderOf`), its own statement: when it
    /// makes temporaries, a block holds their slots, whose `defer`s drop
    /// them as the block yields the header's value, `(label: { slots
    /// break :label e; })`. The caller writes the value, then calls
    /// `closeHeader`.
    fn openHeader(self: *Emitter, e: Sexp) Error!Header {
        return self.openHeaderBy(e, .copy);
    }

    /// `openHeader` for a block that yields `by`: the header's value
    /// (`copy`), or the address of the place a construct's subject
    /// reaches (`pointer`, `emitSubjectPtr`).
    fn openHeaderBy(self: *Emitter, e: Sexp, by: facts.StorageBy) Error!Header {
        const first = self.temp_slots.items.len;
        if (!self.hasTemps(e)) return .{ .first = first };
        const label = try self.hiddenStorage(e, .header_value, by, .next);
        try self.w.print("({s}: {{ ", .{label});
        try self.emitTempSlots(e);
        try self.w.print("break :{s} ", .{label});
        return .{ .label = label, .first = first };
    }

    fn closeHeader(self: *Emitter, h: Header) Error!void {
        if (h.label.len > 0) try self.w.writeAll("; })");
        self.temp_slots.shrinkRetainingCapacity(h.first);
    }

    /// Header `e`'s value, as `emitBare` writes it.
    fn emitHeader(self: *Emitter, e: Sexp) Error!void {
        const h = try self.openHeader(e);
        try self.emitBare(e);
        try self.closeHeader(h);
    }

    /// `storage.headerPoints`: the header over construct subject `e`
    /// makes temporaries, and its block yields the address of the place
    /// `e` reaches.
    fn headerPoints(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.headerPoints(e), e);
    }

    /// The address of the place a construct's subject `e` reaches, which
    /// its header's block yields (`headerPoints`), in a block that ends
    /// the header's temporaries: `(label: { slots break :label &place; })`.
    /// What the construct binds is the place's own, through the pointer:
    /// writable when the construct `writes` it.
    fn emitSubjectPtr(self: *Emitter, e: Sexp, writes: bool) Error!void {
        const h = try self.openHeaderBy(e, .pointer);
        switch (try self.need(self.facts.handsOver(e), e)) {
            .place => {
                const saved = self.read_place;
                defer self.read_place = saved;
                self.read_place = !writes;
                const saved_subject = self.subject_path;
                defer self.subject_path = saved_subject;
                self.subject_path = e;
                try self.emitAddressOf(e);
            },
            // A lend held as a pointer is the address it lends.
            .lend => try self.emitWriteViewPtr(e),
            // A value that branches over views is the view its branch
            // yields; over places, the address of the leaf it takes.
            .branches => if (self.isPtrViewExpr(e)) try self.emitWriteViewPtr(e) else try self.emitLeafPtr(e, self.typeOf(e) orelse return self.unsupported(e, "an untyped header")),
            else => return self.unsupported(e, "a header that points at no place"),
        }
        try self.closeHeader(h);
    }

    /// Whether the header over construct subject `e`, of header `node`,
    /// is evaluated as a copy: it makes temporaries and reaches no place
    /// (`headerPoints`). The checker records the same (`copiesHeader`).
    fn copiesSubject(self: *Emitter, node: Sexp, e: Sexp) Error!bool {
        const copies = self.hasTemps(e) and !try self.headerPoints(e);
        if (copies != self.facts.copiesHeader(node)) return self.unsupported(node, "a header copy the checker did not record");
        return copies;
    }

    fn emitStmtOnly(self: *Emitter, sexp: Sexp) Error!void {
        self.stmt = sexp;
        const head = sexp.kind() orelse {
            try self.w.writeAll("_ = ");
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        };
        switch (head) {
            .set => try self.emitSet(sexp),
            .drop => try self.emitDrop(sexp),
            // An empty block: a statement wherever Zig wants one.
            .pass => try self.w.writeAll("{}"),
            .@"return" => try self.emitReturn(sexp),
            .@"break" => try self.emitBreak(sexp),
            .@"continue" => try self.emitContinue(sexp),
            .@"if" => try self.emitIf(sexp),
            .@"while", .@"for" => try self.emitLoop(sexp, "", null),
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
                if (try self.discardsValue(sexp)) try self.w.writeAll("_ = ");
                try self.emitExpr(sexp);
                try self.w.writeAll(";");
            },
        }
    }

    /// True when `expr` in statement position produces a value that Zig
    /// requires to be used.
    fn discardsValue(self: *Emitter, expr: Sexp) Error!bool {
        var e = expr;
        while (e.isKind(.propagate)) e = ir.Propagate.value(e);
        if (!e.isKind(.call)) return true;
        if (self.isPrintCall(e) or self.textCall(e) != null) return false;
        // A call lowered to a labeled block is an expression Zig will not
        // take as a statement.
        if (self.facts.calleeOf(e).isKind(.lambda)) return true;
        if (try self.hoistsArgs(e)) return true;
        return !self.yieldsNothing(e);
    }

    /// An expression of type `Void` or `noreturn`.
    fn yieldsNothing(self: *Emitter, e: Sexp) bool {
        const ty = self.typeOf(e) orelse return false;
        return switch (self.facts.types.get(ty)) {
            .void, .noreturn => true,
            else => false,
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

        if (kind.operator()) |op| return self.emitCompound(target, op, expr);
        if (target != .src) {
            return switch (kind) {
                .default => self.emitPlaceAssign(target, expr),
                else => self.unsupported(sexp, "this binding target"),
            };
        }
        if (std.mem.eql(u8, self.srcText(target), "_")) return self.emitDiscard(expr);
        // Sema decides whether the name declares a binding or
        // reassigns one.
        const sym = self.facts.symbolOf(target) orelse return self.unsupported(target, "an unresolved binding");
        if (self.facts.symbols.items[sym].decl_pos == target.src.pos) {
            try self.emitBind(target, sym, type_node, expr);
        } else {
            const local = self.localBySym(sym) orelse return self.unsupported(target, "an assignment to this name");
            try self.emitRebind(local.*, expr, self.facts.repoints(sexp));
        }
    }

    /// `_ = expr`, and a statement `<e` of anything but a name, which
    /// drops what it takes.
    fn emitDiscard(self: *Emitter, expr: Sexp) Error!void {
        // A discarded resource is dropped at once.
        if (self.typeOf(expr)) |t| if (self.kindOf(t) != null) {
            try self.w.writeAll("rig.discard(");
            try self.emitBare(expr);
            return self.w.writeAll(");");
        };
        // A named place is discarded by address: it may be used
        // elsewhere, and Zig rejects discarding a used name. (A clone,
        // or a move the checker did not record as a take, of a value
        // that owns nothing is a copy; a take empties its place.)
        var place = expr;
        const takes = place.isKind(.move) and self.facts.takes(place);
        if (!takes and (place.isKind(.read) or place.isKind(.write) or place.isKind(.clone) or place.isKind(.move))) place = ir.get(place, .operand);
        if ((try self.hasStorage(place)) and !place.isKind(.index)) {
            try self.w.writeAll("_ = &");
            try self.emitPlace(place);
            return self.w.writeAll(";");
        }
        try self.w.writeAll("_ = ");
        try self.emitBare(expr);
        try self.w.writeAll(";");
    }

    /// A new binding.
    fn emitBind(self: *Emitter, name_node: Sexp, sym: SymbolId, type_node: Sexp, expr: Sexp) Error!void {
        if (expr.isKind(.lambda)) return self.emitClosureBinding(name_node, sym, expr);

        const s = self.facts.symbols.items[sym];
        const ty = self.symType(sym);
        const binds_view = if (ty) |t| switch (self.facts.types.get(t)) {
            .read_view, .write_view => true,
            else => false,
        } else true;
        // A read view that copies (`sema.lendByValue`) is held as the
        // value it views, as every other `?T` of the type is, so a call's
        // result can rebind it.
        const copies = if (ty) |t| switch (self.facts.types.get(t)) {
            .read_view => !self.isPtrViewTy(t) and self.genericReadView(t) == null,
            else => false,
        } else false;
        const is_lend = binds_view and !copies and (expr.isKind(.read) or expr.isKind(.write)) and
            (ty == null or (self.facts.writeSliceElem(ty.?) == null and self.facts.callableFn(ty.?) == null));
        // A write view is held as a pointer however it was obtained.
        const holds_ptr = is_lend or (ty != null and self.isPtrViewTy(ty.?));
        var local: Local = .{ .sym = sym, .ty = ty, .is_ptr = holds_ptr };
        if (!holds_ptr) {
            if (ty) |t| local.kind = self.kindOf(t);
        }
        if (local.kind != null) local.guard = self.resourceGuard(sym);

        const needs_ptr_self = local.kind == .value or local.kind == .optional;
        // Assigning a write view writes through it, leaving the
        // pointer as it is.
        const rebound = s.flags.repointed or (s.flags.reassigned and !(ty != null and self.facts.pending.assignWritesThrough(ty.?)));
        // A constant initializer would make a Zig `const` compile-time
        // known, and Zig would then evaluate later arithmetic on it at
        // compile time; Rig treats it as a run-time value.
        const is_var = rebound or (!holds_ptr and (s.flags.written or needs_ptr_self or
            (!s.flags.comptime_known and (isZigComptimeIn(self, expr, 0) or self.facts.isConstInt(sym)))));

        // Evaluate the value before the new name is visible, so a shadow
        // (`new x = x + 1`) reads the old binding.
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            if (is_lend) {
                try self.emitLendAddress(expr);
            } else if (holds_ptr) {
                try self.emitWriteViewPtr(expr);
            } else try self.emitBareAs(expr, ty);
        }

        const stored = try self.declare(local, self.srcText(name_node));
        try self.w.print("{s} {s}", .{ if (is_var) "var" else "const", stored.zig_name });
        if (holds_ptr) {
            // A rebindable view needs its pointer type spelled out.
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
            if (!rebound) try self.w.print(" _ = &{s};", .{stored.zig_name});
        } else if (self.facts.isConstInt(sym) or self.facts.isCtLocal(sym)) {
            // A constant's uses may all be folded away, and an alias of a
            // compile-time parameter may be named only in types, which
            // name the parameter.
            try self.w.print(" _ = &{s};", .{stored.zig_name});
        }
    }

    /// Reassign an existing binding. A resource's old value is dropped
    /// after the new one has been computed (so `a = +a` works), and the
    /// guard is re-armed.
    fn emitRebind(self: *Emitter, local: Local, value: Sexp, repoints: bool) Error!void {
        const s = self.facts.symbols.items[local.sym];
        const writes_through = !repoints and self.facts.pending.assignWritesThrough(s.ty);
        if (local.is_ptr and !writes_through) {
            // A view local is rebound to view something else.
            try self.w.print("{s} = ", .{local.zig_name});
            if (value.isKind(.read) or value.isKind(.write)) try self.emitLendAddress(value) else try self.emitWriteViewPtr(value);
            return self.w.writeAll(";");
        }
        if (local.is_ptr) {
            // Through a `!T` parameter: the caller's value is replaced.
            const pointee = if (local.ty) |t| self.peelViews(t) else null;
            if (pointee != null and self.kindOf(pointee.?) != null) {
                const new = try self.openNewValue(pointee, value);
                return self.w.print("; rig.drop({s}); {s}.* = {s}; }}", .{ local.zig_name, local.zig_name, new.name });
            }
        }
        const kind = local.kind orelse {
            // The value is made first when it can act, so the store goes
            // through the place as the value left it (`storesAfterValue`).
            const first = self.facts.storageOf(value, .new_value) != null;
            if (first) {
                const id = self.nextId();
                const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
                try self.w.print("{{ const {s}", .{name});
                if (local.ty) |t| {
                    try self.w.writeAll(": ");
                    try self.emitTypeTy(if (local.is_ptr) self.peelViews(t) else t);
                }
                try self.w.writeAll(" = ");
                try self.emitBareAs(value, local.ty);
                try self.w.writeAll("; ");
                try self.writeLocalPlace(&local);
                return self.w.print(" = {s}; }}", .{name});
            }
            try self.writeLocalPlace(&local);
            try self.w.writeAll(" = ");
            try self.emitBareAs(value, local.ty);
            try self.w.writeAll(";");
            return;
        };
        const new = try self.openNewValue(local.ty, value);
        try self.w.writeAll("; ");
        if (local.guard == .flag) try self.w.print("if ({s}) ", .{local.flag});
        try self.writeDrop(local.zig_name, kind);
        try self.w.print("; {s} = {s};", .{ local.zig_name, new.name });
        if (local.guard == .flag) try self.w.print(" {s} = true;", .{local.flag});
        try self.w.writeAll(" }");
    }

    /// A new value an assignment stores, `__rig_new_N`, and its `N`.
    const NewValue = struct { id: u32, name: []const u8 };

    /// `{ const __rig_new_N: T = value`: a new value, computed before the
    /// one it replaces is dropped. The type lets a context-typed value
    /// (`Vec()`, `.variant(...)`) resolve.
    fn openNewValue(self: *Emitter, ty: ?TypeId, value: Sexp) Error!NewValue {
        const id = self.nextId();
        const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
        try self.w.print("{{ const {s}", .{name});
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitBare(value);
        return .{ .id = id, .name = name };
    }

    /// Assignment to a field or element. When the place may hold a
    /// resource, the old value is dropped after the new one is computed.
    /// The value and the target's indices are evaluated first
    /// (`openAssign`).
    fn emitPlaceAssign(self: *Emitter, target: Sexp, value: Sexp) Error!void {
        const place_ty = self.typeOf(target);
        if (target.isKind(.index)) if (self.typeOf(ir.Index.object(target))) |t| if (self.isCellVecTy(t)) {
            const order = try self.openAssign(target, value, self.typeOf(target), .value);
            try self.emitCellPtr(ir.Index.object(target));
            try self.w.writeAll(".vecSet(");
            try self.emitBare(ir.Index.index(target));
            try self.w.writeAll(", ");
            try self.emitBare(value);
            try self.w.writeAll(");");
            return self.closeAssign(order);
        };
        if (target != .src and self.isPtrViewExpr(target)) {
            // A field or element holding a write view is rebound.
            const order = try self.openAssign(target, value, null, .view);
            // An element is reached as the slot it is.
            if (target.isKind(.index)) try self.emitIndex(target, true) else try self.emitWriteViewPtr(target);
            try self.w.writeAll(" = ");
            try self.emitWriteViewPtr(value);
            try self.w.writeAll(";");
            return self.closeAssign(order);
        }
        const may_own = if (place_ty) |t| self.kindOf(t) != null else true;
        if (!may_own) {
            const order = try self.openAssign(target, value, place_ty, .value);
            try self.emitPlace(target);
            try self.w.writeAll(" = ");
            try self.emitBareAs(value, place_ty);
            try self.w.writeAll(";");
            return self.closeAssign(order);
        }
        const new = try self.openNewValue(place_ty, value);
        try self.w.writeAll("; ");
        const first = self.hoisted.items.len;
        if (self.facts.pending.actsBeforeStore(target, value)) try self.hoistIndices(target, new.id);
        const slot = try self.hiddenStorage(target, .slot, .pointer, .{ .id = new.id });
        try self.w.print("const {s} = &", .{slot});
        try self.emitPlace(target);
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.print("; rig.drop({s}); {s}.* = {s}; }}", .{ slot, slot, new.name });
    }

    /// How `openAssign` evaluates an assignment's value: as a value, or
    /// as the view a view-holding place is pointed at.
    const AssignValue = enum { value, view };

    /// Every assignment evaluates its value first, then its target's
    /// index expressions from the outside in, and only then finds the
    /// place and stores (SPEC §4), which is the order the ownership
    /// checker walks it in: a call in the value that grows, replaces, or
    /// frees what the target lies in cannot leave the store pointing
    /// into freed memory. When the value or an index can act (a call,
    /// an assignment, a drop, or a jump), this opens a block and
    /// evaluates the value into `__rig_new_N` and each index into
    /// `__rig_ix_N_k`, unless it is pure; the store written next names
    /// them. Returns what `closeAssign` needs, or null when nothing can
    /// act and the order is unobservable.
    fn openAssign(self: *Emitter, target: Sexp, value: Sexp, ty: ?TypeId, how: AssignValue) Error!?usize {
        if (!self.facts.pending.actsBeforeStore(target, value)) return null;
        const first = self.hoisted.items.len;
        const id = self.nextId();
        try self.w.writeAll("{ ");
        if (!try self.isPureArg(value)) {
            const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
            try self.w.print("const {s}", .{name});
            if (ty) |t| {
                try self.w.writeAll(": ");
                try self.emitTypeTy(t);
            }
            try self.w.writeAll(" = ");
            if (how == .view) try self.emitWriteViewPtr(value) else try self.emitBare(value);
            try self.w.writeAll("; ");
            try self.hoisted.append(self.allocator, .{ .node = value, .name = name });
        }
        try self.hoistIndices(target, id);
        return first;
    }

    fn closeAssign(self: *Emitter, order: ?usize) Error!void {
        const first = order orelse return;
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.writeAll(" }");
    }

    /// Evaluate each index of place `e` that is not pure into
    /// `__rig_ix_<id>_<k>`, from the outside in, as `openAssign`
    /// describes.
    fn hoistIndices(self: *Emitter, e: Sexp, id: u32) Error!void {
        switch (e.kind() orelse return) {
            .member => try self.hoistIndices(ir.Member.object(e), id),
            .index => {
                try self.hoistIndices(ir.Index.object(e), id);
                const index = ir.Index.index(e);
                if (!index.isKind(.@"..")) return self.hoistIndex(index, id);
                for ([2]Sexp{ ir.@"..".left(index), ir.@"..".right(index) }) |bound| if (bound != .nil) try self.hoistIndex(bound, id);
            },
            else => {},
        }
    }

    fn hoistIndex(self: *Emitter, index: Sexp, id: u32) Error!void {
        if (try self.isPureArg(index)) return;
        const name = try self.hiddenStorage(index, .index, .owned, .{ .pair = .{ id, @intCast(self.hoisted.items.len) } });
        try self.w.print("const {s}", .{name});
        if (self.typeOf(index)) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = false;
        try self.emitBare(index);
        try self.w.writeAll("; ");
        try self.hoisted.append(self.allocator, .{ .node = index, .name = name });
    }

    /// `x op= e` on a name or place, with the place evaluated once, after
    /// `e` (`openAssign`). The operators that lower to a builtin
    /// (`@divTrunc` for integer `/`, `rig.rem`, `@shlExact`) assign the
    /// builtin's result; the others use Zig's own compound assignment.
    fn emitCompound(self: *Emitter, target: Sexp, op: Tag, value: Sexp) Error!void {
        const builtin: ?[]const u8 = switch (op) {
            .@"/", .@"%" => self.divBuiltin(op, target, value),
            .@"<<" => "@shlExact",
            else => null,
        };
        const shift = op == .@"<<" or op == .@">>";
        // The value of a shift is its amount, of any integer type.
        const value_ty = self.typeOf(if (shift) value else target);
        const order = try self.openAssign(target, value, if (value_ty) |t| self.peelViews(t) else null, .value);
        if (builtin) |b| {
            var slot: []const u8 = "";
            if (target == .src) {
                try self.emitPlace(target);
                try self.w.print(" = {s}(", .{b});
                try self.emitPlace(target);
            } else {
                slot = try self.hiddenStorage(target, .slot, .pointer, .next);
                try self.w.print("{{ const {s} = &", .{slot});
                try self.emitPlace(target);
                try self.w.print("; {s}.* = {s}({s}.*", .{ slot, b, slot });
            }
            try self.w.writeAll(if (shift) ", @intCast(" else ", ");
            try self.emitBare(value);
            if (shift) try self.w.writeAll(")");
            try self.w.writeAll(if (target == .src) ");" else "); }");
            return self.closeAssign(order);
        }
        try self.emitPlace(target);
        try self.w.print(" {s}= ", .{@tagName(op)});
        if (shift) try self.w.writeAll("@intCast(");
        try self.emitBare(value);
        if (shift) try self.w.writeAll(")");
        try self.w.writeAll(";");
        return self.closeAssign(order);
    }

    /// An assignable place: a binding, field, or element.
    fn emitPlace(self: *Emitter, target: Sexp) Error!void {
        if (target == .src) if (self.localOf(target)) |local| {
            if (self.subjectView(target, local)) |inner| return self.writeSubjectView(inner, local.zig_name);
            return self.writeLocalPlace(local);
        };
        if (target.isKind(.index)) {
            // An element holding a write view denotes the viewed
            // value, as a field holding one does (`emitValue`).
            if (self.onSubjectPath(target)) if (self.genericReadViewOf(target)) |inner| {
                try self.writeViewedPtrOpen(inner);
                try self.emitIndex(target, true);
                return self.w.writeAll(").*");
            };
            try self.emitIndex(target, true);
            if (self.isPtrViewExpr(target)) try self.w.writeAll(".*");
            return;
        }
        // A field of an element (`v[i].x = ...`) is reached through the
        // element's slot.
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = true;
        try self.emitExpr(target);
    }

    /// The `T` of the generic read view `local` holds when `name` names it
    /// on the path of the `match` subject being emitted (`onSubjectPath`).
    fn subjectView(self: *Emitter, name: Sexp, local: *const Local) ?TypeId {
        if (!local.is_ptr or !self.onSubjectPath(name)) return null;
        return self.genericReadView(local.ty orelse return null);
    }

    fn writeSubjectView(self: *Emitter, inner: TypeId, zig_name: []const u8) Error!void {
        try self.writeViewedPtrOpen(inner);
        try self.w.print("{s}).*", .{zig_name});
    }

    fn writeLocalPlace(self: *Emitter, local: *const Local) Error!void {
        if (local.is_ptr) if (self.genericReadView(local.ty orelse return self.w.writeAll(local.zig_name))) |inner| {
            try self.writeViewedOpen(inner);
            try self.w.writeAll(local.zig_name);
            return self.w.writeAll(")");
        };
        try self.w.writeAll(local.zig_name);
        if (local.is_ptr) try self.w.writeAll(".*");
    }

    /// `<x` as a statement: drop now. `<e` of anything but a name drops
    /// what it takes, as `_ = <e` does.
    fn emitDrop(self: *Emitter, sexp: Sexp) Error!void {
        const target = ir.Drop.target(sexp);
        if (target != .src) return self.emitDiscard(target);
        const local = self.localOf(target) orelse return self.unsupported(sexp, "this drop");
        if (local.kind) |kind| {
            if (local.guard == .flag) try self.w.print("{s} = false; ", .{local.flag});
            try self.writeDrop(local.zig_name, kind);
            try self.w.writeAll(";");
            return;
        }
        // Ending a view or dropping plain data has no runtime effect;
        // the discard is the binding's use in Zig.
        try self.w.print("_ = &{s};", .{local.zig_name});
    }

    // -------------------------------------------------------------------------
    // Control flow
    // -------------------------------------------------------------------------

    /// The target of a jump with Rig label `label` (`.nil` for none): an
    /// unlabeled jump targets the innermost loop, and a labeled one the
    /// innermost loop or block of that name, at any depth.
    fn jumpTarget(self: *Emitter, label: Sexp) ?*JumpTarget {
        var i = self.targets.items.len;
        while (i > 0) {
            i -= 1;
            const t = &self.targets.items[i];
            if (label == .nil) {
                if (t.is_loop) return t;
            } else if (std.mem.eql(u8, self.srcText(label), t.rig_label)) return t;
        }
        return null;
    }

    /// A fresh Zig label `__rig_<kind>_N`.
    fn newLabel(self: *Emitter, kind: []const u8) Error!*ZigLabel {
        const l = try self.arena.allocator().create(ZigLabel);
        l.* = .{ .name = try self.fmt("__rig_{s}_{d}", .{ kind, self.nextId() }) };
        return l;
    }

    /// The Zig label of a construct the program labels `:name`: the name
    /// itself, unless a construct around it has it too (Zig rejects a
    /// label inside another of the same name).
    fn rigLabel(self: *Emitter, name: []const u8, kind: []const u8) Error!*ZigLabel {
        for (self.targets.items) |t| if (std.mem.eql(u8, t.rig_label, name)) return self.newLabel(kind);
        const l = try self.arena.allocator().create(ZigLabel);
        l.* = .{ .name = try self.fmt("{f}", .{ident(name)}) };
        return l;
    }

    /// The name of label `l`, which a jump is being written to.
    fn jumpTo(l: *ZigLabel) []const u8 {
        l.used = true;
        return l.name;
    }

    /// Write what follows into a buffer until `closeLabeled`, which puts
    /// `label: ` before it when a jump was written to the label.
    fn openLabeled(self: *Emitter, label: *ZigLabel) Error!Labeled {
        const buf = try self.arena.allocator().create(Writer.Allocating);
        buf.* = .init(self.arena.allocator());
        const l: Labeled = .{ .label = label, .saved = self.w, .buf = buf };
        self.w = &buf.writer;
        return l;
    }

    fn closeLabeled(self: *Emitter, l: Labeled) Error!void {
        self.w = l.saved;
        if (l.label.used) try self.w.print("{s}: ", .{l.label.name});
        try self.w.writeAll(l.buf.written());
    }

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
        // A result that is a view held as a pointer, or an optional or a
        // fallible one, returns the pointer; an error value is itself.
        if (self.fun.return_ty) |r| if (self.isPtrViewTy(self.unwrapOptionals(self.unwrapFallible(r)))) {
            const error_value = if (self.typeOf(value)) |t| self.facts.isErrorValue(t) else false;
            if (!error_value) return self.emitWriteViewPtr(value);
        };
        self.bare = true;
        try self.emitValue(value, true);
    }

    /// `(break value-or-_ label?)`: leaves the loop's result block, or
    /// the loop; a value leaves the block of the loop it gives a value to.
    fn emitBreak(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Break.value(node);
        const t = self.jumpTarget(ir.Break.label(node)) orelse return self.unsupported(node, "a `break` with no loop or block to leave");
        if (value == .nil) return self.w.print("break :{s};", .{jumpTo(t.brk)});
        const ty = t.value_ty orelse return self.unsupported(node, "a `break` value outside a loop used as a value");
        try self.w.print("break :{s} ", .{jumpTo(t.brk)});
        self.bare = true;
        try self.emitValueAs(value, ty);
        try self.w.writeAll(";");
    }

    /// `(continue label?)`: goes where the part of the loop being emitted
    /// sends it (`JumpTarget.cont`).
    fn emitContinue(self: *Emitter, node: Sexp) Error!void {
        const t = self.jumpTarget(ir.Continue.label(node)) orelse return self.unsupported(node, "a `continue` with no loop");
        const c = t.cont orelse return self.unsupported(node, "a `continue` to a block");
        try self.w.print("{s} :{s};", .{ c.word, jumpTo(c.label) });
    }

    /// Statement `if`: `(if cond then else?)`.
    fn emitIf(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        if (rig.isConditionJoin(cond)) return self.emitIfJoined(sexp);
        // A value the condition holds (`Header.held`) lives in a block
        // around the `if`.
        if (cond.isKind(.as) and self.facts.headerOf(cond) == .held) {
            try self.openBrace();
            const mark = try self.emitHeld(cond);
            defer self.hoisted.shrinkRetainingCapacity(mark);
            try self.writeIndent(self.indent);
            try self.emitIfAs(sexp);
            try self.w.writeAll("\n");
            return self.closeBrace();
        }
        return self.emitIfAs(sexp);
    }

    /// `emitIf` once a held value is in place.
    fn emitIfAs(self: *Emitter, sexp: Sexp) Error!void {
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

    /// The parts of a binding condition (`rig.bindsInCondition`), in order.
    fn conditionParts(self: *Emitter, cond: Sexp) Error![]const Sexp {
        var parts: std.ArrayList(Sexp) = .empty;
        try self.collectParts(cond, &parts);
        return parts.items;
    }

    fn collectParts(self: *Emitter, cond: Sexp, parts: *std.ArrayList(Sexp)) Error!void {
        if (rig.isConditionJoin(cond)) {
            try self.collectParts(ir.get(cond, .left), parts);
            return self.collectParts(ir.get(cond, .right), parts);
        }
        try parts.append(self.arena.allocator(), cond);
    }

    /// One nested `if` per part of a binding condition, each opening its
    /// block and binding its name (`emitCond`); `fail`, when given, is the
    /// `else` of each. The caller closes them with `closeParts`.
    fn openParts(self: *Emitter, parts: []const Sexp) Error!void {
        for (parts, 0..) |p, i| {
            if (i > 0) try self.writeIndent(self.indent);
            try self.w.writeAll("if ");
            const prelude = try self.emitCond(p);
            try self.openBrace();
            try self.emitPrelude(prelude);
        }
    }

    fn closeParts(self: *Emitter, n: usize, fail: ?[]const u8) Error!void {
        for (0..n) |i| {
            try self.closeBrace();
            if (fail) |f| try self.w.print(" else {s}", .{f});
            if (i + 1 < n) try self.w.writeAll("\n");
        }
    }

    /// Statement `if a as x and ...`: nested `if`s, one per part, sharing
    /// one `else`, which a flag cleared on the way into the body selects.
    ///
    ///     {
    ///         var __rig_else_N = true;
    ///         if (a) |x| { if (x > 0) { __rig_else_N = false; ... } }
    ///         if (__rig_else_N) { ... }
    ///     }
    fn emitIfJoined(self: *Emitter, sexp: Sexp) Error!void {
        const parts = try self.conditionParts(ir.If.cond(sexp));
        const else_ = ir.If.@"else"(sexp);
        try self.pushScope();
        var flag: ?[]const u8 = null;
        if (else_ != .nil) {
            flag = try self.fmt("__rig_else_{d}", .{self.nextId()});
            try self.openBrace();
            try self.line("var {s} = true;", .{flag.?});
            try self.writeIndent(self.indent);
        }
        try self.openParts(parts);
        if (flag) |f| try self.line("{s} = false;", .{f});
        try self.emitStmts(try self.stmtsOf(ir.If.then(sexp)));
        try self.closeParts(parts.len, null);
        try self.popScope();
        if (flag) |f| {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("if ({s}) ", .{f});
            if (else_.isKind(.@"if")) {
                try self.openBrace();
                try self.writeIndent(self.indent);
                try self.emitIf(else_);
                try self.w.writeAll("\n");
                try self.closeBrace();
            } else try self.emitBranchStmt(else_);
            try self.w.writeAll("\n");
            try self.closeBrace();
        }
    }

    /// `(cond) ` for `if`/`while`, or the head of `if expr as name`,
    /// whose prelude binds the name (`emitOptionalHead`).
    fn emitCond(self: *Emitter, cond: Sexp) Error!Prelude {
        if (cond.isKind(.as)) return self.emitOptionalHead(cond);
        try self.w.writeAll("(");
        try self.emitHeader(cond);
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

    /// `(labeled name stmt)`: a labeled loop, or a labeled `match` or
    /// `raw` block, which `break :name` leaves as it leaves a Zig
    /// labeled block.
    fn emitLabeled(self: *Emitter, sexp: Sexp) Error!void {
        const stmt = ir.Labeled.stmt(sexp);
        const name = self.srcText(ir.Labeled.label(sexp));
        if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) return self.emitLoop(stmt, name, null);
        const label = try self.rigLabel(name, "label");
        try self.targets.append(self.allocator, .{ .rig_label = name, .is_loop = false, .brk = label });
        defer _ = self.targets.pop();
        const l = try self.openLabeled(label);
        try self.openBrace();
        try self.emitStmts(&.{stmt});
        try self.closeBrace();
        try self.closeLabeled(l);
    }

    /// A loop being emitted (`emitLoop`).
    const Loop = struct {
        /// The block around the loop, which holds what its header holds
        /// and its `else`, and gives a loop used as a value its value.
        res: *ZigLabel,
        /// That block, once opened.
        outer: ?Labeled = null,
        /// The Zig loop.
        loop: *ZigLabel,
        /// The block of the body, which a `continue` leaves.
        body: *ZigLabel,
        target: JumpTarget,
        /// Its index in `targets`, once entered.
        index: usize = 0,
    };

    /// `while` and every form of `for` (docs/INTERNALS.md, "Loops"):
    ///
    ///     __rig_loop_N: {                  // when there is an `else`, a value, or a held header
    ///         <the values the header holds>
    ///         L: while (true) : (step) {   // or Zig's own `for`, `while (it.next())`
    ///             <one `if` per condition part, each `else break`>
    ///             __rig_body_N: { body }   // `continue` is `break :__rig_body_N`
    ///             <a step that reads a binding of the condition>
    ///         }
    ///         <else>
    ///     }
    ///
    /// A `break` leaves the outer block when there is one, so it skips the
    /// `else`, and otherwise the loop. A label is written only where a
    /// jump goes to it (`openLabeled`).
    fn emitLoop(self: *Emitter, loop: Sexp, rig_label: []const u8, value: ?TypeId) Error!void {
        const else_ = ir.get(loop, .@"else");
        var lp: Loop = .{
            .res = try self.newLabel("loop"),
            .loop = if (rig_label.len > 0) try self.rigLabel(rig_label, "label") else try self.newLabel(if (loop.isKind(.@"while")) "while" else "for"),
            .body = try self.newLabel("body"),
            .target = undefined,
        };
        const has_res = else_ != .nil or value != null;
        lp.target = .{ .rig_label = rig_label, .brk = if (has_res) lp.res else lp.loop, .value_ty = value };
        if (has_res) try self.openLoopBlock(&lp);
        const depth = self.targets.items.len;
        if (loop.isKind(.@"while")) try self.emitWhile(loop, &lp) else try self.emitFor(loop, &lp);
        // The loop has ended: a jump in its `else` targets the loop around it.
        std.debug.assert(self.targets.items.len == depth + 1);
        _ = self.targets.pop();
        if (else_ != .nil) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            if (value) |ty| {
                try self.w.print("break :{s} ", .{jumpTo(lp.res)});
                try self.emitValueBlock(else_, .{}, ty);
                try self.w.writeAll(";");
            } else try self.emitBranchStmt(else_);
        }
        if (lp.outer) |o| {
            try self.w.writeAll("\n");
            try self.closeBrace();
            try self.closeLabeled(o);
        }
    }

    /// Open the block around loop `lp`, if it is not open yet.
    fn openLoopBlock(self: *Emitter, lp: *Loop) Error!void {
        if (lp.outer != null) return;
        lp.outer = try self.openLabeled(lp.res);
        try self.openBrace();
    }

    /// Where the Zig loop starts: on a line of its own in the block
    /// around it.
    fn startLoopLine(self: *Emitter, lp: *Loop) Error!void {
        if (lp.outer != null) try self.writeIndent(self.indent);
    }

    /// Make loop `lp` the target of the jumps that name it, with
    /// `continue` going to `cont` until its body opens.
    fn enterLoop(self: *Emitter, lp: *Loop, cont: ContinueTo) Error!void {
        lp.target.cont = cont;
        lp.index = self.targets.items.len;
        try self.targets.append(self.allocator, lp.target);
    }

    /// Open the body's block, which a `continue` leaves.
    fn openLoopBody(self: *Emitter, lp: *Loop) Error!Labeled {
        self.targets.items[lp.index].cont = .{ .word = "break", .label = lp.body };
        const l = try self.openLabeled(lp.body);
        try self.openBrace();
        return l;
    }

    /// The body's statements and the end of its block.
    fn closeLoopBody(self: *Emitter, lp: *Loop, l: Labeled, body: Sexp) Error!void {
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
        try self.closeLabeled(l);
        self.targets.items[lp.index].cont = .{ .word = "continue", .label = lp.loop };
    }

    /// `(while cond step body else?)` (`emitLoop`): a `while (true)` with
    /// one `if` per part of the condition inside, each leaving the loop
    /// when it fails, then the body's block. A step that reads a binding
    /// of the condition (`sema.stepReadsBinding`) follows the body in the
    /// bindings' scope; any other is the loop's continue expression, which
    /// runs after the bindings end, also after a `continue` in the
    /// condition.
    fn emitWhile(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const cond = ir.While.cond(sexp);
        const step = ir.While.step(sexp);
        const step_inside = self.facts.pending.stepReadsBinding(cond, step);
        try self.startLoopLine(lp);
        try self.enterLoop(lp, .{ .word = "continue", .label = lp.loop });
        const l = try self.openLabeled(lp.loop);
        try self.w.writeAll("while (true) ");
        if (step != .nil and !step_inside) {
            try self.w.writeAll(": (");
            try self.emitStep(step, lp);
            try self.w.writeAll(") ");
        }
        try self.openBrace();
        // `while true` has no condition to fail.
        const always = cond == .src and std.mem.eql(u8, self.srcText(cond), "true");
        const parts: []const Sexp = if (always) &.{} else try self.conditionParts(cond);
        var opened: usize = 0;
        for (parts) |p| {
            try self.writeIndent(self.indent);
            if (p.isKind(.as)) {
                try self.w.writeAll("if ");
                const prelude = try self.emitCond(p);
                try self.openBrace();
                try self.emitPrelude(prelude);
                opened += 1;
            } else {
                try self.w.writeAll("if (!(");
                try self.emitHeader(p);
                try self.w.writeAll(")) break;\n");
            }
        }
        try self.writeIndent(self.indent);
        const body = try self.openLoopBody(lp);
        try self.closeLoopBody(lp, body, ir.While.body(sexp));
        try self.w.writeAll("\n");
        if (step != .nil and step_inside) {
            try self.writeIndent(self.indent);
            try self.emitStep(step, lp);
            try self.w.writeAll("\n");
        }
        for (0..opened) |_| {
            try self.closeBrace();
            try self.w.writeAll(" else break;\n");
        }
        try self.closeBrace();
        try self.closeLabeled(l);
    }

    /// The step of `while` loop `lp`: a statement, so an assignment drops
    /// the value it replaces, in a block a `continue` in it leaves, which
    /// ends the step.
    fn emitStep(self: *Emitter, step: Sexp, lp: *Loop) Error!void {
        const label = try self.newLabel("step");
        const saved = self.targets.items[lp.index].cont;
        self.targets.items[lp.index].cont = .{ .word = "break", .label = label };
        defer self.targets.items[lp.index].cont = saved;
        const l = try self.openLabeled(label);
        try self.w.writeAll("{ ");
        try self.emitStmt(step);
        try self.w.writeAll(" }");
        try self.closeLabeled(l);
    }

    fn usesSymbol(self: *Emitter, node: Sexp, sym: SymbolId) bool {
        if (node == .src) return if (self.facts.symbolOf(node)) |s| s == sym else false;
        if (node != .list) return false;
        for (node.items()) |c| if (self.usesSymbol(c, sym)) return true;
        return false;
    }

    /// A loop used as a value: its block (`emitLoop`) gives it the value
    /// of the `break` that leaves it, or of its `else`.
    ///
    ///     @as(T, __rig_loop_N: {
    ///         for (xs) |x| { ... break :__rig_loop_N v; ... }
    ///         break :__rig_loop_N else_value;
    ///     })
    fn emitLoopValue(self: *Emitter, sexp: Sexp) Error!void {
        const labeled = sexp.isKind(.labeled);
        const loop = if (labeled) ir.Labeled.stmt(sexp) else sexp;
        const ty = self.typeOf(loop) orelse return self.unsupported(sexp, "an untyped loop value");
        self.stmt = sexp;
        try self.writeAsOpen(ty);
        try self.emitLoop(loop, if (labeled) self.srcText(ir.Labeled.label(sexp)) else "", ty);
        try self.w.writeAll(")");
    }

    /// The index binding of `for x, i in ...` when the body reads it.
    fn loopIndex(self: *Emitter, sexp: Sexp) ?SymbolId {
        const sym = self.facts.symbolOf(ir.For.index(sexp)) orelse return null;
        return if (self.usage.used.contains(sym)) sym else null;
    }

    /// `const i: Int = @intCast(counter);` at the top of a loop body.
    fn bindLoopIndex(self: *Emitter, sexp: Sexp, counter: []const u8) Error!void {
        const sym = self.loopIndex(sexp) orelse return;
        const local = try self.declare(.{ .sym = sym, .ty = self.symType(sym) }, self.srcText(ir.For.index(sexp)));
        try self.line("const {s}: {s} = @intCast({s});", .{ local.zig_name, int_zig, counter });
    }

    /// `(for mode binding index-binding source body else?)` (`emitLoop`):
    /// Zig's own `for`, or a `while` over an iterator or a range, whose
    /// body's block binds the element. The source is evaluated before the
    /// loop is entered, so a jump in it targets the loop around this one.
    fn emitFor(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const mode = ir.For.mode(sexp).tag;
        const binding = ir.For.@"var"(sexp);
        const source = ir.For.source(sexp);
        if (source.isKind(.@"..")) return self.emitRangeFor(sexp, lp);

        const src_ty = self.typeOf(source);
        const is_vec = src_ty != null and self.isVecTy(src_ty.?);
        // A Vec or an array of values that move, which the loop takes or
        // its source makes, hands its elements over one at a time.
        if (try self.need(self.facts.forConsumes(sexp), sexp)) return self.emitConsumingFor(sexp, lp, !is_vec);
        const elem_sym = self.facts.symbolOf(binding);
        const elem_ty: ?TypeId = if (elem_sym) |s| self.symType(s) else null;
        const header = self.facts.headerOf(sexp);
        // A source with temporaries that reaches no place is walked as a
        // copy, which the checker records (`copiesHeader`).
        if (mode != .move and header != .taken and !rig.isRangeIndex(source)) _ = try self.copiesSubject(sexp, source);
        // An array the loop takes is held in a `var`, and each element is
        // reached through a pointer into it, as the body's own.
        const owned = header == .taken;
        // A resource element is a view of its slot.
        const by_ptr = mode == .write or owned or
            (elem_ty != null and self.facts.types.get(elem_ty.?) == .read_view);

        // A value the loop holds, or the array it takes, lives in the
        // block around it.
        var taken: []const u8 = "";
        var mark: ?usize = null;
        if (owned or header == .held) {
            try self.openLoopBlock(lp);
            if (header == .held) mark = try self.emitHeld(sexp);
            if (owned) {
                taken = try self.hiddenStorage(sexp, .taken, .owned, .next);
                try self.writeIndent(self.indent);
                try self.w.print("var {s} = ", .{taken});
                try self.emitHeader(source);
                try self.w.writeAll(";\n");
            }
        }
        defer if (mark) |m| self.hoisted.shrinkRetainingCapacity(m);
        try self.startLoopLine(lp);
        try self.pushScope();
        const l = try self.openLabeled(lp.loop);
        try self.w.writeAll("for (");
        // Writing an array's elements in place iterates through a pointer.
        const array_ptr = by_ptr and !is_vec and src_ty != null and self.facts.types.get(self.peelViews(src_ty.?)) == .array;
        if (owned) try self.w.print("&{s}", .{taken}) else if (try self.headerPoints(source)) {
            // A place reached through temporaries is walked where it is.
            try self.emitSubjectPtr(source, mode == .write);
            if (!array_ptr) try self.w.writeAll(".*");
        } else if (array_ptr) try self.emitAddressOf(source) else {
            const h = try self.openHeader(source);
            try self.emitExpr(source);
            try self.closeHeader(h);
        }
        if (is_vec) try self.w.writeAll(".items()");
        // `for b in ?t` walks the bytes of a Text, boxed or not.
        if (src_ty) |t| if (self.textReach(t)) |reach| try self.w.print("{s}.bytes()", .{reach});
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
        try self.enterLoop(lp, .{ .word = "continue", .label = lp.loop });
        const body = try self.openLoopBody(lp);
        try self.bindLoopIndex(sexp, counter);
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
        try self.popScope();
    }

    /// `for x in <v`: the Vec (or the array, `array`) is consumed; each
    /// element is handed to `x`, which owns it for one iteration.
    /// Elements a `break` or `return` leaves behind are dropped with it.
    ///
    ///     { var it = v.intoIter(); defer it.deinit();
    ///       while (it.next()) |e| { var x = e; defer rig.drop(&x); ... } }
    fn emitConsumingFor(self: *Emitter, sexp: Sexp, lp: *Loop, array: bool) Error!void {
        const binding = ir.For.@"var"(sexp);
        const id = self.nextId();
        const it = try self.hiddenStorage(sexp, .iterator, .owned, .{ .id = id });
        const tmp = try self.hiddenStorage(sexp, .element, .owned, .{ .id = id });
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const indexed = self.loopIndex(sexp) != null;

        try self.openLoopBlock(lp);
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = {s}(", .{ it, if (array) "rig.arrayIntoIter" else "" });
        const h = try self.openHeader(ir.For.source(sexp));
        try self.emitMoved(ir.For.source(sexp));
        try self.closeHeader(h);
        try self.w.writeAll(if (array) ");\n" else ").intoIter();\n");
        try self.line("defer {s}.deinit();", .{it});
        if (indexed) try self.line("var {s}: usize = 0;", .{counter});
        try self.startLoopLine(lp);
        try self.enterLoop(lp, .{ .word = "continue", .label = lp.loop });
        const l = try self.openLabeled(lp.loop);
        try self.w.print("while ({s}.next()) |{s}| ", .{ it, tmp });
        if (indexed) try self.w.print(": ({s} += 1) ", .{counter});
        const body = try self.openLoopBody(lp);
        const sym = self.facts.symbolOf(binding);
        const ty: ?TypeId = if (sym) |s| self.symType(s) else null;
        if (ty != null and self.kindOf(ty.?) != null) {
            try self.bindOptionalResource(.{ .cond = sexp, .name = binding, .tmp = tmp });
        } else if (sym != null and self.usage.used.contains(sym.?)) {
            const local = try self.declare(.{ .sym = sym.?, .ty = ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ local.zig_name, tmp });
        } else try self.line("_ = {s};", .{tmp});
        try self.bindLoopIndex(sexp, counter);
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
    }

    /// `for i in a..b`: a half-open integer range.
    fn emitRangeFor(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const binding = ir.For.@"var"(sexp);
        const range = ir.For.source(sexp);
        const id = self.nextId();
        const counter = try self.hiddenStorage(sexp, .range_start, .owned, .{ .id = id });
        const end = try self.hiddenStorage(sexp, .range_end, .owned, .{ .id = id });
        const sym = self.facts.symbolOf(binding);
        const int_ty: TypeId = if (sym) |s| (self.symType(s) orelse self.facts.types.int_id) else self.facts.types.int_id;

        try self.openLoopBlock(lp);
        for ([2][]const u8{ counter, end }, [2]Sexp{ ir.@"..".left(range), ir.@"..".right(range) }, [2][]const u8{ "var", "const" }) |name, bound, decl| {
            try self.writeIndent(self.indent);
            try self.w.print("{s} {s}: ", .{ decl, name });
            try self.emitTypeTy(int_ty);
            try self.w.writeAll(" = ");
            try self.emitHeader(bound);
            try self.w.writeAll(";\n");
        }
        try self.startLoopLine(lp);
        try self.enterLoop(lp, .{ .word = "continue", .label = lp.loop });
        const l = try self.openLabeled(lp.loop);
        try self.w.print("while ({s} < {s}) : ({s} += 1) ", .{ counter, end, counter });
        const body = try self.openLoopBody(lp);
        if (sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .ty = int_ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ stored.zig_name, counter });
        };
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
    }

    // -------------------------------------------------------------------------
    // Match
    // -------------------------------------------------------------------------

    /// How a match reaches its subject (`facts.MatchMode`).
    const MatchMode = facts.MatchMode;

    /// What `emitMatch` knows about a match's subject.
    const MatchInfo = struct {
        match: Sexp,
        mode: MatchMode,
        /// The type matched: the enum a boxed subject holds.
        ty: ?TypeId,
        error_set: bool,
        /// The subject without its `?` / `!`.
        subject: Sexp,
        boxed: bool,
        /// The subject as Zig that reads it again without evaluating it
        /// again (`evalSubject`), or empty when nothing reads it twice.
        reread: []const u8 = "",
        /// A `match <x` of a value no binding holds: it was evaluated
        /// into `reread`, which the arm then takes.
        temp: bool = false,
        /// A read match switches on its subject where it is
        /// (`storage.matchesInPlace`).
        in_place: bool = false,
    };

    /// Whether the field or element path `e` passes through an element.
    fn throughElement(e: Sexp) bool {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) : (p = ir.get(p, .object)) {
            if (p.isKind(.index)) return true;
        }
        return false;
    }

    /// `(match scrutinee arm...)` → `switch`. In value position each arm
    /// yields a value. A match with a guarded arm picks its arm first
    /// (`emitGuardedMatch`).
    fn emitMatch(self: *Emitter, sexp: Sexp, value_pos: bool) Error!void {
        const scrutinee = ir.Match.subject(sexp);
        // An enum in a box or behind a handle is switched on where it is.
        const scrut_ty = self.facts.matchedType(sexp);
        var info: MatchInfo = .{
            .match = sexp,
            .mode = try self.need(self.facts.matchMode(sexp), sexp),
            .ty = scrut_ty,
            .error_set = if (scrut_ty) |t| self.isErrorSetTy(t) else false,
            // `match ?t` / `match !t` switch on the value viewed.
            .subject = lentPlace(scrutinee),
            .boxed = scrut_ty != null and scrut_ty.? != self.typeOf(scrutinee).?,
            .in_place = try self.need(self.facts.matchesInPlace(sexp), sexp),
        };
        // A subject with temporaries that reaches no place is matched as
        // a copy, which the checker records (`copiesHeader`).
        const held_view = try self.need(self.facts.holdsView(sexp), sexp);
        if (info.mode != .consume and !held_view) _ = try self.copiesSubject(sexp, info.subject);
        const guarded = facts.syntax.matchGuarded(sexp);
        // A `match !x` binding of the whole value points at the place, and
        // a `match <x` arm with alternatives drops the value from it: the
        // subject is read again.
        const rereads = try self.need(self.facts.matchRereads(sexp), sexp);
        // Evaluating the subject first, or holding the value it is a part
        // of (`Header.held`), takes a block around the match.
        const held = self.facts.headerOf(sexp) == .held;
        const block = if (try self.need(self.facts.matchBlock(sexp), sexp)) try self.fmt("__rig_match_{d}", .{self.nextId()}) else "";
        var held_mark: ?usize = null;
        defer if (held_mark) |m| self.hoisted.shrinkRetainingCapacity(m);
        if (block.len > 0) {
            if (value_pos) try self.w.print("{s}: ", .{block});
            try self.openBrace();
            if (held) held_mark = try self.emitHeld(sexp);
            try self.evalSubject(&info);
            if (guarded) {
                try self.emitGuardedMatch(sexp, value_pos, info, block);
                try self.w.writeAll("\n");
                return self.closeBrace();
            }
            try self.writeIndent(self.indent);
            if (value_pos) try self.w.print("break :{s} ", .{block});
        } else if (rereads) info.reread = try self.placeText(info);
        const place = info.reread;
        const subject = info.subject;
        try self.w.writeAll("switch (");
        if (info.temp or (info.reread.len > 0 and info.mode != .consume)) {
            try self.w.writeAll(info.reread);
        } else if (try self.headerPoints(subject)) {
            // A place reached through temporaries is switched on where it
            // is, so each payload captured by pointer is the place's own.
            try self.emitSubjectPtr(subject, info.mode == .write);
            try self.w.writeAll(".*");
            if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        } else if (info.mode == .write and try self.need(self.facts.handsOver(subject), subject) == .place and throughElement(subject)) {
            // A place through an element that a write match writes is
            // switched on where it is (a Vec's element reads as a
            // value): `(&v.slot(i).*).*`.
            try self.w.writeAll("(");
            try self.emitSubjectPtr(subject, true);
            try self.w.writeAll(").*");
            if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        } else {
            // A match on a call returning a view held by pointer
            // switches on the value it points to, where it is: a header
            // with temporaries yields the pointer, never the value.
            const by_ptr = !(try self.hasStorage(subject)) and self.isPtrViewExpr(subject);
            const h = try self.openHeader(subject);
            if (by_ptr and h.label.len > 0) {
                try self.emitWriteViewPtr(subject);
                try self.closeHeader(h);
                try self.w.writeAll(".*");
            } else {
                if (by_ptr or self.switchesThroughName(subject)) try self.emitSwitchDeref(subject) else {
                    const saved_path = self.subject_path;
                    defer self.subject_path = saved_path;
                    self.subject_path = subject;
                    try self.emitBare(subject);
                }
                if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
                try self.closeHeader(h);
            }
            if (by_ptr and h.label.len > 0 and info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        }
        try self.w.writeAll(") ");
        try self.openBrace();

        var has_default = false;
        for (ir.Match.arms(sexp)) |arm| {
            const pattern = ir.Arm.pattern(arm);
            const body = ir.Arm.body(arm);
            try self.writeIndent(self.indent);
            try self.pushScope();
            defer self.popScope() catch {};

            var prelude: Prelude = .{};
            if (isCatchAll(self.source, pattern)) {
                has_default = true;
                try self.w.writeAll("else => ");
                const named = !std.mem.eql(u8, self.srcText(pattern), "_");
                switch (info.mode) {
                    .read => if (named) try self.emitCapture(pattern),
                    .write => if (named) {
                        prelude.aliases = try self.wholeAlias(pattern, try self.fmt("&{s}", .{place}), .nil);
                    },
                    .consume => {
                        const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
                        try self.w.print("|{s}| ", .{whole});
                        prelude = try self.ownedParts(&.{if (named) pattern else .nil}, &.{.{ .expr = whole }}, .nil);
                    },
                }
            } else {
                try self.writePatternHead(pattern, info);
                try self.w.writeAll(" => ");
                const captures: []const Sexp = if (pattern.isKind(.variant_pattern)) self.facts.payloadBindings(pattern) orelse &.{} else &.{};
                const vname: []const u8 = if (pattern.isKind(.variant_pattern) or pattern.isKind(.enum_lit)) self.srcText(ir.get(pattern, .name)) else "";
                if (info.mode == .consume) {
                    // The arm owns the value: each field is bound or
                    // dropped at the end of the arm.
                    const fields = if (vname.len > 0) self.variantPayload(info.ty.?, vname) orelse &.{} else &.{};
                    if (vname.len == 0) {
                        // Alternatives: the value is dropped from where it
                        // was, copied before the arm can reassign it.
                        const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
                        prelude = try self.ownedParts(&.{.nil}, &.{.{ .expr = whole }}, .nil);
                        prelude.head = try self.fmt("const {s} = {s};", .{ whole, place });
                    } else if (fields.len > 0) {
                        const payload = try self.hiddenStorage(arm, .payload, .owned, .fresh);
                        try self.w.print("|{s}| ", .{payload});
                        prelude = try self.consumedPayload(captures, fields, payload, .nil);
                    }
                } else if (captures.len > 0) {
                    prelude.aliases = try self.payloadAliases(captures, info, vname, .{ .arm = arm }, .nil);
                    // A payload a read binds as a view is reached in place.
                    const by_ptr = info.mode == .write or for (prelude.aliases) |a| {
                        if (a.addr) break true;
                    } else false;
                    if (prelude.aliases.len > 0) try self.w.print("|{s}{s}| ", .{ if (by_ptr) "*" else "", prelude.aliases[0].payload });
                }
            }
            if (value_pos) try self.emitValueBlock(body, prelude, self.typeOf(sexp)) else try self.emitBodyWith(body, prelude);
            try self.w.writeAll(",\n");
        }
        try self.closeBrace();
        if (block.len > 0) {
            if (value_pos) try self.w.writeAll(";");
            try self.w.writeAll("\n");
            try self.closeBrace();
        }
    }

    /// `facts.syntax.subjectRereadable`.
    fn subjectRereadable(self: *Emitter, info: MatchInfo) bool {
        _ = self;
        return facts.syntax.subjectRereadable(info.subject);
    }

    /// Evaluate the subject once, into `info.reread`: a field path as
    /// it is, an element by its address, a value no binding holds (a
    /// call's result, or what `match <` takes from one) into a local.
    fn evalSubject(self: *Emitter, info: *MatchInfo) Error!void {
        const by = (try self.need(self.facts.subjectHold(info.match), info.match)) orelse {
            info.reread = try self.placeText(info.*);
            return;
        };
        const name = try self.hiddenStorage(info.match, .subject, by, .next);
        const value = if (info.subject.isKind(.move)) ir.Move.operand(info.subject) else info.subject;
        if ((try self.hasStorage(value)) and !info.subject.isKind(.move) and !self.hasTemps(value)) {
            try self.line("const {s} = &{s};", .{ name, try self.placeText(info.*) });
            info.reread = try self.fmt("{s}.*", .{name});
            return;
        }
        // A place reached through temporaries is held as its address,
        // which the header's block yields, and a view a call returns
        // (`match get(e)`) as the pointer it is, never copied: the
        // bindings view the value it points to.
        const points = try self.headerPoints(value);
        if (!info.subject.isKind(.move) and (points or self.isPtrViewExpr(value))) {
            try self.writeIndent(self.indent);
            try self.w.print("const {s} = ", .{name});
            if (points) try self.emitSubjectPtr(value, info.mode == .write) else {
                const h = try self.openHeader(value);
                try self.emitWriteViewPtr(value);
                try self.closeHeader(h);
            }
            try self.w.writeAll(";\n");
            var buf: Writer.Allocating = .init(self.arena.allocator());
            {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                // A generic read view is reached where it points, or
                // where its instance's copy is held (`rig.viewedPtr`).
                if (self.genericReadViewOf(value)) |inner| {
                    try self.w.writeAll("rig.viewedPtr(");
                    try self.emitTypeTy(inner);
                    try self.w.print(", &{s}).*", .{name});
                } else try self.w.print("{s}.*", .{name});
                if (info.boxed) try self.writeMatchReach(self.typeOf(value).?);
            }
            info.reread = buf.written();
            return;
        }
        try self.writeIndent(self.indent);
        try self.w.print("var {s}", .{name});
        if (self.typeOf(value)) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(self.peelViews(t));
        }
        try self.w.writeAll(" = ");
        const h = try self.openHeader(value);
        if (self.isPtrViewExpr(value)) try self.emitDeref(value) else try self.emitBare(value);
        if (info.boxed and self.hasTemps(value)) try self.w.writeAll(".value.*");
        try self.closeHeader(h);
        try self.w.print("; _ = &{s};\n", .{name});
        try self.poisonAtExit(name);
        info.reread = name;
        info.temp = info.mode == .consume;
    }

    /// Whether `e` is the `match` subject being emitted, or a field or
    /// element path on the way to it from the name it starts at
    /// (`subject_path`).
    fn onSubjectPath(self: *const Emitter, e: Sexp) bool {
        var p = self.subject_path;
        while (p != .nil) {
            if (p.isKind(.move) or p.isKind(.read) or p.isKind(.write)) {
                p = ir.get(p, .operand);
                continue;
            }
            if (sameNode(p, e)) return true;
            if (!p.isKind(.member) and !p.isKind(.index)) return false;
            p = ir.get(p, .object);
        }
        return false;
    }

    /// `rig.viewedPtr(T, &view).*`: the `T` a generic read view held at
    /// `view`, a name, a field, or an element, reaches in place: the
    /// value the view points to, or the copy it holds. The caller writes
    /// `view` between `open` and `close`.
    fn writeViewedPtrOpen(self: *Emitter, inner: TypeId) Error!void {
        try self.w.writeAll("rig.viewedPtr(");
        try self.emitTypeTy(inner);
        try self.w.writeAll(", &");
    }

    /// The Zig place of a match's subject, for `match !x` and `match <x`
    /// (whose subject is a binding).
    fn placeText(self: *Emitter, info: MatchInfo) Error![]const u8 {
        var buf: Writer.Allocating = .init(self.arena.allocator());
        const saved_w = self.w;
        self.w = &buf.writer;
        defer self.w = saved_w;
        const saved_path = self.subject_path;
        defer self.subject_path = saved_path;
        self.subject_path = info.subject;
        try self.emitPlace(if (info.subject.isKind(.move)) ir.Move.operand(info.subject) else info.subject);
        if (info.boxed) try self.writeMatchReach(self.typeOf(info.subject).?);
        return buf.written();
    }

    /// The enum a match on a `ty` in a box or behind a handle switches
    /// on: `.value` for each box (a pointer) and handle on the way, the
    /// value itself at the end.
    fn writeMatchReach(self: *Emitter, ty: TypeId) Error!void {
        var t = self.facts.unwrapViews(ty);
        var ptr = false;
        while (true) {
            switch (self.facts.types.get(t)) {
                .shared => |inner| {
                    try self.w.writeAll(if (ptr) ".*.value" else ".value");
                    t = self.facts.unwrapViews(inner);
                    ptr = false;
                    continue;
                },
                else => {},
            }
            const inner = self.facts.boxedType(t) orelse break;
            try self.w.writeAll(".value");
            t = self.facts.unwrapViews(inner);
            ptr = true;
        }
        if (ptr) try self.w.writeAll(".*");
    }

    /// The prong head of a pattern that is not a catch-all: a literal, a
    /// variant, a range, or alternatives.
    fn writePatternHead(self: *Emitter, pattern: Sexp, info: MatchInfo) Error!void {
        if (pattern.isKind(.alt_pattern)) {
            for (ir.AltPattern.alts(pattern), 0..) |alt, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.writePatternHead(alt, info);
            }
            return;
        }
        if (pattern.isKind(.enum_lit) and info.error_set) {
            // Sema gave `.name` against an error the type of its set.
            return self.writeError(self.typeOf(pattern) orelse return self.unsupported(pattern, "an untyped error"), self.srcText(ir.EnumLit.name(pattern)), pattern);
        }
        if (pattern.isKind(.enum_lit) or pattern.isKind(.variant_pattern)) {
            return self.w.print(".{f}", .{ident(self.srcText(ir.get(pattern, .name)))});
        }
        if (pattern.isKind(.range_pattern)) {
            // `lo..hi` is half-open; Zig's `lo...hi` is inclusive. Sema
            // checked both bounds are constants.
            const b = try self.rangeBounds(pattern);
            return self.w.print("{d}...{d}", .{ b[0], b[1] });
        }
        try self.emitExpr(pattern);
    }

    /// The inclusive bounds of range pattern `lo..hi`.
    fn rangeBounds(self: *Emitter, pattern: Sexp) Error![2]Wide {
        const lo = self.facts.constIntOf(ir.RangePattern.lo(pattern)) orelse return self.unsupported(pattern, "this range pattern");
        const hi = self.facts.constIntOf(ir.RangePattern.hi(pattern)) orelse return self.unsupported(pattern, "this range pattern");
        return .{ lo, hi - 1 };
    }

    /// `facts.syntax.isCatchAll`.
    fn isCatchAll(source: []const u8, pattern: Sexp) bool {
        return facts.syntax.isCatchAll(source, pattern);
    }

    /// `x => ...` binding the whole value as `expr`, when the arm uses it
    /// (in `used_in`, when given).
    fn wholeAlias(self: *Emitter, pattern: Sexp, expr: []const u8, used_in: Sexp) Error![]const Alias {
        const local = self.usedPayloadLocal(pattern, used_in) orelse return &.{};
        const stored = try self.declare(local, self.srcText(pattern));
        return self.arena.allocator().dupe(Alias, &.{.{ .zig_name = stored.zig_name, .payload = expr, .field = "" }});
    }

    /// The catch-all binding `pattern` of the matched value `subj`, used
    /// in `used_in`: its address for a write view, and for a read one
    /// captured by address (`storage.catchAllByAddress`, as `emitCapture`
    /// decides it), the value for a copy.
    fn wholeBinding(self: *Emitter, pattern: Sexp, subj: []const u8, info: MatchInfo, used_in: Sexp) Error![]const Alias {
        const local = self.usedPayloadLocal(pattern, used_in) orelse return &.{};
        const t = local.ty orelse return self.unsupported(pattern, "a catch-all binding of unknown type");
        if (info.mode == .write) return self.wholeAlias(pattern, try self.fmt("&{s}", .{subj}), used_in);
        const by_addr = try self.need(self.facts.catchAllCaptured(pattern), pattern);
        const stored = try self.declare(payloadPointee(local, by_addr and !self.isPtrViewTy(t)), self.srcText(pattern));
        const expr = if (by_addr) try self.fmt("&{s}", .{subj}) else subj;
        return self.arena.allocator().dupe(Alias, &.{.{ .zig_name = stored.zig_name, .payload = expr, .field = "" }});
    }

    /// The prelude of a `match <x` arm on payload variant `fields`, held
    /// in `payload`: bound fields become owned locals, and the rest is
    /// dropped at the end of the arm.
    fn consumedPayload(self: *Emitter, captures: []const Sexp, fields: []const facts.Field, payload: []const u8, used_in: Sexp) Error!Prelude {
        if (captures.len == 0) return self.ownedParts(&.{.nil}, &.{.{ .expr = payload }}, used_in);
        const parts = try self.arena.allocator().alloc(OwnedPart, fields.len);
        for (fields, parts) |f, *part| part.* = .{ .expr = try self.fmt("{s}.{f}", .{ payload, ident(f.name) }) };
        return self.ownedParts(captures, parts, used_in);
    }

    /// A match with a guarded arm. A Zig `switch` has no guards, so the
    /// arm is picked first, trying each in order (a guard sees the
    /// bindings it names), and a `switch` on its index runs it:
    ///     { const arm = sel: { if (s == .a) { const r = s.a.r; if (r > 0) break :sel 0; } ... break :sel N; };
    ///       switch (arm) { 0 => { const r = s.a.r; body }, ..., else => unreachable } }
    /// The subject is read in place, or from a copy when it is not a
    /// place (sema rejects a temporary that owns a resource).
    fn emitGuardedMatch(self: *Emitter, sexp: Sexp, value_pos: bool, info: MatchInfo, block: []const u8) Error!void {
        const id = self.nextId();
        const arms = ir.Match.arms(sexp);
        const subj = info.reread;

        // Pick the arm.
        const arm_var = try self.fmt("__rig_arm_{d}", .{id});
        const sel = try self.fmt("__rig_select_{d}", .{id});
        try self.line("const {s}: usize = {s}: {{", .{ arm_var, sel });
        self.indent += 1;
        var picked = false;
        for (arms, 0..) |arm, i| {
            const pattern = ir.Arm.pattern(arm);
            const guard = ir.Arm.guard(arm);
            const catch_all = isCatchAll(self.source, pattern);
            try self.writeIndent(self.indent);
            if (!catch_all) {
                try self.w.writeAll("if (");
                try self.writePatternTest(pattern, info, subj);
                try self.w.writeAll(") ");
            }
            if (guard == .nil) {
                try self.w.print("break :{s} @as(usize, {d});\n", .{ sel, i });
                if (catch_all) {
                    picked = true;
                    break;
                }
                continue;
            }
            try self.openBrace();
            try self.guardBindings(pattern, guard, info, subj);
            try self.writeIndent(self.indent);
            try self.w.writeAll("if (");
            try self.emitHeader(guard);
            try self.w.print(") break :{s} @as(usize, {d});\n", .{ sel, i });
            try self.closeBrace();
            try self.w.writeAll("\n");
        }
        if (!picked) try self.line("break :{s} @as(usize, {d});", .{ sel, arms.len });
        self.indent -= 1;
        try self.line("}};", .{});

        // Run it.
        try self.writeIndent(self.indent);
        if (value_pos) try self.w.print("break :{s} ", .{block});
        try self.w.print("switch ({s}) ", .{arm_var});
        try self.openBrace();
        for (arms, 0..) |arm, i| {
            try self.writeIndent(self.indent);
            try self.w.print("{d} => ", .{i});
            try self.pushScope();
            defer self.popScope() catch {};
            const prelude = try self.armBindings(arm, info, subj);
            if (value_pos) try self.emitValueBlock(ir.Arm.body(arm), prelude, self.typeOf(sexp)) else try self.emitBodyWith(ir.Arm.body(arm), prelude);
            try self.w.writeAll(",\n");
        }
        // No arm ran: impossible, since sema requires the arms to cover
        // every value.
        try self.line("else => unreachable,", .{});
        try self.closeBrace();
        if (value_pos) try self.w.writeAll(";");
    }

    /// A Zig condition that holds when `pattern`, not a catch-all,
    /// matches `subj`.
    fn writePatternTest(self: *Emitter, pattern: Sexp, info: MatchInfo, subj: []const u8) Error!void {
        if (pattern.isKind(.alt_pattern)) {
            try self.w.writeAll("(");
            for (ir.AltPattern.alts(pattern), 0..) |alt, i| {
                if (i > 0) try self.w.writeAll(" or ");
                try self.writePatternTest(alt, info, subj);
            }
            return self.w.writeAll(")");
        }
        if (pattern.isKind(.range_pattern)) {
            const b = try self.rangeBounds(pattern);
            return self.w.print("({s} >= {d} and {s} <= {d})", .{ subj, b[0], subj, b[1] });
        }
        try self.w.print("{s} == ", .{subj});
        try self.writePatternHead(pattern, info);
    }

    /// Before a guard: the bindings of `pattern` that `guard` names, read
    /// from `subj` (for `match <x`, views of the value still in `x`).
    fn guardBindings(self: *Emitter, pattern: Sexp, guard: Sexp, info: MatchInfo, subj: []const u8) Error!void {
        if (isCatchAll(self.source, pattern)) {
            const sym = self.facts.symbolOf(pattern) orelse return;
            if (!self.usesSymbol(guard, sym)) return;
            const aliases = try self.wholeBinding(pattern, subj, info, .nil);
            return self.emitPrelude(.{ .aliases = aliases });
        }
        if (!pattern.isKind(.variant_pattern)) return;
        const vname = self.srcText(ir.VariantPattern.name(pattern));
        const fields = self.variantPayload(info.ty.?, vname) orelse return self.unsupported(pattern, "this payload pattern");
        for (self.facts.payloadBindings(pattern) orelse &.{}, fields) |b, f| {
            const sym = self.facts.symbolOf(b) orelse continue;
            if (!self.usesSymbol(guard, sym)) continue;
            const local = self.payloadLocal(b) orelse continue;
            // A write binds a pointer to each field, and a read one to a
            // field it views (`?F`) or reads in place.
            const addr = try self.need(self.facts.bindsByAddress(b), b);
            const stored = try self.declare(payloadPointee(local, addr), self.srcText(b));
            try self.line("const {s} = {s}{s}.{f}.{f};", .{ stored.zig_name, if (addr) "&" else "", subj, ident(vname), ident(f.name) });
        }
    }

    /// The prelude that binds the names of `pattern` that `body` uses,
    /// for the arm picked by a guarded match, from `subj`.
    fn armBindings(self: *Emitter, arm: Sexp, info: MatchInfo, subj: []const u8) Error!Prelude {
        const pattern = ir.Arm.pattern(arm);
        const body = ir.Arm.body(arm);
        if (info.mode == .consume) {
            // The arm takes the value: `x` is consumed now.
            const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
            var buf: Writer.Allocating = .init(self.arena.allocator());
            if (info.temp) try buf.writer.writeAll(info.reread) else {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                try self.emitBare(info.subject);
            }
            const head = try self.fmt("const {s} = {s};", .{ whole, buf.written() });
            var prelude: Prelude = undefined;
            if (isCatchAll(self.source, pattern)) {
                const named = !std.mem.eql(u8, self.srcText(pattern), "_");
                prelude = try self.ownedParts(&.{if (named) pattern else .nil}, &.{.{ .expr = whole }}, body);
            } else if (pattern.isKind(.variant_pattern)) {
                const vname = self.srcText(ir.VariantPattern.name(pattern));
                const fields = self.variantPayload(info.ty.?, vname) orelse &.{};
                prelude = try self.consumedPayload(self.facts.payloadBindings(pattern) orelse &.{}, fields, try self.fmt("{s}.{f}", .{ whole, ident(vname) }), body);
            } else prelude = try self.ownedParts(&.{.nil}, &.{.{ .expr = whole }}, body);
            prelude.head = head;
            return prelude;
        }
        if (isCatchAll(self.source, pattern)) {
            if (std.mem.eql(u8, self.srcText(pattern), "_")) return .{};
            return .{ .aliases = try self.wholeBinding(pattern, subj, info, body) };
        }
        if (!pattern.isKind(.variant_pattern)) return .{};
        const vname = self.srcText(ir.VariantPattern.name(pattern));
        const captures = self.facts.payloadBindings(pattern) orelse return .{};
        return .{ .aliases = try self.payloadAliases(captures, info, vname, .{ .expr = try self.fmt("{s}.{f}", .{ subj, ident(vname) }) }, body) };
    }

    /// A payload binding: `const zig_name = payload.field`, or of
    /// `payload` itself when `field` is empty (`&place` for the whole
    /// value of a `match !x`); `addr` takes the field's address, for a
    /// `match !x` binding that writes it.
    /// `addr`: the binding points at the field.
    const Alias = struct { zig_name: []const u8, payload: []const u8, field: []const u8, addr: bool = false };

    /// A part of a value a `match <x` arm owns: a field, or the whole
    /// payload or value.
    const OwnedPart = struct { expr: []const u8 };

    /// The prelude of a `match <x` arm: each part named by a binding the
    /// arm uses (in `used_in`, when given; `binds[i]` is `.nil` or `_`
    /// for none) becomes an owned
    /// local, dropped at the end of the arm unless moved; every other
    /// part is dropped at the end of the arm.
    fn ownedParts(self: *Emitter, binds: []const Sexp, parts: []const OwnedPart, used_in: Sexp) Error!Prelude {
        var owned: std.ArrayList(OwnedBinding) = .empty;
        var drops: std.ArrayList([]const u8) = .empty;
        const a = self.arena.allocator();
        for (binds, parts) |b, part| {
            const used = if (b == .src and !std.mem.eql(u8, self.srcText(b), "_")) self.usedPayloadLocal(b, used_in) else null;
            if (used) |l| {
                var local = l;
                if (local.kind != null) local.guard = self.resourceGuard(local.sym);
                const stored = try self.declare(local, self.srcText(b));
                try owned.append(a, .{ .local = stored.*, .expr = part.expr });
            } else try drops.append(a, part.expr);
        }
        return .{ .owned = owned.items, .drops = drops.items };
    }

    /// An owned local a `match <x` arm binds from a part of the value.
    const OwnedBinding = struct { local: Local, expr: []const u8 };

    /// Bindings a branch body starts with: payload field aliases,
    /// or the owning binding of `if expr as name`.
    const Prelude = struct {
        /// A line before the rest: the value a `match <x` arm takes.
        head: []const u8 = "",
        aliases: []const Alias = &.{},
        /// The parts of a consumed value a `match <x` arm binds, and the
        /// parts it drops at its end.
        owned: []const OwnedBinding = &.{},
        drops: []const []const u8 = &.{},
        optional: ?OptionalBinding = null,
        lent: ?OptionalBinding = null,
        /// The error a `catch |err|` handler names, captured as `tmp`.
        err_capture: ?struct { zig_name: []const u8, tmp: []const u8 } = null,

        fn isEmpty(p: Prelude) bool {
            return p.head.len == 0 and p.aliases.len == 0 and p.owned.len == 0 and p.drops.len == 0 and p.optional == null and p.lent == null and p.err_capture == null;
        }
    };

    /// A resource bound by `as`: captured as `tmp`, then owned by a local
    /// declared at the top of the body (or dropped at once for `as _`).
    /// `copy`: a viewed binding of a copy of the value inside, which the
    /// header captures by value (`Facts.copiesHeader`), held in a local.
    const OptionalBinding = struct { cond: Sexp, name: Sexp, tmp: []const u8, copy: bool = false };

    /// `payloadLocal` for a binding used in `used_in`, or anywhere when
    /// it is `.nil`.
    fn usedPayloadLocal(self: *Emitter, name_node: Sexp, used_in: Sexp) ?Local {
        const local = self.payloadLocal(name_node) orelse return null;
        if (used_in != .nil and !self.usesSymbol(used_in, local.sym)) return null;
        return local;
    }

    /// A payload binding local, viewing the scrutinee.
    fn payloadLocal(self: *Emitter, name_node: Sexp) ?Local {
        const sym = self.facts.symbolOf(name_node) orelse return null;
        if (!self.usage.used.contains(sym)) return null;
        const ty = self.symType(sym);
        return .{ .sym = sym, .ty = ty, .kind = if (ty) |t| self.kindOf(t) else null };
    }

    /// `|name| ` for a payload or catch-all binding that the body uses:
    /// `|*name| ` for one that views the matched value where it is.
    fn emitCapture(self: *Emitter, name_node: Sexp) Error!void {
        const local = self.payloadLocal(name_node) orelse return;
        const t = local.ty orelse return self.unsupported(name_node, "a catch-all binding of unknown type");
        const by_addr = try self.need(self.facts.catchAllCaptured(name_node), name_node);
        // A value captured by address is held as a pointer to it; a view
        // held as a pointer is that pointer.
        const stored = try self.declare(payloadPointee(local, by_addr and !self.isPtrViewTy(t)), self.srcText(name_node));
        try self.w.print("|{s}{s}| ", .{ if (by_addr) "*" else "", stored.zig_name });
    }

    /// Where payload bindings read their fields: an expression, or a
    /// capture of `arm`'s named here.
    const PayloadAt = union(enum) { expr: []const u8, arm: Sexp };

    /// Bindings for a payload's fields that the arm uses (in `used_in`,
    /// when given), declared in the arm's scope, read from the payload
    /// `at` names. A `match !x` binding (`writes`) points at its field,
    /// unless the field is itself a view, which is bound as it is.
    fn payloadAliases(self: *Emitter, captures: []const Sexp, info: MatchInfo, variant: []const u8, at: PayloadAt, used_in: Sexp) Error![]const Alias {
        const writes = info.mode == .write;
        const fields = self.variantPayload(info.ty.?, variant) orelse return self.unsupported(captures[0], "this payload pattern");
        var out: std.ArrayList(Alias) = .empty;
        var payload: ?[]const u8 = switch (at) {
            .expr => |e| e,
            .arm => null,
        };
        // A capture is by address when a binding views or writes its
        // field, and a copy otherwise.
        var by_addr = writes;
        for (captures) |c| {
            if (self.usedPayloadLocal(c, used_in) == null) continue;
            if (try self.need(self.facts.bindsByAddress(c), c)) by_addr = true;
        }
        for (captures, fields) |c, f| {
            const local = self.usedPayloadLocal(c, used_in) orelse continue;
            const addr = try self.need(self.facts.bindsByAddress(c), c);
            const stored = try self.declare(payloadPointee(local, addr), self.srcText(c));
            if (payload == null) payload = try self.hiddenStorage(at.arm, .payload, if (by_addr) .pointer else .copy, .fresh);
            try out.append(self.arena.allocator(), .{ .zig_name = stored.zig_name, .payload = payload.?, .field = f.name, .addr = addr });
        }
        return out.items;
    }

    /// A payload binding `local` bound by address (`addr`) holds a pointer
    /// to the field, also when its type is the field's own (a type
    /// parameter's value read in place): reading it reads the field.
    fn payloadPointee(local: Local, addr: bool) Local {
        var l = local;
        if (addr) l.is_ptr = true;
        return l;
    }

    fn emitPrelude(self: *Emitter, prelude: Prelude) Error!void {
        if (prelude.head.len > 0) try self.line("{s}", .{prelude.head});
        for (prelude.aliases) |a| {
            if (a.field.len == 0) {
                try self.line("const {s} = {s};", .{ a.zig_name, a.payload });
            } else try self.line("const {s} = {s}{s}.{f};", .{ a.zig_name, if (a.addr) "&" else "", a.payload, ident(a.field) });
        }
        for (prelude.drops) |d| try self.line("defer rig.discard({s});", .{d});
        for (prelude.owned) |o| {
            const is_var = o.local.kind == .value or o.local.kind == .optional;
            try self.line("{s} {s} = {s};", .{ if (is_var) "var" else "const", o.local.zig_name, o.expr });
            if (o.local.guard != .none) {
                try self.writeIndent(self.indent);
                try self.emitGuard(&o.local);
                try self.w.writeAll("\n");
            } else if (is_var) try self.line("_ = &{s};", .{o.local.zig_name});
        }
        if (prelude.optional) |o| try self.bindOptionalResource(o);
        if (prelude.lent) |o| try self.bindOptionalView(o);
        if (prelude.err_capture) |c| try self.line("const {s}: anyerror = {s};", .{ c.zig_name, c.tmp });
    }

    /// `(expr) |capture| ` for `if expr as name` / `while expr as name`.
    /// Plain data is captured under the binding's name; a resource is
    /// captured as a temporary that the returned prelude hands to an
    /// owning local inside the body.
    fn emitOptionalHead(self: *Emitter, cond: Sexp) Error!Prelude {
        const name = ir.As.name(cond);
        const value = ir.As.value(cond);
        const sym = self.facts.symbolOf(name);
        // The header binds a copy of a value with temporaries that reaches
        // no place (`copiesHeader`); a place it reaches, the place's own.
        const owns = value.isKind(.move) or (try self.need(self.facts.handsOver(value), value) == .made and !self.facts.isReadOrWriteView(self.typeOf(value) orelse return self.unsupported(value, "an untyped `as` value")));
        const copies = !owns and try self.copiesSubject(cond, value);
        const points = try self.headerPoints(value);
        // A place, or a part of a value the `if` holds, is bound where it
        // stands, as `if ?o as x` binds it (`Header`).
        if (self.facts.headerOf(cond) != null) {
            try self.w.writeAll("(");
            if (points) {
                try self.emitSubjectPtr(value, false);
                try self.w.writeAll(".*");
            } else try self.emitBare(value);
            try self.w.writeAll(") ");
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .pointer, .next);
            try self.w.print("|*{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp } };
        }
        // Over a view of an optional, a viewed binding points into it.
        if ((try self.viewsOptionalValue(value)) and copies) {
            // A view of a temporary the header drops: the optional is
            // read inside the header, and the binding views a copy of the
            // value inside, which the ownership checker lets nothing use
            // past the header.
            try self.w.writeAll("(");
            const h = try self.openHeader(value);
            try self.w.writeAll("(");
            try self.emitBare(value);
            try self.w.writeAll(").*");
            try self.closeHeader(h);
            try self.w.writeAll(") ");
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .copy, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp, .copy = true } };
        }
        if (try self.viewsOptionalValue(value)) {
            // A name holding a view is emitted as the place it points to.
            // `o` and `<o` of a name holding the view are the place.
            const named = value == .src or (value.isKind(.move) and ir.Move.operand(value) == .src);
            if (points) {
                // A place reached through temporaries is viewed where it is.
                try self.w.writeAll("(");
                try self.emitSubjectPtr(value, false);
                try self.w.writeAll(".*) ");
            } else if (named) {
                try self.w.writeAll("(");
                try self.emitBare(value);
                try self.w.writeAll(") ");
            } else {
                // Any other view, a field's or an element's included, is
                // read through the pointer it is, once.
                try self.w.writeAll("((");
                try self.emitWriteViewPtr(value);
                try self.w.writeAll(").*) ");
            }
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .pointer, .next);
            try self.w.print("|*{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp } };
        }
        try self.w.writeAll("(");
        if (points) {
            try self.emitSubjectPtr(value, false);
            try self.w.writeAll(".*");
        } else try self.emitHeader(value);
        try self.w.writeAll(") ");
        // `as _` binds no symbol; a resource inside is dropped at once.
        const ty: ?TypeId = if (sym) |s| self.symType(s) else if (self.typeOf(value)) |t| switch (self.facts.types.get(self.peelViews(t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        if (ty != null and self.kindOf(ty.?) != null) {
            const tmp = try self.hiddenStorage(cond, .as_value, .owned, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .optional = .{ .cond = cond, .name = if (sym != null) name else .nil, .tmp = tmp } };
        }
        if (sym == null or !self.usage.used.contains(sym.?)) {
            try self.w.writeAll("|_| ");
        } else {
            // A read binding of a write view to a value read by copy holds
            // the write view, a pointer to that value
            // (`Facts.readsThroughWrite`).
            const through = if (self.optionalInner(value)) |inner| self.facts.readsThroughWrite(sym.?, inner) else null;
            const local = try self.declare(.{ .sym = sym.?, .ty = ty, .is_ptr = through == .value }, self.srcText(name));
            try self.w.print("|{s}| ", .{local.zig_name});
        }
        return .{};
    }

    /// `storage.viewsOptionalValue`.
    fn viewsOptionalValue(self: *Emitter, value: Sexp) Error!bool {
        return self.need(self.facts.viewsOptionalValue(value), value);
    }

    /// A view bound by `as`: `tmp` points at the value inside the
    /// optional, and the binding is declared from it at the top of the body.
    fn bindOptionalView(self: *Emitter, o: OptionalBinding) Error!void {
        const sym = self.facts.symbolOf(o.name).?;
        const ty = self.symType(sym).?;
        const local = try self.declare(.{ .sym = sym, .ty = ty }, self.srcText(o.name));
        // A read binding of a write view inside the optional is the read
        // view of what it views: the write view itself, or the value it
        // points at, copied out (`Facts.readsThroughWrite`).
        const through: ?facts.ThroughWrite = if (self.optionalInner(ir.As.value(o.cond))) |inner| self.facts.readsThroughWrite(sym, inner) else null;
        if (o.copy) {
            const copy = try self.hiddenStorage(o.cond, .as_copy, .copy, .{ .copy_of = o.tmp });
            try self.line("var {s} = {s};", .{ copy, o.tmp });
            try self.poisonAtExit(copy);
            if (through) |t| return self.line("const {s} = {s}{s};", .{ local.zig_name, copy, if (t == .value) ".*" else "" });
            return self.line("const {s} = &{s};", .{ local.zig_name, copy });
        }
        if (through) |t| return self.line("const {s} = {s}.*{s};", .{ local.zig_name, o.tmp, if (t == .value) ".*" else "" });
        try self.line("const {s} = {s}{s};", .{ local.zig_name, o.tmp, if (local.is_ptr) "" else ".*" });
    }

    /// The type inside the optional `value` gives, through any views.
    fn optionalInner(self: *Emitter, value: Sexp) ?TypeId {
        const t = self.typeOf(value) orelse return null;
        return switch (self.facts.types.get(self.peelViews(t))) {
            .optional => |inner| inner,
            else => null,
        };
    }

    /// The owning local of a resource bound by `as`, dropped at the end
    /// of the body unless it is moved out.
    fn bindOptionalResource(self: *Emitter, o: OptionalBinding) Error!void {
        if (o.name == .nil) return self.line("rig.discard({s});", .{o.tmp});
        const sym = self.facts.symbolOf(o.name).?;
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
        // A part of the value whose use is known has that use; any other
        // value has the use its own context recorded.
        const saved_use = self.use;
        const saved_use_node = self.use_node;
        defer {
            self.use = saved_use;
            self.use_node = saved_use_node;
        }
        if (!self.partOfUse(sexp)) self.use = self.facts.useOf(sexp);
        self.use_node = sexp;
        const want_ptr = self.want_ptr;
        self.want_ptr = false;
        const bare = self.bare;
        self.bare = false;
        // An owning temporary is kept in its statement's slot, which
        // drops it at the statement's end.
        // A value lent bare is lent around its temporary's slot, as `?e`
        // lends it (unless an argument hoisted before the call holds it).
        if (!sameNode(sexp, self.lending) and self.hoistedOf(sexp) == null) if (self.facts.lendOf(sexp)) |lend| if (lend.implicit) return self.emitLend(sexp, lend, tail, want_ptr);
        // (An argument hoisted before its call was kept there: its name
        // holds the kept value.)
        if (self.facts.dropsTemp(sexp) and !sameNode(sexp, self.keeping) and self.hoistedOf(sexp) == null) {
            const slot = self.tempSlot(sexp) orelse return self.unsupported(sexp, "a temporary outside a statement");
            const saved = self.keeping;
            const saved_ptr = self.ptr_tail;
            defer {
                self.keeping = saved;
                self.ptr_tail = saved_ptr;
            }
            self.keeping = sexp;
            // The slot holds the value: a view of it, the pointer a write
            // lend wants, is taken from the slot (`rig.keep`'s result).
            self.ptr_tail = false;
            try self.w.print("rig.keep(&{s}, &{s}_live, ", .{ slot.name, slot.name });
            self.bare = true;
            try self.emitValue(sexp, tail);
            return self.w.writeAll(").*");
        }
        // A temporary holds the value its context reads (`hoist`).
        if (self.hoistedOf(sexp)) |h| {
            if (h.flag.len > 0) return self.w.print("rig.take(&{s}, {s})", .{ h.flag, h.name });
            return self.w.print("{s}{s}", .{ h.name, if (h.ptr) ".*" else "" });
        }
        if (!sameNode(sexp, self.lending)) if (self.facts.lendOf(sexp)) |lend| if (!lend.has(.read_only)) return self.emitLend(sexp, lend, tail, lend.implicit and want_ptr);
        if (!want_ptr and self.readsThrough(sexp)) return self.emitDeref(sexp);
        const literal_ty = self.literal_ty;
        self.literal_ty = null;
        defer self.literal_ty = literal_ty;
        switch (sexp) {
            .src => if (literal_ty != null and isNumberText(self.srcText(sexp))) {
                const text = self.srcText(sexp);
                try self.writeAsOpen(literal_ty.?);
                try self.w.print("{s}{s})", .{ if (text[0] == '.') "0" else "", text });
            } else try self.emitName(sexp, tail),
            .list => try self.emitList(sexp, tail, bare, literal_ty),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// `sexp`, lent where a view of another type is expected, as the rows
    /// of the lend table make it (`SemContext.lendOf`).
    fn emitLend(self: *Emitter, sexp: Sexp, lend: facts.Lend, tail: bool, as_ptr: bool) Error!void {
        const saved = self.lending;
        defer self.lending = saved;
        self.lending = sexp;
        if (lend.callable()) |fn_ty| {
            // A stack closure lent bare is lent as `?f` lends it.
            if (lend.implicit and sexp == .src) if (self.localOf(sexp)) |local| if (local.stack_closure) return self.emitFnRef(sexp, fn_ty);
            return self.emitLentCallable(sexp, fn_ty);
        }
        const rows = lend.steps();
        var first: facts.LendStep = .lift;
        for (rows) |r| if (r != .lift) {
            first = r;
            break;
        };
        // What the lend starts from: the value written `?x` or `!x` here,
        // the bare value lent as `?x` would be, or the view `sexp` already
        // is, which is a pointer to its value or (a scalar's or a view's)
        // a copy of it.
        const written = sexp.isKind(.read) or sexp.isKind(.write);
        if (lend.implicit and rows.len == 0) {
            // `?x` where a `?T` is expected: the address of `x`, or a copy
            // of a scalar or a view.
            if (!self.isPtrViewTy(lend.view)) {
                self.bare = true;
                return self.emitValue(sexp, false);
            }
            return self.emitReadLend(sexp, self.genericReadView(lend.view) != null);
        }
        var buf: Writer.Allocating = .init(self.arena.allocator());
        var at: LendAt = .{ .text = "", .ptr = true };
        var from: TypeId = facts.type_invalid;
        {
            const saved_w = self.w;
            self.w = &buf.writer;
            defer self.w = saved_w;
            if (!(written or lend.implicit) or (written and first == .unbox and !lend.has(.text))) {
                try self.w.writeAll("(");
                self.bare = true;
                try self.emitValue(sexp, tail and !written);
                try self.w.writeAll(")");
                at.ptr = written or self.isPtrViewExpr(sexp);
                from = self.facts.unwrapViews(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped lend"));
            } else {
                const operand = if (written) ir.get(sexp, .operand) else sexp;
                from = self.facts.unwrapViews(self.typeOf(operand) orelse return self.unsupported(sexp, "an untyped lend"));
                const vec = self.facts.types.get(from) == .parameterized_nominal;
                if (lend.has(.text)) {
                    try self.emitExpr(operand);
                    at.ptr = false;
                } else if (first == .handle or first == .optional or (first == .elems and vec)) {
                    try self.emitMemberBase(operand, self.typeOf(operand));
                    at.ptr = false;
                } else {
                    const saved_read = self.read_place;
                    defer self.read_place = saved_read;
                    self.read_place = !sexp.isKind(.write);
                    const unbox = first == .unbox;
                    if (unbox) try self.w.writeAll("(");
                    try self.emitAddressOf(operand);
                    if (unbox) try self.w.writeAll(")");
                }
            }
        }
        at.text = buf.written();
        return self.w.writeAll(try self.lendChain(sexp, at, from, rows, lend.view, as_ptr));
    }

    /// A value a lend reaches, as Zig text: a pointer to it (`ptr`), or
    /// the value itself, whose fields and methods Zig reaches the same.
    const LendAt = struct { text: []const u8, ptr: bool };

    /// The view the lend table's `rows` make of the value `at`, of type
    /// `from`, where a `view` is expected (`emitLend`), for the lend
    /// `node`.
    fn lendChain(self: *Emitter, node: Sexp, start: LendAt, start_from: TypeId, rows: []const facts.LendStep, start_view: TypeId, as_ptr: bool) Error![]const u8 {
        const types = self.facts.types;
        var at = start;
        var from = start_from;
        var view = start_view;
        for (rows, 0..) |row, i| switch (row) {
            .lift => view = types.get(view).optional,
            .unbox => {
                at = .{ .text = try self.fmt("{s}.value", .{at.text}), .ptr = true };
                from = self.facts.boxedType(from).?;
            },
            // A handle is a pointer: reached through a pointer to it, it is
            // dereferenced first.
            .handle => {
                const handle = if (at.ptr) try self.fmt("({s}).*", .{at.text}) else at.text;
                at = .{ .text = try self.fmt("{s}.value", .{handle}), .ptr = false };
                from = types.get(from).shared;
            },
            // An array's address is a slice; a Vec's elements are its items.
            .elems => return if (types.get(from) == .array)
                (if (at.ptr) at.text else try self.fmt("&{s}", .{at.text}))
            else
                self.fmt("{s}.items()", .{at.text}),
            .text => return self.fmt("{s}.bytes()", .{at.text}),
            .read_only => return at.text,
            // The view of the value inside, or `none`.
            .optional => {
                const name = try self.hiddenStorage(node, .lent, .pointer, .next);
                const inner = try self.lendChain(node, .{ .text = name, .ptr = true }, types.get(from).optional, rows[i + 1 ..], types.get(view).optional, false);
                const value = if (at.ptr) try self.fmt("({s}).*", .{at.text}) else at.text;
                return self.fmt("(if ({s}) |*{s}| {s} else null)", .{ value, name, inner });
            },
            .callable => unreachable,
        };
        const ptr = if (at.ptr) at.text else try self.fmt("&{s}", .{at.text});
        return switch (types.get(view)) {
            .read_view => if (as_ptr) ptr else self.fmt("rig.lend({s})", .{ptr}),
            else => ptr,
        };
    }

    fn emitName(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const name = self.srcText(sexp);
        if (self.localOf(sexp)) |local| {
            if (self.rt_names and !self.keep_comptime and self.facts.symbols.items[local.sym].flags.comptime_known) {
                return self.w.print("rig.rt({s})", .{local.zig_name});
            }
            if (tail and self.ptr_tail and local.is_ptr) return self.w.writeAll(local.zig_name);
            if (self.subjectView(sexp, local)) |inner| return self.writeSubjectView(inner, local.zig_name);
            return if (tail and try self.takesTail(sexp, local)) self.writeTake(local) else self.writeLocalPlace(local);
        }
        if (std.mem.eql(u8, name, "none")) return self.w.writeAll("null");
        if (name[0] == '\'') return writeSingleQuoted(self.w, name);
        if (facts.syntax.isFloatLiteralText(name)) {
            // Typed, so arithmetic on literals rounds like run-time Float math.
            try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.float_id);
            return self.w.print("{s}{s})", .{ if (name[0] == '.') "0" else "", name });
        }
        if (isLiteralText(name)) return self.w.writeAll(name);
        // A built-in type named in an expression: `Endian.big`.
        if (self.facts.symbolOf(sexp)) |id| if (id == self.facts.endian_sym_id) return self.writeNominalName(id);
        if (self.rt_names and !self.keep_comptime and self.isModuleConst(sexp)) {
            try self.w.writeAll("rig.rt(");
            try self.writeModuleName(name);
            return self.w.writeAll(")");
        }
        try self.writeModuleName(name);
    }

    /// A module constant, or a generic type's value parameter: a
    /// compile-time name without a local.
    fn isModuleConst(self: *Emitter, sexp: Sexp) bool {
        const id = self.facts.symbolOf(sexp) orelse return false;
        const sym = self.facts.symbols.items[id];
        return (sym.kind == .local or sym.kind == .param) and sym.flags.comptime_known;
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

    /// Whether `sexp`, the value being emitted, is the value whose use is
    /// known or a part of it (`facts.syntax.valueParts`), directly or as the
    /// block whose tail the part is.
    fn partOfUse(self: *const Emitter, sexp: Sexp) bool {
        if (self.use_node == .nil) return false;
        if (sameNode(sexp, self.use_node)) return true;
        var parts = facts.syntax.valueParts(self.use_node);
        while (parts.next()) |p| if (sameNode(p.node, sexp) or sameNode(p.node, facts.syntax.tailOf(sexp))) return true;
        return false;
    }

    /// Whether name `sexp`, at a tail of the value being emitted, moves
    /// out of `local`: only where the value's context takes it
    /// (`facts.Use`), never where it is read in place. A binding no drop
    /// flag guards has nothing to disarm. A value whose context recorded
    /// no use is an internal error in every build: neither a move nor a
    /// read is right without one.
    fn takesTail(self: *Emitter, sexp: Sexp, local: *const Local) Error!bool {
        if (consumeFlag(local) == null) return false;
        if (self.facts.readsInPlace(sexp)) return false;
        const use = self.use orelse return self.unsupported(sexp, "a value whose use no context recorded");
        return use == .take;
    }

    /// `local`'s value moving out: `rig.take(&flag, x)`, which yields `x`
    /// and disarms a scope-exit drop (`consumeFlag`), or `x` when no drop
    /// is armed.
    fn writeTake(self: *Emitter, local: *const Local) Error!void {
        const flag = consumeFlag(local) orelse return self.writeLocalPlace(local);
        try self.w.print("rig.take(&{s}, ", .{flag});
        try self.writeLocalPlace(local);
        try self.w.writeAll(")");
    }

    /// A value stored into a field, payload, or element: a write view is
    /// stored as its pointer.
    fn emitStored(self: *Emitter, e: Sexp) Error!void {
        if (self.isPtrViewExpr(e) and !self.facts.readsThrough(e)) return self.emitWriteViewPtr(e);
        try self.emitBare(e);
    }

    /// Whether every name in `e` is a constant binding, so folding it
    /// drops no reference Zig would miss (a branch a constant condition
    /// skips may name other locals).
    fn onlyConstantLeaves(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => {
                const sym = self.facts.symbolOf(e) orelse return true;
                return self.facts.isConstInt(sym);
            },
            .list => {
                for (e.items()) |c| if (!self.onlyConstantLeaves(c)) return false;
                return true;
            },
            else => return true,
        }
    }

    /// Every leaf of `e` is a literal.
    fn literalLeaves(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => return self.facts.symbolOf(e) == null,
            .list => {
                for (e.items()) |c| if (!self.literalLeaves(c)) return false;
                return true;
            },
            else => return true,
        }
    }

    fn emitIntConstant(self: *Emitter, sexp: Sexp, v: Wide) Error!void {
        const t = self.typeOf(sexp);
        const concrete = t != null and self.facts.types.get(t.?) == .int;
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
        return switch (self.facts.types.get(t)) {
            .int, .float => t,
            .int_literal => self.facts.types.int_id,
            .float_literal => self.facts.types.float_id,
            else => null,
        };
    }

    fn hasPayloadVariants(self: *Emitter, ty: TypeId) bool {
        const decl = self.facts.nominalDecl(ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
        }
        return false;
    }

    fn isEnumTy(self: *Emitter, ty: TypeId) bool {
        const decl = self.facts.nominalDecl(ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| if (f.is_variant) return true;
        return false;
    }

    /// An expression yielding a pointer view where its context reads the
    /// value behind it (`SemContext.readsThrough`): `!x`, or a call
    /// returning `!Int`. A name, field, or element holding a view reads
    /// through it already.
    fn readsThrough(self: *Emitter, e: Sexp) bool {
        if (e == .src or e.isKind(.member) or e.isKind(.index)) return false;
        return self.facts.readsThrough(e) and self.isPtrViewExpr(e);
    }

    /// An expression whose value is a writable slice `![]T`.
    fn isWriteSliceExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.facts.writeSliceElem(t) != null;
    }

    /// An expression whose value is a pointer view (see `isPtrViewTy`).
    fn isPtrViewExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.isPtrViewTy(t);
    }

    /// A view held as a pointer: a write view, and a read view of a
    /// value that owns resources or holds a `Cell` (see `readViewIsPtr`).
    /// A `![]T` is a Zig slice, which points at its elements itself.
    fn isPtrViewTy(self: *Emitter, ty: TypeId) bool {
        return self.facts.viewHeldAsPointer(ty);
    }

    /// A read view of a scalar or a view is a copy
    /// (`sema.lendByValue`); anything else is lent by address.
    fn readViewIsPtr(self: *Emitter, inner: TypeId) bool {
        return !self.facts.lendByValue(inner);
    }

    /// The `T` of a read view `?T` whose form depends on a generic
    /// type's arguments: `T` holds a type parameter and neither owns
    /// resources nor holds a Cell on its own. It is emitted as
    /// `rig.ReadView(T)`, which applies `readViewIsPtr`'s rule to each
    /// instance, so an instance agrees with the code that uses it
    /// (`?Wrap[Int]` is a copy). Code that depends on the form goes through
    /// `rig.lend` and `rig.viewed`; the rest treats it as a pointer, since
    /// Zig reaches fields and methods through either.
    fn genericReadView(self: *Emitter, ty: TypeId) ?TypeId {
        return self.facts.genericReadView(ty);
    }

    fn genericReadViewOf(self: *Emitter, e: Sexp) ?TypeId {
        return self.genericReadView(self.typeOf(e) orelse return null);
    }

    /// `?x` or `!x` held by pointer: the address of `x`, or for a generic
    /// read view, `rig.lend` of it.
    fn emitLendAddress(self: *Emitter, e: Sexp) Error!void {
        if (!sameNode(e, self.lending)) if (self.facts.lendOf(e)) |lend| if (!lend.has(.read_only) and lend.callable() == null) return self.emitLend(e, lend, false, true);
        const operand = ir.get(e, .operand);
        // A read view reaches a Vec element through a read-only slot, a
        // write view through a writable one.
        const saved_read = self.read_place;
        defer self.read_place = saved_read;
        self.read_place = e.isKind(.read);
        const lends_on = if (self.typeOf(operand)) |t| self.facts.types.get(t) == .read_view else false;
        if (lends_on or !e.isKind(.read)) return self.emitAddressOf(operand);
        return self.emitReadLend(operand, self.genericReadViewOf(e) != null);
    }

    /// A read lend of `operand` as a view held by address: its address,
    /// or for a generic read view (`generic`), `rig.lend` of it, which
    /// gives each instance the view its type is lent as. A lend written
    /// `?x` and one made where a view is expected are written alike.
    fn emitReadLend(self: *Emitter, operand: Sexp, generic: bool) Error!void {
        const saved_read = self.read_place;
        defer self.read_place = saved_read;
        self.read_place = true;
        if (generic) try self.w.writeAll("rig.lend(");
        try self.emitAddressOf(operand);
        if (generic) try self.w.writeAll(")");
    }

    /// `rig.viewed(T, `: the value a generic read view reaches; the
    /// caller writes the view and the `)`.
    fn writeViewedOpen(self: *Emitter, inner: TypeId) Error!void {
        try self.w.writeAll("rig.viewed(");
        try self.emitTypeTy(inner);
        try self.w.writeAll(", ");
    }

    /// `e` yielded where a value of `ty` goes: a view yielded where a
    /// view or an optional view goes stays a view.
    fn emitValueAs(self: *Emitter, e: Sexp, ty: ?TypeId) Error!void {
        if (ty) |t| if (self.isPtrViewExpr(e) and self.isPtrViewTy(self.unwrapOptionals(t))) return self.emitWriteViewPtr(e);
        // A branch's `none` has the optional type of the value: Zig would
        // otherwise give `null` a type of its own, which a branch beside
        // it, or a reference to the branch's value, does not share. A
        // nested `if` of `none`s alone is that type too.
        if (ty) |t| if (self.facts.types.get(t) == .optional) {
            if (self.isNoneLeaf(e)) {
                try self.writeAsOpen(t);
                return self.w.writeAll("null)");
            }
            if (e.isKind(.@"if") and self.typeOf(e) == self.facts.types.none_id) return self.emitIfYieldAs(e, .value, t);
        };
        // A branch's String is a slice, so a literal in one branch and a
        // slice in another have one Zig type.
        if (ty) |t| if (self.unwrapOptional(t) == self.facts.types.string_id) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(t);
            try self.w.writeAll(", ");
            self.bare = true;
            try self.emitValue(e, true);
            return self.w.writeAll(")");
        };
        try self.emitValue(e, true);
    }

    /// `e` where a value of type `target` goes: a view held by pointer
    /// lifted into an optional of that view is the pointer itself, never
    /// the value it reaches.
    fn emitBareAs(self: *Emitter, e: Sexp, target: ?TypeId) Error!void {
        if (target) |t| if (self.facts.types.get(t) == .optional and self.isPtrViewExpr(e) and self.isPtrViewTy(self.unwrapOptionals(t))) return self.emitWriteViewPtr(e);
        try self.emitBare(e);
    }

    /// The type `ty` holds under every level of optional; any other type
    /// itself.
    fn unwrapOptionals(self: *Emitter, ty: TypeId) TypeId {
        var inner = ty;
        while (self.facts.types.get(inner) == .optional) inner = self.facts.types.get(inner).optional;
        return inner;
    }

    /// The type a fallible `ty` succeeds with; any other type itself.
    fn unwrapFallible(self: *Emitter, ty: TypeId) TypeId {
        return switch (self.facts.types.get(ty)) {
            .fallible => |inner| inner,
            else => ty,
        };
    }

    /// The type an optional `ty` holds; any other type itself.
    fn unwrapOptional(self: *Emitter, ty: TypeId) TypeId {
        return switch (self.facts.types.get(ty)) {
            .optional => |inner| inner,
            else => ty,
        };
    }

    /// `(e).*`: the value a pointer view reaches.
    fn emitDeref(self: *Emitter, e: Sexp) Error!void {
        if (self.genericReadViewOf(e)) |inner| {
            try self.writeViewedOpen(inner);
            try self.emitWriteViewPtr(e);
            return self.w.writeAll(")");
        }
        try self.w.writeAll("(");
        try self.emitWriteViewPtr(e);
        try self.w.writeAll(").*");
    }

    /// The value a pointer view `e` reaches, switched on where it is. A
    /// generic read view a name holds is reached through the name's
    /// address (`rig.viewedPtr`), so a payload captured by pointer is
    /// the one the view reaches, or the name's own copy, never a copy
    /// in a Zig temporary.
    fn emitSwitchDeref(self: *Emitter, e: Sexp) Error!void {
        if (self.switchesThroughName(e)) {
            const inner = self.genericReadViewOf(e).?;
            try self.w.writeAll("rig.viewedPtr(");
            try self.emitTypeTy(inner);
            try self.w.writeAll(", &");
            try self.emitWriteViewPtr(e);
            return self.w.writeAll(").*");
        }
        try self.emitDeref(e);
    }

    /// Whether `e` is a name holding a generic read view (`?T`, `?Self`).
    fn switchesThroughName(self: *Emitter, e: Sexp) bool {
        return e == .src and self.localOf(e) != null and self.genericReadViewOf(e) != null;
    }

    /// A write view: the pointer a `!T` expression denotes.
    fn emitWriteViewPtr(self: *Emitter, e: Sexp) Error!void {
        const saved = self.ptr_tail;
        defer self.ptr_tail = saved;
        self.ptr_tail = true;
        self.bare = true;
        self.want_ptr = true;
        try self.emitValue(e, true);
    }

    /// `@as(T, `: the caller writes the value and the `)`.
    fn writeAsOpen(self: *Emitter, ty: TypeId) Error!void {
        try self.w.writeAll("@as(");
        try self.emitTypeTy(ty);
        try self.w.writeAll(", ");
    }

    /// The pointer a view of `inner` held by address is: a write view's
    /// is mutable, `*T`, and so is a read view's of a value that holds a
    /// Cell by value (`sema.holdsCellByValue`), whose Cell changes through
    /// it; any other read view's is `*const T`. (A type parameter never
    /// holds a Cell: a Cell lives only behind a shared handle.)
    fn emitViewPtrTy(self: *Emitter, inner: TypeId, view: enum { read, write }) Error!void {
        const mutable = view == .write or self.facts.holdsCellByValue(inner);
        try self.w.writeAll(if (mutable) "*" else "*const ");
        try self.emitTypeTy(inner);
    }

    /// `*T` / `*const T` for a view type.
    fn emitPointerTy(self: *Emitter, ty: TypeId) Error!void {
        if (self.genericReadView(ty) != null) return self.emitTypeTy(ty);
        switch (self.facts.types.get(ty)) {
            .read_view, .write_view => |inner| try self.emitViewPtrTy(inner, if (self.facts.types.get(ty) == .read_view) .read else .write),
            else => try self.emitTypeTy(ty),
        }
    }

    /// `<x`: the value leaves its binding.
    fn emitMoved(self: *Emitter, inner: Sexp) Error!void {
        if (inner == .src) if (self.localOf(inner)) |local| {
            if (consumeFlag(local) != null) return self.writeTake(local);
        };
        try self.emitBare(inner);
    }

    fn emitList(self: *Emitter, sexp: Sexp, tail: bool, bare: bool, literal_ty: ?TypeId) Error!void {
        const head = sexp.kind().?;
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        switch (head) {
            // Literal operands of float or type-parameter arithmetic take
            // its type.
            .@"+", .@"-", .@"*", .@"/", .@"%", .neg => if (literal_ty orelse self.literalTypeOf(sexp)) |f| {
                self.literal_ty = f;
            },
            else => {},
        }
        if (self.literal_ty == null) switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"<<", .@">>", .@"&", .@"|", .@"^", .neg, .@"if" => {
                // Sema computed a constant integer expression (and checked
                // that it fits); its value is written as a literal, so Zig
                // does not evaluate it again with other intermediate types.
                if (self.facts.constIntOf(sexp)) |v| if (self.onlyConstantLeaves(sexp)) return self.emitIntConstant(sexp, v);
            },
            else => {},
        };
        switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"<<", .@">>", .neg, .index => self.rt_names = true,
            else => {},
        }
        switch (head) {
            // `?a` / `!a` of an array lent as a slice: the array's address,
            // which Zig takes as a slice.
            .read, .write => if (head == .read) {
                // `?f` of a closure or function lends it.
                if (self.typeOf(sexp)) |t| if (self.facts.callableFn(t) != null) return self.emitFnRef(ir.Read.operand(sexp), self.facts.callableFnTy(t).?);
                // `?x` of a value held by pointer (a Cell) is its address.
                if (self.isPtrViewExpr(sexp)) return self.emitLendAddress(sexp);
                // A view never moves its operand, even in tail position.
                self.bare = bare;
                try self.emitValue(ir.Read.operand(sexp), false);
            } else if (self.isWriteSliceExpr(sexp))
                // `!x` as a value (an argument, a receiver) is the place's
                // address; a `![]T` is the slice.
                try self.emitExpr(ir.Write.operand(sexp))
            else
                try self.emitAddressOf(ir.Write.operand(sexp)),
            .move => {
                const operand = ir.Move.operand(sexp);
                // `<p.f` of an optional takes it, leaving `none`; the
                // place's own parts keep their parentheses.
                if (self.facts.takes(sexp)) {
                    try self.w.writeAll("rig.takeOut(");
                    try self.emitAddressOf(operand);
                    return self.w.writeAll(")");
                }
                self.bare = bare;
                if (tail and self.ptr_tail) try self.emitValue(operand, true) else try self.emitMoved(operand);
            },
            .share => try self.emitShare(sexp),
            .clone => {
                // `+b` of a viewed handle clones the handle it views.
                const operand = ir.Clone.operand(sexp);
                const ty = self.typeOf(operand).?;
                switch (self.facts.cloneable(ty)) {
                    .bump => switch (self.facts.types.get(self.peelViews(ty))) {
                        .optional => {
                            try self.w.writeAll("rig.cloneOptional(");
                            try self.emitBare(operand);
                            try self.w.writeAll(")");
                        },
                        .shared => {
                            try self.emitExpr(operand);
                            try self.w.writeAll(".cloneStrong()");
                        },
                        else => {
                            try self.emitExpr(operand);
                            try self.w.writeAll(".cloneWeak()");
                        },
                    },
                    // `+t` of a Text copies its bytes.
                    .text => {
                        try self.emitExpr(operand);
                        try self.w.writeAll(".clone()");
                    },
                    // Each part cloned as `+` clones it.
                    .deep => {
                        try self.w.writeAll("rig.cloneValue(&(");
                        try self.emitExpr(operand);
                        try self.w.writeAll("))");
                    },
                    // A generic `T` is cloned only where each instance
                    // copies, so it is copied.
                    .copy, .depends => try self.emitExpr(operand),
                    .no => return self.unsupported(sexp, "a clone of a value that moves"),
                }
            },
            .weak => {
                try self.emitExpr(ir.Weak.operand(sexp));
                try self.w.writeAll(".weakRef()");
            },
            .call => if (self.facts.elemCallOf(self.facts.calleeOf(sexp))) |ec|
                try self.emitElemCall(sexp, ec)
            else if (try self.hoistsArgs(sexp))
                try self.emitHoistedCall(sexp)
            else
                try self.emitCallDirect(sexp),
            // Compile-time arguments are emitted by the call or type that
            // takes them; sema rejects a bracket list as a value.
            .inst => return self.unsupported(sexp, "a bracket list of compile-time arguments as a value"),
            .member, .index => {
                if (self.facts.instanceOf(sexp) != null) return self.unsupported(sexp, "a bracket list of compile-time arguments as a value");
                // A field or element holding a write view denotes the
                // viewed value, unless the pointer itself is wanted.
                const deref = self.isPtrViewExpr(sexp) and !(tail and self.ptr_tail);
                const generic = if (deref) self.genericReadViewOf(sexp) else null;
                // On a `match` subject's path, a generic read view is
                // reached where it is held, never copied.
                const in_place = generic != null and self.onSubjectPath(sexp);
                if (generic) |inner| if (in_place) try self.writeViewedPtrOpen(inner) else try self.writeViewedOpen(inner);
                if (head == .member) try self.emitMember(sexp) else try self.emitIndex(sexp, self.place_chain);
                if (in_place) try self.w.writeAll(").*") else if (generic != null) try self.w.writeAll(")") else if (deref) try self.w.writeAll(".*");
            },
            .builtin => try self.emitBuiltin(sexp),
            .propagate => {
                try self.w.writeAll("try ");
                try self.emitExpr(ir.Propagate.value(sexp));
            },
            .propagate_none => {
                const operand = ir.PropagateNone.value(sexp);
                try self.w.writeAll("(");
                try self.emitExpr(operand);
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
                const name = self.srcText(ir.EnumLit.name(sexp));
                if (self.typeOf(sexp)) |t| if (self.isErrorSetTy(t)) return self.writeError(self.peelViews(t), name, sexp);
                try self.w.print(".{f}", .{ident(name)});
            },
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^" => try self.emitInfix(sexp, bare),
            .@"+%", .@"-%", .@"*%" => {
                // In the expression's type, so that literal operands wrap
                // as it does rather than as a Zig `comptime_int`.
                if (!bare) try self.w.writeAll("(");
                try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.int_id);
                try self.emitBare(ir.get(sexp, .left));
                try self.w.print(") {s} ", .{@tagName(head)});
                try self.emitExpr(ir.get(sexp, .right));
                if (!bare) try self.w.writeAll(")");
            },
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
                try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.int_id);
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
                const sym: ?SymbolId = if (name != .nil) self.facts.symbolOf(name) else null;
                if (sym != null and self.usage.used.contains(sym.?)) {
                    const tmp = try self.hiddenStorage(sexp, .error_value, .copy, .next);
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
            .@"while", .@"for", .labeled => if (facts.syntax.hasValueBreaks(self.source, sexp)) try self.emitLoopValue(sexp) else return self.unsupported(sexp, "a loop without a value in value position"),
            .array => try self.emitArray(sexp),
            .array_fill => try self.emitArrayFill(sexp),
            // A jump as a fallback (`?? return`, `catch break`): a block
            // that leaves, which Zig types as `noreturn`.
            .@"return", .@"break", .@"continue" => {
                try self.w.writeAll("{ ");
                try self.emitStmt(sexp);
                try self.w.writeAll(" }");
            },
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// A statement that gives a value (`facts.syntax.yieldsValue`).
    fn yieldsValue(self: *Emitter, s: Sexp) bool {
        return facts.syntax.yieldsValue(self.source, s);
    }

    /// `storage.isNoneLeaf`.
    fn isNoneLeaf(self: *Emitter, e: Sexp) bool {
        return self.facts.isNoneLeaf(e);
    }

    /// `&place`, or the pointer itself when the place is already one. A
    /// value that branches, read where its leaves are, is addressed at
    /// the leaf it takes (`emitLeafPtr`), never through Zig's address of
    /// the branching expression, which may be a constant.
    fn emitAddressOf(self: *Emitter, place: Sexp) Error!void {
        if (self.hoistedOf(place)) |h| return self.w.print("{s}{s}", .{ if (h.ptr) "" else "&", h.name });
        if (try self.reachesLeaf(place)) return self.emitLeafPtr(place, self.typeOf(place).?);
        if (place == .src) if (self.localOf(place)) |local| {
            if (local.is_ptr) return self.w.writeAll(local.zig_name);
        };
        if (self.isPtrViewExpr(place)) return self.emitWriteViewPtr(place);
        try self.w.writeAll("&");
        try self.emitPlace(place);
    }

    /// A binary operator node: `(op left right)`.
    fn emitInfix(self: *Emitter, sexp: Sexp, bare: bool) Error!void {
        const kind = sexp.kind().?;
        const op = @tagName(kind);
        const is_eq = kind == .@"==" or kind == .@"!=";
        const operands = [2]Sexp{ ir.get(sexp, .left), ir.get(sexp, .right) };
        // An optional resource made here and compared with `none` is
        // dropped by the test.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const other = operands[1 - i];
            if (!self.isNoneLeaf(other) or !try self.dropsWhenTested(operands[i])) continue;
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("rig.isNone(");
            try self.emitBare(operands[i]);
            return self.w.writeAll(")");
        };
        // A bare `.variant` beside a payload enum tests the variant only.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const value = operands[1 - i];
            if (!operands[i].isKind(.enum_lit) or !self.isPayloadEnumOperand(value)) continue;
            // A value made here that owns a resource is dropped once
            // tested.
            const temp = try self.dropsWhenTested(value);
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll(if (temp) "rig.isVariantDiscard(" else "rig.isVariant(");
            try self.emitExpr(value);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[i]);
            return self.w.writeAll(")");
        };
        if (is_eq and self.comparesStructurally(operands)) {
            if (kind == .@"!=") try self.w.writeAll("!");
            return self.emitCall2("rig.eql(", operands, ")");
        }
        if (!is_eq) if (self.orderOperator(kind, operands)) |order| {
            // Strings and byte slices order by their bytes.
            if (order.bytes) {
                if (!bare) try self.w.writeAll("(");
                try self.emitCall2("std.mem.order(u8, ", operands, order.test_);
                if (!bare) try self.w.writeAll(")");
                return;
            }
            // A generic `T` orders as its instance does.
            try self.w.writeAll("rig.compare(");
            try self.emitExpr(operands[0]);
            try self.w.print(", .{s}, ", .{order.op});
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
        const arr = self.facts.types.get(self.peelViews(ty));
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

    /// `[n of x]` → `@as([n]T, @splat(x))`.
    fn emitArrayFill(self: *Emitter, sexp: Sexp) Error!void {
        const ty = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped array literal");
        try self.w.writeAll("@as(");
        try self.emitTypeTy(self.peelViews(ty));
        try self.w.writeAll(", @splat(");
        try self.emitBare(ir.ArrayFill.value(sexp));
        try self.w.writeAll("))");
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

        if (index.isKind(.@"..")) return self.emitSlice(sexp, base, base_ty, index);
        // An element of a Cell's Vec is a copy; `c[i] = x` is `emitPlaceAssign`'s.
        if (base_ty != null and self.isCellVecTy(base_ty.?)) {
            try self.emitCellPtr(base);
            try self.w.writeAll(".vecAt(");
            self.place_chain = false;
            try self.emitBare(index);
            return self.w.writeAll(")");
        }
        // A shared handle's element is its value's.
        const held_ty: ?TypeId = if (base_ty) |t| self.facts.unwrapReadAccess(t) else null;
        // An element that is not copied (`readsInPlace`) is reached
        // where it is, as a field is: never a copy of its bits.
        const in_place = as_place or self.elemInPlace(sexp);
        if (held_ty != null and self.isVecTy(held_ty.?)) {
            try self.emitIndexBase(base, base_ty, .expr);
            try self.w.writeAll(if (!in_place) ".at(" else if (self.read_place or !as_place or self.throughReadView(base)) ".constSlot(" else ".slot(");
            // The index itself is a value, even inside an assignment target.
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(if (in_place) ").*" else ")");
            return;
        }
        const array_len: ?TypeId = if (held_ty) |t| switch (self.facts.types.get(t)) {
            .array => |a| a.len,
            else => null,
        } else null;
        const n = array_len orelse {
            // A string or slice: its length is only known when it runs,
            // and `rig.at` and `rig.elemPtr` evaluate it once. Only a `![]T`
            // is assigned through.
            if (in_place) {
                try self.w.writeAll("rig.elemPtr(");
                try self.emitIndexBase(base, base_ty, .bare);
                try self.w.writeAll(", ");
                self.place_chain = false;
                try self.emitBare(index);
                return self.w.writeAll(").*");
            }
            try self.w.writeAll("rig.at(");
            try self.emitIndexBase(base, base_ty, .bare);
            try self.w.writeAll(", ");
            self.place_chain = false;
            try self.emitBare(index);
            return self.w.writeAll(")");
        };
        const may_be_empty = switch (self.facts.types.get(n)) {
            .ct_value => |v| v.int == 0,
            else => true,
        };
        if (may_be_empty) {
            // Zig rejects indexing an empty array, and a length that is a
            // compile-time parameter may be 0: the element is reached
            // through a slice of the array.
            try self.w.writeAll("rig.elems(");
            const saved_read = self.read_place;
            if (!as_place) self.read_place = true;
            try self.emitIndexBase(base, base_ty, .address);
            self.read_place = saved_read;
            try self.w.writeAll(")[rig.index(");
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(", ");
            try self.emitTypeTy(n);
            return self.w.writeAll(")]");
        }
        // An array literal is indexed through parentheses: `([_]T{ ... })[i]`.
        const literal = base.isKind(.array);
        if (literal) try self.w.writeAll("(");
        try self.emitIndexBase(base, base_ty, .expr);
        if (literal) try self.w.writeAll(")");
        try self.w.writeAll("[");
        self.place_chain = false;
        // Sema checked a constant index against a known length.
        if (isNonNegativeIntLiteral(self.source, index)) {
            try self.emitExpr(index);
        } else {
            try self.w.writeAll("rig.index(");
            try self.emitBare(index);
            try self.w.writeAll(", ");
            try self.emitTypeTy(n);
            try self.w.writeAll(")");
        }
        try self.w.writeAll("]");
    }

    /// Whether place `e` is reached through a read view or a shared
    /// handle, whose value is read-only: an element on the way is
    /// reached through `constSlot`.
    fn throughReadView(self: *Emitter, e: Sexp) bool {
        var p = e;
        while (true) {
            if (p.isKind(.read)) return true;
            if (self.typeOf(p)) |t| switch (self.facts.types.get(t)) {
                .read_view, .shared => return true,
                else => {},
            };
            if (!p.isKind(.member) and !p.isKind(.index)) return false;
            p = ir.get(p, .object);
        }
    }

    /// Whether element `e` is read where it is rather than copied: its
    /// type is not copied implicitly (`sema.copies`). (No element holds a
    /// Cell by value: a Cell lives only behind a shared handle.)
    fn elemInPlace(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.facts.pending.copies(t) != .yes;
    }

    /// The object `base` of an index, emitted `how` the index needs it. A
    /// shared handle is read through its value, as a member read reaches
    /// through it (`writeReach`).
    fn emitIndexBase(self: *Emitter, base: Sexp, base_ty: ?TypeId, how: enum { expr, bare, address }) Error!void {
        if (base_ty) |t| if (self.facts.types.get(self.peelViews(t)) == .shared) {
            if (how == .address) try self.w.writeAll("&");
            try self.emitMemberBase(base, t);
            return self.writeReach(t);
        };
        // A generic view of an array (`rig.ReadView([n]T)`, a pointer
        // or a copy as the instance decides) is indexed as it is: indexing
        // a copy of the whole array would lend its element from the copy.
        if (how == .expr and base == .src) if (self.localOf(base)) |local| if (local.is_ptr and local.ty != null and self.genericReadView(local.ty.?) != null) {
            return self.w.writeAll(local.zig_name);
        };
        // A value that branches is indexed where the leaf it takes is.
        if (try self.reachesLeaf(base)) return self.emitMemberBase(base, base_ty);
        switch (how) {
            .expr => try self.emitBaseExpr(base),
            .bare => try self.emitBare(base),
            .address => try self.emitAddressOf(base),
        }
    }

    /// `base` where a postfix follows it: a value that branches, moved
    /// (`<(a if c else b)`), is emitted as Zig's `if`, which a postfix
    /// would not reach whole, so it is parenthesized.
    fn emitBaseExpr(self: *Emitter, base: Sexp) Error!void {
        const parens = movesCompound(base);
        if (parens) try self.w.writeAll("(");
        try self.emitExpr(base);
        if (parens) try self.w.writeAll(")");
    }

    /// `xs[a..b]` → `rig.slice(items, a, b)`, which checks the bounds;
    /// `xs[a..]` → `rig.slice(items, a, null)`. An array is sliced in
    /// place, through its address; a Vec through its items.
    fn emitSlice(self: *Emitter, slice: Sexp, base: Sexp, base_ty: ?TypeId, range: Sexp) Error!void {
        self.place_chain = false;
        const writes = self.isWriteSliceExpr(slice);
        try self.w.writeAll(if (writes) "rig.sliceMut(" else "rig.slice(");
        const ty = self.peelViews(base_ty orelse return self.unsupported(base, "a slice of an untyped value"));
        // A constant is sliced where it is stored, not through a copy.
        const saved_rt = self.rt_names;
        self.rt_names = false;
        if (self.isVecTy(ty)) {
            try self.emitBaseExpr(base);
            try self.w.writeAll(".items()");
        } else if (self.textReach(ty)) |reach| {
            try self.emitBaseExpr(base);
            try self.w.print("{s}.bytes()", .{reach});
        } else if (self.facts.types.get(ty) == .array) {
            // A read slice only reads through: a Vec element on the way
            // is reached through a read-only slot.
            const saved_read = self.read_place;
            self.read_place = !writes;
            try self.emitAddressOf(base);
            self.read_place = saved_read;
        } else try self.emitBare(base);
        self.rt_names = saved_rt;
        // An open start is 0; an open end, `null`, is the length.
        for ([2]Sexp{ ir.@"..".left(range), ir.@"..".right(range) }, [2][]const u8{ "0", "null" }) |bound, open| {
            try self.w.writeAll(", ");
            if (bound == .nil) try self.w.writeAll(open) else try self.emitBare(bound);
        }
        try self.w.writeAll(")");
    }

    /// `(member obj name)`. A shared handle auto-dereferences through
    /// `.value`; `.len` of an array, slice, string, or Vec is an `Int`.
    fn emitMember(self: *Emitter, sexp: Sexp) Error!void {
        const obj = ir.Member.object(sexp);
        const field = self.srcText(ir.Member.name(sexp));
        const obj_ty = self.typeOf(obj);
        // `U8.max`, `F64.min`: a number type's limit.
        if (self.facts.intLimit(sexp)) |limit| return self.emitIntConstant(sexp, limit.v);
        const number_type = if (obj.isKind(.member))
            (if (self.moduleMemberSym(obj)) |m| m.kind == .type_alias else false)
        else
            obj == .src and if (self.facts.symbolOf(obj)) |id| self.facts.symbols.items[id].kind == .type_alias else facts.syntax.isNumericTypeName(self.srcText(obj));
        if (number_type) if (self.typeOf(sexp)) |t| if (self.facts.types.get(t) == .float) {
            try self.writeAsOpen(t);
            try self.w.writeAll(if (std.mem.eql(u8, field, "min")) "-std.math.floatMax(" else "std.math.floatMax(");
            try self.emitTypeTy(t);
            return self.w.writeAll("))");
        };
        // `E.name` of an error set.
        if (self.facts.isErrorMember(sexp)) return self.writeError(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped error"), field, sexp);
        // `Shape.dot` of an enum with payloads names the tag; the value
        // is the union holding it.
        if (obj_ty == null and self.isTypeCallee(obj)) if (self.typeOf(sexp)) |t| if (self.hasPayloadVariants(t)) {
            try self.writeAsOpen(t);
            try self.emitMemberBase(obj, obj_ty);
            return self.w.print(".{f})", .{ident(field)});
        };
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.isCellVecTy(obj_ty.?)) {
            try self.emitCellPtr(obj);
            return self.w.writeAll(".vecLen()");
        }
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.facts.unwrapAccess(obj_ty.?) == self.facts.types.text_id) {
            try self.emitMemberBase(obj, obj_ty);
            try self.writeReach(obj_ty.?);
            return self.w.writeAll(".length()");
        }
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.hasLen(obj_ty.?)) {
            try self.w.writeAll("rig.len(");
            try self.emitMemberBase(obj, obj_ty);
            try self.w.writeAll(".len)");
            return;
        }
        // The length of an array or Vec in a box.
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.facts.boxedType(self.facts.unwrapReadAccess(obj_ty.?)) != null and self.hasLen(self.facts.unwrapAccess(obj_ty.?))) {
            try self.w.writeAll("rig.len(");
            try self.emitMemberBase(obj, obj_ty);
            try self.writeReach(obj_ty.?);
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
        if (obj_ty) |t| if (!self.isBoxMethod(sexp, t, field)) {
            // A consuming method of an owned box's value takes the value
            // out of each box, which is freed.
            if (self.facts.boxedType(t) != null and self.facts.boxedNominal(t) != null and self.facts.methodReceiver(t, field) == .value) {
                var b = t;
                while (self.facts.boxedType(b)) |inner| : (b = inner) try self.w.writeAll(".unbox()");
            } else try self.writeReach(t);
        };
        try self.w.print(".{f}", .{ident(field)});
    }

    /// `.value` for each shared handle and box that member access on a
    /// `ty` reaches through (`sema.unwrapAccess`). A box's `.value` is a
    /// pointer, so a handle it holds is dereferenced before its own.
    fn writeReach(self: *Emitter, ty: TypeId) Error!void {
        var t = ty;
        var ptr = false;
        while (true) switch (self.facts.types.get(t)) {
            .read_view, .write_view => |inner| t = inner,
            .shared => |inner| {
                try self.w.writeAll(if (ptr) ".*.value" else ".value");
                t = inner;
                ptr = false;
            },
            else => {
                t = self.facts.boxedType(t) orelse break;
                try self.w.writeAll(".value");
                ptr = true;
            },
        };
    }

    /// `b.unbox` called: the box's own method, which comes before its
    /// value's methods. A data field of the value named `unbox` is read
    /// through the box.
    fn isBoxMethod(self: *Emitter, member: Sexp, ty: TypeId, name: []const u8) bool {
        if (self.facts.boxedType(self.facts.unwrapReadAccess(ty)) == null or !std.mem.eql(u8, name, "unbox")) return false;
        if (self.facts.lookupDataFieldConst(ty, name) == null) return true;
        const t = self.typeOf(member) orelse return true;
        return self.fnType(t) != null;
    }

    /// `module.name` naming a constant (not a function or a type).
    fn isModuleValue(self: *Emitter, obj: Sexp, member: Sexp) bool {
        if (obj != .src) return false;
        const id = self.facts.symbolOf(obj) orelse return false;
        if (self.facts.symbols.items[id].kind != .module) return false;
        const ty = self.typeOf(member) orelse return false;
        return self.fnType(ty) == null;
    }

    /// The object of a member access. Lend sigils on a receiver are
    /// implicit in Zig's method call syntax; pointers to structs
    /// auto-dereference.
    fn emitMemberBase(self: *Emitter, obj: Sexp, obj_ty: ?TypeId) Error!void {
        const o = lentPlace(obj);
        // The type of the value reached, which a lend of it (`!mk()`, a
        // view of the value it lends) is not.
        const o_ty = if (sameNode(o, obj)) obj_ty else self.typeOf(o);
        if (self.place_chain and o.isKind(.index)) return self.emitIndex(o, true);
        // A lent to write field or element (`!v[i].bump()`) is changed
        // in place, reached through the element's slot, unless it was
        // hoisted to run before the arguments.
        if (obj.isKind(.write) and (o.isKind(.index) or o.isKind(.member)) and self.hoistedOf(o) == null) return self.emitPlace(o);
        // `Pair[Int, String].make(...)`: the instance named.
        if (self.facts.instanceOf(o)) |inst| if (inst == .type) return self.emitTypeTy(inst.type);
        // `Wrap.make(...)` of a generic type: the instance sema inferred.
        if (o == .src) if (self.facts.symbolOf(o)) |id| if (self.facts.symbols.items[id].kind == .generic_type) {
            if (obj_ty) |t| return self.emitTypeTy(t);
        };
        // `m.Wrap.make(...)` of another module's generic type.
        if (o.isKind(.member) and self.isTypeCallee(o)) if (obj_ty) |t| if (self.facts.types.get(t) == .parameterized_nominal) return self.emitTypeTy(t);
        if (o == .src) if (self.localOf(o)) |local| {
            if (local.is_ptr and obj_ty != null and self.isStructLike(obj_ty.?)) return self.w.writeAll(local.zig_name);
            return self.writeLocalPlace(local);
        };
        // A value that branches, read where its leaves are, is reached
        // through the address of the leaf it takes, never a copy.
        // Zig reaches a field through a pointer to a struct, but not
        // through one to a handle (`reachesHandle`).
        if (try self.reachesLeaf(o)) {
            if (self.hoistedOf(o)) |h| try self.w.writeAll(h.name) else try self.emitLeafPtr(o, self.typeOf(o).?);
            if (self.reachesHandle(self.typeOf(o))) try self.w.writeAll(".*");
            return self.derefToHandle(self.typeOf(o));
        }
        // A value that branches is read as its Rig type: Zig would take
        // a field of each branch's own type (a literal's, a String's);
        // a receiver evaluated first is read where it was kept. One its
        // statement's slot keeps (`sema.dropsTemp`), lent to write
        // (`sema.writesTemp`) or not, is reached in the slot (below),
        // which has that type, never in a copy: a change through it is
        // the temporary's own, which its drop sees.
        if (!self.facts.writesTemp(o) and !self.facts.dropsTemp(o)) if (o.isKind(.@"if") or o.isKind(.match) or o.isKind(.@"??") or o.isKind(.@"catch")) if (o_ty) |t| {
            if (self.hoistedOf(o)) |h| if (h.flag.len == 0) return self.w.writeAll(h.name);
            try self.writeAsOpen(t);
            try self.emitExpr(o);
            try self.w.writeAll(")");
            return self.derefToHandle(t);
        };
        const needs_parens = movesCompound(o) or if (o.kind()) |h| switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .neg, .not, .propagate, .call, .array => true,
            else => false,
        } else false;
        if (needs_parens) try self.w.writeAll("(");
        try self.emitExpr(o);
        if (needs_parens) try self.w.writeAll(")");
        // A call yielding a view held by pointer: Zig reaches a field
        // through a pointer to a struct, but not through one to a handle.
        if (o.isKind(.call) and o_ty != null and self.isPtrViewTy(o_ty.?) and !self.isStructLike(o_ty.?)) try self.w.writeAll(".*");
    }

    /// Whether `e` is reached where its leaves are: the recorded decision
    /// (`storage.reachesLeaf`).
    fn reachesLeaf(self: *Emitter, e: Sexp) Error!bool {
        return self.facts.reachesLeaf(e) orelse self.unsupported(e, "a value no checker decided how to reach");
    }

    /// The address of the value `e`, of type `ty`, takes: for a value
    /// that branches, the address of the leaf it takes,
    /// `(if (c) &a else &b)` for `a if c else b`, and for `o ?? d`,
    /// `e catch d`, `o?`, and `e!`, the address of the payload where it
    /// is, `(if (o) |*v| v else &d)`, walked as `storage.leafStep` says. A
    /// place is reached where it is, a value kept in its statement's slot
    /// there, and a jump leaves. Any other value made here is a Zig
    /// temporary of the expression, which may be constant: nothing
    /// changes it (a Cell lives only behind a shared handle).
    fn emitLeafPtr(self: *Emitter, e: Sexp, ty: TypeId) Error!void {
        switch (self.facts.leafStep(e) orelse return self.unsupported(e, "a value reached by address that no checker walked")) {
            .@"if" => {
                try self.w.writeAll("(");
                try self.emitIfYieldAs(e, .leaf_ptr, ty);
                return self.w.writeAll(")");
            },
            .fallback => {
                const holder = if (e.isKind(.@"??")) ir.@"??".left(e) else ir.Catch.value(e);
                const v = try self.hiddenStorage(e, .leaf, .pointer, .next);
                try self.w.writeAll("(if (");
                try self.emitPayloadHolder(holder);
                try self.w.print(") |*{s}| {s} else ", .{ v, v });
                if (e.isKind(.@"??")) {
                    try self.emitLeafPtr(ir.@"??".right(e), ty);
                    return self.w.writeAll(")");
                }
                const name = ir.Catch.name(e);
                const handler = ir.Catch.handler(e);
                const sym: ?SymbolId = if (name != .nil) self.facts.symbolOf(name) else null;
                if (sym != null and self.usage.used.contains(sym.?)) {
                    const tmp = try self.hiddenStorage(e, .error_value, .copy, .next);
                    try self.w.print("|{s}| ", .{tmp});
                    try self.pushScope();
                    const local = try self.declare(.{ .sym = sym.?, .ty = self.symType(sym.?) }, self.srcText(name));
                    try self.emitYieldBlock(handler, .{ .err_capture = .{ .zig_name = local.zig_name, .tmp = tmp } }, ty, .leaf_ptr);
                    try self.popScope();
                } else {
                    try self.w.writeAll("|_| ");
                    try self.emitYieldBlock(handler, .{}, ty, .leaf_ptr);
                }
                return self.w.writeAll(")");
            },
            .unwrap => {
                const operand = if (e.isKind(.propagate)) ir.Propagate.value(e) else ir.PropagateNone.value(e);
                const v = try self.hiddenStorage(e, .leaf, .pointer, .next);
                try self.w.writeAll("(if (");
                try self.emitPayloadHolder(operand);
                try self.w.print(") |*{s}| {s} else {s})", .{ v, v, if (e.isKind(.propagate)) "|err| return err" else "return null" });
                return;
            },
            .jump => return self.emitExpr(e),
            .place, .part, .lend => {
                const saved = self.read_place;
                defer self.read_place = saved;
                self.read_place = true;
                return self.emitAddressOf(e);
            },
            .literal => {
                // An absent optional, whose payload no branch captures,
                // so nothing writes through its address.
                if (self.isNoneLeaf(e)) {
                    try self.w.writeAll("rig.noneAt(");
                    try self.emitTypeTy(ty);
                    return self.w.writeAll(")");
                }
                try self.zigTemporary(e);
                try self.w.writeAll("&");
                try self.writeAsOpen(ty);
                try self.emitBare(e);
                return self.w.writeAll(")");
            },
            .made => {
                // A value kept in its statement's slot is reached there.
                if (self.facts.dropsTemp(e)) {
                    try self.w.writeAll("&(");
                    try self.emitBare(e);
                    return self.w.writeAll(")");
                }
                try self.zigTemporary(e);
                try self.w.writeAll("&");
                try self.writeAsOpen(ty);
                try self.emitBare(e);
                return self.w.writeAll(")");
            },
        }
    }

    /// The optional or fallible value `e`, whose payload a branch takes
    /// by address (`emitLeafPtr`), as an lvalue where it can be: a place
    /// where it is, so the payload captured by pointer is the place's
    /// own; a value that branches at the leaf it takes; a value its
    /// statement's slot keeps there.
    fn emitPayloadHolder(self: *Emitter, e: Sexp) Error!void {
        const ty = self.typeOf(e) orelse return self.unsupported(e, "an untyped optional");
        switch (self.facts.leafStep(e) orelse return self.unsupported(e, "a value reached by address that no checker walked")) {
            .@"if", .fallback, .unwrap, .place, .part, .literal => {
                try self.w.writeAll("(");
                try self.emitLeafPtr(e, ty);
                return self.w.writeAll(").*");
            },
            // The payload is captured by address where Zig holds it.
            .made => if (!self.facts.dropsTemp(e)) {
                try self.zigTemporary(e);
            },
            // A lend of an optional or fallible value whose payload is read
            // by address would hand over a resource or a value of a type
            // parameter from inside a view, which typecheck rejects: a
            // payload captured from a lend has no storage a fact names.
            .lend => return self.unsupported(e, "a payload captured by address from a lend"),
            .jump => {},
        }
        try self.emitBare(e);
    }

    /// `@builtin(args)`. Arguments that name Rig types are spelled as Zig
    /// types. A builtin call as Zig names it. `@fromBackingInt` takes the enum's
    /// backing integer type exactly, so its operand, any integer, goes
    /// through `@intCast` (checked in safe builds, as the tag is).
    fn emitBuiltin(self: *Emitter, sexp: Sexp) Error!void {
        if (std.mem.eql(u8, self.srcText(ir.Builtin.name(sexp)), "name")) return self.emitNameQuery(sexp);
        const name = zigBuiltinName(self.srcText(ir.Builtin.name(sexp)));
        const cast = std.mem.eql(u8, name, "fromBackingInt");
        try self.w.print("@{s}(", .{name});
        if (cast) try self.w.writeAll("@intCast(");
        for (ir.Builtin.args(sexp), 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (self.isTypeArg(sexp, a)) try self.emitTypeTy(self.typeOf(a).?) else try self.emitBare(a);
        }
        if (cast) try self.w.writeAll(")");
        try self.w.writeAll(")");
    }

    /// `@name(T)`: the type's name as sema's printer spells it, the
    /// string itself for a type known here. A type that holds a type
    /// parameter is spelled per instance: the printer's spelling, with
    /// each parameter named by `rig.typeName` from the module's table
    /// (`emitNamesTable`). Zig's `@typeName`, inside `raw`, is Zig's.
    fn emitNameQuery(self: *Emitter, sexp: Sexp) Error!void {
        const arg = ir.Builtin.args(sexp)[0];
        const of = if (arg.isKind(.builtin)) ir.Builtin.args(arg)[0] else arg;
        const ty = self.typeOf(of) orelse return self.unsupported(arg, "an untyped `@name` argument");
        const spelling = try self.facts.formatTypeMarked(self.arena.allocator(), ty);
        if (std.mem.findScalar(u8, spelling, facts.type_param_mark) == null) return self.w.print("\"{s}\"", .{spelling});
        self.uses_names = true;
        try self.w.writeAll("(comptime ");
        try self.writeSpelling(spelling, .concat, null);
        try self.w.writeAll(")");
    }

    /// A marked spelling (`sema.formatTypeMarked`) as Zig: its strings,
    /// and each type parameter as `how` writes it. `.concat` joins them
    /// with `++`, each parameter named by `rig.typeName`; `.parts` lists
    /// them in a tuple, each parameter as itself, or, given the generic
    /// type `of`, as its index among that type's parameters.
    fn writeSpelling(self: *Emitter, spelling: []const u8, how: enum { concat, parts }, of: ?SymbolId) Error!void {
        if (how == .parts) try self.w.writeAll(".{ ");
        var it = std.mem.splitScalar(u8, spelling, facts.type_param_mark);
        var i: usize = 0;
        var first = true;
        while (it.next()) |piece| : (i += 1) {
            const is_param = i % 2 == 1;
            if (!is_param and piece.len == 0) continue;
            if (!first) try self.w.writeAll(if (how == .concat) " ++ " else ", ");
            first = false;
            if (!is_param) {
                try self.w.print("\"{s}\"", .{piece});
                continue;
            }
            const sym = std.fmt.parseInt(SymbolId, piece, 10) catch unreachable;
            if (of) |generic| {
                const params = self.facts.symbols.items[generic].type_params.?;
                try self.w.print("{d}", .{std.mem.findScalar(SymbolId, params, sym).?});
            } else if (how == .concat) {
                try self.w.writeAll("rig.typeName(");
                try self.writeTypeParam(sym);
                try self.w.writeAll(", __rig_names)");
            } else try self.writeTypeParam(sym);
        }
        if (how == .parts) try self.w.writeAll(" }");
    }

    /// `const __rig_names = .{ ... };`: what `rig.typeName` needs to name
    /// a type parameter's instance as this module writes it, every name
    /// from sema's printer: this module (`nameModule`), what each module
    /// it imports qualifies its types with, each built-in type, and the
    /// spelling of each of the runtime's generic types.
    fn emitNamesTable(self: *Emitter) Error!void {
        const ctx = self.facts;
        const a = self.arena.allocator();
        try self.w.print("\nconst __rig_names = .{{\n    .module = \"{s}\",\n    .imports = .{{\n", .{nameModule(ctx)});
        for (0..ctx.importCount()) |i| {
            const imp = ctx.importAt(i);
            // The first import of a module names it, as in the printer.
            const seen = for (0..i) |j| {
                if (ctx.importAt(j).module_id == imp.module_id) break true;
            } else false;
            if (!seen) try self.w.print("        .{{ \"{s}\", \"{s}.\" }},\n", .{ imp.facts.name, imp.local_name });
        }
        try self.w.writeAll("    },\n    .types = .{\n");
        for (try ctx.builtinTypes(a)) |t| {
            try self.w.writeAll("        .{ ");
            try self.emitBuiltinTy(t);
            try self.w.print(", \"{s}\" }},\n", .{try ctx.formatTypeValue(a, t)});
        }
        try self.w.writeAll("        .{ ");
        try self.writeNominalName(ctx.endian_sym_id);
        try self.w.print(", \"{s}\" }},\n    }},\n    .generics = .{{\n", .{try ctx.formatTypeValue(a, .{ .nominal = ctx.endian_sym_id })});
        for (0..ctx.symbols.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            if (!ctx.isBuiltinGeneric(sym)) continue;
            try self.w.writeAll("        .{ ");
            try self.writeNominalName(sym);
            try self.w.writeAll(", ");
            try self.writeSpelling(try ctx.formatGenericSelfMarked(a, sym), .parts, sym);
            try self.w.writeAll(" },\n");
        }
        try self.w.writeAll("    },\n};\n");
    }

    /// The Zig name of builtin `name`: Rig's type queries are Zig's
    /// under their own names (`@size` is `@sizeOf`); every other builtin
    /// is Zig's, as written.
    fn zigBuiltinName(name: []const u8) []const u8 {
        const rig_names = std.StaticStringMap([]const u8).initComptime(.{
            .{ "size", "sizeOf" }, .{ "align", "alignOf" }, .{ "name", "typeName" }, .{ "type", "TypeOf" },
        });
        return rig_names.get(name) orelse name;
    }

    /// Every argument of `@sizeOf`, `@alignOf`, and `@typeName` is a
    /// type, except `@TypeOf(x)`.
    fn isTypeArg(self: *Emitter, builtin: Sexp, a: Sexp) bool {
        if (a.isKind(.builtin)) return false;
        const name = zigBuiltinName(self.srcText(ir.Builtin.name(builtin)));
        return std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf") or std.mem.eql(u8, name, "typeName");
    }

    /// `*expr`: move `expr` into a new reference-counted box.
    fn emitShare(self: *Emitter, sexp: Sexp) Error!void {
        const inner = ir.Share.operand(sexp);
        if (inner.isKind(.lambda)) return self.emitOwnedClosure(inner);
        const payload_ty: ?TypeId = if (self.typeOf(sexp)) |t| switch (self.facts.types.get(t)) {
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
        return self.emitIfYieldAs(sexp, .value, self.typeOf(sexp));
    }

    /// `(if cond then else)` yielding `how` each branch's value, of type
    /// `result`: the `if`'s own, or for a leaf reached by address, the
    /// type of the value it is a leaf of (a branch of `none`s alone has
    /// no optional type of its own).
    fn emitIfYieldAs(self: *Emitter, sexp: Sexp, how: Yield, result: ?TypeId) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        if (else_ == .nil) return self.unsupported(sexp, "an `if` without `else` in value position");
        if (rig.isConditionJoin(cond)) {
            // A labeled block: the nested `if`s of the parts break out
            // with the then-value; falling through, the `else` value.
            const parts = try self.conditionParts(cond);
            const label = try self.fmt("__rig_if_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
            try self.openBrace();
            try self.writeIndent(self.indent);
            try self.pushScope();
            try self.openParts(parts);
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{label});
            try self.emitYieldBlock(ir.If.then(sexp), .{}, result, how);
            try self.w.writeAll(";\n");
            try self.closeParts(parts.len, null);
            try self.popScope();
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{label});
            try self.emitYieldBlock(else_, .{}, result, how);
            try self.w.writeAll(";\n");
            return self.closeBrace();
        }
        try self.w.writeAll("if ");
        try self.pushScope();
        const prelude = try self.emitCond(cond);
        try self.emitYieldBlock(ir.If.then(sexp), prelude, result, how);
        try self.popScope();
        try self.w.writeAll(" else ");
        try self.emitYieldBlock(else_, .{}, result, how);
    }

    /// A block that yields its last expression: inline when it is a
    /// single expression, otherwise a labeled block. The value leaves the
    /// block, so a resource binding in tail position is moved out. A block
    /// ending in `return`/`break`/`continue` yields nothing and needs no
    /// label. `result` is the type the block yields.
    fn emitValueBlock(self: *Emitter, body: Sexp, prelude: Prelude, result: ?TypeId) Error!void {
        return self.emitYieldBlock(body, prelude, result, .value);
    }

    /// A block that yields its last expression `how`: the value, or the
    /// address of the leaf it is (`emitLeafPtr`).
    fn emitYieldBlock(self: *Emitter, body: Sexp, prelude: Prelude, result: ?TypeId, how: Yield) Error!void {
        const stmts = try self.stmtsOf(body);
        if (stmts.len == 0) return self.unsupported(body, "an empty block in value position");
        const last = stmts[stmts.len - 1];
        if (stmts.len == 1 and prelude.isEmpty() and self.yieldsValue(last) and !self.hasTemps(last)) return self.emitYield(last, result, how);

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
            const first = self.temp_slots.items.len;
            defer self.temp_slots.shrinkRetainingCapacity(first);
            try self.emitTempSlots(last);
            try self.w.print("break :{s} ", .{label});
            self.bare = true;
            try self.emitYield(last, result, how);
            try self.w.writeAll(";");
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// `e`, a branch's value, yielded `how`.
    fn emitYield(self: *Emitter, e: Sexp, result: ?TypeId, how: Yield) Error!void {
        switch (how) {
            .value => return self.emitValueAs(e, result),
            .leaf_ptr => {
                self.bare = false;
                return self.emitLeafPtr(e, result orelse return self.unsupported(e, "an untyped branch"));
            },
        }
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// `replace` or `swap` when `call` calls the built-in.
    fn builtinCall(self: *Emitter, call: Sexp) ?[]const u8 {
        const callee = self.facts.calleeOf(call);
        if (callee != .src or self.facts.symbolOf(callee) != null) return null;
        const name = self.srcText(callee);
        return if (std.mem.eql(u8, name, "replace") or std.mem.eql(u8, name, "swap")) name else null;
    }

    /// `rig.replace(&place, value)` / `rig.swapPlaces(&a, &b)`: each place by
    /// its address, a held write view as the pointer it is.
    fn emitSwapCall(self: *Emitter, name: []const u8, args: []const Sexp) Error!void {
        try self.w.writeAll(if (std.mem.eql(u8, name, "swap")) "rig.swapPlaces(" else "rig.replace(");
        for (args, 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (i == 0 or std.mem.eql(u8, name, "swap")) {
                try self.emitAddressOf(lentPlace(a));
            } else try self.emitStored(a);
        }
        try self.w.writeAll(")");
    }

    /// How a value of type `ty` (viewed or not) reaches the Text it
    /// views: directly, or through a `Box[Text]`; null for anything else.
    fn textReach(self: *Emitter, ty: TypeId) ?[]const u8 {
        var t = self.peelViews(ty);
        var reach: []const u8 = "";
        while (t != self.facts.types.text_id) {
            const boxed = self.facts.types.get(t) != .shared;
            t = switch (self.facts.types.get(t)) {
                .shared => |inner| self.peelViews(inner),
                else => self.peelViews(self.facts.boxedType(t) orelse return null),
            };
            // A box's value is behind a pointer; a handle it holds is one
            // more, which Zig does not follow by itself.
            const deref = boxed and self.facts.types.get(t) == .shared;
            reach = self.fmt("{s}.value{s}", .{ reach, if (deref) ".*" else "" }) catch return null;
        }
        return reach;
    }

    /// `storage.textCall`.
    fn textCall(self: *Emitter, call: Sexp) ?facts.TextCall {
        return self.facts.textCall(call);
    }

    /// `Text(a, b)` → `rig.Text.of(.{ a, &b })`; `!t.add(a, b)` →
    /// `t.add(.{ a, &b })`, the arguments written as `print`'s are
    /// (`emitPrintArgs`), so a place is read at the call; `!t.clear()` →
    /// `t.clear()`.
    fn emitTextCall(self: *Emitter, call: Sexp, op: facts.TextCall) Error!void {
        const args = ir.Call.args(call);
        switch (op) {
            .new => try self.w.writeAll("rig.Text.of("),
            .add, .push, .clear => {
                const recv = ir.Member.object(self.facts.calleeOf(call));
                try self.emitMemberBase(recv, self.typeOf(recv));
                if (self.typeOf(recv)) |t| try self.writeReach(t);
                if (op == .clear) return self.w.writeAll(".clear()");
                if (op == .push) {
                    try self.w.writeAll(".push(");
                    try self.emitBare(args[0]);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll(".add(");
            },
        }
        try self.emitPrintArgs(args);
        try self.w.writeAll(")");
    }

    /// `storage.isPrintCall`.
    fn isPrintCall(self: *Emitter, call: Sexp) bool {
        return self.facts.isPrintCall(call);
    }

    /// A built-in element method: `!dst.copy(src)` is `rig.copy(dst,
    /// src)`, `fill` and `swap` likewise, and `read` and `write` are
    /// `rig.readInt` and `rig.writeInt`, on the receiver's elements
    /// (`emitElems`). The arguments are plain data, so none is hoisted.
    fn emitElemCall(self: *Emitter, call: Sexp, ec: facts.ElemCall) Error!void {
        const callee = self.facts.calleeOf(call);
        const args = ir.Call.args(call);
        switch (ec.op) {
            // `rig.readInt(T, bytes, at, endian)`,
            // `rig.writeInt(T, bytes, at, value, endian)`.
            .read, .write => {
                try self.w.writeAll(if (ec.op == .read) "rig.readInt(" else "rig.writeInt(");
                try self.emitTypeTy(ec.num);
                try self.w.writeAll(", ");
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
                try self.w.writeAll(", ");
                try self.emitBare(self.facts.ctArgsOf(call)[1]);
            },
            .copy, .fill, .swap => {
                try self.w.print("rig.{s}(", .{@tagName(ec.op)});
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    if (self.facts.lendsTempArray(a)) {
                        try self.zigTemporary(a);
                        try self.w.writeAll("&");
                    }
                    try self.emitBare(a);
                }
            },
        }
        try self.w.writeAll(")");
    }

    /// The elements of a method's receiver (a slice, an array, a Vec, or
    /// a String, viewed or not) as a Zig slice or array pointer: a
    /// slice or String as it is, an array through its address (writable
    /// when the receiver is written `!xs`), a Vec through its items.
    fn emitElems(self: *Emitter, recv: Sexp) Error!void {
        const writes = recv.isKind(.write);
        const place = if (recv.isKind(.write) or recv.isKind(.read)) ir.get(recv, .operand) else recv;
        const ty = self.peelViews(self.typeOf(place) orelse return self.unsupported(recv, "an untyped receiver"));
        if (self.isVecTy(ty)) {
            try self.emitExpr(place);
            return self.w.writeAll(".items()");
        }
        if (self.facts.types.get(ty) == .array) {
            const saved_read = self.read_place;
            defer self.read_place = saved_read;
            self.read_place = !writes;
            return self.emitAddressOf(place);
        }
        try self.emitBare(place);
    }

    fn emitCallDirect(self: *Emitter, sexp: Sexp) Error!void {
        const callee = self.facts.calleeOf(sexp);
        const args = ir.Call.args(sexp);

        if (self.isPrintCall(sexp)) return self.emitPrint(args);
        if (self.textCall(sexp)) |op| return self.emitTextCall(sexp, op);
        if (self.builtinCall(sexp)) |name| return self.emitSwapCall(name, args);
        if (callee == .src and self.facts.symbolOf(callee) == null and facts.syntax.isNumericTypeName(self.srcText(callee))) return self.emitConversion(sexp);
        // A call through an alias: a conversion to the number type it
        // names, or a value of the struct it names.
        if (self.isAliasCallee(callee)) {
            const t = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped call through an alias");
            if (self.facts.isNumeric(t)) return self.emitConversion(sexp);
            if (self.facts.types.get(t) == .parameterized_nominal) {
                const g = self.facts.types.get(t).parameterized_nominal.sym;
                if (g == self.facts.vec_sym_id) return self.emitVecConstruction(sexp);
                if (g == self.facts.box_sym_id) return self.emitBoxConstruction(sexp);
                if (g == self.facts.signal_sym_id) {
                    try self.emitTypeTy(t);
                    return self.emitSignalConstruction(sexp);
                }
            }
            try self.emitTypeTy(t);
            return self.emitFieldInit(args, self.declFields(t));
        }
        if (callee.isKind(.enum_lit)) return self.emitVariantLit(sexp);
        if (callee.isKind(.lambda)) return self.emitInlineInvoke(sexp);

        if (callee == .src) {
            if (self.localOf(callee)) |local| if (local.stack_closure) {
                try self.w.print("{s}.__rig_invoke(", .{local.zig_name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            };
            if (self.facts.symbolOf(callee)) |sym_id| {
                if (sym_id == self.facts.vec_sym_id) return self.emitVecConstruction(sexp);
                if (sym_id == self.facts.signal_sym_id) return self.emitSignalConstruction(sexp);
                if (sym_id == self.facts.box_sym_id) return self.emitBoxConstruction(sexp);
                if (self.isTypeSym(sym_id)) return self.emitConstructor(sexp, sym_id);
            }
        }
        // A member callee without a type of its own names a variant
        // through its enum (`Shape.circle(r: 2)`, `m.Shape.circle(r: 2)`)
        // or a type in another module (`m.Type(field: v)`).
        if (callee.isKind(.member) and self.facts.typeOf(callee) == null) if (self.typeOf(sexp)) |t| {
            const vname = self.srcText(ir.Member.name(callee));
            if (self.variantPayload(t, vname) != null) {
                try self.writeAsOpen(t);
                try self.emitVariantPayload(sexp, t, vname);
                return self.w.writeAll(")");
            }
            if (self.facts.types.get(t) == .imported_nominal) {
                try self.emitMember(callee);
                return self.emitFieldInit(args, self.declFields(t));
            }
            // `m.Wrap[Int](v: 3)`, `m.Wrap(v: 3)`: the instance sema gave it.
            if (self.facts.types.get(t) == .parameterized_nominal and self.isTypeCallee(callee)) {
                try self.emitTypeTy(t);
                return self.emitFieldInit(args, self.declFields(t));
            }
        };
        // A callable view calls through its `rig.FnRef`.
        if (self.typeOf(callee)) |t| if (self.facts.callableFn(t) != null) {
            try self.emitExpr(callee);
            try self.w.writeAll(".call(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };
        // An owned closure handle, held by a name or a field, or a call
        // yielding a view of one, held by pointer.
        if (self.typeOf(callee)) |t| if (self.facts.ownedClosureFn(t) != null) {
            try self.emitExpr(callee);
            if (callee.isKind(.call) and self.isPtrViewTy(t)) try self.w.writeAll(".*");
            try self.w.writeAll(".value.invoke(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };

        // A Cell holding a Vec answers the Vec's members.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isCellVecTy(t)) {
            const m = self.srcText(ir.Member.name(callee));
            const method: ?[]const u8 = if (std.mem.eql(u8, m, "push"))
                "vecPush"
            else if (std.mem.eql(u8, m, "pop"))
                "vecPop"
            else if (std.mem.eql(u8, m, "clear"))
                "vecClear"
            else if (std.mem.eql(u8, m, "get") and ir.Call.args(sexp).len == 1) "vecGet" else null;
            if (method) |name| {
                try self.emitCellPtr(ir.Member.object(callee));
                try self.w.print(".{s}(", .{name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        // `get` on an array, a slice, or a String.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isSequence(t) and std.mem.eql(u8, self.srcText(ir.Member.name(callee)), "get")) {
            try self.w.writeAll("rig.elementAt(");
            try self.emitBare(ir.Member.object(callee));
            try self.w.writeAll(", ");
            try self.emitArgs(sexp);
            return self.w.writeAll(")");
        };
        // `set` / `replace` change a Cell through any path to it: the
        // Cell's address, a mutable pointer (`emitCellAddress`).
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isBuiltinInstance(t, self.facts.cell_sym_id)) {
            const m = self.srcText(ir.Member.name(callee));
            if (std.mem.eql(u8, m, "set") or std.mem.eql(u8, m, "replace")) {
                try self.emitCellAddress(ir.Member.object(callee));
                try self.w.print(".{s}(", .{m});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        try self.emitExpr(callee);
        try self.w.writeAll("(");
        try self.emitArgs(sexp);
        try self.w.writeAll(")");
    }

    /// An array, a slice, or a String, or a view of one.
    fn isSequence(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .array, .slice, .string => true,
            else => false,
        };
    }

    /// A mutable pointer to the Cell `obj` denotes: a shared handle's
    /// value, or the Cell's address.
    fn emitCellPtr(self: *Emitter, obj: Sexp) Error!void {
        const ty = self.typeOf(obj) orelse return self.unsupported(obj, "this Cell");
        if (self.facts.types.get(self.peelViews(ty)) == .shared) {
            try self.w.writeAll("(&");
            try self.emitMemberBase(obj, ty);
            return self.w.writeAll(".value)");
        }
        try self.emitCellAddress(obj);
    }

    /// The address of the Cell `obj` denotes, a mutable pointer: a Cell
    /// lives only behind a shared handle, whose value is on the heap, and
    /// every read view of a value holding one is a mutable pointer
    /// (`emitViewPtrTy`).
    fn emitCellAddress(self: *Emitter, obj: Sexp) Error!void {
        const saved = self.read_place;
        defer self.read_place = saved;
        self.read_place = true;
        try self.w.writeAll("(");
        try self.emitAddressOf(lentPlace(obj));
        try self.w.writeAll(")");
    }

    /// `I32(x)` → `@as(i32, @intCast(@as(i64, x)))`, with the builtin
    /// chosen by the kinds of the two types. Zig checks that the value
    /// fits in safe builds; `@trunc` truncates toward zero, and
    /// `rig.notNan` panics on a NaN.
    fn emitConversion(self: *Emitter, call: Sexp) Error!void {
        const target = self.typeOf(call) orelse return self.unsupported(call, "an untyped conversion");
        const arg = argValue(ir.Call.args(call)[0]);
        const arg_ty = self.typeOf(arg) orelse return self.unsupported(call, "this conversion");
        // A plain enum's value, converted when the program runs, where
        // Zig checks that it fits (the checker did for a constant one).
        if (self.isEnumTy(self.peelViews(arg_ty))) {
            try self.writeAsOpen(target);
            try self.w.writeAll("@intCast(@backingInt(rig.rt(");
            try self.emitBare(arg);
            return self.w.writeAll("))))");
        }
        const from = switch (self.facts.types.get(self.peelViews(arg_ty))) {
            .int, .float => self.peelViews(arg_ty),
            .int_literal => self.facts.types.int_id,
            .float_literal => self.facts.types.float_id,
            else => return self.unsupported(call, "this conversion"),
        };
        const to_int = self.facts.types.get(target) == .int;
        // Constant arithmetic on literals converted to an integer type is
        // a value of it, which the checker made sure fits (it may not fit
        // `Int`).
        if (to_int and self.literalLeaves(arg)) if (self.facts.constIntOf(arg)) |v| {
            try self.writeAsOpen(target);
            return self.w.print("{d})", .{v});
        };
        const from_int = self.facts.types.get(from) == .int;
        const builtin = if (to_int) (if (from_int) "@intCast" else "@trunc") else (if (from_int) "@floatFromInt" else "@floatCast");
        const nan_check = to_int and !from_int;
        try self.writeAsOpen(target);
        try self.w.print("{s}({s}", .{ builtin, if (nan_check) "rig.notNan(" else "" });
        try self.writeAsOpen(from);
        // A constant is converted at run time, where Zig checks it as Rig
        // does, not at compile time.
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        self.rt_names = true;
        try self.emitBare(arg);
        try self.w.writeAll(if (nan_check) "))))" else ")))");
    }

    /// `(|n| print n)()`: the closure is built and called in a block.
    fn emitInlineInvoke(self: *Emitter, call: Sexp) Error!void {
        const id = self.nextId();
        const name = try self.hiddenStorage(ir.Call.callee(call), .invoked, .owned, .{ .id = id });
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
        try self.w.print("break :__rig_inline_{d} {s}.__rig_invoke(", .{ id, name });
        try self.emitArgs(call);
        try self.w.writeAll(");\n");
        try self.closeBrace();
    }

    /// A call's arguments in parameter order: its compile-time arguments
    /// (after a receiver passed as an argument), then its run-time ones,
    /// keyword arguments in their parameters' places and defaults for
    /// omitted ones.
    fn emitArgs(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        const params = self.callParams(call);
        const generic = self.facts.genericCallOf(call);
        const ct_at: usize = if (generic) |g| @intFromBool(g.receiver_arg) else 0;
        const slots = self.facts.callSlotsOf(call);
        const n = if (slots) |sl| sl.len else args.len;
        var written: usize = 0;
        for (0..n + 1) |i| {
            if (i == @min(ct_at, n)) {
                const ct = self.facts.ctArgsOf(call);
                if (written > 0 and ctArgCount(generic, ct) > 0) try self.w.writeAll(", ");
                written += try self.emitCtArgs(generic, ct);
            }
            if (i == n) break;
            if (written > 0) try self.w.writeAll(", ");
            written += 1;
            if (slots) |sl| switch (sl[i]) {
                .arg => |ai| try self.emitArg(args[ai], params, i),
                .default => |d| try self.emitDefault(self.semaOf(d.source) orelse return self.unsupported(call, "this default argument"), d.expr),
            } else try self.emitArg(args[i], params, i);
        }
    }

    /// A field or parameter default, `e`, declared in module `decl`: a
    /// literal, a constant, or (a field's, emitted in its own module's
    /// type) a constructor. A constant of another module than the one
    /// being emitted is reached through its file, which every module of
    /// the package can import.
    fn emitDefault(self: *Emitter, decl: Facts, e: Sexp) Error!void {
        // A member of an error set: `.name` or `E.name`.
        if (e.isKind(.enum_lit) or decl.isErrorMember(e)) if (decl.typeOf(e)) |t| if (decl.nominalDecl(t)) |set| if (set.symbol().flags.error_set) {
            const name = if (e.isKind(.member)) ir.Member.name(e) else ir.EnumLit.name(e);
            try self.w.writeAll("error.");
            return writeErrorName(self.w, set.facts, set.symbol().name, decl.source[name.src.pos..][0..name.src.len]);
        };
        if (isDefaultLiteralNode(decl.source, e)) return writeLiteral(self.w, decl.source, e);
        if (decl.same(self.facts)) {
            const saved = self.keep_comptime;
            defer self.keep_comptime = saved;
            self.keep_comptime = true;
            return self.emitBare(e);
        }
        if (e.isKind(.member)) {
            const obj = ir.Member.object(e);
            const name = decl.source[ir.Member.name(e).src.pos..][0..ir.Member.name(e).src.len];
            if (decl.intLimit(e)) |limit| return self.w.print("{d}", .{limit.v});
            const module = if (decl.symbolOf(obj)) |id| decl.symbols.items[id].kind == .module else false;
            if (!module) if (decl.typeOf(e)) |t| if (decl.types.get(t) == .float) {
                // A float type's limit, named through the type or an
                // alias of it, this module's or an imported one.
                const bits = decl.types.get(t).float.bits;
                return self.w.print("{s}std.math.floatMax(f{d})", .{ if (std.mem.eql(u8, name, "min")) "-" else "", if (bits == 0) 64 else bits });
            };
            if (obj != .src) return self.unsupported(e, "this default value");
            const local = decl.source[obj.src.pos..][0..obj.src.len];
            for (0..decl.importCount()) |i| {
                const imp = decl.importAt(i);
                if (std.mem.eql(u8, imp.local_name, local)) return self.w.print("@import(\"{s}\").{f}", .{ imp.facts.zig_file, ident(name) });
            }
            return self.unsupported(e, "a default from an unresolved module");
        }
        return self.w.print("@import(\"{s}\").{f}", .{ decl.zig_file, ident(decl.source[e.src.pos..][0..e.src.len]) });
    }

    /// The checked module whose source is `source`: this one, or one it
    /// reaches.
    fn semaOf(self: *Emitter, source: []const u8) ?Facts {
        return self.facts.moduleWithSource(source);
    }

    /// The argument filling parameter slot `i`: a `!T` parameter receives
    /// a pointer.
    fn emitArg(self: *Emitter, arg: Sexp, params: []const TypeId, i: usize) Error!void {
        const value = argValue(arg);
        // A temporary array lent as a slice: its address, which lives
        // through the call.
        if (self.facts.lendsTempArray(value)) {
            // Where Zig holds it, unless the call evaluated it first.
            if (self.hoistedOf(value) == null) try self.zigTemporary(value);
            try self.w.writeAll("&");
            return self.emitBare(value);
        }
        if (i < params.len and self.isPtrViewTy(params[i])) return self.emitWriteViewPtr(value);
        try self.emitBareAs(value, if (i < params.len) params[i] else null);
    }

    /// The number of compile-time arguments a call passes: those `given`
    /// in its bracket list, or one per compile-time parameter of a
    /// generic function, whose types may be inferred.
    fn ctArgCount(generic: ?facts.GenericCall, given: []const Sexp) usize {
        return if (generic) |g| g.type_args.len else given.len;
    }

    /// A call's compile-time arguments, `given` in its bracket list: for a
    /// generic function, a type argument (inferred or given) where it
    /// takes one. Returns how many were written.
    fn emitCtArgs(self: *Emitter, generic: ?facts.GenericCall, given: []const Sexp) Error!usize {
        const n = ctArgCount(generic, given);
        for (0..n) |j| {
            if (j > 0) try self.w.writeAll(", ");
            const ty = if (generic) |g| g.type_args[j] else facts.type_invalid;
            if (ty != facts.type_invalid) try self.emitTypeTy(ty) else try self.emitComptime(given[j]);
        }
        return n;
    }

    /// A compile-time argument: a value Zig knows at compile time.
    fn emitComptime(self: *Emitter, arg: Sexp) Error!void {
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        self.keep_comptime = true;
        try self.emitBare(arg);
    }

    /// `storage.argParams`.
    fn callParams(self: *Emitter, call: Sexp) []const TypeId {
        return self.facts.argParams(call);
    }

    /// `storage.isTypeCallee`.
    fn isTypeCallee(self: *Emitter, obj: Sexp) bool {
        return self.facts.isTypeCallee(obj);
    }

    /// `storage.moduleMemberSym`.
    fn moduleMemberSym(self: *Emitter, obj: Sexp) ?facts.Symbol {
        return self.facts.moduleMemberSym(obj);
    }

    /// A struct, enum, or generic type: calling it constructs a value.
    /// A callee naming a type alias, this module's or an imported one.
    fn isAliasCallee(self: *Emitter, callee: Sexp) bool {
        if (callee.isKind(.member)) return if (self.moduleMemberSym(callee)) |m| m.kind == .type_alias else false;
        if (callee != .src) return false;
        const id = self.facts.symbolOf(callee) orelse return false;
        return self.facts.symbols.items[id].kind == .type_alias;
    }

    /// `storage.isTypeSym`.
    fn isTypeSym(self: *Emitter, id: SymbolId) bool {
        return self.facts.isTypeSym(id);
    }
    /// `storage.hoistsArgs`.
    fn hoistsArgs(self: *Emitter, call: Sexp) Error!bool {
        return self.need(self.facts.hoistsArgs(call), call);
    }

    /// `storage.lentLiteral`.
    fn lentLiteral(self: *Emitter, e: Sexp) bool {
        return self.facts.lentLiteral(e);
    }

    /// `storage.consumedTemporary`.
    fn consumedTemporary(self: *Emitter, call: Sexp) Error!?Sexp {
        return if (try self.need(self.facts.consumesReceiver(call), call)) self.facts.receiverOf(call) else null;
    }

    /// `storage.isPureArg`.
    fn isPureArg(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.isPureArg(e), e);
    }

    /// `storage.receiverOf`.
    fn receiverOf(self: *Emitter, call: Sexp) ?Sexp {
        return self.facts.receiverOf(call);
    }

    /// Whether an operand tested against `none` or a bare `.variant` is
    /// a value made there that no slot holds, which the test drops. Any
    /// other operand is read where it is.
    fn dropsWhenTested(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.dropsWhenTested(e), e);
    }

    /// `storage.hasStorage`.
    fn hasStorage(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.hasStorage(e), e);
    }

    /// `storage.receiverWrites`.
    fn receiverWrites(self: *Emitter, call: Sexp) bool {
        return self.facts.receiverWrites(call);
    }

    /// Evaluate the receiver of a method call whose arguments are hoisted
    /// into `__rig_recv_N` first, so it runs before them, as written: the
    /// address of a place, or a temporary value, dropped after the call.
    fn hoistReceiver(self: *Emitter, call: Sexp, id: u32) Error!void {
        const hold = (try self.need(self.facts.receiverHold(call), call)) orelse return;
        // Lend sigils on a receiver are implicit in Zig's method calls.
        const recv = lentPlace(self.receiverOf(call).?);
        const writes = self.receiverWrites(call);
        // Held as written below: an address, or a value made here.
        const by: facts.StorageBy = switch (hold) {
            .leaf, .slot, .place => .pointer,
            .consumed, .value => .owned,
        };
        const name = try self.hiddenStorage(recv, .receiver, by, .{ .id = id });
        try self.writeIndent(self.indent);
        // A value that branches is held as the address of the leaf it
        // takes, and a value kept in its statement's slot, or a part of
        // one, as its address there: never a copy, which the call's block
        // would end while the result may still view it.
        if (hold == .leaf or hold == .slot) {
            try self.w.print("const {s} = ", .{name});
            if (hold == .leaf) try self.emitLeafPtr(recv, self.typeOf(recv).?) else try self.emitSlotAddress(recv);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = recv, .name = name, .ptr = self.reachesHandle(self.typeOf(recv)) });
        }
        if (hold == .place) {
            const saved = self.read_place;
            defer self.read_place = saved;
            self.read_place = !writes;
            try self.w.print("const {s} = ", .{name});
            try self.emitAddressOf(recv);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = recv, .name = name, .ptr = self.reachesHandle(self.typeOf(recv)) });
        }
        const ty = self.typeOf(recv);
        const ptr = if (ty) |t| self.isPtrViewTy(t) else false;
        const kind: ?ResourceKind = if (ptr) null else if (ty) |t| self.kindOf(t) else null;
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional or (writes and !ptr)) "var" else "const", name });
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitBare(recv);
        try self.w.writeAll(";\n");
        if (kind == .value or kind == .optional or (writes and !ptr)) try self.poisonAtExit(name);
        // Sema rejects a viewed temporary receiver that owns a resource
        // (a consumed one is hoisted by `consumedTemporary`), so only a
        // value holding a type parameter gets here (`self.twice()` of a
        // `Wrap[T]`): plain data in every instance sema accepts, dropped
        // like a resource in the generic body.
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
    /// `pair(mk(1)!, mk(2)!)`, with `mk` returning a `Vec[Int]`:
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
        const slots = self.facts.callSlotsOf(call);
        const fields = self.buildsValue(call);
        const id = self.nextId();
        try self.w.print("__rig_call_{d}: ", .{id});
        try self.openBrace();
        const first = self.hoisted.items.len;
        if (try self.consumedTemporary(call)) |recv| {
            try self.hoist(.{ .node = recv, .name = try self.hiddenStorage(recv, .receiver, .owned, .{ .id = id }), .flag = try self.fmt("__rig_live_{d}_recv", .{id}) }, null, &.{}, 0, false);
        } else try self.hoistReceiver(call, id);
        for (args, 0..) |a, ai| {
            const value = argValue(a);
            if (try self.isPureArg(value)) continue;
            const slot: usize = if (slots) |ss| for (ss, 0..) |s, i| {
                if (s == .arg and s.arg == ai) break i;
            } else ai else ai;
            try self.hoist(.{ .node = value, .name = "", .flag = try self.fmt("__rig_live_{d}_{d}", .{ id, ai }) }, .{ .pair = .{ id, @intCast(ai) } }, params, slot, fields);
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
    /// An argument's storage is named here (`suffix`), held as it is
    /// written: a receiver the method consumes comes named.
    fn hoist(self: *Emitter, h_in: Hoisted, suffix: ?StorageSuffix, params: []const TypeId, slot: usize, fields: bool) Error!void {
        var h = h_in;
        // A consumed receiver (no suffix: its storage is named) is a value
        // of its own; an argument is held as the plan decided.
        const hold: facts.ArgumentHold = if (suffix == null) .value else try self.need(self.facts.argumentHold(h.node), h.node);
        if (hold == .closure or hold == .callable) {
            const fn_ty = self.facts.callableOf(h.node).?;
            if (suffix) |sx| h.name = try self.hiddenStorage(h.node, .argument, .owned, sx);
            if (hold == .closure) return self.hoistClosure(h, fn_ty);
            // The `rig.FnRef` has the type Zig gives it.
            try self.writeIndent(self.indent);
            try self.w.print("const {s} = ", .{h.name});
            try self.emitLentCallable(h.node, fn_ty);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
        }
        const ty = self.typeOf(h.node);
        const ptr = slot < params.len and self.isPtrViewTy(params[slot]);
        // A value lent as the view its parameter expects is held as that
        // view, of the parameter's type, which owns nothing.
        const lent = hold == .lent;
        // A temporary array lent as a slice stays in its slot, which owns
        // nothing to release: an array holds no value that needs cleanup.
        const lent_array = self.facts.lendsTempArray(h.node);
        const kind: ?ResourceKind = if (ptr or lent or lent_array) null else if (ty) |t| self.kindOf(t) else null;
        if (suffix) |sx| h.name = try self.hiddenStorage(h.node, .argument, if (ptr or lent) .pointer else .owned, sx);
        try self.writeIndent(self.indent);
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional) "var" else "const", h.name });
        // The value alone may have no Zig type (`.empty`, `null`, a
        // literal). A view read through is read here, in argument order.
        // A value lent has the parameter's type.
        const shown: ?TypeId = if (lent) (if (slot < params.len) params[slot] else null) else ty;
        if (shown) |t| if (!ptr) {
            try self.w.writeAll(": ");
            try self.emitTypeTy(if (self.readsThrough(h.node)) self.peelViews(t) else t);
        };
        try self.w.writeAll(" = ");
        if (fields) try self.emitStored(h.node) else if (self.facts.lendsTempArray(h.node)) try self.emitBare(h.node) else try self.emitArg(h.node, params, slot);
        try self.w.writeAll(";\n");
        if (kind == .value or kind == .optional) try self.poisonAtExit(h.name);
        const k = kind orelse return self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
        try self.line("var {s} = true;", .{h.flag});
        try self.writeIndent(self.indent);
        try self.w.print("defer if ({s}) ", .{h.flag});
        try self.writeDrop(h.name, k);
        try self.w.writeAll(";\n");
        try self.hoisted.append(self.allocator, h);
    }

    /// `storage.keptInSlot`.

    /// The address of `e` in its statement's slot (`keptInSlot`).
    fn emitSlotAddress(self: *Emitter, e: Sexp) Error!void {
        const saved = self.read_place;
        defer self.read_place = saved;
        self.read_place = true;
        try self.w.writeAll("&(");
        if (self.facts.dropsTemp(e)) try self.emitBare(e) else try self.emitPlace(e);
        try self.w.writeAll(")");
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
        const callee = self.facts.calleeOf(call);
        if (callee.isKind(.enum_lit)) return true;
        if (callee.isKind(.member)) return self.facts.typeOf(callee) == null;
        return self.isConstructorCall(call);
    }

    /// A call `emitCall` lowers with `emitConstructor`, whose Zig spells
    /// the value's type.
    fn isConstructorCall(self: *Emitter, e: Sexp) bool {
        if (!e.isKind(.call) or self.facts.calleeOf(e) != .src) return false;
        if (self.localOf(self.facts.calleeOf(e))) |local| if (local.stack_closure) return false;
        const sym_id = self.facts.symbolOf(self.facts.calleeOf(e)) orelse return false;
        return sym_id != self.facts.vec_sym_id and sym_id != self.facts.signal_sym_id and sym_id != self.facts.box_sym_id and self.isTypeSym(sym_id);
    }

    /// Constructor call `Name(field: v, ...)`: a struct literal typed by
    /// sema (a generic type's arguments come from the call's type).
    fn emitConstructor(self: *Emitter, call: Sexp, sym_id: SymbolId) Error!void {
        if (self.facts.symbols.items[sym_id].kind == .generic_type) {
            const ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped generic constructor");
            try self.emitTypeTy(ty);
        } else {
            try self.writeNominalName(sym_id);
        }
        try self.emitFieldInit(ir.Call.args(call), self.facts.symbols.items[sym_id].fields orelse &.{});
    }

    /// The members of the struct or enum type `ty` is declared as.
    fn declFields(self: *Emitter, ty: TypeId) []const facts.Field {
        const decl = self.facts.nominalDecl(ty) orelse return &.{};
        return decl.symbol().fields orelse &.{};
    }

    /// The type a constructor's bracket list gives (`Vec[Int]()`), before
    /// the decl literal that builds it.
    fn emitGivenType(self: *Emitter, call: Sexp) Error!void {
        const inst = self.facts.instanceOf(ir.Call.callee(call)) orelse return;
        if (inst == .type) try self.emitTypeTy(inst.type);
    }

    /// `{ .a = x, ... }` from keyword arguments, or from the one
    /// positional argument of a type or variant whose `fields` hold one
    /// data field.
    fn emitFieldInit(self: *Emitter, args: []const Sexp, fields: []const facts.Field) Error!void {
        var sole: ?facts.Field = null;
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            sole = if (sole == null) f else null;
            if (sole == null) break;
        }
        try self.w.writeAll("{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (!a.isKind(.kwarg)) {
                const f = sole orelse return self.unsupported(a, "a positional field");
                try self.w.print(".{f} = ", .{ident(f.name)});
                try self.emitStored(a);
                continue;
            }
            try self.w.print(".{f} = ", .{ident(self.srcText(ir.Kwarg.name(a)))});
            try self.emitStored(ir.Kwarg.value(a));
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// `Vec()` / `Vec(capacity: n)`: a decl literal of the type sema gave
    /// it, which a `catch` or `??` handler cannot take from its result
    /// location.
    fn emitVecConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        try self.emitTypeTy(self.typeOf(call) orelse return self.unsupported(call, "an untyped Vec construction"));
        if (args.len == 1) {
            try self.w.writeAll(".initCapacity(");
            try self.emitBare(ir.Kwarg.value(args[0]));
            return self.w.writeAll(")");
        }
        try self.w.writeAll(".empty");
    }

    /// `Signal(v)`.
    fn emitSignalConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        if (args.len != 1) return self.unsupported(call, "this Signal construction");
        try self.emitGivenType(call);
        try self.w.writeAll(".init(");
        try self.emitBare(argValue(args[0]));
        try self.w.writeAll(")");
    }

    /// `Box(v)`: `v` moved into a new heap allocation.
    fn emitBoxConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        if (args.len != 1) return self.unsupported(call, "this Box construction");
        try self.emitTypeTy(self.typeOf(call) orelse return self.unsupported(call, "an untyped Box construction"));
        try self.w.writeAll(".init(");
        try self.emitStored(argValue(args[0]));
        try self.w.writeAll(")");
    }

    /// `.variant(args)` → `.{ .variant = .{ .field = value, ... } }`.
    fn emitVariantLit(self: *Emitter, call: Sexp) Error!void {
        const vname = self.srcText(ir.EnumLit.name(ir.Call.callee(call)));
        if (ir.Call.args(call).len == 0) return self.w.print(".{f}", .{ident(vname)});
        const enum_ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped variant");
        return self.emitVariantPayload(call, enum_ty, vname);
    }

    fn emitVariantPayload(self: *Emitter, call: Sexp, enum_ty: TypeId, vname: []const u8) Error!void {
        const args = ir.Call.args(call);
        const payload = self.variantPayload(enum_ty, vname) orelse return self.unsupported(call, "this variant");
        try self.w.print(".{{ .{f} = .", .{ident(vname)});
        try self.emitFieldInit(args, payload);
        try self.w.writeAll(" }");
    }

    /// `print(a, b)`: the runtime writes each value the way Rig spells it.
    /// It reads a place that owns storage when it is called, after every
    /// argument has run, as the ownership checker holds it
    /// (`holdRead`): such a place goes by address, so a later argument
    /// that changes it through a Cell leaves no copy of what it frees.
    /// Plain data is copied whole where it is read.
    fn emitPrint(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("rig.print(");
        try self.emitPrintArgs(args);
        try self.w.writeAll(")");
    }

    /// The tuple of values the runtime's writer reads: `.{ a, &b }`.
    fn emitPrintArgs(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll(".{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (try self.printsByAddress(a)) {
                const saved_read = self.read_place;
                defer self.read_place = saved_read;
                self.read_place = true;
                try self.emitAddressOf(a);
            } else try self.emitBare(a);
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// Whether a `print`, `Text(...)`, or `add` argument `a` reads a
    /// place that owns storage, or is lent from one: a local, or a
    /// field or element of one (not a slice, which is a new value).
    fn printsByAddress(self: *Emitter, a: Sexp) Error!bool {
        return self.need(self.facts.printsByAddress(a), a);
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
        var out: std.ArrayList(Capture) = .empty;
        for (facts.syntax.captureList(captures)) |cap| {
            const name_node = facts.syntax.captureNameNode(cap).?;
            const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(cap, "an unresolved capture");
            const s = self.facts.symbols.items[sym];
            const outer: ?Local = if (self.localBySym(s.origin)) |l| l.* else null;
            try out.append(self.arena.allocator(), .{ .node = cap, .mode = cap.kind().?, .sym = sym, .name = s.name, .ty = s.ty, .outer = outer });
        }
        return out.items;
    }

    /// `f = |captures| body` → a struct holding the captures with an
    /// `__rig_invoke` method; calls lower to `f.__rig_invoke(...)`. When a capture
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

    /// `var name = struct { captures, fn __rig_invoke }{ inits };`. Returns
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

    /// A closure's environment: its captures as fields and a `__rig_invoke`
    /// method taking its parameters.
    ///
    ///     struct { cap_x: T, pub fn __rig_invoke(__rig_self: *@This(), a: A) R { ... } }
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
        try self.w.print("pub fn __rig_invoke({s}: *@This()", .{env});
        self.closure_depth += 1;
        defer self.closure_depth -= 1;
        const saved_fun = self.fun;
        defer self.fun = saved_fun;
        self.fun = .{ .return_ty = ret, .params = params, .unused_env = if (uses_env) "" else env };
        try self.bindParams(params);
        for (params.items()) |p| {
            try self.w.writeAll(", ");
            try self.emitParam(p, false);
        }
        try self.w.writeAll(") ");
        if (ret) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        const body = ir.Lambda.body(lambda);
        if (self.lambdaYields(lambda)) try self.emitValueBody(body) else try self.emitBlock(body);
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
                .cap_clone => try self.writeCloneCapture(&outer, c.node),
                .cap_weak => {
                    try self.writeLocalPlace(&outer);
                    try self.w.writeAll(".weakRef()");
                },
                .cap_move => if (outer.is_ptr and self.isPtrViewTy(c.ty)) {
                    // A moved pointer view moves the pointer.
                    try self.w.writeAll(outer.zig_name);
                } else try self.writeTake(&outer),
                .cap_read, .cap_write => try self.writeCapturedView(&outer, c.ty),
                else => try self.writeLocalPlace(&outer),
            }
        }
        try self.w.writeAll(" }");
    }

    /// `|+x|`: what `+x` gives of local `outer`, read through a view it
    /// holds (`sema.cloneable`): a handle counted again, an owner cloned
    /// part by part, or a copy of a value that copies.
    fn writeCloneCapture(self: *Emitter, outer: *const Local, node: Sexp) Error!void {
        const ty = outer.ty orelse return self.unsupported(node, "a capture of a value of unknown type");
        switch (self.facts.cloneable(ty)) {
            .bump => switch (self.facts.types.get(self.peelViews(ty))) {
                .optional => {
                    try self.w.writeAll("rig.cloneOptional(");
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(")");
                },
                .shared => {
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(".cloneStrong()");
                },
                else => {
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(".cloneWeak()");
                },
            },
            .text, .deep => {
                try self.w.writeAll("rig.cloneValue(&(");
                try self.writeLocalPlace(outer);
                try self.w.writeAll("))");
            },
            .copy, .depends => try self.writeLocalPlace(outer),
            .no => return self.unsupported(node, "a clone of a value that moves"),
        }
    }

    /// `|?x|` / `|!x|`: the view of local `outer` a closure holds, of
    /// type `ty`, as `?x` / `!x` gives it: a pointer, or for a read
    /// view of plain data, the value.
    fn writeCapturedView(self: *Emitter, outer: *const Local, ty: TypeId) Error!void {
        // `|?f|` of a stack closure lends its environment.
        if (outer.stack_closure) if (self.facts.callableFn(ty)) |f| {
            try self.emitCallableTy("FnRef", f);
            return self.w.print(".of(@TypeOf({s}), &{s})", .{ outer.zig_name, outer.zig_name });
        };
        const outer_is_view = if (outer.ty) |t| switch (self.facts.types.get(t)) {
            .read_view, .write_view => true,
            else => false,
        } else false;
        // A `![]T` is the slice itself; a view of a view passes it on.
        if (self.facts.writeSliceElem(ty) != null or (outer_is_view and (self.isPtrViewTy(ty) or !outer.is_ptr))) {
            return self.w.writeAll(outer.zig_name);
        }
        if (self.genericReadView(ty) != null) {
            try self.w.writeAll("rig.lend(");
            if (!outer.is_ptr) try self.w.writeAll("&");
            try self.w.writeAll(outer.zig_name);
            return self.w.writeAll(")");
        }
        if (self.isPtrViewTy(ty)) {
            if (!outer.is_ptr) try self.w.writeAll("&");
            return self.w.writeAll(outer.zig_name);
        }
        try self.writeLocalPlace(outer);
    }

    /// `*|captures, params| body` → a heap-allocated environment, erased
    /// into the runtime closure and boxed:
    ///
    ///     __rig_closure_N: {
    ///         const __rig_Env_N = struct { cap_x: T, pub fn __rig_invoke(...) R { ... } };
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
        const env_ptr = try self.hiddenStorage(lambda, .closure_env, .owned, .{ .id = id });

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
        try self.emitCallableTy("Closure", f);
        try self.w.print(".init({s}, {s}));\n", .{ env, env_ptr });
        try self.closeBrace();
    }

    /// The runtime type behind a function type: `rig.Closure(&.{ A, B }, R)`
    /// for an owned closure `*fun(A, B) -> R`, `rig.FnRef(...)` for a
    /// callable view `?fun(A, B) -> R`.
    fn emitCallableTy(self: *Emitter, comptime runtime_type: []const u8, f: facts.FunctionType) Error!void {
        try self.w.writeAll("rig." ++ runtime_type ++ "(&.{");
        for (f.params, 0..) |p, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitTypeTy(p);
        }
        try self.w.writeAll(if (f.params.len > 0) " }, " else "}, ");
        if (f.is_sub and f.returns == self.facts.types.void_id) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
        try self.w.writeAll(")");
    }

    /// `e`, lent where a callable view of function type `fn_ty` is
    /// expected (`SemContext.callableOf`): a function, as
    /// `rig.FnRef(...).ofFn(f)`, or a viewed owned closure, as
    /// `.ofClosure(handle)`. A closure literal was hoisted
    /// (`hoistClosure`).
    fn emitLentCallable(self: *Emitter, e: Sexp, fn_ty: TypeId) Error!void {
        const f = self.facts.types.get(fn_ty).function;
        try self.emitCallableTy("FnRef", f);
        const ty = self.typeOf(e) orelse return self.unsupported(e, "an untyped callable");
        try self.w.writeAll(if (self.facts.ownedClosureFn(ty) != null) ".ofClosure(" else ".ofFn(");
        const saved = self.lending;
        defer self.lending = saved;
        self.lending = e;
        try self.emitExpr(e);
        try self.w.writeAll(")");
    }

    /// `?f` where `f` is a stack closure, a function value, or already a
    /// callable view: the `rig.FnRef` of function type `fn_ty`.
    fn emitFnRef(self: *Emitter, operand: Sexp, fn_ty: TypeId) Error!void {
        const ty = self.typeOf(operand) orelse return self.unsupported(operand, "an untyped callable");
        if (self.facts.callableFn(ty) != null) return self.emitExpr(operand);
        const f = self.facts.types.get(fn_ty).function;
        if (operand == .src) if (self.localOf(operand)) |local| if (local.stack_closure) {
            try self.emitCallableTy("FnRef", f);
            return self.w.print(".of(@TypeOf({s}), &{s})", .{ local.zig_name, local.zig_name });
        };
        try self.emitCallableTy("FnRef", f);
        try self.w.writeAll(".ofFn(");
        try self.emitExpr(operand);
        try self.w.writeAll(")");
    }

    /// A closure literal lent to the call being hoisted as a viewed
    /// callable: its environment `__rig_env_N`, dropped when the call's
    /// block ends if it owns what it captured, and the `rig.FnRef`
    /// lending it, the argument `h.name`.
    fn hoistClosure(self: *Emitter, h: Hoisted, fn_ty: TypeId) Error!void {
        const env = try self.hiddenStorage(h.node, .environment, .owned, .next);
        try self.writeIndent(self.indent);
        const owns = try self.emitStackClosure(env, h.node);
        try self.w.writeAll("\n");
        try self.poisonAtExit(env);
        if (owns) try self.line("defer rig.dropFields(&{s});", .{env});
        try self.writeIndent(self.indent);
        try self.w.print("const {s} = ", .{h.name});
        try self.emitCallableTy("FnRef", self.facts.types.get(fn_ty).function);
        try self.w.print(".of(@TypeOf({s}), &{s});\n", .{ env, env });
        try self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
    }

    /// Whether a closure's body yields its value: not a `sub`'s, even a
    /// fallible one (`Void!`).
    fn lambdaYields(self: *Emitter, lambda: Sexp) bool {
        return self.facts.lambdaYields(lambda);
    }

    /// The value type a closure literal's body produces, or null.
    fn lambdaReturn(self: *Emitter, lambda: Sexp) ?TypeId {
        const f = self.fnType(self.typeOf(lambda)) orelse return null;
        return switch (self.facts.types.get(f.returns)) {
            .void, .unknown, .invalid, .noreturn => null,
            else => f.returns,
        };
    }

    // =========================================================================
    // Types
    // =========================================================================

    /// A type sema resolved.
    fn emitTypeTy(self: *Emitter, ty: TypeId) Error!void {
        const ctx = self.facts;
        switch (ctx.types.get(ty)) {
            .void, .any_error, .bool, .string, .text, .int_literal, .float_literal, .int, .float => try self.emitBuiltinTy(ctx.types.get(ty)),
            .optional => |inner| {
                try self.w.writeAll("?");
                try self.emitTypeTy(inner);
            },
            // Rig functions do not declare their errors.
            .fallible => |inner| {
                try self.w.writeAll("anyerror!");
                try self.emitTypeTy(inner);
            },
            .read_view => |inner| {
                if (ctx.callableFn(ty)) |f| return self.emitCallableTy("FnRef", f);
                if (self.genericReadView(ty) != null) {
                    try self.w.writeAll("rig.ReadView(");
                    try self.emitTypeTy(inner);
                    return self.w.writeAll(")");
                }
                if (self.readViewIsPtr(inner)) return self.emitViewPtrTy(inner, .read);
                try self.emitTypeTy(inner);
            },
            .write_view => |inner| {
                // A `![]T` is the Zig slice itself, writable.
                if (ctx.writeSliceElem(ty)) |elem| {
                    try self.w.writeAll("[]");
                    return self.emitTypeTy(elem);
                }
                try self.w.writeAll("*");
                try self.emitTypeTy(inner);
            },
            .shared, .weak => |inner| {
                try self.w.writeAll(if (ctx.types.get(ty) == .shared) "*rig.RcBox(" else "rig.WeakHandle(");
                switch (ctx.types.get(inner)) {
                    .function => |f| try self.emitCallableTy("Closure", f),
                    else => try self.emitTypeTy(inner),
                }
                try self.w.writeAll(")");
            },
            .slice => |s| {
                try self.w.writeAll("[]const ");
                try self.emitTypeTy(s.elem);
            },
            .array => |a| {
                try self.w.writeAll("[");
                try self.emitTypeTy(a.len);
                try self.w.writeAll("]");
                try self.emitTypeTy(a.elem);
            },
            // An array length or a generic type's value argument.
            .ct_value => |v| try self.w.print("{d}", .{v.int}),
            .ct_param => |sym_id| try self.writeTypeParam(sym_id),
            .nominal => |sym_id| try self.writeNominalName(sym_id),
            .imported_nominal => |in| {
                const foreign = ctx.foreign(in.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
                try self.writeModuleRef(in.module_id);
                try self.w.print(".{f}", .{ident(foreign.symbols.items[in.sym_id].name)});
            },
            .parameterized_nominal => |pn| {
                if (self.isSelfInstance(pn)) return self.w.writeAll("__rig_Self");
                try self.writeNominalName(pn.sym);
                try self.w.writeAll("(");
                try self.emitTypeList(pn.args);
                try self.w.writeAll(")");
            },
            // A generic function's type parameter is its `comptime`
            // parameter; a generic type's, its function's.
            .type_var => |sym_id| try self.writeTypeParam(sym_id),
            .function => |f| {
                try self.w.writeAll("*const fn (");
                try self.emitTypeList(f.params);
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
            },
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// A built-in type, which needs no type store.
    fn emitBuiltinTy(self: *Emitter, t: facts.Type) Error!void {
        switch (t) {
            .void => try self.w.writeAll("void"),
            .any_error => try self.w.writeAll("anyerror"),
            .bool => try self.w.writeAll("bool"),
            .string => try self.w.writeAll("[]const u8"),
            .text => try self.w.writeAll("rig.Text"),
            .int_literal => try self.w.writeAll(int_zig),
            .float_literal => try self.w.writeAll(float_zig),
            .int => |i| if (i.bits == 0) try self.w.writeAll(int_zig) else try self.w.print("{c}{d}", .{ @as(u8, if (i.signed) 'i' else 'u'), i.bits }),
            .float => |f| if (f.bits == 0) try self.w.writeAll(float_zig) else try self.w.print("f{d}", .{f.bits}),
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// A type parameter, or a compile-time value parameter: a generic
    /// function's `comptime` parameter, or a generic type's function's.
    fn writeTypeParam(self: *Emitter, sym: SymbolId) Error!void {
        if (self.localBySym(sym)) |local| return self.w.writeAll(local.zig_name);
        try self.w.print("{f}", .{ident(self.facts.symbols.items[sym].name)});
    }

    /// `A, B, C`.
    fn emitTypeList(self: *Emitter, tys: []const TypeId) Error!void {
        for (tys, 0..) |t, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitTypeTy(t);
        }
    }

    /// A user nominal, or a runtime one (`Vec` → `rig.Vec`), or another
    /// module's generic type through its proxy (`lib.Wrap`).
    fn writeNominalName(self: *Emitter, sym: SymbolId) Error!void {
        const s = self.facts.symbols.items[sym];
        if (self.facts.isBuiltinGeneric(sym) or sym == self.facts.endian_sym_id) {
            return self.w.print("rig.{s}", .{s.name});
        }
        if (facts.syntax.isProxy(s)) {
            const foreign = self.facts.foreign(s.from.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
            try self.writeModuleRef(s.from.module_id);
            return self.w.print(".{f}", .{ident(foreign.symbols.items[s.from.sym].name)});
        }
        try self.writeModuleName(s.name);
    }

    /// Another module, by the name this one imports it as, or, for a
    /// module reached only through an import, by its file.
    fn writeModuleRef(self: *Emitter, module_id: u32) Error!void {
        for (0..self.facts.importCount()) |i| {
            const imp = self.facts.importAt(i);
            if (imp.module_id == module_id) return self.writeModuleName(imp.local_name);
        }
        const foreign = self.facts.foreign(module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
        try self.w.print("@import(\"{s}\")", .{foreign.zig_file});
    }

    /// The generic type being emitted, applied to its own parameters:
    /// `__rig_Self` inside its body.
    fn isSelfInstance(self: *Emitter, pn: facts.ParamNominal) bool {
        const n = self.nominal orelse return false;
        if (pn.sym != n.sym) return false;
        const params = self.facts.symbols.items[n.sym].type_params orelse return false;
        if (params.len != pn.args.len) return false;
        for (params, pn.args) |p, a| switch (self.facts.types.get(a)) {
            .type_var, .ct_param => |v| if (v != p) return false,
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
        const ty = self.facts.typeOf(expr) orelse return null;
        return self.known(ty);
    }

    fn symType(self: *Emitter, sym: SymbolId) ?TypeId {
        return self.known(self.facts.symbols.items[sym].ty);
    }

    fn known(self: *Emitter, ty: TypeId) ?TypeId {
        if (ty == self.facts.types.unknown_id or ty == self.facts.types.invalid_id) return null;
        return ty;
    }

    /// `storage.fnType`.
    fn fnType(self: *Emitter, ty: ?TypeId) ?facts.FunctionType {
        return self.facts.fnType(ty);
    }

    fn peelViews(self: *Emitter, ty: TypeId) TypeId {
        return self.facts.unwrapViews(ty);
    }

    /// `storage.variantPayload`.
    fn variantPayload(self: *Emitter, enum_ty: TypeId, vname: []const u8) ?[]const facts.Field {
        return self.facts.variantPayload(enum_ty, vname);
    }

    /// How a value of this type that moves (`sema.moves`) is held and
    /// released, or null for a value that copies. A value that moves gets
    /// `var` storage, owned `as` and payload bindings, and an owned
    /// closure environment; the kind picks its drop call. `rig.drop`
    /// releases only what needs cleanup: a unique value, or a value of a
    /// type parameter whose instance needs none, drops nothing.
    fn kindOf(self: *Emitter, ty: TypeId) ?ResourceKind {
        if (self.facts.pending.moves(ty) == .no) return null;
        return switch (self.facts.types.get(ty)) {
            .shared => .shared,
            .weak => .weak,
            .optional => .optional,
            else => .value,
        };
    }

    fn isBuiltinInstance(self: *Emitter, ty: TypeId, sym_id: SymbolId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .parameterized_nominal => |pn| pn.sym == sym_id,
            else => false,
        };
    }

    /// A Cell holding a Vec, reached by value, view, or shared handle.
    fn isCellVecTy(self: *Emitter, ty: TypeId) bool {
        const cell = switch (self.facts.types.get(self.facts.unwrapReadAccess(ty))) {
            .parameterized_nominal => |pn| if (pn.sym == self.facts.cell_sym_id and pn.args.len == 1) pn.args[0] else return false,
            else => return false,
        };
        return self.isVecTy(cell);
    }

    fn isVecTy(self: *Emitter, ty: TypeId) bool {
        return self.isBuiltinInstance(ty, self.facts.vec_sym_id);
    }

    /// Whether a value of `ty` is a shared handle, or a view of one: a
    /// pointer to it is a pointer to a pointer, which Zig does not reach
    /// a field or method through.
    fn reachesHandle(self: *Emitter, ty: ?TypeId) bool {
        return self.facts.types.get(self.peelViews(ty orelse return false)) == .shared;
    }

    /// `.*` for each pointer a value of `ty`, a shared handle or a view
    /// of one, is above the handle: Zig reaches a field through a
    /// pointer to the handle's box, never through one to the handle.
    fn derefToHandle(self: *Emitter, ty: ?TypeId) Error!void {
        var t = ty orelse return;
        if (!self.reachesHandle(t)) return;
        while (true) switch (self.facts.types.get(t)) {
            .read_view, .write_view => |inner| {
                if (self.isPtrViewTy(t)) try self.w.writeAll(".*");
                t = inner;
            },
            else => return,
        };
    }

    fn isStructLike(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .nominal, .parameterized_nominal, .imported_nominal => true,
            else => false,
        };
    }

    fn hasLen(self: *Emitter, ty: TypeId) bool {
        const peeled = self.peelViews(ty);
        return switch (self.facts.types.get(peeled)) {
            .array, .slice, .string => true,
            else => self.isVecTy(peeled),
        };
    }

    /// Numbers, Bool, String, functions, and optionals of them: bindings
    /// of these types are annotated, since a literal or branch value alone
    /// has no runtime type, and a function name alone is a function body,
    /// not a pointer to one.
    fn isPlainTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string, .function => true,
            .optional => |inner| self.isPlainTy(inner),
            else => false,
        };
    }

    /// An error set (local or imported) or any error: its members are
    /// spelled `error.name`.
    fn isErrorSetTy(self: *Emitter, ty: TypeId) bool {
        const t = self.peelViews(ty);
        return self.facts.types.get(t) == .any_error or self.facts.isErrorSet(t);
    }

    /// The type an integer literal takes in arithmetic of `e`'s type: a
    /// float type (a `Float` literal is a `Float`) or a type parameter.
    fn literalTypeOf(self: *Emitter, e: Sexp) ?TypeId {
        const ty = self.typeOf(e) orelse return null;
        return switch (self.facts.types.get(ty)) {
            .float, .type_var => ty,
            .float_literal => self.facts.types.float_id,
            else => null,
        };
    }

    /// `pre(left, right)post`. A payload variant literal (`.circle(r: 1)`)
    /// is spelled with its enum type, which the other operand gave it.
    fn emitCall2(self: *Emitter, pre: []const u8, operands: [2]Sexp, post: []const u8) Error!void {
        try self.w.writeAll(pre);
        for (operands, 0..) |o, i| {
            if (i > 0) try self.w.writeAll(", ");
            const variant = o.isKind(.call) and ir.Call.callee(o).isKind(.enum_lit);
            const ty = if (variant) self.typeOf(o) else null;
            if (ty) |t| try self.writeAsOpen(t);
            try self.emitExpr(o);
            if (ty != null) try self.w.writeAll(")");
        }
        try self.w.writeAll(post);
    }

    /// Whether `a == b` compares with `rig.eql` rather than Zig's `==`:
    /// an operand is not a scalar (a String, a struct, a payload enum, an
    /// array or slice, an optional of one, an optional error, or a type
    /// parameter's value). `none` compares with any optional by `==`.
    fn comparesStructurally(self: *Emitter, operands: [2]Sexp) bool {
        for (operands) |o| if (self.isNoneLeaf(o)) return false;
        for (operands) |o| {
            const ty = self.typeOf(o) orelse continue;
            const t = self.peelViews(ty);
            const scalar = switch (self.facts.types.get(t)) {
                .optional => |inner| self.isScalarTy(inner) and !self.isErrorSetTy(inner),
                else => self.isScalarTy(t),
            };
            if (!scalar) return true;
        }
        return false;
    }

    /// An operand whose value is an enum with payloads, or an optional
    /// of one.
    fn isPayloadEnumOperand(self: *Emitter, e: Sexp) bool {
        const ty = self.typeOf(e) orelse return false;
        const t = switch (self.facts.types.get(self.peelViews(ty))) {
            .optional => |inner| inner,
            else => self.peelViews(ty),
        };
        return self.hasPayloadVariants(t);
    }

    /// A number, Bool, plain enum, or error: Zig's `==` compares it.
    fn isScalarTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(ty)) {
            .int, .float, .bool, .int_literal, .float_literal, .any_error => true,
            .nominal, .imported_nominal => self.facts.isPlainEnum(ty) or self.facts.isErrorSet(ty),
            else => false,
        };
    }

    const OrderOperator = struct {
        /// Strings or byte slices; otherwise a type parameter's values.
        bytes: bool,
        /// The `std.math.CompareOperator` name.
        op: []const u8,
        /// What tests the `std.math.Order` of two byte strings.
        test_: []const u8,
    };

    /// How `a < b` (`<=`, `>`, `>=`) lowers when Zig's operator does not
    /// order its operands; null for numbers.
    fn orderOperator(self: *Emitter, kind: Tag, operands: [2]Sexp) ?OrderOperator {
        var bytes = false;
        var generic = false;
        for (operands) |o| {
            const ty = self.typeOf(o) orelse continue;
            const t = self.peelViews(ty);
            switch (self.facts.types.get(t)) {
                .string, .slice => bytes = true,
                else => generic = generic or self.facts.containsTypeVar(t),
            }
        }
        if (!bytes and !generic) return null;
        return switch (kind) {
            .@"<" => .{ .bytes = bytes, .op = "lt", .test_ = ") == .lt" },
            .@"<=" => .{ .bytes = bytes, .op = "lte", .test_ = ") != .gt" },
            .@">" => .{ .bytes = bytes, .op = "gt", .test_ = ") == .gt" },
            .@">=" => .{ .bytes = bytes, .op = "gte", .test_ = ") != .lt" },
            else => null,
        };
    }

    /// The builtin `left op right` lowers to for `/` and `%`, or null for
    /// float `/`, which is ordinary division. Integer `/` truncates toward
    /// zero (`@divTrunc`), and a type parameter's values divide as their
    /// instance does (`rig.div`). `%` is the remainder with the dividend's
    /// sign (`rig.rem`), for integers and floats alike.
    fn divBuiltin(self: *Emitter, op: Tag, left: Sexp, right: Sexp) ?[]const u8 {
        if (op == .@"%") return "rig.rem";
        if (self.literal_ty) |t| return if (self.facts.types.get(t) == .type_var) "rig.div" else null;
        var builtin: []const u8 = "@divTrunc";
        for ([2]Sexp{ left, right }) |e| {
            const ty = self.typeOf(e) orelse continue;
            switch (self.facts.types.get(self.peelViews(ty))) {
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

    /// `defer rig.poison(&name);` for the hidden `var` `name` (`poison`),
    /// written before its drop's `defer`, so it runs after the drop.
    fn poisonAtExit(self: *Emitter, name: []const u8) Error!void {
        if (self.poison) try self.line("defer rig.poison(&{s});", .{name});
    }

    /// Report a construct the emitter cannot lower. Sema is responsible
    /// for rejecting it with a proper diagnostic; reaching this is a
    /// compiler bug.
    fn unsupported(self: *Emitter, node: Sexp, what: []const u8) Error {
        const lc = diag.lineCol(self.source, self.facts.startOf(if (node == .nil) self.stmt else node));
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

    fn walk(s: *Scan, sexp: Sexp) Error!void {
        switch (sexp) {
            .src => |leaf| {
                const sym = s.e.facts.symbolOf(sexp) orelse return;
                if (s.e.facts.symbols.items[sym].decl_pos != leaf.pos) try s.put(&s.e.usage.used, sym);
                return;
            },
            .list => {},
            else => return,
        }
        // A group (parameters, a function type's parameters) names
        // what it holds, too.
        const head = sexp.kind() orelse {
            for (sexp.items()) |c| try s.walk(c);
            return;
        };
        switch (head) {
            .cap_clone, .cap_weak, .cap_move, .cap_read, .cap_write => {
                const cap = s.e.facts.symbolOf(ir.get(sexp, .name)) orelse return;
                try s.put(&s.e.usage.used, s.e.facts.symbols.items[cap].origin);
                return;
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

fn ident(name: []const u8) Ident {
    return .{ .name = name };
}

/// The Zig name of member `name` of error set `set`, declared in the
/// module `owner`: `@"Set.name"`, or `@"mod.Set.name"` for a module other
/// than the root. Zig's errors share one namespace, so each carries its
/// set and module; `rig.print` shows the last two parts.
fn writeErrorName(w: *Writer, owner: Facts, set: []const u8, name: []const u8) Error!void {
    const module = nameModule(owner);
    if (module.len == 0) return w.print("@\"{s}.{s}\"", .{ set, name });
    try w.print("@\"{s}.{s}.{s}\"", .{ module, set, name });
}

/// The module a name the emitter writes carries (an error's, a type's
/// `__rig_name`): its own, or none for the root.
fn nameModule(ctx: Facts) []const u8 {
    return if (ctx.is_root) "" else ctx.name;
}

/// A literal default value: a number, a string, `true` / `false`,
/// `none`, `.variant`, or a negated number.
fn isDefaultLiteralNode(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => |s| blk: {
            const t = source[s.pos..][0..s.len];
            break :blk isLiteralText(t) or std.mem.eql(u8, t, "none");
        },
        .list => e.isKind(.enum_lit) or (e.isKind(.neg) and ir.Neg.operand(e) == .src),
        else => false,
    };
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
    return name.len > 0 and name[0] != '@' and std.mem.findScalar(u8, name, '.') == null;
}

/// Whether Zig could evaluate `e` at compile time: it is built only from
/// literals, compile-time names (compile-time parameters, `const` bindings),
/// constructors, and operators. Conservative: true when unsure.
fn isZigComptimeIn(em: *Emitter, e: Sexp, depth: u8) bool {
    if (depth > 32) return true;
    switch (e) {
        .src => {
            const t = em.srcText(e);
            if (isLiteralText(t) or std.mem.eql(u8, t, "none")) return true;
            const sym = em.facts.symbolOf(e) orelse return true;
            const sd = em.facts.symbols.items[sym];
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
                    const callee = em.facts.calleeOf(e);
                    const ctor = callee.isKind(.enum_lit) or (callee == .src and if (em.facts.symbolOf(callee)) |id| em.isTypeSym(id) else false);
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
    if (!facts.syntax.isIntLiteralText(t)) return false;
    const v = std.fmt.parseInt(Wide, t, 0) catch return false;
    return v == 0;
}

const isLiteralText = facts.syntax.isLiteralText;

/// An integer or float literal.
fn isNumberText(t: []const u8) bool {
    return facts.syntax.isIntLiteralText(t) or facts.syntax.isFloatLiteralText(t);
}

fn isNonNegativeIntLiteral(source: []const u8, s: Sexp) bool {
    if (s != .src) return false;
    const t = source[s.src.pos..][0..s.src.len];
    for (t) |c| if (!std.ascii.isDigit(c) and c != '_') return false;
    return t.len > 0;
}

const lentPlace = facts.syntax.lentPlace;

/// Whether `e` moves a compound value, `<(a if c else b)` or `<(?t)`,
/// emitted as that value, which a postfix after it would not reach
/// whole: anything but a name, a field, an element, or a call.
fn movesCompound(e: Sexp) bool {
    if (!e.isKind(.move)) return false;
    const o = ir.Move.operand(e);
    if (o != .list) return false;
    return !(o.isKind(.member) or o.isKind(.index) or o.isKind(.call));
}

const argValue = facts.syntax.argValue;

const contains = facts.syntax.contains;

/// The same IR node: the same leaf, or the same list.
fn sameNode(a: Sexp, b: Sexp) bool {
    return switch (a) {
        .src => |s| b == .src and b.src.pos == s.pos,
        .list => b == .list and a.items().ptr == b.items().ptr,
        else => false,
    };
}

fn isTerminatingStmt(s: Sexp) bool {
    const h = s.kind() orelse return false;
    return h == .@"return" or h == .@"break" or h == .@"continue";
}

// Emitted code never writes through a const pointer or into const
// storage: a Cell lives only behind a shared handle, on the heap, and a
// value that holds one is viewed through a mutable pointer
// (`emitViewPtrTy`), so no cast is ever
// needed, and a write a missed site would make through a `*const T` is a
// Zig compile error rather than undefined behavior. Neither the emitter
// nor the runtime casts constness away, except the runtime's `FnRef.ofFn`,
// which erases a function pointer into a context no code writes through.
test "emit and the runtime cast no constness away" {
    const cast = "@const" ++ "Cast(";
    try std.testing.expectEqual(0, std.mem.count(u8, @embedFile("emit.zig"), cast));
    try std.testing.expectEqual(1, std.mem.count(u8, runtime_source, cast));
    const of_fn = std.mem.indexOf(u8, runtime_source, "pub fn ofFn(").?;
    const end = std.mem.indexOfPos(u8, runtime_source, of_fn, "\n        }\n").?;
    try std.testing.expect(std.mem.indexOf(u8, runtime_source[of_fn..end], cast) != null);
}
