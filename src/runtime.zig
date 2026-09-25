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
pub const Int = i64;

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
            if (self.weak == 0) self.allocator.destroy(self);
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
var drop_queue: std.ArrayListUnmanaged(PendingDrop) = .empty;

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

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const alive = if (self.ptr) |p| p.strong > 0 else false;
            try w.writeAll(if (alive) "~(alive)" else "~(gone)");
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

/// `+x` for an optional handle: another handle to the same box, or null.
pub fn cloneOptional(value: anytype) @TypeOf(value) {
    const h = value orelse return null;
    return if (comptime isStrongHandle(@TypeOf(h))) h.cloneStrong() else h.cloneWeak();
}

/// `e == none` for a temporary optional that owns a resource: the
/// temporary is dropped.
pub fn isNone(value: anytype) bool {
    var v = value;
    defer drop(&v);
    return v == null;
}

/// Allocate a new `*T` holding `value`.
pub fn rcNew(value: anytype) *RcBox(@TypeOf(value)) {
    return RcBox(@TypeOf(value)).new(defaultAllocator(), value) catch oom();
}

// -----------------------------------------------------------------------------
// Cell
// -----------------------------------------------------------------------------

/// `Cell(T)`: interior mutability. `get` is only offered for plain-data
/// `T` (ctx enforces this); resource payloads move in and out with
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

// An owned closure `*fun(A, B) R` / `*sub(A)` is a shared handle to a
// `Closure(&.{ A, B }, R)`: a type-erased closure. Each closure literal
// allocates its own environment `Env` (the captures plus an `invoke`
// method taking the parameters); `init` erases it behind `ctx`, so every
// literal with the same parameter and return types has the same type.
// `drop_fn` releases the captures and frees the environment.

pub fn Closure(comptime params: []const type, comptime R: type) type {
    return struct {
        ctx: *anyopaque,
        invoke_fn: *const fn (*anyopaque, Args) R,
        drop_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        allocator: std.mem.Allocator,

        const Self = @This();
        pub const Args = std.meta.Tuple(params);

        /// Erase `env`, a heap-allocated `Env` the closure now owns.
        pub fn init(comptime Env: type, env: *Env) Self {
            const erased = struct {
                fn invoke(ctx: *anyopaque, args: Args) R {
                    const e: *Env = @ptrCast(@alignCast(ctx));
                    return @call(.auto, Env.invoke, .{e} ++ args);
                }
                fn dropEnv(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                    const e: *Env = @ptrCast(@alignCast(ctx));
                    dropFields(e);
                    allocator.destroy(e);
                }
            };
            return .{ .ctx = env, .invoke_fn = erased.invoke, .drop_fn = erased.dropEnv, .allocator = defaultAllocator() };
        }

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<closure>");
        }

        pub fn invoke(self: *Self, args: Args) R {
            return self.invoke_fn(self.ctx, args);
        }

        pub fn __rig_drop(self: *Self) void {
            self.drop_fn(self.ctx, self.allocator);
        }
    };
}

/// `*sub()`: what a Signal notifies.
pub const Callback = Closure(&.{}, void);

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

        pub fn init(value: T) Self {
            return .{ .value = value, .subs = .init(defaultAllocator()) };
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

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeList(w, self.items());
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

        /// Remove and return the last element; the caller owns it.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
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

/// `s[i]` for a string or slice: the element at `i`, with `s` evaluated
/// once; panics when out of range.
pub fn at(items: anytype, i: anytype) std.meta.Elem(@TypeOf(items)) {
    return items[index(i, items.len)];
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

// Allocation. Debug builds check for leaks: every allocation goes through
// `LeakChecker`, which records each live block's address and size (no
// stack traces, so it costs a hash-map update per allocation). At exit a
// leak is reported with its count and size, and a double or mismatched
// free panics. Built with `RIG_LEAK_TRACE=1`, the emitted root module
// declares `__rig_leak_trace`, and the checker sits on Zig's
// `DebugAllocator`, which prints the stack trace of every leaked
// allocation (and of double frees) at the cost of capturing one per
// allocation. Release builds allocate from `smp_allocator` directly.

const builtin = @import("builtin");
const root = @import("root");
const leak_checked = builtin.mode == .Debug;
const leak_trace = leak_checked and @hasDecl(root, "__rig_leak_trace") and root.__rig_leak_trace;

var trace_allocator: std.heap.DebugAllocator(.{}) = .init;
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
        // Under RIG_LEAK_TRACE, let DebugAllocator report a bad free
        // with its stack traces first.
        if (leak_trace and !self.live.contains(@intFromPtr(memory.ptr))) backing().rawFree(memory, alignment, ret_addr);
        _ = self.entry(memory);
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.bytes -= memory.len;
        backing().rawFree(memory, alignment, ret_addr);
    }
};

/// Live allocations and their total size (Debug builds; zero otherwise).
pub const Usage = struct { count: usize, bytes: usize };

pub fn usage() Usage {
    return .{ .count = leak_checker.live.count(), .bytes = leak_checker.bytes };
}

/// Report the allocations live now beyond `before`; true when there are any.
fn reportLeaks(before: Usage) bool {
    if (!leak_checked) return false;
    const now = usage();
    if (now.count <= before.count) return false;
    const n = now.count - before.count;
    std.debug.print("error: rig: memory leak detected: {d} allocation{s} ({d} bytes) never freed\n", .{
        n, if (n == 1) "" else "s", now.bytes - before.bytes,
    });
    if (!leak_trace) std.debug.print("note: build with RIG_LEAK_TRACE=1 set (`RIG_LEAK_TRACE=1 rig run ...`) to see where each was allocated\n", .{});
    return true;
}

/// Deferred first in the emitted `main`, so it runs after all of `main`'s
/// drops: flush `print` output, then exit non-zero if anything leaked, so
/// a leaking program never passes.
pub fn finish() void {
    flush();
    if (!reportLeaks(.{ .count = 0, .bytes = 0 })) return;
    if (leak_trace) _ = trace_allocator.deinit();
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
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.File.stdout();
        stdout_is_tty = file.isTty(io) catch false;
        stdout_writer = file.writerStreaming(io, &stdout_buffer);
    }
    return &stdout_writer.?.interface;
}

/// Write out everything `print` has buffered.
pub fn flush() void {
    if (stdout_writer) |*w| w.interface.flush() catch {};
}

/// `print(a, b, ...)`: the values separated by single spaces, then a
/// newline.
pub fn print(args: anytype) void {
    const w = stdout();
    inline for (std.meta.fields(@TypeOf(args)), 0..) |f, i| {
        if (i > 0) w.writeAll(" ") catch {};
        writeValue(w, @field(args, f.name), true) catch {};
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
        try w.print("test \"{s}\"", .{self.name});
        if (self.module.len > 0) try w.print(" ({s})", .{self.module});
    }
};

var current_test: ?TestName = null;

/// Run every test, reporting each on stdout; exit 1 if any failed.
pub fn runTests(modules: []const TestModule) void {
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
            w.print("FAIL  {f}: error.{s}\n", .{ name, @errorName(err) }) catch {};
            failed += 1;
        }
        flush();
    };
    w.print("{d} passed, {d} failed\n", .{ passed, failed }) catch {};
    flush();
    if (failed > 0) std.process.exit(1);
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// The Rig name of a declared type: `main.Box(i64)` is `Box`.
fn rigTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const end = comptime std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const start = comptime if (std.mem.lastIndexOfScalar(u8, full[0..end], '.')) |d| d + 1 else 0;
    return full[start..end];
}

/// A value as Rig writes it: text as is at the top level and quoted
/// inside other values, `none` for an absent optional, `Name(field: v)`
/// for a struct, `.variant` / `.variant(payload)` for an enum, and
/// `[a, b]` for arrays and Vecs. A shared handle prints its value.
pub fn writeValue(w: *std.Io.Writer, value: anytype, top: bool) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) {
        return if (top) w.writeAll(value) else w.print("\"{s}\"", .{value});
    }
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .optional => if (value) |v| try writeValue(w, v, top) else try w.writeAll("none"),
        .pointer => |p| {
            if (comptime isStrongHandle(T)) return writeValue(w, value.value, top);
            if (p.size == .slice) return writeList(w, value);
            if (@typeInfo(p.child) == .@"fn") return w.writeAll("<fun>");
            return writeValue(w, value.*, top);
        },
        .array => try writeList(w, value),
        .@"enum" => try w.print(".{s}", .{@tagName(value)}),
        .error_set => try w.print(".{s}", .{@errorName(value)}),
        .@"union" => |u| {
            if (u.tag_type == null) return w.writeAll("?");
            switch (value) {
                inline else => |payload, tag| {
                    try w.print(".{s}", .{@tagName(tag)});
                    const P = @TypeOf(payload);
                    if (P == void) return;
                    if (@typeInfo(P) == .@"struct" and !@hasDecl(P, "__rig_print") and !isStrongHandle(P)) {
                        try w.writeAll("(");
                        try writeFields(w, payload);
                        return w.writeAll(")");
                    }
                    try w.writeAll("(");
                    try writeValue(w, payload, false);
                    try w.writeAll(")");
                },
            }
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
    inline for (std.meta.fields(@TypeOf(value)), 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: ", .{f.name});
        try writeValue(w, @field(value, f.name), false);
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
        pub fn invoke(self: *@This()) void {
            self.seen[self.n.*] = self.sig.value;
            self.n.* += 1;
            if (self.sig.value == 1) self.sig.set(2);
        }
    };
    var sig: Signal(i32) = .{ .value = 0, .subs = .init(testing.allocator) };
    defer sig.__rig_drop();
    var seen: [4]i32 = undefined;
    var n: usize = 0;
    const env = try testing.allocator.create(Env);
    env.* = .{ .sig = &sig, .seen = &seen, .n = &n };
    var closure = Callback.init(Env, env);
    closure.allocator = testing.allocator;
    const cb = try RcBox(Callback).new(testing.allocator, closure);
    sig.subscribe(cb);
    sig.set(1);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, seen[0..n]);
}

test "closures take any number of arguments and return values" {
    const Env = struct {
        base: i64,
        pub fn invoke(self: *@This(), a: i64, b: i64, c: bool) i64 {
            return if (c) self.base + a * b else self.base;
        }
    };
    const env = try testing.allocator.create(Env);
    env.* = .{ .base = 1 };
    var closure = Closure(&.{ i64, i64, bool }, i64).init(Env, env);
    closure.allocator = testing.allocator;
    defer closure.__rig_drop();
    try testing.expectEqual(7, closure.invoke(.{ 2, 3, true }));
    try testing.expectEqual(1, closure.invoke(.{ 2, 3, false }));
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

test "values print the way Rig writes them" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const P = struct { name: []const u8, n: ?i64 };
    const U = union(enum) { dot, circle: i64, rect: struct { w: i64, h: i64 } };
    try writeValue(&w, P{ .name = "a", .n = null }, true);
    try w.writeAll(" ");
    try writeValue(&w, U{ .rect = .{ .w = 2, .h = 3 } }, true);
    try w.writeAll(" ");
    try writeValue(&w, [_][]const u8{ "x", "y" }, true);
    try w.writeAll(" ");
    try writeValue(&w, @as(?[]const u8, "hi"), true);
    try testing.expectEqualStrings("P(name: \"a\", n: none) .rect(w: 2, h: 3) [\"x\", \"y\"] hi", w.buffered());
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
    try testing.expectEqual(before, usage());
}

test "dropping a long chain of boxes does not recurse per link" {
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
    for (0..100_000) |_| head = try RcBox(Link).new(testing.allocator, .{ .next = head, .drops = &drops });
    drop(&head);
    try testing.expectEqual(100_000, drops);
    try testing.expectEqual(0, drop_depth);
}

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

test "queued drops keep the order of a recursive release" {
    // A chain deep enough that the release of its last node is queued:
    // that node's fields drop last first, then its child's, and the
    // chain's own counter goes after them.
    const Tree = struct {
        next: ?*RcBox(@This()),
        a: ?*RcBox(Order),
        b: ?*RcBox(Order),
    };
    var log: [16]u8 = undefined;
    var n: usize = 0;
    for ([_]usize{ 10, max_drop_depth - 1, max_drop_depth, max_drop_depth + 5 }) |depth| {
        n = 0;
        const leaf_child = try RcBox(Tree).new(testing.allocator, .{
            .next = null,
            .a = try RcBox(Order).new(testing.allocator, .{ .log = &log, .n = &n, .id = 3 }),
            .b = try RcBox(Order).new(testing.allocator, .{ .log = &log, .n = &n, .id = 4 }),
        });
        var head: ?*RcBox(Tree) = try RcBox(Tree).new(testing.allocator, .{
            .next = leaf_child,
            .a = try RcBox(Order).new(testing.allocator, .{ .log = &log, .n = &n, .id = 1 }),
            .b = try RcBox(Order).new(testing.allocator, .{ .log = &log, .n = &n, .id = 2 }),
        });
        for (0..depth) |_| head = try RcBox(Tree).new(testing.allocator, .{ .next = head, .a = null, .b = null });
        drop(&head);
        try testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3 }, log[0..n]);
        try testing.expectEqual(0, drop_depth);
    }
}

test "a consuming loop left early drops the rest last first" {
    var log: [16]u8 = undefined;
    var n: usize = 0;
    var v: Vec(Order) = .init(testing.allocator);
    for (1..5) |i| v.push(.{ .log = &log, .n = &n, .id = @intCast(i) });
    var it = v.intoIter();
    var first = it.next().?;
    first.__rig_drop();
    it.deinit();
    try testing.expectEqualSlices(u8, &.{ 1, 4, 3, 2 }, log[0..n]);
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
