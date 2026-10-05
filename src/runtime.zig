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

/// True when a `T` holds a `Cell` by value (not behind a pointer or in
/// a `Vec` or `Signal`): the mirror of sema's `holdsCellByValue`.
fn holdsCell(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| holdsCell(o.child),
        .array => |a| holdsCell(a.child),
        .@"struct" => |s| blk: {
            if (@hasDecl(T, "__rig_cell")) break :blk true;
            if (@hasDecl(T, "__rig_signal")) break :blk false;
            inline for (s.field_types) |F| if (holdsCell(F)) break :blk true;
            break :blk false;
        },
        .@"union" => |u| blk: {
            inline for (u.field_types) |F| if (holdsCell(F)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// How a read borrow `?T` is held: a copy of a scalar or a view (a
/// number, `Bool`, a plain enum, an error, a slice or `String`, a
/// function, or an optional of one), a pointer to anything else. The
/// emitter decides this itself for a known `T` (`sema.lendByValue`), by
/// the same rule, and uses this in a generic type, where `T` depends on
/// the type arguments.
pub fn ReadView(comptime T: type) type {
    return if (needsDrop(T) or holdsCell(T) or !copiedByReadView(T)) *const T else T;
}

fn copiedByReadView(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .comptime_int, .comptime_float, .error_set, .@"enum", .@"fn", .pointer => true,
        .optional => |o| copiedByReadView(o.child),
        else => false,
    };
}

/// A read borrow of what `ptr` points to.
pub fn lend(ptr: anytype) ReadView(@TypeOf(ptr.*)) {
    return if (comptime ReadView(@TypeOf(ptr.*)) == @TypeOf(ptr.*)) ptr.* else ptr;
}

/// The `T` a read borrow `?T` reaches.
pub fn viewed(comptime T: type, view: ReadView(T)) T {
    return if (comptime ReadView(T) == T) view else view.*;
}

/// Fill hidden storage whose scope has ended with `0xAA` under the
/// sanitizer, so a view that outlives it reads garbage, not a stale
/// value; nothing otherwise.
pub fn poison(ptr: anytype) void {
    if (comptime !sanitize) return;
    @memset(std.mem.asBytes(ptr), 0xAA);
}

/// The `T` a read borrow `?T`, held where `borrow` points, reaches:
/// the value itself when the borrow is a pointer, else the borrow's copy.
pub fn viewedPtr(comptime T: type, view: *const ReadView(T)) *const T {
    return if (comptime ReadView(T) == T) view else view.*;
}

/// Release whatever `value` owns: a strong handle drops its count, a
/// type with `__rig_drop` runs it, and aggregates drop their parts.
/// Plain data is a no-op, decided at compile time.
fn dropElement(comptime T: type, value: *T) void {
    if (comptime !needsDrop(T)) return;
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
    place.* = null;
    return value;
}

/// Keep `value`, an owning temporary, in `slot` until its statement
/// ends and drops it.
pub fn keep(slot: anytype, live: *bool, value: @TypeOf(slot.*)) @TypeOf(slot) {
    slot.* = value;
    live.* = true;
    return slot;
}

/// Yield `value` after clearing its binding's alive flag: the value has
/// been moved out, so the binding's scope-exit drop must not run.
pub fn take(alive: *bool, value: anytype) @TypeOf(value) {
    alive.* = false;
    return value;
}

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
/// NaN equals nothing); Strings and slices by length and elements;
/// arrays element by element; structs field by field; tagged unions by
/// tag, then payload; optionals both null or both holding equal values.
/// A value beside an optional compares as the optional's value; other
/// operands take their peer type, so a string literal is a String.
pub fn eql(a: anytype, b: anytype) bool {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    // A Text compares with a Text or a String by its bytes.
    if (comptime isText(A) or isText(B)) return std.mem.eql(u8, textBytes(a), textBytes(b));
    // The peer type of an optional error and an error is an error union.
    const T = if (@typeInfo(A) == .optional) A else if (@typeInfo(B) == .optional) B else @TypeOf(a, b);
    return eqlAs(T, a, b);
}

/// A `Text`, or a pointer to one (a borrowed Text), or a box or shared
/// handle holding one.
fn isText(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "__rig_text") or ((@hasDecl(T, "__rig_box") or @hasDecl(T, "__rig_rcbox")) and isText(@TypeOf(@as(T, undefined).value))),
        .pointer => |p| p.size == .one and isText(p.child),
        else => false,
    };
}

/// The bytes of a Text, a borrowed, boxed, or shared Text, or a String.
fn textBytes(x: anytype) []const u8 {
    const X = @TypeOf(x);
    if (comptime !isText(X)) return x;
    if (comptime @typeInfo(X) == .pointer) return textBytes(x.*);
    if (comptime @hasDecl(X, "__rig_box")) return textBytes(x.value.*);
    if (comptime @hasDecl(X, "__rig_rcbox")) return textBytes(x.value);
    return x.list.items;
}

fn eqlAs(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .optional => |o| {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return eqlAs(o.child, x, y);
        },
        .pointer => |p| {
            if (comptime isString(T)) return std.mem.eql(u8, a, b);
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
            if (@hasDecl(T, "__rig_text")) return std.mem.eql(u8, a.list.items, b.list.items);
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

/// `x == .tag` for a tagged union, or an optional of one: whether `x`
/// holds that variant, whatever its payload.
pub fn isVariant(x: anytype, comptime tag: @EnumLiteral()) bool {
    if (@typeInfo(@TypeOf(x)) == .optional) {
        const v = x orelse return false;
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

/// `a op b` for an ordering operator in a generic body: numbers compare
/// as numbers, and Strings by their bytes, where the first byte that
/// differs decides and a prefix sorts first.
pub fn compare(a: anytype, comptime op: std.math.CompareOperator, b: anytype) bool {
    if (comptime isString(@TypeOf(a, b))) return std.mem.order(u8, a, b).compare(op);
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

/// `+x` of a value that owns: a new value holding a clone of each part,
/// as `+` gives it: a handle counted again, a Text's bytes and a Vec's
/// elements copied, a box's value boxed again, plain data copied. Sema
/// clones only types with no `drop` body and nothing unique
/// (`sema.cloneable`).
pub fn cloneValue(value: anytype) @TypeOf(value.*) {
    const T = @TypeOf(value.*);
    if (comptime !needsDrop(T)) return value.*;
    switch (@typeInfo(T)) {
        .pointer => return value.*.cloneStrong(),
        .optional => return if (value.*) |*inner| cloneValue(inner) else null,
        .array => {
            var out: T = undefined;
            for (&out, value) |*o, *v| o.* = cloneValue(v);
            return out;
        },
        .@"struct" => |s| {
            if (comptime @hasDecl(T, "__rig_text") or @hasDecl(T, "__rig_vec")) return value.clone();
            if (comptime @hasDecl(T, "__rig_box")) return T.init(cloneValue(value.value));
            if (comptime @hasDecl(T, "cloneWeak")) return value.cloneWeak();
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
    const h = value orelse return null;
    return if (comptime isStrongHandle(@TypeOf(h))) h.cloneStrong() else h.cloneWeak();
}

/// `e == none` for a temporary optional that owns a resource: the
/// temporary is dropped.
pub fn isNone(value: anytype) bool {
    defer discard(value);
    return value == null;
}

/// `xs.get(i)` on an array (or a pointer to one), a slice, or a String:
/// the element at `i`, or null when out of range.
pub fn elementAt(items: anytype, i: Int) ?ElementOf(@TypeOf(items)) {
    const idx = std.math.cast(usize, i) orelse return null;
    return if (idx < items.len) items[idx] else null;
}

/// The element type of an array, a pointer to one, or a slice.
fn ElementOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) std.meta.Elem(p.child) else p.child,
        else => std.meta.Elem(T),
    };
}

/// Drop a value nothing keeps: `_ = e`, `as _`, a match payload dropped
/// with `-x`.
pub fn discard(value: anytype) void {
    var v = value;
    drop(&v);
}

/// Allocate a new `*T` holding `value`.
pub fn rcNew(value: anytype) *RcBox(@TypeOf(value)) {
    const box = create(RcBox(@TypeOf(value)));
    box.* = .{ .strong = 1, .weak = 1, .value = value };
    return box;
}

// -----------------------------------------------------------------------------
// Box
// -----------------------------------------------------------------------------

/// `Box[T]`: one `T` on the heap, owned by the box. The box is a pointer
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
        pub const __rig_cell = {};

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

        // A `Cell(Vec(E))` answers its Vec's members. No user code runs
        // while the Vec is in use: `push`, `pop`, `len`, and the element
        // reads and writes of a plain-data `E` run no destructor, and
        // `clear` empties the cell before it drops the elements.

        /// The element type when `T` is a Vec; referenced only then.
        const E = @typeInfo(@FieldType(T, "buf")).pointer.child;

        pub fn vecPush(self: *Self, value: E) void {
            self.value.push(value);
        }

        pub fn vecPop(self: *Self) ?E {
            return self.value.pop();
        }

        pub fn vecLen(self: *const Self) Int {
            return len(self.value.len);
        }

        pub fn vecAt(self: *const Self, i: anytype) E {
            return self.value.at(i);
        }

        pub fn vecGet(self: *const Self, i: Int) ?E {
            return self.value.get(i);
        }

        pub fn vecSet(self: *Self, i: anytype, value: E) void {
            self.value.slot(i).* = value;
        }

        /// A drop that reaches back into the cell finds an empty Vec.
        pub fn vecClear(self: *Self) void {
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

// A borrowed callable `?fun(A, B) -> R` / `?sub(A)` is a
// `FnRef(&.{ A, B }, R)`: a context pointer and a function that calls
// through it, 16 bytes passed by value. It lends what the caller owns (a
// stack closure's environment, a function, an owned closure) for as long
// as the ownership checker lets the borrow live, and owns nothing.

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
        subs: Vec(*RcBox(Callback)),
        notifying: bool = false,
        pending: ?T = null,

        const Self = @This();
        pub const __rig_signal = {};

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
// Vec
// -----------------------------------------------------------------------------

/// `Vec(T)`: a growable array that owns its elements. Dropping it drops
/// the elements in reverse order, then frees the buffer.
pub fn Vec(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,

        const Self = @This();

        pub const empty: Self = .{};

        pub fn initCapacity(capacity: Int) Self {
            var v: Self = .empty;
            v.reserve(std.math.cast(usize, capacity) orelse @panic("negative size"));
            return v;
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeList(w, self.items());
        }

        pub const __rig_vec = {};

        /// `+v`: a new Vec holding a clone of each element (`cloneValue`).
        pub fn clone(self: *const Self) Self {
            var out: Self = .empty;
            out.reserve(self.len);
            for (self.items()) |*e| out.push(cloneValue(e));
            return out;
        }

        /// The live elements. Invalidated by `push`.
        pub fn items(self: *const Self) []T {
            return self.buf[0..self.len];
        }

        fn reserve(self: *Self, want: usize) void {
            if (want <= self.buf.len) return;
            self.buf = defaultAllocator().realloc(self.buf, @max(want, 4, self.buf.len * 2)) catch oom();
        }

        pub fn push(self: *Self, value: T) void {
            self.reserve(self.len + 1);
            self.buf[self.len] = value;
            self.len += 1;
        }

        /// The element at `i`, or null when out of range. Plain-data `T` only.
        pub fn get(self: *const Self, i: Int) ?T {
            const idx = std.math.cast(usize, i) orelse return null;
            return if (idx < self.len) self.buf[idx] else null;
        }

        /// `v[i]`: the element at `i`; panics when out of range.
        pub fn at(self: *const Self, i: anytype) T {
            return self.buf[index(i, self.len)];
        }

        /// `v[i] = x`: the slot at `i`; panics when out of range.
        pub fn slot(self: *Self, i: anytype) *T {
            return &self.buf[index(i, self.len)];
        }

        /// The slot at `i`, read-only, for a slice of an element's
        /// array; panics when out of range.
        pub fn constSlot(self: *const Self, i: anytype) *const T {
            return &self.buf[index(i, self.len)];
        }

        /// Remove and return the last element; the caller owns it.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
        }

        /// Insert `value` at `i`, moving the elements from `i` on up by
        /// one; `i` may be `len`. Panics unless `0 <= i <= len`.
        pub fn insert(self: *Self, i: Int, value: T) void {
            const idx = index(i, self.len + 1);
            self.reserve(self.len + 1);
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

        /// `for x in <v`: the Vec's elements, each handed over in order.
        pub const IntoIter = struct {
            vec: Self,
            next_index: usize = 0,

            pub fn next(it: *IntoIter) ?T {
                if (it.next_index >= it.vec.len) return null;
                const value = it.vec.buf[it.next_index];
                it.next_index += 1;
                return value;
            }

            /// Drop the elements not handed over (the loop left early),
            /// last first as a Vec does, then free the buffer.
            pub fn deinit(it: *IntoIter) void {
                while (it.vec.len > it.next_index) {
                    it.vec.len -= 1;
                    dropElement(T, &it.vec.buf[it.vec.len]);
                }
                it.vec.len = 0;
                it.vec.__rig_drop();
            }
        };

        pub fn intoIter(self: Self) IntoIter {
            return .{ .vec = self };
        }

        /// Drop every element (last first), keeping the buffer.
        pub fn clear(self: *Self) void {
            while (self.len > 0) {
                self.len -= 1;
                dropElement(T, &self.buf[self.len]);
            }
        }

        pub fn __rig_drop(self: *Self) void {
            self.clear();
            defaultAllocator().free(self.buf);
            self.buf = &.{};
        }
    };
}

// -----------------------------------------------------------------------------
// Text
// -----------------------------------------------------------------------------

/// `Text`: owned, growable bytes, UTF-8 by convention. `Text(a, b)` and
/// `!t.add(a, b)` write each value as `print` does at the top level
/// (`writeValue`), with no separators; a String taken from a Text views
/// its buffer, which the ownership checker keeps from changing while a
/// view is in use.
pub const Text = struct {
    list: std.ArrayList(u8) = .empty,

    /// Printed as its bytes (`writeValue`), compared by them (`eql`).
    pub const __rig_text = {};

    pub const empty: Text = .{};

    /// `Text(a, b, ...)`.
    pub fn of(parts: anytype) Text {
        var t: Text = .empty;
        t.add(parts);
        return t;
    }

    /// `!t.add(a, b, ...)`.
    pub fn add(self: *Text, parts: anytype) void {
        var out: std.Io.Writer.Allocating = .fromArrayList(defaultAllocator(), &self.list);
        defer self.list = out.toArrayList();
        inline for (@typeInfo(@TypeOf(parts)).@"struct".field_names) |f| writeValue(&out.writer, @field(parts, f), true) catch oom();
    }

    /// `!t.push(b)`: append one byte.
    pub fn push(self: *Text, b: u8) void {
        self.list.append(defaultAllocator(), b) catch oom();
    }

    /// `!t.clear()`: empty, keeping the buffer.
    pub fn clear(self: *Text) void {
        self.list.clearRetainingCapacity();
    }

    /// The bytes, as a String: `?t[..]`, `?t` where a String goes.
    pub fn bytes(self: Text) []const u8 {
        return self.list.items;
    }

    /// `t.len`.
    pub fn length(self: Text) Int {
        return @intCast(self.list.items.len);
    }

    /// `+t`: a new Text holding the same bytes.
    pub fn clone(self: Text) Text {
        var t: Text = .empty;
        t.list.appendSlice(defaultAllocator(), self.list.items) catch oom();
        return t;
    }

    pub fn __rig_drop(self: *Text) void {
        self.list.deinit(defaultAllocator());
        self.list = .empty;
    }
};

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

/// `for x in <a` of an array whose elements move: each element handed
/// over in order; those not handed over (the loop left early) are
/// dropped, last first, as the array would drop them.
pub fn ArrayIntoIter(comptime A: type) type {
    const T = @typeInfo(A).array.child;
    return struct {
        items: A,
        next_index: usize = 0,

        pub fn next(it: *@This()) ?T {
            if (it.next_index >= it.items.len) return null;
            const value = it.items[it.next_index];
            it.next_index += 1;
            return value;
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
/// cannot pass overlapping slices (the write borrow excludes the read).
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

/// `bytes.read[T, e](at)`: the integer or float `T` stored in the
/// `@sizeOf(T)` bytes from `at`, in byte order `e`; panics unless they
/// are all in range.
pub fn readInt(comptime T: type, bytes: anytype, offset: anytype, comptime endian: Endian) T {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, offset, n) orelse @panic("byte read out of range");
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return @bitCast(std.mem.readInt(Bits, bytes[i..][0..n], zigEndian(endian)));
}

/// `!bytes.write[T, e](at, value)`: store `value` in the `@sizeOf(T)`
/// bytes from `at`, in byte order `e`; panics unless they are all in
/// range.
pub fn writeInt(comptime T: type, bytes: anytype, offset: anytype, value: T, comptime endian: Endian) void {
    const n = @divExact(@bitSizeOf(T), 8);
    const i = byteOffset(bytes.len, offset, n) orelse @panic("byte write out of range");
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    std.mem.writeInt(Bits, bytes[i..][0..n], @bitCast(value), zigEndian(endian));
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

/// A length or count as a Rig `Int`.
pub fn len(n: usize) Int {
    return @intCast(n);
}

fn indexPanic() noreturn {
    @panic("index out of bounds");
}

fn oom() noreturn {
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
        const addr = switch (builtin.target.os.tag) {
            .linux => @intFromPtr(info.fields.sigfault.addr),
            else => @intFromPtr(info.addr),
        };
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

/// The bytes `guardStack` keeps unmapped below the stack on macOS: an
/// overflowing frame of up to this size lands there and stops the
/// program.
const stack_reserve: usize = 64 << 20;

/// The main thread's stack: what Zig gives it, and what `guardStack`
/// holds it to on Linux.
const stack_size: usize = 16 << 20;

extern "c" fn pthread_get_stackaddr_np(std.c.pthread_t) *anyopaque;
extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;

/// Called first in the emitted `main` (and by `runTests`). Zig probes the
/// stack page by page as a frame grows only on x86; elsewhere a frame
/// larger than the guard below the stack steps over it, and an overflow
/// would write into whatever is mapped beyond instead of stopping the
/// program. A frame holds at most 16 MiB of values (`checkFrames` in
/// the compiler), so 64 MiB kept free below the stack catches it.
///
/// - macOS guards the stack with one page, and once the address space
///   below fills, it maps memory right next to it: reserve
///   `stack_reserve` bytes below the guard that no access may touch.
/// - Linux places its mappings at least 128 MiB below the top of the
///   stack, and at least the stack limit the program started with plus
///   1 MiB: holding the stack to `stack_size` keeps 112 MiB free below it.
///
/// A program that cannot make that space safe stops before it runs.
pub fn guardStack() void {
    if (guarded()) return;
    std.debug.print("rig: cannot reserve the stack guard below the main stack\n", .{});
    std.process.exit(1);
}

/// Whether an overflow of the main stack now stops the program.
fn guarded() bool {
    if (builtin.target.cpu.arch.isX86()) return true;
    return switch (builtin.target.os.tag) {
        .macos => reserveBelowStack() != null,
        .linux => {
            const limit = std.posix.getrlimit(.STACK) catch return false;
            if (limit.cur <= stack_size) return true;
            std.posix.setrlimit(.STACK, .{ .cur = stack_size, .max = limit.max }) catch return false;
            return true;
        },
        else => true,
    };
}

/// On macOS, reserve `stack_reserve` bytes right below the main stack's
/// guard page; null when something is mapped there already.
fn reserveBelowStack() ?[*]align(std.heap.page_size_min) u8 {
    const self = std.c.pthread_self();
    const bottom = @intFromPtr(pthread_get_stackaddr_np(self)) - pthread_get_stacksize_np(self);
    const base = bottom - std.heap.pageSize() - stack_reserve;
    const got = std.c.mmap(@ptrFromInt(base), stack_reserve, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (got == std.c.MAP_FAILED) return null;
    if (@intFromPtr(got) != base) {
        _ = std.c.munmap(@alignCast(got), stack_reserve);
        return null;
    }
    return @ptrCast(@alignCast(got));
}

/// What the process started with, which Zig hands only to `main`:
/// the arguments and environment, for the standard library.
pub var process: ?std.process.Init.Minimal = null;
var process_args: []const []const u8 = &.{};

/// Called first in the emitted `main` (after `guardStack`) and in
/// `rig test`'s: store what the process started with. The arguments are
/// gathered into Strings once, freed by `finish`.
pub fn start(init: std.process.Init.Minimal) void {
    process = init;
    if (sanitize) {
        sanitizer.configure(init.environ);
        Sanitizer.installHandler();
    }
    if (@TypeOf(init.args.vector) != []const [*:0]const u8) return;
    const list = defaultAllocator().alloc([]const u8, init.args.vector.len) catch oom();
    for (list, init.args.vector) |*arg, c| arg.* = std.mem.sliceTo(c, 0);
    process_args = list;
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

/// `fun main -> Int`: its result, which `finish` has already run after,
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

/// `print(a, b, ...)`: the values separated by single spaces, then a
/// newline.
pub fn print(args: anytype) void {
    const w = stdout();
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names, 0..) |f, i| {
        if (i > 0) w.writeAll(" ") catch {};
        writeValue(w, @field(args, f), true) catch {};
    }
    w.writeAll("\n") catch {};
    if (stdout_is_tty) flush();
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
    guardStack();
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

/// Text: a string literal (`*const [N:0]u8`) or a `String` slice. An
/// array of bytes held by pointer is a list of numbers.
fn isString(comptime T: type) bool {
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

/// The Rig name of a declared type: `main.Wrap(i64)` is `Wrap`.
fn rigTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const end = comptime std.mem.findScalar(u8, full, '(') orelse full.len;
    const begin = comptime if (std.mem.findScalarLast(u8, full[0..end], '.')) |d| d + 1 else 0;
    // A Rig name the emitter reserves (`std`, `rig`) is spelled `@"std'"`.
    const quoted = comptime end > begin and full[end - 1] == '\'';
    return full[begin..if (quoted) end - 1 else end];
}

/// Values nested deeper than this print as `...`: a structure that
/// reaches itself through handles would otherwise print forever.
const max_print_depth = 64;
var print_depth: u32 = 0;

/// A value as Rig writes it: text as is at the top level and quoted
/// inside other values, a float with a decimal point, `none` for an
/// absent optional, `Name(field: v)` for a struct, `.variant` /
/// `.variant(field: v)` for an enum, and `[a, b]` for arrays and Vecs. A
/// shared handle or a Box prints its value, a function `<fun>`.
fn writeValue(w: *std.Io.Writer, value: anytype, top: bool) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) {
        return if (top) w.writeAll(value) else w.print("\"{s}\"", .{value});
    }
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
            if (@hasDecl(T, "__rig_text")) return writeValue(w, value.list.items, top);
        },
        .optional => return if (value) |v| writeValue(w, v, top) else w.writeAll("none"),
        .pointer => |p| {
            if (comptime isStrongHandle(T)) return writeValue(w, value.value, top);
            if (@typeInfo(p.child) == .@"fn") return w.writeAll("<fun>");
            if (p.size != .slice) return writeValue(w, value.*, top);
        },
        .@"enum" => return w.print(".{s}", .{@tagName(value)}),
        .error_set => return w.writeAll(errorShown(value)),
        else => {},
    }
    if (print_depth >= max_print_depth) return w.writeAll("...");
    print_depth += 1;
    defer print_depth -= 1;
    switch (@typeInfo(T)) {
        .pointer, .array => try writeList(w, value),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                try w.print(".{s}", .{@tagName(tag)});
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
        try w.print("{s}: ", .{f});
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

test "the reserve below the stack is made only where nothing is mapped" {
    if (builtin.target.os.tag != .macos or builtin.target.cpu.arch.isX86()) return error.SkipZigTest;
    const self = std.c.pthread_self();
    const bottom = @intFromPtr(pthread_get_stackaddr_np(self)) - pthread_get_stacksize_np(self);
    const page = std.heap.pageSize();
    // Something mapped in the middle of the space: no reserve.
    const in = std.c.mmap(@ptrFromInt(bottom - page - stack_reserve / 2), page, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    try std.testing.expect(in != std.c.MAP_FAILED);
    try std.testing.expect(reserveBelowStack() == null);
    _ = std.c.munmap(@alignCast(in), page);
    // Free again: the reserve is made.
    const r = reserveBelowStack() orelse return error.TestUnexpectedResult;
    _ = std.c.munmap(r, stack_reserve);
}

test "guardStack holds the stack to 16 MiB on Linux" {
    if (builtin.target.os.tag != .linux or builtin.target.cpu.arch.isX86()) return error.SkipZigTest;
    const before = try std.posix.getrlimit(.STACK);
    if (before.max < 2 * stack_size) return error.SkipZigTest;
    try std.posix.setrlimit(.STACK, .{ .cur = 2 * stack_size, .max = before.max });
    try std.testing.expect(guarded());
    try std.testing.expectEqual(stack_size, (try std.posix.getrlimit(.STACK)).cur);
}

test "viewedPtr reaches what a read view views, or the view's own copy" {
    const Pair = struct { a: i64, t: Text };
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
    var some: ?*RcBox(Counter) = rcNew(Counter{ .drops = &drops });
    var none: ?*RcBox(Counter) = null;
    var other = cloneOptional(some);
    try testing.expectEqual(2, some.?.strong);
    try testing.expectEqual(null, cloneOptional(none));
    try testing.expect(!isNone(cloneOptional(some)));
    try testing.expect(isNone(none));
    drop(&none);
    drop(&some);
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

test "Vec owns and drops its elements, last first" {
    const before = usage();
    var log: [16]u8 = undefined;
    var n: usize = 0;
    var v: Vec(*RcBox(Order)) = .empty;
    for (1..11) |i| v.push(rcNew(Order{ .log = &log, .n = &n, .id = @intCast(i) }));
    try testing.expectEqual(10, v.len);
    v.__rig_drop();
    try testing.expectEqualSlices(u8, &.{ 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }, log[0..n]);
    try expectNoLeaks(before);
}

test "Vec of plain data" {
    const before = usage();
    var v: Vec(i32) = .initCapacity(2);
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

test "Vec insert and remove move the elements after the index" {
    const before = usage();
    var v: Vec(i32) = .empty;
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
    var v: Vec(Order) = .empty;
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

test "Text writes values as print does, and compares and frees its bytes" {
    const before = usage();
    const P = struct { name: []const u8, n: ?i64 };
    var t = Text.of(.{ "n=", @as(i64, 42), " ", P{ .name = "a", .n = null }, " ", @as(f64, 2.0) });
    try testing.expectEqualStrings("n=42 P(name: \"a\", n: none) 2.0", t.bytes());
    var i: usize = 0;
    while (i < 1000) : (i += 1) t.add(.{ @as(i64, @intCast(i % 10)), "," });
    try testing.expectEqual(@as(Int, 2030), t.length());
    var u = t.clone();
    try testing.expect(eql(t, u) and !eql(t, "n=42"));
    u.clear();
    u.add(.{ "hi", true });
    try testing.expect(eql(u, "hi" ++ "true") and eql("hitrue", &u));
    const Holder = struct { t: Text };
    var h = Holder{ .t = Text.of(.{"in"}) };
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
