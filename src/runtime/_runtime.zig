//! The Rig runtime. `bin/rig` writes this file verbatim next to every
//! emitted program as `_runtime.zig`; emitted code refers to it as `rig`.
//!
//! Ownership conventions shared with the emitter:
//!
//! - `*T` is `*RcBox(T)`: single-threaded reference counting with weak
//!   handles (`WeakHandle(T)`). `cloneStrong` / `dropStrong` /
//!   `weakRef` / `cloneWeak` / `dropWeak` / `upgrade` are the only
//!   refcount operations; the emitter spells every one explicitly.
//! - A type owns resources iff it declares `__rig_drop(self: *Self)`.
//!   `dropElement` is the single place that knows how to release a value
//!   of any type: strong handles drop a count, types with `__rig_drop`
//!   run it, everything else is plain data.
//! - Allocation failure panics. Every allocation goes through
//!   `defaultAllocator()`, which is leak-checked in Debug builds.

const std = @import("std");

/// Rig's `Int`. Sizes and indices cross the Rig boundary as `Int`.
pub const Int = i32;

// -----------------------------------------------------------------------------
// Dropping values
// -----------------------------------------------------------------------------

/// True when `T` is `*RcBox(U)` for some `U`.
pub fn isStrongHandle(comptime T: type) bool {
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
pub fn needsDrop(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => isStrongHandle(T),
        .optional => |o| needsDrop(o.child),
        .array => |a| needsDrop(a.child),
        .@"struct" => |s| blk: {
            if (@hasDecl(T, "__rig_drop")) break :blk true;
            inline for (s.fields) |f| if (needsDrop(f.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (@hasDecl(T, "__rig_drop")) break :blk true;
            if (u.tag_type == null) break :blk false;
            inline for (u.fields) |f| if (needsDrop(f.type)) break :blk true;
            break :blk false;
        },
        .@"enum", .@"opaque" => @hasDecl(T, "__rig_drop"),
        else => false,
    };
}

/// Release whatever `value` owns: a strong handle drops its count, a
/// type with `__rig_drop` runs it, and aggregates drop their parts.
/// Plain data is a no-op, decided at compile time.
pub fn dropElement(comptime T: type, value: *T) void {
    if (comptime !needsDrop(T)) return;
    switch (@typeInfo(T)) {
        .pointer => value.*.dropStrong(),
        .optional => if (value.*) |*inner| dropElement(@TypeOf(inner.*), inner),
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
    const fields = @typeInfo(@TypeOf(ptr.*)).@"struct".fields;
    comptime var i = fields.len;
    inline while (i > 0) {
        i -= 1;
        dropElement(fields[i].type, &@field(ptr, fields[i].name));
    }
}

/// Yield `value` after clearing its binding's alive flag: the value has
/// been moved out, so the binding's scope-exit drop must not run.
pub fn take(alive: *bool, value: anytype) @TypeOf(value) {
    alive.* = false;
    return value;
}

/// Allocate one `T` with the default allocator.
pub fn create(comptime T: type) *T {
    return defaultAllocator().create(T) catch oom();
}

// -----------------------------------------------------------------------------
// Shared and weak handles
// -----------------------------------------------------------------------------

/// Reference-counted box behind `*T`. `strong` counts owning handles;
/// `weak` counts weak handles plus one on behalf of all strong handles,
/// so the box outlives its value while weak handles remain.
pub fn RcBox(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        strong: usize,
        weak: usize,
        value: T,

        /// Marks the type for `isStrongHandle`.
        pub const __rig_rcbox = {};

        const Self = @This();

        pub fn new(allocator: std.mem.Allocator, value: T) !*Self {
            const box = try allocator.create(Self);
            box.* = .{ .allocator = allocator, .strong = 1, .weak = 1, .value = value };
            return box;
        }

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
        /// and then the strong side's share of the weak count.
        pub fn dropStrong(self: *Self) void {
            std.debug.assert(self.strong > 0);
            self.strong -= 1;
            if (self.strong > 0) return;
            dropElement(T, &self.value);
            self.weak -= 1;
            if (self.weak == 0) self.allocator.destroy(self);
        }
    };
}

/// `~T`: a non-owning handle to an `RcBox(T)`.
pub fn WeakHandle(comptime T: type) type {
    return struct {
        ptr: ?*RcBox(T),

        const Self = @This();

        pub fn cloneWeak(self: Self) Self {
            if (self.ptr) |p| p.weak += 1;
            return self;
        }

        pub fn dropWeak(self: Self) void {
            const p = self.ptr orelse return;
            std.debug.assert(p.weak > 0);
            p.weak -= 1;
            if (p.weak == 0) p.allocator.destroy(p);
        }

        /// A new strong handle, or null once the value has been dropped.
        pub fn upgrade(self: Self) ?*RcBox(T) {
            const p = self.ptr orelse return null;
            if (p.strong == 0) return null;
            p.strong += 1;
            return p;
        }

        pub fn __rig_drop(self: *Self) void {
            self.dropWeak();
        }
    };
}

/// Allocate a new `*T` holding `value`.
pub fn rcNew(value: anytype) *RcBox(@TypeOf(value)) {
    return RcBox(@TypeOf(value)).new(defaultAllocator(), value) catch oom();
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
    };
}

// -----------------------------------------------------------------------------
// Owned closures
// -----------------------------------------------------------------------------

// `*Closure()`, `*Closure1(A)` and `*Closure2(A, B)` are shared handles
// to these type-erased closures. Each closure literal allocates its own
// environment (captures plus `invoke` / `drop` functions that know its
// layout); the erased `ctx` pointer makes every literal of one arity the
// same type. `drop_fn` releases the captures and frees the environment.

pub const Closure0 = struct {
    ctx: *anyopaque,
    invoke_fn: *const fn (*anyopaque) void,
    drop_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    allocator: std.mem.Allocator,

    pub fn invoke(self: *Closure0) void {
        self.invoke_fn(self.ctx);
    }

    pub fn __rig_drop(self: *Closure0) void {
        self.drop_fn(self.ctx, self.allocator);
    }
};

pub fn Closure1(comptime A: type) type {
    return struct {
        ctx: *anyopaque,
        invoke_fn: *const fn (*anyopaque, A) void,
        drop_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn invoke(self: *Self, a: A) void {
            self.invoke_fn(self.ctx, a);
        }

        pub fn __rig_drop(self: *Self) void {
            self.drop_fn(self.ctx, self.allocator);
        }
    };
}

pub fn Closure2(comptime A: type, comptime B: type) type {
    return struct {
        ctx: *anyopaque,
        invoke_fn: *const fn (*anyopaque, A, B) void,
        drop_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn invoke(self: *Self, a: A, b: B) void {
            self.invoke_fn(self.ctx, a, b);
        }

        pub fn __rig_drop(self: *Self) void {
            self.drop_fn(self.ctx, self.allocator);
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
        subs: Vec(*RcBox(Closure0)),
        notifying: bool = false,
        pending: ?T = null,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value, .subs = .init(defaultAllocator()) };
        }

        pub fn get(self: *const Self) T {
            return self.value;
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
                for (self.subs.items()) |cb| cb.value.invoke();
                next = self.pending;
            }
        }

        /// Takes ownership of `cb`; the caller passes its own strong
        /// handle (`sig.subscribe(+cb)` to keep one).
        pub fn subscribe(self: *Self, cb: *RcBox(Closure0)) void {
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
        allocator: std.mem.Allocator,
        buf: []T = &.{},
        len: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: Int) Self {
            var v: Self = .init(allocator);
            v.reserve(toIndex(capacity));
            return v;
        }

        /// The live elements. Invalidated by `push`.
        pub fn items(self: *const Self) []T {
            return self.buf[0..self.len];
        }

        fn reserve(self: *Self, want: usize) void {
            if (want <= self.buf.len) return;
            const cap = @max(want, 4, self.buf.len * 2);
            const new_buf = self.allocator.alloc(T, cap) catch oom();
            @memcpy(new_buf[0..self.len], self.buf[0..self.len]);
            if (self.buf.len > 0) self.allocator.free(self.buf);
            self.buf = new_buf;
        }

        pub fn push(self: *Self, value: T) void {
            self.reserve(self.len + 1);
            self.buf[self.len] = value;
            self.len += 1;
        }

        pub fn length(self: *const Self) Int {
            return @intCast(self.len);
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

        /// Remove and return the last element. Plain-data `T` only.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
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
            if (self.buf.len > 0) self.allocator.free(self.buf);
            self.buf = &.{};
        }
    };
}

// -----------------------------------------------------------------------------
// Integers and indexing
// -----------------------------------------------------------------------------

/// Convert a Rig index to `usize`, panicking unless `0 <= i < len`.
pub fn index(i: anytype, count: usize) usize {
    const idx = std.math.cast(usize, i) orelse indexPanic();
    if (idx >= count) indexPanic();
    return idx;
}

/// A length or count as a Rig `Int`.
pub fn len(n: usize) Int {
    return @intCast(n);
}

fn toIndex(n: Int) usize {
    return std.math.cast(usize, n) orelse @panic("negative size");
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

const leak_checked = @import("builtin").mode == .Debug;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// The allocator behind every runtime allocation: a leak-checking
/// `DebugAllocator` in Debug builds, `smp_allocator` otherwise.
pub fn defaultAllocator() std.mem.Allocator {
    return if (leak_checked) debug_allocator.allocator() else std.heap.smp_allocator;
}

/// Deferred first in the emitted `main`, so it runs after all of `main`'s
/// drops. The allocator has already logged each leak with a stack trace;
/// exit non-zero so a leaking program never passes.
pub fn checkLeaks() void {
    if (!leak_checked) return;
    if (debug_allocator.deinit() == .leak) {
        std.debug.print("error: rig: memory leak detected\n", .{});
        std.process.exit(1);
    }
}

/// `print`: formatted and flushed per call, so output interleaves
/// correctly with panics and diagnostics on stderr.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(std.Io.Threaded.global_single_threaded.io(), &buffer);
    fw.interface.print(fmt, args) catch {};
    fw.interface.flush() catch {};
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

const Counter = struct {
    drops: *usize,
    pub fn __rig_drop(self: *Counter) void {
        self.drops.* += 1;
    }
};

test "strong and weak handles free the box once" {
    var drops: usize = 0;
    const a = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops });
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
}

test "dropping a shared handle to a shared handle drops the inner one" {
    var drops: usize = 0;
    const inner = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops });
    const outer = try RcBox(*RcBox(Counter)).new(testing.allocator, inner);
    outer.dropStrong();
    try testing.expectEqual(1, drops);
}

test "optional handles drop their payload" {
    var drops: usize = 0;
    var some: ?*RcBox(Counter) = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops });
    var none: ?*RcBox(Counter) = null;
    drop(&none);
    drop(&some);
    try testing.expectEqual(1, drops);
    try testing.expect(needsDrop(?*RcBox(Counter)));
    try testing.expect(!needsDrop(?i32));
}

test "Cell.set stores the new value before dropping the old one" {
    const Probe = struct {
        cell: *Cell(?*RcBox(@This())),
        seen_new: *bool,
        pub fn __rig_drop(self: *@This()) void {
            self.seen_new.* = self.cell.value != null;
        }
    };
    var seen_new = false;
    var cell: Cell(?*RcBox(Probe)) = .{ .value = null };
    const old = try RcBox(Probe).new(testing.allocator, .{ .cell = &cell, .seen_new = &seen_new });
    cell.value = old;
    const new = try RcBox(Probe).new(testing.allocator, .{ .cell = &cell, .seen_new = &seen_new });
    cell.set(new);
    try testing.expect(seen_new);
    cell.__rig_drop();
}

test "Vec owns and drops its elements" {
    var drops: usize = 0;
    var v: Vec(*RcBox(Counter)) = .init(testing.allocator);
    for (0..10) |_| v.push(try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }));
    try testing.expectEqual(10, v.length());
    v.__rig_drop();
    try testing.expectEqual(10, drops);
}

test "Vec of plain data" {
    var v: Vec(i32) = .initCapacity(testing.allocator, 2);
    defer v.__rig_drop();
    v.push(4);
    v.push(9);
    v.push(16);
    try testing.expectEqual(9, v.at(1));
    try testing.expectEqual(16, v.get(2).?);
    try testing.expectEqual(null, v.get(3));
    try testing.expectEqual(null, v.get(-1));
    try testing.expectEqual(16, v.pop().?);
    try testing.expectEqual(2, v.length());
}

test "Signal takes ownership of subscribers and delivers reentrant sets" {
    const Env = struct {
        sig: *Signal(i32),
        seen: *[4]i32,
        n: *usize,
        fn invoke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen[self.n.*] = self.sig.value;
            self.n.* += 1;
            if (self.sig.value == 1) self.sig.set(2);
        }
        fn dropEnv(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }
    };
    var sig: Signal(i32) = .{ .value = 0, .subs = .init(testing.allocator) };
    defer sig.__rig_drop();
    var seen: [4]i32 = undefined;
    var n: usize = 0;
    const env = try testing.allocator.create(Env);
    env.* = .{ .sig = &sig, .seen = &seen, .n = &n };
    const cb = try RcBox(Closure0).new(testing.allocator, .{
        .ctx = env,
        .invoke_fn = Env.invoke,
        .drop_fn = Env.dropEnv,
        .allocator = testing.allocator,
    });
    sig.subscribe(cb);
    sig.set(1);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, seen[0..n]);
}

test "aggregates drop their parts" {
    var drops: usize = 0;
    const H = *RcBox(Counter);
    const Pair = struct { n: i32, a: H, b: ?H };
    const Slot = union(enum) { full: H, pair: struct { x: H, y: i32 }, empty };
    try testing.expect(needsDrop(Pair));
    try testing.expect(needsDrop(Slot));
    try testing.expect(!needsDrop(struct { n: i32 }));
    try testing.expect(!needsDrop(union(enum) { a: i32, b }));

    var pair: Pair = .{
        .n = 1,
        .a = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }),
        .b = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }),
    };
    drop(&pair);
    try testing.expectEqual(2, drops);

    var slot: Slot = .{ .pair = .{ .x = try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }), .y = 0 } };
    drop(&slot);
    var empty: Slot = .empty;
    drop(&empty);
    try testing.expectEqual(3, drops);

    var arr: [2]H = .{
        try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }),
        try RcBox(Counter).new(testing.allocator, .{ .drops = &drops }),
    };
    drop(&arr);
    try testing.expectEqual(5, drops);
}

test "take clears the alive flag" {
    var alive = true;
    try testing.expectEqual(7, take(&alive, @as(i32, 7)));
    try testing.expect(!alive);
}

test "index bounds" {
    try testing.expectEqual(2, index(@as(i32, 2), 3));
    try testing.expectEqual(0, index(0, 1));
}
