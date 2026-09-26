//! Semantic analysis: names, types, and expression checking.
//!
//! `check` runs these steps over the normalized IR and returns
//! a `SemContext`, which every later pass (ownership, emit) reads:
//!
//!   1. builtins     `resolve.zig`    Cell, Vec, Signal
//!   2. symbols      `resolve.zig`    every declaration gets a Symbol in a
//!                                    Scope; scopes are keyed by the IR node
//!                                    that opens them
//!   3. declarations `resolve.zig`    type expressions become TypeIds;
//!                                    signatures, fields, variants, aliases
//!   4. contents     `sema.zig`       what each declared type's values hold
//!                                    (drop glue, a Cell, plain data), and
//!                                    types that contain themselves
//!   5. validation   `resolve.zig`    the declaration checks that need 4,
//!                                    and the public surface of the module
//!   6. expressions  `typecheck.zig`  bodies are type-checked; every
//!                                    expression's type is recorded;
//!                                    fallibility and `raw` are checked;
//!                   `sema.zig`       then every local must be read
//!   7. generics     `sema.zig`,      the instances generic bodies reach,
//!                   `typecheck.zig`  and each instance's requirements
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
//!   ctx.instanceOf(node) -> ?Instance  for a bracket list (`index` or
//!                                      `inst`) of compile-time arguments
//!                                      rather than an index: the generic
//!                                      type's instance, or a function's
//!                                      compile-time arguments
//!   ctx.genericCallOf(call) -> ?GenericCall  for a call with compile-time
//!                                      arguments: its type arguments,
//!                                      inferred or given in brackets
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
//! node id the parser gave them (`List.id`), which the Parser wrapper's
//! rewrites preserve. A node that sema never reached (dead code after an
//! error, type positions) has no entry; callers treat `null` as "no
//! information".
//!
//! Types are interned in `TypeStore`, so two TypeIds are the same type
//! iff they are equal. `unknown` and `invalid` are poison: they appear
//! only after a diagnostic has been reported and are compatible with
//! everything so one mistake doesn't cascade.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
pub const diag = @import("diag.zig");
const resolve = @import("resolve.zig");
const typecheck = @import("typecheck.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
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

/// The first scope a module's check opens.
pub const module_scope: ScopeId = 1;

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
    /// Its compile-time parameters, in order: a value parameter's type
    /// (`Mode` for `fun check[mode: Mode](n: Int)`), and a type
    /// parameter itself (the `type_var` `T` for `fun max[T]`), which
    /// makes the function generic. A call fills them in brackets
    /// (`check[.strict](5)`, `max[Int](1, 2)`), or infers the types;
    /// `params` are the run-time ones.
    ct_params: []const TypeId = &.{},
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
    /// Any error value: what `catch |err|` binds. Functions do not
    /// declare which errors they fail with, so the error a failed call
    /// produced may belong to any error set.
    any_error,

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
    /// A generic type applied to arguments: `Box[Int]`.
    parameterized_nominal: ParamNominal,
    /// A generic parameter (`T` inside `type Box[T]`).
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

/// Module id -> the module's context.
pub const ModuleMap = std.AutoHashMapUnmanaged(u32, *SemContext);
const no_modules: ModuleMap = .empty;

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
    any_error_id: TypeId = type_invalid,

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
        s.any_error_id = try s.intern(allocator, .any_error);
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

    /// The id of `ty` if it is interned.
    pub fn find(self: *const TypeStore, ty: Type) ?TypeId {
        return self.map.getKeyAdapted(ty, TypeContext{ .items = self.items.items });
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

    /// By structure: the contents of the slices inside, not their addresses.
    fn hashType(t: Type) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&h, t, .Deep);
        return h.final();
    }

    fn typeEqual(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .invalid, .unknown, .void, .bool, .string, .int_literal, .float_literal, .none_literal, .noreturn, .any_error => true,
            .function => |af| af.is_sub == b.function.is_sub and
                af.returns == b.function.returns and
                std.mem.eql(TypeId, af.ct_params, b.function.ct_params) and
                std.mem.eql(TypeId, af.params, b.function.params),
            .parameterized_nominal => |x| x.sym == b.parameterized_nominal.sym and
                std.mem.eql(TypeId, x.args, b.parameterized_nominal.args),
            // The rest hold ids and numbers only.
            inline else => |x, tag| std.meta.eql(x, @field(b, @tagName(tag))),
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
    /// `type Box[T]` / `enum Option[T]` and the built-in generics.
    generic_type,
    /// `T` in `type Box[T]`, detached: not in any scope, reached through
    /// the owning type's `type_params`. Also `T` in `fun max[T]`, bound
    /// in the function's scope.
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
    /// Value known at compile time: a compile-time parameter
    /// (`fun f[n: Int]`), or a `=!` binding
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
    /// An `error` declaration: its variants are error values.
    error_set: bool = false,
    _: u8 = 0,
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
    /// A data field's default value (`name: T = literal`).
    default: ?Sexp = null,
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
    /// Members of a nominal or generic type; null for other kinds.
    fields: ?[]const Field = null,
    /// A nominal or generic type: what its values hold.
    contents: Contents = .{},
    /// Generic parameters of a generic type, in declaration order.
    type_params: ?[]const SymbolId = null,
    /// Parameter names of a function, for keyword arguments.
    param_names: ?[]const []const u8 = null,
    /// Default values of a function's parameters (null where none).
    param_defaults: ?[]const ?Sexp = null,
    /// A capture: the enclosing binding it captures.
    origin: SymbolId = symbol_invalid,
    /// The previous symbol of the same name in the same scope, if any.
    prev_in_scope: SymbolId = symbol_invalid,
};

pub const ScopeKind = enum { module, function, lambda, block };

pub const Scope = struct {
    parent: ?ScopeId,
    /// In declaration order. Add with `SemContext.addToScope`.
    symbols: std.ArrayListUnmanaged(SymbolId) = .empty,
    /// Name -> the latest symbol of that name; earlier ones are chained
    /// through `Symbol.prev_in_scope`.
    by_name: std.StringHashMapUnmanaged(SymbolId) = .empty,
    kind: ScopeKind = .block,
};

pub const Diagnostic = diag.Diagnostic;

// =============================================================================
// Facts
// =============================================================================

/// Identity of an IR list node: its node id.
pub const NodeKey = parser.NodeId;

/// The key of a list node the parser built; null for a leaf or `_`.
fn nodeKey(node: Sexp) ?NodeKey {
    if (node != .list or node.list.id == 0) return null;
    return node.list.id;
}

/// The key of a node a fact is recorded for: a node the parser built.
fn recordKey(node: Sexp) NodeKey {
    return nodeKey(node) orelse std.debug.panic("sema recorded a fact for a node without a node id: {s}", .{if (node.kind()) |k| @tagName(k) else @tagName(node)});
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
    /// Bracket-list node (`index` / `inst`) -> what it instantiates,
    /// for one that gives compile-time arguments rather than an index.
    instances: std.AutoHashMapUnmanaged(NodeKey, Instance) = .empty,
    /// Call of a generic function (or a statement `f[Int]` that is the
    /// call) -> its type arguments.
    generic_calls: std.AutoHashMapUnmanaged(NodeKey, GenericCall) = .empty,
    /// Positions of names assigned to (`x = e`, `x <- e`, `x += e` after
    /// `x` is declared): a use there writes the binding, not reads it.
    writes: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *Facts, allocator: std.mem.Allocator) void {
        self.writes.deinit(allocator);
        self.names.deinit(allocator);
        self.leaf_types.deinit(allocator);
        self.node_types.deinit(allocator);
        self.scopes.deinit(allocator);
        self.call_slots.deinit(allocator);
        self.exhaustive.deinit(allocator);
        self.instances.deinit(allocator);
        self.generic_calls.deinit(allocator);
    }
};

/// What a bracket list `x[...]` that is not an index instantiates. The
/// parser builds `(index x a)` for one argument and `(inst x a b ...)`
/// for more; sema decides by what `x` names (a generic type or a
/// function with compile-time parameters instantiates, anything else
/// is indexed) and records the instances here.
pub const Instance = union(enum) {
    /// `Vec[Int]`, `Pair[Int, String]`: the generic type's instance.
    type: TypeId,
    /// `check[.strict]`, `p.scale[2]`: a function's compile-time
    /// arguments.
    function: FunctionInstance,
};

pub const FunctionInstance = struct {
    /// The bracket list is itself the call: a statement `show[3]`, which
    /// passes no run-time arguments.
    call: bool = false,
};

/// The compile-time arguments a call passes, one per compile-time
/// parameter in order: a type parameter's type, inferred or given, and
/// `type_invalid` at a value parameter, whose value is in the call's
/// bracket list.
pub const GenericCall = struct {
    type_args: []const TypeId,
    /// The call passes a method's receiver as its first argument
    /// (`Point.scale[2](p)`); Zig takes the receiver first, then the
    /// compile-time arguments.
    receiver_arg: bool = false,
};

/// A generic function at particular type arguments: `params[i]` is
/// `args[i]`. A method's instance starts with its type's parameters,
/// bound to the receiver's type arguments; its own are the last `own`.
pub const FnInstance = struct {
    /// The function, for messages.
    name: []const u8,
    params: []const SymbolId,
    args: []const TypeId,
    own: u32,

    /// Its own type parameters and their arguments.
    pub fn ownParams(self: FnInstance) []const SymbolId {
        return self.params[self.params.len - self.own ..];
    }

    pub fn ownArgs(self: FnInstance) []const TypeId {
        return self.args[self.args.len - self.own ..];
    }

    pub fn subst(self: FnInstance) TypeSubst {
        return .{ .params = self.params, .args = self.args };
    }

    const Context = struct {
        pub fn hash(_: Context, k: FnInstance) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.sliceAsBytes(k.params));
            h.update(std.mem.sliceAsBytes(k.args));
            return h.final();
        }
        pub fn eql(_: Context, a: FnInstance, b: FnInstance) bool {
            return std.mem.eql(SymbolId, a.params, b.params) and std.mem.eql(TypeId, a.args, b.args);
        }
    };
};

/// The arguments of a bracket list: the index of `(index x i)`, or every
/// argument of `(inst x a b ...)`.
pub fn bracketArgs(node: Sexp) []const Sexp {
    if (node.isKind(.inst)) return ir.Inst.args(node);
    return node.items()[ir.slot(.index, .index)..][0..1];
}

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
pub const Requirement = union(enum) {
    numeric,
    ordered,
    equatable,
    integer,
    /// A signed integer or a float: the body negates the value.
    signed,
    /// A float: the body combines the value with a float literal.
    float,
    /// A type that holds this integer exactly: the body combines the
    /// value with an integer literal.
    fits: i128,
    /// An integer wider than this many bits: the body shifts the value
    /// by a constant amount.
    shift: i128,
    /// Owns no resource: the body copies, discards, or leaves a
    /// temporary of the parameter's value.
    plain,

    pub fn describe(self: Requirement) []const u8 {
        return switch (self) {
            .numeric => "arithmetic",
            .ordered => "ordering comparison",
            .equatable => "`==` / `!=`",
            .integer => "integer operators",
            .signed => "negation",
            .float => "a float literal",
            .fits => "an integer literal",
            .shift => "a constant shift",
            .plain => "a value that owns no resource",
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
    /// The parser that built the module's tree, for node spans; null for
    /// a tree checked without one (spans then come from the leaves).
    parser: ?*const parser.Parser = null,
    /// Owns symbol names, messages, and every slice inside a Type.
    arena: std.heap.ArenaAllocator,

    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    /// Scope 1 is the module scope.
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    types: TypeStore,
    /// Facts of each interned type, by TypeId.
    type_info: std.ArrayListUnmanaged(TypeInfo) = .empty,
    /// Every declared type's `contents` is known, and so are the
    /// ownership facts in `type_info`.
    contents_ready: bool = false,
    /// Checks on types spelled in declarations that wait for
    /// `contents_ready`.
    deferred_checks: std.ArrayListUnmanaged(resolve.DeferredCheck) = .empty,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    facts: Facts = .{},

    cell_sym_id: SymbolId = symbol_invalid,
    vec_sym_id: SymbolId = symbol_invalid,
    signal_sym_id: SymbolId = symbol_invalid,

    /// Assigned by the module graph.
    module_id: u32 = 0,
    /// The program's root module, whose `main` is the entry point.
    is_root: bool = false,
    /// The name other modules `use`, and of the module's emitted file.
    name: []const u8 = "",
    imports: []const ImportEntry = &.{},
    /// `use NAME` symbol -> origin module id.
    module_refs: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    /// Every module of the program by id, shared by their contexts: a
    /// type from another module names its origin by id.
    foreign_semas: *const ModuleMap = &no_modules,
    /// The ids of the modules this one reaches through its imports.
    reach: std.DynamicBitSetUnmanaged = .{},

    /// Type alias symbol -> its target type expression, resolved on
    /// first use (aliases may be used before they are declared).
    alias_targets: std.AutoHashMapUnmanaged(SymbolId, Sexp) = .empty,
    /// Aliases currently being resolved, to report cycles.
    alias_in_progress: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Operations generic bodies apply to their type parameters.
    generic_requirements: std.ArrayListUnmanaged(GenericRequirement) = .empty,
    /// Instantiated generic type -> position of its first spelling.
    instantiation_sites: std.AutoHashMapUnmanaged(TypeId, u32) = .empty,
    /// Instances of user generics spelled with type parameters, inside
    /// generic declarations (`Opt[T]` in `Box[T]`'s methods). See
    /// `expandInstantiations`.
    generic_uses: std.ArrayListUnmanaged(TypeId) = .empty,
    /// The instances of generic functions the module's calls make, each
    /// with the position of its first call, in the order found.
    fn_instances: std.ArrayListUnmanaged(struct { inst: FnInstance, site: u32 }) = .empty,
    /// Every instance in `fn_instances` and `generic_fn_uses`.
    fn_instance_set: std.HashMapUnmanaged(FnInstance, void, FnInstance.Context, std.hash_map.default_max_load_percentage) = .empty,
    /// Instances of generic functions called with type parameters, inside
    /// generic bodies (`max[T]` in `fun top[T]`); expanded like
    /// `generic_uses`.
    generic_fn_uses: std.ArrayListUnmanaged(FnInstance) = .empty,
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
        try ctx.syncTypeInfo();
        return ctx;
    }

    pub fn deinit(self: *SemContext) void {
        for (self.scopes.items) |*s| {
            s.symbols.deinit(self.allocator);
            s.by_name.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.type_info.deinit(self.allocator);
        self.deferred_checks.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.module_refs.deinit(self.allocator);
        self.reach.deinit(self.allocator);
        self.alias_targets.deinit(self.allocator);
        self.alias_in_progress.deinit(self.allocator);
        self.generic_requirements.deinit(self.allocator);
        self.instantiation_sites.deinit(self.allocator);
        self.generic_uses.deinit(self.allocator);
        self.fn_instances.deinit(self.allocator);
        self.fn_instance_set.deinit(self.allocator);
        self.generic_fn_uses.deinit(self.allocator);
        self.const_ints.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const SemContext) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    /// The source range of an IR node: its span from the parser, which
    /// includes keywords and sigils (`return x`, `<p`).
    pub fn span(self: *const SemContext, node: Sexp) diag.Span {
        if (self.parser) |p| return p.span(node);
        return diag.leafSpan(node);
    }

    /// Where a node starts in the source.
    pub fn startOf(self: *const SemContext, node: Sexp) u32 {
        return self.span(node).start;
    }

    pub fn err(self: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.report(.@"error", .{ .start = pos, .end = pos }, fmt, args);
    }

    pub fn note(self: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.report(.note, .{ .start = pos, .end = pos }, fmt, args);
    }

    /// An error about `node`, reported at its span.
    pub fn errAt(self: *SemContext, node: Sexp, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.report(.@"error", self.span(node), fmt, args);
    }

    pub fn noteAt(self: *SemContext, node: Sexp, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.report(.note, self.span(node), fmt, args);
    }

    fn report(self: *SemContext, severity: diag.Severity, at: diag.Span, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        // The same finding reached twice is reported once.
        if (severity == .@"error") for (self.diagnostics.items) |d| {
            if (d.severity == .@"error" and d.pos == at.start and std.mem.eql(u8, d.message, msg)) return;
        };
        try self.diagnostics.append(self.allocator, .{ .severity = severity, .pos = at.start, .end = at.end, .message = msg });
    }

    pub fn pushScopeKind(self: *SemContext, parent: ScopeId, kind: ScopeKind) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .parent = if (parent == scope_invalid) null else parent,
            .kind = kind,
        });
        return id;
    }

    /// Add a symbol to the table, in no scope (see `addToScope`).
    pub fn addSymbol(self: *SemContext, sym: Symbol) std.mem.Allocator.Error!SymbolId {
        const id: SymbolId = @intCast(self.symbols.items.len);
        try self.symbols.append(self.allocator, sym);
        return id;
    }

    /// Declare the symbol `id` in `scope_id`, after its earlier ones.
    pub fn addToScope(self: *SemContext, scope_id: ScopeId, id: SymbolId) std.mem.Allocator.Error!void {
        const scope = &self.scopes.items[scope_id];
        try scope.symbols.append(self.allocator, id);
        const latest = try scope.by_name.getOrPut(self.allocator, self.symbols.items[id].name);
        self.symbols.items[id].prev_in_scope = if (latest.found_existing) latest.value_ptr.* else symbol_invalid;
        latest.value_ptr.* = id;
    }

    /// The latest symbol named `name` declared directly in `scope_id`.
    pub fn lookupInScopeOnly(self: *const SemContext, scope_id: ScopeId, name: []const u8) ?SymbolId {
        if (scope_id == scope_invalid or scope_id >= self.scopes.items.len) return null;
        return self.scopes.items[scope_id].by_name.get(name);
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
            .list => self.facts.node_types.get(nodeKey(node) orelse return null),
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

    /// What a bracket list instantiates; null for an index (or a node
    /// sema never reached).
    pub fn instanceOf(self: *const SemContext, node: Sexp) ?Instance {
        if (!rig.isBracketList(node)) return null;
        return self.facts.instances.get(nodeKey(node) orelse return null);
    }

    /// A call's callee without its compile-time arguments: `f` for
    /// `f[3](x)`, `p.scale` for `p.scale[2]()`, `Box` for
    /// `Box[Int](v: 3)` (whose instance `instanceOf` the bracket list
    /// gives).
    pub fn calleeOf(self: *const SemContext, call: Sexp) Sexp {
        const callee = ir.Call.callee(call);
        if (self.instanceOf(callee) == null) return callee;
        return ir.get(callee, .object);
    }

    /// The compile-time arguments of a call that has them (or of a
    /// statement `f[Int]`, which is the call); null for any other.
    pub fn genericCallOf(self: *const SemContext, node: Sexp) ?GenericCall {
        return self.facts.generic_calls.get(nodeKey(node) orelse return null);
    }

    /// The compile-time arguments a call passes in brackets: `.strict`
    /// in `check[.strict](5)`; empty for a call without.
    pub fn ctArgsOf(self: *const SemContext, call: Sexp) []const Sexp {
        const callee = ir.Call.callee(call);
        const inst = self.instanceOf(callee) orelse return &.{};
        return if (inst == .function) bracketArgs(callee) else &.{};
    }

    // ---- facts: recording (sema passes only) ----------------------------

    pub fn recordName(self: *SemContext, node: Sexp, sym: SymbolId) !void {
        if (node != .src or sym == symbol_invalid) return;
        try self.facts.names.put(self.allocator, node.src.pos, sym);
    }

    pub fn recordType(self: *SemContext, node: Sexp, ty: TypeId) !void {
        switch (node) {
            .src => |s| try self.facts.leaf_types.put(self.allocator, s.pos, ty),
            .list => try self.facts.node_types.put(self.allocator, recordKey(node), ty),
            else => {},
        }
    }

    pub fn recordScope(self: *SemContext, node: Sexp, scope: ScopeId) !void {
        try self.facts.scopes.put(self.allocator, recordKey(node), scope);
    }

    pub fn recordExhaustive(self: *SemContext, match: Sexp) !void {
        try self.facts.exhaustive.put(self.allocator, recordKey(match), {});
    }

    pub fn recordCallSlots(self: *SemContext, call: Sexp, slots: []const ArgSlot) !void {
        try self.facts.call_slots.put(self.allocator, recordKey(call), slots);
    }

    pub fn recordInstance(self: *SemContext, node: Sexp, inst: Instance) !void {
        try self.facts.instances.put(self.allocator, recordKey(node), inst);
    }

    pub fn recordGenericCall(self: *SemContext, node: Sexp, call: GenericCall) !void {
        try self.facts.generic_calls.put(self.allocator, recordKey(node), call);
    }

    /// Record an instance of a generic function a call makes at `site`:
    /// a concrete one, checked against its body's requirements, or, from
    /// a call inside a generic body, one over type parameters, which
    /// each instance of that body makes concrete
    /// (`expandInstantiations`). Whether it was new.
    pub fn recordFnInstance(self: *SemContext, inst: FnInstance, site: u32) !bool {
        if (self.fn_instance_set.contains(inst)) return false;
        const owned = try self.ownFnInstance(inst);
        try self.fn_instance_set.put(self.allocator, owned, {});
        for (inst.args) |a| if (self.typeInfo(a).has_type_var) {
            try self.generic_fn_uses.append(self.allocator, owned);
            return true;
        };
        try self.fn_instances.append(self.allocator, .{ .inst = owned, .site = site });
        return true;
    }

    fn ownFnInstance(self: *SemContext, inst: FnInstance) !FnInstance {
        const a = self.arena.allocator();
        return .{ .name = inst.name, .params = try a.dupe(SymbolId, inst.params), .args = try a.dupe(TypeId, inst.args), .own = inst.own };
    }

    pub fn intern(self: *SemContext, ty: Type) std.mem.Allocator.Error!TypeId {
        const id = try self.types.intern(self.allocator, ty);
        try self.syncTypeInfo();
        return id;
    }

    /// Record the facts of every type interned since the last call.
    fn syncTypeInfo(self: *SemContext) std.mem.Allocator.Error!void {
        while (self.type_info.items.len < self.types.items.items.len) {
            const info = try computeTypeInfo(self, @intCast(self.type_info.items.len));
            try self.type_info.append(self.allocator, info);
        }
    }

    pub fn typeInfo(self: *const SemContext, ty: TypeId) TypeInfo {
        return if (ty < self.type_info.items.len) self.type_info.items[ty] else .{};
    }

    /// `typeInfo` for the ownership facts, known once declarations are
    /// resolved.
    fn holds(self: *const SemContext, ty: TypeId) TypeInfo {
        std.debug.assert(self.contents_ready);
        return self.typeInfo(ty);
    }

    /// `intern` for a type whose slices (function parameters, generic
    /// arguments) may be temporary: they are copied into the arena only
    /// when the type is new.
    pub fn internCopy(self: *SemContext, ty: Type) std.mem.Allocator.Error!TypeId {
        if (self.types.find(ty)) |id| return id;
        var owned = ty;
        switch (owned) {
            .function => |*f| {
                f.params = try self.dupeIds(f.params);
                f.ct_params = try self.dupeIds(f.ct_params);
            },
            .parameterized_nominal => |*pn| pn.args = try self.dupeIds(pn.args),
            else => {},
        }
        return self.intern(owned);
    }

    pub fn dupeIds(self: *SemContext, ids: []const TypeId) std.mem.Allocator.Error![]const TypeId {
        return self.arena.allocator().dupe(TypeId, ids);
    }
};

// =============================================================================
// Entry points
// =============================================================================

pub const CheckOptions = struct {
    /// The parser that built the tree, for node spans in diagnostics.
    parser: ?*const parser.Parser = null,
    /// What the module's `use` declarations resolve to.
    imports: []const ImportEntry = &.{},
    /// Every module loaded so far, by id; the imports and the modules
    /// they reach in turn are among them.
    modules: *const ModuleMap = &no_modules,
    name: []const u8 = "",
    /// Assigned by the module graph.
    module_id: u32 = 0,
    /// The program's root module, whose `main` is the entry point.
    is_root: bool = false,
};

/// Check one module.
pub fn check(allocator: std.mem.Allocator, source: []const u8, tree: Sexp, opts: CheckOptions) !SemContext {
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    ctx.parser = opts.parser;
    ctx.module_id = opts.module_id;
    ctx.is_root = opts.is_root;
    ctx.name = opts.name;
    // The caller's slice is temporary; the emitter reads the imports later.
    ctx.imports = try ctx.arena.allocator().dupe(ImportEntry, opts.imports);
    ctx.foreign_semas = opts.modules;
    // Each import was checked first, so its reach is known and no longer
    // than this one.
    ctx.reach = try .initEmpty(allocator, opts.modules.count() + 1);
    for (opts.imports) |imp| {
        ctx.reach.set(imp.module_id);
        const theirs = imp.sema.reach;
        for (0..(theirs.bit_length + @bitSizeOf(usize) - 1) / @bitSizeOf(usize)) |i| ctx.reach.masks[i] |= theirs.masks[i];
    }

    const scope = try ctx.pushScopeKind(scope_invalid, .module);
    std.debug.assert(scope == module_scope);
    try resolve.registerBuiltins(&ctx, module_scope);
    try resolve.resolveSymbols(&ctx, tree, module_scope);
    try resolve.resolveDeclarations(&ctx, tree, module_scope);
    try computeContents(&ctx);
    try checkInfiniteTypes(&ctx);
    try resolve.checkDeclarations(&ctx);
    try typecheck.checkModule(&ctx, tree, module_scope);
    try checkUnreadLocals(&ctx);
    try expandInstantiations(&ctx);
    try typecheck.checkGenericInstantiations(&ctx);
    return ctx;
}

/// A local binding must be read: a name that is only ever assigned is
/// most often a typo for another. Any use other than being assigned is a
/// read, and so is a closure capturing it. A value with drop glue is
/// read by its own release (a guard held to the end of its scope), and
/// `_` names nothing. Parameters and module constants are exempt.
fn checkUnreadLocals(ctx: *SemContext) std.mem.Allocator.Error!void {
    var read: std.DynamicBitSetUnmanaged = try .initEmpty(ctx.allocator, ctx.symbols.items.len);
    defer read.deinit(ctx.allocator);
    var names = ctx.facts.names.iterator();
    while (names.next()) |e| {
        const sym = ctx.symbols.items[e.value_ptr.*];
        if (sym.decl_pos != e.key_ptr.* and !ctx.facts.writes.contains(e.key_ptr.*)) read.set(e.value_ptr.*);
    }
    for (ctx.symbols.items) |sym| {
        var origin = sym.origin;
        if (sym.kind != .capture) continue;
        while (origin != symbol_invalid) : (origin = ctx.symbols.items[origin].origin) read.set(origin);
    }
    for (ctx.symbols.items, 0..) |sym, id| {
        if (sym.kind != .local or sym.scope == module_scope or read.isSet(id)) continue;
        if (std.mem.eql(u8, sym.name, "_") or sym.decl_pos == builtin_decl_pos) continue;
        switch (ctx.types.get(sym.ty)) {
            .invalid, .unknown => continue,
            else => {},
        }
        if (typeHasDropGlue(ctx, sym.ty) or maybeDropGlue(ctx, sym.ty)) continue;
        if (sym.flags.pattern_bound) {
            try ctx.err(sym.decl_pos, "`{s}` is bound but never read; name it `_` to ignore the value", .{sym.name});
        } else {
            try ctx.err(sym.decl_pos, "`{s}` is assigned but never read; use it, or discard the value with `_ = ...`", .{sym.name});
        }
    }
}

/// Add the instances a program reaches through generic bodies: when
/// `Box[*B]` is spelled and `Box[T]`'s methods use `Opt[T]`, `Opt[*B]` is
/// instantiated too, at the same site, and so is `max[*B]` when they
/// call `max[T]`; each instance of a generic function does the same for
/// its body. The requirement checks then see every instantiation, and a
/// built-in generic reached this way (`Vec[T]` in `Stack[T]`) has its
/// element rules checked for the argument.
fn expandInstantiations(ctx: *SemContext) std.mem.Allocator.Error!void {
    if (ctx.generic_uses.items.len == 0 and ctx.generic_fn_uses.items.len == 0) return;
    const Item = struct { subst: TypeSubst, site: u32, root: InstanceRoot };
    var work: std.ArrayListUnmanaged(Item) = .empty;
    defer work.deinit(ctx.allocator);
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |e| {
        const item = typeItem(ctx, e.key_ptr.*) orelse continue;
        try work.append(ctx.allocator, .{ .subst = item, .site = e.value_ptr.*, .root = .{ .type = e.key_ptr.* } });
    }
    for (ctx.fn_instances.items) |f| try work.append(ctx.allocator, .{ .subst = f.inst.subst(), .site = f.site, .root = .{ .func = f.inst } });
    while (work.pop()) |item| {
        for (ctx.generic_fn_uses.items) |use| {
            if (!argsUseParams(ctx, use.args, item.subst.params)) continue;
            const args = try ctx.arena.allocator().alloc(TypeId, use.args.len);
            var deepest: u8 = 0;
            for (use.args, args) |a, *out| {
                out.* = try substituteType(ctx, a, item.subst);
                deepest = @max(deepest, ctx.typeInfo(out.*).depth);
            }
            if (argsHaveTypeVar(ctx, args)) continue;
            // A generic function that calls itself with its parameters
            // nested deeper (`f[Box[T]]` in `f[T]`), or a generic type
            // whose methods do so with its own instances, would expand
            // forever.
            if (deepest > max_instance_depth) {
                const why = if (item.root == .func) "a generic function cannot call itself with its own type parameters nested deeper" else "a generic type's body cannot nest itself in its own type arguments";
                try ctx.err(item.site, "`{s}` leads to ever deeper instances of generic functions (through `{s}`); {s}", .{ try rootName(ctx, item.root), try formatFnInstance(ctx, use), why });
                return;
            }
            const concrete: FnInstance = .{ .name = use.name, .params = use.params, .args = args, .own = use.own };
            if (!try ctx.recordFnInstance(concrete, item.site)) continue;
            try work.append(ctx.allocator, .{ .subst = concrete.subst(), .site = item.site, .root = item.root });
        }
        for (ctx.generic_uses.items) |use| {
            if (!usesParams(ctx, use, item.subst.params)) continue;
            const concrete = try substituteType(ctx, use, item.subst);
            const info = ctx.typeInfo(concrete);
            if (info.has_type_var) continue;
            // A generic whose body uses ever-deeper instances of itself
            // (`Box[T]` using `Box[Box[T]]`) would expand forever.
            if (info.depth > max_instance_depth) {
                try ctx.err(item.site, "`{s}` leads to ever deeper instances of generic types (through `{s}`); a generic type's body cannot nest itself in its own type arguments", .{ try rootName(ctx, item.root), try formatType(ctx, use) });
                return;
            }
            const gop = try ctx.instantiation_sites.getOrPut(ctx.allocator, concrete);
            if (gop.found_existing) continue;
            gop.value_ptr.* = item.site;
            const inst = ctx.types.get(concrete).parameterized_nominal;
            if (ctx.symbols.items[inst.sym].decl_pos == builtin_decl_pos) {
                if (try resolve.builtinElementError(ctx, inst.sym, inst.args)) |msg| {
                    try ctx.err(item.site, "`{s}` instantiates `{s}`: {s}", .{ try rootName(ctx, item.root), try formatType(ctx, concrete), msg });
                }
                continue;
            }
            try work.append(ctx.allocator, .{ .subst = typeItem(ctx, concrete).?, .site = item.site, .root = item.root });
        }
    }
}

/// An instance of a generic type or function, as the diagnostics about
/// it name it; also the one a program spells, from which
/// `expandInstantiations` reached another.
pub const InstanceRoot = union(enum) { type: TypeId, func: FnInstance };

pub fn rootName(ctx: *SemContext, root: InstanceRoot) std.mem.Allocator.Error![]const u8 {
    return switch (root) {
        .type => |t| formatType(ctx, t),
        .func => |f| formatFnInstance(ctx, f),
    };
}

/// A generic type's instance as a substitution of its parameters.
fn typeItem(ctx: *const SemContext, ty: TypeId) ?TypeSubst {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    return .{ .params = ctx.symbols.items[pn.sym].type_params orelse return null, .args = pn.args };
}

fn argsUseParams(ctx: *const SemContext, args: []const TypeId, params: []const SymbolId) bool {
    for (args) |a| if (usesParams(ctx, a, params)) return true;
    return false;
}

fn argsHaveTypeVar(ctx: *const SemContext, args: []const TypeId) bool {
    for (args) |a| if (ctx.typeInfo(a).has_type_var) return true;
    return false;
}

/// A generic function's instance as a call spells it: `max[Int]`, with
/// its own type arguments.
pub fn formatFnInstance(ctx: *SemContext, inst: FnInstance) std.mem.Allocator.Error![]const u8 {
    return formatFnInstanceIn(ctx, ctx.arena.allocator(), inst);
}

/// `formatFnInstance` with a caller-chosen allocator.
pub fn formatFnInstanceIn(ctx: *const SemContext, a: std.mem.Allocator, inst: FnInstance) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}[{s}]", .{ inst.name, try formatTypeList(ctx, a, inst.ownArgs()) });
}

const max_instance_depth = 24;

/// Whether `ty` mentions any of `params`.
fn usesParams(ctx: *const SemContext, ty: TypeId, params: []const SymbolId) bool {
    if (!ctx.typeInfo(ty).has_type_var) return false;
    if (ctx.types.get(ty) == .type_var) return std.mem.indexOfScalar(SymbolId, params, ctx.types.get(ty).type_var) != null;
    var it = typeChildren(ctx, ty);
    while (it.next()) |c| if (usesParams(ctx, c, params)) return true;
    return false;
}

// =============================================================================
// What values hold
//
// The ownership rules ask of a type whether its values own a resource
// (drop glue), hold a `Cell` inline, or are plain data. The answers come
// from the declared types' fields, so they are computed once every
// declaration is resolved: first for each nominal and generic type
// (`Symbol.contents`), then for each interned type (`TypeInfo`), from
// the answers for the types it is built from.
// =============================================================================

/// What the values of a nominal or generic type hold, from its data
/// fields and variant payloads (`computeContents`).
pub const Contents = struct {
    state: enum { todo, busy, done } = .todo,
    /// Needs its destructor run whatever its type arguments: a user
    /// `drop`, or a field that owns a resource.
    glue: bool = false,
    /// Holds a `Cell` inline, directly or through any argument of a
    /// generic instance it holds.
    cell: bool = false,
    /// Owns nothing and holds no borrow. A type parameter held by value
    /// counts as plain here; each instance checks its arguments.
    plain: bool = false,
    /// A generic type: which of its parameters it holds by value.
    held: []const bool = &.{},
    /// Holds a borrow, or a write borrow (see `Borrows`).
    borrows: Borrows = .{},
};

/// Whether values hold a borrow (`?T`, `!T`, a slice) and whether they
/// hold a write borrow (`!T`), directly or through an optional, array,
/// field, variant payload, shared or weak handle, or any argument of a
/// generic instance. What a Cell or Signal holds holds no borrow.
pub const Borrows = packed struct(u2) {
    any: bool = false,
    write: bool = false,

    fn with(a: Borrows, b: Borrows) Borrows {
        return .{ .any = a.any or b.any, .write = a.write or b.write };
    }
};

/// Facts about an interned type, recorded when it is interned
/// (`SemContext.intern`). The structural facts are always known; the
/// rest once declarations are resolved (`SemContext.contents_ready`).
pub const TypeInfo = packed struct(u16) {
    /// Mentions a generic parameter anywhere.
    has_type_var: bool = false,
    /// Holds a generic parameter by value, so whether it owns a resource
    /// depends on the instantiation.
    holds_type_var: bool = false,
    /// Needs its destructor run (see `typeHasDropGlue`).
    glue: bool = false,
    /// Holds a `Cell` inline (see `holdsCellByValue`).
    cell: bool = false,
    /// Holds no resource, borrow, or generic parameter. A struct with a
    /// user `drop` can be plain and still have glue (see `isPlainData`).
    plain: bool = false,
    /// Holds a borrow, or a write borrow (see `Borrows`).
    borrows: Borrows = .{},
    _: u1 = 0,
    /// How deeply wrappers and generic instances nest in it (saturating).
    depth: u8 = 0,
};

/// The fields a member holds by value: a data field itself, or a
/// variant's payload fields. Methods hold nothing.
pub fn dataFields(f: *const Field) []const Field {
    if (f.is_method) return &.{};
    if (f.is_variant) return f.payload orelse &.{};
    return f[0..1];
}

fn isTypeDecl(sym: Symbol) bool {
    return sym.kind == .nominal_type or sym.kind == .generic_type;
}

/// Compute what the values of every declared type hold, then the facts
/// of every type interned so far. Types interned later get theirs as
/// they are interned.
fn computeContents(ctx: *SemContext) std.mem.Allocator.Error!void {
    for (ctx.symbols.items, 0..) |sym, i| {
        if (isTypeDecl(sym)) _ = try symbolContents(ctx, @intCast(i));
    }
    try computeCells(ctx);
    try computeBorrows(ctx);
    ctx.contents_ready = true;
    ctx.type_info.clearRetainingCapacity();
    try ctx.syncTypeInfo();
}

fn symbolContents(ctx: *SemContext, id: SymbolId) std.mem.Allocator.Error!Contents {
    const current = ctx.symbols.items[id].contents;
    switch (current.state) {
        .done => return current,
        // Reached again while computing its own contents: the type holds
        // itself by value, which `checkInfiniteTypes` reports.
        .busy => return .{},
        .todo => {},
    }
    ctx.symbols.items[id].contents.state = .busy;
    const params = ctx.symbols.items[id].type_params orelse &.{};
    const held = try ctx.arena.allocator().alloc(bool, params.len);
    @memset(held, false);
    var c: Contents = .{ .state = .done, .plain = true, .held = held };
    for (ctx.symbols.items[id].fields orelse &.{}) |*f| {
        if (f.is_drop_method) c.glue = true;
        for (dataFields(f)) |d| {
            const h = try holdsIn(ctx, d.ty, params, held);
            c.glue = c.glue or h.glue;
            c.plain = c.plain and h.plain;
        }
    }
    // The built-in generics are runtime types: a Vec owns its buffer, and
    // none of them is copied like plain data.
    if (id == ctx.vec_sym_id) c.glue = true;
    if (id == ctx.vec_sym_id or id == ctx.cell_sym_id or id == ctx.signal_sym_id) c.plain = false;
    ctx.symbols.items[id].contents = c;
    return c;
}

const Holds = struct { glue: bool = false, plain: bool = false, type_var: bool = false };

/// What a value of `ty` holds. `ty` is a field type of a generic type
/// whose parameters are `params` (empty elsewhere): each parameter it
/// holds by value is marked in `held` and counts as plain.
fn holdsIn(ctx: *SemContext, ty: TypeId, params: []const SymbolId, held: []bool) std.mem.Allocator.Error!Holds {
    if (params.len == 0 and ctx.contents_ready and ty < ctx.type_info.items.len) {
        const info = ctx.type_info.items[ty];
        return .{ .glue = info.glue, .plain = info.plain, .type_var = info.holds_type_var };
    }
    return switch (ctx.types.get(ty)) {
        .bool, .int, .float, .string, .any_error => .{ .plain = true },
        .optional => |inner| holdsIn(ctx, inner, params, held),
        .array => |a| holdsIn(ctx, a.elem, params, held),
        .fallible => |inner| .{ .type_var = (try holdsIn(ctx, inner, params, held)).type_var },
        .shared, .weak => .{ .glue = true },
        .nominal, .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk .{};
            const c = if (decl.module_id == null) try symbolContents(ctx, decl.sym) else decl.symbol().contents;
            break :blk .{ .glue = c.glue, .plain = c.plain };
        },
        .type_var => |sym| blk: {
            const i = std.mem.indexOfScalar(SymbolId, params, sym) orelse break :blk .{ .type_var = true };
            held[i] = true;
            break :blk .{ .plain = true, .type_var = true };
        },
        .parameterized_nominal => |pn| blk: {
            const c = try symbolContents(ctx, pn.sym);
            var h: Holds = .{ .glue = c.glue, .plain = c.plain };
            for (pn.args, 0..) |a, i| {
                if (i >= c.held.len or !c.held[i]) continue;
                const arg = try holdsIn(ctx, a, params, held);
                h.glue = h.glue or arg.glue;
                h.plain = h.plain and arg.plain;
                h.type_var = h.type_var or arg.type_var;
            }
            break :blk h;
        },
        else => .{},
    };
}

/// A declared type holds a `Cell` inline when a field does: itself, or
/// through a type it holds, or any argument of a generic instance it
/// holds (as the emitter reads type expressions). Found by propagating
/// backwards from the types that hold one directly, so each field type
/// is walked once.
fn computeCells(ctx: *SemContext) std.mem.Allocator.Error!void {
    var edges: std.ArrayListUnmanaged(CellEdge) = .empty;
    defer edges.deinit(ctx.allocator);
    var work: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer work.deinit(ctx.allocator);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (!isTypeDecl(sym)) continue;
        const id: SymbolId = @intCast(i);
        for (sym.fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| {
                if (!try cellEdges(ctx, d.ty, id, &edges) or ctx.symbols.items[id].contents.cell) continue;
                ctx.symbols.items[id].contents.cell = true;
                try work.append(ctx.allocator, id);
            }
        }
    }
    std.mem.sort(CellEdge, edges.items, {}, CellEdge.lessThan);
    while (work.pop()) |from| {
        var i = std.sort.partitionPoint(CellEdge, edges.items, from, CellEdge.before);
        while (i < edges.items.len and edges.items[i].from == from) : (i += 1) {
            const to = edges.items[i].to;
            if (ctx.symbols.items[to].contents.cell) continue;
            ctx.symbols.items[to].contents.cell = true;
            try work.append(ctx.allocator, to);
        }
    }
}

/// `to` holds a `Cell` inline if `from` does.
const CellEdge = struct {
    from: SymbolId,
    to: SymbolId,

    fn lessThan(_: void, a: CellEdge, b: CellEdge) bool {
        return a.from < b.from;
    }

    fn before(from: SymbolId, e: CellEdge) bool {
        return e.from < from;
    }
};

/// Whether a field of type `ty` of `owner` holds a `Cell` inline
/// whatever the declared types it names hold; adds an edge from each of
/// those to `owner`.
fn cellEdges(ctx: *SemContext, ty: TypeId, owner: SymbolId, edges: *std.ArrayListUnmanaged(CellEdge)) std.mem.Allocator.Error!bool {
    return switch (ctx.types.get(ty)) {
        .optional, .fallible => |inner| cellEdges(ctx, inner, owner, edges),
        .array => |a| cellEdges(ctx, a.elem, owner, edges),
        .nominal => |s| blk: {
            try edges.append(ctx.allocator, .{ .from = s, .to = owner });
            break :blk false;
        },
        .imported_nominal => (nominalDecl(ctx, ty) orelse return false).symbol().contents.cell,
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id) break :blk true;
            if (pn.sym == ctx.vec_sym_id or pn.sym == ctx.signal_sym_id) break :blk false;
            try edges.append(ctx.allocator, .{ .from = pn.sym, .to = owner });
            for (pn.args) |a| if (try cellEdges(ctx, a, owner, edges)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// What each declared type's values borrow. A type borrows what the
/// declared types it holds borrow, even through a handle, so the answers
/// are propagated backwards from the types that hold a borrow directly,
/// like `computeCells`.
fn computeBorrows(ctx: *SemContext) std.mem.Allocator.Error!void {
    var edges: std.ArrayListUnmanaged(CellEdge) = .empty;
    defer edges.deinit(ctx.allocator);
    var work: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer work.deinit(ctx.allocator);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (!isTypeDecl(sym)) continue;
        const id: SymbolId = @intCast(i);
        var b: Borrows = .{};
        for (sym.fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| b = b.with(try borrowEdges(ctx, d.ty, id, &edges));
        }
        ctx.symbols.items[id].contents.borrows = b;
        if (b.any) try work.append(ctx.allocator, id);
    }
    std.mem.sort(CellEdge, edges.items, {}, CellEdge.lessThan);
    while (work.pop()) |from| {
        const b = ctx.symbols.items[from].contents.borrows;
        var i = std.sort.partitionPoint(CellEdge, edges.items, from, CellEdge.before);
        while (i < edges.items.len and edges.items[i].from == from) : (i += 1) {
            const to = &ctx.symbols.items[edges.items[i].to].contents.borrows;
            if (to.with(b) == to.*) continue;
            to.* = to.with(b);
            try work.append(ctx.allocator, edges.items[i].to);
        }
    }
}

/// What a field of type `ty` of `owner` borrows whatever the declared
/// types it names borrow; adds an edge from each of those to `owner`.
fn borrowEdges(ctx: *SemContext, ty: TypeId, owner: SymbolId, edges: *std.ArrayListUnmanaged(CellEdge)) std.mem.Allocator.Error!Borrows {
    return switch (ctx.types.get(ty)) {
        .borrow_read, .slice => .{ .any = true },
        .borrow_write => .{ .any = true, .write = true },
        .optional, .fallible, .shared, .weak => |inner| borrowEdges(ctx, inner, owner, edges),
        .array => |a| borrowEdges(ctx, a.elem, owner, edges),
        .nominal => |s| blk: {
            try edges.append(ctx.allocator, .{ .from = s, .to = owner });
            break :blk .{};
        },
        .imported_nominal => (nominalDecl(ctx, ty) orelse return .{}).symbol().contents.borrows,
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) break :blk .{};
            try edges.append(ctx.allocator, .{ .from = pn.sym, .to = owner });
            var b: Borrows = .{};
            for (pn.args) |a| b = b.with(try borrowEdges(ctx, a, owner, edges));
            break :blk b;
        },
        else => .{},
    };
}

/// The facts of a type, from those of the types it is built from, which
/// were interned before it.
fn computeTypeInfo(ctx: *SemContext, id: TypeId) std.mem.Allocator.Error!TypeInfo {
    const ty = ctx.types.get(id);
    var info: TypeInfo = .{ .has_type_var = ty == .type_var };
    var deepest: ?u8 = null;
    var it: TypeChildren = .{ .ty = ty };
    while (it.next()) |c| {
        const ci = ctx.type_info.items[c];
        info.has_type_var = info.has_type_var or ci.has_type_var;
        deepest = @max(deepest orelse 0, ci.depth);
    }
    info.depth = switch (ty) {
        .function => 0,
        .parameterized_nominal => (deepest orelse 0) +| 1,
        else => if (deepest) |d| d +| 1 else 0,
    };
    if (!ctx.contents_ready) return info;
    var no_params: [0]bool = .{};
    const h = try holdsIn(ctx, id, &.{}, &no_params);
    info.glue = h.glue;
    info.plain = h.plain;
    info.holds_type_var = h.type_var;
    info.cell = switch (ty) {
        .optional, .fallible => |inner| ctx.type_info.items[inner].cell,
        .array => |a| ctx.type_info.items[a.elem].cell,
        .nominal, .imported_nominal => if (nominalDecl(ctx, id)) |decl| decl.symbol().contents.cell else false,
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id) break :blk true;
            if (pn.sym == ctx.vec_sym_id or pn.sym == ctx.signal_sym_id) break :blk false;
            if (ctx.symbols.items[pn.sym].contents.cell) break :blk true;
            for (pn.args) |a| if (ctx.type_info.items[a].cell) break :blk true;
            break :blk false;
        },
        else => false,
    };
    info.borrows = switch (ty) {
        .borrow_read, .slice => .{ .any = true },
        .borrow_write => .{ .any = true, .write = true },
        .optional, .fallible, .shared, .weak => |inner| ctx.type_info.items[inner].borrows,
        .array => |a| ctx.type_info.items[a.elem].borrows,
        .nominal, .imported_nominal => if (nominalDecl(ctx, id)) |decl| decl.symbol().contents.borrows else .{},
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) break :blk .{};
            var b = ctx.symbols.items[pn.sym].contents.borrows;
            for (pn.args) |a| b = b.with(ctx.type_info.items[a].borrows);
            break :blk b;
        },
        else => .{},
    };
    return info;
}

/// A struct or enum may not hold itself by value, directly or through
/// the types it holds by value: it would have no finite size. One search
/// of the by-value graph over the declared types finds every cycle
/// (Tarjan's strongly connected components).
fn checkInfiniteTypes(ctx: *SemContext) std.mem.Allocator.Error!void {
    const n = ctx.symbols.items.len;
    const a = ctx.allocator;
    var s: Components = .{
        .ctx = ctx,
        .index = try a.alloc(u32, n),
        .low = try a.alloc(u32, n),
        .on_stack = try a.alloc(bool, n),
        .cyclic = try a.alloc(bool, n),
    };
    defer s.deinit();
    @memset(s.index, 0);
    @memset(s.on_stack, false);
    @memset(s.cyclic, false);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (isTypeDecl(sym) and s.index[i] == 0) try s.visit(@intCast(i));
    }
    var targets: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer targets.deinit(a);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (!s.cyclic[i] or sym.decl_pos == builtin_decl_pos) continue;
        const f = fields: for (sym.fields orelse &.{}) |*f| {
            targets.clearRetainingCapacity();
            for (dataFields(f)) |d| try byValueTargets(ctx, d.ty, &targets);
            // `low` names the component after the search.
            for (targets.items) |t| if (s.low[t] == s.low[i]) break :fields f;
        } else continue;
        const shown = if (sym.kind == .generic_type) try std.fmt.allocPrint(ctx.arena.allocator(), "{s}[...]", .{sym.name}) else sym.name;
        try ctx.err(f.decl_pos, "`{s}` contains itself by value through `{s}`, so it would have no finite size; hold it through a shared handle (`*{s}`)", .{ shown, f.name, shown });
    }
}

const Components = struct {
    ctx: *SemContext,
    next: u32 = 1,
    /// Visit order (0: not visited yet).
    index: []u32,
    /// The lowest index reachable; once a component is complete, the
    /// index of its root, shared by all its members.
    low: []u32,
    on_stack: []bool,
    /// In a component with a cycle.
    cyclic: []bool,
    stack: std.ArrayListUnmanaged(SymbolId) = .empty,

    fn deinit(self: *Components) void {
        const a = self.ctx.allocator;
        a.free(self.index);
        a.free(self.low);
        a.free(self.on_stack);
        a.free(self.cyclic);
        self.stack.deinit(a);
    }

    fn visit(self: *Components, v: SymbolId) std.mem.Allocator.Error!void {
        const a = self.ctx.allocator;
        self.index[v] = self.next;
        self.low[v] = self.next;
        self.next += 1;
        try self.stack.append(a, v);
        self.on_stack[v] = true;
        var targets: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer targets.deinit(a);
        for (self.ctx.symbols.items[v].fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| try byValueTargets(self.ctx, d.ty, &targets);
        }
        for (targets.items) |w| {
            if (w == v) self.cyclic[v] = true;
            if (self.index[w] == 0) {
                try self.visit(w);
                self.low[v] = @min(self.low[v], self.low[w]);
            } else if (self.on_stack[w]) self.low[v] = @min(self.low[v], self.index[w]);
        }
        if (self.low[v] != self.index[v]) return;
        const start = std.mem.lastIndexOfScalar(SymbolId, self.stack.items, v).?;
        const members = self.stack.items[start..];
        for (members) |m| {
            self.on_stack[m] = false;
            self.low[m] = self.index[v];
            if (members.len > 1) self.cyclic[m] = true;
        }
        self.stack.shrinkRetainingCapacity(start);
    }
};

/// The declared types a value of `ty` holds inline (not behind a handle,
/// a borrow, or a Vec's heap buffer), appended to `out`.
fn byValueTargets(ctx: *const SemContext, ty: TypeId, out: *std.ArrayListUnmanaged(SymbolId)) std.mem.Allocator.Error!void {
    switch (ctx.types.get(ty)) {
        .optional, .fallible => |inner| try byValueTargets(ctx, inner, out),
        .array => |a| try byValueTargets(ctx, a.elem, out),
        .nominal => |s| try out.append(ctx.allocator, s),
        .parameterized_nominal => |pn| {
            if (pn.sym == ctx.vec_sym_id or pn.sym == ctx.signal_sym_id) return;
            try out.append(ctx.allocator, pn.sym);
            const held = ctx.symbols.items[pn.sym].contents.held;
            for (pn.args, 0..) |arg, i| {
                if (i < held.len and held[i]) try byValueTargets(ctx, arg, out);
            }
        },
        else => {},
    }
}

// =============================================================================
// Type queries
// =============================================================================

pub const builtin_decl_pos: u32 = std.math.maxInt(u32);

/// The types a type is built from, in order: a wrapper's inner type, an
/// array or slice's element, a function's parameters then its return
/// type, a generic instance's arguments.
pub const TypeChildren = struct {
    ty: Type,
    i: usize = 0,

    pub fn next(self: *TypeChildren) ?TypeId {
        const i = self.i;
        self.i += 1;
        return switch (self.ty) {
            .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak, .range => |inner| if (i == 0) inner else null,
            .slice => |s| if (i == 0) s.elem else null,
            .array => |a| if (i == 0) a.elem else null,
            .function => |f| if (i < f.params.len) f.params[i] else if (i == f.params.len) f.returns else null,
            .parameterized_nominal => |pn| if (i < pn.args.len) pn.args[i] else null,
            else => null,
        };
    }
};

pub fn typeChildren(ctx: *const SemContext, ty: TypeId) TypeChildren {
    return .{ .ty = ctx.types.get(ty) };
}

/// Does a value of this type need its destructor run: a `*T` / `~T`
/// handle, a Vec, an owned closure, or a nominal or generic instance
/// that declares `drop` or holds such a value. Types with drop glue are
/// non-Copy.
pub fn typeHasDropGlue(ctx: *const SemContext, ty_id: TypeId) bool {
    return ctx.holds(ty_id).glue;
}

/// The signature of an owned closure handle `*fun(...) -> R` / `*sub(...)`
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

/// A value of an error set, or any error: what a fallible function
/// fails with.
pub fn isErrorValue(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.types.get(ty) == .any_error or isErrorSet(ctx, ty);
}

/// A type declared with `error`.
pub fn isErrorSet(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .nominal, .imported_nominal => (nominalDecl(ctx, ty) orelse return false).symbol().flags.error_set,
        else => false,
    };
}

/// Whether some error set this module can see (its own, or one declared
/// in a module it imports) has a member named `name`.
pub fn errorNameExists(ctx: *const SemContext, name: []const u8) bool {
    if (errorNameIn(ctx, name)) return true;
    var it = ctx.reach.iterator(.{});
    while (it.next()) |id| if (errorNameIn(ctx.foreign_semas.get(@intCast(id)).?, name)) return true;
    return false;
}

fn errorNameIn(ctx: *const SemContext, name: []const u8) bool {
    for (ctx.symbols.items) |sym| {
        if (!sym.flags.error_set) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_variant and std.mem.eql(u8, f.name, name)) return true;
        }
    }
    return false;
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
            var params: std.ArrayListUnmanaged(TypeId) = .empty;
            defer params.deinit(ctx.allocator);
            for (f.params) |p| try params.append(ctx.allocator, try substituteType(ctx, p, subst));
            var ct: std.ArrayListUnmanaged(TypeId) = .empty;
            defer ct.deinit(ctx.allocator);
            for (f.ct_params) |p| try ct.append(ctx.allocator, try substituteType(ctx, p, subst));
            const ret = try substituteType(ctx, f.returns, subst);
            if (ret == f.returns and std.mem.eql(TypeId, params.items, f.params) and std.mem.eql(TypeId, ct.items, f.ct_params)) return ty_id;
            return ctx.internCopy(.{ .function = .{ .params = params.items, .returns = ret, .is_sub = f.is_sub, .ct_params = ct.items } });
        },
        .parameterized_nominal => |pn| {
            var args: std.ArrayListUnmanaged(TypeId) = .empty;
            defer args.deinit(ctx.allocator);
            for (pn.args) |a| try args.append(ctx.allocator, try substituteType(ctx, a, subst));
            if (std.mem.eql(TypeId, args.items, pn.args)) return ty_id;
            return ctx.internCopy(.{ .parameterized_nominal = .{ .sym = pn.sym, .args = args.items } });
        },
        else => return ty_id,
    }
}

/// The type parameter a compile-time parameter slot of a function
/// (`FunctionType.ct_params`) declares; null for a value parameter.
pub fn typeParamOf(ctx: *const SemContext, slot: TypeId) ?SymbolId {
    return switch (ctx.types.get(slot)) {
        .type_var => |sym| sym,
        else => null,
    };
}

/// Whether a function takes type parameters: a generic function.
pub fn isGenericFn(ctx: *const SemContext, f: FunctionType) bool {
    for (f.ct_params) |p| if (typeParamOf(ctx, p) != null) return true;
    return false;
}

/// Does `ty_id` mention a generic parameter anywhere?
pub fn containsTypeVar(ctx: *const SemContext, ty_id: TypeId) bool {
    return ctx.typeInfo(ty_id).has_type_var;
}

/// Whether a value of `ty` holds a `Cell` inline (not behind a handle,
/// a borrow, or a Vec's buffer). A read borrow of such a value is held as
/// a pointer, since the cell can change while it is borrowed.
pub fn holdsCellByValue(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).cell;
}

/// Whether a value of `ty` can hold a borrow (see `Borrows`). A generic
/// parameter holds none: an instantiation with a borrow is checked apart.
pub fn holdsBorrow(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).borrows.any;
}

/// Whether a value of `ty` holds a write borrow, which is unique.
pub fn holdsWriteBorrow(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).borrows.write;
}

/// A value that owns nothing and holds no borrow or type parameter: it
/// can be copied freely, like a number.
pub fn isPlainData(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.plain and !info.glue;
}

/// Whether a value of `ty` owns a resource depends on type parameters
/// that `ty` holds by value (a `T`, `T?`, `Box[T]` inside a generic
/// body): it has no drop glue of its own, but an instantiation may. Such
/// values are moved and dropped like resources.
pub fn maybeDropGlue(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return !info.glue and info.holds_type_var;
}

/// The type parameters `ty` holds by value, appended to `out`.
pub fn heldTypeVars(ctx: *const SemContext, ty: TypeId, out: *std.ArrayListUnmanaged(SymbolId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (!ctx.holds(ty).holds_type_var) return;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| if (std.mem.indexOfScalar(SymbolId, out.items, sym) == null) try out.append(a, sym),
        .optional, .fallible => |inner| try heldTypeVars(ctx, inner, out, a),
        .array => |arr| try heldTypeVars(ctx, arr.elem, out, a),
        .parameterized_nominal => |pn| {
            const held = ctx.symbols.items[pn.sym].contents.held;
            for (pn.args, 0..) |arg, i| {
                if (i < held.len and held[i]) try heldTypeVars(ctx, arg, out, a);
            }
        },
        else => {},
    }
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
        .invalid, .unknown, .void, .bool, .string, .int, .float, .int_literal, .float_literal, .none_literal, .noreturn, .any_error => return local_ctx.intern(ty),
        inline .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak, .range => |inner, tag| {
            const local_inner = try importType(local_ctx, foreign_ctx, inner, origin_module_id);
            return local_ctx.intern(@unionInit(Type, @tagName(tag), local_inner));
        },
        .slice => |s| return local_ctx.intern(.{ .slice = .{ .elem = try importType(local_ctx, foreign_ctx, s.elem, origin_module_id) } }),
        .array => |a| return local_ctx.intern(.{ .array = .{ .elem = try importType(local_ctx, foreign_ctx, a.elem, origin_module_id), .len = a.len } }),
        .function => |f| {
            var params: std.ArrayListUnmanaged(TypeId) = .empty;
            defer params.deinit(local_ctx.allocator);
            for (f.params) |p| try params.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, p, origin_module_id));
            var ct: std.ArrayListUnmanaged(TypeId) = .empty;
            defer ct.deinit(local_ctx.allocator);
            for (f.ct_params) |p| try ct.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, p, origin_module_id));
            const ret = try importType(local_ctx, foreign_ctx, f.returns, origin_module_id);
            return local_ctx.internCopy(.{ .function = .{ .params = params.items, .returns = ret, .is_sub = f.is_sub, .ct_params = ct.items } });
        },
        .nominal => |sym_id| return local_ctx.intern(.{ .imported_nominal = .{ .module_id = origin_module_id, .sym_id = sym_id } }),
        .imported_nominal => |n| return local_ctx.intern(.{ .imported_nominal = n }),
        // Only the built-in generics (Vec, Cell, ...) cross module
        // boundaries (`resolve.checkPublicSurface`); they have the same
        // symbol ids in every module, so their ids carry over unchanged.
        .parameterized_nominal => |pn| {
            if (foreign_ctx.symbols.items[pn.sym].decl_pos != builtin_decl_pos) return local_ctx.types.invalid_id;
            var args: std.ArrayListUnmanaged(TypeId) = .empty;
            defer args.deinit(local_ctx.allocator);
            for (pn.args) |a| try args.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, a, origin_module_id));
            return local_ctx.internCopy(.{ .parameterized_nominal = .{ .sym = pn.sym, .args = args.items } });
        },
        // A generic parameter never leaves its generic type's module.
        .type_var => return local_ctx.types.invalid_id,
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

/// `Self` is `nominal(sym)` for plain types and `Box[T]` (applied to
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

/// An enum variant of the receiver's nominal, local or imported.
pub fn lookupVariant(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedVariant {
    const decl = nominalDecl(ctx, receiver_ty) orelse return null;
    const subst = if (membersOf(ctx, unwrapBorrows(ctx, receiver_ty))) |m| m.subst else TypeSubst.empty;
    for (decl.symbol().fields orelse return null) |f| {
        if (!f.is_variant or !std.mem.eql(u8, f.name, name)) continue;
        var payload = f.payload orelse &.{};
        if (payload.len > 0 and (decl.module_id != null or !subst.isEmpty())) {
            const typed = try ctx.arena.allocator().dupe(Field, payload);
            for (typed) |*pf| pf.ty = if (decl.module_id) |origin|
                try importType(ctx, @constCast(decl.ctx), pf.ty, origin)
            else
                try substituteType(ctx, pf.ty, subst);
            payload = typed;
        }
        return .{ .field = f, .payload = payload, .nominal_sym = if (decl.module_id == null) decl.sym else symbol_invalid, .owner_name = decl.symbol().name };
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
        .any_error => "error",
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
        .function => |f| if (f.is_sub)
            try std.fmt.allocPrint(a, "sub({s})", .{try formatTypeList(ctx, a, f.params)})
        else
            try std.fmt.allocPrint(a, "fun({s}) -> {s}", .{ try formatTypeList(ctx, a, f.params), try formatTypeIn(ctx, a, f.returns) }),
        .nominal => |sym| ctx.symbols.items[sym].name,
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk "<imported>";
            if (in.sym_id >= foreign.symbols.items.len) break :blk "<imported>";
            const name = foreign.symbols.items[in.sym_id].name;
            // Spelled the way this module names it: `other.Point`.
            for (ctx.imports) |imp| {
                if (imp.module_id == in.module_id) break :blk try std.fmt.allocPrint(a, "{s}.{s}", .{ imp.local_name, name });
            }
            // A module reached only through an import, by its file name.
            break :blk try std.fmt.allocPrint(a, "{s}.{s}", .{ foreign.name, name });
        },
        .parameterized_nominal => |pn| try std.fmt.allocPrint(a, "{s}[{s}]", .{ ctx.symbols.items[pn.sym].name, try formatTypeList(ctx, a, pn.args) }),
        .type_var => |sym| ctx.symbols.items[sym].name,
    };
}

/// Types separated by `, `.
fn formatTypeList(ctx: *const SemContext, a: std.mem.Allocator, ids: []const TypeId) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (ids, 0..) |id, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, try formatTypeIn(ctx, a, id));
    }
    return buf.items;
}

/// `T?` / `T!`, parenthesizing prefix forms: `(*T)?` is an optional
/// handle, while `*T?` would be a handle to an optional.
fn formatSuffixed(ctx: *const SemContext, a: std.mem.Allocator, inner: TypeId, suffix: u8) ![]const u8 {
    const s = try formatTypeIn(ctx, a, inner);
    const parens = switch (ctx.types.get(inner)) {
        .shared, .weak, .borrow_read, .borrow_write => true,
        // `fun(Int) -> Int?` returns an optional.
        .function => |f| !f.is_sub,
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

/// Whether `e` holds a `break` (with a value, when `valued`) that leaves
/// the loop whose body it is: an unlabeled one outside nested loops, or
/// one naming the loop's `label`, outside closures. A nested loop's
/// `else` runs after that loop, so its jumps are the outer loop's.
pub fn breaksOut(source: []const u8, e: Sexp, label: []const u8, nested: bool, valued: bool) bool {
    const h = e.kind() orelse return false;
    switch (h) {
        .@"break" => {
            if (valued and ir.Break.value(e) == .nil) return false;
            const l = ir.Break.label(e);
            if (l == .nil) return !nested;
            return label.len > 0 and std.mem.eql(u8, identAt(source, l) orelse "", label);
        },
        .lambda => return false,
        .@"while", .@"for" => {
            if (breaksOut(source, ir.get(e, .@"else"), label, nested, valued)) return true;
            return label.len > 0 and breaksOut(source, ir.get(e, .body), label, true, valued);
        },
        else => {},
    }
    for (rig.children(e)) |c| if (breaksOut(source, c, label, nested, valued)) return true;
    return false;
}

/// A loop used as a value: a `while` or `for`, labeled or not, that a
/// `break` with a value leaves.
pub fn hasValueBreaks(source: []const u8, e: Sexp) bool {
    var label: []const u8 = "";
    var loop = e;
    if (e.isKind(.labeled)) {
        label = identAt(source, ir.Labeled.label(e)) orelse "";
        loop = ir.Labeled.stmt(e);
    }
    if (!loop.isKind(.@"while") and !loop.isKind(.@"for")) return false;
    return breaksOut(source, ir.get(loop, .body), label, false, true);
}

pub fn srcPos(sexp: Sexp, fallback: u32) u32 {
    return if (sexp == .src) sexp.src.pos else fallback;
}

/// A constant integer expression's value, or why it has none.
pub const ConstInt = union(enum) {
    value: i128,
    not_constant,
    /// Constant, but too large to compute.
    overflow,
};

/// The value of a constant integer expression: literals, constant
/// bindings, and arithmetic on them.
pub fn constInt(ctx: *const SemContext, e: Sexp) ConstInt {
    switch (e) {
        .src => {
            const text_ = identAt(ctx.source, e) orelse "";
            if (isIntLiteralText(text_)) return .{ .value = std.fmt.parseInt(i128, text_, 0) catch return .overflow };
            const id = ctx.symbolOf(e) orelse return .not_constant;
            return if (ctx.const_ints.get(id)) |v| .{ .value = v } else .not_constant;
        },
        .list => {
            const h = e.kind() orelse return .not_constant;
            if (h == .neg) {
                const v = switch (constInt(ctx, ir.Neg.operand(e))) {
                    .value => |v| v,
                    else => |r| return r,
                };
                return .{ .value = std.math.negate(v) catch return .overflow };
            }
            // `a if c else b` with a constant condition: Zig picks the
            // branch at compile time, so its value is constant.
            if (h == .@"if" and ir.If.@"else"(e) != .nil) {
                const c = constBoolOf(ctx, ir.If.cond(e)) orelse return .not_constant;
                return constInt(ctx, if (c) ir.If.then(e) else ir.If.@"else"(e));
            }
            switch (h) {
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"<<", .@">>", .@"&", .@"|", .@"^" => {},
                else => return .not_constant,
            }
            const a = switch (constInt(ctx, ir.get(e, .left))) {
                .value => |v| v,
                else => |r| return r,
            };
            const b = switch (constInt(ctx, ir.get(e, .right))) {
                .value => |v| v,
                else => |r| return r,
            };
            const v: ?i128 = switch (h) {
                .@"+" => std.math.add(i128, a, b) catch null,
                .@"-" => std.math.sub(i128, a, b) catch null,
                .@"*" => std.math.mul(i128, a, b) catch null,
                // Division by zero and negative shift amounts are
                // reported where the operator is checked.
                .@"/" => if (b == 0) return .not_constant else std.math.divTrunc(i128, a, b) catch null,
                .@"%" => if (b == 0) return .not_constant else if (b == -1) 0 else @rem(a, b),
                .@"<<" => if (b < 0) return .not_constant else if (b > 126) null else blk: {
                    const r = a << @intCast(b);
                    break :blk if (r >> @intCast(b) == a) r else null;
                },
                .@">>" => if (b < 0) return .not_constant else a >> @intCast(@min(b, 127)),
                .@"&" => a & b,
                .@"|" => a | b,
                else => a ^ b,
            };
            return if (v) |x| .{ .value = x } else .overflow;
        },
        else => return .not_constant,
    }
}

/// `constInt` as an optional: null when not constant or too large.
pub fn constIntOf(ctx: *const SemContext, e: Sexp) ?i128 {
    return switch (constInt(ctx, e)) {
        .value => |v| v,
        else => null,
    };
}

/// The value of a constant Bool expression: literals, `not`, `and`,
/// `or`, and comparisons of constant integers.
fn constBoolOf(ctx: *const SemContext, e: Sexp) ?bool {
    switch (e) {
        .src => {
            const word = identAt(ctx.source, e) orelse "";
            if (std.mem.eql(u8, word, "true")) return true;
            if (std.mem.eql(u8, word, "false")) return false;
            return null;
        },
        .list => {
            const h = e.kind() orelse return null;
            switch (h) {
                .not => return !(constBoolOf(ctx, ir.Not.operand(e)) orelse return null),
                .@"and" => return (constBoolOf(ctx, ir.And.left(e)) orelse return null) and (constBoolOf(ctx, ir.And.right(e)) orelse return null),
                .@"or" => return (constBoolOf(ctx, ir.Or.left(e)) orelse return null) or (constBoolOf(ctx, ir.Or.right(e)) orelse return null),
                .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => {
                    const a = constIntOf(ctx, ir.get(e, .left)) orelse return null;
                    const b = constIntOf(ctx, ir.get(e, .right)) orelse return null;
                    return switch (h) {
                        .@"==" => a == b,
                        .@"!=" => a != b,
                        .@"<" => a < b,
                        .@">" => a > b,
                        .@"<=" => a <= b,
                        else => a >= b,
                    };
                },
                else => return null,
            }
        },
        else => return null,
    }
}

/// The compile-time parameter group of a `fun`, `sub`, generic type, or
/// generic enum (`[T]`, `[n: Int]`); `_` for none, and for other kinds.
pub fn tparamsOf(node: Sexp) Sexp {
    const kind = node.kind() orelse return .nil;
    return if (ir.has(kind, .tparams)) ir.get(node, .tparams) else .nil;
}

/// Name leaf of a parameter: `(: name T)`, `(default name T value)`,
/// `(read self)`, `(write self)`, or a bare name.
pub fn paramNameNode(param: Sexp) ?Sexp {
    return switch (param.kind() orelse return if (param == .src) param else null) {
        .@":", .default => ir.get(param, .name),
        .read, .write => ir.get(param, .operand),
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

pub const CaptureMode = enum { cap_clone, cap_weak, cap_move };

pub fn captureModeOf(cap: Sexp) ?CaptureMode {
    return switch (cap.kind() orelse return null) {
        .cap_clone => .cap_clone,
        .cap_weak => .cap_weak,
        .cap_move => .cap_move,
        else => null,
    };
}

pub fn captureNameNode(cap: Sexp) ?Sexp {
    _ = captureModeOf(cap) orelse return null;
    return ir.get(cap, .name);
}

/// The captures of a closure's `captures` slot (`_` when it has none).
pub fn captureList(captures: Sexp) []const Sexp {
    if (captures == .nil) return &.{};
    return ir.Captures.caps(captures);
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
    _ = resolve;
    _ = typecheck;
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
    const ct = [_]TypeId{store.int_id};
    const f4 = try store.intern(a, .{ .function = .{ .params = &p1, .returns = store.int_id, .is_sub = false, .ct_params = &ct } });
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
    var ctx = try check(std.testing.allocator, "", .{ .nil = {} }, .{});
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// ---- facts table ---------------------------------------------------------------

const FactsRun = struct {
    p: parser.Parser,
    tree: Sexp,
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
    var r: FactsRun = .{ .p = parser.Parser.init(std.testing.allocator, source), .tree = undefined, .ctx = undefined, .source = source };
    errdefer r.p.deinit();
    r.tree = try r.p.parseProgram();
    r.ctx = try check(std.testing.allocator, source, r.tree, .{});
    for (r.ctx.diagnostics.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.message});
    try std.testing.expect(!r.ctx.hasErrors());
    return r;
}

/// Find the first list node with head `tag` (depth-first).
fn findNode(node: Sexp, tag: Tag) ?Sexp {
    if (node.kind() == tag) return node;
    if (node != .list) return null;
    for (node.items()) |c| {
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
    const body = ir.Block.stmts(ir.Sub.body(ir.Module.decls(r.tree)[0]));
    try std.testing.expect(r.ctx.isExhaustive(body[1]));
    try std.testing.expect(!r.ctx.isExhaustive(body[3]));
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
    // `I64` is `Int`.
    const i64_ty = r.ctx.types.int_id;
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
    const call = findNode(ir.Module.decls(r.tree)[1], .call).?;
    const add = findNode(call, .@"+").?;
    try std.testing.expectEqual(r.ctx.types.float_id, r.ctx.typeOf(add).?);
    const half_call = findNode(add, .call).?;
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
        \\  v: Vec[Int] = Vec()
        \\  !v.push(3)
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
    const main_fn = ir.Module.decls(r.tree)[1];
    const fn_scope = r.ctx.scopeOf(main_fn).?;
    try std.testing.expectEqual(ScopeKind.function, r.ctx.scopes.items[fn_scope].kind);
    const body = ir.Sub.body(main_fn);
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
    const main_body = ir.Block.stmts(ir.Sub.body(ir.Module.decls(r.tree)[1]));
    const inner1 = ir.Call.args(main_body[0])[0];
    try std.testing.expect(r.ctx.callSlotsOf(inner1) == null);
    const inner2 = ir.Call.args(main_body[1])[0];
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
        \\sub show[k: Int]
        \\  print(k)
        \\
        \\sub main()
        \\  y =! 2
        \\  show[y]()
        \\  print(read(?U(n: y)))
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ctx.symbols.items[r.sym("u", 0).?].flags.borrowed_param);
    const y = r.ctx.symbols.items[r.sym("y", 0).?];
    try std.testing.expect(y.flags.fixed);
    try std.testing.expect(y.flags.comptime_known);
    const k = r.ctx.symbols.items[r.sym("k", 0).?];
    try std.testing.expect(k.flags.comptime_known);
    const show = r.ctx.types.get(r.ctx.symbols.items[r.ctx.lookup(1, "show").?].ty).function;
    try std.testing.expectEqual(@as(usize, 1), show.ct_params.len);
    try std.testing.expectEqual(@as(usize, 0), show.params.len);
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
    // `F64` is `Float`.
    try std.testing.expectEqual(r.ctx.types.float_id, ret.optional);
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
            std.debug.print("no type for node at {d} ({s})\n", .{ diag.leafSpan(node).start, if (node.kind()) |h| @tagName(h) else "leaf" });
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
            .list => switch (e.kind() orelse return) {
                .set => {
                    const target = ir.Set.target(e);
                    self.expectName(target);
                    if (target != .src) self.expr(target);
                    self.expr(ir.Set.value(e));
                },
                .block => for (ir.Block.stmts(e)) |c| self.expr(c),
                .@"if", .@"while" => for (rig.children(e)) |c| self.expr(c),
                .as => {
                    self.expr(ir.As.value(e));
                    self.expectName(ir.As.name(e));
                    self.expectType(ir.As.name(e));
                },
                .@"for" => {
                    self.expectName(ir.For.@"var"(e));
                    const index = ir.For.index(e);
                    if (index != .nil) {
                        self.expectName(index);
                        self.expectType(index);
                    }
                    self.expr(ir.For.source(e));
                    self.expr(ir.For.body(e));
                },
                .match => {
                    self.expr(ir.Match.subject(e));
                    for (ir.Match.arms(e)) |arm| {
                        const pat = ir.Arm.pattern(arm);
                        if (pat.isKind(.variant_pattern)) for (ir.VariantPattern.bindings(pat)) |b| self.expectName(b);
                        self.expr(ir.Arm.body(arm));
                    }
                },
                .lambda => {
                    for (captureList(ir.Lambda.captures(e))) |cap| self.expectName(captureNameNode(cap).?);
                    self.expr(ir.Lambda.body(e));
                },
                .member => {
                    self.expectType(e);
                    self.expr(ir.Member.object(e));
                },
                .call => {
                    self.expectType(e);
                    const callee = ir.Call.callee(e);
                    if (callee == .src) {
                        self.expectName(callee);
                    } else self.expr(callee);
                    for (ir.Call.args(e)) |a| {
                        if (a.isKind(.kwarg)) self.expr(ir.Kwarg.value(a)) else self.expr(a);
                    }
                },
                .@"return", .drop, .@"defer" => for (rig.children(e)) |c| self.expr(c),
                .enum_lit => self.expectType(e),
                else => {
                    self.expectType(e);
                    for (rig.children(e)) |c| if (c != .tag) self.expr(c);
                },
            },
            else => {},
        }
    }

    fn decl(self: *Coverage, d: Sexp) void {
        const h = d.kind() orelse return;
        switch (h) {
            .fun, .sub => {
                for (ir.get(d, .params).items()) |p| self.expectName(paramNameNode(p).?);
                self.expr(ir.get(d, .body));
            },
            .@"struct", .@"enum", .generic_type => for (ir.rest(d, .members)) |m| self.decl(m),
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
        \\type Box[T]
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
        \\  !acct.deposit(5)
        \\  print(acct.doubled())
        \\  moved = <acct
        \\  shared = *Account(owner: "bob", balance: 7)
        \\  other = +shared
        \\  -shared
        \\  print(other.balance)
        \\  total = 0
        \\  v: Vec[Int] = Vec()
        \\  !v.push(3)
        \\  for x in v
        \\    total += x
        \\  print(total + moved.balance)
        \\  b: Box[Int] = Box(value: 4)
        \\  print(b.get())
        \\  print(area(.circle(radius: 2)))
        \\  print(maybe(-1) ?? 9)
        \\  c: *Cell[Int] = *Cell(value: 1)
        \\  f = |+c|
        \\    c.set(c.get() + 1)
        \\  f()
        \\  print(c.get())
        \\
    );
    defer r.deinit();
    var cov: Coverage = .{ .r = &r };
    for (ir.Module.decls(r.tree)) |d| cov.decl(d);
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
        \\  w: Vec[Int] = Vec()
        \\  while !w.pop() as y
        \\    print(y)
        \\  k = 1
        \\  new k = k + 1
        \\  print(k)
        \\
    );
    defer r.deinit();
    var cov: Coverage = .{ .r = &r };
    for (ir.Module.decls(r.tree)) |d| cov.decl(d);
    try std.testing.expectEqual(@as(usize, 0), cov.missing);
    try std.testing.expectEqual(r.ctx.types.int_id, r.leafType("v", 0).?);
    try std.testing.expectEqual(r.ctx.types.int_id, r.leafType("i", 0).?);
}
