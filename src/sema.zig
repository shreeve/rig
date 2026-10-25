//! Semantic analysis: names, types, and expression checking.
//!
//! `check` runs these steps over the normalized IR and returns
//! a `SemContext`, which every later pass (ownership, emit) reads:
//!
//!   1. builtins     `resolve.zig`    Cell, List, ^T, Signal, Endian
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
//! other queries on `SemContext`); `docs/internals/INTERNALS.md` (The facts table)
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
const zig_builtin = @import("builtin");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
pub const diag = @import("diag.zig");
const resolve = @import("resolve.zig");
const typecheck = @import("typecheck.zig");
const storage = @import("storage.zig");
const timing = @import("timing.zig");
pub const cteval = @import("cteval.zig");

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
/// `error`, an error of any set: the set of a `T!` (`Fallible`). Every
/// `TypeStore` interns it at this place (`TypeStore.init`).
pub const type_any_error: TypeId = 12;

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
/// `Simd[elem, len]`: `len` lanes of a number or `Bool`, `len` a power of
/// two from 2 to 64 (`ct_value`), or a `ct_param` inside a generic
/// declaration. A vector is one plain value (docs/CORE.md §1): its lanes
/// are parts of its value, not places.
pub const SimdType = struct { elem: TypeId, len: TypeId };

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
/// frame, and the program's stack holds 64 MiB, so any one value fits
/// there with room to spare. The cap also keeps compiles fast, since Zig
/// builds a constant array element by element. Larger data belongs in a
/// `List`.
pub const max_value_bytes: u64 = 8 << 20;

/// How deep types may nest by value (`valueDepth`): an object, enum,
/// optional, array, or vector holding another, each a level. Zig walks
/// every level of a type when it compiles a use of it, and its compiler
/// runs out of stack on a chain of objects each holding the next past
/// about 1250 levels (on an arm64 Mac and x86-64 Linux alike); a deeper
/// value is held through a box or a List.
pub const max_value_depth: u32 = 1000;

/// The most bytes of values one function keeps on its stack, with the
/// frames inlined into it: 13 MiB. It is a limit on how a program keeps
/// its data, which leaves large data to the heap; safety does not rest on
/// it. Zig's code holds temporaries this count leaves out, and how deep
/// calls nest is not known, so a program can still run out of its 64 MiB
/// stack: the guard below the stack (`max_frame_reach`) stops it there.
pub const max_frame_bytes: u64 = 13 << 20;

/// A frame `checkFrames` counted: what it is, the bytes and reach of its
/// own values (`typecheck.checkFrames`) and of those the calls of marked
/// `inline` functions land in it (`marked`), and the frame owner it is
/// the frame of, at one instance for a generic one: the module that
/// declares it (its id) and where (`FrameOwner.pos`).
pub const FrameSize = struct { label: []const u8, pos: u32, bytes: u128, reach: u128, marked: FrameCount = .none, params: u128 = 0, module: u32, decl: u32 };

/// A frame as `typecheck.checkFrames` counts it: the bytes of the values
/// it keeps, and its reach.
pub const FrameCount = struct {
    bytes: u128,
    reach: u128,

    pub const none: FrameCount = .{ .bytes = 0, .reach = 0 };
};

/// A value a frame keeps, or (`copy`) a copy its code may make, which
/// counts in its reach alone (`typecheck.FrameWalker`); `marked` when a
/// call of a marked `inline` function lands it there.
pub const FrameSlot = struct { ty: TypeId, name: []const u8, copy: bool = false, marked: bool = false };

/// A call of a marked `inline` function, recorded where typecheck
/// resolves the call (`Checker.noteTarget`): the function, and the
/// instance the call makes, its object type's parameters then its own,
/// to their arguments here. Every frame and every cycle of `inline`
/// functions is read from it.
pub const InlineCall = struct { fun: FnRef, subst: TypeSubst };

/// A place Zig writes a stack frame of its own for (docs/internals/INTERNALS.md,
/// "Frame owners"), decided once, by a positive list
/// (`typecheck.recordFrameOwners`): a function or method (each instance of
/// a generic one is a frame of this owner), a closure, a test block, and
/// a `drop` body. The program's `main` is a function. Every other body
/// (a `defer` or `errdefer` body, a match arm, a block, a loop and its
/// iterator's `next` call) belongs to the owner around it.
pub const FrameOwner = struct {
    kind: Kind,
    /// The `fun`, `sub`, `lambda`, `test`, or `drop_decl` node.
    root: Sexp,
    /// The owner around it, for a closure.
    parent: ?u32,
    /// Where it is declared: a function's name, which `inlined` and
    /// `large_frames` key by, or the start of any other.
    pos: u32,
    /// How messages name it.
    label: []const u8,
    /// A method of an object or enum type, and of a generic one, and the
    /// type's name.
    member: bool = false,
    of_generic_type: bool = false,
    type_name: []const u8 = "",
    /// Its calls, as indexes into `SemContext.frame_calls`, in the order
    /// the walk met them.
    calls: []const u32 = &.{},
    /// Its own frame (`checkFrames`); null when each instance's frame is
    /// counted on its own (`FrameSize`), or before it is counted.
    own: ?FrameCount = null,
    /// What the calls of marked `inline` functions in it land in its
    /// frame, beside `own`, and as it.
    marked: FrameCount = .none,
    /// The reach of a function's parameters as its code copies them where
    /// it is inlined, beside `own` (`typecheck.FrameWalker.paramCopies`).
    params: u128 = 0,
    /// Whether `own` is null because its instances count it.
    per_instance: bool = false,
    /// Its frame with what the automatic rule inlines into it, which
    /// `inlining.decide` fills (`SemContext.account`).
    account: Account = .{ .own = null },

    pub const Kind = enum { function, closure, test_block, drop };
};

/// What a frame owner's frame holds (`SemContext.account`): its own
/// values (`checkFrames`), or null where no count knows them, which is
/// unbounded and fails every limit; what the calls of marked `inline`
/// functions land in it, their values and their reach, each at the
/// instance the call makes and at every copy Zig writes of the call
/// (`checkFrames`); and what the functions the automatic rule inlines
/// into it add, each counted at every call and at every copy Zig writes
/// of the call, through the marked functions too (`inlining.decide`).
pub const Account = struct {
    own: ?FrameCount,
    marked: FrameCount = .none,
    auto: u128 = 0,

    /// Its values with everything inlined into it; null when unknown.
    pub fn total(self: Account) ?FrameCount {
        const own = self.own orelse return null;
        return .{ .bytes = own.bytes + self.marked.bytes + self.auto, .reach = own.reach + self.marked.reach + self.auto };
    }
};

/// A function or method by its declaration: the id of the module that
/// declares it, and where its name is there.
pub const FnRef = struct { module: u32, pos: u32 };

/// What a call reaches, as typecheck resolved it (`Checker.synthCall`):
/// one Rig function or method, or none (a built-in, an `extern`
/// function, a constructor, a closure or function value).
pub const CallTarget = union(enum) { function: FnRef, none };

/// A call in a frame owner's body: the owner (null for one outside every
/// owner), and how many times Zig writes it, which a `defer` or `errdefer`
/// body multiplies by the exits it covers (`typecheck.FrameWalker`).
pub const FrameCall = struct { node: Sexp, owner: ?u32, copies: u32 };

/// A value of at most this many bytes is held in registers, or spilled
/// to a slot of its own, never copied through a temporary of its size;
/// a frame's reach leaves it out.
pub const register_bytes: u64 = 16;

/// The most times Zig's code holds one value a function makes or copies
/// on its stack, in any build mode, on aarch64 (LLVM) and x86_64 (Zig's
/// own backend in debug): the stack a frame takes is at most this many
/// times its reach. `test/cli/frame_reach.sh` checks it against the
/// frames Zig really reserves.
pub const reach_factor: u64 = 4;

/// The most stack one function's code may take, `reach_factor` times its
/// reach: 512 MiB, half the smallest guard the runtime keeps below
/// `main`'s stack (`guard_sizes` in `rig/runtime.zig`, 1 GiB). A task's
/// guard is sized from the program's largest frame (`taskGuard`).
pub const max_frame_reach: u64 = 512 << 20;

/// A function whose code may take this much stack (`reach_factor` times
/// its reach) or more is emitted `noinline` and never inlined, so no two
/// such frames merge into one.
pub const noinline_reach: u64 = 1 << 20;

/// The smallest guard below a task's stack (`task_guard` in
/// `rig/runtime.zig`): 16 MiB. A frame larger than the guard could skip
/// past it into memory that is not the task's, so a program's tasks take
/// a guard at least twice its largest frame (`taskGuard`), and at least
/// this, which holds sixteen frames of under `noinline_reach` that Zig's
/// own inlining merged into one.
pub const min_task_guard: u64 = 16 * noinline_reach;

/// What a frame takes beside its values: the registers and scalars every
/// frame saves (`test/cli/frame_reach.sh`).
pub const frame_slack: u64 = 16 << 10;

/// The guard below the stack of each task of a program whose largest
/// frame may take `largest` bytes (`large_frames`; 0 when none is large):
/// at least twice that and its slack, a power of two, and at least
/// `min_task_guard`, so an overflowing frame faults in it, never past it.
/// At most 1 GiB, the guard below `main`'s stack, which already holds
/// twice the largest frame the compiler accepts (`max_frame_reach`).
pub fn taskGuard(largest: u64) u64 {
    const need = std.math.ceilPowerOfTwo(u64, 2 * (largest + frame_slack)) catch unreachable;
    return std.math.clamp(need, min_task_guard, 1 << 30);
}

/// Record that the frame owner declared at `pos` may take `bytes` of
/// stack, a large frame (`SemContext.large_frames`): the most of all its
/// instances.
pub fn markLarge(frames: *std.AutoHashMapUnmanaged(u32, u64), allocator: std.mem.Allocator, pos: u32, bytes: u64) !void {
    const gop = try frames.getOrPut(allocator, pos);
    gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, bytes) else bytes;
}

/// A declaration, `pos` in module `module`, whose frame is large at an
/// instance another module makes, taking `bytes` of stack there
/// (`SemContext.large_foreign_frames`).
pub const ForeignFrame = struct { module: u32, pos: u32, bytes: u64 };

/// The values one function or closure keeps on its stack: `label` names
/// it in messages, declared at `pos` in module `module_id` (0 for the
/// module that keeps the frame).
///
/// `names` holds the name of the local each type is, empty for a temporary,
/// so a diagnostic can name the largest.
///
/// The last `copies` types are copies its code may make, which count in
/// its reach alone (`typecheck.checkFrames`). Of the values, the last
/// `marked` are those calls of marked `inline` functions land in it, and
/// so are the last `marked_copies` of the copies. The last `params` types,
/// after the copies, are a function's parameters as its code copies them
/// where it is inlined.
pub const Frame = struct { label: []const u8, pos: u32, tys: []const TypeId, names: []const []const u8, copies: u32 = 0, marked: u32 = 0, marked_copies: u32 = 0, params: u32 = 0, module_id: u32 = 0 };

pub const Type = union(enum) {
    /// A type error was reported here.
    invalid,
    /// Not known; only ever produced after a diagnostic.
    unknown,

    void,
    bool,
    string_view,
    /// `String`: owned, growable UTF-8 bytes; `?String` is its view.
    string,
    /// `Static`: a `?String` known to view only bytes that live for the
    /// whole program (a literal, or text derived only from literals). It
    /// is plain data that carries no loan, and it is read as a `?String`
    /// where the text is only read (`typecheck.meets`).
    static,
    /// `Symbol`: a symbol literal's type (`:width`). Its values are the
    /// program's symbol literals, numbered once for the whole program
    /// (`src/symbols.zig`); it is plain data, compared with `==` and `!=`.
    symbol,
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
    fallible: Fallible, // T!, T!E
    read_view: TypeId, // ?T
    write_view: TypeId, // !T
    shared: TypeId, // *T
    weak: TypeId, // ~T

    slice: SliceType,
    array: ArrayType,
    /// `Simd[T, n]`: a vector of `n` lanes, lowered to `@Vector(n, T)`.
    /// A mask is `Simd[Bool, n]`, what a lane-wise comparison gives.
    simd: SimdType,
    /// `Slot[n]`: a number below `n`, which names one of the `n` slots of
    /// any `Table[T, n]`. `n` is a `ct_value` of at least 1, or a
    /// `ct_param` inside a generic declaration. Only `push`, `of`, and a
    /// literal below `n` make one; it is plain data, compared, ordered,
    /// hashed, and printed as its number (`slotLen`).
    slot: TypeId,
    /// `a..b`: a half-open range of the element integer type. Only valid
    /// as a `for` source.
    range: TypeId,

    function: FunctionType,
    /// `(A, B)`: a function's several results, two or more, each a type a
    /// single result may have. It is a function's result type only (and
    /// inside `T!` or `T?` there), never a value's: a call that gives it
    /// stands only where each result is bound at once (`q, r = f()`), or
    /// is returned whole. Its facts are its parts' together, as an
    /// object's are its fields' (docs/internals/INTERNALS.md, "Several results").
    results: []const TypeId,
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
    /// A generic parameter (`T` inside `obj Wrap[T]`).
    type_var: SymbolId,
    /// A compile-time integer where a type argument or an array length
    /// goes: `4` in `Ring[Int, 4]` and `[4]Int`. Not a type of values.
    ct_value: CtValue,
    /// A compile-time value parameter used where a `ct_value` goes, the
    /// way a `type_var` stands for a type: `n` in `[n]T` inside `fun
    /// f[n: Int]` or `obj Ring[T, n: Int]`.
    ct_param: SymbolId,
    /// `{Shape}`: an API object, a value of some type that provides an
    /// API of a program's own, its type erased (docs/design/apis.md,
    /// Stage 4). It has no size of its own, so it stands only behind a
    /// view or a box, `?{Shape}`, `!{Shape}`, `^{Shape}` (`misplaced`).
    api_object: ApiObject,
};

/// What an API object's braces name: one API of a program's own, and
/// beside it only the built-in APIs an object serves itself, `Owned`,
/// `Print`, and `Clone`, and the crossing bounds its form can use,
/// `Sends` and `Syncs`. Its type hidden, it may hold anything, so it
/// meets no other bound (`objectMeets`).
pub const ApiObject = struct {
    api: ApiRef,
    builtins: Apis = .empty,
};

/// The built-in APIs an API object meets by what it names: those its
/// braces name and those its API builds on (`api Job: Sends`), each
/// checked on the hidden value where it is erased. The one classifier of
/// an object's bounds, which its crossing (`blockerIn`), its erasure, and
/// `objectMeets` read (docs/design/apis.md, Stage 5).
pub fn objectBounds(ctx: *const SemContext, o: ApiObject) Apis {
    return o.builtins.unionWith(builtInSupers(ctx, &.{o.api}) catch .empty);
}

/// The crossing bound a value going to a task as `how` says needs: `Sends`
/// to be given or lent to write, `Syncs` to be read by several tasks.
pub fn crossingBound(how: Crossing) Api {
    return if (how == .moves) .Sends else .Syncs;
}

/// The braces of an object held as `form`, less a crossing bound the form
/// cannot use: a read view crosses only when its value syncs, and a write
/// view only when it sends, so `?{A + Sends}` is `?{A}` and `!{A +
/// Syncs}` is `!{A}`, one spelling per meaning. A box keeps both; a
/// counted handle crosses only when its value syncs, and a weak handle
/// never.
pub fn formBraces(builtins: Apis, form: ObjectForm) Apis {
    var out = builtins;
    switch (form) {
        .read, .shared => out.remove(.Sends),
        .write => out.remove(.Syncs),
        .box => {},
        .weak => {
            out.remove(.Sends);
            out.remove(.Syncs);
        },
    }
    return out;
}

/// Whether a `*` of `inner` is a `*{A + Syncs}`, its `Syncs` in the
/// braces or the API: such a handle holds a frozen value, counted
/// atomically, which holds no view and has no weak handle; a `*{A}`
/// without it holds a `*T`'s allocation, counted plainly. The holding
/// follows from the braces alone (docs/design/apis.md, Stage 5).
pub fn frozenObject(ctx: *const SemContext, inner: TypeId) bool {
    const o = apiObject(ctx, inner) orelse return false;
    return objectBounds(ctx, o).contains(.Syncs);
}

/// Whether API `sym` declares an associated type, `type Item`: a hidden
/// parameter after its `Self`.
pub fn declaresAssoc(sym: Symbol) bool {
    const params = sym.type_params orelse return false;
    return params.len > 1;
}

/// The braces of an API object as Rig writes them: `{Shape}`,
/// `{geo.Shape + Owned + Print}`, its API first and the built-in APIs
/// after it in one order, so one type has one spelling.
pub fn objectSpelling(ctx: *const SemContext, a: std.mem.Allocator, o: ApiObject) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{{s}", .{try apiName(ctx, o.api)});
    var it = o.builtins.iterator();
    while (it.next()) |b| try out.print(a, " + {s}", .{@tagName(b)});
    try out.append(a, '}');
    return out.items;
}

/// The API object `ty` is, bare: `{Shape}`, which has no size of its own
/// (docs/design/apis.md, Stage 4). Null for any other type.
pub fn apiObject(ctx: *const SemContext, ty: TypeId) ?ApiObject {
    if (!ctx.typeInfo(ty).object) return null;
    return switch (ctx.types.get(ty)) {
        .api_object => |o| o,
        else => null,
    };
}

/// How a value holds the API object it holds directly: `?{Shape}`,
/// `!{Shape}`, `^{Shape}`, `*{Shape}`, or `~{Shape}`.
pub const ObjectForm = enum { read, write, box, shared, weak };

/// The API object `ty` holds directly, and how: a read view, a write
/// view, a box, a counted handle, or a weak handle of one. Null for any
/// other type, an optional of one included.
pub const ObjectHeld = struct { object: ApiObject, form: ObjectForm };

pub fn objectHeld(ctx: *const SemContext, ty: TypeId) ?ObjectHeld {
    if (!ctx.typeInfo(ty).object) return null;
    const inner, const form: ObjectForm = switch (ctx.types.get(ty)) {
        .read_view => |v| .{ v, .read },
        .write_view => |v| .{ v, .write },
        .shared => |v| .{ v, .shared },
        .weak => |v| .{ v, .weak },
        else => .{ boxedType(ctx, ty) orelse return null, .box },
    };
    const o = apiObject(ctx, inner) orelse return null;
    return .{ .object = o, .form = form };
}

/// A value erased to an API object (docs/design/apis.md, Stage 4): the
/// value reached by a lend's rows, of type `from`, which provides the
/// object's API by `witness`, made a `view`, `?{A}` or `!{A}`; a box
/// `^T` moved into a `^{A}`, keeping its allocation; or a counted handle
/// moved into a `*{A}`, keeping its allocation and its count. Recorded
/// once, where the type checker makes it (`SemContext.recordErasure`);
/// emit writes the object and the ownership checker roots its loan from
/// it.
pub const Erasure = struct {
    /// The object's API, whose table the object holds.
    api: ApiRef,
    /// The erased value's type.
    from: TypeId,
    /// The object it becomes: `?{A}`, `!{A}`, `^{A}`, or `*{A}`.
    view: TypeId,
    witness: Witness,
    form: ObjectForm,
    /// Where the value is held, which picks the table's drop, clone, and
    /// weak entries: a box's allocation (a view's table is a box's), a
    /// `*T`'s, or a frozen value's (`frozenObject`).
    holding: Holding = .box,
    /// A box's or a handle's: the value is an optional one, `^T?` or
    /// `*T?`, which, if any, is erased.
    optional: bool = false,
    /// The value is a read view of plain data or of a type parameter's
    /// value, which may be held as a copy with no address of its own: the
    /// object views a copy, a hidden local of the erasing block
    /// (`Storage` `erased_copy`), and cannot leave the block.
    copy: bool = false,
};

/// How an erased value is held (`Erasure.holding`), as the runtime's
/// `rig.ApiHolding` spells it.
pub const Holding = enum { box, counted, frozen };

/// An entry of an API's table (docs/design/apis.md, Stage 4): a method a
/// call through an object reaches (`objectMethods`), in its slot, with
/// how it takes self and its type in the API's module, whose parameters
/// after self and result no type erased to the API changes.
pub const TableEntry = struct {
    name: []const u8,
    slot: u32,
    self_mode: MethodReceiver,
    fn_ty: TypeId,
};

/// The API object a view `ty` is, `?{Shape}` or `!{Shape}`, and how it
/// views it; null for any other type, a box or a handle of one included.
pub fn objectView(ctx: *const SemContext, ty: TypeId) ?struct { object: ApiObject, form: ObjectForm } {
    const h = objectHeld(ctx, ty) orelse return null;
    if (h.form != .read and h.form != .write) return null;
    return .{ .object = h.object, .form = h.form };
}

/// Whether `ty` is an API object's view, `?{Shape}` or `!{Shape}`, whose
/// value's type is erased: no assignment, swap, or copy writes or reads
/// the value through it; only its methods reach it.
pub fn isErasedView(ctx: *const SemContext, ty: TypeId) bool {
    return objectView(ctx, ty) != null;
}

/// A Cell that `ty` is or holds in its structure whose value holds an
/// API object, `Cell[^{Shape}]`: a Cell's value is replaced through any
/// handle to it, and an object changes only through its methods, so a
/// shared object changes through a Cell its value holds, behind a
/// `*{A}` (docs/design/apis.md, Stage 5). Null for any other type.
pub fn objectCell(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return objectCellAt(ctx, ty, 0);
}

fn objectCellAt(ctx: *const SemContext, ty: TypeId, depth: u32) ?TypeId {
    if (depth > max_alias_height or !ctx.typeInfo(ty).object) return null;
    switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id) return ty,
        else => {},
    }
    var it: TypeChildren = .{ .ty = ctx.types.get(ty) };
    while (it.next()) |c| if (objectCellAt(ctx, c, depth + 1)) |found| return found;
    return null;
}

/// The error for a Cell of an API object (`objectCell`).
pub const object_cell = "a Cell holds no API object: `{s}`; a shared object changes through a `Cell` its value holds";

/// Why a call through an API object cannot reach a method of its API
/// (docs/design/apis.md, Stage 4): the call would pass what a table's
/// entry, one function for every type erased to it, cannot.
pub const LeftOut = union(enum) {
    /// Compile-time parameters of its own, types or values, which each
    /// call passes.
    ct_params,
    /// A set parameter of its own, `fun each[E](...)`, by name.
    set_param: []const u8,
    /// `Self` anywhere but self, `?Self` or `-> Self`, which only the
    /// hidden type could give.
    self_type,
};

/// A method of an API object's API, or of an API it builds on, as a
/// call through the object reaches it (`objectMethods`).
pub const ObjectMethod = struct {
    /// The API that declares it, and its declaration there.
    api: ApiRef,
    field: Field,
    /// Its entry in the object's table, in `objectMethods`' order; null
    /// for one left out.
    slot: ?u32,
    /// Why a call through an object cannot reach it; null when it can.
    left_out: ?LeftOut,
};

/// Every method of API `api` and those it builds on, defaults included,
/// in table order: each API's own after those of the APIs it builds on,
/// each API once, its methods as declared. The one decider of what a
/// call through an API object reaches, and in which slot; a method left
/// out says why, and the rest still form objects (docs/design/apis.md,
/// Stage 4).
pub fn objectMethods(ctx: *const SemContext, a: std.mem.Allocator, api: ApiRef) std.mem.Allocator.Error![]const ObjectMethod {
    var order: std.ArrayList(ApiRef) = .empty;
    try objectApiOrder(ctx, a, api, &order, 0);
    var out: std.ArrayList(ObjectMethod) = .empty;
    var slot: u32 = 0;
    for (order.items) |ref| {
        const home = apiContext(ctx, ref) orelse continue;
        const sym = apiSymbol(ctx, ref) orelse continue;
        const self_sym = (sym.type_params orelse continue)[0];
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_method) continue;
            const why = methodLeftOut(home, f, self_sym);
            try out.append(a, .{ .api = ref, .field = f, .slot = if (why == null) slot else null, .left_out = why });
            if (why == null) slot += 1;
        }
    }
    return out.items;
}

/// `ref` after every API it builds on, each once (a cycle stops where it
/// closes; `checkApis` reports it).
fn objectApiOrder(ctx: *const SemContext, a: std.mem.Allocator, ref: ApiRef, out: *std.ArrayList(ApiRef), depth: u32) std.mem.Allocator.Error!void {
    for (out.items) |o| if (o.eql(ref)) return;
    if (depth > 64) return;
    const sym = apiSymbol(ctx, ref) orelse return;
    for (sym.user_apis) |s| try objectApiOrder(ctx, a, s, out, depth + 1);
    for (out.items) |o| if (o.eql(ref)) return;
    try out.append(a, ref);
}

/// Why a call through an object cannot reach API method `f`, declared in
/// `home` with hidden `Self` `self_sym`; null when it can.
fn methodLeftOut(home: *const SemContext, f: Field, self_sym: SymbolId) ?LeftOut {
    const fn_ty = switch (home.types.get(f.ty)) {
        .function => |fun| fun,
        else => return null,
    };
    for (fn_ty.ct_syms) |p| {
        if (p != symbol_invalid and home.symbols.items[p].flags.set_param) return .{ .set_param = home.symbols.items[p].name };
    }
    if (fn_ty.ct_params.len > 0) return .ct_params;
    const params = if (f.receiver == .none) fn_ty.params else fn_ty.params[@min(1, fn_ty.params.len)..];
    for (params) |p| if (namesTypeVar(home, p, self_sym, 0)) return .self_type;
    if (namesTypeVar(home, fn_ty.returns, self_sym, 0)) return .self_type;
    return null;
}

/// Whether `ty` names type parameter `sym` anywhere in its structure.
fn namesTypeVar(ctx: *const SemContext, ty: TypeId, sym: SymbolId, depth: u32) bool {
    if (depth > max_alias_height or !ctx.typeInfo(ty).has_type_var) return false;
    const t = ctx.types.get(ty);
    if (t == .type_var and t.type_var == sym) return true;
    var it: TypeChildren = .{ .ty = t };
    while (it.next()) |c| if (namesTypeVar(ctx, c, sym, depth + 1)) return true;
    return false;
}

/// Whether `ty` is or mentions an API object anywhere: `?{Shape}`,
/// `List[^{Shape}]`, `fun(?{Shape}) -> Int`. A declared type's fields
/// are its own declarations, checked where they are written.
pub fn mentionsObject(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.typeInfo(ty).object;
}

/// `T!E`: a value `ok`, or a failure with an error of `set`, a declared
/// error set or a union of sets; `T!`'s set is `error`, any error.
pub const Fallible = struct {
    ok: TypeId,
    set: TypeId = type_any_error,
};

pub const ParamNominal = struct {
    sym: SymbolId,
    args: []const TypeId,
    /// `List[T, inline: n]`: how many of its first elements live inside
    /// the List; 0 for every other instance.
    inline_len: u32 = 0,
};

pub const ImportedNominal = struct {
    module_id: u32,
    sym_id: SymbolId,
};

/// Module id -> the module's context.
pub const ModuleMap = std.AutoHashMapUnmanaged(u32, *SemContext);
const no_modules: ModuleMap = .empty;

/// A `use`: the file of a directory module it is in (`SemContext.parts`;
/// 0 in a module of one file), the module symbol it binds there, and the
/// declaration.
pub const FileUse = struct { file: u32, sym: SymbolId, decl: Sexp };

/// The index of the file of a directory module `pos` is in; 0 in a
/// module of one file.
pub fn fileIndex(parts: []const diag.Part, pos: u32) u32 {
    var i: usize = parts.len;
    while (i > 1 and parts[i - 1].start > pos) i -= 1;
    return @intCast(i -| 1);
}

/// One resolved `use NAME` of the module being checked. `sema` must
/// outlive the importing SemContext.
pub const ImportEntry = struct {
    local_name: []const u8,
    sema: *SemContext,
    module_id: u32,
    /// The file of a directory module whose `use` the graph recorded it
    /// for (`SemContext.parts`); 0 for a module of one file.
    file: u32 = 0,
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
    string_view_id: TypeId = type_invalid,
    string_id: TypeId = type_invalid,
    static_id: TypeId = type_invalid,
    symbol_id: TypeId = type_invalid,
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
        s.string_view_id = try s.intern(allocator, .string_view);
        s.string_id = try s.intern(allocator, .string);
        s.int_id = try s.intern(allocator, .{ .int = .{} });
        s.float_id = try s.intern(allocator, .{ .float = .{} });
        s.int_literal_id = try s.intern(allocator, .int_literal);
        s.float_literal_id = try s.intern(allocator, .float_literal);
        s.none_id = try s.intern(allocator, .none_literal);
        s.noreturn_id = try s.intern(allocator, .noreturn);
        s.any_error_id = try s.intern(allocator, .any_error);
        std.debug.assert(s.any_error_id == type_any_error);
        s.static_id = try s.intern(allocator, .static);
        s.symbol_id = try s.intern(allocator, .symbol);
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
        if (self.absorbed(ty)) |id| return id;
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

    /// The type a read view of a read view, or of a `String` or a `?String`,
    /// is: a read view of a read view is that read view (`?(?T)` is `?T`),
    /// and the read view of a `String` is its bytes, the one text view,
    /// `?String`, which is already a read view.
    /// Null for any other type. Every way to name such a view interns
    /// through here, so no type holds a pointer view of a `String`.
    fn absorbed(self: *const TypeStore, ty: Type) ?TypeId {
        const inner = switch (ty) {
            .read_view => |inner| inner,
            else => return null,
        };
        if (inner == self.string_view_id or (inner == self.string_id and self.string_id != type_invalid)) return self.string_view_id;
        return if (self.items.items[inner] == .read_view) inner else null;
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
            .invalid, .unknown, .void, .bool, .string_view, .string, .static, .symbol, .int_literal, .float_literal, .none_literal, .noreturn, .any_error => true,
            .function => |af| af.is_sub == b.function.is_sub and
                af.returns == b.function.returns and
                std.mem.eql(TypeId, af.ct_params, b.function.ct_params) and
                std.mem.eql(SymbolId, af.ct_syms, b.function.ct_syms) and
                std.mem.eql(TypeId, af.params, b.function.params),
            .parameterized_nominal => |x| x.sym == b.parameterized_nominal.sym and
                x.inline_len == b.parameterized_nominal.inline_len and
                std.mem.eql(TypeId, x.args, b.parameterized_nominal.args),
            .results => |x| std.mem.eql(TypeId, x, b.results),
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
    /// `obj Wrap[T]` / `enum Option[T]` and the built-in generics.
    generic_type,
    /// `T` in `obj Wrap[T]`, detached: not in any scope, reached through
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
    /// `api Shape`: the methods a type provides (docs/design/apis.md,
    /// Stage 3). Its `fields` are its own methods, its `type_params` its
    /// hidden `Self`, and its `apis` and `user_apis` the APIs it builds
    /// on. Never a type.
    api,
};

pub const SymbolFlags = packed struct(u64) {
    /// `=!` binding: cannot be reassigned.
    fixed: bool = false,
    is_public: bool = false,
    /// Value known at compile time: a compile-time parameter
    /// (`fun f[n: Int]`), or a `=!` binding
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
    /// A type declared `unique` (`obj T unique`): its values are never
    /// copied (`Contents.unique`).
    unique: bool = false,
    /// A read match's binding of a payload, or the whole value, that is
    /// not plain data, of a subject the match reads as a copy (not
    /// `storage.matchesInPlace`): usable within its arm only
    /// (docs/internals/INTERNALS.md, "Header subjects").
    arm_view: bool = false,
    /// A `!T` or `![]T` local assigned a view somewhere
    /// (`SemContext.repoints`): it lowers to a Zig `var` pointer.
    repointed: bool = false,
    /// An assignment gives the binding itself another value or view, not
    /// a write through it (`SemContext.writesThrough`): it lowers to a Zig
    /// `var`.
    rebound: bool = false,
    /// A `for` element that views a slot of the List the loop walks in
    /// place (`forViewsSlot`).
    slot_view: bool = false,
    /// Typecheck decided the binding's access (`Symbol.access`, null
    /// included): a `match`, `as`, or loop binding.
    access_decided: bool = false,
    /// A compile-time constant whose value Zig sets for the target it
    /// compiles for: a Zig-backed constant (`target.arch`), or a module
    /// constant whose value names one. Rig knows its type, never its
    /// value, so its verdict is the same on every machine.
    per_target: bool = false,
    /// A function declared `inline fun`: it has no address, so it is only
    /// called, never a value.
    inline_marked: bool = false,
    /// A function's type parameter its signature writes after `!`
    /// (`sub each[E](f: ?sub()!E)!E`): bound only to an error set, and
    /// a value of it is an error (errors-spec §3.5).
    set_param: bool = false,
    /// A type parameter of a `pub` declaration: a function's, a type's,
    /// or a method's own (docs/design/apis.md, Stage 3, "Public generics
    /// state their bounds"). Its body is checked against its bounds alone,
    /// as a bounded parameter's is (`checkedByBounds`).
    states_bounds: bool = false,
    _: u14 = 0,
    /// Room for flags to come.
    spare: u31 = 0,
};

/// How a method takes its receiver, from the declared first parameter.
pub const MethodReceiver = enum { none, read, write, value };

/// What a built-in method needs of its type's parameter `T`, declared in
/// its entry of `resolve.registerBuiltins` and checked at every call,
/// `xs.m(...)` and `List.m(xs, ...)` alike: the call's `T` must meet `t`.
/// Inside a generic body, a `T` that may or may not meet it makes the
/// requirement one on each instance, as a Rig-written generic's use does
/// (`Requirement.copies`).
pub const Needs = struct {
    t: enum { copies },
    /// What the method does with a `T`, as the note of a generic body
    /// whose instance fails says it.
    op: []const u8,
    /// How the diagnostic of a call whose `T` fails says it.
    says: union(enum) {
        /// The method hands out a copy of an element it keeps; `advice`
        /// reaches the element instead.
        element_out: []const u8,
        /// The method hands out a copy of the one value it keeps;
        /// `advice` takes it out instead.
        value_out: []const u8,
        /// The method writes copies of a value it leaves in place into
        /// the elements it makes (`Checker.notDuplicated`): `what` it
        /// copies, and the loop, followed by `tail`, that makes each
        /// element with `+x` instead.
        into_elements: struct { what: []const u8, loop: []const u8, tail: []const u8 = "" },
    },
};

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
    /// The struct's user `drop(!@)` body. Not callable.
    is_drop_method: bool = false,
    /// A data field's default value (`name: T = literal`).
    default: ?Sexp = null,
    /// Parameter names of a method, for keyword arguments.
    param_names: ?[]const []const u8 = null,
    /// Default values of a method's parameters (null where none).
    param_defaults: ?[]const ?Sexp = null,
    /// A method: which arguments a call passes loans on from.
    origins: Origins = .{},
    /// A built-in method: what it needs of its type's parameter `T`.
    needs: ?*const Needs = null,
    /// A plain enum's variant: its integer value, declared or implicit.
    value: ?Wide = null,
    /// A field or method declared `pub`, which other modules may use.
    /// (Variants and their payload fields are always visible.)
    is_pub: bool = false,
    /// A field declared `pub ?name: T`: other modules read it, and only
    /// its own module writes it.
    read_only: bool = false,
    /// A method declared `inline fun`, which is only called.
    inline_marked: bool = false,
    /// An API's method with a body: a default, which a type that
    /// provides the API may leave out.
    is_default: bool = false,
    /// A method declared under bounds on its type's parameters (`fun
    /// Wrap[T: Print].show(?@)`): what each adds, which a call's type
    /// arguments must provide.
    owner_bounds: []const OwnerBound = &.{},
};

/// A bound a method adds to one of its type's parameters (`fun Wrap[T:
/// Print].show(?@)`): the parameter, by its place among the type's, and
/// the APIs, built-in and a program's own (docs/design/apis.md, Stage 3,
/// "Bounds"). Within the method the parameter has its type's bounds and
/// these (`widenOwnerBounds`); a call's argument for it must provide
/// them, and passes a witness for each API of a program's own.
pub const OwnerBound = struct {
    param: u32,
    apis: Apis = .empty,
    user_apis: []const ApiRef = &.{},
};

/// The witnesses a call passes a method under bounds (`OwnerBound`), one
/// per API of a program's own in the order written, after self, which is
/// the call's first argument when `receiver_arg` (`Wrap.show(w)`).
pub const OwnerWitnesses = struct {
    witnesses: []const Witness,
    receiver_arg: bool = false,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    ty: TypeId,
    decl_pos: u32,
    scope: ScopeId,
    flags: SymbolFlags = .{},
    /// Members of a nominal or generic type, and the methods of an API;
    /// null for other kinds.
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
    /// A `match`, `as`, or loop binding: whether a write may go through
    /// it, or null for one that owns or copies its value, recorded once by
    /// typecheck from `decideBindingAccess` (`SemContext.bindingAccess`).
    access: ?Access = null,
    /// A parameter, local, or capture: how the binding holds its value,
    /// or null for one that owns nothing to drop (`resourceKind` of its
    /// type), recorded once by the storage plan (`storage.plan`). Emit
    /// gives such a binding `var` storage and a drop guard of this kind,
    /// and the ownership checker asserts it treats the binding as owning
    /// exactly when this is set.
    hold: ?ResourceKind = null,
    /// The previous symbol of the same name in the same scope, if any.
    prev_in_scope: SymbolId = symbol_invalid,
    /// A proxy (`proxyOf`): the other module's generic type or
    /// compile-time parameter it stands for. `.{}` for a symbol declared
    /// here.
    from: ForeignRef = .{},
    /// A type parameter: its bounds (`[T: Ord]`), with what they imply
    /// (`implied`). A nominal or generic type: the APIs its header names
    /// (`obj Name: Eq + Hash`), which it gives a meaning of its own. An
    /// API: the built-in APIs it builds on (`api Job: Sends`).
    apis: Apis = .empty,
    /// The APIs of a program's own that the symbol names where `apis`
    /// names the built-in ones: a type parameter's bounds (`[T:
    /// Shape]`), a type's header (`obj Square: Shape`), an API's
    /// (`api Named: Shape`).
    user_apis: []const ApiRef = &.{},
    /// A type parameter: the built-in bounds its declaration's signature
    /// already requires, which count as stated (`resolve.TypeResolver.implyBounds`):
    /// `K` named in `Map[K, V]` is `K: Hash`. Never written, and never a
    /// reason to check a body by its bounds.
    implied: Apis = .empty,
    /// A union of error sets (`error L = A | B`): the sets it joins, each
    /// a declared set or another union. Null for every other symbol.
    error_parts: ?[]const TypeId = null,
    /// An associated type, a type parameter that its base determines: an
    /// API's own `type Item`, or `S.Item` of a type parameter `S` whose
    /// bounds declare it (`assocParam`). Null for every other symbol.
    assoc_of: ?AssocOf = null,
    /// A type parameter: the associated types made for it, each once.
    assoc: []const SymbolId = &.{},
};

/// What an associated type is: `name` of its `base`'s provider for `api`
/// (docs/design/apis.md, Stage 3: `type Item`, read `I.Item`).
pub const AssocOf = struct {
    base: SymbolId,
    api: AssocApi,
    name: []const u8,
};

/// The API that declares an associated type: the built-in `Iter`, whose
/// `Item` is what `next` gives (`iterItem`), or an API of a program's own
/// that declares `type Item`, which its base reaches through the bound
/// `via` (itself or an API built on it), whose witness names it
/// (`W_S_Source.Item`).
pub const AssocApi = union(enum) {
    iter,
    user: struct { api: ApiRef, via: ApiRef },

    pub fn sameApi(x: AssocApi, y: AssocApi) bool {
        return switch (x) {
            .iter => y == .iter,
            .user => |u| y == .user and u.api.eql(y.user.api),
        };
    }
};

pub const Api = rig.Api;
pub const Apis = std.EnumSet(Api);

/// An API of a program's own, wherever it is declared: the module that
/// declares it (`SemContext.module_id`) and its symbol there. One API has
/// one `ApiRef` in every module.
pub const ApiRef = struct {
    module_id: u32,
    sym: SymbolId,

    pub fn eql(a: ApiRef, b: ApiRef) bool {
        return a.module_id == b.module_id and a.sym == b.sym;
    }
};

/// The context of the module that declares `ref`, which is `ctx` or a
/// module `ctx` imports; null for a module no longer known.
pub fn apiContext(ctx: *const SemContext, ref: ApiRef) ?*const SemContext {
    if (ref.module_id == ctx.module_id) return ctx;
    return ctx.foreign_semas.get(ref.module_id);
}

/// The API `ref` names, as declared.
pub fn apiSymbol(ctx: *const SemContext, ref: ApiRef) ?Symbol {
    const home = apiContext(ctx, ref) orelse return null;
    if (ref.sym >= home.symbols.items.len) return null;
    const sym = home.symbols.items[ref.sym];
    return if (sym.kind == .api) sym else null;
}

/// The name of API `ref` as the module `ctx` spells it: `Shape`, or
/// `geo.Shape` for another module's.
pub fn apiName(ctx: *const SemContext, ref: ApiRef) std.mem.Allocator.Error![]const u8 {
    const sym = apiSymbol(ctx, ref) orelse return "?";
    if (ref.module_id == ctx.module_id) return sym.name;
    const home = apiContext(ctx, ref).?;
    const short = if (std.mem.lastIndexOfScalar(u8, home.name, '.')) |i| home.name[i + 1 ..] else home.name;
    return @constCast(ctx).arena.allocator().print("{s}.{s}", .{ short, sym.name });
}

/// API `ref` and every API it builds on, each once, `ref` first, in the
/// order it names them (docs/design/apis.md, Stage 3: a type that
/// provides an API provides those it builds on). A cycle stops where it
/// closes; `checkApis` reports it.
pub fn apiClosure(ctx: *const SemContext, a: std.mem.Allocator, ref: ApiRef) std.mem.Allocator.Error![]const ApiRef {
    var out: std.ArrayList(ApiRef) = .empty;
    try out.append(a, ref);
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const sym = apiSymbol(ctx, out.items[i]) orelse continue;
        for (sym.user_apis) |s| {
            const seen = for (out.items) |o| {
                if (o.eql(s)) break true;
            } else false;
            if (!seen) try out.append(a, s);
        }
    }
    return out.items;
}

/// The built-in APIs `refs` and every API they build on name (`api Job:
/// Sends`), with what those imply.
pub fn builtInSupers(ctx: *const SemContext, refs: []const ApiRef) std.mem.Allocator.Error!Apis {
    var out: Apis = .empty;
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (refs) |r| {
        for (try apiClosure(ctx, scratch.allocator(), r)) |c| {
            if (apiSymbol(ctx, c)) |sym| out.setUnion(sym.apis);
        }
    }
    return implied(out);
}

/// Whether type parameter `sym` has bounds: built-in ones or APIs of a
/// program's own. One with none is checked at each instance.
pub fn hasBounds(sym: Symbol) bool {
    // An associated type does what its own bounds name, as its base does.
    return sym.apis.count() > 0 or sym.user_apis.len > 0 or sym.assoc_of != null;
}

/// Whether a body's use of type parameter `sym` is checked against its
/// bounds alone: it has bounds, or it is a parameter of a `pub`
/// declaration, which states them (`SymbolFlags.states_bounds`). Any
/// other is checked at each instance.
pub fn checkedByBounds(sym: Symbol) bool {
    return hasBounds(sym) or sym.flags.states_bounds;
}

/// The built-in APIs type parameter `sym`'s bounds give, those its
/// own APIs build on and those its signature implies included, with what
/// they imply.
pub fn boundApis(ctx: *const SemContext, sym: Symbol) Apis {
    var out = implied(sym.apis.unionWith(sym.implied));
    if (sym.user_apis.len > 0) out.setUnion(builtInSupers(ctx, sym.user_apis) catch .empty);
    return out;
}

/// The bounds of `sym` as written, `Shape + Ord`, with `more` added at
/// the end when it is not there yet.
pub fn formatBounds(ctx: *const SemContext, a: std.mem.Allocator, sym: Symbol, more: ?Api) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (sym.user_apis) |r| {
        if (out.items.len > 0) try out.appendSlice(a, " + ");
        try out.appendSlice(a, try apiName(ctx, r));
    }
    var apis = sym.apis;
    if (more) |m| apis.insert(m);
    var it = apis.iterator();
    while (it.next()) |api| {
        if (out.items.len > 0) try out.appendSlice(a, " + ");
        try out.appendSlice(a, @tagName(api));
    }
    return out.items;
}

/// The error that a body does with type parameter `sym` what `api` gives
/// (`what`), and its bounds do not name it, with the bound to add; an
/// associated type with no bound of its own is given one.
pub fn unboundedMessage(ctx: *const SemContext, a: std.mem.Allocator, sym: Symbol, api: Api, what: []const u8) std.mem.Allocator.Error![]const u8 {
    const written = try formatBounds(ctx, a, sym, null);
    if (written.len == 0) return a.print("`{s}` has no bound, so it does not give {s}; give it one: `[{s}: {s}]`", .{ sym.name, what, sym.name, @tagName(api) });
    return a.print("`{s}` is bounded by `{s}`, which does not give {s}; add `{s}` to its bounds: `[{s}: {s}]`", .{ sym.name, written, what, @tagName(api), sym.name, try formatBounds(ctx, a, sym, api) });
}

/// What a body does with a `T` that `api` gives, as the error that a
/// `pub` generic does not state the bound says it: `adds `T`s`. `op` is
/// the operator or method the body applies, or empty.
pub fn boundUse(a: std.mem.Allocator, api: Api, tname: []const u8, op: []const u8) std.mem.Allocator.Error![]const u8 {
    const verbs = [_]struct { []const u8, []const u8 }{ .{ "+", "adds" }, .{ "-", "subtracts" }, .{ "*", "multiplies" }, .{ "/", "divides" } };
    for (verbs) |v| if ((api == .Num or api == .Integer) and std.mem.eql(u8, op, v[0])) return a.print("{s} `{s}`s", .{ v[1], tname });
    const operator = op.len > 0 and op.len <= 3 and !std.ascii.isAlphabetic(op[0]);
    return switch (api) {
        .Num, .Integer => if (operator) a.print("applies `{s}` to `{s}`s", .{ op, tname }) else a.print("does arithmetic on `{s}`s", .{tname}),
        .Signed => a.print("negates a `{s}`", .{tname}),
        .Eq => a.print("compares `{s}`s with `==`", .{tname}),
        .Ord => a.print("orders `{s}`s", .{tname}),
        .Hash => a.print("hashes a `{s}`", .{tname}),
        .Print => a.print("prints a `{s}`", .{tname}),
        .Copy => a.print("copies a `{s}`", .{tname}),
        .Clone => a.print("clones a `{s}`", .{tname}),
        .Owned => a.print("keeps a `{s}` where no loan is tracked", .{tname}),
        .Sends => a.print("sends a `{s}` to another task", .{tname}),
        .Syncs => a.print("lets several tasks read a `{s}`", .{tname}),
        .Iter => a.print("iterates a `{s}`", .{tname}),
    };
}

/// A bound a `pub` declaration's error asks for: a built-in API, or an
/// API of a program's own.
pub const StatedBound = union(enum) { api: Api, user: ApiRef };

/// The error that `pub` declaration's body does with its type parameter
/// `param` what `api` gives (`does`, from `boundUse`), and its bounds do
/// not name it, with the bounds to write: `` `pub fun sum[T]` adds `T`s:
/// write `[T: Num]` ``. The bounds are those written with `api` added,
/// less one another implies (`Hash` gives `Eq`); `user` adds an API of a
/// program's own instead. Reported at the parameter, in the brackets the
/// fix rewrites (`tools/state-bounds.py`); null for a parameter that is
/// not one of a `pub` declaration of this module.
pub fn statedMessage(ctx: *const SemContext, a: std.mem.Allocator, param: SymbolId, add: StatedBound, does: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const sym = ctx.symbols.items[param];
    if (!sym.flags.states_bounds) return null;
    const decl = ctx.stated.get(param) orelse return null;
    var shown = sym;
    switch (add) {
        .api => |api| {
            var all = sym.apis;
            all.insert(api);
            shown.apis = strongest(all);
        },
        .user => |ref| shown.user_apis = try std.mem.concat(a, ApiRef, &.{ sym.user_apis, &.{ref} }),
    }
    return try a.print("`{s}` {s}: write `[{s}: {s}]`", .{ decl, does, sym.name, try formatBounds(ctx, a, shown, null) });
}

/// Reports, when type parameter `param` is one of a `pub` declaration of
/// this module, that its body does at `at` what `does` says, and its
/// bounds do not name `add`: at the parameter, with a note where the body
/// does it. False otherwise, for the caller's own error.
fn reportStatedBound(ctx: *SemContext, at: u32, param: SymbolId, add: StatedBound, does: []const u8) std.mem.Allocator.Error!bool {
    const a = ctx.arena.allocator();
    const sym = ctx.symbols.items[param];
    const msg = (try statedMessage(ctx, a, param, add, does)) orelse return false;
    const before = ctx.diagnostics.items.len;
    try ctx.err(sym.decl_pos, "{s}", .{msg});
    if (ctx.diagnostics.items.len > before) try ctx.note(at, "here", .{});
    return true;
}

/// `reportStatedBound` for a built-in API, the body applying `op` (an
/// operator or method, or empty).
pub fn reportStated(ctx: *SemContext, at: u32, param: SymbolId, api: Api, op: []const u8) std.mem.Allocator.Error!bool {
    return reportStatedBound(ctx, at, param, .{ .api = api }, try boundUse(ctx.arena.allocator(), api, ctx.symbols.items[param].name, op));
}

/// `reportStatedBound` for `lack`, when it is a bound of a type parameter
/// (`Lack.bound`), the body doing what `does` says, or what `boundUse`
/// says of `api` when null.
pub fn reportStatedLack(ctx: *SemContext, at: u32, api: Api, lack: Lack, does: ?[]const u8) std.mem.Allocator.Error!bool {
    if (!lack.bound) return false;
    return switch (ctx.types.get(lack.ty)) {
        .type_var => |p| reportStatedBound(ctx, at, p, .{ .api = api }, does orelse try boundUse(ctx.arena.allocator(), api, ctx.symbols.items[p].name, "")),
        else => false,
    };
}

/// `reportStatedBound` for `api`, an API of a program's own that type
/// parameter `arg` does not provide, the body doing what `does` says.
pub fn reportStatedUser(ctx: *SemContext, at: u32, arg: TypeId, api: ApiRef, does: []const u8) std.mem.Allocator.Error!bool {
    return switch (ctx.types.get(arg)) {
        .type_var => |p| reportStatedBound(ctx, at, p, .{ .user = api }, does),
        else => false,
    };
}

/// How a type provides an API of a program's own: by its header (`obj
/// Square: Shape`) or by an addition (`add Int: Shape`). Recorded in the
/// module that writes it (`SemContext.conformances`); `provides` is the
/// one answer to whether a type provides an API.
pub const Conformance = struct {
    api: ApiRef,
    /// The type, in the writing module's store: a nominal type, a generic
    /// type at its own parameters (a header) or the addition's (`add
    /// Wrap[T: Shape]`), or a built-in type.
    ty: TypeId,
    /// The module that writes it.
    module_id: u32,
    /// Where: the type's name for a header, the `add` for an addition.
    pos: u32,
    kind: enum { header, add },
    /// An addition's own type parameters, each with the bounds the
    /// type's arguments must meet.
    params: []const SymbolId = &.{},
    /// An addition's methods; a header's are its type's own.
    methods: []const Field = &.{},
    /// An addition's `Self`, the symbol its methods are checked under.
    self_sym: SymbolId = symbol_invalid,
    /// The type it gives each associated type of its API and those it
    /// builds on, in terms of its own parameters (`conformanceAssoc`),
    /// what its methods give in the API's place (`inferAssoc`).
    assoc: []const AssocBinding = &.{},
    assoc_state: enum { pending, computing, done } = .pending,
    /// What its witness names for each method of the API and those it
    /// builds on, in their order (`typecheck.checkConformance`): emit
    /// writes the witness from these alone.
    members: []const WitnessMember = &.{},
};

/// The type a conformance gives the associated type `name` of `api`.
pub const AssocBinding = struct {
    api: ApiRef,
    name: []const u8,
    ty: TypeId,
};

/// A method of a conformance's witness, and where its body is: the
/// type's own method (a header), the addition's (`add Int: Shape`), or
/// the default of the API that declares it.
pub const WitnessMember = struct {
    name: []const u8,
    from: union(enum) { own, added, default: ApiRef },
};

/// How a call reaches the method it calls (docs/design/apis.md, Stage 3,
/// "Lowering"), recorded once per method call (`SemContext.dispatchOf`):
/// `direct`, the method the receiver's type declares, which Zig finds on
/// the value, a call on a `T` with no bound included, which each instance
/// resolves; `static`, through the witness by which the receiver's type
/// provides the API that declares the method.
pub const Dispatch = union(enum) {
    direct,
    static: Static,
    /// Through an API object's table (docs/design/apis.md, Stage 4):
    /// `s.area()` of a `?{Shape}`, its entry `slot` of the table, which
    /// calls the hidden type's method (`objectMethods`).
    dynamic: Dynamic,

    /// Whether the call reaches an API's method, through a witness or a
    /// table, checked by the API's declaration and its clauses alone: the
    /// one test every pass asks, so none skips a form.
    pub fn viaApi(d: Dispatch) bool {
        return d != .direct;
    }

    /// The API that declares the method a call through an API reaches,
    /// and its name; null for a direct call.
    pub fn apiMethod(d: Dispatch) ?struct { api: ApiRef, method: []const u8 } {
        return switch (d) {
            .direct => null,
            .static => |s| .{ .api = s.api, .method = s.method },
            .dynamic => |y| .{ .api = y.api, .method = y.method },
        };
    }

    pub const Dynamic = struct {
        /// The API that declares the method, and its name.
        api: ApiRef,
        method: []const u8,
        /// Its entry in the object's table (`ObjectMethod.slot`).
        slot: u32,
        /// How the method takes self.
        self_mode: MethodReceiver = .read,
        /// The object is the call's first argument (`Shape.area(s)`).
        receiver_arg: bool = false,
    };

    pub const Static = struct {
        witness: Witness,
        /// The API that declares the method, and its name.
        api: ApiRef,
        method: []const u8,
        /// The receiver is the call's first argument (`Shape.area(c)`),
        /// not the object of `c.area()`.
        receiver_arg: bool = false,
        /// How the method takes self.
        self_mode: MethodReceiver = .read,
    };
};

/// The compile-time argument by which a body reaches a type's methods for
/// an API of a program's own: a bound's own parameter `W_T_Shape`, which
/// a declaration takes after the type it bounds, or the namespace a
/// conformance declares beside it, `__rig_impl_Shape_Square`.
pub const Witness = union(enum) {
    /// Type parameter `sym`'s witness for `api`, one of its bounds as
    /// written, which is or builds on the API asked for.
    param: struct { sym: SymbolId, api: ApiRef },
    /// The witness of the conformance `index` of module `module_id`, for
    /// `ty`, a type of the module that names it. A generic type's takes
    /// the type's arguments, each followed by the witnesses the
    /// conformance's bounds on it ask for (`args`).
    conformance: struct { module_id: u32, index: u32, ty: TypeId, args: []const ArgWitness = &.{} },
};

/// A witness among compile-time arguments, written after type argument
/// `arg`: a generic function's or type's, or a conformance's.
pub const ArgWitness = struct { arg: u32, witness: Witness };

/// `apis` with what each implies: `Hash` and `Ord` need `Eq`, `Integer`
/// and `Signed` need `Num`, and a value that copies also clones.
pub fn implied(apis: Apis) Apis {
    var out = apis;
    if (out.contains(.Hash) or out.contains(.Ord)) out.insert(.Eq);
    if (out.contains(.Integer) or out.contains(.Signed)) out.insert(.Num);
    if (out.contains(.Copy)) out.insert(.Clone);
    return out;
}

/// `apis` less each API the others imply: `Hash + Eq` is `Hash`.
pub fn strongest(apis: Apis) Apis {
    var out = apis;
    var it = apis.iterator();
    while (it.next()) |x| {
        var others = apis;
        others.remove(x);
        if (implied(others).contains(x)) out.remove(x);
    }
    return out;
}

/// `apis` as a bound is written: `Ord + Print`, in declared order.
pub fn formatApis(a: std.mem.Allocator, apis: Apis) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = apis.iterator();
    while (it.next()) |api| {
        if (out.items.len > 0) try out.appendSlice(a, " + ");
        try out.appendSlice(a, @tagName(api));
    }
    return out.items;
}

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
    for ([_][]const u8{ "Cell", "List" }) |c| t.offer(c);
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

/// Whether an error member's fields compare with `==`, and hash.
pub const MemberCompares = struct { eq: bool = false, hash: bool = false };

/// The key of a node a fact is recorded for: a node the parser built.
fn recordKey(node: Sexp) NodeKey {
    return nodeKey(node) orelse std.debug.panic("sema recorded a fact for a node without a node id: {s}", .{if (node.kind()) |k| @tagName(k) else @tagName(node)});
}

/// The key of a decision about a node (`Question`): its `exprKey`, or, for
/// a list node a rewrite built without a number, its items' address, which
/// no other node shares while the tree lives (bit 33 set).
fn decisionKey(node: Sexp) ?u64 {
    if (exprKey(node)) |k| return k;
    if (node != .list) return null;
    return @as(u64, @intFromPtr(node.list.items().ptr)) | 1 << 33;
}

/// `decisionKey` for the passes outside sema that key a fact by node
/// (`typecheck.recordFrameOwners`).
pub fn decisionKeyOf(node: Sexp) ?u64 {
    return decisionKey(node);
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

/// A local task (`Facts.local_tasks`), for `rig check --tasks`: where
/// its call starts, the call as written, and why it stays on one
/// thread: the part that pins it and the type in it that does not cross.
pub const LocalTask = struct { pos: u32, call: []const u8, why: []const u8 };

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
    /// Expressions whose value becomes an optional where it goes (`Lift`):
    /// `none`, and a `T` where a `T?` goes, which Zig lifts on its own
    /// (`SemContext.recordLift`).
    lifts: std.AutoHashMapUnmanaged(u64, Lift) = .empty,
    /// `a ?? b` and `a catch b` whose fallback is a value, not a view, of
    /// what the payload of `a`, a view, reaches: the payload's value is
    /// copied out (`SemContext.recordPayloadCopy`).
    payload_copies: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
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
    /// A compile-time function's call -> its value (`CtCall`).
    ct_calls: std.AutoHashMapUnmanaged(NodeKey, CtCall) = .empty,
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
    /// argument, a view lent to a call, an `==` operand, a `?@`
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
    /// The `Bool`s that decide a test, its last line and each `return`
    /// with a value in it -> what a failing one reports.
    test_checks: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// The calls of `task.all`, which wait for the tasks they take
    /// (`Checker.taskJoin`).
    task_joins: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `par.map` and `par.each`, which run a function on
    /// several tasks (`Checker.parCall`).
    par_calls: std.AutoHashMapUnmanaged(u64, ParCall) = .empty,
    /// `*Actor(x)` calls (`Checker.actorMake`) and method calls through
    /// an actor's handle (`Checker.actorCall`).
    actor_makes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    frozen_makes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// `*Chan[T](n)` calls (`Checker.chanMake`), `task.select` calls
    /// (`Checker.taskSelect`), and their arms, receiving or sending.
    chan_makes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    select_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    select_arms: std.AutoHashMapUnmanaged(u64, SelectArm) = .empty,
    /// `*Actor.supervised(f)` calls (`Checker.actorSupervised`).
    actor_supervised: std.AutoHashMapUnmanaged(u64, void) = .empty,
    actor_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The method calls made on a value of a type parameter
    /// (`Checker.typeParamCall`), whose method each instance gives.
    type_param_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `task.isolate` (`Checker.isolateCall`).
    isolate_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `task.supervise` (`Checker.isolateCall`).
    supervise_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `http.serve` (`Checker.httpServe`).
    http_serves: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `io.copy` (`Checker.ioCopy`).
    io_copies: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The calls of `xs.reduce(start, f)` (`Checker.reduceCall`).
    reduce_calls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Closure literals called at most once, by the call they are passed
    /// to (`SemContext.recordOnceClosure`).
    once_closures: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// `f(x)&` tasks that are local, pinned to the thread of the task
    /// that makes them (`Checker.crossCheck`), with what pins each.
    local_tasks: std.AutoHashMapUnmanaged(u64, LocalTask) = .empty,
    /// Values a context reads, takes, or lends (`Use`), keyed by the
    /// value: a name, or a value that yields one of its parts
    /// (`valueParts`). Emit moves a name at a tail of the value out of
    /// its binding only where the value is taken.
    uses: std.AutoHashMapUnmanaged(u64, Use) = .empty,
    /// Header nodes (`for`, `match`, `as`) whose subject is bare and
    /// not plain data -> how the header has it (`Header`).
    headers: std.AutoHashMapUnmanaged(NodeKey, HeaderFact) = .empty,
    /// `String(...)` call node, or `t.add` / `t.clear` callee node -> the
    /// built-in String operation it is (`StringCall`).
    string_calls: std.AutoHashMapUnmanaged(NodeKey, StringCall) = .empty,
    /// `t.push[T, e]` callee node -> the integer type `T` it appends.
    string_nums: std.AutoHashMapUnmanaged(NodeKey, TypeId) = .empty,
    /// `<place` nodes that take an optional out of a field or element
    /// (`SemContext.recordTake`).
    takes: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// `*w` nodes that upgrade a weak handle -> whether each reads or
    /// takes it (`SemContext.recordUpgrade`).
    upgrades: std.AutoHashMapUnmanaged(NodeKey, Upgrade) = .empty,
    /// Header nodes (`match`, `for`, `as`) emitted over a copy of their
    /// subject: the subject makes a statement temporary, reaches no
    /// place, and the construct does not own what it binds
    /// (`SemContext.recordHeaderCopy`).
    header_copies: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Assignments of a view to a `!T` or `![]T` local, which point it
    /// at another place (`SemContext.recordRepoint`).
    repoints: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Assignments of a value to a `!T` binding, which write the value it
    /// views rather than give the binding another
    /// (`SemContext.recordWriteThrough`).
    write_throughs: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Element reads (`x[i]`) that copy the element's value out
    /// (`SemContext.copiesElem`).
    elem_copies: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Payload bindings of a variant pattern -> the type of the field
    /// each binds, at the matched instance and in this module's types
    /// (`SemContext.recordPayloadField`).
    payload_fields: std.AutoHashMapUnmanaged(u64, TypeId) = .empty,
    /// `E.name` nodes that name a member of an error set `E`, through
    /// its module or an alias (`SemContext.recordErrorMember`).
    error_members: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// `x == K.name` nodes whose side `K.name` names a variant of `x`'s
    /// enum: a test of which variant `x` holds, comparing no payload
    /// (`SemContext.recordMemberTest`).
    member_tests: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// A `g: E =>` pattern -> the members of `E` it covers that no arm
    /// before it did: what its Zig prong lists
    /// (`SemContext.recordSetPatternMembers`).
    set_pattern_members: std.AutoHashMapUnmanaged(NodeKey, []const SetMember) = .empty,
    /// The error values that leave their function by failing: a
    /// `return`'s operand, or a branch of one, of an error type where a
    /// `T!` goes (`SemContext.recordFailingLeaf`). Emit stores the fields
    /// of one with fields through the function's `__out`.
    failing_leaves: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The errors of a set without fields that go where an error that
    /// carries fields goes, `error` or a set with fields
    /// (`SemContext.recordCodeWidening`). Emit makes each a
    /// `rig.ErrorValue` with none.
    code_widenings: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Whether the fields of each error-set member that has them compare
    /// with `==` and hash, by the member's name in its declaration
    /// (`SemContext.recordMemberCompares`): the program's glue compares
    /// and hashes only those.
    member_compares: std.AutoHashMapUnmanaged(u64, MemberCompares) = .empty,
    /// `e.text` nodes: the name of plain enum value `e`'s variant, a
    /// `Static` (`SemContext.recordEnumText`).
    enum_texts: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// `t[s]` index nodes of a table that a write reaches: assigned, lent
    /// to write, written through, or taken from (`Checker.requireAccess`).
    /// Every other slot is read, and is reached read-only, so a table
    /// held as it is written never grows for a read
    /// (`SemContext.recordTableWrite`).
    table_writes: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// Variant pattern node -> the binding of each payload field of its
    /// variant, in field order (`SemContext.payloadBindings`).
    payload_binds: std.AutoHashMapUnmanaged(NodeKey, []const Sexp) = .empty,
    /// `break` and `continue` nodes -> where each goes (`JumpDest`),
    /// which the type checker resolves (`SemContext.jumpDestOf`).
    jump_dests: std.AutoHashMapUnmanaged(NodeKey, JumpDest) = .empty,
    /// Scalar operands of a lane-wise operator or of `select` (`exprKey`)
    /// -> the vector type they stand for, every lane theirs
    /// (`SemContext.recordSplat`).
    splats: std.AutoHashMapUnmanaged(u64, TypeId) = .empty,

    /// A member access `x.f` whose field another module declared `pub
    /// ?f: T`: read-only here (`Checker.placeOf` blocks every write
    /// through it).
    read_only_fields: std.AutoHashMapUnmanaged(NodeKey, ReadOnlyField) = .empty,
    /// Method call node -> how it reaches its method (`Dispatch`).
    dispatch: std.AutoHashMapUnmanaged(NodeKey, Dispatch) = .empty,
    /// A call of a method under bounds -> the witnesses it passes for
    /// them (`OwnerWitnesses`).
    owner_witnesses: std.AutoHashMapUnmanaged(NodeKey, OwnerWitnesses) = .empty,
    /// A value erased to an API object (`exprKey`) -> what was erased,
    /// to which object, by which witness (`Erasure`).
    erasures: std.AutoHashMapUnmanaged(u64, Erasure) = .empty,

    fn deinit(self: *Facts, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Facts).@"struct".field_names) |f| @field(self, f).deinit(allocator);
    }
};

/// The optional an expression's value becomes where it goes: `into`,
/// an optional type, holding the value `from` gives, a type with fewer
/// levels of optional (`none`'s, for `none`), lifted into it level by
/// level (`SemContext.recordLift`).
pub const Lift = struct { into: TypeId, from: TypeId };

/// How `*w` upgrades the weak handle `w` (`SemContext.recordUpgrade`).
pub const Upgrade = enum {
    /// `w` is read where it is, and stays usable: a place, a part of a
    /// value, a lend, a branching value, or a view.
    reads,
    /// `w` is handed over and dropped once upgraded: a move (`*<w`) or a
    /// weak handle made there (`*~h`, `*f()`).
    takes,
};

/// A field another module declared `pub ?name: T`, as a member access
/// here reaches it: its name, its type's name, and its module's.
pub const ReadOnlyField = struct {
    field: []const u8,
    owner: []const u8,
    module: []const u8,
};

/// How a node writes a binding (`SemContext.recordWrite`). Every site
/// where a binding's value may change is one of these, recorded where
/// resolve or typecheck finds it: the binding's `reassigned` and
/// `written` flags are derived from the record, and the proof pass
/// (`src/proofs.zig`) reads it to know what a node changes.
pub const WriteKind = enum {
    /// `x = e` of an existing binding (the `set` node).
    assign,
    /// `x op= e` (the `set` node; its op and value say which).
    compound,
    /// `!x`, `!x.f`, `!x[i]` (the `write` node), and `for e in !x` (the
    /// `for` node): a write view of the binding, or of a part of it.
    lend_write,
    /// `x.f = e` or `x[i] = e` (the `set` node).
    elem_store,
    /// `<x.f` taking an optional out of a part (the `move` node).
    take,
    /// `|!x|`: a closure lent `x` to write (the `cap_write` node).
    capture,
    /// `<x` of the binding itself (the `move` or `drop` node), which
    /// leaves it moved until it is assigned again.
    move,
};

pub const WriteSite = struct { sym: SymbolId, kind: WriteKind };

/// A step of a walk over a body's units (`rig.eachUnit`), as emit writes
/// them and as the proof pass walks them: the unit-order test compares
/// the two (`proofs.checkUnitOrder`).
pub const UnitEvent = union(enum) {
    enter: NodeKey,
    exit: NodeKey,
    /// Emit stops writing a unit's code to write other units' (a
    /// statement `match`'s arms), and takes it up again: the same
    /// occurrence of the unit.
    pause: NodeKey,
    @"resume": NodeKey,
    /// A `break` or `continue`, and the point of its target it goes to.
    jump: struct { node: NodeKey, to: JumpDest.To },
};

/// Which of a node's tests are known to pass (docs/internals/INTERNALS.md, "Proven
/// checks"): recorded by `src/proofs.zig` alone, on an index, a `read` or
/// `write` element call's callee, a `+`, or a `+=` set, and read by emit
/// through `Facts.provenOf`. A node with no entry keeps every test.
pub const Proven = packed struct(u8) {
    /// `0 <= index` is known.
    lower: bool = false,
    /// `index + width <= len` is known.
    upper: bool = false,
    /// The `+` cannot overflow.
    no_overflow: bool = false,
    _: u5 = 0,

    pub fn any(p: Proven) bool {
        return p.lower or p.upper or p.no_overflow;
    }
};

/// Of a node: the tests known to pass while the flag `flag` holds, besides
/// those `Proven` gives always (docs/internals/INTERNALS.md, "Flags").
/// Recorded by `src/proofs.zig` alone, on the nodes `Proven` is, and read
/// by emit through `Facts.provenIfOf`.
pub const ProvenIf = struct {
    tests: Proven,
    /// The statement whose flag it is (`SemContext.flagOf`).
    flag: NodeKey,
};

/// A binding, or a field of one (a field path from it), whose length a
/// flag's test reads: by the symbol of its root and the field names after
/// it.
pub const FlagPlace = struct { root: SymbolId, fields: []const []const u8 = &.{} };

/// One test of a flag (`SemContext.flagOf`), each of an own binding's
/// value or a place's length as the statement starts.
pub const FlagTest = union(enum) {
    /// `0 <= i`.
    nonneg: SymbolId,
    /// `i + k <= s.len`, exactly.
    below: struct { i: SymbolId, k: u64, s: FlagPlace },
};

/// What a function bounds of its result on every path that returns
/// (docs/internals/INTERNALS.md, "Proven checks"): `0 <= v <= hi` of the result
/// itself, an `Int`, or of named `Int` fields of the struct it returns.
/// Written only by `src/proofs.zig`, for a module the ownership checker
/// accepted, and read by the proof pass of each module that calls it.
pub const ResultBound = struct {
    /// The bound of an `Int` result.
    whole: ?u64 = null,
    /// The bounds of the fields of a struct result.
    fields: []const FieldBound = &.{},

    /// The bound of field `name`, or null.
    pub fn field(b: ResultBound, name: []const u8) ?u64 {
        for (b.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.hi;
        return null;
    }
};

/// `0 <= field <= hi` of a struct a function returns.
pub const FieldBound = struct { name: []const u8, hi: u64 };

/// How a header (`for`, `match`, `if … as`, `while … as`) has a bare
/// subject that is not plain data (docs/internals/INTERNALS.md, "Header subjects").
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

/// Where a `break` or `continue` goes (docs/internals/INTERNALS.md, "Loops"): the
/// construct it names and the point of it it goes to. The type checker
/// resolves every jump once, lexically (`Checker.resolveJump`), and emit
/// and the ownership checker read the answer.
pub const JumpDest = struct {
    /// The `while` or `for` a jump leaves or continues, or the `match` or
    /// `raw` block a labeled `break` leaves.
    target: Sexp,
    to: To,

    pub const To = enum {
        /// Past the construct: a `break`.
        exit,
        /// The loop's step, which runs before the next iteration: a
        /// `continue` from the body of a `while` with a step, or from its
        /// condition when the step is the loop's continue expression
        /// (`storage.StepPoint`).
        step,
        /// The loop's head, the next iteration's condition: a `continue`
        /// in a loop with no step, from a step, or from a condition whose
        /// step runs after the body.
        head,
    };
};

/// A hidden storage location emit makes for an expression or construct
/// (docs/internals/INTERNALS.md, "Storage facts"): decided once, before ownership
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
    /// Whether an inclusive range `for` runs again (`__rig_more`): its
    /// counter never steps past the end, which may be its type's largest
    /// value.
    range_more,
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
    /// The copy an API object of a read view of plain data, or of a type
    /// parameter's value, views (`Erasure.copy`), a local of the erasing
    /// block (`__rig_erased`).
    erased_copy,
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
    /// The value an assignment's target path starts from, evaluated after
    /// the value and before the indexes (`__rig_base`).
    base,
    /// An index of an assignment's target, evaluated before the store
    /// (`__rig_ix`).
    index,
    /// The place an assignment stores to, found once (`__rig_slot`).
    slot,
    /// The several results a call gives, held for its statement while
    /// each target takes its own, left to right (`__rig_res`): a
    /// destructure's, `q, r = f()`. A result no target takes (`_`) it
    /// drops at the statement's end.
    results,
    /// A value made here whose address emit takes where Zig holds it, in
    /// no slot: a leaf no statement slot keeps (`storage.leafStep` is
    /// `made`, and not `dropsTemp`), or a literal, reached by address.
    /// No name of its own: the storage is Zig's, which keeps it until its
    /// statement ends.
    zig_temp,
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
    /// Until the block it is made in ends: each pass of a loop's body
    /// makes it anew.
    block,
};

/// A question about a node whose answer emit, the storage plan, and the
/// checkers all act on: decided once, the first time a pass asks it, and
/// recorded (`SemContext.decided`). Every later ask, emit's included,
/// reads the record, so no two passes act on different answers; the
/// storage plan asks each again at its end, from the facts as they then
/// stand, stops at one whose answer changed after it was recorded
/// (`storage.verifyDecisions`), and seals the record: nothing asked later
/// is recorded. Emit only reads them (`Facts`).
pub const Question = enum(u8) {
    /// How the walk that reaches a value by address reaches this node
    /// (`storage.LeafStep`).
    leaf_step,
    /// Whether this value is reached where its leaves are
    /// (`storage.reachesLeaf`).
    reaches_leaf,
    /// Of a `match`: whether it switches on its subject where it is
    /// (`storage.matchesInPlace`).
    matches_in_place,
    /// Of a `match`: whether it reads, writes, or takes its subject
    /// (`storage.matchMode`).
    match_mode,
    /// Of a `match`: whether it reads its subject again after picking an
    /// arm (`storage.matchRereads`).
    match_rereads,
    /// Of a `match`: whether it evaluates its subject first, in a block
    /// (`storage.matchBlock`).
    match_block,
    /// Of a `match`: how `__rig_subject` holds its subject, if it does
    /// (`storage.subjectHold`).
    subject_hold,
    /// Of a `match`: whether its subject is a view a call returns, held as
    /// a pointer, which it switches on where it points
    /// (`storage.holdsView`).
    holds_view,
    /// Of a read `match`'s catch-all binding: whether it is captured by
    /// address where the match switches (`storage.catchAllCaptured`).
    catch_all_by_address,
    /// Of a payload binding: whether it points at the field it binds
    /// (`storage.bindsByAddress`).
    payload_by_address,
    /// Of a `for`: whether it consumes its source, handing its elements
    /// over one at a time (`storage.forConsumes`).
    for_consumes,
    /// Of a `print`, `String(...)`, or `add` argument: whether it is read
    /// by address (`storage.printsByAddress`).
    print_by_address,
    /// Of an operand of `==` or `!=` beside `none` or a bare `.variant`:
    /// whether the test drops it (`storage.dropsWhenTested`).
    drops_when_tested,
    /// What an expression hands over (`handsOver`'s kind), which the plan
    /// decides for every expression (`storage.handsKind`).
    hands,
    /// Of a header's subject: whether its block yields the address of the
    /// place the subject reaches (`storage.headerPoints`).
    header_points,
    /// Of an `as` value: whether the binding views the value inside the
    /// optional (`storage.viewsOptionalValue`).
    views_optional_value,
    /// Of a call or an array literal: whether its arguments or elements
    /// are evaluated first, into storage (`storage.hoistsArgs`).
    hoists_args,
    /// Of a call: how it holds its receiver while its arguments run, if it
    /// does (`storage.receiverHold`).
    receiver_hold,
    /// Of a call: whether its receiver is a temporary the method consumes
    /// (`storage.consumedTemporary`).
    consumes_receiver,
    /// Of a call argument or an array element: how a call or an array
    /// literal that evaluates its parts first holds it
    /// (`storage.argumentHold`).
    argument_hold,
    /// Of an argument, an assigned value, or an index: whether it is pure,
    /// so it stays where it is (`storage.isPureArg`).
    pure_arg,
    /// Of an arithmetic expression (`+`, `-`, `*`, `-v`) or a compound
    /// assignment of one: whether it works on the integer lanes of a vector
    /// and so is made by a checking runtime helper (`storage.laneChecked`).
    lane_checked,
    /// Of an assignment: which of its steps are evaluated into storage in
    /// their turn, and whether the value made first is dropped if a later
    /// step leaves (`storage.setOrder`).
    set_order,
    /// Of a `while`: where its step runs, as the loop's continue
    /// expression or after the body in the condition's bindings
    /// (`storage.stepPoint`).
    step_point,
    /// Of a box or a binding: whether the fill `[n of x]` it takes is
    /// built where its value goes (`storage.fillsInPlace`).
    fills_in_place,
    /// Of a value emit holds in hidden storage or discards: how it is
    /// held and dropped when nothing takes it, or null when it owns
    /// nothing (`storage.dropKind`).
    drop_kind,
};

/// A recorded answer to a `Question`, with the node it is about.
pub const Decision = struct { node: Sexp, at: Sexp = .nil, answer: u8 };

/// The `Question`s decided so far. Held behind a pointer, so a pass that
/// reads the context as constant still records the answer it is first to
/// reach, as a memo would.
/// Facts of a type that are asked often and cost a walk of what it holds,
/// each worked out on its first ask (through a `*const SemContext`, as
/// the decisions are) and kept, once declarations are resolved and the
/// answer can no longer change.
pub const TypeMemo = struct {
    /// `runsDropBody` of a type, with nothing yet looked into.
    drop_body: std.AutoHashMapUnmanaged(TypeId, bool) = .empty,
    /// `printable` of a type.
    printable: std.AutoHashMapUnmanaged(TypeId, bool) = .empty,
};

pub const Decided = struct {
    map: std.AutoHashMapUnmanaged(struct { node: u64, q: Question }, Decision) = .empty,
    /// Set when the storage plan has verified every answer: a question
    /// asked after that (by a classifier emit still calls, `Pending`) is
    /// answered but not recorded, so a record always comes from a pass
    /// the checkers ran.
    sealed: bool = false,
};

/// The key of a storage fact: the expression or construct (`exprKey`)
/// and the kind of storage made for it.
pub const StorageKey = struct { node: u64, kind: StorageKind };

/// What a context does with a value (Core §3).
pub const Use = enum {
    /// Reads it where it is: a `print` argument, an `==` operand, `+e`,
    /// a `?@` receiver, a field or element read.
    read,
    /// Takes it: a binding, an argument, a stored field or element,
    /// `return`, a `break` value, a consuming receiver, a header that
    /// binds it.
    take,
    /// Lends it: `?e`, `!e`.
    lend,
};

/// A built-in method on the elements of a slice, an array, a List, or a
/// `?String`: `!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`, `xs.sum()`
/// and `xs.sum(start: n)` of numbers (`elem` their type), and on
/// bytes `buf.read[U16, .big](at)` and `!buf.write[U32, .little](at, v)`
/// (`num` a number type or a vector of numbers);
/// and the methods of an integer's bits: `x.not()`, the complement of an
/// integer or a `Bool`, or lane by lane of a vector, and
/// `x.swap_bytes()` (`elem` and `num` are its type), and
/// `x.leading_zeros()`, `x.trailing_zeros()`, and `x.count_ones()` (`num`
/// is the integer's type, `elem` the `Int` they give); `f.to_bits()`
/// (`num` is the float's type, `elem` the unsigned integer of its width);
/// the functions of a type, which take an integer (`elem` is its type):
/// `I32.wrap(x)` (`num` the target), `Float.from_bits(u)` (`num` the
/// float, `elem` the unsigned integer), `Status.from_int(n)` and
/// `Status.from_text(word)` (`num` the enum); and the methods of
/// a vector (`isSimd`), where `num` is the vector and `elem` its lane
/// type: `Simd[T, n].splat(x)`, `m.bits()`, `m.first()`, `m.any()`, `m.all()`,
/// `v.array()`, `v.with(i, x)`, `m.select(a, b)`, whose `num` is the
/// mask and `elem` the lane type of the vector it gives, `t.lookup(idx)`,
/// whose `num` is the index vector's type and `elem` its lane type, and
/// `v.lag[k](prev)`.
pub const ElemCall = struct {
    op: ElemOp,
    /// The receiver's element type.
    elem: TypeId,
    /// `read` / `write`: the integer or float type of the value.
    num: TypeId = type_invalid,
};

pub const ElemOp = enum {
    copy,
    fill,
    swap,
    read,
    write,
    not,
    leading_zeros,
    trailing_zeros,
    count_ones,
    swap_bytes,
    to_bits,
    from_bits,
    wrap,
    from_int,
    /// `E.from_text(word)`: the variant of plain enum `num` named
    /// `word`, a `?String` (`elem`).
    from_text,
    nan,
    inf,
    fraction,
    exponent,
    splat,
    bits,
    first,
    any,
    all,
    array,
    with,
    select,
    lookup,
    lag,
    /// `x.hash()`: a `U64` of any value `==` compares but a float's
    /// (`notHashable`); `num` is the value's type, `elem` `U64`.
    hash,
    /// `a.order(?b)`: the `Order` of two values of a type that provides
    /// `Ord` and gives no `order` of its own (`Checker.orderCall`); `num`
    /// is their type, `elem` `Order`.
    order,
    /// `xs.sum()`, `xs.sum(start: n)`: the elements of a slice, an array,
    /// or a List of numbers added in order to `start`, `0` by default.
    sum,

    /// Whether the method is one of a single integer's bits (`bitCall`),
    /// not of the elements of a slice.
    pub fn isBits(op: ElemOp) bool {
        return switch (op) {
            .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .fraction, .exponent => true,
            .copy, .fill, .swap, .read, .write, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag, .hash, .order, .sum => false,
        };
    }

    /// Whether the call is a function of a number type or a plain enum:
    /// `Float.from_bits(u)`, `I32.wrap(x)`, `Status.from_int(n)`,
    /// `Status.from_text(word)`.
    pub fn isTypeFn(op: ElemOp) bool {
        return switch (op) {
            .from_bits, .wrap, .from_int, .from_text, .nan, .inf => true,
            else => false,
        };
    }

    /// Whether the method is a vector's (`simdCall`, `simdTypeCall`):
    /// it reads its receiver and arguments, and makes a new value.
    pub fn isSimd(op: ElemOp) bool {
        return switch (op) {
            .splat, .bits, .first, .any, .all, .array, .with, .select, .lookup, .lag => true,
            .copy, .fill, .swap, .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .hash, .order, .sum => false,
        };
    }
};

/// A call of a built-in String operation: `String(a, b, ...)`, which builds
/// one, and the methods `!t.add(a, b, ...)`, `!t.push(b)`, and
/// `!t.clear()`. `new` and `add` format their arguments as `print` does,
/// reading them; `push` appends one byte, `push[T, e](v)` (`push_int`)
/// the bytes of an integer, and `reserve(n)` makes room for `n` more.
/// `push_keep` is `push(v, keep: k)` of a vector of bytes, or
/// `push[T, e](w, keep: k)` of an integer: the first `k` bytes of `v`.
pub const StringCall = enum {
    new,
    add,
    push,
    push_int,
    push_keep,
    reserve,
    clear,
    /// `!out.value(x)` of a Printer, which writes `x` as `print` shows a
    /// part of another value (`Checker.printerValue`).
    printer_value,
    /// `!h.add(x)` of a Hasher, which mixes in the hash of `x`
    /// (`Checker.hasherAdd`).
    hasher_add,
};

/// What a bracket list `x[...]` that is not an index instantiates. The
/// parser builds `(index x a)` for one argument and `(inst x a b ...)`
/// for more; sema decides by what `x` names (a generic type or a
/// function with compile-time parameters instantiates, anything else
/// is indexed) and records the instances here.
pub const Instance = union(enum) {
    /// `List[Int]`, `Pair[Int, ?String]`: the generic type's instance.
    type: TypeId,
    /// `check[.strict]`, `p.scale[2]`: a function's compile-time
    /// arguments.
    function,
};

/// A compile-time function's call, `(ct_call cap 8)` (`cteval.markCalls`):
/// the value the checker computed, `SemContext.ct.results[result]`; null
/// in a compile-time function's body, where the evaluator runs the call.
pub const CtCall = struct { result: ?u32 };

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
    /// Bit `i`: type argument `i` binds a set parameter
    /// (`SymbolFlags.set_param`), which Zig takes as the set's error set.
    sets: u64 = 0,
    /// The function fails with a set parameter (`-> T!E`): its frame
    /// takes the slot, whatever set the call binds.
    fails_by_set: bool = false,
    /// The witnesses its type arguments give the bounds that name APIs of
    /// a program's own, each after the argument it follows.
    witnesses: []const ArgWitness = &.{},
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
    /// How many of its last arguments its name shows, where fewer than
    /// `own`: an addition's method shows its own, and its name the
    /// addition's, its type's (`List[Float].first`). Null for `own`.
    shown: ?u32 = null,

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
/// sentence 7; docs/internals/INTERNALS.md, "Call origins"): its result carries
/// the loans of the arguments that fill the parameters in `result`, and
/// it may store in what its write arguments lead to only the loans of
/// those in `stores`. Set on each function and method where it is
/// declared; a call reads it from its callee, never from a body.
pub const Origins = struct {
    result: ParamMask = all_params,
    stores: ParamMask = all_params,
    /// `result` is what a `from` clause names, not the signature's types.
    declared: bool = false,
    /// The lent parameters (`lentParam`), which `stores` holds only
    /// where the declaration's `keeps` names them; none for a function
    /// type's origins, which keep by type.
    lent: ParamMask = 0,
    /// The closure parameters the function calls at most once, written
    /// `f: once ?fun() -> T`: a closure literal passed to one may move
    /// what it captures out (`|<t| >t!`), as its own parameters.
    once: ParamMask = 0,
    /// The paths of self a method's `from` names (`from @text`), when it
    /// names paths rather than all of self; `result` keeps self's bit,
    /// so a reader of the mask alone sees all of self.
    self_paths: []const SelfPath = &.{},
};

/// The most fields a place's path names that the ownership checker tells
/// apart: a deeper place is cut there, which only adds conflicts. A path
/// of self a `from` names is no longer (`selfPathIn`), so the body is
/// checked against it exactly.
pub const max_path_fields = 8;

/// A path of self a method's `from` names (Core sentence 7, `from
/// @text`, `from @a.b`): its fields from self, and whether the last is
/// declared as a read view (`readViewField`). A call's result carries
/// the loans self holds and, unless `via_view`, a loan on the path.
pub const SelfPath = struct {
    fields: []const []const u8,
    via_view: bool,
};

/// Whether a field of type `ty` is declared as a read view: a `?T`, a
/// `[]T`, a `?String`, or an optional of one. What a result views
/// through it is what the view views, never a part of its holder.
pub fn readViewField(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .slice, .string_view => true,
        .optional => |inner| readViewField(ctx, inner),
        else => false,
    };
}

/// A function's `from` clause: the names it lists (empty for `from
/// static`), and the function's parameters.
pub const DeclaredOrigins = struct { names: Sexp, params: Sexp, returns: Sexp };

/// A function's `keeps` clause: the names it lists, and the function's
/// parameters.
pub const DeclaredKeeps = struct { names: Sexp, params: Sexp };

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
/// and its callee's `Origins` (docs/internals/INTERNALS.md, "Call origins").
pub const CallParams = struct {
    fills: []const ParamFill,
    origins: Origins,
    /// The names of the parameters the arguments may fill, the receiver
    /// left out, when known: what a diagnostic says a call keeps.
    names: ?[]const []const u8 = null,

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

    /// Whether the call keeps the argument at index `arg`, which fills a
    /// lent parameter its callee's `keeps` names.
    pub fn keepsLent(self: CallParams, arg: usize) bool {
        return self.filled(.{ .arg = @intCast(arg) }, self.origins.stores & self.origins.lent);
    }

    /// Whether the argument at index `arg` fills a parameter the callee
    /// calls at most once (`Origins.once`).
    pub fn fillsOnce(self: CallParams, arg: usize) bool {
        return self.filled(.{ .arg = @intCast(arg) }, self.origins.once);
    }

    /// Whether the call keeps its receiver, which its callee's `keeps`
    /// names (`keeps @`).
    pub fn keepsLentReceiver(self: CallParams) bool {
        return self.filled(.receiver, self.origins.stores & self.origins.lent);
    }

    /// The name of the parameter the argument at index `arg` fills, when
    /// known.
    pub fn paramName(self: CallParams, arg: usize) ?[]const u8 {
        const names = self.names orelse return null;
        var skip: usize = 0;
        for (self.fills, 0..) |f, i| {
            if (f == .receiver) {
                skip += 1;
                continue;
            }
            if (f == .arg and f.arg == arg) return if (i - skip < names.len) names[i - skip] else null;
        }
        return null;
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
                span = if (ctx.parser) |p| p.span(n) else rig.leafSpan(ctx.source, n);
                const kind = if (n == .src) "leaf" else if (n.kind()) |k| @tagName(k) else "group";
                const from = lines.at(span.start);
                const to = lines.at(span.end);
                try t.print("{s} {d}:{d}-{d}:{d} \"", .{ kind, from.line, from.col, to.line, to.col });
                for (diag.textBetween(ctx.source, span.start, @min(span.end, span.start + 40))) |c|
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
                const span = if (ctx.parser) |p| p.span(n) else rig.leafSpan(ctx.source, n);
                const from = lines.at(span.start);
                const to = lines.at(span.end);
                var text: std.Io.Writer.Allocating = .init(a);
                const t = &text.writer;
                const node_kind = if (n == .src) "leaf" else if (n.kind()) |k| @tagName(k) else "group";
                try t.print("{s} {s} {d}:{d}-{d}:{d} \"", .{ @tagName(kind), node_kind, from.line, from.col, to.line, to.col });
                for (diag.textBetween(ctx.source, span.start, @min(span.end, span.start + 40))) |c|
                    if (c == '\n') try t.writeAll("\\n") else try t.writeByte(c);
                try t.print("\" {s} {s}", .{ @tagName(s.by), @tagName(s.life) });
                try out.append(a, .{ .start = span.start, .end = span.end, .text = text.written() });
            }
        }
    }
    std.mem.sort(Line, out.items, {}, Line.lessThan);
    for (out.items) |l| try w.print("{s}\n", .{l.text});
}

/// A witness as `--facts=sema` shows it: `W_T_Shape` for a type
/// parameter's, `__rig_impl_Shape_Square` for a conformance's, with the
/// type it is for.
fn writeWitness(ctx: *const SemContext, a: std.mem.Allocator, w: *std.Io.Writer, wit: Witness) !void {
    switch (wit) {
        .param => |p| try w.writeAll(try witnessParamName(ctx, a, p.sym, p.api)),
        .conformance => |c| try w.print("{s}({s})", .{ try witnessName(ctx, a, c.module_id, c.index), try formatTypeIn(ctx, a, c.ty) }),
    }
}

/// `W_T_Shape`: the witness parameter type parameter `sym` takes for
/// `api`, one of its bounds. Two bounds by APIs of one name (`[T: Shape
/// + geo.Shape]`) are told apart by their place among the bounds,
/// `W_T_Shape_1`, so no two parameters share a name.
pub fn witnessParamName(ctx: *const SemContext, a: std.mem.Allocator, sym: SymbolId, api: ApiRef) std.mem.Allocator.Error![]const u8 {
    const p = ctx.symbols.items[sym];
    const name = (apiSymbol(ctx, api) orelse return "W_unknown").name;
    var at: ?usize = null;
    var shared = false;
    for (p.user_apis, 0..) |b, i| {
        if (b.eql(api)) {
            at = i;
        } else if (apiSymbol(ctx, b)) |other| {
            if (std.mem.eql(u8, other.name, name)) shared = true;
        }
    }
    if (shared) if (at) |i| return a.print("W_{s}_{s}_{d}", .{ p.name, name, i });
    return a.print("W_{s}_{s}", .{ p.name, name });
}

/// The name of the witness of conformance `index` of module
/// `module_id`, as its module declares it: `__rig_impl_Shape_Square`,
/// `__rig_impl_Shape_Int`, `__rig_impl_Shape_geo_Circle`. Two of one
/// module whose names would be the same (two APIs named `Shape`, or the
/// types `geo_Circle` and `geo.Circle`) are told apart by their place,
/// `__rig_impl_Shape_Square_1`.
pub fn witnessName(ctx: *const SemContext, a: std.mem.Allocator, module_id: u32, index: u32) std.mem.Allocator.Error![]const u8 {
    const home: *const SemContext = if (module_id == ctx.module_id) ctx else ctx.foreign_semas.get(module_id) orelse return "__rig_impl_unknown";
    const name = try witnessBaseName(home, a, index);
    for (home.conformances.items, 0..) |_, j| {
        if (j == index) continue;
        if (std.mem.eql(u8, try witnessBaseName(home, a, @intCast(j)), name)) return a.print("{s}_{d}", .{ name, index });
    }
    return name;
}

fn witnessBaseName(home: *const SemContext, a: std.mem.Allocator, index: u32) std.mem.Allocator.Error![]const u8 {
    const conf = home.conformances.items[index];
    const api = (apiSymbol(home, conf.api) orelse return "__rig_impl_unknown").name;
    var shown: []const u8 = switch (home.types.get(conf.ty)) {
        .nominal => |s| home.symbols.items[s].name,
        .parameterized_nominal => |pn| home.symbols.items[pn.sym].name,
        else => try formatTypeIn(home, a, conf.ty),
    };
    if (std.mem.indexOfScalar(u8, shown, '[')) |i| shown = shown[0..i];
    const out = try a.alloc(u8, shown.len);
    for (shown, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(c)) c else '_';
    return a.print("__rig_impl_{s}_{s}", .{ api, out });
}

fn writeFactValue(ctx: *const SemContext, a: std.mem.Allocator, w: *std.Io.Writer, comptime name: []const u8, v: anytype) !void {
    const V = @TypeOf(v);
    if (V == void) return;
    if (comptime std.mem.eql(u8, name, "names")) {
        const sym = ctx.symbols.items[v];
        return w.print(" {s} {s}", .{ sym.name, @tagName(sym.kind) });
    }
    if (comptime std.mem.eql(u8, name, "types") or std.mem.eql(u8, name, "payload_fields") or std.mem.eql(u8, name, "string_nums") or std.mem.eql(u8, name, "splats"))
        return w.print(" {s}", .{try formatTypeIn(ctx, a, v)});
    if (comptime std.mem.eql(u8, name, "scopes")) return w.print(" scope {d}", .{v});
    switch (V) {
        StringCall, Use, Upgrade, ParCall, SelectArm => try w.print(" {s}", .{@tagName(v)}),
        []const u8 => try w.print(" \"{f}\"", .{std.zig.fmtString(v)}),
        Lift => try w.print(" {s} from {s}", .{ try formatTypeIn(ctx, a, v.into), try formatTypeIn(ctx, a, v.from) }),
        HeaderFact => try w.print(" {s}", .{@tagName(v.how)}),
        LocalTask => try w.print(" \"{f}\"", .{std.zig.fmtString(v.why)}),
        ReadOnlyField => try w.print(" {s}.{s}.{s}", .{ v.module, v.owner, v.field }),
        JumpDest => {
            const at = diag.lineCol(ctx.source, ctx.startOf(v.target));
            try w.print(" {s} {s} {d}:{d}", .{ @tagName(v.to), @tagName(v.target.kind().?), at.line, at.col });
        },
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
        CtCall => if (v.result) |r| {
            try w.writeAll(" ");
            try cteval.writeValue(ctx, w, ctx.ct.results.items[r].value, ctx.ct.results.items[r].ty);
        } else try w.writeAll(" in a compile-time body"),
        GenericCall => {
            for (v.type_args) |ty| try w.print(" {s}", .{if (ty == type_invalid) "_" else try formatTypeIn(ctx, a, ty)});
            if (v.receiver_arg) try w.writeAll(" receiver");
            if (v.sets != 0) try w.print(" sets={b}", .{v.sets});
            if (v.fails_by_set) try w.writeAll(" fails_by_set");
            for (v.witnesses) |aw| {
                try w.writeAll(" witness ");
                try writeWitness(ctx, a, w, aw.witness);
            }
        },
        Dispatch => switch (v) {
            .direct => try w.writeAll(" direct"),
            .static => |s| {
                try w.writeAll(" static ");
                try writeWitness(ctx, a, w, s.witness);
                try w.print(" {s}.{s}", .{ try apiName(ctx, s.api), s.method });
            },
            .dynamic => |d| try w.print(" dynamic {s}.{s} slot {d}", .{ try apiName(ctx, d.api), d.method, d.slot }),
        },
        Erasure => {
            try w.print(" {s} {s} ", .{ try formatTypeIn(ctx, a, v.from), try formatTypeIn(ctx, a, v.view) });
            try writeWitness(ctx, a, w, v.witness);
            if (v.copy) try w.writeAll(" copy");
            if (v.optional) try w.writeAll(" optional");
            if (v.holding != .box) try w.print(" {s}", .{@tagName(v.holding)});
        },
        OwnerWitnesses => {
            if (v.receiver_arg) try w.writeAll(" receiver_arg");
            for (v.witnesses) |ow| {
                try w.writeAll(" witness ");
                try writeWitness(ctx, a, w, ow);
            }
        },
        // A field a pattern leaves out shows as `-`.
        []const Sexp => for (v) |b| try w.print(" {s}", .{identAt(ctx.source, b) orelse "-"}),
        []const SetMember => for (v) |m| try w.print(" {s}.{s}", .{ try formatTypeIn(ctx, a, m.set), m.name }),
        MemberCompares => {
            if (v.eq) try w.writeAll(" eq");
            if (v.hash) try w.writeAll(" hash");
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
    /// `x.hash()`: what `==` compares, less a float and what holds one
    /// (`notHashable`).
    hashable,
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
    /// Copies (`copies` is not `no`): the body copies the parameter's
    /// value.
    copies,
    /// Clones (`lacks` finds no `Clone`): the body makes a new owner of a
    /// value that holds the parameter, `+x`, part by part.
    clones,
    /// Needs no cleanup: the body discards the parameter's value, leaves
    /// a temporary of it, overwrites one, or keeps one in an array or a
    /// slice.
    no_cleanup,
    /// A compile-time integer from 0 to `max_array_len`: the body uses
    /// the value parameter as an array length.
    array_len,
    /// A power of two from 2 to 64: the body uses the value parameter as
    /// a vector's lane count (`Simd[T, n]`).
    lane_count,
    /// A count from 1 to `max_slot_count`: the body names `Slot[n]` with
    /// the value parameter, so every slot of the instance is below a
    /// count that has slots.
    slot_count,
    /// Holds no vector inline (`holdsVector`): the body takes the size or
    /// alignment of a type that holds the parameter by value.
    sized,
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
    /// An error set (`isErrorValue`): the signature writes the parameter
    /// after `!`, as the set a function fails with (errors-spec §3.5).
    error_set,
    /// Not a function type: the declaration makes a shared or weak handle
    /// of the parameter (`*T`, `~T`), and `*fun(...)` is an owned
    /// closure, not a handle of a function.
    not_function,
    /// Holds no view but a `?String` (`nameable`): the body names a type
    /// that holds the parameter (`$name`), which the runtime spells from
    /// the instance's Zig type.
    named,
    /// Printable (`printable`): the body prints a value that holds the
    /// parameter, and a `[]U8` would print as text.
    printable,
    /// Holds only data that never changes (`frozenBlocker`): the body
    /// freezes a value that holds the parameter, `*Frozen(x)`.
    frozen,
    /// Holds no task or set of tasks (`holdsTask`): the body hides a value
    /// that holds the parameter from the rules that wait for a task,
    /// erasing it to an API object, giving it out of `task.isolate`, or
    /// capturing it in an owned closure (`Checker.hidesNoTask`).
    no_task,
    /// Goes to a task as this says (`taskBlocker`): the body gives a task
    /// a value that holds the parameter, or lends it one (`taskParams`).
    task: TaskReach,
    /// Meets this built-in API (`lacks`): the body erases a value that
    /// holds the parameter to an API object whose braces or API name it
    /// (`Owned`, `Print`, `Clone`, or another its API builds on), which
    /// the parameter's bounds do not decide.
    meets: Api,

    pub fn describe(self: Requirement) []const u8 {
        return switch (self) {
            .numeric => "arithmetic",
            .ordered => "ordering comparison",
            .equatable => "`==` / `!=`",
            .hashable => "`.hash()`",
            .integer => "integer operators",
            .signed => "negation",
            .float => "a float literal",
            .fits => "an integer literal",
            .shift => "a constant shift",
            .copies => "a value that copies",
            .clones => "a value that clones",
            .no_cleanup => "a value that owns no resource",
            .array_len => "an array length",
            .lane_count => "a lane count",
            .slot_count => "a slot count",
            .sized => "a size or alignment",
            .bytes => "an integer or float in bytes",
            .whole_division => "a division of whole numbers",
            .not_error => "a fallible return",
            .error_set => "an error set",
            .not_function => "a handle",
            .named => "a type name",
            .printable => "printing",
            .frozen => "a frozen value",
            .no_task => "a value that holds no task",
            .task => "a value that goes to a task",
            .meets => "a value that meets an API object's bound",
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
    /// The method whose body makes it, by its declaration's position in
    /// module `module_id`, when the requirement is on a parameter of the
    /// method's type (or an API default's `Self`), at `index` among them:
    /// checked where the program reaches the method (`BodyReach`), not at
    /// every instance of the type. `no_body` for any other.
    body: u32 = no_body,
    index: u32 = 0,
};

/// `GenericRequirement.body` of a requirement checked at every instance
/// of its parameter.
pub const no_body: u32 = std.math.maxInt(u32);

/// A method of a generic type, an addition's, or an API's default, as
/// the program reaches it at its type's arguments (`args`, for
/// `params`): by a call, through an API's witness, or by erasing a value
/// to an API object, whose table holds every method of the API. Zig
/// compiles a method only where it is reached, so a requirement its body
/// makes on its type's parameters is checked here
/// (`GenericRequirement.body`). One over a body's parameters is in
/// `generic_reaches`, which each instance of the body (`in`, a method;
/// null for a function) makes concrete. With `erase`, it stands for
/// every method `recv` gives `erase`, reached when `recv` is known.
pub const BodyReach = struct {
    fun: FnRef,
    in: ?FnRef = null,
    params: []const SymbolId,
    args: []const TypeId,
    /// The type the method is reached on, and its name, for messages.
    recv: TypeId,
    method: []const u8,
    site: u32,
    via: ?InstanceRoot = null,
    erase: ?ApiRef = null,
};

/// A call `x.m(args)` a generic body makes on a value of a type
/// parameter, or a view of one (`?T`, `!T`), checked at each instance
/// (`typecheck.checkMethodCalls`): the instance's type declares a method
/// `m`, visible from the body's module, that takes self as the call's
/// sigil does, takes the arguments as the body passes them, and gives
/// the result the body takes.
pub const GenericMethodCall = struct {
    param: SymbolId,
    method: []const u8,
    /// How the call takes self: `x.m()` reads, `!x.m()` writes, and
    /// `<x.m()` consumes.
    self_mode: MethodReceiver,
    /// The arguments' types in the body, in order.
    args: []const TypeId,
    result: Result,
    pos: u32,
    /// The value the call is made on and the call, as written: `x`,
    /// `x.bump()`.
    recv: []const u8,
    call: []const u8,
    /// The module whose source `pos` is in: 0 for this one, or the
    /// module that declares the body of a proxy's call.
    module_id: u32 = 0,
    /// The call is made on a `T` the body holds by value, whose loans
    /// the body does not track, rather than through a view of one.
    owned_recv: bool = false,

    pub const Result = union(enum) {
        /// The type the body takes the result as.
        ty: TypeId,
        /// A statement: the method gives nothing.
        nothing,
        /// `_ = x.m()`: any result that cannot fail, dropped there.
        dropped,
    };
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

/// The first type `ty` holds, at any depth, that `$name` of a type
/// parameter cannot spell, or null: a view but `?String`. The runtime
/// names an instance from its Zig type (`rig.typeName`), where a read
/// view of a number is the number, and a `[]U8` and a `?String` are one
/// type. (A `Static` an instance binds reads as a `?String`, and is
/// named one.)
pub fn unnameable(ctx: *const SemContext, ty: TypeId) ?TypeId {
    switch (ctx.types.get(ty)) {
        .read_view, .write_view, .slice, .callable => return ty,
        else => {},
    }
    var it = typeChildren(ctx, ty);
    while (it.next()) |c| if (unnameable(ctx, c)) |u| return u;
    return null;
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
    /// The value is one an `as` binds where it stands, inside an optional
    /// a read view reaches, taken out rather than copied.
    as_view: bool = false,
    /// Not a copy: the value is stored where no loan is tracked (a Cell,
    /// a Signal, an owned closure), so each instance's argument must
    /// hold no `?String`, which may view a String.
    view: bool = false,
    /// Not a copy: the body holds a value of `param`'s associated type of
    /// this name (`S.Item`) past a write, move, or drop of the `S` it came
    /// from, which views it in an instance whose associated type may view
    /// memory its base owns (`SemContext.item_views`), and only there.
    item: []const u8 = "",
    /// The module whose source `pos` is in; 0 for this one.
    module_id: u32 = 0,
};

/// An associated type (`I.Item`, an `AssocOf` symbol) at an instance
/// whose base is `base` (`I = Buf`).
pub const ItemView = struct { assoc: SymbolId, base: TypeId };

/// The lists of what generic bodies do over their type parameters, which
/// each instance makes concrete: `generic_fn_uses`, `generic_uses`,
/// `generic_arrays`, `generic_frames`, `generic_api_calls`. Each entry is
/// added through `SemContext.addGeneric`, which indexes it.
pub const GenericList = enum(u8) { fn_uses, uses, arrays, frames, api_calls, reaches };

/// A call through an API of a program's own (`t.look(?k)` on a bounded
/// `T`, `c.look(?k)` on a type that provides the API, `Keyed.look(?c,
/// ?k)`), as the instance it reaches is checked: that instance is the
/// implementation's method (`implInstance`), which the witness names,
/// and its body is checked at the type that provides the API and at the
/// method's own compile-time arguments, as a call of the method itself
/// is. One whose types are known is in `SemContext.api_calls`; one over
/// a body's parameters in `generic_api_calls`, which each instance of
/// the body makes concrete (`expandInstantiations`).
pub const ApiCall = struct {
    /// The type that provides the API: a type parameter it bounds, or a
    /// type that provides it, which may name a body's parameters.
    recv: TypeId,
    api: ApiRef,
    method: []const u8,
    /// The method's own type and integer arguments, in order, as the API
    /// declares its parameters, which every implementation has exactly.
    args: []const TypeId,
    /// The compile-time slot each of `args` fills (`ownParamOf`), as the
    /// call's instance of the API's method binds them
    /// (`typecheck.instantiateCall`): recorded once, here, and read by
    /// `implInstance` at the implementation's same slots.
    slots: []const u32,
    /// Where the call is, in module `module_id` (0 for this one).
    pos: u32,
    module_id: u32 = 0,

    /// The same call: its position aside, what it reaches is the same.
    const Context = struct {
        pub fn hash(_: Context, k: ApiCall) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&k.recv));
            h.update(std.mem.asBytes(&k.api.module_id));
            h.update(std.mem.asBytes(&k.api.sym));
            h.update(k.method);
            h.update(std.mem.sliceAsBytes(k.args));
            return h.final();
        }
        pub fn eql(_: Context, a: ApiCall, b: ApiCall) bool {
            return a.recv == b.recv and a.api.eql(b.api) and std.mem.eql(u8, a.method, b.method) and
                std.mem.eql(TypeId, a.args, b.args) and std.mem.eql(u32, a.slots, b.slots);
        }
    };
};

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
    /// Where among `diagnostics` a form holding an API object was
    /// reported as not built yet (`objectUnbuiltError`); a report a quiet
    /// check took back no longer counts (`objectRejected`).
    object_unbuilt_at: ?usize = null,
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
    /// Optional fields and elements that `<` could not take out, since
    /// the path to them allows no write (`recordUntakeable`). Only a
    /// diagnostic's hint reads it, so it is no fact.
    untakeable: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    facts: Facts = .{},

    cell_sym_id: SymbolId = symbol_invalid,
    list_sym_id: SymbolId = symbol_invalid,
    signal_sym_id: SymbolId = symbol_invalid,
    /// `Actor[T]`: a value one task at a time changes, behind `*`.
    actor_sym_id: SymbolId = symbol_invalid,
    chan_sym_id: SymbolId = symbol_invalid,
    frozen_sym_id: SymbolId = symbol_invalid,
    task_sym_id: SymbolId = symbol_invalid,
    tasks_sym_id: SymbolId = symbol_invalid,
    /// The module makes a task (`f(x)&`): the program's root declares
    /// `__rig_tasks`, which runs it on the scheduler.
    makes_tasks: bool = false,
    /// The module makes an actor (`*Actor(x)`): the program's root
    /// declares `__rig_actors`, so its waits are watched for deadlocks.
    makes_actors: bool = false,
    /// The module names `time.since_start`: the program's root declares
    /// `__rig_since_start`, so the runtime reads the clock as it starts
    /// (`noteRuntimeRead`).
    reads_since_start: bool = false,
    /// The module names `os.memory`: the program's root declares
    /// `__rig_memory`, so its allocator counts what it hands out.
    reads_memory: bool = false,
    simd_sym_id: SymbolId = symbol_invalid,
    /// `Table[T, n]` and `Slot[n]`: a table of `n` slots, and a number
    /// that names one (`Type.slot`).
    table_sym_id: SymbolId = symbol_invalid,
    slot_sym_id: SymbolId = symbol_invalid,
    box_sym_id: SymbolId = symbol_invalid,
    endian_sym_id: SymbolId = symbol_invalid,
    order_sym_id: SymbolId = symbol_invalid,
    printer_sym_id: SymbolId = symbol_invalid,
    hasher_sym_id: SymbolId = symbol_invalid,
    arch_sym_id: SymbolId = symbol_invalid,

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
    /// A directory module: where each of its files starts in `source`.
    /// Empty for a module of one file.
    parts: []const diag.Part = &.{},
    /// The module constants in the order their values are checked: each
    /// after the constants it names (`resolve.orderModuleConsts`).
    const_order: std.ArrayList(Sexp) = .empty,
    /// Each `use` by the file it is in: the module symbol it binds, and
    /// the declaration (`fileModule`).
    file_uses: std.ArrayList(FileUse) = .empty,
    /// Every module of the program by id, shared by their contexts: a
    /// type from another module names its origin by id.
    foreign_semas: *const ModuleMap = &no_modules,
    /// The ids of the modules this one reaches through its imports.
    reach: std.bit_set.Dynamic = .{},
    /// How this module's types, and the types it adds its APIs to,
    /// provide APIs of a program's own (`Conformance`, `provides`).
    conformances: std.ArrayList(Conformance) = .empty,
    /// Each instance of a generic type bounded by an API of a program's
    /// own -> the witnesses among its arguments (`recordTypeWitnesses`).
    type_witnesses: std.AutoHashMapUnmanaged(TypeId, []const ArgWitness) = .empty,
    /// Where the name of each method declared under bounds on its type's
    /// parameters is -> those bounds, as resolve reads them, for the
    /// method's `Field` (`Field.owner_bounds`).
    owner_bounds: std.AutoHashMapUnmanaged(u32, []const OwnerBound) = .empty,
    /// Each type parameter of a `pub` declaration of this module
    /// (`SymbolFlags.states_bounds`) -> the declaration as written, `pub
    /// fun sum[T]`, as the error that it states its bounds names it.
    stated: std.AutoHashMapUnmanaged(SymbolId, []const u8) = .empty,
    /// Each API this module declares -> its table's entries, the methods
    /// a call through an object of it reaches (`TableEntry`), from which
    /// emit writes `__rig_table_Shape` (`typecheck.checkApiDecl`).
    object_tables: std.AutoHashMapUnmanaged(SymbolId, []const TableEntry) = .empty,
    /// Each generic type named in a signature with a type parameter of
    /// the declaration as its argument `index`: the parameter has the
    /// built-in bounds of the one it fills (`resolve.TypeResolver.implyBounds`).
    implications: std.ArrayList(struct { param: SymbolId, generic: SymbolId, index: u32 }) = .empty,
    /// The type parameters that carry the bounds of the method being
    /// checked as well as their own (`widenOwnerBounds`).
    widened: []const SymbolId = &.{},
    /// Each bound on an associated type (`[S: Source, S.Item: Ord]`), by
    /// the parameter it is written on, for resolve to give the
    /// associated type once the APIs are known (`resolveAssocBounds`).
    assoc_bound_decls: std.ArrayList(struct { param: SymbolId, node: Sexp }) = .empty,

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
    /// For each entry of `generic_uses`, the method whose body spells it
    /// (`addUse`): an instance of the method's type makes it only where
    /// the program reaches the method (`BodyReach`). Null for one spelled
    /// anywhere else, which every instance makes.
    generic_uses_in: std.ArrayList(?FnRef) = .empty,
    /// For each entry of `generic_uses`, where it is first spelled or
    /// made (0 for one another module's body makes).
    generic_uses_at: std.ArrayList(u32) = .empty,
    /// The instances of generic functions the module's calls make, each
    /// with the position of its first call, in the order found.
    fn_instances: std.ArrayList(struct {
        inst: FnInstance,
        site: u32,
        via: ?InstanceRoot = null,
        /// The implementation's method a call through an API reaches
        /// (`implInstance`): the call's instance of the API's method
        /// checks the bounds and the arguments it is given.
        through_api: bool = false,
    }) = .empty,
    /// Every instance in `fn_instances` and `generic_fn_uses`.
    fn_instance_set: std.HashMapUnmanaged(FnInstance, void, FnInstance.Context, std.hash_map.default_max_load_percentage) = .empty,
    /// Instances of generic functions called with type parameters, inside
    /// generic bodies (`max[T]` in `fun top[T]`); expanded like
    /// `generic_uses`.
    generic_fn_uses: std.ArrayList(FnInstance) = .empty,
    /// For each entry of `generic_fn_uses`, the method whose body makes
    /// it, as `generic_uses_in` is for `generic_uses`.
    generic_fn_uses_in: std.ArrayList(?FnRef) = .empty,
    /// Integer constants: bindings never reassigned or written whose
    /// value is a constant expression. The emitted Zig computes these at
    /// compile time, so sema checks their arithmetic. Module constants
    /// are folded once, in declaration order, before any type is
    /// resolved (`resolve.foldModuleConsts`), so a type anywhere in the
    /// module can name them.
    const_ints: std.AutoHashMapUnmanaged(SymbolId, ConstVal) = .empty,
    /// The bindings a use may move, drop, or give away (`consumes`,
    /// recorded by `storage.plan`): emit arms such a binding's drop
    /// behind an alive flag, and the ownership checker moves no other.
    consumed: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// The fields a use may move out of a binding (`fieldMoves`,
    /// recorded by `storage.plan` with `consumed`, under its contract):
    /// each a path of field names below the binding, `a.b` for `<p.a.b`.
    /// Emit gives each a drop flag, and the ownership checker moves no
    /// other field out (Core §5, "A field of an owned object moves like
    /// a name").
    field_moves: std.AutoHashMapUnmanaged(SymbolId, std.ArrayList([]const u8)) = .empty,
    /// The several results a `destructure` takes, or a `return a, b`
    /// makes into storage one by one (`storage.hoistsResults`): how each
    /// part is held (`resourceKind` of its type), recorded by the storage
    /// plan (`partDrops`).
    part_drops: std.AutoHashMapUnmanaged(u64, []const ?ResourceKind) = .empty,
    /// The captures of a closure called exactly once that it owns
    /// (`|<x|`, `|+x|`, `|~x|`; `recordOnceClosure`): its one call takes
    /// them, as a function takes a parameter given by value, so its body
    /// may move them out, and drops what it leaves.
    once_captures: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// The array types spelled or built in generic declarations, which
    /// each instance checks against `max_value_bytes`; `module_id` is
    /// the module whose source `pos` is in (0 for this one).
    generic_arrays: std.ArrayList(struct { ty: TypeId, pos: u32, module_id: u32 = 0 }) = .empty,
    /// The stack values of the generic functions and closures, and of the
    /// generic types' methods, whose sizes depend on their parameters:
    /// each instance checks them against `max_frame_bytes`.
    generic_frames: std.ArrayList(Frame) = .empty,
    /// The calls through an API of a program's own made in generic
    /// bodies, over their parameters (`ApiCall`).
    generic_api_calls: std.ArrayList(ApiCall) = .empty,
    /// The calls through an API of a program's own whose types are known.
    api_calls: std.ArrayList(ApiCall) = .empty,
    /// The methods the program reaches, every type known (`BodyReach`),
    /// each once (`reach_set`), and those reached over a generic body's
    /// parameters.
    body_reaches: std.ArrayList(BodyReach) = .empty,
    /// The calls of generic functions a generic body makes at its own
    /// parameters (`spawn(?x)` in `outer[U]`): each callee parameter's
    /// argument, where, and the method of a generic type whose body makes
    /// it (`GenericRequirement.body`). Read to find what a parameter
    /// stated by its bounds must state of what the callees do
    /// (`typecheck.checkStatedForwards`).
    param_calls: std.ArrayList(struct { params: []const SymbolId, args: []const TypeId, pos: u32, body: u32 }) = .empty,
    reach_set: std.StringHashMapUnmanaged(void) = .empty,
    generic_reaches: std.ArrayList(BodyReach) = .empty,
    /// The values erased to API objects, every type known (`BodyReach.erase`).
    erase_reaches: std.ArrayList(BodyReach) = .empty,
    /// Every call in `api_calls` and `generic_api_calls`, each recorded
    /// once (`recordApiCall`).
    api_call_set: std.HashMapUnmanaged(ApiCall, void, ApiCall.Context, std.hash_map.default_max_load_percentage) = .empty,
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
    /// `valueDepth` of each type measured so far.
    value_depths: std.AutoHashMapUnmanaged(TypeId, u32) = .empty,
    /// A local `k =! n` binding of a compile-time integer parameter ->
    /// the `ct_param` it stands for, where an array length or a
    /// compile-time argument names it.
    ct_locals: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// An object that names its none (`none id == 0`) -> its none
    /// (`TypeResolver.resolveNominal`).
    named_nones: std.AutoHashMapUnmanaged(SymbolId, NamedNone) = .empty,
    /// Another module's generic type or compile-time parameter (where it
    /// is declared) -> its proxy here (`proxyOf`).
    imported: std.AutoHashMapUnmanaged(ForeignRef, SymbolId) = .empty,
    /// How many imports `importSymbol` is nested in, and the proxies made
    /// past its limit, which the outermost fills in.
    import_depth: u32 = 0,
    import_pending: std.ArrayList(PendingProxy) = .empty,
    /// The entries of other modules' lists copied here (`importParam`).
    imported_entries: std.AutoHashMapUnmanaged(ImportedEntry, void) = .empty,
    /// The copies of type parameters' values generic bodies make, which
    /// the ownership checker finds: this module's own, recorded after it
    /// is checked, and those of the proxies' bodies, imported with them.
    plain_reqs: std.ArrayList(PlainRequirement) = .empty,
    /// The instances whose associated type may view memory its base owns
    /// (`assocViewsBase`): by the associated type and what its base is
    /// there, what the instance gives the associated type. The ownership
    /// checker rejects such an instance of a body that holds a value of
    /// it past a change of its base (`PlainRequirement.item`).
    item_views: std.AutoHashMapUnmanaged(ItemView, TypeId) = .empty,
    /// The method calls generic bodies make on type parameters.
    generic_methods: std.ArrayList(GenericMethodCall) = .empty,
    /// The hidden storage emit makes (`Storage`), but for the kinds the
    /// facts table keeps (`temp` is `temp_drops`, `header_copy` is
    /// `header_copies`): recorded after the expressions are checked
    /// (`storage.plan`).
    storage: std.AutoHashMapUnmanaged(StorageKey, Storage) = .empty,
    /// The values expression statements discard (`discardsValue`).
    discards: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The functions and methods Zig inlines at every call, by where
    /// their names are declared (`inlining.decide`).
    inlined: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The functions and methods whose entry checks for work left
    /// waiting, by where their names are declared: a set every cycle of
    /// calls passes through (`inlining.decide`).
    entry_checks: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// This module's functions and methods declared `inline fun`, by
    /// where their names are declared: their declarations (`resolve`).
    inline_decls: std.AutoHashMapUnmanaged(u32, Sexp) = .empty,
    /// What each of them lands in the frame of a call of it: its own
    /// values and those of the `inline` functions it calls, in this
    /// module's types, over its own and its type's parameters; null while
    /// it is being worked out (`typecheck.inlineFrame`).
    inline_frames: std.AutoHashMapUnmanaged(u32, ?[]const FrameSlot) = .empty,
    /// How deep the calls of marked `inline` functions nest below each of
    /// them, which `typecheck.max_inline_depth` limits.
    inline_heights: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// A call (`decisionKey`) of a marked `inline` function -> the
    /// function and the instance it makes (`InlineCall`).
    inline_calls: std.AutoHashMapUnmanaged(u64, InlineCall) = .empty,
    /// The frames `checkFrames` counted, each of its owner or, for a
    /// generic one, of one instance of it.
    frame_sizes: std.ArrayList(FrameSize) = .empty,
    /// The frame owners, in the order the walk met them
    /// (`typecheck.recordFrameOwners`): the one list every frame count,
    /// `inlining.decide`, and `rig check --facts=frames` read.
    frame_owners: std.ArrayList(FrameOwner) = .empty,
    /// Every call, in the order the walk met them, with its owner.
    frame_calls: std.ArrayList(FrameCall) = .empty,
    /// A call (`decisionKey`) -> its index in `frame_calls` (`ownerOf`).
    call_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// A call (`decisionKey`) -> what it reaches (`callTargetOf`).
    call_targets: std.AutoHashMapUnmanaged(u64, CallTarget) = .empty,
    /// The functions, by where their names are declared, whose code may
    /// take `noinline_reach` of stack or more, and the most it may take:
    /// emitted `noinline`, never inlined, and sizing the program's task
    /// guard (`taskGuard`; `typecheck.checkFrames`, `inlining.decide`).
    large_frames: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Those of other modules, found large at an instance made here;
    /// `inlining.decide` marks them in their own modules.
    large_foreign_frames: std.ArrayList(ForeignFrame) = .empty,
    /// The plain enums of this module, by symbol, that the program calls
    /// `from_text` on (`recordTextTable`).
    text_tables: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Those of other modules, called here.
    foreign_text_tables: std.ArrayList(ForeignRef) = .empty,
    /// The calls that may reach one of them, by node (`inlining.decide`).
    inlined_calls: std.AutoHashMapUnmanaged(NodeKey, void) = .empty,
    /// The node `Question`s decided so far, each once.
    decided: *Decided,
    /// Facts of types worked out on their first ask (`TypeMemo`).
    type_memo: *TypeMemo,
    /// The `from` clause of each function and method that writes one
    /// (`-> T from a, b`), by where its name is declared, with its
    /// parameters (`computeOrigins`).
    declared_origins: std.AutoHashMapUnmanaged(u32, DeclaredOrigins) = .empty,
    /// The `keeps` clause of each function and method that writes one
    /// (`keeps s, @`), by where its name is declared, with its
    /// parameters (`computeOrigins`).
    declared_keeps: std.AutoHashMapUnmanaged(u32, DeclaredKeeps) = .empty,
    /// The parameters each function and method calls at most once, those
    /// written `f: once ?fun() -> T`, by where its name is declared.
    declared_once: std.AutoHashMapUnmanaged(u32, ParamMask) = .empty,
    /// The `for` loops over an iterator that typecheck found, each to be
    /// rewritten into the `while` it means (`rig.IterLoop`). A module with
    /// any is checked again on the rewritten tree, so no pass sees one.
    iter_loops: std.ArrayList(rig.IterLoop) = .empty,
    /// The string literals typecheck found where a `U8` or a `[N]U8` goes,
    /// each to be written as the byte or the array of bytes it is there
    /// (`rig.ByteLiteral`); a module with any is checked again on the
    /// rewritten tree, as for `iter_loops`.
    byte_literals: std.ArrayList(rig.ByteLiteral) = .empty,
    /// Every node that writes a binding, and how (`recordWrite`). Kept
    /// beside the facts table, not in `check --facts=sema`.
    write_sites: std.AutoHashMapUnmanaged(NodeKey, WriteSite) = .empty,
    /// The tests each node is known to pass (`Proven`), written only by
    /// `src/proofs.zig` once the ownership checker accepted the module.
    /// Printed by `check --facts=proofs`, not `--facts=sema`.
    proven: std.AutoHashMapUnmanaged(NodeKey, Proven) = .empty,
    /// The tests each node is known to pass while a flag holds
    /// (`ProvenIf`), and each flag's tests, by the statement it is made
    /// before (`FlagTest`): written only by `src/proofs.zig`, with the
    /// tests above, and allocated in `arena`.
    proven_if: std.AutoHashMapUnmanaged(NodeKey, ProvenIf) = .empty,
    flags: std.AutoHashMapUnmanaged(NodeKey, []const FlagTest) = .empty,
    /// What each function of the module bounds of its result
    /// (`ResultBound`), by where its name is declared: written only by
    /// `src/proofs.zig`, with the tests above.
    result_bounds: std.AutoHashMapUnmanaged(u32, ResultBound) = .empty,
    /// Each node of a body -> the root of the innermost unit holding it
    /// (`rig.eachUnit`), recorded by the storage plan (`storage.plan`).
    /// Kept beside the facts table, not in `check --facts=sema`.
    unit_of: std.AutoHashMapUnmanaged(NodeKey, NodeKey) = .empty,
    /// The root of each unit -> its kind.
    unit_roots: std.AutoHashMapUnmanaged(NodeKey, rig.UnitKind) = .empty,
    /// The members of each declaration with many fields, by name and
    /// kind, keyed by where its fields are (`indexMembers`), so that
    /// finding one walks no others. Lives in the arena.
    member_index: std.AutoHashMapUnmanaged(usize, MemberIndex) = .empty,
    /// The module's compile-time functions, what their calls computed, and
    /// the hidden constants emit writes for the arrays among them
    /// (`cteval.State`).
    ct: cteval.State = .{},

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !SemContext {
        var ctx: SemContext = .{
            .allocator = allocator,
            .source = source,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try TypeStore.init(allocator),
            .decided = try allocator.create(Decided),
            .type_memo = undefined,
        };
        ctx.decided.* = .{};
        errdefer allocator.destroy(ctx.decided);
        ctx.type_memo = try allocator.create(TypeMemo);
        ctx.type_memo.* = .{};
        errdefer allocator.destroy(ctx.type_memo);
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
        self.conformances.deinit(self.allocator);
        self.type_witnesses.deinit(self.allocator);
        self.owner_bounds.deinit(self.allocator);
        self.stated.deinit(self.allocator);
        self.object_tables.deinit(self.allocator);
        self.implications.deinit(self.allocator);
        self.assoc_bound_decls.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.reported.deinit(self.allocator);
        self.untakeable.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.declared_origins.deinit(self.allocator);
        self.declared_keeps.deinit(self.allocator);
        self.declared_once.deinit(self.allocator);
        self.iter_loops.deinit(self.allocator);
        self.byte_literals.deinit(self.allocator);
        self.module_refs.deinit(self.allocator);
        self.file_uses.deinit(self.allocator);
        self.const_order.deinit(self.allocator);
        self.reach.deinit(self.allocator);
        self.alias_targets.deinit(self.allocator);
        self.alias_in_progress.deinit(self.allocator);
        self.generic_requirements.deinit(self.allocator);
        self.instantiation_sites.deinit(self.allocator);
        self.generic_uses.deinit(self.allocator);
        self.generic_uses_in.deinit(self.allocator);
        self.generic_uses_at.deinit(self.allocator);
        self.generic_fn_uses_in.deinit(self.allocator);
        self.fn_instances.deinit(self.allocator);
        self.fn_instance_set.deinit(self.allocator);
        self.generic_fn_uses.deinit(self.allocator);
        self.const_ints.deinit(self.allocator);
        self.consumed.deinit(self.allocator);
        var fm = self.field_moves.valueIterator();
        while (fm.next()) |paths| {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        self.field_moves.deinit(self.allocator);
        self.part_drops.deinit(self.allocator);
        self.ct_locals.deinit(self.allocator);
        self.named_nones.deinit(self.allocator);
        self.generic_arrays.deinit(self.allocator);
        self.generic_frames.deinit(self.allocator);
        self.generic_api_calls.deinit(self.allocator);
        self.api_calls.deinit(self.allocator);
        self.api_call_set.deinit(self.allocator);
        self.body_reaches.deinit(self.allocator);
        self.param_calls.deinit(self.allocator);
        self.reach_set.deinit(self.allocator);
        self.generic_reaches.deinit(self.allocator);
        self.erase_reaches.deinit(self.allocator);
        var index = self.generic_index.valueIterator();
        while (index.next()) |at| at.deinit(self.allocator);
        self.generic_index.deinit(self.allocator);
        self.oversized.deinit(self.allocator);
        self.byte_sizes.deinit(self.allocator);
        self.value_depths.deinit(self.allocator);
        self.imported.deinit(self.allocator);
        self.import_pending.deinit(self.allocator);
        self.imported_entries.deinit(self.allocator);
        self.plain_reqs.deinit(self.allocator);
        self.item_views.deinit(self.allocator);
        self.generic_methods.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        self.discards.deinit(self.allocator);
        self.inlined.deinit(self.allocator);
        self.entry_checks.deinit(self.allocator);
        self.frame_sizes.deinit(self.allocator);
        self.inline_decls.deinit(self.allocator);
        self.inline_frames.deinit(self.allocator);
        self.inline_heights.deinit(self.allocator);
        self.inline_calls.deinit(self.allocator);
        self.frame_owners.deinit(self.allocator);
        self.frame_calls.deinit(self.allocator);
        self.call_index.deinit(self.allocator);
        self.call_targets.deinit(self.allocator);
        self.large_frames.deinit(self.allocator);
        self.large_foreign_frames.deinit(self.allocator);
        self.text_tables.deinit(self.allocator);
        self.foreign_text_tables.deinit(self.allocator);
        self.inlined_calls.deinit(self.allocator);
        self.write_sites.deinit(self.allocator);
        self.proven.deinit(self.allocator);
        self.proven_if.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.result_bounds.deinit(self.allocator);
        self.unit_of.deinit(self.allocator);
        self.unit_roots.deinit(self.allocator);
        self.ct.deinit(self.allocator);
        self.decided.map.deinit(self.allocator);
        self.allocator.destroy(self.decided);
        self.type_memo.drop_body.deinit(self.allocator);
        self.type_memo.printable.deinit(self.allocator);
        self.allocator.destroy(self.type_memo);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const SemContext) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    /// The source range of an IR node: its span from the parser, which
    /// includes keywords and sigils (`return x`, `<p`).
    pub fn span(self: *const SemContext, node: Sexp) diag.Span {
        if (self.parser) |p| return p.span(node);
        return rig.leafSpan(self.source, node);
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

    /// The declaration named `name` this module makes, as another module
    /// reaches it (`lib.name`), public or not: never a built-in, which
    /// every module sees and none declares (`lib.List` names no `List`).
    pub fn moduleMember(self: *const SemContext, name: []const u8) ?SymbolId {
        const id = self.lookupInScopeOnly(module_scope, name) orelse return null;
        return if (self.symbols.items[id].decl_pos == builtin_decl_pos) null else id;
    }

    /// The module a `use` in the file `pos` is in binds as `name`
    /// (`file_uses`). A `use` binds its name in its own file only, so its
    /// module symbol is in no scope: a lookup that reaches the module's
    /// scope asks here first.
    pub fn fileModule(self: *const SemContext, name: []const u8, pos: u32) ?SymbolId {
        const file = fileIndex(self.parts, pos);
        for (self.file_uses.items) |u| {
            if (u.file == file and std.mem.eql(u8, self.symbols.items[u.sym].name, name)) return u.sym;
        }
        return null;
    }

    /// The end of a diagnostic for `name`, unbound where it is used: in a
    /// directory module, the `use` another file binds it with, which this
    /// file lacks. Empty when no file binds it.
    pub fn otherFileUse(self: *SemContext, name: []const u8) std.mem.Allocator.Error![]const u8 {
        for (self.file_uses.items) |u| {
            if (!std.mem.eql(u8, self.symbols.items[u.sym].name, name)) continue;
            const p = self.parser orelse return "";
            return self.arena.allocator().print("; `{s}` is imported by another file of module `{s}`; add `{s}` to this file", .{ name, self.name, diag.textOf(self.source, p.span(u.decl)) });
        }
        return "";
    }

    /// `lookup` for a name written at `pos`: a module a `use` of its file
    /// binds is visible there.
    pub fn lookupAt(self: *const SemContext, from_scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
        var sid: ?ScopeId = from_scope;
        while (sid) |s| {
            if (s == scope_invalid or s >= self.scopes.items.len) break;
            if (s == module_scope) if (self.fileModule(name, pos)) |id| return id;
            if (self.lookupInScopeOnly(s, name)) |id| return id;
            sid = self.scopes.items[s].parent;
        }
        return null;
    }

    /// The symbol `name` resolves to from `from_scope`: the latest
    /// declaration in the innermost enclosing scope that has one. A
    /// module a `use` binds is named only at a position (`lookupAt`).
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
            if (s == module_scope) if (self.fileModule(name, pos)) |id| return id;
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

    /// Whether a write may go through binding `sym`, or null for one that
    /// is no view (it owns or copies its value): the access typecheck
    /// recorded (`Symbol.access`), or, for a parameter or local, the one
    /// its type declares. The one fact of a binding's mode
    /// (docs/internals/INTERNALS.md, "Binding access").
    pub fn bindingAccess(self: *const SemContext, sym: SymbolId) ?Access {
        const s = self.symbols.items[sym];
        if (s.access) |a| return a;
        return decideBindingAccess(self, .{ .declared = s.ty });
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

    /// The frame owner a call is in (`frame_owners`): the innermost one
    /// around it; null for a call outside every owner.
    pub fn ownerOf(self: *const SemContext, call: Sexp) ?u32 {
        const i = self.call_index.get(decisionKey(call) orelse return null) orelse return null;
        return self.frame_calls.items[i].owner;
    }

    /// What a call reaches, as typecheck resolved it; null for a call it
    /// never checked.
    pub fn callTargetOf(self: *const SemContext, call: Sexp) ?CallTarget {
        return self.call_targets.get(decisionKey(call) orelse return null);
    }

    pub fn recordCallTarget(self: *SemContext, call: Sexp, target: CallTarget) !void {
        try self.call_targets.put(self.allocator, decisionKey(call) orelse return, target);
    }

    /// A call of a marked `inline` function (`inline_calls`); null for any
    /// other call.
    pub fn inlineCallOf(self: *const SemContext, call: Sexp) ?InlineCall {
        return self.inline_calls.get(decisionKey(call) orelse return null);
    }

    pub fn recordInlineCall(self: *SemContext, call: Sexp, ic: InlineCall) !void {
        const a = self.arena.allocator();
        try self.inline_calls.put(self.allocator, decisionKey(call) orelse return, .{ .fun = ic.fun, .subst = .{ .params = try a.dupe(SymbolId, ic.subst.params), .args = try a.dupe(TypeId, ic.subst.args) } });
    }

    /// The context of the module that declares `fun`: this one, or one
    /// it imports.
    pub fn declaringContext(self: *const SemContext, fun: FnRef) ?*const SemContext {
        if (fun.module == self.module_id) return self;
        return self.foreign_semas.get(fun.module);
    }

    /// The frame of owner `owner` with everything inlined into it: the
    /// one reader of a frame's account (`Account`).
    pub fn account(self: *const SemContext, owner: u32) Account {
        return self.frame_owners.items[owner].account;
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

    /// A string literal at `pos` that holds `bytes` where a `U8` goes, or
    /// a `[N]U8` (`array`); recorded once.
    pub fn recordByteLiteral(self: *SemContext, pos: u32, bytes: []const u8, array: bool) !void {
        for (self.byte_literals.items) |l| if (l.pos == pos) return;
        try self.byte_literals.append(self.allocator, .{ .pos = pos, .bytes = bytes, .array = array });
    }

    /// The type `$name` names at `node` where no value of it is made: an
    /// API object's (`Checker.builtinTypeArg`).
    pub fn recordNamedType(self: *SemContext, node: Sexp, ty: TypeId) !void {
        try self.facts.types.put(self.allocator, recordExprKey(node) orelse return, ty);
    }

    pub fn recordType(self: *SemContext, node: Sexp, ty: TypeId) !void {
        try self.facts.types.put(self.allocator, recordExprKey(node) orelse return, ty);
        // A Cell of an API object is Stage 5's: a program that makes one
        // without declaring its type is rejected here, once.
        if (self.typeInfo(ty).object) if (objectCell(self, ty)) |cell| if (!objectRejected(self)) try objectUnbuiltError(self, self.startOf(node), object_cell, .{try formatType(self, cell)});
        // An element read copies its value, or is reached where it is,
        // as its type says (`copiesElem`), decided with the type.
        if (node.isKind(.index)) {
            if (copies(self, ty) == .yes) {
                try self.facts.elem_copies.put(self.allocator, recordKey(node), {});
            } else _ = self.facts.elem_copies.remove(recordKey(node));
        }
    }

    /// Whether reading element `node` (`x[i]`) copies its value out
    /// (`sema.copies` of its type is `.yes`) rather than reaching it where
    /// it is.
    pub fn copiesElem(self: *const SemContext, node: Sexp) bool {
        return self.facts.elem_copies.contains(nodeKey(node) orelse return false);
    }

    /// `node` yields a view where its context reads the value it
    /// reaches: a Copy value where the value is expected, an operand, the
    /// optional of `??`, `?`, or `as`, a `?String` or slice indexed, or a
    /// clone.
    pub fn recordRead(self: *SemContext, node: Sexp) !void {
        try self.facts.reads.put(self.allocator, recordExprKey(node) orelse return, {});
    }

    /// `node`, an `a ?? b` or `a catch b` whose payload is a view `?T` or
    /// `!T` of a `T` that copies, and whose fallback is a `T`, not a view:
    /// it gives the `T`, the payload's value copied out where `a` has
    /// one, as `if a as v` then `v` else `b` would (`copiesPayload`); or,
    /// with `copied` false, that it gives the view.
    /// `node`'s value becomes an optional where it goes (`Lift`), or,
    /// with null, no longer does: the latest check of the node decides.
    pub fn recordLift(self: *SemContext, node: Sexp, lift: ?Lift) !void {
        const key = recordExprKey(node) orelse return;
        if (lift) |l| {
            try self.facts.lifts.put(self.allocator, key, l);
        } else _ = self.facts.lifts.remove(key);
    }

    /// The optional `node`'s value becomes where it goes (`recordLift`).
    pub fn liftOf(self: *const SemContext, node: Sexp) ?Lift {
        return self.facts.lifts.get(exprKey(node) orelse return null);
    }

    pub fn recordPayloadCopy(self: *SemContext, node: Sexp, copied: bool) !void {
        if (copied) {
            try self.facts.payload_copies.put(self.allocator, recordKey(node), {});
        } else _ = self.facts.payload_copies.remove(nodeKey(node) orelse return);
    }

    /// Whether `node`, an `a ?? b` or `a catch b`, copies the value its
    /// payload views out (`recordPayloadCopy`).
    pub fn copiesPayload(self: *const SemContext, node: Sexp) bool {
        return self.facts.payload_copies.contains(nodeKey(node) orelse return false);
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

    pub fn recordSetPatternMembers(self: *SemContext, node: Sexp, members: []const SetMember) !void {
        try self.facts.set_pattern_members.put(self.allocator, recordKey(node), members);
    }

    pub fn setPatternMembers(self: *const SemContext, node: Sexp) ?[]const SetMember {
        return self.facts.set_pattern_members.get(nodeKey(node) orelse return null);
    }

    pub fn recordMemberCompares(self: *SemContext, member: Field, compares: MemberCompares) !void {
        try self.facts.member_compares.put(self.allocator, member.decl_pos, compares);
    }

    pub fn memberCompares(self: *const SemContext, member: Field) MemberCompares {
        return self.facts.member_compares.get(member.decl_pos) orelse .{};
    }

    pub fn recordCodeWidening(self: *SemContext, node: Sexp) !void {
        try self.facts.code_widenings.put(self.allocator, exprKey(node) orelse return, {});
    }

    pub fn isCodeWidening(self: *const SemContext, node: Sexp) bool {
        return self.facts.code_widenings.contains(exprKey(node) orelse return false);
    }

    pub fn recordFailingLeaf(self: *SemContext, node: Sexp) !void {
        try self.facts.failing_leaves.put(self.allocator, exprKey(node) orelse return, {});
    }

    pub fn isFailingLeaf(self: *const SemContext, node: Sexp) bool {
        return self.facts.failing_leaves.contains(exprKey(node) orelse return false);
    }

    pub fn recordMemberTest(self: *SemContext, node: Sexp) !void {
        try self.facts.member_tests.put(self.allocator, recordKey(node), {});
    }

    pub fn isMemberTest(self: *const SemContext, node: Sexp) bool {
        return self.facts.member_tests.contains(nodeKey(node) orelse return false);
    }

    pub fn isErrorMember(self: *const SemContext, node: Sexp) bool {
        return self.facts.error_members.contains(nodeKey(node) orelse return false);
    }

    /// `node`, a `member` `e.text`, is the name of plain enum value
    /// `e`'s variant, not a field.
    pub fn recordEnumText(self: *SemContext, node: Sexp) !void {
        try self.facts.enum_texts.put(self.allocator, recordKey(node), {});
    }

    pub fn isEnumText(self: *const SemContext, node: Sexp) bool {
        return self.facts.enum_texts.contains(nodeKey(node) orelse return false);
    }

    pub fn recordTableWrite(self: *SemContext, node: Sexp) !void {
        try self.facts.table_writes.put(self.allocator, recordKey(node), {});
    }

    /// Whether `t[s]`, a table's slot, is written (`table_writes`).
    pub fn isTableWrite(self: *const SemContext, node: Sexp) bool {
        return self.facts.table_writes.contains(nodeKey(node) orelse return false);
    }

    /// The program calls `E.from_text` on plain enum `decl`, so its
    /// module emits `E`'s table of names (`hasTextTable`). One of
    /// another module is marked there once every module is checked
    /// (`modules.ModuleGraph.markTextTables`).
    pub fn recordTextTable(self: *SemContext, decl: NominalDecl) !void {
        if (decl.module_id) |m| if (m != self.module_id) {
            return self.foreign_text_tables.append(self.allocator, .{ .module_id = m, .sym = decl.sym });
        };
        try self.text_tables.put(self.allocator, decl.sym, {});
    }

    pub fn hasTextTable(self: *const SemContext, sym: SymbolId) bool {
        return self.text_tables.contains(sym);
    }

    /// `node`, an optional field or element, could not be taken with
    /// `<node`: the type checker's check of the take rejects it.
    pub fn recordUntakeable(self: *SemContext, node: Sexp) !void {
        try self.untakeable.put(self.allocator, recordKey(node), {});
    }

    /// Whether `<node` would be rejected (`recordUntakeable`).
    pub fn untakeableAt(self: *const SemContext, node: Sexp) bool {
        return self.untakeable.contains(nodeKey(node) orelse return false);
    }

    pub fn recordTake(self: *SemContext, node: Sexp) !void {
        try self.facts.takes.put(self.allocator, recordKey(node), {});
    }

    /// `node` writes binding `sym` (`WriteKind`). The binding's flags
    /// follow from the record: an assignment of the binding itself
    /// reassigns it, which lowers it to a Zig `var`; a write through it
    /// (a write lend, a store into a part, a take, a write capture) marks
    /// it written, which does too. A move of the whole binding leaves its
    /// flags alone.
    pub fn recordWrite(self: *SemContext, node: Sexp, sym: SymbolId, kind: WriteKind) !void {
        try self.write_sites.put(self.allocator, recordKey(node), .{ .sym = sym, .kind = kind });
        const flags = &self.symbols.items[sym].flags;
        switch (kind) {
            .assign, .compound => flags.reassigned = true,
            .lend_write, .elem_store, .take, .capture => flags.written = true,
            .move => {},
        }
    }

    /// The binding `node` writes, and how; null for a node that writes none.
    pub fn writeSiteOf(self: *const SemContext, node: Sexp) ?WriteSite {
        return self.write_sites.get(nodeKey(node) orelse return null);
    }

    /// Record which of `node`'s tests are known to pass. Only
    /// `src/proofs.zig` calls this.
    pub fn recordProven(self: *SemContext, node: Sexp, p: Proven) !void {
        if (!p.any()) return;
        try self.proven.put(self.allocator, recordKey(node), p);
    }

    /// `root` is a unit of kind `kind`, and the one holding each node of
    /// `parts` outside the blocks in them (`rig.eachUnit`).
    pub fn recordUnit(self: *SemContext, root: Sexp, kind: rig.UnitKind, parts: []const Sexp) !void {
        const key = recordKey(root);
        try self.unit_roots.put(self.allocator, key, kind);
        try self.unit_of.put(self.allocator, key, key);
        for (parts) |p| try self.markUnit(p, key);
    }

    /// Mark `e` and what it holds as `unit`'s, up to the blocks in it,
    /// which hold units of their own and the statements that order them.
    fn markUnit(self: *SemContext, e: Sexp, unit: NodeKey) !void {
        if (e != .list or e.isKind(.block)) return;
        if (nodeKey(e)) |k| try self.unit_of.put(self.allocator, k, unit);
        for (e.items()) |c| try self.markUnit(c, unit);
    }

    /// The root of the innermost unit holding `node`; null for a node of
    /// no body's unit (a structured statement, a module-level value).
    pub fn unitOf(self: *const SemContext, node: Sexp) ?NodeKey {
        return self.unit_of.get(nodeKey(node) orelse return null);
    }

    /// The kind of the unit `node` is the root of; null for any other node.
    pub fn unitRootKind(self: *const SemContext, node: Sexp) ?rig.UnitKind {
        return self.unit_roots.get(nodeKey(node) orelse return null);
    }

    /// The tests `node` is known to pass: none unless the proof pass
    /// recorded some.
    pub fn provenOf(self: *const SemContext, node: Sexp) Proven {
        return self.proven.get(nodeKey(node) orelse return .{}) orelse .{};
    }

    /// The tests `node` is known to pass while a flag holds, and the
    /// flag's statement; null unless the proof pass recorded some.
    pub fn provenIfOf(self: *const SemContext, node: Sexp) ?ProvenIf {
        return self.proven_if.get(nodeKey(node) orelse return null);
    }

    /// The tests of the flag made before statement `stmt`, which the
    /// tests `provenIfOf` gives rest on; null when it has none.
    pub fn flagOf(self: *const SemContext, stmt: Sexp) ?[]const FlagTest {
        return self.flags.get(nodeKey(stmt) orelse return null);
    }

    pub fn takes(self: *const SemContext, node: Sexp) bool {
        return self.facts.takes.contains(nodeKey(node) orelse return false);
    }

    /// `*w` (`node`, a `share`) of a weak handle `w`, a `~T` or a view of
    /// one, upgrades it (`how`): its value is a new `*T?`, a new count
    /// while the value lives and `none` after. The type checker decides
    /// it once, by the operand's type.
    pub fn recordUpgrade(self: *SemContext, node: Sexp, how: Upgrade) !void {
        try self.facts.upgrades.put(self.allocator, recordKey(node), how);
    }

    /// How `*w` upgrades a weak handle (`recordUpgrade`); null where `*`
    /// makes a counted handle.
    pub fn upgradeOf(self: *const SemContext, node: Sexp) ?Upgrade {
        return self.facts.upgrades.get(nodeKey(node) orelse return null);
    }

    /// Header `node` (a `match`, `for`, or `as`) is evaluated in a block
    /// that ends the temporaries its subject makes (`firstStmtTemp`)
    /// and yields the subject's value, which reaches no place
    /// (`storage.headerPoints`), so what it binds views a copy of that
    /// value, not the subject itself.
    pub fn recordHeaderCopy(self: *SemContext, node: Sexp) !void {
        try self.facts.header_copies.put(self.allocator, recordKey(node), {});
    }

    /// Whether a use may move binding `sym` out (`consumed`).
    pub fn consumes(self: *const SemContext, sym: SymbolId) bool {
        return self.consumed.contains(sym);
    }

    /// The field paths a use may move out of binding `sym`
    /// (`field_moves`), in the order they are first met; empty for most.
    pub fn fieldMoves(self: *const SemContext, sym: SymbolId) []const []const u8 {
        const paths = self.field_moves.getPtr(sym) orelse return &.{};
        return paths.items;
    }

    /// Record how each part of the results `node` holds is held
    /// (`part_drops`).
    pub fn recordPartDrops(self: *SemContext, node: Sexp, kinds: []const ?ResourceKind) !void {
        const key = recordExprKey(node) orelse return;
        try self.part_drops.put(self.allocator, key, try self.arena.allocator().dupe(?ResourceKind, kinds));
    }

    /// How each part of the results `node` holds is held, if the storage
    /// plan recorded it (`part_drops`).
    pub fn partDrops(self: *const SemContext, node: Sexp) ?[]const ?ResourceKind {
        return self.part_drops.get(exprKey(node) orelse return null);
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

    /// `node`, an assignment of a `!T` binding (`w = v`, `w += 1`), writes
    /// the value it views; the binding keeps pointing where it did.
    pub fn recordWriteThrough(self: *SemContext, node: Sexp) !void {
        try self.facts.write_throughs.put(self.allocator, recordKey(node), {});
    }

    pub fn writesThrough(self: *const SemContext, node: Sexp) bool {
        return self.facts.write_throughs.contains(nodeKey(node) orelse return false);
    }

    /// `node`, a payload binding of a variant pattern, binds a field of
    /// type `ty`: the declared field's type at the matched instance
    /// (`Opt[?T]`'s `v: T` is a `?T`), in this module's types.
    pub fn recordPayloadField(self: *SemContext, node: Sexp, ty: TypeId) !void {
        try self.facts.payload_fields.put(self.allocator, recordExprKey(node) orelse return, ty);
    }

    /// The type of the field payload binding `node` binds
    /// (`recordPayloadField`); null for a binding sema did not type.
    pub fn payloadFieldOf(self: *const SemContext, node: Sexp) ?TypeId {
        return self.facts.payload_fields.get(exprKey(node) orelse return null);
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

    /// `node`, a scalar operand of a lane-wise operator or of `select`,
    /// stands for every lane of a vector of type `ty`: emit writes it
    /// splatted, `@as(V, @splat(x))`.
    pub fn recordSplat(self: *SemContext, node: Sexp, ty: TypeId) !void {
        try self.facts.splats.put(self.allocator, recordExprKey(node) orelse return, ty);
    }

    /// The vector type a scalar operand stands for (`recordSplat`).
    pub fn splatOf(self: *const SemContext, node: Sexp) ?TypeId {
        return self.facts.splats.get(exprKey(node) orelse return null);
    }

    pub fn recordElemCall(self: *SemContext, callee: Sexp, call: ElemCall) !void {
        try self.facts.elem_calls.put(self.allocator, recordKey(callee), call);
    }

    /// The built-in element method a call's callee (`member`) names.
    pub fn elemCallOf(self: *const SemContext, callee: Sexp) ?ElemCall {
        return self.facts.elem_calls.get(nodeKey(callee) orelse return null);
    }

    /// The recorded answer to `q` about `node`; null when no pass has
    /// asked it.
    pub fn decision(self: *const SemContext, node: Sexp, q: Question) ?u8 {
        const d = self.decided.map.get(.{ .node = decisionKey(node) orelse return null, .q = q }) orelse return null;
        // Two nodes never share a key: the parser numbers each list node,
        // and a rewrite that keeps a number replaces the node it took it
        // from.
        if (node == .list and d.node.list.items().ptr != node.list.items().ptr)
            std.debug.panic("internal error: two nodes share the key of a decision ({s})", .{@tagName(q)});
        return d.answer;
    }

    /// Record `answer` to `q` about `node` (in the construct `at`, for a
    /// question that depends on it), the first time it is decided,
    /// before the plan seals the record. A memo: it changes no fact a pass
    /// reads but this one, so it is written through a constant context.
    /// A node no key names is decided again where it is asked. Running out
    /// of memory here stops the compiler, which keeps the questions
    /// infallible for their many callers.
    pub fn recordDecision(self: *const SemContext, node: Sexp, at: Sexp, q: Question, answer: u8) void {
        if (self.decided.sealed) return;
        const key = decisionKey(node) orelse return;
        self.decided.map.put(self.allocator, .{ .node = key, .q = q }, .{ .node = node, .at = at, .answer = answer }) catch std.debug.panic("out of memory", .{});
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

    pub fn recordTaskJoin(self: *SemContext, call: Sexp) !void {
        try self.facts.task_joins.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is a `task.all` (`recordTaskJoin`).
    pub fn isTaskJoin(self: *const SemContext, call: Sexp) bool {
        return self.facts.task_joins.contains(exprKey(call) orelse return false);
    }

    pub fn recordActorMake(self: *SemContext, call: Sexp) !void {
        try self.facts.actor_makes.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `Actor(x)` (`recordActorMake`).
    pub fn isActorMake(self: *const SemContext, call: Sexp) bool {
        return self.facts.actor_makes.contains(exprKey(call) orelse return false);
    }

    /// `call` is `Frozen(x)`, under `*`: the runtime makes the frozen value
    /// behind its first handle.
    pub fn recordFrozenMake(self: *SemContext, call: Sexp) !void {
        try self.facts.frozen_makes.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `Frozen(x)` (`recordFrozenMake`).
    pub fn isFrozenMake(self: *const SemContext, call: Sexp) bool {
        return self.facts.frozen_makes.contains(exprKey(call) orelse return false);
    }

    pub fn recordActorSupervised(self: *SemContext, call: Sexp) !void {
        try self.facts.actor_supervised.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `Actor.supervised(f)` (`recordActorSupervised`).
    pub fn isActorSupervised(self: *const SemContext, call: Sexp) bool {
        return self.facts.actor_supervised.contains(exprKey(call) orelse return false);
    }

    pub fn recordChanMake(self: *SemContext, call: Sexp) !void {
        try self.facts.chan_makes.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `Chan[T](n)` (`recordChanMake`).
    pub fn isChanMake(self: *const SemContext, call: Sexp) bool {
        return self.facts.chan_makes.contains(exprKey(call) orelse return false);
    }

    pub fn recordSelect(self: *SemContext, call: Sexp) !void {
        try self.facts.select_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `task.select` (`recordSelect`).
    pub fn isSelect(self: *const SemContext, call: Sexp) bool {
        return self.facts.select_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordSelectArm(self: *SemContext, call: Sexp, arm: SelectArm) !void {
        try self.facts.select_arms.put(self.allocator, recordExprKey(call) orelse return, arm);
    }

    /// The arm `call` is of a `task.select`, if it is one.
    pub fn selectArmOf(self: *const SemContext, call: Sexp) ?SelectArm {
        return self.facts.select_arms.get(exprKey(call) orelse return null);
    }

    pub fn recordActorCall(self: *SemContext, call: Sexp) !void {
        try self.facts.actor_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` calls a method through an actor's handle
    /// (`recordActorCall`).
    pub fn isActorCall(self: *const SemContext, call: Sexp) bool {
        return self.facts.actor_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordTypeParamCall(self: *SemContext, call: Sexp) !void {
        try self.facts.type_param_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` calls a method on a value of a type parameter
    /// (`recordTypeParamCall`).
    pub fn isTypeParamCall(self: *const SemContext, call: Sexp) bool {
        return self.facts.type_param_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordSuperviseCall(self: *SemContext, call: Sexp) !void {
        try self.facts.supervise_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `task.supervise` (`recordSuperviseCall`).
    pub fn isSuperviseCall(self: *const SemContext, call: Sexp) bool {
        return self.facts.supervise_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordHttpServe(self: *SemContext, call: Sexp) !void {
        try self.facts.http_serves.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `http.serve` (`recordHttpServe`).
    pub fn isHttpServe(self: *const SemContext, call: Sexp) bool {
        return self.facts.http_serves.contains(exprKey(call) orelse return false);
    }

    pub fn recordReduceCall(self: *SemContext, call: Sexp) !void {
        try self.facts.reduce_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `xs.reduce(start, f)` (`recordReduceCall`).
    pub fn isReduceCall(self: *const SemContext, call: Sexp) bool {
        return self.facts.reduce_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordIoCopy(self: *SemContext, call: Sexp) !void {
        try self.facts.io_copies.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is `io.copy` (`recordIoCopy`).
    pub fn isIoCopy(self: *const SemContext, call: Sexp) bool {
        return self.facts.io_copies.contains(exprKey(call) orelse return false);
    }
    /// Records that closure literal `lambda` is called at most once, by
    /// the call it is passed to, whose parameter is written `once`: what
    /// it owns of its captures, its one call takes (`once_captures`).
    pub fn recordOnceClosure(self: *SemContext, lambda: Sexp) !void {
        try self.facts.once_closures.put(self.allocator, recordExprKey(lambda) orelse return, {});
        for (captureList(ir.Lambda.captures(lambda))) |cap| switch (captureModeOf(cap) orelse continue) {
            .cap_move, .cap_clone, .cap_weak => {
                const sym = self.symbolOf(captureNameNode(cap) orelse continue) orelse continue;
                try self.once_captures.put(self.allocator, sym, {});
            },
            .cap_read, .cap_write => {},
        };
    }

    /// Whether closure literal `lambda` is called exactly once
    /// (`recordOnceClosure`).
    pub fn isOnceClosure(self: *const SemContext, lambda: Sexp) bool {
        return self.facts.once_closures.contains(exprKey(lambda) orelse return false);
    }

    /// Whether capture `sym` is taken by its closure's one call
    /// (`recordOnceClosure`).
    pub fn isOnceCapture(self: *const SemContext, sym: SymbolId) bool {
        return self.once_captures.contains(sym);
    }

    /// Records that the task `call` makes is local, pinned by `local`;
    /// the first part found to pin it is the one kept.
    pub fn recordLocalTask(self: *SemContext, call: Sexp, local: LocalTask) !void {
        const entry = try self.facts.local_tasks.getOrPut(self.allocator, recordExprKey(call) orelse return);
        if (!entry.found_existing) entry.value_ptr.* = local;
    }

    /// Whether the task `call` makes is local (`recordLocalTask`).
    pub fn isLocalTask(self: *const SemContext, call: Sexp) bool {
        return self.facts.local_tasks.contains(exprKey(call) orelse return false);
    }

    pub fn recordIsolateCall(self: *SemContext, call: Sexp) !void {
        try self.facts.isolate_calls.put(self.allocator, recordExprKey(call) orelse return, {});
    }

    /// Whether `call` is a `task.isolate` (`recordIsolateCall`).
    pub fn isIsolateCall(self: *const SemContext, call: Sexp) bool {
        return self.facts.isolate_calls.contains(exprKey(call) orelse return false);
    }

    pub fn recordParCall(self: *SemContext, call: Sexp, kind: ParCall) !void {
        try self.facts.par_calls.put(self.allocator, recordExprKey(call) orelse return, kind);
    }

    /// Which of `par.map` and `par.each` `call` is, or null for any
    /// other call (`recordParCall`).
    pub fn parCallOf(self: *const SemContext, call: Sexp) ?ParCall {
        return self.facts.par_calls.get(exprKey(call) orelse return null);
    }

    pub fn recordTestCheck(self: *SemContext, node: Sexp, shown: []const u8) !void {
        try self.facts.test_checks.put(self.allocator, recordExprKey(node) orelse return, shown);
    }

    /// When `node`, a test's last line or a `return` in a test, gives the
    /// `Bool` that decides the test (`recordTestCheck`), what `rig test`
    /// reports when it is `false`.
    pub fn testCheckOf(self: *const SemContext, node: Sexp) ?[]const u8 {
        return self.facts.test_checks.get(exprKey(node) orelse return null);
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

    /// The member access `node` reaches a field read-only here
    /// (`Facts.read_only_fields`).
    pub fn recordReadOnlyField(self: *SemContext, node: Sexp, field: ReadOnlyField) !void {
        try self.facts.read_only_fields.put(self.allocator, recordKey(node), field);
    }

    pub fn readOnlyFieldOf(self: *const SemContext, node: Sexp) ?ReadOnlyField {
        return self.facts.read_only_fields.get(nodeKey(node) orelse return null);
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

    /// The `break` or `continue` `jump` goes to `dest` (`JumpDest`).
    pub fn recordJumpDest(self: *SemContext, jump: Sexp, dest: JumpDest) !void {
        try self.facts.jump_dests.put(self.allocator, recordKey(jump), dest);
    }

    /// Where the `break` or `continue` `jump` goes; null for a jump the
    /// type checker did not reach or rejected.
    pub fn jumpDestOf(self: *const SemContext, jump: Sexp) ?JumpDest {
        return self.facts.jump_dests.get(nodeKey(jump) orelse return null);
    }

    /// The variant pattern `pattern` binds, for each payload field of its
    /// variant in field order, `binds[i]`: a name leaf, `_`, or `.nil` for
    /// a field a pattern that binds by name leaves out.
    pub fn recordPayloadBindings(self: *SemContext, pattern: Sexp, binds: []const Sexp) !void {
        try self.facts.payload_binds.put(self.allocator, recordKey(pattern), binds);
    }

    /// The binding of each payload field of the variant `pattern` matches,
    /// in field order (`recordPayloadBindings`): `.rect(w: a)` binds
    /// `rect(w, h)`'s fields as `.rect(a, _)` does, with `.nil` for `_`.
    /// Null for a pattern the checker rejected, or that binds nothing.
    /// Every pass that pairs a pattern's bindings with the fields they
    /// bind reads this.
    pub fn payloadBindings(self: *const SemContext, pattern: Sexp) ?[]const Sexp {
        return self.facts.payload_binds.get(nodeKey(pattern) orelse return null);
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

    pub fn recordStringCall(self: *SemContext, call: Sexp, op: StringCall) !void {
        try self.facts.string_calls.put(self.allocator, recordKey(call), op);
    }

    /// The built-in String operation a `String(...)` call or a method's
    /// callee (`member`) is.
    pub fn stringCallOf(self: *const SemContext, node: Sexp) ?StringCall {
        return self.facts.string_calls.get(nodeKey(node) orelse return null);
    }

    pub fn recordStringNum(self: *SemContext, callee: Sexp, num: TypeId) !void {
        try self.facts.string_nums.put(self.allocator, recordKey(callee), num);
    }

    /// The integer type `T` of a `t.push[T, e](v)` callee.
    pub fn stringNumOf(self: *const SemContext, callee: Sexp) ?TypeId {
        return self.facts.string_nums.get(nodeKey(callee) orelse return null);
    }

    pub fn recordInstance(self: *SemContext, node: Sexp, inst: Instance) !void {
        try self.facts.instances.put(self.allocator, recordKey(node), inst);
    }

    pub fn recordCtCall(self: *SemContext, node: Sexp, call: CtCall) !void {
        try self.facts.ct_calls.put(self.allocator, recordKey(node), call);
    }

    pub fn ctCallOf(self: *const SemContext, node: Sexp) ?CtCall {
        return self.facts.ct_calls.get(nodeKey(node) orelse return null);
    }

    pub fn recordGenericCall(self: *SemContext, node: Sexp, call: GenericCall) !void {
        try self.facts.generic_calls.put(self.allocator, recordKey(node), call);
    }

    /// How method call `call` reaches its method (`Dispatch`): `direct`
    /// unless a call through a bound or an API recorded `static`.
    pub fn recordDispatch(self: *SemContext, call: Sexp, d: Dispatch) !void {
        try self.facts.dispatch.put(self.allocator, recordKey(call), d);
    }

    pub fn dispatchOf(self: *const SemContext, call: Sexp) ?Dispatch {
        return self.facts.dispatch.get(nodeKey(call) orelse return null);
    }

    /// `node`, erased to an API object (`Erasure`).
    pub fn recordErasure(self: *SemContext, node: Sexp, e: Erasure) !void {
        try self.facts.erasures.put(self.allocator, recordExprKey(node) orelse return, e);
    }

    pub fn erasureOf(self: *const SemContext, node: Sexp) ?Erasure {
        return self.facts.erasures.get(exprKey(node) orelse return null);
    }

    pub fn recordOwnerWitnesses(self: *SemContext, call: Sexp, w: OwnerWitnesses) !void {
        try self.facts.owner_witnesses.put(self.allocator, recordKey(call), w);
    }

    pub fn ownerWitnessesOf(self: *const SemContext, call: Sexp) ?OwnerWitnesses {
        return self.facts.owner_witnesses.get(nodeKey(call) orelse return null);
    }

    /// Record an instance of a generic function a call makes at `site`:
    /// a concrete one, checked against its body's requirements, or, from
    /// a call inside a generic body, one over type parameters, which
    /// each instance of that body makes concrete
    /// (`expandInstantiations`, which gives the instance written at
    /// `site` that it is made `via`). Whether it was new.
    pub fn recordFnInstance(self: *SemContext, inst: FnInstance, site: u32, via: ?InstanceRoot) !bool {
        return self.recordInstanceOf(inst, site, via, false);
    }

    /// `recordFnInstance` of a call in the body of method `in` (null for
    /// any other place): one over type parameters is made where the
    /// method is reached (`generic_fn_uses_in`).
    pub fn recordFnInstanceIn(self: *SemContext, inst: FnInstance, site: u32, in: ?FnRef) !bool {
        if (!argsHaveTypeVar(self, inst.args)) return self.recordInstanceOf(inst, site, null, false);
        const same: FnInstance.Context = .{};
        for (self.generic_fn_uses.items, self.generic_fn_uses_in.items) |u, at| {
            if (!same.eql(u, inst)) continue;
            const old = at orelse return false;
            const new = in orelse continue;
            if (old.module == new.module and old.pos == new.pos) return false;
        }
        const owned = try self.ownFnInstance(inst);
        try self.fn_instance_set.put(self.allocator, owned, {});
        try self.addGeneric(.fn_uses, owned);
        try self.generic_fn_uses_in.append(self.allocator, in);
        return true;
    }

    /// Record the concrete instance `implInstance` gives a call through
    /// an API, made at `site` (`via` the instance written there). Whether
    /// it was new.
    pub fn recordImplInstance(self: *SemContext, inst: FnInstance, site: u32, via: ?InstanceRoot) !bool {
        return self.recordInstanceOf(inst, site, via, true);
    }

    fn recordInstanceOf(self: *SemContext, inst: FnInstance, site: u32, via: ?InstanceRoot, through_api: bool) !bool {
        if (self.fn_instance_set.contains(inst)) return false;
        const owned = try self.ownFnInstance(inst);
        try self.fn_instance_set.put(self.allocator, owned, {});
        for (inst.args) |a| if (self.typeInfo(a).has_type_var) {
            try self.addGeneric(.fn_uses, owned);
            try self.generic_fn_uses_in.append(self.allocator, null);
            return true;
        };
        try self.fn_instances.append(self.allocator, .{ .inst = owned, .site = site, .via = via, .through_api = through_api });
        return true;
    }

    /// Record a call through an API of a program's own (`ApiCall`): one
    /// whose types are known, or one over the parameters of the generic
    /// body it is in.
    pub fn recordApiCall(self: *SemContext, call: ApiCall) !void {
        if (self.api_call_set.contains(call)) return;
        var owned = call;
        owned.args = try self.arena.allocator().dupe(TypeId, call.args);
        owned.slots = try self.arena.allocator().dupe(u32, call.slots);
        try self.api_call_set.put(self.allocator, owned, {});
        const generic = for (call.args) |a| {
            if (self.typeInfo(a).has_type_var) break true;
        } else self.typeInfo(call.recv).has_type_var;
        if (generic) return self.addGeneric(.api_calls, owned);
        try self.api_calls.append(self.allocator, owned);
    }

    /// Record a method the program reaches (`BodyReach`): one over a
    /// body's parameters for each instance of the body, one with every
    /// type known once. Whether it was new and known.
    pub fn recordBodyReach(self: *SemContext, r: BodyReach) !bool {
        const a = self.arena.allocator();
        var owned = r;
        owned.params = try a.dupe(SymbolId, r.params);
        owned.args = try a.dupe(TypeId, r.args);
        const generic = for (r.args) |t| {
            if (self.typeInfo(t).has_type_var) break true;
        } else self.typeInfo(r.recv).has_type_var;
        if (generic) {
            try self.addGeneric(.reaches, owned);
            return false;
        }
        // A table's methods are known once conformances are checked
        // (`expandInstantiations`).
        if (r.erase != null) {
            try self.erase_reaches.append(self.allocator, owned);
            return false;
        }
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(a, std.mem.asBytes(&r.fun));
        try key.appendSlice(a, std.mem.sliceAsBytes(r.args));
        const gop = try self.reach_set.getOrPut(self.allocator, key.items);
        if (gop.found_existing) return false;
        try self.body_reaches.append(self.allocator, owned);
        return true;
    }

    /// Add `ty`, an instance spelled with type parameters, to
    /// `generic_uses`, made at `site` in the body of method `in` (null for
    /// any other place); one already there, made in the same place or in
    /// every instance, is not added again.
    pub fn addUse(self: *SemContext, ty: TypeId, in: ?FnRef, site: u32) !void {
        for (self.generic_uses.items, self.generic_uses_in.items) |u, at| {
            if (u != ty) continue;
            const old = at orelse return;
            const new = in orelse continue;
            if (old.module == new.module and old.pos == new.pos) return;
        }
        try self.addGeneric(.uses, ty);
        try self.generic_uses_in.append(self.allocator, in);
        try self.generic_uses_at.append(self.allocator, site);
    }

    /// Add `entry` to `list`, indexed by the type and integer parameters
    /// it mentions (`addUse` for `uses`).
    pub fn addGeneric(self: *SemContext, comptime list: GenericList, entry: @typeInfo(@FieldType(@FieldType(SemContext, "generic_" ++ @tagName(list)), "items")).pointer.child) !void {
        const items = &@field(self, "generic_" ++ @tagName(list));
        const at: u32 = @intCast(items.items.len);
        switch (list) {
            .uses => try self.indexParams(list, at, entry),
            .arrays => try self.indexParams(list, at, entry.ty),
            .fn_uses => for (entry.args) |ty| try self.indexParams(list, at, ty),
            .frames => for (entry.tys) |ty| try self.indexParams(list, at, ty),
            .api_calls => {
                try self.indexParams(list, at, entry.recv);
                for (entry.args) |ty| try self.indexParams(list, at, ty);
            },
            .reaches => {
                try self.indexParams(list, at, entry.recv);
                for (entry.args) |ty| try self.indexParams(list, at, ty);
            },
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
        return .{ .name = inst.name, .params = try a.dupe(SymbolId, inst.params), .args = try a.dupe(TypeId, inst.args), .own = inst.own, .shown = inst.shown };
    }

    pub fn intern(self: *SemContext, ty: Type) std.mem.Allocator.Error!TypeId {
        // A view of an API object names only the crossing bound its form
        // uses (`formBraces`): `?{A + Sends}` is `?{A}`.
        switch (ty) {
            .read_view, .write_view => |inner| if (apiObject(self, inner)) |o| {
                const braces = formBraces(o.builtins, if (ty == .read_view) .read else .write);
                if (!braces.eql(o.builtins)) {
                    const object = try self.intern(.{ .api_object = .{ .api = o.api, .builtins = braces } });
                    return self.intern(if (ty == .read_view) .{ .read_view = object } else .{ .write_view = object });
                }
            },
            else => {},
        }
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
            .results => |*parts| parts.* = try self.dupeIds(parts.*),
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
    /// Where `rig check --time` adds the time of each pass.
    timing: ?*timing.Timing = null,
    /// A directory module: where each of its files starts in the source.
    parts: []const diag.Part = &.{},
};

/// The end of a diagnostic for a name a standard library module does
/// not declare, when what it does declare goes by another name: `Rng` in
/// `std.random`, whose generator is `Random`. Empty for any other name.
pub fn stdNameHint(foreign: *const SemContext, name: []const u8) []const u8 {
    if (foreign.is_std and std.mem.eql(u8, foreign.name, "std.random") and std.mem.eql(u8, name, "Rng")) return "; its generator is `Random`";
    return "";
}

/// `module.name`, a public declaration of the imported module `foreign`,
/// named in `ctx`'s module: the two the runtime keeps an answer for only
/// in a program that names one, so no other program pays for it.
/// `time.since_start` needs the clock read as the program starts, and
/// `os.memory` an allocator that counts. Every path to another module's
/// declaration comes here (`Checker.foreignSymbol`); the runtime stops at
/// compile time a program that reaches either one without its flag.
pub fn noteRuntimeRead(ctx: *SemContext, foreign: *const SemContext, name: []const u8) void {
    if (!foreign.is_std) return;
    if (std.mem.eql(u8, foreign.name, "std.time") and std.mem.eql(u8, name, "since_start")) ctx.reads_since_start = true;
    if (std.mem.eql(u8, foreign.name, "std.os") and std.mem.eql(u8, name, "memory")) ctx.reads_memory = true;
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
    var t0 = timing.start(opts.timing);
    var ctx = try SemContext.init(allocator, source);
    errdefer ctx.deinit();

    ctx.parser = opts.parser;
    ctx.module_id = opts.module_id;
    ctx.is_root = opts.is_root;
    ctx.name = opts.name;
    ctx.zig_file = opts.zig_file;
    ctx.is_std = opts.is_std;
    ctx.parts = opts.parts;
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
    timing.stop(opts.timing, .resolve, t0);
    t0 = timing.start(opts.timing);
    try typecheck.checkModule(&ctx, tree, module_scope);
    try typecheck.recordFrameOwners(&ctx, tree);
    try typecheck.checkFrames(&ctx);
    try checkUnreadLocals(&ctx);
    try typecheck.checkDeclaredApis(&ctx);
    try expandInstantiations(&ctx);
    try typecheck.checkGenericInstantiations(&ctx);
    if (@import("build_options").self_check or zig_builtin.is_test) {
        try checkBindingAccess(&ctx);
        try checkTypedClean(&ctx, tree);
    }
    timing.stop(opts.timing, .typecheck, t0);
    t0 = timing.start(opts.timing);
    try storage.plan(&ctx, tree);
    timing.stop(opts.timing, .storage, t0);
    try indexAllMembers(&ctx);
    if (!ctx.hasErrors()) try recordTypeWitnesses(&ctx);
    return ctx;
}

/// Every binding whose access typecheck decided has the type that access
/// gives it (`Checker.viewOfAccess`): `.write` a write view, `.read` a
/// read view, a slice, a `?String`, or a type parameter's value read where
/// it is, and none a value, owned or copied. A binding typed some other
/// way than from its access is a compiler bug, reported where the
/// binding is declared (docs/internals/INTERNALS.md, "Binding access"). Debug and
/// test builds only, of a module typecheck accepted: after an error a
/// binding may hold the type that error left.
fn checkBindingAccess(ctx: *SemContext) std.mem.Allocator.Error!void {
    if (ctx.hasErrors()) return;
    for (ctx.symbols.items) |sym| {
        if (!sym.flags.access_decided or sym.ty == ctx.types.unknown_id or sym.ty == ctx.types.invalid_id) continue;
        const ty = ctx.types.get(sym.ty);
        const agrees = if (sym.access) |a| switch (a) {
            .write => ty == .write_view,
            .read => switch (ty) {
                .read_view, .slice, .string_view => true,
                else => copies(ctx, sym.ty) == .depends,
            },
        } else switch (ty) {
            .read_view, .write_view => false,
            else => true,
        };
        if (agrees) continue;
        const a = ctx.arena.allocator();
        try ctx.err(sym.decl_pos, "internal error: binding `{s}` has type `{s}`, which its access ({s}) does not give", .{ sym.name, try formatTypeIn(ctx, a, sym.ty), if (sym.access) |x| @tagName(x) else "none" });
    }
}

/// A module typecheck accepted types no expression `invalid`, nor with
/// `invalid` in it (`List[invalid]`): a check
/// that rejects reports why, so an `invalid` with no error is a verdict
/// whose diagnostic was dropped (a quiet check's, kept and reused), and
/// emit would write what nothing checked. Reported at the first such
/// expression. Debug and test builds only.
fn checkTypedClean(ctx: *SemContext, tree: Sexp) std.mem.Allocator.Error!void {
    if (ctx.hasErrors()) return;
    if (typedInvalid(ctx, tree)) |e| try ctx.errAt(e, "internal error: `{s}` is typed `invalid`, and no error says why", .{diag.textOf(ctx.source, ctx.span(e))});
}

fn typedInvalid(ctx: *const SemContext, node: Sexp) ?Sexp {
    if (ctx.typeOf(node)) |ty| if (containsPoison(ctx, ty)) return node;
    if (node != .list) return null;
    for (node.items()) |child| if (typedInvalid(ctx, child)) |e| return e;
    return null;
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
        } else if (sym.flags.closure) {
            try ctx.lintErr(sym.decl_pos, "`{s}` is a closure that is never called: call it, or remove it", .{sym.name});
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
/// built-in generic reached this way (`List[T]` in `Stack[T]`) has its
/// element rules checked for the argument. Then the public generics are
/// checked for nesting themselves (`checkSelfNesting`).
fn expandInstantiations(ctx: *SemContext) std.mem.Allocator.Error!void {
    // The instances calls through an API reach where every type is known.
    for (ctx.api_calls.items) |c| if (try implInstance(ctx, c, c.pos, null)) |inst| {
        _ = try ctx.recordImplInstance(inst, c.pos, null);
    };
    for (ctx.erase_reaches.items) |r| try reachMembers(ctx, r.recv, r.erase.?, r.site, r.via);
    if (ctx.generic_uses.items.len == 0 and ctx.generic_fn_uses.items.len == 0 and ctx.generic_api_calls.items.len == 0 and ctx.generic_reaches.items.len == 0) return;
    var work: std.ArrayList(ExpandItem) = .empty;
    defer work.deinit(ctx.allocator);
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |e| {
        const item = typeItem(ctx, e.key_ptr.*) orelse continue;
        try work.append(ctx.allocator, .{ .subst = item, .site = e.value_ptr.*, .root = .{ .type = e.key_ptr.* }, .of_type = true });
    }
    for (ctx.fn_instances.items) |f| try work.append(ctx.allocator, .{ .subst = f.inst.subst(), .site = f.site, .root = .{ .func = f.inst } });
    for (ctx.body_reaches.items) |r| try work.append(ctx.allocator, .{ .subst = .{ .params = r.params, .args = r.args }, .site = r.site, .root = r.via orelse .{ .func = try reachInstance(ctx, r) }, .body = r.fun });
    if (try expand(ctx, &work, null)) return;
    try checkSelfNesting(ctx);
}

/// An instance to expand: its parameters' arguments, where the program
/// makes it, the instance written there that it is reached from, and
/// the generics between the two (`Trail`).
const ExpandItem = struct { subst: TypeSubst, site: u32, root: InstanceRoot, trail: ?*const Trail = null, body: ?FnRef = null, of_type: bool = false };

/// The generics an expansion passed through to reach an instance, each
/// named by its parameters, nearest first: whether one repeats tells a
/// generic that nests itself from a long chain of distinct ones
/// (`deepInstance`).
const Trail = struct { params: []const SymbolId, up: ?*const Trail };

/// The instance at `item.trail` plus `item` itself, as the trail of an
/// instance reached from `item`.
fn trailFrom(ctx: *SemContext, item: ExpandItem) std.mem.Allocator.Error!*const Trail {
    const t = try ctx.arena.allocator().create(Trail);
    t.* = .{ .params = item.subst.params, .up = item.trail };
    return t;
}

/// Report the root of `item`, which reaches an instance (through
/// `through`, a use in the body `item` expands, of the generic with
/// parameters `callee`) whose type arguments nest more than
/// `max_instance_depth` deep. When a generic on the way, the callee
/// among them, is reached twice, it nests itself (`why`) and would
/// expand forever; otherwise the chain of distinct generics is only too
/// deep.
fn deepInstance(ctx: *SemContext, item: ExpandItem, callee: []const SymbolId, kind: []const u8, through: []const u8, why: []const u8) std.mem.Allocator.Error!void {
    const root = try rootName(ctx, item.root);
    const body: Trail = .{ .params = item.subst.params, .up = item.trail };
    const head: Trail = .{ .params = callee, .up = &body };
    var a: ?*const Trail = &head;
    const nests = while (a) |x| : (a = x.up) {
        var b = x.up;
        const again = while (b) |y| : (b = y.up) {
            if (std.mem.eql(SymbolId, x.params, y.params)) break true;
        } else false;
        if (again) break true;
    } else false;
    if (!nests) return ctx.err(item.site, "`{s}` leads to instances of generic {s} whose type arguments nest more than {d} deep (through `{s}`)", .{ root, kind, max_instance_depth, through });
    try ctx.err(item.site, "`{s}` leads to ever deeper instances of generic {s} (through `{s}`); {s}", .{ root, kind, through, why });
}

/// The instances an expansion over type parameters has reached
/// (`checkSelfNesting`), which the program does not make.
const Reached = struct {
    fns: std.HashMapUnmanaged(FnInstance, void, FnInstance.Context, std.hash_map.default_max_load_percentage) = .empty,
    types: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    /// The methods reached, each by its body and the type it is reached
    /// on.
    bodies: std.AutoHashMapUnmanaged(struct { fun: FnRef, recv: TypeId }, void) = .empty,

    fn deinit(self: *Reached, a: std.mem.Allocator) void {
        self.fns.deinit(a);
        self.types.deinit(a);
        self.bodies.deinit(a);
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
        // A reached method's own reaches (`BodyReach`); what else its
        // body makes, its type's instance expands.
        if (item.body != null) {
            if (try expandFnUses(ctx, work, item, reached, &entries)) return true;
            if (try expandUses(ctx, work, item, reached, &entries)) return true;
            try expandReaches(ctx, work, item, reached, &entries);
            continue;
        }
        if (try expandFnUses(ctx, work, item, reached, &entries)) return true;
        if (try expandUses(ctx, work, item, reached, &entries)) return true;
        // A call through an API on the body's parameters reaches, at this
        // instance, the method of the type that provides the API.
        if (reached) |r| {
            if (try expandApiCallsOver(ctx, work, item, r, &entries)) return true;
            try expandReaches(ctx, work, item, reached, &entries);
            continue;
        }
        try ctx.genericEntries(.api_calls, item.subst.params, &entries);
        for (entries.items) |i| {
            var call = ctx.generic_api_calls.items[i];
            call.recv = try substituteType(ctx, call.recv, item.subst);
            if (ctx.typeInfo(call.recv).has_type_var) continue;
            const args = try ctx.arena.allocator().alloc(TypeId, call.args.len);
            for (call.args, args) |a, *out| out.* = try substituteType(ctx, a, item.subst);
            if (argsHaveTypeVar(ctx, args)) continue;
            // A call whose own arguments its body writes is the site of
            // what they make, as a call in a body of known types is.
            const site = if (call.module_id == 0 and call.args.len > 0 and !argsHaveTypeVar(ctx, call.args)) call.pos else item.site;
            call.args = args;
            const concrete = (try implInstance(ctx, call, site, item.root)) orelse continue;
            var deepest: u8 = 0;
            for (concrete.args) |a| deepest = @max(deepest, ctx.typeInfo(a).depth);
            if (deepest > max_instance_depth) {
                const why = if (item.root == .func and item.body == null) "a generic function cannot call itself with its own type parameters nested deeper" else "a generic type's body cannot nest itself in its own type arguments";
                try deepInstance(ctx, item, concrete.params, "functions", try formatFnInstance(ctx, concrete), why);
                return true;
            }
            if (!try ctx.recordImplInstance(concrete, site, item.root)) continue;
            try work.append(ctx.allocator, .{ .subst = concrete.subst(), .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item) });
        }
        try expandReaches(ctx, work, item, reached, &entries);
    }
    return false;
}

/// Whether the method of `nominal_sym` declared at `pos` is called where
/// no call is written: its drop, or a method of a built-in API the type
/// names, which Zig's glue calls. Its body is made at every instance of
/// its type, not only where a call reaches it.
pub fn methodCalledUnwritten(ctx: *const SemContext, nominal_sym: SymbolId, pos: u32) bool {
    if (nominal_sym == symbol_invalid) return false;
    const sym = ctx.symbols.items[nominal_sym];
    for (sym.fields orelse &.{}) |f| {
        if (!f.is_method or f.decl_pos != pos) continue;
        if (f.is_drop_method) return true;
        var it = sym.apis.iterator();
        while (it.next()) |api| if (apiMethodName(api)) |n| if (std.mem.eql(u8, n, f.name)) return true;
    }
    return false;
}

/// The instances `item` makes of the generic functions its body calls
/// (`generic_fn_uses`), as `expandUses` makes those of types. True when
/// one nests too deep, which is reported.
fn expandFnUses(ctx: *SemContext, work: *std.ArrayList(ExpandItem), item: ExpandItem, reached: ?*Reached, entries: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    try ctx.genericEntries(.fn_uses, item.subst.params, entries);
    for (entries.items) |i| {
        const use = ctx.generic_fn_uses.items[i];
        if (!madeBy(item, ctx.generic_fn_uses_in.items[i])) continue;
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
        // forever; a long chain of distinct ones is cut off too.
        if (deepest > max_instance_depth) {
            const why = if (item.root == .func and item.body == null) "a generic function cannot call itself with its own type parameters nested deeper" else "a generic type's body cannot nest itself in its own type arguments";
            try deepInstance(ctx, item, use.params, "functions", try formatFnInstance(ctx, use), why);
            return true;
        }
        // An instance at a renaming of the callee's parameters expands
        // as the callee at its own does, which is kept once.
        if (reached != null and isRenaming(ctx, args)) try ownParamArgs(ctx, use.params, args);
        const concrete: FnInstance = .{ .name = use.name, .params = use.params, .args = args, .own = use.own, .shown = use.shown };
        if (reached) |r| {
            if ((try r.fns.getOrPut(ctx.allocator, concrete)).found_existing) continue;
        } else if (!try ctx.recordFnInstance(concrete, item.site, item.root)) continue;
        try work.append(ctx.allocator, .{ .subst = concrete.subst(), .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item) });
    }
    return false;
}

/// The calls through an API the body `item` expands makes over type
/// parameters, followed where the type they are made on is known (an
/// implementation calling a public generic, `probe(@, k)` in `Sq.walk`,
/// which calls `t.walk(Wrap(v: k))`), kept in `reached`. True when one
/// nests too deep, which is reported.
fn expandApiCallsOver(ctx: *SemContext, work: *std.ArrayList(ExpandItem), item: ExpandItem, reached: *Reached, entries: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    try ctx.genericEntries(.api_calls, item.subst.params, entries);
    for (entries.items) |i| {
        var call = ctx.generic_api_calls.items[i];
        call.recv = try substituteType(ctx, call.recv, item.subst);
        if (ctx.typeInfo(call.recv).has_type_var) continue;
        const args = try ctx.arena.allocator().alloc(TypeId, call.args.len);
        for (call.args, args) |a, *out| out.* = try substituteType(ctx, a, item.subst);
        call.args = args;
        const inst = (try implInstanceOver(ctx, call, item.site)) orelse continue;
        var deepest: u8 = 0;
        for (inst.args) |a| deepest = @max(deepest, ctx.typeInfo(a).depth);
        if (deepest > max_instance_depth) {
            const why = if (item.root == .func and item.body == null) "a generic function cannot call itself with its own type parameters nested deeper" else "a generic type's body cannot nest itself in its own type arguments";
            try deepInstance(ctx, item, inst.params, "functions", try formatFnInstance(ctx, inst), why);
            return true;
        }
        if ((try reached.fns.getOrPut(ctx.allocator, inst)).found_existing) continue;
        try work.append(ctx.allocator, .{ .subst = inst.subst(), .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item) });
    }
    return false;
}

/// Whether `item` makes a use spelled in the body of method `in` (null
/// for one spelled elsewhere): a reached method's body makes its own,
/// and a type's instance those outside its methods; a function's
/// instance makes all of them.
fn madeBy(item: ExpandItem, in: ?FnRef) bool {
    if (item.body) |b| {
        const at = in orelse return false;
        return at.module == b.module and at.pos == b.pos;
    }
    return in == null or !item.of_type;
}

/// The instances `item` makes of the generic types its body spells
/// (`generic_uses`): a type's instance those spelled outside its
/// methods, and a reached method's those its body spells. True when one
/// nests too deep, which is reported.
fn expandUses(ctx: *SemContext, work: *std.ArrayList(ExpandItem), item: ExpandItem, reached: ?*Reached, entries: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    try ctx.genericEntries(.uses, item.subst.params, entries);
    for (entries.items) |i| {
        const use = ctx.generic_uses.items[i];
        // A use in a method's body is made where the method is
        // reached, at the instance that reaches it, never at every
        // instance of its type.
        if (!madeBy(item, ctx.generic_uses_in.items[i])) continue;
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
            const callee = if (typeItem(ctx, concrete)) |t| t.params else &.{};
            try deepInstance(ctx, item, callee, "types", try formatType(ctx, use), "a generic type's body cannot nest itself in its own type arguments");
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
            // A frozen value of a parameter is checked by its requirement
            // (`requireFrozen`), once for each parameter.
            if (builtin and inst.sym == ctx.frozen_sym_id) continue;
            if (builtin) {
                if (try resolve.builtinElementError(ctx, inst.sym, inst.args)) |msg| {
                    try ctx.err(item.site, "`{s}` instantiates `{s}`: {s}", .{ try rootName(ctx, item.root), try formatType(ctx, concrete), msg });
                }
                continue;
            }
            try checkInstanceStacked(ctx, concrete, item.site);
        }
        try work.append(ctx.allocator, .{ .subst = typeItem(ctx, concrete).?, .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item), .of_type = true });
    }
    return false;
}

/// The methods the body `item` expands reaches on its parameters, at its
/// instance (`BodyReach`): one a method's body reaches, only where that
/// method is reached.
fn expandReaches(ctx: *SemContext, work: *std.ArrayList(ExpandItem), item: ExpandItem, reached: ?*Reached, entries: *std.ArrayList(u32)) std.mem.Allocator.Error!void {
    try ctx.genericEntries(.reaches, item.subst.params, entries);
    for (entries.items) |i| {
        var r = ctx.generic_reaches.items[i];
        if (r.in) |in| {
            const b = item.body orelse continue;
            if (b.module != in.module or b.pos != in.pos) continue;
        }
        r.recv = try substituteType(ctx, r.recv, item.subst);
        const args = try ctx.arena.allocator().alloc(TypeId, r.args.len);
        for (r.args, args) |a, *out| out.* = try substituteType(ctx, a, item.subst);
        // Over type parameters, a method a body reaches is followed into
        // its own body and kept in `reached`, never recorded.
        if (reached) |rr| {
            if (r.erase != null or ctx.typeInfo(r.recv).depth > max_instance_depth) continue;
            if ((try rr.bodies.getOrPut(ctx.allocator, .{ .fun = r.fun, .recv = r.recv })).found_existing) continue;
            try work.append(ctx.allocator, .{ .subst = .{ .params = r.params, .args = args }, .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item), .body = r.fun });
            continue;
        }
        if (ctx.typeInfo(r.recv).has_type_var or argsHaveTypeVar(ctx, args)) continue;
        r.args = args;
        r.site = item.site;
        r.via = item.root;
        if (r.erase) |api| {
            const before = ctx.body_reaches.items.len;
            try reachMembers(ctx, r.recv, api, r.site, r.via);
            for (ctx.body_reaches.items[before..]) |n| try work.append(ctx.allocator, .{ .subst = .{ .params = n.params, .args = n.args }, .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item), .body = n.fun });
            continue;
        }
        if (!try ctx.recordBodyReach(r)) continue;
        if (ctx.typeInfo(r.recv).depth > max_instance_depth) continue;
        try work.append(ctx.allocator, .{ .subst = .{ .params = r.params, .args = r.args }, .site = item.site, .root = item.root, .trail = try trailFrom(ctx, item), .body = r.fun });
    }
}

/// `r` as an instance, for messages: `Box[*Node].run`, `Holder.go`.
pub fn reachInstance(ctx: *SemContext, r: BodyReach) std.mem.Allocator.Error!FnInstance {
    return .{ .name = try ctx.arena.allocator().print("{s}.{s}", .{ try formatType(ctx, r.recv), r.method }), .params = r.params, .args = r.args, .own = 0 };
}

/// Every method `recv`, whose type is known, gives `api` and those it
/// builds on, reached at `site` (`BodyReach`): erasing it to an object
/// of `api` makes a table that holds each.
pub fn reachMembers(ctx: *SemContext, recv: TypeId, api: ApiRef, site: u32, via: ?InstanceRoot) std.mem.Allocator.Error!void {
    if (containsPoison(ctx, recv)) return;
    const w = switch ((try witnessFor(ctx, recv, api)) orelse return) {
        .conformance => |c| c,
        .param => return,
    };
    const found = conformanceOf(ctx, .{ .conformance = .{ .module_id = w.module_id, .index = w.index } }) orelse return;
    for (found.conf.members) |m|
        _ = try implReach(ctx, .{ .recv = recv, .api = api, .method = m.name, .args = &.{}, .slots = &.{}, .pos = site }, site, via, .reach_only);
}

/// The instance of the method a call through an API reaches (`ApiCall`,
/// every type known), as the witness names it: the type's own method
/// after the type's parameters, which the type's instance checks; an
/// addition's after the addition's, which no type's instance checks, so
/// this one checks them as its own; or the API's default after its
/// `Self`, whose own parameters the call's instance of the API's method
/// checks, so this one only reaches what the body calls on `Self`. Null
/// when the type does not provide the API, which the bound's check
/// reports; when the instance binds nothing; or when it is recorded
/// already (`fn_instance_set`, looked up before its name is built). A
/// witness that names no method a conformance gives is a compiler bug,
/// reported at `site` (`implLost`), never a check skipped.
pub fn implInstance(ctx: *SemContext, call: ApiCall, site: u32, via: ?InstanceRoot) std.mem.Allocator.Error!?FnInstance {
    return implReach(ctx, call, site, via, .instance);
}

/// `implInstance` over type parameters, for the public nesting check
/// (`checkSelfNesting`): the instance, recording nothing.
fn implInstanceOver(ctx: *SemContext, call: ApiCall, site: u32) std.mem.Allocator.Error!?FnInstance {
    return implReach(ctx, call, site, null, .over_params);
}

/// `implInstance`, recording the method the call reaches
/// (`recordBodyReach`); with `reach_only`, that alone; with
/// `over_params`, the instance alone.
fn implReach(ctx: *SemContext, call: ApiCall, site: u32, via: ?InstanceRoot, mode: enum { instance, reach_only, over_params }) std.mem.Allocator.Error!?FnInstance {
    if (containsPoison(ctx, call.recv)) return null;
    for (call.args) |a| if (containsPoison(ctx, a)) return null;
    const w = switch ((try witnessFor(ctx, call.recv, call.api)) orelse return null) {
        .conformance => |c| c,
        .param => return implLost(ctx, call, site, "its type is a type parameter"),
    };
    const found = conformanceOf(ctx, .{ .conformance = .{ .module_id = w.module_id, .index = w.index } }) orelse return implLost(ctx, call, site, "its witness names no conformance");
    const member = for (found.conf.members) |m| {
        if (std.mem.eql(u8, m.name, call.method)) break m;
    } else return implLost(ctx, call, site, "its conformance's witness has no such method");
    const a = ctx.arena.allocator();
    var outer: TypeSubst = .empty;
    var fn_ty: FunctionType = undefined;
    var fun: ?FnRef = null;
    switch (member.from) {
        .own => {
            const m = (try typeMethod(ctx, call.recv, call.method)) orelse return implLost(ctx, call, site, "its type declares no such method");
            fn_ty = m.fn_ty;
            outer = m.subst;
            if (m.owner.decl_pos != builtin_decl_pos and m.field.decl_pos < imported_decl_pos)
                fun = .{ .module = m.module orelse if (isProxy(m.owner)) m.owner.from.module_id else ctx.module_id, .pos = m.field.decl_pos };
        },
        .added => {
            const f = for (found.conf.methods) |f| {
                if (std.mem.eql(u8, f.name, call.method)) break f;
            } else return implLost(ctx, call, site, "its addition declares no such method");
            const local = found.home == @as(*const SemContext, ctx);
            const ty = if (local) f.ty else try importType(ctx, found.home, f.ty, w.module_id);
            if (ctx.types.get(ty) != .function) return implLost(ctx, call, site, "its addition's method is no function");
            fn_ty = ctx.types.get(ty).function;
            const params = try a.alloc(SymbolId, found.conf.params.len);
            for (found.conf.params, params) |p, *out| out.* = if (local) p else try proxyOf(ctx, .{ .module_id = w.module_id, .sym = p });
            outer = .{ .params = params, .args = try conformanceArgs(ctx, a, call.recv) };
            if (outer.params.len != outer.args.len) return implLost(ctx, call, site, "its addition's parameters and its type's arguments differ in count");
            fun = .{ .module = w.module_id, .pos = f.decl_pos };
        },
        .default => |ref| {
            const home = apiContext(ctx, ref) orelse return implLost(ctx, call, site, "the API that declares its default is not known");
            const sym = apiSymbol(ctx, ref) orelse return implLost(ctx, call, site, "the API that declares its default is not known");
            const f = for (sym.fields orelse &.{}) |f| {
                if (f.is_method and std.mem.eql(u8, f.name, call.method)) break f;
            } else return implLost(ctx, call, site, "its API declares no such default");
            const local = home == @as(*const SemContext, ctx);
            const ty = if (local) f.ty else try importType(ctx, home, f.ty, ref.module_id);
            if (ctx.types.get(ty) != .function) return implLost(ctx, call, site, "its default is no function");
            fn_ty = ctx.types.get(ty).function;
            const home_self = (sym.type_params orelse return implLost(ctx, call, site, "its API has no `Self`"))[0];
            const self_param = if (local) home_self else try proxyOf(ctx, .{ .module_id = ref.module_id, .sym = home_self });
            outer = .{ .params = try a.dupe(SymbolId, &.{self_param}), .args = try a.dupe(TypeId, &.{call.recv}) };
            fun = .{ .module = ref.module_id, .pos = f.decl_pos };
        },
    }
    if (mode != .over_params) if (fun) |body| if (outer.params.len > 0) {
        _ = try ctx.recordBodyReach(.{ .fun = body, .params = outer.params, .args = outer.args, .recv = call.recv, .method = call.method, .site = site, .via = via });
    };
    if (mode == .reach_only) return null;
    // The implementation declares the API's method's compile-time
    // parameters exactly (Stage 3 conformance), so the slots the call's
    // arguments fill are its own parameters too.
    const own = try a.alloc(SymbolId, call.slots.len);
    for (call.slots, own) |slot, *p| {
        p.* = (if (slot < fn_ty.ct_params.len) ownParamOf(ctx, fn_ty, slot) else null) orelse
            return implLost(ctx, call, site, "a compile-time slot its arguments fill is none of the implementation's own parameters");
    }
    var declared: usize = 0;
    for (0..fn_ty.ct_params.len) |i| declared += @intFromBool(ownParamOf(ctx, fn_ty, i) != null);
    if (declared != own.len or call.args.len != own.len) return implLost(ctx, call, site, "the implementation's own compile-time parameters differ in count from the arguments the call gives");
    const own_n: u32 = switch (member.from) {
        .own => @intCast(own.len),
        .added => @intCast(outer.params.len + own.len),
        .default => 0,
    };
    if (own_n == 0 and member.from != .default) return null;
    var inst: FnInstance = .{
        .name = "",
        .params = try std.mem.concat(a, SymbolId, &.{ outer.params, own }),
        .args = try std.mem.concat(a, TypeId, &.{ outer.args, call.args }),
        .own = own_n,
    };
    if (mode != .over_params and ctx.fn_instance_set.contains(inst)) return null;
    // An addition's instance is named by its type's arguments, which are
    // the addition's: `List[Float].first`, `Map[Int, Int].look[Float]`.
    const shown = try formatType(ctx, call.recv);
    const base = if (member.from == .added) shown else shown[0 .. std.mem.findScalar(u8, shown, '[') orelse shown.len];
    inst.name = try a.print("{s}.{s}", .{ base, call.method });
    if (member.from == .added) inst.shown = @intCast(own.len);
    return inst;
}

/// `implInstance` found no method where the conformance's witness names
/// one, `why`: a compiler bug, which a self-checking build reports at
/// `site` rather than skip checking what the call reaches. After another
/// error (a conformance rejected, say) it may be that error's doing.
fn implLost(ctx: *SemContext, call: ApiCall, site: u32, why: []const u8) std.mem.Allocator.Error!?FnInstance {
    if ((@import("build_options").self_check or zig_builtin.is_test) and !ctx.hasErrors())
        try ctx.err(site, "internal error: the call of `{s}` through an API reaches no instance of its implementation: {s}", .{ call.method, why });
    return null;
}

/// A method a type declares, as a call reaches it: its signature at the
/// type's arguments, those arguments, the field, the declaring type, and
/// the module that declares it (null for this one or a proxy's).
pub const TypeMethod = struct { field: Field, fn_ty: FunctionType, subst: TypeSubst, owner: Symbol, module: ?u32 };

/// The method `name` that `ty`, an `obj` or an `enum` a module declares,
/// declares itself; null when it declares none.
pub fn typeMethod(ctx: *SemContext, ty: TypeId, name: []const u8) std.mem.Allocator.Error!?TypeMethod {
    if (try lookupMethod(ctx, ty, name)) |m| return .{ .field = m.field, .fn_ty = m.fn_ty, .subst = m.subst, .owner = ctx.symbols.items[m.nominal_sym], .module = null };
    const decl = nominalDecl(ctx, ty) orelse return null;
    const module_id = decl.module_id orelse return null;
    const foreign = ctx.foreign_semas.get(module_id) orelse return null;
    const fields = decl.symbol().fields orelse &.{};
    const f = fields[(try findMember(ctx, fields, name, .method)) orelse return null];
    const fty = ctx.types.get(try importType(ctx, foreign, f.ty, module_id));
    if (fty != .function) return null;
    return .{ .field = f, .fn_ty = fty.function, .subst = .empty, .owner = decl.symbol(), .module = module_id };
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
        const self_ty: ?TypeId = if (sym.kind == .generic_type) (try makeNominalContext(ctx, @intCast(i))).self_type else null;
        const own = if (self_ty) |st| typeItem(ctx, st) else null;
        if (own) |subst| try work.append(ctx.allocator, .{ .subst = subst, .site = sym.decl_pos, .root = .{ .type = self_ty.? }, .of_type = true });
        for (sym.fields orelse &.{}) |f| {
            if (!f.is_method) continue;
            if (try selfSeed(ctx, f.name, outer, f.ty, f.decl_pos)) |item| {
                try work.append(ctx.allocator, item);
            } else if (own) |subst| {
                // A method of the type at its own parameters, by its body:
                // what it spells, and the methods it reaches.
                const fun: FnRef = .{ .module = ctx.module_id, .pos = f.decl_pos };
                try reached.bodies.put(ctx.allocator, .{ .fun = fun, .recv = self_ty.? }, {});
                try work.append(ctx.allocator, .{ .subst = subst, .site = f.decl_pos, .root = .{ .type = self_ty.? }, .body = fun });
            }
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
    // A default reached through an API binds only its `Self` (`implInstance`).
    const n = inst.shown orelse inst.own;
    if (n == 0) return inst.name;
    return a.print("{s}[{s}]", .{ inst.name, try formatTypeList(ctx, a, inst.args[inst.args.len - n ..]) });
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
    /// Holds a `Cell` inline, directly or through an argument of a
    /// generic instance it holds that the generic holds by value
    /// (`held`).
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
    /// Holds a vector inline, directly or through an argument of a
    /// generic instance it holds by value (`held`).
    vector: bool = false,
    /// Holds an `error` inline, as `vector` reaches (see `moves`).
    any_error: bool = false,
};

/// Whether values hold a marked view (`?T`, `!T`, a slice), whether they
/// hold a write view (`!T`), and whether they hold a `?String`, which may
/// view a String, directly or through an optional, array, field, variant
/// payload, shared or weak handle, or any argument of a generic
/// instance. What a Cell or Signal holds holds no view. A `?String` is no
/// marked view to the type rules (`holdsMarkedView`); the ownership checker
/// follows the loans its values carry (`mayHoldView`).
pub const Views = packed struct(u4) {
    marked: bool = false,
    write: bool = false,
    string_view: bool = false,
    /// Reaches a String, which a `?String` may view: by value, through a
    /// handle, a List's, box's, Cell's, or Signal's value, or a view.
    string: bool = false,
};

/// Facts about an interned type, recorded when it is interned
/// (`SemContext.intern`). The structural facts are always known; the
/// rest once declarations are resolved (`SemContext.contents_ready`).
pub const TypeInfo = packed struct(u30) {
    /// Mentions a generic parameter anywhere.
    has_type_var: bool = false,
    /// Is or mentions an API object anywhere, `{Shape}` (`mentionsObject`).
    object: bool = false,
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
    /// Is or holds inline a vector (see `holdsVector`).
    vector: bool = false,
    /// Is or holds inline an `error`, an error of any set, which is
    /// owning whatever the program's sets hold (see `moves`).
    any_error: bool = false,
    /// How deeply wrappers and generic instances nest in it (saturating).
    depth: u8 = 0,
    /// How deeply every type built from others nests in it, a function's
    /// parameters and result too (saturating): what a walk over the type's
    /// structure nests (`max_alias_height`).
    height: u8 = 0,
};

/// How deeply the type a `type` alias names may nest (`TypeInfo.height`).
/// A type written out nests no deeper than its expression, which the
/// parser bounds; aliases, each naming the next, would nest one in another
/// without end, and every walk over a type's structure with them.
pub const max_alias_height = 200;

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

/// Make the ownership facts of types known for a compile-time
/// function's body, which is checked before every declaration is
/// resolved (`resolve.ensureCtFun`). The body names only integers,
/// `Bool`, and plain enums (`cteval.checkNames`), whose variants are
/// resolved by then (`resolve.resolveVariantsEarly`), so every type the
/// window reaches is complete; a signature, which may name any type, is
/// resolved outside it (`resolve.ensureCtSig`). False when the facts are
/// known already; else `endEarlyContents` takes back everything the
/// window computed, to be computed again for every type.
pub fn beginEarlyContents(ctx: *SemContext) std.mem.Allocator.Error!bool {
    if (ctx.contents_ready) return false;
    ctx.ct.window.clearRetainingCapacity();
    for (ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind != .nominal_type or sym.fields == null or sym.contents.done or sym.decl_pos >= imported_decl_pos) continue;
        if (!isPlainEnum(ctx, try ctx.intern(.{ .nominal = @intCast(i) }))) continue;
        try symbolContents(ctx, @intCast(i));
        try ctx.ct.window.append(ctx.allocator, @intCast(i));
    }
    ctx.contents_ready = true;
    ctx.ct.window_open = true;
    ctx.type_info.clearRetainingCapacity();
    try ctx.syncTypeInfo();
    return true;
}

pub fn endEarlyContents(ctx: *SemContext) std.mem.Allocator.Error!void {
    for (ctx.ct.window.items) |id| ctx.symbols.items[id].contents = .{};
    ctx.ct.window.clearRetainingCapacity();
    ctx.contents_ready = false;
    ctx.ct.window_open = false;
    ctx.type_info.clearRetainingCapacity();
    try ctx.syncTypeInfo();
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
            c.vector = c.vector or h.vector;
            c.any_error = c.any_error or h.any_error;
        }
    }
    // A union of error sets owns what its sets' members carry.
    for (ctx.symbols.items[id].error_parts orelse &.{}) |part| if (fieldsAt(ctx, part, 1)) {
        c.glue = true;
        c.plain = false;
    };
    // The built-in generics are runtime types: a List owns its buffer and
    // a box its value's memory, and none of them is copied like plain data.
    // A Signal owns its subscribers too, but has no glue of its own: it
    // lives only behind a `*` handle (typecheck rejects one held by
    // value), whose release drops it.
    // A task owns its running call, and its drop waits for it.
    // A table owns its slots' memory, and drops each slot.
    if (id == ctx.list_sym_id or id == ctx.box_sym_id or id == ctx.task_sym_id or id == ctx.tasks_sym_id or id == ctx.table_sym_id) c.glue = true;
    if (id == ctx.list_sym_id or id == ctx.box_sym_id or id == ctx.table_sym_id or id == ctx.cell_sym_id or id == ctx.signal_sym_id or id == ctx.actor_sym_id or id == ctx.chan_sym_id or id == ctx.frozen_sym_id or id == ctx.task_sym_id or id == ctx.tasks_sym_id) c.plain = false;
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

const Holds = struct { glue: bool = false, plain: bool = false, type_var: bool = false, vector: bool = false, any_error: bool = false };

/// What a value of `ty` holds. `ty` is a field type of a generic type
/// whose parameters are `params` (empty elsewhere): each parameter it
/// holds by value is marked in `held` and counts as plain.
fn holdsIn(ctx: *SemContext, ty: TypeId, params: []const SymbolId, held: []bool) std.mem.Allocator.Error!Holds {
    if (params.len == 0 and ctx.contents_ready and ty < ctx.type_info.items.len) {
        const info = ctx.type_info.items[ty];
        return .{ .glue = info.glue, .plain = info.plain, .type_var = info.holds_type_var, .vector = info.vector, .any_error = info.any_error };
    }
    return switch (ctx.types.get(ty)) {
        .bool, .int, .float, .string_view, .static, .symbol, .ct_value, .ct_param, .slot => .{ .plain = true },
        .string => .{ .glue = true },
        // An error of any set is owning in every program, whatever the
        // program's sets hold (Core §2, "A failure moves its error").
        .any_error => .{ .glue = true, .any_error = true },
        .optional => |inner| holdsIn(ctx, inner, params, held),
        .array => |a| holdsIn(ctx, a.elem, params, held),
        // Lanes of a number or `Bool`: one plain value.
        .simd => .{ .plain = true, .vector = true },
        .fallible => |f| blk: {
            const h = try holdsIn(ctx, f.ok, params, held);
            break :blk .{ .type_var = h.type_var, .vector = h.vector };
        },
        .shared, .weak => .{ .glue = true },
        // An API object's type is erased, so it may hold anything, and
        // its drop runs through its table (docs/design/apis.md, Stage 4).
        .api_object => .{ .glue = true },
        .nominal, .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk .{};
            const c = contentsOf(decl.ctx, decl.sym);
            break :blk .{ .glue = c.glue, .plain = c.plain, .vector = c.vector, .any_error = c.any_error };
        },
        // A set parameter's value is an error, whatever set binds it.
        .type_var => |sym| blk: {
            if (ctx.symbols.items[sym].flags.set_param) break :blk .{ .glue = true, .any_error = true };
            const i = std.mem.findScalar(SymbolId, params, sym) orelse break :blk .{ .type_var = true };
            held[i] = true;
            break :blk .{ .plain = true, .type_var = true };
        },
        .parameterized_nominal => |pn| blk: {
            const c = contentsOf(ctx, pn.sym);
            var h: Holds = .{ .glue = c.glue, .plain = c.plain, .vector = c.vector, .any_error = c.any_error };
            for (pn.args, 0..) |a, i| {
                if (i >= c.held.len or !c.held[i]) continue;
                const arg = try holdsIn(ctx, a, params, held);
                h.glue = h.glue or arg.glue;
                h.plain = h.plain and arg.plain;
                h.type_var = h.type_var or arg.type_var;
                h.vector = h.vector or arg.vector;
                h.any_error = h.any_error or arg.any_error;
            }
            break :blk h;
        },
        // Several results hold what each of them holds, as an object
        // holds what its fields do.
        .results => |parts| blk: {
            var h: Holds = .{ .plain = true };
            for (parts) |part| {
                const r = try holdsIn(ctx, part, params, held);
                h.glue = h.glue or r.glue;
                h.plain = h.plain and r.plain;
                h.type_var = h.type_var or r.type_var;
                h.vector = h.vector or r.vector;
                h.any_error = h.any_error or r.any_error;
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

    const all: Reach = .{ .cell = true, .unique = true, .views = .{ .marked = true, .write = true, .string_view = true, .string = true } };
    /// What reaches through a handle or heap memory: no Cell or unique
    /// value is inline.
    const views_only: Reach = .{ .views = .{ .marked = true, .write = true, .string_view = true, .string = true } };
    /// What reaches through a view, or into a Cell's or Signal's value:
    /// only a String matters.
    const string_only: Reach = .{ .views = .{ .string = true } };
    /// What reaches through a type argument a generic holds only behind
    /// a handle, a view, or heap memory: everything but an inline Cell.
    const no_cell: Reach = .{ .unique = true, .views = .{ .marked = true, .write = true, .string_view = true, .string = true } };

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
/// reach: through a handle, or a List's or a box's heap memory, only a
/// view does, and a Cell's or Signal's value holds nothing that
/// matters here. What a declared type `ty` names holds is read from its
/// contents; while they are computed (`computeReach`), an edge from it
/// to `into.owner` is added instead.
fn reachOf(ctx: *const SemContext, ty: TypeId, mask: Reach, into: ?struct { edges: *std.ArrayList(ReachEdge), owner: SymbolId }) std.mem.Allocator.Error!Reach {
    const r: Reach = switch (ctx.types.get(ty)) {
        .slice => .{ .views = .{ .marked = true } },
        .read_view => |inner| (Reach{ .views = .{ .marked = true } }).with(try reachOf(ctx, inner, mask.within(Reach.string_only), into)),
        .write_view => |inner| (Reach{ .views = .{ .marked = true, .write = true } }).with(try reachOf(ctx, inner, mask.within(Reach.string_only), into)),
        .string_view => .{ .views = .{ .string_view = true } },
        .string => .{ .views = .{ .string = true } },
        // An API object may hold anything its erased type held: a view,
        // text, a Cell, a unique value. No type holds a write view but
        // a write view itself.
        // One whose braces or API name `Owned` holds no loan, which its
        // erasure checks on the value's type.
        .api_object => |o| if (objectBounds(ctx, o).contains(.Owned)) .{ .cell = true, .unique = true, .views = .{ .string = true } } else .{ .cell = true, .unique = true, .views = .{ .marked = true, .string_view = true, .string = true } },
        .optional => |inner| return reachOf(ctx, inner, mask, into),
        .fallible => |inner| return reachOf(ctx, inner.ok, mask, into),
        .array => |a| return reachOf(ctx, a.elem, mask, into),
        // A `*{A + Syncs}` holds a frozen value, which holds no view.
        .shared, .weak => |inner| return if (frozenObject(ctx, inner)) .{} else reachOf(ctx, inner, mask.within(Reach.views_only), into),
        .nominal => |sym| blk: {
            const e = into orelse break :blk Reach.of(ctx.symbols.items[sym].contents);
            try e.edges.append(ctx.allocator, .{ .from = sym, .to = e.owner, .mask = mask });
            break :blk .{};
        },
        .imported_nominal => Reach.of((nominalDecl(ctx, ty) orelse return .{}).symbol().contents),
        .parameterized_nominal => |pn| blk: {
            // A task keeps the loans of its call's arguments, which its
            // type does not name, so it may always hold a view: a shared
            // home never holds one (docs/design/concurrency.md, "Loans and
            // structure"). Its loans are never write views by type: a
            // task lent to write stays where it is bound. A set of tasks
            // keeps the loans of each.
            if (pn.sym == ctx.task_sym_id or pn.sym == ctx.tasks_sym_id) {
                var r: Reach = .{ .unique = true, .views = .{ .marked = true } };
                for (pn.args) |a| r = r.with(try reachOf(ctx, a, mask, into));
                break :blk r;
            }
            // An actor, as a Cell, lives only behind `*` and changes by a
            // marked call through a handle.
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id) {
                var r: Reach = .{ .cell = pn.sym == ctx.cell_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id };
                for (pn.args) |a| r = r.with(try reachOf(ctx, a, mask.within(Reach.string_only), into));
                break :blk r;
            }
            const m = if (isHeapBuiltin(ctx, pn.sym)) mask.within(Reach.views_only) else mask;
            var r: Reach = .{};
            if (into) |e| {
                try e.edges.append(ctx.allocator, .{ .from = pn.sym, .to = e.owner, .mask = m });
            } else r = Reach.of(ctx.symbols.items[pn.sym].contents);
            // A Cell an argument holds is inline only where the generic
            // holds that parameter by value (`Contents.held`, the rule
            // `holdsIn` follows), not behind a handle, a view, or a
            // container's heap memory.
            const held = contentsOf(ctx, pn.sym).held;
            for (pn.args, 0..) |a, i| {
                const by_value = i < held.len and held[i];
                r = r.with(try reachOf(ctx, a, if (by_value) m else m.within(Reach.no_cell), into));
            }
            break :blk r;
        },
        .results => |parts| blk: {
            var r: Reach = .{};
            for (parts) |part| r = r.with(try reachOf(ctx, part, mask, into));
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
    var info: TypeInfo = .{ .has_type_var = ty == .type_var or ty == .ct_param, .object = ty == .api_object, .poison = ty == .invalid or ty == .unknown };
    var deepest: ?u8 = null;
    var highest: ?u8 = null;
    var it: TypeChildren = .{ .ty = ty };
    while (it.next()) |c| {
        const ci = ctx.type_info.items[c];
        info.has_type_var = info.has_type_var or ci.has_type_var;
        info.object = info.object or ci.object;
        info.poison = info.poison or ci.poison;
        deepest = @max(deepest orelse 0, ci.depth);
        highest = @max(highest orelse 0, ci.height);
    }
    info.depth = switch (ty) {
        .function => 0,
        .parameterized_nominal => (deepest orelse 0) +| 1,
        else => if (deepest) |d| d +| 1 else 0,
    };
    info.height = if (highest) |h| h +| 1 else 0;
    if (!ctx.contents_ready) return info;
    var no_params: [0]bool = .{};
    const h = try holdsIn(ctx, id, &.{}, &no_params);
    info.glue = h.glue;
    info.plain = h.plain;
    info.holds_type_var = h.type_var;
    info.vector = h.vector;
    info.any_error = h.any_error;
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
/// arguments, and a List or a box its element.
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
        .fallible => |inner| inner.ok == ctx.types.void_id,
        else => false,
    };
}

/// A built-in function called by name unless a declaration hides it:
/// `print`, `warn`, and `swap`.
pub fn isBuiltinCallName(name: []const u8) bool {
    return std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "warn") or std.mem.eql(u8, name, "swap");
}

/// Whether the built-in `swap`'s second argument `arg`, of type `ty`
/// where known, is a second place lent to write, `!b` or a held `!T`: the
/// call exchanges two places. Otherwise it is a value the call puts in
/// the first place, giving back what was there.
pub fn swapsTwoPlaces(ctx: *const SemContext, arg: Sexp, ty: ?TypeId) bool {
    if (arg.isKind(.write)) return true;
    const t = ty orelse return false;
    return ctx.types.get(t) == .write_view;
}

/// A built-in generic that keeps its values on the heap: a `List[T]` and
/// a `^T` hold a pointer, whatever `T` is. (A `Cell[T]` holds its
/// `T` inline, and a `Signal[T]` its value and a pending one.)
fn isHeapBuiltin(ctx: *const SemContext, sym: SymbolId) bool {
    return sym == ctx.list_sym_id or sym == ctx.box_sym_id or sym == ctx.table_sym_id;
}

/// The declared types a value of `ty` holds inline (not behind a handle,
/// a view, or a List's or a box's heap memory), appended to `out`; with
/// `every_arg`, those of every argument of a generic instance as well.
fn byValueTargets(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), every_arg: bool) std.mem.Allocator.Error!void {
    switch (ctx.types.get(ty)) {
        .optional => |inner| try byValueTargets(ctx, inner, out, every_arg),
        .fallible => |inner| try byValueTargets(ctx, inner.ok, out, every_arg),
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
/// fallible's value then its set, a slice's element, an array's element
/// then its length, a function's
/// parameters then its return type, a generic instance's arguments.
pub const TypeChildren = struct {
    ty: Type,
    i: usize = 0,

    pub fn next(self: *TypeChildren) ?TypeId {
        const i = self.i;
        self.i += 1;
        return switch (self.ty) {
            .optional, .read_view, .write_view, .shared, .weak, .range, .callable => |inner| if (i == 0) inner else null,
            .fallible => |inner| if (i == 0) inner.ok else if (i == 1) inner.set else null,
            .slice => |s| if (i == 0) s.elem else null,
            .array => |a| if (i == 0) a.elem else if (i == 1) a.len else null,
            .simd => |v| if (i == 0) v.elem else if (i == 1) v.len else null,
            .slot => |n| if (i == 0) n else null,
            .function => |f| if (i < f.params.len) f.params[i] else if (i == f.params.len) f.returns else null,
            .parameterized_nominal => |pn| if (i < pn.args.len) pn.args[i] else null,
            .results => |parts| if (i < parts.len) parts[i] else null,
            else => null,
        };
    }
};

/// Whether a value of `ty` may hold a value of a type parameter: the
/// parameter itself, or a type built from it (`List[T]`, `T?`, `Bag[T]`),
/// but no function, and not a compile-time value (`Simd[U8, n]`).
pub fn holdsTypeParam(ctx: *const SemContext, ty: TypeId) bool {
    if (!ctx.typeInfo(ty).has_type_var) return false;
    const t = ctx.types.get(ty);
    switch (t) {
        // A set parameter's value is an error, whatever set binds it.
        .type_var => |sym| return !ctx.symbols.items[sym].flags.set_param,
        .function, .ct_param => return false,
        else => {},
    }
    var it: TypeChildren = .{ .ty = t };
    while (it.next()) |c| if (holdsTypeParam(ctx, c)) return true;
    return false;
}

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

/// A vector's lane count when it is a known count: a power of two from
/// 2 to 64 (`lanesInRange`); null for a compile-time parameter, whose
/// value each instance gives, and for a count out of range, which is
/// reported where it is written.
pub fn simdLen(ctx: *const SemContext, v: SimdType) ?u64 {
    return switch (ctx.types.get(v.len)) {
        .ct_value => |c| if (lanesInRange(c.int)) @intCast(c.int) else null,
        else => null,
    };
}

/// Whether `n` is a lane count: a power of two from 2 to 64, so every
/// mask fits a `U64` and every count fills whole registers.
pub fn lanesInRange(n: Wide) bool {
    return n >= 2 and n <= 64 and n & (n - 1) == 0;
}

/// Whether a lane may be of type `ty`: a number or `Bool`.
pub fn isLaneType(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int, .float, .bool => true,
        else => false,
    };
}

/// The vector `ty` is, through any views (`?v` reads as its value).
pub fn simdOf(ctx: *const SemContext, ty: TypeId) ?SimdType {
    return switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .simd => |v| v,
        else => null,
    };
}

/// Whether `ty` is a mask, `Simd[Bool, n]`, through any views.
pub fn isMask(ctx: *const SemContext, ty: TypeId) bool {
    const v = simdOf(ctx, ty) orelse return false;
    return v.elem == ctx.types.bool_id;
}

/// The most lanes a mask, `Simd[Bool, n]`, holds as a `@Vector(n, bool)`,
/// a bit a lane; a wider one is a `rig.WideMask(n)`, a byte a lane, which
/// LLVM keeps in vector registers across blocks (`rig.Mask` in
/// src/runtime.zig, which decides it as this does; `test "maskBytes:
/// the runtime's own size"`).
pub const max_bit_mask_lanes = 16;

/// The bytes of a mask of `n` lanes, as `rig.Mask(n)` holds it.
pub fn maskBytes(n: u64) u64 {
    return if (n > max_bit_mask_lanes) n else @max(1, n / 8);
}

/// The bytes a value of `ty` takes at least (padding aside), or null
/// when that depends on a generic parameter or follows an error, such as
/// holding a type reported too large.
pub fn minBytes(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?u128 {
    try sizeHeld(ctx, ty);
    return minBytesOf(ctx, ty, true);
}

/// A type `sizeHeld` sizes once the types it holds (`parts`, from `next`
/// on) are sized.
const SizePending = struct { ty: TypeId, parts: []const TypeId, next: usize = 0 };

/// Sizes the types `ty` holds before `ty`, deepest first, so that
/// `minBytesOf` finds each sized and does not nest through a chain of
/// types, each holding the next: a generic one's instances are sized
/// here, where `checkTypeSizes` sizes declared ones in order. The walk
/// keeps a stack of its own; a type met again on it, on a cycle, is
/// left to `minBytesOf`, which finds such a type no size.
fn sizeHeld(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!void {
    if (ctx.byte_sizes.contains(ty)) return;
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var open: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    var stack: std.ArrayList(SizePending) = .empty;
    try open.put(a, ty, {});
    try stack.append(a, .{ .ty = ty, .parts = try sizedParts(ctx, a, ty) });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next < top.parts.len) {
            const part = top.parts[top.next];
            top.next += 1;
            if (ctx.byte_sizes.contains(part) or ctx.oversized.contains(part)) continue;
            if ((try open.getOrPut(a, part)).found_existing) continue;
            try stack.append(a, .{ .ty = part, .parts = try sizedParts(ctx, a, part) });
            continue;
        }
        const done = stack.pop().?.ty;
        if (done != ty) _ = try minBytesOf(ctx, done, false);
    }
}

/// The types `minBytesOf` sizes `ty` from: an optional's, array's, or
/// vector's element, a Signal's value, and the fields and payloads of a
/// declared type or a generic instance, in it.
fn sizedParts(ctx: *SemContext, a: std.mem.Allocator, ty: TypeId) std.mem.Allocator.Error![]const TypeId {
    var out: std.ArrayList(TypeId) = .empty;
    const fieldsOf = struct {
        fn add(c: *SemContext, al: std.mem.Allocator, list: *std.ArrayList(TypeId), sym: SymbolId, subst: TypeSubst) std.mem.Allocator.Error!void {
            if (c.symbols.items[sym].contents.cyclic) return;
            for (c.symbols.items[sym].fields orelse &.{}) |f| {
                if (f.is_method or f.is_drop_method) continue;
                if (f.is_variant) {
                    for (f.payload orelse &.{}) |p| try list.append(al, try substituteType(c, p.ty, subst));
                } else try list.append(al, try substituteType(c, f.ty, subst));
            }
        }
    }.add;
    switch (ctx.types.get(ty)) {
        .optional => |inner| try out.append(a, inner),
        .array => |arr| try out.append(a, arr.elem),
        .simd => |v| try out.append(a, v.elem),
        .nominal => |sym| try fieldsOf(ctx, a, &out, sym, .empty),
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id or pn.sym == ctx.box_sym_id or pn.sym == ctx.table_sym_id) {
            // A List, a table, and a box are sized without what they hold.
        } else if (pn.sym == ctx.signal_sym_id) {
            try out.append(a, pn.args[0]);
        } else try fieldsOf(ctx, a, &out, pn.sym, .{ .params = ctx.symbols.items[pn.sym].type_params orelse &.{}, .args = pn.args }),
        else => {},
    }
    return out.items;
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
        .symbol => 4,
        .slot => |n| if (slotCount(ctx, n)) |c| slotBytes(c) else null,
        .int => |i| i.width() / 8,
        .float => |f| if (f.bits == 0) 8 else f.bits / 8,
        .string_view, .static, .slice => 16,
        .string => 24,
        .any_error => 2,
        // A null handle or view is its null address; anything else
        // needs a flag.
        .optional => |inner| if (try minBytesOf(ctx, inner, false)) |b| b +| @intFromBool(!isAddress(ctx, inner)) else null,
        .array => |a| blk: {
            const n = arrayLen(ctx, a) orelse break :blk null;
            const e = (try minBytesOf(ctx, a.elem, false)) orelse break :blk null;
            break :blk std.math.mul(u128, n, e) catch std.math.maxInt(u128);
        },
        // Zig's own size: a lane each. A mask is `rig.Mask(n)`: up to
        // `max_bit_mask_lanes` a bool vector, its lanes a bit each, and
        // above a byte each (`maskBytes`).
        .simd => |v| blk: {
            const n = simdLen(ctx, v) orelse break :blk null;
            if (v.elem == ctx.types.bool_id) break :blk maskBytes(n);
            const e = (try minBytesOf(ctx, v.elem, false)) orelse break :blk null;
            break :blk n * e;
        },
        .nominal => |sym| try fieldBytes(ctx, sym, .empty),
        // Sized where it is declared (`checkTypeSizes`).
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk null;
            const declared = foreign.types.find(.{ .nominal = in.sym_id }) orelse break :blk null;
            break :blk foreign.byte_sizes.get(declared) orelse null;
        },
        // A List is its buffer's slice and length, a box its pointer. A
        // Cell is its value (its one field), a Signal its value, a pending
        // one, a flag, and a List of subscribers.
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id)
            24
        else if (pn.sym == ctx.table_sym_id)
            16
        else if (pn.sym == ctx.box_sym_id)
            8
        else if (pn.sym == ctx.signal_sym_id) blk: {
            const v = (try minBytesOf(ctx, pn.args[0], false)) orelse break :blk null;
            break :blk 2 *| v +| 2 +| 24;
        } else try fieldBytes(ctx, pn.sym, .{ .params = ctx.symbols.items[pn.sym].type_params orelse &.{}, .args = pn.args }),
        // Several results are held together, as an object's fields are.
        .results => |parts| blk: {
            var total: u128 = 0;
            for (parts) |part| total +|= (try minBytesOf(ctx, part, false)) orelse break :blk null;
            break :blk total;
        },
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
        .shared, .weak, .read_view, .write_view, .string_view, .static, .slice => true,
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
    try ctx.err(pos, "`{s}` takes {d} bytes; a value takes at most {d} (8 MiB), since it may live on the stack. Keep larger data in a `List`", .{ try formatType(ctx, ty), bytes, max_value_bytes });
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

/// Every declared struct and enum must fit `max_value_bytes` and nest
/// at most `max_value_depth` deep; a generic one is checked at each
/// instance. Each is sized after the types it holds (`order`, from
/// `computeContents`), so sizing one does not nest through the chain of
/// types it holds.
fn checkTypeSizes(ctx: *SemContext, order: []const SymbolId) std.mem.Allocator.Error!void {
    for (order) |id| {
        const sym = ctx.symbols.items[id];
        if (sym.kind != .nominal_type or sym.decl_pos >= imported_decl_pos) continue;
        const ty = try ctx.intern(.{ .nominal = id });
        if (try oversizedByItself(ctx, ty, id, .empty)) |bytes| {
            try reportOversized(ctx, sym.decl_pos, ty, bytes);
        } else if (try tooDeepByItself(ctx, ty, id, .empty)) |depth| try reportTooDeep(ctx, sym.decl_pos, ty, depth);
    }
}

/// How many levels `ty` nests by value: 0 for a type holding nothing by
/// value (a number, a String, a List, a box, a handle), and one more than
/// its deepest part for an optional, an array, a vector, a Signal, or an
/// object or enum (`sizedParts`). The parts are measured first, deepest
/// first, on a stack of the walk's own, as `sizeHeld` sizes them; a type
/// that holds itself (rejected) counts no part twice.
pub fn valueDepth(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!u32 {
    if (ctx.value_depths.get(ty)) |d| return d;
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var open: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    var stack: std.ArrayList(SizePending) = .empty;
    try open.put(a, ty, {});
    try stack.append(a, .{ .ty = ty, .parts = try sizedParts(ctx, a, ty) });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next < top.parts.len) {
            const part = top.parts[top.next];
            top.next += 1;
            if (ctx.value_depths.contains(part)) continue;
            if ((try open.getOrPut(a, part)).found_existing) continue;
            try stack.append(a, .{ .ty = part, .parts = try sizedParts(ctx, a, part) });
            continue;
        }
        const done = stack.pop().?;
        var deepest: u32 = 0;
        for (done.parts) |part| deepest = @max(deepest, ctx.value_depths.get(part) orelse 0);
        const depth: u32 = switch (ctx.types.get(done.ty)) {
            .optional, .array, .simd, .nominal => deepest +| 1,
            // A List, a table, and a box hold their elements apart.
            .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id or pn.sym == ctx.box_sym_id or pn.sym == ctx.table_sym_id) 0 else deepest +| 1,
            // Measured where it is declared (`checkTypeSizes`).
            .imported_nominal => |in| blk: {
                const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk 1;
                const declared = foreign.types.find(.{ .nominal = in.sym_id }) orelse break :blk 1;
                break :blk foreign.value_depths.get(declared) orelse 1;
            },
            else => 0,
        };
        try ctx.value_depths.put(ctx.allocator, done.ty, depth);
    }
    return ctx.value_depths.get(ty).?;
}

/// Whether `ty` (a struct, an enum, or a generic type's instance under
/// `subst`) nests too deep by itself: more than `max_value_depth` levels
/// (`valueDepth`), when no type it holds does, which is reported on its
/// own. Its depth, when it is.
pub fn tooDeepByItself(ctx: *SemContext, ty: TypeId, sym: SymbolId, subst: TypeSubst) std.mem.Allocator.Error!?u32 {
    const depth = try valueDepth(ctx, ty);
    if (depth <= max_value_depth) return null;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| for (dataFields(f)) |d| {
        if (try valueDepth(ctx, try substituteType(ctx, d.ty, subst)) > max_value_depth) return null;
    };
    return depth;
}

/// Report that `ty` nests `depth` levels by value, more than
/// `max_value_depth`.
pub fn reportTooDeep(ctx: *SemContext, pos: u32, ty: TypeId, depth: u32) std.mem.Allocator.Error!void {
    try ctx.oversized.put(ctx.allocator, ty, {});
    try ctx.err(pos, "`{s}` nests {d} types deep by value; a value nests at most {d} deep. Hold a part in a box (`^T`) or a `List`", .{ try formatType(ctx, ty), depth, max_value_depth });
}

/// The `ct_value` of the integer `v`.
pub fn ctInt(ctx: *SemContext, v: Wide) std.mem.Allocator.Error!TypeId {
    return ctx.intern(.{ .ct_value = .{ .int = v } });
}

/// Does a value of this type need its destructor run: a `*T` / `~T`
/// handle, a List, a box, an owned closure, or a nominal or generic instance
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

/// The function type a call of a value of type `ty` follows: that of a
/// callable view, an owned closure, or a function, or of a view of one.
/// The checker checks the call's arguments against it, and emit reads
/// the same parameters.
pub fn calledFn(ctx: *const SemContext, ty: TypeId) ?FunctionType {
    return callableFn(ctx, ty) orelse ownedClosureFn(ctx, ty) orelse switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .function => |f| f,
        else => null,
    };
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
        .read_view, .write_view, .optional, .shared, .weak => |inner| return holdsCallable(ctx, inner),
        .fallible => |inner| return holdsCallable(ctx, inner.ok),
        .slice => |sl| return holdsCallable(ctx, sl.elem),
        .array => |a| return holdsCallable(ctx, a.elem),
        .parameterized_nominal => |pn| for (pn.args) |a| {
            if (holdsCallable(ctx, a)) return true;
        },
        else => {},
    }
    return false;
}

/// The hint for a name that likely means a built-in type: how that type
/// is written. Null for any other name.
pub fn builtinNameHint(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Text")) return "; owned text is `String`, and its read view is `?String`";
    if (std.mem.eql(u8, name, "Vec")) return "; a growable array is `List[T]`";
    if (std.mem.eql(u8, name, "Box")) return "; a box is written `^T` as a type and `^value` as an expression";
    return null;
}

/// Whether a holding sigil (`^` or `*`) over `inner` holds a value that
/// is already held on the heap, directly or inside an optional: `^^T`,
/// `^*T`, `^~T`, `*^T`, `**T`, and `*~T`, and `*(~T?)` or `^(*T?)`. A
/// value is held one way on the heap, so a second sigil is a typo.
pub fn heapStacked(ctx: *const SemContext, inner: TypeId) bool {
    const held = unwrapOptionals(ctx, inner);
    if (boxedType(ctx, held) != null) return true;
    return switch (ctx.types.get(held)) {
        .shared, .weak => true,
        else => false,
    };
}

/// `ty` with every optional around it peeled: `T` of `T?` or `(T?)?`.
pub fn unwrapOptionals(ctx: *const SemContext, ty: TypeId) TypeId {
    var t = ty;
    while (true) switch (ctx.types.get(t)) {
        .optional => |inner| t = inner,
        else => return t,
    };
}

/// Why a holding sigil over a held value is rejected.
pub const heap_stacked_rule = "a value is held one way on the heap, as `^T` (one owner), `*T` (counted), or `~T` (weak)";

/// The diagnostic for a holding sigil over a held value, given the type
/// it would make.
pub const heap_stacked = "`{s}` stacks one heap holding on another; " ++ heap_stacked_rule;

/// The diagnostic for a box of a function value.
pub const boxed_function = "`^` boxes a value; a function has no box (`^fun` is reserved), so pass the function, or own a closure with `*|...| body`";

/// The first type among `ty` and the types it is made of that stacks
/// two holdings (`heapStacked`), or null.
pub fn findHeapStacked(ctx: *const SemContext, ty: TypeId) ?TypeId {
    switch (ctx.types.get(ty)) {
        .shared => |inner| return if (heapStacked(ctx, inner)) ty else findHeapStacked(ctx, inner),
        .weak, .read_view, .write_view, .optional, .range, .callable => |inner| return findHeapStacked(ctx, inner),
        .fallible => |inner| return findHeapStacked(ctx, inner.ok),
        .slice => |s| return findHeapStacked(ctx, s.elem),
        .array => |a| return findHeapStacked(ctx, a.elem),
        .function => |f| {
            for (f.params) |p| if (findHeapStacked(ctx, p)) |found| return found;
            return findHeapStacked(ctx, f.returns);
        },
        .parameterized_nominal => |pn| {
            if (pn.sym == ctx.box_sym_id and pn.args.len == 1 and heapStacked(ctx, pn.args[0])) return ty;
            for (pn.args) |a| if (findHeapStacked(ctx, a)) |found| return found;
            return null;
        },
        else => return null,
    }
}

/// The first stacked holding (`findHeapStacked`) among the fields and
/// methods of generic type `inst`, an instance of a type the program
/// declares, with its type arguments substituted; null for none.
pub fn instanceHeapStacked(ctx: *SemContext, inst: TypeId) std.mem.Allocator.Error!?TypeId {
    const pn = switch (ctx.types.get(inst)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    const sym = ctx.symbols.items[pn.sym];
    if (sym.decl_pos == builtin_decl_pos) return null;
    const subst: TypeSubst = .{ .params = sym.type_params orelse return null, .args = pn.args };
    for (sym.fields orelse &.{}) |f| {
        if (f.ty != type_invalid) if (findHeapStacked(ctx, try substituteType(ctx, f.ty, subst))) |found| return found;
        for (f.payload orelse &.{}) |pf| {
            if (pf.ty != type_invalid) if (findHeapStacked(ctx, try substituteType(ctx, pf.ty, subst))) |found| return found;
        }
    }
    return null;
}

/// Report generic instance `inst`, made at `pos`, if a field of it stacks
/// one heap holding on another (`instanceHeapStacked`): the one check of
/// every instance the program makes, written, made in an expression, or
/// reached through a generic body.
pub fn checkInstanceStacked(ctx: *SemContext, inst: TypeId, pos: u32) std.mem.Allocator.Error!void {
    const found = (try instanceHeapStacked(ctx, inst)) orelse return;
    try ctx.err(pos, "`{s}` holds `{s}`, which stacks one heap holding on another; " ++ heap_stacked_rule, .{ try formatType(ctx, inst), try formatType(ctx, found) });
}

/// The diagnostic for a callable view held inside another value.
pub const held_callable = "a callable view `{s}` is only a parameter's, a local's, or a result's type; no value can hold one";

/// A value of an error set, or any error: what a fallible function
/// fails with.
pub fn isErrorValue(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.types.get(ty) == .any_error or isErrorSet(ctx, ty) or isSetParam(ctx, ty);
}

/// Whether `ty` is a function's set parameter (`SymbolFlags.set_param`):
/// an error of a set its caller names, which only that set and `error`
/// hold.
pub fn isSetParam(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .type_var => |sym| ctx.symbols.items[sym].flags.set_param,
        else => false,
    };
}

/// Whether error set `set` holds `task.Stop`, `std.task`'s set, which
/// every wait may also fail with: `error` does, and a declared set or
/// union does when it joins it.
pub fn setHoldsStop(ctx: *const SemContext, set: TypeId, a: std.mem.Allocator) std.mem.Allocator.Error!bool {
    if (set == type_any_error) return true;
    var leaves: std.ArrayList(SetKey) = .empty;
    try errorSetLeaves(ctx, set, &leaves, a);
    for (leaves.items) |leaf| {
        if (std.mem.eql(u8, leaf.ctx.name, "std.task") and std.mem.eql(u8, leaf.ctx.symbols.items[leaf.sym].name, "Stop")) return true;
    }
    return false;
}

/// Whether error set `ty`, a set or a union, has a member with fields:
/// a value of it carries them (errors-spec §7.2).
pub fn setHasFields(ctx: *const SemContext, ty: TypeId) bool {
    return fieldsAt(ctx, ty, 0);
}

/// Whether a value of `ty` is a `rig.ErrorValue`, an error's code with
/// room for its fields: `error`, a function's set parameter, or a set
/// with a member with fields. A view of one is a pointer to it, not one.
pub fn isErrorValueForm(ctx: *const SemContext, ty: TypeId) bool {
    if (ctx.types.get(ty) == .any_error or isSetParam(ctx, ty)) return true;
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => false,
        else => setHasFields(ctx, ty),
    };
}

fn fieldsAt(ctx: *const SemContext, ty: TypeId, depth: u32) bool {
    if (depth > union_depth) return false;
    const d = nominalDecl(ctx, ty) orelse return false;
    const sym = d.symbol();
    if (!sym.flags.error_set) return false;
    if (sym.error_parts) |parts| {
        for (parts) |part| if (fieldsAt(d.ctx, part, depth + 1)) return true;
        return false;
    }
    for (sym.fields orelse &.{}) |f| {
        if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
    }
    return false;
}

/// Whether any error set this module declares has a member with fields.
pub fn declaresErrorFields(ctx: *const SemContext) bool {
    for (ctx.symbols.items) |sym| {
        if (!sym.flags.error_set or sym.error_parts != null or isProxy(sym)) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
        }
    }
    return false;
}

/// Whether a value of `ty` holds a shared or weak handle (`*T`, `~T`)
/// anywhere inside it: what an error's field may not (errors-spec §4.1).
pub fn holdsHandle(ctx: *const SemContext, ty: TypeId) bool {
    return handleAt(ctx, ty, null);
}

/// The declared types a walk is inside, each in the module whose type it
/// is, nearest first: one met again is on a cycle, through a box or a
/// List, and adds nothing.
const TypePath = struct { ctx: *const SemContext, ty: TypeId, up: ?*const TypePath };

fn handleAt(ctx: *const SemContext, ty: TypeId, path: ?*const TypePath) bool {
    return switch (ctx.types.get(ty)) {
        // An API object's hidden value may hold one (Core §4).
        .shared, .weak, .api_object => true,
        .optional, .read_view, .write_view, .range, .callable => |inner| handleAt(ctx, inner, path),
        .fallible => |f| handleAt(ctx, f.ok, path),
        .array => |a| handleAt(ctx, a.elem, path),
        .slice => |s| handleAt(ctx, s.elem, path),
        .parameterized_nominal => |pn| blk: {
            for (pn.args) |arg| if (handleAt(ctx, arg, path)) break :blk true;
            break :blk fieldsHoldHandle(ctx, ty, path);
        },
        .nominal, .imported_nominal => fieldsHoldHandle(ctx, ty, path),
        else => false,
    };
}

fn fieldsHoldHandle(ctx: *const SemContext, ty: TypeId, path: ?*const TypePath) bool {
    var at = path;
    while (at) |p| : (at = p.up) if (p.ctx == ctx and p.ty == ty) return false;
    const inner: TypePath = .{ .ctx = ctx, .ty = ty, .up = path };
    const d = nominalDecl(ctx, ty) orelse return false;
    for (d.symbol().fields orelse &.{}) |*f| {
        if (f.is_method) continue;
        for (dataFields(f)) |field| if (handleAt(d.ctx, field.ty, &inner)) return true;
    }
    return false;
}

/// Whether function type `f` is lent where function type `want` goes:
/// the same, or with the same parameters and a result `T!A` where
/// `want`'s is a `T!L` whose set holds `A`'s. The view's thunk
/// (`rig.FnRef.ofFn`) returns `want`'s result, which Zig's error union
/// coercion makes of `f`'s.
pub fn lendsCovariant(ctx: *const SemContext, f: TypeId, want: TypeId) bool {
    if (f == want) return true;
    const a = ctx.types.get(f);
    const b = ctx.types.get(want);
    if (a != .function or b != .function) return false;
    const af = a.function;
    const bf = b.function;
    if (af.is_sub != bf.is_sub or af.params.len != bf.params.len or af.ct_params.len != 0 or bf.ct_params.len != 0) return false;
    for (af.params, bf.params) |x, y| if (x != y) return false;
    const ar = ctx.types.get(af.returns);
    const br = ctx.types.get(bf.returns);
    if (ar != .fallible or br != .fallible) return false;
    return ar.fallible.ok == br.fallible.ok and errorSubset(ctx, ar.fallible.set, br.fallible.set);
}

/// A type declared with `error`: a set, or a union of sets.
pub fn isErrorSet(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .nominal, .imported_nominal => (nominalDecl(ctx, ty) orelse return false).symbol().flags.error_set,
        else => false,
    };
}

/// One declared error set, by the module that declares it and its
/// symbol there: what a set is wherever it is named.
pub const SetKey = struct {
    ctx: *const SemContext,
    sym: SymbolId,
    /// The module that declares it, as the module asking names it: null
    /// for one of its own (`NominalDecl.module_id`).
    module_id: ?u32 = null,

    /// The set as a type of the module asking.
    pub fn typeIn(key: SetKey, ctx: *SemContext) std.mem.Allocator.Error!TypeId {
        if (key.module_id) |m| return ctx.intern(.{ .imported_nominal = .{ .module_id = m, .sym_id = key.sym } });
        return ctx.intern(.{ .nominal = key.sym });
    }
};

/// A member of the declared error set `set`, a type of the module that
/// records it.
pub const SetMember = struct { set: TypeId, name: []const u8 };

/// The declared error set `ty` names, if it names one rather than a
/// union.
pub fn setKeyOf(ctx: *const SemContext, ty: TypeId) ?SetKey {
    const d = nominalDecl(ctx, ty) orelse return null;
    const sym = d.symbol();
    if (!sym.flags.error_set or sym.error_parts != null) return null;
    return .{ .ctx = d.ctx, .sym = d.sym };
}

/// A union of error sets (`error L = A | B`).
pub fn isErrorUnion(ctx: *const SemContext, ty: TypeId) bool {
    const d = nominalDecl(ctx, ty) orelse return false;
    return d.symbol().error_parts != null;
}

/// The declared sets `ty`, a set or a union, stands for, each once,
/// appended to `out`; a union's parts are read in the module that
/// declares it. `error` and any other type add none.
pub fn errorSetLeaves(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SetKey), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    return leavesAt(ctx, ty, out, a, 0);
}

fn leavesAt(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SetKey), a: std.mem.Allocator, depth: u32) std.mem.Allocator.Error!void {
    return leavesFrom(ctx, ty, null, out, a, depth);
}

/// `leavesAt` for `ty` as the module with id `home` names it (null: the
/// module asking), so each leaf records its module as the asker names it.
fn leavesFrom(ctx: *const SemContext, ty: TypeId, home: ?u32, out: *std.ArrayList(SetKey), a: std.mem.Allocator, depth: u32) std.mem.Allocator.Error!void {
    if (depth > union_depth) return;
    const d = nominalDecl(ctx, ty) orelse return;
    const sym = d.symbol();
    if (!sym.flags.error_set) return;
    const module = d.module_id orelse home;
    const parts = sym.error_parts orelse {
        const key: SetKey = .{ .ctx = d.ctx, .sym = d.sym, .module_id = module };
        for (out.items) |k| if (k.ctx == key.ctx and k.sym == key.sym) return;
        return out.append(a, key);
    };
    for (parts) |part| try leavesFrom(d.ctx, part, module, out, a, depth + 1);
}

/// The members of declared set `key`, by name.
pub fn setMembers(key: SetKey) []const Field {
    return key.ctx.symbols.items[key.sym].fields orelse &.{};
}

/// How deep unions may nest before `errorSubset` stops looking: past
/// any union a program writes, and an end for one that joins itself,
/// which `typecheck.checkErrorJoin` rejects.
const union_depth = 32;

/// Whether `key`, a declared set, is one `outer` stands for: `outer`
/// itself, or a set a part of the union `outer` joins.
pub fn setIn(ctx: *const SemContext, key: SetKey, outer: TypeId) bool {
    return setInAt(ctx, key, outer, 0);
}

fn setInAt(ctx: *const SemContext, key: SetKey, outer: TypeId, depth: u32) bool {
    if (depth > union_depth) return false;
    const d = nominalDecl(ctx, outer) orelse return false;
    const sym = d.symbol();
    if (!sym.flags.error_set) return false;
    const parts = sym.error_parts orelse return key.ctx == d.ctx and key.sym == d.sym;
    for (parts) |part| if (setInAt(d.ctx, key, part, depth + 1)) return true;
    return false;
}

/// Whether every error of `inner` is one of `outer`: `outer` is `error`,
/// or each set `inner` stands for is one `outer` stands for. `error` is
/// inside no declared set.
pub fn errorSubset(ctx: *const SemContext, inner: TypeId, outer: TypeId) bool {
    if (outer == type_any_error) return true;
    if (inner == type_any_error) return false;
    // A set parameter may be any set: only itself holds it.
    if (isSetParam(ctx, inner) or isSetParam(ctx, outer)) return inner == outer;
    return subsetAt(ctx, inner, ctx, outer, 0);
}

fn subsetAt(ctx: *const SemContext, inner: TypeId, outer_ctx: *const SemContext, outer: TypeId, depth: u32) bool {
    if (depth > union_depth) return false;
    const d = nominalDecl(ctx, inner) orelse return false;
    const sym = d.symbol();
    if (!sym.flags.error_set) return false;
    const parts = sym.error_parts orelse return setInAt(outer_ctx, .{ .ctx = d.ctx, .sym = d.sym }, outer, 0);
    for (parts) |part| if (!subsetAt(d.ctx, part, outer_ctx, outer, depth + 1)) return false;
    return true;
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

/// An object: a type declared `obj`, generic or not, in Rig. Not an
/// enum, an error set, or a built-in type.
pub fn isObject(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .nominal => |sym| isObjectSym(ctx, sym),
        .parameterized_nominal => |pn| isObjectSym(ctx, pn.sym),
        .imported_nominal => |n| isObjectSym(ctx.foreign_semas.get(n.module_id) orelse return false, n.sym_id),
        else => false,
    };
}

/// `isObject` of the type `sym` declares.
pub fn isObjectSym(ctx: *const SemContext, sym_id: SymbolId) bool {
    if (sym_id >= ctx.symbols.items.len) return false;
    const sym = ctx.symbols.items[sym_id];
    if (isProxy(sym)) return isObjectSym(ctx.foreign_semas.get(sym.from.module_id) orelse return false, sym.from.sym);
    if (sym.decl_pos == builtin_decl_pos or sym.flags.error_set) return false;
    if (sym.kind != .nominal_type and sym.kind != .generic_type) return false;
    for (sym.fields orelse return false) |f| if (f.is_variant) return false;
    return true;
}

/// Whether a `T?` of payload `inner` is written `rig.Opt(T)`, and every
/// operation on it goes through the runtime's optional helpers (`some`,
/// `somePtr`, `pack`): where its representation may differ from Zig's
/// `?T`. A type parameter's may, since its instance decides; so may an
/// object's, which holds `none` in a niche where it has one, and an
/// optional of such an optional (`rig.Opt`). `pack` writes an object's flag optional in one store
/// where it fits (runtime `OneStore`). `strict` (`RIG_STRICT_OPTIONALS`)
/// holds each of them as a tagged struct.
pub fn optionalRouted(ctx: *const SemContext, inner: TypeId, strict: bool) bool {
    return switch (ctx.types.get(inner)) {
        .type_var => true,
        .optional => |payload| optionalRouted(ctx, payload, strict),
        else => isObject(ctx, inner),
    };
}

/// The none an object names (`none id == 0`): its one field, which never
/// holds `value` (a plain enum's field: never holds the variant
/// `variant`, whose value `value` is), so `T?` is a `T` that holds it
/// for `none` (`rig.Opt`).
pub const NamedNone = struct { field: []const u8, value: Wide, variant: ?[]const u8 = null };

/// The none the object type `ty` names, itself and not through a view;
/// null for any other type.
pub fn namedNoneOf(ctx: *const SemContext, ty: TypeId) ?NamedNone {
    return switch (ctx.types.get(ty)) {
        .nominal => |sym| ctx.named_nones.get(sym),
        .imported_nominal => |in| (ctx.foreign_semas.get(in.module_id) orelse return null).named_nones.get(in.sym_id),
        else => null,
    };
}

/// An enum all of whose variants are bare (no payloads, or an empty one,
/// `a()`): comparable with `==`, and its values integers (`enumValues`),
/// which resolve gives it. The one classifier of a plain enum.
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

/// For an enum type (not an error set), read through views, whether its
/// values are integers (`Int(x)`): true for a plain enum, false for one
/// with payload variants or type parameters; null for any other type.
pub fn enumValues(ctx: *const SemContext, ty: TypeId) ?bool {
    const base = unwrapViews(ctx, ty);
    const decl = nominalDecl(ctx, base) orelse return null;
    const sym = decl.symbol();
    if (sym.flags.error_set) return null;
    const fields = sym.fields orelse return null;
    // A generic enum's variants have no values, bare or not.
    for (fields) |f| if (f.is_variant) return sym.kind != .generic_type and isPlainEnum(ctx, base);
    return null;
}

/// A declared enum whose values are integers (`enumValues`), itself and
/// not a view of one: `<`, `<=`, `>`, and `>=` order its values by those
/// integers. A built-in enum (`Endian`, `Arch`) has no integer values.
pub fn isOrderedEnum(ctx: *const SemContext, ty: TypeId) bool {
    switch (ctx.types.get(ty)) {
        .nominal => |sym| if (isBuiltinEnum(ctx, sym)) return false,
        .imported_nominal => {},
        else => return false,
    }
    return enumValues(ctx, ty) orelse false;
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
        /// List, Cell, Signal, or `Void`.
        no_eq,
        /// A view held in a field or payload: the value is a view.
        view,
        /// A struct that declares `drop`.
        drop,
        /// A struct declared `unique`.
        unique,
        /// A `Simd[T, n]`, whose `==` compares lane by lane.
        lanes,
        /// A float, which `.hash()` does not take (`notHashable`).
        float,
        /// A type with its own `==` and no hash of its own, which hashing
        /// by its fields would not agree with (`notHashable`).
        own_eq,
        /// An API object: two may hide two types (open question 4).
        object,
    };
};

/// Why `==` does not compare values of `ty`, or null when it does:
/// numbers, Bool, `?String`, error values, plain enums, and, when all they
/// hold is equatable, optionals, arrays, slices, structs without `drop`,
/// and payload enums. Handles, functions, `Void`, List, Cell, Signal, and
/// views held in a field are not equatable. Each generic parameter
/// `ty` holds is appended to `params`, when given: `==` on `ty` holds in
/// the instances where it holds for them.
pub fn notEquatable(ctx: *SemContext, ty: TypeId, params: ?*std.ArrayList(SymbolId)) std.mem.Allocator.Error!?NotEquatable {
    return notComparable(ctx, ty, params, false);
}

/// Why `x.hash()` does not take a value of `ty`, or null when it does:
/// the types `==` compares (`notEquatable`), less a float and what holds
/// one, whose `==` makes `0.0` and `-0.0` equal and NaN equal to nothing.
/// Text of any type hashes its bytes.
pub fn notHashable(ctx: *SemContext, ty: TypeId, params: ?*std.ArrayList(SymbolId)) std.mem.Allocator.Error!?NotEquatable {
    return notComparable(ctx, ty, params, true);
}

fn notComparable(ctx: *SemContext, ty: TypeId, params: ?*std.ArrayList(SymbolId), hashing: bool) std.mem.Allocator.Error!?NotEquatable {
    var walk: EquatableWalk = .{ .ctx = ctx, .params = params, .hashing = hashing };
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

/// The name of the method by which a type gives `api` a meaning of its
/// own, with the signature `api` fixes (docs/design/apis.md, Stage 2);
/// null for an API whose meaning no type gives.
pub fn apiMethodName(api: Api) ?[]const u8 {
    return switch (api) {
        .Eq => "eq",
        .Hash => "hash_into",
        .Ord => "order",
        .Print => "print",
        else => null,
    };
}

/// The method by which the type `sym` gives `api` a meaning of its own:
/// its header names `api` and it declares the method `apiMethodName`
/// names. Null for one that keeps the derived meaning.
pub fn ownApiMethod(sym: Symbol, api: Api) ?Field {
    if (!sym.apis.contains(api)) return null;
    const name = apiMethodName(api) orelse return null;
    for (sym.fields orelse &.{}) |f| {
        if (f.is_method and !f.is_drop_method and std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// `ownApiMethod` of the type `ty` names, through views.
pub fn ownApiOf(ctx: *const SemContext, ty: TypeId, api: Api) ?Field {
    const decl = nominalDecl(ctx, ty) orelse return null;
    return ownApiMethod(decl.symbol(), api);
}

/// Why a type does not provide a built-in API (`lacks`): the type in it
/// that does not, and the path of fields to it (`NotEquatable.path`).
pub const Lack = struct {
    /// In the checked module's type store.
    ty: TypeId,
    /// Field names from the type to `ty`, joined by `.`; empty for the
    /// type itself or what it holds outside a field.
    path: []const u8 = "",
    /// A type parameter whose bounds do not name the API.
    bound: bool = false,
    /// A type with its own `==` and no hash of its own (`Hash`).
    own_eq: bool = false,
};

/// Why `ty` does not provide `api`, or null when it does (docs/design/apis.md,
/// "Which types provide which"). A type parameter provides what its
/// bounds name; one with no bound is decided by each instance, so it
/// lacks nothing here.
pub fn lacks(ctx: *SemContext, ty: TypeId, api: Api) std.mem.Allocator.Error!?Lack {
    if (containsPoison(ctx, ty)) return null;
    // Whether an object crosses is the crossing walk's (`blockerOf`).
    if (api != .Sends and api != .Syncs and mentionsObject(ctx, ty)) {
        if (apiObject(ctx, ty) != null) return .{ .ty = ty };
        if (objectHeld(ctx, ty)) |h| return if (objectMeets(ctx, h.object, h.form, api)) null else .{ .ty = ty };
    }
    switch (ctx.types.get(ty)) {
        .type_var => |sym| return boundLack(ctx, ty, sym, api),
        else => {},
    }
    switch (api) {
        .Eq, .Hash => {
            var params: std.ArrayList(SymbolId) = .empty;
            defer params.deinit(ctx.allocator);
            const not = if (api == .Eq) try notEquatable(ctx, ty, &params) else blk: {
                if (isText(ctx, ty)) break :blk null;
                break :blk try notHashable(ctx, ty, &params);
            };
            if (not) |n| return .{ .ty = n.ty, .path = n.path, .own_eq = n.why == .own_eq };
            return paramsLack(ctx, params.items, api);
        },
        .Ord => return ordLack(ctx, ty, 0),
        .Print => {
            if (!try printable(ctx, ty)) return .{ .ty = ty };
            if (try objectUnprinted(ctx, ty)) |held| return .{ .ty = held };
            return heldLack(ctx, ty, api);
        },
        .Num => return if (isNumeric(ctx, unwrapViews(ctx, ty))) null else .{ .ty = ty },
        .Iter => return if (try iterLack(ctx, ty) == null) null else .{ .ty = ty },
        .Integer => return if (isInteger(ctx, unwrapViews(ctx, ty))) null else .{ .ty = ty },
        .Signed => return switch (ctx.types.get(unwrapViews(ctx, ty))) {
            .int => |info| if (info.signed) null else .{ .ty = ty },
            .float, .int_literal, .float_literal => null,
            else => .{ .ty = ty },
        },
        .Copy => return switch (copies(ctx, ty)) {
            .yes => null,
            .no => .{ .ty = ty },
            .depends => heldLack(ctx, ty, api),
        },
        .Clone => return switch (cloneable(ctx, ty)) {
            .no => .{ .ty = ty },
            .depends => heldLack(ctx, ty, api),
            else => null,
        },
        .Owned => {
            // An API object it holds that may hold a loan is named
            // (`objectUnowned`), as a home that holds none names it.
            if (mayHoldView(ctx, ty)) return .{ .ty = if (unwrapViews(ctx, ty) == ty) (try objectUnowned(ctx, ty)) orelse ty else ty };
            return heldLack(ctx, ty, api);
        },
        .Sends, .Syncs => {
            const found = blockerOf(ctx, ty, if (api == .Sends) .moves else .shares) orelse return heldLack(ctx, ty, api);
            // A blocker inside another module's object is a type of that
            // module's table: the lack names the whole type, which is this
            // module's.
            if (found.ctx != ctx) return .{ .ty = ty };
            const blocker = found.ty;
            return switch (ctx.types.get(blocker)) {
                .type_var => |sym| boundLack(ctx, blocker, sym, api),
                else => .{ .ty = blocker },
            };
        },
    }
}

/// An API object `ty` holds, through wrappers, type arguments, fields,
/// and payloads (the walk `holdsByteSlice` makes), whose braces and API
/// name no `Print`: `List[^{Shape}]`, and an `obj` with a `?{Shape}`
/// field, print only as their objects do (`objectMeets`). The object's
/// type, or `ty` when the object is another module's field's; null when
/// each prints.
pub fn objectUnprinted(ctx: *const SemContext, ty: TypeId) std.mem.Allocator.Error!?TypeId {
    const a = ctx.allocator;
    var todo: std.ArrayList(ByteSliceItem) = .empty;
    defer todo.deinit(a);
    var seen: std.AutoHashMapUnmanaged(ByteSliceVisit, void) = .empty;
    defer seen.deinit(a);
    try todo.append(a, .{ .ctx = ctx, .ty = ty });
    while (todo.pop()) |item| {
        const c = item.ctx;
        const found = if (objectHeld(c, item.ty)) |h| !objectMeets(c, h.object, h.form, .Print) else apiObject(c, item.ty) != null;
        if (found) return if (c == ctx) item.ty else ty;
        if (objectHeld(c, item.ty) != null) continue;
        switch (c.types.get(item.ty)) {
            .optional, .read_view, .write_view, .shared, .weak => |inner| {
                try todo.append(a, .{ .ctx = c, .ty = inner });
                continue;
            },
            .fallible => |f| {
                try todo.append(a, .{ .ctx = c, .ty = f.ok });
                continue;
            },
            .array => |arr| {
                try todo.append(a, .{ .ctx = c, .ty = arr.elem });
                continue;
            },
            .slice => |sl| {
                try todo.append(a, .{ .ctx = c, .ty = sl.elem });
                continue;
            },
            .parameterized_nominal => |pn| for (pn.args) |arg| try todo.append(a, .{ .ctx = c, .ty = arg }),
            .nominal, .imported_nominal => {},
            else => continue,
        }
        const decl = nominalDecl(c, item.ty) orelse continue;
        if ((try seen.getOrPut(a, .{ .ctx = decl.ctx, .sym = decl.sym })).found_existing) continue;
        // A type that prints itself prints no field it does not choose to.
        if (ownApiMethod(decl.ctx.symbols.items[decl.sym], .Print) != null) continue;
        for (decl.ctx.symbols.items[decl.sym].fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| try todo.append(a, .{ .ctx = decl.ctx, .ty = d.ty });
        }
    }
    return null;
}

/// The first API object a value of `ty` may hold, through its fields,
/// elements, and handles, whose braces name no `Owned`: it may hold a
/// loan its type does not show (Core §4), so a home that holds no loan,
/// an owned closure, keeps it only as a `^{A + Owned}`. Null when every
/// object it may hold names `Owned`, or it holds none.
pub fn objectUnowned(ctx: *const SemContext, ty: TypeId) std.mem.Allocator.Error!?TypeId {
    var seen: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer seen.deinit(ctx.allocator);
    return objectUnownedIn(ctx, ty, &seen);
}

/// Why a value of `ty` may hold a loan where a home holds none (an owned
/// closure, a channel's values, a generic body's Cell, Signal, or owned
/// closure), when an API object it holds is why (`objectUnowned`): "a
/// `^{Shape}` may hold one: write `^{Shape + Owned}`". Null when none is,
/// or `ty` is a view, whose own loan is why. The one reason, with its
/// fix, each such home gives.
pub fn objectLoanReason(ctx: *const SemContext, a: std.mem.Allocator, ty: TypeId) std.mem.Allocator.Error!?[]const u8 {
    if (unwrapViews(ctx, ty) != ty) return null;
    const o = (try objectUnowned(ctx, ty)) orelse return null;
    const shown = try formatTypeIn(ctx, a, o);
    const h = objectHeld(ctx, o);
    var with = if (h) |x| x.object else apiObject(ctx, o) orelse
        return try a.print("`{s}` holds an API object whose braces name no `Owned`, which may hold one", .{shown});
    with.builtins.insert(.Owned);
    // A view holds a loan whatever it views: a box holds none.
    const sigil: []const u8 = if (h) |x| switch (x.form) {
        .shared => "*",
        .weak => "~",
        .read, .write, .box => "^",
    } else "^";
    return try a.print("a `{s}` may hold one: write `{s}{s}`", .{ shown, sigil, try objectSpelling(ctx, a, with) });
}

/// Whether `ty`, which holds an API object as `h` says, holds no loan by
/// its braces: they name `Owned`, or it is a frozen value's handle,
/// `*{A + Syncs}`, which holds no view.
pub fn heldObjectOwned(ctx: *const SemContext, ty: TypeId, h: ObjectHeld) bool {
    return objectBounds(ctx, h.object).contains(.Owned) or (h.form == .shared and frozenObject(ctx, ctx.types.get(ty).shared));
}

fn objectUnownedIn(ctx: *const SemContext, ty: TypeId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) std.mem.Allocator.Error!?TypeId {
    if (objectHeld(ctx, ty)) |h| return if (heldObjectOwned(ctx, ty, h)) null else ty;
    if (apiObject(ctx, ty)) |o| return if (objectBounds(ctx, o).contains(.Owned)) null else ty;
    switch (ctx.types.get(ty)) {
        .optional, .read_view, .write_view, .shared, .weak, .range => |inner| return objectUnownedIn(ctx, inner, seen),
        .fallible => |inner| return objectUnownedIn(ctx, inner.ok, seen),
        .array => |a| return objectUnownedIn(ctx, a.elem, seen),
        .slice => |sl| return objectUnownedIn(ctx, sl.elem, seen),
        .results => |parts| {
            for (parts) |part| if (try objectUnownedIn(ctx, part, seen)) |o| return o;
            return null;
        },
        .parameterized_nominal => |pn| {
            for (pn.args) |a| if (try objectUnownedIn(ctx, a, seen)) |o| return o;
            if (isBuiltinGeneric(ctx, pn.sym)) return null;
            return objectUnownedFields(ctx, pn.sym, seen);
        },
        .nominal => |sym| return objectUnownedFields(ctx, sym, seen),
        .imported_nominal => {
            const decl = nominalDecl(ctx, ty) orelse return null;
            // Found in another module's table: the whole type names it.
            return if (try objectUnownedFields(decl.ctx, decl.sym, seen) != null) ty else null;
        },
        else => return null,
    }
}

fn objectUnownedFields(ctx: *const SemContext, sym: SymbolId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) std.mem.Allocator.Error!?TypeId {
    const got = try seen.getOrPut(ctx.allocator, .{ .ctx = ctx, .sym = sym });
    if (got.found_existing) return null;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| {
        for (dataFields(f)) |d| if (try objectUnownedIn(ctx, d.ty, seen)) |o| return o;
    }
    return null;
}

/// Whether an API object held as `form` meets built-in API `api`
/// (docs/design/apis.md, Stage 4): a read view copies, as any read view
/// does, so it clones too; `Print` where its braces name it or its API
/// builds on it, and `Clone` so for a box, the one form whose `+` makes a
/// new owner of the value, and for a handle, whose `+` adds a count;
/// `Owned` for a box or a handle whose braces name it, checked where the
/// type is erased, and for a `*{A + Syncs}`, which holds a frozen value.
/// Nothing else: two objects may hide two types, which `==`, hashing,
/// and `<` cannot compare. `Sends` and `Syncs` are the crossing walk's,
/// by the bounds the braces name (`lacks`, `blockerOf`). A bare object
/// meets nothing (`lacks`).
pub fn objectMeets(ctx: *const SemContext, o: ApiObject, form: ObjectForm, api: Api) bool {
    const named = objectBounds(ctx, o);
    return switch (api) {
        .Copy => form == .read,
        // A weak handle prints whether its value lives, never the value.
        .Print => form == .weak or named.contains(.Print),
        // A handle's `+` adds a count, as any handle's does.
        .Clone => form == .read or form == .shared or form == .weak or (form == .box and named.contains(.Clone)),
        // A `*{A + Syncs}` holds a frozen value, which holds no view.
        .Owned => (form == .box or form == .shared or form == .weak) and named.contains(.Owned) or (form == .shared and named.contains(.Syncs)),
        .Eq, .Hash, .Ord, .Num, .Integer, .Signed, .Iter => false,
        // The crossing walk decides these (`lacks`, `blockerOf`).
        .Sends, .Syncs => false,
    };
}

/// Parameters `params` at `args`, followed by each associated type made
/// for one of them (`Symbol.assoc`) at what its argument gives it
/// (`assocType`): an instance's checks reach `I.Item` as they reach `I`.
/// One whose argument gives it nothing is left out, for the base's bound
/// to report.
pub fn withAssoc(ctx: *SemContext, params: []const SymbolId, args: []const TypeId) std.mem.Allocator.Error!struct { params: []const SymbolId, args: []const TypeId } {
    const any = for (params) |p| {
        if (p != symbol_invalid and ctx.symbols.items[p].assoc.len > 0) break true;
    } else false;
    if (!any or args.len < params.len) return .{ .params = params, .args = args };
    const a = ctx.arena.allocator();
    var ps: std.ArrayList(SymbolId) = .empty;
    var as: std.ArrayList(TypeId) = .empty;
    try ps.appendSlice(a, params);
    try as.appendSlice(a, args[0..params.len]);
    var i: usize = 0;
    while (i < ps.items.len) : (i += 1) {
        const p = ps.items[i];
        if (p == symbol_invalid) continue;
        for (ctx.symbols.items[p].assoc) |assoc| {
            const of = ctx.symbols.items[assoc].assoc_of.?;
            if (containsPoison(ctx, as.items[i])) continue;
            const ty = (try assocType(ctx, as.items[i], of.api, of.name)) orelse continue;
            try ps.append(a, assoc);
            try as.append(a, ty);
        }
    }
    return .{ .params = ps.items, .args = as.items };
}

/// The type an associated type's base takes (`I = Buf`) when what the
/// instance gives the associated type (`I.Item = ?String`) may view
/// memory that base owns, as the ownership checker reaches it
/// (`viewReach`); null otherwise. An iterator whose `next` names only
/// paths of self declared as read views (`from @map`,
/// `SelfPath.via_view`) gives items that view what it only views, never
/// itself (Core sentence 7). Recorded for each instance as
/// `SemContext.item_views`, which the ownership checker reads where a
/// generic body holds such a value past a change of its base.
fn assocViewsBase(ctx: *SemContext, params: []const SymbolId, args: []const TypeId, assoc: AssocOf, item: TypeId) std.mem.Allocator.Error!?TypeId {
    const i = std.mem.findScalar(SymbolId, params, assoc.base) orelse return null;
    if (i >= args.len) return null;
    const base_ty = args[i];
    if (containsTypeVar(ctx, item) or containsTypeVar(ctx, base_ty)) return null;
    if (assoc.api == .iter) if (try lookupMethod(ctx, base_ty, "next")) |next| {
        const paths = next.field.origins.self_paths;
        const through_views = paths.len > 0 and for (paths) |sp| {
            if (!sp.via_view) break false;
        } else true;
        if (through_views) return null;
    };
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    return if (try viewReach(ctx, scratch.allocator(), base_ty, item) == .owned) base_ty else null;
}

/// Each argument of the instance `of`, made at `at`, provides what its
/// parameter's bounds name: a built-in API (`lacks`) or one of the
/// program's own (`provides`); the first that does not is reported
/// there. The associated types' bounds are checked too (`[I: Iter, I.Item:
/// Ord]`), after their bases', at what each argument gives them. False
/// after a diagnostic.
pub fn checkBounds(ctx: *SemContext, given_params: []const SymbolId, given_args: []const TypeId, at: u32, of: InstanceRoot) std.mem.Allocator.Error!bool {
    return boundsHold(ctx, given_params, given_args, .{ .at = at, .of = of });
}

/// Whether `given_args` meet the bounds of `given_params`, as
/// `checkBounds` decides, with nothing reported: for an instance whose
/// bounds another instance checks and reports (`implInstance`).
pub fn boundsMet(ctx: *SemContext, given_params: []const SymbolId, given_args: []const TypeId) std.mem.Allocator.Error!bool {
    return boundsHold(ctx, given_params, given_args, null);
}

fn boundsHold(ctx: *SemContext, given_params: []const SymbolId, given_args: []const TypeId, report: ?struct { at: u32, of: InstanceRoot }) std.mem.Allocator.Error!bool {
    const all = try withAssoc(ctx, given_params, given_args);
    const params = all.params;
    const args = all.args;
    for (params, 0..) |param, i| {
        if (i >= args.len) break;
        const sym = ctx.symbols.items[param];
        // A parameter with no bound meets those its signature implies.
        if (!hasBounds(sym) and sym.implied.count() == 0) continue;
        const arg = args[i];
        if (containsPoison(ctx, arg)) continue;
        if (sym.assoc_of) |assoc| if (try assocViewsBase(ctx, params, args, assoc, arg)) |base| {
            try ctx.item_views.put(ctx.allocator, .{ .assoc = param, .base = base }, arg);
        };
        // A type parameter with no bound is no exception: the witness the
        // bound takes would come from its own bounds, and it has none.
        for (sym.user_apis) |api| {
            if (try provides(ctx, arg, api) != null) continue;
            const r = report orelse return false;
            if (try reportStatedUser(ctx, r.at, arg, api, try ctx.arena.allocator().print("{s} `{s}`, which needs `{s}: {s}`", .{ if (r.of == .func) "calls" else "names", try rootName(ctx, r.of), sym.name, try apiName(ctx, api) }))) return false;
            try reportUnprovided(ctx, r.at, r.of, sym.name, arg, api);
            return false;
        }
        // What the bounds name, written or implied, first, then what they
        // imply, those of the APIs they name included: `K` filling
        // `Map[K, V]` asks `Hash` before the `Eq` it gives.
        const named = strongest(sym.apis.unionWith(sym.implied));
        for ([_]Apis{ named, boundApis(ctx, sym).differenceWith(named) }) |set| {
            var it = set.iterator();
            while (it.next()) |api| {
                const lack = (try lacks(ctx, arg, api)) orelse continue;
                const r = report orelse return false;
                if (try reportStatedLack(ctx, r.at, api, lack, try ctx.arena.allocator().print("{s} `{s}`, which needs `{s}: {s}`", .{ if (r.of == .func) "calls" else "names", try rootName(ctx, r.of), sym.name, @tagName(api) }))) return false;
                try reportLack(ctx, r.at, try rootName(ctx, r.of), sym.name, arg, api, lack);
                return false;
            }
        }
    }
    return true;
}

/// `of` cannot use `pname = arg`, which does not provide `api`, an API
/// of the program's own, at `at`; the fix names the header or the
/// addition that would provide it, or the bound.
fn reportUnprovided(ctx: *SemContext, at: u32, of: InstanceRoot, pname: []const u8, arg: TypeId, api: ApiRef) std.mem.Allocator.Error!void {
    const inst = try rootName(ctx, of);
    const bare = if (std.mem.indexOfScalar(u8, inst, '[')) |i| inst[0..i] else inst;
    const aname = try formatType(ctx, arg);
    const iname = try apiName(ctx, api);
    // A box is not its value, and an object's value has no type a bound
    // could name (open question 9).
    if (objectHeld(ctx, arg)) |h| {
        const view = try objectSpelling(ctx, ctx.arena.allocator(), h.object);
        return ctx.err(at, "`{s}` cannot use `{s} = {s}`: `{s}` needs `{s}: {s}`, and an API object meets no bound by an API; take a `?{s}`", .{ inst, pname, aname, bare, pname, iname, view });
    }
    try ctx.err(at, "`{s}` cannot use `{s} = {s}`: `{s}` needs `{s}: {s}`, and `{s}` does not provide `{s}`{s}", .{ inst, pname, aname, bare, pname, iname, aname, iname, try unprovidedFix(ctx, arg, api) });
}

/// The end of an error that `arg` does not provide `api`, an API of a
/// program's own: the bound to add, the header or addition that would
/// provide it, or why none can.
pub fn unprovidedFix(ctx: *SemContext, arg: TypeId, api: ApiRef) std.mem.Allocator.Error![]const u8 {
    const a = ctx.arena.allocator();
    const aname = try formatType(ctx, arg);
    const iname = try apiName(ctx, api);
    const fix: []const u8 = fix: {
        switch (ctx.types.get(arg)) {
            .type_var => |p| {
                const sym = ctx.symbols.items[p];
                if (!hasBounds(sym)) break :fix try a.print("; give it the bound: `[{s}: {s}]`", .{ sym.name, iname });
                break :fix try a.print("; add `{s}` to its bounds: `[{s}: {s} + {s}]`", .{ iname, sym.name, try formatBounds(ctx, a, sym, null), iname });
            },
            else => {},
        }
        // A view, an optional, a handle, a function, an array, or a slice
        // takes its facts from its parts, and no addition names one.
        const unnamed: ?[]const u8 = switch (ctx.types.get(arg)) {
            .read_view, .write_view, .string_view => "a view",
            .optional => "an optional",
            .shared, .weak => "a handle",
            .function, .callable => "a function type",
            .array => "an array",
            .slice => "a slice",
            else => null,
        };
        if (unnamed) |what| break :fix try a.print("; {s} provides no API of a program's own", .{what});
        // An addition under a bound the argument does not meet.
        if (try conditionalConformance(ctx, arg, api)) |c| break :fix try a.print("; `{s}` provides `{s}` only where {s}", .{ try formatTypeIn(c.home, a, c.conf.ty), iname, try conditionsText(c.home, a, c.conf) });
        const decl = nominalDecl(ctx, arg) orelse break :fix try a.print("; write `add {s}: {s}` in the module of `{s}`", .{ aname, iname, iname });
        const sym = decl.symbol();
        if (decl.module_id != null or isProxy(sym) or sym.decl_pos == builtin_decl_pos or decl.ctx.is_std) {
            break :fix try a.print("; write `add {s}: {s}` in the module of `{s}`", .{ aname, iname, iname });
        }
        // A type of this module names the API on its header.
        const is_enum = for (sym.fields orelse &.{}) |f| {
            if (f.is_variant) break true;
        } else false;
        const params: []const u8 = if (sym.kind == .generic_type) blk: {
            var names: std.ArrayList(u8) = .empty;
            for (sym.type_params orelse &.{}, 0..) |tp, i| {
                if (i > 0) try names.appendSlice(a, ", ");
                try names.appendSlice(a, ctx.symbols.items[tp].name);
            }
            break :blk try a.print("[{s}]", .{names.items});
        } else "";
        // A generic type provides it for every instance, or by an addition
        // under a bound; the header is the simple fix.
        const named = try formatBounds(ctx, a, sym, null);
        break :fix try a.print("; declare `{s} {s}{s}: {s}{s}{s}`", .{ if (is_enum) "enum" else "obj", sym.name, params, named, if (named.len > 0) " + " else "", iname });
    };
    return fix;
}

/// A conformance of `ty`'s type constructor to `api` whose conditions
/// `ty` does not meet (`add Wrap[T: Shape]: Shape` for `Wrap[Label]`).
fn conditionalConformance(ctx: *SemContext, ty: TypeId, api: ApiRef) std.mem.Allocator.Error!?struct { home: *const SemContext, conf: Conformance } {
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const key = (try typeKey(ctx, a, ty)) orelse return null;
    for ([_]u32{ ctx.module_id, api.module_id, key.module_id }) |m| {
        if (m == 0) continue;
        const home: *const SemContext = if (m == ctx.module_id) ctx else ctx.foreign_semas.get(m) orelse continue;
        for (home.conformances.items) |conf| {
            if (conf.params.len == 0 or !conf.api.eql(api)) continue;
            const ckey = (try typeKey(home, a, conf.ty)) orelse continue;
            if (ckey.eql(key)) return .{ .home = home, .conf = conf };
        }
    }
    return null;
}

/// The bounds an addition puts on its type's arguments: `T: Shape`,
/// `` `T: Shape` and `U: Print` ``.
fn conditionsText(home: *const SemContext, a: std.mem.Allocator, conf: Conformance) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (conf.params) |p| {
        const sym = home.symbols.items[p];
        if (!hasBounds(sym)) continue;
        if (out.items.len > 0) try out.appendSlice(a, " and ");
        try out.print(a, "`{s}: {s}`", .{ sym.name, try formatBounds(home, a, sym, null) });
    }
    return out.items;
}

/// What a type provides an API of a program's own by: a type parameter's
/// bound that names it or an API built on it, or a conformance
/// (`SemContext.conformances` of module `module_id`, at `index`).
pub const Provision = union(enum) {
    bound: SymbolId,
    conformance: struct { module_id: u32, index: u32 },
};

/// Whether `ty`, a type of `ctx`, provides `api`, and by what; null when
/// it does not (docs/design/apis.md, Stage 3, "Coherence"). The one
/// answer to whether a type provides an API of a program's own: a bound,
/// conformance, and a call's dispatch read it. A conformance is written
/// in the type's module or the API's, so only those are searched. A view,
/// an optional, a handle, and a function provide none.
pub fn provides(ctx: *SemContext, ty: TypeId, api: ApiRef) std.mem.Allocator.Error!?Provision {
    return providesAt(ctx, ty, api, 0);
}

fn providesAt(ctx: *SemContext, ty: TypeId, api: ApiRef, depth: u32) std.mem.Allocator.Error!?Provision {
    if (depth > 32) return null;
    // An API object, or a view or box of one, meets no bound by an API:
    // a box is not its value (docs/design/apis.md, Stage 4).
    if (apiObject(ctx, ty) != null or objectHeld(ctx, ty) != null) return null;
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    if (ctx.types.get(ty) == .type_var) {
        const p = ctx.types.get(ty).type_var;
        for (ctx.symbols.items[p].user_apis) |b| {
            for (try apiClosure(ctx, a, b)) |c| if (c.eql(api)) return .{ .bound = p };
        }
        return null;
    }
    const key = (try typeKey(ctx, a, ty)) orelse return null;
    const homes = [_]u32{ ctx.module_id, api.module_id, key.module_id };
    for (homes, 0..) |m, hi| {
        if (m == 0) continue;
        const repeated = for (homes[0..hi]) |e| {
            if (e == m) break true;
        } else false;
        if (repeated) continue;
        const home: *const SemContext = if (m == ctx.module_id) ctx else ctx.foreign_semas.get(m) orelse continue;
        for (home.conformances.items, 0..) |conf, ci| {
            const covers = for (try apiClosure(home, a, conf.api)) |c| {
                if (c.eql(api)) break true;
            } else false;
            if (!covers) continue;
            const ckey = (try typeKey(home, a, conf.ty)) orelse continue;
            if (!ckey.eql(key)) continue;
            if (!try conditionsMet(ctx, ty, home, conf, depth)) continue;
            return .{ .conformance = .{ .module_id = m, .index = @intCast(ci) } };
        }
    }
    return null;
}

/// Each argument of `ty`, a generic type's instance, meets the bounds the
/// addition `conf` (of module `home`) puts on the parameter it fills
/// (`add Wrap[T: Shape]: Shape`).
fn conditionsMet(ctx: *SemContext, ty: TypeId, home: *const SemContext, conf: Conformance, depth: u32) std.mem.Allocator.Error!bool {
    const bounded = for (conf.params) |p| {
        if (hasBounds(home.symbols.items[p])) break true;
    } else false;
    if (!bounded) return true;
    const args = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.args,
        else => return false,
    };
    const own = switch (home.types.get(conf.ty)) {
        .parameterized_nominal => |pn| pn.args,
        else => return false,
    };
    for (own, 0..) |o, i| {
        if (i >= args.len) return false;
        const p = switch (home.types.get(o)) {
            .type_var => |p| p,
            else => continue,
        };
        const bound = home.symbols.items[p];
        for (bound.user_apis) |u| if (try providesAt(ctx, args[i], u, depth + 1) == null) return false;
        var it = implied(bound.apis).iterator();
        while (it.next()) |b| if (try lacks(ctx, args[i], b) != null) return false;
    }
    return true;
}

/// A type as a conformance names it, the same in every module: a type a
/// module declares by that module and its symbol there, a built-in
/// generic by its symbol (one in every module), and any other built-in
/// type by its name. Null for a type no conformance names.
const TypeKey = struct {
    module_id: u32 = 0,
    sym: SymbolId = symbol_invalid,
    name: []const u8 = "",

    fn eql(x: TypeKey, y: TypeKey) bool {
        if (x.sym != symbol_invalid or y.sym != symbol_invalid) return x.module_id == y.module_id and x.sym == y.sym;
        return std.mem.eql(u8, x.name, y.name);
    }
};

fn typeKey(ctx: *const SemContext, a: std.mem.Allocator, ty: TypeId) std.mem.Allocator.Error!?TypeKey {
    return switch (ctx.types.get(ty)) {
        .nominal => |s| symKey(ctx, s),
        .parameterized_nominal => |pn| symKey(ctx, pn.sym),
        .imported_nominal => |n| .{ .module_id = n.module_id, .sym = n.sym_id },
        .int, .float, .bool, .string, .static, .symbol => .{ .name = try formatTypeIn(ctx, a, ty) },
        // Every `Slot[n]`, whatever its `n`, as `add Slot[n]` names it.
        .slot => .{ .name = "Slot" },
        else => null,
    };
}

/// The compile-time arguments of `ty` that a conformance's own parameters
/// fill: a generic type's, or a slot's `n`; empty for any other type.
pub fn conformanceArgs(ctx: *const SemContext, a: std.mem.Allocator, ty: TypeId) std.mem.Allocator.Error![]const TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.args,
        .slot => |n| a.dupe(TypeId, &.{n}),
        else => &.{},
    };
}

fn symKey(ctx: *const SemContext, s: SymbolId) TypeKey {
    const sym = ctx.symbols.items[s];
    if (sym.decl_pos == builtin_decl_pos) return .{ .sym = s };
    if (isProxy(sym)) return .{ .module_id = sym.from.module_id, .sym = sym.from.sym };
    return .{ .module_id = ctx.module_id, .sym = s };
}

/// The conformance `p` names, with the context of the module that
/// writes it.
pub fn conformanceOf(ctx: *const SemContext, p: Provision) ?struct { home: *const SemContext, conf: Conformance } {
    const c = switch (p) {
        .conformance => |c| c,
        .bound => return null,
    };
    const home: *const SemContext = if (c.module_id == ctx.module_id) ctx else ctx.foreign_semas.get(c.module_id) orelse return null;
    return .{ .home = home, .conf = home.conformances.items[c.index] };
}

/// The witness by which `ty`, a type of `ctx`, provides `api`, or null
/// when it does not (`provides`, the one answer). A type parameter's is
/// its own, by the bound that names `api` or an API built on it; any
/// other type's is its conformance's, with the witnesses of a generic
/// type's arguments that the conformance's bounds ask for.
pub fn witnessFor(ctx: *SemContext, ty: TypeId, api: ApiRef) std.mem.Allocator.Error!?Witness {
    const p = (try provides(ctx, ty, api)) orelse return null;
    switch (p) {
        .bound => |sym| {
            var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
            defer scratch.deinit();
            for (ctx.symbols.items[sym].user_apis) |b| {
                for (try apiClosure(ctx, scratch.allocator(), b)) |c| if (c.eql(api)) return .{ .param = .{ .sym = sym, .api = b } };
            }
            return null;
        },
        .conformance => |c| {
            const found = conformanceOf(ctx, p).?;
            const args = try conformanceArgs(ctx, ctx.arena.allocator(), ty);
            // The parameters whose bounds the witness takes: an addition's
            // own, or the generic type's.
            const params: []const SymbolId = if (found.conf.kind == .add) found.conf.params else switch (found.home.types.get(found.conf.ty)) {
                .parameterized_nominal => |pn| found.home.symbols.items[pn.sym].type_params orelse &.{},
                else => &.{},
            };
            const arg_ws = (try argWitnesses(ctx, found.home, params, args)) orelse return null;
            return .{ .conformance = .{ .module_id = c.module_id, .index = c.index, .ty = ty, .args = arg_ws } };
        },
    }
}

/// The witnesses compile-time arguments `args` (of `ctx`) give the
/// parameters `params` (symbols of `home`) they fill: one after each
/// type argument for each API of a program's own its parameter's bounds
/// name, in the order written. Null when an argument does not provide
/// one, which the bound's check reports.
pub fn argWitnesses(ctx: *SemContext, home: *const SemContext, params: []const SymbolId, args: []const TypeId) std.mem.Allocator.Error!?[]const ArgWitness {
    var out: std.ArrayList(ArgWitness) = .empty;
    for (params, 0..) |p, i| {
        if (p == symbol_invalid or i >= args.len) continue;
        for (home.symbols.items[p].user_apis) |b| {
            const w = (try witnessFor(ctx, args[i], b)) orelse return null;
            try out.append(ctx.arena.allocator(), .{ .arg = @intCast(i), .witness = w });
        }
    }
    return out.items;
}

/// The witnesses an instance `ty` of a generic type takes among its
/// arguments, after the types they bound (`Bag(Square,
/// __rig_impl_Shape_Square)`); empty for every other type.
pub fn typeWitnesses(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?[]const ArgWitness {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return &.{},
    };
    const params = ctx.symbols.items[pn.sym].type_params orelse return &.{};
    return argWitnesses(ctx, ctx, params, pn.args);
}

/// Record the witnesses of every instance of a generic type whose
/// parameters are bounded by an API of a program's own, among this
/// module's types (`SemContext.type_witnesses`), for emit, which writes
/// them after the arguments they follow.
pub fn recordTypeWitnesses(ctx: *SemContext) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < ctx.types.items.items.len) : (i += 1) {
        const ty: TypeId = @intCast(i);
        const pn = switch (ctx.types.get(ty)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        const params = ctx.symbols.items[pn.sym].type_params orelse continue;
        const bounded = for (params) |p| {
            if (p != symbol_invalid and ctx.symbols.items[p].user_apis.len > 0) break true;
        } else false;
        if (!bounded or ctx.type_witnesses.contains(ty)) continue;
        // A type whose parameters carry a method's bounds just now
        // (`widenOwnerBounds`) takes the witnesses its declaration names,
        // which the record after that method's check gives it.
        const widened = for (params) |p| {
            if (p != symbol_invalid and ownerWidened(ctx, p)) break true;
        } else false;
        if (widened) continue;
        const ws = (try typeWitnesses(ctx, ty)) orelse continue;
        try ctx.type_witnesses.put(ctx.allocator, ty, ws);
    }
}

// =============================================================================
// Associated types and iterators (docs/design/apis.md, Stage 3)
// =============================================================================

/// What a `for` loop makes of a value of type `ty`: not an iterator, one
/// whose `next` has another shape (why), or an iterator of `item`. The one
/// classifier of iterators (docs/internals/INTERNALS.md, "Loops over an
/// iterator"): the loop, the `Iter` bound (`lacks`), and `I.Item`
/// (`assocType`) read it. A positive list: a struct or enum a program or
/// std declares (not a `List`, an array, a slice, a `?String`, a range,
/// or a `Table`, which keep their own meaning) that declares `next(!@) ->
/// T?`, or a type parameter bounded by `Iter`.
pub const IterShape = union(enum) { not_iterator, malformed: []const u8, item: TypeId };

pub fn iterItem(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!IterShape {
    const peeled = unwrapViews(ctx, ty);
    switch (ctx.types.get(peeled)) {
        .nominal, .imported_nominal => {},
        .parameterized_nominal => if (listElem(ctx, peeled) != null or tableElem(ctx, peeled) != null) return .not_iterator,
        .type_var => |p| {
            if (!boundApis(ctx, ctx.symbols.items[p]).contains(.Iter)) return .not_iterator;
            return .{ .item = try ctx.intern(.{ .type_var = try assocParam(ctx, p, .iter, "Item") }) };
        },
        else => return .not_iterator,
    }
    const next = (try methodOfType(ctx, peeled, "next")) orelse return .not_iterator;
    if (next.field.receiver != .write) return .{ .malformed = switch (next.field.receiver) {
        .read => "takes `?@`",
        .value => "takes `<@`",
        else => "takes no self",
    } };
    if (next.field.owner_bounds.len > 0) return .{ .malformed = "is declared under a bound on its type's parameters, which the loop does not state" };
    if (next.fn_ty.params.len != 1) return .{ .malformed = "takes more than `@`" };
    if (next.fn_ty.ct_params.len > 0) return .{ .malformed = "takes compile-time parameters" };
    return switch (ctx.types.get(next.fn_ty.returns)) {
        .optional => |o| .{ .item = o },
        else => .{ .malformed = "does not give an optional" },
    };
}

/// Why a type argument `ty` does not provide `Iter`, as the end of an
/// error says it, or null when it does: what `iterItem` decides, and
/// two facts a bound adds to the loop's. A view is no iterator, since
/// `next(!@)` advances the iterator itself (the loop says the same of
/// `for x in ?it`); and a `next` private to another module is not called
/// from this one, as a call by name or a loop would not call it.
pub fn iterLack(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?[]const u8 {
    const a = ctx.arena.allocator();
    if (unwrapViews(ctx, ty) != ty) return "a view only reads an iterator, and `next(!@)` advances it; pass the iterator itself, `!it`";
    switch (try iterItem(ctx, ty)) {
        .item => {},
        .malformed => |why| return try a.print("its `next` {s}", .{why}),
        .not_iterator => return "it declares no `fun next(!@) -> T?`",
    }
    const decl = nominalDecl(ctx, ty) orelse return null;
    const module = decl.module_id orelse if (isProxy(decl.symbol())) decl.symbol().from.module_id else return null;
    if (module == ctx.module_id) return null;
    const next = (try methodOfType(ctx, ty, "next")) orelse return null;
    if (next.field.is_pub) return null;
    const foreign = ctx.foreign_semas.get(module) orelse return null;
    return try a.print("its `next` is private to module `{s}`; declare it `pub fun next` there", .{foreign.name});
}

/// The method `name` of a value of type `ty`, a type of this module or
/// another's, with its signature in this module's types.
pub fn methodOfType(ctx: *SemContext, ty: TypeId, name: []const u8) std.mem.Allocator.Error!?struct { field: Field, fn_ty: FunctionType } {
    if (try lookupMethod(ctx, ty, name)) |m| return .{ .field = m.field, .fn_ty = m.fn_ty };
    const decl = nominalDecl(ctx, unwrapAccess(ctx, ty)) orelse return null;
    const module_id = decl.module_id orelse return null;
    const foreign = ctx.foreign_semas.get(module_id) orelse return null;
    const fields = decl.symbol().fields orelse return null;
    const f = fields[(try findMember(ctx, fields, name, .method)) orelse return null];
    const fty = ctx.types.get(try importType(ctx, foreign, f.ty, module_id));
    if (fty != .function) return null;
    return .{ .field = f, .fn_ty = fty.function };
}

/// The associated types API `ref` declares (`type Item`): its hidden
/// parameters after `Self`.
pub fn apiAssocParams(ctx: *const SemContext, ref: ApiRef) []const SymbolId {
    const sym = apiSymbol(ctx, ref) orelse return &.{};
    const params = sym.type_params orelse return &.{};
    return if (params.len > 1) params[1..] else &.{};
}

/// Whether API `ref` declares the associated type `name`.
pub fn apiDeclaresAssoc(ctx: *const SemContext, ref: ApiRef, name: []const u8) bool {
    const home = apiContext(ctx, ref) orelse return false;
    for (apiAssocParams(ctx, ref)) |p| if (std.mem.eql(u8, home.symbols.items[p].assoc_of.?.name, name)) return true;
    return false;
}

/// The API through which type parameter `base`'s bounds give it the
/// associated type `name`: one of a program's own that declares it, or
/// `Iter` for `Item`. Null when none does; `ambiguous` when two do.
pub fn assocApiOf(ctx: *const SemContext, base: SymbolId, name: []const u8) std.mem.Allocator.Error!union(enum) { none, ambiguous, one: AssocApi } {
    var found: ?AssocApi = null;
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const sym = ctx.symbols.items[base];
    for (sym.user_apis) |b| for (try apiClosure(ctx, scratch.allocator(), b)) |c| {
        if (!apiDeclaresAssoc(ctx, c, name)) continue;
        const here: AssocApi = .{ .user = .{ .api = c, .via = b } };
        if (found) |f| {
            if (!f.sameApi(here)) return .ambiguous;
        } else found = here;
    };
    if (std.mem.eql(u8, name, "Item") and boundApis(ctx, sym).contains(.Iter)) {
        if (found != null) return .ambiguous;
        found = .iter;
    }
    return if (found) |f| .{ .one = f } else .none;
}

/// The associated type `name` of type parameter `base` by `api`, one
/// symbol however often it is named: an API's own (`Item` of `Self`), one
/// imported with its base, or one made now.
pub fn assocParam(ctx: *SemContext, base: SymbolId, api: AssocApi, name: []const u8) std.mem.Allocator.Error!SymbolId {
    for (ctx.symbols.items[base].assoc) |a| {
        const of = ctx.symbols.items[a].assoc_of.?;
        if (std.mem.eql(u8, of.name, name) and of.api.sameApi(api)) return a;
    }
    const b = ctx.symbols.items[base];
    const id = try ctx.addSymbol(.{
        .name = try ctx.arena.allocator().print("{s}.{s}", .{ b.name, name }),
        .kind = .generic_param,
        .ty = ctx.types.unknown_id,
        .decl_pos = b.decl_pos,
        .scope = scope_invalid,
        .assoc_of = .{ .base = base, .api = api, .name = name },
    });
    ctx.symbols.items[base].assoc = try std.mem.concat(ctx.arena.allocator(), SymbolId, &.{ ctx.symbols.items[base].assoc, &.{id} });
    return id;
}

/// The type `ty` gives associated type `name` of `api`: a type
/// parameter's own (`S.Item`), an iterator's item (`iterItem`), or what a
/// conformance gives it (`conformanceAssoc`); null when `ty` provides no
/// such API.
pub fn assocType(ctx: *SemContext, ty: TypeId, api: AssocApi, name: []const u8) std.mem.Allocator.Error!?TypeId {
    switch (ctx.types.get(ty)) {
        .type_var => |p| switch (try assocApiOf(ctx, p, name)) {
            .one => |found| if (found.sameApi(api)) return try ctx.intern(.{ .type_var = try assocParam(ctx, p, found, name) }),
            else => {},
        },
        else => {},
    }
    return switch (api) {
        .iter => switch (try iterItem(ctx, ty)) {
            .item => |item| item,
            else => null,
        },
        .user => |u| conformanceAssoc(ctx, ty, u.api, name),
    };
}

/// An associated type whose base `subst` replaces is what the base's
/// replacement gives it (`assocType`); null for any other symbol.
fn assocSubst(ctx: *SemContext, sym: SymbolId, subst: TypeSubst) std.mem.Allocator.Error!?TypeId {
    const of = ctx.symbols.items[sym].assoc_of orelse return null;
    const arg = subst.lookup(of.base) orelse return null;
    return assocType(ctx, arg, of.api, of.name);
}

/// What the conformance by which `ty` provides `api` gives its associated
/// type `name`, in this module's types; null when there is none, or it is
/// not known yet.
pub fn conformanceAssoc(ctx: *SemContext, ty: TypeId, api: ApiRef, name: []const u8) std.mem.Allocator.Error!?TypeId {
    const p = (try provides(ctx, ty, api)) orelse return null;
    const c = switch (p) {
        .conformance => |c| c,
        .bound => return null,
    };
    if (c.module_id == ctx.module_id) try inferAssoc(ctx, c.index);
    const found = conformanceOf(ctx, p) orelse return null;
    const binding = for (found.conf.assoc) |b| {
        if (b.api.eql(api) and std.mem.eql(u8, b.name, name)) break b.ty;
    } else return null;
    if (binding == type_invalid) return null;
    const local = if (found.home == @as(*const SemContext, ctx)) binding else try importType(ctx, found.home, binding, c.module_id);
    // In the conformance's own parameters: an addition's, or the generic
    // type's for a header.
    const home_params: []const SymbolId = if (found.conf.kind == .add) found.conf.params else switch (found.home.types.get(found.conf.ty)) {
        .parameterized_nominal => |pn| found.home.symbols.items[pn.sym].type_params orelse &.{},
        else => &.{},
    };
    const args = try conformanceArgs(ctx, ctx.arena.allocator(), ty);
    if (home_params.len == 0 or args.len != home_params.len) return local;
    const params = try ctx.arena.allocator().alloc(SymbolId, home_params.len);
    for (home_params, params) |hp, *lp| lp.* = if (found.home == @as(*const SemContext, ctx)) hp else try proxyOf(ctx, .{ .module_id = c.module_id, .sym = hp });
    return try substituteType(ctx, local, .{ .params = params, .args = args });
}

/// What conformance `index` of this module gives each associated type of
/// its API and those it builds on: what its methods give where the API's
/// required methods name it (`matchAssoc`). One that none names is left
/// unknown (`type_invalid`), which `typecheck.checkApis` reports at the
/// API.
pub fn inferAssoc(ctx: *SemContext, index: u32) std.mem.Allocator.Error!void {
    const conf = &ctx.conformances.items[index];
    if (conf.assoc_state != .pending) return;
    conf.assoc_state = .computing;
    defer ctx.conformances.items[index].assoc_state = .done;
    const a = ctx.arena.allocator();
    var out: std.ArrayList(AssocBinding) = .empty;
    const provider: []const Field = if (conf.kind == .add) conf.methods else blk: {
        const key = nominalDecl(ctx, conf.ty) orelse break :blk &.{};
        break :blk key.symbol().fields orelse &.{};
    };
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    for (try apiClosure(ctx, scratch.allocator(), conf.api)) |api| {
        const home = apiContext(ctx, api) orelse continue;
        const api_sym = apiSymbol(ctx, api) orelse continue;
        for (apiAssocParams(ctx, api)) |param| {
            const pname = home.symbols.items[param].assoc_of.?.name;
            var bound: TypeId = type_invalid;
            for (api_sym.fields orelse &.{}) |f| {
                if (!f.is_method or f.is_default or bound != type_invalid) continue;
                const have = for (provider) |h| {
                    if (h.is_method and std.mem.eql(u8, h.name, f.name)) break h;
                } else continue;
                const pattern = if (home == @as(*const SemContext, ctx)) f.ty else try importType(ctx, home, f.ty, api.module_id);
                const target = if (home == @as(*const SemContext, ctx)) param else try proxyOf(ctx, .{ .module_id = api.module_id, .sym = param });
                bound = matchAssoc(ctx, pattern, have.ty, target, 0) orelse type_invalid;
            }
            try out.append(a, .{ .api = api, .name = pname, .ty = bound });
        }
    }
    ctx.conformances.items[index].assoc = out.items;
}

/// The type `actual` holds where `pattern` holds type parameter `target`,
/// matching the two by their shape; null when `pattern` does not hold it,
/// or the shapes differ before it.
pub fn matchAssoc(ctx: *const SemContext, pattern: TypeId, actual: TypeId, target: SymbolId, depth: u32) ?TypeId {
    if (depth > 32) return null;
    const p = ctx.types.get(pattern);
    const x = ctx.types.get(actual);
    if (p == .type_var and p.type_var == target) return actual;
    // `?String` is the one text view, the type `?Item` takes at `String`.
    if (p == .read_view and x == .string_view) return matchAssoc(ctx, p.read_view, ctx.types.string_id, target, depth + 1);
    switch (p) {
        inline .read_view, .write_view, .shared, .weak, .optional, .range, .callable, .slot => |inner, tag| {
            if (std.meta.activeTag(x) != tag) return null;
            return matchAssoc(ctx, inner, @field(x, @tagName(tag)), target, depth + 1);
        },
        .fallible => |f| {
            if (x != .fallible) return null;
            return matchAssoc(ctx, f.ok, x.fallible.ok, target, depth + 1) orelse matchAssoc(ctx, f.set, x.fallible.set, target, depth + 1);
        },
        .slice => |sl| return if (x == .slice) matchAssoc(ctx, sl.elem, x.slice.elem, target, depth + 1) else null,
        .array => |ar| return if (x == .array) matchAssoc(ctx, ar.elem, x.array.elem, target, depth + 1) else null,
        .parameterized_nominal => |pn| {
            if (x != .parameterized_nominal or x.parameterized_nominal.args.len != pn.args.len) return null;
            for (pn.args, x.parameterized_nominal.args) |pa, xa| if (matchAssoc(ctx, pa, xa, target, depth + 1)) |t| return t;
            return null;
        },
        .function => |f| {
            if (x != .function or x.function.params.len != f.params.len) return null;
            for (f.params, x.function.params) |pa, xa| if (matchAssoc(ctx, pa, xa, target, depth + 1)) |t| return t;
            return matchAssoc(ctx, f.returns, x.function.returns, target, depth + 1);
        },
        else => return null,
    }
}

/// The bounds of a type's parameters as they stand while a method that
/// adds to them is checked (`widenOwnerBounds`), to put back after.
pub const Widened = struct {
    syms: []const SymbolId = &.{},
    apis: []const Apis = &.{},
    user_apis: []const []const ApiRef = &.{},
    outer: []const SymbolId = &.{},
};

/// While the body of a method under bounds (`fun Wrap[T: Print].show(?@)`)
/// is checked, each parameter of its type it bounds has its type's bounds
/// and the method's, so the body does what both name, as any bounded
/// body does; `restoreOwnerBounds` puts them back. A requirement made on
/// such a parameter meanwhile is decided at once (`ownerWidened`), never
/// left for the type's other instances.
pub fn widenOwnerBounds(ctx: *SemContext, type_params: []const SymbolId, bounds: []const OwnerBound) std.mem.Allocator.Error!Widened {
    const a = ctx.arena.allocator();
    var syms: std.ArrayList(SymbolId) = .empty;
    var apis: std.ArrayList(Apis) = .empty;
    var users: std.ArrayList([]const ApiRef) = .empty;
    for (bounds) |b| {
        if (b.param >= type_params.len) continue;
        const p = type_params[b.param];
        if (p == symbol_invalid) continue;
        const sym = &ctx.symbols.items[p];
        try syms.append(a, p);
        try apis.append(a, sym.apis);
        try users.append(a, sym.user_apis);
        sym.apis.setUnion(b.apis);
        sym.user_apis = try std.mem.concat(a, ApiRef, &.{ sym.user_apis, b.user_apis });
    }
    const saved: Widened = .{ .syms = syms.items, .apis = apis.items, .user_apis = users.items, .outer = ctx.widened };
    ctx.widened = try std.mem.concat(a, SymbolId, &.{ ctx.widened, syms.items });
    return saved;
}

/// A parameter a method under bounds widens (`widenOwnerBounds`), with
/// its bounds as they stand while the method is resolved.
pub const WidenedBound = struct { sym: SymbolId, apis: Apis, user_apis: []const ApiRef };

/// The parameters widened now and their bounds, for a check made later
/// under them (`resolve.DeferredCheck.bounds`, through `rewiden`).
pub fn snapshotWidened(ctx: *SemContext) std.mem.Allocator.Error![]const WidenedBound {
    const out = try ctx.arena.allocator().alloc(WidenedBound, ctx.widened.len);
    for (ctx.widened, out) |p, *b| b.* = .{ .sym = p, .apis = ctx.symbols.items[p].apis, .user_apis = ctx.symbols.items[p].user_apis };
    return out;
}

/// Widen the parameters `bounds` names to the bounds it records
/// (`snapshotWidened`); `restoreOwnerBounds` puts them back.
pub fn rewiden(ctx: *SemContext, bounds: []const WidenedBound) std.mem.Allocator.Error!Widened {
    const a = ctx.arena.allocator();
    const syms = try a.alloc(SymbolId, bounds.len);
    const apis = try a.alloc(Apis, bounds.len);
    const users = try a.alloc([]const ApiRef, bounds.len);
    for (bounds, syms, apis, users) |b, *p, *x, *u| {
        const sym = &ctx.symbols.items[b.sym];
        p.* = b.sym;
        x.* = sym.apis;
        u.* = sym.user_apis;
        sym.apis = b.apis;
        sym.user_apis = b.user_apis;
    }
    const saved: Widened = .{ .syms = syms, .apis = apis, .user_apis = users, .outer = ctx.widened };
    ctx.widened = try std.mem.concat(a, SymbolId, &.{ ctx.widened, syms });
    return saved;
}

pub fn restoreOwnerBounds(ctx: *SemContext, w: Widened) void {
    for (w.syms, w.apis, w.user_apis) |p, apis, users| {
        ctx.symbols.items[p].apis = apis;
        ctx.symbols.items[p].user_apis = users;
    }
    ctx.widened = w.outer;
}

/// Whether type parameter `sym` carries the bounds of the method being
/// checked (`widenOwnerBounds`).
pub fn ownerWidened(ctx: *const SemContext, sym: SymbolId) bool {
    return std.mem.findScalar(SymbolId, ctx.widened, sym) != null;
}

/// The bounds a method adds to its type's parameters as written, each
/// with the parameter's name from `type_params` (symbols of `home`):
/// `T: Print`, `T: Print, U: Shape`.
pub fn ownerBoundsText(ctx: *const SemContext, home: *const SemContext, a: std.mem.Allocator, type_params: []const SymbolId, bounds: []const OwnerBound) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bounds) |b| {
        if (b.param >= type_params.len) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{s}: ", .{home.symbols.items[type_params[b.param]].name});
        const start = out.items.len;
        for (b.user_apis) |u| {
            if (out.items.len > start) try out.appendSlice(a, " + ");
            try out.appendSlice(a, try apiName(ctx, u));
        }
        var it = b.apis.iterator();
        while (it.next()) |api| {
            if (out.items.len > start) try out.appendSlice(a, " + ");
            try out.appendSlice(a, @tagName(api));
        }
    }
    return out.items;
}

/// The witnesses a call of a method under `bounds` passes, its type's
/// arguments being `args` (of `ctx`): one for each API of a program's own
/// a bound names, in order. Null when an argument does not provide one,
/// which the call's check reports.
pub fn ownerWitnesses(ctx: *SemContext, bounds: []const OwnerBound, args: []const TypeId) std.mem.Allocator.Error!?[]const Witness {
    var out: std.ArrayList(Witness) = .empty;
    for (bounds) |b| {
        if (b.param >= args.len) return null;
        for (b.user_apis) |u| try out.append(ctx.arena.allocator(), (try witnessFor(ctx, args[b.param], u)) orelse return null);
    }
    return out.items;
}

/// Why `ty`, a type with its own `==` and no hash of its own, cannot be
/// hashed (docs/design/apis.md, Stage 2).
pub fn ownEqUnhashed(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error![]const u8 {
    return ctx.arena.allocator().print("`{s}` declares its own `==`, so it cannot be hashed by its fields; write `sub hash_into(?@, h: !Hasher)`", .{try formatType(ctx, ty)});
}

/// What a value cannot do without `api`, as an error says it.
pub fn cannotDo(api: Api) []const u8 {
    return switch (api) {
        .Copy => "cannot be copied",
        .Clone => "cannot be cloned",
        .Owned => "may hold a loan",
        .Sends => "cannot be sent to another task",
        .Syncs => "cannot be read by several tasks at once",
        .Eq => "cannot be compared with `==`",
        .Hash => "cannot be hashed",
        .Ord => "cannot be ordered",
        .Print => "cannot be printed",
        .Num => "is no number",
        .Integer => "is no integer",
        .Signed => "is no signed number",
        .Iter => "is no iterator",
    };
}

/// `inst` cannot use `pname = arg`, which lacks `api` (`lack`), at `at`.
pub fn reportLack(ctx: *SemContext, at: u32, inst: []const u8, pname: []const u8, arg: TypeId, api: Api, lack: Lack) std.mem.Allocator.Error!void {
    const a = ctx.arena.allocator();
    const aname = try formatType(ctx, arg);
    if (lack.own_eq) return ctx.err(at, "`{s}` cannot use `{s} = {s}`: {s}", .{ inst, pname, aname, try ownEqUnhashed(ctx, lack.ty) });
    try ctx.err(at, "`{s}` cannot use `{s} = {s}`: `{s}` {s}{s}", .{ inst, pname, aname, aname, cannotDo(api), try lackDetail(ctx, a, arg, api, lack) });
}

/// Why `ty` lacks `api` (`lack`), for the end of an error: the fix for a
/// type parameter's bounds or a type's header, or the part that lacks it.
pub fn lackDetail(ctx: *SemContext, a: std.mem.Allocator, ty: TypeId, api: Api, lack: Lack) std.mem.Allocator.Error![]const u8 {
    if (lack.bound) {
        const sym = ctx.types.get(lack.ty).type_var;
        return a.print("; add `{s}` to its bounds: `[{s}: {s}]`", .{ @tagName(api), ctx.symbols.items[sym].name, try formatBounds(ctx, a, ctx.symbols.items[sym], api) });
    }
    if (lack.own_eq) return "";
    if (api == .Iter) return a.print(": {s}", .{(try iterLack(ctx, ty)) orelse "it declares no `fun next(!@) -> T?`"});
    if (lack.path.len > 0) return a.print("; its field `{s}` is a `{s}`", .{ lack.path, try formatType(ctx, lack.ty) });
    if (lack.ty != ty) return a.print("; it holds a `{s}`", .{try formatType(ctx, lack.ty)});
    // A type a module declares gives itself an order, or its own `==`,
    // hashing, or printing, by naming the API on its header.
    if (api == .Ord) if (nominalDecl(ctx, ty)) |decl| {
        const sym = decl.symbol();
        if (sym.decl_pos != builtin_decl_pos and !sym.flags.error_set and !decl.ctx.is_std) {
            const is_enum = for (sym.fields orelse &.{}) |f| {
                if (f.is_variant) break true;
            } else false;
            return a.print("; name `Ord` on its header: `{s} {s}: {s}`", .{ if (is_enum) "enum" else "obj", sym.name, try formatBounds(decl.ctx, a, sym, .Ord) });
        }
    };
    return "";
}

/// A type parameter `ty` (`sym`): what its bounds name; with no bound,
/// nothing, since each instance decides, unless it is a `pub`
/// declaration's (`checkedByBounds`).
fn boundLack(ctx: *const SemContext, ty: TypeId, sym: SymbolId, api: Api) ?Lack {
    if (!checkedByBounds(ctx.symbols.items[sym]) or boundApis(ctx, ctx.symbols.items[sym]).contains(api)) return null;
    return .{ .ty = ty, .bound = true };
}

fn paramsLack(ctx: *SemContext, params: []const SymbolId, api: Api) std.mem.Allocator.Error!?Lack {
    for (params) |p| {
        if (!checkedByBounds(ctx.symbols.items[p]) or boundApis(ctx, ctx.symbols.items[p]).contains(api)) continue;
        return .{ .ty = try ctx.intern(.{ .type_var = p }), .bound = true };
    }
    return null;
}

/// The first type parameter a value of `ty` reaches whose bounds do not
/// name `api`.
fn heldLack(ctx: *SemContext, ty: TypeId, api: Api) std.mem.Allocator.Error!?Lack {
    var params: std.ArrayList(SymbolId) = .empty;
    defer params.deinit(ctx.allocator);
    try reachedTypeVars(ctx, ty, &params, ctx.allocator);
    return paramsLack(ctx, params.items, api);
}

/// Why `ty` has no order (`lacks` of `Ord`): numbers, `Bool`, text, and
/// plain enums are ordered; an object or an enum whose header names
/// `Ord`; an optional, an array, or a slice of ordered values; and a
/// frozen value's handle when its value is ordered.
fn ordLack(ctx: *SemContext, ty: TypeId, depth: u32) std.mem.Allocator.Error!?Lack {
    if (depth > 64) return .{ .ty = ty };
    if (isText(ctx, ty)) return null;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| return boundLack(ctx, ty, sym, .Ord),
        .int, .float, .int_literal, .float_literal, .bool, .slot => return null,
        .read_view, .write_view => |inner| return ordLack(ctx, inner, depth + 1),
        .optional => |inner| return ordLack(ctx, inner, depth + 1),
        // A frozen value never changes, so its handles order by what they
        // reach, as they compare and hash.
        .shared => |inner| return if (frozenValue(ctx, inner)) |value| ordLack(ctx, value, depth + 1) else .{ .ty = ty },
        .array => |arr| return ordLack(ctx, arr.elem, depth + 1),
        .slice => |sl| return ordLack(ctx, sl.elem, depth + 1),
        .nominal, .imported_nominal => {
            if (isOrderedEnum(ctx, ty)) return null;
            const decl = nominalDecl(ctx, ty) orelse return .{ .ty = ty };
            // Its fields were checked where it is declared.
            if (decl.symbol().apis.contains(.Ord)) return null;
            return .{ .ty = ty };
        },
        // A generic type that names `Ord` orders by its fields at its
        // instance's types.
        .parameterized_nominal => |pn| {
            const sym = ctx.symbols.items[pn.sym];
            if (!sym.apis.contains(.Ord)) return .{ .ty = ty };
            const subst: TypeSubst = .{ .params = sym.type_params orelse &.{}, .args = pn.args };
            for (sym.fields orelse &.{}) |f| {
                if (f.is_method) continue;
                const parts: []const Field = if (f.is_variant) f.payload orelse &.{} else &.{f};
                for (parts) |part| {
                    const t = try substituteType(ctx, part.ty, subst);
                    if (try ordLack(ctx, t, depth + 1)) |l| return .{ .ty = l.ty, .path = if (l.path.len > 0) try ctx.arena.allocator().print("{s}.{s}", .{ part.name, l.path }) else part.name, .bound = l.bound };
                }
            }
            return null;
        },
        else => return .{ .ty = ty },
    }
}

/// The types a compared value holds, walked depth first with an explicit
/// stack, so a long chain of types does not nest the walk. Each is in
/// `ctx`'s store: the field types of another module's struct are
/// imported there, and a generic instance's have its type arguments
/// applied.
const EquatableWalk = struct {
    ctx: *SemContext,
    params: ?*std.ArrayList(SymbolId),
    /// For `.hash()`: a float is not taken (`notHashable`).
    hashing: bool = false,
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
            // A vector's `==` is lane by lane, a mask, not one `Bool`.
            .simd => return .lanes,
            .float, .float_literal => if (self.hashing) return .float,
            .slice => |sl| if (item.in_decl) return .view else try self.push(i, sl.elem, ""),
            .read_view, .write_view => return .view,
            // A frozen value never changes, so its handles compare, and
            // hash, by what they reach.
            .shared => |inner| if (frozenValue(ctx, inner)) |value| try self.push(i, value, "") else return if (ctx.types.get(inner) == .function) .closure else .handle,
            .weak => return .handle,
            .function => return .function,
            .api_object => return .object,
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
        // An error set compares by its member and the member's fields, as
        // an enum does by its variant; a union, as the sets it joins.
        if (sym.error_parts) |parts| {
            if ((try self.visited.getOrPut(ctx.allocator, ty)).found_existing) return null;
            for (parts) |part| try self.push(i, if (decl.module_id) |m| try importType(ctx, decl.ctx, part, m) else part, "");
            return null;
        }
        // A type that gives `==` or hashing its own meaning is compared or
        // hashed by its own method, whatever its fields; one with its own
        // `==` and no hash of its own has no hash by its fields.
        if (self.hashing) {
            if (ownApiMethod(sym, .Hash) != null) return null;
            if (ownApiMethod(sym, .Eq) != null) return .own_eq;
        } else if (ownApiMethod(sym, .Eq) != null) return null;
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
        .bool, .int, .float, .string_view, .static, .symbol, .int_literal, .float_literal, .slot => true,
        else => false,
    };
}

/// Whether a value of `ty` is or holds a vector inline: in a field, a
/// payload, an array, an optional, or a generic instance's argument held
/// by value (a List's or a box's elements are on the heap). Its size and
/// alignment are the target's, so `$size` and `$align` take no such type.
pub fn holdsVector(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).vector;
}

/// A scalar: a primitive that copies, or a vector (`Simd[T, n]`), one
/// value held in registers. An operator reads a view of one as its value,
/// and a method takes one by value, never by address.
pub fn isScalar(ctx: *const SemContext, ty: TypeId) bool {
    return isCopyPrimitive(ctx, ty) or ctx.types.get(ty) == .simd;
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
/// Whether a write may go through a view binding.
pub const Access = enum { read, write };

/// How a `match` reaches what its bindings bind.
pub const MatchReach = enum {
    /// `match !x`, or a write view the subject makes (a call's, or a
    /// branch of write lends), lent on as `if … as` lends one on.
    written,
    /// A read match of a value another holds: a place, a lend, a read
    /// view a call returns, a value that branches over places, or a
    /// part of a value made in the header.
    read,
    /// A read match of a value made there, which it holds whole.
    read_own,
    /// `match <x`, or a value made there that owns: taken.
    owned,
};

/// How an `if … as x` or `while … as x` reaches the value inside.
pub const AsReach = enum {
    /// `!o`, or a write view the header makes.
    written,
    /// Viewed where it is, or read through a view.
    read,
    /// Taken: a value made in the header, or moved with `<o`, which the
    /// binding owns, a write view included.
    taken,
    /// Copied out of the optional: plain data, or a view, which a copy
    /// only reads.
    copied,
};

/// What a binding is, for `decideBindingAccess`.
pub const BindingSite = union(enum) {
    /// A payload field of a `match`, or its catch-all: how the match
    /// reaches the subject, and the type of the field or subject.
    match: struct { reach: MatchReach, reached: TypeId },
    /// `if … as x` / `while … as x`, and the type of the value inside.
    as: struct { reach: AsReach, inner: TypeId },
    /// A `for` element: whether the loop writes (`for x in !v`), takes
    /// (`for x in <v`), or reads its elements, and the element's type.
    loop: struct { mode: LoopMode, elem: TypeId },
    /// A parameter, a local, or a closure capture, by its declared or
    /// inferred type: a capture's is the lend its sigil writes
    /// (`|?x|`, `|!x|`) or the value it copies or moves in.
    declared: TypeId,
};

pub const LoopMode = enum { write, take, read };

/// Whether a write may go through the binding `site` describes; null for
/// one that is no view: it owns or copies what it binds. The one decider
/// of a binding's mode (docs/internals/INTERNALS.md, "Binding access"), by a
/// positive list over every kind of binding. Typecheck derives the
/// binding's type from it, ownership the loan a lend of it makes
/// (`lendTarget`), and emit how it binds.
pub fn decideBindingAccess(ctx: *const SemContext, site: BindingSite) ?Access {
    return switch (site) {
        // A parameter, local, or capture is the view its type is.
        .declared => |ty| switch (ctx.types.get(ty)) {
            .write_view => .write,
            .read_view => .read,
            else => null,
        },
        .as => |a| switch (a.reach) {
            .written => .write,
            .read => .read,
            .taken => decideBindingAccess(ctx, .{ .declared = a.inner }),
            // A copy of a view only reads; plain data owns nothing.
            .copied => switch (ctx.types.get(a.inner)) {
                .read_view, .write_view => .read,
                else => null,
            },
        },
        .loop => |l| switch (l.mode) {
            .write => .write,
            .take => decideBindingAccess(ctx, .{ .declared = l.elem }),
            // An element that copies is a copy; any other is viewed.
            .read => if (copies(ctx, l.elem) == .no) .read else decideBindingAccess(ctx, .{ .declared = l.elem }),
        },
        .match => |m| switch (m.reach) {
            .owned => decideBindingAccess(ctx, .{ .declared = m.reached }),
            else => switch (ctx.types.get(m.reached)) {
                .read_view => .read,
                // A write view is written through only where the match
                // writes, or holds the value whole: a read match of a
                // value another holds never writes through its binding,
                // whatever the subject.
                .write_view => if (m.reach == .written or m.reach == .read_own) .write else .read,
                // A slice is bound as the copy it is.
                .slice => null,
                // `match !e` views any other field to write. A read copies
                // plain data and views anything else; a type parameter's
                // value is viewed where the match reads a value another
                // holds, and copied out of one it holds whole.
                else => if (m.reach == .written) .write else switch (copies(ctx, m.reached)) {
                    .yes => null,
                    .no => .read,
                    .depends => if (m.reach == .read) .read else null,
                },
            },
        },
    };
}

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

/// The type a store through write view `ty` writes: the `T` of `!T`,
/// one view peeled, so a `T` that is itself a view (`!?P`) is re-pointed,
/// not replaced. Any other type is its own.
pub fn writtenThrough(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .write_view => |inner| inner,
        else => ty,
    };
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

/// A String (boxed or not, or viewed), a `?String`, or a `Static`: `==`
/// compares any two of them by their bytes, and a `match` on one takes
/// string patterns. A shared handle `*String` is not text: a handle has
/// no `==` or `.hash()`.
pub fn isText(ctx: *const SemContext, ty: TypeId) bool {
    if (accessThroughShared(ctx, ty)) return false;
    const t = if (unwrapAccess(ctx, ty) == ctx.types.string_id) ctx.types.string_id else ty;
    return t == ctx.types.string_id or t == ctx.types.string_view_id or t == ctx.types.static_id;
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
            .read_view, .write_view => |inner| id = inner,
            // A frozen value's handle reaches the value it froze.
            .shared => |inner| id = frozenValue(ctx, inner) orelse inner,
            else => return id,
        }
    }
}

/// The struct or enum a `^T` (or a view or handle of one) holds,
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

/// `T` of a `^T`; null for any other type.
pub fn boxedType(ctx: *const SemContext, ty_id: TypeId) ?TypeId {
    return switch (ctx.types.get(ty_id)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.box_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// One of the built-in enums, `Endian` and `Arch`: the runtime's own
/// type, one in every module.
pub fn isBuiltinEnum(ctx: *const SemContext, sym: SymbolId) bool {
    return sym == ctx.endian_sym_id or sym == ctx.arch_sym_id or sym == ctx.order_sym_id;
}

/// One of the built-in generic types: `Cell`, `List`, `^T`, `Signal`,
/// `Task`, `Tasks`.
pub fn isBuiltinGeneric(ctx: *const SemContext, sym: SymbolId) bool {
    return isHeapBuiltin(ctx, sym) or sym == ctx.cell_sym_id or sym == ctx.signal_sym_id or sym == ctx.actor_sym_id or sym == ctx.chan_sym_id or sym == ctx.frozen_sym_id or sym == ctx.task_sym_id or sym == ctx.tasks_sym_id;
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
/// handle (`unwrapAccess`): `*S`, or a view of one, through any boxes a
/// generic instance puts around it. Nothing is written there, since
/// other handles may exist.
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
        .type_var => |sym| return subst.lookup(sym) orelse (try assocSubst(ctx, sym, subst)) orelse ty_id,
        .ct_param => |sym| return subst.lookup(sym) orelse ty_id,
        inline .read_view, .write_view, .shared, .weak, .optional, .range, .callable, .slot => |inner, tag| {
            const new_inner = try substituteType(ctx, inner, subst);
            if (new_inner == inner) return ty_id;
            // A count with no slots is reported where the instance is made
            // (`Requirement.slot_count`); the slot type is poison.
            if (tag == .slot and ctx.types.get(new_inner) == .ct_value and slotCount(ctx, new_inner) == null) return ctx.types.invalid_id;
            return ctx.intern(@unionInit(Type, @tagName(tag), new_inner));
        },
        .fallible => |f| {
            const ok = try substituteType(ctx, f.ok, subst);
            const set = try substituteType(ctx, f.set, subst);
            if (ok == f.ok and set == f.set) return ty_id;
            return ctx.intern(.{ .fallible = .{ .ok = ok, .set = set } });
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
        .simd => |v| {
            const e = try substituteType(ctx, v.elem, subst);
            const n = try substituteType(ctx, v.len, subst);
            if (e == v.elem and n == v.len) return ty_id;
            // A lane count out of range is reported where the instance is
            // made (`Requirement.lane_count`); the vector is poison.
            if (ctx.types.get(n) == .ct_value and simdLen(ctx, .{ .elem = e, .len = n }) == null) return ctx.types.invalid_id;
            return ctx.intern(.{ .simd = .{ .elem = e, .len = n } });
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
            return ctx.internCopy(.{ .parameterized_nominal = .{ .sym = pn.sym, .args = args.items, .inline_len = pn.inline_len } });
        },
        .results => |parts| {
            var out: std.ArrayList(TypeId) = .empty;
            defer out.deinit(ctx.allocator);
            for (parts) |part| try out.append(ctx.allocator, try substituteType(ctx, part, subst));
            if (std.mem.eql(TypeId, out.items, parts)) return ty_id;
            return ctx.internCopy(.{ .results = out.items });
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

/// The parameter compile-time slot `i` of `f` binds in an instance: a
/// type parameter, or an integer value parameter (`intParamOf`); null
/// for a value an instance does not bind (`mode: Mode`). The one
/// classifier of a function's own compile-time parameters, which
/// `typecheck.instantiateCall` binds and `implInstance` reads.
pub fn ownParamOf(ctx: *const SemContext, f: FunctionType, i: usize) ?SymbolId {
    return typeParamOf(ctx, f.ct_params[i]) orelse intParamOf(ctx, f, i);
}

/// The symbol of compile-time slot `i` of `f` when it is an integer
/// value parameter (`n: Int`), which an instance binds; null for any
/// other slot.
pub fn intParamOf(ctx: *const SemContext, f: FunctionType, i: usize) ?SymbolId {
    if (i >= f.ct_syms.len or f.ct_syms[i] == symbol_invalid) return null;
    if (ctx.types.get(f.ct_params[i]) != .int) return null;
    return f.ct_syms[i];
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
/// with whatever holds it). A value that holds a Cell is no scalar.
/// `rig.ReadView` applies the same rule to Zig types, for a
/// generic `?T`.
pub fn lendByValue(ctx: *const SemContext, inner: TypeId) bool {
    if (typeHasDropGlue(ctx, inner) or maybeDropGlue(ctx, inner)) return false;
    return copiedByReadView(ctx, inner);
}

/// A type a read view copies: a number, `Bool`, `?String`, a slice, a
/// read view, a function or callable view (a `rig.FnRef`), a vector, a
/// plain enum, an error of a set without fields (a Zig error), or an
/// optional of one of those. An error that is a `rig.ErrorValue`
/// (`isErrorValueForm`) is a struct, and lent by address. The runtime's
/// `ReadView` holds a generic `?T` by the same rule, read off the Zig
/// type each of these is.
fn copiedByReadView(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .bool, .string_view, .static, .symbol, .int, .float, .int_literal, .float_literal, .none_literal, .slice, .function, .callable, .simd, .slot, .read_view => true,
        .write_view => writeSliceElem(ctx, ty) != null,
        .optional => |inner| copiedByReadView(ctx, inner),
        .nominal, .imported_nominal => isPlainEnum(ctx, ty) or (isErrorSet(ctx, ty) and !isErrorValueForm(ctx, ty)),
        else => false,
    };
}

/// Whether a value of `ty` holds a `Cell` inline (not behind a handle,
/// a view, or a List's buffer). A read view of such a value is held as
/// a pointer, since the cell can change while it is lent.
pub fn holdsCellByValue(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).cell;
}

/// Whether a value of `ty` changes through a shared handle, by a marked
/// call (`!c.set(5)`): a `Cell`, a `Signal`, or a value that holds a
/// Cell by value. The one list of what a write lend may reach through a
/// `*`; a write view of such a value changes only its Cells and
/// Signals, never its other fields (`Checker.placeOf`).
pub fn changesByMark(ctx: *const SemContext, ty: TypeId) bool {
    const t = unwrapAccess(ctx, ty);
    return switch (ctx.types.get(t)) {
        .parameterized_nominal => |pn| pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id or holdsCellByValue(ctx, t),
        else => holdsCellByValue(ctx, t),
    };
}

/// One machine word, which every change to it replaces at once: an
/// `Int`, a `Bool`, a `Float`, or a plain enum.
pub fn isWordValue(ctx: *const SemContext, ty: TypeId) bool {
    return ty == ctx.types.int_id or ty == ctx.types.bool_id or ty == ctx.types.float_id or isPlainEnum(ctx, ty);
}

/// Whether `ty` is a `Cell` of one word (`isWordValue`): many tasks may
/// change it at once, through handles of their own.
pub fn isWordCell(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym == ctx.cell_sym_id and pn.args.len == 1 and isWordValue(ctx, pn.args[0]),
        else => false,
    };
}

/// The `T` of a `Chan[T]`, or null for any other type.
pub fn chanValue(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.chan_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// The `T` of the `Chan[T]` a handle `*Chan[T]`, or a view of one,
/// reaches; null for any other type.
pub fn chanOfHandle(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .shared => |inner| chanValue(ctx, inner),
        else => null,
    };
}

/// The `T` of an `Actor[T]`, or null for any other type.
pub fn actorValue(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.actor_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// The `T` of the actor a handle reaches, `*Actor[T]` or a view of one;
/// null for any other type.
pub fn actorOfHandle(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .shared => |inner| actorValue(ctx, inner),
        else => null,
    };
}

/// The `T` of a `Frozen[T]`, or null for any other type.
pub fn frozenValue(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.frozen_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// The `T` of the frozen value a handle `*Frozen[T]`, or a view of one,
/// reaches; null for any other type.
pub fn frozenOfHandle(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(unwrapViews(ctx, ty))) {
        .shared => |inner| frozenValue(ctx, inner),
        else => null,
    };
}

/// Whether a `*` handle to `inner` counts its handles atomically, and so
/// goes to other tasks: a Cell of one word's, an actor's, a channel's, a
/// frozen value's, or a `*{A + Syncs}`'s, which holds a frozen value
/// (`frozenObject`). The one test of whether a count is atomic; the
/// runtime's `synchronized` makes the same choice.
pub fn atomicHandle(ctx: *const SemContext, inner: TypeId) bool {
    return isWordCell(ctx, inner) or actorValue(ctx, inner) != null or chanValue(ctx, inner) != null or frozenValue(ctx, inner) != null or frozenObject(ctx, inner);
}

/// Whether `ty` is a `Cell[T]`.
pub fn isCell(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym == ctx.cell_sym_id,
        else => false,
    };
}

/// Where a value of some type stands, as `misplaced` sees it.
pub const Home = enum {
    /// A struct field, or an enum variant's payload field.
    field,
    /// A parameter, a receiver, or a function's result.
    signature,
    /// A local, or what a header or a pattern binds.
    binding,
    /// A type argument of a generic type or function.
    type_arg,
    /// An array's or a slice's element.
    element,
    /// The value inside an optional, `T?`.
    optional,
    /// What a view, `?T` or `!T`, views.
    viewed,
    /// What a handle, `*T` or `~T`, holds.
    handle,
};

/// What may not stand where `misplaced` says.
pub const Misplaced = enum { cell, write_view, unsized, frozen };

/// The one decider of where a Cell, a write view, and an API object may
/// stand (Core §1), by a positive list of homes:
/// - An API object, `{Shape}`, has no size of its own: it stands only
///   behind a view (`.viewed`), a box (`^{Shape}`, which holds it
///   through its allocation), or a handle (`*{Shape}`, `~{Shape}`), never
///   as a value's, an element's, or a type argument's type, written or
///   inferred (docs/design/apis.md, Stages 4 and 5).
/// - A value that holds a Cell by value lives only behind a shared
///   handle: such a type stands in a field (of a value itself so held),
///   behind `*` or `~`, or behind a view. A type that holds one through
///   an element or an optional is reported there, so here only a
///   declared type that holds one counts (`holdsOwnCell`); a type
///   argument counts however it holds one.
/// - A write view is never stored inside a value (`writeViewMisplaced`).
/// - A frozen value, `Frozen[T]`, lives only behind `*`, whose
///   allocation holds it: never a value's, an element's, or a type
///   argument's type, written or inferred, so no generic `*T` or `~T`
///   stands for a frozen value's handle.
/// Null where `ty` may stand at `home`. The Cell rule needs what every
/// type holds (`SemContext.contents_ready`).
pub fn misplaced(ctx: *const SemContext, ty: TypeId, home: Home) ?Misplaced {
    if (unsizedAt(ctx, ty, home)) return .unsized;
    if (writeViewMisplaced(ctx, ty, home)) return .write_view;
    if (frozenMisplaced(ctx, ty, home)) return .frozen;
    switch (home) {
        .field, .handle, .viewed => {},
        .type_arg => if (holdsCellByValue(ctx, ty)) return .cell,
        .signature, .binding, .element, .optional => if (holdsOwnCell(ctx, ty)) return .cell,
    }
    return null;
}

/// Whether `ty` is a frozen value, `Frozen[T]`, at a home other than
/// behind `*` (`Misplaced.frozen`). Decided by the type's structure alone,
/// so a type is rejected where it is written.
pub fn frozenMisplaced(ctx: *const SemContext, ty: TypeId, home: Home) bool {
    return home != .handle and frozenValue(ctx, ty) != null;
}

/// Whether `ty` is a bare API object, `{Shape}`, which has no size of its
/// own, at a home other than behind a view or a handle
/// (`Misplaced.unsized`).
/// Decided by the type's structure alone, so a type is rejected where it
/// is written, before what types hold is known.
pub fn unsizedAt(ctx: *const SemContext, ty: TypeId, home: Home) bool {
    return home != .viewed and home != .handle and apiObject(ctx, ty) != null;
}

/// Whether `ty`, a write view or a value that holds one anywhere
/// (`nestsWriteView`), may not stand at `home`: `!T`, `(!T)?`, and
/// `(!T)!` stand only in a signature or a binding, and `!T` inside an
/// optional; never in a field, an element, a type argument, or behind a
/// view or a handle. Decided by the type's structure alone, so a type
/// is rejected where it is written, before what types hold is known.
pub fn writeViewMisplaced(ctx: *const SemContext, ty: TypeId, home: Home) bool {
    if (!nestsWriteView(ctx, ty)) return false;
    return switch (home) {
        .signature, .binding => !isHeldWriteView(ctx, ty),
        .optional => ctx.types.get(ty) != .write_view,
        .field, .type_arg, .element, .viewed, .handle => true,
    };
}

/// `!T`, `(!T)?`, `(!T)!`, or `((!T)?)!`. What the write view views was
/// decided where it was written, as `.viewed`.
fn isHeldWriteView(ctx: *const SemContext, ty: TypeId) bool {
    var t = ty;
    if (ctx.types.get(t) == .fallible) t = ctx.types.get(t).fallible.ok;
    if (ctx.types.get(t) == .optional) t = ctx.types.get(t).optional;
    return ctx.types.get(t) == .write_view;
}

/// Whether `ty` is a write view or holds one anywhere in its structure,
/// through views, handles, optionals, elements, and type arguments. A
/// declared type's fields are decided where they are declared.
fn nestsWriteView(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .write_view => true,
        .read_view, .shared, .weak, .optional => |inner| nestsWriteView(ctx, inner),
        .fallible => |inner| nestsWriteView(ctx, inner.ok),
        .array => |a| nestsWriteView(ctx, a.elem),
        .slice => |s| nestsWriteView(ctx, s.elem),
        .parameterized_nominal => |pn| for (pn.args) |a| {
            if (nestsWriteView(ctx, a)) break true;
        } else false,
        else => false,
    };
}

/// Whether `ty` is a declared type (a `Cell[T]` included) that holds a
/// Cell by value through its own fields, not only through a type
/// argument, which is decided where it stands.
fn holdsOwnCell(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .nominal, .imported_nominal => holdsCellByValue(ctx, ty),
        .parameterized_nominal => |pn| pn.sym == ctx.cell_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id or (holdsCellByValue(ctx, ty) and for (pn.args) |a| {
            if (holdsCellByValue(ctx, a)) break false;
        } else true),
        else => false,
    };
}

/// The diagnostics of `misplaced`: a Cell's formatted with the type
/// twice, a write view's once.
pub const cell_misplaced = "a value of `{s}` holds a Cell, so it lives only behind a shared handle: write `*{s}`";
/// A bare API object where a value's type goes (`Misplaced.unsized`).
pub const object_unsized = "`{s}` has no size of its own: hold it behind a view, a box, or a handle, `?{s}`, `!{s}`, `^{s}`, or `*{s}`";

/// A bare API object as an instance's type argument, inferred or
/// written (`Misplaced.unsized`): no value has its type, so a generic
/// body would write a value of one type where another lives.
pub const object_unsized_arg = "`{s}` has no size of its own, so it is no type argument, written or inferred";

/// A frozen value where a value's type goes (`Misplaced.frozen`).
pub const frozen_misplaced = "a frozen value lives only behind a shared handle: write `*{s}`";

/// A frozen value as an instance's type argument, inferred or written
/// (`Misplaced.frozen`): a generic `*T` would be a plain count of it, and
/// a `~T` a weak handle of a frozen value, which has none.
pub const frozen_misplaced_arg = "a frozen value lives only behind its handle, so `{s}` is no type argument, written or inferred: pass the handle whole where a `T` goes, `*{s}`";

/// An error that a form holding an API object is not built yet (a Cell
/// of one, Stage 5's), remembered so that `recordType` reports none
/// after it.
pub fn objectUnbuiltError(ctx: *SemContext, pos: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const at = ctx.diagnostics.items.len;
    try ctx.err(pos, fmt, args);
    if (ctx.diagnostics.items.len > at) ctx.object_unbuilt_at = at;
}

/// Whether a report of `objectUnbuiltError` still stands, so the module
/// is rejected: an error remains where it was recorded.
pub fn objectRejected(ctx: *const SemContext) bool {
    const at = ctx.object_unbuilt_at orelse return false;
    if (at >= ctx.diagnostics.items.len) return false;
    const d = ctx.diagnostics.items[at];
    return d.severity == .@"error" and !d.lint;
}

pub const write_view_misplaced = "a write view is never stored inside a value, and `{s}` cannot stand here: `!T` is only a parameter's, `self`'s, a result's, or a binding's type, also as `(!T)?`; hold the value itself, or pass `!x` to each call that changes it";

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

/// Whether a value of `ty` holds a marked view or a `?String`, which may view a
/// String: the ownership checker tracks the loans such a value carries.
pub fn mayHoldView(ctx: *const SemContext, ty: TypeId) bool {
    const b = ctx.holds(ty).views;
    return b.marked or b.string_view;
}

/// An arm of `task.select`: `(!ch).on_recv(f)` or `(!ch).on_send(<v, f)`.
pub const SelectArm = enum { recv, send };

/// Whether `ty` is a task, `Task[T]`.
pub fn isTask(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym == ctx.task_sym_id,
        else => false,
    };
}

/// Whether `ty` is a set of tasks, `Tasks[T]`.
pub fn isTaskSet(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn.sym == ctx.tasks_sym_id,
        else => false,
    };
}

/// The `T` of a `Task[T]` or a `Tasks[T]`: what each of its tasks gives.
pub fn taskResult(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if ((pn.sym == ctx.task_sym_id or pn.sym == ctx.tasks_sym_id) and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

/// The two facts that say what may go to a task on another core
/// (docs/design/concurrency.md, "What may cross cores"): a value that `moves`
/// can be handed whole to another thread, and one that `shares` can be
/// read through a view by another thread while this one also reads it.
pub const Crossing = enum { moves, shares };

/// `par.map(?xs, f)`, which gives each call's value, or `par.each(!xs,
/// f)`, which writes each element.
pub const ParCall = enum { map, each };

/// Whether a value of `ty` meets `how` (`Crossing`): nothing it reaches
/// is a `*T` or `~T`, whose counts are not atomic, a `Cell` or a
/// `Signal`, which change through handles on this core, a set of tasks,
/// or a callable view `?fun`, whose captures its type does not show. A
/// function value, `fun(A) -> R`, is a named function's address and
/// crosses.
/// A `*Cell` of one word crosses (`isWordCell`): its counts and its
/// changes are atomic instructions. A read view crosses when what it
/// views shares; a write view and a `Task` move when what they hold
/// moves, and never share. Where it cannot see what a type holds, it
/// says no.
pub fn crosses(ctx: *const SemContext, ty: TypeId, how: Crossing) bool {
    return blockerOf(ctx, ty, how) == null;
}

/// A type that blocks a crossing, in the table of the module that declares
/// it: one in a field of another module's object is that module's
/// (`module`, its id), not the caller's.
pub const Blocker = struct {
    ctx: *const SemContext,
    ty: TypeId,
    module: ?u32 = null,
};

/// `b`'s type in `ctx`'s own table, imported when another module's.
fn localized(ctx: *SemContext, b: Blocker) std.mem.Allocator.Error!TypeId {
    if (b.ctx == ctx) return b.ty;
    return importType(ctx, b.ctx, b.ty, b.module orelse return ctx.types.invalid_id);
}

/// What in `ty` keeps it from meeting `how` (`crosses`): the innermost
/// type that does not, or null when it does, in `ctx`'s own table.
pub fn crossingBlocker(ctx: *SemContext, ty: TypeId, how: Crossing) std.mem.Allocator.Error!?TypeId {
    const b = blockerOf(ctx, ty, how) orelse return null;
    return try localized(ctx, b);
}

/// `crossingBlocker`, in the table of the module that declares the
/// blocker.
fn blockerOf(ctx: *const SemContext, ty: TypeId, how: Crossing) ?Blocker {
    var walk: Walk = .{};
    defer walk.seen.deinit(ctx.allocator);
    if (blockerIn(ctx, ty, how, false, &walk)) |b| return b;
    if (boundBlocker(ctx, ty, how)) |t| return .{ .ctx = ctx, .ty = t };
    return null;
}

/// A type parameter `ty` reaches whose bounds do not name `Sends` (or
/// `Syncs`, by `how`): a bounded `T`, or a `pub` declaration's, crosses
/// only as its bounds say; any other as each instance does.
fn boundBlocker(ctx: *const SemContext, ty: TypeId, how: Crossing) ?TypeId {
    if (!ctx.typeInfo(ty).has_type_var) return null;
    var params: std.ArrayList(SymbolId) = .empty;
    defer params.deinit(ctx.allocator);
    reachedTypeVars(ctx, ty, &params, ctx.allocator) catch return null;
    for (params.items) |p| {
        if (!checkedByBounds(ctx.symbols.items[p]) or boundApis(ctx, ctx.symbols.items[p]).contains(if (how == .moves) .Sends else .Syncs)) continue;
        return ctx.types.find(.{ .type_var = p }) orelse ty;
    }
    return null;
}

/// What in `ty` keeps it from going to a local task as `how` says: one
/// pinned to the thread of the task that makes it, so values that stay on
/// one thread go to it (a `*T` or `~T` whose counts are not atomic, a
/// `Cell`, a `Signal`). What still stops it: a set of tasks, a task or a
/// write view lent to read, a callable view `?fun`, whose captures may
/// lend to write, an owned closure (`*fun`, `~fun`), and a channel's
/// elements, which go to any task.
pub fn localBlocker(ctx: *SemContext, ty: TypeId, how: Crossing) std.mem.Allocator.Error!?TypeId {
    return taskBlocker(ctx, ty, .{ .how = how, .local = true });
}

/// What in `ty` keeps it from going to a task as `reach` says: to a
/// local one (`localBlocker`), or to any (`crossingBlocker` without a
/// type parameter's bounds).
pub fn taskBlocker(ctx: *SemContext, ty: TypeId, reach: TaskReach) std.mem.Allocator.Error!?TypeId {
    var walk: Walk = .{};
    defer walk.seen.deinit(ctx.allocator);
    const b = blockerIn(ctx, ty, reach.how, reach.local, &walk) orelse return null;
    return try localized(ctx, b);
}

/// How a value goes to a task: as `how` says, and to a local one or to
/// any, which may run on another core (`blockerIn`'s `local`).
pub const TaskReach = struct { how: Crossing, local: bool };

/// A type parameter a value going to a task holds, and how it goes.
pub const TaskParam = struct { param: SymbolId, reach: TaskReach };

/// The type parameters a value of `ty`, going to a task as `reach`
/// says, holds where `blockerIn` looks, added to `out`. Each instance's
/// type for one must go as it does (`Requirement.task`), as a value of a
/// known type must: to a local task, nothing that goes to none (an owned
/// closure in a `T`); to one that may run on another core, nothing that
/// stays on one thread.
pub fn taskParams(ctx: *const SemContext, ty: TypeId, reach: TaskReach, out: *std.ArrayList(TaskParam)) std.mem.Allocator.Error!void {
    if (!ctx.typeInfo(ty).has_type_var) return;
    var walk: Walk = .{ .reached = out };
    defer walk.seen.deinit(ctx.allocator);
    _ = blockerIn(ctx, ty, reach.how, reach.local, &walk);
    if (walk.failed) return error.OutOfMemory;
}

const SymbolKey = struct { ctx: *const SemContext, sym: SymbolId };

/// A walk of `blockerIn`: the declared types it has looked into, and,
/// when collected, the type parameters it reaches (`taskParams`).
const Walk = struct {
    seen: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty,
    reached: ?*std.ArrayList(TaskParam) = null,
    failed: bool = false,
};

/// Whether a `*` or `~` handle's `inner` is an owned closure, `*fun` or
/// `~fun`, which goes to no task.
fn ownedClosure(ctx: *const SemContext, inner: TypeId) bool {
    return ctx.types.get(inner) == .function;
}

/// `local`: what a local task may not take (`localBlocker`).
fn blockerIn(ctx: *const SemContext, ty: TypeId, how: Crossing, local: bool, walk: *Walk) ?Blocker {
    const here: Blocker = .{ .ctx = ctx, .ty = ty };
    return switch (ctx.types.get(ty)) {
        // A Cell of one word's handle, and an actor's, strong or weak,
        // count atomically, and what they reach changes one task at a
        // time. A channel's elements go to any task. A local task reads
        // what another handle reaches on the same thread.
        // A frozen value's handle reads, from any task, what never changes.
        .shared => |inner| if (atomicHandle(ctx, inner)) atomicReach(ctx, inner, walk) else if (local and !ownedClosure(ctx, inner)) blockerIn(ctx, inner, .shares, local, walk) else here,
        .weak => |inner| if (actorValue(ctx, inner) != null) null else if (local and !ownedClosure(ctx, inner)) blockerIn(ctx, inner, .shares, local, walk) else here,
        // A function value is a named function's address and holds
        // nothing (Core §7); a callable view may view a closure's
        // captures, which its type does not show.
        .function => null,
        .callable => here,
        // An API object's erased type may hold anything, what goes to no
        // task included (an owned closure, a set of tasks): it goes to a
        // task only by the bound its braces or API name, checked on the
        // hidden value where it is erased (docs/design/apis.md, Stage 5),
        // and without it to none, a local one included. Its form's row is
        // the wrappers' above: a read view reaches it to share, a write
        // view and a box as they go.
        .api_object => |o| if (objectBounds(ctx, o).contains(crossingBound(how))) null else here,
        // A type parameter goes as each instance's type does
        // (`taskParams`).
        .type_var => |param| blk: {
            const out = walk.reached orelse break :blk null;
            out.append(ctx.allocator, .{ .param = param, .reach = .{ .how = how, .local = local } }) catch {
                walk.failed = true;
            };
            break :blk null;
        },
        .read_view => |inner| blockerIn(ctx, inner, .shares, local, walk),
        .write_view => |inner| if (how == .shares) here else blockerIn(ctx, inner, .moves, local, walk),
        .optional, .range => |inner| blockerIn(ctx, inner, how, local, walk),
        .fallible => |inner| blockerIn(ctx, inner.ok, how, local, walk),
        .array => |a| blockerIn(ctx, a.elem, how, local, walk),
        .slice => |sl| blockerIn(ctx, sl.elem, how, local, walk),
        .results => |parts| for (parts) |part| {
            if (blockerIn(ctx, part, how, local, walk)) |b| break b;
        } else null,
        .parameterized_nominal => |pn| blk: {
            if (local and (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id)) break :blk null;
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id or pn.sym == ctx.tasks_sym_id) break :blk here;
            if (pn.sym == ctx.task_sym_id and how == .shares) break :blk here;
            for (pn.args) |a| if (blockerIn(ctx, a, how, local, walk)) |b| break :blk b;
            if (pn.sym == ctx.task_sym_id or isBuiltinGeneric(ctx, pn.sym) or pn.sym == ctx.simd_sym_id) break :blk null;
            break :blk fieldsBlock(ctx, pn.sym, how, local, walk);
        },
        .nominal => |sym| fieldsBlock(ctx, sym, how, local, walk),
        .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk here;
            var found = fieldsBlock(decl.ctx, decl.sym, how, local, walk) orelse break :blk null;
            if (found.module == null) found.module = decl.module_id;
            break :blk found;
        },
        else => null,
    };
}

/// What a handle counted atomically (`atomicHandle`) to `inner` hands to
/// other tasks that may keep it from going there: a channel's elements,
/// which move; a frozen value, which holds only what never changes
/// (`frozenIn`); nothing of a Cell's or an actor's.
fn atomicReach(ctx: *const SemContext, inner: TypeId, walk: *Walk) ?Blocker {
    if (chanValue(ctx, inner)) |t| return blockerIn(ctx, t, .moves, false, walk);
    if (frozenValue(ctx, inner)) |t| return frozenIn(ctx, t, &walk.seen);
    return null;
}

/// What in `ty` keeps a frozen value from holding it, in `ctx`'s own
/// table, or null when nothing does: a frozen value holds only data that
/// never changes and goes to any task, so plain data, owners, `String`s,
/// `List`s, objects and enums of such, and other frozen values. A generic
/// parameter with no bound is checked in each instance.
pub fn frozenBlocker(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?TypeId {
    var seen: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer seen.deinit(ctx.allocator);
    const b = frozenIn(ctx, ty, &seen) orelse return null;
    return try localized(ctx, b);
}

fn frozenIn(ctx: *const SemContext, ty: TypeId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) ?Blocker {
    const here: Blocker = .{ .ctx = ctx, .ty = ty };
    return switch (ctx.types.get(ty)) {
        // Another frozen value's handle, a `*{A + Syncs}` included.
        .shared => |inner| if (frozenValue(ctx, inner) != null or frozenObject(ctx, inner)) null else here,
        .weak, .callable, .read_view, .write_view, .string_view, .slice => here,
        // An API object's hidden type may hold a Cell or a handle, so
        // whether it freezes is not known (docs/design/apis.md, Stage 4).
        .api_object => here,
        // A generic parameter is decided in each instance: a declaration
        // freezing one requires it (`Requirement.frozen`), and a generic
        // type's fields stand for its arguments, decided above.
        .type_var => null,
        .function => null,
        .optional, .range => |inner| frozenIn(ctx, inner, seen),
        .fallible => |inner| frozenIn(ctx, inner.ok, seen),
        .array => |a| frozenIn(ctx, a.elem, seen),
        .results => |parts| for (parts) |part| {
            if (frozenIn(ctx, part, seen)) |b| break b;
        } else null,
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id or pn.sym == ctx.task_sym_id or pn.sym == ctx.tasks_sym_id) break :blk here;
            for (pn.args) |a| if (frozenIn(ctx, a, seen)) |b| break :blk b;
            if (isBuiltinGeneric(ctx, pn.sym) or pn.sym == ctx.simd_sym_id) break :blk null;
            break :blk fieldsFrozen(ctx, pn.sym, seen);
        },
        .nominal => |sym| fieldsFrozen(ctx, sym, seen),
        .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk here;
            var found = fieldsFrozen(decl.ctx, decl.sym, seen) orelse break :blk null;
            if (found.module == null) found.module = decl.module_id;
            break :blk found;
        },
        else => null,
    };
}

fn fieldsFrozen(ctx: *const SemContext, sym: SymbolId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) ?Blocker {
    const got = seen.getOrPut(ctx.allocator, .{ .ctx = ctx, .sym = sym }) catch return .{ .ctx = ctx, .ty = ctx.types.invalid_id };
    if (got.found_existing) return null;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| {
        for (dataFields(f)) |d| if (frozenIn(ctx, d.ty, seen)) |b| return b;
    }
    return null;
}

/// A frozen value of `ty`, written at `pos`, holding generic parameters:
/// each instance's argument must freeze (`Requirement.frozen`).
pub fn requireFrozen(ctx: *SemContext, ty: TypeId, pos: u32) std.mem.Allocator.Error!void {
    if (!ctx.typeInfo(ty).has_type_var) return;
    var held: std.ArrayList(SymbolId) = .empty;
    defer held.deinit(ctx.allocator);
    try reachedTypeVars(ctx, ty, &held, ctx.allocator);
    for (held.items) |param| try ctx.generic_requirements.append(ctx.allocator, .{ .param = param, .req = .frozen, .pos = pos, .op = "freezes" });
}

/// Why a frozen value cannot hold a `ty`, whose part `blocker` changes
/// (`frozenBlocker`).
pub fn frozenMessage(ctx: *SemContext, ty: TypeId, blocker: TypeId) std.mem.Allocator.Error![]const u8 {
    return ctx.arena.allocator().print("a frozen value holds only data that never changes, and {s}", .{try frozenReason(ctx, ty, blocker)});
}

/// `frozenMessage`'s reason: "`T` holds `B`", or what `T` is.
pub fn frozenReason(ctx: *SemContext, ty: TypeId, blocker: TypeId) std.mem.Allocator.Error![]const u8 {
    const a = ctx.arena.allocator();
    const shown = try formatType(ctx, ty);
    if (apiObject(ctx, blocker) != null) {
        const how = if (objectHeld(ctx, ty) != null) "is" else "holds";
        return a.print("`{s}` {s} an API object, whose type is erased, so whether it can be frozen is not known: freeze the value before erasing it", .{ shown, how });
    }
    if (blocker != ty) return a.print("`{s}` holds `{s}`", .{ shown, try formatType(ctx, blocker) });
    const what: []const u8 = switch (ctx.types.get(ty)) {
        .read_view, .write_view, .string_view, .slice => "is a view",
        .callable => "is a closure lent for a call",
        .shared, .weak => |inner| if (ctx.types.get(inner) == .function) "is an owned closure" else if (atomicHandle(ctx, inner)) "is a handle that changes what it reaches" else "is a `*` handle whose count is not atomic",
        else => "is a handle that changes what it reaches",
    };
    return a.print("`{s}` {s}", .{ shown, what });
}

/// Whether a value of `ty` holds a task or a set of tasks: in an
/// element, an argument, a field, or a payload. A task started in
/// `task.isolate(f)` ends in `f`, so `f` gives no value that holds one.
pub fn holdsTask(ctx: *const SemContext, ty: TypeId) bool {
    var seen: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer seen.deinit(ctx.allocator);
    return taskIn(ctx, ty, &seen);
}

fn taskIn(ctx: *const SemContext, ty: TypeId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .optional, .shared, .weak, .range => |inner| taskIn(ctx, inner, seen),
        .fallible => |inner| taskIn(ctx, inner.ok, seen),
        .array => |a| taskIn(ctx, a.elem, seen),
        .slice => |sl| taskIn(ctx, sl.elem, seen),
        .results => |parts| for (parts) |part| {
            if (taskIn(ctx, part, seen)) break true;
        } else false,
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.task_sym_id or pn.sym == ctx.tasks_sym_id) break :blk true;
            for (pn.args) |a| if (taskIn(ctx, a, seen)) break :blk true;
            if (isBuiltinGeneric(ctx, pn.sym) or pn.sym == ctx.simd_sym_id) break :blk false;
            break :blk fieldsHoldTask(ctx, pn.sym, seen);
        },
        .nominal => |sym| fieldsHoldTask(ctx, sym, seen),
        .imported_nominal => blk: {
            const decl = nominalDecl(ctx, ty) orelse break :blk false;
            break :blk fieldsHoldTask(decl.ctx, decl.sym, seen);
        },
        else => false,
    };
}

fn fieldsHoldTask(ctx: *const SemContext, sym: SymbolId, seen: *std.AutoHashMapUnmanaged(SymbolKey, void)) bool {
    const got = seen.getOrPut(ctx.allocator, .{ .ctx = ctx, .sym = sym }) catch return false;
    if (got.found_existing) return false;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| {
        for (dataFields(f)) |d| if (taskIn(ctx, d.ty, seen)) return true;
    }
    return false;
}

/// What in the fields and payloads of a declared type keeps it from
/// meeting `how` (`blockerIn`); a type already being looked into adds
/// nothing. A generic parameter in a field stands for an argument, which
/// its instance checks.
fn fieldsBlock(ctx: *const SemContext, sym: SymbolId, how: Crossing, local: bool, walk: *Walk) ?Blocker {
    const got = walk.seen.getOrPut(ctx.allocator, .{ .ctx = ctx, .sym = sym }) catch return .{ .ctx = ctx, .ty = ctx.types.invalid_id };
    if (got.found_existing) return null;
    // A field's parameters are the declaration's own, not the walk's.
    const reached = walk.reached;
    walk.reached = null;
    defer walk.reached = reached;
    for (ctx.symbols.items[sym].fields orelse &.{}) |*f| {
        for (dataFields(f)) |d| if (blockerIn(ctx, d.ty, how, local, walk)) |b| return b;
    }
    return null;
}

/// Whether a view of type `view` of a slot of type `slot` (a String, or a
/// write view of one) is the bytes of a String: the read view of a `String`
/// is a `?String` (`TypeStore.absorbed`), held by value, so a binding that
/// views a String slot takes its `.bytes()`.
pub fn viewsStringBytes(ctx: *const SemContext, slot: TypeId, view: TypeId) bool {
    return unwrapViews(ctx, slot) == ctx.types.string_id and view == ctx.types.string_view_id;
}

/// Whether a value of `ty` reaches a String (`Views.string`), which a
/// `?String` may view.
pub fn reachesString(ctx: *const SemContext, ty: TypeId) bool {
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

/// Whether the temporaries `child` makes are its parent `stmt`'s: a
/// block or a closure holds statements of its own, a `match` arm's body
/// is a statement of its own (as the one statement of a block is), and
/// a header (an `if`'s condition, a `match`'s subject, an arm's guard)
/// or a `while` loop's step is a statement of its own; every other part
/// of a statement, a branch, a `??` fallback, and a `catch` handler
/// included, makes its temporaries for the statement.
fn sharesStmtTemps(stmt: Sexp, child: Sexp) bool {
    if (child != .list or child.isKind(.block) or child.isKind(.lambda)) return false;
    return !isHeaderOf(stmt, child) and !isWhileStep(stmt, child) and !isArmBody(stmt, child);
}

/// Whether `child` is the body of `match` arm `parent`: a statement of
/// its own, in the arm's scope, which its bindings outlive.
pub fn isArmBody(parent: Sexp, child: Sexp) bool {
    if (!parent.isKind(.arm)) return false;
    const body = ir.Arm.body(parent);
    return body == .list and child == .list and body.list.id == child.list.id;
}

/// The first statement temporary (`dropsTemp`) that `stmt`, a statement
/// or a header, makes itself (`stmtTemps`).
pub fn firstStmtTemp(ctx: *const SemContext, stmt: Sexp) ?Sexp {
    if (stmt != .list or stmt.isKind(.block) or stmt.isKind(.lambda)) return null;
    if (ctx.dropsTemp(stmt)) return stmt;
    for (rig.children(stmt)) |c| {
        if (!sharesStmtTemps(stmt, c)) continue;
        if (firstStmtTemp(ctx, c)) |t| return t;
    }
    return null;
}

/// The statement temporaries (`dropsTemp`) that `stmt`, a statement, a
/// header, or a part of one, makes itself (`sharesStmtTemps`), appended
/// to `out` in the order they are made: an assignment's value before its
/// target (Core §6), and a value's parts before it. This is where each
/// temporary lives: emit declares a slot for each where the statement
/// starts (`Emitter.emitTempSlots`), and the ownership checker holds each
/// for the statement, also one made in a `catch` handler, whose scope it
/// opens for the handler's name (`Checker.holdPartTemps`).
pub fn stmtTemps(ctx: *const SemContext, a: std.mem.Allocator, stmt: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    if (stmt != .list or stmt.isKind(.block) or stmt.isKind(.lambda)) return;
    if (stmt.isKind(.set)) {
        try stmtTemps(ctx, a, ir.Set.value(stmt), out);
        try stmtTemps(ctx, a, ir.Set.target(stmt), out);
    } else for (rig.children(stmt)) |c| if (sharesStmtTemps(stmt, c)) try stmtTemps(ctx, a, c, out);
    if (ctx.dropsTemp(stmt)) try out.append(a, stmt);
}

/// The values statement `stmt` erases to API objects that view a copy
/// (`Erasure.copy`), in its headers and arms too, but not in the blocks or
/// closures it holds, whose statements are emitted on their own: emit
/// declares the slot of each before the statement, a local of its block
/// (`Emitter.emitErasedSlots`).
pub fn stmtErasedCopies(ctx: *const SemContext, a: std.mem.Allocator, stmt: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    if (ctx.facts.erasures.count() == 0) return;
    if (stmt.isKind(.block) or stmt.isKind(.lambda)) return;
    if (ctx.erasureOf(stmt)) |e| if (e.copy) try out.append(a, stmt);
    if (stmt != .list) return;
    for (stmt.items()) |c| try stmtErasedCopies(ctx, a, c, out);
}

/// Whether a view of type `ty` is held as a pointer: a write view (but
/// a `![]T`, a slice), or a read view of a value that is not lent by
/// value (`lendByValue`).
pub fn viewHeldAsPointer(ctx: *const SemContext, ty: TypeId) bool {
    // An API object is two words held by value, the address and the
    // table, as a callable view is (`rig.ApiView`).
    if (objectView(ctx, ty) != null) return false;
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

/// Whether a value of `ty` holds a `?String` but no marked view or type
/// parameter: it may view a String, and nothing else.
pub fn holdsViewOnly(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.views.string_view and !info.views.marked and !info.holds_type_var and !info.poison;
}

// -----------------------------------------------------------------------------
// What a view can point into (Core sentence 7)
// -----------------------------------------------------------------------------

/// How a value of a holder type leads to the memory a view points into
/// (docs/internals/INTERNALS.md, "Call origins"). One classifier answers both
/// questions sentence 7 asks of a type: whether a value of it could hold
/// what a view views (`!= .none`), and whether that memory may be its
/// own (`== .owned`) rather than a read view's it holds.
pub const ViewReach = enum(u2) {
    /// It never does.
    none,
    /// Only by crossing a read view it holds (`?T`, `[]T`, a `?String`):
    /// the memory is that view's, never the holder's own.
    through_view,
    /// Through what it owns, or a write view it holds: the memory may be
    /// its own, or memory it can change.
    owned,
};

/// The memory a view may point into: a set of `ViewAtom`s, a String's or
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
        .nominal => |sym| if (isBuiltinEnum(ctx, sym)) .{ .module = 0, .sym = symbol_invalid } else .{ .module = ctx.module_id, .sym = sym },
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
    /// A part of a value (`ownedParts`): a function type there is a
    /// function value, which holds nothing (Core §7), where the type
    /// walked itself may be a closure binding's.
    held: bool = false,
};

/// The bit `viewAtom` sets on the target of a slice: memory a slice
/// views is an element of an array, a slice, or a List, never a field.
const elem_view: u64 = 1 << 62;

/// The types a value of `node` holds by value (fields, payloads, an
/// optional's, array's, List's, box's, Cell's or Signal's contents, a
/// handle's), each passed to `f.visit`. A generic instance holds its
/// arguments, and its declared fields in the generic context.
fn ownedParts(node: ViewNode, f: anytype) std.mem.Allocator.Error!void {
    const ctx = node.ctx;
    switch (ctx.types.get(node.ty)) {
        .optional, .shared, .weak => |inner| try f.visit(.{ .ctx = ctx, .ty = inner, .args = node.args, .held = true }),
        .fallible => |inner| try f.visit(.{ .ctx = ctx, .ty = inner.ok, .args = node.args, .held = true }),
        .array => |a| try f.visit(.{ .ctx = ctx, .ty = a.elem, .args = node.args, .elem = true, .held = true }),
        .nominal, .imported_nominal => {
            const decl = nominalDecl(ctx, node.ty) orelse return;
            for (decl.symbol().fields orelse &.{}) |*fld| {
                for (dataFields(fld)) |d| try f.visit(.{ .ctx = decl.ctx, .ty = d.ty, .held = true });
            }
        },
        .parameterized_nominal => |pn| {
            for (pn.args) |arg| try f.visit(.{ .ctx = ctx, .ty = arg, .args = node.args, .elem = true, .held = true });
            for (ctx.symbols.items[pn.sym].fields orelse &.{}) |*fld| {
                for (dataFields(fld)) |d| try f.visit(.{ .ctx = ctx, .ty = d.ty, .args = .{ .ctx = ctx, .tys = pn.args }, .held = true });
            }
        },
        // Several results are held as an object's fields are.
        .results => |parts| for (parts) |part| try f.visit(.{ .ctx = ctx, .ty = part, .args = node.args, .held = true }),
        else => {},
    }
}

/// What a type's own views point into: the target of each view it
/// holds by value, not what those targets hold in turn (a view of a
/// value that holds views keeps that value's loans, which keep the
/// rest). A function or lent callable walked itself (a closure
/// binding's type), an owned closure, a type parameter, or a type not
/// known points anywhere; a function value held in a value, a named
/// function's address, points nowhere (Core §7).
pub fn viewTargets(ctx: *const SemContext, a: std.mem.Allocator, view: TypeId) std.mem.Allocator.Error!ViewTargets {
    var w: TargetWalk = .{ .a = a };
    try w.walk(.{ .ctx = ctx, .ty = view });
    return w.out;
}

/// Each walk visits a type and those it holds in the order a recursive
/// walk would, but with a stack of its own (`todo`): a chain of types,
/// each holding the next, is as long as the program makes it.
const TargetWalk = struct {
    a: std.mem.Allocator,
    out: ViewTargets = .{},
    seen: std.AutoHashMapUnmanaged(SeenKey, void) = .empty,
    /// Only the views of written memory: storage a write view leads to.
    written_only: bool = false,
    written: bool = false,
    /// The types still to visit, the next on top, each with whether a
    /// write view leads to it.
    todo: std.ArrayList(Pending) = .empty,

    const SeenKey = struct { ctx: usize, ty: TypeId, args: usize, written: bool };
    const Pending = struct { node: ViewNode, written: bool };

    /// Visits `node` and every type it holds.
    fn walk(self: *TargetWalk, node: ViewNode) std.mem.Allocator.Error!void {
        try self.todo.append(self.a, .{ .node = node, .written = false });
        while (self.todo.pop()) |next| {
            self.written = next.written;
            const mark = self.todo.items.len;
            try self.visit(next.node);
            // The first type `visit` found is visited first.
            std.mem.reverse(Pending, self.todo.items[mark..]);
        }
        self.written = false;
    }

    /// `node`, to visit after the type being visited, through a write
    /// view when `written`.
    fn push(self: *TargetWalk, node: ViewNode, written: bool) std.mem.Allocator.Error!void {
        try self.todo.append(self.a, .{ .node = node, .written = written });
    }

    /// What `ownedParts` passes each type it finds to: `push`.
    const Parts = struct {
        w: *TargetWalk,
        fn visit(p: Parts, node: ViewNode) std.mem.Allocator.Error!void {
            try p.w.push(node, p.w.written);
        }
    };

    fn target(self: *TargetWalk, node: ViewNode) std.mem.Allocator.Error!void {
        const ctx = node.ctx;
        switch (ctx.types.get(node.ty)) {
            .type_var => if (node.args) |args| {
                for (args.tys) |t| switch (args.ctx.types.get(t)) {
                    .type_var, .invalid, .unknown => self.out.any = true,
                    else => {
                        try self.target(.{ .ctx = args.ctx, .ty = t, .elem = node.elem });
                        // A read view of a `T` that is `String` is a
                        // `?String`, which views the text's bytes.
                        if (!node.elem and t == args.ctx.types.string_id) self.out.bytes = true;
                    },
                };
            } else {
                self.out.any = true;
            },
            // An API object's value may be anything (docs/design/apis.md,
            // Stage 4).
            .function, .callable, .api_object, .invalid, .unknown => self.out.any = true,
            else => {
                try self.out.add(self.a, viewAtom(ctx, node.ty) | if (node.elem) elem_view else 0);
                // A `[]?String` also views the elements of a `[]Static`
                // (`readsAsStringView`).
                if (node.elem and node.ty == ctx.types.string_view_id) try self.out.add(self.a, viewAtom(ctx, ctx.types.static_id) | elem_view);
            },
        }
    }

    fn visit(self: *TargetWalk, node: ViewNode) std.mem.Allocator.Error!void {
        const ctx = node.ctx;
        const t = ctx.types.get(node.ty);
        const is_view = switch (t) {
            .read_view, .write_view, .slice, .string_view, .callable => true,
            .function => !node.held,
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
            .string_view => self.out.bytes = true,
            else => self.out.any = true,
        };
        switch (t) {
            .write_view => |inner| if (self.written_only) {
                // What a write view leads to may be written.
                const elem = switch (ctx.types.get(inner)) {
                    .slice => |sl| sl.elem,
                    else => inner,
                };
                return self.push(.{ .ctx = ctx, .ty = elem, .args = node.args }, true);
            },
            // In a generic type's field, a type parameter stands for the
            // instance's arguments, which `ownedParts` walked where the
            // instance is, each in the context that gives its own type
            // parameters theirs: walked again here, out of that context,
            // an argument that is itself a type parameter (`Entry[K, V]`
            // in a `Map[K, V]`'s field) would stand for anything.
            .type_var => if (node.args != null) {
                return;
            } else if (!self.written_only or self.written) {
                self.out.any = true;
            },
            // An API object's value may hold a view of anything.
            .api_object, .invalid, .unknown => if (!self.written_only or self.written) {
                self.out.any = true;
            },
            // An owned closure's environment counts as anything, as a
            // closure binding's does; a function value alone holds
            // nothing.
            .shared, .weak => |inner| if (ctx.types.get(inner) == .function) {
                if (!self.written_only or self.written) self.out.any = true;
                return;
            },
            else => {},
        }
        if (is_view) return;
        // A box or a handle of an API object whose braces say it holds no
        // loan views nothing (`heldObjectOwned`).
        if (objectHeld(ctx, node.ty)) |h| if (heldObjectOwned(ctx, node.ty, h)) return;
        // Each type is walked once per context.
        const key: SeenKey = .{ .ctx = @intFromPtr(ctx), .ty = node.ty, .args = if (node.args) |args| @intFromPtr(args.tys.ptr) else 0, .written = self.written };
        if ((try self.seen.getOrPut(self.a, key)).found_existing) return;
        try ownedParts(node, Parts{ .w = self });
    }
};

/// What a call may store through write parameters of types `params`:
/// the targets of the views a value stored in memory a write view among
/// them leads to may hold, a handle's contents included. A parameter
/// taken by value is the callee's own copy, so only what its write
/// views lead to counts; what a read view leads to is never written.
pub fn storeTargets(ctx: *const SemContext, a: std.mem.Allocator, params: []const TypeId) std.mem.Allocator.Error!ViewTargets {
    var w: TargetWalk = .{ .a = a, .written_only = true };
    for (params) |p| try w.walk(.{ .ctx = ctx, .ty = p });
    return w.out;
}

/// Which of a holder's memory counts: all of it, or only what it leads
/// to through a view (`?T`, `!T`, `[]T`, a `?String`), as for a parameter
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
            // Anything at all, a view among them; an API object's value,
            // and an owned closure's environment, may be anything too. A
            // function value held in a value, a named function's
            // address, holds nothing (Core §7).
            .callable, .api_object, .invalid, .unknown => return self.reached(path, true),
            .shared, .weak => |inner| if (ctx.types.get(inner) == .function) return self.reached(path, true),
            .function => return if (!node.held) self.reached(path, true),
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
            // A `?String` views bytes, which a target that is any memory
            // (a type parameter's, say) includes; a String owns them.
            .string_view => if (self.targets.bytes or self.targets.any) self.reached(read, true),
            .string => if (self.targets.bytes) self.reached(path, path.viewed),
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

/// Whether a parameter of type `ty` is lent: a view (`isViewType`), or
/// an optional of one. A call keeps a lent parameter only where its
/// declaration's `keeps` names it (Core sentence 7); any other parameter
/// is taken by value, the callee's, and kept wherever its type fits.
pub fn lentParam(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .optional => |inner| isViewType(ctx, inner),
        else => isViewType(ctx, ty),
    };
}

/// Whether `ty` is a view: a `?T`, `!T`, `[]T` (a `![]T` is a `!T`),
/// or `?String`.
pub fn isViewType(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .slice, .string_view => true,
        else => false,
    };
}

/// The origins of function `name`, declared at `pos` with type `f`:
/// its signature's (`defaultOrigins`), with the result's narrowed to the
/// parameters its `from` clause names, and the stores to its by-value
/// parameters and the lent ones its `keeps` clause names (`declKeeps`).
/// A name that is no parameter, or one whose type cannot hold what the
/// result views, is reported, as is a clause on a result that views
/// nothing.
fn declOrigins(ctx: *SemContext, a: std.mem.Allocator, name: []const u8, pos: u32, f: FunctionType, param_names: ?[]const []const u8, in_api: bool) std.mem.Allocator.Error!Origins {
    const o = try declaredOrigins(ctx, a, name, pos, f, in_api);
    if (resultsOf(ctx, f.returns)) |parts| try checkResultViews(ctx, a, name, pos, f, parts, o.result, param_names orelse &.{});
    return o;
}

/// Several results of one function, `parts`, whose call's results carry
/// the parameters of `mask`: a write view among them (one at most,
/// `resolveResults`) views alone what it views while it lives (Core
/// sentence 5), so no other result may view a parameter it may view.
/// Reported at the declaration.
fn checkResultViews(ctx: *SemContext, a: std.mem.Allocator, name: []const u8, pos: u32, f: FunctionType, parts: []const TypeId, mask: ParamMask, param_names: []const []const u8) std.mem.Allocator.Error!void {
    const masks = try a.alloc(ParamMask, parts.len);
    for (parts, masks) |part, *m| {
        m.* = 0;
        const targets = try viewTargets(ctx, a, part);
        for (f.params, 0..) |p, i| {
            if (mask & paramBit(i) == 0) continue;
            if (try reachTargets(ctx, a, p, targets, .views) != .none) m.* |= paramBit(i);
        }
    }
    for (parts, masks, 0..) |part, m, i| {
        if (ctx.types.get(unwrapOptionals(ctx, part)) != .write_view) continue;
        for (masks, 0..) |other, k| {
            if (k == i or m & other == 0) continue;
            const pi = @ctz(m & other);
            const pname = if (pi < param_names.len) param_names[pi] else "a parameter";
            try ctx.err(pos, "`{s}` gives a write view and another result, `{s}`, that could both view `{s}`: while the write view lives, nothing else may view what it writes", .{ name, try formatType(ctx, parts[k]), pname });
            return;
        }
    }
}

/// `declOrigins` without the check of several results. A path of self
/// (`from @text`) keeps self's bit and is recorded in `self_paths`
/// (`selfPathIn`); `@` beside a path, or two paths one of which holds
/// the other, are reported.
fn declaredOrigins(ctx: *SemContext, a: std.mem.Allocator, name: []const u8, pos: u32, f: FunctionType, in_api: bool) std.mem.Allocator.Error!Origins {
    var o = try defaultOrigins(ctx, a, f);
    try declKeeps(ctx, name, pos, f, &o);
    o.once = ctx.declared_once.get(pos) orelse 0;
    const d = ctx.declared_origins.get(pos) orelse return o;
    const results = try viewTargets(ctx, a, f.returns);
    if (results.isEmpty()) {
        try ctx.errAt(d.names, "`{s}` returns `{s}`, which views nothing; `from` names what a result views", .{ name, try formatType(ctx, f.returns) });
        return o;
    }
    var named: ParamMask = 0;
    var whole_self: ?Sexp = null;
    var paths: std.ArrayList(SelfPath) = .empty;
    var path_nodes: std.ArrayList(Sexp) = .empty;
    for (d.names.items()) |n| {
        if (n.isKind(.member)) {
            const found = (try selfPathIn(ctx, a, name, f, d.params, results, n, in_api)) orelse continue;
            for (paths.items, path_nodes.items) |q, qn| {
                const later = found.path.fields.len >= q.fields.len;
                if (!fieldsPrefix((if (later) q else found.path).fields, (if (later) found.path else q).fields)) continue;
                const first = try selfPathText(ctx, qn);
                const second = try selfPathText(ctx, n);
                try ctx.errAt(n, "`from {s}, {s}`: `{s}` holds `{s}`; name one of them", .{ first, second, if (later) first else second, if (later) second else first });
                break;
            } else {
                try paths.append(a, found.path);
                try path_nodes.append(a, n);
                named |= paramBit(found.index);
            }
            continue;
        }
        const text = identAt(ctx.source, n) orelse continue;
        if (std.mem.eql(u8, text, "@")) whole_self = n;
        const i = for (d.params.items(), 0..) |p, i| {
            if (paramName(ctx.source, p)) |pn| if (std.mem.eql(u8, pn, text)) break i;
        } else {
            if (std.mem.eql(u8, text, "static")) {
                try ctx.errAt(n, "`static` stands alone (`from static`): a result may always view what lives for the whole program, so a list names only parameters", .{});
            } else try ctx.errAt(n, "`{s}` has no parameter `{s}`; `from` names parameters, `@`, or `static` alone", .{ name, text });
            continue;
        };
        if (i < f.params.len and try reachTargets(ctx, a, f.params[i], results, .views) == .none) {
            try ctx.errAt(n, "`{s}: {s}` cannot hold a view of what `{s}` returns, so its result never views it", .{ text, try formatType(ctx, f.params[i]), name });
            continue;
        }
        named |= paramBit(i);
    }
    if (whole_self != null and path_nodes.items.len > 0) {
        const p = try selfPathText(ctx, path_nodes.items[0]);
        try ctx.errAt(path_nodes.items[0], "`from @, {s}`: `@` holds `{s}`; name one of them", .{ p, p });
        paths.clearRetainingCapacity();
    }
    o.result &= named;
    o.declared = true;
    if (paths.items.len > 0) o.self_paths = try ctx.arena.allocator().dupe(SelfPath, paths.items);
    return o;
}

/// Whether path `short` is `long` or one of its prefixes.
fn fieldsPrefix(short: []const []const u8, long: []const []const u8) bool {
    if (short.len > long.len) return false;
    for (short, long[0..short.len]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// A path of self, `@a.b`, as written.
fn selfPathText(ctx: *SemContext, n: Sexp) std.mem.Allocator.Error![]const u8 {
    if (!n.isKind(.member)) return identAt(ctx.source, n) orelse "@";
    return memberText(ctx.arena.allocator(), try selfPathText(ctx, ir.Member.object(n)), identAt(ctx.source, ir.Member.name(n)) orelse "?");
}

/// The path of self `n` names in the `from` of method `name` of type
/// `f`, whose parameters are `params` and whose result views `results`
/// (Core sentence 7): fields from `@` through objects and boxes, as Core
/// §5 defines a path, whose last field's type could hold what the result
/// views. Null after reporting a path that names a parameter's part, one
/// in an API, one past a read view (whose result views what the view
/// views), one past anything else that ends a path, one longer than the
/// ownership checker tells apart (`max_path_fields`), a field no type
/// has, or one that cannot hold the result.
fn selfPathIn(ctx: *SemContext, a: std.mem.Allocator, name: []const u8, f: FunctionType, params: Sexp, results: ViewTargets, n: Sexp, in_api: bool) std.mem.Allocator.Error!?struct { path: SelfPath, index: usize } {
    const text = try selfPathText(ctx, n);
    var steps: std.ArrayList(Sexp) = .empty;
    var root = n;
    while (root.isKind(.member)) : (root = ir.Member.object(root)) try steps.insert(a, 0, root);
    const root_text = identAt(ctx.source, root) orelse return null;
    if (!std.mem.eql(u8, root_text, "@")) {
        try ctx.errAt(n, "`from {s}`: `from` names a parameter, or a path of self (`from @text`); write `from {s}`", .{ text, root_text });
        return null;
    }
    if (in_api) {
        try ctx.errAt(n, "`from {s}`: an API names no fields: write `from @`", .{text});
        return null;
    }
    const index = for (params.items(), 0..) |p, i| {
        if (paramName(ctx.source, p)) |pn| if (std.mem.eql(u8, pn, "@")) break i;
    } else {
        try ctx.errAt(n, "`{s}` has no `@`, so `from {s}` names nothing; a path of self is a method's", .{ name, text });
        return null;
    };
    if (index >= f.params.len) return null;
    if (steps.items.len > max_path_fields) {
        try ctx.errAt(n, "`from {s}`: a path of self names at most {d} fields", .{ text, max_path_fields });
        return null;
    }
    const fields = try ctx.arena.allocator().alloc([]const u8, steps.items.len);
    var t = unwrapViews(ctx, f.params[index]);
    for (steps.items, fields, 0..) |step, *field, k| {
        field.* = identAt(ctx.source, ir.Member.name(step)) orelse return null;
        const before = ir.Member.object(step);
        if (k > 0 and readViewField(ctx, t)) {
            const held = try selfPathText(ctx, before);
            try ctx.errAt(n, "`from {s}`: `{s}` is a read view, so a result views what it views, not a part of self; write `from {s}`", .{ text, held, held });
            return null;
        }
        var holder = t;
        while (boxedType(ctx, holder)) |inner| holder = inner;
        const ok = switch (ctx.types.get(holder)) {
            .nominal, .imported_nominal => true,
            .parameterized_nominal => |pn| !isBuiltinGeneric(ctx, pn.sym),
            else => false,
        };
        if (!ok) {
            try ctx.errAt(n, "`from {s}`: `{s}` is a `{s}`, and a path of self goes only through fields of objects and boxes", .{ text, try selfPathText(ctx, before), try formatType(ctx, t) });
            return null;
        }
        const fld = lookupDataFieldConst(ctx, holder, field.*) orelse {
            try ctx.errAt(n, "`{s}` has no field `{s}`, so `from {s}` names nothing", .{ try formatType(ctx, holder), field.*, text });
            return null;
        };
        t = fld.ty;
    }
    if (try reachTargets(ctx, a, t, results, .all) == .none) {
        try ctx.errAt(n, "`{s}: {s}` cannot hold a view of what `{s}` returns, so its result never views it", .{ text, try formatType(ctx, t), name });
        return null;
    }
    return .{ .path = .{ .fields = fields, .via_view = readViewField(ctx, t) }, .index = index };
}

/// Narrow `o.stores` to the parameters a call of function `name`,
/// declared at `pos` with type `f`, keeps: each taken by value whose
/// type could hold what its write parameters lead to (`defaultOrigins`),
/// and each lent one (`lentParam`) its `keeps` clause names. A name that
/// is no parameter, one taken by value, one nothing the function writes
/// could hold, and one named twice are reported.
fn declKeeps(ctx: *SemContext, name: []const u8, pos: u32, f: FunctionType, o: *Origins) std.mem.Allocator.Error!void {
    for (f.params, 0..) |p, i| {
        if (lentParam(ctx, p)) o.lent |= paramBit(i);
    }
    var named: ParamMask = 0;
    if (ctx.declared_keeps.get(pos)) |d| {
        for (d.names.items()) |n| {
            if (n.isKind(.member)) {
                const text = try selfPathText(ctx, n);
                try ctx.errAt(n, "`keeps {s}`: `keeps` names lent parameters, not their parts; write `keeps @`", .{text});
                continue;
            }
            const text = identAt(ctx.source, n) orelse continue;
            const i = for (d.params.items(), 0..) |p, i| {
                if (paramName(ctx.source, p)) |pn| if (std.mem.eql(u8, pn, text)) break i;
            } else {
                try ctx.errAt(n, "`{s}` has no parameter `{s}`; `keeps` names lent parameters, `@` among them", .{ name, text });
                continue;
            };
            if (i >= f.params.len) continue;
            if (named & paramBit(i) != 0) {
                try ctx.errAt(n, "`keeps {s}`: `{s}` is named twice", .{ text, text });
                continue;
            }
            if (!lentParam(ctx, f.params[i])) {
                try ctx.errAt(n, "`keeps {s}`: `{s}` is taken by value, so the callee owns it already", .{ text, text });
                continue;
            }
            if (o.stores & paramBit(i) == 0) {
                try ctx.errAt(n, "`keeps {s}`: `{s}` takes nothing to write that could hold it", .{ text, name });
                continue;
            }
            named |= paramBit(i);
        }
    }
    o.stores &= ~o.lent | named;
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
                sym.origins = try declOrigins(ctx, scratch.allocator(), sym.name, sym.decl_pos, f, sym.param_names, false);
                _ = scratch.reset(.retain_capacity);
            },
            .nominal_type, .generic_type, .api => sym.fields = try methodOrigins(ctx, &scratch, sym.fields orelse continue, sym.kind == .api),
            else => {},
        }
    }
    // An addition's methods, shared by the conformances it writes.
    var done: ?[]const Field = null;
    var with: []const Field = &.{};
    for (ctx.conformances.items) |*c| {
        if (c.kind != .add or c.methods.len == 0) continue;
        if (done == null or done.?.ptr != c.methods.ptr) {
            done = c.methods;
            with = try methodOrigins(ctx, &scratch, c.methods, false);
        }
        c.methods = with;
    }
}

/// `fields` with each method's origins set (`declOrigins`).
fn methodOrigins(ctx: *SemContext, scratch: *std.heap.ArenaAllocator, fields: []const Field, in_api: bool) std.mem.Allocator.Error![]const Field {
    const out = try ctx.arena.allocator().dupe(Field, fields);
    for (out) |*fld| {
        if (!fld.is_method or fld.is_drop_method) continue;
        const f = switch (ctx.types.get(fld.ty)) {
            .function => |f| f,
            else => continue,
        };
        fld.origins = try declOrigins(ctx, scratch.allocator(), fld.name, fld.decl_pos, f, fld.param_names, in_api);
        _ = scratch.reset(.retain_capacity);
    }
    return out;
}

/// The types of the several results `ty` gives, `(A, B)`, also inside
/// one `T!` or `T?` (`(A, B)!`, `(A, B)?`); null for any other type.
pub fn resultsOf(ctx: *const SemContext, ty: TypeId) ?[]const TypeId {
    const t = switch (ctx.types.get(ty)) {
        .optional => |inner| inner,
        .fallible => |inner| inner.ok,
        else => ty,
    };
    return switch (ctx.types.get(t)) {
        .results => |parts| parts,
        else => null,
    };
}

/// Whether a value of `ty` holds a write view, which is unique.
pub fn holdsWriteView(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).views.write;
}

/// Whether `ty` is or holds inline an `error`, which is owning in every
/// program (`TypeInfo.any_error`).
pub fn holdsAnyError(ctx: *const SemContext, ty: TypeId) bool {
    return ctx.holds(ty).any_error;
}

/// Plain data, Core §1's plain kind: a value that owns nothing and
/// holds no `?T`, `!T`, slice, function value, or type parameter, but
/// may hold a `?String`. It copies (`copies`), and carries no loan but a
/// `?String`'s: what a `Cell` or `Signal` holds, and what an owned closure
/// takes and returns (Core sentence 9).
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
/// optional, array, box's or counted handle's contents), never one a weak
/// handle or a view reaches. A `drop` body may read what the value views;
/// any other drop only releases memory, which uses no view (Core sentence
/// 6). `depends` for a value holding a type parameter, whose instances
/// answer for themselves; a type declared in another module answers by
/// whether it has drop glue.
pub fn dropRunsBody(ctx: *const SemContext, ty: TypeId) Answer {
    if (dropBodyOf(ctx, ty)) return .yes;
    const info = ctx.holds(ty);
    return if (info.holds_type_var or info.poison) .depends else .no;
}

/// Whether `print` can write a value of `ty`: unless it holds a `[]U8`,
/// directly or through a wrapper, field, payload, or type argument
/// (`holdsByteSlice`). A type parameter answers for each instance
/// (`Requirement.printable`, on the parameters `printedTypeVars`
/// finds). Worked out once declarations are resolved (`TypeMemo`).
pub fn printable(ctx: *const SemContext, ty: TypeId) !bool {
    if (!ctx.contents_ready) return !try holdsByteSlice(ctx, ty, ctx.allocator, null);
    if (ctx.type_memo.printable.get(ty)) |b| return b;
    const b = !try holdsByteSlice(ctx, ty, ctx.allocator, null);
    try ctx.type_memo.printable.put(ctx.allocator, ty, b);
    return b;
}

/// The type parameters `print` writes of a value of `ty`, where
/// `holdsByteSlice` looks: held, viewed, in an element or a type
/// argument (`[]T`, `List[T]`, `*T`), added to `out`. Each instance's
/// type for one must print (`Requirement.printable`).
pub fn printedTypeVars(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), a: std.mem.Allocator) !void {
    if (!ctx.typeInfo(ty).has_type_var) return;
    _ = try holdsByteSlice(ctx, ty, a, .{ .out = out, .a = a });
}

const ByteSliceVisit = struct { ctx: *const SemContext, sym: SymbolId };
/// `top`: the type is written where the walk began, not in a declared
/// type's fields, whose parameters are the declaration's own.
const ByteSliceItem = struct { ctx: *const SemContext, ty: TypeId, top: bool = false };
/// Where `holdsByteSlice` collects the type parameters it reaches.
const PrintedVars = struct { out: *std.ArrayList(SymbolId), a: std.mem.Allocator };

/// Whether a value of `ty` holds a `[]U8`, directly or through a
/// wrapper, field, payload, or type argument. A `[]U8` and a `?String`
/// are both Zig `[]const u8`, so `print` cannot tell them apart. The
/// walk keeps a stack of its own, so a long chain of types, each
/// holding the next, does not nest it; each declaration is walked once.
/// With `vars`, it also collects the type parameters it reaches
/// (`printedTypeVars`).
fn holdsByteSlice(ctx: *const SemContext, ty: TypeId, a: std.mem.Allocator, vars: ?PrintedVars) !bool {
    var todo: std.ArrayList(ByteSliceItem) = .empty;
    defer todo.deinit(a);
    var seen: std.AutoHashMapUnmanaged(ByteSliceVisit, void) = .empty;
    defer seen.deinit(a);
    try todo.append(a, .{ .ctx = ctx, .ty = ty, .top = true });
    while (todo.pop()) |item| {
        const c = item.ctx;
        switch (c.types.get(item.ty)) {
            .type_var => |param| {
                if (item.top) if (vars) |v| if (std.mem.findScalar(SymbolId, v.out.items, param) == null) try v.out.append(v.a, param);
                continue;
            },
            .slice => |sl| {
                switch (c.types.get(sl.elem)) {
                    .int => |i| if (i.bits == 8 and !i.signed) return true,
                    else => try todo.append(a, .{ .ctx = c, .ty = sl.elem, .top = item.top }),
                }
                continue;
            },
            .optional, .read_view, .write_view, .shared => |inner| {
                try todo.append(a, .{ .ctx = c, .ty = inner, .top = item.top });
                continue;
            },
            .fallible => |f| {
                try todo.append(a, .{ .ctx = c, .ty = f.ok, .top = item.top });
                continue;
            },
            .array => |arr| {
                try todo.append(a, .{ .ctx = c, .ty = arr.elem, .top = item.top });
                continue;
            },
            .parameterized_nominal => |pn| for (pn.args) |arg| try todo.append(a, .{ .ctx = c, .ty = arg, .top = item.top }),
            .nominal, .imported_nominal => {},
            else => continue,
        }
        const decl = nominalDecl(c, item.ty) orelse continue;
        if ((try seen.getOrPut(a, .{ .ctx = decl.ctx, .sym = decl.sym })).found_existing) continue;
        for (decl.ctx.symbols.items[decl.sym].fields orelse &.{}) |*f| {
            for (dataFields(f)) |d| try todo.append(a, .{ .ctx = decl.ctx, .ty = d.ty });
        }
    }
    return false;
}

/// `runsDropBody` of `ty`, worked out once declarations are resolved
/// (`TypeMemo`).
fn dropBodyOf(ctx: *const SemContext, ty: TypeId) bool {
    if (!ctx.contents_ready) return runsDropBody(ctx, ty, null);
    if (ctx.type_memo.drop_body.get(ty)) |b| return b;
    const b = runsDropBody(ctx, ty, null);
    ctx.type_memo.drop_body.put(ctx.allocator, ty, b) catch std.debug.panic("out of memory", .{});
    return b;
}

/// The declared types a walk is inside, nearest first.
const SymPath = struct { sym: SymbolId, up: ?*const SymPath };

/// `path` holds the declared types being looked into: a cycle adds nothing.
fn runsDropBody(ctx: *const SemContext, ty: TypeId, path: ?*const SymPath) bool {
    return switch (ctx.types.get(ty)) {
        .shared, .optional => |i| runsDropBody(ctx, i, path),
        .fallible => |i| runsDropBody(ctx, i.ok, path),
        .array => |a| runsDropBody(ctx, a.elem, path),
        .imported_nominal => typeHasDropGlue(ctx, ty),
        .nominal => |sid| fieldsRunDropBody(ctx, sid, path),
        // An API object's value may have a `drop` body, which may read
        // its loans (docs/design/apis.md, Stage 4).
        .api_object => true,
        .parameterized_nominal => |pn| blk: {
            // A task's drop waits for its call, which uses the loans the
            // task keeps (CORE sentence 6).
            if (pn.sym == ctx.task_sym_id or pn.sym == ctx.tasks_sym_id) break :blk true;
            for (pn.args) |a| if (runsDropBody(ctx, a, path)) break :blk true;
            break :blk fieldsRunDropBody(ctx, pn.sym, path);
        },
        else => false,
    };
}

fn fieldsRunDropBody(ctx: *const SemContext, sid: SymbolId, path: ?*const SymPath) bool {
    var at = path;
    while (at) |p| : (at = p.up) if (p.sym == sid) return false;
    const node: SymPath = .{ .sym = sid, .up = path };
    const inner = &node;
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
/// of those inline (not behind a handle, a view, or a List's or box's
/// heap memory). A copy of a Cell would fork the state it shares.
pub fn isUnique(ctx: *const SemContext, ty: TypeId) bool {
    const info = ctx.holds(ty);
    return info.unique or info.cell;
}

/// Whether a bare use of a value of `ty` moves it rather than copying
/// it: `yes` when it needs cleanup (`typeHasDropGlue`), is unique
/// (`isUnique`), or holds an `error` (`TypeInfo.any_error`), which is
/// owning in every program; `depends` when it holds a type parameter by
/// value (`maybeDropGlue`), otherwise `no`.
pub fn moves(ctx: *const SemContext, ty: TypeId) Answer {
    const info = ctx.holds(ty);
    if (info.glue or holdsAnyError(ctx, ty) or isUnique(ctx, ty)) return .yes;
    return if (info.holds_type_var) .depends else .no;
}

/// Whether a read that copies nothing out (a `print` argument, an
/// argument a call reads before it runs, a branch of one) reads a value
/// of `ty` where it is, by address, so a later argument must not change
/// it first: a value that needs cleanup (`typeHasDropGlue`), a unique
/// one or one holding an `error` (which move like an owner, so reading
/// them in place lends them), or one of a type parameter. Any other
/// value is copied where the read runs.
pub fn readByAddress(ctx: *const SemContext, ty: TypeId) bool {
    return moves(ctx, ty) != .no;
}

/// How a value that moves (`moves`) is held and released, the drop its
/// storage writes when nothing takes it.
pub const ResourceKind = enum {
    /// `*T`: `x.dropStrong()`.
    shared,
    /// `~T`: `x.dropWeak()`.
    weak,
    /// A value with drop glue (`List`, an object owning resources, ...),
    /// a unique value, or a value of a type parameter: `rig.drop(&x)`.
    /// Needs `var` storage.
    value,
    /// An optional resource such as `*T?`: `rig.drop(&x)`. Needs `var`.
    optional,
};

/// How a value of `ty` is held, or null for a value that copies
/// (`moves` is `no`). A value that moves gets `var` storage, owned `as`
/// and payload bindings, and an owned closure environment; the kind
/// picks its drop call. `rig.drop` releases only what needs cleanup: a
/// unique value, or a value of a type parameter whose instance needs
/// none, drops nothing. The storage plan records it for each binding
/// (`Symbol.hold`) and each value emit holds or discards
/// (`storage.dropKind`); emit reads only those records.
pub fn resourceKind(ctx: *const SemContext, ty: TypeId) ?ResourceKind {
    if (moves(ctx, ty) == .no) return null;
    return switch (ctx.types.get(ty)) {
        .shared => .shared,
        .weak => .weak,
        .optional => .optional,
        else => .value,
    };
}

/// Whether a value of `ty` copies: it is duplicated by a bit copy, with
/// no owner involved. It does not move (`moves`: it owns nothing and is
/// not unique) and holds no write view (`!T`), of which there is only
/// one. So numbers, `Bool`, `?String`, function values, plain enums,
/// structs, enums, arrays, and optionals of values that copy, and read
/// views, copy (Core §1: the plain kind and read views). `depends` when
/// each instance decides. Every place that duplicates a value asks this
/// fact: a bare use, a copy out of a view (`copiedOut`), `fill`, `copy`,
/// and `[n of x]`, a `|+x|` capture, `Cell.get`, and a generic body's
/// requirement (`Requirement.copies`). `+x` of a value that does not
/// copy clones it instead (`cloneable`).
pub fn copies(ctx: *const SemContext, ty: TypeId) Answer {
    if (ctx.holds(ty).views.write) return .no;
    // A type parameter whose bounds name `Copy` copies in every instance.
    switch (ctx.types.get(ty)) {
        .type_var => |param| if (boundApis(ctx, ctx.symbols.items[param]).contains(.Copy)) return .yes,
        else => {},
    }
    return switch (moves(ctx, ty)) {
        .no => .yes,
        .yes => .no,
        .depends => .depends,
    };
}

/// The value a view of type `ty` hands over where its context reads it
/// as a value: the `T` of a `?T` or `!T` when a `T` copies (`copies`),
/// and is no view itself. Null for any other type, and for a `![]T`,
/// which is a slice of elements, not a view of one value. A copy out of
/// a view (Core §4), and a bare write view read as its value (Core
/// sentence 1), both take this value.
pub fn copiedThrough(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const inner = switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| inner,
        else => return null,
    };
    if (writeSliceElem(ctx, ty) != null or isReadOrWriteView(ctx, inner)) return null;
    return if (copies(ctx, inner) == .yes) inner else null;
}

/// The value the payload of `holder`, an optional or fallible value (or
/// a view of one), views: the `T` of a `(?T)?`, `(!T)?`, `(?T)!`, or
/// `(!T)!`, where `T` is no view itself. Null for any other type, and
/// for a payload `![]T`. What `a ?? b` and `a catch b` copy out where
/// they copy their payload (`SemContext.copiesPayload`).
pub fn payloadViewed(ctx: *const SemContext, holder: TypeId) ?TypeId {
    const payload = switch (ctx.types.get(unwrapViews(ctx, holder))) {
        .optional => |inner| inner,
        .fallible => |inner| inner.ok,
        else => return null,
    };
    const viewed = switch (ctx.types.get(payload)) {
        .read_view, .write_view => |inner| inner,
        else => return null,
    };
    if (writeSliceElem(ctx, payload) != null or isReadOrWriteView(ctx, viewed)) return null;
    return viewed;
}

/// What `+x` does for an `x` of type `ty`.
pub const Clone = enum {
    /// Copies the value.
    copy,
    /// Bumps a handle's count: `*T`, `~T`, or an optional of one.
    bump,
    /// Copies a String's bytes into a new String.
    text,
    /// Copies the value, where each instance of the type parameters it
    /// holds is copied.
    depends,
    /// Makes a new owner part by part (`deepCloneable`): a String's bytes
    /// and a List's elements copied, a box's value boxed again, a handle
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
        // `+s` of a `?String` view makes a new owner of its bytes.
        .string, .string_view => return .text,
        .optional => |o| switch (ctx.types.get(o)) {
            .shared, .weak => return .bump,
            else => {},
        },
        else => {},
    }
    return switch (moves(ctx, value)) {
        // A value that does not move copies, but for one holding a write
        // view, which has one holder (Core sentence 2): it has no clone.
        .no => if (copies(ctx, value) == .yes) .copy else .no,
        .yes => if (deepCloneable(ctx, value, null, null)) .deep else .no,
        .depends => .depends,
    };
}

/// The type arguments a generic type's field types are read with, the
/// module whose types they are, and the frame those arguments are read
/// in.
const CloneFrame = struct { params: []const SymbolId, args: []const TypeId, args_ctx: *const SemContext, parent: ?*const CloneFrame };

/// A declared type being checked for a clone: its symbol in the module
/// that declares it.
const CloneSeen = struct { ctx: *const SemContext, sym: SymbolId };

/// The declared types a clone check is inside, nearest first.
const ClonePath = struct { at: CloneSeen, up: ?*const ClonePath };

/// Whether `+x` can make a new owner of a `ty` part by part (Core
/// sentence 2): a String, a List, a box, an optional, an array, or a
/// struct or enum, of this module or another, of parts that clone; a
/// handle, counted again; plain data and read views, copied. A type with
/// a `drop` body has no clone, and neither has a unique type, a Cell, a
/// Signal, a write view, or a type parameter. `seen` holds the declared
/// types being checked: one reached again (a box of a recursive type)
/// clones if the rest of it does.
fn deepCloneable(ctx: *const SemContext, ty: TypeId, frame: ?*const CloneFrame, seen: ?*const ClonePath) bool {
    // An API object clones as its braces or API say (`objectMeets`): a
    // box through its table's `Clone`, never the hidden value itself.
    if (ctx.typeInfo(ty).object) {
        if (objectHeld(ctx, ty)) |h| return objectMeets(ctx, h.object, h.form, .Clone);
        if (apiObject(ctx, ty) != null) return false;
    }
    switch (ctx.types.get(ty)) {
        .type_var => |sym| {
            // A set parameter's value is an error, which clones.
            if (ctx.symbols.items[sym].flags.set_param) return true;
            const f = frame orelse return false;
            const i = std.mem.findScalar(SymbolId, f.params, sym) orelse return false;
            return deepCloneable(f.args_ctx, f.args[i], f.parent, seen);
        },
        else => {},
    }
    const info = ctx.holds(ty);
    if (info.unique or info.cell or info.views.write or info.poison) return false;
    if (!info.glue and !info.holds_type_var) return true;
    return switch (ctx.types.get(ty)) {
        .string, .shared, .weak => true,
        // An error's fields always clone (the field rule), through the
        // program's glue.
        .any_error => true,
        .optional => |inner| deepCloneable(ctx, inner, frame, seen),
        .array => |a| deepCloneable(ctx, a.elem, frame, seen),
        .parameterized_nominal => |pn| blk: {
            if (pn.sym == ctx.list_sym_id or pn.sym == ctx.box_sym_id) break :blk pn.args.len == 1 and deepCloneable(ctx, pn.args[0], frame, seen);
            // A table is never cloned: a copy of a reserved one would
            // touch every page.
            if (pn.sym == ctx.cell_sym_id or pn.sym == ctx.signal_sym_id or pn.sym == ctx.actor_sym_id or pn.sym == ctx.chan_sym_id or pn.sym == ctx.table_sym_id) break :blk false;
            const decl = declaredAt(ctx, pn.sym) orelse break :blk false;
            const sym = decl.ctx.symbols.items[decl.sym];
            if (sym.kind != .generic_type) break :blk false;
            const inner: CloneFrame = .{ .params = sym.type_params orelse &.{}, .args = pn.args, .args_ctx = ctx, .parent = frame };
            break :blk fieldsCloneable(decl.ctx, decl.sym, &inner, seen);
        },
        .nominal => |sym| blk: {
            const decl = declaredAt(ctx, sym) orelse break :blk false;
            break :blk fieldsCloneable(decl.ctx, decl.sym, null, seen);
        },
        .imported_nominal => |in| blk: {
            const foreign = ctx.foreign_semas.get(in.module_id) orelse break :blk false;
            if (in.sym_id >= foreign.symbols.items.len) break :blk false;
            break :blk fieldsCloneable(foreign, in.sym_id, null, seen);
        },
        else => false,
    };
}

/// Symbol `sym` of `ctx` as the module that declares it: itself, or, for
/// a proxy of another module's declaration, that declaration.
fn declaredAt(ctx: *const SemContext, sym: SymbolId) ?CloneSeen {
    const s = ctx.symbols.items[sym];
    if (!isProxy(s)) return .{ .ctx = ctx, .sym = sym };
    const foreign = ctx.foreign_semas.get(s.from.module_id) orelse return null;
    if (s.from.sym >= foreign.symbols.items.len) return null;
    return .{ .ctx = foreign, .sym = s.from.sym };
}

/// Whether every part of type `sym`, declared in `ctx`, clones
/// (`deepCloneable`), and it has no `drop` body.
fn fieldsCloneable(ctx: *const SemContext, sym: SymbolId, frame: ?*const CloneFrame, seen: ?*const ClonePath) bool {
    // A type reached again (a box of a recursive type) clones if the rest
    // of it does, and if each type argument it is reached with clones:
    // `Map[Int, Map[Int, Res]]` reaches `Map` again with a `Res`, which a
    // revisit, which walks no field again, would not otherwise check.
    var at = seen;
    while (at) |t| : (at = t.up) if (t.at.ctx == ctx and t.at.sym == sym) {
        const f = frame orelse return true;
        for (f.args) |arg| if (!deepCloneable(f.args_ctx, arg, f.parent, seen)) return false;
        return true;
    };
    const s = ctx.symbols.items[sym];
    const inner: ClonePath = .{ .at = .{ .ctx = ctx, .sym = sym }, .up = seen };
    for (s.fields orelse &.{}) |*f| {
        if (f.is_drop_method) return false;
        for (dataFields(f)) |d| if (!deepCloneable(ctx, d.ty, frame, &inner)) return false;
    }
    return true;
}

/// Whether a value of `ty` read through a view reads as the value
/// itself: a scalar or a plain enum (`n + 1` with `n: ?Int` is an `Int`,
/// and `v + w` with `v: ?Simd[U8, 16]` a `Simd[U8, 16]`).
pub fn readsAsValue(ctx: *const SemContext, ty: TypeId) bool {
    return isScalar(ctx, ty) or isPlainEnum(ctx, ty);
}

/// The type parameters `ty` holds by value, appended to `out`.
pub fn heldTypeVars(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (!ctx.holds(ty).holds_type_var) return;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| if (std.mem.findScalar(SymbolId, out.items, sym) == null) try out.append(a, sym),
        .optional => |inner| try heldTypeVars(ctx, inner, out, a),
        .fallible => |inner| try heldTypeVars(ctx, inner.ok, out, a),
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

/// The type parameters a value of `ty` can reach at any depth, appended
/// to `out`: through every type constructor that holds its arguments
/// (an optional, a fallible, an array or slice element, a view, a
/// shared or weak handle, and each argument of a generic instance:
/// `List`, `^T`, `Cell`, a user generic). A parameter in a value's
/// `List[T]` or `*Hold[T]` is reached though not held by value
/// (`heldTypeVars`): where the loans a value carries matter, this is the
/// walk.
pub fn reachedTypeVars(ctx: *const SemContext, ty: TypeId, out: *std.ArrayList(SymbolId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (!ctx.typeInfo(ty).has_type_var) return;
    switch (ctx.types.get(ty)) {
        .type_var => |sym| if (std.mem.findScalar(SymbolId, out.items, sym) == null) try out.append(a, sym),
        .optional, .read_view, .write_view, .shared, .weak => |inner| try reachedTypeVars(ctx, inner, out, a),
        .fallible => |inner| try reachedTypeVars(ctx, inner.ok, out, a),
        .array => |arr| try reachedTypeVars(ctx, arr.elem, out, a),
        .slice => |sl| try reachedTypeVars(ctx, sl.elem, out, a),
        .parameterized_nominal => |pn| for (pn.args) |arg| try reachedTypeVars(ctx, arg, out, a),
        else => {},
    }
}

/// Whether a value of `ty` reaches type parameter `sym` at any depth,
/// as `reachedTypeVars` walks, or through one of several results.
pub fn reachesTypeVar(ctx: *const SemContext, ty: TypeId, sym: SymbolId) bool {
    if (!ctx.typeInfo(ty).has_type_var) return false;
    return switch (ctx.types.get(ty)) {
        .type_var => |s| s == sym,
        .optional, .read_view, .write_view, .shared, .weak => |inner| reachesTypeVar(ctx, inner, sym),
        .fallible => |inner| reachesTypeVar(ctx, inner.ok, sym),
        .array => |arr| reachesTypeVar(ctx, arr.elem, sym),
        .slice => |sl| reachesTypeVar(ctx, sl.elem, sym),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (reachesTypeVar(ctx, arg, sym)) break true;
        } else false,
        .results => |parts| for (parts) |part| {
            if (reachesTypeVar(ctx, part, sym)) break true;
        } else false,
        else => false,
    };
}

/// A set parameter `ty` names other than after `!`, as a value's type
/// (`e: E`, `List[E]`, `-> E`), or null: a signature writes one only as
/// the set a function fails with (errors-spec §3.5).
pub fn setParamAsValue(ctx: *const SemContext, ty: TypeId) ?SymbolId {
    if (!ctx.typeInfo(ty).has_type_var) return null;
    return switch (ctx.types.get(ty)) {
        .type_var => |sym| if (ctx.symbols.items[sym].flags.set_param) sym else null,
        .optional, .read_view, .write_view, .shared, .weak, .callable, .range, .slot => |inner| setParamAsValue(ctx, inner),
        .fallible => |f| setParamAsValue(ctx, f.ok),
        .array => |arr| setParamAsValue(ctx, arr.elem),
        .slice => |sl| setParamAsValue(ctx, sl.elem),
        .simd => |v| setParamAsValue(ctx, v.elem),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (setParamAsValue(ctx, arg)) |sym| break sym;
        } else null,
        .results => |parts| for (parts) |part| {
            if (setParamAsValue(ctx, part)) |sym| break sym;
        } else null,
        .function => |f| for (f.params) |param| {
            if (setParamAsValue(ctx, param)) |sym| break sym;
        } else setParamAsValue(ctx, f.returns),
        else => null,
    };
}

/// A set parameter `ty` names as the set of a function value or an owned
/// closure, not of a callable view (`?fun(...) -> T!E`), or null: only a
/// view lends a function of any set at one type.
pub fn setParamUnlent(ctx: *const SemContext, ty: TypeId) ?SymbolId {
    if (!ctx.typeInfo(ty).has_type_var) return null;
    return switch (ctx.types.get(ty)) {
        .callable => |inner| switch (ctx.types.get(inner)) {
            .function => |f| for (f.params) |param| {
                if (setParamUnlent(ctx, param)) |sym| break sym;
            } else setParamUnlent(ctx, okOf(ctx, f.returns)),
            else => setParamUnlent(ctx, inner),
        },
        .function => |f| blk: {
            const ret = ctx.types.get(f.returns);
            if (ret == .fallible and isSetParam(ctx, ret.fallible.set)) break :blk ctx.types.get(ret.fallible.set).type_var;
            for (f.params) |param| if (setParamUnlent(ctx, param)) |sym| break :blk sym;
            break :blk setParamUnlent(ctx, okOf(ctx, f.returns));
        },
        .optional, .read_view, .write_view, .shared, .weak => |inner| setParamUnlent(ctx, inner),
        .fallible => |f| setParamUnlent(ctx, f.ok),
        .array => |arr| setParamUnlent(ctx, arr.elem),
        .slice => |sl| setParamUnlent(ctx, sl.elem),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (setParamUnlent(ctx, arg)) |sym| break sym;
        } else null,
        .results => |parts| for (parts) |part| {
            if (setParamUnlent(ctx, part)) |sym| break sym;
        } else null,
        else => null,
    };
}

pub fn okOf(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .fallible => |f| f.ok,
        else => ty,
    };
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
        .invalid, .unknown, .void, .bool, .string_view, .string, .static, .symbol, .int, .float, .int_literal, .float_literal, .none_literal, .noreturn, .any_error, .ct_value => return local_ctx.intern(ty),
        // An API is named by its home module and symbol in every module.
        .api_object => return local_ctx.intern(ty),
        inline .optional, .read_view, .write_view, .shared, .weak, .range, .callable, .slot => |inner, tag| {
            const local_inner = try importType(local_ctx, foreign_ctx, inner, origin_module_id);
            return local_ctx.intern(@unionInit(Type, @tagName(tag), local_inner));
        },
        .fallible => |f| return local_ctx.intern(.{ .fallible = .{
            .ok = try importType(local_ctx, foreign_ctx, f.ok, origin_module_id),
            .set = try importType(local_ctx, foreign_ctx, f.set, origin_module_id),
        } }),
        .slice => |s| return local_ctx.intern(.{ .slice = .{ .elem = try importType(local_ctx, foreign_ctx, s.elem, origin_module_id) } }),
        .array => |a| return local_ctx.intern(.{ .array = .{
            .elem = try importType(local_ctx, foreign_ctx, a.elem, origin_module_id),
            .len = try importType(local_ctx, foreign_ctx, a.len, origin_module_id),
        } }),
        .simd => |v| return local_ctx.intern(.{ .simd = .{
            .elem = try importType(local_ctx, foreign_ctx, v.elem, origin_module_id),
            .len = try importType(local_ctx, foreign_ctx, v.len, origin_module_id),
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
        // Every module has its own `Endian`, `Arch`, `Order`, `Printer`,
        // and `Hasher`, and each is one type.
        .nominal => |sym_id| return if (sym_id == foreign_ctx.endian_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.endian_sym_id })
        else if (sym_id == foreign_ctx.arch_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.arch_sym_id })
        else if (sym_id == foreign_ctx.order_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.order_sym_id })
        else if (sym_id == foreign_ctx.printer_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.printer_sym_id })
        else if (sym_id == foreign_ctx.hasher_sym_id)
            local_ctx.intern(.{ .nominal = local_ctx.hasher_sym_id })
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
        .results => |parts| {
            var out: std.ArrayList(TypeId) = .empty;
            defer out.deinit(local_ctx.allocator);
            for (parts) |part| try out.append(local_ctx.allocator, try importType(local_ctx, foreign_ctx, part, origin_module_id));
            return local_ctx.internCopy(.{ .results = out.items });
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
        // A generic type is named as this module spells it: `lib.Wrap`,
        // as the type printer names it.
        .name = if (generic) try formatTypeValue(ctx, a, .{ .imported_nominal = .{ .module_id = origin.module_id, .sym_id = origin.sym } }) else fsym.name,
        .kind = fsym.kind,
        .ty = ctx.types.unknown_id,
        .decl_pos = imported_decl_pos,
        .scope = scope_invalid,
        .flags = .{ .is_public = fsym.flags.is_public, .comptime_known = fsym.flags.comptime_known, .per_target = fsym.flags.per_target, .set_param = fsym.flags.set_param, .states_bounds = fsym.flags.states_bounds },
        .contents = fsym.contents,
        .from = origin,
        .apis = fsym.apis,
        .user_apis = fsym.user_apis,
        .implied = fsym.implied,
    });
    // Recorded first: the members of a generic type name the type.
    try ctx.imported.put(ctx.allocator, origin, id);
    // A type parameter's associated types come with it, and the
    // requirements its bodies make of them (`importParam`).
    for (fsym.assoc) |assoc| _ = try proxyOf(ctx, .{ .module_id = origin.module_id, .sym = assoc });
    // An associated type is its base's proxy's.
    if (fsym.assoc_of) |of| {
        const base = try proxyOf(ctx, .{ .module_id = origin.module_id, .sym = of.base });
        if (base != symbol_invalid) {
            ctx.symbols.items[id].assoc_of = .{ .base = base, .api = of.api, .name = of.name };
            ctx.symbols.items[base].assoc = try std.mem.concat(a, SymbolId, &.{ ctx.symbols.items[base].assoc, &.{id} });
        }
    }
    // Past `max_import_depth` nested imports, the proxy is filled in
    // later, by the outermost import, which fills each in turn: a chain
    // of generics, each naming the next, would nest once per link.
    if (ctx.import_depth >= max_import_depth) {
        try ctx.import_pending.append(ctx.allocator, .{ .id = id, .origin = origin });
        return id;
    }
    ctx.import_depth += 1;
    defer ctx.import_depth -= 1;
    try fillProxy(ctx, id, origin);
    if (ctx.import_depth == 1) while (ctx.import_pending.pop()) |p| try fillProxy(ctx, p.id, p.origin);
    return id;
}

/// How many imports `importSymbol` nests before it leaves the rest to the
/// outermost one.
const max_import_depth = 64;

/// A proxy `importSymbol` made and has yet to fill in.
pub const PendingProxy = struct { id: SymbolId, origin: ForeignRef };

/// Fill in the proxy `id` of `origin`: a parameter's type and what its
/// declaring module's bodies record of it, or a generic type's parameters
/// and members. Only the outermost import reads a proxy, once every one
/// it made is filled in; the facts of a type that names one, as it is
/// made, read only its contents, copied when the proxy is made.
fn fillProxy(ctx: *SemContext, id: SymbolId, origin: ForeignRef) std.mem.Allocator.Error!void {
    const foreign = ctx.foreign_semas.get(origin.module_id).?;
    const fsym = foreign.symbols.items[origin.sym];
    const a = ctx.arena.allocator();
    if (fsym.kind != .generic_type) {
        ctx.symbols.items[id].ty = try importType(ctx, foreign, fsym.ty, origin.module_id);
        try importParam(ctx, id, origin);
        return;
    }
    const params = fsym.type_params orelse &.{};
    const tps = try a.alloc(SymbolId, params.len);
    for (params, tps) |tp, *out| out.* = try proxyOf(ctx, .{ .module_id = origin.module_id, .sym = tp });
    ctx.symbols.items[id].type_params = tps;
    const fields = fsym.fields orelse return;
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
        try ctx.generic_requirements.append(ctx.allocator, .{ .param = proxy, .req = r.req, .pos = r.pos, .op = r.op, .module_id = if (r.module_id == 0) m else r.module_id, .body = r.body, .index = r.index });
    };
    for (foreign.plain_reqs.items) |r| if (r.param == origin.sym) {
        try ctx.plain_reqs.append(ctx.allocator, .{ .param = proxy, .pos = r.pos, .element = r.element, .view = r.view, .item = r.item, .module_id = if (r.module_id == 0) m else r.module_id });
    };
    for (foreign.generic_methods.items) |c| if (c.param == origin.sym) {
        const args = try a.alloc(TypeId, c.args.len);
        for (c.args, args) |t, *out| out.* = try importType(ctx, foreign, t, m);
        const result: GenericMethodCall.Result = switch (c.result) {
            .ty => |t| .{ .ty = try importType(ctx, foreign, t, m) },
            .nothing, .dropped => c.result,
        };
        var copy = c;
        copy.param = proxy;
        copy.args = args;
        copy.result = result;
        copy.module_id = if (c.module_id == 0) m else c.module_id;
        try ctx.generic_methods.append(ctx.allocator, copy);
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
        try ctx.addGeneric(.frames, .{ .label = fr.label, .pos = fr.pos, .tys = tys, .names = fr.names, .copies = fr.copies, .marked = fr.marked, .marked_copies = fr.marked_copies, .params = fr.params, .module_id = if (fr.module_id == 0) m else fr.module_id });
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
        _ = try ctx.recordFnInstanceIn(.{ .name = name, .params = params, .args = args, .own = use.own, .shown = use.shown }, 0, foreign.generic_fn_uses_in.items[i]);
    }
    for (foreign.paramEntries(.uses, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .uses, i)) continue;
        try ctx.addUse(try importType(ctx, foreign, foreign.generic_uses.items[i], m), foreign.generic_uses_in.items[i], 0);
    }
    for (foreign.paramEntries(.reaches, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .reaches, i)) continue;
        const r = foreign.generic_reaches.items[i];
        const params = try a.alloc(SymbolId, r.params.len);
        for (r.params, params) |p, *out| out.* = try proxyOf(ctx, .{ .module_id = m, .sym = p });
        const args = try a.alloc(TypeId, r.args.len);
        for (r.args, args) |t, *out| out.* = try importType(ctx, foreign, t, m);
        var copy = r;
        copy.params = params;
        copy.args = args;
        copy.recv = try importType(ctx, foreign, r.recv, m);
        try ctx.addGeneric(.reaches, copy);
    }
    for (foreign.paramEntries(.api_calls, origin.sym)) |i| {
        if (!try firstImport(ctx, m, .api_calls, i)) continue;
        const c = foreign.generic_api_calls.items[i];
        const args = try a.alloc(TypeId, c.args.len);
        for (c.args, args) |t, *out| out.* = try importType(ctx, foreign, t, m);
        try ctx.addGeneric(.api_calls, .{ .recv = try importType(ctx, foreign, c.recv, m), .api = c.api, .method = c.method, .args = args, .slots = c.slots, .pos = c.pos, .module_id = if (c.module_id == 0) m else c.module_id });
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
    /// The receiver's generic arguments: those of the type that declares
    /// the method, reached through any views, handles, and boxes.
    subst: TypeSubst,
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
    const f = m.fields[(try findMember(ctx, m.fields, name, .data)) orelse return null];
    return .{ .field = f, .ty = try substituteType(ctx, f.ty, m.subst), .nominal_sym = m.sym };
}

/// Whether member access on `receiver_ty` reaches a data field `name`
/// (without substituting its type).
pub fn lookupDataFieldConst(ctx: *const SemContext, receiver_ty: TypeId, name: []const u8) ?Field {
    const decl = nominalDecl(ctx, unwrapAccess(ctx, receiver_ty)) orelse return null;
    if (decl.sym == decl.ctx.box_sym_id) return null;
    const fields = decl.symbol().fields orelse return null;
    return fields[memberIn(decl.ctx, fields, name, .data) orelse return null];
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
    const fields = decl.symbol().fields orelse return null;
    return fields[memberIn(decl.ctx, fields, name, .method) orelse return null].receiver;
}

fn methodIn(ctx: *SemContext, peeled: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedMethod {
    const m = membersOf(ctx, peeled) orelse return null;
    const first = (try findMember(ctx, m.fields, name, .method)) orelse return null;
    for (m.fields[first..]) |f| {
        if (!f.is_method or f.is_drop_method) continue;
        if (!std.mem.eql(u8, f.name, name)) continue;
        const sub_id = try substituteType(ctx, f.ty, m.subst);
        const sub = ctx.types.get(sub_id);
        if (sub != .function) continue;
        return .{ .field = f, .receiver = f.receiver, .fn_ty = sub.function, .nominal_sym = m.sym, .subst = m.subst };
    }
    return null;
}

/// The kinds of member a declaration's `fields` hold, as the lookups by
/// name ask for them: a data field, a method that can be called (not the
/// `drop` body), a variant, or any member at all.
pub const MemberKind = enum {
    data,
    method,
    variant,
    any,

    fn has(kind: MemberKind, f: Field) bool {
        return switch (kind) {
            .data => !f.is_method and !f.is_variant,
            .method => f.is_method and !f.is_drop_method,
            .variant => f.is_variant,
            .any => true,
        };
    }
};

const n_member_kinds = @typeInfo(MemberKind).@"enum".field_names.len;
const no_member = std.math.maxInt(u32);

/// The first member of each name and kind among a declaration's `fields`,
/// by its place in them. A declaration's fields are replaced whole, never
/// in place, and never freed before the context is.
const MemberIndex = struct {
    len: usize,
    first: std.StringHashMapUnmanaged([n_member_kinds]u32),
};

/// Fields no longer than this are searched in turn.
const member_index_min = 16;

/// Index the members of `fields`, a declaration's, when there are many
/// (`memberIn`).
fn indexMembers(ctx: *SemContext, fields: []const Field) std.mem.Allocator.Error!void {
    if (fields.len <= member_index_min) return;
    const a = ctx.arena.allocator();
    const entry = try ctx.member_index.getOrPut(a, @intFromPtr(fields.ptr));
    const index = entry.value_ptr;
    if (entry.found_existing and index.len == fields.len) return;
    index.* = .{ .len = fields.len, .first = .empty };
    for (fields, 0..) |f, i| {
        const slot = try index.first.getOrPut(a, f.name);
        if (!slot.found_existing) slot.value_ptr.* = @splat(no_member);
        inline for (0..n_member_kinds) |k| {
            const kind: MemberKind = @fromBackingInt(@intCast(k));
            if (slot.value_ptr[k] == no_member and kind.has(f)) slot.value_ptr[k] = @intCast(i);
        }
    }
}

/// Index the members of every declaration with many (`indexMembers`),
/// so the passes that read them through a `*const SemContext` find a
/// member without walking the others.
fn indexAllMembers(ctx: *SemContext) std.mem.Allocator.Error!void {
    for (ctx.symbols.items) |sym| {
        const fields = sym.fields orelse continue;
        try indexMembers(ctx, fields);
        for (fields) |f| try indexMembers(ctx, f.payload orelse continue);
    }
}

/// The place in `fields`, a declaration's or a variant's payload, of
/// its first member `name` of `kind`, after indexing them (`memberIn`).
pub fn findMember(ctx: *SemContext, fields: []const Field, name: []const u8, kind: MemberKind) std.mem.Allocator.Error!?usize {
    try indexMembers(ctx, fields);
    return memberIn(ctx, fields, name, kind);
}

/// The place in `fields`, a declaration's or a variant's payload, of
/// its first member `name` of `kind`: through the index `indexMembers`
/// built, else in turn.
pub fn memberIn(ctx: *const SemContext, fields: []const Field, name: []const u8, kind: MemberKind) ?usize {
    if (ctx.member_index.getPtr(@intFromPtr(fields.ptr))) |index| {
        if (index.len == fields.len) {
            const firsts = index.first.get(name) orelse return null;
            const i = firsts[@backingInt(kind)];
            return if (i == no_member) null else i;
        }
    }
    for (fields, 0..) |f, i| if (kind.has(f) and std.mem.eql(u8, f.name, name)) return i;
    return null;
}

/// The first variant `name` in `fields` (`memberIn`).
pub fn variantIn(ctx: *const SemContext, fields: []const Field, name: []const u8) ?usize {
    return memberIn(ctx, fields, name, .variant);
}

/// An enum variant of the receiver's nominal, local or imported.
pub fn lookupVariant(ctx: *SemContext, receiver_ty: TypeId, name: []const u8) std.mem.Allocator.Error!?ResolvedVariant {
    const decl = nominalDecl(ctx, receiver_ty) orelse return null;
    const subst = if (membersOf(ctx, unwrapViews(ctx, receiver_ty))) |m| m.subst else TypeSubst.empty;
    const fields = decl.symbol().fields orelse return null;
    if (try findMember(ctx, fields, name, .variant)) |i| {
        const f = fields[i];
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
/// context's arena. This is the one place a type's Rig name is decided:
/// diagnostics print it, and `$name(T)` returns it.
pub fn formatType(ctx: *SemContext, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    return formatTypeIn(ctx, ctx.arena.allocator(), ty_id);
}

/// `formatType` with a caller-chosen allocator.
pub fn formatTypeIn(ctx: *const SemContext, a: std.mem.Allocator, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    return (TypePrinter{ .ctx = ctx, .a = a }).id(ty_id);
}

/// `formatTypeIn` of a type not interned in `ctx`: a built-in type
/// (`Int`, `U8`) that a module may not use itself.
pub fn formatTypeValue(ctx: *const SemContext, a: std.mem.Allocator, ty: Type) std.mem.Allocator.Error![]const u8 {
    return (TypePrinter{ .ctx = ctx, .a = a }).value(ty);
}

/// The byte that brackets each type parameter in a marked spelling.
pub const type_param_mark = 0;

/// `formatTypeIn` with each type parameter, or compile-time value
/// parameter, written as its symbol id between two `type_param_mark`
/// bytes (`List[\x003\x00]`), and each type whose spelling depends on
/// the one a parameter stands for (`spelledPerInstance`) as `t` and its
/// type id (`List[\x00t9\x00]` for `List[T?]`), for a spelling
/// completed per instance: the emitter fills each in (`$name(T)`). A
/// spelling with no mark names one type.
pub fn formatTypeMarked(ctx: *const SemContext, a: std.mem.Allocator, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
    return (TypePrinter{ .ctx = ctx, .a = a, .marked = true }).id(ty_id);
}

/// The marked spelling (`formatTypeMarked`) of generic type `sym`
/// applied to its own parameters: `Pair[A, B]`, with `A` and `B` marked.
/// `List[T, inline: n]` as `formatGenericSelfMarked` spells a generic: its
/// element type marked as the List's parameter, and its length marked as
/// `n`, the runtime's second argument (`InlineList(T, n)`).
pub fn formatInlineListMarked(ctx: *const SemContext, a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const p: TypePrinter = .{ .ctx = ctx, .a = a, .marked = true };
    const list = ctx.list_sym_id;
    const elem = try p.param(ctx.symbols.items[list].type_params.?[0]);
    const len = try a.print("{c}n{c}", .{ type_param_mark, type_param_mark });
    return p.instance(ctx.symbols.items[list].name, try p.withInline(elem, len));
}

pub fn formatGenericSelfMarked(ctx: *const SemContext, a: std.mem.Allocator, sym: SymbolId) std.mem.Allocator.Error![]const u8 {
    const p: TypePrinter = .{ .ctx = ctx, .a = a, .marked = true };
    var args: std.ArrayList(u8) = .empty;
    for (ctx.symbols.items[sym].type_params orelse &.{}, 0..) |tp, i| {
        if (i > 0) try args.appendSlice(a, ", ");
        try args.appendSlice(a, try p.param(tp));
    }
    return p.instance(ctx.symbols.items[sym].name, args.items);
}

const TypePrinter = struct {
    ctx: *const SemContext,
    a: std.mem.Allocator,
    /// Type parameters are marked (`formatTypeMarked`).
    marked: bool = false,

    /// A List's arguments, `args`, with its inline length `len`.
    fn withInline(p: TypePrinter, args: []const u8, len: []const u8) std.mem.Allocator.Error![]const u8 {
        return p.a.print("{s}, inline: {s}", .{ args, len });
    }

    fn id(p: TypePrinter, ty_id: TypeId) std.mem.Allocator.Error![]const u8 {
        // Marked whole, as `t` and its id, for the instance to spell.
        if (p.marked and spelledPerInstance(p.ctx, ty_id)) return p.a.print("{c}t{d}{c}", .{ type_param_mark, ty_id, type_param_mark });
        return p.value(p.ctx.types.get(ty_id));
    }

    fn value(p: TypePrinter, ty: Type) std.mem.Allocator.Error![]const u8 {
        const ctx = p.ctx;
        const a = p.a;
        return switch (ty) {
            .invalid => "invalid",
            .unknown => "unknown",
            .void => "Void",
            .bool => "Bool",
            .string_view => "?String",
            .string => "String",
            .static => "Static",
            .symbol => "Symbol",
            .int => |info| if (info.bits == 0) "Int" else try a.print("{c}{d}", .{ @as(u8, if (info.signed) 'I' else 'U'), info.bits }),
            .float => |info| if (info.bits == 0) "Float" else try a.print("F{d}", .{info.bits}),
            .int_literal => "Int",
            .float_literal => "Float",
            .none_literal => "none",
            .any_error => "error",
            .noreturn => "NoReturn",
            .optional => |inner| try p.suffixed(inner, '?'),
            .fallible => |f| blk: {
                const base = try p.suffixed(f.ok, '!');
                if (f.set == type_any_error) break :blk base;
                break :blk try p.a.print("{s}{s}", .{ base, try p.id(f.set) });
            },
            .read_view => |inner| try a.print("?{s}", .{try p.id(inner)}),
            .api_object => |o| try objectSpelling(ctx, a, o),
            .callable => |f| try p.id(f),
            .write_view => |inner| try a.print("!{s}", .{try p.id(inner)}),
            .shared => |inner| try p.handle(inner, '*'),
            .weak => |inner| try p.handle(inner, '~'),
            .slice => |s| try a.print("[]{s}", .{try p.id(s.elem)}),
            .array => |arr| try a.print("[{s}]{s}", .{ try p.id(arr.len), try p.id(arr.elem) }),
            .simd => |v| try a.print("Simd[{s}, {s}]", .{ try p.id(v.elem), try p.id(v.len) }),
            .slot => |n| try a.print("Slot[{s}]", .{try p.id(n)}),
            .range => |e| try a.print("range of {s}", .{try p.id(e)}),
            .function => |f| if (f.is_sub)
                try a.print("sub({s}){s}", .{ try p.list(f.params), if (f.returns == ctx.types.void_id) "" else "!" })
            else
                try a.print("fun({s}) -> {s}", .{ try p.list(f.params), try p.id(f.returns) }),
            .nominal => |sym| ctx.symbols.items[sym].name,
            .imported_nominal => |in| try p.foreign(in.module_id, in.sym_id),
            // Another module's generic type is its proxy, named as this
            // module spells it (`importSymbol`).
            .parameterized_nominal => |pn| if (pn.sym == ctx.box_sym_id and pn.args.len == 1)
                try p.handle(pn.args[0], '^')
            else if (pn.inline_len > 0)
                try p.instance(ctx.symbols.items[pn.sym].name, try p.withInline(try p.list(pn.args), try a.print("{d}", .{pn.inline_len})))
            else
                try p.instance(ctx.symbols.items[pn.sym].name, try p.list(pn.args)),
            .type_var, .ct_param => |sym| try p.param(sym),
            .ct_value => |v| try a.print("{d}", .{v.int}),
            .results => |parts| try a.print("({s})", .{try p.list(parts)}),
        };
    }

    /// Symbol `sym_id` of another module, spelled the way this module
    /// names it: `other.Point`.
    fn foreign(p: TypePrinter, module_id: u32, sym_id: SymbolId) std.mem.Allocator.Error![]const u8 {
        const other = p.ctx.foreign_semas.get(module_id) orelse return "<imported>";
        if (sym_id >= other.symbols.items.len) return "<imported>";
        const name = other.symbols.items[sym_id].name;
        // A built-in type written in Rig is named with no module.
        if (std.mem.eql(u8, other.name, "std." ++ rig.builtin_module_name)) return name;
        for (p.ctx.imports) |imp| {
            if (imp.module_id == module_id) return p.a.print("{s}.{s}", .{ imp.local_name, name });
        }
        // A module reached only through an import, by its file name.
        return p.a.print("{s}.{s}", .{ other.name, name });
    }

    /// A type parameter: its name, or marked.
    fn param(p: TypePrinter, sym: SymbolId) std.mem.Allocator.Error![]const u8 {
        if (p.marked) return p.a.print("{c}{d}{c}", .{ type_param_mark, sym, type_param_mark });
        return p.ctx.symbols.items[sym].name;
    }

    /// Generic type `name` at arguments `args`: `Pair[Int, ?String]`.
    fn instance(p: TypePrinter, name: []const u8, args: []const u8) std.mem.Allocator.Error![]const u8 {
        return p.a.print("{s}[{s}]", .{ name, args });
    }

    /// Types separated by `, `.
    fn list(p: TypePrinter, ids: []const TypeId) std.mem.Allocator.Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (ids, 0..) |ty_id, i| {
            if (i > 0) try buf.appendSlice(p.a, ", ");
            try buf.appendSlice(p.a, try p.id(ty_id));
        }
        return buf.items;
    }

    /// `T?` / `T!`. A handle binds tighter than a suffix (`*T?` is an
    /// optional handle), so only a prefix type that a suffix cannot follow
    /// takes parentheses: `(?T)?`, `([]Int)?`, `(*sub())?`; and so does an
    /// optional of an optional, `(T?)?`.
    fn suffixed(p: TypePrinter, inner: TypeId, suffix: u8) std.mem.Allocator.Error![]const u8 {
        const s = try p.id(inner);
        // `N??` would lex as the `??` operator: `(N?)?`.
        const doubled = suffix == '?' and p.ctx.types.get(inner) == .optional;
        return if (doubled or takesNoSuffix(p.ctx, inner))
            p.a.print("({s}){c}", .{ s, suffix })
        else
            p.a.print("{s}{c}", .{ s, suffix });
    }

    /// `*T` / `~T`, parenthesizing a suffixed operand: `*(T?)` is a handle
    /// to an optional, while `*T?` is an optional handle.
    fn handle(p: TypePrinter, inner: TypeId, sigil: u8) std.mem.Allocator.Error![]const u8 {
        const s = try p.id(inner);
        return switch (p.ctx.types.get(inner)) {
            // A handle binds tighter than a suffix, and takes no view prefix.
            // A box of a read view is written `^?T`, which the grammar takes.
            .read_view, .string_view => if (sigil == '^') p.a.print("^{s}", .{s}) else p.a.print("{c}({s})", .{ sigil, s }),
            .optional, .fallible, .write_view => p.a.print("{c}({s})", .{ sigil, s }),
            else => p.a.print("{c}{s}", .{ sigil, s }),
        };
    }
};

/// Whether the printer's spelling of `ty` depends on the type a type
/// parameter in it stands for: a suffix after one, which `(T?)?` and
/// `(fun() -> Int)?` put in parentheses (`TypePrinter.suffixed`), or a
/// handle's sigil before one, which `*(T?)` does (`TypePrinter.handle`).
/// A marked spelling leaves such a type to each instance whole
/// (`rig.typeName`), which spells it by the same rules.
fn spelledPerInstance(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .optional => |inner| paramOperand(ctx, inner),
        .fallible => |inner| paramOperand(ctx, inner.ok),
        .shared, .weak => |inner| ctx.types.get(inner) == .type_var,
        .parameterized_nominal => |pn| pn.sym == ctx.box_sym_id and pn.args.len == 1 and ctx.types.get(pn.args[0]) == .type_var,
        else => false,
    };
}

/// A type parameter, or a handle or box of one, whose spelling a suffix
/// may need parentheses around (`takesNoSuffix`).
fn paramOperand(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .type_var => true,
        .shared, .weak => |inner| paramOperand(ctx, inner),
        .parameterized_nominal => |pn| pn.sym == ctx.box_sym_id and pn.args.len == 1 and paramOperand(ctx, pn.args[0]),
        else => false,
    };
}

/// Types separated by `, `.
fn formatTypeList(ctx: *const SemContext, a: std.mem.Allocator, ids: []const TypeId) std.mem.Allocator.Error![]const u8 {
    return (TypePrinter{ .ctx = ctx, .a = a }).list(ids);
}

/// A type whose spelling a suffix cannot follow: a view (which covers
/// the suffix), a slice or array (whose element takes it), a function
/// type (`fun(Int) -> Int?` returns an optional), or a handle to one.
fn takesNoSuffix(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view, .string_view, .function, .slice, .array => true,
        .shared, .weak => |inner| takesNoSuffix(ctx, inner),
        .parameterized_nominal => |pn| pn.sym == ctx.box_sym_id and pn.args.len == 1 and takesNoSuffix(ctx, pn.args[0]),
        else => false,
    };
}

// =============================================================================
// IR helpers shared by the sema passes
// =============================================================================

/// The name a variant pattern's binding `b` binds: `b` itself, or the
/// name of `(kwarg field name)`, a field bound by name. Which field each
/// binds is `SemContext.payloadBindings`.
pub fn bindingName(b: Sexp) Sexp {
    return if (b.isKind(.kwarg)) ir.Kwarg.value(b) else b;
}

/// The member `name` of `object`, as Rig writes it: `object.name`, or
/// `@name` on self, `@`.
pub fn memberText(a: std.mem.Allocator, object: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.eql(u8, object, "@")) return a.print("@{s}", .{name});
    return a.print("{s}.{s}", .{ object, name });
}

pub fn identAt(source: []const u8, sexp: Sexp) ?[]const u8 {
    return switch (sexp) {
        .src => |s| rig.leafText(source, s),
        else => null,
    };
}

/// Call `visitor.jump(j)` for each `break` and `continue` that names
/// construct `c`, labeled `label` (or ""), in the order they appear: the
/// one rule of which construct a jump names (docs/internals/INTERNALS.md, "Loops"),
/// which the type checker records as each jump's `JumpDest` and the
/// walks of a loop's value read. An unlabeled jump names the innermost
/// loop around it, and a labeled one the innermost loop or labeled
/// `match` or `raw` block of its name. A closure's body and a `defer`'s
/// are another body's, which no jump leaves. A `for` source runs before
/// its loop is entered and a loop's `else` after it ends, so a jump there
/// names what is around that loop. `c` is a `while` or `for`, whose
/// condition, step, and body it walks, or the statement a label names.
pub fn eachJumpTo(source: []const u8, c: Sexp, label: []const u8, visitor: anytype) !void {
    switch (c.kind() orelse return) {
        .@"while" => for ([_]Sexp{ ir.While.cond(c), ir.While.step(c), ir.While.body(c) }) |part| try jumpsIn(source, part, label, false, visitor),
        .@"for" => try jumpsIn(source, ir.For.body(c), label, false, visitor),
        // An unlabeled jump never names a block.
        else => try jumpsIn(source, c, label, true, visitor),
    }
}

/// The jumps in `e` that name the construct labeled `label` around it
/// (`eachJumpTo`); `nested`: from inside a construct within it that an
/// unlabeled jump names instead.
fn jumpsIn(source: []const u8, e: Sexp, label: []const u8, nested: bool, visitor: anytype) !void {
    const h = e.kind() orelse return;
    switch (h) {
        .@"break", .@"continue" => {
            const l = ir.get(e, .label);
            const names = if (l == .nil) !nested else label.len > 0 and std.mem.eql(u8, identAt(source, l) orelse "", label);
            if (names) try visitor.jump(e);
        },
        .lambda, .@"defer", .@"errdefer" => return,
        .@"while", .@"for", .labeled => {
            var loop = e;
            // A construct labeled `label` too is the one its jumps name.
            var shadowed = false;
            if (h == .labeled) {
                const stmt = ir.Labeled.stmt(e);
                const same = label.len > 0 and std.mem.eql(u8, identAt(source, ir.Labeled.label(e)) orelse "", label);
                if (!same) return jumpsIn(source, stmt, label, nested, visitor);
                if (!stmt.isKind(.@"while") and !stmt.isKind(.@"for")) return jumpsIn(source, stmt, "", nested, visitor);
                loop = stmt;
                shadowed = true;
            }
            // A nested loop: its `for` source and its `else` are outside
            // it, and inside it only a labeled jump can name a construct
            // around it.
            const is_while = loop.isKind(.@"while");
            if (!is_while) try jumpsIn(source, ir.For.source(loop), label, nested, visitor);
            const inside = if (is_while)
                [3]Sexp{ ir.While.cond(loop), ir.While.step(loop), ir.While.body(loop) }
            else
                [3]Sexp{ ir.For.body(loop), .nil, .nil };
            if (!shadowed and label.len > 0) for (inside) |part| try jumpsIn(source, part, label, true, visitor);
            return jumpsIn(source, ir.get(loop, .@"else"), label, nested, visitor);
        },
        else => {},
    }
    for (rig.children(e)) |c| try jumpsIn(source, c, label, nested, visitor);
}

/// The loop `e` is, labeled or not, and its label; null for a construct
/// that is no loop.
fn loopOf(source: []const u8, e: Sexp) ?struct { loop: Sexp, label: []const u8 } {
    var label: []const u8 = "";
    var loop = e;
    if (e.isKind(.labeled)) {
        label = identAt(source, ir.Labeled.label(e)) orelse "";
        loop = ir.Labeled.stmt(e);
    }
    if (!loop.isKind(.@"while") and !loop.isKind(.@"for")) return null;
    return .{ .loop = loop, .label = label };
}

/// Whether a `break` (with a value, when `valued`) leaves loop `e`,
/// labeled or not (`eachJumpTo`).
pub fn breaksOut(source: []const u8, e: Sexp, valued: bool) bool {
    const l = loopOf(source, e) orelse return false;
    const Found = struct {
        valued: bool,
        found: bool = false,
        pub fn jump(f: *@This(), j: Sexp) error{}!void {
            if (j.isKind(.@"break") and (!f.valued or ir.Break.value(j) != .nil)) f.found = true;
        }
    };
    var found: Found = .{ .valued = valued };
    eachJumpTo(source, l.loop, l.label, &found) catch unreachable;
    return found.found;
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
    /// A `^T` lends the views of its `T`.
    unbox,
    /// A `*T` lends the read views of its `T`.
    handle,
    /// An array or a List lends its elements, `[]T` to read and `![]T` to
    /// write.
    elems,
    /// A `String` lends its bytes, a `?String`.
    text,
    /// A `![]T` is lent on to read, as a `[]T`, and a `!{A}` as a `?{A}`.
    read_only,
    /// An `X?` lends a `View?`: a view of the `X` inside, or `none`.
    optional,
    /// The view is lifted into an optional where a `View?` is expected.
    lift,
    /// A function, or an owned closure, lends a `?fun(...)`.
    callable,
    /// The value reached, of a type that provides an API, lends a `?{A}`,
    /// and to write a `!{A}`: the last row, after the others reach the
    /// value (docs/design/apis.md, Stage 4; `SemContext.erasureOf`).
    erase,
    /// An error of a set without fields, a code, lends a view of the error
    /// value of it where a view of `error` or of a set with fields that
    /// holds it goes (`codeLends`): a constant, `rig.codeView`.
    code,
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
/// the lend table (`Lend`): the elements of an array or a List, or a
/// String's bytes reached through handles (`*String`) and boxes, each a row
/// on the way; nothing of a value that is itself a view (a `?String`, a
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
    if (unwrapAccess(ctx, t) == ctx.types.string_id) {
        while (true) {
            switch (ctx.types.get(t)) {
                .read_view, .write_view => |inner| t = inner,
                .shared => |inner| {
                    if (!lend.push(.handle)) return null;
                    t = inner;
                },
                .string => {
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
        .string_view, .static, .slice => return lend,
        .array => {
            _ = lend.push(.elems);
            return lend;
        },
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id) {
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
    // Any `T` lends `?T`, and `!T` to write; a write lend may be read. A
    // write view of an API object lends its read view, one of another
    // Zig type (`rig.ApiView`).
    switch (types.get(view)) {
        .read_view => |t| if (t == from or objectViewOf(ctx, from, t, .read)) return if (kind == .write and apiObject(ctx, t) != null) lend.push(.read_only) else true,
        .write_view => |t| if ((t == from or objectViewOf(ctx, from, t, .write)) and kind == .write) return true,
        else => {},
    }
    // A function, or an owned closure, lends a `?fun(...)`, one whose
    // failure the view's set holds (`lendsCovariant`).
    if (callableFnTy(ctx, view)) |fn_ty| {
        const owned = switch (types.get(from)) {
            .shared => |inner| lendsCovariant(ctx, inner, fn_ty),
            else => false,
        };
        if (!owned and !(lendsCovariant(ctx, from, fn_ty) and kind == .read)) return false;
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
    // The last row: the value reached lends an API object, which the
    // type checker checks it provides (docs/design/apis.md, Stage 4). A
    // handle and a box lend their value's views first, by their rows;
    // only the value reached is erased.
    if (objectView(ctx, view)) |ov| switch (types.get(from)) {
        .shared => {},
        else => if (boxedType(ctx, from) == null) {
            if (ov.form == .write and kind != .write) return false;
            return lend.push(.erase);
        },
    };
    if (kind == .read and codeLends(ctx, from, view)) return lend.push(.code);
    switch (types.get(from)) {
        // An array lends `[]T`, and `![]T` to write.
        .array => |a| return lendElems(ctx, a.elem, kind, view, lend),
        // A `![]T` is lent on to read as a `[]T`.
        .slice => |sl| if (kind == .write) switch (types.get(view)) {
            .slice => |v| return v.elem == sl.elem and lend.push(.read_only),
            else => {},
        },
        // A String lends its bytes; never to write.
        .string => return kind == .read and view == types.string_view_id and lend.push(.text),
        // A `*T` lends the read views of its `T`, and a `*Frozen[T]` those
        // of the `T` it froze; `!h` lends the handle.
        .shared => |inner| return (kind == .read or changesByMark(ctx, inner)) and lend.push(.handle) and lendRows(ctx, frozenValue(ctx, inner) orelse inner, kind, view, lend),
        else => {
            // A List lends its elements, as an array does.
            if (listElem(ctx, from)) |elem| return lendElems(ctx, elem, kind, view, lend);
            // A box lends the views of its value.
            if (boxedType(ctx, from)) |inner| return lend.push(.unbox) and lendRows(ctx, inner, kind, view, lend);
        },
    }
    return false;
}

/// Whether an error of set `from` is a code lent as an error value where
/// `view` goes: `from` has no fields, and `view` is a read view of
/// `error` or of another set with fields that holds `from`.
fn codeLends(ctx: *const SemContext, from: TypeId, view: TypeId) bool {
    if (!isErrorSet(ctx, from) or setHasFields(ctx, from)) return false;
    const want = switch (ctx.types.get(view)) {
        .read_view => |inner| inner,
        else => return false,
    };
    if (want == ctx.types.any_error_id) return true;
    return want != from and isErrorSet(ctx, want) and setHasFields(ctx, want) and errorSubset(ctx, from, want);
}

/// Whether `t` is the object a view as `form` of object `from` views: of
/// the same API, its braces less the crossing bound the form cannot use
/// (`formBraces`), as `?b` of a `^{A + Sends}` lends a `?{A}`.
fn objectViewOf(ctx: *const SemContext, from: TypeId, t: TypeId, form: ObjectForm) bool {
    const f = apiObject(ctx, from) orelse return false;
    const o = apiObject(ctx, t) orelse return false;
    return f.api.eql(o.api) and formBraces(f.builtins, form).eql(o.builtins);
}

/// Whether `actual` is read as `expected`, which differs from it only by
/// a `Static` where a `?String` goes: the one conversion between the two,
/// which reads the text and writes nothing. It holds for the text itself,
/// a read view of it (`?Static` as `?String`), and an optional of either
/// (a `Static?` as a `(?String)?`). A write view, a handle, and the elements
/// of anything else hold exactly their type.
pub fn readsAsStringView(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    if (actual == ctx.types.static_id) return expected == ctx.types.string_view_id;
    const a = ctx.types.get(actual);
    const e = ctx.types.get(expected);
    return switch (a) {
        .read_view => |inner| e == .read_view and readsAsStringView(ctx, inner, e.read_view),
        .optional => |inner| e == .optional and readsAsStringView(ctx, inner, e.optional),
        else => false,
    };
}

/// The elements of an array or a List of `elem`: `[]T` to read, `![]T`
/// to write.
fn lendElems(ctx: *const SemContext, elem: TypeId, kind: LendKind, view: TypeId, lend: *Lend) bool {
    const want = switch (kind) {
        .read => switch (ctx.types.get(view)) {
            .slice => |sl| sl.elem,
            else => return false,
        },
        .write => writeSliceElem(ctx, view) orelse return false,
    };
    // Read, the elements of a `Static` array or List are `?String`s too
    // (`readsAsStringView`); written, they are exactly their type.
    const reads = want == elem or (kind == .read and readsAsStringView(ctx, elem, want));
    return reads and lend.push(.elems);
}

/// The element type of the `[]T` a value of type `ty` lends (`lendsAs`):
/// an array's or a List's, reached through views, boxes, and handles;
/// null for any other type. Generic inference matches a `[]T` with it.
pub fn lentElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    var t = unwrapViews(ctx, ty);
    while (true) switch (ctx.types.get(t)) {
        .array => |a| return a.elem,
        .shared => |inner| t = inner,
        else => {
            if (listElem(ctx, t)) |elem| return elem;
            t = boxedType(ctx, t) orelse return null;
        },
    };
}

/// `T` of a `List[T]`; null for any other type.
pub fn listElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id and pn.args.len == 1) pn.args[0] else null,
        else => null,
    };
}

// =============================================================================
// Tables and slots
// =============================================================================

/// `T` of a `Table[T, n]`; null for any other type.
pub fn tableElem(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.table_sym_id and pn.args.len == 2) pn.args[0] else null,
        else => null,
    };
}

/// The `Slot[n]` that indexes a `Table[T, n]` without a test; null for
/// any other type.
pub fn tableSlot(ctx: *SemContext, ty: TypeId) std.mem.Allocator.Error!?TypeId {
    return switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (pn.sym == ctx.table_sym_id and pn.args.len == 2) try ctx.intern(.{ .slot = pn.args[1] }) else null,
        else => null,
    };
}

/// `n` of a `Table[T, n]` or a `Slot[n]` (`n_ty` the type of its count,
/// `Type.slot`'s operand), when it is a known count; null for a
/// compile-time parameter.
pub fn slotCount(ctx: *const SemContext, n_ty: TypeId) ?u64 {
    return switch (ctx.types.get(n_ty)) {
        .ct_value => |v| if (v.int < 1 or v.int > max_slot_count) null else @intCast(v.int),
        else => null,
    };
}

/// The largest count of a `Table` or `Slot`: a slot is at most a `U64`
/// below it, and the count is an `Int`.
pub const max_slot_count: Wide = std.math.maxInt(i64);

/// The bytes a `Slot[n]` takes: the fewest of 1, 2, 4, and 8 that hold
/// `n - 1`, so a `Slot[1 << 26]` is four bytes, as a `U32` id is.
pub fn slotBytes(n: u64) u64 {
    const top = n -| 1;
    if (top <= std.math.maxInt(u8)) return 1;
    if (top <= std.math.maxInt(u16)) return 2;
    if (top <= std.math.maxInt(u32)) return 4;
    return 8;
}

/// How a `Table[T, n]` fills its `n` slots with `T()` (Core §10,
/// "Tables"): the one decision, which the element rule
/// (`resolve.builtinElementError`) and emit's lowering both read.
pub const TableFill = enum {
    /// `T` is plain data with no `drop`, and `T()` is all zero bytes: the
    /// slots are reserved, and the system gives each page as zeros when
    /// it is first touched.
    zeros,
    /// `T()` is made in every slot when the table is: `T` owns a
    /// resource, or its default is not all zeros.
    made,
    /// `T` has no default, so no slot can hold one before it is written.
    none,
};

/// The most bytes a table fills up front (`TableFill.made`).
pub const max_made_table_bytes: u128 = 64 << 20;

/// The most bytes a table reserves (`TableFill.zeros`): address space
/// only, which the system backs as pages are touched.
pub const max_reserved_table_bytes: u128 = 1 << 46;

/// How a `Table` of `elem` fills its slots. Decided from the type and the
/// defaults of its fields as written, so it is the same at every pass:
/// a default is zero only as a literal 0, `false`, a variant whose value
/// is 0, `T()` of a type whose default is zeros, or `[n of x]` of a zero.
pub fn tableFill(ctx: *const SemContext, elem: TypeId) TableFill {
    return fillOf(ctx, elem, 0);
}

fn fillOf(ctx: *const SemContext, ty: TypeId, depth: u32) TableFill {
    if (depth > 64) return .none;
    switch (ctx.types.get(ty)) {
        .int, .bool, .slot => return .zeros,
        // A float's default may be `-0.0`, and an optional's none is not
        // zero bytes: each slot is made.
        .float, .string, .optional => return .made,
        .parameterized_nominal => |pn| if (pn.sym == ctx.list_sym_id) return .made else if (isBuiltinGeneric(ctx, pn.sym) or pn.sym == ctx.table_sym_id or pn.sym == ctx.simd_sym_id) return .none,
        .nominal, .imported_nominal => {},
        else => return .none,
    }
    const decl = nominalDecl(ctx, ty) orelse return .none;
    return declFillAt(decl.ctx, decl.sym, depth);
}

/// How a table fills its slots with the object or enum `sym` declares
/// (`tableFill`), the same for every instance of a generic one: a field
/// whose type is a parameter is never taken for zeros, so no argument
/// changes the answer. Emit writes it into the type (`__rig_zeros`).
pub fn declFill(ctx: *const SemContext, sym: SymbolId) TableFill {
    return declFillAt(ctx, sym, 0);
}

fn declFillAt(ctx: *const SemContext, sym_id: SymbolId, depth: u32) TableFill {
    const sym = ctx.symbols.items[sym_id];
    // Another module's generic type is decided where it is declared,
    // whose source its fields' defaults are written in.
    if (isProxy(sym)) {
        const foreign = ctx.foreign_semas.get(sym.from.module_id) orelse return .none;
        return declFillAt(foreign, sym.from.sym, depth + 1);
    }
    if (sym.flags.error_set or sym.kind == .type_alias) return .none;
    const fields = sym.fields orelse return .none;
    // A type that owns, or is unique, is made in each slot.
    var zeros = !sym.contents.glue and !sym.flags.unique;
    for (fields) |f| {
        if (f.is_variant) return .none;
        if (f.is_method or f.is_drop_method) continue;
        const d = f.default orelse return .none;
        if (zeros and (ctx.types.get(f.ty) == .type_var or !zeroDefault(ctx, d, f.ty, depth))) zeros = false;
    }
    return if (zeros) .zeros else .made;
}

/// Whether default `d`, written in `decl_ctx` for a field of type `fty`,
/// is all zero bytes (`tableFill`): by the field's type, an integer or a
/// slot written as a zero literal, `false`, a plain enum's variant whose
/// value is 0, `T()` of an object that fills with zeros, or `[n of x]`
/// of one of these. A float is never taken for zeros (`-0.0` is not),
/// nor an optional (an object's none is kept in a niche, not as zeros).
fn zeroDefault(decl_ctx: *const SemContext, d: Sexp, fty: TypeId, depth: u32) bool {
    const src = decl_ctx.source;
    switch (decl_ctx.types.get(fty)) {
        .int, .slot => return d == .src and zeroLiteralText(identAt(src, d) orelse return false),
        .bool => return d == .src and std.mem.eql(u8, identAt(src, d) orelse return false, "false"),
        .array => |a| return d.isKind(.array_fill) and zeroDefault(decl_ctx, ir.ArrayFill.value(d), a.elem, depth + 1),
        .nominal, .imported_nominal, .parameterized_nominal => {
            if (isPlainEnum(decl_ctx, fty)) {
                if (!d.isKind(.enum_lit)) return false;
                const name = identAt(src, ir.EnumLit.name(d)) orelse return false;
                const decl = nominalDecl(decl_ctx, fty) orelse return false;
                const fields = decl.symbol().fields orelse return false;
                const i = memberIn(decl.ctx, fields, name, .variant) orelse return false;
                return fields[i].value != null and fields[i].value.? == 0;
            }
            // `T()`: zero when the field's own type fills with zeros.
            return d.isKind(.call) and ir.Call.args(d).len == 0 and fillOf(decl_ctx, fty, depth + 1) == .zeros;
        },
        else => return false,
    }
}

/// An integer literal whose value is zero: `0`, `0x0`, `0_000`.
fn zeroLiteralText(text: []const u8) bool {
    var digits = text;
    if (digits.len > 2 and digits[0] == '0' and std.mem.findScalar(u8, "xXbBoO", digits[1]) != null) digits = digits[2..];
    if (digits.len == 0 or digits[0] != '0') return false;
    for (digits) |c| if (c != '0' and c != '_') return false;
    return true;
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

/// Whether `node` is a lane of a vector, `v[i]`: an index whose object
/// is a `Simd[T, n]`, or a view of one.
pub fn isLane(ctx: *const SemContext, node: Sexp) bool {
    if (!node.isKind(.index)) return false;
    const ty = ctx.typeOf(ir.Index.object(node)) orelse return false;
    return simdOf(ctx, ty) != null;
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
        .type_alias, .generic_type, .nominal_type, .module, .api => .none,
    };
}

/// `p.f` or `p[i]`: by the base the path starts from. A lane of a
/// vector, `v[i]`, is a part of the vector's value, not a place: a value
/// made where it is read, as an operator's result is.
fn pathHands(source: []const u8, ctx: ?*const SemContext, node: Sexp) Hands.Kind {
    if (ctx) |c| if (isLane(c, node)) return .made;
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

// =============================================================================
// What `<` does to its source
// =============================================================================

/// What `<e` does to its source (Core §5): `<` always leaves its source
/// done, so a name is ended, an optional place is emptied to `none`, and
/// any other place is rejected. Decided here, once, by a positive list
/// over `handsOver` and the operand's type and root, for every form that
/// carries a move: `<e` wherever it stands, a `for x in <e` source, and
/// each leaf of a branching operand (`moveLeaves`). The type checker
/// records a take where it empties an optional and reports a part of a
/// value made here; the ownership checker ends a binding and reports the
/// rest.
pub const MoveSource = enum {
    /// A binding (a local or a parameter): `<x` ends it.
    binding,
    /// A closure's capture (`|+x|`, `|<x|`, `|?x|`, `|!x|`, `|~x|`):
    /// the closure keeps it for every call, so `<` cannot end it.
    capture,
    /// A field or element holding an optional, of a place (`<p.f`,
    /// `<v[i]`, `<(!p).f`): it is emptied to `none`.
    optional_part,
    /// Any other field or element of a place: it can be neither ended
    /// nor emptied.
    part,
    /// A field or element of a branching value (`(a if c else b).f`),
    /// which may be a binding's: neither ended nor emptied.
    branch_part,
    /// A field or element of a value made here (`mk().n`, `[a, b][0]`),
    /// which its statement drops: nothing would see it ended or emptied.
    made_part,
    /// What lives for the whole program: a function, or a module's
    /// constant or a part of one (`K`, `geo.K`, `geo.KP[0]`).
    declared,
    /// A value made here: a call, a constructor, a literal, a lend, an
    /// enum variant (`Color.red`), a `match` or block. Nothing is left
    /// behind.
    made,
    /// A branching value (`a if c else b`, `a ?? b`, `e catch h`, `e!`,
    /// `e?`): what each leaf gives up (`moveLeaves`).
    branches,
};

pub fn moveSource(ctx: *const SemContext, e: Sexp) MoveSource {
    switch (handsOver(ctx, e).kind) {
        .made, .lend, .jump, .none => return .made,
        .branches => return .branches,
        .part_of_made => return if (handsOver(ctx, pathRoot(e)).kind == .branches) .branch_part else .made_part,
        .place => {},
    }
    const root = pathRoot(e);
    // A path through a lend or a view made here reaches a place. An
    // optional there is not emptied where the view sees only values made
    // in the statement (`(!mk()).o`); any other part is rejected as one
    // reached through a view.
    if (root != .src) {
        const source = partSource(ctx, e);
        return if (source == .optional_part and viewsOnlyMade(ctx, root)) .made_part else source;
    }
    const sym = ctx.symbols.items[
        ctx.symbolOf(root) orelse {
            // A built-in type's member (`Int.min`) is a value; a name sema
            // could not resolve was reported, and stands for a binding.
            if (e != .src and ctx.typeOf(root) == null) return .made;
            return if (e == .src) .binding else partSource(ctx, e);
        }
    ];
    switch (sym.kind) {
        .param, .generic_param => return if (e == .src) .binding else partSource(ctx, e),
        .capture => return if (e != .src) partSource(ctx, e) else if (ctx.isOnceCapture(ctx.symbolOf(root).?)) .binding else .capture,
        .local => {
            if (sym.scope == module_scope) return .declared;
            return if (e == .src) .binding else partSource(ctx, e);
        },
        .function, .@"extern" => return .declared,
        // `module.name`: a constant or function of the module, or a type
        // whose member this path names.
        .module => {
            var q = e;
            while (ir.get(q, .object) != .src) q = ir.get(q, .object);
            if (ctx.typeOf(q) != null) return .declared;
            return typeMemberSource(ctx, e);
        },
        .nominal_type, .type_alias, .generic_type, .api => return typeMemberSource(ctx, e),
    }
}

/// Whether the element a `for` binds views a slot of the List it walks
/// in place, a List of values that move: `for x in ?v`, or a bare
/// `for x in v`, over a `List[String]`. The List owns what the slot holds,
/// so the element is never moved, dropped, cloned, or stored. Decided
/// here, once: the type checker marks the element (`slot_view`), and the
/// ownership checker walks it as a loop view.
pub fn forViewsSlot(ctx: *const SemContext, node: Sexp) bool {
    if (ir.For.mode(node).tag != .read and ctx.headerOf(node) == null) return false;
    const source = ir.For.source(node);
    if (handsOver(ctx, source).kind != .place) return false;
    const ty = ctx.typeOf(source) orelse return false;
    const elem = listElem(ctx, unwrapViews(ctx, ty)) orelse return false;
    return moves(ctx, elem) == .yes;
}

/// Why `<x` cannot drop the binding `x`, where it cannot.
pub const Undroppable = enum {
    /// A `?T` or `!T` parameter: the caller owns what it views.
    view_param,
    /// A closure's capture: the closure keeps it for every call
    /// (`moveSource`).
    capture,
    /// A `for` element that views a slot of the List it walks
    /// (`forViewsSlot`).
    loop_slot,
};

/// Why `<name` cannot drop the binding `name` names; null where it
/// drops it. Decided here, once: the ownership checker rejects such a
/// `<x` by it, and the type checker offers `<x` for a statement `-x`
/// only where it drops.
pub fn undroppable(ctx: *const SemContext, name: Sexp) ?Undroppable {
    if (name != .src) return null;
    if (moveSource(ctx, name) == .capture) return .capture;
    const sym = ctx.symbols.items[ctx.symbolOf(name) orelse return null];
    if (sym.kind == .param and isReadOrWriteView(ctx, sym.ty)) return .view_param;
    if (sym.flags.slot_view) return .loop_slot;
    return null;
}

/// Whether `v`, a view made here, sees only values made in its statement:
/// a lend of one (`!mk()`, `?mk().w`), or a call's view result whose
/// every argument it carries a view from is such a view (`gw(!mk())`).
fn viewsOnlyMade(ctx: *const SemContext, v: Sexp) bool {
    if (v.isKind(.read) or v.isKind(.write)) {
        const operand = ir.get(v, .operand);
        return switch (handsOver(ctx, operand).kind) {
            .made => true,
            // A part of a branching value may be a binding's.
            .part_of_made => handsOver(ctx, pathRoot(operand)).kind != .branches,
            .place, .lend, .branches, .jump, .none => false,
        };
    }
    if (!v.isKind(.call)) return false;
    const params = ctx.callParamsOf(v) orelse return false;
    var seen = false;
    const callee = ir.Call.callee(v);
    if (callee.isKind(.member) and params.resultCarriesReceiver()) {
        if (!viewsOnlyMade(ctx, ir.Member.object(callee))) return false;
        seen = true;
    }
    for (ir.Call.args(v), 0..) |arg, i| {
        if (!params.resultCarries(i)) continue;
        const value = if (arg.isKind(.kwarg)) ir.get(arg, .value) else arg;
        // An argument that holds no view gives the result none.
        const ty = ctx.typeOf(value) orelse return false;
        if (!mayHoldView(ctx, ty)) continue;
        if (!viewsOnlyMade(ctx, value)) return false;
        seen = true;
    }
    return seen;
}

/// A field or element of a place: emptied when it holds an optional.
fn partSource(ctx: *const SemContext, e: Sexp) MoveSource {
    const ty = ctx.typeOf(e) orelse return .part;
    return if (ctx.types.get(ty) == .optional) .optional_part else .part;
}

/// A type's member (`Color.red`, `Point.origin`): a function lives for
/// the whole program; any other is a value.
fn typeMemberSource(ctx: *const SemContext, e: Sexp) MoveSource {
    const ty = ctx.typeOf(e) orelse return .made;
    return if (ctx.types.get(ty) == .function) .declared else .made;
}

/// The value a field or element path starts from: `mk()` in
/// `mk().v[0]`; `e` itself for any other node.
pub fn pathRoot(e: Sexp) Sexp {
    var p = e;
    while (p.isKind(.member) or p.isKind(.index)) p = ir.get(p, .object);
    return p;
}

/// A leaf of a branching `<e` that `<` would leave as it was, and what it
/// is (`moveSource`).
pub const MoveLeaf = struct { node: Sexp, source: MoveSource };

/// The leaves of `operand`, a branching value under `<`, that `<` cannot
/// take: every leaf but a value made there, appended to `out` in order.
/// (An operand of `<` is an expression, so no leaf is a name it declares:
/// a block-form `if` or `match` cannot follow `<`.)
pub fn moveLeaves(a: std.mem.Allocator, ctx: *const SemContext, operand: Sexp, out: *std.ArrayList(MoveLeaf)) std.mem.Allocator.Error!void {
    var parts = valueParts(operand);
    while (parts.next()) |p| {
        if (p.node == .nil) continue;
        const source = moveSource(ctx, p.node);
        switch (source) {
            .made => {},
            .branches => try moveLeaves(a, ctx, p.node, out),
            .binding, .capture, .optional_part, .part, .branch_part, .made_part, .declared => try out.append(a, .{ .node = p.node, .source = source }),
        }
    }
}

/// A name of a type or module, or a generic type's instance
/// (`List[Int]`): it has no value of its own.
fn namesTypeOrModule(ctx: *const SemContext, e: Sexp) bool {
    if (ctx.instanceOf(e)) |inst| return inst == .type;
    const sym = ctx.symbolOf(e) orelse return false;
    return switch (ctx.symbols.items[sym].kind) {
        .type_alias, .generic_type, .nominal_type, .module, .api => true,
        .function, .param, .local, .generic_param, .@"extern", .capture => false,
    };
}

/// A number, string, character, or Bool literal's text.
fn isLiteralLeafText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (isStringLiteralText(text)) return true;
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
        .module, .use, .fun, .sub, .@"struct", .@"enum", .errors, .error_join, .generic_struct, .generic_enum, .api, .api_type, .api_add, .type, .@"test", .@"pub", .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .drop_decl, .@"inline", .called, .rarely, .@":", .bound, .assoc_bound, .default, .valued, .none_value, .variant, .captures, .cap_clone, .cap_move, .cap_weak, .cap_read, .cap_write => .none,
        // Statements, and the parts of statements, conditions, and calls.
        .set, .destructure, .results, .drop, .pass, .@"defer", .@"errdefer", .as, .as_results, .as_pattern, .as_match, .shadow, .shadow_fixed, .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"+%=", .@"-%=", .@"*%=", .@"+|=", .@"-|=", .@"&=", .@"|=", .@"^=", .@"<<=", .@"<<%=", .@">>=", .iter, .kwarg => .none,
        // Patterns and arms.
        .arm, .alt_pattern, .range_pattern, .variant_pattern, .set_pattern => .none,
        // `>t`, `f: once T`, and `a..=b`, which the Parser wrapper rewrites first.
        .wait, .once, .@"..=" => .none,
        // Types.
        .optional, .error_union, .read_view, .write_view, .shared, .boxed, .slice, .generic_inst, .array_type, .fun_type, .results_type, .api_object, .fails, .unique, .fixed, .task, .inclusive => .none,
        .@"return", .@"break", .@"continue", .panic => .jump,
        .read, .write => .lend,
        .member, .index => .path,
        .@"if", .@"??", .@"catch", .propagate, .propagate_none => if (isBranchingForm(node)) .branches else .none,
        // A loop, labeled or not, is a value when a `break` leaves it
        // with one.
        .@"while", .@"for", .labeled => if (hasValueBreaks(source, node)) .made else .none,
        // A destructure's target takes its result out of the statement's
        // temporary, whole, as a binding takes a call's result.
        // A compile-time call is a value made where it is written, as an
        // array literal is.
        .call, .builtin, .inst, .ct_call, .lambda, .match, .block, .raw_block, .enum_lit, .symbol, .array, .array_fill, .tuple, .result_part, .move, .clone, .share, .box, .weak => .made,
        .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@"and", .@"or", .@"..", .neg, .not => .made,
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

/// Whether header subject `subject` gives a write view it makes, which
/// the header lends on (`match`, `if … as`): a write lend `!x`, or a
/// value of a write view type whose every leaf (`yieldedLeaves`) is a
/// write lend, a call's result, a write view taken with `<w`, or a jump
/// that gives no value (`getw(!e)`, `(!a if c else !b)`,
/// `optw(!e) ?? !d`, `tryw(!e) catch !d`, `<slot`). Any other subject, a place or a leaf that is
/// one included, is only read. The one decider of a header that lends
/// on a write view, by a positive list.
pub fn makesWriteView(ctx: *const SemContext, subject: Sexp) std.mem.Allocator.Error!bool {
    if (subject.isKind(.write)) return true;
    const ty = ctx.typeOf(subject) orelse return false;
    switch (ctx.types.get(ty)) {
        .write_view => {
            var leaves: std.ArrayList(Sexp) = .empty;
            defer leaves.deinit(ctx.allocator);
            try yieldedLeaves(ctx.allocator, ctx.source, subject, &leaves);
            var made = false;
            for (leaves.items) |leaf| {
                if (leaf.isKind(.write) or leaf.isKind(.call) or leaf.isKind(.move)) {
                    made = true;
                } else if (handsOver(ctx, leaf).kind != .jump) return false;
            }
            return made;
        },
        else => return false,
    }
}

/// A value that is one of its operands: `a if c else b`, `a ?? b`,
/// `e catch h`, `e!`, or `e?`. An `if` without an `else` is a statement.
pub fn isBranchingForm(node: Sexp) bool {
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

/// The values a loop used as a value gives, appended to `out`: the value
/// of each `break` that leaves it (`eachJumpTo`), and its `else`'s tail.
pub fn loopValues(a: std.mem.Allocator, source: []const u8, e: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    const l = loopOf(source, e) orelse return;
    const Values = struct {
        a: std.mem.Allocator,
        out: *std.ArrayList(Sexp),
        pub fn jump(v: *@This(), j: Sexp) std.mem.Allocator.Error!void {
            if (j.isKind(.@"break") and ir.Break.value(j) != .nil) try v.out.append(v.a, ir.Break.value(j));
        }
    };
    var values: Values = .{ .a = a, .out = out };
    try eachJumpTo(source, l.loop, l.label, &values);
    const else_ = ir.get(l.loop, .@"else");
    if (else_ != .nil) {
        const tail = tailOf(else_);
        if (tail != .nil) try out.append(a, tail);
    }
}

/// The leaves of the value `node` gives, appended to `out`, through
/// every form that gives one of its parts: the tails of an `if`, a
/// `match`, and a block, the operands of `??`, `catch`, `e!`, and `e?`
/// (`valueParts`), and the values of a loop used as a value
/// (`loopValues`). Any other node is its own leaf. The one walk of what
/// a value may be, at its leaves: a branching value and a loop alike.
pub fn yieldedLeaves(a: std.mem.Allocator, source: []const u8, node: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
    switch (node.kind() orelse return out.append(a, node)) {
        .@"while", .@"for", .labeled => if (hasValueBreaks(source, node)) {
            var values: std.ArrayList(Sexp) = .empty;
            defer values.deinit(a);
            try loopValues(a, source, node, &values);
            for (values.items) |v| try yieldedLeaves(a, source, v, out);
            return;
        },
        else => {},
    }
    var parts = valueParts(node);
    var any = false;
    while (parts.next()) |p| {
        any = true;
        if (p.node != .nil) try yieldedLeaves(a, source, p.node, out);
    }
    if (!any) try out.append(a, node);
}

/// A loop used as a value: a `while` or `for`, labeled or not, that a
/// `break` with a value leaves.
pub fn hasValueBreaks(source: []const u8, e: Sexp) bool {
    return breaksOut(source, e, true);
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
        const fid = foreign.moduleMember(identAt(self.ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
        const c = foreign.const_ints.get(fid) orelse return null;
        return .{ .v = c.value };
    }

    pub fn literalInt(self: CheckedNames, e: Sexp) ?IntInfo {
        return switch (self.ctx.types.get(self.ctx.typeOf(e) orelse return null)) {
            .int => |i| i,
            else => null,
        };
    }

    /// A compile-time call's integer value, which the checker computed
    /// and recorded where it typed the call.
    pub fn ctCall(self: CheckedNames, e: Sexp) CtFold {
        return cteval.recordedInt(self.ctx, e);
    }
};

/// `constInt` with what `names` knows (`ctFoldBy`).
pub fn constIntBy(ctx: *const SemContext, e: Sexp, names: anytype) ConstInt {
    return switch (ctFoldBy(ctx, e, names)) {
        .value => |t| .{ .value = t.v },
        .not_constant, .mismatch, .failed => .not_constant,
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
    /// A compile-time call in it failed, and was reported at the call
    /// (`cteval.callAt`).
    failed,
};

/// The result of one integer operation on constants (`ctArith`).
pub const Arith = union(enum) {
    value: Wide,
    /// The result does not fit the operation's type.
    overflow,
    /// `/` or `%` by zero.
    div_zero,
    /// A shift by a negative amount, or by the type's width or more.
    shift_range,
};

/// The one arithmetic core of constant folding (`ctFoldBy`) and of
/// compile-time functions (`cteval`): the binary operator `h` on `a` and
/// `b` in the integer type `int`. Wrapping and saturating operators and
/// `<<%` need a type; the others compute exactly without one (literals
/// alone, whose context types them later).
pub fn ctArith(h: Tag, a: Wide, b: Wide, int: ?IntInfo) Arith {
    switch (h) {
        // Wrapping arithmetic keeps the low bits of the result in its
        // type, which a `Wide` computes exactly (its width is a multiple
        // of every integer type's).
        .@"+%", .@"-%", .@"*%" => {
            const v = switch (h) {
                .@"+%" => a +% b,
                .@"-%" => a -% b,
                else => a *% b,
            };
            return .{ .value = wrapTo(int.?, v) };
        },
        // Saturating arithmetic stops at the type's limits, which a
        // `Wide` holds.
        .@"+|", .@"-|" => {
            const r = intRange(int.?);
            const v = if (h == .@"+|") a + b else a - b;
            return .{ .value = std.math.clamp(v, r.min, r.max) };
        },
        // A shift keeps the low bits too, if its amount is below the
        // width.
        .@"<<%" => {
            if (b < 0 or b >= int.?.width()) return .shift_range;
            return .{ .value = wrapTo(int.?, a << @intCast(b)) };
        },
        else => {},
    }
    const v: ?Wide = switch (h) {
        .@"+" => std.math.add(Wide, a, b) catch null,
        .@"-" => std.math.sub(Wide, a, b) catch null,
        .@"*" => std.math.mul(Wide, a, b) catch null,
        .@"/" => if (b == 0) return .div_zero else std.math.divTrunc(Wide, a, b) catch null,
        .@"%" => if (b == 0) return .div_zero else if (b == -1) 0 else @rem(a, b),
        // A shift by the width or more is out of range; one that loses
        // bits overflows.
        .@"<<" => if (b < 0 or b >= (int orelse IntInfo{}).width()) return .shift_range else blk: {
            const r = a << @intCast(b);
            break :blk if (r >> @intCast(b) == a) r else null;
        },
        .@">>" => if (b < 0 or b >= (int orelse IntInfo{}).width()) return .shift_range else a >> @intCast(b),
        .@"&" => a & b,
        .@"|" => a | b,
        .@"^" => a ^ b,
        else => unreachable,
    };
    const r = v orelse return .overflow;
    if (int) |i| if (!intInfoFits(i, r)) return .overflow;
    return .{ .value = r };
}

/// The one constant evaluator: the value of a constant integer
/// expression, for module and local constants, array lengths,
/// compile-time arguments, and enum values. It reads the program only
/// through `names`, which answers for the context the expression is in:
/// `symbol(leaf) ?SymbolId`, the declaration a name is; `name(leaf)`
/// and `member(e)`, each a `?TypedInt`, the value of a constant and of
/// another module's (`lib.N`); and `literalInt(e) ?IntInfo`, the integer
/// type arithmetic on literals alone is computed in (for a wrapping
/// operation or a shift). A `names` that declares `ctCall(e) CtFold`
/// gives the value of a compile-time call (`cap[8]`), so every folding
/// site folds calls too.
pub fn ctFoldBy(ctx: *const SemContext, e: Sexp, names: anytype) CtFold {
    switch (e) {
        .src => {
            const text_ = identAt(ctx.source, e) orelse "";
            if (isIntLiteralText(text_)) return if (std.fmt.parseInt(Wide, text_, 0)) |v| .{ .value = .{ .v = v } } else |_| .{ .overflow = .{ .node = e, .int = null } };
            return if (names.name(e)) |t| .{ .value = t } else .not_constant;
        },
        .list => {
            const h = e.kind() orelse return .not_constant;
            if (h == .ct_call) {
                if (comptime @hasDecl(@TypeOf(names), "ctCall")) return names.ctCall(e);
                return .not_constant;
            }
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
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => {},
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
            const shift = h == .@"<<" or h == .@"<<%" or h == .@">>";
            if (!shift) if (a.int) |ai| if (b.int) |bi| if (!std.meta.eql(ai, bi)) return .{ .mismatch = .{ .node = e, .a = ai, .b = bi } };
            var int = if (shift) a.int orelse names.literalInt(e) else a.int orelse b.int;
            // Literals alone wrap and saturate in the type their context
            // gives them; without one, the width is not known here, so
            // the program computes it.
            switch (h) {
                .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<%" => int = int orelse names.literalInt(e) orelse return .not_constant,
                else => {},
            }
            return switch (ctArith(h, a.v, b.v, int)) {
                .value => |v| .{ .value = .{ .v = v, .int = int } },
                .overflow => .{ .overflow = .{ .node = e, .int = int } },
                // Division by zero and shift amounts out of range are
                // reported where the operator is checked.
                .div_zero, .shift_range => .not_constant,
            };
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
            const module = c.lookupAt(sym.scope, identAt(c.source, m) orelse return null, m.src.pos) orelse return null;
            if (c.symbols.items[module].kind != .module) return null;
            const foreign = c.foreign_semas.get(c.module_refs.get(module) orelse return null) orelse return null;
            alias = foreign.moduleMember(identAt(c.source, ir.Member.name(target)) orelse return null) orelse return null;
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
            const alias = foreign.moduleMember(identAt(ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
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

/// A match pattern that names a module constant: a bare name the
/// resolver recorded as one (`ESC`), or another module's (`lib.ESC`).
/// The context that declares the constant, and its symbol there.
pub const PatternConst = struct { ctx: *const SemContext, id: SymbolId };

/// The one classifier of a constant pattern: a pattern that is a module
/// constant's name compares with its value, and binds nothing.
pub fn patternConst(ctx: *const SemContext, pattern: Sexp) ?PatternConst {
    switch (pattern) {
        .src => {
            const id = ctx.symbolOf(pattern) orelse return null;
            return if (isModuleConst(ctx, id)) .{ .ctx = ctx, .id = id } else null;
        },
        .list => {
            if (!pattern.isKind(.member)) return null;
            const obj = ir.Member.object(pattern);
            if (obj != .src) return null;
            const id = ctx.symbolOf(obj) orelse ctx.lookupInScopeOnly(module_scope, identAt(ctx.source, obj) orelse return null) orelse return null;
            if (ctx.symbols.items[id].kind != .module) return null;
            const foreign = ctx.foreign_semas.get(ctx.module_refs.get(id) orelse return null) orelse return null;
            const fid = foreign.moduleMember(identAt(ctx.source, ir.Member.name(pattern)) orelse return null) orelse return null;
            return if (isModuleConst(foreign, fid)) .{ .ctx = foreign, .id = fid } else null;
        },
        else => return null,
    }
}

/// Whether symbol `id` is a module-level binding, which is a constant.
pub fn isModuleConst(ctx: *const SemContext, id: SymbolId) bool {
    const sym = ctx.symbols.items[id];
    return sym.kind == .local and sym.scope == module_scope;
}

/// The value of a scalar constant as a pattern compares with it.
pub const ConstScalar = union(enum) { int: Wide, boolean: bool, variant: []const u8 };

/// The value of the constant `c` names, when Rig knows it as it checks
/// the program: an integer (`const_ints`), a Bool, or a variant named
/// alone. Null for any other value, and for one the target sets.
pub fn constScalar(c: PatternConst) ?ConstScalar {
    return constScalarAt(c.ctx, c.id, 0);
}

fn constScalarAt(ctx: *const SemContext, id: SymbolId, depth: u32) ?ConstScalar {
    // A chain of constants longer than this is a cycle, reported elsewhere.
    if (depth > 64 or ctx.symbols.items[id].flags.per_target) return null;
    if (ctx.const_ints.get(id)) |c| return .{ .int = c.value };
    const value = for (ctx.const_order.items) |decl| {
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        if (ctx.symbolOf(ir.Set.target(set)) == id) break ir.Set.value(set);
    } else return null;
    return scalarOf(ctx, value, depth);
}

fn scalarOf(ctx: *const SemContext, e: Sexp, depth: u32) ?ConstScalar {
    switch (e) {
        .src => {
            const word = identAt(ctx.source, e) orelse return null;
            if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
            const id = ctx.symbolOf(e) orelse ctx.lookupInScopeOnly(module_scope, word) orelse return null;
            return if (isModuleConst(ctx, id)) constScalarAt(ctx, id, depth + 1) else null;
        },
        .list => {
            const h = e.kind() orelse return null;
            switch (h) {
                .enum_lit => return .{ .variant = identAt(ctx.source, ir.EnumLit.name(e)) orelse return null },
                .member => {
                    if (patternConst(ctx, e)) |c| return constScalarAt(c.ctx, c.id, depth + 1);
                    // `Color.red`: a variant named through its enum, which
                    // is a type, not a value.
                    if (ctx.typeOf(ir.Member.object(e)) != null) return null;
                    return .{ .variant = identAt(ctx.source, ir.Member.name(e)) orelse return null };
                },
                .@"if" => if (ir.If.@"else"(e) != .nil) {
                    const c = constBoolBy(ctx, ir.If.cond(e), CheckedNames{ .ctx = ctx }) orelse return null;
                    return scalarOf(ctx, if (c) ir.If.then(e) else ir.If.@"else"(e), depth);
                },
                else => {},
            }
            return .{ .boolean = constBoolBy(ctx, e, CheckedNames{ .ctx = ctx }) orelse return null };
        },
        else => return null,
    }
}

/// The first name or `module.name` in `e` that is set for each target
/// (`SymbolFlags.per_target`): `target.arch`, or a constant whose value
/// names it. Null when `e` names none.
pub fn perTargetLeaf(ctx: *const SemContext, e: Sexp) ?Sexp {
    switch (e) {
        .src => {
            const id = ctx.symbolOf(e) orelse ctx.lookupInScopeOnly(module_scope, identAt(ctx.source, e) orelse return null) orelse return null;
            return if (ctx.symbols.items[id].flags.per_target) e else null;
        },
        .list => {
            // A member's name, a variant's, and a symbol's are not names
            // in scope.
            if (e.isKind(.enum_lit) or e.isKind(.symbol)) return null;
            if (e.isKind(.member)) {
                if (foreignMemberOf(ctx, e)) |f| return if (f.flags.per_target) e else null;
                return perTargetLeaf(ctx, ir.Member.object(e));
            }
            for (e.items()) |c| if (perTargetLeaf(ctx, c)) |leaf| return leaf;
            return null;
        },
        else => return null,
    }
}

/// The symbol `module.name` names in an imported module; null when `e`
/// is not such a member.
fn foreignMemberOf(ctx: *const SemContext, e: Sexp) ?Symbol {
    const obj = ir.Member.object(e);
    if (obj != .src) return null;
    const id = ctx.symbolOf(obj) orelse ctx.lookupAt(module_scope, identAt(ctx.source, obj) orelse return null, obj.src.pos) orelse return null;
    if (ctx.symbols.items[id].kind != .module) return null;
    const foreign = ctx.foreign_semas.get(ctx.module_refs.get(id) orelse return null) orelse return null;
    const fid = foreign.moduleMember(identAt(ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
    return foreign.symbols.items[fid];
}

/// Why a value Rig needs is not known when it checks the program: the
/// target sets `leaf` (`perTargetLeaf`).
pub const per_target_why = "the value of `{s}` is chosen for each target when Zig compiles the program, so Rig does not know it";

/// The value of a constant Bool expression: literals, `not`, `and`,
/// `or`, and comparisons of constant integers (`ctFoldBy`).
pub fn constBoolBy(ctx: *const SemContext, e: Sexp, names: anytype) ?bool {
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
/// `(read @)`, `(write @)`, `(move @)`, or a bare name.
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

/// The lend a capture of a field path makes where its closure is made,
/// `(read (member p a))` for `|?p.a|`; `_` for a capture of a name.
pub fn captureValue(cap: Sexp) Sexp {
    _ = captureModeOf(cap) orelse return .nil;
    return ir.get(cap, .value);
}

/// Whether place `outer`, a name or a field path (`p`, `p.a`, `@`,
/// `@template`), holds place `inner` and is not it: `p` holds `p.a`,
/// `@` holds `@template`, `p.a` holds `p.a.b`.
pub fn pathHolds(outer: []const u8, inner: []const u8) bool {
    if (inner.len <= outer.len or !std.mem.startsWith(u8, inner, outer)) return false;
    return inner[outer.len] == '.' or std.mem.eql(u8, outer, "@");
}

/// The captures of a closure's `captures` slot (`_` when it has none).
pub fn captureList(captures: Sexp) []const Sexp {
    if (captures == .nil) return &.{};
    return ir.Captures.caps(captures);
}

/// Whether literal text `text` is a string's, double- or single-quoted.
pub fn isStringLiteralText(text: []const u8) bool {
    return text.len > 0 and (text[0] == '"' or text[0] == '\'');
}

/// The bytes a single-quoted string holds, one at a time: its body as
/// written, each `''` one `'`. The checker and emit both read a
/// single-quoted string through it.
pub const SingleQuoted = struct {
    body: []const u8,
    i: usize = 0,

    pub fn init(lit: []const u8) SingleQuoted {
        return .{ .body = lit[1 .. lit.len - 1] };
    }

    pub fn next(it: *SingleQuoted) ?u8 {
        if (it.i >= it.body.len) return null;
        const c = it.body[it.i];
        it.i += if (c == '\'' and it.i + 1 < it.body.len and it.body[it.i + 1] == '\'') 2 else 1;
        return c;
    }
};

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
    const ids = [_]TypeId{ store.unknown_id, store.void_id, store.bool_id, store.string_view_id, store.static_id, store.int_id, store.float_id, store.none_id, store.noreturn_id };
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
    try std.testing.expect(opt != try store.intern(a, .{ .fallible = .{ .ok = store.int_id } }));
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

test "TypeStore: a read view of a String is the ?String, and a read view of a view is that view" {
    const a = std.testing.allocator;
    var store = try TypeStore.init(a);
    defer store.deinit(a);
    // The one text view: the read view of a `String`, and of a `?String`, is the `?String`.
    try std.testing.expectEqual(store.string_view_id, try store.intern(a, .{ .read_view = store.string_id }));
    try std.testing.expectEqual(store.string_view_id, try store.intern(a, .{ .read_view = store.string_view_id }));
    // `?(?T)` is `?T`.
    const read_int = try store.intern(a, .{ .read_view = store.int_id });
    try std.testing.expectEqual(read_int, try store.intern(a, .{ .read_view = read_int }));
    // A view of an optional String stays a view of the optional.
    const opt_string = try store.intern(a, .{ .optional = store.string_id });
    const read_opt_string = try store.intern(a, .{ .read_view = opt_string });
    try std.testing.expect(read_opt_string != store.string_view_id);
    try std.testing.expect(read_opt_string != opt_string);
    // Static is its own plain type.
    try std.testing.expect(try store.intern(a, .{ .read_view = store.static_id }) != store.static_id);
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
        \\obj S
        \\  e: E
        \\  xs: [3]Int
        \\  o: Int?
        \\  t: String
        \\
        \\fun mk() -> S
        \\  S(e: E.a(n: 1), xs: [1, 2, 3], o: 7, t: String("p"))
        \\
        \\fun id(s: ?S) -> ?S from s
        \\  s
        \\
        \\fun idx(s: ?String) -> Int
        \\  s.len - 1
        \\
        \\fun get(v: !List[S]) -> !List[S] from v
        \\  v
        \\
        \\fun mkh(n: Int) -> *S
        \\  *S(e: E.a(n: n), xs: [n, n, n], o: n, t: String("p"))
        \\
        \\fun idh(s: ?*S) -> ?S from s
        \\  s
        \\
        \\sub main()
        \\  v: List[S] = List()
        \\  !v.push(mk())
        \\  match v[idx(?String("a"))].e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  match !get(!v)[idx(?String("a"))].e
        \\    .a(n) => n = 2
        \\    .b => print(0)
        \\  match id(?mk()).e
        \\    .a(n) => print(n)
        \\    .b => print(0)
        \\  for x in id(?mk()).xs
        \\    print(x)
        \\  for x in !v[idx(?String("a"))].xs
        \\    x = 0
        \\  if id(?mk()).o as n
        \\    print(n)
        \\  if !v[idx(?String("a"))].o as n
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
    const points = [_]bool{ true, true, false, false, false, true, false, false, true, false };
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
    try std.testing.expectEqual(r.ctx.types.static_id, r.ctx.symbols.items[a_use].ty);
    try std.testing.expectEqual(r.ctx.types.static_id, r.leafType("s", 3).?);
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
        \\obj P
        \\  n: Int
        \\
        \\  fun get(?@) -> Int
        \\    @n
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
    const self_sym = r.sym("@", 0).?;
    try std.testing.expectEqual(self_sym, r.sym("@n", 0).?);
    try std.testing.expectEqual(SymbolKind.param, r.ctx.symbols.items[self_sym].kind);
    const cap = r.sym("s", 1).?;
    try std.testing.expectEqual(SymbolKind.capture, r.ctx.symbols.items[cap].kind);
    try std.testing.expectEqual(cap, r.sym("s", 2).?);
    try std.testing.expect(cap != r.sym("s", 0).?);
    try std.testing.expectEqual(r.ctx.types.static_id, r.ctx.symbols.items[cap].ty);
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
        \\  v: List[Int] = List()
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
        \\obj P
        \\  n: Int
        \\
        \\  fun get(?@) -> Int
        \\    @n
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

test "a padded closure's hidden parameter spans its closure and reads as empty text" {
    const source =
        \\sub each(f: ?sub(Int, Int))
        \\  f(1, 2)
        \\
        \\sub main()
        \\  each(|a| print(a))
        \\
    ;
    var r: FactsRun = .{ .p = parser.Parser.init(std.testing.allocator, source), .tree = undefined, .ctx = undefined, .source = source };
    defer r.p.deinit();
    r.tree = try r.p.parseProgram();
    r.ctx = try check(std.testing.allocator, source, r.tree, .{ .parser = &r.p });
    defer r.ctx.deinit();
    try std.testing.expect(!r.ctx.hasErrors());
    const lambda = findNode(r.tree, .lambda).?;
    const params = ir.Lambda.params(lambda).items();
    try std.testing.expectEqual(@as(usize, 2), params.len);
    const hidden = params[1];
    try std.testing.expect(hidden.src.pos >= r.source.len);
    const closure = r.ctx.span(lambda);
    const at = r.ctx.span(hidden);
    try std.testing.expect(at.start >= closure.start and at.start <= closure.end);
    try std.testing.expectEqualStrings("|a| print(a)", diag.textOf(r.source, closure));
    try std.testing.expectEqualStrings("", diag.textOf(r.source, at));
    try std.testing.expectEqualStrings("", diag.textBetween(r.source, hidden.src.pos, hidden.src.pos + 1));
    try std.testing.expectEqualStrings("_", identAt(r.source, hidden).?);
    try r.ctx.errAt(hidden, "probe", .{});
    const d = r.ctx.diagnostics.items[r.ctx.diagnostics.items.len - 1];
    try std.testing.expect(d.pos >= closure.start and d.pos <= closure.end);
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
        \\obj Item
        \\  n: Int
        \\
        \\obj Holder
        \\  r: []Int
        \\
        \\fun at(v: ?[4]Item, k: !Int) -> ?Item
        \\  k += 1
        \\  ?v[0]
        \\
        \\fun first(a: ?List[Int], b: ?List[Int]) -> ?List[Int]
        \\  a
        \\
        \\fun pick(s: ?String, t: ?String, n: Int, u: ?Item) -> ?String
        \\  s
        \\
        \\sub fill(h: !Holder, x: []Int, k: Int, s: ?String) keeps x
        \\  h.r = x
        \\
        \\sub peek(h: !Holder, x: []Int, t: Holder)
        \\  print(h.r.len, x.len, t.r.len)
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
    // `fill` keeps the lent `x`, as it says; a number or a `?String` it
    // cannot store, and `h` it is lent only to write into.
    try std.testing.expectEqual(@as(ParamMask, 0b0010), o(&r, "fill").stores);
    try std.testing.expectEqual(@as(ParamMask, 0b1011), o(&r, "fill").lent);
    // `peek` names nothing: of its lent parameters it keeps none, and
    // `t`, taken by value, it may keep by its type.
    try std.testing.expectEqual(@as(ParamMask, 0b100), o(&r, "peek").stores);
    // A type parameter could be anything, but a value taken by value is
    // the callee's own.
    try std.testing.expectEqual(@as(ParamMask, 0b01), o(&r, "same").result);
}

test "origins: a view reached through a read view is that view's" {
    var r = try factsRun(
        \\obj Item
        \\  n: Int
        \\
        \\obj Cursor
        \\  items: ?List[Item]
        \\  i: Int
        \\
        \\obj Owner
        \\  items: ?List[Item]
        \\  scratch: List[Item]
        \\
        \\obj Cut
        \\  before: ?String
        \\
        \\obj Keeps
        \\  t: ?String
        \\
        \\obj Shared
        \\  item: *Item
        \\
        \\obj Boxed
        \\  b: ^Item
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
    const string = r.ctx.types.string_view_id;
    const reach = struct {
        fn of(run: *FactsRun, al: std.mem.Allocator, h: TypeId, v: TypeId) !ViewReach {
            return viewReach(&run.ctx, al, h, v);
        }
    }.of;
    const al = arena.allocator();
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Cursor"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Owner"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, item, view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, r.ctx.types.int_id, view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, string, view));
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Cut"), string));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, r.ctx.types.string_id, string));
    try std.testing.expectEqual(ViewReach.through_view, try reach(&r, al, ty(&r, "Keeps"), string));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Shared"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Boxed"), view));
    try std.testing.expectEqual(ViewReach.owned, try reach(&r, al, ty(&r, "Maybe"), view));
    try std.testing.expectEqual(ViewReach.none, try reach(&r, al, ty(&r, "Cut"), view));
}

test "facts: a checked call records what fills each parameter" {
    var r = try factsRun(
        \\obj Acc
        \\  n: Int
        \\
        \\  fun add(?@, k: Int, by: Int = 1) -> Int
        \\    @n + k * by
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
        \\obj U
        \\  n: Int
        \\
        \\fun read(u: ?U) -> Int
        \\  u.n
        \\
        \\sub show[k: Int]()
        \\  print(k)
        \\
        \\sub main()
        \\  y =! 2
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
        \\obj User
        \\  name: ?String
        \\  age: Int
        \\
        \\  fun greet(?@) -> ?String
        \\    @name
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
    // once per link of the chain. The chain nests deeper than
    // `max_value_depth`, reported once, at the first type past it.
    const n = 5000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    for (0..n) |i| try src.print(a, "obj S{d}\n  x: S{d}\n\n", .{ i, i + 1 });
    try src.print(a, "obj S{d}\n  x: Int\n\nfun same(a: ?S0, b: ?S0) -> Bool\n  a == b\n", .{n});
    var p = parser.Parser.init(a, src.items);
    defer p.deinit();
    var ctx = try check(a, src.items, try p.parseProgram(), .{});
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctx.diagnostics.items.len);
    try std.testing.expect(std.mem.find(u8, ctx.diagnostics.items[0].message, "`S4000` nests 1001 types deep by value") != null);
    const s0 = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "S0").? });
    try std.testing.expectEqual(@as(u32, n + 1), try valueDepth(&ctx, s0));
    const last = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "S4999").? });
    try std.testing.expectEqual(@as(?u128, 8), try minBytes(&ctx, last));
}

test "maskBytes: the runtime's own size" {
    const runtime = @import("runtime.zig");
    inline for (.{ 2, 4, 8, 16, 32, 64 }) |n| {
        try std.testing.expectEqual(@as(u64, @sizeOf(runtime.Mask(n))), maskBytes(n));
        try std.testing.expectEqual(n > max_bit_mask_lanes, @typeInfo(runtime.Mask(n)) == .@"struct");
    }
}

test "type facts: moves, copies, cloneable" {
    var r = try factsRun(
        \\obj P
        \\  x: Int
        \\
        \\obj V
        \\  p: ?P
        \\
        \\obj Wrap[T]
        \\  item: T
        \\
    );
    defer r.deinit();
    const ctx = &r.ctx;
    const ty = &ctx.types;
    const p = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "P").? });
    const v = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "V").? });
    const t = try ctx.intern(.{ .type_var = r.sym("T", 0).? });
    const list_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.list_sym_id, .args = &.{ty.int_id} } });
    const wrap_t = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.lookup(module_scope, "Wrap").?, .args = &.{t} } });
    const wrap_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.lookup(module_scope, "Wrap").?, .args = &.{ty.int_id} } });
    const read_p = try ctx.intern(.{ .read_view = p });
    const write_p = try ctx.intern(.{ .write_view = p });
    // A value that holds a write view: an optional one, `(!P)?`.
    const w = try ctx.intern(.{ .optional = write_p });
    const shared_p = try ctx.intern(.{ .shared = p });
    const weak_p = try ctx.intern(.{ .weak = p });
    const opt_shared = try ctx.intern(.{ .optional = shared_p });
    const opt_t = try ctx.intern(.{ .optional = t });
    const int_slice = try ctx.intern(.{ .slice = .{ .elem = ty.int_id } });
    const write_slice = try ctx.intern(.{ .write_view = int_slice });

    const Case = struct { ty: TypeId, moves: Answer, copies: Answer, clone: Clone };
    const cases = [_]Case{
        .{ .ty = ty.int_id, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = ty.string_view_id, .moves = .no, .copies = .yes, .clone = .text },
        .{ .ty = ty.static_id, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = p, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = read_p, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = write_p, .moves = .no, .copies = .no, .clone = .copy },
        .{ .ty = v, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = w, .moves = .no, .copies = .no, .clone = .no },
        .{ .ty = list_int, .moves = .yes, .copies = .no, .clone = .deep },
        .{ .ty = ty.string_id, .moves = .yes, .copies = .no, .clone = .text },
        .{ .ty = shared_p, .moves = .yes, .copies = .no, .clone = .bump },
        .{ .ty = weak_p, .moves = .yes, .copies = .no, .clone = .bump },
        .{ .ty = opt_shared, .moves = .yes, .copies = .no, .clone = .bump },
        .{ .ty = t, .moves = .depends, .copies = .depends, .clone = .depends },
        .{ .ty = opt_t, .moves = .depends, .copies = .depends, .clone = .depends },
        .{ .ty = wrap_t, .moves = .depends, .copies = .depends, .clone = .depends },
        .{ .ty = wrap_int, .moves = .no, .copies = .yes, .clone = .copy },
        .{ .ty = write_slice, .moves = .no, .copies = .no, .clone = .no },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        try std.testing.expectEqual(c.moves, moves(ctx, c.ty));
        try std.testing.expectEqual(c.copies, copies(ctx, c.ty));
        try std.testing.expectEqual(c.clone, cloneable(ctx, c.ty));
        try std.testing.expect(!isUnique(ctx, c.ty));
    }
    // A clone reads what a view reaches.
    try std.testing.expectEqual(Clone.bump, cloneable(ctx, try ctx.intern(.{ .read_view = shared_p })));
    try std.testing.expectEqual(Clone.deep, cloneable(ctx, try ctx.intern(.{ .read_view = list_int })));
    // A view of a value that copies hands over the value; a view of an
    // owner, of one holding a write view, or a `![]T` does not.
    try std.testing.expectEqual(@as(?TypeId, p), copiedThrough(ctx, read_p));
    try std.testing.expectEqual(@as(?TypeId, p), copiedThrough(ctx, write_p));
    try std.testing.expectEqual(@as(?TypeId, v), copiedThrough(ctx, try ctx.intern(.{ .read_view = v })));
    try std.testing.expectEqual(@as(?TypeId, null), copiedThrough(ctx, try ctx.intern(.{ .read_view = w })));
    try std.testing.expectEqual(@as(?TypeId, null), copiedThrough(ctx, try ctx.intern(.{ .read_view = list_int })));
    try std.testing.expectEqual(@as(?TypeId, null), copiedThrough(ctx, write_slice));
    try std.testing.expectEqual(@as(?TypeId, null), copiedThrough(ctx, p));
    // A view of a scalar or a plain enum reads as the value to an
    // operator.
    try std.testing.expect(readsAsValue(ctx, ty.int_id));
    try std.testing.expect(!readsAsValue(ctx, p));
    try std.testing.expect(lendByValue(ctx, ty.int_id));
    try std.testing.expect(!lendByValue(ctx, list_int));
}

test "heap holdings: a box prints as ^T, and a holding over a held value is stacked" {
    var r = try factsRun(
        \\obj P
        \\  x: Int
        \\
    );
    defer r.deinit();
    const ctx = &r.ctx;
    const ty = &ctx.types;
    const p = try ctx.intern(.{ .nominal = ctx.lookup(module_scope, "P").? });
    const box_p = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{p} } });
    const opt_p = try ctx.intern(.{ .optional = p });
    const box_opt = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{opt_p} } });
    const opt_box = try ctx.intern(.{ .optional = box_p });
    const read_box = try ctx.intern(.{ .read_view = box_p });
    const shared_p = try ctx.intern(.{ .shared = p });
    const weak_p = try ctx.intern(.{ .weak = p });
    const box_box = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{box_p} } });
    const spelled = struct {
        fn f(c: *SemContext, t: TypeId) ![]const u8 {
            return formatType(c, t);
        }
    }.f;
    try std.testing.expectEqualStrings("^P", try spelled(ctx, box_p));
    try std.testing.expectEqualStrings("^(P?)", try spelled(ctx, box_opt));
    try std.testing.expectEqualStrings("^P?", try spelled(ctx, opt_box));
    try std.testing.expectEqualStrings("?^P", try spelled(ctx, read_box));
    try std.testing.expectEqualStrings("^^P", try spelled(ctx, box_box));
    // A box of a read view is written `^?P`, and an optional one `(^?P)?`.
    const box_read = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{try ctx.intern(.{ .read_view = p })} } });
    try std.testing.expectEqualStrings("^?P", try spelled(ctx, box_read));
    try std.testing.expectEqualStrings("(^?P)?", try spelled(ctx, try ctx.intern(.{ .optional = box_read })));
    // A box holds a value held no other way on the heap.
    try std.testing.expect(!heapStacked(ctx, p));
    try std.testing.expect(!heapStacked(ctx, opt_p));
    try std.testing.expect(!heapStacked(ctx, ty.int_id));
    try std.testing.expect(heapStacked(ctx, box_p));
    try std.testing.expect(heapStacked(ctx, shared_p));
    try std.testing.expect(heapStacked(ctx, weak_p));
    // A stacked type is found inside the types made of it.
    try std.testing.expectEqual(@as(?TypeId, null), findHeapStacked(ctx, opt_box));
    try std.testing.expectEqual(@as(?TypeId, box_box), findHeapStacked(ctx, box_box));
    const slice = try ctx.intern(.{ .slice = .{ .elem = box_box } });
    try std.testing.expectEqual(@as(?TypeId, box_box), findHeapStacked(ctx, slice));
}

test "lend table: each row makes its view" {
    var r = try factsRun(
        \\obj P
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
    const box_string = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{ty.string_id} } });
    const fn_ty = try ctx.intern(.{ .function = .{ .params = &.{}, .returns = ty.int_id, .is_sub = false } });
    const owned = try ctx.intern(.{ .shared = fn_ty });
    const callable = try callableOfFn(ctx, fn_ty);
    const opt_string_view = try ctx.intern(.{ .optional = ty.string_view_id });
    const opt_string = try ctx.intern(.{ .optional = ty.string_id });
    const box_box_p = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{box_p} } });
    const box_arr = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.box_sym_id, .args = &.{arr} } });
    const list_int = try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.list_sym_id, .args = &.{ty.int_id} } });
    const shared_p = try ctx.intern(.{ .shared = p });
    const shared_string = try ctx.intern(.{ .shared = ty.string_id });
    const opt_p = try ctx.intern(.{ .optional = p });
    const opt_read_p = try ctx.intern(.{ .optional = try read(ctx, p) });
    const opt_list = try ctx.intern(.{ .optional = list_int });
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
        // A String: a `?String`, also where a `(?String)?` is expected; never to
        // write.
        .{ .from = ty.string_id, .kind = .read, .view = ty.string_view_id, .rows = &.{.text} },
        .{ .from = ty.string_id, .kind = .read, .view = opt_string_view, .rows = &.{ .lift, .text } },
        .{ .from = opt_string, .kind = .read, .view = opt_string_view, .rows = &.{ .optional, .text } },
        .{ .from = ty.string_id, .kind = .write, .view = ty.string_view_id, .rows = null },
        // A box: the views of its value.
        .{ .from = box_p, .kind = .read, .view = try read(ctx, p), .rows = &.{.unbox} },
        .{ .from = box_p, .kind = .write, .view = try write(ctx, p), .rows = &.{.unbox} },
        .{ .from = box_p, .kind = .read, .view = try write(ctx, p), .rows = null },
        .{ .from = box_string, .kind = .read, .view = ty.string_view_id, .rows = &.{ .unbox, .text } },
        // Boxes compose.
        .{ .from = box_box_p, .kind = .read, .view = try read(ctx, p), .rows = &.{ .unbox, .unbox } },
        .{ .from = box_arr, .kind = .read, .view = slice, .rows = &.{ .unbox, .elems } },
        // A List lends its elements, as an array does.
        .{ .from = list_int, .kind = .read, .view = slice, .rows = &.{.elems} },
        .{ .from = list_int, .kind = .write, .view = try write(ctx, slice), .rows = &.{.elems} },
        // A `*T` lends the read views of its `T`, never a write view.
        .{ .from = shared_p, .kind = .read, .view = try read(ctx, p), .rows = &.{.handle} },
        .{ .from = shared_string, .kind = .read, .view = ty.string_view_id, .rows = &.{ .handle, .text } },
        .{ .from = shared_p, .kind = .write, .view = try write(ctx, p), .rows = null },
        // An `X?` lends a `View?`; `?o` of an `S?` is a `?(S?)`.
        .{ .from = opt_p, .kind = .read, .view = opt_read_p, .rows = &.{.optional} },
        .{ .from = opt_p, .kind = .read, .view = try read(ctx, opt_p), .rows = &.{} },
        .{ .from = opt_list, .kind = .read, .view = opt_slice, .rows = &.{ .optional, .elems } },
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
        \\obj U unique
        \\  n: Int
        \\
        \\obj Ring[T] unique
        \\  item: T
        \\
        \\obj Wrap[T]
        \\  item: T
        \\
        \\obj Holder
        \\  u: U
        \\
        \\obj Far
        \\  h: Holder
        \\
        \\obj Ptr
        \\  u: *U
        \\
        \\obj Counter
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
        try ctx.intern(.{ .parameterized_nominal = .{ .sym = ctx.list_sym_id, .args = &.{u} } }),
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
        try std.testing.expectEqual(Answer.no, copies(ctx, t));
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
        const text = rig.leafText(self.r.source, leaf.src);
        if (text.len == 0) return;
        if (isBuiltinCallName(text) or std.mem.eql(u8, text, "_")) return;
        if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_' and !std.mem.eql(u8, text, "@")) return;
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "none")) return;
        if (self.r.ctx.symbolOf(leaf) == null) {
            std.debug.print("no symbol for `{s}` at {d}\n", .{ text, leaf.src.pos });
            self.missing += 1;
        }
    }

    fn expectType(self: *Coverage, node: Sexp) void {
        if (self.r.ctx.typeOf(node) == null) {
            std.debug.print("no type for node at {d} ({s})\n", .{ rig.leafSpan(self.r.source, node).start, if (node.kind()) |h| @tagName(h) else "leaf" });
            self.missing += 1;
        }
    }

    /// `e` is in expression position.
    fn expr(self: *Coverage, e: Sexp) void {
        switch (e) {
            .src => {
                self.expectName(e);
                if (!isBuiltinCallName(rig.leafText(self.r.source, e.src))) self.expectType(e);
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
                        if (pat.isKind(.variant_pattern)) for (ir.VariantPattern.bindings(pat)) |b| self.expectName(bindingName(b));
                        if (ir.Arm.guard(arm) != .nil) self.expr(ir.Arm.guard(arm));
                        self.expr(ir.Arm.body(arm));
                    }
                },
                .lambda => {
                    for (captureList(ir.Lambda.captures(e))) |cap| {
                        self.expectName(captureNameNode(cap).?);
                        if (captureValue(cap) != .nil) self.expr(captureValue(cap));
                    }
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
                .enum_lit, .symbol => self.expectType(e),
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
        \\obj Account
        \\  owner: ?String
        \\  balance: Int
        \\
        \\  fun doubled(?@) -> Int
        \\    @balance * 2
        \\
        \\  sub deposit(!@, n: Int)
        \\    @balance += n
        \\
        \\enum Shape
        \\  circle(radius: Int)
        \\  dot
        \\
        \\obj Wrap[T]
        \\  value: T
        \\
        \\  fun get(?@) -> T
        \\    @value
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
        \\  <shared
        \\  print(other.balance)
        \\  total = 0
        \\  v: List[Int] = List()
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
        \\    !c.set(c.get() + 1)
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
        \\  w: List[Int] = List()
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
        \\obj P
        \\  x: Int
        \\  t: String
        \\
        \\enum E
        \\  a(n: Int)
        \\  b
        \\
        \\fun mk() -> P
        \\  P(x: 1, t: String("a"))
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
        \\  print(String("y") if c else String("z"))
        \\  print(mk().t if c else String("w"))
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

test "a jump in a nested `for` source or `else` names the loop around it" {
    const source =
        \\sub main()
        \\  x = for i in 0..3
        \\    for j in 0..(some(i) ?? break 5)
        \\      continue
        \\    else
        \\      break 6
        \\  else
        \\    0
        \\  $a: while true
        \\    $a: for k in 0..(n ?? break)
        \\      break $a
        \\    defer
        \\      break
        \\    f = ||
        \\      break
        \\
    ;
    var p = parser.Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    var n: usize = 0;
    const outer = nthNode(tree, .@"for", &n).?;
    n = 1;
    const inner = nthNode(tree, .@"for", &n).?;
    const Jumps = struct {
        list: [8]Sexp = undefined,
        len: usize = 0,
        pub fn jump(j: *@This(), e: Sexp) error{}!void {
            j.list[j.len] = e;
            j.len += 1;
        }
    };
    // The outer loop: the `break 5` in the source, the `break 6` in the
    // inner loop's `else`.
    var jumps: Jumps = .{};
    try eachJumpTo(source, outer, "", &jumps);
    try std.testing.expectEqual(2, jumps.len);
    try std.testing.expect(hasValueBreaks(source, outer));
    // The inner loop: only the `continue` in its body.
    jumps = .{};
    try eachJumpTo(source, inner, "", &jumps);
    try std.testing.expectEqual(1, jumps.len);
    try std.testing.expect(jumps.list[0].isKind(.@"continue"));
    try std.testing.expect(!hasValueBreaks(source, inner));
    // `$a: while`: the `break` in the source of the inner `$a: for`,
    // not the one in its body, which names it; nothing in a `defer` or a
    // closure.
    n = 0;
    const labeled = nthNode(tree, .@"while", &n).?;
    jumps = .{};
    try eachJumpTo(source, labeled, "a", &jumps);
    try std.testing.expectEqual(1, jumps.len);
    n = 1;
    const fallback = nthNode(tree, .@"??", &n).?;
    try std.testing.expect(jumps.list[0].items().ptr == ir.get(fallback, .right).items().ptr);
}
