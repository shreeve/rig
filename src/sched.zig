//! The scheduler: Rig's tasks run as fibers, each on a stack of its own,
//! switched by saving and restoring the registers a call keeps
//! (`switchTo`), not by the operating system. One worker, the thread
//! that runs `main`, runs every fiber; `main` itself is the first
//! (`runMain`). A program selects it with `__rig_scheduler`
//! (`RIG_SCHEDULER=1` when `bin/rig` builds it); `bin/rig` writes this
//! file beside the runtime as `rig/sched.zig`.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime.zig");

/// A fiber: a task's own stack, and the stack pointer it left when it
/// last switched away, below the registers it saved there.
pub const Fiber = struct {
    sp: usize = 0,
    run: *const fn (*Fiber) void,
    stack: ?Stack = null,
    /// What the runtime keeps for the task (`rt.task`).
    state: rt.TaskState = .{},
    finished: bool = false,
    /// The next fiber in the run queue.
    next: ?*Fiber = null,
};

/// The worker: its own stack pointer while a fiber runs, the fiber
/// running, the queue of fibers ready to run, and stacks to reuse.
const Worker = struct {
    sp: usize = 0,
    current: ?*Fiber = null,
    head: ?*Fiber = null,
    tail: ?*Fiber = null,
    free: ?*FreeStack = null,

    fn push(w: *Worker, f: *Fiber) void {
        f.next = null;
        if (w.tail) |t| t.next = f else w.head = f;
        w.tail = f;
    }

    fn pop(w: *Worker) ?*Fiber {
        const f = w.head orelse return null;
        w.head = f.next;
        if (w.head == null) w.tail = null;
        return f;
    }
};

var worker: Worker = .{};

/// The fiber running, or none outside every fiber.
pub fn current() ?*Fiber {
    return worker.current;
}

/// Make `f` ready to run.
pub fn wake(f: *Fiber) void {
    worker.push(f);
}

/// Let every fiber ready to run go first, then go on.
pub fn yield() void {
    const f = worker.current.?;
    worker.push(f);
    switchTo(&f.sp, worker.sp);
}

/// Stop running until another fiber wakes this one (`wake`).
pub fn park() void {
    const f = worker.current.?;
    switchTo(&f.sp, worker.sp);
}

/// Run fibers until `main`'s ends: `run(arg)` as the first fiber, on the
/// stack whose top is `top`, the one `rt.onOwnStack` mapped. `guard` is
/// that stack's guard, for the overflow handler (`rt.TaskState`).
pub fn runMain(arg: *anyopaque, run: *const fn (*anyopaque) callconv(.c) void, top: usize, guard: rt.StackGuard) void {
    const Main = struct {
        fiber: Fiber,
        arg: *anyopaque,
        run: *const fn (*anyopaque) callconv(.c) void,

        fn start(f: *Fiber) void {
            const m: *@This() = @fieldParentPtr("fiber", f);
            m.run(m.arg);
        }
    };
    var m: Main = .{ .fiber = .{ .run = Main.start }, .arg = arg, .run = run };
    m.fiber.state.stack_guard = guard;
    m.fiber.sp = initialFrame(&m.fiber, top);
    worker.push(&m.fiber);
    while (!m.fiber.finished) {
        const f = worker.pop() orelse @panic("every task is waiting on another, so none can go on");
        worker.current = f;
        switchTo(&worker.sp, f.sp);
        worker.current = null;
        if (f.finished) if (f.stack) |s| {
            f.stack = null;
            releaseStack(s);
        };
    }
}

/// What a task's waiter shares with the fiber that runs it: whether it
/// has ended, the fiber waiting for it, and how to free the record.
pub const Header = struct {
    fiber: Fiber,
    done: bool = false,
    waiter: ?*Fiber = null,
    destroy: *const fn (*Header) void,
};

/// A task's record: its header and, once it has ended, its result.
pub fn Job(comptime T: type) type {
    return struct {
        header: Header,
        result: T = undefined,

        const Self = @This();

        /// Wait for the task to end and give its result. Waiting again
        /// gives the same result; the owner takes it once (`Task`).
        pub fn join(self: *Self) T {
            if (!self.header.done) {
                self.header.waiter = current().?;
                park();
            }
            return self.result;
        }

        pub fn free(self: *Self) void {
            self.header.destroy(&self.header);
        }
    };
}

/// Start `f(args...)` as a fiber, ready to run, and give its record.
pub fn spawn(comptime T: type, comptime f: anytype, args: anytype) *Job(T) {
    const Args = @TypeOf(args);
    const Full = struct {
        job: Job(T),
        args: Args,

        fn start(fiber: *Fiber) void {
            const h: *Header = @fieldParentPtr("fiber", fiber);
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            j.result = @call(.auto, f, full.args);
            h.done = true;
            if (h.waiter) |w| wake(w);
        }

        fn destroy(h: *Header) void {
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            std.heap.smp_allocator.destroy(full);
        }
    };
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .job = .{ .header = .{ .fiber = .{ .run = Full.start }, .destroy = Full.destroy } }, .args = args };
    const fiber = &full.job.header.fiber;
    const s = takeStack();
    fiber.stack = s;
    fiber.state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard };
    fiber.sp = initialFrame(fiber, s.top());
    wake(fiber);
    return &full.job;
}

// -----------------------------------------------------------------------------
// Stacks
// -----------------------------------------------------------------------------

/// A fiber's stack: `guard` bytes of inaccessible address space at
/// `base`, then the stack, then one inaccessible page, as
/// `rt.onTaskStack` maps a task's.
pub const Stack = struct {
    base: usize,
    guard: usize,
    len: usize,

    fn top(s: Stack) usize {
        return s.base + s.guard + s.len - rt.unwind_headroom;
    }
};

const FreeStack = struct { stack: Stack, next: ?*FreeStack };

/// A stack to run a fiber on: one a fiber that ended left, or a new one.
fn takeStack() Stack {
    if (worker.free) |n| {
        worker.free = n.next;
        const s = n.stack;
        std.heap.smp_allocator.destroy(n);
        return s;
    }
    const guard = rt.task_guard;
    const len = rt.task_stack_size;
    const got = std.posix.mmap(null, guard + len + std.heap.pageSize(), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch rt.oom();
    const base = @intFromPtr(got.ptr);
    if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(base + guard), len, .{ .READ = true, .WRITE = true })) != .SUCCESS) rt.oom();
    return .{ .base = base, .guard = guard, .len = len };
}

/// Keep a stack a fiber has finished with, for the next.
fn releaseStack(s: Stack) void {
    const n = std.heap.smp_allocator.create(FreeStack) catch rt.oom();
    n.* = .{ .stack = s, .next = worker.free };
    worker.free = n;
}

// -----------------------------------------------------------------------------
// Switching
// -----------------------------------------------------------------------------

/// The registers a call keeps, saved on the stack being left: on aarch64
/// x19..x30 and d8..d15, 160 bytes; on x86_64 rbx, rbp and r12..r15
/// under the return address.
const saved_bytes = switch (builtin.target.cpu.arch) {
    .aarch64 => 160,
    .x86_64 => 7 * 8,
    else => @compileError("rig: the scheduler runs on aarch64 and x86_64"),
};

/// Save the registers a call keeps on the stack running, store its
/// stack pointer in `from`, and resume the stack at `to`: the fiber or
/// the worker that saved it there, which returns from its own
/// `switchTo` (or, new, starts at `fiberStartNaked`).
fn switchNaked() callconv(.naked) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ sub sp, sp, #160
            \\ stp x19, x20, [sp, #0]
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ stp x29, x30, [sp, #80]
            \\ stp d8, d9, [sp, #96]
            \\ stp d10, d11, [sp, #112]
            \\ stp d12, d13, [sp, #128]
            \\ stp d14, d15, [sp, #144]
            \\ mov x2, sp
            \\ str x2, [x0]
            \\ mov sp, x1
            \\ ldp x19, x20, [sp, #0]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x29, x30, [sp, #80]
            \\ ldp d8, d9, [sp, #96]
            \\ ldp d10, d11, [sp, #112]
            \\ ldp d12, d13, [sp, #128]
            \\ ldp d14, d15, [sp, #144]
            \\ add sp, sp, #160
            \\ ret
        ),
        .x86_64 => asm volatile (
            \\ push %%rbp
            \\ push %%rbx
            \\ push %%r12
            \\ push %%r13
            \\ push %%r14
            \\ push %%r15
            \\ mov %%rsp, (%%rdi)
            \\ mov %%rsi, %%rsp
            \\ pop %%r15
            \\ pop %%r14
            \\ pop %%r13
            \\ pop %%r12
            \\ pop %%rbx
            \\ pop %%rbp
            \\ ret
        ),
        else => unreachable,
    }
}

/// Where a new fiber's first switch lands: the registers its frame was
/// made with hold the fiber (x19, rbx) and `fiberMain` (x20, r12).
fn fiberStartNaked() callconv(.naked) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, x19
            \\ blr x20
            \\ brk #0
        ),
        .x86_64 => asm volatile (
            \\ mov %%rbx, %%rdi
            \\ and $-16, %%rsp
            \\ call *%%r12
            \\ ud2
        ),
        else => unreachable,
    }
}

const SwitchFn = *const fn (from: *usize, to: usize) callconv(.c) void;

/// `switchNaked` as a function to call. The empty `asm` hides which
/// function the pointer names, so no optimizer inlines the naked body,
/// which takes its arguments in registers only a call sets.
fn switchTo(from: *usize, to: usize) void {
    var f: SwitchFn = @ptrCast(&switchNaked);
    asm volatile (""
        : [f] "+r" (f),
    );
    f(from, to);
}

/// A fiber's body: its `run`, then back to the worker for good.
fn fiberMain(f: *Fiber) callconv(.c) noreturn {
    f.run(f);
    f.finished = true;
    switchTo(&f.sp, worker.sp);
    unreachable;
}

/// The stack pointer a new fiber starts from, below `top`: a frame of
/// saved registers whose return address is `fiberStartNaked`.
fn initialFrame(f: *Fiber, top: usize) usize {
    const sp = (top & ~@as(usize, 15)) - saved_bytes;
    const slots: [*]usize = @ptrFromInt(sp);
    @memset(slots[0 .. saved_bytes / 8], 0);
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            slots[0] = @intFromPtr(f); // x19
            slots[1] = @intFromPtr(&fiberMain); // x20
            slots[11] = @intFromPtr(&fiberStartNaked); // x30
        },
        .x86_64 => {
            slots[3] = @intFromPtr(&fiberMain); // r12
            slots[4] = @intFromPtr(f); // rbx
            slots[6] = @intFromPtr(&fiberStartNaked); // the return address
        },
        else => unreachable,
    }
    return sp;
}

test "fibers switch, yield to each other in turn, and finish" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var log: [8]u8 = undefined;
        var n: usize = 0;
        fn note(c: u8) void {
            log[n] = c;
            n += 1;
        }
        fn a(_: *Fiber) void {
            note('a');
            yield();
            note('c');
        }
        fn b(_: *Fiber) void {
            note('b');
            yield();
            note('d');
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var fa: Fiber = .{ .run = a };
            var fb: Fiber = .{ .run = b };
            const sa = takeStack();
            const sb = takeStack();
            fa.sp = initialFrame(&fa, sa.top());
            fb.sp = initialFrame(&fb, sb.top());
            fa.stack = sa;
            fb.stack = sb;
            wake(&fa);
            wake(&fb);
            while (!fa.finished or !fb.finished) yield();
            note('e');
        }
    };
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    releaseStack(s);
    try std.testing.expectEqualStrings("abcde", Run.log[0..Run.n]);
}
