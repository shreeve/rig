//! Semantic analysis: names, types, and expression checking.
//!
//! `check` runs these steps over the normalized IR and returns
//! a `SemContext`, which every later pass (ownership, emit) reads:
//!
//!   1. builtins     `resolve.zig`    Cell, Vec, Box, Signal, Endian
//!   2. symbols      `resolve.zig`    every declaration gets a Symbol in a
//!                                    Scope; scopes are keyed by the IR node
//!                                    that opens them
//!   3. declarations `resolve.zig`    type expressions become TypeIds;
//!                                    signatures, fields, variants, aliases
//!   4. contents     `sema.zig`       what each declared type's values hold
//!                                    (drop glue, a Cell, plain data), and
//!                                    types that contain themselves
//!   5. validation   `sema.zig`,      every struct and enum fits
//!                   `resolve.zig`    `max_value_bytes`; the declaration
//!                                    checks that need 4
//!   6. expressions  `typecheck.zig`  bodies are type-checked; every
//!                                    expression's type is recorded;
//!                                    fallibility and `raw` are checked;
//!                                    each frame fits `max_frame_bytes`;
//!                   `sema.zig`       then every local must be read
//!   7. generics     `sema.zig`,      the instances generic bodies reach,
//!                   `typecheck.zig`  and each instance's requirements
//!   8. storage      `storage.zig`    the hidden storage emit makes
//!
//! ## The facts table
//!
//! Sema records what it learned about each IR node so later passes can
//! ask instead of re-deriving it by name (`symbolOf`, `typeOf`, and the
//! other queries on `SemContext`); `docs/INTERNALS.md` (The facts table)
//! says what each answers. A call's callee gets a type too:
//! a function name its signature, and a method callee `(member obj m)`
//! the resolved method signature with the receiver's generic arguments
//! applied. The name leaf of every `fun` / `sub` declaration, method or
//! not, carries its function type. Binding facts live on the Symbol
//! (`SymbolFlags`, `kind`, and for a capture the `origin` binding it
//! captures).
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
const storage = @import("storage.zig");

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
    /// 0 for `Int` (64-bit signed); otherwise 8/16/32/64/128.
    bits: u8 = 0,
    signed: bool = true,

    /// The width in bits.
    pub fn width(self: IntInfo) u8 {
        return if (self.bits == 0) 64 else self.bits;
    }
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
    /// The symbol of each compile-time parameter, in the same order:
    /// what a `type_var` or `ct_param` in the signature names. In a
    /// function type imported from another module, a type or integer
    /// parameter's proxy, and `symbol_invalid` for any other.
    ct_syms: []const SymbolId = &.{},
};

pub const SliceType = struct { elem: TypeId };
/// `[len]elem`: `len` is a `ct_value`, or a `ct_param` inside a generic
/// declaration.
pub const ArrayType = struct { elem: TypeId, len: TypeId };

/// A value known at compile time, as a compile-time argument or an
/// array length.
/// The integer type constants are computed in: wide enough for every
/// value of `I128` and `U128`, and for the checked results of operations
/// on them.
pub const Wide = i256;

pub const CtValue = union(enum) { int: Wide };

/// The largest array length: lengths run from 0 to 2^32 - 1.
pub const max_array_len: Wide = std.math.maxInt(u32);

/// The most bytes a value takes: 8 MiB. A value may live in a stack
/// frame, and the main thread's stack holds 16 MiB, so any one value fits
/// there with room to spare; a frame that overflows it by up to 64 MiB
/// stops the program (`rig.guardStack`). The cap also keeps compiles
/// fast, since Zig builds a constant array element by element. Larger
/// data belongs in a `Vec`.
pub const max_value_bytes: u64 = 8 << 20;

/// The most bytes of values one function keeps on its stack: 16 MiB, the
/// size of the main thread's stack, so a function that keeps more could
/// never run. Zig's own temporaries at most about double it, which keeps
/// every frame well inside the 64 MiB below the stack that stops an
/// overflow (`rig.guardStack`).
pub const max_frame_bytes: u64 = 16 << 20;

/// The values one function or closure keeps on its stack: `label` names
/// it in messages, declared at `pos` in module `module_id` (0 for the
/// module that keeps the frame).
pub const Frame = struct { label: []const u8, pos: u32, tys: []const TypeId, module_id: u32 = 0 };

pub const Type = union(enum) {
    /// A type error was reported here.
    invalid,
    /// Not known; only ever produced after a diagnostic.
    unknown,

    void,
    bool,
    string,
    /// `Text`: owned, growable UTF-8 bytes; `String` is its view.
    text,
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
    read_view: TypeId, // ?T
    write_view: TypeId, // !T
    shared: TypeId, // *T
    weak: TypeId, // ~T

    slice: SliceType,
    array: ArrayType,
    /// `a..b`: a half-open range of the element integer type. Only valid
    /// as a `for` source.
    range: TypeId,

    function: FunctionType,
    /// What a callable view `?fun(...) -> R` views, written as
    /// such: a closure, a function, or an owned closure of function type
    /// `callable`, called through a `rig.FnRef`. (A `?T` whose `T` is a
    /// function type is a read view of a function value.)
    callable: TypeId,
    /// A struct, enum, error set, or opaque declared in this module.
    nominal: SymbolId,
    /// A nominal declared in another module. Identity is the origin
    /// module plus the symbol there, never the shape.
    imported_nominal: ImportedNominal,
    /// A generic type applied to arguments: `Wrap[Int]`.
    parameterized_nominal: ParamNominal,
    /// A generic parameter (`T` inside `struct Wrap[T]`).
    type_var: SymbolId,
    /// A compile-time integer where a type argument or an array length
    /// goes: `4` in `Ring[Int, 4]` and `[4]Int`. Not a type of values.
    ct_value: CtValue,
    /// A compile-time value parameter used where a `ct_value` goes, the
    /// way a `type_var` stands for a type: `n` in `[n]T` inside `fun
    /// f[n: Int]` or `struct Ring[T, n: Int]`.
    ct_param: SymbolId,
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
    items: std.ArrayList(Type) = .empty,
    map: std.HashMapUnmanaged(TypeId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    invalid_id: TypeId = type_invalid,
    unknown_id: TypeId = type_invalid,
    void_id: TypeId = type_invalid,
    bool_id: TypeId = type_invalid,
    string_id: TypeId = type_invalid,
    text_id: TypeId = type_invalid,
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
        s.text_id = try s.intern(allocator, .text);
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

    /// The type `id` names. An id from another module's store read in
    /// this one is a compiler bug, which a safe build stops at.
    pub fn get(self: *const TypeStore, id: TypeId) Type {
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
            .invalid, .unknown, .void, .bool, .string, .text, .int_literal, .float_literal, .none_literal, .noreturn, .any_error => true,
            .function => |af| af.is_sub == b.function.is_sub and
                af.returns == b.function.returns and
                std.mem.eql(TypeId, af.ct_params, b.function.ct_params) and
                std.mem.eql(SymbolId, af.ct_syms, b.function.ct_syms) and
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
    /// `struct Wrap[T]` / `enum Option[T]` and the built-in generics.
    generic_type,
    /// `T` in `struct Wrap[T]`, detached: not in any scope, reached through
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
    /// `const` binding: cannot be reassigned.
    fixed: bool = false,
    is_public: bool = false,
    /// Value known at compile time: a compile-time parameter
    /// (`fun f[n: Int]`), or a `const` binding
    /// initialized with a compile-time-known expression.
    comptime_known: bool = false,
    /// Bound by a `for` loop or a match pattern: not assignable.
    pattern_bound: bool = false,
    /// Bound by `if e as x` / `while e as x`: when it holds its own
    /// value, a field of it can be taken out (`<x.next`).
    as_bound: bool = false,
    /// Assigned again after its declaration (`=`, `+=`, ...):
    /// lowers to a Zig `var`.
    reassigned: bool = false,
    /// Written through: lent to write (`!x`), or a field or element of
    /// it assigned. Also lowers to a Zig `var`.
    written: bool = false,
    /// An `error` declaration: its variants are error values.
    error_set: bool = false,
    /// A local bound to a closure literal: a stack closure.
    closure: bool = false,
    /// A type declared `unique` (`struct T unique`): its values are never
    /// copied (`Contents.unique`).
    unique: bool = false,
    /// A read match's binding of a payload, or the whole value, that is
    /// not plain data: usable within its arm only (docs/INTERNALS.md,
    /// "Header subjects").
    arm_view: bool = false,
    /// A `!T` or `![]T` local assigned a view somewhere
    /// (`SemContext.repoints`): it lowers to a Zig `var` pointer.
    repointed: bool = false,
    _: u4 = 0,
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
    /// The struct's user `drop(!self)` body. Not callable.
    is_drop_method: bool = false,
    /// A data field's default value (`name: T = literal`).
    default: ?Sexp = null,
    /// Parameter names of a method, for keyword arguments.
    param_names: ?[]const []const u8 = null,
    /// Default values of a method's parameters (null where none).
    param_defaults: ?[]const ?Sexp = null,
    /// A method: which arguments a call passes loans on from.
    origins: Origins = .{},
    /// A plain enum's variant: its integer value, declared or implicit.
    value: ?Wide = null,
    /// A field or method declared `pub`, which other modules may use.
    /// (Variants and their payload fields are always visible.)
    is_pub: bool = false,
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
    /// A function: which arguments a call passes loans on from.
    origins: Origins = .{},
    /// A capture: the enclosing binding it captures.
    origin: SymbolId = symbol_invalid,
    /// The previous symbol of the same name in the same scope, if any.
    prev_in_scope: SymbolId = symbol_invalid,
    /// A proxy (`proxyOf`): the other module's generic type or
    /// compile-time parameter it stands for. `.{}` for a symbol declared
    /// here.
    from: ForeignRef = .{},
};

/// A symbol of another module: the module's id and the symbol's id there.
pub const ForeignRef = struct { module_id: u32 = 0, sym: SymbolId = symbol_invalid };

/// Whether `sym` stands for another module's declaration (`proxyOf`).
pub fn isProxy(sym: Symbol) bool {
    return sym.from.module_id != 0;
}

pub const ScopeKind = enum { module, function, lambda, block };

pub const Scope = struct {
    parent: ?ScopeId,
    /// In declaration order. Add with `SemContext.addToScope`.
    symbols: std.ArrayList(SymbolId) = .empty,
    /// Name -> the latest symbol of that name; earlier ones are chained
    /// through `Symbol.prev_in_scope`.
    by_name: std.StringHashMapUnmanaged(SymbolId) = .empty,
    kind: ScopeKind = .block,
};

pub const Diagnostic = diag.Diagnostic;

/// The name offered so far that is closest to `name`, a name not found:
/// within one edit for a short name and two for a longer one (a swap
/// of neighbors is one edit), so a typo finds its name and little else.
/// A name of one or two letters is a whole word away from any other.
pub const Suggest = struct {
    name: []const u8,
    best: ?[]const u8 = null,
    dist: usize = std.math.maxInt(usize),

    /// `; did you mean `best`?`, or nothing.
    pub fn hint(s: Suggest, a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const best = s.best orelse return "";
        return a.print("; did you mean `{s}`?", .{best});
    }

    pub fn offer(s: *Suggest, candidate: []const u8) void {
        if (s.name.len <= 2 or candidate.len == 0 or std.mem.eql(u8, candidate, s.name) or std.mem.eql(u8, candidate, "_")) return;
        const limit: usize = if (s.name.len >= 6) 2 else 1;
        const d = editDistance(s.name, candidate, limit) orelse return;
        if (d < s.dist) {
            s.best = candidate;
            s.dist = d;
        }
    }
};

/// The edit distance from `a` to `b` counting a swap of neighbors as one
/// edit, or null when it is over `limit` (or a name is long).
fn editDistance(a: []const u8, b: []const u8, limit: usize) ?usize {
    const max = 32;
    if (a.len > max or b.len > max) return null;
    if ((if (a.len > b.len) a.len - b.len else b.len - a.len) > limit) return null;
    // Row `i` of the table is `rows[i % 3]`: this one and two back.
    var rows: [3][max + 1]usize = undefined;
    for (0..b.len + 1) |j| rows[0][j] = j;
    for (1..a.len + 1) |i| {
        const cur = &rows[i % 3];
        const prev = &rows[(i + 2) % 3];
        const back = &rows[(i + 1) % 3];
        cur[0] = i;
        for (1..b.len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            var d = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) d = @min(d, back[j - 2] + 1);
            cur[j] = d;
        }
    }
    const d = rows[a.len % 3][b.len];
    return if (d <= limit) d else null;
}

test "suggest: a typo finds its name" {
    var s: Suggest = .{ .name = "totla" };
    for ([_][]const u8{ "total", "tot", "table", "x" }) |c| s.offer(c);
    try std.testing.expectEqualStrings("total", s.best.?);
    var t: Suggest = .{ .name = "Foo" };
    for ([_][]const u8{ "Box", "Vec" }) |c| t.offer(c);
    try std.testing.expect(t.best == null);
    var u: Suggest = .{ .name = "xs" };
    for ([_][]const u8{ "x", "ys", "sx" }) |c| u.offer(c);
    try std.testing.expect(u.best == null);
    try std.testing.expectEqual(@as(?usize, 1), editDistance("ab", "ba", 1));
    try std.testing.expectEqual(@as(?usize, 2), editDistance("counter", "conuter2", 2));
}

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

/// The key of a fact about an expression, leaf or list node: a leaf's
/// source position, or a list node's id with bit 32 set. Null for any
/// other node.
fn exprKey(node: Sexp) ?u64 {
    return switch (node) {
        .src => |s| s.pos,
        .list => @as(u64, nodeKey(node) orelse return null) | 1 << 32,
        else => null,
    };
}

/// `exprKey` of an expression a fact is recorded for: a list node the
/// parser built (`recordKey`).
fn recordExprKey(node: Sexp) ?u64 {
    if (node == .list) _ = recordKey(node);
    return exprKey(node);
}

pub const Facts = struct {
    /// Identifier leaf position -> the symbol it names.
    names: std.AutoHashMapUnmanaged(u32, SymbolId) = .empty,
    /// Expression (`exprKey`) -> its type.
    types: std.AutoHashMapUnmanaged(u64, TypeId) = .empty,
    /// Expressions lent where a view of another type is expected ->
    /// the rows of the lend table that make it (`Lend`, `lendsAs`).
    lends: std.AutoHashMapUnmanaged(u64, Lend) = .empty,
    /// Slices (`xs[a..b]`) -> what they lend of the value they slice
    /// (`sliceLend`).
    slice_lends: std.AutoHashMapUnmanaged(NodeKey, Lend) = .empty,
    /// Expressions that yield a view where their context reads the
    /// value it reaches (`SemContext.recordRead`).
    reads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Scope-opening node -> the scope it opens.
    scopes: std.AutoHashMapUnmanaged(NodeKey, ScopeId) = .empty,
    /// Call node -> how its arguments fill the parameters, for calls
    /// with keyword arguments or omitted (defaulted) parameters.
    call_slots: std.AutoHashMapUnmanaged(NodeKey, []const ArgSlot) = .empty,
    /// Checked call node -> what fills each of its callee's run-time
    /// parameters, and which arguments it passes loans on from
    /// (`CallParams`).
    call_params: std.AutoHashMapUnmanaged(NodeKey, CallParams) = .empty,
    /// Match nodes whose non-default arms cover every value.
    exhaustive: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Bracket-list node (`index` / `inst`) -> what it instantiates,
    /// for one that gives compile-time arguments rather than an index.
    instances: std.AutoHashMapUnmanaged(NodeKey, Instance) = .empty,
    /// Call of a generic function (or a statement `f[Int]` that is the
    /// call) -> its type arguments.
    generic_calls: std.AutoHashMapUnmanaged(NodeKey, GenericCall) = .empty,
    /// Positions of names assigned to (`x = e`, `x += e` after
    /// `x` is declared): a use there writes the binding, not reads it.
    writes: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Callee (`member`) node -> the built-in element method it calls.
    elem_calls: std.AutoHashMapUnmanaged(NodeKey, ElemCall) = .empty,
    /// Temporary arrays passed as a `[]T` argument to a call that keeps
    /// no view of them (`SemContext.lendsTempArray`).
    temp_arrays: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Owning temporaries only read where they stand (a `print`
    /// argument, a view lent to a call, an `==` operand, a `?self`
    /// receiver): each is dropped at the end of its statement, or of
    /// its header.
    temp_drops: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Temporaries lent to write (`!mk()`, `!(a if c else b).f`), or the
    /// value a written part of one starts from: written in their
    /// statement's slot.
    written_temps: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Branches of a read branching value that a name holds (`a` in
    /// `print(a if c else b)`): read where they are, never moved out.
    in_place_reads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Values a context reads, takes, or lends (`Use`), keyed by the
    /// value: a name, or a value that yields one of its parts
    /// (`valueParts`). Emit moves a name at a tail of the value out of
    /// its binding only where the value is taken.
    uses: std.AutoHashMapUnmanaged(u64, Use) = .empty,
    /// Header nodes (`for`, `match`, `as`) whose subject is bare and
    /// not plain data -> how the header has it (`Header`).
    headers: std.AutoHashMapUnmanaged(NodeKey, HeaderFact) = .empty,
    /// `Text(...)` call node, or `t.add` / `t.clear` callee node -> the
    /// built-in Text operation it is (`TextCall`).
    text_calls: std.AutoHashMapUnmanaged(NodeKey, TextCall) = .empty,
    /// `<place` nodes that take an optional out of a field or element
    /// (`SemContext.recordTake`).
    takes: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Field and element assignment targets that write through the `!T`
    /// the place holds (`SemContext.recordThroughWrite`).
    through_writes: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Header nodes (`match`, `for`, `as`) emitted over a copy of their
    /// subject: the subject makes a statement temporary, reaches no
    /// place, and the construct does not own what it binds
    /// (`SemContext.recordHeaderCopy`).
    header_copies: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Assignments of a view to a `!T` or `![]T` local, which point it
    /// at another place (`SemContext.recordRepoint`).
    repoints: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Fields and elements of a temporary, holding a Cell, that a read
    /// view lends (`SemContext.recordCellTemp`).
    cell_temps: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// `E.name` nodes that name a member of an error set `E`, through
    /// its module or an alias (`SemContext.recordErrorMember`).
    error_members: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,

    fn deinit(self: *Facts, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Facts).@"struct".field_names) |f| @field(self, f).deinit(allocator);
    }
};

/// How a header (`for`, `match`, `if … as`, `while … as`) has a bare
/// subject that is not plain data (docs/INTERNALS.md, "Header subjects").
pub const Header = enum {
    /// A place, read where it stands as `?p` would lend it: each element
    /// or payload is a view of the place's own.
    viewed,
    /// A value made there, taken as `<e` would take it: each element or
    /// payload is the construct's own.
    taken,
    /// A part, not plain data, of a value made there: the made value is
    /// held in a hidden var for the whole construct, and the part is
    /// viewed in it.
    held,
};

/// A header's `Header`, and the value it holds when `held`.
pub const HeaderFact = struct { how: Header, base: Sexp = .nil };

/// A hidden storage location emit makes for an expression or construct
/// (docs/INTERNALS.md, "Storage facts"): decided once, before ownership
/// is checked, so the ownership checker walks the storage the emitted
/// program has, and emit declares no storage without one
/// (`SemContext.storageOf`).
pub const Storage = struct {
    kind: StorageKind,
    by: StorageBy,
    life: StorageLife,
};

/// What a hidden storage location holds, and the Zig name emit gives it.
pub const StorageKind = enum {
    /// An owning temporary its statement or header drops at its end
    /// (`__rig_tmp`): `dropsTemp`.
    temp,
    /// The value of a header that makes statement temporaries, yielded
    /// by the block that ends them (`__rig_hdr`).
    header_value,
    /// The construct (`match`, `for`, `as`) binds the parts of that
    /// yielded value, a copy of its subject: `copiesHeader`. No name of
    /// its own: the storage is the header's value.
    header_copy,
    /// The made value a header's subject is a part of, held for the
    /// construct (`__rig_held`): `Header.held`.
    held,
    /// The array a `for` takes, held for the loop (`__rig_src`):
    /// `Header.taken`.
    taken,
    /// The iterator a consuming `for` hands its elements over from
    /// (`__rig_it`).
    iterator,
    /// The element a consuming `for` hands over, before its binding
    /// takes it (`__rig_elem`).
    element,
    /// A range `for`'s counter, from the range's start (`__rig_i`).
    range_start,
    /// A range `for`'s end (`__rig_end`).
    range_end,
    /// A `match` subject evaluated once, before its arms (`__rig_subject`).
    subject,
    /// The whole value a `match <x` arm takes (`__rig_whole`).
    whole,
    /// A variant's payload an arm captures (`__rig_payload`).
    payload,
    /// What `if … as` or `while … as` captures (`__rig_opt`).
    as_value,
    /// A mutable copy of what an `as` captures, which its binding views
    /// (`__rig_opt_N_v`).
    as_copy,
    /// The value inside an optional a lend reaches (`__rig_lent`).
    lent,
    /// The payload a branch of a value read where its leaves are takes,
    /// captured by address (`__rig_leaf`).
    leaf,
    /// The error a `catch |e|` handler names (`__rig_err`).
    error_value,
    /// An argument of a call whose arguments are evaluated first
    /// (`__rig_arg`).
    argument,
    /// The receiver of such a call (`__rig_recv`).
    receiver,
    /// The environment of a closure literal lent to a call (`__rig_env`).
    environment,
    /// A closure literal called where it is written (`__rig_fn`).
    invoked,
    /// The environment an owned closure allocates (`__rig_env`), which
    /// the closure value then owns.
    closure_env,
    /// An assignment's value, made before the store (`__rig_new`).
    new_value,
    /// An index of an assignment's target, evaluated before the store
    /// (`__rig_ix`).
    index,
    /// The place an assignment stores to, found once (`__rig_slot`).
    slot,
};

/// How a hidden storage location holds what it holds.
pub const StorageBy = enum {
    /// The value is its own: made there, or taken, and dropped there if
    /// nothing takes it on.
    owned,
    /// A copy of a value that is still held where it was: a view of the
    /// storage views the copy, not that value.
    copy,
    /// The address of a place, or of storage another fact records.
    pointer,
};

/// How long a hidden storage location lives.
pub const StorageLife = enum {
    /// Until its statement ends; a header is its own statement.
    statement,
    /// Until its header ends.
    header,
    /// Until the construct (`match`, `for`, `if … as`) ends.
    construct,
    /// For one iteration of a loop.
    iteration,
    /// Until its `match` arm ends.
    arm,
    /// Until the body of its `if … as` or `while … as` ends.
    body,
    /// Until its `catch` handler ends.
    handler,
    /// Until the expression it is made in ends.
    expression,
    /// Until its call returns.
    call,
    /// Until its assignment's store.
    assignment,
};

/// The key of a storage fact: the expression or construct (`exprKey`)
/// and the kind of storage made for it.
pub const StorageKey = struct { node: u64, kind: StorageKind };

/// What a context does with a value (Core §3).
pub const Use = enum {
    /// Reads it where it is: a `print` argument, an `==` operand, `+e`,
    /// a `?self` receiver, a field or element read.
    read,
    /// Takes it: a binding, an argument, a stored field or element,
    /// `return`, a `break` value, a consuming receiver, a header that
    /// binds it.
    take,
    /// Lends it: `?e`, `!e`.
    lend,
};

/// A built-in method on the elements of a slice, an array, a Vec, or a
/// String: `!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`, and on
/// bytes `buf.read[U16, .big](at)` and `!buf.write[U32, .little](at, v)`.
pub const ElemCall = struct {
    op: ElemOp,
    /// The receiver's element type.
    elem: TypeId,
    /// `read` / `write`: the integer or float type of the value.
    num: TypeId = type_invalid,
};

pub const ElemOp = enum { copy, fill, swap, read, write };

/// A call of a built-in Text operation: `Text(a, b, ...)`, which builds
/// one, and the methods `!t.add(a, b, ...)`, `!t.push(b)`, and
/// `!t.clear()`. `new` and `add` format their arguments as `print` does,
/// reading them; `push` appends one byte.
pub const TextCall = enum { new, add, push, clear };

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
    function,
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

/// A set of a function's run-time parameters: bit `i` stands for
/// parameter `i`, a method's receiver being parameter 0. A parameter
/// past the last bit is in every set.
pub const ParamMask = u64;

/// Every parameter.
pub const all_params: ParamMask = std.math.maxInt(ParamMask);

/// The bit of parameter `i`; every bit past the last.
pub fn paramBit(i: usize) ParamMask {
    return if (i < @bitSizeOf(ParamMask)) @as(ParamMask, 1) << @intCast(i) else all_params;
}

/// Which arguments a call of a function passes loans on from (Core
/// sentence 7; docs/INTERNALS.md, "Call origins"): its result carries
/// the loans of the arguments that fill the parameters in `result`, and
/// it may store in what its write arguments lead to only the loans of
/// those in `stores`. Set on each function and method where it is
/// declared; a call reads it from its callee, never from a body.
pub const Origins = struct {
    result: ParamMask = all_params,
    stores: ParamMask = all_params,
    /// `result` is what a `from` clause names, not the signature's types.
    declared: bool = false,
};

/// A function's `from` clause: the names it lists (empty for `from
/// static`), and the function's parameters.
pub const DeclaredOrigins = struct { names: Sexp, params: Sexp, returns: Sexp };

/// What fills a run-time parameter of a call: the receiver of a method
/// called on a value, the argument at an index of the call's argument
/// list (a `(kwarg ...)` stands for its value), or the parameter's
/// default value.
pub const ParamFill = union(enum) {
    receiver,
    arg: u32,
    default,
};

/// A checked call's parameters: what fills each, in the callee's order,
/// and its callee's `Origins` (docs/INTERNALS.md, "Call origins").
pub const CallParams = struct {
    fills: []const ParamFill,
    origins: Origins,

    /// Whether the call's result carries the loans of the argument at
    /// index `arg`.
    pub fn resultCarries(self: CallParams, arg: usize) bool {
        return self.filled(.{ .arg = @intCast(arg) }, self.origins.result);
    }

    /// Whether the call's result carries the loans of its receiver.
    pub fn resultCarriesReceiver(self: CallParams) bool {
        return self.filled(.receiver, self.origins.result);
    }

    /// Whether the call may store the loans of its receiver.
    pub fn storesReceiver(self: CallParams) bool {
        return self.filled(.receiver, self.origins.stores);
    }

    /// Whether the call may store the loans of the argument at index
    /// `arg`.
    pub fn stores(self: CallParams, arg: usize) bool {
        return self.filled(.{ .arg = @intCast(arg) }, self.origins.stores);
    }

    /// Whether `what` fills a parameter in `mask`.
    fn filled(self: CallParams, what: ParamFill, mask: ParamMask) bool {
        for (self.fills, 0..) |f, i| {
            const same = switch (what) {
                .receiver => f == .receiver,
                .arg => |a| f == .arg and f.arg == a,
                .default => false,
            };
            if (same and mask & paramBit(i) != 0) return true;
        }
        return false;
    }
};

/// `rig check --facts=sema`: every entry of the module's `Facts`, one line each,
///
///   FACT KIND LINE:COL-LINE:COL "SOURCE" [VALUE]
///
/// sorted by fact, then span, then text. Node, symbol, and type ids
/// never appear (a symbol is printed by name and kind, a type as
/// spelled), so two compilers' dumps of one program diff cleanly.
/// `root` is the module's IR; a node outside it prints as `node#ID`.
pub fn writeFactsDump(ctx: *const SemContext, a: std.mem.Allocator, root: Sexp, w: *std.Io.Writer) !void {
    var nodes: std.AutoHashMapUnmanaged(NodeKey, Sexp) = .empty;
    var leaves: std.AutoHashMapUnmanaged(u32, Sexp) = .empty;
    var stack: std.ArrayList(Sexp) = .empty;
    try stack.append(a, root);
    while (stack.pop()) |s| switch (s) {
        .list => |l| {
            if (l.id != 0) try nodes.put(a, l.id, s);
            try stack.appendSlice(a, l.items());
        },
        .src => |x| try leaves.put(a, x.pos, s),
        else => {},
    };

    const Line = struct {
        fact: usize,
        start: u32,
        end: u32,
        text: []const u8,

        fn lessThan(_: void, x: @This(), y: @This()) bool {
            if (x.fact != y.fact) return x.fact < y.fact;
            if (x.start != y.start) return x.start < y.start;
            if (x.end != y.end) return x.end < y.end;
            return std.mem.order(u8, x.text, y.text) == .lt;
        }
    };
    var out: std.ArrayList(Line) = .empty;
    var lines: diag.Lines = .{ .source = ctx.source };
    inline for (@typeInfo(Facts).@"struct".field_names, 0..) |name, fact| {
        const Key = @FieldType(@FieldType(Facts, name).KV, "key");
        var it = @field(ctx.facts, name).iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            // `names` and `writes` are keyed by a leaf's position, the
            // expression facts by `exprKey`, the rest by node id.
            const node: ?Sexp, const id: u64 = if (comptime std.mem.eql(u8, name, "names") or std.mem.eql(u8, name, "writes"))
                .{ leaves.get(key), key }
            else if (Key == u64)
                .{ if (key >> 32 != 0) nodes.get(@truncate(key)) else leaves.get(@truncate(key)), key & 0xffff_ffff }
            else
                .{ nodes.get(key), key };
            var text: std.Io.Writer.Allocating = .init(a);
            const t = &text.writer;
            try t.print("{s} ", .{name});
            var span: parser.Span = .empty;
            if (node) |n| {
                span = if (ctx.parser) |p| p.base.span(n) else diag.leafSpan(n);
                const kind = if (n == .src) "leaf" else if (n.kind()) |k| @tagName(k) else "group";
                const from = lines.at(span.start);
                const to = lines.at(span.end);
                try t.print("{s} {d}:{d}-{d}:{d} \"", .{ kind, from.line, from.col, to.line, to.col });
                for (ctx.source[span.start..@min(span.end, span.start + 40)]) |c|
                    if (c == '\n') try t.writeAll("\\n") else try t.writeByte(c);
                try t.writeAll("\"");
            } else try t.print("node#{d}", .{id});
            try writeFactValue(ctx, a, t, name, e.value_ptr.*);
            try out.append(a, .{ .fact = fact, .start = span.start, .end = span.end, .text = text.written() });
        }
    }
    std.mem.sort(Line, out.items, {}, Line.lessThan);
    for (out.items) |l| try w.print("{s}\n", .{l.text});
}

/// `rig check --facts=storage`: every hidden storage location emit makes
/// for the root module (`Storage`), one per line, in source order:
///
///   KIND NODE L:C-L:C "TEXT" BY LIFE
///
/// with the node it is made for, as `writeFactsDump` shows one.
pub fn writeStorageDump(ctx: *const SemContext, a: std.mem.Allocator, root: Sexp, w: *std.Io.Writer) !void {
    const Line = struct {
        start: u32,
        end: u32,
        text: []const u8,

        fn lessThan(_: void, x: @This(), y: @This()) bool {
            if (x.start != y.start) return x.start < y.start;
            if (x.end != y.end) return x.end > y.end;
            return std.mem.order(u8, x.text, y.text) == .lt;
        }
    };
    var out: std.ArrayList(Line) = .empty;
    var lines: diag.Lines = .{ .source = ctx.source };
    var stack: std.ArrayList(Sexp) = .empty;
    try stack.append(a, root);
    while (stack.pop()) |n| {
        if (n == .list) try stack.appendSlice(a, n.list.items());
        if (n != .src and !(n == .list and n.list.id != 0)) continue;
        inline for (@typeInfo(StorageKind).@"enum".field_names) |name| {
            const kind = @field(StorageKind, name);
            if (ctx.storageOf(n, kind)) |s| {
                const span = if (ctx.parser) |p| p.base.span(n) else diag.leafSpan(n);
                const from = lines.at(span.start);
                const to = lines.at(span.end);
                var text: std.Io.Writer.Allocating = .init(a);
                const t = &text.writer;
                const node_kind = if (n == .src) "leaf" else if (n.kind()) |k| @tagName(k) else "group";
                try t.print("{s} {s} {d}:{d}-{d}:{d} \"", .{ @tagName(kind), node_kind, from.line, from.col, to.line, to.col });
                for (ctx.source[span.start..@min(span.end, span.start + 40)]) |c|
                    if (c == '\n') try t.writeAll("\\n") else try t.writeByte(c);
                try t.print("\" {s} {s}", .{ @tagName(s.by), @tagName(s.life) });
                try out.append(a, .{ .start = span.start, .end = span.end, .text = text.written() });
            }
        }
    }
    std.mem.sort(Line, out.items, {}, Line.lessThan);
    for (out.items) |l| try w.print("{s}\n", .{l.text});
}

fn writeFactValue(ctx: *const SemContext, a: std.mem.Allocator, w: *std.Io.Writer, comptime name: []const u8, v: anytype) !void {
    const V = @TypeOf(v);
    if (V == void) return;
    if (comptime std.mem.eql(u8, name, "names")) {
        const sym = ctx.symbols.items[v];
        return w.print(" {s} {s}", .{ sym.name, @tagName(sym.kind) });
    }
    if (comptime std.mem.eql(u8, name, "types"))
        return w.print(" {s}", .{try formatTypeIn(ctx, a, v)});
    if (comptime std.mem.eql(u8, name, "scopes")) return w.print(" scope {d}", .{v});
    switch (V) {
        TextCall, Use => try w.print(" {s}", .{@tagName(v)}),
        HeaderFact => try w.print(" {s}", .{@tagName(v.how)}),
        Lend => {
            if (v.implicit) try w.writeAll(" implicit");
            for (v.steps()) |step| try w.print(" {s}", .{@tagName(step)});
            if (v.fn_ty != type_invalid) try w.print(" {s}", .{try formatTypeIn(ctx, a, v.fn_ty)});
        },
        ElemCall => {
            try w.print(" {s} {s}", .{ @tagName(v.op), try formatTypeIn(ctx, a, v.elem) });
            if (v.num != type_invalid) try w.print(" {s}", .{try formatTypeIn(ctx, a, v.num)});
        },
        Instance => switch (v) {
            .type => |ty| try w.print(" type {s}", .{try formatTypeIn(ctx, a, ty)}),
            .function => try w.writeAll(" function"),
        },
        GenericCall => {
            for (v.type_args) |ty| try w.print(" {s}", .{if (ty == type_invalid) "_" else try formatTypeIn(ctx, a, ty)});
            if (v.receiver_arg) try w.writeAll(" receiver");
        },
        []const ArgSlot => for (v) |slot| switch (slot) {
            .arg => |i| try w.print(" arg{d}", .{i}),
            .default => try w.writeAll(" default"),
        },
        CallParams => {
            for (v.fills) |f| switch (f) {
                .receiver => try w.writeAll(" receiver"),
                .arg => |i| try w.print(" arg{d}", .{i}),
                .default => try w.writeAll(" default"),
            };
            try writeMask(w, "result", v.origins.result, v.fills.len);
            try writeMask(w, "stores", v.origins.stores, v.fills.len);
        },
        else => @compileError("check --facts=sema: no format for the fact " ++ name),
    }
}

/// ` name:` then the parameters among the first `n` that `mask`
/// holds, or ` name:all` when it holds them all.
fn writeMask(w: *std.Io.Writer, comptime name: []const u8, mask: ParamMask, n: usize) !void {
    var every = true;
    for (0..n) |i| if (mask & paramBit(i) == 0) {
        every = false;
    };
    if (every) return w.writeAll(" " ++ name ++ ":all");
    try w.writeAll(" " ++ name ++ ":");
    var first = true;
    for (0..n) |i| if (mask & paramBit(i) != 0) {
        try w.print("{s}{d}", .{ if (first) "" else ",", i });
        first = false;
    };
}

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
    fits: Wide,
    /// An integer wider than this many bits: the body shifts the value
    /// by a constant amount.
    shift: Wide,
    /// Does not move (`moves` is not `yes`): the body copies the
    /// parameter's value.
    no_move,
    /// Holds no Cell inline: the body binds a copy of a value holding the
    /// parameter (a loop element, a match payload) and may lend it, so a
    /// Cell in it would change in the copy only.
    no_cell,
    /// Needs no cleanup: the body discards the parameter's value, leaves
    /// a temporary of it, overwrites one, or keeps one in an array or a
    /// slice.
    no_cleanup,
    /// A compile-time integer from 0 to `max_array_len`: the body uses
    /// the value parameter as an array length.
    array_len,
    /// An integer or float type: the body reads or writes one in bytes
    /// (`b.read[T, .big](at)`).
    bytes,
    /// An integer: the body gives a value of the parameter's type a
    /// division of whole-number literals (`1 / 2`), which divides
    /// integers.
    whole_division,
    /// Not an error: the signature returns the parameter as a fallible
    /// `T!`, whose failure and success would both be errors.
    not_error,
    /// Not a function type: the declaration makes a shared or weak handle
    /// of the parameter (`*T`, `~T`), and `*fun(...)` is an owned
    /// closure, not a handle of a function.
    not_function,

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
            .no_move => "a value that does not move",
            .no_cleanup => "a value that owns no resource",
            .no_cell => "a value that holds no Cell",
            .array_len => "an array length",
            .bytes => "an integer or float in bytes",
            .whole_division => "a division of whole numbers",
            .not_error => "a fallible return",
            .not_function => "a handle",
        };
    }
};

pub const GenericRequirement = struct {
    param: SymbolId,
    req: Requirement,
    pos: u32,
    op: []const u8,
    /// The module whose source `pos` is in: 0 for this one, or the
    /// module that declares the body of a proxy's requirement.
    module_id: u32 = 0,
};

/// A shared or weak handle of `inner` (`*T`, `~T`, by `op`) is made or
/// spelled at `pos`: when `inner` is a type parameter, each instance must
/// give it a type that is no function (`Requirement.not_function`).
pub fn requireHandleOf(ctx: *SemContext, inner: TypeId, pos: u32, op: []const u8) !void {
    switch (ctx.types.get(inner)) {
        .type_var => |param| try ctx.generic_requirements.append(ctx.allocator, .{ .param = param, .req = .not_function, .pos = pos, .op = op }),
        else => {},
    }
}

/// A generic body copies a value of a type parameter, found by the
/// ownership checker: every instance's argument for it must own no
/// resource.
pub const PlainRequirement = struct {
    param: SymbolId,
    pos: u32,
    /// The value is an element its collection still owns, taken out
    /// (moved, dropped, reassigned) rather than copied.
    element: bool = false,
    /// Not a copy: the value is stored where no loan is tracked (a Cell,
    /// a Signal, an owned closure), so each instance's argument must
    /// hold no String, which may view a Text.
    view: bool = false,
    /// The module whose source `pos` is in; 0 for this one.
    module_id: u32 = 0,
};

/// The lists of what generic bodies do over their type parameters, which
/// each instance makes concrete: `generic_fn_uses`, `generic_uses`,
/// `generic_arrays`, `generic_frames`. Each entry is added through
/// `SemContext.addGeneric`, which indexes it.
pub const GenericList = enum(u8) { fn_uses, uses, arrays, frames };

/// An entry of one of another module's lists of what its generic bodies
/// do (`importParam`), copied here once.
const ImportedEntry = struct { module_id: u32, list: GenericList, index: u32 };

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

    symbols: std.ArrayList(Symbol) = .empty,
    /// Scope 1 is the module scope.
    scopes: std.ArrayList(Scope) = .empty,
    types: TypeStore,
    /// Facts of each interned type, by TypeId.
    type_info: std.ArrayList(TypeInfo) = .empty,
    /// Every declared type's `contents` is known, and so are the
    /// ownership facts in `type_info`.
    contents_ready: bool = false,
    /// Checks on types spelled in declarations that wait for
    /// `contents_ready`.
    deferred_checks: std.ArrayList(resolve.DeferredCheck) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Each error reported, by position and message hash -> its index in
    /// `diagnostics`: the same finding reached twice is reported once.
    /// (A check whose diagnostics are dropped truncates `diagnostics`.)
    reported: std.AutoHashMapUnmanaged(struct { pos: u32, message: u64 }, usize) = .empty,
    facts: Facts = .{},

    cell_sym_id: SymbolId = symbol_invalid,
    vec_sym_id: SymbolId = symbol_invalid,
    signal_sym_id: SymbolId = symbol_invalid,
    box_sym_id: SymbolId = symbol_invalid,
    endian_sym_id: SymbolId = symbol_invalid,

    /// Assigned by the module graph.
    module_id: u32 = 0,
    /// The program's root module, whose `main` is the entry point.
    is_root: bool = false,
    /// The name other modules `use`, qualified (`geo`, `std.os`).
    name: []const u8 = "",
    /// The module's emitted file, which other modules `@import`.
    zig_file: []const u8 = "",
    /// A module of the standard library.
    is_std: bool = false,
    imports: []const ImportEntry = &.{},
    /// `use NAME` symbol -> origin module id.
    module_refs: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    /// Every module of the program by id, shared by their contexts: a
    /// type from another module names its origin by id.
    foreign_semas: *const ModuleMap = &no_modules,
    /// The ids of the modules this one reaches through its imports.
    reach: std.bit_set.Dynamic = .{},

    /// Type alias symbol -> its target type expression, resolved on
    /// first use (aliases may be used before they are declared).
    alias_targets: std.AutoHashMapUnmanaged(SymbolId, Sexp) = .empty,
    /// Aliases currently being resolved, to report cycles.
    alias_in_progress: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Operations generic bodies apply to their type parameters.
    generic_requirements: std.ArrayList(GenericRequirement) = .empty,
    /// Instantiated generic type -> position of its first spelling.
    instantiation_sites: std.AutoHashMapUnmanaged(TypeId, u32) = .empty,
    /// Instances of user generics spelled with type parameters, inside
    /// generic declarations (`Opt[T]` in `Wrap[T]`'s methods). See
    /// `expandInstantiations`.
    generic_uses: std.ArrayList(TypeId) = .empty,
    /// The instances of generic functions the module's calls make, each
    /// with the position of its first call, in the order found.
    fn_instances: std.ArrayList(struct { inst: FnInstance, site: u32, via: ?InstanceRoot = null }) = .empty,
    /// Every instance in `fn_instances` and `generic_fn_uses`.
    fn_instance_set: std.HashMapUnmanaged(FnInstance, void, FnInstance.Context, std.hash_map.default_max_load_percentage) = .empty,
    /// Instances of generic functions called with type parameters, inside
    /// generic bodies (`max[T]` in `fun top[T]`); expanded like
    /// `generic_uses`.
    generic_fn_uses: std.ArrayList(FnInstance) = .empty,
    /// Integer constants: bindings never reassigned or written whose
    /// value is a constant expression. The emitted Zig computes these at
    /// compile time, so sema checks their arithmetic. Module constants
    /// are folded once, in declaration order, before any type is
    /// resolved (`resolve.foldModuleConsts`), so a type anywhere in the
    /// module can name them.
    const_ints: std.AutoHashMapUnmanaged(SymbolId, ConstVal) = .empty,
    /// The array types spelled or built in generic declarations, which
    /// each instance checks against `max_value_bytes`; `module_id` is
    /// the module whose source `pos` is in (0 for this one).
    generic_arrays: std.ArrayList(struct { ty: TypeId, pos: u32, module_id: u32 = 0 }) = .empty,
    /// The stack values of the generic functions and closures, and of the
    /// generic types' methods, whose sizes depend on their parameters:
    /// each instance checks them against `max_frame_bytes`.
    generic_frames: std.ArrayList(Frame) = .empty,
    /// For each `GenericList` and each type or integer parameter, the
    /// positions of the list's entries that mention the parameter, in
    /// order: an instance visits only the entries over its own parameters
    /// (`genericEntries`).
    generic_index: std.AutoHashMapUnmanaged(struct { list: GenericList, param: SymbolId }, std.ArrayList(u32)) = .empty,
    /// The types reported as too large, each once; a type holding one is
    /// not reported again.
    oversized: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    /// Nonzero while an expression is checked with its diagnostics
    /// dropped (`typecheck.synthQuiet`): an array too large is left to
    /// the check that keeps them.
    quiet: u32 = 0,
    /// `minBytes` of each type sized so far.
    byte_sizes: std.AutoHashMapUnmanaged(TypeId, ?u128) = .empty,
    /// A local `const k = n` binding of a compile-time integer parameter ->
    /// the `ct_param` it stands for, where an array length or a
    /// compile-time argument names it.
    ct_locals: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Another module's generic type or compile-time parameter (where it
    /// is declared) -> its proxy here (`proxyOf`).
    imported: std.AutoHashMapUnmanaged(ForeignRef, SymbolId) = .empty,
    /// The entries of other modules' lists copied here (`importParam`).
    imported_entries: std.AutoHashMapUnmanaged(ImportedEntry, void) = .empty,
    /// The copies of type parameters' values generic bodies make, which
    /// the ownership checker finds: this module's own, recorded after it
    /// is checked, and those of the proxies' bodies, imported with them.
    plain_reqs: std.ArrayList(PlainRequirement) = .empty,
    /// The hidden storage emit makes (`Storage`), but for the kinds the
    /// facts table keeps (`temp` is `temp_drops`, `header_copy` is
    /// `header_copies`): recorded after the expressions are checked
    /// (`storage.plan`).
    storage: std.AutoHashMapUnmanaged(StorageKey, Storage) = .empty,
    /// The values expression statements discard (`discardsValue`).
    discards: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The `from` clause of each function and method that writes one
    /// (`-> T from a, b`), by where its name is declared, with its
    /// parameters (`computeOrigins`).
    declared_origins: std.AutoHashMapUnmanaged(u32, DeclaredOrigins) = .empty,

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
        self.reported.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.declared_origins.deinit(self.allocator);
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
        self.ct_locals.deinit(self.allocator);
        self.generic_arrays.deinit(self.allocator);
        self.generic_frames.deinit(self.allocator);
        var index = self.generic_index.valueIterator();
        while (index.next()) |at| at.deinit(self.allocator);
        self.generic_index.deinit(self.allocator);
        self.oversized.deinit(self.allocator);
        self.byte_sizes.deinit(self.allocator);
        self.imported.deinit(self.allocator);
        self.imported_entries.deinit(self.allocator);
        self.plain_reqs.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        self.discards.deinit(self.allocator);
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

    /// An error marked `lint` (see `diag.Diagnostic.lint`).
    pub fn lintErr(self: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const n = self.diagnostics.items.len;
        try self.err(pos, fmt, args);
        if (self.diagnostics.items.len > n) self.diagnostics.items[n].lint = true;
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

    /// A note at `pos` in module `module`'s source (0, or this module's
    /// id, for this module): where another module's generic body applies
    /// an operation an instance made here does not support.
    pub fn noteIn(self: *SemContext, module: u32, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try self.arena.allocator().print(fmt, args);
        const m = if (module == self.module_id) 0 else module;
        try self.diagnostics.append(self.allocator, .{ .severity = .note, .pos = pos, .end = pos, .message = msg, .module = m });
    }

    fn report(self: *SemContext, severity: diag.Severity, at: diag.Span, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const msg = try self.arena.allocator().print(fmt, args);
        if (severity == .@"error") {
            const gop = try self.reported.getOrPut(self.allocator, .{ .pos = at.start, .message = std.hash.Wyhash.hash(0, msg) });
            if (gop.found_existing and gop.value_ptr.* < self.diagnostics.items.len) {
                const d = self.diagnostics.items[gop.value_ptr.*];
                if (d.pos == at.start and std.mem.eql(u8, d.message, msg)) return;
            }
            gop.value_ptr.* = self.diagnostics.items.len;
        }
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

    /// Like `lookup`, but a local declared after `pos` in a body is not
    /// visible there yet.
    pub fn lookupBefore(self: *const SemContext, from_scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
        var sid: ?ScopeId = from_scope;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            var id = self.lookupInScopeOnly(s, name) orelse symbol_invalid;
            while (id != symbol_invalid and s != module_scope and self.symbols.items[id].kind == .local and self.symbols.items[id].decl_pos > pos) id = self.symbols.items[id].prev_in_scope;
            if (id != symbol_invalid) return id;
            sid = self.scopes.items[s].parent;
        }
        return null;
    }

    /// Offer `s` each name visible from `from_scope` at `pos` whose
    /// symbol `keep` accepts, for a diagnostic's "did you mean".
    pub fn offerVisible(self: *const SemContext, s: *Suggest, from_scope: ScopeId, pos: u32, keep: *const fn (Symbol) bool) void {
        var sid: ?ScopeId = from_scope;
        while (sid) |id| {
            if (id == scope_invalid or id >= self.scopes.items.len) break;
            for (self.scopes.items[id].symbols.items) |sym_id| {
                const sym = self.symbols.items[sym_id];
                if (id != module_scope and sym.kind == .local and sym.decl_pos > pos) continue;
                if (keep(sym)) s.offer(sym.name);
            }
            sid = self.scopes.items[id].parent;
        }
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
        return if (node == .src) self.symbolAt(node.src.pos) else null;
    }

    /// The symbol named by the identifier at source position `pos`.
    pub fn symbolAt(self: *const SemContext, pos: u32) ?SymbolId {
        return self.facts.names.get(pos);
    }

    /// The type of an expression node.
    pub fn typeOf(self: *const SemContext, node: Sexp) ?TypeId {
        return self.facts.types.get(exprKey(node) orelse return null);
    }

    /// The type of the symbol an identifier leaf names.
    pub fn bindingTypeOf(self: *const SemContext, node: Sexp) ?TypeId {
        const id = self.symbolOf(node) orelse return null;
        return self.symbols.items[id].ty;
    }

    /// Whether `node` yields a view whose value its context reads
    /// (`recordRead`).
    pub fn readsThrough(self: *const SemContext, node: Sexp) bool {
        return self.facts.reads.contains(exprKey(node) orelse return false);
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

    /// What fills each parameter of a checked call, and which arguments
    /// it passes loans on from; null for a call sema did not check
    /// against a signature (a constructor, `print`, a call it rejected).
    pub fn callParamsOf(self: *const SemContext, call: Sexp) ?CallParams {
        const key = nodeKey(call) orelse return null;
        return self.facts.call_params.get(key);
    }

    /// What a bracket list instantiates; null for an index (or a node
    /// sema never reached).
    pub fn instanceOf(self: *const SemContext, node: Sexp) ?Instance {
        if (!rig.isBracketList(node)) return null;
        return self.facts.instances.get(nodeKey(node) orelse return null);
    }

    /// A call's callee without its compile-time arguments: `f` for
    /// `f[3](x)`, `p.scale` for `p.scale[2]()`, `Wrap` for
    /// `Wrap[Int](v: 3)` (whose instance `instanceOf` the bracket list
    /// gives).
    pub fn calleeOf(self: *const SemContext, call: Sexp) Sexp {
        const callee = ir.Call.callee(call);
        if (self.instanceOf(callee) == null) return callee;
        return ir.get(callee, .object);
    }

    /// The compile-time arguments of a call that has them; null for any
    /// other.
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
        try self.facts.types.put(self.allocator, recordExprKey(node) orelse return, ty);
    }

    /// `node` yields a view where its context reads the value it
    /// reaches: a Copy value where the value is expected, an operand, the
    /// optional of `??`, `?`, or `as`, a String or slice indexed, or a
    /// clone.
    pub fn recordRead(self: *SemContext, node: Sexp) !void {
        try self.facts.reads.put(self.allocator, recordExprKey(node) orelse return, {});
    }

    /// `node`, a temporary array (a literal, a fill, a call's result),
    /// is passed as a `[]T` argument to a call that keeps no view of it.
    pub fn recordTempArray(self: *SemContext, node: Sexp) !void {
        try self.facts.temp_arrays.put(self.allocator, recordKey(node), {});
    }

    /// Whether `node` is a temporary array lent as a `[]T` argument for
    /// the call (`recordTempArray`).
    pub fn lendsTempArray(self: *const SemContext, node: Sexp) bool {
        return self.facts.temp_arrays.contains(nodeKey(node) orelse return false);
    }

    /// `node` is lent, where a view of another type is expected, by the
    /// rows of the lend table `lend` names (`lendOf`).
    pub fn recordLend(self: *SemContext, node: Sexp, lend: Lend) !void {
        std.debug.assert(lend.len > 0 or lend.implicit);
        try self.facts.lends.put(self.allocator, recordExprKey(node) orelse return, lend);
    }

    /// How `node` is lent where a view of another type is expected: the
    /// rows of the lend table that make the view (`recordLend`); null
    /// where its value is the view itself.
    pub fn recordSliceLend(self: *SemContext, slice: Sexp, lend: Lend) !void {
        try self.facts.slice_lends.put(self.allocator, recordKey(slice), lend);
    }

    /// What slice `slice` lends of the value it slices (`sliceLend`);
    /// null for a node that is no checked slice.
    pub fn sliceLendOf(self: *const SemContext, slice: Sexp) ?Lend {
        const key = nodeKey(slice) orelse return null;
        return self.facts.slice_lends.get(key);
    }

    pub fn lendOf(self: *const SemContext, node: Sexp) ?Lend {
        return self.facts.lends.get(exprKey(node) orelse return null);
    }

    /// The function type `node` is lent as, where a callable view is
    /// expected and `node` is not one yet (`Lend.callable`).
    pub fn callableOf(self: *const SemContext, node: Sexp) ?TypeId {
        const lend = self.lendOf(node) orelse return null;
        return lend.callable();
    }

    /// `node` is `<place` taking an optional out of a field or element,
    /// leaving `none` behind.
    /// `node`, a `member`, names a member of an error set, not a
    /// module's constant or a value's field.
    pub fn recordErrorMember(self: *SemContext, node: Sexp) !void {
        try self.facts.error_members.put(self.allocator, recordKey(node), {});
    }

    pub fn isErrorMember(self: *const SemContext, node: Sexp) bool {
        return self.facts.error_members.contains(nodeKey(node) orelse return false);
    }

    pub fn recordTake(self: *SemContext, node: Sexp) !void {
        try self.facts.takes.put(self.allocator, recordKey(node), {});
    }

    pub fn takes(self: *const SemContext, node: Sexp) bool {
        return self.facts.takes.contains(nodeKey(node) orelse return false);
    }

    /// `node`, the target of `p.f = v` or `p.f op= v`, writes the value
    /// the `!T` it holds views rather than pointing it elsewhere.
    pub fn recordThroughWrite(self: *SemContext, node: Sexp) !void {
        try self.facts.through_writes.put(self.allocator, recordKey(node), {});
    }

    pub fn writesThrough(self: *const SemContext, node: Sexp) bool {
        return self.facts.through_writes.contains(nodeKey(node) orelse return false);
    }

    /// Header `node` (a `match`, `for`, or `as`) is evaluated in a block
    /// that ends the temporaries its subject makes (`firstStmtTemp`)
    /// and yields the subject's value, which reaches no place
    /// (`storage.headerPoints`), so what it binds views a copy of that
    /// value, not the subject itself.
    pub fn recordHeaderCopy(self: *SemContext, node: Sexp) !void {
        try self.facts.header_copies.put(self.allocator, recordKey(node), {});
    }

    pub fn copiesHeader(self: *const SemContext, node: Sexp) bool {
        return self.facts.header_copies.contains(nodeKey(node) orelse return false);
    }

    /// `node`, an assignment of a `!T` or `![]T` local, gives it a view
    /// (`w = !n`, `w = <w2`): the local points at another place, rather
    /// than writing the value it views.
    pub fn recordRepoint(self: *SemContext, node: Sexp) !void {
        try self.facts.repoints.put(self.allocator, recordKey(node), {});
    }

    pub fn repoints(self: *const SemContext, node: Sexp) bool {
        return self.facts.repoints.contains(nodeKey(node) orelse return false);
    }

    /// `node`, a field or element of a temporary (`mk().p`), holds a Cell
    /// that the read view lending it (`?mk().p`, or a `?self` receiver)
    /// may change: the temporary is constant, so the part is copied into
    /// a mutable local first.
    pub fn recordCellTemp(self: *SemContext, node: Sexp) !void {
        try self.facts.cell_temps.put(self.allocator, recordKey(node), {});
    }

    pub fn lendsCellTemp(self: *const SemContext, node: Sexp) bool {
        return self.facts.cell_temps.contains(nodeKey(node) orelse return false);
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

    pub fn recordCallParams(self: *SemContext, call: Sexp, params: CallParams) !void {
        try self.facts.call_params.put(self.allocator, recordKey(call), params);
    }

    pub fn recordElemCall(self: *SemContext, callee: Sexp, call: ElemCall) !void {
        try self.facts.elem_calls.put(self.allocator, recordKey(callee), call);
    }

    /// The built-in element method a call's callee (`member`) names.
    pub fn elemCallOf(self: *const SemContext, callee: Sexp) ?ElemCall {
        return self.facts.elem_calls.get(nodeKey(callee) orelse return null);
    }

    /// Emit holds a value of `node` in hidden storage `s`
    /// (`storage.plan`). A `temp` is recorded as `recordTempDrop`, and a
    /// `header_copy` as `recordHeaderCopy`.
    pub fn recordStorage(self: *SemContext, node: Sexp, s: Storage) !void {
        std.debug.assert(s.kind != .temp and s.kind != .header_copy);
        const key = recordExprKey(node) orelse return;
        const gop = try self.storage.getOrPut(self.allocator, .{ .node = key, .kind = s.kind });
        // One node's storage of one kind is decided once.
        if (gop.found_existing) std.debug.assert(std.meta.eql(gop.value_ptr.*, s));
        gop.value_ptr.* = s;
    }

    /// The hidden storage of `kind` emit makes for `node`, if any
    /// (`Storage`).
    pub fn storageOf(self: *const SemContext, node: Sexp, kind: StorageKind) ?Storage {
        return switch (kind) {
            .temp => if (self.dropsTemp(node)) .{ .kind = .temp, .by = .owned, .life = .statement } else null,
            .header_copy => if (self.copiesHeader(node)) .{ .kind = .header_copy, .by = .copy, .life = .construct } else null,
            else => self.storage.get(.{ .node = exprKey(node) orelse return null, .kind = kind }),
        };
    }

    /// `stmt` is an expression statement, whose value nothing uses: the
    /// value it yields, and each value it passes on to it (the operand of
    /// `!`, `?`, `catch`, and a lend sigil), is discarded.
    pub fn recordDiscard(self: *SemContext, stmt: Sexp) !void {
        var e = stmt;
        while (true) {
            try self.discards.put(self.allocator, recordExprKey(e) orelse return, {});
            e = switch (e.kind() orelse return) {
                .propagate => ir.Propagate.value(e),
                .propagate_none => ir.PropagateNone.value(e),
                .@"catch" => ir.Catch.value(e),
                .read, .write => ir.get(e, .operand),
                else => return,
            };
        }
    }

    /// Whether nothing uses the value of `node`: it is, or its value
    /// passes on to, an expression statement (`recordDiscard`).
    pub fn discardsValue(self: *const SemContext, node: Sexp) bool {
        return self.discards.contains(exprKey(node) orelse return false);
    }

    pub fn recordTempDrop(self: *SemContext, node: Sexp) !void {
        try self.facts.temp_drops.put(self.allocator, recordKey(node), {});
    }

    pub fn recordWrittenTemp(self: *SemContext, node: Sexp) !void {
        try self.facts.written_temps.put(self.allocator, recordKey(node), {});
    }

    /// Whether `node` is a temporary lent to write, or the value a part
    /// lent to write starts from (`recordWrittenTemp`): its statement's
    /// slot is written, so it is reached there, never through a copy.
    pub fn writesTemp(self: *const SemContext, node: Sexp) bool {
        return self.facts.written_temps.contains(nodeKey(node) orelse return false);
    }

    /// Whether `node` is an owning temporary its statement drops at its
    /// end (`recordTempDrop`).
    pub fn dropsTemp(self: *const SemContext, node: Sexp) bool {
        return self.facts.temp_drops.contains(nodeKey(node) orelse return false);
    }

    pub fn recordReadInPlace(self: *SemContext, node: Sexp) !void {
        try self.facts.in_place_reads.put(self.allocator, exprKey(node) orelse return, {});
    }

    /// Whether `node`, a branch of a read branching value, is read where
    /// a name holds it (`recordReadInPlace`).
    pub fn readsInPlace(self: *const SemContext, node: Sexp) bool {
        return self.facts.in_place_reads.contains(exprKey(node) orelse return false);
    }

    /// The context of `node` reads, takes, or lends it (`Facts.uses`).
    /// A value has one use: a second record of it must agree. A value
    /// lent implicitly where a view goes was first recorded as taken
    /// (`recordImplicitLend`); checking its context again records the
    /// take before the lend, and keeps the lend.
    pub fn recordUse(self: *SemContext, node: Sexp, use: Use) !void {
        const key = recordExprKey(node) orelse return;
        const gop = try self.facts.uses.getOrPut(self.allocator, key);
        if (gop.found_existing and gop.value_ptr.* == .lend and use == .take) return;
        if (gop.found_existing) std.debug.assert(gop.value_ptr.* == use);
        gop.value_ptr.* = use;
    }

    /// The context of `node` lends it, where it was first recorded as
    /// taken: a bare value lent to read where a view is expected.
    pub fn recordImplicitLend(self: *SemContext, node: Sexp) !void {
        const key = recordExprKey(node) orelse return;
        try self.facts.uses.put(self.allocator, key, .lend);
    }

    /// What the context of `node` does with it, where one was recorded.
    pub fn useOf(self: *const SemContext, node: Sexp) ?Use {
        return self.facts.uses.get(exprKey(node) orelse return null);
    }

    /// `header` has its bare subject as `how`; for `held`, `base` is the
    /// value made there that it holds.
    pub fn recordHeader(self: *SemContext, header: Sexp, how: Header, base: Sexp) !void {
        std.debug.assert((how == .held) == (base != .nil));
        try self.facts.headers.put(self.allocator, recordKey(header), .{ .how = how, .base = base });
    }

    /// How the header `node` (a `for`, a `match`, or an `as`) has a bare
    /// subject (`Header`); null for a subject written with a sigil, or
    /// one whose value is copied.
    pub fn headerOf(self: *const SemContext, node: Sexp) ?Header {
        const fact = self.facts.headers.get(nodeKey(node) orelse return null) orelse return null;
        return fact.how;
    }

    /// The value made there that the header `node` holds for its
    /// construct (`Header.held`): `mk()` in `match mk().e`.
    pub fn heldBaseOf(self: *const SemContext, node: Sexp) ?Sexp {
        const fact = self.facts.headers.get(nodeKey(node) orelse return null) orelse return null;
        return if (fact.how == .held) fact.base else null;
    }

    /// Forget the use recorded for `node`: typecheck records a held base
    /// as taken while it checks the header, and gives it back to an
    /// ordinary read when the header holds nothing after all.
    pub fn forgetUse(self: *SemContext, node: Sexp) void {
        _ = self.facts.uses.remove(exprKey(node) orelse return);
    }

    /// Whether `match` takes its subject, a value made there, as
    /// `match <e` would (`Header.taken`).
    pub fn takesSubject(self: *const SemContext, match: Sexp) bool {
        return self.headerOf(match) == .taken;
    }

    pub fn recordTextCall(self: *SemContext, call: Sexp, op: TextCall) !void {
        try self.facts.text_calls.put(self.allocator, recordKey(call), op);
    }

    /// The built-in Text operation a `Text(...)` call or a method's
    /// callee (`member`) is.
    pub fn textCallOf(self: *const SemContext, node: Sexp) ?TextCall {
        return self.facts.text_calls.get(nodeKey(node) orelse return null);
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
    /// (`expandInstantiations`, which gives the instance written at
    /// `site` that it is made `via`). Whether it was new.
    pub fn recordFnInstance(self: *SemContext, inst: FnInstance, site: u32, via: ?InstanceRoot) !bool {
        if (self.fn_instance_set.contains(inst)) return false;
        const owned = try self.ownFnInstance(inst);
        try self.fn_instance_set.put(self.allocator, owned, {});
        for (inst.args) |a| if (self.typeInfo(a).has_type_var) {
            try self.addGeneric(.fn_uses, owned);
            return true;
        };
        try self.fn_instances.append(self.allocator, .{ .inst = owned, .site = site, .via = via });
        return true;
    }

    /// Add `entry` to `list`, indexed by the type and integer parameters
    /// it mentions; a use already in `generic_uses` is not added again.
    pub fn addGeneric(self: *SemContext, comptime list: GenericList, entry: @typeInfo(@FieldType(@FieldType(SemContext, "generic_" ++ @tagName(list)), "items")).pointer.child) !void {
        const items = &@field(self, "generic_" ++ @tagName(list));
        if (list == .uses and std.mem.findScalar(TypeId, items.items, entry) != null) return;
        const at: u32 = @intCast(items.items.len);
        switch (list) {
            .uses => try self.indexParams(list, at, entry),
            .arrays => try self.indexParams(list, at, entry.ty),
            .fn_uses => for (entry.args) |ty| try self.indexParams(list, at, ty),
            .frames => for (entry.tys) |ty| try self.indexParams(list, at, ty),
        }
        try items.append(self.allocator, entry);
    }

    /// Index entry `at` of `list` under each parameter `ty` mentions.
    fn indexParams(self: *SemContext, list: GenericList, at: u32, ty: TypeId) !void {
        if (!self.typeInfo(ty).has_type_var) return;
        switch (self.types.get(ty)) {
            .type_var, .ct_param => |sym| {
                const gop = try self.generic_index.getOrPut(self.allocator, .{ .list = list, .param = sym });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                const entries = gop.value_ptr;
                if (entries.items.len == 0 or entries.getLast() != at) try entries.append(self.allocator, at);
                return;
            },
            else => {},
        }
        var it = typeChildren(self, ty);
        while (it.next()) |c| try self.indexParams(list, at, c);
    }

    /// The positions of the entries of `list` that mention `param`, in order.
    pub fn paramEntries(self: *const SemContext, list: GenericList, param: SymbolId) []const u32 {
        const entries = self.generic_index.getPtr(.{ .list = list, .param = param }) orelse return &.{};
        return entries.items;
    }

    /// Set `out` to the positions of the entries of `list` that mention
    /// any of `params`, in order.
    pub fn genericEntries(self: *const SemContext, list: GenericList, params: []const SymbolId, out: *std.ArrayList(u32)) !void {
        out.clearRetainingCapacity();
        for (params) |p| try out.appendSlice(self.allocator, self.paramEntries(list, p));
        if (params.len < 2) return;
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (out.items) |i| if (n == 0 or out.items[n - 1] != i) {
            out.items[n] = i;
            n += 1;
        };
        out.shrinkRetainingCapacity(n);
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
                f.ct_syms = try self.arena.allocator().dupe(SymbolId, f.ct_syms);
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
    /// The module's emitted file.
    zig_file: []const u8 = "",
    /// A module of the standard library.
    is_std: bool = false,
};

/// The end of a diagnostic for a name a standard library module does
/// not declare, when what it does declare goes by another name: `Rng` in
/// `std.random`, whose generator is `Random`. Empty for any other name.
pub fn stdNameHint(foreign: *const SemContext, name: []const u8) []const u8 {
    if (foreign.is_std and std.mem.eql(u8, foreign.name, "std.random") and std.mem.eql(u8, name, "Rng")) return "; its generator is `Random`";
    return "";
}

/// Report that `module.name`, a declaration of the imported module
/// `foreign`, is not public: a module of the program can mark it `pub`;
/// the standard library's is not the program's to change.
pub fn notPublic(ctx: *SemContext, pos: u32, module: []const u8, name: []const u8, foreign: *const SemContext) std.mem.Allocator.Error!void {
    if (foreign.is_std) return ctx.err(pos, "`{s}.{s}` is private to the standard library's module `{s}`", .{ module, name, foreign.name });
    try ctx.err(pos, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ module, name, module });
}

/// Check one module.
pub fn check(allocator: std.mem.Allocator, source: []const u8, tree: Sexp, opts: CheckOptions) !SemContext {
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    ctx.parser = opts.parser;
    ctx.module_id = opts.module_id;
    ctx.is_root = opts.is_root;
    ctx.name = opts.name;
    ctx.zig_file = opts.zig_file;
    ctx.is_std = opts.is_std;
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
    const order = try computeContents(&ctx);
    try checkInfiniteTypes(&ctx);
    try checkTypeSizes(&ctx, order);
    try computeOrigins(&ctx);
    try resolve.checkDeclarations(&ctx);
    try typecheck.checkModule(&ctx, tree, module_scope);
    try typecheck.checkFrames(&ctx, tree);
    try checkUnreadLocals(&ctx);
    try expandInstantiations(&ctx);
    try typecheck.checkGenericInstantiations(&ctx);
    try storage.plan(&ctx, tree);
    return ctx;
}

/// A local binding must be read: a name that is only ever assigned is
/// most often a typo for another. Any use other than being assigned is a
/// read, and so is a closure capturing it. A value with drop glue is
/// read by its own release (a guard held to the end of its scope), and
/// `_` names nothing. Parameters and module constants are exempt.
fn checkUnreadLocals(ctx: *SemContext) std.mem.Allocator.Error!void {
    var read: std.bit_set.Dynamic = try .initEmpty(ctx.allocator, ctx.symbols.items.len);
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
        // A value that moves may be bound only to be dropped or moved
        // at the scope's end.
        if (moves(ctx, sym.ty) != .no) continue;
        if (sym.flags.pattern_bound) {
            try ctx.lintErr(sym.decl_pos, "`{s}` is bound but never read; name it `_` to ignore the value", .{sym.name});
        } else {
            try ctx.lintErr(sym.decl_pos, "`{s}` is assigned but never read; use it, or discard the value with `_ = ...`", .{sym.name});
        }
    }
}

/// Add the instances a program reaches through generic bodies: when
/// `Wrap[*B]` is spelled and `Wrap[T]`'s methods use `Opt[T]`, `Opt[*B]` is
/// instantiated too, at the same site, and so is `max[*B]` when they
/// call `max[T]`; each instance of a generic function does the same for
/// its body. The requirement checks then see every instantiation, and a
/// built-in generic reached this way (`Vec[T]` in `Stack[T]`) has its
/// element rules checked for the argument. Then the public generics are
/// checked for nesting themselves (`checkSelfNesting`).
fn expandInstantiations(ctx: *SemContext) std.mem.Allocator.Error!void {
    if (ctx.generic_uses.items.len == 0 and ctx.generic_fn_uses.items.len == 0) return;
    var work: std.ArrayList(ExpandItem) = .empty;
    defer work.deinit(ctx.allocator);
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |e| {
        const item = typeItem(ctx, e.key_ptr.*) orelse continue;
        try work.append(ctx.allocator, .{ .subst = item, .site = e.value_ptr.*, .root = .{ .type = e.key_ptr.* } });
    }
    for (ctx.fn_instances.items) |f| try work.append(ctx.allocator, .{ .subst = f.inst.subst(), .site = f.site, .root = .{ .func = f.inst } });
    if (try expand(ctx, &work, null)) return;
    try checkSelfNesting(ctx);
}

/// An instance to expand: its parameters' arguments, where the program
/// makes it, and the instance written there that it is reached from.
const ExpandItem = struct { subst: TypeSubst, site: u32, root: InstanceRoot };

/// The instances an expansion over type parameters has reached
/// (`checkSelfNesting`), which the program does not make.
const Reached = struct {
    fns: std.HashMapUnmanaged(FnInstance, void, FnInstance.Context, std.hash_map.default_max_load_percentage) = .empty,
    types: std.AutoHashMapUnmanaged(TypeId, void) = .empty,

    fn deinit(self: *Reached, a: std.mem.Allocator) void {
        self.fns.deinit(a);
        self.types.deinit(a);
    }
};

/// Expand `work` until nothing new appears: each use a generic body
/// makes of its parameters, made at the arguments of an instance of that
/// body, is an instance too. The program's instances are recorded
/// (`recordFnInstance`, `instantiation_sites`), and those still over
/// type parameters skipped; with `reached`, those over type parameters
/// are followed too and kept there. Whether an instance nesting ever
/// deeper was reported.
fn expand(ctx: *SemContext, work: *std.ArrayList(ExpandItem), reached: ?*Reached) std.mem.Allocator.Error!bool {
    var entries: std.ArrayList(u32) = .empty;
    defer entries.deinit(ctx.allocator);
    while (work.pop()) |item| {
        try ctx.genericEntries(.fn_uses, item.subst.params, &entries);
        for (entries.items) |i| {
            const use = ctx.generic_fn_uses.items[i];
            // A use over parameters this instance does not bind (a
            // generic method's own `U`, reached from its type's instance)
            // is made by the instances that bind them, as it is above.
            if (reached != null and !argsUseOnlyParams(ctx, use.args, item.subst.params)) continue;
            const args = try ctx.arena.allocator().alloc(TypeId, use.args.len);
            var deepest: u8 = 0;
            for (use.args, args) |a, *out| {
                out.* = try substituteType(ctx, a, item.subst);
                deepest = @max(deepest, ctx.typeInfo(out.*).depth);
            }
            if (reached == null and argsHaveTypeVar(ctx, args)) continue;
            // A generic function that calls itself with its parameters
            // nested deeper (`f[Wrap[T]]` in `f[T]`), or a generic type
            // whose methods do so with its own instances, would expand
            // forever.
            if (deepest > max_instance_depth) {
                const why = if (item.root == .func) "a generic function cannot call itself with its own type parameters nested deeper" else "a generic type's body cannot nest itself in its own type arguments";
                try ctx.err(item.site, "`{s}` leads to ever deeper instances of generic functions (through `{s}`); {s}", .{ try rootName(ctx, item.root), try formatFnInstance(ctx, use), why });
                return true;
            }
            // An instance at a renaming of the callee's parameters expands
            // as the callee at its own does, which is kept once.
            if (reached != null and isRenaming(ctx, args)) try ownParamArgs(ctx, use.params, args);
            const concrete: FnInstance = .{ .name = use.name, .params = use.params, .args = args, .own = use.own };
            if (reached) |r| {
                if ((try r.fns.getOrPut(ctx.allocator, concrete)).found_existing) continue;
            } else if (!try ctx.recordFnInstance(concrete, item.site, item.root)) continue;
            try work.append(ctx.allocator, .{ .subst = concrete.subst(), .site = item.site, .root = item.root });
        }
        try ctx.genericEntries(.uses, item.subst.params, &entries);
        for (entries.items) |i| {
            const use = ctx.generic_uses.items[i];
            if (reached != null and !usesOnlyParams(ctx, use, item.subst.params)) continue;
            var concrete = try substituteType(ctx, use, item.subst);
            if (reached != null) if (typeItem(ctx, concrete)) |t| if (isRenaming(ctx, t.args)) {
                const args = try ctx.arena.allocator().alloc(TypeId, t.args.len);
                try ownParamArgs(ctx, t.params, args);
                concrete = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.types.get(concrete).parameterized_nominal.sym, .args = args } });
            };
            const info = ctx.typeInfo(concrete);
            if (reached == null and info.has_type_var) continue;
            // A generic whose body uses ever-deeper instances of itself
            // (`Wrap[T]` using `Wrap[Wrap[T]]`) would expand forever.
            if (info.depth > max_instance_depth) {
                try ctx.err(item.site, "`{s}` leads to ever deeper instances of generic types (through `{s}`); a generic type's body cannot nest itself in its own type arguments", .{ try rootName(ctx, item.root), try formatType(ctx, use) });
                return true;
            }
            const inst = switch (ctx.types.get(concrete)) {
                .parameterized_nominal => |pn| pn,
                else => continue,
            };
            const builtin = ctx.symbols.items[inst.sym].decl_pos == builtin_decl_pos;
            if (reached) |r| {
                if (builtin or (try r.types.getOrPut(ctx.allocator, concrete)).found_existing) continue;
            } else {
                const gop = try ctx.instantiation_sites.getOrPut(ctx.allocator, concrete);
                if (gop.found_existing) continue;
                gop.value_ptr.* = item.site;
                if (builtin) {
                    if (try resolve.builtinElementError(ctx, inst.sym, inst.args)) |msg| {
                        try ctx.err(item.site, "`{s}` instantiates `{s}`: {s}", .{ try rootName(ctx, item.root), try formatType(ctx, concrete), msg });
                    }
                    continue;
                }
            }
            try work.append(ctx.allocator, .{ .subst = typeItem(ctx, concrete).?, .site = item.site, .root = item.root });
        }
    }
    return false;
}

/// A public generic function or type, or a generic method of a public
/// type, whose body nests itself ever deeper (`f[Wrap[T]]` in `f[T]`)
/// fails in every instance, which other modules make: each is expanded
/// over its own parameters, as an instance would be, and such a one is
/// reported where it is declared.
fn checkSelfNesting(ctx: *SemContext) std.mem.Allocator.Error!void {
    var reached: Reached = .{};
    defer reached.deinit(ctx.allocator);
    var work: std.ArrayList(ExpandItem) = .empty;
    defer work.deinit(ctx.allocator);
    for (0..ctx.symbols.items.len) |i| {
        const sym = ctx.symbols.items[i];
        // A proxy's declaration was checked where it is declared.
        if (!sym.flags.is_public or isProxy(sym)) continue;
        const outer: []const SymbolId = switch (sym.kind) {
            .function => {
                if (try selfSeed(ctx, sym.name, &.{}, sym.ty, sym.decl_pos)) |item| try work.append(ctx.allocator, item);
                continue;
            },
            .generic_type => sym.type_params orelse &.{},
            .nominal_type => &.{},
            else => continue,
        };
        if (sym.kind == .generic_type) {
            const self_ty = (try makeNominalContext(ctx, @intCast(i))).self_type;
            if (typeItem(ctx, self_ty)) |subst| try work.append(ctx.allocator, .{ .subst = subst, .site = sym.decl_pos, .root = .{ .type = self_ty } });
        }
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_method) continue;
            if (try selfSeed(ctx, f.name, outer, f.ty, f.decl_pos)) |item| try work.append(ctx.allocator, item);
        }
    }
    // Each is expanded once, as itself, so a nesting is reported at the
    // declaration that nests rather than at one that calls it.
    for (work.items) |item| switch (item.root) {
        .func => |f| try reached.fns.put(ctx.allocator, f, {}),
        .type => |t| try reached.types.put(ctx.allocator, t, {}),
    };
    _ = try expand(ctx, &work, &reached);
}

/// The instance of generic function `name` (of type `ty`, a method of a
/// generic type with parameters `outer`) at its own parameters, declared
/// at `pos`; null for a function without type or integer parameters.
fn selfSeed(ctx: *SemContext, name: []const u8, outer: []const SymbolId, ty: TypeId, pos: u32) std.mem.Allocator.Error!?ExpandItem {
    const f = switch (ctx.types.get(ty)) {
        .function => |f| f,
        else => return null,
    };
    const a = ctx.arena.allocator();
    var params: std.ArrayList(SymbolId) = .empty;
    try params.appendSlice(a, outer);
    for (f.ct_syms, 0..) |p, i| {
        if (p == symbol_invalid or i >= f.ct_params.len) continue;
        switch (ctx.types.get(f.ct_params[i])) {
            .type_var, .int => try params.append(a, p),
            else => {},
        }
    }
    const own = params.items.len - outer.len;
    if (own == 0) return null;
    const args = try a.alloc(TypeId, params.items.len);
    try ownParamArgs(ctx, params.items, args);
    const inst: FnInstance = .{ .name = name, .params = params.items, .args = args, .own = @intCast(own) };
    return .{ .subst = inst.subst(), .site = pos, .root = .{ .func = inst } };
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

/// Whether `args` are distinct type or integer parameters: an instance at
/// them is its generic at its own parameters, renamed.
fn isRenaming(ctx: *const SemContext, args: []const TypeId) bool {
    for (args, 0..) |a, i| {
        switch (ctx.types.get(a)) {
            .type_var, .ct_param => {},
            else => return false,
        }
        if (std.mem.findScalar(TypeId, args[0..i], a) != null) return false;
    }
    return true;
}

/// Set `args` to `params` themselves.
fn ownParamArgs(ctx: *SemContext, params: []const SymbolId, args: []TypeId) std.mem.Allocator.Error!void {
    for (params, args) |p, *arg| arg.* = try ctx.intern(if (ctx.symbols.items[p].kind == .param) .{ .ct_param = p } else .{ .type_var = p });
}

/// Whether every type or integer parameter `ty` mentions is one of `params`.
fn usesOnlyParams(ctx: *const SemContext, ty: TypeId, params: []const SymbolId) bool {
    if (!ctx.typeInfo(ty).has_type_var) return true;
    switch (ctx.types.get(ty)) {
        .type_var, .ct_param => |sym| return std.mem.findScalar(SymbolId, params, sym) != null,
        else => {},
    }
    var it = typeChildren(ctx, ty);
    while (it.next()) |c| if (!usesOnlyParams(ctx, c, params)) return false;
    return true;
}

fn argsUseOnlyParams(ctx: *const SemContext, args: []const TypeId, params: []const SymbolId) bool {
    for (args) |a| if (!usesOnlyParams(ctx, a, params)) return false;
    return true;
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
    return a.print("{s}[{s}]", .{ inst.name, try formatTypeList(ctx, a, inst.ownArgs()) });
}

const max_instance_depth = 24;

/// Whether `ty` mentions any of `params`.
pub fn usesParams(ctx: *const SemContext, ty: TypeId, params: []const SymbolId) bool {
    if (!ctx.typeInfo(ty).has_type_var) return false;
    switch (ctx.types.get(ty)) {
        .type_var, .ct_param => |sym| return std.mem.findScalar(SymbolId, params, sym) != null,
        else => {},
    }
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
    /// `glue`, `plain`, and `held` are computed (`symbolContents`).
    done: bool = false,
    /// Needs its destructor run whatever its type arguments: a user
    /// `drop`, or a field that owns a resource.
    glue: bool = false,
    /// Holds a `Cell` inline, directly or through any argument of a
    /// generic instance it holds.
    cell: bool = false,
    /// Is declared `unique`, or holds such a type inline, as `cell`
    /// reaches (`Reach`).
    unique: bool = false,
    /// Owns nothing and holds no marked view. A type parameter held by value
    /// counts as plain here; each instance checks its arguments.
    plain: bool = false,
    /// A generic type: which of its parameters it holds by value.
    held: []const bool = &.{},
    /// Holds a view, or a write view (see `Views`).
    views: Views = .{},
    /// Holds itself by value, which `checkInfiniteTypes` reports: it has
    /// no size.
    cyclic: bool = false,
};

/// Whether values hold a marked view (`?T`, `!T`, a slice), whether they
/// hold a write view (`!T`), and whether they hold a String, which may
/// view a Text, directly or through an optional, array, field, variant
/// payload, shared or weak handle, or any argument of a generic
/// instance. What a Cell or Signal holds holds no view. A String is no
/// marked view to the type rules (`holdsMarkedView`); the ownership checker
/// follows the loans its values carry (`mayHoldView`).
pub const Views = packed struct(u4) {
    marked: bool = false,
    write: bool = false,
    string: bool = false,
    /// Reaches a Text, which a String may view: by value, through a
    /// handle, a Vec's, Box's, Cell's, or Signal's value, or a view.
    text: bool = false,
};

/// Facts about an interned type, recorded when it is interned
/// (`SemContext.intern`). The structural facts are always known; the
/// rest once declarations are resolved (`SemContext.contents_ready`).
pub const TypeInfo = packed struct(u19) {
    /// Mentions a generic parameter anywhere.
    has_type_var: bool = false,
    /// Holds a generic parameter by value, so whether it owns a resource
    /// depends on the instantiation.
    holds_type_var: bool = false,
    /// Needs its destructor run (see `typeHasDropGlue`).
    glue: bool = false,
    /// Holds a `Cell` inline (see `holdsCellByValue`).
    cell: bool = false,
    /// Is or holds inline a type declared `unique` (see `isUnique`).
    unique: bool = false,
    /// Holds no resource, marked view, or generic parameter. A struct with a
    /// user `drop` can be plain and still have glue (see `isPlainData`).
    plain: bool = false,
    /// Holds a view, or a write view (see `Views`).
    views: Views = .{},
    /// Is or mentions `invalid` or `unknown`: a diagnostic was reported.
    poison: bool = false,
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
/// they are interned. Each declared type is computed after those it
/// holds, in the order returned, so no walk nests through the chain of
/// types a value holds.
fn computeContents(ctx: *SemContext) std.mem.Allocator.Error![]const SymbolId {
    var c = try Components.run(ctx, true);
    defer c.deinit();
    for (c.order.items) |id| try symbolContents(ctx, id);
    try computeReach(ctx);
    ctx.contents_ready = true;
    ctx.type_info.clearRetainingCapacity();
    try ctx.syncTypeInfo();
    return ctx.arena.allocator().dupe(SymbolId, c.order.items);
}

fn symbolContents(ctx: *SemContext, id: SymbolId) std.mem.Allocator.Error!void {
    if (ctx.symbols.items[id].contents.done) return;
    const params = ctx.symbols.items[id].type_params orelse &.{};
    const held = try ctx.arena.allocator().alloc(bool, params.len);
    @memset(held, false);
    var c: Contents = .{ .done = true, .plain = true, .held = held };
    for (ctx.symbols.items[id].fields orelse &.{}) |*f| {
        if (f.is_drop_method) c.glue = true;
        for (dataFields(f)) |d| {
            const h = try holdsIn(ctx, d.ty, params, held);
            c.glue = c.glue or h.glue;
            c.plain = c.plain and h.plain;
        }
    }
    // The built-in generics are runtime types: a Vec owns its buffer and
    // a Box its value's memory, and none of them is copied like plain data.
    // A Signal owns its subscribers too, but has no glue of its own: it
    // lives only behind a `*` handle (typecheck rejects one held by
    // value), whose release drops it.
    if (id == ctx.vec_sym_id or id == ctx.box_sym_id) c.glue = true;
    if (id == ctx.vec_sym_id or id == ctx.box_sym_id or id == ctx.cell_sym_id or id == ctx.signal_sym_id) c.plain = false;
    // A unique value is never copied, so it is not plain data.
    if (ctx.symbols.items[id].flags.unique) c.plain = false;
    ctx.symbols.items[id].contents = c;
}

/// What the values of a declared type hold, once computed. A type not
/// computed yet holds itself by value (`computeContents` computes each
/// after those it holds), which `checkInfiniteTypes` reports.
fn contentsOf(ctx: *const SemContext, id: SymbolId) Contents {
    const c = ctx.symbols.items[id].contents;
    return if (c.done) c else .{};
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
        .bool, .int, .float, .string, .any_error, .ct_value, .ct_param => .{ .plain = true },
        .text => .{ .glue = true },
        .optional => |inner| holdsIn(ctx, inner, params, held),
        .array => |a| holdsIn(ctx, a.elem, params, held),
        .fallible => |inner| .{ .type_var = (try holdsIn(ctx, inner, params, held)).type_var },
        .shared, .weak => .{ .glue = true },
        .nominal, .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk .{};
            const c = contentsOf(decl.ctx, decl.sym);
            break :blk .{ .glue = c.glue, .plain = c.plain };
        },
        .type_var => |sym| blk: {
            const i = std.mem.findScalar(SymbolId, params, sym) orelse break :blk .{ .type_var = true };
            held[i] = true;
            break :blk .{ .plain = true, .type_var = true };
        },
        .parameterized_nominal => |pn| blk: {
            const c = contentsOf(ctx, pn.sym);
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

/// What a value holds, of what it can hold through the declared types it
/// holds: a `Cell` inline, a unique type inline, a view, and a write
/// view.
const Reach = packed struct(u6) {
    cell: bool = false,
    unique: bool = false,
    views: Views = .{},

    const all: Reach = .{ .cell = true, .unique = true, .views = .{ .marked = true, .write = true, .string = true, .text = true } };
    /// What reaches through a handle or heap memory: no Cell or unique
    /// value is inline.
    const views_only: Reach = .{ .views = .{ .marked = true, .write = true, .string = true, .text = true } };
    /// What reaches through a view, or into a Cell's or Signal's value:
    /// only a Text matters.
    const text_only: Reach = .{ .views = .{ .text = true } };

    fn with(a: Reach, b: Reach) Reach {
        return @bitCast(@as(u6, @bitCast(a)) | @as(u6, @bitCast(b)));
    }

    fn within(a: Reach, mask: Reach) Reach {
        return @bitCast(@as(u6, @bitCast(a)) & @as(u6, @bitCast(mask)));
    }

    fn of(c: Contents) Reach {
        return .{ .cell = c.cell, .unique = c.unique, .views = c.views };
    }
};

/// `to` holds what `from` holds, as far as `mask` lets it reach.
const ReachEdge = struct {
    from: SymbolId,
    to: SymbolId,
    mask: Reach,

    fn lessThan(_: void, a: ReachEdge, b: ReachEdge) bool {
        return a.from < b.from;
    }

    fn before(from: SymbolId, e: ReachEdge) bool {
        return e.from < from;
    }
};

/// What each declared type's values hold (`Reach`): a type declared
/// `unique` is unique, and a type holds what the declared types it
/// holds do, a view even through a handle, and what any argument of a
/// generic instance it holds does (as the emitter reads type
/// expressions). Found by propagating backwards from the types that
/// hold something directly, so each field type is walked once.
fn computeReach(ctx: *SemContext) std.mem.Allocator.Error!void {
    var edges: std.ArrayList(ReachEdge) = .empty;
    defer edges.deinit(ctx.allocator);
    var work: std.ArrayList(SymbolId) = .empty;
    defer work.deinit(ctx.allocator);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (!isTypeDecl(sym)) continue;
        const id: SymbolId = @intCast(i);
        // A proxy's contents are its declaration's.
        var r: Reach = if (isProxy(sym)) Reach.of(sym.contents) else .{ .unique = sym.flags.unique };
        if (!isProxy(sym)) for (sym.fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| r = r.with(try reachOf(ctx, d.ty, .all, .{ .edges = &edges, .owner = id }));
        };
        ctx.symbols.items[id].contents.cell = r.cell;
        ctx.symbols.items[id].contents.unique = r.unique;
        ctx.symbols.items[id].contents.views = r.views;
        if (r != Reach{}) try work.append(ctx.allocator, id);
    }
    std.mem.sort(ReachEdge, edges.items, {}, ReachEdge.lessThan);
    while (work.pop()) |from| {
        const r = Reach.of(ctx.symbols.items[from].contents);
        var i = std.sort.partitionPoint(ReachEdge, edges.items, from, ReachEdge.before);
        while (i < edges.items.len and edges.items[i].from == from) : (i += 1) {
            const to = &ctx.symbols.items[edges.items[i].to].contents;
            const now = Reach.of(to.*).with(r.within(edges.items[i].mask));
            if (now == Reach.of(to.*)) continue;
            to.cell = now.cell;
            to.unique = now.unique;
            to.views = now.views;
            try work.append(ctx.allocator, edges.items[i].to);
        }
    }
}

/// What a value of `ty` holds (`Reach`), as far as `mask` lets it
/// reach: through a handle, or a Vec's or a Box's heap memory, only a
/// view does, and a Cell's or Signal's value holds nothing that
/// matters here. What a declared type `ty` names holds is read from its
/// contents; while they are computed (`computeReach`), an edge from it
/// to `into.owner` is added instead.
fn reachOf(ctx: *const SemContext, ty: TypeId, mask: Reach, into: ?struct { edges: *std.ArrayList(ReachEdge), owner: SymbolId }) std.mem.Allocator.Error!Reach {
    const r: Reach = switch (ctx.types.get(ty)) {
        .slice => .{ .views = .{ .marked = true } },
        .read_view => |inner| (Reach{ .views = .{ .marked = true } }).with(try reachOf(ctx, inner, mask.within(Reach.text_only), into)),
        .write_view => |inner| (Reach{ .views = .{ .marked = true, .write = true } }).with(try reachOf(ctx, inner, mask.within(Reach.text_only), into)),
        .string => .{ .views = .{ .string = true } },
        .text => .{ .views = .{ .text = true } },
        .optional, .fallible => |inner| return reachOf(ctx, inner, mask, into),
        .array => |a| return reachOf(ctx, a.elem, mask, into),
        .shared, .weak => |inner| return reachOf(ctx, inner, mask.within(Reach.views_only), into),
        .nominal => |sym| blk: {
            const e = into orelse break :blk Reach.of(ctx.symbols.items[sym].contents);
            try e.edges.append(ctx.allocator, .{ .from = sym, .to = e.owner, .mask = mask });
            break :blk .{};
        },
        .imported_nominal => Reach.of((nominalDecl(ctx, ty) orelse return .{}).symbol().contents),
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) {
                var r: Reach = .{ .cell = pn.sym == ctx.cell_sym_id };
                for (pn.args) |a| r = r.with(try reachOf(ctx, a, mask.within(Reach.text_only), into));
                break :blk r;
            }
            const m = if (isHeapBuiltin(ctx, pn.sym)) mask.within(Reach.views_only) else mask;
            var r: Reach = .{};
            if (into) |e| {
                try e.edges.append(ctx.allocator, .{ .from = pn.sym, .to = e.owner, .mask = m });
            } else r = Reach.of(ctx.symbols.items[pn.sym].contents);
            for (pn.args) |a| r = r.with(try reachOf(ctx, a, m, into));
            break :blk r;
        },
        else => .{},
    };
    return r.within(mask);
}

/// The facts of a type, from those of the types it is built from, which
/// were interned before it.
fn computeTypeInfo(ctx: *SemContext, id: TypeId) std.mem.Allocator.Error!TypeInfo {
    const ty = ctx.types.get(id);
    var info: TypeInfo = .{ .has_type_var = ty == .type_var or ty == .ct_param, .poison = ty == .invalid or ty == .unknown };
    var deepest: ?u8 = null;
    var it: TypeChildren = .{ .ty = ty };
    while (it.next()) |c| {
        const ci = ctx.type_info.items[c];
        info.has_type_var = info.has_type_var or ci.has_type_var;
        info.poison = info.poison or ci.poison;
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
    const r = try reachOf(ctx, id, .all, null);
    info.cell = r.cell;
    info.unique = r.unique;
    info.views = r.views;
    return info;
}

/// A struct or enum may not hold itself by value, directly or through
/// the types it holds by value: it would have no finite size. One search
/// of the by-value graph over the declared types finds every cycle.
fn checkInfiniteTypes(ctx: *SemContext) std.mem.Allocator.Error!void {
    var c = try Components.run(ctx, false);
    defer c.deinit();
    var targets: std.ArrayList(SymbolId) = .empty;
    defer targets.deinit(ctx.allocator);
    for (ctx.symbols.items, 0..) |sym, i| {
        if (!c.cyclic[i]) continue;
        ctx.symbols.items[i].contents.cyclic = true;
        if (sym.decl_pos >= imported_decl_pos) continue;
        const f = fields: for (sym.fields orelse &.{}) |*f| {
            targets.clearRetainingCapacity();
            for (dataFields(f)) |d| try byValueTargets(ctx, d.ty, &targets, false);
            // `low` names the component after the search.
            for (targets.items) |t| if (c.low[t] == c.low[i]) break :fields f;
        } else continue;
        const shown = if (sym.kind == .generic_type) try ctx.arena.allocator().print("{s}[...]", .{sym.name}) else sym.name;
        try ctx.err(f.decl_pos, "`{s}` contains itself by value through `{s}`, so it would have no finite size; hold it through a shared handle (`*{s}`)", .{ shown, f.name, shown });
    }
}

/// The strongly connected components of the graph of declared types, an
/// edge going from a type to each one it holds by value (Tarjan's
/// algorithm, with an explicit stack, so a long chain of types does not
/// nest the search). Before what each type holds is known
/// (`every_arg`), a generic instance counts as holding all its
/// arguments, and a Vec or a Box its element.
const Components = struct {
    ctx: *const SemContext,
    every_arg: bool,
    next: u32 = 1,
    /// Visit order (0: not visited yet).
    index: []u32,
    /// The lowest index reachable; once a component is complete, the
    /// index of its root, shared by all its members.
    low: []u32,
    on_stack: []bool,
    /// In a component with a cycle.
    cyclic: []bool,
    /// The types in completed components, each component after every
    /// one its members hold by value.
    order: std.ArrayList(SymbolId) = .empty,
    stack: std.ArrayList(SymbolId) = .empty,
    /// The types being visited, innermost last, each with its range of
    /// `targets` and the next one to follow.
    visiting: std.ArrayList(struct { v: SymbolId, start: u32, next: u32, end: u32 }) = .empty,
    targets: std.ArrayList(SymbolId) = .empty,

    fn run(ctx: *const SemContext, every_arg: bool) std.mem.Allocator.Error!Components {
        const n = ctx.symbols.items.len;
        const a = ctx.allocator;
        var self: Components = .{
            .ctx = ctx,
            .every_arg = every_arg,
            .index = try a.alloc(u32, n),
            .low = try a.alloc(u32, n),
            .on_stack = try a.alloc(bool, n),
            .cyclic = try a.alloc(bool, n),
        };
        errdefer self.deinit();
        @memset(self.index, 0);
        @memset(self.on_stack, false);
        @memset(self.cyclic, false);
        for (ctx.symbols.items, 0..) |sym, i| {
            if (isTypeDecl(sym) and self.index[i] == 0) try self.visit(@intCast(i));
        }
        return self;
    }

    fn deinit(self: *Components) void {
        const a = self.ctx.allocator;
        a.free(self.index);
        a.free(self.low);
        a.free(self.on_stack);
        a.free(self.cyclic);
        self.order.deinit(a);
        self.stack.deinit(a);
        self.visiting.deinit(a);
        self.targets.deinit(a);
    }

    fn visit(self: *Components, root: SymbolId) std.mem.Allocator.Error!void {
        try self.enter(root);
        while (self.visiting.items.len > 0) {
            const top = &self.visiting.items[self.visiting.items.len - 1];
            const v = top.v;
            if (top.next < top.end) {
                const w = self.targets.items[top.next];
                top.next += 1;
                if (w == v) self.cyclic[v] = true;
                if (self.index[w] == 0) {
                    try self.enter(w);
                } else if (self.on_stack[w]) self.low[v] = @min(self.low[v], self.index[w]);
                continue;
            }
            self.targets.shrinkRetainingCapacity(top.start);
            _ = self.visiting.pop();
            if (self.visiting.items.len > 0) {
                const parent = self.visiting.items[self.visiting.items.len - 1].v;
                self.low[parent] = @min(self.low[parent], self.low[v]);
            }
            if (self.low[v] != self.index[v]) continue;
            const start = std.mem.findScalarLast(SymbolId, self.stack.items, v).?;
            const members = self.stack.items[start..];
            for (members) |m| {
                self.on_stack[m] = false;
                self.low[m] = self.index[v];
                if (members.len > 1) self.cyclic[m] = true;
            }
            try self.order.appendSlice(self.ctx.allocator, members);
            self.stack.shrinkRetainingCapacity(start);
        }
    }

    fn enter(self: *Components, v: SymbolId) std.mem.Allocator.Error!void {
        const a = self.ctx.allocator;
        self.index[v] = self.next;
        self.low[v] = self.next;
        self.next += 1;
        try self.stack.append(a, v);
        self.on_stack[v] = true;
        const start: u32 = @intCast(self.targets.items.len);
        for (self.ctx.symbols.items[v].fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| try byValueTargets(self.ctx, d.ty, &self.targets, self.every_arg);
        }
        try self.visiting.append(a, .{ .v = v, .start = start, .next = start, .end = @intCast(self.targets.items.len) });
    }
};

/// `Void` or `Void!`: what a `sub` returns.
pub fn returnsNothing(ctx: *const SemContext, ret: TypeId) bool {
    if (ret == ctx.types.void_id) return true;
    return switch (ctx.types.get(ret)) {
        .fallible => |inner| inner == ctx.types.void_id,
        else => false,
    };
}

/// A built-in function called by name unless a declaration hides it:
/// `print`, `replace`, `swap`.
pub fn isBuiltinCallName(name: []const u8) bool {
    return std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "replace") or std.mem.eql(u8, name, "swap");
}

/// A built-in generic that keeps its values on the heap: a `Vec[T]` and
/// a `Box[T]` hold a pointer, whatever `T` is. (A `Cell[T]` holds its
/// `T` inline, and a `Signal[T]` its value and a pending one.)
fn isHeapBuiltin(ctx: *const SemContext, sym: SymbolId) bool {
    return sym == ctx.vec_sym_id or sym == ctx.box_sym_id;
}

/// The declared types a value of `ty` holds inline (not behind a handle,
/// a view, or a Vec's or a Box's heap memory), appended to `out`; with
/// `every_arg`, those of every argument of a generic instance as well.
fn byValueTargets(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), every_arg: bool) std.mem.Allocator.Error!void {
    switch (ctx.types.get(ty)) {
        .optional, .fallible => |inner| try byValueTargets(ctx, inner, out, every_arg),
        .array => |a| try byValueTargets(ctx, a.elem, out, every_arg),
        .nominal => |s| try out.append(ctx.allocator, s),
        .parameterized_nominal => |pn| {
            if (!every_arg and isHeapBuiltin(ctx, pn.sym)) return;
            try out.append(ctx.allocator, pn.sym);
            const held = ctx.symbols.items[pn.sym].contents.held;
            for (pn.args, 0..) |arg, i| {
                if (every_arg or (i < held.len and held[i])) try byValueTargets(ctx, arg, out, every_arg);
            }
        },
        else => {},
    }
}

// =============================================================================
// Type queries
// =============================================================================

pub const builtin_decl_pos: u32 = std.math.maxInt(u32);
/// The `decl_pos` of a proxy (`proxyOf`): declared in another module's
/// source, so at no position of this one.
pub const imported_decl_pos: u32 = std.math.maxInt(u32) - 1;

/// Where the declaration proxy `sym` stands for is: a position in
/// another module's source.
pub fn proxyOrigin(ctx: *const SemContext, sym: Symbol) ?struct { module_id: u32, pos: u32 } {
    const foreign = ctx.foreign_semas.get(sym.from.module_id) orelse return null;
    return .{ .module_id = sym.from.module_id, .pos = foreign.symbols.items[sym.from.sym].decl_pos };
}

/// The types a type is built from, in order: a wrapper's inner type, a
/// slice's element, an array's element then its length, a function's
/// parameters then its return type, a generic instance's arguments.
pub const TypeChildren = struct {
    ty: Type,
    i: usize = 0,

    pub fn next(self: *TypeChildren) ?TypeId {
        const i = self.i;
        self.i += 1;
        return switch (self.ty) {
            .optional, .fallible, .read_view, .write_view, .shared, .weak, .range, .callable => |inner| if (i == 0) inner else null,
            .slice => |s| if (i == 0) s.elem else null,
            .array => |a| if (i == 0) a.elem else if (i == 1) a.len else null,
            .function => |f| if (i < f.params.len) f.params[i] else if (i == f.params.len) f.returns else null,
            .parameterized_nominal => |pn| if (i < pn.args.len) pn.args[i] else null,
            else => null,
        };
    }
};

pub fn typeChildren(ctx: *const SemContext, ty: TypeId) TypeChildren {
    return .{ .ty = ctx.types.get(ty) };
}

/// An array's length when it is a known number; null for a compile-time
/// parameter, whose value each instance gives, and for a length out of
/// range, which the instance that gives it is rejected for.
pub fn arrayLen(ctx: *const SemContext, a: ArrayType) ?u64 {
    return switch (ctx.types.get(a.len)) {
        .ct_value => |v| if (v.int < 0 or v.int > max_array_len) null else @intCast(v.int),
        else => null,
    };
}

/// The bytes a value of `ty` takes at least (padding aside), or null
/// when that depends on a generic parameter or follows an error, such as
/// holding a type reported too large.
pub fn minBytes(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?u128 {
    return minBytesOf(ctx, ty, true);
}

fn minBytesOf(ctx: *SemContext, ty: TypeId, top: bool) std.mem.Allocator.Error!?u128 {
    if (!top and ctx.oversized.contains(ty)) return null;
    // Each type is sized once; one that holds itself (rejected) is null
    // while it is being sized.
    const slot = try ctx.byte_sizes.getOrPut(ctx.allocator, ty);
    if (slot.found_existing) return slot.value_ptr.*;
    slot.value_ptr.* = null;
    const bytes: ?u128 = switch (ctx.types.get(ty)) {
        .invalid, .unknown, .type_var, .ct_param => null,
        .void, .noreturn, .none_literal => 0,
        .bool => 1,
        .int => |i| i.width() / 8,
        .float => |f| if (f.bits == 0) 8 else f.bits / 8,
        .string, .slice => 16,
        .text => 24,
        .any_error => 2,
        // A null handle or view is its null address; anything else
        // needs a flag.
        .optional => |inner| if (try minBytesOf(ctx, inner, false)) |b| b + @intFromBool(!isAddress(ctx, inner)) else null,
        .array => |a| blk: {
            const n = arrayLen(ctx, a) orelse break :blk null;
            const e = (try minBytesOf(ctx, a.elem, false)) orelse break :blk null;
            break :blk std.math.mul(u128, n, e) catch std.math.maxInt(u128);
        },
        .nominal => |sym| try fieldBytes(ctx, sym, .empty),
        // Sized where it is declared (`checkTypeSizes`).
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk null;
            const declared = foreign.types.find(.{ .nominal = in.sym_id }) orelse break :blk null;
            break :blk foreign.byte_sizes.get(declared) orelse null;
        },
        // A Vec is its buffer's slice and length, a Box its pointer. A
        // Cell is its value (its one field), a Signal its value, a pending
        // one, a flag, and a Vec of subscribers.
        .parameterized_nominal => |pn| if (pn.sym == ctx.vec_sym_id)
            24
        else if (pn.sym == ctx.box_sym_id)
            8
        else if (pn.sym == ctx.signal_sym_id) blk: {
            const v = (try minBytesOf(ctx, pn.args[0], false)) orelse break :blk null;
            break :blk 2 *| v +| 2 +| 24;
        } else try fieldBytes(ctx, pn.sym, .{ .params = ctx.symbols.items[pn.sym].type_params orelse &.{}, .args = pn.args }),
        else => 8,
    };
    try ctx.byte_sizes.put(ctx.allocator, ty, bytes);
    return bytes;
}

/// The bytes a struct's fields take at least, or an enum's tag and
/// largest payload.
fn fieldBytes(ctx: *SemContext, sym: SymbolId, subst: TypeSubst) std.mem.Allocator.Error!?u128 {
    if (ctx.symbols.items[sym].contents.cyclic) return null;
    var total: u128 = 0;
    var variants: u128 = 0;
    for (ctx.symbols.items[sym].fields orelse &.{}) |f| {
        if (f.is_method or f.is_drop_method) continue;
        if (f.is_variant) {
            variants += 1;
            var payload: u128 = 0;
            for (f.payload orelse &.{}) |p| payload +|= (try minBytesOf(ctx, try substituteType(ctx, p.ty, subst), false)) orelse return null;
            total = @max(total, payload);
        } else total +|= (try minBytesOf(ctx, try substituteType(ctx, f.ty, subst), false)) orelse return null;
    }
    // The tag: a byte per 8 bits it needs.
    var tag: u128 = 0;
    var span: u128 = 1;
    while (span < variants) : (span <<= 8) tag += 1;
    return total +| tag;
}

/// Whether a value of `ty` is or starts with an address, which is never
/// 0: an optional of it is null there.
fn isAddress(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .shared, .weak, .read_view, .write_view, .string, .slice => true,
        else => false,
    };
}

/// Whether integer type `ty` holds `v`.
pub fn intFits(ctx: *const SemContext, ty: TypeId, v: Wide) bool {
    return switch (ctx.types.get(ty)) {
        .int => |i| intInfoFits(i, v),
        else => true,
    };
}

/// A value of the array type `ty`, spelled or made at `pos`, must fit
/// `max_value_bytes`: one that depends on generic parameters is checked
/// at each instance (`typecheck.checkGenericInstantiations`). False after
/// a diagnostic.
pub fn checkArrayBytes(ctx: *SemContext, pos: u32, ty: TypeId) std.mem.Allocator.Error!bool {
    if (containsPoison(ctx, ty)) return true;
    if (containsTypeVar(ctx, ty)) {
        try ctx.addGeneric(.arrays, .{ .ty = ty, .pos = pos });
        return true;
    }
    if (ctx.quiet > 0) return true;
    if (ctx.oversized.contains(ty)) return false;
    const bytes = (try arrayOversized(ctx, ty)) orelse return true;
    try reportOversized(ctx, pos, ty, bytes);
    return false;
}

/// Each array in `ty`, a type inferred from a value made at `pos`, must
/// fit `max_value_bytes`, innermost first. False after a diagnostic.
pub fn checkArraysIn(ctx: *SemContext, pos: u32, ty: TypeId) std.mem.Allocator.Error!bool {
    if (containsPoison(ctx, ty) or containsTypeVar(ctx, ty)) return true;
    var it = typeChildren(ctx, ty);
    while (it.next()) |c| if (!try checkArraysIn(ctx, pos, c)) return false;
    if (ctx.types.get(ty) == .array) return checkArrayBytes(ctx, pos, ty);
    return true;
}

/// The size of the array type `ty` when it is too large by itself: its
/// element fits `max_value_bytes` (one that does not is reported on its
/// own), and the array does not.
pub fn arrayOversized(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?u128 {
    const bytes = (try minBytes(ctx, ty)) orelse return null;
    if (bytes <= max_value_bytes) return null;
    const elem = (try minBytes(ctx, ctx.types.get(ty).array.elem)) orelse return null;
    return if (elem > max_value_bytes) null else bytes;
}

/// Report that `ty` takes `bytes`, more than `max_value_bytes`.
pub fn reportOversized(ctx: *SemContext, pos: u32, ty: TypeId, bytes: u128) std.mem.Allocator.Error!void {
    try ctx.oversized.put(ctx.allocator, ty, {});
    try ctx.err(pos, "`{s}` takes {d} bytes; a value takes at most {d} (8 MiB), since it may live on the stack. Keep larger data in a `Vec`", .{ try formatType(ctx, ty), bytes, max_value_bytes });
}

/// Whether `ty` (a struct, an enum, or a generic type's instance under
/// `subst`) is too large by itself: it takes more than `max_value_bytes`,
/// and no type it holds directly does, which is reported on its own.
/// Its size, when it is.
pub fn oversizedByItself(ctx: *SemContext, ty: TypeId, sym: SymbolId, subst: TypeSubst) std.mem.Allocator.Error!?u128 {
    const bytes = (try minBytes(ctx, ty)) orelse return null;
    if (bytes <= max_value_bytes) return null;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| for (dataFields(f)) |d| {
        const held = (try minBytes(ctx, try substituteType(ctx, d.ty, subst))) orelse return null;
        if (held > max_value_bytes) return null;
    };
    return bytes;
}

/// Every declared struct and enum must fit `max_value_bytes`; a generic
/// one is checked at each instance. Each is sized after the types it
/// holds (`order`, from `computeContents`), so sizing one does not nest
/// through the chain of types it holds.
fn checkTypeSizes(ctx: *SemContext, order: []const SymbolId) std.mem.Allocator.Error!void {
    for (order) |id| {
        const sym = ctx.symbols.items[id];
        if (sym.kind != .nominal_type or sym.decl_pos >= imported_decl_pos) continue;
        const ty = try ctx.intern(.{ .nominal = id });
        const bytes = (try oversizedByItself(ctx, ty, id, .empty)) orelse continue;
        try reportOversized(ctx, sym.decl_pos, ty, bytes);
    }
}

/// The `ct_value` of the integer `v`.
pub fn ctInt(ctx: *SemContext, v: Wide) std.mem.Allocator.Error!TypeId {
    return ctx.intern(.{ .ct_value = .{ .int = v } });
}

/// Does a value of this type need its destructor run: a `*T` / `~T`
/// handle, a Vec, a Box, an owned closure, or a nominal or generic instance
/// that declares `drop` or holds such a value. Types with drop glue are
/// non-Copy.
pub fn typeHasDropGlue(ctx: *const SemContext, ty_id: TypeId) bool {
    return ctx.holds(ty_id).glue;
}

/// The signature of an owned closure handle `*fun(...) -> R` / `*sub(...)`
/// (possibly viewed), or null.
pub fn ownedClosureFn(ctx: *const SemContext, ty: TypeId) ?FunctionType {
    return switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .shared => |inner| switch (ctx.types.get(inner)) {
            .function => |f| f,
            else => null,
        },
        else => null,
    };
}

/// The function type of a callable view `?fun(...) -> R`: a
/// closure, function, or owned closure lent to a call.
pub fn callableFn(ctx: *const SemContext, ty: TypeId) ?FunctionType {
    return ctx.types.get(callableFnTy(ctx, ty) orelse return null).function;
}

/// The function type of callable view `ty`, or null. (A callable of
/// anything else follows a diagnostic.)
pub fn callableFnTy(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const inner = switch (ctx.types.get(ty)) {
        .read_view => |inner| inner,
        else => return null,
    };
    const f = switch (ctx.types.get(inner)) {
        .callable => |f| f,
        else => return null,
    };
    return if (ctx.types.get(f) == .function) f else null;
}

/// The callable view of function type `fn_ty`: `?fun(...)`.
pub fn callableOfFn(ctx: *SemContext, fn_ty: TypeId) !TypeId {
    return ctx.intern(.{ .read_view = try ctx.intern(.{ .callable = fn_ty }) });
}

/// Whether a value of `ty` holds a callable view inside it (in an
/// optional, a handle, an array or slice, or a type argument). A
/// callable view is only ever a parameter, a local, or a result.
pub fn holdsCallable(ctx: *const SemContext, ty: TypeId) bool {
    switch (ctx.types.get(ty)) {
        .callable => return true,
        .read_view, .write_view, .optional, .fallible, .shared, .weak => |inner| return holdsCallable(ctx, inner),
        .slice => |sl| return holdsCallable(ctx, sl.elem),
        .array => |a| return holdsCallable(ctx, a.elem),
        .parameterized_nominal => |pn| for (pn.args) |a| {
            if (holdsCallable(ctx, a)) return true;
        },
        else => {},
    }
    return false;
}

/// The diagnostic for a callable view held inside another value.
pub const held_callable = "a callable view `{s}` is only a parameter's, a local's, or a result's type; no value can hold one";

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

/// What an owned closure may return: a plain Copy value, or a fallible
/// one (`Int!`).
pub fn isClosureResult(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .fallible => |inner| isClosureValue(ctx, inner),
        else => isClosureValue(ctx, ty),
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

/// The error sets a bare `.name` may mean in this module, as its types:
/// its own sets, private ones included, then the `pub` sets of the
/// modules it reaches through its imports, that have a member `name`.
pub fn errorSetsWith(ctx: *SemContext, name: []const u8) std.mem.Allocator.Error![]const TypeId {
    var out: std.ArrayList(TypeId) = .empty;
    const a = ctx.arena.allocator();
    try collectErrorSets(ctx, ctx, null, name, &out, a);
    var it = ctx.reach.iterator(.{});
    while (it.next()) |id| try collectErrorSets(ctx, ctx.foreign_semas.get(@intCast(id)).?, @intCast(id), name, &out, a);
    return out.items;
}

fn collectErrorSets(ctx: *SemContext, in: *const SemContext, module_id: ?u32, name: []const u8, out: *std.ArrayList(TypeId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    for (in.symbols.items, 0..) |sym, i| {
        if (!sym.flags.error_set or isProxy(sym)) continue;
        if (module_id != null and !sym.flags.is_public) continue;
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_variant or !std.mem.eql(u8, f.name, name)) continue;
            try out.append(a, if (module_id) |m|
                try ctx.intern(.{ .imported_nominal = .{ .module_id = m, .sym_id = @intCast(i) } })
            else
                try ctx.intern(.{ .nominal = @intCast(i) }));
            break;
        }
    }
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

/// Why values of a type have no `==`: the type that lacks it, found
/// inside the compared type, and the path of fields to it.
pub const NotEquatable = struct {
    /// In the checked module's type store.
    ty: TypeId,
    /// Field names from the compared type to `ty`, joined by `.`, a
    /// variant's payload field as `variant.field`; empty for the
    /// compared type itself or what it holds outside a field (an
    /// element, an optional's value).
    path: []const u8,
    why: Why,

    pub const Why = enum {
        /// `*T` or `~T`: `==` could compare identity or content.
        handle,
        /// An owned closure `*fun(...)`.
        closure,
        function,
        /// Vec, Cell, Signal, or `Void`.
        no_eq,
        /// A view held in a field or payload: the value is a view.
        view,
        /// A struct that declares `drop`.
        drop,
        /// A struct declared `unique`.
        unique,
    };
};

/// Why `==` does not compare values of `ty`, or null when it does:
/// numbers, Bool, String, error values, plain enums, and, when all they
/// hold is equatable, optionals, arrays, slices, structs without `drop`,
/// and payload enums. Handles, functions, `Void`, Vec, Cell, Signal, and
/// views held in a field are not equatable. Each generic parameter
/// `ty` holds is appended to `params`, when given: `==` on `ty` holds in
/// the instances where it holds for them.
pub fn notEquatable(ctx: *SemContext, ty: TypeId, params: ?*std.ArrayList(SymbolId)) std.mem.Allocator.Error!?NotEquatable {
    var walk: EquatableWalk = .{ .ctx = ctx, .params = params };
    defer walk.deinit();
    try walk.items.append(ctx.allocator, .{ .ty = ty });
    try walk.work.append(ctx.allocator, 0);
    while (walk.work.pop()) |i| {
        const why = (try walk.step(i)) orelse continue;
        // The path of fields from the compared type to the one found.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(ctx.allocator);
        var at = i;
        while (at != 0) : (at = walk.items.items[at].parent) {
            const name = walk.items.items[at].name;
            if (name.len > 0) try names.append(ctx.allocator, name);
        }
        std.mem.reverse([]const u8, names.items);
        const path = try std.mem.join(ctx.arena.allocator(), ".", names.items);
        return .{ .ty = walk.items.items[i].ty, .path = path, .why = why };
    }
    return null;
}

pub fn isEquatable(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!bool {
    return (try notEquatable(ctx, ty, null)) == null;
}

/// The types a compared value holds, walked depth first with an explicit
/// stack, so a long chain of types does not nest the walk. Each is in
/// `ctx`'s store: the field types of another module's struct are
/// imported there, and a generic instance's have its type arguments
/// applied.
const EquatableWalk = struct {
    ctx: *SemContext,
    params: ?*std.ArrayList(SymbolId),
    /// Every type reached: the compared one first, then each with the
    /// one that holds it and, for a field or payload, its name
    /// (`variant.field` for a payload field).
    items: std.ArrayList(struct { ty: TypeId, parent: u32 = 0, name: []const u8 = "", in_decl: bool = false }) = .empty,
    /// The items still to check, the next last.
    work: std.ArrayList(u32) = .empty,
    /// Declared types checked or being checked: one reached again,
    /// through itself or another path, adds nothing new.
    visited: std.AutoHashMapUnmanaged(TypeId, void) = .empty,

    fn deinit(self: *EquatableWalk) void {
        self.items.deinit(self.ctx.allocator);
        self.work.deinit(self.ctx.allocator);
        self.visited.deinit(self.ctx.allocator);
    }

    /// Why item `i`'s type has no `==` itself, or null after queuing
    /// what it holds. A slice held in a field or payload is a view.
    fn step(self: *EquatableWalk, i: u32) std.mem.Allocator.Error!?NotEquatable.Why {
        const ctx = self.ctx;
        const item = self.items.items[i];
        switch (ctx.types.get(item.ty)) {
            .optional => |inner| try self.push(i, inner, ""),
            .array => |a| try self.push(i, a.elem, ""),
            .slice => |sl| if (item.in_decl) return .view else try self.push(i, sl.elem, ""),
            .read_view, .write_view => return .view,
            .shared => |inner| return if (ctx.types.get(inner) == .function) .closure else .handle,
            .weak => return .handle,
            .function => return .function,
            // A parameter of another module's generic type is always
            // bound by the instance that reaches it.
            .type_var => |sym| if (self.params) |out| if (!isProxy(ctx.symbols.items[sym]) and std.mem.findScalar(SymbolId, out.items, sym) == null) try out.append(ctx.allocator, sym),
            .nominal, .imported_nominal, .parameterized_nominal => return self.stepDecl(i),
            .void, .fallible, .range => return .no_eq,
            else => {},
        }
        return null;
    }

    fn stepDecl(self: *EquatableWalk, i: u32) std.mem.Allocator.Error!?NotEquatable.Why {
        const ctx = self.ctx;
        const ty = self.items.items[i].ty;
        const decl = nominalDecl(ctx, ty) orelse return null;
        if (isBuiltinGeneric(decl.ctx, decl.sym)) return .no_eq;
        const sym = decl.symbol();
        if (sym.flags.error_set) return null;
        if ((try self.visited.getOrPut(ctx.allocator, ty)).found_existing) return null;
        const fields = sym.fields orelse return null;
        for (fields) |f| if (f.is_drop_method) return .drop;
        if (sym.flags.unique) return .unique;
        // An instance's field types name its generic type's parameters
        // (a proxy's, for another module's generic type).
        const subst: TypeSubst = switch (ctx.types.get(ty)) {
            .parameterized_nominal => |pn| .{ .params = sym.type_params orelse &.{}, .args = pn.args },
            else => .empty,
        };
        // Queued last to first, so the first field is checked first.
        var k = fields.len;
        while (k > 0) {
            k -= 1;
            const f = &fields[k];
            const held = dataFields(f);
            var j = held.len;
            while (j > 0) {
                j -= 1;
                const d = held[j];
                const fty = if (decl.module_id) |m| try importType(ctx, decl.ctx, d.ty, m) else try substituteType(ctx, d.ty, subst);
                const name = if (f.is_variant) try ctx.arena.allocator().print("{s}.{s}", .{ f.name, d.name }) else d.name;
                try self.push(i, fty, name);
            }
        }
        return null;
    }

    /// Queue `ty`, which item `parent` holds: in the field `name`, or
    /// (with no name) as its value or element.
    fn push(self: *EquatableWalk, parent: u32, ty: TypeId, name: []const u8) std.mem.Allocator.Error!void {
        const in_decl = name.len > 0 or self.items.items[parent].in_decl;
        try self.items.append(self.ctx.allocator, .{ .ty = ty, .parent = parent, .name = name, .in_decl = in_decl });
        try self.work.append(self.ctx.allocator, @intCast(self.items.items.len - 1));
    }
};

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

/// A read or write view type: `?T`, `!T`.
pub fn isReadOrWriteView(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => true,
        else => false,
    };
}

/// Whether assigning a binding of type `ty` after its declaration writes
/// through to the value it views instead of rebinding it: every write
/// view does, a `!T` parameter, local, capture, or loop or pattern
/// binding alike (`new w = !m` binds a new one).
pub fn assignWritesThrough(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.types.get(ty) == .write_view;
}

/// The element type of a writable slice `![]T`; null for any other type.
pub fn writeSliceElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .write_view => |inner| switch (ctx.types.get(inner)) {
            .slice => |s| s.elem,
            else => null,
        },
        else => null,
    };
}

/// Peel `?T` / `!T`.
pub fn unwrapViews(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = ty_id;
    while (true) {
        switch (ctx.types.get(id)) {
            .read_view, .write_view => |inner| id = inner,
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
            .read_view, .write_view, .shared => |inner| id = inner,
            else => return id,
        }
    }
}

/// The struct or enum a `Box[T]` (or a view or handle of one) holds,
/// through any number of boxes, whose fields and methods are reached
/// through them; null for anything else.
pub fn boxedNominal(ctx: *const SemContext, ty_id: TypeId) ?TypeId {
    const box = unwrapReadAccess(ctx, ty_id);
    if (boxedType(ctx, box) == null) return null;
    const inner = unwrapAccess(ctx, box);
    return switch (ctx.types.get(inner)) {
        .nominal, .imported_nominal => inner,
        .parameterized_nominal => |pn| if (isBuiltinGeneric(ctx, pn.sym)) null else inner,
        else => null,
    };
}

/// `T` of a `Box[T]`; null for any other type.
pub fn boxedType(ctx: *const SemContext, ty_id: TypeId) ?TypeId {
    return switch (ctx.types.get(ty_id)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.box_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// One of the built-in generic types: `Cell`, `Vec`, `Box`, `Signal`.
pub fn isBuiltinGeneric(ctx: *const SemContext, sym: SymbolId) bool {
    return isHeapBuiltin(ctx, sym) or sym == ctx.cell_sym_id or sym == ctx.signal_sym_id;
}

/// The value member access on a `ty_id` reaches: through views,
/// handles, and boxes, each of which lends the views of what it holds
/// (Core §4, `lendsAs`).
pub fn unwrapAccess(ctx: *const SemContext, ty_id: TypeId) TypeId {
    var id = unwrapReadAccess(ctx, ty_id);
    while (boxedType(ctx, id)) |inner| id = unwrapReadAccess(ctx, inner);
    return id;
}

/// Whether member access on a `ty_id` reaches its value through a shared
/// handle (`unwrapAccess`): `*S`, `*Box[S]`, `Box[*S]`, or a view of
/// one. Nothing is written there, since other handles may exist.
pub fn accessThroughShared(ctx: *const SemContext, ty_id: TypeId) bool {
    var id = ty_id;
    while (true) switch (ctx.types.get(id)) {
        .shared => return true,
        .read_view, .write_view => |inner| id = inner,
        else => id = boxedType(ctx, id) orelse return false,
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

/// The declaration behind a (possibly viewed) nominal type, local or
/// imported.
pub fn nominalDecl(ctx: *const SemContext, ty_id: TypeId) ?NominalDecl {
    return switch (ctx.types.get(unwrapViews(ctx, ty_id))) {
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

/// Replace every `type_var` and `ct_param` in `ty_id` that `subst` maps.
pub fn substituteType(ctx: *SemContext, ty_id: TypeId, subst: TypeSubst) std.mem.Allocator.Error!TypeId {
    if (subst.isEmpty() or !ctx.typeInfo(ty_id).has_type_var) return ty_id;
    const ty = ctx.types.get(ty_id);
    switch (ty) {
        .type_var, .ct_param => |sym| return subst.lookup(sym) orelse ty_id,
        inline .read_view, .write_view, .shared, .weak, .optional, .fallible, .range, .callable => |inner, tag| {
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
            const n = try substituteType(ctx, a.len, subst);
            if (e == a.elem and n == a.len) return ty_id;
            // A length out of range is reported where the instance is
            // made (`Requirement.array_len`); the array is poison.
            if (ctx.types.get(n) == .ct_value and arrayLen(ctx, .{ .elem = e, .len = n }) == null) return ctx.types.invalid_id;
            return ctx.intern(.{ .array = .{ .elem = e, .len = n } });
        },
        .function => |f| {
            var params: std.ArrayList(TypeId) = .empty;
            defer params.deinit(ctx.allocator);
            for (f.params) |p| try params.append(ctx.allocator, try substituteType(ctx, p, subst));
            var ct: std.ArrayList(TypeId) = .empty;
            defer ct.deinit(ctx.allocator);
            for (f.ct_params) |p| try ct.append(ctx.allocator, try substituteType(ctx, p, subst));
            const ret = try substituteType(ctx, f.returns, subst);
            if (ret == f.returns and std.mem.eql(TypeId, params.items, f.params) and std.mem.eql(TypeId, ct.items, f.ct_params)) return ty_id;
            return ctx.internCopy(.{ .function = .{ .params = params.items, .returns = ret, .is_sub = f.is_sub, .ct_params = ct.items, .ct_syms = f.ct_syms } });
        },
        .parameterized_nominal => |pn| {
            var args: std.ArrayList(TypeId) = .empty;
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

/// Whether `ty_id` is or mentions a poison type (`invalid`, `unknown`),
/// which only follows a diagnostic.
pub fn containsPoison(ctx: *const SemContext, ty_id: TypeId) bool {
    return ctx.typeInfo(ty_id).poison;
}

/// Whether lending `inner` (`?inner`) hands over a copy of the value: a
/// scalar or a view, which nothing can change while it is lent and which
/// costs no more to copy than a pointer. Anything larger is lent by
/// address, as is a value that owns resources (a copy would be dropped
/// with whatever holds it) or holds a Cell (which can change while it is
/// lent). `rig.ReadView` applies the same rule to Zig types, for a
/// generic `?T`.
pub fn lendByValue(ctx: *const SemContext, inner: TypeId) bool {
    if (typeHasDropGlue(ctx, inner) or maybeDropGlue(ctx, inner) or holdsCellByValue(ctx, inner)) return false;
    return copiedByReadView(ctx, inner);
}

/// A type a read view copies: a number, `Bool`, `String`, a slice, a
/// function or callable view (a `rig.FnRef`), a plain enum, an
/// error, or an optional of one of those.
fn copiedByReadView(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .bool, .string, .int, .float, .int_literal, .float_literal, .none_literal, .any_error, .slice, .function, .callable => true,
        .write_view => writeSliceElem(ctx, ty) != null,
        .optional => |inner| copiedByReadView(ctx, inner),
        .nominal, .imported_nominal => isPlainEnum(ctx, ty) or isErrorSet(ctx, ty),
        else => false,
    };
}

/// Whether a value of `ty` holds a `Cell` inline (not behind a handle,
/// a view, or a Vec's buffer). A read view of such a value is held as
/// a pointer, since the cell can change while it is lent.
pub fn holdsCellByValue(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).cell;
}

/// Whether a value of `ty` can hold a marked view (see `Views`). A generic
/// parameter holds none: an instantiation with a view is checked apart.
pub fn holdsMarkedView(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).views.marked;
}

/// Whether a value of `ty` holds, or in some instance may hold, a marked
/// view.
pub fn mayHoldMarkedView(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.views.marked or info.holds_type_var;
}

/// Whether a value of `ty` holds a marked view or a String, which may view a
/// Text: the ownership checker tracks the loans such a value carries.
pub fn mayHoldView(ctx: *const SemContext, ty: TypeId) bool {
    const b = ctx.holds(ty).views;
    return b.marked or b.string;
}

/// Whether a value of `ty` reaches a Text (`Views.text`), which a
/// String may view.
pub fn reachesText(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).views.text;
}

/// Whether `child` is a header of `parent`: an `if` or `while`
/// condition, a guard, or the subject of a `match` or `for`. A
/// header is its own statement: its temporaries end with it.
pub fn isHeaderOf(parent: Sexp, child: Sexp) bool {
    const kind = parent.kind() orelse return false;
    const header: Sexp = switch (kind) {
        .@"if" => ir.If.cond(parent),
        .@"while" => ir.While.cond(parent),
        .match => ir.Match.subject(parent),
        .arm => ir.Arm.guard(parent),
        .@"for" => ir.For.source(parent),
        else => return false,
    };
    return header == .list and child == .list and header.list.id == child.list.id;
}

/// The first statement temporary (`dropsTemp`) that `stmt`, a statement
/// or a header, makes itself: not one inside a block or closure it
/// holds, a header of its own (an `if`'s condition, a `match`'s
/// subject), or a `while` loop's step, each of which ends its own.
pub fn firstStmtTemp(ctx: *const SemContext, stmt: Sexp) ?Sexp {
    if (stmt != .list or stmt.isKind(.block) or stmt.isKind(.lambda)) return null;
    if (ctx.dropsTemp(stmt)) return stmt;
    for (rig.children(stmt)) |c| {
        if (isHeaderOf(stmt, c) or isWhileStep(stmt, c)) continue;
        if (firstStmtTemp(ctx, c)) |t| return t;
    }
    return null;
}

/// Whether a view of type `ty` is held as a pointer: a write view (but
/// a `![]T`, a slice), or a read view of a value that is not lent by
/// value (`lendByValue`).
pub fn viewHeldAsPointer(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .write_view => writeSliceElem(ctx, ty) == null,
        .read_view => |inner| !lendByValue(ctx, inner),
        else => false,
    };
}

/// Whether `child` is the step of `while` loop `parent`: a statement
/// of its own, run after each pass.
pub fn isWhileStep(parent: Sexp, child: Sexp) bool {
    if (!parent.isKind(.@"while")) return false;
    const step = ir.While.step(parent);
    return step == .list and child == .list and step.list.id == child.list.id;
}

/// Whether `step`, the step of a `while` whose condition is `cond`,
/// reads a name an `as` part of `cond` binds. Such a step runs in the
/// bindings' scope, after the body; any other runs after that scope
/// ends (docs/INTERNALS.md, "Control flow").
pub fn stepReadsBinding(ctx: *const SemContext, cond: Sexp, step: Sexp) bool {
    if (step == .nil) return false;
    if (rig.isConditionJoin(cond)) return stepReadsBinding(ctx, ir.get(cond, .left), step) or stepReadsBinding(ctx, ir.get(cond, .right), step);
    if (!cond.isKind(.as)) return false;
    const sym = ctx.symbolOf(ir.As.name(cond)) orelse return false;
    return findUse(ctx, step, sym) != null;
}

/// The first name in `node` that reads binding `sym`: `sym` itself, or a
/// closure's capture of it, whose symbol leads back to `sym` through its
/// `origin`.
pub fn findUse(ctx: *const SemContext, node: Sexp, sym: SymbolId) ?Sexp {
    if (node == .src) {
        var s = ctx.symbolOf(node) orelse return null;
        while (s != symbol_invalid) : (s = ctx.symbols.items[s].origin) if (s == sym) return node;
        return null;
    }
    if (node != .list) return null;
    for (node.items()) |c| if (findUse(ctx, c, sym)) |use| return use;
    return null;
}

/// Whether a value of `ty` holds a String but no marked view or type
/// parameter: it may view a Text, and nothing else.
pub fn holdsViewOnly(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.views.string and !info.views.marked and !info.holds_type_var and !info.poison;
}

// -----------------------------------------------------------------------------
// What a view can point into (Core sentence 7)
// -----------------------------------------------------------------------------

/// How a value of a holder type leads to the memory a view points into
/// (docs/INTERNALS.md, "Call origins"). One classifier answers both
/// questions sentence 7 asks of a type: whether a value of it could hold
/// what a view views (`!= .none`), and whether that memory may be its
/// own (`== .owned`) rather than a read view's it holds.
pub const ViewReach = enum(u2) {
    /// It never does.
    none,
    /// Only by crossing a read view it holds (`?T`, `[]T`, a String):
    /// the memory is that view's, never the holder's own.
    through_view,
    /// Through what it owns, or a write view it holds: the memory may be
    /// its own, or memory it can change.
    owned,
};

/// The memory a view may point into: a set of `ViewAtom`s, a Text's or
/// a literal's bytes, or anything at all.
pub const ViewTargets = struct {
    any: bool = false,
    bytes: bool = false,
    atoms: std.ArrayList(u64) = .empty,

    fn add(self: *ViewTargets, a: std.mem.Allocator, atom: u64) std.mem.Allocator.Error!void {
        if (std.mem.findScalar(u64, self.atoms.items, atom) == null) try self.atoms.append(a, atom);
    }

    pub fn isEmpty(self: ViewTargets) bool {
        return !self.any and !self.bytes and self.atoms.items.len == 0;
    }
};

/// A type as `viewReach` compares types across modules: the same in
/// every module for one type, and so the same for two equal types. A
/// declared type is its declaration; any other, its kind (and a
/// number's size). Unequal types may share one, which only makes the
/// answer more cautious.
fn viewAtom(ctx: *const SemContext, ty: TypeId) u64 {
    const t = ctx.types.get(ty);
    const tag: u64 = @backingInt(std.meta.activeTag(t));
    const decl: ?struct { module: u32, sym: SymbolId } = switch (t) {
        .nominal => |sym| if (sym == ctx.endian_sym_id) .{ .module = 0, .sym = symbol_invalid } else .{ .module = ctx.module_id, .sym = sym },
        .imported_nominal => |n| .{ .module = n.module_id, .sym = n.sym_id },
        .parameterized_nominal => |pn| blk: {
            const sym = ctx.symbols.items[pn.sym];
            if (sym.decl_pos == builtin_decl_pos) break :blk .{ .module = 0, .sym = pn.sym };
            if (isProxy(sym)) break :blk .{ .module = sym.from.module_id, .sym = sym.from.sym };
            break :blk .{ .module = ctx.module_id, .sym = pn.sym };
        },
        else => null,
    };
    if (decl) |d| return 1 << 63 | @as(u64, d.module) << 32 | d.sym;
    return switch (t) {
        .int => |i| tag << 32 | @as(u64, i.bits) << 1 | @intFromBool(i.signed),
        .float => |f| tag << 32 | f.bits,
        else => tag << 32,
    };
}

/// A type in the module whose types it is written in. A generic type's
/// declared field is read in its generic context, where a type
/// parameter stands for the instance's arguments (`args`), which are
/// read where the instance is.
const ViewNode = struct {
    ctx: *const SemContext,
    ty: TypeId,
    args: ?struct { ctx: *const SemContext, tys: []const TypeId } = null,
    /// An element of an array, a slice, or a generic instance's
    /// argument, which a slice may view (`elem_view`).
    elem: bool = false,
};

/// The bit `viewAtom` sets on the target of a slice: memory a slice
/// views is an element of an array, a slice, or a Vec, never a field.
const elem_view: u64 = 1 << 62;

/// The types a value of `node` holds by value (fields, payloads, an
/// optional's, array's, Vec's, Box's, Cell's or Signal's contents, a
/// handle's), each passed to `f.visit`. A generic instance holds its
/// arguments, and its declared fields in the generic context.
fn ownedParts(node: ViewNode, f: anytype) std.mem.Allocator.Error!void {
    const ctx = node.ctx;
    switch (ctx.types.get(node.ty)) {
        .optional, .fallible, .shared, .weak => |inner| try f.visit(.{ .ctx = ctx, .ty = inner, .args = node.args }),
        .array => |a| try f.visit(.{ .ctx = ctx, .ty = a.elem, .args = node.args, .elem = true }),
        .nominal, .imported_nominal => {
            const decl = nominalDecl(ctx, node.ty) orelse return;
            for (decl.symbol().fields orelse &.{}) |*fld| {
                for (dataFields(fld)) |d| try f.visit(.{ .ctx = decl.ctx, .ty = d.ty });
            }
        },
        .parameterized_nominal => |pn| {
            for (pn.args) |arg| try f.visit(.{ .ctx = ctx, .ty = arg, .args = node.args, .elem = true });
            for (ctx.symbols.items[pn.sym].fields orelse &.{}) |*fld| {
                for (dataFields(fld)) |d| try f.visit(.{ .ctx = ctx, .ty = d.ty, .args = .{ .ctx = ctx, .tys = pn.args } });
            }
        },
        else => {},
    }
}

/// What a type's own views point into: the target of each view it
/// holds by value, not what those targets hold in turn (a view of a
/// value that holds views keeps that value's loans, which keep the
/// rest). A function, a lent callable, a type parameter, or a type
/// not known points anywhere.
pub fn viewTargets(ctx: *const SemContext, a: std.mem.Allocator, view: TypeId) std.mem.Allocator.Error!ViewTargets {
    var w: TargetWalk = .{ .a = a };
    try w.visit(.{ .ctx = ctx, .ty = view });
    return w.out;
}

const TargetWalk = struct {
    a: std.mem.Allocator,
    out: ViewTargets = .{},
    seen: std.AutoHashMapUnmanaged(SeenKey, void) = .empty,
    /// Only the views of written memory: storage a write view leads to.
    written_only: bool = false,
    written: bool = false,

    const SeenKey = struct { ctx: usize, ty: TypeId, args: usize, written: bool };

    fn target(self: *TargetWalk, node: ViewNode) std.mem.Allocator.Error!void {
        const ctx = node.ctx;
        switch (ctx.types.get(node.ty)) {
            .type_var => if (node.args) |args| {
                for (args.tys) |t| switch (args.ctx.types.get(t)) {
                    .type_var, .invalid, .unknown => self.out.any = true,
                    else => try self.target(.{ .ctx = args.ctx, .ty = t, .elem = node.elem }),
                };
            } else {
                self.out.any = true;
            },
            .function, .callable, .invalid, .unknown => self.out.any = true,
            else => try self.out.add(self.a, viewAtom(ctx, node.ty) | if (node.elem) elem_view else 0),
        }
    }

    fn visit(self: *TargetWalk, node: ViewNode) std.mem.Allocator.Error!void {
        const ctx = node.ctx;
        const t = ctx.types.get(node.ty);
        const is_view = switch (t) {
            .read_view, .write_view, .slice, .string, .function, .callable => true,
            else => false,
        };
        if (is_view and (!self.written_only or self.written)) switch (t) {
            // A `![]T` points at its elements; a `?[]T` at a slice.
            .write_view => |inner| try self.target(switch (ctx.types.get(inner)) {
                .slice => |sl| .{ .ctx = ctx, .ty = sl.elem, .args = node.args, .elem = true },
                else => .{ .ctx = ctx, .ty = inner, .args = node.args },
            }),
            .read_view => |inner| try self.target(.{ .ctx = ctx, .ty = inner, .args = node.args }),
            .slice => |sl| try self.target(.{ .ctx = ctx, .ty = sl.elem, .args = node.args, .elem = true }),
            .string => self.out.bytes = true,
            else => self.out.any = true,
        };
        switch (t) {
            .write_view => |inner| if (self.written_only) {
                // What a write view leads to may be written.
                const saved = self.written;
                defer self.written = saved;
                self.written = true;
                const elem = switch (ctx.types.get(inner)) {
                    .slice => |sl| sl.elem,
                    else => inner,
                };
                return self.visit(.{ .ctx = ctx, .ty = elem, .args = node.args });
            },
            .type_var => if (node.args) |args| {
                if (self.written_only and !self.written) return;
                // The instance's arguments, read where it is.
                for (args.tys) |arg| try self.visit(.{ .ctx = args.ctx, .ty = arg });
            } else if (!self.written_only or self.written) {
                self.out.any = true;
            },
            .invalid, .unknown => if (!self.written_only or self.written) {
                self.out.any = true;
            },
            else => {},
        }
        if (is_view) return;
        // Each type is walked once per context.
        const key: SeenKey = .{ .ctx = @intFromPtr(ctx), .ty = node.ty, .args = if (node.args) |args| @intFromPtr(args.tys.ptr) else 0, .written = self.written };
        if ((try self.seen.getOrPut(self.a, key)).found_existing) return;
        try ownedParts(node, self);
    }
};

/// What a call may store through write parameters of types `params`:
/// the targets of the views a value stored in memory a write view among
/// them leads to may hold, a handle's contents included. A parameter
/// taken by value is the callee's own copy, so only what its write
/// views lead to counts; what a read view leads to is never written.
pub fn storeTargets(ctx: *const SemContext, a: std.mem.Allocator, params: []const TypeId) std.mem.Allocator.Error!ViewTargets {
    var w: TargetWalk = .{ .a = a, .written_only = true };
    for (params) |p| try w.visit(.{ .ctx = ctx, .ty = p });
    return w.out;
}

/// Which of a holder's memory counts: all of it, or only what it leads
/// to through a view (`?T`, `!T`, `[]T`, a String), as for a parameter
/// taken by value, whose own memory is the callee's copy.
pub const ReachFrom = enum { all, views };

/// How a value of type `holder` leads to the memory a value of type
/// `view` points into (`ViewReach`).
pub fn viewReach(ctx: *const SemContext, a: std.mem.Allocator, holder: TypeId, view: TypeId) std.mem.Allocator.Error!ViewReach {
    const targets = try viewTargets(ctx, a, view);
    return reachTargets(ctx, a, holder, targets, .all);
}

/// How a value of type `holder` leads to memory `targets` names,
/// counting the memory `from` says.
pub fn reachTargets(ctx: *const SemContext, a: std.mem.Allocator, holder: TypeId, targets: ViewTargets, from: ReachFrom) std.mem.Allocator.Error!ViewReach {
    if (targets.isEmpty()) return .none;
    var w: ReachWalk = .{ .a = a, .targets = targets, .from = from };
    try w.push(.{ .ctx = ctx, .ty = holder }, .{});
    while (w.queue.pop()) |item| {
        try w.step(item);
        if (w.found == .owned) return .owned;
    }
    return w.found;
}

const ReachWalk = struct {
    a: std.mem.Allocator,
    targets: ViewTargets,
    from: ReachFrom,
    found: ViewReach = .none,
    queue: std.ArrayList(Item) = .empty,
    seen: std.AutoHashMapUnmanaged(SeenKey, void) = .empty,
    /// How the parts `ownedParts` passes to `visit` are reached.
    cur: Path = .{},

    /// How a node is reached: past a read view, and past any view.
    const Path = struct { read: bool = false, viewed: bool = false };
    const Item = struct { node: ViewNode, path: Path };
    const SeenKey = struct { ctx: usize, ty: TypeId, path: Path, generic: bool, elem: bool };

    /// Memory of a target type is reached by `path`; `viewed` when it
    /// may be a view's.
    fn reached(self: *ReachWalk, path: Path, viewed: bool) void {
        if (self.from == .views and !viewed) return;
        const r: ViewReach = if (path.read) .through_view else .owned;
        if (@backingInt(r) > @backingInt(self.found)) self.found = r;
    }

    fn push(self: *ReachWalk, node: ViewNode, path: Path) std.mem.Allocator.Error!void {
        const key: SeenKey = .{ .ctx = @intFromPtr(node.ctx), .ty = node.ty, .path = path, .generic = node.args != null, .elem = node.elem };
        if ((try self.seen.getOrPut(self.a, key)).found_existing) return;
        try self.queue.append(self.a, .{ .node = node, .path = path });
    }

    fn visit(self: *ReachWalk, node: ViewNode) std.mem.Allocator.Error!void {
        try self.push(node, self.cur);
    }

    fn step(self: *ReachWalk, item: Item) std.mem.Allocator.Error!void {
        const node = item.node;
        const path = item.path;
        const ctx = node.ctx;
        const t = ctx.types.get(node.ty);
        const read: Path = .{ .read = true, .viewed = true };
        switch (t) {
            // Anything at all, a view among them.
            .function, .callable, .invalid, .unknown => return self.reached(path, true),
            // A type parameter stands for anything; in a generic type's
            // field, for the instance's arguments, which are walked apart.
            .type_var => {
                if (node.args == null) self.reached(path, true);
                return;
            },
            else => {},
        }
        const atom = viewAtom(ctx, node.ty);
        const hit = std.mem.findScalar(u64, self.targets.atoms.items, atom) != null or
            (node.elem and std.mem.findScalar(u64, self.targets.atoms.items, atom | elem_view) != null);
        if (self.targets.any or hit) self.reached(path, path.viewed);
        switch (t) {
            .read_view => |inner| try self.push(.{ .ctx = ctx, .ty = inner, .args = node.args }, read),
            .slice => |sl| try self.push(.{ .ctx = ctx, .ty = sl.elem, .args = node.args, .elem = true }, read),
            .write_view => |inner| {
                const next: ViewNode = switch (ctx.types.get(inner)) {
                    .slice => |sl| .{ .ctx = ctx, .ty = sl.elem, .args = node.args, .elem = true },
                    else => .{ .ctx = ctx, .ty = inner, .args = node.args },
                };
                try self.push(next, .{ .read = path.read, .viewed = true });
            },
            // A String views bytes; a Text owns them.
            .string => if (self.targets.bytes) self.reached(read, true),
            .text => if (self.targets.bytes) self.reached(path, path.viewed),
            else => {
                self.cur = path;
                try ownedParts(node, self);
            },
        }
    }
};

/// The origins of a function of type `f` (Core sentence 7): its result
/// carries the loans of each parameter whose type could hold what the
/// result views, and it may store those of each parameter whose type
/// could hold what memory its write parameters lead to holds. A generic
/// function's are its own signature's, where a type parameter could
/// hold anything, never an instance's.
pub fn defaultOrigins(ctx: *const SemContext, a: std.mem.Allocator, f: FunctionType) std.mem.Allocator.Error!Origins {
    var o: Origins = .{ .result = 0, .stores = 0 };
    const results = try viewTargets(ctx, a, f.returns);
    const stored = try storeTargets(ctx, a, f.params);
    for (f.params, 0..) |p, i| {
        if (try reachTargets(ctx, a, p, results, .views) != .none) o.result |= paramBit(i);
        if (try reachTargets(ctx, a, p, stored, .views) != .none) o.stores |= paramBit(i);
    }
    return o;
}

/// The origins of function `name`, declared at `pos` with type `f`:
/// its signature's (`defaultOrigins`), with the result's narrowed to the
/// parameters its `from` clause names. A name that is no parameter, or
/// one whose type cannot hold what the result views, is reported, as is
/// a clause on a result that views nothing.
fn declOrigins(ctx: *SemContext, a: std.mem.Allocator, name: []const u8, pos: u32, f: FunctionType) std.mem.Allocator.Error!Origins {
    var o = try defaultOrigins(ctx, a, f);
    const d = ctx.declared_origins.get(pos) orelse return o;
    const results = try viewTargets(ctx, a, f.returns);
    if (results.isEmpty()) {
        try ctx.errAt(d.names, "`{s}` returns `{s}`, which views nothing; `from` names what a result views", .{ name, try formatType(ctx, f.returns) });
        return o;
    }
    var named: ParamMask = 0;
    for (d.names.items()) |n| {
        const text = identAt(ctx.source, n) orelse continue;
        const i = for (d.params.items(), 0..) |p, i| {
            if (paramName(ctx.source, p)) |pn| if (std.mem.eql(u8, pn, text)) break i;
        } else {
            if (std.mem.eql(u8, text, "static")) {
                try ctx.errAt(n, "`static` stands alone (`from static`): a result may always view what lives for the whole program, so a list names only parameters", .{});
            } else try ctx.errAt(n, "`{s}` has no parameter `{s}`; `from` names parameters, `self`, or `static` alone", .{ name, text });
            continue;
        };
        if (i < f.params.len and try reachTargets(ctx, a, f.params[i], results, .views) == .none) {
            try ctx.errAt(n, "`{s}: {s}` cannot hold a view of what `{s}` returns, so its result never views it", .{ text, try formatType(ctx, f.params[i]), name });
            continue;
        }
        named |= paramBit(i);
    }
    o.result &= named;
    o.declared = true;
    return o;
}

/// Set the origins of every function and method this module declares
/// (`defaultOrigins`); the built-in generics' methods keep every
/// argument's loans.
fn computeOrigins(ctx: *SemContext) std.mem.Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (ctx.symbols.items) |*sym| {
        if (isProxy(sym.*) or sym.decl_pos == builtin_decl_pos or sym.decl_pos >= imported_decl_pos) continue;
        switch (sym.kind) {
            .function, .@"extern" => {
                const f = switch (ctx.types.get(sym.ty)) {
                    .function => |f| f,
                    else => continue,
                };
                sym.origins = try declOrigins(ctx, scratch.allocator(), sym.name, sym.decl_pos, f);
                _ = scratch.reset(.retain_capacity);
            },
            .nominal_type, .generic_type => {
                const fields = sym.fields orelse continue;
                const out = try ctx.arena.allocator().dupe(Field, fields);
                for (out) |*fld| {
                    if (!fld.is_method or fld.is_drop_method) continue;
                    const f = switch (ctx.types.get(fld.ty)) {
                        .function => |f| f,
                        else => continue,
                    };
                    fld.origins = try declOrigins(ctx, scratch.allocator(), fld.name, fld.decl_pos, f);
                    _ = scratch.reset(.retain_capacity);
                }
                sym.fields = out;
            },
            else => {},
        }
    }
}

/// Whether a value of `ty` holds a write view, which is unique.
pub fn holdsWriteView(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).views.write;
}

/// A value `Vec`, `Cell`, and `Signal` copy in and out like a number: a
/// Copy primitive, or plain data (a struct, enum, optional, or array
/// that owns nothing and holds no view).
pub fn isCopyElement(ctx: *const SemContext, ty: TypeId) bool {
    if (isCopyPrimitive(ctx, ty)) return true;
    return switch (ctx.types.get(ty)) {
        .nominal, .imported_nominal, .parameterized_nominal, .optional, .array => isPlainData(ctx, ty),
        else => false,
    };
}

/// A value that owns nothing and holds no view or type parameter: it
/// can be copied freely, like a number.
pub fn isPlainData(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.plain and !info.glue;
}

/// Whether a value of `ty` owns a resource depends on type parameters
/// that `ty` holds by value (a `T`, `T?`, `Wrap[T]` inside a generic
/// body): it has no drop glue of its own, but an instantiation may. Such
/// values are moved and dropped like resources.
pub fn maybeDropGlue(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return !info.glue and info.holds_type_var;
}

/// An answer about a type that may hold a type parameter by value:
/// `depends` when each instance answers for itself.
pub const Answer = enum { no, yes, depends };

/// Whether dropping a value of `ty` may run a user `drop` body: one of
/// its own, or of a value it holds and drops (a field, payload, element,
/// optional, array, Box's or counted handle's contents), never one a weak
/// handle or a view reaches. A `drop` body may read what the value views;
/// any other drop only releases memory, which uses no view (Core sentence
/// 6). `depends` for a value holding a type parameter, whose instances
/// answer for themselves; a type declared in another module answers by
/// whether it has drop glue.
pub fn dropRunsBody(ctx: *const SemContext, ty: TypeId) Answer {
    if (runsDropBody(ctx, ty, &.{})) return .yes;
    const info = ctx.holds(ty);
    return if (info.holds_type_var or info.poison) .depends else .no;
}

/// `path` holds the declared types being looked into: a cycle adds nothing.
fn runsDropBody(ctx: *const SemContext, ty: TypeId, path: []const SymbolId) bool {
    return switch (ctx.types.get(ty)) {
        .shared, .optional, .fallible => |i| runsDropBody(ctx, i, path),
        .array => |a| runsDropBody(ctx, a.elem, path),
        .imported_nominal => typeHasDropGlue(ctx, ty),
        .nominal => |sid| fieldsRunDropBody(ctx, sid, path),
        .parameterized_nominal => |pn| blk: {
            for (pn.args) |a| if (runsDropBody(ctx, a, path)) break :blk true;
            break :blk fieldsRunDropBody(ctx, pn.sym, path);
        },
        else => false,
    };
}

fn fieldsRunDropBody(ctx: *const SemContext, sid: SymbolId, path: []const SymbolId) bool {
    if (std.mem.findScalar(SymbolId, path, sid) != null) return false;
    // Past any real nesting depth, assume the worst.
    if (path.len >= 32) return true;
    var buf: [32]SymbolId = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = sid;
    const inner = buf[0 .. path.len + 1];
    const fields = ctx.symbols.items[sid].fields orelse return false;
    for (fields) |f| if (f.is_drop_method) return true;
    for (fields) |f| {
        if (f.is_method) continue;
        if (f.is_variant) {
            for (f.payload orelse &.{}) |pf| if (runsDropBody(ctx, pf.ty, inner)) return true;
        } else if (runsDropBody(ctx, f.ty, inner)) return true;
    }
    return false;
}

/// Whether `ty` is unique: declared `unique`, or a `Cell`, or holds one
/// of those inline (not behind a handle, a view, or a Vec's or Box's
/// heap memory). A copy of a Cell would fork the state it shares.
pub fn isUnique(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.unique or info.cell;
}

/// Whether a bare use of a value of `ty` moves it rather than copying
/// it: `yes` when it needs cleanup (`typeHasDropGlue`) or is unique
/// (`isUnique`), `depends` when it holds a type parameter by value
/// (`maybeDropGlue`), otherwise `no`.
pub fn moves(ctx: *const SemContext, ty: TypeId) Answer {
    const info = ctx.holds(ty);
    if (info.glue or isUnique(ctx, ty)) return .yes;
    return if (info.holds_type_var) .depends else .no;
}

/// Whether a read that copies nothing out (a `print` argument, an
/// argument a call reads before it runs, a branch of one) reads a value
/// of `ty` where it is, by address, so a later argument must not change
/// it first: a value that needs cleanup (`typeHasDropGlue`), a unique
/// one (which moves like an owner, so reading it in place lends it), or
/// one of a type parameter. Any other value is copied where the read
/// runs.
pub fn readByAddress(ctx: *const SemContext, ty: TypeId) bool {
    return typeHasDropGlue(ctx, ty) or maybeDropGlue(ctx, ty) or isUnique(ctx, ty);
}

/// Whether a value of `ty` may be copied implicitly: it does not move
/// (`moves`) and holds no write view (`!T`), of which there is only
/// one. `depends` when each instance decides.
pub fn copyable(ctx: *const SemContext, ty: TypeId) Answer {
    if (ctx.holds(ty).views.write) return .no;
    return switch (moves(ctx, ty)) {
        .no => .yes,
        .yes => .no,
        .depends => .depends,
    };
}

/// What `+x` does for an `x` of type `ty`.
pub const Clone = enum {
    /// Copies the value.
    copy,
    /// Bumps a handle's count: `*T`, `~T`, or an optional of one.
    bump,
    /// Copies a Text's bytes into a new Text.
    text,
    /// Copies the value, where each instance of the type parameters it
    /// holds is copied.
    depends,
    /// Makes a new owner part by part (`deepCloneable`): a Text's bytes
    /// and a Vec's elements copied, a box's value boxed again, a handle
    /// counted again, plain data and read views copied.
    deep,
    /// Cannot clone it.
    no,
};

/// What `+x` does for an `x` of type `ty`, which may be a view: a
/// clone reads the value the view reaches. A `![]T` cannot be cloned:
/// it is a write view of elements it does not own, and a copy would be a
/// second path to them.
pub fn cloneable(ctx: *const SemContext, ty: TypeId) Clone {
    if (writeSliceElem(ctx, ty) != null) return .no;
    const value = unwrapViews(ctx, ty);
    switch (ctx.types.get(value)) {
        .shared, .weak => return .bump,
        .text => return .text,
        .optional => |o| switch (ctx.types.get(o)) {
            .shared, .weak => return .bump,
            else => {},
        },
        else => {},
    }
    return switch (moves(ctx, value)) {
        .no => .copy,
        .yes => if (deepCloneable(ctx, value, null, &.{})) .deep else .no,
        .depends => .depends,
    };
}

/// The type arguments a generic type's field types are read with, and
/// the frame those arguments are read in.
const CloneFrame = struct { params: []const SymbolId, args: []const TypeId, parent: ?*const CloneFrame };

/// Whether `+x` can make a new owner of a `ty` part by part (Core
/// sentence 2): a Text, a Vec, a box, an optional, an array, or a
/// struct or enum declared in this module, of parts that clone; a
/// handle, counted again; plain data and read views, copied. A type with
/// a `drop` body has no clone, and neither has a unique type, a Cell, a
/// Signal, a write view, or a type parameter. `seen` holds the declared
/// types being checked: one reached again (a box of a recursive type)
/// clones if the rest of it does.
fn deepCloneable(ctx: *const SemContext, ty: TypeId, frame: ?*const CloneFrame, seen: []const SymbolId) bool {
    if (seen.len > 32) return false;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| {
            const f = frame orelse return false;
            const i = std.mem.findScalar(SymbolId, f.params, sym) orelse return false;
            return deepCloneable(ctx, f.args[i], f.parent, seen);
        },
        else => {},
    }
    const info = ctx.holds(ty);
    if (info.unique or info.cell or info.views.write or info.poison) return false;
    if (!info.glue and !info.holds_type_var) return true;
    return switch (ctx.types.get(ty)) {
        .text, .shared, .weak => true,
        .optional => |inner| deepCloneable(ctx, inner, frame, seen),
        .array => |a| deepCloneable(ctx, a.elem, frame, seen),
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.vec_sym_id or pn.sym == ctx.box_sym_id) break :blk pn.args.len == 1 and deepCloneable(ctx, pn.args[0], frame, seen);
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id) break :blk false;
            const sym = ctx.symbols.items[pn.sym];
            if (sym.kind != .generic_type or isProxy(sym)) break :blk false;
            const inner: CloneFrame = .{ .params = sym.type_params orelse &.{}, .args = pn.args, .parent = frame };
            break :blk fieldsCloneable(ctx, pn.sym, &inner, seen);
        },
        .nominal => |sym| fieldsCloneable(ctx, sym, null, seen),
        else => false,
    };
}

/// Whether every part of declared type `sym` clones (`deepCloneable`),
/// and it has no `drop` body.
fn fieldsCloneable(ctx: *const SemContext, sym: SymbolId, frame: ?*const CloneFrame, seen: []const SymbolId) bool {
    if (std.mem.findScalar(SymbolId, seen, sym) != null) return true;
    const s = ctx.symbols.items[sym];
    if (isProxy(s)) return false;
    var buf: [33]SymbolId = undefined;
    @memcpy(buf[0..seen.len], seen);
    buf[seen.len] = sym;
    const inner = buf[0 .. seen.len + 1];
    for (s.fields orelse &.{}) |*f| {
        if (f.is_drop_method) return false;
        for (dataFields(f)) |d| if (!deepCloneable(ctx, d.ty, frame, inner)) return false;
    }
    return true;
}

/// Whether a value of `ty` read through a view reads as the value
/// itself: a Copy primitive or a plain enum (`n + 1` with `n: ?Int` is
/// an `Int`).
pub fn readsAsValue(ctx: *const SemContext, ty: TypeId) bool {
    return isCopyPrimitive(ctx, ty) or isPlainEnum(ctx, ty);
}

/// The type parameters `ty` holds by value, appended to `out`.
pub fn heldTypeVars(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (!ctx.holds(ty).holds_type_var) return;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| if (std.mem.findScalar(SymbolId, out.items, sym) == null) try out.append(a, sym),
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
    foreign_ctx: *const SemContext,
    foreign_ty_id: TypeId,
    origin_module_id: u32,
) std.mem.Allocator.Error!TypeId {
    const ty = foreign_ctx.types.get(foreign_ty_id);
    switch (ty) {
        .invalid, .unknown, .void, .bool, .string, .text, .int, .float, .int_literal, .float_literal, .none_literal, .noreturn, .any_error, .ct_value => return local_ctx.intern(ty),
        inline .optional, .fallible, .read_view, .write_view, .shared, .weak, .range, .callable => |inner, tag| {
            const local_inner = try importType(local_ctx, foreign_ctx, inner, origin_module_id);
            return local_ctx.intern(@unionInit(Type, @tagName(tag), local_inner));
        },
        .slice => |s| return local_ctx.intern(.{ .slice = .{ .elem = try importType(local_ctx, foreign_ctx, s.elem, origin_module_id) } }),
        .array => |a| return local_ctx.intern(.{ .array = .{
            .elem = try importType(local_ctx, foreign_ctx, a.elem, origin_module_id),
            .len = try importType(local_ctx, foreign_ctx, a.len, origin_module_id),
        } }),
        .function => |f| {
            var params: std.ArrayList(TypeId) = .empty;
            defer params.deinit(local_ctx.allocator);
            for (f.params) |p| try params.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, p, origin_module_id));
            var ct: std.ArrayList(TypeId) = .empty;
            defer ct.deinit(local_ctx.allocator);
            for (f.ct_params) |p| try ct.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, p, origin_module_id));
            const ret = try importType(local_ctx, foreign_ctx, f.returns, origin_module_id);
            // A type or integer parameter's symbol is its proxy, which an
            // instance binds; a parameter of another type is given in
            // brackets and needs none.
            const syms = try local_ctx.arena.allocator().alloc(SymbolId, f.ct_syms.len);
            for (f.ct_syms, syms, 0..) |p, *out, i| {
                const slot = if (i < f.ct_params.len) foreign_ctx.types.get(f.ct_params[i]) else .invalid;
                out.* = if (p != symbol_invalid and (slot == .type_var or slot == .int)) try proxyOf(local_ctx, .{ .module_id = origin_module_id, .sym = p }) else symbol_invalid;
            }
            return local_ctx.internCopy(.{ .function = .{ .params = params.items, .returns = ret, .is_sub = f.is_sub, .ct_params = ct.items, .ct_syms = syms } });
        },
        // Every module has its own `Endian`, and they are one type.
        .nominal => |sym_id| return if (sym_id == foreign_ctx.endian_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.endian_sym_id })
        else
            local_ctx.intern(.{ .imported_nominal = .{ .module_id = origin_module_id, .sym_id = sym_id } }),
        .imported_nominal => |n| return local_ctx.intern(.{ .imported_nominal = n }),
        // A generic type of another module is its proxy's instance.
        .parameterized_nominal => |pn| {
            const sym = try proxyOf(local_ctx, .{ .module_id = origin_module_id, .sym = pn.sym });
            if (sym == symbol_invalid) return local_ctx.types.invalid_id;
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(local_ctx.allocator);
            for (pn.args) |a| try args.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, a, origin_module_id));
            return local_ctx.internCopy(.{ .parameterized_nominal = .{ .sym = sym, .args = args.items } });
        },
        inline .type_var, .ct_param => |sym, tag| {
            const p = try proxyOf(local_ctx, .{ .module_id = origin_module_id, .sym = sym });
            if (p == symbol_invalid) return local_ctx.types.invalid_id;
            return local_ctx.intern(@unionInit(Type, @tagName(tag), p));
        },
    }
}

/// The symbol here that stands for `ref`, a generic type or a type or
/// integer parameter of another module: its proxy, made on first use
/// (`importSymbol`), or the symbol itself for a built-in generic's,
/// which has the same id in every module. A proxy of a proxy is one of
/// the declaration itself, so every path to it gives one symbol here.
pub fn proxyOf(ctx: *SemContext, ref: ForeignRef) std.mem.Allocator.Error!SymbolId {
    const foreign = ctx.foreign_semas.get(ref.module_id) orelse return symbol_invalid;
    if (ref.sym >= foreign.symbols.items.len) return symbol_invalid;
    const fsym = foreign.symbols.items[ref.sym];
    if (fsym.decl_pos == builtin_decl_pos) return ref.sym;
    const origin = if (isProxy(fsym)) fsym.from else ref;
    if (ctx.imported.get(origin)) |id| return id;
    return importSymbol(ctx, origin);
}

/// Make the proxy of `origin`, a generic type or a type or integer
/// parameter declared in another module, which that module has checked
/// in full. The proxy is in no scope; the passes that read symbols by id
/// read it as they read the declaration. A generic type's proxy has the
/// declaration's contents, its parameters' proxies, and its members with
/// their types imported; a parameter's proxy has the requirements the
/// bodies that use it record (`importParam`).
fn importSymbol(ctx: *SemContext, origin: ForeignRef) std.mem.Allocator.Error!SymbolId {
    const foreign = ctx.foreign_semas.get(origin.module_id).?;
    const fsym = foreign.symbols.items[origin.sym];
    const a = ctx.arena.allocator();
    const generic = fsym.kind == .generic_type;
    const id = try ctx.addSymbol(.{
        // A generic type is named as this module spells it: `lib.Wrap`.
        .name = if (generic) try a.print("{s}.{s}", .{ foreign.name, fsym.name }) else fsym.name,
        .kind = fsym.kind,
        .ty = ctx.types.unknown_id,
        .decl_pos = imported_decl_pos,
        .scope = scope_invalid,
        .flags = .{ .is_public = fsym.flags.is_public, .comptime_known = fsym.flags.comptime_known },
        .contents = fsym.contents,
        .from = origin,
    });
    // Recorded first: the members of a generic type name the type.
    try ctx.imported.put(ctx.allocator, origin, id);
    if (!generic) {
        ctx.symbols.items[id].ty = try importType(ctx, foreign, fsym.ty, origin.module_id);
        try importParam(ctx, id, origin);
        return id;
    }
    const params = fsym.type_params orelse &.{};
    const tps = try a.alloc(SymbolId, params.len);
    for (params, tps) |tp, *out| out.* = try proxyOf(ctx, .{ .module_id = origin.module_id, .sym = tp });
    ctx.symbols.items[id].type_params = tps;
    const fields = fsym.fields orelse return id;
    const out = try a.alloc(Field, fields.len);
    for (fields, out) |f, *o| {
        o.* = f;
        o.ty = try importType(ctx, foreign, f.ty, origin.module_id);
        const payload = f.payload orelse continue;
        const typed = try a.alloc(Field, payload.len);
        for (payload, typed) |pf, *t| {
            t.* = pf;
            t.ty = try importType(ctx, foreign, pf.ty, origin.module_id);
        }
        o.payload = typed;
    }
    ctx.symbols.items[id].fields = out;
    return id;
}

/// Copy to `proxy` what the declaring module's bodies record about the
/// parameter `origin`: its requirements and the copies of its values,
/// with their positions there, and the generic instances, arrays, and
/// stack frames that mention it, which each instance made here makes
/// concrete (`expandInstantiations`) and checks.
fn importParam(ctx: *SemContext, proxy: SymbolId, origin: ForeignRef) std.mem.Allocator.Error!void {
    const foreign = ctx.foreign_semas.get(origin.module_id).?;
    const m = origin.module_id;
    const a = ctx.arena.allocator();
    for (foreign.generic_requirements.items) |r| if (r.param == origin.sym) {
        try ctx.generic_requirements.append(ctx.allocator, .{ .param = proxy, .req = r.req, .pos = r.pos, .op = r.op, .module_id = if (r.module_id == 0) m else r.module_id });
    };
    for (foreign.plain_reqs.items) |r| if (r.param == origin.sym) {
        try ctx.plain_reqs.append(ctx.allocator, .{ .param = proxy, .pos = r.pos, .element = r.element, .view = r.view, .module_id = if (r.module_id == 0) m else r.module_id });
    };
    for (foreign.paramEntries(.arrays, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .arrays, i)) continue;
        const g = foreign.generic_arrays.items[i];
        try ctx.addGeneric(.arrays, .{ .ty = try importType(ctx, foreign, g.ty, m), .pos = g.pos, .module_id = if (g.module_id == 0) m else g.module_id });
    }
    for (foreign.paramEntries(.frames, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .frames, i)) continue;
        const fr = foreign.generic_frames.items[i];
        const tys = try a.alloc(TypeId, fr.tys.len);
        for (fr.tys, tys) |t, *out| out.* = try importType(ctx, foreign, t, m);
        try ctx.addGeneric(.frames, .{ .label = fr.label, .pos = fr.pos, .tys = tys, .module_id = if (fr.module_id == 0) m else fr.module_id });
    }
    for (foreign.paramEntries(.fn_uses, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .fn_uses, i)) continue;
        const use = foreign.generic_fn_uses.items[i];
        const params = try a.alloc(SymbolId, use.params.len);
        for (use.params, params) |p, *out| out.* = try proxyOf(ctx, .{ .module_id = m, .sym = p });
        const args = try a.alloc(TypeId, use.args.len);
        for (use.args, args) |t, *out| out.* = try importType(ctx, foreign, t, m);
        // A module-level function is named as this module would call
        // it: `lib.helper[T]`; a method keeps its bare name.
        const name = if (isModuleFunction(foreign, use)) try a.print("{s}.{s}", .{ foreign.name, use.name }) else use.name;
        _ = try ctx.recordFnInstance(.{ .name = name, .params = params, .args = args, .own = use.own }, 0, null);
    }
    for (foreign.paramEntries(.uses, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .uses, i)) continue;
        try ctx.addGeneric(.uses, try importType(ctx, foreign, foreign.generic_uses.items[i], m));
    }
}

/// Whether `use`, an instance over parameters in module `ctx`, is of a
/// module-level function there rather than a method of the same name.
fn isModuleFunction(ctx: *const SemContext, use: FnInstance) bool {
    if (use.own == 0 or use.params.len != use.own) return false;
    const top = ctx.lookupInScopeOnly(module_scope, use.name) orelse return false;
    const sym = ctx.symbols.items[top];
    if (sym.kind != .function) return false;
    return switch (ctx.types.get(sym.ty)) {
        .function => |f| std.mem.findScalar(SymbolId, f.ct_syms, use.params[0]) != null,
        else => false,
    };
}

/// Whether entry `index` of module `module_id`'s `list` is copied here
/// for the first time.
fn firstImport(ctx: *SemContext, module_id: u32, list: @FieldType(ImportedEntry, "list"), index: usize) std.mem.Allocator.Error!bool {
    const gop = try ctx.imported_entries.getOrPut(ctx.allocator, .{ .module_id = module_id, .list = list, .index = @intCast(index) });
    return !gop.found_existing;
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

/// `Self` is `nominal(sym)` for plain types and `Wrap[T]` (applied to
/// its own parameters) for generic ones.
pub fn makeNominalContext(ctx: *SemContext, sym_id: SymbolId) std.mem.Allocator.Error!NominalContext {
    const sym = ctx.symbols.items[sym_id];
    switch (sym.kind) {
        .nominal_type => return .{ .sym = sym_id, .self_type = try ctx.intern(.{ .nominal = sym_id }), .type_params = &.{} },
        .generic_type => {
            const tparams = sym.type_params orelse &.{};
            const args = try ctx.arena.allocator().alloc(TypeId, tparams.len);
            for (tparams, 0..) |tp, i| args[i] = try ctx.intern(if (ctx.symbols.items[tp].kind == .param) .{ .ct_param = tp } else .{ .type_var = tp });
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

/// A data field of the receiver's nominal (auto-deref through views
/// and `*T`).
pub fn lookupDataField(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedField {
    const m = membersOf(ctx, unwrapAccess(ctx, receiver_ty)) orelse return null;
    // A box's `value` names its constructor argument, not a field.
    if (m.sym == ctx.box_sym_id) return null;
    for (m.fields) |f| {
        if (f.is_method or f.is_variant) continue;
        if (std.mem.eql(u8, f.name, name)) {
            return .{ .field = f, .ty = try substituteType(ctx, f.ty, m.subst), .nominal_sym = m.sym };
        }
    }
    return null;
}

/// Whether member access on `receiver_ty` reaches a data field `name`
/// (without substituting its type).
pub fn lookupDataFieldConst(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) ?Field {
    const decl = nominalDecl(ctx, unwrapAccess(ctx, receiver_ty)) orelse return null;
    if (decl.sym == decl.ctx.box_sym_id) return null;
    for (decl.symbol().fields orelse return null) |f| {
        if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// A callable method of the receiver's nominal (auto-deref through
/// views and `*T`, then through each box: a box's own `unbox` comes
/// before its value's methods). The user `drop` body is not callable.
pub fn lookupMethod(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedMethod {
    var t = unwrapReadAccess(ctx, receiver_ty);
    while (true) {
        if (try methodIn(ctx, t, name)) |found| return found;
        t = unwrapReadAccess(ctx, boxedType(ctx, t) orelse return null);
    }
}

/// How the method `name` that member access on `receiver_ty` reaches
/// takes its receiver; null when it names no method.
pub fn methodReceiver(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) ?MethodReceiver {
    const decl = nominalDecl(ctx, unwrapAccess(ctx, receiver_ty)) orelse return null;
    for (decl.symbol().fields orelse return null) |f| {
        if (f.is_method and !f.is_drop_method and std.mem.eql(u8, f.name, name)) return f.receiver;
    }
    return null;
}

fn methodIn(ctx: *SemContext, peeled: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedMethod {
    const m = membersOf(ctx, peeled) orelse return null;
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
    const subst = if (membersOf(ctx, unwrapViews(ctx, receiver_ty))) |m| m.subst else TypeSubst.empty;
    for (decl.symbol().fields orelse return null) |f| {
        if (!f.is_variant or !std.mem.eql(u8, f.name, name)) continue;
        var payload = f.payload orelse &.{};
        if (payload.len > 0 and (decl.module_id != null or !subst.isEmpty())) {
            const typed = try ctx.arena.allocator().dupe(Field, payload);
            for (typed) |*pf| pf.ty = if (decl.module_id) |origin|
                try importType(ctx, decl.ctx, pf.ty, origin)
            else
                try substituteType(ctx, pf.ty, subst);
            payload = typed;
        }
        return .{ .field = f, .payload = payload, .nominal_sym = if (decl.module_id == null) decl.sym else symbol_invalid, .owner_name = decl.symbol().name };
    }
    return null;
}

/// Whether member access on `receiver_ty` reaches a method `name` of its
/// type, local or imported.
pub fn hasMethodNamed(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) bool {
    return methodReceiver(ctx, receiver_ty, name) != null;
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
        .text => "Text",
        .int => |info| if (info.bits == 0) "Int" else try a.print("{c}{d}", .{ @as(u8, if (info.signed) 'I' else 'U'), info.bits }),
        .float => |info| if (info.bits == 0) "Float" else try a.print("F{d}", .{info.bits}),
        .int_literal => "Int",
        .float_literal => "Float",
        .none_literal => "none",
        .any_error => "error",
        .noreturn => "NoReturn",
        .optional => |inner| try formatSuffixed(ctx, a, inner, '?'),
        .fallible => |inner| try formatSuffixed(ctx, a, inner, '!'),
        .read_view => |inner| try a.print("?{s}", .{try formatTypeIn(ctx, a, inner)}),
        .callable => |f| try formatTypeIn(ctx, a, f),
        .write_view => |inner| try a.print("!{s}", .{try formatTypeIn(ctx, a, inner)}),
        .shared => |inner| try formatHandle(ctx, a, inner, '*'),
        .weak => |inner| try formatHandle(ctx, a, inner, '~'),
        .slice => |s| try a.print("[]{s}", .{try formatTypeIn(ctx, a, s.elem)}),
        .array => |arr| try a.print("[{s}]{s}", .{ try formatTypeIn(ctx, a, arr.len), try formatTypeIn(ctx, a, arr.elem) }),
        .range => |e| try a.print("range of {s}", .{try formatTypeIn(ctx, a, e)}),
        .function => |f| if (f.is_sub)
            try a.print("sub({s}){s}", .{ try formatTypeList(ctx, a, f.params), if (f.returns == ctx.types.void_id) "" else "!" })
        else
            try a.print("fun({s}) -> {s}", .{ try formatTypeList(ctx, a, f.params), try formatTypeIn(ctx, a, f.returns) }),
        .nominal => |sym| ctx.symbols.items[sym].name,
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk "<imported>";
            if (in.sym_id >= foreign.symbols.items.len) break :blk "<imported>";
            const name = foreign.symbols.items[in.sym_id].name;
            // Spelled the way this module names it: `other.Point`.
            for (ctx.imports) |imp| {
                if (imp.module_id == in.module_id) break :blk try a.print("{s}.{s}", .{ imp.local_name, name });
            }
            // A module reached only through an import, by its file name.
            break :blk try a.print("{s}.{s}", .{ foreign.name, name });
        },
        .parameterized_nominal => |pn| try a.print("{s}[{s}]", .{ ctx.symbols.items[pn.sym].name, try formatTypeList(ctx, a, pn.args) }),
        .type_var, .ct_param => |sym| ctx.symbols.items[sym].name,
        .ct_value => |v| try a.print("{d}", .{v.int}),
    };
}

/// Types separated by `, `.
fn formatTypeList(ctx: *const SemContext, a: std.mem.Allocator, ids: []const TypeId) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (ids, 0..) |id, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, try formatTypeIn(ctx, a, id));
    }
    return buf.items;
}

/// `T?` / `T!`. A handle binds tighter than a suffix (`*T?` is an
/// optional handle), so only a prefix type that a suffix cannot follow
/// takes parentheses: `(?T)?`, `([]Int)?`, `(*sub())?`; and so does an
/// optional of an optional, `(T?)?`.
fn formatSuffixed(ctx: *const SemContext, a: std.mem.Allocator, inner: TypeId, suffix: u8) ![]const u8 {
    const s = try formatTypeIn(ctx, a, inner);
    // `N??` would lex as the `??` operator: `(N?)?`.
    const doubled = suffix == '?' and ctx.types.get(inner) == .optional;
    return if (doubled or takesNoSuffix(ctx, inner))
        a.print("({s}){c}", .{ s, suffix })
    else
        a.print("{s}{c}", .{ s, suffix });
}

/// A type whose spelling a suffix cannot follow: a view (which covers
/// the suffix), a slice or array (whose element takes it), a function
/// type (`fun(Int) -> Int?` returns an optional), or a handle to one.
fn takesNoSuffix(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .function, .slice, .array => true,
        .shared, .weak => |inner| takesNoSuffix(ctx, inner),
        else => false,
    };
}

/// `*T` / `~T`, parenthesizing a suffixed operand: `*(T?)` is a handle
/// to an optional, while `*T?` is an optional handle.
fn formatHandle(ctx: *const SemContext, a: std.mem.Allocator, inner: TypeId, sigil: u8) ![]const u8 {
    const s = try formatTypeIn(ctx, a, inner);
    return switch (ctx.types.get(inner)) {
        // A handle binds tighter than a suffix, and takes no view prefix.
        .optional, .fallible, .read_view, .write_view => a.print("{c}({s})", .{ sigil, s }),
        else => a.print("{c}{s}", .{ sigil, s }),
    };
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

/// Call `f(context, part)` for each part of `e` that yields its value:
/// a block's last statement, a `raw` block's body, both branches of an
/// `if`, each arm of a `match`, the right of `??`, a `catch` handler,
/// and a loop's `else`. A bare name reached through these where the
/// value leaves (a binding, an argument, a result) leaves its binding:
/// emit takes it (`Scan.consumeTail`), and the ownership checker moves
/// it at that point, before the scopes the value leaves run their
/// defers. Nothing else yields a value through its parts.
pub fn eachTailPart(e: Sexp, context: anytype, comptime f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    switch (e.kind() orelse return) {
        .block => {
            const stmts = ir.Block.stmts(e);
            if (stmts.len > 0) try f(context, stmts[stmts.len - 1]);
        },
        .raw_block => try f(context, ir.RawBlock.body(e)),
        .@"if" => {
            try f(context, ir.If.then(e));
            if (ir.If.@"else"(e) != .nil) try f(context, ir.If.@"else"(e));
        },
        .match => for (ir.Match.arms(e)) |arm| try f(context, ir.Arm.body(arm)),
        .@"??" => try f(context, ir.@"??".right(e)),
        .@"catch" => try f(context, ir.Catch.handler(e)),
        .@"while", .@"for" => if (ir.get(e, .@"else") != .nil) try f(context, ir.get(e, .@"else")),
        .labeled => try f(context, ir.Labeled.stmt(e)),
        else => {},
    }
}

// =============================================================================
// The lend table
// =============================================================================

/// One row of the lend table (Core §4): a step from a value to a view of
/// it, or of what it holds.
pub const LendStep = enum(u8) {
    /// A `Box[T]` lends the views of its `T`.
    unbox,
    /// A `*T` lends the read views of its `T`.
    handle,
    /// An array or a Vec lends its elements, `[]T` to read and `![]T` to
    /// write.
    elems,
    /// A `Text` lends its bytes, a `String`.
    text,
    /// A `![]T` is lent on to read, as a `[]T`.
    read_only,
    /// An `X?` lends a `View?`: a view of the `X` inside, or `none`.
    optional,
    /// The view is lifted into an optional where a `View?` is expected.
    lift,
    /// A function, or an owned closure, lends a `?fun(...)`.
    callable,
};

/// How a view is lent from a value of another type: the rows of the
/// lend table, applied in order from the value (`lendsAs`). A lend with
/// no rows is the first row, `?T` of a `T`.
pub const Lend = struct {
    rows: [max_rows]LendStep = undefined,
    len: u8 = 0,
    /// The view the lend makes: the type its context expects.
    view: TypeId = type_invalid,
    /// The lend is not written: a bare value is lent to read where a
    /// view of it is expected, as `?e` would lend it (Core sentence 1).
    implicit: bool = false,
    /// `callable`: the function type the callable has.
    fn_ty: TypeId = type_invalid,

    pub const max_rows = 8;

    pub fn steps(self: *const Lend) []const LendStep {
        return self.rows[0..self.len];
    }

    pub fn has(self: Lend, step: LendStep) bool {
        return std.mem.findScalar(LendStep, self.rows[0..self.len], step) != null;
    }

    /// The function type a callable is lent as; null for any other lend.
    pub fn callable(self: Lend) ?TypeId {
        return if (self.has(.callable)) self.fn_ty else null;
    }

    /// Whether the lend only lifts the view the value is into an
    /// optional, which a value's type admits as it is (`compatible`).
    pub fn onlyLifts(self: Lend) bool {
        for (self.steps()) |step| if (step != .lift) return false;
        return true;
    }

    fn push(self: *Lend, step: LendStep) bool {
        if (self.len == max_rows) return false;
        self.rows[self.len] = step;
        self.len += 1;
        return true;
    }
};

/// Which lend: `?` to read, `!` to write.
pub const LendKind = enum { read, write };

/// The lend table (Core §4): how lending a value of type `from` to read
/// or to write (`kind`) makes a view of type `view`; null when no row
/// does. The one place that knows which views a value lends.
/// What a slice `xs[a..b]` of a value of type `from` lends, as rows of
/// the lend table (`Lend`): the elements of an array or a Vec, or a
/// Text's bytes reached through handles (`*Text`) and boxes, each a row
/// on the way; nothing of a value that is itself a view (a String, a
/// `[]T`), whose elements it views as that view does; a `![]T` lent on
/// to read. Null for a value that cannot be sliced. The type checker
/// slices by it and records it (`SemContext.sliceLendOf`), and the
/// ownership checker lends by the record.
pub fn sliceLend(ctx: *const SemContext, from: TypeId) ?Lend {
    var lend: Lend = .{};
    if (writeSliceElem(ctx, from) != null) {
        _ = lend.push(.read_only);
        return lend;
    }
    var t = unwrapViews(ctx, from);
    if (unwrapAccess(ctx, t) == ctx.types.text_id) {
        while (true) {
            switch (ctx.types.get(t)) {
                .read_view, .write_view => |inner| t = inner,
                .shared => |inner| {
                    if (!lend.push(.handle)) return null;
                    t = inner;
                },
                .text => {
                    _ = lend.push(.text);
                    return lend;
                },
                else => {
                    if (!lend.push(.unbox)) return null;
                    t = boxedType(ctx, t) orelse return null;
                },
            }
        }
    }
    switch (ctx.types.get(t)) {
        .string, .slice => return lend,
        .array => {
            _ = lend.push(.elems);
            return lend;
        },
        .parameterized_nominal => |pn| if (pn.sym == ctx.vec_sym_id) {
            _ = lend.push(.elems);
            return lend;
        },
        else => {},
    }
    return null;
}

pub fn lendsAs(ctx: *const SemContext, from: TypeId, kind: LendKind, view: TypeId) ?Lend {
    var lend: Lend = .{ .view = view };
    return if (lendRows(ctx, from, kind, view, &lend)) lend else null;
}

fn lendRows(ctx: *const SemContext, from: TypeId, kind: LendKind, view: TypeId, lend: *Lend) bool {
    const types = &ctx.types;
    // Any `T` lends `?T`, and `!T` to write; a write lend may be read.
    switch (types.get(view)) {
        .read_view => |t| if (t == from) return true,
        .write_view => |t| if (t == from and kind == .write) return true,
        else => {},
    }
    // A function, or an owned closure, lends a `?fun(...)`.
    if (callableFnTy(ctx, view)) |fn_ty| {
        const owned = switch (types.get(from)) {
            .shared => |inner| inner == fn_ty,
            else => false,
        };
        if (!owned and !(from == fn_ty and kind == .read)) return false;
        lend.fn_ty = fn_ty;
        return lend.push(.callable);
    }
    if (types.get(view) == .optional) {
        const want = types.get(view).optional;
        // An `X?` lends a `View?` for each view of `X`.
        if (types.get(from) == .optional) {
            var inner = lend.*;
            if (inner.push(.optional) and lendRows(ctx, types.get(from).optional, kind, want, &inner)) {
                lend.* = inner;
                return true;
            }
        }
        // A view where a `View?` is expected is lifted into it.
        var lifted = lend.*;
        if (lifted.push(.lift) and lendRows(ctx, from, kind, want, &lifted)) {
            lend.* = lifted;
            return true;
        }
        return false;
    }
    switch (types.get(from)) {
        // An array lends `[]T`, and `![]T` to write.
        .array => |a| return lendElems(ctx, a.elem, kind, view, lend),
        // A `![]T` is lent on to read as a `[]T`.
        .slice => |sl| if (kind == .write) switch (types.get(view)) {
            .slice => |v| return v.elem == sl.elem and lend.push(.read_only),
            else => {},
        },
        // A Text lends its bytes; never to write.
        .text => return kind == .read and view == types.string_id and lend.push(.text),
        // A `*T` lends the read views of its `T`; `!h` lends the handle.
        .shared => |inner| return kind == .read and lend.push(.handle) and lendRows(ctx, inner, .read, view, lend),
        else => {
            // A Vec lends its elements, as an array does.
            if (vecElem(ctx, from)) |elem| return lendElems(ctx, elem, kind, view, lend);
            // A box lends the views of its value.
            if (boxedType(ctx, from)) |inner| return lend.push(.unbox) and lendRows(ctx, inner, kind, view, lend);
        },
    }
    return false;
}

/// The elements of an array or a Vec of `elem`: `[]T` to read, `![]T`
/// to write.
fn lendElems(ctx: *const SemContext, elem: TypeId, kind: LendKind, view: TypeId, lend: *Lend) bool {
    const want = switch (kind) {
        .read => switch (ctx.types.get(view)) {
            .slice => |sl| sl.elem,
            else => return false,
        },
        .write => writeSliceElem(ctx, view) orelse return false,
    };
    return want == elem and lend.push(.elems);
}

/// The element type of the `[]T` a value of type `ty` lends (`lendsAs`):
/// an array's or a Vec's, reached through views, boxes, and handles;
/// null for any other type. Generic inference matches a `[]T` with it.
pub fn lentElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    var t = unwrapViews(ctx, ty);
    while (true) switch (ctx.types.get(t)) {
        .array => |a| return a.elem,
        .shared => |inner| t = inner,
        else => {
            if (vecElem(ctx, t)) |elem| return elem;
            t = boxedType(ctx, t) orelse return null;
        },
    };
}

/// `T` of a `Vec[T]`; null for any other type.
pub fn vecElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.vec_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

// =============================================================================
// What an expression hands over
// =============================================================================

/// What an expression hands over to the context that uses it (Core §9),
/// decided once, here, by a positive list of IR kinds (`handsOver`).
/// Every pass asks `handsOver`; none decides it again from syntax.
pub const Hands = struct {
    kind: Kind,

    pub const Kind = enum {
        /// Storage with an owner: a name of a binding or of a constant
        /// (a function, a module's constant, `Enum.variant`), or a field
        /// or element path from a place, a lend, or a view (`v`, `p.f`,
        /// `xs[i].f`, `(?v).f`, `mk_ref().f` where `mk_ref()` is a `?T`).
        place,
        /// A field or element path from a value that is no place: one
        /// made here, or a branching value (`mk().v[0]`, `[a, b][1]`,
        /// `(a if c else b).f`). The path's base is evaluated into a
        /// temporary, and the part lives only as long as it.
        part_of_made,
        /// A value made here: a call, a constructor, `+x`, `*x`, `~x`,
        /// `<x`, an array, a closure, an operator's result, a literal,
        /// `none`, an enum literal (`.red`), a `match`, a block, a loop's
        /// value, and a branching value whose every leaf is made here or
        /// jumps.
        made,
        /// `?x`, `!x`, and their slices (`?x[a..b]`): a view of `x`, lent
        /// here.
        lend,
        /// A value that is one of its operands (`a if c else b`,
        /// `a ?? b`, `e catch h`, `e!`, `e?`), at least one of whose
        /// leaves (`valueLeaves`) is not made here.
        branches,
        /// `return`, `break`, `continue`: no value reaches the context.
        jump,
        /// Not a value: a statement, a declaration, a type, a pattern.
        none,
    };

    /// The value is read from storage, not made for the context: a
    /// place, a part of a value made here, or a lend.
    pub fn hasStorage(h: Hands) bool {
        return switch (h.kind) {
            .place, .part_of_made, .lend => true,
            .made, .branches, .jump, .none => false,
        };
    }
};

/// What expression `node` hands over (`Hands`). It reads only the facts
/// sema records (`symbolOf`, `typeOf`, `instanceOf`), so every pass
/// after type checking gets the same answer.
pub fn handsOver(ctx: *const SemContext, node: Sexp) Hands {
    return handsOverIn(ctx.source, ctx, node);
}

/// `handsOver` in `source`, with the facts of `ctx` when there are any.
/// Without them (the ownership checker's own unit tests) every name is a
/// binding's and no type is known.
pub fn handsOverIn(source: []const u8, ctx: ?*const SemContext, node: Sexp) Hands {
    return .{ .kind = handsOverKind(source, ctx, node) };
}

fn handsOverKind(source: []const u8, ctx: ?*const SemContext, node: Sexp) Hands.Kind {
    switch (node) {
        .src => return leafHands(source, ctx, node),
        .list => {},
        else => return .none,
    }
    // `f[Int]`: a function's instance is a value; a type's is none.
    if (ctx) |c| if (c.instanceOf(node)) |inst| return if (inst == .function) .made else .none;
    return switch (shapeOf(source, node)) {
        .made => .made,
        .lend => .lend,
        .jump => .jump,
        .none => .none,
        .path => pathHands(source, ctx, node),
        .branches => {
            var parts = valueParts(node);
            while (parts.next()) |p| switch (handsOverKind(source, ctx, p.node)) {
                .made, .jump => {},
                .place, .part_of_made, .lend, .branches, .none => return .branches,
            };
            return .made;
        },
    };
}

/// A name or a literal.
fn leafHands(source: []const u8, ctx: ?*const SemContext, leaf: Sexp) Hands.Kind {
    const text = identAt(source, leaf) orelse return .none;
    const sym = (if (ctx) |c| c.symbolOf(leaf) else null) orelse {
        if (isLiteralLeafText(text) or std.mem.eql(u8, text, "none")) return .made;
        // A name sema could not resolve was reported; it stands for a
        // binding.
        return .place;
    };
    return switch (ctx.?.symbols.items[sym].kind) {
        .param, .local, .capture, .@"extern", .generic_param, .function => .place,
        .type_alias, .generic_type, .nominal_type, .module => .none,
    };
}

/// `p.f` or `p[i]`: by the base the path starts from.
fn pathHands(source: []const u8, ctx: ?*const SemContext, node: Sexp) Hands.Kind {
    var base = node;
    while (base.isKind(.member) or base.isKind(.index)) {
        const object = ir.get(base, .object);
        // `Enum.variant`, `Type.method`, `module.name`: a qualified
        // name, not a part of another value.
        if (base.isKind(.member)) if (ctx) |c| if (namesTypeOrModule(c, object)) return .place;
        base = object;
    }
    return switch (handsOverKind(source, ctx, base)) {
        .place, .lend => .place,
        // A path through a view reaches what the view views, not the
        // value made here that holds it.
        .made, .branches, .part_of_made => if (ctx) |c| (if (c.typeOf(base)) |ty| (if (isReadOrWriteView(c, ty)) .place else .part_of_made) else .part_of_made) else .part_of_made,
        .jump, .none => .none,
    };
}

/// A name of a type or module, or a generic type's instance
/// (`Vec[Int]`): it has no value of its own.
fn namesTypeOrModule(ctx: *const SemContext, e: Sexp) bool {
    if (ctx.instanceOf(e)) |inst| return inst == .type;
    const sym = ctx.symbolOf(e) orelse return false;
    return switch (ctx.symbols.items[sym].kind) {
        .type_alias, .generic_type, .nominal_type, .module => true,
        .function, .param, .local, .generic_param, .@"extern", .capture => false,
    };
}

/// A number, string, character, or Bool literal's text.
fn isLiteralLeafText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '"' or text[0] == '\'') return true;
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return true;
    return isIntLiteralText(text) or isFloatLiteralText(text);
}

/// What a list node is by its kind alone, the positive list `handsOver`
/// refines with the facts. Every IR kind is listed: a new one is a
/// compile error here until it is classified.
const Shape = enum { made, lend, jump, none, path, branches };

fn shapeOf(source: []const u8, node: Sexp) Shape {
    const tag = node.kind() orelse return .none;
    return switch (tag) {
        // Declarations and their parts.
        .module, .use, .fun, .sub, .@"struct", .@"enum", .errors, .generic_struct, .generic_enum, .type, .@"test", .@"pub", .@"extern", .extern_fun, .extern_sub, .zig_extern, .drop_decl, .@":", .default, .valued, .variant, .captures, .cap_clone, .cap_move, .cap_weak, .cap_read, .cap_write => .none,
        // Statements, and the parts of statements, conditions, and calls.
        .set, .drop, .pass, .@"defer", .@"errdefer", .as, .shadow, .shadow_fixed, .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"+%=", .@"-%=", .@"*%=", .@"&=", .@"|=", .@"^=", .@"<<=", .@">>=", .iter, .kwarg => .none,
        // Patterns and arms.
        .arm, .alt_pattern, .range_pattern, .variant_pattern => .none,
        // Types.
        .optional, .error_union, .read_view, .write_view, .shared, .slice, .generic_inst, .array_type, .fun_type, .fails, .unique, .fixed => .none,
        .@"return", .@"break", .@"continue" => .jump,
        .read, .write => .lend,
        .member, .index => .path,
        .@"if", .@"??", .@"catch", .propagate, .propagate_none => if (isBranchingForm(node)) .branches else .none,
        // A loop, labeled or not, is a value when a `break` leaves it
        // with one.
        .@"while", .@"for", .labeled => if (hasValueBreaks(source, node)) .made else .none,
        .call, .builtin, .inst, .lambda, .match, .block, .raw_block, .enum_lit, .array, .array_fill, .move, .clone, .share, .weak => .made,
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@">>", .@"and", .@"or", .@"..", .neg, .not => .made,
    };
}

/// Whether statement `s` gives a value: an expression, or a loop a
/// `break` leaves with one. A jump, a declaration, and a statement that
/// binds, assigns, or loops without a value give none.
pub fn yieldsValue(source: []const u8, s: Sexp) bool {
    return switch (s) {
        .src => true,
        .list => switch (shapeOf(source, s)) {
            .made, .lend, .path, .branches => true,
            .jump, .none => false,
        },
        else => false,
    };
}

/// One value a compound value may be (`valueParts`).
pub const ValuePart = struct {
    node: Sexp,
    via: Via,

    pub const Via = enum {
        /// The tail of an `if` branch, of a `match` arm, or of a block,
        /// which the value takes.
        tail,
        /// An operand of `??` or `catch` (its value, or its handler's
        /// tail), or the value of `e!`, which the value passes through.
        operand,
        /// The optional of `e?`: what the value gives is the value inside.
        unwrapped,
    };
};

/// The values `node` may be, one level down (`ValuePart`): the tails of
/// an `if` with an `else`, of each `match` arm, and of a block, and the
/// operands of `??`, `catch`, `e!`, and `e?`. None for any other node.
/// This is the one place that knows which forms yield one of their
/// parts.
pub fn valueParts(node: Sexp) ValueParts {
    return .{ .node = node };
}

pub const ValueParts = struct {
    node: Sexp,
    i: usize = 0,

    pub fn next(self: *ValueParts) ?ValuePart {
        const e = self.node;
        const i = self.i;
        self.i += 1;
        return switch (e.kind() orelse return null) {
            .@"if" => if (ir.If.@"else"(e) == .nil) null else switch (i) {
                0 => .{ .node = tailOf(ir.If.then(e)), .via = .tail },
                1 => .{ .node = tailOf(ir.If.@"else"(e)), .via = .tail },
                else => null,
            },
            .match => {
                const arms = ir.Match.arms(e);
                return if (i < arms.len) .{ .node = tailOf(ir.Arm.body(arms[i])), .via = .tail } else null;
            },
            .block => if (i == 0 and ir.Block.stmts(e).len > 0) .{ .node = tailOf(e), .via = .tail } else null,
            .@"??" => switch (i) {
                0 => .{ .node = ir.@"??".left(e), .via = .operand },
                1 => .{ .node = ir.@"??".right(e), .via = .operand },
                else => null,
            },
            .@"catch" => switch (i) {
                0 => .{ .node = ir.Catch.value(e), .via = .operand },
                1 => .{ .node = tailOf(ir.Catch.handler(e)), .via = .operand },
                else => null,
            },
            .propagate => if (i == 0) .{ .node = ir.Propagate.value(e), .via = .operand } else null,
            .propagate_none => if (i == 0) .{ .node = ir.PropagateNone.value(e), .via = .unwrapped } else null,
            else => null,
        };
    }
};

/// The leaves a read of `node` reaches, appended to `out`: through a
/// branching value (`a if c else b`, `a ?? b`, `e catch h`, `e!`, `e?`),
/// the leaves of each operand in turn; any other node is its own leaf. A
/// `match` or a block is a value made here, so a read stops there.
pub fn valueLeaves(a: std.mem.Allocator, node: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    if (isBranchingForm(node)) {
        var parts = valueParts(node);
        while (parts.next()) |p| try valueLeaves(a, p.node, out);
        return;
    }
    try out.append(a, node);
}

/// A value that is one of its operands: `a if c else b`, `a ?? b`,
/// `e catch h`, `e!`, or `e?`. An `if` without an `else` is a statement.
fn isBranchingForm(node: Sexp) bool {
    return switch (node.kind() orelse return false) {
        .@"if" => ir.If.@"else"(node) != .nil,
        .@"??", .@"catch", .propagate, .propagate_none => true,
        else => false,
    };
}

/// The expression whose value a branch or block gives: a block's last
/// statement, or the branch itself; `.nil` for an empty block.
pub fn tailOf(s: Sexp) Sexp {
    if (s.isKind(.block)) {
        const stmts = ir.Block.stmts(s);
        if (stmts.len == 0) return .nil;
        return tailOf(stmts[stmts.len - 1]);
    }
    return s;
}

/// Whether `e`'s value is one of its parts: it yields through them
/// (`yieldsThroughParts`), or it is a branching value (`e!`, `e?`).
pub fn yieldsPart(e: Sexp) bool {
    return yieldsThroughParts(e) or isBranchingForm(e);
}

/// Whether `e` yields its value through parts (`eachTailPart`).
pub fn yieldsThroughParts(e: Sexp) bool {
    return switch (e.kind() orelse return false) {
        .block, .raw_block, .@"if", .match, .@"??", .@"catch", .@"while", .@"for", .labeled => true,
        else => false,
    };
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
    value: Wide,
    not_constant,
    /// Constant, but too large to compute.
    overflow,
};

/// The value of a constant integer expression in checked code: literals,
/// constant bindings, and arithmetic on them.
pub fn constInt(ctx: *const SemContext, e: Sexp) ConstInt {
    return constIntBy(ctx, e, CheckedNames{ .ctx = ctx });
}

/// What `ctFoldBy` knows of checked code, from the facts the checker
/// recorded: the symbol a name is, a constant binding's value (known once
/// its declaration is checked) and an imported constant's (`lib.N`), and
/// the type literal arithmetic was given. The values are untyped here:
/// the checker gives constant arithmetic its type.
const CheckedNames = struct {
    ctx: *const SemContext,

    pub fn symbol(self: CheckedNames, e: Sexp) ?SymbolId {
        return self.ctx.symbolOf(e) orelse self.ctx.lookupInScopeOnly(module_scope, identAt(self.ctx.source, e) orelse return null);
    }

    pub fn name(self: CheckedNames, e: Sexp) ?TypedInt {
        const id = self.ctx.symbolOf(e) orelse return null;
        return if (self.ctx.const_ints.get(id)) |c| .{ .v = c.value } else null;
    }

    /// `lib.N`: another module's integer constant.
    pub fn member(self: CheckedNames, e: Sexp) ?TypedInt {
        const obj = ir.Member.object(e);
        if (obj != .src) return null;
        const id = self.symbol(obj) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        const foreign = self.ctx.foreign_semas.get(self.ctx.module_refs.get(id) orelse return null) orelse return null;
        const fid = foreign.lookupInScopeOnly(module_scope, identAt(self.ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
        const c = foreign.const_ints.get(fid) orelse return null;
        return .{ .v = c.value };
    }

    pub fn literalInt(self: CheckedNames, e: Sexp) ?IntInfo {
        return switch (self.ctx.types.get(self.ctx.typeOf(e) orelse return null)) {
            .int => |i| i,
            else => null,
        };
    }
};

/// `constInt` with what `names` knows (`ctFoldBy`).
pub fn constIntBy(ctx: *const SemContext, e: Sexp, names: anytype) ConstInt {
    return switch (ctFoldBy(ctx, e, names)) {
        .value => |t| .{ .value = t.v },
        .not_constant, .mismatch => .not_constant,
        .overflow => .overflow,
    };
}

/// A module or local integer constant: its value and its type.
pub const ConstVal = struct { value: Wide, int: IntInfo = .{} };

/// A folded integer and its type; `int` is null for arithmetic on
/// literals alone, which takes the type it is used as.
pub const TypedInt = struct { v: Wide, int: ?IntInfo = null };

/// A constant integer expression folded with its types, as constant
/// arithmetic is checked: each operation is in the type of its typed
/// operands, and its value must fit that type.
pub const CtFold = union(enum) {
    value: TypedInt,
    not_constant,
    /// `node`'s value does not fit its type `int`, or (untyped) is too
    /// large to compute.
    overflow: struct { node: Sexp, int: ?IntInfo },
    /// `node` combines constants of two integer types.
    mismatch: struct { node: Sexp, a: IntInfo, b: IntInfo },
};

/// The one constant evaluator: the value of a constant integer
/// expression, for module and local constants, array lengths,
/// compile-time arguments, and enum values. It reads the program only
/// through `names`, which answers for the context the expression is in:
/// `symbol(leaf) ?SymbolId`, the declaration a name is; `name(leaf)`
/// and `member(e)`, each a `?TypedInt`, the value of a constant and of
/// another module's (`lib.N`); and `literalInt(e) ?IntInfo`, the integer
/// type arithmetic on literals alone is computed in (for a wrapping
/// operation or a shift).
pub fn ctFoldBy(ctx: *const SemContext, e: Sexp, names: anytype) CtFold {
    switch (e) {
        .src => {
            const text_ = identAt(ctx.source, e) orelse "";
            if (isIntLiteralText(text_)) return if (std.fmt.parseInt(Wide, text_, 0)) |v| .{ .value = .{ .v = v } } else |_| .{ .overflow = .{ .node = e, .int = null } };
            return if (names.name(e)) |t| .{ .value = t } else .not_constant;
        },
        .list => {
            const h = e.kind() orelse return .not_constant;
            // `U8(k)` (or `Byte(k)` of an alias) of a constant integer: a
            // constant of the target type, which must hold it.
            if (h == .call) {
                const args = ir.Call.args(e);
                if (args.len != 1 or args[0].isKind(.kwarg)) return .not_constant;
                const info = intTypeBy(ctx, ir.Call.callee(e), names) orelse return .not_constant;
                const a = switch (ctFoldBy(ctx, args[0], names)) {
                    .value => |t| t,
                    else => |r| return r,
                };
                if (!intInfoFits(info, a.v)) return .{ .overflow = .{ .node = args[0], .int = info } };
                return .{ .value = .{ .v = a.v, .int = info } };
            }
            if (h == .member) {
                if (intLimitBy(ctx, e, names)) |t| return .{ .value = t };
                return if (names.member(e)) |t| .{ .value = t } else .not_constant;
            }
            if (h == .neg) {
                const a = switch (ctFoldBy(ctx, ir.Neg.operand(e), names)) {
                    .value => |t| t,
                    else => |r| return r,
                };
                const v = std.math.negate(a.v) catch return .{ .overflow = .{ .node = e, .int = a.int } };
                return typedResult(e, v, a.int);
            }
            // `a if c else b` with a constant condition: Zig picks the
            // branch at compile time, so its value is constant.
            if (h == .@"if" and ir.If.@"else"(e) != .nil) {
                const c = constBoolBy(ctx, ir.If.cond(e), names) orelse return .not_constant;
                return ctFoldBy(ctx, if (c) ir.If.then(e) else ir.If.@"else"(e), names);
            }
            switch (h) {
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"<<", .@">>", .@"&", .@"|", .@"^" => {},
                else => return .not_constant,
            }
            const a = switch (ctFoldBy(ctx, ir.get(e, .left), names)) {
                .value => |t| t,
                else => |r| return r,
            };
            const b = switch (ctFoldBy(ctx, ir.get(e, .right), names)) {
                .value => |t| t,
                else => |r| return r,
            };
            // A shift is in its left operand's type.
            const shift = h == .@"<<" or h == .@">>";
            if (!shift) if (a.int) |ai| if (b.int) |bi| if (!std.meta.eql(ai, bi)) return .{ .mismatch = .{ .node = e, .a = ai, .b = bi } };
            const int = if (shift) a.int orelse names.literalInt(e) else a.int orelse b.int;
            // Wrapping arithmetic keeps the low bits of the result in its
            // type, which a `Wide` computes exactly (its width is a
            // multiple of every integer type's). Literals alone wrap in
            // the type their context gives them; without one, the width
            // is not known here, so the program computes it.
            switch (h) {
                .@"+%", .@"-%", .@"*%" => {
                    const info = int orelse names.literalInt(e) orelse return .not_constant;
                    const v = switch (h) {
                        .@"+%" => a.v +% b.v,
                        .@"-%" => a.v -% b.v,
                        else => a.v *% b.v,
                    };
                    return .{ .value = .{ .v = wrapTo(info, v), .int = info } };
                },
                else => {},
            }
            const v: ?Wide = switch (h) {
                .@"+" => std.math.add(Wide, a.v, b.v) catch null,
                .@"-" => std.math.sub(Wide, a.v, b.v) catch null,
                .@"*" => std.math.mul(Wide, a.v, b.v) catch null,
                // Division by zero and negative shift amounts are
                // reported where the operator is checked.
                .@"/" => if (b.v == 0) return .not_constant else std.math.divTrunc(Wide, a.v, b.v) catch null,
                .@"%" => if (b.v == 0) return .not_constant else if (b.v == -1) 0 else @rem(a.v, b.v),
                // A shift by the width or more is reported where the
                // operator is checked; one that loses bits overflows.
                .@"<<" => if (b.v < 0 or b.v >= (int orelse IntInfo{}).width()) return .not_constant else blk: {
                    const r = a.v << @intCast(b.v);
                    break :blk if (r >> @intCast(b.v) == a.v) r else null;
                },
                .@">>" => if (b.v < 0 or b.v >= (int orelse IntInfo{}).width()) return .not_constant else a.v >> @intCast(b.v),
                .@"&" => a.v & b.v,
                .@"|" => a.v | b.v,
                else => a.v ^ b.v,
            };
            return typedResult(e, v orelse return .{ .overflow = .{ .node = e, .int = int } }, int);
        },
        else => return .not_constant,
    }
}

/// The integer type a built-in type name spells (`Int`, `U8`, `I128`),
/// or null.
pub fn intTypeNamed(name: []const u8) ?IntInfo {
    if (std.mem.eql(u8, name, "Int")) return .{};
    if (name.len < 2 or (name[0] != 'I' and name[0] != 'U') or name[1] == '0') return null;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    return switch (bits) {
        8, 16, 32, 128 => .{ .bits = bits, .signed = name[0] == 'I' },
        64 => if (name[0] == 'I') .{} else .{ .bits = 64, .signed = false },
        else => null,
    };
}

/// The integer type the type alias `id` names, through other aliases;
/// null for any other type. Known before the alias is resolved, too.
pub fn aliasIntType(ctx: *const SemContext, id: SymbolId) ?IntInfo {
    var c = ctx;
    var alias = id;
    // An alias chain longer than this is a cycle, reported elsewhere.
    for (0..64) |_| {
        const sym = c.symbols.items[alias];
        if (sym.kind != .type_alias) return null;
        if (sym.ty != c.types.unknown_id) return switch (c.types.get(sym.ty)) {
            .int => |i| i,
            else => null,
        };
        const target = c.alias_targets.get(alias) orelse return null;
        // `module.Name`: another module's public alias.
        if (target.isKind(.member)) {
            const m = ir.Member.object(target);
            if (m != .src) return null;
            const module = c.lookup(sym.scope, identAt(c.source, m) orelse return null) orelse return null;
            if (c.symbols.items[module].kind != .module) return null;
            const foreign = c.foreign_semas.get(c.module_refs.get(module) orelse return null) orelse return null;
            alias = foreign.lookupInScopeOnly(module_scope, identAt(c.source, ir.Member.name(target)) orelse return null) orelse return null;
            if (!foreign.symbols.items[alias].flags.is_public) return null;
            c = foreign;
            continue;
        }
        const name = identAt(c.source, target) orelse return null;
        if (intTypeNamed(name)) |i| return i;
        alias = c.lookup(sym.scope, name) orelse return null;
    }
    return null;
}

/// `U8.max`, `Int.min`: an integer type's limit, a constant of it, named
/// through the type or an alias of it, this module's or another's
/// (`util.Byte.max`). Null for anything else.
pub fn intLimit(ctx: *const SemContext, e: Sexp) ?TypedInt {
    return intLimitBy(ctx, e, CheckedNames{ .ctx = ctx });
}

fn intLimitBy(ctx: *const SemContext, e: Sexp, names: anytype) ?TypedInt {
    const info = intTypeBy(ctx, ir.Member.object(e), names) orelse return null;
    const field = identAt(ctx.source, ir.Member.name(e)) orelse return null;
    const r = intRange(info);
    if (std.mem.eql(u8, field, "min")) return .{ .v = r.min, .int = info };
    if (std.mem.eql(u8, field, "max")) return .{ .v = r.max, .int = info };
    return null;
}

/// The integer type `e` names: a built-in one (`U8`), or an alias of
/// one, this module's (`Byte`) or an imported one (`lib.Byte`).
fn intTypeBy(ctx: *const SemContext, e: Sexp, names: anytype) ?IntInfo {
    switch (e) {
        .src => return if (names.symbol(e)) |id| aliasIntType(ctx, id) else intTypeNamed(identAt(ctx.source, e) orelse return null),
        .list => {
            if (!e.isKind(.member) or ir.Member.object(e) != .src) return null;
            const module = names.symbol(ir.Member.object(e)) orelse return null;
            if (ctx.symbols.items[module].kind != .module) return null;
            const foreign = ctx.foreign_semas.get(ctx.module_refs.get(module) orelse return null) orelse return null;
            const alias = foreign.lookupInScopeOnly(module_scope, identAt(ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
            if (!foreign.symbols.items[alias].flags.is_public) return null;
            return aliasIntType(foreign, alias);
        },
        else => return null,
    }
}

/// `v` wrapped into integer type `info`: its low bits, read as the
/// type reads them.
pub fn wrapTo(info: IntInfo, v: Wide) Wide {
    const modulus = @as(Wide, 1) << @intCast(info.width());
    const low = @mod(v, modulus);
    return if (info.signed and low >= modulus >> 1) low - modulus else low;
}

fn typedResult(e: Sexp, v: Wide, int: ?IntInfo) CtFold {
    if (int) |i| if (!intInfoFits(i, v)) return .{ .overflow = .{ .node = e, .int = i } };
    return .{ .value = .{ .v = v, .int = int } };
}

/// Whether an integer type holds `v`.
pub fn intInfoFits(info: IntInfo, v: Wide) bool {
    const r = intRange(info);
    return v >= r.min and v <= r.max;
}

/// The least and greatest values of an integer type.
pub fn intRange(info: IntInfo) struct { min: Wide, max: Wide } {
    const half = @as(Wide, 1) << @intCast(info.width() - 1);
    return if (info.signed) .{ .min = -half, .max = half - 1 } else .{ .min = 0, .max = 2 * half - 1 };
}

/// `constInt` as an optional: null when not constant or too large.
pub fn constIntOf(ctx: *const SemContext, e: Sexp) ?Wide {
    return switch (constInt(ctx, e)) {
        .value => |v| v,
        else => null,
    };
}

/// The value of a constant Bool expression: literals, `not`, `and`,
/// `or`, and comparisons of constant integers (`ctFoldBy`).
fn constBoolBy(ctx: *const SemContext, e: Sexp, names: anytype) ?bool {
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
                .not => return !(constBoolBy(ctx, ir.Not.operand(e), names) orelse return null),
                .@"and" => return (constBoolBy(ctx, ir.And.left(e), names) orelse return null) and (constBoolBy(ctx, ir.And.right(e), names) orelse return null),
                .@"or" => return (constBoolBy(ctx, ir.Or.left(e), names) orelse return null) or (constBoolBy(ctx, ir.Or.right(e), names) orelse return null),
                .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => {
                    const a = switch (constIntBy(ctx, ir.get(e, .left), names)) {
                        .value => |v| v,
                        else => return null,
                    };
                    const b = switch (constIntBy(ctx, ir.get(e, .right), names)) {
                        .value => |v| v,
                        else => return null,
                    };
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
/// `(read self)`, `(write self)`, `(move self)`, or a bare name.
pub fn paramNameNode(param: Sexp) ?Sexp {
    return switch (param.kind() orelse return if (param == .src) param else null) {
        .@":", .default => ir.get(param, .name),
        .read, .write, .move => ir.get(param, .operand),
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

pub const CaptureMode = enum { cap_clone, cap_weak, cap_move, cap_read, cap_write };

pub fn captureModeOf(cap: Sexp) ?CaptureMode {
    return switch (cap.kind() orelse return null) {
        .cap_clone => .cap_clone,
        .cap_weak => .cap_weak,
        .cap_move => .cap_move,
        .cap_read => .cap_read,
        .cap_write => .cap_write,
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
    return std.mem.findAny(u8, text, ".eE") != null;
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
        while (std.mem.findPos(u8, self.source, i, needle)) |p| : (i = p + 1) {
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
        return self.ctx.facts.types.get(self.at(needle, nth));
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

/// Every node with head `tag`, depth first, in source order.
fn findNodes(node: Sexp, tag: Tag, out: *std.ArrayList(Sexp)) !void {
    if (node.kind() == tag) try out.append(std.testing.allocator, node);
    if (node != .list) return;
    for (node.items()) |c| try findNodes(c, tag, out);
}

test "storage: a header points at a place its temporaries reach, never into one" {
    const source =
        \\enum E
        \\  a(n: Int)
        \\  b
        \\
        \\struct S
        \\  e: E
        \\  xs: [3]Int
        \\  o: Int?
        \\  t: Text
        \\
        \\fun mk() -> S
        \\  S(e: E.a(n: 1), xs: [1, 2, 3], o: 7, t: Text("p"))
        \\
        \\fun id(s: ?S) -> ?S from s
        \\  s
        \\
        \\fun idx(s: String) -> Int
        \\  s.len - 1
        \\
        \\fun get(v: !Vec[S]) -> !Vec[S] from v
        \\  v
        \\
        \\fun mkh(n: Int) -> *S
        \\  *S(e: E.a(n: n), xs: [n, n, n], o: n, t: Text("p"))
        \\
        \\fun idh(s: ?*S) -> ?S from s
        \\  s
        \\
        \\sub main()
        \\  v: Vec[S] = Vec()
        \\  !v.push(mk())
        \\  match v[idx(?Text("a"))].e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  match !get(!v)[idx(?Text("a"))].e
        \\    .a(n) => n = 2
        \\    .b => print(0)
        \\  match id(?mk()).e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  match (?mk()).e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  for x in id(?mk()).xs
        \\    print(x)
        \\  for x in !v[idx(?Text("a"))].xs
        \\    x = 0
        \\  if id(?mk()).o as n
        \\    print(n)
        \\  if !v[idx(?Text("a"))].o as n
        \\    n = 1
        \\  while id(?mk()).o as n
        \\    print(n)
        \\  match idh(?mkh(4)).e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  for x in idh(?mkh(4)).xs
        \\    print(x)
        \\
    ;
    var r: FactsRun = .{ .p = parser.Parser.init(std.testing.allocator, source), .tree = undefined, .ctx = undefined, .source = source };
    defer r.p.deinit();
    r.tree = try r.p.parseProgram();
    r.ctx = try check(std.testing.allocator, source, r.tree, .{});
    defer r.ctx.deinit();
    var headers: std.ArrayList(Sexp) = .empty;
    defer headers.deinit(std.testing.allocator);
    for ([_]Tag{ .match, .@"for", .as }) |tag| try findNodes(r.tree, tag, &headers);
    // A place reached through an index's temporary: the header points.
    // A place inside a view of a value the header makes, a call's or a
    // handle's: it copies (a header pointing into its own temporary
    // would read it after the header drops it).
    const points = [_]bool{ true, true, false, false, false, false, true, false, false, true, false };
    try std.testing.expectEqual(points.len, headers.items.len);
    for (headers.items, points) |h, want| {
        try std.testing.expectEqual(want, storage.headerPoints(&r.ctx, storage.headerSubject(h)));
        try std.testing.expectEqual(!want, r.ctx.copiesHeader(h));
        if (h.isKind(.match) and storage.matchMode(&r.ctx, h) == .read) try std.testing.expectEqual(want, storage.matchesInPlace(&r.ctx, h));
    }
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
    try std.testing.expectEqual(@as(Wide, 5), r.ctx.const_ints.get(r.sym("a", 0).?).?.value);
    try std.testing.expectEqual(@as(Wide, 20), r.ctx.const_ints.get(r.sym("b", 0).?).?.value);
    try std.testing.expect(r.ctx.symbols.items[r.sym("c", 0).?].flags.reassigned);
    try std.testing.expect(r.ctx.const_ints.get(r.sym("c", 0).?) == null);
    try std.testing.expect(r.ctx.const_ints.get(r.sym("d", 0).?) == null);
    try std.testing.expect(r.ctx.symbols.items[r.sym("d", 0).?].flags.written);
}

test "facts: a match covering every value without a default arm is exhaustive" {
    var r = try factsRun(
        \\sub main()
        \\  b = true
        \\  match b
        \\    true => print(1)
        \\    false => print(2)
        \\  n = 3
        \\  match n
        \\    1 => print(1)
        \\    _ => print(0)
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
        \\  const s = "hi"
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
        \\  for x in ?v
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

test "origins: a result carries what could hold what it views" {
    var r = try factsRun(
        \\struct Item
        \\  n: Int
        \\
        \\struct Holder
        \\  r: []Int
        \\
        \\fun at(v: ?[4]Item, k: !Int) -> ?Item
        \\  k += 1
        \\  ?v[0]
        \\
        \\fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int]
        \\  a
        \\
        \\fun pick(s: String, t: ?Text, n: Int, u: ?Item) -> String
        \\  s
        \\
        \\sub fill(h: !Holder, x: []Int, k: Int, s: String)
        \\  h.r = x
        \\
        \\fun same[T](a: ?T, k: Int) -> ?T
        \\  a
        \\
    );
    defer r.deinit();
    const o = struct {
        fn of(run: *const FactsRun, name: []const u8) Origins {
            return run.ctx.symbols.items[run.sym(name, 0).?].origins;
        }
    }.of;
    try std.testing.expectEqual(@as(ParamMask, 0b01), o(&r, "at").result);
    try std.testing.expectEqual(@as(ParamMask, 0), o(&r, "at").stores);
    try std.testing.expectEqual(@as(ParamMask, 0b11), o(&r, "first").result);
    try std.testing.expectEqual(@as(ParamMask, 0b0011), o(&r, "pick").result);
    // `fill` may store `x` in `h.r`; a number or a String it cannot.
    try std.testing.expectEqual(@as(ParamMask, 0b0011), o(&r, "fill").stores);
    // A type parameter could be anything, but a value taken by value is
    // the callee's own.
    try std.testing.expectEqual(@as(ParamMask, 0b01), o(&r, "same").result);
}

test "origins: a view reached through a read view is that view's" {
    var r = try factsRun(
        \\struct Item
        \\  n: Int
        \\
        \\struct Cursor
        \\  items: ?Vec[Item]
        \\  i: Int
        \\
        \\struct Owner
        \\  items: ?Vec[Item]
        \\  scratch: Vec[Item]
        \\
        \\struct Writer
        \\  items: ![]Item
        \\
        \\struct Cut
        \\  before: String
        \\
        \\struct Keeps
        \\  t: ?Text
        \\
        \\struct Edits
        \\  t: !Text
        \\
        \\struct Shared
        \\  item: *Item
        \\
        \\struct Boxed
        \\  b: Box[Item]
        \\
        \\enum Maybe
        \\  one(item: ?Item)
        \\  two(item: Item)
        \\
    );
    defer r.deinit();
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ty = struct {
        fn of(run: *FactsRun, name: []const u8) TypeId {
            return run.ctx.intern(.{ .nominal = run.sym(name, 0).? }) catch unreachable;
        }
    }.of;
    const item = ty(&r, "Item");
    const view = try r.ctx.intern(.{ .read_view = item });
    const write = try r.ctx.intern(.{ .write_view = item });
    const string = r.ctx.types.string_id;
    const reach = struct {
        fn of(run: *FactsRun, al: std.mem.Allocator, h: TypeId, v: TypeId) !ViewReach {
            return viewReach(&run.ctx, al, h, v);
        }
    }.of;
    const al = arena.allocator();
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Cursor"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Owner"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Writer"), write));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, item, view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, r.ctx.types.int_id, view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, string, view));
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Cut"), string));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, r.ctx.types.text_id, string));
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Keeps"), string));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Edits"), string));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Shared"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Boxed"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Maybe"), view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, ty(&r, "Cut"), view));
}

test "facts: a checked call records what fills each parameter" {
    var r = try factsRun(
        \\struct Acc
        \\  n: Int
        \\
        \\  fun add(?self, k: Int, by: Int = 1) -> Int
        \\    self.n + k * by
        \\
        \\fun scaled(n: Int, by: Int = 10) -> Int
        \\  n * by
        \\
        \\sub main()
        \\  a = Acc(n: 1)
        \\  print(a.add(by: 2, k: 3))
        \\  print(scaled(4))
        \\
    );
    defer r.deinit();
    const main_body = ir.Block.stmts(ir.Sub.body(ir.Module.decls(r.tree)[2]));
    // A constructor is checked by its fields, not a signature.
    try std.testing.expect(r.ctx.callParamsOf(ir.Set.value(main_body[0])) == null);
    const method = r.ctx.callParamsOf(ir.Call.args(main_body[1])[0]).?;
    try std.testing.expectEqual(@as(usize, 3), method.fills.len);
    try std.testing.expect(method.fills[0] == .receiver);
    try std.testing.expectEqual(@as(u32, 1), method.fills[1].arg);
    try std.testing.expectEqual(@as(u32, 0), method.fills[2].arg);
    const plain = r.ctx.callParamsOf(ir.Call.args(main_body[2])[0]).?;
    try std.testing.expectEqual(@as(u32, 0), plain.fills[0].arg);
    try std.testing.expect(plain.fills[1] == .default);
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
        \\  const y = 2
        \\  show[y]()
        \\  print(read(?U(n: y)))
        \\
    );
    defer r.deinit();
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
    try std.testing.expect(x == .read_view);
    try std.testing.expectEqual(IntInfo{ .bits = 32, .signed = true }, r.ctx.types.get(x.read_view).int);
    const u64_ty = try r.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } });
    try std.testing.expectEqual(try r.ctx.intern(.{ .write_view = u64_ty }), b.params[1]);
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

test "check: a long chain of types each holding the next by value" {
    // Each walk over what a type holds runs once per type, not nested
    // once per link of the chain.
    const n = 5000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    for (0..n) |i| try src.print(a, "struct S{d}\n  x: S{d}\n\n", .{ i, i + 1 });
    try src.print(a, "struct S{d}\n  x: Int\n\nfun same(a: ?S0, b: ?S0) -> Bool\n  a == b\n", .{n});
    var r = try factsRun(src.items);
    defer r.deinit();
    const s0 = try r.ctx.intern(.{ .nominal = r.ctx.lookup(module_scope, "S0").? });
    try std.testing.expectEqual(@as(?u128, 8), try minBytes(&r.ctx, s0));
}

test "type facts: moves, copyable, cloneable" {
    var r = try factsRun(
        \\struct P
        \\  x: Int
        \\
        \\struct V
        \\  p: ?P
        \\
        \\struct W
        \\  p: !P
        \\
        \\struct Wrap[T]
        \\  item: T
        \\
    );
    defer r.deinit();
    const ctx = &r.ctx;
    const ty = &ctx.types;
    const p = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "P").? });
    const v = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "V").? });
    const w = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "W").? });
    const t = try ctx.intern(.{ .type_var = r.sym("T", 0).? });
    const vec_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.vec_sym_id, .args = &.{ty.int_id} } });
    const wrap_t = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.lookup(module_scope, "Wrap").?, .args = &.{t} } });
    const wrap_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.lookup(module_scope, "Wrap").?, .args = &.{ty.int_id} } });
    const read_p = try ctx.intern(.{ .read_view = p });
    const write_p = try ctx.intern(.{ .write_view = p });
    const shared_p = try ctx.intern(.{ .shared = p });
    const weak_p = try ctx.intern(.{ .weak = p });
    const opt_shared = try ctx.intern(.{ .optional = shared_p });
    const opt_t = try ctx.intern(.{ .optional = t });
    const int_slice = try ctx.intern(.{ .slice = .{ .elem = ty.int_id } });
    const write_slice = try ctx.intern(.{ .write_view = int_slice });

    const Case = struct { ty: TypeId, moves: Answer, copyable: Answer, clone: Clone };
    const cases = [_]Case{
        .{ .ty = ty.int_id, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = ty.string_id, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = p, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = read_p, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = write_p, .moves = .no, .copyable = .no, .clone = .copy },
        .{ .ty = v, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = w, .moves = .no, .copyable = .no, .clone = .copy },
        .{ .ty = vec_int, .moves = .yes, .copyable = .no, .clone = .deep },
        .{ .ty = ty.text_id, .moves = .yes, .copyable = .no, .clone = .text },
        .{ .ty = shared_p, .moves = .yes, .copyable = .no, .clone = .bump },
        .{ .ty = weak_p, .moves = .yes, .copyable = .no, .clone = .bump },
        .{ .ty = opt_shared, .moves = .yes, .copyable = .no, .clone = .bump },
        .{ .ty = t, .moves = .depends, .copyable = .depends, .clone = .depends },
        .{ .ty = opt_t, .moves = .depends, .copyable = .depends, .clone = .depends },
        .{ .ty = wrap_t, .moves = .depends, .copyable = .depends, .clone = .depends },
        .{ .ty = wrap_int, .moves = .no, .copyable = .yes, .clone = .copy },
        .{ .ty = write_slice, .moves = .no, .copyable = .no, .clone = .no },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        try std.testing.expectEqual(c.moves, moves(ctx, c.ty));
        try std.testing.expectEqual(c.copyable, copyable(ctx, c.ty));
        try std.testing.expectEqual(c.clone, cloneable(ctx, c.ty));
        try std.testing.expect(!isUnique(ctx, c.ty));
    }
    // A clone reads what a view reaches.
    try std.testing.expectEqual(Clone.bump, cloneable(ctx, try ctx.intern(.{ .read_view = shared_p })));
    try std.testing.expectEqual(Clone.deep, cloneable(ctx, try ctx.intern(.{ .read_view = vec_int })));
    // A view of a scalar or a plain enum reads as the value.
    try std.testing.expect(readsAsValue(ctx, ty.int_id));
    try std.testing.expect(!readsAsValue(ctx, p));
    try std.testing.expect(lendByValue(ctx, ty.int_id));
    try std.testing.expect(!lendByValue(ctx, vec_int));
}

test "lend table: each row makes its view" {
    var r = try factsRun(
        \\struct P
        \\  x: Int
        \\
    );
    defer r.deinit();
    const ctx = &r.ctx;
    const ty = &ctx.types;
    const p = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "P").? });
    const read = struct {
        fn f(c: *SemContext, t: TypeId) !TypeId {
            return c.intern(.{ .read_view = t });
        }
    }.f;
    const write = struct {
        fn f(c: *SemContext, t: TypeId) !TypeId {
            return c.intern(.{ .write_view = t });
        }
    }.f;
    const arr = try ctx.intern(.{ .array = .{ .elem = ty.int_id, .len = try ctInt(ctx, 3) } });
    const slice = try ctx.intern(.{ .slice = .{ .elem = ty.int_id } });
    const box_p = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{p} } });
    const box_text = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{ty.text_id} } });
    const fn_ty = try ctx.intern(.{ .function = .{ .params = &.{}, .returns = ty.int_id, .is_sub = false } });
    const owned = try ctx.intern(.{ .shared = fn_ty });
    const callable = try callableOfFn(ctx, fn_ty);
    const opt_string = try ctx.intern(.{ .optional = ty.string_id });
    const opt_text = try ctx.intern(.{ .optional = ty.text_id });
    const box_box_p = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{box_p} } });
    const box_arr = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{arr} } });
    const vec_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.vec_sym_id, .args = &.{ty.int_id} } });
    const shared_p = try ctx.intern(.{ .shared = p });
    const shared_text = try ctx.intern(.{ .shared = ty.text_id });
    const opt_p = try ctx.intern(.{ .optional = p });
    const opt_read_p = try ctx.intern(.{ .optional = try read(ctx, p) });
    const opt_vec = try ctx.intern(.{ .optional = vec_int });
    const opt_slice = try ctx.intern(.{ .optional = slice });

    const Case = struct { from: TypeId, kind: LendKind, view: TypeId, rows: ?[]const LendStep };
    const cases = [_]Case{
        // Any `T`: `?T`, and `!T` to write; a write lend may be read.
        .{ .from = p, .kind = .read, .view = try read(ctx, p), .rows = &.{} },
        .{ .from = p, .kind = .write, .view = try write(ctx, p), .rows = &.{} },
        .{ .from = p, .kind = .write, .view = try read(ctx, p), .rows = &.{} },
        .{ .from = p, .kind = .read, .view = try write(ctx, p), .rows = null },
        // An array: `[]T`, and `![]T` to write.
        .{ .from = arr, .kind = .read, .view = slice, .rows = &.{.elems} },
        .{ .from = arr, .kind = .write, .view = try write(ctx, slice), .rows = &.{.elems} },
        .{ .from = arr, .kind = .read, .view = try write(ctx, slice), .rows = null },
        // A `![]T` lent on to read.
        .{ .from = slice, .kind = .write, .view = slice, .rows = &.{.read_only} },
        // A Text: a String, also where a `String?` is expected; never to
        // write.
        .{ .from = ty.text_id, .kind = .read, .view = ty.string_id, .rows = &.{.text} },
        .{ .from = ty.text_id, .kind = .read, .view = opt_string, .rows = &.{ .lift, .text } },
        .{ .from = opt_text, .kind = .read, .view = opt_string, .rows = &.{ .optional, .text } },
        .{ .from = ty.text_id, .kind = .write, .view = ty.string_id, .rows = null },
        // A box: the views of its value.
        .{ .from = box_p, .kind = .read, .view = try read(ctx, p), .rows = &.{.unbox} },
        .{ .from = box_p, .kind = .write, .view = try write(ctx, p), .rows = &.{.unbox} },
        .{ .from = box_p, .kind = .read, .view = try write(ctx, p), .rows = null },
        .{ .from = box_text, .kind = .read, .view = ty.string_id, .rows = &.{ .unbox, .text } },
        // Boxes compose.
        .{ .from = box_box_p, .kind = .read, .view = try read(ctx, p), .rows = &.{ .unbox, .unbox } },
        .{ .from = box_arr, .kind = .read, .view = slice, .rows = &.{ .unbox, .elems } },
        // A Vec lends its elements, as an array does.
        .{ .from = vec_int, .kind = .read, .view = slice, .rows = &.{.elems} },
        .{ .from = vec_int, .kind = .write, .view = try write(ctx, slice), .rows = &.{.elems} },
        // A `*T` lends the read views of its `T`, never a write view.
        .{ .from = shared_p, .kind = .read, .view = try read(ctx, p), .rows = &.{.handle} },
        .{ .from = shared_text, .kind = .read, .view = ty.string_id, .rows = &.{ .handle, .text } },
        .{ .from = shared_p, .kind = .write, .view = try write(ctx, p), .rows = null },
        // An `X?` lends a `View?`; `?o` of an `S?` is a `?(S?)`.
        .{ .from = opt_p, .kind = .read, .view = opt_read_p, .rows = &.{.optional} },
        .{ .from = opt_p, .kind = .read, .view = try read(ctx, opt_p), .rows = &.{} },
        .{ .from = opt_vec, .kind = .read, .view = opt_slice, .rows = &.{ .optional, .elems } },
        .{ .from = arr, .kind = .read, .view = opt_slice, .rows = &.{ .lift, .elems } },
        // A function, or an owned closure: a `?fun(...)`.
        .{ .from = fn_ty, .kind = .read, .view = callable, .rows = &.{.callable} },
        .{ .from = owned, .kind = .read, .view = callable, .rows = &.{.callable} },
        .{ .from = fn_ty, .kind = .write, .view = callable, .rows = null },
        // No row: an Int is no slice.
        .{ .from = ty.int_id, .kind = .read, .view = slice, .rows = null },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        const lend = lendsAs(ctx, c.from, c.kind, c.view);
        const rows = c.rows orelse {
            try std.testing.expect(lend == null);
            continue;
        };
        try std.testing.expect(lend != null);
        try std.testing.expectEqualSlices(LendStep, rows, lend.?.steps());
    }
    try std.testing.expectEqual(fn_ty, lendsAs(ctx, fn_ty, .read, callable).?.callable().?);
}

test "type facts: unique reaches what holds it inline" {
    var r = try factsRun(
        \\struct U unique
        \\  n: Int
        \\
        \\struct Ring[T] unique
        \\  item: T
        \\
        \\struct Wrap[T]
        \\  item: T
        \\
        \\struct Holder
        \\  u: U
        \\
        \\struct Far
        \\  h: Holder
        \\
        \\struct Ptr
        \\  u: *U
        \\
        \\struct Counter
        \\  hits: Cell[Int]
        \\
        \\enum Slot
        \\  full(u: U)
        \\  empty
        \\
    );
    defer r.deinit();
    const ctx = &r.ctx;
    const nominal = struct {
        fn of(c: *SemContext, name: []const u8) !TypeId {
            return c.intern(.{ .nominal = c.lookup(module_scope, name).? });
        }
    }.of;
    const u = try nominal(ctx, "U");
    const wrap = ctx.lookup(module_scope, "Wrap").?;
    const ring = ctx.lookup(module_scope, "Ring").?;
    const two: TypeId = try ctx.intern(.{ .ct_value = .{ .int = 2 } });
    const unique = [_]TypeId{
        u,
        try ctx.intern(.{ .array = .{ .elem = u, .len = two } }),
        try ctx.intern(.{ .optional = u }),
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = wrap, .args = &.{u} } }),
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = ring, .args = &.{ctx.types.int_id} } }),
        try nominal(ctx, "Holder"),
        try nominal(ctx, "Far"),
        try nominal(ctx, "Slot"),
    };
    for (unique, 0..) |t, i| {
        errdefer std.debug.print("unique case {d}\n", .{i});
        try std.testing.expect(isUnique(ctx, t));
    }
    const not_unique = [_]TypeId{
        ctx.types.int_id,
        try ctx.intern(.{ .shared = u }),
        try ctx.intern(.{ .weak = u }),
        try ctx.intern(.{ .read_view = u }),
        try ctx.intern(.{ .write_view = u }),
        try ctx.intern(.{ .slice = .{ .elem = u } }),
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.vec_sym_id, .args = &.{u} } }),
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{u} } }),
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = wrap, .args = &.{ctx.types.int_id} } }),
        try nominal(ctx, "Ptr"),
    };
    for (not_unique, 0..) |t, i| {
        errdefer std.debug.print("not unique case {d}\n", .{i});
        try std.testing.expect(!isUnique(ctx, t));
    }
    // A unique value moves, has no clone, and is not plain data.
    for (unique) |t| {
        try std.testing.expectEqual(Answer.yes, moves(ctx, t));
        try std.testing.expectEqual(Answer.no, copyable(ctx, t));
        try std.testing.expectEqual(Clone.no, cloneable(ctx, t));
        try std.testing.expect(!isPlainData(ctx, t));
    }
    // A Cell, and what holds one inline, is unique, but owns nothing: an
    // array takes it. Behind a handle it is shared, not unique.
    const counter = try nominal(ctx, "Counter");
    const cell_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.cell_sym_id, .args = &.{ctx.types.int_id} } });
    for ([_]TypeId{ counter, cell_int, try ctx.intern(.{ .array = .{ .elem = counter, .len = two } }) }) |t| {
        try std.testing.expect(isUnique(ctx, t));
        try std.testing.expectEqual(Answer.yes, moves(ctx, t));
        try std.testing.expectEqual(Clone.no, cloneable(ctx, t));
        try std.testing.expect(!typeHasDropGlue(ctx, t));
    }
    const shared_counter = try ctx.intern(.{ .shared = counter });
    try std.testing.expect(!isUnique(ctx, shared_counter));
    try std.testing.expectEqual(Clone.bump, cloneable(ctx, shared_counter));
}

/// Walk every expression position of a body and report nodes sema left
/// without a fact. Used to keep the facts table complete.
const Coverage = struct {
    r: *const FactsRun,
    missing: usize = 0,

    fn expectName(self: *Coverage, leaf: Sexp) void {
        if (leaf != .src) return;
        const text = self.r.source[leaf.src.pos..][0..leaf.src.len];
        if (isBuiltinCallName(text) or std.mem.eql(u8, text, "_")) return;
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
                if (!isBuiltinCallName(self.r.source[e.src.pos..][0..e.src.len])) self.expectType(e);
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
                        if (ir.Arm.guard(arm) != .nil) self.expr(ir.Arm.guard(arm));
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
            .@"struct", .@"enum", .generic_struct => for (ir.rest(d, .members)) |m| self.decl(m),
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
        \\struct Wrap[T]
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
        \\  for x in ?v
        \\    total += x
        \\  print(total + moved.balance)
        \\  b: Wrap[Int] = Wrap(value: 4)
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

/// The `n`th (0-based, depth-first) list node of kind `tag` in `node`.
fn nthNode(node: Sexp, tag: Tag, n: *usize) ?Sexp {
    if (node != .list) return null;
    if (node.kind() == tag) {
        if (n.* == 0) return node;
        n.* -= 1;
    }
    for (node.items()) |c| if (nthNode(c, tag, n)) |found| return found;
    return null;
}

/// The leaf at source position `pos` in `node`.
fn leafAt(node: Sexp, pos: u32) ?Sexp {
    switch (node) {
        .src => |s| return if (s.pos == pos) node else null,
        .list => for (node.items()) |c| if (leafAt(c, pos)) |found| return found,
        else => {},
    }
    return null;
}

const HandsRun = struct {
    r: FactsRun,

    fn node(self: *const HandsRun, tag: Tag, nth: usize) Sexp {
        var n = nth;
        return nthNode(self.r.tree, tag, &n) orelse std.debug.panic("no {s} #{d}", .{ @tagName(tag), nth });
    }

    fn leaf(self: *const HandsRun, needle: []const u8, nth: usize) Sexp {
        return leafAt(self.r.tree, self.r.at(needle, nth)).?;
    }

    fn kind(self: *const HandsRun, e: Sexp) Hands.Kind {
        return handsOver(&self.r.ctx, e).kind;
    }
};

test "hands over: one kind per expression, by a positive list" {
    var h: HandsRun = .{ .r = try factsRun(
        \\struct P
        \\  x: Int
        \\  t: Text
        \\
        \\enum E
        \\  a(n: Int)
        \\  b
        \\
        \\fun mk() -> P
        \\  P(x: 1, t: Text("a"))
        \\
        \\fun keep(p: ?P) -> ?P
        \\  p
        \\
        \\fun maybe() -> Int?
        \\  none
        \\
        \\sub main()
        \\  p = mk()
        \\  q = mk()
        \\  c = true
        \\  o: Int? = 3
        \\  xs = [10, 20]
        \\  print(p.x, xs[0], mk().x, keep(?p).x, [1, 2][1])
        \\  print(p.t if c else q.t)
        \\  print(Text("y") if c else Text("z"))
        \\  print(mk().t if c else Text("w"))
        \\  print(o ?? 0, maybe() ?? 0)
        \\  e: E = .b
        \\  print(e == E.b, -p.x, +p.x, mk)
        \\  k: Int? = none
        \\  print(k)
        \\  n = o ?? return
        \\  print(n)
        \\  if c
        \\    print(1)
        \\
    ) };
    defer h.r.deinit();
    // Names, functions, and literals.
    try std.testing.expectEqual(.place, h.kind(h.leaf("p", 3)));
    try std.testing.expectEqual(.made, h.kind(h.leaf("10", 0)));
    try std.testing.expectEqual(.made, h.kind(h.leaf("none", 1)));
    try std.testing.expectEqual(.place, h.kind(h.leaf("mk", 5)));
    // Paths: from a place, from a value made here, through a view
    // one holds.
    try std.testing.expectEqual(.place, h.kind(h.node(.member, 0)));
    try std.testing.expectEqual(.place, h.kind(h.node(.index, 0)));
    try std.testing.expectEqual(.part_of_made, h.kind(h.node(.member, 1)));
    try std.testing.expectEqual(.place, h.kind(h.node(.member, 2)));
    try std.testing.expectEqual(.part_of_made, h.kind(h.node(.index, 1)));
    // A lend.
    try std.testing.expectEqual(.lend, h.kind(h.node(.read, 0)));
    // Branching values: one that may be a name's, and one whose every
    // leaf is made here, which is itself made here.
    try std.testing.expectEqual(.branches, h.kind(h.node(.@"if", 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.@"if", 1)));
    try std.testing.expectEqual(.branches, h.kind(h.node(.@"if", 2)));
    try std.testing.expectEqual(.branches, h.kind(h.node(.@"??", 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.@"??", 1)));
    // A leaf that jumps leaves the others to decide.
    try std.testing.expectEqual(.branches, h.kind(h.node(.@"??", 2)));
    try std.testing.expectEqual(.jump, h.kind(h.node(.@"return", 0)));
    // Operators, clones, and enum literals are made; `Type.variant` is
    // a qualified name.
    try std.testing.expectEqual(.made, h.kind(h.node(.@"==", 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.neg, 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.clone, 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.enum_lit, 0)));
    try std.testing.expectEqual(.place, h.kind(h.node(.member, 6)));
    try std.testing.expectEqual(.made, h.kind(h.node(.call, 0)));
    try std.testing.expectEqual(.made, h.kind(h.node(.array, 0)));
    // Statements and declarations hand over nothing.
    try std.testing.expectEqual(.none, h.kind(h.node(.@"if", 3)));
    try std.testing.expectEqual(.none, h.kind(h.node(.set, 0)));
    try std.testing.expectEqual(.none, h.kind(h.node(.@"struct", 0)));
}

test "hands over: value parts, leaves, and value statements" {
    var r = try factsRun(
        \\fun pick(c: Bool, a: Int?, b: Int?, n: Int) -> Int?
        \\  x = (a if c else b) ?? 0
        \\  y = match n
        \\    0 => n
        \\    _
        \\      x
        \\  z = a?
        \\  if c
        \\    return x
        \\  x + y + z
        \\
    );
    defer r.deinit();
    var n: usize = 0;
    const nullish = nthNode(r.tree, .@"??", &n).?;
    var parts = valueParts(nullish);
    try std.testing.expectEqual(ValuePart.Via.operand, parts.next().?.via);
    try std.testing.expectEqual(ValuePart.Via.operand, parts.next().?.via);
    try std.testing.expect(parts.next() == null);
    // A read reaches the leaves through nested branching values.
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(std.testing.allocator);
    try valueLeaves(std.testing.allocator, nullish, &leaves);
    try std.testing.expectEqual(@as(usize, 3), leaves.items.len);
    try std.testing.expectEqual(r.at("a", 1), leaves.items[0].src.pos);
    try std.testing.expectEqual(r.at("b", 1), leaves.items[1].src.pos);
    // A match's arms are tails it takes; a block arm's is its last line.
    n = 0;
    const match = nthNode(r.tree, .match, &n).?;
    var arms = valueParts(match);
    try std.testing.expectEqual(r.at("n", 2), arms.next().?.node.src.pos);
    const block_arm = arms.next().?;
    try std.testing.expectEqual(ValuePart.Via.tail, block_arm.via);
    try std.testing.expectEqual(r.at("x", 1), block_arm.node.src.pos);
    try std.testing.expect(arms.next() == null);
    // A read stops at a match: it is a value made here.
    leaves.clearRetainingCapacity();
    try valueLeaves(std.testing.allocator, match, &leaves);
    try std.testing.expectEqual(@as(usize, 1), leaves.items.len);
    n = 0;
    var opt = valueParts(nthNode(r.tree, .propagate_none, &n).?);
    try std.testing.expectEqual(ValuePart.Via.unwrapped, opt.next().?.via);
    // Statements that give a value, and those that give none.
    n = 0;
    try std.testing.expect(yieldsValue(r.source, nthNode(r.tree, .@"if", &n).?));
    n = 1;
    try std.testing.expect(!yieldsValue(r.source, nthNode(r.tree, .@"if", &n).?));
    n = 0;
    try std.testing.expect(!yieldsValue(r.source, nthNode(r.tree, .@"return", &n).?));
    n = 0;
    try std.testing.expect(!yieldsValue(r.source, nthNode(r.tree, .set, &n).?));
    n = 0;
    try std.testing.expect(yieldsValue(r.source, nthNode(r.tree, .@"+", &n).?));
    n = 0;
    try std.testing.expect(yieldsValue(r.source, nthNode(r.tree, .match, &n).?));
    // A block gives its last statement's value; nothing gives none.
    n = 1;
    try std.testing.expect(yieldsValue(r.source, nthNode(r.tree, .block, &n).?));
    try std.testing.expect(!yieldsValue(r.source, .nil));
}
