# Zig 0.16 for Rig contributors

Rig is written in Zig 0.16 and compiles to Zig 0.16. This is a
reference for the parts of Zig that Rig work touches: the compiler
(`src/*.zig`), the runtime shipped with every program
(`src/runtime.zig`), the Zig the emitter writes, `build.zig`, and the
standard-library work ahead (I/O, allocators, collections, strings,
processes, files).

It is written for people and for AI agents whose knowledge of Zig
predates 0.16. The 0.15 and 0.16 releases changed most of the
standard library's I/O, containers, and entry point, so Zig written
from memory usually fails to compile. Each section gives the 0.16
spelling; every `zig` block here compiles and passes under Zig 0.16.0.

When this document is silent, the installed standard library is the
authority:

```bash
zig env                                      # .lib_dir is the Zig lib directory
grep -n 'pub fn readFileAlloc' "$(zig env | sed -n 's/.*\.lib_dir = "\(.*\)".*/\1/p')/std/Io/Dir.zig"
zig test scratch.zig                         # try an API in a test block
```

The [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
cover everything this document leaves out.

## Contents

1. [Where Rig meets Zig](#1-where-rig-meets-zig)
2. [Reflexes that no longer compile](#2-reflexes-that-no-longer-compile)
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
16. [Known Zig 0.16 issues Rig works around](#16-known-zig-016-issues-rig-works-around)

---

## 1. Where Rig meets Zig

| Place | Zig it depends on |
|---|---|
| `src/main.zig` (the CLI) | `pub fn main(init: std.process.Init)`, the process arena, `init.environ_map`, `std.Io.Dir.cwd().readFileAlloc`, `createFileAtomic`, buffered `std.Io.File.stdout()` writers, `std.process.spawn` to run `zig` |
| `src/modules.zig` | `readFileAlloc`, `realPathFileAlloc`, `std.fs.path` |
| `src/rig.zig` | `std.StaticStringMap` keyword tables |
| `src/sema.zig`, `resolve.zig`, `typecheck.zig`, `ownership.zig` | unmanaged `ArrayList` / `HashMap` with `.empty`, `ArenaAllocator` |
| `src/emit.zig` | `std.Io.Writer.Allocating`, `std.fmt.allocPrint` |
| `src/runtime.zig` | `std.heap.smp_allocator`, `std.heap.DebugAllocator`, a custom `std.mem.Allocator`, `std.Io.Threaded.global_single_threaded`, `std.debug.FullPanic` |
| Emitted programs | `pub fn main() void`, `pub const panic = rig.panic;`, `anyerror!T`, `@divTrunc`, `@rem`, `@intCast`, `@floatFromInt`, `@intFromFloat` |
| `build.zig` | `b.createModule`, `b.addExecutable(.{ .root_module = ... })`, `b.addOptions`, `b.addInstallArtifact`, `b.addSystemCommand`, `b.addTest`, `b.graph.io` |

## 2. Reflexes that no longer compile

| Pre-0.15 reflex | Zig 0.16 |
|---|---|
| `var list = std.ArrayList(T).init(gpa);` | `var list: std.ArrayList(T) = .empty;` and pass `gpa` to every call that allocates (§9) |
| `list.writer()` to build a string | `var out: std.Io.Writer.Allocating = .init(gpa);` then `out.writer.print(...)` (§5) |
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
| `std.heap.GeneralPurposeAllocator(.{}){}` | `std.heap.DebugAllocator(.{}) = .init` (§8) |
| `pub fn format(self, comptime fmt, options, writer)` | `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`, printed with `{f}` (§7) |
| `"{}"` for a string or an optional | `"{s}"` for strings, `"{?}"` or `"{any}"` for optionals |
| `std.fmt.format(writer, ...)` | `writer.print(...)` |
| `std.mem.trimLeft` / `trimRight` | `std.mem.trimStart` / `trimEnd` |
| `@Type(.{ .int = ... })` | `@Int(.unsigned, 10)` and the other type builtins (§11) |
| `std.time.Timer`, `std.time.milliTimestamp()` | `std.Io.Clock.Timestamp.now(io, .awake)` |
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

`global_single_threaded` is what `src/runtime.zig` uses, because an
emitted program's `main` takes no arguments. It is built from
`Threaded.init_single_threaded`, whose allocator is
`std.mem.Allocator.failing` and which supports no concurrency or
cancelation. Plain file writes, `isTty`, clocks, and similar leaf calls
work through it. Anything that allocates through the `Io` (spawning a
child process, for one, which builds its argv and environment blocks
that way) fails with `error.OutOfMemory`. Thread a real `Io` to code
that spawns processes or runs tasks concurrently.

```zig
const std = @import("std");

test "the process-wide single-threaded Io" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed.raw.toNanoseconds() > 0);
}
```

Time lives under `std.Io` too: `std.time` keeps only unit constants
(`std.time.ns_per_ms` and the like) and the `epoch` helpers. Use
`Io.Clock.Timestamp.now(io, .awake)` for intervals and `.real` for
wall-clock time. Entropy is `io.random(&buf)` (or
`try io.randomSecure(&buf)` for cryptographic use). Locks are
`std.Io.Mutex`, `std.Io.Condition`, `std.Io.Event`, and friends, and
concurrency is `io.async(func, args)` / `std.Io.Group`; Rig uses none of
these yet.

---

## 4. main, arguments, environment, processes

### Three shapes of main

```zig
pub fn main() !void {}                                            // nothing provided
pub fn main(init: std.process.Init.Minimal) !void { _ = init; }   // argv and environ only
pub fn main(init: std.process.Init) !void { _ = init; }           // "juicy" main
```

`std.process.Init` gives the program:

| Field | What it is |
|---|---|
| `init.io` | an `Io.Threaded` for the process |
| `init.gpa` | a general-purpose allocator: `DebugAllocator` in Debug builds and in ReleaseSafe builds without libc; otherwise `c_allocator` when libc is linked, else `smp_allocator` |
| `init.arena` | a `*std.heap.ArenaAllocator` freed when `main` returns |
| `init.environ_map` | `*std.process.Environ.Map`, the environment |
| `init.minimal.args` | the command line (`std.process.Args`) |
| `init.preopens` | WASI preopened files (void elsewhere) |

The Rig CLI is a short-lived compiler, so it allocates everything from
`init.arena` and never frees. That is also much faster in Debug builds
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

Returning an error from `main` logs it (`error: FileNotFound`), dumps
the error return trace in Debug, and exits 1. Leaks reported by
`init.gpa`'s `DebugAllocator` at exit print traces but do not change the
exit status. `std.process.exit(code)` exits immediately without running
`defer`s, so flush buffered writers first. `std.process.fatal(fmt,
args)` logs an error and exits 1.

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
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}
```

`Term` is `union(enum) { exited: u8, signal: std.posix.SIG, stopped:
std.posix.SIG, unknown: u32 }`. A missing executable is
`error.FileNotFound` from `spawn`. `std.process.replace(io, .{ .argv =
argv })` is the old `execv`; `std.process.currentPathAlloc(io, gpa)` is
the old `getCwdAlloc`.

---

## 5. Writers and readers

0.15 replaced the generic `anytype` readers and writers with two
concrete types, `std.Io.Writer` and `std.Io.Reader`. Each is a struct
holding a **buffer** and a vtable; the buffer belongs to whoever
created the writer, and nothing reaches the underlying file until the
buffer fills or `flush()` is called. Functions take `w: *std.Io.Writer`
(not `anytype`), and the error set is `std.Io.Writer.Error`
(`error{WriteFailed}`); the underlying cause, if needed, is kept by the
concrete writer (`file_writer.err`).

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

`std.Io.Writer.Allocating` is a writer that grows a heap buffer; it
replaces `ArrayList(u8).writer()`. Its `writer` is a **field**, not a
method. The emitter writes each module through one of these.

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

`written()` borrows the current contents; the slice is invalid after
the next write. `toOwnedSlice()` hands the bytes over and resets the
writer. For small strings, `std.fmt.allocPrint(gpa, fmt, args)`
returns a new `[]u8` directly, and `list.print(gpa, fmt, args)` appends
formatted text to an `ArrayList(u8)`.

### Fixed buffers

```zig
const std = @import("std");

test "fixed writer and reader" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{d}-{d}", .{ 1, 2 });
    try std.testing.expectEqualStrings("1-2", w.buffered());
    try std.testing.expectError(error.WriteFailed, w.writeAll("x" ** 40));

    var r: std.Io.Reader = .fixed("alpha\nbeta\n");
    try std.testing.expectEqualStrings("alpha", (try r.takeDelimiter('\n')).?);
    try std.testing.expectEqualStrings("beta", (try r.takeDelimiter('\n')).?);
    try std.testing.expectEqual(null, try r.takeDelimiter('\n'));
}
```

`std.fmt.bufPrint(&buf, fmt, args)` formats into a buffer and returns
the used slice, or `error.NoSpaceLeft`.

### Readers

A file reader works the same way: `var fr = file.reader(io, &buf);`
then use `&fr.interface`. Useful `std.Io.Reader` calls:

| Call | Result |
|---|---|
| `r.takeDelimiter('\n')` | the next line without the newline, `null` at the end; `error.StreamTooLong` if a line exceeds the buffer |
| `r.takeByte()`, `r.peekByte()` | one byte; `error.EndOfStream` at the end |
| `r.take(n)` | the next `n` bytes, borrowed from the buffer |
| `r.allocRemaining(gpa, .limited(n))` | everything left, as an owned slice |
| `r.streamRemaining(w)` | copy everything left to a writer |

### `std.Io.Limit`

APIs that read "up to some amount" take a `std.Io.Limit` rather than a
`usize`: `.limited(n)`, `.unlimited`, or `.nothing`. Exceeding it is
`error.StreamTooLong`.

---

## 6. Files and directories

`std.fs` now holds only `std.fs.path` and a few constants. Files and
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

    // Read a whole file, capped.
    const text = try dir.readFileAlloc(io, "a.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello\n", text);
    try std.testing.expectError(error.StreamTooLong, dir.readFileAlloc(io, "a.txt", gpa, .limited(3)));

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

### Renamed methods

| 0.14 / 0.15 | 0.16 |
|---|---|
| `dir.makeDir`, `makePath`, `makeOpenPath` | `dir.createDir(io, p, perms)`, `createDirPath(io, p)`, `createDirPathOpen(io, p, .{})` |
| `std.fs.realpathAlloc`, `dir.realpathAlloc` | `dir.realPathFileAlloc(io, p, gpa)` (returns `[:0]u8`) |
| `file.read`, `file.pread` | `file.readStreaming(io, &.{buf})`, `file.readPositional(io, &.{buf}, offset)` |
| `file.write`, `file.pwrite` | `file.writeStreaming(...)`, `file.writePositional(io, &.{bytes}, offset)` |
| `file.getEndPos`, `setEndPos` | `file.length(io)`, `file.setLength(io, n)` |
| `file.seekTo`, `getPos` | on the reader or writer: `fr.seekTo(n)`, `fr.logicalPos()` |
| `std.fs.selfExePathAlloc` | `std.process.executablePathAlloc(io, gpa)` |
| `file.isTty()` | `file.isTty(io)` (can fail with `error.Canceled`) |

Paths are still plain byte slices handled by `std.fs.path` (also
reachable as `std.Io.Dir.path`): `join`, `dirname`, `basename`,
`extension`, `resolve`, `isAbsolute`. `std.fs.path.relative` now takes
the current directory and environment explicitly.

---

## 7. Formatting

`writer.print`, `std.debug.print`, `std.fmt.allocPrint`, and
`std.fmt.bufPrint` share one format language:
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
`{s:*^9}`. Positional and named arguments: `{0s} {1d} {0s}`,
`{[name]s}` with `.{ .name = "x" }`. Write `{{` and `}}` for literal
braces.

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
    const got = try std.fmt.bufPrint(&buf, "{d:0>4}|{s:<4}|{x}|{t}|{t}|{?d}|{f}|{any}|{Bi}|{{}}", .{
        42, "ab", 255, Color.green, e, none, p, p, 2048,
    });
    try std.testing.expectEqualStrings("0042|ab  |ff|green|Oops|null|(1, -2)|.{ .x = 1, .y = -2 }|2KiB|{}", got);
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
    try std.testing.expectEqualStrings("\"rig\"", try std.fmt.bufPrint(&buf, "{f}", .{n.fmtQuoted()}));
    // std.zig.fmtString escapes a string for a Zig string literal:
    try std.testing.expectEqualStrings("a\\nb", try std.fmt.bufPrint(&buf, "{f}", .{std.zig.fmtString("a\nb")}));
}
```

Renamed: `std.fmt.Formatter` → `std.fmt.Alt`, `std.fmt.format` →
`writer.print`, `std.fmt.FormatOptions` → `std.fmt.Options`,
`std.fmt.bufPrintZ` → `std.fmt.bufPrintSentinel`.

---

## 8. Allocators

The interface is `std.mem.Allocator`; `alloc`, `free`, `create`,
`destroy`, `dupe`, `realloc` work as before. A custom allocator fills
in a vtable of four functions, each taking a `std.mem.Alignment` (an
enum of log2 values, not a byte count). The runtime's `LeakChecker` is
one:

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
| `std.heap.DebugAllocator(.{})` | leak detection with stack traces, double-free detection. `var da: std.heap.DebugAllocator(.{}) = .init;` then `da.allocator()`; `da.deinit()` returns `.ok` or `.leak`. Replaces `GeneralPurposeAllocator`. |
| `std.heap.ArenaAllocator` | `.init(child)`, then `.allocator()`; frees everything at `deinit()`. Thread-safe in 0.16 when its child allocator is. Rig's compiler passes use arenas. |
| `std.heap.page_allocator` | whole pages from the OS; a backing allocator, not for small objects |
| `std.heap.c_allocator` | `malloc`; needs libc linked |
| `std.heap.FixedBufferAllocator` | `.init(&buf)`, allocates from a byte buffer |
| `std.testing.allocator` | a `DebugAllocator` in tests; a leak fails the test |
| `std.testing.failing_allocator`, `std.testing.FailingAllocator` | fail allocation (after N successes) to test `error.OutOfMemory` paths |

**`DebugAllocator` is slow when many allocations are live.** It keeps
per-allocation metadata (and, in Debug, a stack trace for each), and
its cost grows with the number of live allocations: in a Debug build,
allocating and freeing 200,000 small blocks that are all live at once
takes a few hundred times longer than with `smp_allocator` or an arena.
This is why
the Rig CLI allocates from `init.arena` instead of `init.gpa`, and why
the runtime's Debug leak checker records only address and size, keeps
its table in `smp_allocator`, and sits on `DebugAllocator` only when
`RIG_LEAK_TRACE=1` asks for stack traces.

`std.heap.ThreadSafeAllocator` and `std.heap.GeneralPurposeAllocator`
are gone.

---

## 9. Collections

### ArrayList is unmanaged

`std.ArrayList(T)` no longer stores an allocator. Initialize it with
`.empty` (its fields have no defaults, so `.{}` does not compile), and
pass the allocator to every call that may allocate and to `deinit`.
The old managed type survives as the deprecated
`std.array_list.Managed`, and `std.ArrayListUnmanaged` is a deprecated
alias of `std.ArrayList` (much of `src/` still spells it that way).

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

### Hash maps

`std.AutoHashMapUnmanaged(K, V)`, `std.StringHashMapUnmanaged(V)`, and
`std.HashMapUnmanaged(K, V, Context, max_load)` follow the same rules:
`.empty`, allocator on `put`, `getOrPut`, `ensureTotalCapacity`, and
`deinit`; none on `get`, `getPtr`, `contains`, `remove`, `count`, or
`iterator`. The managed `std.AutoHashMap` and `std.StringHashMap` still
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

Insertion-ordered maps moved: `std.array_hash_map.Auto(K, V)`,
`.String(V)`, and `.Custom(...)`, all unmanaged; the managed
`std.AutoArrayHashMap` family is gone, and the `...Unmanaged` names are
deprecated aliases. Removal must choose an order:
`swapRemove` or `orderedRemove`.

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

- `std.DynamicBitSetUnmanaged`: `try .initEmpty(gpa, n)`, `set(i)`,
  `isSet(i)`, `deinit(gpa)`. The static bit sets also have `.empty` and
  `.full` decl literals.
- `std.Deque(T)`: `.empty`, `pushBack(gpa, x)`, `pushFront(gpa, x)`,
  `popFront()`, `popBack()`.
- `std.PriorityQueue(T, Context, lessThan)`: `.empty` (or
  `.initContext(ctx)`), `push(gpa, x)`, `pop()`, `peek()`.
- `std.MultiArrayList(T)`, `std.EnumMap`, `std.EnumSet`,
  `std.SinglyLinkedList` and `std.DoublyLinkedList` (intrusive: embed a
  `Node` in your struct and use `@fieldParentPtr`).
- `std.SegmentedList` and `std.BoundedArray` are gone. For a
  fixed-capacity list, use `std.ArrayList(T).initBuffer(&buf)` with the
  `...Bounded` and `...AssumeCapacity` methods.
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
| split once | `std.mem.cut(u8, s, "=")` → `?struct { before, after }`; also `cutScalar`, `cutLast`, `cutPrefix`, `cutSuffix` |
| split into parts | `std.mem.splitScalar(u8, s, ',')`, `splitSequence`, `splitAny` (keep empty fields); `tokenizeScalar`, `tokenizeAny` (skip them) |
| trim | `std.mem.trim(u8, s, " \t")`, `trimStart`, `trimEnd` |
| join, concatenate | `std.mem.join(gpa, ", ", parts)`, `std.mem.concat(gpa, u8, &.{ a, b })` |
| replace, count | `std.mem.replaceOwned(u8, gpa, s, "a", "b")`, `std.mem.count(u8, s, "a")` |
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

### Changed builtins

| Builtin | 0.16 |
|---|---|
| `@Type(info)` | removed. Use `@Int(.signed, 12)`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple(&.{ A, B })`, `@EnumLiteral()`. Arrays, optionals, error unions, and floats use their own syntax (`[N]T`, `?T`, `E!T`, `std.meta.Float(64)`). Error sets cannot be reified. `std.meta.Int` and `std.meta.Tuple` are deprecated wrappers. |
| `@intFromFloat(x)` | deprecated (still compiles), equivalent to `@trunc`. `@trunc`, `@floor`, `@ceil`, and `@round` now convert to an integer result type directly: `const n: i64 = @trunc(x);`. An out-of-range result is safety-checked. |
| `@floatFromInt(x)` | still needed unless the integer type fits the float exactly: `u24` and smaller coerce to `f32` implicitly, 53-bit integers to `f64`. |
| `@sqrt`, `@sin`, `@floor`, ... | forward the result type: `const r: f64 = @sqrt(@floatFromInt(n));` |
| `@cImport` | deprecated in favor of `b.addTranslateC` in `build.zig` |
| `@divTrunc`, `@divFloor`, `@rem`, `@mod`, `@intCast`, `@truncate`, `@bitCast`, `@ptrCast`, `@alignCast` | unchanged; cast builtins take the result type from context (`const x: u8 = @intCast(n);`, or `@as(u8, @intCast(n))`). |

```zig
const std = @import("std");

test "type and float builtins" {
    const U12 = @Int(.unsigned, 12);
    try std.testing.expectEqual(12, @bitSizeOf(U12));

    const Pair = @Tuple(&.{ u8, bool });
    const p: Pair = .{ 1, true };
    try std.testing.expect(p[1]);

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

### Rules that tightened

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
- Custom `format` methods take `(self, *std.Io.Writer)` (since 0.15).
- `usingnamespace` and `async`/`await` are gone (since 0.15).

### Unchanged but worth knowing when reading emitted code

- `anyerror!T` is an error union over every error. Rig emits it for
  every fallible function, and `try` propagates.
- Unused locals and parameters are compile errors; discard with
  `_ = x;`. A `var` that is never mutated is an error too
  ("local variable is never mutated"); `_ = &x;` silences it.
- A local may not shadow another local or a declaration in scope.
  Names that are Zig keywords or primitive types can still be used when
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

`std.debug.assert(ok)` is checked in Debug and ReleaseSafe and is
undefined behavior when false in ReleaseFast and ReleaseSmall. `@panic(msg)` and
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
ready-made handlers. Stack traces in 0.16:
`std.debug.dumpCurrentStackTrace(.{})`,
`std.debug.captureCurrentStackTrace(.{}, &addr_buf)`, and
`std.debug.dumpStackTrace(&trace)`; `@errorReturnTrace()` still gives
the error return trace.

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
    const s = try std.fmt.allocPrint(gpa, "{d}", .{double(21)});
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
and `expectEqualSlices` print a diff on failure. `zig build test` runs
the compiler's and the runtime's unit tests; `./test/run` runs them as
the `unit` test.
`std.testing.tmpDir(.{})` gives a scratch `std.Io.Dir` under
`.zig-cache/tmp`, removed by `cleanup()`.

---

## 14. The build system

`build.zig` in 0.16 builds executables and tests from **modules**: the
root source file, target, optimize mode, imports, and libc linkage
belong to a `std.Build.Module`, and `addExecutable` / `addTest` take
`.root_module`.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    b.installArtifact(exe); // zig-out/bin/app

    // `zig build run -- args`
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
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

- To install somewhere other than `zig-out/bin`, use
  `b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom
  = "../bin" } } })`; Rig installs `bin/rig` in the checkout that way
  when no `--prefix` is given.
- File system access in `build.zig` goes through `b.graph.io`, e.g.
  `std.Io.Dir.cwd().access(b.graph.io, path, .{})`. Path helpers:
  `b.path("rel")` (a `LazyPath` in the package), `b.pathJoin`,
  `b.pathResolve`, `b.build_root`.
- `b.addTranslateC(.{ .root_source_file = b.path("c.h"), .target =
  target, .optimize = optimize })` then `.createModule()` replaces
  `@cImport`.
- A `build.zig.zon`, if present, needs `.name` as an enum literal
  (`.name = .rig`) and a `.fingerprint`. Fetched packages land in
  `zig-pkg/` next to `build.zig`.
- Useful flags: `--summary all`, `--error-style minimal` (replaces
  `--prominent-compile-errors`), `--test-timeout 30s`,
  `-Doptimize=ReleaseSafe`, `-p PREFIX`.

---

## 15. Compile errors and their fixes

| Error (fragment) | Cause | Fix |
|---|---|---|
| `root source file struct 'fs' has no member named 'cwd'` | 0.14-era file API | `std.Io.Dir.cwd()`, and pass `io` |
| `member function expected 1 argument(s), found 0` on `close`, `stat`, `openFile`, ... | the method now takes `io` | `file.close(io)` |
| `missing struct field: items` / `capacity` | `ArrayList` initialized with `.{}` or `T{}` | `= .empty` |
| `no field or member function named 'writer'` on an `ArrayList` | unmanaged lists have no writer | `list.print(gpa, ...)`, or a `Writer.Allocating` |
| `type 'Io.Writer' not a function` | `out.writer()` on a `Writer.Allocating`, whose `writer` is a field | `&out.writer`, `out.writer.print(...)` |
| `expected type 'Io.Limit', found 'comptime_int'` | bare size cap | `.limited(n)` |
| `cannot format slice without a specifier (i.e. {s}, {x}, {b64}, or {any})` | `{}` on a string | `{s}` |
| no error, but a struct prints as `.{ .x = ... }` instead of through its `format` method | `{}` or `{any}` | `{f}` |
| `cannot print optional without a specifier (i.e. {?} or {any})` | `{}` on `?T` | `{?}`, `{?s}` |
| `member function expected 3 argument(s), found 1` from `{f}` | 0.14-style `format(self, fmt, options, writer)` | `format(self, w: *std.Io.Writer) std.Io.Writer.Error!void` |
| `invalid builtin function: '@Type'` | `@Type` removed | `@Int`, `@Struct`, `@Tuple`, ... |
| `root source file struct 'mem' has no member named 'trimLeft'` | renamed | `trimStart` / `trimEnd` |
| `root source file struct 'heap' has no member named 'GeneralPurposeAllocator'` | renamed | `std.heap.DebugAllocator(.{})` |
| `documentation comments cannot be attached to tests` | `///` before `test` | `//` |
| `returning address of expired local variable` | `return &local;` | return by value or allocate |
| `local variable is never mutated` | `var` that could be `const` | make it `const` |
| `unused local constant` / `unused local variable` / `unused function parameter` | Zig requires use | `_ = x;` |
| `packed structs cannot contain fields of type '*u8'` | a pointer in a packed struct | store a `usize` |
| `vector index not comptime known` | runtime vector indexing | coerce the vector to an array |
| `no field or member function named 'writeAll' in 'Io.File'` | 0.15 file writes | `file.writeStreamingAll(io, bytes)` or a file writer |
| `root source file struct 'std' has no member named 'io'` | `std.io.getStdOut()`, `fixedBufferStream` | `std.Io.File.stdout()`, `std.Io.Writer.fixed` |
| `error: FileNotFound` printed and exit 1 at run time | an error returned from `main` | handle it, or print a message and `std.process.exit` |
| `error(DebugAllocator): memory address 0x... leaked` at exit | `init.gpa` or a `DebugAllocator` saw a leak | free it, or allocate from an arena |
| `error.OutOfMemory` from `std.process.spawn` with plenty of memory | spawning through `global_single_threaded` (its allocator always fails) | pass a real `Io` (`init.io`) |

## 16. Known Zig 0.16 issues Rig works around

**`zig run` can run a stale executable built from another directory.**
In whole cache mode, `Compilation.addModuleTableToCacheHash` adds the
root source file through `Path.toCachePath`, which makes it
cwd-relative, and the cwd prefix is not hashed. Two directories with a
byte-identical root file that imports different files share one cache
entry, and editing the imported file in the second directory is not
noticed. Rig passes `--cache-dir <package>/.zig-cache` to every `zig`
invocation so each emitted package has its own cache
(`src/main.zig`; regression test `test/cli/zig_cache.sh`). This
standalone script reproduces it, for an upstream report:

```sh
set -e
# The real path: an absolute path spelled through a symlink (macOS /var ->
# /private/var) does not start with the cwd, so it stays absolute and unique.
T=$(cd "$(mktemp -d)" && pwd -P)
nonce=$$-$(date +%s)
for d in a b; do
  mkdir "$T/$d"
  printf 'const lib = @import("lib.zig");\npub fn main() void { lib.hello(); }\n' >"$T/$d/main.zig"
  printf 'const std = @import("std");\npub fn hello() void { std.debug.print("%s %s\\n", .{}); }\n' "$d" "$nonce" >"$T/$d/lib.zig"
done

echo "expect 'a $nonce':"; (cd "$T/a" && zig run main.zig)
echo "expect 'b $nonce':"; (cd "$T/b" && zig run main.zig)
echo "expect 'b $nonce' (absolute path):"; (cd "$T/b" && zig run "$T/b/main.zig")
printf 'const std = @import("std");\npub fn hello() void { std.debug.print("b edited %s\\n", .{}); }\n' "$nonce" >"$T/b/lib.zig"
echo "expect 'b edited $nonce':"; (cd "$T/b" && zig run main.zig)
echo "expect 'b edited $nonce' (run from the parent, so the relative path differs):"; (cd "$T" && zig run b/main.zig)
rm -rf "$T"
```

**Deprecated builtins and std functions still in use.** The emitter
writes `@intFromFloat`, and `src/` calls `std.mem.indexOf*`; both are
deprecated in 0.16 but compile. Move to their replacements when Zig
removes them.
