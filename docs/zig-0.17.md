# Zig 0.17 for Rig contributors

Rig is written in Zig 0.17 and compiles to Zig 0.17. This is a
reference for the parts of Zig that Rig work touches: the compiler
(`src/*.zig`), the runtime shipped with every program
(`src/runtime.zig`), the standard library's Zig shims (`std/*.zig`),
the Zig the emitter writes, `build.zig`, and the standard-library work
ahead (I/O, allocators, collections, strings, processes, files).

It is written for people and for AI agents whose knowledge of Zig
comes from earlier releases. Zig 0.17's I/O, containers, entry point,
reflection, allocators, and build system differ from those releases,
so Zig written from memory usually fails to compile. Each section gives
the 0.17 spelling. Every `zig` block here is a whole file that compiles
under Zig 0.17.0, with passing tests where it has them, except the
three alternative signatures of `main` in
[§4](#4-main-arguments-environment-processes), one per program.

When this document is silent, the installed standard library is the
authority:

```bash
zig env                                      # .std_dir is the standard library's source
grep -n 'pub fn readFileAlloc' "$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')/Io/Dir.zig"
zig test scratch.zig                         # try an API in a test block
```

The [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
cover everything this document leaves out.

## Contents

1. [Where Rig meets Zig](#1-where-rig-meets-zig)
2. [Reflexes from older Zig](#2-reflexes-from-older-zig)
3. [Io: the I/O interface](#3-io-the-io-interface)
4. [main, arguments, environment, processes](#4-main-arguments-environment-processes)
5. [Writers and readers](#5-writers-and-readers)
6. [Files and directories](#6-files-and-directories)
7. [Formatting](#7-formatting)
8. [Allocators](#8-allocators)
9. [Collections](#9-collections)
10. [Slices and strings](#10-slices-and-strings)
11. [Language and builtins](#11-language-and-builtins)
12. [Panics and debugging output](#12-panics-and-debugging-output)
13. [Tests](#13-tests)
14. [The build system](#14-the-build-system)
15. [Compile errors and their fixes](#15-compile-errors-and-their-fixes)
16. [Known Zig 0.17 issues Rig works around](#16-known-zig-017-issues-rig-works-around)

---

## 1. Where Rig meets Zig

| Place | Zig it depends on |
|---|---|
| `src/main.zig` (the CLI) | `pub fn main(init: std.process.Init)`, the process arena, `init.environ_map`, `std.Io.Dir.cwd().readFileAlloc`, `createFileAtomic`, buffered `std.Io.File.stdout()` writers, `Allocator.print`, `std.process.spawn` to run `zig` (`-Odebug`, `-Osafe`, `-Ofast`, and a `--cache-dir` per package) |
| `src/modules.zig` | `readFileAlloc`, `realPathFileAlloc`, `std.fs.path`, `Allocator.print` |
| `src/rig.zig` | `std.StaticStringMap` keyword tables |
| `src/sema.zig`, `resolve.zig`, `typecheck.zig`, `ownership.zig` | unmanaged `ArrayList` / `HashMap` with `.empty`, `ArenaAllocator`, `@backingInt` / `@fromBackingInt` |
| `src/emit.zig` | `std.Io.Writer.Allocating`, `Allocator.print` |
| `src/runtime.zig` | `std.heap.smp_allocator`, `std.heap.SafeAllocator`, a custom `std.mem.Allocator`, `std.Io.Threaded.global_single_threaded`, `std.process.Init.Minimal`, `std.debug.FullPanic`, `@typeInfo` reflection, `@Tuple`, `@Int` |
| `std/*.zig` | `std.mem.find*`, `std.fmt.parseInt` / `parseFloat`, `std.Io.Timestamp.now`, `io.sleep`, `io.random`, `init.environ.getPosix` |
| Emitted programs | `pub fn main(__rig_init: std.process.Init.Minimal) void` (`u8` for `fun main() -> Int`), `pub const panic = rig.panic;`, `anyerror!T`, `@divTrunc`, `@rem`, `@intCast`, `@floatFromInt`, `@trunc`, `@backingInt`, `@splat` |
| `build.zig` | `b.createModule`, `b.addExecutable(.{ .root_module = ... })`, `b.addOptions`, `b.addUpdateSourceFiles`, `b.installArtifact`, `run.addPassthruArgs()`, `b.addSystemCommand`, `b.addTest`, `b.root`, `b.graph.io` |

## 2. Reflexes from older Zig

The left column is what memory of earlier Zig suggests; none of it
compiles, or it compiles only as a deprecated spelling.

| Pre-0.17 reflex | Zig 0.17 |
|---|---|
| `var list = std.ArrayList(T).init(gpa);` | `var list: std.ArrayList(T) = .empty;` and pass `gpa` to every call that allocates (§9) |
| `std.ArrayListUnmanaged(T)`, `list.getLast()` | `std.ArrayList(T)`, `list.last().?` (§9) |
| `list.writer()` to build a string | `var out: std.Io.Writer.Allocating = .init(gpa);` then `out.writer.print(...)` (§5) |
| `std.fmt.allocPrint(gpa, fmt, args)` | `gpa.print(fmt, args)` (§8) |
| `std.fmt.bufPrint(&buf, fmt, args)` | `std.mem.print(&buf, fmt, args)` (§7) |
| `std.io.getStdOut().writer()` | `std.Io.File.stdout().writerStreaming(io, &buf)`, then `.interface`, then `flush()` (§5) |
| `std.io.fixedBufferStream(buf)` | `std.Io.Writer.fixed(buf)` / `std.Io.Reader.fixed(bytes)` |
| `std.fs.cwd()`, `std.fs.File`, `std.fs.Dir` | `std.Io.Dir.cwd()`, `std.Io.File`, `std.Io.Dir`; most methods take `io` (§6) |
| `file.close()` | `file.close(io)` |
| `file.writeAll(bytes)` | `file.writeStreamingAll(io, bytes)` |
| `dir.readFileAlloc(gpa, path, max)` | `dir.readFileAlloc(io, path, gpa, .limited(max))`; too big is `error.StreamTooLong` |
| `std.process.argsAlloc(gpa)` | `init.minimal.args.toSlice(init.arena.allocator())` (§4) |
| `std.process.getEnvVarOwned`, `std.os.environ` | `init.environ_map.get("NAME")` |
| `std.process.Child.init(argv, gpa)` | `std.process.spawn(io, .{ .argv = argv, ... })`, `child.wait(io)` |
| `.Exited`, `.Signal` on a child's `Term` | `.exited`, `.signal`, `.stopped`, `.unknown` |
| `std.heap.GeneralPurposeAllocator(.{}){}`, `std.heap.DebugAllocator(.{})` | `std.heap.SafeAllocator`: `.init(std.heap.page_allocator, .{})` (§8) |
| `if (da.deinit() == .leak)` | `if (sa.deinit() != 0)`: `deinit` returns the number of leaks |
| `pub fn format(self, comptime fmt, options, writer)` | `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`, printed with `{f}` (§7) |
| `"{}"` for a string or an optional | `"{s}"` for strings, `"{?}"` or `"{any}"` for optionals |
| `std.fmt.format(writer, ...)` | `writer.print(...)` |
| `std.mem.indexOf*`, `lastIndexOf*` | `std.mem.find*`, `findLast*` (§10) |
| `std.mem.trimLeft` / `trimRight` | `std.mem.trimStart` / `trimEnd` |
| `std.DynamicBitSetUnmanaged`, `std.StaticBitSet(n)` | `std.bit_set.Dynamic`, `std.bit_set.Static(n)` (§9) |
| `"-" ** 40`, `[_]u8{0} ** 16` | `const rule: [40]u8 = @splat('-');`, `const zeros: [16]u8 = @splat(0);` (§11) |
| `@intFromEnum(e)` / `@enumFromInt(n)` | `@backingInt(e)` / `@fromBackingInt(n)` (§11) |
| `@Type(.{ .int = ... })`, `std.meta.Int`, `std.meta.Tuple` | `@Int(.unsigned, 10)`, `@Tuple(&.{ A, B })`, and the other type builtins (§11) |
| `@typeInfo(T).@"struct".fields`, `std.meta.fields(T)` | `@typeInfo(T).@"struct".field_names` / `field_types` / `field_attrs` (§11) |
| `std.builtin.Type`, `std.builtin.Endian` | `std.lang.Type`, `std.lang.Endian` (§11) |
| `builtin.mode == .Debug`, `.ReleaseSafe`, `.ReleaseFast` | `builtin.optimize == .debug`; the modes are `.debug`, `.safe`, `.fast`, `.small` |
| `builtin.os.tag`, `builtin.cpu.arch` | `builtin.target.os.tag`, `builtin.target.cpu.arch` |
| `std.debug.runtime_safety` | `builtin.optimize.runtimeSafety()` |
| `zig run -OReleaseFast`, `-Doptimize=ReleaseSafe` | `zig run -Ofast`, `-Doptimize=safe` |
| `errdefer \|err\| log(err);` | catch at the call site: `inner() catch \|err\| { log(err); return err; };` |
| `@cImport({ @cInclude("x.h"); })` | translate the header in `build.zig` (§14) |
| `if (b.args) \|args\| run.addArgs(args);` | `run.addPassthruArgs();` (§14) |
| `b.build_root`, `b.install_path` | `b.root`; install paths are not visible to `build.zig` (§14) |
| `std.time.Timer`, `std.time.milliTimestamp()` | `std.Io.Clock.Timestamp.now(io, .awake)` (§3) |
| `std.Thread.Mutex`, `std.Thread.Pool` | `std.Io.Mutex`; `io.async` / `std.Io.Group` |
| `/// doc comment` before a `test` | a plain `//` comment |

---

## 3. Io: the I/O interface

Everything that blocks or observes the outside world (files,
directories, processes, clocks, sleeping, entropy, locks, networking)
goes through a `std.Io` value. It is passed around like an allocator:
functions that do I/O take an `io: std.Io` parameter, and the program
chooses the implementation once, at the top.

Where an `Io` comes from:

| Context | Io |
|---|---|
| a program whose `main` takes `std.process.Init` | `init.io` (an `Io.Threaded`; the Rig CLI uses this) |
| a test | `std.testing.io` |
| `build.zig` | `b.graph.io` |
| code with no `Io` to hand, for leaf system calls only | `std.Io.Threaded.global_single_threaded.io()` |

`global_single_threaded` is what `src/runtime.zig` uses (`rig.io()`),
because an emitted program's `main` takes `std.process.Init.Minimal`,
which carries no `Io`. It is built from
`Threaded.init_single_threaded`, whose allocator is
`std.mem.Allocator.failing` and which supports no concurrency or
cancelation. Plain file reads and writes, `isTty`, clocks, sleeping,
entropy, and similar leaf calls work through it. Anything that
allocates through the `Io` (spawning a child process, for one, which
builds its argv and environment blocks that way) fails with
`error.OutOfMemory`. Thread a real `Io` to code that spawns processes
or runs tasks concurrently.

```zig
const std = @import("std");

test "the process-wide single-threaded Io" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed.raw.toNanoseconds() > 0);

    const wall = std.Io.Timestamp.now(io, .real); // what std/time.zig reads
    try std.testing.expect(wall.nanoseconds > 0);

    var bytes: [8]u8 = undefined;
    io.random(&bytes); // what std/random.zig reads
}
```

Time lives under `std.Io`: `std.time` keeps only unit constants
(`std.time.ns_per_ms` and the like) and the `epoch` helpers. Use
`Io.Clock.Timestamp.now(io, .awake)` (or `std.Io.Clock.awake.now(io)`)
for intervals and `.real` for wall-clock time; `io.sleep(duration,
.awake)` sleeps. Entropy is `io.random(&buf)` (or
`try io.randomSecure(&buf)` for cryptographic use). Locks are
`std.Io.Mutex`, `std.Io.Condition`, `std.Io.Event`, and friends, and
concurrency is `io.async(func, args)` / `std.Io.Group`. Rig's standard
library uses the clocks, `sleep`, and `random`; it uses no locks or
concurrency.

---

## 4. main, arguments, environment, processes

### Three shapes of main

```zig
pub fn main() !void {}                                            // nothing provided
pub fn main(init: std.process.Init.Minimal) !void { _ = init; }   // argv and environ only
pub fn main(init: std.process.Init) !void { _ = init; }           // "juicy" main
```

`main` may also return `void`, `u8` (the exit status), or an error
union of either.

`std.process.Init` gives the program:

| Field | What it is |
|---|---|
| `init.io` | an `Io.Threaded` for the process |
| `init.gpa` | a general-purpose allocator: a `SafeAllocator` in debug and safe builds; in fast and small builds, `c_allocator` when libc is linked, else `smp_allocator` |
| `init.arena` | a `*std.heap.ArenaAllocator` freed when `main` returns |
| `init.environ_map` | `*std.process.Environ.Map`, the environment |
| `init.minimal.args` | the command line (`std.process.Args`) |
| `init.preopens` | WASI preopened files (void elsewhere) |

The Rig CLI is a short-lived compiler, so it allocates everything from
`init.arena` and never frees. That is also much faster in debug builds
than `init.gpa` (see [§8](#8-allocators)).

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena); // []const [:0]const u8; args[0] is the program
    const home = init.environ_map.get("HOME") orelse "(unset)";

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    try w.print("{d} argument(s); HOME={s}\n", .{ args.len - 1, home });
    try w.flush();
}
```

`init.minimal.args.iterate()` walks the arguments without allocating
on POSIX systems (`iterateAllocator` is the portable form). A function
that needs the environment takes a `*const std.process.Environ.Map`
rather than reading a global: there is no `std.os.environ` and no
`std.posix.getenv`.

An emitted program's `main` takes `std.process.Init.Minimal` and hands
it to `rig.start`, which keeps it in `rig.process` for the standard
library: `init.args.vector` is the argument vector on POSIX systems
(`[]const [*:0]const u8`), and `init.environ.getPosix("NAME")` reads
one variable without allocating (`std/os.zig` uses it).

```zig
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) void {
    for (init.args.vector) |arg| std.debug.print("{s}\n", .{std.mem.sliceTo(arg, 0)});
    std.debug.print("HOME={s}\n", .{init.environ.getPosix("HOME") orelse "(unset)"});
}
```

Returning an error from `main` logs it (`error: FileNotFound`), dumps
the error return trace in debug builds, and exits 1. Leaks that
`init.gpa` reports at exit print a stack trace for each but do not
change the exit status. `std.process.exit(code)` exits immediately
without running `defer`s, so flush buffered writers first.
`std.process.fatal(fmt, args)` logs an error and exits 1.

### Running a child process

```zig
const std = @import("std");

test "spawn a child and wait for it" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 3" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, term);
}

test "run a child and capture its output" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ "echo", "hi" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("hi\n", result.stdout);
    try std.testing.expect(result.term.success());
}
```

`Term` is `union(enum) { exited: u8, signal: std.posix.SIG, stopped:
std.posix.SIG, unknown: u32 }`; `term.success()` is true for an exit
status of 0. A missing executable is `error.FileNotFound` from `spawn`.
The `.exe` option chooses how the executable is found (`.detect` by
default, `.search` on `PATH`, `.path` relative to a `std.Io.Dir`).
`std.process.replace(io, .{ .argv = argv })` replaces the running
program (`execv`); `std.process.currentPathAlloc(io, gpa)` returns the
working directory.

---

## 5. Writers and readers

The stream interfaces are two concrete types, `std.Io.Writer` and
`std.Io.Reader`. Each is a struct holding a **buffer** and a vtable;
the buffer belongs to whoever created the writer, and nothing reaches
the underlying file until the buffer fills or `flush()` is called.
Functions take `w: *std.Io.Writer` (not `anytype`), and the error set
is `std.Io.Writer.Error` (`error{WriteFailed}`); the underlying cause,
if needed, is kept by the concrete writer (`file_writer.err`).

### Writing to stdout and stderr

A file writer (`std.Io.File.Writer`) wraps a file and a buffer; its
`interface` field is the `std.Io.Writer` to pass around. Take the
address of the field, never copy it: the vtable finds the file writer
from the interface's address.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const w = &out.interface; // not `const w = out.interface;`
    try w.print("{s} {d}\n", .{ "answer", 42 });
    try w.writeAll("done\n");
    try w.flush(); // nothing is written until here
}
```

`file.writer(io, &buf)` starts in positional mode (it `pwrite`s at an
offset and falls back to streaming); `file.writerStreaming(io, &buf)`
writes at the current position. Use `writerStreaming` for stdout,
stderr, and pipes, as Rig does. For one unbuffered write,
`try std.Io.File.stdout().writeStreamingAll(io, bytes)`.

The runtime keeps one process-wide stdout writer with an 8 KiB buffer,
flushed when the program finishes, before a panic message, and after
every `print` when stdout is a terminal (`file.isTty(io)`).

### Building a string: `Writer.Allocating`

`std.Io.Writer.Allocating` is a writer that grows a heap buffer. Its
`writer` is a **field**, not a method. The emitter writes each module
through one of these.

```zig
const std = @import("std");

fn header(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try w.print("// module {s}\n", .{name});
}

test "Writer.Allocating" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try header(&out.writer, "main");
    try out.writer.writeAll("const x = 1;\n");
    try std.testing.expectEqualStrings("// module main\nconst x = 1;\n", out.written());

    const owned = try out.toOwnedSlice(); // out is empty again
    defer gpa.free(owned);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
```

`written()` returns a view of the current contents; the slice is
invalid after the next write. `toOwnedSlice()` hands the bytes over and
resets the writer. `.fromArrayList(gpa, &list)` and `toArrayList()`
move the bytes in and out of an `ArrayList(u8)` (`rig.Text` appends
that way). For small strings, `gpa.print(fmt, args)` returns a new
`[]u8` directly, and `list.print(gpa, fmt, args)` appends formatted
text to an `ArrayList(u8)`.

### Fixed buffers

```zig
const std = @import("std");

test "fixed writer and reader" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{d}-{d}", .{ 1, 2 });
    try std.testing.expectEqualStrings("1-2", w.buffered());
    const too_long: [40]u8 = @splat('x');
    try std.testing.expectError(error.WriteFailed, w.writeAll(&too_long));

    var r: std.Io.Reader = .fixed("alpha\nbeta\n");
    try std.testing.expectEqualStrings("alpha", (try r.takeDelimiter('\n')).?);
    try std.testing.expectEqualStrings("beta", (try r.takeDelimiter('\n')).?);
    try std.testing.expectEqual(null, try r.takeDelimiter('\n'));
}
```

`std.mem.print(&buf, fmt, args)` formats into a buffer and returns
the used slice, or `error.NoSpaceLeft`.

### Readers

A file reader works the same way: `var fr = file.reader(io, &buf);`
then use `&fr.interface`. Useful `std.Io.Reader` calls:

| Call | Result |
|---|---|
| `r.takeDelimiter('\n')` | the next line without the newline, `null` at the end; `error.StreamTooLong` if a line exceeds the buffer |
| `r.takeByte()`, `r.peekByte()` | one byte; `error.EndOfStream` at the end |
| `r.take(n)` | the next `n` bytes, a slice of the reader's buffer |
| `r.allocRemaining(gpa, .limited(n))` | everything left, as an owned slice; up to and including `n` bytes |
| `r.streamRemaining(w)` | copy everything left to a writer |

### `std.Io.Limit`

APIs that read "up to some amount" take a `std.Io.Limit` rather than a
`usize`: `.limited(n)`, `.unlimited`, or `.nothing`. Exceeding it is
`error.StreamTooLong`. The two whole-input readers draw the line
differently: `Reader.allocRemaining` accepts exactly `n` bytes, while
`Dir.readFileAlloc` rejects a file of exactly `n` bytes (§6).

---

## 6. Files and directories

`std.fs` holds only `std.fs.path` and a few constants. Files and
directories are `std.Io.File` and `std.Io.Dir`, and nearly every
method takes `io` right after the receiver.

```zig
const std = @import("std");

test "files through Io.Dir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir; // a std.Io.Dir; std.Io.Dir.cwd() is the working directory

    // Write a whole file.
    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });

    // Read a whole file, capped; the cap must exceed the file's size.
    const text = try dir.readFileAlloc(io, "a.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello\n", text);
    try std.testing.expectError(error.StreamTooLong, dir.readFileAlloc(io, "a.txt", gpa, .limited(6)));

    // Create, write through a buffered writer, close.
    {
        var file = try dir.createFile(io, "b.txt", .{});
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.print("{d}\n", .{123});
        try fw.interface.flush();
    }

    // Open and read through a reader.
    {
        var file = try dir.openFile(io, "b.txt", .{});
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var fr = file.reader(io, &buf);
        try std.testing.expectEqualStrings("123", (try fr.interface.takeDelimiter('\n')).?);
    }

    // Directories, existence, deletion.
    try dir.createDirPath(io, "x/y/z");
    try dir.access(io, "x/y/z", .{});
    try dir.deleteFile(io, "a.txt");
    try std.testing.expectError(error.FileNotFound, dir.access(io, "a.txt", .{}));
}
```

### Replacing a file atomically

`src/main.zig` writes every emitted file this way, so a concurrent
build never reads a half-written file:

```zig
const std = @import("std");

fn writeAtomically(io: std.Io, dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    var file = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, contents);
    try file.replace(io); // with .replace = false, call file.link(io) instead
}

test writeAtomically {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomically(std.testing.io, tmp.dir, "out/pkg/main.zig", "const a = 1;\n");
    var buf: [64]u8 = undefined;
    const got = try tmp.dir.readFile(std.testing.io, "out/pkg/main.zig", &buf);
    try std.testing.expectEqualStrings("const a = 1;\n", got);
}
```

### Other operations

| Need | Call |
|---|---|
| make directories | `dir.createDir(io, p, perms)`, `dir.createDirPath(io, p)`, `dir.createDirPathOpen(io, p, .{})` |
| the real path of a file | `dir.realPathFileAlloc(io, p, gpa)` (returns `[:0]u8`) |
| read or write at the current position | `file.readStreaming(io, &.{buf})`, `file.writeStreamingAll(io, bytes)` |
| read or write at an offset | `file.readPositional(io, &.{buf}, offset)`, `file.writePositionalAll(io, bytes, offset)` |
| size | `file.length(io)`, `file.setLength(io, n)`, `file.stat(io)` (`.size`, `.kind`, `.mtime`) |
| seek | on the reader or writer: `fr.seekTo(n)`, `fr.logicalPos()` |
| the running executable | `std.process.executablePathAlloc(io, gpa)` |
| whether a file is a terminal | `file.isTty(io)` (can fail with `error.Canceled`) |

Paths are plain byte slices handled by `std.fs.path` (also reachable
as `std.Io.Dir.path`): `join`, `dirname`, `basename`, `extension`,
`resolve`, `isAbsolute`. `std.fs.path.relative(gpa, cwd, environ_map,
from, to)` takes the current directory and environment as arguments
and touches no files.

---

## 7. Formatting

`writer.print`, `std.debug.print`, `Allocator.print`, and
`std.mem.print` share one format language:
`{[argument][specifier]:[fill][alignment][width].[precision]}`.

| Specifier | For | Example → output |
|---|---|---|
| `{d}` | integers, floats, enums (their value) | `{d}` of `-7` → `-7`; `{d:.2}` of `3.14159` → `3.14` |
| `{s}` | `[]const u8`, `[*:0]const u8`, byte arrays | `{s}` of `"hi"` → `hi` |
| `{c}` | a byte as a character | `{c}` of `'A'` → `A` |
| `{u}` | a `u21` code point as UTF-8 | `{u}` of `'é'` → `é` |
| `{x}` `{X}` | integers in hex; byte slices as hex pairs | `{x}` of `255` → `ff`; `{x}` of `"AB"` → `4142` |
| `{b}` `{o}` | binary, octal | `{b}` of `5` → `101` |
| `{e}` | floats in scientific notation | `{e}` of `1234.5` → `1.2345e3` |
| `{t}` | an enum or tagged union's tag name, an error's name | `{t}` of `.red` → `red`; of `error.Oops` → `Oops` |
| `{q}` | a string as a Zig string literal, quoted and escaped | `{q}` of `"a\nb"` → `"a\nb"` |
| `{?}` `{?s}` | optionals: the payload or `null` | `{?d}` of `@as(?u8, null)` → `null` |
| `{!}` | error unions: the payload or the error | |
| `{f}` | calls the type's `format` method | see below |
| `{any}` | the default rendering of any value, skipping `format` | `{any}` of `.{ .x = 1 }` → `.{ .x = 1 }` |
| `{*}` | a pointer's address | |
| `{B}` `{Bi}` | a byte count in SI or IEC units | `{Bi}` of `2048` → `2KiB` |

With no specifier, `{}` prints numbers, bools, enums (`.red`), errors
(`error.Oops`), and structs (`.{ .x = 1 }`); strings need `{s}` and
optionals `{?}` or `{any}`. Only `{f}` calls a `format` method: `{}` and
`{any}` print a struct's fields even when it has one.

Width and fill pad any of these: `{d:>5}`, `{s:<10}`, `{d:0>4}`,
`{s:*^9}`. A string is right-aligned by default (`{s:10}`). Positional
and named arguments: `{0s} {1d} {0s}`, `{[name]s}` with
`.{ .name = "x" }`. Write `{{` and `}}` for literal braces.

```zig
const std = @import("std");

const Color = enum { red, green };

const Point = struct {
    x: i32,
    y: i32,

    pub fn format(p: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d}, {d})", .{ p.x, p.y });
    }
};

test "format specifiers" {
    var buf: [128]u8 = undefined;
    const e: anyerror = error.Oops;
    const none: ?u8 = null;
    const p: Point = .{ .x = 1, .y = -2 };
    const got = try std.mem.print(&buf, "{d:0>4}|{s:<4}|{x}|{t}|{t}|{?d}|{f}|{any}|{Bi}|{q}|{{}}", .{
        42, "ab", 255, Color.green, e, none, p, p, 2048, "a\nb",
    });
    try std.testing.expectEqualStrings("0042|ab  |ff|green|Oops|null|(1, -2)|.{ .x = 1, .y = -2 }|2KiB|\"a\\nb\"|{}", got);
}
```

A custom `format` method takes only the value and a `*std.Io.Writer`.
To offer several renderings of one type, return a `std.fmt.Alt`:

```zig
const std = @import("std");

const Name = struct {
    text: []const u8,

    fn quoted(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("\"{s}\"", .{text});
    }

    pub fn fmtQuoted(n: Name) std.fmt.Alt([]const u8, quoted) {
        return .{ .data = n.text };
    }
};

test "std.fmt.Alt" {
    var buf: [32]u8 = undefined;
    const n: Name = .{ .text = "rig" };
    try std.testing.expectEqualStrings("\"rig\"", try std.mem.print(&buf, "{f}", .{n.fmtQuoted()}));
    // std.zig.fmtString escapes a string for a Zig string literal:
    try std.testing.expectEqualStrings("a\\nb", try std.mem.print(&buf, "{f}", .{std.zig.fmtString("a\nb")}));
}
```

`std.fmt.Options` holds a placeholder's fill, alignment, width, and
precision. `std.fmt.allocPrint` and `std.fmt.bufPrint` are deprecated
wrappers of `Allocator.print` and `std.mem.print`.

---

## 8. Allocators

The interface is `std.mem.Allocator`: `alloc`, `free`, `create`,
`destroy`, `dupe`, `realloc`, `print` (format into a new allocation),
`dupeSentinel`. A custom allocator fills in a vtable of four functions,
each taking a `std.mem.Alignment` (an enum of log2 values, not a byte
count). The runtime's `LeakChecker` is one:

```zig
const std = @import("std");

/// Counts live allocations and forwards to a backing allocator.
const Counting = struct {
    backing: std.mem.Allocator,
    live: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += 1;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    /// Like resize, but may move the memory; null means "allocate, copy, free instead".
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.live -= 1;
    }
};

test Counting {
    var counting: Counting = .{ .backing = std.testing.allocator };
    const a = counting.allocator();
    const bytes = try a.alloc(u8, 100);
    const more = try a.realloc(bytes, 5000);
    try std.testing.expectEqual(@as(usize, 1), counting.live);
    a.free(more);
    try std.testing.expectEqual(@as(usize, 0), counting.live);
}
```

### Which allocator

| Allocator | Use |
|---|---|
| `std.heap.smp_allocator` | the fast general-purpose allocator for release builds; thread-safe, a global value (no setup, no deinit). The runtime's release-build allocator. |
| `std.heap.SafeAllocator` | the checking allocator: leaks with stack traces, double and mismatched frees, and most writes to freed memory. `var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});` then `sa.allocator()`; `sa.deinit()` logs every leak and returns their count. Thread-safe. |
| `std.heap.ArenaAllocator` | `.init(child)`, then `.allocator()`; frees everything at `deinit()`. Thread-safe when its child allocator is. Rig's compiler passes use arenas. |
| `std.heap.page_allocator` | whole pages from the OS; a backing allocator, not for small objects |
| `std.heap.c_allocator` | `malloc`; needs libc linked |
| `std.heap.FixedBufferAllocator` | `.init(&buf)`, allocates from a byte buffer |
| `std.heap.BufferFirstAllocator` | `.init(&buf, fallback)`: allocates from a buffer, then from the fallback |
| `std.testing.allocator` | a `SafeAllocator` in tests; a leak fails the test |
| `std.testing.failing_allocator`, `std.testing.FailingAllocator` | fail allocation (after N successes) to test `error.OutOfMemory` paths |

```zig
const std = @import("std");

test "SafeAllocator and Allocator.print" {
    var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = sa.allocator();
    {
        const s = try gpa.print("{s}={d}", .{ "x", 1 });
        defer gpa.free(s);
        try std.testing.expectEqualStrings("x=1", s);
        const z = try gpa.dupeSentinel(u8, "hi", 0);
        defer gpa.free(z);
    }
    try std.testing.expectEqual(@as(usize, 0), sa.deinit()); // the number of leaks
}
```

`SafeAllocator.Options` sets `stack_trace_frames` (7 in debug builds
where stack traces work, 0 otherwise), `check_write_after_free`, and a
`canary` that catches memory freed through the wrong instance.

**`SafeAllocator` is slow in debug builds.** Each allocation and free
captures a stack trace and carries a footer of metadata. In a debug
build on aarch64-macos, allocating and freeing 200,000 small blocks
takes about 6 seconds through a `SafeAllocator` with its default
options, about 60 ms with `.stack_trace_frames = 0`, and under 10 ms
through `smp_allocator` or an arena. This is why the Rig CLI allocates
from `init.arena` instead of `init.gpa`, and why the runtime's debug
leak checker records only address and size, keeps its table in
`smp_allocator`, and sits on a `SafeAllocator` only when
`RIG_LEAK_TRACE=1` asks for stack traces.

---

## 9. Collections

### ArrayList is unmanaged

`std.ArrayList(T)` does not store an allocator. Initialize it with
`.empty` (its fields have no defaults, so `.{}` does not compile), and
pass the allocator to every call that may allocate and to `deinit`.
`std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList`
(much of `src/` spells it that way), and `std.array_list.Managed` is a
deprecated variant that stores its allocator.

```zig
const std = @import("std");

const Module = struct {
    names: std.ArrayList([]const u8) = .empty, // not `= .{}`
};

test "ArrayList" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 1);
    try list.appendSlice(gpa, &.{ 2, 3, 4 });
    try list.ensureUnusedCapacity(gpa, 1);
    list.appendAssumeCapacity(5);
    try list.insert(gpa, 0, 0);
    _ = list.orderedRemove(1);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4, 5 }, list.items);
    try std.testing.expectEqual(@as(?u32, 5), list.pop());
    try std.testing.expectEqual(@as(?u32, 4), list.last());
    if (list.lastPtr()) |p| p.* += 1;
    try std.testing.expectEqual(@as(u32, 5), list.last().?);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.print(gpa, "{d}+{d}", .{ 1, 2 });
    try std.testing.expectEqualStrings("1+2", text.items);

    var m: Module = .{};
    defer m.names.deinit(gpa);
    try m.names.append(gpa, "main");

    const owned = try list.toOwnedSlice(gpa); // list is empty again
    defer gpa.free(owned);
}
```

In debug and safe builds a list also carries pointer-stability state:
`list.lockPointers()` and `list.unlockPointers()` make any operation
that could move or free the items panic while locked.

### Hash maps

`std.AutoHashMapUnmanaged(K, V)`, `std.StringHashMapUnmanaged(V)`, and
`std.HashMapUnmanaged(K, V, Context, max_load)` follow the same rules:
`.empty`, allocator on `put`, `getOrPut`, `ensureTotalCapacity`, and
`deinit`; none on `get`, `getPtr`, `contains`, `remove`, `count`, or
`iterator`. The managed `std.AutoHashMap` and `std.StringHashMap` also
exist. A string-keyed map does not copy its keys: they must outlive
the map (Rig keeps them in an arena).

```zig
const std = @import("std");

test "hash maps" {
    const gpa = std.testing.allocator;
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    defer ids.deinit(gpa);

    try ids.put(gpa, "a", 1);
    const gop = try ids.getOrPut(gpa, "b");
    if (!gop.found_existing) gop.value_ptr.* = 2;
    try std.testing.expectEqual(@as(?u32, 2), ids.get("b"));
    try std.testing.expect(ids.remove("a"));

    var it = ids.iterator();
    while (it.next()) |entry| try std.testing.expectEqualStrings("b", entry.key_ptr.*);

    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(gpa);
    try seen.put(gpa, 7, {});
    try std.testing.expect(seen.contains(7));
}
```

Insertion-ordered maps are `std.array_hash_map.Auto(K, V)`,
`.String(V)`, and `.Custom(...)`, all unmanaged; the
`std.AutoArrayHashMapUnmanaged` family names are deprecated aliases.
Removal must choose an order: `swapRemove` or `orderedRemove`.

### Compile-time string maps

```zig
const std = @import("std");

const Keyword = enum { kw_if, kw_else, kw_while };

const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
});

const reserved = std.StaticStringMap(void).initComptime(.{ .{"std"}, .{"rig"} });

test "StaticStringMap" {
    try std.testing.expectEqual(Keyword.kw_else, keywords.get("else").?);
    try std.testing.expectEqual(null, keywords.get("elif"));
    try std.testing.expect(reserved.has("rig"));
}
```

### Others

```zig
const std = @import("std");

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

test "other containers" {
    const gpa = std.testing.allocator;

    var bits: std.bit_set.Dynamic = try .initEmpty(gpa, 100);
    defer bits.deinit(gpa);
    bits.set(42);
    try std.testing.expect(bits.isSet(42));

    var small: std.bit_set.Static(64) = .empty; // also `.full`
    small.set(3);
    try std.testing.expectEqual(@as(usize, 1), small.count());

    var dq: std.Deque(u32) = .empty;
    defer dq.deinit(gpa);
    try dq.pushBack(gpa, 1);
    try dq.pushFront(gpa, 0);
    try std.testing.expectEqual(@as(?u32, 0), dq.popFront());

    var pq: std.PriorityQueue(u32, void, lessThan) = .empty;
    defer pq.deinit(gpa);
    try pq.push(gpa, 5);
    try pq.push(gpa, 2);
    try std.testing.expectEqual(@as(?u32, 2), pq.pop());

    // A fixed-capacity list over a buffer.
    var buf: [4]u8 = undefined;
    var bounded: std.ArrayList(u8) = .initBuffer(&buf);
    try bounded.appendSliceBounded("abcd");
    try std.testing.expectError(error.OutOfMemory, bounded.appendBounded('e'));
}
```

- `std.MultiArrayList(T)`, `std.EnumMap`, `std.EnumSet`,
  `std.SinglyLinkedList` and `std.DoublyLinkedList` (intrusive: embed a
  `Node` in your struct and use `@fieldParentPtr`).
- Sorting: `std.mem.sort(T, items, context, lessThan)` (stable) and
  `std.mem.sortUnstable`; `std.sort.asc(T)` and `std.sort.desc(T)` give
  `lessThan` functions.

---

## 10. Slices and strings

Strings are `[]const u8`. `std.mem` works on slices of any element
type `T`.

| Need | Call |
|---|---|
| equality, prefix, suffix | `std.mem.eql(u8, a, b)`, `startsWith`, `endsWith` |
| find | `std.mem.find(u8, s, "x")`, `findScalar(u8, s, 'x')`, `findAny`, `findLast`, `findScalarLast`, `findPos` (`indexOf*` / `lastIndexOf*` are deprecated aliases) |
| split once | `std.mem.cut(u8, s, "=")` → `?struct { []const u8, []const u8 }`; also `cutScalar`, `cutLast`, `cutPrefix`, `cutSuffix` |
| split into parts | `std.mem.splitScalar(u8, s, ',')`, `splitSequence`, `splitAny` (keep empty fields); `tokenizeScalar`, `tokenizeAny` (skip them) |
| trim | `std.mem.trim(u8, s, " \t")`, `trimStart`, `trimEnd` |
| join, concatenate | `std.mem.join(gpa, ", ", parts)`, `std.mem.concat(gpa, u8, &.{ a, b })` |
| replace, count | `std.mem.replaceOwned(u8, gpa, s, "a", "b")`, `std.mem.count(u8, s, "a")` |
| at least `n` copies | `std.mem.containsAtLeastScalar(u8, s, 'a', n)` (element, then count) |
| format into a buffer | `std.mem.print(&buf, fmt, args)`, `std.mem.printSentinel(&buf, fmt, args, 0)` |
| characters | `std.ascii.isDigit`, `isAlphabetic`, `isAlphanumeric`, `isWhitespace`, `isHex`, `toLower` |
| numbers from text | `std.fmt.parseInt(i64, s, 10)` (base 0 reads `0x`/`0o`/`0b`; allows `_`), `std.fmt.parseFloat(f64, s)` |
| enum from text | `std.meta.stringToEnum(E, s)` |
| UTF-8 | `std.unicode.utf8ValidateSlice`, `std.unicode.Utf8View` |

```zig
const std = @import("std");

test "strings" {
    const line = "  key = value  ";
    const trimmed = std.mem.trim(u8, line, " ");
    const key, const value = std.mem.cutScalar(u8, trimmed, '=').?;
    try std.testing.expectEqualStrings("key", std.mem.trimEnd(u8, key, " "));
    try std.testing.expectEqualStrings("value", std.mem.trimStart(u8, value, " "));

    try std.testing.expectEqual(@as(?usize, 2), std.mem.find(u8, "a.b.c", "b"));
    try std.testing.expectEqual(@as(?usize, 3), std.mem.findScalarLast(u8, "a.b.c", '.'));
    try std.testing.expect(std.mem.containsAtLeastScalar(u8, "aab", 'a', 2));

    var parts = std.mem.splitScalar(u8, "a,,b", ',');
    try std.testing.expectEqualStrings("a", parts.next().?);
    try std.testing.expectEqualStrings("", parts.next().?);
    var words = std.mem.tokenizeAny(u8, "  a  b ", " ");
    try std.testing.expectEqualStrings("a", words.next().?);
    try std.testing.expectEqualStrings("b", words.next().?);
    try std.testing.expectEqual(null, words.next());

    try std.testing.expectEqual(@as(i64, 255), try std.fmt.parseInt(i64, "0xff", 0));
    try std.testing.expectEqual(@as(i64, 1000), try std.fmt.parseInt(i64, "1_000", 10));
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(i8, "300", 10));

    const gpa = std.testing.allocator;
    const joined = try std.mem.join(gpa, ", ", &.{ "a", "b" });
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("a, b", joined);
}
```

---

## 11. Language and builtins

### Builtins

| Builtin | In Zig 0.17 |
|---|---|
| type-creating builtins | `@Int(.signed, 12)`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple(&.{ A, B })`, `@EnumLiteral()`; there is no `@Type`. Arrays, optionals, error unions, and floats use their own syntax (`[N]T`, `?T`, `E!T`, `std.meta.Float(64)`). Error sets cannot be reified. |
| `@backingInt(x)`, `@fromBackingInt(n)` | an enum's integer value and back, and a `packed struct(uN)` or `packed union(uN)`'s backing integer and back. `@fromBackingInt` takes its result type from context and needs an argument of exactly the backing type: `const e: E = @fromBackingInt(@intCast(n));`. An integer with no enum tag is safety-checked. `@intFromEnum` and `@enumFromInt` are deprecated spellings. Inside `raw`, Rig offers `@fromBackingInt` (integer to plain enum) and rejects `@enumFromInt`. |
| `@splat(x)` | an array or vector with every element `x`, typed by its result: `const s: [n]u8 = @splat('x');`, `@as([4]u8, @splat(0))`. There is no `**` repetition operator. |
| `@divCeil(a, b)` | division rounding toward positive infinity, for integers, floats, and vectors |
| `@intFromFloat(x)` | deprecated, equivalent to `@trunc`. `@trunc`, `@floor`, `@ceil`, and `@round` convert to an integer result type directly: `const n: i64 = @trunc(x);`. An out-of-range result is safety-checked; a NaN is not (§16). |
| `@floatFromInt(x)` | needed unless the integer type fits the float exactly: `u24` and smaller coerce to `f32` implicitly, 53-bit integers to `f64`. |
| `@sqrt`, `@sin`, `@floor`, ... | forward the result type: `const r: f64 = @sqrt(@floatFromInt(n));` |
| `@divTrunc`, `@divFloor`, `@rem`, `@mod`, `@intCast`, `@truncate`, `@bitCast`, `@ptrCast`, `@alignCast` | cast builtins take the result type from context (`const x: u8 = @intCast(n);`, or `@as(u8, @intCast(n))`). `@bitCast` works on logical bit representations (integers, floats, `enum(T)`, packed types, and arrays and vectors of these), never on `extern struct` or `extern union`. |
| C headers | there is no `@cImport`; a header is translated in `build.zig` (§14) |

```zig
const std = @import("std");

const Color = enum(u8) { red = 1, green = 2, blue = 4 };

test "type, enum, and float builtins" {
    const U12 = @Int(.unsigned, 12);
    try std.testing.expectEqual(12, @bitSizeOf(U12));

    const Pair = @Tuple(&.{ u8, bool });
    const p: Pair = .{ 1, true };
    try std.testing.expect(p[1]);

    try std.testing.expectEqual(@as(u8, 4), @backingInt(Color.blue));
    var n: usize = 2;
    _ = &n;
    const c: Color = @fromBackingInt(@intCast(n));
    try std.testing.expectEqual(Color.green, c);

    const rule: [3]u8 = @splat('-');
    try std.testing.expectEqualStrings("---", &rule);
    try std.testing.expectEqual(4, @divCeil(7, 2));

    var x: f64 = -2.7;
    _ = &x;
    const t: i64 = @trunc(x);
    const r: i64 = @round(x);
    try std.testing.expectEqual(@as(i64, -2), t);
    try std.testing.expectEqual(@as(i64, -3), r);

    const small: u24 = 1000;
    const f: f32 = small; // implicit: every u24 is exact in an f32
    try std.testing.expectEqual(@as(f32, 1000), f);
}
```

### Reflection

`@typeInfo` returns a `std.lang.Type`, and every kind with fields,
parameters, or declarations describes them as parallel arrays: a
struct has `field_names`, `field_types`, `field_attrs` (each
`.@"comptime"`, `.@"align"`, `.defaultValue(T)`), and `decl_names`
(public declarations only); an enum has `field_names` and
`field_values`; a union has `field_names`, `field_types`, and
`field_attrs`. A function has `param_types` (null for `anytype`),
`param_attrs` (`.@"noalias"`), `return_type`, and `attrs`
(`.@"callconv"`, `.varargs`). A pointer has `size`, `child`, and
`attrs` (`.@"const"`, `.@"volatile"`, `.@"align"`, ...). An error set
has `error_names`, null for `anyerror`. The runtime's drop glue,
`print`, and shim checks (`rig.expectShim`) read these.

```zig
const std = @import("std");

const Point = struct { x: i32 = 0, y: i32 = 0 };
const Mode = enum(u8) { off, on };
const Errors = error{ Invalid, Overflow };

fn parse(_: []const u8, _: *u8) Errors!void {}

test "reflection" {
    const s = @typeInfo(Point).@"struct";
    inline for (s.field_names, s.field_types, s.field_attrs) |name, T, attrs| {
        try std.testing.expect(name.len == 1);
        try std.testing.expectEqual(@as(?T, 0), attrs.defaultValue(T));
    }

    const e = @typeInfo(Mode).@"enum";
    inline for (e.field_names, e.field_values) |name, value| {
        try std.testing.expectEqual(@field(Mode, name), @as(Mode, @fromBackingInt(value)));
    }

    const f = @typeInfo(@TypeOf(parse)).@"fn";
    try std.testing.expectEqual(2, f.param_types.len);
    try std.testing.expect(!f.attrs.varargs and !f.param_attrs[0].@"noalias");
    try std.testing.expect(@typeInfo(f.param_types[1].?).pointer.attrs.@"const" == false);

    const errs = @typeInfo(Errors).error_set.error_names.?; // in no particular order
    try std.testing.expectEqual(2, errs.len);
    try std.testing.expect(for (errs) |name| {
        if (std.mem.eql(u8, name, "Invalid")) break true;
    } else false);
    try std.testing.expectEqual(null, @typeInfo(anyerror).error_set.error_names);
}
```

`std.meta.fields` is a compile error that points to `@typeInfo`;
`std.meta.Elem`, `std.meta.activeTag`, `std.meta.eql`, and
`std.meta.stringToEnum` remain.

### `std.lang` and `@import("builtin")`

The language's types live in `std.lang`: `std.lang.Type`,
`std.lang.Endian`, `std.lang.Optimize`, `std.lang.CallingConvention`,
and so on (`std.builtin` is a deprecated alias). The compilation's own
settings come from `@import("builtin")`:

```zig
const std = @import("std");
const builtin = @import("builtin");

test "the build's settings" {
    const debug = builtin.optimize == .debug; // .debug, .safe, .fast, .small
    try std.testing.expect(!debug or builtin.optimize.runtimeSafety());
    const os = builtin.target.os.tag;
    const arch = builtin.target.cpu.arch;
    _ = .{ os, arch };
    const endian: std.lang.Endian = .little;
    _ = endian;
}
```

`builtin.mode` is a deprecated alias of `builtin.optimize`, and
`builtin.os`, `builtin.cpu`, and `builtin.abi` are deprecated in favor
of `builtin.target.os` and the rest. `@tagName(builtin.optimize)` is
`"debug"`, `"safe"`, `"fast"`, or `"small"`, and the same names are the
`-O` and `-Doptimize` values on the command line.

### Rules the compiler enforces

- Returning the address of a local is a compile error ("returning
  address of expired local variable").
- `packed struct` and `packed union` fields cannot be pointers (store
  a `usize`), and every field of a packed union must have the same bit
  size ("field bit width does not match earlier field"). Enums and
  packed types used in `extern` contexts need an explicit tag or
  backing integer: `enum(u8)`, `packed struct(u8)`.
- A vector cannot be indexed with a runtime index; coerce it to an
  array first.
- Doc comments (`///`) before a `test` block are an error; use `//`.
- `errdefer` takes no capture: `errdefer |err|` does not parse.
- `@hasDecl(T, "name")` sees only `pub` declarations, even from the
  file that declares `T`. Every declaration the runtime's `@hasDecl`
  checks look for (`__rig_drop`, `__rig_print`, `__rig_leak_trace`,
  ...) is `pub`.
- There is no `usingnamespace`, no `async`/`await`, no `void{}` (write
  `{}`), and no `i0` (write `u0`).

### Worth knowing when reading emitted code

- `anyerror!T` is an error union over every error. Rig emits it for
  every fallible function, and `try` propagates.
- Unused locals and parameters are compile errors; discard with
  `_ = x;`. A `var` that is never mutated is an error too
  ("local variable is never mutated"); `_ = &x;` silences it.
- A local may not shadow another local or a declaration in scope.
  Names that are Zig keywords or primitive types can be used when
  quoted: `@"var"`, `@"u8"`. `rig.writeZigIdent` quotes such Rig names,
  and the emitter's own declarations start with `__rig`.
- Declarations are analyzed lazily: a function nobody references is
  never type-checked, so write a test that calls new code.

---

## 12. Panics and debugging output

`std.debug.print(fmt, args)` writes to stderr at once (its small
buffer is flushed before it returns), ignoring errors. It bypasses the
program's `Io`, which makes it right for diagnostics and wrong for
program output (Rig's compiler diagnostics and usage errors use it).

`std.debug.assert(ok)` is checked in debug and safe builds and is
illegal behavior when false in fast and small builds. `@panic(msg)` and
`std.debug.panic(fmt, args)` panic unconditionally.

A root source file can replace the panic handler by declaring `pub
const panic`. Every emitted program declares `pub const panic =
rig.panic;`, and the runtime defines it with `std.debug.FullPanic`,
which takes the function that receives every panic message:

```zig
const std = @import("std");

pub const panic = std.debug.FullPanic(onPanic);

var out_buffer: [256]u8 = undefined;
var out: ?std.Io.File.Writer = null;

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // Flush buffered program output before the panic message.
    if (out) |*w| w.interface.flush() catch {};
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

pub fn main() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    out.?.interface.writeAll("buffered output\n") catch {};
    // A panic here (@panic, an overflow, a failed bounds check) would
    // print "buffered output" first, then the message and stack trace.
    out.?.interface.flush() catch {};
}
```

`std.debug.simple_panic` and `std.debug.no_panic` are the other
ready-made handlers. A handler written by hand as a `pub const panic =
struct { ... }` namespace must also declare `unexpectedErrorCode` and
`loadUninstantiableType`; `std.debug.simple_panic` has both to copy.
Stack traces: `std.debug.dumpCurrentStackTrace(.{})`,
`std.debug.captureCurrentStackTrace(.{}, &addr_buf)`, and
`std.debug.dumpStackTrace(&trace)`; `@errorReturnTrace()` gives the
error return trace.

---

## 13. Tests

```zig
const std = @import("std");

fn double(n: i64) i64 {
    return n * 2;
}

// A plain comment; `///` here would be a compile error.
test double {
    try std.testing.expectEqual(@as(i64, 8), double(4));
}

test "the testing namespace" {
    const gpa = std.testing.allocator; // leaks fail the test
    const s = try gpa.print("{d}", .{double(21)});
    defer gpa.free(s);
    try std.testing.expectEqualStrings("42", s);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &.{ 1, 2 });
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "x", 10));
    try std.testing.expect(std.mem.eql(u8, s, "42"));
    _ = std.testing.io; // an Io for tests
}
```

`expectEqual(expected, actual)` compares at the peer type of the two
arguments, so a bare literal works as `expected`; `expectEqualStrings`
and `expectEqualSlices` print a diff on failure.
`std.testing.tmpDir(.{})` gives a scratch `std.Io.Dir` under
`.zig-cache/tmp`, removed by `cleanup()`.

`zig build test` runs the compiler's and the runtime's unit tests;
`./test/run` runs it as the `unit` test. When nothing the tests depend
on has changed, `zig build test` replays the cached result: no test
runs, `--summary all` shows `run test cached`, and the summary counts
no tests. To run
them again on an unchanged tree, give it a fresh cache:
`zig build test --cache-dir "$(mktemp -d)"`.

---

## 14. The build system

`zig build` compiles `build.zig` into a separate configurer program
whose `build` function describes the build graph; a separate maker
runs the graph. `build.zig` therefore only describes steps: it cannot
read install paths or resolve a `LazyPath` to a file name, and anything
that must happen at build time is a step (a Run step, or a small Zig
tool built and run by one). Executables and tests are built from
**modules**: the root source file, target, optimize mode, imports, and
libc linkage belong to a `std.Build.Module`, and `addExecutable` /
`addTest` take `.root_module`.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{}); // .debug, .safe, .fast, .small

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // .link_libc = true,
        // .imports = &.{.{ .name = "dep", .module = other_module }},
    });

    // Values the code reads with @import("build_options").
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "app", .root_module = mod });
    b.installArtifact(exe); // PREFIX/bin/app, zig-out/bin/app by default

    // Copy the executable into the source tree as well (Rig's bin/rig).
    const checkout_bin = b.addUpdateSourceFiles();
    checkout_bin.addCopyFileToSource(exe.getEmittedBin(), "bin/app");
    b.getInstallStep().dependOn(&checkout_bin.step);

    // `zig build run -- args`
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run.step);

    // `zig build test`
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // A user option (-Dtool=PATH) and an external command.
    const tool = b.option([]const u8, "tool", "Path to a generator") orelse "true";
    const gen = b.addSystemCommand(&.{ tool, "input.txt" });
    gen.setCwd(b.path("."));
    b.step("gen", "Run the generator").dependOn(&gen.step);
}
```

- The install prefix (`-p PREFIX`, `zig-out` by default) is not
  visible to `build.zig`. Rig's `build.zig` installs `PREFIX/bin/rig`
  with `b.installArtifact` and copies the same executable to `bin/rig`
  in the checkout with `b.addUpdateSourceFiles`, as above.
- Arguments after `--` reach a Run step through `run.addPassthruArgs()`;
  `build.zig` itself never sees them.
- The configuration is cached: `build` runs again only when
  `build.zig` or a `-D` option changes. A file it inspects (Rig's
  `findNexus` checks for a Nexus binary) is not an input unless
  declared with `b.dependOnFileMetadata(lazy_path)` or
  `b.dependOnFileContents(lazy_path)`; `b.graph.poisonCache()` makes
  `build` run every time.
- File system access in `build.zig` goes through `b.graph.io`, e.g.
  `std.Io.Dir.cwd().access(b.graph.io, path, .{})`. Path helpers:
  `b.path("rel")` (a `LazyPath` in the package), `b.pathJoin`,
  `b.pathResolve`, and `b.root`, the package's directory (format it
  with `b.fmt("{f}", .{b.root})`).
- C headers: `b.addTranslateC(.{ .root_source_file = b.path("c.h"),
  .target = target, .optimize = optimize })` then `.createModule()`
  (deprecated in favor of the `translate_c` package), imported as a
  module; there is no `@cImport`.
- A `build.zig.zon`, if present, needs `.name` as an enum literal
  (`.name = .rig`) and a `.fingerprint`. Fetched packages land in
  `zig-pkg/` next to `build.zig`.
- Useful flags: `--summary all`, `--error-style minimal`,
  `--test-timeout 30s`, `-Doptimize=safe`, `-p PREFIX`, and
  `--cache-dir DIR` for a fresh cache (§13).
- `zig run`, `zig test`, and `zig build` reuse cached work; `zig
  build-exe` compiles in full every time, with or without
  `-femit-bin=`. `rig build` runs `zig build-exe`, so it pays a full
  compile on every call.

---

## 15. Compile errors and their fixes

| Error (fragment) | Cause | Fix |
|---|---|---|
| `root source file struct 'fs' has no member named 'cwd'` | `std.fs.cwd()`: directories are `std.Io.Dir` | `std.Io.Dir.cwd()`, and pass `io` |
| `member function expected 1 argument(s), found 0` on `close`, `stat`, `openFile`, ... | the method takes `io` | `file.close(io)` |
| `missing struct field: items` | `ArrayList` initialized with `.{}` or `T{}` | `= .empty` |
| `no field or member function named 'writer' in 'array_list.Aligned(u8,null)'` | unmanaged lists have no writer | `list.print(gpa, ...)`, or a `Writer.Allocating` |
| `type 'Io.Writer' not a function` | `out.writer()` on a `Writer.Allocating`, whose `writer` is a field | `&out.writer`, `out.writer.print(...)` |
| `expected type 'Io.Limit', found 'comptime_int'` | bare size cap | `.limited(n)` |
| `cannot format slice without a specifier (i.e. {s}, {x}, {b64}, or {any})` | `{}` on a string | `{s}` |
| no error, but a struct prints as `.{ .x = ... }` instead of through its `format` method | `{}` or `{any}` | `{f}` |
| `cannot print optional without a specifier (i.e. {?} or {any})` | `{}` on `?T` | `{?}`, `{?s}` |
| `member function expected 3 argument(s), found 1` from `{f}` | `format(self, fmt, options, writer)` | `format(self, w: *std.Io.Writer) std.Io.Writer.Error!void` |
| `binary operator '*' has whitespace on one side, but not the other` | `"-" ** 40`: there is no `**` | `@splat` with a typed result |
| `expected block or expression, found '\|'` | `errdefer \|err\|` | catch the error at the call site |
| `no field named 'fields' in struct 'lang.Type.Struct'` | `@typeInfo(T).@"struct".fields` | `field_names`, `field_types`, `field_attrs` |
| `deprecated in favor of @typeInfo` | `std.meta.fields(T)` | `@typeInfo(T).@"struct".field_names` |
| `root source file struct 'meta' has no member named 'Int'` | `std.meta.Int`, `std.meta.Tuple` | `@Int`, `@Tuple` |
| `invalid builtin function: '@Type'` | `@Type` | `@Int`, `@Struct`, `@Tuple`, ... |
| `invalid builtin function: '@cImport'` | `@cImport` | translate the header in `build.zig` |
| `expected type 'u8', found 'usize'` at `@fromBackingInt` | the argument is not exactly the backing type | `@fromBackingInt(@intCast(n))` |
| `no field named 'Debug' in enum 'lang.Optimize'` | `builtin.optimize == .Debug` | `.debug`, `.safe`, `.fast`, `.small` |
| `root source file struct 'mem' has no member named 'trimLeft'` | the name is `trimStart` | `trimStart` / `trimEnd` |
| `root source file struct 'fmt' has no member named 'bufPrintZ'` | | `std.mem.printSentinel(&buf, fmt, args, 0)` |
| `root source file struct 'heap' has no member named 'GeneralPurposeAllocator'` | | `std.heap.SafeAllocator` |
| `incompatible types: 'usize' and '@EnumLiteral()'` | `sa.deinit() == .leak` | `sa.deinit() != 0` |
| `documentation comments cannot be attached to tests` | `///` before `test` | `//` |
| `returning address of expired local variable 'x'` | `return &x;` | return by value or allocate |
| `local variable is never mutated` | `var` that could be `const` | make it `const` |
| `unused local constant` / `unused local variable` / `unused function parameter` | Zig requires use | `_ = x;` |
| `packed structs cannot contain fields of type '*u8'` | a pointer in a packed struct | store a `usize` |
| `vector index not comptime known` | runtime vector indexing | coerce the vector to an array |
| `no field or member function named 'writeAll' in 'Io.File'` | writing to a file directly | `file.writeStreamingAll(io, bytes)` or a file writer |
| `root source file struct 'std' has no member named 'io'` | `std.io.getStdOut()`, `fixedBufferStream` | `std.Io.File.stdout()`, `std.Io.Writer.fixed` |
| `no field named 'args' in struct 'Build'` | `b.args` in `build.zig` | `run.addPassthruArgs()` |
| `no field named 'build_root' in struct 'Build'` (also `'install_path'`) | `build.zig` reading its paths | `b.root`; pass `LazyPath`s to steps |
| `error: FileNotFound` printed and exit 1 at run time | an error returned from `main` | handle it, or print a message and `std.process.exit` |
| `error(SafeAllocator): leaked [addr: ..., len: ...] allocated at:` at exit | `init.gpa` or a `SafeAllocator` saw a leak | free it, or allocate from an arena |
| `error.OutOfMemory` from `std.process.spawn` with plenty of memory | spawning through `global_single_threaded` (its allocator always fails) | pass a real `Io` (`init.io`) |

## 16. Known Zig 0.17 issues Rig works around

**A NaN converted to an integer is not safety-checked.** In debug and
safe builds, `@trunc`, `@floor`, `@ceil`, and
`@round` with an integer result type, panic on an out-of-range value
("integer part of floating point value out of bounds") but turn a NaN
into an unspecified integer (0 on aarch64-macos) without a panic. The
emitter wraps the operand of a float-to-integer conversion in
`rig.notNan`, which panics with the same message
(`src/runtime.zig`). This program shows it:

```zig
const std = @import("std");

pub fn main() void {
    var x: f64 = std.math.nan(f64);
    _ = &x;
    const n: i64 = @trunc(x); // no panic in a debug build
    std.debug.print("{d}\n", .{n});
}
```
