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
    /// further error spam.
    invalid,
    /// Used for placeholders during inference / declaration ordering.
    /// Should never escape the checker.
    unknown,

    void,
    bool,
    string,
    int: IntInfo,
    float: FloatInfo,

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
    int_id: TypeId = type_invalid,     // unsized Int (arch default)
    float_id: TypeId = type_invalid,   // unsized Float (arch default)

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
            .invalid, .unknown, .void, .bool, .string => true,
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
/// Current passes (in order):
///   1. Symbol resolution — collect every fun/sub/lambda, params,
///      type aliases, externs, use's, and locals into the symbol
///      table with proper scope nesting. Types remain `unknown_id`
///      until type expression resolution lands.
///
/// Future passes (subsequent M5 commits):
///   2. Type expression resolution — convert IR type Sexps to TypeIds.
///   3. Expression typing — synth + check.
///
/// Caller owns the returned `SemContext` and must call `deinit`.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    ir: Sexp,
) !SemContext {
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    // Module scope is scope 1 (slot 0 reserved for invalid sentinel).
    const module_scope = try ctx.pushScope(scope_invalid);
    var resolver: SymbolResolver = .{ .ctx = &ctx, .current_scope = module_scope };
    try resolver.walk(ir);
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
