//! Semantic analysis: names, types, and expression checking.
//!
//! `check` runs four passes over the normalized IR and returns a
//! `SemContext`, which every later pass (effects, ownership, emit)
//! reads:
//!
//!   1. builtins     `sema_builtins.zig`  Cell, Vec, Signal
//!   2. symbols      `sema_decls.zig`     every declaration gets a Symbol in
//!                                        a Scope; scopes are keyed by the IR
//!                                        node that opens them
//!   3. declarations `sema_decls.zig`     type expressions become TypeIds;
//!                                        signatures, fields, variants, aliases
//!   4. expressions  `sema_expr.zig`      bodies are type-checked; every
//!                                        expression's type is recorded
//!
//! ## The facts table
//!
//! Sema records what it learned about each IR node so later passes can
//! ask instead of re-deriving it by name:
//!
//!   ctx.symbolOf(leaf)   -> ?SymbolId  the symbol an identifier leaf names,
//!                                      at its declaration or any use site
//!   ctx.typeOf(node)     -> ?TypeId    the type of an expression node
//!                                      (literals get the type their context
//!                                      gave them, e.g. `U8` in `x: U8 = 5`)
//!   ctx.bindingTypeOf(leaf) -> ?TypeId the declared/inferred type of the
//!                                      symbol a leaf names
//!   ctx.scopeOf(node)    -> ?ScopeId   the scope a fun/sub/method/lambda/
//!                                      block/for/arm/catch node opens
//!   ctx.isExhaustive(match) -> bool   the match's arms cover every value
//!                                      without a default arm
//!   ctx.callSlotsOf(call) -> ?[]ArgSlot for a call with keyword or
//!                                      omitted arguments: which argument
//!                                      (or default value) fills each
//!                                      parameter, in parameter order
//!
//! A call's callee gets a type too: a function name its signature, and a
//! method callee `(member obj m)` the resolved method signature with the
//! receiver's generic arguments applied. The name leaf of every `fun` /
//! `sub` declaration, method or not, carries its function type. Binding
//! facts live on the Symbol: `flags.reassigned`, `flags.written`,
//! `flags.fixed`,
//! `flags.comptime_known`, `flags.pattern_bound`, `kind` (local / param /
//! capture / ...), and for a capture the `origin` binding it captures.
//!
//! Leaves are keyed by source position (`src.pos`); list nodes by the
//! identity of their item slice (`NodeKey`), which is stable because
//! every pass walks the same IR tree that was passed to `check`. A node
//! that sema never reached (dead code after an error, type positions)
//! has no entry; callers treat `null` as "no information".
//!
//! Types are interned in `TypeStore`, so two TypeIds are the same type
//! iff they are equal. `unknown` and `invalid` are poison: they appear
//! only after a diagnostic has been reported and are compatible with
//! everything so one mistake doesn't cascade.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
pub const diag = @import("diag.zig");
const builtins = @import("sema_builtins.zig");
const decls = @import("sema_decls.zig");
const exprs = @import("sema_expr.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;

// =============================================================================
// IDs
// =============================================================================

pub const SymbolId = u32;
pub const ScopeId = u32;
pub const TypeId = u32;

/// Slot 0 of every table is a sentinel, so `id != 0` means "valid".
pub const symbol_invalid: SymbolId = 0;
pub const scope_invalid: ScopeId = 0;
pub const type_invalid: TypeId = 0;

// =============================================================================
// Types
// =============================================================================

pub const IntInfo = struct {
    /// 0 for `Int` (64-bit signed); otherwise 8/16/32/64.
    bits: u8 = 0,
    signed: bool = true,
};

pub const FloatInfo = struct {
    /// 0 for `Float` (64-bit); otherwise 32/64.
    bits: u8 = 0,
};

pub const FunctionType = struct {
    params: []const TypeId,
    returns: TypeId,
    is_sub: bool,
    /// Bit i set: parameter i is a `pre` (compile-time) parameter.
    pre_mask: u32 = 0,

    pub fn isPre(self: FunctionType, i: usize) bool {
        return i < 32 and (self.pre_mask >> @intCast(i)) & 1 == 1;
    }
};

pub const SliceType = struct { elem: TypeId };
pub const ArrayType = struct { elem: TypeId, len: u64 };

pub const Type = union(enum) {
    /// A type error was reported here.
    invalid,
    /// Not known; only ever produced after a diagnostic.
    unknown,

    void,
    bool,
    string,
    int: IntInfo,
    float: FloatInfo,

    /// Unsuffixed numeric literals. They take the numeric type their
    /// context expects and default to `Int` / `Float` otherwise.
    int_literal,
    float_literal,
    /// `none` before its context gives it an optional type.
    none_literal,
    /// Expressions that never complete: `return`, `break`, `continue`.
    noreturn,

    optional: TypeId, // T?
    fallible: TypeId, // T!
    borrow_read: TypeId, // ?T
    borrow_write: TypeId, // !T
    shared: TypeId, // *T
    weak: TypeId, // ~T

    slice: SliceType,
    array: ArrayType,
    /// `a..b`: a half-open range of the element integer type. Only valid
    /// as a `for` source.
    range: TypeId,

    function: FunctionType,
    /// A struct, enum, error set, or opaque declared in this module.
    nominal: SymbolId,
    /// A nominal declared in another module. Identity is the origin
    /// module plus the symbol there, never the shape.
    imported_nominal: ImportedNominal,
    /// A generic type applied to arguments: `Box(Int)`.
    parameterized_nominal: ParamNominal,
    /// A generic parameter (`T` inside `type Box(T)`).
    type_var: SymbolId,
};

pub const ParamNominal = struct {
    sym: SymbolId,
    args: []const TypeId,
};

pub const ImportedNominal = struct {
    module_id: u32,
    sym_id: SymbolId,
};

/// One resolved `use NAME` of the module being checked. `sema` must
/// outlive the importing SemContext.
pub const ImportEntry = struct {
    local_name: []const u8,
    sema: *SemContext,
    module_id: u32,
};

/// Interns types so structural equality is TypeId equality. Lookup is
/// a hash map keyed by the type's structure.
pub const TypeStore = struct {
    items: std.ArrayListUnmanaged(Type) = .empty,
    map: std.HashMapUnmanaged(TypeId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    invalid_id: TypeId = type_invalid,
    unknown_id: TypeId = type_invalid,
    void_id: TypeId = type_invalid,
    bool_id: TypeId = type_invalid,
    string_id: TypeId = type_invalid,
    int_id: TypeId = type_invalid,
    float_id: TypeId = type_invalid,
    int_literal_id: TypeId = type_invalid,
    float_literal_id: TypeId = type_invalid,
    none_id: TypeId = type_invalid,
    noreturn_id: TypeId = type_invalid,

    const IdContext = struct {
        items: []const Type,
        pub fn hash(self: IdContext, id: TypeId) u64 {
            return hashType(self.items[id]);
        }
        pub fn eql(_: IdContext, a: TypeId, b: TypeId) bool {
            return a == b;
        }
    };

    const TypeContext = struct {
        items: []const Type,
        pub fn hash(_: TypeContext, t: Type) u64 {
            return hashType(t);
        }
        pub fn eql(self: TypeContext, t: Type, id: TypeId) bool {
            return typeEqual(t, self.items[id]);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !TypeStore {
        var s: TypeStore = .{};
        s.invalid_id = try s.intern(allocator, .invalid);
        std.debug.assert(s.invalid_id == type_invalid);
        s.unknown_id = try s.intern(allocator, .unknown);
        s.void_id = try s.intern(allocator, .void);
        s.bool_id = try s.intern(allocator, .bool);
        s.string_id = try s.intern(allocator, .string);
        s.int_id = try s.intern(allocator, .{ .int = .{} });
        s.float_id = try s.intern(allocator, .{ .float = .{} });
        s.int_literal_id = try s.intern(allocator, .int_literal);
        s.float_literal_id = try s.intern(allocator, .float_literal);
        s.none_id = try s.intern(allocator, .none_literal);
        s.noreturn_id = try s.intern(allocator, .noreturn);
        return s;
    }

    pub fn deinit(self: *TypeStore, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.items.deinit(allocator);
    }

    pub fn get(self: *const TypeStore, id: TypeId) Type {
        if (id >= self.items.items.len) return .invalid;
        return self.items.items[id];
    }

    /// Return the id of `ty`, adding it if new. Slices inside `ty`
    /// (function params, generic args) must outlive the store.
    pub fn intern(self: *TypeStore, allocator: std.mem.Allocator, ty: Type) !TypeId {
        const gop = try self.map.getOrPutContextAdapted(
            allocator,
            ty,
            TypeContext{ .items = self.items.items },
            IdContext{ .items = self.items.items },
        );
        if (gop.found_existing) return gop.key_ptr.*;
        const id: TypeId = @intCast(self.items.items.len);
        self.items.append(allocator, ty) catch |e| {
            self.map.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.key_ptr.* = id;
        return id;
    }

    fn hashType(t: Type) u64 {
        var h = std.hash.Wyhash.init(0);
        const tag: u8 = @intFromEnum(std.meta.activeTag(t));
        h.update(&.{tag});
        switch (t) {
            .invalid, .unknown, .void, .bool, .string, .int_literal, .float_literal, .none_literal, .noreturn => {},
            .int => |i| h.update(&.{ i.bits, @intFromBool(i.signed) }),
            .float => |f| h.update(&.{f.bits}),
            .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak, .range => |inner| hashId(&h, inner),
            .slice => |s| hashId(&h, s.elem),
            .array => |a| {
                hashId(&h, a.elem);
                h.update(std.mem.asBytes(&a.len));
            },
            .function => |f| {
                for (f.params) |p| hashId(&h, p);
                hashId(&h, f.returns);
                h.update(&.{@intFromBool(f.is_sub)});
                h.update(std.mem.asBytes(&f.pre_mask));
            },
            .nominal, .type_var => |s| hashId(&h, s),
            .imported_nominal => |n| {
                hashId(&h, n.module_id);
                hashId(&h, n.sym_id);
            },
            .parameterized_nominal => |pn| {
                hashId(&h, pn.sym);
                for (pn.args) |a| hashId(&h, a);
            },
        }
        return h.final();
    }

    fn hashId(h: *std.hash.Wyhash, id: u32) void {
        h.update(std.mem.asBytes(&id));
    }

    fn typeEqual(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .invalid, .unknown, .void, .bool, .string, .int_literal, .float_literal, .none_literal, .noreturn => true,
            .int => |ai| ai.bits == b.int.bits and ai.signed == b.int.signed,
            .float => |af| af.bits == b.float.bits,
            .optional => |x| x == b.optional,
            .fallible => |x| x == b.fallible,
            .borrow_read => |x| x == b.borrow_read,
            .borrow_write => |x| x == b.borrow_write,
            .shared => |x| x == b.shared,
            .weak => |x| x == b.weak,
            .range => |x| x == b.range,
            .slice => |s| s.elem == b.slice.elem,
            .array => |x| x.elem == b.array.elem and x.len == b.array.len,
            .function => |af| af.is_sub == b.function.is_sub and
                af.returns == b.function.returns and
                af.pre_mask == b.function.pre_mask and
                std.mem.eql(TypeId, af.params, b.function.params),
            .nominal => |x| x == b.nominal,
            .type_var => |x| x == b.type_var,
            .imported_nominal => |x| x.module_id == b.imported_nominal.module_id and x.sym_id == b.imported_nominal.sym_id,
            .parameterized_nominal => |x| x.sym == b.parameterized_nominal.sym and
                std.mem.eql(TypeId, x.args, b.parameterized_nominal.args),
        };
    }
};

// =============================================================================
// Symbols and scopes
// =============================================================================

pub const SymbolKind = enum {
    /// Top-level `fun` / `sub`.
    function,
    param,
    /// Block-local binding: `x = ...`, `new x = ...`, loop and pattern
    /// bindings, and `catch` names.
    local,
    /// `type UserId = Int`. Transparent: the alias's `ty` is its target.
    type_alias,
    /// `type Box(T)` / `enum Option(T)` and the built-in generics.
    generic_type,
    /// `T` in `type Box(T)`. Detached: not in any scope; reached through
    /// the owning type's `type_params`.
    generic_param,
    /// struct / enum / error set / opaque.
    nominal_type,
    /// A module imported with `use`.
    module,
    /// `extern` variable or body-less `extern fun` / `extern sub`.
    @"extern",
    /// A closure capture, bound in the lambda's scope with the type the
    /// capture mode gives it.
    capture,
};

pub const SymbolFlags = packed struct(u16) {
    /// `=!` binding: cannot be reassigned.
    fixed: bool = false,
    is_public: bool = false,
    /// Parameter declared with a borrowed type (`?T` / `!T`).
    borrowed_param: bool = false,
    /// Struct with a user `drop` or a field whose type has drop glue.
    /// Such values are non-Copy and get a generated `__rig_drop`.
    has_drop_glue: bool = false,
    /// `pre` parameter.
    is_pre: bool = false,
    /// Value known at compile time: a `pre` parameter, or a `=!` binding
    /// initialized with a compile-time-known expression.
    comptime_known: bool = false,
    /// Bound by a `for` loop or a match pattern: not assignable.
    pattern_bound: bool = false,
    /// Assigned again after its declaration (`=`, `<-`, `+=`, ...):
    /// lowers to a Zig `var`.
    reassigned: bool = false,
    /// Written through: write-borrowed (`!x`), or a field or element of
    /// it assigned. Also lowers to a Zig `var`.
    written: bool = false,
    _: u7 = 0,
};

/// How a method takes its receiver, from the declared first parameter.
pub const MethodReceiver = enum { none, read, write, value };

/// A member of a nominal type: data field, method, or enum variant.
pub const Field = struct {
    name: []const u8,
    ty: TypeId,
    decl_pos: u32,
    /// Payload fields of a payload-bearing enum variant.
    payload: ?[]const Field = null,
    /// A method; `ty` is its function type.
    is_method: bool = false,
    receiver: MethodReceiver = .none,
    /// An enum / error-set variant (not a data field).
    is_variant: bool = false,
    /// The struct's user `drop self: !Self` body. Not callable.
    is_drop_method: bool = false,
    /// A data field declared with a default value (`name: T = expr`).
    has_default: bool = false,
    /// Parameter names of a method, for keyword arguments.
    param_names: ?[]const []const u8 = null,
    /// Default values of a method's parameters (null where none).
    param_defaults: ?[]const ?Sexp = null,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    ty: TypeId,
    decl_pos: u32,
    scope: ScopeId,
    flags: SymbolFlags = .{},
    /// Members of a nominal or generic type; null for other kinds and
    /// for opaque types.
    fields: ?[]const Field = null,
    /// Generic parameters of a generic type, in declaration order.
    type_params: ?[]const SymbolId = null,
    /// Parameter names of a function, for keyword arguments.
    param_names: ?[]const []const u8 = null,
    /// Default values of a function's parameters (null where none).
    param_defaults: ?[]const ?Sexp = null,
    /// A capture: the enclosing binding it captures.
    origin: SymbolId = symbol_invalid,
};

pub const ScopeKind = enum { module, function, lambda, block };

pub const Scope = struct {
    parent: ?ScopeId,
    symbols: std.ArrayListUnmanaged(SymbolId) = .empty,
    kind: ScopeKind = .block,
};

pub const Diagnostic = diag.Diagnostic;

/// How a receiver expression is written, and what kind of value it is,
/// for the method receiver-mode rules.
pub const ReceiverShape = exprs.ReceiverShape;
pub const ReceiverTypeKind = exprs.ReceiverTypeKind;
pub const compatible = exprs.compatible;

// =============================================================================
// Facts
// =============================================================================

/// Identity of an IR list node: the address and length of its item
/// slice.
pub const NodeKey = struct { addr: usize, len: usize };

pub fn nodeKey(node: Sexp) ?NodeKey {
    return switch (node) {
        .list => |items| .{ .addr = @intFromPtr(items.ptr), .len = items.len },
        else => null,
    };
}

pub const Facts = struct {
    /// Identifier leaf position -> the symbol it names.
    names: std.AutoHashMapUnmanaged(u32, SymbolId) = .empty,
    /// Leaf expression position -> type.
    leaf_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// List expression node -> type.
    node_types: std.AutoHashMapUnmanaged(NodeKey, TypeId) = .empty,
    /// Scope-opening node -> the scope it opens.
    scopes: std.AutoHashMapUnmanaged(NodeKey, ScopeId) = .empty,
    /// Call node -> how its arguments fill the parameters, for calls
    /// with keyword arguments or omitted (defaulted) parameters.
    call_slots: std.AutoHashMapUnmanaged(NodeKey, []const ArgSlot) = .empty,
    /// Match nodes whose non-default arms cover every value.
    exhaustive: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,

    fn deinit(self: *Facts, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
        self.leaf_types.deinit(allocator);
        self.node_types.deinit(allocator);
        self.scopes.deinit(allocator);
        self.call_slots.deinit(allocator);
        self.exhaustive.deinit(allocator);
    }
};

/// What fills one parameter of a call: the argument at an index of the
/// call's argument list (a `(kwarg ...)` stands for its value), or the
/// parameter's default value, a literal from the declaring module.
pub const ArgSlot = union(enum) {
    arg: u32,
    default: DefaultValue,
};

pub const DefaultValue = struct {
    expr: Sexp,
    /// Source of the module that declares the parameter.
    source: []const u8,
};

/// An operation a generic body applies to a type parameter. Checked
/// against every instantiation of the generic type.
pub const Requirement = enum {
    numeric,
    ordered,
    equatable,
    integer,

    pub fn describe(self: Requirement) []const u8 {
        return switch (self) {
            .numeric => "arithmetic",
            .ordered => "ordering comparison",
            .equatable => "`==` / `!=`",
            .integer => "integer operators",
        };
    }
};

pub const GenericRequirement = struct {
    param: SymbolId,
    req: Requirement,
    pos: u32,
    op: []const u8,
};

// =============================================================================
// SemContext
// =============================================================================

pub const SemContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    /// Owns symbol names, messages, and every slice inside a Type.
    arena: std.heap.ArenaAllocator,

    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    /// Scope 1 is the module scope.
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    types: TypeStore,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    facts: Facts = .{},

    cell_sym_id: SymbolId = symbol_invalid,
    vec_sym_id: SymbolId = symbol_invalid,
    signal_sym_id: SymbolId = symbol_invalid,

    /// Assigned by the module graph; 0 for a lone file.
    module_id: u32 = 0,
    imports: []const ImportEntry = &.{},
    /// `use NAME` symbol -> origin module id.
    module_refs: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    /// Origin module id -> its SemContext.
    foreign_semas: std.AutoHashMapUnmanaged(u32, *SemContext) = .empty,

    /// Type alias symbol -> its target type expression, resolved on
    /// first use (aliases may be used before they are declared).
    alias_targets: std.AutoHashMapUnmanaged(SymbolId, Sexp) = .empty,
    /// Aliases currently being resolved, to report cycles.
    alias_in_progress: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Operations generic bodies apply to their type parameters.
    generic_requirements: std.ArrayListUnmanaged(GenericRequirement) = .empty,
    /// Instantiated generic type -> position of its first spelling.
    instantiation_sites: std.AutoHashMapUnmanaged(TypeId, u32) = .empty,
    /// Integer constants: bindings never reassigned or written whose
    /// value is a constant expression. The emitted Zig computes these at
    /// compile time, so sema checks their arithmetic.
    const_ints: std.AutoHashMapUnmanaged(SymbolId, i128) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !SemContext {
        var ctx: SemContext = .{
            .allocator = allocator,
            .source = source,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try TypeStore.init(allocator),
        };
        try ctx.symbols.append(allocator, .{
            .name = "",
            .kind = .local,
            .ty = ctx.types.invalid_id,
            .decl_pos = 0,
            .scope = scope_invalid,
        });
        try ctx.scopes.append(allocator, .{ .parent = null });
        return ctx;
    }

    pub fn deinit(self: *SemContext) void {
        for (self.scopes.items) |*s| s.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.module_refs.deinit(self.allocator);
        self.foreign_semas.deinit(self.allocator);
        self.alias_targets.deinit(self.allocator);
        self.alias_in_progress.deinit(self.allocator);
        self.generic_requirements.deinit(self.allocator);
        self.instantiation_sites.deinit(self.allocator);
        self.const_ints.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const SemContext) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    pub fn writeDiagnostics(self: *const SemContext, file_path: []const u8, w: anytype) !void {
        try diag.write(self.diagnostics.items, self.source, file_path, w);
    }

    pub fn err(self: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = pos, .message = msg });
    }

    pub fn note(self: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .note, .pos = pos, .message = msg });
    }

    pub fn pushScope(self: *SemContext, parent: ScopeId) !ScopeId {
        return self.pushScopeKind(parent, .block);
    }

    pub fn pushScopeKind(self: *SemContext, parent: ScopeId, kind: ScopeKind) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .parent = if (parent == scope_invalid) null else parent,
            .kind = kind,
        });
        return id;
    }

    /// The latest symbol named `name` declared directly in `scope_id`.
    pub fn lookupInScopeOnly(self: *const SemContext, scope_id: ScopeId, name: []const u8) ?SymbolId {
        if (scope_id == scope_invalid or scope_id >= self.scopes.items.len) return null;
        const syms = self.scopes.items[scope_id].symbols.items;
        var i = syms.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols.items[syms[i]].name, name)) return syms[i];
        }
        return null;
    }

    /// The symbol `name` resolves to from `from_scope`: the latest
    /// declaration in the innermost enclosing scope that has one.
    pub fn lookup(self: *const SemContext, from_scope: ScopeId, name: []const u8) ?SymbolId {
        var sid: ?ScopeId = from_scope;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            if (self.lookupInScopeOnly(s, name)) |id| return id;
            sid = self.scopes.items[s].parent;
        }
        return null;
    }

    /// Like `lookup`, but stops at the nearest function or lambda
    /// scope: finds only names local to the current body.
    pub fn lookupLocal(self: *const SemContext, from_scope: ScopeId, name: []const u8) ?SymbolId {
        var sid: ?ScopeId = from_scope;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            if (self.lookupInScopeOnly(s, name)) |id| return id;
            const scope = self.scopes.items[s];
            if (scope.kind == .function or scope.kind == .lambda or scope.kind == .module) break;
            sid = scope.parent;
        }
        return null;
    }

    /// The nearest enclosing function or lambda scope of `scope_id`.
    pub fn bodyRoot(self: *const SemContext, scope_id: ScopeId) ?ScopeId {
        var sid: ?ScopeId = scope_id;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            const scope = self.scopes.items[s];
            if (scope.kind == .function or scope.kind == .lambda) return s;
            sid = scope.parent;
        }
        return null;
    }

    // ---- facts: queries ---------------------------------------------------

    /// The symbol an identifier leaf names (declaration or use).
    pub fn symbolOf(self: *const SemContext, node: Sexp) ?SymbolId {
        return switch (node) {
            .src => |s| self.facts.names.get(s.pos),
            else => null,
        };
    }

    /// The symbol named by the identifier at source position `pos`.
    pub fn symbolAt(self: *const SemContext, pos: u32) ?SymbolId {
        return self.facts.names.get(pos);
    }

    /// The type of an expression node.
    pub fn typeOf(self: *const SemContext, node: Sexp) ?TypeId {
        return switch (node) {
            .src => |s| self.facts.leaf_types.get(s.pos),
            .list => self.facts.node_types.get(nodeKey(node).?),
            else => null,
        };
    }

    /// The type of the symbol an identifier leaf names.
    pub fn bindingTypeOf(self: *const SemContext, node: Sexp) ?TypeId {
        const id = self.symbolOf(node) orelse return null;
        return self.symbols.items[id].ty;
    }

    /// The scope a scope-opening node opens.
    pub fn scopeOf(self: *const SemContext, node: Sexp) ?ScopeId {
        const key = nodeKey(node) orelse return null;
        return self.facts.scopes.get(key);
    }

    /// Whether a match's arms, without a default arm, cover every value
    /// of its scrutinee.
    pub fn isExhaustive(self: *const SemContext, match: Sexp) bool {
        const key = nodeKey(match) orelse return false;
        return self.facts.exhaustive.contains(key);
    }

    /// Parameter-order argument slots of a call with keyword arguments
    /// or omitted parameters; null when the arguments are positional
    /// and complete.
    pub fn callSlotsOf(self: *const SemContext, call: Sexp) ?[]const ArgSlot {
        const key = nodeKey(call) orelse return null;
        return self.facts.call_slots.get(key);
    }

    // ---- facts: recording (sema passes only) -----------------------------

    pub fn recordName(self: *SemContext, node: Sexp, sym: SymbolId) !void {
        if (node != .src or sym == symbol_invalid) return;
        try self.facts.names.put(self.allocator, node.src.pos, sym);
    }

    pub fn recordType(self: *SemContext, node: Sexp, ty: TypeId) !void {
        switch (node) {
            .src => |s| try self.facts.leaf_types.put(self.allocator, s.pos, ty),
            .list => try self.facts.node_types.put(self.allocator, nodeKey(node).?, ty),
            else => {},
        }
    }

    pub fn recordScope(self: *SemContext, node: Sexp, scope: ScopeId) !void {
        const key = nodeKey(node) orelse return;
        try self.facts.scopes.put(self.allocator, key, scope);
    }

    pub fn recordExhaustive(self: *SemContext, match: Sexp) !void {
        const key = nodeKey(match) orelse return;
        try self.facts.exhaustive.put(self.allocator, key, {});
    }

    pub fn recordCallSlots(self: *SemContext, call: Sexp, slots: []const ArgSlot) !void {
        const key = nodeKey(call) orelse return;
        try self.facts.call_slots.put(self.allocator, key, slots);
    }

    pub fn intern(self: *SemContext, ty: Type) std.mem.Allocator.Error!TypeId {
        return self.types.intern(self.allocator, ty);
    }

    pub fn dupeIds(self: *SemContext, ids: []const TypeId) std.mem.Allocator.Error![]const TypeId {
        return self.arena.allocator().dupe(TypeId, ids);
    }
};

// =============================================================================
// Entry points
// =============================================================================

/// Check a single module with no imports.
pub fn check(allocator: std.mem.Allocator, source: []const u8, ir: Sexp) !SemContext {
    return checkWithImports(allocator, source, ir, &.{}, 0);
}

/// Check a module whose `use` declarations resolve to `imports`.
pub fn checkWithImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    ir: Sexp,
    imports: []const ImportEntry,
    module_id: u32,
) !SemContext {
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    ctx.module_id = module_id;
    // The caller's slice is temporary; the emitter reads the imports later.
    ctx.imports = try ctx.arena.allocator().dupe(ImportEntry, imports);
    for (imports) |imp| try ctx.foreign_semas.put(allocator, imp.module_id, imp.sema);

    const module_scope = try ctx.pushScopeKind(scope_invalid, .module);
    try builtins.register(&ctx, module_scope);
    try decls.resolveSymbols(&ctx, ir, module_scope);
    try decls.resolveDeclarations(&ctx, ir, module_scope);
    propagateDropGlue(&ctx);
    try exprs.checkModule(&ctx, ir, module_scope);
    try exprs.checkGenericInstantiations(&ctx);
    return ctx;
}

/// `has_drop_glue` depends on field types, which may name structs
/// declared later; iterate until no flag changes.
fn propagateDropGlue(ctx: *SemContext) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (ctx.symbols.items) |*sym| {
            if (sym.kind != .nominal_type or sym.flags.has_drop_glue) continue;
            const fields = sym.fields orelse continue;
            for (fields) |f| {
                const glue = f.is_drop_method or (!f.is_method and if (f.is_variant)
                    payloadHasDropGlue(ctx, f)
                else
                    typeHasDropGlue(ctx, f.ty));
                if (glue) {
                    sym.flags.has_drop_glue = true;
                    changed = true;
                    break;
                }
            }
        }
    }
}

fn payloadHasDropGlue(ctx: *const SemContext, f: Field) bool {
    for (f.payload orelse &.{}) |pf| if (typeHasDropGlue(ctx, pf.ty)) return true;
    return false;
}

// =============================================================================
// Type queries
// =============================================================================

pub const builtin_decl_pos: u32 = std.math.maxInt(u32);

/// Does a value of this type need its destructor run: a `*T` / `~T`
/// handle, a Vec, an owned closure, a Cell holding such a value, or a
/// struct flagged `has_drop_glue`. Types with drop glue are non-Copy.
pub fn typeHasDropGlue(ctx: *const SemContext, ty_id: TypeId) bool {
    return hasDropGlueUnder(ctx, ty_id, null, 0);
}

/// Type arguments in effect while looking inside a generic instance.
const GlueSubst = struct {
    params: []const SymbolId,
    args: []const TypeId,
    outer: ?*const GlueSubst,
};

/// `typeHasDropGlue` inside generic instances: a type parameter has glue
/// when its argument does, and an instance of a user generic has glue
/// when any field or variant payload does under its arguments.
fn hasDropGlueUnder(ctx: *const SemContext, ty_id: TypeId, subst: ?*const GlueSubst, depth: u8) bool {
    if (ty_id == ctx.types.invalid_id or ty_id == ctx.types.unknown_id) return false;
    if (depth > 16) return false;
    return switch (ctx.types.get(ty_id)) {
        .shared, .weak => true,
        .optional => |inner| hasDropGlueUnder(ctx, inner, subst, depth + 1),
        .type_var => |sym| blk: {
            const sb = subst orelse break :blk false;
            for (sb.params, 0..) |p, i| {
                if (p == sym and i < sb.args.len) break :blk hasDropGlueUnder(ctx, sb.args[i], sb.outer, depth + 1);
            }
            break :blk false;
        },
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.vec_sym_id) break :blk true;
            if (pn.sym == ctx.cell_sym_id) break :blk pn.args.len == 1 and hasDropGlueUnder(ctx, pn.args[0], subst, depth + 1);
            const base = ctx.symbols.items[pn.sym];
            if (base.flags.has_drop_glue) break :blk true;
            const inner: GlueSubst = .{ .params = base.type_params orelse &.{}, .args = pn.args, .outer = subst };
            const fields = base.fields orelse break :blk false;
            for (fields) |f| {
                if (f.is_method) continue;
                if (f.is_variant) {
                    for (f.payload orelse &.{}) |pf| if (hasDropGlueUnder(ctx, pf.ty, &inner, depth + 1)) break :blk true;
                    continue;
                }
                if (hasDropGlueUnder(ctx, f.ty, &inner, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .nominal => |sym| ctx.symbols.items[sym].flags.has_drop_glue,
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk false;
            if (in.sym_id >= foreign.symbols.items.len) break :blk false;
            break :blk foreign.symbols.items[in.sym_id].flags.has_drop_glue;
        },
        else => false,
    };
}

/// The signature of an owned closure handle `*fun(...) R` / `*sub(...)`
/// (possibly borrowed), or null.
pub fn ownedClosureFn(ctx: *const SemContext, ty: TypeId) ?FunctionType {
    return switch (ctx.types.get(unwrapBorrows(ctx, ty))) {
        .shared => |inner| switch (ctx.types.get(inner)) {
            .function => |f| f,
            else => null,
        },
        else => null,
    };
}

/// A value an owned closure can take or return: its runtime form is
/// type-erased, so only plain Copy data crosses it (a Copy primitive, a
/// plain enum, or an optional of one).
pub fn isClosureValue(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .invalid, .unknown => true,
        .optional => |inner| isCopyPrimitive(ctx, inner) or isPlainEnum(ctx, inner),
        .nominal, .imported_nominal => isPlainEnum(ctx, ty),
        else => isCopyPrimitive(ctx, ty),
    };
}

/// An enum all of whose variants are bare (no payloads): comparable
/// with `==`.
pub fn isPlainEnum(ctx: *const SemContext, ty: TypeId) bool {
    const decl = nominalDecl(ctx, ty) orelse return false;
    const fields = decl.symbol().fields orelse return false;
    var any = false;
    for (fields) |f| {
        if (!f.is_variant) continue;
        any = true;
        if (f.payload != null and f.payload.?.len > 0) return false;
    }
    return any;
}

/// Primitive values that are copied freely.
pub fn isCopyPrimitive(ctx: *const SemContext, ty_id: TypeId) bool {
    return switch (ctx.types.get(ty_id)) {
        .bool, .int, .float, .string, .int_literal, .float_literal => true,
        else => false,
    };
}

pub fn isNumeric(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int, .float, .int_literal, .float_literal => true,
        else => false,
    };
}

pub fn isInteger(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int, .int_literal => true,
        else => false,
    };
}

/// Peel `?T` / `!T`.
pub fn unwrapBorrows(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = ty_id;
    while (true) {
        switch (ctx.types.get(id)) {
            .borrow_read, .borrow_write => |inner| id = inner,
            else => return id,
        }
    }
}

/// Peel `?T`, `!T`, and `*T`: the view read-only member access sees.
/// Weak handles and optionals are not peeled; they must be upgraded or
/// unwrapped explicitly.
pub fn unwrapReadAccess(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = ty_id;
    while (true) {
        switch (ctx.types.get(id)) {
            .borrow_read, .borrow_write, .shared => |inner| id = inner,
            else => return id,
        }
    }
}

/// The nominal symbol behind a receiver type, after peeling borrows.
pub fn nominalSymOfReceiver(ctx: *const SemContext, ty_id: TypeId) ?SymbolId {
    return switch (ctx.types.get(unwrapBorrows(ctx, ty_id))) {
        .nominal => |s| s,
        .parameterized_nominal => |pn| pn.sym,
        else => null,
    };
}

/// Where a nominal type is declared: the module's context and the
/// symbol there. A type imported from another module resolves to that
/// module's declaration.
pub const NominalDecl = struct {
    ctx: *const SemContext,
    sym: SymbolId,
    /// The origin module of an imported nominal; null for a local one.
    module_id: ?u32 = null,

    pub fn symbol(self: NominalDecl) Symbol {
        return self.ctx.symbols.items[self.sym];
    }
};

/// The declaration behind a (possibly borrowed) nominal type, local or
/// imported.
pub fn nominalDecl(ctx: *const SemContext, ty_id: TypeId) ?NominalDecl {
    return switch (ctx.types.get(unwrapBorrows(ctx, ty_id))) {
        .nominal => |s| .{ .ctx = ctx, .sym = s },
        .parameterized_nominal => |pn| .{ .ctx = ctx, .sym = pn.sym },
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk null;
            if (in.sym_id >= foreign.symbols.items.len) break :blk null;
            break :blk .{ .ctx = foreign, .sym = in.sym_id, .module_id = in.module_id };
        },
        else => null,
    };
}

/// Generic-parameter substitution: `params[i]` maps to `args[i]`.
pub const TypeSubst = struct {
    params: []const SymbolId,
    args: []const TypeId,

    pub const empty: TypeSubst = .{ .params = &.{}, .args = &.{} };

    pub fn lookup(self: TypeSubst, param: SymbolId) ?TypeId {
        for (self.params, 0..) |p, i| {
            if (p == param and i < self.args.len) return self.args[i];
        }
        return null;
    }

    pub fn isEmpty(self: TypeSubst) bool {
        return self.params.len == 0;
    }
};

/// Would `substituteType(ty_id, subst)` equal `target`? Does not
/// intern, so it works on a const context.
pub fn typeEqualsAfterSubst(ctx: *const SemContext, ty_id: TypeId, subst: TypeSubst, target: TypeId) bool {
    if (subst.isEmpty() and ty_id == target) return true;
    const ty = ctx.types.get(ty_id);
    if (ty == .type_var) {
        const resolved = subst.lookup(ty.type_var) orelse return ty_id == target;
        return typeEqualsAfterSubst(ctx, resolved, TypeSubst.empty, target);
    }
    const tgt = ctx.types.get(target);
    return switch (ty) {
        .borrow_read => |i| tgt == .borrow_read and typeEqualsAfterSubst(ctx, i, subst, tgt.borrow_read),
        .borrow_write => |i| tgt == .borrow_write and typeEqualsAfterSubst(ctx, i, subst, tgt.borrow_write),
        .shared => |i| tgt == .shared and typeEqualsAfterSubst(ctx, i, subst, tgt.shared),
        .weak => |i| tgt == .weak and typeEqualsAfterSubst(ctx, i, subst, tgt.weak),
        .optional => |i| tgt == .optional and typeEqualsAfterSubst(ctx, i, subst, tgt.optional),
        .fallible => |i| tgt == .fallible and typeEqualsAfterSubst(ctx, i, subst, tgt.fallible),
        .range => |i| tgt == .range and typeEqualsAfterSubst(ctx, i, subst, tgt.range),
        .slice => |s| tgt == .slice and typeEqualsAfterSubst(ctx, s.elem, subst, tgt.slice.elem),
        .array => |a| tgt == .array and a.len == tgt.array.len and typeEqualsAfterSubst(ctx, a.elem, subst, tgt.array.elem),
        .function => |f| blk: {
            if (tgt != .function) break :blk false;
            const tf = tgt.function;
            if (f.is_sub != tf.is_sub or f.pre_mask != tf.pre_mask or f.params.len != tf.params.len) break :blk false;
            if (!typeEqualsAfterSubst(ctx, f.returns, subst, tf.returns)) break :blk false;
            for (f.params, tf.params) |p, tp| {
                if (!typeEqualsAfterSubst(ctx, p, subst, tp)) break :blk false;
            }
            break :blk true;
        },
        .parameterized_nominal => |pn| blk: {
            if (tgt != .parameterized_nominal) break :blk false;
            const tpn = tgt.parameterized_nominal;
            if (pn.sym != tpn.sym or pn.args.len != tpn.args.len) break :blk false;
            for (pn.args, tpn.args) |a, ta| {
                if (!typeEqualsAfterSubst(ctx, a, subst, ta)) break :blk false;
            }
            break :blk true;
        },
        else => ty_id == target,
    };
}

/// Replace every `type_var` in `ty_id` that `subst` maps.
pub fn substituteType(ctx: *SemContext, ty_id: TypeId, subst: TypeSubst) std.mem.Allocator.Error!TypeId {
    if (subst.isEmpty()) return ty_id;
    const ty = ctx.types.get(ty_id);
    switch (ty) {
        .type_var => |sym| return subst.lookup(sym) orelse ty_id,
        inline .borrow_read, .borrow_write, .shared, .weak, .optional, .fallible, .range => |inner, tag| {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) return ty_id;
            return ctx.intern(@unionInit(Type, @tagName(tag), new_inner));
        },
        .slice => |s| {
            const e = try substituteType(ctx, s.elem, subst);
            if (e == s.elem) return ty_id;
            return ctx.intern(.{ .slice = .{ .elem = e } });
        },
        .array => |a| {
            const e = try substituteType(ctx, a.elem, subst);
            if (e == a.elem) return ty_id;
            return ctx.intern(.{ .array = .{ .elem = e, .len = a.len } });
        },
        .function => |f| {
            const ret = try substituteType(ctx, f.returns, subst);
            var changed = ret != f.returns;
            const params = try ctx.arena.allocator().alloc(TypeId, f.params.len);
            for (f.params, 0..) |p, i| {
                params[i] = try substituteType(ctx, p, subst);
                if (params[i] != p) changed = true;
            }
            if (!changed) return ty_id;
            return ctx.intern(.{ .function = .{ .params = params, .returns = ret, .is_sub = f.is_sub, .pre_mask = f.pre_mask } });
        },
        .parameterized_nominal => |pn| {
            var changed = false;
            const args = try ctx.arena.allocator().alloc(TypeId, pn.args.len);
            for (pn.args, 0..) |a, i| {
                args[i] = try substituteType(ctx, a, subst);
                if (args[i] != a) changed = true;
            }
            if (!changed) return ty_id;
            return ctx.intern(.{ .parameterized_nominal = .{ .sym = pn.sym, .args = args } });
        },
        else => return ty_id,
    }
}

/// Does `ty_id` mention a generic parameter anywhere?
pub fn containsTypeVar(ctx: *const SemContext, ty_id: TypeId) bool {
    return switch (ctx.types.get(ty_id)) {
        .type_var => true,
        .borrow_read, .borrow_write, .shared, .weak, .optional, .fallible, .range => |i| containsTypeVar(ctx, i),
        .slice => |s| containsTypeVar(ctx, s.elem),
        .array => |a| containsTypeVar(ctx, a.elem),
        .function => |f| blk: {
            for (f.params) |p| if (containsTypeVar(ctx, p)) break :blk true;
            break :blk containsTypeVar(ctx, f.returns);
        },
        .parameterized_nominal => |pn| blk: {
            for (pn.args) |a| if (containsTypeVar(ctx, a)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Copy a type from another module's store into `local_ctx`. Nominals
/// declared there become `imported_nominal` tagged with their origin.
pub fn importType(
    local_ctx: *SemContext,
    foreign_ctx: *SemContext,
    foreign_ty_id: TypeId,
    origin_module_id: u32,
) std.mem.Allocator.Error!TypeId {
    const ty = foreign_ctx.types.get(foreign_ty_id);
    switch (ty) {
        .invalid, .unknown, .void, .bool, .string, .int, .float, .int_literal, .float_literal, .none_literal, .noreturn => return local_ctx.intern(ty),
        inline .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak, .range => |inner, tag| {
            const local_inner = try importType(local_ctx, foreign_ctx, inner, origin_module_id);
            return local_ctx.intern(@unionInit(Type, @tagName(tag), local_inner));
        },
        .slice => |s| return local_ctx.intern(.{ .slice = .{ .elem = try importType(local_ctx, foreign_ctx, s.elem, origin_module_id) } }),
        .array => |a| return local_ctx.intern(.{ .array = .{ .elem = try importType(local_ctx, foreign_ctx, a.elem, origin_module_id), .len = a.len } }),
        .function => |f| {
            const params = try local_ctx.arena.allocator().alloc(TypeId, f.params.len);
            for (f.params, 0..) |p, i| params[i] = try importType(local_ctx, foreign_ctx, p, origin_module_id);
            const ret = try importType(local_ctx, foreign_ctx, f.returns, origin_module_id);
            return local_ctx.intern(.{ .function = .{ .params = params, .returns = ret, .is_sub = f.is_sub, .pre_mask = f.pre_mask } });
        },
        .nominal => |sym_id| return local_ctx.intern(.{ .imported_nominal = .{ .module_id = origin_module_id, .sym_id = sym_id } }),
        .imported_nominal => |n| return local_ctx.intern(.{ .imported_nominal = n }),
        // Built-in generics (Vec, Cell, ...) have the same symbol ids in
        // every module, so their ids carry over unchanged.
        .parameterized_nominal => |pn| {
            const args = try local_ctx.arena.allocator().alloc(TypeId, pn.args.len);
            for (pn.args, 0..) |a, i| args[i] = try importType(local_ctx, foreign_ctx, a, origin_module_id);
            return local_ctx.intern(.{ .parameterized_nominal = .{ .sym = pn.sym, .args = args } });
        },
        .type_var => |sym| return local_ctx.intern(.{ .type_var = sym }),
    }
}

/// The enclosing nominal while resolving a method signature or body:
/// what `Self` means, and which names are generic parameters.
pub const NominalContext = struct {
    sym: SymbolId,
    self_type: TypeId,
    type_params: []const SymbolId,

    pub const none: NominalContext = .{ .sym = symbol_invalid, .self_type = type_invalid, .type_params = &.{} };

    pub fn isEmpty(self: NominalContext) bool {
        return self.sym == symbol_invalid;
    }
};

/// `Self` is `nominal(sym)` for plain types and `Box(T)` (applied to
/// its own parameters) for generic ones.
pub fn makeNominalContext(ctx: *SemContext, sym_id: SymbolId) std.mem.Allocator.Error!NominalContext {
    const sym = ctx.symbols.items[sym_id];
    switch (sym.kind) {
        .nominal_type => return .{ .sym = sym_id, .self_type = try ctx.intern(.{ .nominal = sym_id }), .type_params = &.{} },
        .generic_type => {
            const tparams = sym.type_params orelse &.{};
            const args = try ctx.arena.allocator().alloc(TypeId, tparams.len);
            for (tparams, 0..) |tp, i| args[i] = try ctx.intern(.{ .type_var = tp });
            const self_type = try ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = args } });
            return .{ .sym = sym_id, .self_type = self_type, .type_params = tparams };
        },
        else => return NominalContext.none,
    }
}

pub const ResolvedField = struct {
    field: Field,
    /// The field's type with the receiver's generic arguments applied.
    ty: TypeId,
    nominal_sym: SymbolId,
};

pub const ResolvedMethod = struct {
    field: Field,
    receiver: MethodReceiver,
    /// The method's signature with the receiver's generic arguments applied.
    fn_ty: FunctionType,
    nominal_sym: SymbolId,
};

pub const ResolvedVariant = struct {
    field: Field,
    /// Payload fields with generic arguments applied; empty if none.
    payload: []const Field,
    /// The enum's symbol; `symbol_invalid` for an imported enum.
    nominal_sym: SymbolId,
    owner_name: []const u8,
};

const Members = struct {
    sym: SymbolId,
    fields: []const Field,
    subst: TypeSubst,
};

fn membersOf(ctx: *const SemContext, peeled: TypeId) ?Members {
    switch (ctx.types.get(peeled)) {
        .nominal => |s| return .{ .sym = s, .fields = ctx.symbols.items[s].fields orelse return null, .subst = TypeSubst.empty },
        .parameterized_nominal => |pn| {
            const sym = ctx.symbols.items[pn.sym];
            return .{
                .sym = pn.sym,
                .fields = sym.fields orelse return null,
                .subst = .{ .params = sym.type_params orelse &.{}, .args = pn.args },
            };
        },
        else => return null,
    }
}

/// A data field of the receiver's nominal (auto-deref through borrows
/// and `*T`).
pub fn lookupDataField(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedField {
    const m = membersOf(ctx, unwrapReadAccess(ctx, receiver_ty)) orelse return null;
    for (m.fields) |f| {
        if (f.is_method or f.is_variant) continue;
        if (std.mem.eql(u8, f.name, name)) {
            return .{ .field = f, .ty = try substituteType(ctx, f.ty, m.subst), .nominal_sym = m.sym };
        }
    }
    return null;
}

/// A callable method of the receiver's nominal (auto-deref through
/// borrows and `*T`). The user `drop` body is not callable.
pub fn lookupMethod(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedMethod {
    const m = membersOf(ctx, unwrapReadAccess(ctx, receiver_ty)) orelse return null;
    for (m.fields) |f| {
        if (!f.is_method or f.is_drop_method) continue;
        if (!std.mem.eql(u8, f.name, name)) continue;
        const sub_id = try substituteType(ctx, f.ty, m.subst);
        const sub = ctx.types.get(sub_id);
        if (sub != .function) continue;
        return .{ .field = f, .receiver = f.receiver, .fn_ty = sub.function, .nominal_sym = m.sym };
    }
    return null;
}

/// An enum variant of the receiver's nominal.
pub fn lookupVariant(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedVariant {
    if (ctx.types.get(unwrapBorrows(ctx, receiver_ty)) == .imported_nominal) {
        const decl = nominalDecl(ctx, receiver_ty) orelse return null;
        const foreign: *SemContext = @constCast(decl.ctx);
        for (decl.symbol().fields orelse return null) |f| {
            if (!f.is_variant or !std.mem.eql(u8, f.name, name)) continue;
            const orig = f.payload orelse &.{};
            const payload = try ctx.arena.allocator().alloc(Field, orig.len);
            for (orig, 0..) |pf, i| {
                payload[i] = pf;
                payload[i].ty = try importType(ctx, foreign, pf.ty, decl.module_id.?);
            }
            return .{ .field = f, .payload = payload, .nominal_sym = symbol_invalid, .owner_name = decl.symbol().name };
        }
        return null;
    }
    const m = membersOf(ctx, unwrapBorrows(ctx, receiver_ty)) orelse return null;
    for (m.fields) |f| {
        if (!f.is_variant or !std.mem.eql(u8, f.name, name)) continue;
        const orig = f.payload orelse &.{};
        const owner = ctx.symbols.items[m.sym].name;
        if (orig.len == 0 or m.subst.isEmpty()) return .{ .field = f, .payload = orig, .nominal_sym = m.sym, .owner_name = owner };
        const payload = try ctx.arena.allocator().alloc(Field, orig.len);
        for (orig, 0..) |pf, i| {
            payload[i] = pf;
            payload[i].ty = try substituteType(ctx, pf.ty, m.subst);
        }
        return .{ .field = f, .payload = payload, .nominal_sym = m.sym, .owner_name = owner };
    }
    return null;
}

pub fn hasMethodNamed(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) bool {
    const m = membersOf(ctx, unwrapReadAccess(ctx, receiver_ty)) orelse return false;
    for (m.fields) |f| {
        if (f.is_method and !f.is_drop_method and std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// Number of variants of an enum type, or null if not an enum.
pub fn enumVariantCount(ctx: *const SemContext, ty: TypeId) ?usize {
    const decl = nominalDecl(ctx, ty) orelse return null;
    const fields = decl.symbol().fields orelse return null;
    var count: usize = 0;
    for (fields) |f| {
        if (f.is_variant) count += 1;
    }
    return if (count == 0) null else count;
}

/// Render a type the way it is spelled in Rig source, allocating in the
/// context's arena.
pub fn formatType(ctx: *SemContext, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    return formatTypeIn(ctx, ctx.arena.allocator(), ty_id);
}

/// `formatType` with a caller-chosen allocator.
pub fn formatTypeIn(ctx: *const SemContext, a: std.mem.Allocator, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    return switch (ctx.types.get(ty_id)) {
        .invalid => "invalid",
        .unknown => "unknown",
        .void => "Void",
        .bool => "Bool",
        .string => "String",
        .int => |info| if (info.bits == 0) "Int" else try std.fmt.allocPrint(a, "{c}{d}", .{ @as(u8, if (info.signed) 'I' else 'U'), info.bits }),
        .float => |info| if (info.bits == 0) "Float" else try std.fmt.allocPrint(a, "F{d}", .{info.bits}),
        .int_literal => "Int",
        .float_literal => "Float",
        .none_literal => "none",
        .noreturn => "NoReturn",
        .optional => |inner| try formatSuffixed(ctx, a, inner, '?'),
        .fallible => |inner| try formatSuffixed(ctx, a, inner, '!'),
        .borrow_read => |inner| try std.fmt.allocPrint(a, "?{s}", .{try formatTypeIn(ctx, a, inner)}),
        .borrow_write => |inner| try std.fmt.allocPrint(a, "!{s}", .{try formatTypeIn(ctx, a, inner)}),
        .shared => |inner| try std.fmt.allocPrint(a, "*{s}", .{try formatTypeIn(ctx, a, inner)}),
        .weak => |inner| try std.fmt.allocPrint(a, "~{s}", .{try formatTypeIn(ctx, a, inner)}),
        .slice => |s| try std.fmt.allocPrint(a, "[]{s}", .{try formatTypeIn(ctx, a, s.elem)}),
        .array => |arr| try std.fmt.allocPrint(a, "[{d}]{s}", .{ arr.len, try formatTypeIn(ctx, a, arr.elem) }),
        .range => |e| try std.fmt.allocPrint(a, "range of {s}", .{try formatTypeIn(ctx, a, e)}),
        .function => |f| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(a, if (f.is_sub) "sub(" else "fun(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, try formatTypeIn(ctx, a, p));
            }
            try buf.append(a, ')');
            if (!f.is_sub) {
                try buf.appendSlice(a, " ");
                try buf.appendSlice(a, try formatTypeIn(ctx, a, f.returns));
            }
            break :blk buf.items;
        },
        .nominal => |sym| ctx.symbols.items[sym].name,
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk "<imported>";
            if (in.sym_id >= foreign.symbols.items.len) break :blk "<imported>";
            const name = foreign.symbols.items[in.sym_id].name;
            // Spelled the way this module names it: `other.Point`.
            for (ctx.imports) |imp| {
                if (imp.module_id == in.module_id) break :blk try std.fmt.allocPrint(a, "{s}.{s}", .{ imp.local_name, name });
            }
            break :blk name;
        },
        .parameterized_nominal => |pn| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(a, ctx.symbols.items[pn.sym].name);
            try buf.append(a, '(');
            for (pn.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, try formatTypeIn(ctx, a, arg));
            }
            try buf.append(a, ')');
            break :blk buf.items;
        },
        .type_var => |sym| ctx.symbols.items[sym].name,
    };
}

/// `T?` / `T!`, parenthesizing prefix forms: `(*T)?` is an optional
/// handle, while `*T?` would be a handle to an optional.
fn formatSuffixed(ctx: *const SemContext, a: std.mem.Allocator, inner: TypeId, suffix: u8) ![]const u8 {
    const s = try formatTypeIn(ctx, a, inner);
    const parens = switch (ctx.types.get(inner)) {
        .shared, .weak, .borrow_read, .borrow_write => true,
        else => false,
    };
    return if (parens)
        std.fmt.allocPrint(a, "({s}){c}", .{ s, suffix })
    else
        std.fmt.allocPrint(a, "{s}{c}", .{ s, suffix });
}

// =============================================================================
// IR helpers shared by the sema passes
// =============================================================================

pub fn identAt(source: []const u8, sexp: Sexp) ?[]const u8 {
    return switch (sexp) {
        .src => |s| source[s.pos..][0..s.len],
        else => null,
    };
}

pub fn srcPos(sexp: Sexp, fallback: u32) u32 {
    return if (sexp == .src) sexp.src.pos else fallback;
}

/// Head tag of a list node, or null.
pub fn headOf(sexp: Sexp) ?Tag {
    if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return null;
    return sexp.list[0].tag;
}

pub fn isHead(sexp: Sexp, tag: Tag) bool {
    return headOf(sexp) == tag;
}

/// Name leaf of a parameter: `(: name T)`, `(pre_param name T)`,
/// `(read self)`, `(write self)`, or a bare name.
pub fn paramNameNode(param: Sexp) ?Sexp {
    return switch (param) {
        .src => param,
        .list => |items| blk: {
            if (items.len < 2 or items[0] != .tag) break :blk null;
            break :blk switch (items[0].tag) {
                .@":", .@"pre_param", .@"read", .@"write", .@"default" => items[1],
                else => null,
            };
        },
        else => null,
    };
}

pub fn paramName(source: []const u8, param: Sexp) ?[]const u8 {
    return identAt(source, paramNameNode(param) orelse return null);
}

pub fn paramPos(param: Sexp, fallback: u32) u32 {
    const n = paramNameNode(param) orelse return fallback;
    return srcPos(n, fallback);
}

pub fn isBorrowedTypeNode(t: Sexp) bool {
    const h = headOf(t) orelse return false;
    return h == .borrow_read or h == .borrow_write;
}

pub const CaptureMode = enum { cap_clone, cap_weak, cap_move };

pub fn captureModeOf(cap: Sexp) ?CaptureMode {
    const h = headOf(cap) orelse return null;
    if (cap.list.len < 2) return null;
    return switch (h) {
        .@"cap_clone" => .cap_clone,
        .@"cap_weak" => .cap_weak,
        .@"cap_move" => .cap_move,
        else => null,
    };
}

pub fn captureNameNode(cap: Sexp) ?Sexp {
    _ = captureModeOf(cap) orelse return null;
    return cap.list[1];
}

/// Items of a `(captures ...)` node, or empty.
pub fn captureList(captures: Sexp) []const Sexp {
    if (!isHead(captures, .@"captures")) return &.{};
    return captures.list[1..];
}

pub fn parseIntegerLiteral(source: []const u8, sexp: Sexp) ?u64 {
    const text = identAt(source, sexp) orelse return null;
    return std.fmt.parseInt(u64, text, 0) catch null;
}

pub fn isIntLiteralText(text: []const u8) bool {
    if (text.len == 0 or text[0] < '0' or text[0] > '9') return false;
    return !isFloatLiteralText(text);
}

/// `3.14`, `.5`, `1.0e10`, `2e-3`. A hex literal's `e` is a digit.
pub fn isFloatLiteralText(text: []const u8) bool {
    if (text.len == 0) return false;
    if ((text[0] < '0' or text[0] > '9') and text[0] != '.') return false;
    if (text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) return false;
    return std.mem.indexOfAny(u8, text, ".eE") != null;
}

// =============================================================================
// Tests
// =============================================================================

test {
    _ = diag;
    _ = builtins;
    _ = decls;
    _ = exprs;
}

test "TypeStore: primitives are pre-interned and distinct" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(type_invalid, store.invalid_id);
    const ids = [_]TypeId{ store.unknown_id, store.void_id, store.bool_id, store.string_id, store.int_id, store.float_id, store.none_id, store.noreturn_id };
    for (ids, 0..) |a, i| {
        try std.testing.expect(a != type_invalid);
        for (ids[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
    try std.testing.expectEqual(store.bool_id, try store.intern(std.testing.allocator, .bool));
}

test "TypeStore: composites intern by structure" {
    const a = std.testing.allocator;
    var store = try TypeStore.init(a);
    defer store.deinit(a);
    const opt = try store.intern(a, .{ .optional = store.int_id });
    try std.testing.expectEqual(opt, try store.intern(a, .{ .optional = store.int_id }));
    try std.testing.expect(opt != try store.intern(a, .{ .fallible = store.int_id }));
    try std.testing.expect(opt != try store.intern(a, .{ .optional = opt }));

    const p1 = [_]TypeId{ store.int_id, store.int_id };
    const p2 = [_]TypeId{ store.int_id, store.int_id };
    const p3 = [_]TypeId{ store.int_id, store.bool_id };
    const f1 = try store.intern(a, .{ .function = .{ .params = &p1, .returns = store.int_id, .is_sub = false } });
    const f2 = try store.intern(a, .{ .function = .{ .params = &p2, .returns = store.int_id, .is_sub = false } });
    const f3 = try store.intern(a, .{ .function = .{ .params = &p3, .returns = store.int_id, .is_sub = false } });
    const f4 = try store.intern(a, .{ .function = .{ .params = &p1, .returns = store.int_id, .is_sub = false, .pre_mask = 1 } });
    try std.testing.expectEqual(f1, f2);
    try std.testing.expect(f1 != f3);
    try std.testing.expect(f1 != f4);
}

test "TypeStore: many distinct types stay distinct" {
    const a = std.testing.allocator;
    var store = try TypeStore.init(a);
    defer store.deinit(a);
    var prev = store.int_id;
    var ids: [200]TypeId = undefined;
    for (&ids) |*id| {
        id.* = try store.intern(a, .{ .optional = prev });
        prev = id.*;
    }
    prev = store.int_id;
    for (ids) |id| {
        try std.testing.expectEqual(id, try store.intern(a, .{ .optional = prev }));
        prev = id;
    }
}

test "SemContext: init/deinit" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), ctx.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.scopes.items.len);
}

test "check: tolerates an empty IR" {
    var ctx = try check(std.testing.allocator, "", .{ .nil = {} });
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// ---- facts table ---------------------------------------------------------------

const FactsRun = struct {
    p: parser.Parser,
    ir: Sexp,
    ctx: SemContext,
    source: []const u8,

    fn deinit(self: *FactsRun) void {
        self.ctx.deinit();
        self.p.deinit();
    }

    /// Position of the `nth` (0-based) occurrence of `needle` as a whole word.
    fn at(self: *const FactsRun, needle: []const u8, nth: usize) u32 {
        var count: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, self.source, i, needle)) |p| : (i = p + 1) {
            const before_ok = p == 0 or !isWordChar(self.source[p - 1]);
            const after = p + needle.len;
            const after_ok = after >= self.source.len or !isWordChar(self.source[after]);
            if (!before_ok or !after_ok) continue;
            if (count == nth) return @intCast(p);
            count += 1;
        }
        @panic("needle not found");
    }

    fn sym(self: *const FactsRun, needle: []const u8, nth: usize) ?SymbolId {
        return self.ctx.symbolAt(self.at(needle, nth));
    }

    fn leafType(self: *const FactsRun, needle: []const u8, nth: usize) ?TypeId {
        return self.ctx.facts.leaf_types.get(self.at(needle, nth));
    }
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn factsRun(source: []const u8) !FactsRun {
    var r: FactsRun = .{ .p = parser.Parser.init(std.testing.allocator, source), .ir = undefined, .ctx = undefined, .source = source };
    errdefer r.p.deinit();
    r.ir = try r.p.parseProgram();
    r.ctx = try check(std.testing.allocator, source, r.ir);
    for (r.ctx.diagnostics.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try std.testing.expect(!r.ctx.hasErrors());
    return r;
}

/// Find the first list node with head `tag` (depth-first).
fn findNode(node: Sexp, tag: Tag) ?Sexp {
    if (headOf(node) == tag) return node;
    if (node != .list) return null;
    for (node.list) |c| {
        if (findNode(c, tag)) |n| return n;
    }
    return null;
}

test "facts: same local name in two functions resolves per function" {
    var r = try factsRun(
        \\sub b()
        \\  s = 42
        \\  print(s)
        \\
        \\sub a()
        \\  s = "hello"
        \\  print(s)
        \\
    );
    defer r.deinit();
    const b_decl = r.sym("s", 0).?;
    const b_use = r.sym("s", 1).?;
    const a_decl = r.sym("s", 2).?;
    const a_use = r.sym("s", 3).?;
    try std.testing.expectEqual(b_decl, b_use);
    try std.testing.expectEqual(a_decl, a_use);
    try std.testing.expect(a_decl != b_decl);
    try std.testing.expectEqual(r.ctx.types.int_id, r.ctx.symbols.items[b_use].ty);
    try std.testing.expectEqual(r.ctx.types.string_id, r.ctx.symbols.items[a_use].ty);
    try std.testing.expectEqual(r.ctx.types.string_id, r.leafType("s", 3).?);
}

test "facts: reassignment names the existing binding" {
    var r = try factsRun(
        \\sub main()
        \\  x = 1
        \\  if true
        \\    x = 2
        \\  print(x)
        \\
    );
    defer r.deinit();
    const first = r.sym("x", 0).?;
    try std.testing.expectEqual(first, r.sym("x", 1).?);
    try std.testing.expectEqual(first, r.sym("x", 2).?);
}

test "facts: a shadowing binding's value reads the previous binding" {
    var r = try factsRun(
        \\sub main()
        \\  x = 1
        \\  print(x)
        \\  new x = x + 1
        \\  print(x)
        \\
    );
    defer r.deinit();
    const first = r.sym("x", 0).?;
    try std.testing.expectEqual(first, r.sym("x", 1).?);
    const second = r.sym("x", 2).?;
    try std.testing.expect(second != first);
    try std.testing.expectEqual(first, r.sym("x", 3).?);
    try std.testing.expectEqual(second, r.sym("x", 4).?);
}

test "facts: constant bindings keep their value; changed ones do not" {
    var r = try factsRun(
        \\sub main()
        \\  a = 2 + 3
        \\  b = a * 4
        \\  c = 1
        \\  c = 2
        \\  d = 7
        \\  e = !d
        \\  print(a, b, c, e)
        \\
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(?i128, 5), r.ctx.const_ints.get(r.sym("a", 0).?));
    try std.testing.expectEqual(@as(?i128, 20), r.ctx.const_ints.get(r.sym("b", 0).?));
    try std.testing.expect(r.ctx.symbols.items[r.sym("c", 0).?].flags.reassigned);
    try std.testing.expect(r.ctx.const_ints.get(r.sym("c", 0).?) == null);
    try std.testing.expect(r.ctx.const_ints.get(r.sym("d", 0).?) == null);
    try std.testing.expect(r.ctx.symbols.items[r.sym("d", 0).?].flags.written);
}

test "facts: a match covering every value without a default is exhaustive" {
    var r = try factsRun(
        \\sub main()
        \\  b = true
        \\  match b
        \\    true => print(1)
        \\    false => print(2)
        \\  n = 3
        \\  match n
        \\    1 => print(1)
        \\
    );
    defer r.deinit();
    const body = r.ir.list[1].list[4];
    try std.testing.expect(r.ctx.isExhaustive(body.list[2]));
    try std.testing.expect(!r.ctx.isExhaustive(body.list[4]));
}

test "facts: literals record the type their context gives them" {
    var r = try factsRun(
        \\sub main()
        \\  a: U8 = 7
        \\  b: I64? = 9
        \\  c = 11
        \\  print(a)
        \\  print(b ?? 0)
        \\  print(c)
        \\
    );
    defer r.deinit();
    const u8_ty = try r.ctx.intern(.{ .int = .{ .bits = 8, .signed = false } });
    const i64_ty = try r.ctx.intern(.{ .int = .{ .bits = 64, .signed = true } });
    try std.testing.expectEqual(u8_ty, r.leafType("7", 0).?);
    try std.testing.expectEqual(i64_ty, r.leafType("9", 0).?);
    try std.testing.expectEqual(r.ctx.types.int_id, r.leafType("11", 0).?);
    try std.testing.expectEqual(i64_ty, r.leafType("0", 0).?);
}

test "facts: expression nodes carry their types" {
    var r = try factsRun(
        \\fun half(n: Int) -> Float
        \\  1.5
        \\
        \\sub main()
        \\  print(half(4) + 2.0)
        \\
    );
    defer r.deinit();
    const call = findNode(r.ir.list[2], .@"call").?;
    const add = findNode(call, .@"+").?;
    try std.testing.expectEqual(r.ctx.types.float_id, r.ctx.typeOf(add).?);
    const half_call = findNode(add, .@"call").?;
    try std.testing.expectEqual(r.ctx.types.float_id, r.ctx.typeOf(half_call).?);
    try std.testing.expectEqual(r.ctx.types.void_id, r.ctx.typeOf(call).?);
    const half_sym = r.sym("half", 1).?;
    try std.testing.expectEqual(r.sym("half", 0).?, half_sym);
    try std.testing.expectEqual(SymbolKind.function, r.ctx.symbols.items[half_sym].kind);
}

test "facts: captures, parameters, and self resolve to their symbols" {
    var r = try factsRun(
        \\struct P
        \\  n: Int
        \\
        \\  fun get(?self) -> Int
        \\    self.n
        \\
        \\sub main()
        \\  s =! "hi"
        \\  f = |+s|
        \\    print(s)
        \\  f()
        \\  p = P(n: 2)
        \\  print(p.get())
        \\
    );
    defer r.deinit();
    const self_decl = r.sym("self", 0).?;
    try std.testing.expectEqual(self_decl, r.sym("self", 1).?);
    try std.testing.expectEqual(SymbolKind.param, r.ctx.symbols.items[self_decl].kind);
    const cap = r.sym("s", 1).?;
    try std.testing.expectEqual(SymbolKind.capture, r.ctx.symbols.items[cap].kind);
    try std.testing.expectEqual(cap, r.sym("s", 2).?);
    try std.testing.expect(cap != r.sym("s", 0).?);
    try std.testing.expectEqual(r.ctx.types.string_id, r.ctx.symbols.items[cap].ty);
    const f_ty = r.ctx.types.get(r.ctx.symbols.items[r.sym("f", 0).?].ty);
    try std.testing.expect(f_ty == .function);
}

test "facts: loop and pattern bindings" {
    var r = try factsRun(
        \\enum Shape
        \\  circle(radius: Int)
        \\  dot
        \\
        \\sub main()
        \\  v: Vec(Int) = Vec()
        \\  (!v).push(3)
        \\  for x in v
        \\    print(x)
        \\  s: Shape = .circle(radius: 4)
        \\  match s
        \\    .circle(r) => print(r)
        \\    .dot => print(0)
        \\
    );
    defer r.deinit();
    const x = r.sym("x", 0).?;
    try std.testing.expectEqual(x, r.sym("x", 1).?);
    try std.testing.expectEqual(r.ctx.types.int_id, r.ctx.symbols.items[x].ty);
    const rr = r.sym("r", 0).?;
    try std.testing.expectEqual(rr, r.sym("r", 1).?);
    try std.testing.expectEqual(r.ctx.types.int_id, r.ctx.symbols.items[rr].ty);
}

test "facts: scopes are keyed by the node that opens them" {
    var r = try factsRun(
        \\test "first"
        \\  a = 1
        \\  print(a)
        \\
        \\sub main()
        \\  x = "hi"
        \\  print(x)
        \\
    );
    defer r.deinit();
    const main_fn = r.ir.list[2];
    const fn_scope = r.ctx.scopeOf(main_fn).?;
    try std.testing.expectEqual(ScopeKind.function, r.ctx.scopes.items[fn_scope].kind);
    const body = main_fn.list[4];
    const body_scope = r.ctx.scopeOf(body).?;
    try std.testing.expectEqual(fn_scope, r.ctx.scopes.items[body_scope].parent.?);
    const x = r.sym("x", 0).?;
    try std.testing.expectEqual(body_scope, r.ctx.symbols.items[x].scope);
    try std.testing.expectEqual(x, r.ctx.lookup(body_scope, "x").?);
    try std.testing.expect(r.ctx.lookup(fn_scope, "a") == null);
}

test "facts: declaration names carry their function type" {
    var r = try factsRun(
        \\struct P
        \\  n: Int
        \\
        \\  fun get(?self) -> Int
        \\    self.n
        \\
        \\fun twice(x: Int) -> Int
        \\  x * 2
        \\
    );
    defer r.deinit();
    const get = r.ctx.types.get(r.leafType("get", 0).?).function;
    try std.testing.expectEqual(r.ctx.types.int_id, get.returns);
    try std.testing.expectEqual(@as(usize, 1), get.params.len);
    const twice = r.ctx.types.get(r.leafType("twice", 0).?).function;
    try std.testing.expectEqual(r.ctx.types.int_id, twice.params[0]);
}

test "facts: a capture names the binding it captures" {
    var r = try factsRun(
        \\sub main()
        \\  n = 3
        \\  f = |+n|
        \\    print(n)
        \\  f()
        \\
    );
    defer r.deinit();
    const outer = r.sym("n", 0).?;
    const cap = r.sym("n", 1).?;
    try std.testing.expect(cap != outer);
    try std.testing.expectEqual(outer, r.ctx.symbols.items[cap].origin);
}

test "facts: keyword and omitted arguments record their slots" {
    var r = try factsRun(
        \\fun scaled(n: Int, by: Int = 10, plus: Int = 0) -> Int
        \\  n * by + plus
        \\
        \\sub main()
        \\  print(scaled(1, 2, 3))
        \\  print(scaled(plus: 5, n: 4))
        \\
    );
    defer r.deinit();
    const main_fn = r.ir.list[2];
    const first = findNode(main_fn.list[4].list[1], .@"call").?;
    const inner1 = findNode(first.list[2], .@"call").?;
    try std.testing.expect(r.ctx.callSlotsOf(inner1) == null);
    const second = findNode(main_fn.list[4].list[2], .@"call").?;
    const inner2 = findNode(second.list[2], .@"call").?;
    const slots = r.ctx.callSlotsOf(inner2).?;
    try std.testing.expectEqual(@as(usize, 3), slots.len);
    try std.testing.expectEqual(@as(u32, 1), slots[0].arg);
    try std.testing.expectEqualStrings("10", r.source[slots[1].default.expr.src.pos..][0..2]);
    try std.testing.expectEqual(@as(u32, 0), slots[2].arg);
}

// ---- symbols and declarations -----------------------------------------------

test "symbols: functions at module scope, parameters in the function scope" {
    var r = try factsRun(
        \\fun add(a: Int, b: Int) -> Int
        \\  a + b
        \\
        \\pub sub main()
        \\  print(add(1, 2))
        \\
    );
    defer r.deinit();
    const add = r.ctx.lookup(1, "add").?;
    try std.testing.expectEqual(SymbolKind.function, r.ctx.symbols.items[add].kind);
    try std.testing.expect(r.ctx.lookup(1, "a") == null);
    const a = r.sym("a", 0).?;
    try std.testing.expectEqual(SymbolKind.param, r.ctx.symbols.items[a].kind);
    try std.testing.expectEqual(r.ctx.types.int_id, r.ctx.symbols.items[a].ty);
    try std.testing.expect(r.ctx.symbols.items[r.ctx.lookup(1, "main").?].flags.is_public);
    const f = r.ctx.types.get(r.ctx.symbols.items[add].ty).function;
    try std.testing.expectEqual(@as(usize, 2), f.params.len);
    try std.testing.expectEqual(r.ctx.types.int_id, f.returns);
    try std.testing.expect(!f.is_sub);
    try std.testing.expectEqualStrings("b", r.ctx.symbols.items[add].param_names.?[1]);
}

test "symbols: binding flags" {
    var r = try factsRun(
        \\struct U
        \\  n: Int
        \\
        \\fun read(u: ?U) -> Int
        \\  u.n
        \\
        \\sub show(pre k: Int)
        \\  print(k)
        \\
        \\sub main()
        \\  y =! 2
        \\  show(y)
        \\  print(read(?U(n: y)))
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ctx.symbols.items[r.sym("u", 0).?].flags.borrowed_param);
    const y = r.ctx.symbols.items[r.sym("y", 0).?];
    try std.testing.expect(y.flags.fixed);
    try std.testing.expect(y.flags.comptime_known);
    const k = r.ctx.symbols.items[r.sym("k", 0).?];
    try std.testing.expect(k.flags.is_pre);
    const show = r.ctx.types.get(r.ctx.symbols.items[r.ctx.lookup(1, "show").?].ty).function;
    try std.testing.expect(show.isPre(0));
}

test "declarations: wrapper, sized, and alias types" {
    var r = try factsRun(
        \\type UserId = U64
        \\
        \\fun a() -> Int!
        \\  1
        \\
        \\fun b(x: ?I32, y: !UserId) -> F64?
        \\  none
        \\
    );
    defer r.deinit();
    const a = r.ctx.types.get(r.ctx.symbols.items[r.ctx.lookup(1, "a").?].ty).function;
    try std.testing.expect(r.ctx.types.get(a.returns) == .fallible);
    const b = r.ctx.types.get(r.ctx.symbols.items[r.ctx.lookup(1, "b").?].ty).function;
    const x = r.ctx.types.get(b.params[0]);
    try std.testing.expect(x == .borrow_read);
    try std.testing.expectEqual(IntInfo{ .bits = 32, .signed = true }, r.ctx.types.get(x.borrow_read).int);
    const u64_ty = try r.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } });
    try std.testing.expectEqual(try r.ctx.intern(.{ .borrow_write = u64_ty }), b.params[1]);
    try std.testing.expectEqual(u64_ty, r.ctx.symbols.items[r.ctx.lookup(1, "UserId").?].ty);
    const ret = r.ctx.types.get(b.returns);
    try std.testing.expectEqual(FloatInfo{ .bits = 64 }, r.ctx.types.get(ret.optional).float);
}

test "declarations: struct fields, methods, and enum variants" {
    var r = try factsRun(
        \\struct User
        \\  name: String
        \\  age: Int
        \\
        \\  fun greet(?self) -> String
        \\    self.name
        \\
        \\enum Shape
        \\  circle(radius: Int)
        \\  origin
        \\
        \\error NetError
        \\  timeout
        \\
    );
    defer r.deinit();
    const user = r.ctx.symbols.items[r.ctx.lookup(1, "User").?].fields.?;
    try std.testing.expectEqual(@as(usize, 3), user.len);
    try std.testing.expectEqualStrings("age", user[1].name);
    try std.testing.expectEqual(r.ctx.types.int_id, user[1].ty);
    try std.testing.expect(user[2].is_method);
    try std.testing.expectEqual(MethodReceiver.read, user[2].receiver);
    const shape = r.ctx.symbols.items[r.ctx.lookup(1, "Shape").?].fields.?;
    try std.testing.expect(shape[0].is_variant);
    try std.testing.expectEqualStrings("radius", shape[0].payload.?[0].name);
    try std.testing.expect(shape[1].payload == null);
    const net = r.ctx.symbols.items[r.ctx.lookup(1, "NetError").?].fields.?;
    try std.testing.expectEqualStrings("timeout", net[0].name);
}

/// Walk every expression position of a body and report nodes sema left
/// without a fact. Used to keep the facts table complete.
const Coverage = struct {
    r: *const FactsRun,
    missing: usize = 0,

    fn expectName(self: *Coverage, leaf: Sexp) void {
        if (leaf != .src) return;
        const text = self.r.source[leaf.src.pos..][0..leaf.src.len];
        if (std.mem.eql(u8, text, "print") or std.mem.eql(u8, text, "_")) return;
        if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return;
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "none")) return;
        if (self.r.ctx.symbolOf(leaf) == null) {
            std.debug.print("no symbol for `{s}` at {d}\n", .{ text, leaf.src.pos });
            self.missing += 1;
        }
    }

    fn expectType(self: *Coverage, node: Sexp) void {
        if (self.r.ctx.typeOf(node) == null) {
            std.debug.print("no type for node at {d} ({s})\n", .{ diag.firstSrcPos(node), if (headOf(node)) |h| @tagName(h) else "leaf" });
            self.missing += 1;
        }
    }

    /// `e` is in expression position.
    fn expr(self: *Coverage, e: Sexp) void {
        switch (e) {
            .src => {
                self.expectName(e);
                if (!std.mem.eql(u8, self.r.source[e.src.pos..][0..e.src.len], "print")) self.expectType(e);
            },
            .list => |items| {
                const h = headOf(e) orelse return;
                switch (h) {
                    .@"set" => {
                        self.expectName(items[2]);
                        if (items[2] != .src) self.expr(items[2]);
                        self.expr(items[4]);
                        return;
                    },
                    .@"block" => {
                        for (items[1..]) |c| self.expr(c);
                        return;
                    },
                    .@"if", .@"while" => {
                        for (items[1..]) |c| self.expr(c);
                        return;
                    },
                    .@"as" => {
                        self.expr(items[1]);
                        self.expectName(items[2]);
                        self.expectType(items[2]);
                        return;
                    },
                    .@"for" => {
                        self.expectName(items[2]);
                        if (items[3] != .nil) {
                            self.expectName(items[3]);
                            self.expectType(items[3]);
                        }
                        self.expr(items[4]);
                        self.expr(items[5]);
                        return;
                    },
                    .@"match" => {
                        self.expr(items[1]);
                        for (items[2..]) |arm| {
                            const pat = arm.list[1];
                            if (isHead(pat, .@"variant_pattern")) for (pat.list[2..]) |b| self.expectName(b);
                            self.expr(arm.list[arm.list.len - 1]);
                        }
                        return;
                    },
                    .@"lambda" => {
                        for (captureList(items[1])) |cap| self.expectName(captureNameNode(cap).?);
                        self.expr(items[4]);
                        return;
                    },
                    .@"member" => {
                        self.expectType(e);
                        self.expr(items[1]);
                        return;
                    },
                    .@"call" => {
                        self.expectType(e);
                        if (items[1] == .src) {
                            self.expectName(items[1]);
                        } else self.expr(items[1]);
                        for (items[2..]) |a| {
                            if (isHead(a, .@"kwarg")) self.expr(a.list[2]) else self.expr(a);
                        }
                        return;
                    },
                    .@"return", .@"drop", .@"defer" => {
                        for (items[1..]) |c| self.expr(c);
                        return;
                    },
                    .@"enum_lit" => {
                        self.expectType(e);
                        return;
                    },
                    else => {
                        self.expectType(e);
                        for (items[1..]) |c| if (c != .tag) self.expr(c);
                    },
                }
            },
            else => {},
        }
    }

    fn decl(self: *Coverage, d: Sexp) void {
        const h = headOf(d) orelse return;
        switch (h) {
            .@"fun", .@"sub" => {
                if (d.list[2] == .list) for (d.list[2].list) |p| self.expectName(paramNameNode(p).?);
                self.expr(d.list[d.list.len - 1]);
            },
            .@"struct", .@"enum", .@"generic_type" => for (d.list[2..]) |m| self.decl(m),
            else => {},
        }
    }
};

test "facts: every name and expression in a program has a fact" {
    var r = try factsRun(
        \\struct Account
        \\  owner: String
        \\  balance: Int
        \\
        \\  fun doubled(?self) -> Int
        \\    self.balance * 2
        \\
        \\  sub deposit(!self, n: Int)
        \\    self.balance += n
        \\
        \\enum Shape
        \\  circle(radius: Int)
        \\  dot
        \\
        \\type Box(T)
        \\  value: T
        \\
        \\  fun get(?self) -> T
        \\    self.value
        \\
        \\fun balance_of(a: ?Account) -> Int
        \\  a.balance
        \\
        \\fun area(s: Shape) -> Int
        \\  match s
        \\    .circle(r) => r * r * 3
        \\    .dot => 0
        \\
        \\fun maybe(n: Int) -> Int?
        \\  if n > 0
        \\    n
        \\  else
        \\    none
        \\
        \\sub main()
        \\  acct = Account(owner: "ada", balance: 100)
        \\  print(balance_of(?acct))
        \\  (!acct).deposit(5)
        \\  print(acct.doubled())
        \\  moved = <acct
        \\  shared = *Account(owner: "bob", balance: 7)
        \\  other = +shared
        \\  -shared
        \\  print(other.balance)
        \\  total = 0
        \\  v: Vec(Int) = Vec()
        \\  (!v).push(3)
        \\  for x in v
        \\    total += x
        \\  print(total + moved.balance)
        \\  b: Box(Int) = Box(value: 4)
        \\  print(b.get())
        \\  print(area(.circle(radius: 2)))
        \\  print(maybe(-1) ?? 9)
        \\  c: *Cell(Int) = *Cell(value: 1)
        \\  f = |+c|
        \\    c.set(c.get() + 1)
        \\  f()
        \\  print(c.get())
        \\
    );
    defer r.deinit();
    var cov: Coverage = .{ .r = &r };
    for (r.ir.list[1..]) |d| cov.decl(d);
    try std.testing.expectEqual(@as(usize, 0), cov.missing);
}

test "facts: optional bindings, index bindings, defaults, and shadows have facts" {
    var r = try factsRun(
        \\fun scaled(n: Int, by: Int = 10) -> Int
        \\  n * by
        \\
        \\sub main()
        \\  m: Int? = 4
        \\  if m as v
        \\    print(v, scaled(v))
        \\  xs = [1, 2]
        \\  for x, i in xs
        \\    print(x + i)
        \\  w: Vec(Int) = Vec()
        \\  while (!w).pop() as y
        \\    print(y)
        \\  k = 1
        \\  new k = k + 1
        \\  print(k)
        \\
    );
    defer r.deinit();
    var cov: Coverage = .{ .r = &r };
    for (r.ir.list[1..]) |d| cov.decl(d);
    try std.testing.expectEqual(@as(usize, 0), cov.missing);
    try std.testing.expectEqual(r.ctx.types.int_id, r.leafType("v", 0).?);
    try std.testing.expectEqual(r.ctx.types.int_id, r.leafType("i", 0).?);
}
