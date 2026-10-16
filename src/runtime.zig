//! The Rig runtime. `bin/rig` writes this file verbatim next to every
//! emitted program as `rig/runtime.zig`; emitted code refers to it as `rig`.
//!
//! Ownership conventions shared with the emitter:
//!
//! - `*T` is `*RcBox(T)`: single-threaded reference counting with weak
//!   handles (`WeakHandle(T)`). `cloneStrong` / `dropStrong` /
//!   `weakRef` / `cloneWeak` / `dropWeak` / `upgrade` are the only
//!   refcount operations; the emitter spells every one explicitly.
//! - `dropElement` is the single place that knows how to release a value
//!   of any type: a strong handle drops a count, a type that declares
//!   `__rig_drop(self: *Self)` runs it, structs, tagged unions, arrays,
//!   and optionals drop their parts, and everything else is plain data.
//! - A moved-from binding's scope-exit drop is disarmed by `take`.
//! - Allocation failure panics. Every allocation goes through
//!   `defaultAllocator()`, which is leak-checked in Debug builds.

const std = @import("std");

/// Rig's `Int`. Sizes and indices cross the Rig boundary as `Int`.
const Int = i64;

// -----------------------------------------------------------------------------
// Optionals
// -----------------------------------------------------------------------------

// Rig's `T?` is `Opt(T)`: Zig's `?T`, or a struct that declares
// `__rig_optional`, its payload type, and holds the payload its own way.
// Every operation on a `T?` whose representation may differ from `?T` goes
// through `some`, `somePtr`, and `pack`, which are the identity on a `?T`:
// Zig rejects `orelse`, `null`, and a payload where a struct optional
// goes, so an operation that skips them fails to compile. Under
// `RIG_STRICT_OPTIONALS`, every object declares `__rig_strict_optional`,
// and its optional is a `Strict` wrapper, so the whole suite checks that
// emit and this file route every such operation.

/// The Zig type of Rig's `T?`.
pub fn Opt(comptime T: type) type {
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "__rig_strict_optional")) return Strict(T);
    // A type that names its none (a compact optional) gets its own
    // struct here.
    return ?T;
}

/// `T?` held beside a flag, for an object under `RIG_STRICT_OPTIONALS`:
/// the same values as `?T`, in a type Zig never lifts a `T` into.
fn Strict(comptime T: type) type {
    return struct {
        has: bool,
        payload: T,

        pub const __rig_optional = T;

        pub inline fn unwrap(o: @This()) ?T {
            return if (o.has) o.payload else null;
        }

        pub inline fn unwrapPtr(p: anytype) ?@TypeOf(&p.payload) {
            return if (p.has) &p.payload else null;
        }

        pub inline fn wrap(x: ?T) @This() {
            return if (x) |v| .{ .has = true, .payload = v } else .{ .has = false, .payload = undefined };
        }
    };
}

/// Whether `O` is a Rig optional held as a struct (`Opt`).
fn isOptStruct(comptime O: type) bool {
    return @typeInfo(O) == .@"struct" and @hasDecl(O, "__rig_optional");
}

/// Whether `O` is a Rig optional: Zig's `?T`, or a struct one.
fn isOptional(comptime O: type) bool {
    return @typeInfo(O) == .optional or isOptStruct(O);
}

/// The `T` of an optional type `O`.
pub fn Payload(comptime O: type) type {
    return if (comptime isOptStruct(O)) O.__rig_optional else @typeInfo(O).optional.child;
}

/// `x`, a `T?`, as Zig's `?T`: what `if x as v`, `while x as v`, `??`,
/// `?`, and `== none` test.
pub inline fn some(x: anytype) ?Payload(@TypeOf(x)) {
    if (comptime isOptStruct(@TypeOf(x))) return x.unwrap();
    return x;
}

/// The address of the value inside the optional `p` points to, or null:
/// what a `|*v|` capture binds.
pub inline fn somePtr(p: anytype) ?PayloadPtr(@TypeOf(p)) {
    const O = @typeInfo(@TypeOf(p)).pointer.child;
    if (comptime isOptStruct(O)) return O.unwrapPtr(p);
    return if (p.*) |*v| v else null;
}

fn PayloadPtr(comptime P: type) type {
    const info = @typeInfo(P).pointer;
    return if (info.attrs.@"const") *const Payload(info.child) else *Payload(info.child);
}

/// Zig's `?T` as the `T?` of type `O`, the inverse of `some`: what a
/// `T`, `none`, or an optional-valued `??` is where a `T?` goes.
pub inline fn pack(comptime O: type, x: ?Payload(O)) O {
    if (comptime isOptStruct(O)) return O.wrap(x);
    return x;
}

// -----------------------------------------------------------------------------
// Dropping values
// -----------------------------------------------------------------------------

/// True when `T` is `*RcBox(U)` for some `U`.
fn isStrongHandle(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and
            @typeInfo(p.child) == .@"struct" and
            @hasDecl(p.child, "__rig_rcbox"),
        else => false,
    };
}

/// True when dropping a `T` releases anything. A type owns resources
/// when it declares `__rig_drop`, is a strong handle, or (for structs,
/// tagged unions, arrays, and optionals) contains something that does.
/// The mirror of sema's `typeHasDropGlue` for a Zig type: a unique type
/// that needs no cleanup drops nothing.
fn needsDrop(comptime T: type) bool {
    if (comptime isOptStruct(T)) return needsDrop(Payload(T));
    return switch (@typeInfo(T)) {
        .pointer => isStrongHandle(T),
        .optional => |o| needsDrop(o.child),
        .error_union => |e| needsDrop(e.payload),
        .array => |a| needsDrop(a.child),
        .@"struct" => |s| blk: {
            if (@hasDecl(T, "__rig_drop")) break :blk true;
            inline for (s.field_types) |F| if (needsDrop(F)) break :blk true;
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (@hasDecl(T, "__rig_drop")) break :blk true;
            if (u.tag_type == null) break :blk false;
            inline for (u.field_types) |F| if (needsDrop(F)) break :blk true;
            break :blk false;
        },
        .@"enum", .@"opaque" => @hasDecl(T, "__rig_drop"),
        else => false,
    };
}

/// How a read view `?T` is held: a copy of a scalar or a view (a
/// number, `Bool`, a vector, a plain enum, an error, a slice or
/// `?String`, a function, or an optional of one), a pointer to anything else, and
/// for a `String` its bytes, the one text view, `?String`. The
/// emitter decides this itself for a known `T` (`sema.lendByValue`), by
/// the same rule, and uses this in a generic type, where `T` depends on
/// the type arguments. A type argument never holds a Cell (a Cell lives
/// only behind a shared handle), so the pointer is read-only.
pub fn ReadView(comptime T: type) type {
    if (T == String) return []const u8;
    return if (needsDrop(T) or !copiedByReadView(T)) *const T else T;
}

fn copiedByReadView(comptime T: type) bool {
    if (comptime isOptStruct(T)) return copiedByReadView(Payload(T));
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .comptime_int, .comptime_float, .error_set, .@"enum", .@"fn", .pointer, .vector => true,
        .optional => |o| copiedByReadView(o.child),
        .@"struct" => isWideMask(T),
        else => false,
    };
}

/// A read view of what `ptr` points to.
pub fn lend(ptr: anytype) ReadView(@TypeOf(ptr.*)) {
    if (comptime @TypeOf(ptr.*) == String) return ptr.bytes();
    return if (comptime ReadView(@TypeOf(ptr.*)) == @TypeOf(ptr.*)) ptr.* else ptr;
}

/// What a read view `?T` reaches: the `T`, and for a `String` its bytes,
/// which is all a read view of one holds.
fn Reached(comptime T: type) type {
    return if (T == String) []const u8 else T;
}

/// The `T` a read view `?T` reaches.
pub fn viewed(comptime T: type, view: ReadView(T)) Reached(T) {
    if (comptime T == String) return view;
    return if (comptime ReadView(T) == T) view else view.*;
}

/// Fill hidden storage whose scope has ended with `0xAA` under the
/// sanitizer, so a view that outlives it reads garbage, not a stale
/// value; nothing otherwise.
pub fn poison(ptr: anytype) void {
    if (comptime !sanitize) return;
    @memset(std.mem.asBytes(ptr), 0xAA);
}

/// The `T` a read view `?T`, held where `view` points, reaches:
/// the value itself when the view is a pointer, else the view's copy.
pub fn viewedPtr(comptime T: type, view: *const ReadView(T)) *const Reached(T) {
    if (comptime T == String) return view;
    return if (comptime ReadView(T) == T) view else view.*;
}

/// `held`, an optional or a fallible view of a `T` that copies, with the
/// `T` the view holds (a view lent by value) or points at copied out in
/// place of the view: what `a ?? b` and `a catch b` give where their
/// fallback is a `T`, not a view.
pub fn copiedOut(comptime T: type, held: anytype) CopiedOut(T, @TypeOf(held)) {
    return switch (@typeInfo(@TypeOf(held))) {
        .optional => if (held) |v| copiedView(T, v) else null,
        .error_union => if (held) |v| copiedView(T, v) else |err| err,
        else => @compileError("rig.copiedOut takes an optional or a fallible view"),
    };
}

fn CopiedOut(comptime T: type, comptime Held: type) type {
    return switch (@typeInfo(Held)) {
        .optional => ?T,
        .error_union => |e| e.error_set!T,
        else => T,
    };
}

fn copiedView(comptime T: type, view: anytype) T {
    return if (comptime @TypeOf(view) == T) view else view.*;
}

/// Release whatever `value` owns: a strong handle drops its count, a
/// type with `__rig_drop` runs it, and aggregates drop their parts.
/// Plain data is a no-op, decided at compile time.
fn dropElement(comptime T: type, value: *T) void {
    if (comptime !needsDrop(T)) return;
    if (comptime isOptStruct(T)) {
        if (somePtr(value)) |inner| dropElement(Payload(T), inner);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => value.*.dropStrong(),
        .optional => if (value.*) |*inner| dropElement(@TypeOf(inner.*), inner),
        .error_union => if (value.*) |*inner| dropElement(@TypeOf(inner.*), inner) else |_| {},
        .array => {
            var i: usize = value.len;
            while (i > 0) {
                i -= 1;
                dropElement(@TypeOf(value[i]), &value[i]);
            }
        },
        .@"struct" => if (@hasDecl(T, "__rig_drop")) value.__rig_drop() else dropFields(value),
        .@"union" => if (@hasDecl(T, "__rig_drop")) {
            value.__rig_drop();
        } else switch (value.*) {
            inline else => |*payload| dropElement(@TypeOf(payload.*), payload),
        },
        else => value.__rig_drop(),
    }
}

/// `dropElement` with the type inferred from the pointer.
pub fn drop(ptr: anytype) void {
    dropElement(@TypeOf(ptr.*), ptr);
}

/// Drop every field of the struct `ptr` points to, last field first.
/// A type's own `__rig_drop` calls this after its user-written body.
pub fn dropFields(ptr: anytype) void {
    const s = @typeInfo(@TypeOf(ptr.*)).@"struct";
    comptime var i = s.field_names.len;
    inline while (i > 0) {
        i -= 1;
        dropElement(s.field_types[i], &@field(ptr, s.field_names[i]));
    }
}

/// `replace(!place, value)`: the old value, with `value` in its place.
pub fn replace(place: anytype, value: @TypeOf(place.*)) @TypeOf(place.*) {
    const old = place.*;
    place.* = value;
    return old;
}

/// `swap(!a, !b)`.
pub fn swapPlaces(a: anytype, b: @TypeOf(a)) void {
    std.mem.swap(@TypeOf(a.*), a, b);
}

/// `<p.f` of an optional: the value, with `none` left in its place.
pub fn takeOut(place: anytype) @TypeOf(place.*) {
    const value = place.*;
    place.* = pack(@TypeOf(place.*), null);
    return value;
}

/// Keep `value`, an owning temporary, in `slot` until its statement
/// ends and drops it.
pub fn keep(slot: anytype, live: *bool, value: @TypeOf(slot.*)) @TypeOf(slot) {
    slot.* = value;
    live.* = true;
    return slot;
}

/// The address of an absent optional of type `O`: a `none` leaf of a
/// value whose payload a branch captures by address (`o if k else none`
/// in `(o if k else none)?`), beside leaves reached through mutable
/// pointers. It is never written: a branch captures the payload of a
/// value that has one, and this has none.
pub fn noneAt(comptime O: type) *O {
    const S = struct {
        var none: O = pack(O, null);
    };
    return &S.none;
}

/// Yield `value` after clearing its binding's alive flag: the value has
/// been moved out, so the binding's scope-exit drop must not run.
pub fn take(alive: *bool, value: anytype) @TypeOf(value) {
    alive.* = false;
    return value;
}

/// The compile-time evaluation budget every emitted function that is not
/// inline sets first (`@setEvalBranchQuota`). Zig charges each inline
/// call, and each pass of a compile-time loop in an inlined body, to the
/// budget of the function the code lands in, 1000 by default, and fails
/// the build when it runs out. No Rig program evaluates anything at
/// compile time that it could not finish, so the budget is never what
/// stops it.
pub const eval_quota = std.math.maxInt(u32);

/// `value`, as a run-time value: arithmetic on a compile-time constant
/// read through this is checked when it runs, as Rig specifies, rather
/// than folded by Zig at compile time.
pub fn rt(value: anytype) @TypeOf(value) {
    return value;
}

/// Allocate one `T` with the default allocator.
pub fn create(comptime T: type) *T {
    return defaultAllocator().create(T) catch oom();
}

// -----------------------------------------------------------------------------
// Equality and ordering
// -----------------------------------------------------------------------------

/// `a == b` for any equatable value, decided at compile time: numbers,
/// Bools, enum values, and errors by `==` (floats as IEEE numbers, so
/// NaN equals nothing); `?String`s and slices by length and elements;
/// arrays element by element; structs field by field; tagged unions by
/// tag, then payload; optionals both null or both holding equal values.
/// A value beside an optional compares as the optional's value; other
/// operands take their peer type, so a string literal is a `?String`.
pub fn eql(a: anytype, b: anytype) bool {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    // Optionals compare level by level. Where both sides are optional,
    // `none` is checked on each before either is unwrapped, so a `none`
    // held inside an outer `some` differs from the outer `none`. A side
    // with more optional levels than the other is unwrapped alone (the
    // other side counts as `some` at that level), and `none` equals only
    // `none`: a `String?` beside a `?String` compares the text.
    if (comptime A == @TypeOf(null) or B == @TypeOf(null)) return nullish(a) and nullish(b);
    // A view held as a pointer compares as the value it reaches.
    if (comptime isValuePointer(A)) return eql(a.*, b);
    if (comptime isValuePointer(B)) return eql(a, b.*);
    const dA = comptime optDepth(A);
    const dB = comptime optDepth(B);
    if (comptime dA > dB) {
        const x = some(a) orelse return false;
        return eql(x, b);
    }
    if (comptime dB > dA) {
        const y = some(b) orelse return false;
        return eql(a, y);
    }
    if (comptime dA > 0) {
        const x = some(a) orelse return some(b) == null;
        const y = some(b) orelse return false;
        return eql(x, y);
    }
    // A String compares with a String or a `?String` by its bytes.
    if (comptime isString(A) or isString(B)) return std.mem.eql(u8, stringBytes(a), stringBytes(b));
    // The peer type of an optional error and an error is an error union.
    const T = if (@typeInfo(A) == .optional) A else if (@typeInfo(B) == .optional) B else @TypeOf(a, b);
    return eqlAs(T, a, b);
}

/// A pointer to one value that is no text: a read view of a struct,
/// enum, or array held by address. (A shared handle has no `==`.)
fn isValuePointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and !isString(T) and !isStringView(T) and @typeInfo(p.child) != .@"fn",
        else => false,
    };
}

/// How many optional levels `T` has.
fn optDepth(comptime T: type) comptime_int {
    if (comptime isOptStruct(T)) return 1 + optDepth(Payload(T));
    return switch (@typeInfo(T)) {
        .optional => |o| 1 + optDepth(o.child),
        else => 0,
    };
}

/// Whether `x` is `none`: the literal, or an optional holding nothing.
fn nullish(x: anytype) bool {
    if (comptime isOptStruct(@TypeOf(x))) return some(x) == null;
    return switch (@typeInfo(@TypeOf(x))) {
        .null => true,
        .optional => x == null,
        else => false,
    };
}

/// A `String`, or a pointer to one (a viewed `String`), or a box or shared
/// handle holding one.
fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "__rig_string") or ((@hasDecl(T, "__rig_box") or @hasDecl(T, "__rig_rcbox")) and isString(@TypeOf(@as(T, undefined).value))),
        .pointer => |p| p.size == .one and isString(p.child),
        else => false,
    };
}

/// The bytes of a `String`, a viewed, boxed, or shared `String`, or a `?String`.
fn stringBytes(x: anytype) []const u8 {
    const X = @TypeOf(x);
    if (comptime !isString(X)) return x;
    if (comptime @typeInfo(X) == .pointer) return stringBytes(x.*);
    if (comptime @hasDecl(X, "__rig_box")) return stringBytes(x.value.*);
    if (comptime @hasDecl(X, "__rig_rcbox")) return stringBytes(x.value);
    return x.list.items;
}

fn eqlAs(comptime T: type, a: T, b: T) bool {
    if (comptime isOptStruct(T)) {
        const x = some(a) orelse return some(b) == null;
        const y = some(b) orelse return false;
        return eqlAs(Payload(T), x, y);
    }
    switch (@typeInfo(T)) {
        .optional => |o| {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return eqlAs(o.child, x, y);
        },
        .pointer => |p| {
            if (comptime isStringView(T)) return std.mem.eql(u8, a, b);
            if (p.size != .slice) @compileError("rig.eql: no `==` on " ++ @typeName(T));
            if (comptime isScalar(p.child)) return std.mem.eql(p.child, a, b);
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!eqlAs(p.child, x, y)) return false;
            return true;
        },
        .array => |arr| {
            for (a, b) |x, y| if (!eqlAs(arr.child, x, y)) return false;
            return true;
        },
        .@"struct" => |s| {
            if (@hasDecl(T, "__rig_string")) return std.mem.eql(u8, a.list.items, b.list.items);
            inline for (s.field_names, s.field_types) |name, F| if (!eqlAs(F, @field(a, name), @field(b, name))) return false;
            return true;
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("rig.eql: no `==` on " ++ @typeName(T));
            if (@as(Tag, a) != @as(Tag, b)) return false;
            return switch (a) {
                inline else => |x, tag| eqlAs(@TypeOf(x), x, @field(b, @tagName(tag))),
            };
        },
        .void => return true,
        else => return a == b,
    }
}

/// `x.hash()`: a `U64` of any value `==` compares but a float, the same
/// for values `rig.eql` calls equal, with a fixed seed. Text hashes its
/// bytes (Wyhash) whatever its type; an integer hashes its value,
/// whatever its width or signedness, by one multiply; an optional holding
/// a value hashes as that value; a view as what it views; arrays,
/// slices, structs, and tagged unions combine their parts in order.
pub fn hash(x: anytype) u64 {
    return hashAs(@TypeOf(x), x);
}

/// `hash` of a value of type `T`.
pub fn hashAs(comptime T: type, x: T) u64 {
    if (comptime isString(T)) return hashBytes(stringBytes(x));
    if (comptime isOptStruct(T)) return if (some(x)) |v| hashAs(Payload(T), v) else hash_none;
    switch (@typeInfo(T)) {
        .optional => |o| return if (x) |v| hashAs(o.child, v) else hash_none,
        .null => return hash_none,
        .pointer => |p| {
            if (comptime isStringView(T)) return hashBytes(x);
            if (p.size == .one) return hashAs(p.child, x.*);
            if (p.size != .slice) @compileError("rig.hash: no `.hash()` of " ++ @typeName(T));
            var h: u64 = hashInt(x.len);
            for (x) |e| h = hashMix(h, hashAs(p.child, e));
            return h;
        },
        .array => |arr| {
            var h: u64 = hashInt(arr.len);
            for (x) |e| h = hashMix(h, hashAs(arr.child, e));
            return h;
        },
        .@"struct" => |st| {
            var h: u64 = hash_seed;
            inline for (st.field_names, st.field_types) |name, F| h = hashMix(h, hashAs(F, @field(x, name)));
            return h;
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("rig.hash: no `.hash()` of " ++ @typeName(T));
            return switch (x) {
                inline else => |v, tag| hashMix(hashInt(@intFromEnum(@as(Tag, tag))), hashAs(@TypeOf(v), v)),
            };
        },
        .@"enum" => return hashInt(@intFromEnum(x)),
        .error_set => return hashInt(@intFromError(x)),
        .bool => return hashInt(@intFromBool(x)),
        .int, .comptime_int => return hashInt(x),
        .void => return hash_seed,
        else => @compileError("rig.hash: no `.hash()` of " ++ @typeName(T)),
    }
}

const hash_seed: u64 = 0x2d358dccaa6c78a5;
const hash_none: u64 = 0x8bb84b93962eacc9;
const hash_mul: u64 = 0x4b33a62ed433d4a3;

/// Wyhash of `bytes`, seed 0, as Zig's `StringHashMap` hashes text.
fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// An integer by its value, whatever its width or signedness: a value
/// from the least `i64` to the greatest `u64` hashes as one 64-bit word
/// (a negative one sign-extended, so `-1` is the same in every width);
/// a wider one folds its high half in.
fn hashInt(x: anytype) u64 {
    const X = @TypeOf(x);
    if (X == comptime_int) return hashInt(@as(if (x < 0) i128 else u128, x));
    const info = @typeInfo(X).int;
    if (info.bits <= 64) {
        const w: u64 = if (info.signedness == .signed) @bitCast(@as(i64, x)) else x;
        return hashWord(w);
    }
    const v: if (info.signedness == .signed) i128 else u128 = x;
    if (v >= 0 and v <= std.math.maxInt(u64)) return hashWord(@intCast(v));
    if (v < 0 and v >= std.math.minInt(i64)) return hashWord(@bitCast(@as(i64, @intCast(v))));
    const bits: u128 = @bitCast(v);
    return hashMix(hashWord(@truncate(bits)), hashWord(@truncate(bits >> 64)));
}

/// One 64-bit word, mixed by a full 64x64 multiply folded to 64 bits,
/// so every input bit reaches the low bits a table indexes by.
inline fn hashWord(w: u64) u64 {
    const p = @as(u128, w ^ hash_seed) * hash_mul;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}

/// The hash of a part combined into the hash so far.
inline fn hashMix(h: u64, part: u64) u64 {
    const p = @as(u128, h ^ part) * hash_mul;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}

/// `x == .tag` for a tagged union, or an optional of one: whether `x`
/// holds that variant, whatever its payload.
pub fn isVariant(x: anytype, comptime tag: @EnumLiteral()) bool {
    if (comptime isOptional(@TypeOf(x))) {
        const v = some(x) orelse return false;
        return isVariant(v, tag);
    }
    return std.meta.activeTag(x) == tag;
}

/// `isVariant` for a temporary that owns a resource: the temporary is
/// dropped.
pub fn isVariantDiscard(x: anytype, comptime tag: @EnumLiteral()) bool {
    defer discard(x);
    return isVariant(x, tag);
}

/// Compared by `std.mem.eql`. Floats are not: it finds two slices of
/// the same elements equal without comparing them, and NaN equals
/// nothing.
fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .error_set => true,
        else => false,
    };
}

/// `a op b` for an ordering operator in a generic body or on a plain
/// enum: numbers compare as numbers, a plain enum's values by their
/// variants' values, and `?String`s by their bytes, where the first byte
/// that differs decides and a prefix sorts first.
pub fn compare(a: anytype, comptime op: std.math.CompareOperator, b: anytype) bool {
    const T = @TypeOf(a, b);
    if (comptime isStringView(T)) return std.mem.order(u8, a, b).compare(op);
    if (@typeInfo(T) == .@"enum") return std.math.compare(@intFromEnum(@as(T, a)), op, @intFromEnum(@as(T, b)));
    return std.math.compare(a, op, b);
}

// -----------------------------------------------------------------------------
// Shared and weak handles
// -----------------------------------------------------------------------------

/// Reference-counted box behind `*T`. `strong` counts owning handles;
/// `weak` counts weak handles plus one on behalf of all strong handles,
/// so the box outlives its value while weak handles remain.
pub fn RcBox(comptime T: type) type {
    return struct {
        strong: usize,
        weak: usize,
        value: T,

        /// Marks the type for `isStrongHandle`.
        pub const __rig_rcbox = {};

        const Self = @This();

        pub fn cloneStrong(self: *Self) *Self {
            std.debug.assert(self.strong > 0);
            self.strong += 1;
            return self;
        }

        pub fn weakRef(self: *Self) WeakHandle(T) {
            std.debug.assert(self.strong > 0);
            self.weak += 1;
            return .{ .ptr = self };
        }

        /// Release one strong handle. The last one drops the value (with
        /// `strong == 0`, so an `upgrade` from inside that drop fails)
        /// and then the strong side's share of the weak count. Deep
        /// chains of boxes are released through `drop_queue` rather than
        /// by unbounded recursion.
        pub fn dropStrong(self: *Self) void {
            std.debug.assert(self.strong > 0);
            self.strong -= 1;
            if (self.strong > 0) return;
            if (comptime !needsDrop(T)) return self.releaseValue();
            if (drop_depth >= max_drop_depth) {
                drop_queue.append(std.heap.smp_allocator, .{ .box = self, .release = releaseErased }) catch oom();
                return;
            }
            drop_depth += 1;
            self.releaseValue();
            drop_depth -= 1;
            if (drop_depth == 0) drainDropQueue();
        }

        /// Drop the value, then give up the strong side's weak count.
        fn releaseValue(self: *Self) void {
            dropElement(T, &self.value);
            self.weak -= 1;
            if (self.weak == 0) defaultAllocator().destroy(self);
        }

        fn releaseErased(box: *anyopaque) void {
            releaseValue(@ptrCast(@alignCast(box)));
        }
    };
}

// Releasing a box can release the boxes its value holds, recursively: a
// 200k-node `*Node` list nests 200k drops. Past `max_drop_depth` nested
// releases, a box whose last strong handle goes is queued instead, and the
// outermost release drains the queue. The queued boxes are released in
// the order a recursive release would have reached them (depth first,
// siblings in the order they were queued), only later: after the
// releases already in progress finish. A queued box already has
// `strong == 0`, so `upgrade` fails on it.

const max_drop_depth = 256;
var drop_depth: u32 = 0;
const PendingDrop = struct { box: *anyopaque, release: *const fn (*anyopaque) void };
var drop_queue: std.ArrayList(PendingDrop) = .empty;

fn drainDropQueue() void {
    drop_depth += 1;
    // The queue is a stack. The boxes a release queued go on top, reversed,
    // so the first one queued is released next and before anything
    // queued earlier.
    var fresh: usize = 0;
    while (true) {
        std.mem.reverse(PendingDrop, drop_queue.items[fresh..]);
        const pending = drop_queue.pop() orelse break;
        fresh = drop_queue.items.len;
        pending.release(pending.box);
    }
    drop_depth -= 1;
    drop_queue.clearAndFree(std.heap.smp_allocator);
}

/// `~T`: a non-owning handle to an `RcBox(T)`.
pub fn WeakHandle(comptime T: type) type {
    return struct {
        ptr: *RcBox(T),

        const Self = @This();
        /// Its handle's type, for `typeName`.
        pub const __rig_weak = T;

        pub fn cloneWeak(self: Self) Self {
            self.ptr.weak += 1;
            return self;
        }

        pub fn dropWeak(self: Self) void {
            std.debug.assert(self.ptr.weak > 0);
            self.ptr.weak -= 1;
            if (self.ptr.weak == 0) defaultAllocator().destroy(self.ptr);
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll(if (self.ptr.strong > 0) "~(alive)" else "~(gone)");
        }

        /// A new strong handle, or null once the value has been dropped.
        pub fn upgrade(self: Self) ?*RcBox(T) {
            if (self.ptr.strong == 0) return null;
            self.ptr.strong += 1;
            return self.ptr;
        }

        pub fn __rig_drop(self: *Self) void {
            self.dropWeak();
        }
    };
}

/// `*<w`, `*~h`: a new strong handle from the weak handle `w`, which it
/// takes and drops once upgraded; null once the value has been dropped.
pub fn upgradeTaken(w: anytype) @TypeOf(w.upgrade()) {
    const up = w.upgrade();
    w.dropWeak();
    return up;
}

/// `+x` of a value that owns: a new value holding a clone of each part,
/// as `+` gives it: a handle counted again, a `String`'s bytes and a List's
/// elements copied, a box's value boxed again, plain data copied. Sema
/// clones only types with no `drop` body and nothing unique
/// (`sema.cloneable`).
pub fn cloneValue(value: anytype) @TypeOf(value.*) {
    const T = @TypeOf(value.*);
    if (comptime !needsDrop(T)) return value.*;
    if (comptime isOptStruct(T)) return pack(T, if (somePtr(value)) |inner| cloneValue(inner) else null);
    switch (@typeInfo(T)) {
        .pointer => return value.*.cloneStrong(),
        .optional => return if (value.*) |*inner| cloneValue(inner) else null,
        .array => {
            var out: T = undefined;
            for (&out, value) |*o, *v| o.* = cloneValue(v);
            return out;
        },
        .@"struct" => |s| {
            if (comptime @hasDecl(T, "__rig_string") or @hasDecl(T, "__rig_list")) return value.clone();
            if (comptime @hasDecl(T, "__rig_box")) return T.init(cloneValue(value.value));
            if (comptime @hasDecl(T, "__rig_weak")) return value.cloneWeak();
            var out: T = undefined;
            inline for (s.field_names) |f| @field(out, f) = cloneValue(&@field(value, f));
            return out;
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| return @unionInit(T, @tagName(tag), cloneValue(payload)),
        },
        else => @compileError("rig: cannot clone " ++ @typeName(T)),
    }
}

/// `+x` for an optional handle: another handle to the same box, or null.
pub fn cloneOptional(value: anytype) @TypeOf(value) {
    const O = @TypeOf(value);
    const h = some(value) orelse return pack(O, null);
    return pack(O, if (comptime isStrongHandle(@TypeOf(h))) h.cloneStrong() else h.cloneWeak());
}

/// `e == none` for a temporary optional that owns a resource: the
/// temporary is dropped.
pub fn isNone(value: anytype) bool {
    defer discard(value);
    return some(value) == null;
}

/// `xs.get(i)` on an array (or a pointer to one), a slice, or a `?String`:
/// the element at `i`, or null when out of range.
pub fn elementAt(items: anytype, i: Int) Opt(ElementOf(@TypeOf(items))) {
    const O = Opt(ElementOf(@TypeOf(items)));
    const idx = std.math.cast(usize, i) orelse return pack(O, null);
    return pack(O, if (idx < items.len) items[idx] else null);
}

/// The element type of an array, a pointer to one, or a slice.
fn ElementOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) std.meta.Elem(p.child) else p.child,
        else => std.meta.Elem(T),
    };
}

/// Drop a value nothing keeps: `_ = e`, `as _`, a match payload dropped
/// with `<x`.
pub fn discard(value: anytype) void {
    var v = value;
    drop(&v);
}

/// Drop a copy of the value `ptr` points to, which nothing else drops: a
/// part of a payload a `match <e` arm leaves unused, deferred. It takes a
/// pointer, so each exit Zig writes the deferred call at passes only that,
/// and the copy lives in this function's frame, once.
pub fn discardAt(ptr: anytype) void {
    var v = ptr.*;
    drop(&v);
}

/// Allocate a new `*T` holding `value`.
pub fn rcNew(value: anytype) *RcBox(@TypeOf(value)) {
    const box = create(RcBox(@TypeOf(value)));
    box.* = .{ .strong = 1, .weak = 1, .value = value };
    return box;
}

// -----------------------------------------------------------------------------
// Box (`^T`)
// -----------------------------------------------------------------------------

/// `^T`: one `T` on the heap, owned by the box. The box is a pointer
/// that moves, never copies; dropping it drops the value and frees its
/// memory. Deep chains of boxes are released through `drop_queue`, as
/// shared handles are.
pub fn Box(comptime T: type) type {
    return struct {
        value: *T,

        const Self = @This();

        pub fn init(value: T) Self {
            const p = create(T);
            p.* = value;
            return .{ .value = p };
        }

        /// `^[n of x]`: the array filled in its allocation, never made on
        /// the stack first.
        pub fn fill(x: @typeInfo(T).array.child) Self {
            const p = create(T);
            @memset(p, x);
            return .{ .value = p };
        }

        /// `<b.unbox()`: the value, moved out; the box's memory is freed.
        pub fn unbox(self: Self) T {
            const v = self.value.*;
            defaultAllocator().destroy(self.value);
            return v;
        }

        /// Printed as the value it holds (`writeValue`).
        pub const __rig_box = {};

        pub fn __rig_drop(self: *Self) void {
            if (comptime !needsDrop(T)) return defaultAllocator().destroy(self.value);
            if (drop_depth >= max_drop_depth) {
                drop_queue.append(std.heap.smp_allocator, .{ .box = @ptrCast(self.value), .release = releaseErased }) catch oom();
                return;
            }
            drop_depth += 1;
            release(self.value);
            drop_depth -= 1;
            if (drop_depth == 0) drainDropQueue();
        }

        fn release(p: *T) void {
            dropElement(T, p);
            defaultAllocator().destroy(p);
        }

        fn releaseErased(p: *anyopaque) void {
            release(@ptrCast(@alignCast(p)));
        }
    };
}

// -----------------------------------------------------------------------------
// Cell
// -----------------------------------------------------------------------------

/// `Cell(T)`: interior mutability. `get` is only offered for plain-data
/// `T` (sema enforces this); resource payloads move in and out with
/// `set` and `replace`.
pub fn Cell(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};

        pub fn get(self: *const Self) T {
            return self.value;
        }

        /// Store `value`, then drop the old one. The cell already holds
        /// the new value when the old one's drop runs, so a destructor
        /// that reaches back into this cell sees a live value.
        pub fn set(self: *Self, value: T) void {
            var old = self.value;
            self.value = value;
            dropElement(T, &old);
        }

        /// Store `value` and hand the old one to the caller.
        pub fn replace(self: *Self, value: T) T {
            const old = self.value;
            self.value = value;
            return old;
        }

        pub fn __rig_drop(self: *Self) void {
            dropElement(T, &self.value);
        }

        // A `Cell(List(E))` answers its List's members. No user code runs
        // while the List is in use: `push`, `pop`, `len`, and the element
        // reads and writes of a plain-data `E` run no destructor, `clear`
        // empties the cell before it drops the elements, and `keep` pops
        // each element before it drops it.

        /// The element type when `T` is a List; referenced only then.
        const E = @typeInfo(@FieldType(T, "buf")).pointer.child;

        pub fn listPush(self: *Self, value: E) void {
            self.value.push(value);
        }

        pub fn listPop(self: *Self) Opt(E) {
            return self.value.pop();
        }

        pub fn listLen(self: *const Self) Int {
            return len(self.value.len);
        }

        pub fn listAt(self: *const Self, i: anytype) E {
            return self.value.at(i);
        }

        pub fn listGet(self: *const Self, i: Int) Opt(E) {
            return self.value.get(i);
        }

        pub fn listSet(self: *Self, i: anytype, value: E) void {
            self.value.slot(i).* = value;
        }

        /// Each element leaves the List before it drops, so a drop that
        /// reaches back into the cell finds the elements not yet dropped;
        /// what it pushes past the first `n` is dropped in turn.
        pub fn listKeep(self: *Self, n: Int) void {
            const rest = index(n, self.value.len + 1);
            if (comptime !needsDrop(E)) {
                self.value.len = rest;
                return;
            }
            while (self.value.len > rest) {
                var gone = some(self.value.pop()).?;
                dropElement(E, &gone);
            }
        }

        /// A drop that reaches back into the cell finds an empty List.
        pub fn listClear(self: *Self) void {
            var old = self.value;
            self.value = .empty;
            old.__rig_drop();
        }
    };
}

// -----------------------------------------------------------------------------
// Owned closures
// -----------------------------------------------------------------------------

// An owned closure `*fun(A, B) -> R` / `*sub(A)` is a shared handle to a
// `Closure(&.{ A, B }, R)`: a type-erased closure. Each closure literal
// allocates its own environment `Env` (the captures plus an `__rig_invoke`
// method taking the parameters); `init` erases it behind `ctx`, so every
// literal with the same parameter and return types has the same type.
// `drop_fn` releases the captures and frees the environment.

pub fn Closure(comptime params: []const type, comptime R: type) type {
    return struct {
        ctx: *anyopaque,
        invoke_fn: *const fn (*anyopaque, Args) R,
        drop_fn: *const fn (*anyopaque) void,

        const Self = @This();
        /// Its function type, for `typeName`.
        pub const __rig_fn = .{ params, R };
        pub const Args = @Tuple(params);

        /// Erase `env`, a heap-allocated `Env` the closure now owns.
        pub fn init(comptime Env: type, env: *Env) Self {
            const erased = struct {
                fn invoke(ctx: *anyopaque, args: Args) R {
                    const e: *Env = @ptrCast(@alignCast(ctx));
                    return @call(.auto, Env.__rig_invoke, .{e} ++ args);
                }
                fn dropEnv(ctx: *anyopaque) void {
                    const e: *Env = @ptrCast(@alignCast(ctx));
                    dropFields(e);
                    defaultAllocator().destroy(e);
                }
            };
            return .{ .ctx = env, .invoke_fn = erased.invoke, .drop_fn = erased.dropEnv };
        }

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<closure>");
        }

        pub fn invoke(self: *Self, args: Args) R {
            return self.invoke_fn(self.ctx, args);
        }

        pub fn __rig_drop(self: *Self) void {
            self.drop_fn(self.ctx);
        }
    };
}

/// `*sub()`: what a Signal notifies.
const Callback = Closure(&.{}, void);

// A callable view `?fun(A, B) -> R` / `?sub(A)` is a
// `FnRef(&.{ A, B }, R)`: a context pointer and a function that calls
// through it, 16 bytes passed by value. It lends what the caller owns (a
// stack closure's environment, a function, an owned closure) for as long
// as the ownership checker lets the view live, and owns nothing.

pub fn FnRef(comptime params: []const type, comptime R: type) type {
    return struct {
        ctx: *anyopaque,
        call_fn: *const fn (*anyopaque, Args) R,

        const Self = @This();
        pub const Args = @Tuple(params);

        /// Lend `env`, a stack closure's environment, whose `__rig_invoke`
        /// takes the parameters.
        pub fn of(comptime Env: type, env: *Env) Self {
            const thunk = struct {
                fn call(ctx: *anyopaque, args: Args) R {
                    const e: *Env = @ptrCast(@alignCast(ctx));
                    return @call(.auto, Env.__rig_invoke, .{e} ++ args);
                }
            };
            return .{ .ctx = env, .call_fn = thunk.call };
        }

        /// Lend function `f`, a function or a pointer to one.
        pub fn ofFn(f: anytype) Self {
            if (@typeInfo(@TypeOf(f)) == .@"fn") return ofFn(&f);
            const F = @TypeOf(f);
            const thunk = struct {
                fn call(ctx: *anyopaque, args: Args) R {
                    const g: F = @ptrCast(@alignCast(ctx));
                    return @call(.auto, g, args);
                }
            };
            return .{ .ctx = @ptrCast(@constCast(f)), .call_fn = thunk.call };
        }

        /// Lend the owned closure `handle` points to (a
        /// `*RcBox(Closure(params, R))`, or a pointer to one).
        pub fn ofClosure(handle: anytype) Self {
            const box = if (@typeInfo(@TypeOf(handle.*)) == .pointer) handle.* else handle;
            const C = @TypeOf(box.value);
            const thunk = struct {
                fn call(ctx: *anyopaque, args: Args) R {
                    const c: *C = @ptrCast(@alignCast(ctx));
                    return c.invoke(args);
                }
            };
            return .{ .ctx = &box.value, .call_fn = thunk.call };
        }

        pub fn call(self: Self, args: Args) R {
            return self.call_fn(self.ctx, args);
        }

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<closure>");
        }
    };
}

// -----------------------------------------------------------------------------
// Signal
// -----------------------------------------------------------------------------

/// `Signal(T)`: a value plus subscribers notified on every `set`. `T` is
/// plain data. A `set` from inside a subscriber is queued (latest value
/// wins) and delivered in another round once the current one finishes;
/// subscribing from inside a subscriber panics.
pub fn Signal(comptime T: type) type {
    return struct {
        value: T,
        subs: List(*RcBox(Callback)),
        notifying: bool = false,
        pending: ?T = null,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};

        pub fn init(value: T) Self {
            return .{ .value = value, .subs = .empty };
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("Signal(value: ");
            try writeValue(w, self.value, false);
            try w.writeAll(")");
        }

        pub fn set(self: *Self, value: T) void {
            if (self.notifying) {
                self.pending = value;
                return;
            }
            self.notifying = true;
            defer self.notifying = false;
            var next: ?T = value;
            while (next) |v| {
                self.value = v;
                self.pending = null;
                for (self.subs.items()) |cb| cb.value.invoke(.{});
                next = self.pending;
            }
        }

        /// Takes ownership of `cb`; the caller passes its own strong
        /// handle (`sig.subscribe(+cb)` to keep one).
        pub fn subscribe(self: *Self, cb: *RcBox(Callback)) void {
            if (self.notifying) @panic("Signal.subscribe called while notifying subscribers");
            self.subs.push(cb);
        }

        pub fn __rig_drop(self: *Self) void {
            self.subs.__rig_drop();
        }
    };
}

// -----------------------------------------------------------------------------
// List
// -----------------------------------------------------------------------------

/// A fact the runtime's fast paths rely on in place of a check. Debug
/// builds verify it; optimized builds trust it, so the hot path carries
/// no branch for a case that cannot happen.
inline fn invariant(ok: bool) void {
    if (builtin.mode == .debug) std.debug.assert(ok);
}

/// `List(T)`: a growable array that owns its elements. Dropping it drops
/// the elements in reverse order, then frees the buffer.
pub fn List(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};

        pub const empty: Self = .{};

        pub fn initCapacity(capacity: Int) Self {
            var v: Self = .empty;
            v.reserve(capacity);
            return v;
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeList(w, self.items());
        }

        pub const __rig_list = {};

        /// `+v`: a new List holding a clone of each element (`cloneValue`).
        pub fn clone(self: *const Self) Self {
            var out: Self = .empty;
            out.reserveTotal(self.len);
            for (self.items()) |*e| out.push(cloneValue(e));
            return out;
        }

        /// The live elements. Invalidated by `push`.
        pub fn items(self: *const Self) []T {
            return self.buf[0..self.len];
        }

        /// Room for `want` elements in all.
        fn reserveTotal(self: *Self, want: usize) void {
            if (want <= self.buf.len) return;
            self.grow(want);
        }

        /// `!v.reserve(n)`: room for `n` more elements; the length is
        /// unchanged. Panics when `n` is negative.
        pub fn reserve(self: *Self, n: Int) void {
            const extra = std.math.cast(usize, n) orelse @panic("negative size");
            self.reserveTotal(self.len +| extra);
        }

        /// The out-of-line growth, so `push` stays small enough to inline.
        noinline fn grow(self: *Self, want: usize) void {
            // A zero-bit element takes no memory, so every length fits:
            // the buffer is made as long as any length can be, and
            // freeing it frees nothing.
            if (comptime @sizeOf(T) == 0) {
                self.buf = self.buf.ptr[0..std.math.maxInt(usize)];
                return;
            }
            self.buf = defaultAllocator().realloc(self.buf, @max(want, 4, self.buf.len * 2)) catch oom();
        }

        /// `len <= buf.len` always holds. When the buffer is full, `grow`
        /// leaves `len < buf.len`, so the slot at `len` exists, `len + 1`
        /// cannot overflow, and the store needs no bounds check.
        pub fn push(self: *Self, value: T) void {
            if (self.len == self.buf.len) self.grow(self.len +% 1);
            invariant(self.len < self.buf.len);
            self.buf.ptr[self.len] = value;
            self.len +%= 1;
        }

        /// The element at `i`, or null when out of range. Plain-data `T` only.
        pub fn get(self: *const Self, i: Int) Opt(T) {
            const idx = std.math.cast(usize, i) orelse return pack(Opt(T), null);
            return pack(Opt(T), if (idx < self.len) self.buf[idx] else null);
        }

        /// `v[i]`: the element at `i`; panics when out of range.
        pub fn at(self: *const Self, i: anytype) T {
            return self.buf[index(i, self.len)];
        }

        /// `v[i] = x`: the slot at `i`; panics when out of range.
        pub fn slot(self: *Self, i: anytype) *T {
            return &self.buf[index(i, self.len)];
        }

        /// The slot at `i`, read-only, for an element reached through a
        /// read view; panics when out of range.
        pub fn constSlot(self: *const Self, i: anytype) *const T {
            return &self.buf[index(i, self.len)];
        }

        /// Remove and return the last element; the caller owns it.
        pub fn pop(self: *Self) Opt(T) {
            if (self.len == 0) return pack(Opt(T), null);
            self.len -= 1;
            return pack(Opt(T), self.buf[self.len]);
        }

        /// Insert `value` at `i`, moving the elements from `i` on up by
        /// one; `i` may be `len`. Panics unless `0 <= i <= len`.
        pub fn insert(self: *Self, i: Int, value: T) void {
            const idx = index(i, self.len + 1);
            self.reserveTotal(self.len + 1);
            std.mem.copyBackwards(T, self.buf[idx + 1 .. self.len + 1], self.buf[idx..self.len]);
            self.buf[idx] = value;
            self.len += 1;
        }

        /// Remove and return the element at `i`, moving the ones after
        /// it down by one; the caller owns it. Panics unless
        /// `0 <= i < len`.
        pub fn remove(self: *Self, i: Int) T {
            const idx = index(i, self.len);
            const value = self.buf[idx];
            std.mem.copyForwards(T, self.buf[idx .. self.len - 1], self.buf[idx + 1 .. self.len]);
            self.len -= 1;
            return value;
        }

        /// `for x in <v`: the List's elements, each handed over in order.
        pub const IntoIter = struct {
            list: Self,
            next_index: usize = 0,

            pub fn next(it: *IntoIter) Opt(T) {
                if (it.next_index >= it.list.len) return pack(Opt(T), null);
                const value = it.list.buf[it.next_index];
                it.next_index += 1;
                return pack(Opt(T), value);
            }

            /// Drop the elements not handed over (the loop left early),
            /// last first as a List does, then free the buffer.
            pub fn deinit(it: *IntoIter) void {
                if (comptime needsDrop(T)) {
                    invariant(it.list.len <= it.list.buf.len);
                    while (it.list.len > it.next_index) {
                        it.list.len -= 1;
                        dropElement(T, &it.list.buf.ptr[it.list.len]);
                    }
                }
                it.list.len = 0;
                it.list.__rig_drop();
            }
        };

        pub fn intoIter(self: Self) IntoIter {
            return .{ .list = self };
        }

        /// Drop every element (last first), keeping the buffer. Plain
        /// elements own nothing, so clearing them is setting the length;
        /// otherwise each live slot, inside the buffer by `len <= buf.len`,
        /// is dropped without a bounds check.
        pub fn clear(self: *Self) void {
            if (comptime !needsDrop(T)) {
                self.len = 0;
                return;
            }
            invariant(self.len <= self.buf.len);
            while (self.len > 0) {
                self.len -= 1;
                dropElement(T, &self.buf.ptr[self.len]);
            }
        }

        /// `!v.keep(n)`: keep the first `n` elements and drop the rest,
        /// last first as `clear` does, keeping the buffer. Panics unless
        /// `0 <= n <= len`.
        pub fn keep(self: *Self, n: Int) void {
            const rest = index(n, self.len + 1);
            if (comptime !needsDrop(T)) {
                self.len = rest;
                return;
            }
            invariant(self.len <= self.buf.len);
            while (self.len > rest) {
                self.len -= 1;
                dropElement(T, &self.buf.ptr[self.len]);
            }
        }

        /// `List.filled(n, x)`: `n` copies of `x` in one allocation of
        /// exactly `n` slots, filled by one `@memset`. Sema admits only
        /// a `T` that copies. Panics when `n` is negative.
        pub fn filled(n: Int, value: T) Self {
            const count = std.math.cast(usize, n) orelse @panic("negative size");
            if (count == 0) return .empty;
            const buf = defaultAllocator().alloc(T, count) catch oom();
            @memset(buf, value);
            return .{ .buf = buf, .len = count };
        }

        /// `!v.resize(n, x)`: grow to `n` elements with copies of `x`,
        /// one allocation at most (growing as `push` does, so resizing
        /// up by small steps stays linear) and one `@memset`, or shrink
        /// to `n` as `keep` does. Sema admits only a `T` that copies.
        /// Panics when `n` is negative.
        pub fn resize(self: *Self, n: Int, value: T) void {
            const want = std.math.cast(usize, n) orelse @panic("negative size");
            if (want <= self.len) return self.keep(n);
            self.reserveTotal(want);
            invariant(want <= self.buf.len);
            @memset(self.buf.ptr[self.len..want], value);
            self.len = want;
        }

        pub fn __rig_drop(self: *Self) void {
            self.clear();
            defaultAllocator().free(self.buf);
            self.buf = &.{};
        }
    };
}

// -----------------------------------------------------------------------------
// String
// -----------------------------------------------------------------------------

/// `String`: owned, growable bytes, UTF-8 by convention. `String(a, b)` and
/// `!t.add(a, b)` write each value as `print` does at the top level
/// (`writeValue`), with no separators; a `?String` taken from a `String` views
/// its buffer, which the ownership checker keeps from changing while a
/// view is in use.
pub const String = struct {
    list: std.ArrayList(u8) = .empty,

    /// Printed as its bytes (`writeValue`), compared by them (`eql`).
    pub const __rig_string = {};

    pub const empty: String = .{};

    /// `String(a, b, ...)`.
    pub inline fn of(pieces: anytype) String {
        var t: String = .empty;
        t.add(pieces);
        return t;
    }

    /// `!t.add(a, b, ...)`: the pieces as `print` takes them (`piecesOf`),
    /// with no separators. Inlined, it is a straight line of appends:
    /// each run of text once, each value by the one writer of its type.
    pub inline fn add(self: *String, pieces: anytype) void {
        inline for (comptime piecesOf(@TypeOf(pieces))) |p| switch (p) {
            .text => |t| self.appendFixed(t.len, t[0..t.len]),
            .value => |f| self.addValue(pieces[f]),
        };
    }

    /// Text of `n` bytes known at compile time, appended by the one
    /// function of its length.
    noinline fn appendFixed(self: *String, comptime n: usize, text: *const [n]u8) void {
        self.appendBytes(text);
    }

    /// A value `add` writes: text and a String as their bytes, which the
    /// ownership checker keeps from being this String's own, anything
    /// else by the one writer of its type.
    inline fn addValue(self: *String, value: anytype) void {
        const P = @TypeOf(value);
        if (comptime isStringView(P)) return self.appendBytes(value);
        if (comptime P == String or isStringPlace(P)) return self.appendBytes(value.list.items);
        self.addValueOf(value);
    }

    noinline fn addValueOf(self: *String, value: anytype) void {
        var out: std.Io.Writer.Allocating = .fromArrayList(defaultAllocator(), &self.list);
        defer self.list = out.toArrayList();
        writeValue(&out.writer, value, true) catch oom();
    }

    // The list's `items.len <= capacity` always holds, so every append
    // below tests the room once, grows when short, and then stores
    // through `items.ptr` at `items.len`: the slot is inside the
    // capacity by construction, and the new length cannot overflow
    // because it is at most the capacity. Debug builds check both (`invariant`).

    /// `!t.push(b)`: append one byte.
    pub fn push(self: *String, b: u8) void {
        const l = &self.list;
        if (l.items.len == l.capacity) self.grow(1);
        invariant(l.items.len < l.capacity);
        l.items.ptr[l.items.len] = b;
        l.items.len +%= 1;
    }

    /// `!t.reserve(n)`: room for `n` more bytes; the length is unchanged.
    pub fn reserve(self: *String, n: Int) void {
        const extra = std.math.cast(usize, n) orelse @panic("negative size");
        const l = &self.list;
        if (l.capacity -% l.items.len < extra) self.grow(extra);
        invariant(l.capacity -% l.items.len >= extra);
    }

    /// `!t.push[T, e](v)`: append the bytes of the integer `v`, in byte
    /// order `endian`, in one write.
    pub fn pushInt(self: *String, comptime T: type, value: T, comptime endian: Endian) void {
        const n = @divExact(@bitSizeOf(T), 8);
        const l = &self.list;
        const used = l.items.len;
        if (l.capacity -% used < n) self.grow(n);
        invariant(l.capacity -% used >= n);
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        const raw: Bits = @bitCast(value);
        // One store of the whole integer, through an unaligned pointer
        // at `used`; `used + n <= capacity` puts all `n` bytes inside
        // the allocation, and keeps `used + n` from overflowing.
        const dst: *align(1) Bits = @ptrCast(l.items.ptr + used);
        dst.* = if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(raw) else raw;
        l.items.len = used +% n;
    }

    /// `!t.push(v, keep: k)` of a vector of bytes, and
    /// `!t.push[T, e](w, keep: k)` of an integer: append the first `k`
    /// bytes of `v`, in byte order `endian` for an integer. Room is made
    /// for all of `v`, which one unaligned store writes after the
    /// length; the length then grows by `k`, so the bytes past it are
    /// spare capacity that no String operation reads. Panics unless
    /// `0 <= k <= @sizeOf(T)`.
    pub fn pushKeep(self: *String, comptime T: type, value: T, count: Int, comptime endian: Endian) void {
        const is_vector = @typeInfo(T) == .vector;
        const n = if (is_vector) @typeInfo(T).vector.len else @sizeOf(T);
        const k = std.math.cast(usize, count) orelse keepPanic(count, n);
        if (k > n) keepPanic(count, n);
        const l = &self.list;
        const used = l.items.len;
        if (l.capacity -% used < n) self.grow(n);
        invariant(l.capacity -% used >= n);
        // One store of all `n` bytes at `used`, through an unaligned
        // pointer; `used + n <= capacity` puts them inside the allocation.
        const dst = l.items.ptr + used;
        if (comptime is_vector) {
            if (comptime wideVector(T, n)) {
                const p: *align(1) T = @ptrCast(dst);
                p.* = value;
            } else if (comptime smallVector(n)) {
                const p: *align(1) @Int(.unsigned, n * 8) = @ptrCast(dst);
                p.* = @bitCast(value);
            } else dst[0..n].* = @bitCast(value);
        } else {
            const p: *align(1) T = @ptrCast(dst);
            p.* = if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(value) else value;
        }
        l.items.len = used +% k;
    }

    noinline fn keepPanic(count: Int, n: usize) noreturn {
        std.debug.panic("`keep: {d}` is outside 0..{d}, the bytes pushed", .{ count, n });
    }

    /// Append `bytes_`, which does not alias this String's buffer.
    fn appendBytes(self: *String, bytes_: []const u8) void {
        const l = &self.list;
        const used = l.items.len;
        if (l.capacity -% used < bytes_.len) self.grow(bytes_.len);
        invariant(l.capacity -% used >= bytes_.len);
        @memcpy((l.items.ptr + used)[0..bytes_.len], bytes_);
        l.items.len = used +% bytes_.len;
    }

    noinline fn grow(self: *String, extra: usize) void {
        self.list.ensureUnusedCapacity(defaultAllocator(), extra) catch oom();
    }

    /// `!t.clear()`: empty, keeping the buffer.
    pub fn clear(self: *String) void {
        self.list.items.len = 0;
    }

    /// The bytes, as a `?String`: `?t[..]`, `?t` where a `?String` goes.
    pub fn bytes(self: String) []const u8 {
        return self.list.items;
    }

    /// `t.len`.
    pub fn length(self: String) Int {
        return @intCast(self.list.items.len);
    }

    /// `+t`: a new String holding the same bytes.
    pub fn clone(self: String) String {
        var t: String = .empty;
        t.list.appendSlice(defaultAllocator(), self.list.items) catch oom();
        return t;
    }

    pub fn __rig_drop(self: *String) void {
        self.list.deinit(defaultAllocator());
        self.list = .empty;
    }
};

// -----------------------------------------------------------------------------
// Type names
// -----------------------------------------------------------------------------

// `@name(T)` of a type parameter: the name of the instance, as Rig writes
// it. The runtime holds no Rig name. The emitter writes every name from
// sema's type printer: into each type it emits, and into the table of
// each module that asks. This follows the shape of a Zig type between
// them, as the printer spells each shape.
//
// The table, `names` (`__rig_names` in the module), has:
//   .module    the module asking, as a `__rig_name` names its module;
//   .imports   each module it imports, and what its types are qualified
//              with there (`.{ "geo", "geo." }`);
//   .types     each built-in type, and its name;
//   .generics  each of the runtime's generic types, and its spelling:
//              strings, and the index of each argument.
// A type the emitter writes declares `__rig_name`: `.module`, its module
// (empty for the root), and `.name`, its spelling: strings, and each of
// its parameters, a type or a compile-time integer.

/// The name of `x`, a type or a compile-time integer, as the module
/// whose table is `names` writes it.
pub fn typeName(comptime x: anytype, comptime names: anytype) []const u8 {
    return comptime nameOf(x, names);
}

fn nameOf(comptime x: anytype, comptime names: anytype) []const u8 {
    if (@TypeOf(x) != type) return std.fmt.comptimePrint("{d}", .{x});
    const T = x;
    if (builtinName(T, names)) |name| return name;
    if (comptime isOptStruct(T)) return suffixedName(Payload(T), "?", names);
    return switch (@typeInfo(T)) {
        .optional => |o| suffixedName(o.child, "?", names),
        .error_union => |e| suffixedName(e.payload, "!", names),
        .error_set => |e| errorSetName(e.error_names.?[0], names),
        .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ nameOf(a.child, names),
        .vector => |v| "Simd[" ++ nameOf(v.child, names) ++ std.fmt.comptimePrint(", {d}]", .{v.len}),
        // A function, or a strong handle. A type parameter holds no view
        // or slice: its instance is a type the generic body may copy.
        .pointer => |p| if (@typeInfo(p.child) == .@"fn")
            fnName(@typeInfo(p.child).@"fn".param_types, @typeInfo(p.child).@"fn".return_type.?, names)
        else if (isStrongHandle(T))
            handleName("*", @FieldType(p.child, "value"), names)
        else
            @compileError("rig.typeName: no Rig name for " ++ @typeName(T)),
        .@"struct", .@"union", .@"enum" => if (comptime isWideMask(T))
            "Simd[" ++ nameOf(bool, names) ++ std.fmt.comptimePrint(", {d}]", .{T.__rig_mask})
        else if (@hasDecl(T, "__rig_name"))
            qualifier(T.__rig_name.module, names) ++ spell(T.__rig_name.name, .{}, names)
        else if (@hasDecl(T, "__rig_weak"))
            handleName("~", T.__rig_weak, names)
        else if (@hasDecl(T, "__rig_box"))
            handleName("^", @typeInfo(@FieldType(T, "value")).pointer.child, names)
        else if (@hasDecl(T, "__rig_fn"))
            fnName(T.__rig_fn[0], T.__rig_fn[1], names)
        else
            genericName(T, names),
        else => @compileError("rig.typeName: no Rig name for " ++ @typeName(T)),
    };
}

fn builtinName(comptime T: type, comptime names: anytype) ?[]const u8 {
    inline for (names.types) |entry| if (entry[0] == T) return entry[1];
    return null;
}

/// An instance of one of the runtime's generic types, which declares
/// its arguments, `__rig_args`.
fn genericName(comptime T: type, comptime names: anytype) []const u8 {
    if (@hasDecl(T, "__rig_args")) inline for (names.generics) |g| {
        if (@typeInfo(@TypeOf(g[0])).@"fn".param_types.len == T.__rig_args.len and @call(.auto, g[0], T.__rig_args) == T)
            return spell(g[1], T.__rig_args, names);
    };
    @compileError("rig.typeName: no Rig name for " ++ @typeName(T));
}

/// A spelling: each string as it is, and each other part named, an
/// index standing for that argument of `args`.
fn spell(comptime parts: anytype, comptime args: anytype, comptime names: anytype) []const u8 {
    var out: []const u8 = "";
    inline for (parts) |part| out = out ++ switch (@typeInfo(@TypeOf(part))) {
        .pointer => part,
        .comptime_int => nameOf(args[part], names),
        else => nameOf(part, names),
    };
    return out;
}

/// What a type of `module` is qualified with where `names` is written:
/// nothing in its own module, or the root's, the name it is imported
/// under, or else its own name.
fn qualifier(comptime module: []const u8, comptime names: anytype) []const u8 {
    if (module.len == 0 or std.mem.eql(u8, module, names.module)) return "";
    inline for (names.imports) |imp| if (std.mem.eql(u8, imp[0], module)) return imp[1];
    return module ++ ".";
}

/// An error set, by one of its errors' names, which the emitter writes
/// as `module.Set.error` (`Set.error` in the root).
fn errorSetName(comptime error_name: []const u8, comptime names: anytype) []const u8 {
    const set = error_name[0 .. std.mem.lastIndexOfScalar(u8, error_name, '.').?];
    const dot = std.mem.lastIndexOfScalar(u8, set, '.') orelse return set;
    return qualifier(set[0..dot], names) ++ set[dot + 1 ..];
}

/// A function type: `fun(A, B) -> R`, or `sub(A)` returning nothing,
/// `sub(A)!` when it may fail. Its parameters are types, or a Zig
/// function's (`?type`).
fn fnName(comptime params: anytype, comptime R: type, comptime names: anytype) []const u8 {
    var list: []const u8 = "";
    inline for (params, 0..) |P, i| list = list ++ (if (i > 0) ", " else "") ++ nameOf(if (@TypeOf(P) == type) P else P.?, names);
    if (R == void) return "sub(" ++ list ++ ")";
    if (@typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void) return "sub(" ++ list ++ ")!";
    return "fun(" ++ list ++ ") -> " ++ nameOf(R, names);
}

/// `T?` / `T!`, with `T` in parentheses when a suffix cannot follow it,
/// as the printer writes them.
fn suffixedName(comptime T: type, comptime suffix: []const u8, comptime names: anytype) []const u8 {
    const doubled = std.mem.eql(u8, suffix, "?") and builtinName(T, names) == null and isOptional(T);
    if (doubled or takesNoSuffix(T, names)) return "(" ++ nameOf(T, names) ++ ")" ++ suffix;
    return nameOf(T, names) ++ suffix;
}

/// An array or a function, or a handle to one: a type whose spelling a
/// suffix cannot follow.
fn takesNoSuffix(comptime T: type, comptime names: anytype) bool {
    // A built-in type's name takes a suffix, unless it is a view's: `?String`.
    if (builtinName(T, names)) |name| return name[0] == '?';
    return switch (@typeInfo(T)) {
        .array => true,
        .pointer => |p| if (isStrongHandle(T)) takesNoSuffix(@FieldType(p.child, "value"), names) else true,
        .@"struct" => if (@hasDecl(T, "__rig_weak"))
            takesNoSuffix(T.__rig_weak, names)
        else if (@hasDecl(T, "__rig_box"))
            takesNoSuffix(@typeInfo(@FieldType(T, "value")).pointer.child, names)
        else
            @hasDecl(T, "__rig_fn"),
        else => false,
    };
}

/// `*T` / `~T` / `^T`, with `T` in parentheses when it is suffixed.
fn handleName(comptime sigil: []const u8, comptime T: type, comptime names: anytype) []const u8 {
    // A box of a read view is written `^?T`; a handle holds no view.
    const view = if (builtinName(T, names)) |name| name[0] == '?' and sigil[0] != '^' else false;
    const suffixed = view or isOptional(T) or @typeInfo(T) == .error_union;
    return if (suffixed) sigil ++ "(" ++ nameOf(T, names) ++ ")" else sigil ++ nameOf(T, names);
}

// -----------------------------------------------------------------------------
// Zig-backed declarations
// -----------------------------------------------------------------------------

/// The check the emitter writes for each Zig-backed declaration of the
/// standard library (`extern zig "file.zig"`): its function in the Zig
/// file has exactly the type its Rig signature lowers to, so a call the
/// checker accepts passes and returns what Rig says it does. `Errors` is
/// every error of the module's error sets. Where the Rig signature can
/// fail (`anyerror!T`), the Zig function returns `E!T` instead, for an
/// error set `E` it names, each error of which is in `Errors`: so a
/// failure is always one of the module's Rig errors.
pub fn expectShim(comptime f: anytype, comptime Rig: type, comptime Errors: type, comptime name: []const u8) void {
    const F = @TypeOf(f);
    const rig_ret = @typeInfo(Rig).@"fn".return_type.?;
    if (@typeInfo(rig_ret) != .error_union) {
        if (F != Rig) shimMismatch(F, @typeName(Rig), name);
        return;
    }
    const rig_name = @typeName(Rig);
    const lowered = rig_name[0 .. rig_name.len - @typeName(rig_ret).len] ++ "E!" ++ @typeName(@typeInfo(rig_ret).error_union.payload) ++ ", for an error set E of module `" ++ moduleOf(name) ++ "`";
    const fi = switch (@typeInfo(F)) {
        .@"fn" => |fi| fi,
        else => shimMismatch(F, lowered, name),
    };
    const ri = @typeInfo(Rig).@"fn";
    const ret = fi.return_type orelse shimMismatch(F, lowered, name);
    if (@typeInfo(ret) != .error_union or fi.attrs.varargs or fi.param_types.len != ri.param_types.len or
        @typeInfo(ret).error_union.payload != @typeInfo(rig_ret).error_union.payload or
        !std.meta.eql(fi.attrs.@"callconv", ri.attrs.@"callconv")) shimMismatch(F, lowered, name);
    for (fi.param_types, ri.param_types, fi.param_attrs, ri.param_attrs) |p, q, pa, qa| if (p != q or pa.@"noalias" != qa.@"noalias") shimMismatch(F, lowered, name);
    const set = @typeInfo(@typeInfo(ret).error_union.error_set).error_set.error_names orelse
        @compileError("rig: the Zig function of `" ++ name ++ "` returns `anyerror`; it must name the errors it returns, each an error of module `" ++ moduleOf(name) ++ "`");
    const allowed = @typeInfo(Errors).error_set.error_names.?;
    for (set) |e| {
        const known = for (allowed) |a| {
            if (std.mem.eql(u8, a, e)) break true;
        } else false;
        if (!known) @compileError("rig: the Zig function of `" ++ name ++ "` returns `error." ++ e ++ "`, which is not an error of module `" ++ moduleOf(name) ++ "`: its errors are named `error.@\"" ++ moduleOf(name) ++ ".Set.name\"`");
    }
}

fn shimMismatch(comptime F: type, comptime lowered: []const u8, comptime name: []const u8) noreturn {
    @compileError("rig: the Zig function of `" ++ name ++ "` has type " ++ @typeName(F) ++ ", but its Rig signature lowers to " ++ lowered);
}

/// The module of the declaration `std.NAME.decl`.
fn moduleOf(comptime name: []const u8) []const u8 {
    return name[0 .. std.mem.findScalarLast(u8, name, '.') orelse 0];
}

// -----------------------------------------------------------------------------
// Integers and indexing
// -----------------------------------------------------------------------------

/// Convert a Rig index of any integer type to `usize`, panicking unless
/// `0 <= i < len`.
pub fn index(i: anytype, count: usize) usize {
    const idx = std.math.cast(usize, i) orelse indexPanic();
    if (idx >= count) indexPanic();
    return idx;
}

/// A float about to be converted to an integer type, panicking if it is
/// NaN, which `@trunc`'s own range check does not catch.
pub fn notNan(x: anytype) @TypeOf(x) {
    if (comptime builtin.optimize.runtimeSafety()) if (std.math.isNan(x)) @panic("integer part of floating point value out of bounds");
    return x;
}

/// `x.fraction()`: the fraction of `frexp`, in [0.5, 1) in magnitude.
pub fn frexpFraction(x: anytype) @TypeOf(x) {
    return std.math.frexp(x).significand;
}

/// `x.exponent()`: the exponent of `frexp`; 0 for an infinity or a NaN,
/// as Go's.
pub fn frexpExponent(x: anytype) i64 {
    if (!std.math.isFinite(x)) return 0;
    return std.math.frexp(x).exponent;
}

/// The variant of plain enum `E` whose integer value is `n`, or null.
pub fn enumFromInt(comptime E: type, n: anytype) Opt(E) {
    return pack(Opt(E), std.enums.fromInt(E, n));
}

/// `e.text`: the Rig name of plain enum value `e`'s variant (`rigName`),
/// or of the value a write view of it points at.
pub fn enumText(e: anytype) []const u8 {
    return rigName(switch (@typeInfo(@TypeOf(e))) {
        .pointer => @tagName(e.*),
        else => @tagName(e),
    });
}

/// `E.from_text(word)`: the variant of plain enum `E` named `word`, or
/// null. `names` is the table of `E`'s names in declaration order, which
/// the compiler emits for each enum the program calls `from_text` on.
pub fn enumFromText(comptime E: type, names: NameTable, word: []const u8) ?E {
    const i = names.find(word) orelse return null;
    return std.enums.values(E)[i];
}

/// A fixed set of names, each found by its text with no allocation: a
/// plain enum's variants for `E.from_text(word)`. The compiler builds
/// the table and emits it as constant data (`src/nametable.zig`); `find`
/// gives a name's index in `names`.
///
/// The table is open-addressed: `tags.len` slots, a power of two of at
/// least 16, at most four fifths full. A word hashes once (`hashOf`),
/// starts at the slot the hash's low bits give, and walks on to the
/// first empty slot. A slot's tag is 0 when it is empty, and otherwise
/// `tagOf` of its name's hash, so a name's bytes are compared only where
/// the tag agrees; `slots` holds each full slot's index into `names`.
/// Measured against comparing the names one by one, the table wins every
/// miss at every size, and loses only a hit among a few names, by 1 to
/// 2 ns (bench/names/README.md), so every set of names gets one.
pub const NameTable = struct {
    names: []const []const u8,
    tags: []const u8,
    slots: []const u32,

    pub fn hashOf(word: []const u8) u64 {
        return std.hash.Wyhash.hash(0, word);
    }

    /// The top seven bits of hash `h`, and the eighth set, so no tag is
    /// the empty slot's 0.
    pub fn tagOf(h: u64) u8 {
        return @as(u8, @intCast(h >> 57)) | 0x80;
    }

    pub fn find(t: NameTable, word: []const u8) ?u32 {
        const h = hashOf(word);
        const tag = tagOf(h);
        const last = t.tags.len - 1;
        var i: usize = @intCast(h & last);
        while (true) : (i = (i + 1) & last) {
            const slot_tag = t.tags[i];
            if (slot_tag == 0) return null;
            if (slot_tag == tag) {
                const id = t.slots[i];
                if (std.mem.eql(u8, t.names[id], word)) return id;
            }
        }
    }
};

/// `for x in <a` of an array whose elements move: each element handed
/// over in order; those not handed over (the loop left early) are
/// dropped, last first, as the array would drop them.
pub fn ArrayIntoIter(comptime A: type) type {
    const T = @typeInfo(A).array.child;
    return struct {
        items: A,
        next_index: usize = 0,

        pub fn next(it: *@This()) Opt(T) {
            if (it.next_index >= it.items.len) return pack(Opt(T), null);
            const value = it.items[it.next_index];
            it.next_index += 1;
            return pack(Opt(T), value);
        }

        pub fn deinit(it: *@This()) void {
            var i: usize = it.items.len;
            while (i > it.next_index) {
                i -= 1;
                dropElement(T, &it.items[i]);
            }
        }
    };
}

pub fn arrayIntoIter(items: anytype) ArrayIntoIter(@TypeOf(items)) {
    return .{ .items = items };
}

/// The elements of the array `p` points to, as a slice. Zig rejects
/// indexing an array of length 0, which an array sized by a compile-time
/// parameter may be; a slice's index is checked when the program runs.
pub fn elems(p: anytype) Elems(@TypeOf(p)) {
    return p;
}

fn Elems(comptime P: type) type {
    const ptr = @typeInfo(P).pointer;
    const elem = @typeInfo(ptr.child).array.child;
    return if (ptr.attrs.@"const") []const elem else []elem;
}

/// `s[i]` for a string or slice: the element at `i`, with `s` evaluated
/// once; panics when out of range.
pub fn at(items: anytype, i: anytype) std.meta.Elem(@TypeOf(items)) {
    return items[index(i, items.len)];
}

/// `s[i] = x` through a `![]T`: the slot at `i`, with `s` evaluated
/// once; panics when out of range. Read-only for a read-only slice.
pub fn elemPtr(items: anytype, i: anytype) @TypeOf(&items[0]) {
    return &items[index(i, items.len)];
}

/// Which of an index's tests the compiler proved already passed
/// (docs/INTERNALS.md, "Proven checks"): `lower` is `0 <= i`, `upper` is
/// `i + width <= len`, and `both` is both. A proven test is not made,
/// except as an assertion of the proof when `verify_proofs` is on; the
/// other is made as `index` makes it, with the same panic.
pub const Proven = enum { lower, upper, both };

/// Proven tests are asserted in every debug build, and in an optimized
/// build whose root module asks for it (`RIG_VERIFY_PROOFS=1`).
const verify_proofs = builtin.optimize == .debug or (@hasDecl(root, "__rig_verify_proofs") and root.__rig_verify_proofs);

fn proofPanic() noreturn {
    @panic("rig: a proven check failed (compiler bug)");
}

/// `i` as the start of `width` elements within `count`, or null when a
/// test `p` does not prove fails. A proven test is made only as an
/// assertion (`verify_proofs`).
inline fn provenOffset(i: Int, count: usize, width: usize, comptime p: Proven) ?usize {
    @setRuntimeSafety(false);
    if (i < 0) {
        if (p == .upper) return null;
        if (verify_proofs) proofPanic();
    }
    // `0 <= i` here, so the conversion is exact.
    const u: u64 = @intCast(i);
    if (u > count or count - u < width) {
        if (p == .lower) return null;
        if (verify_proofs) proofPanic();
    }
    return @intCast(u);
}

/// `s[i]` with the tests `p` proves omitted: the element is read through
/// the slice's pointer, which carries no test of its own.
pub inline fn atProven(items: anytype, i: Int, comptime p: Proven) std.meta.Elem(@TypeOf(items)) {
    return items.ptr[provenOffset(i, items.len, 1, p) orelse indexPanic()];
}

/// `elemPtr` with the tests `p` proves omitted.
pub inline fn elemPtrProven(items: anytype, i: Int, comptime p: Proven) @TypeOf(&items[0]) {
    return &items.ptr[provenOffset(i, items.len, 1, p) orelse indexPanic()];
}

/// `a + b` that the compiler proved cannot overflow: an add LLVM may
/// assume does not wrap.
pub inline fn addProven(a: Int, b: Int) Int {
    if (verify_proofs) _ = std.math.add(Int, a, b) catch proofPanic();
    @setRuntimeSafety(false);
    return a + b;
}

// Checked lane arithmetic. Zig's own `a + b` on an integer vector tests
// the overflow bits of `@addWithOverflow(a, b)`, and LLVM miscompiles
// those bits on aarch64 when the vector is 32 or 64 lanes of bytes and
// both the flags and the result are used: a sum with no overflow in any
// lane reports one (`@reduce(.Or, flags)` is true), so a correct program
// panics. The helpers below never ask for the intrinsic: they compute the
// wrapped result and find an overflowing lane with lane comparisons, then
// panic as a scalar overflow does. Lanes follow the scalar rule in every
// mode: the checks are there in debug and safe builds, and `--release=fast`
// (no runtime safety) drops them, so each helper is the plain operator
// and an overflowing lane is undefined behavior, as a scalar's is.

/// Whether lane arithmetic checks for overflow: when runtime safety is on.
const lane_checks = builtin.optimize.runtimeSafety();

noinline fn laneOverflow() noreturn {
    @branchHint(.cold);
    panic.integerOverflow();
}

inline fn laneUnsigned(comptime V: type) bool {
    return @typeInfo(@typeInfo(V).vector.child).int.signedness == .unsigned;
}

inline fn laneZero(comptime V: type) V {
    return @splat(0);
}

/// Panics unless no lane of `bad` is set.
inline fn laneCheck(bad: anytype) void {
    if (@reduce(.Or, bad)) laneOverflow();
}

/// `a + b` lane by lane: the sum wrapped, overflow where an unsigned
/// sum is below an addend or a signed sum has the sign of neither.
pub inline fn vecAdd(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return addLanes(lane_checks, a, b);
}

inline fn addLanes(comptime checked: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (comptime !checked) return a + b;
    const V = @TypeOf(a);
    const r = a +% b;
    laneCheck(if (comptime laneUnsigned(V)) r < a else ((a ^ r) & (b ^ r)) < laneZero(V));
    return r;
}

/// `a - b` lane by lane: the difference wrapped, overflow where an
/// unsigned `a` is below `b` or a signed difference has the sign of
/// neither `a` nor the negation of `b`.
pub inline fn vecSub(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return subLanes(lane_checks, a, b);
}

inline fn subLanes(comptime checked: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (comptime !checked) return a - b;
    const V = @TypeOf(a);
    const r = a -% b;
    laneCheck(if (comptime laneUnsigned(V)) a < b else ((a ^ b) & (a ^ r)) < laneZero(V));
    return r;
}

/// `a * b` lane by lane: the product wrapped, overflow where it differs
/// from the product taken in lanes twice as wide. A 64-bit lane has no
/// wider vector lane, so each is tested as a scalar.
pub inline fn vecMul(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return mulLanes(lane_checks, a, b);
}

inline fn mulLanes(comptime checked: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (comptime !checked) return a * b;
    const V = @TypeOf(a);
    const info = @typeInfo(V).vector;
    const r = a *% b;
    if (comptime @bitSizeOf(info.child) >= 64) {
        const xs: [info.len]info.child = a;
        const ys: [info.len]info.child = b;
        for (xs, ys) |x, y| if (@mulWithOverflow(x, y)[1] != 0) laneOverflow();
    } else {
        const W = @Vector(info.len, @Int(@typeInfo(info.child).int.signedness, @bitSizeOf(info.child) * 2));
        const wide = @as(W, @intCast(a)) *% @as(W, @intCast(b));
        laneCheck(wide != @as(W, @intCast(r)));
    }
    return r;
}

/// `-a` lane by lane (signed lanes): overflow where a lane is the least
/// value of its type.
pub inline fn vecNeg(a: anytype) @TypeOf(a) {
    return negLanes(lane_checks, a);
}

inline fn negLanes(comptime checked: bool, a: anytype) @TypeOf(a) {
    if (comptime !checked) return -a;
    const V = @TypeOf(a);
    laneCheck(a == @as(V, @splat(std.math.minInt(@typeInfo(V).vector.child))));
    return laneZero(V) -% a;
}

/// `s[lo..hi]` of a string, slice, or array pointer: the elements from
/// `lo` up to `hi` (`null`: the end); panics unless `0 <= lo <= hi <= len`.
pub fn slice(items: anytype, lo: anytype, hi: anytype) []const std.meta.Elem(@TypeOf(items)) {
    const b = bounds(items.len, lo, hi);
    return items[b[0]..b[1]];
}

/// `!xs[lo..hi]`: `slice`, writable.
pub fn sliceMut(items: anytype, lo: anytype, hi: anytype) []std.meta.Elem(@TypeOf(items)) {
    const b = bounds(items.len, lo, hi);
    return items[b[0]..b[1]];
}

/// `!dst.copy(src)`: panics unless the lengths are equal. Safe code
/// cannot pass overlapping slices (the write view excludes the read).
pub fn copy(dst: anytype, src: []const std.meta.Elem(@TypeOf(dst))) void {
    if (dst.len != src.len) @panic("copy between slices of different lengths");
    @memcpy(dst, src);
}

/// `!s.fill(v)`: every element becomes `v`.
pub fn fill(dst: anytype, value: std.meta.Elem(@TypeOf(dst))) void {
    @memset(dst, value);
}

/// `!s.swap(i, j)`: panics unless both indexes are in range.
pub fn swap(items: anytype, i: anytype, j: anytype) void {
    const a = index(i, items.len);
    const b = index(j, items.len);
    std.mem.swap(std.meta.Elem(@TypeOf(items)), &items[a], &items[b]);
}

/// Rig's `Endian`: the byte order of `read` and `write`.
pub const Endian = enum { little, big };

/// Rig's `Arch`: the target's processor architecture, Zig's own enum.
pub const Arch = std.Target.Cpu.Arch;

/// `bytes.read[T, e](at)`: the integer or float `T` stored in the
/// `@sizeOf(T)` bytes from `at`, in byte order `e`; panics unless they
/// are all in range.
pub fn readInt(comptime T: type, bytes: anytype, offset: anytype, comptime endian: Endian) T {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, offset, n) orelse bytesPanic("read", n, offset, bytes.len);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    // One load of the `n` bytes, however wide, whatever the target's
    // native integer width (an integer array load is split into bytes
    // where the integer is not native).
    const lanes: @Vector(n, u8) = bytes[i..][0..n].*;
    const raw: Bits = @bitCast(lanes);
    return @bitCast(if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(raw) else raw);
}

/// `!bytes.write[T, e](at, value)`: store `value` in the `@sizeOf(T)`
/// bytes from `at`, in byte order `e`; panics unless they are all in
/// range.
pub fn writeInt(comptime T: type, bytes: anytype, offset: anytype, value: T, comptime endian: Endian) void {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, offset, n) orelse bytesPanic("write", n, offset, bytes.len);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const raw: Bits = @bitCast(value);
    const ordered = if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(raw) else raw;
    // One store of the whole integer, through an unaligned pointer: a
    // vector store would be scalarized to byte stores where vectors
    // are not native.
    const dst: *align(1) Bits = @ptrCast(bytes[i..][0..n]);
    dst.* = ordered;
}

/// `bytes.read[Simd[T, n], e](at)`: the `n` lanes of type `T` held in the
/// bytes from `at`, each in byte order `e`; panics unless they are all in
/// range. One check, then one unaligned load of exactly the bytes read.
pub fn simdRead(comptime V: type, bytes: anytype, offset: anytype, comptime endian: Endian) V {
    const n = comptime vectorBytes(V);
    const i = byteOffset(bytes.len, offset, n) orelse bytesPanic("read", n, offset, bytes.len);
    return simdLoad(V, bytes[i..][0..n], endian);
}

/// `simdRead` with the tests `p` proves omitted; an unproven one panics as
/// `simdRead`'s does.
pub fn simdReadProven(comptime V: type, bytes: anytype, offset: Int, comptime endian: Endian, comptime p: Proven) V {
    const n = comptime vectorBytes(V);
    const i = provenOffset(offset, bytes.len, n, p) orelse bytesPanic("read", n, offset, bytes.len);
    return simdLoad(V, @ptrCast(bytes.ptr + i), endian);
}

/// The bytes a vector `V` is read from or written to: its lanes' sizes,
/// with no padding.
fn vectorBytes(comptime V: type) usize {
    return @sizeOf([@typeInfo(V).vector.len]@typeInfo(V).vector.child);
}

/// The lanes of `V` held in the bytes at `src`, each in byte order `endian`.
inline fn simdLoad(comptime V: type, src: *const [vectorBytes(V)]u8, comptime endian: Endian) V {
    const n = comptime vectorBytes(V);
    // The bytes are loaded as an array of exactly `n`, then become the
    // vector: a load through a vector pointer may touch the vector's whole
    // register (Zig's own x86 backend loads 16 bytes for a 4-byte vector),
    // past the bytes it was given. LLVM makes this one unaligned load.
    if (comptime smallVector(n)) {
        // A vector of 1, 2, 4 or 8 bytes is one integer of that width:
        // one scalar load, where a byte-array to byte-vector cast is
        // lowered lane by lane on aarch64.
        const Bits = @Int(.unsigned, n * 8);
        const word: *align(1) const Bits = @ptrCast(src);
        return lanesInOrder(@as(V, @bitCast(word.*)), endian);
    }
    if (comptime wideVector(V, n)) {
        // A whole-register vector: a load through an unaligned vector
        // pointer touches exactly its `n` bytes, and lowers to the
        // target's own vector loads (the array copy of 64 bytes is
        // spilled and rebuilt byte by byte on x86).
        const vec: *align(1) const V = @ptrCast(src);
        return lanesInOrder(vec.*, endian);
    }
    const raw: [n]u8 = src.*;
    return lanesInOrder(@as(V, @bitCast(raw)), endian);
}

/// Whether the vector `V` of `n` bytes is whole registers with no padding,
/// so an unaligned vector access touches exactly its `n` bytes.
fn wideVector(comptime V: type, comptime n: usize) bool {
    return n >= 16 and @sizeOf(V) == n;
}

/// Whether `n` bytes fit one scalar register access: 1, 2, 4 or 8.
fn smallVector(comptime n: usize) bool {
    return n == 1 or n == 2 or n == 4 or n == 8;
}

/// `!bytes.write[Simd[T, n], e](at, v)`: store the lanes of `v` in the
/// bytes from `at`, each in byte order `e`; panics unless they are all in
/// range. One check, then one unaligned store.
pub fn simdWrite(comptime V: type, bytes: anytype, offset: anytype, value: V, comptime endian: Endian) void {
    const n = comptime vectorBytes(V);
    const i = byteOffset(bytes.len, offset, n) orelse bytesPanic("write", n, offset, bytes.len);
    simdStore(V, bytes[i..][0..n], value, endian);
}

/// `simdWrite` with the tests `p` proves omitted; an unproven one panics
/// as `simdWrite`'s does.
pub fn simdWriteProven(comptime V: type, bytes: anytype, offset: Int, value: V, comptime endian: Endian, comptime p: Proven) void {
    const n = comptime vectorBytes(V);
    const i = provenOffset(offset, bytes.len, n, p) orelse bytesPanic("write", n, offset, bytes.len);
    simdStore(V, @ptrCast(bytes.ptr + i), value, endian);
}

/// Store the lanes of `value` in the bytes at `dst`, as `simdLoad` loads
/// them: exactly `n` bytes.
inline fn simdStore(comptime V: type, dst: *[vectorBytes(V)]u8, value: V, comptime endian: Endian) void {
    const n = comptime vectorBytes(V);
    if (comptime smallVector(n)) {
        const Bits = @Int(.unsigned, n * 8);
        const word: *align(1) Bits = @ptrCast(dst);
        word.* = @bitCast(lanesInOrder(value, endian));
        return;
    }
    if (comptime wideVector(V, n)) {
        const vec: *align(1) V = @ptrCast(dst);
        vec.* = lanesInOrder(value, endian);
        return;
    }
    dst.* = @bitCast(lanesInOrder(value, endian));
}

/// `v` with each lane's bytes in the native order where `endian` is not
/// it: the same swap reads and writes. One-byte lanes have no order.
fn lanesInOrder(v: anytype, comptime endian: Endian) @TypeOf(v) {
    const V = @TypeOf(v);
    const T = @typeInfo(V).vector.child;
    if (comptime @sizeOf(T) == 1 or zigEndian(endian) == builtin.cpu.arch.endian()) return v;
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const n = @typeInfo(V).vector.len;
    return @bitCast(@byteSwap(@as(@Vector(n, Bits), @bitCast(v))));
}

/// `v[i]`: lane `i` of a vector, with `i` checked as an index is.
pub fn lane(v: anytype, i: anytype) LaneOf(@TypeOf(v)) {
    const lanes = vectorArray(v);
    return lanes[index(i, lanes.len)];
}

/// `v.with(i, x)`: a copy of `v` whose lane `i` is `x`, with `i` checked
/// as an index is.
pub fn withLane(v: anytype, i: anytype, x: LaneOf(@TypeOf(v))) @TypeOf(v) {
    var lanes = vectorArray(v);
    lanes[index(i, lanes.len)] = x;
    if (comptime isWideMask(@TypeOf(v))) return maskOf(@TypeOf(v), lanes);
    return lanes;
}

/// The type of a lane of `V`, a vector or a mask.
fn LaneOf(comptime V: type) type {
    return if (isWideMask(V)) bool else @typeInfo(V).vector.child;
}

/// The lanes of `v`, a vector or a mask, as an array.
inline fn vectorArray(v: anytype) [vectorLen(@TypeOf(v))]LaneOf(@TypeOf(v)) {
    return if (comptime isWideMask(@TypeOf(v))) maskArray(v) else v;
}

fn vectorLen(comptime V: type) comptime_int {
    return if (isWideMask(V)) V.__rig_mask else @typeInfo(V).vector.len;
}

/// `a +| b` and `a -| b` of integer vectors: each lane stops at its
/// type's limits. LLVM's own saturating operators (`uqadd`, `psubusb`,
/// `i8x16.sub_sat_u`) where it builds the code; elsewhere the wrapped
/// result, corrected where a lane overflowed. Zig's own x86 backend (a
/// debug build) gives wrong lanes for `I32` vectors of 8 or more on a CPU
/// without AVX (`test/lanes/simd2_grid.zig`).
pub inline fn vecAddSat(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime builtin.zig_backend == .stage2_llvm) a +| b else addSatWrapped(a, b);
}

pub inline fn vecSubSat(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime builtin.zig_backend == .stage2_llvm) a -| b else subSatWrapped(a, b);
}

inline fn addSatWrapped(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const V = @TypeOf(a);
    const r = a +% b;
    if (comptime laneSigned(V)) {
        const over = ((a ^ r) & (b ^ r)) < laneSplat(V, 0);
        return @select(laneChild(V), over, @select(laneChild(V), a < laneSplat(V, 0), laneSplat(V, laneMin(V)), laneSplat(V, laneMax(V))), r);
    }
    return @select(laneChild(V), r < a, laneSplat(V, laneMax(V)), r);
}

inline fn subSatWrapped(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const V = @TypeOf(a);
    const r = a -% b;
    if (comptime laneSigned(V)) {
        const over = ((a ^ b) & (a ^ r)) < laneSplat(V, 0);
        return @select(laneChild(V), over, @select(laneChild(V), a < laneSplat(V, 0), laneSplat(V, laneMin(V)), laneSplat(V, laneMax(V))), r);
    }
    return @select(laneChild(V), a < b, laneSplat(V, 0), r);
}

fn laneChild(comptime V: type) type {
    return @typeInfo(V).vector.child;
}

fn laneSigned(comptime V: type) bool {
    return @typeInfo(laneChild(V)).int.signedness == .signed;
}

fn laneMin(comptime V: type) laneChild(V) {
    return std.math.minInt(laneChild(V));
}

fn laneMax(comptime V: type) laneChild(V) {
    return std.math.maxInt(laneChild(V));
}

inline fn laneSplat(comptime V: type, x: laneChild(V)) V {
    return @splat(x);
}

/// `v << c`, `v <<% c`, and `v >> c` of a vector of integers: every lane
/// shifted by the one amount `c`, which must be below the lane width (a
/// cast that panics otherwise, as for a scalar). `<<` panics where a lane
/// loses bits or its sign, found by shifting back (`(r >> c) != v`): no
/// overflow intrinsic, and a vector known at compile time still panics
/// when the program runs rather than stopping the build. With runtime
/// safety off (`--release=fast`) it is `<<%`, as a scalar `<<` is the plain
/// shift there.
pub inline fn vecShl(v: anytype, amount: anytype) @TypeOf(v) {
    return laneShift(if (lane_checks) .left_checked else .left, v, amount);
}

pub inline fn vecShlWrap(v: anytype, amount: anytype) @TypeOf(v) {
    return laneShift(.left, v, amount);
}

pub inline fn vecShr(v: anytype, amount: anytype) @TypeOf(v) {
    return laneShift(.right, v, amount);
}

const Shift = enum { left, left_checked, right };

/// A shift of every lane of `v` by `amount`. On WASM SIMD a vector of
/// less than 16 bytes is shifted as the low lanes of a 16-byte one: LLVM
/// (Zig 0.17) gives wrong lanes for `>>` of a `Simd[U8, 2]` or
/// `Simd[U8, 4]` there in an optimized build (`test/lanes/simd2_grid.zig`).
inline fn laneShift(comptime op: Shift, v: anytype, amount: anytype) @TypeOf(v) {
    const V = @TypeOf(v);
    const info = @typeInfo(V).vector;
    if (comptime wasmSimd() and @sizeOf([info.len]info.child) < 16) {
        const m = 16 / @sizeOf(info.child);
        const wide = @shuffle(info.child, v, @as(V, @splat(0)), padIndicesTo(m, info.len));
        return @shuffle(info.child, laneShiftWhole(op, wide, amount), undefined, iota(info.len, 0));
    }
    return laneShiftWhole(op, v, amount);
}

inline fn laneShiftWhole(comptime op: Shift, v: anytype, amount: anytype) @TypeOf(v) {
    const k = laneAmount(@TypeOf(v), amount);
    if (op == .right) return v >> k;
    const r = v << k;
    if (op == .left_checked and @reduce(.Or, (r >> k) != v)) panic.shlOverflow();
    return r;
}

/// A shift amount for every lane of `V`, in the width Zig shifts by.
inline fn laneAmount(comptime V: type, amount: anytype) @Vector(@typeInfo(V).vector.len, std.math.Log2Int(@typeInfo(V).vector.child)) {
    return @splat(@intCast(amount));
}

/// `cur.lag[k](prev)`: lane `i` is `cur[i - k]` for `i >= k`, and
/// `prev[n - k + i]` below: the lanes of `prev` then `cur`, `k` lanes
/// back from the end. One constant two-vector shuffle, which LLVM lowers
/// to `ext` on NEON, `palignr` on x86 (with a lane-crossing permute for
/// AVX2's 32 bytes), and `i8x16.shuffle` on WASM. Typecheck holds `k` to
/// 1..n-1.
pub inline fn lag(comptime k: usize, cur: anytype, prev: @TypeOf(cur)) @TypeOf(cur) {
    if (comptime isWideMask(@TypeOf(cur))) return .{ .bytes = lag(k, cur.bytes, prev.bytes) };
    const info = @typeInfo(@TypeOf(cur)).vector;
    return @shuffle(info.child, prev, cur, lagIndices(info.len, k));
}

fn lagIndices(comptime n: usize, comptime k: usize) @Vector(n, i32) {
    @setEvalBranchQuota(100_000);
    var a: [n]i32 = undefined;
    for (&a, 0..) |*x, i| x.* = if (i < k) @intCast(n - k + i) else ~@as(i32, @intCast(i - k));
    return a;
}

/// `t.lookup(idx)` of a table `t` of 16, 32, or 64 bytes: lane `i` is
/// `t[idx[i]]`, or 0 where `idx[i]` is past the table. Each target's
/// table instruction takes 16 indexes at a time (a shorter `idx` is
/// filled out with indexes past the table, and a longer one taken in
/// pieces): NEON's `tbl` takes 1 to 4 table registers and gives 0 past
/// them. x86's `pshufb` (SSSE3; `vpshufb`, 32 indexes against a table
/// repeated in both halves, with AVX2) and WASM's `i8x16.swizzle` read one
/// 16-byte table piece, so each piece is looked up with the indexes moved
/// down to it, and the results OR together. `pshufb` reads only an
/// index's low 4 bits unless its bit 7 is set, which gives 0: a saturating
/// add of 0x70 sets bit 7 exactly where an index is 16 or more. Elsewhere,
/// and at compile time, a lane at a time (`lookupLanes`); every form gives
/// the same lanes (`test "lookup: every form agrees"`).
pub inline fn lookup(table: anytype, idx: anytype) @TypeOf(idx) {
    const n = @typeInfo(@TypeOf(idx)).vector.len;
    if (@inComptime() or comptime !lookupInstructions()) return lookupLanes(table, idx);
    if (comptime n >= 16) return lookupPieces(table, idx);
    const wide = @shuffle(u8, idx, @as(@Vector(16, u8), @splat(0xFF)), padIndices(n));
    return @shuffle(u8, lookupPieces(table, wide), undefined, iota(n, 0));
}

/// `lookup` of 16 or more indexes, a target's table instructions at a time.
/// Vectors are cut into pieces and joined again by shuffles: through an
/// array, LLVM moves each 8 bytes at a time.
inline fn lookupPieces(table: anytype, idx: anytype) @TypeOf(idx) {
    const m = @typeInfo(@TypeOf(table)).vector.len;
    const n = @typeInfo(@TypeOf(idx)).vector.len;
    var ts: [m / 16]@Vector(16, u8) = undefined;
    inline for (&ts, 0..) |*t, j| t.* = @shuffle(u8, table, undefined, iota(16, 16 * j));
    const w = if (avx2 and n >= 32) 32 else 16;
    const W = @Vector(w, u8);
    var out: [n / w]W = undefined;
    inline for (&out, 0..) |*o, k| {
        const piece: W = @shuffle(u8, idx, undefined, iota(w, w * k));
        if (w == 32) {
            var r: W = @splat(0);
            inline for (ts, 0..) |t, j| {
                const both = @shuffle(u8, t, undefined, iota(32, 0) & @as(@Vector(32, i32), @splat(15)));
                r |= @"llvm.x86.avx2.pshuf.b"(both, (piece -% @as(W, @splat(16 * j))) +| @as(W, @splat(0x70)));
            }
            o.* = r;
        } else o.* = lookup16(m, ts, piece);
    }
    return joinPieces(w, n, out);
}

/// The `n / w` pieces of `w` bytes as one vector of `n`, by halves.
inline fn joinPieces(comptime w: usize, comptime n: usize, pieces: [n / w]@Vector(w, u8)) @Vector(n, u8) {
    if (n == w) return pieces[0];
    const h = n / 2;
    const lo = joinPieces(w, h, pieces[0 .. h / w].*);
    const hi = joinPieces(w, h, pieces[h / w ..].*);
    return @shuffle(u8, lo, hi, concatIndices(h));
}

/// The lanes of `a` then of `b`, each of `h` lanes.
fn concatIndices(comptime h: usize) @Vector(2 * h, i32) {
    var a: [2 * h]i32 = undefined;
    for (&a, 0..) |*x, i| x.* = if (i < h) @intCast(i) else ~@as(i32, @intCast(i - h));
    return a;
}

/// One 16-index piece of `lookup`.
inline fn lookup16(comptime m: usize, ts: [m / 16]@Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    const P = @Vector(16, u8);
    if (comptime neonIntrinsics()) return switch (m) {
        16 => @"llvm.aarch64.neon.tbl1.v16i8"(ts[0], idx),
        32 => @"llvm.aarch64.neon.tbl2.v16i8"(ts[0], ts[1], idx),
        else => @"llvm.aarch64.neon.tbl4.v16i8"(ts[0], ts[1], ts[2], ts[3], idx),
    };
    var r: P = @splat(0);
    inline for (ts, 0..) |t, j| {
        const down = idx -% @as(P, @splat(16 * j));
        r |= if (comptime wasmSimd()) @"llvm.wasm.swizzle"(t, down) else @"llvm.x86.ssse3.pshuf.b.128"(t, down +| @as(P, @splat(0x70)));
    }
    return r;
}

/// Whether the target has a table instruction `lookup` uses: NEON, x86's
/// SSSE3, or WASM SIMD, each through LLVM.
fn lookupInstructions() bool {
    return lookup_instructions;
}

const lookup_instructions = builtin.zig_backend == .stage2_llvm and (neon_intrinsics or wasm_simd or
    (builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3)));
const avx2 = builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// `lookup` a lane at a time.
fn lookupLanes(table: anytype, idx: anytype) @TypeOf(idx) {
    const m = @typeInfo(@TypeOf(table)).vector.len;
    const n = @typeInfo(@TypeOf(idx)).vector.len;
    const t: [m]u8 = table;
    const is: [n]u8 = idx;
    var out: [n]u8 = undefined;
    for (is, &out) |j, *o| o.* = if (j < m) t[j] else 0;
    return out;
}

/// Lanes `0..n` of a vector, then 16 - n lanes of the second operand's.
fn padIndices(comptime n: usize) @Vector(16, i32) {
    return padIndicesTo(16, n);
}

/// Lanes `0..n` of a vector, then `m - n` lanes of the second operand's
/// (its first lane, for an operand of every lane alike).
fn padIndicesTo(comptime m: usize, comptime n: usize) @Vector(m, i32) {
    var a: [m]i32 = undefined;
    for (&a, 0..) |*x, i| x.* = if (i < n) @intCast(i) else -1;
    return a;
}

/// The table instructions, each named only where `lookupInstructions`
/// picks it.
extern fn @"llvm.aarch64.neon.tbl1.v16i8"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.aarch64.neon.tbl2.v16i8"(@Vector(16, u8), @Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.aarch64.neon.tbl4.v16i8"(@Vector(16, u8), @Vector(16, u8), @Vector(16, u8), @Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.x86.ssse3.pshuf.b.128"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.x86.avx2.pshuf.b"(@Vector(32, u8), @Vector(32, u8)) @Vector(32, u8);
extern fn @"llvm.wasm.swizzle"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);

/// The Zig type of `Simd[Bool, n]`: a vector of `bool` up to 16 lanes, and
/// a `WideMask` above that. LLVM keeps a `@Vector(n, bool)` of more lanes
/// than one vector register holds in vector registers only within a basic
/// block: where it lives across blocks (a mask built up by a loop, an
/// argument or result of a call that is not inlined) it is taken apart into one general
/// register per lane, on NEON, SSE, AVX2 at 64 lanes, and WASM SIMD alike, which made a
/// 32-lane scan about 20 times slower than a 16-lane one. Bytes stay in
/// vector registers everywhere, and a comparison gives them with no work.
pub fn Mask(comptime n: comptime_int) type {
    return if (n > 16) WideMask(n) else @Vector(n, bool);
}

/// A mask of more than 16 lanes: one byte per lane, 0xFF where the lane is
/// true and 0 where it is false, always one or the other. A distinct type, so that
/// it prints and is named as a mask, not as the bytes that hold it.
pub fn WideMask(comptime n: comptime_int) type {
    return struct {
        bytes: @Vector(n, u8),
        pub const __rig_mask = n;
    };
}

fn isWideMask(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "__rig_mask");
}

/// The lane count of `M`, a mask of either form.
fn maskLen(comptime M: type) comptime_int {
    return if (isWideMask(M)) M.__rig_mask else @typeInfo(M).vector.len;
}

/// `a op b` that compares two vectors other than masks: their lanes'
/// results as a mask.
pub inline fn mask(lanes: anytype) Mask(@typeInfo(@TypeOf(lanes)).vector.len) {
    const n = @typeInfo(@TypeOf(lanes)).vector.len;
    if (comptime n <= 16) return lanes;
    return .{ .bytes = @select(u8, lanes, @as(@Vector(n, u8), @splat(0xFF)), @as(@Vector(n, u8), @splat(0))) };
}

/// The mask of type `M` whose lanes are `lanes`: `Simd[Bool, n](a)`, a
/// `splat`, or a `Bool` beside a mask.
pub inline fn maskOf(comptime M: type, lanes: @Vector(maskLen(M), bool)) M {
    return mask(lanes);
}

/// The lanes of mask `m` as a vector of `bool`, for an operation that
/// reads them where they are used.
inline fn maskLanes(m: anytype) @Vector(maskLen(@TypeOf(m)), bool) {
    const n = maskLen(@TypeOf(m));
    if (comptime !isWideMask(@TypeOf(m))) return m;
    return @as(@Vector(n, i8), @bitCast(m.bytes)) < @as(@Vector(n, i8), @splat(0));
}

/// `m.array()`: the lanes of mask `m` as a `[n]Bool`.
pub inline fn maskArray(m: anytype) [maskLen(@TypeOf(m))]bool {
    return maskLanes(m);
}

/// `a & b`, `a | b`, and `a ^ b` of two masks, and `a == b` and `a != b`,
/// which compare them lane by lane; `m.not()`. On a wide mask's bytes, `&`
/// and `|` are the lanes' minimum and maximum, which are the same for 0
/// and 0xFF: LLVM turns `|` and `&` of the bytes of comparisons back into
/// `<n x i1>` selects, which NEON then widens to bytes again with a shift
/// and a compare per 16 lanes (`shl`, `cmlt`), where `umax` and `umin` stay
/// bytes.
pub inline fn maskAnd(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime isWideMask(@TypeOf(a))) .{ .bytes = @min(a.bytes, b.bytes) } else a & b;
}

pub inline fn maskOr(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime isWideMask(@TypeOf(a))) .{ .bytes = @max(a.bytes, b.bytes) } else a | b;
}

pub inline fn maskXor(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime isWideMask(@TypeOf(a))) .{ .bytes = a.bytes ^ b.bytes } else a ^ b;
}

pub inline fn maskEq(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime isWideMask(@TypeOf(a))) .{ .bytes = ~(a.bytes ^ b.bytes) } else a == b;
}

pub inline fn maskNe(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return maskXor(a, b);
}

pub inline fn maskNot(m: anytype) @TypeOf(m) {
    return if (comptime isWideMask(@TypeOf(m))) .{ .bytes = ~m.bytes } else !m;
}

/// `m.select(a, b)`: lane `i` of `a` where lane `i` of `m` is true, and of
/// `b` where it is false; `a` and `b` may be masks.
pub inline fn maskSelect(m: anytype, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const pick = maskLanes(m);
    if (comptime isWideMask(@TypeOf(a))) return .{ .bytes = @select(u8, pick, a.bytes, b.bytes) };
    return @select(@typeInfo(@TypeOf(a)).vector.child, pick, a, b);
}

/// The mask helpers (`maskBits`, `maskFirst`, `maskAny`, `maskAll`, and the
/// functions they call) are `inline`: called, a wide mask is moved through
/// its lanes one by one (about 56 moves per 32 bytes on aarch64), where
/// inline LLVM keeps it in vector registers. They hold no checked
/// arithmetic, so a mask known at compile time gives the same answer
/// (`test "mask helpers: a mask known at compile time"`).
///
/// `m.bits()`: bit `i` is lane `i` of mask `m`, the higher bits 0. Each
/// target gets the fastest form measured for it (docs/INTERNALS.md,
/// "Vectors"): NEON's pairwise-add reduction for 32 and 64 lanes, 16-lane
/// bitmasks on WASM SIMD for more than 16 (a wider mask would be taken
/// apart lane by lane), a multiply that gathers eight lanes at a time on
/// WASM without SIMD, and Zig's own `@bitCast` elsewhere (one `pmovmskb`
/// per 16 lanes on x86, one `i8x16.bitmask` on WASM SIMD), a piece at a
/// time held opaque for more than 16 lanes (`maskBitsOpaque`). Every form
/// gives the same bits (`test "maskBits: every form agrees"`).
pub inline fn maskBits(m: anytype) u64 {
    const n = maskLen(@TypeOf(m));
    if (comptime (n == 32 or n == 64) and neonIntrinsics()) return maskBitsNeon(n, maskBytes(m));
    if (comptime n > 16 and wasmSimd()) return maskBitsPieces(n, maskBytes(m));
    if (comptime n >= 8 and builtin.cpu.arch.isWasm() and !wasmSimd()) return maskBitsSwar(n, maskBytes(m));
    if (comptime n > 16 and opaque_wide_bits) return maskBitsOpaque(n, maskBytes(m));
    // `@bitCast` of a mask gives wrong bits on aarch64 without NEON (Zig
    // 0.17); Rig builds no such target, so it takes this form too.
    return maskBitsCast(n, maskLanes(m));
}

/// `m.not().bits()`: the bits of `m` flipped, the higher bits 0. Flipped
/// lanes cost more on NEON: LLVM turns the `not` of comparisons ORed
/// together into a flipped comparison each (`cmeq` and `mvn`, then `bic`),
/// a vector instruction more per 16 lanes, where this flips one register.
pub inline fn maskBitsNot(m: anytype) u64 {
    const n = maskLen(@TypeOf(m));
    return ~maskBits(m) & std.math.maxInt(@Int(.unsigned, n));
}

/// `m.first()`: the index of the first true lane of mask `m`, or null.
/// One vector-to-register crossing decides it on NEON for 16 lanes or
/// more (`nibbleMask`; a wider mask tests the OR of its pieces with `umaxv`, and locates the
/// piece only when a lane is true); elsewhere `bits()` is already one
/// bitmask, whose lowest set bit is the lane.
pub inline fn maskFirst(m: anytype) ?i64 {
    const n = maskLen(@TypeOf(m));
    if (comptime n >= 16 and std.math.isPowerOfTwo(n) and neonIntrinsics()) {
        const bytes = maskBytes(m);
        if (comptime n == 16) {
            const found = nibbleMask(bytes);
            if (found == 0) return null;
            return @as(i64, @ctz(found) >> 2);
        }
        const pieces: [n / 16]@Vector(16, u8) = @bitCast(bytes);
        if (@"llvm.aarch64.neon.umaxv.i32.v16i8"(foldBytes(n, bytes, false)) == 0) return null;
        inline for (pieces, 0..) |piece, k| {
            const found = nibbleMask(piece);
            if (found != 0) return @as(i64, k * 16) + @as(i64, @ctz(found) >> 2);
        }
        unreachable;
    }
    const bits = maskBits(m);
    if (bits == 0) return null;
    return @ctz(bits);
}

/// A 16-byte mask (0xFF or 0 per byte) as 4 bits per byte in a `u64`,
/// lane `i` at bits `4i..4i+3`: a narrowing shift right by 4 (`shrn`)
/// and one `fmov`.
inline fn nibbleMask(bytes: @Vector(16, u8)) u64 {
    const wide: @Vector(8, u16) = @bitCast(bytes);
    const narrow: @Vector(8, u8) = @truncate(wide >> @as(@Vector(8, u4), @splat(4)));
    return @bitCast(narrow);
}

/// The OR (or AND) of the 16-byte pieces of `w`, a power of two bytes of 16
/// or more, by halving shuffles: an
/// OR over the pieces as an array makes LLVM move them through general
/// registers.
inline fn foldBytes(comptime n: usize, w: @Vector(n, u8), comptime and_: bool) @Vector(16, u8) {
    comptime std.debug.assert(n >= 16 and std.math.isPowerOfTwo(n));
    if (n == 16) return w;
    const h = n / 2;
    const lo = @shuffle(u8, w, undefined, iota(h, 0));
    const hi = @shuffle(u8, w, undefined, iota(h, h));
    return foldBytes(h, if (and_) lo & hi else lo | hi, and_);
}

/// The indices `from`, `from + 1`, ... of a shuffle mask.
fn iota(comptime n: usize, comptime from: i32) @Vector(n, i32) {
    // A mask known at compile time makes the caller's whole body run at
    // compile time, with these loops counted against its one quota.
    @setEvalBranchQuota(100_000);
    var a: [n]i32 = undefined;
    for (&a, 0..) |*x, j| x.* = from + @as(i32, @intCast(j));
    return a;
}

/// `m.any()`: whether any lane of mask `m` is true.
pub inline fn maskAny(m: anytype) bool {
    const n = maskLen(@TypeOf(m));
    // WASM SIMD reduces a mask of more than 16 lanes lane by lane; its
    // pieces OR into one, which `v128.any_true` tests.
    if (comptime wasmSimd() and n > 16 and n & (n - 1) == 0) return @reduce(.Or, foldBytes(n, maskBytes(m), false) >= @as(@Vector(16, u8), @splat(0x80)));
    if (comptime n > 16 and wasmSimd()) return maskBitsPieces(n, maskBytes(m)) != 0;
    // On NEON, the pieces OR into one, whose largest byte (`umaxv`) is
    // the answer; spelled as a reduction, LLVM turns it back into a
    // bitmask in a loop.
    if (comptime n >= 16 and std.math.isPowerOfTwo(n) and neonIntrinsics()) {
        return @"llvm.aarch64.neon.umaxv.i32.v16i8"(foldBytes(n, maskBytes(m), false)) != 0;
    }
    return @reduce(.Or, maskLanes(m));
}

/// `m.all()`: whether every lane of mask `m` is true.
pub inline fn maskAll(m: anytype) bool {
    const n = maskLen(@TypeOf(m));
    if (comptime wasmSimd() and n > 16 and n & (n - 1) == 0) return @reduce(.And, foldBytes(n, maskBytes(m), true) >= @as(@Vector(16, u8), @splat(0x80)));
    if (comptime n > 16 and wasmSimd()) return maskBitsPieces(n, maskBytes(m)) == std.math.maxInt(@Int(.unsigned, n));
    if (comptime n >= 16 and std.math.isPowerOfTwo(n) and neonIntrinsics()) {
        return @"llvm.aarch64.neon.uminv.i32.v16i8"(foldBytes(n, maskBytes(m), true)) != 0;
    }
    return @reduce(.And, maskLanes(m));
}

/// NEON's across-lanes maximum and minimum of 16 bytes; named only where
/// `neonIntrinsics` holds.
extern fn @"llvm.aarch64.neon.umaxv.i32.v16i8"(@Vector(16, u8)) i32;
extern fn @"llvm.aarch64.neon.uminv.i32.v16i8"(@Vector(16, u8)) i32;

/// A mask's lanes as bytes, 0xFF for true and 0 for false.
inline fn maskBytes(m: anytype) @Vector(maskLen(@TypeOf(m)), u8) {
    const n = maskLen(@TypeOf(m));
    if (comptime isWideMask(@TypeOf(m))) return m.bytes;
    return @select(u8, m, @as(@Vector(n, u8), @splat(0xFF)), @as(@Vector(n, u8), @splat(0)));
}

/// Whether NEON's intrinsics may be named: an aarch64 target with NEON,
/// built by LLVM (Zig's own backends do not know them, and an intrinsic
/// for a feature the target lacks stops LLVM).
fn neonIntrinsics() bool {
    return neon_intrinsics;
}

/// Decided once: a feature test in an inline helper would count against
/// the branch quota of every function that calls it.
const neon_intrinsics = builtin.cpu.arch == .aarch64 and builtin.zig_backend == .stage2_llvm and
    std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon);

/// Whether the target is WASM with its 128-bit SIMD.
fn wasmSimd() bool {
    return wasm_simd;
}

const wasm_simd = builtin.cpu.arch.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .simd128);

inline fn maskBitsCast(comptime n: usize, m: @Vector(n, bool)) u64 {
    return @as(@Int(.unsigned, n), @bitCast(m));
}

/// Whether a mask of more than 16 lanes gives its bits by
/// `maskBitsOpaque`: x86-64 built by LLVM, without AVX-512BW, whose `k`
/// registers hold a mask of 64 lanes and take shifts with no lane moves.
const opaque_wide_bits = x86_llvm and !std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw);

/// A mask of more than 16 lanes as the bitmasks of its pieces of 16 lanes
/// (32 with AVX2), one `pmovmskb` each, whose bytes first pass through an
/// empty `asm` (`opaqueBytes`). LLVM reads the bits of a whole mask's
/// `@bitCast` as the vector of `bool` they came from, and may do later
/// work on them on its lanes: a classifier's checked `<<` of them became
/// a shuffle of the lanes, which x86 without AVX-512 does a lane at a time
/// (`pextrb` and `pinsrb`, or bytes through the stack). From bytes it
/// cannot see past, each piece's bits stay an integer; LLVM still leaves
/// out a piece whose bits go unused (`bits() & 0xFF` takes one `pmovmskb`)
/// and, on AVX2, ORs two masks' pieces before one `pmovmskb`
/// (`a.bits() | b.bits()`).
inline fn maskBitsOpaque(comptime n: usize, lanes: @Vector(n, u8)) u64 {
    const w = if (avx2 and n % 32 == 0) 32 else 16;
    const bytes: [n]u8 = lanes;
    var r: u64 = 0;
    inline for (0..n / w) |k| {
        const piece: @Vector(w, u8) = bytes[k * w ..][0..w].*;
        const held = if (@inComptime()) piece else opaqueBytes(piece);
        const bits: @Int(.unsigned, w) = @bitCast(held >= @as(@Vector(w, u8), @splat(0x80)));
        r |= @as(u64, bits) << (k * w);
    }
    return r;
}

/// `v` itself, through an empty `asm` that LLVM cannot see into, on x86-64
/// (`x` is an SSE or AVX register); elsewhere `v` as it is.
inline fn opaqueBytes(v: anytype) @TypeOf(v) {
    if (comptime !x86_llvm) return v;
    return asm (""
        : [out] "=x" (-> @TypeOf(v)),
        : [in] "0" (v),
    );
}

const x86_llvm = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm;

/// simdjson's reduction: each lane's bit weighted within its byte, then
/// pairwise adds (`addp`) fold 16 lanes into 2 bytes, 64 into 8.
inline fn maskBitsNeon(comptime n: usize, bytes: @Vector(n, u8)) u64 {
    const V = @Vector(16, u8);
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const eight = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };
    const weights: @Vector(n, u8) = comptime weightsOf(n, eight);
    // The pieces come from the mask as bytes, never through `[n]bool`,
    // which would take each lane apart; the result is read as a lane of
    // a wider vector, one `fmov`.
    const pieces: [n / 16]V = @bitCast(bytes & weights);
    if (n == 32) {
        const s1 = addp(pieces[0], pieces[1]);
        const s2 = addp(s1, s1);
        const s3 = addp(s2, s2);
        return @as(@Vector(4, u32), @bitCast(s3))[0];
    }
    const s1 = addp(pieces[0], pieces[1]);
    const s2 = addp(pieces[2], pieces[3]);
    const s3 = addp(s1, s2);
    const s4 = addp(s3, s3);
    return @as(@Vector(2, u64), @bitCast(s4))[0];
}

/// `eight` repeated to `n` bytes.
fn weightsOf(comptime n: usize, comptime eight: [8]u8) [n]u8 {
    var w: [n]u8 = undefined;
    for (&w, 0..) |*x, i| x.* = eight[i % 8];
    return w;
}

/// NEON's pairwise add of two 16-byte vectors; named only where
/// `neonIntrinsics` holds.
extern fn @"llvm.aarch64.neon.addp.v16i8"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);

/// A mask of more than 16 lanes as 16-lane bitmasks, one `i8x16.bitmask`
/// each on WASM SIMD.
inline fn maskBitsPieces(comptime n: usize, lanes: @Vector(n, u8)) u64 {
    const bytes: [n]u8 = lanes;
    var r: u64 = 0;
    inline for (0..n / 16) |k| {
        const piece: @Vector(16, u8) = bytes[k * 16 ..][0..16].*;
        r |= @as(u64, @as(u16, @bitCast(piece >= @as(@Vector(16, u8), @splat(0x80))))) << (k * 16);
    }
    return r;
}

/// A mask's lanes as bytes of 0 or 1, gathered eight at a time into the
/// top byte of one multiply: lane `i` of eight lands on bit `56 + i`, and
/// no two partial products meet.
inline fn maskBitsSwar(comptime n: usize, lanes: @Vector(n, u8)) u64 {
    const bytes: [n]u8 = lanes & @as(@Vector(n, u8), @splat(1));
    var r: u64 = 0;
    inline for (0..n / 8) |k| {
        const x = std.mem.readInt(u64, bytes[k * 8 ..][0..8], .little);
        r |= ((x *% 0x0102040810204080) >> 56) << (k * 8);
    }
    return r;
}

/// A `read` or `write` of `n` bytes at `offset` that runs past `count`
/// bytes, or starts before them.
fn bytesPanic(comptime what: []const u8, n: usize, offset: anytype, count: usize) noreturn {
    @branchHint(.cold);
    std.debug.panic("byte " ++ what ++ " out of range: {d} bytes at offset {d} of {d}", .{ n, offset, count });
}

/// `readInt` with the tests `p` proves omitted; an unproven one panics as
/// `readInt`'s does.
pub fn readIntProven(comptime T: type, bytes: anytype, offset: Int, comptime endian: Endian, comptime p: Proven) T {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = provenOffset(offset, bytes.len, n, p) orelse bytesPanic("read", n, offset, bytes.len);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const lanes: @Vector(n, u8) = @as(*const [n]u8, @ptrCast(bytes.ptr + i)).*;
    const raw: Bits = @bitCast(lanes);
    return @bitCast(if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(raw) else raw);
}

/// `writeInt` with the tests `p` proves omitted; an unproven one panics as
/// `writeInt`'s does.
pub fn writeIntProven(comptime T: type, bytes: anytype, offset: Int, value: T, comptime endian: Endian, comptime p: Proven) void {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = provenOffset(offset, bytes.len, n, p) orelse bytesPanic("write", n, offset, bytes.len);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const raw: Bits = @bitCast(value);
    const ordered = if (n > 1 and zigEndian(endian) != builtin.cpu.arch.endian()) @byteSwap(raw) else raw;
    const dst: *align(1) Bits = @ptrCast(bytes.ptr + i);
    dst.* = ordered;
}

/// `offset` as a `usize` with `offset + n <= count`, or null.
fn byteOffset(count: usize, offset: anytype, n: usize) ?usize {
    const i = std.math.cast(usize, offset) orelse return null;
    if (i > count or count - i < n) return null;
    return i;
}

fn zigEndian(comptime e: Endian) std.lang.Endian {
    return switch (e) {
        .little => .little,
        .big => .big,
    };
}

fn bounds(count: usize, lo: anytype, hi: anytype) [2]usize {
    const l = std.math.cast(usize, lo) orelse slicePanic();
    const h = if (@TypeOf(hi) == @TypeOf(null)) count else std.math.cast(usize, hi) orelse slicePanic();
    if (l > h or h > count) slicePanic();
    return .{ l, h };
}

fn slicePanic() noreturn {
    @panic("slice bounds out of range");
}

/// `a / b` on a type parameter's values: exact for floats, truncating
/// toward zero for integers.
pub fn div(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    return if (@typeInfo(T) == .float) @as(T, a) / @as(T, b) else @divTrunc(@as(T, a), @as(T, b));
}

/// `a % b`: the remainder with the dividend's sign, for integers and
/// floats. A signed integer's remainder by -1 is 0, `Int.min % -1`
/// included, where the machine's division would trap.
pub fn rem(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    switch (@typeInfo(T)) {
        .int => |int| if (int.signedness == .signed and b == -1) return 0,
        else => {},
    }
    return @rem(@as(T, a), @as(T, b));
}

/// The longest length a Rig `Int` holds: no target holds more, and the
/// margin above it lets the compiler prove `i + c` fits where `i` is
/// below a length (docs/INTERNALS.md, "Proven checks").
pub const max_len: u64 = (1 << 62) - 1;

/// A length or count as a Rig `Int`; panics above `max_len`, which a
/// 64-bit target tests with one compare and a 32-bit one never needs to.
pub fn len(n: usize) Int {
    if (@as(u64, n) > max_len) lenPanic();
    // Exact: `n <= max_len` here.
    return @bitCast(@as(u64, n));
}

/// Out of line and cold, so the test costs a caller's inlining one
/// compare and a branch.
noinline fn lenPanic() noreturn {
    @branchHint(.cold);
    @panic("length out of range");
}

fn indexPanic() noreturn {
    @panic("index out of bounds");
}

pub fn oom() noreturn {
    @panic("out of memory");
}

// -----------------------------------------------------------------------------
// Process support
// -----------------------------------------------------------------------------

// Allocation. Debug builds check for leaks: every allocation goes through
// `LeakChecker`, which records each live block's address and size (no
// stack traces, so it costs a hash-map update per allocation). At exit a
// leak is reported with its count and size, and a double or mismatched
// free panics. Built with `RIG_LEAK_TRACE=1`, the emitted root module
// declares `__rig_leak_trace`, and the checker sits on Zig's
// `SafeAllocator`, which prints the stack trace of every leaked
// allocation (and of double frees) at the cost of capturing one per
// allocation. Built with `RIG_SANITIZE=1`, the root module declares
// `__rig_sanitize`, and the checker sits on `Sanitizer`, which makes any
// use of freed memory crash where it happens (it takes precedence over
// `RIG_LEAK_TRACE`). Release builds allocate from `smp_allocator`
// directly.

const builtin = @import("builtin");
const root = @import("root");
const leak_checked = builtin.optimize == .debug;
const leak_trace = leak_checked and @hasDecl(root, "__rig_leak_trace") and root.__rig_leak_trace;
const sanitize = leak_checked and Sanitizer.supported and @hasDecl(root, "__rig_sanitize") and root.__rig_sanitize;

var trace_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
var sanitizer: Sanitizer = .{};
var leak_checker: LeakChecker = .{};

/// The allocator behind every runtime allocation.
pub fn defaultAllocator() std.mem.Allocator {
    return if (leak_checked) leak_checker.allocator() else std.heap.smp_allocator;
}

/// Tracks every live allocation by address. Its own table lives in
/// `smp_allocator`, outside the count.
const LeakChecker = struct {
    live: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    bytes: usize = 0,

    const table_allocator = std.heap.smp_allocator;

    fn backing() std.mem.Allocator {
        if (sanitize) return sanitizer.allocator();
        return if (leak_trace) trace_allocator.allocator() else std.heap.smp_allocator;
    }

    fn allocator(self: *LeakChecker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LeakChecker = @ptrCast(@alignCast(ctx));
        const ptr = backing().rawAlloc(n, alignment, ret_addr) orelse return null;
        self.live.put(table_allocator, @intFromPtr(ptr), n) catch oom();
        self.bytes += n;
        return ptr;
    }

    /// The recorded size of `memory`, which must be a live allocation.
    fn entry(self: *LeakChecker, memory: []u8) *usize {
        const size = self.live.getPtr(@intFromPtr(memory.ptr)) orelse
            @panic("rig: double free or free of memory that was never allocated");
        if (size.* != memory.len) @panic("rig: free with the wrong size");
        return size;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LeakChecker = @ptrCast(@alignCast(ctx));
        const size = self.entry(memory);
        if (!backing().rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.bytes = self.bytes - size.* + new_len;
        size.* = new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LeakChecker = @ptrCast(@alignCast(ctx));
        _ = self.entry(memory);
        const ptr = backing().rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.live.put(table_allocator, @intFromPtr(ptr), new_len) catch oom();
        self.bytes = self.bytes - memory.len + new_len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LeakChecker = @ptrCast(@alignCast(ctx));
        // Under RIG_LEAK_TRACE, let SafeAllocator report a bad free
        // with its stack traces first.
        if (leak_trace and !sanitize and !self.live.contains(@intFromPtr(memory.ptr))) backing().rawFree(memory, alignment, ret_addr);
        _ = self.entry(memory);
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.bytes -= memory.len;
        backing().rawFree(memory, alignment, ret_addr);
    }
};

/// Page-per-block allocation that turns every use of freed memory into a
/// crash at the access, in the manner of Electric Fence:
///
/// - each block gets pages of its own, carved from spans of address
///   space reserved inaccessible (`PROT_NONE`), and ends where they end,
///   so the next page, which stays inaccessible, catches a read or write
///   past its end;
/// - a free maps fresh inaccessible pages over the block's, which gives
///   the memory back and leaves the addresses reserved;
/// - addresses are never reused: blocks are carved in order, and a span
///   is never released.
///
/// A fault inside a span prints what was touched and then falls through
/// to Zig's own handler for the stack trace (`onFault`). Each block costs
/// two system calls and at least two pages of address space, one of them
/// resident while the block lives, so it is for test runs, not programs.
///
/// Each live block is a mapping of its own, and Linux allows a process
/// only so many (`vm.max_map_count`). Past `max_live` live blocks, or when
/// a block cannot be mapped, the sanitizer degrades rather than fail:
/// it says so once, and hands further blocks to `smp_allocator`, poisoning
/// each when it is freed. The leak checker above still sees every block.
const Sanitizer = struct {
    /// The rest of the newest span, where the next block goes.
    next: usize = 0,
    end: usize = 0,
    spans: [max_spans]usize = undefined,
    span_count: usize = 0,
    /// Guarded blocks live now, and how many may be.
    live: usize = 0,
    max_live: usize = default_max_live,
    /// The note that blocks are no longer guarded has been printed.
    noted: bool = false,

    const supported = builtin.target.os.tag == .macos or builtin.target.os.tag == .linux;
    /// Address space reserved at a time: 64 GiB, which holds a million
    /// blocks at the largest page size (16 KiB, plus a guard page).
    const span_size: usize = 64 << 30;
    const max_spans = 64;
    const none: std.posix.PROT = .{};
    const read_write: std.posix.PROT = .{ .READ = true, .WRITE = true };
    /// Where nothing smaller is known: a million blocks, 16 GiB of pages
    /// at 16 KiB each.
    const default_max_live: usize = 1 << 20;
    /// Mappings left for everything else in the process (its code, its
    /// stack, the allocator's own).
    const map_headroom: usize = 4096;
    const fallback = std.heap.smp_allocator;
    const freed_byte: u8 = 0xdd;

    fn allocator(self: *Sanitizer) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Set `max_live` when the program starts: `RIG_SANITIZE_BLOCKS` if
    /// set (which tests use to reach the limit), else on Linux half the
    /// mappings `vm.max_map_count` allows less some headroom, since a
    /// live block and the guard space after it may be two mappings.
    fn configure(self: *Sanitizer, environ: std.process.Environ) void {
        if (environ.getPosix("RIG_SANITIZE_BLOCKS")) |text| {
            if (std.fmt.parseInt(usize, text, 10)) |n| return self.setMaxLive(n) else |_| {}
        }
        if (builtin.target.os.tag != .linux) return;
        var buf: [32]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io(), "/proc/sys/vm/max_map_count", &buf) catch return;
        const maps = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch return;
        self.setMaxLive(if (maps > 2 * map_headroom) (maps - map_headroom) / 2 else maps / 4);
    }

    fn setMaxLive(self: *Sanitizer, n: usize) void {
        self.max_live = @min(n, default_max_live);
    }

    /// Hand blocks to `fallback` from now on, saying so once.
    fn degrade(self: *Sanitizer) void {
        self.max_live = self.live;
        if (self.noted) return;
        self.noted = true;
        const note = "rig: sanitizer: mapping limit reached; further allocations are not guarded\n";
        _ = std.posix.system.write(std.posix.STDERR_FILENO, note.ptr, note.len);
    }

    /// Map inaccessible pages at `addr` (a new span when null).
    fn mapNone(addr: ?usize, size: usize) ?usize {
        const hint: ?[*]align(std.heap.page_size_min) u8 = if (addr) |a| @ptrFromInt(a) else null;
        const got = std.posix.mmap(hint, size, none, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = addr != null }, -1, 0) catch return null;
        return @intFromPtr(got.ptr);
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Sanitizer = @ptrCast(@alignCast(ctx));
        if (self.live >= self.max_live) {
            self.degrade();
            return fallback.rawAlloc(n, alignment, ret_addr);
        }
        const page = std.heap.pageSize();
        const size = std.mem.alignForward(usize, @max(n, 1), page);
        const block_align = @max(alignment.toByteUnits(), page);
        var base = std.mem.alignForward(usize, self.next, block_align);
        // The block, then one guard page.
        if (self.next == 0 or base + size + page > self.end) {
            if (size + page + block_align > span_size) return null;
            if (self.span_count == max_spans) @panic("rig: sanitizer: address space exhausted");
            const span = mapNone(null, span_size) orelse return null;
            self.spans[self.span_count] = span;
            self.span_count += 1;
            self.end = span + span_size;
            base = std.mem.alignForward(usize, span, block_align);
        }
        if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(base), size, read_write)) != .SUCCESS) {
            self.degrade();
            return fallback.rawAlloc(n, alignment, ret_addr);
        }
        self.next = base + size + page;
        self.live += 1;
        return @ptrFromInt(alignment.backward(base + size - n));
    }

    /// Guarded blocks never grow or shrink in place: every size change
    /// moves the block, so the old addresses become inaccessible.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Sanitizer = @ptrCast(@alignCast(ctx));
        if (!self.owns(@intFromPtr(memory.ptr))) return fallback.rawResize(memory, alignment, new_len, ret_addr);
        return new_len == memory.len;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Sanitizer = @ptrCast(@alignCast(ctx));
        if (!self.owns(@intFromPtr(memory.ptr))) return fallback.rawRemap(memory, alignment, new_len, ret_addr);
        return null;
    }

    /// A guarded block's pages become inaccessible; if even that cannot
    /// be mapped, they are poisoned and left. An unguarded block is
    /// poisoned and freed.
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Sanitizer = @ptrCast(@alignCast(ctx));
        if (!self.owns(@intFromPtr(memory.ptr))) {
            @memset(memory, freed_byte);
            return fallback.rawFree(memory, alignment, ret_addr);
        }
        self.live -= 1;
        const page = std.heap.pageSize();
        const first = std.mem.alignBackward(usize, @intFromPtr(memory.ptr), page);
        const stop = std.mem.alignForward(usize, @intFromPtr(memory.ptr) + @max(memory.len, 1), page);
        if (mapNone(first, stop - first) != null) return;
        if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(first), stop - first, none)) == .SUCCESS) return;
        @memset(memory, freed_byte);
    }

    /// Whether `addr` lies in address space the sanitizer reserved.
    fn owns(self: *const Sanitizer, addr: usize) bool {
        for (self.spans[0..self.span_count]) |span| if (addr >= span and addr - span < span_size) return true;
        return false;
    }

    // The fault handler. It runs before Zig's, which it restores and
    // returns to: the access runs again and faults into Zig's handler,
    // which prints the stack trace.

    var previous: [2]std.posix.Sigaction = undefined;
    const signals = [2]std.posix.SIG{ .SEGV, .BUS };

    /// Called by `start` in a program built with `RIG_SANITIZE=1`.
    fn installHandler() void {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = onFault },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
        };
        for (signals, &previous) |sig, *old| std.posix.sigaction(sig, &act, old);
    }

    fn onFault(_: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
        for (signals, &previous) |sig, *old| std.posix.sigaction(sig, old, null);
        const addr = faultAddress(info);
        if (!sanitizer.owns(addr)) return;
        flush();
        var buf: [256]u8 = undefined;
        const msg = if (sanitizer.blockBefore(addr)) |b|
            std.mem.print(&buf, "error: rig: access past the end of a {d}-byte block at 0x{x} (address 0x{x})\n", .{ b.len, b.start, addr })
        else
            std.mem.print(&buf, "error: rig: use of freed memory at address 0x{x}\n", .{addr});
        const text = msg catch return;
        _ = std.posix.system.write(std.posix.STDERR_FILENO, text.ptr, text.len);
    }

    /// The live block whose guard page holds `addr`, if any.
    fn blockBefore(_: *const Sanitizer, addr: usize) ?struct { start: usize, len: usize } {
        const page = std.heap.pageSize();
        var it = leak_checker.live.iterator();
        while (it.next()) |e| {
            const stop = e.key_ptr.* + e.value_ptr.*;
            const guard = std.mem.alignForward(usize, stop, page);
            if (addr >= stop and addr < guard + page) return .{ .start = e.key_ptr.*, .len = e.value_ptr.* };
        }
        return null;
    }
};

/// Live allocations and their total size (Debug builds; zero otherwise).
const Usage = struct { count: usize, bytes: usize };

fn usage() Usage {
    return .{ .count = leak_checker.live.count(), .bytes = leak_checker.bytes };
}

/// Report the allocations live now beyond `before`; true when there are any.
fn reportLeaks(before: Usage) bool {
    if (!leak_checked) return false;
    const now = usage();
    if (now.count <= before.count) return false;
    const n = now.count - before.count;
    std.debug.print("error: rig: memory leak detected: {d} allocation{s} ({d} bytes) never freed\n", .{
        n, if (n == 1) "" else "s", now.bytes -| before.bytes,
    });
    if (!leak_trace) std.debug.print("note: build with RIG_LEAK_TRACE=1 set (`RIG_LEAK_TRACE=1 rig run ...`) to see where each was allocated\n", .{});
    return true;
}

// The stack. Rig's code runs on a stack the runtime maps itself, over a
// guard of inaccessible address space, so a program that runs out of
// stack by a frame no larger than the guard faults in the guard before it
// writes anywhere else (docs/INTERNALS.md, "The program's stack").

/// The stack `main` and the tests run on: 64 MiB, four times the 16 MiB
/// Zig gives the main thread, for deep recursion; a frame keeps at most
/// 13 MiB of values (`checkFrames` in the compiler).
const stack_size: usize = 64 << 20;

/// The inaccessible address space below the stack, the largest that can
/// be reserved first: a frame no larger than it that overflows the stack
/// makes its first access past it here. The compiler holds a frame's
/// reach to half the last (`max_frame_reach`), a measured bound.
const guard_sizes = [_]usize{ 64 << 30, 1 << 30 };

/// Whether `onOwnStack` switches to a stack of its own: on macOS and
/// Linux, on aarch64 and x86_64. Elsewhere code runs on the thread's
/// own stack.
const own_stack = (builtin.target.os.tag == .macos or builtin.target.os.tag == .linux) and
    (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .x86_64);

/// Bytes left unused at the stack's top, above the first frame, for a
/// stack trace's walk to read. On macOS, Zig's reader of a frame's
/// compact unwind entry (the FRAME case of `unwindFrameInner` in
/// `std/debug/SelfInfo/MachO.zig`, to recheck at each Zig upgrade)
/// reads the saved pairs of x19..x28 upward from 8 below the frame
/// pointer, though they lie below it: up to 56 bytes above the stack
/// pointer the frame started from. Without this room the walk would
/// read past the top of the first frame on this stack, into the page
/// above, which faults while a panic prints its trace.
const unwind_headroom: usize = 256;

comptime {
    // Room for five pairs read from 8 below a frame pointer that is 16
    // below where the frame started, and the stack pointer kept aligned.
    std.debug.assert(unwind_headroom >= 64 and unwind_headroom % 16 == 0);
}

/// The guard below the stack, once it is mapped: an access in it is a
/// stack overflow.
var stack_guard: struct { lo: usize = 0, hi: usize = 0 } = .{};

/// Map the stack, read-write, above its guard and below one inaccessible
/// page, so a read past its top faults whatever else is mapped; the
/// stack's top, or null when not even the smallest guard can be
/// reserved.
fn mapStack() ?usize {
    for (guard_sizes) |size| {
        const got = std.posix.mmap(null, size + stack_size + std.heap.pageSize(), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch continue;
        const base = @intFromPtr(got.ptr);
        if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(base + size), stack_size, .{ .READ = true, .WRITE = true })) != .SUCCESS) {
            std.posix.munmap(got);
            continue;
        }
        stack_guard = .{ .lo = base, .hi = base + size };
        return base + size + stack_size;
    }
    return null;
}

/// `f(args...)` on the stack the runtime maps: called by the emitted
/// `main` with the program's `main`, and by `runTests`. A program whose
/// stack and guard cannot be mapped stops before it runs.
pub fn onOwnStack(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    if (!own_stack) return @call(.auto, f, args);
    const top = mapStack() orelse {
        std.debug.print("rig: cannot reserve the program's stack and the guard below it\n", .{});
        std.process.exit(1);
    };
    // A fault runs its handler on the thread's alternate signal stack,
    // which Zig's start code sets; a child process forked on macOS has
    // none until it is set again.
    if (builtin.link_libc) _ = std.c.pthread_atfork(null, null, attachSignalStack);
    installOverflowHandler();
    const Call = struct {
        args: @TypeOf(args),
        result: @typeInfo(@TypeOf(f)).@"fn".return_type.? = undefined,

        fn run(p: *anyopaque) callconv(.c) void {
            const call: *@This() = @ptrCast(@alignCast(p));
            call.result = @call(.auto, f, call.args);
        }
    };
    var call: Call = .{ .args = args };
    switchStack(&call, &Call.run, top - unwind_headroom);
    return call.result;
}

fn attachSignalStack() callconv(.c) void {
    std.Thread.maybeAttachSignalStack();
}

/// Call `run(arg)` with the stack pointer at `top`, and return with it
/// where it was. The frame record it pushes links the new stack's frames
/// to the caller's, for stack traces. Zig calls no naked function
/// directly, and its body follows the C calling convention, so it is
/// called through a pointer (`switchStack`).
fn switchStackNaked() callconv(.naked) void {
    // The unwind rules, where the build keeps any: the caller's frame
    // pointer and return address are saved below the old stack pointer.
    // Zig's own x86_64 assembler takes none of these but the one its
    // `_start` uses, which ends a stack trace here.
    const cfi = builtin.unwind_tables != .none or !builtin.strip_debug_info;
    const self_hosted = builtin.zig_backend == .stage2_x86_64;
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (if (cfi)
                \\ stp x29, x30, [sp, #-32]!
                \\ .cfi_def_cfa_offset 32
                \\ .cfi_offset w30, -24
                \\ .cfi_offset w29, -32
                \\ str x19, [sp, #16]
                \\ .cfi_offset w19, -16
                \\ mov x29, sp
                \\ .cfi_def_cfa w29, 32
                \\ mov x19, sp
                \\ mov sp, x2
                \\ blr x1
                \\ mov sp, x19
                \\ ldr x19, [sp, #16]
                \\ ldp x29, x30, [sp], #32
                \\ ret
            else
                \\ stp x29, x30, [sp, #-32]!
                \\ str x19, [sp, #16]
                \\ mov x29, sp
                \\ mov x19, sp
                \\ mov sp, x2
                \\ blr x1
                \\ mov sp, x19
                \\ ldr x19, [sp, #16]
                \\ ldp x29, x30, [sp], #32
                \\ ret
        ),
        .x86_64 => asm volatile (if (cfi and self_hosted)
                \\ .cfi_undefined %%rip
                \\ push %%rbp
                \\ mov %%rsp, %%rbp
                \\ push %%rbx
                \\ mov %%rsp, %%rbx
                \\ mov %%rdx, %%rsp
                \\ call *%%rsi
                \\ mov %%rbx, %%rsp
                \\ pop %%rbx
                \\ pop %%rbp
                \\ ret
            else if (cfi)
                \\ push %%rbp
                \\ .cfi_def_cfa_offset 16
                \\ .cfi_offset %%rbp, -16
                \\ mov %%rsp, %%rbp
                \\ .cfi_def_cfa_register %%rbp
                \\ push %%rbx
                \\ .cfi_offset %%rbx, -24
                \\ mov %%rsp, %%rbx
                \\ mov %%rdx, %%rsp
                \\ call *%%rsi
                \\ mov %%rbx, %%rsp
                \\ pop %%rbx
                \\ pop %%rbp
                \\ ret
            else
                \\ push %%rbp
                \\ mov %%rsp, %%rbp
                \\ push %%rbx
                \\ mov %%rsp, %%rbx
                \\ mov %%rdx, %%rsp
                \\ call *%%rsi
                \\ mov %%rbx, %%rsp
                \\ pop %%rbx
                \\ pop %%rbp
                \\ ret
        ),
        else => unreachable,
    }
}

const SwitchStack = *const fn (arg: *anyopaque, run: *const fn (*anyopaque) callconv(.c) void, top: usize) callconv(.c) void;

/// `switchStackNaked` as a function to call. The empty `asm` hides which
/// function the pointer names, so no optimizer inlines the naked body,
/// which takes its arguments in registers only a call sets.
fn switchStack(arg: *anyopaque, run: *const fn (*anyopaque) callconv(.c) void, top: usize) void {
    var f: SwitchStack = @ptrCast(&switchStackNaked);
    asm volatile (""
        : [f] "+r" (f),
    );
    f(arg, run, top);
}

// The overflow handler. Like the sanitizer's, it restores the handlers
// it replaced and returns: the access runs again and faults into Zig's
// handler, which prints the stack trace. Where Zig installs none, it
// aborts.

var overflow_previous: [2]std.posix.Sigaction = undefined;

fn installOverflowHandler() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = onOverflow },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
    };
    for (Sanitizer.signals, &overflow_previous) |sig, *old| std.posix.sigaction(sig, &act, old);
}

fn onOverflow(_: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    for (Sanitizer.signals, &overflow_previous) |sig, *old| std.posix.sigaction(sig, old, null);
    const addr = faultAddress(info);
    if (addr < stack_guard.lo or addr >= stack_guard.hi) return;
    flush();
    const msg = "error: rig: stack overflow\n";
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
    // Where Zig installs no handler (`--release=fast`), the fault again
    // would end the program by the signal; it aborts as a panic does.
    if (!std.options.enable_segfault_handler) std.process.abort();
}

/// The address whose access raised the fault `info` describes.
fn faultAddress(info: *const std.posix.siginfo_t) usize {
    return switch (builtin.target.os.tag) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        else => @intFromPtr(info.addr),
    };
}

/// What the process started with, which Zig hands only to `main`:
/// the arguments and environment, for the standard library.
pub var process: ?std.process.Init.Minimal = null;
var process_args: []const []const u8 = &.{};

/// Called first in the program's `main` and in `rig test`'s: store what the process started with. The arguments are
/// gathered into `Static`s once, freed by `finish`.
pub fn start(init: std.process.Init.Minimal) void {
    process = init;
    // RIG_NO_CRASH_REPORT=1, set by a test harness for a program that
    // panics on purpose: macOS files no crash report when it dies, and
    // Linux passes it to no crash handler (apport). It still dies by its
    // signal, its report on stderr unchanged.
    if (builtin.os.tag.isDarwin() or builtin.os.tag == .linux) {
        if (init.environ.getPosix("RIG_NO_CRASH_REPORT")) |v| {
            if (std.mem.eql(u8, v, "1")) noCrashReport();
        }
    }
    // Only a program `rig run` or `rig test` builds declares
    // `__rig_run_started`, the environment variable that names a file to
    // create as it starts: their evidence that the exit status is the
    // program's. A program `rig build` makes has no such hook.
    if (@hasDecl(root, "__rig_run_started")) {
        if (init.environ.getPosix(root.__rig_run_started)) |path| {
            if (std.Io.Dir.cwd().createFile(io(), path, .{})) |file| file.close(io()) else |_| {}
        }
    }
    if (sanitize) {
        sanitizer.configure(init.environ);
        Sanitizer.installHandler();
    }
    if (@TypeOf(init.args.vector) != []const [*:0]const u8) return;
    const list = defaultAllocator().alloc([]const u8, init.args.vector.len) catch oom();
    for (list, init.args.vector) |*arg, c| arg.* = std.mem.sliceTo(c, 0);
    process_args = list;
}

extern "c" var mach_task_self_: c_uint;
extern "c" fn task_set_exception_ports(task: c_uint, mask: c_uint, port: c_uint, behavior: c_int, flavor: c_int) c_int;

/// No crash report for this process's death. macOS: no handler for its
/// crash exceptions (EXC_MASK_CRASH and EXC_MASK_CORPSE_NOTIFY to
/// MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE), so ReportCrash
/// never hears of it. Linux: a core limit of exactly 1, at which the
/// kernel starts no `core_pattern` pipe (apport) and writes no core: each
/// crash otherwise waits seconds on the handler. The processes it starts
/// inherit it.
fn noCrashReport() void {
    if (builtin.os.tag == .linux) {
        std.posix.setrlimit(.CORE, .{ .cur = 1, .max = 1 }) catch {};
        return;
    }
    const exc_mask_crash: c_uint = 1 << 10;
    const exc_mask_corpse_notify: c_uint = 1 << 13;
    const exception_default: c_int = 1;
    const thread_state_none: c_int = if (builtin.cpu.arch == .x86_64) 13 else 5;
    _ = task_set_exception_ports(mach_task_self_, exc_mask_crash | exc_mask_corpse_notify, 0, exception_default, thread_state_none);
}

/// Free what `start` gathered, at the end of the program or its tests.
fn releaseProcess() void {
    defaultAllocator().free(process_args);
    process_args = &.{};
}

/// The program's arguments, its name first; they live as long as the
/// process.
pub fn processArgs() []const []const u8 {
    return process_args;
}

/// The `std.Io` the runtime and the standard library's Zig files do
/// their I/O through: synchronous, on the calling thread.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `fun main() -> Int`: its result, which `finish` has already run after,
/// as the process's exit status.
pub fn exitStatus(n: Int) u8 {
    return std.math.cast(u8, n) orelse std.debug.panic("exit status {d} is not in 0..255", .{n});
}

/// Deferred first in the emitted `main`, so it runs after all of `main`'s
/// drops: flush `print` output, then exit non-zero if anything leaked, so
/// a leaking program never passes.
pub fn finish() void {
    releaseProcess();
    flush();
    if (!reportLeaks(.{ .count = 0, .bytes = 0 })) return;
    if (leak_trace) _ = trace_allocator.deinit();
    std.process.exit(1);
}

/// A failure that left `main`, after its drops and `finish`: report the
/// error as a Rig program shows it and exit 1.
pub fn failMain(err: anyerror) noreturn {
    flush();
    std.debug.print("error: {s}\n", .{errorShown(err)});
    std.process.exit(1);
}

// Output. `print` writes to one process-wide buffer, flushed when the
// program finishes, before a panic message, and after every `print`
// when stdout is a terminal.

var stdout_buffer: [8192]u8 = undefined;
var stdout_writer: ?std.Io.File.Writer = null;
var stdout_is_tty = false;

fn stdout() *std.Io.Writer {
    if (stdout_writer == null) {
        const file = std.Io.File.stdout();
        stdout_is_tty = file.isTty(io()) catch false;
        stdout_writer = file.writerStreaming(io(), &stdout_buffer);
    }
    return &stdout_writer.?.interface;
}

/// Write out everything `print` has buffered.
fn flush() void {
    if (stdout_writer) |*w| w.interface.flush() catch {};
}

/// One `print`: its pieces in order, the spaces between its arguments and
/// the newline that ends them included, as the emitter lists them
/// (`.{ "n =", " ", n, "\n" }`). The tuple holds every argument's value,
/// so all of them have run before a byte is written. Inlined, it is a
/// straight line: each run of text (`piecesOf`) copied into the buffer
/// at once, each value written by its writer (`outValue`).
pub inline fn print(pieces: anytype) void {
    const plan = comptime piecesOf(@TypeOf(pieces));
    comptime std.debug.assert(plan.len > 0 and plan[plan.len - 1] == .text);
    inline for (plan, 0..) |p, i| switch (p) {
        .text => |t| outText(t, i == plan.len - 1),
        .value => |f| outValue(pieces[f]),
    };
}

/// What one piece of `print`, `String(...)`, or `add` writes: text known
/// at compile time, or the value of the tuple's field at this index.
const Piece = union(enum) { text: []const u8, value: usize };

/// The pieces of the tuple type `P`, in order, with each run of text
/// joined into one. A field known at compile time whose bytes are too
/// (a string literal, an Int, a Bool) is text, written as `writeValue`
/// writes it at the top level.
fn piecesOf(comptime P: type) []const Piece {
    comptime {
        const s = @typeInfo(P).@"struct";
        const n = s.field_types.len;
        @setEvalBranchQuota(1000 + 20 * n);
        var texts: [n]?[]const u8 = undefined;
        for (s.field_types, s.field_attrs, &texts) |T, a, *t| {
            t.* = if (a.@"comptime") constantText(T, a.defaultValue(T).?) else null;
        }
        var out: [n]Piece = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < n) : (count += 1) {
            if (texts[i] == null) {
                out[count] = .{ .value = i };
                i += 1;
                continue;
            }
            const first = i;
            var bytes: usize = 0;
            while (i < n and texts[i] != null) : (i += 1) bytes += texts[i].?.len;
            out[count] = .{ .text = joined(bytes, texts[first..i]) };
        }
        const done = out[0..count].*;
        return &done;
    }
}

/// `parts` joined, `bytes` long in all.
fn joined(comptime bytes: usize, comptime parts: []const ?[]const u8) []const u8 {
    comptime {
        var buf: [bytes]u8 = undefined;
        var end: usize = 0;
        for (parts) |p| {
            @memcpy(buf[end..][0..p.?.len], p.?);
            end += p.?.len;
        }
        const done = buf;
        return &done;
    }
}

/// The bytes `writeValue` writes for `v` at the top level, when they are
/// known at compile time.
fn constantText(comptime T: type, comptime v: T) ?[]const u8 {
    if (comptime isStringView(T)) return v;
    return switch (@typeInfo(T)) {
        .int, .comptime_int => std.fmt.comptimePrint("{d}", .{v}),
        .bool => if (v) "true" else "false",
        else => null,
    };
}

/// The one place a failed write to stdout lands. It is ignored.
fn outFailed(err: std.Io.Writer.Error) void {
    switch (err) {
        error.WriteFailed => {},
    }
}

/// Text of a `print`, known at compile time, written by the one writer
/// of its length (`outFixed`).
inline fn outText(comptime text: []const u8, comptime ends_line: bool) void {
    outFixed(text.len, ends_line, text[0..text.len]);
}

/// Text of `n` bytes: copied into the buffer when it fits, and otherwise
/// written by `outBytes`. Text that ends a line goes through `outLine`
/// when stdout is a terminal.
noinline fn outFixed(comptime n: usize, comptime ends_line: bool, text: *const [n]u8) void {
    if (stdout_writer) |*sw| {
        const w = &sw.interface;
        if (!(ends_line and stdout_is_tty) and n <= w.buffer.len - w.end) {
            w.buffer[w.end..][0..n].* = text.*;
            w.end += n;
            return;
        }
    }
    if (ends_line) outLine(text) else outBytes(text);
}

/// Bytes of a `print`.
noinline fn outBytes(bytes: []const u8) void {
    stdout().writeAll(bytes) catch |err| outFailed(err);
}

/// The last text of a `print`, which ends its line: written, then
/// flushed when stdout is a terminal.
noinline fn outLine(text: []const u8) void {
    outBytes(text);
    if (stdout_is_tty) flush();
}

/// A value of a `print`, as Rig writes it at the top level: text as its
/// bytes, anything else by the one writer of its type.
inline fn outValue(value: anytype) void {
    if (comptime isStringView(@TypeOf(value))) return outBytes(value);
    if (comptime isStringPlace(@TypeOf(value))) return outBytes(value.list.items);
    outValueOf(value);
}

noinline fn outValueOf(value: anytype) void {
    writeValue(stdout(), value, true) catch |err| outFailed(err);
}

/// The root panic handler of every emitted program: buffered output
/// comes first, then the panic message and stack trace on stderr.
pub const panic = std.debug.FullPanic(panicAfterFlush);

var panicking = false;

fn panicAfterFlush(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (!panicking) {
        panicking = true;
        if (current_test) |t| stdout().print("FAIL  {f}: panicked\n", .{t}) catch {};
        flush();
    }
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

// Tests. `rig test` builds a driver whose `main` calls `runTests` with
// the `__rig_tests` table of every module. Each test runs in order; it
// fails when it returns an error or (in Debug builds) leaks. A panic
// ends the run, naming the test that panicked.

/// One `test "name"` block.
pub const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

/// The tests of one module; `module` is empty for the root module.
pub const TestModule = struct {
    module: []const u8,
    tests: []const Test,
};

const TestName = struct {
    module: []const u8,
    name: []const u8,

    pub fn format(self: TestName, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("test \"{f}\"", .{std.zig.fmtString(self.name)});
        if (self.module.len > 0) try w.print(" ({s})", .{self.module});
    }
};

var current_test: ?TestName = null;

/// Run every test, reporting each on stdout; exit 1 if any failed.
/// An error as a program shows it, `Set.name`: the emitter names each
/// error `Set.name`, or `module.Set.name` outside the root module.
pub fn errorShown(err: anyerror) []const u8 {
    const full = @errorName(err);
    const dot = std.mem.findScalarLast(u8, full, '.') orelse return full;
    const begin = if (std.mem.findScalarLast(u8, full[0..dot], '.')) |d| d + 1 else 0;
    return full[begin..];
}

pub fn runTests(modules: []const TestModule) void {
    onOwnStack(runTestsHere, .{modules});
}

fn runTestsHere(modules: []const TestModule) void {
    const w = stdout();
    var passed: usize = 0;
    var failed: usize = 0;
    for (modules) |m| for (m.tests) |t| {
        const name: TestName = .{ .module = m.module, .name = t.name };
        current_test = name;
        const before = usage();
        const result = t.func();
        current_test = null;
        flush();
        if (result) |_| {
            if (reportLeaks(before)) {
                w.print("FAIL  {f}: memory leak\n", .{name}) catch {};
                failed += 1;
            } else {
                w.print("ok    {f}\n", .{name}) catch {};
                passed += 1;
            }
        } else |err| {
            w.print("FAIL  {f}: {s}\n", .{ name, errorShown(err) }) catch {};
            failed += 1;
        }
        flush();
    };
    w.print("{d} passed, {d} failed\n", .{ passed, failed }) catch {};
    flush();
    releaseProcess();
    if (failed > 0) std.process.exit(1);
}

/// `?String`: a string literal (`*const [N:0]u8`) or a `?String` slice. An
/// array of bytes held by pointer is a list of numbers.
fn isStringView(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8 and a.sentinel_ptr != null,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// A String read where it is, by address (`*String`, `*const String`).
fn isStringPlace(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and p.child == String,
        else => false,
    };
}

/// The Rig name of a declared type: `main.Wrap(i64)` is `Wrap`.
fn rigTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const end = comptime std.mem.findScalar(u8, full, '(') orelse full.len;
    const begin = comptime if (std.mem.findScalarLast(u8, full[0..end], '.')) |d| d + 1 else 0;
    return rigName(full[begin..end]);
}

/// The Rig name of a Zig name the emitter wrote: a Rig name the emitted
/// Zig cannot keep (`std`, `rig`, `debug`) is spelled with a `'` suffix
/// (`rig.writeZigIdent` in the compiler), which no Rig name contains.
pub fn rigName(zig: []const u8) []const u8 {
    return if (zig.len > 1 and zig[zig.len - 1] == '\'') zig[0 .. zig.len - 1] else zig;
}

/// Values nested deeper than this print as `...`: a structure that
/// reaches itself through handles would otherwise print forever.
const max_print_depth = 64;
var print_depth: u32 = 0;

/// A value as Rig writes it: text as is at the top level and quoted
/// inside other values, a float with a decimal point, `none` for an
/// absent optional, `Name(field: v)` for a struct, `.variant` /
/// `.variant(field: v)` for an enum, and `[a, b]` for arrays and Lists. A
/// shared handle or a box prints its value, a function `<fun>`.
fn writeValue(w: *std.Io.Writer, value: anytype, top: bool) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isStringView(T)) {
        return if (top) w.writeAll(value) else w.print("\"{s}\"", .{value});
    }
    if (comptime isOptStruct(T)) return if (some(value)) |v| writeValue(w, v, top) else w.writeAll("none");
    switch (@typeInfo(T)) {
        .int, .comptime_int => return w.print("{d}", .{value}),
        .float, .comptime_float => {
            const f: f64 = value;
            // A NaN's sign bit differs by platform and means nothing.
            if (std.math.isNan(f)) return w.writeAll("nan");
            try w.print("{d}", .{value});
            if (std.math.isFinite(f) and f == @trunc(f)) try w.writeAll(".0");
            return;
        },
        .bool => return w.writeAll(if (value) "true" else "false"),
        .@"fn" => return w.writeAll("<fun>"),
        .@"struct" => {
            if (@hasDecl(T, "__rig_box")) return writeValue(w, value.value.*, top);
            if (@hasDecl(T, "__rig_string")) return writeValue(w, value.list.items, top);
            // A mask prints as the array of its lanes, as a vector does.
            if (@hasDecl(T, "__rig_mask")) return writeValue(w, maskArray(value), top);
        },
        .optional => return if (value) |v| writeValue(w, v, top) else w.writeAll("none"),
        .pointer => |p| {
            if (comptime isStrongHandle(T)) return writeValue(w, value.value, top);
            if (@typeInfo(p.child) == .@"fn") return w.writeAll("<fun>");
            if (p.size != .slice) return writeValue(w, value.*, top);
        },
        .@"enum" => return w.print(".{s}", .{rigName(@tagName(value))}),
        .error_set => return w.writeAll(errorShown(value)),
        else => {},
    }
    if (print_depth >= max_print_depth) return w.writeAll("...");
    print_depth += 1;
    defer print_depth -= 1;
    switch (@typeInfo(T)) {
        .pointer, .array => try writeList(w, value),
        // A vector prints as the array of its lanes.
        .vector => |v| try writeList(w, @as([v.len]v.child, value)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                try w.print(".{s}", .{rigName(@tagName(tag))});
                const P = @TypeOf(payload);
                if (P == void) return;
                try w.writeAll("(");
                try writeFields(w, payload);
                try w.writeAll(")");
            },
        },
        .@"struct" => {
            if (@hasDecl(T, "__rig_print")) return value.__rig_print(w);
            try w.print("{s}(", .{rigTypeName(T)});
            try writeFields(w, value);
            try w.writeAll(")");
        },
        else => try w.print("{any}", .{value}),
    }
}

fn writeFields(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: ", .{rigName(f)});
        try writeValue(w, @field(value, f), false);
    }
}

fn writeList(w: *std.Io.Writer, items: anytype) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |x, i| {
        if (i > 0) try w.writeAll(", ");
        try writeValue(w, x, false);
    }
    try w.writeAll("]");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

// The tests allocate through `defaultAllocator`, like emitted programs;
// `expectNoLeaks` checks that everything since `before` was freed.

fn expectNoLeaks(before: Usage) !void {
    try testing.expectEqual(before, usage());
}

const Counter = struct {
    drops: *usize,
    pub fn __rig_drop(self: *Counter) void {
        self.drops.* += 1;
    }
};

/// Records the order values are dropped in.
const Order = struct {
    log: *[16]u8,
    n: *usize,
    id: u8,
    pub fn __rig_drop(self: *Order) void {
        self.log[self.n.*] = self.id;
        self.n.* += 1;
    }
};

test "maskBits: every form agrees" {
    @setEvalBranchQuota(10_000);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    inline for (.{ 2, 4, 8, 16, 32, 64 }) |n| {
        for (0..200) |_| {
            var lanes: [n]bool = undefined;
            for (&lanes) |*l| l.* = r.boolean();
            const m: @Vector(n, bool) = lanes;
            const w = maskOf(Mask(n), lanes);
            const bytes = maskBytes(m);
            var want: u64 = 0;
            for (lanes, 0..) |l, i| want |= @as(u64, @intFromBool(l)) << @intCast(i);
            try testing.expectEqual(want, maskBitsCast(n, m));
            if (n >= 8) try testing.expectEqual(want, maskBitsSwar(n, bytes));
            if (n >= 16) try testing.expectEqual(want, maskBitsPieces(n, bytes));
            if (n > 16) try testing.expectEqual(want, maskBitsOpaque(n, bytes));
            if (comptime (n == 32 or n == 64) and neonIntrinsics()) try testing.expectEqual(want, maskBitsNeon(n, bytes));
            // A vector of `bool` and the mask of its lanes alike.
            inline for (.{ m, w }) |x| {
                try testing.expectEqual(want, maskBits(x));
                try testing.expectEqual(~want & std.math.maxInt(@Int(.unsigned, n)), maskBitsNot(x));
                try testing.expectEqual(want != 0, maskAny(x));
                try testing.expectEqual(if (want == 0) null else @as(?i64, @ctz(want)), maskFirst(x));
                try testing.expectEqual(want == std.math.maxInt(@Int(.unsigned, n)), maskAll(x));
                try testing.expectEqual(lanes, maskArray(x));
            }
        }
    }
}

/// An index for `lookup`'s tests: in the table, just past it, around
/// `pshufb`'s bit 7 and the saturating add of 0x70, or anything.
fn lookupIndex(r: std.Random, m: usize) u8 {
    const edges = [_]u8{ 0, 15, 16, 31, 32, 47, 48, 63, 64, 0x6F, 0x70, 0x7F, 0x80, 0x8F, 0x90, 0xEF, 0xF0, 0xFF };
    return switch (r.uintLessThan(u8, 4)) {
        0 => edges[r.uintLessThan(usize, edges.len)],
        1 => r.uintLessThan(u8, @intCast(m)),
        else => r.int(u8),
    };
}

test "lookup: every form agrees" {
    var prng = std.Random.DefaultPrng.init(0x7ab1e);
    const r = prng.random();
    inline for (.{ 16, 32, 64 }) |m| {
        inline for (.{ 2, 4, 8, 16, 32, 64 }) |n| {
            for (0..300) |_| {
                var t: [m]u8 = undefined;
                r.bytes(&t);
                var is: [n]u8 = undefined;
                for (&is) |*x| x.* = lookupIndex(r, m);
                var want: [n]u8 = undefined;
                for (is, &want) |j, *w| w.* = if (j < m) t[j] else 0;
                const table: @Vector(m, u8) = t;
                const idx: @Vector(n, u8) = is;
                try testing.expectEqual(want, @as([n]u8, lookup(table, idx)));
                try testing.expectEqual(want, @as([n]u8, lookupLanes(table, idx)));
            }
        }
    }
}

test "lookup: at compile time" {
    const t: @Vector(16, u8) = "0123456789abcdef".*;
    const idx: @Vector(4, u8) = .{ 0, 15, 16, 0x80 };
    const r = comptime lookup(t, idx);
    try testing.expectEqual([4]u8{ '0', 'f', 0, 0 }, @as([4]u8, r));
}

test "vecAddSat, vecSubSat: the wrapped forms agree with Zig's" {
    var prng = std.Random.DefaultPrng.init(0x5a7);
    const r = prng.random();
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
        inline for (.{ 2, 8, 16, 64 }) |n| {
            for (0..200) |_| {
                var xs: [n]T = undefined;
                var ys: [n]T = undefined;
                for (&xs, &ys) |*x, *y| {
                    x.* = r.int(T);
                    y.* = if (r.boolean()) r.int(T) else if (r.boolean()) 0 else std.math.minInt(T);
                }
                const add: [n]T = addSatWrapped(@as(@Vector(n, T), xs), @as(@Vector(n, T), ys));
                const sub: [n]T = subSatWrapped(@as(@Vector(n, T), xs), @as(@Vector(n, T), ys));
                for (xs, ys, add, sub) |x, y, s, d| {
                    try testing.expectEqual(x +| y, s);
                    try testing.expectEqual(x -| y, d);
                }
            }
        }
    }
}

test "lag: every amount and lane count" {
    inline for (.{ 2, 4, 8, 16, 32, 64 }) |n| {
        var p: [n]u16 = undefined;
        var c: [n]u16 = undefined;
        for (&p, &c, 0..) |*x, *y, i| {
            x.* = @intCast(i);
            y.* = @intCast(1000 + i);
        }
        inline for (1..n) |k| {
            const got: [n]u16 = lag(k, @as(@Vector(n, u16), c), @as(@Vector(n, u16), p));
            for (got, 0..) |g, i| try testing.expectEqual(if (i >= k) c[i - k] else p[n - k + i], g);
        }
    }
}

test "lane arithmetic: the unchecked form is the plain operator" {
    // `--release=fast` runs the unchecked form; an overflowing lane is
    // undefined there, so only lanes that do not overflow are run, and the
    // two forms must agree on them.
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
        const a: @Vector(8, T) = .{ 9, 10, 11, 12, 13, 14, 15, 9 };
        const b: @Vector(8, T) = .{ 8, 7, 6, 5, 4, 3, 2, 1 };
        try testing.expectEqual(@as([8]T, addLanes(true, a, b)), @as([8]T, addLanes(false, a, b)));
        try testing.expectEqual(@as([8]T, subLanes(true, a, b)), @as([8]T, subLanes(false, a, b)));
        try testing.expectEqual(@as([8]T, mulLanes(true, a, b)), @as([8]T, mulLanes(false, a, b)));
        if (@typeInfo(T).int.signedness == .signed)
            try testing.expectEqual(@as([8]T, negLanes(true, a)), @as([8]T, negLanes(false, a)));
    }
    // The public helpers choose the unchecked form exactly when runtime
    // safety is off, the rule a scalar follows.
    try testing.expectEqual(builtin.optimize.runtimeSafety(), lane_checks);
}

test "vecShl, vecShlWrap, vecShr: every lane type and amount" {
    var prng = std.Random.DefaultPrng.init(0x5417);
    const r = prng.random();
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
        inline for (.{ 2, 16, 32, 64 }) |n| {
            for (0..@bitSizeOf(T)) |c| {
                var xs: [n]T = undefined;
                for (&xs) |*x| x.* = if (r.boolean()) r.int(T) else @truncate(r.int(T) >> @intCast(r.uintLessThan(usize, @bitSizeOf(T))));
                const v: @Vector(n, T) = xs;
                const k: std.math.Log2Int(T) = @intCast(c);
                var lost = false;
                for (xs, @as([n]T, vecShlWrap(v, c)), @as([n]T, vecShr(v, c))) |x, wrapped, right| {
                    try testing.expectEqual(x << k, wrapped);
                    try testing.expectEqual(x >> k, right);
                    if ((x << k) >> k != x) lost = true;
                }
                if (!lost) try testing.expectEqual(@as([n]T, vecShlWrap(v, c)), @as([n]T, vecShl(v, c)));
            }
        }
    }
}

test "mask helpers: a mask known at compile time" {
    // Every helper below runs at compile time, against this one quota.
    @setEvalBranchQuota(10_000);
    inline for (.{ 8, 16, 32, 64 }) |n| {
        const none = maskOf(Mask(n), @splat(false));
        const all = maskOf(Mask(n), @splat(true));
        comptime var lanes: [n]bool = @splat(false);
        lanes[n - 1] = true;
        const one = maskOf(Mask(n), lanes);
        try testing.expectEqual(@as(?i64, null), maskFirst(none));
        try testing.expectEqual(@as(?i64, 0), maskFirst(all));
        try testing.expectEqual(@as(?i64, n - 1), maskFirst(one));
        try testing.expect(!maskAny(none) and maskAny(one) and maskAny(all));
        try testing.expect(!maskAll(none) and !maskAll(one) and maskAll(all));
        try testing.expectEqual(@as(u64, 0), maskBits(none));
        try testing.expectEqual(@as(u64, 1) << (n - 1), maskBits(one));
        try testing.expectEqual(@as(u64, std.math.maxInt(@Int(.unsigned, n))), maskBits(all));
        try testing.expectEqual(maskBits(none), maskBitsNot(all));
        try testing.expectEqual(~(@as(u64, 1) << (n - 1)) & std.math.maxInt(@Int(.unsigned, n)), maskBitsNot(one));
        // Evaluated by Zig at compile time, the pieces take no `asm`.
        if (n > 16) try testing.expectEqual(@as(u64, 1) << (n - 1), comptime blk: {
            var bytes: [n]u8 = @splat(0);
            bytes[n - 1] = 0xFF;
            break :blk maskBitsOpaque(n, bytes);
        });
    }
}

test "maskFirst: every lane, every run, every lane count" {
    inline for (.{ 2, 4, 8, 16, 32, 48, 64 }) |n| {
        const M = Mask(n);
        try testing.expectEqual(@as(?i64, null), maskFirst(maskOf(M, @splat(false))));
        for (0..n) |i| {
            var lanes: [n]bool = @splat(false);
            lanes[i] = true;
            try testing.expectEqual(@as(?i64, @intCast(i)), maskFirst(maskOf(M, lanes)));
            var run: [n]bool = @splat(false);
            for (i..n) |j| run[j] = true;
            try testing.expectEqual(@as(?i64, @intCast(i)), maskFirst(maskOf(M, run)));
            try testing.expectEqual(i == 0, maskAll(maskOf(M, run)));
            try testing.expect(maskAny(maskOf(M, lanes)));
            var hole: [n]bool = @splat(true);
            hole[i] = false;
            try testing.expect(!maskAll(maskOf(M, hole)));
        }
    }
}

test "mask operators: every lane count, against the lanes one by one" {
    var prng = std.Random.DefaultPrng.init(0x3a5c);
    const r = prng.random();
    inline for (.{ 2, 8, 16, 32, 48, 64 }) |n| {
        const M = Mask(n);
        for (0..100) |_| {
            var a: [n]bool = undefined;
            var b: [n]bool = undefined;
            var c: [n]u8 = undefined;
            var d: [n]u8 = undefined;
            for (&a, &b, &c, &d) |*x, *y, *z, *t| {
                x.* = r.boolean();
                y.* = r.boolean();
                z.* = r.int(u8);
                t.* = r.int(u8);
            }
            const ma = maskOf(M, a);
            const mb = maskOf(M, b);
            var want: [6][n]bool = undefined;
            var pick: [n]u8 = undefined;
            var pick_mask: [n]bool = undefined;
            for (0..n) |i| {
                want[0][i] = a[i] and b[i];
                want[1][i] = a[i] or b[i];
                want[2][i] = a[i] != b[i];
                want[3][i] = a[i] == b[i];
                want[4][i] = !a[i];
                want[5][i] = c[i] < d[i];
                pick[i] = if (a[i]) c[i] else d[i];
                pick_mask[i] = if (a[i]) b[i] else !b[i];
            }
            try testing.expectEqual(want[0], maskArray(maskAnd(ma, mb)));
            try testing.expectEqual(want[1], maskArray(maskOr(ma, mb)));
            try testing.expectEqual(want[2], maskArray(maskXor(ma, mb)));
            try testing.expectEqual(want[2], maskArray(maskNe(ma, mb)));
            try testing.expectEqual(want[3], maskArray(maskEq(ma, mb)));
            try testing.expectEqual(want[4], maskArray(maskNot(ma)));
            try testing.expectEqual(want[5], maskArray(mask(@as(@Vector(n, u8), c) < @as(@Vector(n, u8), d))));
            try testing.expectEqual(pick, @as([n]u8, maskSelect(ma, @as(@Vector(n, u8), c), @as(@Vector(n, u8), d))));
            try testing.expectEqual(pick_mask, maskArray(maskSelect(ma, mb, maskNot(mb))));
            const k = r.uintLessThan(usize, n);
            try testing.expectEqual(a[k], lane(ma, @as(i64, @intCast(k))));
            var with = a;
            with[k] = !a[k];
            try testing.expectEqual(with, maskArray(withLane(ma, @as(i64, @intCast(k)), !a[k])));
            if (n > 1) {
                var lagged: [n]bool = undefined;
                for (0..n) |i| lagged[i] = if (i < 1) b[n - 1 + i] else a[i - 1];
                try testing.expectEqual(lagged, maskArray(lag(1, ma, mb)));
            }
        }
    }
}

test "simdRead and simdWrite: lanes in either byte order, one unaligned access" {
    var buf: [19]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i);
    const v = simdRead(@Vector(4, u16), buf[0..], 1, .little);
    try testing.expectEqual([4]u16{ 0x0201, 0x0403, 0x0605, 0x0807 }, @as([4]u16, v));
    const w = simdRead(@Vector(4, u16), buf[0..], 1, .big);
    try testing.expectEqual([4]u16{ 0x0102, 0x0304, 0x0506, 0x0708 }, @as([4]u16, w));
    simdWrite(@Vector(4, u16), buf[0..], 11, w, .big);
    try testing.expectEqualSlices(u8, buf[1..9], buf[11..19]);
    const bytes = simdRead(@Vector(16, u8), buf[0..], 3, .little);
    try testing.expectEqual(@as(u8, 3), lane(bytes, 0));
    try testing.expectEqual(@as(u8, 9), lane(withLane(bytes, 15, 9), 15));
}

test "simdRead and simdWrite: every 1 to 8 byte vector touches exactly its bytes" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f32 }) |T| {
        inline for (.{ 1, 2, 4, 8 }) |n| {
            if (@sizeOf(T) * n > 8) continue;
            const V = @Vector(n, T);
            const size = @sizeOf(T) * n;
            inline for (.{ Endian.little, Endian.big }) |e| {
                var buf: [size + 2]u8 = undefined;
                for (&buf, 0..) |*b, k| b.* = @intCast(k * 7 + 1);
                const v = simdRead(V, buf[1..][0..size], 0, e);
                var out: [size + 2]u8 = @splat(0xEE);
                simdWrite(V, out[1..][0..size], 0, v, e);
                try testing.expectEqual(@as(u8, 0xEE), out[0]);
                try testing.expectEqual(@as(u8, 0xEE), out[size + 1]);
                try testing.expectEqualSlices(u8, buf[1..][0..size], out[1..][0..size]);
            }
        }
    }
}

test "simdRead and simdWrite: wide vectors touch exactly their bytes, padded ones too" {
    inline for (.{ u8, u16, u32, u64, f32 }) |T| {
        inline for (.{ 3, 5, 6, 12, 16, 24, 32, 64 }) |lanes| {
            const V = @Vector(lanes, T);
            const size = @sizeOf([lanes]T);
            inline for (.{ Endian.little, Endian.big }) |e| {
                var buf: [size + 2]u8 = undefined;
                for (&buf, 0..) |*b, k| b.* = @truncate(k * 7 + 1);
                const v = simdRead(V, buf[1..][0..size], 0, e);
                var out: [size + 2]u8 = @splat(0xEE);
                simdWrite(V, out[1..][0..size], 0, v, e);
                try testing.expectEqual(@as(u8, 0xEE), out[0]);
                try testing.expectEqual(@as(u8, 0xEE), out[size + 1]);
                try testing.expectEqualSlices(u8, buf[1..][0..size], out[1..][0..size]);
            }
        }
    }
}

test "viewedPtr reaches what a read view views, or the view's own copy" {
    const Pair = struct { a: i64, t: String };
    var p: Pair = .{ .a = 3, .t = .{} };
    const b: ReadView(Pair) = lend(&p);
    try std.testing.expect(viewedPtr(Pair, &b) == &p);
    const n: ReadView(i64) = 7;
    try std.testing.expect(viewedPtr(i64, &n) == &n);
}

test "strong and weak handles free the box once" {
    const before = usage();
    var drops: usize = 0;
    const a = rcNew(Counter{ .drops = &drops });
    const b = a.cloneStrong();
    const w = a.weakRef();
    a.dropStrong();
    try testing.expectEqual(0, drops);
    const up = w.upgrade().?;
    up.dropStrong();
    b.dropStrong();
    try testing.expectEqual(1, drops);
    try testing.expectEqual(null, w.upgrade());
    w.dropWeak();
    try expectNoLeaks(before);
}

test "upgrading a taken weak handle drops it" {
    const before = usage();
    var drops: usize = 0;
    const a = rcNew(Counter{ .drops = &drops });
    const up = upgradeTaken(a.weakRef()).?;
    a.dropStrong();
    try testing.expectEqual(0, drops);
    const w = up.weakRef();
    up.dropStrong();
    try testing.expectEqual(1, drops);
    try testing.expectEqual(null, upgradeTaken(w));
    try expectNoLeaks(before);
}

test "dropping a shared handle to a shared handle drops the inner one" {
    const before = usage();
    var drops: usize = 0;
    rcNew(rcNew(Counter{ .drops = &drops })).dropStrong();
    try testing.expectEqual(1, drops);
    try expectNoLeaks(before);
}

test "optional handles drop, clone, and compare with none" {
    const before = usage();
    var drops: usize = 0;
    var held: ?*RcBox(Counter) = rcNew(Counter{ .drops = &drops });
    var none: ?*RcBox(Counter) = null;
    var other = cloneOptional(held);
    try testing.expectEqual(2, held.?.strong);
    try testing.expectEqual(null, cloneOptional(none));
    try testing.expect(!isNone(cloneOptional(held)));
    try testing.expect(isNone(none));
    drop(&none);
    drop(&held);
    try testing.expectEqual(0, drops);
    drop(&other);
    try testing.expectEqual(1, drops);
    try testing.expect(needsDrop(?*RcBox(Counter)));
    try testing.expect(!needsDrop(?i32));
    try expectNoLeaks(before);
}

test "Cell.set stores the new value before dropping the old one" {
    const before = usage();
    const Probe = struct {
        cell: *Cell(?*RcBox(@This())),
        seen_new: *bool,
        pub fn __rig_drop(self: *@This()) void {
            self.seen_new.* = self.cell.value != null;
        }
    };
    var seen_new = false;
    var cell: Cell(?*RcBox(Probe)) = .{ .value = null };
    cell.value = rcNew(Probe{ .cell = &cell, .seen_new = &seen_new });
    cell.set(rcNew(Probe{ .cell = &cell, .seen_new = &seen_new }));
    try testing.expect(seen_new);
    cell.__rig_drop();
    try expectNoLeaks(before);
}

test "Cell.replace hands the old value back without dropping it" {
    const before = usage();
    var drops: usize = 0;
    var cell: Cell(*RcBox(Counter)) = .{ .value = rcNew(Counter{ .drops = &drops }) };
    const old = cell.replace(rcNew(Counter{ .drops = &drops }));
    try testing.expectEqual(0, drops);
    old.dropStrong();
    try testing.expectEqual(1, drops);
    cell.__rig_drop();
    try testing.expectEqual(2, drops);
    try expectNoLeaks(before);
}

test "List owns and drops its elements, last first" {
    const before = usage();
    var log: [16]u8 = undefined;
    var n: usize = 0;
    var v: List(*RcBox(Order)) = .empty;
    for (1..11) |i| v.push(rcNew(Order{ .log = &log, .n = &n, .id = @intCast(i) }));
    try testing.expectEqual(10, v.len);
    v.__rig_drop();
    try testing.expectEqualSlices(u8, &.{ 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }, log[0..n]);
    try expectNoLeaks(before);
}

test "List of plain data" {
    const before = usage();
    var v: List(i32) = .initCapacity(2);
    v.push(4);
    v.push(9);
    v.push(16);
    try testing.expectEqual(9, v.at(1));
    try testing.expectEqual(16, v.get(2).?);
    try testing.expectEqual(null, v.get(3));
    try testing.expectEqual(null, v.get(-1));
    try testing.expectEqual(16, v.pop().?);
    try testing.expectEqual(2, v.len);
    v.__rig_drop();
    try expectNoLeaks(before);
}

test "List insert and remove move the elements after the index" {
    const before = usage();
    var v: List(i32) = .empty;
    v.insert(0, 3);
    v.insert(0, 1);
    v.insert(2, 4);
    v.insert(1, 2);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, v.items());
    try testing.expectEqual(2, v.remove(1));
    try testing.expectEqual(4, v.remove(2));
    try testing.expectEqualSlices(i32, &.{ 1, 3 }, v.items());
    v.__rig_drop();
    try expectNoLeaks(before);
}

test "a consuming loop left early drops the rest last first" {
    const before = usage();
    var log: [16]u8 = undefined;
    var n: usize = 0;
    var v: List(Order) = .empty;
    for (1..5) |i| v.push(.{ .log = &log, .n = &n, .id = @intCast(i) });
    var it = v.intoIter();
    var first = it.next().?;
    first.__rig_drop();
    it.deinit();
    try testing.expectEqualSlices(u8, &.{ 1, 4, 3, 2 }, log[0..n]);
    try expectNoLeaks(before);
}

test "Signal takes ownership of subscribers and delivers reentrant sets" {
    const before = usage();
    const Env = struct {
        sig: *Signal(i32),
        seen: *[4]i32,
        n: *usize,
        pub fn __rig_invoke(self: *@This()) void {
            self.seen[self.n.*] = self.sig.value;
            self.n.* += 1;
            if (self.sig.value == 1) self.sig.set(2);
        }
    };
    var sig: Signal(i32) = .init(0);
    var seen: [4]i32 = undefined;
    var n: usize = 0;
    const env = create(Env);
    env.* = .{ .sig = &sig, .seen = &seen, .n = &n };
    sig.subscribe(rcNew(Callback.init(Env, env)));
    sig.set(1);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, seen[0..n]);
    sig.__rig_drop();
    try expectNoLeaks(before);
}

test "closures take any number of arguments and return values" {
    const before = usage();
    const Env = struct {
        base: i64,
        pub fn __rig_invoke(self: *@This(), a: i64, b: i64, c: bool) i64 {
            return if (c) self.base + a * b else self.base;
        }
    };
    const env = create(Env);
    env.* = .{ .base = 1 };
    var closure = Closure(&.{ i64, i64, bool }, i64).init(Env, env);
    try testing.expectEqual(7, closure.invoke(.{ 2, 3, true }));
    try testing.expectEqual(1, closure.invoke(.{ 2, 3, false }));
    closure.__rig_drop();
    try expectNoLeaks(before);
}

fn fnRefDouble(n: i64) i64 {
    return n * 2;
}

test "a callable view calls a stack closure, a function, or an owned closure" {
    const before = usage();
    const Ref = FnRef(&.{i64}, i64);
    const Env = struct {
        k: i64,
        pub fn __rig_invoke(self: *@This(), a: i64) i64 {
            return a + self.k;
        }
    };
    var env: Env = .{ .k = 3 };
    try testing.expectEqual(7, Ref.of(Env, &env).call(.{4}));
    try testing.expectEqual(8, Ref.ofFn(fnRefDouble).call(.{4}));
    const ptr: *const fn (i64) i64 = fnRefDouble;
    try testing.expectEqual(10, Ref.ofFn(ptr).call(.{5}));
    const heap = create(Env);
    heap.* = .{ .k = 10 };
    const handle = rcNew(Closure(&.{i64}, i64).init(Env, heap));
    try testing.expectEqual(11, Ref.ofClosure(handle).call(.{1}));
    try testing.expectEqual(12, Ref.ofClosure(&handle).call(.{2}));
    handle.dropStrong();
    try expectNoLeaks(before);
}

test "aggregates drop their parts" {
    const before = usage();
    var drops: usize = 0;
    const H = *RcBox(Counter);
    const Pair = struct { n: i32, a: H, b: ?H };
    const Slot = union(enum) { full: H, pair: struct { x: H, y: i32 }, empty };
    try testing.expect(needsDrop(Pair));
    try testing.expect(needsDrop(Slot));
    try testing.expect(!needsDrop(struct { n: i32 }));
    try testing.expect(!needsDrop(union(enum) { a: i32, b }));

    var pair: Pair = .{ .n = 1, .a = rcNew(Counter{ .drops = &drops }), .b = rcNew(Counter{ .drops = &drops }) };
    drop(&pair);
    try testing.expectEqual(2, drops);

    var slot: Slot = .{ .pair = .{ .x = rcNew(Counter{ .drops = &drops }), .y = 0 } };
    drop(&slot);
    var empty: Slot = .empty;
    drop(&empty);
    try testing.expectEqual(3, drops);

    var arr: [2]H = .{ rcNew(Counter{ .drops = &drops }), rcNew(Counter{ .drops = &drops }) };
    drop(&arr);
    try testing.expectEqual(5, drops);
    try expectNoLeaks(before);
}

test "an optional held as a struct drops, clones, compares, hashes, and prints as ?T does" {
    const before = usage();
    var drops: usize = 0;
    const H = *RcBox(Counter);
    const Obj = struct {
        h: H,
        pub const __rig_strict_optional = {};
    };
    const Plain = struct {
        id: i64,
        pub const __rig_strict_optional = {};
    };
    const O = Opt(Obj);
    try testing.expect(isOptStruct(O) and needsDrop(O) and !needsDrop(Opt(Plain)));
    try testing.expect(Opt(i64) == ?i64 and Opt(O) == ?O);

    var held = pack(O, Obj{ .h = rcNew(Counter{ .drops = &drops }) });
    var none = pack(O, null);
    try testing.expect(some(none) == null and somePtr(&none) == null);
    var cloned = cloneValue(&held);
    try testing.expectEqual(2, some(held).?.h.strong);
    somePtr(&cloned).?.h.dropStrong();
    cloned = takeOut(&held);
    try testing.expect(isNone(held) and !isNone(pack(Opt(Plain), Plain{ .id = 1 })));
    drop(&none);
    drop(&held);
    try testing.expectEqual(0, drops);
    drop(&cloned);
    try testing.expectEqual(1, drops);

    const P = Opt(Plain);
    const a = pack(P, Plain{ .id = 3 });
    try testing.expect(eql(a, pack(P, Plain{ .id = 3 })) and !eql(a, pack(P, null)) and eql(a, Plain{ .id = 3 }));
    try testing.expect(eql(pack(P, null), @as(?Plain, null)) and !eql(a, pack(P, Plain{ .id = 4 })));
    try testing.expectEqual(hash(@as(?Plain, Plain{ .id = 3 })), hash(a));
    try testing.expectEqual(hash(@as(?Plain, null)), hash(pack(P, null)));
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeValue(&w, a, true);
    try w.writeAll(" ");
    try writeValue(&w, pack(?P, pack(P, null)), true);
    try testing.expectEqualStrings("Plain(id: 3) none", w.buffered());
    try expectNoLeaks(before);
}

test "dropping a long chain of boxes does not recurse per link" {
    const before = usage();
    const Link = struct {
        next: ?*RcBox(@This()),
        drops: *usize,
        pub fn __rig_drop(self: *@This()) void {
            self.drops.* += 1;
            dropFields(self);
        }
    };
    var drops: usize = 0;
    var head: ?*RcBox(Link) = null;
    for (0..100_000) |_| head = rcNew(Link{ .next = head, .drops = &drops });
    drop(&head);
    try testing.expectEqual(100_000, drops);
    try testing.expectEqual(0, drop_depth);
    try expectNoLeaks(before);
}

test "queued drops keep the order of a recursive release" {
    // At some depths the fields of the last node are released from the
    // queue; they still drop last first, before the node's child.
    const before = usage();
    const Tree = struct {
        next: ?*RcBox(@This()),
        a: ?*RcBox(Order),
        b: ?*RcBox(Order),
    };
    var log: [16]u8 = undefined;
    var n: usize = 0;
    for ([_]usize{ 10, max_drop_depth - 1, max_drop_depth, max_drop_depth + 5 }) |depth| {
        n = 0;
        const child = rcNew(Tree{
            .next = null,
            .a = rcNew(Order{ .log = &log, .n = &n, .id = 3 }),
            .b = rcNew(Order{ .log = &log, .n = &n, .id = 4 }),
        });
        var head: ?*RcBox(Tree) = rcNew(Tree{
            .next = child,
            .a = rcNew(Order{ .log = &log, .n = &n, .id = 1 }),
            .b = rcNew(Order{ .log = &log, .n = &n, .id = 2 }),
        });
        for (0..depth) |_| head = rcNew(Tree{ .next = head, .a = null, .b = null });
        drop(&head);
        try testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3 }, log[0..n]);
        try testing.expectEqual(0, drop_depth);
    }
    try expectNoLeaks(before);
}

test "values print the way Rig writes them" {
    const before = usage();
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const P = struct { name: []const u8, n: ?i64 };
    const U = union(enum) { dot, circle: struct { r: i64 }, at: struct { p: P }, rect: struct { w: i64, h: i64 } };
    const h = rcNew(P{ .name = "b", .n = 1 });
    const weak = h.weakRef();
    const Env = struct {
        pub fn __rig_invoke(_: *@This()) void {}
    };
    var closure = Callback.init(Env, create(Env));
    const bytes = [3]u8{ 72, 105, 33 };
    try writeValue(&w, P{ .name = "a", .n = null }, true);
    try w.writeAll(" ");
    try writeValue(&w, U{ .rect = .{ .w = 2, .h = 3 } }, true);
    try w.writeAll(" ");
    try writeValue(&w, U{ .at = .{ .p = .{ .name = "c", .n = 2 } } }, true);
    try w.writeAll(" ");
    try writeValue(&w, [_][]const u8{ "x", "y" }, true);
    try w.writeAll(" ");
    try writeValue(&w, @as(?[]const u8, "hi"), true);
    inline for (.{ h, weak, closure, &bytes, @as(f64, 1), @as(f64, 2.5), @as(f64, -0.0), @as(f32, 1e10) }) |v| {
        try w.writeAll(" ");
        try writeValue(&w, v, true);
    }
    try testing.expectEqualStrings(
        "P(name: \"a\", n: none) .rect(w: 2, h: 3) .at(p: P(name: \"c\", n: 2)) [\"x\", \"y\"] hi " ++
            "P(name: \"b\", n: 1) ~(alive) <closure> [72, 105, 33] 1.0 2.5 -0.0 10000000000.0",
        w.buffered(),
    );
    h.dropStrong();
    w = .fixed(&buf);
    try writeValue(&w, weak, true);
    try testing.expectEqualStrings("~(gone)", w.buffered());
    weak.dropWeak();
    closure.__rig_drop();
    try expectNoLeaks(before);
}

test "String writes values as print does, and compares and frees its bytes" {
    const before = usage();
    const P = struct { name: []const u8, n: ?i64 };
    var t = String.of(.{ "n=", @as(i64, 42), " ", P{ .name = "a", .n = null }, " ", @as(f64, 2.0) });
    try testing.expectEqualStrings("n=42 P(name: \"a\", n: none) 2.0", t.bytes());
    var i: usize = 0;
    while (i < 1000) : (i += 1) t.add(.{ @as(i64, @intCast(i % 10)), "," });
    try testing.expectEqual(@as(Int, 2030), t.length());
    var u = t.clone();
    try testing.expect(eql(t, u) and !eql(t, "n=42"));
    u.clear();
    u.add(.{ "hi", true });
    try testing.expect(eql(u, "hi" ++ "true") and eql("hitrue", &u));
    const Holder = struct { t: String };
    var h = Holder{ .t = String.of(.{"in"}) };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeValue(&w, h, true);
    try w.writeAll(" ");
    try writeValue(&w, h.t, true);
    try testing.expectEqualStrings("Holder(t: \"in\") in", w.buffered());
    drop(&h);
    u.__rig_drop();
    t.__rig_drop();
    try expectNoLeaks(before);
}

test "printing stops past a nesting depth" {
    const before = usage();
    const Node = struct { next: ?*RcBox(@This()) };
    var head: ?*RcBox(Node) = null;
    for (0..100) |_| head = rcNew(Node{ .next = head });
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeValue(&w, head, true);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "Node(next: ...)" ++ &@as([max_print_depth - 1]u8, @splat(')'))));
    drop(&head);
    try expectNoLeaks(before);
}

test "the leak checker counts live allocations" {
    if (!leak_checked) return error.SkipZigTest;
    const a = defaultAllocator();
    const before = usage();
    const block = try a.alloc(u8, 10);
    try testing.expectEqual(before.count + 1, usage().count);
    try testing.expectEqual(before.bytes + 10, usage().bytes);
    const grown = try a.realloc(block, 4000);
    try testing.expectEqual(before.bytes + 4000, usage().bytes);
    a.free(grown);
    try expectNoLeaks(before);
}

/// Run `touch(addr)` in a child process, with the sanitizer's fault
/// handler when `handler` is set; true when a signal ended it, false
/// when it returned. What the child writes to stderr goes to `err`.
fn faultsInChild(addr: usize, comptime touch: fn (usize) void, handler: bool, err: []u8) !struct { faulted: bool, stderr: []u8 } {
    const sys = std.posix.system;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(sys.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
    const pid = sys.fork();
    if (pid == 0) {
        _ = sys.dup2(fds[1], std.posix.STDERR_FILENO);
        // Die of the fault itself, with no stack trace on the way.
        const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.SEGV, &dfl, null);
        std.posix.sigaction(.BUS, &dfl, null);
        if (handler) Sanitizer.installHandler();
        touch(addr);
        sys.exit(0);
    }
    _ = sys.close(fds[1]);
    var n: usize = 0;
    while (n < err.len) {
        const got = std.posix.read(fds[0], err[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    _ = sys.close(fds[0]);
    const signaled = if (builtin.target.os.tag == .linux) blk: {
        var status: i32 = 0;
        if (std.posix.errno(sys.waitpid(@intCast(pid), &status, 0)) != .SUCCESS) return error.WaitFailed;
        break :blk status & 0x7f != 0;
    } else blk: {
        var status: c_int = 0;
        if (sys.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
        break :blk status & 0x7f != 0;
    };
    return .{ .faulted = signaled, .stderr = err[0..n] };
}

fn faults(addr: usize, comptime touch: fn (usize) void) !bool {
    var buf: [256]u8 = undefined;
    return (try faultsInChild(addr, touch, false, &buf)).faulted;
}

fn writeByte(addr: usize) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = 1;
}

fn readByte(addr: usize) void {
    std.mem.doNotOptimizeAway(@as(*volatile u8, @ptrFromInt(addr)).*);
}

test "the program's stack is writable, and the guard below it and the page above it fault" {
    if (!own_stack) return error.SkipZigTest;
    const top = mapStack() orelse return error.TestUnexpectedResult;
    defer std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(stack_guard.lo))[0 .. top + std.heap.pageSize() - stack_guard.lo]);
    try std.testing.expectEqual(top - stack_size, stack_guard.hi);
    try std.testing.expect(stack_guard.hi - stack_guard.lo >= guard_sizes[guard_sizes.len - 1]);
    writeByte(top - 1);
    writeByte(stack_guard.hi);
    try std.testing.expect(try faults(stack_guard.hi - 1, writeByte));
    try std.testing.expect(try faults(stack_guard.lo, readByte));
    try std.testing.expect(try faults(top, readByte));
}

test "a call on the program's stack returns its value" {
    if (!own_stack) return error.SkipZigTest;
    const f = struct {
        fn depth(n: u32) u32 {
            var a: [4096]u8 = undefined;
            a[n % 4096] = 1;
            std.mem.doNotOptimizeAway(&a);
            return if (n == 0) 0 else 1 + depth(n - 1);
        }
    }.depth;
    // 8 MiB deep: more than a test thread's own stack may hold.
    try std.testing.expectEqual(2048, onOwnStack(f, .{2048}));
}

test "the sanitizer faults on freed memory and past a block's end" {
    if (!Sanitizer.supported) return error.SkipZigTest;
    var s: Sanitizer = .{};
    const a = s.allocator();
    const block = try a.alloc(u8, 100);
    @memset(block, 7);
    try testing.expect(!try faults(@intFromPtr(&block[99]), readByte));
    try testing.expect(try faults(@intFromPtr(&block[99]) + 1, readByte));
    try testing.expect(s.owns(@intFromPtr(block.ptr)));
    const freed = @intFromPtr(block.ptr);
    a.free(block);
    try testing.expect(try faults(freed, writeByte));
    try testing.expect(try faults(freed + 50, readByte));
    // Addresses are never handed out again.
    const again = try a.alloc(u8, 100);
    defer a.free(again);
    try testing.expect(@intFromPtr(again.ptr) > freed + 100);
    // Alignment is kept, and a block never resizes in place.
    const aligned = try a.alignedAlloc(u64, .@"64", 3);
    defer a.free(aligned);
    try testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
    try testing.expect(!a.resize(aligned, 4));
    const page = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_max * 2), 10);
    defer a.free(page);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), std.heap.page_size_max * 2));
}

test "past its limit the sanitizer hands out unguarded blocks" {
    if (!Sanitizer.supported) return error.SkipZigTest;
    var s: Sanitizer = .{ .max_live = 2, .noted = true };
    const a = s.allocator();
    const one = try a.alloc(u8, 8);
    const two = try a.alloc(u8, 8);
    const three = try a.alloc(u8, 8);
    try testing.expect(s.owns(@intFromPtr(one.ptr)) and s.owns(@intFromPtr(two.ptr)));
    try testing.expect(!s.owns(@intFromPtr(three.ptr)));
    // An unguarded block grows like any other.
    const grown = try a.realloc(three, 4000);
    @memset(grown, 1);
    a.free(grown);
    const freed = @intFromPtr(one.ptr);
    a.free(one);
    try testing.expect(try faults(freed, readByte));
    a.free(two);
    try testing.expectEqual(0, s.live);
}

test "the sanitizer aligns a block as its type asks: a List of 64-byte vectors" {
    if (!Sanitizer.supported) return error.SkipZigTest;
    var s: Sanitizer = .{ .max_live = 8, .noted = true };
    const a = s.allocator();
    const V = @Vector(64, u8);
    const blocks = try a.alignedAlloc(V, .@"64", 3);
    try testing.expect(s.owns(@intFromPtr(blocks.ptr)));
    try testing.expectEqual(0, @intFromPtr(blocks.ptr) % 64);
    for (blocks, 0..) |*v, i| v.* = @splat(@intCast(i));
    try testing.expectEqual(@as(u8, 2), blocks[2][63]);
    a.free(blocks);
    const odd = try a.alloc(@Vector(16, u8), 5);
    try testing.expectEqual(0, @intFromPtr(odd.ptr) % @alignOf(@Vector(16, u8)));
    a.free(odd);
    try testing.expectEqual(0, s.live);
}

test "a fault in freed memory names it" {
    if (!Sanitizer.supported) return error.SkipZigTest;
    const a = sanitizer.allocator();
    const block = try a.alloc(u8, 16);
    const freed = @intFromPtr(block.ptr);
    a.free(block);
    var buf: [256]u8 = undefined;
    const got = try faultsInChild(freed, writeByte, true, &buf);
    try testing.expect(got.faulted);
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&want, "error: rig: use of freed memory at address 0x{x}\n", .{freed}), got.stderr);
}

test "take clears the alive flag" {
    var alive = true;
    try testing.expectEqual(7, take(&alive, @as(i32, 7)));
    try testing.expect(!alive);
}

test "index bounds and division" {
    try testing.expectEqual(2, index(@as(i32, 2), 3));
    try testing.expectEqual(0, index(0, 1));
    try testing.expectEqual(2, index(@as(u8, 2), 3));
    try testing.expectEqual('b', at(@as([]const u8, "abc"), @as(i64, 1)));
    try testing.expectEqual(2.5, div(@as(f64, 5), 2));
    try testing.expectEqual(-2, div(@as(i64, -5), 2));
}
