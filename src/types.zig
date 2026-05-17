//! Rig Sema / Type Checker (M5).
//!
//! Pipeline slot: parse → normalize → **sema (this file)** → ownership/effects → emit.
//!
//! `SemContext` is the central semantic structure produced by `check()`
//! and consumed by every later pass. Stable IDs (`SymbolId`, `ScopeId`,
//! `TypeId`) replace name-based lookup so:
//!
//!   - ownership tracks `SymbolId`s, not name strings (no more shadow
//!     ambiguity in lookup);
//!   - emitter consults symbol facts (no more name-based mutation scan);
//!   - diagnostics can point at both use site and declaration;
//!   - M5/M6 modules and generics won't require reshaping the data.
//!
//! M5 v1 scope (per GPT-5.5 design pass):
//!
//!   1. Symbol resolution — functions / params / locals / type aliases.
//!   2. Type expression resolution — `(error_union T)` / `(optional T)`
//!      / `(borrow_read T)` / `(slice T)` etc. Sexp → `TypeId`.
//!   3. Conservative local synthesis for expressions. Function
//!      boundaries authoritative. `if` arms must unify exactly. Numeric
//!      literals default to canonical `Int` / `Float`. No
//!      Hindley-Milner, no bidirectional, no coercion lattice.
//!   4. Annotations required for ambiguous untyped bindings
//!      (`x = []`, `x = none`, `x = .Foo` all error without context).
//!
//! THIS COMMIT: skeleton only. Defines all the IDs / enums / context
//! shape and lands `pub fn check(allocator, source, ir) !SemContext`
//! that does nothing (returns an empty context). Subsequent commits
//! fill in the passes.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;

// =============================================================================
// Stable IDs
// =============================================================================
//
// `u32` everywhere — we'll never have 4G symbols/types/scopes in a single
// compilation unit, and `u32` keeps SemContext compact. `0` is reserved
// for "invalid / sentinel" so callers can use `id != 0` as a quick check.

pub const SymbolId = u32;
pub const ScopeId = u32;
pub const TypeId = u32;

pub const symbol_invalid: SymbolId = 0;
pub const scope_invalid: ScopeId = 0;
pub const type_invalid: TypeId = 0;

// =============================================================================
// Types
// =============================================================================

pub const IntInfo = struct {
    /// `0` for unsized / arch-default `Int`. Specific widths use 8/16/32/64.
    bits: u8 = 0,
    signed: bool = true,
};

pub const FloatInfo = struct {
    /// `0` for unsized / arch-default `Float`. Specific widths use 32/64.
    bits: u8 = 0,
};

pub const FunctionType = struct {
    /// Slice into `SemContext.fn_param_types` — borrowed, not owned.
    params: []const TypeId,
    returns: TypeId,
    is_sub: bool, // sub: no return value (returns == void)
};

pub const SliceType = struct { elem: TypeId };
pub const ArrayType = struct { elem: TypeId, len: u64 };

/// Tagged union of all Rig types. Sized intentionally small — heavier
/// data (function param lists) lives in side-tables in `SemContext`.
pub const Type = union(enum) {
    /// Sentinel for "type checking failed here" — propagates without
    /// further error spam at downstream use sites.
    invalid,
    /// Used for placeholders during inference / declaration ordering.
    /// Should never escape the checker.
    unknown,

    void,
    bool,
    string,
    int: IntInfo,
    float: FloatInfo,

    /// Pseudo-types for unconstrained numeric literals (`1`, `2.5`).
    /// Adapt to a concrete `int`/`float` at known use sites (assignment
    /// to declared type, call arg to typed param, return value, etc.).
    /// Without context, default to canonical `Int` / `Float`.
    ///
    /// This is the M5 v1 minimum that makes `x: U8 = 0` work without
    /// adding a general coercion lattice — only literals adapt; named
    /// values don't widen across sized integer types.
    int_literal,
    float_literal,

    optional: TypeId,      // T?  → optional T
    fallible: TypeId,      // T!  → error_union T
    borrow_read: TypeId,   // ?T  → read-borrowed T
    borrow_write: TypeId,  // !T  → write-borrowed T

    /// M20d: `*T` shared / `Rc<T>` handle. Strict structural equality
    /// per GPT-5.5's design pass — `*User != User`, `*User != *Owner`,
    /// `*User != ~User`. No wildcard or coercion behavior; the only way
    /// to bridge `*T → T`-shaped APIs is the read-only auto-deref that
    /// lands in M20d(4/5), and even then write/value receivers are
    /// rejected (interior mutation belongs in `Cell(T)`, M20+ item #7).
    shared: TypeId,        // *T  → shared T (Rc<T>)
    /// M20d: `~T` weak handle paired with `*T`. Strict structural
    /// equality. The runtime `.upgrade()` method returns
    /// `optional(shared(T))` i.e. `*T?` (built-in optional, NOT the
    /// user-defined `Option(*T)` — that desugar is a separate, strongly
    /// deferred milestone). At sema-typing time `(weak x)` in expression
    /// position requires `x: shared(T)` and types as `weak(T)`.
    weak: TypeId,          // ~T  → weak T (Weak<T>)

    slice: SliceType,
    array: ArrayType,

    function: FunctionType,
    /// Reference to a named declaration (struct, enum, type alias,
    /// generic-type DECLARATION). The actual definition lives at
    /// `SemContext.symbols[symbol]`.
    nominal: SymbolId,

    /// M20b(2/5): a fully-applied generic type instantiation. `sym`
    /// points at the generic_type Symbol (e.g., `Box`); `args` are
    /// the type arguments in declaration order (e.g., `[Int]` for
    /// `Box(Int)`). The interner deduplicates by structure so
    /// `Box(Int)` always returns the same TypeId. `args` is owned
    /// by the SemContext arena.
    parameterized_nominal: ParamNominal,

    /// M20b(2/5): a generic type parameter reference. `SymbolId`
    /// points at a `.generic_param` Symbol bound by SymbolResolver
    /// when walking a generic type's body. Substituted away by
    /// `substituteType` at use sites; should never escape into
    /// resolved expression types after substitution.
    type_var: SymbolId,
};

/// M20b(2/5): a fully-applied generic type instantiation.
pub const ParamNominal = struct {
    sym: SymbolId,
    args: []const TypeId,
};

/// Type interner. Ensures structural equality for atomic types
/// (`int{32, true}` is always the same `TypeId`) and gives us O(1) lookup
/// from id to definition. Composite types (function, slice, array,
/// optional, fallible, borrow_*) are also interned by structure so
/// identity comparison suffices for unification.
///
/// Backed by a `std.ArrayListUnmanaged(Type)` plus an inverse-lookup
/// `std.AutoHashMapUnmanaged(TypeKey, TypeId)`. Since `Type` includes
/// slices (function params), we hash the canonicalized representation
/// when interning.
///
/// THIS COMMIT: empty store with primitives pre-interned at construction.
pub const TypeStore = struct {
    items: std.ArrayListUnmanaged(Type) = .empty,

    /// Pre-interned primitive `TypeId`s. Set by `init`; valid for the
    /// store's lifetime. `0` is reserved as the invalid sentinel.
    invalid_id: TypeId = type_invalid,
    unknown_id: TypeId = type_invalid,
    void_id: TypeId = type_invalid,
    bool_id: TypeId = type_invalid,
    string_id: TypeId = type_invalid,
    int_id: TypeId = type_invalid,           // unsized Int (arch default)
    float_id: TypeId = type_invalid,         // unsized Float (arch default)
    int_literal_id: TypeId = type_invalid,   // unconstrained int literal pseudo-type
    float_literal_id: TypeId = type_invalid, // unconstrained float literal pseudo-type

    pub fn init(allocator: std.mem.Allocator) !TypeStore {
        var s: TypeStore = .{};
        // Slot 0 is the invalid sentinel.
        try s.items.append(allocator, .invalid);
        s.invalid_id = 0;
        s.unknown_id = try s.appendType(allocator, .unknown);
        s.void_id = try s.appendType(allocator, .void);
        s.bool_id = try s.appendType(allocator, .bool);
        s.string_id = try s.appendType(allocator, .string);
        s.int_id = try s.appendType(allocator, .{ .int = .{ .bits = 0, .signed = true } });
        s.float_id = try s.appendType(allocator, .{ .float = .{ .bits = 0 } });
        s.int_literal_id = try s.appendType(allocator, .int_literal);
        s.float_literal_id = try s.appendType(allocator, .float_literal);
        return s;
    }

    pub fn deinit(self: *TypeStore, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    fn appendType(self: *TypeStore, allocator: std.mem.Allocator, ty: Type) !TypeId {
        const id: TypeId = @intCast(self.items.items.len);
        try self.items.append(allocator, ty);
        return id;
    }

    pub fn get(self: *const TypeStore, id: TypeId) Type {
        if (id >= self.items.items.len) return .invalid;
        return self.items.items[id];
    }

    /// Intern a composite type (or return existing id). Atomic types
    /// (void, bool, string, etc.) should use the pre-interned `*_id`
    /// fields directly, not this method, for hot-path efficiency.
    ///
    /// THIS COMMIT: simple linear-scan dedupe. Future commit will swap
    /// to a hash-keyed lookup once we have a stable canonical hash.
    pub fn intern(self: *TypeStore, allocator: std.mem.Allocator, ty: Type) !TypeId {
        for (self.items.items, 0..) |existing, i| {
            if (typeEqual(existing, ty)) return @intCast(i);
        }
        return self.appendType(allocator, ty);
    }

    fn typeEqual(a: Type, b: Type) bool {
        if (@as(std.meta.Tag(Type), a) != @as(std.meta.Tag(Type), b)) return false;
        return switch (a) {
            .invalid, .unknown, .void, .bool, .string,
            .int_literal, .float_literal,
            => true,
            .int => |ai| ai.bits == b.int.bits and ai.signed == b.int.signed,
            .float => |af| af.bits == b.float.bits,
            .optional => |ao| ao == b.optional,
            .fallible => |af| af == b.fallible,
            .borrow_read => |abr| abr == b.borrow_read,
            .borrow_write => |abw| abw == b.borrow_write,
            .shared => |as| as == b.shared,
            .weak => |aw| aw == b.weak,
            .slice => |as| as.elem == b.slice.elem,
            .array => |aa| aa.elem == b.array.elem and aa.len == b.array.len,
            .function => |af| blk: {
                const bf = b.function;
                if (af.is_sub != bf.is_sub) break :blk false;
                if (af.returns != bf.returns) break :blk false;
                if (af.params.len != bf.params.len) break :blk false;
                for (af.params, bf.params) |ap, bp| if (ap != bp) break :blk false;
                break :blk true;
            },
            .nominal => |an| an == b.nominal,
            .parameterized_nominal => |an| blk: {
                const bn = b.parameterized_nominal;
                if (an.sym != bn.sym) break :blk false;
                if (an.args.len != bn.args.len) break :blk false;
                for (an.args, bn.args) |ap, bp| if (ap != bp) break :blk false;
                break :blk true;
            },
            .type_var => |an| an == b.type_var,
        };
    }
};

// =============================================================================
// Symbols + Scopes
// =============================================================================

pub const SymbolKind = enum {
    /// Top-level fun/sub/lambda.
    function,
    /// Function parameter binding.
    param,
    /// Block-local binding (`x = ...`, `new x = ...`, etc.).
    local,
    /// Type alias (`type UserId = Int`).
    type_alias,
    /// Generic type declaration (`type Box(T) = ...`).
    generic_type,
    /// M20b(2/5): a generic type parameter (`T` in `type Box(T)`).
    /// Bound by SymbolResolver when walking the generic type body.
    /// Referenced as a `type_var(SymbolId)` Type variant. Lives in
    /// the type namespace only — using `T` as a value-position name
    /// must fail to resolve.
    generic_param,
    /// Struct / enum / errors / opaque declaration.
    nominal_type,
    /// Module imported via `use`.
    module,
    /// Extern var / const declaration.
    @"extern",
};

pub const SymbolFlags = packed struct {
    /// `=!` or extern-const: re-binding is forbidden.
    fixed: bool = false,
    /// `pub` decoration applied.
    is_public: bool = false,
    /// Function parameter declared with a borrowed type (`?T` / `!T`),
    /// relevant to the borrow-escape rule.
    borrowed_param: bool = false,
    _padding: u5 = 0,
};

/// A field in a nominal type (struct/enum/errors). Stored on the
/// owning Symbol's `fields` slice when the symbol is a `nominal_type`.
/// Slice memory is owned by `SemContext.arena`.
///
/// For struct fields: `ty` holds the declared type; `payload` is null.
/// For enum/errors variants:
///   - bare `red`            → `ty = void_id`, `payload = null`
///   - valued `ok = 0`       → `ty = void_id`, `payload = null` (value
///                              passes through to emit verbatim)
///   - payload `circle(r:Int)` → `ty = void_id`, `payload = [{r, Int}]`
///                              (M9a: declared, lowers to Zig union(enum);
///                              construction lands in M9b+).
/// M20a.2: describes how a method receives its receiver. Computed
/// at decl-time by `resolveNominalMethod` from the syntactic first
/// parameter, *not* inferred at call sites from `params.len > 0`
/// (that was the M20a soundness bug: associated/static methods
/// with parameters silently dispatched as instance methods).
///
///   .none       method has NO `self` parameter (associated/static)
///   .read       `self: ?Self` / `self: ?User` / `?self` sugar
///   .write      `self: !Self` / `self: !User` / `!self` sugar
///   .value      `self: Self` / `self: User` (by-value, consuming)
pub const MethodReceiver = enum { none, read, write, value };

pub const Field = struct {
    name: []const u8, // borrowed slice into source
    ty: TypeId,
    decl_pos: u32,
    payload: ?[]const Field = null,

    /// M12: when true, this `Field` represents a method declared on
    /// the owning nominal type, not a data field. `ty` is then the
    /// method's `function` Type. Method body type-checking landed in
    /// M20a (`ExprChecker.walkMethod`).
    is_method: bool = false,

    /// M20a.2: receiver mode for methods. `.none` for both data
    /// fields and associated/static methods (`fun make(...)` with
    /// no `self` param). Populated alongside `is_method` by
    /// `TypeResolver.resolveNominalMethod`.
    receiver: MethodReceiver = .none,

    /// M20c: when true, this `Field` represents an enum variant
    /// (bare like `red`, valued like `ok = 0`, or payload-bearing
    /// like `circle(r: Int)`). Variants live in the same `fields`
    /// slice as data fields and methods, but are NOT data fields
    /// (so `lookupDataField` must filter them out) and NOT methods
    /// (so `lookupMethod` must filter them out). Use `lookupVariant`
    /// for enum-literal / match-arm resolution. Per GPT-5.5 M20c
    /// design pass.
    is_variant: bool = false,
};

pub const Symbol = struct {
    name: []const u8,            // borrowed slice into source
    kind: SymbolKind,
    ty: TypeId,                  // resolved declared type, or `unknown_id`
    decl_pos: u32,               // source pos of declaration name
    scope: ScopeId,              // owning scope
    flags: SymbolFlags = .{},

    /// For `nominal_type` symbols (struct/enum/errors), the field list
    /// declared in the body. `null` until M6 type resolution populates
    /// it (or for non-nominal kinds). Empty slice means "explicitly no
    /// fields" (e.g., a marker struct).
    ///
    /// Member access (`obj.name`) and constructor checking
    /// (`User(name: ...)`) consult this list.
    ///
    /// M20b(3/5): also populated for `generic_type` symbols with the
    /// type-var-bearing symbolic field types (e.g., for `type Box(T)
    /// value: T`, the `value` field's `ty` is `type_var(T_sym)`).
    fields: ?[]const Field = null,

    /// M20b(3/5): for `generic_type` symbols, the SymbolIds of this
    /// type's generic parameters (in declaration order). `null` for
    /// non-generic symbols. Used by `NominalContext` and by
    /// `TypeResolver.resolveType` to map a bare identifier `T` to
    /// `type_var(T_sym)` without depending on the original lexical
    /// scope being active (per GPT-5.5: more robust than scope-only
    /// lookup, which fails when `ExprChecker.checkSet` constructs an
    /// on-the-fly TypeResolver for a body annotation).
    type_params: ?[]const SymbolId = null,
};

pub const Scope = struct {
    parent: ?ScopeId,
    /// SymbolIds visible in this scope (in declaration order).
    symbols: std.ArrayListUnmanaged(SymbolId) = .empty,
};

// =============================================================================
// Diagnostics (mirrors ownership/effects shape)
// =============================================================================

pub const Severity = enum { @"error", note };

pub const Diagnostic = struct {
    severity: Severity,
    pos: u32,
    message: []const u8,
};

// =============================================================================
// SemContext — the output of `check`
// =============================================================================

pub const SemContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    /// All allocations owned by this context (Symbol names, Diagnostic
    /// messages, fn param-type slices) live in this arena. `deinit`
    /// reclaims them in one call.
    arena: std.heap.ArenaAllocator,

    /// SymbolId 0 is the invalid sentinel.
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,

    /// ScopeId 0 is the invalid sentinel; ScopeId 1 is the module scope.
    scopes: std.ArrayListUnmanaged(Scope) = .empty,

    types: TypeStore,

    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    /// M20f: built-in `Cell(T)` generic_type SymbolId. Set by
    /// `registerBuiltins` during `check`; `symbol_invalid` if
    /// builtins haven't been registered (defensive). Used by
    /// `resolveType` to detect `Cell(T)` instantiations and enforce
    /// the V1 Copy-only restriction.
    cell_sym_id: SymbolId = symbol_invalid,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !SemContext {
        var ctx: SemContext = .{
            .allocator = allocator,
            .source = source,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try TypeStore.init(allocator),
        };
        // Slot 0 = invalid sentinel for both symbols and scopes.
        try ctx.symbols.append(allocator, .{
            .name = "",
            .kind = .local,
            .ty = ctx.types.invalid_id,
            .decl_pos = 0,
            .scope = scope_invalid,
        });
        try ctx.scopes.append(allocator, .{ .parent = null });
        // Slot 1 = the module scope (created lazily on first symbol add).
        return ctx;
    }

    pub fn deinit(self: *SemContext) void {
        for (self.scopes.items) |*s| s.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const SemContext) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    /// Stream all diagnostics to `w`. Defensive against missing/empty
    /// `file_path`, missing/empty `source`, empty messages, and pos
    /// values beyond `source.len`. Diagnostic printing is the last
    /// line of defense — it must never crash, even when upstream
    /// passes left the context partially populated.
    pub fn writeDiagnostics(self: *const SemContext, file_path: []const u8, w: anytype) !void {
        const path = if (file_path.len == 0) "<unknown>" else file_path;
        for (self.diagnostics.items) |d| {
            const tag = switch (d.severity) {
                .@"error" => "error",
                .note => "  note",
            };
            const msg = if (d.message.len == 0) "(no message)" else d.message;
            if (self.source.len == 0) {
                try w.print("{s}: {s}: {s}\n", .{ path, tag, msg });
            } else {
                const lc = lineCol(self.source, d.pos);
                try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ path, lc.line, lc.col, tag, msg });
            }
        }
    }

    /// Append a new scope and return its id.
    pub fn pushScope(self: *SemContext, parent: ScopeId) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .parent = if (parent == scope_invalid) null else parent,
        });
        return id;
    }

    /// Look up a name visible from `from_scope`, walking up the chain.
    /// Returns the most recent (latest-declared) match in the innermost
    /// scope that contains it — this matches the ownership checker's
    /// reverse-order lookup so shadowed names resolve correctly.
    /// M20e(3/5): scope-local name lookup. Unlike `lookup`, does NOT
    /// walk parent scopes — only matches symbols declared in the given
    /// scope. Used by `SymbolResolver.walkSet` to detect reassignment
    /// vs fresh shadowing within the same scope.
    pub fn lookupInScopeOnly(self: *const SemContext, scope_id: ScopeId, name: []const u8) ?SymbolId {
        if (scope_id == scope_invalid or scope_id >= self.scopes.items.len) return null;
        const scope = &self.scopes.items[scope_id];
        var i = scope.symbols.items.len;
        while (i > 0) {
            i -= 1;
            const sym_id = scope.symbols.items[i];
            if (std.mem.eql(u8, self.symbols.items[sym_id].name, name)) {
                return sym_id;
            }
        }
        return null;
    }

    pub fn lookup(self: *const SemContext, from_scope: ScopeId, name: []const u8) ?SymbolId {
        var sid: ?ScopeId = from_scope;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            const scope = &self.scopes.items[s];
            var i = scope.symbols.items.len;
            while (i > 0) {
                i -= 1;
                const sym_id = scope.symbols.items[i];
                if (std.mem.eql(u8, self.symbols.items[sym_id].name, name)) {
                    return sym_id;
                }
            }
            sid = scope.parent;
        }
        return null;
    }
};

// =============================================================================
// Entry point
// =============================================================================

/// Run sema on the normalized IR. Returns a populated `SemContext`.
///
/// Passes (in order):
///   1. Symbol resolution — collect every fun/sub/lambda, params,
///      type aliases, externs, use's, and locals into the symbol
///      table with proper scope nesting. Types start as `unknown_id`.
///   2. Type expression resolution — for every declaration that has
///      a declared type (param, return, alias, extern), convert the
///      type Sexp to a `TypeId` and write it back into the symbol's
///      `ty` slot. Function symbols get a `function` Type.
///   3. Expression typing — for each function body, walk statements
///      with statement-vs-value context. Synthesize types for
///      expressions, check declared bindings against their RHS, check
///      return values against the function's declared return type,
///      enforce `if` arm unification (in value position) and condition
///      types (Bool). Numeric literals adapt to context; otherwise
///      default to canonical `Int` / `Float`.
///
/// Caller owns the returned `SemContext` and must call `deinit`.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    ir: Sexp,
) !SemContext {
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    // Pass 1: symbol resolution.
    const module_scope = try ctx.pushScope(scope_invalid);

    // M20f: register built-in nominal types (Cell, etc.) BEFORE
    // walking user IR, so user code referencing them finds the
    // symbol via the normal lookup path. Stays parallel to how the
    // type interner pre-registers primitive Type IDs in TypeStore.init.
    try registerBuiltins(&ctx, module_scope);

    var resolver: SymbolResolver = .{ .ctx = &ctx, .current_scope = module_scope };
    try resolver.walk(ir);

    // Pass 2: type expression resolution.
    var type_resolver: TypeResolver = .{ .ctx = &ctx };
    try type_resolver.walk(ir, module_scope);

    // Pass 3: expression typing.
    var expr_checker: ExprChecker = .{
        .ctx = &ctx,
        .current_scope = module_scope,
        .current_fn_return = ctx.types.void_id,
    };
    try expr_checker.walkModule(ir, module_scope);

    return ctx;
}

// =============================================================================
// Built-in nominal registration (M20f)
// =============================================================================

/// M20f: pre-register built-in nominal types in the module scope
/// BEFORE the user's IR is walked. Currently registers `Cell(T)`;
/// future built-in stdlib types live here too.
///
/// Cell registration shape:
///   - Cell symbol (kind = .generic_type, scope = module_scope)
///   - Detached `T` generic_param symbol (kind = .generic_param)
///   - Cell.type_params = [T_sym_id]
///   - Synthetic `value: T` field (for `Cell(Int)(value: 0)`
///     constructor syntax)
///
/// Methods (`get`, `set`) are added in M20f(2/4); this commit only
/// gives Rig source the type-position view of `Cell`.
fn registerBuiltins(ctx: *SemContext, module_scope: ScopeId) std.mem.Allocator.Error!void {
    // Cell symbol.
    const cell_sym_id = blk: {
        const id: SymbolId = @intCast(ctx.symbols.items.len);
        try ctx.symbols.append(ctx.allocator, .{
            .name = "Cell",
            .kind = .generic_type,
            .ty = ctx.types.unknown_id,
            .decl_pos = 0,
            .scope = module_scope,
        });
        try ctx.scopes.items[module_scope].symbols.append(ctx.allocator, id);
        break :blk id;
    };
    ctx.cell_sym_id = cell_sym_id;

    // T parameter (detached — lives in ctx.symbols + on
    // Cell.type_params, but NOT in module_scope's symbol list).
    const t_sym_id = blk: {
        const id: SymbolId = @intCast(ctx.symbols.items.len);
        try ctx.symbols.append(ctx.allocator, .{
            .name = "T",
            .kind = .generic_param,
            .ty = ctx.types.unknown_id,
            .decl_pos = 0,
            .scope = module_scope,
        });
        break :blk id;
    };

    // Cell.type_params = [T]
    const type_params = try ctx.arena.allocator().alloc(SymbolId, 1);
    type_params[0] = t_sym_id;
    ctx.symbols.items[cell_sym_id].type_params = type_params;

    // Synthetic field: `value: T` (T as type_var(t_sym_id)).
    const t_type_id = try ctx.types.intern(ctx.allocator, .{ .type_var = t_sym_id });

    // M20f(2/4): synthetic methods `get(?self) -> T` and
    // `set(?self, value: T)`. Per GPT-5.5's M20f design pass:
    // model Cell's methods as ordinary read-receiver methods on
    // a generic nominal. M20b's generic-method substitution
    // machinery handles the per-call-site `T → Int` rewrite, and
    // M20d's read-only auto-deref accepts the receivers through
    // shared without any ad-hoc intercept. The trusted-runtime
    // implementation does the actual interior mutation.
    //
    // The Cell instance type used as the self-receiver:
    //   borrow_read(parameterized_nominal(Cell, [type_var(T)]))
    const cell_inst_id = try ctx.types.intern(ctx.allocator, .{
        .parameterized_nominal = .{
            .sym = cell_sym_id,
            .args = blk: {
                const a = try ctx.arena.allocator().alloc(TypeId, 1);
                a[0] = t_type_id;
                break :blk a;
            },
        },
    });
    const self_ty_id = try ctx.types.intern(ctx.allocator, .{ .borrow_read = cell_inst_id });

    // get(self: ?Cell(T)) -> T
    const get_params = try ctx.arena.allocator().alloc(TypeId, 1);
    get_params[0] = self_ty_id;
    const get_fn_ty = try ctx.types.intern(ctx.allocator, .{
        .function = .{ .params = get_params, .returns = t_type_id, .is_sub = false },
    });

    // set(self: ?Cell(T), value: T) -> Void
    const set_params = try ctx.arena.allocator().alloc(TypeId, 2);
    set_params[0] = self_ty_id;
    set_params[1] = t_type_id;
    const set_fn_ty = try ctx.types.intern(ctx.allocator, .{
        .function = .{ .params = set_params, .returns = ctx.types.void_id, .is_sub = true },
    });

    const fields = try ctx.arena.allocator().alloc(Field, 3);
    fields[0] = .{
        .name = "value",
        .ty = t_type_id,
        .decl_pos = 0,
    };
    fields[1] = .{
        .name = "get",
        .ty = get_fn_ty,
        .decl_pos = 0,
        .is_method = true,
        .receiver = .read,
    };
    fields[2] = .{
        .name = "set",
        .ty = set_fn_ty,
        .decl_pos = 0,
        .is_method = true,
        .receiver = .read,
    };
    ctx.symbols.items[cell_sym_id].fields = fields;
}

/// M20f: is a TypeId a Copy type for Cell(T) instantiation? V1
/// restricts Cell to Copy T (primitives + literal pseudo-types).
/// Non-Copy T (nominal structs, resource handles, slices, etc.)
/// would let `Cell.set` corrupt ownership semantics — overwriting
/// a `*User` without dropping it, etc. Defer until V1 grows
/// replace/take/Drop semantics.
fn isCopyTypeForCell(ctx: *const SemContext, ty_id: TypeId) bool {
    const ty = ctx.types.get(ty_id);
    return switch (ty) {
        .bool, .int, .float, .string, .int_literal, .float_literal => true,
        else => false,
    };
}

// =============================================================================
// Symbol Resolution
// =============================================================================

const SymbolResolver = struct {
    ctx: *SemContext,
    current_scope: ScopeId,

    fn walk(self: *SymbolResolver, sexp: Sexp) std.mem.Allocator.Error!void {
        if (sexp != .list or sexp.list.len == 0) return;
        const items = sexp.list;
        if (items[0] != .tag) return;

        switch (items[0].tag) {
            .@"module" => {
                for (items[1..]) |child| try self.walk(child);
            },
            .@"pub" => {
                // `(pub child)` decoration. Mark the inner declaration as public.
                if (items.len >= 2) {
                    const before = self.ctx.symbols.items.len;
                    try self.walk(items[1]);
                    const after = self.ctx.symbols.items.len;
                    if (after > before) {
                        // The wrapped decl appended exactly one symbol at
                        // the front of its run; flag it public. Inner
                        // recursion (params, locals) added more after,
                        // but those are scope-internal and don't need the
                        // pub flag.
                        self.ctx.symbols.items[before].flags.is_public = true;
                    }
                }
            },
            .@"fun", .@"sub" => try self.walkFun(items),
            .@"lambda" => try self.walkLambda(items),
            .@"use" => try self.walkUse(items),
            .@"type" => try self.walkTypeAlias(items),
            // M20b: `type Box(T)` — generic struct shape.
            // M20c: `enum Option(T)` — generic enum shape. Same
            // pass-1 work (bind detached params, walk methods); the
            // struct-vs-enum distinction lives in the IR head, not
            // in SymbolKind (both kind as `.generic_type` per
            // GPT-5.5's M20c design pass). Pass 2 dispatches on
            // the IR head for field/variant resolution.
            .@"generic_type", .@"generic_enum" => try self.walkGenericType(items),
            .@"struct", .@"enum", .@"errors", .@"opaque" => try self.walkNominalType(items),
            .@"extern" => try self.walkExtern(items),
            .@"set" => try self.walkSet(items),
            .@"block" => try self.walkBlock(items[1..]),
            .@"for" => try self.walkFor(items),
            .@"if", .@"while", .@"match", .@"return", .@"try_block",
            .@"propagate", .@"try", .@"call", .@"member", .@"kwarg",
            .@"drop",
            => for (items[1..]) |child| try self.walk(child),
            .@"catch_block" => try self.walkCatchBlock(items),
            .@"arm" => try self.walkArm(items),
            else => for (items[1..]) |child| try self.walk(child),
        }
    }

    /// `(fun name params returns body)` or `(sub name params body)`.
    /// Adds the function symbol to the CURRENT scope, then opens a fresh
    /// child scope for params + body.
    fn walkFun(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 3) return;
        const name_node = items[1];
        const is_sub = items[0].tag == .@"sub";
        const params = items[2];
        const body = items[items.len - 1];

        if (identAt(self.ctx.source, name_node)) |name| {
            const decl_pos = if (name_node == .src) name_node.src.pos else 0;
            _ = try self.addSymbol(.{
                .name = name,
                .kind = .function,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = decl_pos,
                .scope = self.current_scope,
            });
        }

        // Function body opens a fresh scope (params + locals).
        const fn_scope = try self.ctx.pushScope(self.current_scope);
        const prev_scope = self.current_scope;
        self.current_scope = fn_scope;
        defer self.current_scope = prev_scope;

        // Bind parameters.
        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }

        // Walk body for locals / nested fns.
        try self.walk(body);

        _ = is_sub; // kept for future kind-distinction (e.g., return-type defaulting)
    }

    /// `(lambda params returns body)` — like `fun` but anonymous.
    fn walkLambda(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 4) return;
        const params = items[1];
        const body = items[items.len - 1];

        const fn_scope = try self.ctx.pushScope(self.current_scope);
        const prev_scope = self.current_scope;
        self.current_scope = fn_scope;
        defer self.current_scope = prev_scope;

        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }
        try self.walk(body);
    }

    /// Add a parameter binding to the current (function) scope. Param
    /// shapes vary: `(: name type)`, `(: name type default)`, `name`
    /// (untyped), `(pre_param name type)`, etc. We extract the name and
    /// flag `borrowed_param` if the type is `(borrow_read T)` /
    /// `(borrow_write T)`.
    fn bindParam(self: *SymbolResolver, param: Sexp) std.mem.Allocator.Error!void {
        var name_node: Sexp = .{ .nil = {} };
        var type_node: Sexp = .{ .nil = {} };

        switch (param) {
            .src => name_node = param,
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return;
                switch (items[0].tag) {
                    .@":" => {
                        // (: name type) or (: name type default)
                        if (items.len >= 3) {
                            name_node = items[1];
                            type_node = items[2];
                        }
                    },
                    .@"pre_param" => {
                        // (pre_param name type)
                        if (items.len >= 3) {
                            name_node = items[1];
                            type_node = items[2];
                        }
                    },
                    // M20a.1: `?self` / `!self` sugar — `(read NAME)` /
                    // `(write NAME)` at param position. Treat as a
                    // borrowed param; type-resolution happens in
                    // TypeResolver where the enclosing nominal is known.
                    .@"read", .@"write" => {
                        if (items.len >= 2) {
                            name_node = items[1];
                            // type_node stays nil; the borrowed-param
                            // flag below is set unconditionally for
                            // these shapes.
                        }
                    },
                    else => return,
                }
            },
            else => return,
        }

        const name = identAt(self.ctx.source, name_node) orelse return;
        const decl_pos = if (name_node == .src) name_node.src.pos else 0;
        // M20a.1: `?self` / `!self` sugar — the `read`/`write` head
        // signals a borrow without an explicit type_node, so mark as
        // borrowed unconditionally.
        const borrowed = blk: {
            if (param == .list and param.list.len >= 1 and param.list[0] == .tag) {
                switch (param.list[0].tag) {
                    .@"read", .@"write" => break :blk true,
                    else => {},
                }
            }
            break :blk isBorrowedTypeNode(type_node);
        };
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .param,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
            .flags = .{ .borrowed_param = borrowed },
        });
    }

    fn walkUse(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 2) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const decl_pos = if (items[1] == .src) items[1].src.pos else 0;
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .module,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
        });
    }

    fn walkTypeAlias(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (type name typeexpr)
        if (items.len < 2) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const decl_pos = if (items[1] == .src) items[1].src.pos else 0;
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .type_alias,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
        });
    }

    fn walkGenericType(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (generic_type name (param...) member...)         — M20b
        // (generic_enum name (param...) member...)         — M20c
        // Shared pass-1 work: bind detached params + walk methods.
        if (items.len < 3) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const decl_pos = if (items[1] == .src) items[1].src.pos else 0;
        const generic_sym_id = try self.addSymbol(.{
            .name = name,
            .kind = .generic_type,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
        });

        // M20b(3/5): bind each type parameter as a `.generic_param`
        // symbol AND record the param SymbolIds on the generic type
        // symbol (via `Symbol.type_params`). NominalContext later uses
        // these to resolve bare `T` → `type_var(T_sym)` even when the
        // generic body scope isn't lexically active.
        const params_node = items[2];

        // M20c per GPT-5.5: reject zero-param generic declarations
        // (`type Box()` / `enum Foo()`) — a generic with no type
        // parameters is degenerate; the user almost certainly meant
        // a plain `type Box` / `enum Foo`.
        const empty_params = (params_node == .nil) or
            (params_node == .list and params_node.list.len == 0);
        if (empty_params) {
            const kind_label = if (items[0].tag == .@"generic_enum") @as([]const u8, "enum") else "type";
            const msg = try std.fmt.allocPrint(
                self.ctx.arena.allocator(),
                "generic {s} `{s}` must declare at least one type parameter; for a non-generic {s}, drop the `()`",
                .{ kind_label, name, kind_label },
            );
            try self.ctx.diagnostics.append(self.ctx.allocator, .{
                .severity = .@"error",
                .pos = decl_pos,
                .message = msg,
            });
            // Continue with empty type_params so subsequent passes
            // don't double-fault on the half-constructed symbol.
        }
        var param_ids: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer param_ids.deinit(self.ctx.allocator);

        // Generic-param symbols live in the surrounding (module) scope
        // so that nested-method-body lookups can reach them via the
        // ordinary lexical chain too — but the primary resolution path
        // goes through `Symbol.type_params` + NominalContext, NOT scope.
        if (params_node == .list) {
            // Detect duplicate generic params: `type Pair(T, T)` should
            // error rather than silently shadowing.
            for (params_node.list, 0..) |p, i| {
                const pname = identAt(self.ctx.source, p) orelse continue;
                for (params_node.list[0..i]) |earlier| {
                    const ename = identAt(self.ctx.source, earlier) orelse continue;
                    if (std.mem.eql(u8, pname, ename)) {
                        // Duplicate. We don't have err() here in
                        // SymbolResolver — fire a diagnostic via the
                        // ctx's append path.
                        const ppos: u32 = if (p == .src) p.src.pos else decl_pos;
                        const msg = try std.fmt.allocPrint(
                            self.ctx.arena.allocator(),
                            "duplicate generic parameter `{s}` on `{s}`",
                            .{ pname, name },
                        );
                        try self.ctx.diagnostics.append(self.ctx.allocator, .{
                            .severity = .@"error",
                            .pos = ppos,
                            .message = msg,
                        });
                    }
                }
            }
            // M20b(5/5) per GPT-5.5: generic params are DETACHED —
            // they live in `ctx.symbols` and on the generic type's
            // `type_params` slice, but are NOT inserted into the
            // module scope. Otherwise `T` from `type Box(T)` would
            // collide with `T` from `type Pair(T)` AND would be
            // resolvable by ordinary lexical lookup at module scope,
            // both of which are wrong. NominalContext.type_params is
            // the canonical resolution path.
            //
            // Track seen-this-decl names to skip duplicates (we still
            // diagnosed them above; not adding the duplicate keeps
            // type_params clean and avoids later confusion).
            var added_names: std.StringHashMapUnmanaged(void) = .empty;
            defer added_names.deinit(self.ctx.allocator);
            for (params_node.list) |p| {
                const pname = identAt(self.ctx.source, p) orelse continue;
                if (added_names.contains(pname)) continue;
                try added_names.put(self.ctx.allocator, pname, {});
                const ppos: u32 = if (p == .src) p.src.pos else 0;
                const param_sym_id = try self.addDetachedSymbol(.{
                    .name = pname,
                    .kind = .generic_param,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = ppos,
                    .scope = self.current_scope,
                });
                try param_ids.append(self.ctx.allocator, param_sym_id);
            }
        }

        const owned_params = try self.ctx.arena.allocator().dupe(SymbolId, param_ids.items);
        self.ctx.symbols.items[generic_sym_id].type_params = owned_params;

        // M20b(3/5): walk members for `fun`/`sub` methods to open their
        // body scopes (same machinery as nominal `walkNominalType`).
        // Data fields don't push scopes; they're typed at pass 2.
        // Sigil-prefixed members (`?x`) are diagnosed at pass 2.
        for (items[3..]) |member| {
            if (member != .list or member.list.len == 0 or member.list[0] != .tag) continue;
            switch (member.list[0].tag) {
                .@"fun", .@"sub" => try self.walkMethod(member.list),
                else => {},
            }
        }
    }

    fn walkNominalType(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (struct name members) / (enum name members) / (errors name members) / (opaque name)
        if (items.len < 2) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const decl_pos = if (items[1] == .src) items[1].src.pos else 0;
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .nominal_type,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
        });

        // M20a: walk methods (fun/sub members) to open their function
        // body scopes and bind their params (including `self`). This
        // applies to all nominal forms (struct, enum, errors) so
        // receiver-style calls can find self-bound symbols. The methods
        // themselves are NOT added as module-scope function symbols —
        // they're recorded as `is_method = true` entries on the
        // nominal's `Symbol.fields` slice by `TypeResolver`.
        if (items.len > 2) {
            for (items[2..]) |member| {
                if (member != .list or member.list.len == 0 or member.list[0] != .tag) continue;
                switch (member.list[0].tag) {
                    .@"fun", .@"sub" => try self.walkMethod(member.list),
                    else => {},
                }
            }
        }
    }

    /// Like `walkFun` but for methods inside a nominal body: opens the
    /// body scope and binds params without adding a module-level
    /// function symbol. The method's signature lives in `Symbol.fields`
    /// (with `is_method = true`) populated by `TypeResolver`.
    fn walkMethod(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 3) return;
        const params = items[2];
        const body = items[items.len - 1];

        const fn_scope = try self.ctx.pushScope(self.current_scope);
        const prev_scope = self.current_scope;
        self.current_scope = fn_scope;
        defer self.current_scope = prev_scope;

        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }
        try self.walk(body);
    }

    fn walkExtern(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (extern <kind> name type) — kind ∈ { _, fixed }
        if (items.len < 4) return;
        const kind_slot = items[1];
        const name = identAt(self.ctx.source, items[2]) orelse return;
        const decl_pos = if (items[2] == .src) items[2].src.pos else 0;
        const fixed = kind_slot == .tag and kind_slot.tag == .fixed;
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .@"extern",
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
            .flags = .{ .fixed = fixed },
        });
    }

    /// `(set <kind> name type-or-_ expr)` — local binding. Only
    /// `default`, `fixed`, `shadow` introduce new locals; compound
    /// assigns and move-assign reuse an existing slot. The expression
    /// itself is walked for nested decls (e.g., a lambda inside RHS).
    fn walkSet(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 5) return;
        const kind = rig.bindingKindOf(items[1]) catch return;
        const target = items[2];
        const expr = items[4];

        // Always walk the expression first (RHS-first, matches ownership).
        try self.walk(expr);

        switch (kind) {
            .default => {
                // M20e(3/5): dedup. The original M5-era behavior added a
                // fresh symbol on every `rc = X` (relying on lookup's
                // reverse iteration to find the newest one). That works
                // for sema's own queries but produces an orphan (untyped)
                // first-symbol that downstream consumers (emit's
                // forward `handleKindOf` scan, print polish, etc.) trip
                // over. Reassignment in Rig source — `rc = X; rc = Y`
                // — semantically updates the existing slot, so the
                // resolver should reflect that.
                //
                // If a same-name symbol already exists in the current
                // scope, REUSE it. Outer-scope shadowing via `default`
                // kind is still possible (the inner scope's lookup
                // returns null for outer-only names → fresh symbol),
                // matching the M5/M20a semantics.
                const name = identAt(self.ctx.source, target) orelse return;
                if (self.ctx.lookupInScopeOnly(self.current_scope, name) != null) return;
                const decl_pos = if (target == .src) target.src.pos else 0;
                _ = try self.addSymbol(.{
                    .name = name,
                    .kind = .local,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = decl_pos,
                    .scope = self.current_scope,
                    .flags = .{},
                });
            },
            .fixed, .shadow => {
                // `=!` declares a fixed binding (Rig errors on
                // reassignment to it); `new x = ...` explicitly creates
                // a fresh slot that shadows any outer-scope name. Both
                // unconditionally add a new symbol — no dedup.
                const name = identAt(self.ctx.source, target) orelse return;
                const decl_pos = if (target == .src) target.src.pos else 0;
                const fixed = kind == .fixed;
                _ = try self.addSymbol(.{
                    .name = name,
                    .kind = .local,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = decl_pos,
                    .scope = self.current_scope,
                    .flags = .{ .fixed = fixed },
                });
            },
            // `<-` move and compound assigns mutate an existing slot —
            // no new symbol introduced.
            .@"move", .@"+=", .@"-=", .@"*=", .@"/=" => {},
        }
    }

    fn walkBlock(self: *SymbolResolver, stmts: []const Sexp) std.mem.Allocator.Error!void {
        const block_scope = try self.ctx.pushScope(self.current_scope);
        const prev = self.current_scope;
        self.current_scope = block_scope;
        defer self.current_scope = prev;
        for (stmts) |s| try self.walk(s);
    }

    fn walkFor(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (for <mode> binding1 binding2-or-_ source body else?)
        if (items.len < 6) return;
        const binding1 = items[2];
        const binding2 = items[3];
        const source = items[4];
        const body = items[5];

        try self.walk(source);

        const for_scope = try self.ctx.pushScope(self.current_scope);
        const prev = self.current_scope;
        self.current_scope = for_scope;
        defer self.current_scope = prev;

        if (identAt(self.ctx.source, binding1)) |name| {
            _ = try self.addSymbol(.{
                .name = name,
                .kind = .local,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = if (binding1 == .src) binding1.src.pos else 0,
                .scope = self.current_scope,
            });
        }
        if (identAt(self.ctx.source, binding2)) |name| {
            _ = try self.addSymbol(.{
                .name = name,
                .kind = .local,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = if (binding2 == .src) binding2.src.pos else 0,
                .scope = self.current_scope,
            });
        }

        try self.walk(body);
        if (items.len > 6) try self.walk(items[6]);
    }

    fn walkCatchBlock(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (catch_block err_name body)
        if (items.len < 3) return;
        const catch_scope = try self.ctx.pushScope(self.current_scope);
        const prev = self.current_scope;
        self.current_scope = catch_scope;
        defer self.current_scope = prev;
        if (identAt(self.ctx.source, items[1])) |name| {
            _ = try self.addSymbol(.{
                .name = name,
                .kind = .local,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = if (items[1] == .src) items[1].src.pos else 0,
                .scope = self.current_scope,
            });
        }
        try self.walk(items[2]);
    }

    fn walkArm(self: *SymbolResolver, items: []const Sexp) std.mem.Allocator.Error!void {
        // (arm pattern binding? body) — body is the last child.
        if (items.len < 2) return;
        const arm_scope = try self.ctx.pushScope(self.current_scope);
        const prev = self.current_scope;
        self.current_scope = arm_scope;
        defer self.current_scope = prev;

        // M10: extract pattern bindings into the arm scope so they're
        // visible in the body. Types start as `unknown_id` and are
        // refined by `ExprChecker.checkMatchStmt` against the
        // scrutinee's variant payload.
        //
        //   (variant_pattern circle r)        → binds `r`
        //   (variant_pattern triangle a b)    → binds `a` and `b`
        //   bare ident pattern (default arm)  → binds the ident
        //   (enum_lit X) / (enum_pattern X)   → no bindings
        const pattern = items[1];
        try self.bindPatternNames(pattern);

        try self.walk(items[items.len - 1]);
    }

    fn bindPatternNames(self: *SymbolResolver, pattern: Sexp) std.mem.Allocator.Error!void {
        switch (pattern) {
            .src => |s| {
                // Bare ident pattern → default arm with the ident as
                // the catch-all binding. Avoid binding `_` (which
                // conventionally means "ignore"); future range/literal
                // patterns will skip this branch via their list shape.
                const name = self.ctx.source[s.pos..][0..s.len];
                if (std.mem.eql(u8, name, "_")) return;
                _ = try self.addSymbol(.{
                    .name = name,
                    .kind = .local,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = s.pos,
                    .scope = self.current_scope,
                });
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return;
                if (items[0].tag != .@"variant_pattern") return;
                // (variant_pattern Name binding...). items[1] is the
                // variant name (a literal, not a binding); items[2..]
                // are the destructured payload bindings.
                for (items[2..]) |b| {
                    if (b != .src) continue;
                    const name = self.ctx.source[b.src.pos..][0..b.src.len];
                    if (std.mem.eql(u8, name, "_")) continue;
                    _ = try self.addSymbol(.{
                        .name = name,
                        .kind = .local,
                        .ty = self.ctx.types.unknown_id,
                        .decl_pos = b.src.pos,
                        .scope = self.current_scope,
                    });
                }
            },
            else => {},
        }
    }

    fn addSymbol(self: *SymbolResolver, sym: Symbol) std.mem.Allocator.Error!SymbolId {
        const id: SymbolId = @intCast(self.ctx.symbols.items.len);
        try self.ctx.symbols.append(self.ctx.allocator, sym);
        try self.ctx.scopes.items[sym.scope].symbols.append(self.ctx.allocator, id);
        return id;
    }

    /// M20b(5/5): like `addSymbol` but does NOT insert into the lexical
    /// scope's symbol list. Used for generic-param symbols
    /// (`.generic_param` kind) which are referenced by `Symbol.type_params`
    /// on the owning generic-type symbol and resolved via
    /// `NominalContext.type_params` — never via ordinary scope lookup.
    /// Per GPT-5.5 M20b post-implementation review: detaching prevents
    /// `T` from `type Box(T)` polluting module scope and colliding with
    /// `T` from `type Pair(T)`.
    fn addDetachedSymbol(self: *SymbolResolver, sym: Symbol) std.mem.Allocator.Error!SymbolId {
        const id: SymbolId = @intCast(self.ctx.symbols.items.len);
        try self.ctx.symbols.append(self.ctx.allocator, sym);
        return id;
    }
};

// =============================================================================
// Type Resolution
// =============================================================================
//
// After symbol resolution, walk the IR a second time to resolve every
// declared type Sexp into a `TypeId`. Updates `Symbol.ty` in place for
// each function (full function type), parameter (declared type), type
// alias (aliased type), and extern declaration (declared type).
//
// `resolveType(sexp, scope)` is the workhorse: walks a type Sexp and
// returns its interned `TypeId`. Recognizes:
//
//   - primitive type names → pre-interned ids in TypeStore
//     - `Int` / `Float` / `Bool` / `String` / `Void`
//     - sized: `I8`/`I16`/`I32`/`I64`/`U8`/`U16`/`U32`/`U64`/`F32`/`F64`
//   - nominal type names → `nominal(SymbolId)` if found in scope
//   - `(optional T)` / `(error_union T)` → wrap recursively
//   - `(borrow_read T)` / `(borrow_write T)` → wrap recursively
//   - `(slice T)` → slice
//   - `(array_type N T)` → fixed-size array (N parsed as u64)
//   - `(fn_type params returns)` → function type
//
// Unknown names produce a sema diagnostic and return `invalid_id` so
// downstream synthesis fails fast without cascading.

const TypeResolver = struct {
    ctx: *SemContext,

    /// M20a / M20b(3/5): enclosing nominal context when resolving
    /// method signatures or body annotations. Empty (`.none`) at
    /// module scope. For plain nominals, holds `{sym, nominal(sym),
    /// &.{}}`. For generic types, holds `{sym, parameterized_nominal(
    /// sym, [type_var(T_i)]), [T_i...]}` so `Self` and bare `T`
    /// resolve correctly inside the body.
    current_nominal: NominalContext = NominalContext.none,

    /// Walk top-level decls in the module scope and populate types.
    fn walk(self: *TypeResolver, ir: Sexp, module_scope: ScopeId) std.mem.Allocator.Error!void {
        if (ir != .list or ir.list.len == 0 or ir.list[0] != .tag) return;
        if (ir.list[0].tag != .@"module") return;

        // Walk each top-level declaration. The fn-scope cursor advances
        // alongside the symbol resolver did — we re-use scope ordering
        // to find each fn's body scope.
        var scope_cursor: ScopeId = module_scope + 1;
        for (ir.list[1..]) |child| {
            scope_cursor = try self.resolveDecl(child, module_scope, scope_cursor);
        }
    }

    /// Resolve a single top-level decl, advancing `scope_cursor` past
    /// any sub-scopes the decl owns. Returns the new cursor.
    fn resolveDecl(self: *TypeResolver, sexp: Sexp, parent_scope: ScopeId, scope_cursor: ScopeId) std.mem.Allocator.Error!ScopeId {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return scope_cursor;
        const items = sexp.list;
        switch (items[0].tag) {
            .@"pub" => {
                if (items.len >= 2) return self.resolveDecl(items[1], parent_scope, scope_cursor);
                return scope_cursor;
            },
            .@"fun", .@"sub" => return self.resolveFun(items, parent_scope, scope_cursor),
            .@"type" => {
                try self.resolveTypeAlias(items, parent_scope);
                return scope_cursor;
            },
            .@"extern" => {
                try self.resolveExtern(items, parent_scope);
                return scope_cursor;
            },
            .@"struct" => {
                // M20a: returns cursor advanced past method body scopes
                // pushed by SymbolResolver.walkMethod.
                return self.resolveStructFields(items, parent_scope, scope_cursor);
            },
            .@"enum", .@"errors" => {
                // IR shapes are identical: `(enum Name v...)` /
                // `(errors Name v...)`. Reuse the same variant
                // resolver so error-set declarations get fields too.
                // M20a: returns cursor advanced past method body scopes.
                return self.resolveEnumVariants(items, parent_scope, scope_cursor);
            },
            .@"generic_type" => {
                // M20b(3/5): generic type body resolution. Populates
                // `.fields` with type_var-bearing symbolic types and
                // advances cursor past method body scopes pushed by
                // SymbolResolver.walkGenericType.
                return self.resolveGenericTypeFields(items, parent_scope, scope_cursor);
            },
            .@"generic_enum" => {
                // M20c: generic enum body resolution. Reuses
                // `resolveEnumVariants` (which now branches on the
                // IR head to position variants at items[3..] and
                // set NominalContext for type_var resolution in
                // payload field types).
                return self.resolveEnumVariants(items, parent_scope, scope_cursor);
            },
            else => return scope_cursor,
        }
    }

    /// Walk a `(struct name members...)` / `(enum ...)` / `(errors ...)`
    /// declaration, resolving each `(: name type)` member into a `Field`
    /// and storing the field list on the nominal symbol.
    ///
    /// M6 v1 scope: structs only — enums and errors get an empty field
    /// list for now (their member shapes differ enough to deserve their
    /// own resolver in M7+).
    fn resolveStructFields(
        self: *TypeResolver,
        items: []const Sexp,
        parent_scope: ScopeId,
        scope_cursor: ScopeId,
    ) std.mem.Allocator.Error!ScopeId {
        if (items.len < 2) return scope_cursor;
        const name = identAt(self.ctx.source, items[1]) orelse return scope_cursor;
        const sym_id = self.ctx.lookup(parent_scope, name) orelse return scope_cursor;

        // Only structs get fields populated for now.
        if (items[0].tag != .@"struct") return scope_cursor;

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);

        var cursor = scope_cursor;
        for (items[2..]) |member| {
            if (member != .list or member.list.len < 2 or member.list[0] != .tag) continue;
            switch (member.list[0].tag) {
                // Data field: (: name type) or (: name type default)
                .@":" => {
                    if (member.list.len < 3) continue;
                    const fname_node = member.list[1];
                    const ftype_node = member.list[2];
                    const fname = identAt(self.ctx.source, fname_node) orelse continue;
                    const ftype = try self.resolveType(ftype_node, parent_scope);
                    try fields.append(self.ctx.allocator, .{
                        .name = fname,
                        .ty = ftype,
                        .decl_pos = if (fname_node == .src) fname_node.src.pos else 0,
                    });
                },
                // M12/M20a: method declaration. Resolve its function
                // type and record it as a method-flagged Field on the
                // struct symbol. M20a: write each param symbol's `ty`
                // back so the method body's `self.name`-style accesses
                // type correctly, and advance the cursor past the
                // method body's scope (pushed by SymbolResolver in
                // M20a).
                .@"fun", .@"sub" => {
                    cursor = try self.resolveNominalMethod(member.list, parent_scope, sym_id, cursor, &fields);
                },
                // M20a.2: sigil-prefixed sugar (`?name` / `!name`) is
                // ONLY valid as a method's `self` parameter. The
                // grammar's `field` production is reused for nominal
                // members, so `struct S { ?x }` parses to a `(read x)`
                // member that the prior `else => {}` silently dropped.
                // Diagnose it cleanly instead.
                .@"read", .@"write" => {
                    try self.err(
                        paramPos(member, 0),
                        "sigil-prefixed member (`?{s}` / `!{s}`) is not allowed in a nominal body; sigil-prefix sugar is only valid for the `self` parameter of a method",
                        .{
                            if (member.list.len >= 2) identAt(self.ctx.source, member.list[1]) orelse "name" else "name",
                            if (member.list.len >= 2) identAt(self.ctx.source, member.list[1]) orelse "name" else "name",
                        },
                    );
                },
                else => {},
            }
        }

        const owned = try self.ctx.arena.allocator().dupe(Field, fields.items);
        self.ctx.symbols.items[sym_id].fields = owned;
        return cursor;
    }

    /// M20b(3/5): walk a `(generic_type Name (T...) members...)`
    /// declaration. Populates `.fields` with type-var-bearing symbolic
    /// types (data fields get their declared type with `T` resolved
    /// to `type_var(T_sym)`; methods get their function type with the
    /// same symbolic types in params/return). Advances scope_cursor
    /// past method body scopes pushed by `SymbolResolver.walkGenericType`.
    fn resolveGenericTypeFields(
        self: *TypeResolver,
        items: []const Sexp,
        parent_scope: ScopeId,
        scope_cursor: ScopeId,
    ) std.mem.Allocator.Error!ScopeId {
        if (items.len < 3) return scope_cursor;
        const name = identAt(self.ctx.source, items[1]) orelse return scope_cursor;
        const sym_id = self.ctx.lookup(parent_scope, name) orelse return scope_cursor;

        // Set NominalContext so resolveType in field/method signatures
        // resolves `T` → type_var(T_sym) and `Self` → parameterized_nominal.
        const prev_nominal = self.current_nominal;
        self.current_nominal = try makeNominalContext(self.ctx, sym_id);
        defer self.current_nominal = prev_nominal;

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);

        var cursor = scope_cursor;
        // Members start at items[3] for generic_type
        // (items[0]=tag, items[1]=name, items[2]=params, items[3..]=members).
        for (items[3..]) |member| {
            if (member != .list or member.list.len < 2 or member.list[0] != .tag) continue;
            switch (member.list[0].tag) {
                // Data field: (: name type) or (: name type default)
                .@":" => {
                    if (member.list.len < 3) continue;
                    const fname_node = member.list[1];
                    const ftype_node = member.list[2];
                    const fname = identAt(self.ctx.source, fname_node) orelse continue;
                    const ftype = try self.resolveType(ftype_node, parent_scope);
                    try fields.append(self.ctx.allocator, .{
                        .name = fname,
                        .ty = ftype,
                        .decl_pos = if (fname_node == .src) fname_node.src.pos else 0,
                    });
                },
                // M20b(3/5): generic methods. Same resolveNominalMethod
                // machinery — it already threads current_nominal for
                // Self / type-var resolution.
                .@"fun", .@"sub" => {
                    cursor = try self.resolveNominalMethod(member.list, parent_scope, sym_id, cursor, &fields);
                },
                // M20a.2: sigil-prefixed sugar at member position is
                // rejected for nominals; same for generic types.
                .@"read", .@"write" => {
                    try self.err(
                        paramPos(member, 0),
                        "sigil-prefixed member (`?{s}` / `!{s}`) is not allowed in a generic type body; sigil-prefix sugar is only valid for the `self` parameter of a method",
                        .{
                            if (member.list.len >= 2) identAt(self.ctx.source, member.list[1]) orelse "name" else "name",
                            if (member.list.len >= 2) identAt(self.ctx.source, member.list[1]) orelse "name" else "name",
                        },
                    );
                },
                else => {},
            }
        }

        const owned = try self.ctx.arena.allocator().dupe(Field, fields.items);
        self.ctx.symbols.items[sym_id].fields = owned;
        return cursor;
    }

    /// Resolve a `fun`/`sub` method member of a nominal (struct or
    /// enum) body. Interns the function type, writes each param
    /// symbol's `ty` back into the method body's scope (so `self.name`
    /// inside the body types correctly), and advances the scope cursor
    /// past the method body's scopes. Used by both `resolveStructFields`
    /// and `resolveEnumVariants` (M20a).
    fn resolveNominalMethod(
        self: *TypeResolver,
        items: []const Sexp,
        parent_scope: ScopeId,
        nominal_sym: SymbolId,
        scope_cursor: ScopeId,
        fields: *std.ArrayListUnmanaged(Field),
    ) std.mem.Allocator.Error!ScopeId {
        if (items.len < 5) return scope_cursor;
        const is_sub = items[0].tag == .@"sub";
        const name_node = items[1];
        const params = items[2];
        const returns_node: Sexp = if (is_sub) .{ .nil = {} } else items[3];
        const mname = identAt(self.ctx.source, name_node) orelse return scope_cursor;
        const mpos: u32 = if (name_node == .src) name_node.src.pos else 0;

        // Enclosing nominal is in scope for `Self` and (for generics)
        // `T` resolution. M20b(3/5): NominalContext is now a struct
        // carrying both the SymbolId AND the precomputed self_type
        // and type_params, so generic methods see the right Self.
        const prev_nominal = self.current_nominal;
        self.current_nominal = try makeNominalContext(self.ctx, nominal_sym);
        defer self.current_nominal = prev_nominal;

        // The method body scope was pushed by SymbolResolver.walkMethod
        // (M20a); it's the next cursor.
        const fn_scope = scope_cursor;

        const return_ty: TypeId = if (is_sub or returns_node == .nil)
            self.ctx.types.void_id
        else
            try self.resolveType(returns_node, parent_scope);

        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        if (params == .list) {
            for (params.list) |p| {
                const ptype = try self.resolveParamType(p, parent_scope);
                try param_types.append(self.ctx.allocator, ptype);
                // M20a: write the resolved param type back into the
                // symbol the SymbolResolver bound in the body scope.
                // Without this, `self` inside the body types as
                // `unknown` and `self.name` collapses to unknown.
                const pname = paramName(self.ctx.source, p);
                if (pname) |nm| {
                    if (self.ctx.lookup(fn_scope, nm)) |sym_id| {
                        self.ctx.symbols.items[sym_id].ty = ptype;
                    }
                }
            }
        }

        // M20a.2: determine MethodReceiver from params[0] and validate
        // self position + type. Without this, `synthInstanceCall` would
        // (incorrectly) treat any first-param method as an instance
        // method, silently dispatching associated/static methods called
        // with receiver-style syntax.
        var receiver_mode: MethodReceiver = .none;
        if (params == .list and params.list.len > 0) {
            for (params.list, 0..) |p, i| {
                const pname = paramName(self.ctx.source, p);
                const is_named_self = if (pname) |nm| std.mem.eql(u8, nm, "self") else false;
                const is_sugar = blk: {
                    if (p == .list and p.list.len >= 1 and p.list[0] == .tag) {
                        switch (p.list[0].tag) {
                            .@"read", .@"write" => break :blk true,
                            else => {},
                        }
                    }
                    break :blk false;
                };

                // M20a.2: `self` only allowed at param[0].
                if (is_named_self and i != 0) {
                    try self.err(
                        paramPos(p, mpos),
                        "`self` must be the first parameter of a method",
                        .{},
                    );
                }

                // M20a.2: `?self` / `!self` sugar only allowed at
                // param[0]. (resolveParamType already rejected non-self
                // names; this catches `?self` / `!self` in second+
                // position.)
                if (is_sugar and i != 0) {
                    try self.err(
                        paramPos(p, mpos),
                        "sigil-prefixed parameter sugar (`?self` / `!self`) is only allowed at the first parameter position",
                        .{},
                    );
                }
            }

            // Classify receiver from param[0] if it's `self`.
            const first = params.list[0];
            const first_pname = paramName(self.ctx.source, first);
            const first_is_self = if (first_pname) |nm| std.mem.eql(u8, nm, "self") else false;
            if (first_is_self) {
                const ptype_id = param_types.items[0];
                const ptype = self.ctx.types.get(ptype_id);
                const nom_name = self.ctx.symbols.items[nominal_sym].name;
                switch (ptype) {
                    .borrow_read => |inner| {
                        if (isSelfTypeId(self.ctx, inner, self.current_nominal)) {
                            receiver_mode = .read;
                        } else {
                            try self.err(mpos, "`self` receiver type must be `?Self` or `?{s}`", .{nom_name});
                        }
                    },
                    .borrow_write => |inner| {
                        if (isSelfTypeId(self.ctx, inner, self.current_nominal)) {
                            receiver_mode = .write;
                        } else {
                            try self.err(mpos, "`self` receiver type must be `!Self` or `!{s}`", .{nom_name});
                        }
                    },
                    .nominal => {
                        if (isSelfTypeId(self.ctx, ptype_id, self.current_nominal)) {
                            receiver_mode = .value;
                        } else {
                            try self.err(mpos, "`self` receiver type must be `Self` or `{s}`", .{nom_name});
                        }
                    },
                    .parameterized_nominal => {
                        // M20b(3/5): for generic methods, `self: Self`
                        // resolves to `parameterized_nominal(sym, [type_var(T)])`
                        // — that's an isSelfType match for a by-value receiver.
                        if (isSelfTypeId(self.ctx, ptype_id, self.current_nominal)) {
                            receiver_mode = .value;
                        } else {
                            try self.err(mpos, "`self` receiver type must be `Self` or `{s}`", .{nom_name});
                        }
                    },
                    .unknown, .invalid => {
                        // M20a.2 (per GPT-5.5 pre-commit review):
                        // distinguish bare untyped `self` (`fun foo(self)`)
                        // from `self: T` where T didn't resolve. Bare
                        // untyped `self` in first position is a hard
                        // error — once `self` is special enough to power
                        // receiver metadata, it must not silently become
                        // an ordinary associated-method param. Users
                        // wanting a by-value receiver should write
                        // `self: Self` or `self: <Nominal>` explicitly;
                        // bare-`self` sugar is deliberately deferred.
                        if (first == .src) {
                            try self.err(
                                paramPos(first, mpos),
                                "`self` parameter requires an explicit receiver type; use `?self`, `!self`, or `self: Self`",
                                .{},
                            );
                        }
                        // For `self: SomeUnresolvedType`, leave
                        // receiver_mode = .none silently — the type
                        // resolver already fired a diagnostic for the
                        // unresolved name (or will, when M5 v1's
                        // deferred-diagnostic policy tightens).
                    },
                    else => {
                        try self.err(mpos, "`self` receiver type must be `?Self`, `!Self`, `Self`, or an explicit `{s}` form", .{nom_name});
                    },
                }
            }
        }

        const owned_params = try self.ctx.arena.allocator().dupe(TypeId, param_types.items);
        const fn_ty = try self.ctx.types.intern(self.ctx.allocator, .{ .function = .{
            .params = owned_params,
            .returns = return_ty,
            .is_sub = is_sub,
        } });

        try fields.append(self.ctx.allocator, .{
            .name = mname,
            .ty = fn_ty,
            .decl_pos = mpos,
            .is_method = true,
            .receiver = receiver_mode,
        });

        // Advance past this method's body scopes — same machinery
        // `resolveFun` uses for top-level functions.
        return scopeAfter(self.ctx, fn_scope);
    }

    /// Walk an enum or errors declaration and store one `Field` per
    /// variant. Variant shapes:
    ///
    ///   bare `red`               → ty=void_id, payload=null
    ///   valued `ok = 0`          → ty=void_id, payload=null (value
    ///                              propagates verbatim through emit)
    ///   payload `circle(r: Int)` → ty=void_id, payload=[Field{r, Int}]
    ///                              (M9a: declared + lowered;
    ///                              construction in M9b+)
    fn resolveEnumVariants(
        self: *TypeResolver,
        items: []const Sexp,
        parent_scope: ScopeId,
        scope_cursor: ScopeId,
    ) std.mem.Allocator.Error!ScopeId {
        if (items.len < 2) return scope_cursor;
        const name = identAt(self.ctx.source, items[1]) orelse return scope_cursor;
        const sym_id = self.ctx.lookup(parent_scope, name) orelse return scope_cursor;

        // M20c: `(generic_enum Name (params) variants...)` has its
        // variants at items[3..] (after name and params). Plain
        // `(enum/errors Name variants...)` has them at items[2..].
        // Set NominalContext for the generic case so payload field
        // types with bare `T` resolve to `type_var(T_sym)` and
        // `Self` resolves to `parameterized_nominal(sym, [type_var(T)])`.
        const head = items[0].tag;
        const is_generic = head == .@"generic_enum";
        const variants_start: usize = if (is_generic) 3 else 2;
        if (items.len <= variants_start) {
            // No variants — empty enum body. Still populate `.fields`
            // with `&.{}` so downstream lookups don't mistake this
            // for an opaque (unresolved) nominal.
            const owned = try self.ctx.arena.allocator().dupe(Field, &.{});
            self.ctx.symbols.items[sym_id].fields = owned;
            return scope_cursor;
        }

        const prev_nominal = self.current_nominal;
        if (is_generic) {
            self.current_nominal = try makeNominalContext(self.ctx, sym_id);
        }
        defer self.current_nominal = prev_nominal;

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);

        var cursor = scope_cursor;
        for (items[variants_start..]) |variant| {
            // M20a: enum methods (fun/sub members) get the same
            // `is_method = true` Field treatment as struct methods.
            // M20a.2: also catch sigil-prefixed sugar at member
            // position (which the grammar's reused `field` production
            // accepts; without this diagnostic the member is silently
            // dropped).
            if (variant == .list and variant.list.len > 0 and variant.list[0] == .tag) {
                switch (variant.list[0].tag) {
                    .@"fun", .@"sub" => {
                        cursor = try self.resolveNominalMethod(variant.list, parent_scope, sym_id, cursor, &fields);
                        continue;
                    },
                    .@"read", .@"write" => {
                        try self.err(
                            paramPos(variant, 0),
                            "sigil-prefixed member (`?{s}` / `!{s}`) is not allowed in a nominal body; sigil-prefix sugar is only valid for the `self` parameter of a method",
                            .{
                                if (variant.list.len >= 2) identAt(self.ctx.source, variant.list[1]) orelse "name" else "name",
                                if (variant.list.len >= 2) identAt(self.ctx.source, variant.list[1]) orelse "name" else "name",
                            },
                        );
                        continue;
                    },
                    else => {},
                }
            }
            switch (variant) {
                .src => |s| {
                    // M20c: mark bare-variant Fields with is_variant=true.
                    try fields.append(self.ctx.allocator, .{
                        .name = self.ctx.source[s.pos..][0..s.len],
                        .ty = self.ctx.types.void_id,
                        .decl_pos = s.pos,
                        .is_variant = true,
                    });
                },
                .list => |sub| {
                    if (sub.len < 2 or sub[0] != .tag) continue;
                    switch (sub[0].tag) {
                        // (valued name expr) — keep the variant name;
                        // ignore the value (emit handles it verbatim).
                        .@"valued" => {
                            const vname_node = sub[1];
                            if (identAt(self.ctx.source, vname_node)) |vname| {
                                try fields.append(self.ctx.allocator, .{
                                    .name = vname,
                                    .ty = self.ctx.types.void_id,
                                    .decl_pos = if (vname_node == .src) vname_node.src.pos else 0,
                                    .is_variant = true,
                                });
                            }
                        },
                        // (variant name params) — payload variant.
                        // Resolve each param to a Field and store as
                        // the variant's payload.
                        .@"variant" => {
                            if (sub.len < 3) continue;
                            const vname_node = sub[1];
                            const params_node = sub[2];
                            const vname = identAt(self.ctx.source, vname_node) orelse continue;
                            const vpos: u32 = if (vname_node == .src) vname_node.src.pos else 0;

                            var payload: std.ArrayListUnmanaged(Field) = .empty;
                            defer payload.deinit(self.ctx.allocator);
                            if (params_node == .list) {
                                for (params_node.list) |p| {
                                    // Each param is `(: name type)` etc.
                                    if (p != .list or p.list.len < 3 or p.list[0] != .tag) continue;
                                    if (p.list[0].tag != .@":") continue;
                                    const fname_node = p.list[1];
                                    const ftype_node = p.list[2];
                                    const fname = identAt(self.ctx.source, fname_node) orelse continue;
                                    const ftype = try self.resolveType(ftype_node, parent_scope);
                                    try payload.append(self.ctx.allocator, .{
                                        .name = fname,
                                        .ty = ftype,
                                        .decl_pos = if (fname_node == .src) fname_node.src.pos else 0,
                                    });
                                }
                            }
                            const owned_payload = try self.ctx.arena.allocator().dupe(Field, payload.items);
                            try fields.append(self.ctx.allocator, .{
                                .name = vname,
                                .ty = self.ctx.types.void_id,
                                .decl_pos = vpos,
                                .payload = owned_payload,
                                .is_variant = true,
                            });
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        const owned = try self.ctx.arena.allocator().dupe(Field, fields.items);
        self.ctx.symbols.items[sym_id].fields = owned;
        return cursor;
    }

    fn resolveFun(self: *TypeResolver, items: []const Sexp, parent_scope: ScopeId, scope_cursor: ScopeId) std.mem.Allocator.Error!ScopeId {
        if (items.len < 5) return scope_cursor;
        const is_sub = items[0].tag == .@"sub";
        const name_node = items[1];
        const params = items[2];
        const returns_node: Sexp = if (is_sub) .{ .nil = {} } else items[3];

        // The fn's own body scope was the next one created by symbol
        // resolution. Use it for nominal lookups in the signature too,
        // so generic params (when added later) resolve correctly.
        const fn_scope = scope_cursor;

        // Resolve return type.
        const return_ty: TypeId = if (is_sub)
            self.ctx.types.void_id
        else if (returns_node == .nil)
            self.ctx.types.void_id
        else
            try self.resolveType(returns_node, parent_scope);

        // Resolve param types and write each back into its symbol's `ty`.
        const param_count: usize = if (params == .list) params.list.len else 0;
        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        try param_types.ensureTotalCapacity(self.ctx.allocator, param_count);

        if (params == .list) {
            for (params.list) |p| {
                const ptype = try self.resolveParamType(p, parent_scope);
                param_types.appendAssumeCapacity(ptype);
                // Find the symbol for this param in fn_scope and update.
                const pname = paramName(self.ctx.source, p);
                if (pname) |nm| {
                    if (self.ctx.lookup(fn_scope, nm)) |sym_id| {
                        self.ctx.symbols.items[sym_id].ty = ptype;
                    }
                }
            }
        }

        // Build the function type and update the fn symbol.
        const owned_params = try self.ctx.arena.allocator().dupe(TypeId, param_types.items);
        const fn_ty = try self.ctx.types.intern(self.ctx.allocator, .{ .function = .{
            .params = owned_params,
            .returns = return_ty,
            .is_sub = is_sub,
        } });
        if (identAt(self.ctx.source, name_node)) |nm| {
            if (self.ctx.lookup(parent_scope, nm)) |sym_id| {
                self.ctx.symbols.items[sym_id].ty = fn_ty;
            }
        }

        // Skip past this fn's scopes. Counting is fragile in general,
        // but symbol resolution opens scopes in a deterministic order,
        // so we advance `scope_cursor` to the next module-level decl
        // by counting scopes opened during this fn's walk.
        return scopeAfter(self.ctx, fn_scope);
    }

    fn resolveTypeAlias(self: *TypeResolver, items: []const Sexp, parent_scope: ScopeId) std.mem.Allocator.Error!void {
        // (type name typeexpr)
        if (items.len < 3) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const ty = try self.resolveType(items[2], parent_scope);
        if (self.ctx.lookup(parent_scope, name)) |sym_id| {
            self.ctx.symbols.items[sym_id].ty = ty;
        }
    }

    fn resolveExtern(self: *TypeResolver, items: []const Sexp, parent_scope: ScopeId) std.mem.Allocator.Error!void {
        // (extern <kind> name type)
        if (items.len < 4) return;
        const name = identAt(self.ctx.source, items[2]) orelse return;
        const ty = try self.resolveType(items[3], parent_scope);
        if (self.ctx.lookup(parent_scope, name)) |sym_id| {
            self.ctx.symbols.items[sym_id].ty = ty;
        }
    }

    /// Resolve the declared type of a parameter Sexp. Returns
    /// `unknown_id` for untyped params (`name` only) — declared params
    /// without an explicit type are an error in V1, but we report that
    /// from the symbol resolver, not here.
    fn resolveParamType(self: *TypeResolver, param: Sexp, scope: ScopeId) std.mem.Allocator.Error!TypeId {
        switch (param) {
            .src => return self.ctx.types.unknown_id, // bare name, untyped
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return self.ctx.types.unknown_id;
                switch (items[0].tag) {
                    .@":" => if (items.len >= 3) return self.resolveType(items[2], scope),
                    .@"pre_param" => if (items.len >= 3) return self.resolveType(items[2], scope),
                    // M20a.1: `?self` / `!self` sugar. Type resolves to
                    // `(borrow_read|borrow_write) nominal(current_nominal)`.
                    // Validate that the wrapped name is literally `self`
                    // and that we're inside a nominal body. Otherwise
                    // fire a diagnostic and return invalid.
                    .@"read", .@"write" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const name = identAt(self.ctx.source, items[1]) orelse return self.ctx.types.invalid_id;
                        const pos: u32 = if (items[1] == .src) items[1].src.pos else 0;
                        if (!std.mem.eql(u8, name, "self")) {
                            try self.err(pos, "sigil-prefixed parameter is only allowed for `self`; for other parameters use `{s}: ?Type` / `{s}: !Type`", .{ name, name });
                            return self.ctx.types.invalid_id;
                        }
                        if (self.current_nominal.isEmpty()) {
                            try self.err(pos, "`{s}self` is only allowed in a method body (inside a struct, enum, or errors declaration)", .{
                                if (items[0].tag == .@"read") "?" else "!",
                            });
                            return self.ctx.types.invalid_id;
                        }
                        // M20b(3/5): use NominalContext.self_type so
                        // generic methods get `?Box(T)` rather than the
                        // bare nominal — keeps `?self` symbolic for
                        // generic-body checking.
                        const self_ty = self.current_nominal.self_type;
                        const wrap_payload = if (items[0].tag == .@"read")
                            Type{ .borrow_read = self_ty }
                        else
                            Type{ .borrow_write = self_ty };
                        return try self.ctx.types.intern(self.ctx.allocator, wrap_payload);
                    },
                    else => {},
                }
                return self.ctx.types.unknown_id;
            },
            else => return self.ctx.types.unknown_id,
        }
    }

    /// The workhorse: type Sexp → `TypeId`.
    fn resolveType(self: *TypeResolver, sexp: Sexp, scope: ScopeId) std.mem.Allocator.Error!TypeId {
        switch (sexp) {
            .nil => return self.ctx.types.void_id,
            .src => |s| {
                const name = self.ctx.source[s.pos..][0..s.len];
                if (primitiveTypeId(self.ctx, name)) |id| return id;
                if (sizedIntTypeId(self.ctx, name)) |id| return id;
                if (sizedFloatTypeId(self.ctx, name)) |id| return id;
                // M20a / M20b(3/5): `Self` inside a nominal context
                // resolves to the context's cached self_type
                // (`nominal(sym)` for plain, `parameterized_nominal(
                // sym, [type_var(T)])` for generics).
                if (!self.current_nominal.isEmpty()) {
                    if (std.mem.eql(u8, name, "Self")) {
                        return self.current_nominal.self_type;
                    }
                    // M20b(3/5): bare generic param `T` inside the
                    // generic body resolves to `type_var(T_sym)`.
                    // Looked up via NominalContext.type_params rather
                    // than the lexical scope so on-the-fly
                    // TypeResolvers (e.g., constructed by checkSet for
                    // body annotations) still find them.
                    for (self.current_nominal.type_params) |tp_sym| {
                        const tp = self.ctx.symbols.items[tp_sym];
                        if (std.mem.eql(u8, tp.name, name)) {
                            return self.ctx.types.intern(self.ctx.allocator, .{ .type_var = tp_sym });
                        }
                    }
                }
                if (self.ctx.lookup(scope, name)) |sym_id| {
                    const sym = self.ctx.symbols.items[sym_id];
                    if (sym.kind == .nominal_type or sym.kind == .type_alias) {
                        return self.ctx.types.intern(self.ctx.allocator, .{ .nominal = sym_id });
                    }
                    // M20b(5/5) per GPT-5.5: bare `Box` (a generic_type)
                    // in type position requires type arguments —
                    // `x: Box` should error, only `x: Box(Int)` is
                    // valid. Return invalid_id; the use site fires
                    // the diagnostic.
                    if (sym.kind == .generic_type) {
                        try self.err(s.pos, "generic type `{s}` requires type arguments; write `{s}(T)`", .{ name, name });
                        return self.ctx.types.invalid_id;
                    }
                    // Generic-param symbols are detached (per M20b(5/5)
                    // post-implementation review) — they're resolved
                    // via NominalContext.type_params above, not via
                    // ordinary lexical lookup. If we reach here with
                    // a generic_param symbol, it's a code-path bug.
                }
                // Unknown type name. M5 v1 doesn't have a module
                // system / forward declarations / generic-param scope
                // yet, so undeclared names are common in idiomatic Rig
                // (e.g., `User` in showcase.rig). Return `invalid_id`
                // silently for now — the diagnostic will return once
                // type-driven expression checking lands and can produce
                // useful errors at the *use* site.
                return self.ctx.types.invalid_id;
            },
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return self.ctx.types.invalid_id;
                switch (items[0].tag) {
                    .@"optional" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .optional = inner });
                    },
                    .@"error_union" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .fallible = inner });
                    },
                    .@"borrow_read" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .borrow_read = inner });
                    },
                    .@"borrow_write" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .borrow_write = inner });
                    },
                    // M20d: `*T` and `~T` in type position. Distinct
                    // tags from the expression-position `(share x)`
                    // form (which keeps the M3 `share` tag) — see
                    // src/rig.zig's Tag enum for the rationale.
                    //
                    // M20d(4/5) per GPT-5.5: reject nested shared
                    // (`**T`) — two layers of refcount indirection
                    // serve no V1 use case and the type would be a
                    // surprise to read. Single `*T` is always what the
                    // user meant. `*?T` (shared-of-borrow) and `*T?`
                    // (shared-of-optional) are NOT rejected; both are
                    // structurally meaningful.
                    .@"shared" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        const inner_ty = self.ctx.types.get(inner);
                        if (inner_ty == .shared) {
                            // Best-effort pos: the inner tag node or the wrapper's first src.
                            const pos = firstSrcPos(items[1]);
                            try self.err(pos, "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                            return self.ctx.types.invalid_id;
                        }
                        return self.ctx.types.intern(self.ctx.allocator, .{ .shared = inner });
                    },
                    .@"weak" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const inner = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .weak = inner });
                    },
                    .@"slice" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const elem = try self.resolveType(items[1], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .slice = .{ .elem = elem } });
                    },
                    .@"array_type" => {
                        // (array_type N T)
                        if (items.len < 3) return self.ctx.types.invalid_id;
                        const len = parseIntegerLiteral(self.ctx.source, items[1]) orelse 0;
                        const elem = try self.resolveType(items[2], scope);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .array = .{
                            .elem = elem,
                            .len = len,
                        } });
                    },
                    .@"fn_type" => {
                        // (fn_type params returns) — params is a list of types.
                        if (items.len < 3) return self.ctx.types.invalid_id;
                        var ps: std.ArrayListUnmanaged(TypeId) = .empty;
                        defer ps.deinit(self.ctx.allocator);
                        if (items[1] == .list) {
                            for (items[1].list) |p| {
                                try ps.append(self.ctx.allocator, try self.resolveType(p, scope));
                            }
                        }
                        const ret = try self.resolveType(items[2], scope);
                        const owned = try self.ctx.arena.allocator().dupe(TypeId, ps.items);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .function = .{
                            .params = owned,
                            .returns = ret,
                            .is_sub = false,
                        } });
                    },
                    // M20b(4/5): `(generic_inst Name T1 T2 ...)` — a
                    // fully-applied generic type instantiation. Resolve
                    // `Name` to a `generic_type` Symbol, recursively
                    // resolve each type arg, intern as
                    // `parameterized_nominal{sym, args}`. The interner
                    // guarantees `Box(Int)` is always the same TypeId.
                    //
                    // Arity validation: error if the supplied count
                    // doesn't match the generic's declared type_params.
                    .@"generic_inst" => {
                        if (items.len < 2) return self.ctx.types.invalid_id;
                        const name_node = items[1];
                        const name = identAt(self.ctx.source, name_node) orelse return self.ctx.types.invalid_id;
                        const pos: u32 = if (name_node == .src) name_node.src.pos else 0;
                        const sym_id = self.ctx.lookup(scope, name) orelse {
                            try self.err(pos, "unknown type `{s}`", .{name});
                            return self.ctx.types.invalid_id;
                        };
                        const sym = self.ctx.symbols.items[sym_id];
                        if (sym.kind != .generic_type) {
                            try self.err(pos, "`{s}` is not a generic type", .{name});
                            return self.ctx.types.invalid_id;
                        }
                        const expected_count = if (sym.type_params) |tps| tps.len else 0;
                        const supplied = items[2..];
                        if (supplied.len != expected_count) {
                            try self.err(pos, "generic type `{s}` expects {d} type argument{s}, got {d}", .{
                                name,
                                expected_count,
                                if (expected_count == 1) @as([]const u8, "") else "s",
                                supplied.len,
                            });
                            return self.ctx.types.invalid_id;
                        }
                        var arg_ids: std.ArrayListUnmanaged(TypeId) = .empty;
                        defer arg_ids.deinit(self.ctx.allocator);
                        try arg_ids.ensureTotalCapacity(self.ctx.allocator, supplied.len);
                        for (supplied) |arg| {
                            arg_ids.appendAssumeCapacity(try self.resolveType(arg, scope));
                        }

                        // M20f: Cell(T) is a built-in nominal with a
                        // hard V1 restriction — T must be a Copy type.
                        // Non-Copy T would let `Cell.set` corrupt
                        // ownership (overwriting a `*User` without
                        // dropping the previous handle, etc.).
                        // Deferred until V1 grows replace/take/Drop.
                        if (sym_id == self.ctx.cell_sym_id and supplied.len == 1) {
                            const arg_ty = arg_ids.items[0];
                            // Allow unknown/invalid to slide silently
                            // (some upstream resolution failed; don't
                            // double-fault).
                            const is_known = arg_ty != self.ctx.types.unknown_id and
                                arg_ty != self.ctx.types.invalid_id;
                            if (is_known and !isCopyTypeForCell(self.ctx, arg_ty)) {
                                const ty_str = try formatType(self.ctx, arg_ty);
                                try self.err(pos, "`Cell(T)` in V1 requires `T` to be a Copy type (Int, Bool, Float, String); got `{s}`. Non-Copy `Cell(T)` requires replace/take/Drop semantics and is deferred to a later milestone.", .{ty_str});
                                return self.ctx.types.invalid_id;
                            }
                        }

                        const owned = try self.ctx.arena.allocator().dupe(TypeId, arg_ids.items);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .parameterized_nominal = .{
                            .sym = sym_id,
                            .args = owned,
                        } });
                    },
                    else => return self.ctx.types.invalid_id,
                }
            },
            else => return self.ctx.types.invalid_id,
        }
    }

    fn err(self: *TypeResolver, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.ctx.arena.allocator(), fmt, args);
        try self.ctx.diagnostics.append(self.ctx.allocator, .{
            .severity = .@"error",
            .pos = pos,
            .message = msg,
        });
    }
};

fn primitiveTypeId(ctx: *const SemContext, name: []const u8) ?TypeId {
    if (std.mem.eql(u8, name, "Int")) return ctx.types.int_id;
    if (std.mem.eql(u8, name, "Float")) return ctx.types.float_id;
    if (std.mem.eql(u8, name, "Bool")) return ctx.types.bool_id;
    if (std.mem.eql(u8, name, "String")) return ctx.types.string_id;
    if (std.mem.eql(u8, name, "Void")) return ctx.types.void_id;
    return null;
}

fn sizedIntTypeId(ctx: *SemContext, name: []const u8) ?TypeId {
    const Pair = struct { name: []const u8, bits: u8, signed: bool };
    const pairs = [_]Pair{
        .{ .name = "I8", .bits = 8, .signed = true },
        .{ .name = "I16", .bits = 16, .signed = true },
        .{ .name = "I32", .bits = 32, .signed = true },
        .{ .name = "I64", .bits = 64, .signed = true },
        .{ .name = "U8", .bits = 8, .signed = false },
        .{ .name = "U16", .bits = 16, .signed = false },
        .{ .name = "U32", .bits = 32, .signed = false },
        .{ .name = "U64", .bits = 64, .signed = false },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p.name)) {
            return ctx.types.intern(ctx.allocator, .{ .int = .{ .bits = p.bits, .signed = p.signed } }) catch null;
        }
    }
    return null;
}

fn sizedFloatTypeId(ctx: *SemContext, name: []const u8) ?TypeId {
    if (std.mem.eql(u8, name, "F32")) return ctx.types.intern(ctx.allocator, .{ .float = .{ .bits = 32 } }) catch null;
    if (std.mem.eql(u8, name, "F64")) return ctx.types.intern(ctx.allocator, .{ .float = .{ .bits = 64 } }) catch null;
    return null;
}

/// Find the next scope id at or above `from_scope` whose parent is the
/// module scope (i.e., the next top-level decl's scope). Used by
/// `resolveFun` to skip over a function's nested scopes when walking
/// module-level decls in order.
fn scopeAfter(ctx: *const SemContext, from_scope: ScopeId) ScopeId {
    const total: ScopeId = @intCast(ctx.scopes.items.len);
    var s: ScopeId = from_scope + 1;
    while (s < total) : (s += 1) {
        const scope = &ctx.scopes.items[s];
        if (scope.parent) |p| {
            // Module scope is 1; its children are top-level decl scopes.
            if (p == 1) return s;
        }
    }
    return total;
}

/// M20a / M20a.2: classify a receiver expression's "shape" at the call
/// site, used by `checkReceiverMode` to enforce visible-effects rules.
///
/// Per GPT-5.5's M20a.2 design pass: "false negatives are okay; false
/// positives are not." A false negative (treating an rvalue as lvalue)
/// just annoys the user with an unnecessary explicit move/borrow. A
/// false positive (treating an lvalue as rvalue) silently permits
/// invalid moves/writes. So this is intentionally conservative — only
/// confidently-fresh-value expression heads are classified as rvalue.
pub const ReceiverShape = enum {
    read_explicit, // (read X)   — `?u.method()` form
    write_explicit, // (write X) — `(!u).method()` form
    move_explicit, // (move X)   — `(<u).method()` form
    rvalue, // expressions that produce a fresh value (no place to borrow)
    lvalue_bare, // bare identifier or any other place expression
};

/// M20a.2 (per GPT-5.5 pre-commit review): receiver expression's
/// *type* classification, complementing the syntactic shape. Without
/// this, expressions like `get_ref().consume()` — where `get_ref`
/// returns `?User` (read borrow) — would be silently accepted by a
/// `MethodReceiver.value` method because the syntactic shape is
/// `rvalue`. The fix: also check that the receiver expression's
/// TYPE is compatible with the receiver mode (owned vs read-borrow
/// vs write-borrow), not just its syntactic shape.
pub const ReceiverTypeKind = enum {
    owned_nominal, // T (matching the enclosing nominal)
    read_borrow, // ?T (matching the enclosing nominal)
    write_borrow, // !T (matching the enclosing nominal)
    shared, // M20d: *T (shared Rc handle to the enclosing nominal)
    other, // doesn't unwrap to the expected nominal, or unknown
};

fn classifyReceiverType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) ReceiverTypeKind {
    const ty = ctx.types.get(ty_id);
    switch (ty) {
        .nominal => |s| return if (s == nominal_sym) .owned_nominal else .other,
        // M20b(4/5): a parameterized_nominal whose base symbol matches
        // the expected nominal counts as owned for receiver-mode rules
        // — the type args don't affect mode classification (substitution
        // is handled in the lookup helper).
        .parameterized_nominal => |pn| return if (pn.sym == nominal_sym) .owned_nominal else .other,
        .borrow_read => |inner| {
            const inner_ty = ctx.types.get(inner);
            if (inner_ty == .nominal and inner_ty.nominal == nominal_sym) return .read_borrow;
            if (inner_ty == .parameterized_nominal and inner_ty.parameterized_nominal.sym == nominal_sym) return .read_borrow;
            return .other;
        },
        .borrow_write => |inner| {
            const inner_ty = ctx.types.get(inner);
            if (inner_ty == .nominal and inner_ty.nominal == nominal_sym) return .write_borrow;
            if (inner_ty == .parameterized_nominal and inner_ty.parameterized_nominal.sym == nominal_sym) return .write_borrow;
            return .other;
        },
        // M20d(4/5): shared(T) receiver. Match against the enclosing
        // nominal exactly like borrow kinds so `checkReceiverMode` can
        // reject `.write` / `.value` methods through shared. Auto-deref
        // is already permitted by `unwrapReadAccess` in the lookup
        // helpers; this is the safety check that turns "method found"
        // into "method callable."
        .shared => |inner| {
            const inner_ty = ctx.types.get(inner);
            if (inner_ty == .nominal and inner_ty.nominal == nominal_sym) return .shared;
            if (inner_ty == .parameterized_nominal and inner_ty.parameterized_nominal.sym == nominal_sym) return .shared;
            return .other;
        },
        else => return .other,
    }
}

fn classifyReceiverShape(receiver_expr: Sexp) ReceiverShape {
    if (receiver_expr == .list and receiver_expr.list.len >= 1 and
        receiver_expr.list[0] == .tag)
    {
        switch (receiver_expr.list[0].tag) {
            .@"read" => return .read_explicit,
            .@"write" => return .write_explicit,
            .@"move" => return .move_explicit,

            // Confidently-fresh-value expression heads:
            .@"call", // function / method / constructor call result
            .@"builtin", // @sizeOf(...) etc.
            .@"record", // Type{...} struct literal
            .@"anon_init", // .{...} anonymous literal
            .@"array", // [a, b, c] array literal
            .@"clone", // +x — explicit fresh clone
            .@"share", // *x — fresh shared handle
            .@"weak", // ~x — fresh weak handle
            .@"if", // value-position if produces a fresh value
            .@"match", // value-position match produces a fresh value
            .@"ternary", // postfix-if expression
            .@"catch", // expr catch ... — yields a value
            .@"try", // try expr — wraps a value
            .@"try_block", // value-yielding try / catch block
            .@"propagate", // x! — yields T from T!, fresh value
            => return .rvalue,

            // Place expressions (lvalue): member access, index, deref,
            // bare identifiers reached through `.src` below, and the
            // unsafe escape hatches (`@x` pin, `%x` raw) which are
            // views over existing storage rather than fresh values.
            else => return .lvalue_bare,
        }
    }
    // `.src` (bare name) or other leaf — lvalue.
    return .lvalue_bare;
}

/// M20b(2/5): substitution map for generic type-parameter resolution.
/// `params` and `args` are parallel slices: index `i` maps `params[i]`
/// (a `.generic_param` SymbolId) to `args[i]` (the supplied TypeId).
///
/// Constructed at lookup time from a receiver's `parameterized_nominal`
/// args, then passed into `substituteType` to walk the field/method's
/// stored symbolic type and produce the concrete substituted form.
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

/// M20b(5/5) per GPT-5.5: extract the underlying nominal SymbolId
/// from a receiver type, handling both `.nominal` (plain) and
/// `.parameterized_nominal` (generic). Peels borrows first. Returns
/// `null` if the receiver isn't anchored to a nominal at all.
///
/// Used in diagnostic paths so messages like "no method `missing` on
/// type `Box`" work uniformly for plain and generic receivers — without
/// this, the parameterized case fell through to "(unknown)" or
/// silent-unknown.
pub fn nominalSymOfReceiver(ctx: *const SemContext, ty_id: TypeId) ?SymbolId {
    const peeled = unwrapBorrows(ctx, ty_id);
    return switch (ctx.types.get(peeled)) {
        .nominal => |s| s,
        .parameterized_nominal => |pn| pn.sym,
        else => null,
    };
}

/// M20b(2/5): walk a type and substitute generic-param references
/// (`type_var(T_sym)`) with the corresponding TypeId from `subst`.
/// Recurses through every Type variant that can contain a TypeId
/// (`borrow_read`/`borrow_write`/`optional`/`fallible`/`slice`/`array`/
/// `function`/`parameterized_nominal`). Returns the input unchanged if
/// no substitution applies (including when `subst` is empty — fast
/// path for plain nominals).
///
/// Per GPT-5.5: unbound type_vars left unchanged (`type_var(U)` not
/// in `subst` returns `type_var(U)`) — matters for future method-local
/// generics where outer-scope and inner-scope substitutions stage
/// separately.
/// M20b(5/5) per GPT-5.5: const, non-allocating comparison helper.
/// Does `substituteType(ty_id, subst) == target` *as if* substitution
/// had been performed — but without actually interning anything.
/// Walks the type structure, substituting `type_var(T)` via `subst`
/// at each leaf, comparing against the corresponding slot in `target`.
///
/// Used by the emitter's print polish (which lives in a `*const
/// SemContext` context) to test "does this field's substituted type
/// equal String?" without mutating sema's interner via `@constCast`.
/// Phase discipline: emit must not allocate into sema.
pub fn typeEqualsAfterSubst(
    ctx: *const SemContext,
    ty_id: TypeId,
    subst: TypeSubst,
    target: TypeId,
) bool {
    // Fast path: when no substitution is in play, interner structural
    // equality is sound. Per GPT-5.5 review: NOT sound with a non-
    // empty subst — a composite like `Box(T)` would short-circuit
    // against `Box(T)` even though subst says T → Int.
    if (subst.isEmpty() and ty_id == target) return true;

    const ty = ctx.types.get(ty_id);
    // Resolve any leaf type_var via subst. The recursive comparison
    // uses `TypeSubst.empty` so substitution is simultaneous (one-
    // pass), not transitive — matches `substituteType`'s semantics.
    if (ty == .type_var) {
        const resolved = subst.lookup(ty.type_var) orelse return ty_id == target;
        return typeEqualsAfterSubst(ctx, resolved, TypeSubst.empty, target);
    }
    // Composite recursion: target must also be the composite form.
    const tgt = ctx.types.get(target);
    return switch (ty) {
        .borrow_read => |inner| tgt == .borrow_read and typeEqualsAfterSubst(ctx, inner, subst, tgt.borrow_read),
        .borrow_write => |inner| tgt == .borrow_write and typeEqualsAfterSubst(ctx, inner, subst, tgt.borrow_write),
        .shared => |inner| tgt == .shared and typeEqualsAfterSubst(ctx, inner, subst, tgt.shared),
        .weak => |inner| tgt == .weak and typeEqualsAfterSubst(ctx, inner, subst, tgt.weak),
        .optional => |inner| tgt == .optional and typeEqualsAfterSubst(ctx, inner, subst, tgt.optional),
        .fallible => |inner| tgt == .fallible and typeEqualsAfterSubst(ctx, inner, subst, tgt.fallible),
        .slice => |s| tgt == .slice and typeEqualsAfterSubst(ctx, s.elem, subst, tgt.slice.elem),
        .array => |arr| tgt == .array and arr.len == tgt.array.len and typeEqualsAfterSubst(ctx, arr.elem, subst, tgt.array.elem),
        .function => |fn_ty| blk: {
            if (tgt != .function) break :blk false;
            if (fn_ty.is_sub != tgt.function.is_sub) break :blk false;
            if (fn_ty.params.len != tgt.function.params.len) break :blk false;
            if (!typeEqualsAfterSubst(ctx, fn_ty.returns, subst, tgt.function.returns)) break :blk false;
            for (fn_ty.params, tgt.function.params) |p, tp| {
                if (!typeEqualsAfterSubst(ctx, p, subst, tp)) break :blk false;
            }
            break :blk true;
        },
        .parameterized_nominal => |pn| blk: {
            if (tgt != .parameterized_nominal) break :blk false;
            if (pn.sym != tgt.parameterized_nominal.sym) break :blk false;
            if (pn.args.len != tgt.parameterized_nominal.args.len) break :blk false;
            for (pn.args, tgt.parameterized_nominal.args) |a, ta| {
                if (!typeEqualsAfterSubst(ctx, a, subst, ta)) break :blk false;
            }
            break :blk true;
        },
        else => ty_id == target,
    };
}

pub fn substituteType(ctx: *SemContext, ty_id: TypeId, subst: TypeSubst) std.mem.Allocator.Error!TypeId {
    if (subst.isEmpty()) return ty_id;
    const ty = ctx.types.get(ty_id);
    return switch (ty) {
        .type_var => |sym| subst.lookup(sym) orelse ty_id,
        .borrow_read => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .borrow_read = new_inner });
        },
        .borrow_write => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .borrow_write = new_inner });
        },
        .shared => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .shared = new_inner });
        },
        .weak => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .weak = new_inner });
        },
        .optional => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .optional = new_inner });
        },
        .fallible => |inner| blk: {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .fallible = new_inner });
        },
        .slice => |s| blk: {
            const new_elem = try substituteType(ctx, s.elem, subst);
            if (new_elem == s.elem) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .slice = .{ .elem = new_elem } });
        },
        .array => |arr| blk: {
            const new_elem = try substituteType(ctx, arr.elem, subst);
            if (new_elem == arr.elem) break :blk ty_id;
            break :blk try ctx.types.intern(ctx.allocator, .{ .array = .{ .elem = new_elem, .len = arr.len } });
        },
        .function => |fn_ty| blk: {
            var changed = false;
            const new_ret = try substituteType(ctx, fn_ty.returns, subst);
            if (new_ret != fn_ty.returns) changed = true;
            var new_params_buf: std.ArrayListUnmanaged(TypeId) = .empty;
            defer new_params_buf.deinit(ctx.allocator);
            try new_params_buf.ensureTotalCapacity(ctx.allocator, fn_ty.params.len);
            for (fn_ty.params) |p| {
                const np = try substituteType(ctx, p, subst);
                if (np != p) changed = true;
                new_params_buf.appendAssumeCapacity(np);
            }
            if (!changed) break :blk ty_id;
            const owned = try ctx.arena.allocator().dupe(TypeId, new_params_buf.items);
            break :blk try ctx.types.intern(ctx.allocator, .{ .function = .{
                .params = owned,
                .returns = new_ret,
                .is_sub = fn_ty.is_sub,
            } });
        },
        .parameterized_nominal => |pn| blk: {
            var changed = false;
            var new_args_buf: std.ArrayListUnmanaged(TypeId) = .empty;
            defer new_args_buf.deinit(ctx.allocator);
            try new_args_buf.ensureTotalCapacity(ctx.allocator, pn.args.len);
            for (pn.args) |a| {
                const na = try substituteType(ctx, a, subst);
                if (na != a) changed = true;
                new_args_buf.appendAssumeCapacity(na);
            }
            if (!changed) break :blk ty_id;
            const owned = try ctx.arena.allocator().dupe(TypeId, new_args_buf.items);
            break :blk try ctx.types.intern(ctx.allocator, .{ .parameterized_nominal = .{ .sym = pn.sym, .args = owned } });
        },
        else => ty_id,
    };
}

/// M20b(3/5): does the given TypeId match the enclosing nominal's
/// `self_type` (modulo identity comparison via the interner)? For
/// plain nominals this is `ty_id == nominal(sym)`. For generic types
/// this is `ty_id == parameterized_nominal(sym, [type_var(T_i)])` —
/// i.e., `Self` as it appears symbolically in the body.
///
/// Used by `resolveNominalMethod` to validate that `self: ?Self`
/// inside `struct User` resolves to `?User` (and inside `type Box(T)`
/// resolves to `?Box(T)`). The interner gives us structural equality
/// for free, so this is just a TypeId compare against the cached
/// self_type.
pub fn isSelfTypeId(ctx: *const SemContext, ty_id: TypeId, nominal_ctx: NominalContext) bool {
    if (nominal_ctx.isEmpty()) return false;
    if (ty_id == nominal_ctx.self_type) return true;
    // Allow the explicit form (`self: User` matching nominal(User))
    // for plain nominals — already covered by interner equality above
    // since `self_type` for plain nominals IS `nominal(sym)`.
    // For generics, the parameterized form is checked the same way.
    _ = ctx;
    return false;
}

/// M20b(3/5): construct the canonical `NominalContext` for a given
/// nominal Symbol. For plain nominals (struct/enum/errors), returns
/// `{sym, nominal(sym), &.{}}`. For generic types, returns
/// `{sym, parameterized_nominal(sym, [type_var(T)]), [T...]}` —
/// `self_type` is the parameterized form whose args are the generic
/// params themselves (so `Self` inside `type Box(T)` is `Box(T)`,
/// not `Box`).
pub fn makeNominalContext(ctx: *SemContext, sym_id: SymbolId) std.mem.Allocator.Error!NominalContext {
    const sym = ctx.symbols.items[sym_id];
    switch (sym.kind) {
        .nominal_type => {
            const self_type = try ctx.types.intern(ctx.allocator, .{ .nominal = sym_id });
            return .{ .sym = sym_id, .self_type = self_type, .type_params = &.{} };
        },
        .generic_type => {
            const tparams = sym.type_params orelse &.{};
            // Build args = [type_var(T_i) ...] for self_type = Box(T).
            var args_buf: std.ArrayListUnmanaged(TypeId) = .empty;
            defer args_buf.deinit(ctx.allocator);
            try args_buf.ensureTotalCapacity(ctx.allocator, tparams.len);
            for (tparams) |tp_sym| {
                const tv = try ctx.types.intern(ctx.allocator, .{ .type_var = tp_sym });
                args_buf.appendAssumeCapacity(tv);
            }
            const owned = try ctx.arena.allocator().dupe(TypeId, args_buf.items);
            const self_type = try ctx.types.intern(ctx.allocator, .{ .parameterized_nominal = .{
                .sym = sym_id,
                .args = owned,
            } });
            return .{ .sym = sym_id, .self_type = self_type, .type_params = tparams };
        },
        else => return NominalContext.none,
    }
}

/// M20b(2/5): the enclosing nominal context for type resolution and
/// body checking. Replaces the simpler `current_nominal: ?SymbolId`
/// used in M20a/M20a.2 — generic types need to carry their type-param
/// list (so `T` inside `type Box(T)` resolves) AND a precomputed
/// `self_type` so `Self` always resolves to the right `(parameterized_)
/// nominal` consistently.
///
/// For plain nominals (struct/enum/errors):
///   `{ sym, self_type = nominal(sym), type_params = &.{} }`.
///
/// For generic types (`type Box(T)`):
///   `{ sym, self_type = parameterized_nominal(sym, [type_var(T)]),
///      type_params = [T_sym] }`.
///
/// `resolveType` uses `type_params` to resolve bare identifier `T` to
/// `type_var(T_sym)` even when the original generic body scope is no
/// longer active (e.g., when `ExprChecker.checkSet` constructs an
/// on-the-fly TypeResolver for a body annotation). Per GPT-5.5: do
/// not rely solely on lexical scope binding.
pub const NominalContext = struct {
    sym: SymbolId,
    self_type: TypeId,
    type_params: []const SymbolId,

    /// Empty context — for top-level resolution outside any nominal.
    pub const none: NominalContext = .{
        .sym = symbol_invalid,
        .self_type = type_invalid,
        .type_params = &.{},
    };

    pub fn isEmpty(self: NominalContext) bool {
        return self.sym == symbol_invalid;
    }
    // Note: NominalContext does NOT carry a "selfSubst" — for generic
    // body symbolic resolution, `resolveType` stores `type_var(T)`
    // directly via NominalContext.type_params lookup, so no identity
    // substitution is needed. Concrete substitution at use sites uses
    // `TypeSubst{params=ctx.type_params, args=parameterized_nominal.args}`
    // constructed by the lookup helpers (M20b(4/5)).
};

/// M20b: result of resolving a data-field reference on a receiver
/// type. Carries the matched `Field`, the (possibly substituted) field
/// type, and the owning nominal Symbol — useful for diagnostics and
/// for emit/codegen needs that want to know which type the field came
/// from.
///
/// For plain nominals (M20b(1/5)), `ty == field.ty` always.
/// For parameterized nominals (M20b(4/5)), `ty` is `field.ty` with
/// the generic-param substitution applied.
pub const ResolvedField = struct {
    field: Field,
    ty: TypeId,
    nominal_sym: SymbolId,
};

/// M20b: result of resolving a method reference on a receiver type.
/// Carries the matched `Field`, the receiver mode (so call-site
/// dispatch doesn't have to re-derive it), the function type
/// (possibly substituted), and the owning nominal Symbol.
pub const ResolvedMethod = struct {
    field: Field,
    receiver: MethodReceiver,
    fn_ty: FunctionType,
    nominal_sym: SymbolId,
};

/// M20b(1/5): look up a data field by name on a receiver type. Peels
/// borrow_read / borrow_write via `unwrapBorrows` before searching the
/// underlying nominal's `Symbol.fields`. Methods (`is_method = true`)
/// are intentionally skipped — use `lookupMethod` for those.
///
/// Returns `null` if the receiver doesn't unwrap to a nominal, the
/// nominal has no `fields` (opaque or unresolved), or no matching
/// non-method field exists. Callers produce their own diagnostics
/// (with field-vs-method-collision handling, etc.).
///
/// M20b(4/5) will extend this to handle `parameterized_nominal` and
/// substitute the returned `ty` against the receiver's type arguments.
pub fn lookupDataField(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedField {
    // M20d(4/5): use `unwrapReadAccess` (peels shared too) so `rc.field`
    // reaches the nominal's fields. Read-only access is always safe
    // through a shared handle; field WRITE through shared is rejected
    // separately in `checkSet` (also M20d(4/5)).
    const peeled = unwrapReadAccess(ctx, receiver_ty);
    const ty = ctx.types.get(peeled);

    // Classify the receiver: plain nominal vs parameterized.
    var sym_id: SymbolId = symbol_invalid;
    var subst: TypeSubst = TypeSubst.empty;
    switch (ty) {
        .nominal => |s| {
            sym_id = s;
        },
        .parameterized_nominal => |pn| {
            sym_id = pn.sym;
            const sym = ctx.symbols.items[pn.sym];
            const tparams = sym.type_params orelse &.{};
            subst = .{ .params = tparams, .args = pn.args };
        },
        else => return null,
    }

    const sym = ctx.symbols.items[sym_id];
    const fields = sym.fields orelse return null;
    for (fields) |f| {
        // M20a: skip methods. M20c per GPT-5.5: also skip variants
        // (an enum's variants live in `fields` but are NOT data
        // fields — use `lookupVariant` for those).
        if (f.is_method or f.is_variant) continue;
        if (std.mem.eql(u8, f.name, name)) {
            // M20b(4/5): substitute the field's stored type against
            // the receiver's type arguments. For plain nominals,
            // `subst` is empty so `substituteType` returns the
            // original TypeId unchanged. For parameterized receivers,
            // `type_var(T)` → concrete arg.
            // M20b(5/5) per GPT-5.5: propagate allocator errors;
            // never silently fall back to unsubstituted f.ty.
            const sub_ty = try substituteType(ctx, f.ty, subst);
            return .{ .field = f, .ty = sub_ty, .nominal_sym = sym_id };
        }
    }
    return null;
}

/// M20b(1/5): look up a method by name on a receiver type. Peels
/// borrows; searches the underlying nominal's `Symbol.fields` for an
/// `is_method = true` entry whose name matches. Data fields are
/// intentionally skipped.
///
/// Returns `null` on no match. M20b(4/5) will substitute the returned
/// `fn_ty` (params + return) against the receiver's type arguments
/// for parameterized nominals.
pub fn lookupMethod(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedMethod {
    // M20d(4/5): use `unwrapReadAccess` (peels shared too). Method
    // lookup matches; the receiver-mode check (`checkReceiverMode`)
    // is then responsible for rejecting `.write` / `.value` receivers
    // when the actual receiver type is `shared`. Auto-deref reaches
    // the declaration; the receiver-mode rule enforces safety.
    const peeled = unwrapReadAccess(ctx, receiver_ty);
    const ty = ctx.types.get(peeled);

    var sym_id: SymbolId = symbol_invalid;
    var subst: TypeSubst = TypeSubst.empty;
    switch (ty) {
        .nominal => |s| {
            sym_id = s;
        },
        .parameterized_nominal => |pn| {
            sym_id = pn.sym;
            const sym = ctx.symbols.items[pn.sym];
            const tparams = sym.type_params orelse &.{};
            subst = .{ .params = tparams, .args = pn.args };
        },
        else => return null,
    }

    const sym = ctx.symbols.items[sym_id];
    const fields = sym.fields orelse return null;
    for (fields) |f| {
        if (!f.is_method) continue;
        if (std.mem.eql(u8, f.name, name)) {
            const fn_ty_val = ctx.types.get(f.ty);
            if (fn_ty_val != .function) continue;
            // M20b(4/5): substitute the function type against the
            // receiver's type arguments. For plain nominals subst is
            // empty (no-op). For generics, T inside the signature
            // becomes the concrete arg.
            // M20b(5/5) per GPT-5.5: propagate allocator errors.
            const sub_fn_ty_id = try substituteType(ctx, f.ty, subst);
            const sub_fn_ty_val = ctx.types.get(sub_fn_ty_id);
            const sub_fn_ty: FunctionType = if (sub_fn_ty_val == .function) sub_fn_ty_val.function else fn_ty_val.function;
            return .{
                .field = f,
                .receiver = f.receiver,
                .fn_ty = sub_fn_ty,
                .nominal_sym = sym_id,
            };
        }
    }
    return null;
}

/// M20c: result of resolving an enum-variant reference on a receiver
/// type. Per GPT-5.5 M20c design pass: variants are NOT fields; enum-
/// literal / match-arm dispatch goes through this helper rather than
/// poking through `Symbol.fields` directly.
///
/// `payload` is the variant's payload field list with `type_var`s
/// substituted against the receiver's type arguments (for parameterized
/// enums) — so a match arm on `Option(Int).some(value: ...)` sees
/// `value: Int`, not `value: T`. For plain nominals, substitution is
/// empty and payload comes through unchanged.
pub const ResolvedVariant = struct {
    field: Field,
    payload: []const Field, // substituted; empty slice when variant has no payload
    nominal_sym: SymbolId,
};

/// M20c: look up an enum variant by name on a receiver type. Peels
/// borrows; handles `nominal` (plain enum) and `parameterized_nominal`
/// (generic enum). Substitutes `type_var` in payload field types
/// against the receiver's type args.
///
/// Returns `null` if the receiver isn't an enum/errors nominal or
/// the named variant doesn't exist. Use the `nominal_sym` from the
/// result for callee-side diagnostics.
pub fn lookupVariant(
    ctx: *SemContext,
    receiver_ty: TypeId,
    name: []const u8,
) std.mem.Allocator.Error!?ResolvedVariant {
    const peeled = unwrapBorrows(ctx, receiver_ty);
    const ty = ctx.types.get(peeled);

    var sym_id: SymbolId = symbol_invalid;
    var subst: TypeSubst = TypeSubst.empty;
    switch (ty) {
        .nominal => |s| sym_id = s,
        .parameterized_nominal => |pn| {
            sym_id = pn.sym;
            const sym = ctx.symbols.items[pn.sym];
            const tparams = sym.type_params orelse &.{};
            subst = .{ .params = tparams, .args = pn.args };
        },
        else => return null,
    }

    const sym = ctx.symbols.items[sym_id];
    const fields = sym.fields orelse return null;
    for (fields) |f| {
        if (!f.is_variant) continue;
        if (!std.mem.eql(u8, f.name, name)) continue;
        // Substitute payload field types if any.
        const orig_payload = f.payload orelse &.{};
        if (orig_payload.len == 0 or subst.isEmpty()) {
            return .{ .field = f, .payload = orig_payload, .nominal_sym = sym_id };
        }
        // Build a substituted payload slice in the arena.
        const sub_payload = try ctx.arena.allocator().alloc(Field, orig_payload.len);
        for (orig_payload, 0..) |pf, i| {
            sub_payload[i] = .{
                .name = pf.name,
                .ty = try substituteType(ctx, pf.ty, subst),
                .decl_pos = pf.decl_pos,
                .payload = pf.payload,
                .is_method = pf.is_method,
                .receiver = pf.receiver,
                .is_variant = pf.is_variant,
            };
        }
        return .{ .field = f, .payload = sub_payload, .nominal_sym = sym_id };
    }
    return null;
}

/// M20b(1/5) / M20b(5/5): check whether a method by `name` exists on
/// the receiver's nominal (method-vs-field collision detection). Used
/// by `synthMember` to produce a targeted "bare method reference not
/// supported" diagnostic. Per GPT-5.5: this is a non-substituting,
/// non-allocating boolean existence check — does NOT call
/// `lookupMethod` (which substitutes and may allocate).
pub fn hasMethodNamed(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) bool {
    // M20d(4/5): peel shared too (read-only access auto-deref).
    const peeled = unwrapReadAccess(ctx, receiver_ty);
    const ty = ctx.types.get(peeled);
    const sym_id = switch (ty) {
        .nominal => |s| s,
        .parameterized_nominal => |pn| pn.sym,
        else => return false,
    };
    const sym = ctx.symbols.items[sym_id];
    const fields = sym.fields orelse return false;
    for (fields) |f| {
        if (!f.is_method) continue;
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// M20a.2: peel `borrow_read` / `borrow_write` wrappers from a type
/// to reach the underlying nominal (or whatever). Used by member
/// lookup, instance-call dispatch, exhaustiveness checks, and the
/// emitter's print polish — anywhere "I have a value of type T or
/// a borrow of T; find the underlying nominal" semantics applies.
///
/// Per GPT-5.5: deliberately does NOT unwrap optional, fallible,
/// shared, weak, raw, or anything else — those have member-access
/// semantics that haven't been decided yet. Adding silent unwrap
/// here would reintroduce null-deref-style hazards.
pub fn unwrapBorrows(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = ty_id;
    while (true) {
        const ty = ctx.types.get(id);
        switch (ty) {
            .borrow_read => |inner| id = inner,
            .borrow_write => |inner| id = inner,
            else => return id,
        }
    }
}

/// M20d(4/5): read-only access unwrap. Peels `borrow_read` /
/// `borrow_write` AND `shared` — but NOT `weak`, NOT `optional`, NOT
/// `fallible`, NOT `raw`. Used by `lookupDataField` / `lookupMethod` /
/// `hasMethodNamed` so a `*T` receiver can reach `T`'s fields and
/// methods for read-only access (`rc.field`, `rc.method()` where the
/// method takes `?self`).
///
/// This is the cornerstone of M20d's read-only auto-deref. Per
/// GPT-5.5's M20d design pass: deliberately separated from
/// `unwrapBorrows` so the existing write-borrow / consume paths
/// don't accidentally compose with `shared` (which would silently
/// permit write-through-shared, breaking the aliasing model).
///
/// Critically, `checkReceiverMode` must STILL classify the receiver
/// via `classifyReceiverType` to detect shared-typed receivers and
/// reject `.write` / `.value` methods — auto-deref reaches the method
/// declaration, the receiver-mode check enforces it's safe to call.
///
/// `weak` is NOT peeled: weak handles must be `.upgrade()`'d
/// explicitly. Auto-deref of weak would silently dereference a
/// potentially dangling handle.
pub fn unwrapReadAccess(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = ty_id;
    while (true) {
        const ty = ctx.types.get(id);
        switch (ty) {
            .borrow_read => |inner| id = inner,
            .borrow_write => |inner| id = inner,
            .shared => |inner| id = inner,
            else => return id,
        }
    }
}

/// M20a.2: best-effort source position for a parameter Sexp, falling
/// back to the supplied default if the shape doesn't carry one.
fn paramPos(param: Sexp, fallback: u32) u32 {
    return switch (param) {
        .src => |s| s.pos,
        .list => |items| blk: {
            if (items.len >= 2 and items[0] == .tag) {
                switch (items[0].tag) {
                    .@":", .@"pre_param", .@"read", .@"write" => {
                        if (items[1] == .src) break :blk items[1].src.pos;
                    },
                    else => {},
                }
            }
            break :blk fallback;
        },
        else => fallback,
    };
}

/// Extract the name of a parameter Sexp, regardless of shape.
fn paramName(source: []const u8, param: Sexp) ?[]const u8 {
    return switch (param) {
        .src => identAt(source, param),
        .list => |items| blk: {
            if (items.len == 0 or items[0] != .tag) break :blk null;
            switch (items[0].tag) {
                .@":", .@"pre_param" => {
                    if (items.len >= 2) break :blk identAt(source, items[1]);
                },
                // M20a.1: `?self` / `!self` sugar emits `(read self)` /
                // `(write self)` at param position — extract the name.
                .@"read", .@"write" => {
                    if (items.len >= 2) break :blk identAt(source, items[1]);
                },
                else => {},
            }
            break :blk null;
        },
        else => null,
    };
}

fn parseIntegerLiteral(source: []const u8, sexp: Sexp) ?u64 {
    if (sexp != .src) return null;
    const text = source[sexp.src.pos..][0..sexp.src.len];
    return std.fmt.parseInt(u64, text, 0) catch null;
}

// =============================================================================
// Expression Typing
// =============================================================================
//
// Pass 3: walk function bodies with statement-vs-value context.
//
// Two entry points (per GPT-5.5's design pass for M5(3/n)):
//
//   synthExpr(expr) -> TypeId
//     Bottom-up synthesis. Returns the type of the expression. Used in
//     both statement and value contexts; the caller decides what to do
//     with the result.
//
//   checkExpr(expr, expected) -> void
//     Synth + compatibility-check against `expected`. Emits a
//     diagnostic on mismatch; otherwise silent. Used at every "the
//     value is consumed somewhere with a known expected type" site
//     (typed binding RHS, call arg position, return value, etc.).
//
//   checkStmt(stmt) -> void
//     Walks a statement-position form. `if` / `while` etc. don't
//     require arm unification here. Calls synth/checkExpr as needed
//     for embedded expressions.
//
// Compatibility rules (M5 v1):
//
//   same type                                ok
//   int_literal   → integer type             ok (no range check yet)
//   float_literal → float type               ok
//   anything      → invalid                  ok (errors don't cascade)
//   invalid       → anything                 ok
//   unknown       → anything                 ok (deferred resolution)
//   anything      → unknown                  ok (rare but harmless)
//   T → T?                                   no  (must be wrapped)
//   T! → T                                   no  (must be `!` propagated)
//   ?T / !T cross-mix                        no  (exact match only)
//   nominal A → nominal B                    only if A == B
//
// Errors point at use sites with a `note:` at the relevant declaration.

const ExprChecker = struct {
    ctx: *SemContext,
    /// Innermost scope when typing an expression. Updated as we descend
    /// into function bodies / blocks / for / catch / arm scopes — same
    /// nesting order the symbol resolver established. We don't push
    /// new scopes (pass 1 did that); we just advance into the existing
    /// scope ids in lockstep via `next_scope_cursor`.
    current_scope: ScopeId,

    /// The next available scope id we'll enter when a scope-introducing
    /// form is walked. Advances in the same order the SymbolResolver
    /// pushed scopes during pass 1 so `current_scope` always matches
    /// the bindings the resolver actually populated.
    next_scope_cursor: ScopeId = 0,

    /// Declared return type of the function whose body we're currently
    /// inside. `void_id` at module scope; updated when entering a fn.
    /// Used by `(return value)` and the implicit-return final
    /// expression of a function with a non-void return.
    current_fn_return: TypeId,

    /// M20a.2 / M20b(3/5): enclosing nominal context when type-checking
    /// inside a method body. Plumbed into any `TypeResolver` instance
    /// constructed by `ExprChecker` (e.g., for `x: Self = ...`
    /// annotations in body) so `Self` and (for generics) `T` resolve
    /// correctly in expression-position type annotations as well as
    /// method signatures.
    current_nominal: NominalContext = NominalContext.none,

    /// Enter the next scope in the resolver's creation order. Saves the
    /// previous scope so the caller can restore via `leaveScope`.
    fn enterNextScope(self: *ExprChecker) ScopeId {
        const prev = self.current_scope;
        self.current_scope = self.next_scope_cursor;
        self.next_scope_cursor += 1;
        return prev;
    }

    fn leaveScope(self: *ExprChecker, prev: ScopeId) void {
        self.current_scope = prev;
    }

    fn err(self: *ExprChecker, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.ctx.arena.allocator(), fmt, args);
        try self.ctx.diagnostics.append(self.ctx.allocator, .{
            .severity = .@"error",
            .pos = pos,
            .message = msg,
        });
    }

    fn note(self: *ExprChecker, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.ctx.arena.allocator(), fmt, args);
        try self.ctx.diagnostics.append(self.ctx.allocator, .{
            .severity = .note,
            .pos = pos,
            .message = msg,
        });
    }

    /// Top-level walk: visit each module-level decl, advancing the
    /// scope cursor in lockstep with the SymbolResolver pass.
    fn walkModule(self: *ExprChecker, ir: Sexp, module_scope: ScopeId) std.mem.Allocator.Error!void {
        if (ir != .list or ir.list.len == 0 or ir.list[0] != .tag) return;
        if (ir.list[0].tag != .@"module") return;

        // Pass 1 created the module scope first, then began creating
        // child scopes from `module_scope + 1` onward.
        self.current_scope = module_scope;
        self.next_scope_cursor = module_scope + 1;

        for (ir.list[1..]) |child| {
            try self.walkDecl(child);
        }
    }

    fn walkDecl(self: *ExprChecker, sexp: Sexp) std.mem.Allocator.Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return;
        const items = sexp.list;
        switch (items[0].tag) {
            .@"pub" => {
                if (items.len >= 2) try self.walkDecl(items[1]);
            },
            .@"fun", .@"sub" => try self.walkFun(items),
            // M20a / M20b(3/5): descend into nominal bodies so method
            // bodies are type-checked. Each method's body scope was
            // pushed by the SymbolResolver (walkMethod /
            // walkGenericType); we must enter them in the same order
            // to stay in lockstep with the scope cursor.
            .@"struct", .@"enum", .@"errors", .@"generic_type" => try self.walkNominalDecl(items),
            // type aliases / extern / use have no body to type-check.
            else => {},
        }
    }

    /// M20a / M20b(3/5): walk a nominal declaration (`(struct ...)` /
    /// `(enum ...)` / `(errors ...)` / `(generic_type ...)`),
    /// descending into each `fun`/`sub` member so its body is
    /// type-checked. Sets `current_nominal` so `Self` (and, for
    /// generic types, `T`) in body local type annotations resolves
    /// correctly.
    fn walkNominalDecl(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 2) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const nominal_sym_id = self.ctx.lookup(self.current_scope, name) orelse return;

        const prev_nominal = self.current_nominal;
        self.current_nominal = try makeNominalContext(self.ctx, nominal_sym_id);
        defer self.current_nominal = prev_nominal;

        // For generic_type, members are at items[3..] (after name and
        // params list); for plain struct/enum/errors, items[2..].
        const head = items[0].tag;
        const member_start: usize = if (head == .@"generic_type") 3 else 2;
        if (items.len <= member_start) return;
        for (items[member_start..]) |member| {
            if (member != .list or member.list.len == 0 or member.list[0] != .tag) continue;
            switch (member.list[0].tag) {
                .@"fun", .@"sub" => try self.walkMethod(member.list, nominal_sym_id),
                else => {},
            }
        }
    }

    /// M20a: walk a method body. Mirrors `walkFun` but pulls the
    /// declared return type from the nominal's `Symbol.fields` (where
    /// `TypeResolver.resolveNominalMethod` stored the method's function
    /// type) rather than from a top-level function symbol — methods
    /// don't get module-scope function symbols.
    fn walkMethod(self: *ExprChecker, items: []const Sexp, nominal_sym_id: SymbolId) std.mem.Allocator.Error!void {
        if (items.len < 5) return;
        const is_sub = items[0].tag == .@"sub";
        const name_node = items[1];
        const body = items[items.len - 1];

        // Find the method's return type from the nominal's fields list.
        const method_name = identAt(self.ctx.source, name_node) orelse return;
        const nominal_sym = self.ctx.symbols.items[nominal_sym_id];
        var fn_return: TypeId = if (is_sub) self.ctx.types.void_id else self.ctx.types.unknown_id;
        if (nominal_sym.fields) |fields| {
            for (fields) |f| {
                if (f.is_method and std.mem.eql(u8, f.name, method_name)) {
                    const fn_ty = self.ctx.types.get(f.ty);
                    if (fn_ty == .function) fn_return = fn_ty.function.returns;
                    break;
                }
            }
        }

        // Enter the method body scope (matches SymbolResolver.walkMethod's pushScope).
        const prev_scope = self.enterNextScope();
        const prev_return = self.current_fn_return;
        defer {
            self.leaveScope(prev_scope);
            self.current_fn_return = prev_return;
        }
        self.current_fn_return = fn_return;

        try self.walkBody(body, fn_return, is_sub);
    }

    fn walkFun(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 5) return;
        const is_sub = items[0].tag == .@"sub";
        const name_node = items[1];
        const body = items[items.len - 1];

        // Look up our declared signature to find return type.
        const fn_return: TypeId = blk: {
            if (identAt(self.ctx.source, name_node)) |nm| {
                if (self.ctx.lookup(scope_invalid + 1, nm)) |fn_sym| {
                    const fn_ty = self.ctx.types.get(self.ctx.symbols.items[fn_sym].ty);
                    if (fn_ty == .function) break :blk fn_ty.function.returns;
                }
            }
            break :blk if (is_sub) self.ctx.types.void_id else self.ctx.types.unknown_id;
        };

        // Enter the fn body scope (matches resolver's pushScope in walkFun).
        const prev_scope = self.enterNextScope();
        const prev_return = self.current_fn_return;
        defer {
            self.leaveScope(prev_scope);
            self.current_fn_return = prev_return;
        }
        self.current_fn_return = fn_return;

        try self.walkBody(body, fn_return, is_sub);
    }

    /// Walk a function body. The body is either a `(block stmt...)` or
    /// a single expression. For `fun` (non-void return), the LAST
    /// statement is checked against the return type as the implicit
    /// return value; all others are statement-position. For `sub`, all
    /// statements are statement-position (return values would be void).
    ///
    /// IMPORTANT: when the body is a `(block ...)`, the SymbolResolver
    /// pushed a fresh scope for it (separate from the fn scope) — so
    /// we must enter that scope here for binding lookups to resolve.
    fn walkBody(self: *ExprChecker, body: Sexp, fn_return: TypeId, is_sub: bool) std.mem.Allocator.Error!void {
        const is_block = body == .list and body.list.len > 0 and
            body.list[0] == .tag and body.list[0].tag == .@"block";

        const stmts: []const Sexp = if (is_block)
            body.list[1..]
        else if (body == .list)
            (&[_]Sexp{body})[0..]
        else
            return;

        // Enter the body's block scope to mirror the resolver. Single-
        // expression bodies (no surrounding block) don't have one.
        var prev_scope: ScopeId = self.current_scope;
        const entered = is_block;
        if (entered) {
            prev_scope = self.enterNextScope();
        }
        defer if (entered) self.leaveScope(prev_scope);

        const want_implicit_return = !is_sub and !typeIsVoid(self.ctx, fn_return);

        for (stmts, 0..) |stmt, i| {
            const is_last = i == stmts.len - 1;
            if (is_last and want_implicit_return) {
                // Implicit return: the last expression must be
                // assignable to the declared return type.
                try self.checkExpr(stmt, fn_return);
            } else {
                try self.checkStmt(stmt);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Statement walker
    // -------------------------------------------------------------------------

    fn checkStmt(self: *ExprChecker, stmt: Sexp) std.mem.Allocator.Error!void {
        if (stmt != .list or stmt.list.len == 0 or stmt.list[0] != .tag) {
            // Bare `.src` or other leaf at statement position — synth
            // and discard. (Drives plain-name lookup so unbound names
            // can be diagnosed in the future, but currently noop.)
            _ = try self.synthExpr(stmt);
            return;
        }
        const items = stmt.list;
        switch (items[0].tag) {
            .@"set" => try self.checkSet(items),
            .@"return" => try self.checkReturn(items),
            .@"if" => try self.checkIfStmt(items),
            .@"while" => try self.checkWhileStmt(items),
            .@"for" => try self.checkForStmt(items),
            .@"match" => try self.checkMatchStmt(items),
            .@"block" => {
                // Enter the block scope created by the SymbolResolver.
                const prev = self.enterNextScope();
                defer self.leaveScope(prev);
                for (items[1..]) |c| try self.checkStmt(c);
            },
            .@"drop" => {
                // (drop name) — no type effects; ownership pass handles it.
            },
            .@"break", .@"continue" => {},
            .@"defer", .@"errdefer" => {
                if (items.len >= 2) try self.checkStmt(items[1]);
            },
            // Everything else (call, propagate, member, infix, etc.)
            // is an expression. Synth and discard the result.
            else => _ = try self.synthExpr(stmt),
        }
    }

    /// M20d.1: walk an assignment LHS chain and return true if any
    /// segment's obj type unwraps borrows to `shared(_)`. Catches
    /// the chained cases GPT-5.5 flagged in the post-M20d review:
    ///
    ///   rc.field = X            # immediate: obj=rc, type=shared(_)
    ///   rc.inner.field = X      # chained:   obj=(member rc inner) is Inner;
    ///                           #   recurse: obj=rc is shared(_) → reject
    ///   rc.items[0] = X         # via index: same pattern through array slot
    ///   (!rc).name = X          # wrapped:   obj=(write rc) is borrow_write(shared(_))
    ///                           #   unwrapBorrows peels → shared(_) → reject
    ///
    /// Uses `unwrapBorrows` (NOT `unwrapReadAccess`) so the shared
    /// layer is detected. Stops at any non-place expression (calls,
    /// rvalues, etc. — those can't be assigned to anyway).
    fn assignmentChainPassesThroughShared(self: *ExprChecker, lhs: Sexp) std.mem.Allocator.Error!bool {
        if (lhs != .list or lhs.list.len < 2 or lhs.list[0] != .tag) return false;
        const head = lhs.list[0].tag;
        if (head != .@"member" and head != .@"index") return false;
        const obj = lhs.list[1];
        const obj_ty = self.synthExpr(obj) catch self.ctx.types.unknown_id;
        const peeled = unwrapBorrows(self.ctx, obj_ty);
        if (self.ctx.types.get(peeled) == .shared) return true;
        return self.assignmentChainPassesThroughShared(obj);
    }

    fn checkSet(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (set <kind> name type-or-_ expr).
        if (items.len < 5) return;
        const target = items[2];
        const type_node = items[3];
        const expr = items[4];

        // M20d(4/5) + M20d.1: reject any assignment whose target
        // chain passes through a shared handle. `rc.field = X` and
        // `rc.inner.field = X` and `rc.items[0] = X` all mutate
        // storage inside the RcBox, which other `*T` handles can
        // observe — breaking the aliasing model. The Cell(T) /
        // RefCell(T) pattern (M20+ item #7) is the user-facing
        // answer for controlled mutation through shared ownership.
        //
        // Walks the target chain via `.member` and `.index` segments.
        // At each segment, synth the obj and check whether its type
        // unwraps borrows to `shared(_)`. The recursion uses
        // `unwrapBorrows` (NOT `unwrapReadAccess`) so the shared
        // layer is detected; if we peeled shared during the check
        // we'd silently accept the very thing we're trying to catch.
        if (try self.assignmentChainPassesThroughShared(target)) {
            const pos = firstSrcPos(target);
            try self.err(pos, "cannot assign through shared handle (`*T`); other handles may exist. Use an interior-mutable type (planned `Cell(T)` in M20+ item #7) for mutation through shared ownership.", .{});
            _ = self.synthExpr(expr) catch self.ctx.types.unknown_id;
            return;
        }

        // Find the symbol, if any. Compound assigns / move-assign reuse
        // an existing slot — they don't introduce a new symbol but we
        // still need to type-check against the existing one.
        const sym_id = blk: {
            const nm = identAt(self.ctx.source, target) orelse break :blk symbol_invalid;
            break :blk self.ctx.lookup(self.current_scope, nm) orelse symbol_invalid;
        };

        // Resolve the explicit type annotation, if any. M20a.2: plumb
        // `current_nominal` so `Self` resolves correctly inside method
        // bodies (e.g., `x: Self = User(...)`).
        var declared_ty: TypeId = self.ctx.types.unknown_id;
        if (type_node != .nil) {
            var tr: TypeResolver = .{ .ctx = self.ctx, .current_nominal = self.current_nominal };
            declared_ty = try tr.resolveType(type_node, self.current_scope);
        } else if (sym_id != symbol_invalid) {
            const existing = self.ctx.symbols.items[sym_id].ty;
            if (existing != self.ctx.types.unknown_id) declared_ty = existing;
        }

        // Check or synth the RHS.
        const rhs_ty = if (declared_ty == self.ctx.types.unknown_id)
            try self.synthExpr(expr)
        else blk: {
            try self.checkExpr(expr, declared_ty);
            break :blk declared_ty;
        };

        // Promote literal pseudo-types to their canonical concrete forms
        // when stored on a symbol — downstream uses will see `Int`/`Float`,
        // not the unconstrained pseudo-type.
        const final_ty = self.canonicalize(rhs_ty);

        if (sym_id != symbol_invalid) {
            const sym = &self.ctx.symbols.items[sym_id];
            if (sym.ty == self.ctx.types.unknown_id) {
                sym.ty = final_ty;
            }
        }
    }

    fn checkReturn(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (return value? if?)
        if (items.len >= 2 and items[1] != .nil) {
            try self.checkExpr(items[1], self.current_fn_return);
        }
    }

    fn checkIfStmt(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (if cond then else?). At statement position we check cond is
        // Bool but DON'T unify branch arms (branches at stmt position
        // discard their results, so mismatched arm value-types aren't
        // a problem unless the if is used as a value).
        if (items.len >= 2) try self.checkExpr(items[1], self.ctx.types.bool_id);
        if (items.len >= 3) try self.checkStmt(items[2]);
        if (items.len >= 4 and items[3] != .nil) try self.checkStmt(items[3]);
    }

    fn checkWhileStmt(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (while cond body else?) or (while cond cont body else?).
        if (items.len >= 2) try self.checkExpr(items[1], self.ctx.types.bool_id);
        for (items[2..]) |c| try self.checkStmt(c);
    }

    fn checkForStmt(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (for <mode> binding1 binding2-or-_ source body else?). We
        // don't have iterator-protocol types in V1, so only walk source
        // (synth + discard) and the body. The for itself opens a scope
        // for the loop variable(s) — match the resolver here.
        if (items.len < 6) return;
        _ = try self.synthExpr(items[4]);
        const prev = self.enterNextScope();
        try self.checkStmt(items[5]);
        self.leaveScope(prev);
        if (items.len > 6 and items[6] != .nil) try self.checkStmt(items[6]);
    }

    /// `(match scrutinee arm...)` at statement position.
    /// Implementation shared with `synthMatchExpr` via `walkMatchArms`.
    fn checkMatchStmt(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        if (items.len < 2) return;
        _ = try self.walkMatchArms(items, .statement);
    }

    /// `(match scrutinee arm...)` at value position. Per GPT-5.5's
    /// design pass for M5(3/n): arms must unify into a single result
    /// type; missing default in a non-exhaustive match is an error.
    fn synthMatchExpr(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        if (items.len < 2) return self.ctx.types.unknown_id;
        return try self.walkMatchArms(items, .value) orelse self.ctx.types.unknown_id;
    }

    const MatchPosition = enum { statement, value };

    /// Walk a match expression, applying the M10 rules:
    ///
    ///   - Synth the scrutinee's type.
    ///   - For each `(arm pattern binding-or-_ body)`:
    ///     * Validate pattern against scrutinee (variant exists, payload
    ///       binding count matches the variant's payload arity).
    ///     * Bind the pattern's captured names with the right types
    ///       (variant payload field types, OR scrutinee type for
    ///       default-bare-ident arms).
    ///     * Walk the body — `checkStmt` for statement-position match,
    ///       `synthExpr` for value-position match (with arm-result
    ///       unification).
    ///   - Detect duplicate arm patterns (same `.X` arm twice).
    ///   - Track exhaustiveness: when the scrutinee's enum has known
    ///     fields and the arms cover every variant, no diagnostic.
    ///     Non-exhaustive without a default arm fires for value-position
    ///     match; statement-position is permissive (emit appends
    ///     `else => unreachable`).
    fn walkMatchArms(self: *ExprChecker, items: []const Sexp, position: MatchPosition) std.mem.Allocator.Error!?TypeId {
        const scrutinee_ty = try self.synthExpr(items[1]);

        // Track which variants the arms cover (for exhaustiveness +
        // duplicate detection). Keys are variant names; values are
        // source positions of the FIRST arm that covered them.
        var covered: std.StringHashMapUnmanaged(u32) = .empty;
        defer covered.deinit(self.ctx.allocator);
        var has_default = false;

        // For value-position match: unified result type across all arms.
        var result_ty: TypeId = self.ctx.types.unknown_id;
        var result_pos: u32 = 0;

        for (items[2..]) |arm| {
            if (arm != .list or arm.list.len < 4 or arm.list[0] != .tag or
                arm.list[0].tag != .@"arm")
            {
                continue;
            }

            const prev = self.enterNextScope();
            defer self.leaveScope(prev);

            const pattern = arm.list[1];
            const body = arm.list[arm.list.len - 1];

            // Pattern checking + binding-type refinement.
            try self.checkArmPattern(pattern, scrutinee_ty, &covered, &has_default);

            // Walk the body. Value position synthesizes + unifies; the
            // statement path just walks for side effects.
            switch (position) {
                .statement => try self.checkStmt(body),
                .value => {
                    const arm_ty = try self.synthExpr(body);
                    const arm_pos = firstSrcPos(body);
                    if (result_ty == self.ctx.types.unknown_id) {
                        result_ty = arm_ty;
                        result_pos = arm_pos;
                    } else {
                        if (try self.unifyOrErr(result_ty, arm_ty, arm_pos)) |unified| {
                            result_ty = unified;
                        }
                    }
                },
            }
        }

        // Value-position exhaustiveness: must have a default OR cover
        // every variant of a known enum.
        if (position == .value and !has_default) {
            const expected_variants = enumVariantCount(self.ctx, scrutinee_ty);
            if (expected_variants) |total| {
                if (covered.count() < total) {
                    try self.err(firstSrcPos(items[1]), "value-position `match` is not exhaustive (covered {d} of {d} variants and no default arm)", .{ covered.count(), total });
                }
            }
        }

        return if (position == .value) result_ty else null;
    }

    /// Validate one arm's pattern against the scrutinee's type, set the
    /// pattern's captured-binding types, and update coverage tracking.
    fn checkArmPattern(
        self: *ExprChecker,
        pattern: Sexp,
        scrutinee_ty: TypeId,
        covered: *std.StringHashMapUnmanaged(u32),
        has_default: *bool,
    ) std.mem.Allocator.Error!void {
        switch (pattern) {
            .src => |s| {
                // Bare ident — catch-all default with binding.
                has_default.* = true;
                const name = self.ctx.source[s.pos..][0..s.len];
                if (!std.mem.eql(u8, name, "_")) {
                    if (self.ctx.lookup(self.current_scope, name)) |sym_id| {
                        // Default-bind takes the scrutinee's type.
                        self.ctx.symbols.items[sym_id].ty = scrutinee_ty;
                    }
                }
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return;
                switch (items[0].tag) {
                    .@"enum_lit" => {
                        // No payload destructure; just validate the variant.
                        try self.checkEnumLit(items, scrutinee_ty);
                        if (identAt(self.ctx.source, items[1])) |vname| {
                            try self.recordCovered(vname, firstSrcPos(pattern), covered);
                        }
                    },
                    .@"variant_pattern" => {
                        try self.checkVariantPattern(items, scrutinee_ty, covered);
                    },
                    .@"enum_pattern" => {
                        // (enum_pattern name) — semi-deprecated alias for enum_lit.
                        if (items.len >= 2 and identAt(self.ctx.source, items[1]) != null) {
                            try self.recordCovered(identAt(self.ctx.source, items[1]).?, firstSrcPos(pattern), covered);
                        }
                    },
                    .@"range_pattern" => {
                        // M13: (range_pattern lo hi). Bounds must be
                        // numeric AND assignable to the scrutinee.
                        // Range patterns count as a coverage of an
                        // (unbounded) span — they never satisfy
                        // exhaustiveness for an enum-typed match,
                        // but they're fine for integer scrutinees.
                        if (items.len >= 3) {
                            try self.checkExpr(items[1], scrutinee_ty);
                            try self.checkExpr(items[2], scrutinee_ty);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn recordCovered(
        self: *ExprChecker,
        name: []const u8,
        pos: u32,
        covered: *std.StringHashMapUnmanaged(u32),
    ) std.mem.Allocator.Error!void {
        if (covered.get(name)) |first_pos| {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            try self.note(first_pos, "first arm here", .{});
            return;
        }
        try covered.put(self.ctx.allocator, name, pos);
    }

    fn checkVariantPattern(
        self: *ExprChecker,
        items: []const Sexp,
        scrutinee_ty: TypeId,
        covered: *std.StringHashMapUnmanaged(u32),
    ) std.mem.Allocator.Error!void {
        const variant_name = identAt(self.ctx.source, items[1]) orelse return;
        const variant_pos: u32 = if (items[1] == .src) items[1].src.pos else 0;
        try self.recordCovered(variant_name, variant_pos, covered);

        // M20c per GPT-5.5: route through `lookupVariant` so both
        // `nominal(Shape)` (plain) and `parameterized_nominal(
        // Option, [Int])` (generic) scrutinees work uniformly. The
        // returned payload field types are already substituted, so
        // pattern bindings on `.some(value)` against `Option(Int)`
        // get `value: Int` rather than `value: T`.
        const resolved = (try lookupVariant(self.ctx, scrutinee_ty, variant_name)) orelse {
            const owner_id_opt = nominalSymOfReceiver(self.ctx, scrutinee_ty);
            const sym_id = owner_id_opt orelse return;
            const enum_sym = self.ctx.symbols.items[sym_id];
            if (enum_sym.fields == null) return; // opaque
            try self.err(variant_pos, "no variant `{s}` on enum `{s}`", .{ variant_name, enum_sym.name });
            if (enum_sym.decl_pos > 0) try self.note(enum_sym.decl_pos, "`{s}` declared here", .{enum_sym.name});
            return;
        };

        // Bind each captured payload name with the matching (substituted)
        // field type.
        const bindings = items[2..];
        const payload = resolved.payload;
        if (payload.len == 0) {
            if (bindings.len > 0) {
                try self.err(variant_pos, "variant `{s}` has no payload to destructure", .{variant_name});
            }
            return;
        }
        if (bindings.len != payload.len) {
            try self.err(variant_pos, "variant `{s}` has {d} payload field{s}, pattern destructures {d}", .{
                variant_name,
                payload.len,
                if (payload.len == 1) @as([]const u8, "") else "s",
                bindings.len,
            });
            return;
        }
        for (bindings, payload) |b, f| {
            if (b != .src) continue;
            const bname = self.ctx.source[b.src.pos..][0..b.src.len];
            if (std.mem.eql(u8, bname, "_")) continue;
            if (self.ctx.lookup(self.current_scope, bname)) |sym_id| {
                self.ctx.symbols.items[sym_id].ty = f.ty;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Expression synth
    // -------------------------------------------------------------------------

    fn synthExpr(self: *ExprChecker, expr: Sexp) std.mem.Allocator.Error!TypeId {
        switch (expr) {
            .nil => return self.ctx.types.void_id,
            .src => |s| return self.synthLeafSrc(s.pos, self.ctx.source[s.pos..][0..s.len]),
            .str => return self.ctx.types.string_id,
            .tag => return self.ctx.types.unknown_id,
            .list => |items| {
                if (items.len == 0 or items[0] != .tag) return self.ctx.types.unknown_id;
                return self.synthList(items);
            },
        }
    }

    fn synthLeafSrc(self: *ExprChecker, pos: u32, text: []const u8) std.mem.Allocator.Error!TypeId {
        if (text.len == 0) return self.ctx.types.unknown_id;
        // Literals (parser leaves these as raw .src slices).
        if (text[0] == '"' or text[0] == '\'') return self.ctx.types.string_id;
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
            return self.ctx.types.bool_id;
        }
        if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "undefined")) {
            return self.ctx.types.unknown_id;
        }
        if (isFloatLiteral(text)) return self.ctx.types.float_literal_id;
        if (isIntLiteral(text)) return self.ctx.types.int_literal_id;
        // Identifier — resolve via symbol table.
        if (self.ctx.lookup(self.current_scope, text)) |sym_id| {
            return self.ctx.symbols.items[sym_id].ty;
        }
        // Unresolved name: defer to ownership/effects passes for
        // diagnostic. Returning `unknown_id` lets type checking
        // proceed without cascading errors.
        _ = pos;
        return self.ctx.types.unknown_id;
    }

    fn synthList(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        const head = items[0].tag;
        return switch (head) {
            .@"call" => try self.synthCall(items),
            .@"member" => try self.synthMember(items),
            .@"index" => try self.synthIndex(items),
            .@"propagate" => try self.synthPropagate(items),
            .@"try" => try self.synthPropagate(items),
            .@"if" => try self.synthIfExpr(items),
            .@"match" => try self.synthMatchExpr(items),
            .@"ternary" => try self.synthTernary(items),
            .@"block" => try self.synthBlock(items),
            // Borrow wrappers — return borrow_read/borrow_write of the
            // inner value's type. Read borrows of `T` are `?T` for sema
            // purposes; ownership pass enforces lifetime separately.
            .@"read" => try self.synthBorrow(items, .borrow_read),
            .@"write" => try self.synthBorrow(items, .borrow_write),
            .@"move" => {
                if (items.len >= 2) return self.synthExpr(items[1]);
                return self.ctx.types.unknown_id;
            },
            // M20d: `*x` (expression position) constructs a shared
            // handle wrapping `typeOf(x)`. Per GPT-5.5: the operand is
            // CONSUMED into the Rc; if the user wants to keep `x`, they
            // write `*(+x)`. That consumption is enforced by the
            // ownership pass (M2-era), not here. This commit only
            // changes the *type* attribution from `unknown` to
            // `shared(T)`; emit lowering lands in M20d(3/5).
            .@"share" => {
                if (items.len < 2) return self.ctx.types.unknown_id;
                const inner = try self.synthExpr(items[1]);
                if (inner == self.ctx.types.unknown_id or inner == self.ctx.types.invalid_id) return inner;
                return self.ctx.types.intern(self.ctx.allocator, .{ .shared = inner }) catch self.ctx.types.invalid_id;
            },
            // M20d: `~x` (expression position) constructs a weak
            // handle from an existing shared handle. The operand MUST
            // be `shared(T)` — diagnose otherwise. Weak refs don't
            // exist independently of a strong ref, per SPEC §Weak
            // Reference.
            .@"weak" => {
                if (items.len < 2) return self.ctx.types.unknown_id;
                const inner = try self.synthExpr(items[1]);
                if (inner == self.ctx.types.unknown_id or inner == self.ctx.types.invalid_id) return inner;
                const inner_ty = self.ctx.types.get(inner);
                switch (inner_ty) {
                    .shared => |t| return self.ctx.types.intern(self.ctx.allocator, .{ .weak = t }) catch self.ctx.types.invalid_id,
                    else => {
                        try self.err(firstSrcPos(items[1]), "`~` weak reference requires a shared handle `*T`; got `{s}`", .{
                            try formatType(self.ctx, inner),
                        });
                        return self.ctx.types.invalid_id;
                    },
                }
            },
            .@"clone", .@"pin", .@"raw" => {
                if (items.len >= 2) return self.synthExpr(items[1]);
                return self.ctx.types.unknown_id;
            },
            // Arithmetic / comparison / logical infixes.
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"**" => try self.synthArith(items),
            .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => try self.synthCompare(items),
            .@"&&", .@"||", .@"not" => try self.synthLogical(items),
            .@"neg" => {
                if (items.len >= 2) return self.synthExpr(items[1]);
                return self.ctx.types.unknown_id;
            },
            // Constructor sugar / record literals — see Q4. With sema we
            // know if the callee is a nominal type; for M5(3/n) we just
            // return `nominal(Sym)` and let downstream emit decide.
            .@"record" => try self.synthRecord(items),
            // Anonymous init, array literal — best-effort unknown.
            .@"anon_init", .@"array" => self.ctx.types.unknown_id,
            // Enum literal `.name` — context-dependent; unknown for now.
            .@"enum_lit" => self.ctx.types.unknown_id,
            else => self.ctx.types.unknown_id,
        };
    }

    fn synthCall(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (call callee args...)
        if (items.len < 2) return self.ctx.types.unknown_id;
        const callee = items[1];

        // If the callee is a known symbol, dispatch on its KIND (not on
        // the symbol's `ty` slot — for nominal types the ty slot is the
        // self-referential type which we don't pre-intern).
        if (callee == .src) {
            const name = self.ctx.source[callee.src.pos..][0..callee.src.len];
            if (self.ctx.lookup(self.current_scope, name)) |sym_id| {
                const sym = self.ctx.symbols.items[sym_id];
                switch (sym.kind) {
                    .function => {
                        const fn_ty = self.ctx.types.get(sym.ty);
                        if (fn_ty == .function) {
                            try self.checkCallArgs(items[2..], fn_ty.function, name, callee.src.pos);
                            return fn_ty.function.returns;
                        }
                    },
                    .nominal_type, .type_alias => {
                        // Constructor call (e.g., `User(name: "Steve")`).
                        // The result is an instance of the nominal type.
                        try self.checkConstructorArgs(items[2..], sym_id, name, callee.src.pos);
                        return self.ctx.types.intern(self.ctx.allocator, .{ .nominal = sym_id }) catch self.ctx.types.unknown_id;
                    },
                    .generic_type => {
                        // M20b(5/5) per GPT-5.5: unannotated generic
                        // construction (e.g., `Box(value: 5)` with no
                        // LHS type annotation) requires expected-type
                        // inference, which V1 does not provide. The
                        // `checkExpr` path (with expected type) handles
                        // the annotated case via `checkGenericConstructorCall`;
                        // reaching `synthCall` for a generic_type
                        // callee means no expected was provided.
                        //
                        // Diagnose and synth args for cascade
                        // suppression.
                        try self.err(callee.src.pos, "generic constructor `{s}` requires an expected type; write `b: {s}(T) = {s}(...)`", .{
                            name, name, name,
                        });
                        for (items[2..]) |arg| _ = try self.synthExpr(arg);
                        return self.ctx.types.unknown_id;
                    },
                    else => {},
                }
            }
        }

        // M20a: dispatch on `(call (member obj name) args)` callees.
        // Three cases (module / nominal-type / value-receiver) per the
        // M20a design — see docs/REACTIVITY-DESIGN.md and the M20
        // conversation summary.
        if (callee == .list and callee.list.len >= 3 and
            callee.list[0] == .tag and callee.list[0].tag == .@"member")
        {
            return self.synthMemberCall(callee.list, items[2..]);
        }

        // Unknown callee: synth args anyway so nested type errors fire.
        for (items[1..]) |arg| _ = try self.synthExpr(arg);
        return self.ctx.types.unknown_id;
    }

    /// M20a: type a `(call (member obj name) args)` form. Three cases:
    ///
    ///   1. `foo.bar()` where `foo` is a `use`d module.
    ///      Cross-module signatures aren't tracked until M15b lands;
    ///      return `unknown` deliberately (NOT a diagnostic).
    ///   2. `Type.method(args)` (associated/static call).
    ///      Look up `method` on `Type`'s `is_method` fields, check
    ///      args, return the declared return type.
    ///   3. `value.method(args)` (instance method call).
    ///      Look up `method` on `value`'s nominal type, validate the
    ///      receiver mode at the call site, check the remaining args
    ///      against `params[1..]`, return the declared return type.
    fn synthMemberCall(
        self: *ExprChecker,
        callee_items: []const Sexp,
        args: []const Sexp,
    ) std.mem.Allocator.Error!TypeId {
        const obj = callee_items[1];
        const name_node = callee_items[2];
        const method_name = identAt(self.ctx.source, name_node) orelse {
            for (args) |a| _ = try self.synthExpr(a);
            return self.ctx.types.unknown_id;
        };
        const name_pos: u32 = if (name_node == .src) name_node.src.pos else 0;

        // Cases 1 + 2: obj is a bare name resolving to a module or nominal type.
        if (obj == .src) {
            const oname = self.ctx.source[obj.src.pos..][0..obj.src.len];
            if (self.ctx.lookup(self.current_scope, oname)) |sym_id| {
                const sym = self.ctx.symbols.items[sym_id];
                switch (sym.kind) {
                    .module => {
                        // Case 1: cross-module call. M15b deferred —
                        // synth args silently, return unknown without
                        // a diagnostic.
                        for (args) |a| _ = try self.synthExpr(a);
                        return self.ctx.types.unknown_id;
                    },
                    .nominal_type, .generic_type => {
                        // Case 2: associated call. All args are
                        // user-supplied; no receiver injection.
                        return self.synthAssociatedCall(sym, method_name, name_pos, args);
                    },
                    else => {},
                }
            }
        }

        // Case 3: instance method call.
        const obj_ty_id = try self.synthExpr(obj);

        // M20d.1 + M20d.2: built-in `.upgrade()` on weak handles.
        //
        // The runtime ships `WeakHandle.upgrade()`, but it's not
        // declared on any Rig nominal — without this special-case,
        // source-level `w.upgrade()` would error with "no method on
        // type `weak(...)`" because `lookupMethod` uses
        // `unwrapReadAccess` which deliberately does NOT peel weak
        // (weak auto-deref would be unsafe).
        //
        // Per the joint M20d.2 design pass with GPT-5.5: `upgrade` is
        // a **built-in method** on `~T`, with the same status as
        // array `.len` or future built-in optional methods. It's
        // NOT a sigil (`^w` was considered and rejected for V1 — see
        // HANDOFF §3); a sigil would be the first one whose normal
        // contract includes failure, and the totality invariant of
        // Rig's sigil family is more valuable than the symmetry win.
        //
        // The returned type is built-in `optional(shared(T))` — NOT
        // user-defined `Option(*T)`. The `T? → Option(T)` desugar
        // is a separate (deferred) milestone.
        //
        // Precedence: built-in `upgrade` on `~T` takes precedence
        // over user-defined `.upgrade()` methods — but only when the
        // receiver is actually weak. If the user has `.upgrade()` on
        // their own type and calls it via `value.upgrade()`, the
        // normal dispatch path handles it. The "rc.upgrade() on a
        // shared handle (not weak)" footgun gets a targeted
        // diagnostic so users who reach for upgrade in the wrong
        // place see an actionable message.
        if (std.mem.eql(u8, method_name, "upgrade")) {
            // Peel borrow wrappers so `(?w).upgrade()` / `(!w).upgrade()`
            // also hit the built-in. We do NOT peel `shared` here —
            // that's the wrong-receiver case below.
            const peeled = unwrapBorrows(self.ctx, obj_ty_id);
            const peeled_ty = self.ctx.types.get(peeled);
            switch (peeled_ty) {
                .weak => |inner| {
                    if (args.len != 0) {
                        try self.err(name_pos, "weak `upgrade` takes no arguments; got {d}", .{args.len});
                        for (args) |a| _ = try self.synthExpr(a);
                    }
                    const shared_id = self.ctx.types.intern(self.ctx.allocator, .{ .shared = inner }) catch
                        return self.ctx.types.unknown_id;
                    return self.ctx.types.intern(self.ctx.allocator, .{ .optional = shared_id }) catch
                        self.ctx.types.unknown_id;
                },
                .shared => {
                    // `rc.upgrade()` where `rc: *T`. If T has its own
                    // `.upgrade()` method, the normal dispatch path
                    // will find it via auto-deref — fall through.
                    // Otherwise fire a targeted diagnostic instead of
                    // the generic "no method" message — users who
                    // reach for `.upgrade()` here almost certainly
                    // meant a weak handle.
                    if (!hasMethodNamed(self.ctx, peeled, method_name)) {
                        try self.err(name_pos, "`upgrade` is only available on weak handles (`~T`); receiver here is a shared handle (`*T`). Use `~rc` to obtain a weak reference, then `.upgrade()` on the weak.", .{});
                        for (args) |a| _ = try self.synthExpr(a);
                        return self.ctx.types.unknown_id;
                    }
                },
                else => {},
            }
        }

        return self.synthInstanceCall(obj, obj_ty_id, method_name, name_pos, args);
    }

    /// Case 2 helper: `Type.method(args)`. The method's full param list
    /// (including any explicit `self`) is matched against the user's
    /// args verbatim — no receiver injection.
    fn synthAssociatedCall(
        self: *ExprChecker,
        nominal_sym: Symbol,
        method_name: []const u8,
        name_pos: u32,
        args: []const Sexp,
    ) std.mem.Allocator.Error!TypeId {
        const fields = nominal_sym.fields orelse {
            // Opaque / unresolved nominal — synth args and return unknown.
            for (args) |a| _ = try self.synthExpr(a);
            return self.ctx.types.unknown_id;
        };

        for (fields) |f| {
            if (!f.is_method) continue;
            if (!std.mem.eql(u8, f.name, method_name)) continue;
            const fn_ty_val = self.ctx.types.get(f.ty);
            if (fn_ty_val != .function) continue;
            try self.checkCallArgs(args, fn_ty_val.function, method_name, name_pos);
            return fn_ty_val.function.returns;
        }

        try self.err(name_pos, "no method `{s}` on type `{s}`", .{ method_name, nominal_sym.name });
        if (nominal_sym.decl_pos > 0) try self.note(nominal_sym.decl_pos, "`{s}` declared here", .{nominal_sym.name});
        for (args) |a| _ = try self.synthExpr(a);
        return self.ctx.types.unknown_id;
    }

    /// Case 3 helper: `value.method(args)`. Looks up the method on the
    /// receiver's nominal type (unwrapping one level of `?T` / `!T`
    /// borrow), validates the receiver mode at the call site per the
    /// M20a rules (auto-`?`, explicit `!`, explicit `<`), and checks
    /// the remaining args against `params[1..]`.
    fn synthInstanceCall(
        self: *ExprChecker,
        receiver_expr: Sexp,
        receiver_ty_id: TypeId,
        method_name: []const u8,
        name_pos: u32,
        args: []const Sexp,
    ) std.mem.Allocator.Error!TypeId {
        // M20b(1/5): unified method lookup via helper. Peels borrows,
        // matches by name + is_method, returns ResolvedMethod with
        // receiver mode + nominal_sym pre-extracted. M20b(4/5) extends
        // the helper to substitute generic type params.
        const resolved = (try lookupMethod(self.ctx, receiver_ty_id, method_name)) orelse {
            // M20b(5/5) per GPT-5.5: nominalSymOfReceiver handles both
            // plain and parameterized nominals. Distinguish "receiver
            // isn't nominal" (silent unknown, matches the
            // unknown-callee policy) from "no such method on this
            // nominal" (diagnostic).
            const owner_id_opt = nominalSymOfReceiver(self.ctx, receiver_ty_id);
            const nom_sym_id = owner_id_opt orelse {
                for (args) |a| _ = try self.synthExpr(a);
                return self.ctx.types.unknown_id;
            };
            const nom_sym = self.ctx.symbols.items[nom_sym_id];
            // Opaque nominal (no fields) also stays silent.
            if (nom_sym.fields == null) {
                for (args) |a| _ = try self.synthExpr(a);
                return self.ctx.types.unknown_id;
            }
            try self.err(name_pos, "no method `{s}` on type `{s}`", .{ method_name, nom_sym.name });
            if (nom_sym.decl_pos > 0) try self.note(nom_sym.decl_pos, "`{s}` declared here", .{nom_sym.name});
            for (args) |a| _ = try self.synthExpr(a);
            return self.ctx.types.unknown_id;
        };

        const nominal_sym = self.ctx.symbols.items[resolved.nominal_sym];

        // M20a.2: dispatch on the receiver metadata established at
        // decl-time, NOT on `params.len > 0`. Otherwise associated/
        // static methods with parameters silently dispatch as
        // instance methods — the M20a soundness bug GPT-5.5 caught.
        if (resolved.receiver == .none) {
            try self.err(name_pos, "method `{s}` has no `self` receiver; call as `{s}.{s}(...)`", .{
                method_name, nominal_sym.name, method_name,
            });
            for (args) |a| _ = try self.synthExpr(a);
            return resolved.fn_ty.returns;
        }

        // Validate receiver mode at the call site using the method's
        // declared receiver mode (decl-time, authoritative). M20a.2:
        // also pass the receiver expression's TYPE classification so
        // we catch e.g. `get_ref().consume()` where the rvalue is
        // actually a read borrow (would be silently accepted on shape
        // alone).
        const recv_type_kind = classifyReceiverType(self.ctx, receiver_ty_id, resolved.nominal_sym);
        try self.checkReceiverMode(receiver_expr, resolved.receiver, recv_type_kind, method_name, name_pos);

        // Check the remaining args against `params[1..]`. (Instance
        // methods always have at least one param — `self` — by
        // construction of resolved.receiver != .none.)
        const non_self_fn = FunctionType{
            .params = resolved.fn_ty.params[1..],
            .returns = resolved.fn_ty.returns,
            .is_sub = resolved.fn_ty.is_sub,
        };
        try self.checkCallArgs(args, non_self_fn, method_name, name_pos);
        return resolved.fn_ty.returns;
    }

    /// M20a receiver-mode rules (per GPT-5.5):
    ///
    ///   self param  | call-site requirement
    ///   ------------|----------------------------------------------------
    ///   ?Self       | auto-borrow OK from bare lvalue; explicit ? OK;
    ///               | explicit ! OK (write coerces to read); cannot move
    ///   !Self       | require explicit (!receiver); cannot pass bare,
    ///               | cannot pass read borrow, cannot move; rvalue OK
    ///   Self        | require explicit (<receiver) for named lvalue;
    ///               | rvalue (call result) OK; borrow forms rejected
    ///
    /// Visible-effects principle: write borrow and move are dramatic
    /// effects and must be visible at the call site. Read borrow is
    /// lightweight enough to auto-insert.
    fn checkReceiverMode(
        self: *ExprChecker,
        receiver_expr: Sexp,
        receiver: MethodReceiver,
        recv_type_kind: ReceiverTypeKind,
        method_name: []const u8,
        name_pos: u32,
    ) std.mem.Allocator.Error!void {
        const shape = classifyReceiverShape(receiver_expr);

        switch (receiver) {
            .read => {
                // ?Self — auto-borrow OK. Any receiver-type kind that
                // resolves to the enclosing nominal is fine; `other`
                // typed receivers (different nominal, unknown, etc.)
                // also slide silently — sema has likely already fired
                // a more useful diagnostic elsewhere.
                switch (shape) {
                    .move_explicit => {
                        try self.err(name_pos, "method `{s}` takes a read borrow of receiver; cannot move", .{method_name});
                    },
                    else => return,
                }
            },
            .write => {
                // !Self — require explicit write borrow OR a write-
                // borrowed type at call site OR an owned rvalue.
                // Reject: read borrow (type or shape), bare lvalue
                // without explicit !, explicit move.
                if (recv_type_kind == .read_borrow) {
                    try self.err(name_pos, "method `{s}` requires a write-borrowed receiver; cannot upgrade a read borrow to a write borrow", .{method_name});
                    return;
                }
                // M20d(4/5): write-receiver methods are not callable
                // through a shared (`*T`) handle. `*T` is shared
                // ownership — other handles may exist, so we cannot
                // hand out unique mutable access. The user-facing
                // pattern for mutation through `*T` is interior
                // mutability (`Cell(T)` / `RefCell(T)`, M20+ item #7).
                if (recv_type_kind == .shared) {
                    try self.err(name_pos, "cannot call write-receiver method `{s}` through a shared handle (`*T`); other handles may exist. Use an interior-mutable type (planned `Cell(T)` in M20+ item #7) for mutation through shared ownership.", .{method_name});
                    return;
                }
                switch (shape) {
                    .write_explicit => return, // explicit (!u)
                    .rvalue => {
                        // OK only if the rvalue's type is owned or
                        // already write-borrowed. (Read-borrow rvalue
                        // already rejected above.) `.other` slides —
                        // sema has likely fired a more useful error
                        // elsewhere, and we don't want to compound it.
                        if (recv_type_kind == .owned_nominal or
                            recv_type_kind == .write_borrow or
                            recv_type_kind == .other) return;
                        try self.err(name_pos, "method `{s}` requires a write-borrowed receiver; this expression yields a borrowed value, not an owned one", .{method_name});
                    },
                    .read_explicit => try self.err(name_pos, "method `{s}` requires a write-borrowed receiver; got `?...`; use `(!receiver).{s}(...)`", .{ method_name, method_name }),
                    .move_explicit => try self.err(name_pos, "method `{s}` requires a write-borrowed receiver; cannot move; use `(!receiver).{s}(...)`", .{ method_name, method_name }),
                    .lvalue_bare => try self.err(name_pos, "method `{s}` requires a write-borrowed receiver; use `(!receiver).{s}(...)`", .{ method_name, method_name }),
                }
            },
            .value => {
                // By-value Self — require explicit move OR owned
                // rvalue. Reject any borrow (read or write), bare
                // lvalue without explicit `<`.
                switch (recv_type_kind) {
                    .read_borrow, .write_borrow => {
                        try self.err(name_pos, "method `{s}` consumes the receiver; cannot consume through a borrowed value", .{method_name});
                        return;
                    },
                    // M20d(4/5): consuming the inner T through a
                    // shared handle is impossible — other handles
                    // would dangle. Pattern: explicitly `.upgrade()` a
                    // weak or `+rc` clone, but for consuming inner T
                    // you need exclusive ownership which `*T` cannot
                    // provide. Reject cleanly.
                    .shared => {
                        try self.err(name_pos, "method `{s}` consumes the receiver; cannot consume the inner value through a shared handle (`*T`) — other handles may still reference it", .{method_name});
                        return;
                    },
                    else => {},
                }
                switch (shape) {
                    .move_explicit => return,
                    .rvalue => {
                        // OK only if owned. (Borrow returned from
                        // a call was rejected above on type kind.)
                        if (recv_type_kind == .owned_nominal or recv_type_kind == .other) return;
                        try self.err(name_pos, "method `{s}` consumes the receiver; this expression yields a borrowed value, not an owned one", .{method_name});
                    },
                    .read_explicit, .write_explicit => try self.err(name_pos, "method `{s}` consumes the receiver; borrow forms not allowed; use `(<receiver).{s}(...)`", .{ method_name, method_name }),
                    .lvalue_bare => try self.err(name_pos, "method `{s}` consumes the receiver; use `(<receiver).{s}(...)`", .{ method_name, method_name }),
                }
            },
            .none => {
                // Should never reach here — synthInstanceCall errors
                // for `none` receivers before calling checkReceiverMode.
                // Belt-and-suspenders guard.
            },
        }
    }

    /// Constructor invocation `T(name: value, ...)` against a nominal
    /// type's declared fields. M6 v1 rules:
    ///   - Each kwarg must reference a real field (else: unknown-field error)
    ///   - Each kwarg's value must be assignable to the field's type
    ///   - Duplicate kwargs are rejected
    ///   - Missing fields are reported (per missing field, with the
    ///     struct's decl pos as a note)
    ///   - Positional args inside a kwarg-bearing call are V1-disallowed
    ///     (constructor must be all-kwarg or all-positional; mixed is
    ///     undefined surface and we just synth-and-discard those args).
    /// If the nominal has no resolved fields (opaque / undeclared
    /// struct), we synth args and discard — same behavior as M5.
    fn checkConstructorArgs(
        self: *ExprChecker,
        args: []const Sexp,
        nominal_sym: SymbolId,
        callee_name: []const u8,
        callee_pos: u32,
    ) std.mem.Allocator.Error!void {
        try self.checkConstructorArgsSubst(args, nominal_sym, callee_name, callee_pos, TypeSubst.empty);
    }

    /// M20b(4/5): generic-aware constructor checking. When `subst` is
    /// non-empty, each declared field type is substituted (T → arg)
    /// before being compared against the supplied kwarg's value type.
    /// For plain nominals, callers pass `TypeSubst.empty` (or use the
    /// `checkConstructorArgs` convenience wrapper above).
    fn checkConstructorArgsSubst(
        self: *ExprChecker,
        args: []const Sexp,
        nominal_sym: SymbolId,
        callee_name: []const u8,
        callee_pos: u32,
        subst: TypeSubst,
    ) std.mem.Allocator.Error!void {
        const sym = self.ctx.symbols.items[nominal_sym];
        const fields = sym.fields orelse {
            // No field metadata — opaque nominal. Synth args, return.
            for (args) |a| _ = try self.synthExpr(a);
            return;
        };

        // Track which fields were supplied so we can report missing ones.
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        defer seen.deinit(self.ctx.allocator);

        var has_positional = false;
        for (args) |arg| {
            if (arg == .list and arg.list.len >= 3 and arg.list[0] == .tag and
                arg.list[0].tag == .@"kwarg")
            {
                const fname = identAt(self.ctx.source, arg.list[1]) orelse continue;
                const fpos: u32 = if (arg.list[1] == .src) arg.list[1].src.pos else callee_pos;

                // Duplicate kwarg?
                if (seen.contains(fname)) {
                    try self.err(fpos, "duplicate field `{s}` in constructor of `{s}`", .{ fname, callee_name });
                    if (seen.get(fname)) |first_pos| try self.note(first_pos, "first `{s}` here", .{fname});
                    continue;
                }
                try seen.put(self.ctx.allocator, fname, fpos);

                // Find the DATA field in the declared list. M20a:
                // methods (is_method=true) share the same `fields`
                // slice but aren't constructor-targetable, so skip them.
                const field = blk: {
                    for (fields) |f| {
                        if (f.is_method) continue;
                        if (std.mem.eql(u8, f.name, fname)) break :blk f;
                    }
                    try self.err(fpos, "no field `{s}` on type `{s}`", .{ fname, callee_name });
                    if (sym.decl_pos > 0) try self.note(sym.decl_pos, "`{s}` declared here", .{callee_name});
                    _ = try self.synthExpr(arg.list[2]);
                    break :blk null;
                } orelse continue;

                // M20b(4/5): substitute the field's declared type
                // against the expected-type's args (T → Int for
                // `Box(Int)`). For plain nominals subst is empty so
                // this is a no-op. M20b(5/5) per GPT-5.5: propagate
                // allocator errors. No `type_var` skip — `compatible`
                // does the right thing (`type_var(T)` equals itself
                // and nothing else), so symbolic generic-body
                // constructor checking now correctly catches
                // `b: Self = Box(value: "wrong type")` inside a
                // generic body.
                const substituted_field_ty = try substituteType(self.ctx, field.ty, subst);
                try self.checkExpr(arg.list[2], substituted_field_ty);
            } else {
                has_positional = true;
                _ = try self.synthExpr(arg);
            }
        }

        // Missing-field check (only when the call was all-kwarg —
        // mixed/positional constructors are undefined surface in V1).
        // M20a: skip methods (is_method=true) — they're not
        // constructor-targetable.
        if (!has_positional and fields.len > 0) {
            for (fields) |f| {
                if (f.is_method) continue;
                if (!seen.contains(f.name)) {
                    try self.err(callee_pos, "constructor of `{s}` is missing field `{s}`", .{ callee_name, f.name });
                    if (f.decl_pos > 0) try self.note(f.decl_pos, "field `{s}` declared here", .{f.name});
                }
            }
        }
    }

    fn checkCallArgs(
        self: *ExprChecker,
        args: []const Sexp,
        fn_ty: FunctionType,
        callee_name: []const u8,
        callee_pos: u32,
    ) std.mem.Allocator.Error!void {
        // V1: only positional args are type-checked. Skip arity/type
        // check entirely if any arg is a `(kwarg ...)` — constructor
        // sugar uses kwargs and we can't map them to params yet without
        // struct field metadata.
        for (args) |a| {
            if (a == .list and a.list.len > 0 and a.list[0] == .tag and
                a.list[0].tag == .@"kwarg")
            {
                for (args) |aa| _ = try self.synthExpr(aa);
                return;
            }
        }

        if (args.len != fn_ty.params.len) {
            try self.err(callee_pos, "call to `{s}` expects {d} argument{s}, got {d}", .{
                callee_name,
                fn_ty.params.len,
                if (fn_ty.params.len == 1) @as([]const u8, "") else "s",
                args.len,
            });
            for (args) |a| _ = try self.synthExpr(a);
            return;
        }
        for (args, fn_ty.params) |arg, param_ty| {
            try self.checkExpr(arg, param_ty);
        }
    }

    fn synthMember(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (member obj name). Two flavors:
        //
        //   1. Type-qualified access: obj is a `.src` whose name
        //      resolves to a `nominal_type` symbol (typically an
        //      enum/errors). `Color.red` is then equivalent to
        //      `.red` in a `Color`-expecting context — return
        //      `nominal(Color)`. Unknown variant fires.
        //
        //   2. Value member access: obj's TYPE is `nominal(SymId)`
        //      (struct instance). Look up the field on the symbol;
        //      return its declared type. Unknown field fires.
        //
        //   3. Anything else (opaque nominal, primitive, unresolved)
        //      returns `unknown` silently so downstream typing keeps
        //      flowing without spurious errors.
        if (items.len < 3) return self.ctx.types.unknown_id;

        const obj = items[1];
        const field_node = items[2];
        const field_name = identAt(self.ctx.source, field_node) orelse return self.ctx.types.unknown_id;
        const pos: u32 = if (field_node == .src) field_node.src.pos else 0;

        // Flavor 1: type-qualified access (e.g., `Color.red`, `User.greet`).
        if (obj == .src) {
            const oname = self.ctx.source[obj.src.pos..][0..obj.src.len];
            if (self.ctx.lookup(self.current_scope, oname)) |sym_id| {
                const sym = self.ctx.symbols.items[sym_id];
                if (sym.kind == .nominal_type) {
                    if (sym.fields) |members| {
                        for (members) |m| {
                            if (!std.mem.eql(u8, m.name, field_name)) continue;
                            if (m.is_method) {
                                // M12: `Type.method` — return the
                                // method's function type so the
                                // surrounding call can dispatch.
                                return m.ty;
                            }
                            // Variant — return `nominal(Type)` (the
                            // enum instance type).
                            return self.ctx.types.intern(self.ctx.allocator, .{ .nominal = sym_id }) catch self.ctx.types.unknown_id;
                        }
                        try self.err(pos, "no member `{s}` on type `{s}`", .{ field_name, sym.name });
                        if (sym.decl_pos > 0) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
                        return self.ctx.types.unknown_id;
                    }
                    // Opaque nominal — accept silently.
                    return self.ctx.types.intern(self.ctx.allocator, .{ .nominal = sym_id }) catch self.ctx.types.unknown_id;
                }
            }
        }

        // Flavor 2: value member access on a struct instance.
        const obj_ty_id = try self.synthExpr(obj);
        if (obj_ty_id == self.ctx.types.invalid_id or obj_ty_id == self.ctx.types.unknown_id) {
            return self.ctx.types.unknown_id;
        }

        // M20b(1/5): unified data-field lookup via helper. Peels
        // borrows and returns the (possibly substituted) field type.
        if (try lookupDataField(self.ctx, obj_ty_id, field_name)) |resolved| {
            return resolved.ty;
        }

        // No data field by that name — was it a method? If so, give a
        // targeted "must be called" error. Otherwise fall through to
        // the generic "no field on type" diagnostic.
        // M20b(5/5) per GPT-5.5: nominalSymOfReceiver handles both
        // plain and parameterized nominals uniformly.
        const owner_id_opt = nominalSymOfReceiver(self.ctx, obj_ty_id);
        if (hasMethodNamed(self.ctx, obj_ty_id, field_name)) {
            const nom_name = if (owner_id_opt) |id| self.ctx.symbols.items[id].name else "(unknown)";
            try self.err(pos, "method `{s}` on type `{s}` must be called; bare method reference not supported in V1", .{ field_name, nom_name });
            return self.ctx.types.unknown_id;
        }

        // No-such-field diagnostic. Skip silently if the receiver
        // didn't resolve to any nominal — sema has likely already
        // diagnosed the upstream issue.
        const sym_id = owner_id_opt orelse return self.ctx.types.unknown_id;
        const sym = self.ctx.symbols.items[sym_id];
        try self.err(pos, "no field `{s}` on type `{s}`", .{ field_name, sym.name });
        if (sym.decl_pos > 0) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
        return self.ctx.types.unknown_id;
    }

    fn synthIndex(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (index expr idx) — for slice/array T, returns T; otherwise unknown.
        if (items.len < 3) return self.ctx.types.unknown_id;
        const obj_ty = try self.synthExpr(items[1]);
        _ = try self.synthExpr(items[2]); // walk idx for nested errors
        const ty = self.ctx.types.get(obj_ty);
        return switch (ty) {
            .slice => |s| s.elem,
            .array => |a| a.elem,
            .optional => |inner| inner, // unwrap T? to T (ish) for indexing
            else => self.ctx.types.unknown_id,
        };
    }

    fn synthPropagate(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (propagate expr) / (try expr) — unwrap one fallible layer.
        if (items.len < 2) return self.ctx.types.unknown_id;
        const inner = try self.synthExpr(items[1]);
        const ty = self.ctx.types.get(inner);
        return switch (ty) {
            .fallible => |t| t,
            // Effects checker fires its own diagnostic if propagation
            // is applied to a non-fallible value; here we just let the
            // type flow through unchanged.
            else => inner,
        };
    }

    fn synthIfExpr(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // Value-position `if`. Per GPT-5.5: condition must be Bool, an
        // else IS required, then-arm and else-arm types must unify.
        if (items.len < 2) return self.ctx.types.unknown_id;
        try self.checkExpr(items[1], self.ctx.types.bool_id);

        if (items.len < 4 or items[3] == .nil) {
            // Missing else in value position. Find a position to point at.
            const pos = firstSrcPos(items[2]);
            try self.err(pos, "`if` expression used as a value requires an `else` branch", .{});
            return self.ctx.types.unknown_id;
        }

        const then_ty = if (items[2] == .nil) self.ctx.types.void_id else try self.synthExpr(items[2]);
        const else_ty = try self.synthExpr(items[3]);
        return (try self.unifyOrErr(then_ty, else_ty, firstSrcPos(items[2]))) orelse self.ctx.types.unknown_id;
    }

    fn synthTernary(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (ternary cond then else)
        if (items.len < 4) return self.ctx.types.unknown_id;
        try self.checkExpr(items[1], self.ctx.types.bool_id);
        const then_ty = try self.synthExpr(items[2]);
        const else_ty = try self.synthExpr(items[3]);
        return (try self.unifyOrErr(then_ty, else_ty, firstSrcPos(items[2]))) orelse self.ctx.types.unknown_id;
    }

    fn synthBlock(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (block stmts...) — value-position block returns the type of
        // its last expression. Walk all but the last as statements.
        if (items.len <= 1) return self.ctx.types.void_id;
        for (items[1 .. items.len - 1]) |s| try self.checkStmt(s);
        return self.synthExpr(items[items.len - 1]);
    }

    fn synthBorrow(self: *ExprChecker, items: []const Sexp, comptime kind: std.meta.Tag(Type)) std.mem.Allocator.Error!TypeId {
        if (items.len < 2) return self.ctx.types.unknown_id;
        const inner = try self.synthExpr(items[1]);
        if (inner == self.ctx.types.unknown_id or inner == self.ctx.types.invalid_id) return inner;
        return switch (kind) {
            .borrow_read => self.ctx.types.intern(self.ctx.allocator, .{ .borrow_read = inner }) catch self.ctx.types.invalid_id,
            .borrow_write => self.ctx.types.intern(self.ctx.allocator, .{ .borrow_write = inner }) catch self.ctx.types.invalid_id,
            else => self.ctx.types.unknown_id,
        };
    }

    fn synthArith(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (op a b) — both args must be numeric, result is unified type.
        if (items.len < 3) return self.ctx.types.unknown_id;
        const a = try self.synthExpr(items[1]);
        const b = try self.synthExpr(items[2]);
        // Don't error on numeric mismatch yet — V1 lets users mix
        // unsized literals freely, and we have no coercion for sized
        // numerics. Just pick the first non-literal type if available.
        if (isNumeric(self.ctx, a) and isNumeric(self.ctx, b)) {
            return (try self.unifyOrErr(a, b, firstSrcPos(items[1]))) orelse self.ctx.types.unknown_id;
        }
        return self.ctx.types.unknown_id;
    }

    fn synthCompare(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        if (items.len >= 3) {
            _ = try self.synthExpr(items[1]);
            _ = try self.synthExpr(items[2]);
        }
        return self.ctx.types.bool_id;
    }

    fn synthLogical(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        if (items.len >= 2) try self.checkExpr(items[1], self.ctx.types.bool_id);
        if (items.len >= 3) try self.checkExpr(items[2], self.ctx.types.bool_id);
        return self.ctx.types.bool_id;
    }

    fn synthRecord(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!TypeId {
        // (record TypeName members...) — V1 doesn't track fields.
        if (items.len < 2) return self.ctx.types.unknown_id;
        const name_node = items[1];
        if (identAt(self.ctx.source, name_node)) |nm| {
            if (self.ctx.lookup(self.current_scope, nm)) |sym_id| {
                const sym = self.ctx.symbols.items[sym_id];
                if (sym.kind == .nominal_type or sym.kind == .type_alias) return sym.ty;
            }
        }
        return self.ctx.types.unknown_id;
    }

    // -------------------------------------------------------------------------
    // checkExpr — synth + compatibility-check
    // -------------------------------------------------------------------------

    fn checkExpr(self: *ExprChecker, expr: Sexp, expected: TypeId) std.mem.Allocator.Error!void {
        // M20f(3/4): propagate expected type through `(share x)`. The
        // pattern `*Cell(value: 0)` with expected `*Cell(Int)` parses
        // as `(share (call Cell (kwarg value 0)))` and the inner
        // `Cell(...)` constructor needs the expected `Cell(Int)` to
        // drive its expected-type-based generic substitution
        // (otherwise it fires the "unannotated generic constructor"
        // diagnostic). The simplest fix is to unwrap the shared
        // wrapper from the expected type and recursively check the
        // inner expression. The result-type compatibility check is
        // automatic — if inner produces `Cell(Int)`, the outer
        // `(share ...)` produces `shared(Cell(Int))` which matches
        // the original expected.
        if (expr == .list and expr.list.len >= 2 and expr.list[0] == .tag and
            expr.list[0].tag == .@"share")
        {
            const expected_ty = self.ctx.types.get(expected);
            if (expected_ty == .shared) {
                try self.checkExpr(expr.list[1], expected_ty.shared);
                return;
            }
        }

        // M7: enum literal `.red` is intrinsically context-typed —
        // synth would return `unknown` (no enum is named in the
        // expression itself). When the expected type is a nominal
        // enum, validate the variant against the enum's field list
        // here instead of falling through to `synthExpr` and silently
        // accepting unknown.
        if (expr == .list and expr.list.len >= 2 and expr.list[0] == .tag and
            expr.list[0].tag == .@"enum_lit")
        {
            try self.checkEnumLit(expr.list, expected);
            return;
        }

        // M9b: payload-bearing variant construction `.circle(radius: 5)`
        // parses as `(call (enum_lit circle) (kwarg radius 5))` — same
        // contextual typing pattern. When the expected type is a nominal
        // enum and the call's callee is `(enum_lit name)`, validate the
        // variant + check args against the variant's payload fields.
        if (expr == .list and expr.list.len >= 2 and expr.list[0] == .tag and
            expr.list[0].tag == .@"call" and expr.list[1] == .list and
            expr.list[1].list.len >= 2 and expr.list[1].list[0] == .tag and
            expr.list[1].list[0].tag == .@"enum_lit")
        {
            try self.checkPayloadVariantCall(expr.list, expected);
            return;
        }

        // M20b(4/5): generic constructor with expected parameterized_nominal.
        // `Box(value: 5)` with expected `Box(Int)` should check the value
        // against the substituted field type (T → Int). Without this
        // expected-type-driven substitution, `synthCall` returns
        // `nominal(Box)` for the constructor (no inference) and the
        // compatibility check fails with "expected Box(Int), got Box".
        // Per GPT-5.5: "Design for expected-type-driven generic
        // construction, not inference."
        if (expr == .list and expr.list.len >= 2 and expr.list[0] == .tag and
            expr.list[0].tag == .@"call" and expr.list[1] == .src)
        {
            const expected_ty = self.ctx.types.get(expected);
            if (expected_ty == .parameterized_nominal) {
                const callee_src = expr.list[1].src;
                const callee_name = self.ctx.source[callee_src.pos..][0..callee_src.len];
                if (self.ctx.lookup(self.current_scope, callee_name)) |sym_id| {
                    if (sym_id == expected_ty.parameterized_nominal.sym) {
                        try self.checkGenericConstructorCall(expr.list, expected_ty.parameterized_nominal, callee_name, callee_src.pos);
                        return;
                    }
                }
            }
        }

        const actual = try self.synthExpr(expr);
        if (compatible(self.ctx, actual, expected)) return;
        const pos = firstSrcPos(expr);
        try self.err(pos, "type mismatch: expected `{s}`, got `{s}`", .{
            try formatType(self.ctx, expected),
            try formatType(self.ctx, actual),
        });
    }

    /// M20b(4/5): `Box(value: 5)` with expected `Box(Int)` — the
    /// expected-type's args become the substitution for field-type
    /// checking. Called by `checkExpr` when the constructor's callee
    /// matches the expected `parameterized_nominal`'s sym.
    fn checkGenericConstructorCall(
        self: *ExprChecker,
        items: []const Sexp,
        pn: ParamNominal,
        callee_name: []const u8,
        callee_pos: u32,
    ) std.mem.Allocator.Error!void {
        // items: (call <name> args...)
        const args = items[2..];
        const sym = self.ctx.symbols.items[pn.sym];
        const tparams = sym.type_params orelse &.{};
        const subst: TypeSubst = .{ .params = tparams, .args = pn.args };
        try self.checkConstructorArgsSubst(args, pn.sym, callee_name, callee_pos, subst);
    }

    /// `(call (enum_lit name) args...)` — payload-variant construction
    /// against an `expected` nominal enum. Errors if the variant
    /// doesn't exist; otherwise checks args against the variant's
    /// payload field list.
    ///
    /// Arg matching mirrors `checkConstructorArgs` for structs:
    ///   - all-kwarg: each kwarg names a real payload field, types
    ///     check, no duplicates, no missing
    ///   - all-positional: arity must match payload field count, types
    ///     checked positionally
    ///   - mixed: V1-undefined, args synth-and-discarded
    fn checkPayloadVariantCall(self: *ExprChecker, items: []const Sexp, expected: TypeId) std.mem.Allocator.Error!void {
        const callee = items[1].list;
        const variant_name = identAt(self.ctx.source, callee[1]) orelse return;
        const variant_pos: u32 = if (callee[1] == .src) callee[1].src.pos else 0;

        // M20c per GPT-5.5: route through `lookupVariant` so both
        // plain `nominal(Shape)` and generic `parameterized_nominal(
        // Option, [Int])` receivers work uniformly, with payload field
        // types already substituted (T → Int).
        const resolved = (try lookupVariant(self.ctx, expected, variant_name)) orelse {
            // Not a known enum context — could be no expected type, or
            // the expected isn't an enum at all. Distinguish silent vs
            // diagnostic via the receiver's nominal classification.
            const owner_id_opt = nominalSymOfReceiver(self.ctx, expected);
            const sym_id = owner_id_opt orelse return;
            const sym = self.ctx.symbols.items[sym_id];
            if (sym.fields == null) return; // opaque
            try self.err(variant_pos, "no variant `{s}` on enum `{s}`", .{ variant_name, sym.name });
            if (sym.decl_pos > 0) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
            return;
        };
        const enum_sym = self.ctx.symbols.items[resolved.nominal_sym];

        const args = items[2..];
        if (resolved.payload.len == 0) {
            // Bare variant called with args → mismatch.
            if (args.len > 0) {
                try self.err(variant_pos, "variant `{s}` of enum `{s}` takes no payload", .{ variant_name, enum_sym.name });
            }
            return;
        }
        const payload = resolved.payload;

        // Decide arg style.
        var has_kwarg = false;
        var has_positional = false;
        for (args) |a| {
            if (a == .list and a.list.len > 0 and a.list[0] == .tag and a.list[0].tag == .@"kwarg") {
                has_kwarg = true;
            } else {
                has_positional = true;
            }
        }

        if (has_kwarg and !has_positional) {
            try self.checkPayloadKwargs(args, payload, variant_name, enum_sym.name, variant_pos);
        } else if (has_positional and !has_kwarg) {
            try self.checkPayloadPositional(args, payload, variant_name, variant_pos);
        } else {
            // Mixed or empty — V1 doesn't define behavior; just synth.
            for (args) |a| _ = try self.synthExpr(a);
        }
    }

    fn checkPayloadKwargs(
        self: *ExprChecker,
        args: []const Sexp,
        payload: []const Field,
        variant_name: []const u8,
        enum_name: []const u8,
        variant_pos: u32,
    ) std.mem.Allocator.Error!void {
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        defer seen.deinit(self.ctx.allocator);

        for (args) |arg| {
            if (arg != .list or arg.list.len < 3 or arg.list[0] != .tag or
                arg.list[0].tag != .@"kwarg") continue;
            const fname = identAt(self.ctx.source, arg.list[1]) orelse continue;
            const fpos: u32 = if (arg.list[1] == .src) arg.list[1].src.pos else variant_pos;

            if (seen.contains(fname)) {
                try self.err(fpos, "duplicate field `{s}` in variant `{s}`", .{ fname, variant_name });
                if (seen.get(fname)) |first_pos| try self.note(first_pos, "first `{s}` here", .{fname});
                continue;
            }
            try seen.put(self.ctx.allocator, fname, fpos);

            const field = blk: {
                for (payload) |f| if (std.mem.eql(u8, f.name, fname)) break :blk f;
                try self.err(fpos, "no field `{s}` on variant `{s}` of `{s}`", .{ fname, variant_name, enum_name });
                _ = try self.synthExpr(arg.list[2]);
                break :blk null;
            } orelse continue;

            try self.checkExpr(arg.list[2], field.ty);
        }

        for (payload) |f| {
            if (!seen.contains(f.name)) {
                try self.err(variant_pos, "variant `{s}` is missing field `{s}`", .{ variant_name, f.name });
            }
        }
    }

    fn checkPayloadPositional(
        self: *ExprChecker,
        args: []const Sexp,
        payload: []const Field,
        variant_name: []const u8,
        variant_pos: u32,
    ) std.mem.Allocator.Error!void {
        if (args.len != payload.len) {
            try self.err(variant_pos, "variant `{s}` expects {d} payload field{s}, got {d}", .{
                variant_name,
                payload.len,
                if (payload.len == 1) @as([]const u8, "") else "s",
                args.len,
            });
            for (args) |a| _ = try self.synthExpr(a);
            return;
        }
        for (args, payload) |arg, f| {
            try self.checkExpr(arg, f.ty);
        }
    }

    /// Validate `(enum_lit name)` against an `expected` nominal enum
    /// type. M7 v1 rules:
    ///   - Expected must be `nominal(SymId)` where the symbol is a
    ///     `nominal_type` with `fields` populated (i.e., a known enum).
    ///     Anything else: silently accept (unknown context, deferred).
    ///   - The variant name must appear in the enum's fields.
    ///     Otherwise: `error: no variant 'red' on type 'Color'`.
    fn checkEnumLit(self: *ExprChecker, items: []const Sexp, expected: TypeId) std.mem.Allocator.Error!void {
        const variant_node = items[1];
        const variant_name = identAt(self.ctx.source, variant_node) orelse return;
        const variant_pos: u32 = if (variant_node == .src) variant_node.src.pos else 0;

        // M20c per GPT-5.5: route through `lookupVariant` so both
        // `nominal(Color)` (plain) and `parameterized_nominal(Option,
        // [Int])` (generic) receivers work uniformly.
        if (try lookupVariant(self.ctx, expected, variant_name)) |_| return;

        // No match — either the expected type isn't an enum at all
        // (accept silently — no useful context), or it is but the
        // variant doesn't exist (diagnose).
        const owner_id_opt = nominalSymOfReceiver(self.ctx, expected);
        const sym_id = owner_id_opt orelse return;
        const sym = self.ctx.symbols.items[sym_id];
        if (sym.fields == null) return; // opaque nominal — accept silently
        try self.err(variant_pos, "no variant `{s}` on enum `{s}`", .{ variant_name, sym.name });
        if (sym.decl_pos > 0) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
    }

    /// Best-effort unification: returns the unified type id, or null
    /// after emitting a diagnostic. Literal pseudo-types adapt to
    /// matching numeric concrete types.
    fn unifyOrErr(self: *ExprChecker, a: TypeId, b: TypeId, pos: u32) std.mem.Allocator.Error!?TypeId {
        if (a == b) return a;
        if (a == self.ctx.types.unknown_id or a == self.ctx.types.invalid_id) return b;
        if (b == self.ctx.types.unknown_id or b == self.ctx.types.invalid_id) return a;

        // Literal pseudo-types adapt to concrete numeric.
        if (compatible(self.ctx, a, b)) return b;
        if (compatible(self.ctx, b, a)) return a;

        try self.err(pos, "incompatible types `{s}` and `{s}`", .{
            try formatType(self.ctx, a),
            try formatType(self.ctx, b),
        });
        return null;
    }

    /// Promote literal pseudo-types to canonical concrete forms (used
    /// when storing on a symbol so downstream uses see `Int`/`Float`).
    fn canonicalize(self: *ExprChecker, ty: TypeId) TypeId {
        if (ty == self.ctx.types.int_literal_id) return self.ctx.types.int_id;
        if (ty == self.ctx.types.float_literal_id) return self.ctx.types.float_id;
        return ty;
    }
};

/// Compatibility: is `actual` acceptable where `expected` is required?
/// See the rule table at the top of "Expression Typing".
fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    if (actual == expected) return true;
    // Sentinel propagation — unknown / invalid never produce a mismatch.
    if (actual == ctx.types.invalid_id or expected == ctx.types.invalid_id) return true;
    if (actual == ctx.types.unknown_id or expected == ctx.types.unknown_id) return true;

    const a = ctx.types.get(actual);
    const e = ctx.types.get(expected);

    // Literal pseudo-types adapt to matching numeric concrete types.
    if (a == .int_literal) {
        return switch (e) {
            .int, .int_literal => true,
            else => false,
        };
    }
    if (a == .float_literal) {
        return switch (e) {
            .float, .float_literal => true,
            else => false,
        };
    }
    return false;
}

fn typeIsVoid(ctx: *const SemContext, ty: TypeId) bool {
    return ty == ctx.types.void_id;
}

/// If `ty` resolves to a nominal enum/errors with declared variants,
/// returns the variant count. Used by match exhaustiveness checking.
fn enumVariantCount(ctx: *const SemContext, ty: TypeId) ?usize {
    // M20c per GPT-5.5: handle both `nominal` (plain enum) and
    // `parameterized_nominal` (generic enum like `Option(Int)`) via
    // the shared `nominalSymOfReceiver` helper.
    const sym_id = nominalSymOfReceiver(ctx, ty) orelse return null;
    const sym = ctx.symbols.items[sym_id];
    if (sym.kind != .nominal_type and sym.kind != .generic_type) return null;
    const fields = sym.fields orelse return null;
    // M20a: methods (is_method=true) live in the same `fields` slice
    // as variants but aren't variants. M20c: only count actual variants
    // (is_variant=true).
    var count: usize = 0;
    for (fields) |f| {
        if (f.is_variant) count += 1;
    }
    return count;
}

fn isNumeric(ctx: *const SemContext, ty: TypeId) bool {
    const t = ctx.types.get(ty);
    return switch (t) {
        .int, .float, .int_literal, .float_literal => true,
        else => false,
    };
}

fn isIntLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    const c = text[0];
    if (c == '0' and text.len > 1 and (text[1] == 'x' or text[1] == 'b' or text[1] == 'o')) return true;
    if (c < '0' or c > '9') return false;
    for (text) |ch| {
        if (ch == '.') return false;
    }
    return true;
}

fn isFloatLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    const c = text[0];
    if (c < '0' or c > '9') return false;
    for (text) |ch| {
        if (ch == '.') return true;
    }
    return false;
}

fn firstSrcPos(sexp: Sexp) u32 {
    return switch (sexp) {
        .src => |s| s.pos,
        .list => |items| blk: {
            for (items) |c| {
                const p = firstSrcPos(c);
                if (p > 0) break :blk p;
            }
            break :blk 0;
        },
        else => 0,
    };
}

/// Render a `TypeId` as a short human-readable string in the sema arena.
/// Returned slice lives until `SemContext.deinit`.
fn formatType(ctx: *SemContext, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    const a = ctx.arena.allocator();
    const t = ctx.types.get(ty_id);
    return switch (t) {
        .invalid => "invalid",
        .unknown => "unknown",
        .void => "Void",
        .bool => "Bool",
        .string => "String",
        .int => |info| if (info.bits == 0) "Int" else try std.fmt.allocPrint(a, "{c}{d}", .{
            @as(u8, if (info.signed) 'I' else 'U'),
            info.bits,
        }),
        .float => |info| if (info.bits == 0) "Float" else try std.fmt.allocPrint(a, "F{d}", .{info.bits}),
        .int_literal => "<int literal>",
        .float_literal => "<float literal>",
        // M20d.1: parenthesize prefix-type operands of optional /
        // fallible so `optional(shared(T))` renders as `(*T)?` and
        // not `*T?` — the latter spelling is `shared(optional(T))`
        // per Rig's grammar precedence (suffix binds tighter than
        // prefix). Without the parens, formatType collapses both
        // shapes to the same string and type-mismatch diagnostics
        // become "expected `*T?`, got `*T?`" — useless.
        .optional => |inner| blk: {
            const inner_ty = ctx.types.get(inner);
            const needs_parens = inner_ty == .shared or inner_ty == .weak or
                inner_ty == .borrow_read or inner_ty == .borrow_write;
            const inner_str = try formatType(ctx, inner);
            break :blk if (needs_parens)
                try std.fmt.allocPrint(a, "({s})?", .{inner_str})
            else
                try std.fmt.allocPrint(a, "{s}?", .{inner_str});
        },
        .fallible => |inner| blk: {
            const inner_ty = ctx.types.get(inner);
            const needs_parens = inner_ty == .shared or inner_ty == .weak or
                inner_ty == .borrow_read or inner_ty == .borrow_write;
            const inner_str = try formatType(ctx, inner);
            break :blk if (needs_parens)
                try std.fmt.allocPrint(a, "({s})!", .{inner_str})
            else
                try std.fmt.allocPrint(a, "{s}!", .{inner_str});
        },
        .borrow_read => |inner| try std.fmt.allocPrint(a, "?{s}", .{try formatType(ctx, inner)}),
        .borrow_write => |inner| try std.fmt.allocPrint(a, "!{s}", .{try formatType(ctx, inner)}),
        .shared => |inner| try std.fmt.allocPrint(a, "*{s}", .{try formatType(ctx, inner)}),
        .weak => |inner| try std.fmt.allocPrint(a, "~{s}", .{try formatType(ctx, inner)}),
        .slice => |s| try std.fmt.allocPrint(a, "[]{s}", .{try formatType(ctx, s.elem)}),
        .array => |arr| try std.fmt.allocPrint(a, "[{d}]{s}", .{ arr.len, try formatType(ctx, arr.elem) }),
        .function => "fn(...)",
        .nominal => |sym| ctx.symbols.items[sym].name,
        .parameterized_nominal => |pn| blk: {
            // Render `Box(Int, String)` style.
            const base_name = ctx.symbols.items[pn.sym].name;
            if (pn.args.len == 0) break :blk try std.fmt.allocPrint(a, "{s}()", .{base_name});
            // Build args list via repeated allocPrint — fine for the
            // diagnostic path; not on the hot loop.
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(a);
            try buf.appendSlice(a, base_name);
            try buf.append(a, '(');
            for (pn.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, try formatType(ctx, arg));
            }
            try buf.append(a, ')');
            break :blk try a.dupe(u8, buf.items);
        },
        .type_var => |sym| ctx.symbols.items[sym].name,
    };
}

// =============================================================================
// Helpers
// =============================================================================

fn identAt(source: []const u8, sexp: Sexp) ?[]const u8 {
    return switch (sexp) {
        .src => |s| source[s.pos..][0..s.len],
        else => null,
    };
}

/// Is the given type Sexp a `(borrow_read T)` or `(borrow_write T)`?
fn isBorrowedTypeNode(t: Sexp) bool {
    if (t != .list or t.list.len == 0 or t.list[0] != .tag) return false;
    return switch (t.list[0].tag) {
        .borrow_read, .borrow_write => true,
        else => false,
    };
}

const LineCol = struct { line: u32, col: u32 };

fn lineCol(source: []const u8, pos: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    const end = @min(pos, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

// =============================================================================
// Tests
// =============================================================================

test "TypeStore: primitives pre-interned" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.invalid_id == 0);
    try std.testing.expect(store.unknown_id != type_invalid);
    try std.testing.expect(store.void_id != type_invalid);
    try std.testing.expect(store.bool_id != type_invalid);
    try std.testing.expect(store.string_id != type_invalid);
    try std.testing.expect(store.int_id != type_invalid);
    try std.testing.expect(store.float_id != type_invalid);

    // All primitive ids are distinct.
    const ids = [_]TypeId{
        store.unknown_id, store.void_id, store.bool_id,
        store.string_id, store.int_id, store.float_id,
    };
    for (ids, 0..) |a, i| {
        for (ids[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
}

test "TypeStore: intern composites dedupes" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit(std.testing.allocator);

    const opt_int_a = try store.intern(std.testing.allocator, .{ .optional = store.int_id });
    const opt_int_b = try store.intern(std.testing.allocator, .{ .optional = store.int_id });
    try std.testing.expectEqual(opt_int_a, opt_int_b);

    const fall_int = try store.intern(std.testing.allocator, .{ .fallible = store.int_id });
    try std.testing.expect(fall_int != opt_int_a);

    // Distinct nesting levels are distinct types.
    const opt_opt_int = try store.intern(std.testing.allocator, .{ .optional = opt_int_a });
    try std.testing.expect(opt_opt_int != opt_int_a);
}

test "TypeStore: function types compare by structure" {
    const allocator = std.testing.allocator;
    var store = try TypeStore.init(allocator);
    defer store.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params_a = try a.dupe(TypeId, &.{ store.int_id, store.int_id });
    const params_b = try a.dupe(TypeId, &.{ store.int_id, store.int_id });
    const params_c = try a.dupe(TypeId, &.{ store.int_id, store.bool_id });

    const fn_a = try store.intern(allocator, .{ .function = .{
        .params = params_a, .returns = store.int_id, .is_sub = false,
    } });
    const fn_b = try store.intern(allocator, .{ .function = .{
        .params = params_b, .returns = store.int_id, .is_sub = false,
    } });
    const fn_c = try store.intern(allocator, .{ .function = .{
        .params = params_c, .returns = store.int_id, .is_sub = false,
    } });

    try std.testing.expectEqual(fn_a, fn_b); // same structure → same id
    try std.testing.expect(fn_a != fn_c);
}

test "SemContext: init/deinit roundtrip" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();

    try std.testing.expect(!ctx.hasErrors());
    // Sentinels at slot 0.
    try std.testing.expectEqual(@as(usize, 1), ctx.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.scopes.items.len);
}

test "check: returns empty context for any IR" {
    var ctx = try check(std.testing.allocator, "", .{ .nil = {} });
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// -----------------------------------------------------------------------------
// Symbol resolution end-to-end tests (parse real Rig source through the
// whole pipeline up to sema and verify the symbol table).
// -----------------------------------------------------------------------------

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !SemContext {
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();
    const ir = try p.parseProgram();
    return check(allocator, source, ir);
}

test "symbols: collects function + sub at module scope" {
    const source =
        \\fun add(a: Int, b: Int) -> Int
        \\  a + b
        \\
        \\sub main()
        \\  print 42
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    try std.testing.expect(!ctx.hasErrors());
    // Module scope is scope 1; we should see `add` and `main` in it.
    try std.testing.expect(ctx.lookup(1, "add") != null);
    try std.testing.expect(ctx.lookup(1, "main") != null);

    const add_id = ctx.lookup(1, "add").?;
    try std.testing.expectEqual(SymbolKind.function, ctx.symbols.items[add_id].kind);
}

test "symbols: parameters bound in fn scope, not module scope" {
    const source =
        \\fun greet(name: String) -> String
        \\  name
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    try std.testing.expect(ctx.lookup(1, "name") == null);

    // Walk to the fn scope (it's the next scope after module).
    // Module is scope 1; greet's body scope is scope 2.
    const name_in_fn = ctx.lookup(2, "name");
    try std.testing.expect(name_in_fn != null);
    try std.testing.expectEqual(SymbolKind.param, ctx.symbols.items[name_in_fn.?].kind);
}

test "symbols: borrowed param flagged" {
    const source =
        \\fun read_name(user: ?User) -> ?String
        \\  ?user.name
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const user_id = ctx.lookup(2, "user").?;
    try std.testing.expect(ctx.symbols.items[user_id].flags.borrowed_param);
}

test "symbols: locals introduced by `set` (default/fixed/shadow only)" {
    const source =
        \\sub main()
        \\  x = 1
        \\  y =! 2
        \\  new x = 3
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    // Find main's body scope. main is in module scope (1); body is scope 2.
    // Locals are bound in scope 3 (the inner block scope).
    // Just verify the names appear somewhere reachable from leaf scopes.
    const last_scope: ScopeId = @intCast(ctx.scopes.items.len - 1);
    try std.testing.expect(ctx.lookup(last_scope, "x") != null);
    try std.testing.expect(ctx.lookup(last_scope, "y") != null);

    // The `y` symbol should be flagged fixed (`=!`).
    const y_id = ctx.lookup(last_scope, "y").?;
    try std.testing.expect(ctx.symbols.items[y_id].flags.fixed);
}

test "symbols: lookup walks scope chain" {
    const source =
        \\fun outer(x: Int) -> Int
        \\  x
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    // From any scope inside outer's body, looking up `outer` should find
    // the function in module scope.
    const inner_scope: ScopeId = @intCast(ctx.scopes.items.len - 1);
    try std.testing.expect(ctx.lookup(inner_scope, "outer") != null);
    try std.testing.expect(ctx.lookup(inner_scope, "x") != null);
}

test "symbols: shadow binding finds NEW binding via reverse lookup" {
    const source =
        \\sub main()
        \\  x = 1
        \\  new x = 2
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const last_scope: ScopeId = @intCast(ctx.scopes.items.len - 1);
    const x_id = ctx.lookup(last_scope, "x").?;
    // The shadowing `new x = 2` is the second `set` and should be the
    // one returned by lookup. We can't easily check the source pos here
    // without reaching deeper, but we can verify TWO `x` symbols exist.
    var x_count: u32 = 0;
    for (ctx.symbols.items) |s| {
        if (std.mem.eql(u8, s.name, "x")) x_count += 1;
    }
    try std.testing.expect(x_count == 2);
    _ = x_id;
}

test "symbols: pub flag set on wrapped declaration" {
    const source =
        \\pub fun greet() -> String
        \\  "hi"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const greet_id = ctx.lookup(1, "greet").?;
    try std.testing.expect(ctx.symbols.items[greet_id].flags.is_public);
}

// -----------------------------------------------------------------------------
// Type expression resolution tests
// -----------------------------------------------------------------------------

test "type-resolve: fun signature populated with primitive types" {
    const source =
        \\fun add(a: Int, b: Int) -> Int
        \\  a + b
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const add_id = ctx.lookup(1, "add").?;
    const add_ty = ctx.types.get(ctx.symbols.items[add_id].ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .function), @as(std.meta.Tag(Type), add_ty));
    try std.testing.expectEqual(ctx.types.int_id, add_ty.function.returns);
    try std.testing.expectEqual(@as(usize, 2), add_ty.function.params.len);
    try std.testing.expectEqual(ctx.types.int_id, add_ty.function.params[0]);
    try std.testing.expectEqual(ctx.types.int_id, add_ty.function.params[1]);
    try std.testing.expect(!add_ty.function.is_sub);

    // Param symbols also have their `ty` populated.
    const a_id = ctx.lookup(2, "a").?;
    try std.testing.expectEqual(ctx.types.int_id, ctx.symbols.items[a_id].ty);
}

test "type-resolve: sub return is Void" {
    const source =
        \\sub main()
        \\  print 1
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const main_id = ctx.lookup(1, "main").?;
    const main_ty = ctx.types.get(ctx.symbols.items[main_id].ty);
    try std.testing.expect(main_ty.function.is_sub);
    try std.testing.expectEqual(ctx.types.void_id, main_ty.function.returns);
}

test "type-resolve: T! / T? / ?T / !T wrappers" {
    const source =
        \\fun a() -> Int!
        \\  1
        \\
        \\fun b() -> Int?
        \\  1
        \\
        \\fun c(x: ?Int) -> Int
        \\  1
        \\
        \\fun d(x: !Int) -> Int
        \\  1
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const a_ret = ctx.symbols.items[ctx.lookup(1, "a").?].ty;
    const a_ty = ctx.types.get(a_ret);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .fallible), @as(std.meta.Tag(Type), ctx.types.get(a_ty.function.returns)));

    const b_ret = ctx.symbols.items[ctx.lookup(1, "b").?].ty;
    const b_ty = ctx.types.get(b_ret);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .optional), @as(std.meta.Tag(Type), ctx.types.get(b_ty.function.returns)));

    const c_id = ctx.lookup(1, "c").?;
    const c_ty = ctx.types.get(ctx.symbols.items[c_id].ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .borrow_read), @as(std.meta.Tag(Type), ctx.types.get(c_ty.function.params[0])));

    const d_id = ctx.lookup(1, "d").?;
    const d_ty = ctx.types.get(ctx.symbols.items[d_id].ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .borrow_write), @as(std.meta.Tag(Type), ctx.types.get(d_ty.function.params[0])));
}

test "type-resolve: unknown type silently returns invalid_id (M5 v1 deferred)" {
    // M5 v1 doesn't fire the unknown-type diagnostic at declaration
    // resolution time — the user has no module/forward-decl mechanism
    // yet, so undeclared nominal names are common (every example using
    // `User`, `Profile`, etc.). The diagnostic will return when type-
    // driven expression checking lands and can point at a USE site.
    const source =
        \\fun bad(x: NotAType) -> Int
        \\  1
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    try std.testing.expect(!ctx.hasErrors());
    const bad_id = ctx.lookup(1, "bad").?;
    const bad_ty = ctx.types.get(ctx.symbols.items[bad_id].ty);
    // The param's type is invalid (unresolved nominal), but the function
    // type itself was still constructed.
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .function), @as(std.meta.Tag(Type), bad_ty));
    try std.testing.expectEqual(ctx.types.invalid_id, bad_ty.function.params[0]);
}

test "type-resolve: type alias resolves to its target" {
    const source =
        \\type UserId = Int
        \\
        \\fun lookup(id: UserId) -> UserId
        \\  id
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    try std.testing.expect(!ctx.hasErrors());

    // Type alias's `ty` should be the int_id.
    const alias_id = ctx.lookup(1, "UserId").?;
    try std.testing.expectEqual(ctx.types.int_id, ctx.symbols.items[alias_id].ty);

    // The fn's param type should be `nominal(UserId)` since user types
    // resolve to nominal references rather than expanding the alias.
    const fn_id = ctx.lookup(1, "lookup").?;
    const fn_ty = ctx.types.get(ctx.symbols.items[fn_id].ty);
    const param_ty = ctx.types.get(fn_ty.function.params[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .nominal), @as(std.meta.Tag(Type), param_ty));
    try std.testing.expectEqual(alias_id, param_ty.nominal);
}

// -----------------------------------------------------------------------------
// Expression typing tests
// -----------------------------------------------------------------------------

test "expr-typing: literal coerces to declared sized integer" {
    const source =
        \\sub main()
        \\  x: U8 = 0
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "expr-typing: declared return type drives last-statement check" {
    const source =
        \\fun bad() -> Int
        \\  "no"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "expected `Int`") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "expr-typing: if-arm value mismatch fires" {
    const source =
        \\sub main()
        \\  x = if true
        \\    1
        \\  else
        \\    "no"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
}

test "expr-typing: if condition must be Bool" {
    const source =
        \\sub main()
        \\  if 42
        \\    print "yes"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "expected `Bool`") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "expr-typing: call arg arity mismatch" {
    const source =
        \\fun add(a: Int, b: Int) -> Int
        \\  a + b
        \\
        \\sub main()
        \\  x = add(1)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "expects 2 arguments") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "expr-typing: matching if-arm types pass clean" {
    const source =
        \\sub main()
        \\  x = if true
        \\    1
        \\  else
        \\    2
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// -----------------------------------------------------------------------------
// M6: struct field typing tests
// -----------------------------------------------------------------------------

test "M6: struct fields populated on the nominal symbol" {
    const source =
        \\struct User
        \\  name: String
        \\  age: Int
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const user_id = ctx.lookup(1, "User").?;
    const fields = ctx.symbols.items[user_id].fields.?;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("name", fields[0].name);
    try std.testing.expectEqual(ctx.types.string_id, fields[0].ty);
    try std.testing.expectEqualStrings("age", fields[1].name);
    try std.testing.expectEqual(ctx.types.int_id, fields[1].ty);
}

test "M6: member access fires `no field` for unknown name" {
    const source =
        \\struct User
        \\  name: String
        \\
        \\sub main()
        \\  u = User(name: "Steve")
        \\  print(u.zzz)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "no field `zzz`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M6: constructor fires `missing field` per absent kwarg" {
    const source =
        \\struct Point
        \\  x: Int
        \\  y: Int
        \\
        \\sub main()
        \\  p = Point(x: 1)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "missing field `y`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M6: constructor wrong-type kwarg fires type mismatch" {
    const source =
        \\struct User
        \\  name: String
        \\
        \\sub main()
        \\  u = User(name: 42)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
}

test "M6: member access on a known struct returns the field's type" {
    const source =
        \\struct User
        \\  name: String
        \\
        \\fun greet(u: User) -> String
        \\  u.name
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    // The function returns String. If member typing works, the implicit
    // return `u.name` is checked against `String` and passes — no
    // diagnostic. If it returned `unknown` we'd silently pass too
    // (compatible-with-anything sentinel), so we also positively check
    // by inverting the type and ensuring the diagnostic DOES fire.
    try std.testing.expect(!ctx.hasErrors());

    const source_bad =
        \\struct User
        \\  name: String
        \\
        \\fun greet(u: User) -> Int
        \\  u.name
        \\
    ;
    var ctx2 = try checkSource(std.testing.allocator, source_bad);
    defer ctx2.deinit();
    try std.testing.expect(ctx2.hasErrors());
}

// -----------------------------------------------------------------------------
// M7: enum / error-set typing tests
// -----------------------------------------------------------------------------

test "M7: enum variants populated as fields" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\  blue
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    const id = ctx.lookup(1, "Color").?;
    const fields = ctx.symbols.items[id].fields.?;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("red", fields[0].name);
    try std.testing.expectEqualStrings("green", fields[1].name);
    try std.testing.expectEqualStrings("blue", fields[2].name);
}

test "M7: enum literal against expected enum is typed" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .red
        \\  print(c)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "M7: enum literal with unknown variant fires" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .purple
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "no variant `purple`") != null) found = true;
    }
    try std.testing.expect(found);
}

// -----------------------------------------------------------------------------
// M8: match typing tests
// -----------------------------------------------------------------------------

test "M8: match arm `.variant` patterns are checked against scrutinee enum" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .red
        \\  match c
        \\    .red => print(c)
        \\    .purple => print(c)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "no variant `purple`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M8: match clean when all arm variants are valid" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .red
        \\  match c
        \\    .red => print(c)
        \\    .green => print(c)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "M9b: payload variant construction kwarg type-checks against payload" {
    const source =
        \\enum Shape
        \\  circle(radius: Int)
        \\
        \\sub main()
        \\  s: Shape = .circle(radius: "nope")
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "expected `Int`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M9b: payload variant construction with missing field fires" {
    const source =
        \\enum Shape
        \\  triangle(a: Int, b: Int)
        \\
        \\sub main()
        \\  s: Shape = .triangle(a: 1)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "missing field `b`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M9b: clean payload variant construction passes" {
    const source =
        \\enum Shape
        \\  circle(radius: Int)
        \\  origin
        \\
        \\sub main()
        \\  s1: Shape = .circle(radius: 5)
        \\  s2: Shape = .origin
        \\  print(s1)
        \\  print(s2)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// -----------------------------------------------------------------------------
// M10: pattern destructuring + bindings + value-position match + exhaustiveness
// -----------------------------------------------------------------------------

test "M10: variant pattern binds payload field with the right type" {
    // The arm body uses `r` against an Int-expecting print — if the
    // binding's type is correctly set to Int (the payload field type),
    // sema accepts; if it stays unknown, sema also accepts (compatible-
    // with-anything sentinel). To prove the binding really has Int,
    // pass it where a String is expected and watch the diagnostic fire.
    const source =
        \\enum Shape
        \\  circle(radius: Int)
        \\
        \\fun stringify(s: String) -> String
        \\  s
        \\
        \\sub main()
        \\  s: Shape = .circle(radius: 5)
        \\  match s
        \\    .circle(r) => stringify(r)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "expected `String`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M10: duplicate match arm fires" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .red
        \\  match c
        \\    .red => print(1)
        \\    .red => print(2)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "duplicate arm for variant `red`") != null) found = true;
    }
    try std.testing.expect(found);
}

test "M10: value-position match unifies arm types" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = .red
        \\  x = match c
        \\    .red => 1
        \\    .green => "no"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
}

test "M10: value-position match requires exhaustive coverage" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\  blue
        \\
        \\sub main()
        \\  c: Color = .red
        \\  x = match c
        \\    .red => 1
        \\    .green => 2
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
    var found = false;
    for (ctx.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "not exhaustive") != null) found = true;
    }
    try std.testing.expect(found);
}

// -----------------------------------------------------------------------------
// M11: qualified enum access tests
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// M14: generic type tests
// -----------------------------------------------------------------------------

test "M14: generic type declaration + instantiation + construction" {
    const source =
        \\type Box(T)
        \\  value: T
        \\
        \\sub main()
        \\  b: Box(Int) = Box(value: 5)
        \\  print(b.value)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "M14: multi-param generic" {
    const source =
        \\type Pair(T, U)
        \\  first: T
        \\  second: U
        \\
        \\sub main()
        \\  p: Pair(Int, String) = Pair(first: 1, second: "hi")
        \\  print(p.first)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// -----------------------------------------------------------------------------
// M13: range pattern tests
// -----------------------------------------------------------------------------

test "M13: range pattern bounds are checked against scrutinee" {
    const source =
        \\sub main()
        \\  x = 5
        \\  match x
        \\    1..3 => print(0)
        \\    4..6 => print(1)
        \\    other => print(2)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

// -----------------------------------------------------------------------------
// M12: struct method tests
// -----------------------------------------------------------------------------

test "M12: struct method registered as method-flagged Field" {
    const source =
        \\struct User
        \\  name: String
        \\
        \\  fun greet() -> String
        \\    "hi"
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    const id = ctx.lookup(1, "User").?;
    const fields = ctx.symbols.items[id].fields.?;
    // First member: name (data field, not method).
    try std.testing.expectEqualStrings("name", fields[0].name);
    try std.testing.expect(!fields[0].is_method);
    // Second member: greet (method).
    try std.testing.expectEqualStrings("greet", fields[1].name);
    try std.testing.expect(fields[1].is_method);
    const fn_ty = ctx.types.get(fields[1].ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Type), .function), @as(std.meta.Tag(Type), fn_ty));
    try std.testing.expectEqual(ctx.types.string_id, fn_ty.function.returns);
}

test "M12: `Type.method` resolves to the method's function type" {
    const source =
        \\struct User
        \\  fun greet() -> String
        \\    "hi"
        \\
        \\sub main()
        \\  print(User.greet())
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "M11: qualified `Color.red` types as the enum" {
    const source =
        \\enum Color
        \\  red
        \\  green
        \\
        \\sub main()
        \\  c: Color = Color.red
        \\  print(c)
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
}

test "M11: qualified access with unknown variant fires" {
    const source =
        \\enum Color
        \\  red
        \\
        \\sub main()
        \\  c: Color = Color.purple
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(ctx.hasErrors());
}

test "M9a: payload-bearing enum variant carries field metadata" {
    const source =
        \\enum Shape
        \\  circle(radius: Int)
        \\  origin
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    const id = ctx.lookup(1, "Shape").?;
    const fields = ctx.symbols.items[id].fields.?;
    try std.testing.expectEqual(@as(usize, 2), fields.len);

    // First variant: circle with one payload field `radius: Int`.
    try std.testing.expectEqualStrings("circle", fields[0].name);
    const payload = fields[0].payload.?;
    try std.testing.expectEqual(@as(usize, 1), payload.len);
    try std.testing.expectEqualStrings("radius", payload[0].name);
    try std.testing.expectEqual(ctx.types.int_id, payload[0].ty);

    // Second variant: origin (bare, no payload).
    try std.testing.expectEqualStrings("origin", fields[1].name);
    try std.testing.expect(fields[1].payload == null);
}

test "M7: error set declaration populates fields" {
    const source =
        \\error NetworkError
        \\  timeout
        \\  refused
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    const id = ctx.lookup(1, "NetworkError").?;
    const fields = ctx.symbols.items[id].fields.?;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("timeout", fields[0].name);
}

test "expr-typing: untyped binding gets canonical type from RHS" {
    // After typing, `x` should have type `Int` (the canonical form),
    // NOT `int_literal` (the raw RHS pseudo-type).
    const source =
        \\sub main()
        \\  x = 1
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();
    try std.testing.expect(!ctx.hasErrors());
    const last_scope: ScopeId = @intCast(ctx.scopes.items.len - 1);
    const x_id = ctx.lookup(last_scope, "x").?;
    try std.testing.expectEqual(ctx.types.int_id, ctx.symbols.items[x_id].ty);
}

test "type-resolve: sized integer types intern distinctly" {
    const source =
        \\fun pair(a: I32, b: U64) -> I32
        \\  a
        \\
    ;
    var ctx = try checkSource(std.testing.allocator, source);
    defer ctx.deinit();

    const pair_id = ctx.lookup(1, "pair").?;
    const pair_ty = ctx.types.get(ctx.symbols.items[pair_id].ty);
    const i32_ty = ctx.types.get(pair_ty.function.params[0]);
    const u64_ty = ctx.types.get(pair_ty.function.params[1]);

    try std.testing.expectEqual(@as(u8, 32), i32_ty.int.bits);
    try std.testing.expect(i32_ty.int.signed);
    try std.testing.expectEqual(@as(u8, 64), u64_ty.int.bits);
    try std.testing.expect(!u64_ty.int.signed);
}
