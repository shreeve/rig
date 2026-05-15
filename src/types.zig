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

    slice: SliceType,
    array: ArrayType,

    function: FunctionType,
    /// Reference to a named declaration (struct, enum, type alias,
    /// generic-type instantiation later). The actual definition lives
    /// at `SemContext.symbols[symbol]`.
    nominal: SymbolId,
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

pub const Symbol = struct {
    name: []const u8,            // borrowed slice into source
    kind: SymbolKind,
    ty: TypeId,                  // resolved declared type, or `unknown_id`
    decl_pos: u32,               // source pos of declaration name
    scope: ScopeId,              // owning scope
    flags: SymbolFlags = .{},
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

    pub fn writeDiagnostics(self: *const SemContext, file_path: []const u8, w: anytype) !void {
        for (self.diagnostics.items) |d| {
            const lc = lineCol(self.source, d.pos);
            const tag = switch (d.severity) {
                .@"error" => "error",
                .note => "  note",
            };
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, lc.line, lc.col, tag, d.message });
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
            .@"generic_type" => try self.walkGenericType(items),
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
                    else => return,
                }
            },
            else => return,
        }

        const name = identAt(self.ctx.source, name_node) orelse return;
        const decl_pos = if (name_node == .src) name_node.src.pos else 0;
        const borrowed = isBorrowedTypeNode(type_node);
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
        // (generic_type name params? members)
        if (items.len < 2) return;
        const name = identAt(self.ctx.source, items[1]) orelse return;
        const decl_pos = if (items[1] == .src) items[1].src.pos else 0;
        _ = try self.addSymbol(.{
            .name = name,
            .kind = .generic_type,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = decl_pos,
            .scope = self.current_scope,
        });
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
            .default, .fixed, .shadow => {
                // Introduce a local. `default` may also be a rebind in
                // outer scope (we don't dedupe here — duplicates within
                // a scope are caught by the ownership checker; sema
                // mirrors what the checker sees). Whether to add or
                // reuse will be revisited when ownership consumes sema.
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
        try self.walk(items[items.len - 1]);
    }

    fn addSymbol(self: *SymbolResolver, sym: Symbol) std.mem.Allocator.Error!SymbolId {
        const id: SymbolId = @intCast(self.ctx.symbols.items.len);
        try self.ctx.symbols.append(self.ctx.allocator, sym);
        try self.ctx.scopes.items[sym.scope].symbols.append(self.ctx.allocator, id);
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
            else => return scope_cursor,
        }
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
                if (self.ctx.lookup(scope, name)) |sym_id| {
                    const sym = self.ctx.symbols.items[sym_id];
                    if (sym.kind == .nominal_type or sym.kind == .type_alias or
                        sym.kind == .generic_type)
                    {
                        return self.ctx.types.intern(self.ctx.allocator, .{ .nominal = sym_id });
                    }
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
            // type aliases / extern / use have no body to type-check.
            else => {},
        }
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

    fn checkSet(self: *ExprChecker, items: []const Sexp) std.mem.Allocator.Error!void {
        // (set <kind> name type-or-_ expr).
        if (items.len < 5) return;
        const target = items[2];
        const type_node = items[3];
        const expr = items[4];

        // Find the symbol, if any. Compound assigns / move-assign reuse
        // an existing slot — they don't introduce a new symbol but we
        // still need to type-check against the existing one.
        const sym_id = blk: {
            const nm = identAt(self.ctx.source, target) orelse break :blk symbol_invalid;
            break :blk self.ctx.lookup(self.current_scope, nm) orelse symbol_invalid;
        };

        // Resolve the explicit type annotation, if any.
        var declared_ty: TypeId = self.ctx.types.unknown_id;
        if (type_node != .nil) {
            var tr: TypeResolver = .{ .ctx = self.ctx };
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
            .@"clone", .@"share", .@"weak", .@"pin", .@"raw" => {
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

        // If the callee is a known function symbol, check arg arity +
        // types and return its declared return type.
        if (callee == .src) {
            const name = self.ctx.source[callee.src.pos..][0..callee.src.len];
            if (self.ctx.lookup(self.current_scope, name)) |sym_id| {
                const sym = self.ctx.symbols.items[sym_id];
                const ty = self.ctx.types.get(sym.ty);
                switch (ty) {
                    .function => |fn_ty| {
                        try self.checkCallArgs(items[2..], fn_ty, name, callee.src.pos);
                        return fn_ty.returns;
                    },
                    .nominal => {
                        // Constructor call (e.g., `User(name: "Steve")`).
                        // The result is the nominal type itself. Args
                        // are type-unchecked in M5 v1 (need struct
                        // field metadata which we don't track yet).
                        for (items[2..]) |arg| _ = try self.synthExpr(arg);
                        return sym.ty;
                    },
                    else => {},
                }
            }
        }

        // Unknown callee: synth args anyway so nested type errors fire.
        for (items[1..]) |arg| _ = try self.synthExpr(arg);
        return self.ctx.types.unknown_id;
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
        // (member obj name) — V1 doesn't track struct fields, so any
        // member access is unknown. Walk obj for nested type errors.
        if (items.len >= 2) _ = try self.synthExpr(items[1]);
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
        const actual = try self.synthExpr(expr);
        if (compatible(self.ctx, actual, expected)) return;
        const pos = firstSrcPos(expr);
        try self.err(pos, "type mismatch: expected `{s}`, got `{s}`", .{
            try formatType(self.ctx, expected),
            try formatType(self.ctx, actual),
        });
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
        .optional => |inner| try std.fmt.allocPrint(a, "{s}?", .{try formatType(ctx, inner)}),
        .fallible => |inner| try std.fmt.allocPrint(a, "{s}!", .{try formatType(ctx, inner)}),
        .borrow_read => |inner| try std.fmt.allocPrint(a, "?{s}", .{try formatType(ctx, inner)}),
        .borrow_write => |inner| try std.fmt.allocPrint(a, "!{s}", .{try formatType(ctx, inner)}),
        .slice => |s| try std.fmt.allocPrint(a, "[]{s}", .{try formatType(ctx, s.elem)}),
        .array => |arr| try std.fmt.allocPrint(a, "[{d}]{s}", .{ arr.len, try formatType(ctx, arr.elem) }),
        .function => "fn(...)",
        .nominal => |sym| ctx.symbols.items[sym].name,
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
